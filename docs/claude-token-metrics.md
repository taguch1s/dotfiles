# Claude トークン効率指標（claude-token-metrics）

Claude Code のトランスクリプト（`~/.claude/projects/**/<session>.jsonl` と `<session>/subagents/*.jsonl`）から、セッションごとのトークン効率指標（L0〜L2）を集計する。親 Issue は #17、実装は #18。

```bash
claude-token-metrics session ~/.claude/projects/-home-issei/<session>.jsonl   # 1 行の JSON
claude-token-metrics report --since 2026-11-14          # 記録済みセッションの表
claude-token-metrics report --json                      # 同じ内容を JSON の配列で
claude-token-metrics waste <transcript.jsonl>           # 無駄の検出結果をルール別の表で（下の「無駄の検出」）
claude-token-metrics report --by task --since 2026-11-22 # タスク（Issue）ごとの表（下の「タスク単位の集計」）
claude-token-metrics rescan --since 2026-11-14          # transcript を集計し直して記録に追記する
```

## SessionEnd hook の導入

リポジトリ版 `.claude/settings.json` の `SessionEnd` に `claude-token-metrics record` を登録してある。`make link` で `~/.local/bin/claude-token-metrics` を配置したうえで、`make sync` を実行すると `~/.claude/settings.json` に反映される（#28）。

`~/.claude/settings.json` は `dotfiles.toml` で `mode = "merge-json-managed"` として管理している。`make sync` は `hook_commands` に宣言した hook と `keys`（`statusLine`）だけをリポジトリ版に合わせ、Herdr の `SessionStart` hook や Claude Code が書き足す `autoMode`・`env` などの管理外の hook・キーはそのまま残す。変更前のファイルは `~/.claude/settings.json.dotfiles-backup-<時刻>` に残る。反映前の確認は `make diff`、反映漏れの検出は `make doctor`（欠けていれば NG）。

`record` は stdin の `transcript_path` / `session_id` を受け取ると、集計を切り離した子プロセスに任せてすぐ終了する（大きなセッションでは集計に数十秒かかるため）。結果は `${XDG_DATA_HOME:-~/.local/share}/claude-token-metrics/sessions.jsonl` に 1 行ずつ追記され、失敗は同じディレクトリの `record.log` に残る。同じ `session_id` を再記録した場合、`report` は後の行を採用する。

確認方法：短いセッションを開いて閉じ、`sessions.jsonl` が 1 行増えることを見る。

## 重み

重み付きコストは input トークン換算の値で、既定の重みは input 1、cache 作成 5m 1.25 / 1h 2、cache 読み込み 0.1、output 5。既定値 < 設定ファイル < `--weights input=1,output=5` の順に上書きする。

設定ファイル `${XDG_CONFIG_HOME:-~/.config}/claude-token-metrics/weights.json` は次の形で、一部のキーだけでもよい。`weights` 以外のキーは読み飛ばすので、推定の根拠などを併記できる。

```json
{"weights": {"input": 1, "cache_creation_5m": 1.25, "cache_creation_1h": 2, "cache_read": 0.1, "output": 5}}
```

## 出力（schema `claude-token-metrics/v1`）

- 先頭：`session_id`、`transcript_path`、`version`（Claude Code）、`versions`、`started_at` / `ended_at`、`weights`、`weights_source`、`skipped`（`broken_lines`、`no_usage`、`synthetic`）。`record` はさらに `recorded_at`、`reason`、`cwd`、`git`、`hc`、`ctx_budget` を足す（下の「タスク単位の集計」）。
- scope：`main`（本体）、`sidechain`（本体ファイル内の `isSidechain` 行）、`subagents`（`files` つき）。それぞれ次を持つ。
  - `L0`：`tokens`（`input`、`cache_creation_5m`、`cache_creation_1h`、`cache_creation`、`cache_read`、`output`、`thinking`）と `weighted_cost`
  - `L1`：`requests`、`context`（`mean`、`max`、`last`、`deciles`）、`rent_rate`（家賃率 = cache 読み込みの重み付きコスト ÷ 総コスト）、`reread_ratio`（再読倍率 = cache 読み込み ÷ (input + cache 作成)）、`drops`（文脈が半分未満かつ 1000 トークン以上減った位置）、`compact_boundaries`
  - `L2`：`window_bytes`、`min_bytes`、`low_threshold`、`tool_results`、`raw_bytes`、`novel_bytes`、`new_info_rate`、`by_tool`、`low_new_info`（新情報率 5% 未満の呼び出しを `Bash:<先頭語>` またはツール名でまとめた一覧）
  - `by_model`：モデルごとの `requests`、`tokens`、`weighted_cost`
