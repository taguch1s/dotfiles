#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timestamp="$(date +%Y%m%d%H%M%S)"

link_file() {
  local relative="$1" source="$root/$1" target="$HOME/$1"
  mkdir -p "$(dirname "$target")"
  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$source" ]; then
    return
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    mv "$target" "$target.dotfiles-backup-$timestamp"
  fi
  ln -s "$source" "$target"
}

link_file .config/herdr/config.toml
link_file .config/ghostty/config.ghostty
link_file .local/bin/herdr-codex-status
chmod 755 "$root/.local/bin/herdr-codex-status"
