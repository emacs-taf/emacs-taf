#!/usr/bin/env python3
"""Synchronize shared policy, check all repositories, or install local hooks."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHARED = ('AGENTS.md', '.editorconfig', 'scripts/check-repository.py', 'scripts/run-acceptance.py', '.githooks/pre-commit', '.githooks/commit-msg', 'scripts/check-commit-message.py',
          '.github/workflows/structure.yml')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['sync', 'check', 'setup-hooks', 'status'])
    args = parser.parse_args()
    repos = json.loads((ROOT / 'workspace.json').read_text())['repositories']
    failed = False
    for name, entry in repos.items():
        repo = ROOT / name
        if not (repo / '.git').exists():
            print(f'{name}: missing independent checkout ({entry["url"]})', file=sys.stderr)
            failed = True
            continue
        if args.action == 'sync':
            for rel in SHARED:
                target = repo / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, target)
        elif args.action == 'setup-hooks':
            # Never replace another hook configuration implicitly.
            old = subprocess.run(['git', '-C', str(repo), 'config', '--local', '--get',
                                  'core.hooksPath'], text=True, capture_output=True).stdout.strip()
            legacy = any((repo / '.git/hooks' / hook).exists() for hook in ('pre-commit', 'commit-msg'))
            if old not in ('', '.githooks') or (not old and legacy):
                print(f'{name}: existing hooks need manual integration', file=sys.stderr)
                failed = True
                continue
            subprocess.run(['git', '-C', str(repo), 'config', '--local', 'core.hooksPath', '.githooks'], check=True)
            print(f'{name}: structure and commit-message hooks enabled')
        elif args.action == 'status':
            actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
            print(f'{name}: {actual}' + (' (matches recorded revision)' if actual==entry['revision'] else ' (different from recorded revision)'))
        else:
            for rel in SHARED:
                if not (repo / rel).exists() or (repo / rel).read_bytes() != (ROOT / rel).read_bytes():
                    print(f'{name}/{rel}: shared policy drift; run workspace.py sync', file=sys.stderr)
                    failed = True
            if subprocess.run([sys.executable, str(ROOT / 'scripts/check-repository.py'), '--root', str(repo)]).returncode:
                failed = True
    if args.action == 'check':
        if subprocess.run([sys.executable, str(ROOT / 'scripts/check-repository.py')]).returncode:failed=True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
