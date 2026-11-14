#!/usr/bin/env bash
# dev ディストリ（エージェントを動かす境界）の root 作業をまとめて行う。
# admin（今の Ubuntu-24.04）を export → import で複製した直後に、Windows 側から次のように実行する:
#   wsl -d dev -u root -- bash /home/issei/dotfiles/wsl/dev/setup-dev-distro.sh --distro dev
# 手順の全体と理由は docs/wsl-dev-distro.md。何度実行しても同じ状態になる。
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-dev-distro.sh --distro NAME [--user USER] [--windows-user USER]

--distro        このスクリプトを実行しているディストリの名前（WSL_DISTRO_NAME と一致しないと止める。
                admin で誤って実行しないための確認）
--user          dev の作業ユーザー（既定 issei）。sudo・docker を外し、ログインの既定ユーザーにする
--windows-user  Windows のユーザー名（既定 issei）。VS Code 用の読み取り専用 mount に使う
EOF
}

die() {
  printf 'setup-dev-distro: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

distro=""
user="issei"
windows_user="issei"
while (($#)); do
  case "$1" in
    --distro|--user|--windows-user)
      (($# >= 2)) || die "$1 に値を指定してください"
      case "$1" in
        --distro) distro="$2" ;;
        --user) user="$2" ;;
        --windows-user) windows_user="$2" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$distro" ]] || { usage >&2; exit 2; }
((EUID == 0)) || die 'root で実行してください（Windows 側から wsl -d <distro> -u root -- bash ...）'
[[ "${WSL_DISTRO_NAME:-}" == "$distro" ]] \
  || die "WSL_DISTRO_NAME が '${WSL_DISTRO_NAME:-}' です。--distro '$distro' のディストリの中で実行してください"
id "$user" >/dev/null 2>&1 || die "ユーザーがいません: $user"
# fstab は空白で区切るため、空白や特殊文字を含む Windows ユーザー名は扱わない。
[[ "$windows_user" =~ ^[A-Za-z0-9._-]+$ ]] || die "Windows ユーザー名に使えない文字があります: $windows_user"

backup_dir="/root/dotfiles-dev-setup-backup/$(date +%Y%m%d%H%M%S)"
backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$backup_dir"
  cp -a "$1" "$backup_dir/"
}

step '役割の印 /etc/dotfiles-role'
# hc の起動ラッパーはこの印が dev のときだけ権限確認なしで起動する。作業ユーザーは root になれないので書き換えられない。
printf 'dev\n' >/etc/dotfiles-role
chmod 644 /etc/dotfiles-role
echo 'dev'

step '/etc/wsl.conf（Windows のドライブと Windows プログラムの起動を切る）'
backup /etc/wsl.conf
cat >/etc/wsl.conf <<EOF
# dev ディストリ用。dotfiles の wsl/dev/setup-dev-distro.sh が書き込む（docs/wsl-dev-distro.md）。
[boot]
systemd=true

[automount]
# C: などを自動で mount しない。VS Code に必要な 2 ディレクトリだけ /etc/fstab で読み取り専用 mount する。
enabled=false

[interop]
# .exe を起動させない。PATH にも Windows のパスを入れない。
enabled=false
appendWindowsPath=false

[user]
default=$user
EOF
cat /etc/wsl.conf

step '/etc/fstab（VS Code Remote-WSL 用の読み取り専用 mount）'
# WSL 拡張は Windows 側の拡張ディレクトリにある wslServer.sh と、Windows 側に置いたサーバー tarball を使う。
backup /etc/fstab
rootfs_view="$(mktemp -d)"
# automount が有効なまま実行すると /mnt/c は C: で覆われている。mount point は rootfs 自体に作る必要があるので、
# / を再帰なしで bind した場所から作る（C: に書き込まない）。
mount --bind / "$rootfs_view"
trap 'umount "$rootfs_view" 2>/dev/null || true; rmdir "$rootfs_view" 2>/dev/null || true' EXIT
for dir in .vscode/extensions vscode-remote-wsl; do
  windows_path="C:\\Users\\$windows_user\\${dir//\//\\}"
  mount_point="/mnt/c/Users/$windows_user/$dir"
  line="$windows_path $mount_point drvfs ro 0 0"
  grep -qxF "$line" /etc/fstab || printf '%s\n' "$line" >>/etc/fstab
  mkdir -p "$rootfs_view$mount_point"
