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
- **Secrets:** `CODECOV_TOKEN` (optional) — pass via `secrets: inherit`. `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` (optional) authenticate Docker Hub pulls (e.g. testcontainers); without them pulls are anonymous and may hit the rate limit.
- **Inputs:** `python-version`, `coverage-fail-under`, **`coverage-source`** (set this if your package isn't named `app`).
  - **`test-parallel`** (default `''` = serial; e.g. `4`) — run pytest with that many `pytest-xdist` workers, using `--dist loadfile` so each test module stays in one worker. The caller must have `pytest-xdist` installed.
  - **`detect-secrets`** (default `true`) — set `false` when the caller already runs its own secrets gate over the same tree (e.g. a Node job in the same workflow).
  - **`detect-secrets-scope`** (default `all`) — `changed` scans only files that differ from the base commit (plus every file the *previous* baseline listed, so removing a baseline entry is still caught). It deepens the checkout fetch. Falls back to a whole-tree scan when no base commit is available.
- **Test isolation:** pytest runs with a throwaway `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and `XDG_*` under `$RUNNER_TEMP/test-isolation`, and `--basetemp` there, so a test that reads the environment cannot touch the runner's real files. That root is exported as **`TEST_ISOLATION_ROOT`**: a repo's `conftest` can use it to give each xdist worker its own config root (otherwise workers share one database file). This applies to every caller and is not opt-in; a suite that depends on files in the real `~` will not find them.
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
  - **`shard-build-script`** (default `''` = use `build-script`) — overrides `build-script` for the `test-shard` jobs **only**. Set it to `''` to skip the build step in every shard: a shard job runs its tests against the SOURCE tree, so a caller whose tests import `src/` directly pays for a full `npm run build` per shard for nothing. `lint-and-test` still builds once, so a broken build is still caught.
  - **`build-env`** (default `''`; extra env for the build step as `KEY=VALUE` lines, e.g. `NEXT_TELEMETRY_DISABLED=1`)
  - **`typecheck-script`** (default `''` = skip; set to `typecheck` to run type checking between lint and test)
  - **`test-script`** (default `test`; set to `test:coverage` to enable coverage upload and threshold enforcement)
  - **`coverage-fail-under`** (default `0` = disabled; set e.g. `80` to require ≥80% line coverage)
  - **`test-shards`** (default `1` = disabled; set e.g. `4` to split tests across a 4-way matrix via `vitest`/`jest` `--shard` syntax). `1` is a no-op — the single `lint-and-test` job runs exactly as before, so no existing caller is affected unless it opts in. Above `1`, tests move into a `test-shard` matrix (parallel with `lint-and-test`, so lint/typecheck/build no longer wait on tests) plus a `test-merge` job that combines every shard's coverage and enforces `coverage-fail-under` **once, over the union** — never per-shard. Requires the coverage reporter list to also include istanbul's `json` reporter (vitest: add `"json"` to `coverage.reporter`; jest: add `"json"` to `coverageReporters`) alongside `json-summary`, and a test script that accepts pass-through CLI args.
  - **`test-shard-matrix`** (default `''` = disabled) — the shard matrix as a JSON array of shard indices (e.g. `'[1,2,3,4]'`), consumed directly by the `test-shard` matrix. Unlike `test-shards`, this needs no `shard-plan` job to compute the array — GitHub cannot build a numeric range into a matrix, which is why the count-based input has to spend a whole runner job on `jq`. When set, it wins over `test-shards` and the `shard-plan` job is skipped; the shard COUNT is still taken from the matrix's own length, so `test-shards` only has to be `> 1` to enable the sharded path.
  - **`artifact-prefix`** (default `''`) — namespaces this caller's shard coverage artifacts: `coverage-shard<prefix>-<n>`, downloaded by `test-merge` as `coverage-shard<prefix>-*`. **Set it when one workflow run calls this reusable workflow more than once with sharding on.** Artifact names are scoped to the RUN, not to the caller, so two sharded callers both uploading `coverage-shard-1` collide — and `test-merge` then downloads the *other* caller's map, silently merging two workspaces' coverage into one report and enforcing the threshold against a number that means nothing. Give each sharded caller its own prefix (`'-backend'`, `'-frontend'`, ...). Empty keeps today's names exactly, which is right for the common case of a single sharded caller per run.
  - **`detect-secrets`** (default `true`) — set `false` when the caller already runs a secrets gate over the same tree (e.g. a Python job in the same workflow), so the repository is not scanned twice.
  - **`detect-secrets-scope`** (default `all`) — `changed` scans only files that differ from the base commit (plus every file the previous baseline listed). It deepens the checkout fetch and falls back to a whole-tree scan when no base commit is available.
  - **`test-pool`** (default `''` = Vitest's default) — Vitest worker pool, e.g. `vmThreads`, which reuses one jsdom environment per worker instead of building one per test file.
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

### [CI-Mobile](.github/workflows/ci-mobile.yml)
Native Android and iOS companion application CI with `gomobile` support. Runs JDK 21, `setup-gradle@v6`, Android SDK/NDK, Go module & build caching, Xcode `DerivedData` caching, and simulator-only iOS testing on PRs with full multi-slice builds on `main` merges.
- **Caller permissions:** none beyond the default `contents: read`.
- **Inputs:** `java-version` (default `'21'`), `android-ndk-version` (default `'25.1.8937393'`), `go-mod-dir` (default `'core'`), `xcode-version`, `ios-destination`, `ios-scheme`, `ios-project`, `ios-slices` (default `'auto'`: all slices on `main`, sim-only on PRs), `upload-aar` (default `false`).
- **Expects:** `./scripts/build-mobile.sh` and native `android`/`ios` module layout.

### [CI-Tauri](.github/workflows/ci-tauri.yml)
`cargo fmt --check`, `cargo clippy`, `cargo test`, optional coverage via `cargo-llvm-cov` + Codecov, `cargo audit`, plus a separate 3-OS build-verification matrix (Tauri, unlike Go, cannot cross-compile a GUI app from one host — WebView2/WKWebView/webkit2gtk are genuinely per-platform).
- **Caller permissions:** none beyond the default `contents: read`.
- **Secrets:** `CODECOV_TOKEN` (optional) — pass via `secrets: inherit`.
- **No CodeQL coverage available.** CodeQL has no Rust language support at all (Go, Python, JS/TS, C/C++, C#, Java/Kotlin, Swift — not Rust). `cargo audit` (RustSec advisory scanning, built into `lint-and-test`) is the closest available substitute — it is not the same kind of coverage as CodeQL's semantic analysis, and a caller should not expect one. It also runs with `cargo-audit`'s own default severity policy (fails only on advisories classified `Vulnerability`, not `Warning`/unmaintained/unsound) rather than `--deny warnings` — a real Tauri v2 Linux build prints several Warning-level findings out of the box, deep in Tauri's own webkit2gtk bindings and outside a caller's control. GitHub's Dependabot alerts don't draw that same distinction, so a green `cargo audit` here doesn't mean zero Dependabot alerts.
- **Inputs:** `rust-version` (default `''` = latest stable), `working-directory` (default `src-tauri` — where `Cargo.toml` lives), `frontend-build` (default `true` — npm-builds a frontend before compiling Rust; required whenever `tauri::generate_context!()` embeds a real `frontendDist`, since that macro reads it at compile time), `node-version` (default `22`), `build-script` (default `build`), `clippy-args` (default `-- -D warnings`), **`coverage`** (default `false` — generates coverage via `cargo-llvm-cov` and uploads to Codecov; kept as its own switch, separate from the threshold below, since re-running the suite under instrumentation is a real extra cost unlike Go's free `-coverprofile`), `coverage-fail-under` (default `0` = report-only, no gate; only enforced when `coverage: true`), `matrix-os` (default `'["ubuntu-latest","windows-latest","macos-latest"]'` — narrow this if a caller only targets a subset of platforms).
- **Lockfile is enforced.** `clippy`, `test`, `cargo-llvm-cov` and the release build run with `--locked`, so a `Cargo.lock` that is out of sync with the manifests fails CI instead of being silently re-resolved. Callers must commit an up-to-date lockfile.
- **Expects:** a Tauri v2 project with `Cargo.toml` under `working-directory` and (unless `frontend-build: false`) a `package-lock.json` at the repo root (uses `npm ci`).
- **The `build` job is a compile-verification matrix, not a release-artifact build** — no bundling, no installers. That belongs in each caller's own hand-rolled release job (see `build-helper-exe`/`build-helper-pkg` in `mullion-session-manager`'s `release-please.yml` for the established shape), same split `ci-node`/`ci-go` already draw between PR-gate CI and release-time artifact building.

### [Docker-Publish](.github/workflows/docker-publish.yml)
Multi-arch builds (amd64/arm64), GHCR push, and Cosign signing.
- **Caller permissions (required):** `contents: read`, `packages: write`, `id-token: write`.
- **Secrets:** `REGISTRY_USERNAME`/`REGISTRY_TOKEN` (optional; falls back to `GITHUB_TOKEN`) — pass via `secrets: inherit`. `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` (optional) authenticate base-image pulls from Docker Hub; without them pulls are anonymous and may hit the rate limit (429). Use a read-only ("Public Repo Read-only") access token.
- **Inputs:** `image-name` (required), `push-edge`, `push-release`, `release-tag`, `platforms`, `dockerfile`, `build-args`.
- **Built commit:** the build always receives `COMMIT_SHA=<the commit it checked out>` (the tag's commit for a release build). Use that for a build stamp instead of `${{ github.sha }}`, which is the commit that triggered the *caller* and differs on a manual dispatch or a rebuild of an older tag. Declare `ARG COMMIT_SHA` where you consume it.
- **Build-arg check:** each `build-args` key is checked against `dockerfile`. The build **fails** when the final stage references `$X` without its own `ARG X` (the value would be silently empty) and **warns** when `X` appears nowhere in the Dockerfile. An arg consumed only in a builder stage (baked into a bundle) is fine.

### [CodeQL](.github/workflows/codeql.yml)
Advanced semantic security scanning. Code scanning is free on public repos; private repos need GitHub Advanced Security.
- **Caller permissions (required):** `actions: read`, `contents: read`, `security-events: write`.
- **Inputs:** `languages` — comma-separated (`"python, javascript-typescript"`), a JSON array, or the legacy pre-quoted form.

### [Release-Please](.github/workflows/release-please.yml)
Automated versioning and changelogs.
- **Caller permissions (required):** `contents: write`, `pull-requests: write`.
- **Expects:** `release-please-config.json` and `.release-please-manifest.json` in the repo root.
- **Optional secrets `RELEASE_APP_ID` / `RELEASE_APP_PRIVATE_KEY`** (opt-in, pass via `secrets: inherit`): a dedicated GitHub App (Contents, Pull requests, Workflows: read & write) that creates the GitHub Release + tag. Without it, `GITHUB_TOKEN` can only tag the default branch's HEAD, so one failed release-PR-merge run wedges every later run on a 403 until an operator runs `gh release create` by hand. With it, the release runs as the App while the release PR is still opened by `github-actions[bot]` (so Hermes auto-review and PR CI are unaffected). Note an App-created release fires `on: release` / `on: push: tags`, which a `GITHUB_TOKEN` one does not. No change to the caller `permissions:` above.

### [Cleanup-GHCR](.github/workflows/ghcr-cleanup.yml)
Deletes untagged container versions from GHCR on a schedule.
- **Caller permissions (required):** `packages: write`.
- **Inputs:** `package-name` (required), `package-type`, `min-versions-to-keep`.

### [Dependency Review](.github/workflows/dependency-review.yml)
Checks for vulnerable dependencies and license policy violations in PRs.
- **Caller permissions:** `contents: read`.
- **Inputs:** none.

### [Claude-Code](.github/workflows/claude-code.yml)
On-demand `@claude` assistant for issues and PRs (review + implement), shared so the gate and prompt cannot drift between repos.
- **Caller permissions (required):** `contents: read`, `pull-requests: write`, `issues: read`, `id-token: write`, `actions: read`.
- **Secrets:** `CLAUDE_CODE_OAUTH_TOKEN` (required).
- **Gate:** a `gate` job first applies the trusted-commenter check (`MEMBER`/`OWNER`/`COLLABORATOR`), then requires the comment to *address* the bot: a line starting with `@claude`. A comment that only mentions it mid-sentence is skipped with a notice, so a human's status report cannot start a second, unintended review run (pocket-portfolio-tracker#567). Input `mention-match` (default `line-start`; `anywhere` restores the old substring match).
- **Inputs:** `setup-node`, `node-version`, `build-tools`, `mention-match`.

### [Hermes-Review](.github/workflows/hermes-review.yml)
AI agent that acts on **`@s3ntin3l8-hermes` mentions** posted to a PR or issue by a human.
The runner container does **not** run Hermes; it forwards the request to the **Hermes API
server on `hermes-01`** (`192.168.2.6:8642/p/review-bot`, the `review-bot` profile) over the LAN. The
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
- **Secrets:** `HERMES_APP_ID`, `HERMES_APP_PRIVATE_KEY` (used by the runner to resolve the PR/issue for routing), and `HERMES_API_KEY` (bearer key for the hermes-01 API server) — pass via `secrets: inherit`. To auto-review **dependabot** PRs (the default), mirror the same three secrets into the repo's **Settings → Secrets and variables → Dependabot**: a dependabot-authored `pull_request` run sees only those. Without them the run skips green with a notice rather than failing.
- **Auto-review skips:** bot authors `s3ntin3l8-hermes[bot]` (self) and `github-actions[bot]` (release-please), fork PRs, and `mullion/task-*` branches. `dependabot[bot]` is reviewed — a bump can change a runtime tool version without saying so (runway-ai-usage-tracker#627).
- **Variables:** `HERMES_MODEL` (optional model override).
- **Inputs:** `hermes-api-url` (default `http://192.168.2.6:8642/p/review-bot`), `hermes-api-model` (default `hermes-agent`), `mention-trigger` (default `hermes`), `mention-match` (default `line-start`), `hermes-react` (default `true`), `hermes-model`, `max-turns` (default `30`), `prompt-path` (default `hermes-review-prompt.md`), `issue-prompt-path` (default `hermes-triage-prompt.md`).
- **Addressing the bot (`mention-match`, default `line-start`):** an on-demand comment only starts a run if some line **starts with** `@<mention-trigger>` (after whitespace). A status report that merely names the bot ("Addressed the review from @s3ntin3l8-hermes in abc123") does not; neither does a mention in a quoted (`>`) line or a fenced code block, or a longer handle such as `@<slug>-foo`. Matching is case-insensitive. It filters on how the bot is named, never on whether the head was already reviewed, so a deliberate re-review is still just another `@<slug> Review` comment. `anywhere` restores the old substring match. Same rule as `claude-code.yml`.
- **👀 acknowledgement (`hermes-react`, default `true`, needs `hermes-use-runs: true`):** once a review has *actually been dispatched* — a **new** Hermes run was accepted — the workflow reacts 👀 to the comment that asked for it (issue/PR comment, review comment, or issue body) — or, for the auto-review on PR open, to the PR body itself, the same signal `@claude` gives. It never reacts on a skip, a replay of an existing run, an already-running review, a refusal (HTTP 409/429/401) or any failure, so an eyes reaction means "this request started a review"; no reaction on a request means it did not. The legacy fire-and-forget path cannot tell a dispatch from a silent no-op, so it never reacts. The reaction uses its own short-lived App token (Issues and Pull requests: write) and is best-effort: if the App lacks the permission or the call fails, a warning is logged and the review is unaffected. Set `hermes-react: false` to turn it off.
- **Opt-in Runs API dispatch (`hermes-use-runs`, default `false`):** the default is a fire-and-forget `POST /v1/chat/completions` that cannot tell a long healthy run from a silent failure, so the check is green once the POST is accepted. With `hermes-use-runs: true` the workflow uses `POST /v1/runs`, polls `GET /v1/runs/{id}` until the run is terminal, **fails the check if it ends `failed`/`cancelled`/`interrupted`** (or the API is lost/rejects the key), and writes the bot's reply to the job summary. A run still going after the 45-minute poll window (`HERMES_POLL_SECONDS`, default 2700, capped at 3000; the job timeout is 60 minutes) only warns and exits green — that is *not* a verdict on the review, which keeps running on hermes-01 — and its `Hermes review` marker check stays pending (not `neutral`) until the next round, or a status read, sees the run finished and closes it with the real outcome. The polling job holds its self-hosted runner for the length of the review, so give the repo a second runner before opting in (`count: 2` in `ansible/host_vars/gh-runner-01.yml`). Requires Hermes with the Runs API (check `GET /v1/capabilities` for `run_submission`/`run_status`).
- **One review in flight per pull request (`hermes-review-scope`, `hermes-review-ledger`):** the default (`delta` + `check-run`) keeps a pull request to a single review at a time, and makes each round small:
  - **Scope `delta`** — a follow-up round reviews only the commits since the last commit Hermes demonstrably reviewed (`<base>..<head>`), so a round is fast and focused on what changed. The first round of a PR is still a full review. The reviewer is told the exact commit to review, so a review cannot silently cover a newer head than the one requested. "Last reviewed commit" is read from the ledger (below), **not** from the review's `commit_id`: GitHub re-points an approval's `commit_id` at the PR's current head whenever the branch tip is rewritten (a force-push, "Update branch"), so it stops recording what was reviewed (s3ntin3l8/.github#129). The base is the commit of the newest ledger marker that ended `success` *and* has a landed Hermes review submitted at or after the run started. **The ledger is what makes this hold**, and it only exists with `hermes-use-runs: true` and `hermes-review-ledger: check-run` (the Runs API path writes the markers): on an `@mention`-only consumer (the default) there is none, and the rule is only the fallback below, which is a heuristic. The ledger is searched in the PR's **newest 50 commits**, so after a long history of pushes an old marker is out of reach and the round falls back. With no paired marker it falls back to the last review's `commit_id` only while that commit is not newer than the review, and otherwise reviews the whole diff. An explicit request is skipped ("nothing new to review") only when the head's **tree** equals the reviewed commit's tree, so a rebase that changes nothing is skipped and an "Update branch" merge is reviewed. To force another round on unchanged content, dismiss the review: `gh api -X PUT repos/<owner>/<repo>/pulls/<n>/reviews/<review id>/dismissals -f message=...`.
  - **Scope `full`** — every round re-reviews the whole pull request (the old behaviour).
  - **A delta excludes the base branch** — after "Update branch" the `<base>..<head>` range also holds every commit that landed on the base branch meanwhile. The reviewer is told to review only the PR's own commits in it (`git log -p --remerge-diff <base>..<head> ^origin/<base-branch>`), which also surfaces what the author resolved in the merge commit, including a conflict finished by taking one side wholesale. The idempotency key is unchanged (it still names `<base>..<head>`). Mullion's relay does not name a range to its reviewer at all, so this affects the workflow path only.
  - **Ledger `check-run`** — the workflow writes a check run named `Hermes review` on the reviewed head whose `external_id` is the Hermes run id. A later request finds it: if the same head is still being reviewed it is **skipped** (no second review is queued), and if the head moved on the stale run is **stopped** and the new head is reviewed instead. **Ledger `off`** dispatches every request.
  - The `Idempotency-Key` of a dispatched run is the review range (`hermes-review:<repo>#<n>@<base>..<head>`, with the repo name **lower-cased** — as is the session id — so a mixed-case repo name still matches the key Mullion's relay builds), so a second `@mention` on an unchanged head replays the run that is already there instead of queueing a second review of the same diff. Mullion's own relay builds the same key for the same range, so a review asked for through `mullion review` and one asked for with an `@mention` are the same request.
  - **Stuck sessions (Runs API):** if Hermes' session authority refuses a turn (HTTP 409 `admission_conflict`), the round is retried in a fresh session (`hermes-review-<owner>-<repo>-<pr>-<n>`) and told plainly that it has no memory of earlier rounds (it reads the PR's reviews instead). The session a round ran in is recorded in its in-flight marker (`session: <id>`), and the next round continues in it instead of starting from the stuck base id; only an id of exactly that shape for the same PR is honoured. A 409 that no marker or run status can explain **fails** the check (`review NOT dispatched`) rather than going green — after waiting up to 30 s for the marker (`HERMES_MARKER_WAIT_TRIES`, default 6, every `HERMES_MARKER_WAIT_INTERVAL`, default 5 s), because the other entry point writes its marker just after it dispatches and the two can race within the same second — and a completed run whose review already landed (a Hermes review submitted at or after its marker started) is not re-dispatched. Mullion's relay (0.3.43 and later) uses the same base session id, range key and marker (s3ntin3l8/mullion-session-manager#1757); its marker needs a GitHub **App** token with `Checks: write` (a user/OAuth token is refused), otherwise this workflow cannot see the relay's run.
  - All of this is what stops reviews from piling up: without it, every mention of a PR became another queued turn in that PR's Hermes session, each round inheriting the previous rounds' transcript, until the queue tripped Hermes' concurrent-run cap (HTTP 429) — which used to be reported as a successful relay.
- **Runner requirement:** a `self-hosted` runner with `gh`, `curl`, and `python3` on PATH (no hermes install needed).
- **hermes-01 requirement:** the `review-bot` profile API must be running and reachable from the runner — served natively by the multiplexed gateway (`/p/review-bot` on port 8642) with `API_SERVER_KEY` configured (`HERMES_API_KEY`). Port 8643 is kept as a compatibility forwarder.
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

### [Mobile Blueprints](blueprints/mobile/)
- [Makefile](blueprints/mobile/Makefile) - Standard Mobile (Android/iOS/Go) dev environment setup (lint, test, android, android-test, ios-test, mobile-build, clean).
- [pre-commit.yaml](blueprints/mobile/pre-commit.yaml) - Standard Mobile pre-commit hooks (gofmt, go vet, go mod tidy, detect-secrets). Generate initial baseline via `detect-secrets scan > .secrets.baseline`.

## 🛡️ Templates
- [dependabot.yml](dependabot.yml) - Recommended configuration for weekly dependency updates.

## License

Copyright (C) 2026 Björn Hansen

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See [LICENSE](LICENSE).
