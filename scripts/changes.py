#!/usr/bin/env python3
"""Seal one cross-repository change, then publish the sealed checkpoints.

A workspace change usually touches a provider and its consumers, but the order
is not a convention: a package entry declares its providers in
`Package-Requires`, so a provider is sealed before its consumers and the
workspace root last, because its `workspace.json` records the revisions that
were published.  One message file serves the whole change: the tool adds each
repository's scope, the `Repo:` marker and the checks it actually ran, and it
seals nothing until every affected repository passed its own checks.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
# The shared tooling list has one authority: workspace.py distributes those files.
import workspace  # noqa: E402

ROOT_NAME = 'workspace'
REMOTES = ('aliyun', 'origin')
# The message file states the change itself; the tool adds what only it knows.
TITLE = re.compile(r'(feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(!?): (\S.*)')
SCOPED = re.compile(r'[a-z]+(?:\([^)]*\))?!?: .*')
DEPENDENCIES = re.compile(r'^;; Package-Requires: (.+)$', re.M)
REQUIREMENT = re.compile(r'\(([a-z][a-z0-9-]*) "[0-9]+(?:\.[0-9]+)*"\)')
TEST_FILE = re.compile(r'^test_.*\.py$')
WIDTH = 76


class Failure(Exception):
    """A precondition or an executed check rejected the change."""


def tail(result, size=4000):
    """Return the end of a failed command's output, where the cause is."""
    return (result.stdout + result.stderr).strip()[-size:]


def jj(repo, *args, check=True):
    result = subprocess.run(['jj', *args], cwd=repo, text=True, capture_output=True)
    if check and result.returncode:
        raise Failure(f'jj {" ".join(args)} failed in {repo.name}:\n{tail(result)}')
    return result


def registry():
    return json.loads((ROOT / 'workspace.json').read_text())


def repositories():
    return registry()['repositories']


def selected(repos, values):
    """Return the checkouts `--only` limits a run to, or None for all of them."""
    if not values:
        return None
    names = {name.strip() for value in values for name in value.split(',') if name.strip()}
    unknown = sorted(names - set(repos) - {ROOT_NAME})
    if unknown:
        raise Failure('unknown checkout: ' + ', '.join(unknown))
    return names


def directory(name):
    return ROOT if name == ROOT_NAME else ROOT / name


def branch_of(name, repos):
    return 'main' if name == ROOT_NAME else repos[name].get('branch', 'main')


def changed(name):
    """Return the working-copy paths that sealing NAME would commit."""
    return jj(directory(name), 'diff', '-r', '@', '--name-only').stdout.split()


def shared_copies(name, repos):
    """Return NAME's unsealed paths that are copies of the shared tooling.

    Those files belong to `workspace.py seal-sync`, which records them as such
    and names the unpublished work around them.  Folding a synced copy into a
    feature commit would publish it under a message that does not describe it.
    """
    if name == ROOT_NAME:
        return []
    tooling = set(workspace.shared_files(repos.get(name, {})))
    return [path for path in changed(name) if path in tooling]


def revision(name, rev):
    """Return the commit REV names in NAME's checkout, or None when it is absent."""
    result = jj(directory(name), 'log', '--no-graph', '-r', rev, '-T', 'commit_id', check=False)
    if result.returncode:
        return None
    return result.stdout.strip() or None


def commits(name, revset):
    """Return (short id, title) pairs in REVSET, newest first; empty when absent."""
    result = jj(directory(name), 'log', '--no-graph', '-r', revset,
                '-T', 'commit_id.short() ++ " " ++ description.first_line() ++ "\\n"',
                check=False)
    if result.returncode:
        return []
    found = []
    for line in result.stdout.splitlines():
        commit_id, _, title = line.partition(' ')
        if commit_id:
            found.append((commit_id, title))
    return found


def declared_providers(name, known):
    """Return the workspace packages NAME's entry requires, in declaration order.

    The entry is the authority for ordering a change: a consumer cannot be
    sealed before the provider whose interface it now uses.
    """
    entry = ROOT / name / f'{name}.el'
    if not entry.is_file():
        raise Failure(f'{name}: no package entry {entry.name}; cannot order the change')
    declared = DEPENDENCIES.search(entry.read_text())
    if not declared:
        raise Failure(f'{name}: {entry.name} declares no Package-Requires; cannot order the change')
    return [package for package in REQUIREMENT.findall(declared[1]) if package in known]


