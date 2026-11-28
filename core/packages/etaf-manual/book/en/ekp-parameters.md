# Parameter Reference

Every number and policy that steers EKP is a user option. This chapter is their complete reference: what each option means, its default and allowed values, where it applies, and when a change takes effect. The model chapters explain the mechanisms these options tune — [Line-Breaking Principles](ekp-principles.md) for the score, [CJK Typesetting](ekp-cjk.md) for kinsoku, protrusion and number-unit tokens, [Hyphenation](ekp-hyphenation.md) for dictionaries and language, and [Interactive Use](ekp-interactive-use.md) for the buffer layer.

## How to read the entries

<!-- index: user option; default value; option scope; mode profile; safe-local value -->

An option's description states its purpose, and **Semantics.** gives the default, the accepted values and the effect. Where an option belongs to the buffer layer, the scope says who can set it: a buffer-local value, a mode profile consulted for buffers of that major mode, or the global value. The precedence is fixed: a buffer-local value wins; otherwise the first matching profile entry wins; otherwise the global value is used. Region break policy is stronger than all three, but it is a text property rather than an option, and it is documented as `ekp-break-policy`.

A mode profile is an entry of `ekp-buffer-mode-policy-alist`, an alist of major mode to a plist of options. `ekp-token-break-policies` is merged by token category rather than replaced: the effective alist starts from the global value, then the profile's categories are merged in, then any buffer-local categories. This is what lets a profile change the treatment of URLs while keeping the number-unit rule.

Most options take effect at the next layout or reflow rather than immediately: the paragraph cache key, the dynamic-programming signature and the plan context include every option that affects their result, so a new value is never served from an old cache entry. The buffer options are read when a projection is planned, so a justify call or an automatic reflow picks them up; the options that govern the automatic mode's timing are read when the relevant event arrives.

Values are checked when they are used, not when they are set. Options with a closed set of allowed values fall back to sensible behavior for an unknown value, while options whose shape is structural signal a type error from the layout call that reads them; each entry states which. Values with a `safe-local` predicate are accepted from a file- or directory-local variable list; the predicate mirrors the allowed values.

## Break and score parameters

The options in this group shape the line-breaking objective itself. They are read directly from their global or dynamically bound values; they are not part of the buffer policy context.

#### Variable: ekp-alignment

Paragraph alignment mode.

**Semantics.** `justify` (the default) flushes both edges. `ragged-right`, `ragged-left` and `center` keep inter-word glue rigid and use the line's end-of-line flexibility to balance the three shapes, so the search still minimizes raggedness while lines need not be stretched to the measure. With any non-justify mode the maximum and minimum line widths lose their glue stretch and shrink, and the end-of-line allowance comes from `ekp-ragged-stretch-pixel`.

**See also.** `ekp-ragged-stretch-pixel`, `ekp-line-penalty`.

#### Variable: ekp-first-line-indent

First-line indentation: pixels, or t for 2 em of the paragraph font.

**Semantics.** The default is nil: no indentation. An integer shifts line zero by that many pixels and reduces its width by the same amount; `t` uses two em of the paragraph's CJK font. The indent runs on the fast path and in the native engine. It is ignored when `ekp-parshape` is set, because a full shape already decides the first line.

**Example.** With `t`, the paragraph `aaaa bbbb cccc dddd eeee ffff gggg hhhh` at 30 pixels breaks after `eeee` instead of after `ffff`, because line zero starts four pixels in.

**See also.** `ekp-parshape`.

#### Variable: ekp-parshape

Per-line layout, as a sequence of `(INDENT . WIDTH)` cons cells.

**Semantics.** The default is nil: every line uses the measure. A list of cons cells shapes the paragraph: line i uses element i, INDENT is the left offset in pixels and WIDTH the text width, so the line occupies INDENT + WIDTH; lines beyond the last element reuse it, like a TeX paragraph shape. Line-number-dependent widths need the position-by-line-count search, so while this option is set the native module is bypassed and only the Emacs Lisp engine is used. It takes precedence over `ekp-first-line-indent`.

**Example.** Under `((0 . 20) (6 . 24) (0 . 30))` at a 30-pixel measure, line zero is 20 pixels wide, line one occupies 6 + 24, and later lines are 30 wide.

**See also.** `ekp-first-line-indent`, `ekp-looseness`.

#### Variable: ekp-line-penalty

Penalty for each line break. Higher = fewer lines. Default 10.

