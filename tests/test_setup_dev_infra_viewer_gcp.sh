#!/usr/bin/env bash
# wsl/admin/setup-dev-infra-viewer-gcp.sh（L0 の読み取り専用 SA）を偽の gcloud で検証する。
# dry-run は変更系の gcloud を呼ばず、--apply は表示したものと同じ引数で呼ぶこと、
# 付けない権限・ロールが一覧や既定のロールに入ると止まること、dev では --apply を拒否することを確かめる。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
setup="$repository_root/wsl/admin/setup-dev-infra-viewer-gcp.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# 偽の gcloud: 呼ばれた引数を 1 行ずつ $FAKE_LOG に記録する。$FAKE_STATE/<名前> で状態を変える。
mkdir -p "$fixture/bin"
cat >"$fixture/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
has() { [[ -e "$FAKE_STATE/$1" ]]; }
case "$1 $2" in
  "iam roles")
    if [[ "$3" == describe ]]; then
      if [[ "$4" == roles/* ]]; then
        has roles-unreadable && exit 1
        service="${4#roles/}"; service="${service%%.*}"
        printf '%s.things.get\n%s.things.list\n' "$service" "$service"
        has "bad-${4#roles/}" && cat "$FAKE_STATE/bad-${4#roles/}"
        exit 0
      fi
      has "role-$4" && { cat "$FAKE_STATE/role-$4"; exit 0; }
      echo 'NOT_FOUND' >&2; exit 1
    fi
    exit 0 ;;
  "iam service-accounts")
    case "$3" in
      describe) has sa && { echo "$4"; exit 0; }; echo 'NOT_FOUND' >&2; exit 1 ;;
      keys) printf '{"type": "service_account"}\n' >"$5"; exit 0 ;;
    esac
    exit 0 ;;
  "projects get-iam-policy")
    has policy-unreadable && exit 1
    cat "$FAKE_STATE/bound" 2>/dev/null; exit 0 ;;
  "projects add-iam-policy-binding")
    if [[ -e "$FAKE_STATE/binding-fail-once" ]]; then rm "$FAKE_STATE/binding-fail-once"; echo 'SA does not exist' >&2; exit 1; fi
    exit 0 ;;
esac
exit 0
FAKE
chmod +x "$fixture/bin/gcloud"

failures=0
ng() { printf 'NG   %s\n' "$*" >&2; failures=1; }
ok() { printf 'OK   %s\n' "$*"; }
check() {  # check <説明> <コマンド...>
  local description="$1"
  shift
  if "$@"; then ok "$description"; else ng "$description"; fi
}

case_no=0
# run_setup [script=<path>] [role=dev] <状態...> -- <引数...>: 新しい HOME・状態で実行し、$out・$log・$status・$home・$state を残す。
run_setup() {
  case_no=$((case_no + 1))
  home="$fixture/case$case_no/home"
  state="$fixture/case$case_no/state"
  local script="$setup" role_file="$fixture/case$case_no/role"
  mkdir -p "$home" "$state"
  while (($#)) && [[ "$1" != -- ]]; do
    case "$1" in
      script=*) script="${1#script=}" ;;
      role=dev) printf 'dev\n' >"$role_file" ;;
      bound=*) printf '%s\n' "${1#bound=}" >>"$state/bound" ;;
      bad=*) printf '%s\n' "${1#bad=*:}" >>"$state/bad-$(cut -d: -f1 <<<"${1#bad=}")" ;;
      *) touch "$state/$1" ;;
    esac
    shift
  done
  shift
  log="$fixture/case$case_no/gcloud.log"
  : >"$log"
  status=0
  out="$(HOME="$home" PATH="$fixture/bin:$PATH" FAKE_LOG="$log" FAKE_STATE="$state" \
    DOTFILES_ROLE_FILE="$role_file" DEV_INFRA_SETUP_RETRY_SLEEP=0 bash "$script" "$@" 2>&1)" || status=$?
}
mutating='^(services enable|iam service-accounts (create|delete|keys create|keys delete|keys disable)|iam roles (create|update|undelete|delete)|projects (add|remove)-iam-policy-binding|projects set-iam-policy)'
called() { grep -qE -- "$1" "$log"; }
not_called() { ! grep -qE -- "$1" "$log"; }
out_has() { grep -qF -- "$1" <<<"$out"; }

project=first-impression-490413
sa=dev-infra-viewer@$project.iam.gserviceaccount.com
roles=(roles/compute.viewer roles/run.viewer roles/cloudscheduler.viewer roles/cloudbuild.builds.viewer roles/monitoring.viewer
  roles/logging.viewer roles/serviceusage.serviceUsageViewer roles/cloudquotas.viewer roles/secretmanager.viewer
  "projects/$project/roles/devInfraViewer")

# 1. dry-run: 変更系を呼ばず、SA・ロール・鍵の場所・外す付与を表示する
run_setup bound=roles/compute.viewer bound=roles/storage.objectViewer --
check 'dry-run は成功する' test "$status" -eq 0
check 'dry-run は変更系の gcloud を呼ばない' not_called "$mutating"
check 'dry-run は鍵を作らない' test ! -e "$home/.config/dev-infra"
check 'dry-run は dry-run と表示する' out_has 'dry-run（何も変更しません'
check 'dry-run は SA を表示する' out_has "$sa"
for role in "${roles[@]}"; do
  check "dry-run はロール $role を表示する" out_has "(dry-run) gcloud projects add-iam-policy-binding $project --member=serviceAccount:$sa --role=$role --condition=None --quiet --format=none"
done
check 'dry-run はカスタムロールの権限を表示する' out_has 'resourcemanager.projects.getIamPolicy'
check 'dry-run は既定のロールの中身を確かめる' out_has 'roles/compute.viewer: 2 個の権限。付けない権限は入っていない'
check 'dry-run は一覧にない付与を外すと表示する' out_has "(dry-run) gcloud projects remove-iam-policy-binding $project --member=serviceAccount:$sa --role=roles/storage.objectViewer --all"
check 'dry-run は一覧にある付与は外さない' bash -c '! grep -qF -- "remove-iam-policy-binding $2 --member=serviceAccount:$3 --role=roles/compute.viewer " <<<"$1"' _ "$out" "$project" "$sa"
check 'dry-run は鍵の置き場所を表示する' out_has "$home/.config/dev-infra/gcp-viewer-key.json（0600"
dry_out="$out"

# 2. --apply（何もない状態）: dry-run で表示したものと同じ引数で呼ぶ
run_setup binding-fail-once bound=roles/compute.viewer bound=roles/storage.objectViewer -- --apply
check '--apply は成功する' test "$status" -eq 0
check 'SA を作る' called "^iam service-accounts create dev-infra-viewer --project $project "
check 'カスタムロールを読み取りの権限だけで作る' called "^iam roles create devInfraViewer --project $project .*--permissions=resourcemanager.projects.get,resourcemanager.projects.getIamPolicy,iam.roles.get,"
for role in "${roles[@]}"; do
  check "ロール $role を条件なしで付ける" called "^projects add-iam-policy-binding $project --member=serviceAccount:$sa --role=$role --condition=None --quiet --format=none\$"
done
check '付与の失敗（SA の伝わり待ち）をやり直す' test "$(grep -c 'roles/compute.viewer --condition=None' "$log")" -eq 2
check '一覧にない付与を外す' called "^projects remove-iam-policy-binding $project --member=serviceAccount:$sa --role=roles/storage.objectViewer --all --quiet --format=none\$"
check '一覧にある付与は外さない' not_called 'remove-iam-policy-binding .*--role=roles/compute.viewer '
check '鍵を作る' called "^iam service-accounts keys create $home/.config/dev-infra/gcp-viewer-key.json.partial --iam-account=$sa --project $project\$"
check '鍵は 0600' test "$(stat -c %a "$home/.config/dev-infra/gcp-viewer-key.json")" = 600
check '鍵のディレクトリは 0700' test "$(stat -c %a "$home/.config/dev-infra")" = 700
# dry-run の表示（(dry-run) gcloud …）と --apply の表示（+   gcloud …）が、鍵の .partial 以外で同じであること
sed -n 's/^  (dry-run) //p' <<<"$dry_out" | sed "s#$fixture/case1/home#HOME#" >"$fixture/dry.txt"
sed -n 's/^  +   //p' <<<"$out" | sed "s#$fixture/case$case_no/home#HOME#; s#gcp-viewer-key.json.partial#gcp-viewer-key.json#" \
  | awk '!seen[$0]++' >"$fixture/apply.txt"
check 'dry-run の表示に変更系のコマンドがある（SA・ロール・付与 10 件・外す付与・鍵）' test "$(wc -l <"$fixture/dry.txt")" -eq 14
check 'dry-run の表示と --apply の呼び出しが同じ' diff "$fixture/dry.txt" "$fixture/apply.txt"

# 3. --apply（すべてある状態）: 作り直さない。ロールの権限だけ定義にそろえる
run_setup sa role-devInfraViewer -- --apply
mkdir -p "$home/.config/dev-infra"
check '2 回目の --apply は成功する' test "$status" -eq 0
check '既にあるものは作らない' not_called '^(iam service-accounts create|iam roles create)'
check 'カスタムロールの権限を定義にそろえる' called "^iam roles update devInfraViewer --project $project .*--permissions=resourcemanager.projects.get,"
check '外す付与がなければ外さない' not_called 'remove-iam-policy-binding'
echo '{}' >"$home/.config/dev-infra/gcp-viewer-key.json"
existing_home="$home"
case_no=$((case_no + 1))
mkdir -p "$fixture/case$case_no/state"
touch "$fixture/case$case_no/state/sa"
log="$fixture/case$case_no.log"; : >"$log"
HOME="$existing_home" PATH="$fixture/bin:$PATH" FAKE_LOG="$log" FAKE_STATE="$fixture/case$case_no/state" \
  DOTFILES_ROLE_FILE=/nonexistent bash "$setup" --apply >/dev/null 2>&1 || ng '鍵が既にあるときの --apply'
check '鍵が既にあれば作らない' not_called '^iam service-accounts keys create'

# 4. 既定のロールに付けない権限が入っている（Google がロールを広げた）: 付与せずに止める
for perm in secretmanager.versions.access storage.objects.get iam.serviceAccountKeys.create iam.serviceAccounts.getAccessToken \
  iam.serviceAccounts.actAs logging.privateLogEntries.list compute.instances.delete compute.instances.create \
  run.jobs.update compute.instances.setMetadata resourcemanager.projects.setIamPolicy; do
  run_setup "bad=run.viewer:$perm" -- --apply
  check "既定のロールに $perm があれば --apply は止まる" test "$status" -ne 0
  check "既定のロールに $perm があれば変更系を呼ばない" not_called "$mutating"
  check "既定のロールに $perm があれば理由を表示する" out_has "roles/run.viewer: 付けない権限が入っている: $perm"
done
run_setup "bad=compute.viewer:logging.privateLogEntries.list" --
check '既定のロールに付けない権限があれば dry-run も止まる' test "$status" -ne 0
run_setup roles-unreadable -- --apply
check '既定のロールの中身を読めなければ --apply は止まる' test "$status" -ne 0
check '既定のロールの中身を読めなければ変更系を呼ばない' not_called "$mutating"
run_setup roles-unreadable policy-unreadable --
check '読めなくても dry-run は止まらない' test "$status" -eq 0
check '読めなければ確かめられないと表示する' out_has 'roles/compute.viewer: 中身を読めなかった（確かめられない）'
check '今の付与を読めなければ確かめられないと表示する' out_has '今の付与を読めなかった（確かめられない）'

# 5. スクリプトの一覧に付けない権限・ロールを入れると、gcloud を呼ぶ前に止まる
mutate_script() {  # mutate_script <名前> <sed の式>: 一覧を書き換えた写しを作る
  sed "$2" "$setup" >"$fixture/$1.sh"
  printf '%s' "$fixture/$1.sh"
}
for role in roles/viewer roles/editor roles/owner roles/iam.securityReviewer roles/artifactregistry.reader; do
  copy="$(mutate_script "role-${role//\//-}" "s#^  roles/compute.viewer\$#  roles/compute.viewer\\n  $role#")"
  grep -qx "  $role" "$copy" || ng "写しに $role を入れられなかった"
  run_setup "script=$copy" --
  check "一覧に $role があれば止まる" test "$status" -ne 0
  check "一覧に $role があれば gcloud を呼ばない" test ! -s "$log"
done
for perm in secretmanager.versions.access storage.objects.get iam.serviceAccountKeys.create iam.serviceAccounts.getAccessToken \
  iam.serviceAccounts.actAs logging.privateLogEntries.list compute.instances.create run.jobs.update compute.disks.delete \
  compute.instances.setMetadata resourcemanager.projects.setIamPolicy iam.roles.undelete; do
  copy="$(mutate_script "perm-$perm" "s#^  iam.roles.get\$#  iam.roles.get\\n  $perm#")"
  grep -qx "  $perm" "$copy" || ng "写しに $perm を入れられなかった"
  run_setup "script=$copy" --
  check "カスタムロールに $perm があれば止まる" test "$status" -ne 0
  check "カスタムロールに $perm があれば gcloud を呼ばない" test ! -s "$log"
  check "カスタムロールに $perm があれば理由を表示する" out_has "付けない権限がカスタムロールにある: $perm"
done

# 6. dev: dry-run は動き、--apply は gcloud を呼ばずに 0 以外で終わる
run_setup role=dev --
check 'dev の dry-run は成功する' test "$status" -eq 0
check 'dev の dry-run は今の状態を読む' called '^projects get-iam-policy'
check 'dev の dry-run は変更系の gcloud を呼ばない' not_called "$mutating"
run_setup role=dev -- --apply
check 'dev の --apply は止まる' test "$status" -ne 0
check 'dev の --apply は gcloud を呼ばない' test ! -s "$log"
check 'dev の --apply は admin で実行するよう表示する' out_has 'dev ディストリでは --apply しません'

bash -n "$setup" || ng 'setup-dev-infra-viewer-gcp.sh の構文'
exit "$failures"