def providers(name, names, strict=True):
    """Return what must happen before NAME: its providers, or every checkout for the root."""
    if name == ROOT_NAME:
        return [other for other in names if other != name]
    try:
        return declared_providers(name, set(names))
    except Failure:
        if strict:
            raise
        return []


def sealed_order(names, priority, strict=True):
    """Return NAMES with every provider before its consumers.

    PRIORITY is the registry order and settles ties, so the same change always
    seals and publishes the same way.
    """
    wanted = set(names)
    edges = {name: providers(name, wanted, strict) for name in names}
    order, done, remaining = [], set(), [name for name in priority if name in wanted]
    while remaining:
        ready = next((name for name in remaining if set(edges[name]) <= done), None)
        if ready is None:
            raise Failure('dependency cycle among: ' + ', '.join(remaining))
        order.append(ready)
        done.add(ready)
        remaining.remove(ready)
    return order


@dataclass
class Message:
    """The one message file, before each repository's details are added."""
    kind: str
    bang: str
    summary: str
    body: str


def read_message(path):
    """Read the shared message: a title without a scope, then the body."""
    lines = [line.rstrip() for line in Path(path).read_text().splitlines()]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    if not lines:
        raise Failure(f'{path}: the message is empty')
    header = TITLE.fullmatch(lines[0])
    if not header:
        if SCOPED.fullmatch(lines[0]):
            raise Failure(f'{path}: drop the scope from the title; changes.py adds the name '
                          'of the repository it seals to every commit')
        raise Failure(f'{path}: the title must be "type: summary", for example '
                      '"feat: add the changes tool"')
    body = lines[1:]
    if not body or body[0] != '':
        raise Failure(f'{path}: separate the title and the body with a blank line')
    if not '\n'.join(body).strip():
        raise Failure(f'{path}: explain the problem and the resulting behavior in the body')
    for line in body:
        if line.startswith(('Repo:', 'Validation:')):
            raise Failure(f'{path}: changes.py writes the Repo: and Validation: lines; '
                          f'remove this one: {line}')
    return Message(header[1], header[2], header[3], '\n'.join(body).strip())


def render(message, name, checks):
    """Return the commit message NAME receives, with its scope and evidence."""
    evidence = textwrap.fill('; '.join(checks) + ' passed on the working copy before sealing; '
                             'scripts/check-commit-message.py accepted this message.',
                             WIDTH, subsequent_indent='  ')
    return (f'{message.kind}({name}){message.bang}: {message.summary}\n\n'
            f'{message.body}\n\nRepo: {name}\nValidation: {evidence}\n')


def checked_message(text):
    """Refuse a message the project's own contract rejects."""
    with tempfile.NamedTemporaryFile('w', suffix='.msg', delete=False) as handle:
        handle.write(text)
        path = handle.name
    try:
        result = subprocess.run(
            [sys.executable, str(ROOT / 'scripts/check-commit-message.py'), path],
            cwd=ROOT, text=True, capture_output=True)
    finally:
        Path(path).unlink(missing_ok=True)
    if result.returncode:
        raise Failure(f'{tail(result)}\n\nrefused message:\n{text}')
    return text


def execute(name, label, argv, cwd=ROOT):
    """Run one gate, keeping only the evidence a commit message cites."""
    print(f'{name}: {label} ...', end=' ', flush=True)
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        print('FAILED')
        raise Failure(f'{name}: {label} failed\n{tail(result)}')
    print('ok', flush=True)
    ran = re.search(r'^Ran (\d+) tests?', result.stdout + result.stderr, re.M)
    return f'{label} ({ran[1]} tests)' if ran else label


def tool_tests(name):
    """Return (label, argv) for the repository's own tool tests, when it keeps any."""
    tests = directory(name) / 'tests/tools'
    if not tests.is_dir() or not any(TEST_FILE.fullmatch(path.name) for path in tests.iterdir()):
        return None
    return ('python3 -m unittest discover -s tests/tools -p test_*.py',
            [sys.executable, '-m', 'unittest', 'discover', '-s', 'tests/tools', '-p', 'test_*.py'])


def planned_checks(name, full):
    """Return the labels of the gates sealing NAME would run."""
    if full and name != ROOT_NAME:
        return [f'make -C {name} check']
    labels = [f'make -C {name} structure-check' if name != ROOT_NAME
              else 'python3 scripts/check-repository.py']
    tests = tool_tests(name)
    return labels + ([tests[0]] if tests else [])


