#!/usr/bin/env bash
# dev の hc-remote（gcp backend）が使う、VM の操作だけに絞った service account を admin で用意する。
# 既定は dry-run（作るもの・付ける権限・条件の式をすべて表示し、GCP は読み取りしかしない）。
# --apply のときだけ、service account・カスタムロール・IAM の付与・firewall・鍵・budget を作る。
# 何度実行しても同じ状態になる。手順・権限の理由・消し方は docs/hc-remote-gcp.md。
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-hc-remote-gcp.sh [--apply] [--project ID] [--zone ZONE] [--network NAME]
                              [--key-dir DIR] [--max-vcpus N] [--budget-amount N | --no-budget]

--apply          実際に作る（既定は dry-run で、変更系の gcloud を呼ばない）
--project        GCP の project（既定 first-impression-490413）
--zone           VM を作るゾーン（既定 asia-northeast1-a）。条件の式の名前に入る
--network        firewall を置く VPC（既定 default）
--key-dir        鍵を置くディレクトリ（既定 ~/.config/hc-remote）。鍵は <dir>/gcp-key.json（0600）
--budget-amount  hc-remote の月の budget の金額（課金アカウントの通貨。既定は USD なら 10、JPY なら 1500）
--max-vcpus      hc-remote が同時に使える vCPU の上限（既定 16）。region の CPU の quota を
                 「今の使用分 + この値」まで下げる（下げるだけで、上げない）
--no-budget      budget のアラートを作らない
EOF
}

die() {
  printf 'setup-hc-remote-gcp: %s\n' "$*" >&2
  exit 1
}

project="first-impression-490413"
zone="asia-northeast1-a"
network="default"
key_dir="${HOME}/.config/hc-remote"
apply=0
budget=1
budget_amount=""
max_vcpus=16
while (($#)); do
  case "$1" in
    --apply) apply=1; shift ;;
    --no-budget) budget=0; shift ;;
    --project|--zone|--network|--key-dir|--budget-amount|--max-vcpus)
      (($# >= 2)) || die "$1 に値を指定してください"
      case "$1" in
        --project) project="$2" ;;
        --zone) zone="$2" ;;
        --network) network="$2" ;;
        --key-dir) key_dir="$2" ;;
        --budget-amount) budget_amount="$2" ;;
        --max-vcpus) max_vcpus="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "不明な引数: $1" ;;
  esac
