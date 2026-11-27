#!/usr/bin/env python3
"""Check root Commentary API declarations and cross-package Lisp references."""
import argparse
import json
from pathlib import Path
import re
import sys
import subprocess

API = re.compile(r'^;; (Function|Macro|Variable|Hook|Error|Component): ([^\s()]+)(.*)$', re.M)
REQUIRES = re.compile(r'^;; Package-Requires: (.+)$', re.M)
REQUIREMENT = re.compile(r'\(([a-z][a-z0-9-]*) "[0-9]+(?:\.[0-9]+)*"\)')
DEFINITION = re.compile(r"(?<!['`])\((?:defun|cl-defun|defmacro|cl-defmacro|defsubst|defvar|defconst|defcustom|defvar-local|define-minor-mode|define-derived-mode|etaf-ui--define-component|etaf-define-component)\s+([^\s()]+)")


def tokens(source):
    """Keep Lisp symbols/references, excluding comments, strings and characters."""
    i = 0
    while i < len(source):
        c = source[i]
        if c == ';':
            end = source.find('\n', i)
            i = len(source) if end < 0 else end + 1
        elif c == '"':
            i += 1
            while i < len(source):
                if source[i] == '\\': i += 2
                elif source[i] == '"':
                    i += 1
                    break
                else: i += 1
        elif c == '?' and (i == 0 or source[i-1] in ' \t\n(['):
            i += 2
            if i <= len(source) and source[i-1] == '\\': i += 1
        elif c in " \t\r\n()[]'`,": i += 1
        else:
            start = i
            while i < len(source) and source[i] not in " \t\r\n()[]'`,;\"": i += 1
            if i == start: i += 1
            else: yield source[start:i]


def declarations(entry):
    source = entry.read_text()
    if ';;; Commentary:' not in source or ';;; Code:' not in source:
        return {}, [f'{entry}: missing Commentary/Code sections']
    commentary = source.split(';;; Commentary:', 1)[1].split(';;; Code:', 1)[0]
    records = {}; errors = []; bindings = set()
    matches = list(API.finditer(commentary))
    for index, match in enumerate(matches):
        kind, name, signature = match.groups()
        detail = commentary[match.end():matches[index+1].start() if index+1<len(matches) else len(commentary)]
        namespace = {'Function': 'function', 'Macro': 'function',
                     'Variable': 'value', 'Hook': 'value',
                     'Error': 'error', 'Component': 'component'}[kind]
        binding = (namespace, name)
        if binding in bindings:
            errors.append(f'{entry}: duplicate API declaration: {name} ({namespace})')
        bindings.add(binding)
        if '--' in name: errors.append(f'{entry}: private symbol declared as API: {name}')
        if kind in ('Function', 'Macro', 'Component') and not signature.strip().startswith('('):
            errors.append(f'{entry}: {name} needs a calling signature')
        if not re.search(r'^;;\s+\S', detail, re.M): errors.append(f'{entry}: {name} needs usage/behavior documentation')
        records.setdefault(name, set()).add(kind.lower())
    if not records: errors.append(f'{entry}: public API declarations are empty')
    return records, errors


def struct_symbols(source):
    """Recognize cl-defstruct accessors, constructors, predicates and copiers.

    Ignore comments/strings before balancing forms. This intentionally recognizes
    literal definitions; dynamically generated symbols remain a review concern.
    """
    masked = re.sub(r'"(?:\\.|[^"\\])*"|;[^\n]*', lambda m: ' ' * len(m[0]), source)
    result = set()
    for start in re.finditer(r'\(cl-defstruct\s+', masked):
        depth = 0
        end = start.start()
        for end in range(start.start(), len(masked)):
            if masked[end] == '(': depth += 1
            elif masked[end] == ')':
                depth -= 1
                if depth == 0: break
        parts = re.findall(r"[()]|[^\s()'`]+", masked[start.start():end+1])
        stack = [[]]
        for token in parts:
            if token == '(':
                child = []; stack[-1].append(child); stack.append(child)
            elif token == ')':
                if len(stack) > 1: stack.pop()
            else: stack[-1].append(token)
        if not stack[0] or len(stack[0][0]) < 2: continue
        form = stack[0][0]
        header = form[1]
        name = header[0] if isinstance(header, list) else header
        if not isinstance(name, str) or name.startswith(','): continue
        options = header[1:] if isinstance(header, list) else []
        prefix = name + '-'
        constructors = []
        predicate = name + '-p'; copier = 'copy-' + name
        for option in options:
            if not isinstance(option, list) or len(option)<2: continue
            key, value = option[:2]
            if key == ':conc-name': prefix = '' if value == 'nil' else value
            elif key == ':constructor': constructors.append(value)
            elif key == ':predicate': predicate = value
            elif key == ':copier': copier = value
        result.update(x for x in [predicate, copier] + (constructors or ['make-'+name]) if x != 'nil')
        for slot in form[2:]:
            slot = slot[0] if isinstance(slot, list) and slot else slot
            if isinstance(slot, str) and slot and not slot.startswith(':'):
                result.add(prefix + slot)
    return result


