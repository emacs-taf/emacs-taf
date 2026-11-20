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

POLICY_VERSION = 13
DOC_NAMES = {'README.md', 'README.zh-CN.md', 'CHANGELOG.md', 'CHANGELOG.zh-CN.md',
             'AGENTS.md', 'docs/manual.md', 'docs/manual.zh-CN.md',
             'docs/architecture.md', 'docs/architecture.zh-CN.md',
             # A package's extension contract is a maintained interface document,
             # like the workspace keyboard contract: the container syntax, its
             # parameters and the rules a definition follows.
             'docs/extensions.md', 'docs/extensions.zh-CN.md'}
WORKSPACE_DOC_NAMES = {'docs/keyboard-navigation.zh-CN.md'}
DIRS = {'lisp', 'tests', 'examples', 'benchmarks', 'scripts', 'docs', 'native', 'packages',
        'dictionaries', 'design', 'book', 'site', 'backends', '.github', '.gitea', '.githooks'}
# A reference book is product content rendered by its package: one Markdown
# chapter per file under book/<language>/, with the same link checks as docs.
BOOK_CHAPTER = re.compile(r'book/[a-z]{2}(?:-[A-Z][A-Za-z]+)?/[a-z0-9]+(?:-[a-z0-9]+)*\.md')
# Dependencies and build trees are not maintained files: their READMEs and
# licenses belong to their own projects.
SKIP = {'.git', '.jj', '__pycache__', 'target', '.omx', '.worktrees', '.claude',
        'node_modules'}
SHARED = ('scripts/check-api.py', 'scripts/check-api.el', 'scripts/api-workspace.json', '.editorconfig', 'scripts/check-repository.py', 'scripts/run-acceptance.py', '.githooks/pre-commit', '.githooks/commit-msg', 'scripts/check-commit-message.py',
          '.github/workflows/structure.yml', 'scripts/package_archive.py')

# A length the canvas draws is measured with the canvas's own face: `ch' and
# `lh' resolve against it, and the frame's cell is a different number whenever
# a canvas font, a text scale or another selected frame sets the two apart.
CANVAS_CELL = re.compile(r'frame-char-(?:width|height)')
# A line that names the canvas metric beside the frame's cell is that
# fallback: it asks the canvas first and keeps the frame for a runtime that
# cannot answer.
METRIC_FALLBACK = re.compile(r'etaf-display-metrics|:(?:char-width|line-height)')
# A line that states its number is the frame's own geometry says so.
FRAME_METRIC_NOTE = '; frame metric'


def provider_directory(root):
    """Return the checkout directory holding the sibling provider repositories.

    Providers normally sit beside the repository.  A nested application
    workspace keeps them one level above its own checkout, so accept the
    nearest ancestor that holds a provider named by the API registry.
    """
    try:
        names = json.loads((Path(__file__).resolve().parent / 'api-workspace.json').read_text(encoding='utf-8'))
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


def owner_binary(root):
    """Return the change graph binary that owns ROOT's checkout.

    jjosh keeps a private object store under the repository, while a jj
    checkout reaches one through a Git directory.  Both write metadata the
    other refuses to read, so asking the wrong one leaves the checkout unusable
    for its owner.
    """
    repository = root / '.jj' / 'repo'
    if repository.is_dir() and (repository / 'store' / 'git').is_dir():
        return 'jjosh'
    return 'jj'


