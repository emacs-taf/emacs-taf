#!/usr/bin/env python3
"""Add one delivery unit to this checkout.

A package arrives as a directory under packages/ plus a bookmark pointing at
its own history, which is what a push later projects. The steps below are the
same whatever the number of packages already here.

The registry and the release selection are edited from the same facts; the
release selection still needs a person to say whether the package ships and
which resource directories it carries, so the tool reports what it left.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def change_graph(dry_run=False):
    """Return the jjosh binary; this checkout is not readable by plain jj."""
    from shutil import which
    for name in ('jjosh', 'jj'):
        if which(name):
            return name
    if dry_run:
        return 'jjosh'
    raise SystemExit('add-package: jjosh is not on PATH')


def run(argv, dry_run, capture=False):
    """Run one step, or print it when DRY-RUN asks for the plan."""
    printable = ' '.join(argv)
    if dry_run:
        print(f'would run: {printable}')
        return ''
    result = subprocess.run(argv, cwd=ROOT, capture_output=capture, text=True)
    if result.returncode:
        raise SystemExit(f'add-package: {printable} failed\n{(result.stderr or "").strip()}')
    return (result.stdout or '').strip()


def require_clean(binary, dry_run):
    """Refuse to import on top of unsealed work."""
    if dry_run:
        return
    status = subprocess.run([binary, 'diff', '--name-only'], cwd=ROOT,
                            capture_output=True, text=True)
    if status.returncode == 0 and status.stdout.strip():
        raise SystemExit('add-package: seal the working copy before adding a package')


def entry_text(name, url):
    """Return the root entry the registry records for NAME."""
    return (f';; {name}.el --- {name} package -*- lexical-binding: t; -*-\n\n'
            ';;; Commentary:\n\n;; Package metadata and public API records live here.\n\n'
            ';;; Code:\n\n(provide \'' + name + ')\n;;; ' + name + '.el ends here\n')


def register(name, url, branch, role, dry_run):
    """Add NAME to the registry, or record the entry the tool would write."""
    path = ROOT / 'workspace.json'
    document = json.loads(path.read_text(encoding='utf-8'))
    packages = document['packages']
    if name in packages:
        raise SystemExit(f'add-package: {name} is already registered')
    packages[name] = {'url': url, 'branch': branch, 'role': role}
    if dry_run:
        print(f'would register {name} in workspace.json as {role}')
        return
    path.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
    print(f'registered {name} in workspace.json as {role}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', help='package name, which becomes packages/NAME')
    parser.add_argument('--url', required=True, help='repository the package publishes to')
    parser.add_argument('--branch', default='main')
    parser.add_argument('--role', default='application',
                        choices=('framework', 'extension', 'application', 'game'))
    parser.add_argument('--dry-run', action='store_true', help='print the steps instead')
    args = parser.parse_args()

    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.name):
        raise SystemExit(f'add-package: {args.name} is not a package name')
    target = ROOT / 'packages' / args.name
    if target.exists():
        raise SystemExit(f'add-package: {target} already exists')

    binary = change_graph(dry_run=args.dry_run)
    require_clean(binary, args.dry_run)

    bookmark = f'{args.branch}#{args.name}@origin'
    run([binary, 'project', 'add', args.name, '--path', f'packages/{args.name}'], args.dry_run)
    run([binary, 'git', 'remote', 'add', 'origin', args.url,
         '--project', args.name, '--whole'], args.dry_run)
    run([binary, 'git', 'fetch', '--project', args.name, '--branch', args.branch], args.dry_run)
    run([binary, 'new', '@', bookmark], args.dry_run)
    register(args.name, args.url, args.branch, args.role, args.dry_run)

    root_entry = target / f'{args.name}.el'
    if not args.dry_run and not root_entry.exists():
        root_entry.write_text(entry_text(args.name, args.url), encoding='utf-8')
        print(f'wrote a root entry at {root_entry.relative_to(ROOT)}')

    recommended = []
    if not args.dry_run and target.is_dir():
        import importlib.util
        policy_path = ROOT / 'scripts' / 'check-repository.py'
        spec = importlib.util.spec_from_file_location('check_repository', policy_path)
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
        recommended = policy.suggest_release_resources(target)

    print()
    print(f'{args.name} is in the checkout. Still a person\'s decision:')
    print(f'  release-dependencies.json -- whether it ships; recommended resources: {json.dumps(recommended)}')
    print('    (runtime backends belong in backends/, offline manuals in docs/, showcase screenshots/videos in media/;')
    print('     tests/, benchmarks/, scripts/, media/, Makefile and native/vendor never ship;')
    print('     add examples/ only when public commands load pure-code examples at runtime)')
    print(f'  etaf-install.el -- add target, plus manual OS tools (if any) in etaf-install--system-tools')
    print(f'  its Package-Requires -- which providers it declares')
    print('Then run: make structure-check && make -C packages/' + args.name + ' check')


if __name__ == '__main__':
    main()
