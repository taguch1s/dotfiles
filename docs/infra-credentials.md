# dev に置く資格情報を被害の上限で層に分ける（Issue #63）

dev ディストリ（エージェントの境界、[wsl-dev-distro.md](wsl-dev-distro.md)）の中から、インフラ（まず GCP）の実際の状態を確かめながら実装できるようにするための決まりです。ユーザー本人の資格情報を dev に置かない方針は変えず、dev に置く資格情報を「漏れた・悪用されたときの被害の上限」で層に分け、層ごとに置き場所と使い方を決めます。

## 原則

1. dev にあるものは、エージェントが使え、外へ持ち出せる前提で扱う（dev の egress は無制限。#26）。dev に置いてよいのは、被害の上限を事前に固定できる資格情報だけ。
2. ユーザー本人の資格情報と、権限を広げられる操作（IAM、SA の鍵、firewall、quota、課金、秘密の値）は admin から出さない。
3. 確認は dev で、変更の実行だけを admin で行う。admin で動かすのは、dry-run が変更系のコマンドをすべて表示するスクリプトだけにする。

## 4 つの層

| 層 | できること | 主体 | 置き場所 | 被害の上限 |
| --- | --- | --- | --- | --- |
| L0 読み取り | 構成・状態・ログの読み取り。秘密の値とデータの本体は含めない | 専用の SA `dev-infra-viewer` | dev の既定の gcloud（`~/.config/gcloud`）。鍵は `~/.config/dev-infra/gcp-viewer-key.json` | 読めるもの = 漏れてよいもの、に絞る。変更は一切できない |
| L1 限定された書き込み | 名前・ラベルで絞った資源の作成・削除 | 用途ごとの SA（今は `hc-remote-runner` だけ） | dev の用途専用の `CLOUDSDK_CONFIG`（例: `~/.config/hc-remote/gcloud`） | IAM 条件 + quota + budget（[hc-remote-gcp.md](hc-remote-gcp.md) の形） |
| L2 開発用の資源への広い書き込み | 種類を問わない作成・削除 | 開発用の project に閉じた SA | dev | project の境界 + budget + quota |
| L3 本番・共有の変更 | IAM、SA の鍵、firewall、quota、課金、秘密の値、本番のデプロイ | ユーザー本人 | admin だけ | dev に置かない |

- **L0** が「読むだけのために admin が要る」不便をなくす層です。作り方は下の「L0 のロール」と「L0 を用意する」。
- **L1** の SA は資源 1 つごとではなく用途ごとに 1 つ作ります（例: hc-remote の VM・disk の操作に `hc-remote-runner`）。1 つの用途は、名前・ラベルの条件で絞れる資源のまとまりと、その被害の上限（IAM 条件 + quota + budget）の組です。新しい用途が出たら、その用途の SA・条件・専用の `CLOUDSDK_CONFIG` を足します。
- **L2** は今は無い。開発用の project が無いため使わない。必要になったら別の Issue で決める（2026-11-29 のユーザーの決定、D-20261129-0124）。
- **L3** は admin（`Ubuntu-24.04`）のユーザー本人の gcloud だけです。

## 実装の流れ

```
dev: スクリプトを書く
dev: dry-run（L0 で今の状態を読み、作るもの・変わるものを表示）
admin: ユーザーが dry-run の表示を確かめて --apply（終わったら admin を止める）
dev: 適用後の状態を L0 で確かめる
```

admin が要るのは `--apply` の 1 回だけです。`wsl/admin/setup-hc-remote-gcp.sh` と `wsl/admin/setup-dev-infra-viewer-gcp.sh` は、dev（`/etc/dotfiles-role` が `dev`）では dry-run だけが動き、`--apply` は gcloud を呼ぶ前に止まります。

admin で `--apply` するスクリプトは dev のエージェントが書いたものです。ユーザーは admin で同じスクリプトの dry-run を実行し、表示された変更系のコマンド（`(dry-run) gcloud …` の行）を読んでから `--apply` します。`--apply` は、dry-run が表示したものと同じ引数で gcloud を呼びます（テストで確かめている）。

