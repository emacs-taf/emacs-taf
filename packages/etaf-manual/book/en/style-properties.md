# Style Properties

<!-- index: style property; property reference; value syntax; initial value; inherited property -->

Every Host gets its appearance and its share of space from the style properties in this chapter. Each property has one entry that gives its value syntax, its initial value, the Hosts that accept it, whether it inherits, and whether changing it affects paint or geometry.

The value grammars are shared and are defined in [Values](values.md): lengths with their units and size functions, colors, fonts, shorthand expansion, inheritance and the CSS-wide keywords. This chapter is the property-by-property reference; the layer that computes a winner among declarations is [The Style System](style-system.md), and how a schema property becomes paint and geometry is [Styles Implementation](style-implementation.md).

**Reading an entry.** The first line is a table: *Value* is the grammar the property's validator accepts; *Initial* is the computed value when no declaration wins; *Applies to* names the Hosts whose author forms accept the property; *Inherited* says whether the computed value flows to descendants; *Impact* says whether a change repaints, re-lays out, or both. A shorthand has no computed value of its own: it expands into the longhands named in its entry, and its *Initial* cell is left empty.

In the tables, *every node* means a node of `text`, `box`, `row`, `column`, `flex` or `grid`. The `fragment` Host has no node of its own, and the `image` Host disregards style properties because the picture fills its cell, so neither accepts them. *Every non-`text` node* means the same set without `text`.

An inline style property that the Host kind does not accept is rejected when the View is published, as [Host](hosts.md) describes. A value outside the grammar is rejected when the node is built or updated; the declaration never reaches paint or layout.

Only seven properties inherit: `:color`, `:font-family`, `:font-size`, `:font-weight`, `:font-style`, `:text-align` and `:wrap-mode`. Everything else starts from its initial value on every node and is combined only by explicit declarations and the cascade.

```elisp :figure The seven inherited properties: color and font-weight flow into children, and an override touches only its own branch
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 0)
         :color (etaf-theme-token :ui-accent "#0969da")
         :font-weight 'bold
         (text "这一行继承颜色与字重。")
         (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "这一行覆盖颜色，字重仍继承。")
         (text :color (etaf-theme-token :ui-muted-fg "#526174") :font-weight 'normal
               "这一行两个属性都覆盖。")))
```

## Text

<!-- index: color; font; text decoration -->

Text properties set the foreground, the font and the decorations of text. They are accepted on every node, because any Host can carry text, and a font change is visible both in paint and in measurement.

#### Style: :color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A color string or `currentColor` | `nil` | Every node | Yes | Paint |

Sets the foreground color of the node's text.

**Semantics.** The string is handed to the face as a foreground without color parsing, so any face color name works. `currentColor` leaves the foreground to the default face; the border colors and `:text-decoration-color` resolve it to the text color. The value is inherited, so descendants start from their parent's computed color.

#### Style: :font-family

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-empty string or a symbol | `nil` | Every node | Yes | Paint and geometry |

Names the font family used to measure and paint the node's text.

**Semantics.** The family feeds both the face and text measurement, so changing it can change the node's size as well as its appearance. The initial value leaves the choice to the default frame font. The value is inherited.

#### Style: :font-size

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A multiple of the body size | `nil` | Every node | Yes | Paint and geometry |

Sets the font size as a multiple of the body size.

**Semantics.** The value is a bare positive number from 0.3 through 4, not a `(UNIT NUMBER)` length; zero, lengths and anything outside that range are rejected, as a pixel size left over from the older absolute API would multiply the whole interface. 1 is the body size, 1.42 a heading and 0.85 a caption, so every size follows the reader's own default font instead of assuming a body size in pixels. The size drives glyph metrics, line measurement and the face height, so it affects geometry and paint. The value is inherited.

#### Style: :font-weight

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `normal`, `bold`, `bolder`, `lighter` or `100`–`900` | `normal` | Every node | Yes | Paint and geometry |

Selects the font weight.

**Semantics.** The keyword or hundred step is mapped to the face weight and participates in measurement, so a heavier weight can widen text. The value is inherited.

#### Style: :font-style

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `normal`, `italic` or `oblique` | `normal` | Every node | Yes | Paint and geometry |

Selects the font slant; `:font-slant` is an alias.

**Semantics.** The value selects the corresponding face and is inherited. It affects measurement like the other font properties.

#### Style: :text-decoration-line

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `none` or a list of `underline`, `overline` and `line-through` | `none` | Every node | No | Paint |

Draws one or more text decorations.

**Semantics.** A list combines decorations; repeated lines are rejected, and `none` draws nothing. The decoration covers the node's own text runs. The property does not inherit, so a box does not decorate the text of its descendants.

