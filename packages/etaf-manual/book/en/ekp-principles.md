# Line-Breaking Principles

EKP lays out a paragraph by choosing all of its line breaks at once. It follows the Knuth–Plass model: the paragraph is a sequence of boxes joined by glue, every legal break point carries a penalty, and an arrangement of lines is judged by the sum of its line costs. Because the choice is made for the whole paragraph, a break that fills one line well but forces an ugly next line loses to an arrangement that is even overall; filling lines greedily cannot take an earlier decision back, and the paragraph-wide search can.

This chapter explains that model as EKP implements it. It defines how text becomes boxes and glue, how a single line is scored with badness, fitness and demerits, what looseness changes, and how the two-pass emergency strategy keeps every input layout-able. Its own interfaces are the explicit spacing parameters below; the individual numbers and policies it names are all user options, collected in the [Parameter Reference](ekp-parameters.md) chapter. The string form of the result and the structural plan behind it are the [Programming Interface](ekp-programming-interface.md) chapter.

## Model

<!-- index: box; glue; penalty; badness; demerits; fitness class; looseness; emergency layout -->

A paragraph is a sequence of **boxes**. A box is the smallest unit a line break never splits: a Latin word, a CJK character together with the punctuation that hugs it, or a run of whitespace. Box types and the characters at their edges decide what may separate two boxes and whether a break between them is legal, which is how a closing `。` stays on the line it closes and an opening quote stays with the text it opens.

The space between boxes is **glue**. Glue has no single width: it has an ideal width, an amount it may stretch, and an amount it may shrink, all in pixels. EKP assigns each gap one of three glue classes — the Latin word space between two Latin words, the mixed space between Latin and CJK, and the CJK space used around CJK characters and punctuation — and adds no glue at a rigid join, where a break is impossible or the characters supply their own spacing. The nine pixels that describe the three classes are the model's spacing parameters.

A **penalty** is the cost charged for a break. An ordinary break costs nothing; a break at a [hyphenation](ekp-hyphenation.md) point costs `ekp-hyphen-penalty`. A charge like this lets a legal but slightly stretched line win over a hyphenated one.

A line's **badness** measures how far its glued width misses the target width. Glue at its ideal width gives badness 0; the more the line must stretch or shrink relative to what its glue can do, the larger the badness, up to a cap treated as infinite. The same ratio gives the line a **fitness class** — tight, decent, loose or very loose — and **demerits** combine badness, the break penalty and two consistency charges: a jump of more than one fitness class between neighboring lines, and runs of consecutive hyphenated lines. The formulas are under [Scoring a line](#scoring-a-line).

**Looseness** is a requested offset from the optimal line count. At 0 the paragraph uses the arrangement with the lowest demerits; a positive or negative value asks for more or fewer lines, and EKP picks the line count closest to the request.

Some text has no ordinary arrangement at all: a word can be wider than the measure, and a rigid run can refuse to stretch. The **two-pass emergency strategy** handles both. A strict pass runs first, and only if the paragraph end is unreachable does a second pass add a finite background stretch to underfull candidates and score them through the same badness, fitness and demerits formulas. A final reachability rule keeps an overfull candidate when rejecting it would extinguish the last path to a break point. Every input consequently produces a complete plan.

## Spacing parameters

The nine values behind the three glue classes have their own interface. `ekp-param-set` writes them explicitly, and `ekp-param-reset` returns to deriving them from each paragraph's font.

#### Function: ekp-param-set (lws-i lws-+ lws-- mws-i mws-+ mws-- cws-i cws-+ cws--)

Set all spacing parameters explicitly; persist until `ekp-param-reset`.

**Arguments.** The nine pixel values, in order, are LWS-I LWS-+ LWS-- MWS-I MWS-+ MWS-- CWS-I CWS-+ CWS--: ideal, stretch (+) and shrink (−) for the Latin (LWS), mixed (MWS) and CJK (CWS) word spaces.

**Semantics.** The values replace the automatic per-string defaults for every later layout, in every buffer, until `ekp-param-reset`. Each class keeps its own stretch and shrink allowance; the derived maximum and minimum widths are recomputed, and paragraphs are re-resolved against the new values rather than served from a cache computed with the old ones. Zero is a legal value: a class can be given an ideal width of 0 with no stretch and no shrink, which makes its gaps rigid.

**Returns.** `t`.

**Errors.** `error→ error` with the message "All spacing parameters must be non-nil" when any argument is nil. `error→ wrong-type-argument` naming `number-or-marker-p` when an argument is not a number. A rejected call does not establish explicit parameters: the next layout derives defaults from the paragraph's font again, so the failed values never reach a line.

**Example.**

```elisp
(ekp-param-set 4 8 2 3 6 2 0 4 0)
(length (split-string
         (ekp-pixel-justify "one two three four five six seven eight nine ten" 60)
         "\n"))
     ⇒ 2
(ekp-param-reset)
(length (split-string
         (ekp-pixel-justify "one two three four five six seven eight nine ten" 60)
         "\n"))
     ⇒ 1
```

**See also.** `ekp-param-reset`.

#### Function: ekp-param-reset ()

Clear explicit spacing parameters; defaults are derived per string again.

