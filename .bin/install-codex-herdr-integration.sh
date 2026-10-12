#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

if command -v herdr >/dev/null 2>&1; then
  if command -v codex >/dev/null 2>&1; then
    herdr integration install codex
  fi
  if command -v claude >/dev/null 2>&1; then
    herdr integration install claude
  fi
fi
