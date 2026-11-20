# Positioning, Layers and Overlays

Absolute positioning takes a box out of flow and lets it paint over its siblings: dropdowns, tooltips, menus and modal scrims are all overlays of a host box. This chapter describes the model behind the `:position`, `:layer`, `:anchor`, `:placement`, `:left`, `:top` and `:z-index` properties of [Style Properties](style-properties.md): how the positioning host is chosen, where an overlay lands, how anchors resolve, how overlapping boxes paint, and how an overlay is spliced into the host's lines. The flow containers themselves are described in [Boxes and Normal Flow](boxes-and-normal-flow.md), [Flex Layout](flex-layout.md) and [Grid Layout](grid-layout.md), and the coordinate system in [Rendering Model](rendering-model.md).

## Positioning and the positioning host

<!-- index: absolute positioning; positioning host; overlay; offset; clipping -->

A box with `:position absolute` leaves its parent's flow. It contributes nothing to the parent's content size, takes no line of its own and does not move its siblings, so the parent's height stays what its flow content and any explicit height say it is. An absolute box is called an **overlay**, and the box that places it is its **positioning host**.

The host is the nearest ancestor that is not an inline box — the nearest ancestor whose `:outer` is not `inline`, which is normally the nearest box — or the root itself when the box has `:layer root`. An inline parent therefore defers its absolute children to the nearest enclosing block box. A box whose `:outer` is `inline` never hosts overlays itself, and neither does a text node.

Without an anchor, the placement origin is the host's content origin: the host's left border and left padding plus `:left` horizontally, and the host's top padding plus `:top` vertically. Percentages in `:left` measure the host's padding-box width — the border box minus its side borders — and percentages in `:top` measure the host's border-box height; a root-layer box without an anchor measures both against the root's border box, because the root is its host.

An overlay is laid out against the host's border box: its available width is the host's border-box width and it shrinks to its content, so a declared `:width (% 50)` resolves to half the host's width. Because the host reserves no space, an overlay that should occupy a slot needs the host to have an explicit height. Painting is clipped to the host: only the host's border-box lines exist, so an overlay extending past the host's bottom edge is cut there, and the part of a negative offset that falls outside the host is not painted — the offset itself is kept, so geometry still reports the requested position. Overlays belong to the host's canvas rather than to its content: when the host scrolls, an overlay does not move with the flow, it stays at its host-relative position.

**Example.** A host with one line of horizontal padding places an overlay with `:left (px 3)` and `:top (lh 1)` at x 4 and y 1 above the host content origin; the same host's height stays one line when the overlay is five lines tall. A host three lines tall with an overlay at `:top (lh 2)` and five lines of height shows only the overlay's first line.

## The root layer and page-level scrims

<!-- index: root layer; page layer; scrim; logical parentage -->

With `:layer root` the positioning host is the root, so the overlay paints in the root's top layer rather than inside its logical parent. Its logical position does not change: it keeps its original parent for selectors, inheritance and tree queries, and only placement and paint move to the page.

Without an anchor, a root-layer box measures its offsets and percentages from the root's border box — no padding or border is subtracted — so `:left (px 0)` and `:top (lh 0)` mean the page origin, and a `:width (% 100)` with `:height (% 100)` covers the whole page. That is the usual page-level scrim, and because the box still has its logical parent, the scrim can be styled by the rules, classes and inheritance that apply where it stands in the tree.

Root-layer boxes and the root's own overlays share one paint list ordered by `:z-index`, and because the root composes its lines after every subtree, a root-layer box paints over the local overlays of all nested hosts. Which subtree a root-layer box was written in makes no difference to its paint position.

**Example.** A scrim declared inside a small nested box, with `(% 100)` width and height, measures 12 by 4 on a 12 by 4 root and covers an `o` in a sibling subtree; a `:z-index 1` root-layer box sits under a `:z-index 5` overlay of the root, and above a `:z-index 9` overlay of a nested host.

## Anchors and placement

<!-- index: anchor; placement; flip; clamping; anchor target -->

`:anchor` makes an overlay follow a node instead of the host origin. The value names a target by its `:id`: the anchor value and the id are normalized to names, and the target is the first node with that name in document order under the overlay's root tree — the whole tree, not only the host's subtree. While the target is missing, hidden, or inside the overlay itself, the box is not placed at all: it paints nothing, owns no buffer cells and cannot take focus, even though a layout box still exists for it.

Placement positions the overlay relative to the target's border box. The default `bottom-start` puts the overlay's top edge at the target's bottom edge, left edges aligned; `top-start` puts its bottom edge at the target's top edge; the `-end` variants align right edges instead. `:left` and `:top` are added as further offsets on top of that placement. When the preferred vertical side would leave the host, placement flips to the other side if it fits there, and in every case the final position is clamped inside the host, so an anchored overlay never paints outside its host's canvas and stays visible as the host narrows.

Placement repeats until it settles, so a target that lives inside another overlay still gets a final position after that overlay has moved. The pass runs after every layout and flush, so an overlay follows a target that has shifted, even though the target's move does not relayout the overlay by itself. Resolution is cached per overlay and renewed when the cached target no longer matches or no longer belongs to the same tree, so repeated placement does not re-walk the tree for an unchanged target.