## 採らない案

| 案 | 採らない理由 |
| --- | --- |
| ユーザー本人の資格情報を dev に置く | 被害の上限がなくなる（project の所有者の権限、課金、秘密の値） |
| admin に常駐の中継サービスを置く | admin を起動し続けるためメモリを食う。dev から届く localhost のサービスに独自の認可が要り、作るものが大きい。「中継」は、ユーザーが admin で `--apply` することで足りる |
| admin が短命のトークン（1 時間）を作って dev に渡す | 1 時間ごとに admin の起動と手作業が要る。組織がないので有効時間も延ばせない |
| `hc-remote-runner` に読み取りを足して兼用する | 用途の違う権限が 1 つの鍵に混ざり、鍵の無効化も監査も分けられなくなる |
| `roles/viewer` を付ける | 全サービスの読み取りが入り、サービスが増えるたびに勝手に広がるので、上限を固定できない |

## dev にある資格情報の棚卸し（2026-11-29）

| 資格情報 | 置き場所（dev） | 層 | 被害の上限 | 無効化 |
| --- | --- | --- | --- | --- |
| GCP `dev-infra-viewer` | `~/.config/dev-infra/gcp-viewer-key.json`、既定の `~/.config/gcloud` | L0 | 下の「L0 のロール」の読み取りだけ。秘密の値・Cloud Storage のデータ・データアクセスの監査ログは読めない | 下の「鍵の作り直し・無効化」 |
| GCP `hc-remote-runner` | `~/.config/hc-remote/gcp-key.json`、`~/.config/hc-remote/gcloud` | L1 | `hc-remote-*` の VM・disk だけ、quota・budget（[hc-remote-gcp.md](hc-remote-gcp.md) の「被害の上限」） | [hc-remote-gcp.md](hc-remote-gcp.md) の「鍵の作り直し・無効化」 |
| GCP のユーザー本人 | 置かない（admin だけ） | L3 | — | `verify-dev-boundary.sh` が見つけたら NG |
| GitHub（`gh` のトークン） | `~/.config/gh` | 層の外（#26 で受け入れたリスク。スコープは限定していない） | トークンのスコープ（ユーザーのリポジトリへの書き込みを含む） | GitHub の Settings の「Applications」→「Authorized OAuth Apps」で GitHub CLI を取り消し、dev で `gh auth logout` |
| Modal のトークン | `~/.modal.toml` | 層の外（ワークスペース全体。L1 のように資源を絞れない） | Modal のワークスペースの使用額（無料枠と hc-remote の記録上の予算。[hc-remote.md](hc-remote.md)）。Modal の Secret を関数に渡して読める | Modal の Settings の「API Tokens」で取り消す |
| Claude の認証 | `~/.claude` | 層の外（エージェントそのものの認証） | アカウントの使用量 | claude.ai の設定でセッションを取り消し、dev で `/login` し直す |
| AWS | なし（`~/.aws` に資格情報はない） | — | — | — |

この Issue では GCP の L0 を足すだけで、GitHub・Modal・Claude・AWS の資格情報やスコープは変えません。

## L0 のロール

L0 は既定のロールを使うサービスごとに並べ、既定のロールが広すぎるものはカスタムロール `devInfraViewer` に読み取りだけを並べます。一覧は `wsl/admin/setup-dev-infra-viewer-gcp.sh` の `l0_roles` の 1 か所だけです。ロールを外すときは、その 1 行を消して admin で `--apply` します。`--apply` は、一覧にない付与（消したロール・手で足したロール）を `gcloud projects remove-iam-policy-binding … --all` で外します（dry-run にも表示される）。

各ロールの中身は、2026-11-29 に公式ドキュメント（`https://docs.cloud.google.com/iam/docs/roles-permissions/<サービス>`、例: `…/roles-permissions/compute`）のロールの一覧で確かめました。スクリプトは毎回、既定のロールの中身を `gcloud iam roles describe` で読み、付けない権限が入っていれば付与せずに止まります（Google がロールを広げたときに気づくため）。

