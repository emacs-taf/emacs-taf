"""Release command contracts, including diagnostics that Emacs demotes to logs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
EMACS = os.environ.get("EMACS", "emacs")


@unittest.skipUnless(shutil.which(EMACS), "Release checks require Emacs")
class PackageReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "ekp"
        self.source.mkdir()
        self.archive = self.base / "archive"

    def build(self, body=""):
        (self.source / "ekp.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n;;; ekp.el --- Release fixture\n'
            ';; Version: 1.0.0\n;; Package-Requires: ((emacs "29.1"))\n'
            f"{body}\n(defun ekp-hyphen-create (&optional _lang _file _left _right) t)\n"
            "(provide 'ekp)\n")
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/package_archive.py"), "build",
             "--directory", str(self.archive), "--package", f"ekp={self.source}",
             "--package", f"etaf-install={ROOT}"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def verify(self, *extra, success=True):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/package-release.py"), "verify",
             "--directory", str(self.archive), "--emacs", EMACS, "--target", "ekp", *extra],
            capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_verification_covers_entry_and_standard_install_in_separate_profiles(self):
        self.build()
        self.verify()
        report = json.loads((self.archive / "installation.json").read_text())
        self.assertEqual(report["manifest_sha256"], hashlib.sha256(
            (self.archive / "manifest.json").read_bytes()).hexdigest())
        self.assertEqual({item["entry"] for item in report["installations"]},
                         {"etaf-install", "package-install"})
        self.assertTrue(all(item["status"] == "ok" and item["emacs"] and item["system"]
                            for item in report["installations"]))
        self.assertEqual({item["target"] for item in report["installations"]}, {"ekp"})

    def test_demoted_reload_errors_are_failures_even_when_emacs_exits_successfully(self):
        self.build('(message "Error in package--load-files-for-activation: fixture failure")')
        result = self.verify("--direct", success=False)
        self.assertIn("Installation diagnostics", result.stderr)
        self.assertIn("Error in package--load-files-for-activation", result.stderr)
        self.assertFalse((self.archive / "installation.json").exists())
        self.assertTrue((self.archive / "installation-ekp-direct.log").is_file())

    def test_stdout_diagnostics_are_not_misreported_as_invalid_json(self):
        self.build('(princ "Warning: fixture diagnostic\\n")')
        result = self.verify("--direct", success=False)
        self.assertIn("Installation diagnostics", result.stderr)
        self.assertIn("Warning: fixture diagnostic", result.stderr)

    def test_real_compilation_warnings_block_verification(self):
        self.build('(defun ekp-release-fixture () (ekp-missing-function))')
        result = self.verify("--direct", success=False)
        self.assertIn("Installation diagnostics", result.stderr)
        self.assertIn("Warning:", result.stderr)

    def test_bad_installation_cannot_leave_earlier_success_evidence(self):
        self.build()
        self.verify()
        (self.archive / "ekp-1.0.0.tar").write_bytes(b"broken archive")
        result = self.verify(success=False)
        self.assertIn("checksum", result.stderr)
        self.assertFalse((self.archive / "installation.json").exists())

    def test_entry_load_error_keeps_a_log_but_no_success_report(self):
        self.build('(error "Fixture entry failed")')
        self.verify("--direct", success=False)
        self.assertFalse((self.archive / "installation.json").exists())
        self.assertIn("Fixture entry failed", (self.archive / "installation-ekp-direct.log").read_text())


class PackageReleaseBuildTests(unittest.TestCase):
    def git(self, repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self, repo):
        self.git(repo, "add", ".")
        self.git(repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
        return self.git(repo, "rev-parse", "HEAD")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "workspace"
        (self.root / "scripts").mkdir(parents=True)
        for name in ("package-release.py", "package_archive.py"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / ".gitignore").write_text("ecss/\n__pycache__/\n")
        (self.root / "etaf-install.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n;;; etaf-install.el --- Fixture\n'
            ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1") (ecss "1.0.0"))\n'
            "(provide 'etaf-install)\n")
        self.provider = self.root / "ecss"
        (self.provider / "data").mkdir(parents=True)
        (self.provider / "data/fixture.txt").write_text("pinned resource")
        (self.provider / "ecss.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n;;; ecss.el --- Fixture\n'
            ';; Version: 1.0.0\n;; Package-Requires: ((emacs "29.1"))\n'
            "(provide 'ecss)\n")
        self.git(self.provider, "init", "-q")
        self.provider_revision = self.commit(self.provider)
        (self.root / "workspace.json").write_text(json.dumps({"repositories": {
            "ecss": {"revision": self.provider_revision}}}))
        (self.root / "release-dependencies.json").write_text(json.dumps(
            {"schema": 1, "packages": {"ecss": {"resources": ["data"]}}}))
        self.git(self.root, "init", "-q")
        self.root_revision = self.commit(self.root)
        self.output = self.base / "archive"

    def build(self, success=True):
        result = subprocess.run([sys.executable, str(self.root / "scripts/package-release.py"),
                                 "build", "--directory", str(self.output)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_build_uses_checkpoint_objects_not_provider_working_copies_or_latest_heads(self):
        (self.provider / "data/fixture.txt").write_text("newer unrelated provider revision")
        self.commit(self.provider)
        (self.provider / "ecss.el").write_text("uncommitted provider work")
        self.build()
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["workspace"], self.root_revision)
        self.assertEqual(manifest["sources"]["ecss"], self.provider_revision)
        with tarfile.open(self.output / "ecss-1.0.0.tar") as archive:
            self.assertEqual(archive.extractfile("ecss-1.0.0/data/fixture.txt").read(), b"pinned resource")
            self.assertIn(b"(provide 'ecss)", archive.extractfile("ecss-1.0.0/ecss.el").read())

    def test_unsealed_root_and_existing_release_are_rejected(self):
        (self.root / "unsealed.txt").write_text("not committed")
        self.assertIn("Commit the workspace", self.build(success=False).stderr)
        self.assertFalse(self.output.exists())
        (self.root / "unsealed.txt").unlink()
        self.build()
        original = (self.output / "manifest.json").read_bytes()
        self.assertIn("Refusing to replace", self.build(success=False).stderr)
        self.assertEqual((self.output / "manifest.json").read_bytes(), original)

    def test_missing_and_insufficient_dependencies_leave_no_partial_release(self):
        entry = self.root / "etaf-install.el"
        original = entry.read_text()
        for requirement in ('(missing "1.0.0")', '(ecss "2.0.0")'):
            with self.subTest(requirement=requirement):
                entry.write_text(original.replace('(ecss "1.0.0")', requirement))
                self.commit(self.root)
                self.assertIn("dependency", self.build(success=False).stderr)
                self.assertFalse(self.output.exists())
                self.assertFalse(list(self.base.glob(".etaf-release-*")))


if __name__ == "__main__":
    unittest.main()
