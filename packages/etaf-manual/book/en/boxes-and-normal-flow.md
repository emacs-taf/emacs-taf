# Boxes and Normal Flow

A `box` is the general layout container: it stacks block children and lays inline content out as paragraphs. This chapter describes normal flow — how a box tells blocks and inline pieces apart, how the three width constraints stretch, shrink and exact drive its children, how minimum and maximum sizes and `box-sizing` interact with those constraints, how a border becomes characters in a line, and how the `row` and `column` containers place their children along one axis. [Hosts](hosts.md) defines which box kinds exist and [Style Properties](style-properties.md) defines the properties named here; [The Rendering Model](rendering-model.md) defines the line and pixel coordinates this chapter's geometry uses.

## Block, inline and anonymous paragraphs

<!-- index: normal flow; inline; block; anonymous paragraph; outer -->

A node participates in inline formatting when it is a text node, or a `box` whose `:outer` is `inline` and whose children are all inline or absolutely positioned. Everything else is a block. The distinction is what `:outer` states, and it can be observed: an inline box sits beside its neighbours in the same paragraph, while a block box takes a full row of the container's content width and pushes the following content down.

A `box` arranges its in-flow children in document order and groups them. Consecutive inline children form one run, and the run is laid out as an *anonymous paragraph* at the box's content width: the inline pieces share the paragraph's lines, wrap together, and are positioned as one block of lines. Every block child is its own group. The groups are then stacked by line, each block child laid out stretched to the content width, each paragraph's height added in lines. A box whose children are a single inline run lays that run out as one paragraph directly; that is the common case of a box that only holds text.

Abspos children do not take part: an absolutely positioned child is out of flow and is placed from its containing host instead, which [Positioning, Layers and Overlays](positioning-layers-and-overlays.md) describes. A paragraph is a layout construct, not a public node — it exists while the box is laid out to hold the wrapped lines of its inline run — so the public way to observe it is the box's geometry and the rendered lines.

## The three width constraints

<!-- index: width constraint; stretch; shrink; exact; intrinsic width -->

Before a box resolves a width it is given an available width in pixels and one of three constraints. *Stretch* means the box may fill the available width. *Shrink* means the box should follow its content, bounded by the available width: its intrinsic minimum (the narrowest it can be without breaking something that must stay whole) and its intrinsic maximum (the width it would take on one line), clamped to the available width. *Exact* means the box takes a width another algorithm has already decided for it, ignoring its own declaration.

The constraint is chosen by the parent. A block child of a `box` is stretched to the content width, and so is a `column` child when its cross-axis alignment is `stretch`; the root of a non-text tree is stretched to the viewport width. A `row` child and a non-stretched `column` child shrink to their content. Exact is how the flex and grid algorithms hand a target width to an item, so it appears only inside those containers, which [Flex Layout](flex-layout.md) and [Grid Layout](grid-layout.md) describe.

A width declaration takes precedence over the mode: a fixed `:width` resolves to that value under stretch and shrink alike, and `min-content`, `max-content` and `fit-content` choose an intrinsic width explicitly, where `fit-content` is the minimum and maximum intrinsic widths clamped to the available width. The initial `auto` behaves like the mode — fill under stretch, fit-content under shrink — and the `stretch` keyword fills explicitly when there is a containing block to fill. Heights work the same way with lines: a fixed `:height` wins, a `stretch` height fills the containing height when one is known, and otherwise the height is the content's height. A `visible`-overflow box whose content needs more lines than its own height takes the content height instead of clipping, so a growing row of text pushes its container taller.

## Minimum, maximum and box sizing

<!-- index: box sizing; minimum size; maximum size -->

`:box-sizing` decides what a declared size measures. With the initial `border-box`, `:width` and `:height` describe the border box, so padding and borders shrink the content area; with `content-box`, they describe the content box and padding plus borders are added outside, so a 20-pixel width with 2-pixel padding and a 1-pixel border occupies 25 pixels. The resolved size is then clamped by `:min-width`, `:max-width`, `:min-height` and `:max-height`; a minimum larger than the declared size wins, and a maximum smaller shrinks the box, wrapping text when the smaller content width cannot hold a line. Minimum and maximum sizes follow the same `box-sizing` as the declared size.

The recovery rule for opposing constraints is that the clamp is applied last and silently: geometry never rejects a combination of declared and minimum or maximum sizes, it resolves to the clamped value. `:overflow visible` is the one case where content can override a declared height, as the previous section describes; `hidden` and `scroll` keep the declared height and let the overflow interfaces deal with the excess.