**Semantics.** The value enters demerits as the constant added to a line's badness before squaring, so a higher penalty makes extra lines expensive and the search prefers a tighter paragraph. It is a plain number and may be zero.

**See also.** `ekp-hyphen-penalty`, `ekp-last-line-short-penalty`.

#### Variable: ekp-hyphen-penalty

Penalty for hyphenated breaks. Higher = avoid hyphenation. Default 50.

**Semantics.** The value is added to demerits as its square, following the Knuth-Plass penalty formula, so a hyphen break is attractive only when the geometry saves more than that. It has no effect when hyphenation is off or no dictionary is available.

**See also.** `ekp-hyphenation`, `ekp-consecutive-hyphen-penalty`.

#### Variable: ekp-adjacent-fitness-penalty

Penalty when adjacent lines differ in tightness by more than one class.

**Semantics.** Each line gets a fitness class from how far its glue had to stretch or shrink; a jump of two or more classes between neighboring lines adds this flat constant to the demerits. The default 100 makes a paragraph avoid alternating very tight and very loose lines even when that is locally cheaper.

**See also.** `ekp-line-penalty`.

#### Variable: ekp-consecutive-hyphen-penalty

Base penalty multiplier for consecutive hyphenated lines.

**Semantics.** A hyphenated break adds the base penalty times the square of the run length — the number of consecutive hyphenated lines ending at this break. The default 100 makes a run of two hyphens four times as expensive as one and a run of three nine times, which spreads hyphens out.

**See also.** `ekp-hyphen-penalty`.

#### Variable: ekp-last-line-min-ratio

Minimum fill ratio for last line (0.0-1.0).

**Semantics.** The default 0.5 sets the fill ratio below which the last line is considered too short. The ratio is the last line's ideal width over its target width; a line at or above the threshold pays nothing extra, and one below it is charged through `ekp-last-line-short-penalty`.

**See also.** `ekp-last-line-short-penalty`.

#### Variable: ekp-last-line-short-penalty

Penalty multiplier for underfilled last lines.

**Semantics.** When the last line's fill ratio is below `ekp-last-line-min-ratio`, its short-badness is this value times one minus the fill ratio, and the last line pays `(ekp-line-penalty + short-badness)²` instead of its ordinary badness. The default 50 makes a nearly empty last line expensive without forbidding it.

**See also.** `ekp-last-line-min-ratio`.

#### Variable: ekp-looseness

Target line count offset: 0=optimal, +1=looser (more lines), -1=tighter.

**Semantics.** The default 0 selects the arrangement with the lowest demerits. A non-zero value switches to the position-by-line-count search: EKP finds the line count with the lowest demerits, then selects the count closest to that plus this offset, breaking ties by demerits. The option is an integer and is clamped by the line counts that are actually reachable. Non-zero values also bypass the native module, because only the Emacs Lisp engine implements the two-dimensional search.

**Example.** At 12 pixels, `aaa bbb ccc ddd eee fff ggg hhh iii jjj` lays out in three lines at 0 and four lines at +1; there is no reachable two-line arrangement, so -1 stays at three.

**See also.** `ekp-parshape`, `ekp-line-penalty`.

#### Variable: ekp-ragged-stretch-pixel

Per-line end-of-line flexibility (pixels) for non-justify alignment.

**Semantics.** The default nil derives eight times the Latin word-space ideal, about two em. The value is the room a ragged line may fall short of the measure without reaching infinite badness; it is read only when `ekp-alignment` is not `justify`.

**See also.** `ekp-alignment`.

#### Variable: ekp-default-cws-stretch-pixel

Max stretched pixel of whitespace between CJK chars.

**Semantics.** The default 2 is the stretch allowance of the CJK glue in the automatic spacing derivation. It only matters while spacing is automatic: after `ekp-param-set` the CJK class has its explicit values. It is the one automatic spacing value that is a user option rather than a font measurement.

**See also.** `ekp-param-set`, `ekp-param-reset`.

## CJK and token policy

#### Variable: ekp-kinsoku-profile

Kinsoku profile used when compiling paragraph break permissions.

**Semantics.** The default `common` forbids closing marks at line start, opening marks at line end and lone halfwidth punctuation, as [CJK Typesetting](ekp-cjk.md) describes. `zh` currently behaves exactly like `common`. `ja` adds the immutable Japanese set of small kana, phonetic extensions, the prolonged sound mark and iteration marks. `custom` adds the characters listed in the two extra options. `off` disables the prohibitions. An unknown value behaves like the common rules. The profile is part of the paragraph analysis key, so changing it re-resolves paragraphs.

