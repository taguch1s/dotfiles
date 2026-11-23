# hc-remote: 重い処理を Modal・GCP の Spot VM に回す

ワーカー（Claude Code のセッション）は手元に置いたまま、テスト一式・ビルド・実験などの重い処理だけを遠隔で動かす。まず Modal（Issue #55）で、月の無料枠（Starter プランは月 $30 のクレジット）を使い切ったら GCP の Spot VM（Issue #56、月 1000 円まで）で、どちらにも収まらなければ手元で動かす。料金は 1 ジョブの上限と、backend ごとの月の枠の範囲に収める。

- 本体: `.local/bin/hc-remote`（`~/.local/bin/hc-remote` にリンク）
- 上限と枠: `.config/hc-remote/config.toml`（`~/.config/hc-remote/config.toml` にリンク）
- 記録: `~/.local/share/hc-remote/`（Git 管理外）
- テスト: `tests/test_hc_remote.py`（`make check` から実行。Modal SDK と gcloud は偽物に差し替える）
- GCP の service account・権限・quota: [hc-remote-gcp.md](hc-remote-gcp.md)（Issue #57）

## 使い方

```bash
# カレントの git worktree を送り、遠隔の /work で bash -lc '<コマンド>' を実行する。
# ログを流し、コマンドの終了コードで終わり、--out の path を worktree の同じ場所へ持ち帰る。
hc-remote run --cpu 4 --memory 8 --timeout 1h --out reports -- 'uv run pytest -q --junitxml reports/junit.xml'

hc-remote budget          # 今月の使用額・その出どころ・残り・今月の記録にあるジョブ
hc-remote budget --json
hc-remote ls              # hc-remote が起動したジョブ（記録にあるものだけ）
hc-remote logs <id>       # ジョブのログ
hc-remote wait <id>       # run を Ctrl-C した後などに、続きを待ってログと --out を持ち帰る
hc-remote cancel <id>     # ジョブを止める（記録にあるものだけ。GCP は VM を消す）
hc-remote gc [--dry-run]  # 残った GCP の VM（ラベル hc-remote=1）のうち、記録で終わったもの・期限切れを消す
```

- `--backend auto|modal|gcp|local`（既定は設定の `defaults.backend` = `auto`）。
- コマンドを 1 語で書くとそのまま `bash -lc` に渡し、複数語で書くと `shlex.join` で 1 つにする。
- 終了コード: コマンドの終了コード。上限・枠・秘密情報で起動しなかったときは `3`（「ユーザー確認が必要」と理由を出す）、使い方の誤りは `2`、backend の失敗でコマンドの終了コードが無いとき（指定した backend で起動できなかったときを含む）は `125`、run を Ctrl-C・SIGTERM で止めたときは `130`（Modal・local のジョブは動き続け、GCP のジョブは VM ごと止める）。

### `--backend auto` の順（2026-11-23 のユーザーの決定）

1. `modal`: 無料枠（`free_credit_usd − margin_usd`）に収まれば。
2. `gcp`: 月の予算（1000 円）に収まり、VM を作れれば。
3. `local`: どの remote にも収まらない・使えないときは、止めずに手元で実行する。理由（`modal: 無料枠を超える …; gcp: 予算を超える …` など）を表示し、記録の `fallback_reason` に残す。

- 1 ジョブの上限（CPU・メモリ・時間・送る量・同時に動かす数）を超える依頼と、秘密情報らしいファイルでの拒否は、`auto` でも今までどおり起動せずに止まる（終了コード 3）。
- `--backend modal` / `--backend gcp` と指定したときは、枠を超えれば止まる（終了コード 3）。手元には回さない。
- 起動の途中で失敗したとき（GCP の VM を作れない・SSH で入れない）は、`auto` なら次へ進み、指定したときは終了コード 125 で止まる。
- `local` は同じ手順を手元の一時ディレクトリ（`~/.local/share/hc-remote/jobs/<id>/work`）で行う。`--cpu`・`--memory` は効かず、`--timeout` だけが効く。
- Modal SDK は `uv run --script` の inline 依存（`modal==1.6.4`、Python 3.12）で用意する。dotfiles に venv は持たない。初回だけ PyPI から入れる。

## 送るもの・送らないもの