done
[[ -z "$budget_amount" || "$budget_amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--budget-amount は数値で指定してください: $budget_amount"
[[ "$max_vcpus" =~ ^[0-9]+$ ]] || die "--max-vcpus は整数で指定してください: $max_vcpus"
[[ "$zone" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] || die "ゾーンの形が不正です: $zone"

# 秘密情報の置き場（admin）でだけ動かす。dev ではユーザーの gcloud の資格情報を使わない方針（docs/wsl-dev-distro.md）。
role_file="${DOTFILES_ROLE_FILE:-/etc/dotfiles-role}"
if [[ "$(cat "$role_file" 2>/dev/null)" == dev ]]; then
  die "dev ディストリでは実行しません。admin（Ubuntu-24.04）で実行してください"
fi
command -v gcloud >/dev/null || die "gcloud が見つかりません"

# --- 作るものの定義（dry-run の表示と --apply の実行で同じ値を使う） ---
sa_id="hc-remote-runner"
sa_email="${sa_id}@${project}.iam.gserviceaccount.com"
member="serviceAccount:${sa_email}"
name_prefix="hc-remote-"
region="${zone%-*}"
network_tag="hc-remote"
firewall_name="hc-remote-allow-iap-ssh"
iap_range="35.235.240.0/20"
key_file="${key_dir}/gcp-key.json"
budget_name="hc-remote"
budget_label="hc-remote=1"

# 名前が hc-remote- で始まる VM・disk だけに効かせる操作（条件付きで付与する）。
# VM に service account を付ける権限（compute.instances.setServiceAccount、iam.serviceAccounts.actAs）と、
# project の metadata を書く権限（compute.projects.setCommonInstanceMetadata）は入れない。
runner_role="hcRemoteRunner"
runner_permissions=(
  compute.instances.create
  compute.instances.delete
  compute.instances.get
  compute.instances.getSerialPortOutput
  compute.instances.setLabels
  compute.instances.setMetadata
  compute.instances.setScheduling
  compute.instances.setTags
  compute.disks.create
  compute.disks.delete
  compute.disks.get
)
# 条件を付けられない（project に対して確かめられる）読み取り。変更はできない。
reader_role="hcRemoteReader"
reader_permissions=(
  compute.instances.list
  compute.machineTypes.get
  compute.machineTypes.list
  compute.projects.get
  compute.regions.get
  compute.zoneOperations.get
  compute.zones.get
  compute.zones.list
)
# VM の NIC を subnetwork に繋ぐ（外部 IP 付き）ための権限。名前で絞る対象ではないので型（この権限だけのロール）で許す。
subnet_role="hcRemoteSubnetUser"
subnet_permissions=(
  compute.subnetworks.use
  compute.subnetworks.useExternalIp
)
iap_role="roles/iap.tunnelResourceAccessor"

runner_condition_title="hc-remote-name-prefix"
runner_condition_description="Only VMs and disks named ${name_prefix}* in ${zone}"
runner_condition_expression="(resource.type == \"compute.googleapis.com/Instance\" && resource.name.startsWith(\"projects/${project}/zones/${zone}/instances/${name_prefix}\")) || (resource.type == \"compute.googleapis.com/Disk\" && resource.name.startsWith(\"projects/${project}/zones/${zone}/disks/${name_prefix}\"))"
iap_condition_title="hc-remote-ssh-only"
iap_condition_description="IAP TCP forwarding to port 22 only"
iap_condition_expression="destination.port == 22"

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

# --- 実行の道具 ---
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
    printf '      失敗したので %s 秒後にやり直す（%s/5）\n' "${HC_REMOTE_SETUP_RETRY_SLEEP:-5}" "$attempt" >&2
    sleep "${HC_REMOTE_SETUP_RETRY_SLEEP:-5}"
  done
  return 1
}
# 読み取り専用の gcloud。dry-run でも今の状態を表示するために呼ぶ。失敗は「無い・確かめられない」として扱う。
# API が無効なときに gcloud が「有効にしますか」と聞いて止まったり、有効にしたりしないよう、確認を出させない。
read_gcloud() {
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud "$@" 2>/dev/null </dev/null
}
condition_file() {  # condition_file <path> <title> <description> <expression>
  {
    printf 'title: %s\n' "$2"
    printf 'description: %s\n' "$3"
    printf "expression: '%s'\n" "${4//\'/\'\'}"
  } >"$1"
}

mode_label="dry-run（何も変更しません。実行するには --apply）"
((apply)) && mode_label="apply"
printf 'setup-hc-remote-gcp: %s\n' "$mode_label"
printf '  project: %s / zone: %s / network: %s\n' "$project" "$zone" "$network"

# --- 0. 使う API ---
for api in iap.googleapis.com cloudquotas.googleapis.com; do
  case "$api" in
    iap.googleapis.com) section "API: ${api}（IAP 経由の SSH に使う）" ;;
    cloudquotas.googleapis.com) section "API: ${api}（quota を下げるのに使う）" ;;
  esac
  if [[ -n "$(read_gcloud services list --enabled --project "$project" --filter="config.name=${api}" --format='value(config.name)')" ]]; then
    info "有効になっている"
  else
    change services enable "$api" --project "$project"
  fi
done

# --- 1. service account ---
section "service account: $sa_email"
if read_gcloud iam service-accounts describe "$sa_email" --project "$project" --format='value(email)' >/dev/null; then
  info "既にある"
