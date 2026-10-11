"""Black-box contracts for the shared performance command and scenario driver."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ROOT / "scripts/performance.py"
FIXTURE = ROOT / "tests/fixtures/performance-scenarios.el"


class ExitPublicationCommand(unittest.TestCase):
    def test_final_report_published_between_read_and_exit_poll_is_preserved(self):
        launcher = '''import runpy, subprocess, sys
original = subprocess.Popen
class ExitAfterPublication(original):
    def poll(self):
        if any("taf-benchmark-start" in str(arg) for arg in self.args):
            self.wait(timeout=15)
        return super().poll()
subprocess.Popen = ExitAfterPublication
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
'''
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                [sys.executable, '-c', launcher, str(COMMAND), 'run', '--root', str(ROOT),
                 '--scenario-file', str(FIXTURE), '--mode', 'batch',
                 '--scenario', 'fixture.counter', '--sets', '1', '--samples', '2',
                 '--warmups', '0', '--output-dir', directory],
                capture_output=True, text=True, timeout=25)
            self.assertEqual(0, process.returncode, process.stdout + process.stderr)
            report = json.loads((Path(directory)/'result.json').read_text())
            self.assertTrue(report['valid'])
            self.assertEqual(2, report['cases']['fixture.counter']['count'])
            self.assertNotIn('Batch exited', process.stdout + process.stderr)


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
    def run_case(cls, name, scenario, *extra, warmups=0):
        output = cls.base / name
        process = subprocess.run(
            [sys.executable, str(COMMAND), "run", "--root", str(ROOT),
             "--scenario-file", str(FIXTURE), "--mode", "batch", "--scenario", scenario,
             "--samples", "2", "--sets", "1", "--output-dir", str(output),
             *([] if warmups is None else ["--warmups", str(warmups)]), *extra],
            capture_output=True, text=True, timeout=25)
        return process, json.loads((output / "result.json").read_text()), output

    def test_disposal_requires_actual_target_death_and_stable_parent_context(self):
        process, result, output = self.run_case("dispose", "fixture.dispose")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertTrue(result["valid"])
        raw = json.loads((output / "latency-1.json").read_text())
        self.assertTrue(all(row["target_disposed"] for row in raw["samples"]))
        self.assertTrue(all(row["before"]["buffer"] and row["after"]["buffer"] is None
                            for row in raw["samples"]))
        for name in ("dispose-unexpected", "dispose-missing", "dispose-context"):
            process, result, _ = self.run_case(name, "fixture." + name)
            self.assertNotEqual(process.returncode, 0, process.stdout + process.stderr)
            self.assertFalse(result["valid"])

    def compare(self, before, after):
        left, right = self.base / "before.json", self.base / "after.json"
        left.write_text(json.dumps(before))
        right.write_text(json.dumps(after))
        return subprocess.run([sys.executable, str(COMMAND), "compare", str(left), str(right)],
                              capture_output=True, text=True, timeout=5)

    def runtime_case(self, name, strategy, extra_module=False, lazy_source=False, symlink_root=False):
        """Exercise real library loading, including stale fixture bytecode."""
        directory = self.base / name
        package = directory / "fixture-runtime"
        library = package / "lisp"
        library.mkdir(parents=True)
        entry = package / "fixture-runtime.el"
        worker = library / "fixture-worker.el"
        entry.write_text(""";;; -*- lexical-binding: t; -*-
