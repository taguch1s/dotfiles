#!/usr/bin/env bash
# wsl/admin/setup-hc-remote-gcp.sh を偽の gcloud で検証する。
# dry-run は変更系の gcloud を呼ばず、--apply は期待どおりの引数で呼ぶこと、
# dev の verify-dev-boundary.sh がユーザー本人の gcloud 資格情報を見つけることを確かめる。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
setup="$repository_root/wsl/admin/setup-hc-remote-gcp.sh"
verify="$repository_root/wsl/dev/verify-dev-boundary.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# 偽の gcloud: 呼ばれた引数を 1 行ずつ $FAKE_LOG に記録する。--condition-from-file の中身も記録する。
# $FAKE_STATE/<名前> があるものは「既にある」として describe などが成功する。
mkdir -p "$fixture/bin"
cat >"$fixture/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
for arg in "$@"; do
  case "$arg" in
    --condition-from-file=*) printf 'CONDITION %s\n' "$(tr '\n' ' ' <"${arg#*=}")" >>"$FAKE_LOG" ;;
  esac
done
has() { [[ -e "$FAKE_STATE/$1" ]]; }
case "$1 $2" in
  "services list")
    filter="$*"
    has iap && [[ "$filter" == *iap.googleapis.com* ]] && echo iap.googleapis.com
    has cloudquotas && [[ "$filter" == *cloudquotas* ]] && echo cloudquotas.googleapis.com
    has budgets-api && [[ "$filter" == *billingbudgets* ]] && echo billingbudgets.googleapis.com
    exit 0 ;;
  "iam service-accounts")
    case "$3" in
      describe) has sa && { echo "$4"; exit 0; }; echo 'NOT_FOUND' >&2; exit 1 ;;
      keys)
        if has key-denied; then
          echo "ERROR: (gcloud.iam.service-accounts.keys.create) FAILED_PRECONDITION: Key creation is not allowed on this service account. constraints/iam.disableServiceAccountKeyCreation" >&2
          exit 1
        fi
        printf '{"type": "service_account"}\n' >"$5"; exit 0 ;;
    esac
    exit 0 ;;
  "iam roles")
    if [[ "$3" == describe ]]; then
      has "role-$4" && { cat "$FAKE_STATE/role-$4"; exit 0; }
      echo 'NOT_FOUND' >&2; exit 1
    fi
    exit 0 ;;
  "projects add-iam-policy-binding")
    if [[ -e "$FAKE_STATE/binding-fail-once" ]]; then rm "$FAKE_STATE/binding-fail-once"; echo 'SA does not exist' >&2; exit 1; fi
    exit 0 ;;
  "compute instances")
    printf 'ts-crawler-detail-loop-4zzn\tasia-northeast1-a\te2-small\tRUNNING\n'
    has hc-vm && printf 'hc-remote-job-1\tasia-northeast1-a\te2-standard-4\tRUNNING\n'
    exit 0 ;;
  "compute firewall-rules")
    if [[ "$3" == describe ]]; then has firewall && { echo "$4"; exit 0; }; exit 1; fi
    exit 0 ;;
  "compute regions")
    has no-region && exit 1
    if has quota-capped; then
      cpus=17 e2=16 n2=0 gpu=0
    else
      cpus=100 e2=24 n2=200 gpu=1
    fi
    cat <<JSON
{"quotas": [
  {"metric": "CPUS", "limit": $cpus.0, "usage": 1.0},
  {"metric": "PREEMPTIBLE_CPUS", "limit": 0.0, "usage": 0.0},
  {"metric": "COMMITTED_CPUS", "limit": 0.0, "usage": 0.0},
  {"metric": "E2_CPUS", "limit": $e2.0, "usage": 0.0},
  {"metric": "N2_CPUS", "limit": $n2.0, "usage": 0.0},
  {"metric": "N2D_CPUS", "limit": $n2.0, "usage": 0.0},
  {"metric": "M2_CPUS", "limit": 0.0, "usage": 0.0},
  {"metric": "INSTANCES", "limit": 24.0, "usage": 1.0},
  {"metric": "NVIDIA_T4_GPUS", "limit": $gpu.0, "usage": 0.0},
  {"metric": "PREEMPTIBLE_NVIDIA_T4_GPUS", "limit": $gpu.0, "usage": 0.0}
]}
JSON
    exit 0 ;;
  "beta quotas")
    if [[ "$3" == info ]]; then
      has no-family && exit 1
      c4=24; has quota-capped && c4=0
      printf '{"dimensionsInfos": [{"dimensions": {"region": "asia-northeast1", "vm_family": "C4"}, "details": {"value": "%s"}}, {"dimensions": {"region": "asia-northeast1", "vm_family": "H4D"}, "details": {}}, {"dimensions": {"region": "us-central1", "vm_family": "C4"}, "details": {"value": "24"}}]}\n' "$c4"
      exit 0
    fi
    has quota-fail && { echo 'ERROR: quota decrease rejected' >&2; exit 1; }
    if has quota-recent && [[ "$*" == *--quota-id=N2D-CPUS-per-project-region* && "$*" == *--preferred-value=0\ * ]]; then
      echo 'ERROR: (gcloud.beta.quotas.preferences.update) FAILED_PRECONDITION: decreases effective quota unsafely. New Effective limit 0 is below recent quota usage 8.' >&2
      exit 1
    fi
    if has quota-missing && [[ "$*" == *--quota-id=E2-CPUS-per-project-region* ]]; then
      echo "ERROR: (gcloud.beta.quotas.preferences.update) NOT_FOUND: Limit 'E2-CPUS-per-project-region' does not exist" >&2
      exit 1
    fi
    exit 0 ;;
  "billing projects")
    has billing && echo 'billingAccounts/000000-111111-222222'; exit 0 ;;
  "billing accounts")
    cat "$FAKE_STATE/currency" 2>/dev/null; exit 0 ;;
  "billing budgets")
    if [[ "$3" == list ]]; then has budget && echo 'billingAccounts/000000-111111-222222/budgets/abc'; exit 0; fi
    has budget-denied && { echo 'PERMISSION_DENIED' >&2; exit 1; }
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
# run_setup <状態ファイル...> -- <setup の引数...>: 新しい HOME・状態で実行し、$out・$log・$status・$home を残す。
run_setup() {
  case_no=$((case_no + 1))
  home="$fixture/case$case_no/home"
  local state="$fixture/case$case_no/state"
  mkdir -p "$home" "$state"
  while (($#)) && [[ "$1" != -- ]]; do
    case "$1" in
      currency=*) printf '%s\n' "${1#currency=}" >"$state/currency" ;;
      *) touch "$state/$1" ;;
    esac
    shift
  done
  shift
  log="$fixture/case$case_no/gcloud.log"
  : >"$log"
  status=0
  out="$(HOME="$home" PATH="$fixture/bin:$PATH" FAKE_LOG="$log" FAKE_STATE="$state" \
    DOTFILES_ROLE_FILE="$fixture/case$case_no/role" HC_REMOTE_SETUP_RETRY_SLEEP=0 \
    bash "$setup" "$@" 2>&1)" || status=$?
}
mutating='^(beta quotas preferences (create|update|delete)|services enable|iam service-accounts (create|delete|keys create|keys delete|keys disable)|iam roles (create|update|undelete|delete)|projects (add|remove)-iam-policy-binding|projects set-iam-policy|compute firewall-rules (create|update|delete)|compute instances (create|delete)|billing budgets (create|update|delete))'
called() { grep -qE -- "$1" "$log"; }
not_called() { ! grep -qE -- "$1" "$log"; }
out_has() { grep -qF -- "$1" <<<"$out"; }

