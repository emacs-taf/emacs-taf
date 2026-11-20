# Values

A style declaration gives a property a value, and the value decides how the property behaves: a length occupies space, a color paints, a keyword selects a mode. This chapter defines the value grammars Ebox accepts — lengths with their units and size functions, colors, fonts — and the machinery around them: shorthand expansion and aliases, inheritance and the CSS-wide keywords, custom properties and variable references, `!important`, and the path from a declared value to a computed value with its provenance. The properties themselves are the subject of [Style Properties](style-properties.md), and the cascade that chooses between declarations belongs to [The Style System](style-system.md).

## Lengths

<!-- index: length; size unit; size function -->

A length is written as a two-element list `(UNIT NUMBER)`. Ebox knows six units: `px` and `ch` measure along the horizontal axis, `lh` measures along the vertical axis, `%` is relative to the containing box, and `vw` and `vh` are relative to the viewport. Which units a property accepts depends on the axis the property sizes: horizontal properties such as `:width` and `:left` accept `px`, `ch`, `vw` and `%`; vertical properties such as `:height` and `:top` accept `lh`, `vh` and `%`; border widths accept `px`, `ch`, `lh`, `vw` and `vh` but no percentage. A value that mixes axes — `(px 4)` on a vertical property, `(lh 1)` on a horizontal one — is rejected by the property's validator with the allowed units named in the message.

A length may be computed. The supported expressions are `(calc EXPR)`, `(min ...)`, `(max ...)` and `(clamp MIN PREFERRED MAX)`, and inside them `+` and `-` combine values of one dimension, while `*` and `/` take one scalar operand, so `(calc (+ (px 1) (px 2)))`, `(calc (* 2 (px 3)))`, `(calc (/ (px 6) 2))`, `(min (px 1) (vw 50))` and `(clamp (px 1) (vw 50) (px 9))` are lengths. A bare number is not a length, old pixel shorthands are not lengths, and mixing a number with a length under `+` or `-` is rejected.

Some size properties accept keywords instead of a length: `auto`, `min-content`, `max-content`, `fit-content` and `stretch`, plus `none` where a maximum size is allowed. Those keywords are size values, not lengths.

Lengths stay typed in computed styles: a declaration of `(% 50)` computes to `(% 50)`, and the resolution to pixels happens later against measured context — the containing box for `%`, the viewport for `vw` and `vh`, and the effective font for `ch` and `lh`. [Viewport](viewport.md) defines how those measurements are supplied and when a change reflows. An invalid length signals `ebox-size-error` with the property name and the reason.

## Colors

<!-- index: color; currentColor -->

A color value is a string or the symbol `currentColor`. Ebox does not parse color syntax: any string is accepted and handed to Emacs as a face attribute, so hex strings such as `"#B45309"` and named colors such as `"red"` both work. `currentColor` is a reference to the element's own computed `:color`, and it is the initial value of the border colors and of `:text-decoration-color`.

```elisp :figure Length units and color values: ch, px, a percentage and a calculated length, in named, hex and token colors
(etaf-view
 (column :width '(ch 44) :item-gap '(lh 1)
         (row :item-gap '(ch 1)
              (box :height '(lh 1) :width '(ch 6) :background-color "red")
              (box :height '(lh 1) :width '(px 48) :background-color "#0969da")
              (box :height '(lh 1) :width '(% 25) :background-color (etaf-theme-token :ui-accent "#0969da"))
              (box :height '(lh 1) :width '(calc (* 2 (ch 3))) :background-color "#e5e7eb"))
         (text :color (etaf-theme-token :ui-muted-fg "#526174")
               "宽度依次用 ch、px、% 与 calc。")
         (text :color (etaf-theme-token :ui-muted-fg "#526174")
               "颜色依次用命名色、十六进制与 token。")))
```

## Fonts

<!-- index: font family; font size; font weight; font style -->

Four properties carry the font, and their value grammars are narrower than CSS. `:font-family` is a non-empty string or a symbol, such as `"DejaVu Sans Mono"` or `mono`. `:font-size` is a positive number read as a multiple of the body size, from 0.3 through 4, not a length tuple; Ebox multiplies it into the face height when it paints. `:font-weight` is one of `normal`, `bold`, `bolder`, `lighter` or the hundreds `100` through `900`. `:font-style` is `normal`, `italic` or `oblique`. The first three of these are inherited by default, so a child Host without its own declaration follows its parent's font.