(add-to-list 'load-path (expand-file-name "lisp" (file-name-directory load-file-name)))
(require 'fixture-worker)
(provide 'fixture-runtime)
""")
        worker.write_text(""";;; -*- lexical-binding: t; -*-
(defun fixture-next (value) (1+ value))
(provide 'fixture-worker)
""")
        sources = [worker, entry]
        if extra_module:
            extra = library / "fixture-extra.el"
            extra.write_text("(provide 'fixture-extra)\n")
            worker.write_text("(require 'fixture-extra)\n" + worker.read_text())
            sources.insert(0, extra)
        compilation = subprocess.run(
            ["emacs", "-Q", "--batch", "-L", str(library), "-f", "batch-byte-compile",
             *map(str, sources)], capture_output=True, text=True, timeout=10)
        self.assertEqual(compilation.returncode, 0, compilation.stdout + compilation.stderr)
        if strategy in ("interpreted", "mixed"):
            # Reproduce a checkout newer than copied .elc artifacts.  These
            # fixture-only timestamp changes must never occur in the runner.
            for source in sources if strategy == "interpreted" else [worker]:
                source.write_text(source.read_text() + "; changed source\n")
                newer = source.with_suffix(".elc").stat().st_mtime_ns + 2_000_000_000
                os.utime(source, ns=(newer, newer))
        lazy = "nil"
        if lazy_source:
            examples = package / "examples"
            examples.mkdir()
            example = examples / "fixture-example.el"
            example.write_text("(provide 'fixture-example)\n")
            lazy = f'(load {json.dumps(str(example))} nil t t)'
        scenario = directory / "scenario.el"
        scenario.write_text(""";;; -*- lexical-binding: t; -*-
(require 'fixture-runtime)
(taf-benchmark-register
 "fixture.library" :modes '(batch) :budget-ms 100 :impact 'local :isolation 'series
 :setup (lambda (_mode)
          (let ((buffer (generate-new-buffer " *library-fixture*")) (count 0))
            (list :buffer buffer
                  :invoke (lambda (_sample)
                            LAZY_LOAD
                            (setq count (fixture-next count))
                            (with-current-buffer buffer
                              (erase-buffer) (insert (number-to-string count))))
                  :verify (lambda ()
                            (with-current-buffer buffer (equal (buffer-string) (number-to-string count))))
                  :cleanup (lambda () (kill-buffer buffer))))))
""".replace("LAZY_LOAD", lazy))
        if symlink_root:
            workspace = directory / "workspace"
            workspace.mkdir()
            (workspace / "fixture-runtime").symlink_to(package, target_is_directory=True)
            (workspace / "workspace.json").write_text(json.dumps({"repositories": {"fixture-runtime": {}}}))
            paths = ["--root", str(workspace)]
        else:
            paths = ["--load-path", str(package)]
        return self.run_case(name + "-run", "fixture.library", *paths, "--scenario-file", str(scenario))

    def test_library_formats_reject_false_compiled_speedups_and_allow_module_splits(self):
        source_process, source, source_output = self.runtime_case("libraries-source", "interpreted")
        compiled_process, compiled, compiled_output = self.runtime_case("libraries-compiled", "compiled")
        split_process, split, _ = self.runtime_case("libraries-split", "compiled", extra_module=True)
        linked_process, linked, _ = self.runtime_case("libraries-symlink", "compiled", symlink_root=True)
        for process in (source_process, compiled_process, split_process, linked_process):
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        for report, strategy, count in ((source, "interpreted", 2), (compiled, "compiled", 2),
                                        (split, "compiled", 3), (linked, "compiled", 2)):
            code = report["cases"]["fixture.library"]["runtime_code"]
            self.assertEqual(code["strategies"], [strategy])
            self.assertEqual(len(code["libraries"]), count)
        raw = json.loads((source_output / "latency-1.json").read_text())
        self.assertEqual({row["format"] for row in raw["samples"][0]["before"]["runtime_libraries"]}, {"source"})
        raw = json.loads((compiled_output / "latency-1.json").read_text())
        self.assertEqual({row["format"] for row in raw["samples"][0]["before"]["runtime_libraries"]}, {"compiled"})
        self.assertEqual(self.compare(source, source).returncode, 0)
        mismatch = self.compare(source, compiled)
        self.assertEqual(mismatch.returncode, 2)
        self.assertIn("execution strategy differs", mismatch.stdout)
        # A package split adds a compiled module without changing workload or
        # execution strategy.  Paths and module counts are diagnostic evidence.
        self.assertEqual(self.compare(compiled, split).returncode, 0)
        self.assertEqual(self.compare(compiled, linked).returncode, 0)
        missing = copy.deepcopy(compiled)
        del missing["cases"]["fixture.library"]["runtime_code"]
        self.assertEqual(self.compare(compiled, missing).returncode, 2)

    def test_mixed_and_mid_sample_library_formats_remain_unverified(self):
        for name, strategy, lazy in (("libraries-mixed", "mixed", False),
                                      ("libraries-lazy", "compiled", True)):
            with self.subTest(name=name):
                process, report, output = self.runtime_case(name, strategy, lazy_source=lazy)
                self.assertEqual(process.returncode, 2, process.stdout + process.stderr)
                self.assertFalse(report["valid"])
                code = report["cases"]["fixture.library"]["runtime_code"]
                self.assertIn("mixed", code["strategies"])
                self.assertIn("Runtime library load formats", " ".join(report["errors"]))
                self.assertEqual(self.compare(report, report).returncode, 2)
                if lazy:
                    raw = json.loads((output / "latency-1.json").read_text())["samples"][0]
                    self.assertEqual({row["format"] for row in raw["before"]["runtime_libraries"]}, {"compiled"})
                    self.assertEqual({row["format"] for row in raw["after"]["runtime_libraries"]}, {"compiled", "source"})

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
        flush = trace["samples"][0]["reports"][1]
        self.assertEqual((flush["provider"], flush["strategy"], flush["edits"], flush["lines"]),
                         ("ebox", "full", 1, 2))
        self.assertEqual(case["strategies"], [{"strategy": "full", "count": 1}])
        self.assertEqual(case["flush_medians"]["lines"], 2)
        self.assertIn("full_repaint_on_local_update", {row["kind"] for row in case["findings"]})
        self.assertIn("flush strategies: full=1", process.stdout)
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

    def test_default_warmups_retain_first_use_without_polluting_latency(self):
        process, report, output = self.run_case("warmups", "fixture.sequence", "--sets", "2", warmups=None)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(report["settings"]["warmups"], 5)
        case = report["cases"]["fixture.sequence"]
        self.assertEqual(case["count"], 4)
        self.assertEqual(case["over_budget"], 0)
        self.assertEqual(case["warmups"]["count"], 10)
        self.assertEqual(case["warmups"]["attempted_count"], 10)
        self.assertEqual(case["warmups"]["failures"], [])
        self.assertGreaterEqual(case["warmups"]["max_ms"], 150)
        self.assertEqual(case["all_latency"]["count"], 14)
        self.assertEqual(case["all_latency"]["max_ms"], case["warmups"]["max_ms"])
        self.assertLess(case["max_ms"], case["warmups"]["max_ms"])
        for number in (1, 2):
            raw = json.loads((output / f"latency-{number}.json").read_text())["samples"]
            self.assertEqual([row["phase"] for row in raw], ["warmup"] * 5 + ["latency"] * 2)
            self.assertEqual([row["iteration"] for row in raw], list(range(7)))
            self.assertEqual([row["sample"] for row in raw], list(range(5)) + [0, 1])
            self.assertEqual([row["outcome"] for row in raw], [{"count": value} for value in range(1, 8)])
            self.assertTrue(all(row["correct"] and row["environment_stable"] for row in raw))
            self.assertTrue(all(row["profile"] is None and not row["diagnostic"] for row in raw))
        self.assertIn("warmups=10/10", process.stdout)
        self.assertIn("all-latency=14/14", process.stdout)
        self.assertEqual(self.compare(report, report).returncode, 0)
        for mutate in (
            lambda item: item["settings"].update(warmups=4),
            lambda item: item["settings"].update(warmup_protocol="unrecorded"),
            lambda item: item["cases"]["fixture.sequence"]["warmups"]["samples_ms"].pop(),
            lambda item: item["cases"]["fixture.sequence"]["warmups"].update(max_ms=0),
            lambda item: item["cases"]["fixture.sequence"]["warmups"]["environments"][0].update(font="different"),
            lambda item: item["cases"]["fixture.sequence"]["all_latency"].update(count=4),
        ):
            with self.subTest(mutate=mutate):
                changed = copy.deepcopy(report)
                mutate(changed)
                self.assertEqual(self.compare(report, changed).returncode, 2)

    def test_warmup_verification_and_context_failures_remain_unverified(self):
        for scenario in ("fixture.fail", "fixture.context"):
            with self.subTest(scenario=scenario):
                process, report, output = self.run_case("warmup-" + scenario, scenario, warmups=1)
                self.assertEqual(process.returncode, 2)
                self.assertFalse(report["valid"])
                case = report["cases"][scenario]
                self.assertEqual(case["count"], 0)
                self.assertEqual(case["warmups"]["count"], 1)
                self.assertEqual(case["warmups"]["invalid_count"], 1)
                self.assertEqual(len(case["warmups"]["failures"]), 1)
                self.assertEqual(case["all_latency"]["count"], 1)
                self.assertEqual(case["all_latency"]["attempted_count"], 1)
                raw = json.loads((output / "latency-1.json").read_text())
                self.assertEqual(raw["active"]["phase"], "warmup")
                self.assertEqual(raw["samples"][0]["phase"], "warmup")

    def test_timed_out_warmup_preserves_attempt_and_failure_reason(self):
        process, report, _ = self.run_case("warmup-timeout", "fixture.timeout", "--timeout", ".3",
                                         "--run-timeout", "3", warmups=1)
        self.assertEqual(process.returncode, 2)
        case = report["cases"]["fixture.timeout"]
        self.assertEqual(case["count"], 0)
        self.assertEqual(case["warmups"]["count"], 0)
        self.assertEqual(case["warmups"]["attempted_count"], 1)
        self.assertEqual(case["all_latency"]["attempted_count"], 1)
        failure = case["warmups"]["failures"][0]
        self.assertEqual(failure["phase"], "warmup")
        self.assertEqual(failure["stage"], "action")
        self.assertIn("exceeded", failure["reason"])

    def test_warmups_are_configurable_and_do_not_enter_diagnostics(self):
        process, report, output = self.run_case("warmup-diagnose", "fixture.async", "--diagnose",
                                              "--diagnostic-samples", "1", warmups=2)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        case = report["cases"]["fixture.async"]
        self.assertEqual(case["warmups"]["count"], 2)
        self.assertEqual(case["count"], 2)
        self.assertEqual(case["diagnostic_count"], 3)
        self.assertTrue(all(value >= 10 for value in case["warmups"]["samples_ms"]))
        for kind in ("trace", "cpu", "memory"):
            rows = json.loads((output / f"{kind}-1.json").read_text())["samples"]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["phase"], "diagnostic")

    def test_warmups_obey_the_all_interaction_hard_limit(self):
        process, report, _ = self.run_case("warmup-hard-limit", "fixture.cold-slow", warmups=1)
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertTrue(report["valid"])
        self.assertEqual(report["status"], "failed")
        case = report["cases"]["fixture.cold-slow"]
        self.assertEqual(case["over_budget"], 0)
        self.assertEqual(case["over_hard_limit"], 1)
        self.assertGreaterEqual(case["warmups"]["max_ms"], 550)
        self.assertLess(case["max_ms"], 100)

    def test_warmup_bounds_are_validated_before_creating_evidence(self):
        for count in (-1, 1001):
            with self.subTest(count=count):
                output = self.base / f"warmup-bounds-{count}"
                process = subprocess.run(
                    [sys.executable, str(COMMAND), "run", "--root", str(ROOT),
                     "--scenario-file", str(FIXTURE), "--mode", "batch", "--scenario", "fixture.counter",
                     "--warmups", str(count), "--output-dir", str(output)],
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(process.returncode, 2)
                self.assertIn("outside supported bounds", process.stderr)
                self.assertFalse(output.exists())

    def test_acceptance_requires_three_complete_thirty_sample_sets(self):
        process, report, _ = self.run_case("short-acceptance", "fixture.async", "--sets", "3",
                                         "--samples", "10", warmups=5)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertFalse(report["acceptance_eligible"])
        self.assertEqual(report["status"], "screened")
        changed = copy.deepcopy(report)
        changed["acceptance_eligible"] = True
        self.assertEqual(self.compare(changed, changed).returncode, 2)

    def test_diagnostic_failures_remain_distinct_from_latency_and_each_other(self):
        process, report, _ = self.run_case("diagnostic-fail", "fixture.diagnostic-fail", "--diagnose",
                                         "--diagnostic-samples", "1", warmups=1)
        self.assertEqual(process.returncode, 2)
        case = report["cases"]["fixture.diagnostic-fail"]
        self.assertEqual(case["warmups"]["count"], 1)
        self.assertEqual(case["all_latency"]["failures"], [])
        self.assertEqual({failure["diagnostic_kind"] for failure in case["failures"]}, {"trace", "cpu"})
        self.assertIn("Deliberate profiler-pass failure", process.stdout)

    def test_cleanup_failure_retains_its_reason_without_adding_an_attempt(self):
        process, report, _ = self.run_case("cleanup-fail", "fixture.cleanup-fail", warmups=1)
        self.assertEqual(process.returncode, 2)
        case = report["cases"]["fixture.cleanup-fail"]
        self.assertEqual(case["all_latency"]["count"], 3)
        self.assertEqual(case["all_latency"]["attempted_count"], 3)
        self.assertEqual(case["failures"][0]["stage"], "cleanup")
        self.assertEqual(case["failures"][0]["reason"], "Deliberate cleanup failure")

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

    def journal_case(self, name, crash=False):
        directory = self.base / name
        directory.mkdir()
        output = directory / "evidence"
        report = output / "latency-1.json"
        scenario = directory / "scenario.el"
        failure = (f'(when (= index 2) (write-region "{{" nil {json.dumps(str(report) + ".samples.jsonl")} t (quote silent)) (kill-emacs 17))'
                   if crash else "nil")
        scenario.write_text(''';;; -*- lexical-binding: t; -*-
(require 'ebox)
(taf-benchmark-register
 "fixture.journal" :modes '(batch) :budget-ms 1000 :impact 'local :isolation 'series
 :setup (lambda (_mode)
          (let ((buffer (generate-new-buffer " *journal-fixture*")) bytes count)
            (list :buffer buffer
                  :invoke (lambda (index)
                            FAILURE
                            (setq bytes (file-attribute-size (file-attributes REPORT)))
                            (with-temp-buffer
                              (insert-file-contents REPORT)
                              (setq count (plist-get (json-parse-buffer :object-type 'plist) :sample_count))))
                  :outcome (lambda () (list :progress_bytes bytes :progress_count count
                                           :payload (make-string 32000 ?x)))
                  :verify (lambda () t)
                  :cleanup (lambda () (kill-buffer buffer))))))
'''.replace("FAILURE", failure).replace("REPORT", json.dumps(str(report))))
        process = subprocess.run(
            [sys.executable, str(COMMAND), "run", "--root", str(ROOT),
             "--scenario-file", str(scenario), "--scenario", "fixture.journal",
             "--mode", "batch", "--sets", "1", "--samples", "4", "--warmups", "0",
             "--output-dir", str(output)], capture_output=True, text=True, timeout=25)
        return process, json.loads((output / "result.json").read_text()), report

    def test_live_progress_is_bounded_and_final_report_keeps_every_row(self):
        process, result, path = self.journal_case("journal-complete")
        self.assertEqual(0, process.returncode, process.stdout + process.stderr)
        self.assertTrue(result["valid"])
        final = json.loads(path.read_text())
        rows = final["samples"]
        self.assertEqual(4, len(rows))
        self.assertEqual([0, 1, 2, 3], [row["outcome"]["progress_count"] for row in rows])
        sizes = [row["outcome"]["progress_bytes"] for row in rows]
        self.assertLess(max(sizes) - min(sizes), 1024)
        journal = [json.loads(line) for line in Path(str(path) + ".samples.jsonl").read_text().splitlines()]
        self.assertTrue(journal == rows, "Journal differs from final sample rows")

    def test_abrupt_exit_recovers_completed_samples_before_a_torn_journal_row(self):
        process, result, path = self.journal_case("journal-interrupted", crash=True)
        self.assertNotEqual(0, process.returncode)
        self.assertFalse(result["valid"])
        self.assertEqual(2, result["cases"]["fixture.journal"]["count"])
        self.assertEqual(3, result["cases"]["fixture.journal"]["all_latency"]["attempted_count"])
        progress = json.loads(path.read_text())
        self.assertEqual([], progress["samples"])
        self.assertEqual(2, progress["sample_count"])
        self.assertTrue(Path(str(path) + ".samples.jsonl").read_text().endswith("{"))

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
                               (lambda () (and (ebox-buffer-mount buffer) t)))
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
                (should (ebox-buffer-mount (nth 0 buffers)))
                (should (ebox-buffer-mount (nth 1 buffers)))
                (run CONFIG)
                (should-not (buffer-live-p (nth 1 buffers)))
                (should (ebox-buffer-mount (nth 0 buffers)))
                (should (ebox-buffer-mount (nth 2 buffers)))
                (run EMPTY_CONFIG)
                (should-not (buffer-live-p (nth 2 buffers)))
                (should (ebox-buffer-mount (nth 0 buffers)))
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

    def test_scenario_entries_load_once_per_emacs_process(self):
        directory = self.base / "reload-scenario"
        directory.mkdir()
        scenario = directory / "scenarios.el"
        scenario.write_text(""";;; -*- lexical-binding: t; -*-
(defvar taf-test-reload-loads 0)
(setq taf-test-reload-loads (1+ taf-test-reload-loads))
(taf-benchmark-register
 "fixture.reload" :modes '(batch) :budget-ms 100 :impact 'local
 :setup
 (lambda (_mode)
   (let ((buffer (generate-new-buffer " *reload*")))
     (ebox-render-to-buffer buffer (ebox-build '(box "Reload")))
     (list :buffer buffer
           :invoke (lambda (_sample) nil)
           :verify (lambda ()
                     (with-current-buffer buffer
                       (string-match-p "Reload" (buffer-string))))
           :cleanup (lambda ()
                      (when (buffer-live-p buffer) (kill-buffer buffer)))))))
""")
        configurations = []
        for number, name in enumerate(("latency", "trace"), start=1):
            configuration = {
                "output": str(directory / (name + ".json")), "mode": "batch", "run_id": name,
                "scenario_files": [str(scenario)], "load_paths": [], "code_roots": [],
                "jobs": [{"id": "fixture.reload", "set": 1, "sample": number,
                          "diagnostic": name == "trace",
                          "diagnostic_kind": "trace" if name == "trace" else None,
                          "phase": "diagnostic" if name == "trace" else "latency"}],
                "timeout": 3,
            }
            path = directory / (name + "-configuration.json")
            path.write_text(json.dumps(configuration))
            configurations.append(str(path))
        script = directory / "reload-test.el"
        script.write_text(""";;; -*- lexical-binding: t; -*-
(require 'ert)
(require 'ebox)
(ert-deftest taf-test-scenario-entries-load-once ()
  (dolist (configuration CONFIGURATIONS)
    (taf-benchmark-start configuration)
    (with-timeout (5 (ert-fail "Driver did not finish"))
      (while (taf-benchmark-running-p) (accept-process-output nil .01))))
  (should (= taf-test-reload-loads 1)))
(ert-run-tests-batch-and-exit)
""".replace("CONFIGURATIONS",
                      "(list " + " ".join(json.dumps(path) for path in configurations) + ")"))
        process = subprocess.run(
            ["emacs", "-Q", "--batch", "-L", str(ROOT / "ecss"), "-L", str(ROOT / "ebox"),
             "--eval", "(setq load-prefer-newer t)",
             "-l", str(ROOT / "benchmarks/performance-driver.el"), "-l", str(script)],
            capture_output=True, text=True, timeout=15)
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
        case["all_latency"]["max_ms"] += 3
        result = self.compare(before, after)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "regressed")


class PerformanceGate(unittest.TestCase):
    """The gate runner's twin contract and the budget classes it is judged by."""

    def evaluate(self, results, status="done", total=None):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "gate.json"
            report.write_text(json.dumps({"status": status, "frame": {}, "results": results,
                                          "total": len(results) if total is None else total}))
            return subprocess.run([sys.executable, str(COMMAND), "gate", "--report", str(report)],
                                  capture_output=True, text=True, timeout=20)

    @staticmethod
    def result(name, klass, op, total=1000, twin=None, cons=10, verify=True, **gate):
        return {"id": name, "gate": {"class": klass, **gate}, "op": [op] * 5, "total": [total] * 5,
                "cons": [cons] * 5, "twin": None if twin is None else [twin] * 5,
                "twin-error": None, "gcs": 0, "verify": verify}

    def test_runner_prepares_samples_and_replays_reported_ranges(self):
        with tempfile.TemporaryDirectory() as directory:
            output, configuration = Path(directory) / "gate.json", Path(directory) / "configuration.json"
            configuration.write_text(json.dumps({"output": str(output), "scenario_files": [str(FIXTURE)],
                                                 "scenarios": [r"fixture\.gate\."], "samples": 6}))
            subprocess.run(["emacs", "-Q", "--batch", "-l", str(ROOT / "benchmarks/performance-gate.el"),
                            "--eval", f"(progn (taf-gate-start {json.dumps(str(configuration))}) "
                            "(with-timeout (20) (while (taf-gate-running-p) (accept-process-output nil 0.05))))"],
                           check=True, capture_output=True, timeout=30)
            report = json.loads(output.read_text())
            evaluated = subprocess.run([sys.executable, str(COMMAND), "gate", "--report", str(output)],
                                       capture_output=True, text=True, timeout=20)
        results = {result["id"]: result for result in report["results"]}
        self.assertEqual("done", report["status"])
        self.assertEqual(4, report["total"])
        self.assertIs(True, results["fixture.gate.prepared"]["verify"])
        for name in ("fixture.gate.rewrite", "fixture.gate.replay"):
            self.assertIs(True, results[name]["verify"])
            self.assertIsNone(results[name]["twin-error"])
            self.assertEqual(6, len(results[name]["twin"]))
            self.assertEqual(6, len(results[name]["op"]))
        self.assertIn("do not reproduce", results["fixture.gate.wrong-ranges"]["twin-error"])
        self.assertIsNone(results["fixture.gate.wrong-ranges"]["twin"])
        self.assertEqual(1, evaluated.returncode, evaluated.stdout)
        self.assertIn("FAIL fixture.gate.wrong-ranges: twin:", evaluated.stdout)
        self.assertNotIn("FAIL fixture.gate.rewrite", evaluated.stdout)

    def test_budget_classes_end_to_end_slack_and_size_independence(self):
        passing = [self.result("a.local.30", "local", 40, total=1100, twin=1000),
                   self.result("a.local.10000", "local", 45, total=1150, twin=1000),
                   self.result("a.tree.400", "propagate", 190),
                   self.result("a.list.30", "structure", 50),
                   self.result("a.list.10000", "structure", 290, total=1400, twin=1000),
                   self.result("a.snapshot.10000", "snapshot", 1900, total=3000, twin=1000),
                   self.result("a.counter", "counter", 30),
                   self.result("a.resize.400", "resize", 15000),
                   self.result("a.mount.400", "rows", 400 * 39),
                   self.result("a.filter.400", "rows", 9000, total=10100, twin=1000)]
        process = self.evaluate(passing)
        self.assertEqual(0, process.returncode, process.stdout)
        self.assertIn("PASS: 10 scenarios, 0 failures", process.stdout)
        failing = [self.result("b.op.30", "local", 51),
                   self.result("b.cons.30", "local", 10, cons=201),
                   self.result("b.e2e.30", "local", 10, total=1201, twin=1000),
                   self.result("b.verify.30", "local", 10, verify="stale row"),
                   self.result("b.grow.30", "propagate", 20),
                   self.result("b.grow.10000", "propagate", 51),
                   self.result("b.mount.400", "rows", 400 * 41),
                   self.result("b.filter.400", "rows", 9000, total=10201, twin=1000),
                   self.result("b.list.10000", "structure", 301, total=1502, twin=1000),
                   self.result("b.snapshot.10000", "snapshot", 2001),
                   self.result("b.counter", "counter", 31, cons=201),
                   self.result("b.resize.400", "resize", 16001),
                   self.result("b.unknown.30", "fast", 1)]
        process = self.evaluate(failing)
        self.assertEqual(1, process.returncode, process.stdout)
        for expected in ("b.op.30: op p50 51 > 50", "b.cons.30: cons p50 201 > 200",
                         "b.e2e.30: e2e +201 us over twin", "b.verify.30: verify: stale row",
                         "b.grow: op p50 grows 20 -> 51", "b.mount.400: op 41.0 us/row > 40",
                         "b.filter.400: redisplay +201 us over twin",
                         "b.list.10000: op p50 301 > 300", "b.list.10000: redisplay +201 us",
                         "b.snapshot.10000: op p50 2001 > 2000",
                         "b.counter: op p50 31 > 30", "b.counter: cons p50 201 > 200",
                         "b.resize.400: op p50 16001 > 16000",
                         "b.unknown.30: unknown gate class fast"):
            self.assertIn("FAIL " + expected, process.stdout)

    def test_incomplete_or_running_reports_are_unverified(self):
        self.assertEqual(2, self.evaluate([self.result("c.x.30", "local", 1)], total=2).returncode)
        self.assertEqual(2, self.evaluate([], status="running", total=1).returncode)


@unittest.skipUnless(shutil.which("jj"), "jj is not installed")
class SourceProvenance(unittest.TestCase):
    def test_secondary_jj_workspace_records_revision_and_changes(self):
        spec = importlib.util.spec_from_file_location("performance", COMMAND)
        tool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tool)
        with tempfile.TemporaryDirectory() as directory:
            main, second = Path(directory) / "main", Path(directory) / "second"
            subprocess.run(["jj", "git", "init", str(main)], check=True, capture_output=True)
            (main / "package.el").write_text("(provide 'package)\n")
            subprocess.run(["jj", "commit", "-m", "base"], cwd=main, check=True, capture_output=True)
            subprocess.run(["jj", "workspace", "add", str(second)], cwd=main,
                           check=True, capture_output=True)
            head = subprocess.check_output(["jj", "log", "--no-graph", "-r", "@-", "-T", "commit_id"],
                                           cwd=second, text=True).strip()
            clean = tool.source_snapshot([second])["second"]
            self.assertEqual(head, clean["revision"])
            self.assertEqual("", clean["status"])
            (second / "package.el").write_text("(provide 'package) ; edited\n")
            edited = tool.source_snapshot([second])["second"]
            self.assertEqual(head, edited["revision"])
            self.assertIn("package.el", edited["status"])
            self.assertNotEqual(clean["change_digest"], edited["change_digest"])


if __name__ == "__main__":
    unittest.main()
