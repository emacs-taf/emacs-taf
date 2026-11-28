# Programming Interface

EKP can be used without a buffer. The string interface takes text as a value, returns justified text as a value, and never touches the current buffer or a window: applications embed it to typeset a paragraph they are about to display, and other packages call it to prepare text for their own renderer. This chapter defines that boundary: the two justifying calls, the semantic plan behind them, and the cache control that goes with them.

The layout model is [Line-Breaking Principles](ekp-principles.md), and the buffer commands that project the same plans onto editing buffers are [Interactive Use](ekp-interactive-use.md). The options that steer width selection, hyphenation, kinsoku and the overlong-token policy are user options collected in the [Parameter Reference](ekp-parameters.md) chapter; this chapter names them where a function's result depends on them.

## The string boundary

<!-- index: string layout; paragraph; layout plan; cache; natural overlong token -->

A string argument is one or more paragraphs separated by newline characters. Every newline-separated segment is planned as an independent paragraph, and an empty segment stays empty: blank lines are preserved exactly where the input puts them, and no break decision crosses a newline. There is no measure argument on the paragraph level — the width argument is the whole measure a paragraph is planned against.

Text properties on the input are honored exactly as they are in a buffer: a rigid no-break atom stays whole, and a span carrying a break policy keeps it, so hyphenation can be forced on or off for a span of a plain string. Verbatim protection belongs to the buffer layer — the string interface plans every paragraph it is given — so a caller that wants a paragraph untouched simply does not pass it.

The result of justification is a new string, not a mutation of the argument. It contains the source characters together with the synthesized spacing and breaks that make the paragraph justified, and the source fragments those replaced are recorded as text properties so that the package's own buffer layer can invert the transformation when the same string is inserted into a buffer. A caller that needs the untouched source therefore keeps the input; stripping properties from the result does not recover it. The call is deterministic: the same string and width produce an equal result, properties included.

When the native module is loaded and the input has more than one non-blank paragraph, string justification plans the paragraphs in parallel before rendering them, which is what makes wide documents of many short paragraphs fast. The result does not depend on whether that path was taken. One policy has a visible shortcut in this layer: when `ekp-overlong-token-policy` is `natural` and a paragraph contains an ordinary Latin-like token wider than the measure, the paragraph is returned as written instead of being planned, leaving the whole paragraph to Emacs's wrapping.

## Justifying strings

#### Function: ekp-pixel-justify (string line-pixel)

Justify multiline STRING to LINE-PIXEL pixels.

**Arguments.** STRING is the text; each newline-separated segment is one paragraph. LINE-PIXEL is the target width in pixels and must be a positive integer.

**Semantics.** Every non-blank paragraph is planned at LINE-PIXEL and rendered; blank segments are copied through unchanged. Text properties on STRING act as layout inputs, as the string boundary describes, and a paragraph left natural by the overlong-token policy is returned untouched. When the native module is available and the input holds several paragraphs, planning runs in parallel. The result is a fresh, deterministic string: the same input and width always produce an equal result.

**Returns.** The justified string. Its visible form is the justified paragraph; the source text around every synthesis is recorded in its text properties for the package's own rendering layer.

**Errors.** `error→ wrong-type-argument` naming `stringp` when STRING is not a string. `error→ user-error` with the message `Line width must be a positive integer, got PIXEL` when LINE-PIXEL is not a positive integer. Errors from planning itself propagate unchanged, for example `ekp-hyphen-unsupported-pattern` when a selected dictionary cannot be used.

**Example.**

```elisp
(ekp-pixel-justify "one two three four five six seven eight nine ten" 60)
     ⇒ the same words laid out at a 60-pixel measure
(length (split-string
         (ekp-pixel-justify "one two three four five six seven eight nine ten" 60)
         "\n"))
     ⇒ 1 with automatic spacing, 2 after (ekp-param-set 4 8 2 3 6 2 0 4 0)
```

**See also.** `ekp-pixel-range-justify`, `ekp-layout-plan`, `ekp-clear-caches`.

#### Function: ekp-pixel-range-justify (string min-pixel max-pixel)

Find optimal width for STRING between MIN-PIXEL and MAX-PIXEL.

**Arguments.** STRING is the text, planned exactly as `ekp-pixel-justify` plans it. MIN-PIXEL and MAX-PIXEL are positive integers bounding the candidate widths, with MIN-PIXEL not greater than MAX-PIXEL.

**Semantics.** The function searches the range for the width at which the paragraphs have the lowest average cost — the demerits a paragraph pays, averaged over the non-blank paragraphs, so a long input does not outweigh a short one. The search is a ternary search refined by a local scan, and it returns a good local optimum rather than a guarantee: cost as a function of width jumps whenever the chosen number of lines changes, so the curve is not strictly unimodal. A range of one width is legal and simply justifies at it. The returned text is exactly the result of `ekp-pixel-justify` at the returned width.

