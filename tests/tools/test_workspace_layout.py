import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import workspace_layout  # noqa: E402


class WorkspaceLayoutTests(unittest.TestCase):
    def test_layered_discovery_covers_all_registered_packages(self):
        ws = workspace_layout.load_workspace(ROOT)
        dirs = workspace_layout.package_dirs(ROOT)
        self.assertEqual(set(dirs), set(ws["packages"]))
        self.assertEqual(workspace_layout.package_relpath(ROOT, "etaf"), "core/packages/etaf")
        self.assertEqual(workspace_layout.package_relpath(ROOT, "etaf-manual"), "core/packages/etaf-manual")
        self.assertEqual(workspace_layout.package_relpath(ROOT, "etaf-md"), "apps/etaf-md")
        self.assertEqual(workspace_layout.package_relpath(ROOT, "etaf-xiangqi"), "games/etaf-xiangqi")

    def test_container_root_recognizes_all_layers(self):
        self.assertEqual(workspace_layout.container_root(ROOT / "core/packages/ecss"), ROOT)
        self.assertEqual(workspace_layout.container_root(ROOT / "apps/etaf-md"), ROOT)
        self.assertEqual(workspace_layout.container_root(ROOT / "games/etaf-xiangqi"), ROOT)
        self.assertIsNone(workspace_layout.container_root(ROOT))

    def test_projection_targets_and_affected_matching(self):
        targets = workspace_layout.projection_targets(ROOT)
        by_id = {t["id"]: t for t in targets}
        self.assertIn("etaf", by_id)
        self.assertEqual(by_id["etaf"]["prefix"], "core")
        self.assertEqual(by_id["etaf"]["repo"], "emacs-taf/etaf")
        self.assertIn("etaf-md", by_id)
        self.assertEqual(by_id["etaf-md"]["prefix"], "apps/etaf-md")
        self.assertNotIn("etaf-web", by_id)
        self.assertNotIn("ecss", by_id)

        hit_core = workspace_layout.affected_projections(ROOT, ["core/packages/ebox/ebox.el"])
        self.assertEqual([t["id"] for t in hit_core], ["etaf"])

        hit_multi = workspace_layout.affected_projections(
            ROOT, ["core/README.md", "apps/etaf-md/etaf-md.el", "games/etaf-xiangqi/etaf-xiangqi.el"]
        )
        self.assertEqual(sorted(t["id"] for t in hit_multi), ["etaf", "etaf-md", "etaf-xiangqi"])

        hit_none = workspace_layout.affected_projections(ROOT, ["README.md", "apps/etaf-web/etaf-web.el"])
        self.assertEqual(hit_none, [])

    def test_incubating_packages_are_registered_and_excluded_from_projections(self):
        ws = workspace_layout.load_workspace(ROOT)
        for name in ("etaf-devtools", "etaf-island", "etaf-balatro"):
            self.assertIn(name, ws["packages"])
            self.assertTrue(workspace_layout.is_incubating(ws["packages"][name]))
        by_id = {t["id"] for t in workspace_layout.projection_targets(ROOT)}
        self.assertNotIn("etaf-island", by_id)
        self.assertNotIn("etaf-balatro", by_id)
        self.assertNotIn("etaf-devtools", by_id)


if __name__ == "__main__":
    unittest.main()
