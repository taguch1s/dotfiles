#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$HOME/.codex/config.toml"

if [ -e "$target" ]; then
  printf '既存の %s は保持しました。移植可能な既定値を変更する場合は %s と比較してください。\n' "$target" "$root/.codex/config.toml"
else
  install -Dm644 "$root/.codex/config.toml" "$target"
  printf '%s を導入しました。\n' "$target"
fi
