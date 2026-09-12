#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$root/.bin/doctor-agent-terminal.sh"
bash "$root/tests/test_herdr_codex_orchestrate.sh"
git -C "$root" diff --check

# 既知の認証情報形式を管理対象ファイルから検出する。検出時はコミットを止める。
if git -C "$root" grep -nEI \
  '(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,})' -- . \
  ':!docs/**'; then
  echo 'NG    認証情報らしき値を検出しました。リポジトリ外のローカル設定へ移してください。' >&2
  exit 1
fi

echo 'OK    管理対象と秘密情報の検査'
