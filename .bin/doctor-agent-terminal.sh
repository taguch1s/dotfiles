#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    printf 'OK   コマンド: %s\n' "$1"
  else
    printf 'NG   コマンド: %s\n' "$1" >&2
    failures=1
  fi
}

check_command gh
check_command herdr
check_command codex
check_command ghostty
python3 "$root/.bin/manage-dotfiles-configs.py" doctor || failures=1
python3 -m py_compile "$root/.local/bin/herdr-codex-status"
exit "$failures"
