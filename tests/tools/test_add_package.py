"""Contract of scripts/add-package.py: layered placement and registry rules."""
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
        result = self.call('etaf', '--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)

    def test_a_name_that_is_not_a_package_name_is_refused(self):
        result = self.call('../escape', '--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a package name', result.stderr)

    def test_dry_run_places_application_under_apps_without_touching_registry(self):
        registry = ROOT / 'workspace.json'
        before = registry.read_text(encoding='utf-8')
        result = self.call('etaf-probe-unit', '--repo', 'emacs-taf/etaf-probe-unit', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('would create apps/etaf-probe-unit/', result.stdout)
        self.assertIn('register etaf-probe-unit at apps/etaf-probe-unit in workspace.json as application',
                      result.stdout)
        self.assertEqual(registry.read_text(encoding='utf-8'), before)

    def test_dry_run_places_extension_under_core_packages(self):
        result = self.call('etaf-probe-ext', '--role', 'extension', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('would create core/packages/etaf-probe-ext/', result.stdout)
        self.assertIn('as extension', result.stdout)

    def test_dry_run_places_game_under_games(self):
        result = self.call('etaf-probe-game', '--role', 'game', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('would create games/etaf-probe-game/', result.stdout)


class RegistryTests(unittest.TestCase):
    def test_a_new_name_becomes_a_layered_registry_entry(self):
        document = {'schema': 3, 'packages': {'etaf': {'path': 'core/packages/etaf', 'role': 'framework'}}}
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'workspace.json'
            path.write_text(json.dumps(document), encoding='utf-8')
            original = add_package.ROOT
            add_package.ROOT = Path(work)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    add_package.register('etaf-probe', '', 'main', 'application', False,
                                         repo='emacs-taf/etaf-probe')
                written = json.loads(path.read_text(encoding='utf-8'))
            finally:
                add_package.ROOT = original
        self.assertEqual(written['packages']['etaf-probe'], {
            'path': 'apps/etaf-probe',
            'role': 'application',
            'branch': 'main',
            'repo': 'emacs-taf/etaf-probe',
            'url': 'https://github.com/emacs-taf/etaf-probe.git',
        })
        self.assertIn('etaf', written['packages'])


if __name__ == '__main__':
    unittest.main()
