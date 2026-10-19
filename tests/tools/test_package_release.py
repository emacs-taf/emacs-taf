"""Release command contracts, including diagnostics that Emacs demotes to logs."""
import hashlib
import importlib.util
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
RELEASE = None


def release_module():
    """Load the release CLI without requiring a package installation."""
    global RELEASE
    if RELEASE is None:
        sys.path.insert(0, str(ROOT / "scripts"))
        spec = importlib.util.spec_from_file_location(
            "package_release", str(ROOT / "scripts" / "package-release.py"))
        RELEASE = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(RELEASE)
    return RELEASE


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


class PackageReleaseDiagnosticAttributionTests(unittest.TestCase):
    """A third-party activation error is not evidence about this archive."""

    def test_third_party_activation_error_is_ignored(self):
        text = (
            "Compiling /tmp/elpa/ekp-1.0.0/ekp.el...\n"
            "GEN      seq-autoloads.el\n"
            "Error in package--load-files-for-activation: "
            "(file-missing Cannot open load file seq-25)\n")
        self.assertEqual(release_module().scan_diagnostics(text, ["ekp"]), [])

    def test_third_party_compilation_warning_is_ignored(self):
        text = (
            "Compiling /tmp/elpa/seq-2.24/seq-24.el...\n"
            "seq-24.el:76:8: Warning: fixture third-party warning\n")
        self.assertEqual(release_module().scan_diagnostics(text, ["ekp"]), [])

    def test_archive_activation_error_is_kept(self):
        text = (
            "Checking /tmp/elpa/ekp-1.0.0...\n"
            "GEN      ekp-autoloads.el\n"
            "Error in package--load-files-for-activation: fixture failure\n")
        self.assertEqual(len(release_module().scan_diagnostics(text, ["ekp"])), 1)


