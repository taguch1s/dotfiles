"""hc-remote（重い処理を Modal などへ回す）を検証する。Modal SDK は偽物に差し替える。"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import types
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / ".local" / "bin" / "hc-remote"
LOADER = importlib.machinery.SourceFileLoader("hc_remote", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("hc_remote", LOADER)
HC = importlib.util.module_from_spec(SPEC)
sys.modules["hc_remote"] = HC
LOADER.exec_module(HC)

NOW = datetime(2026, 11, 23, 12, 0, tzinfo=timezone.utc)
# .bin/check-dotfiles.sh の秘密情報の検査に引っかからないよう、実行時に組み立てる
FAKE_KEY = "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nabc\n"


# ---------------------------------------------------------------- 偽の Modal SDK


class FakeNotFound(Exception):
    pass


class FakeVolume:
    def __init__(self, sdk, name):
        self.sdk = sdk
        self.name = name
        self.root = sdk.volume_root
        self.commits = 0

    def _path(self, path):
        return self.root / str(path).lstrip("/")

    @contextlib.contextmanager
    def batch_upload(self, force=False):
        volume = self

        class Batch:
            def put_file(self, src, dst):
                dest = volume._path(dst)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dest)

        yield Batch()

    def read_file(self, path):
        p = self._path(path)
        if not p.exists():
            raise FakeNotFound(path)
        return iter([p.read_bytes()])

    def remove_file(self, path, recursive=False):
        self._path(path).unlink()

    def commit(self):
        self.commits += 1


class FakeImage:
    def __init__(self, calls):
        self.calls = calls

    def apt_install(self, *pkgs):
        return FakeImage(self.calls + [("apt_install", pkgs)])

    def pip_install(self, *pkgs):
        return FakeImage(self.calls + [("pip_install", pkgs)])


class FakeCall:
    def __init__(self, sdk, object_id, value=None, error=None):
        self.sdk = sdk
        self.object_id = object_id
        self.value = value
        self.error = error
        self.cancelled = None

    def get(self, timeout=None):
        if self.error is not None:
            raise self.error
        return self.value

    def cancel(self, terminate_containers=False):
        self.cancelled = terminate_containers


class FakeFunction:
    def __init__(self, sdk, raw, options):
        self.sdk = sdk
        self.raw = raw
        self.options = options

    def spawn(self, *args):
        self.sdk.spawned.append((self.options, args))
        # コンテナの代わりに、同じ本体を偽の Volume の上で同期的に動かす
        work = Path(tempfile.mkdtemp(dir=self.sdk.tmp))
        with mock.patch.dict(sys.modules, {"modal": self.sdk}):
            value = self.raw(*args, mount=str(self.sdk.volume_root), work=str(work))
        call = FakeCall(self.sdk, f"fc-{len(self.sdk.spawned)}", value=value)
        self.sdk.calls[call.object_id] = call
        return call


class FakeApp:
    def __init__(self, sdk, name):
        self.sdk = sdk
        self.name = name

    def function(self, **options):
        return lambda raw: FakeFunction(self.sdk, raw, options)

    @contextlib.contextmanager
    def run(self, detach=False):
        self.sdk.detach.append(detach)
        yield


class FakeModal(types.SimpleNamespace):
    def __init__(self, tmp, report=None):
        super().__init__()
        self.tmp = tmp
        self.volume_root = Path(tmp) / "volume"
        self.volume_root.mkdir()
        self.spawned = []
        self.detach = []
        self.calls = {}
        self.report_calls = []
        self.report = report  # list of costs, or an Exception
        self.volumes = {}
        sdk = self

        self.exception = types.SimpleNamespace(
            NotFoundError=FakeNotFound,
            OutputExpiredError=type("OutputExpiredError", (Exception,), {}),
            TimeoutError=type("ModalTimeoutError", (Exception,), {}),
        )
        self.exception.FunctionTimeoutError = type("FunctionTimeoutError", (self.exception.TimeoutError,), {})

        class Volume:
            @staticmethod
            def from_name(name, create_if_missing=False):
                return sdk.volumes.setdefault(name, FakeVolume(sdk, name))

        class Image:
            @staticmethod
            def debian_slim(python_version=None):
                return FakeImage([("debian_slim", python_version)])

        class FunctionCall:
            @staticmethod
            def from_id(object_id):
                return sdk.calls[object_id]

        class Workspace:
            @staticmethod
            def from_context():
                def report(**kwargs):
                    sdk.report_calls.append(kwargs)
                    if isinstance(sdk.report, Exception):
                        raise sdk.report
                    return [types.SimpleNamespace(cost=Decimal(str(c))) for c in sdk.report or []]

                return types.SimpleNamespace(billing=types.SimpleNamespace(report=report))

        self.Volume = Volume
        self.Image = Image
        self.FunctionCall = FunctionCall
        self.Workspace = Workspace
        self.App = lambda name: FakeApp(sdk, name)
        self.enable_output = contextlib.nullcontext


# ---------------------------------------------------------------- 準備


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.state = self.tmp / "state"
        self.config = self.tmp / "config.toml"
        # ユーザーの全体の gitignore（.env などを無視する）に左右されないようにする
        (self.tmp / "gitconfig").write_text("")
        env = mock.patch.dict(
            os.environ,
            {
                "HC_REMOTE_STATE_DIR": str(self.state),
                "HC_REMOTE_CONFIG": str(self.config),
                "GIT_CONFIG_GLOBAL": str(self.tmp / "gitconfig"),
                "GIT_CONFIG_NOSYSTEM": "1",
            },
        )
        env.start()
        self.addCleanup(env.stop)
        # pre-commit hook の中では GIT_DIR・GIT_INDEX_FILE などが外のリポジトリを指している
        for key in [k for k in os.environ if k.startswith("GIT_") and not k.startswith("GIT_CONFIG")]:
            del os.environ[key]
        git(self.repo, "init", "-q")
        (self.repo / ".gitignore").write_text("ignored.txt\n")
        (self.repo / "tracked.txt").write_text("tracked\n")
        (self.repo / "gone.txt").write_text("gone\n")
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "init")
        (self.repo / "gone.txt").unlink()
        (self.repo / "untracked.txt").write_text("untracked\n")
        (self.repo / "ignored.txt").write_text("ignored\n")

    def write_config(self, text):
        self.config.write_text(text)

    def run_cli(self, *argv, sdk=None, now=lambda: NOW):
        out, err = io.StringIO(), io.StringIO()
        code = HC.main(list(argv), sdk=sdk, cwd=self.repo, out=out, err=err, now=now)
        return code, out.getvalue(), err.getvalue()

    def records(self):
        return HC.Store(self.state).records()


# ---------------------------------------------------------------- 値と設定


class ValuesTest(unittest.TestCase):
    def test_durations(self):
        self.assertEqual(HC.parse_duration("90s"), 90)
        self.assertEqual(HC.parse_duration("30m"), 1800)
        self.assertEqual(HC.parse_duration("1h30m"), 5400)
        self.assertEqual(HC.parse_duration("120"), 120)
        with self.assertRaises(HC.UsageError):
            HC.parse_duration("2 hours")

    def test_out_paths_stay_inside_the_worktree(self):
        self.assertEqual(HC.check_outs(["out/a.txt", "./res"]), ["out/a.txt", "res"])
        for bad in ("/etc/passwd", "../x", "a/../../b", "."):
            with self.assertRaises(HC.UsageError):
                HC.check_outs([bad])

    def test_managed_config_matches_the_defaults(self):
        with (REPO / ".config" / "hc-remote" / "config.toml").open("rb") as f:
            managed = tomllib.load(f)
        self.assertEqual(HC._merge(HC.DEFAULTS, managed, ""), HC.DEFAULTS)
        self.assertEqual(managed, HC.DEFAULTS)

    def test_unknown_config_key_is_an_error(self):
        with self.assertRaises(HC.UsageError):
            HC._merge(HC.DEFAULTS, {"limits": {"max_gpu": 1}}, "")

    def test_estimate_uses_function_prices(self):
        backend = HC.ModalBackend(HC.load_config(Path("/nonexistent")), Path("/tmp"), sdk=object())
        # 2 コア・4 GiB を 1000 秒
        self.assertAlmostEqual(backend.estimate_usd(2, 4, 1000), 1000 * (2 * 0.0000131 + 4 * 0.00000222))
        spec = HC.Spec("x", [], 8, 32, 7200)
        self.assertAlmostEqual(backend.estimate_max_usd(spec), backend.estimate_usd(8, 32, 7200 + HC.GRACE_S))
        self.assertEqual(HC.LocalBackend(HC.DEFAULTS, Path("/tmp")).estimate_max_usd(spec), 0)


# ---------------------------------------------------------------- 送るファイルと秘密情報


class FilesTest(Base):
    def test_tracked_and_unignored_untracked_files_are_sent(self):
        files, _ = HC.list_files(self.repo)
        self.assertEqual(files, [".gitignore", "tracked.txt", "untracked.txt"])

    def test_secret_names_and_contents_are_found(self):
        for name in (".env", ".env.local", "server.pem", "id_ed25519", ".modal.toml", "credentials.json"):
            (self.repo / name).write_text("x\n")
        (self.repo / "notes.txt").write_text(FAKE_KEY)
        (self.repo / "id_utils.py").write_text("x = 1\n")
        files, _ = HC.list_files(self.repo)
        found = HC.find_secrets(self.repo, files)
        joined = " ".join(found)
        for name in (".env", ".env.local", "server.pem", "id_ed25519", ".modal.toml", "credentials.json", "notes.txt"):
            self.assertIn(name, joined)
        self.assertNotIn("id_utils.py", joined)

    def test_run_stops_without_sending_when_a_secret_is_present(self):
        (self.repo / ".env").write_text("TOKEN=x\n")
        code, _, err = self.run_cli("run", "--backend", "local", "--", "true")
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("秘密情報", err)
        self.assertIn(".env", err)
        self.assertEqual(self.records(), {})
        self.assertFalse((self.state / "jobs").exists() and any((self.state / "jobs").iterdir()))


# ---------------------------------------------------------------- 上限


class LimitsTest(Base):
    def test_over_the_limits_is_refused_with_reasons(self):
        for flags, word in (
            (["--cpu", "9"], "max_cpu"),
            (["--memory", "64"], "max_memory_gb"),
            (["--timeout", "3h"], "max_timeout"),
        ):
            code, _, err = self.run_cli("run", "--backend", "local", *flags, "--", "true")
            self.assertEqual(code, HC.EXIT_REFUSED, flags)
            self.assertIn("ユーザー確認が必要", err)
            self.assertIn(word, err)
        self.assertEqual(self.records(), {})

    def test_config_lowers_the_limits(self):
        self.write_config('[limits]\nmax_cpu = 1\n')
        code, _, err = self.run_cli("run", "--backend", "local", "--cpu", "2", "--", "true")
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("max_cpu=1", err)

    def test_upload_size_limit(self):
        self.write_config('[limits]\nmax_upload_mb = 0\n')
        code, _, err = self.run_cli("run", "--backend", "local", "--", "true")
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("max_upload_mb", err)

    def test_concurrent_jobs_limit(self):
        store = HC.Store(self.state)
        for i in range(2):
            store.append(
                {
                    "event": "launch",
                    "id": f"j{i}",
                    "backend": "local",
                    "status": "running",
                    "created_at": HC.iso(NOW),
                    # 生きている pid（このプロセス）で、結果はまだ無い
                    "handle": {"pid": os.getpid(), "dir": str(self.tmp / f"none{i}")},
                }
            )
        code, _, err = self.run_cli("run", "--backend", "local", "--", "true")
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("max_concurrent_jobs=2", err)


# ---------------------------------------------------------------- local backend


class LocalRunTest(Base):
    CMD = (
        "cat tracked.txt untracked.txt; test ! -e ignored.txt && echo no-ignored; "
        "mkdir -p out && echo result > out/res.txt; echo to-stderr >&2; exit 7"
    )

    def test_run_sends_executes_streams_and_brings_back(self):
        code, out, err = self.run_cli("run", "--backend", "local", "--out", "out", "--out", "missing", "--", self.CMD)
        self.assertEqual(code, 7, err)
        for text in ("tracked", "untracked", "no-ignored", "to-stderr"):
            self.assertIn(text, out)
        self.assertEqual((self.repo / "out" / "res.txt").read_text(), "result\n")
        self.assertIn("missing", err)
        (record,) = self.records().values()
        self.assertEqual(record["status"], "done")
        self.assertEqual(record["exit_code"], 7)
        self.assertEqual(record["backend"], "local")
        self.assertTrue(record["fetched"])
        self.assertEqual(record["est_usd"], 0)
        self.assertFalse((Path(record["handle"]["dir"]) / "bundle.tar").exists())
        self.assertFalse((Path(record["handle"]["dir"]) / "work").exists())

        code, out, _ = self.run_cli("logs", record["id"])
        self.assertEqual(code, 0)
        self.assertIn("no-ignored", out)
        code, out, _ = self.run_cli("ls")
        self.assertIn(record["id"], out)

    def test_multiple_words_are_quoted(self):
        code, out, err = self.run_cli("run", "--backend", "local", "--", "printf", "%s|", "a b", "c")
        self.assertEqual(code, 0, err)
        self.assertIn("a b|c|", out)

    def test_timeout_stops_the_command(self):
        code, out, _ = self.run_cli("run", "--backend", "local", "--timeout", "1s", "--", "sleep 30")
        self.assertNotEqual(code, 0)
        (record,) = self.records().values()
        self.assertEqual(record["status"], "timeout")

    def test_cancel_and_wait(self):
        store = HC.Store(self.state)
        backend = HC.LocalBackend(HC.DEFAULTS, self.state)
        files, _ = HC.list_files(self.repo)
        bundle = store.job_dir("job1") / "bundle.tar"
        HC.make_bundle(self.repo, files, bundle)
        spec = HC.Spec("echo started; sleep 30", [], 1, 1, 60)
        handle = backend.launch("job1", spec, bundle)
        store.append(
            {"event": "launch", "id": "job1", "backend": "local", "status": "running", "created_at": HC.iso(NOW),
             "root": str(self.repo), "cmd": spec.cmd, "outs": [], "cpu": 1, "memory_gb": 1, "timeout_s": 60,
             "max_usd": 0, "handle": handle}
        )
        deadline = time.time() + 10
        while b"started" not in backend.read_log(self.records()["job1"], 0) and time.time() < deadline:
            time.sleep(0.05)
        code, _, _ = self.run_cli("cancel", "job1")
        self.assertEqual(code, 0)
        code, _, err = self.run_cli("wait", "job1")
        self.assertNotEqual(code, 0)
        self.assertEqual(self.records()["job1"]["status"], "cancelled", err)

    def test_unknown_job_is_not_handled(self):
        for command in ("logs", "wait", "cancel"):
            code, _, err = self.run_cli(command, "someone-elses-call")
            self.assertEqual(code, HC.EXIT_USAGE)
            self.assertIn("記録にありません", err)


# ---------------------------------------------------------------- Modal（偽物）と無料枠


class ModalTest(Base):
    def sdk(self, report=None):
        return FakeModal(self.tmp, report=report)

    def test_launch_uses_a_detached_serialized_function_with_capped_resources(self):
        sdk = self.sdk(report=[1.25, 2.5])
        code, out, err = self.run_cli(
            "run", "--cpu", "2", "--memory", "4", "--timeout", "10m", "--out", "out", "--",
            "mkdir -p out && echo hi > out/x && echo remote-log",
            sdk=sdk,
        )
        self.assertEqual(code, 0, err)
        self.assertIn("remote-log", out)
        self.assertEqual((self.repo / "out" / "x").read_text(), "hi\n")
        ((options, args),) = sdk.spawned
        self.assertTrue(options["serialized"])
        self.assertEqual(options["retries"], 0)
        self.assertEqual(options["cpu"], (2.0, 2.0))
        self.assertEqual(options["memory"], (4096, 4096))
        self.assertEqual(options["timeout"], 600 + HC.GRACE_S)
        self.assertEqual(list(options["volumes"]), [HC.MOUNT])
        self.assertEqual(options["image"].calls[0], ("debian_slim", "3.12"))
        self.assertIn(("apt_install", ("git", "build-essential", "curl", "ca-certificates")), options["image"].calls)
        self.assertEqual(sdk.detach, [True])
        self.assertEqual(args[1]["timeout_s"], 600)
        self.assertEqual(args[2], "hc-remote")
        self.assertGreater(sdk.volumes["hc-remote"].commits, 0)
        # billing report を今月の月初から時間単位で取った
        (call,) = sdk.report_calls
        self.assertEqual(call["start"], datetime(2026, 11, 1, tzinfo=timezone.utc))
        self.assertEqual(call["resolution"], "h")
        self.assertIn("billing report", err)
        (record,) = self.records().values()
        self.assertEqual(record["backend"], "modal")
        self.assertEqual(record["handle"]["call_id"], "fc-1")
        self.assertGreater(record["est_usd"], 0)
        # Volume に送った bundle と持ち帰ったものは消し、ログと結果は残す
        job = sdk.volume_root / "jobs" / record["id"]
        self.assertFalse((job / "bundle.tar").exists())
        self.assertFalse((job / "out.tar").exists())
        self.assertTrue((job / "log").exists())

    def test_report_over_the_free_credit_refuses_modal(self):
        # 枠は 30 − 3 = 27。使用 26.95 + 既定のジョブ（2 コア・4 GiB・30 分 + 猶予、約 $0.07）の最大で超える
        sdk = self.sdk(report=[26.95])
        code, _, err = self.run_cli("run", "--", "true", sdk=sdk)
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("無料枠を超える", err)
        self.assertIn("次の backend は無い", err)
        self.assertEqual(sdk.spawned, [])
        self.assertEqual(self.records(), {})

    def test_report_within_the_free_credit_allows_modal(self):
        sdk = self.sdk(report=[26.5])
        code, _, err = self.run_cli("run", "--", "true", sdk=sdk)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(sdk.spawned), 1)

    def test_local_estimate_is_used_when_the_report_fails(self):
        sdk = self.sdk(report=RuntimeError("not on this plan"))
        store = HC.Store(self.state)
        store.append({"event": "launch", "id": "old", "backend": "modal", "status": "done",
                      "created_at": "2026-11-02T00:00:00+00:00", "est_usd": 26.95, "cpu": 1, "memory_gb": 1})
        store.append({"event": "launch", "id": "lastmonth", "backend": "modal", "status": "done",
                      "created_at": "2026-10-30T00:00:00+00:00", "est_usd": 100, "cpu": 1, "memory_gb": 1})
        code, _, err = self.run_cli("run", "--", "true", sdk=sdk)
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("手元の記録からの見積もり", err)
        self.assertIn("not on this plan", err)

        code, out, _ = self.run_cli("budget", "--json", sdk=sdk)
        self.assertEqual(code, 0)
        status = json.loads(out)
        self.assertEqual(status["source"], "local")
        self.assertEqual(status["used_usd"], 26.95)
        self.assertEqual(status["limit_usd"], 27.0)
        self.assertEqual([j["id"] for j in status["jobs"]], ["old"])

    def test_budget_from_the_report_counts_running_jobs(self):
        sdk = self.sdk(report=[4, 1.5])
        store = HC.Store(self.state)
        sdk.calls["fc-run"] = FakeCall(sdk, "fc-run", error=sdk.exception.TimeoutError())
        store.append({"event": "launch", "id": "r", "backend": "modal", "status": "running",
                      "created_at": HC.iso(NOW), "max_usd": 1.0, "cpu": 1, "memory_gb": 1,
                      "handle": {"call_id": "fc-run", "volume": "hc-remote", "app": "hc-remote"}})
        code, out, _ = self.run_cli("budget", "--json", sdk=sdk)
        self.assertEqual(code, 0)
        status = json.loads(out)
        self.assertEqual(status["source"], "report")
        self.assertEqual(status["used_usd"], 5.5)
        self.assertEqual(status["running_reserved_usd"], 1.0)
        self.assertEqual(status["remaining_usd"], 20.5)
        code, out, _ = self.run_cli("budget", sdk=sdk)
        self.assertIn("残り: $20.50", out)

    def test_modal_cancel_terminates_the_call(self):
        sdk = self.sdk(report=[])
        call = FakeCall(sdk, "fc-x", error=sdk.exception.TimeoutError())
        sdk.calls["fc-x"] = call
        HC.Store(self.state).append({"event": "launch", "id": "m", "backend": "modal", "status": "running",
                                     "created_at": HC.iso(NOW), "cpu": 1, "memory_gb": 1,
                                     "handle": {"call_id": "fc-x", "volume": "hc-remote", "app": "hc-remote"}})
        code, _, _ = self.run_cli("cancel", "m", sdk=sdk)
        self.assertEqual(code, 0)
        self.assertTrue(call.cancelled)


if __name__ == "__main__":
    unittest.main()
