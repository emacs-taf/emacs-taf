#!/usr/bin/env python3
"""refscope: which units must be re-checked after a change.

A general change-impact tool. The engine (graph, reverse lookup, propagation,
grading, ordering) is language and project agnostic. Two kinds of plugin supply
the parts that are not:

  scoper     turns a directory tree into delivery units, each with the files it
             owns, the public symbols it exports and the units it requires
  extractor  turns one source file into the symbols it defines and the symbols
             it references

Current plugins: scoper `emacs` (one root entry plus lisp/ per unit, requires
read from Package-Requires) and extractor `elisp` (defun / defmacro / defvar /
cl-defstruct into symbols). Adding a language or a project layout means adding
one plugin, not touching the engine.

Commands:
  stats                  graph size and totals
  impact --package PKG   which units reference PKG's symbols
  impact --symbol SYM    which units reference SYM
  compare --package PKG  symbol-level scope beside package-level scope
  plan --changed PATH…   the units to re-check, with level and reason
  run --changed PATH…    execute the plan (L1 compile, L2 test); --yes to act

Reusing scripts/check-api.py (tokenizer, definition regex, Commentary parser)
keeps refscope and the API boundary gate from disagreeing about symbol ownership.
"""
import argparse
import concurrent.futures
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import NamedTuple

CHECK_API = Path(__file__).resolve().parent / 'check-api.py'
TOKEN = re.compile(r"[^\s()\[\]'`,;\"]+")
BARE_DEFVAR = re.compile(r"(?<!['`])\(defvar\s+([^\s()]+)\s*\)")
LEVELS = ('L1', 'L2')