| ロール | 読めるもの | 確かめたこと |
| --- | --- | --- |
| `roles/compute.viewer` | VM・disk・firewall・network・quota など | 付けない権限なし。シリアルポートの出力（`compute.instances.getSerialPortOutput`）とスクリーンショットは入っていない。get・list 以外は `compute.advice.capacity`・`compute.instances.troubleshoot`・`compute.urlMaps.validate` など読み取りの確認だけ |
| `roles/run.viewer` | Cloud Run のサービス・ジョブ・実行 | 付けない権限なし。`run.jobs.get`・`run.services.get` は設定の全体（環境変数の値を含む）を返す |
| `roles/cloudscheduler.viewer` | Cloud Scheduler のジョブ | 付けない権限なし。`cloudscheduler.jobs.fullView` を含むので、ジョブの HTTP のヘッダ・本文まで読めるものとして扱う |
| `roles/cloudbuild.builds.viewer` | Cloud Build のビルド | 付けない権限なし。ビルドの設定（substitutions・環境変数）を読める |
| `roles/monitoring.viewer` | 指標・アラート・ダッシュボード | 付けない権限なし |
| `roles/logging.viewer` | ログ（データアクセスの監査ログを除く） | `logging.privateLogEntries.list` は入っていない。get・list 以外は `logging.queries.usePrivate`（保存したクエリを使う）だけ |
| `roles/serviceusage.serviceUsageViewer` | 有効な API | 付けない権限なし |
| `roles/cloudquotas.viewer` | quota と quota preference | 付けない権限なし |
| `roles/secretmanager.viewer` | Secret の名前・設定（値は読めない） | `secretmanager.versions.access` は入っていない |
| `projects/first-impression-490413/roles/devInfraViewer` | project の IAM ポリシー、IAM のロール・SA・鍵の一覧（鍵の中身は無い）、Artifact Registry の一覧（ダウンロードはできない） | 下の外したロールの代わり |

外したロール:

| ロール | 外した理由 | 代わり |
| --- | --- | --- |
| `roles/iam.securityReviewer` | `logging.privateLogEntries.list`（データアクセスの監査ログ）を含む（2026-11-29 に公式ドキュメントで確認）。全サービスの list を含み、サービスが増えると広がる | `devInfraViewer` の `resourcemanager.projects.getIamPolicy`・`iam.roles.*`・`iam.serviceAccounts.get/list/getIamPolicy`・`iam.serviceAccountKeys.get/list` |
| `roles/artifactregistry.reader` | `artifactregistry.repositories.downloadArtifacts`・`artifactregistry.files.download` でイメージ・パッケージの中身（データの本体）を取り出せる | `devInfraViewer` の `artifactregistry.{repositories,dockerimages,packages,versions,tags}.{get,list}` |

### 付けない権限

スクリプトの `forbidden_permissions` と `forbidden_roles` が一覧です。スクリプトは起動時に自分の一覧を確かめ、付けない権限・ロールが入っていれば gcloud を呼ぶ前に止まります。`tests/test_setup_dev_infra_viewer_gcp.sh` は、一覧に入れた写しのスクリプトが止まること、既定のロールに入っていたら付与しないことを確かめます。

- 秘密の値・データの本体: `secretmanager.versions.access`、`storage.objects.get`、`artifactregistry.repositories.downloadArtifacts`、`artifactregistry.files.download`
- 鍵・トークンの発行と SA のなりすまし: `iam.serviceAccountKeys.create`、`iam.serviceAccounts.getAccessToken`、`iam.serviceAccounts.getOpenIdToken`、`iam.serviceAccounts.signBlob`、`iam.serviceAccounts.signJwt`、`iam.serviceAccounts.implicitDelegation`、`iam.serviceAccounts.actAs`
- データアクセスの監査ログ: `logging.privateLogEntries.list`
- 変更系すべて: 最後の語が `create`・`update`・`delete`・`undelete`・`set` で始まる権限（`setIamPolicy`・`setMetadata` などを含む）
- ロール: `roles/viewer`・`roles/editor`・`roles/owner`、上の外したロール

