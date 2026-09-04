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
- **Inputs:** `go-version` (default empty — override the version, e.g. `'1.23'`), `go-version-file` (default `go.mod` — derives the version when `go-version` is empty), `coverage-fail-under` (default `0` = disabled), `govulncheck-ignore` (default empty — comma-separated finding IDs, e.g. `'GO-2026-5932'`, to suppress; use only for individually reviewed findings with no available fix, and drop the ID once one exists).
- **Pre-build hook:** if a `.github/ci-prebuild.sh` exists in the repo, it runs before build (e.g. to stub `//go:embed` assets). Keep that logic in the script — there is no command-string input.
- **Expects:** a `go.mod` at the repo root (or override `go-version-file`).

### [CI-Tauri](.github/workflows/ci-tauri.yml)
`cargo fmt --check`, `cargo clippy`, `cargo test`, optional coverage via `cargo-llvm-cov` + Codecov, `cargo audit`, plus a separate 3-OS build-verification matrix (Tauri, unlike Go, cannot cross-compile a GUI app from one host — WebView2/WKWebView/webkit2gtk are genuinely per-platform).
- **Caller permissions:** none beyond the default `contents: read`.
- **Secrets:** `CODECOV_TOKEN` (optional) — pass via `secrets: inherit`.
- **No CodeQL coverage available.** CodeQL has no Rust language support at all (Go, Python, JS/TS, C/C++, C#, Java/Kotlin, Swift — not Rust). `cargo audit` (RustSec advisory scanning, built into `lint-and-test`) is the closest available substitute — it is not the same kind of coverage as CodeQL's semantic analysis, and a caller should not expect one. It also runs with `cargo-audit`'s own default severity policy (fails only on advisories classified `Vulnerability`, not `Warning`/unmaintained/unsound) rather than `--deny warnings` — a real Tauri v2 Linux build prints several Warning-level findings out of the box, deep in Tauri's own webkit2gtk bindings and outside a caller's control. GitHub's Dependabot alerts don't draw that same distinction, so a green `cargo audit` here doesn't mean zero Dependabot alerts.
- **Inputs:** `rust-version` (default `''` = latest stable), `working-directory` (default `src-tauri` — where `Cargo.toml` lives), `frontend-build` (default `true` — npm-builds a frontend before compiling Rust; required whenever `tauri::generate_context!()` embeds a real `frontendDist`, since that macro reads it at compile time), `node-version` (default `22`), `build-script` (default `build`), `clippy-args` (default `-- -D warnings`), **`coverage`** (default `false` — generates coverage via `cargo-llvm-cov` and uploads to Codecov; kept as its own switch, separate from the threshold below, since re-running the suite under instrumentation is a real extra cost unlike Go's free `-coverprofile`), `coverage-fail-under` (default `0` = report-only, no gate; only enforced when `coverage: true`), `matrix-os` (default `'["ubuntu-latest","windows-latest","macos-latest"]'` — narrow this if a caller only targets a subset of platforms).
- **Expects:** a Tauri v2 project with `Cargo.toml` under `working-directory` and (unless `frontend-build: false`) a `package-lock.json` at the repo root (uses `npm ci`).
- **The `build` job is a compile-verification matrix, not a release-artifact build** — no bundling, no installers. That belongs in each caller's own hand-rolled release job (see `build-helper-exe`/`build-helper-pkg` in `mullion-session-manager`'s `release-please.yml` for the established shape), same split `ci-node`/`ci-go` already draw between PR-gate CI and release-time artifact building.

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
AI agent that acts on **`@s3ntin3l8-hermes` mentions** posted to a PR or issue by a human.
The runner container does **not** run Hermes; it forwards the request to the **Hermes API
server on `hermes-01`** (`192.168.2.6:8643`, the `review-bot` profile) over the LAN. The
agent runs there — full tools, memory, skills — and **posts the review/comment back to
GitHub itself** using a GitHub App token it mints via `app-token.sh`. This keeps runner
containers lightweight (no hermes venv) while preserving the trigger-agnostic,
centralized-prompt, reusable design. See [`s3ntin3l8/.github` #18](https://github.com/s3ntin3l8/.github/pull/18).
- **ON-DEMAND ONLY.** This workflow does *not* auto-review PRs — automatic/bulk reviews
  are driven separately by a Hermes **cronjob** (see *Out-of-Actions bot identity* below).
- **PR mention** → diff review (uses [`hermes-review-prompt.md`](hermes-review-prompt.md)).
- **Issue mention** → triage; may open a *draft* PR that **Closes #N** and is presented
  for human approval (uses [`hermes-triage-prompt.md`](hermes-triage-prompt.md)).
- **Caller permissions (required):** `contents: write`, `pull-requests: write`, `issues: write`, `checks: write`.
- **Secrets:** `HERMES_APP_ID`, `HERMES_APP_PRIVATE_KEY` (used by the runner to resolve the PR/issue for routing), and `HERMES_API_KEY` (bearer key for the hermes-01 API server) — pass via `secrets: inherit`.
- **Variables:** `HERMES_MODEL` (optional model override).
- **Inputs:** `hermes-api-url` (default `http://192.168.2.6:8643`), `hermes-api-model` (default `hermes-agent`), `mention-trigger` (default `hermes`), `hermes-model`, `max-turns` (default `30`), `prompt-path` (default `hermes-review-prompt.md`), `issue-prompt-path` (default `hermes-triage-prompt.md`).
- **Runner requirement:** a `self-hosted` runner with `gh`, `curl`, and `python3` on PATH (no hermes install needed).
- **hermes-01 requirement:** the `review-bot` profile API server must be running and reachable from the runner — started with `hermes -p review-bot gateway`, with `API_SERVER_HOST` bound to the LAN interface (not `127.0.0.1`), `API_SERVER_PORT` set, and `API_SERVER_KEY` configured (that's `HERMES_API_KEY`).
- **Expects:** a GitHub App installed on the calling repo with `Contents:Write` (open PRs), `Pull requests:Read&write`, `Checks:Read&write`, `Issues:Write` (triage). Triggering is **Actions-driven** (the *calling* repo defines `on: issue_comment` only — see the example). Do **not** subscribe to `pull_request_review_comment` / `pull_request_review`: a submitted review fires those events and review bodies routinely contain the `@<slug>` string, which re-triggers this workflow with no human summon (the Claude→Hermes cascade on s3ntin3l8/.github#527). `issue_comment` alone covers both PR-conversation and issue mentions.

> **`@<slug>` mention trigger:** comment `@s3ntin3l8-hermes` on a PR (or reply to a review
> comment) for a diff review, or on an issue for triage. The mention string is set via the
> `mention-trigger` input (defaults to `hermes`; set it to your App slug, e.g.
> `s3ntin3l8-hermes`). The bot is guarded against re-triggering itself.

### Full caller example (on-demand, "@<slug>" mention on PRs or issues)
```yaml
|name: Hermes (on-demand)
|on:
|  issue_comment:
|    types: [created]
|  # NOTE: do NOT add pull_request_review_comment here — a submitted review
|  # fires that event, and review bodies can contain "@<slug>", re-triggering
|  # this workflow with no human summon (see .github#527).
|
|jobs:
|  hermes:
|    # Only fire for comment events from a human (the bot never re-triggers itself).
|    # The actual "@<slug>" mention check is done inside the reusable workflow via the
|    # `mention-trigger` input, so the slug lives in exactly one place.
|    if: github.actor != 's3ntin3l8-hermes[bot]'
|    permissions:
|      contents: write
|      pull-requests: write
|      issues: write
|      checks: write
|    uses: s3ntin3l8/.github/.github/workflows/hermes-review.yml@main
|    with:
|      mention-trigger: s3ntin3l8-hermes   # your GitHub App slug
|    secrets: inherit
|```

### Full caller example (auto — review every new PR, no mention needed)
```yaml
|name: Hermes (auto review)
|on:
|  pull_request:
|    types: [opened, synchronize]
|    # `opened` => review once when a PR is opened. Add `synchronize` to also
|    # re-review on every push to the PR (the reusable workflow's "already reviewed"
|    # guard skips repeats, so it effectively re-reviews only after you dismiss the
|    # prior review). Add `if: github.event.pull_request.draft == false` to skip drafts.
|
|jobs:
|  hermes:
|    # The bot never re-triggers itself (its own review/push won't restart this).
|    if: github.actor != 's3ntin3l8-hermes[bot]'
|    permissions:
|      contents: write
|      pull-requests: write
|      issues: write
|      checks: write
|    uses: s3ntin3l8/.github/.github/workflows/hermes-review.yml@main
|    with:
|      mode: auto                      # <-- skips the mention check, reviews on trigger
|      mention-trigger: s3ntin3l8-hermes
|    secrets: inherit
|```

### Out-of-Actions bot identity (open PRs / triage from any Hermes session)
The reusable workflow mints the App token *inside* Actions. To let your local
`review-bot` profile, gateway, or a **cronjob** act as the App *outside* a workflow,
use [`scripts/app-token.sh`](scripts/app-token.sh). It signs a JWT with the App's
private key and exchanges it for an installation token, so any `gh` / REST call is
attributed to `<slug>[bot]` — not your account. Each invocation mints a fresh token
(1-hour max lifetime), so scheduled runs sidestep expiry entirely. Configure it once
in the `review-bot` profile's `.env` (`HERMES_APP_ID`, `HERMES_APP_PRIVATE_KEY`,
`HERMES_INSTALLATION_ID`) and call `export GITHUB_TOKEN="$(~/.h....sh)"`.
**This is a required setup step — the App credentials are NOT in the profile by default;**
you must add `HERMES_APP_ID` + `HERMES_APP_PRIVATE_KEY` (and `HERMES_INSTALLATION_ID` if you
installed the App on more than one account/org) to `~/.hermes/profiles/review-bot/.env` on
`hermes-01`, plus copy `scripts/app-token.sh` to `~/.h....sh`.

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
- [pre-commit.yaml](blueprints/go/pre-commit.yaml) - Standard Go pre-commit hooks (gofmt, go vet, go mod tidy, go test, govulncheck, golangci-lint via local `go install`).

### [Tauri Blueprints](blueprints/tauri/)
- [Makefile](blueprints/tauri/Makefile) - Standard Tauri v2 dev environment setup (lint, fmt, test, build, dev, vulncheck, clean).
- [pre-commit.yaml](blueprints/tauri/pre-commit.yaml) - Standard Tauri v2 pre-commit hooks (cargo fmt, cargo clippy, cargo test). See [`tauri-app-template`](https://github.com/s3ntin3l8/tauri-app-template) for a full working example these are extracted from.

## 🛡️ Templates
- [dependabot.yml](dependabot.yml) - Recommended configuration for weekly dependency updates.
