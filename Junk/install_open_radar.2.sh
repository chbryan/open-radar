#!/usr/bin/env bash
# install_open_radar.sh
# Zero-intervention installer for Open Radar on Linux.
#
# Goals:
# - Works when run as root OR via `sudo bash ...`
# - Installs Docker Engine + a working Compose command on Debian/Ubuntu/Fedora/Arch
# - Enables/starts Docker daemon
# - Ensures the *real* user (not root) can run Docker
# - Autostarts Open Radar (defaults to ON) with no manual steps
#
# Usage:
#   sudo bash install_open_radar.sh
#   # or
#   bash install_open_radar.sh
#
# Controls:
#   OPEN_RADAR_AUTOSTART=1  (default) -> start containers if docker-compose.yml exists next to this script
#   OPEN_RADAR_AUTOSTART=0  -> install only

set -euo pipefail

log()  { echo -e "\033[1;32m[open-radar]\033[0m $*"; }
warn() { echo -e "\033[1;33m[open-radar]\033[0m $*"; }
err()  { echo -e "\033[1;31m[open-radar]\033[0m $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AUTO_START="${OPEN_RADAR_AUTOSTART:-1}"

run_root() {
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

detect_target_user() {
  local tu=""
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    # If invoked via sudo, this is the original user
    tu="${SUDO_USER:-}"
    if [[ -z "$tu" || "$tu" == "root" ]]; then
      # If not via sudo, try logname (usually works in terminals)
      if need_cmd logname; then
        tu="$(logname 2>/dev/null || true)"
      fi
    fi
  else
    tu="${USER:-}"
  fi

  # Final fallback: first non-root account in /etc/passwd
  if [[ -z "$tu" || "$tu" == "root" ]]; then
    tu="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1; exit}' /etc/passwd || true)"
  fi

  if [[ -z "$tu" || "$tu" == "root" ]]; then
    err "Could not determine a non-root TARGET_USER."
    exit 1
  fi

  echo "$tu"
}

TARGET_USER="$(detect_target_user)"

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

  # Wait for the daemon to become responsive
  for _ in {1..30}; do
    if need_cmd docker && run_root docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  warn "Docker daemon might not be fully up yet. We'll continue, but startup may fail if Docker isn't running."
  return 0
}

# -------------------------
# Debian/Ubuntu (apt)
# -------------------------
apt_install() {
  # Install packages without prompting
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null
}

install_deps_apt() {
  log "Installing dependencies via apt-get…"
  run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null

  apt_install ca-certificates curl gnupg lsb-release git unzip

  # Debian (notably trixie) may split docker daemon and client:
  # - docker.io (daemon)
  # - docker-cli (client)
  # We'll install both to be safe.
  if ! need_cmd docker; then
    apt_install docker.io docker-cli containerd runc || apt_install docker.io docker-cli || apt_install docker.io
  else
    # Ensure client exists even if docker is present
    apt_install docker-cli >/dev/null 2>&1 || true
  fi

  # Compose: some Debian/Ubuntu repos don't have docker-compose-plugin, but do have docker-compose (v2).
  if ! (docker compose version >/dev/null 2>&1); then
    if apt_install docker-compose-plugin 2>/dev/null; then
      log "Installed docker-compose-plugin."
    else
      warn "Package docker-compose-plugin not found. Falling back to 'docker-compose' package…"
      if apt_install docker-compose 2>/dev/null; then
        log "Installed docker-compose."
      else
        warn "Could not install docker-compose from apt. Will attempt manual Compose plugin install."
        manual_install_compose_plugin
      fi
    fi
  fi

  enable_docker_service
}

# -------------------------
# Fedora/RHEL (dnf)
# -------------------------
install_deps_dnf() {
  log "Installing dependencies via dnf…"
  run_root dnf -y install ca-certificates curl git unzip >/dev/null

  # Prefer plugin package if available
  run_root dnf -y install docker docker-compose-plugin >/dev/null 2>&1 || run_root dnf -y install docker >/dev/null

  enable_docker_service
}

# -------------------------
# Arch (pacman)
# -------------------------
install_deps_pacman() {
  log "Installing dependencies via pacman…"
  run_root pacman -Sy --noconfirm ca-certificates curl git unzip >/dev/null

  run_root pacman -S --noconfirm docker >/dev/null 2>&1 || true
  # Arch uses docker-compose (standalone). Newer systems may support plugin too; either is fine.
  run_root pacman -S --noconfirm docker-compose >/dev/null 2>&1 || true

  enable_docker_service
}

# -------------------------
# Compose availability
# -------------------------
compose_cmd_detect() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  if need_cmd docker-compose; then
    echo "docker-compose"
    return 0
  fi
  return 1
}