### ログを L0 に入れる（D-20261129-0124-2）

`roles/logging.viewer` は L0 に入れます。確認の役に最も立つためです。そのかわり、ログの本文は dev から持ち出せるようになるので、`--apply` の前に、本番の処理が秘密の値をログに出していないことを admin で確かめます（下の「`--apply` の前に admin で確かめること」）。出していたら、`l0_roles` から `roles/logging.viewer` の 1 行を消してから `--apply` します。

### Cloud Storage のデータ（D-20261129-0124-3）

未決。必要になったら別の Issue で、秘密でないデータのバケットに限って決める。L0 には `storage.objects.get` を入れないので、dev から `gcloud storage cp`・`rsync` でデータを取り込めません。

## L0 を用意する（ユーザーが行う）

Issue #63 の実装の後、main に入ってから行います。admin のコマンドは admin（`Ubuntu-24.04`）の端末で、dev のコマンドは dev の端末で、上から 1 行ずつ実行します。

### 1. `--apply` の前に admin で確かめること（admin）

```bash
git -C ~/dotfiles pull --ff-only
gcloud logging read 'textPayload:("password" OR "secret" OR "token" OR "api_key" OR "Bearer") OR jsonPayload.message:("password" OR "secret" OR "token" OR "api_key" OR "Bearer")' --project=first-impression-490413 --freshness=30d --limit=50 --format='value(timestamp,resource.type,textPayload,jsonPayload.message)'
gcloud logging read 'resource.type="cloud_run_job"' --project=first-impression-490413 --freshness=7d --limit=200 --format='value(textPayload,jsonPayload.message)'
gcloud run jobs list --project=first-impression-490413 --format='yaml(metadata.name,spec.template.spec.template.spec.containers[].env)'
gcloud run services list --project=first-impression-490413 --format='yaml(metadata.name,spec.template.spec.containers[].env)'
gcloud scheduler jobs list --project=first-impression-490413 --location=asia-northeast1 --format='yaml(name,httpTarget.uri,httpTarget.headers,httpTarget.body)'
gcloud builds list --project=first-impression-490413 --limit=20 --format='yaml(id,substitutions,steps[].env)'
bash ~/dotfiles/wsl/admin/setup-dev-infra-viewer-gcp.sh
```

- 1〜2 行目のログ: 秘密の値（パスワード・トークン・API キー・接続文字列）が出ていないこと。キーワードに当たった行は、本文を開いて値そのものが出ていないかを見ます。
- Cloud Run の `env`: 秘密の値が `value:` に直書きされておらず、`valueFrom.secretKeyRef`（Secret Manager の参照）になっていること。
- Cloud Scheduler の `headers`・`body`、Cloud Build の `substitutions`・`env`: 秘密の値が直書きされていないこと。Cloud Scheduler のジョブが `asia-northeast1` 以外にあるときは、`--location` をその region にして実行します（`gcloud scheduler locations list --project=first-impression-490413` で一覧）。
- 最後の dry-run: 表示が「付けない権限は入っていない」になっていて、`(dry-run) gcloud …` の行が SA の作成・カスタムロールの作成（または update）・上の表の 10 件の `add-iam-policy-binding`・鍵の作成だけであること。`remove-iam-policy-binding` があれば、外してよい付与かを確かめます。
- 秘密が混ざっていたら `--apply` せず、混ざっていたロール（多くは `roles/logging.viewer`・`roles/run.viewer`・`roles/cloudscheduler.viewer`・`roles/cloudbuild.builds.viewer`）を `l0_roles` から外す Issue を作ります。VM の metadata（`startup-script`）は既に `hc-remote-runner` から読めます（[hc-remote-gcp.md](hc-remote-gcp.md) の「残る露出」）。

