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
# The archive primitives belong to the container that owns them.
CONTAINER = next((p for p in ROOT.parents if (p / "workspace.json").is_file()), ROOT.parents[1])
ARCHIVE_TOOL = CONTAINER / "scripts/package_archive.py"
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
        self.assertEqual(written - before, {"index.html", "og.png"})
        self.assertEqual(sorted(path.name for path in self.archive.iterdir() if path.is_dir()),
                         ["alpha", "beta", "gamma"])
        for directory in ("alpha", "beta", "gamma"):
            self.assertEqual(sorted(path.name for path in (self.archive / directory).iterdir()),
                             ["index.html"])

    def test_archive_and_package_pages_emit_section_og_card_with_page_metadata(self):
        self.pages()
        index_html = self.index()
        self.assertRegex(
            index_html,
            r'<meta property="og:image" content="https://etaf\.top/packages/og\.png\?v=[0-9a-f]{8}">',
        )
        self.assertIn('<meta property="og:image:alt" content="ETAF package archive">', index_html)
        index_png = (self.archive / "og.png").read_bytes()
        self.assertTrue(index_png.startswith(b"\x89PNG\r\n\x1a\n"))

        for name in ("alpha", "beta", "gamma"):
            detail_html = self.page(name)
            self.assertRegex(
                detail_html,
                r'<meta property="og:image" content="https://etaf\.top/packages/og\.png\?v=[0-9a-f]{8}">',
            )
            self.assertIn(
                f'<meta property="og:image:alt" content="{name} — ETAF package archive">',
                detail_html,
            )

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

    def test_core_packages_link_unified_etaf_repo_and_monorepo_commits(self):
        import shutil
        rename = {"alpha": "ebox", "beta": "etaf-tanks"}
        for old, new in rename.items():
            shutil.copyfile(self.archive / f"{old}-1.0.0.tar", self.archive / f"{new}-1.0.0.tar")
        for package in self.manifest["packages"]:
            if package["name"] in rename:
                new = rename[package["name"]]
                package["name"] = new
                package["file"] = f"{new}-1.0.0.tar"
        commit = "d" * 40
        document = dict(self.manifest)
        document["workspace"] = commit
        document["sources"] = {"ebox": commit, "etaf-tanks": commit, "gamma": commit}
        document["updated"] = {"ebox": "2026-10-20T22:40:00+08:00",
                               "etaf-tanks": "2026-09-01T09:00:00+08:00",
                               "gamma": "2026-09-02T10:00:00+08:00"}
        (self.archive / "manifest.json").write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n")
        self.pages()
        ebox_page = self.page("ebox")
        self.assertIn('href="https://github.com/emacs-taf/etaf/tree/main/packages/ebox"', ebox_page)
        self.assertIn(f'href="https://github.com/emacs-taf/emacs-taf/commit/{commit}"', ebox_page)
        self.assertIn(f'href="https://github.com/emacs-taf/emacs-taf/blob/{commit}/core/packages/ebox/CHANGELOG.md"', ebox_page)
        tanks_page = self.page("etaf-tanks")
        self.assertIn('href="https://github.com/emacs-taf/etaf-tanks"', tanks_page)
        self.assertIn(f'href="https://github.com/emacs-taf/emacs-taf/commit/{commit}"', tanks_page)


class NativePageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.native_dir = Path(self.temp.name) / "native"
        self.native_dir.mkdir()

    def write_native_manifest(self, doc):
        (self.native_dir / "manifest.json").write_text(
            json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def run_write_native(self):
        result = subprocess.run(
            [sys.executable, str(PAGES_TOOL), "write-native", "--directory", str(self.native_dir)],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_native_page_leads_with_binary_names_separates_archived_versions_and_runtime_libs(self):
        manifest = {
            "schema": 1,
            "modules": {
                "etaf-video-mpv": {
                    "package": "etaf",
                    "current_version": "2",
                    "description": "Cross-platform libmpv GPU playback module.",
                    "used_by": ["etaf-video-player", "etaf-bili"],
                    "versions": {
                        "2": {
                            "status": "current",
                            "min_package_version": "0.3.14",
                            "summary": "Adds Windows and Linux GPU layers.",
                            "released": "2026-11-26T17:16:50Z",
                        },
                        "1": {
                            "status": "archived",
                            "max_package_version": "0.3.13",
                            "summary": "Initial bridge retained for older etaf.",
                            "released": "2026-11-25T13:42:04Z",
                        },
                    },
                },
                "etaf-md-typeset-native": {
                    "package": "etaf-md",
                    "current_version": "1",
                    "description": "QuickJS Mermaid and MathJax renderer.",
                    "used_by": ["etaf-md", "etaf-org"],
                    "versions": {
                        "1": {
                            "status": "current",
                            "min_package_version": "0.3.0",
                            "released": "2026-11-25T13:42:04Z",
                        },
                    },
                },
            },
            "artifacts": [
                {
                    "package": "etaf", "module": "etaf-video-mpv", "owner_module": "etaf-video-mpv",
                    "role": "module", "version": "1", "platform": "darwin-arm64",
                    "path": "etaf/1/etaf-video-mpv-v1-darwin-arm64.dylib",
                    "sha256": "1" * 64, "size": 34808, "built_at": "2026-11-25T13:42:04Z",
                },
                {
                    "package": "etaf", "module": "etaf-video-mpv", "owner_module": "etaf-video-mpv",
                    "role": "module", "version": "2", "platform": "darwin-arm64",
                    "path": "etaf/2/etaf-video-mpv-v2-darwin-arm64.dylib",
                    "sha256": "2" * 64, "size": 93960, "built_at": "2026-11-26T17:16:50Z",
                },
                {
                    "package": "etaf", "module": "etaf-video-mpv", "owner_module": "etaf-video-mpv",
                    "role": "module", "version": "2", "platform": "windows-x86_64",
                    "path": "etaf/2/etaf-video-mpv-v2-windows-x86_64.dll",
                    "sha256": "3" * 64, "size": 148712, "built_at": "2026-11-26T17:16:50Z",
                },
                {
                    "package": "etaf", "module": "libmpv-2", "owner_module": "etaf-video-mpv",
                    "role": "library", "runtime_name": "libmpv-2.dll",
                    "note": "Bundled Windows runtime library.",
                    "version": "2", "platform": "windows-x86_64",
                    "path": "etaf/2/libmpv-2-v2-windows-x86_64.dll",
                    "sha256": "4" * 64, "size": 121789952, "built_at": "2026-11-26T17:16:50Z",
                },
                {
                    "package": "etaf-md", "module": "etaf-md-typeset-native", "owner_module": "etaf-md-typeset-native",
                    "role": "module", "version": "1", "platform": "darwin-arm64",
                    "path": "etaf-md/1/etaf-md-typeset-native-v1-darwin-arm64.dylib",
                    "sha256": "5" * 64, "size": 3557936, "built_at": "2026-11-25T13:42:04Z",
                },
            ],
        }
        self.write_native_manifest(manifest)
        report = self.run_write_native()
        self.assertEqual(report["modules"], 2)
        self.assertEqual(report["artifacts"], 5)
        self.assertEqual(report["current"], 4)
        self.assertEqual(report["archived"], 1)

        html_text = (self.native_dir / "index.html").read_text(encoding="utf-8")
        # Primary row labels are binary filenames, never bare platform triples.
        self.assertIn('>etaf-video-mpv-v2-darwin-arm64.dylib</a>', html_text)
        self.assertNotIn('<strong>darwin-arm64</strong>', html_text)
        # Platform is rendered as a structured category button and support matrix column.
        self.assertIn('macOS · arm64', html_text)
        self.assertIn('Windows · x86_64', html_text)
        self.assertIn('+lib', html_text)
        # Companion runtime library is clearly badged and shows its cached runtime name.
        self.assertIn('Runtime lib', html_text)
        self.assertIn('cached as <code>libmpv-2.dll</code>', html_text)
        self.assertIn('Bundled Windows runtime library.', html_text)
        # v2 is outside the archived drawer; v1 is collapsed inside <details class="archived-drawer">.
        drawer_start = html_text.index('<details class="archived-drawer"')
        drawer_end = html_text.index('</details>', drawer_start)
        drawer = html_text[drawer_start:drawer_end]
        outside = html_text[:drawer_start] + html_text[drawer_end:]
        self.assertIn('etaf/1/etaf-video-mpv-v1-darwin-arm64.dylib', drawer)
        self.assertNotIn('etaf/2/etaf-video-mpv-v2-darwin-arm64.dylib', drawer)
        self.assertIn('etaf/2/etaf-video-mpv-v2-darwin-arm64.dylib', outside)
        # Copy SHA-256 and visible Download controls are present (no broken .tar-link class).
        self.assertIn(f'data-copy-text="{"2" * 64}"', html_text)
        self.assertIn('class="dl-btn"', html_text)
        self.assertNotIn('tar-link', html_text)
        # View switch supports By Module and By Platform.
        self.assertIn('data-view-mode="module"', html_text)
        self.assertIn('data-view-mode="platform"', html_text)
        # Native page emits its own dedicated OpenGraph card instead of reusing archive.png.
        self.assertRegex(
            html_text,
            r'<meta property="og:image" content="https://etaf\.top/native/og\.png\?v=[0-9a-f]{8}">',
        )
        self.assertIn('<meta property="og:image:alt" content="ETAF prebuilt native modules">', html_text)
        self.assertTrue((self.native_dir / "og.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

        # Verify check-archive.py --native passes against a real local HTTP server.
        import functools
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
        import threading

        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(
            QuietHandler, directory=str(self.native_dir)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            checked = subprocess.run(
                [sys.executable, str(ROOT / "site/scripts/check-archive.py"),
                 "--native", f"http://127.0.0.1:{server.server_port}/"],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            self.assertIn("ok=yes", checked.stdout)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_native_page_falls_back_cleanly_on_legacy_manifest_without_modules_catalog(self):
        legacy = {
            "schema": 1,
            "artifacts": [
                {
                    "package": "ekp", "module": "ekp", "version": "1.6",
                    "platform": "darwin-arm64", "path": "ekp/1.6/ekp-v1.6-darwin-arm64.dylib",
                    "sha256": "a" * 64, "size": 52184,
                },
            ],
        }
        self.write_native_manifest(legacy)
        report = self.run_write_native()
        self.assertEqual(report["modules"], 1)
        self.assertEqual(report["current"], 1)
        self.assertEqual(report["archived"], 0)
        html_text = (self.native_dir / "index.html").read_text(encoding="utf-8")
        self.assertIn('>ekp-v1.6-darwin-arm64.dylib</a>', html_text)
        self.assertNotIn('<details class="archived-drawer"', html_text)
        # Theme painting covers both html and body, aligns icon convention with the
        # landing/manual pages (dark -> moon, light -> sun), and syncs across pageshow/storage.
        self.assertIn('<html lang="en" data-theme="dark">', html_text)
        self.assertIn('html { -webkit-text-size-adjust: 100%; background-color: var(--paper); }', html_text)
        self.assertIn(':root[data-theme="dark"] .theme .moon { display: block; }', html_text)
        self.assertIn(':root[data-theme="light"] .theme .sun { display: block; }', html_text)
        self.assertIn("window.addEventListener('pageshow'", html_text)
        self.assertIn("window.addEventListener('storage'", html_text)


class MediaPageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.media_dir = Path(self.temp.name) / "media"
        self.media_dir.mkdir()

    def test_media_page_emits_dedicated_og_card(self):
        manifest = {
            "schema": 1,
            "assets": [
                {
                    "namespace": "site",
                    "path": "site/shots/etaf-ncm.webp",
                    "sha256": "a" * 64,
                    "size": 12345,
                },
                {
                    "namespace": "etaf-md",
                    "path": "etaf-md/etaf-md-wide.webp",
                    "sha256": "b" * 64,
                    "size": 23456,
                },
            ],
        }
        (self.media_dir / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(PAGES_TOOL), "write-media", "--directory", str(self.media_dir)],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        html_text = (self.media_dir / "index.html").read_text(encoding="utf-8")
        self.assertRegex(
            html_text,
            r'<meta property="og:image" content="https://etaf\.top/media/og\.png\?v=[0-9a-f]{8}">',
        )
        self.assertIn('<meta property="og:image:alt" content="ETAF media library">', html_text)
        self.assertTrue((self.media_dir / "og.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))


if __name__ == "__main__":
    unittest.main()
