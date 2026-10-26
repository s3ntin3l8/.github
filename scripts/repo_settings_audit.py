#!/usr/bin/env python3
"""Audit repository settings that the workflows' security model relies on.

Run by .github/workflows/repo-settings-audit.yml with a token that has
Administration: read, Metadata: read and Secret scanning alerts: read.
Locally: GH_TOKEN=... OWNER=s3ntin3l8 python3 scripts/repo_settings_audit.py

Each check takes the raw API payloads for one repo and returns a list of problem
strings (empty = pass). Intentional differences go in .github/repo-settings-audit.json
under "exceptions", keyed by check id then repo name, with a reason.
"""

import json
import os
import subprocess
import sys

CONFIG = os.path.join(os.path.dirname(__file__), "..", ".github", "repo-settings-audit.json")


def check_fork_pr_approval(d):
    p = d["fork_approval"]
    if p == "all_external_contributors":
        return []
    return [f"fork PR approval is {p!r}, want 'all_external_contributors'"]


def check_workflow_permissions(d):
    w = d["workflow"]
    if w is None:
        return ["workflow permissions unreadable"]
    if w.get("default_workflow_permissions") == "read":
        return []
    return [f"default workflow token is {w.get('default_workflow_permissions')!r}, want 'read'"]


def check_branch_protection(d):
    """Default branch needs required status checks and conversation resolution,
    via classic protection or an active ruleset."""
    prot, rules = d["protection"], d["rules"]
    if prot not in (None, "none") and prot is not False:
        checks = (prot.get("required_status_checks") or {}).get("contexts") or []
        checks = checks or (prot.get("required_status_checks") or {}).get("checks") or []
        conv = (prot.get("required_conversation_resolution") or {}).get("enabled")
        problems = []
        if not checks:
            problems.append("no required status checks")
        if not conv:
            problems.append("conversation resolution not required")
        return [f"default branch protection: {', '.join(problems)}"] if problems else []
    if rules:
        types = {r.get("type") for r in rules}
        pr = [r for r in rules if r.get("type") == "pull_request"]
        problems = []
        if "required_status_checks" not in types:
            problems.append("no required status checks")
        if not any((r.get("parameters") or {}).get("required_review_thread_resolution") for r in pr):
            problems.append("conversation resolution not required")
        return [f"default branch ruleset: {', '.join(problems)}"] if problems else []
    return ["default branch is not protected (no protection, no ruleset)"]


def check_secret_scanning(d):
    sa = d["repo"].get("security_and_analysis")
    if not sa:
        return ["security_and_analysis not visible (token lacks scope?)"]
    problems = []
    if (sa.get("secret_scanning") or {}).get("status") != "enabled":
        problems.append("secret scanning off")
    if (sa.get("secret_scanning_push_protection") or {}).get("status") != "enabled":
        problems.append("push protection off")
    return problems


def check_merge_methods(d):
    r = d["repo"]
    keys = ("allow_squash_merge", "allow_merge_commit", "allow_rebase_merge", "delete_branch_on_merge")
    if any(r.get(k) is None for k in keys):
        return ["merge settings not visible to the token (REST fields absent)"]
    problems = []
    if not r["allow_squash_merge"]:
        problems.append("squash merge disabled")
    if r["allow_merge_commit"]:
        problems.append("merge commits allowed")
    if r["allow_rebase_merge"]:
        problems.append("rebase merge allowed")
    if not r["delete_branch_on_merge"]:
        problems.append("branch not auto-deleted on merge")
    return problems


CHECKS = {
    "fork-pr-approval": check_fork_pr_approval,
    "workflow-permissions": check_workflow_permissions,
    "branch-protection": check_branch_protection,
    "secret-scanning": check_secret_scanning,
    "merge-methods": check_merge_methods,
}
# Forks mirror an upstream whose settings are not ours to choose.
SKIP_FORKS = {"branch-protection", "merge-methods"}


MERGE_KEYS = ("allow_squash_merge", "allow_merge_commit", "allow_rebase_merge", "delete_branch_on_merge")


def gh(path):
    """GET a gh api path; return parsed JSON, or None on a 403/404-style error."""
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        if "HTTP 404" in r.stderr or "HTTP 403" in r.stderr:
            return None
        raise RuntimeError(f"gh api {path}: {r.stderr.strip()}")
    return json.loads(r.stdout)


def fetch(owner, name):
    base = f"repos/{owner}/{name}"
    repo = gh(base) or {}
    if any(repo.get(k) is None for k in MERGE_KEYS):
        # Some tokens get these fields only over GraphQL.
        q = ("query($o:String!,$n:String!){repository(owner:$o,name:$n){"
             "squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed deleteBranchOnMerge}}")
        r = subprocess.run(["gh", "api", "graphql", "-f", f"query={q}", "-f", f"o={owner}", "-f", f"n={name}"],
                           capture_output=True, text=True)
        g = (json.loads(r.stdout).get("data") or {}).get("repository") if r.returncode == 0 else None
        if g:
            repo.update(allow_squash_merge=g["squashMergeAllowed"], allow_merge_commit=g["mergeCommitAllowed"],
                        allow_rebase_merge=g["rebaseMergeAllowed"], delete_branch_on_merge=g["deleteBranchOnMerge"])
    branch = repo.get("default_branch", "main")
    prot = gh(f"{base}/branches/{branch}/protection")
    fa = gh(f"{base}/actions/permissions/fork-pr-contributor-approval")
    return {
        "repo": repo,
        "fork_approval": (fa or {}).get("approval_policy", "<unreadable>"),
        "workflow": gh(f"{base}/actions/permissions/workflow"),
        "protection": prot if prot is not None else "none",
        "rules": gh(f"{base}/rules/branches/{branch}") or [],
    }


def audit(data, exceptions, is_fork):
    """Return {check: [problems]} for failures not covered by an exception."""
    out = {}
    for cid, fn in CHECKS.items():
        if is_fork and cid in SKIP_FORKS:
            continue
        problems = fn(data)
        if problems and cid not in exceptions:
            out[cid] = problems
    return out


def main():
    owner = os.environ["OWNER"]
    if not os.environ.get("GH_TOKEN"):
        print("::error::REPO_SETTINGS_TOKEN is not set; the audit cannot run.")
        return 1
    with open(CONFIG) as f:
        cfg = json.load(f).get("exceptions", {})
    r = subprocess.run(
        ["gh", "repo", "list", owner, "--visibility", "public", "--no-archived",
         "--limit", "1000", "--json", "name,isFork"],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not json.loads(r.stdout):
        print(f"::error::could not list public repositories for {owner}: {r.stderr.strip()}")
        return 1
    failures = 0
    lines = ["| repo | check | problem |", "|---|---|---|"]
    for repo in sorted(json.loads(r.stdout), key=lambda x: x["name"]):
        name = repo["name"]
        exc = {cid for cid, repos in cfg.items() if name in repos}
        res = audit(fetch(owner, name), exc, repo["isFork"])
        if not res:
            print(f"ok    {name}")
        for cid, problems in res.items():
            failures += 1
            msg = "; ".join(problems)
            print(f"::error title={cid}::{owner}/{name}: {msg}")
            lines.append(f"| {name} | {cid} | {msg} |")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and failures:
        with open(summary, "a") as f:
            f.write("\n".join(lines) + "\n")
    print(f"{failures} finding(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
