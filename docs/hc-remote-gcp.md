# hc-remote が GCP の VM を使うための service account（Issue #57）

dev ディストリの hc-remote（gcp backend、Issue #56）は、ユーザー本人の gcloud の資格情報ではなく、VM の操作だけに絞った専用の service account（SA）`hc-remote-runner` の鍵で GCP を使います。専用の project は作らず、今の project `first-impression-490413` の中で IAM 条件付きの権限にします（2026-11-23 のユーザーの決定）。同じ project で動いているユーザーの別用途の VM `ts-crawler-*` とそのインスタンステンプレートには触れられない権限にします。

用意は admin（`Ubuntu-24.04`）で `wsl/admin/setup-hc-remote-gcp.sh` が行います。admin は秘密情報の置き場、dev はエージェントの境界という方針（[wsl-dev-distro.md](wsl-dev-distro.md)）に合わせ、SA を作る操作はユーザーの資格情報がある admin で行い、dev には鍵だけを渡します。鍵は dev にそのまま置きます（2026-11-23 のユーザーの決定。dev のエージェントは復号もできるので、暗号化は守りにならない）。そのかわり、鍵で起こせる被害の上限を IAM 条件と quota で固定します（下の「被害の上限」）。

### admin は実行時に要らない

hc-remote の実行（VM の作成・SSH・削除）は dev の中の鍵と `CLOUDSDK_CONFIG` だけで完結し、admin を起動しておく必要はありません。admin と dev を同時に起動すると同じ WSL の VM のメモリを食うので、admin を起動するのは次のときだけにし、終わったら止めます。

- 最初のセットアップ（このスクリプトの dry-run・`--apply`、鍵を dev に渡す）
- 鍵の作り直し・無効化、権限・quota の見直し、全部を消すとき

```powershell
wsl --terminate Ubuntu-24.04   # admin の作業が終わったら（Windows の PowerShell）
```

## gcp backend（#56）との約束

| 項目 | 値 |
| --- | --- |
| gcloud の設定 | `CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud`（dev の `~/.config/gcloud` は使わない） |
| 鍵 | `~/.config/hc-remote/gcp-key.json`（0600、ディレクトリは 0700） |
| SA | `hc-remote-runner@first-impression-490413.iam.gserviceaccount.com` |
| VM・disk の名前 | `hc-remote-` で始める（boot disk の名前は VM と同じ既定のままにする）。ゾーンは `asia-northeast1-a` |
| VM の作り方 | `--no-service-account --no-scopes`、network tag `hc-remote`、ラベル `hc-remote=1`、metadata `block-project-ssh-keys=TRUE` と作成時の `ssh-keys` |
| SSH | `gcloud compute ssh/scp --tunnel-through-iap`（IAP 経由） |

この約束から外れる操作（別の名前・別のゾーンの VM、SA を付けた VM、project の metadata への SSH 鍵の追加）は、権限がないため失敗します。

## admin で実行する

```bash
bash ~/dotfiles/wsl/admin/setup-hc-remote-gcp.sh            # dry-run: 作るもの・権限・条件の式・今の状態を表示する（GCP は読み取りだけ）
bash ~/dotfiles/wsl/admin/setup-hc-remote-gcp.sh --apply    # 実際に作る（ユーザーが dry-run の内容を確かめてから）
```

- 既定は dry-run です。変更系の gcloud（作成・付与・鍵・budget）は `--apply` のときだけ呼びます。dry-run でも、今あるものを表示するために読み取り（`describe`・`list`）は呼びます。
- 何度実行しても同じ状態になります。既にあるものは作り直しません。カスタムロールの権限だけは、毎回スクリプトの定義にそろえます（`gcloud iam roles update`）。
- 引数: `--project`・`--zone`・`--network`（既定 `default`）・`--key-dir`（既定 `~/.config/hc-remote`）・`--max-vcpus N`（既定 16）・`--budget-amount N`・`--no-budget`。
- 順番: API → SA → ロール → 付与 → firewall → quota → 鍵 → budget。quota を下げられなかったときは、鍵を作らずに止まります（被害の上限がない鍵を作らない）。
- dev（`/etc/dotfiles-role` が `dev`）では実行しません。