project=first-impression-490413
sa=hc-remote-runner@$project.iam.gserviceaccount.com
prefix_expr="resource.name.startsWith(\"projects/$project/zones/asia-northeast1-a/instances/hc-remote-\")"

# 1. dry-run: 変更系を呼ばず、作るもの・権限・条件・firewall・鍵の場所を表示する
run_setup billing currency=JPY --
check 'dry-run は成功する' test "$status" -eq 0
check 'dry-run は変更系の gcloud を呼ばない' not_called "$mutating"
check 'dry-run は鍵を作らない' test ! -e "$home/.config/hc-remote"
check 'dry-run は dry-run と表示する' out_has 'dry-run（何も変更しません'
check 'dry-run は SA を表示する' out_has "$sa"
for perm in compute.instances.create compute.instances.delete compute.instances.setMetadata compute.disks.create \
  compute.instances.list compute.zoneOperations.get compute.subnetworks.use compute.subnetworks.useExternalIp; do
  check "dry-run は権限 $perm を表示する" out_has "$perm"
done
check 'dry-run は条件の式を表示する' out_has "$prefix_expr"
check 'dry-run は IAP の条件を表示する' out_has 'destination.port == 22'
check 'dry-run は firewall と IAP の範囲を表示する' out_has 'hc-remote-allow-iap-ssh（tag hc-remote の VM に 35.235.240.0/20'
check 'dry-run は鍵の置き場所を表示する' out_has "$home/.config/hc-remote/gcp-key.json（0600"
check 'dry-run は ts-crawler を条件に当たらない VM として数える' out_has '条件に当たらない既存の VM: 1 台'
check 'dry-run は条件に当たらない VM の機種と状態を表示する' out_has '条件に当たらない: ts-crawler-detail-loop-4zzn（asia-northeast1-a e2-small RUNNING）'
check 'dry-run は JPY の既定の budget を表示する' out_has '金額 1000 JPY/月'
check 'dry-run は CPUS を使用分 + 16 に下げると表示する' grep -qE 'CPUS +上限 100 +使用 1 +→ 17 に下げる' <<<"$out"
check 'dry-run は PREEMPTIBLE_CPUS が 0 なら触らないと表示する' grep -qE 'PREEMPTIBLE_CPUS +上限 0 .*0 のまま' <<<"$out"
check 'dry-run は GPU の quota が 0 でないことを表示する' out_has 'GPU の quota に 0 でないものがある'
check 'dry-run は ほかの機種の CPU を 0 に下げると表示する' grep -qE 'N2_CPUS +上限 200 .*→ 0 に下げる' <<<"$out"
check 'dry-run は値のない VM ファミリーを変えないと表示する' grep -qE 'CPUS_PER_VM_FAMILY\(H4D\) .*値なし（変えない）' <<<"$out"
check 'dry-run は VM ファミリーの quota も表示する' grep -qE 'CPUS_PER_VM_FAMILY\(C4\) +上限 24 .*→ 0 に下げる' <<<"$out"
check 'dry-run は付けない権限を出さない' not_called 'setServiceAccount|setCommonInstanceMetadata|actAs'
if grep -qE 'setServiceAccount|setCommonInstanceMetadata|serviceAccounts.actAs' <<<"$out"; then
  ng 'SA を VM に付ける権限・project の metadata を書く権限を付けない'