#### Style: :text-decoration-color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A color string or `currentColor` | `currentColor` | Every node | No | Paint |

Sets the color of the decorations drawn by `:text-decoration-line`.

**Semantics.** `currentColor` and `nil` use the node's text color; an explicit string overrides it. The property does not inherit.

#### Style: :text-decoration-style

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `solid`, `double`, `dotted`, `dashed` or `wavy` | `solid` | Every node | No | Paint |

Sets the line style of text decorations.

**Semantics.** The value projects to the face's decoration style: `wavy` selects the wave variant, while the other keywords are accepted and paint a solid line. The property does not inherit.

## Sizing

<!-- index: width; height; box sizing -->

`:width`, `:height` and their minimum and maximum partners accept keywords and axis lengths, and `:box-sizing` decides what the size measures. Inline lengths resolve in pixels and block lengths in lines; percentages use the containing block. [Boxes and Normal Flow](boxes-and-normal-flow.md), [Flex Layout](flex-layout.md) and [Grid Layout](grid-layout.md) define how the constraints are resolved.

#### Style: :box-sizing

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `border-box` or `content-box`; any other value behaves as `border-box` | `border-box` | Every non-`text` node | No | Geometry |

Chooses whether `:width` and `:height` describe the border box or the content box.

**Semantics.** With `border-box` (the initial value), the declared size includes padding and border, so padding or a border shrinks the content area. With `content-box`, the declared size is the content box and padding plus border are added outside it: a 20px width with 2px padding and a 1px border occupies 26px.

#### Style: :width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `auto`, `stretch`, `min-content`, `max-content`, `fit-content` or an inline-axis length | `auto` | Every non-`text` node | No | Geometry |

Sets the inline size of the node's border box.

**Semantics.** `auto` fits the available space, `stretch` fills it, `min-content` and `max-content` take the node's intrinsic widths, and `fit-content` clamps the intrinsic width to the available space. A length resolves against the containing block's width and uses inline-axis units. `:min-width` and `:max-width` clamp the result.

#### Style: :min-width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| The `:width` keywords or an inline-axis length | `auto` | Every non-`text` node | No | Geometry |

Clamps the inline size from below.

**Semantics.** The minimum applies after `:width` has been resolved. Only a length or percentage imposes a bound; `auto`, `stretch` and the intrinsic keywords impose none, and a percentage resolves against the containing block's width.

#### Style: :max-width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `none` or the `:width` keywords or an inline-axis length | `none` | Every non-`text` node | No | Geometry |

Clamps the inline size from above.

**Semantics.** A length or percentage limits the resolved width after `:width` and `:min-width`; the other keywords, including `none`, impose no limit.

#### Style: :height

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `auto`, `stretch`, `min-content`, `max-content`, `fit-content` or a block-axis length | `auto` | Every non-`text` node | No | Geometry |

Sets the block size of the node's border box.

**Semantics.** `auto` grows with the node's content, `stretch` fills a definite containing height, and a length resolves in lines against the containing block's height; the intrinsic keywords are accepted and size to the content, like `auto`. A box whose `:overflow` is `visible` grows past a definite height instead of clipping its content. `:min-height` and `:max-height` clamp the result when they carry a length.

#### Style: :min-height

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| The `:height` keywords or a block-axis length | `auto` | Every non-`text` node | No | Geometry |

Clamps the block size from below.

**Semantics.** Only a length or percentage imposes a bound; `auto` and the other keywords impose none and resolve in lines against the containing block's height.

#### Style: :max-height

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `none` or the `:height` keywords or a block-axis length | `none` | Every non-`text` node | No | Geometry |

Clamps the block size from above.

**Semantics.** A length or percentage limits the resolved height; the other keywords, including `none`, impose no limit. A box with `:overflow visible` still grows to fit its content.

## Padding and margin

<!-- index: padding; margin; logical sides -->

Padding adds space inside the border box, margin adds space outside it. Each physical side has a longhand and each logical side has one too: `:padding-top` is the block-start side, `:padding-right` the inline-end side, `:padding-bottom` the block-end side and `:padding-left` the inline-start side, and the same mapping applies to margin. When a node declares a physical side and its logical counterpart, the non-initial logical value wins.

Both families take the axis units of their side: block units for the top and bottom sides, inline units for the left and right sides. A percentage on an inline side resolves against the containing block's width; on a block side it is accepted by the grammar but has no percentage base and adds no space, so block-axis spacing uses `lh`. Neither padding nor margin accepts a negative value.

Block padding may be fractional. `:padding-block (lh 0.5)` takes a whole line's space but paints the background over only half of it, which gives pills and bubbles even vertical air without breaking the line grid.

