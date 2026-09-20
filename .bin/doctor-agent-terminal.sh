#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

if [[ "${1:-}" == "--worktree-safe" ]]; then
  doctor_args=(--auto)
elif [[ -n "${1:-}" ]]; then
  printf 'Usage: %s [--worktree-safe]\n' "$0" >&2
  exit 2
else
  doctor_args=()
fi

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
python3 "$root/.bin/manage-dotfiles-configs.py" doctor "${doctor_args[@]}" || failures=1
python3 -m py_compile "$root/.local/bin/herdr-codex-status"
bash -n "$root/.local/bin/herdr-codex-orchestrate"
exit "$failures"
