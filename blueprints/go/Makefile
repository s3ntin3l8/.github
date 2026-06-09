.DEFAULT_GOAL := help

# Run `make` (or `make help`) to list available targets.
.PHONY: help install-hooks lint test build vet fmt vulncheck tidy clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

install-hooks: ## Install pre-commit hooks
	pre-commit install
	pre-commit install --hook-type pre-push

lint: vet fmt-check ## Run vet + gofmt format check

vet: ## Static analysis
	go vet ./...

fmt-check: ## Check that all .go files are gofmt-clean (CI uses this)
	@test -z "$$(gofmt -l $$(git ls-files '*.go'))" || \
		(echo "::error::gofmt needed on:" && gofmt -l $$(git ls-files '*.go') && exit 1)

fmt: ## Auto-fix formatting
	gofmt -w .

test: ## Run tests with race detector + coverage
	go test -race -coverprofile=coverage.txt -covermode=atomic -coverpkg=./... ./...

build: ## Compile all packages
	go build ./...

tidy: ## Sync go.mod / go.sum
	go mod tidy

vulncheck: ## Scan for known vulnerabilities (requires `go install golang.org/x/vuln/cmd/govulncheck@latest`)
	govulncheck ./...

clean: ## Remove build artifacts
	rm -f coverage.txt
	go clean -testcache
