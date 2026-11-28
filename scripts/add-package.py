#!/usr/bin/env python3
"""Add one package directory to the Emacs TAF monorepo.

Places framework/extension packages under `core/packages/<name>`,
applications under `apps/<name>`, and games under `games/<name>`, then
registers the package in `workspace.json`.
"""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import workspace_layout

ROLE_CONTAINER = {
    'framework': 'core/packages',
    'extension': 'core/packages',
    'application': 'apps',
    'game': 'games',
}


def relpath_for(name, role):
    """Return the repo-relative directory path for NAME with ROLE."""
    return f'{ROLE_CONTAINER[role]}/{name}'


def entry_text(name):
    """Return a minimal root entry skeleton for NAME."""
    return (f';;; {name}.el --- {name} package -*- lexical-binding: t; -*-\n\n'
            ';;; Commentary:\n\n;; Package metadata and public API records live here.\n\n'
            ';;; Code:\n\n(provide \'' + name + ')\n;;; ' + name + '.el ends here\n')


def register(name, url, branch, role, dry_run, repo=None):
    """Add NAME to workspace.json, or report what would be written."""
    path = ROOT / 'workspace.json'
    document = json.loads(path.read_text(encoding='utf-8'))
    packages = document['packages']
    if name in packages:
        raise SystemExit(f'add-package: {name} is already registered')
    rel = relpath_for(name, role)
    entry = {'path': rel, 'role': role, 'branch': branch}
    if role in ('framework', 'extension'):
        entry['projection'] = 'etaf'
        entry['url'] = url or 'https://github.com/emacs-taf/etaf.git'
    else:
        if repo:
            entry['repo'] = repo
        entry['url'] = url or (f'https://github.com/{repo}.git' if repo
                               else 'https://github.com/emacs-taf/emacs-taf.git')
    packages[name] = entry
    if dry_run:
        print(f'would register {name} at {rel} in workspace.json as {role}')
        return
    document['packages'] = dict(sorted(packages.items()))
    path.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
    print(f'registered {name} at {rel} in workspace.json as {role}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', help='package name (placed by --role under core/packages, apps or games)')
    parser.add_argument('--url', default='', help='repository URL (optional; defaults from role/repo)')
    parser.add_argument('--repo', default='', help='GitHub projection slug owner/name for standalone apps/games')
    parser.add_argument('--branch', default='main')
    parser.add_argument('--role', default='application',
                        choices=('framework', 'extension', 'application', 'game'))
    parser.add_argument('--dry-run', action='store_true', help='print the steps instead')
    args = parser.parse_args()

    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.name):
        raise SystemExit(f'add-package: {args.name} is not a package name')
    existing = workspace_layout.package_dirs(ROOT)
    if args.name in existing:
        raise SystemExit(f'add-package: {existing[args.name]} already exists')

    rel = relpath_for(args.name, args.role)
    target = ROOT / rel
    if target.exists():
        raise SystemExit(f'add-package: {target} already exists')

    if args.dry_run:
        print(f'would create {rel}/')
    else:
        target.mkdir(parents=True, exist_ok=False)
        root_entry = target / f'{args.name}.el'
        root_entry.write_text(entry_text(args.name), encoding='utf-8')
        print(f'wrote a root entry at {rel}/{args.name}.el')

    register(args.name, args.url, args.branch, args.role, args.dry_run, repo=args.repo or None)

    recommended = []
    if not args.dry_run and target.is_dir():
        import importlib.util
        policy_path = ROOT / 'scripts' / 'check-repository.py'
        spec = importlib.util.spec_from_file_location('check_repository', policy_path)
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
        recommended = policy.suggest_release_resources(target)

    print()
    print(f'{args.name} is in the checkout ({rel}). Still a person\'s decision:')
    print(f'  release-dependencies.json -- whether it ships; recommended resources: {json.dumps(recommended)}')
    print('  core/packages/etaf-install/lisp/etaf-install-catalog.el -- offline fallback target and System CLI tools')
    print('  its Package-Requires -- which providers it declares')
    print(f'Then run: make structure-check && make -C {rel} check')


if __name__ == '__main__':
    main()
