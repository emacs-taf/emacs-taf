"""Verify the workspace runner's command, result and failure contracts."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VerificationTests(unittest.TestCase):
    def verify(self, fail='', repeat=False, mutate=False, delta=None):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repo = base / 'workspace'
            repo.mkdir()
            (repo / 'workspace.json').write_text('{"repositories": {}}')
            evaluator = repo / 'etaf-playground/benchmarks/benchmark-research-shelf.el'
            evaluator.parent.mkdir(parents=True)
            evaluator.write_text('; fixture evaluator\n')
            for arguments in (['init', '-q'], ['add', '.'],
                              ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                               'commit', '-qm', 'fixture']):
                subprocess.run(['git', '-C', str(repo), *arguments], check=True, capture_output=True)
            make = base / 'make'
            make.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if 'INCREMENTAL_PERF_MANIFEST' in os.environ:
    pathlib.Path(os.environ['INCREMENTAL_PERF_MANIFEST']).write_text(json.dumps({
        'source_identity': os.environ['INCREMENTAL_SOURCE_IDENTITY'],
        'set_index': os.environ['INCREMENTAL_SET_INDEX'],
        'warmups': 5, 'machine_id': 'fixture',
        'evaluator_identity': os.environ['INCREMENTAL_EVALUATOR_IDENTITY'],
        'scenarios': {'action': {'samples_ms': [20 + float(os.environ.get('VERIFY_DELTA', '0'))] * 30,
            'p95_ms': 20 + float(os.environ.get('VERIFY_DELTA', '0')),
            'max_ms': 20 + float(os.environ.get('VERIFY_DELTA', '0'))}}}))
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
                                         'VERIFY_MUTATE': '1' if mutate else ''})
            if delta is not None:
                command.remove('--record-baseline')
                command[command.index('--output-dir') + 1] = str(base / 'comparison')
                command += ['--baseline', str(base / 'output/result.json')]
                result = subprocess.run(command, capture_output=True, text=True,
                                        env={**os.environ, 'VERIFY_DELTA': str(delta)})
                report = json.loads((base / 'comparison/result.json').read_text())
            else:
                report = json.loads((base / 'output/result.json').read_text())
            samples = [json.loads(path.read_text()) for path in sorted((base / 'output').glob('performance-*.json'))]
            return result, report, samples

    def test_success_is_compact_and_records_independent_samples(self):
        result, report, samples = self.verify(repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['status'], 'passed')
        self.assertLess(len(result.stdout), 1800)
        self.assertNotIn('fixture output', result.stdout)
        self.assertEqual([s['set_index'] for s in samples], ['1', '2', '3'])
        self.assertTrue(all(s['source_identity'] == report['source_identity'] for s in samples))
        self.assertEqual([p['name'] for p in report['phases']],
                         ['prepare', 'performance-1', 'performance-2', 'performance-3',
                          'functional', 'source-stability'])

    def test_regression_comparison_checks_the_previous_samples(self):
        for delta, code in ((0.5, 0), (3, 1)):
            with self.subTest(delta=delta):
                result, report, _ = self.verify(delta=delta)
                self.assertEqual(result.returncode, code, result.stderr)
                comparison = next(p for p in report['phases'] if p['name'] == 'performance-comparison')
                self.assertEqual(comparison['comparisons'][0]['delta_ms'], delta)

    def test_performance_failure_still_runs_functional_checks(self):
        result, report, _ = self.verify(fail='perf-evaluator')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report['phases'][1]['status'], 'failed')
        self.assertEqual(report['phases'][2]['status'], 'passed')

    def test_preparation_failure_is_not_a_performance_pass(self):
        result, report, samples = self.verify(fail='perf-prepare')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report['phases'][1]['status'], 'not-run')
        self.assertEqual(report['phases'][2]['status'], 'passed')
        self.assertEqual(samples, [])

    def test_functional_failure_and_source_changes_reject_the_run(self):
        for options in ({'fail': 'check'}, {'mutate': True}):
            with self.subTest(options=options):
                result, report, _ = self.verify(**options)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(report['status'], 'failed')


if __name__ == '__main__':
    unittest.main()
