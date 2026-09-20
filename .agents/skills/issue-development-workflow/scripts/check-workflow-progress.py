#!/usr/bin/env python3
"""Validate local workflow-progress/v1 evidence without network or side effects."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import re
import subprocess
import sys
from pathlib import Path


SHA = re.compile(r"^[0-9a-f]{40}$")
TAB_ID = re.compile(r"^w[^:\s]+:t[^:\s]+$")
BLOCK = re.compile(r"<!-- workflow-progress/v1:start -->\s*```json\s*(.*?)\s*```\s*<!-- workflow-progress/v1:end -->", re.S)
MARKER = re.compile(r'<!-- workflow-review-section/v1 (?P<attrs>[^>]*) -->\n(?P<heading>### [^\n]+)')
ATTR = re.compile(r'(\w+)="([^"]*)"')


class SchemaError(Exception):
    pass


def error(message: str) -> None:
    print(f"ERROR workflow-progress: {message}", file=sys.stderr)
    raise SystemExit(2)


def gate(message: str) -> None:
    print(f"NG workflow-progress: {message}", file=sys.stderr)
    raise SystemExit(1)


def current_git(command: list[str]) -> str:
    return subprocess.check_output(command, text=True).strip()


def markers(text: str) -> list[dict[str, str]]:
    result = []
    for match in MARKER.finditer(text):
        attrs = dict(ATTR.findall(match.group("attrs")))
        if not attrs.get("id"):
            raise SchemaError("review marker id is required")
        attrs["heading"] = match.group("heading")
        result.append(attrs)
    return result


def one_marker(items: list[dict[str, str]], locator: str) -> dict[str, str] | None:
    matched = [item for item in items if item["id"] == locator]
    return matched[0] if len(matched) == 1 else None


def review_marker(items: list[dict[str, str]], review: dict, *, unit: str | None) -> bool:
    evidence = review.get("evidence")
    if not isinstance(evidence, list) or len(evidence) != 1:
        return False
    locator = evidence[0].get("locator") if isinstance(evidence[0], dict) else None
    expected = f"workflow-review-unit-{unit}" if unit else "workflow-review-final"
    marker = one_marker(items, locator) if isinstance(locator, str) and locator == expected else None
    if marker is None or marker.get("reviewed_head") != review.get("reviewed_head"):
        return False
    if unit:
        return marker.get("unit") == unit and marker.get("kind") == "light" and marker["heading"] == f"### Review evidence: Unit {unit}"
    return "unit" not in marker and marker.get("kind") == "full" and marker["heading"] == "### Review evidence: Final delivery"


def validate_review(review: object) -> None:
    if not isinstance(review, dict):
        raise SchemaError("review must be an object")
    if review.get("kind") not in ("light", "full"):
        raise SchemaError("review kind is invalid")
    if review.get("outcome") not in ("pass", "fail", "pending"):
        raise SchemaError("review outcome is invalid")
    if review.get("independence") not in ("fresh", "degraded"):
        raise SchemaError("review independence is invalid")
    if review.get("degraded_reason") is not None and not isinstance(review.get("degraded_reason"), str):
        raise SchemaError("review degraded_reason is invalid")
    reviewed_head = review.get("reviewed_head")
    if reviewed_head is not None and (not isinstance(reviewed_head, str) or not SHA.match(reviewed_head)):
        raise SchemaError("review reviewed_head is invalid")
    evidence = review.get("evidence")
    if not isinstance(evidence, list) or any(not isinstance(item, dict) or not isinstance(item.get("locator"), str) or not isinstance(item.get("summary"), str) for item in evidence):
        raise SchemaError("review evidence is invalid")


def validate_delivery(value: object) -> dict:
    if not isinstance(value, dict):
        raise SchemaError("delivery must be an object")
    required = ("intent", "state", "pr_url", "read_back_evidence", "pause_reason")
    if any(key not in value for key in required):
        raise SchemaError("delivery required field is missing")
    if value["intent"] not in ("none", "commit", "pr"):
        raise SchemaError("delivery intent is invalid")
    if value["state"] not in ("not_requested", "in_progress", "pr_read_back_pass", "blocked", "paused"):
        raise SchemaError("delivery state is invalid")
    if value["pr_url"] is not None and not isinstance(value["pr_url"], str):
        raise SchemaError("delivery pr_url is invalid")
    if value["pause_reason"] is not None and not isinstance(value["pause_reason"], str):
        raise SchemaError("delivery pause_reason is invalid")
    evidence = value["read_back_evidence"]
    if not isinstance(evidence, list) or any(not isinstance(item, dict) or not isinstance(item.get("locator"), str) or not isinstance(item.get("summary"), str) for item in evidence):
        raise SchemaError("delivery read_back_evidence is invalid")
    return value


def validate_delivery_gate(delivery: dict, current: dict, items: list[dict[str, str]]) -> None:
    if delivery["intent"] != "pr":
        return
    state = delivery["state"]
    if state == "in_progress":
        return
    if state not in ("pr_read_back_pass", "blocked", "paused"):
        gate("PR delivery state must be in_progress or a terminal state")
    if str(current.get("next_action", "")).strip():
        gate("terminal delivery must not retain next_action")
    if state == "paused" and delivery.get("pause_reason") != "user_instruction":
        gate("paused PR delivery requires user_instruction")
    if state != "pr_read_back_pass":
        return
    evidence = delivery["read_back_evidence"]
    if not isinstance(delivery.get("pr_url"), str) or not delivery["pr_url"].strip() or len(evidence) != 1:
        gate("pr_read_back_pass requires PR URL/read-back evidence")
    marker = one_marker(items, evidence[0]["locator"])
    if marker is None or marker.get("kind") != "delivery" or not marker["heading"].startswith("### PR read-back evidence:"):
        gate("pr_read_back_pass requires PR URL/read-back evidence")


def validate_recovery(value: object, items: list[dict[str, str]]) -> str:
    if value is None:
        return ""
    if not isinstance(value, dict):
        raise SchemaError("session_recovery must be an object")
    required = ("tab_id", "observed_at", "issue", "latest_pr", "agent_state", "worktree_state", "handoff_state", "downstream_pane_needed", "decision", "evidence")
    if any(key not in value for key in required):
        raise SchemaError("session_recovery required field is missing")
    if not isinstance(value["tab_id"], str) or not TAB_ID.match(value["tab_id"]):
        raise SchemaError("session_recovery tab_id is invalid")
    if not isinstance(value["observed_at"], str):
        raise SchemaError("session_recovery observed_at is invalid")
    try:
        observed_at = datetime.fromisoformat(value["observed_at"].replace("Z", "+00:00"))
    except ValueError as exc:
        raise SchemaError("session_recovery observed_at is invalid") from exc
    if observed_at.tzinfo is None:
        raise SchemaError("session_recovery observed_at is invalid")
    if value["agent_state"] not in ("running", "stopped", "unknown") or value["worktree_state"] not in ("clean", "dirty", "unknown") or value["handoff_state"] not in ("sent", "unsent", "unknown"):
        raise SchemaError("session_recovery state is invalid")
    if value["decision"] not in ("retain", "candidate_for_orchestrator_recovery", "recovered") or value["downstream_pane_needed"] not in (True, False, None):
        raise SchemaError("session_recovery decision is invalid")
    issue, pr = value["issue"], value["latest_pr"]
    if not isinstance(issue, dict) or issue.get("state") not in ("open", "closed", "unknown") or not isinstance(pr, dict) or pr.get("state") not in ("none", "open", "merged", "unknown"):
        raise SchemaError("session_recovery issue or PR state is invalid")
    if not isinstance(pr.get("reference"), str) or not isinstance(issue.get("blocked_evidence_locator"), (str, type(None))):
        raise SchemaError("session_recovery issue or PR reference is invalid")
    evidence = value["evidence"]
    if not isinstance(evidence, list) or len(evidence) != 1 or not isinstance(evidence[0], dict):
        raise SchemaError("session_recovery evidence is invalid")
    marker = one_marker(items, evidence[0].get("locator", ""))
    if marker is None or marker.get("kind") != "recovery" or not marker["heading"].startswith("### Recovery observation:"):
        raise SchemaError("session_recovery evidence locator is invalid")
    blocked_locator = issue.get("blocked_evidence_locator")
    blocked_marker = one_marker(items, blocked_locator) if isinstance(blocked_locator, str) and blocked_locator.strip() else None
    manual_ok = issue["state"] == "open" and issue.get("manual_gate_only") is True and blocked_marker is not None and blocked_marker.get("kind") == "blocked" and blocked_marker["heading"].startswith("### Recovery block evidence:") and bool(pr["reference"].strip())
    issue_ok = issue["state"] == "closed" or manual_ok
    candidate = issue_ok and pr["state"] in ("none", "merged") and value["agent_state"] == "stopped" and value["worktree_state"] == "clean" and value["handoff_state"] == "sent" and value["downstream_pane_needed"] is False
    return "RECOVERY candidate: orchestrator decision required" if candidate else "RECOVERY retain: incomplete or conflicting observation"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--handoff", required=True, type=Path)
    parser.add_argument("--branch")
    parser.add_argument("--head")
    args = parser.parse_args()
    try:
        text = args.handoff.read_text()
    except OSError as exc:
        error(f"cannot read handoff: {exc}")
    blocks = BLOCK.findall(text)
    if len(blocks) != 1:
        error("expected exactly one workflow-progress/v1 block")
    try:
        data = json.loads(blocks[0])
        if not isinstance(data, dict) or data.get("version") != "workflow-progress/v1":
            raise SchemaError("version is invalid")
        units = data.get("units")
        current = data.get("current_unit")
        if not isinstance(units, list) or not units:
            raise SchemaError("units must not be empty")
        if not isinstance(current, dict):
            raise SchemaError("current_unit is invalid")
        indexed = {unit.get("id"): unit for unit in units if isinstance(unit, dict) and isinstance(unit.get("id"), str) and unit.get("id")}
        if len(indexed) != len(units) or current.get("id") not in indexed:
            raise SchemaError("current_unit.id does not reference units")
        if current.get("status") not in ("planned", "in_progress", "blocked", "accepted"):
            raise SchemaError("current_unit status is invalid")
        for unit in units:
            if unit.get("status") not in ("planned", "in_progress", "blocked", "accepted") or not isinstance(unit.get("required_for_delivery"), bool):
                raise SchemaError("Unit status or required_for_delivery is invalid")
            validate_review(unit.get("review"))
        if indexed[current["id"]].get("status") != current.get("status"):
            raise SchemaError("current_unit status does not match Unit")
        if not any(unit.get("required_for_delivery") is True for unit in units):
            raise SchemaError("at least one Unit must be required_for_delivery")
        git = data.get("git")
        if not isinstance(git, dict) or not isinstance(git.get("branch"), str) or not git["branch"] or not isinstance(git.get("head"), str) or not SHA.match(git["head"]):
            raise SchemaError("git identity is invalid")
        validate_review(data.get("final_review"))
        delivery = validate_delivery(data.get("delivery"))
        continuation = data.get("continuation")
        if continuation not in ("manual", "auto"):
            raise SchemaError("continuation is invalid")
    except (json.JSONDecodeError, SchemaError) as exc:
        error(str(exc))

    branch = args.branch or current_git(["git", "branch", "--show-current"])
    head = args.head or current_git(["git", "rev-parse", "HEAD"])
    if git.get("branch") != branch:
        gate("branch mismatch")
    if git["head"] != head:
        gate("HEAD mismatch")
    items = markers(text)
    for unit in units:
        if not unit.get("required_for_delivery"):
            continue
        review = unit.get("review")
        if unit.get("status") != "accepted" or not isinstance(review, dict) or review.get("kind") != "light" or review.get("outcome") != "pass":
            gate(f"required Unit {unit.get('id')} light review is missing/pending/failed")
        if review.get("reviewed_head") != head:
            gate(f"required Unit {unit.get('id')} review HEAD mismatch")
        reason = review.get("degraded_reason")
        if review.get("independence") == "degraded" and (not isinstance(reason, str) or not reason.strip()):
            gate(f"required Unit {unit.get('id')} degraded review lacks a reason")
        if not review_marker(items, review, unit=unit["id"]):
            gate(f"required Unit {unit['id']} evidence locator is invalid or unrelated")
    final = data.get("final_review")
    if not isinstance(final, dict) or final.get("kind") != "full" or final.get("outcome") != "pass":
        gate("final full review is missing/pending/failed")
    if final.get("independence") != "fresh":
        gate("final review must be fresh")
    if final.get("reviewed_head") != head or not review_marker(items, final, unit=None):
        gate("final review evidence locator is invalid or unrelated")
    if delivery["intent"] == "pr" and continuation != "auto":
        gate("PR delivery requires continuation=auto")
    validate_delivery_gate(delivery, current, items)
    try:
        recovery = validate_recovery(data.get("session_recovery"), items)
    except SchemaError as exc:
        error(str(exc))
    print(f"OK workflow-progress/v1: branch={branch} head={head}")
    if recovery:
        print(recovery)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
