#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$HOME/.codex/config.toml"

if [ -e "$target" ]; then
  printf 'Preserved existing %s; compare it with %s when changing portable defaults.\n' "$target" "$root/.codex/config.toml"
else
  install -Dm644 "$root/.codex/config.toml" "$target"
  printf 'Installed %s\n' "$target"
fi
