"""Tests for scripts/media-publish.py staging, conversion and verification."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("media_publish", ROOT / "scripts/media-publish.py")
MEDIA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MEDIA)


class MediaPublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def test_parse_item_spec_and_validation(self):
        src = self.work / "shot.png"
        src.write_bytes(b"fake")
        ns, path, dest = MEDIA.parse_item_spec(f"etaf-bili:{src}")
        self.assertEqual(ns, "etaf-bili")
        self.assertEqual(path, src.resolve())
        self.assertIsNone(dest)
        ns2, _, dest2 = MEDIA.parse_item_spec(f"site:{src}:og/manual.png")
        self.assertEqual((ns2, dest2), ("site", "og/manual.png"))
        with self.assertRaises(ValueError):
            MEDIA.parse_item_spec("BAD_NS:" + str(src))
        with self.assertRaises(ValueError):
            MEDIA.resolve_dest_rel("site", src, "../escape.png", keep_format=True)

    def test_stage_and_verify_keep_format_and_webp(self):
        sample_png = ROOT / "apps/etaf-md/tests/fixtures/wide-400x100.png"
        stage = self.work / "stage"
        items = [("site", sample_png, "og/sample.png")]
        if shutil.which("cwebp") or shutil.which("ffmpeg"):
            items.append(("etaf-md", sample_png, None))
        report = MEDIA.stage_items(stage, items)
        manifest = MEDIA.verify_stage(stage)
        paths = [a["path"] for a in manifest["assets"]]
        self.assertIn("site/og/sample.png", paths)
        if shutil.which("cwebp") or shutil.which("ffmpeg"):
            self.assertIn("etaf-md/wide-400x100.webp", paths)
        self.assertEqual(report["count"], len(paths))

        # Tampering with a staged file fails verification.
        (stage / "site/og/sample.png").write_bytes(b"corrupted")
        with self.assertRaises(ValueError):
            MEDIA.verify_stage(stage)


if __name__ == "__main__":
    unittest.main()
