;;; etaf-ui-markdown-highlight.el --- Colour fenced code with Emacs' own faces  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A fenced code block names its language, and Emacs already knows how to read
;; that language: `font-lock' gives every token a face, whether it comes from a
;; major mode's keywords or from a tree-sitter grammar.  This module runs the
;; language's own mode over the block's text in a scratch buffer and turns the
;; resulting faces into runs, so the painter draws the same colours the source
;; buffer would show.
;;
;; Nothing here loads a third-party package: a language is highlighted only when
;; its mode is already available, and a block whose language (or size) has no
;; answer is painted as plain code.  That keeps a page of code blocks as cheap
;; as the text it holds, and a missing mode degrades the colour, never the page.
;;
;; Highlighting is a pure function of (LANGUAGE . TEXT), so its answer is cached
;; by that key: a repaint of the same block costs one hash lookup.

;;; Code:

(require 'cl-lib)

(defconst etaf-ui-markdown-highlight--max-lines 400
  "Lines a code block may have and still be highlighted.
A page repaints after every keystroke, so a pasted file-long block is left in
one colour instead of turning typing into a fontification run.")

(defconst etaf-ui-markdown-highlight--max-chars 20000
  "Characters a code block may have and still be highlighted.")

(defconst etaf-ui-markdown-highlight--cache-size 64
  "Code blocks kept in the highlight cache.")

(defvar etaf-ui-markdown-highlight--cache (make-hash-table :test #'equal)
  "Highlighted runs by (LANGUAGE . TEXT).")

(defconst etaf-ui-markdown-highlight-languages
  '(("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode)
    ("lisp" . emacs-lisp-mode) ("scheme" . scheme-mode) ("clojure" . clojure-mode)
    ("python" . python-mode) ("py" . python-mode)
    ("javascript" . js-mode) ("js" . js-mode) ("jsx" . js-jsx-mode)
    ("typescript" . typescript-mode) ("ts" . typescript-mode)
    ("json" . js-mode) ("jsonc" . js-mode)
    ("c" . c-mode) ("h" . c-mode) ("cpp" . c++-mode) ("c++" . c++-mode)
    ("objc" . objc-mode) ("java" . java-mode) ("csharp" . csharp-mode)
    ("rust" . rust-mode) ("go" . go-mode) ("ruby" . ruby-mode)
    ("php" . php-mode) ("perl" . perl-mode) ("lua" . lua-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("zsh" . sh-mode) ("shell" . sh-mode)
    ("fish" . fish-mode) ("powershell" . powershell-mode)
    ("sql" . sql-mode) ("yaml" . yaml-mode) ("yml" . yaml-mode)
    ("toml" . conf-toml-mode) ("ini" . conf-mode) ("conf" . conf-mode)
    ("xml" . nxml-mode) ("html" . html-mode) ("svg" . nxml-mode)
    ("css" . css-mode) ("scss" . scss-mode) ("less" . css-mode)
    ("markdown" . markdown-mode) ("md" . markdown-mode)
    ("org" . org-mode) ("diff" . diff-mode) ("patch" . diff-mode)
    ("make" . makefile-mode) ("makefile" . makefile-mode)
    ("dockerfile" . dockerfile-mode) ("cmake" . cmake-mode)
    ("latex" . latex-mode) ("tex" . latex-mode)
    ("haskell" . haskell-mode) ("kotlin" . kotlin-mode) ("swift" . swift-mode)
    ("scala" . scala-mode) ("erlang" . erlang-mode) ("elixir" . elixir-mode)
    ("ocaml" . tuareg-mode) ("vim" . vimrc-mode))
  "Fence language names and the major mode that reads each one.
Only a mode whose library is already loaded or loadable is used; the entry
keeps the name a document writes, which is not always the mode's name.")

(defun etaf-ui-markdown-highlight--mode (language)
  "Return the major mode that reads LANGUAGE, or nil when none is available.
Both the symbol and its file are tried, so a mode that is installed but not
loaded is accepted, while a language with no mode costs one failed `require'."
  (when-let* ((language (and (stringp language) (downcase language)))
              (entry (assoc language etaf-ui-markdown-highlight-languages))
              (mode (cdr entry)))
    ;; The mapping names the reader mode; its library is usually the mode's own
    ;; name without the suffix, and often the whole name.
    (let ((library (intern (replace-regexp-in-string "-mode\\'" "" (symbol-name mode)))))
      (when (or (fboundp mode)
                (require mode nil t)
                (require library nil t))
        (and (fboundp mode) mode)))))

