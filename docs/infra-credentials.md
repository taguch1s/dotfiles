# dev の資格情報は、権限を絞った service account を認証しておく（Issue #63・#65）

dev ディストリ（エージェントの境界、[wsl-dev-distro.md](wsl-dev-distro.md)）の中から、インフラ（まず GCP）の実際の状態を確かめながら実装できるようにするための決まりです。

## 決まり

> dev にはユーザー本人の資格情報を置かない。dev で使う認証は、権限を絞った service account（SA）を先に認証しておく。SA の権限が、そのまま被害の上限になる。

理由: dev にあるものは、エージェントが使え、外へ持ち出せます（dev の egress は無制限。#26）。だから、鍵を隠すかどうかではなく、その主体に何の権限があるかだけが効きます。dev に置いてよいのは、被害の上限を事前に固定できる資格情報だけです。例外は、下の「dev にある資格情報の棚卸し」で「受け入れたリスク」としたものです。

### dev で使える主体

GCP の主体です。ほかのサービスは下の「dev にある資格情報の棚卸し」にあります。

| 主体 | 置き場所 | できること |
| --- | --- | --- |
| `dev-infra-viewer` | dev の既定の gcloud（`~/.config/gcloud`）。鍵は `~/.config/dev-infra/gcp-viewer-key.json` | 構成・状態・ログの読み取り。秘密の値とデータの本体は含めず、変更は一切できない |
| `hc-remote-runner` | `~/.config/hc-remote/gcloud`（鍵は `~/.config/hc-remote/gcp-key.json`） | `hc-remote-*` の VM・disk の操作。IAM 条件 + quota + budget で上限を固定する（[hc-remote-gcp.md](hc-remote-gcp.md)） |
| ユーザー本人 | admin（`Ubuntu-24.04`）だけ | IAM、SA の鍵、firewall、quota、課金、秘密の値、本番のデプロイ |

### git の認証は dev に通しているのに、なぜ GCP の本人の資格情報は置かないのか

違いは原則ではなく、被害の大きさです。`gh` のトークンがないと、エージェントは push・PR ができません。被害は履歴から戻せて、ruleset と hook で歯止めがあります。GCP の本人の資格情報は project の所有者の権限で、課金・秘密の値・IAM に歯止めがありません。

## 権限を足すとき

読み取りと書き込みで手順が違います。どちらも、足す前に「漏れたときに何が起こせるか」をこの文書に書きます。

### 読み取りを足す

1. 漏れたときに何が起こせるか（何が読めるようになるか）を、下の「読み取り専用 SA のロール」の表に書く。
2. `wsl/admin/setup-dev-infra-viewer-gcp.sh` のロールの一覧 `viewer_roles` に 1 行を足す。既定のロールが広すぎるときは、カスタムロールの一覧 `custom_permissions` に読み取りの権限を足す。
3. 下の「実装の流れ」のとおり、admin で `--apply` して dev で確かめる。

### 書き込みを足す

`dev-infra-viewer` には書き込みを足しません。名前・ラベルで絞れる用途ごとに SA を分けます（`hc-remote-runner` の形）。1 つの用途は、名前・ラベルの条件で絞れる資源のまとまりと、その被害の上限の組です。

1. 漏れたときに何が起こせるかと、その上限（IAM 条件 + quota + budget）を文書に書く。
2. その用途の SA・IAM 条件・quota・budget を、dry-run が変更系のコマンドをすべて表示するスクリプトで作る（「実装の流れ」のとおり admin で `--apply`）。
3. dev には用途専用の `CLOUDSDK_CONFIG` に認証し、`wsl/dev/verify-dev-boundary.sh` の「設定ごとにあってよい SA」に足す。

## 実装の流れ

確認は dev で、変更の実行だけを admin で行います。admin で動かすのは、dry-run が変更系のコマンドをすべて表示するスクリプトだけにします。

```
dev: スクリプトを書く
dev: dry-run（読み取り専用 SA で今の状態を読み、作るもの・変わるものを表示）
admin: ユーザーが dry-run の表示を確かめて --apply（終わったら admin を止める）
dev: 適用後の状態を読み取り専用 SA で確かめる
```

