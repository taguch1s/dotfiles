import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / ".bin" / "manage-dotfiles-configs.py"
SPEC = importlib.util.spec_from_file_location("manage_dotfiles_configs", SCRIPT)
MANAGER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MANAGER)


class ManageDotfilesConfigsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.original_root = MANAGER.ROOT
        MANAGER.ROOT = self.root

    def tearDown(self):
        MANAGER.ROOT = self.original_root
        self.directory.cleanup()

    def config(self, target: Path):
        source = self.root / ".codex" / "config.toml"
        source.parent.mkdir(parents=True)
        source.write_text("[features]\nhooks = true\nmemories = true\n")
        return {
            "mode": "merge-toml-features",
            "source": ".codex/config.toml",
            "target": str(target),
            "features": ["hooks", "memories"],
        }

    def test_merge_adds_missing_feature_without_replacing_machine_state(self):
        target = self.root / "local" / "config.toml"
        target.parent.mkdir(parents=True)
        target.write_text("model = 'local'\n\n[features]\nhooks = true\n\n[hooks.state]\npath = 'machine-generated'\n")

        self.assertTrue(MANAGER.merge_toml_features(self.config(target)))

        self.assertEqual(
            target.read_text(),
            "model = 'local'\n\n[features]\nhooks = true\nmemories = true\n\n[hooks.state]\npath = 'machine-generated'\n",
        )

    def test_merge_refuses_conflicting_feature_without_writing(self):
        target = self.root / "local" / "config.toml"
        target.parent.mkdir(parents=True)
        original = "[features]\nhooks = true\nmemories = false\n"
        target.write_text(original)

        self.assertFalse(MANAGER.merge_toml_features(self.config(target)))

        self.assertEqual(target.read_text(), original)

    def test_merge_accepts_a_commented_features_header(self):
        target = self.root / "local" / "config.toml"
        target.parent.mkdir(parents=True)
        target.write_text("model = 'local'\n\n[features] # machine comment\nhooks = true\n")

        self.assertTrue(MANAGER.merge_toml_features(self.config(target)))

        self.assertEqual(
            target.read_text(),
            "model = 'local'\n\n[features] # machine comment\nhooks = true\nmemories = true\n",
        )

    def test_merge_refuses_an_inline_features_table_without_writing(self):
        target = self.root / "local" / "config.toml"
        target.parent.mkdir(parents=True)
        original = "features = { hooks = true }\n"
        target.write_text(original)

        self.assertFalse(MANAGER.merge_toml_features(self.config(target)))

        self.assertEqual(target.read_text(), original)

    def test_linking_one_skill_does_not_replace_the_skills_directory(self):
        source = self.root / ".agents" / "skills" / "shared-codex-workflow"
        source.mkdir(parents=True)
        (source / "SKILL.md").write_text("shared")
        target_root = self.root / "home" / ".agents" / "skills"
        target_root.mkdir(parents=True)
        existing = target_root / "existing-skill"
        existing.mkdir()

        config = {
            "mode": "link",
            "source": ".agents/skills/shared-codex-workflow",
            "target": str(target_root / "shared-codex-workflow"),
        }
        original_configs = MANAGER.configs
        MANAGER.configs = lambda: [config]
        try:
            self.assertEqual(MANAGER.link(), 0)
        finally:
            MANAGER.configs = original_configs

        self.assertTrue(existing.is_dir())
        self.assertTrue((target_root / "shared-codex-workflow").is_symlink())
        self.assertEqual((target_root / "shared-codex-workflow").resolve(), source)

    def test_static_doctor_checks_sources_without_requiring_home_links(self):
        source = self.root / ".agents" / "skills" / "example"
        source.mkdir(parents=True)
        target = self.root / "home" / ".agents" / "skills" / "example"
        config = {"name": "Example", "mode": "link", "source": ".agents/skills/example", "target": str(target)}
        original_configs = MANAGER.configs
        MANAGER.configs = lambda: [config]
        output = io.StringIO()
        try:
            with redirect_stdout(output):
                self.assertEqual(MANAGER.doctor(static=True), 0)
        finally:
            MANAGER.configs = original_configs

        self.assertIn("OK    管理対象", output.getvalue())

    def test_auto_doctor_uses_full_link_validation_for_an_installed_checkout(self):
        source_a = self.root / ".agents" / "skills" / "a"
        source_b = self.root / ".agents" / "skills" / "b"
        source_a.mkdir(parents=True)
        source_b.mkdir(parents=True)
        target_a = self.root / "home" / ".agents" / "skills" / "a"
        target_b = self.root / "home" / ".agents" / "skills" / "b"
        target_a.parent.mkdir(parents=True)
        target_a.symlink_to(source_a)
        configs = [
            {"name": "A", "mode": "link", "source": ".agents/skills/a", "target": str(target_a)},
            {"name": "B", "mode": "link", "source": ".agents/skills/b", "target": str(target_b)},
        ]
        original_configs = MANAGER.configs
        MANAGER.configs = lambda: configs
        output = io.StringIO()
        try:
            with redirect_stdout(output):
                self.assertEqual(MANAGER.doctor(auto=True), 1)
        finally:
            MANAGER.configs = original_configs

        self.assertIn("NG    リンク", output.getvalue())



