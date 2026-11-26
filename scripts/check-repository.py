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
    # A secondary workspace stores a path to the owning repository here, so
    # read through it instead of treating the workspace as a Git-backed jj.
    if repository.is_file():
        target = Path(repository.read_text(encoding='utf-8').strip())
        repository = target if target.is_absolute() else (repository.parent / target).resolve()
    if repository.is_dir() and (repository / 'store' / 'git').is_dir():
        return 'jjosh'
    return 'jj'


def package_of_container(root):
    """Return non-nil when ROOT is one package inside a shared container.

    The container owns the shared tooling, the hooks and the workflow, so a
    package does not carry its own copies of them.
    """
    root = Path(root).resolve()
    return root.parent.name == 'packages' and (root.parent.parent / 'workspace.json').exists()


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
        errors.extend(install_selection_errors(root))
        errors.extend(archive_consistency_errors(root))
        # One workspace owns every checkout: a nested workspace root would fork
        # the registry, its shared tooling and its integration checkpoint again.
        for name in sorted(allowed_dirs - DIRS):
            if (root / name / 'workspace.json').exists():
                fail(name, 'nested workspace root; register its checkouts in the workspace registry instead')
        packages_dir = root / 'packages'
        registered = registry.get('packages')
        if packages_dir.is_dir() and isinstance(registered, dict):
            actual = {p.name for p in packages_dir.iterdir()
                      if p.is_dir() and not p.name.startswith('.')}
            declared = set(registered)
            for name in sorted(actual - declared):
                fail(f'packages/{name}', 'unregistered package directory; add it to workspace.json')
            for name in sorted(declared - actual):
                fail('workspace.json', f'registered package is missing under packages/: {name}')
            for name in sorted(actual):
                for vcs in ('.git', '.jj'):
                    if (packages_dir / name / vcs).exists():
                        fail(f'packages/{name}/{vcs}',
                             'nested VCS directory inside packages/; keep one shared checkout')
            valid_roles = {'framework', 'extension', 'application', 'game'}
            for name, meta in sorted(registered.items()):
                if not isinstance(meta, dict):
                    continue
                role = meta.get('role')
                if role is None:
                    continue
                if role not in valid_roles:
                    fail('workspace.json',
                         f'{name}: unknown role {role!r}; expected one of {sorted(valid_roles)}')
                elif role == 'extension':
                    entry_path = packages_dir / name / f'{name}.el'
                    if entry_path.is_file():
                        head = entry_path.read_text(encoding='utf-8', errors='replace')
                        req = re.search(r'^;; Package-Requires: (.+)$', head, re.M)
                        if not req or not re.search(r'\(etaf-ext\s+"[^"]+"\)', req.group(1)):
                            fail(f'packages/{name}/{name}.el',
                                 'role "extension" requires declaring etaf-ext in Package-Requires')
    # A package inside a shared container borrows the tooling the container
    # owns; only a root that stands alone carries its own copies.
    required = ['README.md', 'Makefile']
    if not package_of_container(root):
        required += ['scripts/check-repository.py', '.githooks/pre-commit',
                     '.githooks/commit-msg', 'scripts/check-commit-message.py',
                     '.github/workflows/structure.yml', 'scripts/check-api.py',
                     'scripts/check-api.el', 'scripts/api-workspace.json']
    for item in required:
        if item not in files: fail(item, 'required maintained file is missing')
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


INSTALLER_TARGETS = re.compile(r'^\(defconst etaf-install--targets\b(.*?)^  "', re.M | re.S)
INSTALLER_ENTRY = re.compile(r'\(([a-z][a-z0-9-]*) "')


def install_selection_errors(root):
    """Return drift between the installer menu and the release selection.

    A curated menu entry a user can pick must be shipped and gated, and a gated
    target must be reachable from that menu.  The two lists drifted once, so a
    target was offered while the archive had no file for it.
    """
    installer = root / 'etaf-install.el'
    selection_path = root / 'release-dependencies.json'
    if not installer.is_file() or not selection_path.is_file():
        return []
    match = INSTALLER_TARGETS.search(installer.read_text(encoding='utf-8'))
    if not match:
        return ['etaf-install.el: cannot read etaf-install--targets; update the consistency check']
    targets = set(INSTALLER_ENTRY.findall(match.group(1))) - {'etaf-install'}
    try:
        selection = json.loads(selection_path.read_text(encoding='utf-8'))
        packages = set(selection['packages'])
        gated = set(selection.get('targets') or packages)
    except (OSError, ValueError, KeyError, TypeError) as error:
        return [f'release-dependencies.json: {error}']
    errors = []
    for name in sorted(targets - packages):
        errors.append(f'etaf-install.el: target {name} is not in release-dependencies packages')
    for name in sorted(targets - gated):
        errors.append(f'etaf-install.el: target {name} is not in release-dependencies targets')
    for name in sorted(gated - targets):
        errors.append(f'release-dependencies.json: target {name} is not an installer target')
    return errors


