---
description: Claude Code の実装担当。担当 worktree と完了条件を渡す。権限確認は hook と親が判断する。
command: claude --model opus --permission-mode default --settings "$HOME/.config/herdr-core/claude/worker-settings.json" --append-system-prompt-file "$HOME/.config/herdr-core/claude/worker-prompt.md"
---
システムプロンプトのワーカーの役割で、次の依頼を進めてください。
