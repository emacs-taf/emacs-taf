# Grids and Character Surfaces

Three catalog components give applications fixed-geometry character surfaces: a tile grid whose cells project coordinate callbacks, a text grid of independently retained fixed-width text rows, and a playing card whose intrinsic dimensions never stretch to fill a viewport. They own layout and activation, never the caller's board, board state, timers or game rules, and their dimensions stay what the caller declared even when the window changes. [Images](images.md) defines the image Host the cells use, [UI Overview](ui-overview.md) the shared contract, and [Grid Layout](grid-layout.md) the underlying track model.

## The tile grid

<!-- index: etaf-tile-grid; coordinate callbacks; fixed cells; cell image -->

#### Component: etaf-tile-grid (&key rows columns cell-width cell-height cell-background cell-color cell-text cell-label cell-image cell-ref on-cell-press on-cell-focus)

Render ROWS by COLUMNS fixed cells with stable coordinate identities.

**Arguments.** ROWS and COLUMNS are positive integers; CELL-WIDTH (character columns, default 2) and CELL-HEIGHT (text lines, default 1) are positive integers and stay fixed when the viewport changes. The callbacks receive zero-based ROW and COLUMN: CELL-BACKGROUND returns a color or nil; CELL-COLOR supplies the foreground (nil inherits); both may return deferred Theme tokens. CELL-TEXT returns one line fitting CELL-WIDTH (default a space). CELL-IMAGE returns a local file path, an Emacs image descriptor including generated SVG, or nil — an image fills the fixed cell through the image Host, nil uses CELL-TEXT instead, and source decoding failures use the image Host's placeholder. CELL-LABEL returns the accessible name and help text (default `"Cell r,c"`). CELL-REF returns a distinct Host reference per cell; omitted references are instance-local. ON-CELL-PRESS handles keyboard and mouse activation, and without it cells are read-only; ON-CELL-FOCUS reports the coordinates when focus enters a cell.

**Semantics.** The grid owns layout and activation, not board state or timers: it reads the caller's refs inside the callbacks so unchanged cells retain their content, and it never maintains a second selection. With a press callback every cell is a `button` with a Tab index inside a `grid` focus group; without one the cells are inert. Cells clip hidden overflow and center their content, and a focus outline marks the focused cell.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ROWS, COLUMNS, CELL-WIDTH or CELL-HEIGHT is not a positive integer, or when one of the coordinate callbacks is neither a function nor nil. A CELL-TEXT or CELL-LABEL that is not a single line fitting the cell width also signals at render time.

**Example.**

```elisp
(etaf-tile-grid :rows 8 :columns 12 :cell-width 2 :cell-height 1
                :cell-text (lambda (_r _c) ".")
                :on-cell-press (lambda (row column) (select-cell row column)))
```

**See also.** `etaf-text-grid`, [Images](images.md).

## The text grid

<!-- index: etaf-text-grid; fixed-width rows; monospace surface; scrolling text grid; large row counts -->

#### Component: etaf-text-grid (&key rows columns row-text row-ref label height ref on-scroll)

Display ROWS fixed text lines, each COLUMNS character columns wide.

**Arguments.** ROWS and COLUMNS are positive integers. ROW-TEXT is a required callback receiving the zero-based row; it returns a single-line string whose display width fits COLUMNS, and short rows are padded with spaces. ROW-REF optionally returns distinct Text Host references for retained content updates — those updates must also fit and pad to COLUMNS, with the callback's state kept in sync. LABEL names the read-only surface (default `"Text grid"`). HEIGHT, a positive integer or nil (the default), is the number of lines the surface shows in a scrolling viewport. REF names the surface Host for `etaf-scroll-to`, `etaf-scroll-by` and `etaf-scroll-offset`; without it the grid uses an instance-local reference. ON-SCROLL is nil or a function called with the first visible row after the viewport moves.

**Semantics.** Each row keeps a stable identity and its own retained boundary, so a change to one row's text repaints one line instead of the whole surface. The component has no focus targets, input handling, timers or terminal escape interpretation; it is a monospaced display, and wide characters occupy their Emacs display width. Individually retained rows are what a caller with a finer-grained identity uses instead of one big text host.