class StandardArchiveSnapshotTests(unittest.TestCase):
    """The prefetch manifest is a gate, not a best-effort download."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.archives = []
        for name in ("gnu", "nongnu", "melpa"):
            archive = self.directory / name
            archive.mkdir()
            index = archive / "archive-contents"
            index.write_text("(1)\n", encoding="utf-8")
            self.archives.append({
                "name": name,
                "url": f"https://example.invalid/{name}/",
                "sha256": hashlib.sha256(index.read_bytes()).hexdigest(),
            })
        self.write_manifest()

    def write_manifest(self, packages=None):
        (self.directory / "manifest.json").write_text(json.dumps({
            "schema": 1,
            "archives": self.archives,
            "packages": packages or [],
        }), encoding="utf-8")

    def test_valid_snapshot_is_accepted(self):
        release_module().verify_standard_archives(self.directory)

    def test_missing_index_is_rejected(self):
        (self.directory / "nongnu" / "archive-contents").unlink()
        with self.assertRaises(ValueError):
            release_module().verify_standard_archives(self.directory)

    def test_corrupt_index_is_rejected(self):
        (self.directory / "gnu" / "archive-contents").write_text("(2)\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            release_module().verify_standard_archives(self.directory)


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


class PackageReleaseStageTests(unittest.TestCase):
    """Synthetic reports exercise gate inputs; real Emacs checks are above."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "workspace"
        (self.root / "scripts").mkdir(parents=True)
        for name in ("package-release.py", "package_archive.py", "install-smoke.el"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        shutil.copyfile(ROOT / "etaf-install.el", self.root / "etaf-install.el")
        targets = ("etaf-ui", "etaf", "etaf-manual", "ekp", "etaf-db")
        (self.root / ".gitignore").write_text("__pycache__/\n" + "".join(f"{name}/\n" for name in targets))
        repositories = {}
        for name in targets:
            source = self.root / name
            source.mkdir()
            (source / f"{name}.el").write_text(
                f';;; -*- lexical-binding: t; -*-\n;;; {name}.el --- Fixture\n'
                f';; Version: 1.0.0\n;; Package-Requires: ((emacs "29.1"))\n(provide \'{name})\n')
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            repositories[name] = {"revision": self.commit(source)}
        (self.root / "workspace.json").write_text(json.dumps({"repositories": repositories}))
        (self.root / "release-dependencies.json").write_text(json.dumps(
            {"schema": 1, "packages": {name: {} for name in targets}}))
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.commit(self.root)
        self.archive = self.base / "archive"
        self.command("build", "--directory", str(self.archive))
        self.report = {"schema": 1, "manifest_sha256": self.digest(self.archive / "manifest.json"),
                       "validator_sha256": self.digest(self.root / "scripts/package-release.py"),
                       "smoke_sha256": self.digest(self.root / "scripts/install-smoke.el"),
                       "installations": [{"target": target, "entry": entry, "status": "ok",
                                          "emacs": "29.1", "system": "gnu/linux"}
                                         for target in targets for entry in ("etaf-install", "package-install")]}
        self.output = self.base / "public"

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def commit(repo):
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "fixture"], check=True)
        return subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()

    def command(self, *arguments, success=True):
        result = subprocess.run([sys.executable, str(self.root / "scripts/package-release.py"), *arguments],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def stage(self, success=True):
        (self.archive / "installation.json").write_text(json.dumps(self.report))
        result = self.command("stage", "--directory", str(self.archive), "--output", str(self.output), success=success)
        if not success:
            self.assertFalse(self.output.exists())
        return result

    def test_stage_exports_only_public_files_and_never_local_evidence(self):
        (self.archive / "installation-etaf-entry.log").write_text("private profile path")
        (self.archive / "unrelated.txt").write_text("private metadata")
        self.stage()
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual({path.name for path in self.output.iterdir()},
                         {"manifest.json", "archive-contents", *(item["file"] for item in manifest["packages"])})
        self.assertEqual(set(manifest), {"schema", "workspace", "sources", "packages"})
        self.assertEqual((self.output / "archive-contents").read_bytes(), (self.archive / "archive-contents").read_bytes())
        for package in manifest["packages"]:
            self.assertEqual(self.digest(self.output / package["file"]), package["sha256"])

    def test_partial_duplicate_failed_and_mixed_runtime_evidence_is_rejected(self):
        original = json.loads(json.dumps(self.report))
        for mutation in ("partial", "duplicate", "failed", "mixed", "old-emacs"):
            with self.subTest(mutation=mutation):
                self.report = json.loads(json.dumps(original))
                rows = self.report["installations"]
                if mutation == "partial":
                    rows.pop()
                elif mutation == "duplicate":
                    rows[-1] = rows[0]
                elif mutation == "failed":
                    rows[0]["status"] = "failed"
                elif mutation == "mixed":
                    rows[0]["system"] = "windows-nt"
                else:
                    for row in rows:
                        row["emacs"] = "28.2"
                # b983b8a reworded the refusal; the check is the same gate.
                self.assertIn("recorded targets through both installation paths",
                              self.stage(success=False).stderr)

    def test_publisher_refuses_partial_evidence_before_building_or_connecting(self):
        self.report["installations"].pop()
        (self.archive / "installation.json").write_text(json.dumps(self.report))
        publisher = ROOT / "etaf-manual/site/scripts/publish.py"
        if not publisher.is_file():
            self.skipTest("Site publisher checkout is not available")
        result = subprocess.run([sys.executable, str(publisher), "--packages", str(self.archive)],
                                env=dict(os.environ, ETAF_TOP_HOST="invalid host"),
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        # Any local gate may refuse first; what matters is that the publisher
        # stops before validating transport or contacting the host.
        self.assertIn("error=publish", result.stderr)
        self.assertIn("error=release", result.stderr)
        self.assertNotIn("Invalid ETAF_TOP_ROOT", result.stderr)

    def test_stale_validator_smoke_or_archive_evidence_is_rejected(self):
        for key in ("validator_sha256", "smoke_sha256", "manifest_sha256"):
            with self.subTest(key=key):
                old = self.report[key]
                self.report[key] = "0" * 64
                self.assertIn("stale", self.stage(success=False).stderr)
                self.report[key] = old

    def test_development_or_mismatched_provenance_is_rejected(self):
        path = self.archive / "manifest.json"
        original = json.loads(path.read_text())
        for mutation in ("development", "source"):
            with self.subTest(mutation=mutation):
                manifest = json.loads(json.dumps(original))
                if mutation == "development":
                    manifest.pop("workspace")
                else:
                    manifest["sources"]["etaf"] = "0" * 40
                path.write_text(json.dumps(manifest))
                self.report["manifest_sha256"] = self.digest(path)
                self.stage(success=False)


class PackageReleasePublishedTests(unittest.TestCase):
    """The published query must answer from the archive, not from a hand list."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name)
        (self.archive / "manifest.json").write_text(json.dumps({
            "schema": 2, "workspace": "0" * 40, "sources": {},
            "packages": [
                {"name": "etaf-ui", "version": "0.1.3", "requirements": [["emacs", "29.1"]],
                 "summary": "catalog", "file": "etaf-ui-0.1.3.tar", "sha256": "0" * 64},
                {"name": "etaf-md-preview", "version": "0.1.0", "requirements": [["etaf", "0.2.2"]],
                 "summary": "markdown", "file": "etaf-md-preview-0.1.0.tar", "sha256": "1" * 64}]}))

    def query(self, success=True):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/package-release.py"), "published",
             "--url", self.archive.as_uri() + "/"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_groups_packages_by_role_from_the_live_manifest(self):
        output = self.query().stdout
        self.assertIn("Framework (1):", output)
        self.assertIn("etaf-ui", output)
        self.assertIn("Applications (1):", output)
        self.assertIn("etaf-md-preview", output)
        self.assertIn("Games (0):", output)

    def test_a_missing_manifest_fails_closed(self):
        (self.archive / "manifest.json").unlink()
        result = self.query(success=False)
        self.assertIn("error=release", result.stderr)


if __name__ == "__main__":
    unittest.main()
