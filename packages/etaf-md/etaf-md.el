;;; etaf-md.el --- Modern Markdown preview in ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0"))
;; Keywords: hypermedia, docs
;; URL: https://github.com/emacs-taf/etaf-md

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-md) after adding this
;; repository and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  The
;; previewer renders a local Markdown document as a modern reading view: a
;; centered measure with a typographic heading scale, fenced code blocks with
;; language tags, blockquotes, nested lists, task list markers, pipe tables,
;; thematic breaks, footnotes, clickable links and inline images, plus local
;; image and video cards whose poster frame is prepared through ETAF's image
;; Host; activating a video card plays it inline through ETAF's video
;; Component.  Front matter is stripped into document metadata.  The whole
;; document publishes into one buffer with native Emacs scrolling, isearch
;; and window splitting, so no pane owns a private scrolling model.
;;
;; A document may also write containers: a `:::name {attrs}' block around
;; markdown, with `@tab' markers inside the containers that own them.  The
;; shipped vocabulary turns a document into a documentation page — callouts,
;; cards, columns, steps, a timeline, a file tree, tabs, a table with
;; highlighted rows, a window frame, a QR code — and every type is a
;; definition of attributes, accepted children and a paint, so a reader may
;; add a type of their own or replace a shipped paint with the functions
;; below.  docs/extensions.md is the contract for that vocabulary.
;;
;; A session is the unit of state.  `etaf-md-create' builds one from a
;; file or from text, `etaf-md-open' displays it in its own buffer,
;; the navigation and display functions below drive it, and
;; `etaf-md-state' reports it as plain data.  Every displayed value is
;; an ETAF reactive source, so a reload, a width change or a palette change
;; repaints the mounted preview without a refresh call.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-md-define-node (type &rest args)
;;   Register a node type, or extend or replace one; see article 10.
;;   ARGS: :name, :summary, :attrs, :derived, :accepts, :child-syntax,
;;   :contract, :view, :extends, :replace.  A second definition of a type must
;;   say :extends or :replace, and a declared attribute name is never
;;   redeclared.  :child-syntax is `blocks' (default) or `markers'.
;;
;; Function: etaf-md-undefine-node (type)
;;   Remove a user definition; a shipped type returns to its shipped one.
;;
;; Function: etaf-md-set-attr (selector rules)
;;   Install RULES for SELECTOR, or remove them with nil.  RULES is a list of
;;   (KEY VALUE); a later rule for the same selector replaces the earlier one.
;;
;; Function: etaf-md-set-view (type function &rest args)
;;   Give TYPE the paint FUNCTION.  ARGS: :extends, :replace, :style-keys.
;;   A nil FUNCTION puts the previous paint back.
;;
;; Function: etaf-md-describe-nodes (&optional type)
;;   Return the registry as text, one type per stanza; TYPE limits it to one.
;;
;; Function: etaf-md-derived-attributes (type)
;;   Return TYPE's derived attribute names in declaration order.
;;
;; Variable: etaf-md-node-definitions
;;   Registry from a type symbol to its definition plist; the single source of
;;   every attribute declaration.
;;
;; Variable: etaf-md-node-directory
;;   Directory whose `.el' files hold user definitions, one per file.
;;
;; Variable: etaf-md-styles
;;   Ordered style rules, oldest first, each (SELECTOR KEY VALUE...).
;;
;; Variable: etaf-md-contract
;;   Version of the document-side attribute table this build accepts.
;;
;; Function: etaf-md-attr (env key &optional node)
;;   KEY's final value on NODE, or on ENV's node: a rule beats the document,
;;   the document beats the declaration's default, a derived value has none but
;;   itself.
;;
;; Function: etaf-md-type (env)
;;   The type name of ENV's node.
;;
;; Function: etaf-md-children (env &optional node)
;;   NODE's children, or ENV's node's children, in document order.
;;
;; Function: etaf-md-content (env)
;;   ENV's children painted as one view; the whole-block case.
;;
;; Function: etaf-md-render (env nodes)
;;   NODES painted as one view; the one-item-at-a-time case.
;;
;; Function: etaf-md-surface (env word)
;;   Surface WORD as a colour for ENV, or nil for none.
;;
;; Function: etaf-md-accent (env word)
;;   Accent WORD as a colour for ENV.
;;
;; Function: etaf-md-default-view (env)
;;   ENV's node painted with the definition's previous view.
;;
;; Function: etaf-md-follow-link (env target)
;;   Open TARGET through ENV's session; non-nil when it was followed.
;;
;; Function: etaf-md-block-state (env key &optional default)
;;   KEY's state for ENV's block, or DEFAULT.
;;
;; Function: etaf-md-set-block-state (env key value)
;;   Store VALUE under KEY for ENV's block and return VALUE.
;;
;; Function: etaf-md-available-width (env)
;;   The columns ENV's block may occupy.
;;
;; Function: etaf-md-doctor ()
;; Return capability facts for reading a document.  The shape matches
;; `etaf-install-doctor'; every program is optional, and a missing one leaves
;; the blocks that need it as their source text.
;; Function: etaf-md-preview (&optional source)
;;;###autoload (autoload 'etaf-md-preview "etaf-md" nil t)
;; Open SOURCE's preview in a window beside the current one.
;; SOURCE is a file path; interactively it is the current buffer's markdown
;; file, and a buffer that visits no markdown file prompts for one.  The source
;; buffer keeps the selected window and the point, so an edit followed by a
;; save reaches the preview without leaving the text.  An existing preview of
;; the same file is shown instead of rendered twice, and
;; `etaf-md-close' gives the window back.
;;
;; Function: etaf-md-open (&optional source)
;;;###autoload (autoload 'etaf-md-open "etaf-md" nil t)
;; Mount a markdown preview and return its buffer.
;; SOURCE is a file path, a session from `etaf-md-create', or nil to
;; prompt for a file.  Interactively it defaults to the current buffer's
;; markdown file and then to a file prompt; a file that already has a preview
;; buffer is selected instead of rendered twice.  Opening a session mounts
;; that session, so callers can render a document they built themselves.  The
;; buffer is an ETAF application (`etaf-app-open') whose root keys add outline
;; navigation, reloading, theming and closing; the reading measure starts from
;; the showing window and later resizes reflow through the framework's viewport
;; update, so the document is never rebuilt for a window geometry change.
;; A preview opened from a file follows it: an unsaved edit in its buffer
;; repaints the document on the next frame, so the render keeps up with the
;; typing instead of waiting for the keys to stop, and saving the source or
;; changing it on disk from another program repaints it the same way.  Each
;; top-level block is its own Component, published under a key that names the
;; block's type and source, so a repaint renders the block that changed and
;; leaves the others' output and instances alone.  The page is read-only: the
;; markdown is edited in its own buffer with the reader's own commands.  Closing
;; the buffer releases the session's Runtime, its watch, the buffer's change
;; hook, so reopening the same file renders a fresh preview.
;;
;; Function: etaf-md-close ()
;;;###autoload (autoload 'etaf-md-close "etaf-md" nil t)
;; Unmount the current preview buffer, kill it and free its window.
;; The current window goes away when the frame has another window, so a preview
;; opened beside its source closes back onto the source.  Signals `user-error'
;; when the current buffer is not a preview.
;;
;; Function: etaf-md-view (&optional session)
;;;###autoload (autoload 'etaf-md-view "etaf-md" nil t)
;; Return the preview View for SESSION.
;; SESSION defaults to a new empty session; pass a session from
;; `etaf-md-create' to mount a real document yourself with
;; `etaf-mount', for example inside a tab or a larger layout.
;;
;; Function: etaf-md-create (&key file text title theme flavor)
;; Return a new headless preview session.
;; Exactly one of FILE (a markdown document read from disk) or TEXT (the
;; document itself) is required; a missing or unreadable FILE signals
;; `etaf-md-error'.  TITLE overrides the document title and THEME
;; selects a palette from `etaf-md-themes', defaulting to the frame's
;; background mode.  FLAVOR selects the markdown dialect: `gfm' (the default)
;; enables the GitHub extensions (tables, task lists, strikethrough, autolinks,
;; footnotes and front matter), `commonmark' parses the core specification
;; only, and a feature plist toggles individual extensions.  The session owns
;; no buffer, so it is a complete headless preview for scripts and tests.
;;
;; Function: etaf-md-state (session)
;; Return SESSION's state as a detached plist snapshot.
;; Keys are `:file', `:title', `:dir', `:theme', `:flavor', `:background',
;; `:width', `:outline' (a list of (LEVEL TEXT ID)), `:error', `:blocks'
;; \(top-level block count) and `:footnotes' (definition labels in reference
;; order).  `:background' is `palette' when the preview paints its palette's
;; page background and nil when it keeps the Emacs theme's background.  The
;; snapshot copies every value, so mutating it never changes the session; use
;; it to render outside ETAF or to assert behavior in tests.
;;
;; Function: etaf-md-refresh (session)
;; Re-read and re-parse SESSION's document and return it.
;; A session created from text re-parses the original text; a file session
;; re-reads the file.  A read failure signals `etaf-md-error' and
;; leaves the published document untouched.
;;
;; Function: etaf-md-set-theme (session theme)
;; Show SESSION with the palette THEME and return it.
;; THEME is `auto' or a key of `etaf-md-themes' (`dark', `light' or
;; `sepia'); any other value signals `etaf-md-error'.  `auto' returns
;; to the face-derived surfaces and paints no page background.
;;
;; Function: etaf-md-cycle-theme (session)
;; Switch SESSION to the next palette and return its name.
;;
;; Function: etaf-md-outline (session)
;; Return SESSION's outline as a list of (LEVEL TEXT ID), in document order.
;;
;; Function: etaf-md-goto-heading ()
;;;###autoload (autoload 'etaf-md-goto-heading "etaf-md" nil t)
;; Choose an outline heading of the current preview and move to it.
;; The candidate list is the document's own outline, indented by level and
;; prefixed with its hash marks.  Signals `user-error' when the current buffer
;; is not a preview.
;;
;; Function: etaf-md-next-heading ()
;;;###autoload (autoload 'etaf-md-next-heading "etaf-md" nil t)
;; Move point to the next outline heading of the current preview.
;; Reports "No further heading" when the document has no later heading and
;; signals `user-error' when the current buffer is not a preview.
;;
;; Function: etaf-md-previous-heading ()
;;;###autoload (autoload 'etaf-md-previous-heading "etaf-md" nil t)
;; Move point to the previous outline heading of the current preview.
;; Reports "No earlier heading" at the first heading and signals
;; `user-error' when the current buffer is not a preview.
;;
;; Function: etaf-md-follow-scroll (&optional arg)
;;;###autoload (autoload 'etaf-md-follow-scroll "etaf-md" nil t)
;; Toggle scrolling the preview along with its source buffer and return the new
;; state.  While it is on, a command that scrolls the source window moves the
;; preview so the block at the top of that window becomes its first row: a
;; reader keeping the two side by side sees the same place in each.  Only the
;; source's scrolling follows, so scrolling the preview itself stays free, and
;; typing follows as far as the source window scrolls.
;;
;; Run it from the markdown buffer or from its preview.  ARG sets the state
;; instead of toggling: a positive prefix argument turns it on and anything
;; else turns it off.  A buffer that no preview shows signals `user-error'.
;;
;; Function: etaf-md-reload ()
;;;###autoload (autoload 'etaf-md-reload "etaf-md" nil t)
;; Re-read the file behind the current preview and repaint it.
;; The same as `etaf-md-refresh' on the preview's session, for a reader pressing
;; the page's own key.  Signals `user-error' when the current buffer is not a
;; preview.
;;
;; Function: etaf-md-wider ()
;;;###autoload (autoload 'etaf-md-wider "etaf-md" nil t)
;; Widen the current preview's reading measure by four cells.
;; Reports the effective width and the maximum.  Signals `user-error' when the
;; current buffer is not a preview.
;;
;; Function: etaf-md-narrower ()
;;;###autoload (autoload 'etaf-md-narrower "etaf-md" nil t)
;; Narrow the current preview's reading measure by four cells, down to
;; `etaf-md-width-min'.  Signals `user-error' when the current buffer is not a
;; preview.
;;
;; Function: etaf-md-locate (session index)
;; Move point to SESSION's outline heading INDEX and recenter.
;; INDEX is zero-based into `etaf-md-outline'.  Return the buffer
;; position, or nil when SESSION has no live buffer or the heading is not
;; visible.
;;
;; Function: etaf-md-adjust-width (session delta)
;; Widen SESSION's maximum reading measure by DELTA character cells and return
;; the new maximum.  The result is clamped to `etaf-md-width-min' and
;; `etaf-md-width-max'; a window narrower than the maximum fills the
;; available columns instead.
;;
;; Variable: etaf-md-theme (default `auto')
;; Initial palette of `etaf-md-create'.  `auto' derives the document
;; colors from the active frame's own faces (default, shadow, outline-1 and the
;; semantic faces) and paints no page background, so panels, tables, code
;; blocks and rules match whatever Emacs theme is active; `dark', `light' and
;; `sepia' select that fixed palette explicitly, including its page background.
;; `etaf-md-set-theme' and `etaf-md-cycle-theme' always select
;; an explicit palette, so the page background follows the chosen theme.  An
;; open preview keeps a live theme cell that a panel's title-bar switch also
;; writes, so a host can pin a fixed page or return to the face-derived one.
;;
;; Variable: etaf-md-flavor (default nil)
;; Default Markdown dialect of `etaf-md-create' when it is not given a
;; `:flavor': nil to take the renderer's default, a dialect name such as
;; `etaf' or `gfm', or a feature plist.  A markdown file may name its own
;; dialect with a `flavor:' line in its front matter, which is how one document
;; stays CommonMark while the rest of a directory read with every syntax the
;; renderer knows; a session's `:flavor' argument overrides the document.
;;
;; Variable: etaf-md-width-min (default 40)
;; Narrowest reading measure in character cells.
;;
;; Variable: etaf-md-width-max (default 96)
;; Widest reading measure in character cells; a wider window keeps this measure
;; and centers it.  The column keeps a two-cell gutter on each side outside the
;; measure, so text never starts or ends on the window edge; a window narrower
;; than the minimum measure plus those gutters clips a block that cannot shrink
;; to the measure instead of painting over the gutter.
;;
;; Variable: etaf-md-typeset (default t)
;; Whether a mermaid fence and a `$$' display formula are drawn by a program.
;; Both are source in the markdown and pictures on the page when mermaid-cli is
;; installed: the diagram is drawn by `mmdc', the formula by KaTeX in the
;; Chromium that package brings.  A render runs in the background and is cached
;; by its source and the page's colours, so a page paints its source at once
;; and swaps in the picture when it arrives; a block edited again draws again.
;; With this nil, or without the program, the fence stays a code block and the
;; formula keeps `etaf-ui-markdown-math-text'', which is also what an inline
;; formula always keeps, because a picture inside a line would change the line
;; height.
;;
;; Function: etaf-md-typeset-available-p ()
;; Return non-nil when this system can draw diagrams and formulas.
;; Both go through mermaid-cli, so this answers that one program's presence;
;; the answer is remembered until the next Emacs session.
;;
;; Error: etaf-md-error
;; Invalid markdown preview session or document input
;; Catch this condition with condition-case; failed calls do not return a value.

;;; Code:

(defgroup etaf-md nil
  "Markdown preview appearance and reading behavior."
  :group 'text)

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-ui)
(require 'etaf-md-theme)
(require 'etaf-md-node)
(require 'etaf-md-env)
(require 'etaf-md-nodes)
(require 'etaf-md-model)
(require 'etaf-md-views)
(require 'etaf-md-app)
(require 'etaf-md-live)
(require 'etaf-md-typeset)
(require 'etaf-md-qrcode)

(defun etaf-md-doctor ()
  "Return capability facts for reading a document.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Reading text needs no external program; each entry
tells which block keeps its source text without it."
  (list :required nil
        :optional
        (list (list "ffmpeg" (and (executable-find "ffmpeg") t)
                    "Optional: install ffmpeg to play video cards and convert terminal images.")
              (list "mmdc" (etaf-md-typeset-available-p)
                    "Optional: install mermaid-cli to draw mermaid diagrams and display formulas.")
              (list "qrencode" (and (executable-find "qrencode") t)
                    "Optional: install qrencode to draw a qrcode block."))))


(provide 'etaf-md)
;;; etaf-md.el ends here