- `total`：3 つの scope を合わせた `requests`、`tokens`、`weighted_cost`、`rent_rate`、`reread_ratio`、`tool_results`、`raw_bytes`、`novel_bytes`、`new_info_rate`、`low_new_info`

文脈サイズは 1 リクエストの `input + cache 作成 + cache 読み込み`。assistant 行は `requestId` で重複を除き、同じリクエストは後の行の usage を使う。

新情報率は、200 バイト以上のツール結果ごとに、直前 400kB のツール結果履歴を前置したときの lzma（preset=1）圧縮長の増分を新しい情報量とみなした粗い近似である。絶対値ではなく、同じ方法・同じ窓幅で測った値どうしの比較に使う。

## statusline と使用率の記録（#20）

`claude-statusline` は Claude Code の statusline コマンドで、`Opus | dotfiles | ctx 182k | 5h 54% | 7d 8%` の 1 行を出す。

- モデル名・ディレクトリ：stdin の `model.display_name` と `workspace.current_dir`（無ければ `cwd`）の末尾。無い項目は出さない。以前の `~/.claude/statusline.py` の表示を取り込んだもので、同期後は `statusline.py` は使われない。

- `ctx`：`transcript_path` の最後のリクエスト（本体の assistant 行。合成メッセージと sidechain は除く）の `input + cache 作成 + cache 読み込み`。上の文脈サイズと同じ定義で、トランスクリプトは末尾から最大 16MB だけ読む。
- `5h` / `7d`：stdin の `rate_limits.five_hour` / `seven_day` の `used_percentage`。`rate_limits` が null や欠けている場合は `-` を出し、記録しない。

`used_percentage`（5h か 7d）が前回の記録から変わったときだけ、`${XDG_DATA_HOME:-~/.local/share}/claude-token-metrics/ratelimit.jsonl` に 1 行追記する。複数のセッションから同時に呼ばれても重ならないよう、ファイルをロックして比べる。

```json
{"ts": "2026-11-14T01:02:03.456+00:00", "session_id": "...", "five_hour": {"used_percentage": 54, "resets_at": 1763100000}, "seven_day": {"used_percentage": 8, "resets_at": 1763600000}}
```

どんな入力でも 1 行を出して exit 0 で終わる。リポジトリ版 `.claude/settings.json` の `statusLine` は、`make link` のあとに `make sync` で `~/.claude/settings.json` に反映される（値ごと置き換える）。

## 使用率から重みを推定する（calibrate）

```bash
claude-token-metrics calibrate                     # 推定結果か「データ不足」を表で出す
claude-token-metrics calibrate --since 2026-11-14 --json
claude-token-metrics calibrate --write             # 推定した重みを weights.json に書き出す
```

1. `ratelimit.jsonl` の記録を時刻順に並べ、同じ `five_hour.resets_at`（60 秒以内の差は同じとみなす）を持つ連続した 2 つの記録の間を 1 区間とする。枠の切り替わりと使用率の減少は区間にしない。
2. `~/.claude/projects`（`CLAUDE_CONFIG_DIR` か `--projects` で変更可）の全 `*.jsonl`（サブエージェント込み）のリクエストを、時刻で区間に振り分けて種類別（input、cache 作成 5m / 1h、cache 読み込み、output）に合計する。requestId はファイルをまたいで重複を除く。最初の記録より前に更新が止まったファイルは読まない。
3. Δ`used_percentage` を目的変数、種類別トークンを説明変数として、切片なしの非負最小二乗で係数を求める（説明変数が 5 個なので全部分集合を解く厳密解で、結果は決定的）。

