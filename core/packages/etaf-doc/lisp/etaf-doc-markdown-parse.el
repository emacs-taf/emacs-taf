;;; etaf-doc-markdown-parse.el --- Markdown document parsing for etaf-doc -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Markdown parsing shared by the ETAF Doc markdown renderer
;; (`etaf-doc-markdown') and its consumers.  Parsing is pure Elisp over a
;; string: no buffer, no network and no file access.
;;
;; It covers CommonMark block and inline structure plus the GitHub extensions
;; the renderer supports: pipe tables, task list items, strikethrough,
;; autolinks, footnotes and alert blocks, and it strips YAML front matter into
;; document metadata.
;;
;; A block is a plist with :type one of `heading', `paragraph', `code-block',
;; `blockquote', `list', `list-item', `table', `thematic-break', `html-block'
;; and `footnote-def'.  An inline is a plist with :type one of `text', `code',
;; `emph', `strong', `strike', `link', `image', `autolink', `footnote-ref',
;; `html' and `break'.  The tree carries no presentation facts; the views own
;; every style and ETAF node choice.
;;
;; Link reference definitions and footnote definitions are collected into
;; parser-local tables while blocks are read, then resolved into inline nodes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-doc-markdown-error "Markdown document error")

(defvar etaf-doc-markdown--refs nil
  "Link reference definitions of the document being parsed.")

(defvar etaf-doc-markdown--features nil
  "Extension feature flags of the document being parsed.
A plist of booleans: `:front-matter', `:tables', `:task-lists',
`:strikethrough', `:autolinks', `:footnotes', `:alerts' and `:extensions',
the names of the extensions this module adds on top of the flags.  A
recognizer gated off leaves its syntax as literal text instead of failing.")

(defconst etaf-doc-markdown-gfm-features
  '(:front-matter t :tables t :task-lists t
    :strikethrough t :autolinks t :footnotes t :alerts t)
  "The feature flags GitHub Flavored Markdown enables as a whole.
A preset spells its own flags out so a later change to GFM does not silently
change what an older preset meant.")

(defconst etaf-doc-markdown-flavors
  `((commonmark . (:front-matter nil :tables nil :task-lists nil
                    :strikethrough nil :autolinks nil :footnotes nil
                    :alerts nil :extensions nil))
    (gfm . ,etaf-doc-markdown-gfm-features)
    ;; The renderer's own daily dialect: GitHub's extensions plus the ones a
    ;; reader expects from a notes tool, all of them pure parsing.  Nothing
    ;; here needs an external program, so a plain checkout renders them.
    (etaf . ,(append etaf-doc-markdown-gfm-features
                     '(:extensions (definition-list subscript superscript
                                    abbreviation math emoji mark icon kbd
                                    badge plot annotation wiki-link comment
                                    color-chip symbol)))))
  "Named markdown dialects and the syntax each one enables.
`commonmark' is the CommonMark core; `gfm' adds GitHub's extensions there as
well: tables, task lists, strikethrough, bare autolinks, footnotes, alert
blocks and front matter; `etaf' adds definition lists, sub- and superscript,
abbreviations, `$' math, emoji shortcodes, `==highlighted==' runs,
`::name::' icons, `:kbd[KEY+KEY]' key groups, `:badge[TEXT]' badges,
`!!spoiler!!' plots, `[+label]' rich annotations, `[[wiki]]' links,
`%%...%%' comments and focused inline semantics (`:color[...]', `:sym[...]')
on top of `gfm'.  A preset is only a set of switches over one parser, so a
document written for one of them still parses under another, with the syntax
it did not enable showing as literal text.")

(defcustom etaf-doc-markdown-flavor 'etaf
  "Default Markdown dialect of `etaf-doc-markdown-parse'.
A FLAVOR argument overrides it.  `etaf' is the widest preset and what a
reader gets by opening a document; `gfm' and `commonmark' are the narrower
ones to name when a document has to parse exactly as those specifications
say."
  :type '(choice (const :tag "ETAF dialect" etaf)
                 (const :tag "GitHub Flavored Markdown" gfm)
                 (const :tag "CommonMark only" commonmark)
                 (sexp :tag "Feature plist"))
  :group 'text)

(defun etaf-doc-markdown--features-for (flavor)
  "Return the feature plist for FLAVOR.
FLAVOR is a named dialect, nil for `etaf-doc-markdown-flavor', or a plist
overriding the default preset: a flag key replaces that flag and `:extensions'
replaces the extension list.  Unknown names signal
`etaf-doc-markdown-error'."
  (let* ((fallback (or etaf-doc-markdown-flavor 'etaf))
         (base (cdr (assq fallback etaf-doc-markdown-flavors))))
    (cond
     ((null flavor) (copy-sequence base))
     ((and (symbolp flavor) (assq flavor etaf-doc-markdown-flavors))
      (copy-sequence (cdr (assq flavor etaf-doc-markdown-flavors))))
     ((listp flavor)
      ;; A plist may release or add individual flags and extensions.
      (let ((merged (copy-sequence base))
            (tail flavor))
        (while tail
          (setq merged (plist-put merged (pop tail) (pop tail))))
        merged))
     (t (signal 'etaf-doc-markdown-error
                (list (format "Unknown markdown flavor: %S" flavor)))))))

(defun etaf-doc-markdown--feature-p (key)
  "Return non-nil when the document being parsed enables feature KEY."
  (plist-get etaf-doc-markdown--features key))

(defun etaf-doc-markdown-extension-p (name)
  "Return non-nil when the document being parsed enables extension NAME.
NAME is a symbol from `etaf-doc-markdown-flavors' `:extensions' list."
  (and (memq name (plist-get etaf-doc-markdown--features :extensions)) t))

(defconst etaf-doc-markdown-block-extensions
  '((definition-list etaf-doc-markdown--definition-list-at)
    (math etaf-doc-markdown--math-block-at)
    (comment etaf-doc-markdown--comment-block-at))
  "Block syntax this module adds, as (NAME RECOGNIZER).
RECOGNIZER takes the remaining lines and returns (BLOCK . REST) when it claims
them.  A preset enables NAME, and a disabled extension never runs, so its
syntax stays literal text exactly as CommonMark reads it.")

