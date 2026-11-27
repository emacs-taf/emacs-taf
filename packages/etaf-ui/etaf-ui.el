;;; etaf-ui.el --- Official ETAF component catalog  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.13
;; Keywords: ui, convenience
;; Package-Requires: ((emacs "29.1") (etaf "0.3.8"))
;; URL: https://github.com/emacs-taf/etaf-ui

;;; Commentary:

;; A catalog of ready-made ETAF components: buttons, inputs, tables,
;; sheets, media, navigation and window chrome, all built on Ebox boxes.
;;
;; Public API
;;
;; Load this package with (require 'etaf-ui) after adding the repository
;; root to load-path.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions.  The ETAF Reference Manual contains workflows.
;;
;; Every Component is keyboard operable through ETAF's key layer.  Tabs,
;; segmented and radio selectors, desktop bars, window controls, tables,
;; lists, trees, calendars, breadcrumbs, steps and tile grids are each one
;; Tab stop entered at their selected item; arrows and C-n/C-p/C-b/C-f move
;; inside them.  Dialogs, drawers, popovers and the media viewer are modal
;; key scopes closed by Escape.  `?' opens read-only key help listing the
;; keys in scope.
;;
;; Function: etaf-ui-color-mix (from to amount)
;;;###autoload (autoload 'etaf-ui-color-mix "etaf-ui" nil nil)
;; Return FROM mixed AMOUNT of the way toward TO, both #RRGGBB strings.
;; AMOUNT is a fraction between 0 and 1.  A colour written in any other
;; spelling is returned unchanged, so a Theme that names a colour stays
;; usable.  Applications use it to derive hover, selection and surface steps
;; from the frame's own colours instead of carrying a second palette.
;;
;; Function: etaf-ui-color-contrast (from to)
;;;###autoload (autoload 'etaf-ui-color-contrast "etaf-ui" nil nil)
;; Return the WCAG contrast ratio between FROM and TO, from 1 to 21.  Both
;; are #RRGGBB strings; a colour in any other spelling answers 0, which reads
;; as a colour nobody measured.  Applications use it to check a derived
;; hover, selected or code colour against the surface it is painted on.
;;
;; Function: etaf-ui-color-legible (color background &optional ratio)
;;;###autoload (autoload 'etaf-ui-color-legible "etaf-ui" nil nil)
;; Return COLOR made readable on BACKGROUND, keeping its hue.  COLOR is mixed
;; toward black on a light surface and toward white on a dark one until it
;; reaches RATIO (default 4.5, the WCAG AA ratio for body text).  A colour
;; that already passes, and one written in another spelling, comes back
;; unchanged.  A page that renders with colours from elsewhere, such as the
;; frame's syntax faces, passes them through this so they stay readable on its
;; own surface.
;;
;; Function: etaf-ui-theme-tokens (palette)
;;;###autoload (autoload 'etaf-ui-theme-tokens "etaf-ui" nil nil)
;; Return the catalog's color Theme tokens for application PALETTE, a plist
;; of #RRGGBB roles: `:bg' and `:fg' are required; `:panel', `:track',
;; `:border', `:muted', `:dim', `:accent', `:accent-fg', `:accent-soft' and
;; the status roles `:success', `:warning', `:danger', `:info' and `:important'
;; (each with `-bg' and `-border' variants) are derived when omitted.  Append
;; the result to the application's own Theme keys and provide it with
;; `etaf-theme-provide'; a key placed before the result overrides it, since
;; the first value of a key wins.  An unknown role, a non-string value or a
;; missing `:bg' or `:fg' signals `wrong-type-argument'.
;;
;; Component: etaf-button (&key label on-press disabled id ref class color bgcolor border padding font-size font-weight tab-index aria-label aria-selected help-echo hover-content hover-group pointer use variant)
;; Parameters:
;; :label — Display value/ref/computed; default nil (empty). Supply a useful name.
;; :on-press — Optional function (); default nil. Called on activation.
;; :disabled — Optional flag; default nil. Suppress activation and Tab focus.
;; :variant — Optional primary/secondary/ghost; nil selects primary.
;; :aria-label — Optional accessible string; nil uses the rendered label.
;; :aria-selected — Optional flag; default nil. Selected paint suppresses hover.
;; :color, :bgcolor — Optional Host colors/reactive sources; nil uses the Theme.
;; :border, :padding — Optional Host lengths/border; nil uses Theme/variant defaults.
;; :font-size, :font-weight — Optional Host typography; nil inherits size and uses variant weight.
;; :tab-index — Optional integer; nil uses 0 unless disabled; negative skips Tab.
;; :id, :ref, :class — Optional Host identity, reference and extra classes; default nil.
;; :help-echo, :hover-content, :hover-group — Optional Host help/hover capabilities; default nil.
;; :pointer — Optional Host pointer; nil uses arrow when enabled.
;; :use — Optional ETAF Behavior composition; default nil.
;;
;; Render a standard pressable Button with a committed callback.
;;
;; DISABLED removes the callback and default focus tab index.  VARIANT is
;; `primary' (accent fill, bold, default), `secondary' (soft accent tint) or
;; `ghost' (inherits its surface, narrower padding); every variant is a
;; borderless single-row pill by default. Optional Theme tokens
;; `:ui-button-padding', `:ui-button-radius' and `:ui-button-border' set the
;; shared control geometry, falling back to the variant padding, `(px 0)'
;; radius and no border. Explicit presentation props take precedence.
;; The class carries the variant name, and a Button never shrinks below its label or wraps it, so a narrow flex line
;; moves the whole Button instead of splitting its text.  A hover fill comes
;; from the variant's hover token, or from a caller-supplied surface when it
;; has one, while the pointer is over an enabled, unselected Button;
;; `aria-selected' controls (tabs, segments) keep their selected
;; presentation. A selected `ghost' uses the secondary Theme colors while
;; preserving its padding, font weight and size; callers keep one variant
;; across selection changes rather than switching geometry-bearing variants.
;; Keyboard focus underlines the label and fills a Button
;; that has no surface of its own, so Tab navigation stays visible without
;; moving geometry.
;; Presentation props remain caller-overridable.  Runtime publishes ON-PRESS with the visible Button,
;; so a failed render keeps the previous callback and its captured values.
;; ID reaches the rendered Host so anchor-based surfaces can reference the
;; Button by identity.
;; Native root attributes :pointer, :help-echo, :hover-style and
;; :hover-content request Ebox text-property capabilities.
;; interaction feedback; explicit nil blocks inherited capabilities.
;; Use inside (etaf-view (etaf-button ...)); keyword arguments are component props.
;; A default slot replaces the visible label with ordinary non-interactive
;; content (for example, a title and description). LABEL or ARIA-LABEL still
;; names the single focus/activation target; nested controls are inappropriate.
;;
;; Component: etaf-checkbox (&key checked label on-change disabled bind)
;; Parameters:
;; :checked — Boolean/ref/computed; default nil (unchecked), unless :bind supplies it.
;; :label — Optional display value/ref/computed; default nil (empty caption).
;; :on-change — Optional function (next-boolean); default nil. Store the requested state.
;; :disabled — Optional flag; default nil. Suppress activation and bound writes.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :checked and :on-change, even nil.
;;
;; Render a controlled Checkbox whose next value is sent to ON-CHANGE.
;; Alternatively, pass an existing writable ref as :bind; its current value
;; supplies CHECKED and the next boolean is written to the same ref.  Non-nil
;; BIND rejects explicitly supplied CHECKED or ON-CHANGE, including nil, with
;; `etaf-component-call-error'.  Nil BIND leaves the explicit controlled
;; interface active.
;; Native root attributes request Ebox pointer, help and hover feedback,
;; using the same forwarding contract as Button.
;; No additional state is created. External ref writes update the control;
;; disabled activation cannot write. :on-press remains an additive observer.
;; Failed publication retains the old binding target, and unmount releases
;; the control's handlers and subscriptions without owning the caller's ref.
;; Use inside (etaf-view (etaf-checkbox ...)); keyword arguments are component props.
;;
;; Component: etaf-tile-grid (&key rows columns cell-width cell-height cell-background cell-color cell-text cell-label cell-image cell-ref on-cell-press on-cell-focus)
;; Parameters:
;; :rows, :columns — Required positive integers. Grid dimensions in cells.
;; :cell-width, :cell-height — Positive integers; defaults 2 character columns and 1 text line per cell.
;; :cell-background, :cell-color — Optional pure functions (row column) returning color/Theme token/nil; default nil (inherit).
;; :cell-text — Optional pure function (row column) returning one line fitting :cell-width; default nil (space).
;; :cell-label — Optional pure function (row column) returning an accessible string; default nil ("Cell r,c").
;; :cell-image — Optional pure function (row column) returning local image path/descriptor/nil; default nil (use text).
;; :cell-ref — Optional pure function (row column) returning distinct supported Host references; default nil (instance-local identities).
;; :on-cell-press, :on-cell-focus — Optional functions (row column), both zero-based; default nil. Activation or focus notification, not data accessors.
;;
;; Render ROWS by COLUMNS fixed cells with stable coordinate identities.
;; Dimensions, CELL-WIDTH (character columns, default 2) and CELL-HEIGHT
;; (text lines, default 1) are positive integers.
;; Cell dimensions remain fixed when the containing viewport changes.
;; Optional callbacks take zero-based ROW and COLUMN. CELL-BACKGROUND returns
;; a color or nil; CELL-COLOR supplies the foreground color (nil inherits).
;; Both color callbacks may return deferred Theme tokens.
;; CELL-TEXT returns one line fitting CELL-WIDTH (default space).
;; CELL-IMAGE returns a local file path, an Emacs image descriptor (including
;; generated SVG) or nil. An image fills the fixed cell via ETAF's image Host;
;; nil uses CELL-TEXT instead. Supply aspect-correct sources and CELL-LABEL
;; for media; source decoding failures use the image Host's placeholder.
;; CELL-LABEL returns a string for accessibility and help (default "Cell r,c").
;; Read caller refs inside those callbacks to retain property/text boundaries.
;; ON-CELL-PRESS handles keyboard and mouse activation. Without it cells are
;; read-only. ON-CELL-FOCUS reports ROW/COLUMN when focus enters a cell, so
;; callers can paint a media focus indicator without another focus model.
;; CELL-REF returns a distinct supported Host reference per cell;
;; omitted references are instance-local. Caller owns data and lifecycle;
;; the grid does not run timers or maintain a second selection/board state.
;; Invalid dimensions, callbacks or text signal etaf-component-call-error.
;; Use (etaf-view (etaf-tile-grid :rows 8 :columns 12 ...)).
;;
;; Component: etaf-svg-stage (&key rows columns cell-width cell-height tile-width tile-height cell-svg sprites cell-text cell-background cell-color cell-label cell-ref on-cell-press on-cell-focus graphic)
;; Parameters:
;; :rows, :columns — Required positive integers. Grid dimensions in cells.
;; :cell-width, :cell-height — Positive integers; defaults 2 character columns and 1 text line per cell.
;; :tile-width, :tile-height — Optional positive integer pixel dimensions per tile; nil derives from cell size (8px/ch, 16px/lh).
;; :cell-svg — Required pure function (row column tile-width tile-height) returning SVG inner markup in stage coordinates.
;; :sprites — Optional sprite list, reactive source or zero-argument function returning plists (:x :y :width :height :markup) in stage pixel coordinates.
;; :cell-text, :cell-background, :cell-color, :cell-label, :cell-ref, :on-cell-press, :on-cell-focus — Optional tile-grid coordinate callbacks; text and color callbacks serve text terminals.
;; :graphic — Optional auto (default), t or nil. Selects SVG tile rendering or text fallback.
;;
;; Render a fixed tiled SVG stage with dirty-tile sprite compositing over
;; `etaf-tile-grid'.  Each cell clips the shared stage coordinate space with
;; its own viewBox `(col*tw row*th tw th)'; only tiles whose rectangle overlaps
;; a sprite's bounding box rebuild their image descriptor when the sprite moves,
;; while untouched tiles reuse cached descriptors.  On text displays (or when
;; `:graphic' is nil), the stage falls back cleanly to `:cell-text' and cell
;; colors without changing layout or grid navigation.
;; Invalid dimensions, callbacks or sprite records signal `etaf-component-call-error'.
;; Use (etaf-view (etaf-svg-stage :rows 4 :columns 4 :cell-svg ... :sprites ...)).
;;
;; Component: etaf-playing-card (&key rank suit face-down empty selected disabled on-press label ref columns lines)
;; Parameters:
;; :rank — Optional one-line string of at most 3 display columns; default nil. No tabs/newlines.
;; :suit — spades/hearts/clubs/diamonds/nil; default nil.
;; :face-down, :empty, :selected, :disabled — Optional flags; default nil. Hide face, show pile, mark selection, or disable activation.
;; :on-press — Optional function (); default nil (noninteractive).
;; :label — Optional accessible string; nil derives a safe card/pile name. Never put hidden card information in it.
;; :ref — Optional Host reference; default nil. Addresses the whole card.
;; :columns, :lines — Integer width >= 7 and height >= 1; defaults 9 character columns and 5 text lines. Never stretch with the viewport.
;;
;; Present a controlled playing card or empty pile as one activation target.
;; RANK is a one-line string up to three columns; SUIT is spades, hearts,
;; clubs, diamonds or nil. FACE-DOWN conceals the rank/suit, including the
;; generated accessible label. EMPTY presents a pile placeholder. SELECTED
;; changes paint without changing geometry. COLUMNS defaults to 9 (minimum 7);
;; LINES defaults to 5 (minimum 1); one row exposes just a card's corner in a
;; stack. These intrinsic dimensions never stretch to fill a viewport.
;; ON-PRESS receives no arguments; omitted/disabled cards are noninteractive.
;; LABEL overrides the accessible name and help, so callers must not put
;; hidden information there. Caller owns selection, stacks, moves and rules.
;; Colors use :ui-playing-card-* theme tokens; default faces are warm ivory
;; with contrasting red/black suits. Hover preserves all card text; backs
;; and empty piles derive a subtle tint from their own surface rather than
;; the face-up hover fill. Selected cards suppress hover paint.
;; Invalid rank/suit/dimensions signal
;; etaf-component-call-error. Use (etaf-view (etaf-playing-card :rank "A"
;; :suit 'hearts :on-press (lambda () ...))). No game backend is required.
;;
;; Component: etaf-text-grid (&key rows columns row-text row-ref label height ref on-scroll)
;; Parameters:
;; :rows, :columns — Required positive integers. Text line count and character-column capacity per line.
;; :row-text — Required pure function (zero-based-row) returning a single-line string fitting :columns; short strings are padded.
;; :row-ref — Optional pure function (zero-based-row) returning distinct Text Host references; default nil (no row references).
;; :label — String; default "Text grid". Accessible name of this read-only surface.
;; :height — Optional positive integer; default nil (every row shows). Lines shown in a scrolling viewport.
;; :ref — Optional Host reference of the surface; default instance-local. Target of etaf-scroll-to, etaf-scroll-by and etaf-scroll-offset.
;; :on-scroll — Optional function (first-visible-row); default nil. Called after the viewport moves.
;;
;; Display ROWS fixed text lines, each COLUMNS character columns wide.
;; Dimensions are positive integers. ROW-TEXT is a required callback receiving
;; the zero-based row; return a single-line string whose display width fits
;; COLUMNS. Short rows are padded with spaces. Read refs inside the callback to
;; update individual rows; each row keeps a stable identity. ROW-REF optionally
;; returns distinct Text Host references for retained content updates. Those
;; updates must also fit and pad to COLUMNS; keep the callback's state in sync.
;; LABEL names the read-only surface (default "Text grid"). The component has
;; no focus targets, input handling, timers or terminal escape interpretation.
;; Use monospaced text; wide characters occupy their Emacs display width.
;; With HEIGHT the surface shows HEIGHT lines that scroll, and it builds only
;; the rows near that viewport while spacers stand for the rest: mounting,
;; scrolling and repainting the viewport cost the same for any number of rows,
;; and ROW-TEXT runs only for built rows. The wheel, the scroll keys and
;; etaf-scroll-to/etaf-scroll-by on REF move the viewport; etaf-scroll-offset
;; and ON-SCROLL report the first visible row. Shrinking ROWS below the
;; viewport clamps it to the last rows. To scroll columns, keep the first
;; column in a ref that ROW-TEXT reads. Without HEIGHT every row is built.
;; Invalid dimensions, callbacks or row content signal etaf-component-call-error.
;; Use (etaf-view (etaf-text-grid :rows 24 :columns 80 :row-text read-row)), or
;; (etaf-text-grid :rows 1000000 :columns 80 :height 30 :ref 'log
;;                 :row-text read-row) for a long scrolling surface.
;;
;; Function: etaf-cell-line (cells &key (stripe 'px) border-color rule rule-color leading-edge)
;;;###autoload (autoload 'etaf-cell-line "etaf-ui" nil nil)
;; Return the styled text of one grid line holding CELLS.
;;
;; Parameters:
;; :cells — Required list of cell plists: :width (content characters, required), :text (one line, no tabs), :align (left, right or center), :face (a face or face plist over the text) and :edge (the colour of the separator after this cell).
;; :stripe — `px' (default) or `glyph'. One-pixel spaces with a background, or the box-rule character on a frame that cannot paint pixels.
;; :border-color — Separator colour used when a cell names no :edge.
;; :rule — Optional flag; default nil. Paint the row's bottom rule across the whole line.
;; :rule-color — Colour of that rule; a rule without a colour paints nothing.
;; :leading-edge — Optional colour of one separator before the first cell.
;;
;; Lay out CELLS at their declared widths, padded by one space on each side and
;; aligned, and separate them with the stripe an Ebox box paints for a side
;; border. A selected cell's fill therefore reaches the stroke, and no
;; half-cell gap, overhanging rule or unaligned column can appear. RULE paints
;; the underline an Ebox box paints on its last line, continuous across every
;; separator, which is what closes a cell row without a second Host.
;; The painter owns no state, no scrolling and no interaction: a grid surface
;; decides which cells are visible and what each one says, and calls this once
;; per line, so a row of cells costs one text Host rather than two per cell.
;; Cell widths, texts, alignment and multi-line content are validated; invalid
;; cells signal an error, and `etaf-cell-line-width' reports the line's
;; character width for callers that size a surface.
;; Use (etaf-cell-line (list (list :width 8 :text "Item 1")
;;                            (list :width 5 :text "38" :align 'right))
;;                      :border-color "#687386" :rule t :rule-color "#687386").
;;
;; Function: etaf-cell-line-width (cells)
;;;###autoload (autoload 'etaf-cell-line-width "etaf-ui" nil nil)
;; Return how many characters wide a line of CELLS is, separators included.
;;
;; CELLS is the same cell list `etaf-cell-line' paints. The count includes each
;; cell's padding and one separator per cell, so a surface can size its Host
;; before painting.
;;
;; Component: etaf-sheet (&key rows columns widths heights version cell-text cell-face cell-align header row-head cursor region height editing cell-edit-text colors on-commit on-edit-cancel on-resize-column on-resize-row keys label ref)
;; Parameters:
;; :rows, :columns — Required positive integers. Sheet size.
;; :widths — Required vector of content widths in characters, or a reactive source holding one.
;; :heights — Optional eql hash from row to extra lines; default nil (every row is one line).
;; :version — Optional writable ref; bump it after changing cell text so the sheet asks CELL-TEXT again.
;; :cell-text — Required function (row column) returning the cell's one-line text.
;; :cell-face — Optional function (row column) returning a face merged over the cell's text; default nil.
;; :cell-align — Optional function (row column) returning left, right or center; default nil (left).
;; :header — Column headings: t for spreadsheet letters, a function (column) or nil to omit the header line.
;; :row-head — Row headings: t for row numbers, a function (row) or nil to omit the number column.
;; :cursor — Required writable ref of the active cell (ROW . COL).
;; :region — Optional writable ref of the selection's other corner; default nil (the cursor cell alone).
;; :height — Required positive integer. Visible body lines.
;; :editing — Optional writable ref naming the cell being edited; default nil (no editor).
;; :cell-edit-text — Optional function (row column) with the text an edit starts from; default CELL-TEXT.
;; :on-commit — Optional function (row column text) receiving a submitted edit; default nil (no editing).
;; :on-edit-cancel — Optional function (text) receiving an abandoned edit.
;; :on-resize-column — Optional function (column width) from a dragged column heading.
;; :on-resize-row — Optional function (row lines) from a dragged row number.
;; :colors — Optional colour plist overriding :border, :rule, :selected, :selected-fg, :head, :muted and :accent.
;; :keys — Optional additional (KEY COMMAND LABEL) entries, placed before the sheet's own.
;; :label — String; default "Sheet". Accessible name of the grid.
;; :ref — Optional Host reference; an application that edits programmatically needs a stable one.
;;
;; Show a caller-owned grid of cells as a scrolling sheet with spreadsheet
;; borders, a cursor cell, a rectangular selection and an in-place editor.
;; The sheet owns the viewport: which rows and columns are built, where the
;; scroller sits and which cell a pointer landed on. It owns no cells: text,
;; widths, heights and every change come from the caller, so formulas,
;; formatting, undo and persistence stay in the caller's model. One text Host
;; per visible row is built with `etaf-cell-line', so mounting, scrolling and
;; repainting cost the viewport rather than the sheet; only the edited cell
;; becomes a Host of its own, an `etaf-text-input' that the sheet focuses.
;; Arrow keys move the cursor, Shift with an arrow extends the selection, F2
;; and RET begin an edit, and the horizontal wheel scrolls columns. Column
;; headings resize their column and row numbers resize their row when the
;; corresponding callbacks are supplied. Colours come from the catalog palette
;; (`:ui-table-border', `:ui-table-selected-bg', `:ui-table-selected-fg',
;; `:ui-panel-bg', `:ui-muted-fg', `:ui-accent'), a dark frame gets the sheet's
;; own dark colours, and :colors overrides either; a text frame paints
;; box-rule separators instead of one-pixel stripes. Invalid sizes, callbacks or references signal
;; `etaf-component-call-error' before publication.
;; Use (etaf-view (etaf-sheet :rows 1000 :columns 6 :widths widths
;;                            :height 20 :cursor cursor :cell-text read-cell
;;                            :on-commit write-cell :ref 'orders)).
;;
;; Function: etaf-sheet-begin-edit (runtime ref editing cell)
;;;###autoload (autoload 'etaf-sheet-begin-edit "etaf-ui" nil nil)
;; Begin editing CELL in the sheet REF of mounted RUNTIME.
;;
;; EDITING is the writable ref the sheet took as `:editing', and REF the stable
;; `:ref' it took, because the editor Host is addressable as REF's `-editor'
;; companion. Sets EDITING to CELL, then starts the field's native session and
;; returns its reference, or nil when the sheet or its editor is not mounted.
;; Call it from a command or key handler, outside a reactive batch, so the
;; editing row is published before the field takes focus.
;; Use it for Excel's type-to-edit, which replaces a cell with what was typed.
;;
;; Function: etaf-sheet-cell-at (runtime ref x y)
;;;###autoload (autoload 'etaf-sheet-cell-at "etaf-ui" nil nil)
;; Return the cell (ROW . COL) of the sheet REF in mounted RUNTIME at X and Y.
;;
;; X and Y are window pixels, as a pointer gesture reports them. The result is
;; nil when the position is outside the sheet's body, so an application can tell
;; a press on a cell from one on the chrome around it, for a context menu or a
;; drop target. The sheet's own presses use the same mapping.
;;
;; Function: etaf-sheet-scroll (runtime &optional ref lines)
;;;###autoload (autoload 'etaf-sheet-scroll "etaf-ui" nil nil)
;; Scroll the sheet REF of mounted RUNTIME by LINES, negative upwards.
;;
;; REF defaults to `etaf-sheet', and LINES defaults to one page: the sheet's
;; visible body height. Scrolling moves the viewport only, so an application
;; that pages a sheet also moves the `:cursor' ref and reveals it. Use it for
;; page keys, a scrollbar-free "jump to row" or a benchmark harness; the sheet's
;; own pointer wheel and arrow keys need no help.
;;
;; Function: etaf-sheet-reveal (runtime &optional ref)
;;;###autoload (autoload 'etaf-sheet-reveal "etaf-ui" nil nil)
;; Scroll the sheet REF of mounted RUNTIME so its cursor cell is visible.
;;
;; REF defaults to `etaf-sheet'. The sheet's own keys and pointer drags reveal
;; the cursor already; call this after moving `:cursor' from application code,
;; for example a "go to cell" command or a restored session.
;;

;; Component: etaf-log (&key rows level-width time-width width ref)
;; Parameters:
;; :rows — List of plists with :time, :level and :message.
;; :level-width — Level column width; default 5.
;; :time-width — Time column width; default 8.
;; :width — Host length; default `stretch'.
;; :ref — Optional Host reference.
;;
;; Render a log without a frame: the level is coloured by severity, the
;; message fills the rest, and the pane around it supplies the edge.

;; Component: etaf-status-bar (&key mode keys note width ref)
;; Parameters:
;; :mode — Optional string naming the current mode; painted as a filled chip.
;; :keys — List of (KEY . LABEL) pairs.
;; :note — Optional right-aligned string.
;; :width — Host length; default `stretch'.
;; :ref — Optional Host reference.
;;
;; Render one status row: mode chip, key hints, note at the right.

;; Component: etaf-braille-chart (&key values width height min max label ref)
;; Parameters:
;; :values — List of at least two numbers.
;; :width — Cell count; default 40.
;; :height — Row count; default 6; each cell holds a 2x4 dot grid.
;; :min, :max — Optional scale bounds.
;; :label — Optional string above the chart.
;; :ref — Optional Host reference.
;;
;; Render VALUES as a braille dot chart: dots the series does not pass
;; through stay empty, so the line is thin and its shape copies as text.

;; Component: etaf-data-grid (&key controller columns row-key on-row-press row-ref row-selected-p loading-label error-label empty-label)
;; Parameters:
;; :controller — Required caller-owned ETAF Data Controller; create it before rendering and stop it at its owner's disposal.
;; :columns — Table column plist list; default nil (no columns). Unique non-nil symbol/integer/string :key, optional :label, :width and pure :cell (row) returning View content.
;; :row-key — Function (row) required for nonempty data; returns a unique stable non-nil key.
;; :on-row-press — Optional function (row); default nil (no row activation).
;; :row-ref — Optional pure function (row) returning a distinct Host reference; default nil (instance-local).
;; :row-selected-p — Optional pure function (row); default nil. Its selection flag is ORed with the Controller's selection, not an override.
;; :loading-label — Optional display value; nil uses "Loading..." or "Refreshing..." according to status.
;; :error-label — Optional display value; nil uses "Unable to load data." or "Loading cancelled." according to status.
;; :empty-label — Optional display value; nil uses "No data.". Idle still displays "Not loaded.".
;;
;; Render DATA CONTROLLER state through the public Component DSL.
;;
;; DataGrid shows idle, loading, refreshing, cancelled, error and empty states.
;; Accepted rows stay interactive during pending or failed operations. Status
;; appears above the rows; refresh uses LOADING-LABEL or Refreshing....
;; Cancellation uses ERROR-LABEL or Loading cancelled. Pagination disables
;; page changes while loading or refreshing. Controllers remain caller-owned.
;; Table row Components retain keyed identity and custom cell state across
;; insert, reorder and update. ETAF supplies instance-local Host references and
;; publishes each row callback with its visible data; callers need :row-ref only
;; for explicit external addresses. UI owns no callback or reference cache.
;; COLUMNS use Table's unique keys and optional `:cell' row-to-View functions.
;; Row fields remain business data and are never interpreted as loading status.
;; Use inside (etaf-view (etaf-data-grid ...)); keyword arguments are component props.
;;
;; Component: etaf-label (&key text variant)
;; Parameters:
;; :text — Optional value/ref/computed; default nil (empty); strings keep text properties.
;; :variant — Optional default/muted/danger/success/strong/heading; nil uses default.
;;
;; Render TEXT in a semantic Label with ordinary Box layout. TEXT accepts a
;; value, ref or computed; nil is empty, strings retain their text properties,
;; and other values use their printed representation. VARIANT selects the
;; default, muted, danger, success, strong or heading presentation. Strong and
;; heading emphasize text with weight while retaining the inherited font size.
;; Layout attributes such as :width, :padding, :border and :wrap-mode apply
;; to the Label's Box; its Text child inherits typography and color.
;; Use :width 'stretch to follow the containing width and :wrap-mode 'word
;; for wrapping prose. Reactive text and viewport changes use Ebox reflow.
;; Use inside (etaf-view (etaf-label ...)); keyword arguments are component props.
;;
;; Component: etaf-number-input (&key value label on-change disabled min max bind hide-label ref)
;; Parameters:
;; :value — Integer/nil or ref/computed; default nil (empty), unless :bind supplies it.
;; :label — Optional string/nil; nil uses "Value" as caption and accessible name.
;; :on-change — Optional function (integer-or-nil); default nil. Accepts complete in-range input; empty submission reports nil.
;; :disabled, :hide-label — Optional flags; default nil. Disable editing/steppers or omit the caption respectively.
;; :min, :max — Optional numeric bounds; default nil (unbounded); min <= max.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;; :ref — Optional Host reference for the in-place text field; nil uses an instance-local reference.
;;
;; Render a controlled integer input with a muted caption, an in-place text
;; field and minus/plus steppers. Steppers change the value by one and disable
;; at MIN/MAX. Incomplete or out-of-range text stays a draft; invalid submission
;; signals user-error without writing. Empty submission reports nil.
;; Unlike Slider's step-aligned native prompt, NumberInput supports an empty
;; value and in-place integer editing; Range provides pointer scrubbing and a
;; separate commit callback. HIDE-LABEL omits the caption for grid forms.
;; Alternatively, :bind accepts an existing writable ref and replaces VALUE
;; plus ON-CHANGE. It uses the same conflict, ownership and publication rules
;; as Checkbox. The current value must be an integer or nil, label a string or
;; nil, and min/max numbers or nil with min <= max. Invalid inputs signal
;; etaf-component-call-error identifying the Component and property. Input
;; configuration is checked before initialization or updated props publish;
;; live values are checked when rendered. Accepted edits are checked against
;; the integer and min/max constraints before writing the ref. Custom business
;; validation or transformation uses the explicit VALUE/ON-CHANGE interface.
;; Use inside (etaf-view (etaf-number-input ...)); keyword arguments are component props.
;;
;; Function: etaf-ui-editor-mode (&optional arg)
;;;###autoload (autoload 'etaf-ui-editor-mode "etaf-ui" nil t)
;; Enable or disable native editing behavior in a caller-owned UI buffer.
;; The mode preserves text, the major-mode keymap, undo, selection and CAPF.
;; It owns an empty hint and edit observation, not window layout or transport.
;; No minibuffer is opened. Disabling removes its overlay/hooks, never text.
;; Framework/native-pane integrations configure it through the functions below.
;; This behavior is not yet a layout-mounted Input/Textarea Component.
;;
;; Function: etaf-ui-editor-configure (&key (placeholder nil placeholder-p) (placeholder-face nil face-p) (on-change nil callback-p))
;;;###autoload (autoload 'etaf-ui-editor-configure "etaf-ui" nil nil)
;; Configure the current editor's hint string, face and edit observer.
;; Enable etaf-ui-editor-mode first. Omitted fields retain existing values;
;; explicit nil ON-CHANGE detaches it. The observer receives the buffer after
;; text changes and must not edit it. Errors propagate without erasing text.
;; Configuration and point movement produce no edit notifications.
;;
;; Function: etaf-ui-editor-value (&optional buffer)
;;;###autoload (autoload 'etaf-ui-editor-value "etaf-ui" nil nil)
;; Return a detached, property-free, widened text value without changing edit
;; state. BUFFER defaults to current and must have the editor behavior enabled.
;;
;; Function: etaf-ui-editor-replace (buffer text &optional expected-tick)
;;;###autoload (autoload 'etaf-ui-editor-replace "etaf-ui" nil nil)
;; Replace native editor text, preserving markers where possible and making
;; one undoable replacement. Return t if accepted; nil on a stale optional
;; buffer-chars-modified-tick. Equal text changes nothing and emits no callback.
;; Applications, not this behavior, decide when a reply permits replacement.
;; Explicit updates may change read-only text. Invalid/stale handles and
;; reentrant replacement signal user-error; observer errors leave accepted
;; text intact. Native hooks still run, and this mode observes the final value.
;;
;; Function: etaf-text-input-begin (runtime ref)
;;;###autoload (autoload 'etaf-text-input-begin "etaf-ui" nil nil)
;; Begin native editing of mounted text input REF in RUNTIME and return it, or
;; nil when REF is unknown, disabled, read-only or already editing. Activation
;; calls this from the field's own callback; call it directly to focus a
;; composer or open a grid cell. Beginning another field first leaves the
;; previous one, keeping its text. Other publications continue while editing.
;;
;; Function: etaf-text-input-end (&optional how)
;;;###autoload (autoload 'etaf-text-input-end "etaf-ui" nil nil)
;; Finish the active text input and return its user text, or nil when none is
;; active. HOW nil submits: the text stays the value and :on-submit receives
;; it. HOW `blur' leaves the field keeping its text, without callbacks. Any
;; other HOW cancels: the value captured at activation is restored through
;; the change callback and :on-cancel receives the abandoned text. The session
;; is released even when a callback signals; the signal then propagates.
;;
;; Function: etaf-text-input-active-p (&optional runtime)
;;;###autoload (autoload 'etaf-text-input-active-p "etaf-ui" nil nil)
;; Return the text input currently editing in RUNTIME, or nil. RUNTIME defaults
;; to the active field's Runtime, so the query works from any buffer.
;;
;; Component: etaf-text-input (&key value bind on-change label placeholder rows width variant disabled read-only submit-on-return on-submit on-cancel on-focus completion-functions keymap hide-label ref)
;; Parameters:
;; :value — String/nil or ref/computed; default nil (empty), unless :bind supplies it.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;; :on-change — Optional function (text); default nil. Receives the whole string after each edit.
;; :label, :placeholder — Strings; defaults "Text" and "". Caption/name and empty-value hint.
;; :rows — Positive integer; default 1. Minimum text lines, not a fixed height.
;; :width — Host length; default stretch. For example (ch 24), not a bare column count.
;; :variant — outlined/plain; default outlined. Framed field or text-only content.
;; :disabled, :read-only, :hide-label — Optional flags; default nil. Disable activation, keep focus without editing, or omit the caption.
;; :submit-on-return — Optional flag; omitted means t for one row, nil otherwise; explicit nil inserts newlines.
;; :on-submit, :on-cancel — Optional functions (text); default nil. Submitted or abandoned session text; cancel restores the activation value.
;; :on-focus — Optional function (); default nil. Runs once when editing starts.
;; :completion-functions — Optional list of CAPF functions (); default nil. Used by native completion.
;; :keymap — Optional Emacs keymap; default nil. Field-local keys must not bind framework-reserved events.
;; :ref — Optional Host reference; nil uses an instance-local field reference.
;;
;; Edit text directly in the application's layout. VALUE/ON-CHANGE or a
;; writable BIND supplies the controlled string; ROWS (default 1) sets the
;; minimum visible lines, so one Component covers single-line inputs and text
;; areas. LABEL defaults to "Text" and HIDE-LABEL omits its muted caption.
;; PLACEHOLDER (default "") shows while the value is empty and never becomes
;; its content. VARIANT `outlined' (default) frames the text in a panel with a
;; hairline border that takes the accent colour while focused, without moving
;; any cell; `plain' draws only the text, for composers inside a styled footer.
;; Optional Theme tokens `:ui-input-padding' (default `((lh 0) (ch 1))'),
;; `:ui-input-radius' (default `(px 0)'), `:ui-input-bg' (falls back to the
;; Theme's `:ui-panel-bg') and `:ui-input-border' (idle one-pixel border color,
;; falls back to `:ui-panel-border') style outlined fields. Focus keeps using
;; `:ui-accent'; plain fields ignore these tokens. Editing shows a bar caret
;; and no other focus decoration.
;; Activation starts a native editing session on the field's value inside the
;; application layout: every keystroke reflows only the field, which grows
;; with wrapped or added lines while padding and frame stay intact. Native
;; commands, input-method preedit, undo, kill/yank, word and line motion, and
;; mouse caret placement and selection all act on the value alone, with no
;; minibuffer, frame or extra window. Printing keys reach the field even when
;; the application binds them. Return submits when :submit-on-return is
;; non-nil (default for one row) and otherwise inserts a newline;
;; Shift+Return and C-j insert an unindented newline; C-c C-c and
;; Ctrl+Return submit; C-c C-k cancels and restores the activation value;
;; Escape leaves the session keeping its text and Host focus; TAB/backtab leave and move application focus; M-TAB
;; completes. A press or click outside the field leaves it, keeping the text.
;; ON-SUBMIT and ON-CANCEL receive the session text; ON-FOCUS runs without
;; arguments once a session begins, by pointer, keyboard or
;; `etaf-text-input-begin'. READ-ONLY stays focusable
;; without a session; DISABLED also removes activation. COMPLETION-FUNCTIONS
;; configures CAPF during the session and KEYMAP adds field-local bindings,
;; which run in the application buffer; KEYMAP may not bind framework-reserved
;; keys (Escape, Tab, `?', the arrows, `M-g', `C-g') and such a value signals
;; `etaf-component-call-error' during validation, with direction behavior left
;; to `:on-direction'. Other application changes publish
;; while editing. Invalid props signal contextual `etaf-view-error'.
;; Use inside (etaf-view (etaf-text-input ...)); companion functions above drive
;; it programmatically.
;;
;; Component: etaf-search-field (&key value bind on-change placeholder width icon on-focus on-submit on-cancel on-clear keymap ref)
;; Parameters:
;; :value — String/nil or ref/computed; default nil (empty), unless :bind supplies it.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;; :on-change — Function (text) for explicit controlled use; default nil. Required to persist edits and handle the clear action without :bind.
;; :placeholder — String; default "Search". Empty-value hint and input name.
;; :width — Host length; default stretch; e.g. (ch 32).
;; :icon — Optional flag; default nil. Show a magnifier.
;; :on-focus, :on-clear — Optional functions (); default nil. Editing began or the query was cleared.
;; :on-submit, :on-cancel — Optional functions (text); default nil. Follow TextInput session semantics.
;; :keymap — Optional field-local keymap; default nil. Framework-reserved events are rejected.
;; :ref — Optional Host reference; nil uses an instance-local input reference.
;;
;; Render a rounded pill search field editing a controlled query through
;; `etaf-text-input', so ON-CHANGE sees every keystroke. VALUE/ON-CHANGE or a
;; writable BIND supplies the query. The pill is three rows tall and its painted
;; surface leaves half a row above and below the text. PLACEHOLDER (default
;; "Search") shows while the query is empty; ICON non-nil adds a magnifier;
;; WIDTH defaults to stretch. A clear button follows a nonempty query: it
;; empties the query, calls ON-CLEAR and keeps editing. A press anywhere on the
;; pill begins editing. ON-FOCUS, ON-SUBMIT, ON-CANCEL and KEYMAP follow
;; etaf-text-input; REF names the input for `etaf-text-input-begin'. Colors come
;; from the :ui-search-* theme tokens.
;; Use (etaf-view (etaf-search-field :bind query :icon t)).
;;
;; Component: etaf-menu (&key label items on-select disabled)
;; Parameters:
;; :label — String; default "Actions". Trigger caption and prompt name.
;; :items — List of plists; default nil (disabled). Unique non-nil scalar :key and unique nonempty string :label; optional :disabled flag.
;; :on-select — Optional function (key); default nil (disabled). Called once after accepted native completion.
;; :disabled — Optional flag; default nil. Disable the trigger regardless of enabled items.
;;
;; Render a Button opening native completion for an action. LABEL defaults to
;; "Actions". A trailing arrow indicates a menu, not a keyboard binding.
;; ITEMS are plists with unique non-nil scalar :key values, unique
;; nonempty string :label values and optional :disabled. Native choices include
;; only enabled items. ON-SELECT receives the chosen key once, after the input
;; boundary validates the entry and restores focus. Empty input or C-c C-k
;; cancels.
;; No enabled items, nil ON-SELECT or DISABLED disables the Button. Like other
;; inputs, :on-press is an additive observer. Current props supply each published
;; menu; no application value or extra open-state ref is owned by the control.
;; Invalid props signal contextual `etaf-view-error'. Use in `etaf-view'.
;;
;; Function: etaf-confirm-dialog (prompt)
;;;###autoload (autoload 'etaf-confirm-dialog "etaf-ui" nil nil)
;; Ask a nonempty string PROMPT with the native yes/no minibuffer from a Host
;; callback. Return non-nil on confirmation and nil on no; change application
;; state only after confirmation. C-g or invalidated entry ownership aborts the
;; callback. Ebox restores focus to the valid entry; no surface content is edited.
;; Outside a Host event, signal `etaf-event-error'. Invalid PROMPT signals
;; `etaf-view-error'. Compose in a Menu's ON-SELECT or a Button's ON-PRESS.
;;
;; Component: etaf-select (&key value options label placeholder on-change disabled bind presentation hide-label width ref)
;; Parameters:
;; :value — Scalar/ref/computed; default nil. Nil means no selection unless it is an option key.
;; :options — Alist (value . label); default nil (disabled empty list). Unique symbol/number/string keys and unique nonempty string labels.
;; :label, :placeholder — Strings; defaults "Select" and "—". Caption/name and no-selection text.
;; :on-change — Optional function (chosen-value); default nil. Caller stores the selection.
;; :disabled, :hide-label — Optional flags; default nil. Suppress activation or omit the caption.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;; :presentation — auto/chips/dropdown; default auto (chips for at most four options).
;; :width — Dropdown Host length; default (ch 28), not the whole chip group's width.
;; :ref — Optional Host reference; default nil. Dropdown trigger or the whole chips field.
;;
;; Choose a controlled value from OPTIONS without leaving the UI.
;; PRESENTATION is `chips', `dropdown' or `auto' (default): chips render each
;; option as an inline pill with the current one filled; a dropdown renders one
;; anchor pill with its caption and a disclosure arrow, which REF names,
;; and lists the options as ghost
;; buttons in a Popover of WIDTH (default (ch 28)) that closes on selection or
;; Escape.  `auto' shows chips for up to four options.  HIDE-LABEL omits the
;; muted caption for grid forms.
;; OPTIONS is an alist of (VALUE . LABEL); values are unique symbols, numbers
;; or strings, labels unique nonempty strings. Nil is a valid option value.
;; A nil VALUE absent from OPTIONS displays PLACEHOLDER; other absent values
;; are errors. An empty list disables activation. LABEL defaults to "Select"
;; and PLACEHOLDER to "—"; both are strings. VALUE may be a ref/computed.
;; ON-CHANGE receives the accepted option value. :bind follows TextInput.
;; Invalid props signal contextual `etaf-view-error'. Use (etaf-view (etaf-select ...)).

;; Component: etaf-radio (&key value options label on-change disabled bind)
;; Parameters:
;; :value — Scalar/ref/computed; default nil. Nil or a key in :options.
;; :options — Required nonempty alist (value . label); unique scalar keys and unique nonempty string labels.
;; :label — String; default "Choice". Visible group caption.
;; :on-change — Optional function (chosen-value); default nil. Caller stores the selection.
;; :disabled — Optional flag; default nil. Disable every choice.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;;
;; Render a controlled single-choice group from an options alist. VALUE/ON-CHANGE
;; or the writable BIND ref owns the selection.
;;
;; Component: etaf-switch (&key checked label on-change disabled bind)
;; Parameters:
;; :checked — Boolean/ref/computed; default nil, unless :bind supplies it.
;; :label — String; default "Switch". Caption and accessible name.
;; :on-change — Optional function (next-boolean); default nil. Caller stores the state.
;; :disabled — Optional flag; default nil. Disable activation.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :checked and :on-change, even nil.
;;
;; Render a controlled binary switch with Checkbox's ownership contract.
;;
;; Component: etaf-segmented (&key value options on-change disabled bind)
;; Parameters:
;; :value — Scalar/ref/computed; default nil. Nil or a key in :options.
;; :options — Required nonempty alist (value . label); unique scalar keys and unique nonempty string labels.
;; :on-change — Optional function (chosen-value); default nil. Caller stores the selection.
;; :disabled — Optional flag; default nil. Disable every segment.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;;
;; Render a compact mutually-exclusive selector from an options alist.
;;
;; Function: etaf-toggle-strip (&key options value on-change theme label surface)
;; Parameters:
;; :options — Required nonempty alist (value . label); at least two unique scalar keys and unique nonempty string labels.
;; :value — Scalar; default nil. Nil or a key in :options.
;; :on-change — Optional function (chosen-value); default nil. Called when a segment is clicked.
;; :theme — Required token plist; supplies `:ui-panel-fg', `:ui-panel-border', `:ui-accent' and `:ui-accent-fg'.
;; :label — Optional string; default nil. Painted before the strip in `:ui-muted-fg'.
;; :surface — Optional color; default nil, which uses the Theme's panel surface.
;;
;; Return the same control as a propertized string, for a row where a Component
;; cannot mount: a header line or a mode line.  The segments form one row of
;; equal width, the selected one paints the accent, the others the row surface,
;; and each segment carries its own box and a click handler calling :on-change.
;; A selected segment takes no pointer-hover face, so states do not stack.
;;
;; Component: etaf-slider (&key value min max step label on-change disabled bind)
;; Parameters:
;; :value — Required integer/ref/computed unless :bind supplies it; no valid empty default. Align (value - min) to :step within bounds.
;; :min, :max — Integer bounds; defaults 0 and 100; min <= max. Max need not align to :step.
;; :step — Positive integer; default 1. Alignment unit and arrow increment.
;; :label — String; default "Value". Caption and native prompt name.
;; :on-change — Optional function (next-integer); default nil. Store the accepted value.
;; :disabled — Optional flag; default nil. Disable arrows and prompt.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;;
;; Render a controlled integer value within MIN..MAX aligned to STEP.
;; Activation uses a native number prompt, not pointer scrubbing. Use Range
;; for drag/seek preview and commit, or NumberInput for in-place integer entry.
;; Left and Right on the focused slider report the value moved by STEP,
;; clamped to MIN and the largest aligned value <= MAX. For 0..5 with STEP 2,
;; the reachable values are 0, 2 and 4; Right at 4 reports 4, never 5.
;;
;; Component: etaf-range (&key value min max step key-step on-change on-commit disabled color track-color bar-height label ref fill-ref)
;; Parameters:
;; :value — Number/ref/computed in :min..:max; default nil paints an empty span.
;; :min, :max — Numbers/ref/computed; defaults 0 and 100; resolved min <= max. Pending nil bounds paint an empty span.
;; :step — Optional positive number; default nil. Pointer values snap to this increment from :min.
;; :key-step — Optional positive number; nil uses :step, otherwise one twentieth of the span. Arrow increment.
;; :on-change, :on-commit — Optional functions (number); default nil. Intermediate change versus released/clicked/keyboard value; no :bind prop.
;; :disabled — Boolean; default nil. Disable pointer and keyboard input.
;; :color, :track-color — Optional Host colors; nil uses :ui-range-fill and :ui-range-track.
;; :bar-height — Integer percentage 1..100; default 40. Centered graphical thickness within one standard row, pixel-rounded with a one-pixel minimum. Text-only frames keep a thin rule.
;; :label — Optional string; nil uses "Range" as accessible name.
;; :ref, :fill-ref — Optional symbol Host references; nil generates instance-local track/fill identities.
;;
;; Render a controlled interactive Range (progress, seek, volume) within MIN..MAX.
;; ON-CHANGE reports intermediate values and ON-COMMIT the released one; the bar
;; paints a Track and a percentage Fill inside one standard row. SVG-capable
;; graphical frames honor BAR-HEIGHT without changing row or hit-target size.
;; Other frames retain a thin text rule. A retained
;; binding updates FILL-REF's width without re-rendering the Component.
;; MIN/MAX accept numbers or reactive sources. Live bounds are checked by the
;; retained Fill getter; invalid bounds reject publication until corrected.
;; Left and Right on the focused range report the value moved by KEY-STEP
;; (default STEP, else a twentieth of the span) through ON-CHANGE and
;; ON-COMMIT; Home and End report MIN and MAX.

;; Component: etaf-pagination (&key controller previous-ref next-ref previous-label next-label class color bgcolor border padding aria-label)
;; Parameters:
;; :controller — Optional caller-owned ETAF Data Controller; nil shows an empty disabled one-page pager.
;; :previous-ref, :next-ref — Optional Button Host references; default nil.
;; :previous-label, :next-label — Optional captions; nil uses "‹ Previous" and "Next ›". Accessible names remain "Previous page" and "Next page".
;; :class — Optional extra root classes; default nil.
;; :color, :bgcolor — Optional Host colors; nil uses Theme foreground/background.
;; :border — Optional Button border override; default nil (Button Theme default).
;; :padding — Optional root Host padding; nil uses ((lh 0) (ch 1)).
;; :aria-label — Optional string; nil uses "Pagination" for the navigation group.
;;
;; Render a controlled pager whose callbacks follow its committed CONTROLLER.
;; PREVIOUS-LABEL and NEXT-LABEL override the complete Button captions.
;; Each Button captures its render's Controller; Runtime publishes that callback
;; together with the visible control after a successful render.
;; Use inside (etaf-view (etaf-pagination ...)); keyword arguments are component props.
;;
;; Component: etaf-panel (&key title variant)
;; Parameters:
;; :title — Optional display value/ref/computed; default nil (no title row).
;; :variant — Optional style symbol; nil uses default; flat omits background and border. Other names add a class only.
;;
;; Render a titled Panel with named header and default slots.
;; Panel supplies a header slot; Card instead supplies a description prop.
;; Use inside (etaf-view (etaf-panel ...)); keyword arguments are component props.


;; Component: etaf-drop-zone (&key side label ratio cols rows accent width ref)
;; Parameters:
;; :side — nil, `top', `bottom', `left', `right' or `center'.
;; :label — Optional string naming the dragged thing.
;; :ratio — Share of the pane the preview takes; default 0.5.
;; :cols, :rows — The pane's cell size, so the preview frame is exact.
;; :accent — Optional colour for the preview; default the warning ink.
;; :width — Host length; default `stretch'.
;; :ref — Optional Host reference.
;;
;; Render a pane with a drop preview on SIDE. The default slot is the pane
;; body; with SIDE nil it is painted unchanged. The preview occupies exactly
;; the half a release would take and names the dragged thing, so nothing
;; moves again when the pointer lets go.

;; Component: etaf-edge-panel (&key title status variant focus width ref)
;; Parameters:
;; :title — Optional string; default nil. Painted in the first row, on the rule.
;; :status — Optional string; default nil. Painted at the right end of that rule.
;; :variant — `default' or `flat'; default `default'. Flat keeps the rule but no surface.
;; :focus — Optional boolean; default nil. The accent colour paints the rule.
;; :width — Host length; default `stretch'.
;; :ref — Optional Host reference; default nil.
;;
;; Render a panel whose title sits on its top rule, so the frame spends no row
;; on a header. The default slot is the body under the title row.

;; Component: etaf-edge-tabs (&key items active on-change width ref)
;; Parameters:
;; :items — List of plists with unique :key and string :label.
;; :active — Required key present in :items.
;; :on-change — Function (key), called when a tab is pressed or activated.
;; :width — Host length; default `stretch'.
;; :ref — Optional Host reference; default nil.
;;
;; Render tabs set into the panel's top rule, with the body in the default
;; slot. The chosen tab takes the accent ink and the raised surface.

;; Component: etaf-underline-field (&key label value placeholder focus width ref)
;; Parameters:
;; :label — Optional string naming the field; default nil.
;; :value — Optional string; default "".
;; :placeholder — Optional string shown while the value is empty.
;; :focus — Optional boolean; default nil. The accent colour paints the rule.
;; :width — Host length; default `stretch'.
;; :ref — Optional Host reference; default nil.
;;
;; Render a read-only field as a line under its value: the rule costs no row,
;; so a form reads as rows of labelled text instead of boxes.

;; Component: etaf-resizable-panel (&key x y width height position z-index visible min-width max-width min-height max-height resizable resize-edges resize-refs resize-use on-resize on-move header-style drag-lock-modifier full-bleed font-size font-family ref id class role use overflow)
;; Parameters:
;; :x, :y — Host lengths/ref/computed; defaults (px 0), (lh 0). Left and top positions; px means pixels, lh standard text rows.
;; :width, :height — Optional Host lengths/ref/computed; default nil (Host auto sizing). Prefer explicit dimensions on a positioned canvas.
;; :position — absolute/relative; default absolute. Positioning mode within the containing canvas.
;; :z-index, :visible — Stacking integer/ref/computed (default nil) and visibility flag/ref/computed (default t).
;; :min-width, :min-height — Host lengths/ref/computed; defaults (px 80) and (lh 2).
;; :max-width, :max-height — Optional Host lengths/ref/computed; default nil (no maximum).
;; :resizable — Boolean; default t. Handles still need :on-resize or :resize-use.
;; :resize-edges — List; defaults to all eight: top/right/bottom/left and top-left/top-right/bottom-left/bottom-right.
;; :resize-refs — Optional alist (edge . Host-reference); default nil. Supported references are symbols or functions.
;; :resize-use — Optional alist (edge . Behavior-composition); default nil. Caller-owned resizing policy.
;; :on-resize — Optional function (edge gesture); default nil. Gesture :delta is (dx . dy) in pixels; caller updates dimensions and restores cancelled geometry.
;; :on-move — Optional function (gesture); default nil. Panel-root drag, with pixel delta and start/move/end/cancel phase.
;; :header-style — Optional Host style plist; default nil. Paint header corner cells like the header slot.
;; :drag-lock-modifier — nil/shift/control/meta/super/hyper; default nil (held-button tracking).
;; :full-bleed — Boolean; default nil. Let body reach the frame edges; handles keep their edge cells as hit surfaces that show the body's paint.
;; :font-size, :font-family — Optional body-relative size ratio and family string; default nil (inherit). Must fit the canvas line height.
;; :ref, :id, :class — Optional Host reference, semantic ID and extra classes; default nil; class may be reactive.
;; :role — Optional Host role; nil uses region.
;; :use — Optional root Behavior composition; default nil.
;; :overflow — Optional Host overflow mode; nil uses hidden.
;;
;; Render a controlled positioned panel and optional edge/corner resize handles.
;; Geometry props are passed to Ebox and may be values, refs or computed values;
;; CLASS may also be a ref or computed so a caller's mode class changes stay a
;; Host property binding.  A panel with a `header' slot is always framed so the
;; header row reaches both borders even when resizing is disabled.
;; ON-MOVE receives a gesture plist; ON-RESIZE receives EDGE and that gesture.
;; DRAG-LOCK-MODIFIER defaults to nil; a supported modifier enables Ebox's
;; release-independent gestures on the panel and all enabled resize handles.
;; A second primary-button press confirms; Escape cancels through the same
;; callbacks.  Geometry restoration remains the caller's responsibility.
;; The `header' slot owns the first row between the corner cells, HEADER-STYLE
;; presents those cells like the header, and the default slot fills the body
;; area, so a caller's title bar reaches both panel borders.  With FULL-BLEED
;; the default slot instead owns the full body and enabled handles paint after
;; it, so the body reaches the panel edges; a handle sharing a cell covers it,
;; so pair FULL-BLEED with handles that sit in the header or in the body's own
;; margin when the body must stay seamless.
;; Callers own geometry updates and constraints.  This component stores no
;; state, does not assign z-order and does not implement a window manager.
;; FONT-SIZE and FONT-FAMILY default to nil, inheriting the surrounding
;; typography (the Emacs default font without an authored ancestor override).
;; An explicit FONT-SIZE is a positive number in CSS reference pixels.
;; Positioned content must fit its containing canvas's shared line height;
;; Ebox rejects a font whose resolved line height exceeds that canvas.

;; Component: etaf-window-controls (&key mode show-minimize show-maximize show-close active on-minimize on-maximize on-restore on-close group class)
;; Parameters:
;; :mode — normal/minimized/maximized or ref/computed; default normal. Selects the Zoom action, not geometry.
;; :show-minimize, :show-maximize, :show-close — Optional flags; default t for each. Include the corresponding light.
;; :active — Boolean/ref/computed; default t. Colored lights when active, gray when inactive.
;; :on-minimize, :on-maximize, :on-restore, :on-close — Optional functions (); default nil. Request caller-owned transitions; Zoom restores only in maximized mode.
;; :group — Scalar hover-group key; default etaf-window-controls. Share across one window's lights.
;; :class — Optional extra root classes; default nil.
;;
;; Render reusable macOS-style traffic-light controls.  GROUP is forwarded to
;; Ebox hover grouping so all controls update in one incremental batch.  ACTIVE
;; selects the macOS presentation: an inactive window shows one gray for all
;; three lights and the active window keeps red, yellow and green.  The green
;; "Zoom" control has one stable target: it calls ON-RESTORE while MODE is
;; `maximized' and ON-MAXIMIZE otherwise.  MODE and ACTIVE may be scalars,
;; refs or computed values; the rendered structure never depends on them.
;; SVG lights fit the frame line. Without SVG, inherited one-cell ASCII `o'
;; marks show `x', `-' and `+' on hover, preserving the same action targets.
;;
;; Component: etaf-window-chrome (&key title mode show-minimize show-maximize show-close active on-minimize on-maximize on-restore on-close on-move drag-lock-modifier title-font-size font-family group ref class use)
;; Parameters:
;; :title — Optional display value/ref/computed; default nil (empty title).
;; :mode — normal/minimized/maximized or ref/computed; default normal. Presentation and Zoom action only.
;; :show-minimize, :show-maximize, :show-close — Optional flags; default t for each.
;; :active — Boolean/ref/computed; default t. Active title/control paint.
;; :on-minimize, :on-maximize, :on-restore, :on-close — Optional functions (); default nil. Caller owns transitions.
;; :on-move — Optional function (gesture); default nil. Title drag supplies pixel :delta (dx . dy) and start/move/end/cancel :phase.
;; :drag-lock-modifier — nil/shift/control/meta/super/hyper; default shift. Enable release-independent dragging; caller restores cancelled geometry.
;; :title-font-size, :font-family — Optional body-relative size ratio and family string; default nil (inherit). Must fit the canvas line height.
;; :group — Optional scalar hover-group key; nil uses :ref, then etaf-window-controls.
;; :ref, :class — Optional title Host reference and extra classes; default nil.
;; :use — Optional title Behavior composition; default nil. Can implement movement instead of a callback.
;;
;; Render a controlled title bar with minimize, zoom and close action
;; buttons; MODE may be a scalar, ref or computed and only changes classes.  The title bar forwards drag gestures to ON-MOVE; its
;; `drag-lock-modifier' defaults to `shift' for a release-independent drag.
;; Actions
;; only request caller-owned state transitions; `actions' and default slots
;; append custom controls/content. TITLE-FONT-SIZE and FONT-FAMILY default to
;; nil to inherit; an explicit size is a positive CSS reference pixel number.
;; The title, traffic lights and custom controls share the title-bar typography.
;; Within a positioned window, the font must fit its canvas's shared line height;
;; Ebox rejects a larger resolved font before publishing the candidate.

;; Component: etaf-window (&key title mode x y width height z-index visible min-width max-width min-height max-height resizable resize-edges resize-refs resize-use move-use full-bleed on-move on-resize on-focus drag-lock-modifier title-font-size content-font-size font-family controls-group controls-active on-minimize on-maximize on-restore on-close show-minimize show-maximize show-close ref id chrome-ref class use overflow)
;; Parameters:
;; :title — Optional display value/ref/computed; default nil (empty title).
;; :mode — normal/minimized/maximized or ref/computed; default normal. Minimized collapses the body, but never computes new geometry.
;; :x, :y — Host lengths/ref/computed; defaults (px 0) and (lh 0). Left/top within the positioned canvas.
;; :width, :height — Host lengths/ref/computed; defaults (ch 42) and (lh 16). Character-width and standard-row units, not bare numbers.
;; :z-index, :visible — Stacking integer/ref/computed (default nil) and visibility flag/ref/computed (default t).
;; :min-width, :min-height — Host lengths/ref/computed; defaults (px 160) and (lh 2).
;; :max-width, :max-height — Optional Host lengths/ref/computed; default nil (no maximum).
;; :resizable — Boolean; default t. Each enabled edge also needs :on-resize or its :resize-use entry.
;; :resize-edges — List; defaults to all eight: top/right/bottom/left and top-left/top-right/bottom-left/bottom-right.
;; :resize-refs — Optional alist (edge . Host-reference); default nil. Keyboard handles get instance-local references when absent.
;; :resize-use — Optional alist (edge . Behavior-composition); default nil. Caller-owned resize policy.
;; :move-use — Optional title-bar Behavior composition; default nil. Caller-owned move policy.
;; :full-bleed — Boolean; default nil. Body reaches frame edges; handles sit on its edge cells as hit surfaces, so no chrome strip covers the body.
;; :on-move — Optional function (gesture); default nil. Title drag/keyboard move reports pixel :delta (dx . dy), not new geometry.
;; :on-resize — Optional function (edge gesture); default nil. Caller updates dimensions and handles start/move/end/cancel phases.
;; :on-focus — Optional function (); default nil. Body activation and keyboard focus entry request caller-owned focus/z-order.
;; :drag-lock-modifier — nil/shift/control/meta/super/hyper; default shift. Applies to title and handles; cancellation does not restore caller data automatically.
;; :title-font-size, :content-font-size — Optional body-relative size ratios; default nil (inherit independently). Must fit the shared canvas line height.
;; :font-family — Optional string; default nil (inherit in both regions).
;; :controls-group — Optional scalar hover-group key; nil derives from the title reference.
;; :controls-active — Boolean/ref/computed; default t. Select active versus inactive control paint.
;; :on-minimize, :on-maximize, :on-restore, :on-close — Optional functions (); default nil. Caller owns all state transitions.
;; :show-minimize, :show-maximize, :show-close — Optional flags; default t for each.
;; :ref, :id, :chrome-ref, :class — Optional panel reference, semantic ID, title reference and extra classes; default nil. A missing title reference is instance-local.
;; :use — Optional panel-root Behavior composition; default nil. Use :move-use for title movement.
;; :overflow — Optional Host overflow mode; nil uses hidden.
;;
;; Compose a controlled Window shell from `etaf-resizable-panel' and
;; `etaf-window-chrome'.  MODE, geometry, visibility and callbacks remain
;; caller-owned.  Slots are `header', `actions', `default' and `footer'.  The
;; default slot is wrapped in one viewport region, so a Component rendered in
;; the body reads the space it was given as `(PIXELS . ROWS)` with
;; `etaf-viewport'.  The window adds no inset of its own and content owns its
;; inner spacing; with FULL-BLEED the body rectangle reaches the frame edges
;; and enabled handles are hit strips over its edge cells, while without it a
;; handle keeps its own cell.
;; Maximizing or
;; minimizing never changes geometry or global focus/z-order policy.  MODE and
;; VISIBLE may be refs or computed values: their changes publish as Host
;; property bindings (mode classes, panel visibility and the collapsed content
;; column) without re-rendering the shell, so the Component is stateful and
;; requires a mounted Runtime rather than `etaf-render'.  ON-FOCUS
;; runs for body activation, through ETAF's explicit ancestor capture hook
;; when a nested body control is pressed, and when keyboard focus enters the
;; window, so Tab and arrows activate it like a click. Ordinary body space uses
;; an arrow pointer; nested controls may override it. DRAG-LOCK-MODIFIER defaults to shift
;; and applies to both the title bar and all resize handles.  Set it to super
;; for a Super-modified press or nil to disable locking everywhere.
;; With focus anywhere in the window, M-arrows move it through the title
;; bar's ON-MOVE or MOVE-USE and M-S-arrows resize it through the right,
;; bottom or bottom-right handle, one cell per press; the edge handles are
;; not Tab stops.
;; TITLE-FONT-SIZE and CONTENT-FONT-SIZE default to nil and inherit independently;
;; positive CSS reference pixel numbers override only their own region.
;; FONT-FAMILY defaults to nil and otherwise selects the family for both regions.
;; All positioned content must fit the containing canvas's shared line height.
;; A larger resolved font is rejected by Ebox before publication; the previous
;; committed pixels and input remain available. Custom text may still select
;; fallback glyph fonts with different metrics even at an equal CSS font size.
;;
;; Component: etaf-taskbar (&key items active on-select on-launch launcher-label ref-prefix class)
;; Parameters:
;; :items — List of plists; default nil ("No windows"). Unique scalar :key and nonempty string :label; optional :state (active/minimized/error/nil or reactive) and boolean :disabled.
;; :active — Scalar key/ref/computed or nil; default nil. Matching item is highlighted; no window focus state is created.
;; :on-select — Optional function (key); default nil. Caller focuses/restores the chosen window.
;; :on-launch — Optional function (); default nil (no launcher control).
;; :launcher-label — String; default "Applications". Launcher caption and accessible name.
;; :ref-prefix — String or nil; default nil. Prefixes the Host references the bar creates, so several bars can share one ETAF Runtime.
;; :class — Optional extra root classes; default nil.
;;
;; Render a controlled taskbar for window items.  ITEMS use scalar :key and
;; string :label, with optional :state (`active', `minimized' or `error', or a
;; ref or computed of one) and :disabled.  Callers own window state; ON-SELECT receives a key and
;; ON-LAUNCH opens a caller-owned application launcher.  ACTIVE accepts a
;; scalar key, nil, ref or computed; matching items show selection.  Colors
;; come from the Desktop Theme tokens below; provide a Theme to restyle.
;;
;; Component: etaf-workspace-bar (&key workspaces active on-select on-add on-close add-label brand status layout-label layout-action settings-label settings-action ref-prefix class)
;; Parameters:
;; :workspaces — List; default nil (empty). Scalar keys or plists with :key/:label and optional :description/:disabled; keep keys distinct.
;; :active — Scalar key/ref/computed or nil; default nil. Marks the selected workspace.
;; :on-select — Optional function (key); default nil. Caller switches workspace.
;; :on-add, :on-close — Optional functions (); default nil (omit their controls). Close is a bar-level action, not a per-item callback.
;; :add-label — String; default "New workspace". Add action's accessible name.
;; :brand — Optional string; default nil (no brand).
;; :status — String/nil or ref/computed; default nil. Remaining single-row space clips overflow.
;; :layout-label — String/ref/computed or nil; default nil (no layout control). Fixed-width caption.
;; :layout-action — Optional function (); default nil. Caller changes layout mode.
;; :settings-label, :settings-action — Optional string and function (); defaults nil. Both are needed to show settings.
;; :ref-prefix — String or nil; default nil. Prefixes the tabs' and trailing controls' Host references, so several bars can share one ETAF Runtime.
;; :class — Optional extra root classes; default nil.
;;
;; Render accessible workspace tabs.  WORKSPACES may be scalar keys or item
;; plists with :key/:label.  Callbacks request caller-owned workspace changes;
;; this Component creates no workspace state.  LAYOUT-LABEL/LAYOUT-ACTION and
;; SETTINGS-LABEL/SETTINGS-ACTION optionally add trailing caller-owned controls.
;; ACTIVE accepts a scalar key, nil, ref or computed.  STATUS accepts a string,
;; nil, ref or computed; nil clears status text.  LAYOUT-LABEL accepts a
;; string, ref or computed of strings; the layout control keeps a fixed width
;; so a changed label rewrites only its own text.  Reactive sources
;; remain caller-owned and are read at their retained Host properties or Text
;; payload.  Status occupies the remaining single-row space and clips excess
;; text; layout and settings actions stay at the right edge as status length
;; changes.
;;

;; Desktop Theme tokens.  The desktop Components (`etaf-taskbar',
;; `etaf-workspace-bar', `etaf-window', `etaf-splitter', `etaf-launcher',
;; `etaf-switcher' and their pickers) read these semantic tokens through
;; `etaf-theme-token' inside retained Host properties, so a Theme provided
;; with `etaf-theme-provide' (scalar, ref or computed) restyles the whole
;; shell through paint slots without re-rendering:
;;   `:ui-shell-bg' `:ui-shell-fg' `:ui-shell-muted-fg' `:ui-shell-item-fg'
;;   `:ui-shell-item-minimized-fg' (bars and their items),
;;   `:ui-accent' `:ui-accent-fg' `:ui-accent-soft-bg' (bar selection and the
;;   launcher control), `:ui-window-bg' `:ui-window-fg' `:ui-window-border'
;;   `:ui-window-title-bg' `:ui-window-title-fg' `:ui-window-title-active-fg'
;;   (window chrome; inactive traffic lights use `:ui-window-title-fg'),
;;   `:ui-divider-bg' (splitter dividers) and `:ui-picker-item-bg'
;;   `:ui-picker-item-fg' `:ui-picker-item-muted-fg' (launcher and switcher
;;   rows).  Dialogs keep using `:ui-panel-*'; a selected picker row, chip,
;;   radio, switch or checkbox mark paints `:ui-button-secondary-fg' on
;;   `:ui-button-secondary-bg', dialog tokens that stay crisp while a modal's
;;   backdrop dims the shell.  Without a provided Theme the Components paint
;;   their light fallback colors.
;;
;; Component: etaf-launcher (&key open title items on-select on-close close-label backdrop)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed).
;; :title, :close-label — Strings; defaults "Applications" and "Close".
;; :items — List of plists; default nil (empty). Unique scalar :key, nonempty :label; optional :description, :state and :disabled. Caller owns the registry.
;; :on-select — Required function (key), even while closed. Caller launches/selects and decides when to close.
;; :on-close — Required function (), even while closed. Caller dismisses the launcher.
;; :backdrop — Boolean; default t. Nil leaves the underlying surface painted.
;;
;; Render a controlled modal application launcher from item plists.  The
;; caller owns the registry and OPEN state; ON-SELECT receives a selected key.
;; Items show their :label caption with an optional muted :description below
;; it.  The Dialog is centered and sized to its items.  BACKDROP defaults to
;; t and dims the application underneath while keeping it painted; nil paints
;; no backdrop at all, leaving the underlying surface fully visible.
;;
;; Component: etaf-switcher (&key open title items selected on-select on-close close-label backdrop)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed).
;; :title, :close-label — Strings; defaults "Switch application" and "Close".
;; :items — List of Launcher plists; default nil (empty). Unique scalar :key, nonempty :label; optional :description, :state and :disabled.
;; :selected — Key/ref/computed or nil; default nil. Non-nil must be present in :items.
;; :on-select — Required function (key), even while closed. Caller changes application/window focus and decides when to close.
;; :on-close — Required function (), even while closed. Caller dismisses the switcher.
;; :backdrop — Boolean; default t. Nil leaves the underlying surface painted.
;;
;; Render a controlled modal application/window switcher.  SELECTED marks the
;; caller-owned active item and ON-SELECT receives a key.  Presentation,
;; sizing and BACKDROP follow `etaf-launcher'.
;;
;; Component: etaf-splitter (&key orientation ratio min-ratio max-ratio on-change use class overlay z-index divider-content overlay-rect visible)
;; Parameters:
;; :orientation — horizontal (left/right) or vertical (top/bottom); default horizontal.
;; :ratio — Number/ref/computed; default 0.5. First pane's fraction within :min-ratio..:max-ratio.
;; :min-ratio, :max-ratio — Numbers strictly between 0 and 1; defaults 0.1 and 0.9; min <= max. Validate supplied ratio, not a gesture-to-ratio conversion.
;; :on-change — Optional function (gesture); default nil. Raw :phase and :delta (dx . dy) in pixels, not a ratio. Caller owns conversion and cancel restoration.
;; :use — Optional divider Behavior composition; default nil. Alternative policy for pointer/keyboard gestures.
;; :class — Optional extra root classes; default nil. Applies to the two-pane layout, not the overlay-only divider.
;; :overlay — Boolean; default nil. Draw divider only; caller supplies positioned panes.
;; :z-index — Integer/ref/computed or nil; default nil. Divider stacking order.
;; :divider-content — String/ref/computed or nil; default nil. Painted extent of overlay divider.
;; :overlay-rect — Optional plist/ref/computed; default nil. Requires :overlay; :left/:width are (px N), :top/:height are (lh N); entries may be reactive.
;; :visible — Boolean/ref/computed; default t. Visibility of an allocated :overlay-rect divider.
;;
;; Render a controlled horizontal or vertical split with named `first' and
;; `second' slots.  RATIO remains caller-owned; ON-CHANGE receives divider
;; gestures and USE can install an ETAF Behavior for keyboard/pointer updates.
;; For a ratio-based policy, capture the initial ratio and allocated pixel
;; extent at gesture start; divide cumulative pixel delta by that extent,
;; clamp the result and restore the initial ratio on cancel. Do not use an
;; assumed viewport width. etaf-host-ref-size measures a referenced layout.
;; OVERLAY renders only the divider over caller-owned panes.  OVERLAY-RECT is an
;; optional exact positioned rectangle using :left/:width in `(px N)' and
;; :top/:height in `(lh N)'; it keeps nested or constrained dividers aligned
;; with the caller's pane allocation.  Without it the overlay follows RATIO.
;; With OVERLAY-RECT, the rectangle and its :left/:top/:width/:height entries,
;; Z-INDEX, DIVIDER-CONTENT and VISIBLE accept refs or computeds: the divider
;; binds them as retained Host properties, so a layout policy moves, relabels
;; or hides dividers by writing cells instead of re-rendering the tree.
;; VISIBLE defaults to t; a hidden divider keeps its identity and gestures off.
;; The focused divider steps like a one-cell drag with the arrows across it.
;;
;; Component: etaf-pane-resizer (&key size side min max on-change on-end line background ref)
;; Parameters:
;; :size — Required numeric width in pixels or ref/computed for interactive resizing; caller owns the width.
;; :side — right/left; default right. Which side of the sized pane holds the divider.
;; :min, :max — Optional numeric pixel bounds; default nil (unbounded). Supply min <= max.
;; :on-change — Optional function (pixel-width); default nil. Receives rounded clamped widths on move/end.
;; :on-end — Optional function (pixel-width); default nil. Receives the released width after :on-change.
;; :line — Optional flag; default t. Draw a one-pixel hairline beside the pane.
;; :background — Optional Host color; default nil (inherit).
;; :ref — Optional Host reference; default nil. Names the divider for focus/addressing.
;;
;; Render a vertical divider that resizes an adjacent fixed-width pane. SIZE is
;; the pane's caller-owned width in pixels (a number, ref or computed). SIDE
;; `right' (default) places the divider on the pane's right so dragging right
;; widens it; `left' serves a pane to the divider's right. Each drag move passes
;; the candidate width, clamped to MIN and MAX pixels when given, to ON-CHANGE;
;; ON-END receives the final width. LINE (default t) draws a hairline in the
;; divider color beside the pane over BACKGROUND. The divider is wide enough to
;; grab and never moves other cells while dragging.  With a callback it is a
;; Tab stop whose Left and Right step the width one column.  REF reaches the
;; rendered divider so callers can focus or address it.
;; Use (etaf-view (etaf-pane-resizer :size width :on-change #'set-width)).
;;
;; Component: etaf-table (&key columns rows row-key row-ref on-row-press row-selected-p)
;; Parameters:
;; :columns — Column plist list; default nil (no columns). Unique non-nil symbol/integer/string :key, optional :label, :width and pure :cell (row) returning View content. Width defaults to max-content; integers count columns and (fr N) shares remaining space.
;; :rows — List of caller-owned rows; default nil (empty). Fields use column keys when :cell is absent.
;; :row-key — Required function (row), including for empty rows; returns a unique stable non-nil key.
;; :row-ref — Optional pure function (row) returning a distinct Host reference; default nil (instance-local).
;; :on-row-press — Optional function (row); default nil (no row activation).
;; :row-selected-p — Optional pure function (row) returning a selection flag; default nil (unselected).
;;
;; Render ordinary ROWS as a presentational Table.
;;
;; COLUMNS contain a unique non-nil `:key', optional `:label', `:width',
;; and `:cell' function accepting one row and returning ordinary View content.
;; Integer widths are character capacities; `(fr N)' shares the remaining width
;; by positive weight N.
;; Without `:cell', the key reads a text field from the row.  Cell state belongs
;; in a returned Component, whose Context comes from the consuming Table.
;; ROW-KEY supplies stable identity.  ROW-REF is only needed for caller-owned
;; addresses; interactive rows otherwise receive instance-local references.
;; Interaction and selection are controlled optional inputs; Table never owns
;; application or Data Controller state.
;; Rows retain their application object identity. A replacement row updates
;; callbacks even with equal contents; its stable key preserves cell state.
;; Use inside (etaf-view (etaf-table ...)); keyword arguments are component props.
;;

;; Component: etaf-popover (&key open anchor placement width title on-close)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed). Caller owns visibility.
;; :anchor — Required nonempty string or symbol identifying one Host's semantic :id, not its :ref.
;; :placement — bottom-start/bottom-end/top-start/top-end; default bottom-start. Flip vertically when needed and clamp to the canvas.
;; :width — Host length; default (ch 32). Floating panel width.
;; :title — Optional string; default nil (no title).
;; :on-close — Required function (), even while closed. Requests a caller-owned visibility change.
;;
;; Show controlled OPEN content on Ebox's root layer, anchored to a unique
;; semantic ID. OPEN can be a value, ref or computed; ON-CLOSE requests closing
;; without owning application state. Default PLACEMENT is bottom-start and
;; WIDTH is (ch 32). Other placements follow Ebox's anchor contract. TITLE is
;; optional. Every floating surface shares one card anatomy: a one-row header
;; with the title under a hairline, a body padded by one row and two columns,
;; and a right-aligned footer row. Default and footer slots retain their
;; author Context and state.
;; Opening focuses the first eligible control (or the panel when empty).
;; TAB/Shift-TAB and arrow keys navigate within the panel; Escape requests
;; close. Closing restores a still-valid prior focus. Shortcuts are buffer-local
;; and disposed with the open panel; they outrank application key maps,
;; including emulation maps, while it is open.  Outside controls remain
;; mouse-accessible.
;; The application root must reserve a canvas height for floating content.
;; Ebox owns clipping, flipping, occlusion and layout. No child frame is created.
;;
;; Component: etaf-dialog (&key open title width height compact close-label on-close backdrop keys on-direction animated)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed). Caller owns visibility and form state.
;; :title — String; default "Dialog". Header caption.
;; :width — Host length; default (ch 48). Panel width.
;; :height — Optional (lh positive-integer); default nil (content height). Fixed rows include header/body/footer and are bounded by the window.
;; :compact — Boolean; default nil. Remove body vertical padding.
;; :close-label — String/nil; default "Close". Nil omits the default footer action, not Escape or header dismissal.
;; :on-close — Required function (), even while closed. Caller updates :open.
;; :backdrop — Optional flag; default t. Dim/block the background; nil leaves outside-click policy to the caller.
;; :keys — Optional scoped ETAF key declarations; default nil. Entries (key callback label) follow the Host :keys contract.
;; :on-direction — Optional function (direction); default nil. Return handled/release according to the Host direction contract.
;; :animated — Optional flag; default t. Smoothly dim the modal backdrop on open via the shared animation clock.
;;
;; Show a controlled modal panel using the same floating surface as Popover.
;; TITLE defaults to Dialog and WIDTH to (ch 48).  HEIGHT optionally fixes the
;; panel to `(lh N)' rows, bounded by the visible window.  COMPACT removes
;; the body's vertical air so short forms stay dense.  The panel centers in
;; the window that displays its buffer when that window is graphical.  When
;; `etaf-ui-modal-use-child-frame' is non-nil and `etaf-ui-modal-host-function'
;; is installed (for example by `etaf-posframe'), centered modals project their
;; content into a floating child frame over the dimmed parent canvas and fall
;; back to in-buffer rendering on batch or non-graphical displays.
;; The header shows TITLE and a pointer-only x that requests ON-CLOSE; initial
;; focus still lands on the first body control.  Default content and footer
;; slots compose ordinary Components; a secondary CLOSE-LABEL button (default
;; "Close") ends the footer and requests ON-CLOSE; CLOSE-LABEL nil omits it so
;; the footer slot orders every action, for example [Cancel] [Delete].  A fixed
;; HEIGHT needs the body rows plus five for header, body air and footer.
;; The backdrop covers the root canvas and dims it, so covered text and
;; images stay visible while covered controls and their focus targets are
;; blocked. A pointer press on the backdrop requests ON-CLOSE without
;; activating covered controls; a press inside the panel does not dismiss it.
;; Keyboard navigation, dismissal and focus return follow Popover. Set
;; BACKDROP nil to paint no backdrop at all, for an application-owned
;; projection that keeps the underlying surface fully visible. A shell may
;; call etaf-ui-dismiss-outside-press for that unpainted outside-click policy.
;; KEYS and ON-DIRECTION declare the panel's scoped :keys and
;; direction handler; they never bind the backdrop or background controls.
;; Dialogs own no form data.
;;
;; Component: etaf-key-help (&key data on-close)
;; Parameters:
;; :data — Required snapshot plist returned by etaf-help-data, including string :title and scope/groups. Read-only descriptions, not executable commands.
;; :on-close — Required function (). Caller removes its controlled help View; normal etaf-help owns this automatically.
;;
;; Show DATA from etaf-help-data as a read-only searchable keyboard dialog.
;; ON-CLOSE is a zero-argument dismissal callback.  Descriptions are grouped
;; by source; wide windows use two columns, compact windows one scrolling
;; column.  `/` activates a native search field; descriptions never execute
;; commands.  Escape exits an edit first, then closes the dialog and restores
;; its opener.  Clicking the backdrop also closes help without activating the
;; background.  The minimum useful viewport is 48 columns by 18 rows; smaller
;; viewports clip deliberately without shrinking the font.  Loading etaf-ui
;; supplies this presentation for etaf-help automatically unless the caller
;; has already set etaf-help-view-function.  Applications need no help state
;; or extra mount.  Compose directly as (etaf-key-help :data snapshot
;; :on-close close) when owning a separate controlled dialog lifecycle.
;;
;; Component: etaf-media-viewer (&key open kind src source-size title subtitle caption duration on-close on-previous on-next on-ended autoplay audio volume)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed). Caller controls lifetime.
;; :kind — image/video/audio; default image.
;; :src — Source required for visible media: image Host file/descriptor, etaf-video source, or audio file path. Default nil supplies no media.
;; :source-size — Optional pair (width . height) of positive integer pixels; nil reads/probes image/video dimensions once.
;; :title, :subtitle, :caption — Optional strings; default nil. Header name, secondary name and media description.
;; :duration — Optional nonnegative number of seconds; default nil. Audio total duration.
;; :on-close — Required function (), even while closed. Caller closes the viewer.
;; :on-previous, :on-next — Optional functions (); default nil (no corresponding browse action). Caller switches media.
;; :on-ended — Optional function (); default nil. Invoked once when video or audio finishes naturally.
;; :autoplay — Optional flag; default t. Start audio/video playback on open; does not affect images.
;; :audio — Optional flag or :default (follows etaf-video-audio); default :default. Initial sound state.
;; :volume — Optional number in 0..100 or nil (follows etaf-video-audio-volume); default nil. Initial sound volume.
;;
;; Show one image, video or audio file in a controlled modal viewer over the
;; application, inside the same buffer.  KIND is `image' (default), `video'
;; or `audio'.  SRC is an `image' Host source (a file or image descriptor) or
;; an `etaf-video' source; for `audio' it is the audio file SRC played through
;; ffplay.  SOURCE-SIZE is the media's pixel (WIDTH . HEIGHT); without it the
;; viewer reads the image or probes the video once.  The media keeps its aspect
;; ratio and fits the live viewport, following window resizes; images are
;; not enlarged beyond their natural size, video fills the stage.  DURATION,
;; seconds, gives an audio file its total time.  The header
;; shows TITLE and SUBTITLE, default slot children (for example download or
;; share buttons) and a close control; an image's footer shows CAPTION, and
;; an audio stage shows it under the speaker placeholder.
;; Video and audio start when AUTOPLAY (default t) and get a transport bar:
;; play and pause, back and forward ten seconds, elapsed and total time, a seek
;; bar, the playback speed and sound.  Clicking the media toggles playback.
;; ON-PREVIOUS and ON-NEXT, when functions, add side arrows, the p/n keys and
;; two-finger swipes for browsing a gallery; with images the arrow keys
;; browse too, with video they seek five seconds.  Escape, q, the close
;; control and a press on the backdrop outside the header, media and footer
;; request ON-CLOSE.  Space or k toggles playback, j/l seek ten seconds, m
;; toggles sound and . cycles the speed.  While open the viewer's keys
;; outrank application keys, other printing keys do nothing, and focus
;; returns to the prior control on close.  The viewer covers the root
;; canvas's first viewport on a fixed dark scrim, so mount it in an
;; application whose root is one window tall, such as a (vh 100) shell.
;;
;; Component: etaf-reactions (&key items on-toggle choices add-label)
;; Parameters:
;; :items — List/ref/computed; default nil. Plists with unique non-nil scalar :key, nonempty :label, optional natural :count and boolean :chosen.
;; :on-toggle — Required function (key). Caller updates counts/choice state; no automatic mutation.
;; :choices — Optional alist (key . label); default nil (no picker). Unique non-nil scalar keys and nonempty labels.
;; :add-label — Nonempty string; default "Add reaction". Picker trigger's accessible name.
;;
;; Render one row of controlled reaction chips, for example under a chat
;; message.  ITEMS are plists with a unique non-nil scalar :key, a nonempty string
;; :label (usually an emoji), an optional natural :count shown after it and a
;; boolean :chosen that tints the chip with the accent; ITEMS may be a value
;; or ref.  Chosen and unchosen
;; chips share padding and weight, so toggling never moves a neighbour; only
;; a count gaining a digit widens its chip.  Pressing a chip calls ON-TOGGLE
;; with its key; the caller updates ITEMS.  CHOICES, an alist of (KEY . LABEL),
;; adds a trailing smile chip named ADD-LABEL (default "Add reaction") that
;; opens a Popover of the choices in rows of six; picking one closes it and
;; calls ON-TOGGLE with that key.  The row does not wrap, so keep ITEMS short
;; enough for its container.  Invalid props signal `etaf-view-error'.
;; Use (etaf-view (etaf-reactions :items items :on-toggle #'toggle)).
;;
;; Component: etaf-dropdown-menu (&key label items on-select disabled width icon placement)
;; Parameters:
;; :label — String; default "Actions". Trigger caption/help/accessibility name.
;; :items — List of plists; default nil (disabled). Unique non-nil scalar :key and unique nonempty :label; optional :disabled and icon name :icon.
;; :on-select — Optional function (key); default nil (disabled trigger). Menu closes before the callback.
;; :disabled — Optional flag; default nil. Disable the trigger.
;; :width — Host length; default (ch 28). Popover width.
;; :icon — Optional icon name; default nil. Replace trigger text with an icon, retaining :label as its name.
;; :placement — Anchor placement symbol; default bottom-start. Follows Popover.
;;
;; Render a Button and an anchored Popover of menu items. LABEL defaults to
;; Actions; WIDTH defaults to (ch 28). ITEMS use etaf-menu's item contract and
;; may carry an :icon shown before the label. ICON makes the trigger that icon,
;; with LABEL as its help text and accessible name. PLACEMENT (default
;; bottom-start) follows etaf-popover.
;; Enabled selection closes the menu and invokes ON-SELECT once with its key.
;; Disabled items remain visible and cannot be activated or focused. Empty
;; menus or nil ON-SELECT disable the trigger. Open state and the unique anchor
;; belong to each retained Component; application data remains caller-owned.
;; Keyboard shortcuts and focus return follow Popover. Use native etaf-menu
;; when completion matching, rather than an in-buffer menu, suits the task.
;;
;; Component: etaf-badge (&key text variant)
;; Parameters:
;; :text — Optional display value/ref/computed; default nil (empty).
;; :variant — neutral/success/warning/danger/info; default neutral. Semantic status paint.
;;
;; Render compact semantic status text using neutral, success, warning, danger
;; or info styling. The value is caller-owned and may be reactive.
;;
;; Component: etaf-divider (&key orientation label)
;; Parameters:
;; :orientation — horizontal/vertical; default horizontal.
;; :label — Optional display value/ref/computed; default nil. Centered label for a horizontal divider; ignored for vertical.
;;
;; Render a horizontal or vertical separator, optionally with a centered label.
;;
;; Component: etaf-progress (&key value max label variant animated)
;; Parameters:
;; :value — Required number/ref/computed; 0 <= value <= max. Display only, no change callback.
;; :max — Positive number/ref/computed; default 100. Total work units.
;; :label — Optional display value/ref/computed; default nil (empty caption).
;; :variant — neutral/success/warning/danger/info; default success. Fill color.
;; :animated — Optional flag; default nil. Smoothly transition fill width and percentage on the shared animation clock when mounted.
;;
;; Render a determinate progress bar. VALUE and MAX are numeric (or reactive)
;; with 0 <= VALUE <= MAX and MAX > 0. LABEL is optional.
;;
;; Component: etaf-alert (&key title message variant dismissible on-dismiss)
;; Parameters:
;; :title — Optional string; default nil (empty heading).
;; :message — Optional display value/ref/computed; default nil (empty body).
;; :variant — neutral/success/warning/danger/info; default info.
;; :dismissible — Optional flag; default nil. Add a dismissal button.
;; :on-dismiss — Function () required when :dismissible is non-nil; otherwise optional, default nil. Does not remove the Alert itself.
;;
;; Render an alert with semantic styling. A dismissible alert invokes ON-DISMISS;
;; the caller decides whether its state remains visible.
;;
;; Component: etaf-statistic (&key label value trend animated)
;; Parameters:
;; :label, :value, :trend — Optional display values/refs/computeds; default nil. Muted caption, emphasized metric and success-colored trend respectively; no arithmetic is performed.
;; :animated — Optional flag; default nil. Smoothly roll numeric values on the shared animation clock when mounted.
;;
;; Render a compact metric card from caller-owned display values.
;;
;; Component: etaf-empty (&key title description action-label on-action)
;; Parameters:
;; :title — Display value/ref/computed; default "Nothing here". Heading.
;; :description — Optional display value/ref/computed; default nil (empty).
;; :action-label — Optional display value; default nil (no action button).
;; :on-action — Function () required when :action-label is non-nil; otherwise optional, default nil.
;;
;; Render an empty state with optional action callback.
;;
;; Component: etaf-skeleton (&key width height animated)
;; Parameters:
;; :width — Host length; default stretch. Horizontal extent, e.g. (ch 24).
;; :height — Host length; default (lh 1). Vertical extent in standard rows when using lh.
;; :animated — Optional flag; default nil. Gently pulse the placeholder surface on the shared animation clock when mounted.
;;
;; Render a neutral loading placeholder without owning loading state.
;;
;; Component: etaf-spinner (&key style label variant interval)
;; Parameters:
;; :style — braille (default), dots, line or meter. Fixed-width glyph sequence.
;; :label — Optional string; default nil. Muted caption shown beside the glyph.
;; :variant — neutral/success/warning/danger/info; default info. Glyph color.
;; :interval — Positive number of seconds per frame; default 0.09.
;;
;; Render a shared-clock loading indicator whose Scope owns its frame sequence.
;; Fixed glyph width keeps adjacent labels stationary on every frame.  Invalid
;; style, label or interval signals `etaf-component-call-error'.

;; Component: etaf-card (&key title description icon variant width text-align on-press)
;; Parameters:
;; :title, :description — Optional display values/refs/computeds; default nil (omit row). Heading and muted summary.
;; :icon — Optional icon name; default nil. Draws the set's glyph before the title on the title's row.
;; :variant — Optional style name; default default. Adds a class; semantic accents (`primary', `info', `success', `warning', `danger', `important') tint the title and draw a left accent border from the Theme.
;; :width, :text-align — Optional size and alignment; default stretch and start (aligns header and body content).
;; :on-press — Optional function; default nil. Makes the whole surface activate with a hand pointer.
;;
;; Render a reusable titled surface with default content slots.
;; Card supplies a summary description; use Panel for a named header slot.
;;
;; Component: etaf-avatar (&key name initials src size variant lines background shape)
;; Parameters:
;; :name — Optional display value/ref/computed; default nil. Accessible name and source for derived initials.
;; :initials — Optional display value/ref/computed; nil/empty derives the first two name characters, or "?".
;; :src — Optional local image path/descriptor or reactive source; default nil. Circle photo, with initials fallback.
;; :size — Width; default (ch 5). Round avatars also accept an integer column count.
;; :variant — neutral/success/warning/danger/info; default info. Semantic color when :background is absent.
;; :lines — Positive integer; default 3. Fixed height in text lines.
;; :background — Optional color; default nil. Override semantic background, with white initials.
;; :shape — circle/square; default circle. Square and terminal frames use initials rather than a photo.
;;
;; Render a compact avatar with semantic color and accessible name.
;; SIZE is its width (`(ch N)' or an integer column count for round avatars);
;; LINES (default 3, a positive integer) its height, so a one- or two-line
;; list row can carry it. BACKGROUND, a color, replaces VARIANT with white
;; initials on that color, for per-person colors such as chat senders.
;; SRC is an optional photo: a local image file or an Emacs image descriptor
;; with :type and :data or :file. SHAPE `circle' (default) draws, on
;; graphical frames with SVG, the photo clipped to a disc, or the initials on
;; a colored disc when SRC is nil or unreadable; `square' and text frames use
;; an initials box with the initials on its (upper) middle line. Round images
;; are cached by source and cell size; pass `equal'-stable sources.
;;
;; Component: etaf-timeline (&key items)
;; Parameters:
;; :items — Required nonempty list of plists with :title, :content and optional :status. Display values use Label semantics; absent status displays "Update". Caller supplies chronological order.
;;
;; Render chronological item plists containing :title, :content and :status.
;;
;; Component: etaf-tag (&key text variant closable on-close)
;; Parameters:
;; :text — Optional display value/ref/computed; default nil (empty).
;; :variant — neutral/success/warning/danger/info; default neutral.
;; :closable — Optional flag; default nil. Show the close action.
;; :on-close — Function () required when :closable is non-nil; otherwise optional, default nil. Caller removes the tag from its data.
;;
;; Render a compact semantic tag; an optional close action remains caller-owned.
;; A closable tag requires ON-CLOSE. It reports dismissal without removing
;; itself; the caller decides whether to retain it.
;;
;; Component: etaf-kbd (&key keys)
;; Parameters:
;; :keys — Required nonempty list of nonempty strings, e.g. ("C-x" "C-s"). Display only; does not install bindings.
;;
;; Render a keyboard shortcut as accessible keycaps from a nonempty string list.
;; Compact rounded caps keep the normal line height; their subtle fill and
;; edge derive from the inherited panel background and foreground Theme tokens.
;;
;; Component: etaf-keycap (&key text level label active disabled on-press aria-label help-echo variant)
;; Parameters:
;; :text — Required nonempty string drawn in the cap.
;; :level — action or region; default action.
;; :variant — outline or filled; default outline. `outline' draws a hairline box with no fill; `filled' a soft chip.
;; :label — Optional caption drawn one column right of the cap; default nil.
;; :active — Optional flag; default nil. A region key fills with the accent and draws its letter in the panel background.
;; :disabled — Optional flag; default nil. Keeps the slot and the outline, drops the ink.
;; :on-press — Optional function (); default nil. Makes the cap a focusable button.
;; :aria-label, :help-echo — Optional accessible name and help; default nil.
;;
;; Render one key as a keycap.  An action key is one row high with a hairline
;; border and no fill; a region key is a 20px right-angled square.  A cap is an
;; inline control shorter than the standard row and takes no part in flex
;; shrinking, so a cap at the right end of a row is never squeezed.  Colour
;; comes from Theme tokens; ACTIVE and DISABLED change paint and ink only.
;;
;; Component: etaf-check-mark (&key state color glyph aria-label)
;; Parameters:
;; :state — empty (default), done, dropped or skipped.
;; :color — Optional ink override; default nil (inherits the surrounding foreground).
;; :glyph — Optional nonempty two-cell terminal spelling; default nil (the state's own word).
;; :aria-label — Optional accessible name; default nil (the state's own word).
;;
;; Render a task's check state as one right-angled box whose check, cross or
;; dash is a path, so all four states share one metric and a column of marks
;; never shifts.  Without SVG the mark falls back to two cells of text.
;;
;; Component: etaf-steps (&key items current on-change)
;; Parameters:
;; :items — Required nonempty list of plists with unique scalar :key and unique nonempty string :label.
;; :current — Required key/ref/computed present in :items. Marks the current step.
;; :on-change — Optional function (key); default nil. Requests a step; does not own workflow validation or content.
;;
;; Render ordered step buttons. ITEMS contain :key and :label; CURRENT and the
;; callback are controlled by the caller.
;; Keys and nonempty labels must be unique; CURRENT is a value/ref/computed
;; containing one of the keys. ON-CHANGE is optional and receives a selected key.
;;
;; Component: etaf-list (&key items on-select checkbox selected)
;; Parameters:
;; :items — List of plists; default nil (empty). Unique non-nil :key, nonempty string :title, optional string :description, string :meta and boolean :checked.
;; :on-select — Optional function (key); default nil. Receives the key, not the whole item; caller owns selection/navigation.
;; :checkbox — Optional flag; default nil. Draw a three-cell `[ ]`/`[x]` column fed by each item's :checked.
;; :selected — Optional item :key; default nil. Paint one row with the selection colours.
;;
;; Render a selectable list of full-width rows. ITEMS contain :key, :title,
;; optional :description shown after the title, optional :meta shown at the
;; right edge and optional :checked read by the :checkbox column. Selection
;; is reported to ON-SELECT and painted when SELECTED names a key; a checked
;; row greys its title and strikes it through. Keys are unique and titles are
;; nonempty strings; an empty list is allowed. The list owns no state: the
;; caller supplies both CHECKED and SELECTED and updates them itself.
;;
;; Component: etaf-date-picker (&key value label placeholder on-change disabled bind)
;; Parameters:
;; :value — ISO YYYY-MM-DD string/nil or ref/computed; default nil (empty).
;; :label, :placeholder — Strings; defaults "Date" and "YYYY-MM-DD". Caption and empty-value hint.
;; :on-change — Optional function (iso-date-or-nil); default nil. Complete valid edits report the date; clearing reports nil.
;; :disabled — Optional flag; default nil. Disable editing.
;; :bind — Optional writable ref; default nil. Non-nil excludes explicit :value and :on-change, even nil.
;;
;; Semantic date input on the catalog's native text field. The controlled
;; value is an ISO `YYYY-MM-DD' string or nil; typing a partial date keeps the
;; last accepted value and submitting rejects an invalid date with a readable
;; error instead of writing it.
;;
;; Component: etaf-tree (&key items expanded on-toggle on-select)
;; Parameters:
;; :items — Required nonempty list of nested plists with unique :key, nonempty string :label and optional :children lists.
;; :expanded — List/ref/computed; default nil (all branches closed). Contains expanded keys.
;; :on-toggle — Optional function (next-expanded-keys); default nil. Receives the whole next list, not just the branch key.
;; :on-select — Optional function (leaf-key); default nil. Branch activation requests expansion instead of selection.
;;
;; Render nested items with caller-owned expanded keys and selection callbacks.
;; Right opens and Left closes the focused branch through ON-TOGGLE.
;;
;; Component: etaf-calendar (&key month value on-change label)
;; Parameters:
;; :month — Two-integer list (year month-number); default (2026 1), not the current month. Month number is 1..12; pass the desired month explicitly.
;; :value — Optional integer day-of-month; default nil (no selection). Only a matching displayed day is highlighted; this is not a full date or ref prop.
;; :on-change — Optional function (date-list); default nil. Receives (year month day), unlike the integer :value prop.
;; :label — Optional display value; default "Calendar". Caption preceding the month/year.
;;
;; Render a controlled month grid; MONTH is `(YEAR MONTH)' and ON-CHANGE gets
;; `(YEAR MONTH DAY)'.
;;
;; Component: etaf-command-palette (&key open title items on-select on-close)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed).
;; :title — String; default "Command palette". Dialog title.
;; :items — List plists; default nil. Unique non-nil :key, nonempty string :title and optional string :description; follows List, not Menu's :label format.
;; :on-select — Optional function (key); default nil. Caller executes the action and decides whether to close; no built-in search/filtering.
;; :on-close — Required function (), even while closed. Caller updates visibility.
;;
;; Compose a modal Dialog and List for caller-owned command selection.
;;
;; Function: etaf-ui-qr-paint (rows &optional quiet)
;;;###autoload (autoload 'etaf-ui-qr-paint "etaf-ui" nil nil)
;; Paint module ROWS as a scannable code string.
;; ROWS is a list of strings of "0" and "1"; a shorter row is blank past its
;; end.  QUIET is the number of blank modules drawn on every side, four when
;; omitted.  Two module rows share one text row through half blocks, so the
;; code stays square in a text cell twice as tall as it is wide, and every
;; glyph keeps pure black on white because a scanner needs that contrast in
;; both palettes.  The caller or its backend supplies the rows; the function
;; paints text and contacts nothing.
;;
;; Component: etaf-ui-qr-login (&key open code status hint on-close)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed). Caller owns visibility.
;; :code — Optional painted-code string/ref; default nil (no code). Normally from `etaf-ui-qr-paint'.
;; :status — Optional string/ref; default nil. Transport state or the site's own error.
;; :hint — Optional string; default "请用手机客户端扫码，并在手机上确认登录。". Explains the confirmation step.
;; :on-close — Required function (), even while closed. Caller updates visibility.
;;
;; Compose a modal Dialog with the painted code and a status line for a
;; caller-owned sign-in cycle.  On graphical displays with SVG support, a
;; half-block code from `etaf-ui-qr-paint' renders as a crisp square vector SVG
;; image sized to fit the live viewport so East Asian ambiguous block widths and
;; font line spacing never distort scannability; terminals and builds without
;; SVG keep half-block text rendering.  The page underneath keeps its content
;; and only dims, and Escape, the header close control and the footer cancel
;; button request ON-CLOSE.  The component sends no request and asks for no
;; credentials; mount it as the application shell's last child.
;;
;; Component: etaf-tabs (&key items active on-change variant framed)
;; Parameters:
;; :items — Required nonempty plist list; unique scalar :key and nonempty unique :label; optional scalar :count and symbol :ref.
;; :active — Required key/ref/computed present in :items. Selected tab.
;; :on-change — Required function (key). Caller updates selection and content.
;; :variant — Optional style name; default underline. Adds a class; selection paint is shared across variants.
;; :framed — Optional boolean; default t. The strip draws its own outer frame; nil leaves every outer edge to a surrounding panel and keeps only the dividers.
;;
;; The strip is one Tab stop, entered at the selected tab; Left/Right move focus inside it and RET selects.  At either end the key is consumed.
;;
;; Render controlled tabs from unique scalar keys and labels.  An item may
;; carry a scalar :count and a symbol :ref, so callers can address a tab by
;; name.  ON-CHANGE receives the selected key; content can be composed with
;; ordinary conditional Views.
;;
;; Component: etaf-accordion (&key items open on-toggle multiple)
;; Parameters:
;; :items — Plist list; default nil (empty). Unique non-nil :key and unique nonempty :label; :content is a string or pure function () returning a View. An optional symbol :ref gives that row a stable Host ref, so a repaint around the accordion updates the row in place.
;; :open — List of item keys/ref/computed; default nil (all closed). At most one key when :multiple is nil.
;; :on-toggle — Required function (next-open-keys), not (key). Caller stores the complete next list.
;; :multiple — Boolean; default t. Allow several expanded sections.
;;
;; Render controlled disclosure sections. Items contain :key, :label and
;; string or zero-argument function :content. OPEN is a list of expanded keys.
;; A directional icon shows expansion; the accessible name remains :label.
;;
;; Component: etaf-breadcrumb (&key items on-select)
;; Parameters:
;; :items — Required nonempty list of strings, ordered from root to current location.
;; :on-select — Optional function (zero-based-index); default nil (read-only labels). No navigation state is stored.
;;
;; Render a navigation trail of strings; ON-SELECT receives a zero-based index.
;;
;; Component: etaf-tooltip (&key open anchor text placement on-close)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed). No automatic hover trigger.
;; :anchor — Semantic Host :id required when open; nonempty string or symbol.
;; :text — Required string/ref/computed, including while closed. Tooltip content.
;; :placement — Anchor placement symbol; default top-start. Follows Popover.
;; :on-close — Required function (), even while closed. Caller changes visibility.
;;
;; Show controlled short text near an anchor using Popover placement. The caller
;; controls visibility; no second hover event system is introduced.
;;
;; Component: etaf-toast (&key open anchor message title variant on-close)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed). Caller controls timing; no timer is created.
;; :anchor — Semantic Host :id required when open; nonempty string or symbol. Placement is top-end.
;; :message — Required string/ref/computed, including while closed. Notification content.
;; :title — String; default "Notification". Panel header.
;; :variant — neutral/success/warning/danger/info; default info. Semantic badge paint.
;; :on-close — Required function (), even while closed. Caller dismisses the notification.
;;
;; Show a controlled dismissible anchored notification. The caller owns its
;; lifecycle and message state.

;; Component: etaf-context-menu (&key label items on-select disabled width)
;; Parameters:
;; :label — String; default "More". Explicit action trigger; does not install a global right-click handler.
;; :items — List of Menu item plists; default nil (disabled). Unique non-nil scalar :key, unique nonempty :label, optional :disabled/:icon.
;; :on-select — Optional function (key); default nil (disabled). Menu closes before callback.
;; :disabled — Optional flag; default nil. Disable the trigger.
;; :width — Host length; default (ch 30). Menu width.
;;
;; Compose a keyboard and mouse accessible context action trigger from the
;; DropdownMenu contract.
;;
;; Component: etaf-drawer (&key open title placement width modal on-close)
;; Parameters:
;; :open — Value/ref/computed; default nil (closed). Caller owns visibility.
;; :title — String/nil; default "Drawer". Optional panel heading.
;; :placement — left/right; default right. Side of the root canvas.
;; :width — Host length; default (ch 42). Clamped to the root width.
;; :modal — Boolean; default t. Block the background while open.
;; :on-close — Required function (), even while closed. Caller updates :open.
;;
;; Show a controlled left or right side surface with default and footer slots.
;; PLACEMENT defaults to right, WIDTH to (ch 42), and MODAL to t. Width is
;; constrained to the root canvas. OPEN accepts a value/ref/computed; ON-CLOSE
;; must be a function. Focus, dismissal, return and disposal follow Dialog.
;;
;; Variable: etaf-ui-modal-host-function
;; Optional child-frame modal host callback, default nil.  When non-nil and
;; `etaf-ui-modal-use-child-frame' is enabled on a graphical display, centered
;; `etaf-dialog' modals (including `etaf-key-help') pass a spec plist
;; (:key :parent-buffer :parent-window :panel :title :width-px :height-rows
;; :max-height-rows :help-p :theme :appearance :view :on-close) and expect a
;; handle plist (:update :close :frame :runtime-fn) while keeping the dimmed
;; animated backdrop scrim in the parent buffer.  `etaf-posframe' installs its
;; host automatically when loaded.
;;
;; Variable: etaf-ui-modal-use-child-frame
;; When non-nil (default nil), project centered `etaf-dialog' modals through
;; `etaf-ui-modal-host-function' on graphical displays; nil keeps all modals
;; rendered inside the parent buffer with single-pass centering and uniform
;; backdrop dimming.
;;
;; Function: etaf-ui-dismiss-outside-press ()
;;;###autoload (autoload 'etaf-ui-dismiss-outside-press "etaf-ui")
;; Dismiss every mounted floating surface (dialog, launcher, switcher,
;; popover, menu or drawer) in the current event's Runtime whose panel does
;; not contain the pressed Host, requesting each one's ON-CLOSE, and return
;; the number dismissed.  Call it from the `:on-press' or `:on-press-capture'
;; callback of a Host enclosing the application, such as a shell root, to give
;; unpainted (`:backdrop' nil) modals and popovers click-outside dismissal.
;; A surface opened by the press being handled is not mounted yet and stays
;; open.  Outside a Host event callback it signals `etaf-event-error'.
;;
;; Function: etaf-ui-surfaces-open ()
;;;###autoload (autoload 'etaf-ui-surfaces-open "etaf-ui" nil t)
;; Mount the runnable floating-component example in *ETAF UI Surfaces* and
;; return its buffer. Interactive calls display it. Reopening resets its
;; application state; unmount the Runtime or close the buffer to dispose it.

;; Function: etaf-ui-gallery-open (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-ui-gallery-open "etaf-ui" nil t)
;; Mount the complete component browser and return its buffer (default
;; *ETAF UI Gallery*). An explicit buffer/name allows independent mounts;
;; interactive calls display it. Browse categories or search names/purposes,
;; operate live specimens, switch a scoped light/dark Theme, and read each
;; Component's signature, parameter types/defaults, callbacks and constraints
;; in its usage panel. Reference text comes from this public Commentary,
;; read before mounting; keep the installed etaf-ui.el source available.
;; Complete runnable examples use the same bindings/View as the live specimen.
;; Specimen state survives browsing and Theme changes;
;; reset or reopening restores defaults. Unmount or kill the buffer to release
;; its local controllers. Unrelated nonempty buffers or mounted applications
;; raise user-error instead of being replaced.
;;
;; Function: etaf-ui-window-resize-open (&optional buffer-or-name)
;;;###autoload (autoload 'etaf-ui-window-resize-open "etaf-ui" nil t)
;; Mount a controlled catalog window with a fixed body and independent peer.
;; Interactive calls show the buffer. The title moves; eight native handles
;; resize; Shift locks and Escape restores the starting rectangle. Reopening
;; replaces only an existing example mount. Unmount or kill it to dispose.
;; This example is a GUI workload, not a performance certification.
;;
;; Component: etaf-ui-icon (&key name set size color face lines min-width help-echo on-press tab-index aria-label id class ref)
;; Parameters:
;; :name — Required icon symbol or nonempty string. Unknown names use a safe text fallback.
;; :set — Optional registered set symbol; nil starts at etaf-ui-icon-default-set.
;; :size — Positive number; default 1.0. Relative scale clamped to the reserved rows.
;; :lines, :min-width — Row count 1/2 (default 1) and minimum cell width >= 1 (default 2).
;; :color, :face — Optional foreground and face/plist; default nil. Only face foreground/background are used; color overrides foreground.
;; :on-press — Optional function (); default nil. Makes the complete icon box actionable.
;; :tab-index — Optional integer; nil uses 0 when actionable; negative skips Tab.
;; :help-echo, :aria-label — Optional help and accessible name; default nil. Name falls back to string help, then icon name.
;; :id, :class, :ref — Optional Host identity, extra classes and reference; default nil.
;;
;; Render NAME in one standard row, or exactly two with :lines 2. SIZE defaults
;; to 1.0 and is clamped within those rows; font ascent and descent must each
;; fit the default baseline. MIN-WIDTH is in cells (default 2). ON-PRESS is a
;; zero-argument callback on the complete box, with ordinary ETAF focus/events.
;; A pressable icon is a Tab stop with TAB-INDEX (default 0); a negative
;; TAB-INDEX keeps it clickable but out of Tab order, for example when its
;; enclosing list already owns the keyboard. ARIA-LABEL names it in
;; `etaf-palette' and defaults to a string HELP-ECHO, then NAME.
;; FACE accepts a face name or plist; only foreground/background are used so
;; caller typography cannot enlarge the icon. COLOR overrides its foreground.
;; SVG uses currentColor and cached centered images. On graphical frames with
;; SVG, font sets draw their glyph as SVG text in the same canvas, so ink that
;; exceeds the font's declared ascent/descent is never clipped by the row.
;; Two-row icons use slices of one canvas. Without graphical SVG, font sets
;; use their clamped face as text; two-row icons reserve both rows and put a
;; line-safe text variant in the first row.
;; Resolve NAME in SET, then `etaf-ui-icon-default-set', then sys, then svg
;; (its line-safe text variant without graphical SVG), then show the name as
;; plain text (control/non-ASCII characters are escaped). On a text terminal an
;; SVG request consults `etaf-ui-terminal-icon-set' before SET, because a
;; terminal cannot draw the artwork. Absent fonts/glyphs follow the same
;; lookup; terminal font sets use their glyph as text.
;; An unknown explicitly requested/default set is a usage error, wrapped by
;; ETAF during rendering. Invalid geometry/callback props fail before publish.
;; Use (etaf-view (etaf-ui-icon :name 'play :set 'svg :on-press action)).
;;
;; Function: etaf-ui-icon (name &key set (size 1.0) color face (lines 1) (min-width 2) help-echo on-press tab-index aria-label id class ref)
;;;###autoload (autoload 'etaf-ui-icon "etaf-ui" nil nil)
;; Return the same typed icon View from ordinary Elisp with positional NAME.
;; Pass it directly to etaf-mount, or use the Component's :name form in the DSL.
;; The component contract above governs rendering, lookup and box ownership.
;;
;; Function: etaf-ui-icon-lines (name &key set (size 1.0) color face (lines 1))
;;;###autoload (autoload 'etaf-ui-icon-lines "etaf-ui" nil nil)
;; Return owned propertized strings for one or two standard icon rows.
;; Resolution, fallback and colouring match etaf-ui-icon. SIZE must be positive;
;; LINES must be 1 or 2. Invalid names/sets follow the icon component contract.
;; Resolve once in a Component binding and select these strings from retained
;; Host text expressions instead of adding a positioned overlay. Returned
;; strings are independent; shared image values must not be mutated.
;;
;; Component: etaf-ui-toggle-icon (&key value off on set size color on-color face lines min-width help-echo on-press tab-index aria-label id class ref)
;; Parameters:
;; :value — Boolean/ref/computed; default nil. Chooses :off or :on; caller owns changes.
;; :off, :on — Required icon symbols or nonempty strings. Resolved before retained updates.
;; :set — Optional registered set symbol; nil starts at etaf-ui-icon-default-set.
;; :size — Positive number; default 1.0. Relative scale clamped to the reserved rows.
;; :lines, :min-width — Row count 1/2 (default 1) and minimum cell width >= 1 (default 2).
;; :color, :on-color, :face — Optional colors and face/plist; default nil. On-color falls back to color; face supplies paint only.
;; :on-press — Optional function (); default nil. Requests caller-owned state changes; no automatic toggle or :bind.
;; :tab-index — Optional integer; nil uses 0 when actionable; negative skips Tab.
;; :help-echo, :aria-label — Optional help and accessible name; default nil. Name falls back to string help, then "OFF / ON".
;; :id, :class, :ref — Optional Host identity, extra classes and reference; default nil.
;;
;; Render one icon that switches between OFF and ON through retained Host
;; text instead of repainting the View. VALUE is a boolean or a reactive
;; source; both variants resolve while rendering and each row then reads
;; VALUE directly, so a change publishes a retained text update. OFF and ON
;; may name the same icon when only ON-COLOR differs, which turns a colour
;; state into the same retained update. ON-COLOR defaults to COLOR. SET,
;; SIZE, FACE, LINES, MIN-WIDTH (cells, default 2), HELP-ECHO, ON-PRESS,
;; TAB-INDEX, ID, CLASS and REF match `etaf-ui-icon'; the complete box is the
;; ON-PRESS target. ARIA-LABEL defaults to a string HELP-ECHO, then "OFF / ON".
;; Use (etaf-view (etaf-ui-toggle-icon :value playing :off 'play :on 'pause)).
;;
;; Variable: etaf-ui-icon-default-set
;; Registered fallback style, initially nerd. Bind or set it before rendering.
;; Registry changes/default changes take effect on the next render; existing
;; mounted values remain valid and are not implicitly rerendered.
;;
;; Variable: etaf-ui-terminal-icon-set
;; Icon set consulted first on a text terminal for an SVG request, initially
;; tty. Set it to a registered font set whose glyphs the terminal font
;; contains, such as nerd after installing a Nerd Font, to keep one icon family
;; in a terminal. Names the set lacks fall through to the requested set.
;;
;; Function: etaf-ui-icon-set-register (name spec)
;;;###autoload (autoload 'etaf-ui-icon-set-register "etaf-ui" nil nil)
;; Register symbolic NAME with SPEC, replacing a previous registration, and
;; return NAME. Font SPEC: :kind font, :family string, positive float :height
;; relative to default, :glyphs alist of symbolic names to single glyphs.
;; SVG SPEC: :kind svg, :viewbox four numbers with positive width/height,
;; :paths alist of names to SVG bodies and/or :draw alist of names to nullary
;; functions returning bodies, :inset nonnegative pixels (default 2). Bodies
;; use currentColor; draw functions must be pure, and their output is cached.
;; Optional :fallback alist supplies printable ASCII strings; absent entries
;; display their name. Invalid specs signal user-error without replacement.
;; Treat stored specs as immutable; re-register to invalidate cached variants.
;; Font maps must contain actual glyphs, never substitute Unicode codepoints
;; for missing icons. The GUI check enforces actual family/coverage for every
;; registered name. Font sets share one face per frame/clamped size; SVG sets
;; share one image sizing policy. No style-specific branches are needed.
;;
;; Function: etaf-ui-icon-set-remove (name)
;;;###autoload (autoload 'etaf-ui-icon-set-remove "etaf-ui" nil nil)
;; Remove NAME and invalidate cached variants; absent NAME is harmless.
;; Return nil. Existing rendered values remain valid until the next render.
;;
;; Function: etaf-ui-icon-sets ()
;;;###autoload (autoload 'etaf-ui-icon-sets "etaf-ui" nil nil)
;; Return registered set names in registration order. Built-ins are nerd, fa,
;; material, octicons, sys and svg. Their semantic coverage can differ.
;;
;; Function: etaf-ui-icon-set-spec (name)
;;;###autoload (autoload 'etaf-ui-icon-set-spec "etaf-ui" nil nil)
;; Return the stored immutable SPEC or nil for an unregistered NAME.
;;
;; Function: etaf-ui-icon-names (&optional set)
;;;###autoload (autoload 'etaf-ui-icon-names "etaf-ui" nil nil)
;; Return SET's own names, or the union of all sets when nil. This query never
;; performs fallback lookup. Unknown non-nil SET signals user-error.
;;
;; Function: etaf-ui-icon-metrics (set &optional frame)
;;;###autoload (autoload 'etaf-ui-icon-metrics "etaf-ui" nil nil)
;; Return :family :height :line-pixel-height :line-height :fit for SET/FRAME
;; before clamping. Font row metrics include default ascent/descent; missing
;; fonts report nil pixel height/fit. In batch/TTY the declared relative height
;; gives an estimate, not a font-availability guarantee. SVG reports its line
;; box. FRAME defaults to selected-frame; an unknown SET signals user-error.
;;
;; Function: etaf-ui-svg-rect (x y width height &rest attributes)
;;;###autoload (autoload 'etaf-ui-svg-rect "etaf-ui" nil nil)
;; Return SVG markup for a rectangle at X/Y with positive WIDTH and HEIGHT.
;; ATTRIBUTES accept :rx, :ry, :transform and the shared paint family
;; :fill, :stroke, :stroke-width, :stroke-linecap, :stroke-linejoin,
;; :stroke-dasharray and :opacity.
;;
;; Function: etaf-ui-svg-circle (cx cy radius &rest attributes)
;;;###autoload (autoload 'etaf-ui-svg-circle "etaf-ui" nil nil)
;; Return SVG markup for a circle centred at CX/CY with positive RADIUS.
;; ATTRIBUTES accept :transform and the shared paint family :fill, :stroke,
;; :stroke-width, :stroke-linecap, :stroke-linejoin, :stroke-dasharray and
;; :opacity.
;;
;; Function: etaf-ui-svg-line (x1 y1 x2 y2 &rest attributes)
;;;###autoload (autoload 'etaf-ui-svg-line "etaf-ui" nil nil)
;; Return SVG markup for a line from X1/Y1 to X2/Y2. ATTRIBUTES accept
;; :stroke, :stroke-width, :stroke-linecap, :stroke-linejoin,
;; :stroke-dasharray and :opacity.
;;
;; Function: etaf-ui-svg-path (d &rest attributes)
;;;###autoload (autoload 'etaf-ui-svg-path "etaf-ui" nil nil)
;; Return SVG markup for path data D, a nonempty string. ATTRIBUTES accept
;; :fill :stroke :stroke-width :stroke-linecap :stroke-linejoin
;; :stroke-dasharray :opacity.
;;
;; Function: etaf-ui-svg-text (x y text &rest attributes)
;;;###autoload (autoload 'etaf-ui-svg-text "etaf-ui" nil nil)
;; Return SVG markup for single-line TEXT anchored at X/Y; its content is XML
;; escaped. ATTRIBUTES accept :font-family :font-size :font-weight
;; :text-anchor :dominant-baseline :fill :stroke :stroke-width :opacity.
;;
;; Function: etaf-ui-svg-group (children &rest attributes)
;;;###autoload (autoload 'etaf-ui-svg-group "etaf-ui" nil nil)
;; Return SVG markup for group CHILDREN sharing ATTRIBUTES.
;;
;; Function: etaf-ui-svg-image (body width height viewbox &optional preserve-aspect-ratio)
;;;###autoload (autoload 'etaf-ui-svg-image "etaf-ui" nil nil)
;; Return an (image :type svg :data STRING) descriptor showing scene BODY in a
;; WIDTH by HEIGHT pixel box over viewbox (X Y WIDTH HEIGHT). Callers compose
;; BODY from the element helpers above and pass the result to an image source
;; or image Host, such as `etaf-tile-grid' :cell-image. PRESERVE-ASPECT-RATIO
;; is nil (SVG default centring) or `none' (scale the complete scene to the
;; box). Keep a text fallback for terminal frames; Ebox draws one image per
;; displayed row, so slice per cell only where each cell owns its own target
;; and slice once per block row for passive artwork. Cache a composed scene
;; with its state key and clear the cache at a fixed bound.
;; All element helpers validate geometry and attribute keys, escape text and
;; attribute values, format numbers identically, and omit nil values;
;; invalid input signals `etaf-ui-svg-error'.
;;
;; Error: etaf-ui-svg-error
;; Invalid input to the etaf-ui-svg scene helpers
;; Catch this condition with condition-case; invalid scenes produce no markup.
;;
;; The markdown document renderer turns the block tree produced by
;; `etaf-ui-markdown-parse' into ordinary ETAF Views.  It is data-driven:
;; every color comes from the caller's `:palette' alist and media or code
;; blocks can be delegated to caller callbacks, so the same renderer serves a
;; previewer, a manual reader or any other document view.  It owns no state
;; and no buffer, so it renders headless in tests and inside a mounted
;; Component alike.
;;
;; Function: etaf-ui-markdown-parse (text &optional flavor)
;; Parse markdown TEXT into a document plist, or signal `etaf-ui-markdown-error'.
;; FLAVOR is a dialect name from `etaf-ui-markdown-flavors' (`etaf' is the
;; default), a feature plist overriding individual flags and extensions, or
;; nil for `etaf-ui-markdown-flavor'.  Keys are `:meta' (front matter alist),
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
;; Variable: etaf-ui-markdown-code-renderers
;; Renderers for one fenced language, as an alist of (LANGUAGE . FUNCTION).
;; FUNCTION receives the block and the rendering environment and returns a
;; View, or nil to keep the default.  This is where a language that needs a
;; program belongs -- a diagram language, a typesetter -- so the parser stays
;; pure Elisp and a missing program only means that block shows its source.
;; The environment's `:render-code-block' is consulted first and overrides the
;; table for one caller.
;;
;; Function: etaf-ui-markdown-highlight-code (language text)
;; Return runs colouring TEXT as LANGUAGE, or nil to paint it in one colour.
;; Emacs already knows how to read the language: this runs its major mode over
;; the text in a scratch buffer and turns the faces `font-lock' produced into
;; runs of `(:text STRING :props PLIST)'.  Only what a text run can express is
;; kept (colour, weight, slant, underline, strike-through), so a page of code
;; shows the colours the source buffer shows.  The answer is a pure function of
;; (LANGUAGE . TEXT) and is cached, so a repaint costs one lookup; a language
;; with no available mode, or a block over `etaf-ui-markdown-highlight--max-lines'
;; or `--max-chars', returns nil instead of fontifying.  Never signals.
;;
;; Variable: etaf-ui-markdown-highlight-languages
;; Fence language names and the major mode that reads each one, as an alist of
;; (NAME . MODE).  A mode whose library cannot be loaded is skipped, so adding a
;; name never makes a document fail to render.
;;
;; Function: etaf-ui-markdown-math-text (source)
;; Return SOURCE, a TeX formula, written as plain text; never signals.
;; The page paints a formula as text rather than an image: command names get
;; their symbols, `\frac{a}{b}' becomes `a/b', `\sqrt{x}' becomes `√(x)',
;; and `^{}' and `_{}' become the Unicode letters of that position.  Anything
;; the mapping does not know keeps its own characters, so a formula never
;; turns into noise.  Callers that want real typesetting return a View from
;; `:render-math' instead, which leaves this function as the fallback.
;;
;; Function: etaf-ui-markdown-view-block (block env)
;; Return BLOCK rendered as one ETAF View, or nil when nothing renders.
;; BLOCK is one top-level block of `etaf-ui-markdown-parse' and ENV is the
;; rendering environment described below.  A block that expands to several
;; Views is wrapped in one column, so callers own one node per block.
;;
;; Function: etaf-ui-markdown-view-blocks (blocks env &optional tight)
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
;; `etaf-ui-markdown-error'.  `:open-link' is called with a link URL;
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
;; Variable: etaf-ui-markdown-flavor
;; Default markdown dialect of `etaf-ui-markdown-parse', `etaf' unless set.
;; A FLAVOR argument overrides it.  `etaf' is the widest preset and what a
;; reader gets by opening a document; `gfm' and `commonmark' name the narrower
;; ones to use when a document has to parse exactly as those specifications
;; say, and a feature plist toggles individual flags and extensions.
;;
;; Variable: etaf-ui-markdown-flavors
;; Named markdown dialects and the syntax each one enables.
;; `commonmark' is the CommonMark core; `gfm' adds GitHub's extensions there
;; as well: tables, task lists, strikethrough, bare autolinks, footnotes,
;; alert blocks and front matter; `etaf' adds definition lists, sub- and
;; superscript, abbreviations and `$' math on top of `gfm'.  A preset is only
;; a set of switches over one parser, so a document written for one of them
;; still parses under another, with the syntax it did not enable showing as
;; literal text.  None of the added syntax needs an external program.
;;
;; Variable: etaf-ui-markdown-gfm-features
;; The feature plist GitHub Flavored Markdown enables: front matter, tables,
;; task lists, strikethrough, autolinks, footnotes and alert blocks.
;; A preset spells its own flags out, so extending this list never changes what
;; an older preset meant; use it to start a plist of your own.
;;
;; Function: etaf-ui-markdown-extension-p (name)
;; Return non-nil when the document being parsed enables extension NAME.
;; NAME is one of the symbols in a preset's `:extensions' list, such as
;; `emoji' or `definition-list'.  A parser extension calls this to decide
;; whether its syntax runs at all; disabled syntax stays literal text.
;;
;; Variable: etaf-ui-markdown-block-extensions
;; Block syntax the parser adds, as an alist of (NAME RECOGNIZER).
;; RECOGNIZER takes the remaining source lines and returns (BLOCK . REST) when
;; it claims them; `etaf-ui-markdown-extension-p' decides whether it runs.
;; Adding a block syntax means adding its recognizer here and its name to a
;; preset, which keeps one parser instead of forking it per dialect.
;;
;; Variable: etaf-ui-markdown-inline-extensions
;; Inline syntax the parser adds, as (NAME TRIGGER-CHAR RECOGNIZER).
;; TRIGGER-CHAR opens the syntax, or is nil for a recognizer that starts at a
;; word character such as an abbreviation.  RECOGNIZER takes (TEXT POSITION
;; END) and returns (NODE . NEXT) when it claims the text there.  The same
;; gating by `etaf-ui-markdown-extension-p' applies, so an inline extension a
;; preset does not enable never runs and its text stays as written.
;;
;; Variable: etaf-ui-markdown-emoji
;; Emoji shortcodes this renderer paints, as an alist of (NAME . CHARACTER).
;; A document writes `:tada:' and the page shows the character; a name outside
;; this table keeps its colons, and a time such as `12:30:45' is never a
;; shortcode.  Add entries here to teach the renderer more of them.
;;
;; Variable: etaf-ui-markdown-subscript-table
;; Characters a `~subscript~' run can be written with, as (CHAR . SCRIPT).
;; A character missing from the table keeps the source spelling, so the
;; construct paints what Unicode can express and never invents glyphs.
;;
;; Variable: etaf-ui-markdown-superscript-table
;; Characters a `^superscript^' run can be written with, as (CHAR . SCRIPT).
;; A character missing from the table keeps the source spelling, so the
;; construct paints what Unicode can express and never invents glyphs.
;;
;; Error: etaf-ui-markdown-error
;; Markdown document error
;; Signaled for an unknown dialect, a missing palette and unknown palette
;; keys; catch this condition with condition-case.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-ui")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-ui.el" dir))
                                (file-exists-p (expand-file-name "etaf-ui.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(defconst etaf-ui--root
  (or (catch 'found
        (dolist (file (list (bound-and-true-p byte-compile-current-file)
                            (and load-file-name
                                 (not (string-suffix-p ".eln" load-file-name))
                                 load-file-name)
                            (locate-library "etaf-ui")
                            buffer-file-name))
          (when (stringp file)
            (let ((dir (file-name-directory file)))
              (when (and dir
                         (or (file-exists-p (expand-file-name "etaf-ui.el" dir))
                             (file-exists-p (expand-file-name "etaf-ui.elc" dir))))
                (throw 'found dir))))))
      default-directory)
  "Directory of this package entry, resolved when it is loaded.
Native-compiled entries live in `eln-cache', so their location says
nothing about where the package directory is.")

(require 'etaf-ui-basic)
(require 'etaf-ui-drop)
(require 'etaf-ui-edge)
(require 'etaf-ui-pane)
(require 'etaf-ui-icon)
(require 'etaf-ui-svg)
(require 'etaf-ui-input)
(require 'etaf-ui-field)
(require 'etaf-ui-editor)
(require 'etaf-ui-selection)
(require 'etaf-ui-feedback)
(require 'etaf-ui-navigation)
(require 'etaf-ui-surface)
(require 'etaf-ui-key-help)
(require 'etaf-ui-reactions)
(require 'etaf-ui-media)
(require 'etaf-ui-table)
(require 'etaf-ui-data)
(require 'etaf-ui-tile-grid)
(require 'etaf-ui-svg-stage)
(require 'etaf-ui-text-grid)
(require 'etaf-ui-cell-line)
(require 'etaf-ui-sheet)
(require 'etaf-ui-playing-card)
(require 'etaf-ui-advanced)
(require 'etaf-ui-window)
(require 'etaf-ui-desktop)
(require 'etaf-ui-markdown-parse)
(require 'etaf-ui-markdown)

;; Absolute files: an installed archive must not depend on the package root
;; being on `load-path', which some hosts do not add.
(autoload 'etaf-ui-surfaces-open
  (expand-file-name "examples/etaf-ui-surfaces" etaf-ui--root) nil t)
(autoload 'etaf-ui-gallery-open
  (expand-file-name "examples/etaf-ui-gallery" etaf-ui--root) nil t)
(autoload 'etaf-ui-window-resize-open
  (expand-file-name "examples/etaf-ui-window-resize" etaf-ui--root) nil t)

(provide 'etaf-ui)
;;; etaf-ui.el ends here