### 2. `--apply`（admin）

```bash
bash ~/dotfiles/wsl/admin/setup-dev-infra-viewer-gcp.sh --apply
```

### 3. 鍵を dev に渡す（Windows の PowerShell、1 行。最後に admin を止める）

```powershell
wsl -d Ubuntu-24.04 -- sh -c 'cat ~/.config/dev-infra/gcp-viewer-key.json' | wsl -d dev -- sh -c 'umask 077; mkdir -p ~/.config/dev-infra; cat > ~/.config/dev-infra/gcp-viewer-key.json'; wsl --terminate Ubuntu-24.04
```

### 4. dev の既定の gcloud に登録する（dev）

dev の `~/.config/gcloud` にユーザー本人の資格情報が残っていないことを先に確かめます（`verify-dev-boundary.sh` の gcloud の行が OK であること。残っていれば [hc-remote-gcp.md](hc-remote-gcp.md) の「dev の `~/.config/gcloud` からユーザー本人の資格情報を消す」）。

```bash
bash /home/issei/dotfiles-main/wsl/dev/verify-dev-boundary.sh
gcloud auth activate-service-account --key-file ~/.config/dev-infra/gcp-viewer-key.json
gcloud config set project first-impression-490413
gcloud config set core/disable_usage_reporting true
bash /home/issei/dotfiles-main/wsl/dev/verify-dev-boundary.sh
```

環境変数を付けない `gcloud …` が L0 で動きます。hc-remote は自分の `CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud` を指定して gcloud を呼ぶので、影響を受けません。

### 5. dev で確かめる（dev）

```bash
gcloud compute instances list
gcloud run jobs list
gcloud scheduler jobs list --location=asia-northeast1
gcloud projects get-iam-policy first-impression-490413
bash /home/issei/dotfiles-main/wsl/admin/setup-hc-remote-gcp.sh
bash /home/issei/dotfiles-main/wsl/admin/setup-dev-infra-viewer-gcp.sh
```

- 1〜4 行目が成功すること。`gcloud run jobs list` が region を聞いてきたら、`gcloud run jobs list --region=asia-northeast1` で実行し直します。`gcloud scheduler jobs list` の `--location` は上の 1. と同じ region にします。
- 5 行目（hc-remote の dry-run）が、今ある SA・ロール・firewall・quota の状態を表示すること。budget の節は課金アカウントを読めないため「確かめられない」になり、それで止まらないのが期待どおりです。
- 6 行目（L0 の dry-run）が「付けない権限は入っていない」と表示し、`(dry-run) gcloud …` の行に `add-iam-policy-binding`（付与は既にあっても毎回表示する）とカスタムロールの `update` だけが出ること。
- 秘密の値の読み取り（`gcloud secrets versions access` など）を dev で試さないでください。権限が誤って通っていたときに、値が dev に出てしまいます。「できないこと」は次の 6. で admin から確かめます。

### 6. できないことを確かめる（admin、Policy Troubleshooter）

```bash
gcloud services enable policytroubleshooter.googleapis.com --project=first-impression-490413
gcloud policy-intelligence troubleshoot-policy iam //cloudresourcemanager.googleapis.com/projects/first-impression-490413 --principal-email=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --permission=secretmanager.versions.access
gcloud policy-intelligence troubleshoot-policy iam //cloudresourcemanager.googleapis.com/projects/first-impression-490413 --principal-email=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --permission=compute.instances.delete
gcloud policy-intelligence troubleshoot-policy iam //cloudresourcemanager.googleapis.com/projects/first-impression-490413 --principal-email=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --permission=iam.serviceAccountKeys.create
gcloud policy-intelligence troubleshoot-policy iam //cloudresourcemanager.googleapis.com/projects/first-impression-490413 --principal-email=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --permission=resourcemanager.projects.setIamPolicy
gcloud policy-intelligence troubleshoot-policy iam //cloudresourcemanager.googleapis.com/projects/first-impression-490413 --principal-email=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --permission=compute.instances.list
```

