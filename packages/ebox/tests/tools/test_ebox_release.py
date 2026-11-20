"""Public command contract of Ebox's pinned standalone release adapter."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "ebox"
        self.dependencies = self.base / "deps"
        self.lock = {"schema": 1, "dependencies": {}, "optional": {}}
        for name, version in (("ebox", "3.0.0"), ("ecss", "0.1.0"), ("ekp", "1.0.0")):
            source = self.root if name == "ebox" else self.dependencies / name
            source.mkdir(parents=True)
            (source / f"{name}.el").write_text(
                f';;; -*- lexical-binding: t; -*-\n;;; {name}.el --- Release fixture\n'
                f';; Version: {version}\n;; Package-Requires: ((emacs "29.1"))\n'
                f"(provide '{name})\n")
            (source / "LICENSE").write_text("Fixture license\n")
            if name == "ebox":
                (source / "docs").mkdir()
                (source / "docs/architecture.md").write_text("# Architecture\n")
            if name == "ekp":
                for directory in ("native", "dictionaries"):
                    (source / directory).mkdir()
                    (source / directory / "COPYING").write_text("Fixture license\n")
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(["git", "add", "."], cwd=source, check=True)
            subprocess.run(["git", "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid",
                            "commit", "-qm", "fixture"], cwd=source, check=True)
            revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
            if name != "ebox":
                section = "optional" if name == "ekp" else "dependencies"
                self.lock[section][name] = {"url": f"https://example.invalid/{name}.git", "revision": revision}
        (self.root / "release-dependencies.json").write_text(json.dumps(self.lock))
        (self.root / "scripts").mkdir()
        for name in ("ebox-release.py", "package_archive.py"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        self.command = [sys.executable, str(self.root / "scripts/ebox-release.py")]

    def call(self, *arguments, success=True):
        result = subprocess.run([*self.command, *map(str, arguments)], text=True,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def build(self, output, *extra, success=True):
        return self.call("build", "--directory", output, "--dependencies", self.dependencies,
                         *extra, success=success)

    def test_default_release_keeps_standalone_boundary_and_is_reproducible(self):
        first, second = self.base / "first", self.base / "second"
        self.build(first)
        self.build(second)
        manifest = json.loads((first / "manifest.json").read_text())
        self.assertEqual({p["name"] for p in manifest["packages"]}, {"ecss", "ebox"})
        for package in manifest["packages"]:
            self.assertEqual((first / package["file"]).read_bytes(), (second / package["file"]).read_bytes())
        with tarfile.open(first / "ebox-3.0.0.tar") as archive:
            self.assertIn("ebox-3.0.0/docs/architecture.md", archive.getnames())
            self.assertIn("ebox-3.0.0/LICENSE", archive.getnames())

    def test_optional_ekp_includes_its_runtime_resources_only_when_selected(self):
        output = self.base / "optional"
        self.build(output, "--with-ekp")
        with tarfile.open(output / "ekp-1.0.0.tar") as archive:
            self.assertIn("ekp-1.0.0/dictionaries/COPYING", archive.getnames())
            self.assertIn("ekp-1.0.0/native/COPYING", archive.getnames())

    def test_modified_or_wrong_revision_dependency_is_rejected_before_build(self):
        output = self.base / "archive"
        entry = self.dependencies / "ecss/ecss.el"
        entry.write_text(entry.read_text() + "; modified\n")
        result = self.build(output, success=False)
        self.assertIn("dependency must be clean", result.stderr)
        self.assertFalse(output.exists())

    def test_existing_dependency_and_archive_outputs_are_preserved(self):
        output = self.base / "archive"
        self.build(output)
        before = (output / "ebox-3.0.0.tar").read_bytes()
        self.build(output, success=False)
        self.call("deps", "--directory", self.dependencies, success=False)
        self.assertEqual(before, (output / "ebox-3.0.0.tar").read_bytes())

    def test_symbolic_revisions_are_rejected_without_network_access(self):
        self.lock["dependencies"]["ecss"]["revision"] = "main"
        (self.root / "release-dependencies.json").write_text(json.dumps(self.lock))
        result = self.build(self.base / "archive", success=False)
        self.assertIn("full commit hash", result.stderr)

    def test_modified_archive_is_rejected_before_starting_emacs(self):
        output = self.base / "archive"
        self.build(output)
        (output / "ebox-3.0.0.tar").write_bytes(b"corrupt")
        result = self.call("verify", "--directory", output, "--emacs", "must-not-start", success=False)
        self.assertIn("checksum mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