else
  ok 'SA を VM に付ける権限・project の metadata を書く権限を付けない'
fi

# 2. --apply（何もない状態）: すべてを期待どおりの引数で作る
run_setup billing currency=JPY binding-fail-once -- --apply
check '--apply は成功する' test "$status" -eq 0
check 'Cloud Quotas の API を有効にする' called "^services enable cloudquotas.googleapis.com --project $project\$"
quota_args="--allow-missing --project=$project --service=compute.googleapis.com"
check 'CPUS を 17 に下げる' called "^beta quotas preferences update hc-remote_cpus_asia-northeast1 $quota_args --quota-id=CPUS-per-project-region --dimensions=region=asia-northeast1 --preferred-value=17 --allow-high-percentage-quota-decrease "
check 'E2_CPUS も CPUS と同じ上限にする' called "^beta quotas preferences update hc-remote_e2-cpus_asia-northeast1 .*--quota-id=E2-CPUS-per-project-region .*--preferred-value=16 "
check 'N2_CPUS を 0 に下げる' called "--quota-id=N2-CPUS-per-project-region --dimensions=region=asia-northeast1 --preferred-value=0 "
check 'GPU を 0 に下げる' called "--quota-id=NVIDIA-T4-GPUS-per-project-region --dimensions=region=asia-northeast1 --preferred-value=0 "
check 'Spot の GPU を 0 に下げる' called "--quota-id=PREEMPTIBLE-NVIDIA-T4-GPUS-per-project-region .*--preferred-value=0 "
check 'VM ファミリーの CPU を 0 に下げる' called "^beta quotas preferences update hc-remote_cpus-per-vm-family-c4_asia-northeast1 .*--quota-id=CPUS-PER-VM-FAMILY-per-project-region --dimensions=region=asia-northeast1,vm_family=C4 --preferred-value=0 "
check 'PREEMPTIBLE_CPUS（0）には触らない' not_called 'PREEMPTIBLE-CPUS-per-project-region'
check 'すでに 0 の quota・COMMITTED・ほかの region には触らない' not_called 'M2-CPUS|COMMITTED|INSTANCES|H4D|us-central1'
check '使用中の分より下げるフラグは付けない' not_called 'allow-quota-decrease-below-usage'
check 'IAP の API を有効にする' called "^services enable iap.googleapis.com --project $project\$"
check 'SA を作る' called "^iam service-accounts create hc-remote-runner --project $project "
check 'runner ロールを決めた権限だけで作る' called "^iam roles create hcRemoteRunner --project $project .*--permissions=compute.instances.create,compute.instances.delete,compute.instances.get,compute.instances.getSerialPortOutput,compute.instances.setLabels,compute.instances.setMetadata,compute.instances.setScheduling,compute.instances.setTags,compute.disks.create,compute.disks.delete,compute.disks.get --stage=GA\$"
check 'reader ロールを読み取りだけで作る' called "^iam roles create hcRemoteReader .*--permissions=compute.instances.list,compute.machineTypes.get,compute.machineTypes.list,compute.projects.get,compute.regions.get,compute.zoneOperations.get,compute.zones.get,compute.zones.list "
check 'subnet ロールを作る' called "^iam roles create hcRemoteSubnetUser .*--permissions=compute.subnetworks.use,compute.subnetworks.useExternalIp "
check 'runner ロールを条件付きで付ける' called "^projects add-iam-policy-binding $project --member=serviceAccount:$sa --role=projects/$project/roles/hcRemoteRunner --condition-from-file=.* --quiet --format=none\$"
check '条件の式は hc-remote- の instance と disk だけ' called "^CONDITION title: hc-remote-name-prefix .*expression: '\\(resource.type == \"compute.googleapis.com/Instance\" && resource.name.startsWith\\(\"projects/$project/zones/asia-northeast1-a/instances/hc-remote-\"\\)\\) \\|\\| \\(resource.type == \"compute.googleapis.com/Disk\" && resource.name.startsWith\\(\"projects/$project/zones/asia-northeast1-a/disks/hc-remote-\"\\)\\)' \$"
check 'reader ロールは条件なしで付ける' called "^projects add-iam-policy-binding $project --member=serviceAccount:$sa --role=projects/$project/roles/hcRemoteReader --condition=None --quiet --format=none\$"
check 'subnet ロールは条件なしで付ける' called "^projects add-iam-policy-binding $project --member=serviceAccount:$sa --role=projects/$project/roles/hcRemoteSubnetUser --condition=None --quiet --format=none\$"
check 'IAP は port 22 の条件で付ける' called "^projects add-iam-policy-binding $project --member=serviceAccount:$sa --role=roles/iap.tunnelResourceAccessor --condition-from-file="
check 'IAP の条件の式' called "^CONDITION title: hc-remote-ssh-only .*expression: 'destination.port == 22' \$"
check '付与の失敗（SA の伝わり待ち）をやり直す' test "$(grep -c "roles/hcRemoteRunner --condition-from-file" "$log")" -eq 2
check 'firewall を IAP の範囲・tag hc-remote・tcp:22 で作る' called "^compute firewall-rules create hc-remote-allow-iap-ssh --project $project --network=default --direction=INGRESS --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=hc-remote "
check '鍵を作る' called "^iam service-accounts keys create $home/.config/hc-remote/gcp-key.json.partial --iam-account=$sa --project $project\$"
check '鍵は 0600' test "$(stat -c %a "$home/.config/hc-remote/gcp-key.json")" = 600
check '鍵のディレクトリは 0700' test "$(stat -c %a "$home/.config/hc-remote")" = 700
check 'budget の API を有効にする' called "^services enable billingbudgets.googleapis.com --project $project\$"
check 'budget をラベル hc-remote=1・1000JPY で作る' called "^billing budgets create --billing-account=000000-111111-222222 --billing-project=$project --display-name=hc-remote --budget-amount=1000JPY --filter-projects=projects/$project --filter-labels=hc-remote=1 --calendar-period=month "
check 'VM・project の metadata を変えない' not_called '^compute (instances (create|delete|add-metadata)|project-info)'
check 'dev へ鍵を渡す PowerShell の 1 行を表示する' out_has "wsl -d dev -- sh -c 'umask 077; mkdir -p ~/.config/hc-remote; cat > ~/.config/hc-remote/gcp-key.json'"

