"""Black-box contracts for the shared performance command and scenario driver."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ROOT / "scripts/performance.py"
FIXTURE = ROOT / "tests/fixtures/performance-scenarios.el"


class PerformanceTool(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="taf-perf-tests-")
        cls.base = Path(cls.directory.name)
        cls.good = cls.run_case("valid", "fixture.counter", "--diagnose", "--diagnostic-samples", "1")

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    @classmethod
    def run_case(cls, name, scenario, *extra):
        output = cls.base / name
        process = subprocess.run(
            [sys.executable, str(COMMAND), "run", "--root", str(ROOT),
             "--scenario-file", str(FIXTURE), "--mode", "batch", "--scenario", scenario,
             "--samples", "2", "--sets", "1", "--output-dir", str(output), *extra],
            capture_output=True, text=True, timeout=25)
        return process, json.loads((output / "result.json").read_text()), output

    def compare(self, before, after):
        left, right = self.base / "before.json", self.base / "after.json"
        left.write_text(json.dumps(before))
        right.write_text(json.dumps(after))
        return subprocess.run([sys.executable, str(COMMAND), "compare", str(left), str(right)],
                              capture_output=True, text=True, timeout=5)

    def test_latency_trace_cpu_and_memory_are_separate(self):
        process, report, output = self.good
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(report["status"], "screened")
        self.assertFalse(report["acceptance_eligible"])
        case = report["cases"]["fixture.counter"]
        self.assertTrue(report["valid"])
        self.assertEqual(case["count"], 2)
        self.assertEqual(case["diagnostic_count"], 3)
        self.assertEqual(len(case["samples_ms"]), 2)
        latency = json.loads((output / "latency-1.json").read_text())
        self.assertTrue(all(not row["diagnostic"] and row["profile"] is None for row in latency["samples"]))
        self.assertEqual([row["outcome"] for row in latency["samples"]],
                         [{"count": 1}, {"count": 2}])
        self.assertEqual([row["value"] for row in case["latency_outcomes"]],
                         [{"count": 1}, {"count": 2}])
        self.assertIn("slowest outcome (set 1, sample", process.stdout)
        # The outcome callback deliberately waits longer than the case budget.
        # Reading it must remain outside the measured operation.
        self.assertTrue(all(row["wall_ms"] < 100 for row in latency["samples"]))
        trace = json.loads((output / "trace-1.json").read_text())
        self.assertEqual(trace["samples"][0]["reports"][0]["provider"], "fixture")
        observed = trace["samples"][0]["reports"][0]
        self.assertIn("viewport-context", observed["native_declined"])
        self.assertIn("Unsupported size", observed["native_fallback"])
        self.assertEqual({row["kind"] for row in case["native_diagnostics"]},
                         {"native_declined", "native_fallback"})
        self.assertIn("native_declined (1)", process.stdout)
        self.assertIn("Unsupported size", process.stdout)
        self.assertIsNone(trace["samples"][0]["profile"])
        for kind in ("cpu", "memory"):
            data = json.loads((output / (kind + "-1.json")).read_text())
            self.assertIn(kind, data["samples"][0]["profile"])
            self.assertEqual(data["samples"][0]["reports"], [])

    def test_async_settlement_is_included_and_checked(self):
        process, report, _ = self.run_case("async", "fixture.async")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertTrue(report["valid"])
        self.assertTrue(all(value >= 10 for value in report["cases"]["fixture.async"]["samples_ms"]))

    def test_cpu_report_identifies_the_application_leaf(self):
        process, report, output = self.run_case("hot", "fixture.hot", "--diagnose", "--diagnostic-samples", "2")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        profile = report["cases"]["fixture.hot"]["profiles"]["cpu"]
        self.assertGreater(profile["total"], 0)
        leaf = next(row for row in profile["functions"] if row["function"] == "taf-test-hot-leaf")
        self.assertGreater(leaf["inclusive"], 0)
        self.assertEqual(Path(leaf["file"]), FIXTURE)
        self.assertGreater(leaf["line"], 0)
        raw = json.loads((output / "cpu-1.json").read_text())
        for sample in raw["samples"]:
            profile = sample["profile"]["cpu"]
            functions = {row["function"]: row for row in profile["functions"]}
            for stack in profile["stacks"]:
                first = stack["stack"][0]
                self.assertIn(first, functions)
                self.assertGreaterEqual(functions[first]["self"], stack["weight"])

    def test_batch_scenarios_use_independent_processes(self):
        process, report, output = self.run_case("isolated", "fixture.counter", "--scenario", "fixture.async")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertTrue(report["valid"])
        self.assertEqual(len(report["runs"]), 2)
        processes = {json.loads((output / run["file"]).read_text())["environment"]["pid"] for run in report["runs"]}
        self.assertEqual(len(processes), 2)

    def test_detached_fixture_survives_the_next_driver_run(self):
        directory = self.base / "detach-fixture"
        directory.mkdir()
        scenario = directory / "scenarios.el"
        scenario.write_text(""";;; -*- lexical-binding: t; -*-
