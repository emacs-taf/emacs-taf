"""Scope graph of scripts/refscope.py: ownership, references and conflicts."""
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('refscope', ROOT / 'scripts/refscope.py')
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
CHECK = VERIFY.load_check()


class Fixture(unittest.TestCase):
    """A temporary workspace with minimal Emacs packages in it."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def package(self, name, body='', requires=(), extra=()):
        """Write one minimal package that declares NAME-open as its public API."""
        lines = [f';;; {name}.el --- test fixture', '']
        if requires:
            lines += [';; Package-Requires: ' + ' '.join(f'({r} "0.1")' for r in requires), '']
        lines += [';;; Commentary:', '',
                  f';; Function: {name}-open ()',
                  f';; Return the {name} open value.', '',
                  ';;; Code:', '', f'(defun {name}-open () t)']
        if body:
            lines += ['', body.rstrip('\n')]
        lines += ['', f"(provide '{name})", f';;; {name}.el ends here', '']
        self.write(self.root / name / f'{name}.el', '\n'.join(lines))
        for relative, text in extra:
            self.write(self.root / name / relative, text)

    def build(self, stream=None):
        return VERIFY.build(self.root, CHECK, stream=io.StringIO() if stream is None else stream)


class WorkspaceTests(Fixture):
    def test_owners_come_from_the_root_entry_and_its_lisp_files(self):
        self.package('base', extra=[('lisp/base-extra.el', '(defun base-grow () t)\n')])
        self.package('app')
        graph = self.build()
        self.assertEqual('base', graph.owners['base-open'])
        self.assertEqual('base', graph.owners['base-grow'])
        self.assertEqual({'base', 'app'}, set(graph.public))

    def test_cross_package_reference_is_reverse_indexed(self):
        self.package('base')
        self.package('app', body='(defun app-use () (base-open))')
        graph = self.build()
        provider, consumers = VERIFY.consumers_of_symbol(graph, 'base-open')
        self.assertEqual('base', provider)
        self.assertEqual(['app'], list(consumers))
        file, line = consumers['app'][0]
        self.assertEqual('app.el', file.name)
        self.assertIn('base-open', file.read_text(encoding='utf-8').splitlines()[line - 1])
        self.assertEqual({'app'}, set(VERIFY.scope_for_package(graph, 'base')))

    def test_symbol_two_packages_claim_stays_unowned_and_warns(self):
        self.package('alpha', body='(defun shared-thing () t)')
        self.package('beta', body='(defun shared-thing () t)\n(defun beta-use () (shared-thing))')
        warnings = io.StringIO()
        graph = self.build(stream=warnings)
        self.assertNotIn('shared-thing', graph.owners)
        self.assertEqual(['alpha', 'beta'], graph.conflicts['shared-thing'])
        text = warnings.getvalue()
        self.assertIn('warning', text)
        self.assertIn('shared-thing', text)
        self.assertIn('alpha', text)
        self.assertIn('beta', text)
        # The ambiguous symbol must not resurface in any query result.
        self.assertEqual((None, {}), VERIFY.consumers_of_symbol(graph, 'shared-thing'))
        self.assertEqual({}, VERIFY.scope_for_package(graph, 'alpha'))
        self.assertEqual({}, VERIFY.scope_for_package(graph, 'beta'))
        verify = subprocess.run([sys.executable, str(ROOT / 'scripts/refscope.py'),
                                 '--root', str(self.root), 'impact', '--symbol', 'shared-thing'],
                                text=True, capture_output=True)
        self.assertEqual(2, verify.returncode)
        self.assertIn('ambiguous symbol: shared-thing', verify.stderr)

    def test_compare_reports_package_level_and_symbol_level_counts(self):
        self.package('base')
        self.package('app', requires=['base'], body='(defun app-use () (base-open))')
        self.package('peer', requires=['base'])
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/refscope.py'),
                                 '--root', str(self.root), 'compare', '--package', 'base'],
                                text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('package-level dependents of base: 2', result.stdout)
        self.assertIn('symbol-level consumers of base: 1', result.stdout)
        self.assertIn('peer   (never touches its symbols)', result.stdout)


class PlanningTests(Fixture):
    """plan and run turn a change into an ordered, graded workload."""

    def cli(self, *args):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/refscope.py'),
                               '--root', str(self.root), *args],
                              text=True, capture_output=True)

    def test_plugin_list_names_the_scoper_and_extractor(self):
        result = self.cli('plugins')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('scoper', result.stdout)
        self.assertIn('emacs', result.stdout)
        self.assertIn('extractor', result.stdout)
        self.assertIn('elisp', result.stdout)

    def test_plan_for_a_changed_file_grades_the_owner_and_its_consumers(self):
        self.package('base')
        self.package('user', requires=['base'], body='(defun user-go () (base-open))')
        self.package('peer', requires=['base'])
        result = self.cli('plan', '--changed', str(self.root / 'base' / 'base.el'))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('base', result.stdout)
        self.assertIn('L1+L2', result.stdout)
        self.assertIn('uses base-open', result.stdout)
        self.assertIn('transitive: base', result.stdout)
        # The consumer needs tests, the uninvolved dependent only a compile.
        self.assertIn('3 unit(s)', result.stdout)
        self.assertIn('2 need tests, 1 need a compile', result.stdout)

    def test_plan_for_a_symbol_names_the_provider_and_each_user(self):
        self.package('base')
        self.package('user', body='(defun user-go () (base-open))')
        self.package('idle')
        result = self.cli('plan', '--symbol', 'base-open')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('base', result.stdout)
        self.assertIn('uses base-open', result.stdout)
        self.assertNotIn('idle', result.stdout)

    def test_no_transitive_drops_units_that_merely_require_the_owner(self):
        self.package('base')
        self.package('peer', requires=['base'])
        result = self.cli('plan', '--symbol', 'base-open', '--no-transitive')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn('peer', result.stdout)
        self.assertIn('1 unit(s)', result.stdout)

    def test_run_without_yes_only_prints_the_commands(self):
        self.package('base')
        result = self.cli('run', '--symbol', 'base-open', '--no-transitive')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('would run: make -C', result.stdout)
        self.assertIn('compile', result.stdout)
        self.assertIn('dry run', result.stdout)
        self.assertNotIn('run: make', result.stdout.replace('would run: make', ''))

    def test_rev_reads_the_change_graph_of_the_checkout(self):
        self.package('base')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '-A'], check=True)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.email=t@example.com',
                        '-c', 'user.name=Tester', 'commit', '-qm', 'init'], check=True)
        entry = self.root / 'base' / 'base.el'
        entry.write_text(entry.read_text() + '\n(defun base-extra () t)\n', encoding='utf-8')
        result = self.cli('plan', '--rev', 'HEAD')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('base', result.stdout)
        self.assertIn('1 unit(s)', result.stdout)

    def test_unknown_symbol_is_reported_not_silently_empty(self):
        self.package('base')
        result = self.cli('plan', '--symbol', 'nope-does-not-exist')
        self.assertNotEqual(0, result.returncode)
        self.assertIn('unknown symbol', result.stderr)


if __name__ == '__main__':
    unittest.main()
