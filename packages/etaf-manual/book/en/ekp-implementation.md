# Implementation

The earlier chapters describe EKP through its model and its interfaces: what a line costs, which breaks are legal, how a plan is rendered. This chapter describes how those decisions are actually computed — the data flow from a string to a finished layout, the caches that make repeated layout cheap, and the invariants that hold at each boundary. It defines no interfaces of its own; it explains the machine that implements the ones defined elsewhere.

## The five stages

<!-- index: layout pipeline; paragraph record; prefix arrays; dynamic programming; glue distribution -->

A justification call moves through five stages. First the paragraph is tokenized into boxes: Latin words, CJK characters, punctuation attached to its neighbors, and whitespace runs. The boxes get their types and the glue class of every gap. Second, Latin word boxes are optionally split at dictionary hyphenation points into syllable boxes. Third, the boxes are measured and indexed: their pixel widths are measured with deduplication, the glue limits are derived from the spacing parameters, and prefix-sum arrays are built so that any candidate line's ideal, minimum and maximum width can be read in constant time. Fourth, the break search runs over those arrays and returns the chosen breaks with the per-line adjustment. Fifth, rendering distributes the adjustment across each line's gaps, strips the edge whitespace, attaches discretionary hyphens, and joins the lines.

The first three stages run once per paragraph per layout context, and their result is cached as a paragraph record. The fourth runs once per (paragraph, width, parameter set). The fifth is deterministic given the fourth's result. That division is the reason a resize sweep is cheap: changing the width reuses the record and reruns only the search.

**Example.** For a paragraph with n boxes, the record holds three prefix arrays of n + 1 elements plus per-box glue arrays; a candidate line spanning boxes i through k reads `ideal[k] − ideal[i]`, `min[k] − min[i]` and `max[k] − max[i]` and subtracts the leading glue and the line-edge space runs. No measurement happens during the search.

## The paragraph record

The paragraph record is keyed by everything that can change how the paragraph is shaped: the characters, their text-property intervals, the detected Latin and CJK fonts, the width context, the hyphenation language, the alignment, and the layout policy and spacing signatures. The key is compared structurally, so hash collisions cannot alias two different paragraphs, and two calls with equal inputs share one record.

The record owns the box vector and the per-box widths, types and glue values; the hyphenation positions and hyphen width; the three prefix arrays; per-class prefix counts for stretched and shrunk gaps; the leading and trailing space-run widths at every position; a snapshot of the effective glue parameters; and the result caches for the dynamic program and the semantic plan. The spacing parameters are part of the record rather than the search key because they are fixed once spacing is chosen, whether it was derived from the font or set explicitly.

Because the key contains the property intervals, editing a paragraph's text or changing its faces misses the record and builds a fresh one; because the font and width context are in the key, a theme or text-scale change does too. This is the mechanism behind the rule that layout results are never served from a stale record; the layout-relevant options are in the keys for the same reason.

## Measuring a line in constant time

The prefixes let the search price a candidate without touching its boxes. The raw ideal width of a line is the difference of the ideal prefixes minus the leading gap's own glue; the renderer strips a whitespace run at each line edge, so the search subtracts the smaller of the raw width and the sum of the two edge runs, exactly as the renderer will. The same computation is done for the minimum and maximum widths, with the glue limits substituted.

A hyphenated break adds the hyphen's width, measured with the style of the word's last character, and a protruding final glyph releases part of its own width at the line edge. Those two corrections are applied before the line's adjustment is computed, so the search and the renderer agree on the number the glue has to absorb. That agreement is what makes every justified line render at exactly the target width: the two sides use one edge-strip rule, and the renderer never re-derives a width the search did not price.

## The break search

The search relaxes positions from left to right. Each reached break point stores the fewest demerits with which it can be reached, the previous break that achieved them, the line adjustment, the gap counts, the fitness class and the number of consecutive hyphenated lines. A candidate break that is forbidden by kinsoku, by a hard no-break atom or by a joiner character is not a candidate at all; the search keeps extending the line across it. When a candidate reaches a break point that already has a record, it replaces it only if its demerits are lower, so the table always holds the best path known so far and the final trace-back through the previous-break links yields the chosen layout.

