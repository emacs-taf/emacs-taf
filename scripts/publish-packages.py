#!/usr/bin/env python3
"""Publish every package to every remote that carries it.

A push projects one package out of the shared tree, which rewrites the commit it
sends: the same source hashes differently in each package's remote, so a package
cannot be compared against what its remote serves to decide whether it moved.
Pushing an unchanged package is a no-op that costs one request, which is cheaper
than a wrong skip.

The packages are pushed one after another on purpose.  Moving a bookmark is a
write to this checkout's operation log, and two writers race it: jjosh reports
one repository loaded at an operation that is a sibling of the working copy's,
and pushes then fail on stale credentials and stale leases.

The two HTTPS remotes read their credentials from this checkout's
`scripts/askpass.sh`, which answers git's prompt from the stores this machine
already has: forgejo's token in git's credential helper, GitHub's from `gh`.
`laycat` is SSH and needs a key.  Set `ETAF_ASKPASS` to use another script.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REMOTES = ("aliyun", "laycat", "origin")


def graph(*arguments, timeout=240):
    """Run jjosh and return its result; this checkout is not readable by plain jj."""
    return subprocess.run(list(arguments), cwd=ROOT, capture_output=True,
                          text=True, timeout=timeout)


def bookmark_state():
    """Return {package: {remote: commit id}} for the bookmarks this checkout holds.

    jjosh prints one line per bookmark, and a name carrying the package suffix
    separates the remote from the package: `main#etaf-ui@laycat: id`.
    """
    listing = graph("jjosh", "bookmark", "list", "--all").stdout
    state = {}
    for line in listing.splitlines():
        name, _, remainder = line.partition(":")
        name = name.strip()
        if not name.startswith("main#"):
            continue
        package, _, remote = name.removeprefix("main#").partition("@")
        commit = remainder.split()[0] if remainder.split() else ""
        if package and commit:
            state.setdefault(package, {})[remote or "local"] = commit
    return state


def publish(package, remotes, environment):
    """Push PACKAGE to REMOTES; return (package, [(remote, error)])."""
    failures = []
    for remote in remotes:
        moved = subprocess.run(['jjosh', 'bookmark', 'set', f'main#{package}',
                                '-r', '@-', '--allow-backwards'],
                               cwd=ROOT, capture_output=True, text=True, timeout=180,
                               env=environment)
        if moved.returncode:
            failures.append((remote, (moved.stderr or '').strip()[:200]))
            break
        pushed = subprocess.run(['jjosh', 'git', 'push', '--remote', f'{remote}#{package}',
                                 '--bookmark', f'main#{package}'],
                                cwd=ROOT, capture_output=True, text=True, timeout=600,
                                env=environment)
        if pushed.returncode:
            failures.append((remote, ((pushed.stderr or '') + (pushed.stdout or '')).strip()[-220:]))
    return package, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remote', action='append', choices=DEFAULT_REMOTES,
                        help='remote to publish to; repeatable, default all three')
    parser.add_argument('--package', action='append', default=[],
                        help='publish only this package; repeatable')
    parser.add_argument('--dry-run', action='store_true',
                        help='report what would be pushed')
    args = parser.parse_args()

    remotes = tuple(args.remote or DEFAULT_REMOTES)
    state = bookmark_state()
    selected = sorted(args.package or state)
    unknown = [name for name in selected if name not in state]
    if unknown:
        raise SystemExit(f'publish-packages: unknown package {", ".join(unknown)}')
    for package in selected:
        print(f'{"would push" if args.dry_run else "push"} {package} to '
              f'{", ".join(remotes)}')
    if args.dry_run:
        return 0

    environment = dict(os.environ)
    environment.setdefault('GIT_ASKPASS',
                             os.environ.get('ETAF_ASKPASS',
                                            str(ROOT / 'scripts' / 'askpass.sh')))
    failures = []
    for package in selected:
        _, problems = publish(package, remotes, environment)
        if problems:
            failures.extend((package, remote, note) for remote, note in problems)
            print(f'FAIL {package}', flush=True)
        else:
            print(f'ok {package}', flush=True)

    print()
    print(f'published {len(selected) - len({item[0] for item in failures})} of '
          f'{len(selected)} package(s); {len(failures)} failure(s)')
    for package, remote, note in failures:
        print(f'FAIL {package} {remote}: {note}')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