(defconst etaf-doc-markdown-inline-extensions
  '((mark ?= etaf-doc-markdown--try-mark)
    (plot ?! etaf-doc-markdown--try-plot)
    (comment ?% etaf-doc-markdown--try-comment)
    (wiki-link ?\[ etaf-doc-markdown--try-wiki-link)
    (annotation ?\[ etaf-doc-markdown--try-annotation)
    (math ?$ etaf-doc-markdown--try-math)
    (subscript ?~ etaf-doc-markdown--try-subscript)
    (superscript ?^ etaf-doc-markdown--try-superscript)
    (abbreviation nil etaf-doc-markdown--try-abbreviation)
    (emoji ?: etaf-doc-markdown--try-emoji)
    (icon ?: etaf-doc-markdown--try-icon)
    (kbd ?: etaf-doc-markdown--try-kbd)
    (badge ?: etaf-doc-markdown--try-badge)
    (color-chip ?: etaf-doc-markdown--try-color-chip)
    (symbol ?: etaf-doc-markdown--try-symbol))
  "Inline syntax this module adds, as (NAME TRIGGER-CHAR RECOGNIZER).
TRIGGER-CHAR is the character that can open the syntax, or nil for a
recognizer that starts at a word character.  RECOGNIZER takes (TEXT POSITION
END) and returns (NODE . NEXT) when it claims the text there.")

(defun etaf-doc-markdown--block-extension (lines)
  "Return (BLOCK . REST) when an enabled extension claims LINES."
  (let (claimed)
    (dolist (entry etaf-doc-markdown-block-extensions)
      (unless claimed
        (when (etaf-doc-markdown-extension-p (car entry))
          (setq claimed (funcall (nth 1 entry) lines)))))
    claimed))

(defun etaf-doc-markdown--inline-extension (text position end)
  "Return (NODE . NEXT) when an enabled extension claims POSITION in TEXT."
  (let* ((char (aref text position))
         (word-start (or (>= char 128)
                         (and (>= char ?A) (<= char ?Z))
                         (and (>= char ?a) (<= char ?z))))
         (result nil))
    ;; Several extensions can share one trigger: `:' opens an emoji, an
    ;; `::name::' icon, a `:kbd[...]' key group and a `:badge[...]' badge.
    ;; Each recognizer declines text it does not own, so try them in order
    ;; until one claims the position.
    (dolist (entry etaf-doc-markdown-inline-extensions)
      (when (and (not result)
                 (etaf-doc-markdown-extension-p (car entry))
                 (if (nth 1 entry)
                     (eq char (nth 1 entry))
                   ;; A recognizer without a trigger character starts on a
                   ;; word character, which is where a word can begin.
                   word-start))
        (setq result (funcall (nth 2 entry) text position end))))
    result))

(defvar etaf-doc-markdown--abbreviations nil
  "Abbreviation definitions of the document being parsed, newest first.")

(defvar etaf-doc-markdown--annotations nil
  "Annotation definitions of the document being parsed, mapping label to blocks.")

(defvar etaf-doc-markdown--footnotes nil
  "Footnote definitions of the document being parsed, newest first.")

;;; ---------------------------------------------------------------------------
;;; Line helpers
;;; ---------------------------------------------------------------------------

(defun etaf-doc-markdown--blank-line-p (line)
  "Return non-nil when LINE contains only whitespace."
  (string-match-p "\\`[ \t]*\\'" line))

(defun etaf-doc-markdown--indent (line)
  "Return LINE's leading space count with tabs counted as four columns."
  (let ((indent 0)
        (index 0))
    (while (and (< index (length line))
                (memq (aref line index) '(?\s ?\t)))
      (setq indent (+ indent (if (eq (aref line index) ?\t) 4 1)))
      (setq index (1+ index)))
    indent))

(defun etaf-doc-markdown--strip-indent (line count)
  "Return LINE with up to COUNT leading columns of indentation removed."
  (let ((index 0)
        (removed 0))
    (while (and (< index (length line))
                (< removed count)
                (memq (aref line index) '(?\s ?\t)))
      (setq removed (+ removed (if (eq (aref line index) ?\t) 4 1)))
      (setq index (1+ index)))
    (substring line index)))

(defun etaf-doc-markdown--atx-heading (line)
  "Return (LEVEL . TEXT) when LINE is an ATX heading, else nil."
  (when (string-match "\\` ? ? ?\\(#\\{1,6\\}\\)\\(?:[ \t]+\\(.*?\\)\\|[ \t]*\\)[ \t]*#*[ \t]*\\'" line)
    (let ((level (length (match-string 1 line)))
          (text (or (match-string 2 line) "")))
      (cons level (string-trim (replace-regexp-in-string "[ \t]+#+[ \t]*\\'" "" text))))))

(defun etaf-doc-markdown--setext-level (line)
  "Return 1 or 2 when LINE is a Setext heading underline, else nil."
  (let ((trimmed (string-trim line)))
    (when (and (>= (length trimmed) 1)
               (string-match-p "\\`\\(=+\\|-+\\)\\'" trimmed))
      (if (eq (aref trimmed 0) ?=) 1 2))))

(defun etaf-doc-markdown--thematic-break-p (line)
  "Return non-nil when LINE is a thematic break."
  (let ((trimmed (replace-regexp-in-string "[ \t]" "" (string-trim line))))
    (and (>= (length trimmed) 3)
         (string-match-p "\\`\\(\\*+\\|-+\\|_+\\)\\'" trimmed))))

(defun etaf-doc-markdown--fence-start (line)
  "Return (INDENT MARKER-CHAR MARKER-LENGTH INFO) when LINE opens a fence."
  (when (string-match "\\` ? ? ?\\(`\\{3,\\}\\|~\\{3,\\}\\)\\(.*\\)\\'" line)
    (let ((fence (match-string 1 line)))
      (list (etaf-doc-markdown--indent line)
            (aref fence 0)
            (length fence)
            (string-trim (match-string 2 line))))))

(defun etaf-doc-markdown--blockquote-line (line)
  "Return LINE's blockquote content, or nil when LINE is not a quote line."
  (when (string-match "\\` ? ? ?> ?\\(.*\\)\\'" line)
    (match-string 1 line)))

(defun etaf-doc-markdown--list-marker (line)
  "Return (INDENT ORDERED START CONTENT-INDENT CONTENT DELIMITER) for an item.
Only markers indented by less than four columns are list markers.  DELIMITER
is the character after the number, or the bullet itself: a list changes when
it changes, which is what lets a numbered list run 3, 4, 5 and then start a new
one at 1 with the other delimiter."
  (let ((indent (etaf-doc-markdown--indent line)))
    (when (< indent 4)
      (let ((rest (substring line indent)))
        (cond
         ((string-match "\\`\\([-+*]\\)\\(?:[ \t]+\\(.*\\)\\|\\'\\)\\'" rest)
          (list indent nil nil
                (+ indent (if (match-string 2 rest) 2 1))
                (or (match-string 2 rest) "")
                (match-string 1 rest)))
         ((string-match "\\`\\([0-9]\\{1,9\\}\\)\\([.)]\\)\\(?:[ \t]+\\(.*\\)\\|\\'\\)\\'" rest)
          (list indent t (string-to-number (match-string 1 rest))
                (+ indent (if (match-string 3 rest) 2 1))
                (or (match-string 3 rest) "")
                (match-string 2 rest)))
         (t nil))))))

(defun etaf-doc-markdown--table-delimiter-p (line)
  "Return non-nil when LINE is a table delimiter row."
  (let ((trimmed (string-trim line)))
    (and (string-match-p "|" trimmed)
         (string-match-p "\\`|?[ \t]*:?-+:?[ \t]*\\(?:|[ \t]*:?-+:?[ \t]*\\)*|?\\'" trimmed)
         (string-match-p "-" trimmed))))

(defun etaf-doc-markdown--footnote-definition (line)
  "Return (LABEL . TEXT) when LINE defines a footnote."
  (when (string-match "\\` ? ? ?\\[\\^\\([^]]+\\)\\]:[ \t]*\\(.*\\)\\'" line)
    (cons (match-string 1 line) (match-string 2 line))))

(defun etaf-doc-markdown--annotation-definition (line)
  "Return (LABEL . TEXT) when LINE defines an inline annotation `[+label]:'."
  (when (string-match "\\` ? ? ?\\[\\+\\([^]]+\\)\\]:[ \t]*\\(.*\\)\\'" line)
    (cons (string-trim (match-string 1 line)) (match-string 2 line))))

(defun etaf-doc-markdown--reference-definition (line)
  "Return (LABEL URL TITLE) when LINE defines a link reference."
  (when (string-match "\\` ? ? ?\\[\\([^]]+\\)\\]:[ \t]*\\(.*\\)\\'" line)
    (let ((raw-label (match-string 1 line))
          (label (downcase (string-trim (match-string 1 line))))
          (rest (string-trim (match-string 2 line)))
          (url nil)
          (title nil))
      (unless (and (etaf-doc-markdown-extension-p 'annotation)
                   (string-prefix-p "+" raw-label))
        (when (and (not (string-empty-p rest))
                   (string-match
                    "\\`\\(?:<\\([^>]*\\)>\\|\\([^ \t]+\\)\\)\\(?:[ \t]+\\(?:\"\\([^\"]*\\)\"\\|'\\([^']*\\)'\\)\\)?[ \t]*\\'"
                    rest))
          (setq url (or (match-string 1 rest) (match-string 2 rest)))
          (setq title (or (match-string 3 rest) (match-string 4 rest)))
          (list label url title))))))

(defconst etaf-doc-markdown--html-block-tags
  '("address" "article" "aside" "base" "blockquote" "body" "caption" "center"
    "col" "colgroup" "dd" "details" "dialog" "dir" "div" "dl" "dt" "fieldset"
    "figcaption" "figure" "footer" "form" "frame" "frameset" "h1" "h2" "h3"
    "h4" "h5" "h6" "head" "header" "hr" "html" "iframe" "legend" "li" "link"
    "main" "menu" "menuitem" "nav" "noframes" "ol" "optgroup" "option" "p"
    "param" "search" "section" "summary" "table" "tbody" "td" "tfoot" "th"
    "thead" "title" "tr" "track" "ul" "video" "audio" "source" "img" "svg")
  "Tag names that open an HTML block.")

(defun etaf-doc-markdown--html-block-start-p (line)
  "Return non-nil when LINE opens a raw HTML block."
  (let ((trimmed (string-trim line)))
    (or (string-prefix-p "<!--" trimmed)
        (string-prefix-p "<!" trimmed)
        (string-prefix-p "<?" trimmed)
        (when (string-match "\\`</?\\([a-zA-Z][a-zA-Z0-9-]*\\)" trimmed)
          (member (downcase (match-string 1 trimmed))
                  etaf-doc-markdown--html-block-tags)))))

(defun etaf-doc-markdown--starts-block-p (line)
  "Return non-nil when LINE starts a block construct."
  (or (etaf-doc-markdown--blank-line-p line)
      (and (etaf-doc-markdown--atx-heading line) t)
      (etaf-doc-markdown--fence-start line)
      (etaf-doc-markdown--blockquote-line line)
      (etaf-doc-markdown--list-marker line)
      (etaf-doc-markdown--thematic-break-p line)
      (etaf-doc-markdown--footnote-definition line)
      (etaf-doc-markdown--reference-definition line)
      (etaf-doc-markdown--html-block-start-p line)
      (and (etaf-doc-markdown-extension-p 'definition-list)
           (etaf-doc-markdown--definition-marker line))
      (and (etaf-doc-markdown-extension-p 'math)
           (etaf-doc-markdown--math-block-start-p line))
      (and (etaf-doc-markdown-extension-p 'abbreviation)
           (etaf-doc-markdown--abbreviation-definition line))
      (and (etaf-doc-markdown-extension-p 'annotation)
           (etaf-doc-markdown--annotation-definition line))
      (and (etaf-doc-markdown-extension-p 'comment)
           (etaf-doc-markdown--comment-block-start-p line))
      (>= (etaf-doc-markdown--indent line) 4)))

(defun etaf-doc-markdown--split-table-row (line)
  "Return LINE's table cells as a list of trimmed strings.
A pipe written `\\|' belongs to the cell it sits in, which is the only way to
put one in a cell at all; every other pipe separates two cells."
  (let* ((trimmed (string-trim line))
         (trimmed (if (string-prefix-p "|" trimmed) (substring trimmed 1) trimmed))
         (trimmed (if (and (string-suffix-p "|" trimmed)
                           (not (string-suffix-p "\\|" trimmed)))
                      (substring trimmed 0 (1- (length trimmed)))
                    trimmed))
         (cells nil)
         (start 0)
         (index 0))
    (while (< index (length trimmed))
      (when (and (eq (aref trimmed index) ?|)
                 (not (and (> index 0) (eq (aref trimmed (1- index)) ?\\))))
        (push (substring trimmed start index) cells)
        (setq start (1+ index)))
      (setq index (1+ index)))
    (push (substring trimmed start) cells)
    (mapcar (lambda (cell)
              (string-trim (string-replace "\\|" "|" cell)))
            (nreverse cells))))

(defun etaf-doc-markdown--table-alignments (line)
  "Return the alignment list described by delimiter LINE."
  (mapcar (lambda (cell)
            (let ((left (string-prefix-p ":" cell))
                  (right (string-suffix-p ":" cell)))
              (cond ((and left right) 'center)
                    (right 'right)
                    (left 'left)
                    (t nil))))
          (etaf-doc-markdown--split-table-row line)))

;;; ---------------------------------------------------------------------------
;;; Block collection helpers
;;; ---------------------------------------------------------------------------

(defun etaf-doc-markdown--collect-indented (lines)
  "Split LINES into leading lines indented by four columns and the rest.
Return (CONTENT . REST); blank lines between indented lines stay in CONTENT."
  (let ((content nil)
        (rest lines))
    (while (and rest
                (or (>= (etaf-doc-markdown--indent (car rest)) 4)
                    (etaf-doc-markdown--blank-line-p (car rest))))
      (setq content
            (append content
                    (list (if (etaf-doc-markdown--blank-line-p (car rest))
                              ""
                            (etaf-doc-markdown--strip-indent (car rest) 4)))))
      (setq rest (cdr rest)))
    (cons content rest)))

(defun etaf-doc-markdown--collect-quote (lines)
  "Split LINES into blockquote content lines and the rest."
  (let ((content nil)
        (rest lines)
        (started nil))
    (while (and rest
                (if (etaf-doc-markdown--blockquote-line (car rest))
                    (progn
                      (push (etaf-doc-markdown--blockquote-line (car rest)) content)
                      (setq rest (cdr rest)
                            started t)
                      t)
                  (if (and started
                           (not (etaf-doc-markdown--starts-block-p (car rest))))
                      (progn
                        (push (car rest) content)
                        (setq rest (cdr rest))
                        t)
                    nil))))
    (cons (nreverse content) rest)))

(defun etaf-doc-markdown--collect-list (lines)
  "Split LINES into one list's items and the rest.
Return (ORDERED START TIGHT ITEMS . REST); each item is
\(FIRST-LINE LINES LINE-OFFSET)."
  (let* ((first-marker (etaf-doc-markdown--list-marker (car lines)))
         (base (nth 0 first-marker))
         (ordered (nth 1 first-marker))
         (start (nth 2 first-marker))
         ;; A different delimiter or bullet starts another list; a numbered
         ;; list written 3, 4, 5 must not continue into a 1) list.
         (delimiter (nth 5 first-marker))
         (items nil)
         (tight t)
         (rest lines)
         (line-offset 0))
    (while (and rest
                (let ((marker (etaf-doc-markdown--list-marker (car rest))))
                  (and marker
                       (eq (nth 1 marker) ordered)
                       (= (nth 0 marker) base)
                       (equal (nth 5 marker) delimiter))))
      (let* ((marker (etaf-doc-markdown--list-marker (car rest)))
             (content-indent (nth 3 marker))
             (first-content (nth 4 marker))
             (item-offset line-offset)
             (item-lines (list first-content)))
        (setq rest (cdr rest)
              line-offset (1+ line-offset))
        (while (and rest
                    (not (let ((next (etaf-doc-markdown--list-marker (car rest))))
                           (and next
                                (eq (nth 1 next) ordered)
                                (= (nth 0 next) base)
                                (equal (nth 5 next) delimiter))))
                    (let ((line (car rest)))
                      (cond
                       ((etaf-doc-markdown--blank-line-p line)
                        ;; A blank line belongs to the item only when this list
                        ;; continues: the next line is indented content or
                        ;; another item of the same list.  Otherwise the list
                        ;; ends here and the blank line stays for the outer
                        ;; parser, so an unindented paragraph or a different
                        ;; list is not swallowed as a lazy continuation.  When
                        ;; it does belong, the item keeps it: it separates the
                        ;; two paragraphs the source wrote as such.
                        (let ((next (and (cadr rest)
                                         (etaf-doc-markdown--list-marker (cadr rest)))))
                          (when (and (cadr rest)
                                     (or (>= (etaf-doc-markdown--indent (cadr rest))
                                             content-indent)
                                         (and next
                                              (eq (nth 1 next) ordered)
                                              (= (nth 0 next) base)
                                              (equal (nth 5 next) delimiter))))
                            (setq tight nil)
                            (push "" item-lines)
                            t)))
                       ((>= (etaf-doc-markdown--indent line) content-indent)
                        (push (etaf-doc-markdown--strip-indent line content-indent)
                              item-lines)
                        t)
                       ((not (etaf-doc-markdown--starts-block-p line))
                        (push line item-lines)
                        t)
                       (t nil))))
          (setq rest (cdr rest)
                line-offset (1+ line-offset)))
        (setq items (cons (list first-content (nreverse item-lines) item-offset)
                          items))))
    (cons (list ordered start tight (nreverse items)) rest)))

(defun etaf-doc-markdown--parse-list-item (item ordered start)
  "Parse one ITEM of a list, with ORDERED and START for its marker.
ITEM is (FIRST-LINE LINES LINE-OFFSET)."
  (let* ((body (nth 1 item))
         (line-offset (nth 2 item))
         (blocks (etaf-doc-markdown--parse-blocks body))
         (checked nil)
         (task nil))
    (when (and blocks (eq (plist-get (car blocks) :type) 'paragraph))
      (let* ((children (plist-get (car blocks) :children))
             (first (car children)))
        (when (and first (eq (plist-get first :type) 'text))
          (let ((text (plist-get first :text)))
            (when (and (etaf-doc-markdown--feature-p :task-lists)
                       (string-match "\\`\\[\\([ xX]?\\)\\][ \t]+" text))
              (let ((checked-text (match-string 1 text))
                    (rest (substring text (match-end 0))))
                (setq task t
                      checked (not (string-empty-p (string-trim checked-text))))
                (setcar blocks
                        (plist-put (car blocks) :children
                                   (if (string-empty-p rest)
                                       (cdr children)
                                     (cons (plist-put (copy-sequence first)
                                                      :text rest)
                                           (cdr children)))))))))))
    (list :type 'list-item :checked (if task checked nil) :task task
          :line-offset line-offset
          :start (and ordered start) :children blocks)))

(defun etaf-doc-markdown--normalize-cells (cells aligns)
  "Pad or trim CELLS to the column count of ALIGNS."
  (let ((count (length aligns)))
    (append (cl-subseq cells 0 (min count (length cells)))
            (make-list (max 0 (- count (length cells))) ""))))

(defun etaf-doc-markdown--take-table (lines)
  "Parse a table from LINES; return (TABLE . REST)."
  (let* ((aligns (etaf-doc-markdown--table-alignments (cadr lines)))
         (header (etaf-doc-markdown--split-table-row (car lines)))
         (rest (cddr lines))
         (rows nil))
    (while (and rest
                (not (etaf-doc-markdown--blank-line-p (car rest)))
                (string-match-p "|" (car rest)))
      (push (etaf-doc-markdown--split-table-row (car rest)) rows)
      (setq rest (cdr rest)))
    (cons (list :type 'table
                :aligns aligns
                :header (etaf-doc-markdown--parse-table-cells header aligns)
                :rows (mapcar (lambda (row)
                                (etaf-doc-markdown--parse-table-cells row aligns))
                              (nreverse rows)))
          rest)))

(defun etaf-doc-markdown--parse-table-cells (cells aligns)
  "Return CELLS normalized to ALIGNS and parsed into inline nodes."
  (mapcar #'etaf-doc-markdown--parse-inlines
          (etaf-doc-markdown--normalize-cells cells aligns)))

;;; ---------------------------------------------------------------------------
;;; Block parser
;;; ---------------------------------------------------------------------------

(defun etaf-doc-markdown--line-starts (lines shift limit)
  "Return the character offsets where LINES start, plus one past the last line.
SHIFT is added to every offset, and no offset exceeds LIMIT.  A caller that
split one text into LINES uses the result to turn a line index into a range in
that text."
  (let ((starts (make-vector (1+ (length lines)) 0))
        (position shift)
        (index 0))
    (dolist (line lines)
      (aset starts index position)
      (setq position (+ position (length line) 1)
            index (1+ index)))
    (aset starts index (min position limit))
    starts))

(defun etaf-doc-markdown--parse-blocks (lines &optional starts)
  "Parse LINES into a list of block nodes.
STARTS, when given, is the line offset vector from
`etaf-doc-markdown--line-starts': every node this call creates then carries
`:begin' and `:end', its half-open character range in the text LINES came from.
`:end' is where the line after the block begins, so the range always covers
whole lines and its slice ends with the block's own last newline.
Recursive calls parse a snippet of another block and pass no vector, so nested
nodes carry no range."
  (let ((blocks nil)
        (index 0)
        (total (length lines)))
    (while lines
      (let ((line (car lines))
            (head blocks)
            (start index))
        (cond
         ((etaf-doc-markdown--blank-line-p line)
          (setq lines (cdr lines)))

         ((etaf-doc-markdown--atx-heading line)
          (let* ((heading (etaf-doc-markdown--atx-heading line))
                 (text (cdr heading)))
            (push (list :type 'heading
                        :level (car heading)
                        :text text
                        :children (etaf-doc-markdown--parse-inlines text))
                  blocks))
          (setq lines (cdr lines)))

         ((etaf-doc-markdown--fence-start line)
          (let* ((fence (etaf-doc-markdown--fence-start line))
                 (char (nth 1 fence))
                 (length (nth 2 fence))
                 (info (nth 3 fence))
                 (rest (cdr lines))
                 (content nil)
                 (closed nil))
            (while (and rest (not closed))
              (if (etaf-doc-markdown--fence-close-p (car rest) char length)
                  (setq closed t)
                (push (car rest) content))
              (setq rest (cdr rest)))
            (push (list :type 'code-block
                        :lang (car (split-string info "[ \t]+" t))
                        :info info
                        :text (mapconcat #'identity (nreverse content) "\n"))
                  blocks)
            (setq lines rest)))

         ((etaf-doc-markdown--thematic-break-p line)
          (push (list :type 'thematic-break) blocks)
          (setq lines (cdr lines)))

         ((etaf-doc-markdown--blockquote-line line)
          (let ((collected (etaf-doc-markdown--collect-quote lines)))
            (push (list :type 'blockquote
                        :children (etaf-doc-markdown--parse-blocks (car collected)))
                  blocks)
            (setq lines (cdr collected))))

         ((etaf-doc-markdown--footnote-definition line)
          (let* ((definition (etaf-doc-markdown--footnote-definition line))
                 ;; GFM footnote continuations are indented four columns.
                 (content-indent 4)
                 (rest (cdr lines))
                 (content (list (cdr definition))))
            (while (and rest
                        (or (etaf-doc-markdown--blank-line-p (car rest))
                            (>= (etaf-doc-markdown--indent (car rest)) content-indent)))
              (push (if (etaf-doc-markdown--blank-line-p (car rest))
                        ""
                      (etaf-doc-markdown--strip-indent (car rest) content-indent))
                    content)
              (setq rest (cdr rest)))
            (let ((definition-blocks
                   (etaf-doc-markdown--parse-blocks (nreverse content))))
              ;; The first definition of a label is the one that counts: a
              ;; document that repeats it has a mistake, and the reader should
              ;; see the note the reference was written against.
              (unless (assoc (car definition) etaf-doc-markdown--footnotes)
                (setf (alist-get (car definition) etaf-doc-markdown--footnotes
                                 nil nil #'equal)
                      definition-blocks)))
            (setq lines rest)))

         ((and (etaf-doc-markdown-extension-p 'annotation)
               (etaf-doc-markdown--annotation-definition line))
          ;; Consume `[+label]: ...' definition plus indented continuations;
          ;; definitions are already collected before inline parsing so the
          ;; body paints nothing here.
          (let ((rest (cdr lines)))
            (while (and rest
                        (or (and (etaf-doc-markdown--blank-line-p (car rest))
                                 (cadr rest)
                                 (>= (etaf-doc-markdown--indent (cadr rest)) 2))
                            (>= (etaf-doc-markdown--indent (car rest)) 2)))
              (setq rest (cdr rest)))
            (setq lines rest)))

         ((etaf-doc-markdown--reference-definition line)
          (let ((definition (etaf-doc-markdown--reference-definition line)))
            (setf (gethash (car definition) etaf-doc-markdown--refs)
                  (cons (nth 1 definition) (nth 2 definition))))
          (setq lines (cdr lines)))

         ((and (etaf-doc-markdown-extension-p 'abbreviation)
               (etaf-doc-markdown--abbreviation-definition line))
          ;; An abbreviation definition names a word and its title; the word's
          ;; occurrences carry it, so the line paints nothing, exactly as a
          ;; link reference definition does.
          (setq lines (cdr lines)))

         ((etaf-doc-markdown--html-block-start-p line)
          (let ((rest lines)
                (content nil)
                (comment (string-prefix-p "<!--" (string-trim line))))
            (while (and rest
                        (not (etaf-doc-markdown--blank-line-p (car rest)))
                        (not (and comment
                                  content
                                  (string-match-p "-->" (car content)))))
              (push (car rest) content)
              (setq rest (cdr rest)))
            (push (list :type 'html-block
                        :text (mapconcat #'identity (nreverse content) "\n"))
                  blocks)
            (setq lines rest)))

         ((and (>= (etaf-doc-markdown--indent line) 4)
               (not (etaf-doc-markdown--list-marker line)))
          (let ((collected (etaf-doc-markdown--collect-indented lines)))
            (push (list :type 'code-block
                        :lang nil
                        :info nil
                        :text (string-trim-right
                               (mapconcat #'identity (car collected) "\n") "\n"))
                  blocks)
            (setq lines (cdr collected))))

         ((etaf-doc-markdown--list-marker line)
          (let* ((collected (etaf-doc-markdown--collect-list lines))
                 (head (car collected))
                 (ordered (nth 0 head))
                 (start (nth 1 head))
                 (tight (nth 2 head))
                 (items (nth 3 head)))
            (push (list :type 'list
                        :ordered ordered
                        :start start
                        :tight tight
                        :items (mapcar (lambda (item)
                                         (etaf-doc-markdown--parse-list-item
                                          item ordered start))
                                       items))
                  blocks)
            (setq lines (cdr collected))))

         ((and (etaf-doc-markdown--feature-p :tables)
               (cdr lines)
               (string-match-p "|" line)
               (etaf-doc-markdown--table-delimiter-p (cadr lines)))
          (let ((table (etaf-doc-markdown--take-table lines)))
            (push (car table) blocks)
            (setq lines (cdr table))))

         ((let ((claim (etaf-doc-markdown--block-extension lines)))
            ;; A block extension claims its lines whole, so the loop needs no
            ;; branch of its own for each one.  The clause has to end with a
            ;; true value: a claim that consumes the rest of the document sets
            ;; LINES to nil, and a nil clause value would let the paragraph
            ;; branch handle the same line again.
            (when claim
              (push (car claim) blocks)
              (setq lines (cdr claim))
              t)))

         (t
          ;; Paragraph, possibly a Setext heading.
          (let ((rest (cdr lines))
                (texts (list line)))
            (while (and rest
                        (not (etaf-doc-markdown--blank-line-p (car rest)))
                        (not (etaf-doc-markdown--starts-block-p (car rest)))
                        (not (etaf-doc-markdown--setext-level (car rest))))
              (push (car rest) texts)
              (setq rest (cdr rest)))
            (let* ((ordered (nreverse texts))
                   (text (mapconcat #'identity ordered "\n"))
                   (level (and rest (etaf-doc-markdown--setext-level (car rest)))))
              (cond
               (level
                (push (list :type 'heading
                            :level level
                            :text (string-trim text)
                            :children (etaf-doc-markdown--parse-inlines
                                       (string-trim text)))
                      blocks)
                (setq lines (cdr rest)))
               ((and (etaf-doc-markdown-extension-p 'definition-list)
                     rest
                     (etaf-doc-markdown--definition-marker (car rest)))
                ;; The paragraph's last line is a term and the marker line
                ;; opens its definition, which is how a definition list is
                ;; written under the paragraph it belongs to.
                (let* ((term (car (last ordered)))
                       (body (butlast ordered))
                       (claimed (etaf-doc-markdown--definition-list-at
                                 (cons term rest))))
                  (when body
                    (let ((before (mapconcat #'identity body "\n")))
                      (push (etaf-doc-markdown--block-with-range
                             (list :type 'paragraph
                                   :text before
                                   :children (etaf-doc-markdown--parse-inlines before))
                             starts start (+ start (length body)))
                            blocks)))
                  (push (etaf-doc-markdown--block-with-range
                         (car claimed) starts
                         (+ start (length body))
                         (- total (length (cdr claimed))))
                        blocks)
                  (setq lines (cdr claimed))))
               (t
                (push (list :type 'paragraph
                            :text text
                            :children (etaf-doc-markdown--parse-inlines text))
                      blocks)
                (setq lines rest)))))))
        (setq index (- total (length lines)))
        (when (and starts (not (eq head blocks))
                   (not (plist-member (car blocks) :begin)))
          (setcar blocks (etaf-doc-markdown--block-with-range
                          (car blocks) starts start index)))
        ))
    (nreverse blocks)))

(defun etaf-doc-markdown--block-with-range (block starts begin end)
  "Return BLOCK carrying the character range STARTS gives from BEGIN to END.
STARTS is a line offset vector, or nil for a recursive parse of a snippet,
where no block carries a range and BLOCK comes back unchanged.  A clause that
pushes two blocks calls this for each one, so the earlier block ends where the
later one begins instead of taking the whole clause's range."
  (if starts
      (append block (list :begin (aref starts begin)
                          :end (aref starts end)))
    block))

(defun etaf-doc-markdown--fence-close-p (line char length)
  "Return non-nil when LINE closes a fence of CHAR repeated LENGTH times."
  (let ((trimmed (string-trim line)))
    (and (>= (length trimmed) length)
         (cl-every (lambda (candidate) (eq candidate char))
                   (string-to-list trimmed)))))

;;; ---------------------------------------------------------------------------
;;; Inline parser
;;; ---------------------------------------------------------------------------

(defconst etaf-doc-markdown--entities
  '(("amp" . "&") ("lt" . "<") ("gt" . ">") ("quot" . "\"") ("apos" . "'")
    ("nbsp" . "\u00a0") ("copy" . "\u00a9") ("reg" . "\u00ae") ("trade" . "\u2122")
    ("hellip" . "\u2026") ("mdash" . "\u2014") ("ndash" . "\u2013")
    ("laquo" . "\u00ab") ("raquo" . "\u00bb") ("times" . "\u00d7")
    ("divide" . "\u00f7") ("deg" . "\u00b0") ("plusmn" . "\u00b1")
    ("frac12" . "\u00bd") ("frac14" . "\u00bc") ("frac34" . "\u00be")
    ("larr" . "\u2190") ("rarr" . "\u2192") ("uarr" . "\u2191") ("darr" . "\u2193")
    ("harr" . "\u2194") ("bull" . "\u2022") ("middot" . "\u00b7")
    ("sect" . "\u00a7") ("para" . "\u00b6") ("dagger" . "\u2020")
    ("Dagger" . "\u2021") ("permil" . "\u2030") ("lsquo" . "\u2018")
    ("rsquo" . "\u2019") ("ldquo" . "\u201c") ("rdquo" . "\u201d")
    ("star" . "\u2606") ("check" . "\u2713") ("cross" . "\u2717"))
  "Named character references decoded in inline text.")

(defun etaf-doc-markdown--decode-entity (name)
  "Return the character for entity NAME, or nil."
  (cond
   ((string-prefix-p "#x" name)
    (ignore-errors (string (string-to-number (substring name 2) 16))))
   ((string-prefix-p "#" name)
    (ignore-errors (string (string-to-number (substring name 1)))))
   (t (cdr (assoc name etaf-doc-markdown--entities)))))

(defun etaf-doc-markdown--punctuation-p (char)
  "Return non-nil when CHAR is punctuation."
  (and (characterp char)
       (or (and (< char 128)
                (string-match-p "[!-/:-@\\[-`{-~]" (char-to-string char)))
           (memq (char-charset char) '(latin-iso8859-1 unicode)))))

(defun etaf-doc-markdown--delimiter-run (text index char)
  "Return the length of the run of CHAR at INDEX in TEXT."
  (let ((length 0))
    (while (and (< (+ index length) (length text))
                (eq (aref text (+ index length)) char))
      (setq length (1+ length)))
    length))

(defun etaf-doc-markdown--skip-code-span (text index end)
  "Advance INDEX past a backtick code span in TEXT up to END.
When INDEX opens a closed code span, return the offset after its closing
backticks; otherwise advance past the opening backtick run."
  (let ((span (etaf-doc-markdown--try-code-span text index end)))
    (if span
        (cdr span)
      (+ index (etaf-doc-markdown--delimiter-run text index ?`)))))

(defun etaf-doc-markdown--emphasis-close (text from char end)
  "Find a closing run of CHAR in TEXT searching from FROM to END.
Return (START END LENGTH) of the closing delimiter run, or nil.
Skips backtick code spans and backslash-escaped punctuation so delimiters
inside inline code do not prematurely close emphasis."
  (let ((index from)
        (found nil))
    (while (and (< index end) (not found))
      (let ((ch (aref text index)))
        (cond
         ((and (eq ch ?\\)
               (< (1+ index) end)
               (etaf-doc-markdown--punctuation-p (aref text (1+ index))))
          (setq index (+ index 2)))
         ((eq ch ?`)
          (setq index (etaf-doc-markdown--skip-code-span text index end)))
         ((eq ch char)
          (let* ((length (etaf-doc-markdown--delimiter-run text index char))
                 (before (and (> index 0) (aref text (1- index))))
                 (after (and (< (+ index length) end)
                             (aref text (+ index length))))
                 (before-space (or (null before) (memq before '(?\s ?\t ?\n))))
                 (after-space (or (null after) (memq after '(?\s ?\t ?\n))))
                 (before-punct (etaf-doc-markdown--punctuation-p before))
                 (after-punct (etaf-doc-markdown--punctuation-p after))
                 (right-flanking (and (not before-space)
                                      (or (not before-punct)
                                          after-space
                                          after-punct))))
            (if (and right-flanking
                     (or (not (eq char ?_))
                         after-space
                         after-punct))
                (setq found (list index (+ index length) length))
              (setq index (+ index length)))))
         (t (setq index (1+ index))))))
    found))

(defun etaf-doc-markdown--emphasis-can-open-p (text position end char run)
  "Return non-nil when a delimiter run at POSITION can open emphasis.
TEXT, END, CHAR and RUN describe the run being considered."
  (let* ((before (and (> position 0) (aref text (1- position))))
         (after (and (< (+ position run) end) (aref text (+ position run))))
         (before-space (or (null before) (memq before '(?\s ?\t ?\n))))
         (after-space (or (null after) (memq after '(?\s ?\t ?\n))))
         (before-punct (etaf-doc-markdown--punctuation-p before))
         (after-punct (etaf-doc-markdown--punctuation-p after))
         (left-flanking (and (not after-space)
                             (or (not after-punct)
                                 before-space
                                 before-punct))))
    (if (eq char ?_)
        (and left-flanking
             (or (not (and (not before-space)
                           (or (not before-punct) after-space after-punct)))
                 before-punct))
      left-flanking)))

(defun etaf-doc-markdown--find-closing-bracket (text from end)
  "Return the index of the `]' matching the `[' before FROM, or nil."
  (let ((depth 0)
        (index from)
        (found nil))
    (while (and (< index end) (not found))
      (let ((char (aref text index)))
        (cond ((eq char ?\[) (setq depth (1+ depth)))
              ((eq char ?\])
               (if (= depth 0)
                   (setq found index)
                 (setq depth (1- depth))))
              ((eq char ?\\) (setq index (1+ index)))))
      (setq index (1+ index)))
    found))

(defun etaf-doc-markdown--parse-destination (text from end)
  "Parse a link destination at FROM in TEXT up to END.
Return (URL TITLE NEXT) or nil."
  (when (and (< from end) (eq (aref text from) ?\())
    (let ((index (1+ from)))
      (while (and (< index end) (memq (aref text index) '(?\s ?\t ?\n)))
        (setq index (1+ index)))
      (let ((url nil)
            (title nil)
            (next nil))
        (cond
         ((and (< index end) (eq (aref text index) ?<))
          (let ((close (cl-position ?> text :start (1+ index) :end end)))
            (when close
              (setq url (substring text (1+ index) close)
                    index (1+ close)))))
         (t
          (let ((start index)
                (depth 0))
            (while (and (< index end)
                        (not (and (= depth 0)
                                  (memq (aref text index) '(?\s ?\t ?\n ?\))))))
              (cond ((eq (aref text index) ?\() (setq depth (1+ depth)))
                    ((eq (aref text index) ?\)) (setq depth (1- depth)))
                    ((eq (aref text index) ?\\) (setq index (1+ index))))
              (setq index (1+ index)))
            (when (> index start)
              (setq url (substring text start index))))))
        (when url
          (while (and (< index end) (memq (aref text index) '(?\s ?\t ?\n)))
            (setq index (1+ index)))
          (when (and (< index end)
                     (memq (aref text index) '(?\" ?\' ?\()))
            (let* ((open (aref text index))
                   (close (if (eq open ?\() ?\) open))
                   (title-end (cl-position close text :start (1+ index) :end end)))
              (when title-end
                (setq title (substring text (1+ index) title-end)
                      index (1+ title-end)))))
          (while (and (< index end) (memq (aref text index) '(?\s ?\t ?\n)))
            (setq index (1+ index)))
          (when (and (< index end) (eq (aref text index) ?\)))
            (setq next (1+ index))))
        (when (and url next)
          (list url title next))))))

(defun etaf-doc-markdown--try-bracket (text position end)
  "Parse a link, image or footnote reference at POSITION in TEXT.
Return (NODE . NEXT) or nil."
  (cond
   ;; Footnote reference.
   ((and (etaf-doc-markdown--feature-p :footnotes)
         (< (1+ position) end)
         (eq (aref text (1+ position)) ?^))
    (let* ((close (cl-position ?\] text :start (+ position 2) :end end))
           (label (and close (substring text (+ position 2) close))))
      (when (and close (>= (length label) 1))
        (cons (list :type 'footnote-ref :label label) (1+ close)))))
   (t
    (let* ((image (and (> position 0) (eq (aref text (1- position)) ?!)))
           (close (etaf-doc-markdown--find-closing-bracket text (1+ position) end)))
      (when close
        (let ((label (substring text (1+ position) close))
              (after (1+ close))
              (node nil)
              (next nil))
          (cond
           ((and (< after end) (eq (aref text after) ?\())
            (let ((destination (etaf-doc-markdown--parse-destination text after end)))
              (when destination
                (setq next (nth 2 destination))
                (setq node
                      (if image
                          (list :type 'image
                                :url (nth 0 destination)
                                :title (nth 1 destination)
                                :alt (etaf-doc-markdown--plain-text
                                      (etaf-doc-markdown--parse-inlines label)))
                        (list :type 'link
                              :url (nth 0 destination)
                              :title (nth 1 destination)
                              :children (etaf-doc-markdown--parse-inlines label)))))))
           ((and (< after end) (eq (aref text after) ?\[))
            (let ((ref-close (etaf-doc-markdown--find-closing-bracket
                              text (1+ after) end)))
              (when ref-close
                (let* ((ref-label (substring text (1+ after) ref-close))
                       (key (downcase (string-trim
                                       (if (string-empty-p ref-label) label ref-label))))
                       (definition (gethash key etaf-doc-markdown--refs)))
                  (when definition
                    (setq next (1+ ref-close))
                    (setq node
                          (if image
                              (list :type 'image
                                    :url (car definition)
                                    :title (cdr definition)
                                    :alt (etaf-doc-markdown--plain-text
                                          (etaf-doc-markdown--parse-inlines label)))
                            (list :type 'link
                                  :url (car definition)
                                  :title (cdr definition)
                                  :children (etaf-doc-markdown--parse-inlines label)))))))))
           (t
            (let* ((key (downcase (string-trim label)))
                   (definition (gethash key etaf-doc-markdown--refs)))
              (when definition
                (setq next after)
                (setq node
                      (if image
                          (list :type 'image
                                :url (car definition)
                                :title (cdr definition)
                                :alt label)
                        (list :type 'link
                              :url (car definition)
                              :title (cdr definition)
                              :children (etaf-doc-markdown--parse-inlines label))))))))
          (when (and node next)
            (cons node next))))))))

(defun etaf-doc-markdown--try-code-span (text position end)
  "Parse a code span at POSITION in TEXT up to END.
Return (NODE . NEXT) or nil."
  (let* ((run (etaf-doc-markdown--delimiter-run text position ?`))
         (search (+ position run))
         (found nil))
    (while (and (< search end) (not found))
      (if (and (eq (aref text search) ?`)
               (= (etaf-doc-markdown--delimiter-run text search ?`) run))
          (setq found search)
        (setq search (1+ search))))
    (when found
      (let ((code (substring text (+ position run) found)))
        (when (and (>= (length code) 2)
                   (eq (aref code 0) ?\s)
                   (eq (aref code (1- (length code))) ?\s)
                   (not (string-blank-p code)))
          (setq code (substring code 1 -1)))
        (cons (list :type 'code :text code) (+ found run))))))

(defconst etaf-doc-markdown--bare-url-prefixes
  '("https://" "http://" "www.")
  "Prefixes that begin a GFM bare URL, longest first per length.")

(defun etaf-doc-markdown--bare-url-prefix-p (text position end)
  "Return non-nil when a bare URL prefix starts at POSITION in TEXT.
Only the characters at POSITION are compared, so one candidate character
costs a bounded comparison: searching for the next prefix instead would scan
the rest of the inline text for every `h' and `w' it contains."
  (cl-some (lambda (prefix)
             (let ((finish (+ position (length prefix))))
               (and (<= finish end)
                    (eq t (compare-strings prefix nil nil text position finish)))))
           etaf-doc-markdown--bare-url-prefixes))

(defun etaf-doc-markdown--try-bare-url (text position end)
  "Parse a GFM bare URL at POSITION in TEXT up to END.
Return (NODE . NEXT) or nil.  Trailing punctuation and unbalanced closing
parentheses stay outside the link, as the extension specifies."
  (when (and (etaf-doc-markdown--bare-url-prefix-p text position end)
             (string-match "[^ \t\n<>]+" text position)
             (= (match-beginning 0) position))
    (let* ((matched (match-string 0 text))
           (start (match-beginning 0))
           (finish (match-end 0)))
      (while (and (> (length matched) 1)
                  (string-match-p "[.,:;!?]\\'" matched))
        (setq matched (substring matched 0 -1)
              finish (1- finish)))
      (while (and (> (length matched) 1)
                  (string-suffix-p ")" matched)
                  (> (cl-count ?\) matched) (cl-count ?\( matched)))
        (setq matched (substring matched 0 -1)
              finish (1- finish)))
      (when (and (> (length matched) 3) (> start 0))
        (cons (list :type 'link
                    :url (if (string-prefix-p "www." matched)
                             (concat "http://" matched)
                           matched)
                    :title nil
                    :children (list (list :type 'text :text matched)))
              finish)))))

(defun etaf-doc-markdown--find-double-delimiter (text from char end)
  "Return offset of closing CHAR+CHAR in TEXT from FROM up to END, or nil.
Skips backtick code spans and backslash-escaped punctuation."
  (let ((index from)
        (found nil))
    (while (and (< (1+ index) end) (not found))
      (let ((ch (aref text index)))
        (cond
         ((and (eq ch ?\\)
               (etaf-doc-markdown--punctuation-p (aref text (1+ index))))
          (setq index (+ index 2)))
         ((eq ch ?`)
          (setq index (etaf-doc-markdown--skip-code-span text index end)))
         ((and (eq ch char) (eq (aref text (1+ index)) char))
          (setq found index))
         (t (setq index (1+ index))))))
    found))

(defun etaf-doc-markdown--try-strike (text position end)
  "Parse strikethrough at POSITION in TEXT up to END.
Return (NODE . NEXT) or nil."
  (when (and (< (+ position 2) end)
             (eq (aref text (1+ position)) ?~))
    (let ((close (etaf-doc-markdown--find-double-delimiter
                  text (+ position 2) ?~ end)))
      (when (and close (> close (+ position 2)))
        (cons (list :type 'strike
                    :children (etaf-doc-markdown--parse-inlines
                               (substring text (+ position 2) close)))
              (+ close 2))))))

(defun etaf-doc-markdown--try-emphasis (text position end)
  "Parse emphasis or strong emphasis at POSITION in TEXT up to END.
Return (NODE . NEXT) or nil."
  (let* ((char (aref text position))
         (run (min 3 (etaf-doc-markdown--delimiter-run text position char))))
    (when (etaf-doc-markdown--emphasis-can-open-p text position end char run)
      (let ((close (etaf-doc-markdown--emphasis-close text (+ position run)
                                                    char end)))
        (when (and close (> (nth 0 close) (+ position run)))
          (let* ((strong (and (>= run 2) (>= (nth 2 close) 2)))
                 (triple (and (>= run 3) (>= (nth 2 close) 3)))
                 (width (cond (triple 3) (strong 2) (t 1)))
                 (inner (substring text (+ position width) (nth 0 close)))
                 (children (etaf-doc-markdown--parse-inlines inner))
                 (node (cond
                        (triple (list :type 'emph
                                      :children (list (list :type 'strong
                                                            :children children))))
                        (strong (list :type 'strong :children children))
                        (t (list :type 'emph :children children)))))
            (cons node (+ (nth 0 close) width))))))))

(defun etaf-doc-markdown--try-angle (text position end)
  "Parse an autolink or raw inline HTML at POSITION in TEXT up to END.
Return (NODE . NEXT) or nil."
  (let ((close (cl-position ?> text :start (1+ position) :end end)))
    (when close
      (let* ((inner (substring text (1+ position) close))
             (url (cond ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:[^ \t]*\\'" inner)
                         inner)
                        ((string-match-p "\\`[^ @<>]+@[^ @<>]+\\.[^ @<>]+\\'" inner)
                         (concat "mailto:" inner))
                        (t nil))))
        (cond
         (url (cons (list :type 'autolink
                          :url url
                          :children (list (list :type 'text :text inner)))
                    (1+ close)))
         ((string-match-p "\\`/?[a-zA-Z!][^>]*\\'" inner)
          (cons (list :type 'html :text (substring text position (1+ close)))
                (1+ close)))
         (t nil))))))

(defun etaf-doc-markdown--try-entity (text position end)
  "Parse a character reference at POSITION in TEXT up to END.
Return (STRING . NEXT) or nil."
  (let ((semicolon (cl-position ?\; text :start position :end end)))
    (when (and semicolon (<= (- semicolon position) 32))
      (let ((decoded (etaf-doc-markdown--decode-entity
                      (substring text (1+ position) semicolon))))
        (when decoded
          (cons decoded (1+ semicolon)))))))

(defun etaf-doc-markdown--parse-inlines (text)
  "Parse markdown inline TEXT into a list of inline nodes."
  (let ((nodes nil)
        (position 0)
        (literal 0)
        (end (length text)))
    (cl-labels
        ((push-node (node)
           (if (and (eq (plist-get node :type) 'text)
                    nodes
                    (eq (plist-get (car nodes) :type) 'text)
                    (not (string-suffix-p "\n" (plist-get (car nodes) :text))))
               (setcar nodes (plist-put (car nodes) :text
                                        (concat (plist-get (car nodes) :text)
                                                (plist-get node :text))))
             (push node nodes)))
         (flush ()
           (when (> position literal)
             (push-node (list :type 'text :text (substring text literal position))))))
      (while (< position end)
        (let* ((char (aref text position))
               (result
                (or (etaf-doc-markdown--inline-extension text position end)
                    (pcase char
                      (?` (etaf-doc-markdown--try-code-span text position end))
                      (?\[ (etaf-doc-markdown--try-bracket text position end))
                      (?! (and (< (1+ position) end)
                               (eq (aref text (1+ position)) ?\[)
                               (etaf-doc-markdown--try-bracket text (1+ position) end)))
                      (?< (etaf-doc-markdown--try-angle text position end))
                      (?& (etaf-doc-markdown--try-entity text position end))
                      ((or ?h ?w)
                       (and (etaf-doc-markdown--feature-p :autolinks)
                            (etaf-doc-markdown--try-bare-url text position end)))
                      (?~ (and (etaf-doc-markdown--feature-p :strikethrough)
                               (etaf-doc-markdown--try-strike text position end)))
                      ((or ?* ?_) (etaf-doc-markdown--try-emphasis text position end))
                      (_ nil)))))
          (cond
           (result
            (flush)
            (push-node (if (stringp (car result))
                           (list :type 'text :text (car result))
                         (car result)))
            (setq position (cdr result)
                  literal (cdr result)))
           ((and (eq char ?\n)
                 (>= position 2)
                 (eq (aref text (- position 1)) ?\s)
                 (eq (aref text (- position 2)) ?\s))
            (when (> (- position 2) literal)
              (push-node (list :type 'text
                               :text (substring text literal (- position 2)))))
            (push-node (list :type 'break :hard t))
            (setq position (1+ position)
                  literal position))
           ((eq char ?\n)
            (flush)
            (push-node (list :type 'break :hard nil))
            (setq position (1+ position)
                  literal position))
           ((and (eq char ?\\)
                 (< (1+ position) end)
                 (eq (aref text (1+ position)) ?\n))
            (flush)
            (push-node (list :type 'break :hard t))
            (setq position (+ position 2)
                  literal position))
           ((and (eq char ?\\)
                 (< (1+ position) end)
                 (etaf-doc-markdown--punctuation-p (aref text (1+ position))))
            (flush)
            (push-node (list :type 'text
                             :text (char-to-string (aref text (1+ position)))))
            (setq position (+ position 2)
                  literal position))
           (t (setq position (1+ position))))))
      (flush)
      (nreverse nodes))))

(defun etaf-doc-markdown--plain-text (nodes)
  "Return the concatenated plain text of inline NODES."
  (mapconcat
   (lambda (node)
     (pcase (plist-get node :type)
       ((or 'text 'code 'symbol) (or (plist-get node :text) (plist-get node :name) ""))
       ((or 'emph 'strong 'strike 'link 'autolink 'mark 'plot)
        (etaf-doc-markdown--plain-text (plist-get node :children)))
       ('wiki-link (or (plist-get node :label) (plist-get node :target) ""))
       ('color-chip (or (plist-get node :color) ""))
       ('badge (or (plist-get node :content) ""))
       ('image (or (plist-get node :alt) ""))
       ('break " ")
       ('html (or (plist-get node :text) ""))
       ('footnote-ref (format "[%s]" (or (plist-get node :label) "")))
       ((or 'annotation-ref 'comment) "")
       (_ "")))
   nodes))

;;; ---------------------------------------------------------------------------
;;; Document assembly
;;; ---------------------------------------------------------------------------

(defun etaf-doc-markdown--slug (text)
  "Return a stable anchor slug for TEXT."
  (let ((slug (downcase (string-trim text))))
    (setq slug (replace-regexp-in-string "[^[:alnum:]\u4e00-\u9fff]+" "-" slug))
    (setq slug (replace-regexp-in-string "\\`-+\\|-+\\'" "" slug))
    (if (string-empty-p slug) "section" slug)))

(defun etaf-doc-markdown--front-matter (text)
  "Strip YAML front matter from TEXT.
Return (META . BODY) where META is an alist of top-level key strings."
  (let* ((lines (split-string text "\n"))
         (close (and (equal (string-trim (car lines)) "---")
                     (cl-position-if
                      (lambda (line)
                        (member (string-trim line) '("---" "...")))
                      (cdr lines)))))
    (if close
        (let* ((meta-text (mapconcat #'identity (cl-subseq (cdr lines) 0 close) "\n"))
               (body (mapconcat #'identity (nthcdr (+ close 2) lines) "\n"))
               (meta (delq nil
                           (mapcar
                            (lambda (line)
                              (when (string-match
                                     "\\`\\([A-Za-z0-9_.-]+\\):[ \t]*\\(.*\\)\\'" line)
                                (let* ((key (downcase (match-string 1 line)))
                                       (raw (match-string 2 line))
                                       (value (string-trim raw)))
                                  (setq value (replace-regexp-in-string
                                               "\\`[\"']\\(.*\\)[\"']\\'" "\\1" value))
                                  (cons key value))))
                            (split-string meta-text "\n")))))
          (cons meta body))
      (cons nil text))))

(defun etaf-doc-markdown--number-footnotes (blocks)
  "Number footnote references in BLOCKS depth-first.
Return (BLOCKS . ORDER); ORDER holds labels in first-reference order.  Each
reference node receives :number for the views layer."
  (let ((order nil))
    (cl-labels
        ((number-inline
          (node)
          (when (eq (plist-get node :type) 'footnote-ref)
            (let* ((label (plist-get node :label))
                   (existing (cl-position label order :test #'equal))
                   (number (if (numberp existing) (1+ existing) (1+ (length order)))))
              (unless (numberp existing)
                (setq order (append order (list label))))
              (plist-put node :number number)))
          (dolist (child (plist-get node :children))
            (number-inline child)))
         (number-block
          (block)
          (pcase (plist-get block :type)
            ((or 'heading 'paragraph)
             (dolist (child (plist-get block :children))
               (number-inline child)))
            ((or 'blockquote 'list-item)
             (number-blocks (plist-get block :children)))
            ('list
             (dolist (item (plist-get block :items))
               (number-blocks (plist-get item :children))))
            ('table
             (dolist (cell (plist-get block :header))
               (dolist (child cell) (number-inline child)))
             (dolist (row (plist-get block :rows))
               (dolist (cell row)
                 (dolist (child cell) (number-inline child)))))))
         (number-blocks
          (blocks)
          (dolist (block blocks)
            (number-block block))))
      (number-blocks blocks))
    (cons blocks order)))

(defun etaf-doc-markdown--outline (blocks)
  "Return the outline of BLOCKS as (LEVEL TEXT ID) lists.
TEXT is the rendered plain text of the heading, so navigation can match it
against the buffer even when the source used inline markup."
  (let ((outline nil))
    (dolist (block blocks)
      (when (eq (plist-get block :type) 'heading)
        (push (list (plist-get block :level)
                    (string-trim
                     (etaf-doc-markdown--plain-text (plist-get block :children)))
                    (plist-get block :id))
              outline)))
    (nreverse outline)))

(defun etaf-doc-markdown-parse (text &optional flavor)
  "Parse markdown TEXT into a document plist.
FLAVOR selects the dialect: a name from `etaf-doc-markdown-flavors' (`gfm' is
the default), a feature plist overriding it, or nil.  Keys are `:meta' (front
matter alist), `:title', `:children' (top-level blocks with heading ids),
`:outline' and `:footnotes' (a list of plists with `:label', `:number' and
`:children'), and `:features' (the resolved extension plist)."
  (let* ((text (replace-regexp-in-string "\r\n?" "\n" text))
         (etaf-doc-markdown--features (etaf-doc-markdown--features-for flavor))
         (front (if (etaf-doc-markdown--feature-p :front-matter)
                    (etaf-doc-markdown--front-matter text)
                  (cons nil text)))
         (body (cdr front))
         (etaf-doc-markdown--refs
          ;; Reference definitions may appear after their use, so collect
          ;; every definition before any inline parsing starts.
          (let ((refs (make-hash-table :test #'equal)))
            (dolist (line (split-string body "\n"))
              (let ((definition (etaf-doc-markdown--reference-definition line)))
                (when definition
                  (puthash (car definition)
                           (cons (nth 1 definition) (nth 2 definition))
                           refs))))
            refs))
         (etaf-doc-markdown--footnotes nil)
         (etaf-doc-markdown--abbreviations
          ;; An abbreviation can be used before it is defined, so every
          ;; definition is collected before any inline parsing, exactly as
          ;; link reference definitions are.
          (let ((table (make-hash-table :test #'equal)))
            (when (etaf-doc-markdown-extension-p 'abbreviation)
              (dolist (line (split-string body "\n"))
                (let ((definition (etaf-doc-markdown--abbreviation-definition line)))
                  (when definition
                    (puthash (car definition) (cdr definition) table)))))
            table))
         (annotation-raw
          (when (etaf-doc-markdown-extension-p 'annotation)
            (etaf-doc-markdown--collect-annotations body)))
         (etaf-doc-markdown--annotations
          (let ((table (make-hash-table :test #'equal)))
            (dolist (entry annotation-raw)
              (puthash (car entry) (cdr entry) table))
            table))
         (lines (split-string body "\n"))
         (blocks (etaf-doc-markdown--parse-blocks
                  lines
                  (etaf-doc-markdown--line-starts
                   lines (- (length text) (length body)) (length text)))))
    ;; Parse collected annotation bodies after main blocks so nested inline
    ;; markup renders cleanly without recursive annotation expansion.
    (let ((annotation-alist
           (when annotation-raw
             (let ((etaf-doc-markdown--annotations (make-hash-table :test #'equal)))
               (mapcar (lambda (entry)
                         (cons (car entry)
                               (etaf-doc-markdown--parse-blocks
                                (split-string (cdr entry) "\n"))))
                       annotation-raw)))))
      ;; Assign stable, unique heading anchors.
      (let ((seen (make-hash-table :test #'equal)))
        (dolist (block blocks)
          (when (eq (plist-get block :type) 'heading)
            (let* ((base (etaf-doc-markdown--slug
                          (etaf-doc-markdown--plain-text (plist-get block :children))))
                   (count (1+ (or (gethash base seen) 0))))
              (puthash base count seen)
              (plist-put block :id (if (= count 1) base (format "%s-%d" base count)))))))
      (let* ((numbered (etaf-doc-markdown--number-footnotes blocks))
             (ordered (cdr numbered))
             (labels (cl-loop for label in ordered
                              for index from 1
                              collect (cons label index)))
             (footnote-nodes
              (cl-loop for label in ordered
                       append (when-let* ((definition
                                           (alist-get label etaf-doc-markdown--footnotes
                                                      nil nil #'equal)))
                                (list (list :type 'footnote-def
                                            :label label
                                            :number (cdr (assq label labels))
                                            :children definition))))))
        (append
         (list :meta (car front)
               :features etaf-doc-markdown--features
               :title (or (cdr (assoc "title" (car front)))
                          (let ((first-heading
                                 (cl-find-if (lambda (block)
                                               (eq (plist-get block :type) 'heading))
                                             blocks)))
                            (and first-heading
                                 (string-trim (plist-get first-heading :text)))))
               :children blocks
               :outline (etaf-doc-markdown--outline blocks)
               :footnotes footnote-nodes)
         (when annotation-alist
           (list :annotations annotation-alist)))))))


;;; ---------------------------------------------------------------------------
;;; Extensions: definition lists, sub- and superscript, abbreviations, math
;;; ---------------------------------------------------------------------------

(defconst etaf-doc-markdown-subscript-table
  '((?0 . ?₀) (?1 . ?₁) (?2 . ?₂) (?3 . ?₃) (?4 . ?₄) (?5 . ?₅) (?6 . ?₆)
    (?7 . ?₇) (?8 . ?₈) (?9 . ?₉) (?+ . ?₊) (?- . ?₋) (?= . ?₌)
    (?\( . ?₍) (?\) . ?₎)
    (?a . ?ₐ) (?e . ?ₑ) (?h . ?ₕ) (?i . ?ᵢ) (?j . ?ⱼ) (?k . ?ₖ) (?l . ?ₗ)
    (?m . ?ₘ) (?n . ?ₙ) (?o . ?ₒ) (?p . ?ₚ) (?r . ?ᵣ) (?s . ?ₛ) (?t . ?ₜ)
    (?u . ?ᵤ) (?v . ?ᵥ) (?x . ?ₓ))
  "Characters a subscript run can be written with, as (CHAR . SCRIPT).")

(defconst etaf-doc-markdown-superscript-table
  '((?0 . ?⁰) (?1 . ?¹) (?2 . ?²) (?3 . ?³) (?4 . ?⁴) (?5 . ?⁵) (?6 . ?⁶)
    (?7 . ?⁷) (?8 . ?⁸) (?9 . ?⁹) (?+ . ?⁺) (?- . ?⁻) (?= . ?⁼)
    (?\( . ?⁽) (?\) . ?⁾)
    (?a . ?ᵃ) (?b . ?ᵇ) (?c . ?ᶜ) (?d . ?ᵈ) (?e . ?ᵉ) (?f . ?ᶠ) (?g . ?ᵍ)
    (?h . ?ʰ) (?i . ?ⁱ) (?j . ?ʲ) (?k . ?ᵏ) (?l . ?ˡ) (?m . ?ᵐ) (?n . ?ⁿ)
    (?o . ?ᵒ) (?p . ?ᵖ) (?r . ?ʳ) (?s . ?ˢ) (?t . ?ᵗ) (?u . ?ᵘ) (?v . ?ᵛ)
    (?w . ?ʷ) (?x . ?ˣ) (?y . ?ʸ) (?z . ?ᶻ))
  "Characters a superscript run can be written with, as (CHAR . SCRIPT).")

(defun etaf-doc-markdown--script-text (text table)
  "Return TEXT written in TABLE's script characters, or nil when one has none.
A run this renderer cannot raise or lower is left as the source wrote it: a
page that dropped the markers would silently change what the text says."
  (let ((result nil))
    (catch 'unmapped
      (dotimes (index (length text))
        (let ((mapped (alist-get (aref text index) table)))
          (unless mapped (throw 'unmapped nil))
          (push mapped result)))
      (apply #'string (nreverse result)))))

(defun etaf-doc-markdown--script-at (text position end marker table type)
  "Return (NODE . NEXT) for a TYPE run marked by MARKER at POSITION.
TEXT, END and MARKET name the text being parsed and the character that opens
the run; TABLE maps a character to its script form."
  (let ((start (1+ position)))
    (when (and (< start end)
               ;; A space right after the marker is ordinary text, not a run.
               (not (memq (aref text start) '(?\s ?\t ?\n)))
               ;; The marker written twice is the other syntax on that
               ;; character, such as `~~' for strikethrough.
               (not (eq (aref text start) marker)))
      (let ((index start)
            (close nil))
        (while (and (< index end) (not close))
          (let ((char (aref text index)))
            (cond
             ((eq char ?\n) (setq index end))
             ((and (eq char marker)
                   (> index start)
                   (not (memq (aref text (1- index)) '(?\s ?\t)))
                   (or (>= (1+ index) end)
                       (not (eq (aref text (1+ index)) marker))))
              (setq close index))
             (t (setq index (1+ index))))))
        (when close
          (let ((content (substring text start close)))
            (when-let* ((rendered (etaf-doc-markdown--script-text content table)))
              ;; The script form is decided while parsing, so the view needs no
              ;; table of its own and the claim and the drawing agree.
              (cons (list :type type :text content :rendered rendered)
                    (1+ close)))))))))

(defun etaf-doc-markdown--try-subscript (text position end)
  "Return (NODE . NEXT) for a `~text~' subscript at POSITION."
  (etaf-doc-markdown--script-at text position end ?~
                               etaf-doc-markdown-subscript-table 'subscript))

(defun etaf-doc-markdown--try-superscript (text position end)
  "Return (NODE . NEXT) for a `^text^' superscript at POSITION."
  (etaf-doc-markdown--script-at text position end ?^
                               etaf-doc-markdown-superscript-table 'superscript))

(defun etaf-doc-markdown--definition-marker (line)
  "Return (TEXT INDENT) when LINE opens a definition, else nil.
TEXT is what follows the `:' or `~' marker and INDENT the column it starts at,
which is where the definition's continuation lines line up."
  (when (and (stringp line)
             (string-match "\\` ? ? ?[:~][ \t]+\\(.*\\)\\'" line))
    (list (match-string 1 line) (match-beginning 1))))

(defun etaf-doc-markdown--definition-list-at (lines)
  "Return (BLOCK . REST) when LINES open a definition list.
A term line followed by a line that starts with `:' or `~' is a definition
list.  Another term right after a definition continues the list, so one list
holds as many terms as the document writes under it."
  (let ((term (car lines))
        (rest (cdr lines))
        (term-lines nil)
        (items nil))
    (when (and term rest
               (not (etaf-doc-markdown--blank-line-p term))
               (< (etaf-doc-markdown--indent term) 4)
               (not (etaf-doc-markdown--starts-block-p term))
               (etaf-doc-markdown--definition-marker (car rest)))
      (setq term-lines (list term))
      (while (and rest (etaf-doc-markdown--definition-marker (car rest)))
        (let ((definitions nil))
          (while (and rest (etaf-doc-markdown--definition-marker (car rest)))
            (let* ((marker (etaf-doc-markdown--definition-marker (car rest)))
                   (indent (nth 1 marker))
                   (content (list (car marker))))
              (setq rest (cdr rest))
              ;; A definition keeps the blank lines inside it, but the blank
              ;; line that separates the list from what follows stays in REST:
              ;; a document's blank lines are lines the page paints, so eating
              ;; one here would pull the next block against the list.
              (while
                  (and rest
                       (if (etaf-doc-markdown--blank-line-p (car rest))
                           (let ((next (cadr rest)))
                             (and next
                                  (or (etaf-doc-markdown--definition-marker next)
                                      (>= (etaf-doc-markdown--indent next) indent))))
                         (>= (etaf-doc-markdown--indent (car rest)) indent)))
                (push (if (etaf-doc-markdown--blank-line-p (car rest))
                          ""
                        (etaf-doc-markdown--strip-indent (car rest) indent))
                      content)
                (setq rest (cdr rest)))
              (push (list :type 'definition
                          :children (etaf-doc-markdown--parse-blocks
                                     (nreverse content)))
                    definitions)))
          (push (list :type 'definition-item
                      :term (string-trim (mapconcat #'identity term-lines "\n"))
                      :children (etaf-doc-markdown--parse-inlines
                                 (string-trim (mapconcat #'identity term-lines "\n")))
                      :definitions (nreverse definitions))
                items))
        ;; A further term with a definition under it belongs to this list.
        (let ((gap rest))
          (while (and gap (etaf-doc-markdown--blank-line-p (car gap)))
            (setq gap (cdr gap)))
          (when (and gap (etaf-doc-markdown--definition-marker (cadr gap)))
            (setq term-lines (list (car gap)))
            (setq rest (cdr gap)))))
      (cons (list :type 'definition-list :items (nreverse items)) rest))))

(defun etaf-doc-markdown--math-block-start-p (line)
  "Return non-nil when LINE opens a display formula."
  (and line (string-match-p "\\` ? ? ?\\$\\$" line)))

(defun etaf-doc-markdown--math-block-at (lines)
  "Return (BLOCK . REST) when LINES open a display formula.
`$$text$$' on one line is a formula by itself; a bare `$$' opens one that the
next bare `$$' closes, and the lines between are its body."
  (let ((line (car lines)))
    (when (etaf-doc-markdown--math-block-start-p line)
      (if (string-match "\\` ? ? ?\\$\\$\\(.*?\\)\\$\\$[ \t]*\\'" line)
          (cons (list :type 'math :display t :text (string-trim (match-string 1 line)))
                (cdr lines))
        (let ((rest (cdr lines))
              (content nil)
              (closed nil))
          (while (and rest (not closed))
            (if (string-match-p "\\` ? ? ?\\$\\$[ \t]*\\'" (car rest))
                (setq closed t)
              (push (car rest) content))
            (setq rest (cdr rest)))
          (when closed
            (cons (list :type 'math :display t
                        :text (string-trim (mapconcat #'identity (nreverse content) "\n")
                                           "\n" "\n"))
                  rest)))))))

(defun etaf-doc-markdown--math-close (text from end)
  "Return the index of the `$' closing a formula whose text starts at FROM.
A closing `$' is neither preceded by a space nor followed by a digit, which is
what keeps `$5' and `$5.00' money instead of a formula."
  (let ((index from)
        (close nil))
    (while (and (< index end) (not close))
      (let ((char (aref text index)))
        (cond
         ((eq char ?\n) (setq index end))
         ((and (eq char ?$)
               (> index from)
               (not (memq (aref text (1- index)) '(?\s ?\t)))
               (or (>= (1+ index) end)
                   (not (and (>= (aref text (1+ index)) ?0)
                             (<= (aref text (1+ index)) ?9)))))
          (setq close index))
         (t (setq index (1+ index))))))
    close))

(defun etaf-doc-markdown--try-math (text position end)
  "Return (NODE . NEXT) for a `$...$' formula at POSITION."
  (let ((start (1+ position)))
    (when (and (< start end)
               (not (memq (aref text start) '(?\s ?\t ?\n ?$))))
      (when-let* ((close (etaf-doc-markdown--math-close text start end)))
        (cons (list :type 'math :display nil :text (substring text start close))
              (1+ close))))))

(defun etaf-doc-markdown--abbreviation-definition (line)
  "Return (WORD . TITLE) when LINE defines an abbreviation.
`*[WORD]: TITLE' is the syntax; the definition paints nothing itself."
  (when (string-match "\\` ? ? ?\\*\\[\\([^]]+\\)\\]:[ \t]+\\(.*\\)\\'" line)
    (cons (match-string 1 line) (string-trim (match-string 2 line)))))

(defconst etaf-doc-markdown-emoji
  '(("smile" . "😄") ("grin" . "😁") ("joy" . "😂") ("laughing" . "😆")
    ("wink" . "😉") ("blush" . "😊") ("heart_eyes" . "😍") ("thinking" . "🤔")
    ("sob" . "😭") ("cry" . "😢") ("sunglasses" . "😎") ("sweat_smile" . "😅")
    ("thumbsup" . "👍") ("+1" . "👍") ("thumbsdown" . "👎") ("-1" . "👎")
    ("clap" . "👏") ("wave" . "👋") ("muscle" . "💪") ("pray" . "🙏")
    ("ok_hand" . "👌") ("point_right" . "👉") ("eyes" . "👀") ("brain" . "🧠")
    ("heart" . "❤️") ("broken_heart" . "💔") ("sparkling_heart" . "💖")
    ("fire" . "🔥") ("star" . "⭐") ("star2" . "🌟") ("sparkles" . "✨")
    ("zap" . "⚡") ("boom" . "💥") ("tada" . "🎉") ("rocket" . "🚀")
    ("bug" . "🐛") ("wrench" . "🔧") ("hammer" . "🔨") ("gear" . "⚙️")
    ("package" . "📦") ("truck" . "🚚") ("globe_with_meridians" . "🌐")
    ("lock" . "🔒") ("key" . "🔑") ("bell" . "🔔") ("calendar" . "📅")
    ("clock1" . "🕐") ("hourglass" . "⌛") ("chart_with_upwards_trend" . "📈")
    ("bar_chart" . "📊") ("clipboard" . "📋") ("memo" . "📝")
    ("book" . "📖") ("books" . "📚") ("bulb" . "💡") ("pushpin" . "📌")
    ("paperclip" . "📎") ("scissors" . "✂️") ("mag" . "🔍") ("link" . "🔗")
    ("computer" . "💻") ("keyboard" . "⌨️") ("phone" . "☎️") ("email" . "✉️")
    ("inbox_tray" . "📥") ("outbox_tray" . "📤") ("floppy_disk" . "💾")
    ("battery" . "🔋") ("sunny" . "☀️") ("cloud" . "☁️") ("umbrella" . "☔")
    ("snowflake" . "❄️") ("droplet" . "💧") ("rainbow" . "🌈") ("moon" . "🌙")
    ("apple" . "🍎") ("coffee" . "☕") ("beer" . "🍺") ("pizza" . "🍕")
    ("cake" . "🍰") ("gift" . "🎁") ("trophy" . "🏆") ("medal_sports" . "🏅")
    ("crown" . "👑") ("gem" . "💎") ("money_with_wings" . "💸")
    ("credit_card" . "💳") ("moneybag" . "💰") ("white_check_mark" . "✅")
    ("heavy_check_mark" . "✔️") ("x" . "❌") ("warning" . "⚠️")
    ("no_entry" . "⛔") ("information_source" . "ℹ️") ("question" . "❓")
    ("exclamation" . "❗") ("construction" . "🚧") ("art" . "🎨")
    ("musical_note" . "🎵") ("headphones" . "🎧") ("microphone" . "🎤")
    ("video_camera" . "📹") ("camera" . "📷") ("pencil2" . "✏️")
    ("mega" . "📣") ("speech_balloon" . "💬") ("thought_balloon" . "💭")
    ("zzz" . "💤") ("100" . "💯") ("see_no_evil" . "🙈") ("cat" . "🐱")
    ("dog" . "🐶") ("penguin" . "🐧") ("snake" . "🐍") ("unicorn" . "🦄"))
  "Emoji shortcodes this renderer knows, as (NAME . CHARACTER).
A name outside this table stays literal text, so a document that writes
`:notanemoji:' keeps its colons instead of losing them to a guess.")

(defun etaf-doc-markdown--try-emoji (text position end)
  "Return (NODE . NEXT) for a `:name:' shortcode at POSITION in TEXT.
Only a known name matches, and only as a whole token: `12:30:45' is a time and
`a:b:' is prose, so the two colons need a word boundary on the outside."
  (let ((start (1+ position)))
    (when (and (< start end)
               (or (= position 0)
                   (not (etaf-doc-markdown--word-char-p (aref text (1- position)))))
               (let ((char (aref text start)))
                 ;; `+1' and `-1' are names too: the table carries both, and
                 ;; the trailing colon and the word boundaries still keep a
                 ;; time or a `:-)' out of this path.
                 (or (and (>= char ?a) (<= char ?z))
                     (and (>= char ?A) (<= char ?Z))
                     (and (>= char ?0) (<= char ?9))
                     (memq char '(?+ ?-)))))
      (let ((index start))
        (while (and (< index end)
                    (let ((char (aref text index)))
                      (or (and (>= char ?a) (<= char ?z))
                          (and (>= char ?A) (<= char ?Z))
                          (and (>= char ?0) (<= char ?9))
                          (memq char '(?_ ?- ?+)))))
          (setq index (1+ index)))
        (when (and (< index end)
                   (eq (aref text index) ?:)
                   (> index start)
                   (or (= (1+ index) end)
                       (not (etaf-doc-markdown--word-char-p (aref text (1+ index))))))
          (let* ((name (downcase (substring text start index)))
                 (char (cdr (assoc name etaf-doc-markdown-emoji))))
            (when char
              (cons (list :type 'emoji :text (substring text position (1+ index))
                          :char char)
                    (1+ index)))))))))

(defun etaf-doc-markdown--try-mark (text position end)
  "Return (NODE . NEXT) for `==text==' at POSITION in TEXT.
The delimiter needs a non-space on its inside edge, so a comparison written
`a == b' stays prose.  A `{.class}' after the closing pair names the
highlight colour."
  (when (and (<= (+ position 2) end)
             (eq (aref text position) ?=)
             (eq (aref text (1+ position)) ?=))
    (let* ((start (+ position 2))
           (close (etaf-doc-markdown--find-double-delimiter text start ?= end)))
      (when (and close (< close end) (> close start)
                 (not (memq (aref text start) '(?\s ?\t)))
                 (not (memq (aref text (1- close)) '(?\s ?\t))))
        (let* ((class (etaf-doc-markdown--inline-class text (+ close 2) end))
               (content (substring text start close)))
          (cons (list :type 'mark
                      :class (car class)
                      :text (substring text position (cdr class))
                      :children (etaf-doc-markdown--parse-inlines content))
                (cdr class)))))))

(defun etaf-doc-markdown--inline-class (text position end)
  "Return (CLASS . NEXT) for a `{.name}' after POSITION in TEXT.
NEXT is POSITION when no attribute follows, so a caller can always use it."
  (if (and (< position end)
           (eq (aref text position) ?{))
      (let ((close (cl-position ?} text :start position :end end)))
        (if (and close
                 (string-match-p "\\`\\.[a-zA-Z0-9_-]+\\'"
                                 (substring text (1+ position) close)))
            (cons (substring text (+ position 2) close) (1+ close))
          (cons nil position)))
    (cons nil position)))

(defun etaf-doc-markdown--try-icon (text position end)
  "Return (NODE . NEXT) for an `::name::' icon at POSITION in TEXT."
  (when (and (<= (+ position 4) end)
             (eq (aref text position) ?:)
             (eq (aref text (1+ position)) ?:))
    (let* ((start (+ position 2))
           (close (string-match "::" text start)))
      (when (and close (< close end) (> close start))
        (let ((name (substring text start close)))
          (when (string-match-p "\\`[a-zA-Z0-9_.:-]+\\'" name)
            (cons (list :type 'icon
                        :name name
                        :text (substring text position (+ close 2)))
                  (+ close 2))))))))

(defun etaf-doc-markdown--try-kbd (text position end)
  "Return (NODE . NEXT) for a `:kbd[KEY+KEY]' group at POSITION in TEXT."
  (when (and (<= (+ position 5) end)
             (eq (aref text position) ?:)
             (string-match-p "\\`kbd\\["
                             (substring text (1+ position) (+ position 5))))
    (let* ((start (+ position 5))
           (close (cl-position ?\] text :start start :end end)))
      (when (and close (> close start))
        (let ((keys (mapcar #'string-trim
                            (split-string (substring text start close)
                                          "[+]" t " "))))
          (when keys
            (cons (list :type 'kbd
                        :keys keys
                        :text (substring text position (1+ close)))
                  (1+ close))))))))

(defun etaf-doc-markdown--collect-annotations (body)
  "Return (LABEL . RAW-BODY) alist of `[+label]:' definitions in BODY.
Skips fenced code blocks and keeps the first definition per label."
  (let ((lines (split-string body "\n"))
        (fence nil)
        (result nil))
    (while lines
      (let ((line (car lines)))
        (cond
         ((string-match "\\`[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
          (let ((marker (match-string 1 line))
                (bare (string-match-p "\\`[ \t]*\\'" (substring line (match-end 0)))))
            (if fence
                (when (and bare
                           (eq (aref fence 0) (aref marker 0))
                           (>= (length marker) (length fence)))
                  (setq fence nil))
              (setq fence marker)))
          (setq lines (cdr lines)))
         (fence
          (setq lines (cdr lines)))
         ((etaf-doc-markdown--annotation-definition line)
          (let* ((def (etaf-doc-markdown--annotation-definition line))
                 (label (car def))
                 (first (cdr def))
                 (content (if (string-empty-p (string-trim first)) nil (list first)))
                 (rest (cdr lines)))
            (while (and rest
                        (or (and (etaf-doc-markdown--blank-line-p (car rest))
                                 (cadr rest)
                                 (>= (etaf-doc-markdown--indent (cadr rest)) 2))
                            (>= (etaf-doc-markdown--indent (car rest)) 2)))
              (push (if (etaf-doc-markdown--blank-line-p (car rest))
                        ""
                      (etaf-doc-markdown--strip-indent (car rest) 2))
                    content)
              (setq rest (cdr rest)))
            (unless (assoc label result)
              (push (cons label (string-trim (mapconcat #'identity (nreverse content) "\n")))
                    result))
            (setq lines rest)))
         (t (setq lines (cdr lines))))))
    (nreverse result)))

(defun etaf-doc-markdown--comment-block-start-p (line)
  "Return non-nil when LINE opens an Obsidian `%%' comment block."
  (and line (string-match-p "\\` ? ? ?%%" line)))

(defun etaf-doc-markdown--comment-block-at (lines)
  "Return (BLOCK . REST) when LINES open an Obsidian `%%...%%' block."
  (let ((line (car lines)))
    (when (etaf-doc-markdown--comment-block-start-p line)
      (cond
       ((string-match-p "\\` ? ? ?%%.+%%[ \t]*\\'" line)
        (cons (list :type 'comment :text line) (cdr lines)))
       ((string-match-p "\\` ? ? ?%%[ \t]*\\'" line)
        (let ((rest (cdr lines))
              (closed nil))
          (while (and rest (not closed))
            (when (string-match-p "%%[ \t]*\\'" (car rest))
              (setq closed t))
            (setq rest (cdr rest)))
          (when closed
            (cons (list :type 'comment :text "") rest))))))))

(defun etaf-doc-markdown--try-plot (text position end)
  "Return (NODE . NEXT) for `!!spoiler!!' hidden text at POSITION in TEXT."
  (when (and (<= (+ position 2) end)
             (eq (aref text position) ?!)
             (eq (aref text (1+ position)) ?!))
    (let* ((start (+ position 2))
           (close (etaf-doc-markdown--find-double-delimiter text start ?! end)))
      (when (and close (< close end) (> close start)
                 (not (memq (aref text start) '(?\s ?\t ?\n)))
                 (not (memq (aref text (1- close)) '(?\s ?\t ?\n))))
        (let* ((class (etaf-doc-markdown--inline-class text (+ close 2) end))
               (content (substring text start close)))
          (cons (list :type 'plot
                      :class (car class)
                      :text (substring text position (cdr class))
                      :children (etaf-doc-markdown--parse-inlines content))
                (cdr class)))))))

(defun etaf-doc-markdown--try-comment (text position end)
  "Return (NODE . NEXT) for an Obsidian inline `%%comment%%' at POSITION."
  (when (and (<= (+ position 2) end)
             (eq (aref text position) ?%)
             (eq (aref text (1+ position)) ?%))
    (let* ((start (+ position 2))
           (close (etaf-doc-markdown--find-double-delimiter text start ?% end)))
      (when (and close (< close end) (>= close start))
        (cons (list :type 'comment
                    :text (substring text position (+ close 2)))
              (+ close 2))))))

(defun etaf-doc-markdown--try-wiki-link (text position end)
  "Return (NODE . NEXT) for `[[target#anchor|alias]]' at POSITION in TEXT."
  (when (and (<= (+ position 4) end)
             (eq (aref text position) ?\[)
             (eq (aref text (1+ position)) ?\[))
    (let* ((start (+ position 2))
           (close (etaf-doc-markdown--find-double-delimiter text start ?\] end)))
      (when (and close (> close start)
                 (not (string-search "\n" (substring text start close))))
        (let* ((inner (string-trim (substring text start close)))
               (bar (string-search "|" inner))
               (dest (string-trim (if bar (substring inner 0 bar) inner)))
               (alias (and bar (string-trim (substring inner (1+ bar)))))
               (hash (string-search "#" dest))
               (target (string-trim (if hash (substring dest 0 hash) dest)))
               (anchor (and hash (string-trim (substring dest (1+ hash)))))
               (label (cond
                       ((and alias (not (string-empty-p alias))) alias)
                       ((and (not (string-empty-p target))
                             anchor (not (string-empty-p anchor)))
                        (format "%s › %s" target anchor))
                       ((not (string-empty-p target)) target)
                       ((and anchor (not (string-empty-p anchor))) anchor)
                       (t inner))))
          (unless (string-empty-p dest)
            (cons (list :type 'wiki-link
                        :target target
                        :anchor anchor
                        :label label
                        :text (substring text position (+ close 2)))
                  (+ close 2))))))))

(defun etaf-doc-markdown--try-annotation (text position end)
  "Return (NODE . NEXT) for a defined `[+label]' annotation at POSITION."
  (when (and (<= (+ position 3) end)
             (eq (aref text position) ?\[)
             (eq (aref text (1+ position)) ?+))
    (let ((close (cl-position ?\] text :start (+ position 2) :end end)))
      (when (and close (> close (+ position 2)))
        (let ((label (string-trim (substring text (+ position 2) close))))
          (when (and (not (string-empty-p label))
                     (hash-table-p etaf-doc-markdown--annotations)
                     (gethash label etaf-doc-markdown--annotations))
            (cons (list :type 'annotation-ref
                        :label label
                        :text (substring text position (1+ close)))
                  (1+ close))))))))

(defun etaf-doc-markdown--try-color-chip (text position end)
  "Return (NODE . NEXT) for `:color[#4493f8]' at POSITION in TEXT."
  (when (and (<= (+ position 11) end)
             (eq (aref text position) ?:)
             (string-prefix-p "color[" (substring text (1+ position) (min end (+ position 8)))))
    (let* ((start (+ position 7))
           (close (cl-position ?\] text :start start :end end)))
      (when (and close (> close start))
        (let ((hex (string-trim (substring text start close))))
          (when (string-match-p "\\`#\\(?:[[:xdigit:]]\\{3\\}\\|[[:xdigit:]]\\{6\\}\\)\\'" hex)
            (cons (list :type 'color-chip
                        :color hex
                        :text (substring text position (1+ close)))
                  (1+ close))))))))

(defun etaf-doc-markdown--try-symbol (text position end)
  "Return (NODE . NEXT) for `:sym[name]' Emacs symbol chip at POSITION."
  (when (and (<= (+ position 7) end)
             (eq (aref text position) ?:)
             (string-prefix-p "sym[" (substring text (1+ position) (min end (+ position 6)))))
    (let* ((start (+ position 5))
           (close (cl-position ?\] text :start start :end end)))
      (when (and close (> close start))
        (let ((name (string-trim (substring text start close))))
          (when (string-match-p "\\`[^[:space:]]+\\'" name)
            (cons (list :type 'symbol
                        :name name
                        :text (substring text position (1+ close)))
                  (1+ close))))))))

(defun etaf-doc-markdown--try-badge (text position end)
  "Return (NODE . NEXT) for a `:badge[TEXT]' badge at POSITION in TEXT.
A `{.variant}' after the closing bracket sets its semantic colour."
  (when (and (<= (+ position 7) end)
             (eq (aref text position) ?:)
             (string-match-p "\\`badge\\["
                             (substring text (1+ position) (+ position 7))))
    (let* ((start (+ position 7))
           (close (cl-position ?\] text :start start :end end)))
      (when (and close (> close start))
        (let* ((content (substring text start close))
               (variant (etaf-doc-markdown--inline-class text (1+ close) end)))
          (cons (list :type 'badge
                      :text (substring text position (cdr variant))
                      :content content
                      :variant (car variant))
                (cdr variant)))))))

(defun etaf-doc-markdown--word-char-p (char)
  "Return non-nil when CHAR belongs to a Latin word or number.
CJK text is not a word boundary for the ASCII tokens this decides about: a
Chinese sentence writes `表情：:tada:' and `:tada:很棒', so a Han character on
either side of a shortcode or abbreviation neither joins nor blocks it."
  (or (and (>= char ?0) (<= char ?9))
      (and (>= char ?A) (<= char ?Z))
      (and (>= char ?a) (<= char ?z))
      (eq char ?_)))

(defun etaf-doc-markdown--try-abbreviation (text position end)
  "Return (NODE . NEXT) for a defined abbreviation starting at POSITION.
The longest defined word wins, and only a whole word matches: `HTML' inside
`HTML5' is not the abbreviation."
  (let ((table etaf-doc-markdown--abbreviations)
        (best nil))
    (when (and (hash-table-p table)
               (> (hash-table-count table) 0)
               (or (= position 0)
                   (not (etaf-doc-markdown--word-char-p
                         (aref text (1- position))))))
      (maphash (lambda (word title)
                 (let ((stop (+ position (length word))))
                   (when (and (<= stop end)
                              (or (null best)
                                  (> (length word) (length (car best))))
                              (string-prefix-p word (substring text position stop))
                              (or (= stop end)
                                  (not (etaf-doc-markdown--word-char-p
                                        (aref text stop)))))
                     (setq best (cons word title)))))
               table))
    (when best
      (cons (list :type 'abbreviation :text (car best) :title (cdr best))
            (+ position (length (car best)))))))

(defconst etaf-doc-markdown--math-symbols
  '(("\\Alpha" . "Α") ("\\Beta" . "Β") ("\\Gamma" . "Γ") ("\\Delta" . "Δ")
    ("\\Theta" . "Θ") ("\\Lambda" . "Λ") ("\\Pi" . "Π") ("\\Sigma" . "Σ")
    ("\\Phi" . "Φ") ("\\Psi" . "Ψ") ("\\Omega" . "Ω")
    ("\\alpha" . "α") ("\\beta" . "β") ("\\gamma" . "γ") ("\\delta" . "δ")
    ("\\epsilon" . "ε") ("\\zeta" . "ζ") ("\\eta" . "η") ("\\theta" . "θ")
    ("\\iota" . "ι") ("\\kappa" . "κ") ("\\lambda" . "λ") ("\\mu" . "μ")
    ("\\nu" . "ν") ("\\xi" . "ξ") ("\\pi" . "π") ("\\rho" . "ρ")
    ("\\sigma" . "σ") ("\\tau" . "τ") ("\\phi" . "φ") ("\\chi" . "χ")
    ("\\psi" . "ψ") ("\\omega" . "ω")
    ("\\times" . "×") ("\\cdot" . "·") ("\\div" . "÷") ("\\pm" . "±")
    ("\\mp" . "∓") ("\\le" . "≤") ("\\leq" . "≤") ("\\ge" . "≥")
    ("\\geq" . "≥") ("\\ne" . "≠") ("\\neq" . "≠") ("\\approx" . "≈")
    ("\\equiv" . "≡") ("\\propto" . "∝") ("\\sim" . "∼")
    ("\\to" . "→") ("\\rightarrow" . "→") ("\\leftarrow" . "←")
    ("\\Rightarrow" . "⇒") ("\\Leftarrow" . "⇐") ("\\leftrightarrow" . "↔")
    ("\\infty" . "∞") ("\\partial" . "∂") ("\\nabla" . "∇")
    ("\\sum" . "∑") ("\\prod" . "∏") ("\\int" . "∫") ("\\oint" . "∮")
    ("\\in" . "∈") ("\\notin" . "∉") ("\\subset" . "⊂") ("\\supset" . "⊃")
    ("\\cup" . "∪") ("\\cap" . "∩") ("\\forall" . "∀") ("\\exists" . "∃")
    ("\\emptyset" . "∅") ("\\angle" . "∠") ("\\perp" . "⊥")
    ("\\parallel" . "∥") ("\\therefore" . "∴") ("\\ldots" . "…")
    ("\\cdots" . "⋯") ("\\degree" . "°") ("\\circ" . "∘")
    ("\\left" . "") ("\\right" . "") ("\\," . " ") ("\\;" . " ")
    ("\\!" . "") ("\\quad" . "  ") ("\\qquad" . "    "))
  "TeX command names a plain-text rendering spells as a symbol.
Ordered with the long names first, so `\\leftarrow' wins over `\\le'.")

(defun etaf-doc-markdown--math-replace-fraction (text)
  "Return TEXT with every `\\frac{A}{B}' written as `A/B'."
  (let ((previous nil))
    (while (not (equal previous text))
      (setq previous text)
      (setq text (replace-regexp-in-string
                  "\\\\frac ?{\\([^{}]*\\)} ?{\\([^{}]*\\)}"
                  "\\1/\\2" text)))
    text))

(defun etaf-doc-markdown-math-text (source)
  "Return SOURCE, a TeX formula, written as plain text.
This is a typographic approximation rather than a typesetter: command names
become their symbols, `\\frac{a}{b}' becomes `a/b', `\\sqrt{x}' becomes
`√(x)', and `^{}' and `_{}' become the Unicode letters of that position.
Anything it does not know keeps its own characters, so a formula can never
turn into a row of noise."
  (let ((text (or source "")))
    ;; Symbols first: a script body such as `\infty' then reaches the script
    ;; pass as its character, and an unknown command keeps its own name.
    (dolist (pair etaf-doc-markdown--math-symbols)
      ;; A literal replacement: `replace-regexp-in-string' with FIXEDCASE folds
      ;; case, which turned `\pi' into `\Pi'.
      (setq text (string-replace (car pair) (cdr pair) text)))
    ;; A root is written before the fraction holding it, so `\frac{\sqrt{x}}{2}'
    ;; is a fraction of plain characters when the fraction pass reads it.
    (setq text (replace-regexp-in-string
                "\\\\sqrt ?{\\([^{}]*\\)}" "√(\\1)" text))
    (setq text (etaf-doc-markdown--math-replace-fraction text))
    (dolist (pair '((superscript . "\\^\\(?:{\\([^{}]*\\)}\\|\\(.\\)\\)")
                    (subscript . "_\\(?:{\\([^{}]*\\)}\\|\\(.\\)\\)")))
      (let ((table (if (eq (car pair) 'superscript)
                       etaf-doc-markdown-superscript-table
                     etaf-doc-markdown-subscript-table))
            (regexp (cdr pair)))
        (setq text
              (replace-regexp-in-string
               regexp
               (lambda (match)
                 (save-match-data
                   (let* ((body (or (match-string 1 match) (match-string 2 match)))
                          (script (etaf-doc-markdown--script-text body table))
                          ;; A replacement string reads `\' as a back-reference,
                          ;; so an unknown command's own backslash is doubled.
                          (replacement (or script (format "(%s)" body))))
                     (string-replace "\\" "\\\\" replacement))))
               text))))
    (setq text (string-replace "\\{" "\0L" text))
    (setq text (string-replace "\\}" "\0R" text))
    (setq text (replace-regexp-in-string "[{}]" "" text))
    (setq text (string-replace "\0L" "{" text))
    (setq text (string-replace "\0R" "}" text))
    (string-trim (replace-regexp-in-string "[ \t]+" " " text))))

(provide 'etaf-doc-markdown-parse)
;;; etaf-doc-markdown-parse.el ends here
