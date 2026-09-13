"""Behavioral regressions for drift detection and staged-content checking."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('policy', ROOT / 'scripts/check-repository.py')
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for f in POLICY.SHARED:
            self.write(f, (ROOT / f).read_text())
        self.write('README.md', '# Package\n')
        self.write('package.el', ";;; Commentary:\n;; Function: package-open ()\n;; Return the package value.\n;;; Code:\n(defun package-open () t)\n(provide 'package)\n")
        self.write('tests/public-tests.el', '(ert-deftest public-roundtrip () (should t))\n')
        self.write('tests/acceptance.json', '{"cases": [{"name": "public-roundtrip", "file": "tests/public-tests.el", "purpose": "roundtrip"}]}')
        self.write('Makefile', 'compile:\ntest:\ncheck: structure-check acceptance api-check\nclean:\nstructure-check:\nsetup-hooks:\n')

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def errors(self): return '\n'.join(POLICY.check(self.root))

    def test_minimal_package_does_not_need_empty_documents(self):
        self.assertEqual('', self.errors())

    def test_workspace_cli_requires_root_instructions_and_ecosystem_contract(self):
        self.write('workspace.json', '{"schema": 1, "repositories": {}}')
        self.write('scripts/api-workspace.json', '{}')
        (self.root / 'package.el').unlink()
        # Exercise both worktree and exact-index CLI behavior. An untracked or
        # unstaged replacement must not conceal deletion from the next commit.
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.write('AGENTS.md', '# Workspace instructions\n')
        self.write('docs/architecture.zh-CN.md', '# Accepted ecosystem contract\n')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        command = [sys.executable, str(self.root / 'scripts/check-repository.py'),
                   '--root', str(self.root)]
        accepted = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(0, accepted.returncode, accepted.stderr)
        for path, message in [
                ('AGENTS.md', 'workspace requires its development instructions'),
                ('docs/architecture.zh-CN.md',
                 'workspace requires the accepted ecosystem architecture contract')]:
            with self.subTest(path=path):
                subprocess.run(['git', '-C', str(self.root), 'rm', '--cached', path],
                               check=True, capture_output=True)
                rejected = subprocess.run(command + ['--staged'], capture_output=True, text=True)
                self.assertEqual(1, rejected.returncode)
                self.assertIn(message, rejected.stderr)
                subprocess.run(['git', '-C', str(self.root), 'add', path], check=True)

    def test_workspace_sync_preserves_optional_local_instructions(self):
        # Exercise the real CLI against a workspace with an independent checkout.
        # A local instruction file is owned by its package, not the synchronizer.
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            package = workspace / 'sample'
            shutil.copytree(self.root, package)
            for path in POLICY.SHARED + ('scripts/workspace.py', 'scripts/verify.py', 'Makefile'):
                target = workspace / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / path, target)
            (workspace / 'README.md').write_text('# Workspace\n')
            (workspace / 'AGENTS.md').write_text('# Workspace development instructions\n')
            (workspace / 'docs').mkdir()
            (workspace / 'docs/architecture.zh-CN.md').write_text('# Accepted contract\n')
            (workspace / 'workspace.json').write_text(json.dumps({'schema': 1, 'repositories': {
                'sample': {'url': 'https://example.invalid/sample.git', 'revision': 'unused',
                           'branch': 'main'}}}))
            (workspace / '.gitignore').write_text('sample/\n__pycache__/\n')
            (package / '.gitignore').write_text('__pycache__/\n')
            for repo in [workspace, package]:
                subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            command = [sys.executable, str(workspace / 'scripts/workspace.py')]

            def run(action, success=True):
                result = subprocess.run(command + [action], capture_output=True, text=True)
                self.assertEqual(0 if success else 1, result.returncode, result.stderr)
                return result

            run('sync')
            self.assertFalse((package / 'AGENTS.md').exists())
            run('check')

            local = package / 'AGENTS.md'
            local.write_text('# Local instructions\nRead [the package](README.md).\n')
            nested = package / 'native/AGENTS.md'
            nested.parent.mkdir()
            nested.write_text('# Native build instructions\n')
            expected = {path: path.read_bytes() for path in [local, nested]}
            (workspace / 'AGENTS.md').write_text('# Changed workspace instructions\n')
            run('sync')
            self.assertEqual(expected, {path: path.read_bytes() for path in expected})
            run('check')
            (package / '.editorconfig').write_text('root = false\n')
            self.assertIn('shared tooling drift', run('check', success=False).stderr)
            run('sync')
            self.assertEqual(expected, {path: path.read_bytes() for path in expected})
            run('check')
            subprocess.run(['git', '-C', str(package), 'add', '.'], check=True)
            staged = subprocess.run([sys.executable, str(package / 'scripts/check-repository.py'),
                                     '--root', str(package), '--staged'],
                                    capture_output=True, text=True)
            self.assertEqual(0, staged.returncode, staged.stderr)

            # Local ownership must not exempt instructions from normal link checks.
            local.write_text('[missing](docs/missing.md)\n')
            self.assertIn('broken local link', run('check', success=False).stderr)
            local.unlink()
            run('sync')
            self.assertFalse(local.exists())
            self.assertEqual(expected[nested], nested.read_bytes())
            run('check')

    def test_responsibilities_allow_mixed_languages_and_test_data(self):
        for path in ['tests/tools/test_runner.py', 'tests/public.erts',
                     'benchmarks/measure.py', 'benchmarks/run.sh',
                     'benchmarks/input.json', 'tests/fixtures/input.json']:
            self.write(path, '')
        self.assertEqual('', self.errors())

    def test_tool_assertions_do_not_drift_into_runner_directory(self):
        self.write('scripts/test_runner.py', '# assertions')
        self.assertIn('tests/tools/', self.errors())

    def test_root_entry_and_internal_modules_have_distinct_roles(self):
        self.write('lisp/package-core.el', '; implementation')
        self.assertEqual('', self.errors())
        self.write('package-extra.el', '; extra root source')
        self.assertIn('exactly one root entry', self.errors())
        (self.root / 'package-extra.el').unlink()
        self.write('lisp/package.el', '; duplicate facade')
        self.assertIn('duplicated', self.errors())

    def test_new_plan_document_is_rejected(self):
        self.write('docs/proposals/phase-two.md', '# Plan\n')
        self.assertIn('fixed document names', self.errors())

    def test_broken_link_is_rejected(self):
        self.write('README.md', '[usage](docs/absent.md)\n')
        self.assertIn('broken local link', self.errors())

    def test_reference_style_broken_link_is_rejected(self):
        self.write('README.md', '[usage][manual]\n\n[manual]: docs/absent.md\n')
        self.assertIn('broken local link', self.errors())

    def test_provider_link_must_work_in_an_independent_checkout(self):
        self.write('README.md', '[provider](../sibling/README.md)\n')
        self.assertIn('provider URL', self.errors())

    def test_missing_build_source_is_rejected(self):
        with (self.root/'Makefile').open('a') as out:out.write('\nprobe:\n\temacs -l tests/deleted-tests.el\n')
        self.assertIn('missing source', self.errors())

    def test_empty_wildcard_does_not_silently_skip_examples(self):
        with (self.root/'Makefile').open('a') as out:out.write('\nEXAMPLES := $(wildcard examples/*.el)\n')
        self.assertIn('empty source discovery', self.errors())

    def test_case_only_directory_split_is_rejected_on_all_platforms(self):
        self.write('docs/manual.md', '# Manual\n')
        self.write('Docs/architecture.md', '# Architecture\n')
        self.assertIn('case collision', '\n'.join(POLICY.check(self.root, POLICY.inventory(self.root)+['docs/manual.md','Docs/architecture.md'])))

    def test_unknown_root_report_is_rejected(self):
        self.write('audit-results.json', '{}')
        self.assertIn('unapproved root file', self.errors())

    def test_missing_literal_load_directory_is_rejected(self):
        with (self.root/'Makefile').open('a') as out:out.write('\nLOAD_PATH = -L benchmarks./provider\n')
        self.assertIn('missing load directory', self.errors())

    def test_missing_acceptance_case_cannot_silently_disappear(self):
        self.write('tests/public-tests.el', '(ert-deftest renamed-roundtrip () (should t))\n')
        self.assertIn('missing named scenario', self.errors())

    def test_unlisted_lisp_test_cannot_form_a_hidden_suite(self):
        self.write('tests/hidden-tests.el', '(ert-deftest hidden () (should t))\n')
        self.assertIn('cover exactly all', self.errors())

    def test_native_internal_unit_suite_is_rejected(self):
        self.write('native/src/lib.rs', '#[cfg(test)] mod tests {}\n')
        self.assertIn('native internal unit tests', self.errors())

    def test_empty_acceptance_inventory_is_rejected(self):
        self.write('tests/acceptance.json', '{"cases": []}')
        self.assertIn('nonempty', self.errors())

    def test_link_case_must_match_even_on_case_insensitive_filesystems(self):
        self.write('README.md', '[self](readme.md)\n')
        self.assertIn('exact case', self.errors())

    def test_upstream_legal_notices_are_preserved(self):
        self.write('dictionaries/LICENSES.md', '# Provenance\n')
        self.assertEqual('', self.errors())

    def test_tracked_generated_files_are_rejected(self):
        self.write('package.elc', 'bytecode')
        self.assertIn('generated artifact', '\n'.join(POLICY.check(self.root, POLICY.inventory(self.root)+['package.elc'])))

    def test_staged_content_cannot_be_hidden_by_an_unstaged_repair(self):
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        self.write('README.md','[manual](docs/missing.md)\n')
        subprocess.run(['git','-C',str(self.root),'add','.'],check=True)
        self.write('README.md','# Repaired only in worktree\n')
        self.assertEqual('', self.errors())
        result=subprocess.run([sys.executable,str(self.root/'scripts/check-repository.py'),'--staged'],capture_output=True,text=True)
        self.assertEqual(1,result.returncode)
        self.assertIn('broken local link',result.stderr)

    def test_untracked_new_documents_are_checked(self):
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        self.write('AUDIT.md','# Extra\n')
        self.assertIn('merge or delete',self.errors())


if __name__ == '__main__':unittest.main()
