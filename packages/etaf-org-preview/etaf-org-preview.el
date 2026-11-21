;;; etaf-org-preview.el --- Modern Org preview in ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.1
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0"))
;; Keywords: hypermedia, docs, org
;; URL: https://github.com/emacs-taf/etaf-org-preview

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-org-preview) after adding this
;; repository and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  The
;; previewer renders an Org document as a modern reading view: a centered
;; measure with a Markdown-style heading ladder, keyword chips, planning lines, tags,
;; nested and description lists, checkboxes, tables, source and example
;; blocks, quotes, callouts, images, footnotes, a table of contents, property
;; chips and entities.  Display formulas and `mermaid' source blocks are drawn
;; with mermaid-cli when it is installed.  Every section is rendered in place:
;; there is no headline fold control and no chevron; the top two levels keep the
;; Markdown rule under their row.
;; A publish keeps every unchanged block's instance, and a displayed preview
;; follows edits in its source buffer before they are saved.
;;
;; A session is the unit of state.  `etaf-org-preview-create' builds one from
;; a file or from text, `etaf-org-preview-open' displays it in its own buffer,
;; the navigation and display functions below drive it, and
;; `etaf-org-preview-state' reports it as plain data.  Every displayed value
;; is an ETAF reactive source, so a reload, a width change or a palette change
;; repaints only what it touches.
;;
;; The preview is read-only.  It never writes the document, never runs Babel,
;; never evaluates `#+TBLFM:' and never expands `#+INCLUDE'.  Parsing never
;; signals on malformed input: an unknown construct keeps its source text and
;; is counted in the `:degraded' state.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-org-preview-doctor ()
;; Return capability facts for reading Org documents.
;; The shape matches `etaf-install-doctor': `:required' and `:optional' lists
;; of (LABEL AVAILABLE REMEDY).  Reading text needs no external program; Org
;; itself is optional and only improves `id:' links and the keyword defaults.
;;
;; Function: etaf-org-preview-open (&optional source)
;;;###autoload (autoload 'etaf-org-preview-open "etaf-org-preview" nil t)
;; Mount an Org preview and return its buffer.
;; SOURCE is a file path, a session from `etaf-org-preview-create', or nil to
;; prompt for a file.  Interactively it defaults to the current buffer's Org
;; file and then to a file prompt; a file that already has a preview buffer is
;; selected instead of rendered twice.  The buffer is an ETAF application
;; whose root keys add outline navigation, link activation, reloading, theming
;; and closing; a window resize reflows through the framework's
;; viewport update, so the document is never rebuilt for a geometry change.
;; A preview opened from a file follows it: saving the source, or changing it
;; on disk, repaints the document after the write settles and keeps the reader
;; in the section it was reading.
;;
;; Function: etaf-org-preview-close ()
;;;###autoload (autoload 'etaf-org-preview-close "etaf-org-preview" nil t)
;; Unmount the current preview buffer and kill it.
;; Signals `user-error' when the current buffer is not a preview.
;;
;; Function: etaf-org-preview-view (&optional session)
;;;###autoload (autoload 'etaf-org-preview-view "etaf-org-preview" nil t)
;; Return the preview View for SESSION.
;; SESSION defaults to a new empty session; pass a session from
;; `etaf-org-preview-create' to mount a real document yourself with
;; `etaf-mount', for example inside a tab or a larger layout.
;;
;; Function: etaf-org-preview-create (&key file text title theme toc)
;; Return a new headless preview session.
;; Exactly one of FILE (an Org document read from disk) or TEXT (the document
;; itself) is required; a missing or unreadable FILE signals
;; `etaf-org-preview-error'.  TITLE overrides the document title.  THEME
;; selects a palette from `etaf-org-preview-themes' and defaults to
;; `etaf-org-preview-theme'.  TOC overrides the `#+OPTIONS: toc' depth.  The
;; session owns no buffer, so it is a complete headless preview for scripts
;; and tests.
;;
;; Function: etaf-org-preview-state (session)
;; Return SESSION's state as a detached plist snapshot.
;; Keys are `:file', `:title', `:author', `:date', `:keywords', `:filetags',
;; `:theme', `:background', `:width',
;; `:buffer', `:outline' (a list of (LEVEL TITLE ID TODO TAGS)), `:sections',
;; `:blocks', `:footnotes', `:degraded', `:counts' and `:error'.
;; `:background' is `palette' when the preview paints its palette's page
;; background and nil when it keeps the Emacs theme's background.  `:counts'
;; holds `:todo', `:done', `:deadline' and `:overdue' counts.  The snapshot
;; copies every value, so mutating it never changes the session.
;;
;; Function: etaf-org-preview-refresh (session)
;; Re-read and re-parse SESSION's document and return it.
;; A session created from text re-parses the original text; a file session
;; re-reads the file.  A read failure signals `etaf-org-preview-error' and
;; leaves the published document untouched.  Section ids and reading anchors
;; survive for every section that is still present.
;;
;; Function: etaf-org-preview-set-theme (session theme)
;; Show SESSION with palette THEME and return it.
;; THEME is `auto' or a key of `etaf-org-preview-themes' (`dark', `light' or
;; `sepia'); any other value signals `etaf-org-preview-error'.  `auto' returns
;; to the face-derived surfaces and paints no page background.
;;
;; Function: etaf-org-preview-cycle-theme (session)
;; Switch SESSION to the next fixed palette and return its name.
;;
;; Function: etaf-org-preview-outline (session)
;; Return SESSION's outline as a list of (LEVEL TITLE ID TODO TAGS), in
;; document order.
;;
;; Function: etaf-org-preview-locate (session index)
;; Move point to SESSION's outline heading INDEX and recenter.
;; INDEX is zero-based into `etaf-org-preview-outline'.  Return the buffer
;; position, or nil when the heading is not in the document.
;;
;; Function: etaf-org-preview-fold (session id state)
;; Set the fold state of SESSION's section ID to STATE and return SESSION.
;; STATE is `folded' (the headline only), `children' (child headlines, no
;; body) or `open' (everything).  Only that section's cell is written, so one
;; fold repaints one section.  An unknown id or state signals
;; `etaf-org-preview-error'.
;;
;; Function: etaf-org-preview-folded-p (session id)
;; Return non-nil when SESSION's section ID is folded to its headline.
;;
;; Function: etaf-org-preview-show-toc (session show)
;; Show or hide SESSION's table of contents and return SESSION.
;; SHOW non-nil displays the contents card at the document's `#+OPTIONS: toc'
;; depth; nil hides it.  `C-c t' toggles the same state in a preview buffer.
;;
;; Function: etaf-org-preview-show-hidden (session show)
;; Show or hide SESSION's hidden content and return SESSION.
;; Hidden content is comment lines, comment blocks, property drawers and the
;; metadata keywords the title block already summarizes.  `C-c v' toggles the
;; same state in a preview buffer.
;;
;; Function: etaf-org-preview-fold-all (session state)
;; Set every section of SESSION to fold STATE and return SESSION.
;; The writes share one batch, so the document repaints once.
;;
;; Function: etaf-org-preview-next-heading (&optional session)
;;;###autoload (autoload 'etaf-org-preview-next-heading "etaf-org-preview" nil t)
;; Move point to the next headline of the current preview.
;; SESSION defaults to the current preview buffer's session; a script driving
;; a headless mount passes its own session.  Reports "No further heading" at
;; the end and signals `user-error' when the buffer is not a preview.
;;
;; Function: etaf-org-preview-previous-heading (&optional session)
;;;###autoload (autoload 'etaf-org-preview-previous-heading "etaf-org-preview" nil t)
;; Move point to the previous headline of the current preview.
;; SESSION defaults to the current preview buffer's session.
;;
;; Function: etaf-org-preview-adjust-width (session delta)
;; Change SESSION's maximum reading measure by DELTA cells and return the new
;; maximum.  The result is clamped to `etaf-org-preview-width-min' and
;; `etaf-org-preview-width-max'; a narrower window fills the available
;; columns instead.
;;
;; Variable: etaf-org-preview-theme (default `auto')
;; Initial palette of `etaf-org-preview-create'.
;; `auto' derives the document colors from the active frame's own faces and
;; paints no page background; `dark', `light' and `sepia' select that fixed
;; palette, including its page background.  `etaf-org-preview-set-theme' and
;; `etaf-org-preview-cycle-theme' always select an explicit palette.
;;
;; Variable: etaf-org-preview-width-min (default 40)
;; Narrowest reading measure in character cells.
;;
;; Variable: etaf-org-preview-width-max (default 96)
;; Widest reading measure; a wider window keeps this measure and centers it.
;;
;; Variable: etaf-org-preview-image-max-height (default 24)
;; Tallest image, in text lines; a narrower reading measure also shrinks it.
;;
;; Variable: etaf-org-preview-typeset (default t)
;; Whether a display formula and a `mermaid' source block are drawn.
;; Drawing needs mermaid-cli (`mmdc'); without it, or with this nil, both keep
;; their source text.  A picture is cached by source, palette and body size,
;; and a page never waits for a program: a finished picture repaints its block.
;;
;; Error: etaf-org-preview-error
;; Invalid org preview session or document input
;; Catch this condition with condition-case; failed calls do not return a value.