- 送るのは `git ls-files -co --exclude-standard` の結果（追跡ファイルと、無視されていない未追跡ファイル）だけ。消した追跡ファイル、`.git`、submodule の中身は送らない。遠隔では `git` の履歴を使えない。
- シンボリックリンクはリンクのまま送る（リンク先は読まない）。
- 秘密情報らしいファイルが 1 つでもあれば、何も送らずに止まる（終了コード 3）。名前（basename）で `.env*`・`*.pem`・`*.key`・`*.p12`・`*.pfx`・`*.keystore`・`*.jks`・`id_rsa*`・`id_dsa*`・`id_ecdsa*`・`id_ed25519*`・`.modal.toml`・`credentials*`・`.git-credentials`・`.netrc`・`.pypirc`・`.npmrc`・`auth.json`・`service-account*.json` を、2 MB 以下のファイルは中身で秘密鍵・GitHub トークン・`sk-…`・AWS のアクセスキーの形式を見る。`.gitignore` に足すか worktree の外へ移してから実行する。
- 資格情報（Claude・GitHub・Modal・GCP のトークンなど）はクラウドへ送らない。Modal のトークンは dev の `~/.modal.toml`、GCP の鍵は `~/.config/hc-remote/` にあり、手元の SDK・gcloud が API の認証に使うだけで、ジョブには渡らない。GCP の VM には service account を付けない（`--no-service-account --no-scopes`）。遠隔のコマンドが外部の資格情報を要る処理は hc-remote の対象外にする。
- 送る tar.gz の大きさは `limits.max_upload_mb` まで。

## 遠隔の環境（Modal）

- Modal の **Function** を `serialized=True` で作って `spawn` し、`app.run(detach=True)` で手元が切れても動き続けるようにする（`mlbot-remote` と同じ形）。**Sandbox は使わない**: Sandbox は非プリエンプティブの料金（Function の約 3 倍）で課金される。
- image: `debian_slim`（Python 3.12）+ `git`・`build-essential`・`curl`・`ca-certificates` + `uv`（`[modal] uv` の版）。定義が変わらない限り Modal が cache する。リポジトリ固有の依存はコマンドの側で入れる（`uv run …` など）。
- bundle・ログ・結果・持ち帰るものは Volume（`[modal] volume`、既定 `hc-remote`）の `jobs/<id>/` に置く。コンテナは 10 秒ごとに Volume を commit し、手元はそれを読んでログを流す。終わったら bundle と持ち帰ったものの tar を Volume から消し、ログと結果は残す。
- cpu と memory は request = limit にする（`cpu=(N, N)`、`memory=(MiB, MiB)`）。Modal は request と実際の使用量の大きい方で課金するため、limit で使用量を抑え、最大見積もりを上限にする。
- Function の時間制限は `--timeout` + 300 秒（展開と持ち帰りの分）。コマンドは `--timeout` で止め（SIGTERM、10 秒後に SIGKILL）、それまでのログと `--out` を持ち帰る。`retries=0`。

## 遠隔の環境（GCP の Spot VM）

ジョブごとに VM を 1 台作り、終わったら消す。gcloud は `CLOUDSDK_CONFIG=[gcp] cloudsdk_config`（`~/.config/hc-remote/gcloud`、service account `hc-remote-runner`）で呼ぶ。ユーザー本人の `~/.config/gcloud` は使わない。

1. 一時の SSH 鍵（ed25519）を `jobs/<id>/ssh/` に作る。
2. `gcloud compute instances create hc-remote-<id>` を次の形で呼ぶ（[hc-remote-gcp.md](hc-remote-gcp.md) の「gcp backend との約束」）。
   - `--provisioning-model=SPOT --instance-termination-action=DELETE --max-run-duration=<timeout + 300 秒 + setup_timeout>s`: 手元が落ちても、Spot で回収されても、VM は自分で消える。
   - `--no-service-account --no-scopes`、network tag `hc-remote`、ラベル `hc-remote=1,hc-remote-job=<id>,hc-remote-deadline=<消える時刻の epoch 秒>`。
   - metadata: `block-project-ssh-keys=TRUE`、`ssh-keys=hcremote:<一時の公開鍵>`、起動スクリプト（apt で `python3 git build-essential curl ca-certificates`、`uv`（`[gcp] uv` の版）を `/usr/local/bin` に入れる）。
   - image は `debian-12`（`debian-cloud`）、boot disk は pd-balanced の 20 GB、ゾーンは `asia-northeast1-a`。
