;;; etaf-ui-markdown-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test the supported markdown parsing and rendering contract: document
;; structure, dialects, block and inline rendering, the environment
;; callbacks and the documented errors.  Internal helpers are outside this
;; contract.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'etaf-ui)

(defconst etaf-ui-markdown-test--palette
  '((:ink . "#1f2328") (:muted . "#59636e") (:faint . "#818b98")
    (:accent . "#0969da") (:accent-soft . "#ddf4ff") (:border . "#d1d9e0")
    (:panel . "#f6f8fa") (:panel2 . "#eef1f4") (:quote-bar . "#d1d9e0")
    (:quote-bg . "#f9fbfd") (:table-header . "#f0f3f6")
    (:table-stripe . "#fbfcfd") (:heading . "#1f2328") (:heading-rule . "#d1d9e0")
    (:ok . "#1a7f37") (:ok-soft . "#dafbe1") (:warn . "#9a6700")
    (:warn-soft . "#fff8c5") (:danger . "#d1242f") (:danger-soft . "#ffebe9")
    (:important . "#8250df") (:important-soft . "#fbefff"))
  "Palette covering every semantic key the markdown renderer reads.")

(defvar etaf-ui-markdown-test--code-calls 0
  "Number of `:render-code-block' calls of the current test.")

(defvar etaf-ui-markdown-test--media-calls 0
  "Number of `:render-media' calls of the current test.")

(defun etaf-ui-markdown-test--env (&rest overrides)
  "Return a rendering environment with OVERRIDES applied."
  (append overrides (list :palette etaf-ui-markdown-test--palette)))

(defun etaf-ui-markdown-test--mount (text env)
  "Mount TEXT rendered with ENV and return the buffer name."
  (let* ((document (etaf-ui-markdown-parse text))
         (env (append env (list :features (plist-get document :features))))
         (views (etaf-ui-markdown-view-blocks (plist-get document :children) env))
         (buffer-name (format " *etaf-ui-markdown-%s*" (cl-gensym))))
    (etaf-mount buffer-name
                (etaf-node 'column (list :width '(ch 60)) views))
    buffer-name))

(defun etaf-ui-markdown-test--text (buffer-name)
  "Return the plain text published in BUFFER-NAME."
  (with-current-buffer buffer-name
    (substring-no-properties (buffer-string))))

