"""Regression tests for scripts/publish-packages.py bookmark projection safety."""
import importlib.util
from pathlib import Path
from unittest import TestCase, mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("publish_packages", ROOT / "scripts/publish-packages.py")
PUB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUB)


class PublishPackagesTests(TestCase):
    def test_publish_defaults_to_main_without_allow_backwards(self):
        calls = []

        def fake_run(cmd, **_kwargs):
            calls.append(cmd)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(PUB.subprocess, "run", side_effect=fake_run):
            pkg, failures = PUB.publish("etaf-ui", ("origin",), {})
        self.assertEqual(pkg, "etaf-ui")
        self.assertEqual(failures, [])
        self.assertEqual(calls[0], ["jjosh", "bookmark", "set", "main#etaf-ui", "-r", "main"])
        self.assertNotIn("--allow-backwards", calls[0])
        self.assertEqual(calls[1], ["jjosh", "git", "push", "--remote", "origin#etaf-ui", "--bookmark", "main#etaf-ui"])

    def test_publish_honors_explicit_rev_and_allow_backwards(self):
        calls = []

        def fake_run(cmd, **_kwargs):
            calls.append(cmd)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(PUB.subprocess, "run", side_effect=fake_run):
            _, failures = PUB.publish("etaf-ui", ("aliyun",), {}, rev="abc123", allow_backwards=True)
        self.assertEqual(failures, [])
        self.assertEqual(
            calls[0],
            ["jjosh", "bookmark", "set", "main#etaf-ui", "-r", "abc123", "--allow-backwards"],
        )
