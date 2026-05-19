NVIM_CONTEXT_MCP_STATE_DIR := /tmp/nvim-context-mcp-test
VERSION ?=
TAG := v$(VERSION)

.PHONY: help
help: ## Print this help menu
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: require
require: ## Check that prerequisites are installed
	@if ! command -v cargo > /dev/null; then \
		printf "\033[1m\033[31mERROR\033[0m: cargo not installed.\n" >&2 ; \
		exit 1; \
		fi
	@if ! command -v nvim > /dev/null; then \
		printf "\033[1m\033[31mERROR\033[0m: nvim not installed.\n" >&2 ; \
		exit 1; \
		fi

.PHONY: require-release
require-release: require ## Check that release prerequisites are installed
	@if ! command -v gh > /dev/null; then \
		printf "\033[1m\033[31mERROR\033[0m: gh not installed.\n" >&2 ; \
		exit 1; \
		fi

.PHONY: build
build: require ## Build the MCP server
	cargo build

.PHONY: fix
fix: require ## Fix all files in-place
	cargo fmt

.PHONY: lint
lint: require ## Run formatting and compile checks
	cargo fmt --check
	cargo check

.PHONY: lua-smoke
lua-smoke: require ## Smoke-test the Neovim plugin in headless Neovim
	NVIM_CONTEXT_MCP_STATE_DIR=$(NVIM_CONTEXT_MCP_STATE_DIR) nvim --headless --clean +'set rtp+=.' +'lua local m = require("nvim_context_mcp"); m.setup({ heartbeat_ms = 60000 }); m.setup({ heartbeat_ms = 60000 }); assert(m.visible_context().schemaVersion == 1); assert(type(m.buffers().buffers) == "table"); assert(m.buffer_text({ maxLines = 1 }).schemaVersion == 1); assert(m.buffer_text({ maxLines = 0, maxBytes = 0 }).schemaVersion == 1); assert(type(m.diagnostics({ maxDiagnostics = 1, severity = "WARN" }).buffers) == "table"); m.stop()' +qa

.PHONY: tests
tests: lint lua-smoke ## Run full local validation
	cargo test

.PHONY: release-check
release-check: require-release ## Check release inputs and local validation
	@if [ -z "$(VERSION)" ]; then \
		printf "\033[1m\033[31mERROR\033[0m: VERSION is required. Example: make release VERSION=0.1.0\n" >&2 ; \
		exit 1; \
		fi
	@if git rev-parse "$(TAG)" >/dev/null 2>&1; then \
		printf "\033[1m\033[31mERROR\033[0m: tag $(TAG) already exists.\n" >&2 ; \
		exit 1; \
		fi
	$(MAKE) tests

.PHONY: release
release: release-check ## Tag, push, and publish a GitHub release. Usage: make release VERSION=0.1.0
	git tag "$(TAG)"
	git push origin "$(TAG)"
	gh release create "$(TAG)" --verify-tag --generate-notes

.PHONY: install
install: require ## Install the MCP server onto PATH
	cargo install --path .

.PHONY: clean
clean: ## Remove Rust build artifacts
	cargo clean