(defun etaf-ui-markdown-test--help (position)
  "Return the help text painted at POSITION, through any hover probe."
  (let ((help (get-text-property position 'help-echo)))
    (if (functionp help)
        (funcall help (selected-window) (current-buffer) position)
      help)))

(defmacro etaf-ui-markdown-test--with-mount (text env &rest body)
  "Mount TEXT rendered with ENV, evaluate BODY, then release the runtime."
  (declare (indent 2))
  `(let ((buffer-name (etaf-ui-markdown-test--mount ,text ,env)))
     (unwind-protect
         (progn ,@body)
       (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
         (etaf-unmount runtime))
       (when-let* ((buffer (get-buffer buffer-name)))
         (kill-buffer buffer)))))

(ert-deftest etaf-ui-markdown-a-soft-break-folds-into-one-line ()
  "A source line end inside a paragraph is a space, and a hard break a line end.
CommonMark reads the newline between two lines of one paragraph as a space, so
the paragraph flows and wraps at the page's own width; two trailing spaces or a
backslash is the author asking for a line end, and that paints a row of its
own."
  (etaf-ui-markdown-test--with-mount
      "alpha\nbeta\n\ngamma  \ndelta\n\nepsilon\\\nzeta\n"
      (etaf-ui-markdown-test--env)
    (let* ((text (etaf-ui-markdown-test--text buffer-name))
           (rows (mapcar #'string-trim (split-string text "\n"))))
      ;; The soft break folded: one row holds both words, in source order.
      (should (string-match-p "alpha beta" text))
      (should-not (member "alpha" rows))
      ;; The two hard spellings each start a row.
      (should (cl-position "gamma" rows :test #'string=))
      (should (= 1 (- (cl-position "delta" rows :test #'string=)
                      (cl-position "gamma" rows :test #'string=))))
      (should (= 1 (- (cl-position "zeta" rows :test #'string=)
                      (cl-position "epsilon" rows :test #'string=)))))))

(ert-deftest etaf-ui-markdown-parse-reports-document-structure ()
  "Parsing exposes the title, outline, blocks, footnotes and features."
  (let* ((document (etaf-ui-markdown-parse
                    "---\ntitle: Doc\n---\n\n# Intro\n\nText[^a].\n\n## Part\n\n[^a]: note\n"))
         (blocks (plist-get document :children))
         (types (mapcar (lambda (block) (plist-get block :type)) blocks)))
    (should (equal "Doc" (plist-get document :title)))
    (should (equal '((1 "Intro" "intro") (2 "Part" "part"))
                   (plist-get document :outline)))
    (should (equal '(heading paragraph heading) types))
    (should (equal '("a") (mapcar (lambda (note) (plist-get note :label))
                                  (plist-get document :footnotes))))
    (should (eq t (plist-get (plist-get document :features) :tables)))))

(ert-deftest etaf-ui-markdown-quote-adds-no-blank-line-of-its-own ()
  "A quote ends on the last line it was written with.
The source had no blank line inside the quote, so the rendered box must not
add one before its bottom edge."
  (etaf-ui-markdown-test--with-mount
      "Lead paragraph.\n\n> first quoted line\n> second quoted line\n\nTail.\n"
      (etaf-ui-markdown-test--env)
    (let* ((lines (split-string (etaf-ui-markdown-test--text buffer-name) "\n"))
           (quote-line (cl-position-if (lambda (line) (string-match-p "second quoted" line))
                                       lines))
           (tail-line (cl-position-if (lambda (line) (string-match-p "Tail" line))
                                      lines)))
      (should quote-line)
      (should tail-line)
      (should (= 1 (- tail-line quote-line 1))))))

(ert-deftest etaf-ui-markdown-quote-separates-its-blocks ()
  "A quote keeps one blank row between the blocks it holds.
A `>' line with nothing after it separates the paragraphs of a quote, so the
rendered quote separates them the way the top level separates its own blocks,
and it still ends on the last line of its last block."
  (etaf-ui-markdown-test--with-mount
      "> first quoted paragraph\n>\n> - a listed item\n\nTail.\n"
      (etaf-ui-markdown-test--env)
    (let* ((lines (split-string (etaf-ui-markdown-test--text buffer-name) "\n"))
           (first-line (cl-position-if (lambda (line) (string-match-p "first quoted" line)) lines))
           (item-line (cl-position-if (lambda (line) (string-match-p "a listed item" line)) lines))
           (tail-line (cl-position-if (lambda (line) (string-match-p "Tail" line)) lines)))
      (should first-line)
      (should item-line)
      (should tail-line)
      (should (= 2 (- item-line first-line)))
      (should (= 1 (- tail-line item-line 1))))))

(ert-deftest etaf-ui-markdown-a-blank-line-in-an-item-separates-paragraphs ()
  "A blank line inside a list item separates the paragraphs it wrote.
The item keeps that line, so the two paragraphs stay two and the render draws
the break between them instead of running them together as one paragraph."
  (let* ((text "- first paragraph\n\n  second paragraph\n")
         (block (car (plist-get (etaf-ui-markdown-parse text) :children)))
         (item (car (plist-get block :items))))
    (should-not (plist-get block :tight))
    (should (equal '(paragraph paragraph)
                   (mapcar (lambda (child) (plist-get child :type))
                           (plist-get item :children))))
    (etaf-ui-markdown-test--with-mount text (etaf-ui-markdown-test--env)
      (let* ((lines (split-string (etaf-ui-markdown-test--text buffer-name) "\n"))
             (first-line (cl-position-if (lambda (line) (string-match-p "first paragraph" line)) lines))
             (second-line (cl-position-if (lambda (line) (string-match-p "second paragraph" line)) lines)))
        (should first-line)
        (should second-line)
        (should (= 2 (- second-line first-line)))))))

(ert-deftest etaf-ui-markdown-quote-text-recedes-behind-its-surface ()
  "A quote paints its own text in the muted color.
The block keeps its surface and bar, and a link inside the quote keeps the
accent it sets for itself, so a quote reads as secondary content instead of
body text that somebody tinted."
  (etaf-ui-markdown-test--with-mount
      "Body text.\n\n> quoted line with [a link](https://example.com)\n\nAfter.\n"
      (etaf-ui-markdown-test--env)
    (with-current-buffer buffer-name
      (let ((color-at
             (lambda (needle)
               (goto-char (point-min))
               (search-forward needle)
               (let ((face (get-text-property (match-beginning 0) 'face)))
                 (cl-some (lambda (entry)
                            (and (listp entry) (plist-get entry :foreground)))
                          (if (keywordp (car-safe face)) (list face) face))))))
        (should (equal (cdr (assq :muted etaf-ui-markdown-test--palette))
                       (funcall color-at "quoted line")))
        (should (equal (cdr (assq :accent etaf-ui-markdown-test--palette))
                       (funcall color-at "a link")))
        ;; Body text outside the quote keeps no color of its own, so it keeps
        ;; following the buffer face.
        (should-not (funcall color-at "Body text"))))))

(ert-deftest etaf-ui-markdown-parse-etaf-preset-defines-terms ()
  "A term and the lines under it that start with `:' form one definition list."
  (let* ((document (etaf-ui-markdown-parse
                    "Term\n: first\n: second\n\nOther\n: third\n"))
         (block (car (plist-get document :children))))
    (should (eq 'definition-list (plist-get block :type)))
    (should (equal '("Term" "Other")
                   (mapcar (lambda (item) (plist-get item :term))
                           (plist-get block :items))))
    (should (= 2 (length (plist-get (car (plist-get block :items)) :definitions))))
    (should (= 1 (length (plist-get (cadr (plist-get block :items)) :definitions))))
    ;; The list claims its own lines only: the blank line that separates it
    ;; from the next block stays outside its range, so a renderer can paint it.
    (let* ((source "Term\n: first\n\n## 下一节\n")
           (next (etaf-ui-markdown-parse source))
           (paragraph (car (plist-get next :children))))
      (should (eq 'heading (plist-get (cadr (plist-get next :children)) :type)))
      (should (equal "\n" (substring source (plist-get paragraph :end)
                                      (1+ (plist-get paragraph :end))))))))

(ert-deftest etaf-ui-markdown-parse-scripts-and-math ()
  "Sub- and superscript become script characters; `$' math stays a formula.
A run the renderer cannot raise or lower keeps its source, and a price stays
money."
  (let* ((document (etaf-ui-markdown-parse
                    "H~2~O and x^2^ and $\\frac{a}{b}$ and $5\n"))
         (nodes (plist-get (car (plist-get document :children)) :children))
         (types (mapcar (lambda (node) (plist-get node :type)) nodes))
         (subscript (cl-find 'subscript nodes :key (lambda (n) (plist-get n :type))))
         (superscript (cl-find 'superscript nodes :key (lambda (n) (plist-get n :type))))
         (math (cl-find 'math nodes :key (lambda (n) (plist-get n :type)))))
    (should (equal '(subscript superscript math) (delq 'text types)))
    (should (equal "₂" (plist-get subscript :rendered)))
    (should (equal "²" (plist-get superscript :rendered)))
    (should (equal "\\frac{a}{b}" (plist-get math :text)))))

(ert-deftest etaf-ui-markdown-parse-a-display-formula-is-one-block ()
  "A `$$' fence holds a formula that the page draws as one centered line."
  (let* ((document (etaf-ui-markdown-parse "$$\n\\sqrt{c} \\le \\infty\n$$\n"))
         (block (car (plist-get document :children))))
    (should (eq 'math (plist-get block :type)))
    (should (plist-get block :display))
    (should (equal "√(c) ≤ ∞" (etaf-ui-markdown-math-text (plist-get block :text))))))

(ert-deftest etaf-ui-markdown-math-text-survives-a-backslash-in-a-script ()
  "A script body holding a TeX command keeps the page instead of signalling.
A command inside `^{}' reaches the replacement as raw TeX, and a replacement
string reads a lone backslash as a back-reference; the text rendering escapes
it and keeps the rest of the formula."
  (let ((integral (etaf-ui-markdown-math-text
                   "\\int_{0}^{\\infty} e^{-x^2} \\, dx = \\frac{\\sqrt{\\pi}}{2}")))
    (should (string-match-p (regexp-quote "√(π)/2") integral))
    (should (string-match-p "∫" integral))
    (should (equal "e(∞)" (etaf-ui-markdown-math-text "e^{\\infty}")))
    (should (equal "x(\\unknown)" (etaf-ui-markdown-math-text "x^{\\unknown}")))))

(ert-deftest etaf-ui-markdown-math-text-keeps-command-case ()
  "`\\pi' and `\\Pi' are different symbols, and a root goes before its fraction.
The symbol table holds both cases, so replacing case-insensitively would paint
every pi as a capital; a fraction of a root must also read as the root's value."
  (should (equal "π" (etaf-ui-markdown-math-text "\\pi")))
  (should (equal "Π" (etaf-ui-markdown-math-text "\\Pi")))
  (should (equal "√(x)/2" (etaf-ui-markdown-math-text "\\frac{\\sqrt{x}}{2}"))))

(ert-deftest etaf-ui-markdown-parse-an-abbreviation-carries-its-title ()
  "A defined abbreviation marks whole words only, and its definition paints nothing.
`HTML5' is not the abbreviation `HTML', so the title belongs to the word the
definition named."
  (let* ((document (etaf-ui-markdown-parse
                    "*[HTML]: HyperText Markup Language\n\nHTML and HTML5\n"))
         (blocks (plist-get document :children))
         (nodes (plist-get (car blocks) :children))
         (abbreviation (cl-find 'abbreviation nodes :key (lambda (n) (plist-get n :type)))))
    (should (= 1 (length blocks)))
    (should (equal "HTML" (plist-get abbreviation :text)))
    (should (equal "HyperText Markup Language" (plist-get abbreviation :title)))))

(ert-deftest etaf-ui-markdown-parse-a-narrower-preset-leaves-new-syntax-literal ()
  "`gfm' reads the added syntax as the text CommonMark sees.
A preset is a set of switches over one parser, so a document written for the
wide preset still parses here, with its syntax shown literally."
  (let* ((gfm (etaf-ui-markdown-parse "H~2~O\n" 'gfm))
         (nodes (plist-get (car (plist-get gfm :children)) :children)))
    (should (equal '((:type text :text "H~2~O"))
                   (mapcar (lambda (node) (list :type (plist-get node :type)
                                                :text (plist-get node :text)))
                           nodes)))))

(ert-deftest etaf-ui-markdown-etaf-syntax-paints-its-own-shapes ()
  "The added syntax paints: a term with its definition, a subscript, a formula."
  (etaf-ui-markdown-test--with-mount
      "Term\n: second\n\nH~2~O and $a/b$\n"
      (etaf-ui-markdown-test--env)
    (let ((text (etaf-ui-markdown-test--text buffer-name)))
      ;; The term is bold on its own line, and its definition sits behind a
      ;; quiet rule: the source's `:' marker is not repeated in the painter.
      (should (string-match-p "Term" text))
      (should (string-match-p "│  second" text))
      (should (string-match-p "H₂O" text))
      (should (string-match-p "a/b" text)))))

(ert-deftest etaf-ui-markdown-parse-a-shortcode-paints-its-emoji ()
  "A known `:name:' shortcode paints its character; anything else stays text.
A time, an unknown name and a document on the `gfm' preset all keep their
colons, so the syntax can never eat prose."
  (let* ((nodes (lambda (text &optional flavor)
                  (plist-get (car (plist-get (etaf-ui-markdown-parse text flavor)
                                             :children))
                             :children)))
         (emoji (funcall nodes "nice :tada: and :rocket:\n"))
         (time (funcall nodes "at 12:30:45 sharp\n"))
         (unknown (funcall nodes "keep :notanemoji: here\n"))
         ;; Chinese prose touches the shortcode on both sides: a Han character
         ;; is not a Latin word, so the shortcode still paints.
         (after-colon (funcall nodes "表情：:tada: 完成\n"))
         (before-han (funcall nodes ":rocket: 起飞\n"))
         (prose (funcall nodes "a:b: is prose\n"))
         ;; `:+1:' starts with a sign, and its name is in the table.
         (signed (funcall nodes "加一 :+1: 就够了\n"))
         (narrow (funcall nodes "nice :tada:\n" 'gfm)))
    (should (equal '("🎉" "🚀")
                   (mapcar (lambda (node) (plist-get node :char))
                           (seq-filter (lambda (node) (eq (plist-get node :type) 'emoji))
                                       emoji))))
    (should (equal "at 12:30:45 sharp"
                   (mapconcat (lambda (node) (or (plist-get node :char)
                                                 (plist-get node :text)))
                              time "")))
    (should (equal "keep :notanemoji: here"
                   (mapconcat (lambda (node) (or (plist-get node :char)
                                                 (plist-get node :text)))
                              unknown "")))
    (should (equal "表情：🎉 完成"
                   (mapconcat (lambda (node) (or (plist-get node :char)
                                                 (plist-get node :text)))
                              after-colon "")))
    (should (equal "🚀 起飞"
                   (mapconcat (lambda (node) (or (plist-get node :char)
                                                 (plist-get node :text)))
                              before-han "")))
    (should (equal "a:b: is prose"
                   (mapconcat (lambda (node) (or (plist-get node :char)
                                                 (plist-get node :text)))
                              prose "")))
    (should (equal "加一 👍 就够了"
                   (mapconcat (lambda (node) (or (plist-get node :char)
                                                 (plist-get node :text)))
                              signed "")))
    (should-not (seq-find (lambda (node) (eq (plist-get node :type) 'emoji)) narrow))))

(ert-deftest etaf-ui-markdown-parse-marks-icons-keys-and-badges ()
  "The added inline marks become their own nodes.
A comparison written `a == b' stays prose, and a mark's `{.class}' names the
fill; a key group keeps its separate keys and a badge its text and variant."
  (let* ((document (etaf-ui-markdown-parse
                    "a ==marked=={.warning} then a == b and :kbd[Ctrl+B] :badge[beta]{.tip} ::check:: :tada:\n"))
         (nodes (plist-get (car (plist-get document :children)) :children))
         (find (lambda (type) (cl-find type nodes :key (lambda (n) (plist-get n :type)))))
         (mark (funcall find 'mark))
         (kbd (funcall find 'kbd))
         (badge (funcall find 'badge))
         (icon (funcall find 'icon))
         (emoji (funcall find 'emoji)))
    (should (equal "warning" (plist-get mark :class)))
    (should (equal "marked" (plist-get (car (plist-get mark :children)) :text)))
    (should (equal '("Ctrl" "B") (plist-get kbd :keys)))
    (should (equal "beta" (plist-get badge :content)))
    (should (equal "tip" (plist-get badge :variant)))
    (should (equal "check" (plist-get icon :name)))
    (should (equal "🎉" (plist-get emoji :char)))
    (should (= 1 (seq-count (lambda (node) (eq (plist-get node :type) 'mark)) nodes)))))

(ert-deftest etaf-ui-markdown-etaf-inline-marks-paint ()
  "A highlighted run, a key group and a badge paint inside one paragraph."
  (etaf-ui-markdown-test--with-mount
      "a ==marked=={.warning} :kbd[Ctrl+B] :badge[beta]{.tip}\n"
      (etaf-ui-markdown-test--env)
    (let ((text (etaf-ui-markdown-test--text buffer-name)))
      (should (string-match-p "marked" text))
      (should (string-match-p "Ctrl" text))
      (should (string-match-p "beta" text)))))

(ert-deftest etaf-ui-markdown-parse-a-repeated-footnote-uses-its-first-definition ()
  "A label defined twice shows the first definition, and a reference to a label
that was never defined has no note to show."
  (let* ((duplicate (etaf-ui-markdown-parse
                     "a[^x] b[^y]\n\n[^x]: first\n\n[^x]: second\n\n[^y]: other\n"))
         (notes (plist-get duplicate :footnotes))
         (missing (plist-get (etaf-ui-markdown-parse "a[^nope]\n") :footnotes)))
    (should (equal '(("x" 1 "first") ("y" 2 "other"))
                   (mapcar (lambda (note)
                             (list (plist-get note :label) (plist-get note :number)
                                   (plist-get (car (plist-get note :children)) :text)))
                           notes)))
    (should-not missing)))

(ert-deftest etaf-ui-markdown-highlight-uses-the-modes-own-faces ()
  "Code is coloured by running its language's mode, not by a pattern of ours.
The assertion reads the weight a face sets, which is theme independent: a
language with no mode, or a block too large to fontify, stays one run."
  (let* ((runs (etaf-ui-markdown-highlight-code "elisp" "(defun f (x) (+ x 1))\n"))
         (plain (etaf-ui-markdown-highlight-code "no-such-language" "(defun f ())\n"))
         (weights (delq nil (mapcar (lambda (run) (plist-get (plist-get run :props)
                                                             :font-weight))
                                    runs))))
    (should (> (length runs) 1))
    (should (equal (apply #'concat (mapcar (lambda (run) (plist-get run :text)) runs))
                   "(defun f (x) (+ x 1))\n"))
    (should (memq 'bold weights))
    (should-not plain)))

(ert-deftest etaf-ui-markdown-code-fence-options-paint-their-block ()
  "A fence's title, line numbers and row paints reach the painted block.
The options live in the info string the way plume writes them, and the row
markers leave the painted code: a reader sees the title, the numbers and the
words, not the markers that chose the paint."
  (let* ((buffer (etaf-ui-markdown-test--mount
                  (concat "```elisp title=\"a.el\" :line-numbers=2\n"
                          "(defun f ())\n"
                          "(defun g ()) ; [!code ++]\n"
                          "```\n")
                  (etaf-ui-markdown-test--env))))
    (unwind-protect
        (let ((text (etaf-ui-markdown-test--text buffer)))
          (should (string-match-p "a.el" text))
          (should (string-match-p "复制" text))
          (should (string-match-p "2 (defun f ())" (replace-regexp-in-string "[[:space:]]+" " " text)))
          (should (string-match-p "3 +" (replace-regexp-in-string "[[:space:]]+" " " text)))
          (should (string-match-p "defun g" text))
          (should-not (string-match-p "\\[!code" text)))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-markdown-code-renderers-draw-their-language ()
  "A language with a registered renderer stops being painted as code.
The table is how a diagram language or a typesetter joins in without the parser
knowing about it; a language without an entry keeps the fenced block."
  (let ((etaf-ui-markdown-code-renderers
         (list (cons "mermaid"
                     (lambda (block env)
                       (declare (ignore env))
                       (etaf-node 'text nil (list (format "DIAGRAM:%s"
                                                          (plist-get block :text)))))))))
    (etaf-ui-markdown-test--with-mount "```mermaid\ngraph TD; A-->B\n```\n"
        (etaf-ui-markdown-test--env)
      (should (string-match-p "DIAGRAM:graph TD" (etaf-ui-markdown-test--text buffer-name))))
    (etaf-ui-markdown-test--with-mount "```text\nplain words\n```\n"
        (etaf-ui-markdown-test--env)
      (should (string-match-p "plain words" (etaf-ui-markdown-test--text buffer-name))))))

(ert-deftest etaf-ui-markdown-render-math-draws-the-formula ()
  "`:render-math' owns a display formula, and its absence keeps the text.
A caller that can typeset returns a View, so the block paints what that caller
drew instead of the plain-text approximation."
  (let ((env (etaf-ui-markdown-test--env
              :render-math
              (lambda (block env)
                (ignore env)
                (etaf-node 'text nil (list (format "TYPESET:%s"
                                                  (plist-get block :text))))))))
    (etaf-ui-markdown-test--with-mount "$$\\frac{a}{b}$$\n" env
      (let ((published (etaf-ui-markdown-test--text buffer-name)))
        (should (string-match-p (regexp-quote "TYPESET:\\frac{a}{b}") published))
        (should-not (string-match-p "a/b" published)))))
  (etaf-ui-markdown-test--with-mount "$$\\frac{a}{b}$$\n"
      (etaf-ui-markdown-test--env)
    (should (string-match-p "a/b" (etaf-ui-markdown-test--text buffer-name)))))

(ert-deftest etaf-ui-markdown-parse-dialect-gates-extensions ()
  "The `commonmark' dialect leaves GitHub extensions as literal text."
  (let ((gfm (etaf-ui-markdown-parse "| a | b |\n| --- | --- |\n| 1 | 2 |\n"))
        (core (etaf-ui-markdown-parse "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
                                      'commonmark)))
    (should (eq 'table (plist-get (car (plist-get gfm :children)) :type)))
    (should-not (eq 'table (plist-get (car (plist-get core :children)) :type)))))

(ert-deftest etaf-ui-markdown-parse-links-a-bare-url-in-a-long-paragraph ()
  "A bare URL inside a long paragraph becomes exactly one link.
Every `h' and `w' the paragraph contains is a candidate position, so the
parser has to reject them by comparing the text at that position.  A
paragraph of ordinary prose keeps its words and gets its URL."
  (let* ((prose (mapconcat (lambda (n) (format "word %d with h and w" n))
                           (number-sequence 1 200) " "))
         (blocks (plist-get (etaf-ui-markdown-parse
                             (concat prose " see https://example.com/a-b for why."))
                            :children))
         (children (plist-get (car blocks) :children))
         (links (cl-loop for node in children
                         when (eq (plist-get node :type) 'link)
                         collect (plist-get node :url)))
         (words (mapconcat (lambda (node)
                             (unless (eq (plist-get node :type) 'link)
                               (or (plist-get node :text) "")))
                           children "")))
    (should (eq 'paragraph (plist-get (car blocks) :type)))
    (should (equal '("https://example.com/a-b") links))
    (should (equal (concat prose " see " " for why.") words))))

(ert-deftest etaf-ui-markdown-parse-accepts-a-bare-www-url ()
  "A `www.' address resolves to an http link and keeps its own words.
The prefix check that rejects prose words must still accept the shorter
`www.' form."
  (let* ((blocks (plist-get (etaf-ui-markdown-parse "Visit www.example.org now.")
                            :children))
         (children (plist-get (car blocks) :children))
         (link (cl-find-if (lambda (node) (eq (plist-get node :type) 'link))
                           children))
         (words (mapconcat (lambda (node)
                             (unless (eq (plist-get node :type) 'link)
                               (or (plist-get node :text) "")))
                           children "")))
    (should (equal "http://www.example.org" (plist-get link :url)))
    (should (equal "Visit  now." words))))

(ert-deftest etaf-ui-markdown-parse-costs-the-same-as-its-own-paragraphs ()
  "One long paragraph costs no more than the same text as many paragraphs.
Prose makes every `h' and `w' an autolink candidate, so a parser that looks
for the next prefix from each candidate instead of comparing the characters
at it turns the paragraph into quadratic work.  Comparing the same text
parsed as paragraphs keeps this check independent of machine speed."
  (let* ((unit (mapconcat (lambda (n) (format "word %d with h and w" n))
                          (number-sequence 1 60) " "))
         (one (mapconcat (lambda (n) (format "%s line %d" unit n))
                         (number-sequence 1 120) "\n"))
         (many (mapconcat (lambda (n) (format "%s line %d" unit n))
                          (number-sequence 1 120) "\n\n"))
         (time (lambda (text)
                 (let ((start (float-time)))
                   (etaf-ui-markdown-parse text)
                   (- (float-time) start)))))
    (should (eq 'paragraph (plist-get (car (plist-get (etaf-ui-markdown-parse one)
                                                      :children))
                                      :type)))
    (should (= 120 (length (plist-get (etaf-ui-markdown-parse many) :children))))
    ;; The fastest of three runs each way; a garbage collection slows a run
    ;; instead of faking a quadratic one.
    (let ((single (apply #'min (cl-loop repeat 3 collect (funcall time one))))
          (split (apply #'min (cl-loop repeat 3 collect (funcall time many)))))
      (should (< single (* 8 (max split 0.001)))))))

(ert-deftest etaf-ui-markdown-parse-rejects-unknown-flavor ()
  "An unknown dialect name signals the documented error."
  (should-error (etaf-ui-markdown-parse "# x\n" 'markdown-extras)
                :type 'etaf-ui-markdown-error))

(ert-deftest etaf-ui-markdown-render-requires-a-palette ()
  "Rendering a colored block without its palette signals the error."
  (let ((blocks (plist-get (etaf-ui-markdown-parse "## Heading\n") :children)))
    (should-error (etaf-ui-markdown-view-blocks blocks (list))
                  :type 'etaf-ui-markdown-error)
    (should-error (etaf-ui-markdown-view-blocks
                   blocks (list :palette '((:ink . "#000000"))))
                  :type 'etaf-ui-markdown-error)))

(ert-deftest etaf-ui-markdown-renders-blocks-and-inline-styles ()
  "A document renders headings, lists, code, tables, quotes and alerts."
  (let ((text (concat "# Title\n\n"
                      "<!-- index: invisible marker -->\n\n"
                      "Plain **bold** and `code` paragraph.\n\n"
                      "- first\n- second\n\n"
                      "```elisp\n(message \"hi\")\n```\n\n"
                      "| Name | Value |\n| --- | --- |\n| alpha | 1 |\n\n"
                      "> quoted line\n\n"
                      "> [!NOTE]\n> alert body\n")))
    (etaf-ui-markdown-test--with-mount
        text (etaf-ui-markdown-test--env)
      (let ((published (etaf-ui-markdown-test--text buffer-name)))
        (should (string-match-p "Title" published))
        (should-not (string-match-p "index: invisible" published))
        (should (string-match-p "Plain bold and code paragraph\\." published))
        (should (string-match-p "• first" published))
        (should (string-match-p "(message \"hi\")" published))
        (should (string-match-p "alpha" published))
        (should (string-match-p "quoted line" published))
        (should (string-match-p "Note" published))
        (should (string-match-p "alert body" published))))))

(ert-deftest etaf-ui-markdown-task-list-marks-done-and-open-items ()
  "A task list marks a done item and an open item with different glyphs.
Both marks come from the text's own font, so the done and open items share
one box geometry and the column stays even; the fill shows the state."
  (let ((text (concat "- [x] 已完成的一项\n"
                      "- [ ] 未完成的一项\n"
                      "- 普通条目\n")))
    (etaf-ui-markdown-test--with-mount
        text (etaf-ui-markdown-test--env)
      (let ((published (etaf-ui-markdown-test--text buffer-name)))
        (should (string-match-p "■ 已完成的一项" published))
        (should (string-match-p "□ 未完成的一项" published))
        (should (string-match-p "• 普通条目" published))
        (should-not (string-match-p "\\[x\\]" published))
        (should-not (string-match-p "\\[ \\]" published))
        ;; The two marks sit in the same column, so the words line up.
        (let* ((lines (split-string published "\n" t))
               (done (cl-find-if (lambda (line) (string-match-p "已" line)) lines))
               (todo (cl-find-if (lambda (line) (string-match-p "未" line)) lines)))
          (should done)
          (should todo)
          (should (equal (string-match "已" done) (string-match "未" todo))))))))

(ert-deftest etaf-ui-markdown-callbacks-replace-media-and-code ()
  "`:render-code-block' and `:render-media' own the rendered block."
  (setq etaf-ui-markdown-test--code-calls 0
        etaf-ui-markdown-test--media-calls 0)
  (let ((env (etaf-ui-markdown-test--env
              :render-code-block
              (lambda (block env)
                (ignore block env)
                (setq etaf-ui-markdown-test--code-calls
                      (1+ etaf-ui-markdown-test--code-calls))
                (etaf-node 'text nil (list "CUSTOM-CODE")))
              :render-media
              (lambda (kind node env)
                (ignore kind node env)
                (setq etaf-ui-markdown-test--media-calls
                      (1+ etaf-ui-markdown-test--media-calls))
                (etaf-node 'text nil (list "CUSTOM-MEDIA"))))))
    (etaf-ui-markdown-test--with-mount
        "```\nraw code\n```\n\n![alt text](missing.png)\n" env
      (let ((published (etaf-ui-markdown-test--text buffer-name)))
        (should (= 1 etaf-ui-markdown-test--code-calls))
        (should (= 1 etaf-ui-markdown-test--media-calls))
        (should (string-match-p "CUSTOM-CODE" published))
        (should (string-match-p "CUSTOM-MEDIA" published))
        (should-not (string-match-p "raw code" published))))))

(ert-deftest etaf-ui-markdown-media-falls-back-to-text ()
  "Without `:render-media' an image renders as its alt text."
  (etaf-ui-markdown-test--with-mount
      "![the alt text](missing.png)\n" (etaf-ui-markdown-test--env)
    (should (string-match-p "\\[the alt text\\]"
                            (etaf-ui-markdown-test--text buffer-name)))))

(ert-deftest etaf-ui-markdown-alert-labels-override-defaults ()
  "`:alert-labels' replaces the callout label of its kind only."
  (etaf-ui-markdown-test--with-mount
      "> [!WARNING]\n> body\n" (etaf-ui-markdown-test--env
                                :alert-labels '((warning . "当心")))
    (let ((published (etaf-ui-markdown-test--text buffer-name)))
      (should (string-match-p "当心" published))
      (should-not (string-match-p "Warning" published)))))

(defun etaf-ui-markdown-test--scaled-text (buffer-name)
  "Return the published characters of BUFFER-NAME whose face sets a height."
  (with-current-buffer buffer-name
    (let ((scaled nil))
      (dotimes (index (buffer-size))
        (let ((faces (get-text-property (1+ index) 'face)))
          (when (cl-some (lambda (face)
                           (and (consp face) (keywordp (car face))
                                (plist-get face :height)))
                         (if (and (consp faces) (keywordp (car faces)))
                             (list faces)
                           (ensure-list faces)))
            (push (char-after (1+ index)) scaled))))
      (concat (nreverse scaled)))))

(defun etaf-ui-markdown-test--background (buffer-name position)
  "Return the face background at POSITION in BUFFER-NAME, or nil."
  (with-current-buffer buffer-name
    (let ((face (get-text-property position 'face)))
      (cl-loop for spec in (if (and (consp face) (keywordp (car face)))
                               (list face)
                             (ensure-list face))
               when (and (consp spec) (plist-get spec :background))
               return (plist-get spec :background)))))

(ert-deftest etaf-ui-markdown-line-grid-keeps-body-size ()
  "`:line-grid' renders headings and footnote references at the body size."
  (let ((text "# Title\n\n## Part\n\nBody[^n]\n\n[^n]: note\n"))
    (etaf-ui-markdown-test--with-mount text (etaf-ui-markdown-test--env)
      (let ((scaled (etaf-ui-markdown-test--scaled-text buffer-name)))
        (should (string-match-p "Title" scaled))
        (should (string-match-p "Part" scaled))))
    (etaf-ui-markdown-test--with-mount
        text (etaf-ui-markdown-test--env :line-grid t)
      (let ((scaled (etaf-ui-markdown-test--scaled-text buffer-name))
            (published (etaf-ui-markdown-test--text buffer-name)))
        (should (equal "" scaled))
        (should (string-match-p "Title" published))
        (should (string-match-p "Part" published))))))

(ert-deftest etaf-ui-markdown-blocks-carry-their-source-range ()
  "Every top-level block carries the half-open range of its own source.
A caller maps an edit to the block that holds it from that range instead of
searching the document again, so the range must slice back to the block's text
and the blocks must stay in document order."
  (let* ((text (concat "# Title\n\n"
                       "First paragraph\nspanning two lines.\n\n"
                       "```elisp\n(+ 1 2)\n```\n\n"
                       "| a | b |\n| --- | --- |\n| 1 | 2 |\n"))
         (blocks (plist-get (etaf-ui-markdown-parse text) :children)))
    (should (= 4 (length blocks)))
    (let ((previous 0))
      (dolist (block blocks)
        (should (>= (plist-get block :begin) previous))
        (should (> (plist-get block :end) (plist-get block :begin)))
        (setq previous (plist-get block :end))))
    (cl-flet ((source (block)
                (string-trim-right
                 (substring text (plist-get block :begin) (plist-get block :end))
                 "\n")))
      (should (equal "# Title" (source (nth 0 blocks))))
      (should (equal "First paragraph\nspanning two lines." (source (nth 1 blocks))))
      (should (equal "```elisp\n(+ 1 2)\n```" (source (nth 2 blocks))))
      (should (equal "| a | b |\n| --- | --- |\n| 1 | 2 |" (source (nth 3 blocks)))))))

(ert-deftest etaf-ui-markdown-a-definition-list-splits-the-paragraph-range ()
  "A paragraph read with its definition list gives each block its own range.
One clause pushes both blocks, so each must be sliced on its own: a caller
that splices an edited document on these ranges cannot tell the two apart
when the paragraph ends where the list begins."
  (let* ((text "前言一行\n术语行\n: 定义一行\n\n后面的段落。\n")
         (blocks (plist-get (etaf-ui-markdown-parse text) :children)))
    (should (equal '(paragraph definition-list paragraph)
                   (mapcar (lambda (block) (plist-get block :type)) blocks)))
    (should (equal '("前言一行\n" "术语行\n: 定义一行\n" "后面的段落。\n")
                   (mapcar (lambda (block)
                             (substring text (plist-get block :begin)
                                        (plist-get block :end)))
                           blocks)))))

(ert-deftest etaf-ui-markdown-an-alert-puts-its-text-under-the-label ()
  "An alert paints its label and then its text, with no row between them.
The marker sits on its own line, and the line break that ended it stayed at the
head of the paragraph after the marker was removed, so every callout opened
with an empty row."
  (etaf-ui-markdown-test--with-mount
      "> [!NOTE]\n> 正文一行。\n"
      (etaf-ui-markdown-test--env)
    (let ((lines (split-string (etaf-ui-markdown-test--text buffer-name) "\n")))
      (should (string-match-p "Note\\|笔记" (nth 0 lines)))
      (should-not (string-blank-p (nth 1 lines)))
      (should (string-match-p "正文一行" (nth 1 lines))))))

(ert-deftest etaf-ui-markdown-a-cell-keeps-an-escaped-pipe ()
  "A pipe written `\\|' stays inside its cell; the others split cells.
Splitting on every pipe lost the cell the escape protects, which is the only
way a table can show a pipe at all."
  (let* ((text "| a \\| b | c |\n| --- | --- |\n| 1 \\| 2 | 3 |\n")
         (table (car (plist-get (etaf-ui-markdown-parse text) :children)))
         (cells (lambda (row)
                  (mapcar (lambda (cell)
                            (mapconcat (lambda (node) (or (plist-get node :text) ""))
                                       cell ""))
                          row))))
    (should (= 2 (length (plist-get table :header))))
    (should (equal '("a | b" "c") (funcall cells (plist-get table :header))))
    (should (equal '(("1 | 2" "3")) (mapcar (lambda (row) (funcall cells row))
                                            (plist-get table :rows))))))

(ert-deftest etaf-ui-markdown-a-new-delimiter-starts-a-new-list ()
  "A numbered list that changes its delimiter starts again from its own number.
CommonMark reads `3.' and `1)' as two lists; sharing one made the second list
continue at 6 and 7 instead of showing the numbers the source wrote."
  (let* ((text "3. 三\n4. 四\n\n1) 圆括号一\n2) 圆括号二\n")
         (lists (plist-get (etaf-ui-markdown-parse text) :children)))
    (should (= 2 (length lists)))
    (should (equal '(3 1) (mapcar (lambda (list) (plist-get list :start)) lists)))
    (etaf-ui-markdown-test--with-mount text (etaf-ui-markdown-test--env)
      (let ((painted (etaf-ui-markdown-test--text buffer-name)))
        (should (string-match-p "^3\\. 三" painted))
        (should (string-match-p "^4\\. 四" painted))
        (should (string-match-p "^1\\. 圆括号一" painted))
        (should (string-match-p "^2\\. 圆括号二" painted))))))

(ert-deftest etaf-ui-markdown-list-mark-takes-one-cell-before-its-text ()
  "A list mark sits one cell before its text, and a wider number keeps the column.
A fixed marker column leaves a gap as wide as a CJK character after a single
mark, so the text starts far from its bullet; the column now fits the widest
mark of its own list and one cell of air."
  (etaf-ui-markdown-test--with-mount
      "- 第一项\n\n9. 第九项\n10. 第十项\n\n- [x] 完成\n"
      (etaf-ui-markdown-test--env)
    (let ((text (etaf-ui-markdown-test--text buffer-name)))
      (should (string-match-p "^• 第一项" text))
      (should (string-match-p "^ 9\\. 第九项" text))
      (should (string-match-p "^10\\. 第十项" text))
      (should (string-match-p "^■ 完成" text)))))

(ert-deftest etaf-ui-markdown-table-columns-follow-content ()
  "Table columns take width in proportion to their content and wrap by word."
  (let ((long "alpha bravo charlie delta echo foxtrot"))
    (etaf-ui-markdown-test--with-mount
        (format "| k | text |\n| --- | --- |\n| a | %s |\n" long)
        (etaf-ui-markdown-test--env)
      (let ((published (etaf-ui-markdown-test--text buffer-name)))
        (should (string-match-p (regexp-quote long) published))))
    (etaf-ui-markdown-test--with-mount
        (format "| text | more |\n| --- | --- |\n| %s | %s |\n" long long)
        (etaf-ui-markdown-test--env)
      (let ((published (etaf-ui-markdown-test--text buffer-name)))
        (dolist (word (split-string long))
          (should (string-match-p (format "\\_<%s\\_>" word) published)))))))

(defun etaf-ui-markdown-test--ruler (line)
  "Return the display columns of LINE's cell borders.
LINE is a rendered table row.  Each character is measured the way the
buffer shows it: a space whose `display' property stands for a wider gap
counts that width, and a plain character counts its own."
  (let ((column 0) (positions nil) (index 0) (width (length line)))
    (while (< index width)
      (let* ((char (aref line index))
             (display (get-text-property index 'display line))
             (step (cond
                    ((and (consp display) (eq (car display) 'space))
                     (let ((width (plist-get (cdr display) :width)))
                       (cond ((numberp width) width)
                             ((consp width) (or (car width) 1))
                             (t 1))))
                    ((stringp display) (string-width display))
                    (t (string-width (string char))))))
        (when (eq char ?│) (push column positions))
        (setq column (+ column step) index (1+ index))))
    (nreverse positions)))

(defun etaf-ui-markdown-test--border-columns (buffer-name)
  "Return the border columns of every table row in BUFFER-NAME."
  (with-current-buffer buffer-name
    (let (rulers)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring (line-beginning-position)
                                        (line-end-position))))
            (when (string-match-p "│" (substring-no-properties line))
              (push (etaf-ui-markdown-test--ruler line) rulers)))
          (forward-line 1)))
      (nreverse rulers))))

(ert-deftest etaf-ui-markdown-table-weights-its-lines ()
  "A table rules every cell, and the frames it draws are the ones the page owns.
Every row carries the rule between its cells, so the columns stay apart.  The
header's rule, the cell rules and the table's frame differ only in weight, which
the batch renderer does not paint: the GUI captures carry that half."
  (etaf-ui-markdown-test--with-mount
      (concat "| Option | Meaning |\n"
              "| --- | --- |\n"
              "| :at | Where the panel sits |\n"
              "| :width | Content columns |\n")
      (etaf-ui-markdown-test--env)
    (let* ((text (etaf-ui-markdown-test--text buffer-name))
           (rows (cl-remove-if-not (lambda (line) (string-match-p "\u2502" line))
                                   (split-string text "\n"))))
      (should (= 3 (length rows)))
      (should (string-match-p "Option" (car rows)))
      (should (string-match-p ":width" (car (last rows))))
      ;; A row of two columns shows the table's two frame edges and the one
      ;; rule between the cells.
      (should (cl-every (lambda (row) (= 3 (cl-count ?\u2502 row))) rows)))))

(ert-deftest etaf-ui-markdown-table-rows-share-one-column-grid ()
  "Every row of a table rules its cells in the same display columns.
A cell whose content is wider than its neighbours must not push that row's
columns out of line: the table resolves one set of tracks for all rows."
  (etaf-ui-markdown-test--with-mount
      (concat "| Option | Value | Default | Meaning |\n"
              "| --- | --- | --- | --- |\n"
              "| :at | placement | point | Where the panel sits |\n"
              "| :focus-on-open | t, nil | :focusable | Select it on open |\n"
              "| :width | columns | 56 | Content columns |\n")
      (etaf-ui-markdown-test--env)
    (let ((rulers (etaf-ui-markdown-test--border-columns buffer-name)))
      (should (>= (length rulers) 4))
      (should (cl-every (lambda (row) (equal row (car rulers))) rulers)))))

(ert-deftest etaf-ui-markdown-table-keeps-unbroken-columns ()
  "A column is never narrower than the widest unbreakable cell text."
  (let ((identifier "etaf-manual-reader--section")
        (prose (concat "this is a very long description with many many words "
                       "that push the fraction to the cap")))
    (etaf-ui-markdown-test--with-mount
        (format "| Property | Inheritance | Meaning |\n| --- | --- | --- |\n| `%s` | 继承 | %s |\n"
                identifier prose)
        (etaf-ui-markdown-test--env)
      (let ((published (etaf-ui-markdown-test--text buffer-name)))
        (should (string-match-p (regexp-quote identifier) published))
        (should (string-match-p "继承" published))))))

(ert-deftest etaf-ui-markdown-code-link-links-a-code-span ()
  "`:code-link' makes a code span a link without losing its code style."
  (let ((opened nil)
        (asked nil))
    (etaf-ui-markdown-test--with-mount
        "Plain `target` and `untouched` spans.\n"
        (etaf-ui-markdown-test--env
         :open-link (lambda (url) (push url opened))
         :code-link (lambda (text)
                      (push text asked)
                      (when (equal text "target")
                        (cons "app:target" "Go to target"))))
      (let* ((published (etaf-ui-markdown-test--text buffer-name))
             (position (string-match "target" published))
             (untouched (string-match "untouched" published)))
        (should (= 2 (length asked)))
        (should (member "target" asked))
        (should (member "untouched" asked))
        (should position)
        (with-current-buffer buffer-name
          (should (equal "Go to target"
                         (etaf-ui-markdown-test--help (1+ position))))
          (should (get-text-property (1+ position) 'face))
          (should-not (get-text-property (1+ untouched) 'help-echo))
          ;; Activation needs a live text window; RET over the span runs the
          ;; link callback exactly like a click.
          (set-window-buffer (selected-window) (current-buffer))
          (goto-char (1+ position))
          (execute-kbd-macro (kbd "RET")))
        (should (equal '("app:target") opened))))))

(ert-deftest etaf-ui-markdown-code-link-inside-a-link-keeps-one-decoration ()
  "A linked code span that is also a code link renders without a duplicate."
  (etaf-ui-markdown-test--with-mount
      "A [`target`](app:link) span.\n"
      (etaf-ui-markdown-test--env
       :code-link (lambda (text)
                    (when (equal text "target")
                      (cons "app:target" "Go to target"))))
    (let* ((published (etaf-ui-markdown-test--text buffer-name))
           (position (string-match "target" published)))
      (should position)
      (with-current-buffer buffer-name
        (should (equal "Go to target"
                       (etaf-ui-markdown-test--help (1+ position))))))))

(ert-deftest etaf-ui-markdown-code-bg-colors-code-spans ()
  "A `:code-bg' palette entry colors inline code; without it code uses `:panel'."
  (etaf-ui-markdown-test--with-mount
      "A `span` here.\n" (etaf-ui-markdown-test--env)
    (should (equal "#f6f8fa"
                   (etaf-ui-markdown-test--background
                    buffer-name (1+ (string-match "span"
                                                  (etaf-ui-markdown-test--text buffer-name)))))))
  (etaf-ui-markdown-test--with-mount
      "A `span` here.\n"
      (etaf-ui-markdown-test--env :palette (cons '(:code-bg . "#123456")
                                                 etaf-ui-markdown-test--palette))
    (should (equal "#123456"
                   (etaf-ui-markdown-test--background
                    buffer-name (1+ (string-match "span"
                                                  (etaf-ui-markdown-test--text buffer-name))))))))

(ert-deftest etaf-ui-markdown-table-keeps-short-cjk-cells-whole ()
  "A tight table column still fits a short CJK word on one line.
The container holds both the words and the columns' alignment; a table that
cannot fit the words at all wraps them, so the case is measured at the width
its columns need."
  (let* ((document (etaf-ui-markdown-parse
                    (concat "| Style | 初值 | 适用 | 继承 | 影响 |\n"
                            "| --- | --- | --- | --- | --- |\n"
                            "| 颜色字符串或 currentColor | nil | 所有节点 | 是 | 绘制 |\n")))
         (env (etaf-ui-markdown-test--env :features (plist-get document :features)))
         (views (etaf-ui-markdown-view-blocks (plist-get document :children) env))
         (buffer-name (format " *etaf-ui-markdown-%s*" (cl-gensym))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-node 'column (list :width '(ch 56)) views))
          (let ((published (etaf-ui-markdown-test--text buffer-name)))
            (dolist (word '("初值" "适用" "继承" "影响"))
              (should (string-match-p (regexp-quote word) published)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-markdown-links-hover-with-the-accent-tint ()
  "A rendered link carries the accent-soft hover face."
  (etaf-ui-markdown-test--with-mount
      "A [site](https://example.com) and `code` here.\n" (etaf-ui-markdown-test--env)
    (with-current-buffer buffer-name
      (let ((position (1+ (string-match "site" (buffer-string)))))
        (should (equal "#ddf4ff"
                       (plist-get (get-text-property position 'mouse-face)
                                  :background)))))))

(ert-deftest etaf-ui-markdown-link-hover-can-be-disabled ()
  "Setting `:link-hover nil' in ENV removes link `mouse-face' while keeping links active."
  (let ((clicked nil))
    (etaf-ui-markdown-test--with-mount
        "A [site](https://example.com) here.\n"
        (etaf-ui-markdown-test--env
         :link-hover nil
         :open-link (lambda (url) (push url clicked)))
      (with-current-buffer buffer-name
        (let ((position (1+ (string-match "site" (buffer-string)))))
          (should-not (get-text-property position 'mouse-face))
          (should (eq 'hand (get-text-property position 'pointer)))
          (goto-char position)
          (call-interactively (key-binding (kbd "RET")))
          (should (equal clicked '("https://example.com"))))))))

(ert-deftest etaf-ui-markdown-html-media-forwards-declared-dimensions ()
  "Raw HTML media tags pass declared pixel `:width' and `:height' to `:render-media'."
  (let ((calls nil))
    (etaf-ui-markdown-test--with-mount
        (concat "<img src=\"icon.svg\" alt=\"ETAF\" width=\"52\" height=\"52\">\n\n"
                "<img src=\"logo.svg\" alt=\"\" width=\"40px\" height=\"40px\">\n\n"
                "<img src=\"banner.png\" width=240 height=\"100%\">\n")
        (etaf-ui-markdown-test--env
         :render-media
         (lambda (kind node _env)
           (push (list kind
                       (plist-get node :url)
                       (plist-get node :alt)
                       (plist-get node :width)
                       (plist-get node :height))
                 calls)
           (etaf-node 'text nil (list "media"))))
      (let ((seen (nreverse calls)))
        (should (equal seen
                       '((image "icon.svg" "ETAF" 52 52)
                         (image "logo.svg" "" 40 40)
                         (image "banner.png" nil 240 nil))))))))

(ert-deftest etaf-ui-markdown-heading-underline-can-be-disabled ()
  "Setting `:heading-underline nil' suppresses H1/H2 rules and heading link underlines."
  (let ((clicked nil))
    (cl-labels ((face-underlined-p (f)
                  (cond
                   ((not (listp f)) nil)
                   ((keywordp (car f)) (and (plist-get f :underline) t))
                   (t (cl-some #'face-underlined-p f)))))
      (etaf-ui-markdown-test--with-mount
          (concat "# Top Heading\n\n"
                  "## [Linked Heading](https://example.com/h)\n\n"
                  "Read [Body Link](https://example.com/b) text.\n")
          (etaf-ui-markdown-test--env
           :heading-underline nil
           :open-link (lambda (url) (push url clicked)))
        (with-current-buffer buffer-name
          (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "^[ \t]*─\\{8,\\}[ \t]*$" plain)))
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (hpos (1+ (string-match "Linked Heading" text)))
                 (hface (get-text-property hpos 'face))
                 (bpos (1+ (string-match "Body Link" text)))
                 (bface (get-text-property bpos 'face)))
            (should-not (face-underlined-p hface))
            (should (eq 'hand (get-text-property hpos 'pointer)))
            (should (face-underlined-p bface))
            (goto-char hpos)
            (call-interactively (key-binding (kbd "RET")))
            (should (equal clicked '("https://example.com/h")))))))))

(ert-deftest etaf-ui-markdown-inline-delimiters-skip-code-spans ()
  "Emphasis, strikethrough and highlight delimiters ignore matching tokens inside inline code."
  (let* ((doc (etaf-ui-markdown-parse
               "Check **bold `a*b` end**, ~~del `x~~y` end~~ and ==mark `p==q` end==.\n"))
         (children (plist-get (car (plist-get doc :children)) :children))
         (strong (cl-find 'strong children :key (lambda (n) (plist-get n :type))))
         (strike (cl-find 'strike children :key (lambda (n) (plist-get n :type))))
         (mark (cl-find 'mark children :key (lambda (n) (plist-get n :type)))))
    (should strong)
    (should (cl-some (lambda (n) (and (eq (plist-get n :type) 'code)
                                      (equal (plist-get n :text) "a*b")))
                     (plist-get strong :children)))
    (should strike)
    (should (cl-some (lambda (n) (and (eq (plist-get n :type) 'code)
                                      (equal (plist-get n :text) "x~~y")))
                     (plist-get strike :children)))
    (should mark)
    (should (cl-some (lambda (n) (and (eq (plist-get n :type) 'code)
                                      (equal (plist-get n :text) "p==q")))
                     (plist-get mark :children)))))

(ert-deftest etaf-ui-markdown-math-text-preserves-escaped-braces ()
  "`etaf-ui-markdown-math-text' keeps escaped set braces `\\{' and `\\}'."
  (let ((rendered (etaf-ui-markdown-math-text "\\{x \\in S\\} \\cup \\{y^2\\}")))
    (should (string-match-p "{x ∈ S}" rendered))
    (should (string-match-p "{y²}" rendered))))

(ert-deftest etaf-ui-markdown-highlight-reuses-mode-buffer-cleanly ()
  "Highlighting multiple snippets in one language leaves no leaked syntax state."
  (let* ((unclosed (etaf-ui-markdown-highlight-code "elisp" "(setq s \"unterminated"))
         (clean (etaf-ui-markdown-highlight-code "elisp" "(defun demo (x) (+ x 1))")))
    (should (listp unclosed))
    (should (cl-some (lambda (run)
                       (and (equal (plist-get run :text) "defun")
                            (eq (plist-get (plist-get run :props) :role) 'keyword)))
                     clean))))

(ert-deftest etaf-ui-markdown-footnote-ref-back-and-code-copy-callbacks ()
  "`:footnote-ref', `:footnote-back' and `:on-copy' wire host refs and notifications."
  (let* ((backed nil)
         (copied nil)
         (fn-ref 'etaf-ui-test-fn-1)
         (doc (etaf-ui-markdown-parse
               "Body[^1].\n\n```elisp\n(message \"hi\")\n(message \"bye\")\n```\n\n[^1]: Note text.\n"))
         (env (etaf-ui-markdown-test--env
               :features (plist-get doc :features)
               :footnote-ref (lambda (label) (when (equal label "1") fn-ref))
               :footnote-back (lambda (label) (push label backed))
               :on-copy (lambda (kind text lines) (push (list kind text lines) copied))))
         (views (append (etaf-ui-markdown-view-blocks (plist-get doc :children) env)
                        (etaf-ui-markdown-view-blocks (plist-get doc :footnotes) env)))
         (buffer-name (format " *etaf-ui-md-fn-%s*" (cl-gensym))))
    (unwind-protect
        (progn
          (etaf-mount buffer-name (etaf-node 'column (list :width '(ch 60)) views))
          (let* ((rt (etaf-runtime-for-buffer buffer-name))
                 (bounds (etaf-host-ref-bounds rt fn-ref))
                 (plain (etaf-ui-markdown-test--text buffer-name)))
            (should (consp bounds))
            (should (string-match-p "↩" plain))
            (with-current-buffer buffer-name
              (set-window-buffer (selected-window) (current-buffer))
              (goto-char (1+ (string-match "↩" plain)))
              (execute-kbd-macro (kbd "RET"))
              (should (equal backed '("1")))
              (goto-char (1+ (string-match "复制" plain)))
              (execute-kbd-macro (kbd "RET"))
              (should (equal (caar copied) 'code))
              (should (= (nth 2 (car copied)) 2)))))
      (when-let* ((rt (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount rt))
      (when-let* ((buf (get-buffer buffer-name)))
        (kill-buffer buf)))))

(ert-deftest etaf-ui-markdown-etaf-extended-inline-syntax-parses-and-paints ()
  "Extended inline syntax parses in the `etaf' dialect, stays literal in `gfm' and paints cleanly."
  (let* ((source (concat
                  "%%hidden block comment%%\n\n"
                  "Secret !!hidden answer!! and %%inline hidden%% text.\n\n"
                  "See [[Guide#Intro|入门指南]] and [+term] with "
                  ":color[#4493f8] :sym[find-file] ==Tip=={.tip} :badge[v2]{.tip}.\n\n"
                  "[+term]: A rich inline explanation.\n"))
         (doc (etaf-ui-markdown-parse source))
         (gfm (etaf-ui-markdown-parse "!!raw!! :color[#4493f8] [[raw]]\n" 'gfm))
         (state (etaf-ref nil))
         (opened-wiki nil)
         (opened-sym nil)
         (buffer-name (format " *etaf-ui-md-ext-%s*" (cl-gensym))))
    (should (assoc "term" (plist-get doc :annotations)))
    (should (equal "!!raw!! :color[#4493f8] [[raw]]"
                   (mapconcat (lambda (n) (or (plist-get n :text) ""))
                              (plist-get (car (plist-get gfm :children)) :children)
                              "")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column :width '(ch 76)
              (expr
               (let* ((alist (etaf-value state))
                      (env (etaf-ui-markdown-test--env
                            :features (plist-get doc :features)
                            :annotations (plist-get doc :annotations)
                            :block-state (lambda (k &optional d)
                                           (if-let* ((cell (assoc k alist)))
                                               (cdr cell)
                                             d))
                            :set-block-state (lambda (k v)
                                               (let ((next (copy-alist (etaf-value state))))
                                                 (if-let* ((cell (assoc k next)))
                                                     (setcdr cell v)
                                                   (push (cons k v) next))
                                                 (etaf-set-value state next)))
                            :open-wiki-link (lambda (target anchor label)
                                              (push (list target anchor label) opened-wiki))
                            :open-symbol (lambda (name) (push name opened-sym)))))
                 (etaf-ui-markdown-view-blocks (plist-get doc :children) env))))))
          (let ((plain (etaf-ui-markdown-test--text buffer-name)))
            (should-not (string-match-p "hidden block comment" plain))
            (should-not (string-match-p "inline hidden" plain))
            (should-not (string-match-p "hidden answer" plain))
            (should (string-match-p "░" plain))
            (should (string-match-p "入门指南" plain))
            (should (string-match-p "#4493f8" plain))
            (should (string-match-p "find-file" plain))
            (should (string-match-p "v2" plain))
            (with-current-buffer buffer-name
              (set-window-buffer (selected-window) (current-buffer))
              ;; `.tip' mark and badge must use the success fill (:ok-soft), not blue (:accent-soft).
              (let* ((tip-pos (1+ (string-match "Tip" plain)))
                     (v2-pos (1+ (string-match "v2" plain)))
                     (tip-face (get-text-property tip-pos 'face))
                     (v2-face (get-text-property v2-pos 'face)))
                (should (string-match-p "#dafbe1\\|#12261e" (format "%S" tip-face)))
                (should (string-match-p "#dafbe1\\|#12261e" (format "%S" v2-face))))
              ;; Reveal spoiler via activation.
              (goto-char (1+ (string-match "░" plain)))
              (execute-kbd-macro (kbd "RET"))
              (should (string-match-p "hidden answer"
                                      (etaf-ui-markdown-test--text buffer-name)))
              ;; Expand annotation card via activation.
              (let ((after-plot (etaf-ui-markdown-test--text buffer-name)))
                (goto-char (1+ (string-match "term" after-plot)))
                (execute-kbd-macro (kbd "RET")))
              (should (string-match-p "A rich inline explanation\\."
                                      (etaf-ui-markdown-test--text buffer-name)))
              ;; Activate wiki-link and symbol.
              (let ((now (etaf-ui-markdown-test--text buffer-name)))
                (goto-char (1+ (string-match "入门指南" now)))
                (execute-kbd-macro (kbd "RET"))
                (goto-char (1+ (string-match "find-file" now)))
                (execute-kbd-macro (kbd "RET")))))
          (should (equal opened-wiki '(("Guide" "Intro" "入门指南"))))
          (should (equal opened-sym '("find-file"))))
      (when-let* ((rt (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount rt))
      (when-let* ((buf (get-buffer buffer-name)))
        (kill-buffer buf)))))

(ert-deftest etaf-ui-markdown-code-fence-advanced-options ()
  "Code blocks support `:collapsed-lines', `/word/', `[!code word:...]', `:whitespace', `:indent-guides' and 1-based `{a-b}'."
  (let* ((source (concat
                  "```elisp {2-3} /alpha/ :collapsed-lines=2 :whitespace :indent-guides\n"
                  "line1 alpha\n"
                  "  line2 beta ; [!code word:beta]\n"
                  "    line3\n"
                  "line4\n"
                  "line5\n"
                  "```\n"))
         (doc (etaf-ui-markdown-parse source))
         (state (etaf-ref nil))
         (buffer-name (format " *etaf-ui-md-code-adv-%s*" (cl-gensym))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column :width '(ch 72)
              (expr
               (let* ((alist (etaf-value state))
                      (env (etaf-ui-markdown-test--env
                            :features (plist-get doc :features)
                            :block-state (lambda (k &optional d)
                                           (if-let* ((cell (assoc k alist)))
                                               (cdr cell)
                                             d))
                            :set-block-state (lambda (k v)
                                               (let ((next (copy-alist (etaf-value state))))
                                                 (if-let* ((cell (assoc k next)))
                                                     (setcdr cell v)
                                                   (push (cons k v) next))
                                                 (etaf-set-value state next))))))
                 (etaf-ui-markdown-view-blocks (plist-get doc :children) env))))))
          (let ((collapsed (etaf-ui-markdown-test--text buffer-name)))
            (should (string-match-p "line1" collapsed))
            (should (string-match-p "line2" collapsed))
            (should-not (string-match-p "line4" collapsed))
            (should-not (string-match-p "\\[!code" collapsed))
            (should (string-match-p "·" collapsed))
            (should (string-match-p "展开剩余 3 行" collapsed))
            (with-current-buffer buffer-name
              (set-window-buffer (selected-window) (current-buffer))
              (goto-char (1+ (string-match "展开剩余 3 行" collapsed)))
              (execute-kbd-macro (kbd "RET"))))
          (let ((expanded (etaf-ui-markdown-test--text buffer-name)))
            (should (string-match-p "line4" expanded))
            (should (string-match-p "line5" expanded))
            (should (string-match-p "│" expanded))
            (should (string-match-p "收起代码" expanded))))
      (when-let* ((rt (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount rt))
      (when-let* ((buf (get-buffer buffer-name)))
        (kill-buffer buf)))))

(ert-deftest etaf-ui-markdown-collapsible-alert-and-interactive-tasks ()
  "Obsidian collapsible alerts toggle their body and task checkboxes invoke `:on-toggle-task'."
  (let* ((source (concat
                  "> [!tip]- 折叠提示\n"
                  "> 隐藏的正文。\n\n"
                  "- [ ] 第一项\n"
                  "- [x] 第二项\n"))
         (doc (etaf-ui-markdown-parse source))
         (state (etaf-ref nil))
         (toggled nil)
         (buffer-name (format " *etaf-ui-md-alert-task-%s*" (cl-gensym))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column :width '(ch 64)
              (expr
               (let* ((alist (etaf-value state))
                      (env (etaf-ui-markdown-test--env
                            :features (plist-get doc :features)
                            :block-state (lambda (k &optional d)
                                           (if-let* ((cell (assoc k alist)))
                                               (cdr cell)
                                             d))
                            :set-block-state (lambda (k v)
                                               (let ((next (copy-alist (etaf-value state))))
                                                 (if-let* ((cell (assoc k next)))
                                                     (setcdr cell v)
                                                   (push (cons k v) next))
                                                 (etaf-set-value state next)))
                            :on-toggle-task (lambda (block item item-index)
                                              (push (list (plist-get block :begin)
                                                          (plist-get item :line-offset)
                                                          (plist-get item :checked)
                                                          item-index)
                                                    toggled)))))
                 (etaf-ui-markdown-view-blocks (plist-get doc :children) env))))))
          (let ((initial (etaf-ui-markdown-test--text buffer-name)))
            (should (string-match-p "折叠提示" initial))
            (should-not (string-match-p "隐藏的正文" initial))
            (with-current-buffer buffer-name
              (set-window-buffer (selected-window) (current-buffer))
              ;; Expand collapsible alert.
              (goto-char (1+ (string-match "折叠提示" initial)))
              (execute-kbd-macro (kbd "RET"))
              (should (string-match-p "隐藏的正文"
                                      (etaf-ui-markdown-test--text buffer-name)))
              ;; Toggle first task checkbox leaf.
              (let ((now (etaf-ui-markdown-test--text buffer-name)))
                (goto-char (1+ (string-match "□" now)))
                (execute-kbd-macro (kbd "RET")))))
          (should (= 1 (length toggled)))
          (should (equal 0 (nth 1 (car toggled))))
          (should-not (nth 2 (car toggled)))
          (should (= 1 (nth 3 (car toggled)))))
      (when-let* ((rt (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount rt))
      (when-let* ((buf (get-buffer buffer-name)))
        (kill-buffer buf)))))

(ert-deftest etaf-ui-markdown-hover-discipline-keeps-static-surfaces-clean ()
  "Hover faces attach strictly to unselected interactive leaves, never to static prose, code lines or selected tabs."
  (let* ((source (concat
                  "Plain prose with [link](https://example.com), :sym[car], "
                  "!!secret!!, :color[#123456], :badge[beta]{.tip}.\n\n"
                  "- [ ] Checkable item\n\n"
                  "```elisp\n(defun keep-me-clean () 42)\n```\n"))
         (doc (etaf-ui-markdown-parse source))
         (env (etaf-ui-markdown-test--env
               :features (plist-get doc :features)
               :open-link #'ignore
               :open-symbol #'ignore
               :on-toggle-task #'ignore))
         (buffer-name (format " *etaf-ui-md-hover-%s*" (cl-gensym))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (column :width '(ch 72) :item-gap '(lh 1)
              (etaf-tabs :active 'first
                         :items '((:key first :label "ActiveTab")
                                  (:key second :label "IdleTab"))
                         :on-change #'ignore)
              (expr (etaf-ui-markdown-view-blocks (plist-get doc :children) env)))))
          (with-current-buffer buffer-name
            (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
              ;; Unselected interactive leaves MUST carry mouse-face and hand pointer.
              (dolist (needle '("IdleTab" "link" "car" "░" "□" "复制"))
                (let ((pos (1+ (string-match (regexp-quote needle) plain))))
                  (should (get-text-property pos 'mouse-face))
                  (should (eq 'hand (get-text-property pos 'pointer)))))
              ;; Selected tab and static/multi-styled surfaces MUST NOT carry mouse-face.
              (dolist (needle '("ActiveTab" "Plain" "#123456" "beta"
                                "Checkable" "defun" "keep-me-clean"))
                (let ((pos (1+ (string-match (regexp-quote needle) plain))))
                  (should-not (get-text-property pos 'mouse-face)))))))
      (when-let* ((rt (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount rt))
      (when-let* ((buf (get-buffer buffer-name)))
        (kill-buffer buf)))))

(ert-deftest etaf-ui-markdown-highlight-modern-aliases-and-fallback ()
  "Modern fence aliases (`python3', `console', `tsx', `ts', `el', `http', `yaml') highlight cleanly without failing on missing Tree-sitter grammars."
  (dolist (case '(("python3" . "def greet(name):\n    return 'hi'\n")
                  ("pycon" . ">>> def f(x):\n...     return x\n")
                  ("console" . "if true; then echo ok; fi\n")
                  ("shell-session" . "export FOO=\"bar\"\n")
                  ("el" . "(defun foo (x) (+ x 1))\n")
                  ("common-lisp" . "(defun bar (x) (* x 2))\n")
                  ("mjs" . "export const answer = 42;\n")
                  ("ts" . "const total = 10;\nfunction sum(a) { return a; }\n")
                  ("tsx" . "function App() { return <div>ok</div>; }\n")
                  ("http" . "Content-Type: application/json\n")
                  ("yaml" . "name: etaf\nversion: 1\n")))
    (let* ((lang (car case))
           (src (cdr case))
           (runs (etaf-ui-markdown-highlight-code lang src))
           (joined (mapconcat (lambda (r) (plist-get r :text)) runs "")))
      (should (consp runs))
      (should (equal joined src))
      (should (cl-some (lambda (r) (plist-get r :props)) runs)))))

(ert-deftest etaf-ui-markdown-highlight-builtin-lexer-and-shell-cli ()
  "Zero-dependency built-in lexer highlights languages without installed modes and enhances shell CLI commands losslessly."
  (dolist (case '(("go" . "package main\nfunc main() { x := 1; fmt.Println(\"hi\") }\n")
                  ("rust" . "#[derive(Debug)]\npub fn first<'a>(s: &'a str) -> Option<usize> { let _ = vec![1]; Some(s.len()) }\n")
                  ("dockerfile" . "FROM alpine:3.20\nRUN apk add --no-cache git\n")
                  ("zig" . "const std = @import(\"std\");\npub fn main() void {}\n")
                  ("svelte" . "<script lang=\"ts\">\nlet count = 0;\n</script>\n<button>{count}</button>\n")
                  ("vue" . "<script setup>\nconst n = 1\n</script>\n<template><div>ok</div></template>\n")
                  ("kotlin" . "fun greet(name: String): Int { return 42 }\n")
                  ("swift" . "struct Point { let x: Double }\n")
                  ("graphql" . "query GetUser { user(id: 1) { name } }\n")
                  ("protobuf" . "message User { string name = 1; }\n")
                  ("hcl" . "resource \"aws_s3_bucket\" \"b\" { bucket = \"demo\" }\n")
                  ("cmake" . "cmake_minimum_required(VERSION 3.20)\n")
                  ("abnf9110" . "field-name = 1*VCHAR ; comment\n")
                  ("bash" . "brew install ripgrep\n")
                  ("shell" . "$ git status -sb\n")
                  ("console" . "$ sudo cargo build --release | tee build.log\n")))
    (let* ((lang (car case))
           (src (cdr case))
           (runs (etaf-ui-markdown-highlight-code lang src))
           (joined (mapconcat (lambda (r) (plist-get r :text)) runs "")))
      (should (consp runs))
      (should (equal joined src))
      (should (cl-some (lambda (r) (plist-get (plist-get r :props) :role)) runs))))
  ;; Shell CLI enhancer paints prompt, command, flags and pipe roles explicitly.
  (let ((runs (etaf-ui-markdown-highlight-code
               "console" "$ cargo build --release | sh")))
    (should (cl-some (lambda (r)
                       (and (equal (plist-get r :text) "$")
                            (eq (plist-get (plist-get r :props) :role) 'comment)))
                     runs))
    (should (cl-some (lambda (r)
                       (and (equal (plist-get r :text) "cargo")
                            (eq (plist-get (plist-get r :props) :role) 'function)))
                     runs))
    (should (cl-some (lambda (r)
                       (and (equal (plist-get r :text) "--release")
                            (eq (plist-get (plist-get r :props) :role) 'constant)))
                     runs))
    (should (cl-some (lambda (r)
                       (and (equal (plist-get r :text) "|")
                            (eq (plist-get (plist-get r :props) :role) 'keyword)))
                     runs)))
  ;; Unrecognized language still stays plain (nil).
  (should-not (etaf-ui-markdown-highlight-code "no-such-language" "plain text")))

(ert-deftest etaf-ui-markdown-table-fits-wide-tables-without-clipping ()
  "An 8-column table adapts cleanly across breakout, compact and narrow budgets.
No rightmost column is ever clipped: wide breakout renders all columns side by
side, medium budgets compress padding and scale columns into the budget, and
narrow splits fold rows into stacked record cards."
  (let ((md (concat
             "| 标准 | 方法论 (BEM/SMACSS) | 预处理器 (Sass) | CSS 模块 | 运行时 CSS-in-JS | 编译时 CSS-in-JS | 实用工具优先 (Tailwind) | 现代原生 CSS |\n"
             "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
             "| 作用域机制 | 手动命名约定 | 无 (全局) | 构建时哈希化类名 | JS闭包/运行时生成 | 构建时提取/哈希化 | 无 (依赖组合) | @scope |\n"
             "| 最佳适用 | 纪律严明的团队 | 组织中大型CSS | 任何组件化应用 | 高度动态化的UI | 性能敏感的组件化应用 | 快速原型/设计系统 | 简化工具链的项目 |\n")))
    ;; 1. Wide breakout budget: all 8 columns fit side-by-side with 9 borders.
    (let* ((doc (etaf-ui-markdown-parse md))
           (env (etaf-ui-markdown-test--env :width 78 :table-max-width 166
                                            :features (plist-get doc :features)))
           (views (etaf-ui-markdown-view-blocks (plist-get doc :children) env))
           (buf (format " *etaf-ui-markdown-%s*" (cl-gensym))))
      (unwind-protect
          (progn
            (etaf-mount buf (etaf-node 'column (list :width '(ch 170)) views))
            (let* ((text (etaf-ui-markdown-test--text buf))
                   (rows (cl-remove-if-not (lambda (l) (string-match-p "│" l))
                                           (split-string text "\n"))))
              (should (string-match-p "@scope" text))
              (should (string-match-p "现代原生 CSS" text))
              (should (cl-every (lambda (r) (= 9 (cl-count ?│ r))) rows))))
        (when-let* ((rt (etaf-runtime-for-buffer buf))) (etaf-unmount rt))
        (when (get-buffer buf) (kill-buffer buf))))
    ;; 2. Compact 78-cell budget: all 8 columns remain in one aligned grid.
    (let* ((doc (etaf-ui-markdown-parse md))
           (env (etaf-ui-markdown-test--env :width 78
                                            :features (plist-get doc :features)))
           (views (etaf-ui-markdown-view-blocks (plist-get doc :children) env))
           (buf (format " *etaf-ui-markdown-%s*" (cl-gensym))))
      (unwind-protect
          (progn
            (etaf-mount buf (etaf-node 'column (list :width '(ch 78)) views))
            (let* ((text (etaf-ui-markdown-test--text buf))
                   (rows (cl-remove-if-not (lambda (l) (string-match-p "│" l))
                                           (split-string text "\n"))))
              (should (string-match-p "@scope" text))
              (should (cl-every (lambda (r) (= 9 (cl-count ?│ r))) rows))
              (should (cl-every (lambda (r) (<= (string-width r) 78)) rows))))
        (when-let* ((rt (etaf-runtime-for-buffer buf))) (etaf-unmount rt))
        (when (get-buffer buf) (kill-buffer buf))))
    ;; 3. Ultra-narrow 44-cell budget: folds into stacked record cards keeping all data.
    (let* ((doc (etaf-ui-markdown-parse md))
           (env (etaf-ui-markdown-test--env :width 44
                                            :features (plist-get doc :features)))
           (views (etaf-ui-markdown-view-blocks (plist-get doc :children) env))
           (buf (format " *etaf-ui-markdown-%s*" (cl-gensym))))
      (unwind-protect
          (progn
            (etaf-mount buf (etaf-node 'column (list :width '(ch 44)) views))
            (let* ((text (etaf-ui-markdown-test--text buf))
                   (lines (split-string text "\n")))
              (should (string-match-p "标准 · 作用域机制" text))
              (should (string-match-p "@scope" text))
              (should (string-match-p "简化工具链" text))
              (should (cl-every (lambda (l) (<= (string-width l) 44)) lines))))
        (when-let* ((rt (etaf-runtime-for-buffer buf))) (etaf-unmount rt))
        (when (get-buffer buf) (kill-buffer buf))))))

(ert-deftest etaf-ui-markdown-table-images-dispatch-with-column-width ()
  "Table cells dispatch Markdown, linked and inline HTML images as `table-image'.
Each call receives `:table-cell t', the resolved column `:table-cell-width' and
`:table-cell-align', empty-alt image columns retain usable width, and stacked
card layouts at narrow widths continue dispatching `table-image'."
  (let* ((calls nil)
         (md (concat
              "| 左图 | 中图 | 右图 |\n"
              "| :--- | :---: | ---: |\n"
              "| ![封面](cover.png) | ![](empty.png) | [![徽章](badge.png)](https://example.com/doc) |\n"
              "| <img src=\"shot.png\" alt=\"截图\" width=\"120\" height=\"80\"> | 说明 | ok |\n"))
         (doc (etaf-ui-markdown-parse md))
         (spy (lambda (kind node env)
                (push (list :kind kind
                            :url (plist-get node :url)
                            :alt (plist-get node :alt)
                            :link (plist-get node :link)
                            :width (plist-get node :width)
                            :height (plist-get node :height)
                            :table-cell (plist-get env :table-cell)
                            :cell-width (plist-get env :table-cell-width)
                            :env-width (plist-get env :width)
                            :align (plist-get env :table-cell-align))
                      calls)
                (etaf-node 'text nil
                           (list (format "[IMG:%s@%d]"
                                         (or (plist-get node :url) "")
                                         (or (plist-get env :table-cell-width) 0))))))
         (env (etaf-ui-markdown-test--env :width 72
                                          :features (plist-get doc :features)
                                          :render-media spy))
         (views (etaf-ui-markdown-view-blocks (plist-get doc :children) env))
         (buf (format " *etaf-ui-markdown-%s*" (cl-gensym))))
    (unwind-protect
        (progn
          (etaf-mount buf (etaf-node 'column (list :width '(ch 72)) views))
          (setq calls (nreverse calls))
          (should (= 4 (length calls)))
          (dolist (c calls)
            (should (eq 'table-image (plist-get c :kind)))
            (should (eq t (plist-get c :table-cell)))
            (should (integerp (plist-get c :cell-width)))
            (should (equal (plist-get c :cell-width) (plist-get c :env-width)))
            (should (>= (plist-get c :cell-width) 10)))
          ;; Alignment and payload attributes match each column/source.
          (let ((cover (nth 0 calls))
                (empty (nth 1 calls))
                (badge (nth 2 calls))
                (shot  (nth 3 calls)))
            (should (equal (plist-get cover :url) "cover.png"))
            (should (eq (plist-get cover :align) 'left))
            (should (equal (plist-get empty :url) "empty.png"))
            (should (eq (plist-get empty :align) 'center))
            (should (equal (plist-get badge :url) "badge.png"))
            (should (equal (plist-get badge :link) "https://example.com/doc"))
            (should (eq (plist-get badge :align) 'right))
            (should (equal (plist-get shot :url) "shot.png"))
            (should (equal (plist-get shot :alt) "截图"))
            (should (= 120 (plist-get shot :width)))
            (should (= 80 (plist-get shot :height)))
            (should (eq (plist-get shot :align) 'left))))
      (when-let* ((rt (etaf-runtime-for-buffer buf))) (etaf-unmount rt))
      (when (get-buffer buf) (kill-buffer buf)))
    ;; Ultra-narrow stacked card fallback (8 columns at width 40) still dispatches `table-image'.
    (setq calls nil)
    (let* ((wide-md (concat
                     "| A | B | C | D | E | F | G | H |\n"
                     "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
                     "| 标题行 | ![卡片图](card.png) | ccc | ddd | eee | fff | ggg | hhh |\n"))
           (wide-doc (etaf-ui-markdown-parse wide-md))
           (card-env (etaf-ui-markdown-test--env :width 40
                                                 :features (plist-get wide-doc :features)
                                                 :render-media spy))
           (card-views (etaf-ui-markdown-view-blocks (plist-get wide-doc :children) card-env))
           (card-buf (format " *etaf-ui-markdown-%s*" (cl-gensym))))
      (unwind-protect
          (progn
            (etaf-mount card-buf (etaf-node 'column (list :width '(ch 40)) card-views))
            (should (string-match-p "A · 标题行" (etaf-ui-markdown-test--text card-buf)))
            (should (= 1 (length calls)))
            (should (eq 'table-image (plist-get (car calls) :kind)))
            (should (eq t (plist-get (car calls) :table-cell)))
            (should (>= (plist-get (car calls) :cell-width) 16)))
        (when-let* ((rt (etaf-runtime-for-buffer card-buf))) (etaf-unmount rt))
        (when (get-buffer card-buf) (kill-buffer card-buf))))))

(provide 'etaf-ui-markdown-tests)
;;; etaf-ui-markdown-tests.el ends here
