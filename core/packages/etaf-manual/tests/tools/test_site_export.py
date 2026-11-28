"""Check generated website inputs through the documented export CLI."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
EMACS = os.environ.get("EMACS", "emacs")


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
            self.assertIn("## Installation", (docs / "introduction.md").read_text())
            self.assertIn("## 安装", (docs / "zh-cn/introduction.md").read_text())
            page = docs / "404.md"
            original = page.read_text()
            self.assertIn("/introduction/#installation", original)
            self.assertIn("/zh-cn/introduction/#安装", original)
            self.assertIn("pagefind: false", original)
            page.write_text("obsolete generated page")
            result = subprocess.run(command, capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(page.read_text(), original)


if __name__ == "__main__":
    unittest.main()
