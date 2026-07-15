# s3ntin3l8/.github

This repository contains centralized workflows, security policies, and repository templates for my projects.

## 🚀 Reusable Workflows

These building blocks allow any repository to implement a robust CI/CD pipeline with just a few lines of YAML.

> [!IMPORTANT]
> **Caller jobs must grant the permissions the reusable workflow needs.** A called
> workflow's permissions are *capped by the caller*, and most repos default to a
> read-only `GITHUB_TOKEN` (`Settings → Actions → Workflow permissions`). If the
> caller job does not declare a `permissions:` block, any reusable workflow that
> needs write scopes makes the **entire run fail at startup with zero jobs**. Grant
> the permissions listed below on each calling job (`secrets: inherit` does *not*
> grant permissions — it only forwards secrets).

### [CI-Python](.github/workflows/ci-python.yml)
ruff, mypy, pytest+coverage, Codecov (coverage **and** Test Analytics), pip-audit, detect-secrets.
- **Caller permissions:** none beyond the default `contents: read`.
- **Secrets:** `CODECOV_TOKEN` (optional) — pass via `secrets: inherit`.
- **Inputs:** `python-version`, `coverage-fail-under`, **`coverage-source`** (set this if your package isn't named `app`).
- **Expects:** dev tooling installable via `requirements-dev.txt`, **or** a `pyproject.toml`/`setup.py` (installed with `pip install -e ".[dev]"`).

### [CI-Node](.github/workflows/ci-node.yml)
Runs `lint` / `typecheck` (opt-in) / `test` npm scripts when present (the default `npm init` `exit 1` test stub is skipped), detect-secrets, then builds.
- **Caller permissions:** none beyond the default `contents: read`.
- **Secrets:** `CODECOV_TOKEN` (optional) — pass via `secrets: inherit`.
- **Detect-secrets:** opt-in on file presence, no caller YAML change needed — runs advisory-only the moment the repo has a `.secrets.baseline` at its root. Generate one with `detect-secrets scan > .secrets.baseline`. Set **`strict-checks`** to `true` once the baseline is verified clean (`detect-secrets scan --baseline .secrets.baseline` reports nothing new) to make it a hard gate.
- **Inputs:**
  - `node-version` (default `22`)
  - `working-directory` (default `.`) — directory containing `package.json`, relative to the repo root. All shell steps run there; the Codecov `directory:` is computed relative to the repo root.
  - `cache-dependency-path` (default `package-lock.json`) — path to the lockfile relative to the repo root, for npm cache keying. Override to `web/package-lock.json` for monorepos.
  - `build-script` (default `build`)
  - **`build-env`** (default `''`; extra env for the build step as `KEY=VALUE` lines, e.g. `NEXT_TELEMETRY_DISABLED=1`)
  - **`typecheck-script`** (default `''` = skip; set to `typecheck` to run type checking between lint and test)
  - **`test-script`** (default `test`; set to `test:coverage` to enable coverage upload and threshold enforcement)
  - **`coverage-fail-under`** (default `0` = disabled; set e.g. `80` to require ≥80% line coverage)
  - **`test-shards`** (default `1` = disabled; set e.g. `4` to split tests across a 4-way matrix via `vitest`/`jest` `--shard` syntax). `1` is a no-op — the single `lint-and-test` job runs exactly as before, so no existing caller is affected unless it opts in. Above `1`, tests move into a `test-shard` matrix (parallel with `lint-and-test`, so lint/typecheck/build no longer wait on tests) plus a `test-merge` job that combines every shard's coverage and enforces `coverage-fail-under` **once, over the union** — never per-shard. Requires the coverage reporter list to also include istanbul's `json` reporter (vitest: add `"json"` to `coverage.reporter`; jest: add `"json"` to `coverageReporters`) alongside `json-summary`, and a test script that accepts pass-through CLI args.
  - **`turbo-cache`** (default `true`) — cache `**/.turbo` under `working-directory` across runs (keyed by commit SHA, OS-scoped restore-key fallback). On by default: safe even for non-Turborepo callers (`actions/cache` no-ops on a missing path) and can't produce a stale/wrong result (Turbo's own hashing is content-based). Set `false` to opt out.
