# Claude トークン効率指標（claude-token-metrics）

Claude Code のトランスクリプト（`~/.claude/projects/**/<session>.jsonl` と `<session>/subagents/*.jsonl`）から、セッションごとのトークン効率指標（L0〜L2）を集計する。親 Issue は #17、実装は #18。

```bash
claude-token-metrics session ~/.claude/projects/-home-issei/<session>.jsonl   # 1 行の JSON
claude-token-metrics report --since 2026-11-14          # 記録済みセッションの表
claude-token-metrics report --json                      # 同じ内容を JSON の配列で
claude-token-metrics waste <transcript.jsonl>           # 無駄の検出結果をルール別の表で（下の「無駄の検出」）
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

- 先頭：`session_id`、`transcript_path`、`version`（Claude Code）、`versions`、`started_at` / `ended_at`、`weights`、`weights_source`、`skipped`（`broken_lines`、`no_usage`、`synthetic`）。`record` はさらに `recorded_at`、`reason`、`cwd` を足す。
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

実装の細部：

- `reread_file` の行の範囲は、開始が `offset`（既定 1）、行数が結果の中の行番号つきの行（`N<tab>` / `N→`）の数。失敗した `Read` は記録しない。編集系ツールの結果が来ると、その path の `Read` の記録を消す。`Bash` の command にその path の文字列があっても消す（見逃し側に倒す）。
- `repeated_failure` の記録は、編集系ツールの結果で全部消す（TDD の Red や、修正のたびに test を流す反復は数えない）。
- `hints.failure_streaks`：同じ `command_key` の結果が、成功を挟まず `failure_streak` 回以上続けて `is_error` だったもの（他のツールの結果は挟んでよい）。トークンは数えず、`key`、`count`、最初と最後の `tool_use_id` を出す。
- `cache_rewrite` の `cause`：間隔（両リクエストの最初の行の `timestamp` の差）が TTL を超え、R_j の直前が人の発言なら `idle`、ツール結果なら `tool_wait`。間隔が TTL 以下か取れなければ `break`（system prompt やツール定義の変化など）。TTL は、そのストリームでそれまでに 1h cache を書いていれば 3600 秒、なければ 300 秒（`cache_ttl_seconds` で固定できる）。
- `context_bloat` の予算は、`record` のときは環境変数 `CLAUDE_CTX_GUARD_TOKENS`（hc の監督役 150000、ワーカー 120000）、無ければ `context_budget`。`session` / `waste` は常に `context_budget` を使う。`hints.requests_after_budget` は最初に予算を超えたリクエストより後の本体のリクエスト数。

### 設定（`waste.json`）

`${XDG_CONFIG_HOME:-~/.config}/claude-token-metrics/waste.json`。既定値 < 設定ファイル < `--waste-config <path>` の順に上書きする。一部のキーだけでよく、`waste` 以外のキーは読み飛ばす。

```json
{"waste": {"oversized_bytes": 20000, "min_bytes": 200, "exempt_keys": [], "failure_streak": 3,
           "cache_miss_ratio": 0.5, "cache_ttl_seconds": null, "context_budget": 150000,
           "findings_limit": 50, "bytes_per_token": 2.2}}
```

| キー | 既定値 | 値の範囲 |
|---|---|---|
| `oversized_bytes` | 20000 | 0 以上の整数 |
| `min_bytes` | 200 | 0 以上の整数（`duplicate_result` の対象の下限） |
| `exempt_keys` | `[]` | `command_key`（`Bash:<先頭語>` かツール名）の配列。`oversized_output` と `duplicate_result` で共有 |
| `failure_streak` | 3 | 2 以上の整数 |
| `cache_miss_ratio` | 0.5 | 0 より大きく 1 以下 |
| `cache_ttl_seconds` | `null` | `null`（自動）か 0 より大きい数値 |
| `context_budget` | 150000 | 1 以上の整数 |
| `findings_limit` | 50 | 0 以上の整数 |
| `bytes_per_token` | 2.2 | 0 より大きい数値 |

知らないキーは stderr に警告して無視する。型・範囲が不正な値や読めないファイルは、`session` / `waste` では exit 2、`record` では既定値で集計して `record.log` に理由を残す。

閾値の既定値は、Epic #45 の実データの分布（ツール結果の p99 16.7 kB、最大 27.7 kB など）を根拠にした仮の値で、タスク単位の記録が溜まってから見直す。`bytes_per_token` の 2.2 は、dotfiles の transcript 5 本で Δ が取れたツール結果 49 件の バイト ÷ トークン の中央値 2.212（十分位 1.73〜2.74）から決めた。日本語や記号の多い出力ほど小さくなる。

### 出力（schema `claude-token-metrics/waste/v1`）

- `config`（使った値の全部）、`config_hash`（キー順で正規化した JSON の sha256 の先頭 12 文字）、`config_source`（`default` / `file` / `cli`）。
- `rules`：ルールごとの `count`、`tokens`、`weighted_cost`。`context_bloat` にはさらに `budget` と `budget_source`（`env` / `config`）。
- `cache_rewrite_by_cause`：`idle` / `tool_wait` / `break` ごとの同じ集計。
- `total`：`tokens`、`weighted_cost`、`share`（無駄の重み付きコスト ÷ セッションの `total.weighted_cost`。0 なら null）。
- `findings`：`rule`、`scope`、`file`、`request_index`、`timestamp`、`tool_use_id`、`key`、`tokens`（小数 1 桁）、`token_source`（`delta` / `bytes`。ツール結果以外は null）、`weighted_cost`（小数 4 桁）、`detail`（ルールごとの補足。`Read` の path、ハッシュの先頭 12 文字、閾値、`first_tool_use_id` など。本文は入れない）。重み付きコストの降順、同じなら scope・file・`request_index`・`tool_use_id`・ルールの順で並べ、`findings_limit` 件まで出す。合計は件数を絞る前の全件で数える。
- `hints`：`failure_streaks`、`requests_after_budget`。

同じ transcript と同じ設定なら、`findings` の順序まで同じ結果になる。
