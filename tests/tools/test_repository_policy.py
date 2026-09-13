"""Behavioral regressions for drift detection and staged-content checking."""
import importlib.util
from pathlib import Path
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
