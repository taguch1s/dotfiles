import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ".agents/skills/issue-development-workflow/scripts/check-workflow-progress.py"
HEAD = "a" * 40
BRANCH = "feature/issue-9-workflow-progress-review-gate"


def review(kind, locator):
    return {
        "kind": kind,
        "outcome": "pass",
        "independence": "fresh",
        "degraded_reason": None,
        "reviewed_head": HEAD,
        "evidence": [{"locator": locator, "summary": "review passed"}],
    }


def handoff(recovery=None):
    payload = {
        "version": "workflow-progress/v1",
        "issue": {"repository": "taguch1s/dotfiles", "number": 9, "url": "https://github.com/taguch1s/dotfiles/issues/9"},
        "git": {"branch": BRANCH, "head": HEAD},
        "current_unit": {"id": "U1", "status": "accepted", "next_action": "delivery review"},
        "units": [{"id": "U1", "status": "accepted", "required_for_delivery": True, "review": review("light", "workflow-review-unit-U1")}],
        "final_review": review("full", "workflow-review-final"),
        "remote_sync": {"status": "pending", "pending_actions": ["post later"]},
        "delivery": {"intent": "none", "state": "not_requested", "pr_url": None, "read_back_evidence": [], "pause_reason": None},
        "continuation": "manual",
    }
    if recovery is not None:
        payload["session_recovery"] = recovery
    return "\n".join(
        [
            "<!-- workflow-progress/v1:start -->",
            "```json",
            json.dumps(payload),
            "```",
            "<!-- workflow-progress/v1:end -->",
            f'<!-- workflow-review-section/v1 id="workflow-review-unit-U1" unit="U1" kind="light" reviewed_head="{HEAD}" -->',
            "### Review evidence: Unit U1",
            f'<!-- workflow-review-section/v1 id="workflow-review-final" kind="full" reviewed_head="{HEAD}" -->',
            "### Review evidence: Final delivery",
            f'<!-- workflow-review-section/v1 id="workflow-recovery-observation-U1" kind="recovery" reviewed_head="{HEAD}" -->',
            "### Recovery observation: Unit U1",
            f'<!-- workflow-review-section/v1 id="workflow-recovery-blocked-U1" kind="blocked" reviewed_head="{HEAD}" -->',
            "### Recovery block evidence: Unit U1",
            f'<!-- workflow-review-section/v1 id="workflow-delivery-pr-U1" kind="delivery" reviewed_head="{HEAD}" -->',
            "### PR read-back evidence: Unit U1",
        ]
    )


def rewrite_payload(text, mutate):
    start = "<!-- workflow-progress/v1:start -->\n```json\n"
    end = "\n```\n<!-- workflow-progress/v1:end -->"
    before, remainder = text.split(start, 1)
    encoded, after = remainder.split(end, 1)
    payload = json.loads(encoded)
    mutate(payload)
    return before + start + json.dumps(payload) + end + after


