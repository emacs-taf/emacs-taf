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
class StandardSnapshotTests(unittest.TestCase):
    """A verification reuses one snapshot instead of refetching the closure."""

    def module(self):
        return release_module()

    def test_an_explicit_directory_wins_without_touching_the_cache(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as work:
            explicit = Path(work)
            calls = []
            original = module.prefetch
            module.prefetch = lambda *args, **kwargs: calls.append(args)
            try:
                chosen = module.standard_snapshot(explicit, "emacs")
            finally:
                module.prefetch = original
            self.assertEqual(explicit, chosen)
            self.assertEqual([], calls)

    def test_a_cached_snapshot_is_reused_and_missing_one_is_fetched(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as work:
            cache = Path(work)
            calls = []
            original_prefetch, original_cache = module.prefetch, module.STANDARD_ARCHIVE_CACHE
            module.prefetch = lambda directory, emacs: calls.append(directory)
            module.STANDARD_ARCHIVE_CACHE = cache
            try:
                # Nothing cached yet: the closure is fetched once.
                self.assertEqual(cache, module.standard_snapshot(None, "emacs"))
                self.assertEqual([cache], calls)
                # A manifest makes the next verification local.
                (cache / "manifest.json").write_text("{}", encoding="utf-8")
                self.assertEqual(cache, module.standard_snapshot(None, "emacs"))
                self.assertEqual([cache], calls)
                # Asking for a refresh fetches again.
                self.assertEqual(cache, module.standard_snapshot(None, "emacs", refresh=True))
                self.assertEqual([cache, cache], calls)
            finally:
                module.prefetch, module.STANDARD_ARCHIVE_CACHE = original_prefetch, original_cache


class PackageReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "ekp"
        self.source.mkdir()
        self.archive = self.base / "archive"

    def build(self, body=""):
        (self.source / "native").mkdir(exist_ok=True)
        (self.source / "native/manifest.json").write_text(json.dumps({
            "schema": 1,
            "package": "ekp",
            "modules": [{
                "name": "ekp",
                "version": "1.6",
                "description": "Fixture EKP C module",
                "platforms": {},
            }],
        }) + "\n")
        (self.source / "ekp.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n;;; ekp.el --- Release fixture\n'
            ';; Version: 1.0.0\n;; Package-Requires: ((emacs "29.1"))\n'
            f"{body}\n(defun ekp-hyphen-create (&optional _lang _file _left _right) t)\n"
            "(provide 'ekp)\n")
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/package_archive.py"), "build",
             "--directory", str(self.archive), "--package", f"ekp={self.source}",
             "--resource", "ekp=native/manifest.json",
             "--package", f"etaf-install={ROOT / 'core/packages/etaf-install'}"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def verify(self, *extra, success=True):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/package-release.py"), "verify",
             "--directory", str(self.archive), "--emacs", EMACS, "--target", "ekp", *extra],
            # The package-install path refreshes the live archives, so this
            # budget covers a slow third-party fetch and its retries rather
            # than the local install. The gate it proves is unrelated to
            # network speed, and a tighter budget only reports the network.
            capture_output=True, text=True, timeout=180)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_verification_proves_the_entry_path_by_default(self):
        self.build()
        self.verify()
        report = json.loads((self.archive / "installation.json").read_text())
        self.assertEqual(report["manifest_sha256"], hashlib.sha256(
            (self.archive / "manifest.json").read_bytes()).hexdigest())
        self.assertEqual(report["paths"], ["etaf-install"])
        self.assertEqual({item["entry"] for item in report["installations"]}, {"etaf-install"})
        self.assertTrue(all(item["status"] == "ok" and item["emacs"] and item["system"]
                            for item in report["installations"]))
        self.assertEqual({item["target"] for item in report["installations"]}, {"ekp"})

    def test_verification_covers_both_paths_when_asked(self):
        self.build()
        self.verify("--paths", "both")
        report = json.loads((self.archive / "installation.json").read_text())
        self.assertEqual(report["paths"], ["etaf-install", "package-install"])
        self.assertEqual({item["entry"] for item in report["installations"]},
                         {"etaf-install", "package-install"})

    def test_demoted_reload_errors_are_failures_even_when_emacs_exits_successfully(self):
        self.build('(message "Error in package--load-files-for-activation: fixture failure")')
        result = self.verify("--paths", "package-install", success=False)
        self.assertIn("Installation diagnostics", result.stderr)
        self.assertIn("Error in package--load-files-for-activation", result.stderr)
        self.assertFalse((self.archive / "installation.json").exists())
        self.assertTrue((self.archive / "installation-ekp-package-install.log").is_file())

    def test_stdout_diagnostics_are_not_misreported_as_invalid_json(self):
        self.build('(princ "Warning: fixture diagnostic\\n")')
        result = self.verify("--paths", "package-install", success=False)
        self.assertIn("Installation diagnostics", result.stderr)
        self.assertIn("Warning: fixture diagnostic", result.stderr)

    def test_real_compilation_warnings_block_verification(self):
        self.build('(defun ekp-release-fixture () (ekp-missing-function))')
        result = self.verify("--paths", "package-install", success=False)
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
        self.verify("--paths", "package-install", success=False)
        self.assertFalse((self.archive / "installation.json").exists())
        self.assertIn("Fixture entry failed",
                      (self.archive / "installation-ekp-package-install.log").read_text())


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
        for name in ("package-release.py", "package_archive.py", "workspace_layout.py"):
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
        changed = subprocess.check_output(
            ["git", "-C", str(self.provider), "log", "-1", "--format=%cI",
             self.provider_revision, "--", "ecss.el", "data"], text=True).strip()
        self.assertEqual(manifest["updated"]["ecss"], changed)
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
        for name in ("package-release.py", "package_archive.py", "workspace_layout.py", "install-smoke.el"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        shutil.copytree(ROOT / "core/packages/etaf-install", self.root / "packages/etaf-install",
                        ignore=shutil.ignore_patterns("*.elc"))
        targets = ("etaf-ui", "etaf", "etaf-manual", "ekp", "etaf-db")
        (self.root / ".gitignore").write_text("__pycache__/\n")
        packages = {}
        for name in targets:
            source = self.root / "packages" / name
            source.mkdir(parents=True, exist_ok=True)
            (source / f"{name}.el").write_text(
                f';;; -*- lexical-binding: t; -*-\n;;; {name}.el --- Fixture\n'
                f';; Version: 1.0.0\n;; Package-Requires: ((emacs "29.1"))\n(provide \'{name})\n')
            packages[name] = {"url": f"https://github.com/emacs-taf/{name}.git", "branch": "main"}
        packages["etaf-install"] = {"url": "https://github.com/emacs-taf/emacs-taf.git", "branch": "main", "role": "framework"}
        (self.root / "README.md").write_text("# Workspace root README\n")
        (self.root / "workspace.json").write_text(json.dumps({"schema": 2, "packages": packages}))
        (self.root / "release-dependencies.json").write_text(json.dumps(
            {"schema": 1, "packages": {name: {} for name in targets}}))
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.commit(self.root)
        self.archive = self.base / "archive"
        self.command("build", "--directory", str(self.archive))
        self.report = {"schema": 1, "manifest_sha256": self.digest(self.archive / "manifest.json"),
                       "validator_sha256": self.digest(self.root / "scripts/package-release.py"),
                       "smoke_sha256": self.digest(self.root / "scripts/install-smoke.el"),
                       "installations": [{"target": target, "entry": "etaf-install", "status": "ok",
                                          "emacs": "29.1", "system": "gnu/linux"}
                                         for target in targets]}
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
        self.assertEqual(set(manifest), {"schema", "workspace", "sources", "packages", "updated", "catalog"})
        self.assertEqual(manifest["catalog"]["etaf-ui"]["group"], "framework")
        self.assertEqual(manifest["catalog"]["etaf-ui"]["open"], "etaf-ui-gallery-open")
        self.assertEqual(set(manifest["updated"]), {item["name"] for item in manifest["packages"]})
        self.assertEqual((self.output / "archive-contents").read_bytes(), (self.archive / "archive-contents").read_bytes())
        for package in manifest["packages"]:
            self.assertEqual(self.digest(self.output / package["file"]), package["sha256"])

    def test_root_readme_changes_do_not_alter_etaf_install_tarball_bytes(self):
        first_manifest = json.loads((self.archive / "manifest.json").read_text())
        first_inst = next(p for p in first_manifest["packages"] if p["name"] == "etaf-install")
        with tarfile.open(self.archive / first_inst["file"]) as tar:
            members = tar.getnames()
        self.assertTrue(any(m.endswith("/lisp/etaf-install-catalog.el") for m in members), members)
        (self.root / "README.md").write_text("# Updated workspace root README\n")
        self.commit(self.root)
        second = self.base / "archive-after-root-readme-edit"
        self.command("build", "--directory", str(second))
        second_manifest = json.loads((second / "manifest.json").read_text())
        second_inst = next(p for p in second_manifest["packages"] if p["name"] == "etaf-install")
        self.assertEqual(first_inst["sha256"], second_inst["sha256"])
        self.assertEqual(first_manifest["updated"]["etaf-install"], second_manifest["updated"]["etaf-install"])

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
                self.assertIn("recorded targets through etaf-install",
                              self.stage(success=False).stderr)

    def test_publisher_refuses_partial_evidence_before_building_or_connecting(self):
        self.report["installations"].pop()
        (self.archive / "installation.json").write_text(json.dumps(self.report))
        publisher = ROOT / "core/packages/etaf-manual/site/scripts/publish.py"
        if not publisher.is_file():
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
                {"name": "etaf-md", "version": "0.1.0", "requirements": [["etaf", "0.2.2"]],
                 "summary": "markdown", "file": "etaf-md-0.1.0.tar", "sha256": "1" * 64}]}))

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
        self.assertIn("etaf-md", output)
        self.assertIn("Games (0):", output)

    def test_a_missing_manifest_fails_closed(self):
        (self.archive / "manifest.json").unlink()
        result = self.query(success=False)
        self.assertIn("error=release", result.stderr)