出力（`--json`、schema `claude-token-metrics/calibrate/v1`）：

- `status`：`ok` か `insufficient_data`。区間数が `--min-intervals`（既定 30）未満なら推定せず、`weights` などは null。
- `weights`：input を 1 とした相対値（有効数字 4 桁）。データに現れない種類は null。input の係数が 0 になった場合は null。
- `percent_per_mtok`：100 万トークンあたりの使用率（%）。input を基準にしない絶対値。
- `r2`：決定係数（平均まわり。切片なしの回帰なので保守的な値）、`intervals`、`records`、`requests`、`files`、`skipped`（`window_change`、`negative_delta`、`no_tokens`、`duplicate_requests`）。
- `by_model`：`opus` / `sonnet` / `haiku` / `other` ごとに、その系統だけを使った区間で同じ推定をする。区間数が足りない系統は `insufficient_data`。

`--write` は推定できた場合だけ `${XDG_CONFIG_HOME:-~/.config}/claude-token-metrics/weights.json` の `weights` を丸ごと置き換え、推定の根拠を `calibration` に書く（`weights` 以外のキーは残す）。推定できなかった種類（データに現れない種類）は書かないので、手で設定していた同じキーは消えて既定値に戻る。推定できなければ書かずに exit 1。既定では書き出さない。

注意点：

- 同じ枠を claude.ai web や他の端末で使った分はローカルのログに出ず、推定のノイズになる（ローカルのトークンがない区間は除外するが、混ざった区間は除けない）。
- `used_percentage` が整数刻みだと、連続した 2 記録の Δ は 1 前後で丸め誤差が大きい。`--min-delta 3` などで、同じ枠の中で Δ がその値以上になるまで区間をつなげると誤差を減らせる（区間数は減る）。
- Claude Code では input トークンが cache に比べて非常に少ないため、input の係数は不安定になりやすい。`weights`（input = 1）がぶれる場合は `percent_per_mtok` の比で見る。

## 無駄の検出（waste、#46）

transcript の項目（ツール結果のバイト数と sha256、ツールの input、`is_error`、usage、行の `timestamp`）と設定の閾値だけで、無駄なトークンを決定的に数える。LLM や類似度モデルは使わない。結果は `session` と `record`（`sessions.jsonl`）の JSON の `waste` に入る。

```bash
claude-token-metrics waste <transcript.jsonl>                       # ルール別の合計と findings の表
claude-token-metrics waste --json <transcript.jsonl>                # waste をそのまま JSON で
claude-token-metrics waste --waste-config ./waste.json --weights cache_read=0.1 <transcript.jsonl>
```

`waste` サブコマンドは L2（lzma の圧縮）を計算しないので、`session` より速い。

### 共通の定義

- **ストリーム**：`main`（本体）、`sidechain`（本体内の `isSidechain` 行）、サブエージェントの 1 ファイル。ルールはストリームごとに独立に適用する（ストリームをまたいだ重複・読み直しは数えない）。
- **区切り**：`compact_boundary`、または文脈の急減（L1 の `drops` と同じ条件）。区切りより前の内容は文脈に残っていないものとして扱い、区切りをまたぐ重複・読み直しは数えない（失敗の繰り返しは区切りをまたいでも数える）。
- **ツール結果のトークン数（推定）**：ツール呼び出しを出したリクエスト R_k と同じストリームの次のリクエスト R_k+1 について、Δ = 文脈(R_k+1) − 文脈(R_k) − output(R_k)。Δ > 0 で間に区切りがなければ、Δ をその間のツール結果にバイト数の比で配分する（`token_source: "delta"`）。それ以外は `バイト数 ÷ bytes_per_token`（`"bytes"`）。Δ には同じ間に入るフック出力・`attachment` 行も含まれるので近似である。
- **重み付きコスト（滞在込み）**：トークン t が R_k+1 で文脈に入り、次の区切り（なければストリームの末尾）まで n 回のリクエストで読まれたとき `t × (w_cc + w_cr × (n − 1))`。w_cc は R_k+1 の cache 作成の多い方（5m / 1h）の重み、w_cr は cache 読み込みの重み。重みは `weights.json` / `--weights` と共有する。結果を読むリクエストが無い（ストリームの最後の結果）ときは、トークンを bytes で推定し、コストは 0 にする。
- **二重計上の禁止**：1 つのツール結果は、`repeated_failure` > `duplicate_result` > `reread_file` > `oversized_output` の順で最初に当たった 1 ルールだけで数える。`context_bloat` は、ツール結果系のルールで数えたトークンのうち、そのリクエストの文脈に残っている分を差し引いてから数える（`cache_rewrite` と `repeated_failure` の output 分は差し引かない）。

