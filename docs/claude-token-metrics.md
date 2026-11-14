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
