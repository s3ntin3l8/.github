import unittest

import repo_settings_audit as a


def good():
    return {
        "repo": {
            "allow_squash_merge": True, "allow_merge_commit": False, "allow_rebase_merge": False,
            "delete_branch_on_merge": True,
            "security_and_analysis": {
                "secret_scanning": {"status": "enabled"},
                "secret_scanning_push_protection": {"status": "enabled"},
            },
        },
        "fork_approval": "all_external_contributors",
        "workflow": {"default_workflow_permissions": "read", "can_approve_pull_request_reviews": False},
        "protection": {"required_status_checks": {"contexts": ["ci"]},
                       "required_conversation_resolution": {"enabled": True}},
        "rules": [],
    }


class AuditTest(unittest.TestCase):
    def test_clean_repo_passes(self):
        self.assertEqual(a.audit(good(), set(), False), {})

    def test_each_drift_is_reported(self):
        d = good()
        d["fork_approval"] = "first_time_contributors"
        d["workflow"] = {"default_workflow_permissions": "write", "can_approve_pull_request_reviews": True}
        d["repo"]["allow_merge_commit"] = True
        d["repo"]["security_and_analysis"]["secret_scanning_push_protection"]["status"] = "disabled"
        self.assertEqual(set(a.audit(d, set(), False)), {
            "fork-pr-approval", "workflow-permissions",
            "merge-methods", "secret-scanning"})

    def test_exception_suppresses_only_its_check(self):
        d = good()
        d["workflow"]["default_workflow_permissions"] = "write"
        d["fork_approval"] = "first_time_contributors"
        self.assertEqual(set(a.audit(d, {"workflow-permissions"}, False)), {"fork-pr-approval"})

    def test_actions_approving_prs_is_allowed(self):
        d = good()
        d["workflow"]["can_approve_pull_request_reviews"] = True
        self.assertEqual(a.audit(d, set(), False), {})

    def test_unprotected_branch(self):
        d = good()
        d["protection"] = "none"
        self.assertIn("branch-protection", a.audit(d, set(), False))

    def test_ruleset_counts_only_with_checks_and_thread_resolution(self):
        d = good()
        d["protection"] = "none"
        d["rules"] = [{"type": "required_status_checks"},
                      {"type": "pull_request", "parameters": {"required_review_thread_resolution": True}}]
        self.assertEqual(a.audit(d, set(), False), {})
        d["rules"][1]["parameters"]["required_review_thread_resolution"] = False
        self.assertIn("branch-protection", a.audit(d, set(), False))

    def test_forks_skip_branch_and_merge_checks_but_not_fork_approval(self):
        d = good()
        d["protection"] = "none"
        d["repo"]["allow_merge_commit"] = True
        d["fork_approval"] = "first_time_contributors"
        self.assertEqual(set(a.audit(d, set(), True)), {"fork-pr-approval"})

    def test_unreadable_security_analysis_fails_loudly(self):
        d = good()
        d["repo"]["security_and_analysis"] = None
        self.assertIn("secret-scanning", a.audit(d, set(), False))

    def test_unreadable_fork_approval_fails(self):
        d = good()
        d["fork_approval"] = "<unreadable>"
        self.assertIn("fork-pr-approval", a.audit(d, set(), False))


if __name__ == "__main__":
    unittest.main()
