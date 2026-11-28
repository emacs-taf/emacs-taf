# Grid Layout

A `grid` container places its children on a two-dimensional grid of tracks. It is the container for forms, dashboards, table-like layouts and any arrangement that needs aligned columns and rows rather than one axis. This chapter describes the model behind the grid properties of [Style Properties](style-properties.md): how tracks are defined and sized, how implicit tracks appear, how automatic and explicit placement work, how items align inside their areas, and how the layout proceeds. [Flex Layout](flex-layout.md) describes the one-dimensional sibling of this container.

## Tracks

<!-- index: grid track; fixed track; content track; fr; minmax; repeat; track gap -->

`:grid-template-columns` and `:grid-template-rows` define the explicit tracks as an ordered list. A track is a pixel or line length, the content keywords `min-content` and `max-content`, the automatic `auto`, a fractional `(fr N)` with a positive N, a `(minmax MIN MAX)` whose minimum cannot be fractional, or a `(repeat N TRACK)` where TRACK is one track or a list of tracks. A fractional track divides the space that remains after the fixed and content tracks are sized, in proportion to its factor, and a `minmax` raises its track to at least the minimum and caps it at the maximum; both ends of the range may themselves be content keywords or fractions.

A content track takes its size from its items. `min-content` is the widest thing that cannot be broken — the item's narrowest honest width — and `max-content` is the width the item would take on one line. The automatic `auto` size works differently: an item contributes a size to an `auto` track only when it can express one. A text item contributes its min-content width, an item with `:min-width` contributes that width, and an item whose `:overflow` is `visible` contributes its min-content width; any other box contributes only its margins and padding. A clipped or scrollable box therefore does not widen the track it sits in, and an `auto` track can resolve to zero pixels, leaving its content to overflow into the next track unless something else gives the track a size. `:justify-content stretch` is the usual way to give it one, because stretching distributes the leftover space into every track.

Tracks are separated by `:column-gap` between columns and `:row-gap` between rows, inserted between tracks only. The gaps are subtracted from the space available to track sizing, so an `fr` track divides what is left after them.

## Implicit tracks and automatic placement

<!-- index: implicit track; auto placement; auto flow; occupied cell -->

An item that lands outside the explicit tracks creates an implicit track, sized by `:grid-auto-columns` or `:grid-auto-rows`, both initially `auto`. Implicit tracks follow the same sizing rules as explicit ones — including the `auto` contribution rule above — and the grid grows to hold them, so placing a fourth item on a three-column grid gives the grid a fourth column rather than dropping or wrapping the item.

Automatic placement fills the grid in `:grid-auto-flow` order. With the initial `row`, the container scans row by row for a free area large enough for the item; with `column`, it scans column by column. An item that spans several cells needs a free area of that size, so the scan skips over occupied cells and over holes too small for it, and a spanning item can push later items to a new implicit track.

## Explicit placement and spans

<!-- index: grid placement; grid span; grid area -->

`:grid-row` and `:grid-column` place an item on a one-based line or area. An integer places the item at that line and spans one cell; `(:span N)` makes it span N cells from wherever automatic placement puts it; `(START :span N)` fixes the start line and the span; and `(START END)` spans from the start line to the end line. `:grid-row-span` and `:grid-column-span` set the span on their own, and a value that carries both a start and a span uses the larger of the two.

An explicit position wins over automatic placement for that axis. When only one axis is explicit, the other is filled by the automatic scan restricted to the explicit line or column, so an item with only `:grid-column 2` takes the first free cell in column two. A spanning item occupies every cell of its area for placement purposes, and the tracks it spans absorb its size contribution: a two-column span distributes its width over those columns, and a two-row span gives each row the full height it needs.

**Example.** In a grid with columns 4, 6 and 2 pixels and a one-pixel column gap, an item with `:grid-column (1 :span 2)` is 11 pixels wide — 4 plus the gap plus 6 — and the next automatic item starts at column three, at x 12.