BROKEN_ELPA_DOC = re.compile(
    r"elpa/[^\n\"']*\s&&\s*(?:make\b|sh\s+native/build-)", re.IGNORECASE
)
BROKEN_DOCTOR_REMEDY = re.compile(
    r"(?:elpa/[^\n\"']*\s&&\s*make\b|run\s+['`\"]make\s+native-build['`\"]|run\s+['`\"]sh\s+native/build-)",
    re.IGNORECASE,
)

# Uniform directory-to-archive classification shared across every package:
# dev/CI/showcase directories must NEVER ship in ELPA tarballs; runtime scripts
# live in `backends/', flat pure-Markdown manuals live in `docs/', and heavy
# native C build trees with `vendor/' ship only `native/manifest.json'.
DEV_ONLY_RESOURCE_ROOTS = frozenset({
    'tests', 'benchmarks', 'scripts', 'design', 'site',
    '.github', '.gitea', '.githooks',
})
DEV_ONLY_RESOURCE_FILES = frozenset({'Makefile', 'AGENTS.md'})
MEDIA_EXTENSIONS = frozenset({
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.mp4', '.mov', '.avi', '.mkv',
})
REQUIRED_RUNTIME_DIRS = ('backends', 'dictionaries', 'book')


def _dir_has_media(directory):
    """Return the first media/screenshot path inside DIRECTORY, or None."""
    for path in sorted(directory.rglob('*')):
        if path.is_file() and path.suffix.lower() in MEDIA_EXTENSIONS:
            return path
    return None


def suggest_release_resources(pkg_dir):
    """Return the recommended `release-dependencies.json` `resources` list for PKG_DIR.

    Applies the workspace's uniform directory-to-archive law:
    - Ships `docs` (flat pure-Markdown manuals), `backends`, `dictionaries`,
      `book`, pure-code `examples` (no screenshots/media), and either
      `native/manifest.json` (when `native/vendor/` exists) or `native`.
    - Never ships `tests`, `benchmarks`, `scripts`, `Makefile`, `design`,
      `site` or `native/vendor`.
    """
    pkg_dir = Path(pkg_dir)
    resources = []
    if (pkg_dir / 'docs').is_dir() and any((pkg_dir / 'docs').glob('*.md')):
        resources.append('docs')
    for name in REQUIRED_RUNTIME_DIRS:
        if (pkg_dir / name).is_dir():
            resources.append(name)
    examples_dir = pkg_dir / 'examples'
    if examples_dir.is_dir() and _dir_has_media(examples_dir) is None:
        if any(examples_dir.rglob('*.el')):
            resources.append('examples')
    native_dir = pkg_dir / 'native'
    if native_dir.is_dir():
        if (native_dir / 'vendor').exists():
            if (native_dir / 'manifest.json').is_file():
                resources.append('native/manifest.json')
        elif (native_dir / 'manifest.json').is_file() or any(native_dir.rglob('*')):
            resources.append('native')
    return resources


