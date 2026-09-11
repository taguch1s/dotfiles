#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    printf 'ok   command: %s\n' "$1"
  else
    printf 'FAIL command: %s\n' "$1" >&2
    failures=1
  fi
}

check_link() {
  local relative="$1" target="$HOME/$1" expected="$root/$1"
  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$expected" ]; then
    printf 'ok   link: %s\n' "$relative"
  else
    printf 'FAIL link: %s\n' "$relative" >&2
    failures=1
  fi
}

check_command gh
check_command herdr
check_command codex
check_command ghostty
check_link .config/herdr/config.toml
check_link .config/ghostty/config.ghostty
check_link .local/bin/herdr-codex-status
if [ -f "$HOME/.codex/config.toml" ]; then
  printf 'ok   config: .codex/config.toml\n'
else
  printf 'FAIL config: .codex/config.toml\n' >&2
  failures=1
fi
python3 -m py_compile "$root/.local/bin/herdr-codex-status"
exit "$failures"