def run_checks(name, full):
    """Run the gates a changed repository must pass before it is sealed.

    A repository is checked by its own gate: the root checks the root
    repository, a package checks itself through its Makefile.  `--full` runs
    each package's whole `check` target, which is the pre-release run.
    """
    if full and name != ROOT_NAME:
        return [execute(name, f'make -C {name} check', ['make', '-C', name, 'check'])]
    if name == ROOT_NAME:
        checks = [execute(name, 'python3 scripts/check-repository.py',
                          [sys.executable, 'scripts/check-repository.py'])]
    else:
        checks = [execute(name, f'make -C {name} structure-check',
                          ['make', '-C', name, 'structure-check'])]
    tests = tool_tests(name)
    if tests:
        checks.append(execute(name, tests[0], tests[1], cwd=directory(name)))
    return checks


def seals(name, message, checks, paths=None):
    """Seal NAME's working-copy changes and return the sealed commit.

    Without PATHS every working-copy change is sealed, because the working copy
    is the change set: sealing by path would split a rename, whose old name is
    absent from the diff, off into the next commit.  The workspace root's
    pin-only commit names the one path it records.
    """
    if paths is not None and not paths:
        return None
    before = revision(name, '@-')
    text = checked_message(render(message, name, checks))
    if paths is None:
        jj(directory(name), 'commit', '-m', text)
    else:
        jj(directory(name), 'commit', *paths, '-m', text)
    sealed = revision(name, '@-')
    if sealed == before:
        raise Failure(f'{name}: jj sealed no commit; inspect jj st')
    return sealed


def record_pins(sealed):
    """Record the sealed revisions in the workspace checkpoint.

    Every repository already sealed is recorded, including when a later one
    fails: the checkpoint then names exactly what is reproducible, and the next
    run continues with what is left.
    """
    if not sealed:
        return
    document = registry()
    for name, commit in sealed.items():
        document['repositories'][name]['revision'] = commit
    (ROOT / 'workspace.json').write_text(json.dumps(document, indent=2) + '\n')
    print('workspace.json: recorded ' + ', '.join(f'{name} {commit[:12]}'
                                                 for name, commit in sealed.items()))


def commit(message, dry_run, full, scope=None):
    """Seal the selected checkouts in dependency order, then record their pins."""
    repos = repositories()
    known = [name for name in repos if scope is None or name in scope]
    root_scope = scope is None or ROOT_NAME in scope
    affected = [name for name in known if changed(name)]
    order = sealed_order(affected, known) if affected else []
    root_changes = changed(ROOT_NAME) if root_scope else []
    if not order and not root_changes:
        print('nothing to seal: the selected checkouts are unchanged')
        return 0
    for name in order + ([ROOT_NAME] if root_changes else []):
        print(f'{name}: ' + ', '.join(changed(name)), flush=True)
    if order and not root_scope:
        print(f'{ROOT_NAME}: workspace.json (records the sealed revisions)', flush=True)
    synced = {name: paths for name in order
              if (paths := shared_copies(name, repos))}
    if synced:
        for name, paths in synced.items():
            print(f'{name}: unsealed shared tooling: ' + ', '.join(paths), file=sys.stderr)
        print('workspace.py seal-sync delivers those copies; seal them there instead of '
              'folding them into this change', file=sys.stderr)
        return 1
    if dry_run:
        for name in order + ([ROOT_NAME] if root_changes or order else []):
            planned = planned_checks(name, full)
            print(f'\n--- {name}\nchecks: {"; ".join(planned)}\nwould seal with:')
            print(render(message, name, planned))
        return 0
    checks = {name: run_checks(name, full) for name in order}
    sealed = {}
    try:
        for name in order:
            sealed[name] = seals(name, message, checks[name])
            print(f'{name}: sealed {sealed[name][:12]}')
    finally:
        record_pins({name: commit for name, commit in sealed.items() if commit})
    # The root records what was just sealed, so it is sealed last.  A scoped
    # change that did not name the root seals only the checkpoint it updated.
    root_paths = changed(ROOT_NAME) if root_scope else [
        path for path in ['workspace.json'] if path in changed(ROOT_NAME)]
    sealed[ROOT_NAME] = None
    if root_paths:
        sealed[ROOT_NAME] = seals(ROOT_NAME, message, run_checks(ROOT_NAME, full), root_paths)
    print(f'{ROOT_NAME}: sealed {sealed[ROOT_NAME][:12]}' if sealed[ROOT_NAME]
          else f'{ROOT_NAME}: no checkpoint to record')
    if any(sealed.values()):
        print('publish with: python3 scripts/changes.py publish')
    return 0


