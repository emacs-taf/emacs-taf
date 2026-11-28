"""Exercise the GUI scenario tool's supported input and evidence contracts."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ScenarioTests(unittest.TestCase):
    def run_scenario(self, execute='(insert "任务")', assertion='t', settled='t', screenshot='nil'):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name) / 'evidence'
        script = Path(temporary.name) / 'scenario.el'
        script.write_text(f''';;; -*- lexical-binding: t; -*-
(require 'emacs-gui-verifier)
(let ((scenario
       (etaf-gui-verifier-scenario-create
        :name "fixture" :claim "Tool ordering and failure evidence"
        :initialize (lambda (context)
                      (etaf-gui-verifier-context-select-buffer
                       context (get-buffer-create "*fixture*")))
        :actions
        (list (etaf-gui-verifier-action-create
               :id "edit" :execute (lambda (_context) {execute})
               :settled-p (lambda (_context) {settled})
               :settle-timeout 0.05 :settle-interval 0.001
               :screenshot {screenshot}
               :assertions (lambda (_context)
                             (list (etaf-gui-verifier-assert "expected" {assertion}))))))))
  (condition-case problem
      (etaf-gui-verifier-run scenario (getenv "SCENARIO_OUTPUT"))
    (error (princ (error-message-string problem)) (kill-emacs 1))))
''', encoding='utf-8')
        command = [os.environ.get('EMACS', 'emacs'), '-Q', '--batch',
                   '-L', str(ROOT / 'scripts'), '--eval', '(setq load-prefer-newer t)', '-l', str(script)]
        environment = {**os.environ, 'SCENARIO_OUTPUT': str(output)}
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
        records = [json.loads(line) for line in (output / 'manifest.jsonl').read_text().splitlines()]
        report = json.loads((output / 'result.json').read_text())
        return result, records, report, command, environment, output

    def test_ordered_actions_write_portable_evidence_without_a_skill(self):
        result, records, report, *_ = self.run_scenario()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['visual_review'], 'required')
        self.assertEqual(report['foreground_latency'], 'not-certified')
        self.assertIsNone(report['error'])
        self.assertEqual(set(records[0]),
                         {'kind', 'schema_version', 'run_id', 'claim', 'required_phases'})
        self.assertEqual([r['phase'] for r in records if r['kind'] == 'checkpoint'],
                         ['before-action', 'after-action', 'after-redisplay'])
        for record in records[1:-1]:
            self.assertEqual(set(record), {'kind', 'sequence', 'elapsed_ms', 'action_id',
                                          'phase', 'screenshot', 'window', 'buffer',
                                          'assertions', 'adapter'})
        self.assertEqual(set(records[-1]),
                         {'kind', 'sequence', 'elapsed_ms', 'completed', 'adapter'})
        self.assertEqual(len(report['measurements']), 1)
        self.assertFalse(report['measurements'][0]['presentation_measured'])
        self.assertTrue(records[-1]['completed'])

    def test_native_split_panes_have_layout_evidence(self):
        result, _, report, *_ = self.run_scenario(
            execute='(set-window-buffer (split-window-below) (get-buffer-create "*input*"))')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        measurement = report['measurements'][0]
        self.assertEqual(len(measurement['before']['window_layout']), 1)
        panes = measurement['after']['window_layout']
        self.assertEqual(len(panes), 2)
        self.assertEqual({p['buffer'] for p in panes}, {'*fixture*', '*input*'})
        self.assertEqual(sum(bool(p['selected']) for p in panes), 1)
        self.assertNotEqual(panes[0]['edges_px'], panes[1]['edges_px'])

    def test_false_assertion_is_a_failed_run_with_boolean_evidence(self):
        result, records, report, *_ = self.run_scenario(assertion='nil')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('expected', report['error'])
        self.assertIs(records[-2]['assertions'][-1]['passed'], False)
        self.assertIs(records[-1]['completed'], False)

    def test_callback_failure_keeps_the_original_error_and_measurement(self):
        result, _, report, *_ = self.run_scenario(execute='(error "fixture failure")')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report['error'], 'fixture failure')
        self.assertEqual(report['measurements'][0]['status'], 'error')

    def test_unsettled_result_and_unavailable_capture_fail_closed(self):
        for options, message in (({'settled': 'nil'}, 'timeout'),
                                 ({'screenshot': 't'}, 'graphical frame')):
            with self.subTest(options=options):
                result, _, report, *_ = self.run_scenario(**options)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(report['status'], 'failed')
                self.assertIn(message, report['error'])

    def test_existing_evidence_is_never_overwritten(self):
        _, _, _, command, environment, output = self.run_scenario()
        before = {p.name: p.read_bytes() for p in output.iterdir()}
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn('already exists', result.stdout)
        self.assertEqual(before, {p.name: p.read_bytes() for p in output.iterdir()})


if __name__ == '__main__':
    unittest.main()
