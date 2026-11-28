# Composite Components

Three catalog components exist to compose existing contracts rather than introduce new ones. `etaf-date-picker` is the catalog's native text field plus a date contract, `etaf-command-palette` is a modal dialog around a selectable list, and `etaf-ui-qr-login` is a modal dialog around a painted code and a status line. All three are controlled and stateless: the caller owns the value, the command registry or the sign-in cycle, and the components only render and report. [Text Input Controls](ui-text-input-controls.md) defines the field they build on, [Overlays](ui-overlays.md) the dialog, [Navigation and Collections](ui-navigation-and-collections.md) the list, and [UI Overview](ui-overview.md) the shared contract. `etaf-ui-qr-paint` turns module rows into the text code the sign-in panel shows.

## The date picker

<!-- index: etaf-date-picker; ISO date; draft value; submit validation -->

#### Component: etaf-date-picker (&key value label placeholder on-change disabled bind)

Render a semantic date input on the catalog's native text field.

**Arguments.** VALUE is the controlled value: an ISO `YYYY-MM-DD` string or nil. LABEL defaults to `"Date"`. PLACEHOLDER (default `"YYYY-MM-DD"`) shows while the field is empty. ON-CHANGE receives the accepted value: a complete date string, or nil when the field is emptied. DISABLED removes editing, and BIND replaces VALUE and ON-CHANGE with a writable ref, following `etaf-text-input`.

**Semantics.** Editing is native and in place, exactly as the text field describes. A partial date is a draft: keystrokes that do not yet form a complete date are not reported, and the last accepted value stays. Submitting rejects an entry that is neither empty nor a complete date with a readable error naming the label, instead of writing it. The check is a shape check — four digits, two digits, two digits — so a well-formed but non-existent date such as `2026-13-01` is accepted as a value; enforcing calendar validity is the application's business rule.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when VALUE is neither nil nor an ISO `YYYY-MM-DD` string. Submitting an invalid draft signals `user-error` with the label and the expected form and leaves the value unchanged.

**Example.**

```elisp
(etaf-date-picker :value "2026-01-15" :label "Due"
                  :on-change (lambda (date) (setq due date)))
```

**See also.** `etaf-text-input`, `etaf-calendar`.

## The command palette

<!-- index: etaf-command-palette; modal list; command registry -->

#### Component: etaf-command-palette (&key open title items on-select on-close)

Compose a modal Dialog and List for caller-owned command selection.

**Arguments.** OPEN is a value, ref or computed. TITLE defaults to `"Command palette"`. ITEMS follows `etaf-list`: item plists with a unique `:key`, a nonempty string `:title` and an optional `:description` — a command's name is its title, not a menu label. ON-SELECT receives the chosen key and ON-CLOSE is required.

**Semantics.** While open, the palette is a centered modal dialog of `(ch 56)` rows wide whose body is one selectable list and whose default footer offers a close button; Escape and the header `x` request ON-CLOSE like any dialog. The palette owns no command registry, filtering or execution: the application supplies the items, decides what a key means and closes the dialog.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ON-CLOSE is not a function; the list's own item contract applies to ITEMS.

**Example.**

```elisp
(etaf-command-palette :open palette :on-close (lambda () (setf palette nil))
                      :items '((:key save :title "Save file")
                               (:key open :title "Open file"))
                      :on-select #'run-command)
```

**See also.** `etaf-list`, `etaf-dialog`.

## The scanned-code sign-in panel

<!-- index: etaf-ui-qr-paint; etaf-ui-qr-login; scannable code; sign-in panel -->

`etaf-ui-qr-paint` turns module rows into a text code, and `etaf-ui-qr-login` presents that code in a modal sign-in panel.  The application or its backend owns the rows, the request cycle and the account state; neither function reads the network or a file.

#### Function: etaf-ui-qr-paint (rows &optional quiet)

Paint module rows as a scannable code string.

**Arguments.** ROWS is a list of strings of `"0"` and `"1"`; a shorter row is blank past its end.  QUIET, when non-nil, is the number of blank modules drawn on every side; nil uses four.

**Semantics.** Two module rows share one text row through half blocks, so the code stays square in a text cell twice as tall as it is wide.  A pair of set modules becomes a full block, a set upper or lower module becomes that half block, and an empty pair becomes a space.  Every glyph keeps pure black on white in both palettes, because a scanner needs that contrast.  The caller or its backend supplies the rows; the function paints text and contacts nothing.