Without HEIGHT every row is built and shown. With HEIGHT the surface is a scroll Host of HEIGHT lines that builds only the rows near its viewport; two spacers stand for the rows above and below, so the content keeps its full height while the cost of mounting, scrolling and repainting does not depend on ROWS. ROW-TEXT runs only for built rows, and a ref it reads repaints only those rows. When the viewport leaves the built rows the grid rebuilds the rows around it, keeping the keyed rows that remain in range. The wheel, the scroll keys and `etaf-scroll-to`/`etaf-scroll-by` on REF move the viewport; `etaf-scroll-offset` and ON-SCROLL report the first visible row, and `etaf-scroll-to` past the end clamps to the last full viewport. Changing ROWS rebuilds the range: a viewport beyond the new end moves to the last rows. To scroll columns, keep the first column in a ref that ROW-TEXT reads; changing it repaints the visible rows.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ROWS or COLUMNS is not a positive integer, ROW-TEXT is not a function, ROW-REF is neither a function nor nil, LABEL is not a string, HEIGHT is neither nil nor a positive integer, or ON-SCROLL is neither nil nor a function. At render time a row content that is not a string, contains a newline, carriage return or tab, or is wider than COLUMNS signals the same condition naming ROW-TEXT.

**Example.**

```elisp
(etaf-text-grid :rows 24 :columns 80 :row-text (lambda (row) (buffer-line row)))
```

A long log that scrolls through a 30-line viewport and reports the first visible row:

```elisp
(etaf-text-grid :rows 1000000 :columns 80 :height 30 :ref 'log
                :row-text (lambda (row) (format "%7d  entry" row))
                :on-scroll (lambda (row) (message "Row %d" row)))
```

**See also.** `etaf-tile-grid`.

## The playing card

<!-- index: etaf-playing-card; card face; pile placeholder; intrinsic size -->

#### Component: etaf-playing-card (&key rank suit face-down empty selected disabled on-press label ref columns lines)

Present a controlled playing card or empty pile as one activation target.

**Arguments.** RANK is a one-line string up to three columns; SUIT is `spades`, `hearts`, `clubs`, `diamonds` or nil. FACE-DOWN conceals the rank and suit, including the generated accessible label. EMPTY presents a pile placeholder. SELECTED changes the paint without changing geometry. COLUMNS defaults to 9 with a minimum of 7, and LINES to 5 with a minimum of 1; one row exposes just a card's corner in a stack. These intrinsic dimensions never stretch to fill a viewport. ON-PRESS receives no arguments; omitted or disabled cards are noninteractive. LABEL overrides the accessible name and help, so callers must not put hidden information there.

**Semantics.** The card is one centered button sized in cells: a top corner with the rank and suit glyph, a centered suit mark (or a `◇` when face-down), and a bottom corner that appears when the card is more than three rows tall. Colors come from the playing-card tokens — a warm ivory face for the default bg, black or red ink depending on the suit, the blue back for face-down cards, a muted placeholder for an empty pile, the amber selected background and the hover tint — so a game can restyle the table through its Theme. Hover preserves every glyph and covers the complete painted card. Face-down cards and empty piles derive a subtle tint from their own surface instead of borrowing the face-up hover fill; selected cards suppress hover paint. The caller owns selection, stacks, moves and rules, and no game backend is required.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when RANK is neither nil nor a one-line string of at most three columns, SUIT is not one of the four suits or nil, COLUMNS is below 7, or LINES is below 1.

**Example.**

```elisp
(etaf-playing-card :rank "A" :suit 'hearts :on-press #'play-card)
```

## Playing-card tokens

<!-- index: ui-playing-card-bg; ui-playing-card-red; ui-playing-card-back-bg -->

#### Token: :ui-playing-card-bg

The face background of an ordinary card.

#### Token: :ui-playing-card-black

The ink of a spades or clubs card.

#### Token: :ui-playing-card-red

The ink of a hearts or diamonds card.

#### Token: :ui-playing-card-back-bg

The background of a face-down card.

#### Token: :ui-playing-card-back-fg

The front color of a face-down card.

**Semantics.** The face pair paints the concealed card; a face-down card never leaks its rank or suit through paint, text or the accessible label.

#### Token: :ui-playing-card-empty-bg

The background of an empty pile placeholder.

#### Token: :ui-playing-card-empty-fg

The glyph color of an empty pile placeholder.

#### Token: :ui-playing-card-selected-bg

The background of a selected card.

#### Token: :ui-playing-card-hover-bg

The hover tint of an interactive card.

**Semantics.** Selection and hover are paint only — the card's geometry and the pile's layout never move — and every token falls back to the catalog's built-in palette when no Theme is provided.

## The cell sheet

<!-- index: etaf-sheet; etaf-cell-line; spreadsheet; cell grid; column widths; row height; selection; cell editing -->

