#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sudo install -Dm644 "$root/wsl/etc/wsl.conf" /etc/wsl.conf

if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  windows_home="$(wslpath "$(cmd.exe /C 'echo %USERPROFILE%' | tr -d '\r')")"
  target="$windows_home/.wslconfig"
  if [ -e "$target" ]; then
    cp "$target" "$target.dotfiles-backup-$(date +%Y%m%d%H%M%S)"
  fi
  install -Dm644 "$root/windows/.wslconfig" "$target"
  printf '%s を導入しました。\n' "$target"
else
  printf '/etc/wsl.conf を導入しました。windows/.wslconfig は Windows のユーザープロファイルへ手動でコピーしてください。\n'
fi
