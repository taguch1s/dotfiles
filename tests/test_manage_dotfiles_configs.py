import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stdout
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


if __name__ == "__main__":
    unittest.main()