(defconst etaf-ui-markdown-highlight-roles
  '((font-lock-keyword-face . keyword)
    (font-lock-builtin-face . builtin)
    (font-lock-string-face . string)
    (font-lock-doc-face . string)
    (font-lock-comment-face . comment)
    (font-lock-comment-delimiter-face . comment)
    (font-lock-function-name-face . function)
    (font-lock-variable-name-face . variable)
    (font-lock-type-face . type)
    (font-lock-constant-face . constant)
    (font-lock-preprocessor-face . preprocessor)
    (font-lock-warning-face . warning))
  "The token role each font-lock face paints.
The highlighter reads the source of a fence with the language's own mode, so
the tokens are the faces font-lock already found; a role names what a token is,
which is what lets the page colour it from its own palette instead of copying
whatever the reader's theme happened to choose.")

(defconst etaf-ui-markdown-highlight-palettes
  '((light . ((keyword . "#cf222e") (builtin . "#0550ae") (string . "#0a3069")
              (comment . "#6e7781") (function . "#8250df") (variable . "#953800")
              (type . "#953800") (constant . "#0550ae") (preprocessor . "#953800")
              (warning . "#9a6700")))
    (dark . ((keyword . "#ff7b72") (builtin . "#79c0ff") (string . "#a5d6ff")
             (comment . "#8b949e") (function . "#d2a8ff") (variable . "#ffa657")
             (type . "#ffa657") (constant . "#79c0ff") (preprocessor . "#ffa657")
             (warning . "#e3b341"))))
  "Syntax colours a code block takes on a light and on a dark page.
They are the pairs a reader of GitHub's code view already knows, so a block sits
on the page the way a block sits in a browser: saturated enough to read on a
white surface and light enough on a dark one.  A face with no role keeps its
own colour, adjusted to the page's contrast.")