# 3. --apply（すべてある状態）: 何度実行しても同じ（作り直さない。ロールの権限だけ定義にそろえる）
run_setup iap cloudquotas quota-capped sa role-hcRemoteRunner role-hcRemoteReader role-hcRemoteSubnetUser firewall billing budgets-api budget currency=USD -- --apply
mkdir -p "$home/.config/hc-remote"
check '2 回目の --apply は成功する' test "$status" -eq 0
check 'quota が下がっていれば何もしない' not_called '^beta quotas preferences'
check '既にあるものは作らない' not_called '^(services enable|iam service-accounts create|iam roles create|compute firewall-rules create|billing budgets create)'
check 'ロールの権限を定義にそろえる' called "^iam roles update hcRemoteRunner --project $project .*--permissions=compute.instances.create,"
echo '{}' >"$home/.config/hc-remote/gcp-key.json"
run_existing_home="$home"
case_no=$((case_no + 1))
log="$fixture/case$case_no.log"; : >"$log"
mkdir -p "$fixture/case$case_no/state"
touch "$fixture/case$case_no/state/sa"
status=0
out="$(HOME="$run_existing_home" PATH="$fixture/bin:$PATH" FAKE_LOG="$log" FAKE_STATE="$fixture/case$case_no/state" \
  DOTFILES_ROLE_FILE=/nonexistent HC_REMOTE_SETUP_RETRY_SLEEP=0 bash "$setup" --apply --no-budget 2>&1)" || status=$?