@dataclass
class Publication:
    """One repository's verdict, decided before anything is pushed."""
    name: str
    branch: str
    sealed: str
    ahead: dict = field(default_factory=dict)      # remote -> commits it lacks
    blocked: str = ''


def message_checks(name, ahead):
    """Check every message that publishing NAME would expose."""
    seen = {}
    for found in ahead.values():
        for commit_id, subject in found:
            seen.setdefault(commit_id, subject)
    for commit_id in seen:
        text = jj(directory(name), 'log', '-r', commit_id, '--no-graph',
                  '-T', 'description').stdout
        checked_message(text)


def inspect(name, repos, remotes):
    """Decide whether NAME can be published: fetch, verify, then check it."""
    branch = branch_of(name, repos)
    if not (directory(name) / '.jj').exists():
        return Publication(name, branch, '', blocked=f'no jj checkout in {directory(name)}')
    sealed = revision(name, '@-')
    if not sealed:
        return Publication(name, branch, '', blocked='no sealed commit')
    publication = Publication(name, branch, sealed)
    for remote in remotes:
        fetched = jj(directory(name), 'git', 'fetch', '--remote', remote, check=False)
        if fetched.returncode:
            return Publication(name, branch, sealed,
                               blocked=f'fetch from {remote} failed: {tail(fetched, 400)}')
    for remote in remotes:
        published = revision(name, f'{branch}@{remote}')
        if not published:
            return Publication(name, branch, sealed,
                               blocked=f'no {branch}@{remote}; create it by hand for a new '
                                       'repository')
        if commits(name, f'{sealed}..{branch}@{remote}'):
            return Publication(name, branch, sealed,
                               blocked=f'{branch}@{remote} moved away; rebase instead of forcing')
        publication.ahead[remote] = commits(name, f'{branch}@{remote}..{sealed}')
    if not any(publication.ahead.values()):
        return publication
    recorded = repos.get(name, {}).get('revision')
    # The workspace root has no pin: it records the others.
    if name != ROOT_NAME and recorded != sealed:
        return Publication(name, branch, sealed, ahead=publication.ahead,
                           blocked=f'workspace.json records {(recorded or "nothing")[:12]}, '
                                   f'not the sealed {sealed[:12]}; run changes.py commit first')
    message_checks(name, publication.ahead)
    repository = directory(name) / 'scripts/check-repository.py'
    execute(name, 'scripts/check-repository.py --staged',
            [sys.executable, str(repository), '--staged'], cwd=directory(name))
    return publication


def publish(dry_run, remotes, scope=None):
    """Fetch and verify every checkout, then move and push what can be published.

    Repositories already at their sealed revision are the ledger: a rerun after
    a failed push ignores them and pushes only what is left.
    """
    repos = repositories()
    names = [name for name in repos if scope is None or name in scope]
    order = sealed_order(names, names, strict=False) if names else []
    if scope is None or ROOT_NAME in scope:
        order.append(ROOT_NAME)
    if not order:
        print('nothing selected to publish')
        return 0
    verdicts, failed = {}, []
    for name in order:
        upstreams = [upstream for upstream in providers(name, names, strict=False)
                     if upstream in verdicts and verdicts[upstream].blocked]
        publication = inspect(name, repos, remotes)
        verdicts[name] = publication
        if not publication.blocked and upstreams:
            publication.blocked = 'unpublished dependency: ' + ', '.join(upstreams)
        if publication.blocked:
            print(f'{name}: cannot publish, {publication.blocked}')
            failed.append(name)
        elif not any(publication.ahead.values()):
            print(f'{name}: already published at {publication.sealed[:12]}')
        else:
            found = {}
            for values in publication.ahead.values():
                for commit_id, subject in values:
                    found.setdefault(commit_id, subject)
            print(f'{name}: {len(found)} commit(s) to publish')
            for commit_id, subject in found.items():
                print(f'  {commit_id} {subject}')
    if dry_run:
        print('dry run: fetched and verified, moved and pushed nothing')
        return int(bool(failed))
    for name in order:
        publication = verdicts[name]
        behind = [remote for remote, found in publication.ahead.items() if found]
        if publication.blocked or not behind:
            continue
        # A dependency that failed while pushing leaves this one unpublished too.
        unfinished = [upstream for upstream in providers(name, names, strict=False)
                      if upstream in verdicts and verdicts[upstream].blocked]
        if unfinished:
            publication.blocked = 'unpublished dependency: ' + ', '.join(unfinished)
            print(f'{name}: cannot publish, {publication.blocked}')
            failed.append(name)
            continue
        repository = directory(name)
        jj(repository, 'bookmark', 'set', publication.branch, '-r', publication.sealed)
        pushed = []
        for remote in behind:
            # A fresh checkout imports the remote bookmark untracked; tracking it
            # is what lets the same branch publish to both mirrors.
            jj(repository, 'bookmark', 'track', f'{publication.branch}@{remote}', check=False)
            result = jj(repository, 'git', 'push', '--remote', remote,
                        '-b', publication.branch, check=False)
            if result.returncode:
                publication.blocked = f'push to {remote} failed: {tail(result, 400)}'
                break
            pushed.append(remote)
        if publication.blocked:
            print(f'{name}: {publication.blocked}')
            failed.append(name)
        else:
            print(f'{name}: {publication.branch} -> {publication.sealed[:12]}, pushed '
                  + ', '.join(pushed))
    if failed:
        print('not published: ' + ', '.join(dict.fromkeys(failed)), file=sys.stderr)
        return 1
    print('publish complete')
    return 0


