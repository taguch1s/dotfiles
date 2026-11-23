# hc-remote: 重い処理を Modal に回す

ワーカー（Claude Code のセッション）は手元に置いたまま、テスト一式・ビルド・実験などの重い処理だけを Modal で動かす（Issue #55）。料金は 1 ジョブの上限と、月の無料枠（Starter プランは月 $30 のクレジット）の範囲に収める。

- 本体: `.local/bin/hc-remote`（`~/.local/bin/hc-remote` にリンク）
- 上限と無料枠: `.config/hc-remote/config.toml`（`~/.config/hc-remote/config.toml` にリンク）
- 記録: `~/.local/share/hc-remote/`（Git 管理外）
- テスト: `tests/test_hc_remote.py`（`make check` から実行。Modal SDK は偽物に差し替える）

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
hc-remote cancel <id>     # ジョブを止める（記録にあるものだけ）
```

- `--backend auto|modal|local`（既定は設定の `defaults.backend` = `auto`）。`auto` は課金のある backend を `AUTO_ORDER` の順に試す（今は `modal` だけ。GCP の VM は #56 で後ろに足す）。`local` は同じ手順を手元の一時ディレクトリで行う試行・テスト用で、`auto` には入らない。
- コマンドを 1 語で書くとそのまま `bash -lc` に渡し、複数語で書くと `shlex.join` で 1 つにする。
- 終了コード: コマンドの終了コード。上限・無料枠・秘密情報で起動しなかったときは `3`（「ユーザー確認が必要」と理由を出す）、使い方の誤りは `2`、backend の失敗でコマンドの終了コードが無いときは `125`、待つのを Ctrl-C でやめたときは `130`（ジョブは動き続ける）。
- Modal SDK は `uv run --script` の inline 依存（`modal==1.6.4`、Python 3.12）で用意する。dotfiles に venv は持たない。初回だけ PyPI から入れる。

## 送るもの・送らないもの

- 送るのは `git ls-files -co --exclude-standard` の結果（追跡ファイルと、無視されていない未追跡ファイル）だけ。消した追跡ファイル、`.git`、submodule の中身は送らない。遠隔では `git` の履歴を使えない。
- シンボリックリンクはリンクのまま送る（リンク先は読まない）。
- 秘密情報らしいファイルが 1 つでもあれば、何も送らずに止まる（終了コード 3）。名前（basename）で `.env*`・`*.pem`・`*.key`・`*.p12`・`*.pfx`・`*.keystore`・`*.jks`・`id_rsa*`・`id_dsa*`・`id_ecdsa*`・`id_ed25519*`・`.modal.toml`・`credentials*`・`.git-credentials`・`.netrc`・`.pypirc`・`.npmrc`・`auth.json`・`service-account*.json` を、2 MB 以下のファイルは中身で秘密鍵・GitHub トークン・`sk-…`・AWS のアクセスキーの形式を見る。`.gitignore` に足すか worktree の外へ移してから実行する。
- 資格情報（Claude・GitHub・Modal のトークンなど）はクラウドへ送らない。Modal のトークンは dev の `~/.modal.toml` にあり、手元の SDK が API の認証に使うだけで、ジョブには渡らない。遠隔のコマンドが外部の資格情報を要る処理は hc-remote の対象外にする。
- 送る tar.gz の大きさは `limits.max_upload_mb` まで。

## 遠隔の環境（Modal）

- Modal の **Function** を `serialized=True` で作って `spawn` し、`app.run(detach=True)` で手元が切れても動き続けるようにする（`mlbot-remote` と同じ形）。**Sandbox は使わない**: Sandbox は非プリエンプティブの料金（Function の約 3 倍）で課金される。
- image: `debian_slim`（Python 3.12）+ `git`・`build-essential`・`curl`・`ca-certificates` + `uv`（`[modal] uv` の版）。定義が変わらない限り Modal が cache する。リポジトリ固有の依存はコマンドの側で入れる（`uv run …` など）。
- bundle・ログ・結果・持ち帰るものは Volume（`[modal] volume`、既定 `hc-remote`）の `jobs/<id>/` に置く。コンテナは 10 秒ごとに Volume を commit し、手元はそれを読んでログを流す。終わったら bundle と持ち帰ったものの tar を Volume から消し、ログと結果は残す。
- cpu と memory は request = limit にする（`cpu=(N, N)`、`memory=(MiB, MiB)`）。Modal は request と実際の使用量の大きい方で課金するため、limit で使用量を抑え、最大見積もりを上限にする。
- Function の時間制限は `--timeout` + 300 秒（展開と持ち帰りの分）。コマンドは `--timeout` で止め（SIGTERM、10 秒後に SIGKILL）、それまでのログと `--out` を持ち帰る。`retries=0`。

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
| `pricing.modal.*` | 下の料金 | 見積もりに使う 1 秒あたりの料金 |
| `modal.app` / `volume` / `python` / `uv` | `hc-remote` / `hc-remote` / `3.12` / `0.11.25` | Modal の app 名・Volume 名・image |

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

## 無料枠の確認

課金のある backend で起動する前に、次を確かめる。`run` の間は記録のロックを持つので、同時に起動しても枠を二重に使わない。

```
今月の使用額 + 実行中のジョブの最大見積額の合計 + このジョブの最大見積額 ≤ free_credit_usd − margin_usd
```

- 今月の使用額: UTC の月初から今までの `modal.Workspace.from_context().billing.report(start=…, end=…, resolution="h")` の `cost` の合計。`resolution="d"` だと途中の区間（今日）がまるごと抜けるので時間単位にする。`mlbot-remote` など hc-remote 以外の Modal の使用分も入るので、同じ枠で数えられる。
- report を取れないとき（資格情報が無い、プランで使えないなど）は、手元の記録（`jobs.jsonl` の今月の hc-remote の modal のジョブの見積額）を使い、どちらを使ったかと取れなかった理由を出す。この見積もりには hc-remote 以外の使用分が入らない。
- 実行中のジョブは最大見積額で数える（report に一部が入っていても二重に数える側に倒す）。
- 収まらなければ Modal では起動しない。`auto` なら次の backend を試すが、今は無いので終了コード 3 で止まる。
- `hc-remote budget` で同じ値（使用額・出どころ・実行中・枠・残り・今月のジョブ）を見られる。

## 記録

- `~/.local/share/hc-remote/jobs.jsonl`: 追記だけ。起動（backend・cpu・memory・timeout・最大見積額・handle・コマンド・worktree）、取り消し、終了（状態・終了コード・時間・見積額）を 1 行ずつ書き、id ごとに重ねて読む。`HC_REMOTE_STATE_DIR` で置き場所を変えられる（設定は `HC_REMOTE_CONFIG`）。
- `~/.local/share/hc-remote/jobs/<id>/`: bundle（送るまで）、`local` backend のログと結果。
- 状態: `running`・`done`（コマンドが終わった。終了コードは別に見る）・`timeout`・`cancelled`・`error`（backend の失敗）。`ls`・`budget`・`run` は実行中のジョブの状態を backend に確かめてから数える。確かめられなければ実行中として数える。
- `ls`・`logs`・`wait`・`cancel` は、この記録にあるジョブ（この端末の hc-remote が起動したもの）だけを扱う。

## backend を足す（#56 の GCP の VM）

`Backend` を継いだクラスを作り、`BACKENDS` に登録して `AUTO_ORDER` の後ろに足す。

- `name`・`billable`・`poll_interval`
- 見積もり: `billable = True` なら `[pricing.<name>]` の `cpu_core_second_usd`・`memory_gib_second_usd` を基底の `estimate_usd` / `estimate_max_usd` が使う（料金の形が違えば上書きする）。
- `month_usage(start, end)`: その期間の実際の使用額。取れなければ `Unavailable` を投げると手元の記録からの見積もりになる。枠は `[budget.<name>]`（`free_credit_usd`・`margin_usd`）。
- `launch(job_id, spec, bundle)` → 記録に残す handle（JSON にできる dict）。遠隔では `execute_job`（展開・`bash -lc`・`--timeout`・`--out` の tar・result.json。標準ライブラリだけ）を動かす。
- `poll(record)` → `Poll(done, result, error)`、`read_log(record, offset)`、`fetch_outputs(record, dest)`、`cleanup(record)`、`cancel(record)`。
- `DEFAULTS` と `.config/hc-remote/config.toml` に `[pricing.<name>]`・`[budget.<name>]`・backend の節を足す。

## 実機で確かめる（dev、未実施）

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

## 残る制限

- billing report は反映が遅れることがあり、その分は `margin_usd` で吸収する。手元の見積もりは image の build・Volume の保存を含まない。
- `run` を Ctrl-C しても（Claude Code の Bash の時間制限で止められても）遠隔のジョブは止まらない（`hc-remote cancel <id>`）。持ち帰りは `hc-remote wait <id>` で行う。起動の途中（launch から記録までの間）で止められると、記録に無いジョブが残りうる。
- Modal のログは poll のたびに Volume からまるごと読む。ログがとても大きいジョブは、コマンドの側でファイルに書いて `--out` で持ち帰る。
- GPU は扱わない（`Spec` と `launch` に足せる形にだけしてある）。