**Returns.** A string of newline-separated text rows, each glyph carrying the black-on-white face.

**Errors.** `error→ wrong-type-argument` with `(list-of-strings ROWS)` when ROWS is not a list of strings.

**Example.**

```elisp
(etaf-ui-qr-paint '("111" "101" "111"))
```

**See also.** `etaf-ui-qr-login`.

#### Component: etaf-ui-qr-login (&key open code status hint on-close)

Show a scanned-code sign-in panel over the calling application.

**Arguments.** OPEN is nil, t, a ref or a computed value; nil (the default) keeps the panel closed, and the caller owns visibility.  CODE is an optional painted-code string or ref, normally from `etaf-ui-qr-paint`; nil shows no code.  STATUS is an optional string or ref for the transport state or the site's own error.  HINT is an optional string explaining the confirmation step.  ON-CLOSE is a required zero-argument function, called while the panel is hidden as well.

**Semantics.** The panel composes `etaf-dialog`, so the page underneath keeps its content, dims once and stays readable, and the panel centers in the application's root canvas.  Mount it as the last child of the application shell rather than in a separate buffer.  On graphical displays with SVG support, a half-block code from `etaf-ui-qr-paint` is converted into a crisp square vector SVG image sized to fit the live viewport, avoiding East Asian ambiguous block-glyph widths, horizontal font gaps and tall-code clipping; text terminals and builds without SVG keep half-block text rendering.  The code sizes the panel: the caller paints whatever rows the service returned, so a wider or taller code makes a taller panel.  The status line sits above the code, so a transport message stays visible when a tall code fills the available height.  When the code is taller than the window allows, the panel keeps the window's height and scrolls, so every control stays reachable.  Escape, the header close control and the footer cancel button request ON-CLOSE; covered controls stay blocked while it is open.  The panel's title, close label and default hint are fixed Chinese strings (`扫码登录`, `取消` and `请用手机客户端扫码，并在手机上确认登录。`); only HINT can be replaced.  The caller owns the request cycle (obtaining and polling the code, reloading after confirmation) and the account state; the component sends no request and asks for no credentials.

**Returns.** A View while open; nothing while closed.

**Errors.** `error→ etaf-component-call-error` when OPEN is not nil, t, a ref or a computed value; CODE or STATUS is not nil, a string or a ref; or HINT is not nil or a string.  The composed dialog signals the same condition when ON-CLOSE is missing or not a function.

**Example.**

```elisp
(etaf-ui-qr-login :open open
                  :code (etaf-ui-qr-paint rows)
                  :status status
                  :on-close (lambda () (setf open nil)))
```

**See also.** `etaf-ui-qr-paint`, `etaf-dialog`, `etaf-ref`.

## Markdown document rendering

<!-- index: markdown; document tree; palette; render callback -->

Markdown document rendering turns Markdown text into ordinary ETAF Views for a previewer, a manual reader or any other document view.  It works in two steps: `etaf-ui-markdown-parse` parses the text into a block tree that carries no presentation facts, and the render functions turn that tree plus an environment plist into Views.  Both steps are pure functions without a buffer, runtime state or file, so one code path serves headless tests and a mounted Component alike.

#### Function: etaf-ui-markdown-parse (text &optional flavor)

Parse Markdown TEXT into a document plist.

**Arguments.** TEXT is the Markdown source.  FLAVOR selects the dialect: a name from `etaf-ui-markdown-flavors` (`gfm` is the default), a feature plist overriding individual extension flags, or nil for `etaf-ui-markdown-flavor`.

**Semantics.** Parsing covers CommonMark block and inline structure plus the GitHub extensions: pipe tables, task list items, strikethrough, bare autolinks, footnotes and alert blocks; YAML front matter is stripped into document metadata.  A block is a plist whose `:type` is `heading`, `paragraph`, `code-block`, `blockquote`, `list`, `table`, `thematic-break`, `html-block` or `footnote-def`; an inline's `:type` is `text`, `code`, `emph`, `strong`, `strike`, `link`, `image`, `autolink`, `footnote-ref`, `html` or `break`.  The tree carries no presentation facts: the render functions own every style and ETAF node choice.  Headings get stable unique anchors, and link reference definitions and footnote definitions are collected while blocks are read and resolved into inline nodes.  Parsing is pure Elisp and reads no buffer, file or network.