def inventory(root):
    """Include new nonignored files, and exclude deleted or generated files."""
    if git_checkout_p(root):
        raw = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z',
                                       '--cached', '--others', '--exclude-standard'])
        return sorted({s for s in raw.decode().split('\0') if s and (root / s).is_file()})
    if (root / '.jj').is_dir():
        # A Jujutsu checkout has no Git index; the change graph already tracks
        # the files and applies the same ignore rules. The two binaries write
        # incompatible repository metadata, so neither may be tried on a
        # checkout it does not own. jjosh keeps its own object store under the
        # repository; a jj checkout shares one through a Git directory.
        binary = owner_binary(root)
        if shutil.which(binary):
            try:
                raw = subprocess.check_output([binary, 'file', 'list', '--no-pager'], cwd=root,
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
        book = json.loads(description.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return set()
    names = set()
    for spec in list(book.get('appendices') or []) + list(book.get('indices') or []):
        if isinstance(spec, dict) and spec.get('id') and spec.get('generate'):
            for language in book.get('languages') or []:
                names.add(f'book/{language}/{spec["id"]}.md')
    return names


def check(root, files=None, notices=None):
    files = inventory(root) if files is None else files
    errors = []
    generated_chapters = generated_book_chapters(root)
    workspace = (root / 'workspace.json').exists()
    doc_names = DOC_NAMES | (WORKSPACE_DOC_NAMES if workspace else set())
    if workspace:
        registry = __import__('json').loads((root / 'workspace.json').read_text(encoding='utf-8'))
        # Schema 1 listed sibling checkouts; schema 2 lists the delivery units
        # one checkout holds. Both name directories that may appear at the root.
        allowed_dirs = DIRS | set(registry.get('packages') or registry.get('repositories') or {})
    else:
        allowed_dirs = set(DIRS)
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
            if re.search(r'#\s*\[\s*(?:test\s*\]|cfg\s*\(\s*test\s*\))', (root / f).read_text(encoding='utf-8')):
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
        text = (root / f).read_text(encoding='utf-8')
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
    # Report every place that measures a length on the canvas with the frame's
    # own face.  The two agree while the canvas font, the text scale and the
    # selected frame match the frame's default face; when they do not, the page
    # draws narrower or wider than it measured and the gap grows with the
    # canvas.  Reported rather than failed: the frame's cell is the right
    # number for the frame's own geometry, which a line states with
    # `;; frame metric`.
    if notices is not None:
        for f in files:
            if not f.endswith('.el') or ('/' in f and not f.startswith('lisp/')):
                continue
            lines = (root / f).read_text(encoding='utf-8').splitlines()
            for index, line in enumerate(lines):
                if not CANVAS_CELL.search(line):
                    continue
                # An expression that names the canvas metric beside the frame's
                # cell asks the canvas first, and one that states its number is
                # frame geometry says so; both wrap, so read the line above.
                context = line + (lines[index - 1] if index else '')
                if FRAME_METRIC_NOTE in context or METRIC_FALLBACK.search(context):
                    continue
                notices.append(f'{f}:{index + 1}: frame character cell; a length the canvas draws '
                               'is measured with `etaf-display-metrics`')
    makefile = root / 'Makefile'
    if makefile.exists():
        text = makefile.read_text(encoding='utf-8')
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
        if makefile.exists() and not re.search(r'^check\s*:[^\n]*\bapi-check\b', makefile.read_text(encoding='utf-8'), re.M):
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
                manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
                cases = manifest['cases']
                names = [c['name'] for c in cases]
                declared_tests = set()
                for source in (root/'tests').rglob('*.el'):
                    if 'fixtures' not in source.relative_to(root).parts:
                        declared_tests.update(re.findall(r'^\(ert-deftest ([^\s()]+)', source.read_text(encoding='utf-8'), re.M))
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
                            file.read_text(encoding='utf-8'), re.M):
                        fail('tests/acceptance.json', f"missing named scenario: {case['name']}")
                if not re.search(r'^check\s*:[^\n]*\bacceptance\b', makefile.read_text(encoding='utf-8'), re.M):
                    fail('Makefile', 'check must include public acceptance scenarios')
            except (ValueError, KeyError, TypeError, OSError) as error:
                fail('tests/acceptance.json', f'invalid inventory: {error}')
    return sorted(set(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--staged', action='store_true')
    parser.add_argument('--skip-api', action='store_true',
                        help='check repository structure only; the API boundary is '
                             'checked once for the whole container')
    parser.add_argument('--exclude', action='append', default=[], metavar='PREFIX',
                        help='skip maintained files whose path starts with PREFIX; '
                             'a container such as packages/ is checked per unit instead')
    args = parser.parse_args()
    if (args.staged and not git_checkout_p(args.root) and (args.root / '.jj').is_dir()):
        # A secondary jj workspace has no index.  Its sealed tree is the working
        # copy exactly when the working-copy change is empty.  The binary that
        # owns this checkout must answer: asking the other one rewrites the
        # repository in a format its owner cannot read.
        binary = owner_binary(args.root)
        if not shutil.which(binary):
            print(f'{binary} is not on PATH; it owns this checkout', file=sys.stderr)
            return 1
        changed = subprocess.run([binary, 'diff', '--no-pager', '--name-only', '-r', '@'],
                                 cwd=args.root, capture_output=True, text=True)
        if changed.returncode:
            print((changed.stderr or '').strip() or f'{binary} cannot read this checkout',
                  file=sys.stderr)
            return 1
        if changed.stdout.strip():
            print('the working copy has unsealed changes; seal them before '
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
            notices = []
            errors = check(snapshot, files, notices)
            if not args.skip_api and not errors and not (snapshot / 'workspace.json').exists():
                result = subprocess.run([sys.executable, str(snapshot/'scripts/check-api.py'),
                                         '--root', str(snapshot), '--providers-dir', str(provider_directory(args.root))],
                                        capture_output=True, text=True)
                if result.returncode: errors.append(result.stderr.strip())
    else:
        notices = []
        # A container directory such as packages/ is validated one unit at a
        # time by its own invocation, so the root pass leaves it alone.
        kept = [f for f in inventory(args.root)
                if not any(f.startswith(prefix) for prefix in args.exclude)]
        errors = check(args.root, files=kept, notices=notices)
        if not errors and not args.skip_api:
            mode = '--workspace' if (args.root/'workspace.json').exists() else '--root'
            api_root = args.root/'packages' if (args.root/'packages').is_dir() else args.root.resolve()
            result = subprocess.run([sys.executable, str(args.root/'scripts/check-api.py'),
                                     mode, str(api_root),
                                     '--providers-dir', str(provider_directory(args.root))],
                                    capture_output=True, text=True)
            if result.returncode: errors.append(result.stderr.strip())
    if notices:
        print('\n'.join('note: ' + notice for notice in notices), file=sys.stderr)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'{args.root.name}: repository structure OK (policy {POLICY_VERSION})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
