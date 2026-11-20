"""Contract of scripts/check-references.py: external links into the book."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT.parent
REQUIRED_SIBLINGS = (
    'ecss', 'ekp', 'ebox', 'etaf', 'etaf-ui', 'etaf-db',
    'ebox-playground', 'etaf-playground',
)


class CheckReferencesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.workspace = Path(self.directory.name)
        self.manuscript = self.workspace / 'etaf-manual'
        (self.workspace / 'consumer/.git').mkdir(parents=True)
        self.write_book()

    def tearDown(self):
        self.directory.cleanup()

    def write(self, name, text):
        path = self.workspace / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text))

    def write_book(self):
        description = {
            'languages': ['en', 'zh-CN'],
            'appendices': [{'id': 'generated-appendix', 'generate': 'appendix'}],
            'indices': [{'id': 'generated-index', 'generate': 'index'}],
        }
        self.write('etaf-manual/book/book.json', json.dumps(description))
        self.write('etaf-manual/book/en/chapter.md', """\
            # Chapter

            ## [Linked section](other.md)

            ## Repeated

            ## Repeated
        """)
        self.write('etaf-manual/book/zh-CN/chapter.md', """\
            # 章节

            ## 中文标题
        """)

    def run_check(self):
        return subprocess.run(
            [sys.executable, str(ROOT / 'scripts/check-references.py'),
             '--root', str(self.workspace), '--manuscript', str(self.manuscript)],
            capture_output=True, text=True, timeout=60,
        )

    def write_references(self, text):
        self.write('consumer/README.md', text)

    def test_valid_links_and_chinese_anchor_pass(self):
        self.write_references("""\
            [English](https://etaf.top/chapter/#linked-section)
            [Chinese](https://etaf.top/zh-cn/chapter/#%E4%B8%AD%E6%96%87%E6%A0%87%E9%A2%98)
            [Repeated](https://etaf.top/chapter/#repeated-1)
        """)
        result = self.run_check()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_configuration_literals_are_not_manual_navigation_links(self):
        self.write_references('''\
            The package archive is `https://etaf.top/packages/`.
            ```elisp
            (add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))
            ```
            [Read the chapter](https://etaf.top/chapter/)
        ''')
        result = self.run_check()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_code_link_labels_do_not_hide_invalid_destinations(self):
        self.write_references('''\
            [`chapter`](https://etaf.top/chapter/#missing)
            ```text
            https://etaf.top/literal-value/
            ```
            https://etaf.top/real-missing-chapter/
        ''')
        result = self.run_check()
        self.assertEqual(1, result.returncode)
        self.assertIn('target heading does not exist', result.stderr)
        self.assertIn('book/en/real-missing-chapter.md', result.stderr)
        self.assertNotIn('literal-value', result.stderr)

    def test_archive_url_is_not_a_chapter(self):
        self.write_references("""\
            The official archive is [etaf.top](https://etaf.top/packages/).
        """)
        result = self.run_check()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_missing_chapter_is_reported(self):
        self.write_references('https://etaf.top/missing/\n')
        result = self.run_check()
        self.assertEqual(1, result.returncode)
        self.assertIn('consumer/README.md:1: target chapter does not exist: book/en/missing.md',
                      result.stderr)

    def test_missing_anchor_is_reported(self):
        self.write_references('https://etaf.top/chapter/#missing\n')
        result = self.run_check()
        self.assertEqual(1, result.returncode)
        self.assertIn('consumer/README.md:1: target heading does not exist: '
                      'book/en/chapter.md#missing', result.stderr)

    def test_generated_chapters_skip_file_and_anchor_checks(self):
        self.write_references("""\
            https://etaf.top/generated-appendix/#missing
            https://etaf.top/zh-cn/generated-index/#missing
        """)
        result = self.run_check()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_retired_repository_path_is_reported(self):
        self.write_references(
            'https://example.test/emacs-taf/etaf-manual/src/branch/main/book/en/chapter.md\n')
        result = self.run_check()
        self.assertEqual(1, result.returncode)
        self.assertIn('consumer/README.md:1: retired repository path, '
                      'use https://etaf.top/chapter/', result.stderr)

    def test_real_workspace_passes_when_siblings_are_available(self):
        missing = [name for name in REQUIRED_SIBLINGS if not (WORKSPACE / name).is_dir()]
        if missing:
            self.skipTest('workspace siblings are unavailable: ' + ', '.join(missing))
        result = subprocess.run(
            [sys.executable, str(ROOT / 'scripts/check-references.py')],
            cwd=ROOT, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(0, result.returncode, result.stderr)


if __name__ == '__main__':
    unittest.main()