**Semantics.** All nine values and the record that they were set explicitly are cleared. The next layout of a paragraph derives its spacing from that paragraph's font, exactly as it would in a session where `ekp-param-set` was never called. Paragraphs already laid out keep their lines until the next layout call; nothing is re-flowed by the reset itself.

**Returns.** `nil`.

**Errors.** None. The function takes no arguments, so it cannot reject them.

**Example.**

```elisp
(ekp-param-set 7 3 2 5 2 1 0 2 0)
(ekp-param-reset)
(length (split-string
         (ekp-pixel-justify "one two three four five six seven eight nine ten" 60)
         "\n"))
     ⇒ 1
```

**See also.** `ekp-param-set`.

## Scoring a line

A candidate line spans a run of boxes and has four widths: its ideal width with all glue at the ideal value, its minimum width with all glue shrunk to the limit, its maximum width with all glue stretched to the limit, and the target width of the layout. The line is a valid break point when `minimum ≤ target ≤ maximum`; the last line of the paragraph is also valid when it is underfull, that is when `ideal ≤ target`. Hanging punctuation releases part of the line's final glyph at the right edge, so a line that protrudes may be valid slightly beyond the plain maximum.

The adjustment is `target − ideal`. When it is zero the badness is 0; when the line's flexibility is zero or negative the badness is 10,000, the value treated as infinite; otherwise

```
badness = min(10000, 100 × |adjustment / flexibility|³)
```

where flexibility is the sum of the stretch allowances of the line's gaps for a stretched line, and the sum of their shrink allowances for a shrunk one. The ratio `adjustment / flexibility` also gives the line its fitness class:

| Ratio | Class |
| --- | --- |
| below −0.5 | tight |
| −0.5 to 0.5 | decent |
| 0.5 to 1.0 | loose |
| 1.0 and above | very loose |

The demerits of a line add the consistency charges to the base cost:

```
demerits = (ekp-line-penalty + badness)²
         + ekp-hyphen-penalty²                    ; only at a hyphenated break
         + ekp-adjacent-fitness-penalty           ; when the classes differ by more than one
         + ekp-consecutive-hyphen-penalty × run²  ; only while hyphenated lines continue
```

The `run` in the last charge counts the consecutive hyphenated lines ending at this break, including it, so a second hyphenated line in a row is penalized more than the first and a third more than the second. The adjacent-fitness charge is a flat constant, not a multiplier, and both charges are always added, never negative.

Two kinds of line deviate from the general formula:

- A single-box line — a line that holds one unbreakable box, such as a word with no hyphenation point — has flexibility fixed at 1 in the strict pass, so its badness comes from the raw pixels it misses by. In the emergency pass a positive adjustment is scored against the emergency stretch instead.
- The last line is charged `(ekp-line-penalty + short-badness)²`, where `short-badness` is `ekp-last-line-short-penalty × (1 − fill)` when the fill ratio `ideal / target` is below `ekp-last-line-min-ratio`, and 0 otherwise. The last line is exempt from the fitness charge, takes the decent class, and never pays a hyphen penalty.

## Choosing the breaks

The search runs over break points from left to right. Each reached break point keeps the demerits of the cheapest arrangement that ends there, together with the previous break that produced it; when a new candidate reaches the same point with fewer demerits, it replaces the old one. A position where a break is forbidden — because of [kinsoku rules](ekp-cjk.md#kinsoku), because it lies inside a hard no-break atom, or because a no-break character joins its neighbors — is not a candidate at all, and the search keeps extending the line across it. When the paragraph end is reached, following the recorded predecessors back gives the chosen breaks.

The strict pass accepts only valid break points. If the paragraph end cannot be reached, the emergency pass runs again with the finite background stretch added to the maximum width of underfull candidates; the extra allowance is three times the width of an `M` in the current font by default. The same pass implements the reachability rule for overfull candidates: when rejecting a candidate would leave no path at a break point that has no surviving non-overfull candidate, the best provisional path is installed with the tight fitness class and no added demerits. The rule only fires when an ordinary path is already lost; it never competes with one, and it does not inspect CJK, unit or token classes. This is what guarantees that a complete plan exists for every input, including unbreakable words wider than the measure.

`ekp-looseness` and `ekp-parshape` switch the search to a two-dimensional dynamic program over position and line count. That program first finds the line count with the lowest demerits, then selects the count closest to `ekp-looseness` above or below it, breaking ties by demerits. Both features are computed by the Emacs Lisp engine only: when either is set, the native module is bypassed even if it is loaded and `ekp-use-c-module` is non-nil. The ordinary one-dimensional search exists in both engines and the two produce the same result; the native module exists to compute it faster, not differently.

## Errors and recovery

Nothing in this chapter's model refuses a paragraph. Layout has no failure path: the strict pass, the emergency pass and the reachability rule together guarantee a plan for any sequence of boxes, and the recorded outcome of unbreakable content is an overfull line, not an error. A bad width argument is rejected by the entry point that takes it, as [Programming Interface](ekp-programming-interface.md) documents.

The spacing-parameter interface is the one place here that signals. `ekp-param-set` rejects a nil argument with a plain error and a non-number with `wrong-type-argument`; in both cases the rejected call leaves no explicit parameters behind, so the next layout simply derives the automatic defaults. To recover, call `ekp-param-set` again with nine numbers, or call `ekp-param-reset` to make the automatic defaults the intended state.