admin が要るのは `--apply` の 1 回だけです。`wsl/admin/setup-hc-remote-gcp.sh` と `wsl/admin/setup-dev-infra-viewer-gcp.sh` は、dev（`/etc/dotfiles-role` が `dev`）では dry-run だけが動き、`--apply` は gcloud を呼ぶ前に止まります。

admin で `--apply` するスクリプトは dev のエージェントが書いたものです。ユーザーは admin で同じスクリプトの dry-run を実行し、表示された変更系のコマンド（`(dry-run) gcloud …` の行）を読んでから `--apply` します。`--apply` は、dry-run が表示したものと同じ引数で gcloud を呼びます（`setup-dev-infra-viewer-gcp.sh` は `tests/test_setup_dev_infra_viewer_gcp.sh` で、表示と呼び出しが同じことを確かめている。`setup-hc-remote-gcp.sh` のテストは、dry-run が変更系を呼ばないことと dev で `--apply` が止まることだけを確かめている）。

## 採らない案

| 案 | 採らない理由 |
| --- | --- |
| ユーザー本人の資格情報を dev に置く | 被害の上限がなくなる（project の所有者の権限、課金、秘密の値） |
| 鍵のファイルは読ませず、CLI だけ使わせる | dev では成り立たない。hc のエージェントは sandbox なしで同じユーザーとして動くので、CLI が読めるファイルは読める。隠せたとしても、エージェントは CLI を通してその権限をすべて使える |
| admin に常駐の中継サービスを置く | admin を起動し続けるためメモリを食う。dev から届く localhost のサービスに独自の認可が要り、作るものが大きい。「中継」は、ユーザーが admin で `--apply` することで足りる |
| admin が短命のトークン（1 時間）を作って dev に渡す | 1 時間ごとに admin の起動と手作業が要る。組織がないので有効時間も延ばせない |
| `hc-remote-runner` に読み取りを足して兼用する | 用途の違う権限が 1 つの鍵に混ざり、鍵の無効化も監査も分けられなくなる |
| `roles/viewer` を付ける | 全サービスの読み取りが入り、サービスが増えるたびに勝手に広がるので、上限を固定できない |
| 開発用の project に閉じた SA に、広い書き込みを持たせる | 開発用の project は作らない。必要になったら別の Issue で決める（2026-11-29 のユーザーの決定、D-20261129-0124） |

## dev にある資格情報の棚卸し（2026-11-29）

| 資格情報 | 置き場所（dev） | 扱い | 被害の上限 | 無効化 |
| --- | --- | --- | --- | --- |
| GCP `dev-infra-viewer` | `~/.config/dev-infra/gcp-viewer-key.json`、既定の `~/.config/gcloud` | 権限を絞った SA | 下の「読み取り専用 SA のロール」の読み取りだけ。秘密の値・Cloud Storage のデータ・データアクセスの監査ログは読めない | 下の「鍵の作り直し・無効化」 |
| GCP `hc-remote-runner` | `~/.config/hc-remote/gcp-key.json`、`~/.config/hc-remote/gcloud` | 権限を絞った SA | `hc-remote-*` の VM・disk だけ、quota・budget（[hc-remote-gcp.md](hc-remote-gcp.md) の「被害の上限」） | [hc-remote-gcp.md](hc-remote-gcp.md) の「鍵の作り直し・無効化」 |
| GCP のユーザー本人 | 置かない（admin だけ） | 置かない | — | `verify-dev-boundary.sh` が見つけたら NG |
| GitHub（`gh` のトークン） | `~/.config/gh` | 受け入れたリスク（#26。スコープは限定していない） | トークンのスコープ（ユーザーのリポジトリへの書き込みを含む） | GitHub の Settings の「Applications」→「Authorized OAuth Apps」で GitHub CLI を取り消し、dev で `gh auth logout` |
| Modal のトークン | `~/.modal.toml` | 受け入れたリスク（ワークスペース全体で、資源を絞れない） | Modal のワークスペースの使用額（無料枠と hc-remote の記録上の予算。[hc-remote.md](hc-remote.md)）。Modal の Secret を関数に渡して読める | Modal の Settings の「API Tokens」で取り消す |
| Claude の認証 | `~/.claude` | 受け入れたリスク（エージェントそのものの認証） | アカウントの使用量 | claude.ai の設定でセッションを取り消し、dev で `/login` し直す |
| AWS | なし（`~/.aws` に資格情報はない） | 置かない | — | — |