check '鍵が既にあれば作らない' not_called '^iam service-accounts keys create'
check '--no-budget は budget を作らない' not_called '^(billing budgets create|services enable billingbudgets)'

# 4. 鍵を組織のポリシーで作れない: 理由を表示して止まる
run_setup sa key-denied -- --apply --no-budget
check '鍵を作れなければ失敗で止まる' test "$status" -ne 0
check '組織のポリシーが理由だと表示する' out_has 'iam.disableServiceAccountKeyCreation'
check '作りかけの鍵を残さない' test ! -e "$home/.config/hc-remote/gcp-key.json.partial"

# 4b. quota を下げられない・読めない: 鍵を作らずに止まる
run_setup sa quota-fail -- --apply --no-budget
check 'quota を下げられなければ失敗で止まる' test "$status" -ne 0
check 'quota を下げられなければ鍵を作らない' not_called '^iam service-accounts keys create'
run_setup sa quota-recent quota-missing -- --apply --no-budget
check '直近の使用量を下回れない・無い quota があっても止まらない' test "$status" -eq 0
check '直近の使用量（8）まで下げ直す' called '--quota-id=N2D-CPUS-per-project-region --dimensions=region=asia-northeast1 --preferred-value=8 '
check '直近の使用量を下回るフラグは付けない' not_called 'allow-quota-decrease-below-usage'
check '無い quota は飛ばすと表示する' out_has 'この project には無い quota なので飛ばす: E2-CPUS-per-project-region'
check '下げ直せたら鍵を作る' called '^iam service-accounts keys create'
run_setup sa no-region -- --apply --no-budget
check 'quota を読めなければ失敗で止まる' test "$status" -ne 0
check 'quota を読めなければ鍵を作らない' not_called '^iam service-accounts keys create'
run_setup sa no-family -- --apply --no-budget
check '機種別の quota を読めなければ失敗で止まる' test "$status" -ne 0
check '機種別の quota を読めなければ鍵を作らない' not_called '^iam service-accounts keys create'
run_setup billing currency=USD -- --max-vcpus 8 --apply
check '--max-vcpus で CPUS の上限を変える' called '--quota-id=CPUS-per-project-region --dimensions=region=asia-northeast1 --preferred-value=9 '