**Example.** A target at y 6 in an eight-line host with a two-line `bottom-start` tip flips above the target and lands at y 4, because the preferred side would end at y 8. A target at y 5 with a six-line tip and a `:left (px 20)` offset has no side that fits, so both coordinates are clamped and the tip lands at x 16, y 2. A tip anchored to a node inside another tip settles one line below that node.

## z-index and occlusion

<!-- index: z-index; paint order; occlusion; hit testing; stacking -->

Overlays of one host paint in ascending `:z-index`; equal values keep document order, so the later overlay paints on top of the earlier one. The initial value is 0, and negative values are allowed, so an overlay can be pushed behind its siblings.

A relatively positioned flow child joins that order without leaving the flow. It keeps its slot and layout geometry, but when its `:z-index` is higher than the lowest overlay's, it paints after the overlays below it and before the overlays above it, showing their background through the cells it does not fill itself. The comparison is against the lowest overlay's value, so the same z value means the same stack position for flow children and overlays, and a relatively positioned child with the initial 0 stays under every overlay whose value is 0 or higher.

z-index is local to one host's list. Overlays of different hosts are ordered by composition and nesting, not by z: a nested host's overlay, whatever its value, paints before an overlay of an ancestor host, because the ancestor splices its own overlays into lines that already contain the subtree's. Comparing z values across hosts is therefore meaningless, and raising a nested overlay's value cannot lift it above an outer host's overlay.

Hit testing reverses paint order: the highest z wins, and among equal values the later overlay wins. A cell covered by an overlay belongs to the overlay's content, so a click or a hit test at that cell resolves through the overlay and never reaches the covered flow node. A node whose whole first line is covered owns no buffer cells — `ebox-node-position` returns nil, `ebox-node-at` returns something else — and it cannot take focus either; a node that is only partly covered keeps the uncovered cells.

**Example.** Two overlapping four-pixel overlays with z 0 and 1 resolve to `BBBB`, and with the values swapped to `AAAA`; with both at 0 the later one still wins. A flow child of z 5 against an overlay of z 0 paints `RRRR` on top, but a relative z 5 child under a z 10 overlay does not.

```elisp :figure An overlay joins the host's lines without changing the layout
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
        (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "宿主行"))
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        (text :color (etaf-theme-token :ui-accent "#0969da") "浮层拼进这一行，布局不动"))
   (box :padding '((lh 1) (ch 2)) :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
        (text :color (etaf-theme-token :ui-disabled-fg "#687386") "宿主的其余行不受影响"))))
```

## How overlays compose into the lines below

<!-- index: overlay composition; line splicing; border decoration; root coordinates -->

Composition splices each overlay into the host's lines. The overlay's margin box starts at its placed position; for every border-box line of the host, the overlay line at the corresponding offset replaces the pixels under it, and the result becomes a flat part list that is concatenated once when the line is written to the buffer. Only the lines the overlay covers are affected — every other host line keeps its flow content.

Before splicing, flow content is clipped to its containing content box even when a stacked child's intrinsic or minimum width is larger. This preserves the child's geometry while keeping the painted row within the parent's width; hidden overflow cannot widen the canvas or shift another overlay. Text, complete native image glyphs and existing image slices follow the same boundary when windows move or resize. Cutting an image keeps the exposed slice and its baseline modifiers instead of replacing the whole glyph with empty space; successive cuts continue from that slice's original image coordinates.

Border decorations are applied after the overlays are spliced, so a top or bottom border's overline or underline continues across an overlay and an overlay never breaks a border line. An overlay changes pixels, hit testing and visibility, never layout: the host is not resized, siblings do not shift, and the flow below the overlay is untouched.

The cost of an overlay is proportional to the lines it covers. A host composes and caches its lines, and an overlay's lines take part in that cache; when the overlay moves, only the lines it leaves and the lines it reaches are repainted, so a tooltip that moves one line does not rewrite the host. The damage bookkeeping behind this belongs to [Incremental Updates and Publication](incremental-updates-and-publication.md).

`ebox-node-geometry` reports an overlay's border box in root coordinates — host margin origin plus the overlay's host-relative position plus its own margin — so an overlay's position is directly comparable with any other node's, including through nested hosts.

## Errors and recovery

<!-- index: overlay errors; missing anchor; clipped overlay -->

A malformed `:position`, `:layer`, `:anchor` or `:placement` value, a non-integer `:z-index` or a `:left`/`:top` that is not a size is rejected while the declaration is compiled, before any layout runs, with the conditions [Style Properties](style-properties.md) describes.

A missing anchor target is not an error: the overlay is simply not placed. The usual causes are a misspelled id, a target that is hidden, a target inside the overlay itself, and duplicate ids, where only the first node in document order is followed. An unplaced overlay is silent, so when a dropdown does not appear it is worth checking the target id and whether the target is painted.

An overlay that is placed but invisible is usually clipped or covered. A host with no explicit height has no lines below its flow, so an overlay placed past the flow is cut away; the recovery is to give the host the height the design needs. A lower z value hides an overlay under a sibling, and an overlay of a nested host hides under the overlays of its ancestor host no matter how high its z is. A covered node reports no buffer position and cannot be focused, which is the intended occlusion behavior, not a defect.