```elisp :run
(etaf-define-component demo-grid-lab ()
  :bindings ((span (etaf-ref 2)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (etaf-segmented :value 2
                          :options '((1 . "跨 1") (2 . "跨 2") (3 . "跨 3"))
                          :on-change (lambda (key) (etaf-set-value span key)))
          (grid :width '(ch 44)
                :grid-template-columns '((fr 1) (fr 1) (fr 1))
                :gap '((lh 1) (ch 1))
                (box :padding '((lh 1) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "A"))
                (box :grid-column-span (etaf-value span) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
                     (text :color (etaf-theme-token :ui-accent "#0969da") "B"))
                (box :padding '((lh 1) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "C"))
                (box :padding '((lh 1) (ch 1)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "D")))))
(etaf-view (demo-grid-lab))
```

```elisp :figure A three-column grid with one two-column span
(etaf-view
 (grid :width '(ch 40)
       :grid-template-columns '((fr 1) (fr 1) (fr 1))
       :gap '((lh 1) (ch 1))
   (box :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text "A"))
   (box :grid-column-span 2
        :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text "B 跨两列"))
   (box :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text "C"))
   (box :padding '((lh 1) (ch 1))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
     (text "D"))))
```

## Alignment

<!-- index: justify items; justify self; align items; justify content; grid alignment -->

Items are aligned inside their areas by `:justify-items` horizontally and `:align-items` vertically, with `:justify-self` and `:align-self` overriding either for one item. The initial value of both is `stretch`, so an item whose cross size is automatic fills its area; a declared size keeps its size and the alignment keyword places it: `start`, `center` and `end` shift it inside the area. An item can be stretched in one axis and centered in the other.

The tracks themselves are placed by `:justify-content` for columns and `:align-content` for rows, using the same keywords as [Flex Layout](flex-layout.md). The initial `start` packs the tracks at the start of the content box; `stretch` distributes the leftover space into every track, which is what makes an otherwise zero-sized `auto` track usable; `center` centers the track set; and `space-between`, `space-around` and `space-evenly` distribute the leftover between or around the tracks. Only when the tracks together are smaller than the container is there leftover to distribute.

**Example.** A ten-pixel column holding a four-pixel item puts the item at x 3 with `:justify-items center` and at x 6 with `:justify-self end`. Two four-pixel columns in a twenty-pixel container sit at x 0 and x 16 with `:justify-content space-between`.

## How grid lays out

<!-- index: grid algorithm; column pass; row pass; relayout -->

Grid layout runs in two passes because a row's height depends on how tall its items are at their final widths. The column tracks are sized first from the items' width contributions; then every item is laid out inside its column area to learn its height, with its width coming from the columns it spans and its horizontal alignment; then the row tracks are sized from those heights; finally each item is placed vertically by its alignment, which can stretch an automatic-height item to its row area. Both passes resolve fractional tracks against the available space, freeze tracks that exceed their share, and quantize the result to whole pixels or lines.

A grid item's area is computed from the track offsets: an item spanning several tracks gets the sum of their sizes plus the gaps between them. The container's height is the total of its row tracks, so an implicit row added by placement makes the container taller. A change to any child relayouts the container's children completely, since one item's size can change its track and therefore every item after it; each child's own layout cache lets unchanged items return immediately.

## Errors and recovery

<!-- index: grid errors; zero track; place beyond template -->

A malformed track, a fraction with a non-positive factor, a minimum that is fractional, or a length with the wrong unit is rejected when the declaration is compiled, before any layout runs, with the conditions [Style Properties](style-properties.md) describes. Placing an item beyond the explicit tracks is not an error: the grid grows implicit tracks to hold it, sized by the grid's automatic track properties.

A zero-sized `auto` track is the one silent surprise of the model: the item overflows its area instead of widening it. The recovery is to give the track or the item the size the author had in mind — `min-content` or `max-content` on the track, a `:min-width` or `:overflow visible` on the item, an explicit length, or `:justify-content stretch` to share the container's leftover space. Clipping the overflow is then the ordinary `:overflow` behavior, which [Scrolling](scrolling.md) describes.
