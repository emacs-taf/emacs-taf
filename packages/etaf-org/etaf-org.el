;;; etaf-org.el --- Living Org document renderer & extension platform in ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.4.8
;; Package-Requires: ((emacs "29.1") (etaf "0.3.11") (etaf-ui "0.3.11"))
;; Keywords: hypermedia, docs, org
;; URL: https://github.com/emacs-taf/etaf-org

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-org) after adding this repository and
;; the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  `etaf-org' renders
;; native Org-mode documents as a modern interactive reading view and extends
;; Org through a single unified node registry, style-rule engine, Org-native
;; container syntax (`#+begin_<name> :key val', `#+attr_etaf:', `#+<marker>:',
;; `#+BEGIN:' dynamic blocks), custom inline links, bounded workspace L1 live
;; views (`org-query', `kanban', `clock-summary', `transclude', `backlinks',
;; `include', `code-ref', `symbol', `project-tree', `git-log', `git-diff'),
;; explicit L2 Runbook actions (`run'), an independent side-window outline, and
;; an O(Δ) live-editing preview shell.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-org-doctor ()
;; Return capability facts for reading and extending Org documents.
;; The shape matches `etaf-install-doctor': `:required' and `:optional' lists
;; of `(LABEL AVAILABLE REMEDY)'.  Core reading needs no external program;
;; optional capabilities cover `org', `typeset-native', `ffmpeg', `qrencode', `git',
;; `rg', `dot' and `plantuml'.
;;
;; Function: etaf-org-open (&optional source)
;;;###autoload (autoload 'etaf-org-open "etaf-org" nil t)
;; Open a full-width Org reading view in the current window and return its
;; buffer.  SOURCE is a file path, a session from `etaf-org-create', or nil to
;; open the current `.org' buffer directly without prompting (syncing to point)
;; or prompt when called with `C-u' or from a non-Org buffer.  Never splits
;; windows; reuses an existing preview buffer visiting the same canonical file.
;;
;; Function: etaf-org-preview (&optional file)
;;;###autoload (autoload 'etaf-org-preview "etaf-org" nil t)
;; Toggle a live side-by-side Org preview in a right split beside the source
;; buffer.  Opening splits non-destructively without closing unrelated panes,
;; turns on proportional follow-scroll synced to the current source line and
;; keeps point in the source buffer; invoking it again (or pressing `q' in the
;; preview) closes the preview and removes only the split window it created.
;; When invoked inside a preview buffer with no FILE, delegates to
;; `etaf-org-toggle-split'.  This and `etaf-org-open' are the only globally
;; autoloaded `M-x' commands; all preview-buffer actions below are interactive
;; commands scoped to preview buffers via `completion-predicate' (and bound to
;; single-key defaults in `etaf-org-keys') so they work via `M-x' / `M-X'
;; inside previews without cluttering unrelated buffers.
;;
;; Function: etaf-org-close ()
;; Unmount the current preview buffer, close any attached outline side window,
;; and restore windows cleanly.  Removes only the split window created by
;; `etaf-org-preview' or `etaf-org-toggle-split'; when opened single-window
;; via `etaf-org-open', switches back to the originating buffer in place.
;;
;; Function: etaf-org-toggle-split ()
;; Toggle between single-window full-width reading and side-by-side left-source
;; / right-preview editing (`v').  Returns non-nil when split is active.
;;
;; Function: etaf-org-view (&optional session)
;;;###autoload (autoload 'etaf-org-view "etaf-org" nil nil)
;; Return the preview View for SESSION (defaulting to a new empty session).
;; Pass a session from `etaf-org-create' to embed an Org document in any ETAF
;; layout via `etaf-mount'.  Not an interactive command.
;;
;; Function: etaf-org-theme-tokens (theme-or-palette)
;; Return the ETAF UI theme token plist for THEME-OR-PALETTE (`dark', `light',
;; `sepia', `auto', or a palette alist).  Every color value is normalized to a
;; valid 6-digit `#RRGGBB' hex string.
;;
;; Function: etaf-org-create (&key file text title theme flavor toc today on-link on-media on-action (link-hover t) (heading-underline t))
;; Return a new headless Org session.
;; Exactly one of FILE or TEXT is required; missing FILE signals
;; `etaf-org-error'.  TITLE overrides document title; THEME selects `auto',
;; `dark', `light' or `sepia'; FLAVOR selects `etaf' (default), `standard' or
;; a feature plist; TOC overrides `#+OPTIONS: toc' depth; TODAY injects a
;; reference date `(Y M D)' or `YYYY-MM-DD' for overdue checks; ON-LINK,
;; ON-MEDIA and ON-ACTION intercept links, media and actions; LINK-HOVER and
;; HEADING-UNDERLINE default to t.
;;
;; Function: etaf-org-state (session)
;; Return SESSION's state as a detached plist snapshot.
;; Keys include `:file', `:title', `:author', `:date', `:keywords', `:filetags',
;; `:flavor', `:theme', `:theme-mode', `:background', `:width', `:buffer',
;; `:outline', `:sections', `:blocks', `:footnotes', `:citations', `:filter',
;; `:spoilers-revealed', `:degraded', `:counts' (`:todo', `:done', `:deadline',
;; `:overdue', `:clock-minutes') and `:error'.
;;
;; Function: etaf-org-refresh (session)
;; Re-read and re-parse SESSION's document and return SESSION.
;; A read failure signals `etaf-org-error' and leaves the published document
;; untouched.
;;
;; Function: etaf-org-set-theme (session theme)
;; Show SESSION with palette THEME (`auto', `dark', `light' or `sepia').
;; Signals `etaf-org-error' on unknown theme names.
;;
;; Function: etaf-org-cycle-theme (&optional session)
;; Cycle SESSION (or the current preview) through `dark', `light', `sepia' and
;; `auto' and return the new theme mode symbol.
;;
;; Function: etaf-org-outline (session)
;; Return SESSION's outline as a list of `(LEVEL TITLE ID TODO TAGS)' entries.
;;
;; Function: etaf-org-locate (session index)
;; Move point to SESSION's zero-based outline heading INDEX (pushing mark),
;; reveal collapsed ancestors, and return its buffer position.
;;
;; Function: etaf-org-fold (session id state)
;; Set fold STATE (`folded', `children' or `open') of SESSION's section ID.
;; Signals `etaf-org-error' for unknown section id or state.
;;
;; Function: etaf-org-folded-p (session id)
;; Return non-nil when SESSION's section ID is folded.
;;
;; Function: etaf-org-fold-all (session state)
;; Set every section of SESSION to fold STATE in one batch and return SESSION.
;;
;; Function: etaf-org-show-toc (session show)
;; Show or hide SESSION's inline Org preamble table of contents and return
;; SESSION.
;;
;; Function: etaf-org-show-hidden (session show)
;; Show or hide SESSION's hidden content (comments, properties, drawers,
;; metadata) and return SESSION.
;;
;; Function: etaf-org-set-filter (session filter)
;; Filter visible sections in SESSION by FILTER query string (TODO, :tag:,
;; #priority, keywords; nil or empty clears).  Return SESSION.
;;
;; Function: etaf-org-update-block (session id view)
;; Replace the rendered ETAF View of SESSION's named block ID (`#+NAME:' or
;; `:id') with VIEW (or nil to restore default rendering).  Signals
;; `etaf-org-error' when ID is unknown.
;;
;; Function: etaf-org-adjust-width (session delta)
;; Adjust SESSION's maximum reading measure by DELTA columns clamped to
;; `etaf-org-width-min'..`etaf-org-width-max' and return the new width.
;;
;; Function: etaf-org-next-heading (&optional session)
;; Move point to the next visible headline in SESSION or the current preview.
;;
;; Function: etaf-org-previous-heading (&optional session)
;; Move point to the previous visible headline in SESSION or the current preview.
;;
;; Function: etaf-org-goto-heading ()
;; Choose a headline from the current preview outline and jump to it.
;;
;; Function: etaf-org-open-link ()
;; Activate the link or interactive control at point in the current preview.
;;
;; Function: etaf-org-goto-source (&optional session)
;; Jump from the current preview position to the matching Org source line and
;; momentarily highlight it.  Switches in place in single-window mode.
;;
;; Function: etaf-org-follow-scroll (&optional arg)
;; Toggle proportional follow-scroll synchronization between source and preview.
;; Works from either the preview buffer or its source Org buffer.
;;
;; Function: etaf-org-toggle-toc (&optional arg)
;; Toggle the independent `*ETAF Org Outline*' side window (`T') for the
;; current preview.  Opens on `etaf-org-toc-side' (default `left') with width
;; `etaf-org-toc-width' so scaled headings never affect TOC row height or
;; scrolling.  Returns non-nil when open and nil when closed.
;;
;; Variable: etaf-org-toc-side (default `left')
;; Side of the frame where the independent TOC side window opens: `left'
;; (default) or `right'.
;;
;; Variable: etaf-org-toc-width (default 28)
;; Width of the independent TOC side window in character cells (clamped
;; between 18 and 52).
;;
;; Variable: etaf-org-keys
;; Customizable list of `(KEY COMMAND LABEL)' entries active in a preview
;; buffer.  Defaults use single keys only so user prefix maps (`C-c', `C-t',
;; `C-x', etc.) are never shadowed.
;;
;; Function: etaf-org-preview-link (&optional session)
;; Show or dismiss the floating viewport-centered peek dialog (`K') for the
;; link, footnote, citation or target at point.  Pressing `K' again on the
;; same target or pressing `Esc' dismisses it.
;;
;; Function: etaf-org-filter (&optional query session)
;; Interactively filter visible sections (`/') by TODO, tags, priority or
;; keywords.
;;
;; Function: etaf-org-cycle-fold (&optional session)
;; Cycle fold state of the current section (`folded' -> `children' -> `open').
;;
;; Function: etaf-org-cycle-global-fold (&optional session)
;; Cycle global fold state between outline overview and full content.
;;
;; Function: etaf-org-toggle-spoilers (&optional session)
;; Toggle global visibility of `!!spoiler!!' and `[[spoiler:...]]' masks.
;;
;; Function: etaf-org-toggle-hidden ()
;; Toggle visibility of comments, properties, drawers and metadata (`H').
;;
;; Function: etaf-org-reload ()
;; Re-read and repaint the current preview buffer (`g' / `r').
;;
;; Function: etaf-org-wider ()
;; Widen the current preview reading measure by four columns (`]').
;;
;; Function: etaf-org-narrower ()
;; Narrow the current preview reading measure by four columns (`[').
;;
;; Function: etaf-org-edit-mode (&optional arg)
;; Toggle non-destructive authoring assistance (soft font-lock, CAPF completion
;; from `etaf-org-node-definitions', and bounded block-pair highlight) in Org
;; source buffers.  Callable from Lisp or `org-mode-hook'; not a global `M-x'
;; command.
;;
;; Function: etaf-org-insert-block (name)
;; Insert a `#+begin_NAME ... #+end_NAME' container skeleton at point in an Org
;; buffer.  Callable from Lisp; not a global `M-x' command.
;;
;; Function: etaf-org-define-node (type &rest args)
;; Register a node TYPE (or extend/replace an existing type via `:extends' or
;; `:replace') with `:name', `:summary', `:attrs', `:derived', `:accepts',
;; `:child-syntax', `:contract' and `:view'.
;;
;; Function: etaf-org-undefine-node (type)
;; Remove user definition of TYPE, restoring a shipped type's built-in
;; definition or removing a user-only type from `etaf-org-node-definitions'.
;;
;; Function: etaf-org-set-attr (selector rules)
;; Install style RULES `(KEY VALUE)...' for SELECTOR `(TYPE :ATTR VAL ...)',
;; or clear rules for SELECTOR when RULES is nil.
;;
;; Function: etaf-org-set-view (type function &rest args)
;; Override the view paint FUNCTION of node TYPE (or pass nil to restore the
;; shipped view).  ARGS accepts `:extends', `:replace' and `:style-keys'.
;;
;; Function: etaf-org-describe-nodes (&optional type)
;; Return a readable directory of registered node types, their attributes,
;; accepted children and active style rules.
;;
;; Function: etaf-org-derived-attributes (type)
;; Return TYPE's read-only derived attribute name symbols in declaration order.
;;
;; Function: etaf-org-attr (env key &optional node)
;; Return resolved value of attribute KEY on NODE (or ENV's current node).
;;
;; Function: etaf-org-type (env)
;; Return the node type symbol of ENV's current node.
;;
;; Function: etaf-org-children (env &optional node)
;; Return child nodes/blocks of NODE (or ENV's current node) in document order.
;;
;; Function: etaf-org-content (env)
;; Paint all children of ENV's current node as one ETAF View.
;;
;; Function: etaf-org-render (env nodes)
;; Paint a list of NODES (or single node) as an ETAF View in ENV.
;;
;; Function: etaf-org-surface (env word)
;; Convert semantic surface WORD (`none', `page', `raised', `sunken', `quote',
;; `table-header', `table-stripe') to a theme color in ENV, or nil.
;;
;; Function: etaf-org-accent (env word &optional soft)
;; Convert semantic accent WORD (`neutral', `primary', `info', `success',
;; `warning', `danger', `important') to its foreground (or SOFT fill) color.
;;
;; Function: etaf-org-default-view (env)
;; Paint ENV's node using its previous (shipped) view function.
;;
;; Function: etaf-org-follow-link (env target)
;; Open link TARGET through ENV's session; return non-nil when handled.
;;
;; Function: etaf-org-block-state (env key &optional default)
;; Return per-block reactive state for KEY in ENV, or DEFAULT.
;;
;; Function: etaf-org-set-block-state (env key value)
;; Store VALUE under KEY in ENV's per-block reactive state (propagating
;; `:selected' when `:target' is declared) and return VALUE.
;;
;; Function: etaf-org-available-width (env)
;; Return available character column width for ENV's block.
;;
;; Variable: etaf-org-theme (default `auto')
;; Initial palette of `etaf-org-create' (`auto', `dark', `light', `sepia').
;;
;; Variable: etaf-org-flavor (default `etaf')
;; Default Org dialect (`etaf', `standard', or a feature plist).
;;
;; Variable: etaf-org-width-min (default 40)
;; Narrowest reading measure in character cells.
;;
;; Variable: etaf-org-width-max (default 96)
;; Widest reading measure in character cells.
;;
;; Variable: etaf-org-image-max-height (default 24)
;; Tallest image in text lines.
;;
;; Variable: etaf-org-typeset (default t)
;; Whether display formulas and diagram source blocks are drawn as pictures.
;;
;; Variable: etaf-org-src-renderers (default nil)
;; Alist of `(LANG . FN)' custom source block renderers tried before built-in
;; code/diagram views.
;;
;; Variable: etaf-org-remote-images (default t)
;; Whether mounted buffers asynchronously fetch remote HTTP(S) images into the
;; bounded disk cache.
;;
;; Variable: etaf-org-cache-max-bytes (default 104857600)
;; Soft LRU byte cap for `etaf-org' disk cache subdirectories.
;;
;; Variable: etaf-org-allow-local-read (default t)
;; Whether read-only workspace L1 widgets and native `#+INCLUDE:'/`#+SETUPFILE:'
;; may read files inside the project root.
;;
;; Variable: etaf-org-allow-actions (default `ask')
;; Trust policy (`ask', `t', or `nil') for explicit executable L2 actions
;; (`run').
;;
;; Variable: etaf-org-allow-babel (default nil)
;; Trust policy (`nil', `ask', or `t') for opt-in Org Babel execution on
;; `#+begin_src' blocks.
;;
;; Variable: etaf-org-interactive-checkbox (default t)
;; Whether clicking a list checkbox toggles `[ ]'/`[X]' in source and updates
;; parent `[n/m]'/`[p%]' cookies.
;;
;; Variable: etaf-org-interactive-todo (default nil)
;; Whether clicking a headline TODO chip cycles its keyword in source.
;;
;; Variable: etaf-org-media-lightbox (default `auto')
;; Whether activating a local image opens the in-buffer `etaf-media-viewer'
;; lightbox (`auto', `t', or `nil').
;;
;; Variable: etaf-org-node-definitions (default hash table of built-in nodes)
;; Registry mapping node type symbols to their definition plists.
;;
;; Variable: etaf-org-styles (default nil)
;; Ordered list of reader style rules written by `etaf-org-set-attr'.
;;
;; Variable: etaf-org-node-directory (default `~/.emacs.d/etaf-org/nodes')
;; Directory of user `.el' node definitions loaded once on first session.
;;
;; Variable: etaf-org-contract (default 1)
;; Version of the document-side attribute contract accepted by this build.
;;
;; Error: etaf-org-error
;; Invalid Org session, node definition, style rule, or unreadable document.

;;; Code:

(defgroup etaf-org nil
  "Modern Org rendering, extension widgets and live preview in ETAF."
  :group 'text)

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-org")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-org.el" dir))
                                (file-exists-p (expand-file-name "etaf-org.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-ui)
(require 'etaf-org-entities)
(require 'etaf-org-cache)
(require 'etaf-org-theme)
(require 'etaf-org-node)
(require 'etaf-org-parse)
(require 'etaf-org-derive)
(require 'etaf-org-env)
(require 'etaf-org-qrcode)
(require 'etaf-org-typeset)
(require 'etaf-org-assets)
(require 'etaf-org-nodes)
(require 'etaf-org-widgets)
(require 'etaf-org-views)
(require 'etaf-org-model)
(require 'etaf-org-live)
(require 'etaf-org-app)
(require 'etaf-org-edit)

(defun etaf-org-doctor ()
  "Return capability facts for `etaf-org'.
The shape matches `etaf-install-doctor': `:required' and `:optional' lists of
`(LABEL AVAILABLE REMEDY)'."
  (let* ((native-info (etaf-org-typeset--native-info))
         (native-ok (and native-info t))
         (native-remedy
          (if native-info
              (format "Built-in QuickJS native renderer active (Pele %s, MathJax %s, text: %s)."
                      (plist-get native-info :pele)
                      (plist-get native-info :mathjax)
                      (plist-get native-info :text-backend))
            "Optional: run M-x etaf-install-native (select etaf-org) to download the prebuilt QuickJS renderer for fast zero-browser Mermaid and math SVG rendering.")))
    (list :required nil
          :optional
          (list (list "org" (featurep 'org)
                      "Optional: load Org to resolve org-id links and org-todo-keywords.")
                (list "typeset-native" native-ok native-remedy)
                (list "ffmpeg" (and (executable-find "ffmpeg") t)
                      "Optional: install ffmpeg to play inline video blocks.")
                (list "qrencode" (and (executable-find "qrencode") t)
                      "Optional: install qrencode to draw PNG QR code cards.")
                (list "git" (and (executable-find "git") t)
                      "Optional: install git for git-log and git-diff live blocks.")
                (list "rg" (and (executable-find "rg") t)
                      "Optional: install ripgrep for faster workspace backlinks scans.")
                (list "dot" (and (executable-find "dot") t)
                      "Optional: install Graphviz (dot) to draw dot/graphviz source blocks.")
                (list "plantuml" (and (executable-find "plantuml") t)
                      "Optional: install PlantUML to draw plantuml source blocks.")))))

(provide 'etaf-org)
;;; etaf-org.el ends here