#### Style: :padding

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One to four side lengths, or a plist with the `:top`, `:right`, `:bottom` and `:left` keys | — | Every non-`text` node | No | Paint and geometry |

Sets padding on all sides in one declaration.

**Semantics.** The value expands to the logical longhands using the CSS rules: one value applies to all four sides, two are vertical and horizontal, three are top, horizontal and bottom, four are top, right, bottom and left. A keyword plist must give all four sides and expands directly. Each expanded declaration is validated separately, so a value that is wrong for one axis is rejected for that side.

#### Style: :padding-inline

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One or two inline-axis lengths | — | Every non-`text` node | No | Paint and geometry |

Sets padding on the inline-start and inline-end sides.

**Semantics.** One value applies to both sides and two values are start then end. The expanded longhands take inline-axis units.

#### Style: :padding-block

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One or two block-axis lengths | — | Every non-`text` node | No | Paint and geometry |

Sets padding on the block-start and block-end sides.

**Semantics.** One value applies to both sides and two values are block-start then block-end. The expanded longhands take block-axis units and may be fractional.

#### Style: :padding-top

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the top edge.

#### Style: :padding-right

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the right edge, the inline-end side.

#### Style: :padding-bottom

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the bottom edge, the block-end side.

#### Style: :padding-left

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the left edge, the inline-start side.

#### Style: :padding-block-start

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the block-start edge, the logical name of the top side.

#### Style: :padding-inline-end

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the inline-end edge, the logical name of the right side.

#### Style: :padding-block-end

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the block-end edge, the logical name of the bottom side.

#### Style: :padding-inline-start

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Adds space inside the border box on the inline-start edge, the logical name of the left side.

#### Style: :margin

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One to four side lengths, or a plist with the `:top`, `:right`, `:bottom` and `:left` keys | — | Every non-`text` node | No | Geometry |

Sets margin on all sides in one declaration.

**Semantics.** The value expands to the logical longhands with the same rules as `:padding`. Each expanded declaration is validated separately.

#### Style: :margin-inline

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One or two inline-axis lengths | — | Every non-`text` node | No | Geometry |

Sets margin on the inline-start and inline-end sides.

**Semantics.** One value applies to both sides and two values are start then end.

#### Style: :margin-block

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One or two block-axis lengths | — | Every non-`text` node | No | Geometry |

Sets margin on the block-start and block-end sides.

**Semantics.** One value applies to both sides and two values are block-start then block-end.

#### Style: :margin-top

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the top edge.

#### Style: :margin-right

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the right edge, the inline-end side.

#### Style: :margin-bottom

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the bottom edge, the block-end side.

#### Style: :margin-left

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the left edge, the inline-start side.

#### Style: :margin-block-start

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the block-start edge, the logical name of the top side.

#### Style: :margin-inline-end

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the inline-end edge, the logical name of the right side.

#### Style: :margin-block-end

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the block-end edge, the logical name of the bottom side.

#### Style: :margin-inline-start

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Geometry |

Adds space outside the border box on the inline-start edge, the logical name of the left side.

## Borders and corner radius

<!-- index: border; corner radius; stroke width -->

Border widths take stroke units — `px`, `ch`, `lh`, `vw` and `vh`, without percentages — and a side paints only when its style is `solid`; `none` and `solid` are the only border styles. The left and right borders paint as pixel-wide spaces at their resolved width. The top and bottom borders become the line's overline and underline, so they are limited to one pixel: a wider top or bottom border signals `ebox-error` when the node is built or updated.

Border colors are strings or `currentColor`, and `currentColor` uses the node's text color. `:border-radius` rounds the painted box background and supported complete outlines on graphical frames; terminals paint square corners.

#### Style: :border

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A width, style and color in any order, or one value | — | Every non-`text` node | No | Paint and geometry |

Sets all four border sides in one declaration.

**Semantics.** A single length sets that width and a `solid` style; `solid` or `none` sets a 1px width with that style; a string sets a 1px `solid` border in that color. A list is classified by item type and may omit components: the default width is `(px 1)`, the default style `solid` and the default color is unset, so the border follows the text color. A duplicated component is rejected.

#### Style: :border-top

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A width, style and color in any order, or one value | — | Every non-`text` node | No | Paint and geometry |

Sets the top border's width, style and color in one declaration.

**Semantics.** Expansion and component classification are the same as `:border`; only the top side is set.

#### Style: :border-right

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A width, style and color in any order, or one value | — | Every non-`text` node | No | Paint and geometry |

Sets the right border's width, style and color in one declaration.

**Semantics.** Expansion and component classification are the same as `:border`; only the right side is set.

