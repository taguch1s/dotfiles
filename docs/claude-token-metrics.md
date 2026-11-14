# Claude トークン効率指標（claude-token-metrics）

Claude Code のトランスクリプト（`~/.claude/projects/**/<session>.jsonl` と `<session>/subagents/*.jsonl`）から、セッションごとのトークン効率指標（L0〜L2）を集計する。親 Issue は #17、実装は #18。

```bash
claude-token-metrics session ~/.claude/projects/-home-issei/<session>.jsonl   # 1 行の JSON
claude-token-metrics report --since 2026-11-14          # 記録済みセッションの表
claude-token-metrics report --json                      # 同じ内容を JSON の配列で
```

## SessionEnd hook の導入

リポジトリ版 `.claude/settings.json` の `SessionEnd` に `claude-token-metrics record` を登録してある。ただし `~/.claude/settings.json` は `copy-if-missing` なので、既に設定がある端末には反映されない。その場合は `make link` で `~/.local/bin/claude-token-metrics` を配置したうえで、`~/.claude/settings.json` の `hooks.SessionEnd[0].hooks` に次を手で追加する。

```json
{
  "type": "command",
  "command": "~/.local/bin/claude-token-metrics record || true",
  "timeout": 10
}
```

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

`claude-statusline` は Claude Code の statusline コマンドで、`ctx 182k | 5h 54% | 7d 8%` の 1 行を出す。

- `ctx`：`transcript_path` の最後のリクエスト（本体の assistant 行。合成メッセージと sidechain は除く）の `input + cache 作成 + cache 読み込み`。上の文脈サイズと同じ定義で、トランスクリプトは末尾から最大 16MB だけ読む。
- `5h` / `7d`：stdin の `rate_limits.five_hour` / `seven_day` の `used_percentage`。`rate_limits` が null や欠けている場合は `-` を出し、記録しない。

`used_percentage`（5h か 7d）が前回の記録から変わったときだけ、`${XDG_DATA_HOME:-~/.local/share}/claude-token-metrics/ratelimit.jsonl` に 1 行追記する。複数のセッションから同時に呼ばれても重ならないよう、ファイルをロックして比べる。

```json
{"ts": "2026-11-14T01:02:03.456+00:00", "session_id": "...", "five_hour": {"used_percentage": 54, "resets_at": 1763100000}, "seven_day": {"used_percentage": 8, "resets_at": 1763600000}}
```

どんな入力でも 1 行を出して exit 0 で終わる。リポジトリ版 `.claude/settings.json` に `statusLine` を登録してあるが、`~/.claude/settings.json` は `copy-if-missing` なので、既に設定がある端末では `make link` のあとに次を手で追加する。

```json
"statusLine": {"type": "command", "command": "~/.local/bin/claude-statusline"}
```

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
