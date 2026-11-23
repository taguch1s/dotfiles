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


# ---------------------------------------------------------------- 偽の gcloud

# 呼び出しを calls.jsonl に記録し、VM を FAKE_GCLOUD_DIR/vm/<名前>/ のディレクトリで真似る。
# ssh は --command をそのディレクトリで bash -c し、scp は user@<名前>:path をそのディレクトリの path に読み替える。
# 振る舞いはファイルで変える: fail_create（中身がエラー）、scp_fail、setup_fails、ignore_filter。
FAKE_GCLOUD = r'''
import json, os, shutil, signal, subprocess, sys
from pathlib import Path

root = Path(os.environ["FAKE_GCLOUD_DIR"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"args": args, "cloudsdk_config": os.environ.get("CLOUDSDK_CONFIG")}) + "\n")
inst_file = root / "instances.json"
insts = json.loads(inst_file.read_text()) if inst_file.exists() else {}


def save():
    inst_file.write_text(json.dumps(insts))


def opt(name):
    for a in args:
        if a.startswith(f"--{name}="):
            return a.split("=", 1)[1]
    return None


def fail(msg, code=1):
    sys.stderr.write(f"ERROR: {msg}\n")
    sys.exit(code)


def vm(name):
    return root / "vm" / name


def local_path(spec):
    if "@" in spec and ":" in spec:
        target, path = spec.split(":", 1)
        name = target.split("@", 1)[1]
        if name not in insts:
            fail(f"The resource '{name}' was not found", 255)
        return vm(name) / path
    return Path(spec)


pos = [a for a in args if not a.startswith("--")]
if pos[:3] == ["compute", "instances", "create"]:
    name = pos[3]
    if (root / "fail_create").exists():
        fail((root / "fail_create").read_text())
    labels = dict(kv.split("=", 1) for kv in opt("labels").split(","))
    insts[name] = {"name": name, "zone": "projects/p/zones/" + opt("zone"), "labels": labels, "status": "RUNNING"}
    save()
    vm(name).mkdir(parents=True)
    if (root / "setup_fails").exists():
        (vm(name) / "failed").write_text("E: apt failed\n")
    else:
        (vm(name) / ".ready").touch()
elif pos[:3] == ["compute", "instances", "delete"]:
    name = pos[3]
    if name not in insts:
        fail(f"The resource 'projects/p/zones/z/instances/{name}' was not found")
    del insts[name]
    save()
    for pid in vm(name).glob("hc-remote/*/pid"):
        try:
            os.killpg(int(pid.read_text()), signal.SIGKILL)
        except (ProcessLookupError, ValueError, PermissionError):
            pass
    if vm(name).exists():
        vm(name).rename(root / "vm" / f"{name}.deleted")
elif pos[:3] == ["compute", "instances", "describe"]:
    if pos[3] not in insts:
        fail(f"The resource '{pos[3]}' was not found")
    print(insts[pos[3]]["status"])
elif pos[:3] == ["compute", "instances", "list"]:
    items = list(insts.values())
    if opt("filter") == "labels.hc-remote=1" and not (root / "ignore_filter").exists():
        items = [i for i in items if (i.get("labels") or {}).get("hc-remote") == "1"]
    print(json.dumps(items))
elif pos[:2] == ["compute", "ssh"]:
    name = pos[2].split("@", 1)[1]
    if name not in insts:
        fail(f"The resource '{name}' was not found", 255)
    if not Path(opt("ssh-key-file")).exists():
        fail("no key", 255)
    env = dict(os.environ, HC_REMOTE_READY=str(vm(name) / ".ready"))
    proc = subprocess.run(["bash", "-c", opt("command")], cwd=vm(name), env=env)
    sys.exit(proc.returncode)
elif pos[:2] == ["compute", "scp"]:
    if (root / "scp_fail").exists():
        fail("scp failed", 1)
    *srcs, dest = pos[2:]
    dest_path = local_path(dest)
    for src in srcs:
        src_path = local_path(src)
        if not src_path.exists():
            fail(f"scp: {src}: No such file or directory")
        target = dest_path / src_path.name if dest.endswith("/") else dest_path
        shutil.copyfile(src_path, target)
else:
    fail(f"fake gcloud does not know: {args}", 2)
'''


# ---------------------------------------------------------------- 準備