else
  change iam service-accounts create "$sa_id" --project "$project" \
    --display-name="hc-remote runner" \
    --description="hc-remote on the dev distro: manages ${name_prefix}* VMs only (dotfiles wsl/admin/setup-hc-remote-gcp.sh)"
fi

# --- 2. カスタムロール ---
ensure_role() {  # ensure_role <role id> <title> <description> <permission>...
  local role_id="$1" title="$2" description="$3"
  shift 3
  local permissions
  permissions="$(join_by_comma "$@")"
  section "カスタムロール projects/${project}/roles/${role_id}（${title}）"
  local perm
  for perm in "$@"; do info "$perm"; done
  local deleted
  if deleted="$(read_gcloud iam roles describe "$role_id" --project "$project" --format='value(deleted)')"; then
    if [[ "$deleted" == True ]]; then
      change iam roles undelete "$role_id" --project "$project"
    fi
    # 権限の一覧をこのスクリプトの定義にそろえる（足し過ぎた権限も外す）。
    change iam roles update "$role_id" --project "$project" --title="$title" --description="$description" \
      --permissions="$permissions" --stage=GA --quiet
  else
    change iam roles create "$role_id" --project "$project" --title="$title" --description="$description" \
      --permissions="$permissions" --stage=GA
  fi
}
ensure_role "$runner_role" "hc-remote runner" "Create, inspect and delete hc-remote VMs and disks (bound with a name-prefix condition)" \
  "${runner_permissions[@]}"
ensure_role "$reader_role" "hc-remote reader" "Read-only project-level lookups that IAM conditions cannot scope" \
  "${reader_permissions[@]}"
ensure_role "$subnet_role" "hc-remote subnet user" "Attach hc-remote VM NICs (with external IP) to subnetworks" \
  "${subnet_permissions[@]}"

# --- 3. IAM の付与 ---
section "IAM の付与（project ${project}、member ${member}）"
runner_condition_file="$tmp_dir/runner-condition.yaml"
iap_condition_file="$tmp_dir/iap-condition.yaml"
condition_file "$runner_condition_file" "$runner_condition_title" "$runner_condition_description" "$runner_condition_expression"
condition_file "$iap_condition_file" "$iap_condition_title" "$iap_condition_description" "$iap_condition_expression"
info "projects/${project}/roles/${runner_role}: 条件 ${runner_condition_title}"
info "  ${runner_condition_expression}"
info "projects/${project}/roles/${reader_role}: 条件なし（読み取りだけ）"
info "projects/${project}/roles/${subnet_role}: 条件なし（subnetwork の use / useExternalIp だけ）"
info "${iap_role}: 条件 ${iap_condition_title}"
info "  ${iap_condition_expression}"
change_retry projects add-iam-policy-binding "$project" --member="$member" \
  --role="projects/${project}/roles/${runner_role}" --condition-from-file="$runner_condition_file" --quiet --format=none
change_retry projects add-iam-policy-binding "$project" --member="$member" \
  --role="projects/${project}/roles/${reader_role}" --condition=None --quiet --format=none
change_retry projects add-iam-policy-binding "$project" --member="$member" \
  --role="projects/${project}/roles/${subnet_role}" --condition=None --quiet --format=none
change_retry projects add-iam-policy-binding "$project" --member="$member" \
  --role="$iap_role" --condition-from-file="$iap_condition_file" --quiet --format=none

section "既存の VM への影響（${name_prefix}* 以外は変更・削除できない）"
if vm_rows="$(read_gcloud compute instances list --project "$project" --format='value(name,zone.basename(),machineType.basename(),status)')"; then
  matched=0
  others=0
  while IFS=$'\t' read -r vm vm_zone vm_type vm_status; do
    [[ -n "$vm" ]] || continue
    if [[ "$vm" == "$name_prefix"* ]]; then
      info "条件に当たる（操作できる）: $vm"
      matched=1
    else
      others=$((others + 1))
      # 停止中の VM も quota の機種を確かめるために表示する（下の quota は実行中の使用分しか数えない）
      info "条件に当たらない: $vm（${vm_zone} ${vm_type} ${vm_status}）"
    fi
  done <<<"$vm_rows"
  ((matched)) || info "条件に当たる既存の VM はない"
  info "条件に当たらない既存の VM: ${others} 台（ts-crawler-* など。作成・削除・metadata・ラベル・tags を変えられない）"
  info "停止中の VM が E2・N1 以外の機種なら、下の quota の引き下げで再起動できなくなるので、--apply の前に確かめる"
