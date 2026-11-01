#!/usr/bin/env bash
set -euo pipefail

# WSL を開発用途に絞るため、常駐不要なサービスを止める。再実行しても同じ状態になる。
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

disable_units() {
  for unit in "$@"; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      systemctl disable --now "$unit"
      printf '停止: %s\n' "$unit"
    fi
  done
}

# Docker は docker.socket 経由で、docker コマンドの初回実行時に起動させる。
disable_units docker.service containerd.service
systemctl enable --now docker.socket

# Ubuntu Pro・Landscape・クラッシュ報告は WSL の開発用途では使わない。
disable_units landscape-client.service ubuntu-advantage.service ua-reboot-cmds.service \
  wsl-pro.service apport.service apport-forward.socket

# Ghostty は VS Code 拡張へ移行したため削除する。他に snap アプリがなければ snapd も止める。
if command -v snap >/dev/null 2>&1; then
  if snap list ghostty >/dev/null 2>&1; then
    snap remove ghostty
  fi
  remaining="$(snap list 2>/dev/null | awk 'NR > 1 && $1 !~ /^(core[0-9]*|snapd|bare)$/ { print $1 }')"
  if [ -z "$remaining" ]; then
    disable_units snapd.service snapd.socket snapd.seeded.service
  else
    printf 'snap アプリが残っているため snapd は維持します: %s\n' "$(echo "$remaining" | tr '\n' ' ')"
  fi
fi
