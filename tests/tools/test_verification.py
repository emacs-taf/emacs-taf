"""Exercise the workspace verification command with external tool fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

DRIVER = '''import json, os, pathlib, sys
args = sys.argv[1:]
def value(name):
    return args[args.index(name) + 1]
if args[0] == 'run':
    output = pathlib.Path(value('--output-dir'))
    output.mkdir(parents=True)
    sets = int(value('--sets'))
    valid = os.environ.get('VERIFY_EVIDENCE') != 'invalid'
    result = {'schema': 1, 'valid': valid, 'acceptance_eligible': sets >= 3,
              'status': 'passed' if sets >= 3 else 'screened',
              'settings': {'sets': sets, 'samples': int(value('--samples')),
                           'warmups': int(value('--warmups'))},
              'cases': {'action': {'samples_ms': [20.0] * 30 * sets}},
              'arguments': args}
    if os.environ.get('VERIFY_EVIDENCE') != 'missing':
        (output / 'result.json').write_text(json.dumps(result))
    code = 1 if os.environ.get('VERIFY_FAIL') == 'performance' else 0
else:
    before, after = (json.loads(pathlib.Path(path).read_text()) for path in args[1:3])
    code = 1 if (before['settings'] != after['settings'] or
                 os.environ.get('VERIFY_COMPARE') == 'regressed') else 0
print('fixture output ' * 1000)
sys.exit(code)
'''


class VerificationTests(unittest.TestCase):
    def verify(self, fail='', repeat=False, mutate=False, evidence='', compare=None,
               comparison_repeat=None):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repo = base / 'workspace'
            (repo / 'scripts').mkdir(parents=True)
            (repo / 'workspace.json').write_text('{"repositories": {}}')
            (repo / 'scripts/performance.py').write_text(DRIVER)
            for arguments in (['init', '-q'], ['add', '.'],
                              ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                               'commit', '-qm', 'fixture']):
                subprocess.run(['git', '-C', str(repo), *arguments], check=True, capture_output=True)
            make = base / 'make'
            make.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
if os.environ.get('VERIFY_MUTATE') and sys.argv[-1] == 'check':
    pathlib.Path('changed.txt').write_text('changed during verification')
print('fixture output ' * 1000)
sys.exit(1 if sys.argv[-1] == os.environ.get('VERIFY_FAIL') else 0)
''')
            make.chmod(0o755)
            command = [sys.executable, str(ROOT / 'scripts/verify.py'), '--root', str(repo),
                       '--output-dir', str(base / 'output'), '--make', str(make), '--record-baseline']
            if repeat:
                command.append('--repeatability')
            result = subprocess.run(command, capture_output=True, text=True,
                                    env={**os.environ, 'VERIFY_FAIL': fail,
                                         'VERIFY_EVIDENCE': evidence,
                                         'VERIFY_MUTATE': '1' if mutate else ''})
            report = json.loads((base / 'output/result.json').read_text())
            performance_path = base / 'output/performance/result.json'
            performance = json.loads(performance_path.read_text()) if performance_path.exists() else None
            if compare is not None:
                command.remove('--record-baseline')
                command[command.index('--output-dir') + 1] = str(base / 'comparison')
                if comparison_repeat is True and '--repeatability' not in command:
                    command.append('--repeatability')
                command += ['--baseline', str(base / 'output/result.json')]
                result = subprocess.run(command, capture_output=True, text=True,
                                        env={**os.environ, 'VERIFY_COMPARE': compare})
                report = json.loads((base / 'comparison/result.json').read_text())
            return result, report, performance

    def test_repeatability_uses_registered_driver_with_complete_coverage(self):
        result, report, performance = self.verify(repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['status'], 'passed')
        self.assertTrue(report['acceptance_eligible'])
        self.assertLess(len(result.stdout), 1800)
        self.assertNotIn('fixture output', result.stdout)
        self.assertEqual(performance['settings'], {'sets': 3, 'samples': 30, 'warmups': 5})
        self.assertEqual(len(performance['cases']['action']['samples_ms']), 90)
        self.assertIn('etaf-playground.*', performance['arguments'])
        self.assertEqual([p['name'] for p in report['phases']],
                         ['prepare', 'performance', 'functional', 'source-stability'])

    def test_single_set_is_a_screen_not_repeatability_acceptance(self):
        result, report, _ = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['status'], 'screened')
        self.assertFalse(report['acceptance_eligible'])

    def test_comparison_delegates_to_the_measurement_driver(self):
        for verdict, code in (('passed', 0), ('regressed', 1)):
            with self.subTest(verdict=verdict):
                result, report, _ = self.verify(compare=verdict)
                self.assertEqual(result.returncode, code, result.stderr)
                phase = next(p for p in report['phases'] if p['name'] == 'performance-comparison')
                self.assertIn('compare', phase['command'])
                self.assertEqual(phase['command'][-2:], ['--allowance-ms', '2.0'])

    def test_different_sample_grouping_is_not_a_comparable_baseline(self):
        result, report, _ = self.verify(compare='passed', comparison_repeat=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(report['status'], 'failed')

    def test_comparison_keeps_a_three_set_baseline_grouping(self):
        result, report, _ = self.verify(repeat=True, compare='passed')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['performance_sets'], 3)
        self.assertEqual(report['status'], 'passed')

    def test_failed_baseline_cannot_be_reused_as_passing_evidence(self):
        result, report, _ = self.verify(fail='performance', compare='passed')
        self.assertEqual(result.returncode, 1, result.stderr)
        phase = next(p for p in report['phases'] if p['name'] == 'performance-comparison')
        self.assertIn('baseline', phase['reason'])

    def test_performance_failure_still_runs_functional_checks(self):
        result, report, _ = self.verify(fail='performance')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report['phases'][1]['status'], 'failed')
        self.assertEqual(report['phases'][2]['status'], 'passed')

    def test_missing_or_invalid_evidence_cannot_pass_on_exit_code_alone(self):
        for evidence in ('missing', 'invalid'):
            with self.subTest(evidence=evidence):
                result, report, _ = self.verify(evidence=evidence)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(report['phases'][1]['status'], 'failed')
                self.assertEqual(report['phases'][2]['status'], 'passed')

    def test_preparation_failure_is_not_a_performance_pass(self):
        result, report, performance = self.verify(fail='compile')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report['phases'][1]['status'], 'not-run')
        self.assertEqual(report['phases'][2]['status'], 'passed')
        self.assertIsNone(performance)

    def test_functional_failure_and_source_changes_reject_the_run(self):
        for options in ({'fail': 'check'}, {'mutate': True}):
            with self.subTest(options=options):
                result, report, _ = self.verify(**options)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(report['status'], 'failed')
                if options.get('mutate'):
                    self.assertIn('UNVERIFIED: Workspace sources changed during measurement',
                                  result.stdout)


if __name__ == '__main__':
    unittest.main()