class WorkflowProgressValidatorTest(unittest.TestCase):
    def run_validator(self, text, *, head=HEAD):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "handoff.md"
            fixture.write_text(text)
            return subprocess.run(
                ["python3", str(SCRIPT), "--handoff", str(fixture), "--branch", BRANCH, "--head", head],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_valid_delivery_evidence_passes_and_pending_remote_sync_is_non_blocking(self):
        result = self.run_validator(handoff())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK workflow-progress/v1", result.stdout)

    def test_head_mismatch_fails_the_delivery_gate(self):
        result = self.run_validator(handoff(), head="b" * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn("HEAD mismatch", result.stderr)

    def test_branch_mismatch_fails_the_delivery_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "handoff.md"
            fixture.write_text(handoff())
            result = subprocess.run(
                ["python3", str(SCRIPT), "--handoff", str(fixture), "--branch", "feature/issue-99-other", "--head", HEAD],
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("branch mismatch", result.stderr)

    def test_required_unit_review_pending_fails_the_delivery_gate(self):
        result = self.run_validator(rewrite_payload(handoff(), lambda payload: payload["units"][0]["review"].update(outcome="pending")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("light review is missing/pending/failed", result.stderr)

    def test_unrelated_unit_locator_fails_the_delivery_gate(self):
        result = self.run_validator(handoff().replace("workflow-review-unit-U1", "workflow-review-unit-other", 1))
        self.assertEqual(result.returncode, 1)
        self.assertIn("locator", result.stderr)

    def test_missing_final_review_fails_the_delivery_gate(self):
        result = self.run_validator(rewrite_payload(handoff(), lambda payload: payload["final_review"].update(outcome="pending")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("final full review", result.stderr)

    def test_degraded_unit_review_without_reason_fails_the_delivery_gate(self):
        def mutate(payload):
            payload["units"][0]["review"].update(independence="degraded", degraded_reason=None)

        result = self.run_validator(rewrite_payload(handoff(), mutate))
        self.assertEqual(result.returncode, 1)
        self.assertIn("degraded review lacks a reason", result.stderr)

    def test_empty_units_is_a_schema_error(self):
        result = self.run_validator(rewrite_payload(handoff(), lambda payload: payload.update(units=[])))
        self.assertEqual(result.returncode, 2)
        self.assertIn("units must not be empty", result.stderr)

    def test_invalid_review_enum_is_a_schema_error(self):
        result = self.run_validator(rewrite_payload(handoff(), lambda payload: payload["units"][0]["review"].update(kind="unknown")))
        self.assertEqual(result.returncode, 2)
        self.assertIn("review kind is invalid", result.stderr)

    def test_invalid_required_for_delivery_type_is_a_schema_error(self):
        result = self.run_validator(rewrite_payload(handoff(), lambda payload: payload["units"][0].update(required_for_delivery="true")))
        self.assertEqual(result.returncode, 2)
        self.assertIn("required_for_delivery", result.stderr)

    def test_complete_recovery_observation_is_candidate_only(self):
        recovery = {
            "tab_id": "w4:t5",
            "observed_at": "2026-09-20T10:43:35Z",
            "issue": {"state": "closed", "manual_gate_only": False, "blocked_evidence_locator": None},
            "latest_pr": {"state": "merged", "reference": "https://example.invalid/pr/1"},
            "agent_state": "stopped",
            "worktree_state": "clean",
            "handoff_state": "sent",
            "downstream_pane_needed": False,
            "decision": "candidate_for_orchestrator_recovery",
            "evidence": [{"locator": "workflow-recovery-observation-U1", "summary": "read-back complete"}],
        }
        result = self.run_validator(handoff(recovery))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RECOVERY candidate: orchestrator decision required", result.stdout)

    def test_incomplete_recovery_observation_is_retain_not_a_gate_failure(self):
        recovery = {
            "tab_id": "w4:t5",
            "observed_at": "2026-09-20T10:43:35Z",
            "issue": {"state": "open", "manual_gate_only": False, "blocked_evidence_locator": None},
            "latest_pr": {"state": "open", "reference": "https://example.invalid/pr/1"},
            "agent_state": "running",
            "worktree_state": "dirty",
            "handoff_state": "unsent",
            "downstream_pane_needed": True,
            "decision": "retain",
            "evidence": [{"locator": "workflow-recovery-observation-U1", "summary": "not eligible"}],
        }
        result = self.run_validator(handoff(recovery))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RECOVERY retain:", result.stdout)

    def test_malformed_recovery_locator_is_a_schema_error(self):
        recovery = {
            "tab_id": "w4:t5",
            "observed_at": "2026-09-20T10:43:35Z",
            "issue": {"state": "closed", "manual_gate_only": False, "blocked_evidence_locator": None},
            "latest_pr": {"state": "merged", "reference": "https://example.invalid/pr/1"},
            "agent_state": "stopped",
            "worktree_state": "clean",
            "handoff_state": "sent",
            "downstream_pane_needed": False,
            "decision": "candidate_for_orchestrator_recovery",
            "evidence": [{"locator": "not-a-recovery-section", "summary": "invalid"}],
        }
        result = self.run_validator(handoff(recovery))
        self.assertEqual(result.returncode, 2)
        self.assertIn("session_recovery evidence locator is invalid", result.stderr)

    def test_malformed_recovery_tab_id_is_a_schema_error(self):
        recovery = {
            "tab_id": "not-a-tab",
            "observed_at": "2026-09-20T10:43:35Z",
            "issue": {"state": "closed", "manual_gate_only": False, "blocked_evidence_locator": None},
            "latest_pr": {"state": "merged", "reference": "https://example.invalid/pr/1"},
            "agent_state": "stopped",
            "worktree_state": "clean",
            "handoff_state": "sent",
            "downstream_pane_needed": False,
            "decision": "candidate_for_orchestrator_recovery",
            "evidence": [{"locator": "workflow-recovery-observation-U1", "summary": "invalid tab"}],
        }
        result = self.run_validator(handoff(recovery))
        self.assertEqual(result.returncode, 2)
        self.assertIn("session_recovery tab_id is invalid", result.stderr)

    def test_malformed_recovery_timestamp_is_a_schema_error(self):
        recovery = {
            "tab_id": "w4:t5",
            "observed_at": "not-a-time",
            "issue": {"state": "closed", "manual_gate_only": False, "blocked_evidence_locator": None},
            "latest_pr": {"state": "merged", "reference": "https://example.invalid/pr/1"},
            "agent_state": "stopped",
            "worktree_state": "clean",
            "handoff_state": "sent",
            "downstream_pane_needed": False,
            "decision": "candidate_for_orchestrator_recovery",
            "evidence": [{"locator": "workflow-recovery-observation-U1", "summary": "invalid timestamp"}],
        }
        result = self.run_validator(handoff(recovery))
        self.assertEqual(result.returncode, 2)
        self.assertIn("session_recovery observed_at is invalid", result.stderr)

    def test_pr_delivery_read_back_terminal_passes_with_url_evidence_and_empty_next_action(self):
        def mutate(payload):
            payload["current_unit"]["next_action"] = ""
            payload["delivery"] = {
                "intent": "pr",
                "state": "pr_read_back_pass",
                "pr_url": "https://example.invalid/OWNER/REPO/pull/9",
                "read_back_evidence": [{"locator": "workflow-delivery-pr-U1", "summary": "PR URL and read-back confirmed"}],
                "pause_reason": None,
            }
            payload["continuation"] = "auto"

        result = self.run_validator(rewrite_payload(handoff(), mutate))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pr_read_back_pass_without_url_fails(self):
        def mutate(payload):
            payload["current_unit"]["next_action"] = ""
            payload["delivery"] = {"intent": "pr", "state": "pr_read_back_pass", "pr_url": "", "read_back_evidence": [], "pause_reason": None}
            payload["continuation"] = "auto"

        result = self.run_validator(rewrite_payload(handoff(), mutate))
        self.assertEqual(result.returncode, 1)
        self.assertIn("PR URL/read-back evidence", result.stderr)

    def test_pr_delivery_in_progress_before_pr_creation_is_valid(self):
        def mutate(payload):
            payload["delivery"] = {"intent": "pr", "state": "in_progress", "pr_url": None, "read_back_evidence": [], "pause_reason": None}
            payload["continuation"] = "auto"

        result = self.run_validator(rewrite_payload(handoff(), mutate))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pr_delivery_blocked_terminal_without_pr_url_is_valid_when_next_action_is_empty(self):
        def mutate(payload):
            payload["current_unit"]["next_action"] = ""
            payload["delivery"] = {"intent": "pr", "state": "blocked", "pr_url": None, "read_back_evidence": [], "pause_reason": None}
            payload["continuation"] = "auto"

        result = self.run_validator(rewrite_payload(handoff(), mutate))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pr_delivery_terminal_with_next_action_fails(self):
        def mutate(payload):
            payload["delivery"] = {
                "intent": "pr",
                "state": "pr_read_back_pass",
                "pr_url": "https://example.invalid/OWNER/REPO/pull/9",
                "read_back_evidence": [{"locator": "workflow-delivery-pr-U1", "summary": "read-back"}],
                "pause_reason": None,
            }
            payload["continuation"] = "auto"

        result = self.run_validator(rewrite_payload(handoff(), mutate))
        self.assertEqual(result.returncode, 1)
        self.assertIn("terminal delivery must not retain next_action", result.stderr)

    def test_missing_continuation_is_a_schema_error(self):
        result = self.run_validator(rewrite_payload(handoff(), lambda payload: payload.pop("continuation")))
        self.assertEqual(result.returncode, 2)
        self.assertIn("continuation is invalid", result.stderr)

    def test_pr_delivery_requires_auto_continuation(self):
        def mutate(payload):
            payload["delivery"] = {"intent": "pr", "state": "in_progress", "pr_url": None, "read_back_evidence": [], "pause_reason": None}

        result = self.run_validator(rewrite_payload(handoff(), mutate))
        self.assertEqual(result.returncode, 1)
        self.assertIn("PR delivery requires continuation=auto", result.stderr)

    def test_manual_gate_candidate_with_blank_blocked_locator_is_retain(self):
        recovery = {
            "tab_id": "w4:t5",
            "observed_at": "2026-09-20T10:43:35Z",
            "issue": {"state": "open", "manual_gate_only": True, "blocked_evidence_locator": ""},
            "latest_pr": {"state": "merged", "reference": "https://example.invalid/pr/1"},
            "agent_state": "stopped",
            "worktree_state": "clean",
            "handoff_state": "sent",
            "downstream_pane_needed": False,
            "decision": "candidate_for_orchestrator_recovery",
            "evidence": [{"locator": "workflow-recovery-observation-U1", "summary": "manual gate"}],
        }
        result = self.run_validator(handoff(recovery))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RECOVERY retain:", result.stdout)

    def test_manual_gate_candidate_with_blank_latest_pr_reference_is_retain(self):
        recovery = {
            "tab_id": "w4:t5",
            "observed_at": "2026-09-20T10:43:35Z",
            "issue": {"state": "open", "manual_gate_only": True, "blocked_evidence_locator": "workflow-recovery-blocked-U1"},
            "latest_pr": {"state": "merged", "reference": ""},
            "agent_state": "stopped",
            "worktree_state": "clean",
            "handoff_state": "sent",
            "downstream_pane_needed": False,
            "decision": "candidate_for_orchestrator_recovery",
            "evidence": [{"locator": "workflow-recovery-observation-U1", "summary": "manual gate"}],
        }
        result = self.run_validator(handoff(recovery))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RECOVERY retain:", result.stdout)


if __name__ == "__main__":
    unittest.main()
