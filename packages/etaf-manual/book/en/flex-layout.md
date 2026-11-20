# Flex Layout

A `flex` container distributes its children along one axis, growing and shrinking them from their base sizes. It is the container for toolbars, button rows, headers and any group whose items must share the available space rather than each take a line. This chapter describes the model behind the flex properties of [Style Properties](style-properties.md): the main and cross axes, how base sizes are resolved and grown or shrunk with min/max freezing, how wrapping forms lines, how alignment and gaps place the items, and how the algorithm proceeds. The properties themselves, including their grammars and initial values, are defined in [Style Properties](style-properties.md); [Boxes and Normal Flow](boxes-and-normal-flow.md) defines the flow this container replaces.

## The main and cross axes

<!-- index: main axis; cross axis; flex direction; order -->

`:flex-direction` chooses the main axis. The initial `row` and `row-reverse` lay the children out horizontally, so the main size is a pixel width; `column` and `column-reverse` stack them vertically, so the main size is a line count. The other axis is the cross axis, and every placement in a flex container is described against those two axes.

Children are placed in `:order` order, ascending, with equal values keeping document order; an absolutely positioned child is out of flow and does not take an item slot. A reversed direction reflects the placement after the line has been resolved, so it changes which end the items start from rather than only their visual order, and `:justify-content` follows the reversed main start. The two axes are also why a length is accepted in every unit on the properties that describe them: `:flex-basis` is resolved against the axis the container actually uses, so a row resolves pixels and a column resolves lines.

## Basis, growth, shrink and freezing

<!-- index: flex basis; flex grow; flex shrink; hypothetical size; freezing -->

Each item starts from a *base size*. `:flex-basis` gives it directly; `auto`, the initial value, uses the item's main size property — `:width` in a row, `:height` in a column — and `content` uses the item's intrinsic content size. Text items take their content size and never grow or shrink, which is what keeps a label from being squeezed when the items around it share out space. The base size is clamped by the item's minimum and maximum main sizes to form its *hypothetical size*, the size it would take if no space were distributed.

The container then compares the sum of the hypothetical sizes and gaps with the available main space. When there is free space, growth is distributed in proportion to `:flex-grow`; when the items overflow, shrink is distributed in proportion to `:flex-shrink` multiplied by the base size, so a wider item gives up more room than a narrow one at the same factor. An item whose factor is zero, or whose base already lies in the direction opposite to the distribution, stays frozen at its hypothetical size.

Growth and shrink may push an item past its own minimum or maximum. When that happens the item is clamped to the boundary and frozen there, and the free space is distributed again among the items still unfrozen; the loop repeats until every item is frozen, so a minimum or maximum always wins over the distribution while the remaining items absorb the difference. When the factors still in play sum to less than 1, only that fraction of the free space is distributed, so a lone item with `:flex-grow 0.5` takes half the free space and leaves the rest. The final sizes are quantized to whole pixels or lines on cumulative boundaries, so adjacent items never leave a fractional gap and an overflowing row sheds from its start rather than opening a gap in the middle.

**Example.** Two items of base 4 pixels, the first growing at 1 and the second at 3, fill a 20-pixel row as 7 and 13 pixels. The same two items at base 10 and shrink 1 in a 12-pixel row resolve to 6 and 6; with shrink 3 and 1 at base 8 they resolve to 5 and 7; and when the first item of a growing pair has `:min-width (px 15)`, it freezes at 15 and the other takes the remaining 9.

```elisp :run
(etaf-define-component demo-flex-lab ()
  :bindings ((a (etaf-ref 1))
             (b (etaf-ref 2))
             (c (etaf-ref 1)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 2)
               (etaf-number-input :label "A" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value a v)))
               (etaf-number-input :label "B" :value 2 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value b v)))
               (etaf-number-input :label "C" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value c v))))
          (flex :flex-direction 'row :width '(ch 44) :column-gap '(ch 1)
                (box :flex-grow (etaf-value a) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
                     (text :color (etaf-theme-token :ui-accent "#0969da") "A"))
                (box :flex-grow (etaf-value b) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                     (text "B"))
                (box :flex-grow (etaf-value c) :padding '((lh 1) (ch 1))
                     :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
                     (text :color (etaf-theme-token :ui-accent "#0969da") "C")))))
(etaf-view (demo-flex-lab))
```