### ルール

| `rule` | 条件 | 無駄トークン | 重み付きコスト |
|---|---|---|---|
| `oversized_output` | ツール結果が `oversized_bytes` バイトを超える。`exempt_keys` の `command_key` は除く | 推定トークン × (バイト数 − 閾値) ÷ バイト数 | 滞在込み |
| `duplicate_result` | 本文の sha256 が同じストリーム・同じ区間の前のツール結果と一致。`min_bytes` 未満と `exempt_keys` は除く。状態確認の繰り返し（`hc read`、`git status` の同じ出力）も数える | 推定トークン全部 | 滞在込み |
| `reread_file` | `Read` の `file_path` が同じ区間の前の `Read` と同じで、行の範囲が重なり、本文はどの前の `Read` とも一致しない。間にその path への `Edit`・`MultiEdit`・`Write`・`NotebookEdit` も、path を含む `Bash` もない | 推定トークン × 重なった行数 ÷ 読んだ行数 | 滞在込み |
| `repeated_failure` | `is_error` のツール結果で、ツール名と input（key 順で正規化した JSON）が同じ呼び出しが同じストリームで前にも失敗しており、間に編集系ツールがない。1 回目は数えない | 推定トークン + 呼び出しを出したリクエストの output（同じリクエストは 1 回だけ） | 滞在込み + output × w_out |
| `cache_rewrite` | 連続するリクエスト R_j−1、R_j で cache 読み込み(R_j) < 文脈(R_j−1) × `cache_miss_ratio`、間に `compact_boundary` がない | min(cache 作成(R_j), 文脈(R_j−1) − cache 読み込み(R_j)) | 無駄トークン × (w_cc − w_cr) |
| `context_bloat` | 本体のリクエストの文脈が予算を超える | Σ max(0, 文脈 − 予算 − 他のルールで数えて文脈に残っている分) | 無駄トークン × w_cr |
| `over_delegation` | サブエージェント単位。`trivial` と `duplicate`（下の「委譲と作り直し」） | trivial: cold start のトークン。duplicate: そのサブエージェントの総トークン | trivial: cold start の換算。duplicate: そのサブエージェントの重み付きコスト全部 |

実装の細部：

- `reread_file` の行の範囲は、開始が `offset`（既定 1）、行数が結果の中の行番号つきの行（`N<tab>` / `N→`）の数。失敗した `Read` は記録しない。編集系ツールの結果が来ると、その path の `Read` の記録を消す。`Bash` の command にその path の文字列があっても消す（見逃し側に倒す）。
- `repeated_failure` の記録は、編集系ツールの結果で全部消す（TDD の Red や、修正のたびに test を流す反復は数えない）。
- `hints.failure_streaks`：同じ `command_key` の結果が、成功を挟まず `failure_streak` 回以上続けて `is_error` だったもの（他のツールの結果は挟んでよい）。hints 自体はトークンを数えず、`key`、`count`、最初と最後の `tool_use_id` を出す（streak の中の失敗も、`repeated_failure` の条件に当たればそちらで数える）。
- `duplicate_result` は、同じ path への連続した `Edit` の成功メッセージ（同じ本文で 200 バイトを超えることがある）も数える。避けられない出力なので、`exempt_keys` の既定に編集系ツール（`Edit`・`MultiEdit`・`Write`・`NotebookEdit`）を入れてあり、数えない（数えたいときは `exempt_keys` を上書きして外す）。
- `cache_rewrite` の `cause`：間隔（両リクエストの最初の行の `timestamp` の差）が TTL を超え、R_j の直前が人の発言なら `idle`、ツール結果なら `tool_wait`。間隔が TTL 以下か取れなければ `break`（system prompt やツール定義の変化など）。TTL は、そのストリームでそれまでに 1h cache を書いていれば 3600 秒、なければ 300 秒（`cache_ttl_seconds` で固定できる）。
- `context_bloat` の予算は、`record` のときは環境変数 `CLAUDE_CTX_GUARD_TOKENS`（hc の監督役 200000、ワーカー 180000。上限の `CLAUDE_CTX_GUARD_LIMIT_TOKENS` は使わない）、無ければ `context_budget`。`session` / `waste` は常に `context_budget` を使う。`hints.requests_after_budget` は最初に予算を超えたリクエストより後の本体のリクエスト数。