def load_check(path=CHECK_API):
    """Import scripts/check-api.py, the single source of symbol ownership."""
    spec = importlib.util.spec_from_file_location('checkapi', str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mask(source):
    """Blank out comments and strings, keeping length and newlines."""
    return re.sub(r'"(?:\\.|[^"\\])*"|;[^\n]*',
                  lambda m: re.sub(r"[^\n]", " ", m.group(0)), source)


# --- engine -------------------------------------------------------------

class Unit(NamedTuple):
    """One delivery unit as the scoper describes it."""
    name: str
    root: Path
    entry: Path
    files: list
    requires: set
    public: set


class Graph(NamedTuple):
    units: dict
    owners: dict
    refs: dict
    conflicts: dict
    by_file: dict

    @property
    def public(self):
        """Public symbols per unit, for callers that only need the export list."""
        return {name: unit.public for name, unit in self.units.items()}

    @property
    def requires(self):
        """Required unit names per unit."""
        return {name: unit.requires for name, unit in self.units.items()}


def pick(extractors, path):
    """The first extractor that claims PATH, or None when no plugin handles it."""
    for extractor in extractors:
        if extractor.matches(path):
            return extractor
    return None


def build(root, check, stream=None, scoper=None, extractors=None):
    """Map every symbol to its owning unit and every reference site back to it.

    A symbol two units both define is ambiguous, not decided by directory
    order: report it and leave it unowned, because crediting one claimant makes
    every reference to it a false edge between the two.
    """
    scoper = scoper or EmacsScoper(check)
    extractors = extractors or [ElispExtractor(check)]
    units = scoper.units(root)

    claimed, by_file = {}, {}
    for name, unit in units.items():
        for file in unit.files:
            extractor = pick(extractors, file)
            if extractor is None:
                continue
            defined = extractor.definitions(file)
            by_file[file.resolve()] = defined
            for symbol in defined:
                claimed.setdefault(symbol, set()).add(name)
        for symbol in unit.public:
            claimed.setdefault(symbol, set()).add(name)

    owners, conflicts = {}, {}
    for symbol, names in claimed.items():
        if len(names) > 1:
            conflicts[symbol] = sorted(names)
        else:
            owners[symbol] = next(iter(names))
    stream = sys.stderr if stream is None else stream
    for symbol in sorted(conflicts):
        print(f'warning: {symbol} is claimed by {", ".join(conflicts[symbol])}; '
              'it stays unowned and out of every scope', file=stream)

    refs = {}
    for name, unit in units.items():
        for file in unit.files:
            extractor = pick(extractors, file)
            if extractor is None:
                continue
            for symbol, line in extractor.references(file):
                if symbol in owners:
                    refs.setdefault(symbol, []).append((name, file, line))
    return Graph(units, owners, refs, conflicts, by_file)


def consumers_of_symbol(graph, symbol):
    """Return the owner of SYMBOL and the other units that reference it."""
    provider = graph.owners.get(symbol)
    if not provider:
        return None, {}
    found = {}
    for name, file, line in graph.refs.get(symbol, ()):
        if name != provider:
            found.setdefault(name, []).append((file, line))
    return provider, found


def scope_for_package(graph, target):
    """Symbols of TARGET that another unit references, grouped by consumer."""
    own_symbols = {s for s, name in graph.owners.items() if name == target}
    result = {}
    for symbol in sorted(own_symbols):
        for name, file, line in graph.refs.get(symbol, ()):
            if name != target:
                result.setdefault(name, {}).setdefault(symbol, []).append((file, line))
    return result


# --- planning -----------------------------------------------------------

class Impact(NamedTuple):
    """What one unit must redo, and the evidence that put it in scope."""
    unit: str
    levels: tuple
    reasons: tuple


def plan_scope(graph, changed_paths):
    """Group the affected units by level for a set of changed files.

    L1 and L2 for a unit that changed or that references a changed symbol,
    because either can alter behavior its tests observe. L1 only for a unit
    that merely requires a changed unit: its .elc may be stale, its behavior
    cannot be.
    """
    changed = {Path(path).resolve() for path in changed_paths}
    impacts, touched, symbols = {}, set(), set()

    for name, unit in graph.units.items():
        hit = [file for file in unit.files if file.resolve() in changed]
        if not hit:
            continue
        touched.add(name)
        impacts[name] = Impact(name, LEVELS, ('changed',))
        for file in hit:
            symbols.update(graph.by_file.get(file.resolve(), ()))

    for symbol in sorted(symbols):
        provider = graph.owners.get(symbol)
        if provider is None:
            continue
        for name, _file, _line in graph.refs.get(symbol, ()):
            if name == provider:
                continue
            _add_consumer(impacts, name, f'uses {symbol}')

    return _add_transitive(graph, impacts, touched)


def plan_for_symbol(graph, symbol):
    """The affected units for a symbol change, without assuming its file."""
    provider = graph.owners.get(symbol)
    if provider is None:
        return None
    impacts = {provider: Impact(provider, LEVELS, ('changed',))}
    for name, _file, _line in graph.refs.get(symbol, ()):
        if name == provider:
            continue
        _add_consumer(impacts, name, f'uses {symbol}')
    return _add_transitive(graph, impacts, {provider})


def _add_consumer(impacts, name, reason):
    """Record that NAME references a changed symbol, keeping L1 and L2."""
    prior = impacts.get(name)
    if prior is None:
        impacts[name] = Impact(name, LEVELS, (reason,))
    elif reason not in prior.reasons:
        impacts[name] = prior._replace(reasons=prior.reasons + (reason,))


def _add_transitive(graph, impacts, changed_units):
    """Units that merely require a changed unit need a compile, not a test."""
    for name, unit in graph.units.items():
        if name in impacts:
            continue
        shared = unit.requires & changed_units
        if shared:
            impacts[name] = Impact(name, ('L1',), (f'transitive: {sorted(shared)[0]}',))
    return impacts


def execution_layers(graph, names):
    """Group NAMES into dependency layers; units in one layer can run in parallel."""
    pending, layers = set(names), []
    while pending:
        ready = sorted(name for name in pending
                       if not (graph.units[name].requires & pending))
        if not ready:
            layers.append(sorted(pending))
            break
        layers.append(ready)
        pending.difference_update(ready)
    return layers


def execution_order(graph, names):
    """Dependencies first, so a failure stops before its consumers run."""
    return [name for layer in execution_layers(graph, names) for name in layer]


def owner_binary(root):
    """Return the Jujutsu binary that owns ROOT without mixing jjosh and jj."""
    repository = root / '.jj' / 'repo'
    # A secondary workspace stores a path to the owning repository here.
    if repository.is_file():
        target = Path(repository.read_text(encoding='utf-8').strip())
        repository = target if target.is_absolute() else (repository.parent / target).resolve()
    if repository.is_dir() and (repository / 'store' / 'git').is_dir():
        return 'jjosh'
    return 'jj'


def changed_from_rev(root, rev):
    """Files touched by REV inside ROOT.

    A Jujutsu checkout answers for its own change graph; a Git checkout answers
    through its index. Both report paths relative to ROOT.
    """
    if (root / '.jj').is_dir():
        binary = owner_binary(root)
        if not shutil.which(binary):
            raise SystemExit(f'{binary} is not on PATH; it owns {root}')
        argv = [binary, '--no-pager', 'diff', '--name-only', '-r', rev]
        result = subprocess.run(argv, cwd=str(root), text=True, capture_output=True)
        source = f'{binary} diff'
    else:
        argv = ['git', '-C', str(root), 'diff', '--name-only', rev]
        result = subprocess.run(argv, text=True, capture_output=True)
        source = 'git diff'
    if result.returncode != 0:
        raise SystemExit(f'{source} in {root} failed: {result.stderr.strip()}')
    return [root / name for name in result.stdout.splitlines() if name.strip()]


def resolve_paths(root, paths):
    """Accept paths relative to ROOT or absolute."""
    return [(root / path if not path.is_absolute() else path).resolve() for path in paths]


# --- plugin: scoper -----------------------------------------------------

class EmacsScoper:
    """A directory with one root entry and lisp/ is one delivery unit."""
    name = 'emacs'

    def __init__(self, check):
        self.check = check

    def units(self, root):
        found = {}
        # One checkout keeps every unit under packages/; a tree of sibling
        # checkouts has them at the root. The scoper decides, not the engine.
        base = root / 'packages' if (root / 'packages').is_dir() else root
        for directory in sorted(base.iterdir()):
            if not directory.is_dir() or directory.name.startswith('.'):
                continue
            entries = list(directory.glob('*.el'))
            if len(entries) != 1:
                continue
            entry = entries[0]
            files = [entry] + sorted((directory / 'lisp').glob('*.el'))
            declared, _errors = self.check.declarations(entry)
            found[directory.name] = Unit(
                name=directory.name,
                root=directory,
                entry=entry,
                files=[file for file in files if file.is_file()],
                requires=set(self.check.required(entry) or ()),
                public=set(declared))
        return found


# --- plugin: extractor --------------------------------------------------

class ElispExtractor:
    """Elisp source: definitions and references with their line numbers."""
    name = 'elisp'

    def __init__(self, check):
        self.check = check

    def matches(self, path):
        return path.suffix == '.el'

    def definitions(self, path):
        text = path.read_text(errors='replace')
        masked = mask(text)
        found = {s for s in self.check.DEFINITION.findall(masked)
                 if not s.startswith(',')}
        # A bare `(defvar NAME)' only tells the byte compiler that NAME is
        # special; it defines nothing, so it must not claim ownership.
        declared_only = set(BARE_DEFVAR.findall(masked))
        defined = {s for s in self.check.DEFINITION.findall(
            BARE_DEFVAR.sub(' ', masked)) if not s.startswith(',')}
        found -= declared_only - defined
        found.update(self.check.struct_symbols(text))
        return found

    def references(self, path):
        text = mask(path.read_text(errors='replace'))
        for match in TOKEN.finditer(text):
            yield match.group(0), text.count("\n", 0, match.start()) + 1


# --- command line -------------------------------------------------------

def add_change_arguments(parser):
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--changed', nargs='+', type=Path,
                        help='changed files, relative to the root or absolute')
    source.add_argument('--rev', help='use git diff REV in a single-repository root')
    source.add_argument('--symbol', help='a symbol whose contract changed')
    parser.add_argument('--no-transitive', action='store_true',
                        help='omit units that only require a changed unit')