```elisp :figure Three boxes growing 1 : 2 : 3 in one flex row
(etaf-view
 (flex :flex-direction 'row :width '(ch 40) :column-gap '(ch 1)
   (box :flex-grow 1
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        :padding '((lh 1) (ch 1))
     (text "grow 1"))
   (box :flex-grow 2
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        :padding '((lh 1) (ch 1))
     (text "grow 2"))
   (box :flex-grow 3
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        :padding '((lh 1) (ch 1))
     (text "grow 3"))))
```

## Wrapping

<!-- index: flex wrap; flex lines; wrap reverse -->

The initial `:flex-wrap nowrap` keeps every item on one line, so items that do not fit overflow the container. `wrap` breaks the items into *flex lines*: an item starts a new line when adding it, its hypothetical size and the gap would exceed the available main space. Wrapping is decided from hypothetical sizes, before growth or shrink, so a line that will grow to fill its space still breaks at the same place. `wrap-reverse` forms the same lines but reflects them along the cross axis, so the first line ends up at the far side.

The height of a wrapping row container is the sum of its lines' cross sizes plus the gaps between them; a column container measures the same way along the other axis. Inside a line, the items grow and shrink against that line's share of the main space, not against the whole container. Alignment of the lines themselves is `:align-content`, described below.

**Example.** Three items of base 4 in a 10-pixel row with `:flex-wrap wrap` form a first line of two items and a second line of one; the container is two lines tall and the third item sits at x 0 on the second line.

## Alignment and gaps

<!-- index: justify content; align items; align self; align content; flex gap -->

`:justify-content` places the items along the main axis after free space is distributed: the initial `start` packs them at the main start, `end` packs them at the main end, `center` centers the group, and `space-between`, `space-around` and `space-evenly` distribute the free space between the items, around them and evenly including the ends. The keyword is applied per line in a wrapping container.

`:align-items` places each item on the cross axis and `:align-self` overrides it for one item; `auto` follows the container. `start`, `center` and `end` place the item at its natural cross size, and the initial `stretch` fills the line's cross size for items whose cross size is automatic; an item with a declared cross size keeps it. `:align-content` distributes the lines of a wrapping container when the lines together do not fill the container's cross size: `stretch`, the initial value, expands the lines to take the leftover, and the other keywords place or distribute the lines as `:justify-content` does for items. A single line in a container with a definite cross size is stretched to that size.

Gaps are part of the main and cross layout: `:column-gap` separates items along the main axis of a row and `:row-gap` separates the lines of a wrapping row, with the axes swapped for a column container. `:gap` sets both in one declaration. Gaps are inserted between items and lines only, never outside them, so the free space available to alignment is computed after the gaps are subtracted.

**Example.** Two 4-pixel items in a 20-pixel row sit at x 6 and 10 with `:justify-content center`, at 0 and 16 with `space-between`, at 3 and 13 with `space-around`, and at 4 and 12 with `space-evenly`. With `:align-items center` in a three-line-tall row, an item one line tall sits on the middle line; with `:align-self end` it sits on the last line.

## How flex lays out

<!-- index: flex algorithm; relayout; item cache -->

The layout is a resolution loop, not a formula. First the container computes every item's hypothetical size; then it breaks the items into lines; then, line by line, it distributes the free space and freezes the items that violate a minimum or maximum, repeating until the distribution is stable. Only after the main sizes are final does each item's cross size get measured — a row measures the natural height of each item at its final width, a column measures widths at its final height — and only then are the lines placed by `:align-content` and the items by `:align-items`.

Because a flex container's item placements depend on every item's final size, a change to any child relayouts the container's children; the children's own layout caches make unchanged items return immediately, so the cost is proportional to what actually changed. The distribution is also deliberately integer: pixels for a row, whole lines for a column, with earlier items taking the remainder of an uneven split. A row therefore never shows a half-pixel seam between two items, and its right edge lands on a pixel boundary.

## Errors and recovery

<!-- index: flex errors; overflow -->

Flex layout has no runtime error of its own: malformed values, a unit that does not fit the axis, or a property the container does not accept are rejected when the declaration is compiled, before any layout runs, with the conditions [Style Properties](style-properties.md) describes. Conflicting requests are resolved by the algorithm instead of reported: an item whose growth would exceed its maximum freezes at the maximum and the remaining space goes to the other items, and an item that cannot shrink enough overflows.

Overflow is not corrected by the container. A `nowrap` row whose items do not fit overflows it, and the box's `:overflow` decides whether the excess is clipped or scrollable, which [Scrolling](scrolling.md) defines; a wrapping row avoids the situation by starting a new line instead. Items that cannot be shrunk below their own content — text items and boxes with a visible overflow and a fixed size — keep their size and can push the row past its container in the same way.