### 設定（`waste.json`）

`${XDG_CONFIG_HOME:-~/.config}/claude-token-metrics/waste.json`。既定値 < 設定ファイル < `--waste-config <path>` の順に上書きする。一部のキーだけでよく、`waste` 以外のキーは読み飛ばす。

```json
{"waste": {"oversized_bytes": 20000, "min_bytes": 200, "exempt_keys": ["Edit", "MultiEdit", "NotebookEdit", "Write"], "failure_streak": 3,
           "cache_miss_ratio": 0.5, "cache_ttl_seconds": null, "context_budget": 200000,
           "findings_limit": 50, "bytes_per_token": 2.2}}
```

| キー | 既定値 | 値の範囲 |
|---|---|---|
| `oversized_bytes` | 20000 | 0 以上の整数 |
| `min_bytes` | 200 | 0 以上の整数（`duplicate_result` の対象の下限） |
| `exempt_keys` | `["Edit", "MultiEdit", "NotebookEdit", "Write"]` | `command_key`（`Bash:<先頭語>` かツール名）の配列。`oversized_output` と `duplicate_result` で共有 |
| `failure_streak` | 3 | 2 以上の整数 |
| `cache_miss_ratio` | 0.5 | 0 より大きく 1 以下 |
| `cache_ttl_seconds` | `null` | `null`（自動）か 0 より大きい数値 |
| `context_budget` | 200000（`claude-context-guard` の既定の閾値と同じ） | 1 以上の整数 |
| `findings_limit` | 50 | 0 以上の整数 |
| `bytes_per_token` | 2.2 | 0 より大きい数値 |
| `trivial_requests` | 3 | 0 以上の整数（`over_delegation.trivial`、下の「委譲と作り直し」） |
| `trivial_tool_calls` | 2 | 0 以上の整数 |
| `exempt_agent_types` | `["web-fetch"]` | 文字列の配列（trivial に数えない型） |
| `under_delegation_bytes` | 400000 | 0 以上の整数 |
| `resume_markers` | `["【再開】"]` | 文字列の配列 |
| `resume_window` | 5 | 1 以上の整数 |
| `supervisor_handoff_paths` | `["hc-supervisor/handoff.md"]` | 文字列の配列 |
| `startup_cap` | 20 | 1 以上の整数 |
| `handoff_tail` | 10 | 1 以上の整数 |
| `handoff_write_paths` | `["codex-handoffs/", "hc-supervisor/handoff.md"]` | 文字列の配列 |
| `task_branch_pattern` | `(?:^\|/)(?:issue\|epic)-(\d+)` | グループを 1 つ以上持つ正規表現（Python `re`）。最初のグループを Issue の番号とみなす（下の「タスク単位の集計」） |

知らないキーは stderr に警告して無視する。型・範囲が不正な値や読めないファイルは、`session` / `waste` では exit 2、`record` では既定値で集計して `record.log` に理由を残す。

閾値の既定値は、Epic #45 の実データの分布（ツール結果の p99 16.7 kB、最大 27.7 kB など）を根拠にした仮の値で、タスク単位の記録が溜まってから見直す。`bytes_per_token` の 2.2 は、dotfiles の transcript 5 本で Δ が取れたツール結果 49 件の バイト ÷ トークン の中央値 2.212（十分位 1.73〜2.74）から決めた。日本語や記号の多い出力ほど小さくなる。

### 出力（schema `claude-token-metrics/waste/v1`）