#### Style: :border-bottom

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A width, style and color in any order, or one value | — | Every non-`text` node | No | Paint and geometry |

Sets the bottom border's width, style and color in one declaration.

**Semantics.** Expansion and component classification are the same as `:border`; only the bottom side is set.

#### Style: :border-left

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A width, style and color in any order, or one value | — | Every non-`text` node | No | Paint and geometry |

Sets the left border's width, style and color in one declaration.

**Semantics.** Expansion and component classification are the same as `:border`; only the left side is set.

#### Style: :border-width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One to four non-negative stroke lengths | — | Every non-`text` node | No | Paint and geometry |

Sets all four border widths in one declaration.

**Semantics.** The value follows the TRBL rules: one value applies to all sides, two are vertical and horizontal, three are top, horizontal and bottom, four are top, right, bottom and left.

#### Style: :border-style

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One to four of `none` and `solid` | — | Every non-`text` node | No | Paint and geometry |

Sets all four border styles in one declaration.

**Semantics.** The value follows the TRBL rules and expands to the four physical style longhands.

#### Style: :border-color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One to four color strings or `currentColor` | — | Every non-`text` node | No | Paint |

Sets all four border colors in one declaration.

**Semantics.** The value follows the TRBL rules and expands to the four physical color longhands.

#### Style: :border-top-p

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `t` or `nil` | — | Every non-`text` node | No | Paint and geometry |

Turns the top border on or off.

**Semantics.** `t` sets a 1px `solid` top border and `nil` sets width 0 and style `none`; no other value is accepted. It is a compact way to draw a separator above a row.

#### Style: :border-top-width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative stroke length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Sets the stroke width of the top border, limited to one pixel.

#### Style: :border-right-width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative stroke length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Sets the stroke width of the right border.

#### Style: :border-bottom-width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative stroke length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Sets the stroke width of the bottom border, limited to one pixel.

#### Style: :border-left-width

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative stroke length | `(px 0)` | Every non-`text` node | No | Paint and geometry |

Sets the stroke width of the left border.

#### Style: :border-top-style

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `none` or `solid` | `none` | Every non-`text` node | No | Paint and geometry |

Selects the top border style.

#### Style: :border-right-style

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `none` or `solid` | `none` | Every non-`text` node | No | Paint and geometry |

Selects the right border style.

#### Style: :border-bottom-style

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `none` or `solid` | `none` | Every non-`text` node | No | Paint and geometry |

Selects the bottom border style.

#### Style: :border-left-style

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `none` or `solid` | `none` | Every non-`text` node | No | Paint and geometry |

Selects the left border style.

#### Style: :border-top-color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A color string or `currentColor` | `currentColor` | Every non-`text` node | No | Paint |

Sets the top border color.

#### Style: :border-right-color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A color string or `currentColor` | `currentColor` | Every non-`text` node | No | Paint |

Sets the right border color.

#### Style: :border-bottom-color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A color string or `currentColor` | `currentColor` | Every non-`text` node | No | Paint |

Sets the bottom border color.

#### Style: :border-left-color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A color string or `currentColor` | `currentColor` | Every non-`text` node | No | Paint |

Sets the left border color.

#### Style: :border-radius

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | Every non-`text` node | No | Paint |

Rounds the painted box background and complete one-pixel outlines on graphical frames.

**Semantics.** With SVG support, a complete same-color 1 px solid border rounds its first and last lines when both corners contain only blank padding. The outline radius is limited to one standard line and half the box width and height. Provide enough padding to keep text or media outside the corners; otherwise that line keeps its square outline rather than covering content. The middle stays native text, a header band keeps its own background, and geometry, focus and activation do not change. Unequal or incomplete borders, unavailable SVG support and terminals retain square outlines. Background rounding without an outline retains its existing behavior; terminals paint square, full-line backgrounds.

## Background and visibility

<!-- index: background color; visibility -->

`:background-color` paints the box behind its content and propagates to descendants that have no background of their own. `:visibility hidden` suppresses the ink of a whole subtree while keeping its layout space.

#### Style: :background-color

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A color string | `nil` | Every node | No | Paint |

Paints the node's box behind its content.

**Semantics.** The value is a color string handed to the face without parsing. The property does not inherit, but a node without a background of its own paints the background of its nearest ancestor that has one, so a panel's background shows through its descendants. On graphical frames `:border-radius` rounds the painted background.

#### Style: :backdrop-filter

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `nil` or `(brightness AMOUNT)` | `nil` | Every non-`text` node | No | Paint |

Dims the cells an overlay covers while keeping their text and images visible.