done
umount "$rootfs_view"
rmdir "$rootfs_view"
trap - EXIT
grep drvfs /etc/fstab

step "作業ユーザー $user から root になる手段を外す"
for group in sudo admin docker lxd; do
  if id -nG "$user" | tr ' ' '\n' | grep -qxF "$group"; then
    gpasswd -d "$user" "$group" >/dev/null
    printf 'グループから外しました: %s\n' "$group"
  fi
done
# sudoers.d にユーザー個別の NOPASSWD などがあると、sudo グループを外しても sudo できる。
shopt -s nullglob
for file in /etc/sudoers.d/*; do
  [[ "$(basename "$file")" != README ]] || continue
  if grep -Eq "(^|[[:space:],])$user([[:space:],=]|$)" "$file"; then
    backup "$file"
    rm -f "$file"
    printf '削除しました（%s に退避）: %s\n' "$backup_dir" "$file"
  fi
done
shopt -u nullglob
if grep -Eq "^[[:space:]]*$user[[:space:]]" /etc/sudoers; then
  die "/etc/sudoers に $user の行があります。visudo で削除してから再実行してください"
fi
visudo -c >/dev/null
# root のパスワードを無効にし、su で root になれないようにする。root は Windows 側の wsl -u root からだけ使う。
passwd -l root >/dev/null
echo "groups: $(id -nG "$user")"

step 'Docker を止める（docker グループは root と同等のため dev では使わない）'
for unit in docker.socket docker.service containerd.service; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    printf '止めました: %s\n' "$unit"
  fi
done

step '複製元と同じ識別子を作り直す'
# export → import で machine-id と各種の鍵がそのまま複製されるため、dev 側で作り直す。
rm -f /etc/machine-id
systemd-machine-id-setup >/dev/null
echo "machine-id: $(cat /etc/machine-id)"
if compgen -G '/etc/ssh/ssh_host_*' >/dev/null; then
  mkdir -p "$backup_dir/ssh"
  mv /etc/ssh/ssh_host_* "$backup_dir/ssh/"
  ssh-keygen -A >/dev/null
  echo 'SSH ホスト鍵を作り直しました'
fi

step 'Claude Code: bypassPermissions の確認ダイアログを出さない'
# hc から起動するセッションは bypassPermissions で動く。初回に確認ダイアログが出ると hc の起動が止まるため、
# ユーザー設定で省く（このキーは --settings からは効かない）。dev の手元の設定だけに入れる。
user_home="$(getent passwd "$user" | cut -d: -f6)"
runuser -u "$user" -- python3 - "$user_home/.claude/settings.json" <<'PYEOF'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
if settings.get("skipDangerousModePermissionPrompt") is True:
    print(f"設定済み: {path}")
else:
    settings["skipDangerousModePermissionPrompt"] = True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"追加しました: {path}")
PYEOF

step 'Tailscale（複製されたノード情報を消す）'
if command -v tailscale >/dev/null 2>&1; then
  systemctl stop tailscaled 2>/dev/null || true
  if [[ -e /var/lib/tailscale/tailscaled.state ]]; then
    mkdir -p "$backup_dir/tailscale"
    mv /var/lib/tailscale/tailscaled.state "$backup_dir/tailscale/"
    echo '複製元のノード情報を退避しました'
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  echo '次に Windows 側から: wsl -d '"$distro"' -u root -- tailscale up --ssh --hostname '"$distro"
else
  echo 'tailscale が入っていません（スマホから使うなら docs/remote-access.md の手順で導入）'
fi

[[ ! -d "$backup_dir" ]] || printf '\n変更前のファイル: %s\n' "$backup_dir"
cat <<EOF

完了。設定を反映するため、Windows 側で次を実行してください:
  wsl --terminate $distro
そのあと作業ユーザーで境界を確認します:
  wsl -d $distro -- bash /home/$user/dotfiles/wsl/dev/verify-dev-boundary.sh
EOF