manual_install_compose_plugin() {
  # Installs Compose CLI plugin to /usr/local/lib/docker/cli-plugins for system-wide use.
  # This is an automated fallback when packages are missing.
  #
  # NOTE: This fetches from GitHub releases. If your environment blocks GitHub, this will fail.
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l|armv7) arch="armv7" ;;
    *) warn "Unknown arch '$arch' for manual compose install; skipping."; return 0 ;;
  esac

  # Pick a recent Compose v2 release. This is just a fallback; distro packages are preferred.
  # If this ever breaks, update the version string here.
  local version="v2.29.7"
  local url="https://github.com/docker/compose/releases/download/${version}/docker-compose-linux-${arch}"

  log "Manual install: Docker Compose plugin ${version} for ${arch}…"
  run_root mkdir -p /usr/local/lib/docker/cli-plugins
  run_root curl -fsSL "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose
  run_root chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}

ensure_docker_group_access() {
  log "Ensuring docker group access for $TARGET_USER…"
  run_root groupadd -f docker
  run_root usermod -aG docker "$TARGET_USER"

  # Fix docker.sock group when possible (helps on some setups)
  if [[ -S /var/run/docker.sock ]]; then
    run_root chgrp docker /var/run/docker.sock || true
    run_root chmod 660 /var/run/docker.sock || true
  fi
}

ensure_repo_ready() {
  # Ensure .env exists if this is an extracted repo
  if [[ -f "$SCRIPT_DIR/.env.example" && ! -f "$SCRIPT_DIR/.env" ]]; then
    log "Creating .env from .env.example…"
    cp -n "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  fi
}

autostart_stack() {
  [[ "$AUTO_START" == "1" ]] || { log "OPEN_RADAR_AUTOSTART=0, skipping autostart."; return 0; }

  if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    warn "No docker-compose.yml found in $SCRIPT_DIR; skipping autostart."
    return 0
  fi

  ensure_repo_ready

  # Start containers in a *fresh login shell* for TARGET_USER so group membership is effective immediately.
  log "Starting Open Radar containers (detached)…"
  run_root su - "$TARGET_USER" -c "
    set -e
    cd '$SCRIPT_DIR'
    if docker compose version >/dev/null 2>&1; then
      DC='docker compose'
    elif command -v docker-compose >/dev/null 2>&1; then
      DC='docker-compose'
    else
      echo '[open-radar] ERROR: Docker Compose not found.' >&2
      exit 1
    fi
    \$DC up --build -d
    \$DC ps
  "

  log "Open Radar is running (or starting)."
  log "UI:  http://localhost:5173"
  log "API: http://localhost:8000/api/health"
}

main() {
  log "Target user: $TARGET_USER"
  log "Script directory: $SCRIPT_DIR"

  local pm
  pm="$(detect_pkg_mgr)"
  case "$pm" in
    apt) install_deps_apt ;;
    dnf) install_deps_dnf ;;
    pacman) install_deps_pacman ;;
    *)
      err "Unsupported distro/package manager. Install manually: docker + compose + git + unzip + curl."
      exit 1
      ;;
  esac

  # If compose still isn't available, try manual plugin install (as last resort)
  if ! compose_cmd_detect >/dev/null 2>&1; then
    warn "Compose not available after package install. Attempting manual Compose plugin install…"
    manual_install_compose_plugin
  fi

  # Validate compose exists now
  if ! compose_cmd_detect >/dev/null 2>&1; then
    err "Docker Compose still not available. Please report your distro details and output of: apt-cache search docker-compose"
    exit 1
  fi

  ensure_docker_group_access
  autostart_stack

  log "Install complete."
}

main "$@"