#63 で足したのは GCP の `dev-infra-viewer` だけで、GitHub・Modal・Claude・AWS の資格情報やスコープは変えていません。

## 読み取り専用 SA のロール

`dev-infra-viewer` には、既定のロールを使うサービスごとに並べ、既定のロールが広すぎるものはカスタムロール `devInfraViewer` に読み取りだけを並べます。一覧は `wsl/admin/setup-dev-infra-viewer-gcp.sh` の `viewer_roles` の 1 か所だけです。ロールを外すときは、その 1 行を消して admin で `--apply` します。`--apply` は、一覧にない付与（消したロール・手で足したロール）を `gcloud projects remove-iam-policy-binding … --all` で外します（dry-run にも表示される）。

各ロールの中身は、2026-11-29 に公式ドキュメント（`https://docs.cloud.google.com/iam/docs/roles-permissions/<サービス>`、例: `…/roles-permissions/compute`）のロールの一覧で確かめました。スクリプトは毎回、既定のロールの中身を `gcloud iam roles describe` で読み、付けない権限が入っていれば付与せずに止まります（Google がロールを広げたときに気づくため）。

| ロール | 読めるもの | 確かめたこと |
| --- | --- | --- |
| `roles/run.viewer` | Cloud Run のサービス・ジョブ・実行 | 付けない権限なし。`run.jobs.get`・`run.services.get` は設定の全体（環境変数の値を含む）を返す |
| `roles/cloudscheduler.viewer` | Cloud Scheduler のジョブ | 付けない権限なし。`cloudscheduler.jobs.fullView` を含むので、ジョブの HTTP のヘッダ・本文まで読めるものとして扱う |
| `roles/cloudbuild.builds.viewer` | Cloud Build のビルド | 付けない権限なし。ビルドの設定（substitutions・環境変数）を読める。`remotebuildexecution.blobs.get`（Remote Build Execution の保存物の読み取り）も入る。この project では Remote Build Execution を使っていない前提で残す（使い始めたら外すか見直す） |
| `roles/monitoring.viewer` | 指標・アラート・ダッシュボード | 付けない権限なし |
| `roles/logging.viewer` | ログ（データアクセスの監査ログを除く） | `logging.privateLogEntries.list` は入っていない。get・list 以外は `logging.queries.usePrivate`（保存したクエリを使う）だけ |
| `roles/serviceusage.serviceUsageViewer` | 有効な API | 付けない権限なし |
| `roles/cloudquotas.viewer` | quota と quota preference | 付けない権限なし |
| `roles/secretmanager.viewer` | Secret の名前・設定（値は読めない） | `secretmanager.versions.access` は入っていない |
| `projects/first-impression-490413/roles/devInfraViewer` | Compute Engine の VM・disk・snapshot・image・template・network・subnet・firewall・route・router・address・region（quota を含む）・zone・operation の get・list、project の IAM ポリシー、IAM のロール・SA・鍵の一覧（鍵の中身は無い）、Artifact Registry の一覧（ダウンロードはできない） | 下の外したロールの代わり。`setup-hc-remote-gcp.sh` の dry-run が読む `compute.instances.list`・`compute.firewalls.get`・`compute.regions.get`・`compute.projects.get` を含む |

外したロール:

| ロール | 外した理由 | 代わり |
| --- | --- | --- |
| `roles/iam.securityReviewer` | `logging.privateLogEntries.list`（データアクセスの監査ログ）を含む（2026-11-29 に公式ドキュメントで確認）。全サービスの list を含み、サービスが増えると広がる | `devInfraViewer` の `resourcemanager.projects.getIamPolicy`・`iam.roles.*`・`iam.serviceAccounts.get/list/getIamPolicy`・`iam.serviceAccountKeys.get/list` |
| `roles/artifactregistry.reader` | `artifactregistry.repositories.downloadArtifacts`・`artifactregistry.files.download` でイメージ・パッケージの中身（データの本体）を取り出せる | `devInfraViewer` の `artifactregistry.{repositories,dockerimages,packages,versions,tags}.{get,list}` |
| `roles/compute.viewer` | 公式ドキュメントの一覧に `compute.instances.getSerialPortOutput`（VM のシリアルポートの出力。起動ログに秘密が出ることがある）・`compute.instances.getScreenshot`・`compute.instances.getGuestAttributes` が入っているかを、公式ドキュメントで確定できなかった（読み方で結果が分かれた）ので、安全側に外した。全 compute の get・list を含み、サービスが増えると広がる | `devInfraViewer` の `compute.*.get`・`compute.*.list`（上の表） |

### 付けない権限

スクリプトの `forbidden_permissions` と `forbidden_roles` が一覧です。スクリプトは起動時に自分の一覧を確かめ、付けない権限・ロールが入っていれば gcloud を呼ぶ前に止まります。`tests/test_setup_dev_infra_viewer_gcp.sh` は、一覧に入れた写しのスクリプトが止まること、既定のロールに入っていたら付与しないことを確かめます。

- 秘密の値・データの本体: `secretmanager.versions.access`、`storage.objects.get`、`artifactregistry.repositories.downloadArtifacts`、`artifactregistry.files.download`
- 鍵・トークンの発行と SA のなりすまし: `iam.serviceAccountKeys.create`、`iam.serviceAccounts.getAccessToken`、`iam.serviceAccounts.getOpenIdToken`、`iam.serviceAccounts.signBlob`、`iam.serviceAccounts.signJwt`、`iam.serviceAccounts.implicitDelegation`、`iam.serviceAccounts.actAs`
- データアクセスの監査ログ: `logging.privateLogEntries.list`
- VM の中の出力: `compute.instances.getSerialPortOutput`、`compute.instances.getScreenshot`、`compute.instances.getGuestAttributes`
- 変更系すべて: 最後の語が `create`・`update`・`delete`・`undelete`・`set` で始まる権限（`setIamPolicy`・`setMetadata` などを含む）
- ロール: `roles/viewer`・`roles/editor`・`roles/owner`、上の外したロール。`viewer_roles` に入れてよいのは既定のロール（`roles/…`、実行時に中身を確かめる）と `devInfraViewer` だけで、それ以外の `projects/…`・`organizations/…` のロールがあれば止まる
- 一覧にない付与を外すときは、member が `serviceAccount:dev-infra-viewer@…` と完全に同じ付与だけを外す（`deleted:serviceAccount:…` などは触らない）

### ログを読み取り専用 SA に含める（D-20261129-0124-2）

`roles/logging.viewer` は読み取り専用 SA に含めます。確認の役に最も立つためです。そのかわり、ログの本文は dev から持ち出せるようになるので、`--apply` の前に、本番の処理が秘密の値をログに出していないことを admin で確かめます（下の「`--apply` の前に admin で確かめること」）。出していたら、`viewer_roles` から `roles/logging.viewer` の 1 行を消してから `--apply` します。

### Cloud Storage のデータ（D-20261129-0124-3）

未決。必要になったら別の Issue で、秘密でないデータのバケットに限って決める。読み取り専用 SA には `storage.objects.get` を入れないので、dev から `gcloud storage cp`・`rsync` でデータを取り込めません。

## dev の読み取り専用 SA を用意する（ユーザーが行う）

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
- 最後の dry-run: 表示が「付けない権限は入っていない」になっていて、`(dry-run) gcloud …` の行が SA の作成・カスタムロールの作成（または update）・上の表の 9 件の `add-iam-policy-binding`・鍵の作成だけであること。`remove-iam-policy-binding` があれば、外してよい付与かを確かめます。
- 秘密が混ざっていたら `--apply` せず、混ざっていたロール（多くは `roles/logging.viewer`・`roles/run.viewer`・`roles/cloudscheduler.viewer`・`roles/cloudbuild.builds.viewer`）を `viewer_roles` から外す Issue を作ります。VM の metadata（`startup-script`）は既に `hc-remote-runner` から読めます（[hc-remote-gcp.md](hc-remote-gcp.md) の「残る露出」）。

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