### 作るもの

| もの | 名前 | 内容 |
| --- | --- | --- |
| API | `iap.googleapis.com` | IAP 経由の SSH に要る（2026-11-23 時点で無効だった） |
| API | `cloudquotas.googleapis.com` | quota を下げる（quota preference）のに使う |
| quota | region `asia-northeast1` の CPU・GPU | 下の「被害の上限」。下げるだけで上げない |
| SA | `hc-remote-runner` | 鍵だけで使う。VM には付けない |
| カスタムロール | `hcRemoteRunner` | VM・disk の操作。下の名前の条件付きで付与 |
| カスタムロール | `hcRemoteReader` | 条件を付けられない読み取り。条件なしで付与 |
| カスタムロール | `hcRemoteSubnetUser` | subnetwork に NIC を繋ぐ権限だけ。条件なしで付与 |
| 付与 | `roles/iap.tunnelResourceAccessor` | IAP の TCP 転送。条件 `destination.port == 22` |
| firewall | `hc-remote-allow-iap-ssh` | network `default`、tag `hc-remote` の VM に `35.235.240.0/20`（IAP）からの tcp:22 だけを許す |
| 鍵 | admin の `~/.config/hc-remote/gcp-key.json` | 0600。組織のポリシーで作れなければ理由を出して止まる |
| budget | `hc-remote` | project のうちラベル `hc-remote=1` の使用額。しきい値 50%・90%・100% でメール。課金アカウントが JPY なので既定 1500 円（#56 の $10 のおよその換算）。作れなければ手順を表示して先へ進む |

budget はアラートだけで、課金を止めません。使い過ぎは hc-remote の記録上の予算（#56）と VM の `--max-run-duration` で抑えます。

## 権限と理由

### `hcRemoteRunner`（条件付き）

| 権限 | 使う場面 |
| --- | --- |
| `compute.instances.create` | VM を作る |
| `compute.instances.delete` | VM を消す（成功・失敗・中断・`hc-remote gc`） |
| `compute.instances.get` | 状態・IP の取得、`gcloud compute ssh/scp` |
| `compute.instances.getSerialPortOutput` | 起動の失敗を調べる |
| `compute.instances.setLabels` | 作成時のラベル `hc-remote=1,hc-remote-job=<id>` |
| `compute.instances.setMetadata` | 作成時の `ssh-keys`・`block-project-ssh-keys`・起動スクリプト。`gcloud compute ssh` が VM の metadata に鍵を足すとき |
| `compute.instances.setScheduling` | Spot・`--instance-termination-action=DELETE`・`--max-run-duration` の設定（作成時に要るかは公式ドキュメントで確かめられなかったので、名前の条件の中で付けておく） |
| `compute.instances.setTags` | 作成時の network tag `hc-remote` |
| `compute.disks.create` | 作成時の boot disk |
| `compute.disks.delete` | VM と一緒に boot disk を消す（auto-delete で要るかは公式ドキュメントに書かれていないので、名前の条件の中で付けておく） |
| `compute.disks.get` | 残った disk の確認 |

条件の式（dry-run がそのまま表示します）:

```
(resource.type == "compute.googleapis.com/Instance" && resource.name.startsWith("projects/first-impression-490413/zones/asia-northeast1-a/instances/hc-remote-")) ||
(resource.type == "compute.googleapis.com/Disk" && resource.name.startsWith("projects/first-impression-490413/zones/asia-northeast1-a/disks/hc-remote-"))
```

