;;; etaf-md.el --- Modern Markdown preview in ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.5
;; Package-Requires: ((emacs "29.1") (etaf "0.3.10") (etaf-ui "0.3.6"))
;; Keywords: hypermedia, docs
;; URL: https://github.com/emacs-taf/etaf-md

;;; Commentary:

;; Modern Markdown reading view and living-document renderer built on ETAF.
;;
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
;; Function: etaf-md-open (&optional source)
;;;###autoload (autoload 'etaf-md-open "etaf-md" nil t)
;; Open a full-width Markdown reading view in the current window and return its
;; buffer.  SOURCE is a file path, a session from `etaf-md-create', or nil to
;; prompt for a file.  Interactively, when the current buffer visits a Markdown
;; file and no prefix argument is given, opens it immediately without prompting
;; or splitting windows and syncs to the current source line; with `C-u' or
;; from any other buffer, prompts for a file.  A file that already has a
;; preview buffer is selected instead of rendered twice.  Opening a session
;; mounts that session, so callers can render a document they built themselves.
;; The buffer is an ETAF application (`etaf-app-open') whose root keys add
;; outline navigation, side-by-side split toggling, reloading, theming and
;; closing; the reading measure starts from the showing window and later
;; resizes reflow through the framework's viewport update.  A preview opened
;; from a file follows it live on every edit and save.  Closing a single-window
;; preview with `etaf-md-close' (`q') restores the originating buffer without
;; deleting the window.
;;
;; Function: etaf-md-preview (&optional file)
;;;###autoload (autoload 'etaf-md-preview "etaf-md" nil t)
;; Toggle a live side-by-side preview in a right split beside the Markdown
;; source window.  Opening splits non-destructively without closing unrelated
;; panes, turns on proportional scroll-follow aligned to the current source
;; line and keeps point in the source buffer; invoking it again (or pressing
;; `q' in the preview) closes the preview and removes only the split window it
;; created.  When invoked inside a preview buffer with no FILE, delegates to
;; `etaf-md-toggle-split'.  This and `etaf-md-open' are the only global `M-x'
;; interactive commands; all preview-buffer actions below are bound to keys in
;; the preview buffer and remain callable from Lisp without polluting `M-x'.
;;
;; Function: etaf-md-close ()
;; Unmount the current preview buffer, kill it and restore its window cleanly.
;; Removes only the split window created by `etaf-md-preview' or
;; `etaf-md-toggle-split'; when opened single-window via `etaf-md-open',
;; restores the originating buffer in place.  Signals `user-error' when the
;; current buffer is not a preview.
;;
;; Function: etaf-md-toggle-split ()
;; Toggle between single-window full reading view and side-by-side source +
;; preview editing from inside the current preview buffer (`v').  Returns
;; non-nil when side-by-side split is active.
;;
;; Function: etaf-md-view (&optional session)
;;;###autoload (autoload 'etaf-md-view "etaf-md" nil nil)
;; Return the preview View for SESSION.
;; SESSION defaults to a new empty session; pass a session from
;; `etaf-md-create' to mount a real document yourself with
;; `etaf-mount', for example inside a tab or a larger layout.
;;
;; Function: etaf-md-create (&key file text title theme flavor on-link on-media (link-hover t) (heading-underline t))
;; Return a new headless preview session.
;; Exactly one of FILE (a markdown document read from disk) or TEXT (the
;; document itself) is required; a missing or unreadable FILE signals
;; `etaf-md-error'.  TITLE overrides the document title and THEME
;; selects a palette from `etaf-md-themes', defaulting to the frame's
;; background mode.  FLAVOR selects the markdown dialect: `etaf' (the default)
;; enables GFM plus ETAF extensions and front matter, `gfm' enables the GitHub
;; extensions (tables, task lists, strikethrough, autolinks, footnotes and
;; front matter), `commonmark' parses the core specification only, and a
;; feature plist toggles individual extensions.  ON-LINK is an
;; optional function (URL) called when a link is activated; returning non-nil
;; marks the activation handled, and returning nil falls back to the default
;; behavior (in-document `#anchor' jump, `browse-url' for remote URLs, or
;; opening local files).  ON-MEDIA is an optional function (KIND PATH) called
;; when media is activated, where KIND is the symbol `image' or `video' and
;; PATH is the resolved local path or remote URL; returning non-nil marks the
;; activation handled, and returning nil falls back to inline video playback
;; or opening the media.  LINK-HOVER controls whether rendered links carry a
;; hover background highlight (default t; nil suppresses hover highlights while
;; keeping links clickable).  HEADING-UNDERLINE controls whether headings draw
;; a bottom rule on levels 1–2 and underline inline links inside headings
;; (default t; nil suppresses both while keeping heading links clickable and
;; body links underlined).  The session owns no buffer, so it is a complete
;; headless preview for scripts and tests.
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
;; Function: etaf-md-cycle-theme (&optional session)
;; Switch SESSION (or the current preview buffer interactively via `t') to the
;; next theme mode (`dark' -> `light' -> `sepia' -> `auto') and return the
;; newly selected mode symbol.
;;
;; Function: etaf-md-outline (session)
;; Return SESSION's outline as a list of (LEVEL TEXT ID), in document order.
;;
;; Function: etaf-md-goto-heading ()
;; Choose an outline heading of the current preview and move to it.
;; The candidate list is the document's own outline, indented by level and
;; prefixed with its hash marks.  Signals `user-error' when the current buffer
;; is not a preview.
;;
;; Function: etaf-md-goto-source ()
;; Jump from the current preview point to the matching line in its source
;; buffer or file and momentarily highlight that line.  Selects an existing
;; source window when visible, or switches to the source buffer in place
;; without creating an unexpected split.  Returns the target buffer position,
;; or signals `user-error' when the preview has no backing source.
;;
;; Function: etaf-md-next-heading ()
;; Move point to the next outline heading of the current preview.
;; Reports "No further heading" when the document has no later heading and
;; signals `user-error' when the current buffer is not a preview.
;;
;; Function: etaf-md-previous-heading ()
;; Move point to the previous outline heading of the current preview.
;; Reports "No earlier heading" at the first heading and signals
;; `user-error' when the current buffer is not a preview.
;;
;; Function: etaf-md-follow-scroll (&optional arg)
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
;; Re-read the file behind the current preview and repaint it.
;; The same as `etaf-md-refresh' on the preview's session, for a reader pressing
;; the page's own key.  Signals `user-error' when the current buffer is not a
;; preview.
;;
;; Function: etaf-md-wider ()
;; Widen the current preview's reading measure by four cells.
;; Reports the effective width and the maximum.  Signals `user-error' when the
;; current buffer is not a preview.
;;
;; Function: etaf-md-narrower ()
;; Narrow the current preview's reading measure by four cells, down to
;; `etaf-md-width-min'.  Signals `user-error' when the current buffer is not a
;; preview.
;;
;; Function: etaf-md-locate (session index)
;; Move point to SESSION's outline heading INDEX and bring it into view.
;; INDEX is zero-based into `etaf-md-outline'.  When SESSION is embedded inside
;; a scrolling Host viewport, scrolls the enclosing viewport to the heading
;; without disturbing surrounding chrome; otherwise recenters the window.
;; Return the buffer position, or nil when SESSION has no live buffer or the
;; heading is not visible.
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
;; `etaf-md-set-theme' selects `auto' or an explicit palette, and
;; `etaf-md-cycle-theme' cycles `dark' -> `light' -> `sepia' -> `auto'.  An
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
;; Whether a mermaid fence and a `$$' display formula are drawn as pictures.
;; Both are source in the markdown and crisp SVGs on the page when the
;; embedded QuickJS native module (installed automatically by `M-x etaf-install'
;; or `M-x etaf-install-native', or built from a source checkout with
;; `make native-build', combining vendored
;; Obsidian Pele + native CoreText/Pango text measurement and MathJax
;; TeX-to-SVG, inspired by LuciusChen/pele.el) is available; `mermaid-cli' +
;; KaTeX serves as an automatic fallback when the native module is absent or
;; for diagram dialects Pele does not implement.  A render runs in the
;; background and is cached by its source and the page's colours, keeping the
;; last valid picture visible while editing until the replacement arrives.
;; With this nil, or without any backend, the fence stays a code block and the
;; formula keeps `etaf-ui-markdown-math-text', which is also what an inline
;; formula always keeps, because a picture inside a line would change the line
;; height.
;;
;; Function: etaf-md-typeset-available-p ()
;; Return non-nil when this system can draw diagrams and formulas.
;; Checks the embedded QuickJS native module first, then `mermaid-cli' (`mmdc')
;; plus `node' as fallback.
;;
;; Function: etaf-md-toggle-toc (&optional arg)
;; Toggle the independent right side-window outline (`*ETAF Outline*') for the
;; current preview (`C-c t`).  With prefix ARG, open when positive and close
;; otherwise.  Returns the new state.
;;
;; Function: etaf-md-toggle-spoilers (&optional arg)
;; Reveal or hide all `!!spoiler!!' spans in the current preview (`S`).
;; With prefix ARG, reveal when positive and hide otherwise.  Returns the new
;; state.
;;
;; Function: etaf-md-preview-link ()
;; Inspect the link, wiki-link, in-document anchor or Emacs symbol at point
;; inside a dismissible in-buffer preview card (`K`).  Returns the preview
;; plist or nil.
;;
;; Variable: etaf-md-allow-local-read (default t)
;; Whether read-only workspace widgets (`include', `code-ref', `project-tree',
;; `git-log', `git-diff') may read files inside the document's workspace root.
;;
;; Variable: etaf-md-allow-actions (default `ask')
;; Whether executable widget actions (`run') are allowed: `ask' prompts
;; before running, `t' runs without prompting, and `nil' disables execution.
;;
;; Variable: etaf-md-interactive-checkbox (default t)
;; Whether activating a task list checkbox toggles `[ ]' and `[x]' in source.
;;
;; Variable: etaf-md-media-lightbox (default `auto')
;; Whether activating a local image opens the in-buffer media lightbox (`auto'
;; uses it on graphical frames, `t' always uses it, `nil' opens externally).
;;
;; Variable: etaf-md-remote-images (default t)
;; Whether displayed previews asynchronously download remote HTTP(S) images
;; into the local disk cache (`~/.cache/etaf-md/images/') and repaint them in
;; place once ready.  Headless sessions created by `etaf-md-create' never
;; initiate network transfers.
;;
;; Variable: etaf-md-cache-max-bytes (default 104857600)
;; Maximum total size in bytes retained per `etaf-md' disk cache directory
;; (`typeset/', `qrcode/' and `images/') before least recently modified
;; entries are evicted lazily on idle.
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
                                  (or (and load-file-name
                                           (not (string-suffix-p ".eln" load-file-name))
                                           (file-directory-p (expand-file-name "lisp" (file-name-directory load-file-name)))
                                           load-file-name)
                                      (bound-and-true-p byte-compile-current-file)
                                      (locate-library "etaf-md")
                                      buffer-file-name)))))

(require 'etaf-ui)
(require 'etaf-md-cache)
(require 'etaf-md-theme)
(require 'etaf-md-assets)
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
The shape matches `etaf-install-doctor': `:required' and `:optional' lists of
\\(LABEL AVAILABLE REMEDY).  Reading text needs no external program; each entry
tells which block keeps its source text without it."
  (let* ((native-info (etaf-md-typeset--native-info))
         (native-ok (and native-info t))
         (native-remedy
          (if native-info
              (format "Built-in QuickJS native renderer active (Pele %s, MathJax %s, text: %s)."
                      (plist-get native-info :pele)
                      (plist-get native-info :mathjax)
                      (plist-get native-info :text-backend))
            "Optional: run M-x etaf-install-native (select etaf-md) to download the prebuilt QuickJS renderer for fast zero-browser Mermaid and math SVG rendering.")))
    (list :required nil
          :optional
          (list (list "typeset-native" native-ok native-remedy)
                (list "ffmpeg" (and (executable-find "ffmpeg") t)
                      "Optional: install ffmpeg to play video cards and convert terminal images.")
                (list "mmdc" (etaf-md-typeset--mmdc-available-p)
                      "Optional fallback: install mermaid-cli when the native renderer is not built or for unsupported Mermaid dialects.")
                (list "qrencode" (and (executable-find "qrencode") t)
                      "Optional: install qrencode to draw a qrcode block.")
                (list "git" (and (executable-find "git") t)
                      "Optional: install git for git-log and git-diff living-doc blocks.")))))


(provide 'etaf-md)
;;; etaf-md.el ends here
