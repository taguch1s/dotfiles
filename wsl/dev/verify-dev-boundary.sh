#!/usr/bin/env bash
# dev ディストリの境界が効いているかを、作業ユーザーの立場で確かめる（root 不要、何も変更しない）。
# setup-dev-distro.sh のあと wsl --terminate してから実行する。手順は docs/wsl-dev-distro.md。
set -uo pipefail

failures=0
ok() { printf 'OK    %s\n' "$*"; }
ng() { printf 'NG    %s\n' "$*"; failures=$((failures + 1)); }

if [[ "$(cat /etc/dotfiles-role 2>/dev/null)" == dev ]]; then
  ok '役割の印: /etc/dotfiles-role = dev'
else
  ng '役割の印 /etc/dotfiles-role が dev ではない'
fi

((EUID != 0)) || ng 'root で実行している（作業ユーザーで実行してください）'

groups=" $(id -nG) "
for group in sudo admin docker lxd; do
  if [[ "$groups" == *" $group "* ]]; then
    ng "作業ユーザーが $group グループに入っている"
  fi
done
[[ "$groups" =~ \ (sudo|admin|docker|lxd)\  ]] || ok "root 相当のグループに入っていない（$(id -nG)）"

if sudo -n true 2>/dev/null; then
  ng 'パスワードなしで sudo できる'
else
  ok 'パスワードなしの sudo はできない'
fi

if [[ ":$PATH:" == *:/mnt/* ]]; then
  ng "PATH に Windows のパスが入っている: $PATH"
else
  ok 'PATH に Windows のパスがない'
fi

interop_enabled=0
for entry in /proc/sys/fs/binfmt_misc/WSLInterop*; do
  [[ -e "$entry" ]] || continue
  [[ "$(head -n1 "$entry" 2>/dev/null)" == enabled ]] && interop_enabled=1
done
if ((interop_enabled)); then
  ng '.exe を起動する binfmt（WSLInterop）が有効'
else
  ok '.exe を起動する binfmt（WSLInterop）がない'
fi

mounts="$(grep ' drvfs ' /etc/fstab 2>/dev/null | awk '{print $2}')"

# /mnt の下に見えてよいのは、/mnt/wsl（全ディストリ共有の tmpfs）と、fstab の mount point およびその親だけ。
allowed() {
  local path="$1" mount_point
  [[ "$path" == /mnt/wsl ]] && return 0
  for mount_point in $mounts; do
    [[ "$mount_point" == "$path" || "$mount_point" == "$path"/* ]] && return 0
  done
  return 1
}
unexpected=()
while IFS= read -r path; do
  allowed "$path" || unexpected+=("$path")
done < <(find /mnt -mindepth 1 \( -path /mnt/wsl $(printf -- '-o -path %s ' $mounts) \) -prune -print -o -print 2>/dev/null)
if ((${#unexpected[@]})); then
  ng "/mnt に想定外のものが見える: ${unexpected[*]:0:5}"
else
  ok '/mnt に Windows のドライブが見えない（VS Code 用の mount だけ）'
fi
if [[ -z "$mounts" ]]; then
  ng '/etc/fstab に VS Code 用の drvfs mount がない'
fi
for mount_point in $mounts; do
  if ! mountpoint -q "$mount_point"; then
    ng "mount されていない: $mount_point"
  elif touch "$mount_point/.dotfiles-write-test" 2>/dev/null; then
    rm -f "$mount_point/.dotfiles-write-test"
    ng "書き込める: $mount_point"
  else
    ok "読み取り専用で mount されている: $mount_point"
  fi
done

if python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("skipDangerousModePermissionPrompt") is True else 1)' \
  "$HOME/.claude/settings.json" 2>/dev/null; then
  ok 'Claude Code: bypassPermissions の確認ダイアログを省く設定がある'
else
  ng "$HOME/.claude/settings.json に skipDangerousModePermissionPrompt: true がない（hc の起動が確認ダイアログで止まる）"
fi

if ((failures)); then
  printf '\n%d 件の NG があります。docs/wsl-dev-distro.md を確認してください。\n' "$failures"
  exit 1
fi
printf '\n境界の確認はすべて OK です。\n'
