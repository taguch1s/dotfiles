#!/usr/bin/env bash
set -euo pipefail

# スマホからの遠隔操作中に Windows がアイドルスリープしないよう、awake-keeper を常駐させる。
# スクリプトと unit のリンクは make link が行う。全体像は docs/remote-access.md

if ! systemctl --user show-environment >/dev/null 2>&1; then
  printf 'systemd のユーザーセッションが使えません。/etc/wsl.conf で systemd=true にして WSL を再起動してください（make wsl）。\n' >&2
  exit 1
fi

systemctl --user daemon-reload
systemctl --user enable --now awake-keeper.service

# ログインセッションが無い間（SSH 切断中など）もユーザーサービスを止めない。
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]]; then
  loginctl enable-linger "$USER" || sudo loginctl enable-linger "$USER"
fi

systemctl --user --no-pager status awake-keeper.service | head -5
printf 'Claude Code の hook が ~/.local/bin/awake-hook を呼んでいるか ~/.claude/settings.json を確認してください。\n'