**Returns.** A cons cell `(JUSTIFIED . PIXEL)`: the justified string and the width chosen from the range.

**Errors.** `error→ wrong-type-argument` naming `stringp` when STRING is not a string. `error→ user-error` with the message `Line width must be a positive integer, got WIDTH` when either bound is not a positive integer, and with the message `Min-pixel (MIN) must be <= max-pixel (MAX)` when the bounds are reversed.

**Example.**

```elisp
(ekp-pixel-range-justify
 "Pack my box with five dozen liquor jugs. The five boxing wizards jump quickly."
 60 120)
     ⇒ (justified-text . 116)
```

**See also.** `ekp-pixel-justify`, `ekp-layout-plan`.

## The layout plan

The string interface renders its plan, and the buffer interface projects it, but a caller can also ask for the plan itself. A plan is the representation boundary between deciding and displaying: it describes what the paragraph looks like — which source boxes share a line, where the glue goes and how much of it, where a discretionary hyphen is taken — without committing to spaces, newlines, text properties or any other output form. It is the object the package's own renderers consume, and the object a future consumer would use to display the same layout somewhere else.

A plan is either `planned` or `natural`. A planned plan carries the lines; a natural plan carries none and records that the paragraph was left to Emacs's wrapping because of the overlong-token policy. The same policy inputs that steer a string justification steer the plan, so the plan is the complete description of one layout decision at one width.

#### Function: ekp-layout-plan (string line-pixel)

Return a semantic KP layout plan for STRING at LINE-PIXEL.

**Arguments.** STRING is the text of one or more paragraphs, split on newlines like the justifying calls. LINE-PIXEL is the target width in pixels.

**Semantics.** The plan records the paragraph's source offsets, its lines, each line's glue targets, indentation and stripped edges, and whether a line ends with a discretionary hyphen. The layout is complete but has no display representation: nothing in it says that a space is a space character or that a break is a newline. A plan whose paragraph the overlong-token policy leaves natural has no lines and its state is `natural`; otherwise its state is `planned`. Plans are cached per paragraph and layout context and a hit returns a consumer-owned copy, so mutating what you receive cannot affect later plans. Unlike the justifying calls, this function does not validate the width: a width too small to fit a box is accepted and produces one box per line.

**Returns.** A layout plan record. Read it through `ekp-layout-plan-string`, `ekp-layout-plan-lines` and `ekp-layout-plan-state`, then the line readers `ekp-layout-line-*` and the gap readers `ekp-layout-gap-*`.

**Errors.** `error→ wrong-type-argument` naming `buffer-or-string-p` when STRING is neither a string nor a buffer. There is no width validation: any integer is accepted.

**Example.**

```elisp
(ekp-layout-plan "aaaa bbbb cccc dddd eeee ffff gggg" 30)
     ⇒ a plan with two lines, the first ending after "ffff"
```

**See also.** `ekp-pixel-justify`, `ekp-clear-caches`.

#### Function: ekp-layout-plan-string (plan)

Return the cleaned source text PLAN was planned from.

**Semantics.** The plan's source offsets index this string, so a line's source range slices the exact text it renders.

**Returns.** The source string.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-plan PLAN)` for another value.

**See also.** `ekp-layout-plan`, `ekp-layout-line-source-start`.

#### Function: ekp-layout-plan-lines (plan)

Return PLAN's display lines as a vector of line records.

**Semantics.** Each line carries the source range it renders, its leading and trailing pixels, its discretionary hyphen flag and its semantic gaps. A plan whose state is `natural` has an empty vector.

**Returns.** A vector of line records.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-plan PLAN)` for another value.

**See also.** `ekp-layout-plan-state`, `ekp-layout-line-source-start`.

#### Function: ekp-layout-plan-state (plan)

Return PLAN's state: `planned`, or `natural` when the overlong-token policy left it unbroken.

**Semantics.** Read it before the lines: a `natural` plan keeps its string unbroken and has no lines, so a renderer shows the source outside the measure instead of planned breaks.

**Returns.** The state symbol.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-plan PLAN)` for another value.

**See also.** `ekp-layout-plan-lines`.

#### Function: ekp-layout-line-index (line)

Return LINE's zero-based index within its plan.

**Semantics.** Lines are ordered as displayed, so the index is the line number a renderer would show.

**Returns.** The line index as an integer.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-line LINE)` for another value.

**See also.** `ekp-layout-line-source-start`.

#### Function: ekp-layout-line-source-start (line)

Return the source offset where LINE starts.

**Semantics.** Offsets index `ekp-layout-plan-string`; together with `ekp-layout-line-source-end` the range is the exact text the line renders.