#### Function: etaf-cell-line (cells &key (stripe 'px) border-color rule rule-color leading-edge)

Return the styled text of one grid line holding CELLS.

**Arguments.** CELLS is a proper list of cell plists. `:width` is the content width in characters and is required; `:text` is the cell's single-line text; `:align` is `left` (the default), `right` or `center`; `:face` is a face or face plist merged over the text; `:edge` is the colour of the separator drawn after that cell. STRIPE is `px` (the default) or `glyph`: a one-pixel space with a background, or the box-rule character on a frame that cannot paint pixels. BORDER-COLOR is the separator colour a cell without `:edge` uses. With RULE the line carries a bottom rule in RULE-COLOR, and LEADING-EDGE adds one separator before the first cell in that colour.

**Semantics.** Each cell is padded by one space on both sides and aligned inside its width; text wider than its cell is truncated. Cells are separated by the stripe an Ebox box paints for a side border and closed by the underline it paints on its last line. A selected cell's fill therefore reaches the stroke, no half-cell gap can appear between two cells, and a row of cells costs one text Host instead of two Hosts per cell. The painter owns no state, no scrolling and no interaction: a surface decides which cells are visible and what each one says.

**Returns.** A propertized string. `etaf-cell-line-width` returns its character width.

**Errors.** A cell list that is not a proper list, a width that is not a non-negative integer, a text that is not a string or contains a newline, carriage return or tab, or an alignment other than `left`, `right` or `center` signals an error before anything is painted.

**Example.**

```elisp
(etaf-cell-line (list (list :width 8 :text "Item 1")
                      (list :width 5 :text "38" :align 'right))
                :border-color "#687386" :rule t :rule-color "#687386")
```

#### Function: etaf-cell-line-width (cells)

Return how many characters wide a line of CELLS is, separators included.

**Arguments.** CELLS is the same cell list `etaf-cell-line` paints.

**Semantics.** The count includes each cell's padding and one separator per cell, so a surface can size its Host before painting.

**Returns.** An integer.

**Errors.** The same cell validation as `etaf-cell-line`.

#### Component: etaf-sheet (&key rows columns widths heights version cell-text cell-face cell-align header row-head cursor region height editing cell-edit-text colors on-commit on-edit-cancel on-resize-column on-resize-row keys label ref)

Show a caller-owned grid of cells as a scrolling sheet.

**Arguments.** ROWS and COLUMNS are the sheet's size. WIDTHS is a vector of content widths in characters, or a reactive source holding one. CELL-TEXT is called with a row and a column and returns the cell's one-line text; CELL-FACE returns a face merged over the cell's text; CELL-ALIGN returns `left` (the default), `right` or `center`. HEIGHTS is an eql hash mapping rows to extra lines, for the few rows taller than one line, and VERSION is a writable ref the caller bumps after changing cell text. CURSOR is the writable ref of the active cell `(ROW . COL)`, REGION the writable ref of the selection's other corner, and HEIGHT the visible body in lines. HEADER and ROW-HEAD draw column letters and row numbers: `t` for the built-in naming, a function of the index, or nil to leave them out. EDITING is a writable ref naming the cell being edited; CELL-EDIT-TEXT supplies the text an edit starts from (default CELL-TEXT), ON-COMMIT receives `(ROW COL TEXT)` after a submit and ON-EDIT-CANCEL the abandoned text. ON-RESIZE-COLUMN receives `(COLUMN WIDTH)` from a dragged column heading and ON-RESIZE-ROW receives `(ROW LINES)` from a dragged row number. COLORS overrides the painted colour plist, KEYS adds `(KEY COMMAND LABEL)` entries before the sheet's own, LABEL names the grid and REF names the sheet Host.

