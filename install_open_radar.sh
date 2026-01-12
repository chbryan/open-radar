#!/usr/bin/env bash
# install_open_radar.sh
# One-shot installer for Open Radar (Linux-first). Installs Docker + Compose, enables the daemon,
# fixes permissions when run via `sudo bash ...`, and (by default) starts Open Radar automatically.
#
# Zero-intervention goal:
# - Works whether run as root OR via sudo
# - Adds the *original* user (SUDO_USER/logname) to the docker group
# - Starts the stack via a fresh login shell for that user (so group membership is effective immediately)
#
# Usage:
#   sudo bash install_open_radar.sh
#   # or
#   bash install_open_radar.sh
#
# Controls:
#   OPEN_RADAR_AUTOSTART=1  (default) start containers (if docker-compose.yml is present next to this script)
#   OPEN_RADAR_AUTOSTART=0  install only

set -euo pipefail

log()  { echo -e "\033[1;32m[open-radar]\033[0m $*"; }
warn() { echo -e "\033[1;33m[open-radar]\033[0m $*"; }
err()  { echo -e "\033[1;31m[open-radar]\033[0m $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AUTO_START="${OPEN_RADAR_AUTOSTART:-1}"

# Determine which non-root user should own "docker group" access.
detect_target_user() {
  local tu=""
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    # If invoked via sudo, this is the real user
    tu="${SUDO_USER:-}"
    if [[ -z "$tu" || "$tu" == "root" ]]; then
      # If not via sudo, try logname (works in most terminals)
      if need_cmd logname; then
        tu="$(logname 2>/dev/null || true)"
      fi
    fi
  else
    tu="${USER:-}"
  fi

  # Final fallback: first non-root home dir owner
  if [[ -z "$tu" || "$tu" == "root" ]]; then
    tu="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1; exit}' /etc/passwd || true)"
  fi

  if [[ -z "$tu" || "$tu" == "root" ]]; then
    err "Could not determine a non-root TARGET_USER. Re-run as a normal user or via sudo."
    exit 1
  fi

  echo "$tu"
}

TARGET_USER="$(detect_target_user)"
log "Target user: $TARGET_USER"
log "Script directory: $SCRIPT_DIR"

run_root() {
  # Run a command with root privileges without spawning interactive shells
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    if need_cmd sudo; then
      sudo "$@"
    else
      err "sudo is required to install packages. Install sudo or run as root."
      exit 1
    fi
  fi
}

detect_pkg_mgr() {
  if need_cmd apt-get; then echo "apt"; return; fi
  if need_cmd dnf; then echo "dnf"; return; fi
  if need_cmd pacman; then echo "pacman"; return; fi
  echo "unknown"
}

enable_docker_service() {
  if need_cmd systemctl; then
    run_root systemctl enable --now docker >/dev/null 2>&1 || true
    run_root systemctl restart docker >/dev/null 2>&1 || true
  elif need_cmd service; then
    run_root service docker start >/dev/null 2>&1 || true
  fi

  # Wait briefly for the daemon
  local i
  for i in {1..20}; do
    if need_cmd docker && run_root docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  warn "Docker daemon may not be running yet. If containers fail to start, check your init system."
  return 0
}

install_deps_apt() {
  log "Installing dependencies via apt-get…"
  run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg lsb-release git unzip

  # Docker Engine + Compose plugin from distro repos
  if ! need_cmd docker; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  fi
  # docker compose v2 plugin
  if ! (docker compose version >/dev/null 2>&1); then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
  fi

  enable_docker_service
}

install_deps_dnf() {
  log "Installing dependencies via dnf…"
  run_root dnf -y install ca-certificates curl git unzip
  run_root dnf -y install docker docker-compose-plugin || run_root dnf -y install docker

  enable_docker_service
}

install_deps_pacman() {
  log "Installing dependencies via pacman…"
  run_root pacman -Sy --noconfirm ca-certificates curl git unzip

  # Arch usually provides docker and either docker-compose (standalone) or compose plugin
  run_root pacman -S --noconfirm docker || true
  # Prefer plugin if available; otherwise docker-compose
  run_root pacman -S --noconfirm docker-compose || true

  enable_docker_service
}

ensure_docker_compose_available() {
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose v2 is available."
    return 0
  fi

  # Fallback: try legacy docker-compose command if installed
  if need_cmd docker-compose; then
    warn "Using legacy docker-compose (v1) command is available, but this repo expects 'docker compose'."
    warn "Consider installing the Compose v2 plugin for your distro."
    return 0
  fi

  err "Docker Compose is not available (neither 'docker compose' nor 'docker-compose')."
  exit 1
}

ensure_docker_group_access() {
  log "Ensuring docker group access for $TARGET_USER…"
  run_root groupadd -f docker
  run_root usermod -aG docker "$TARGET_USER"

  # Ensure docker socket group is docker (common, but not guaranteed)
  if [[ -S /var/run/docker.sock ]]; then
    run_root chgrp docker /var/run/docker.sock || true
    run_root chmod 660 /var/run/docker.sock || true
  fi
}

maybe_unzip_repo() {
  # If someone only has open-radar.zip and not the expanded repo, unpack it
  if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" && -f "$SCRIPT_DIR/open-radar.zip" ]]; then
    log "Found open-radar.zip without an extracted repo; unzipping…"
    run_root apt-get install -y unzip >/dev/null 2>&1 || true
    unzip -o "$SCRIPT_DIR/open-radar.zip" -d "$SCRIPT_DIR"
  fi
}

autostart_stack_if_present() {
  if [[ "$AUTO_START" != "1" ]]; then
    log "OPEN_RADAR_AUTOSTART=0, skipping autostart."
    return 0
  fi

  if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    warn "No docker-compose.yml found in $SCRIPT_DIR; skipping autostart."
    return 0
  fi

  # Ensure .env exists
  if [[ ! -f "$SCRIPT_DIR/.env" && -f "$SCRIPT_DIR/.env.example" ]]; then
    log "Creating .env from .env.example…"
    cp -n "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  fi

  ensure_docker_compose_available

  log "Starting Open Radar containers (detached)…"
  # Run compose under a fresh login shell for TARGET_USER so docker group membership is effective immediately
  run_root su - "$TARGET_USER" -c "cd '$SCRIPT_DIR' && docker compose up --build -d"

  log "Open Radar is starting."
  log "UI:  http://localhost:5173"
  log "API: http://localhost:8000/api/health"
}

main() {
  local pm
  pm="$(detect_pkg_mgr)"
  case "$pm" in
    apt) install_deps_apt ;;
    dnf) install_deps_dnf ;;
    pacman) install_deps_pacman ;;
    *)
      err "Unsupported distro/package manager. Install manually: docker + docker compose + git + unzip + curl."
      exit 1
      ;;
  esac

  ensure_docker_group_access
  maybe_unzip_repo
  autostart_stack_if_present

  log "Install complete."
  # Note: Your *current* shell might not immediately reflect docker group changes.
  # Autostart is executed in a fresh login shell for $TARGET_USER, so it works immediately.
}

main "$@"