**Returns.** The start offset as an integer.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-line LINE)` for another value.

**See also.** `ekp-layout-line-source-end`.

#### Function: ekp-layout-line-source-end (line)

Return the source offset just past LINE's source range.

**Semantics.** The end excludes the break itself, so consecutive lines do not overlap and the text between them is the whitespace or hyphen the break consumed.

**Returns.** The end offset as an integer.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-line LINE)` for another value.

**See also.** `ekp-layout-line-source-start`.

#### Function: ekp-layout-line-leading-pixel (line)

Return the pixel width LINE keeps before its first box.

**Semantics.** The width covers the line's indentation and any stripped edge the layout decided, so a renderer adds it before the line's source text.

**Returns.** The leading width in pixels.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-line LINE)` for another value.

**See also.** `ekp-layout-line-trailing-pixel`.

#### Function: ekp-layout-line-trailing-pixel (line)

Return the trailing pixel width LINE carries after its last box.

**Semantics.** The line's total is leading, content, its gaps and trailing; an unjustified line leaves the slack here.

**Returns.** The trailing width in pixels.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-line LINE)` for another value.

**See also.** `ekp-layout-line-leading-pixel`.

#### Function: ekp-layout-line-hyphen-p (line)

Return non-nil when LINE ends with a discretionary hyphen.

**Semantics.** A hyphenated break inserts a hyphen the source does not contain, so a renderer adds it after the line's source range.

**Returns.** Non-nil for a hyphenated line end, nil otherwise.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-line LINE)` for another value.

**See also.** `ekp-layout-line-source-end`.

#### Function: ekp-layout-line-gaps (line)

Return LINE's semantic gaps as a vector of gap records.

**Semantics.** Each gap sits between two boxes and carries the source range it covers, its natural width and the width the layout chose; a zero-width gap between adjacent boxes is absent. Render the gaps in order between the line's boxes.

**Returns.** A vector of gap records.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-line LINE)` for another value.

**See also.** `ekp-layout-gap-target-pixel`.

#### Function: ekp-layout-gap-natural-pixel (gap)

Return GAP's unstretched natural width in pixels.

**Semantics.** Comparing it with `ekp-layout-gap-target-pixel` shows how far the layout stretched or shrank this gap.

**Returns.** The natural width in pixels.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-gap GAP)` for another value.

**See also.** `ekp-layout-gap-target-pixel`.

#### Function: ekp-layout-gap-target-pixel (gap)

Return GAP's target width in pixels chosen by the layout.

**Semantics.** The target is the width a renderer gives the gap so the line reaches its measure; for an unjustified line it equals the natural width.

**Returns.** The target width in pixels.

**Errors.** error→ `wrong-type-argument` `(ekp-layout-gap GAP)` for another value.

**See also.** `ekp-layout-gap-natural-pixel`.

## Caches

Layout is deterministic but expensive, so results are cached. A paragraph cache keeps the tokenized, measured and indexed form of a paragraph keyed by its characters, its text properties, its fonts, the width context and the layout-relevant options; a per-paragraph dynamic-programming cache keeps the chosen breaks and costs for each width and penalty set; and a plan cache keeps the semantic plans themselves. Measurement of individual glyph runs is cached too. The caches are invisible in the results — clearing them changes speed, never output — which is why one command is enough to handle the one situation that invalidates their measurements: a font, theme or text-scale change that alters glyph widths.

#### Function: ekp-clear-caches ()

Clear all paragraph and measurement caches.

**Arguments.** None.

**Semantics.** It drops the paragraph cache, the policy analysis cache, the most-recent-paragraph fast path and the glyph-width measurement cache. The next layout call rebuilds whatever it needs. Run it after a font or theme change that alters glyph widths, or after text scaling, when the cached measurements no longer describe how the text will be drawn. It is also the tool of choice when a caller wants a layout to be recomputed from scratch for the sake of measurement or diagnosis.

**Returns.** Unspecified; clearing is the effect.

**Errors.** None. The command takes no arguments and the caches accept being empty.

**Example.**

```elisp
(ekp-clear-caches)
     ⇒ the next justification re-measures every glyph
```

**See also.** `ekp-pixel-justify`, `ekp-layout-plan`.

## Errors and recovery

The string interface validates its own arguments before planning. A non-string input raises `wrong-type-argument`; a width that is not a positive integer, or a range whose bounds are reversed, raises `user-error` with the offending value in the message. A rejected call leaves nothing behind: strings are values, and no buffer, cache entry or global state is modified by an argument check.

Errors from planning propagate unchanged. Hyphenation is the layer most likely to raise one, since a configured dictionary that uses replacement patterns is refused rather than degraded, as [Hyphenation](ekp-hyphenation.md) describes. The recovery is the same in every case: fix the argument or the configuration and call again. Caches never need recovery — clearing them is always safe, and a plan or a justified string is reproducible from its inputs.
