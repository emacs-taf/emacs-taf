# Data Display

The catalog presents data in four shapes: a table for columns and rows, a data grid that wraps a table around a live Data Controller, an avatar for a person or entity, a timeline for a sequence of events, and a calendar for a month. The table family is presentational: it owns no loading, database, pagination or selection state, and the caller supplies rows plus optional controlled interaction. The avatar, timeline and calendar are ordinary display components. [UI Overview](ui-overview.md) defines the controlled contract, [Data Controllers](data-controllers.md) the controller the grid follows, [Component Styles and Themes](component-styles-and-themes.md) the tokens, and [Grid Layout](grid-layout.md) the tracks a table lays its cells in.

## Tables and rows

<!-- index: table columns; row shapes; cell function; fixed width; keyed identity -->

A table is defined by its columns and its rows. Each column carries a unique non-nil `:key`, an optional `:label` for the header, an optional `:width` — an integer character capacity, or `(fr N)` to share the remaining width by positive weight — and an optional `:cell` function that receives one row and returns ordinary View content. Without a `:cell`, the column's key reads a field from the row, and the row may be a plist with keyword keys, an alist, or a hash table.

Rows keep their application object identity: a stable `:row-key` function names each row for the reconciler, so cell state inside a returned Component survives inserts, reorders and replacements, and a replacement row still updates the callbacks it captures. Interaction is optional and controlled: with an `:on-row-press` callback the row becomes a button with a Tab index and a press callback, `:row-ref` supplies caller-owned addresses where the application needs them, and `:row-selected-p` paints a row with the selection foreground and background. The table itself never stores a selection or a page.

Columns with fixed positive character widths take a fast path: each header and row is one padded text Host, which keeps every row a single line and makes widths exact. Other columns share a grid layout, so a fractional column can reflow with the viewport while the fixed columns keep their capacity.

## The table component

<!-- index: etaf-table; presentational table -->

#### Component: etaf-table (&key columns rows row-key row-ref on-row-press row-selected-p)

Render ordinary ROWS as a presentational Table.

**Arguments.** COLUMNS is the column list described above. ROWS is a list of rows in any of the supported shapes; `:row-key` is a required function of one row returning its stable identity. `:row-ref` is an optional function returning a non-nil caller-owned reference per row, `:on-row-press` receives the row when it is activated, and `:row-selected-p` decides the selected paint per row. Interaction and selection are controlled inputs; the Table owns no application or Data Controller state.

**Semantics.** The header renders the column labels under a hairline in `:ui-table-border`; each body row draws the same hairline and the cells for its columns. Fixed character widths produce one padded text Host per row, other widths a grid; custom cell functions run at the consuming position and their Component output keeps its own Context, styles, state and lifecycle. The body is one vertical focus group, so the arrows move between interactive rows. A table without an `:on-row-press` callback is purely presentational and adds no focus targets.

**Returns.** A View.

**Errors.** An `error` naming the column, row or key: a duplicate column key, a `:cell` that is not a function, a row key that is not a function, or a `(fr N)` width with a non-positive weight. An invalid width also surfaces as Ebox's `error→ ebox-error` when the grid rejects it.

**Example.**

```elisp
(etaf-table :columns '((:key :name :label "Name" :width 10)
                       (:key :size :label "Size" :width 6))
            :rows '(((:name . "main.el") (:size . "12K")))
            :row-key (lambda (row) (cdr (assq :name row)))
            :on-row-press #'open-file)
```

**See also.** `etaf-data-grid`, `etaf-list`.

## The data grid

<!-- index: etaf-data-grid; controller states; status labels -->

#### Component: etaf-data-grid (&key controller columns row-key on-row-press row-ref row-selected-p loading-label error-label empty-label)

Render DATA CONTROLLER state through the public Component DSL.

