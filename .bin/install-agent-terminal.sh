#!/usr/bin/env bash
set -euo pipefail

ensure_apt_package() {
  local package="$1"
  if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    sudo apt-get install -y "$package"
  fi
}

sudo apt-get update
ensure_apt_package ca-certificates
ensure_apt_package curl
ensure_apt_package gh
ensure_apt_package make
ensure_apt_package python3

if ! command -v codex >/dev/null 2>&1; then
  if ! command -v npm >/dev/null 2>&1; then
    echo 'Codex requires npm. Install Node.js/mise first, then rerun this command.' >&2
    exit 1
  fi
  npm install --global @openai/codex
fi

if ! command -v herdr >/dev/null 2>&1; then
  curl -fsSL https://herdr.dev/install.sh | sh
fi

if ! command -v ghostty >/dev/null 2>&1; then
  if apt-cache show ghostty >/dev/null 2>&1; then
    ensure_apt_package ghostty
  else
    cat <<'EOF'
Ghostty is not in this Ubuntu release's default apt repository.
Install it through your preferred supported package source, then rerun make doctor.
For the community Ubuntu/Debian package, explicitly opt in with:
  GHOSTTY_INSTALL=community-deb make bootstrap
EOF
    if [ "${GHOSTTY_INSTALL:-}" = "community-deb" ]; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh)"
    fi
  fi
fi
