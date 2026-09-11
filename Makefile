.DEFAULT_GOAL := help
.PHONY: bootstrap link codex-config integration wsl doctor help

bootstrap: ## Install terminal/agent tools and link portable configuration.
	./.bin/install-agent-terminal.sh
	$(MAKE) link
	$(MAKE) codex-config
	$(MAKE) integration

link: ## Link the portable configuration into the current home directory.
	./.bin/link-agent-terminal-configs.sh

codex-config: ## Install portable Codex defaults only when no local config exists.
	./.bin/install-codex-config.sh

integration: ## Install Herdr's generated Codex integration files.
	./.bin/install-codex-herdr-integration.sh

wsl: ## Install WSL-side and Windows-side WSL configuration.
	./.bin/install-wsl-config.sh

doctor: ## Verify commands, links, and the status-line script.
	./.bin/doctor-agent-terminal.sh

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "%-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