## Borders as characters

<!-- index: border painting; pixel space border; overline; underline -->

A border is painted with the tools a text buffer has. The left and right borders are pixel spaces painted with the border color as their background: a three-pixel left border is one display space three pixels wide whose face has that background. Their widths are geometry — they reduce the content area of a `border-box` and add to the outer size of a `content-box` — and because they are display spaces they stay exact at any pixel width.

The top and bottom borders are not characters. They decorate every character of the border-box's first or last line with an overline or underline in the border color, so a top border draws its line above the line's characters and a bottom border draws its line below them, spanning exactly the box's pixel width. A face has one such stroke, so a top or bottom border wider than one pixel has no honest rendering; Ebox signals `ebox-error` instead of drawing an approximation. A border exists only when its style is `solid` and its width is greater than zero: the initial style `none` resolves the border to zero width, so it neither reserves geometry nor paints.

```elisp :run
(etaf-define-component demo-box-lab ()
  :bindings ((pad (etaf-ref 2))
             (edge (etaf-ref 1))
             (gap (etaf-ref 1)))
  :view
  (column :width '(ch 44) :item-gap '(lh 1)
          (row :item-gap '(ch 2)
               (etaf-number-input :label "内边距" :value 2 :min 0 :max 6
                                  :on-change (lambda (v) (etaf-set-value pad v)))
               (etaf-number-input :label "边框" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value edge v)))
               (etaf-number-input :label "外边距" :value 1 :min 0 :max 4
                                  :on-change (lambda (v) (etaf-set-value gap v))))
          (box :width '(ch 44)
               :padding (list (list 'lh (etaf-value gap)) (list 'ch (etaf-value gap)))
               :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
            (box :padding (list (list 'lh (etaf-value pad)) (list 'ch (etaf-value pad)))
                 :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
                 :border-width (list 'px (etaf-value edge))
                 :border-style 'solid
                 :border-color (etaf-theme-token :ui-accent "#0969da")
              (text "内容")))))
(etaf-view (demo-box-lab))
```

```elisp :figure Content, padding, border and margin around one box
(etaf-view
 (box :width '(ch 40) :padding '((lh 1) (ch 2))
      :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
   (box :padding '((lh 1) (ch 2))
        :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        :border-width '(px 1)
        :border-style 'solid
        :border-color (etaf-theme-token :ui-panel-border "#687386")
     (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "内容")
     (text :color (etaf-theme-token :ui-muted-fg "#526174")
           " 两边是内边距，细线是边框，灰底是外边距"))))
```

## Rows and columns

<!-- index: row; column; item gap; cross alignment; single axis -->

A `row` places its direct children along the horizontal axis and a `column` along the vertical axis, in both cases at pixel or line positions within the container's content box. `:item-gap` separates adjacent children on that main axis — inline-axis units for a row, block-axis units for a column — and is inserted only between children, never before the first or after the last. `:cross-align` places each child on the cross axis: `start`, `center` and `end` position the child, and the initial `stretch` lets a child fill the container's cross size.

The two containers differ in how a child takes its main size and in what happens when the children do not fit. A `column` gives a child the full content width unless the cross alignment stops it; a `row` lets a child shrink to its content, which is what makes icon-and-label groups size themselves naturally. A `row` never wraps: children that do not fit overflow the container, and `:overflow` decides whether that excess is clipped or scrollable, which [Scrolling](scrolling.md) defines. A container that must wrap or distribute extra space is a `flex` container, which [Flex Layout](flex-layout.md) defines.

## Errors and recovery

<!-- index: border width error; size rejection; clamp -->

A top or bottom border wider than one pixel signals `ebox-error` with the side and the offending width as its data; the check runs while the node's computed style is built during a layout pass, so it is reported when the update runs — setting the property on its own does not signal. Lengths whose unit does not fit the axis, such as a pixel padding on the block axis, are rejected earlier, when the declaration is compiled, with `ebox-size-error` naming the allowed units; [Style Properties](style-properties.md) describes the unit domains.

Opposing sizes are not errors: declared sizes, minimums and maximums resolve to a clamped value, and a `visible`-overflow box grows to its content rather than reporting that the content does not fit. The remaining recovery paths — scrolling a clipped box and rewriting only the damaged lines after a size change — belong to [Scrolling](scrolling.md) and [Incremental Updates and Publication](incremental-updates-and-publication.md).
