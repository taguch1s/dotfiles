.DEFAULT_GOAL := help
.PHONY: bootstrap link codex-config integration wsl doctor help

bootstrap: ## 端末・エージェント用ツールを導入し、移植可能な設定をリンクする。
	./.bin/install-agent-terminal.sh
	$(MAKE) link
	$(MAKE) codex-config
	$(MAKE) integration

link: ## 移植可能な設定を現在のホームディレクトリへリンクする。
	./.bin/link-agent-terminal-configs.sh

codex-config: ## ローカル設定がない場合のみ、移植可能な Codex 既定値を導入する。
	./.bin/install-codex-config.sh

integration: ## Herdr が生成する Codex 連携ファイルを導入する。
	./.bin/install-codex-herdr-integration.sh

wsl: ## WSL 側と Windows 側の WSL 設定を導入する。
	./.bin/install-wsl-config.sh

doctor: ## コマンド、リンク、ステータスラインスクリプトを検証する。
	./.bin/doctor-agent-terminal.sh

help: ## 利用可能なターゲットを表示する。
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "%-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