def _sexp_tokens(source):
    """Yield Elisp structural tokens (parens, strings, atoms) without comments."""
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if c in ' \t\r\n':
            i += 1
        elif c == ';':
            end = source.find('\n', i)
            i = n if end < 0 else end + 1
        elif c == '"':
            start = i
            i += 1
            while i < n:
                if source[i] == '\\':
                    i += 2
                elif source[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
            yield ('str', source[start:i])
        elif c == '?' and (i == 0 or source[i - 1] in ' \t\r\n([\'`,'):
            start = i
            i += 2
            if i <= n and source[i - 1] == '\\':
                if i < n and source[i] in 'xuU':
                    while i < n and source[i] not in ' \t\r\n()[]\'"`;':
                        i += 1
                else:
                    i += 1
            yield ('atom', source[start:i])
        elif c in '()':
            yield (c, c)
            i += 1
        elif c in "[]'`,@#":
            yield ('punct', c)
            i += 1
        else:
            start = i
            while i < n and source[i] not in ' \t\r\n()[]\'`,;"':
                i += 1
            if i == start:
                i += 1
            else:
                yield ('atom', source[start:i])


def interactive_definitions(source):
    """Return sorted list of (KIND, NAME) for top-level interactive commands/modes."""
    toks = list(_sexp_tokens(source))
    i, n = 0, len(toks)
    results = []

    def skip_form(idx):
        if idx >= n:
            return n
        k, _ = toks[idx]
        if k == 'punct':
            return skip_form(idx + 1)
        if k == '(':
            depth = 1
            idx += 1
            while idx < n and depth > 0:
                if toks[idx][0] == '(':
                    depth += 1
                elif toks[idx][0] == ')':
                    depth -= 1
                idx += 1
            return idx
        return idx + 1

    while i < n:
        if toks[i][0] == '(':
            form_end = skip_form(i)
            if i + 2 < form_end and toks[i + 1][0] == 'atom' and toks[i + 2][0] == 'atom':
                head = toks[i + 1][1]
                name = toks[i + 2][1]
                if head in ('defun', 'cl-defun'):
                    # Skip arglist, optional docstring, and optional (declare ...) forms.
                    pos = skip_form(i + 3)
                    while pos < form_end - 1:
                        if toks[pos][0] == 'str':
                            pos += 1
                        elif (toks[pos][0] == '(' and pos + 1 < form_end - 1
                              and toks[pos + 1] == ('atom', 'declare')):
                            pos = skip_form(pos)
                        else:
                            break
                    if (pos + 1 < form_end - 1 and toks[pos][0] == '('
                            and toks[pos + 1] == ('atom', 'interactive')):
                        results.append((head, name))
                elif head in ('define-derived-mode', 'define-minor-mode',
                              'define-globalized-minor-mode', 'define-generic-mode'):
                    # Interactive unless top-level keyword pair `:interactive nil' is present.
                    non_interactive = False
                    pos = i + 3
                    while pos < form_end - 1:
                        if toks[pos] == ('atom', ':interactive'):
                            if pos + 1 < form_end - 1 and toks[pos + 1] == ('atom', 'nil'):
                                non_interactive = True
                                break
                            pos += 2
                        else:
                            pos = skip_form(pos)
                    if not non_interactive:
                        results.append((head, name))
            i = form_end
        else:
            i += 1
    return results


def check_interactive_leaks(files, api_records, entry_name, *, check_undeclared=True):
    """Return errors for private (`--') or undeclared interactive commands/modes."""
    errors = []
    declared_functions = {sym for sym, kinds in api_records.items() if 'function' in kinds}
    for path in files:
        for kind, name in interactive_definitions(path.read_text()):
            if '--' in name:
                errors.append(
                    f'{path}: private interactive {kind} {name} leaks into M-x '
                    f'(make it non-interactive / pass :interactive nil, and wrap keymap '
                    f'bindings in anonymous lambdas or uninterned make-symbol commands)'
                )
            elif check_undeclared and name not in declared_functions:
                errors.append(
                    f'{path}: undeclared interactive {kind} {name} leaks into M-x '
                    f'(either declare it as Function in {entry_name} Commentary or make it non-interactive)'
                )
    return errors


def package(root):
    entries = list(root.glob('*.el'))
    if len(entries) != 1: raise ValueError(f'{root}: expected one root entry')
    entry = entries[0]
    files = [entry] + sorted((root/'lisp').glob('*.el'))
    example_roots = sorted(p for p in (root/'examples').glob('*')
                           if p.is_dir() and (p/(p.name+'.el')).is_file())
    examples = {p.name: package(p) for p in example_roots}
    diagnostic_files = [p for d in ('scripts', 'benchmarks', 'examples')
                        for p in (root/d).rglob('*.el')
                        if not any(p.is_relative_to(example) for example in example_roots)]
    example_files = [p for p in (root/'examples').rglob('*.el')
                     if not any(p.is_relative_to(example) for example in example_roots)]
    defined = set(); features = set()
    for p in files + diagnostic_files:
        text = p.read_text()
        text = re.sub(r'"(?:\\.|[^"\\])*"|;[^\n]*', lambda m: ' ' * len(m[0]), text)
        defined.update(sym for sym in DEFINITION.findall(text) if not sym.startswith(','))
        defined.difference_update(re.findall(r"\(defvar\s+([^\s()]+)\s*\)", text))
        defined.update(re.findall(r"\((?:define-error|defalias|defvaralias)\s+'([^\s()]+)", text))
        defined.update(struct_symbols(text))
        features.update(re.findall(r"\(provide\s+'([^\s()]+)", text))
    api, errors = declarations(entry)
    errors.extend(check_interactive_leaks(files, api, entry.name, check_undeclared=True))
    errors.extend(check_interactive_leaks(example_files, api, entry.name, check_undeclared=False))
    return {'root':root, 'entry':entry, 'files':files, 'defined':defined, 'features':features,
            'api':api, 'errors':errors, 'examples':examples}


def required(entry):
    """Return the package names the entry's Package-Requires header names.

    None means the entry states no requirement at all, which leaves the
    declaration contract unenforced rather than guessed.
    """
    header = REQUIRES.search(entry.read_text())
    return REQUIREMENT.findall(header[1]) if header else None


def check(packages, selected=None, known_providers=()):
    packages = dict(packages)
    selected = set(selected) if selected is not None else None
    pending = list(packages)
    while pending:
        parent = pending.pop()
        for name, example in packages[parent]['examples'].items():
            name = parent + '/examples/' + name
            packages[name] = example
            pending.append(name)
            if selected is not None and parent in selected:
                selected.add(name)
    errors = []
    owners = {}
    feature_owners = {}
    for name, pkg in packages.items():
        # Explicit exports cover generated accessors and macro-created components too.
        for sym in pkg['defined'] | set(pkg['api']):
            if sym in owners and owners[sym] != name:
                errors.append(f'{pkg["entry"]}: symbol {sym} is also owned by {owners[sym]}')
            owners[sym] = name
        for feature in pkg['features']: feature_owners[feature] = name
    for name, pkg in packages.items():
        if selected and name not in selected: continue
        errors.extend(pkg['errors'])
        tests = sorted(p for p in (pkg['root']/'tests').rglob('*.el') if 'fixtures' not in p.relative_to(pkg['root']).parts)
        example_roots = [example['root'] for example in pkg['examples'].values()]
        files = pkg['files'] + [p for p in sorted((pkg['root']/'examples').rglob('*.el'))
                               if not any(p.is_relative_to(root) for root in example_roots)] + tests
        for file in files:
            source = file.read_text()
            for symbol in set(tokens(source)):
                provider = owners.get(symbol)
                if provider and (provider != name or file in tests) and symbol not in packages[provider]['api']:
                    errors.append(f'{file}: {symbol} is internal to {provider}; use its root entry API')
            for literal in re.findall(r'\(intern(?:-soft)?\s+"([^"\\]+)"', source):
                provider = owners.get(literal)
                if provider and (provider != name or file in tests) and literal not in packages[provider]['api']:
                    errors.append(f'{file}: reflective reference to internal {provider} symbol {literal}')
            for library in re.findall(r'\((?:load|load-file)\s+"([^"\\]+)"', source):
                for provider, contract in packages.items():
                    if provider == name and file not in tests: continue
                    internal = contract['features'] - {contract['entry'].stem}
                    if Path(library).stem in internal:
                        errors.append(f'{file}: direct load of internal {provider} library {library}')
            for feature in re.findall(r"\(require\s+'([^\s()]+)", source):
                provider = feature_owners.get(feature)
                if provider and (provider != name or file in tests) and feature != packages[provider]['entry'].stem:
                    errors.append(f'{file}: require {packages[provider]["entry"].stem}, not internal feature {feature}')
        # A declared dependency names what the package itself consumes: the
        # archive resolves the closure, so a transitive provider stays out and a
        # declaration no source uses goes away.
        owner_of = {**feature_owners, **owners}
        declared = required(pkg['entry'])
        known = ({owner for owner in owner_of.values() if '/examples/' not in owner}
                 | set(known_providers))
        runtime, anywhere = set(), set()
        for file in pkg['files'] + files:
            consumed = set()
            for symbol in set(tokens(file.read_text())):
                provider = owner_of.get(symbol)
                if provider and provider != name and '/examples/' not in provider:
                    consumed.add(provider)
            anywhere.update(consumed)
            if file in pkg['files']:
                runtime.update(consumed)
        if declared is not None:
            declared = set(declared) - {'emacs'}
            for missing in sorted(runtime - declared):
                errors.append(f'{pkg["entry"]}: Package-Requires omits {missing}, whose API its sources use')
            for unused in sorted((declared & known) - anywhere):
                errors.append(f'{pkg["entry"]}: Package-Requires declares {unused}, which no source uses')
    return sorted(set(errors))


def clone_provider(url, path):
    if url.startswith('git@'):
        host, location = url[4:].split(':', 1)
        url = 'https://' + host + '/' + location
    subprocess.run(['git','clone','--depth=1','--single-branch',url,str(path)],check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--providers-dir', type=Path)
    parser.add_argument('--fetch-providers', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    registry = json.loads((Path(__file__).parent/'api-workspace.json').read_text())
    if args.workspace:
        workspace = args.workspace.resolve()
        if args.fetch_providers:
            for name, entry in registry.items():
                if not (workspace/name).exists(): clone_provider(entry['url'], workspace/name)
        # A workspace checkout holds only the packages it registered;
        # a name in the registry with no directory there is not a defect.
        packages = {name:package(workspace/name) for name in registry
                    if (workspace/name).is_dir()}
        selected = None
    else:
        own = package(root)
        name = next((n for n,e in registry.items() if e['entry']==own['entry'].stem), root.name)
        provider_dir = (args.providers_dir or root.parent).resolve()
        packages = {name: own}
        pending = [name]
        while pending:
            current = pending.pop()
            contract = packages[current]
            references = set()
            for file in contract['files'] + [p for d in ('examples', 'tests') for p in (contract['root']/d).rglob('*.el') if 'fixtures' not in p.relative_to(contract['root']).parts]:
                references.update(tokens(file.read_text()))
            dependencies = set()
            for symbol in references:
                provider = next((n for n,e in sorted(registry.items(), key=lambda pair:-len(pair[1]['entry']))
                                 if symbol==e['entry'] or symbol.startswith(e['entry']+'-')), None)
                if provider and provider not in packages: dependencies.add(provider)
            for dependency in sorted(dependencies):
                path = provider_dir/dependency
                if args.fetch_providers and not path.exists():
                    clone_provider(registry[dependency]['url'], path)
                if not path.is_dir():
                    parser.error(f'missing provider {dependency}; clone it beside this repository or use --fetch-providers --providers-dir PATH')
                packages[dependency] = package(path)
                pending.append(dependency)
        selected = {name}
    errors = check(packages, selected, registry)
    if args.workspace:
        # Also audit every package directory under workspace (including apps not
        # in api-workspace.json) plus root etaf-install.el for M-x leaks.
        for pkg_dir in sorted(workspace.iterdir()):
            if not pkg_dir.is_dir() or pkg_dir.name.startswith('.') or pkg_dir.name in packages:
                continue
            entry = pkg_dir / (pkg_dir.name + '.el')
            if not entry.is_file():
                continue
            pkg_api, pkg_errs = declarations(entry)
            errors.extend(pkg_errs)
            pkg_files = [entry] + sorted((pkg_dir / 'lisp').glob('*.el'))
            ex_roots = [p for p in (pkg_dir / 'examples').glob('*')
                        if p.is_dir() and (p / (p.name + '.el')).is_file()]
            ex_files = [p for p in (pkg_dir / 'examples').rglob('*.el')
                        if not any(p.is_relative_to(r) for r in ex_roots)]
            errors.extend(check_interactive_leaks(pkg_files, pkg_api, entry.name, check_undeclared=True))
            errors.extend(check_interactive_leaks(ex_files, pkg_api, entry.name, check_undeclared=False))
            for ex_root in ex_roots:
                ex_entry = ex_root / (ex_root.name + '.el')
                ex_api, ex_errs = declarations(ex_entry)
                errors.extend(ex_errs)
                ex_pkg_files = [ex_entry] + sorted((ex_root / 'lisp').glob('*.el'))
                errors.extend(check_interactive_leaks(ex_pkg_files, ex_api, ex_entry.name, check_undeclared=True))
        installer = workspace.parent / 'etaf-install.el'
        if installer.is_file():
            inst_api, inst_errors = declarations(installer)
            errors.extend(inst_errors)
            errors.extend(check_interactive_leaks([installer], inst_api, installer.name, check_undeclared=True))
    errors = sorted(set(errors))
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('Public API declarations and consumer boundaries OK')
    return 0


if __name__ == '__main__': sys.exit(main())
