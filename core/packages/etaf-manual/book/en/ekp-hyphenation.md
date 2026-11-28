# Hyphenation

A long word can be broken at more places than its spaces allow, and a language can name those places. EKP performs discretionary hyphenation: it finds the legal break positions inside a Latin word with Liang's pattern algorithm and lets the line breaker choose one, showing a hyphen at the break. The result is a softer paragraph — more candidate layouts, fewer stretched lines — at the cost of a hyphen and the linguistic risk of a bad break, which is why the feature is a policy with an off switch rather than an always-on rule.

This chapter defines the hyphenation interface: the function that resolves a language or a dictionary file into a hyphenator, the conditions it can signal, and the language and dictionary handling behind both. The demerits that a hyphenated break pays are part of [Line-Breaking Principles](ekp-principles.md), the hanging hyphen is part of [CJK Typesetting](ekp-cjk.md), and the options that enable hyphenation and pick the language are user options collected in the [Parameter Reference](ekp-parameters.md) chapter.

## Model

<!-- index: hyphenation; Liang algorithm; dictionary; hyphenator; hyphen margin -->

EKP uses Frank Liang's ordinary pattern algorithm. A dictionary is a set of patterns over words, each pattern carrying priorities for the positions between its letters. To hyphenate a word, EKP pads it with a boundary mark at both ends, looks up every pattern that occurs in it, and keeps the highest priority recorded at each position. A position whose priority is odd is a legal break.

A dictionary's own `LEFTHYPHENMIN` and `RIGHTHYPHENMIN` declarations bound the result: at least that many characters stay before the first break and after the last one. The bundled English dictionaries declare 2 and 3, which is why `hy-phen-ation` is a valid split of `hyphenation` while a break after the first or before the last two characters is not. A dictionary that declares neither keeps the default of two characters on each side.

Hyphenation applies to Latin word boxes only. A word may be wrapped in punctuation — `(word)`, `word!`, a quoted word — and the punctuation stays glued to the first or the last syllable, so the hyphen never lands next to it. A span that a break policy has made hyphen-free, or a rigid no-break atom, is never hyphenated. When a hyphenated break wins, the hyphen's width joins the line and the break pays `ekp-hyphen-penalty`, with the consecutive-run charge described in [Line-Breaking Principles](ekp-principles.md); with right-edge protrusion on, the hyphen itself may hang past the edge.

**Example.** At five or six pixels, `hyphenation` lays out as `hy-`, `phen-` and `ation`, respecting the two-character left and three-character right margins; at seven to ten pixels it takes the single break `hyphen-` / `ation`, and from twelve pixels up it is not hyphenated at all. For a full paragraph, a long German or English word list hyphenates at several breaks at 60 pixels and at one at 80, while turning `ekp-hyphenation` off removes every soft hyphen at the same widths.

## Creating a hyphenator

#### Function: ekp-hyphen-create (&optional lang file left right)

Create hyphenator for LANG or dictionary FILE.

**Arguments.** LANG is a language code such as `"en_US"` or `"de"`. FILE is the path of a dictionary file, used when LANG is nil or cannot be resolved. LEFT and RIGHT override the minimum number of characters kept before and after a break.

**Semantics.** LANG is resolved against the registry of dictionaries scanned from the package's `dictionaries/` directory: the exact key first, then the normalized form (lowercased, `-` written as `_`), then progressively shorter prefixes, so a short code resolves to the first matching dictionary in scan order. A resolvable LANG wins over FILE. A dictionary is compiled once and cached under its path; a later call for the same language returns the same hyphenator, while giving LEFT or RIGHT returns a new hyphenator that shares the compiled patterns and the per-word result cache and overrides only the margins. Without the overrides, the dictionary's `LEFTHYPHENMIN` and `RIGHTHYPHENMIN` apply, or the default of two characters on each side.

**Returns.** A hyphenator for the resolved dictionary.

**Errors.** `error→ ekp-hyphen-dictionary-not-found` when LANG does not resolve and FILE is nil. `error→ ekp-hyphen-unsupported-pattern` when the dictionary uses replacement patterns. `error→ file-missing`, a `file-error`, when FILE names a file that cannot be opened; it is not a hyphen condition.

**Example.**

```elisp
(ekp-hyphen-create "en_US")
     ⇒ a hyphenator for the English (United States) dictionary
(ekp-hyphen-create "en")
     ⇒ a hyphenator for the first matching English dictionary
(ekp-hyphen-create "zz_XX")
     error→ ekp-hyphen-dictionary-not-found
(ekp-hyphen-create "hu_HU")
     error→ ekp-hyphen-unsupported-pattern
```

**See also.** `ekp-hyphen-error`.

