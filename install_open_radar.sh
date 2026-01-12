```bash
#!/usr/bin/env bash
# install_open_radar.sh
# Installs everything needed to run Open Radar via Docker Compose on Linux.
# Supports: Debian/Ubuntu, Fedora/RHEL/CentOS (dnf), Arch.
#
# Usage:
#   bash install_open_radar.sh
#
# Optional (after install):
#   unzip open-radar.zip && cd open-radar && cp .env.example .env && docker compose up --build

set -euo pipefail

log() { echo -e "\033[1;32m[open-radar]\033[0m $*"; }
warn() { echo -e "\033[1;33m[open-radar]\033[0m $*"; }
err() { echo -e "\033[1;31m[open-radar]\033[0m $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if need_cmd sudo; then
      SUDO="sudo"
    else
      err "This script needs root privileges. Install sudo or run as root."
      exit 1
    fi
  else
    SUDO=""
  fi
}

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
  else
    DISTRO_ID="unknown"
    DISTRO_LIKE=""
  fi
}

install_debian_like() {
  log "Detected Debian/Ubuntu-like distro."
  $SUDO apt-get update -y
  $SUDO apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    git unzip

  # Prefer distro Docker packages (simple + free). On many distros:
  # - docker.io (engine)
  # - docker-compose-plugin (docker compose v2)
  if ! need_cmd docker; then
    log "Installing Docker Engine (docker.io) and Compose plugin..."
    $SUDO apt-get install -y docker.io docker-compose-plugin
  else
    log "Docker already installed."
    # Ensure compose plugin exists
    if ! docker compose version >/dev/null 2>&1; then
      log "Installing Docker Compose plugin..."
      $SUDO apt-get install -y docker-compose-plugin
    fi
  fi

  $SUDO systemctl enable --now docker || true
}

install_fedora_like() {
  log "Detected Fedora/RHEL/CentOS-like distro."
  # Prefer dnf if available
  if need_cmd dnf; then
    $SUDO dnf -y install \
      ca-certificates curl git unzip \
      docker docker-compose-plugin
    $SUDO systemctl enable --now docker || true
  else
    err "dnf not found; this distro may not be supported by this script."
    exit 1
  fi
}

install_arch_like() {
  log "Detected Arch-like distro."
  if need_cmd pacman; then
    $SUDO pacman -Sy --noconfirm \
      ca-certificates curl git unzip \
      docker docker-compose
    $SUDO systemctl enable --now docker || true
  else
    err "pacman not found; this distro may not be supported by this script."
    exit 1
  fi
}

post_install() {
  # Add current user to docker group for non-root usage
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if getent group docker >/dev/null 2>&1; then
      if id -nG "$USER" | grep -qw docker; then
        log "User '$USER' is already in the docker group."
      else
        log "Adding user '$USER' to the docker group (so Docker works without sudo)..."
        $SUDO usermod -aG docker "$USER"
        warn "You must log out and log back in (or reboot) for docker group changes to take effect."
      fi
    else
      # Some distros create docker group at install time; if not, create it.
      log "Creating docker group and adding user '$USER'..."
      $SUDO groupadd -f docker
      $SUDO usermod -aG docker "$USER"
      warn "You must log out and log back in (or reboot) for docker group changes to take effect."
    fi
  fi

  # Sanity checks
  if ! need_cmd docker; then
    err "Docker installation failed (docker not found in PATH)."
    exit 1
  fi

  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose (v2) is available: $(docker compose version | head -n1)"
  else
    warn "Docker Compose plugin not detected via 'docker compose'."
    warn "Try installing 'docker-compose-plugin' (Debian/Ubuntu) or 'docker-compose-plugin' (Fedora) or 'docker-compose' (Arch)."
  fi

  log "All set."
  echo
  log "Next steps (example):"
  cat <<'EOF'
  # In the directory containing open-radar.zip:
  unzip open-radar.zip
  cd open-radar
  cp .env.example .env
  docker compose up --build
EOF
}

main() {
  require_sudo
  detect_distro

  case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|elementary)
      install_debian_like
      ;;
    fedora|rhel|centos|rocky|almalinux)
      install_fedora_like
      ;;
    arch|manjaro|endeavouros)
      install_arch_like
      ;;
    *)
      # Try to infer via ID_LIKE
      if echo "$DISTRO_LIKE" | grep -qiE 'debian|ubuntu'; then
        install_debian_like
      elif echo "$DISTRO_LIKE" | grep -qiE 'rhel|fedora|centos'; then
        install_fedora_like
      elif echo "$DISTRO_LIKE" | grep -qiE 'arch'; then
        install_arch_like
      else
        err "Unsupported distro: ID=$DISTRO_ID ID_LIKE=$DISTRO_LIKE"
        err "Install manually: docker + docker compose plugin + git + unzip."
        exit 1
      fi
      ;;
  esac

  post_install
}

main "$@"
```