def collect_impacts(graph, root, args):
    """Pick the planning route the arguments asked for."""
    if getattr(args, 'symbol', None):
        impacts = plan_for_symbol(graph, args.symbol)
        if impacts is None:
            raise SystemExit(f'unknown symbol: {args.symbol}')
    else:
        impacts = plan_scope(graph, collect_changed(root, args))
    if getattr(args, 'no_transitive', False):
        impacts = {name: impact for name, impact in impacts.items()
                   if not all(reason.startswith('transitive:')
                              for reason in impact.reasons)}
    return impacts


def collect_changed(root, args):
    if getattr(args, 'rev', None):
        return changed_from_rev(root, args.rev)
    return resolve_paths(root, args.changed)


def print_plan(graph, impacts, root, as_json=False):
    order = execution_order(graph, impacts)
    if as_json:
        import json
        print(json.dumps([{'unit': name, 'levels': list(impacts[name].levels),
                           'reasons': list(impacts[name].reasons)} for name in order],
                         indent=2))
        return
    if not order:
        print('nothing to re-check: no unit owns a changed file')
        return
    width = max(len(name) for name in order)
    for name in order:
        impact = impacts[name]
        print(f'{name:<{width}}  {"+".join(impact.levels):<6}  {"; ".join(impact.reasons)}')
    human = [name for name in order if 'L2' in impacts[name].levels]
    print()
    print(f'{len(order)} unit(s): {len(human)} need tests, '
          f'{len(order) - len(human)} need a compile')