**Semantics.** AMOUNT is a non-negative number: values below 1 dim every covered pixel, 1 keeps it unchanged, and values above 1 brighten with each color channel clamped at its maximum. The effective foreground and background colors of covered text cells multiply by AMOUNT, including nested inherited faces and canvas-remapped defaults. On graphical frames with SVG support, self-contained PNG, JPEG and SVG displays multiply their sRGB channels while preserving alpha, native `currentColor`, dimensions, slices and row insets. File sources prepared with `ebox-image-prepare` are self-contained; raw file-only displays, other native formats and frames without SVG keep the original image pixels rather than hiding them. Image composites are cached in memory without source I/O or external conversion; nested filters apply in stacking order. Removing the overlay restores the original image descriptors. A blank cell of the filtered node shows the dimmed pixel behind it, so a full-screen box with `:backdrop-filter` and no background dims the page without hiding it, while cells the node paints itself hide the dimmed pixels. Borrowed pixels retain only their paint: hit ownership, native keymap, pointer, help and hover feedback come from the covering node, not the background text. This lets a backdrop handle outside clicks without activating covered controls. A modal backdrop that only covers, such as an opaque `:background-color`, still hides what is behind it.

Composition filters only the background spans borrowed through the overlay's blank cells, rather than first filtering the whole covered line. Each borrowed span gets one owned copy for both its paint and the covering input properties; shared source strings remain unchanged. This reduces transient allocation during updates inside a modal without retaining a separate cache of callback-bearing background strings.

#### Style: :visibility

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `visible` or `hidden` | `visible` | Every non-`text` node | No | Paint |

Hides or shows the node and its subtree without changing layout.

**Semantics.** `hidden` suppresses the ink of the node and everything below it but keeps their space, so neighbours do not move. It is deliberately not inherited: each node checks its own value and its ancestors when painting, so hiding one node does not restyle its descendants. Any value other than `hidden` paints normally.

## Rows and columns

<!-- index: item gap; cross alignment -->

A `row` or `column` lays its direct children along one axis. `:item-gap` sets the main-axis gap between them and `:cross-align` the cross-axis alignment; [Flex Layout](flex-layout.md) defines the fuller algorithm.

#### Style: :item-gap

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative main-axis length | `(px 0)` | `row` and `column` | No | Geometry |

Sets the main-axis gap between the direct children of a row or column.

**Semantics.** A row takes inline-axis units and a column takes block-axis units. The gap is inserted between adjacent children only, never before the first or after the last.

#### Style: :cross-align

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `start`, `center`, `end` or `stretch` | `stretch` | `row` and `column` | No | Geometry |

Aligns the direct children of a row or column on the cross axis.

**Semantics.** `stretch` lets a child fill the container's cross size; `start`, `center` and `end` place the child on the container's cross axis.

## Flex

<!-- index: flex container; flex item; gap -->

A `flex` container distributes and aligns its direct children with the container properties in this section, and its children take the item properties. `:gap`, `:row-gap` and `:column-gap` are shared with `grid`, and `:justify-content`, `:align-items` and `:align-content` also apply to `grid` containers. [Flex Layout](flex-layout.md) defines the algorithm; this section gives each property's grammar and its effect.

#### Style: :flex-direction

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `row`, `row-reverse`, `column` or `column-reverse` | `row` | `flex` | No | Geometry |

Sets the main axis of a flex container.

**Semantics.** `row` and `row-reverse` lay the children out horizontally and `column` and `column-reverse` vertically. The reversal changes the direction of placement, not just the visible order, so `:justify-content` follows it.

#### Style: :flex-wrap

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `nowrap`, `wrap` or `wrap-reverse` | `nowrap` | `flex` | No | Geometry |

Allows the children to wrap onto several lines and sets the cross-axis direction of the lines.

**Semantics.** `nowrap` keeps one line, `wrap` starts new lines in the cross direction and `wrap-reverse` starts them from the opposite side.

#### Style: :flex-flow

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One direction and one wrapping keyword in any order | — | `flex` | No | Geometry |

Sets `:flex-direction` and `:flex-wrap` in one declaration.

**Semantics.** The two items are recognized by type, so their order is free; a value that is not exactly one direction plus one wrapping keyword is rejected.

#### Style: :justify-content

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `normal`, `start`, `end`, `flex-start`, `flex-end`, `center`, `stretch`, `space-between`, `space-around` or `space-evenly` | `flex-start` | `flex` and `grid` | No | Geometry |

Distributes the children along the main axis.

**Semantics.** `start` and `flex-start` pack at the start, `end` and `flex-end` at the end, and `center` centers. `space-between`, `space-around` and `space-evenly` distribute the free space. In a flex container `normal` and `stretch` pack at the start; in a grid, `stretch` and `normal` expand the tracks to fill the container.