else
  info "VM の一覧を取得できなかった（gcloud の認証を確かめてください）"
fi
info "インスタンステンプレート・MIG・firewall・project の metadata を変える権限は付けない"

# --- 4. firewall ---
section "firewall: ${firewall_name}（tag ${network_tag} の VM に ${iap_range} からの tcp:22 だけを許す）"
if read_gcloud compute firewall-rules describe "$firewall_name" --project "$project" --format='value(name)' >/dev/null; then
  info "既にある"
else
  change compute firewall-rules create "$firewall_name" --project "$project" --network="$network" \
    --direction=INGRESS --action=ALLOW --rules=tcp:22 --source-ranges="$iap_range" \
    --target-tags="$network_tag" --description="hc-remote: SSH through IAP only"
fi

# --- 5. quota（被害の上限） ---
# 鍵が dev のエージェントに使われた・漏れた場合でも、作れる VM の大きさ・台数を quota で固定する。
# VM は IAM 条件で ${zone} にしか作れないので、その region（${region}）の quota だけを見る。
# 下げるだけで上げない。使用中の分を下回る値にはしない（--allow-quota-decrease-below-usage を付けない）。
section "quota: region ${region} の CPU・GPU（hc-remote の上限 ${max_vcpus} vCPU）"
quota_plan="$tmp_dir/quota-plan.tsv"
region_json="$tmp_dir/region.json"
family_json="$tmp_dir/vm-family.json"
read_gcloud compute regions describe "$region" --project "$project" --format=json >"$region_json" || : >"$region_json"
read_gcloud beta quotas info describe CPUS-PER-VM-FAMILY-per-project-region --service=compute.googleapis.com \
  --project="$project" --format=json >"$family_json" || : >"$family_json"
if [[ ! -s "$family_json" ]]; then
  info "機種別（N4・C4 など）の CPU の quota を読めなかった"
  ((apply)) && die "quota を確かめられないので、鍵を作らずに止めます"
fi
if [[ ! -s "$region_json" ]]; then
  info "region の quota を読めなかった（gcloud の認証を確かめてください）"
  ((apply)) && die "quota を確かめられないので、鍵を作らずに止めます"
else
  python3 - "$region_json" "$family_json" "$region" "$max_vcpus" >"$quota_plan" <<'QUOTA'
import json, math, sys

region_path, family_path, region, cap = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])


def quota_id(metric):
    return metric.replace("_", "-") + "-per-project-region"


rows = []
for quota in json.load(open(region_path)).get("quotas", []):
    metric = quota["metric"]
    if metric.startswith("COMMITTED_") or not (metric.endswith("_CPUS") or metric == "CPUS" or metric.endswith("_GPUS")):
        continue
    limit, usage = quota.get("limit", 0), quota.get("usage", 0)
    used = math.ceil(usage)
    if metric in ("CPUS", "E2_CPUS"):
        # E2・N1 は CPUS を使う（E2_CPUS も同じ上限にしておく）。hc-remote の VM はここに入る。
        target, note = used + cap, f"使用中 {used} + hc-remote {cap}"
    elif metric == "PREEMPTIBLE_CPUS":
        if limit == 0:
            # 一度も申請していない project では、Spot は CPUS を使う。preference を作ると申請扱いになりうるので触らない。
            rows.append(("keep", quota_id(metric), f"region={region}", metric, limit, usage, "-", "0 のまま（Spot は CPUS を使う）"))
            continue
        target, note = used + cap, f"使用中 {used} + hc-remote {cap}"
    else:
        target, note = used, f"使用中 {used}（hc-remote は使わない）"
    action = "lower" if limit > target else "ok"
    rows.append((action, quota_id(metric), f"region={region}", metric, limit, usage, target, note))

