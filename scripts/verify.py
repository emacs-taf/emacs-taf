#!/usr/bin/env python3
"""Run workspace batch checks with compact output and saved comparison evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def snapshot(root):
    names = ['.'] + list(json.loads((root / 'workspace.json').read_text())['repositories'])
    result = {}
    for name in names:
        repo = root / name
        def git(*args):
            return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL)
        if not (repo / '.git').exists() and (repo / '.jj').is_dir():
            # An index-less jj workspace: @- is the colocated Git HEAD view.
            def jj(*args):
                return subprocess.check_output(['jj', '--no-pager', *args], cwd=repo,
                                               stderr=subprocess.DEVNULL)
            result[name] = {'revision': jj('log', '--no-graph', '-r', '@-', '-T', 'commit_id').decode().strip(),
                            'status': jj('diff', '-r', '@', '--summary').decode(),
                            'change_digest': hashlib.sha256(jj('diff', '-r', '@', '--git')).hexdigest()}
            continue
        status = git('status', '--porcelain', '--untracked-files=all').decode()
        digest = hashlib.sha256(git('diff', '--binary', 'HEAD'))
        for relative in git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'):
            if relative:
                path = repo / os.fsdecode(relative)
                digest.update(relative)
                digest.update(os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes())
        result[name] = {'revision': git('rev-parse', 'HEAD').decode().strip(),
                        'status': status, 'change_digest': digest.hexdigest()}
    return result


def compare_performance(output, baseline, count, allowance):
    "Compare matching recorded workloads; missing evidence is a failure."
    previous = json.loads(baseline.read_text())
    rows = []
    for index in range(1, count + 1):
        old = json.loads((baseline.parent / f'performance-{index}.json').read_text())
        new = json.loads((output / f'performance-{index}.json').read_text())
        for key in ('warmups', 'machine_id', 'evaluator_identity'):
            if old.get(key) != new.get(key) or old.get(key) is None:
                raise ValueError(f'baseline workload differs: {key}')
        if not old.get('scenarios') or old['scenarios'].keys() != new.get('scenarios', {}).keys():
            raise ValueError('baseline scenario coverage differs or is empty')
        for name, target in new['scenarios'].items():
            base = old['scenarios'][name]
            if len(base['samples_ms']) != 30 or len(target['samples_ms']) != 30:
                raise ValueError(f'incomplete samples: {name}')
            base_samples = sorted(base['samples_ms'])
            target_samples = sorted(target['samples_ms'])
            for metric, position in (('p95_ms', 28), ('max_ms', 29)):
                baseline_value, current_value = base_samples[position], target_samples[position]
                delta = current_value - baseline_value
                rows.append({'set': index, 'scenario': name, 'metric': metric,
                             'baseline_ms': baseline_value, 'current_ms': current_value,
                             'delta_ms': delta, 'regressed': delta > allowance})
    return {'baseline': str(baseline), 'baseline_source_identity': previous['source_identity'],
            'allowance_ms': allowance, 'comparisons': rows,
            'status': 'failed' if any(row['regressed'] for row in rows) else 'passed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--emacs', default='emacs')
    parser.add_argument('--make', default='make')
    baseline = parser.add_mutually_exclusive_group(required=True)
    baseline.add_argument('--baseline', type=Path, help='Previous result.json for regression comparison.')
    baseline.add_argument('--record-baseline', action='store_true', help='Record the initial baseline without claiming no regression.')
    parser.add_argument('--regression-allowance-ms', type=float, default=2.0)
    parser.add_argument('--repeatability', action='store_true',
                        help='Run three independent full performance sets instead of one.')
    args = parser.parse_args()
    if args.regression_allowance_ms < 0 or not args.regression_allowance_ms < float('inf'):
        parser.error('--regression-allowance-ms must be finite and nonnegative')
    root = args.root.resolve()
    output = args.output_dir.resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix='etaf-verify-'))
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('--output-dir must be empty; existing evidence is never overwritten')
    try:
        source = snapshot(root)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        parser.error(f'cannot record workspace sources: {error}')
    source_id = hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest()
    report = {'schema': 1, 'started_at': datetime.now(timezone.utc).isoformat(),
              'kind': 'workspace-baseline' if args.record_baseline else 'workspace-batch-verification', 'root': str(root),
              'platform': platform.platform(), 'emacs': args.emacs,
              'coverage': ['batch correctness', 'Research Shelf batch latency'],
              'not_certified': ['GUI rendering and input', 'GUI latency', 'installation compatibility'],
              'source_identity': source_id, 'sources': source,
              'performance_sets': 3 if args.repeatability else 1,
              'phases': [], 'status': 'running'}
    report_path = output / 'result.json'

    def save():
        pending = output / 'result.json.tmp'
        pending.write_text(json.dumps(report, indent=2) + '\n')
        pending.replace(report_path)

    def run(name, command, environment=None):
        log = output / (name + '.log')
        phase = {'name': name, 'command': command, 'log': str(log), 'status': 'running'}
        report['phases'].append(phase)
        save()
        print(f'RUN {name}', flush=True)
        started = time.monotonic()
        with log.open('w') as stream:
            try:
                completed = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT,
                                           env={**os.environ, **(environment or {})})
                phase['exit_code'] = completed.returncode
            except OSError as error:
                stream.write(str(error) + '\n')
                phase['exit_code'] = 127
        phase['seconds'] = round(time.monotonic() - started, 3)
        phase['status'] = 'passed' if phase['exit_code'] == 0 else 'failed'
        save()
        print(f'{phase["status"].upper()} {name} ({phase["seconds"]:.1f}s) {log}', flush=True)
        return phase['exit_code'] == 0

    make = [args.make, f'EMACS={args.emacs}']
    prepared = run('prepare', make + ['-C', 'etaf-playground', 'perf-prepare'])
    if prepared:
        report['native_modules'] = {
            str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (root / 'ebox/native/target').glob('*/release/libebox_native_reflow.*')
            if path.is_file() and path.suffix in ('.so', '.dylib', '.dll')}
        evaluator = root / 'etaf-playground/benchmarks/benchmark-research-shelf.el'
        evaluator_id = hashlib.sha256(evaluator.read_bytes()).hexdigest()
        for index in range(1, report['performance_sets'] + 1):
            run(f'performance-{index}', make + ['-C', 'etaf-playground', 'perf-evaluator'],
                {'INCREMENTAL_PERF_MANIFEST': str(output / f'performance-{index}.json'),
                 'INCREMENTAL_SET_INDEX': str(index),
                 'INCREMENTAL_SOURCE_IDENTITY': source_id,
                 'INCREMENTAL_EVALUATOR_IDENTITY': evaluator_id})
    else:
        report['phases'].append({'name': 'performance', 'status': 'not-run',
                                 'reason': 'preparation failed'})
    if args.baseline:
        try:
            comparison = compare_performance(output, args.baseline.resolve(),
                                             report['performance_sets'], args.regression_allowance_ms)
        except (OSError, ValueError, KeyError, TypeError) as error:
            comparison = {'status': 'failed', 'reason': str(error)}
        comparison['name'] = 'performance-comparison'
        report['phases'].append(comparison)
        save()
        print(f'{comparison["status"].upper()} performance-comparison', flush=True)
    # A performance failure must not hide the independent correctness result.
    run('functional', make + ['check'])
    try:
        stable = snapshot(root) == source
    except (OSError, subprocess.CalledProcessError, ValueError):
        stable = False
    report['phases'].append({'name': 'source-stability', 'status': 'passed' if stable else 'failed'})
    passed = all(phase['status'] == 'passed' for phase in report['phases'])
    report['status'] = 'passed' if passed else 'failed'
    report['finished_at'] = datetime.now(timezone.utc).isoformat()
    save()
    print(f'{report["status"].upper()} result {report_path}', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
