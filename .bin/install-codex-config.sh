#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$root/.bin/manage-dotfiles-configs.py" install
exec python3 "$root/.bin/manage-dotfiles-configs.py" sync
