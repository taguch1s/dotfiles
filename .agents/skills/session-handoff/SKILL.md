---
name: session-handoff
description: 作業状態を Git 管理外のhandoffへ圧縮し、別セッションが会話履歴なしで安全に再開できる状態を残す。
---

# Session Handoff

handoff は要求・設計の正本ではない。親 Issue、Accepted design artifact、PR、Git diff、remote state を優先し、矛盾は `Open questions / blockers` に記録する。

## 70,000 input-token 運用閾値

これは Codex / プラットフォームの自動 compact 閾値を変更する機能ではない。Herdr status が報告する最新の `input_tokens` に基づく、手動の安全な handoff 規約である。

- Unit 完了の直前、長時間の test / build / 調査 / 外部操作の直前、commit・push・PR 操作の直前に最新値を確認する。
- `input_tokens >= 70_000` のとき handoff を始める。値が取れない、欠けている、数値でないときは閾値未満として扱い、推測で handoff や session 切替を行わない。
- 到達後は新しい作業 Unit を始めない。進行中の atomic operation（test、commit、push など）は安全に完結させる。完結できなければ、実行済み command、結果、残った安全な次の action を handoff に記録する。
- handoff を保存したら、最終報告に次セッションの再開 prompt をそのまま示す。最終報告を返すことや現在の session を終了することは session 切替ではない。
- ユーザーが当該 task について 70k 到達時の fresh continuation（新規 top-level tab）を明示的に許可している場合だけ、既存の Herdr preflight を再実行し、`herdr-codex-orchestrate --new-top-level --cwd "$PWD" "<handoff の Next-session prompt>"` で新しい Codex session を起動する。launcher が返した tab ID / main agent 名を handoff に記録し、`herdr tab get <tab-id>` と Herdr status から main agent の `agent_session.value` を再取得する。その ID が起動元と異なる非空値であることを確認して初めて fresh continuation とする。確認前に旧 session を終了・継続済み報告してはならない。
- 明示許可がない場合、handoff は Herdr の tab / pane 作成・終了や session 切替を許可しない。handoff と prompt を提示して現在の session を終了し、次の起動はユーザーの指示を待つ。UI 操作は `AGENTS.md` の Herdr 規約に従う。

開始時に `AGENTS.md`、対象 Issue / PR、既存 handoff を読み、次を再取得する。

```bash
pwd
git status -sb
git worktree list
git branch --show-current
git diff --stat
```

保存先は `git rev-parse --git-path codex-handoffs` 配下の `<task-slug>.md` とする。tracked `docs/` や session ごとの新規ファイルは使わず、1 file 50 KiB 未満を目安に同じ handoff を更新する。

```markdown
# Handoff: <task title>

- Repository / worktree:
- Branch:
- Parent Issue / design artifact / PR:

## Goal / Done / Non-goals
## Canonical references
## Completed units / commits / checks
## Confirmed decisions / rejected proposals
## Worktree / branch / current diff
## Current unit and exact next action
## Fresh-continuation verification
## Open questions / blockers / residual risks
## Next-session prompt
```

生ログ、長い diff、secret、token、個人情報は残さない。次セッション用 prompt には絶対 worktree path、handoff path、親 Issue / PR、最初に読む正本、最初の状態確認 command、現在 Unit の exact next action、停止条件を含める。保存後に path、Issue / PR、branch、commit、check 結果を実データと照合する。
