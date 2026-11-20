"""Public command contract of the archive page writer.

The pages are generated from a published archive alone, so the fixture is an
archive built by the shared package builder plus the provenance fields the
release tool adds. Every assertion describes what a visitor reads.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_TOOL = ROOT / "scripts/package_archive.py"
PAGES_TOOL = ROOT / "site/scripts/archive_pages.py"


class ArchivePageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.archive = self.base / "archive"
        alpha = self.source("alpha", "Open a window", '((emacs "29.1"))', changelog="""# Changelog

## Unreleased

### Added

- `alpha-open` opens a window and keeps the `cursor` inside it.  Second
  sentence of the same entry.

### Fixed

- The window no longer closes twice.
""")
        beta = self.source("beta", "Shows a panel", '((emacs "29.1") (alpha "1.0.0"))')
        gamma = self.source("gamma", "Not in a role group", '((emacs "29.1"))')
        result = subprocess.run(
            [sys.executable, str(ARCHIVE_TOOL), "build", "--directory", str(self.archive),
             "--package", f"alpha={alpha}", "--package", f"beta={beta}",
             "--package", f"gamma={gamma}"],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.manifest = json.loads((self.archive / "manifest.json").read_text())
        self.dates = {"alpha": "2026-10-20T22:40:00+08:00",
                      "beta": "2026-09-01T09:00:00+08:00",
                      "gamma": "2026-09-02T10:00:00+08:00"}
        self.write_manifest()

    def source(self, name, summary, requires, changelog=""):
        root = self.base / f"src-{name}"
        root.mkdir(parents=True)
        (root / f"{name}.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n'
            f';;; {name}.el --- {summary}\n'
            ';; Version: 1.0.0\n'
            f';; Package-Requires: {requires}\n'
            f"(provide '{name})\n")
        if changelog:
            (root / "CHANGELOG.md").write_text(changelog)
        return root

    def write_manifest(self, *, dates=True):
        document = dict(self.manifest)
        document["sources"] = {"alpha": "a" * 40, "beta": "b" * 40, "gamma": "c" * 40}
        document["workspace"] = "d" * 40
        document.pop("updated", None)
        if dates:
            document["updated"] = self.dates
        (self.archive / "manifest.json").write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n")

    def pages(self, success=True):
        result = subprocess.run([sys.executable, str(PAGES_TOOL), "write",
                                 "--directory", str(self.archive)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def index(self):
        return (self.archive / "index.html").read_text()

    def page(self, name):
        return (self.archive / name / "index.html").read_text()

    def test_help_has_no_side_effects(self):
        for args in ((), ("help",), ("help", "write")):
            result = subprocess.run([sys.executable, str(PAGES_TOOL), *args],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--", result.stdout)
        self.assertFalse((self.archive / "index.html").exists())
        self.assertFalse((self.archive / "alpha").exists())

    def test_every_package_appears_once_and_only_page_files_are_written(self):
        before = {path.name for path in self.archive.iterdir() if path.is_file()}
        self.pages()
        rows = self.index().count('<tr data-search=')
        self.assertEqual(rows, len(self.manifest["packages"]))
        for name in ("alpha", "beta", "gamma"):
            self.assertEqual(self.index().count(f'<a href="{name}/"><strong>'), 1)
            self.assertTrue((self.archive / name / "index.html").is_file())
        written = {path.name for path in self.archive.iterdir() if path.is_file()}
        self.assertEqual(written - before, {"index.html"})
        self.assertEqual(sorted(path.name for path in self.archive.iterdir() if path.is_dir()),
                         ["alpha", "beta", "gamma"])
        for directory in ("alpha", "beta", "gamma"):
            self.assertEqual(sorted(path.name for path in (self.archive / directory).iterdir()),
                             ["index.html"])

    def test_index_shows_the_newest_shipped_change_of_each_package(self):
        self.pages()
        index = self.index()
        self.assertIn('<time datetime="2026-10-20T22:40:00+08:00"', index)
        self.assertIn(">20 Oct 2026</time>", index)
        self.assertIn(">1 Sep 2026</time>", index)
        self.assertIn('<span>latest change <time datetime="2026-10-20">20 Oct 2026</time></span>',
                      index)
        self.assertIn("Updated is the date of the newest commit", index)

    def test_detail_page_reports_freshness_dependencies_and_weight(self):
        self.pages()
        page = self.page("alpha")
        self.assertIn("updated <time datetime=\"2026-10-20T22:40:00+08:00\">20 Oct 2026</time>", page)
        self.assertIn("<dt>Updated</dt><dd><time datetime=\"2026-10-20T22:40:00+08:00\">"
                      "20 October 2026</time>", page)
        self.assertIn("newest commit that changed the files this package ships", page)
        self.assertIn('<a href="../alpha/">alpha 1.0.0</a>', self.page("beta"))
        self.assertIn('<dt>Used by</dt><dd><a href="../beta/">beta</a></dd>', page)
        self.assertRegex(page, r"<dt>Installs</dt><dd>[1-9][0-9]* files, [1-9][0-9]* KB downloaded")

    def test_latest_changes_read_the_changelog_shipped_with_the_version(self):
        self.pages()
        page = self.page("alpha")
        self.assertIn("Latest changes", page)
        self.assertIn("alpha-open opens a window and keeps the cursor inside it.", page)
        self.assertIn("The window no longer closes twice.", page)
        self.assertNotIn("`", page)
        self.assertIn(f"https://github.com/emacs-taf/alpha/blob/{'a' * 40}/CHANGELOG.md", page)
        self.assertNotIn("Latest changes", self.page("beta"))

    def test_community_package_names_its_author_and_its_own_repository(self):
        self.manifest["community"] = {"gamma": {"url": "https://github.com/someone/gamma",
                                                "license": "GPL-3.0-or-later",
                                                "maintainer": "someone"}}
        self.write_manifest()
        self.pages()
        index = self.index()
        self.assertNotIn('id="community"', index)
        applications = index[index.index('<section class="group" id="applications">'):]
        self.assertIn('<a href="gamma/"><strong>gamma</strong>', applications)
        self.assertIn('<td class="author"><a href="https://github.com/someone">someone</a></td>', index)
        self.assertIn('<td class="author"><a href="https://github.com/emacs-taf">emacs-taf</a></td>', index)
        page = self.page("gamma")
        self.assertIn('<a class="button" href="https://github.com/someone/gamma">Repository</a>', page)
        self.assertIn("<dt>Maintained by</dt><dd>someone</dd>", page)
        self.assertIn("<dt>License</dt><dd>GPL-3.0-or-later</dd>", page)
        self.assertIn("pick it in <code>M-x etaf-install</code>", page)
        self.assertNotIn("Maintained by", self.page("alpha"))

    def test_community_package_is_named_after_its_repository(self):
        self.manifest["community"] = {"gamma": {"url": "https://github.com/someone/gamma.el",
                                                "license": "GPL-3.0-or-later",
                                                "maintainer": "someone"}}
        self.write_manifest()
        self.pages()
        applications = self.index()[self.index().index('<section class="group" id="applications">'):]
        self.assertIn('<a href="gamma/"><strong>gamma.el</strong>', applications)
        page = self.page("gamma")
        self.assertIn("<h1>gamma.el</h1>", page)
        self.assertIn('<span aria-hidden="true">/</span><span>gamma.el</span>', page)
        self.assertIn("<title>gamma.el — ETAF package archive</title>", page)
        # The repository name is the label; the installable package keeps its own.
        self.assertIn("<dt>Package</dt><dd><code>gamma</code></dd>", page)
        self.assertIn("Install <code>gamma</code> with <code>M-x package-install</code>", page)
        self.assertIn('data-downloads="gamma"', page)
        self.assertIn('href="../gamma-1.0.0.tar"', page)
        self.assertNotIn('data-downloads="gamma.el"', page)

    def test_a_known_package_and_a_community_one_land_in_their_own_sections(self):
        # Rename two fixture builds to real catalog names so the role table, not
        # a default, decides each section.
        import shutil
        rename = {"alpha": "ebox", "beta": "etaf-tanks"}
        for old, new in rename.items():
            shutil.copyfile(self.archive / f"{old}-1.0.0.tar", self.archive / f"{new}-1.0.0.tar")
        for package in self.manifest["packages"]:
            if package["name"] in rename:
                new = rename[package["name"]]
                package["name"] = new
                package["file"] = f"{new}-1.0.0.tar"
        self.manifest["sources"] = {"ebox": "e" * 40, "etaf-tanks": "f" * 40, "gamma": "c" * 40}
        self.manifest["community"] = {"gamma": {"url": "https://github.com/someone/gamma",
                                                "license": "GPL-3.0-or-later",
                                                "maintainer": "someone",
                                                "group": "application"}}
        self.write_manifest()
        self.pages()
        index = self.index()
        framework = index[index.index('id="framework"'):index.index('id="applications"')]
        self.assertIn('<strong>ebox</strong>', framework)
        self.assertNotIn('etaf-tanks', framework)
        applications = index[index.index('id="applications"'):index.index('id="games"')]
        self.assertIn('<strong>gamma</strong>', applications)
        self.assertNotIn('ebox', applications)
        games = index[index.index('id="games"'):]
        self.assertIn('<strong>etaf-tanks</strong>', games)
        self.assertEqual(json.loads(self.pages().stdout)["unplaced"], [])

    def test_report_names_the_packages_no_section_places(self):
        """A name with neither a section nor a community record must be visible.

        The page shows it under Other, the report names it, and the publisher
        refuses to deploy it: a nameless section is a mistake, not a category.
        """
        self.pages()
        report = json.loads(self.pages().stdout)
        self.assertEqual(report["unplaced"], ["alpha", "beta", "gamma"])

    def test_packages_without_a_declared_group_keep_their_role(self):
        self.pages()
        index = self.index()
        # These fixture packages name no role, so the default group must not
        # file them under applications: they belong to Other.
        self.assertNotIn('id="framework"', index)
        self.assertNotIn('id="games"', index)
        self.assertNotIn('id="applications"', index)
        self.assertIn('<section class="group" id="other">', index)

    def test_archive_without_update_dates_still_writes_readable_pages(self):
        self.write_manifest(dates=False)
        self.pages()
        index = self.index()
        self.assertNotIn("<time datetime=", index)
        self.assertNotIn("latest change", index)
        self.assertEqual(index.count('<tr data-search='), 3)
        self.assertIn("Updated", index)


if __name__ == "__main__":
    unittest.main()