3. `gcloud compute ssh/scp --tunnel-through-iap` で入れるまで待ち（最大 300 秒）、bundle・`spec.json`・`runner.py`（`execute_job` の source をそのまま入れたもの）・`run.sh` を `~hcremote/hc-remote/<id>/` に送る。
4. `run.sh` を `setsid nohup` で切り離して起動する。起動スクリプトの完了（`/var/lib/hc-remote/ready`）を `setup_timeout`（10 分）まで待ってから `python3 runner.py` を動かす。準備に失敗したらログに理由を書いて止まる。
5. 手元は 10 秒ごとに SSH でログの続き（`tail -c +N`）と `result.json` を読む。
6. 終わったら `--out` の tar を scp で持ち帰り、ログを `jobs/<id>/log` に写し（`hc-remote logs` は VM を消した後もこれを読む）、VM を消し、一時鍵を消す。

VM を消す場面（受け入れ条件。`tests/test_hc_remote.py` の `GcpTest` が偽の gcloud で確かめる）:

| 場面 | 消し方 |
| --- | --- |
| 成功・コマンドの失敗（終了コード ≠ 0）・`--timeout` | 持ち帰りの後に `instances delete` |
| VM の準備の失敗・ジョブが結果を残さずに終わった | 同上（状態は `error`） |
| 起動の途中の失敗（SSH で入れない・送れない）・その途中の Ctrl-C | その場で `instances delete` してから失敗を返す |
| `run` を Ctrl-C・SIGTERM で止めた、見ている途中の例外 | `instances delete` して記録を `cancelled`／`error` で閉じる |
| `hc-remote cancel <id>` | `instances delete`（次の `wait` で `cancelled` を記録する） |
| 手元が落ちた（SIGKILL・電源断） | `--max-run-duration` で VM が自分で消える。`hc-remote gc` でも消せる |

- `--cpu` は Modal と同じく物理コア数で、E2 の vCPU（ハイパースレッド）は 2 倍にする（最小 2 vCPU、偶数）。上限いっぱい（8 コア）で 16 vCPU になり、#57 の quota（hc-remote の分 16 vCPU）に収まる。
- マシンタイプは E2（quota の都合で他の機種は 0）。`e2-highcpu`・`e2-standard`・`e2-highmem` と `e2-custom-<vCPU>-<MB>`（1 vCPU あたり 0.5〜8 GB、256 MB 単位、5% 割高）のうち、要求を満たす最も安いものを選ぶ。例: 既定（2 コア・4 GB）は `e2-highcpu-4`、8 コア・32 GB は `e2-custom-16-32768`。
- VM の SSH 鍵はジョブごとに作り、VM の metadata にだけ入れる（project の metadata には書けない権限）。
- Spot で回収されたときは、VM が消えて結果が無いので `error`（「VM が無い」）になる。再実行は手で行う。

## 上限（`~/.config/hc-remote/config.toml`）

| キー | 既定 | 意味 |
| --- | --- | --- |
| `limits.max_cpu` | 8 | 1 ジョブの物理コア数 |
| `limits.max_memory_gb` | 32 | 1 ジョブのメモリ（GiB） |
| `limits.max_timeout` | `"2h"` | 1 ジョブの時間 |
| `limits.max_concurrent_jobs` | 2 | 同時に動かすジョブ数（hc-remote が起動したもの。`local` も数える） |
| `limits.max_upload_mb` | 200 | 送る tar.gz の大きさ |
| `defaults.backend` / `cpu` / `memory_gb` / `timeout` | `auto` / 2 / 4 / `"30m"` | `run` で指定しなかったときの値 |
| `budget.modal.free_credit_usd` | 30 | 月の無料クレジット |
| `budget.modal.margin_usd` | 3 | billing report の反映の遅れの分の余裕 |
| `budget.gcp.monthly_budget_jpy` | 1000 | GCP の月の予算（円。2026-11-23 のユーザーの決定） |
| `budget.gcp.usd_jpy` | 170 | 記録（USD）と予算（円）の換算。円安側に置くほど枠が小さくなる |
| `pricing.modal.*` | 下の料金 | 見積もりに使う 1 秒あたりの料金 |
| `pricing.gcp.*` | 下の料金 | E2 の Spot の 1 時間あたりの料金と、disk・外部 IP の分 |
| `modal.app` / `volume` / `python` / `uv` | `hc-remote` / `hc-remote` / `3.12` / `0.11.25` | Modal の app 名・Volume 名・image |
| `gcp.project` / `zone` | `first-impression-490413` / `asia-northeast1-a` | service account の IAM 条件と同じにする |
| `gcp.cloudsdk_config` / `gcloud` | `~/.config/hc-remote/gcloud` / `gcloud` | gcloud の設定ディレクトリと実行ファイル |
| `gcp.image_family` / `image_project` / `boot_disk_gb` / `uv` | `debian-12` / `debian-cloud` / 20 / `0.11.25` | VM の image・disk・uv の版 |
| `gcp.setup_timeout` | `"10m"` | VM の準備（apt・uv）を待つ上限。`--max-run-duration` と最大見積もりに足す |