**Semantics.** The sheet owns the viewport: which rows and columns are built, where the scroller sits and which cell a pointer landed on. It owns no cells, so formulas, formatting, undo and persistence stay in the caller's model; every cell it paints comes from CELL-TEXT and every change returns through a callback. One text Host per visible row is built with `etaf-cell-line`, so mounting, scrolling and repainting cost the viewport rather than the sheet; only the edited cell becomes a Host of its own, an `etaf-text-input` that the sheet focuses. Arrow keys move the cursor, Shift with an arrow extends the selection, F2 and RET begin an edit, and the horizontal wheel scrolls columns. Column headings resize their column and row numbers resize their row when the corresponding callbacks are supplied. Colours come from the catalog palette (`:ui-table-border`, `:ui-table-selected-bg`, `:ui-table-selected-fg`, `:ui-panel-bg`, `:ui-muted-fg`, `:ui-accent`), a dark frame gets the sheet's own dark colours, and COLORS overrides either. A text frame paints box-rule separators instead of one-pixel stripes.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ROWS, COLUMNS or HEIGHT is not a positive integer, WIDTHS is neither a vector nor a reactive source, CELL-TEXT is not a function, CELL-ALIGN, CELL-FACE, ON-EDIT-CANCEL, ON-RESIZE-COLUMN or ON-RESIZE-ROW is neither nil nor a function, HEIGHTS is neither nil nor a hash table, CURSOR is not a writable ref, REGION or EDITING is neither nil nor a writable ref, ON-COMMIT is not a function, HEADER or ROW-HEAD is neither nil, `t` nor a function, or KEYS and COLORS are not lists.

**Example.**

```elisp
(etaf-sheet :rows 1000 :columns 6 :widths widths :height 20
            :cursor cursor :region region :editing editing
            :cell-text read-cell :cell-align (lambda (row col) 'right)
            :header t :row-head t :ref 'orders
            :on-commit write-cell
            :on-resize-column (lambda (col width) (setf (aref widths col) width)))
```

#### Function: etaf-sheet-begin-edit (runtime ref editing cell)

Begin editing CELL in the sheet REF of mounted RUNTIME.

**Arguments.** EDITING is the writable ref the sheet took as `:editing`; REF is the sheet's stable `:ref`, because the editor Host is addressable as REF's `-editor` companion. CELL is the cell to edit.

**Semantics.** Sets EDITING and starts the field's native session. Call it from a command or a key handler, outside a reactive batch, so the editing row is published before the field takes focus. It is what Excel's type-to-edit needs, where the first typed character replaces the cell.

**Returns.** The field's reference, or nil when the sheet or its editor is not mounted.

**See also.** `etaf-sheet-reveal`, `etaf-sheet-scroll`.

#### Function: etaf-sheet-reveal (runtime &optional ref)

Scroll the sheet REF of mounted RUNTIME so its cursor cell is visible.

**Arguments.** REF defaults to `etaf-sheet`.

**Semantics.** The sheet's own keys and pointer drags reveal the cursor already; call this after moving `:cursor` from application code, such as a "go to cell" command or a restored session.

**Returns.** The dispatch result.

#### Function: etaf-sheet-cell-at (runtime ref x y)

Return the cell `(ROW . COL)` of the sheet REF in mounted RUNTIME at X and Y.

**Arguments.** X and Y are window pixels, the same values a pointer gesture reports. REF names the sheet.

**Semantics.** The result is nil when the position belongs to the sheet's chrome or lies outside it, so an application can tell a press on a cell from one beside it, for a context menu, a tooltip or a drop target. The sheet's own presses use the same mapping, which the GUI check `scripts/etaf-ui-sheet-gui.el` verifies against a mounted sheet.

**Returns.** A cons of the row and column, or nil.

#### Function: etaf-sheet-scroll (runtime &optional ref lines)

Scroll the sheet REF of mounted RUNTIME by LINES, negative upwards.

**Arguments.** REF defaults to `etaf-sheet`. LINES defaults to one page, the sheet's visible body height.

**Semantics.** Scrolling moves the viewport only, so an application that pages a sheet also moves the `:cursor` ref and reveals it. Use it for page keys or a scrollbar-free "jump to row"; the sheet's pointer wheel and arrow keys need no help.

**Returns.** The dispatch result.


## Errors and recovery

- `error→ etaf-component-call-error` reports every rejected input through `etaf-check-prop`: a non-positive dimension, a callback that is not a function, a row content that is not a single line fitting its column count, a card rank that is too wide, an unknown suit and a card narrower than seven columns.
- The grids own no state to roll back: a rejected callback result fails the render and the previously published cells or rows stay on screen.
- A tile image that cannot be decoded follows the image Host's placeholder path rather than failing the grid; a nil image simply falls back to the cell text.
- The playing card is pure presentation: a press reports to the caller, and an ignored press leaves the card exactly as it was.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Images](images.md).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-tile-grid :rows 2 :columns 4 :cell-width 3 :cell-height 1
                   :cell-text (lambda (row column) (format "%d%d" row column))
                   :on-cell-press #'ignore)
   (etaf-playing-card :rank "A" :suit 'hearts :on-press #'ignore)))
```
