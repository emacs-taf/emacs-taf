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

    def test_declared_dependencies_match_the_sources(self):
        entry = self.root/'consumer/consumer.el'
        body = (";;; Commentary:\n;; Function: consumer-open ()\n;; Return a new instance.\n"
                ";;; Code:\n(defun consumer-open () t)\n(provide 'consumer)\n")
        header = ';; Package-Requires: ((emacs "29.1") (provider "1.0.0"))\n'
        entry.write_text(header + body)
        self.assertEqual('', self.check("(require 'provider)\n(provider-open)"))
        self.assertIn('declares provider, which no source uses', self.check("(defun unrelated () t)"))
        entry.write_text(';; Package-Requires: ((emacs "29.1"))\n' + body)
        self.assertIn('Package-Requires omits provider', self.check('(provider-open)'))

    def test_own_package_private_calls_in_test_helpers_are_rejected(self):
        tests = self.root/'provider/tests'
        tests.mkdir()
        (tests/'public-tests.el').write_text(
            "(defun test-helper () (provider-helper))\n"
            "(ert-deftest public-case () (test-helper))\n")
        self.assertIn('provider-helper', self.check('(provider-open)'))

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


class StandaloneExampleCommandTests(unittest.TestCase):
    def test_example_entry_owns_its_public_api_not_the_framework(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'framework.el').write_text(
                ';;; -*- lexical-binding: t; -*-\n;;; Commentary:\n'
                ';; Function: framework-start ()\n;; Start an instance.\n;;; Code:\n'
                "(defun framework-start () t)\n(defun framework--private () t)\n(provide 'framework)\n")
            example = root/'examples/arena'
            (example/'lisp').mkdir(parents=True)
            entry = example/'arena.el'
            source = (';;; -*- lexical-binding: t; -*-\n;;; Commentary:\n'
                      ';; Function: arena-open ()\n;; Open a game.\n;;; Code:\n'
                      "(require 'framework)\n(require 'arena-world)\n"
                      "(defun arena-open () (framework-start))\n(provide 'arena)\n")
            entry.write_text(source)
            (example/'lisp/arena-world.el').write_text(
                ';;; -*- lexical-binding: t; -*-\n'
                "(defun arena--private () t)\n(provide 'arena-world)\n")
            (root/'tests').mkdir()
            tests = root/'tests/game-tests.el'

            def run(code):
                tests.write_text(';;; -*- lexical-binding: t; -*-\n' + code)
                return subprocess.run(
                    ['python3', str(ROOT/'scripts/check-api.py'), '--root', directory],
                    capture_output=True, text=True)

            result = run("(require 'arena)\n(arena-open)\n")
            self.assertEqual(0, result.returncode, result.stderr)
            for code, diagnostic in [("(arena--private)", 'internal to'),
                                     ("(require 'arena-world)", 'internal feature'),
                                     ('(load "arena-world")', 'direct load')]:
                with self.subTest(code=code):
                    result = run(code)
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(diagnostic, result.stderr)
            entry.write_text(source.replace('(framework-start)', '(framework--private)'))
            result = run("(arena-open)")
            self.assertNotEqual(0, result.returncode)
            self.assertIn('framework--private is internal', result.stderr)
            entry.write_text(source.replace(';; Open a game.\n', ''))
            result = run("(arena-open)")
            self.assertNotEqual(0, result.returncode)
            self.assertIn('needs usage/behavior documentation', result.stderr)


class DeclarationCommandTests(unittest.TestCase):
    def test_distinct_bindings_share_a_symbol_but_not_a_namespace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = root / 'sample.el'
            def run(records):
                entry.write_text(';;; Commentary:\n' + records +
                                 ";;; Code:\n(provide 'sample)\n")
                return subprocess.run(
                    ['python3', str(ROOT/'scripts/check-api.py'), '--root', directory],
                    capture_output=True, text=True)
            result = run(';; Function: sample-error (object)\n;; Read an error value.\n'
                         ';; Error: sample-error\n;; Signal an invalid operation.\n')
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            for first, second in [('Function', 'Function'), ('Function', 'Macro'),
                                  ('Variable', 'Hook'), ('Error', 'Error')]:
                with self.subTest(first=first, second=second):
                    result = run(f';; {first}: sample-value ()\n;; First binding.\n'
                                 f';; {second}: sample-value ()\n;; Duplicate binding.\n')
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn('duplicate API declaration', result.stderr)

    @unittest.skipUnless(shutil.which('emacs'), 'batch Emacs is unavailable')
    def test_same_named_function_and_error_are_both_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            entry = Path(directory)/'sample.el'
            source = (";;; Commentary:\n"
                      ";; Function: sample-error (object)\n;; Read an error value.\n"
                      ";; Error: sample-error\n;; Signal invalid input.\n"
                      ";;; Code:\n"
                      "(defun sample-error (object) object)\n"
                      "(define-error 'sample-error \"Invalid input\")\n"
                      "(provide 'sample)\n")
            def run(text):
                entry.write_text(text)
                return subprocess.run(
                    ['emacs', '-Q', '--batch', '-l', str(ROOT/'scripts/check-api.el')],
                    cwd=directory, capture_output=True, text=True)
            result = run(source)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            for removed in ["(defun sample-error (object) object)\n",
                            "(define-error 'sample-error \"Invalid input\")\n"]:
                result = run(source.replace(removed, ''))
                self.assertNotEqual(0, result.returncode)
                self.assertIn('unavailable after loading', result.stdout + result.stderr)
