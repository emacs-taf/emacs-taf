"""Exercise the acceptance runner's bounded reports and per-checkout lock."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'scripts/run-acceptance.py'
EMACS = os.environ.get('EMACS', 'emacs')

PACKAGE = '''\
;;; probe.el --- acceptance-runner sandbox -*- lexical-binding: t; -*-
(require 'cl-lib)
(cl-defstruct probe-node children payload)
(defun probe-make (depth width)
  (if (zerop depth)
      (make-probe-node :payload (make-string 120 ?x))
    (let (children)
      (dotimes (_ width) (push (probe-make (1- depth) width) children))
      (make-probe-node :children (nreverse children)))))
(defvar probe-graph
  (make-probe-node :children (probe-make 4 6) :payload (make-string 100000 ?y)))
(defun probe-find (graph) (ignore graph) nil)
(provide 'probe)
'''

FAILURE_SCENARIOS = '''\
;;; probe-tests.el --- sandbox scenarios -*- lexical-binding: t; -*-
(require 'ert)
(require 'probe)
(ert-deftest probe-small-failure ()
  (should (= 1 2)))
(ert-deftest probe-big-failure ()
  (should (probe-find probe-graph)))
'''

HOLD_SCENARIOS = '''\
;;; probe-tests.el --- sandbox scenarios -*- lexical-binding: t; -*-
(require 'ert)
(require 'probe)
(ert-deftest probe-holds ()
  (write-region "held\\n" nil {marker})
  (dotimes (_ 300) (unless (file-exists-p {release}) (sleep-for 0.1)))
  (should t))
'''


def manifest(*cases):
    return {'cases': [{'name': name, 'file': 'tests/probe-tests.el', 'purpose': purpose}
                      for name, purpose in cases]}


class AcceptanceRunnerTests(unittest.TestCase):
    def sandbox(self, scenarios, cases):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / 'probe'
        (root / 'tests').mkdir(parents=True)
        (root / 'probe.el').write_text(PACKAGE)
        (root / 'tests/probe-tests.el').write_text(scenarios)
        (root / 'tests/acceptance.json').write_text(json.dumps(cases))
        return root

    def run_runner(self, root, *arguments, timeout=90):
        return subprocess.run([sys.executable, str(RUNNER), '--emacs', EMACS, '--root', str(root), *arguments],
                              capture_output=True, text=True, timeout=timeout)

    @staticmethod
    def report(result):
        return result.stdout + result.stderr

    def test_failure_reports_are_bounded_and_keep_small_conditions(self):
        root = self.sandbox(FAILURE_SCENARIOS, manifest(
            ('probe-small-failure', 'small failure report stays readable'),
            ('probe-big-failure', 'large object failure report stays bounded')))
        result = self.run_runner(root)
        self.assertEqual(1, result.returncode, self.report(result))
        report = self.report(result)
        self.assertIn('(= 1 2)', report)
        self.assertIn('condition truncated', report)
        self.assertIn('probe-big-failure', report)
        self.assertLess(len(report), 32768)
        self.assertLess(max(map(len, report.splitlines())), 16384)

    def test_print_flags_widen_the_report_and_validate(self):
        root = self.sandbox(FAILURE_SCENARIOS, manifest(
            ('probe-big-failure', 'large object failure report stays bounded')))
        narrow = self.run_runner(root, '--print-level', '1', '--print-length', '2', '--max-condition-bytes', '512')
        wide = self.run_runner(root, '--print-level', '3', '--print-length', '6', '--max-condition-bytes', '200000')
        self.assertNotIn('condition truncated', self.report(narrow))
        self.assertGreater(len(self.report(wide)), 5 * len(self.report(narrow)))
        invalid = self.run_runner(root, '--print-level', '0')
        self.assertNotEqual(0, invalid.returncode)
        self.assertIn('must be positive', invalid.stderr)

    def test_concurrent_runs_are_serialized_per_checkout(self):
        root = self.sandbox('', manifest(('probe-holds', 'hold the checkout lock while running')))
        marker, release = root / 'held.marker', root / 'release.marker'
        (root / 'tests/probe-tests.el').write_text(
            HOLD_SCENARIOS.format(marker=json.dumps(str(marker)), release=json.dumps(str(release))))
        first = subprocess.Popen([sys.executable, str(RUNNER), '--emacs', EMACS, '--root', str(root)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        # Cleanup is LIFO: stop first, then drain/reap and close its pipe,
        # including when an assertion aborts the lock-handshake scenario.
        self.addCleanup(first.communicate)
        self.addCleanup(first.kill)
        for _ in range(100):
            if marker.exists():
                break
            time.sleep(0.1)
        self.assertTrue(marker.exists(), 'first run never reached its scenario')
        busy = self.run_runner(root)
        self.assertEqual(75, busy.returncode, self.report(busy))
        self.assertIn('already running', busy.stderr)
        error_log = root / 'queued.err'
        with open(error_log, 'w') as errors:
            queued = subprocess.Popen([sys.executable, str(RUNNER), '--emacs', EMACS, '--root', str(root), '--wait', '30'],
                                      stdout=subprocess.DEVNULL, stderr=errors, text=True)
        self.addCleanup(queued.wait)
        self.addCleanup(queued.kill)
        for _ in range(100):
            if 'waiting up to' in error_log.read_text():
                break
            time.sleep(0.1)
        else:
            self.fail('queued run never reported waiting for the lock')
        release.write_text('go\n')
        self.assertEqual(0, queued.wait(timeout=30))
        self.assertEqual(0, first.wait(timeout=30))


if __name__ == '__main__':
    unittest.main()
