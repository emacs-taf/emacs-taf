"""Contract of scripts/check-book.el: the book gate's inputs and reports."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
EMACS = os.environ.get('EMACS', 'emacs')

PROVIDER = {
    'etaf/etaf.el': """\
        ;;; etaf.el --- Fixture provider -*- lexical-binding: t; -*-
        ;; Version: 0.2.1
        ;;; Commentary:
        ;; Function: etaf-ref (initial-value &key test name)
        ;; Create a ref.
        ;;
        ;; Error: etaf-error
        ;; Fixture error.
        ;;; Code:
        (require 'cl-lib)
        (cl-defun etaf-ref (initial-value &key test name) (list initial-value test name))
        (define-error 'etaf-error "Fixture error")
        (provide 'etaf)
        """,
    'etaf/lisp/etaf-view.el': """\
        ;;; etaf-view.el --- Fixture internals -*- lexical-binding: t; -*-
        (defconst etaf--host-names '(text box))
        (defconst etaf--semantic-props '(:class))
        (defun etaf--commit (runtime &optional force) (list runtime force :on-press))
        (provide 'etaf-view)
        """,
    'etaf-ui/etaf-ui.el': """\
        ;;; etaf-ui.el --- Fixture UI provider -*- lexical-binding: t; -*-
        ;; Version: 0.1.0
        ;;; Commentary:
        ;; Component: etaf-button (&key label)
        ;; A button.
        ;;; Code:
        ;; Fixture token vocabulary: (:name :ui-fg :id ebox/color)
        (provide 'etaf-ui)
        """,
}

ENGLISH = """\
    # Reactivity

    A ref holds a value; see [refs](#refs) and [hosts](hosts.md#box-hosts). Create one with `etaf-ref`.

    | Message | Raised by |
    | --- | --- |
    | `"Stateful Component requires `etaf-mount'"` | `etaf-render` met a Component with `:setup` |

    ## Refs

    <!-- index: ref -->
    #### Function: etaf-ref (initial-value &key test name)
    #### Error: etaf-error
    #### Property: :on-press
    #### Token: :ui-fg

    The default foreground.

    #### Component: etaf-button (&key label)

    A button.

    ```elisp :run
    (etaf-ref 1)
    ```
    """

CHINESE = """\
    # 响应式

    ref 保存一个值；见[引用](#引用)与[Host](hosts.md#box-hosts)。用 `etaf-ref` 创建。

    | 消息 | 触发者 |
    | --- | --- |
    | `"Stateful Component requires `etaf-mount'"` | `etaf-render` 遇到带 `:setup` 的 Component |

    ## 引用

    <!-- index: 引用 -->
    #### Function: etaf-ref (initial-value &key test name)
    #### Error: etaf-error
    #### Property: :on-press
    #### Token: :ui-fg

    默认前景色。

    #### Component: etaf-button (&key label)

    一个按钮。

    ```elisp :run
    (etaf-ref 1)
    ```
    """

HOSTS = """\
    # Hosts

    ## Box hosts

    #### Host: box
    #### Host: text
    """


class CheckBookTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        for name, text in PROVIDER.items():
            self.write('providers/' + name, text)
        self.description = {
            'title': {'en': 'Fixture', 'zh-CN': '样例'},
            'languages': ['en', 'zh-CN'],
            'packages': ['etaf', 'etaf-ui'],
            'references': [],
            'coverage': ['etaf', 'etaf-ui'],
            'parts': [{'id': 'model', 'title': {'en': 'Model', 'zh-CN': '模型'},
                       'chapters': ['reactivity', 'hosts']}],
            'appendices': [
                {'id': 'theme-token-table', 'generate': 'token-table',
                 'title': {'en': 'Theme Token Table', 'zh-CN': '主题 token 表'}},
            ],
            'indices': [
                {'id': 'concept-index', 'generate': 'concept-index',
                 'title': {'en': 'Concept Index', 'zh-CN': '概念索引'}},
            ],
        }
        self.write_description()
        self.write('book/en/reactivity.md', ENGLISH)
        self.write('book/zh-CN/reactivity.md', CHINESE)
        self.write('book/en/hosts.md', HOSTS)
        self.write('book/zh-CN/hosts.md', HOSTS.replace('# Hosts', '# Host'))

    def tearDown(self):
        self.directory.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text))

    def write_description(self):
        self.write('book/book.json', json.dumps(self.description))

    def run_gate(self, *arguments):
        return subprocess.run(
            [EMACS, '-Q', '--batch', '-L', str(ROOT), '-L', str(ROOT / 'lisp'),
             '--eval', '(setq load-prefer-newer t)',
             '-l', str(ROOT / 'scripts/check-book.el'),
             '--book', str(self.root / 'book'), '--providers', str(self.root / 'providers'),
             *arguments],
            capture_output=True, text=True, timeout=60)

    def assert_reported(self, message):
        result = self.run_gate()
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn(message, result.stderr)

    def test_consistent_book_passes_and_reports_coverage(self):
        result = self.run_gate('--coverage')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('etaf          2 /    2', result.stdout)
        self.assertIn('etaf-ui       1 /    1', result.stdout)
        self.assertIn('tokens        1 /    1', result.stdout)
        self.assertIn('hosts         2 /    2', result.stdout)

    def test_unknown_generated_content_is_reported(self):
        self.description['appendices'] = [
            {'id': 'broken-table', 'generate': 'no-such-table',
             'title': {'en': 'Broken', 'zh-CN': '坏'}},
        ]
        self.write_description()
        self.assert_reported('<generated:no-such-table>:0: Unknown generated content')

    def test_signature_drift_is_reported(self):
        for language in ('en', 'zh-CN'):
            path = self.root / 'book' / language / 'reactivity.md'
            path.write_text(path.read_text().replace(
                'etaf-ref (initial-value &key test name)', 'etaf-ref (value)'))
        self.assert_reported('book/en/reactivity.md:12: signature of etaf-ref '
                             'differs from etaf Commentary: (initial-value &key test name)')

    def test_declared_coverage_requires_every_record(self):
        for language in ('en', 'zh-CN'):
            path = self.root / 'book' / language / 'reactivity.md'
            path.write_text(path.read_text().replace('#### Error: etaf-error\n', ''))
        self.assert_reported('error etaf-error has no definition entry (coverage: etaf)')

    def test_unknown_definitions_are_reported(self):
        for language in ('en', 'zh-CN'):
            path = self.root / 'book' / language / 'hosts.md'
            path.write_text(path.read_text() + '#### Host: grid\n#### Style: :flex-grow\n')
        result = self.run_gate()
        self.assertEqual(1, result.returncode)
        self.assertIn('unknown host grid', result.stderr)
        self.assertIn('unknown style :flex-grow', result.stderr)

    def test_package_versions_must_match_the_provider(self):
        for language in ('en', 'zh-CN'):
            path = self.root / 'book' / language / 'reactivity.md'
            path.write_text(path.read_text() + '\nWritten for `etaf 0.2.1` and `etaf 0.9`.\n')
        result = self.run_gate()
        self.assertEqual(1, result.returncode)
        self.assertIn('etaf is version 0.2.1, not 0.9', result.stderr)
        self.assertNotIn('not 0.2.1', result.stderr)

    def test_version_tables_must_match_the_entry_headers(self):
        english = """
        | Package | Version | Documented with |
        | --- | --- | --- |
        | `etaf` | 0.9.9 | Emacs 29.1 |
        """
        chinese = """
        | 包 | 版本 | 配套版本 |
        | --- | --- | --- |
        | `etaf` | 0.9.9 | Emacs 29.1 |
        """
        for language, table in (('en', english), ('zh-CN', chinese)):
            path = self.root / 'book' / language / 'reactivity.md'
            path.write_text(path.read_text() + textwrap.dedent(table))
        result = self.run_gate()
        self.assertEqual(1, result.returncode)
        self.assertEqual(
            2, result.stderr.count(
                'version table gives etaf 0.9.9, but its entry header is 0.2.1'),
            result.stderr)

    def test_version_tables_may_match_the_entry_headers(self):
        english = """
        | Package | Version | Documented with |
        | --- | --- | --- |
        | `etaf` | 0.2.1 | Emacs 29.1 |
        """
        chinese = """
        | 包 | 版本 | 配套版本 |
        | --- | --- | --- |
        | `etaf` | 0.2.1 | Emacs 29.1 |
        """
        for language, table in (('en', english), ('zh-CN', chinese)):
            path = self.root / 'book' / language / 'reactivity.md'
            path.write_text(path.read_text() + textwrap.dedent(table))
        result = self.run_gate()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_paragraphs_and_list_items_are_one_line(self):
        self.write('book/en/hosts.md', textwrap.dedent(HOSTS) + '\nA box holds\nchildren.\n\n- An item\n  continued.\n'
                   '- Another item.\n\n```elisp\n(etaf-ref\n 1)\n```\n')
        result = self.run_gate()
        self.assertEqual(1, result.returncode)
        self.assertIn('book/en/hosts.md:9: hard-wrapped line', result.stderr)
        self.assertIn('book/en/hosts.md:12: hard-wrapped line', result.stderr)
        self.assertEqual(2, result.stderr.count('hard-wrapped line'), result.stderr)

    def test_links_must_reach_a_heading_in_the_same_language(self):
        self.write('book/zh-CN/reactivity.md', CHINESE.replace('(#引用)', '(#refs)'))
        self.assert_reported('book/zh-CN/reactivity.md:3: link to unknown heading: #refs')
        self.write('book/zh-CN/reactivity.md', CHINESE.replace('hosts.md', 'views.md'))
        self.assert_reported('link to unknown chapter: views.md#box-hosts')

    def test_only_public_interfaces_are_documented(self):
        self.write('book/en/reactivity.md', ENGLISH.replace(
            'with `etaf-ref`.', 'with `etaf--commit` or `etaf-reff`.'))
        result = self.run_gate()
        self.assertEqual(1, result.returncode)
        self.assertIn("book/en/reactivity.md:3: `etaf--commit' is not a public interface",
                      result.stderr)
        self.assertIn("`etaf-reff' is not a public interface", result.stderr)
        self.write('book/en/reactivity.md', ENGLISH)
        self.write('book/en/hosts.md', HOSTS + '#### Internal Function: etaf--commit (runtime)\n')
        self.assert_reported('Level-4 headings are definition entries')

    def test_translations_keep_entries_sections_and_examples(self):
        self.write('book/zh-CN/reactivity.md',
                   CHINESE.replace('#### Error: etaf-error\n', '')
                   .replace('## 引用', '### 引用')
                   .replace('```elisp :run', '```elisp'))
        result = self.run_gate()
        self.assertEqual(1, result.returncode)
        for message in ('definition entries differ from en',
                        'section structure differs from en',
                        'runnable examples differ from en'):
            self.assertIn('book/zh-CN/reactivity.md:1: ' + message, result.stderr)

    def test_translations_keep_index_terms(self):
        self.write('book/zh-CN/reactivity.md',
                   CHINESE.replace('    <!-- index: 引用 -->\n', ''))
        self.assert_reported('book/zh-CN/reactivity.md:1: index terms differ from en')

    def test_unlisted_chapter_and_malformed_heading_are_reported(self):
        self.write('book/en/notes.md', '# Notes\n')
        self.assert_reported('book/en/notes.md:1: chapter is not listed in book.json')
        (self.root / 'book/en/notes.md').unlink()
        self.write('book/en/hosts.md', HOSTS + '#### Box details\n')
        self.assert_reported('Level-4 headings are definition entries')

    def append_hosts(self, block):
        for language in ('en', 'zh-CN'):
            path = self.root / 'book' / language / 'hosts.md'
            path.write_text(path.read_text() + textwrap.dedent(block))

    def test_result_lines_are_evaluated_and_compared(self):
        self.append_hosts("""
            ```elisp
            (+ 1 2)
            ;; ⇒ 3
            ```
        """)
        result = self.run_gate()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_a_wrong_result_line_is_reported(self):
        self.append_hosts("""
            ```elisp
            (+ 1 2)
            ;; ⇒ 4
            ```
        """)
        self.assert_reported('result line claims 4 but the form returns 3')

    def test_a_multiline_result_line_is_compared(self):
        self.append_hosts("""
            ```elisp
            (list 1
                  2)
            ;; ⇒ (1
            ;;    2)
            ```
        """)
        result = self.run_gate()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_a_described_result_line_is_not_compared(self):
        self.append_hosts("""
            ```elisp
            (list 1 2)
            ;; ⇒ a two-element list ; display
            ```
        """)
        result = self.run_gate()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_an_unreadable_result_line_is_reported(self):
        self.append_hosts("""
            ```elisp
            (list 1 2)
            ;; ⇒ (1
            ```
        """)
        self.assert_reported('result line is no readable value: (1')

    def test_a_result_line_without_a_form_is_reported(self):
        self.append_hosts("""
            ```elisp
            ;; ⇒ 3
            ```
        """)
        self.assert_reported('result line has no preceding form')

    def test_a_bare_result_line_is_not_evaluated(self):
        self.append_hosts("""
            ```elisp
            (error "boom")
            ⇒ 1
            ```
        """)
        result = self.run_gate()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_a_wrapped_bare_result_line_is_accepted(self):
        self.append_hosts("""
            ```elisp
            (list 1 2)
            ⇒ (1
               2)
            ```
        """)
        result = self.run_gate()
        self.assertEqual(0, result.returncode, result.stderr)

    def test_an_unreadable_bare_result_line_is_reported(self):
        self.append_hosts("""
            ```elisp
            (list 1 2)
            ⇒ (1
            ```
        """)
        self.assert_reported('result line is no readable value: (1')

    def test_a_bare_result_line_without_a_form_is_reported(self):
        self.append_hosts("""
            ```elisp
            ⇒ 3
            ```
        """)
        self.assert_reported('result line has no preceding form')

    def write_appendix(self, text):
        self.description['appendices'].append(
            {'id': 'standard-errors',
             'title': {'en': 'Standard Errors', 'zh-CN': '标准错误'}})
        self.write_description()
        self.write('book/en/standard-errors.md', text)
        self.write('book/zh-CN/standard-errors.md', text)

    def test_an_appendix_missing_a_record_is_reported(self):
        self.write_appendix("""\
            # Standard Errors

            | Condition | Parent | Signaled when |
            | --- | --- | --- |
        """)
        self.assert_reported('book/en/standard-errors.md:1: appendix does not list error etaf-error')

    def test_an_appendix_listing_every_record_passes(self):
        self.write_appendix("""\
            # Standard Errors

            | Condition | Parent | Signaled when |
            | --- | --- | --- |
            | `etaf-error` | `error` | A fixture error. |
        """)
        result = self.run_gate()
        self.assertEqual(0, result.returncode, result.stderr)


if __name__ == '__main__':
    unittest.main()