;;; Code:

(defgroup etaf-org-preview nil
  "Org preview appearance and reading behavior."
  :group 'text)

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or (and load-file-name
                                           (not (string-suffix-p ".eln" load-file-name))
                                           (file-directory-p (expand-file-name "lisp" (file-name-directory load-file-name)))
                                           load-file-name)
                                      (bound-and-true-p byte-compile-current-file)
                                      (locate-library "etaf-org-preview")
                                      buffer-file-name)))))

(require 'etaf-ui)
(require 'etaf-org-preview-entities)
(require 'etaf-org-preview-parse)
(require 'etaf-org-preview-theme)
(require 'etaf-org-preview-views)
(require 'etaf-org-preview-model)
(require 'etaf-org-preview-typeset)
(require 'etaf-org-preview-app)

(defun etaf-org-preview-doctor ()
  "Return capability facts for reading Org documents.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Reading text needs no external program; Org is an
optional improvement, not a requirement."
  (list :required nil
        :optional
        (list (list "org" (featurep 'org)
                    "Optional: load Org to resolve id: links and honour org-todo-keywords.")
              (list "ffmpeg" (and (executable-find "ffmpeg") t)
                    "Optional: install ffmpeg to preview video files and terminal images."))))

(provide 'etaf-org-preview)
;;; etaf-org-preview.el ends here