def budget_of(statuses, name):
    (status,) = [s for s in statuses if s["backend"] == name]
    return status


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
        # 本物の ~/.config/hc-remote/gcloud（GCP の資格情報）を使わない
        (self.tmp / "home").mkdir()
        env = mock.patch.dict(
            os.environ,
            {
                "HOME": str(self.tmp / "home"),
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
        code, _, err = self.run_cli("run", "--backend", "modal", "--", "true", sdk=sdk)
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("無料枠を超える", err)
        self.assertEqual(sdk.spawned, [])
        self.assertEqual(self.records(), {})

    def test_auto_runs_locally_when_no_remote_fits(self):
        # modal は無料枠を超え、gcp は gcloud の設定が無い（HOME は空）→ 止めずに手元で実行し、記録に残す
        sdk = self.sdk(report=[26.95])
        code, out, err = self.run_cli("run", "--", "echo local-ran; exit 4", sdk=sdk)
        self.assertEqual(code, 4, err)
        self.assertIn("local-ran", out)
        self.assertIn("手元（local）で実行する", err)
        self.assertEqual(sdk.spawned, [])
        (record,) = self.records().values()
        self.assertEqual(record["backend"], "local")
        self.assertIn("modal: 無料枠を超える", record["fallback_reason"])
        self.assertIn("gcp: gcloud", record["fallback_reason"])

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
        code, _, err = self.run_cli("run", "--backend", "modal", "--", "true", sdk=sdk)
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("手元の記録からの見積もり", err)
        self.assertIn("not on this plan", err)

        code, out, _ = self.run_cli("budget", "--json", sdk=sdk)
        self.assertEqual(code, 0)
        status = budget_of(json.loads(out), "modal")
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
        status = budget_of(json.loads(out), "modal")
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


# ---------------------------------------------------------------- GCP（偽の gcloud）と予算、auto の順


class GcpTest(Base):
    def setUp(self):
        super().setUp()
        self.fake = self.tmp / "fake-gcloud"
        self.fake.mkdir()
        self.gcloud = self.tmp / "gcloud"
        self.gcloud.write_text(f"#!{sys.executable}\n" + FAKE_GCLOUD)
        self.gcloud.chmod(0o755)
        self.sdk_config = self.tmp / "hc-remote-gcloud"
        self.sdk_config.mkdir()
        self.write_config(f'[gcp]\ngcloud = "{self.gcloud}"\ncloudsdk_config = "{self.sdk_config}"\n')
        env = mock.patch.dict(os.environ, {"FAKE_GCLOUD_DIR": str(self.fake)})
        env.start()
        self.addCleanup(env.stop)
        fast = mock.patch.object(HC.GcpBackend, "poll_interval", 0.05)
        fast.start()
        self.addCleanup(fast.stop)

    def calls(self, *prefix):
        path = self.fake / "calls.jsonl"
        if not path.exists():
            return []
        calls = [json.loads(line) for line in path.read_text().splitlines()]
        return [c for c in calls if [a for a in c["args"] if not a.startswith("--")][: len(prefix)] == list(prefix)]

    def instances(self):
        path = self.fake / "instances.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def add_record(self, job_id, backend="gcp", status="done", est=0.0, **extra):
        HC.Store(self.state).append(
            {"event": "launch", "id": job_id, "backend": backend, "status": status, "created_at": HC.iso(NOW),
             "cpu": 1, "memory_gb": 1, "est_usd": est, **extra}
        )

    # ---- 見積もりと予算

    def test_machine_type_and_estimate(self):
        backend = HC.GcpBackend(HC.load_config(), self.state)
        self.assertEqual(backend.machine(2, 4).type, "e2-highcpu-4")  # 2 コア = 4 vCPU
        self.assertEqual(backend.machine(0.25, 0.5).type, "e2-custom-2-1024")  # 最小 2 vCPU、1 vCPU あたり 0.5 GB 以上
        self.assertEqual(backend.machine(1, 32).type, "e2-highmem-4")  # 1 vCPU あたり 8 GB まで
        self.assertEqual(backend.machine(8, 32).type, "e2-custom-16-32768")  # 上限いっぱいでも quota の 16 vCPU に収まる
        m = backend.machine(2, 4)
        self.assertAlmostEqual(m.hour_usd, 4 * 0.02 + 4 * 0.0027 + 0.01)
        spec = HC.Spec("x", [], 2, 4, 1800)
        self.assertEqual(backend.max_run_s(spec), 1800 + HC.GRACE_S + 600)
        self.assertAlmostEqual(backend.estimate_max_usd(spec), m.hour_usd * (1800 + HC.GRACE_S + 600 + HC.GCP_CREATE_S) / 3600)
        # 終わったジョブの課金は VM の生存時間で、--max-run-duration より長くは数えない
        record = {"created_at": HC.iso(NOW), "handle": {"created_epoch": NOW.timestamp() - 86400 * 3, "max_run_s": 2700}}
        self.assertEqual(backend.billed_seconds(record, {}, NOW, final=True), 2700 + HC.GCP_CREATE_S)
        self.assertEqual(backend.billed_seconds(record, {}, NOW, final=False), 2700 + HC.GCP_CREATE_S)
        record["handle"]["created_epoch"] = NOW.timestamp() - 600
        self.assertEqual(backend.billed_seconds(record, {}, NOW, final=True), 600 + HC.GCP_CREATE_S / 2)
        limit, info, _ = backend.budget_limit()
        self.assertAlmostEqual(limit, 1000 / 170)
        self.assertEqual(info["monthly_budget_jpy"], 1000)

    def test_over_the_budget_refuses_gcp_without_creating_a_vm(self):
        # 枠 1000 円 ÷ 170 = $5.88。今月の記録 $5.85 + 既定のジョブの最大（約 $0.08）で超える。先月の分は数えない
        self.add_record("g1", est=5.85)
        HC.Store(self.state).append({"event": "launch", "id": "old", "backend": "gcp", "status": "done",
                                     "created_at": "2026-10-31T00:00:00+00:00", "est_usd": 100})
        code, _, err = self.run_cli("run", "--backend", "gcp", "--", "true")
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("gcp: 予算を超える", err)
        self.assertIn("円", err)
        self.assertEqual(self.calls("compute", "instances", "create"), [])

        sdk = FakeModal(self.tmp, report=[])
        code, out, _ = self.run_cli("budget", "--json", sdk=sdk)
        status = budget_of(json.loads(out), "gcp")
        self.assertEqual(status["source"], "local")
        self.assertEqual(status["used_usd"], 5.85)
        self.assertEqual(status["monthly_budget_jpy"], 1000)
        code, out, _ = self.run_cli("budget", sdk=sdk)
        self.assertIn("月の予算 1000 円", out)
        self.assertIn("使用額: $5.85（約 994 円）", out)

    # ---- 起動・実行・後始末

    def test_run_creates_a_spot_vm_runs_brings_back_and_deletes_it(self):
        code, out, err = self.run_cli(
            "run", "--backend", "gcp", "--cpu", "2", "--memory", "4", "--timeout", "10m", "--out", "out", "--",
            "cat tracked.txt; test ! -e ignored.txt && echo no-ignored; mkdir -p out && echo hi > out/x; exit 3",
        )
        self.assertEqual(code, 3, err)
        self.assertIn("tracked", out)
        self.assertIn("no-ignored", out)
        self.assertEqual((self.repo / "out" / "x").read_text(), "hi\n")
        (record,) = self.records().values()
        job = record["id"]
        name = f"hc-remote-{job}"
        ((create),) = self.calls("compute", "instances", "create")
        args = create["args"]
        self.assertEqual(create["cloudsdk_config"], str(self.sdk_config))
        for flag in (
            "--provisioning-model=SPOT",
            "--instance-termination-action=DELETE",
            f"--max-run-duration={600 + HC.GRACE_S + 600}s",
            "--no-service-account",
            "--no-scopes",
            "--tags=hc-remote",
            "--zone=asia-northeast1-a",
            "--project=first-impression-490413",
            "--machine-type=e2-highcpu-4",
            "--image-family=debian-12",
            "--image-project=debian-cloud",
        ):
            self.assertIn(flag, args)
        self.assertEqual(args[3], name)
        labels = dict(kv.split("=", 1) for kv in next(a for a in args if a.startswith("--labels=")).split("=", 1)[1].split(","))
        self.assertEqual(labels["hc-remote"], "1")
        self.assertEqual(labels["hc-remote-job"], job)
        self.assertEqual(int(labels["hc-remote-deadline"]), record["handle"]["deadline_epoch"])
        metadata = next(a for a in args if a.startswith("--metadata="))
        self.assertIn("block-project-ssh-keys=TRUE", metadata)
        self.assertIn("ssh-keys=hcremote:ssh-ed25519 ", metadata)
        for call in self.calls("compute", "ssh") + self.calls("compute", "scp"):
            self.assertIn("--tunnel-through-iap", call["args"])
        # 成功しても VM を消し、一時鍵も消す。ログは手元に残す
        self.assertEqual(self.instances(), {})
        self.assertEqual(len(self.calls("compute", "instances", "delete")), 1)
        self.assertFalse(Path(record["handle"]["key"]).exists())
        self.assertEqual(record["status"], "done")
        self.assertEqual(record["backend"], "gcp")
        self.assertGreater(record["est_usd"], 0)
        self.assertLess(record["est_usd"], record["max_usd"])
        code, out, _ = self.run_cli("logs", job)
        self.assertIn("no-ignored", out)

    def test_vm_is_deleted_when_the_setup_fails(self):
        (self.fake / "setup_fails").write_text("")
        code, out, err = self.run_cli("run", "--backend", "gcp", "--", "echo never")
        self.assertEqual(code, HC.EXIT_INFRA, err)
        self.assertIn("VM の準備", err)
        self.assertNotIn("never", out)
        (record,) = self.records().values()
        self.assertEqual(record["status"], "error")
        self.assertEqual(self.instances(), {})
        self.assertEqual(len(self.calls("compute", "instances", "delete")), 1)

    def test_vm_is_deleted_when_sending_fails_during_launch(self):
        (self.fake / "scp_fail").write_text("")
        code, _, err = self.run_cli("run", "--backend", "gcp", "--", "true")
        self.assertEqual(code, HC.EXIT_INFRA, err)
        self.assertIn("VM へ送れない", err)
        self.assertIn("VM hc-remote-", err)
        self.assertEqual(self.instances(), {})
        self.assertEqual(len(self.calls("compute", "instances", "delete")), 1)
        # VM を作った後の失敗は、枠に数えるため記録に残す
        (record,) = self.records().values()
        self.assertEqual(record["status"], "error")
        self.assertGreater(record["est_usd"], 0)

    def test_vm_is_deleted_when_the_run_is_interrupted(self):
        with mock.patch.object(HC.time, "sleep", side_effect=KeyboardInterrupt):
            code, _, err = self.run_cli("run", "--backend", "gcp", "--", "sleep 3")
        self.assertEqual(code, 130, err)
        self.assertIn("後始末", err)
        self.assertEqual(self.instances(), {})
        (record,) = self.records().values()
        self.assertEqual(record["status"], "cancelled")
        self.assertTrue(record["fetched"])

    def test_vm_is_deleted_when_interrupted_while_creating(self):
        real = HC.GcpBackend.ssh

        def interrupt(backend, handle, command, timeout=120):
            raise KeyboardInterrupt

        with mock.patch.object(HC.GcpBackend, "ssh", interrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.run_cli("run", "--backend", "gcp", "--", "true")
        self.assertIsNotNone(real)
        self.assertEqual(len(self.calls("compute", "instances", "create")), 1)
        self.assertEqual(self.instances(), {})
        self.assertEqual(self.records(), {})

    def test_cancel_deletes_the_vm(self):
        self.instances_file = self.fake / "instances.json"
        self.instances_file.write_text(json.dumps({"hc-remote-j": {"name": "hc-remote-j", "labels": {"hc-remote": "1"}, "status": "RUNNING"}}))
        key = self.tmp / "k" / "id"
        key.parent.mkdir()
        key.write_text("")
        self.add_record("j", status="running", handle={"instance": "hc-remote-j", "zone": "asia-northeast1-a", "key": str(key),
                                                     "deadline_epoch": time.time() + 3600, "max_run_s": 600})
        code, _, _ = self.run_cli("cancel", "j")
        self.assertEqual(code, 0)
        self.assertEqual(self.instances(), {})
        code, _, _ = self.run_cli("wait", "j")
        self.assertEqual(self.records()["j"]["status"], "cancelled")

    # ---- auto の順

    def test_auto_uses_modal_first_within_the_free_credit(self):
        sdk = FakeModal(self.tmp, report=[1.0])
        code, _, err = self.run_cli("run", "--", "true", sdk=sdk)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(sdk.spawned), 1)
        self.assertEqual(self.calls("compute", "instances", "create"), [])

    def test_auto_uses_gcp_when_modal_is_over_the_free_credit(self):
        sdk = FakeModal(self.tmp, report=[26.95])
        code, out, err = self.run_cli("run", "--", "echo on-gcp", sdk=sdk)
        self.assertEqual(code, 0, err)
        self.assertIn("on-gcp", out)
        self.assertEqual(sdk.spawned, [])
        (record,) = self.records().values()
        self.assertEqual(record["backend"], "gcp")
        self.assertNotIn("fallback_reason", record)
        self.assertEqual(self.instances(), {})

    def test_auto_runs_locally_when_both_are_over(self):
        sdk = FakeModal(self.tmp, report=[26.95])
        self.add_record("g1", est=5.85)
        code, out, err = self.run_cli("run", "--", "echo here; exit 5", sdk=sdk)
        self.assertEqual(code, 5, err)
        self.assertIn("here", out)
        self.assertIn("手元（local）で実行する", err)
        self.assertEqual(self.calls("compute", "instances", "create"), [])
        record = [r for r in self.records().values() if r["id"] != "g1"][0]
        self.assertEqual(record["backend"], "local")
        self.assertIn("modal: 無料枠を超える", record["fallback_reason"])
        self.assertIn("gcp: 予算を超える", record["fallback_reason"])

    def test_auto_runs_locally_when_the_vm_cannot_be_created(self):
        sdk = FakeModal(self.tmp, report=[26.95])
        (self.fake / "fail_create").write_text("Quota 'CPUS' exceeded")
        code, _, err = self.run_cli("run", "--", "true", sdk=sdk)
        self.assertEqual(code, 0, err)
        (record,) = self.records().values()
        self.assertEqual(record["backend"], "local")
        self.assertIn("VM を作れない", record["fallback_reason"])
        self.assertIn("Quota", record["fallback_reason"])

    def test_auto_still_refuses_over_the_limits_and_secrets(self):
        sdk = FakeModal(self.tmp, report=[26.95])
        code, _, err = self.run_cli("run", "--cpu", "9", "--", "true", sdk=sdk)
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("max_cpu", err)
        (self.repo / ".env").write_text("TOKEN=x\n")
        code, _, err = self.run_cli("run", "--", "true", sdk=sdk)
        self.assertEqual(code, HC.EXIT_REFUSED)
        self.assertIn("秘密情報", err)
        self.assertEqual(self.records(), {})
        self.assertEqual(self.calls("compute", "instances", "create"), [])

    # ---- gc

    def gc_fixture(self):
        future, past = str(int(NOW.timestamp()) + 3600), str(int(NOW.timestamp()) - 60)

        def inst(name, labels):
            return {"name": name, "zone": "projects/p/zones/asia-northeast1-a", "labels": labels, "status": "RUNNING"}

        (self.fake / "instances.json").write_text(json.dumps({
            "hc-remote-a": inst("hc-remote-a", {"hc-remote": "1", "hc-remote-job": "ja", "hc-remote-deadline": future}),
            "hc-remote-b": inst("hc-remote-b", {"hc-remote": "1", "hc-remote-job": "jb", "hc-remote-deadline": future}),
            "hc-remote-c": inst("hc-remote-c", {"hc-remote": "1", "hc-remote-job": "jc", "hc-remote-deadline": past}),
            "hc-remote-e": inst("hc-remote-e", {"hc-remote": "1", "hc-remote-job": "je", "hc-remote-deadline": past}),
            "hc-remote-f": inst("hc-remote-f", {"hc-remote": "1", "hc-remote-job": "jf", "hc-remote-deadline": future}),
            "hc-remote-d": inst("hc-remote-d", {"hc-remote-job": "jd", "hc-remote-deadline": past}),
            "ts-crawler-x": inst("ts-crawler-x", {}),
            "ts-crawler-y": inst("ts-crawler-y", {"hc-remote": "1"}),
        }))
        self.add_record("ja", status="done", fetched=True)
        self.add_record("jb", status="running", max_usd=0.1)
        self.add_record("je", status="running", max_usd=0.2)
        self.add_record("jf", status="done")  # 別の ls が終わりに気づいただけで、まだ持ち帰っていない

    def test_gc_deletes_only_labelled_finished_or_expired_vms(self):
        self.gc_fixture()
        (self.fake / "ignore_filter").write_text("")  # 偽の gcloud が filter を無視しても、ラベルと名前で絞る
        code, out, _ = self.run_cli("gc", "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(self.calls("compute", "instances", "delete"), [])
        self.assertIn("消す予定: hc-remote-a", out)

        code, out, _ = self.run_cli("gc")
        self.assertEqual(code, 0, out)
        (listed,) = {tuple(c["args"]) for c in self.calls("compute", "instances", "list")}
        self.assertIn("--filter=labels.hc-remote=1", listed)
        deleted = sorted(c["args"][3] for c in self.calls("compute", "instances", "delete"))
        self.assertEqual(deleted, ["hc-remote-a", "hc-remote-c", "hc-remote-e"])
        self.assertEqual(sorted(self.instances()), ["hc-remote-b", "hc-remote-d", "hc-remote-f", "ts-crawler-x", "ts-crawler-y"])
        self.assertIn("残す: hc-remote-b", out)
        self.assertIn("hc-remote wait jf", out)
        self.assertNotIn("ts-crawler", out)
        # 実行中の記録の VM を期限切れで消したら、最大見積額で記録を閉じる
        self.assertEqual(self.records()["je"]["status"], "error")
        self.assertEqual(self.records()["je"]["est_usd"], 0.2)
        self.assertEqual(self.records()["jb"]["status"], "running")


if __name__ == "__main__":
    unittest.main()