## Shorthands and aliases

<!-- index: shorthand; alias; declaration expansion -->

A *shorthand* is a property whose value stands for several longhands at once; an *alias* is an alternative name for one canonical property. Ebox registers both in its property schema, so every authoring surface accepts the same names and expands them the same way. The shorthands are the four-side and pair forms — `:padding`, `:margin`, `:border` and their side and component variants, `:gap` — and the component forms `:flex`, `:flex-flow`, `:grid-column-span` and `:grid-row-span`. The only aliases are `:bgcolor` for `:background-color` and `:font-slant` for `:font-style`.

The four-side form takes one to four values, assigned in top, right, bottom, left order (one value applies to all four sides, two apply to the first and second and repeat, and so on), or a keyword plist with all four of `:top`, `:right`, `:bottom` and `:left`. The values map onto the logical longhands, so `top` sets `padding-block-start` and `right` sets `padding-inline-end`; because one value can reach both axes, a single value must be valid for both, and in practice that means `%` or a keyword plist with per-side units. `:border` takes a width, a style and a color as one atom or in any order; a lone length means a border of that width in `solid`, a lone style or color fills the missing components with `1px` and `solid`, and `solid` and `none` are the only styles. `:gap` takes one value for row and column or a pair, `:flex` takes a factor or `none`, `auto`, `initial` or a three-element `(GROW SHRINK BASIS)` tuple, and the two grid span shorthands take a positive integer that becomes an automatic `(:span N)` placement.

Expansion and merging are explicit functions so that a host can prepare declarations before the cascade reads them. `ecss-expand-declarations` normalizes aliases, expands each shorthand once, and returns a longhand plist; `ecss-merge-declarations` does the same for several groups and merges them from left to right. Neither resolves tagged values and neither validates concrete values — the schema validator still runs when the style is computed — but both reject an unknown property and a malformed declaration list.

**Example.** One border value expands to a width, a style and a color; the box below draws its border with the declared color.

```elisp :run
(etaf-define-component demo-value-badge ()
  :view (box (text "Draft"))
  :styles (("&" :border "#B45309")))
(etaf-view (demo-value-badge))
```

#### Function: ecss-expand-declarations (schemas declarations)

Validate DECLARATIONS through SCHEMAS and expand each shorthand once.

**Arguments.** SCHEMAS is a composed schema set. DECLARATIONS is an even property/value list whose properties are canonical IDs or aliases.

**Semantics.** Every alias is resolved to its canonical property, every shorthand is expanded exactly once by its schema's expansion function, and explicit nil is kept as a declaration. Importance, CSS-wide and variable tags pass through unchanged; they are resolved by the cascade, not here. The function checks property identity and declaration-list shape, not concrete values: a value the schema's validator would reject is still expanded.

**Returns.** A fresh longhand plist in canonical property IDs.

**Errors.** `error→ ecss-invalid-declaration` with `(:unknown-property NAME)` when a property is not in SCHEMAS, and with `(:declarations VALUE)` when DECLARATIONS is not an even list.

**Example.**

```elisp
(ecss-expand-declarations schemas '(app/padding 1 :fg "red"))
     ⇒ (app/padding-top 1 app/padding-right 1
        app/padding-bottom 1 app/padding-left 1 app/color "red")
```

**See also.** `ecss-merge-declarations` and `ebox-style-canonical-name`.

#### Function: ecss-merge-declarations (schemas &rest declaration-groups)

Expand and merge DECLARATION-GROUPS through SCHEMAS from left to right.

**Arguments.** SCHEMAS is a composed schema set. DECLARATION-GROUPS are even property/value lists in the same shape `ecss-expand-declarations` accepts.

**Semantics.** Each group is expanded as by `ecss-expand-declarations`, then the groups are merged in order: a later longhand replaces the earlier value, and explicit nil is a value like any other, so a group can clear an earlier declaration with nil. The result is a longhand plist; concrete values are not validated.

**Returns.** The merged longhand plist.

**Errors.** As `ecss-expand-declarations`.

**Example.**

```elisp
(ecss-merge-declarations schemas
                         '(app/padding 1 :fg "blue")
                         '(app/padding-left 4 :fg nil))
     ⇒ (app/padding-top 1 app/padding-right 1
        app/padding-bottom 1 app/padding-left 4 app/color nil)
```

