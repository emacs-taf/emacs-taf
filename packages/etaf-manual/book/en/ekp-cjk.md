# CJK Typesetting

CJK text differs from Latin text for a line breaker in one basic way: there are no spaces to break at. Any two CJK characters are potential break points, so the interesting work is not finding where a line may break but removing the places where it must not. That is the kinsoku side of the model, and it comes with two companions: what a fullwidth punctuation mark may do at a line edge, where Emacs cannot shrink a glyph, and how a compact number-and-unit token such as `512MB` is kept together.

This chapter describes those three mechanisms as EKP implements them. The break-permission model behind the first one is [Line-Breaking Principles](ekp-principles.md); every option these mechanisms use is a user option collected in the [Parameter Reference](ekp-parameters.md) chapter.

## Kinsoku

<!-- index: kinsoku; line-start prohibition; line-end prohibition; kinsoku profile -->

EKP classifies each character and keeps the classification at the edges of a box, so a closing mark and an opening mark are recognizable wherever they occur. A box whose last character is a closing mark must not start a line; a box whose first character is an opening mark must not end one. The rule covers fullwidth punctuation through those character classes and halfwidth punctuation through two fixed sets: a box made entirely of line-start-forbidden marks (`,` `;` `:` `!` `?` and their relatives) must not start a line, and a box made entirely of line-end-forbidden marks (the opening brackets and quotes) must not end one. The "entirely" matters: a word that merely begins with a period, such as `.emacs`, keeps its freedom to start a line.

Punctuation also hugs its content. There is no glue after an opening mark and no glue before a closing mark, and the gap is rigid, so the prohibition is not a charge the optimizer may pay — the break point does not exist at all. The line simply continues past it.

`ekp-kinsoku-profile` selects the rule set:

| Value | What it forbids |
| --- | --- |
| `common` | Closing marks at line start, opening marks at line end, lone halfwidth punctuation |
| `zh` | The same rules as `common`; the two values are behaviorally identical in the current implementation |
| `ja` | The common rules plus an immutable built-in Japanese addition: small kana, katakana phonetic extensions, the prolonged sound mark and iteration marks |
| `custom` | The common rules plus the characters in `ekp-cjk-no-line-start-extra` and `ekp-cjk-no-line-end-extra` |
| `off` | No kinsoku prohibition: closing marks may start a line and opening marks may end one |

The `custom` profile reads the two extra strings as characters, not as patterns: a box may not start with any character of `ekp-cjk-no-line-start-extra`, and may not end with any character of `ekp-cjk-no-line-end-extra`. Both default to the empty string, so `custom` without extras behaves like `common`. The Japanese addition set is not affected by `ekp-cjk-no-line-start-extra`, and `off` disables only the prohibition — the hugging glue around punctuation is a property of the boxes, not of the profile.

Changing the profile or either extra string changes the paragraph analysis key, so already laid-out paragraphs are re-resolved on their next layout call.

**Example.** For the Japanese sentence `きょうのてんきはとてもいいので、さんぽにいこうとおもいます。`, the `common` profile allows a line to start with the small kana `ょ` and `っ` at narrow widths, while `ja` produces no such line at any of the widths from 8 to 110 pixels. Setting `off` lets a fullwidth `。` start a line at eight or fourteen pixels, and `common` never does. A lone halfwidth `,` after CJK text never starts a line under `common`, but a Latin word beginning with a period may.

## Punctuation squeeze

Classic CJK typesetting compresses punctuation at a line edge by shrinking the punctuation glyph. Emacs cannot shrink a glyph's advance, so EKP cannot render mid-line compression, and it cannot protrude at the left edge either, because text cannot be drawn before the line origin. What remains is right-edge release: a line may end with its last glyph hanging part of the way past the flush edge, so the text before it gains room.

`ekp-protrusion` turns the behavior on, and `ekp-protrusion-ratios` gives each class of line-final glyph the fraction of its width that may hang:

