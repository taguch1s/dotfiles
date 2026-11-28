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

# /mnt の下に見えてよいのは、/mnt/wsl（全ディストリ共有の tmpfs）、/mnt/wslg（WSLg の tmpfs とシステム領域。
# Herdr app を dev の WSLg で使うため）、fstab の mount point およびその親だけ。
# /mnt/wslg の中は辿らず、Windows のファイルを見せる mount（9p・drvfs・virtiofs）がないことだけを下で確かめる。
allowed() {
  local path="$1" mount_point
  [[ "$path" == /mnt/wsl || "$path" == /mnt/wslg ]] && return 0
  for mount_point in $mounts; do
    [[ "$mount_point" == "$path" || "$mount_point" == "$path"/* ]] && return 0
  done
  return 1
}
unexpected=()
while IFS= read -r path; do
  allowed "$path" || unexpected+=("$path")
done < <(find /mnt -mindepth 1 \( -path /mnt/wsl -o -path /mnt/wslg $(printf -- '-o -path %s ' $mounts) \) -prune -print -o -print 2>/dev/null)
while read -r _ mount_point fstype _; do
  case "$mount_point" in /mnt/wslg|/mnt/wslg/*) ;; *) continue ;; esac
  case "$fstype" in 9p|drvfs|virtiofs) unexpected+=("$mount_point($fstype)") ;; esac
done </proc/self/mounts
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

# GCP: dev にはユーザー本人の gcloud の資格情報を置かない。gcloud の設定ごとに、あってよい service account を
# 1 つに決める（docs/infra-credentials.md）。既定の ~/.config/gcloud は読み取り専用の dev-infra-viewer だけ、
# hc-remote の専用の設定（CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud）は hc-remote-runner だけ。
gcp_project="${DEV_GCP_PROJECT:-first-impression-490413}"
gcloud_allowed() {  # gcloud_allowed <gcloud の設定ディレクトリ>: あってよい SA のメールアドレス
  case "$1" in
    "$HOME/.config/gcloud") printf 'dev-infra-viewer@%s.iam.gserviceaccount.com' "$gcp_project" ;;
    "$HOME/.config/hc-remote/gcloud") printf 'hc-remote-runner@%s.iam.gserviceaccount.com' "$gcp_project" ;;
  esac
}
for gcloud_dir in "$HOME/.config/gcloud" "$HOME/.config/hc-remote/gcloud"; do
  [[ -d "$gcloud_dir" ]] || continue
  allowed_sa="$(gcloud_allowed "$gcloud_dir")"
  user_accounts="$(python3 - "$gcloud_dir" "$allowed_sa" <<'PY' 2>&1
import json, os, sqlite3, sys

root, allowed = sys.argv[1], sys.argv[2]
found = set()
for name in ("credentials.db", "access_tokens.db"):
    path = os.path.join(root, name)
    if not os.path.exists(path):
        continue
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        table = "credentials" if name == "credentials.db" else "access_tokens"
        # access_tokens.db にはアカウント以外（ADC のキャッシュのハッシュ）も入るので、メールアドレスの形だけを見る
        found.update(row[0] for row in db.execute(f"SELECT account_id FROM {table}") if "@" in row[0])
    except sqlite3.Error as error:
        found.add(f"{name} を読めない（{error}）")
legacy = os.path.join(root, "legacy_credentials")
if os.path.isdir(legacy):
    found.update(os.listdir(legacy))
adc = os.path.join(root, "application_default_credentials.json")
if os.path.exists(adc):
    try:
        kind = json.load(open(adc)).get("type")
    except (OSError, ValueError):
        kind = "unreadable"
    if kind != "service_account":
        found.add(f"application_default_credentials.json（type={kind}）")
    else:
        try:
            found.add(json.load(open(adc)).get("client_email") or "application_default_credentials.json（client_email なし）")
        except (OSError, ValueError):
            found.add("application_default_credentials.json（読めない）")
users = sorted(a for a in found if not a.endswith(".gserviceaccount.com"))
others = sorted(a for a in found if a.endswith(".gserviceaccount.com") and a != allowed)
# 1 行目: ユーザー本人の資格情報、2 行目: 決めた SA 以外の SA
print(" ".join(users))
print(" ".join(others))
PY
)"
  other_accounts="$(sed -n 2p <<<"$user_accounts")"
  user_accounts="$(sed -n 1p <<<"$user_accounts")"
  if [[ -n "$user_accounts" ]]; then
    ng "gcloud の資格情報にユーザー本人のもの（service account 以外）がある: ${gcloud_dir}: ${user_accounts}"
  elif [[ -n "$other_accounts" ]]; then
    ng "gcloud の資格情報に決めた SA（${allowed_sa}）以外の service account がある: ${gcloud_dir}: ${other_accounts}"
  else
    ok "gcloud の資格情報は決めた SA（${allowed_sa}）だけか、ない: ${gcloud_dir}"
  fi
done
[[ -d "$HOME/.config/gcloud" || -d "$HOME/.config/hc-remote/gcloud" ]] || ok 'gcloud の資格情報がない（~/.config/gcloud・~/.config/hc-remote/gcloud）'

# SA の鍵は組織のポリシーで有効期限を強制できないので、古い鍵を警告する（NG にはしない。終了コードは変えない）。
# 日数はファイルの更新時刻（admin から渡した日）で数える。作り直しの手順は docs/infra-credentials.md。
key_max_age_days="${DEV_KEY_MAX_AGE_DAYS:-90}"
if [[ ! "$key_max_age_days" =~ ^[0-9]+$ ]]; then
  printf 'WARN  DEV_KEY_MAX_AGE_DAYS が整数ではないので 90 日で確かめる: %s\n' "$key_max_age_days"
  key_max_age_days=90
fi
for key_path in "$HOME/.config/dev-infra/gcp-viewer-key.json" "$HOME/.config/hc-remote/gcp-key.json"; do
  [[ -f "$key_path" ]] || continue
  key_age_days=$((($(date +%s) - $(stat -c %Y "$key_path")) / 86400))
  if ((key_age_days > key_max_age_days)); then
    printf 'WARN  SA の鍵が %s 日前のもの（%s 日より古い）: %s。docs/infra-credentials.md の「鍵の作り直し」で作り直す\n' \
      "$key_age_days" "$key_max_age_days" "$key_path"
  else
    ok "SA の鍵は ${key_age_days} 日前のもの（${key_max_age_days} 日以内）: ${key_path}"
  fi
done

if ((failures)); then
  printf '\n%d 件の NG があります。docs/wsl-dev-distro.md を確認してください。\n' "$failures"
  exit 1
fi
printf '\n境界の確認はすべて OK です。\n'