**See also.** `ecss-expand-declarations`.

#### Function: ebox-style-canonical-name (name)

Return canonical CSS-like longhand property name for NAME.

**Arguments.** NAME is a keyword or symbol naming an Ebox property: a canonical name or an alias.

**Semantics.** The function looks the name up in Ebox's property schema and returns the property's public canonical name. An alias resolves to the property it names, so `:bgcolor` returns `:background-color`. A name that is not an Ebox property, including a custom property, returns nil.

**Returns.** The canonical property name as a keyword, or nil.

**Example.**

```elisp
(ebox-style-canonical-name :font-slant)
     ⇒ :font-style
```

**See also.** `ecss-expand-declarations`.

## Inheritance and global keywords

<!-- index: inheritance; global keyword; initial; inherit; unset; revert -->

Properties are either inherited or not, and the schema decides which. An inherited property that a declaration does not supply takes its parent's computed value; a non-inherited property takes its schema's initial value. A declaration can override either choice with a CSS-wide keyword, produced by `ecss-wide-value`: `initial` selects the schema's initial value, `inherit` copies the parent's computed value even for a non-inherited property, `unset` selects the inherited value for an inherited property and the initial value otherwise, `revert` removes the winning declaration's whole origin and chooses again from what remains, and `revert-layer` removes only the winning declaration's cascade layer and chooses again.

The wide keywords are tagged values, not ordinary symbols: a declaration whose value is the symbol `inherit` is an ordinary value, while `(ecss-wide-value 'inherit)` is the global keyword. The same is true of `!important` and of variable references, and a host that inspects declaration values before the cascade can ask `ecss-declaration-value-tagged-p` whether a value needs cascade computation and `ecss-declaration-value-valid-p` to run its own value checks without mistaking a tagged value for the underlying data.

#### Function: ecss-wide-value (kind)

Return a tagged CSS-wide value of KIND.

**Arguments.** KIND is `initial`, `inherit`, `unset`, `revert` or `revert-layer`.

**Semantics.** The return value is a tagged value that the cascade resolves per property: `initial` uses the schema's initial value, `inherit` the parent's computed value, and `unset` chooses between them according to the property's inheritance. `revert` removes the winning declaration's entire origin — normal and important declarations alike — and re-selects among the remaining candidates; `revert-layer` removes only the winning declaration's layer inside its origin. When no candidate remains, the property falls back to the inherited or initial value.

**Returns.** The tagged value. It is not equal to the symbol that names KIND, and ordinary data is never scanned for it.

**Errors.** `error→ ecss-invalid-declaration` with `(:wide-value KIND)` when KIND is not one of the five.

**Example.**

```elisp
(ecss-computed-style-value
 (ecss-compute-style schemas subject
                      :parent-style parent
                      :declarations (list 'app/color (ecss-wide-value 'inherit)))
 'app/color)
     ⇒ "red"   ; the parent's computed color
```