(defvar taf-test-detach-fixtures nil)
(taf-benchmark-register
 "fixture.detach" :modes '(gui) :budget-ms 100 :impact 'local :isolation 'series
 :setup (lambda (_mode) (pop taf-test-detach-fixtures)))
""")
        output = directory / "report.json"
        configuration = {
            "output": str(output), "mode": "gui", "run_id": "detach-fixture",
            "scenario_files": [str(scenario)], "load_paths": [], "code_roots": [],
            "jobs": [{"id": "fixture.detach", "set": 1, "sample": 0,
                      "diagnostic": False, "diagnostic_kind": "latency"}],
            "timeout": 2,
        }
        config = directory / "configuration.json"
        config.write_text(json.dumps(configuration))
        empty_config = directory / "empty-configuration.json"
        empty_config.write_text(json.dumps({**configuration, "jobs": []}))
        script = directory / "detach-test.el"
        script.write_text(""";;; -*- lexical-binding: t; -*-
(require 'ert)
(require 'ebox)
(defvar taf-test-detach-fixtures nil)
(ert-deftest taf-test-detached-fixture-lifetime ()
  (should-not (taf-benchmark-detach-fixture))
  (let ((fixtures
         (cl-loop repeat 3
                  collect
                  (let* ((fixture (taf-test-fixture 'counter))
                         (buffer (plist-get fixture :buffer)))
                    (ebox-render-to-buffer buffer (ebox-build '(box "Mounted")))
                    (plist-put fixture :invoke
                               (lambda (_sample)
                                 (should (taf-benchmark-running-p))
                                 (should-error (taf-benchmark-detach-fixture)
                                               :type 'user-error)))
                    (plist-put fixture :verify
                               (lambda () (ebox-surface-buffer-mounted-p buffer)))
                    fixture))))
    (setq taf-test-detach-fixtures (copy-sequence fixtures))
    (let ((buffers (mapcar (lambda (fixture) (plist-get fixture :buffer)) fixtures)))
      (unwind-protect
          ;; Exercise retained GUI lifecycle in an isolated batch process.
          ;; Actual rendering above uses the process's real display context.
          (let ((noninteractive nil))
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _display) t)))
              (cl-labels
                  ((run (configuration)
                     (taf-benchmark-start configuration)
                     (with-timeout (5 (ert-fail "Driver did not finish"))
                       (while (taf-benchmark-running-p) (accept-process-output nil .01)))
                     (with-temp-buffer
                       (insert-file-contents REPORT)
                       (should (equal (plist-get (json-parse-buffer :object-type 'plist)
                                                 :status)
                                      "completed")))))
                (run CONFIG)
                (should (eq (taf-benchmark-detach-fixture) (nth 0 buffers)))
                (should-not (taf-benchmark-detach-fixture))
                (run CONFIG)
                (should (buffer-live-p (nth 0 buffers)))
                (should (ebox-surface-buffer-mounted-p (nth 0 buffers)))
                (should (ebox-surface-buffer-mounted-p (nth 1 buffers)))
                (run CONFIG)
                (should-not (buffer-live-p (nth 1 buffers)))
                (should (ebox-surface-buffer-mounted-p (nth 0 buffers)))
                (should (ebox-surface-buffer-mounted-p (nth 2 buffers)))
                (run EMPTY_CONFIG)
                (should-not (buffer-live-p (nth 2 buffers)))
                (should (ebox-surface-buffer-mounted-p (nth 0 buffers)))
                (should-not (taf-benchmark-detach-fixture)))))
        (taf-benchmark-cancel)
        (dolist (fixture fixtures) (funcall (plist-get fixture :cleanup)))))))
(ert-run-tests-batch-and-exit)
""".replace("EMPTY_CONFIG", json.dumps(str(empty_config)))
               .replace("CONFIG", json.dumps(str(config)))
               .replace("REPORT", json.dumps(str(output))))
        process = subprocess.run(
            ["emacs", "-Q", "--batch", "-L", str(ROOT / "ecss"), "-L", str(ROOT / "ebox"),
             "--eval", "(setq load-prefer-newer t)",
             "-l", str(ROOT / "benchmarks/performance-driver.el"), "-l", str(FIXTURE), "-l", str(script)],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_functional_failure_is_not_a_performance_pass(self):
        process, report, output = self.run_case("failure", "fixture.fail")
        self.assertEqual(process.returncode, 2)
        self.assertFalse(report["valid"])
        self.assertIn("Deliberate verification failure", " ".join(report["errors"]))
        raw = json.loads((output / "latency-1.json").read_text())
        self.assertFalse(raw["samples"][0]["correct"])

    def test_timeout_retains_progress_and_stops_owned_batch(self):
        started = time.monotonic()
        process, report, output = self.run_case("timeout", "fixture.timeout", "--timeout", ".3", "--run-timeout", "3")
        self.assertLess(time.monotonic() - started, 8)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(report["runs"][0]["status"], "timeout")
        raw = json.loads((output / "latency-1.json").read_text())
        self.assertEqual(raw["active"]["stage"], "action")
        with self.assertRaises(ProcessLookupError):
            os.kill(raw["environment"]["pid"], 0)

    def test_correct_behavior_can_fail_latency(self):
        process, report, _ = self.run_case("slow", "fixture.slow")
        self.assertEqual(process.returncode, 1)
        self.assertTrue(report["valid"])
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cases"]["fixture.slow"]["over_budget"], 2)

    def test_context_changes_are_not_accepted(self):
        process, report, output = self.run_case("context", "fixture.context")
        self.assertEqual(process.returncode, 2)
        self.assertFalse(report["valid"])
        raw = json.loads((output / "latency-1.json").read_text())
        self.assertFalse(raw["samples"][0]["environment_stable"])

    def test_comparison_rejects_incomplete_or_inconsistent_evidence(self):
        before = self.good[1]
        for mutate in (
            lambda report: report["cases"]["fixture.counter"]["samples_ms"].pop(),
            lambda report: report["cases"]["fixture.counter"]["sets"].append(copy.deepcopy(report["cases"]["fixture.counter"]["sets"][0])),
            lambda report: report["cases"]["fixture.counter"].update(max_ms=float("nan")),
            lambda report: report["cases"]["fixture.counter"].update(source_sha256="different"),
            lambda report: report.update(valid=False),
            lambda report: report.update(machine={"node": "another"}),
            lambda report: report["tool_identity"].update(driver="different"),
            lambda report: report["settings"].update(boundary="another-boundary"),
        ):
            with self.subTest(mutate=mutate):
                changed = copy.deepcopy(before)
                mutate(changed)
                self.assertEqual(self.compare(before, changed).returncode, 2)

    def test_startup_and_baseline_failures_preserve_final_reports(self):
        process, report, _ = self.run_case("missing-emacs", "fixture.counter", "--emacs", "/nonexistent/emacs")
        self.assertEqual(process.returncode, 2)
        self.assertEqual(report["status"], "unverified")
        self.assertTrue(report["errors"])
        process, report, _ = self.run_case("missing-baseline", "fixture.counter", "--baseline", str(self.base / "absent.json"))
        self.assertEqual(process.returncode, 2)
        self.assertEqual(report["comparison"]["status"], "incomparable")
        self.assertEqual(report["cases"]["fixture.counter"]["count"], 2)

    def test_regression_comparison_preserves_tail_and_maximum(self):
        before = self.good[1]
        after = copy.deepcopy(before)
        case = after["cases"]["fixture.counter"]
        case["samples_ms"] = [value + 3 for value in case["samples_ms"]]
        for group in case["sets"]:
            group["samples_ms"] = [value + 3 for value in group["samples_ms"]]
        for metric in ("p50_ms", "p95_ms", "p99_ms", "max_ms"):
            case[metric] += 3
        result = self.compare(before, after)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "regressed")


if __name__ == "__main__":
    unittest.main()
