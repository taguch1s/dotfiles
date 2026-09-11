---
name: session-handoff
description: 作業状態を Git 管理外のhandoffへ圧縮し、別セッションが会話履歴なしで安全に再開できる状態を残す。
---

# Session Handoff

handoff は要求・設計の正本ではない。親 Issue、Accepted design artifact、PR、Git diff、remote state を優先し、矛盾は `Open questions / blockers` に記録する。

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
## Open questions / blockers / residual risks
## Next-session prompt
```

生ログ、長い diff、secret、token、個人情報は残さない。次セッション用 prompt には絶対 worktree path、handoff path、親 Issue / PR、最初に読む正本、最初の状態確認 command、現在 Unit の exact next action、停止条件を含める。保存後に path、Issue / PR、branch、commit、check 結果を実データと照合する。
