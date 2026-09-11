import importlib.util
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
