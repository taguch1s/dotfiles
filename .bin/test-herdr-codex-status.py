#!/usr/bin/env python3
"""Focused unit tests for the pure resource-status helpers."""

import importlib.util
import os
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).parents[1] / ".local/bin/herdr-codex-status"
SPEC = importlib.util.spec_from_loader("herdr_codex_status", SourceFileLoader("herdr_codex_status", str(SCRIPT)))
assert SPEC and SPEC.loader
STATUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATUS)


class ResourceStatusTest(unittest.TestCase):
    def test_lease_counts_unique_live_sessions_and_warns_at_limit(self):
        snapshot = {
            "agents": [
                {"agent": "codex", "agent_status": "working", "agent_session": {"value": "one"}},
                {"agent": "codex", "agent_status": "idle", "agent_session": {"value": "one"}},
                {"agent": "codex", "agent_status": "idle", "agent_session": {"value": "two"}},
                {"agent": "codex", "agent_status": "unknown", "agent_session": {"value": "three"}},
                {"agent": "other", "agent_status": "working", "agent_session": {"value": "four"}},
            ]
        }
        with patch.dict(os.environ, {"HERDR_CODEX_LEASE_LIMIT": "2"}, clear=False):
            self.assertEqual(STATUS.lease_label(snapshot), "agents:2 (稼働:1) | lease:2/2 ⚠")

    def test_invalid_limit_uses_safe_default(self):
        with patch.dict(os.environ, {"HERDR_CODEX_LEASE_LIMIT": "invalid"}, clear=False):
            self.assertEqual(STATUS.lease_limit(), STATUS.DEFAULT_LEASE_LIMIT)

    def test_lease_skips_malformed_snapshot_agents(self):
        malformed = {
            "agents": [
                None,
                {"agent": "codex", "agent_status": "working", "agent_session": "not-a-dict"},
                {"agent": "codex", "agent_status": "idle", "agent_session": {"value": "one"}},
            ]
        }
        self.assertEqual(STATUS.lease_label(malformed), "agents:1 (稼働:0) | lease:1/3")
        self.assertEqual(STATUS.lease_label({"agents": {}}), "agents:— (稼働:—) | lease:—/3")

    def test_main_falls_back_when_snapshot_schema_is_malformed(self):
        with patch.object(STATUS, "snapshot", return_value=[]), patch("builtins.print") as output:
            STATUS.main()
        output.assert_called_once_with("Codex: 状態を取得できません")

    def test_cpu_label_uses_cached_delta(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cpu.json"
            cache.write_text('{"total": 100, "idle": 40}', encoding="utf-8")
            with patch.object(STATUS, "CPU_CACHE", cache), patch.object(STATUS, "CACHE_DIR", Path(directory)), patch.object(STATUS, "cpu_counters", return_value=(200, 90)):
                self.assertEqual(STATUS.cpu_label(), "cpu:50%")

    def test_previous_cpu_counters_ignores_non_object_json(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cpu.json"
            cache.write_text("[]", encoding="utf-8")
            with patch.object(STATUS, "CPU_CACHE", cache):
                self.assertIsNone(STATUS.previous_cpu_counters())

    def test_memory_label_calculates_used_from_available(self):
        meminfo = """MemTotal:       1048576 kB
MemAvailable:    262144 kB
"""
        with patch("pathlib.Path.read_text", return_value=meminfo):
            self.assertEqual(STATUS.memory_label(), "mem:0.8/1.0G (75%)")


if __name__ == "__main__":
    unittest.main()
