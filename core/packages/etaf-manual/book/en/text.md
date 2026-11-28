# Text

A text node is the only Ebox node that carries characters; every box ultimately exists to arrange them. This chapter describes how text nodes are created and what properties they accept, how the line-breaking modes of `:wrap-mode` fill the available width, how CJK text, grapheme clusters and emoji stay whole, how text decoration paints, and how measurement results are cached. The properties themselves are defined in [Style Properties](style-properties.md); [Boxes and Normal Flow](boxes-and-normal-flow.md) describes the paragraphs these nodes take part in, and [Rendering Model](rendering-model.md) the pixels and line heights they resolve to.

#### Function: ebox-text-create (string &optional props)

Create a detached text node showing STRING with author PROPS.

**Arguments.** `string` is the payload, copied into the node; an empty string is valid. `props` is an optional author property plist limited to the paint and typography properties a text node accepts: `:color`, `:background-color`, `:font-family`, `:font-size`, `:font-weight`, `:font-style`, `:text-decoration-line`, `:text-decoration-color` and `:text-decoration-style`. Layout properties belong to the box that owns the paragraph, not to the text node.

**Semantics.** The node is detached until it is passed as a child of another node, where it becomes part of that box's paragraph. A text node is a leaf and never takes children. Because it has no box geometry of its own, it is measured and wrapped by its paragraph: `:wrap-mode` and `:text-align` are read from the owning box (or the nearest ancestor that declares them), and the node's typography is inherited through the same computed style chain as any other box. `ebox-node-text-p` recognizes text nodes, and `ebox-node-set-text` replaces their payload later.

**Returns.** The new detached text node.

**Errors.** A non-string `string` raises `ebox-error` with the message "Ebox text payload must be a string". An unsupported property or an invalid value raises `ebox-error` while the node is created, as in "Ebox text does not accept :width".

**Example.** `(ebox-text-create "hello")` builds a node whose text is `hello`; attaching it to a box three pixels wide and rendering that box breaks it into `hel` and `lo` under the default `word` mode.

**See also.** `ebox-node-create`, `ebox-node-set-text`.

## Line breaking

<!-- index: line breaking; wrap mode; word break; soft break; space handling -->

A paragraph breaks its inline pieces into lines no wider than the containing box's content width. The unit of breaking is a grapheme cluster together with its classification: a newline, a space, a CJK character, or part of a word. `:wrap-mode` chooses which of those units may start a new line.

The initial `word` mode moves whole words: a word that does not fit starts the next line, and the space before it ends its line and is dropped. A word wider than the whole line cannot be moved anywhere, so it is split cluster by cluster. `char` mode treats every cluster as a break opportunity, so lines are filled to the pixel. `none` mode breaks only at explicit newlines; text wider than the paragraph is not wrapped and the part beyond the available width is not shown, because a paragraph never scrolls horizontally. A paragraph whose pieces fit on one line skips the breaking work entirely.

`\n` always starts a new line, in every mode, and it is the only break in `none` mode. A run of spaces that does not fit ends its line: the spaces are dropped rather than pushed to the next line. A paragraph made only of spaces renders as an empty line.

Each line is padded to the paragraph width according to `:text-align`: `left` leaves the free pixels at the end, `center` splits them, and `right` puts them at the start. When the line is wider than the paragraph there is nothing to pad, and the line is cut at the paragraph edge.

Soft breaks respect punctuation rules. A closing bracket or sentence mark (`。`, `、`, `）`, `」`, `.`, `,` and their families) must not begin a wrapped line, and an opening bracket or quote (`（`, `「`, `'` and their families) must not end one; when a soft break would do either, the break moves back to the previous cluster or word, which pulls the punctuation onto the current line and shortens it. The rule is given up when moving back would empty the line, so extremely narrow paragraphs still make progress.

**Example.** With a 4-pixel width and the default `word` mode, `中文。汉字` breaks as `中` / `文。` / `汉字`: the `。` may not start a line, so it is pulled onto the line above and `中` stays alone. A 3-pixel width gives one character per line and lets `。` start a line, because the required move back would empty the line. `ab（cd）` breaks as `ab` / `（cd` / `）` for the same reason, with the opening bracket kept off the line end.

## The kp wrap mode

<!-- index: kp wrap mode; Knuth-Plass -->

`kp` is accepted as a `:wrap-mode` value, but Ebox does not implement Knuth–Plass breaking yet: the layout falls through to the `word` rules, so a paragraph under `kp` breaks exactly like one under `word`, including its split of over-wide words. The mode is reserved for the paragraph-optimal breaking that the [EKP typesetting package](ekp-principles.md) implements separately; Ebox does not link EKP, and no Ebox build turns `kp` into the optimal algorithm. Applications that need that behavior today typeset the paragraph with EKP and mount the result elsewhere.

