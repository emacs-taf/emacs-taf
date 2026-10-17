#!/usr/bin/env python3
"""Synchronize, check and seal shared tooling, report revisions, or install hooks."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHARED = ('scripts/check-api.py', 'scripts/check-api.el', 'scripts/api-workspace.json', '.editorconfig', 'scripts/check-repository.py', 'scripts/run-acceptance.py', '.githooks/pre-commit', '.githooks/commit-msg', 'scripts/check-commit-message.py',
          '.github/workflows/structure.yml', 'scripts/package_archive.py')
SEAL_TITLE = 'chore(scripts): sync shared workspace tooling'


def jj(repo, *args):
    """Run jj in REPO and return its output; paths print relative to REPO."""
    return subprocess.run(['jj', *args], cwd=repo, text=True, capture_output=True, check=True).stdout


def changed_shared(repo):
    """Return the shared paths that the working-copy commit of REPO changes."""
    names = set(jj(repo, 'diff', '-r', '@', '--name-only').split())
    return [rel for rel in SHARED if rel in names]


def seal(repos, remote, dry_run):
    """Commit the synchronized shared copies of every child, and nothing else.

    A refusal of the preconditions leaves all repositories untouched.  Each
    sealed commit is structure-checked as committed (the colocated Git index
    mirrors @-), so another session's work in progress neither fails nor
    passes it; a commit that fails is reverted and reported."""
    if not (ROOT / '.jj').exists() or any(not (ROOT / name / '.jj').exists() for name in repos):
        print('seal-sync needs jj checkouts of the root and every repository', file=sys.stderr)
        return 1
    pending = changed_shared(ROOT)
    if pending:
        print('commit the root tooling first; uncommitted: ' + ', '.join(pending), file=sys.stderr)
        return 1
    failed = False
    for name in repos:
        for rel in SHARED:
            if not (ROOT / name / rel).exists() or (ROOT / name / rel).read_bytes() != (ROOT / rel).read_bytes():
                print(f'{name}/{rel}: shared tooling drift; run workspace.py sync', file=sys.stderr)
                failed = True
    if failed:
        print('nothing sealed', file=sys.stderr)
        return 1
    paths = ' | '.join(f'"{rel}"' for rel in SHARED)
    source = jj(ROOT, 'log', '--no-graph', '-r', f'latest(::@- & files({paths}))',
                '-T', 'commit_id.short() ++ " " ++ description.first_line()').strip()
    for name, entry in repos.items():
        repo = ROOT / name
        rels = changed_shared(repo)
        if not rels:
            print(f'{name}: shared tooling already sealed')
        elif dry_run:
            print(f'{name}: would seal ' + ', '.join(rels))
        else:
            message = (f'{SEAL_TITLE}\n\nCopy the shared tooling maintained in the workspace root, as of\n'
                       f'{source}:\n\n' + ''.join(f'- {rel}\n' for rel in rels) +
                       '\nValidation: workspace.py seal-sync found each copy identical to the\n'
                       'committed root tooling and kept this commit only after\n'
                       'check-repository.py --staged passed on it.\n')
            working = jj(repo, 'log', '--no-graph', '-r', '@', '-T', 'commit_id').strip()
            jj(repo, 'commit', *rels, '-m', message)
            sealed = jj(repo, 'log', '--no-graph', '-r', '@-', '-T', 'commit_id.short()').strip()
            check = subprocess.run([sys.executable, str(ROOT / 'scripts/check-repository.py'),
                                    '--root', str(repo), '--staged'], text=True, capture_output=True)
            if check.returncode == 0:
                print(f'{name}: sealed {sealed} ({len(rels)} file{"s" if len(rels) > 1 else ""})')
            else:
                failed = True
                print(f'{name}: sealed commit {sealed} fails the structure check:', file=sys.stderr)
                print(check.stdout + check.stderr, end='', file=sys.stderr)
                ops = jj(repo, 'op', 'log', '--no-graph', '-n', '10', '-T', 'id ++ " " ++ description ++ "\\n"')
                op = next((line.split()[0] for line in ops.splitlines() if line.endswith(f' commit {working}')), None)
                if op:
                    jj(repo, 'op', 'revert', op)
                    print(f'{name}: reverted the seal; the copies stay uncommitted', file=sys.stderr)
                else:
                    print(f'{name}: could not find the seal operation; inspect jj op log', file=sys.stderr)
                continue
        # Publishing @- would also publish every other commit in this range.
        branch = entry.get('branch', 'main')
        try:
            unpublished = jj(repo, 'log', '--no-graph', '-r', f'{branch}@{remote}..@-',
                             '-T', 'commit_id.short() ++ " " ++ description.first_line() ++ "\n"')
        except subprocess.CalledProcessError:
            print(f'{name}: no {branch}@{remote} bookmark; publish it as a new repository')
            continue
        others = [line for line in unpublished.splitlines() if line.split(' ', 1)[-1] != SEAL_TITLE]
        if others:
            print(f'{name}: publishing @- also publishes other unpublished work:')
            print(''.join(f'  {line}\n' for line in others), end='')
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['sync', 'check', 'seal-sync', 'setup-hooks', 'status'])
    parser.add_argument('--remote', default='aliyun',
                        help='seal-sync: remote whose branch bounds the publish range (default aliyun)')
    parser.add_argument('--dry-run', action='store_true',
                        help='seal-sync: report what would be sealed without committing')
    args = parser.parse_args()
    repos = json.loads((ROOT / 'workspace.json').read_text())['repositories']
    if args.action == 'seal-sync':
        return seal(repos, args.remote, args.dry_run)
    api_registry = {}
    for name, entry in repos.items():
        entries = list((ROOT/name).glob('*.el'))
        if len(entries) == 1:
            api_registry[name] = {'entry': entries[0].stem, 'url': entry['url']}
    registry_path = ROOT/'scripts/api-workspace.json'
    if args.action == 'sync' and len(api_registry) == len(repos):
        registry_path.write_text(json.dumps(api_registry, indent=2, sort_keys=True) + '\n')
    failed = False
    if args.action == 'check' and json.loads(registry_path.read_text()) != api_registry:
        print('API provider registry drift; run workspace.py sync', file=sys.stderr)
        failed = True
    for name, entry in repos.items():
        repo = ROOT / name
        # A secondary `jj workspace add` checkout has only jj metadata.
        if not ((repo / '.git').exists() or (repo / '.jj').exists()):
            print(f'{name}: missing independent checkout ({entry["url"]})', file=sys.stderr)
            failed = True
            continue
        if args.action == 'sync':
            for rel in SHARED:
                target = repo / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, target)
        elif args.action == 'setup-hooks' and not (repo / '.git').exists():
            print(f'{name}: jj workspace without Git hooks; run the publishing checks')
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
            # jj 协作：HEAD 会指向 jj 的工作副本提交（detached），
            # "在哪个版本上"看的是分支引用；旧行为在分支上提交时与 HEAD 等价。
            branch = entry.get('branch', 'main')
            if not (repo / '.git').exists():
                actual = subprocess.check_output(
                    ['jj', '-R', str(repo), 'log', '--no-graph', '-r', branch, '-T', 'commit_id'],
                    text=True).strip()
            else:
                try:
                    actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', f'refs/heads/{branch}'], text=True).strip()
                except subprocess.CalledProcessError:
                    actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
            line = f'{name}: {actual}' + (' (matches recorded revision)' if actual==entry['revision'] else ' (different from recorded revision)')
            if (repo / '.jj').exists() and shutil.which('jj'):
                try:
                    change = subprocess.check_output(
                        ['jj', '-R', str(repo), 'log', '--no-graph', '-r', '@',
                         '-T', 'change_id.short() ++ " " ++ commit_id.short()'],
                        text=True, stderr=subprocess.DEVNULL).strip()
                    line += f' [jj @ {change}]'
                except subprocess.CalledProcessError:
                    pass
            print(line)
        else:
            for rel in SHARED:
                if not (repo / rel).exists() or (repo / rel).read_bytes() != (ROOT / rel).read_bytes():
                    print(f'{name}/{rel}: shared tooling drift; run workspace.py sync', file=sys.stderr)
                    failed = True
            if subprocess.run([sys.executable, str(ROOT / 'scripts/check-repository.py'), '--root', str(repo)]).returncode:
                failed = True
    if args.action == 'check':
        if subprocess.run([sys.executable, str(ROOT / 'scripts/check-repository.py')]).returncode:failed=True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