**Returns.** A document plist: `:meta` (front matter alist), `:title`, `:children` (top-level blocks with heading anchors; each top-level block also carries `:begin` and `:end`, its half-open character range in TEXT, so a caller maps an edit back to the block that holds it), `:outline` (document-order `(LEVEL TEXT ID)`), `:footnotes` (with `:label`, `:number` and `:children`) and `:features` (the resolved extension plist).

**Errors.** An unknown dialect name signals `error→ etaf-ui-markdown-error`.

**Example.**

```elisp
(etaf-ui-markdown-parse "# Title\n\nBody.\n")
```

**See also.** `etaf-ui-markdown-view-blocks`, `etaf-ui-markdown-flavors`.

#### Function: etaf-ui-markdown-view-block (block env)

Render one block as an ETAF View, or nil when it has no rendered content.  BLOCK is one top-level block of `etaf-ui-markdown-parse` and ENV is the environment plist described by `etaf-ui-markdown-view-blocks`.  A block that expands to several Views is wrapped in one column, so callers own one node per block for scrolling, selection or per-block references.

#### Function: etaf-ui-markdown-view-blocks (blocks env &optional tight)

Return the list of Views for BLOCKS in document order, or nil for empty input.  Consecutive blocks are separated by one blank line unless TIGHT is non-nil.  The list carries no container, so callers wrap it themselves; render the `:footnotes` Views and append them when the document's footnote definitions belong in the flow.  ENV's `:palette` is required: an alist of semantic color keys (`:ink`, `:muted`, `:faint`, `:heading`, `:accent`, `:accent-soft`, `:panel`, `:code-bg` (optional; inline code and code blocks use it when present and fall back to `:panel`), `:border`, `:quote-bg`, `:quote-bar`, `:table-header`, `:table-stripe`, `:heading-rule` (optional; the rule under a level-1 and level-2 heading falls back to `:border`), `:ok`, `:ok-soft`, `:warn`, `:warn-soft`, `:danger`, `:danger-soft`, `:important` and `:important-soft`); every color is read through it, so a palette change never leaks a half-updated set of colors, and an unknown key signals `error→ etaf-ui-markdown-error`.  The remaining entries are callbacks: `:open-link` receives a link URL, and every rendered link also carries the `:accent-soft` palette color as its pointer-hover face; `:footnote-jump` receives a footnote label; `:footnote-ref (label)` returns a host `:ref` symbol attached to the footnote definition box; `:footnote-back (label)` appends a clickable `↩` return control to each footnote definition; `:on-copy (kind text lines)` is notified after the code block copy action copies TEXT; `:render-media (kind node env)` returns the View for media, where KIND is `image`, `video`, `inline-image`, `table-image` or `html-media` (for `table-image`, ENV supplies `:table-cell` t, `:width` and `:table-cell-width` set to the cell's inner content columns, and `:table-cell-align`), and without it media falls back to its alt text or URL; `:render-code-block (block env)` may return a View for a code block and nil keeps the default fenced block; `:code-link (text)` is called with the text of every code span and may return a URL or a (URL . HELP) cons to make that span a link, which keeps the code style and calls `:open-link` with URL when activated, its help echo being HELP or URL; `:alert-labels` overrides the callout labels kind by kind; and `:features`, the document's resolved extension plist, gates whether alert blocks render as callouts; `:line-grid` non-nil keeps every line at the standard line height, for documents that scroll beside other content: headings and footnote references keep the body font size, a level-1 heading uses the accent color and a level-2 heading gains a left accent bar, so scrolling never changes the height of the lines it reveals.  Without `:line-grid` a level-1 and level-2 heading draws a rule from `:heading-rule` under its text, which sets the level apart even in a theme whose heading color is its body color; a fenced block with a language opens with a header strip that holds the language and closes with a rule, so the label frames the block instead of floating over its first line; a quote paints its plain text in `:muted` while links and code keep the colors they set for themselves.  A table is one grid: its tracks are resolved once, so every row shares the same column boundaries and a wide cell in one row cannot push that row off the column lines. Columns share the width in proportion to their widest cell and keep a floor: a run of narrow characters, such as a word or a code span, stays whole, while a run of wide characters counts at a fixed cap of 12 cells, because a line may break between them. Longer cells wrap at word boundaries, and a container too narrow for the floors lets the table overflow rather than squeezing columns below their words.  A table draws its outer border, a rule between every pair of columns and a rule between rows, its header row closed by a stronger rule than the rows, and it drops the zebra stripe when the palette gives the stripe and the header row the same surface.  HTML comments render as nothing.

#### Variable: etaf-ui-markdown-flavor

Default markdown dialect of `etaf-ui-markdown-parse`.

**Semantics.** An explicit FLAVOR argument wins over it.  `gfm` enables the GitHub extensions and front matter, `commonmark` parses the core specification only, and a feature plist toggles individual extensions.

**See also.** `etaf-ui-markdown-parse`, `etaf-ui-markdown-flavors`.

#### Variable: etaf-ui-markdown-flavors

Named dialects and the extension flags they enable.

**Semantics.** `commonmark` is the CommonMark core; `gfm` adds the GitHub extensions the renderer also treats as its default: tables, task lists, strikethrough, bare autolinks, footnotes and alert blocks, plus front matter, which is a document convention rather than a markdown extension.  `etaf` reads definition lists, sub- and superscript, abbreviations, `$` math, emoji shortcodes, `==highlighted==` runs, `::icon::`, `:kbd[keys]` and `:badge[text]` on top of `gfm`.

**See also.** `etaf-ui-markdown-parse`.

#### Function: etaf-ui-markdown-extension-p (name)

Return non-nil when the document being parsed enables extension NAME.

**Parameters.** NAME is a symbol from a dialect's `:extensions` list, such as `emoji` or `definition-list`.

**Returns.** t when the extension runs, nil otherwise.

**Semantics.** A parser extension calls it to decide whether its own syntax runs at all; disabled syntax stays literal text exactly as CommonMark reads it, which lets one parser carry every dialect instead of forking per dialect. It reads the state of the parse in progress, so calling it outside a parse has no meaning.

**See also.** `etaf-ui-markdown-block-extensions`, `etaf-ui-markdown-inline-extensions`, `etaf-ui-markdown-flavors`.

#### Variable: etaf-ui-markdown-block-extensions

Block syntax the parser adds, as an alist of (NAME RECOGNIZER).

**Semantics.** RECOGNIZER takes the remaining source lines and returns (BLOCK . REST) when it claims them; `etaf-ui-markdown-extension-p` decides whether it runs, so a block syntax a dialect does not enable never runs and its text stays literal, exactly as CommonMark reads it. Adding a block syntax means adding its recognizer here and its name to a dialect, which keeps one parser instead of forking it per dialect.

**See also.** `etaf-ui-markdown-inline-extensions`, `etaf-ui-markdown-flavors`.

#### Variable: etaf-ui-markdown-inline-extensions

Inline syntax the parser adds, as (NAME TRIGGER-CHAR RECOGNIZER).

**Semantics.** TRIGGER-CHAR opens the syntax, or is nil for a recognizer that starts at a word character such as an abbreviation. RECOGNIZER takes (TEXT POSITION END) and returns (NODE . NEXT) when it claims the text there. The same gating by `etaf-ui-markdown-extension-p` applies, so an inline extension a dialect does not enable never runs and its text stays as written.

**See also.** `etaf-ui-markdown-block-extensions`, `etaf-ui-markdown-flavors`.

#### Variable: etaf-ui-markdown-emoji

Emoji shortcodes this renderer paints, as an alist of (NAME . CHARACTER).

**Semantics.** A document writes `:tada:` and the page shows the character; a name outside this table keeps its colons, and a time such as `12:30:45` is never a shortcode. Add entries here to teach the renderer more of them.

**See also.** `etaf-ui-markdown-flavors`.

#### Variable: etaf-ui-markdown-subscript-table

Characters a `~subscript~` run can be written with, as (CHAR . SCRIPT).

**Semantics.** A character missing from the table keeps the source spelling, so the construct paints what Unicode can express and never invents glyphs.

**See also.** `etaf-ui-markdown-superscript-table`, `etaf-ui-markdown-flavors`.

#### Variable: etaf-ui-markdown-superscript-table

Characters a `^superscript^` run can be written with, as (CHAR . SCRIPT).

**Semantics.** A character missing from the table keeps the source spelling, so the construct paints what Unicode can express and never invents glyphs.

**See also.** `etaf-ui-markdown-subscript-table`, `etaf-ui-markdown-flavors`.

#### Variable: etaf-ui-markdown-code-renderers

Renderers for one fenced language, as an alist of (LANGUAGE . FUNCTION).

**Semantics.** FUNCTION receives the block and ENV and returns a View, or nil to keep the default. A language that needs a program — a diagram language, a typesetter — belongs here, so the parser stays pure and a missing program only means that block shows its source. ENV's `:render-code-block' is consulted first, which lets one caller override the table without changing it.

**Returns.** Not applicable; the variable holds the renderer table.

**See also.** `etaf-ui-markdown-highlight-languages`, `etaf-ui-markdown-view-blocks`.

#### Variable: etaf-ui-markdown-highlight-languages

Languages whose fenced code is colored with an Emacs mode, as (LANGUAGE . MODE).

**Semantics.** A language with a mode entry here is colored with that mode; a language outside the table paints as plain text and loads no mode. Adding a language means adding one mapping, and coloring still happens only while rendering.

**Returns.** Not applicable; the variable holds the language-to-mode mapping.

**See also.** `etaf-ui-markdown-code-renderers`, `etaf-ui-markdown-view-blocks`.

#### Variable: etaf-ui-markdown-gfm-features

The feature plist GitHub Flavored Markdown enables as a whole.

**Semantics.** It spells every flag out: front matter, tables, task lists, strikethrough, bare autolinks, footnotes and alert blocks. A dialect writes its own flags, so a later change to GFM never silently changes what an older dialect meant; a dialect of your own can start from it.

**Returns.** Not applicable; the variable holds the feature plist.

**See also.** `etaf-ui-markdown-flavors`, `etaf-ui-markdown-parse`.

#### Error: etaf-ui-markdown-error

The condition of a rejected markdown document operation.

**Semantics.** An unknown dialect name signals it during parsing; a missing `:palette` or a color key the palette does not define signals it during rendering, before any View is published.  The data is a list carrying a description string.

**Recovery.** A failure produces no half-rendered document: a failed parse has no block tree and a failed render publishes no View.  Fix the dialect or supply the palette keys and call again.

**See also.** `etaf-ui-markdown-parse`, `etaf-ui-markdown-view-blocks`.

#### Function: etaf-ui-markdown-highlight-code (language text)

Return runs colouring TEXT as LANGUAGE, or nil when it cannot be coloured.

**Parameters.** LANGUAGE is a fenced language name; TEXT is the block body.

**Returns.** A list of `(:text STRING :props PLIST)` covering TEXT in order, with PLIST an Ebox style plist; nil means paint the block in one colour.

**Semantics.** It runs the language's own major mode over the text, so keywords, strings, comments and numbers come out as the source buffer shows them. The answer is cached per (LANGUAGE . TEXT), so the next repaint costs one lookup.

**See also.** `etaf-ui-markdown-highlight-languages`, `etaf-ui-markdown-code-renderers`.

#### Function: etaf-ui-markdown-math-text (source)

Return SOURCE, a TeX formula, written as plain text.

**Parameters.** SOURCE is the formula's source text.

**Returns.** A string.

**Semantics.** This is a typographic approximation rather than a typesetter: command names become their symbols, `\frac{a}{b}` becomes `a/b`, `\sqrt{x}` becomes `√(x)`, and `^{}` and `_{}` become the Unicode letters of that position. Anything it does not know keeps its own characters, so a formula can never turn into a row of noise.

**See also.** `etaf-ui-markdown-flavors`, `etaf-ui-markdown-parse`.

## Shared document infrastructure (`etaf-doc`)

<!-- index: etaf-doc; document cache; qrcode; QuickJS typesetting; living document assets; document protocol; editorial widgets -->

The `etaf-doc` package collects the shared non-syntax infrastructure used across document viewers (`etaf-ui-markdown-*` plus six reusable subsystems): bounded LRU remote-image caching, async QR code generation, native QuickJS Mermaid and MathJax typesetting, sandboxed workspace living-document assets, a schema-checked custom node protocol, and editorial UI widgets.

### Document cache

#### Function: etaf-doc-cache-prune-directory (directory &optional max-bytes max-files)

Schedule lazy idle LRU pruning of DIRECTORY to keep total disk usage under MAX-BYTES and MAX-FILES. Repeated calls for the same DIRECTORY coalesce onto one idle timer so cache writes never stall rendering.

#### Function: etaf-doc-cache-http-url-p (url)

Return non-nil when URL is a string beginning with `http://` or `https://`.

#### Function: etaf-doc-cache-image-url-p (url)

Return non-nil when remote URL points to a supported image file extension.

#### Function: etaf-doc-cache-image-path (url)

Return the local cached image file path for remote URL from the in-memory table, or nil. Performs zero disk or network I/O so it is safe to call inside `:render`.

#### Function: etaf-doc-cache-warm-urls (urls &optional directory)

Populate the in-memory image cache from existing files on disk in DIRECTORY for remote URLS without network I/O, returning non-nil when at least one entry was newly warmed.

#### Function: etaf-doc-cache-request-urls (urls on-ready &optional options)

Queue asynchronous downloads for uncached remote image URLS and invoke ON-READY when images arrive. OPTIONS is a plist accepting `:directory`, `:max-bytes`, `:max-files`, `:max-per-page` and `:live-p`.

### QR code generation

#### Function: etaf-doc-qrcode-available-p ()

Return non-nil when the `qrencode` executable is available on `exec-path`.

#### Function: etaf-doc-qrcode-file (text &optional directory)

Return the deterministic cached PNG path for QR payload TEXT under DIRECTORY (or the default QR cache directory).

#### Function: etaf-doc-qrcode-request-texts (texts on-ready &optional directory)

Queue asynchronous `qrencode` subprocesses for uncached QR payloads in TEXTS under DIRECTORY, invoking ON-READY whenever a PNG finishes writing.

### Native QuickJS typesetting

#### Function: etaf-doc-typeset-available-p ()

Return non-nil when the embedded QuickJS + Pele + MathJax native dynamic module is loaded and ready.

#### Function: etaf-doc-typeset-info ()

Return engine metadata plist from the loaded QuickJS native module, or nil when unavailable.

#### Function: etaf-doc-typeset-options-json (kind palette &optional options)

Return the JSON options payload string for KIND (`mermaid` or `math`) derived from semantic color PALETTE. OPTIONS accepts `:font-size`, `:pixels`, `:cell-height`, `:scale`, `:font-family` and `:mono-family`.

#### Function: etaf-doc-typeset-request (key kind source options-json cache-dir on-done &optional on-error)

Queue SOURCE of KIND (`mermaid` or `math`) under KEY on the shared background QuickJS worker, writing `CACHE-DIR/KEY.svg` and invoking `(ON-DONE PATH)` on success or `(ON-ERROR MESSAGE FATAL-P)` on failure.

#### Function: etaf-doc-typeset-image-pixels (path)

Return `(WIDTH . HEIGHT)` in pixels for image file PATH via fast header inspection, or nil when unreadable.

#### Function: etaf-doc-typeset-grid-for-pixels (pixels max-columns &optional max-rows cell-metrics)

Return `(COLUMNS . ROWS)` preserving the aspect ratio of PIXELS `(WIDTH . HEIGHT)` within MAX-COLUMNS and optional MAX-ROWS using CELL-METRICS `(CHAR-WIDTH . LINE-HEIGHT)`.

### Workspace living-document assets

#### Function: etaf-doc-assets-workspace-root (dir)

Return the canonical workspace root directory containing DIR (stopping at `.git`, `.jj`, or DIR itself).

#### Function: etaf-doc-assets-safe-path (dir relpath)

Resolve RELPATH relative to DIR strictly inside its canonical workspace root, returning nil for path traversal or escapes outside the root.

#### Function: etaf-doc-assets-lang-for-path (path)

Infer a canonical syntax-highlighting language tag string from file PATH's extension or basename.

#### Function: etaf-doc-assets-read-slice (dir relpath &optional options)

Safely read a bounded source slice from RELPATH under DIR's workspace root. OPTIONS accepts `:lines`, `:region`, `:section`, `:symbol`, `:context`, `:lang`, `:default-lines`, `:max-bytes` and `:max-lines`.

#### Function: etaf-doc-assets-inspect-symbol (name &optional workspace-dir)

Return a live Emacs symbol introspection plist for NAME (kind, signature, docstring, value preview and source location relative to WORKSPACE-DIR).

#### Function: etaf-doc-assets-project-tree (dir relpath &optional options)

Compute a bounded workspace directory tree structure for RELPATH under DIR. OPTIONS accepts `:depth` and `:max-entries`.

#### Function: etaf-doc-assets-git-log-async (dir on-done &optional options)

Run Git or Jujutsu log asynchronously for DIR's workspace and invoke `(ON-DONE RESULT)` when finished. OPTIONS accepts `:limit` and `:path`.

#### Function: etaf-doc-assets-git-diff-async (dir on-done &optional options)

Run Git or Jujutsu diff asynchronously for DIR's workspace and invoke `(ON-DONE RESULT)` when finished. OPTIONS accepts `:rev` and `:path`.

### Document node protocol

#### Function: etaf-doc-protocol-convert (type value)

Convert VALUE to document attribute schema TYPE (`string`, `integer`, `number`, `boolean`, `keyword`, `symbol`, `list`, or `(enum ...)`), returning nil when incompatible.

#### Function: etaf-doc-protocol-validate-value (key decl value source &optional style)

Return a diagnostic message string when VALUE violates attribute declaration DECL for KEY from SOURCE, or nil when valid. STYLE selects message formatting.

#### Function: etaf-doc-protocol-check-declarations (type decls derived error-symbol &optional allow-nil-default)

Validate attribute declarations DECLS and DERIVED keys of node TYPE, signaling ERROR-SYMBOL on invalid declaration shapes unless ALLOW-NIL-DEFAULT permits nil defaults.

#### Function: etaf-doc-protocol-define-node (registry type args contract error-symbol &optional shipped-p allow-nil-default)

Register or update node TYPE in hash table REGISTRY using definition plist ARGS validated against CONTRACT, signaling ERROR-SYMBOL on violation. SHIPPED-P marks built-in definitions so undefining can restore them.

#### Function: etaf-doc-protocol-undefine-node (registry styles type)

Restore a shipped definition for TYPE or remove a user-defined TYPE from REGISTRY and STYLES hash tables.

#### Function: etaf-doc-protocol-load-directory (directory &optional label)

Load every `.el` extension file in DIRECTORY in sorted filename order, using LABEL in diagnostic messages.

### Editorial widgets

#### Function: etaf-doc-widget-leaf-button (palette label on-press &rest opts)

Return a single-face interactive leaf control with LABEL and ON-PRESS styled from PALETTE. OPTS accepts `:color`, `:background`, `:hover-bg`, `:help`, `:active`, `:ref` and `:padding`.

#### Function: etaf-doc-widget-pill (palette label active-p on-press &optional help hover-p)

Return a compact toggle pill with LABEL styled from PALETTE, reflecting ACTIVE-P and invoking ON-PRESS with optional HELP tooltip and HOVER-P hover styling.

#### Function: etaf-doc-widget-status-badge (palette text variant)

Return a borderless soft-tinted status pill displaying TEXT in semantic VARIANT (`ok`, `warn`, `danger`, `important`, `accent` or `muted`) from PALETTE.

#### Function: etaf-doc-widget-notice (palette message &optional variant)

Return an inline notice or loading strip displaying MESSAGE styled from PALETTE in optional VARIANT.

#### Function: etaf-doc-widget-progress-bars (palette rows available-width &optional options)

Render ROWS as a borderless editorial progress bar group fitted to AVAILABLE-WIDTH using PALETTE and optional display OPTIONS.

#### Function: etaf-doc-widget-line-chart (palette series available-width &optional options)

Render SERIES as a zero-wrap box-drawing line chart fitted to AVAILABLE-WIDTH using PALETTE and optional axis OPTIONS.

#### Function: etaf-doc-widget-source-card (palette title meta code-view &optional options)

Render a single-frame living-document source card wrapping CODE-VIEW with TITLE, META badge text and optional action OPTIONS from PALETTE.

## Errors and recovery

- The date picker separates a draft from an error: text that is not yet a complete date is simply not reported, and submitting it signals `user-error` without writing the value; cancelling the session restores the activation value.
- The palette composes the list's validation: a malformed item list fails the render with `etaf-component-call-error` before any surface appears, and a missing close callback fails the same way.
- The sign-in panel validates its props and composes the dialog's own close-callback check before any surface appears; backend failures belong in STATUS, because the panel sends no request and has no transport error of its own.
- All three components are stateless: a rejected input leaves the caller's value and the mounted instance as they were.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery).

```elisp :run
(etaf-view
 (column :width '(ch 60) :height '(lh 18) :item-gap '(lh 1)
   (etaf-date-picker :value "2026-01-15" :label "Due")
   (etaf-command-palette :open t :on-close #'ignore :on-select #'ignore
                         :items '((:key save :title "Save file")))))
```