環境変数を付けない `gcloud …` が読み取り専用 SA で動きます。hc-remote は自分の `CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud` を指定して gcloud を呼ぶので、影響を受けません。

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
- 6 行目（読み取り専用 SA の dry-run）が「付けない権限は入っていない」と表示し、`(dry-run) gcloud …` の行に `add-iam-policy-binding`（付与は既にあっても毎回表示する）とカスタムロールの `update` だけが出ること。
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

2〜5 行目が許可されず（`NOT_GRANTED`・`access: DENIED` など）、6 行目（比べるための読み取り）が許可されれば期待どおりです。読み取り専用 SA の付与はすべて project に対するものなので、project で確かめれば足ります（個別の Secret・VM に付与を足した場合は、その資源の名前で確かめ直します）。終わったら PowerShell で `wsl --terminate Ubuntu-24.04` で admin を止めます。

## 鍵の作り直し・無効化

組織に属さない project なので、SA の鍵の有効期限は強制できません。`verify-dev-boundary.sh` は、dev の `~/.config/dev-infra/gcp-viewer-key.json` と `~/.config/hc-remote/gcp-key.json` が 90 日より古いと `WARN` を出します（NG ではなく、終了コードも変わらない。D-20261129-0124-4）。日数はファイルの更新時刻（admin から渡した日）で数え、環境変数 `DEV_KEY_MAX_AGE_DAYS` で変えられます。

### 作り直す（読み取り専用 SA。admin で新しい鍵を作り、古い鍵を消す）

admin で上から実行します。

```bash
mv ~/.config/dev-infra/gcp-viewer-key.json ~/.config/dev-infra/gcp-viewer-key.old.json
bash ~/dotfiles/wsl/admin/setup-dev-infra-viewer-gcp.sh --apply
gcloud iam service-accounts keys delete "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' ~/.config/dev-infra/gcp-viewer-key.old.json)" --iam-account=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --quiet
rm ~/.config/dev-infra/gcp-viewer-key.old.json
gcloud iam service-accounts keys list --iam-account=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com --managed-by=user
```

最後の行で、ユーザーが作った鍵が 1 つだけになっていることを確かめます。そのあと「dev の読み取り専用 SA を用意する」の 3（PowerShell で鍵を渡し、admin を止める）と 4（dev で `activate-service-account`）をやり直します。hc-remote の鍵は [hc-remote-gcp.md](hc-remote-gcp.md) の「鍵の作り直し・無効化」です。

### すぐ止める（漏れたと思われるとき、admin）

```bash
gcloud iam service-accounts keys disable "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["private_key_id"])' ~/.config/dev-infra/gcp-viewer-key.json)" --iam-account=dev-infra-viewer@first-impression-490413.iam.gserviceaccount.com
```

`gcloud iam service-accounts keys enable` で戻せます。戻さないなら、上の「作り直す」を行います。

### 読み取り専用 SA を全部消す（admin）

```bash
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

- 候補のロールの中身: 上の「読み取り専用 SA のロール」のとおり公式ドキュメントで確かめた。`roles/iam.securityReviewer`・`roles/artifactregistry.reader`・`roles/compute.viewer` は外し、カスタムロール `devInfraViewer` に置き換えた。
- 読み取り専用 SA で読めるものに秘密が混ざっていないこと: dev には資格情報がなく実状態を読めないので、上の「`--apply` の前に admin で確かめること」に入れた。
- 課金アカウントの読み取り: 読み取り専用 SA は project の権限だけなので、dev での `setup-hc-remote-gcp.sh` の dry-run の budget の節は「確かめられない」になり、止まらない（`tests/test_setup_hc_remote_gcp.sh` で確かめている）。
- admin での dry-run の表示をユーザーが確かめてから `--apply` する手順: 上の「dev の読み取り専用 SA を用意する」の 1〜2 に書いた。
