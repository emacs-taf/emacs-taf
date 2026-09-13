"""Exercise the commit-message gate through its public command line."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CommitMessageTests(unittest.TestCase):
    def run_gate(self, text):
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt') as message:
            message.write(text)
            message.flush()
            return subprocess.run(['sh', str(ROOT / '.githooks/commit-msg'), message.name],
                                  cwd=ROOT, capture_output=True, text=True)

    def test_meaningful_normal_and_breaking_messages_pass(self):
        for header, footer in [('fix(layout): preserve table column units', ''),
                               ('feat(api)!: require explicit size units',
                                '\nBREAKING CHANGE: Wrap integer widths in (ch N).')]:
            with self.subTest(header=header):
                result = self.run_gate(header + '\n\nPreserve the public width contract.\n\nValidation: make check passed.\n' + footer)
                self.assertEqual(0, result.returncode, result.stderr)

    def test_malformed_or_uninformative_messages_fail(self):
        for text in ['', 'WIP', 'chore: update files\n\nCleanup.\n\nValidation: reviewed.',
                     'fix: preserve widths\nMissing blank line.\nValidation: passed.',
                     'fix: preserve widths\n\nExplain the fix.',
                     'fix: preserve widths\n\nValidation: make check passed.',
                     'feat(api)!: change sizes\n\nRequire units.\n\nValidation: passed.',
                     'feat: change sizes\n\nRequire units.\nValidation: passed.\nBREAKING CHANGE: Use units.',
                     'fix: ' + 'x' * 73 + '\n\nReason.\nValidation: passed.']:
            with self.subTest(text=text):
                self.assertNotEqual(0, self.run_gate(text).returncode)

    def test_unrun_validation_is_explicit_and_comments_are_ignored(self):
        result = self.run_gate('docs: clarify module ownership\n\nDocument current ownership.\n\nValidation: manual review; runtime checks not run for prose-only edit.\n# editor comment\n')
        self.assertEqual(0, result.returncode, result.stderr)


if __name__ == '__main__':
    unittest.main()