式の形は Google の [Configure resource-based access](https://cloud.google.com/iam/docs/configuring-resource-based-access) の Compute Engine の例（`resource.type` と `resource.name.startsWith` の組み合わせ）に合わせています。このロールには instance と disk の権限しか入れていないので、例にある「ほかの型はすべて許す」節は付けません。

### `hcRemoteReader`（条件なし、読み取りだけ）

`compute.instances.list`・`compute.zoneOperations.get`・`compute.zones.get`・`compute.zones.list`・`compute.projects.get`・`compute.regions.get`・`compute.machineTypes.get`・`compute.machineTypes.list`。

- `compute.instances.list` などの一覧の権限は project（`cloudresourcemanager.googleapis.com/Project`）に対して確かめられるため、名前の条件では許せません（同じ公式ページ）。`hc-remote gc`（`--filter=labels.hc-remote=1`）と、IAP の公式ドキュメントが `gcloud compute ssh/scp` に要るとする `compute.instances.list` のために付けます。
- `compute.projects.get` は `gcloud compute ssh/scp` が project の metadata（OS Login の設定）を読むのに使います（[Using IAP for TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding) の権限の表）。
- `compute.zoneOperations.get` は作成・削除の完了待ちに使います。operation の名前は `operation-…` なので名前では絞れません。

### `hcRemoteSubnetUser`（条件なし）

`compute.subnetworks.use`・`compute.subnetworks.useExternalIp`。VM の NIC を `default` の subnetwork に外部 IP 付きで繋ぐのに要ります（VM が uv・apt で外へ出るため。Cloud NAT は使わない）。名前で絞る対象ではないので、この 2 つだけのロールにして型で許します。

### IAP（`roles/iap.tunnelResourceAccessor`、条件 `destination.port == 22`）

`iap.tunnelInstances.accessViaIAP`（と、使っていない `iap.tunnelDestGroups.accessViaIAP`）。IAP の tunnel の `resource.name` の形は公式ドキュメントで確かめられなかったため、VM の名前では絞らず、公式の例にある port 22 だけの条件にします。

### 付けない権限

- VM に SA を付ける権限（`compute.instances.setServiceAccount`、`iam.serviceAccounts.actAs`）。VM は `--no-service-account --no-scopes` で作るので要りません。
- project の metadata を書く権限（`compute.projects.setCommonInstanceMetadata`）。SSH 鍵は VM の metadata にだけ入れます。
- インスタンステンプレート・MIG・firewall・IAM・Secret Manager・Storage など、VM の操作以外の権限すべて。

## ts-crawler に触れられない根拠

- 変更・削除の権限（`hcRemoteRunner`）は、名前が `projects/first-impression-490413/zones/asia-northeast1-a/instances/hc-remote-` で始まる instance と、同じ接頭辞の disk にだけ効きます。`ts-crawler-*` の VM と disk は条件に当たらないので、削除・停止・metadata・ラベル・tags の変更はできません（停止・再起動などの権限はそもそも付けていません）。dry-run は、今ある VM のうち条件に当たるもの・当たらないものの数を表示します。
- `ts-crawler-*` のインスタンステンプレートとマネージドインスタンスグループには、どの権限も付けません。
- IAP の付与は port 22 にしか絞れていないので、SA は `ts-crawler-*` の port 22 へ tunnel を張ることはできます。ただし、`ts-crawler-*` の metadata にも project の metadata にも SSH 鍵を書けず、OS Login の権限（`compute.instances.osLogin`）もないため、ログインはできません。なお、今の project には `default-allow-ssh`（`0.0.0.0/0` からの tcp:22）があるので、IAP の firewall は新しい到達経路を増やしません。
- 条件付きの付与は、同じロールの条件なしの付与があると効きません。`hcRemoteRunner` は条件付きでだけ付与します（スクリプトは条件なしで付けません）。

### 残る露出（承知の上で付けるもの）

- `compute.instances.list` は project のすべての VM の内容を返すため、SA は `ts-crawler-*` の metadata（2026-11-23 時点で `startup-script` のキーがある）を読めます。`startup-script` に秘密情報を直書きしているなら、Secret Manager などへ移してください。
- SA は `hc-remote-*` の VM を、マシンタイプを問わず quota の範囲で作れます。費用の上限は hc-remote の予算（#56）と budget のアラートで見ます。
- `hc-remote-*` の VM は外部 IP を持ち、既存の `default-allow-ssh` によりインターネットから port 22 に届きます（認証はジョブごとの SSH 鍵だけ）。`default-allow-ssh` を絞るかどうかは別に扱います（この Issue の対象外）。

## 被害の上限

鍵が dev のエージェントに使われた、または dev から漏れた場合に起こせることの上限です。

### 操作できるもの

- 作成・削除・変更できるのは、ゾーン `asia-northeast1-a` の名前が `hc-remote-` で始まる VM と disk だけです（IAM 条件）。`ts-crawler-*`、インスタンステンプレート、MIG、firewall、IAM、project の metadata、ほかのサービス（Cloud Run・Secret Manager・Storage など）は変えられません。
- 読めるのは、project の VM の一覧（metadata を含む）・ゾーン・マシンタイプ・operation などの Compute Engine の読み取りだけです。

### 台数・大きさ（quota）

IAM 条件で VM を `asia-northeast1-a` にしか作れないため、効くのは region `asia-northeast1` の quota だけです。ほかの region の quota は、そもそも VM を作れないので関係しません。スクリプトは region の quota を次のように下げます（`--apply` のときだけ。dry-run は今の値と下げた後の値を表示します）。

| quota | 下げた後の値 | 理由 |
| --- | --- | --- |
| `CPUS`（E2・N1 が使う） | 今の使用分（`ts-crawler-*` など）+ `--max-vcpus`（既定 16） | hc-remote の VM（E2）はここを使う |
| `E2_CPUS` | `CPUS` と同じ | 公式ドキュメントでは E2 は `CPUS` を使う（2026-11-23 の実測でも `ts-crawler` の e2-small は `CPUS` に数えられ、`E2_CPUS` の使用は 0）。念のため同じ上限にそろえる |
| `PREEMPTIBLE_CPUS` | 今 0 なら触らない。0 でなければ `CPUS` と同じ考え方 | 下の「Spot が使う quota」 |
| ほかの機種の CPU（`N2_CPUS`・`C2_CPUS`・`M1_CPUS` など、`CPUS_PER_VM_FAMILY` の `N4`・`C4`・`E4` など） | 今の使用分（ふつう 0） | hc-remote は使わない。残すと鍵でそれらの大きな VM を作れてしまう |
| GPU（`NVIDIA_*_GPUS`・`PREEMPTIBLE_NVIDIA_*_GPUS`） | 今の使用分（0） | hc-remote は GPU を使わない（#56 の対象外）。2026-11-23 時点で T4・L4・V100・P100・P4 などが 1 ずつあった |

- 下げ方は Cloud Quotas API の quota preference です（`gcloud beta quotas preferences update <id> --allow-missing … --preferred-value=N --allow-high-percentage-quota-decrease`）。10% を超える引き下げには `--allow-high-percentage-quota-decrease` が要ります。使用中の分より下げる `--allow-quota-decrease-below-usage` は付けないので、使用中の quota を誤って下げることはありません（API が拒否し、スクリプトは鍵を作らずに止まる）。
- preference の ID は `hc-remote_<quota>_<region>` です。値を戻すときは同じ ID で `--preferred-value` を変えます（引き上げは Google の審査が入ることがあります）。
- 目標の値は実行したときの使用分から決めます（実行中の VM だけを数える）。再実行すると、そのときの使用分で計算し直し、今の上限より低い場合だけ下げます（上げません）。hc-remote の VM が動いていないときに実行してください。
- 停止中の VM は使用分に数えられません。dry-run は、条件に当たらない既存の VM の機種と状態を表示します。停止中の E2・N1 以外の VM があれば、その機種の quota が 0 になって再起動できなくなるので、`--apply` の前に確かめます（2026-11-23 時点では `ts-crawler-detail-loop-4zzn`（e2-small、RUNNING）の 1 台だけ）。
- 反映には時間がかかることがあります。`gcloud compute regions describe asia-northeast1 --format='table(quotas.metric,quotas.limit,quotas.usage)'` で確かめます。
- `INSTANCES`（24）・`IN_USE_ADDRESSES`（外部 IP、8）・`DISKS_TOTAL_GB`（4096）・`SSD_TOTAL_GB`（500）は変えません。外部 IP の quota により、同時に作れる hc-remote の VM は多くても 7 台程度です。

### Spot が使う quota

公式ドキュメント（[Allocation quotas](https://cloud.google.com/compute/resource-usage) の Preemptible quotas）によれば、Spot・preemptible の VM は `PREEMPTIBLE_CPUS` を使いますが、「project に preemptible の quota がなく、一度も申請したことがない場合は、標準の quota（`CPUS`）を使う」。一度 preemptible の quota を得ると、標準の quota には戻れません。2026-11-23 時点でこの project の `PREEMPTIBLE_CPUS` は 0 なので、hc-remote の Spot VM は `CPUS` を使い、`CPUS` の上限で抑えられます。`PREEMPTIBLE_CPUS` に preference を作ると申請とみなされて Spot が作れなくなるおそれがあるため、0 のときは触りません（この「preference を作ると申請扱いになるか」は公式ドキュメントで確かめられなかった点です）。

### 最大の時間単価の目安

鍵で作れる最大は、`CPUS` の残り 16 vCPU 分の E2 の VM（メモリは E2 の上限の 8 GB/vCPU で 128 GB）と、その disk・外部 IP です。SA は Spot でない VM も作れるので、通常の料金で見積もります。

- E2 16 vCPU・128 GB（e2-highmem-16 相当）: 東京で 1 時間あたりおよそ $1（公式の料金表は us-central1 で約 $0.72、東京はその 1.3 倍程度）。
- disk: 標準の永続ディスクを quota の 4096 GB まで作っても 1 時間あたり約 $0.3、SSD の 500 GB で約 $0.15。
- 合計でおよそ $1.5/時間（約 230 円）、放置して 1 か月で約 $1,100 が目安の上限です。料金は公式の料金表（[VM instance pricing](https://cloud.google.com/compute/vm-instance-pricing)、[Disk pricing](https://cloud.google.com/compute/disks-image-pricing)）で確かめた値ではなく目安です。

hc-remote 自身は VM に `--max-run-duration` を付けるので、通常の使い方では VM は自分で消えます。上の上限は、鍵を悪用して長時間動く VM を作られた場合のものです。budget のアラート（ラベル `hc-remote=1` だけを数える）は、ラベルを付けずに作られた VM を数えないので、異常に気づくには請求額の全体のアラートも見てください。

### 悪用・漏えいに気づいたら

admin を起動して、まず鍵を無効にします（すぐ効き、`enable` で戻せます）。

```bash
P=first-impression-490413; SA=hc-remote-runner@$P.iam.gserviceaccount.com
gcloud iam service-accounts keys list --iam-account="$SA" --managed-by=user
gcloud iam service-accounts keys disable <KEY_ID> --iam-account="$SA"
gcloud compute instances list --filter='name~^hc-remote-'      # 作られた VM を確かめて消す
gcloud compute instances delete <名前> --zone asia-northeast1-a
```

SA ごと止めるときは `gcloud iam service-accounts disable "$SA"` です。終わったら `wsl --terminate Ubuntu-24.04` で admin を止めます。鍵の作り直しは下の「鍵の作り直し・無効化」。

## 公式ドキュメントで確かめられなかった点

- VM の作成（`compute.instances.create`・`compute.disks.create`）で、名前の条件が作る VM・disk の名前で評価されること。Compute Engine の作成の権限の表は「project に対して」と書いており、名前の条件の公式の例も作成について明言していません。`--apply` の後に下の「適用後の確認」で確かめます。作成が拒否された場合は、条件に `resource.type == "cloudresourcemanager.googleapis.com/Project"` の節を足すと作成だけが通ります（削除・変更は VM に対して確かめられるので、ts-crawler には効かないまま）。ただし、その場合は任意の名前の VM を作れるようになります。
- auto-delete の boot disk を VM と一緒に消すときに `compute.disks.delete` が要るか（念のため付けています）。
- Spot・`--max-run-duration` の作成に `compute.instances.setScheduling` が要るか（念のため付けています）。
- IAP の tunnel の `resource.name` の形（分からないので port だけで絞っています）。
- Debian の公開 image（`debian-cloud`）を使う権限（`compute.images.useReadOnly`）。公開 image は誰でも使える前提で、付けていません。
- quota preference による引き下げが自動で反映されるか（公式ドキュメントは「宣言的で、最新の preference を満たそうとする」とだけ書いている）と、`PREEMPTIBLE_CPUS` に preference を作ると preemptible の quota の申請とみなされるか。
- quota preference の ID の長さ・文字の制限（`hc-remote_<quota>_<region>` の形で、長いもので 60 文字程度）。
- 最大の時間単価（目安で、料金表の東京の値で確かめていない）。

## dev で使う

### 1. 鍵を dev に渡す（Windows の PowerShell、1 行）

admin を一時的に起動して鍵を読むだけで、読み終わったら admin を止めます。

```powershell
wsl -d Ubuntu-24.04 -- sh -c 'cat ~/.config/hc-remote/gcp-key.json' | wsl -d dev -- sh -c 'umask 077; mkdir -p ~/.config/hc-remote; cat > ~/.config/hc-remote/gcp-key.json'; wsl --terminate Ubuntu-24.04
```

Windows PowerShell 5.1 は途中で改行を CRLF に変えることがありますが、JSON なので gcloud はそのまま読めます。

### 2. 専用の gcloud 設定を作る（dev）

```bash
export CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud
gcloud auth activate-service-account --key-file ~/.config/hc-remote/gcp-key.json
gcloud config set project first-impression-490413
gcloud config set compute/zone asia-northeast1-a
gcloud config set core/disable_usage_reporting true
```

hc-remote（#56）は、この `CLOUDSDK_CONFIG` を自分で指定して gcloud を呼びます。シェルの既定の `~/.config/gcloud` には何も入れません。

### 3. dev の `~/.config/gcloud` からユーザー本人の資格情報を消す（dev）

dev は admin の複製なので、admin のユーザー本人の gcloud の資格情報が `~/.config/gcloud` に入っています。dev では使わないので消します。`gcloud auth revoke` は使わないでください（admin と同じ資格情報を Google 側で無効にするため、admin の gcloud も使えなくなります）。

```bash
rm -rf ~/.config/gcloud
```

`wsl/dev/verify-dev-boundary.sh` は、`~/.config/gcloud` と `~/.config/hc-remote/gcloud` に service account 以外のアカウントの資格情報（`credentials.db`・`access_tokens.db`・`legacy_credentials/`・ユーザーの `application_default_credentials.json`）があれば NG にします。

### 4. 疎通を確かめる（dev）

```bash
CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud gcloud compute zones list --filter=name=asia-northeast1-a
```

`asia-northeast1-a` が表示されれば完了です。繋がらないときは、塞いでいるものを次の順で特定します（直すのは別の Issue で扱います）。

```bash
getent hosts oauth2.googleapis.com compute.googleapis.com tunnel.cloudproxy.app   # 名前が引けるか（DNS）
curl -sS -o /dev/null -w '%{http_code}\n' https://oauth2.googleapis.com/          # HTTPS で届くか（404 などの数字が出れば届いている）
curl -sS -o /dev/null -w '%{http_code}\n' https://compute.googleapis.com/
env | grep -i _proxy                                                               # proxy の設定が入っていないか
CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud gcloud compute zones list --verbosity=debug 2>&1 | tail -20   # gcloud の失敗の理由
```

- 名前が引けない: dev の `/etc/resolv.conf`（WSL の DNS）を確かめる。
- HTTPS が届かない・時間切れ: Windows の firewall・VPN・proxy を確かめる。admin からは届くかを同じ curl で比べる。
- `invalid_grant`・`account not found`: 鍵が壊れている（渡し直す）か、無効にされている（下の「鍵の作り直し」）。
- `PERMISSION_DENIED`: 付与が伝わるまで数分待つ。続くなら admin で dry-run を実行し、付与が揃っているかを見る。

`gcloud compute ssh --tunnel-through-iap` は、加えて `tunnel.cloudproxy.app` へ WebSocket（443）で繋ぎます。

## 適用後の確認（admin、読み取りだけ）

Policy Troubleshooter（`policytroubleshooter.googleapis.com` を有効にする必要があります）で、条件が効いていることを確かめます。

```bash
P=first-impression-490413; Z=asia-northeast1-a; SA=hc-remote-runner@$P.iam.gserviceaccount.com
for vm in ts-crawler-detail-loop-4zzn hc-remote-probe; do
  gcloud policy-intelligence troubleshoot-policy iam "//compute.googleapis.com/projects/$P/zones/$Z/instances/$vm" \
    --principal-email="$SA" --permission=compute.instances.delete \
    --resource-name="//compute.googleapis.com/projects/$P/zones/$Z/instances/$vm" \
    --resource-service=compute.googleapis.com --resource-type=compute.googleapis.com/Instance
done
```

`ts-crawler-*` は許可されず、`hc-remote-probe` は許可されれば期待どおりです（`ts-crawler-*` の実際の VM 名は `gcloud compute instances list` で確かめる）。作成の条件（上の「確かめられなかった点」）は、#56 の実機確認（最小の VM で `echo` 1 件）で確かめます。

## 鍵の作り直し・無効化

```bash
P=first-impression-490413; SA=hc-remote-runner@$P.iam.gserviceaccount.com
key_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' ~/.config/hc-remote/gcp-key.json)
gcloud iam service-accounts keys list --iam-account="$SA" --managed-by=user
gcloud iam service-accounts keys disable "$key_id" --iam-account="$SA"   # すぐ止める（enable で戻せる）
gcloud iam service-accounts keys delete "$key_id" --iam-account="$SA"    # 消す（戻せない）
rm ~/.config/hc-remote/gcp-key.json
bash ~/dotfiles/wsl/admin/setup-hc-remote-gcp.sh --apply                # 新しい鍵を作る（ほかは既にあるので変わらない）
```

admin の端末で行い、そのあと「dev で使う」の 1（最後に admin を止める）と 2（`activate-service-account`）をやり直します。鍵が dev から漏れたと思われるときは、まず `disable` します。

### 鍵を作れないとき

組織のポリシー `iam.disableServiceAccountKeyCreation` が効いていると、スクリプトは理由を表示して止まります（2026-11-23 時点でこの project は組織に属さず、ポリシーは効いていません）。dev にユーザー本人の資格情報を置かない方針のままでは代わりの方法がないため、ポリシーの例外を作るか、方針を見直すかをユーザーが決めます。

## 全部を消す

```bash
P=first-impression-490413; SA=hc-remote-runner@$P.iam.gserviceaccount.com
gcloud compute instances list --filter=labels.hc-remote=1            # hc-remote の VM が残っていないか（残っていれば先に消す）
for role in projects/$P/roles/hcRemoteRunner projects/$P/roles/hcRemoteReader projects/$P/roles/hcRemoteSubnetUser roles/iap.tunnelResourceAccessor; do
  gcloud projects remove-iam-policy-binding "$P" --member="serviceAccount:$SA" --role="$role" --all
done
gcloud iam service-accounts delete "$SA"
for role in hcRemoteRunner hcRemoteReader hcRemoteSubnetUser; do gcloud iam roles delete "$role" --project "$P"; done
gcloud compute firewall-rules delete hc-remote-allow-iap-ssh --project "$P"
gcloud billing budgets list --billing-account="$(gcloud billing projects describe $P --format='value(billingAccountName.basename())')" --filter=displayName=hc-remote
gcloud billing budgets delete <上で表示された budget の名前>
rm -rf ~/.config/hc-remote                                            # admin。dev でも同じく消す
```

- 付与を先に外してから SA を消します（SA を先に消すと、付与が `deleted:serviceAccount:…` として残ります）。
- 消したカスタムロールは 7 日間は復元でき、その間に同じ名前で作り直すときは、スクリプトが `gcloud iam roles undelete` してから権限をそろえます。
- `iap.googleapis.com`・`billingbudgets.googleapis.com`・`cloudquotas.googleapis.com` の API は、ほかで使っていなければ `gcloud services disable` で止めてかまいません。
- 下げた quota は自動では戻りません。戻すときは `gcloud beta quotas preferences list --project "$P"` で `hc-remote_` で始まる preference を探し、`gcloud beta quotas preferences update <ID> --preferred-value=<元の値> …` で引き上げを申請します。
- 終わったら `wsl --terminate Ubuntu-24.04` で admin を止めます。
