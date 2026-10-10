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
    sets = 3 if args.repeatability else 1
    if args.baseline and not args.repeatability:
        try:
            prior = json.loads(args.baseline.read_text())
            if (isinstance(prior, dict) and prior.get('schema') == 2
                    and prior.get('performance_sets') in (1, 3)):
                sets = prior['performance_sets']
        except (OSError, ValueError, TypeError):
            pass  # The independent comparison phase reports unusable baselines.
    report = {'schema': 2, 'started_at': datetime.now(timezone.utc).isoformat(),
              'kind': 'workspace-baseline' if args.record_baseline else 'workspace-batch-verification', 'root': str(root),
              'platform': platform.platform(), 'emacs': args.emacs,
              'coverage': ['batch correctness', 'registered Playground batch latency'],
              'not_certified': ['GUI rendering and input', 'GUI latency', 'installation compatibility'],
              'source_identity': source_id, 'sources': source,
              'performance_sets': sets,
              'performance_report': 'performance/result.json',
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
        return phase

    make = [args.make, f'EMACS={args.emacs}']
    prepared = run('prepare', make + ['compile'])
    driver = [sys.executable, str(root / 'scripts/performance.py')]
    performance_path = output / report['performance_report']
    if prepared['status'] == 'passed':
        phase = run('performance', driver + [
            'run', '--root', str(root), '--emacs', args.emacs, '--mode', 'batch',
            '--scenario', 'etaf-playground.*', '--sets', str(report['performance_sets']),
            '--samples', '30', '--warmups', '5', '--output-dir', str(performance_path.parent)])
        try:
            performance = json.loads(performance_path.read_text())
            if (not isinstance(performance, dict)
                    or performance.get('schema') != 1 or performance.get('valid') is not True
                    or not performance.get('cases')
                    or performance.get('status') not in ('passed', 'screened')):
                raise ValueError('performance driver did not produce valid passing evidence')
            if phase['status'] == 'passed':
                phase['status'] = performance['status']
            phase['report'] = str(performance_path)
            report['acceptance_eligible'] = performance.get('acceptance_eligible', False)
        except (OSError, ValueError, TypeError) as error:
            phase.update(status='failed', reason=str(error))
        save()
    else:
        report['phases'].append({'name': 'performance', 'status': 'not-run',
                                 'reason': 'preparation failed'})
    if args.baseline:
        try:
            previous_path = args.baseline.resolve()
            previous = json.loads(previous_path.read_text())
            if (not isinstance(previous, dict) or previous.get('schema') != 2
                    or previous.get('status') not in ('passed', 'screened')):
                raise ValueError('baseline is not a successful current-driver workspace run')
            comparison = run('performance-comparison', driver + [
                'compare', str(previous_path.parent / 'performance/result.json'),
                str(performance_path), '--allowance-ms', str(args.regression_allowance_ms)])
        except (OSError, ValueError, KeyError, TypeError) as error:
            comparison = {'name': 'performance-comparison', 'status': 'failed', 'reason': str(error)}
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
    if not stable:
        print('UNVERIFIED: Workspace sources changed during measurement', flush=True)
    passed = all(phase['status'] in ('passed', 'screened') for phase in report['phases'])
    report['status'] = ('failed' if not passed else
                        'passed' if report.get('acceptance_eligible') else 'screened')
    report['finished_at'] = datetime.now(timezone.utc).isoformat()
    save()
    print(f'{report["status"].upper()} result {report_path}', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
