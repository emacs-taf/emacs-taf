"""Command contract of changes.py: seal one cross-repository change, then publish it."""
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


@unittest.skipUnless(shutil.which('jj'), 'changes.py operates jj checkouts')
class ChangesTests(unittest.TestCase):
    """A workspace of two dependent packages and one bare mirror per remote."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        (self.base / 'jj.toml').write_text('[user]\nname = "Test"\nemail = "test@example.invalid"\n')
        self.env = dict(os.environ, JJ_CONFIG=str(self.base / 'jj.toml'))
        self.root = self.base / 'workspace'
        self.copy_root_tooling()
        self.write_child('base', '')
        self.write_child('app', ' (base "0.1.0")')
        # An application keeps the provider registry its own boundary check sees.
        self.write(self.root / 'app/scripts/api-workspace.json', json.dumps({
            'base': {'entry': 'base', 'url': 'https://example.invalid/base.git'}},
            indent=2) + '\n')
        self.write(self.root / 'README.md', '# Workspace\n\nThe integration checkpoint.\n')
        self.write(self.root / 'AGENTS.md', '# Instructions\n\nStart from this directory.\n')
        self.write(self.root / 'docs/architecture.zh-CN.md', '# 架构\n\n跨包契约。\n')
        self.write(self.root / 'Makefile', self.root_makefile())
        self.write(self.root / 'tests/tools/test_sample.py',
                   'import unittest\n\n\nclass Sample(unittest.TestCase):\n'
                   '    def test_nothing(self):\n        self.assertTrue(True)\n\n\n'
                   "if __name__ == '__main__':\n    unittest.main()\n")
        self.write(self.root / '.gitignore', '/app/\n/base/\n__pycache__/\n*.pyc\n')
        # The application is registered first, so only the provider edge can
        # order the seal.
        self.write(self.root / 'workspace.json', json.dumps({'schema': 1, 'repositories': {
            'app': self.record('app', 'application'),
            'base': self.record('base', 'framework')}}, indent=2) + '\n')
        for name in ('app', 'base'):
            self.jj(self.root / name, 'git', 'init')
        self.assertEqual(0, self.workspace('sync').returncode)
        for name in ('app', 'base'):
            self.seal_initial(name)
        self.write(self.root / 'workspace.json', json.dumps({'schema': 1, 'repositories': {
            'app': self.record('app', 'application'),
            'base': self.record('base', 'framework')}}, indent=2) + '\n')
        self.jj(self.root, 'git', 'init')
        self.jj(self.root, 'commit', '-m', 'chore: register the checkouts')
        self.publish_initial(self.root, 'workspace')

    # ------------------------------------------------------------------ setup

    def copy_root_tooling(self):
        for rel in ('scripts/workspace.py', 'scripts/changes.py',
                    *WORKSPACE.SHARED, *WORKSPACE.FRAMEWORK_SHARED):
            self.write(self.root / rel, (ROOT / rel).read_text())

    def write_child(self, name, requirement):
        child = self.root / name
        self.write(child / f'{name}.el',
                   f';;; {name}.el --- the {name} package  -*- lexical-binding: t; -*-\n\n'
                   ';; Version: 0.1.0\n'
                   f';; Package-Requires: ((emacs "29.1"){requirement})\n\n'
                   ';;; Commentary:\n'
                   f';; Function: {name}-value ()\n'
                   f';; Return the value of {name}.\n'
                   ';;; Code:\n\n'
                   f'(defun {name}-value () :{name})\n'
                   f"(provide '{name})\n"
                   f';;; {name}.el ends here\n')
        self.write(child / f'lisp/{name}-util.el',
                   f';;; {name}-util.el --- helpers  -*- lexical-binding: t; -*-\n\n'
                   ';;; Commentary:\n;; The implementation module.\n;;; Code:\n\n'
                   f'(defun {name}-util () :util)\n'
                   f"(provide '{name}-util)\n"
                   f';;; {name}-util.el ends here\n')
        self.write(child / 'README.md', f'# {name}\n\nInstall and require it.\n')
        self.write(child / 'tests/public-tests.el',
                   f'(ert-deftest {name}-roundtrip ()\n  (should (eq ({name}-value) :{name})))\n')
        self.write(child / 'tests/acceptance.json', json.dumps({'cases': [{
            'name': f'{name}-roundtrip', 'file': 'tests/public-tests.el',
            'purpose': 'the entry returns its value'}]}))
        self.write(child / 'Makefile', self.package_makefile())
        self.write(child / '.gitignore', '*.elc\n__pycache__/\n')

    def root_makefile(self):
        return ('.DEFAULT_GOAL := check\n.PHONY: compile test check clean structure-check '
                'setup-hooks\ncompile:\ntest:\ncheck: structure-check\nstructure-check:\n'
                '\tpython3 scripts/check-repository.py\nclean:\nsetup-hooks:\n')

    def package_makefile(self):
        return ('compile:\ntest:\ncheck: structure-check acceptance api-check\nclean:\n'
                'structure-check:\n\tpython3 scripts/check-repository.py\nsetup-hooks:\n')

    def record(self, name, role):
        return {'url': f'https://example.invalid/{name}.git',
                'revision': self.revision(name, 'main') or '0' * 40,
                'branch': 'main', 'role': role}

    def seal_initial(self, name):
        self.jj(self.root / name, 'commit', '-m', f'feat: add the {name} package')
        self.publish_initial(self.root / name, name)

    def publish_initial(self, checkout, name):
        for remote in ('aliyun', 'origin'):
            bare = self.base / 'remotes' / f'{name}-{remote}.git'
            if not bare.exists():
                bare.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(['git', 'init', '-q', '--bare', str(bare)], check=True)
            self.jj(checkout, 'git', 'remote', 'add', remote, str(bare))
        self.jj(checkout, 'bookmark', 'create', 'main', '-r', '@-')
        for remote in ('aliyun', 'origin'):
            self.jj(checkout, 'bookmark', 'track', f'main@{remote}')
            self.jj(checkout, 'git', 'push', '--remote', remote, '-b', 'main')

    # ----------------------------------------------------------------- helpers

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def jj(self, repo, *args):
        result = subprocess.run(['jj', *args], cwd=repo, env=self.env, text=True,
                                capture_output=True)
        if result.returncode:
            raise AssertionError(f'jj {" ".join(args)} failed in {repo}:\n'
                                 + result.stdout + result.stderr)
        return result.stdout

    def workspace(self, *args):
        return subprocess.run([sys.executable, str(self.root / 'scripts/workspace.py'), *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def changes(self, *args):
        return subprocess.run([sys.executable, str(self.root / 'scripts/changes.py'), *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def change(self, name, path='README.md'):
        target = (self.root if name == 'workspace' else self.root / name) / path
        self.write(target, target.read_text() + '\nAnother paragraph.\n')

    def message(self, body='The change spans both packages, so the provider is sealed first.'):
        path = self.base / 'message.txt'
        path.write_text(f'feat: coordinate the packages\n\n{body}\n')
        return path

    def revision(self, name, rev='@-'):
        checkout = self.root if name == 'workspace' else self.root / name
        return subprocess.run(['jj', 'log', '--no-graph', '-r', rev, '-T', 'commit_id'],
                              cwd=checkout, env=self.env, text=True, capture_output=True).stdout.strip()

    def description(self, name, rev='@-'):
        checkout = self.root if name == 'workspace' else self.root / name
        return self.jj(checkout, 'log', '--no-graph', '-r', rev, '-T', 'description')

    def unsealed(self, name):
        checkout = self.root if name == 'workspace' else self.root / name
        return self.jj(checkout, 'diff', '-r', '@', '--name-only').split()

    def pins(self):
        return {name: entry['revision']
                for name, entry in json.loads((self.root / 'workspace.json').read_text())
                ['repositories'].items()}

    def published(self, name, remote):
        """Return the commit NAME's branch names on REMOTE."""
        checkout = self.root if name == 'workspace' else self.root / name
        self.jj(checkout, 'git', 'fetch', '--remote', remote)
        return self.jj(checkout, 'log', '--no-graph', '-r', f'main@{remote}',
                       '-T', 'commit_id').strip()

    def diverge(self, name, remote):
        """Publish a foreign commit on REMOTE, as another checkout would."""
        bare = self.base / 'remotes' / f'{name}-{remote}.git'
        work = self.base / 'foreign' / f'{name}-{remote}'
        subprocess.run(['git', 'clone', '-q', str(bare), str(work)], check=True,
                       env=dict(self.env, GIT_AUTHOR_NAME='Other', GIT_AUTHOR_EMAIL='o@example.invalid',
                                GIT_COMMITTER_NAME='Other', GIT_COMMITTER_EMAIL='o@example.invalid'))
        (work / 'foreign.txt').write_text('elsewhere\n')
        subprocess.run(['git', '-C', str(work), 'add', 'foreign.txt'], check=True)
        subprocess.run(['git', '-C', str(work), 'commit', '-q', '-m', 'foreign work'], check=True)
        subprocess.run(['git', '-C', str(work), 'push', '-q', 'origin', 'HEAD:main'], check=True)

    # ------------------------------------------------------------------- tests

    def test_seals_providers_first_and_records_their_revisions(self):
        self.change('base')
        self.change('app')
        self.change('workspace')
        result = self.changes('commit', '-F', str(self.message()))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        order = [result.stdout.index(f'{name}: sealed') for name in ('base', 'app', 'workspace')]
        self.assertEqual(sorted(order), order, result.stdout)
        for name in ('base', 'app', 'workspace'):
            self.assertEqual([], self.unsealed(name), name)
            self.assertTrue(self.description(name).startswith(f'feat({name}): coordinate the packages'),
                            self.description(name))
        self.assertIn('\nRepo: app\nValidation: ', self.description('app'))
        self.assertIn('make -C app structure-check', self.description('app'))
        self.assertIn('tests/tools', self.description('workspace'))
        self.assertEqual(self.revision('base'), self.pins()['base'])
        self.assertEqual(self.revision('app'), self.pins()['app'])
        self.assertIn('workspace.json', self.jj(self.root, 'diff', '-r', '@-', '--name-only'))

    def test_failed_check_seals_nothing(self):
        self.change('base')
        self.write(self.root / 'app/docs/notes.md', '# Notes\n')
        before = {name: self.revision(name) for name in ('base', 'app', 'workspace')}
        result = self.changes('commit', '-F', str(self.message()))
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn('structure-check failed', result.stderr)
        for name, commit in before.items():
            self.assertEqual(commit, self.revision(name), name)
        self.assertEqual(['README.md'], self.unsealed('base'))
        self.assertEqual(before['base'], self.pins()['base'])
        self.assertEqual(['docs/notes.md'], self.unsealed('app'))

    def test_dry_run_reports_the_plan_without_sealing(self):
        self.change('base')
        self.change('app')
        self.change('workspace')
        before = {name: self.revision(name) for name in ('base', 'app', 'workspace')}
        result = self.changes('commit', '--dry-run', '-F', str(self.message()))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('app: README.md', result.stdout)
        self.assertIn('checks: make -C app structure-check', result.stdout)
        self.assertIn('feat(base): coordinate the packages', result.stdout)
        self.assertLess(result.stdout.index('--- base'), result.stdout.index('--- app'))
        for name, commit in before.items():
            self.assertEqual(commit, self.revision(name), name)
        self.assertIn('README.md', self.unsealed('app'))

    def test_refuses_to_seal_a_synced_shared_copy(self):
        self.change('app')
        self.write(self.root / 'app/.editorconfig',
                   (self.root / 'app/.editorconfig').read_text() + '# local edit\n')
        before = {name: self.revision(name) for name in ('app', 'workspace')}
        result = self.changes('commit', '-F', str(self.message()))
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn('app: unsealed shared tooling: .editorconfig', result.stderr)
        self.assertIn('workspace.py seal-sync delivers those copies', result.stderr)
        for name, commit in before.items():
            self.assertEqual(commit, self.revision(name), name)
        self.assertIn('shared tooling drift: app (1 file)', self.changes('status').stdout)

    def test_seals_a_rename_together_with_its_change(self):
        (self.root / 'base/lisp/base-util.el').rename(self.root / 'base/lisp/base-helper.el')
        result = self.changes('commit', '-F', str(self.message()))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual([], self.unsealed('base'))
        self.assertEqual(['lisp/base-helper.el'],
                         self.jj(self.root / 'base', 'diff', '-r', '@-', '--name-only').split())

    def test_only_limits_the_seal_to_the_named_checkouts(self):
        self.change('base')
        self.change('app')
        self.change('workspace')
        alone = self.changes('commit', '--only', 'workspace', '-F', str(self.message()))
        self.assertEqual(0, alone.returncode, alone.stdout + alone.stderr)
        self.assertEqual([], self.unsealed('workspace'))
        self.assertEqual(['README.md'], self.unsealed('app'))
        self.assertEqual(['README.md'], self.unsealed('base'))
        self.assertEqual(['README.md'], self.jj(self.root, 'diff', '-r', '@-', '--name-only').split())
        packages = self.changes('commit', '--only', 'app,base', '-F', str(self.message()))
        self.assertEqual(0, packages.returncode, packages.stdout + packages.stderr)
        self.assertLess(packages.stdout.index('base: sealed'), packages.stdout.index('app: sealed'))
        self.assertEqual(['workspace.json'],
                         self.jj(self.root, 'diff', '-r', '@-', '--name-only').split())
        self.assertEqual(self.revision('base'), self.pins()['base'])
        self.assertEqual(self.revision('app'), self.pins()['app'])

    def test_publish_is_idempotent(self):
        self.change('base')
        self.change('app')
        self.assertEqual(0, self.changes('commit', '-F', str(self.message())).returncode)
        preview = self.changes('publish', '--dry-run')
        self.assertEqual(0, preview.returncode, preview.stderr)
        self.assertEqual(self.revision('base', 'main'), self.published('base', 'aliyun'))
        result = self.changes('publish')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        for name in ('base', 'app', 'workspace'):
            for remote in ('aliyun', 'origin'):
                self.assertEqual(self.revision(name), self.published(name, remote), (name, remote))
        again = self.changes('publish')
        self.assertEqual(0, again.returncode, again.stdout + again.stderr)
        self.assertIn('already published', again.stdout)
        self.assertNotIn('pushed', again.stdout)

    def test_publish_refuses_a_divergent_mirror_and_blocks_consumers(self):
        self.change('base')
        self.change('app')
        self.assertEqual(0, self.changes('commit', '-F', str(self.message())).returncode)
        root = {name: self.published(name, 'origin') for name in ('base', 'app', 'workspace')}
        self.diverge('app', 'aliyun')
        result = self.changes('publish')
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn('app: cannot publish', result.stdout)
        self.assertIn('moved away', result.stdout)
        self.assertIn('workspace: cannot publish, unpublished dependency: app', result.stdout)
        self.assertIn('not published: app, workspace', result.stderr)
        self.assertEqual(root['app'], self.published('app', 'origin'))
        self.assertEqual(root['workspace'], self.published('workspace', 'origin'))

    def test_publish_resumes_with_only_the_remotes_left(self):
        self.change('base')
        self.change('app')
        self.assertEqual(0, self.changes('commit', '-F', str(self.message())).returncode)
        bare = self.base / 'remotes' / 'base-origin.git'
        bare.chmod(0o555)
        self.addCleanup(bare.chmod, 0o755)
        first = self.changes('publish')
        self.assertEqual(1, first.returncode, first.stdout + first.stderr)
        self.assertIn('base: push to origin failed', first.stdout)
        self.assertIn('not published: base, app, workspace', first.stderr)
        self.assertEqual(self.revision('base'), self.published('base', 'aliyun'))
        bare.chmod(0o755)
        second = self.changes('publish')
        self.assertEqual(0, second.returncode, second.stdout + second.stderr)
        retried = next(line for line in second.stdout.splitlines()
                       if line.startswith('base: main -> '))
        self.assertIn('pushed origin', retried)
        self.assertNotIn('aliyun', retried)
        for name in ('base', 'app', 'workspace'):
            for remote in ('aliyun', 'origin'):
                self.assertEqual(self.revision(name), self.published(name, remote), (name, remote))

    def test_status_reports_unsealed_work_and_stale_pins(self):
        clean = self.changes('status')
        self.assertEqual(0, clean.returncode, clean.stderr)
        self.assertIn('unsealed: nothing', clean.stdout)
        self.assertIn('stale pins: none', clean.stdout)
        self.change('app')
        self.change('base')
        pending = self.changes('status')
        self.assertIn('unsealed: app (1 file), base (1 file)', pending.stdout)
        self.assertIn('seal order: base, app', pending.stdout)
        self.write(self.root / 'workspace.json',
                   (self.root / 'workspace.json').read_text().replace(
                       self.pins()['base'], '1' * 40))
        self.assertIn('stale pins: base (records ' + '1' * 12, self.changes('status').stdout)


if __name__ == '__main__':
    unittest.main()
