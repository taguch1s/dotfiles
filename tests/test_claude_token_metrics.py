"""claude-token-metrics の集計（L0〜L2）、record / report、SessionEnd hook を検証する。

トランスクリプトは合成 fixture を一時ディレクトリに書き出して使う。
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import random
import string
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ".local" / "bin" / "claude-token-metrics"
LOADER = importlib.machinery.SourceFileLoader("claude_token_metrics", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("claude_token_metrics", LOADER)
METRICS = importlib.util.module_from_spec(SPEC)
sys.modules["claude_token_metrics"] = METRICS
LOADER.exec_module(METRICS)

SESSION = "sess-1"
VERSION = "2.1.0"
# 圧縮しにくい 1000 バイトの文字列（同じ内容を 2 回返すツール出力に使う）。
_RANDOM = random.Random(18)
NOISE = "".join(_RANDOM.choice(string.ascii_letters) for _ in range(1000))


def usage(inp, cc, cr, out, *, cc5=None, cc1=None, thinking=None):
    value = {"input_tokens": inp, "cache_creation_input_tokens": cc,
             "cache_read_input_tokens": cr, "output_tokens": out}
    if cc5 is not None:
        value["cache_creation"] = {"ephemeral_5m_input_tokens": cc5, "ephemeral_1h_input_tokens": cc1}
    if thinking is not None:
        value["output_tokens_details"] = {"thinking_tokens": thinking}
    return value


def assistant(request, model, use, content, *, sidechain=False, minute=0):
    return {"type": "assistant", "requestId": request, "isSidechain": sidechain, "sessionId": SESSION,
            "version": VERSION, "timestamp": f"2026-11-14T01:{minute:02d}:00.000Z",
            "message": {"id": f"msg_{request}", "model": model, "role": "assistant",
                        "content": content, "usage": use}}


def tool_use(tool_id, name, tool_input):
    return {"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}


def tool_result(tool_id, content, minute=0):
    return {"type": "user", "isSidechain": False, "sessionId": SESSION, "version": VERSION,
            "timestamp": f"2026-11-14T01:{minute:02d}:30.000Z",
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id,
                                                     "content": content}]}}


def main_lines():
    use_a = usage(10, 1000, 0, 50, cc5=400, cc1=600, thinking=20)
    return [
        {"type": "user", "sessionId": SESSION, "version": VERSION, "timestamp": "2026-11-14T01:00:00.000Z",
         "message": {"role": "user", "content": "調べて"}},
        # 1 リクエストが 2 行に分かれる（同じ requestId）。
        assistant("req_A", "m1", use_a, [{"type": "text", "text": "見ます"}], minute=1),
        assistant("req_A", "m1", use_a, [tool_use("toolu_1", "Bash", {"command": "git status"})], minute=1),
        tool_result("toolu_1", NOISE, minute=1),
        # cache_creation の内訳がない行は 5m として数える。
        assistant("req_B", "m1", usage(5, 200, 1000, 30),
                  [tool_use("toolu_2", "Bash", {"command": "FOO=1 /usr/bin/git status"})], minute=2),
        tool_result("toolu_2", [{"type": "text", "text": NOISE}], minute=2),
        assistant("req_C", "m2", usage(2, 0, 1200, 10),
                  [tool_use("toolu_3", "Read", {"file_path": "/x"})], minute=3),
        tool_result("toolu_3", "short", minute=3),
        "{not json",
        {"type": "assistant", "sessionId": SESSION, "version": VERSION, "timestamp": "2026-11-14T01:04:00.000Z",
         "message": {"model": "<synthetic>", "role": "assistant", "content": []}},
        # 中断などで Claude Code が作る合成メッセージは usage が 0 でもリクエストに数えない。
        {"type": "assistant", "sessionId": SESSION, "version": VERSION, "timestamp": "2026-11-14T01:04:10.000Z",
         "message": {"id": "msg_synthetic", "model": "<synthetic>", "role": "assistant",
                     "content": [{"type": "text", "text": "No response requested."}], "usage": usage(0, 0, 0, 0)}},
        assistant("req_S", "m1", usage(1, 100, 0, 5, cc5=100, cc1=0), [], sidechain=True, minute=4),
        # /clear や compact の後は文脈が急に小さくなる。
        assistant("req_D", "m1", usage(3, 50, 0, 8), [{"type": "text", "text": "完了"}], minute=5),
    ]


def subagent_lines():
    line = assistant("req_X", "m1", usage(4, 300, 500, 40, cc5=0, cc1=300), [], sidechain=True, minute=4)
    return [line, line]


def write_jsonl(path, lines):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for line in lines:
            handle.write((line if isinstance(line, str) else json.dumps(line)) + "\n")


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.transcript = self.root / "projects" / "-home-x" / f"{SESSION}.jsonl"
        write_jsonl(self.transcript, main_lines())
        write_jsonl(self.transcript.with_suffix("") / "subagents" / "agent-a1.jsonl", subagent_lines())
        self.env = dict(os.environ, XDG_DATA_HOME=str(self.root / "data"),
                        XDG_CONFIG_HOME=str(self.root / "config"), PYTHONDONTWRITEBYTECODE="1")

    def tearDown(self):
        self.directory.cleanup()

    def run_cli(self, *args, stdin=""):
        return subprocess.run([sys.executable, str(SCRIPT), *args], input=stdin, capture_output=True,
                              text=True, env=self.env, timeout=60)


class SessionMetricsTest(FixtureCase):
    def setUp(self):
        super().setUp()
        result = self.run_cli("session", str(self.transcript))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.strip().splitlines()), 1)
        self.data = json.loads(result.stdout)

    def test_identity_and_skips(self):
        self.assertEqual(self.data["schema"], "claude-token-metrics/v1")
        self.assertEqual(self.data["session_id"], SESSION)
        self.assertEqual(self.data["version"], VERSION)
        self.assertEqual(self.data["started_at"], "2026-11-14T01:00:00.000Z")
        self.assertEqual(self.data["weights"], METRICS.DEFAULT_WEIGHTS)
        self.assertEqual(self.data["weights_source"], "default")
        self.assertEqual(self.data["skipped"], {"broken_lines": 1, "no_usage": 1, "synthetic": 1})

    def test_l0_main_dedupes_request_and_splits_cache_creation(self):
        l0 = self.data["main"]["L0"]
        self.assertEqual(l0["tokens"], {"input": 20, "cache_creation_5m": 650, "cache_creation_1h": 600,
                                        "cache_creation": 1250, "cache_read": 2200, "output": 98,
                                        "thinking": 20})
        self.assertAlmostEqual(l0["weighted_cost"], 2742.5)

    def test_l0_by_model(self):
        models = self.data["main"]["by_model"]
        self.assertEqual(sorted(models), ["m1", "m2"])
        self.assertEqual(models["m1"]["requests"], 3)
        self.assertEqual(models["m2"]["requests"], 1)
        self.assertAlmostEqual(models["m2"]["weighted_cost"], 2 + 120 + 50)

    def test_l1_context_rent_and_drop(self):
        l1 = self.data["main"]["L1"]
        self.assertEqual(l1["requests"], 4)
        self.assertEqual(l1["context"]["max"], 1205)
        self.assertEqual(l1["context"]["last"], 53)
        self.assertAlmostEqual(l1["context"]["mean"], 867.5)
        deciles = l1["context"]["deciles"]
        self.assertEqual(len(deciles), 10)
        self.assertEqual([value for value in deciles if value is not None], [1010, 1205, 1202, 53])
        self.assertAlmostEqual(l1["rent_rate"], 220 / 2742.5)
        self.assertAlmostEqual(l1["reread_ratio"], 2200 / 1270)
        self.assertEqual(l1["drops"], [{"request_index": 3, "from": 1202, "to": 53}])

    def test_sidechain_and_subagents_are_separate(self):
        side, sub = self.data["sidechain"], self.data["subagents"]
        self.assertEqual(side["L1"]["requests"], 1)
        self.assertAlmostEqual(side["L0"]["weighted_cost"], 1 + 125 + 25)
        self.assertEqual(sub["files"], 1)
        self.assertEqual(sub["L1"]["requests"], 1)
        self.assertEqual(sub["L0"]["tokens"]["cache_creation_1h"], 300)
        self.assertAlmostEqual(sub["L0"]["weighted_cost"], 4 + 600 + 50 + 200)
        total = self.data["total"]
        self.assertEqual(total["requests"], 6)
        self.assertAlmostEqual(total["weighted_cost"], 2742.5 + 151 + 854)
        self.assertAlmostEqual(total["rent_rate"], (220 + 50) / 3747.5)

    def test_l2_repeated_tool_output_has_low_new_information(self):
        l2 = self.data["main"]["L2"]
        self.assertEqual(l2["window_bytes"], 400_000)
        self.assertEqual(l2["min_bytes"], 200)
        self.assertEqual(l2["tool_results"], 2)
        self.assertEqual(l2["raw_bytes"], 2000)
        bash = l2["by_tool"]["Bash"]
        self.assertEqual(bash["count"], 2)
        self.assertNotIn("Read", l2["by_tool"])
        self.assertAlmostEqual(l2["new_info_rate"], l2["novel_bytes"] / 2000)
        self.assertEqual([(item["key"], item["count"], item["raw_bytes"]) for item in l2["low_new_info"]],
                         [("Bash:git", 1, 1000)])
        self.assertLess(l2["low_new_info"][0]["novel_bytes"], 50)
        self.assertGreater(l2["novel_bytes"], 500)


class NewInformationTest(unittest.TestCase):
    def test_second_identical_output_is_below_five_percent(self):
        history = METRICS.ToolHistory()
        first = history.novel_bytes(NOISE.encode())
        second = history.novel_bytes(NOISE.encode())
        self.assertGreater(first / 1000, 0.5)
        self.assertLess(second / 1000, 0.05)

    def test_window_keeps_only_recent_bytes(self):
        history = METRICS.ToolHistory(window=300)
        history.novel_bytes(b"a" * 1000)
        self.assertEqual(len(history.buffer), 300)

    def test_command_key(self):
        self.assertEqual(METRICS.command_key("Bash", {"command": "LANG=C sudo ls -la"}), "Bash:sudo")
        self.assertEqual(METRICS.command_key("Bash", {"command": "  /usr/bin/rg foo"}), "Bash:rg")
        self.assertEqual(METRICS.command_key("Read", {"file_path": "/x"}), "Read")


class WeightsTest(FixtureCase):
    def test_cli_weights_override(self):
        result = self.run_cli("session", "--weights", "output=1,cache_read=0", str(self.transcript))
        data = json.loads(result.stdout)
        self.assertEqual(data["weights_source"], "--weights")
        self.assertAlmostEqual(data["main"]["L0"]["weighted_cost"], 20 + 812.5 + 1200 + 0 + 98)
        self.assertEqual(data["main"]["L1"]["rent_rate"], 0)

    def test_config_file_then_cli_precedence(self):
        config = self.root / "config" / "claude-token-metrics" / "weights.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"weights": {"output": 2, "input": 3}, "note": "calibrate"}))
        data = json.loads(self.run_cli("session", str(self.transcript)).stdout)
        self.assertEqual(data["weights"]["output"], 2)
        self.assertEqual(data["weights_source"], str(config))
        data = json.loads(self.run_cli("session", "--weights", "output=4", str(self.transcript)).stdout)
        self.assertEqual((data["weights"]["output"], data["weights"]["input"]), (4, 3))

    def test_invalid_weights_are_rejected(self):
        for value in ("output", "unknown=1", "output=-1", "output=x"):
            with self.subTest(value=value):
                self.assertEqual(self.run_cli("session", "--weights", value, str(self.transcript)).returncode, 2)


class RecordReportTest(FixtureCase):
    def sessions_file(self):
        return self.root / "data" / "claude-token-metrics" / "sessions.jsonl"

    def hook_input(self, transcript=None):
        return json.dumps({"session_id": SESSION, "transcript_path": str(transcript or self.transcript),
                           "cwd": "/tmp", "hook_event_name": "SessionEnd", "reason": "clear"})

    def test_record_appends_and_report_uses_latest(self):
        for _ in range(2):
            result = self.run_cli("record", "--foreground", stdin=self.hook_input())
            self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.sessions_file().read_text().splitlines()
        self.assertEqual(len(lines), 2)
        record = json.loads(lines[-1])
        self.assertEqual((record["session_id"], record["reason"]), (SESSION, "clear"))
        self.assertIn("recorded_at", record)

        rows = json.loads(self.run_cli("report", "--json").stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["session_id"], SESSION)
        self.assertAlmostEqual(rows[0]["weighted_cost"], 3747.5)
        self.assertEqual(rows[0]["context_max"], 1205)
        self.assertEqual(rows[0]["low_new_info_top"], ["Bash:git"])

        table = self.run_cli("report", "--since", "2026-11-14")
        self.assertEqual(table.returncode, 0, table.stderr)
        self.assertIn(SESSION, table.stdout)
        self.assertEqual(json.loads(self.run_cli("report", "--since", "2026-11-15", "--json").stdout), [])
        self.assertEqual(self.run_cli("report", "--since", "11/14").returncode, 2)

    def test_record_never_fails_the_hook(self):
        for stdin in ("not json", self.hook_input(self.root / "missing.jsonl"), ""):
            with self.subTest(stdin=stdin):
                result = self.run_cli("record", "--foreground", stdin=stdin)
                self.assertEqual(result.returncode, 0)
        self.assertFalse(self.sessions_file().exists())

    def test_record_detaches_by_default(self):
        result = self.run_cli("record", stdin=self.hook_input())
        self.assertEqual(result.returncode, 0, result.stderr)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not self.sessions_file().exists():
            time.sleep(0.1)
        self.assertTrue(self.sessions_file().exists())

    def test_report_skips_broken_records(self):
        self.sessions_file().parent.mkdir(parents=True)
        self.sessions_file().write_text("{broken\n")
        result = self.run_cli("report", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])


class HookSettingsTest(unittest.TestCase):
    def test_session_end_records_metrics(self):
        settings = json.loads((ROOT / ".claude" / "settings.json").read_text())
        hooks = [hook for group in settings["hooks"]["SessionEnd"] for hook in group["hooks"]]
        matches = [hook for hook in hooks if "claude-token-metrics record" in hook["command"]]
        self.assertEqual(len(matches), 1)
        self.assertGreater(matches[0].get("timeout", 0), 0)


# ---- calibrate --------------------------------------------------------------

# 合成データの「真の」重み（input = 1 の相対値）。既定値と違う値にして、既定値を返していないことも確かめる。
TRUE_WEIGHTS = {"input": 1.0, "cache_creation_5m": 1.5, "cache_creation_1h": 2.5, "cache_read": 0.08, "output": 4.0}
PERCENT_PER_INPUT = 4e-6  # input 1 トークンあたりの使用率（%）
T0 = 1_750_000_000.0  # 2025-06-15。ファイルの mtime より十分前にする
WINDOW = 5 * 3600


def iso(epoch, *, z=False):
    text = METRICS.dt.datetime.fromtimestamp(epoch, METRICS.dt.timezone.utc).isoformat(timespec="milliseconds")
    return text.replace("+00:00", "Z") if z else text


def calibration_request(request_id, epoch, model, tokens):
    use = {"input_tokens": tokens["input"],
           "cache_creation_input_tokens": tokens["cache_creation_5m"] + tokens["cache_creation_1h"],
           "cache_creation": {"ephemeral_5m_input_tokens": tokens["cache_creation_5m"],
                              "ephemeral_1h_input_tokens": tokens["cache_creation_1h"]},
           "cache_read_input_tokens": tokens["cache_read"], "output_tokens": tokens["output"]}
    return {"type": "assistant", "requestId": request_id, "sessionId": "cal", "timestamp": iso(epoch, z=True),
            "message": {"id": f"msg_{request_id}", "model": model, "role": "assistant", "content": [], "usage": use}}


def ratelimit_record(epoch, percent, reset):
    return {"ts": iso(epoch), "session_id": "cal",
            "five_hour": {"used_percentage": percent, "resets_at": reset},
            "seven_day": {"used_percentage": 3, "resets_at": reset + 6 * 86_400}}


class Synthetic:
    """既知の重みから使用率を生成し、ratelimit.jsonl とトランスクリプト群を書き出す。"""

    def __init__(self, root, seed=20):
        self.random = random.Random(seed)
        self.projects = root / "projects"
        self.ratelimit = root / "data" / "claude-token-metrics" / "ratelimit.jsonl"
        self.files = [self.projects / "-home-a" / "s1.jsonl",
                      self.projects / "-home-a" / "s1" / "subagents" / "agent-1.jsonl",
                      self.projects / "-home-b" / "s2.jsonl"]
        self.lines = {file: [] for file in self.files}
        self.records = []
        self.count = 0
        self.clock = T0

    def tokens(self):
        r = self.random
        return {"input": r.randint(200, 6000), "cache_creation_5m": r.randint(0, 20000),
                "cache_creation_1h": r.randint(0, 20000), "cache_read": r.randint(10_000, 300_000),
                "output": r.randint(100, 5000)}

    def request(self, epoch, model, tokens=None):
        tokens = tokens or self.tokens()
        self.count += 1
        line = calibration_request(f"req_{self.count}", epoch, model, tokens)
        file = self.files[self.count % len(self.files)]
        self.lines[file].extend([line, line])  # 1 リクエストが 2 行に分かれる
        return tokens

    def window(self, intervals, *, model="claude-opus-4-1", scale=1.0, noise=0.01, start_percent=1.0):
        reset = self.clock + WINDOW
        percent = start_percent
        self.records.append(ratelimit_record(self.clock, percent, reset))
        for _ in range(intervals):
            delta = 0.0
            for step in range(self.random.randint(1, 3)):
                tokens = self.request(self.clock + 10 + step * 20, model)
                delta += PERCENT_PER_INPUT * scale * sum(TRUE_WEIGHTS[key] * tokens[key] for key in TRUE_WEIGHTS)
            percent += delta * (1 + noise * self.random.uniform(-1, 1))
            self.clock += 90
            self.records.append(ratelimit_record(self.clock, round(percent, 4), reset))
        # 枠の切り替わりの直前に大きなリクエストを置く。区間に入れると推定が崩れる。
        self.request(self.clock + 30, model, {key: 5_000_000 for key in TRUE_WEIGHTS})
        self.clock += 600
        return self

    def write(self):
        # 枠の外（最初の記録より前）のリクエストは数えない。
        self.request(T0 - 100, "claude-opus-4-1", {key: 9_000_000 for key in TRUE_WEIGHTS})
        for file, lines in self.lines.items():
            write_jsonl(file, lines)
        write_jsonl(self.ratelimit, [json.dumps(record) for record in self.records])
        return self


class CalibrateCase(FixtureCase):
    def calibrate(self, *args):
        result = self.run_cli("calibrate", "--projects", str(self.root / "projects"), *args)
        return result

    def calibrate_json(self, *args):
        result = self.calibrate("--json", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_recovers(self, weights):
        for key, expected in TRUE_WEIGHTS.items():
            with self.subTest(key=key):
                self.assertLessEqual(abs(weights[key] - expected) / expected, 0.10, weights)


class CalibrateTest(CalibrateCase):
    def test_recovers_known_weights_within_ten_percent(self):
        Synthetic(self.root).window(40).write()
        data = self.calibrate_json()
        self.assertEqual(data["status"], "ok")
        self.assertEqual(data["intervals"], 40)
        self.assertEqual(data["min_intervals"], 30)
        self.assertEqual(data["weights"]["input"], 1)
        self.assert_recovers(data["weights"])
        self.assertGreater(data["r2"], 0.95)
        self.assertAlmostEqual(data["percent_per_mtok"]["input"], PERCENT_PER_INPUT * 1e6, delta=0.4)

    def test_intervals_across_windows_and_reset_boundaries(self):
        Synthetic(self.root).window(20).window(20, start_percent=0.5).write()
        data = self.calibrate_json()
        self.assertEqual(data["intervals"], 40)
        self.assertEqual(data["skipped"]["window_change"], 1)
        self.assert_recovers(data["weights"])

    def test_insufficient_intervals_do_not_estimate(self):
        Synthetic(self.root).window(12).write()
        data = self.calibrate_json()
        self.assertEqual(data["status"], "insufficient_data")
        self.assertEqual(data["intervals"], 12)
        self.assertIsNone(data["weights"])
        text = self.calibrate()
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn("データ不足", text.stdout)
        self.assertIn("12", text.stdout)
        self.assertEqual(self.calibrate_json("--min-intervals", "10")["status"], "ok")

    def test_no_records(self):
        data = self.calibrate_json()
        self.assertEqual((data["status"], data["intervals"], data["records"]), ("insufficient_data", 0, 0))

    def test_since_filters_records(self):
        Synthetic(self.root).window(40).write()
        self.assertEqual(self.calibrate_json("--since", "2025-06-15")["intervals"], 40)
        self.assertEqual(self.calibrate_json("--since", "2025-06-16")["intervals"], 0)
        self.assertEqual(self.calibrate("--since", "6/16").returncode, 2)

    def test_text_output_shows_weights(self):
        Synthetic(self.root).window(40).write()
        result = self.calibrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("区間 40", result.stdout)
        self.assertIn("cache_read", result.stdout)
        self.assertIn("決定係数", result.stdout)

    def test_by_model_splits_only_with_enough_data(self):
        Synthetic(self.root).window(35, model="claude-opus-4-1").window(
            35, model="claude-sonnet-4-5", scale=0.2).window(5, model="claude-haiku-4-5", scale=0.05).write()
        data = self.calibrate_json()
        by_model = data["by_model"]
        self.assertEqual(sorted(by_model), ["haiku", "opus", "sonnet"])
        self.assertEqual((by_model["opus"]["status"], by_model["opus"]["intervals"]), ("ok", 35))
        self.assertEqual(by_model["sonnet"]["status"], "ok")
        self.assertEqual((by_model["haiku"]["status"], by_model["haiku"]["intervals"]), ("insufficient_data", 5))
        self.assertIsNone(by_model["haiku"]["weights"])
        self.assert_recovers(by_model["opus"]["weights"])
        self.assert_recovers(by_model["sonnet"]["weights"])
        ratio = by_model["sonnet"]["percent_per_mtok"]["output"] / by_model["opus"]["percent_per_mtok"]["output"]
        self.assertAlmostEqual(ratio, 0.2, delta=0.02)

    def test_duplicate_request_across_files_is_counted_once(self):
        synthetic = Synthetic(self.root).window(40)
        # 再開したセッションのように、同じ requestId の行が別ファイルにもある場合。
        copied = [line for line in synthetic.lines[synthetic.files[0]][:20]]
        synthetic.lines[self.root / "projects" / "-home-c" / "resumed.jsonl"] = copied
        synthetic.write()
        self.assert_recovers(self.calibrate_json()["weights"])


class IntervalTest(unittest.TestCase):
    @staticmethod
    def records(*items):
        return [{"ts": float(ts), "pct": pct, "reset": reset} for ts, pct, reset in items]

    def test_consecutive_records_in_same_window(self):
        records = self.records((0, 1, 100), (10, 2, 100), (20, 2, 130), (30, 1, 100), (40, 5, 9000), (50, 6, 9000))
        intervals, skipped = METRICS.build_intervals(records)
        # resets_at の 60 秒以内の揺れは同じ枠、減少と枠の切り替わりは区間にしない。
        self.assertEqual([(i["start"], i["end"], i["delta"]) for i in intervals],
                         [(0, 10, 1), (10, 20, 0), (40, 50, 1)])
        self.assertEqual(skipped, {"window_change": 1, "negative_delta": 1})

    def test_min_delta_merges_until_threshold(self):
        records = self.records((0, 1, 100), (10, 2, 100), (20, 3, 100), (30, 4, 100), (40, 5, 100),
                               (50, 6, 900), (60, 9, 900))
        intervals, _ = METRICS.build_intervals(records, min_delta=2)
        self.assertEqual([(i["start"], i["end"], i["delta"]) for i in intervals],
                         [(0, 20, 2), (20, 40, 2), (50, 60, 3)])

    def test_cli_rejects_negative_min_delta(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            METRICS.main(["calibrate", "--min-delta", "-1"])


class CalibrateWriteTest(CalibrateCase):
    def config(self):
        return self.root / "config" / "claude-token-metrics" / "weights.json"

    def test_does_not_write_by_default(self):
        Synthetic(self.root).window(40).write()
        self.calibrate_json()
        self.assertFalse(self.config().exists())

    def test_write_saves_weights_and_basis(self):
        Synthetic(self.root).window(40).write()
        self.config().parent.mkdir(parents=True)
        self.config().write_text(json.dumps({"weights": {"output": 9}, "memo": "keep"}))
        result = self.calibrate("--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = json.loads(self.config().read_text())
        self.assertEqual(saved["memo"], "keep")
        self.assertEqual(saved["weights"]["input"], 1)
        self.assert_recovers(saved["weights"])
        self.assertEqual(saved["calibration"]["intervals"], 40)
        self.assertIn("r2", saved["calibration"])
        weights, source = METRICS.load_weights(path=self.config())
        self.assertEqual(source, str(self.config()))
        self.assertEqual(weights, saved["weights"])

    def test_write_refuses_without_estimate(self):
        Synthetic(self.root).window(5).write()
        result = self.calibrate("--write")
        self.assertEqual(result.returncode, 1)
        self.assertIn("データ不足", result.stdout + result.stderr)
        self.assertFalse(self.config().exists())


class NnlsTest(unittest.TestCase):
    def test_exact_solution(self):
        columns = [[1, 0, 1, 2], [0, 1, 1, 1]]
        y = [2, 3, 5, 7]
        self.assertEqual([round(value, 9) for value in METRICS.nnls(columns, y)], [2, 3])

    def test_negative_coefficient_is_clamped_to_zero(self):
        # 制約なしの最小二乗では y = c1 - c2（2 列目が -1）になる。非負なら c2 = 0、c1 = 平均 2/3。
        columns = [[1, 1, 1], [1, 0, 0]]
        y = [0, 1, 1]
        solution = METRICS.nnls(columns, y)
        self.assertEqual(solution[1], 0)
        self.assertAlmostEqual(solution[0], 2 / 3)

    def test_all_zero_target(self):
        self.assertEqual(METRICS.nnls([[1, 2], [3, 4]], [0, 0]), [0, 0])


if __name__ == "__main__":
    unittest.main()