try:
    family = json.load(open(family_path))
except (OSError, ValueError):
    family = {}
for info in family.get("dimensionsInfos", []):
    dims = info.get("dimensions", {})
    if dims.get("region") != region or "vm_family" not in dims:
        continue
    value = info.get("details", {}).get("value")
    label = f"CPUS_PER_VM_FAMILY({dims['vm_family']})"
    if value is None:
        rows.append(("keep", "CPUS-PER-VM-FAMILY-per-project-region", "-", label, "-", "-", "-", "値なし（変えない）"))
        continue
    limit = int(value)
    action = "lower" if limit > 0 else "ok"
    rows.append((action, "CPUS-PER-VM-FAMILY-per-project-region", f"region={region},vm_family={dims['vm_family']}",
                 label, limit, "?", 0, "hc-remote は使わない（使用中なら API が拒否する）"))

def fmt(value):
    return str(int(value)) if isinstance(value, float) and value.is_integer() else str(value)


for row in rows:
    print("\t".join(fmt(x) for x in row))
QUOTA
  gpu_nonzero=0
  quota_failed=0
  while IFS=$'\t' read -r action qid dims label limit usage target note; do
    [[ "$label" == *GPUS* && "$limit" != 0 ]] && gpu_nonzero=1
    case "$action" in
      ok) info "$(printf '%-34s 上限 %-6s 使用 %-5s → そのまま（%s 以下）' "$label" "$limit" "$usage" "$target")" ;;
      keep) info "$(printf '%-34s 上限 %-6s 使用 %-5s → %s' "$label" "$limit" "$usage" "$note")" ;;
      lower)
        info "$(printf '%-34s 上限 %-6s 使用 %-5s → %s に下げる（%s）' "$label" "$limit" "$usage" "$target" "$note")"
        preference_id="hc-remote_$(tr 'A-Z' 'a-z' <<<"${label}" | tr -c 'a-z0-9\n' '-' | sed 's/-*$//')_${region}"
        change beta quotas preferences update "$preference_id" --allow-missing --project="$project" \
          --service=compute.googleapis.com --quota-id="$qid" --dimensions="$dims" --preferred-value="$target" \
          --allow-high-percentage-quota-decrease --justification="hc-remote damage cap (dotfiles #57)" --quiet \
          </dev/null || quota_failed=1
        ;;
    esac
  done <"$quota_plan"
  if ((gpu_nonzero)); then
    info "GPU の quota に 0 でないものがある（上の一覧。--apply で使用中の分まで下げる）"
  else
    info "GPU の quota はすべて 0"
  fi
  if ((quota_failed)); then
    die "quota を下げられなかったものがあります。鍵は作らずに止めます（上の gcloud のエラーを確かめてください）"
  fi
  ((apply)) && info "反映の確認: gcloud compute regions describe ${region} --format='table(quotas.metric,quotas.limit,quotas.usage)'"
fi

# --- 6. 鍵 ---
section "service account の鍵: ${key_file}（0600、ディレクトリは 0700）"
if [[ -s "$key_file" ]]; then
  info "既にある（作り直すときは docs/hc-remote-gcp.md の手順で古い鍵を無効にしてから消す）"