CONTEXT_GUARD = "~/.local/bin/claude-context-guard"
TOKEN_RECORD = "~/.local/bin/claude-token-metrics record || true"
AWAKE_ON = "~/.local/bin/awake-hook on"
AWAKE_OFF = "~/.local/bin/awake-hook off"
HERDR = "bash '/home/user/.claude/hooks/herdr-agent-state.sh' session"


def handler(command, timeout=None):
    value = {"type": "command", "command": command}
    if timeout is not None:
        value["timeout"] = timeout
    return value


def repo_settings():
    """リポジトリ版 .claude/settings.json と同じ形の source。"""
    return {
        "permissions": {"deny": ["Read(~/.codex/sessions)"]},
        "statusLine": {"type": "command", "command": "~/.local/bin/claude-statusline"},
        "hooks": {
            "UserPromptSubmit": [{"hooks": [handler(AWAKE_ON), handler(CONTEXT_GUARD, 10)]}],
            "PostToolUse": [{"hooks": [handler(CONTEXT_GUARD, 10)]}],
            "PreToolUse": [{"hooks": [handler(AWAKE_ON)]}],
            "Stop": [{"hooks": [handler(AWAKE_OFF)]}],
            "SessionEnd": [{"hooks": [handler(AWAKE_OFF), handler(TOKEN_RECORD, 10)]}],
        },
    }


def machine_settings():
    """dev ディストリの ~/.claude/settings.json と同じ形（管理外の hook・キーを含む）。"""
    return {
        "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"},
        "permissions": {"allow": ["Bash(git push:*)"], "deny": ["Read(~/.codex/sessions)"]},
        "model": "opus",
        "statusLine": {"type": "command", "command": "python3 ~/.claude/statusline.py"},
        "hooks": {
            "SessionStart": [{"matcher": "*", "hooks": [handler(HERDR, 10)]}],
            "UserPromptSubmit": [{"hooks": [handler(AWAKE_ON)]}],
            "PreToolUse": [{"hooks": [handler(AWAKE_ON)]}],
            "Stop": [{"hooks": [handler(AWAKE_OFF)]}],
            "SessionEnd": [{"hooks": [handler(AWAKE_OFF)]}],
        },
        "autoMode": {"soft_deny": ["$defaults"], "environment": ["machine"]},
    }


class ClaudeSettingsSyncTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.original_root = MANAGER.ROOT
        MANAGER.ROOT = self.root
        self.source = self.root / ".claude" / "settings.json"
        self.source.parent.mkdir(parents=True)
        self.write_source(repo_settings())
        self.target = self.root / "home" / ".claude" / "settings.json"
        self.target.parent.mkdir(parents=True)
        self.config = {
            "name": "Claude user settings",
            "mode": "merge-json-managed",
            "source": ".claude/settings.json",
            "target": str(self.target),
            "keys": ["statusLine"],
            "hook_commands": [AWAKE_ON, AWAKE_OFF, CONTEXT_GUARD, TOKEN_RECORD],
        }

    def tearDown(self):
        MANAGER.ROOT = self.original_root
        self.directory.cleanup()

    def write_source(self, value):
        self.source.write_text(json.dumps(value, indent=2) + "\n")

    def write_target(self, value):
        self.target.write_text(json.dumps(value, indent=2) + "\n")

    def read_target(self):
        return json.loads(self.target.read_text())

    def backups(self):
        return sorted(self.target.parent.glob("settings.json.dotfiles-backup-*"))

    def sync(self):
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            result = MANAGER.merge_json_managed(self.config)
        return result, output.getvalue()

    def run_with_config(self, function, **kwargs):
        original_configs = MANAGER.configs
        MANAGER.configs = lambda: [self.config]
        output = io.StringIO()
        try:
            with redirect_stdout(output), redirect_stderr(output):
                result = function(**kwargs)
        finally:
            MANAGER.configs = original_configs
        return result, output.getvalue()

    def test_sync_adds_managed_entries_and_keeps_machine_state(self):
        before = machine_settings()
        self.write_target(before)
        original_text = self.target.read_text()

        ok, output = self.sync()

        self.assertTrue(ok, output)
        after = self.read_target()
        hooks = after["hooks"]
        self.assertEqual(hooks["UserPromptSubmit"], [{"hooks": [handler(AWAKE_ON), handler(CONTEXT_GUARD, 10)]}])
        self.assertEqual(hooks["PostToolUse"], [{"hooks": [handler(CONTEXT_GUARD, 10)]}])
        self.assertEqual(hooks["SessionEnd"], [{"hooks": [handler(AWAKE_OFF), handler(TOKEN_RECORD, 10)]}])
        self.assertEqual(after["statusLine"], repo_settings()["statusLine"])
        # 管理外の hook とキーは同期前と同一
        self.assertEqual(hooks["SessionStart"], before["hooks"]["SessionStart"])
        self.assertEqual(hooks["PreToolUse"], before["hooks"]["PreToolUse"])
        self.assertEqual(hooks["Stop"], before["hooks"]["Stop"])
        for key in ("env", "permissions", "model", "autoMode"):
            self.assertEqual(after[key], before[key], key)
        self.assertEqual(list(after), list(before))
        # 変更前のファイルを残す
        backups = self.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original_text)

    def test_second_sync_is_a_no_op(self):
        self.write_target(machine_settings())
        self.assertTrue(self.sync()[0])
        first = self.target.read_text()

        ok, output = self.sync()

        self.assertTrue(ok, output)
        self.assertIn("一致", output)
        self.assertEqual(self.target.read_text(), first)
        self.assertEqual(len(self.backups()), 1)

    def test_sync_removes_entries_dropped_from_dotfiles(self):
        retired = "~/.local/bin/retired-hook"
        self.config["hook_commands"].append(retired)
        machine = machine_settings()
        machine["hooks"]["Notification"] = [{"hooks": [handler(retired)]}]
        machine["hooks"]["Stop"] = [{"hooks": [handler(AWAKE_OFF), handler(retired), handler("~/mine")]}]
        self.write_target(machine)

        ok, output = self.sync()

        self.assertTrue(ok, output)
        hooks = self.read_target()["hooks"]
        self.assertNotIn("Notification", hooks)
        self.assertEqual(hooks["Stop"], [{"hooks": [handler(AWAKE_OFF), handler("~/mine")]}])

    def test_sync_updates_changed_fields_and_collapses_duplicates(self):
        machine = machine_settings()
        machine["hooks"]["PostToolUse"] = [
            {"hooks": [handler(CONTEXT_GUARD, 3)]},
            {"hooks": [handler(CONTEXT_GUARD, 3), handler("~/mine")]},
        ]
        self.write_target(machine)

        ok, output = self.sync()

        self.assertTrue(ok, output)
        self.assertEqual(
            self.read_target()["hooks"]["PostToolUse"],
            [{"hooks": [handler(CONTEXT_GUARD, 10)]}, {"hooks": [handler("~/mine")]}],
        )

    def test_sync_respects_matchers(self):
        source = repo_settings()
        source["hooks"]["PreToolUse"] = [{"matcher": "Bash", "hooks": [handler(AWAKE_ON)]}]
        self.write_source(source)
        self.write_target(machine_settings())

        ok, output = self.sync()

        self.assertTrue(ok, output)
        self.assertEqual(self.read_target()["hooks"]["PreToolUse"], [{"matcher": "Bash", "hooks": [handler(AWAKE_ON)]}])

    def test_sync_removes_a_managed_key_dropped_from_dotfiles(self):
        source = repo_settings()
        del source["statusLine"]
        self.write_source(source)
        self.write_target(machine_settings())

        ok, output = self.sync()

        self.assertTrue(ok, output)
        self.assertNotIn("statusLine", self.read_target())

    def test_broken_target_fails_without_writing(self):
        for broken in ('{"hooks": {', '[]', '{"hooks": []}', '{"hooks": {"Stop": [{"hooks": "x"}]}}'):
            with self.subTest(broken=broken):
                self.target.write_text(broken)

                ok, output = self.sync()

                self.assertFalse(ok)
                self.assertIn("NG", output)
                self.assertEqual(self.target.read_text(), broken)
                self.assertEqual(self.backups(), [])

    def test_undeclared_source_hook_fails_without_writing(self):
        source = repo_settings()
        source["hooks"]["Stop"][0]["hooks"].append(handler("~/.local/bin/undeclared"))
        self.write_source(source)
        self.write_target(machine_settings())
        original = self.target.read_text()

        ok, output = self.sync()

        self.assertFalse(ok)
        self.assertIn("hook_commands", output)
        self.assertEqual(self.target.read_text(), original)

    def test_missing_target_gets_a_copy_of_the_source(self):
        ok, output = self.sync()

        self.assertTrue(ok, output)
        self.assertEqual(self.target.read_text(), self.source.read_text())

    def test_sync_command_runs_the_new_mode(self):
        self.write_target(machine_settings())

        result, output = self.run_with_config(MANAGER.sync)

        self.assertEqual(result, 0, output)
        self.assertIn(CONTEXT_GUARD, json.dumps(self.read_target()["hooks"]["PostToolUse"]))

    def test_doctor_reports_missing_entries_until_synced(self):
        self.write_target(machine_settings())

        result, output = self.run_with_config(MANAGER.doctor)
        self.assertEqual(result, 1)
        self.assertIn("NG", output)

        self.assertTrue(self.sync()[0])
        result, output = self.run_with_config(MANAGER.doctor)
        self.assertEqual(result, 0, output)
        self.assertIn("OK", output)

    def test_static_doctor_validates_the_declaration_without_reading_home(self):
        self.target.write_text("{broken")

        result, output = self.run_with_config(MANAGER.doctor, static=True)
        self.assertEqual(result, 0, output)

        source = repo_settings()
        source["hooks"]["Stop"][0]["hooks"].append(handler("~/.local/bin/undeclared"))
        self.write_source(source)
        result, output = self.run_with_config(MANAGER.doctor, static=True)
        self.assertEqual(result, 1, output)

    def test_diff_shows_pending_changes_until_synced(self):
        self.write_target(machine_settings())

        result, output = self.run_with_config(MANAGER.diff)
        self.assertEqual(result, 1)
        self.assertIn("+", output)
        self.assertIn("claude-context-guard", output)

        self.assertTrue(self.sync()[0])
        result, output = self.run_with_config(MANAGER.diff)
        self.assertEqual(result, 0, output)

    def test_repository_declaration_covers_the_repository_settings(self):
        MANAGER.ROOT = self.original_root
        config = next(item for item in MANAGER.configs() if item["target"] == ".claude/settings.json")
        self.assertEqual(config["mode"], "merge-json-managed")
        source = json.loads(MANAGER.source_path(config).read_text())
        MANAGER.managed_json_source(config, source)


if __name__ == "__main__":
    unittest.main()
