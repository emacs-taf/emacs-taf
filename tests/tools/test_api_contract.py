"""Public boundary checks use source fixtures rather than implementation details."""
import importlib.util
from pathlib import Path
import tempfile
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('api', ROOT/'scripts/check-api.py')
API = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(API)


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('provider', 'consumer'):
            base = self.root/name
            (base/'lisp').mkdir(parents=True)
            (base/(name+'.el')).write_text(
                f';;; Commentary:\n;; Function: {name}-open ()\n;; Return a new instance.\n'
                f';;; Code:\n(defun {name}-open () t)\n(provide \'{name})\n')
        (self.root/'provider/lisp/provider-core.el').write_text(
            "(defun provider-helper () t)\n(defun provider--private () t)\n(provide 'provider-core)\n")

    def check(self, code):
        (self.root/'consumer/lisp/consumer-core.el').write_text(code)
        return '\n'.join(API.check({n:API.package(self.root/n) for n in ('provider', 'consumer')}))

    def test_public_calls_and_function_references_pass(self):
        self.assertEqual('', self.check("(require 'provider)\n(provider-open)\n(mapcar #'provider-open nil)"))

    def test_unlisted_nonprivate_name_is_not_an_export(self):
        self.assertIn('internal to provider', self.check('(provider-helper)'))

    def test_quoted_private_callback_is_rejected(self):
        self.assertIn('provider--private', self.check("(mapcar #'provider--private nil)"))

    def test_internal_library_imports_are_rejected(self):
        self.assertIn('internal feature', self.check("(require 'provider-core)"))
        self.assertIn('direct load', self.check('(load "../provider/lisp/provider-core.el")'))

    def test_comments_and_docstrings_are_not_calls(self):
        self.assertEqual('', self.check('; provider--private\n(defun consumer-doc () "provider--private" t)'))

    def test_literal_reflection_cannot_bypass_the_boundary(self):
        self.assertIn('reflective reference', self.check('(intern "provider--private")'))

    def test_shadowing_a_provider_symbol_is_rejected(self):
        self.assertIn('also owned', self.check('(defun provider-helper () nil)'))

    def test_generated_struct_accessors_and_aliases_are_internal(self):
        p = self.root/'provider/lisp/provider-core.el'
        p.write_text("(cl-defstruct (provider-state (:constructor provider-state-create)) value)\n"
                     "(defalias 'provider-alias #'ignore)\n")
        self.assertIn('provider-state-value', self.check('(provider-state-value state)'))
        self.assertIn('provider-state-create', self.check('(provider-state-create)'))
        self.assertIn('provider-alias', self.check('(provider-alias)'))

    @unittest.skipUnless(shutil.which('emacs'), 'batch Emacs is unavailable')
    def test_runtime_gate_rejects_signature_drift_and_missing_bindings(self):
        entry = self.root/'provider/provider.el'
        original = entry.read_text()
        def run():
            return subprocess.run(['emacs', '-Q', '--batch', '-l', str(ROOT/'scripts/check-api.el')],
                                  cwd=entry.parent, capture_output=True, text=True)
        self.assertEqual(run().returncode, 0)
        entry.write_text(original.replace('Function: provider-open ()', 'Function: provider-open (item)'))
        result = run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signature drift', result.stdout + result.stderr)
        entry.write_text(original.replace('(defun provider-open () t)', ''))
        result = run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unavailable after loading', result.stdout + result.stderr)

    def test_api_declaration_requires_usage_and_has_no_duplicates(self):
        p=self.root/'provider/provider.el'
        p.write_text(';;; Commentary:\n;; Function: provider-open\n;; Function: provider-open ()\n;;; Code:\n')
        errors='\n'.join(API.declarations(p)[1])
        self.assertIn('calling signature', errors)
        self.assertIn('duplicate', errors)
        self.assertIn('documentation', errors)