| Class | Line-final glyph | Default ratio |
| --- | --- | --- |
| `cjk-close` | A fullwidth closing mark such as `。`、`」` | 0.5 |
| `latin-close` | A word-final character from the line-start prohibition set, such as a period, a comma or a quote | 0.5 |
| `hyphen` | The soft hyphen inserted at a hyphenated break | 1.0 |

The released amount is the ratio times the glyph's measured width, floored to whole pixels; a ratio of 0.5 on a fullwidth closer hangs exactly the whitespace half of the glyph, which is visually equivalent to line-end compression. The engine counts the released pixels as available width, so a protruding line is valid slightly beyond its plain maximum, and the string interface's reported line width exceeds the target by the released amount. The buffer integration reserves the protrusion width in its layout while the option is on, so the text before it does not collide with the window edge.

The option and its ratios are part of the paragraph key, so toggling protrusion or editing a ratio re-resolves paragraphs; with protrusion off, nothing is released and every line respects the maximum width.

**Example.** For six repetitions of `四字一句。` at 20 pixels, every line measures exactly 20 pixels with protrusion off. With the default ratios, every line measures 21 — the fullwidth `。` hangs one pixel of its two. Raising the `cjk-close` ratio to 1.0 makes them 22, and lowering it to 0 makes them 20 again. For a [hyphenated break](ekp-hyphenation.md) at 40 pixels, the line measures 41 with the default `hyphen` ratio of 1.0 and 40 with protrusion off.

## Numbers and units

A compact number-and-unit token is recognized by shape, not by a list of words. A token qualifies when it begins with a digit, the part before the suffix is an integer or a decimal written with `.` or `,`, and the token ends with an entry of `ekp-number-unit-suffixes`. The default table covers percentages and per-mille, degrees Celsius and Fahrenheit, pixel and font lengths, time units, frequencies, byte units and metric mass and length units. Matching is exact and case-sensitive, so `512MB` qualifies, `512 MB` is two ordinary tokens, and `MB512` is not a unit token. Replacing the table is how an application teaches EKP its own units.

The category feeds `ekp-token-break-policies`, whose default for `number-unit` is `no-break`. The token then becomes an automatic rigid atom: no break or hyphenation inside it, and no internal split — the recognized form is kept whole. An atom wider than the measure follows `ekp-overlong-token-policy`: the default `emergency` downgrades it to `no-hyphen`, `overflow` keeps it rigid, and `natural` leaves the paragraph to the surrounding Emacs wrapping and returns it unchanged. For a compact unit token the downgrade has no legal internal boundary to use, so the token stays whole on one overfull line — the terminal outcome for an unbreakable atom in [Line-Breaking Principles](ekp-principles.md).

**Example.** At 30 pixels, `aa 123456789012345678901234567890MB bb cc dd ee ff` puts the overwide unit token on a 34-pixel line followed by the rest under `emergency` and `overflow`; under `natural` the whole string comes back as one line, unchanged, for the caller to wrap. With the unit not present in `ekp-number-unit-suffixes`, the token is an ordinary Latin-like token and the same overwide rules apply to it.

## Errors and recovery

No text is rejected for being CJK, Japanese or mixed: the mechanisms in this chapter change which break points exist and how much room a line edge has, and every input still produces a complete plan. The failure modes here are malformed option values, because these options are not validated when they are set. An `ekp-number-unit-suffixes` value that is not a sequence makes the next layout signal `wrong-type-argument` naming `sequencep`; a `ekp-protrusion-ratios` value that is not an alist makes it signal `wrong-type-argument` naming `listp`, while a table whose keys are not the expected symbols simply never matches and releases nothing. An unknown `ekp-kinsoku-profile` value falls back to the common rules, and a non-string extra set is ignored. All of these options are inputs to the paragraph analysis key, so fixing the value is the whole recovery: the next layout call uses the corrected value.
