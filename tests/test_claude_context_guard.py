"""claude-context-guard（文脈サイズの超過を hook で知らせる）を検証する。"""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / ".local" / "bin" / "claude-context-guard"
LOADER = importlib.machinery.SourceFileLoader("claude_context_guard", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("claude_context_guard", LOADER)
GUARD = importlib.util.module_from_spec(SPEC)
sys.modules["claude_context_guard"] = GUARD
LOADER.exec_module(GUARD)


def assistant_line(input_tokens, cache_creation=0, cache_read=0, **extra):
    entry = {
        "type": "assistant",
        "message": {
            "model": "claude-opus",
            "usage": {
                "input_tokens": input_tokens,
                "cache_creation_input_tokens": cache_creation,
                "cache_read_input_tokens": cache_read,
                "output_tokens": 123,
            },
        },
    }
    entry.update(extra)
    return json.dumps(entry)


class GuardProcessTest(unittest.TestCase):
    """hook と同じく stdin に JSON を渡してスクリプトを実行する。"""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.state_dir = root / "state"
        self.transcript = root / "session.jsonl"
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("CLAUDE_CTX_GUARD_")
        }
        self.env["CLAUDE_CTX_GUARD_STATE_DIR"] = str(self.state_dir)

    def tearDown(self):
        self.directory.cleanup()

    def write_transcript(self, *lines):
        self.transcript.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def write_context(self, tokens):
        # 文脈 = input + cache 作成 + cache 読み込み。3 種類すべてが合算されることも確かめる。
        self.write_transcript(
            json.dumps({"type": "user", "message": {"role": "user", "content": "hi"}}),
            assistant_line(1, tokens - 101, 100),
        )

    def run_hook(self, event="UserPromptSubmit", session_id="session-1", payload=None, env=None):
        if payload is None:
            payload = {
                "session_id": session_id,
                "transcript_path": str(self.transcript),
                "hook_event_name": event,
            }
        stdin = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=stdin,
            capture_output=True,
            text=True,
            env={**self.env, **(env or {})},
            check=False,
        )

    def assert_silent(self, result):
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def assert_warning(self, result, event, tokens):
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        output = json.loads(result.stdout)
        specific = output["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], event)
        self.assertIn(f"{tokens:,}", specific["additionalContext"])
        self.assertIn("/session-handoff", specific["additionalContext"])

    def test_below_threshold_is_silent(self):
        self.write_context(149_999)
        self.assert_silent(self.run_hook())

    def test_exactly_threshold_is_silent(self):
        self.write_context(150_000)
        self.assert_silent(self.run_hook())

    def test_over_threshold_warns_once(self):
        self.write_context(150_001)
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 150_001)
        self.assert_silent(self.run_hook())

    def test_rewarns_only_after_interval(self):
        self.write_context(150_001)
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 150_001)
        self.write_context(160_000)
        self.assert_silent(self.run_hook(event="PostToolUse"))
        self.write_context(200_000)
        self.assert_silent(self.run_hook(event="PostToolUse"))
        self.write_context(200_001)
        self.assert_warning(self.run_hook(event="PostToolUse"), "PostToolUse", 200_001)
        self.assert_silent(self.run_hook(event="PostToolUse"))

    def test_sessions_are_tracked_separately(self):
        self.write_context(150_001)
        self.assert_warning(self.run_hook(session_id="session-a"), "UserPromptSubmit", 150_001)
        self.assert_warning(self.run_hook(session_id="session-b"), "UserPromptSubmit", 150_001)

    def test_drop_below_threshold_resets_state(self):
        # /compact などで文脈が閾値を下回ったら、次に超えたときにまた知らせる。
        self.write_context(150_001)
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 150_001)
        self.write_context(40_000)
        self.assert_silent(self.run_hook())
        self.write_context(150_002)
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 150_002)

    def test_drop_above_threshold_lowers_baseline(self):
        self.write_context(300_000)
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 300_000)
        self.write_context(180_000)
        self.assert_silent(self.run_hook())
        self.write_context(230_000)
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 230_000)

    def test_threshold_and_interval_can_be_overridden(self):
        env = {"CLAUDE_CTX_GUARD_TOKENS": "1000", "CLAUDE_CTX_GUARD_INTERVAL": "10"}
        self.write_context(1_001)
        self.assert_warning(self.run_hook(env=env), "UserPromptSubmit", 1_001)
        self.write_context(1_011)
        self.assert_warning(self.run_hook(env=env), "UserPromptSubmit", 1_011)

    def test_invalid_threshold_falls_back_to_default(self):
        self.write_context(149_999)
        self.assert_silent(self.run_hook(env={"CLAUDE_CTX_GUARD_TOKENS": "abc"}))
        self.assert_silent(self.run_hook(env={"CLAUDE_CTX_GUARD_TOKENS": "-5"}))

    def test_uses_last_assistant_usage(self):
        self.write_transcript(
            assistant_line(200_000),
            json.dumps({"type": "user", "message": {"role": "user", "content": "tool result"}}),
            assistant_line(10, 0, 100_000),
            json.dumps({"type": "system", "content": "note"}),
        )
        self.assert_silent(self.run_hook())

    def test_skips_sidechain_and_zero_usage_entries(self):
        self.write_transcript(
            assistant_line(1, 0, 170_000),
            assistant_line(1, 0, 900_000, isSidechain=True),
            assistant_line(0, 0, 0),
        )
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 170_001)

    def test_ignores_truncated_last_line(self):
        self.transcript.write_text(assistant_line(1, 0, 170_000) + "\n" + '{"type": "assist', encoding="utf-8")
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 170_001)

    def test_reads_large_transcript_from_the_end(self):
        filler = json.dumps({"type": "user", "message": {"content": "x" * 1000}})
        lines = [assistant_line(1, 0, 10)] + [filler] * 2000 + [assistant_line(1, 0, 170_000)]
        self.write_transcript(*lines)
        self.assert_warning(self.run_hook(), "UserPromptSubmit", 170_001)

    def test_missing_transcript_is_silent(self):
        self.assert_silent(self.run_hook())

    def test_broken_transcript_is_silent(self):
        self.transcript.write_text("not json\n{]\n\x00\x01\n", encoding="utf-8")
        self.assert_silent(self.run_hook())

    def test_transcript_without_usage_is_silent(self):
        self.write_transcript(
            json.dumps({"type": "user", "message": {"content": "hi"}}),
            json.dumps({"type": "assistant", "message": {"content": "no usage"}}),
            json.dumps({"type": "assistant", "message": {"usage": "broken"}}),
        )
        self.assert_silent(self.run_hook())

    def test_invalid_stdin_is_silent(self):
        self.assert_silent(self.run_hook(payload="not json"))
        self.assert_silent(self.run_hook(payload="[]"))
        self.assert_silent(self.run_hook(payload={"hook_event_name": "UserPromptSubmit"}))

    def test_unsupported_event_is_silent(self):
        self.write_context(170_000)
        self.assert_silent(self.run_hook(event="Stop"))

    def test_subagent_hook_is_silent(self):
        # サブエージェント内の PostToolUse では、親セッションの handoff を促さない。
        self.write_context(170_000)
        payload = {
            "session_id": "session-1",
            "transcript_path": str(self.transcript),
            "hook_event_name": "PostToolUse",
            "agent_id": "agent-1",
        }
        self.assert_silent(self.run_hook(payload=payload))

    def test_unsafe_session_id_is_silent(self):
        self.write_context(170_000)
        self.assert_silent(self.run_hook(session_id="../escape"))
        self.assertFalse((self.state_dir.parent / "escape").exists())

    def test_unwritable_state_dir_is_silent(self):
        # 状態を保存できないと毎回警告してしまうので、警告しない。
        blocker = Path(self.directory.name) / "blocker"
        blocker.write_text("file", encoding="utf-8")
        self.write_context(170_000)
        self.assert_silent(self.run_hook(env={"CLAUDE_CTX_GUARD_STATE_DIR": str(blocker / "state")}))


class ContextTokensTest(unittest.TestCase):
    def test_sums_input_and_cache_tokens(self):
        usage = {
            "input_tokens": 3,
            "cache_creation_input_tokens": 20,
            "cache_read_input_tokens": 100,
            "output_tokens": 9999,
        }
        self.assertEqual(GUARD.context_tokens(usage), 123)

    def test_rejects_invalid_usage(self):
        for usage in (None, "x", {}, {"output_tokens": 5}, {"input_tokens": "3"},
                      {"input_tokens": -1}, {"input_tokens": True}):
            with self.subTest(usage=usage):
                self.assertIsNone(GUARD.context_tokens(usage))


if __name__ == "__main__":
    unittest.main()