(defun etaf-ui-markdown-highlight-color (props dark)
  "Return the colour the run PROPS takes on a page of DARK appearance, or nil.
PROPS comes from `etaf-ui-markdown-highlight--face-props'; a run whose face has
no role answers nil, and its caller decides what to paint."
  (when-let* ((role (plist-get props :role))
              (palette (alist-get (if dark 'dark 'light)
                                  etaf-ui-markdown-highlight-palettes)))
    (alist-get role palette)))

(defun etaf-ui-markdown-highlight--face-props (face)
  "Return the drawing props of FACE as an Ebox style plist.
Only what a text run can express is kept: colour, weight, slant, underline and
strike-through.  An inherited attribute is resolved through the face itself, so
a mode that only sets a foreground still renders."
  (let ((props nil))
    (when (and face (facep face))
      ;; The face's own name is the only handle on what the token is; a mode
      ;; that inherits from a font-lock face is resolved to the role too.
      (let ((role (cdr (assq (or (and (symbolp face) face) (car (ensure-list face)))
                             etaf-ui-markdown-highlight-roles))))
        (when role (setq props (plist-put props :role role))))
      ;; INHERIT is t, not nil: a mode's face usually sets one attribute and
      ;; inherits the rest, and only an inherited value is the colour the
      ;; source buffer actually shows.
      (let ((foreground (face-attribute face :foreground nil t)))
        (when (and (stringp foreground)
                   (not (member foreground '("unspecified" "default"))))
          (setq props (plist-put props :color foreground))))
      (let ((weight (face-attribute face :weight nil t)))
        (when (memq weight '(bold semi-bold extra-bold ultra-bold light))
          (setq props (plist-put props :font-weight weight))))
      (let ((slant (face-attribute face :slant nil t)))
        (when (memq slant '(italic oblique reverse-oblique reverse-italic))
          (setq props (plist-put props :font-style slant))))
      (let ((underline (face-attribute face :underline nil t)))
        (when (and underline (not (memq underline '(unspecified nil))))
          (setq props (plist-put props :text-decoration-line '(underline)))))
      (let ((strike (face-attribute face :strike-through nil t)))
        (when (and strike (not (memq strike '(unspecified nil))))
          (setq props (plist-put props :text-decoration-line '(line-through))))))
    props))

(defun etaf-ui-markdown-highlight--runs (text)
  "Return TEXT as runs of `(:text STRING :props PLIST)' by its faces.
The runs follow the face changes in order, so a stretch of one token stays one
run: a page of code is a handful of text nodes, not one per character."
  (let ((runs nil)
        (index 0)
        (end (length text)))
    (while (< index end)
      (let* ((face (get-text-property index 'face text))
             (props (etaf-ui-markdown-highlight--face-props face))
             (next (or (next-single-property-change index 'face text end) end)))
        (when (> next index)
          (let ((run (list :text (substring-no-properties text index next)
                           :props props)))
            ;; A run that draws like the one before it joins it, so the page
            ;; does not pay for a new text node every token boundary.
            (if (and runs (equal (plist-get run :props) (plist-get (car runs) :props)))
                (setcar runs (list :text (concat (plist-get (car runs) :text)
                                                 (plist-get run :text))
                                   :props (plist-get run :props)))
              (push run runs))))
        (setq index next)))
    (nreverse runs)))

(defun etaf-ui-markdown-highlight-code (language text)
  "Return runs colouring TEXT as LANGUAGE, or nil when it cannot be coloured.
The answer is a list of `(:text STRING :props PLIST)' covering TEXT in order,
with PLIST an Ebox style plist; nil means paint the block in one colour.  This
runs the language's own major mode over the text, so keywords, strings,
comments and numbers come out as the source buffer shows them, and the result
costs one cache lookup on the next repaint."
  (when (and (stringp text)
             (stringp language)
             (<= (length text) etaf-ui-markdown-highlight--max-chars)
             (<= (cl-count ?\n text) etaf-ui-markdown-highlight--max-lines))
    (let* ((key (cons (downcase language) text))
           (cached (gethash key etaf-ui-markdown-highlight--cache 'miss)))
      (if (not (eq cached 'miss))
          cached
        (let ((runs (etaf-ui-markdown-highlight--compute language text)))
          (when (> (hash-table-count etaf-ui-markdown-highlight--cache)
                   etaf-ui-markdown-highlight--cache-size)
            (clrhash etaf-ui-markdown-highlight--cache))
          (puthash key runs etaf-ui-markdown-highlight--cache)
          runs)))))

(defun etaf-ui-markdown-highlight--compute (language text)
  "Return the highlighted runs of TEXT as LANGUAGE, or nil."
  (when-let* ((mode (etaf-ui-markdown-highlight--mode language)))
    ;; A mode may announce what it set up, as `sh-mode' does when it picks the
    ;; shell's indentation; the reader asked for a page, not for that log.
    (let ((inhibit-message t)
          (message-log-max nil))
    (with-temp-buffer
      (insert text)
      ;; `delay-mode-hooks' keeps the mode from running a page's mode hooks in
      ;; a throwaway buffer; only the syntax rules matter here.
      (condition-case nil
          (delay-mode-hooks (funcall mode))
        (error nil))
      (when (eq major-mode mode)
        (setq-local font-lock-verbose nil)
        (condition-case nil
            (progn (font-lock-ensure) (etaf-ui-markdown-highlight--runs (buffer-string)))
          (error nil)))))))

(provide 'etaf-ui-markdown-highlight)

;;; etaf-ui-markdown-highlight.el ends here
