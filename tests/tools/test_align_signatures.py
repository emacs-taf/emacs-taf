"""Commentary signature alignment of scripts/align-signatures.py."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('align_signatures',
                                              ROOT / 'scripts/align-signatures.py')
ALIGN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ALIGN)


class SignatureTests(unittest.TestCase):
    """A temporary workspace holding one minimal package per scenario."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def entry(self, package, commentary, body):
        """Write PACKAGE's root entry with COMMENTARY lines and BODY code."""
        path = self.root / 'packages' / package / f'{package}.el'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f';;; {package}.el --- test fixture\n\n;;; Commentary:\n'
                        + '\n'.join(f';; {line}' if line.startswith(' ') else line
                                    for line in commentary)
                        + f'\n\n;;; Code:\n\n{body}\n\n(provide \'{package})\n'
                          f';;; {package}.el ends here\n',
                        encoding='utf-8')
        return path

    def run_align(self, package):
        """Align PACKAGE and return what it printed."""
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            ALIGN.align(self.root, package)
        return output.getvalue()

    def declared(self, path, name):
        """Return the one `;; Function: NAME` line written in PATH."""
        lines = [line for line in path.read_text(encoding='utf-8').splitlines()
                 if line.startswith(f';; Function: {name} ')]
        self.assertEqual(1, len(lines))
        return lines[0]

    def test_declaration_follows_the_definition_and_names_the_function(self):
        path = self.entry('alpha', [';; Function: alpha-open (id)',
                                    ';; Open ALPHA.'],
                          '(defun alpha-open (name)\n'
                          '  "Open NAME."\n'
                          '  name)')
        output = self.run_align('alpha')
        self.assertEqual(';; Function: alpha-open (name)', self.declared(path, 'alpha-open'))
        self.assertIn('alpha-open: (id) -> (name)', output)
        self.assertIn('alpha: 1 signature(s) aligned', output)

    def test_aligned_file_is_not_rewritten(self):
        path = self.entry('alpha', [';; Function: alpha-open (name)',
                                    ';; Open ALPHA.'],
                          '(defun alpha-open (name) name)')
        before = path.read_text(encoding='utf-8')
        output = self.run_align('alpha')
        self.assertEqual(before, path.read_text(encoding='utf-8'))
        self.assertIn('alpha: 0 signature(s) aligned', output)

    def test_wrapped_cl_defun_arguments_align_to_one_line(self):
        path = self.entry('beta', [';; Function: beta-run (job)',
                                   ';; Run BETA.'],
                          '(cl-defun beta-run (job\n'
                          '                    &key\n'
                          '                    (placeholder "two  spaces")\n'
                          '                    (predicate (lambda (x) (and x (list x))))\n'
                          '                    (on-change nil callback-p))\n'
                          '  "Run JOB."\n'
                          '  (when on-change\n'
                          '    (funcall on-change (list job (lambda () placeholder)\n'
                          '                             predicate))))')
        self.run_align('beta')
        expected = (';; Function: beta-run (job &key (placeholder "two  spaces") '
                    '(predicate (lambda (x) (and x (list x)))) '
                    '(on-change nil callback-p))')
        self.assertEqual(expected, self.declared(path, 'beta-run'))


if __name__ == '__main__':
    unittest.main()