#### Style: :align-items

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `normal`, `start`, `end`, `stretch`, `flex-start`, `flex-end`, `center` or `baseline` | `stretch` | `flex` and `grid` | No | Geometry |

Aligns the children on the cross axis of a flex container and inside their area in a grid.

**Semantics.** `stretch` fills the cross size, `start`, `end`, `center` and `baseline` place the child, and `normal` behaves like `stretch`. `baseline` is accepted and aligns the child like `start`. An item can override it with `:align-self`.

#### Style: :align-content

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `normal`, `start`, `end`, `stretch`, `flex-start`, `flex-end`, `center`, `space-between`, `space-around` or `space-evenly` | `stretch` | `flex` and `grid` | No | Geometry |

Distributes a flex container's lines, or a grid's tracks, along the cross axis.

**Semantics.** It takes the same distribution keywords as `:justify-content`. `stretch` expands the lines or tracks to fill the container, and the other keywords distribute the free space between them.

#### Style: :row-gap

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative block-axis length | `(lh 0)` | `flex` and `grid` | No | Geometry |

Sets the gap between flex lines and between grid rows.

**Semantics.** The value resolves in block-axis units, and a percentage uses the containing block's height.

#### Style: :column-gap

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative inline-axis length | `(px 0)` | `flex` and `grid` | No | Geometry |

Sets the gap between flex items and between grid columns.

**Semantics.** The value resolves in inline-axis units, and a percentage uses the containing block's width.

#### Style: :gap

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| One or two non-negative lengths | — | `flex` and `grid` | No | Geometry |

Sets `:row-gap` and `:column-gap` in one declaration.

**Semantics.** One value applies to both axes and must therefore be valid for both — zero or a percentage — while two values are row gap then column gap. This is the usual way to space toolbar items.

```elisp :run
(etaf-define-component demo-gap-toolbar ()
  :view (flex :gap '((lh 0) (ch 2))
              (text :color "#e5e7eb" "Save")
              (text :color "#e5e7eb" "Cancel"))
  :styles (("&" :background-color "#1f2937")))
(etaf-view (demo-gap-toolbar))
```

#### Style: :order

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| An integer | `0` | Every non-`text` node | No | Geometry |

Changes the order in which a flex container places its children.

**Semantics.** Children are placed in ascending order; equal values keep document order. It applies to the direct children of a flex or grid container.

#### Style: :flex-grow

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative number | `0` | Every non-`text` node | No | Geometry |

Sets how much of the free main-axis space the item takes.

**Semantics.** Free space is distributed in proportion to the factors. The initial value leaves the item at its basis. [Flex Layout](flex-layout.md) defines how growth interacts with minimum and maximum sizes.

#### Style: :flex-shrink

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative number | `1` | Every non-`text` node | No | Geometry |

Sets how much the item shrinks when the line overflows.

**Semantics.** Items shrink in proportion to factor times basis; `0` keeps the item at its basis, so it can overflow instead of shrinking.

#### Style: :flex-basis

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `auto`, `min-content`, `max-content`, `fit-content`, `stretch` or a non-negative length | `auto` | Every non-`text` node | No | Geometry |

Sets the item's initial main size before free space is distributed.

**Semantics.** `auto` uses the item's main size property — `:width` on a row and `:height` on a column. A length is accepted in every length unit because the item's axis is not known at declaration time.

#### Style: :align-self

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `auto`, `normal`, `start`, `end`, `stretch`, `flex-start`, `flex-end`, `center` or `baseline` | `auto` | Every non-`text` node | No | Geometry |

Overrides `:align-items` for one item.

**Semantics.** `auto` follows the container's `:align-items`; any other value applies to this item only. `normal` aligns like `stretch`, and `baseline` like `start`.

#### Style: :flex

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A non-negative number, `none`, `auto`, `initial`, or `(grow shrink basis)` | — | Every non-`text` node | No | Geometry |

Sets the item's growth, shrink and basis in one declaration.

**Semantics.** A number N expands to `:flex-grow N`, `:flex-shrink 1` and `:flex-basis (% 0)`; `none` is 0 0 auto, `auto` is 1 1 auto and `initial` is 0 1 auto; a three-element list gives the longhands directly.

## Grid

<!-- index: grid template; grid placement; track -->

A `grid` container places its children on explicit and implicit tracks. Track lists are built from fixed and intrinsic sizes, fractional units, `(minmax MIN MAX)` and `(repeat N TRACK)`; placement is one-based. [Grid Layout](grid-layout.md) defines the sizing and placement algorithms; this section gives each property's grammar and its effect.

#### Style: :grid-template-columns

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `nil` or a list of column tracks | `nil` | `grid` | No | Geometry |

