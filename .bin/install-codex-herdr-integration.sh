#!/usr/bin/env bash
set -euo pipefail

if command -v herdr >/dev/null 2>&1 && command -v codex >/dev/null 2>&1; then
  herdr integration install codex
fi