2〜5 行目が許可されず（`NOT_GRANTED`・`access: DENIED` など）、6 行目（比べるための読み取り）が許可されれば期待どおりです。L0 の付与はすべて project に対するものなので、project で確かめれば足ります（個別の Secret・VM に付与を足した場合は、その資源の名前で確かめ直します）。終わったら PowerShell で `wsl --terminate Ubuntu-24.04` で admin を止めます。

## 鍵の作り直し・無効化

組織に属さない project なので、SA の鍵の有効期限は強制できません。`verify-dev-boundary.sh` は、dev の `~/.config/dev-infra/gcp-viewer-key.json` と `~/.config/hc-remote/gcp-key.json` が 90 日より古いと `WARN` を出します（NG ではなく、終了コードも変わらない。D-20261129-0124-4）。日数はファイルの更新時刻（admin から渡した日）で数え、環境変数 `DEV_KEY_MAX_AGE_DAYS` で変えられます。

### 作り直す（L0。admin で新しい鍵を作り、古い鍵を消す）

admin で上から実行します。

```bash
mv ~/.config/dev-infra/gcp-viewer-key.json ~/.config/dev-infra/gcp-viewer-key.old.json
bash ~/dotfiles/wsl/admin/setup-dev-infra-viewer-gcp.sh --apply
gcloud iam service-accounts keys delete "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' ~/.config/dev-infra/gcp-viewer-key.old.json)" --iam-account=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --quiet
rm ~/.config/dev-infra/gcp-viewer-key.old.json
gcloud iam service-accounts keys list --iam-account=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --managed-by=user
```

最後の行で、ユーザーが作った鍵が 1 つだけになっていることを確かめます。そのあと「L0 を用意する」の 3（PowerShell で鍵を渡し、admin を止める）と 4（dev で `activate-service-account`）をやり直します。hc-remote の鍵は [hc-remote-gcp.md](hc-remote-gcp.md) の「鍵の作り直し・無効化」です。

### すぐ止める（漏れたと思われるとき、admin）

```bash
gcloud iam service-accounts keys disable "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' ~/.config/dev-infra/gcp-viewer-key.json)" --iam-account=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com
```

`gcloud iam service-accounts keys enable` で戻せます。戻さないなら、上の「作り直す」を行います。

### L0 を全部消す（admin）

```bash
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/compute.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/run.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/cloudscheduler.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/cloudbuild.builds.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/monitoring.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/logging.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/serviceusage.serviceUsageViewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/cloudquotas.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=roles/secretmanager.viewer --all
gcloud projects remove-iam-policy-binding first-impression-490413 --member=serviceAccount:dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --role=projects/first-impression-490413/roles/devInfraViewer --all
gcloud iam service-accounts delete dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --project=first-impression-490413
gcloud iam roles delete devInfraViewer --project=first-impression-490413
rm -rf ~/.config/dev-infra
```

付与を先に外してから SA を消します。dev では `gcloud auth revoke dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com` と `rm -rf ~/.config/dev-infra` を実行します（SA の資格情報なので、`revoke` しても admin のユーザー本人の資格情報には影響しない）。

## 実装時に確かめたこと・dev では確かめられないこと（2026-11-29）

- 候補のロールの中身: 上の「L0 のロール」のとおり公式ドキュメントで確かめた。`roles/iam.securityReviewer` と `roles/artifactregistry.reader` は外した。
- L0 で読めるものに秘密が混ざっていないこと: dev には資格情報がなく実状態を読めないので、上の「`--apply` の前に admin で確かめること」に入れた。
- 課金アカウントの読み取り: L0 は project の権限だけなので、dev での `setup-hc-remote-gcp.sh` の dry-run の budget の節は「確かめられない」になり、止まらない（`tests/test_setup_hc_remote_gcp.sh` で確かめている）。
- admin での dry-run の表示をユーザーが確かめてから `--apply` する手順: 上の「L0 を用意する」の 1〜2 に書いた。