- **Expects:** a `package-lock.json` (uses `npm ci`). For coverage, a test setup that writes an istanbul `json-summary` report to `coverage/coverage-summary.json` (vitest v8, jest, c8, …).
- **Test Analytics (optional):** if the test runner emits JUnit XML (vitest `--reporter=junit --outputFile=./test-results/junit.xml`, or jest with jest-junit), it's uploaded to Codecov Test Analytics.

### [CI-Go](.github/workflows/ci-go.yml)
gofmt, `go vet`, `go build`, tests via `gotestsum` (race + coverage + JUnit), Codecov coverage **and** Test Analytics upload, `govulncheck`.
- **Caller permissions:** none beyond the default `contents: read`.
- **Secrets:** `CODECOV_TOKEN` (optional) — pass via `secrets: inherit`.
- **Inputs:** `go-version` (default empty — override the version, e.g. `'1.23'`), `go-version-file` (default `go.mod` — derives the version when `go-version` is empty), `coverage-fail-under` (default `0` = disabled).
- **Pre-build hook:** if a `.github/ci-prebuild.sh` exists in the repo, it runs before build (e.g. to stub `//go:embed` assets). Keep that logic in the script — there is no command-string input.
- **Expects:** a `go.mod` at the repo root (or override `go-version-file`).

### [Docker-Publish](.github/workflows/docker-publish.yml)
Multi-arch builds (amd64/arm64), GHCR push, and Cosign signing.
- **Caller permissions (required):** `contents: read`, `packages: write`, `id-token: write`.
- **Secrets:** `REGISTRY_USERNAME`/`REGISTRY_TOKEN` (optional; falls back to `GITHUB_TOKEN`) — pass via `secrets: inherit`.
- **Inputs:** `image-name` (required), `push-edge`, `push-release`, `release-tag`, `platforms`.

### [CodeQL](.github/workflows/codeql.yml)
Advanced semantic security scanning. Code scanning is free on public repos; private repos need GitHub Advanced Security.
- **Caller permissions (required):** `actions: read`, `contents: read`, `security-events: write`.
- **Inputs:** `languages` — comma-separated (`"python, javascript-typescript"`), a JSON array, or the legacy pre-quoted form.

### [Release-Please](.github/workflows/release-please.yml)
Automated versioning and changelogs.
- **Caller permissions (required):** `contents: write`, `pull-requests: write`.
- **Expects:** `release-please-config.json` and `.release-please-manifest.json` in the repo root.

### [Cleanup-GHCR](.github/workflows/ghcr-cleanup.yml)
Deletes untagged container versions from GHCR on a schedule.
- **Caller permissions (required):** `packages: write`.
- **Inputs:** `package-name` (required), `package-type`, `min-versions-to-keep`.

### [Dependency Review](.github/workflows/dependency-review.yml)
Checks for vulnerable dependencies and license policy violations in PRs.
- **Caller permissions:** `contents: read`.
- **Inputs:** none.