## CJK, clusters and emoji

<!-- index: CJK; grapheme cluster; emoji; regional indicator -->

CJK characters break like spaces in `word` mode: each one ends a line if the next does not fit, so a Chinese or Japanese paragraph wraps at any character boundary without needing break opportunities. CJK punctuation also takes part in the soft-break rules above, so a full-width comma or period is never left at the start of a line when the line has room to pull it back. CJK clusters are measured at their own width — two pixels for a full-width character in the fallback metrics, their font advance in a graphical frame.

A grapheme cluster is the smallest unit that is measured, split and broken. Combining marks stay with their base character, variation selectors and zero-width joiners extend the cluster they follow, and a pair of regional indicators forms one flag cluster; breaking a line can never separate those parts. Emoji sequences built with joiners therefore move as one unit in `word` mode and count as one break opportunity in `char` mode, just like a single ideograph. The default word splitting for an over-wide word also cuts only at cluster boundaries, never inside one.

## Text decoration

<!-- index: text decoration; underline; overline; strike-through; wavy -->

`:text-decoration-line` values (`underline`, `overline`, `line-through`, or a list of them) are projected into the face that paints the text, so a decoration follows the glyphs exactly as a face property does. `:text-decoration-color` chooses the line color and defaults to `currentColor`; `:text-decoration-style` currently supports `solid` and `wavy`, the latter painting a wave style line. A text node's own decoration replaces the face's other decorations rather than adding to them.

Decoration propagates to descendants. A box that declares a decoration passes it down the tree, through intermediate boxes and inline boxes, to every text node below that does not declare one of its own; a text node cannot cancel an inherited decoration, because a declaration of `none` simply leaves the inherited one in place. Declaring a different line on a descendant replaces the inherited decoration for that subtree instead of stacking with it.

Text in a subtree that is hidden with `:visibility hidden` keeps its characters and its line breaking: the text is painted as blank space of the same widths, so hidden text occupies exactly the space it would show. This is what makes `visibility` useful for layout placeholders.

**Example.** Underlining a box and rendering `ab` and `cd` as text gives both runs a face with `:underline`; making `cd` `line-through` replaces the underline on that run with a strike-through. A hidden six-character run three pixels wide still renders two blank lines.

```elisp :figure Weight, slant and the two text decorations
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (text :font-weight 'bold "加粗")
   (text :font-style 'italic "倾斜")
   (text :text-decoration-line '(underline) "下划线")
   (text :text-decoration-line '(line-through) "删除线")
   (text :font-family (or (face-attribute 'fixed-pitch :family nil t) "Monospace")
         "等宽文本")))
```

## Measurement caching

<!-- index: text measurement; measurement cache; cluster width -->

A text node caches its measurement: the face it was measured with, its payload, the wrap mode, whether the text contains a newline, the width of its longest line, the width of its longest unbreakable run, and — computed lazily the first time the paragraph must break — its display units. Any change to the payload, the face, the wrap mode or the global width epoch recomputes the measurement; an unchanged node reuses it. The paragraph caches its wrapped lines in the same way, and rebuilds them when the text, computed style or interaction of any inline node in it changes.

Widths are measured per cluster and memoized per face, so a paragraph of repeated characters measures each cluster once. Font changes that keep the metrics identical — an inheritable weight change under a monospaced family, for example — repaint without re-measuring. When a whole-tree font change invalidates the measurements, `ebox-clear-cache` drops the width caches and the next layout measures again; [Rendering Model](rendering-model.md) defines the epoch that drives this.

#### Function: etaf-string-pixel-width (string)

Return the display pixel width of STRING's first line.

**Semantics.** The measure honors STRING's `face` and `display` properties, so styled text and plain text can measure differently, and a newline ends the measurement. Applications use it to align content to glyph widths with the same measure the renderer used.

**Returns.** The width in pixels; an empty string is zero.

**Errors.** `error→ wrong-type-argument` naming `stringp` when STRING is not a string.

**See also.** `ebox-text-create`.

## Errors and recovery

<!-- index: text errors; unwrappable text; empty text -->

Creating a text node with a non-string payload raises `ebox-error`, and so does an unsupported property or an invalid value: property mistakes surface at construction, before any layout. A text node with an empty string is legal and renders as an empty line, which is the way to leave a deliberate blank row in a block.

Text that cannot be broken is still handled: a word wider than its line is split at cluster boundaries under `word`, and under `none` the overflow is simply not shown. When that overflow is content rather than decoration, give the paragraph a wider box, choose `word` or `char`, or put the text in a scrolling container, which [Scrolling](scrolling.md) describes. A narrowing paragraph never silently loses characters except under `none`; the other modes always break.