# 5. budget を作れなくても、手順を表示して先へ進む
run_setup billing currency=JPY budget-denied -- --apply
check 'budget の失敗では止まらない' test "$status" -eq 0
check 'budget を手で作る手順を表示する' out_has 'budget を作れない・確かめられないときは手で作ってください'

# 6. dev では実行しない
case_no=$((case_no + 1))
printf 'dev\n' >"$fixture/role-dev"
log="$fixture/case$case_no.log"; : >"$log"
status=0
out="$(PATH="$fixture/bin:$PATH" FAKE_LOG="$log" FAKE_STATE="$fixture" DOTFILES_ROLE_FILE="$fixture/role-dev" bash "$setup" --apply 2>&1)" || status=$?
check 'dev では止まる' test "$status" -ne 0
check 'dev では gcloud を呼ばない' test ! -s "$log"

# 7. dev の境界の検査: ~/.config/gcloud にユーザー本人の資格情報があれば NG
gcloud_lines() {  # gcloud_lines <HOME>: verify-dev-boundary.sh の gcloud の行だけを出す
  HOME="$1" bash "$verify" 2>&1 | grep -E 'gcloud' || true
}
make_credentials_db() {  # make_credentials_db <dir> <account...>
  mkdir -p "$1"
  python3 - "$1/credentials.db" "${@:2}" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE IF NOT EXISTS credentials (account_id TEXT PRIMARY KEY, value BLOB)")
for account in sys.argv[2:]:
    db.execute("INSERT INTO credentials VALUES (?, '{}')", (account,))
db.commit()
PY
}
empty_home="$fixture/verify-empty"
mkdir -p "$empty_home"
lines="$(gcloud_lines "$empty_home")"
check 'gcloud の設定がなければ OK' grep -q '^OK .*gcloud' <<<"$lines"

user_home="$fixture/verify-user"
make_credentials_db "$user_home/.config/gcloud" user@example.com
lines="$(gcloud_lines "$user_home")"
check 'credentials.db にユーザーのアカウントがあれば NG' grep -q '^NG .*user@example.com' <<<"$lines"

legacy_home="$fixture/verify-legacy"
mkdir -p "$legacy_home/.config/gcloud/legacy_credentials/someone@example.com"
lines="$(gcloud_lines "$legacy_home")"
check 'legacy_credentials にユーザーのアカウントがあれば NG' grep -q '^NG .*someone@example.com' <<<"$lines"

adc_home="$fixture/verify-adc"
mkdir -p "$adc_home/.config/gcloud"
printf '{"type": "authorized_user", "refresh_token": "x"}\n' >"$adc_home/.config/gcloud/application_default_credentials.json"
lines="$(gcloud_lines "$adc_home")"
check 'ユーザーの application default credentials があれば NG' grep -q '^NG .*application_default_credentials' <<<"$lines"

sa_home="$fixture/verify-sa"
make_credentials_db "$sa_home/.config/gcloud" "$sa"
make_credentials_db "$sa_home/.config/hc-remote/gcloud" "$sa"
lines="$(gcloud_lines "$sa_home")"
check 'service account だけなら OK' grep -q '^OK .*gcloud' <<<"$lines"
check 'service account だけなら NG を出さない' bash -c '! grep -q "^NG" <<<"$1"' _ "$lines"

hc_user_home="$fixture/verify-hc-user"
make_credentials_db "$hc_user_home/.config/hc-remote/gcloud" user@example.com
lines="$(gcloud_lines "$hc_user_home")"
check 'hc-remote の gcloud 設定にユーザーのアカウントがあれば NG' grep -q '^NG .*hc-remote/gcloud.*user@example.com' <<<"$lines"

bash -n "$setup" || ng 'setup-hc-remote-gcp.sh の構文'
exit "$failures"
