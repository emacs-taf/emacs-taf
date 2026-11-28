"""Tests for scripts/sync-generated-docs.py (Layer-0 doc generation & drift checks)."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("sync_docs", ROOT / "scripts/sync-generated-docs.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class SyncGeneratedDocsTests(unittest.TestCase):
    def test_workspace_generated_docs_are_in_sync(self):
        changed, errors = SYNC.sync(ROOT, write=False)
        self.assertEqual([], errors, "\n".join(errors))
        self.assertEqual([], changed)

    def test_stale_fence_is_detected_and_repaired(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # Minimal layered workspace fixture.
            (root / "workspace.json").write_text(json.dumps({
                "schema": 3,
                "projections": {"etaf": {"prefix": "core", "repo": "emacs-taf/etaf", "branch": "main"}},
                "packages": {
                    "ecss": {"path": "core/packages/ecss", "role": "framework", "projection": "etaf"},
                    "etaf": {"path": "core/packages/etaf", "role": "framework", "projection": "etaf"},
                    "demo-app": {"path": "apps/demo-app", "role": "application", "repo": "emacs-taf/demo-app"},
                    "wip-game": {"path": "games/wip-game", "role": "game", "status": "incubating"},
                },
            }), encoding="utf-8")
            (root / "release-dependencies.json").write_text(json.dumps({
                "schema": 1, "packages": {"ecss": {}, "etaf": {}, "demo-app": {}}, "targets": ["demo-app"],
            }), encoding="utf-8")
            (root / "scripts").mkdir()
            (root / "scripts/doc-catalog.json").write_text(json.dumps({"schema": 1, "packages": {}}), encoding="utf-8")
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/structure.yml").write_text("name: Repository structure\n", encoding="utf-8")

            for rel, ver, reqs in (
                ("core/packages/ecss/ecss.el", "0.1.5", '((emacs "28.1"))'),
                ("core/packages/etaf/etaf.el", "0.4.0", '((emacs "29.1") (ecss "0.1.5"))'),
                ("apps/demo-app/demo-app.el", "0.2.0", '((emacs "29.1") (etaf "0.4.0"))'),
                ("games/wip-game/wip-game.el", "0.1.0", '((emacs "29.1") (etaf "0.4.0"))'),
            ):
                p = root / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(
                    f";;; {p.name} --- Summary for {p.stem}\n;; Version: {ver}\n;; Package-Requires: {reqs}\n",
                    encoding="utf-8",
                )

            (root / "README.md").write_text(
                "# Test\n"
                "<!-- BEGIN:GENERATED:root-badges-en -->\nstale\n<!-- END:GENERATED:root-badges-en -->\n"
                "<!-- BEGIN:GENERATED:root-overview-en -->\nstale\n<!-- END:GENERATED:root-overview-en -->\n"
                "<!-- BEGIN:GENERATED:root-packages-en -->\nstale\n<!-- END:GENERATED:root-packages-en -->\n"
                "<!-- BEGIN:GENERATED:root-layout-en -->\nstale\n<!-- END:GENERATED:root-layout-en -->\n",
                encoding="utf-8",
            )
            (root / "apps/demo-app/README.md").write_text(
                "# Demo\n<!-- BEGIN:GENERATED:pkg-install-en:demo-app -->\nstale\n<!-- END:GENERATED:pkg-install-en:demo-app -->\n",
                encoding="utf-8",
            )
            (root / "games/wip-game/README.md").write_text(
                "# WIP\n<!-- BEGIN:GENERATED:pkg-install-en:wip-game -->\nstale\n<!-- END:GENERATED:pkg-install-en:wip-game -->\n",
                encoding="utf-8",
            )

            changed, errors = SYNC.sync(root, write=False)
            self.assertTrue(errors)
            self.assertIn("README.md", changed)

            changed_w, errors_w = SYNC.sync(root, write=True)
            self.assertEqual([], errors_w)
            self.assertEqual(3, len(changed_w))

            demo_readme = (root / "apps/demo-app/README.md").read_text(encoding="utf-8")
            self.assertIn("(etaf-install-ensure '(demo-app))", demo_readme)
            self.assertIn('"ecss" "etaf"', demo_readme)

            wip_readme = (root / "games/wip-game/README.md").read_text(encoding="utf-8")
            self.assertIn("incubating", wip_readme)
            self.assertNotIn("etaf-install-ensure", wip_readme)

            # Second check must be clean.
            changed2, errors2 = SYNC.sync(root, write=False)
            self.assertEqual([], errors2)
            self.assertEqual([], changed2)


if __name__ == "__main__":
    unittest.main()
