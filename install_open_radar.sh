#!/usr/bin/env bash
# install_open_radar.sh
# Zero-intervention installer for Open Radar on Linux (Linux-first, Debian-friendly).
#
# Features:
# - Works via sudo or as root
# - Installs Docker engine + a working Compose command
# - Avoids interactive prompts (needrestart, conffiles, etc.)
# - Handles dpkg/apt locks (waits; stops apt-daily if it's holding locks)
# - Adds the *real* user to docker group and autostarts Open Radar immediately

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
    if need_cmd sudo; then sudo "$@"; else err "sudo required"; exit 1; fi
  fi
}

detect_target_user() {
  local tu=""
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    tu="${SUDO_USER:-}"
    if [[ -z "$tu" || "$tu" == "root" ]]; then
      if need_cmd logname; then tu="$(logname 2>/dev/null || true)"; fi
    fi
  else
    tu="${USER:-}"
  fi
  if [[ -z "$tu" || "$tu" == "root" ]]; then
    tu="$(awk -F: '($3>=1000)&&($1!="nobody"){print $1; exit}' /etc/passwd || true)"
  fi
  [[ -n "$tu" && "$tu" != "root" ]] || { err "Could not determine non-root TARGET_USER"; exit 1; }
  echo "$tu"
}

TARGET_USER="$(detect_target_user)"

detect_pkg_mgr() {
  if need_cmd apt-get; then echo "apt"; return; fi
  if need_cmd dnf; then echo "dnf"; return; fi
  if need_cmd pacman; then echo "pacman"; return; fi
  echo "unknown"
}

# -----------------------------
# Lock handling (Debian/apt)
# -----------------------------
dpkg_lock_holders() {
  # Returns PIDs holding dpkg/apt locks (if any), else empty
  local pids=""
  for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
    if [[ -e "$f" ]]; then
      pids+=" $(fuser "$f" 2>/dev/null || true)"
    fi
  done
  echo "$pids" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

stop_apt_daily_if_running() {
  # If apt-daily services are running (common on Debian), stop them to release locks.
  if need_cmd systemctl; then
    run_root systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    run_root systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  fi
}

wait_for_apt_locks() {
  # Wait up to 5 minutes for locks. If apt-daily is the holder, stop it and keep going.
  local max_s=300
  local waited=0
  while true; do
    local holders
    holders="$(dpkg_lock_holders)"
    if [[ -z "$holders" ]]; then
      return 0
    fi

    # See if holders include apt.systemd.daily / unattended upgrades; try stopping those
    if ps -p ${holders// /,} -o comm= 2>/dev/null | grep -qiE 'apt|unattended|dpkg'; then
      warn "Detected dpkg/apt lock holders (pids: $holders). Attempting to stop apt-daily/upgrade if applicable…"
      stop_apt_daily_if_running
    fi

    if (( waited >= max_s )); then
      err "dpkg/apt locks still held after ${max_s}s (pids: $holders)."
      err "Rebooting usually clears this if a background upgrade is stuck."
      exit 1
    fi

    warn "Waiting for dpkg/apt locks to clear… (${waited}s)"
    sleep 5
    waited=$((waited + 5))
  done
}

# -----------------------------
# Debian/Ubuntu install (apt)
# -----------------------------
apt_install() {
  # Safe apt install: no prompts, retries, timeouts, conffile defaults, visible progress
  wait_for_apt_locks

  run_root env \
    DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE=a \
    APT_LISTCHANGES_FRONTEND=none \
    apt-get install -y --no-install-recommends \
      -o Dpkg::Use-Pty=0 \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confnew \
      -o Acquire::Retries=3 \
      -o Acquire::http::Timeout=20 \
      -o Acquire::https::Timeout=20 \
      "$@"
}

apt_update() {
  wait_for_apt_locks
  run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20
}

enable_docker_service() {
  if need_cmd systemctl; then
    run_root systemctl enable --now docker >/dev/null 2>&1 || true
    run_root systemctl restart docker >/dev/null 2>&1 || true
  elif need_cmd service; then
    run_root service docker start >/dev/null 2>&1 || true
  fi

  for _ in {1..30}; do
    if need_cmd docker && run_root docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  warn "Docker daemon might not be fully up yet; continuing."
}

compose_cmd_detect() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose"; return 0; fi
  if need_cmd docker-compose; then echo "docker-compose"; return 0; fi
  return 1
}

manual_install_compose_plugin() {
  # Last resort: install compose plugin binary to /usr/local/lib/docker/cli-plugins
  local arch version url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l|armv7) arch="armv7" ;;
    *) warn "Unknown arch '$arch'; skipping manual compose install."; return 0 ;;
  esac

  version="v2.29.7"
  url="https://github.com/docker/compose/releases/download/${version}/docker-compose-linux-${arch}"

  warn "Installing Docker Compose plugin manually (${version}, ${arch})…"
  run_root mkdir -p /usr/local/lib/docker/cli-plugins
  run_root curl -fsSL "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose
  run_root chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}