**See also.** [The cascade order](style-system.md#the-cascade-order).

#### Function: ecss-declaration-value-valid-p (value predicate)

Check concrete declaration VALUE with PREDICATE before cascade computation.

**Arguments.** VALUE is a declaration value. PREDICATE is a one-argument function that answers whether a concrete value is acceptable.

**Semantics.** An importance tag is transparent: the inner value is passed to PREDICATE. A CSS-wide value or a variable reference is context-dependent, so the function returns true without calling PREDICATE; the resolved value is still checked by the schema validator when the style is computed. Every other value is passed unchanged to PREDICATE, and the function returns its result as a boolean. The function never resolves variables, evaluates value sources or changes VALUE, and an error from PREDICATE propagates to the caller.

**Returns.** A boolean.

**Errors.** Whatever PREDICATE signals.

**Example.**

```elisp
(ecss-declaration-value-valid-p (ecss-important "red") #'stringp)
     ⇒ t   ; PREDICATE receives "red"
```

**See also.** `ecss-declaration-value-tagged-p`.

#### Function: ecss-declaration-value-tagged-p (value)

Return whether VALUE carries ECSS importance, CSS-wide or variable semantics and must be computed before projection.

**Arguments.** VALUE is any declaration value.

**Semantics.** The function inspects only the top-level value: an importance tag, a CSS-wide value or a variable reference is tagged, while ordinary nested data is not scanned. It neither resolves nor mutates VALUE.

**Returns.** A boolean.

**Example.**

```elisp
(list (ecss-declaration-value-tagged-p "red")
      (ecss-declaration-value-tagged-p (ecss-var '--tone)))
     ⇒ (nil t)
```

**See also.** `ecss-declaration-value-valid-p`.

## Custom properties

<!-- index: custom property; variable reference; var -->

A *custom property* is a named value that other declarations can reference. Custom properties have no schema: their names are symbols whose name begins with `--`, and their values are ordinary data that the cascade carries at the computed level. A property declares one as it would any property, and another declaration reads it with a *variable reference* created by `ecss-var`. A reference resolves against the computed custom properties of the same subject, so a custom property can be set on an ancestor and read by a descendant; when the name is missing and no fallback is given, the referencing property falls back to its inherited or initial value. A fallback may itself be a variable reference, and a reference cycle is recorded as a diagnostic while the property falls back to its initial value. Custom properties are visible on a computed style through the custom-property list and accessors defined in [Computed Style](ecss-computed-style.md).

#### Function: ecss-var (name &rest fallback)

Return a custom property reference to NAME with optional FALLBACK.

**Arguments.** NAME is a custom property symbol, a symbol whose name begins with `--`. FALLBACK is zero or one value used when NAME is not defined; it may itself be a variable reference.

**Semantics.** The function returns a tagged reference. When the style is computed, the reference resolves to the named custom property's computed value; when that property is absent, FALLBACK is used if present, and otherwise the referencing property falls back to its inherited or initial value. A cycle among custom properties is reported in the computed style's diagnostics, and the affected property uses its initial value.

**Returns.** The tagged variable reference.

**Errors.** `error→ ecss-invalid-declaration` with `(:custom-property NAME)` when NAME is not a custom property symbol. `error→ wrong-number-of-arguments` when more than one FALLBACK is given.

**Example.**

```elisp
(ecss-computed-style-value
 (ecss-compute-style schemas subject
                      :declarations (list '--tone "teal"
                                          'app/color (ecss-var '--tone)))
 'app/color)
     ⇒ "teal"
```

**See also.** [Computed Style](ecss-computed-style.md).

## Importance

<!-- index: important; importance tag -->

`!important` moves a declaration to the important level of its origin, where it outranks every normal declaration of the same origin and, for the user and UA origins, every important declaration of the origins below. It does not change the value grammar: the value inside the tag is validated and computed like any other value. Importance is produced by `ecss-important`; a host that pre-checks values sees the inner value through `ecss-declaration-value-valid-p`, and expansion and compilation preserve the tag until the cascade consumes it. The order of the importance levels is part of the cascade described in [The Style System](style-system.md#origins).

#### Function: ecss-important (value)

Return VALUE tagged as an important declaration.

**Arguments.** VALUE is any declaration value, plain or already tagged.

**Semantics.** The returned value keeps VALUE and adds importance. The cascade compares the declaration at the important level of its origin instead of the normal one; the value's grammar and validation are unchanged, and the other declaration-value functions treat the tag as transparent.

**Returns.** The tagged value.

**Example.**

```elisp
(ecss-declaration-value-tagged-p (ecss-important "red"))
     ⇒ t
```

**See also.** [Origins](style-system.md#origins).

## Computed values and provenance

<!-- index: computed value; provenance; invalid winner -->

A declared value becomes a computed value in one deterministic path. The cascade first selects one winning declaration per longhand from the inline declarations, the stylesheet rules and the inherited defaults; the winner's value is then resolved — CSS-wide keywords choose between the inherited and initial value, variable references read the custom property set, importance has already decided the winner's rank — and the schema's normalizer and validator produce the canonical computed value that Ebox projects into paint and geometry.

When the winning value is invalid, the cascade does not hand the property to the next candidate. The schema's inherited or initial value is used instead, and the invalid winner is recorded so that the outcome stays deterministic and diagnosable: the property has no computed declaration, yet re-running the cascade can never select a different winner. A style's provenance tells which declaration won and why — its origin, importance, layer, specificity, scope distance, source and declaration order, and whether it validated — and the per-property fact gives the winner with its computed value. [Computed Style](ecss-computed-style.md) defines those queries; [The cascade order](style-system.md#the-cascade-order) defines the comparison that produces the winner.
