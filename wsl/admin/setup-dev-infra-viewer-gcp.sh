#!/usr/bin/env bash
# dev ディストリで GCP の構成・状態・ログを読むだけの service account（L0、dev-infra-viewer）を admin で用意する。
# 既定は dry-run（作る SA・付けるロール・外す付与・鍵の場所を表示し、GCP は読み取りしかしない）。
# --apply のときだけ、service account・カスタムロール・IAM の付与・鍵を作る。何度実行しても同じ状態になる。
# 層の考え方は docs/infra-credentials.md、手順は同じ文書の「L0 を用意する」。
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-dev-infra-viewer-gcp.sh [--apply] [--project ID] [--key-dir DIR]

--apply    実際に作る（既定は dry-run で、変更系の gcloud を呼ばない）。dev では拒否する
--project  GCP の project（既定 first-impression-490413）
--key-dir  鍵を置くディレクトリ（既定 ~/.config/dev-infra）。鍵は <dir>/gcp-viewer-key.json（0600）
EOF
}

die() {
  printf 'setup-dev-infra-viewer-gcp: %s\n' "$*" >&2
  exit 1
}

project="first-impression-490413"
key_dir="${HOME}/.config/dev-infra"
apply=0
while (($#)); do
  case "$1" in
    --apply) apply=1; shift ;;
    --project|--key-dir)
      (($# >= 2)) || die "$1 に値を指定してください"
      case "$1" in
        --project) project="$2" ;;
        --key-dir) key_dir="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "不明な引数: $1" ;;
  esac
done

# dev では dry-run（読み取り）だけを動かす。変更（--apply）はユーザー本人の資格情報がある admin でだけ行う
# （docs/infra-credentials.md の原則 3）。dev の gcloud は L0 の SA なので、--apply しても権限で失敗するが、
# gcloud を呼ぶ前に止める。
role_file="${DOTFILES_ROLE_FILE:-/etc/dotfiles-role}"
if ((apply)) && [[ "$(cat "$role_file" 2>/dev/null)" == dev ]]; then
  die "dev ディストリでは --apply しません。dry-run の表示を確かめたら、admin（Ubuntu-24.04）で --apply してください"
fi
command -v gcloud >/dev/null || die "gcloud が見つかりません"

# --- 作るものの定義（dry-run の表示と --apply の実行で同じ値を使う） ---
sa_id="dev-infra-viewer"
sa_email="${sa_id}@${project}.iam.gserviceaccount.com"
member="serviceAccount:${sa_email}"
key_file="${key_dir}/gcp-viewer-key.json"
custom_role="devInfraViewer"

# L0 に付けるロール（ここが唯一の一覧）。外すときは 1 行を消して --apply すると、その付与も外す。
# 各ロールの中身を公式ドキュメントで確かめた日付と結果は docs/infra-credentials.md の「L0 のロール」。
l0_roles=(
  roles/compute.viewer
  roles/run.viewer
  roles/cloudscheduler.viewer
  roles/cloudbuild.builds.viewer
  roles/monitoring.viewer
  roles/logging.viewer
  roles/serviceusage.serviceUsageViewer
  roles/cloudquotas.viewer
  roles/secretmanager.viewer
  "projects/${project}/roles/${custom_role}"
)
# 既定のロールでは広すぎるもの（roles/iam.securityReviewer は logging.privateLogEntries.list を含み、
# roles/artifactregistry.reader はイメージの中身を取り出せる）の代わりに、読み取りだけを並べたカスタムロール。
custom_permissions=(
  resourcemanager.projects.get
  resourcemanager.projects.getIamPolicy
  iam.roles.get
  iam.roles.list
  iam.serviceAccounts.get
  iam.serviceAccounts.list
  iam.serviceAccounts.getIamPolicy
  iam.serviceAccountKeys.get
  iam.serviceAccountKeys.list
  artifactregistry.repositories.get
  artifactregistry.repositories.list
  artifactregistry.dockerimages.get
  artifactregistry.dockerimages.list
  artifactregistry.packages.get
  artifactregistry.packages.list
  artifactregistry.versions.get
  artifactregistry.versions.list
  artifactregistry.tags.get
  artifactregistry.tags.list
)

