"""Exercise the deployment CLI against a real local HTTP server and filesystem."""
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipIf(os.name == "nt", "Deployment runs on the POSIX web host")
class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.base = self.work / "site"
        (self.base / "releases").mkdir(parents=True)
        self.tools = self.work / "tools"
        self.tools.mkdir()
        shutil.copyfile(ROOT / "site/scripts/deploy-release.py", self.tools / "deploy-release.py")
        shutil.copyfile(ROOT / "scripts/package_archive.py", self.tools / "package_archive.py")
        self.broken = False
        owner = self

        class Handler(SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                current = owner.base / "current/index.html"
                if owner.broken and current.exists() and current.read_text() == "bad deployment":
                    self.send_error(503, "Fixture web-serving failure")
                else:
                    super().do_GET()

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(
            Handler, directory=str(self.base / "current")))
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_http)
        self.url = f"http://127.0.0.1:{self.http.server_port}"
        self.sequence = 0

    def close_http(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=5)

    def package(self, version="1.0.0", body=""):
        self.sequence += 1
        source = self.work / f"source-{self.sequence}"
        source.mkdir()
        (source / "example.el").write_text(
            ';;; -*- lexical-binding: t; -*-\n;;; example.el --- Fixture\n'
            f';; Version: {version}\n;; Package-Requires: ((emacs "29.1"))\n'
            f"{body}\n(provide 'example)\n")
        output = self.work / f"archive-{self.sequence}"
        result = subprocess.run([sys.executable, str(ROOT / "scripts/package_archive.py"),
                                 "build", "--directory", str(output), "--package", f"example={source}"],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return output

    def payload(self, *, page=None, packages=None):
        self.sequence += 1
        output = self.work / f"payload-{self.sequence}.tgz"
        with tarfile.open(output, "w:gz") as archive:
            if page is not None:
                value = page.encode()
                for name in ("index.html", "zh-cn/index.html", "introduction/index.html",
                             "zh-cn/introduction/index.html", "symbol-index/index.html", "zh-cn/symbol-index/index.html"):
                    member = tarfile.TarInfo(name)
                    member.size = len(value)
                    archive.addfile(member, io.BytesIO(value))
            if packages:
                for path in packages.iterdir():
                    archive.add(path, arcname="packages/" + path.name)
        return output

    def deploy(self, payload, mode, *, success=True, release=None):
        self.sequence += 1
        stamp = release or f"20261017T120000Z-{self.sequence:08x}"
        result = subprocess.run(
            [sys.executable, str(self.tools / "deploy-release.py"), "--base", str(self.base),
             "--archive", str(payload), "--release", stamp, "--mode", mode, "--keep", "2",
             "--verify-url", self.url], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if success:
            self.assertEqual(json.loads(result.stdout)["release"], stamp)
            self.assertEqual((self.base / "current").resolve().name, stamp)
        return result

    def test_package_and_site_publications_preserve_all_old_downloads_after_pruning(self):
        first = self.package()
        old = (first / "example-1.0.0.tar").read_bytes()
        self.deploy(self.payload(page="site one", packages=first), "combined")
        self.deploy(self.payload(packages=self.package("1.1.0")), "packages")
        self.assertEqual((self.base / "current/index.html").read_text(), "site one")
        self.deploy(self.payload(page="site two"), "site")
        self.deploy(self.payload(packages=self.package("1.2.0")), "packages")
        self.assertEqual((self.base / "current/index.html").read_text(), "site two")
        public = self.base / "current/packages"
        self.assertEqual((public / "example-1.0.0.tar").read_bytes(), old)
        self.assertTrue((public / "example-1.1.0.tar").is_file())
        self.assertEqual(len(list((self.base / "releases").iterdir())), 2)
        self.assertEqual({path.name for path in public.iterdir()}, {
            "archive-contents", "manifest.json", "example-1.0.0.tar", "example-1.1.0.tar", "example-1.2.0.tar"})

    def test_same_version_changed_bytes_and_downgrades_preserve_current(self):
        self.deploy(self.payload(page="stable", packages=self.package()), "combined")
        previous = (self.base / "current").readlink()
        changed = self.package(body=";; Different source bytes")
        result = self.deploy(self.payload(packages=changed), "packages", success=False)
        self.assertIn("Immutable package differs", result.stderr)
        result = self.deploy(self.payload(packages=self.package("0.9.0")), "packages", success=False)
        self.assertIn("downgrade", result.stderr)
        self.assertEqual((self.base / "current").readlink(), previous)

    def test_http_failure_restores_and_verifies_the_previous_release(self):
        self.deploy(self.payload(page="stable", packages=self.package()), "combined")
        previous = (self.base / "current").readlink()
        self.broken = True
        result = self.deploy(self.payload(page="bad deployment"), "site", success=False)
        self.assertIn("Rollback verified", result.stderr)
        self.assertEqual((self.base / "current").readlink(), previous)
        self.assertEqual(len(list((self.base / "releases").iterdir())), 1)

    def test_failed_first_publication_leaves_no_current(self):
        self.broken = True
        self.deploy(self.payload(page="bad deployment"), "site", success=False)
        self.assertFalse((self.base / "current").exists())
        self.assertFalse(list((self.base / "releases").iterdir()))

    def test_links_traversal_duplicates_and_special_members_are_rejected(self):
        self.deploy(self.payload(page="stable"), "site")
        previous = (self.base / "current").readlink()
        for name, kind in (("../escape", tarfile.REGTYPE), ("/tmp/escape", tarfile.REGTYPE),
                           ("link", tarfile.SYMTYPE), ("hardlink", tarfile.LNKTYPE),
                           ("device", tarfile.CHRTYPE), ("duplicate", tarfile.REGTYPE)):
            with self.subTest(name=name):
                payload = self.work / "unsafe.tar"
                with tarfile.open(payload, "w") as archive:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "../../escape"
                    archive.addfile(member, io.BytesIO(b""))
                    if name == "duplicate":
                        archive.addfile(member, io.BytesIO(b""))
                self.deploy(payload, "site", success=False)
                self.assertEqual((self.base / "current").readlink(), previous)
        self.assertFalse((self.base / "escape").exists())
        self.assertFalse(list(self.base.glob(".deploy-*")))

    def test_private_files_index_corruption_and_unversioned_archives_never_publish(self):
        self.deploy(self.payload(page="stable"), "site")
        previous = (self.base / "current").readlink()
        for name in ("installation.json", "installation.log", "unlisted-1.0.tar", "archive-contents"):
            with self.subTest(name=name):
                archive = self.package()
                (archive / name).write_text("must not publish")
                self.deploy(self.payload(packages=archive), "packages", success=False)
                self.assertEqual((self.base / "current").readlink(), previous)

    def test_lock_rejects_a_concurrent_deployment_without_changing_current(self):
        import fcntl
        self.deploy(self.payload(page="stable"), "site")
        previous = (self.base / "current").readlink()
        with (self.base / ".deploy.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.deploy(self.payload(page="concurrent"), "site", success=False)
        self.assertIn("site lock", result.stderr)
        self.assertEqual((self.base / "current").readlink(), previous)

    def test_missing_reference_pages_and_reused_release_identity_are_rejected(self):
        self.deploy(self.payload(page="stable"), "site")
        previous = (self.base / "current").readlink()
        self.deploy(self.payload(page="changed"), "site", release=previous.name, success=False)
        payload = self.work / "incomplete.tar"
        with tarfile.open(payload, "w") as archive:
            member = tarfile.TarInfo("index.html")
            archive.addfile(member, io.BytesIO(b""))
        result = self.deploy(payload, "site", success=False)
        self.assertIn("reference page", result.stderr)
        self.assertEqual((self.base / "current").readlink(), previous)

    def test_package_index_page_is_published_and_survives_a_site_only_release(self):
        archive = self.package()
        (archive / "index.html").write_text("<html>archive index</html>")
        self.deploy(self.payload(page="site one", packages=archive), "combined")
        current = self.base / "current/packages/index.html"
        self.assertEqual(current.read_text(), "<html>archive index</html>")
        self.deploy(self.payload(page="site two"), "site")
        self.assertEqual(current.read_text(), "<html>archive index</html>")
        self.assertEqual((self.base / "current/index.html").read_text(), "site two")

    def test_package_detail_pages_are_published_and_survive_a_site_only_release(self):
        archive = self.package()
        (archive / "index.html").write_text("<html>archive index</html>")
        (archive / "example").mkdir()
        (archive / "example/index.html").write_text("<html>example package</html>")
        self.deploy(self.payload(page="site one", packages=archive), "combined")
        current = self.base / "current/packages/example/index.html"
        self.assertEqual(current.read_text(), "<html>example package</html>")
        self.deploy(self.payload(page="site two"), "site")
        self.assertEqual(current.read_text(), "<html>example package</html>")

    def test_unindexed_detail_directory_or_extra_page_is_rejected(self):
        self.deploy(self.payload(page="stable"), "site")
        previous = (self.base / "current").readlink()
        for name in ("not-a-package", "example"):
            with self.subTest(directory=name):
                archive = self.package()
                (archive / name).mkdir()
                (archive / name / "index.html").write_text("<html>x</html>")
                if name == "example":
                    (archive / name / "extra.txt").write_text("not public")
                self.deploy(self.payload(packages=archive), "packages", success=False)
                self.assertEqual((self.base / "current").readlink(), previous)

    def test_manifest_update_dates_are_published_and_must_cover_every_package(self):
        self.deploy(self.payload(page="stable"), "site")
        archive = self.package()
        path = archive / "manifest.json"
        document = json.loads(path.read_text())
        document["updated"] = {"example": "2026-10-20T22:40:00+08:00"}
        path.write_text(json.dumps(document))
        self.deploy(self.payload(packages=archive), "packages")
        served = json.loads((self.base / "current/packages/manifest.json").read_text())
        self.assertEqual(served["updated"], {"example": "2026-10-20T22:40:00+08:00"})
        previous = (self.base / "current").readlink()
        for broken in ({"example": "2026-10-20"},
                       {"other": "2026-10-20T22:40:00+08:00"},
                       {"example": 20261020},
                       ["2026-10-20T22:40:00+08:00"]):
            with self.subTest(updated=broken):
                document["updated"] = broken
                path.write_text(json.dumps(document))
                result = self.deploy(self.payload(packages=archive), "packages", success=False)
                self.assertIn("update dates", result.stderr)
                self.assertEqual((self.base / "current").readlink(), previous)

    def test_site_only_cannot_replace_packages_and_package_only_needs_a_site(self):
        package = self.package()
        self.deploy(self.payload(packages=package), "packages", success=False)
        self.deploy(self.payload(page="stable"), "site")
        result = self.deploy(self.payload(page="changed", packages=package), "site", success=False)
        self.assertIn("Site-only", result.stderr)
        self.assertEqual((self.base / "current/index.html").read_text(), "stable")


if __name__ == "__main__":
    unittest.main()