- `config`（使った値の全部）、`config_hash`（キー順で正規化した JSON の sha256 の先頭 12 文字）、`config_source`（`default` / `file` / `cli`）。
- `rules`：ルールごとの `count`、`tokens`、`weighted_cost`。`context_bloat` にはさらに `budget` と `budget_source`（`env` / `config`）。
- `cache_rewrite_by_cause`：`idle` / `tool_wait` / `break` ごとの同じ集計。
- `total`：`tokens`、`weighted_cost`、`share`（無駄の重み付きコスト ÷ セッションの `total.weighted_cost`。0 なら null）。
- `findings`：`rule`、`scope`、`file`、`request_index`、`timestamp`、`tool_use_id`、`key`、`tokens`（小数 1 桁）、`token_source`（`delta` / `bytes`。ツール結果以外は null）、`weighted_cost`（小数 4 桁）、`detail`（ルールごとの補足。`Read` の path、ハッシュの先頭 12 文字、閾値、`first_tool_use_id` など。本文は入れない）。重み付きコストの降順、同じなら scope・file・`request_index`・`tool_use_id`・ルールの順で並べ、`findings_limit` 件まで出す。合計は件数を絞る前の全件で数える。
- `hints`：`failure_streaks`、`requests_after_budget`、`under_delegation`（真偽。下の「委譲と作り直し」）。
- `rules.over_delegation` はさらに `by_kind`（`trivial` / `duplicate` ごとの `count`、`tokens`、`weighted_cost`）を持つ。finding の `scope` は `subagents`、`file` はサブエージェントのファイル、`tool_use_id` は本体の `Agent` の id、`key` は `Agent:<型>`、`detail.kind` が種類。

同じ transcript と同じ設定なら、`findings` の順序まで同じ結果になる。

## 委譲と作り直し（delegation・restart、#47）

`session` と `record` の JSON に、`delegation`（サブエージェントへの委譲の量と効果）と `restart`（セッションの作り直し）が入る。どちらも transcript と設定の閾値だけで決まる。`over_delegation` は無駄検出のルール（上の表）。

### meta.json との対応づけ

サブエージェントのファイル `<session>/subagents/agent-<id>.jsonl` には `agent-<id>.meta.json` が並ぶ。`toolUseId`（本体の `Agent` の tool_use id）、`agentType`、`model` を読み、`toolUseId` で本体の `Agent`（旧名 `Task` も）と対応づける。`agentType` が無ければ `Agent` の input の `subagent_type` を使う。meta.json が無い・JSON として読めない・`toolUseId` が文字列でないファイルは `unlinked` に数え、`agents` には `tool_use_id: null` で入れる（Claude Code の版で形が変わると、まず `unlinked` が増えるので `versions` と合わせて見る）。`unlinked` のサブエージェントは型が分からないため `over_delegation` の対象にしない。

### `delegation`

- `agent_calls`：本体の `Agent` / `Task` の tool_use の数。
- `subagent_cost_share`：subagents scope の重み付きコスト ÷ セッション全体（0 なら null）。
- `subagent_tool_bytes`：サブエージェントのツール結果のバイト数の合計（本体に入らずに済んだ量の上限）。
- `agent_result_bytes`：本体に返った `Agent` のツール結果のバイト数の合計。バックグラウンド実行のサブエージェントでは、起動時の受付メッセージだけで、後から `<task-notification>` として届く本当の結果は含まない（`compression` は小さめに出る）。
- `compression`：`agent_result_bytes ÷ subagent_tool_bytes`（小さいほど、委譲で本体の文脈を守れている。分母が 0 なら null）。
- `main_tool_bytes`：本体（`Agent` の結果を除く）のツール結果のバイト数。`sidechain` は含めない。
- `unlinked`：meta.json と対応づけられなかったファイルの数。
- `agents`：サブエージェントごとに `file`、`tool_use_id`、`agent_type`、`model`、`requests`、`tool_calls`、`weighted_cost`、`tokens`（input + cache 作成 + cache 読み込み + output）、`cold_start_tokens`（最初のリクエストの input + cache 作成）、`cold_start_cost`、`result_bytes`（本体に返った結果）、`duplicate_of`（下の `duplicate` の相手の tool_use_id。なければ null）。

