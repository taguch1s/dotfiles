---
description: Claude Code の指揮役。Issue ごとにワーカーを起動し、ワーカーの権限確認に答える。hc-orch から起動する。
command: claude --model opus --settings "$HOME/.config/herdr-core/claude/orchestrator-settings.json" --append-system-prompt-file "$HOME/.config/herdr-core/claude/orchestrator-prompt.md"
---
システムプロンプトのオーケストレーターの役割で、次の依頼を進めてください。