elif ((apply)); then
  (umask 077 && mkdir -p "$key_dir")
  chmod 700 "$key_dir"
  partial="${key_file}.partial"
  rm -f "$partial"
  printf '  +   %s\n' "$(quote_command gcloud iam service-accounts keys create "$partial" --iam-account="$sa_email" --project "$project")"
  if ! (umask 077 && gcloud iam service-accounts keys create "$partial" --iam-account="$sa_email" --project "$project") 2>"$tmp_dir/key.err"; then
    rm -f "$partial"
    cat "$tmp_dir/key.err" >&2
    if grep -qiE 'disableServiceAccountKeyCreation|constraints/iam' "$tmp_dir/key.err"; then
      die "組織のポリシー（iam.disableServiceAccountKeyCreation）で鍵を作れません。鍵を使わない方法は docs/hc-remote-gcp.md を見てください"
    fi
    die "鍵を作れませんでした（上の gcloud のエラーを確かめてください）"
  fi
  chmod 600 "$partial"
  mv "$partial" "$key_file"
  info "作った: $key_file"
else
  printf '  (dry-run) %s\n' "$(quote_command gcloud iam service-accounts keys create "$key_file" --iam-account="$sa_email" --project "$project")"
fi

# --- 7. budget ---
budget_manual() {
  info "budget を作れない・確かめられないときは手で作ってください: Cloud Console の「お支払い」→「予算とアラート」で、"
  info "  対象 project ${project}、ラベル ${budget_label}、月の金額、しきい値 50%・90%・100% の予算 ${budget_name} を作る"
}
section "budget のアラート: ${budget_name}（project ${project} のうちラベル ${budget_label} の使用額）"
if ((!budget)); then
  info "--no-budget のため作らない"
else
  billing_account="$(read_gcloud billing projects describe "$project" --format='value(billingAccountName)' || true)"
  billing_account="${billing_account#billingAccounts/}"
  currency=""
  [[ -n "$billing_account" ]] && currency="$(read_gcloud billing accounts describe "$billing_account" --format='value(currencyCode)' || true)"
  if [[ -z "$budget_amount" ]]; then
    case "$currency" in
      USD) budget_amount=10 ;;
      JPY) budget_amount=1500 ;;  # #56 の GCP の月の予算 $10 のおよその円換算
    esac
  fi
  if [[ -z "$billing_account" || -z "$currency" || -z "$budget_amount" ]]; then
    info "課金アカウント・通貨・金額を確かめられない（account='${billing_account}' currency='${currency}'）"
    budget_manual
  else
    info "課金アカウント ${billing_account}、金額 ${budget_amount} ${currency}/月（アラートだけで、課金は止まらない）"
    if [[ -z "$(read_gcloud services list --enabled --project "$project" --filter=config.name=billingbudgets.googleapis.com --format='value(config.name)')" ]]; then
      change services enable billingbudgets.googleapis.com --project "$project"
    fi
    existing_budget="$(read_gcloud billing budgets list --billing-account="$billing_account" --billing-project="$project" \
      --filter="displayName=${budget_name}" --format='value(name)' || true)"
    if [[ -n "$existing_budget" ]]; then
      info "既にある: $existing_budget（金額を変えるときは gcloud billing budgets update）"
    elif ! change billing budgets create --billing-account="$billing_account" --billing-project="$project" \
      --display-name="$budget_name" --budget-amount="${budget_amount}${currency}" \
      --filter-projects="projects/${project}" --filter-labels="$budget_label" --calendar-period=month \
      --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0; then
      budget_manual
    fi
  fi
fi

section "このあと"
if ((apply)); then
  info "1. 鍵を dev に渡す（Windows の PowerShell、1 行）:"
  info "   wsl -d Ubuntu-24.04 -- sh -c 'cat ~/.config/hc-remote/gcp-key.json' | wsl -d dev -- sh -c 'umask 077; mkdir -p ~/.config/hc-remote; cat > ~/.config/hc-remote/gcp-key.json'; wsl --terminate Ubuntu-24.04"
  info "2. dev で専用の gcloud 設定を作り、疎通を確かめる: docs/hc-remote-gcp.md の「dev で使う」"
  info "3. 実行時に admin は要らない。admin の作業が終わったら PowerShell で wsl --terminate Ubuntu-24.04"
else
  info "内容を確かめたら --apply で実行する。作ったものの意味と消し方は docs/hc-remote-gcp.md"
fi
