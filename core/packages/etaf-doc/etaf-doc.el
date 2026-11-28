;;; etaf-doc.el --- Document parsing, typesetting, caching and editorial widgets for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.20") (etaf-ui "0.3.15"))
;; Keywords: text, tools, ui
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; Shared document infrastructure for ETAF document applications (`etaf-md',
;; `etaf-org', `etaf-web', `etaf-manual', `etaf-translate'): Markdown parsing,
;; syntax highlighting, block view rendering, bounded LRU asset caches, async
;; QR/Mermaid/MathJax typesetting, unified node protocol and editorial widgets.
;;
;; Public API
;;
;; Load this package with (require 'etaf-doc) after adding the repository
;; root to `load-path'.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions.  The ETAF Reference Manual contains workflows.
;;
;; Function: etaf-doc-markdown-parse (text &optional flavor)
;; Parse markdown TEXT into a document plist, or signal `etaf-doc-markdown-error'.
;; FLAVOR is a dialect name from `etaf-doc-markdown-flavors' (`etaf' is the
;; default), a feature plist overriding individual flags and extensions, or
;; nil for `etaf-doc-markdown-flavor'.  Keys are `:meta' (front matter alist),
;; `:title', `:children' (top-level blocks with heading ids), `:outline'
;; (`(LEVEL TEXT ID)' in document order), `:footnotes' (definitions with
;; `:label', `:number' and `:children') and `:features' (the resolved
;; extension plist, `:extensions' naming the syntax this module adds).  A
;; block is a plist with `:type' one of `heading', `paragraph', `code-block',
;; `blockquote', `list', `table', `thematic-break', `html-block',
;; `footnote-def', `definition-list' (items with `:term', `:children' and
;; `:definitions') and `math' (`:text' as written, `:display' for a `$$'
;; block).  An inline is a plist with `:type' one of `text', `code', `emph',
;; `strong', `strike', `link', `image', `autolink', `footnote-ref', `html',
;; `break', `subscript' and `superscript' (both carry `:rendered', the script
;; characters to paint), `abbreviation' (`:text' and its `:title'), `emoji'
;; (`:text' as written and `:char' to paint) and `math'.  A top-level block also
;; carries `:begin' and `:end', its half-open character range in TEXT, so a
;; caller maps an edit back to the block that holds it; nested blocks carry no
;; range because their offsets belong to the snippet their container parsed.
;;
;; Variable: etaf-doc-markdown-code-renderers
;; Renderers for one fenced language, as an alist of (LANGUAGE . FUNCTION).
;; FUNCTION receives the block and the rendering environment and returns a
;; View, or nil to keep the default.  This is where a language that needs a
;; program belongs -- a diagram language, a typesetter -- so the parser stays
;; pure Elisp and a missing program only means that block shows its source.
;; The environment's `:render-code-block' is consulted first and overrides the
;; table for one caller.
;;
;; Function: etaf-doc-highlight-code (language text)
;; Return runs colouring TEXT as LANGUAGE, or nil to paint it in one colour.
;; Emacs already knows how to read the language: this runs its major mode over
;; the text in a scratch buffer and turns the faces `font-lock' produced into
;; runs of `(:text STRING :props PLIST)'.  Only what a text run can express is
;; kept (colour, weight, slant, underline, strike-through), so a page of code
;; shows the colours the source buffer shows.  The answer is a pure function of
;; (LANGUAGE . TEXT) and is cached, so a repaint costs one lookup; a language
;; with no available mode, or a block over `etaf-doc-highlight--max-lines'
;; or `--max-chars', returns nil instead of fontifying.  Never signals.
;;
;; Variable: etaf-doc-highlight-languages
;; Fence language names and the major mode that reads each one, as an alist of
;; (NAME . MODE).  A mode whose library cannot be loaded is skipped, so adding a
;; name never makes a document fail to render.
;;
;; Function: etaf-doc-markdown-math-text (source)
;; Return SOURCE, a TeX formula, written as plain text; never signals.
;; The page paints a formula as text rather than an image: command names get
;; their symbols, `\frac{a}{b}' becomes `a/b', `\sqrt{x}' becomes `√(x)',
;; and `^{}' and `_{}' become the Unicode letters of that position.  Anything
;; the mapping does not know keeps its own characters, so a formula never
;; turns into noise.  Callers that want real typesetting return a View from
;; `:render-math' instead, which leaves this function as the fallback.
;;
;; Function: etaf-doc-markdown-view-block (block env)
;; Return BLOCK rendered as one ETAF View, or nil when nothing renders.
;; BLOCK is one top-level block of `etaf-doc-markdown-parse' and ENV is the
;; rendering environment described below.  A block that expands to several
;; Views is wrapped in one column, so callers own one node per block.
;;
;; Function: etaf-doc-markdown-view-blocks (blocks env &optional tight)
;; Return the list of Views for BLOCKS in document order, or nil for empty input.
;; Consecutive blocks are separated by one blank line unless TIGHT is non-nil.
;; The list carries no container, so callers wrap it for scrolling, selection
;; or per-block references; a renderer that also wants the document's
;; footnote definitions appends the Views of `:footnotes' itself.
;;
;; The rendering environment is a plist.  `:palette' is required: an alist of
;; semantic color keys (`:ink', `:muted', `:faint', `:heading', `:accent',
;; `:accent-soft', `:panel', `:code-bg' (optional; inline code and code
;; blocks use it when present and fall back to `:panel'), `:border',
;; `:quote-bg', `:quote-bar',
;; `:table-header', `:table-stripe', `:heading-rule' (optional; the rule
;; under a level-1 and level-2 heading falls back to `:border'), `:ok',
;; `:ok-soft', `:warn',
;; `:warn-soft', `:danger', `:danger-soft', `:important' and
;; `:important-soft'); every color is read through it, so a palette change
;; never leaks a half-updated set of colors, and an unknown key signals
;; `etaf-doc-markdown-error'.  `:open-link' is called with a link URL;
;; `:link-hover' controls whether rendered links carry an `:accent-soft' hover
;; background (default t when omitted; nil suppresses link hover highlights);
;; `:heading-underline' controls whether headings draw a bottom rule on levels
;; 1–2 and underline inline links inside headings (default t when omitted; nil
;; suppresses both while keeping heading links active and body links underlined);
;; `:footnote-jump' with a footnote label; `:footnote-ref (label)' returns a
;; host `:ref' symbol attached to the footnote definition box; `:footnote-back
;; (label)' appends a clickable `↩' return control on each footnote definition;
;; `:on-copy (kind text lines)' is called after the code block copy button
;; copies TEXT into the kill ring; `:render-media (kind node env)'
;; returns the View for media, where KIND is `image', `video', `inline-image',
;; `table-image' or `html-media' (without it media renders as its alt text or
;; URL); for `table-image', ENV supplies `:table-cell' t, `:width' and
;; `:table-cell-width' set to the cell's inner content columns, and
;; `:table-cell-align';
;; `:render-code-block (block env)' may return a View for a code block and
;; nil keeps the default fenced block, so a diagram language can be drawn by a
;; program without teaching the renderer about it; `:render-math (block env)'
;; does the same for a display formula, whose block carries `:display' and its
;; TeX source, and nil keeps the text rendering; `:code-link (text)' is called with
;; the text of every code span and may return a URL or a (URL . HELP) cons
;; to make that span a focusable link, which keeps the code style, gains an
;; underline and calls `:open-link' with URL on activation, its help echo
;; being HELP or URL; `:alert-labels' is an alist
;; overriding the callout labels kind by kind; `:features' is the document's
;; resolved extension plist, which gates the alert callouts.
;; `:line-grid' non-nil keeps every rendered line at the standard line
;; height, for documents shown in a scrolling pane beside other content:
;; headings and footnote references keep the body font size, a level-1
;; heading uses the accent color and a level-2 heading gains a left accent
;; bar, so scrolling never changes the height of the lines it reveals.
;; Without `:line-grid' the top two heading levels draw a rule from
;; `:heading-rule' under their text, a fenced block with a language opens
;; with a header strip holding that language, a table draws its outer border,
;; a rule between every pair of columns and a rule between rows (its header
;; row separated by a stronger one), and drops its zebra
;; stripe when the palette gives the stripe and the header row one surface,
;; and a quote paints its text in `:muted' while links and code keep their
;; own colors.
;; Table columns share the width in proportion to their widest cell, keep a
;; short unbreakable run such as a CJK word whole, and wrap longer cells at
;; word boundaries.
;;
;; Variable: etaf-doc-markdown-flavor
;; Default markdown dialect of `etaf-doc-markdown-parse', `etaf' unless set.
;; A FLAVOR argument overrides it.  `etaf' is the widest preset and what a
;; reader gets by opening a document; `gfm' and `commonmark' name the narrower
;; ones to use when a document has to parse exactly as those specifications
;; say, and a feature plist toggles individual flags and extensions.
;;
;; Variable: etaf-doc-markdown-flavors
;; Named markdown dialects and the syntax each one enables.
;; `commonmark' is the CommonMark core; `gfm' adds GitHub's extensions there
;; as well: tables, task lists, strikethrough, bare autolinks, footnotes,
;; alert blocks and front matter; `etaf' adds definition lists, sub- and
;; superscript, abbreviations and `$' math on top of `gfm'.  A preset is only
;; a set of switches over one parser, so a document written for one of them
;; still parses under another, with the syntax it did not enable showing as
;; literal text.  None of the added syntax needs an external program.
;;
;; Variable: etaf-doc-markdown-gfm-features
;; The feature plist GitHub Flavored Markdown enables: front matter, tables,
;; task lists, strikethrough, autolinks, footnotes and alert blocks.
;; A preset spells its own flags out, so extending this list never changes what
;; an older preset meant; use it to start a plist of your own.
;;
;; Function: etaf-doc-markdown-extension-p (name)
;; Return non-nil when the document being parsed enables extension NAME.
;; NAME is one of the symbols in a preset's `:extensions' list, such as
;; `emoji' or `definition-list'.  A parser extension calls this to decide
;; whether its syntax runs at all; disabled syntax stays literal text.
;;
;; Variable: etaf-doc-markdown-block-extensions
;; Block syntax the parser adds, as an alist of (NAME RECOGNIZER).
;; RECOGNIZER takes the remaining source lines and returns (BLOCK . REST) when
;; it claims them; `etaf-doc-markdown-extension-p' decides whether it runs.
;; Adding a block syntax means adding its recognizer here and its name to a
;; preset, which keeps one parser instead of forking it per dialect.
;;
;; Variable: etaf-doc-markdown-inline-extensions
;; Inline syntax the parser adds, as (NAME TRIGGER-CHAR RECOGNIZER).
;; TRIGGER-CHAR opens the syntax, or is nil for a recognizer that starts at a
;; word character such as an abbreviation.  RECOGNIZER takes (TEXT POSITION
;; END) and returns (NODE . NEXT) when it claims the text there.  The same
;; gating by `etaf-doc-markdown-extension-p' applies, so an inline extension a
;; preset does not enable never runs and its text stays as written.
;;
;; Variable: etaf-doc-markdown-emoji
;; Emoji shortcodes this renderer paints, as an alist of (NAME . CHARACTER).
;; A document writes `:tada:' and the page shows the character; a name outside
;; this table keeps its colons, and a time such as `12:30:45' is never a
;; shortcode.  Add entries here to teach the renderer more of them.
;;
;; Variable: etaf-doc-markdown-subscript-table
;; Characters a `~subscript~' run can be written with, as (CHAR . SCRIPT).
;; A character missing from the table keeps the source spelling, so the
;; construct paints what Unicode can express and never invents glyphs.
;;
;; Variable: etaf-doc-markdown-superscript-table
;; Characters a `^superscript^' run can be written with, as (CHAR . SCRIPT).
;; A character missing from the table keeps the source spelling, so the
;; construct paints what Unicode can express and never invents glyphs.
;;
;; Error: etaf-doc-markdown-error
;; Markdown document error
;; Signaled for an unknown dialect, a missing palette and unknown palette
;; keys; catch this condition with condition-case.
;;
;; Function: etaf-doc-cache-prune-directory (directory &optional max-bytes max-files)
;; Schedule lazy idle LRU pruning of DIRECTORY to stay under MAX-BYTES and MAX-FILES.
;; Coalesces repeated calls per DIRECTORY so cache writes never stall rendering.
;;
;; Function: etaf-doc-cache-http-url-p (url)
;; Return non-nil when URL is an http:// or https:// URL.
;;
;; Function: etaf-doc-cache-image-url-p (url)
;; Return non-nil when remote URL points to a supported image extension.
;;
;; Function: etaf-doc-cache-image-path (url)
;; Return the local cached image path for remote URL from memory, or nil.
;; Never touches the disk or network, so it is safe to call inside :render.
;;
;; Function: etaf-doc-cache-warm-urls (urls &optional directory)
;; Populate in-memory cache from disk for remote URLS in DIRECTORY without network I/O.
;; Return non-nil when at least one URL was newly warmed.
;;
;; Function: etaf-doc-cache-request-urls (urls on-ready &optional options)
;; Queue asynchronous downloads for uncached remote image URLS.
;; Invokes ON-READY when cached images arrive; OPTIONS accepts :directory,
;; :max-bytes, :max-files, :max-per-page and :live-p.
;;
;; Function: etaf-doc-qrcode-available-p ()
;; Return non-nil when qrencode is available on exec-path.
;;
;; Function: etaf-doc-qrcode-file (text &optional directory)
;; Return the deterministic cached PNG file path for QR payload TEXT.
;;
;; Function: etaf-doc-qrcode-request-texts (texts on-ready &optional directory)
;; Queue asynchronous qrencode jobs for uncached QR payloads in TEXTS.
;; Invokes ON-READY whenever a new PNG finishes writing.
;;
;; Function: etaf-doc-typeset-available-p ()
;; Return non-nil when the embedded QuickJS native typesetting module is ready.
;;
;; Function: etaf-doc-typeset-info ()
;; Return engine metadata plist when the native QuickJS module is loaded, else nil.
;;
;; Function: etaf-doc-typeset-options-json (kind palette &optional options)
;; Return the JSON options string for KIND (mermaid or math) from PALETTE.
;; OPTIONS accepts :font-size, :pixels, :cell-height, :scale, :font-family and :mono-family.
;;
;; Function: etaf-doc-typeset-request (key kind source options-json cache-dir on-done &optional on-error)
;; Queue SOURCE of KIND (mermaid or math) for KEY on the shared QuickJS worker.
;; Writes CACHE-DIR/KEY.svg and invokes (ON-DONE PATH) or (ON-ERROR MESSAGE FATAL-P).
;;
;; Function: etaf-doc-typeset-image-pixels (path)
;; Return (WIDTH . HEIGHT) in pixels for PATH via fast header inspection.
;;
;; Function: etaf-doc-typeset-grid-for-pixels (pixels max-columns &optional max-rows cell-metrics)
;; Return (COLUMNS . ROWS) fitting PIXELS inside MAX-COLUMNS and MAX-ROWS.
;;
;; Function: etaf-doc-assets-workspace-root (dir)
;; Return the canonical workspace root directory containing DIR.
;;
;; Function: etaf-doc-assets-safe-path (dir relpath)
;; Resolve RELPATH relative to DIR strictly inside its workspace root, or nil.
;;
;; Function: etaf-doc-assets-lang-for-path (path)
;; Infer a canonical syntax-highlight language tag from file PATH.
;;
;; Function: etaf-doc-assets-read-slice (dir relpath &optional options)
;; Safely read a bounded source slice from RELPATH under DIR's workspace root.
;; OPTIONS accepts :lines, :region, :section, :symbol, :context, :lang,
;; :default-lines, :max-bytes and :max-lines.
;;
;; Function: etaf-doc-assets-inspect-symbol (name &optional workspace-dir)
;; Return live Emacs symbol introspection plist for NAME.
;;
;; Function: etaf-doc-assets-project-tree (dir relpath &optional options)
;; Compute a bounded workspace directory tree for RELPATH under DIR.
;;
;; Function: etaf-doc-assets-git-log-async (dir on-done &optional options)
;; Run Git or Jujutsu log asynchronously for DIR's workspace and invoke ON-DONE.
;;
;; Function: etaf-doc-assets-git-diff-async (dir on-done &optional options)
;; Run Git or Jujutsu diff asynchronously for DIR's workspace and invoke ON-DONE.
;;
;; Function: etaf-doc-protocol-convert (type value)
;; Convert VALUE to document attribute TYPE, or return nil when incompatible.
;;
;; Function: etaf-doc-protocol-validate-value (key decl value source &optional style)
;; Return a diagnostic message when VALUE violates DECL for KEY from SOURCE.
;;
;; Function: etaf-doc-protocol-check-declarations (type decls derived error-symbol &optional allow-nil-default)
;; Validate attribute declarations DECLS of TYPE; signal ERROR-SYMBOL on invalid shape.
;;
;; Function: etaf-doc-protocol-define-node (registry type args contract error-symbol &optional shipped-p allow-nil-default)
;; Register or update node TYPE in hash table REGISTRY using plist ARGS.
;;
;; Function: etaf-doc-protocol-undefine-node (registry styles type)
;; Restore shipped TYPE or remove user TYPE from REGISTRY and STYLES.
;;
;; Function: etaf-doc-protocol-load-directory (directory &optional label)
;; Load every .el file in DIRECTORY in sorted filename order.
;;
;; Function: etaf-doc-widget-leaf-button (palette label on-press &rest opts)
;; Return a single-face interactive leaf control styled from PALETTE.
;;
;; Function: etaf-doc-widget-pill (palette label active-p on-press &optional help hover-p)
;; Return a compact toggle pill with LABEL styled from PALETTE.
;;
;; Function: etaf-doc-widget-status-badge (palette text variant)
;; Return a borderless soft-tinted status pill for TEXT in VARIANT.
;;
;; Function: etaf-doc-widget-notice (palette message &optional variant)
;; Return an inline notice or loading strip for MESSAGE styled from PALETTE.
;;
;; Function: etaf-doc-widget-progress-bars (palette rows available-width &optional options)
;; Render ROWS as a borderless editorial progress bar group from PALETTE.
;;
;; Function: etaf-doc-widget-line-chart (palette series available-width &optional options)
;; Render SERIES as a zero-wrap box-drawing line chart from PALETTE.
;;
;; Function: etaf-doc-widget-source-card (palette title meta code-view &optional options)
;; Render a single-frame living-doc code card around CODE-VIEW from PALETTE.

;;; Code:

(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-doc")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-doc.el" dir))
                                (file-exists-p (expand-file-name "etaf-doc.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc-markdown-parse)
(require 'etaf-doc-highlight)
(require 'etaf-doc-markdown)
(require 'etaf-doc-cache)
(require 'etaf-doc-qrcode)
(require 'etaf-doc-typeset)
(require 'etaf-doc-assets)
(require 'etaf-doc-protocol)
(require 'etaf-doc-widgets)

(provide 'etaf-doc)
;;; etaf-doc.el ends here