## Conditions

The three conditions form one family: a dictionary problem is a hyphenation error, so a single handler covers everything EKP rejects while resolving hyphenation.

#### Error: ekp-hyphen-error

The base condition for hyphenation failures.

**Semantics.** It descends from `error` and has no failure path of its own; the two conditions below descend from it. Its data is whatever the specific condition adds, and its message is "Hyphenation error", which `error-message-string` extends with that data.

**Recovery.** Fix the language or dictionary named by the data and call again. Nothing was modified: hyphenators are values, and a rejected creation leaves no global state beyond the dictionary caches that a later successful call reuses.

**See also.** `ekp-hyphen-dictionary-not-found`, `ekp-hyphen-unsupported-pattern`.

#### Error: ekp-hyphen-dictionary-not-found

Hyphenation dictionary not found.

**Semantics.** `ekp-hyphen-create` signals it when LANG cannot be resolved to any dictionary and no FILE was given. Its data is a one-element list holding LANG, so a handler can report which code failed and suggest the closest available one; the condition message names the language, as in `Hyphenation dictionary not found: "zz_XX"`.

**Recovery.** Check the code's spelling and the language of the dictionary set, use a short code such as `"de"` for the first matching dictionary, or pass an explicit dictionary FILE. The layout engine treats this condition as "hyphenation unavailable" and silently disables hyphenation rather than failing the layout.

**See also.** `ekp-hyphen-create`.

#### Error: ekp-hyphen-unsupported-pattern

Dictionary uses unsupported replacement patterns.

**Semantics.** Liang dictionaries may carry replacement rules that rewrite glyphs when a particular break wins. EKP's line model needs fixed-width boxes and cannot represent that honestly, so it refuses the whole dictionary instead of producing linguistically wrong text and wrong widths. The condition's data is the language or path, the dictionary path and the number of replacement rules found, as in `("hu_HU" "…/hyph_hu_HU.dic" 2396)`. Unlike a missing dictionary, the layout engine lets this condition propagate: a configuration that selects such a dictionary fails loudly instead of silently losing hyphenation.

**Recovery.** Choose a language whose dictionary uses ordinary patterns only, replace the dictionary with a pattern-only one, or turn hyphenation off. The failed dictionary is recorded, so later calls signal again without re-reading it.

**See also.** `ekp-hyphen-create`.

## Language and dictionaries

The language used by the formatter is `ekp-latin-lang`, a code such as `"en_US"` or `"de"`; `ekp-hyphenation` selects the policy, with `auto` (the default) and `on` enabling hyphenation when a dictionary is available, and `off` disabling it without consulting any dictionary. A region that carries the `hyphenate` break policy turns hyphenation on for that region alone. These options are documented in [Parameter Reference](ekp-parameters.md); what belongs here is how a code becomes a dictionary and what happens when it cannot.

The package ships 49 dictionaries under `dictionaries/`, compiled from a pinned revision of the LibreOffice dictionary collection. Each file's upstream path, SHA-256, license evidence and count of replacement patterns are recorded in `dictionaries/MANIFEST.tsv`, and an offline gate verifies the inventory. The directory is scanned when the package loads; if it is absent, loading only warns once and hyphenation stays disabled.

Resolution tries the exact code, its normalized form and then progressively shorter prefixes, so `"de_CH"` can fall back to another German dictionary only when no `de_CH` dictionary is registered, and `"de"` resolves to the first German dictionary in scan order. Resolution is per dictionary path, and the compiled dictionary is cached, so the cost is paid once per language.

Four bundled dictionaries use replacement patterns and are therefore refused: `ca`, `eo`, `hu_HU` and `sq_AL`. `ekp-hyphen-create` signals `ekp-hyphen-unsupported-pattern` for them, and a layout that selects one of them propagates the condition. A code with no dictionary at all, such as `zz_XX`, is a different case: the layout catches the missing-dictionary condition and lays the paragraph out without hyphenation, because a missing dictionary is a normal situation for a language EKP does not ship.

## Errors and recovery

The hyphenation family hangs off `ekp-hyphen-error`, which itself descends from `error`. A handler for the base condition catches both the missing-dictionary and the unsupported-pattern condition; the file error for an unreadable dictionary file is an ordinary `file-error` and stays outside the family.

Recovery is dictionary correction, and it is always local: fix the language code, provide a file, remove or replace the dictionary, or disable the feature. Hyphenators are immutable values with no external ownership, so a rejected creation leaves nothing to roll back — the next successful call for a corrected input succeeds. In layout, distinguish the two failure shapes: a missing dictionary degrades silently, while an unsupported one signals, so a configuration that must not fail should stay with supported languages.
