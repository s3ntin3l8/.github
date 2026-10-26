# Security Policy

## Supported Versions

Currently, only the latest release of each repository is supported with security updates.

## Reporting a Vulnerability

I take the security of my projects seriously. If you find a security vulnerability, please do NOT open a public issue. Instead, report it privately.

**Contact:** [s3ntin3l8 on GitHub](https://github.com/s3ntin3l8)

I will acknowledge your report within 48 hours and provide a timeline for a fix within 7 days. Once a fix is verified, a new version will be released, and credit will be given in the changelog if desired.

## Repository settings (maintainers)

Public repositories that run workflows on a self-hosted runner must keep **Settings -> Actions -> General -> "Fork pull request workflows from outside collaborators" -> "Require approval for all outside collaborators"** enabled (API value `all_external_contributors`). For a `pull_request` event GitHub runs the workflow file from the PR's own head, so an in-file guard cannot keep a fork PR off the runner; this setting is the control. The same weekly [Repo settings audit](.github/workflows/repo-settings-audit.yml) also checks a read-only default workflow token (Actions may still approve PRs), a protected default branch (required status checks and conversation resolution), secret scanning with push protection, and squash-only merges with branch auto-delete, and fails when any public repository drifts. Intentional differences are listed with a reason in [`.github/repo-settings-audit.json`](.github/repo-settings-audit.json). Private repositories do not expose this setting.