**See also.** `ekp-cjk-no-line-start-extra`, `ekp-cjk-no-line-end-extra`.

#### Variable: ekp-cjk-no-line-start-extra

Custom/Japanese CJK letters that must not start a line.

**Semantics.** The default is the empty string. The value is read as characters, not as a pattern: under the `custom` profile, a box may not start with any character in the string. The `ja` profile uses its immutable built-in set instead, and the common profiles ignore this option entirely.

**See also.** `ekp-kinsoku-profile`.

#### Variable: ekp-cjk-no-line-end-extra

Custom CJK characters that must not end a line.

**Semantics.** The default is the empty string. Under the `custom` profile, a box may not end with any character in the string. It is ignored by every other profile.

**See also.** `ekp-kinsoku-profile`.

#### Variable: ekp-protrusion

Non-nil enables right-edge character protrusion (hanging punctuation).

**Semantics.** The default nil keeps every line inside the measure. When set, a line's final glyph may hang past the flush edge by the fraction `ekp-protrusion-ratios` gives for its class: fullwidth closers, word-final halfwidth closers, and the discretionary hyphen. The released pixels count as available width, so the text before the punctuation gains room; the buffer integration reserves the protrusion width in its layout. Toggling the option changes the paragraph key, so the next layout re-resolves.

**See also.** `ekp-protrusion-ratios`.

#### Variable: ekp-protrusion-ratios

Alist CLASS → RATIO of the glyph width allowed to protrude.

**Semantics.** The default is `((cjk-close . 0.5) (latin-close . 0.5) (hyphen . 1.0))`. `cjk-close` covers fullwidth closers such as `。` and `」`, where 0.5 hangs exactly the whitespace half of the glyph; `latin-close` covers word-final characters from the line-start prohibition set; `hyphen` covers the soft hyphen inserted at a break. The released amount is the ratio times the glyph's width, floored. The alist may be partial: a class without an entry releases nothing.

**See also.** `ekp-protrusion`.

#### Variable: ekp-number-unit-suffixes

Exact suffixes recognized by the compact number-unit classifier.

**Semantics.** The default table covers percentages, degrees, pixel and font lengths, time units, frequencies, byte units and common metric units. A token qualifies as a number-unit token when it starts with a digit, the part before the suffix is an integer or a `.`/`,` decimal, and it ends with one of these strings; matching is exact and case-sensitive. The token then follows the policy `ekp-token-break-policies` gives the category, whose default keeps it rigid.

**See also.** `ekp-token-break-policies`, `ekp-overlong-token-policy`.

#### Variable: ekp-break-policy

Text property controlling regional break policy.

**Semantics.** This entry is a convention rather than a global setting: the property is attached to a stretch of text, and the layout honors the value on the property over the automatic token and face policies. `normal` clears both kinds of automatic restriction; `hyphenate` turns discretionary hyphenation on for the span even when the global policy is off; `no-hyphen` suppresses discretionary hyphenation while keeping ordinary legal breaks. It never makes an atom rigid; that is the separate no-break property described under `ekp-no-break-region`.

**Example.** With global hyphenation off, `internationalization` wrapped in the `hyphenate` policy still hyphenates; with global hyphenation on, the `no-hyphen` policy removes its hyphens.

**See also.** `ekp-inline-code-policy`, `ekp-hyphenation`, `ekp-no-break-region`.

#### Variable: ekp-inline-code-policy

Default break policy for automatic inline code spans.

**Semantics.** The default `no-hyphen` keeps the source spacing of a span wearing a face from `ekp-buffer-inline-faces` literal and suppresses dictionary hyphenation while still allowing ordinary breaks. `normal` treats the span as prose. `no-break` makes a fitting span rigid; a span wider than the measure is downgraded to `no-hyphen` rather than overflowing. The option has no effect on explicit no-break regions.

**See also.** `ekp-buffer-inline-faces`, `ekp-break-policy`.

#### Variable: ekp-token-break-policies

Break policies for bounded automatic token classifiers.

**Semantics.** The default is `((url . no-hyphen) (path . no-hyphen) (identifier . no-hyphen) (number-unit . no-break))`. Each entry maps a token category to one of the three break policies. The classifier recognizes URL, file-path, identifier-shaped and compact number-unit tokens in ordinary text; only the number-unit category is rigid by default. Entries are merged by category, not replaced: a profile or a buffer-local value changes the categories it names and leaves the rest.

**See also.** `ekp-number-unit-suffixes`, `ekp-inline-code-policy`.