### [Hermes-Review](.github/workflows/hermes-review.yml)
AI agent (a **local Hermes instance** on your self-hosted runner, sharing the
`review-bot` profile's persistent memory + skills) that acts on **`@hermes` mentions**
— posted to the PR or issue by a human. No internet exposure: the event reaches the
runner over its outbound connection and Hermes is called on localhost; the only
outbound call is the App-token-authed POST back to GitHub.
- **ON-DEMAND ONLY.** This workflow does *not* auto-review PRs — automatic/bulk reviews
  are driven separately by a Hermes **cronjob** (see *Out-of-Actions bot identity* below).
- **PR mention** → diff review (uses [`hermes-review-prompt.md`](hermes-review-prompt.md)).
- **Issue mention** → triage; may open a *draft* PR that **Closes #N** and is presented
  for human approval (uses [`hermes-triage-prompt.md`](hermes-triage-prompt.md)).
- **Caller permissions (required):** `contents: write`, `pull-requests: write`, `issues: write`, `checks: write`.
- **Secrets:** `HERMES_APP_ID`, `HERMES_APP_PRIVATE_KEY` (required) — pass via `secrets: inherit`.
- **Variables:** `HERMES_MODEL` (optional model override).
- **Inputs:** `hermes-profile` (default `review-bot`), `hermes-binary` (default `/home/bjoern/hermes-agent/venv/bin/hermes`), `hermes-model`, `max-turns` (default `30`), `prompt-path` (default `hermes-review-prompt.md`), `issue-prompt-path` (default `hermes-triage-prompt.md`).
- **Runner requirement:** a `self-hosted` runner with `hermes` on PATH; the `review-bot` profile must exist on it (create once with `hermes profile create review-bot --clone`).
- **Expects:** a GitHub App installed on the calling repo with `Contents:Write` (open PRs), `Pull requests:Read&write`, `Checks:Read&write`, `Issues:Write` (triage); subscribe to *Issue comment* and *Pull request review comment* events.

> **`@hermes` mention trigger:** comment `@hermes` on a PR (or reply to a review comment)
> for a diff review, or on an issue for triage. Match the mention string to your App slug
> (e.g. `@hermes-review`). The bot is guarded against re-triggering itself.

### Full caller example (on-demand, @hermes on PRs or issues)
```yaml
name: Hermes (on-demand)
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  hermes:
    # Respond to "@hermes" only (never let the bot re-trigger itself).
    if: >-
      github.actor != 'hermes-review[bot]' && (
        (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@hermes')) ||
        (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@hermes'))
      )
    permissions:
      contents: write
      pull-requests: write
      issues: write
      checks: write
    uses: s3ntin3l8/.github/.github/workflows/hermes-review.yml@main
    secrets: inherit
```

### Out-of-Actions bot identity (open PRs / triage from any Hermes session)
The reusable workflow mints the App token *inside* Actions. To let your local
`review-bot` profile, gateway, or a **cronjob** act as the App *outside* a workflow,
use [`scripts/app-token.sh`](scripts/app-token.sh). It signs a JWT with the App's
private key and exchanges it for an installation token, so any `gh` / REST call is
attributed to `<slug>[bot]` — not your account. Each invocation mints a fresh token
(1-hour max lifetime), so scheduled runs sidestep expiry entirely. Configure it once
in the `review-bot` profile's `.env` (`HERMES_APP_ID`, `HERMES_APP_PRIVATE_KEY`,
`HERMES_INSTALLATION_ID`) and call `export GITHUB_TOKEN="$(~/.hermes/scripts/app-token.sh)"`.

### Minimal caller example
```yaml
jobs:
  test-python:
    uses: s3ntin3l8/.github/.github/workflows/ci-python.yml@main
    with:
      coverage-source: 'my_pkg'   # omit if your package is named 'app'
    secrets: inherit
  test-node:
    uses: s3ntin3l8/.github/.github/workflows/ci-node.yml@main
    with:
      node-version: '24'
      working-directory: 'web'             # omit if package.json is at the repo root
      cache-dependency-path: 'web/package-lock.json'   # ditto
      typecheck-script: 'typecheck'        # opt into type checking
      test-script: 'test:coverage'         # opt into coverage + Codecov upload
      coverage-fail-under: '80'            # optional: fail below 80%
    secrets: inherit
  build-docker:
    needs: [test-python]
    permissions:                  # <-- required: ci-python needs none, docker-publish does
      contents: read
      packages: write
      id-token: write
    uses: s3ntin3l8/.github/.github/workflows/docker-publish.yml@main
    with:
      image-name: 'owner/repo'
    secrets: inherit
```

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

### [Node Blueprints](blueprints/node/)
- [Makefile](blueprints/node/Makefile) - Standard Node.js dev environment setup (install, dev, test, lint, typecheck, build, clean).
- [pre-commit.yaml](blueprints/node/pre-commit.yaml) - Standard Node.js/TypeScript pre-commit hooks (eslint, typecheck, vitest).

### [Go Blueprints](blueprints/go/)
- [Makefile](blueprints/go/Makefile) - Standard Go dev environment setup (lint, test, build, fmt, vet, tidy, vulncheck, clean).
- [pre-commit.yaml](blueprints/go/pre-commit.yaml) - Standard Go pre-commit hooks (gofmt, go vet, go mod tidy, go test, govulncheck).

## 🛡️ Templates
- [dependabot.yml](dependabot.yml) - Recommended configuration for weekly dependency updates.
