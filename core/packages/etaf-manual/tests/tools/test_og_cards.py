"""Unit tests for per-page OpenGraph preview card generation."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "site/scripts"))
import og_cards


def png_dimensions(data: bytes) -> tuple[int, int]:
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    width, height = struct.unpack(">II", data[16:24])
    return width, height


class OgCardsTests(unittest.TestCase):
    def test_build_svg_handles_long_english_and_chinese_titles_and_escapes_xml(self):
        spec_en = og_cards.CardSpec(
            title="Actions, Behaviors & Error Boundaries <Extended>",
            subtitle="Reusable behavioral mixins, declarative command dispatch and isolated recovery boundaries for interactive ETAF views.",
            url_label="etaf.top/actions-behaviors-and-error-boundaries",
            footer_left="REFERENCE MANUAL · THE ETAF PROGRAMMING MODEL",
            footer_right="CHAPTER 11",
            lang="en",
        )
        svg_en = og_cards.build_svg(spec_en)
        self.assertIn("&amp;", svg_en)
        self.assertIn("&lt;Extended&gt;", svg_en)
        self.assertIn("etaf.top/actions-behaviors-and-error-boundaries", svg_en)
        self.assertIn("CHAPTER 11", svg_en)

        spec_zh = og_cards.CardSpec(
            title="增量更新与发布管线（保留式渲染核心机制说明）",
            subtitle="介绍 ETAF 保留式渲染树如何按变更范围做最小补丁，避免整屏重绘并维持帧率稳定。",
            url_label="etaf.top/zh-cn/incremental-updates-and-publication",
            footer_left="参考手册 · 布局与渲染",
            footer_right="第 27 章",
            lang="zh-CN",
        )
        svg_zh = og_cards.build_svg(spec_zh)
        self.assertIn("第 27 章", svg_zh)
        self.assertIn("参考手册 · 布局与渲染", svg_zh)

    def test_render_site_manifest_renders_1200x630_pngs_caches_and_prunes_stale_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp)
            (site / "src").mkdir()
            stale = site / "public/og/manual/obsolete.png"
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"stale")

            manifest = [
                {
                    "key": "landing-en",
                    "output": "landing.png",
                    "url_label": "etaf.top",
                    "title": "Emacs Text Application Framework",
                    "subtitle": "Build complete text applications in Emacs.",
                    "footer_left": "EMACS TEXT APPLICATION FRAMEWORK",
                    "footer_right": "EMACS 29.1+",
                    "lang": "en",
                },
                {
                    "key": "manual/zh-cn/introduction",
                    "output": "manual/zh-cn/introduction.png",
                    "url_label": "etaf.top/zh-cn/introduction",
                    "title": "引言",
                    "subtitle": "本书是 ETAF 的参考手册，描述框架各包的全部公共接口与工作机制。",
                    "footer_left": "参考手册 · 总论",
                    "footer_right": "第 1 章",
                    "lang": "zh-CN",
                },
            ]
            (site / "src/og-manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
            )

            hashes_first = og_cards.render_site_manifest(site)
            self.assertFalse(stale.exists(), "stale OG PNG must be pruned")
            self.assertEqual(set(hashes_first), {"landing-en", "manual/zh-cn/introduction"})
            en_png = (site / "public/og/landing.png").read_bytes()
            zh_png = (site / "public/og/manual/zh-cn/introduction.png").read_bytes()
            self.assertEqual(png_dimensions(en_png), (1200, 630))
            self.assertEqual(png_dimensions(zh_png), (1200, 630))
            self.assertNotEqual(en_png, zh_png)

            # Second run with unchanged manifest hits cache and produces identical hashes.
            hashes_second = og_cards.render_site_manifest(site)
            self.assertEqual(hashes_first, hashes_second)


if __name__ == "__main__":
    unittest.main()