Defines the grid's explicit column tracks.

**Semantics.** A track is `auto`, `min-content`, `max-content`, a non-negative inline-axis length, `(fr N)` with a positive N, `(minmax MIN MAX)` whose minimum cannot be fractional, or `(repeat N TRACK)` — where TRACK is one track or a list — with a positive N. Fractional tracks divide the free space.

#### Style: :grid-template-rows

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `nil` or a list of row tracks | `nil` | `grid` | No | Geometry |

Defines the grid's explicit row tracks.

**Semantics.** The grammar is the same as `:grid-template-columns`, with block-axis lengths.

#### Style: :grid-auto-columns

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `auto`, a single track, or a one-element list of one track | `auto` | `grid` | No | Geometry |

Sizes the implicit columns created by auto-placement.

**Semantics.** A single track in the same grammar as the template list, without `repeat`.

#### Style: :grid-auto-rows

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `auto`, a single track, or a one-element list of one track | `auto` | `grid` | No | Geometry |

Sizes the implicit rows created by auto-placement.

**Semantics.** A single track in the same grammar as the template list, without `repeat`, with block-axis lengths.

#### Style: :grid-auto-flow

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `row` or `column` | `row` | `grid` | No | Structure |

Chooses the axis along which auto-placement fills the grid.

**Semantics.** `row` fills row by row and adds implicit rows; `column` fills column by column and adds implicit columns.

#### Style: :grid-column

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `nil`, `auto`, a positive integer, `(N)`, `(START :span SPAN)`, `(:span SPAN)` or `(START END)` | `auto` | Every non-`text` node | No | Geometry |

Places the item on one or more columns.

**Semantics.** Numbers are one-based track lines on the explicit or implicit grid. `(:span N)` spans N tracks from the auto-placement position, `(START END)` is an explicit range whose end is greater than its start, and `auto` leaves placement to the algorithm.

#### Style: :grid-row

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `nil`, `auto`, a positive integer, `(N)`, `(START :span SPAN)`, `(:span SPAN)` or `(START END)` | `auto` | Every non-`text` node | No | Geometry |

Places the item on one or more rows.

**Semantics.** The grammar and rules are the same as `:grid-column`, on the block axis.

#### Style: :grid-column-span

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A positive integer | — | Every non-`text` node | No | Geometry |

Spans the item across N columns.

**Semantics.** The shorthand expands to `:grid-column (:span N)`.

#### Style: :grid-row-span

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A positive integer | — | Every non-`text` node | No | Geometry |

Spans the item across N rows.

**Semantics.** The shorthand expands to `:grid-row (:span N)`.

#### Style: :justify-items

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `stretch`, `start`, `end` or `center` | `stretch` | `grid` | No | Geometry |

Aligns grid items inside their column area on the inline axis.

**Semantics.** It is the default for items that do not set `:justify-self`.

#### Style: :justify-self

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `auto`, `stretch`, `start`, `end` or `center` | `auto` | Every non-`text` node | No | Geometry |

Overrides `:justify-items` for one grid item.

**Semantics.** `auto` follows the container's `:justify-items`; any other value applies to this item only.
## Positioning and layers

<!-- index: absolute positioning; z-index; anchor; overlay layer -->

A box is in normal flow unless `:position` takes it out of it. An absolutely positioned box is placed by `:left` and `:top` from its positioning host — the nearest non-inline ancestor, or the root for `:layer root` — and `:z-index` orders overlapping paint. `:anchor` and `:placement` place an absolute box against a unique target instead of the host origin. [Positioning, Layers and Overlays](positioning-layers-and-overlays.md) defines the full model.

#### Style: :position

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `static`, `relative` or `absolute` | `static` | Every non-`text` node | No | Geometry |

Sets how the node participates in its parent's layout.

**Semantics.** `static` is normal flow. `relative` keeps the node's flow slot and only affects paint order through `:z-index`; the `:left` and `:top` offsets do not move it. `absolute` removes the box from flow and makes it an overlay of its positioning host.

#### Style: :left

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A signed inline-axis length | `(px 0)` | Every non-`text` node | No | Geometry |

Sets the horizontal offset of an absolutely positioned box from its positioning host.

**Semantics.** The offset is measured from the host's content origin, or from the root's border-box origin for a root-layer box without an anchor. A percentage uses the host's padding-box width, or the root's border-box width for a root-layer box without an anchor. The property has no effect on a box that is not absolutely positioned.

#### Style: :top

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| A signed block-axis length | `(lh 0)` | Every non-`text` node | No | Geometry |

Sets the vertical offset of an absolutely positioned box from its positioning host.

