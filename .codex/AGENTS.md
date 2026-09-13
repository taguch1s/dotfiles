# 共通の Codex 作業規約

- 変更前に、対象アプリケーション、Git リポジトリ、作業ディレクトリ、既存状態を実データで確認する。名称が曖昧で結果が変わる場合だけ、変更せず質問する。
- 恒久的な作業規約はこのファイルまたはリポジトリ管理された文書に置く。Memory と会話履歴は補助情報であり、規約の正本にしない。
- 変更・実装では、対象リポジトリの `AGENTS.md`、検証コマンド、Git 状態を確認し、未検証の結果を完了と報告しない。
- 別 task の変更やユーザー所有の未追跡ファイルを、明示指示なしに編集、移動、削除しない。

## Herdr のタスク運用

- 「Issue を進める」「実装する」は新規 tab 作成の許可ではない。Herdr 管理下の main session で task がすでに始まっている場合は、その session を継続し、`herdr-codex-orchestrate` を実行しない。
- 新規 top-level task 用 tab を作る前に、`test "${HERDR_ENV:-}" = 1`、`herdr workspace list`、`herdr tab list --workspace "$HERDR_WORKSPACE_ID"`、`herdr pane current --current` を実行し、現在の pane、既存の同一 task、作成済み delegate を確認する。既存 session の所有者・目的を判別できない場合は読み取りだけに留め、new tab を作らない。
- ユーザーが「新しい tab で始める」「新規 top-level task を作る」と明示した場合だけ、`herdr-codex-orchestrate --new-top-level "<task>"` を実行する。このランチャーは新規 tab を作り、左に main orchestrator、右に delegate を配置する。独立した delegate を並列実行する場合は `--delegates N` を指定し、右列だけを縦に分割する。
- delegate / subagent は `herdr-codex-orchestrate` を実行しない。作成済み main session が割り当てた範囲だけを扱い、自身や他の delegate 用の tab / pane / agent を追加しない。
- 「session が多い」「減らして」のような観測は、tab、pane、workspace、agent、server を終了する許可ではない。`herdr tab close`、`herdr pane close`、`herdr agent send-keys ... ctrl+c`、`herdr server stop` は、ユーザーが対象 ID または終了対象を明示した場合だけ実行する。重複が疑われるときは ID、cwd、状態を報告して指示を待つ。
- main orchestrator は要件整理、タスク分割、delegate への割り当て、統合判断、最終検証、ユーザー報告だけを担当する。production code や設定の編集は delegate に委譲し、結果を独立に確認してから採用する。
- delegate は明確に割り当てられた範囲だけを扱い、変更・検証・ブロッカーを main orchestrator に返す。並列編集では別 worktree または非重複ファイルを使う。

## コンテキスト上限前の handoff

- これはプラットフォームの自動 compact 閾値を変更する設定ではなく、作業を安全に引き継ぐための運用上の閾値である。
- Unit 完了の直前、長時間の test / build / 調査 / 外部操作を始める直前、および commit・push・PR 操作の直前に、Herdr status が示す最新の `input_tokens` を確認する。
- 最新の `input_tokens >= 70_000` なら handoff を開始する。値を取得できない、欠けている、数値でない場合は閾値未満とみなし、推測で handoff・session 切替をしない。
- 閾値到達後は新しい作業 Unit を開始しない。進行中の test・commit・push などの atomic operation は安全に完結させ、完結できない場合は実行状態と結果を handoff に記録する。
- handoff は `session-handoff` skill の指定形式で Git 管理外に保存する。最終報告を返すことや現在の session を終了することは、session 切替ではない。70k handoff を「継続済み」と報告できるのは、handoff の再開 prompt を渡した別の Codex session が実際に起動し、その新しい session ID を確認した後だけである。
- ユーザーが当該 task で 70k 到達時の fresh continuation（新規 top-level tab）を明示的に許可している場合は、handoff 保存後、既存の Herdr preflight を再実行してから `herdr-codex-orchestrate --new-top-level --cwd "$PWD" "<handoff の Next-session prompt>"` で continuation を起動する。返却された tab ID / main agent 名を記録し、`herdr tab get <tab-id>` と Herdr status の main agent `agent_session.value` を再取得して、起動元とは異なる非空の session ID を照合する。確認できるまで旧 session を終了せず、continuation を報告しない。
- fresh continuation の明示許可がない場合、この規約は tab / pane の新規作成・終了や session 切替を自動許可しない。handoff と再開 prompt を保存・提示して現在の session を終了し、次の起動はユーザーの指示を待つ。Herdr の UI 操作には上記の既存規約を引き続き適用する。

## 再発防止メモリ

- Codex memories は有効だが、永続ルールの正本ではない。失敗から cross-project で再発しうる教訓を得たときだけ、原因・予防策・適用条件を短く memory に保存する。秘密情報、個人情報、一過性の障害、task 固有のデバッグログは保存しない。
- repository 固有の制約や恒久運用ルールは memory だけに置かず、その repository の `AGENTS.md` または追跡文書にも記録する。既存の memory と重複する場合は追加せず更新する。
