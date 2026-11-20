"""Public command contract of the source-only package.el archive builder."""
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMAND = [sys.executable, str(ROOT / "scripts/package_archive.py")]


class PackageArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        (self.source / "sample.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n'
            ';;; sample.el --- An archive fixture\n'
            ';; Version: 1.2.3\n;; Package-Requires: ((emacs "29.1"))\n'
            "(provide 'sample)\n")
        (self.source / "LICENSE").write_text("Fixture license\n")
        (self.source / "lisp").mkdir()
        (self.source / "lisp/sample-runtime.el").write_text(
            ";;; -*- lexical-binding: t; -*-\n(provide 'sample-runtime)\n")

    def call(self, *args, success=True):
        result = subprocess.run([*COMMAND, *map(str, args)], capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def build(self, output, *extra, success=True):
        return self.call("build", "--directory", output, "--package", f"sample={self.source}",
                         *extra, success=success)

    def test_help_has_no_side_effects_and_supports_subcommands(self):
        for args in ((), ("help",), ("help", "build")):
            result = self.call(*args)
            self.assertIn("--", result.stdout)

    def test_reproducible_archive_keeps_runtime_and_licenses_but_not_generated_files(self):
        for name in ("sample.elc", "lisp/sample-runtime.eln", "unrelated.txt"):
            (self.source / name).write_text("not shipped")
        one, two = self.base / "one", self.base / "two"
        self.build(one)
        (self.source / "sample.el").touch()
        self.build(two)
        self.assertEqual((one / "sample-1.2.3.tar").read_bytes(), (two / "sample-1.2.3.tar").read_bytes())
        with tarfile.open(one / "sample-1.2.3.tar") as archive:
            self.assertEqual(sorted(archive.getnames()), [
                "sample-1.2.3/LICENSE", "sample-1.2.3/lisp/sample-runtime.el",
                "sample-1.2.3/sample-pkg.el", "sample-1.2.3/sample.el"])
            self.assertTrue(all(member.mtime == 0 for member in archive.getmembers()))
        self.call("verify", "--directory", one)

    def test_explicit_resources_include_nested_data_and_preserve_upstream_names(self):
        (self.source / "dictionaries/zh-CN").mkdir(parents=True)
        (self.source / "dictionaries/zh-CN/COPYING.txt").write_text("license")
        (self.source / "dictionaries/zh-CN/rules.txt").write_text("rules")
        (self.source / "dictionaries/.private").write_text("not shipped")
        output = self.base / "archive"
        self.build(output, "--resource", "sample=dictionaries")
        with tarfile.open(output / "sample-1.2.3.tar") as archive:
            self.assertIn("sample-1.2.3/dictionaries/zh-CN/rules.txt", archive.getnames())
            self.assertNotIn("sample-1.2.3/dictionaries/.private", archive.getnames())

    def test_ship_globs_and_declared_dependencies_cover_a_foreign_layout(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import package_archive
        plugins = self.source / "plugins"
        plugins.mkdir()
        (plugins / "sample-plugin.el").write_text(";;; -*- lexical-binding: t; -*-\n(provide 'sample-plugin)\n")
        (self.source / "sample-extra.el").write_text(";;; -*- lexical-binding: t; -*-\n(provide 'sample-extra)\n")
        (self.source / "private.txt").write_text("not shipped\n")
        output = self.base / "archive"
        manifest = package_archive.build(
            output, {"sample": self.source}, {},
            {"sample": ["*.el", "plugins/*.el"]}, {"sample": [["emacs", "29.1"], ["etaf", "0.3.0"]]})
        package = manifest["packages"][0]
        self.assertEqual(package["requirements"], [["emacs", "29.1"], ["etaf", "0.3.0"]])
        with tarfile.open(output / "sample-1.2.3.tar") as archive:
            names = sorted(archive.getnames())
        self.assertEqual(names, ["sample-1.2.3/plugins/sample-plugin.el",
                                 "sample-1.2.3/sample-extra.el", "sample-1.2.3/sample-pkg.el",
                                 "sample-1.2.3/sample.el"])

    def test_existing_output_is_never_replaced(self):
        output = self.base / "archive"
        self.build(output)
        before = (output / "sample-1.2.3.tar").read_bytes()
        result = self.build(output, success=False)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(before, (output / "sample-1.2.3.tar").read_bytes())

    def test_tampered_tar_and_index_are_rejected(self):
        output = self.base / "archive"
        self.build(output)
        index = output / "archive-contents"
        original = index.read_bytes()
        index.write_text("(1)")
        self.assertIn("index", self.call("verify", "--directory", output, success=False).stderr)
        index.write_bytes(original)
        (output / "sample-1.2.3.tar").write_bytes(b"corrupt")
        self.assertIn("checksum", self.call("verify", "--directory", output, success=False).stderr)

    def test_older_manifest_schema_is_not_silently_reinterpreted(self):
        output = self.base / "archive"
        self.build(output)
        path = output / "manifest.json"
        manifest = json.loads(path.read_text())
        self.assertEqual(manifest["schema"], 2)
        manifest["schema"] = 1
        manifest["packages"][0]["requirements"] = '((emacs "29.1"))'
        path.write_text(json.dumps(manifest))
        result = self.call("verify", "--directory", output, success=False)
        self.assertIn("schema 2", result.stderr)
        self.assertIn("rebuild", result.stderr)

    def test_update_dates_must_be_iso_and_cover_every_package(self):
        output = self.base / "archive"
        self.build(output)
        path = output / "manifest.json"
        manifest = json.loads(path.read_text())
        for dates in ({"sample": "2026-10-20T22:40:00+08:00"},
                      {"sample": "2026-10-20T14:40:00Z"}):
            manifest["updated"] = dates
            path.write_text(json.dumps(manifest))
            self.call("verify", "--directory", output)
        for dates in ({"sample": "2026-10-20"}, {"sample": "20 October 2026"},
                      {"other": "2026-10-20T22:40:00+08:00"}, {},
                      {"sample": 20261020}, ["2026-10-20T22:40:00+08:00"]):
            with self.subTest(updated=dates):
                manifest["updated"] = dates
                path.write_text(json.dumps(manifest))
                result = self.call("verify", "--directory", output, success=False)
                self.assertIn("update dates", result.stderr)

    def test_unsafe_manifest_paths_are_rejected(self):
        output = self.base / "archive"
        self.build(output)
        path = output / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["packages"][0]["file"] = "../outside.tar"
        path.write_text(json.dumps(manifest))
        self.assertIn("identity", self.call("verify", "--directory", output, success=False).stderr)

    def test_missing_resource_and_bad_metadata_leave_no_partial_output(self):
        for resource in ("missing", "../source", str(self.source)):
            output = self.base / "archive"
            self.build(output, "--resource", f"sample={resource}", success=False)
            self.assertFalse(output.exists())
        entry = self.source / "sample.el"
        entry.write_text(entry.read_text().replace('((emacs "29.1"))', '(eval "bad")'))
        self.build(self.base / "archive", success=False)
        self.assertFalse((self.base / "archive").exists())
        self.assertFalse(list(self.base.glob(".package-build-*")))

    def test_resource_symlinks_cannot_import_files_outside_the_package(self):
        (self.source / "data").mkdir()
        (self.base / "private").write_text("private")
        try:
            (self.source / "data/linked").symlink_to(self.base / "private")
        except OSError as error:
            self.skipTest(f"This environment cannot create symlinks: {error}")
        self.build(self.base / "archive", "--resource", "sample=data", success=False)
        self.assertFalse((self.base / "archive").exists())


if __name__ == "__main__":
    unittest.main()
