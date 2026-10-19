#!/usr/bin/env python3
"""Validate repository organization in a checkout or the exact Git index."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import unquote

POLICY_VERSION = 12
DOC_NAMES = {'README.md', 'README.zh-CN.md', 'CHANGELOG.md', 'CHANGELOG.zh-CN.md',
             'AGENTS.md', 'docs/manual.md', 'docs/manual.zh-CN.md',
             'docs/architecture.md', 'docs/architecture.zh-CN.md'}
WORKSPACE_DOC_NAMES = {'docs/keyboard-navigation.zh-CN.md'}
DIRS = {'lisp', 'tests', 'examples', 'benchmarks', 'scripts', 'docs', 'native',
        'dictionaries', 'design', 'book', 'site', 'backends', '.github', '.gitea', '.githooks'}
# A reference book is product content rendered by its package: one Markdown
# chapter per file under book/<language>/, with the same link checks as docs.
BOOK_CHAPTER = re.compile(r'book/[a-z]{2}(?:-[A-Z][A-Za-z]+)?/[a-z0-9]+(?:-[a-z0-9]+)*\.md')
SKIP = {'.git', '.jj', '__pycache__', 'target', '.omx', '.worktrees', '.claude'}
SHARED = ('scripts/check-api.py', 'scripts/check-api.el', 'scripts/api-workspace.json', '.editorconfig', 'scripts/check-repository.py', 'scripts/run-acceptance.py', '.githooks/pre-commit', '.githooks/commit-msg', 'scripts/check-commit-message.py',
          '.github/workflows/structure.yml', 'scripts/package_archive.py')


def provider_directory(root):
    """Return the checkout directory holding the sibling provider repositories.

    Providers normally sit beside the repository.  A nested application
    workspace keeps them one level above its own checkout, so accept the
    nearest ancestor that holds a provider named by the API registry.
    """
    try:
        names = json.loads((Path(__file__).resolve().parent / 'api-workspace.json').read_text())
    except (OSError, ValueError):
        names = {}
    providers = Path(root).resolve().parent
    if not any((providers / name).is_dir() for name in names) and any(
            (providers.parent / name).is_dir() for name in names):
        providers = providers.parent
    return providers


def git_checkout_p(root):
    """Whether ROOT is the top level of its own Git checkout."""
    try:
        top = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                                      stderr=subprocess.DEVNULL, text=True).strip()
        return Path(top).resolve() == root.resolve()
    except (subprocess.CalledProcessError, OSError):
        return False


def inventory(root):
    """Include new nonignored files, and exclude deleted or generated files."""
    if git_checkout_p(root):
        raw = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z',
                                       '--cached', '--others', '--exclude-standard'])
        return sorted({s for s in raw.decode().split('\0') if s and (root / s).is_file()})
    if (root / '.jj').is_dir() and shutil.which('jj'):
        # A secondary jj workspace has no Git index; jj snapshots new files and
        # applies the same ignore rules.
        try:
            raw = subprocess.check_output(['jj', 'file', 'list', '--no-pager'], cwd=root,
                                          stderr=subprocess.DEVNULL, text=True)
            return sorted({s for s in raw.splitlines() if s and (root / s).is_file()})
        except subprocess.CalledProcessError:
            pass
    return sorted(str(p.relative_to(root)) for p in root.rglob('*')
                  if p.is_file() and not (set(p.relative_to(root).parts) & SKIP)
                  and p.suffix not in {'.elc', '.pyc', '.o', '.so', '.dylib', '.dll'})


def generated_book_chapters(root):
    """Return book/<language>/<id>.md names that book.json declares as generated.

    A generated appendix or index has no chapter file; the package builds the
    chapter from the book model, so links to it are valid without one.
    """
    description = Path(root) / 'book/book.json'
    if not description.is_file():
        return set()
    try:
        book = json.loads(description.read_text())
    except (OSError, ValueError):
        return set()
    names = set()
    for spec in list(book.get('appendices') or []) + list(book.get('indices') or []):
        if isinstance(spec, dict) and spec.get('id') and spec.get('generate'):
            for language in book.get('languages') or []:
                names.add(f'book/{language}/{spec["id"]}.md')
    return names


def check(root, files=None):
    files = inventory(root) if files is None else files
    errors = []
    generated_chapters = generated_book_chapters(root)
    workspace = (root / 'workspace.json').exists()
    doc_names = DOC_NAMES | (WORKSPACE_DOC_NAMES if workspace else set())
    allowed_dirs = DIRS | (set(__import__('json').loads((root / 'workspace.json').read_text())['repositories']) if workspace else set())
    def fail(path, message): errors.append(f'{path}: {message}')
    if workspace:
        # One workspace owns every checkout: a nested workspace root would fork
        # the registry, its shared tooling and its integration checkpoint again.
        for name in sorted(allowed_dirs - DIRS):
            if (root / name / 'workspace.json').exists():
                fail(name, 'nested workspace root; register its checkouts in the workspace registry instead')
    for required in ['README.md', 'Makefile', 'scripts/check-repository.py',
                     '.githooks/pre-commit', '.githooks/commit-msg', 'scripts/check-commit-message.py', '.github/workflows/structure.yml',
                     'scripts/check-api.py', 'scripts/check-api.el', 'scripts/api-workspace.json']:
        if required not in files: fail(required, 'required maintained file is missing')
    if workspace and 'AGENTS.md' not in files:
        fail('AGENTS.md', 'workspace requires its development instructions')
    if workspace and 'docs/architecture.zh-CN.md' not in files:
        fail('docs/architecture.zh-CN.md', 'workspace requires the accepted ecosystem architecture contract')
    root_lisp = [f for f in files if '/' not in f and f.endswith('.el')]
    if not workspace and len(root_lisp) != 1:
        fail('entry', 'packages require exactly one root entry; implementations belong in lisp/')
    for entry in root_lisp:
        if 'lisp/' + entry in files:
            fail(entry, 'entry must not be duplicated under lisp/')
    spellings = {}
    for f in files:
        parts = PurePosixPath(f).parts
        instructions = parts[-1] == 'AGENTS.md'
        for i in range(1, len(parts) + 1):
            spelling = '/'.join(parts[:i]); old = spellings.setdefault(spelling.casefold(), spelling)
            if old != spelling: fail(f, f'case collision with {old}')
        if len(parts) > 1 and parts[0] not in allowed_dirs:
            fail(f, 'unapproved top-level directory')
        if len(parts) == 1 and f not in doc_names and f not in {
                'Makefile', 'LICENSE', 'COPYING', 'NOTICE', '.gitignore',
                '.gitattributes', '.editorconfig', 'workspace.json',
                'release-dependencies.json'} and not f.endswith('.el'):
            fail(f, 'unapproved root file; use the designated source/tool/data directory')
        if f.startswith('native/') and f.endswith('.rs') and 'vendor' not in parts:
            if re.search(r'#\s*\[\s*(?:test\s*\]|cfg\s*\(\s*test\s*\))', (root / f).read_text()):
                fail(f, 'delete native internal unit tests; validate through public package APIs')
        # Preserve upstream dictionary/vendor licensing and resource names.
        external = parts[0] == 'dictionaries' or f.startswith('native/vendor/')
        chapter = parts[0] == 'book' and f.endswith('.md')
        if chapter and not BOOK_CHAPTER.fullmatch(f):
            fail(f, 'book chapters are book/<language>/<lowercase-kebab-slug>.md')
        if f.endswith('.md') and f not in doc_names and not external and not instructions and not chapter:
            fail(f, 'use README, CHANGELOG, docs/manual or docs/architecture; merge or delete other documents')
        if f.startswith('docs/') and not instructions and (len(parts) != 2 or f not in doc_names):
            fail(f, 'documentation must be flat and use the fixed document names')
        if re.search(r'(^|/)(?:\.DS_Store|[^/]+\.(?:elc|eln|pyc|o|so|dylib|dll))$', f) or 'target' in parts or '__pycache__' in parts:
            fail(f, 'generated artifact must not be tracked')
        if len(parts)==1 and f.endswith('.el') and any(x in f for x in ['benchmark','-tests','-demo','-showcase']):
            fail(f, 'development code belongs in tests, benchmarks or examples')
        if f.startswith('scripts/') and (Path(f).name.endswith('-tests.el') or Path(f).name.startswith('test_')):
            fail(f, 'correctness tests belong in tests/; tool tests belong in tests/tools/')
        if external or not f.endswith('.md'): continue
        text = (root / f).read_text()
        # Validate inline and reference-style Markdown links outside fenced and
        # inline code; a code span may show link syntax without being a link.
        plain = re.sub(r'^(`{3,}|~{3,}).*?^\1\s*$', '', text, flags=re.M | re.S)
        plain = re.sub(r'(?<!`)(`+)(?!`).+?(?<!`)\1(?!`)', '', plain)
        links = re.findall(r'\]\(<?([^\s)>]+)>?(?:\s+"[^"]*")?\)', plain)
        links += re.findall(r'^\s*\[[^\]]+\]:\s*<?([^\s>]+)>?', plain, re.M)
        for link in links:
            if re.match(r'[a-zA-Z][\w+.-]*:', link) or link.startswith(('#', '/')): continue
            rel = unquote(link.split('#')[0])
            if not rel: continue
            target = Path(os.path.normpath(str(Path(f).parent / rel)))
            if '..' in target.parts:
                fail(f, f'cross-repository link must use the provider URL: {link}')
            elif (target.as_posix() != '.' and target.as_posix() not in files
                  and target.as_posix() not in generated_chapters
                  and not any(name.startswith(target.as_posix().rstrip('/') + '/') for name in files)):
                fail(f, f'broken local link (including exact case): {link}')
    makefile = root / 'Makefile'
    if makefile.exists():
        text = makefile.read_text()
        for name in ['compile', 'test', 'check', 'clean', 'structure-check', 'setup-hooks']:
            if not re.search(r'^'+name+r'\s*:', text, re.M): fail('Makefile', f'missing {name} target')
        if not re.search(r'^check\s*:[^\n]*\bstructure-check\b', text, re.M):
            fail('Makefile', 'check must depend on structure-check')
        # Literal source paths in the root Makefile must exist, including phase leftovers.
        for token in re.findall(r'(?<![\w/.-])(?:lisp|tests|scripts|examples|benchmarks)/[\w./*-]+\.(?:el|py|sh)', text):
            if '*' not in token and not (root/token).is_file():fail('Makefile', f'missing source: {token}')
        for directory in re.findall(r'(?:^|\s)-L ([\w./-]+)', text):
            if directory.startswith('../'):
                # Sibling dependencies can be absent in a standalone clone.
                continue
            if not (root/directory).is_dir():fail('Makefile', f'missing load directory: {directory}')
        for directory in re.findall(r'directory-files(?:-recursively)?\s+"([\w/-]+)"', text):
            if not (root/directory).is_dir():fail('Makefile', f'missing scanned directory: {directory}')
        for pattern in re.findall(r'\$\(wildcard ((?:examples|tests|scripts|benchmarks)/[^)]+)\)', text):
            if not list(root.glob(pattern)):fail('Makefile', f'empty source discovery: {pattern}')
    if not workspace:
        if makefile.exists() and not re.search(r'^check\s*:[^\n]*\bapi-check\b', makefile.read_text(), re.M):
            fail('Makefile', 'check must include fresh entry API validation')
        api_tool = root / 'scripts/check-api.py'
        if api_tool.exists() and len(root_lisp) == 1:
            spec = importlib.util.spec_from_file_location('api_policy', api_tool)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            errors.extend(module.declarations(root / root_lisp[0])[1])
        manifest_path = root / 'tests/acceptance.json'
        if not manifest_path.is_file():
            fail('tests/acceptance.json', 'missing public acceptance inventory')
        else:
            try:
                manifest = json.loads(manifest_path.read_text())
                cases = manifest['cases']
                names = [c['name'] for c in cases]
                declared_tests = set()
                for source in (root/'tests').rglob('*.el'):
                    if 'fixtures' not in source.relative_to(root).parts:
                        declared_tests.update(re.findall(r'^\(ert-deftest ([^\s()]+)', source.read_text(), re.M))
                if declared_tests != set(names):
                    fail('tests/acceptance.json', 'inventory must cover exactly all public Lisp tests')
                if not cases or len(names) != len(set(names)):
                    fail('tests/acceptance.json', 'cases must be nonempty and unique')
                for case in cases:
                    file = root / case['file']
                    if not case.get('purpose'):
                        fail('tests/acceptance.json', 'each scenario needs an observable purpose')
                    if not file.is_file() or not re.search(
                            r'^\(ert-deftest ' + re.escape(case['name']) + r'(?=\s|\()',
                            file.read_text(), re.M):
                        fail('tests/acceptance.json', f"missing named scenario: {case['name']}")
                if not re.search(r'^check\s*:[^\n]*\bacceptance\b', makefile.read_text(), re.M):
                    fail('Makefile', 'check must include public acceptance scenarios')
            except (ValueError, KeyError, TypeError, OSError) as error:
                fail('tests/acceptance.json', f'invalid inventory: {error}')
    return sorted(set(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--staged', action='store_true')
    args = parser.parse_args()
    if (args.staged and not git_checkout_p(args.root) and (args.root / '.jj').is_dir()
            and shutil.which('jj')):
        # A secondary jj workspace has no index.  Its sealed tree is the working
        # copy exactly when the working-copy change is empty.
        changed = subprocess.run(['jj', 'diff', '--no-pager', '--name-only', '-r', '@'],
                                 cwd=args.root, capture_output=True, text=True)
        if changed.returncode or changed.stdout.strip():
            print(changed.stderr.strip() or 'jj workspace has unsealed changes; seal them before '
                  '--staged checks', file=sys.stderr)
            return 1
        args.staged = False
    if args.staged:
        # Materialize the index, so unstaged repairs cannot hide a broken commit.
        with tempfile.TemporaryDirectory(prefix='repository-index-') as directory:
            subprocess.run(['git', '-C', str(args.root), 'checkout-index', '--all',
                            '--prefix', directory + os.sep], check=True)
            snapshot = Path(directory)
            # Intent-to-add entries (`git add -N`, and the new files of a
            # colocated jj working copy) are not part of the commit, but
            # checkout-index writes them as empty files.
            status = subprocess.check_output(['git', '-C', str(args.root), 'status', '--porcelain=v2',
                                              '-z', '--untracked-files=no']).decode()
            for entry in status.split('\0'):
                if entry.startswith('1 .A '):
                    (snapshot / entry.split(' ', 8)[8]).unlink(missing_ok=True)
            files = sorted(str(p.relative_to(snapshot)) for p in snapshot.rglob('*') if p.is_file())
            errors = check(snapshot, files)
            if not errors and not (snapshot / 'workspace.json').exists():
                result = subprocess.run([sys.executable, str(snapshot/'scripts/check-api.py'),
                                         '--root', str(snapshot), '--providers-dir', str(provider_directory(args.root))],
                                        capture_output=True, text=True)
                if result.returncode: errors.append(result.stderr.strip())
    else:
        errors = check(args.root)
        if not errors:
            mode = '--workspace' if (args.root/'workspace.json').exists() else '--root'
            result = subprocess.run([sys.executable, str(args.root/'scripts/check-api.py'),
                                     mode, str(args.root.resolve()),
                                     '--providers-dir', str(provider_directory(args.root))],
                                    capture_output=True, text=True)
            if result.returncode: errors.append(result.stderr.strip())
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'{args.root.name}: repository structure OK (policy {POLICY_VERSION})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
