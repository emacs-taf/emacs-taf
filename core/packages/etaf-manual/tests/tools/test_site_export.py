"""Check generated website inputs through the documented export CLI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
EMACS = os.environ.get("EMACS", "emacs")
OG_TOOL = ROOT / "site/scripts/og_cards.py"


@unittest.skipUnless(shutil.which(EMACS), "The site exporter requires Emacs")
class SiteExportTests(unittest.TestCase):
    def test_export_preserves_installation_anchors_and_regenerates_recovery_page(self):
        with tempfile.TemporaryDirectory() as temporary:
            site = Path(temporary)
            command = [EMACS, "-Q", "--batch", "-L", str(ROOT), "-L", str(ROOT / "lisp"),
                       "-l", str(ROOT / "site/scripts/export-site.el"), "--", "--site", str(site)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            docs = site / "src/content/docs"
            intro_en = (docs / "introduction.md").read_text()
            intro_zh = (docs / "zh-cn/introduction.md").read_text()
            self.assertIn("## Installation", intro_en)
            self.assertIn("## 安装", intro_zh)
            self.assertIn("description: \"", intro_en)
            self.assertIn("description: \"", intro_zh)
            page = docs / "404.md"
            original = page.read_text()
            self.assertIn("/introduction/#installation", original)
            self.assertIn("/zh-cn/introduction/#安装", original)
            self.assertIn("pagefind: false", original)
            manifest = json.loads((site / "src/og-manifest.json").read_text(encoding="utf-8"))
            by_key = {item["key"]: item for item in manifest}
            self.assertEqual(set(by_key), {"landing-en", "landing-zh", "manual-en", "manual-zh"})
            self.assertEqual(by_key["landing-en"]["url_label"], "etaf.top")
            self.assertEqual(by_key["landing-zh"]["url_label"], "etaf.top/zh-cn")
            self.assertEqual(by_key["manual-en"]["url_label"], "etaf.top/introduction")
            self.assertEqual(by_key["manual-zh"]["url_label"], "etaf.top/zh-cn/introduction")
            page.write_text("obsolete generated page")
            result = subprocess.run(command, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(page.read_text(), original)

            og_res = subprocess.run(
                [sys.executable, str(OG_TOOL), "site", "--site", str(site)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(og_res.returncode, 0, og_res.stdout + og_res.stderr)
            hashes = json.loads((site / "src/og-hashes.json").read_text(encoding="utf-8"))
            self.assertEqual(set(hashes), set(by_key))
            for item in manifest:
                png_path = site / "public/og" / item["output"]
                self.assertTrue(png_path.is_file(), f"missing {png_path}")
                self.assertTrue(png_path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))


if __name__ == "__main__":
    unittest.main()
