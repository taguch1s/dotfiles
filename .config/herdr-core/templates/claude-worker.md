---
description: Claude Code の実装担当。監督役が起動する。担当 worktree と完了条件を渡す。権限確認は ~/.claude/settings.json の hook と監督役が判断する。
command: claude --model opus --settings "$HOME/.config/herdr-core/claude/worker-settings.json" --append-system-prompt-file "$HOME/.config/herdr-core/claude/worker-prompt.md"
---
システムプロンプトのワーカーの役割で、次の依頼を進めてください。