# 付けない権限・ロール（docs/infra-credentials.md の「付けない権限」）。
# 秘密の値・データの本体・トークンの発行・SA のなりすまし・データアクセスの監査ログ。
forbidden_permissions=(
  secretmanager.versions.access
  storage.objects.get
  iam.serviceAccountKeys.create
  iam.serviceAccounts.getAccessToken
  iam.serviceAccounts.getOpenIdToken
  iam.serviceAccounts.signBlob
  iam.serviceAccounts.signJwt
  iam.serviceAccounts.implicitDelegation
  iam.serviceAccounts.actAs
  logging.privateLogEntries.list
  artifactregistry.repositories.downloadArtifacts
  artifactregistry.files.download
)
forbidden_roles=(roles/viewer roles/editor roles/owner roles/iam.securityReviewer roles/artifactregistry.reader)

# forbidden_permission <permission>: 付けない権限なら 0。変更系（最後の語が create・update・delete・set… で始まる）もすべて含む。
forbidden_permission() {
  local perm="$1" verb="${1##*.}" f
  for f in "${forbidden_permissions[@]}"; do [[ "$perm" == "$f" ]] && return 0; done
  [[ "$verb" =~ ^(create|update|delete|undelete|set) ]] && return 0
  return 1
}

# 定義そのものを先に確かめる（一覧に付けない権限・ロールが入っていたら、何もせずに止める）。
self_check() {
  local role f perm bad=0
  for role in "${l0_roles[@]}"; do
    for f in "${forbidden_roles[@]}"; do
      if [[ "$role" == "$f" ]]; then
        printf 'setup-dev-infra-viewer-gcp: 付けないロールが一覧にある: %s\n' "$role" >&2
        bad=1
      fi
    done
  done
  for perm in "${custom_permissions[@]}"; do
    if forbidden_permission "$perm"; then
      printf 'setup-dev-infra-viewer-gcp: 付けない権限がカスタムロールにある: %s\n' "$perm" >&2
      bad=1
    fi
  done
  return "$bad"
}
self_check || die "ロール・権限の一覧に付けない権限があります。一覧を直してください"

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

# --- 実行の道具（setup-hc-remote-gcp.sh と同じ形） ---
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

section() { printf '\n== %s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
quote_command() {
  local out="" arg
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      out+=" $arg"
    elif [[ "$arg" != *"'"* ]]; then
      out+=" '$arg'"
    else
      out+=" $(printf '%q' "$arg")"
    fi
  done
  printf '%s' "${out# }"
}
# 変更系の gcloud。dry-run では表示だけで呼ばない。
change() {
  if ((apply)); then
    printf '  +   %s\n' "$(quote_command gcloud "$@")"
    gcloud "$@"
  else
    printf '  (dry-run) %s\n' "$(quote_command gcloud "$@")"
  fi
}
# 作ったばかりの service account は IAM に伝わるまで数秒かかり、付与が失敗することがあるので繰り返す。
change_retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    change "$@" && return 0
    ((apply)) || return 0
    ((attempt < 5)) || break
    printf '      失敗したので %s 秒後にやり直す（%s/5）\n' "${DEV_INFRA_SETUP_RETRY_SLEEP:-5}" "$attempt" >&2
    sleep "${DEV_INFRA_SETUP_RETRY_SLEEP:-5}"
  done
  return 1
}
# 読み取り専用の gcloud。dry-run でも今の状態を表示するために呼ぶ。失敗は「無い・確かめられない」として扱う。
read_gcloud() {
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud "$@" 2>/dev/null </dev/null
}

mode_label="dry-run（何も変更しません。実行するには admin で --apply）"
((apply)) && mode_label="apply"
printf 'setup-dev-infra-viewer-gcp: %s\n' "$mode_label"
printf '  project: %s\n' "$project"

