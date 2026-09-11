#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$root" config core.hooksPath .githooks
chmod 755 "$root/.githooks/pre-commit"
printf 'Git hook を有効化しました（core.hooksPath=.githooks）。\n'
