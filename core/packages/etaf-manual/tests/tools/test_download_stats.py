"""Count installs, not file fetches, from the archive's access log."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "download_stats", ROOT / "site/scripts/download-stats.py")
STATS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATS)


class DownloadCountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.logs = Path(self.temp.name)
        self.lines = []

    def fetch(self, uri, *, ip="203.0.113.7", stamp=1_766_016_300.0,
              status=200, method="GET", host="etaf.top"):
        self.lines.append(json.dumps({
            "ts": stamp, "status": status,
            "request": {"uri": uri, "method": method, "host": host, "remote_ip": ip}}))

    def count(self):
        (self.logs / "etaf.top.access.log").write_text("\n".join(self.lines) + "\n")
        return STATS.count(self.logs)[0]

    def test_an_install_is_a_tarball_with_its_signature(self):
        self.fetch("/packages/ebox-3.1.1.tar")
        self.fetch("/packages/ebox-3.1.1.tar.sig", stamp=1_766_016_303.0)
        self.assertEqual({"ebox": 1}, self.count())

    def test_a_bare_fetch_crawler_or_curl_is_not_an_install(self):
        self.fetch("/packages/ebox-3.1.1.tar")
        self.assertEqual({}, self.count())

    def test_one_client_counts_once_per_day(self):
        for hour in (0, 4, 9):
            self.fetch("/packages/ebox-3.1.1.tar", stamp=1_766_016_300.0 + hour * 3600)
            self.fetch("/packages/ebox-3.1.1.tar.sig", stamp=1_766_016_302.0 + hour * 3600)
        self.assertEqual({"ebox": 1}, self.count())
        self.fetch("/packages/ebox-3.1.1.tar", stamp=1_766_016_300.0 + 86400)
        self.fetch("/packages/ebox-3.1.1.tar.sig", stamp=1_766_016_301.0 + 86400)
        self.assertEqual({"ebox": 2}, self.count())

    def test_two_clients_count_twice(self):
        for ip in ("203.0.113.7", "198.51.100.9"):
            self.fetch("/packages/ebox-3.1.1.tar", ip=ip)
            self.fetch("/packages/ebox-3.1.1.tar.sig", ip=ip)
        self.assertEqual({"ebox": 2}, self.count())

    def test_deployment_verification_and_failures_are_not_downloads(self):
        self.fetch("/packages/ebox-3.1.1.tar?deployment=20261022T125253Z-aea6ffba")
        self.fetch("/packages/ebox-3.1.1.tar.sig?deployment=20261022T125253Z-aea6ffba")
        self.fetch("/packages/ebox-3.1.1.tar", status=404)
        self.fetch("/packages/ebox-3.1.1.tar.sig", status=404)
        self.fetch("/packages/ebox-3.1.1.tar.sig", method="HEAD")
        self.assertEqual({}, self.count())

    def test_pages_and_other_packages_are_ignored(self):
        self.fetch("/packages/exc-0.5.1.tar")
        self.fetch("/packages/exc-0.5.1.tar.sig")
        self.fetch("/packages/")
        self.fetch("/packages/etaf/")
        self.assertEqual({"exc": 1}, self.count())


if __name__ == "__main__":
    unittest.main()
