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
        trace = json.loads((output / "trace-1.json").read_text())
        self.assertEqual(trace["samples"][0]["reports"][0]["provider"], "fixture")
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