install_deps_apt() {
  log "Installing dependencies via apt-get…"
  apt_update

  apt_install ca-certificates curl gnupg lsb-release git unzip

  # Docker engine/client packages (Debian names vary slightly across versions)
  if ! need_cmd docker; then
    apt_install docker.io docker-cli containerd runc || apt_install docker.io docker-cli || apt_install docker.io
  else
    apt_install docker-cli >/dev/null 2>&1 || true
  fi

  enable_docker_service

  # Compose packages differ by distro release. Try in best order.
  if ! (docker compose version >/dev/null 2>&1) && ! need_cmd docker-compose; then
    log "Installing Docker Compose (trying plugin/v2/v1 packages)…"
    if apt_install docker-compose-plugin; then
      log "Installed docker-compose-plugin."
    else
      warn "Package docker-compose-plugin not found. Trying docker-compose-v2…"
      if apt_install docker-compose-v2; then
        log "Installed docker-compose-v2."
      else
        warn "Package docker-compose-v2 not found. Falling back to 'docker-compose' package…"
        if apt_install docker-compose; then
          log "Installed docker-compose."
        else
          warn "Could not install Compose from apt. Falling back to manual Compose plugin install…"
          manual_install_compose_plugin
        fi
      fi
    fi
  fi

  # Final validation
  if ! compose_cmd_detect >/dev/null 2>&1; then
    err "Docker Compose is still not available after install."
    exit 1
  fi
}

# -----------------------------
# Other distros (kept simple)
# -----------------------------
install_deps_dnf() {
  log "Installing dependencies via dnf…"
  run_root dnf -y install ca-certificates curl git unzip
  run_root dnf -y install docker docker-compose-plugin || run_root dnf -y install docker
  enable_docker_service
}

install_deps_pacman() {
  log "Installing dependencies via pacman…"
  run_root pacman -Sy --noconfirm ca-certificates curl git unzip
  run_root pacman -S --noconfirm docker || true
  run_root pacman -S --noconfirm docker-compose || true
  enable_docker_service
}

ensure_docker_group_access() {
  log "Ensuring docker group access for $TARGET_USER…"
  run_root groupadd -f docker
  run_root usermod -aG docker "$TARGET_USER"
  if [[ -S /var/run/docker.sock ]]; then
    run_root chgrp docker /var/run/docker.sock || true
    run_root chmod 660 /var/run/docker.sock || true
  fi
}

ensure_repo_ready() {
  if [[ -f "$SCRIPT_DIR/.env.example" && ! -f "$SCRIPT_DIR/.env" ]]; then
    log "Creating .env from .env.example…"
    cp -n "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  fi
}

autostart_stack() {
  [[ "$AUTO_START" == "1" ]] || { log "OPEN_RADAR_AUTOSTART=0, skipping autostart."; return 0; }
  [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || { warn "No docker-compose.yml found; skipping autostart."; return 0; }

  ensure_repo_ready

  local dc
  dc="$(compose_cmd_detect)" || { err "Compose not found"; exit 1; }

  log "Starting Open Radar containers (detached) using: $dc"
  # Run in a *fresh login shell* for the user so group membership works immediately.
  run_root su - "$TARGET_USER" -c "cd '$SCRIPT_DIR' && $dc up --build -d && $dc ps"

  log "Open Radar should now be up."
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
    *) err "Unsupported distro/package manager."; exit 1 ;;
  esac

  ensure_docker_group_access
  autostart_stack
  log "Install complete."
}

main "$@"