# --- 1. 既定のロールの中身を確かめる（ロールは Google が増やすことがあるので毎回見る） ---
section "既定のロールの中身（付けない権限が入っていないか）"
roles_checked=1
for role in "${l0_roles[@]}"; do
  [[ "$role" == roles/* ]] || continue
  if ! perms="$(read_gcloud iam roles describe "$role" --flatten=includedPermissions --format='value(includedPermissions)')" || [[ -z "$perms" ]]; then
    info "${role}: 中身を読めなかった（確かめられない）"
    roles_checked=0
    continue
  fi
  bad=()
  while IFS= read -r perm; do
    [[ -n "$perm" ]] || continue
    forbidden_permission "$perm" && bad+=("$perm")
  done <<<"$perms"
  if ((${#bad[@]})); then
    info "${role}: 付けない権限が入っている: ${bad[*]}"
    die "${role} に付けない権限が入っています。一覧から外すか、カスタムロールに置き換えてください"
  fi
  info "${role}: $(wc -l <<<"$perms") 個の権限。付けない権限は入っていない"
done
if ((!roles_checked)); then
  ((apply)) && die "既定のロールの中身を確かめられないので、付与せずに止めます（gcloud の認証を確かめてください）"
  info "確かめられないロールがある。--apply では確かめられるまで止まる"
fi

# --- 2. service account ---
section "service account: $sa_email"
if read_gcloud iam service-accounts describe "$sa_email" --project "$project" --format='value(email)' >/dev/null; then
  info "既にある"
else
  change iam service-accounts create "$sa_id" --project "$project" \
    --display-name="dev infra viewer" \
    --description="dev distro: read-only view of infra config, state and logs; no secret values or data (dotfiles wsl/admin/setup-dev-infra-viewer-gcp.sh)"
fi

# --- 3. カスタムロール ---
custom_title="dev infra viewer"
custom_description="Read-only IAM, project and Artifact Registry metadata for the dev distro (no downloads)"
custom_list="$(join_by_comma "${custom_permissions[@]}")"
section "カスタムロール projects/${project}/roles/${custom_role}（${custom_title}）"
for perm in "${custom_permissions[@]}"; do info "$perm"; done
if deleted="$(read_gcloud iam roles describe "$custom_role" --project "$project" --format='value(deleted)')"; then
  if [[ "$deleted" == True ]]; then
    change iam roles undelete "$custom_role" --project "$project"
  fi
  # 権限の一覧をこのスクリプトの定義にそろえる（足し過ぎた権限も外す）。
  change iam roles update "$custom_role" --project "$project" --title="$custom_title" --description="$custom_description" \
    --permissions="$custom_list" --stage=GA --quiet
else
  change iam roles create "$custom_role" --project "$project" --title="$custom_title" --description="$custom_description" \
    --permissions="$custom_list" --stage=GA
fi

# --- 4. IAM の付与（条件なし。読み取りだけなので名前で絞らない） ---
section "IAM の付与（project ${project}、member ${member}）"
for role in "${l0_roles[@]}"; do
  info "$role"
done
for role in "${l0_roles[@]}"; do
  change_retry projects add-iam-policy-binding "$project" --member="$member" --role="$role" --condition=None --quiet --format=none
done
# 一覧にない付与（一覧から消したロール・手で足したロール）は外す。
section "一覧にない付与（外す）"
if bound="$(read_gcloud projects get-iam-policy "$project" --flatten='bindings[].members' \
  --filter="bindings.members:${member}" --format='value(bindings.role)')"; then
  stale=0
  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    keep=0
    for wanted in "${l0_roles[@]}"; do [[ "$role" == "$wanted" ]] && keep=1; done
    ((keep)) && continue
    stale=1
    change projects remove-iam-policy-binding "$project" --member="$member" --role="$role" --all --quiet --format=none
  done < <(sort -u <<<"$bound")
  ((stale)) || info "ない"
else
  info "今の付与を読めなかった（確かめられない）"
fi

# --- 5. 鍵 ---
section "service account の鍵: ${key_file}（0600、ディレクトリは 0700）"
if [[ -s "$key_file" ]]; then
  info "既にある（作り直すときは docs/infra-credentials.md の「鍵の作り直し」）"
elif ((apply)); then
  (umask 077 && mkdir -p "$key_dir")
  chmod 700 "$key_dir"
  partial="${key_file}.partial"
  rm -f "$partial"
  printf '  +   %s\n' "$(quote_command gcloud iam service-accounts keys create "$partial" --iam-account="$sa_email" --project "$project")"
  if ! (umask 077 && gcloud iam service-accounts keys create "$partial" --iam-account="$sa_email" --project "$project") 2>"$tmp_dir/key.err"; then
    rm -f "$partial"
    cat "$tmp_dir/key.err" >&2
    die "鍵を作れませんでした（上の gcloud のエラーを確かめてください）"
  fi
  chmod 600 "$partial"
  mv "$partial" "$key_file"
  info "作った: $key_file"
else
  printf '  (dry-run) %s\n' "$(quote_command gcloud iam service-accounts keys create "$key_file" --iam-account="$sa_email" --project "$project")"
fi

section "このあと"
if ((apply)); then
  info "鍵を dev に渡し、dev の既定の gcloud に登録する: docs/infra-credentials.md の「L0 を用意する」"
  info "admin の作業が終わったら PowerShell で wsl --terminate Ubuntu-24.04"
else
  info "内容を確かめたら admin で --apply する。手順と消し方は docs/infra-credentials.md"
fi