class PackageReleaseAutoScopeTests(unittest.TestCase):
    """Auto scope checks immutable drift before Emacs runs and narrows to changed targets."""

    def make_archive(self, directory, packages):
        directory.mkdir(parents=True, exist_ok=True)
        for p in packages:
            (directory / p["file"]).write_bytes(p["_bytes"])
        public = [{k: v for k, v in p.items() if not k.startswith("_")} for p in packages]
        sys.path.insert(0, str(ROOT / "scripts"))
        import package_archive
        package_archive.write_index(directory, public)

    def pkg(self, name, version, reqs, body):
        digest = hashlib.sha256(body).hexdigest()
        return {"name": name, "version": version, "requirements": reqs,
                "summary": name, "file": f"{name}-{version}.tar",
                "sha256": digest, "_bytes": body}

    def test_auto_scope_fails_fast_listing_all_drifting_packages(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            live = base / "live"
            built = base / "built"
            self.make_archive(live, [
                self.pkg("etaf-install", "0.2.0", [["emacs", "29.1"]], b"inst-old"),
                self.pkg("maillist", "0.4.2", [["emacs", "29.1"]], b"mail-old"),
            ])
            self.make_archive(built, [
                self.pkg("etaf-install", "0.2.0", [["emacs", "29.1"]], b"inst-new"),
                self.pkg("maillist", "0.4.2", [["emacs", "29.1"]], b"mail-new"),
            ])
            with self.assertRaises(ValueError) as caught:
                release_module().resolve_auto_scope(built, ["maillist"], live.as_uri() + "/")
            msg = str(caught.exception)
            self.assertIn("bump etaf-install past 0.2.0", msg)
            self.assertIn("bump maillist past 0.4.2", msg)

    def test_auto_scope_narrows_to_changed_leaf_and_dependents(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            live = base / "live"
            built = base / "built"
            inst = self.pkg("etaf-install", "0.2.0", [["emacs", "29.1"]], b"inst-same")
            etaf = self.pkg("etaf", "0.3.8", [["emacs", "29.1"]], b"etaf-same")
            mail = self.pkg("maillist", "0.4.3", [["etaf", "0.3.8"]], b"mail-same")
            md_old = self.pkg("etaf-md", "0.2.1", [["etaf", "0.3.8"]], b"md-old")
            md_new = self.pkg("etaf-md", "0.3.0", [["etaf", "0.3.8"]], b"md-new")
            self.make_archive(live, [inst, etaf, mail, md_old])
            self.make_archive(built, [inst, etaf, mail, md_new])
            scope, targets, reason = release_module().resolve_auto_scope(
                built, ["etaf", "maillist", "etaf-md"], live.as_uri() + "/")
            self.assertEqual(scope, "selected")
            self.assertEqual(targets, ["etaf-md"])
            self.assertIn("etaf-md", reason)

    def test_auto_scope_rejects_stale_internal_requires_on_changed_packages_only(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            live = base / "live"
            built = base / "built"
            inst = self.pkg("etaf-install", "0.2.0", [["emacs", "29.1"]], b"inst-same")
            etaf = self.pkg("etaf", "0.3.18", [["emacs", "29.1"]], b"etaf-same")
            # Unchanged package with older bound must NOT block unrelated releases.
            unchanged = self.pkg("maillist", "0.4.3", [["emacs", "29.1"], ["etaf", "0.3.10"]], b"mail-same")
            md_live = self.pkg("etaf-md", "0.2.1", [["emacs", "29.1"], ["etaf", "0.3.10"]], b"md-old")
            md_stale = self.pkg("etaf-md", "0.3.0", [["emacs", "29.1"], ["etaf", "0.3.10"]], b"md-new")
            self.make_archive(live, [inst, etaf, unchanged, md_live])
            self.make_archive(built, [inst, etaf, unchanged, md_stale])
            with self.assertRaises(ValueError) as caught:
                release_module().resolve_auto_scope(
                    built, ["etaf", "maillist", "etaf-md"], live.as_uri() + "/")
            msg = str(caught.exception)
            self.assertIn("etaf-md: etaf 0.3.10 -> 0.3.18", msg)
            self.assertNotIn("maillist", msg)
            self.assertIn("sync-requires --write --package etaf-md", msg)

            # Once changed package aligns its bound, unchanged stale maillist still passes.
            built_ok = base / "built-ok"
            md_aligned = self.pkg("etaf-md", "0.3.0", [["emacs", "29.1"], ["etaf", "0.3.18"]], b"md-new")
            self.make_archive(built_ok, [inst, etaf, unchanged, md_aligned])
            scope, targets, _reason = release_module().resolve_auto_scope(
                built_ok, ["etaf", "maillist", "etaf-md"], live.as_uri() + "/")
            self.assertEqual(scope, "selected")
            self.assertEqual(targets, ["etaf-md"])

    def test_auto_scope_skips_community_packages_for_stale_requires(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            live = base / "live"
            built = base / "built"
            inst = self.pkg("etaf-install", "0.2.0", [["emacs", "29.1"]], b"inst-same")
            etaf = self.pkg("etaf", "0.3.18", [["emacs", "29.1"]], b"etaf-same")
            comm_old = self.pkg("exc", "0.1.0", [["emacs", "29.1"], ["etaf", "0.3.10"]], b"exc-old")
            comm_new = self.pkg("exc", "0.1.1", [["emacs", "29.1"], ["etaf", "0.3.10"]], b"exc-new")
            self.make_archive(live, [inst, etaf, comm_old])
            self.make_archive(built, [inst, etaf, comm_new])
            # Mark exc as a community package in the built manifest.
            mpath = built / "manifest.json"
            manifest = json.loads(mpath.read_text(encoding="utf-8"))
            manifest["community"] = {
                "exc": {"url": "https://example.invalid/exc", "license": "GPL-3.0",
                        "maintainer": "ext", "group": "application", "label": "exc", "open": ""}
            }
            mpath.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            scope, targets, _reason = release_module().resolve_auto_scope(
                built, ["etaf"], live.as_uri() + "/")
            self.assertEqual(scope, "selected")
            self.assertEqual(targets, ["exc"])


class PackageReleaseRequiresSyncTests(unittest.TestCase):
    """sync-requires keeps internal Package-Requires lower bounds aligned cleanly."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "workspace"
        (self.root / "scripts").mkdir(parents=True)
        for name in ("package-release.py", "package_archive.py", "workspace_layout.py"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        self.write_pkg("core/packages/etaf-install", "etaf-install", "0.2.0", '((emacs "29.1"))')
        self.write_pkg("core/packages/ecss", "ecss", "0.1.4", '((emacs "29.1"))')
        self.write_pkg("core/packages/etaf", "etaf", "0.3.18", '((emacs "29.1") (ecss "0.1.0"))')
        self.write_pkg(
            "apps/etaf-md", "etaf-md", "0.4.0",
            '((emacs "29.1") (etaf "0.3.10") (posframe "0.9.0"))',
            body=";; Important comment preserved\n(defun etaf-md-open () t)\n",
        )
        self.write_pkg(
            "apps/maillist", "maillist", "0.4.3",
            '((emacs "29.1") (etaf "0.3.10"))',
        )
        (self.root / "workspace.json").write_text(json.dumps({
            "schema": 3,
            "packages": {
                "etaf-install": {"path": "core/packages/etaf-install", "role": "framework"},
                "ecss": {"path": "core/packages/ecss", "role": "framework"},
                "etaf": {"path": "core/packages/etaf", "role": "framework"},
                "etaf-md": {"path": "apps/etaf-md", "role": "application"},
                "maillist": {"path": "apps/maillist", "role": "application"},
            },
        }), encoding="utf-8")
        (self.root / "release-dependencies.json").write_text(json.dumps({
            "schema": 1,
            "packages": {
                "ecss": {},
                "etaf": {},
                "etaf-md": {"external": ["posframe"]},
                "maillist": {},
            },
        }), encoding="utf-8")

    def write_pkg(self, rel, name, version, reqs, body=""):
        pkg_dir = self.root / rel
        pkg_dir.mkdir(parents=True, exist_ok=True)
        (pkg_dir / f"{name}.el").write_text(
            f";;; -*- lexical-binding: t; -*-\n"
            f";;; {name}.el --- Fixture {name}\n"
            f";; Version: {version}\n"
            f";; Package-Requires: {reqs}\n"
            f"{body}"
            f"(provide '{name})\n",
            encoding="utf-8",
        )

    def run_cli(self, *args, success=True):
        result = subprocess.run(
            [sys.executable, str(self.root / "scripts/package-release.py"), *args],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_compare_versions_handles_padding_and_multi_digit_segments(self):
        cmp = release_module().compare_versions
        self.assertEqual(cmp("0.3.9", "0.3.10"), -1)
        self.assertEqual(cmp("1.0", "1.0.0"), 0)
        self.assertEqual(cmp("3.1.14", "3.1.6"), 1)
        self.assertEqual(cmp("0.3.18", "0.3.18"), 0)

    def test_sync_requires_check_preview_and_write_preserves_external_deps_and_body(self):
        # Preview exits 0 without modifying files.
        before = (self.root / "apps/etaf-md/etaf-md.el").read_text(encoding="utf-8")
        preview = self.run_cli("sync-requires", "--package", "etaf-md", "--json")
        data = json.loads(preview.stdout)
        self.assertEqual(data["mode"], "preview")
        self.assertEqual(len(data["stale"]), 1)
        self.assertEqual(data["stale"][0], {
            "package": "etaf-md", "dependency": "etaf",
            "declared": "0.3.10", "current": "0.3.18",
        })
        self.assertEqual((self.root / "apps/etaf-md/etaf-md.el").read_text(encoding="utf-8"), before)

        # --check fails with exit code 1 when stale bounds exist.
        check_fail = self.run_cli("sync-requires", "--package", "etaf-md", "--check", success=False)
        self.assertIn("etaf-md: etaf 0.3.10 -> 0.3.18", check_fail.stdout)
        self.assertIn("stale internal Package-Requires", check_fail.stderr)

        # --write updates only internal bounds, keeping emacs, external posframe, and file body intact.
        write_res = self.run_cli("sync-requires", "--package", "etaf-md", "--write", "--json")
        write_data = json.loads(write_res.stdout)
        self.assertEqual(write_data["updated_packages"], ["etaf-md"])
        after = (self.root / "apps/etaf-md/etaf-md.el").read_text(encoding="utf-8")
        self.assertIn(';; Package-Requires: ((emacs "29.1") (etaf "0.3.18") (posframe "0.9.0"))', after)
        self.assertIn(";; Important comment preserved", after)
        # Unselected packages stay untouched.
        self.assertIn('(etaf "0.3.10")', (self.root / "apps/maillist/maillist.el").read_text(encoding="utf-8"))

        # Subsequent --check passes cleanly.
        self.run_cli("sync-requires", "--package", "etaf-md", "--check", success=True)

    def test_sync_requires_write_json_stays_pure_json_when_doc_sync_prints(self):
        # A real monorepo has scripts/sync-generated-docs.py that prints human text on stdout;
        # sync-requires --write --json must keep stdout valid JSON.
        doc_sync = self.root / "scripts" / "sync-generated-docs.py"
        doc_sync.parent.mkdir(parents=True, exist_ok=True)
        doc_sync.write_text('print("Updated 2 generated doc file(s): README.md")\n', encoding="utf-8")
        write_res = self.run_cli("sync-requires", "--package", "etaf-md", "--write", "--json")
        write_data = json.loads(write_res.stdout)
        self.assertEqual(write_data["updated_packages"], ["etaf-md"])
        self.assertTrue(write_data["ok"])

    def test_sync_requires_changed_only_targets_only_drifted_packages(self):
        # Build a "live" archive matching the initial workspace, then modify only etaf-md.
        sys.path.insert(0, str(ROOT / "scripts"))
        import package_archive
        live = self.base / "live"
        sources = {
            "etaf-install": self.root / "core/packages/etaf-install",
            "ecss": self.root / "core/packages/ecss",
            "etaf": self.root / "core/packages/etaf",
            "etaf-md": self.root / "apps/etaf-md",
            "maillist": self.root / "apps/maillist",
        }
        package_archive.build(live, sources, {})

        # Change only etaf-md (simulate a new release of etaf-md).
        self.write_pkg(
            "apps/etaf-md", "etaf-md", "0.4.1",
            '((emacs "29.1") (etaf "0.3.10") (posframe "0.9.0"))',
            body="(defun etaf-md-open () 'updated)\n",
        )
        res = self.run_cli(
            "sync-requires", "--changed-only", "--live-url", live.as_uri() + "/",
            "--write", "--json",
        )
        data = json.loads(res.stdout)
        self.assertEqual(data["checked_packages"], ["etaf-md"])
        self.assertEqual(data["updated_packages"], ["etaf-md"])
        # Unchanged etaf & maillist were NOT rewritten.
        self.assertIn('(ecss "0.1.0")', (self.root / "core/packages/etaf/etaf.el").read_text(encoding="utf-8"))
        self.assertIn('(etaf "0.3.10")', (self.root / "apps/maillist/maillist.el").read_text(encoding="utf-8"))
        # Changed etaf-md WAS aligned to current etaf 0.3.18.
        self.assertIn('(etaf "0.3.18")', (self.root / "apps/etaf-md/etaf-md.el").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
