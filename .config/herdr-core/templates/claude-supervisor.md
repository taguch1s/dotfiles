---
description: 監督役の Claude Code。hc 上の全 Claude Code の権限確認を代行し、頼まれればワーカーを起動する。hc-supervisor から起動する。
command: claude --model opus --settings "$HOME/.config/herdr-core/claude/supervisor-settings.json" --append-system-prompt-file "$HOME/.config/herdr-core/claude/supervisor-prompt.md"
---
システムプロンプトの監督役の役割で動いてください。
