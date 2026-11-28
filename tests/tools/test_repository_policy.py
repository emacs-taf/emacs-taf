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

    def test_site_build_directory_is_accepted(self):
        self.write('site/package.json', '{}\n')
        self.write('site/.gitignore', 'node_modules/\ndist/\n')
        self.assertEqual('', self.errors())

    def test_unknown_top_level_directory_is_rejected(self):
        self.write('probe/notes.md', '# Notes\n')
        self.assertIn('unapproved top-level directory', self.errors())

    def installer_fixture(self, menu, packages, targets):
        entries = '\n'.join(f'    ({name} "Label" application {name}-open)' for name in menu)
        self.write('etaf-install.el',
                   '(defconst etaf-install--targets\n'
                   f"  '((etaf-install \"Install ETAF\" framework etaf-install)\n{entries})\n"
                   '  "Installable targets as (PACKAGE LABEL GROUP OPEN).")\n')
        self.write('release-dependencies.json', json.dumps(
            {'schema': 1, 'packages': {name: {} for name in packages}, 'targets': targets}))

    def test_installer_target_must_be_shipped_and_gated(self):
        self.installer_fixture(['etaf-ui'], ['etaf-ui', 'etaf-md'], ['etaf-md'])
        self.assertIn('target etaf-ui is not in release-dependencies targets',
                      '\n'.join(POLICY.install_selection_errors(self.root)))
        self.installer_fixture(['etaf-ui', 'maillist'], ['etaf-ui'], ['etaf-ui'])
        errors = '\n'.join(POLICY.install_selection_errors(self.root))
        self.assertIn('target maillist is not in release-dependencies packages', errors)
        self.assertIn('target maillist is not in release-dependencies targets', errors)

    def test_gated_target_must_be_an_installer_target(self):
        self.installer_fixture(['etaf-ui'], ['etaf-ui', 'maillist'], ['etaf-ui', 'maillist'])
        self.assertIn('target maillist is not an installer target',
                      '\n'.join(POLICY.install_selection_errors(self.root)))

    def test_a_consistent_installer_selection_has_no_errors(self):
        self.installer_fixture(['etaf-ui', 'maillist'], ['etaf-ui', 'maillist'],
                               ['etaf-ui', 'maillist'])
        self.assertEqual([], POLICY.install_selection_errors(self.root))

    def test_nested_application_resolves_providers_above_its_workspace(self):
        # A game checkout nested in a workspace still finds the provider
        # checkouts beside that workspace, in worktree and staged checks.
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            provider = base / 'etaf'
            (provider / 'lisp').mkdir(parents=True)
            (provider / 'etaf.el').write_text(
                ';;; Commentary:\n;; Function: etaf-open ()\n;; Open the runtime.\n'
                ";;; Code:\n(defun etaf-open () t)\n(provide 'etaf)\n")
            app = base / 'games/app'
            shutil.copytree(self.root, app)
            (app / 'package.el').write_text(
                ';;; Commentary:\n;; Function: package-open ()\n;; Return the package value.\n'
                ";;; Code:\n(require 'etaf)\n(defun package-open () (etaf-open))\n(provide 'package)\n")
            registry = json.loads((app / 'scripts/api-workspace.json').read_text())
            (app / 'scripts/api-workspace.json').write_text(
                json.dumps({'etaf': registry['etaf']}))
            subprocess.run(['git', 'init', '-q', str(app)], check=True)
            subprocess.run(['git', '-C', str(app), 'add', '.'], check=True)
            for extra in ([], ['--staged']):
                with self.subTest(staged=bool(extra)):
                    result = subprocess.run(
                        [sys.executable, str(app / 'scripts/check-repository.py'),
                         '--root', str(app)] + extra, capture_output=True, text=True)
                    self.assertEqual(0, result.returncode, result.stderr)

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

    def test_extension_contract_documents_are_allowed(self):
        self.write('docs/extensions.md', '# Extension syntax\n')
        self.write('docs/extensions.zh-CN.md', '# 扩展语法\n')
        self.assertEqual('', self.errors())

    def test_reference_book_chapters_are_content_with_checked_links(self):
        self.write('book/book.json', '{"parts": []}\n')
        self.write('book/en/views.md', '# Views\nSee [hosts](hosts.md#host-kinds).\n')
        self.write('book/en/hosts.md', '# Hosts\n')
        self.write('book/zh-CN/views.md', '# View\n')
        self.assertEqual('', self.errors())
        self.write('book/en/views.md', '# Views\nSee [hosts](missing.md).\n')
        self.assertIn('broken local link', self.errors())
        (self.root / 'book/en/views.md').unlink()
        for misplaced in ('book/notes.md', 'book/en/part/views.md', 'book/en/Views.md'):
            self.write(misplaced, '# Notes\n')
            self.assertIn('book chapters are book/<language>/', self.errors())
            (self.root / misplaced).unlink()

    def test_generated_book_chapters_are_valid_link_targets(self):
        self.write('book/book.json', json.dumps({
            'languages': ['en', 'zh-CN'], 'parts': [], 'indices': [],
            'appendices': [{'id': 'theme-token-table', 'generate': 'token-table'}]}))
        self.write('book/en/views.md', '# Views\nSee [tokens](theme-token-table.md).\n')
        self.write('book/zh-CN/views.md', '# View\n见[tokens](theme-token-table.md)。\n')
        self.assertEqual('', self.errors())
        self.write('book/en/views.md', '# Views\nSee [tokens](missing.md).\n')
        self.assertIn('broken local link', self.errors())
        self.write('book/en/views.md', '# Views\nSee [tokens](theme-token-table.md#token-ui-fg).\n')
        self.assertEqual('', self.errors())

    def test_staged_check_ignores_intent_to_add_entries(self):
        # A colocated jj working copy records its new files this way.
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        self.write('notes.md', '# Notes\n')
        subprocess.run(['git', '-C', str(self.root), 'add', '-N', 'notes.md'], check=True)
        staged = [sys.executable, str(ROOT / 'scripts/check-repository.py'), '--root', str(self.root), '--staged']
        result = subprocess.run(staged, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        subprocess.run(['git', '-C', str(self.root), 'add', 'notes.md'], check=True)
        result = subprocess.run(staged, capture_output=True, text=True)
        self.assertIn('notes.md: use README, CHANGELOG', result.stderr)

    def test_link_syntax_inside_inline_code_is_not_a_link(self):
        self.write('README.md', '# Package\nWrite `[Views](views.md)` or ``[a](b.md) `x` `` to link.\n')
        self.assertEqual('', self.errors())
        self.write('README.md', '# Package\nSee [`views`](views.md).\n')
        self.assertIn('broken local link (including exact case): views.md', self.errors())
        self.write('README.md', '# Package\nSee `code` and [views](views.md).\n')
        self.assertIn('broken local link (including exact case): views.md', self.errors())

    def test_keyboard_contract_is_workspace_only_and_checks_links(self):
        document = 'docs/keyboard-navigation.zh-CN.md'
        self.write(document, '# Keyboard navigation contract\n')
        command = [sys.executable, str(self.root / 'scripts/check-repository.py'),
                   '--root', str(self.root)]
        package = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(1, package.returncode)
        self.assertIn('fixed document names', package.stderr)

        self.write('workspace.json', '{"schema": 1, "repositories": {}}')
        self.write('scripts/api-workspace.json', '{}')
        self.write('AGENTS.md', '# Workspace instructions\n')
        self.write('docs/architecture.zh-CN.md', '# Ecosystem contract\n')
        self.write('README.md', '[Keyboard contract](' + document + ')\n')
        (self.root / 'package.el').unlink()
        accepted = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(0, accepted.returncode, accepted.stderr)

        self.write('.gitignore', '__pycache__/\n')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        staged = subprocess.run(command + ['--staged'], capture_output=True, text=True)
        self.assertEqual(0, staged.returncode, staged.stderr)
        self.write(document, '[Missing](missing.md)\n')
        broken = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(1, broken.returncode)
        self.assertIn('broken local link', broken.stderr)

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

    def test_secondary_jj_workspace_metadata_is_not_project_content(self):
        # A non-colocated `jj workspace add` checkout has no Git index.
        self.write('.jj/repo', '../../main/.jj/repo')
        self.write('.jj/working_copy/tree_state', 'state')
        self.assertEqual('', self.errors())

    @unittest.skipUnless(shutil.which('jj'), 'jj is not installed')
    def test_secondary_jj_workspace_checks_new_files_and_honors_ignores(self):
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'main'
            second = Path(directory) / 'second'
            subprocess.run(['jj', 'git', 'init', str(main)], check=True, capture_output=True)
            shutil.copytree(self.root, main, dirs_exist_ok=True)
            (main / '.gitignore').write_text('/child/\n')
            subprocess.run(['jj', 'commit', '-m', 'base'], cwd=main, check=True, capture_output=True)
            subprocess.run(['jj', 'workspace', 'add', str(second)], cwd=main,
                           check=True, capture_output=True)
            (second / 'child').mkdir()
            (second / 'child/AUDIT.md').write_text('# Independent ignored checkout\n')
            self.assertEqual('', '\n'.join(POLICY.check(second)))
            (second / 'AUDIT.md').write_text('# Extra\n')
            errors = '\n'.join(POLICY.check(second))
            self.assertIn('AUDIT.md: use README', errors)
            self.assertNotIn('child/', errors)
            # Without an index, --staged checks only a sealed working copy.
            command = [sys.executable, str(second / 'scripts/check-repository.py'), '--staged']
            unsealed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(1, unsealed.returncode)
            self.assertIn('unsealed', unsealed.stderr)
            subprocess.run(['jj', 'commit', '-m', 'audit'], cwd=second,
                           check=True, capture_output=True)
            sealed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(1, sealed.returncode)
            self.assertIn('AUDIT.md: use README', sealed.stderr)

    def test_untracked_new_documents_are_checked(self):
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        self.write('AUDIT.md','# Extra\n')
        self.assertIn('merge or delete',self.errors())

    def test_monorepo_registry_matches_packages_and_forbids_nested_vcs(self):
        self.write('workspace.json', json.dumps({'schema': 2, 'packages': {'alpha': {'url': 'https://example.invalid/alpha.git', 'branch': 'main'}}}))
        self.write('AGENTS.md', '# Workspace instructions\n')
        self.write('docs/architecture.zh-CN.md', '# Ecosystem contract\n')
        (self.root / 'package.el').unlink()
        (self.root / 'packages/alpha').mkdir(parents=True)
        self.assertEqual('', '\n'.join(POLICY.check(self.root, files=[f for f in POLICY.inventory(self.root) if not f.startswith('packages/')])))

        # Unregistered directory under packages/ is rejected.
        (self.root / 'packages/orphan').mkdir(parents=True)
        errors = '\n'.join(POLICY.check(self.root, files=[f for f in POLICY.inventory(self.root) if not f.startswith('packages/')]))
        self.assertIn('unregistered package directory', errors)
        (self.root / 'packages/orphan').rmdir()

        # Nested .git inside packages/<name> is rejected.
        (self.root / 'packages/alpha/.git').mkdir()
        errors = '\n'.join(POLICY.check(self.root, files=[f for f in POLICY.inventory(self.root) if not f.startswith('packages/')]))
        self.assertIn('nested VCS directory', errors)
        (self.root / 'packages/alpha/.git').rmdir()

        # Missing registered package under packages/ is rejected.
        (self.root / 'packages/alpha').rmdir()
        errors = '\n'.join(POLICY.check(self.root, files=[f for f in POLICY.inventory(self.root) if not f.startswith('packages/')]))
        self.assertIn('registered package is missing on disk: alpha', errors)

    def test_extension_role_requires_etaf_ext_dependency_and_rejects_unknown_roles(self):
        self.write('AGENTS.md', '# Workspace instructions\n')
        self.write('docs/architecture.zh-CN.md', '# Ecosystem contract\n')
        (self.root / 'package.el').unlink()
        (self.root / 'packages/etaf-ext').mkdir(parents=True)
        (self.root / 'packages/etaf-ext/etaf-ext.el').write_text(
            ';;; etaf-ext.el --- Engine -*- lexical-binding: t; -*-\n'
            ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1"))\n(provide \'etaf-ext)\n')
        (self.root / 'packages/my-ext').mkdir(parents=True)
        (self.root / 'packages/my-ext/my-ext.el').write_text(
            ';;; my-ext.el --- Extension -*- lexical-binding: t; -*-\n'
            ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1") (etaf-ext "0.1.0"))\n(provide \'my-ext)\n')
        self.write('workspace.json', json.dumps({'schema': 2, 'packages': {
            'etaf-ext': {'url': 'https://example.invalid/etaf-ext.git', 'branch': 'main', 'role': 'framework'},
            'my-ext': {'url': 'https://example.invalid/my-ext.git', 'branch': 'main', 'role': 'extension'},
        }}))
        files = [f for f in POLICY.inventory(self.root) if not f.startswith('packages/')]
        self.assertEqual('', '\n'.join(POLICY.check(self.root, files=files)))

        # Extension without etaf-ext in Package-Requires is rejected.
        (self.root / 'packages/my-ext/my-ext.el').write_text(
            ';;; my-ext.el --- Not an etaf-ext extension -*- lexical-binding: t; -*-\n'
            ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1") (etaf "0.3.8"))\n(provide \'my-ext)\n')
        errors = '\n'.join(POLICY.check(self.root, files=files))
        self.assertIn('role "extension" requires declaring etaf-ext in Package-Requires', errors)

        # Misspelled/unknown role is rejected.
        self.write('workspace.json', json.dumps({'schema': 2, 'packages': {
            'etaf-ext': {'url': 'https://example.invalid/etaf-ext.git', 'branch': 'main', 'role': 'framework'},
            'my-ext': {'url': 'https://example.invalid/my-ext.git', 'branch': 'main', 'role': 'extention'},
        }}))
        errors = '\n'.join(POLICY.check(self.root, files=files))
        self.assertIn("unknown role 'extention'", errors)

    def test_archive_consistency_rejects_elpa_make_remedy_and_bad_native_manifest(self):
        self.write('AGENTS.md', '# Workspace instructions\n')
        self.write('docs/architecture.zh-CN.md', '# Ecosystem contract\n')
        shutil.copyfile(ROOT / 'scripts/native-release.py', self.root / 'scripts/native-release.py')
        (self.root / 'package.el').unlink()
        self.write('workspace.json', json.dumps({'schema': 2, 'packages': {
            'demo': {'url': 'https://example.invalid/demo.git', 'branch': 'main', 'role': 'application'},
        }}))
        self.installer_fixture(['demo'], ['demo'], ['demo'])
        self.write('release-dependencies.json', json.dumps({
            'schema': 1,
            'packages': {'demo': {'resources': ['native/manifest.json']}},
            'targets': ['demo'],
        }))
        self.write('packages/demo/demo.el',
                   ';;; demo.el --- Demo -*- lexical-binding: t; -*-\n'
                   ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1"))\n'
                   '(defun demo-doctor () (list :optional (list (list "native" nil "Run \'make native-build\'"))))\n'
                   '(provide \'demo)\n')
        self.write('packages/demo/README.md',
                   '# Demo\n\ncd ~/.emacs.d/elpa/demo-* && make native-build\n')
        self.write('packages/demo/native/manifest.json', '{"schema": 2, "package": "wrong", "modules": []}\n')
        errors = '\n'.join(POLICY.archive_consistency_errors(self.root))
        self.assertIn('README.md: archive users do not receive root Makefile', errors)
        self.assertIn('demo.el: archive users do not receive root Makefile', errors)
        self.assertIn('native/manifest.json: expected schema 1', errors)

    def test_archive_resource_policy_enforces_uniform_directory_classification(self):
        self.write('AGENTS.md', '# Workspace instructions\n')
        self.write('docs/architecture.zh-CN.md', '# Ecosystem contract\n')
        (self.root / 'package.el').unlink()
        self.write('workspace.json', json.dumps({'schema': 2, 'packages': {
            'app': {'url': 'https://example.invalid/app.git', 'branch': 'main', 'role': 'application'},
        }}))
        self.installer_fixture(['app'], ['app'], ['app'])
        self.write('packages/app/app.el',
                   ';;; app.el --- App -*- lexical-binding: t; -*-\n'
                   ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1"))\n(provide \'app)\n')
        self.write('packages/app/Makefile', 'check:\n\t@true\n')
        self.write('packages/app/docs/manual.md', '# Manual\n')
        self.write('packages/app/backends/worker.mjs', 'console.log("ok");\n')
        self.write('packages/app/scripts/dev-probe.el', ';; dev only\n')
        self.write('packages/app/tests/app-tests.el', ';; tests\n')
        self.write('packages/app/benchmarks/bench.el', ';; bench\n')
        self.write('packages/app/examples/demo.el', ';; demo\n')
        self.write('packages/app/examples/screenshot.png', 'PNG')
        self.write('packages/app/media/demo-wide.png', 'PNG')
        self.write('packages/app/native/manifest.json', json.dumps({
            'schema': 1, 'package': 'app', 'modules': [{
                'name': 'app-native', 'version': '1', 'description': 'test',
                'platforms': {'darwin-arm64': {
                    'file': 'app-native-v1-darwin-arm64.dylib',
                    'urls': ['https://etaf.top/native/app/1/app-native-v1-darwin-arm64.dylib'],
                    'sha256': '0' * 64, 'size': 16,
                }},
            }],
        }) + '\n')
        self.write('packages/app/native/vendor/lib.c', '/* vendor */\n')

        # 1) Smart suggestion picks ONLY offline docs, runtime backends and native/manifest.json.
        self.assertEqual(
            ['docs', 'backends', 'native/manifest.json'],
            POLICY.suggest_release_resources(self.root / 'packages/app'),
        )

        # 2) Passing the clean recommended list has zero errors.
        self.write('release-dependencies.json', json.dumps({
            'schema': 1,
            'packages': {'app': {'resources': ['docs', 'backends', 'native/manifest.json']}},
            'targets': ['app'],
        }))
        self.assertEqual([], POLICY.archive_consistency_errors(self.root))

        # 3) Shipping dev-only dirs, scripts/, media/, Makefile, screenshot examples, or native/ with vendor/ is rejected.
        self.write('release-dependencies.json', json.dumps({
            'schema': 1,
            'packages': {'app': {'resources': [
                'docs', 'backends', 'tests', 'benchmarks', 'media', 'Makefile',
                'scripts', 'examples', 'native',
            ]}},
            'targets': ['app'],
        }))
        errors = '\n'.join(POLICY.archive_consistency_errors(self.root))
        self.assertIn('tests is development-only', errors)
        self.assertIn('benchmarks is development-only', errors)
        self.assertIn('media is development-only', errors)
        self.assertIn('Makefile is development-only', errors)
        self.assertIn('dev-only scripts/', errors)
        self.assertIn('contains showcase media', errors)
        self.assertIn('contains vendor/ build sources', errors)

        # 4) Forgetting on-disk docs/, runtime backends/ or native/manifest.json is also caught.
        self.write('release-dependencies.json', json.dumps({
            'schema': 1,
            'packages': {'app': {'resources': []}},
            'targets': ['app'],
        }))
        missing_errors = '\n'.join(POLICY.archive_consistency_errors(self.root))
        self.assertIn('runtime directory docs/ exists on disk', missing_errors)
        self.assertIn('runtime directory backends/ exists on disk', missing_errors)
        self.assertIn('native/manifest.json exists on disk', missing_errors)

    def test_showcase_media_belongs_in_media_not_examples_and_lisp_cannot_ref_dev_dirs(self):
        # Compact offline test fixture under tests/fixtures/ is allowed.
        self.write('tests/fixtures/wide.png', 'PNG')
        self.assertEqual('', self.errors())

        # Media inside media/ or examples/ is rejected at structure-check time.
        self.write('media/wide.png', 'PNG')
        self.assertIn('images and videos must not be committed outside tests/fixtures/', self.errors())
        (self.root / 'media/wide.png').unlink()

        self.write('examples/shot.png', 'PNG')
        self.assertIn('https://etaf.top/media/', self.errors())
        (self.root / 'examples/shot.png').unlink()

        # Runtime Lisp referencing an existing top-level scripts/ file is rejected.
        self.write('scripts/helper.mjs', 'console.log(1);\n')
        self.write('lisp/package-runtime.el',
                   '(defconst package--helper "scripts/helper.mjs")\n'
                   '(provide \'package-runtime)\n')
        self.assertIn('runtime Lisp must not reference dev-only scripts/helper.mjs', self.errors())

        # A comment mentioning scripts/helper.mjs or a non-root relative path is allowed.
        self.write('lisp/package-runtime.el',
                   ';; dev helper lives at "scripts/helper.mjs"\n'
                   '(defconst package--nested "scripts/only-inside-backend.mjs")\n'
                   '(provide \'package-runtime)\n')
        self.assertEqual('', self.errors())

    def test_custom_keys_variable_must_appear_in_readme_usage_and_manual(self):
        self.write('package.el',
                   ";;; Commentary:\n"
                   ";; Function: package-open ()\n"
                   ";; Open package.\n"
                   ";; Variable: package-keys\n"
                   ";; Key bindings.\n"
                   ";; Variable: package-extra-option\n"
                   ";; Extra option.\n"
                   ";;; Code:\n"
                   "(defcustom package-keys nil \"Keys.\" :type 'sexp)\n"
                   "(defcustom package-extra-option t \"Extra.\" :type 'boolean)\n"
                   "(defun package-open () t)\n"
                   "(provide 'package)\n")
        # Mentioning package-keys only under Capabilities fails.
        self.write('README.md',
                   '# Package\n\n## Capabilities\n\nCustomizable via `package-keys`.\n\n'
                   '## Usage\n\nRun `M-x package-open`.\n')
        self.write('README.zh-CN.md',
                   '# 包\n\n## 核心能力\n\n可通过 `package-keys` 定制。\n\n'
                   '## 使用方式\n\n运行 `M-x package-open`。\n')
        self.write('docs/manual.md', '# Manual\n\n## Keys\n\nPress `q`.\n')
        errors = self.errors()
        self.assertIn('README.md: customizable key variable `package-keys` must be documented inside the Usage / Quick start section', errors)
        self.assertIn('README.zh-CN.md: customizable key variable `package-keys` must be documented inside the Usage / Quick start section', errors)
        self.assertIn('docs/manual.md: customizable key variable `package-keys` is missing from user manual', errors)

        # Documenting package-keys inside Usage / 使用方式 and docs/manual.md passes,
        # while an undocumented non-key defcustom surfaces as a notice.
        self.write('README.md',
                   '# Package\n\n## Usage\n\nCustomize `package-keys`.\n')
        self.write('README.zh-CN.md',
                   '# 包\n\n## 使用方式\n\n通过 `package-keys` 定制。\n')
        self.write('docs/manual.md',
                   '# Manual\n\n## Keys\n\nCustomize `package-keys`.\n')
        notices = []
        self.assertEqual([], POLICY.check(self.root, notices=notices))
        self.assertTrue(any('package-extra-option' in n for n in notices))

    def test_large_media_videos_and_blobs_are_blocked_from_git(self):
        # Compact offline test inputs (<= 100 KB) under tests/fixtures/ pass cleanly.
        (self.root / 'tests/fixtures').mkdir(parents=True, exist_ok=True)
        (self.root / 'tests/fixtures/sample.mp4').write_bytes(b'\0' * (32 * 1024))
        (self.root / 'tests/fixtures/pixel.png').write_bytes(b'\0' * (12 * 1024))
        self.assertEqual([], POLICY.check(self.root))

        # Any image or video outside tests/fixtures/ is hard-rejected regardless of size.
        (self.root / 'media').mkdir(exist_ok=True)
        (self.root / 'media/shot.webp').write_bytes(b'\0' * (20 * 1024))
        (self.root / 'media/recording.mp4').write_bytes(b'\0' * (20 * 1024))
        (self.root / 'site/public/shots').mkdir(parents=True, exist_ok=True)
        (self.root / 'site/public/shots/app.webp').write_bytes(b'\0' * (20 * 1024))
        # Oversized fixture media (> 100 KB), archive (> 512 KB), and non-vendor file (> 2 MB) are rejected.
        (self.root / 'tests/fixtures/big-shot.png').write_bytes(b'\0' * (120 * 1024))
        (self.root / 'tests/fixtures/bundle.zip').write_bytes(b'\0' * (600 * 1024))
        (self.root / 'tests/fixtures/huge.dat').write_bytes(b'\0' * (2100 * 1024))
        errors = self.errors()
        self.assertIn('media/shot.webp: images and videos must not be committed outside tests/fixtures/', errors)
        self.assertIn('media/recording.mp4: images and videos must not be committed outside tests/fixtures/', errors)
        self.assertIn('site/public/shots/app.webp: images and videos must not be committed outside tests/fixtures/', errors)
        self.assertIn('tests/fixtures/big-shot.png: test fixture media exceeds 100 KB', errors)
        self.assertIn('tests/fixtures/bundle.zip: binary media/archive exceeds 512 KB', errors)
        self.assertIn('tests/fixtures/huge.dat: tracked file exceeds 2 MB', errors)

        # Upstream vendored source under native/vendor/ is exempt from the 2 MB general cap.
        for bad in ('media/shot.webp', 'media/recording.mp4', 'site/public/shots/app.webp',
                    'tests/fixtures/big-shot.png', 'tests/fixtures/bundle.zip', 'tests/fixtures/huge.dat'):
            (self.root / bad).unlink()
        (self.root / 'native/vendor/lib').mkdir(parents=True, exist_ok=True)
        (self.root / 'native/vendor/lib/upstream.c').write_bytes(b'a' * (2100 * 1024))
        self.assertEqual('', self.errors())

    def test_workspace_readme_alignment_rejects_outside_overlap_and_missing_pkg(self):
        (self.root / 'packages/etaf-alpha').mkdir(parents=True)
        (self.root / 'packages/etaf-beta').mkdir(parents=True)
        self.write('workspace.json', json.dumps({
            'schema': 2,
            'packages': {
                'etaf-alpha': {'url': 'https://github.com/emacs-taf/etaf-alpha.git', 'role': 'application'},
                'etaf-beta': {'url': 'https://github.com/emacs-taf/etaf-beta.git', 'role': 'application'},
            },
        }))
        self.write('README.md',
                   '# Workspace\n\n## Applications\n\n'
                   '| [etaf-alpha](https://github.com/emacs-taf/etaf-alpha) | Alpha | etaf |\n\n'
                   '## Outside this checkout\n\n'
                   '| [etaf-beta](https://github.com/emacs-taf/etaf-beta) | Beta |\n')
        errors = '\n'.join(POLICY.workspace_readme_errors(self.root))
        self.assertIn('README.md: registered package etaf-beta is listed under Outside this checkout', errors)
        self.assertIn('README.md: registered package etaf-beta is missing from the in-checkout tables', errors)

        self.write('README.md',
                   '# Emacs TAF Monorepo\n\n## Applications\n\n'
                   '| [etaf-alpha](https://github.com/emacs-taf/etaf-alpha) | Alpha | etaf |\n'
                   '| [etaf-beta](https://github.com/emacs-taf/etaf-beta) | Beta | etaf |\n\n'
                   '## Outside this Monorepo\n\n'
                   '| [etaf-other](https://github.com/emacs-taf/etaf-other) | Other |\n')
        self.assertEqual([], POLICY.workspace_readme_errors(self.root))

    def test_lisp_module_rejects_sibling_package_prefix(self):
        self.write('workspace.json', json.dumps({
            'schema': 2,
            'packages': {
                'etaf': {'path': 'core/packages/etaf', 'role': 'framework'},
                'etaf-ui': {'path': 'core/packages/etaf-ui', 'role': 'framework'},
                'etaf-doc': {'path': 'core/packages/etaf-doc', 'role': 'framework'},
                'etaf-db': {'path': 'core/packages/etaf-db', 'role': 'framework'},
            },
        }))
        makefile = (
            'compile:\n\t@true\n'
            'acceptance:\n\t@true\n'
            'test: acceptance\n'
            'clean:\n\t@true\n'
            'setup-hooks:\n\t@true\n'
            'structure-check:\n\t@true\n'
            'api-check:\n\t@true\n'
            'check: structure-check compile acceptance api-check\n'
        )
        doc_root = self.root / 'core/packages/etaf-doc'
        for rel, body in (
            ('README.md', '# etaf-doc\n'),
            ('Makefile', makefile),
            ('tests/acceptance.json', json.dumps({'schema': 1, 'load_path': ['.'], 'cases': [
                {'name': 'etaf-doc-ok-test', 'file': 'tests/etaf-doc-tests.el', 'purpose': 'Ok.'},
            ]}) + '\n'),
            ('tests/etaf-doc-tests.el', ';;; etaf-doc-tests.el --- Tests -*- lexical-binding: t; -*-\n(ert-deftest etaf-doc-ok-test () (should t))\n'),
            ('etaf-doc.el',
             ';;; etaf-doc.el --- Doc -*- lexical-binding: t; -*-\n'
             ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1"))\n'
             ';;; Commentary:\n;; Function: etaf-doc-ok ()\n;; Ok.\n;;; Code:\n'
             '(defun etaf-doc-ok () "Ok." t)\n(provide \'etaf-doc)\n'),
            ('lisp/etaf-doc-markdown.el', ';;; etaf-doc-markdown.el --- Ok -*- lexical-binding: t; -*-\n(provide \'etaf-doc-markdown)\n'),
            ('lisp/etaf-ui-markdown.el', ';;; etaf-ui-markdown.el --- Bad -*- lexical-binding: t; -*-\n(provide \'etaf-ui-markdown)\n'),
        ):
            p = doc_root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body)
        errors = '\n'.join(POLICY.check(doc_root))
        self.assertIn("lisp/etaf-ui-markdown.el: lisp module borrows sibling package prefix 'etaf-ui'", errors)
        self.assertNotIn('etaf-doc-markdown.el', errors)

        # Removing the offending sibling-prefixed file makes the package clean.
        (doc_root / 'lisp/etaf-ui-markdown.el').unlink()
        self.assertEqual([], POLICY.check(doc_root))

        # A parent namespace prefix (e.g. `etaf` for `etaf-db`) is allowed for domain modules.
        db_root = self.root / 'core/packages/etaf-db'
        for rel, body in (
            ('README.md', '# etaf-db\n'),
            ('Makefile', makefile),
            ('tests/acceptance.json', json.dumps({'schema': 1, 'load_path': ['.'], 'cases': [
                {'name': 'etaf-db-ok-test', 'file': 'tests/etaf-db-tests.el', 'purpose': 'Ok.'},
            ]}) + '\n'),
            ('tests/etaf-db-tests.el', ';;; etaf-db-tests.el --- Tests -*- lexical-binding: t; -*-\n(ert-deftest etaf-db-ok-test () (should t))\n'),
            ('etaf-db.el',
             ';;; etaf-db.el --- DB -*- lexical-binding: t; -*-\n'
             ';; Version: 0.1.0\n;; Package-Requires: ((emacs "29.1"))\n'
             ';;; Commentary:\n;; Function: etaf-db-ok ()\n;; Ok.\n;;; Code:\n'
             '(defun etaf-db-ok () "Ok." t)\n(provide \'etaf-db)\n'),
            ('lisp/etaf-sqlite-store.el', ';;; etaf-sqlite-store.el --- Ok -*- lexical-binding: t; -*-\n(provide \'etaf-sqlite-store)\n'),
        ):
            p = db_root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body)
        self.assertEqual([], POLICY.check(db_root))


if __name__ == '__main__':unittest.main()
