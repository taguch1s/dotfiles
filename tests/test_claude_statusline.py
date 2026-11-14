"""claude-statusline の表示と ratelimit.jsonl への記録を検証する。

stdin の JSON とトランスクリプトは合成し、記録先は一時ディレクトリの XDG_DATA_HOME に向ける。
"""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ".local" / "bin" / "claude-statusline"
METRICS_SCRIPT = ROOT / ".local" / "bin" / "claude-token-metrics"


def load_metrics():
    loader = importlib.machinery.SourceFileLoader("claude_token_metrics_for_statusline", str(METRICS_SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def assistant(request, context_parts, *, model="claude-opus-4-1", sidechain=False):
    inp, cc, cr = context_parts
    return {"type": "assistant", "requestId": request, "isSidechain": sidechain, "sessionId": "s1",
            "timestamp": "2026-11-14T01:00:00.000Z",
            "message": {"id": f"msg_{request}", "model": model, "role": "assistant", "content": [],
                        "usage": {"input_tokens": inp, "cache_creation_input_tokens": cc,
                                  "cache_read_input_tokens": cr, "output_tokens": 10}}}


def rate_limits(five, seven=8, reset=1_763_100_000):
    return {"five_hour": {"used_percentage": five, "resets_at": reset},
            "seven_day": {"used_percentage": seven, "resets_at": reset + 86_400}}


class StatuslineCase(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.transcript = self.root / "s1.jsonl"
        self.env = dict(os.environ, XDG_DATA_HOME=str(self.root / "data"), PYTHONDONTWRITEBYTECODE="1")

    def tearDown(self):
        self.directory.cleanup()

    def write_transcript(self, lines):
        with self.transcript.open("w") as handle:
            for line in lines:
                handle.write((line if isinstance(line, str) else json.dumps(line)) + "\n")

    def payload(self, **extra):
        value = {"session_id": "s1", "transcript_path": str(self.transcript), "cwd": "/tmp",
                 "model": {"id": "claude-opus-4-1", "display_name": "Opus"}}
        value.update(extra)
        return json.dumps(value)

    def run_statusline(self, stdin):
        return subprocess.run([sys.executable, str(SCRIPT)], input=stdin, capture_output=True, text=True,
                              env=self.env, timeout=30)

    def records_file(self):
        return self.root / "data" / "claude-token-metrics" / "ratelimit.jsonl"

    def records(self):
        path = self.records_file()
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


class DisplayTest(StatuslineCase):
    def test_shows_context_and_rate_limits_in_one_line(self):
        self.write_transcript([assistant("r1", (5, 1000, 100_000)), assistant("r2", (3, 2000, 180_000))])
        result = self.run_statusline(self.payload(rate_limits=rate_limits(54, 8)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "ctx 182k | 5h 54% | 7d 8%\n")

    def test_context_uses_last_real_request(self):
        # 合成メッセージ、sidechain、壊れた行、usage のない行は飛ばし、最後の本体リクエストを使う。
        self.write_transcript([
            assistant("r1", (1, 0, 999)),
            assistant("r2", (2, 1500, 1_200_000)),
            assistant("r3", (1, 0, 5), sidechain=True),
            {"type": "assistant", "message": {"model": "<synthetic>", "role": "assistant", "content": [],
                                              "usage": {"input_tokens": 0}}},
            {"type": "user", "message": {"role": "user", "content": "x" * 300_000}},
            "{broken",
        ])
        result = self.run_statusline(self.payload())
        self.assertEqual(result.stdout, "ctx 1.2M | 5h - | 7d -\n")

    def test_small_context_and_fractional_percent(self):
        self.write_transcript([assistant("r1", (1, 0, 998))])
        result = self.run_statusline(self.payload(rate_limits=rate_limits(12.6, 0.4)))
        self.assertEqual(result.stdout, "ctx 999 | 5h 13% | 7d 0%\n")

    def test_missing_inputs_still_print_one_line(self):
        cases = {
            "rate_limits null": self.payload(rate_limits=None),
            "rate_limits missing": self.payload(),
            "five_hour null": self.payload(rate_limits={"five_hour": None, "seven_day": None}),
            "no transcript": json.dumps({"session_id": "s1", "transcript_path": str(self.root / "none.jsonl")}),
            "broken stdin": "{not json",
            "empty stdin": "",
            "array stdin": "[]",
        }
        for name, stdin in cases.items():
            with self.subTest(name=name):
                result = self.run_statusline(stdin)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(result.stdout.splitlines()), 1)
                self.assertTrue(result.stdout.startswith("ctx "))
        self.assertFalse(self.records_file().exists())


class RecordTest(StatuslineCase):
    def setUp(self):
        super().setUp()
        self.write_transcript([assistant("r1", (1, 0, 999))])

    def test_records_only_when_used_percentage_changes(self):
        for five, seven in ((54, 8), (54, 8), (54, 8), (55, 8), (55, 8), (55, 9)):
            self.assertEqual(self.run_statusline(self.payload(rate_limits=rate_limits(five, seven))).returncode, 0)
        records = self.records()
        self.assertEqual([(r["five_hour"]["used_percentage"], r["seven_day"]["used_percentage"]) for r in records],
                         [(54, 8), (55, 8), (55, 9)])
        first = records[0]
        self.assertEqual(sorted(first), ["five_hour", "session_id", "seven_day", "ts"])
        self.assertEqual(first["session_id"], "s1")
        self.assertEqual(first["five_hour"], {"used_percentage": 54, "resets_at": 1_763_100_000})
        self.assertEqual(first["seven_day"]["resets_at"], 1_763_186_400)

    def test_missing_rate_limits_do_not_record(self):
        self.run_statusline(self.payload(rate_limits=rate_limits(10)))
        for stdin in (self.payload(rate_limits=None), self.payload(),
                      self.payload(rate_limits={"five_hour": {"used_percentage": None}}),
                      self.payload(rate_limits={"five_hour": {"used_percentage": "54"}}),
                      '{"rate_limits": {"five_hour": {"used_percentage": NaN}, "seven_day": {"used_percentage": Infinity}}}'):
            self.run_statusline(stdin)
        self.assertEqual(len(self.records()), 1)

    def test_broken_last_record_does_not_block_recording(self):
        self.records_file().parent.mkdir(parents=True)
        self.records_file().write_text("{broken\n")
        self.run_statusline(self.payload(rate_limits=rate_limits(20)))
        lines = self.records_file().read_text().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(json.loads(lines[-1])["five_hour"]["used_percentage"], 20)

    def test_calibrate_reads_statusline_records(self):
        for five in (10, 11, 12):
            self.run_statusline(self.payload(rate_limits=rate_limits(five)))
        metrics = load_metrics()
        records = metrics.load_ratelimit_records(self.records_file())
        self.assertEqual([record["pct"] for record in records], [10, 11, 12])
        self.assertEqual({record["reset"] for record in records}, {1_763_100_000.0})
        self.assertEqual(len(metrics.build_intervals(records)[0]), 2)


class SettingsTest(unittest.TestCase):
    def test_repo_settings_register_statusline(self):
        settings = json.loads((ROOT / ".claude" / "settings.json").read_text())
        self.assertEqual(settings["statusLine"]["type"], "command")
        self.assertEqual(settings["statusLine"]["command"], "~/.local/bin/claude-statusline")


if __name__ == "__main__":
    unittest.main()
