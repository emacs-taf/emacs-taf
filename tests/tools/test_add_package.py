"""Contract of scripts/add-package.py: the steps it plans and the names it refuses."""
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('add_package', ROOT / 'scripts/add-package.py')
add_package = importlib.util.module_from_spec(SPEC)
sys.modules['add_package'] = add_package
SPEC.loader.exec_module(add_package)


class ArgumentTests(unittest.TestCase):
    def call(self, *arguments):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/add-package.py'), *arguments],
                              capture_output=True, text=True, timeout=60, cwd=ROOT)

    def test_a_name_that_is_already_a_package_is_refused(self):
        result = self.call('etaf', '--url', 'https://example.invalid/etaf.git', '--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)

    def test_a_name_that_is_not_a_package_name_is_refused(self):
        result = self.call('../escape', '--url', 'https://example.invalid/x.git', '--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a package name', result.stderr)

    def test_dry_run_plans_every_step_without_touching_the_registry(self):
        registry = ROOT / 'workspace.json'
        before = registry.read_text(encoding='utf-8')
        result = self.call('etaf-probe-unit', '--url',
                           'https://example.invalid/etaf-probe-unit.git', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        # A unit is registered, given a remote, fetched, and checked out as the
        # working copy before its directory can hold anything.
        for fragment in ('project add etaf-probe-unit',
                         'git remote add origin https://example.invalid/etaf-probe-unit.git',
                         'git fetch --project etaf-probe-unit',
                         'new @ main#etaf-probe-unit@origin',
                         'register etaf-probe-unit in workspace.json'):
            self.assertIn(fragment, result.stdout)
        self.assertEqual(registry.read_text(encoding='utf-8'), before)


class RegistryTests(unittest.TestCase):
    def test_a_new_name_becomes_a_registry_entry(self):
        document = {'schema': 2, 'packages': {'etaf': {'url': 'u', 'branch': 'main'}}}
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'workspace.json'
            path.write_text(json.dumps(document), encoding='utf-8')
            original = add_package.ROOT
            add_package.ROOT = Path(work)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    add_package.register('etaf-probe', 'https://example.invalid/x.git',
                                         'main', 'application', False)
                written = json.loads(path.read_text(encoding='utf-8'))
            finally:
                add_package.ROOT = original
        self.assertEqual(written['packages']['etaf-probe'],
                         {'url': 'https://example.invalid/x.git',
                          'branch': 'main', 'role': 'application'})
        self.assertIn('etaf', written['packages'])


if __name__ == '__main__':
    unittest.main()
