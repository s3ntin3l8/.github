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

### [Docker-Publish](.github/workflows/docker-publish.yml)
Multi-arch builds (amd64/arm64), GHCR push, and Cosign signing.
- **Caller permissions (required):** `contents: read`, `packages: write`, `id-token: write`.
- **Secrets:** `REGISTRY_USERNAME`/`REGISTRY_TOKEN` (optional; falls back to `GITHUB_TOKEN`) — pass via `secrets: inherit`.
- **Inputs:** `image-name` (required), `push-edge`, `push-release`, `release-tag`, `platforms`.

### [CodeQL](.github/workflows/codeql.yml)
Advanced semantic security scanning. Code scanning is free on public repos; private repos need GitHub Advanced Security.
- **Caller permissions (required):** `actions: read`, `contents: read`, `security-events: write`.
