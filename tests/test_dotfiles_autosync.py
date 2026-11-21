"""dotfiles-autosync（セッション開始時の dotfiles 自動同期）を検証する。"""

import fcntl
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / ".local" / "bin" / "dotfiles-autosync"
MANAGER = REPO / ".bin" / "manage-dotfiles-configs.py"
LOADER = importlib.machinery.SourceFileLoader("dotfiles_autosync", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("dotfiles_autosync", LOADER)
AUTOSYNC = importlib.util.module_from_spec(SPEC)
sys.modules["dotfiles_autosync"] = AUTOSYNC
LOADER.exec_module(AUTOSYNC)


class BlockedReasonTest(unittest.TestCase):
    def test_clean_main_may_update(self):
        self.assertIsNone(AUTOSYNC.blocked_reason("main", dirty=False, repo="/r"))

    def test_other_branch_is_blocked(self):
        reason = AUTOSYNC.blocked_reason("feature/x", dirty=False, repo="/r")
        self.assertIn("feature/x", reason)
        self.assertIn("main", reason)

    def test_detached_head_is_blocked(self):
        self.assertIn("detached", AUTOSYNC.blocked_reason(None, dirty=False, repo="/r"))

    def test_uncommitted_changes_are_blocked(self):
        self.assertIn("未コミット", AUTOSYNC.blocked_reason("main", dirty=True, repo="/r"))


class ClassifyTest(unittest.TestCase):
    def test_same_commit_is_up_to_date(self):
        self.assertEqual(AUTOSYNC.classify("a", "a", head_in_upstream=True, upstream_in_head=True), "up_to_date")

    def test_upstream_descendant_fast_forwards(self):
        self.assertEqual(AUTOSYNC.classify("a", "b", head_in_upstream=True, upstream_in_head=False), "fast_forward")

    def test_local_commits_only_are_ahead(self):
        self.assertEqual(AUTOSYNC.classify("b", "a", head_in_upstream=False, upstream_in_head=True), "ahead")

    def test_both_sides_moved_is_diverged(self):
        self.assertEqual(AUTOSYNC.classify("b", "c", head_in_upstream=False, upstream_in_head=False), "diverged")


class IntervalTest(unittest.TestCase):
    def test_first_run_is_due(self):
        self.assertTrue(AUTOSYNC.is_due(now=1000, last=None, interval=1800))

    def test_within_interval_is_not_due(self):
        self.assertFalse(AUTOSYNC.is_due(now=1000 + 1799, last=1000, interval=1800))

    def test_after_interval_is_due(self):
        self.assertTrue(AUTOSYNC.is_due(now=1000 + 1800, last=1000, interval=1800))

    def test_clock_moved_backwards_is_due(self):
        self.assertTrue(AUTOSYNC.is_due(now=500, last=1000, interval=1800))

    def test_state_round_trip_and_broken_state(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            self.assertIsNone(AUTOSYNC.read_last_attempt(path))
            AUTOSYNC.write_last_attempt(path, 1234.5)
            self.assertEqual(AUTOSYNC.read_last_attempt(path), 1234.5)
            path.write_text("{broken")
            self.assertIsNone(AUTOSYNC.read_last_attempt(path))


class LockTest(unittest.TestCase):
    def test_second_lock_fails_while_the_first_is_held(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lock"
            first = AUTOSYNC.try_lock(path)
            self.assertIsNotNone(first)
            try:
                self.assertIsNone(AUTOSYNC.try_lock(path))
            finally:
                os.close(first)
            second = AUTOSYNC.try_lock(path)
            self.assertIsNotNone(second)
            os.close(second)


class SummaryTest(unittest.TestCase):
    def test_nothing_to_report_is_silent(self):
        self.assertIsNone(AUTOSYNC.summarize([]))

    def test_parts_are_joined_on_one_line(self):
        line = AUTOSYNC.summarize(["2 commit 更新", "リンク 1 件を追加\nX"])
        self.assertEqual(line.count("\n"), 0)
        self.assertTrue(line.startswith("dotfiles: 2 commit 更新、リンク 1 件を追加"))


def git(*args, cwd=None, env=None):
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


LINK_ENTRY = """
[[config]]
name = "{name}"
source = ".local/bin/{name}"
target = ".local/bin/{name}"
mode = "link"
executable = true
"""

SETTINGS_ENTRY = """
[[config]]
name = "Claude settings"
source = ".claude/settings.json"
target = ".claude/settings.json"
mode = "merge-json-managed"
keys = []
hook_commands = {commands}
"""


class AutosyncIntegrationTest(unittest.TestCase):
    """bare repo を origin にした一時ディレクトリで、スクリプトを hook と同じく実行する。"""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state"
        # pre-commit hook から make check を実行すると GIT_DIR などが入っているため、git の環境変数は引き継がない。
        self.env = {
            **{key: value for key, value in os.environ.items() if not key.startswith("GIT_")},
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        self.origin = self.root / "origin.git"
        self.work = self.root / "work"
        self.checkout = self.root / "checkout"
        git("init", "--quiet", "--bare", "-b", "main", str(self.origin), env=self.env)
        git("init", "--quiet", "-b", "main", str(self.work), env=self.env)
        (self.work / ".bin").mkdir()
        shutil.copy2(MANAGER, self.work / ".bin" / "manage-dotfiles-configs.py")
        self.links = ["tool"]
        self.hooks = {"Stop": "~/.local/bin/tool"}
        self.write_declaration()
        self.commit("初期状態")
        git("remote", "add", "origin", str(self.origin), cwd=self.work, env=self.env)
        git("push", "--quiet", "origin", "main", cwd=self.work, env=self.env)
        git("clone", "--quiet", str(self.origin), str(self.checkout), env=self.env)
        for command in ("link", "sync"):
            subprocess.run(
                [sys.executable, str(self.checkout / ".bin" / "manage-dotfiles-configs.py"), command],
                env=self.env, check=True, capture_output=True,
            )

    def tearDown(self):
        self.directory.cleanup()

    def write_declaration(self):
        declaration = "".join(LINK_ENTRY.format(name=name) for name in self.links)
        declaration += SETTINGS_ENTRY.format(commands=json.dumps(sorted(set(self.hooks.values()))))
        (self.work / "dotfiles.toml").write_text(declaration)
        for name in self.links:
            tool = self.work / ".local" / "bin" / name
            tool.parent.mkdir(parents=True, exist_ok=True)
            tool.write_text("#!/bin/sh\n")
            tool.chmod(0o755)  # link は executable の source に実行権を付けるため、commit 時点で付けておく
        settings = {"hooks": {event: [{"hooks": [{"type": "command", "command": command}]}] for event, command in self.hooks.items()}}
        (self.work / ".claude").mkdir(exist_ok=True)
        (self.work / ".claude" / "settings.json").write_text(json.dumps(settings, indent=2) + "\n")

    def commit(self, message):
        git("add", "-A", cwd=self.work, env=self.env)
        git("commit", "--quiet", "-m", message, cwd=self.work, env=self.env)

    def advance_origin(self):
        """新しい link エントリと SessionStart hook を origin/main に足す。"""
        self.links.append("tool2")
        self.hooks["SessionStart"] = "~/.local/bin/tool2"
        self.write_declaration()
        self.commit("tool2 を追加")
        git("push", "--quiet", "origin", "main", cwd=self.work, env=self.env)
        return git("rev-parse", "HEAD", cwd=self.work, env=self.env)

    def run_autosync(self, *args, **extra_env):
        env = {
            **self.env,
            "DOTFILES_AUTOSYNC_REPO": str(self.checkout),
            "DOTFILES_AUTOSYNC_STATE_DIR": str(self.state),
            **extra_env,
        }
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
        )
        return result, time.monotonic() - started

    def head(self):
        return git("rev-parse", "HEAD", cwd=self.checkout, env=self.env)

    def tracking(self):
        return git("rev-parse", "refs/remotes/origin/main", cwd=self.checkout, env=self.env)

    def settings_commands(self):
        settings = json.loads((self.home / ".claude" / "settings.json").read_text())
        return {
            event: [handler["command"] for group in groups for handler in group["hooks"]]
            for event, groups in settings.get("hooks", {}).items()
        }

    def test_fast_forward_places_new_links_and_managed_hooks(self):
        new_head = self.advance_origin()

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.head(), new_head)
        link = self.home / ".local" / "bin" / "tool2"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), (self.checkout / ".local" / "bin" / "tool2").resolve())
        self.assertEqual(self.settings_commands()["SessionStart"], ["~/.local/bin/tool2"])
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 1, result.stdout)
        self.assertIn("1 commit 更新", lines[0])
        self.assertIn("リンク 1 件を追加", lines[0])
        self.assertIn("設定 1 件を同期", lines[0])

    def test_up_to_date_and_in_sync_is_silent(self):
        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_local_drift_is_repaired_without_an_update(self):
        (self.home / ".local" / "bin" / "tool").unlink()

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".local" / "bin" / "tool").is_symlink())
        self.assertIn("リンク 1 件を追加", result.stdout)

    def test_existing_file_is_not_replaced_by_a_link(self):
        link = self.home / ".local" / "bin" / "tool"
        link.unlink()
        link.write_text("user file\n")

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(link.read_text(), "user file\n")
        self.assertIn("未配置", result.stdout)

    def test_uncommitted_changes_block_the_update(self):
        before_head = self.head()
        self.advance_origin()
        (self.checkout / "dotfiles.toml").write_text((self.checkout / "dotfiles.toml").read_text() + "# local\n")

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.head(), before_head)
        self.assertFalse((self.home / ".local" / "bin" / "tool2").exists())
        self.assertNotIn("SessionStart", self.settings_commands())
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertIn("未コミット", result.stdout)

    def test_untracked_files_also_block_the_update(self):
        before_head = self.head()
        self.advance_origin()
        (self.checkout / "scratch.txt").write_text("user\n")

        result, _ = self.run_autosync()

        self.assertEqual(self.head(), before_head)
        self.assertIn("未コミット", result.stdout)
        self.assertTrue((self.checkout / "scratch.txt").exists())

    def test_other_branch_blocks_the_update(self):
        git("checkout", "--quiet", "-b", "feature/x", cwd=self.checkout, env=self.env)
        before_head = self.head()
        self.advance_origin()

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.head(), before_head)
        self.assertEqual(git("branch", "--show-current", cwd=self.checkout, env=self.env), "feature/x")
        self.assertIn("feature/x", result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 1)

    def test_diverged_main_is_not_changed(self):
        (self.checkout / "local.txt").write_text("local\n")
        git("add", "local.txt", cwd=self.checkout, env=self.env)
        git("commit", "--quiet", "-m", "local", cwd=self.checkout, env=self.env)
        local_head = self.head()
        self.advance_origin()

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.head(), local_head)
        self.assertFalse((self.home / ".local" / "bin" / "tool2").exists())
        self.assertIn("分岐", result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 1)

    def test_unreachable_origin_exits_zero(self):
        before_head = self.head()
        git("remote", "set-url", "origin", str(self.root / "missing.git"), cwd=self.checkout, env=self.env)

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.head(), before_head)
        self.assertIn("origin を確認できません", result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 1)

    def test_hanging_fetch_is_cut_off_by_the_time_limit(self):
        git("remote", "set-url", "origin", "ssh://example.invalid/dotfiles.git", cwd=self.checkout, env=self.env)

        result, elapsed = self.run_autosync(
            DOTFILES_AUTOSYNC_TIMEOUT="2", GIT_SSH_COMMAND="sh -c 'sleep 30' --",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 15)
        self.assertIn("時間内", result.stdout)

    def test_fetch_runs_once_within_the_interval(self):
        self.run_autosync()
        first_tracking = self.tracking()
        self.advance_origin()

        result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.tracking(), first_tracking)

        result, _ = self.run_autosync("--force")
        self.assertIn("1 commit 更新", result.stdout)

    def test_a_held_lock_skips_the_run(self):
        self.advance_origin()
        before_tracking = self.tracking()
        self.state.mkdir(parents=True)
        with (self.state / "lock").open("w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result, _ = self.run_autosync()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.tracking(), before_tracking)


if __name__ == "__main__":
    unittest.main()
