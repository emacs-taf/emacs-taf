"""Command contract of workspace.py seal-sync in a throwaway jj workspace."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('workspace', ROOT / 'scripts/workspace.py')
WORKSPACE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKSPACE)


@unittest.skipUnless(shutil.which('jj'), 'seal-sync operates jj checkouts')
class SealSyncTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        base = Path(temp.name)
        (base / 'jj.toml').write_text('[user]\nname = "Test"\nemail = "test@example.invalid"\n')
        self.env = dict(os.environ, JJ_CONFIG=str(base / 'jj.toml'))
        self.root = base / 'workspace'
        self.child = self.root / 'pkg'
        for rel in ('scripts/workspace.py', *WORKSPACE.SHARED):
            self.write(self.root / rel, (ROOT / rel).read_text())
        self.write(self.root / '.gitignore', '/pkg/\n')
        self.write(self.root / 'workspace.json', json.dumps({'repositories': {'pkg': {
            'url': 'https://example.invalid/pkg.git', 'revision': '0', 'branch': 'main'}}}))
        self.write(self.child / '.gitignore', '*.elc\n__pycache__/\n')
        self.write(self.child / 'README.md', '# Package\n')
        self.write(self.child / 'package.el', ";;; Commentary:\n;; Function: package-open ()\n;; Return the package value.\n;;; Code:\n(defun package-open () t)\n(provide 'package)\n")
        self.write(self.child / 'tests/public-tests.el', '(ert-deftest public-roundtrip () (should t))\n')
        self.write(self.child / 'tests/acceptance.json', '{"cases": [{"name": "public-roundtrip", "file": "tests/public-tests.el", "purpose": "roundtrip"}]}')
        self.write(self.child / 'Makefile', 'compile:\ntest:\ncheck: structure-check acceptance api-check\nclean:\nstructure-check:\nsetup-hooks:\n')
        self.jj(self.child, 'git', 'init')
        self.assertEqual(0, self.workspace('sync').returncode)
        self.jj(self.root, 'git', 'init')
        self.jj(self.root, 'commit', '-m', 'chore: add the workspace tooling')
        # The child is published once, then gains another session's commit.
        subprocess.run(['git', 'init', '-q', '--bare', str(base / 'remote.git')], check=True)
        self.jj(self.child, 'git', 'remote', 'add', 'aliyun', str(base / 'remote.git'))
        self.jj(self.child, 'commit', '-m', 'feat: add the package')
        self.jj(self.child, 'bookmark', 'create', 'main', '-r', '@-')
        self.jj(self.child, 'git', 'push', '--remote', 'aliyun', '-b', 'main')
        self.write(self.child / 'README.md', '# Package\n\nOther work.\n')
        self.jj(self.child, 'commit', '-m', 'docs: describe the package')

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def jj(self, repo, *args):
        return subprocess.run(['jj', *args], cwd=repo, env=self.env, text=True,
                              capture_output=True, check=True).stdout

    def workspace(self, *args):
        return subprocess.run([sys.executable, str(self.root / 'scripts/workspace.py'), *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def change_root_tooling(self, commit=True):
        self.write(self.root / '.editorconfig', (self.root / '.editorconfig').read_text() + '# changed\n')
        if commit:
            self.jj(self.root, 'commit', '-m', 'chore: tighten the editor settings')

    def child_log(self):
        return self.jj(self.child, 'log', '--no-graph', '-r', '::@-', '-T', 'description.first_line() ++ "\\n"')

    def test_seals_only_shared_copies_and_names_other_unpublished_work(self):
        self.change_root_tooling()
        self.assertEqual(0, self.workspace('sync').returncode)
        # Another session's unfinished work, including a file that would fail
        # the structure check, stays in the working copy.
        self.write(self.child / 'README.md', '# Package\n\nUnfinished edit.\n')
        self.write(self.child / 'notes.md', '# Notes\n')
        preview = self.workspace('seal-sync', '--dry-run')
        self.assertEqual(0, preview.returncode, preview.stderr)
        self.assertIn('pkg: would seal .editorconfig', preview.stdout)
        self.assertNotIn(WORKSPACE.SEAL_TITLE, self.child_log())
        result = self.workspace('seal-sync')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('pkg: sealed', result.stdout)
        self.assertIn('also publishes other unpublished work', result.stdout)
        self.assertIn('docs: describe the package', result.stdout)
        sealed = self.jj(self.child, 'log', '--no-graph', '-r', '@-', '-T', 'description')
        self.assertTrue(sealed.startswith(WORKSPACE.SEAL_TITLE + '\n'))
        self.assertIn('chore: tighten the editor settings', sealed)
        self.assertEqual(['.editorconfig'], self.jj(self.child, 'diff', '-r', '@-', '--name-only').split())
        self.assertEqual(['README.md', 'notes.md'], self.jj(self.child, 'diff', '-r', '@', '--name-only').split())
        self.write(self.root.parent / 'message', sealed)
        checker = subprocess.run([sys.executable, str(self.root / 'scripts/check-commit-message.py'),
                                  str(self.root.parent / 'message')], text=True, capture_output=True)
        self.assertEqual(0, checker.returncode, checker.stdout + checker.stderr)
        again = self.workspace('seal-sync')
        self.assertIn('pkg: shared tooling already sealed', again.stdout)

    def test_refuses_uncommitted_root_tooling_and_drift_without_committing(self):
        before = self.child_log()
        self.change_root_tooling(commit=False)
        self.assertEqual(0, self.workspace('sync').returncode)
        result = self.workspace('seal-sync')
        self.assertEqual(1, result.returncode)
        self.assertIn('commit the root tooling first', result.stderr)
        self.jj(self.root, 'commit', '-m', 'chore: tighten the editor settings')
        self.change_root_tooling()
        result = self.workspace('seal-sync')
        self.assertEqual(1, result.returncode)
        self.assertIn('pkg/.editorconfig: shared tooling drift', result.stderr)
        self.assertIn('nothing sealed', result.stderr)
        self.assertEqual(before, self.child_log())

    def test_reverts_a_seal_whose_commit_fails_the_structure_check(self):
        self.write(self.child / 'docs/notes.md', '# Notes\n')
        self.jj(self.child, 'commit', '-m', 'docs: add notes')
        before = self.child_log()
        self.change_root_tooling()
        self.assertEqual(0, self.workspace('sync').returncode)
        result = self.workspace('seal-sync')
        self.assertEqual(1, result.returncode)
        self.assertIn('fails the structure check', result.stderr)
        self.assertIn('pkg: reverted the seal; the copies stay uncommitted', result.stderr)
        self.assertEqual(before, self.child_log())
        self.assertEqual(['.editorconfig'], self.jj(self.child, 'diff', '-r', '@', '--name-only').split())


if __name__ == '__main__':
    unittest.main()
