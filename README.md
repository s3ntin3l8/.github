# s3ntin3l8/.github

This repository contains centralized workflows, security policies, and repository templates for my projects.

## 🚀 Reusable Workflows

These building blocks allow any repository to implement a robust CI/CD pipeline with just a few lines of YAML.

### [CI-Python](.github/workflows/ci-python.yml)
Handles ruff, mypy, pytest, codecov, and secret scanning for Python projects.

### [CI-Node](.github/workflows/ci-node.yml)
Handles linting and building for Node.js / React projects.

### [Docker-Publish](.github/workflows/docker-publish.yml)
Handles multi-arch builds (amd64/arm64), GHCR pushing, and Cosign signing.

### [CodeQL](.github/workflows/codeql.yml)
Advanced semantic security scanning.

### [Release-Please](.github/workflows/release-please.yml)
Automated versioning and changelogs.

---

## 🛡️ Global Health Files
The following files are automatically applied to all public repositories in this account:
- [SECURITY.md](SECURITY.md) - Security disclosure policy.
- [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) - Default PR checklist.

## 🛠️ Blueprints

These are templates you can copy into your local projects to standardize your development environment.

### [Python Blueprints](blueprints/python/)
- [Makefile](blueprints/python/Makefile) - Standard Python dev environment setup.
- [pre-commit.yaml](blueprints/python/pre-commit.yaml) - Standard Python linting and testing hooks.
- [pyproject.toml](blueprints/python/pyproject.toml) - Pre-tuned Ruff and Mypy configuration.
- [README.md.template](blueprints/python/README.md.template) - High-signal project README template.

## 🛡️ Templates
- [dependabot.yml](dependabot.yml) - Recommended configuration for weekly dependency updates.
