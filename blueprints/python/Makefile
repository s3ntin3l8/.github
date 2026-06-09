.DEFAULT_GOAL := help
VENV := .venv
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip

.PHONY: help install install-hooks test lint format clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

install-hooks: ## Install pre-commit hooks
	$(VENV)/bin/pip install pre-commit
	$(VENV)/bin/pre-commit install
	$(VENV)/bin/pre-commit install --hook-type pre-push

install: install-hooks ## Set up venv and install dependencies
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	[ -f requirements-dev.txt ] && $(PIP) install -r requirements-dev.txt || true
	[ -f requirements.txt ] && $(PIP) install -r requirements.txt || true

test: ## Run tests
	$(VENV)/bin/pytest

lint: ## Run pre-commit on all files
	$(VENV)/bin/pre-commit run --all-files

format: ## Auto-fix formatting
	$(VENV)/bin/ruff format .

clean: ## Remove venv and caches
	rm -rf $(VENV) .pytest_cache .mypy_cache .ruff_cache .coverage