#### Variable: ekp-overlong-token-policy

Policy for ordinary non-CJK tokens wider than the measure.

**Semantics.** The default `emergency` lets the emergency pass place an overwide token, downgrading an overwide automatic no-break span to `no-hyphen` so that it stays whole on an overfull line. `overflow` keeps such a span rigid. `natural` leaves any paragraph containing an overwide ordinary Latin-like token to Emacs's wrapping and returns the paragraph unchanged instead of planning it. The option does not apply to CJK text or to explicit no-break regions.

**See also.** `ekp-token-break-policies`, `ekp-no-break-region`.

## Hyphenation and language

#### Variable: ekp-hyphenation

Global discretionary hyphenation policy.

**Semantics.** The default `auto` and the value `on` both use the configured dictionary when one is available; a missing dictionary disables hyphenation without signaling. `off` disables discretionary hyphenation. A region carrying the `hyphenate` break policy still hyphenates under `off`. Changing the value changes the paragraph analysis key, so the next layout re-resolves.

**See also.** `ekp-latin-lang`, `ekp-hyphen-penalty`, `ekp-break-policy`.

#### Variable: ekp-latin-lang

Language code for hyphenation (e.g., "en_US", "de_DE").

**Semantics.** The default is `"en_US"`. The code is resolved against the bundled dictionaries by exact key, normalized form and progressively shorter prefixes, so a short code such as `"de"` selects the first matching dictionary in scan order, as [Hyphenation](ekp-hyphenation.md) describes. The value is part of the paragraph cache key, so changing it re-resolves paragraphs; a code with no dictionary simply disables hyphenation, while a dictionary that uses replacement patterns signals `ekp-hyphen-unsupported-pattern` from the layout.

**See also.** `ekp-hyphenation`.

## Buffer layout

These options belong to the buffer layer documented in [Interactive Use](ekp-interactive-use.md). They can be set globally, in a mode profile, or buffer-locally, with the precedence this chapter's introduction describes.

#### Variable: ekp-buffer-measure

Measure used for automatic and default manual buffer layout.

**Semantics.** The default `narrowest-window` plans at the narrowest live window showing the buffer. A positive integer is a fixed width in pixels, independent of the window; a cons `(max . N)` caps the narrowest window at N pixels. The value is read whenever a projection is planned, and the automatic mode follows it on window changes. A value that is none of the three signals an error from the layout call.

**See also.** `ekp-buffer-margin-pixel`.

#### Variable: ekp-buffer-margin-pixel

Pixels reserved inside the window body width.

**Semantics.** The default 2 is subtracted from the window body width before the measure is computed, leaving a rounding safety margin so that a line that measures exactly the window width does not wrap in the display engine. It applies to window-derived measures, not to a fixed `ekp-buffer-measure`.

**See also.** `ekp-buffer-measure`.

#### Variable: ekp-buffer-skip-faces

Faces whose paragraphs stay verbatim.

**Semantics.** The default is nil, the empty list. A paragraph that intersects any of these faces is left under the buffer's natural wrapping instead of being projected. The automatic mode reads the mode profile, which supplies block faces for Org and Markdown; `ekp-org-setup` and `ekp-markdown-setup` copy those lists into the buffer for manual justification.

**See also.** `ekp-buffer-inline-faces`, `ekp-org-setup`.

#### Variable: ekp-buffer-inline-faces

Faces whose exact spans use `ekp-inline-code-policy`.

**Semantics.** The default is nil. A span wearing one of these faces is laid out under the inline-code policy, so its spacing and hyphenation follow the policy rather than the paragraph's. The face span is the unit; a paragraph containing such a span is still projected.

**See also.** `ekp-inline-code-policy`, `ekp-buffer-skip-faces`.

#### Variable: ekp-buffer-skip-predicate

Function called with a paragraph string that should stay verbatim.

**Semantics.** The default is nil. This is a buffer-local variable: when it holds a function, that function is called with each hard paragraph's text, and a non-nil result keeps the paragraph verbatim. It is the general escape hatch for document syntax that has no recognizable face, and it is consulted together with the skip faces and the other protection rules.

**Example.** A buffer-local predicate returning non-nil for paragraphs matching `"SKIP"` keeps exactly those paragraphs natural while the rest of the buffer is projected.

**See also.** `ekp-buffer-skip-faces`.

#### Variable: ekp-buffer-mode-policy-alist

Mode profiles consulted by automatic and manual buffer layout.

