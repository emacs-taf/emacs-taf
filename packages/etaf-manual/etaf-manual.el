;;; etaf-manual.el --- The ETAF Reference Manual -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.11
;; Package-Requires: ((emacs "29.1") (etaf "0.2.2") (etaf-ui "0.1.3"))
;; URL: https://github.com/emacs-taf/etaf-manual

;;; Commentary:

;; The ETAF Reference Manual documents the core ETAF packages (ecss, ekp,
;; ebox, etaf, etaf-ui and etaf-db) in English and Simplified Chinese.  The
;; chapters live below book/ as Markdown; this package reads them as data so
;; Emacs tools and the site build share one source.
;;
;; Public API
;;
;; Load this package with (require 'etaf-manual) after adding the repository
;; root to load-path.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen. Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; docs/manual.md describes
;; the book format and how to build and check the manual.
;;
;; Variable: etaf-manual-language
;; Language code of the manual read by default: "en" or "zh-CN".
;;
;; Function: etaf-manual-book (&optional language)
;;;###autoload (autoload 'etaf-manual-book "etaf-manual" nil nil)
;; Return the manual in LANGUAGE (default `etaf-manual-language') as a plist.
;;
;; The plist has :language, :title, :parts and :chapters.  Each part is
;; (:id ID :number ROMAN :title STRING :chapters IDS).  :chapters lists every
;; chapter, appendix and index in reading order; each is a plist with :id
;; (a symbol), :kind (`chapter', `appendix' or `index'), :number (an integer
;; for chapters, a letter string for appendices, nil for indices), :title and
;; :definitions, :nodes, :examples and :index lists.  Written chapters also
;; have :part and :file; generated appendices and indices have :generate
;; naming their generator and :content with their Markdown text, parsed with
;; the same rules as a written chapter.  A node is (:level 2-or-3 :title
;; STRING :anchor STRING :line N).  A definition is (:kind KIND :name SYMBOL
;; :signature STRING :anchor STRING :line N :chapter ID :body STRING-OR-NIL),
;; where :body is the entry's Markdown text; consecutive entry headings share
;; one body.  An example is (:id STRING :chapter ID :line N :code STRING); a
;; figure is (:id STRING :chapter ID :line N :caption STRING-OR-NIL :code
;; STRING) and the reader renders its last form inline as a static
;; illustration.
;; An index term is (:term STRING :line N :anchor STRING).  The result is
;; cached until a source file changes; the sources are checked again at
;; most once per input event and second, so the lookups of one command
;; share one check.  Treat the result as read-only.  Signals
;; `etaf-manual-error' when book/book.json or a chapter is missing or
;; malformed, or LANGUAGE is not provided.
;;
;; Function: etaf-manual-definition (name &optional kind language)
;;;###autoload (autoload 'etaf-manual-definition "etaf-manual" nil nil)
;; Return the definition entry of symbol NAME in LANGUAGE, or nil.
;; KIND restricts the match to one definition kind: `function', `macro',
;; `component' or `style' when NAME has several entries; otherwise the first
;; entry in reading order is returned.  The result has the definition shape
;; described for `etaf-manual-book'.
;;
;; Function: etaf-manual-example-view (example)
;;;###autoload (autoload 'etaf-manual-example-view "etaf-manual" nil nil)
;; Evaluate runnable EXAMPLE from `etaf-manual-book' and return its View.
;;
;; The code is read and evaluated form by form with lexical binding, with
;; etaf and etaf-ui loaded; the value of the last form is returned and must
;; be an ETAF View suitable for `etaf-mount'.  Component definitions in the
;; example may be evaluated again, so an example can be rerun after its
;; previous Runtime was unmounted.  Read and evaluation failures signal
;; `etaf-manual-error' with the example identifier and the original error.
;;
;; Function: etaf-manual-open (&optional chapter)
;;;###autoload (autoload 'etaf-manual-open "etaf-manual" nil t)
;; Open the manual reader in its own buffer and return that buffer.
;; CHAPTER is the chapter identifier (a symbol) or its name as a string, and
;; defaults to the remembered reading position when there is one and to the
;; first chapter otherwise.  An unknown chapter signals
;; `etaf-manual-error' instead of opening an empty page.  The buffer gets `etaf-manual-reader-mode': `n' and `p' move
;; between sections, `u' goes up one level, `l' and `r' walk the reading
;; history, `[' and `]' change chapter, `/` searches the whole book and
;; `M-n'/`M-p' walk the matches, `e' edits the example at the reading
;; position and `C-c C-c' reruns it, `w' copies the code at the reading
;; position, `g' switches between Chinese and
;; English, `i' opens a jump completion listing chapters, sections,
;; definition entries and index terms, `t' cycles the palette mode (`亮',
;; `暗', `随') and `q' closes the reader.  The mounted page declares these keys as Host `:keys', so they
;; also work when the reader View is embedded and `?' opens the read-only
;; ETAF key help listing them.  The navigation column and, on wide frames,
;; the on-this-page column are draggable dividers: dragging one resizes
;; that column, and a focused divider steps one column per Left or Right
;; press; `etaf-manual-reader-set-sidebar-width' and
;; `-set-outline-width' set the widths programmatically.  Tabs, arrows, RET, M-g and Escape keep the
;; framework behaviours, so controls inside runnable examples stay focusable
;; and operable; activating the run control of an example renders the real
;; ETAF View in place.  A code span in the article whose text names a
;; definition entry is itself a link: RET or a click over it opens that
;; entry.
;;
;; Function: etaf-manual-close ()
;;;###autoload (autoload 'etaf-manual-close "etaf-manual" nil t)
;; Unmount and kill the manual reader buffer shown in the current buffer.
;;
;; Function: etaf-manual-lookup (symbol &optional kind)
;;;###autoload (autoload 'etaf-manual-lookup "etaf-manual" nil t)
;; Open the manual at the definition entry of SYMBOL.
;; KIND restricts the entry to one definition kind; without it the first
;; entry in reading order is used.  Interactively the symbol at point is
;; used when it has a definition entry; otherwise the command reads a name
;; with completion.  An open reader buffer is reused instead of opening a
;; second one.  A symbol without an entry signals a `user-error'.
;;
;; Function: etaf-manual-reader-create (&key language theme chapter)
;; Create a headless manual reader session and return it.
;; LANGUAGE defaults to `etaf-manual-language', THEME to `auto' (follow the
;; appearance the host provides, and the Emacs theme in a standalone reader;
;; `light' and `dark' pin the palette), and CHAPTER to the manual's first
;; chapter.  CHAPTER is
;; the chapter identifier (a symbol) or its name as a string; an unknown
;; chapter signals `etaf-manual-error' here, before any buffer exists.  The
;; session owns no buffer, so scripts and tests drive the same model the
;; mounted application uses.  The navigation and display functions below take such a
;; session as their first argument.
;;
;; Function: etaf-manual-reader-session (&optional buffer)
;;;###autoload (autoload 'etaf-manual-reader-session "etaf-manual" nil nil)
;; Return the reader session mounted in BUFFER-OR-NAME, or nil.
;; BUFFER-OR-NAME defaults to the current buffer.  `etaf-manual-open', a
;; floating panel and a desktop host all mount `etaf-manual-reader-view', and
;; each records its session in the buffer it renders into, so a command or a
;; host can find the reader it acts on; a buffer without a mounted reader
;; returns nil.
;;
;; Function: etaf-manual-reader-state (session)
;; Return a detached snapshot of SESSION's reading state.
;; Keys are `:language', `:theme', `:chapter', `:chapter-title', `:part',
;; `:node' (the zero-based section index, or nil at the chapter top),
;; `:node-title', `:nodes' (section titles in order), `:position' (zero-based
;; chapter index), `:chapters' (chapter count), `:can-back', `:can-forward',
;; `:sidebar-width' and `:outline-width' (the effective side-column widths
;; in character cells).  The snapshot copies every value, so mutating it
;; never changes the session.
;;
;; Function: etaf-manual-reader-toc (session)
;; Return SESSION's navigation outline as a list of part plists.
;; Each part has `:number', `:title' and `:chapters'; each chapter has `:id',
;; `:number', `:title', `:kind', `:current' and, for the current chapter,
;; `:nodes' with `:title', `:level', `:anchor', `:index' and `:current'.
;; The shape is data only; the mounted reader renders it as the navigation
;; column.
;;
;; Function: etaf-manual-reader-goto (session chapter &optional node)
;; Move SESSION to CHAPTER and NODE, recording the previous position.
;; CHAPTER is the chapter identifier (a symbol) or its name as a string; an
;; unknown chapter signals `etaf-manual-error' and leaves the reading
;; position unchanged.  NODE is a zero-based index into the chapter's section
;; nodes, or nil for the chapter top.
;;
;; Function: etaf-manual-reader-next (session)
;; Move SESSION to the next section, rolling into the next chapter.
;;
;; Function: etaf-manual-reader-previous (session)
;; Move SESSION to the previous section, rolling into the previous chapter.
;;
;; Function: etaf-manual-reader-up (session)
;; Move SESSION one level up: a level-3 section to its level-2 parent, and a
;; level-2 section to the chapter top.
;;
;; Function: etaf-manual-reader-back (session)
;; Return SESSION to the previous reading position.
;;
;; Function: etaf-manual-reader-forward (session)
;; Move SESSION to the next reading position.
;;
;; Function: etaf-manual-reader-jump-targets (session)
;; Return SESSION's jump targets as a list of (LABEL . TARGET) pairs.
;; LABEL names the target for completion; TARGET is a plist with `:chapter'
;; and one of `:node' (a zero-based section index), `:definition' (a symbol)
;; or `:anchor' (a section anchor), or only `:chapter' for the chapter
;; itself.  Chapters, their sections, definition entries and index terms all
;; appear in reading order; the mounted reader opens them from `i'.
;;
;; Function: etaf-manual-reader-search (session query)
;; Search SESSION's book for QUERY and move to the first matching section.
;; Matching ignores case and starts after the reading position, wrapping to
;; the first result when the search reaches the end.  Store the result list
;; for `etaf-manual-reader-search-next' and `-search-previous'.  Return the
;; number of matching sections, or 0 when nothing matches; an empty QUERY
;; signals a `user-error'.
;;
;; Function: etaf-manual-reader-search-next (session)
;; Move SESSION to its next search result and return that match; signal a
;; `user-error' when no search is active or the last result is current.
;;
;; Function: etaf-manual-reader-search-previous (session)
;; Move SESSION to its previous search result and return that match; signal
;; a `user-error' when no search is active or the first result is current.
;;
;; Function: etaf-manual-reader-search-match (session)
;; Return SESSION's current search result as a plist, or nil.
;; The result has `:chapter', `:node' and `:definition', the symbol of the
;; definition entry the match belongs to, or nil.
;;
;; Function: etaf-manual-reader-remember (session)
;; Remember SESSION's reading position for `etaf-manual-reader-restore'.
;; Write language, palette, chapter and section to
;; `etaf-manual-reader-position-file' and return non-nil when the write
;; succeeded; write errors are ignored.  A displayed session also saves by
;; itself a moment after each navigation.
;;
;; Function: etaf-manual-reader-restore (session)
;; Apply the remembered reading position to SESSION and return it.
;; Reads `etaf-manual-reader-position-file'; a missing, unreadable,
;; malformed or stale entry leaves the corresponding setting untouched.
;; Return non-nil when a chapter was applied.
;;
;; Variable: etaf-manual-reader-position-file
;; File remembering the reader's last reading position.
;; The file stores the language, palette, chapter and section as a plist; a
;; missing, unreadable or malformed file is ignored.  nil uses
;; `etaf-manual-position.eld' under `user-emacs-directory'.
;;
;; Function: etaf-manual-reader-set-sidebar-width (session columns)
;; Set SESSION's navigation column width to COLUMNS character cells.
;; COLUMNS is clamped to the supported range; nil restores the default.
;; In the mounted reader the column's divider is draggable and steps one
;; column per Left or Right press when focused.
;;
;; Function: etaf-manual-reader-set-outline-width (session columns)
;; Set SESSION's on-this-page column width to COLUMNS character cells.
;; COLUMNS is clamped to the supported range; nil restores the width that
;; hugs the chapter's section titles.
;;
;; Function: etaf-manual-reader-set-language (session language)
;; Read SESSION in LANGUAGE, keeping the chapter and the nearest section.
;;
;; Function: etaf-manual-reader-toggle-theme (session)
;; Switch SESSION between the light and dark palettes; return the new one.
;; An `auto' reader pins the opposite of the appearance it resolves to, and
;; the title bar of a panel framing the reader offers `auto' again after that.
;;
;; Function: etaf-manual-reader-view (session)
;; Return the application View of SESSION.
;; Use it to embed the reader in your own `etaf-mount' call; prefer
;; `etaf-manual-open' to also get a buffer, a keymap and window metrics.
;;
;; Error: etaf-manual-error
;; ETAF manual error
;; Signaled for malformed book sources and failing runnable examples.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-manual-book)

(defgroup etaf-manual nil
  "The ETAF Reference Manual."
  :group 'etaf
  :prefix "etaf-manual-")

(defcustom etaf-manual-language "en"
  "Language code of the manual read by default."
  :type '(choice (const :tag "English" "en")
                 (const :tag "Simplified Chinese" "zh-CN"))
  :group 'etaf-manual)

(defun etaf-manual-book (&optional language)
  "Return the manual in LANGUAGE as a plist; see the package Commentary."
  (etaf-manual--read-book (expand-file-name "book" etaf-manual--root)
                          (or language etaf-manual-language)))

(defun etaf-manual-definition (name &optional kind language)
  "Return the definition of NAME, optionally of KIND, in LANGUAGE."
  (cl-loop for chapter in (plist-get (etaf-manual-book language) :chapters)
           thereis (cl-loop for definition in (plist-get chapter :definitions)
                            when (and (eq (plist-get definition :name) name)
                                      (or (null kind)
                                          (eq (plist-get definition :kind) kind)))
                            return definition)))

(defun etaf-manual-example-view (example)
  "Evaluate runnable EXAMPLE and return the View of its last form."
  (let ((id (plist-get example :id))
        (code (plist-get example :code)))
    (condition-case error
        (etaf-component-redefine-run
         (lambda ()
           (let ((position 0) (value nil) form)
             (while (setq form (condition-case nil
                                   (let ((read (read-from-string code position)))
                                     (setq position (cdr read))
                                     (list (car read)))
                                 (end-of-file nil)))
               (setq value (eval (car form) t)))
             value)))
      (error (signal 'etaf-manual-error (list "Runnable example failed" id error))))))

(require 'etaf-manual-reader)

(provide 'etaf-manual)
;;; etaf-manual.el ends here
