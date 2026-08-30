.DEFAULT_GOAL := help

# Run `make` (or `make help`) to list available targets.
.PHONY: help install-hooks lint fmt fmt-check test build dev vulncheck clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

install-hooks: ## Install pre-commit hooks
	pre-commit install
	pre-commit install --hook-type pre-push

lint: fmt-check ## Run cargo clippy + rustfmt check
	cd src-tauri && cargo clippy --all-targets --all-features -- -D warnings

fmt-check: ## Check that all Rust files are rustfmt-clean (CI uses this)
	cd src-tauri && cargo fmt --check

fmt: ## Auto-fix formatting
	cd src-tauri && cargo fmt

test: ## Run tests
	cd src-tauri && cargo test --all-features

build: ## Build the frontend, then the Tauri app
	npm ci
	npm run build
	cd src-tauri && cargo build --release

dev: ## Run the app in dev mode (requires the tauri-cli: cargo install tauri-cli)
	cargo tauri dev

vulncheck: ## Scan Rust dependencies for known vulnerabilities (requires: cargo install cargo-audit)
	cd src-tauri && cargo audit

clean: ## Remove build artifacts
	# `dist` matches this blueprint's own Vite-style frontendDist convention --
	# adjust if your project's frontend build writes elsewhere (build/, .output/, out/, ...).
	rm -rf dist node_modules
	cd src-tauri && cargo clean