def archive_consistency_errors(root):
    """Validate release resource paths, directory-to-archive policy and native manifests.

    Enforces the uniform directory-to-archive classification (blocking dev-only
    directories such as `tests', `benchmarks', `scripts', `Makefile',
    `native/vendor' and screenshot `examples/' from ELPA tarballs while
    requiring declared runtime `backends/' and `native/manifest.json'), catches
    broken `elpa/ && make' remedies, and validates `native/manifest.json'.
    """
    selection_path = root / 'release-dependencies.json'
    packages_dir = root / 'packages'
    if not selection_path.is_file() or not packages_dir.is_dir():
        return []
    try:
        selection = json.loads(selection_path.read_text(encoding='utf-8'))
        packages = selection.get('packages') or {}
    except (OSError, ValueError, TypeError) as error:
        return [f'release-dependencies.json: {error}']
    errors = []
    native_validator = None
    native_script = root / 'scripts' / 'native-release.py'
    if native_script.is_file():
        spec = importlib.util.spec_from_file_location('native_release', native_script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        native_validator = module.validate_manifest

    for name, options in sorted(packages.items()):
        pkg_dir = packages_dir / name
        if not pkg_dir.is_dir():
            continue
        resources = (options or {}).get('resources') or []
        resource_set = set(resources)
        for resource in resources:
            rel = PurePosixPath(resource)
            target = pkg_dir / resource
            if (rel.is_absolute() or not rel.parts or any(part in ('.', '..') for part in rel.parts)
                    or not (target.is_dir() or target.is_file())):
                errors.append(f'release-dependencies.json: {name}: missing resource {resource}')
                continue
            top = rel.parts[0]
            if top == 'scripts':
                errors.append(
                    f'release-dependencies.json: {name}: {resource} is in dev-only scripts/; '
                    f'move runtime scripts into backends/ instead of shipping scripts/'
                )
            elif top in DEV_ONLY_RESOURCE_ROOTS or resource in DEV_ONLY_RESOURCE_FILES:
                errors.append(
                    f'release-dependencies.json: {name}: {resource} is development-only '
                    f'and must not be shipped in ELPA tarballs'
                )
            elif top == 'native':
                if 'vendor' in rel.parts or 'build' in rel.parts:
                    errors.append(
                        f'release-dependencies.json: {name}: {resource} must not ship '
                        f'native vendor/build artifacts in ELPA tarballs'
                    )
                elif resource == 'native' and (pkg_dir / 'native' / 'vendor').exists():
                    errors.append(
                        f'release-dependencies.json: {name}: native/ contains vendor/ build sources; '
                        f'list only "native/manifest.json" and host prebuilt binaries on /native/'
                    )
            elif top == 'examples' and target.is_dir():
                media = _dir_has_media(target)
                if media is not None:
                    rel_media = media.relative_to(pkg_dir).as_posix()
                    errors.append(
                        f'release-dependencies.json: {name}: {resource} contains showcase media '
                        f'({rel_media}); ship examples/ only when it holds pure runnable code'
                    )
            elif top == 'docs' and target.is_dir():
                for item in sorted(target.rglob('*')):
                    if item.is_file() and item.suffix.lower() != '.md':
                        rel_item = item.relative_to(pkg_dir).as_posix()
                        errors.append(
                            f'release-dependencies.json: {name}: docs/ must contain only '
                            f'Markdown files (found {rel_item})'
                        )
        # Ensure runtime directories present on disk are not forgotten in resources.
        for req_dir in REQUIRED_RUNTIME_DIRS:
            if (pkg_dir / req_dir).is_dir():
                if not any(r == req_dir or r.startswith(req_dir + '/') for r in resource_set):
                    errors.append(
                        f'release-dependencies.json: {name}: runtime directory {req_dir}/ '
                        f'exists on disk but is missing from resources'
                    )
        manifest_path = pkg_dir / 'native' / 'manifest.json'
        if manifest_path.is_file():
            if not any(r in ('native', 'native/manifest.json') for r in resource_set):
                errors.append(
                    f'release-dependencies.json: {name}: native/manifest.json exists on disk '
                    f'but is missing from resources'
                )
            if native_validator is not None:
                try:
                    doc = json.loads(manifest_path.read_text(encoding='utf-8'))
                except (OSError, ValueError) as error:
                    errors.append(f'packages/{name}/native/manifest.json: invalid JSON: {error}')
                else:
                    for err in native_validator(doc, expected_package=name):
                        errors.append(f'packages/{name}/native/manifest.json: {err}')
        # Archive packages never ship a root Makefile; doctor remedies and ELPA
        # install guides must not tell archive users to run one.
        for doc_name, pattern in (('README.md', BROKEN_ELPA_DOC),
                                  ('README.zh-CN.md', BROKEN_ELPA_DOC),
                                  (f'{name}.el', BROKEN_DOCTOR_REMEDY)):
            path = pkg_dir / doc_name
            if not path.is_file():
                continue
            text = path.read_text(encoding='utf-8', errors='replace')
            match = pattern.search(text)
            if match:
                errors.append(
                    f'packages/{name}/{doc_name}: archive users do not receive root Makefile/build scripts; '
                    f'replace {match.group(0)!r} with M-x etaf-install-native')
    return errors


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