**Semantics.** The default carries an Org and a Markdown profile, giving each its block and inline faces. Entries are matched in order with `derived-mode-p`, and the first match supplies the options it names. The values are the buffer policy options themselves, so a profile can set the measure, hyphenation, kinsoku, overlong-token behavior, faces and token policies for every buffer of a mode without touching the globals.

**See also.** `ekp-buffer-measure`, `ekp-token-break-policies`.

## Automatic reflow

These options tune `ekp-auto-justify-mode`. They are read when the mode enables or when the corresponding event arrives.

#### Variable: ekp-auto-justify-lazy-threshold

Buffer size beyond which whole-buffer reflows run visible-first.

**Semantics.** The default is 20 000 characters. The mode itself projects paragraphs as they complete, but an explicit reflow of a large buffer is split: the part on screen is projected synchronously and the rest is processed in background chunks under the tick budget. Buffers at or below the threshold are reflowed in one pass.

**See also.** `ekp-auto-justify-tick-budget`, `ekp-auto-justify-mode`.

#### Variable: ekp-auto-justify-paragraph-limit

Maximum hard-paragraph characters planned automatically.

**Semantics.** The default is 2 048 characters. A longer paragraph stays under natural wrapping while editing, so enabling the mode, pasting or ordinary typing cannot start an unbounded planning pass; the diagnostic reports that the limit was the reason. `ekp-refill-paragraph` is not limited by this value and performs the full-quality pass for the paragraph on request.

**See also.** `ekp-refill-paragraph`, `ekp-diagnose`.

#### Variable: ekp-auto-justify-resize-delay

Seconds to debounce window resize reflows.

**Semantics.** The default is 0.15 seconds. A resize restarts the wait; when it passes without further size changes, the buffer is reflowed once at the new width, so a window drag does not run one reflow per intermediate size.

**See also.** `ekp-buffer-measure`.

#### Variable: ekp-auto-justify-tick-budget

Seconds of work allowed in one lazy reflow tick.

**Semantics.** The default is 0.005 seconds. It bounds each background chunk of a large-buffer reflow, keeping idle time responsive while the rest of the buffer catches up; whatever is visible is prioritized over the remaining chunks.

**See also.** `ekp-auto-justify-lazy-threshold`.

#### Variable: ekp-auto-justify-native-append

Use the loaded native module for automatic live append DP.

**Semantics.** The default t. It applies only to the already-prepared live append path: ordinary string layout and full buffer layout still follow `ekp-use-c-module`, and when the native module is unavailable the live path falls back to Emacs Lisp. Setting it to nil forces the live append path to Lisp while leaving every other use of the module alone.

**See also.** `ekp-use-c-module`, `ekp-auto-justify-mode`.

## Caches and the native engine

#### Variable: ekp-para-cache-limit

Maximum number of cached paragraphs.

**Semantics.** The default is 256. When the paragraph cache reaches this many entries, the whole cache is flushed before the new paragraph is added; rebuilding is cheap, and this keeps a long editing session bounded. The limit does not affect results.

**See also.** `ekp-clear-caches`.

#### Variable: ekp-use-c-module

When non-nil, use C dynamic module for DP computation if available.

**Semantics.** The default t lets the native module compute line breaks when it is loaded, including the parallel batch path for multiple paragraphs. nil forces the Emacs Lisp engine. The option cannot switch to a module that is not loaded, and two features bypass it regardless: a non-zero `ekp-looseness` and a non-nil `ekp-parshape` need the Emacs Lisp search. Both engines produce the same layout.

**See also.** `ekp-auto-justify-native-append`, `ekp-c-module-load`, `ekp-looseness`, `ekp-parshape`.

## Errors and recovery

Options are checked when they are read, not when they are set. A value with a closed set of choices falls back to documented behavior when it is unknown: an unrecognized kinsoku profile follows the common rules, non-string CJK extra sets are ignored, and a protrusion table without the needed key releases nothing. A structurally wrong value surfaces as an error from the layout call that reads it: a non-sequence number-unit suffix table signals `wrong-type-argument` naming `sequencep`, a protrusion table that is not even an alist names `listp`, and a buffer measure that is none of its three forms fails when a projection is planned.

Recovery never requires editing text: correct the option and re-run the layout. Because the caches key on the options that affect their result, the corrected value is used on the next call; `ekp-clear-caches` is available when a caller wants to be certain that nothing measured earlier is reused, but it is never required. The buffer-layer options can be fixed globally, in the mode profile or buffer-locally, and the most specific value wins.