### `over_delegation`

- `trivial`：サブエージェントの `requests` ≤ `trivial_requests` かつ `tool_calls` ≤ `trivial_tool_calls`。無駄トークンは `cold_start_tokens`、コストは cold start の換算（input と cache 作成を重みで）。`exempt_agent_types`（ツールの代わりに使う型。既定 `web-fetch`）は数えない。
- `duplicate`：同じセッションで `prompt` の sha256 と `subagent_type` が、前の `Agent` 呼び出しと一致する。比べる相手は同じ組の直前の呼び出しで、それが `is_error` で終わっていれば、やり直しとして数えない。無駄トークンはそのサブエージェントの総トークン、コストはその重み付きコスト全部。
- 二重計上：1 つのサブエージェントは 1 件だけ数え、`duplicate` が `trivial` に優先する。`duplicate` に当たったサブエージェントの中の finding（`duplicate_result` など）と failure streak は数えない（`over_delegation.duplicate` > A のルール）。`trivial` のサブエージェントの中の finding はそのまま数える。

### `hints.under_delegation`

`main_tool_bytes` > `under_delegation_bytes` かつ `agent_calls` = 0 のとき true。委譲すべきだったかは設計の判断（#35）なので、無駄トークンには入れず、数値（`delegation.main_tool_bytes`）と一緒に見るためのヒントとして出す。

### `restart`

- `kind`：`resume_worker`（最初の人の発言のいずれかの行が `resume_markers` のどれかで始まる（hc は依頼を `<pasted_content>`・`<hc …>` で包むので、先頭の行とは限らない）。`hc-supervisor resume-worker` の `【再開】<handoff の path>`）、`resume_supervisor`（本体の最初の `resume_window` リクエストの中で、`supervisor_handoff_paths` のどれかを含む path を `Read` するか、それを含む `Bash` を実行した（失敗した呼び出しは数えない）。`hc-supervisor restart` 後の監督役）、`fresh`（どちらでもない）。`resume_worker` を先に判定する。
- `startup_requests`：最初の編集系ツール（`Edit`・`MultiEdit`・`Write`・`NotebookEdit`）か `git commit` を含む `Bash` を出したリクエストより前のリクエスト数（そのリクエストは含めない）。`startup_cap` で打ち切る。編集がないセッション（調査だけ）は全リクエスト、または `startup_cap` まで伸びる近似である。
- `startup_cost`：上のリクエストの重み付きコストの合計（文脈を作り直すのにかかった分）。
- `ended_with_handoff`：最後の `handoff_tail` リクエストの中に、`handoff_write_paths` のどれかを含む path への `Write`・`Edit` がある。
- 対象は本体のストリームだけで、サブエージェントと `sidechain` は見ない。

## タスク単位の集計（report --by task・rescan、#48）

セッションの記録をタスク（Issue）ごとに束ね、Issue 1 件ごとの消費量、作り直しの割合、委譲の割合、無駄トークンを比べる。記録は SessionEnd の `record` で自動に溜まり、タスク単位の表は `report --by task` を実行するたびに記録から作る（別のファイルには溜めない）。

### `record` が足す項目

| キー | 取り方 |
|---|---|
| `git.repo` | `git -C <cwd> rev-parse --path-format=absolute --git-common-dir` の親ディレクトリの名前（worktree でも本体のリポジトリ名） |
| `git.branch` | `git -C <cwd> branch --show-current`。取れなければ transcript の本体の行で最も多い `gitBranch`（`HEAD` は数えない） |
| `git.branch_source` | `git` / `transcript` / `null` |
| `hc.terminal` | `HC_TERMINAL_ID` |
| `hc.role` | `HC_CLAUDE_ROLE`（`hc-claude` が `supervisor` / `worker` を export する） |
| `ctx_budget` | `CLAUDE_CTX_GUARD_TOKENS`（`context_bloat` の予算にも使う） |

`cwd` は hook の入力、無ければ transcript の本体の行で最も多い `cwd`。git が無い、`cwd` が無い（worktree を消した後など）ときは `null` にして記録は続ける。