The demerits of a candidate come from the formulas of [Line-Breaking Principles](ekp-principles.md): the squared line penalty plus badness, the squared hyphen penalty, the flat adjacent-fitness charge, and the quadratic consecutive-hyphen charge. The first pass admits only valid break points. If the paragraph end is unreachable, a second pass adds a bounded emergency stretch to the flexible width of underfull candidates and reuses the same scoring, and a reachability rule installs an overfull candidate with the tight fitness class and no added demerits when rejecting it would leave a break point with no surviving path. Only after the pass that reaches the end are the breaks extracted.

Two features change the shape of the search rather than its scoring. A non-zero `ekp-looseness` and a non-nil `ekp-parshape` make line widths depend on the line number, so the state becomes (position, line count): the search keeps a table of the cheapest paths per line count, finds the optimal count, and then picks the count that best matches the requested offset. That two-dimensional search exists only in the Emacs Lisp engine, which is why those two options bypass the native module. The native module, when it is loaded, runs the same one-dimensional relaxation in compiled code and can process several paragraphs at once on its worker pool, with its result validated against the contract of [The Native Module](ekp-native-module.md).

## Rendering

Rendering turns each line's adjustment into actual glue widths. A line that must stretch distributes the excess in the fixed order Latin, mixed, CJK, so word spaces open before CJK characters do; if the nominal stretch of all gaps is exhausted, the CJK gaps absorb the remainder rather than the line overflowing. A line that must shrink distributes the deficit in the same order and stops at each class's shrink limit, with glue widths floored at zero. A single-box line, which has no glue to absorb anything, gets a trailing filler instead.

The last line of a paragraph is not justified: it keeps its ideal glue and gets a trailing filler, which is what makes it ragged on the right while the measured line still covers the target. The search already scored the last line with its short-line rule rather than its ordinary badness, so the renderer does not need to second-guess it.

The renderer consumes a semantic plan rather than the search internals: source offsets, per-line box ranges, glue targets, indentation and hyphen decisions, with no display representation. The string interface renders that plan with synthesized spacing and line-break characters whose display properties record what they replaced, which is how the buffer interface can invert the operation; the buffer interface instead installs display properties on the existing characters, as [Interactive Use](ekp-interactive-use.md) describes. Cache hits hand out consumer-owned copies, so a renderer may keep or modify a plan without disturbing the cached one.

## Caches and invalidation

EKP keeps three levels of cached state. The paragraph record is the widest: it is keyed as described above and holds everything that does not depend on the width or the penalty settings. The dynamic-program result is keyed by width and by every parameter that changes the score — looseness, the penalties, the emergency stretch — so a parameter change selects a new result without invalidating the paragraph record. The semantic plan is keyed by the layout context and reuses completed prefix lines when a plan is extended. A per-glyph width cache backs the measurements, and a one-entry fast path avoids repeating the structural comparison for the same string object.

The caches are bounded. The paragraph cache flushes entirely when it reaches its size limit, which is cheap because rebuilding is straightforward; the plan cache keeps a small number of recent entries; the width cache has its own bound. None of this is visible in the results, and `ekp-clear-caches` drops all of it for the case the keys cannot express — a font or theme change that alters glyph widths, which the font names in the key may not distinguish.

## The live editing path

The automatic mode adds a second, narrower pipeline for the line being edited. The committed state holds the last projected plan for the paragraph, its signatures and stable break anchors. The first real edit opens a transaction and removes EKP's properties only from the smallest projected span containing the edit; further edits inside that island use native wrapping and no whole-paragraph planning. Crossing a visual row, completing the paragraph, the next real edit elsewhere, an explicit refill and width or context changes are the commit points; there is no idle snap and no post-command hook. A commit computes or reuses one whole-paragraph plan, derives the completed rows, and publishes the changed suffix silently. Stable line signatures minimize writes, and a small buffer-local plan cache serves recent widths. IME preedit, foreign display ownership, unsupported shrink and overlarge hard lines fail closed to native display, and a partial projection is rolled back before the error surfaces.

## What the pipeline guarantees

Three properties hold at the end of any layout call, and the tests of the package exercise them directly. The character stream is untouched: a projection adds and removes text properties only, and saving, searching and copying see the logical text. A justified line renders at exactly the target width whenever the score was computed for a valid break, with the last line, protrusion and the emergency pass as the documented exceptions. And both engines produce the same layout; the Emacs Lisp engine is the reference, and the native module is only a faster way to run the same computation.