**Arguments.** CONTROLLER is a [Data Controller](data-controllers.md). COLUMNS, ROW-KEY, ROW-REF, ON-ROW-PRESS and ROW-SELECTED-P follow `etaf-table`, with ROW-SELECTED-P optionally combined with the controller's own selection. LOADING-LABEL, ERROR-LABEL and EMPTY-LABEL override the status texts.

**Semantics.** The grid shows the controller's idle, loading, refreshing, cancelled, error and empty states. A status label appears above the rows: refreshing uses LOADING-LABEL (`"Refreshing..."`), cancellation uses ERROR-LABEL (`"Loading cancelled."`), and a bare loading uses the same LOADING-LABEL. The body shows the rows once items exist, or a state label — `"Not loaded."` for idle, `"No data."` or EMPTY-LABEL for an empty success, and the error text for a failure. Error and cancelled text paints with `:ui-data-grid-error-fg`. Accepted rows stay interactive during pending or failed operations; the grid keeps each row's keyed identity and custom cell state, and the footer slot composes below the body.

**Returns.** A View.

**Errors.** The column, row-key and selection contracts of `etaf-table`; the controller's own errors propagate from its load path.

**Example.**

```elisp
(etaf-data-grid :controller controller
                :columns '((:key :name :label "Name"))
                :row-key (lambda (row) (plist-get row :id))
                :empty-label "No records")
```

**See also.** `etaf-table`, `:ui-data-grid-error-fg`.

## The avatar component

<!-- index: etaf-avatar; initials; round photo; background color -->

#### Component: etaf-avatar (&key name initials src size variant lines background shape)

Render a compact avatar with semantic color and accessible name.

**Arguments.** NAME is the accessible name and the default source of initials. INITIALS overrides the derived initials. SRC is an optional photo: a local image file or an Emacs image descriptor. SIZE is the width, default `(ch 5)`; round avatars also accept an integer column count. LINES is the positive integer height in text rows, default 3. VARIANT selects the semantic color pair. BACKGROUND replaces the variant with white initials on that color, for per-person colors. SHAPE is `circle` (default) or `square`.

**Semantics.** Without INITIALS, the first two characters of NAME are used uppercased; without NAME and INITIALS the avatar shows `?`. On graphical frames with SVG, a circular avatar draws the photo clipped to a disc, or the initials on a colored disc when there is no readable photo; `square` and text frames use an initials box whose text sits on the upper middle line of its height. Round images are cached by source and cell size, so callers should pass `equal`-stable sources. The whole box carries the `img` role and NAME as its accessible label.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when SHAPE is neither `circle` nor `square`; a non-positive LINES signals the native `wrong-type-argument (natnump)`.

**Example.**

```elisp
(etaf-avatar :name "Ada Lovelace" :size '(ch 3) :lines 2 :variant 'success)
```

## The timeline component

<!-- index: etaf-timeline; event stream; status badge -->

#### Component: etaf-timeline (&key items)

Render chronological item plists containing `:title`, `:content` and `:status`.

**Arguments.** ITEMS is a nonempty list of item plists. `:status` is an optional string shown as a badge and defaults to `"Update"`; `:title` and `:content` are the two text lines.

**Semantics.** Each entry is a row with an info badge carrying the status next to a column holding the strong title above the muted content, so a release, commit or comment reads as one event in a vertical sequence. The list is presentational and owns no chronology, filtering or pagination.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when ITEMS is not a nonempty list of item plists.

**Example.**

```elisp
(etaf-timeline :items '((:status "v1.2" :title "Release" :content "Shipped")
                        (:title "Commit" :content "Fixed the parser")))
```

## The calendar component

<!-- index: etaf-calendar; month grid; selected day -->

#### Component: etaf-calendar (&key month value on-change label)

Render a controlled month grid; MONTH is `(YEAR MONTH)` and ON-CHANGE gets `(YEAR MONTH DAY)`.

