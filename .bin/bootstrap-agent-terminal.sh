#!/usr/bin/env bash
set -euo pipefail

if ! command -v make >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y make
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec make -C "$root" bootstrap