**Semantics.** The offset is measured from the host's content origin, or from the root's border-box origin for a root-layer box without an anchor. A percentage uses the host's border-box height. The property has no effect on a box that is not absolutely positioned.

#### Style: :z-index

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| An integer | `0` | Every non-`text` node | No | Paint |

Orders overlapping boxes.

**Semantics.** Boxes paint in ascending `:z-index`. A relatively positioned flow child with a positive value paints above absolute siblings with a lower value while keeping its flow slot, so their backgrounds show through its blank cells.

#### Style: :layer

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `local` or `root` | `local` | Every non-`text` node | No | Geometry |

Chooses whether an absolutely positioned box paints inside its host's layer or the root's top layer.

**Semantics.** `local` paints the overlay inside its positioning host. `root` paints it in the root's top layer while keeping its logical parent for selectors and inheritance. Without an anchor, a root-layer box measures its offsets and percentages from the root's border box, so `:width (% 100)` and `:height (% 100)` cover the whole page.

#### Style: :anchor

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `nil`, a symbol or a string | `nil` | Every non-`text` node | No | Geometry |

Makes an absolute box follow the node whose `:id` matches the value.

**Semantics.** The value names a node in the box's root tree. The overlay is placed from the target's box using `:placement`; while the target is missing, hidden or inside the overlay itself, the box paints nothing, has no position and cannot take focus. This is the property a dropdown or tooltip uses to stay beside its trigger.

#### Style: :placement

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `bottom-start`, `bottom-end`, `top-start`, `top-end` or `center` | `bottom-start` | Every non-`text` node | No | Geometry |

Chooses which corner of the anchor target an overlay is placed against, or centers an unanchored overlay.

**Semantics.** With an anchor, the name is the vertical side followed by the horizontal side; when the preferred vertical side would leave the host, placement flips to the other side if that fits, and the result stays inside the host. Without an anchor, `center` centers the overlay horizontally and vertically from its laid-out size within its host (or within the visible viewport band starting at `:top` on `:layer root`), clamped inside the host.

## Text alignment and wrap mode

<!-- index: text align; wrap mode -->

`:text-align` positions the lines of a box's paragraph and `:wrap-mode` chooses how those lines break. Both inherit. [Text](text.md) defines the wrap modes and the line-breaking rules.

#### Style: :text-align

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `left`, `center`, `right`; `end` behaves as `right` and any other value as `left` | `left` | `box` only | Yes | Geometry |

Aligns the lines of the box's text paragraph.

**Semantics.** `center` centers and `right` or `end` right-aligns each line; any other value is left-aligned. The value is inherited, so a container passes its alignment to descendant boxes, but only a `box` accepts the declaration.

#### Style: :wrap-mode

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `word`, `char`, `kp` or `none` | `word` | Every non-`text` node | Yes | Geometry |

Chooses how lines break when the text is wider than the available space.

**Semantics.** `word` breaks between words, `char` breaks between characters, `kp` runs the Knuth-Plass paragraph breaker, and `none` disables soft wrapping while keeping explicit newlines. The value is inherited.

## Overflow and scrolling

<!-- index: overflow; scroll anchor -->

`:overflow` decides what happens when content is larger than its box and which boxes provide a scrolling viewport; `:scroll-anchor` decides whether a scrolled box follows the end of its content. [Scrolling](scrolling.md) defines the scrolling interfaces.

#### Style: :overflow

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `visible`, `hidden`, `scroll` or `auto` | `scroll` | Every non-`text` node | No | Paint and geometry |

Controls clipping and vertical scrolling for content larger than the box.

**Semantics.** `visible` does not clip and grows the box to fit its content. `hidden` clips horizontally and vertically at whole display units. `scroll` (the initial value) and `auto` show a scrolling viewport whose offset the scrolling commands read and change, and clip the content to the box.

#### Style: :scroll-anchor

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `start` or `end` | `start` | Every non-`text` node | No | Geometry |

Pins a scrolled box to the start or the end of its content.

**Semantics.** With `end`, a box that is pinned to its last line keeps following that line as content grows, which is the usual chat and log behaviour. `start` keeps the view at the top.

## Structural properties

<!-- index: outer; inline box; block box -->

The remaining property changes how a box takes part in a container's flow rather than how it looks.

#### Style: :outer

| Value | Initial | Applies to | Inherited | Impact |
| --- | --- | --- | --- | --- |
| `inline` or `block` | `block` | Every non-`text` node | No | Structure and geometry |

Chooses whether a box participates in inline formatting or as a block.

**Semantics.** A box with `:outer inline` participates in inline formatting when all of its children are inline or absolutely positioned, so it sits beside its neighbours. With the initial `block`, or when a child is a block, the box takes its own line in the stacked flow.