設定ファイルが無いときはスクリプトの既定値（上の表と同じ）を使う。知らないキーはエラーにする。上限を超えるジョブは起動せず、「ユーザー確認が必要」と理由を出して終了コード 3 で終わる。上限を上げるかはユーザーが決める（ワーカーは監督役に相談し、監督役はユーザーに回す。`.config/herdr-core/claude/` のプロンプト）。

## 料金の見積もり

https://modal.com/pricing を 2026-11-23 に確かめた値（Function、物理コア 1 つ = 2 vCPU 相当）:

| 項目 | Function | Sandbox（参考、使わない） |
| --- | --- | --- |
| CPU | $0.0000131 / コア / 秒 | $0.00003942 / コア / 秒 |
| メモリ | $0.00000222 / GiB / 秒 | $0.00000667 / GiB / 秒 |

- Starter プランの無料クレジットは月 $30。最小は 0.125 コア・128 MiB。リージョンの指定は 1.15〜1.75 倍、非プリエンプティブは 3 倍（hc-remote はどちらも指定しない）。
- 1 ジョブの最大見積額 = `(timeout + 300 秒) × (cpu × CPU 単価 + memory × メモリ単価)`。例: 既定（2 コア・4 GiB・30 分）は約 $0.07、上限いっぱい（8 コア・32 GiB・2 時間）は約 $1.32。
- 終わったジョブの見積額 = `(コンテナで測った時間 + 30 秒) × 同じ単価`。image の build、Volume の保存などは入らない（余裕で吸収する）。
- 料金が変わったら `pricing.modal` と `DEFAULTS`（スクリプト）、この表を一緒に直す（テストが設定ファイルと `DEFAULTS` の一致を確かめる）。

### GCP（E2 の Spot、asia-northeast1）