def status():
    """Report unsealed work, unpublished commits and stale checkpoints."""
    repos = repositories()
    names = list(repos)
    checkouts = [(name, branch_of(name, repos)) for name in names] + [(ROOT_NAME, 'main')]
    paths = {name: changed(name) for name, _ in checkouts}
    unsealed = [f'{name} ({len(found)} file{"s" if len(found) > 1 else ""})'
                for name, found in paths.items() if found]
    unpublished = [f'{name} ({len(found)})' for name, branch in checkouts
                   if (found := commits(name, f'{branch}@origin..@-'))]
    stale = []
    for name, entry in repos.items():
        if entry.get('revision') != revision(name, '@-'):
            sealed = revision(name, '@-') or 'nothing'
            stale.append(f'{name} (records {(entry.get("revision") or "nothing")[:12]}, '
                         f'sealed {sealed[:12]})')
    synced = [f'{name} ({len(found)} file{"s" if len(found) > 1 else ""})'
              for name in names if (found := shared_copies(name, repos))]
    print('unsealed: ' + (', '.join(unsealed) or 'nothing'))
    print('unpublished (as last fetched): ' + (', '.join(unpublished) or 'nothing'))
    print('stale pins: ' + (', '.join(stale) or 'none'))
    if synced:
        print('shared tooling drift: ' + ', '.join(synced) +
              ' (run workspace.py sync and seal-sync; changes.py commit refuses those paths)')
    if order := [name for name in names if paths[name]] or paths[ROOT_NAME]:
        sealed = sealed_order(order, names) if order else []
        print('seal order: ' + ', '.join(sealed + ([ROOT_NAME] if paths[ROOT_NAME] else [])))
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    actions = parser.add_subparsers(dest='action', required=True)
    actions.add_parser('status', help='report unsealed work, unpublished commits and stale pins')
    sealing = actions.add_parser('commit', help='seal the changed checkouts in dependency order')
    sealing.add_argument('-F', '--message-file', required=True,
                         help='title and body shared by every sealed repository')
    sealing.add_argument('--dry-run', action='store_true',
                         help='show the order, the paths and the checks; change nothing')
    sealing.add_argument('--full', action='store_true',
                         help="run each package's whole check target instead of its tool tests")
    publishing = actions.add_parser('publish', help='move and push the branch of every sealed checkout')
    publishing.add_argument('--dry-run', action='store_true',
                            help='fetch and verify, then report what would be pushed')
    publishing.add_argument('--remote', action='append', choices=REMOTES,
                            help='publish to this remote only (default: aliyun and origin)')
    for action in (sealing, publishing):
        action.add_argument('--only', action='append', metavar='CHECKOUT',
                            help='limit this run to these checkouts (repeatable or comma separated)')
    args = parser.parse_args()
    try:
        if args.action == 'status':
            return status()
        scope = selected(repositories(), args.only)
        if args.action == 'commit':
            return commit(read_message(args.message_file), args.dry_run, args.full, scope)
        return publish(args.dry_run, tuple(args.remote or REMOTES), scope)
    except Failure as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
