# CLAUDE.md — s3ntin3l8/.github

Central home for **reusable GitHub Actions workflows**, **repo blueprints**, and org
health files consumed by my other repositories. If you are an AI agent or contributor
editing this repo, read this first.

## ⚠️ Consumers pin `@main` — changes go live immediately

Every reusable workflow is referenced downstream as
`s3ntin3l8/.github/.github/workflows/<name>.yml@main`. **A change merged to `main`
here is live in every consumer's *next* CI run — there is no staging.** Therefore:

- **Stay backward compatible.** New inputs must have `default:` values; never rename or
  remove an input/secret a caller relies on; don't silently raise the permissions a
  reusable workflow requires (that breaks callers — see below).
- **This repo has no CI of its own.** Reusable workflows can't run standalone. The only
  real test is a consumer: point a throwaway branch in a consumer repo (e.g. `runway`)
  at your feature ref — `uses: s3ntin3l8/.github/.github/workflows/<x>.yml@<your-branch>` —
  open a PR, confirm its checks pass, then revert. Local YAML parsing and shell-snippet
  checks are necessary but **not** sufficient.

## ⚠️ The caller-permissions contract (the #1 failure mode)

A called workflow's `GITHUB_TOKEN` permissions are **capped by the caller**, and most
repos default to a **read-only** token (`Settings → Actions → Workflow permissions`).
If a caller job does not declare a `permissions:` block, any reusable workflow that
needs write scopes makes the **entire run fail at startup with zero jobs** (not a
per-step error — the whole run is rejected at parse time). `secrets: inherit` forwards
secrets but does **not** grant permissions.

When you change what permissions a workflow needs, update the per-workflow
`permissions:` documentation in [README.md](README.md). Current requirements:

| Workflow | Required caller `permissions:` |
|----------|-------------------------------|
| `ci-python` / `ci-node` | none beyond default `contents: read` |
| `docker-publish` | `contents: read`, `packages: write`, `id-token: write` |
| `codeql` | `actions: read`, `contents: read`, `security-events: write` |
| `release-please` | `contents: write`, `pull-requests: write` |
| `ghcr-cleanup` | `packages: write` |

## Layout

- `.github/workflows/*.yml` — reusable workflows (`workflow_call`): `ci-python`,
  `ci-node`, `docker-publish`, `codeql`, `release-please`, `ghcr-cleanup`.
- `blueprints/python/` — files to **copy into** a new project (Makefile,
  `pre-commit.yaml`, `pyproject.toml`, README template). These are parallel copies of
  what the **[`python-backend-template`](https://github.com/s3ntin3l8/python-backend-template)**
  repo ships — **keep the two in sync** when you edit either.
- `dependabot.yml`, `SECURITY.md`, `.github/PULL_REQUEST_TEMPLATE.md` — org defaults.

## Conventions

- **Conventional Commits** (this repo and its consumers use Release Please).
- **Graceful, layout-agnostic workflows.** `ci-python` installs from
  `requirements-dev.txt`, else editable-installs a `pyproject.toml`/`setup.py` project
  (`pip install -e ".[dev]"`), else `requirements.txt` — so it works whether deps live
  in requirements files or pyproject. Don't hardcode repo-specific assumptions (e.g.
  the package name — use the `coverage-source` input, default `app`).
- **Detect npm scripts by exact key** (`npm pkg get scripts.X`), never by grepping
  `npm run` output (it matched substrings and ran the `npm init` `exit 1` stub).
- **Action versions** are bumped by Dependabot (the `github-actions` ecosystem is
  configured) — don't hand-pin unless fixing a specific break.

## Quick reference: minimal consumer

```yaml
jobs:
  test-python:
    uses: s3ntin3l8/.github/.github/workflows/ci-python.yml@main
    with:
      coverage-source: 'my_pkg'   # omit if the package is named 'app'
    secrets: inherit
  build-docker:
    needs: [test-python]
    permissions:                  # REQUIRED — ci-python needs none, docker-publish does
      contents: read
      packages: write
      id-token: write
    uses: s3ntin3l8/.github/.github/workflows/docker-publish.yml@main
    with:
      image-name: 's3ntin3l8/${{ github.event.repository.name }}'
    secrets: inherit
```
