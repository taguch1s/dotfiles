#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
  printf 'Windows 連携が使えません。windows/dev-mode.ps1 を Windows 側へ手動でコピーし、-Mode Install で実行してください。\n' >&2
  exit 1
fi

# スタートメニューのショートカットはこの配置先を指すため、リポジトリの場所に依存させない。
local_app_data="$(wslpath "$(cmd.exe /C 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')")"
target="$local_app_data/dotfiles/dev-mode.ps1"
install -Dm644 "$root/windows/dev-mode.ps1" "$target"
printf '%s を導入しました。\n' "$target"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$target")" -Mode Install
