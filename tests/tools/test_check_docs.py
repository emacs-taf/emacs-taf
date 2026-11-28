"""Tests for scripts/check-docs.py (Layer-1/2 badge, link, anchor, banned pattern & elisp checks)."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_docs", ROOT / "scripts/check-docs.py")
DOCS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCS)


class CheckDocsTests(unittest.TestCase):
    def test_workspace_docs_pass(self):
        errors = DOCS.check_docs(ROOT)
        self.assertEqual([], errors, "\n".join(errors))

    def test_detects_broken_badge_anchor_retired_patterns_and_bad_elisp(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/structure.yml").write_text("name: Structure\n", encoding="utf-8")
            (root / "workspace.json").write_text(
                '{"schema": 3, "packages": {"etaf": {"path": "core/packages/etaf", "role": "framework"}}}',
                encoding="utf-8",
            )
            pkg = root / "core/packages/etaf"
            (pkg / "lisp").mkdir(parents=True)
            (pkg / "etaf.el").write_text(
                ";;; etaf.el --- test\n;;; Commentary:\n;; Function: etaf-open ()\n;; Open.\n"
                ";;; Code:\n(defun etaf-open () t)\n(provide 'etaf)\n",
                encoding="utf-8",
            )
            (pkg / "lisp/etaf-priv.el").write_text(
                "(defun etaf--secret () t)\n(provide 'etaf-priv)\n",
                encoding="utf-8",
            )
            (root / "README.md").write_text(
                "# Title\n\n"
                "[![Bad](https://github.com/emacs-taf/emacs-taf/actions/workflows/missing.yml/badge.svg)]"
                "(https://github.com/emacs-taf/emacs-taf/actions/workflows/missing.yml)\n\n"
                "See [missing anchor](#no-such-heading).\n\n"
                "```sh\ngit clone https://github.com/emacs-taf/etaf-ui.git\n```\n\n"
                "```elisp\n(etaf--secret)\n```\n\n"
                "```elisp\n(etaf-open\n```\n",
                encoding="utf-8",
            )
            errors = "\n".join(DOCS.check_docs(root))
            self.assertIn("missing .github/workflows/missing.yml", errors)
            self.assertIn("broken same-file heading anchor #no-such-heading", errors)
            self.assertIn("retired per-core-package git clone URL", errors)
            self.assertIn("internal symbol `etaf--secret`", errors)
            self.assertIn("unclosed '('", errors)


if __name__ == "__main__":
    unittest.main()