def _run_unit(unit, impact):
    """Run compile/test steps for one unit; return (name, error_or_none, output)."""
    steps = []
    if 'L1' in impact.levels:
        steps.append(['make', '-C', str(unit.root), 'compile'])
    if 'L2' in impact.levels:
        steps.append(['make', '-C', str(unit.root), 'test'])
    for step in steps:
        rendered = ' '.join(step)
        print(f'run: {rendered}', flush=True)
        result = subprocess.run(step, text=True, capture_output=True)
        if result.returncode != 0:
            detail = (result.stdout[-2000:] + '\n' + result.stderr[-2000:]).strip()
            return unit.name, f'{unit.name}: {rendered} exited {result.returncode}', detail
    return unit.name, None, ''


def run_plan(graph, impacts, assume_yes=False, jobs=1):
    """Compile then test each unit in dependency order, optionally parallel per layer."""
    layers = execution_layers(graph, impacts)
    order = [name for layer in layers for name in layer]
    if not assume_yes:
        for name in order:
            unit, impact = graph.units[name], impacts[name]
            if 'L1' in impact.levels:
                print(f'would run: make -C {unit.root} compile')
            if 'L2' in impact.levels:
                print(f'would run: make -C {unit.root} test')
        print('\n(dry run; pass --yes to execute)')
        return 0
    failures = []
    workers = max(1, int(jobs))
    for layer in layers:
        if workers == 1 or len(layer) == 1:
            for name in layer:
                _name, error, detail = _run_unit(graph.units[name], impacts[name])
                if error:
                    if detail:
                        print(detail, file=sys.stderr)
                    failures.append(error)
                    break
        else:
            with concurrent.futures.ThreadPoolExecutor(max_workers=min(workers, len(layer))) as pool:
                futures = [pool.submit(_run_unit, graph.units[name], impacts[name]) for name in layer]
                for future in concurrent.futures.as_completed(futures):
                    _name, error, detail = future.result()
                    if error:
                        if detail:
                            print(detail, file=sys.stderr)
                        failures.append(error)
        if failures:
            break
    if failures:
        print('\n'.join(sorted(failures)), file=sys.stderr)
        return 1
    print(f'ok: {len(order)} unit(s) passed')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="workspace root (default: the checkout holding this script)")
    sub = parser.add_subparsers(dest="command", required=True)

    impact = sub.add_parser("impact", help="units affected by a package or symbol change")
    impact.add_argument("--package")
    impact.add_argument("--symbol")

    compare = sub.add_parser("compare", help="symbol-level scope beside package-level scope")
    compare.add_argument("--package", required=True)

    sub.add_parser("stats", help="graph size and per-unit reference counts")
    sub.add_parser("plugins", help="the extractor and scoper currently in use")

    order_cmd = sub.add_parser("order", help="all units in dependency order (providers first)")
    order_cmd.add_argument("--layers", action="store_true",
                           help="print one parallelizable dependency layer per line")

    plan = sub.add_parser("plan", help="what to re-check for a set of changed files")
    add_change_arguments(plan)
    plan.add_argument("--json", action="store_true", help="machine-readable output")

    run = sub.add_parser("run", help="execute the plan: compile then test")
    add_change_arguments(run)
    run.add_argument("--yes", action="store_true", help="actually execute; default is a dry run")
    run.add_argument("--jobs", type=int, default=1,
                     help="parallel workers within each dependency layer (default: 1)")

    args = parser.parse_args()
    root = args.root.resolve()
    check = load_check()

    if args.command == "plugins":
        print(f'scoper     {EmacsScoper.name}')
        print(f'extractor  {ElispExtractor.name}')
        return 0

    if args.command == "order":
        # Ordering needs only each unit's declared requirements, not the
        # symbol graph, so it skips extraction and stays cheap enough for
        # every Makefile recipe that iterates packages.
        graph = Graph(EmacsScoper(check).units(root), {}, {}, {}, {})
        if args.layers:
            for layer in execution_layers(graph, graph.units):
                print(' '.join(layer))
        else:
            for name in execution_order(graph, graph.units):
                print(name)
        return 0

    graph = build(root, check)

    if args.command == "stats":
        print(f"packages       {len(graph.units)}")
        print(f"symbols owned  {len(graph.owners)}")
        print(f"symbols public {sum(len(value) for value in graph.public.values())}")
        print(f"references     {sum(len(value) for value in graph.refs.values())}")
        return 0

    if args.command == "plan":
        impacts = collect_impacts(graph, root, args)
        print_plan(graph, impacts, root, as_json=args.json)
        return 0

    if args.command == "run":
        impacts = collect_impacts(graph, root, args)
        print_plan(graph, impacts, root)
        print()
        return run_plan(graph, impacts, assume_yes=args.yes, jobs=args.jobs)

    if args.command == "impact":
        if args.symbol:
            if args.symbol in graph.conflicts:
                print(f"ambiguous symbol: {args.symbol} is claimed by "
                      f"{', '.join(graph.conflicts[args.symbol])}", file=sys.stderr)
                return 2
            provider, found = consumers_of_symbol(graph, args.symbol)
            if provider is None:
                print(f"unknown symbol: {args.symbol}", file=sys.stderr)
                return 2
            print(f"{args.symbol}  owned by {provider}")
            for name in sorted(found):
                sites = found[name]
                print(f"  {name:<16} {len(sites)} site(s)")
                for file, line in sites[:3]:
                    print(f"      {file.relative_to(root)}:{line}")
            if not found:
                print("  (no external consumer)")
            return 0

        target = args.package
        if target not in graph.units:
            print(f"unknown package: {target}", file=sys.stderr)
            return 2
        scope = scope_for_package(graph, target)
        print(f"symbol-level consumers of {target}: {len(scope)}")
        for name in sorted(scope, key=lambda consumer: -len(scope[consumer])):
            symbols = scope[name]
            used = sum(len(value) for value in symbols.values())
            print(f"  {name:<16} {len(symbols)} symbol(s), {used} site(s)")
        return 0

    target = args.package
    if target not in graph.units:
        print(f"unknown package: {target}", file=sys.stderr)
        return 2
    scope = scope_for_package(graph, target)
    by_package = {name for name, deps in graph.requires.items() if target in deps}
    print(f"package-level dependents of {target}: {len(by_package)}")
    for name in sorted(by_package):
        marker = "" if name in scope else "   (never touches its symbols)"
        print(f"  {name}{marker}")
    print()
    print(f"symbol-level consumers of {target}: {len(scope)}")
    for name in sorted(scope):
        print(f"  {name}  ({len(scope[name])} symbols)")
    print()
    saved = len(by_package) - len(scope)
    if saved > 0:
        print(f"symbol scope is {saved} package(s) smaller than package scope")
    return 0


if __name__ == "__main__":
    sys.exit(main())