### タスクの key

記録から次の順で決める（`task_key`。`record`・`rescan`・`git` の無い古い記録に同じ規則を使う）。

1. `hc.role` が `supervisor` → `supervisor`（監督役のコストはタスクに配分せず、この行にまとめる）
2. `git.branch` が `task_branch_pattern` に当たる → `<repo>#<番号>`（`feature/issue-12-x` → `dotfiles#12`、`epic-201-summary` → `mlbot-dev#201`）
3. ブランチがあり `main`・`master` でない → `<repo>:<branch>`（`fix/no-issue-y` など）
4. それ以外 → `cwd:<cwd>`

`git.repo` が分からないときは `?` を使う（`?#12`）。hc の引き継ぎは同じ worktree・同じブランチで続くので、作り直したワーカーのセッションも同じタスクに入る。1 つのセッションで複数の Issue を扱うと（オーケストレーター方式のメインセッションなど）、そのブランチ 1 つの key にまとまる。サブエージェントが別 worktree で作業した分も、本体のセッションの key に入る。

### `report --by task`

```bash
claude-token-metrics report --by task [--since 2026-11-22] [--json]
```

`--since` はセッションの `started_at`（UTC）で絞る。タスクごとに 1 行、始まりの早い順。

| 列（JSON のキー） | 定義 |
|---|---|
| `task` | 上の key |
| `sessions` / `resumed` | セッション数 / そのうち `restart.kind` が `resume_*` の数。`restart` の無い記録だけなら `-`（`null`） |
| `requests`、`weighted_cost` | セッションの合計 |
| `restart_ratio` | `resume_*` のセッションの `startup_cost` の合計 ÷ タスクの `weighted_cost` |
| `subagent_cost_share` | `subagents` scope の重み付きコストの合計 ÷ タスクの `weighted_cost` |
| `waste_share` | `waste.total.weighted_cost` の合計 ÷ タスクの `weighted_cost`。`waste` の無い記録だけなら `-` |
| `waste_top` | ルール別の重み付きコストの合計が大きい順に 3 件（0 は出さない） |
| `context_max`、`models` | 本体の文脈の最大、使ったモデルの一覧 |
| `config_hashes` | 記録に含まれる `waste.config_hash` の一覧。2 つ以上なら表の `waste` 列に `*` を付け、stderr に注意を出す（閾値が違う記録を比べている） |
| `sessions_without_waste` | `waste` の無い（#46 より前の）記録の数。`waste_share` の分母には入るので、0 でなければ低めに出る |
| `started_at`、`session_ids` | 最初のセッションの開始時刻、セッションの一覧（JSON だけ） |

比較は割合（`waste_share`、`restart_ratio`、`subagent_cost_share`）と、Issue 1 件あたりの `weighted_cost` で行う。

### `rescan`

```bash
claude-token-metrics rescan --since 2026-11-14 [--projects <dir>]
```

`--since` の日（UTC）以降に更新された本体の transcript（`<projects>/<dir>/*.jsonl`。既定 `~/.claude/projects`）を、今の重みと `waste.json` で集計し直して `sessions.jsonl` に追記する。後の行が使われるので、閾値を変えた後の再集計にも使える。transcript は Claude Code が古いものを消すので、消えたセッションは再集計できない（記録は残る）。

- `git.branch` は transcript の本体の行で最も多い `gitBranch`、`git.repo` は transcript の `cwd` に git を実行して取る（worktree を消していて取れなければ、同じ `session_id` の既存の記録の値）。
- `hc`・`ctx_budget`・`reason`・`cwd` は同じ `session_id` の既存の記録から引き継ぐ（無ければ `null`）。`ctx_budget` は `context_bloat` の予算にも使う。
- 追記した行には `"rescanned": true` が付く。1 件の集計に失敗しても他は続け、失敗があれば exit 1。

確認方法（dev）：hc でワーカーを 1 件動かし、SessionEnd 後の `sessions.jsonl` の最後の行に `git.repo`・`git.branch`・`hc.role` = `worker`・`hc.terminal` が入り、`report --by task` にその Issue の行（`<repo>#<番号>`）が出ることを見る。
