import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("project_repos", ROOT / "scripts/project-repos.py")
MOD = importlib.util.module_from_spec(SPEC)
sys.modules["project_repos"] = MOD
SPEC.loader.exec_module(MOD)


class ProjectReposTests(unittest.TestCase):
    def test_select_all_targets_includes_unified_core_and_apps_only(self):
        targets = MOD.select_targets(ROOT)
        ids = {t["id"] for t in targets}
        self.assertIn("etaf", ids)
        self.assertIn("etaf-md", ids)
        self.assertIn("etaf-xiangqi", ids)
        self.assertNotIn("ecss", ids)
        self.assertNotIn("etaf-manual", ids)
        self.assertNotIn("etaf-web", ids)
        self.assertEqual(len(ids), 18)

    def test_select_explicit_targets_rejects_unknown(self):
        with self.assertRaises(ValueError):
            MOD.select_targets(ROOT, targets=["does-not-exist"])

    def test_changed_since_filters_to_affected_targets(self):
        with mock.patch.object(MOD, "git_changed_files", return_value=["core/packages/ecss/ecss.el"]):
            hits = MOD.select_targets(ROOT, changed_since="HEAD~1")
        self.assertEqual([h["id"] for h in hits], ["etaf"])

    def test_push_commit_redacts_token_on_error(self):
        failed = mock.Mock(returncode=1, stdout="", stderr="fatal: https://x-access-token:SECRET123@github.com/emacs-taf/etaf.git denied")
        with mock.patch.object(MOD.subprocess, "run", return_value=failed):
            with self.assertRaises(RuntimeError) as ctx:
                MOD.push_commit(ROOT, "a" * 40, "emacs-taf/etaf", "main", token="SECRET123")
        self.assertNotIn("SECRET123", str(ctx.exception))
        self.assertIn("***", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