公式の価格ページ [Spot VMs pricing](https://cloud.google.com/spot-vms/pricing) を 2026-11-23 に確かめた。ページの表は既定で us-central1 だけを表示し、東京（asia-northeast1）の値はページの HTML に入っていない（地域を選ぶと読み込む形）ため、**東京の値は確かめられなかった**。円の価格（JPY の課金アカウントで実際に使う [Cloud Platform SKUs](https://cloud.google.com/skus)）もログインが要る画面で確かめられなかった。

| 項目 | us-central1 の Spot（公式、USD） | `pricing.gcp`（見積もりに使う値） |
| --- | --- | --- |
| vCPU | $0.01309 / 時（e2-standard-2 $0.040212・e2-highmem-2 $0.054244 から逆算） | $0.02 / 時 |
| メモリ | $0.001754 / GiB / 時 | $0.0027 / GiB / 時 |
| boot disk（pd-balanced 20 GB）・外部 IP | 確かめていない | `fixed_hour_usd` $0.01 / 時 |

- 東京は E2 の通常の料金で us-central1 の約 1.3 倍（目安、未確認）で、Spot の料金は日々変わる（最大で 1 日 1 回）。その分を見込んで us-central1 の約 1.5 倍に切り上げた。custom の 5% の割増しは別に掛ける。
- 1 ジョブの最大見積額 = `(timeout + 300 秒 + setup_timeout + 120 秒) × マシンの時間単価`。VM は `--max-run-duration` で消えるので、これが 1 ジョブの上限になる。例: 既定（2 コア・4 GB・30 分 → `e2-highcpu-4`、$0.1008/時）は約 $0.08（約 13 円）、上限いっぱい（8 コア・32 GB・2 時間 → `e2-custom-16-32768`）は約 $1.0（約 170 円）。
- 終わったジョブの見積額 = `(VM を作り始めてから消すまでの時間 + 60 秒) × 時間単価`（最低 1 分）。持ち帰りの前に `ls`・`budget` が終わりに気づいたときは、VM が残っているので最大で数えておく。
- 料金が分かったら（dev の実機確認の後、課金アカウントの請求で hc-remote のラベルの額を見る）、`pricing.gcp` を直す。

## 枠の確認

課金のある backend で起動する前に、次を確かめる。`run` の間は記録のロックを持つので、同時に起動しても枠を二重に使わない。

```
今月の使用額 + 実行中のジョブの最大見積額の合計 + このジョブの最大見積額 ≤ 枠
  modal: 枠 = free_credit_usd − margin_usd（$27）
  gcp:   枠 = monthly_budget_jpy ÷ usd_jpy（1000 円 ÷ 170 = $5.88）
```

- 今月の使用額: UTC の月初から今までの `modal.Workspace.from_context().billing.report(start=…, end=…, resolution="h")` の `cost` の合計。`resolution="d"` だと途中の区間（今日）がまるごと抜けるので時間単位にする。`mlbot-remote` など hc-remote 以外の Modal の使用分も入るので、同じ枠で数えられる。
- report を取れないとき（資格情報が無い、プランで使えないなど）は、手元の記録（`jobs.jsonl` の今月の hc-remote の modal のジョブの見積額）を使い、どちらを使ったかと取れなかった理由を出す。この見積もりには hc-remote 以外の使用分が入らない。
- 実行中のジョブは最大見積額で数える（report に一部が入っていても二重に数える側に倒す）。
- 収まらなければ Modal では起動しない。`auto` なら次の backend（gcp）を試す。
- GCP は請求額を API で取らない（#56 の Non-goal）。今月の使用額は手元の記録（`jobs.jsonl` の今月の gcp のジョブの見積額。起動に失敗するまでに VM が動いた分も `launch_failed` として入る）。円の予算を USD の見積もりと比べるため、`usd_jpy` で換算する。表示には円も添える。
- 予算を超えるなら GCP では起動しない。`auto` なら手元で実行する。
- GCP 側の budget のアラート（ラベル `hc-remote=1`、1000 円、50%・90%・100% でメール。#57 で作成済み）は課金を止めない。止めるのはこの起動前の確認。
- `hc-remote budget` で同じ値（使用額・出どころ・実行中・枠・残り・今月のジョブ）を見られる。`--json` は backend ごとの配列。

## 記録

- `~/.local/share/hc-remote/jobs.jsonl`: 追記だけ。起動（backend・cpu・memory・timeout・最大見積額・handle・コマンド・worktree）、取り消し、終了（状態・終了コード・時間・見積額）を 1 行ずつ書き、id ごとに重ねて読む。`HC_REMOTE_STATE_DIR` で置き場所を変えられる（設定は `HC_REMOTE_CONFIG`）。
- `~/.local/share/hc-remote/jobs/<id>/`: bundle（送るまで）、`local` backend のログと結果。
- `auto` で手元に回したジョブは `backend: local` と `fallback_reason`（remote に回せなかった理由）を持つ。
- 状態: `running`・`done`（コマンドが終わった。終了コードは別に見る）・`timeout`・`cancelled`・`error`（backend の失敗）。`ls`・`budget`・`run` は実行中のジョブの状態を backend に確かめてから数える。確かめられなければ実行中として数える。
- `ls`・`logs`・`wait`・`cancel` は、この記録にあるジョブ（この端末の hc-remote が起動したもの）だけを扱う。

## GCP の VM が残ったとき・予算を変えるとき

```bash
hc-remote gc --dry-run      # 消すものを表示するだけ
hc-remote gc                # ラベル hc-remote=1 の VM のうち、記録で終わったもの・期限を過ぎたものを消す
CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud gcloud compute instances list --filter=labels.hc-remote=1   # 残っているかを直接見る
```

- `gc` は `gcloud compute instances list --filter=labels.hc-remote=1` で一覧を取り、さらにラベル `hc-remote=1` と名前 `hc-remote-` の両方を満たすものだけを扱う。ラベルの無い VM（`ts-crawler-*` など）は一覧にも出さない。
- 消すのは、記録で終わっている（`running` でない）もの、または期限（ラベル `hc-remote-deadline`）を過ぎたもの。記録で実行中の VM を期限切れで消したときは、記録を `error`（最大見積額）で閉じる。記録に無く期限前の VM（別の端末・起動の途中）は残す。
- 予算を変えるのはユーザーが決める。`~/.config/hc-remote/config.toml`（dotfiles の `.config/hc-remote/config.toml`）の `[budget.gcp] monthly_budget_jpy` を変え、スクリプトの `DEFAULTS` も同じ値にする（テストが一致を確かめる）。GCP 側の budget のアラートの金額も合わせる。`wsl/admin/setup-hc-remote-gcp.sh` は既にある budget を作り直さないので、Cloud Console の「お支払い」→「予算とアラート」で `hc-remote` の金額を直す。

## backend を足す

`Backend` を継いだクラスを作り、`BACKENDS` に登録して（課金のあるものは）`AUTO_ORDER` に足す。

- `name`・`billable`・`detached`（run を止めても遠隔が動き続けるか。False なら止めたときに `cancel` する）・`poll_interval`
- 見積もり: `billable = True` なら `[pricing.<name>]` の `cpu_core_second_usd`・`memory_gib_second_usd` を基底の `estimate_usd` / `estimate_max_usd` が使う（料金の形が違えば上書きする）。
- `month_usage(start, end)`: その期間の実際の使用額。取れなければ `Unavailable` を投げると手元の記録からの見積もりになる。枠は `budget_limit()`（既定は `[budget.<name>]` の `free_credit_usd − margin_usd`。GCP は円の予算 ÷ 換算）。
- `billed_seconds(record, result, now, final)`: 終わったジョブの課金の秒数（GCP は VM の生存時間）。
- `launch(job_id, spec, bundle)` → 記録に残す handle（JSON にできる dict）。起動できなければ `Unavailable`（`auto` は次へ進む。課金が出ていれば `spent_usd` に入れると記録に残る）。遠隔では `execute_job`（展開・`bash -lc`・`--timeout`・`--out` の tar・result.json。標準ライブラリだけ）を動かす。
- `poll(record)` → `Poll(done, result, error)`、`read_log(record, offset)`、`fetch_outputs(record, dest)`、`cleanup(record)`、`cancel(record)`。
- `DEFAULTS` と `.config/hc-remote/config.toml` に `[pricing.<name>]`・`[budget.<name>]`・backend の節を足す。

## 実機で確かめる（dev、未実施）

### Modal

Modal の資格情報は dev の `~/.modal.toml` にだけあるので、dev で行う。最小のジョブ 1 件で数セント未満。

```bash
# 1. 枠の確認。出どころが「Modal の billing report」になるか（Starter プランで report を使えるか）を確かめる
hc-remote budget

# 2. 最小のジョブ。初回は image の build が入る
hc-remote run --cpu 0.25 --memory 0.5 --timeout 5m --out out -- 'mkdir -p out && uname -a | tee out/uname.txt && nproc && free -m'
#    → ログが流れる、終了コード 0、worktree に out/uname.txt が戻る、ls で est$ が入る

# 3. 秘密ファイルで止まる（untracked で無視されていない .env を置いて試し、消す）
# 4. 取り消し: 長いジョブを起動し、別の端末で hc-remote cancel <id>、元の端末の run が cancelled で終わる
#    Modal の dashboard（Apps → hc-remote）でコンテナが止まったことを見る
# 5. 翌日以降に hc-remote budget の使用額が dashboard の Usage と合うかを見る
```

確かめること: 送る対象に資格情報が無いこと（送る対象は worktree で `git ls-files -co --exclude-standard` を実行すると見られる）、`enable_output` の表示がワーカーの出力に多すぎないこと、10 秒ごとの Volume の commit でログが流れること。

### GCP（Spot VM）

前提: [hc-remote-gcp.md](hc-remote-gcp.md) の「dev で使う」の 1〜4（鍵・`CLOUDSDK_CONFIG`・疎通）が済んでいること。admin では行わない（admin の gcloud はユーザー本人の資格情報なので）。最小の VM（`e2-custom-2-1024`、約 $0.05/時）を数分動かすだけで、1 円未満〜数円。

```bash
export CLOUDSDK_CONFIG=~/.config/hc-remote/gcloud
# 1. 残っている VM が無いこと（ts-crawler-* は出ない）
gcloud compute instances list --filter=labels.hc-remote=1
hc-remote budget                         # gcp の使用額 $0.00・枠 $5.88（月の予算 1000 円 ÷ 170 円/$）

# 2. 最小のジョブ（echo 1 件）。VM の作成 → SSH が通る → 準備（apt・uv、数分）→ 実行 → 持ち帰り → 削除まで見る
hc-remote run --backend gcp --cpu 0.25 --memory 0.5 --timeout 5m --out out -- 'mkdir -p out && echo hello | tee out/hello.txt && uname -a && nproc && free -m && uv --version'
#    → 終了コード 0、worktree に out/hello.txt が戻る、最後に VM が消える

# 3. VM が消えたこと、記録と見積もり
gcloud compute instances list --filter=labels.hc-remote=1   # 空
hc-remote ls; hc-remote budget; hc-remote logs <id>

# 4. 中断で消える: 長いジョブを起動して VM ができたら Ctrl-C → 「後始末」と出て、上の list が空になる
hc-remote run --backend gcp --cpu 0.25 --memory 0.5 --timeout 10m -- 'sleep 300'

# 5. 翌日以降、Cloud Console の「お支払い」→「レポート」でラベル hc-remote=1 の額を見て、hc-remote budget の見積もりと比べる
```

確かめること（偽の gcloud では確かめられない点）:

- service account で作成が通ること（名前の IAM 条件が作成時に効くか。[hc-remote-gcp.md](hc-remote-gcp.md) の「公式ドキュメントで確かめられなかった点」）。通らなければ同じ文書の手順で条件を見直す。
- `--max-run-duration` を Spot と一緒に付けられること、VM の「詳細」で終了時の操作が「削除」になっていること。
- `gcloud compute ssh --tunnel-through-iap --ssh-key-file` が、VM の metadata にある一時鍵で入れること（VM の metadata や project の metadata に鍵を足しに行かないこと。足しに行くと権限の無い操作で失敗する）。
- Debian 12 の起動スクリプトで uv が `/usr/local/bin` に入り、`bash -lc` から使えること。準備にかかる時間（`setup_timeout` 10 分に収まるか）。
- Debian 12 の `python3`（3.11）で `runner.py` が動くこと（`tarfile` の `filter` が無ければ無しで展開する）。
- 料金: 実際の請求（東京の Spot の単価）と `pricing.gcp` の比べ。

## 残る制限

- billing report は反映が遅れることがあり、その分は `margin_usd` で吸収する。手元の見積もりは image の build・Volume の保存を含まない。
- `run` を Ctrl-C しても（Claude Code の Bash の時間制限で止められても）遠隔のジョブは止まらない（`hc-remote cancel <id>`）。持ち帰りは `hc-remote wait <id>` で行う。起動の途中（launch から記録までの間）で止められると、記録に無いジョブが残りうる。
- Modal のログは poll のたびに Volume からまるごと読む。ログがとても大きいジョブは、コマンドの側でファイルに書いて `--out` で持ち帰る。
- GPU は扱わない（`Spec` と `launch` に足せる形にだけしてある）。
- GCP: 使用額は記録上の見積もりで、請求額ではない。料金表の東京の値は確かめていない（上の「GCP」）。budget のアラートが後ろ盾になる。
- GCP: `run` を止めると VM ごと止まる（Modal と違い、`hc-remote wait` で続きを待てない）。長いジョブは Bash の `run_in_background` で実行する。
- GCP: 手元が SIGKILL・電源断で落ちると、VM は `--max-run-duration` まで残る。VM を作ってから記録を書くまでの間に落ちると、その VM の分は記録上の使用額に入らない（最大で 1 ジョブの最大見積額）。
- GCP: Spot は回収されることがある。回収されたジョブは `error` で終わり、再実行は手で行う。
- GCP: ログは 10 秒ごとに SSH（IAP）で読むので、1 回に数秒かかる。