**Arguments.** MONTH is a `(YEAR MONTH)` list with a month from 1 to 12 and defaults to `(2026 1)`, not the current month; pass the intended month explicitly. VALUE is the selected integer day-of-month or nil (default), not a full date or a ref. ON-CHANGE is optional, defaults to nil and receives one `(YEAR MONTH DAY)` list; the caller extracts its day to update VALUE and may separately update MONTH. LABEL defaults to `"Calendar"` and precedes the month name in the header.

**Semantics.** The grid shows Monday through Sunday as muted labels and every day of the month as a button formatted to two columns; the selected day uses the ghost Button's selected tint and carries `:aria-selected`. Weekday headings, date buttons and blank leading cells each occupy four character widths, so every date remains under its weekday and selection changes neither column positions nor typeface. The calendar is one focus group with the `grid` role, so the arrows move across days and the buttons keep their accessible date labels. The component owns no month navigation: the caller changes MONTH and VALUE.

**Returns.** A View.

**Errors.** `error→ etaf-component-call-error` when MONTH is not a `(YEAR MONTH)` list with a valid month, VALUE is neither an integer nor nil, or ON-CHANGE is neither a function nor nil.

**Example.**

```elisp
(etaf-calendar :month '(2026 1) :value 15
               :on-change (lambda (date) (setq selected date)))
```

## Data display tokens

<!-- index: ui-table-border; ui-table-selected-fg; ui-data-grid-error-fg -->

#### Token: :ui-table-border

The hairline under a table header and every table row.

**Semantics.** Shared by the table, the data grid's header and rows, and any other row-based surface, so a table reads as one grid regardless of which component produced it.

#### Token: :ui-table-selected-fg

The foreground of a selected table row.

#### Token: :ui-table-selected-bg

The background of a selected table row.

**Semantics.** With `:ui-table-selected-fg` it forms the selection pair a row uses when its `:row-selected-p` or the data grid's selection says so.

#### Token: :ui-data-grid-error-fg

The text color of a data grid failure or cancellation.

**Semantics.** The status label above the rows and the error body label paint with it, while informational statuses stay muted; a component that reads it supplies a built-in fallback.

#### Component: etaf-braille-chart (&key values width height min max label ref)

Render VALUES as a braille chart WIDTH cells by HEIGHT cells.

**Parameters.** VALUES is a numeric series; WIDTH defaults to 40 and HEIGHT to 6; MIN and MAX fix the scale, and without them the series' own range is used; LABEL names the chart above it; REF lets a caller address it by name.

**Returns.** An ETAF Component.

**Semantics.** Each cell carries a two by four dot grid, so the chart resolves four times as many vertical steps as it has rows. Dots the series does not pass through stay empty, which is what makes the line thin. It draws no axes; MIN and MAX define the scale, so a reading shows shape rather than exact values.

**See also.** `etaf-table`, `etaf-timeline`.

## Errors and recovery

- The table family reports contract errors as plain `error` conditions naming the column, row or key — a duplicate column key, a non-function cell or row key, a bad fraction weight — because they are authoring mistakes in the caller's data, not reactive input; the data grid additionally surfaces Ebox's own `ebox-error` when Ebox rejects a layout value.
- Selection and interaction are controlled: a rejected or ignored press changes nothing in the table, and the caller's row objects are never mutated.
- A data grid keeps its accepted rows on screen while a refresh fails or is cancelled, so a transient backend error does not blank the view; only the status text changes.
- The calendar and avatar components own no state: an invalid input fails the call and leaves the mounted instance as it was.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery), [Data Controllers](data-controllers.md).

```elisp :run
(etaf-view
 (column :item-gap '(lh 1)
   (etaf-table :columns '((:key :name :label "Name" :width 10)
                          (:key :size :label "Size" :width 6))
               :rows '(((:name . "main.el") (:size . "12K"))
                       ((:name . "util.el") (:size . "4K")))
               :row-key (lambda (row) (cdr (assq :name row)))
               :on-row-press #'ignore)
   (etaf-avatar :name "Ada Lovelace" :size '(ch 3) :lines 2)))
```
