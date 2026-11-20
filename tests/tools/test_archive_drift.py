"""Contract of scripts/archive-drift.py: which packages must bump before publishing."""
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("archive_drift", ROOT / "scripts" / "archive-drift.py")
drift = importlib.util.module_from_spec(SPEC)
sys.modules["archive_drift"] = drift
SPEC.loader.exec_module(drift)


def package(name, version, digest):
    return {"name": name, "version": version,
            "file": f"{name}-{version}.tar", "sha256": digest}


class ClassificationTests(unittest.TestCase):
    def test_a_changed_file_under_a_served_name_is_drift(self):
        local = {"packages": [package("etaf", "0.3.5", "a" * 64)]}
        remote = {"etaf-0.3.5.tar": "b" * 64}
        rows = drift.drift(local, remote)
        self.assertEqual([("etaf", "0.3.5", "drift", "etaf-0.3.5.tar")], rows)

    def test_identical_bytes_and_absent_names_are_not_drift(self):
        local = {"packages": [package("etaf", "0.3.6", "a" * 64),
                              package("etaf-md", "0.2.0", "c" * 64)]}
        remote = {"etaf-0.3.6.tar": "a" * 64}
        rows = {row[0]: row[2] for row in drift.drift(local, remote)}
        self.assertEqual({"etaf": "same", "etaf-md": "new"}, rows)

    def test_a_version_bump_clears_drift_because_the_name_changes(self):
        # The same source published as 0.3.6 has a different file name, which is
        # what makes a bump the resolution rather than a re-upload.
        local = {"packages": [package("etaf", "0.3.6", "b" * 64)]}
        remote = {"etaf-0.3.5.tar": "a" * 64}
        self.assertEqual("new", drift.drift(local, remote)[0][2])

    def test_an_unreadable_manifest_yields_no_digests_rather_than_raising(self):
        self.assertEqual({}, drift.served_digests("file:///nonexistent/manifest.json"))


class CommandTests(unittest.TestCase):
    def test_the_command_reports_drift_and_exits_nonzero(self):
        import json
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            local = {"schema": 1, "workspace": "0" * 40,
                     "packages": [package("etaf", "0.3.5", "a" * 64)]}
            (directory / "manifest.json").write_text(json.dumps(local), encoding="utf-8")
            remote = {"schema": 1, "workspace": "0" * 40,
                      "packages": [package("etaf", "0.3.5", "b" * 64)]}
            live = directory / "live.json"
            live.write_text(json.dumps(remote), encoding="utf-8")
            result = subprocess.run([sys.executable, str(ROOT / "scripts" / "archive-drift.py"),
                                     "--directory", str(directory),
                                     "--url", live.as_uri()],
                                    capture_output=True, text=True, timeout=60)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn("1 need a version bump", result.stdout)
        self.assertIn("bump etaf past 0.3.5", result.stdout)


if __name__ == "__main__":
    unittest.main()
