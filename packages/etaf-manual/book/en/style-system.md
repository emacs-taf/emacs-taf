# The Style System

Every Host gets its appearance and its share of space from one style model. A *declaration* gives a style property a value, a *rule* pairs a selector with declarations, and the cascade chooses one winner per property. The model has one semantics and three authoring spellings — attributes written directly on a Host, static rules in a Component's `:styles`, and rule files — and three layers divide the work: ECSS computes the winner and the final value, Ebox owns the property vocabulary and projects computed values into paint and geometry, and ETAF provides the authoring surfaces and the Theme. This chapter describes that division, the five cascade origins, cascade layers and the complete comparison order. [Selectors](selectors.md) details rule selectors; [Values](values.md) details value semantics, inheritance, custom properties and provenance; [Style Properties](style-properties.md) is the reference for every property; [Component Styles and Themes](component-styles-and-themes.md) covers component rules and Theme; and [Styles Implementation](style-implementation.md) covers the schema and the style pass.

## One semantics, three spellings

<!-- index: declaration; style rule; style attribute; rule file -->

A *declaration* gives a style property a value, such as `:color "#B45309"`. A *rule* pairs a selector with one or more declarations. Whatever spelling a declaration is written in, it enters the same property vocabulary and the same value grammar, and the same selector and cascade semantics decide which declaration wins.

*Inline attributes* are the shortest spelling: style keywords written among a Host's other attributes in the View.

```elisp
(text :color "#B45309" "Draft")
```

ETAF separates style keys from semantic and event properties by asking the Ebox schema whether the property name is a style property, and a style property the chosen Host does not accept is rejected when the View is published. The [Hosts](hosts.md) chapter defines the property domains and how attributes from several sources are combined.

*Component styles* are static rules in the `:styles` clause of a Component definition:

```elisp
(etaf-define-component demo-badge ()
  :view (text "Draft")
  :styles (("&" :color "#B45309")))
```

The rule list is validated when the Component is defined, and its selectors are written relative to the Component's own roots. [Component Styles and Themes](component-styles-and-themes.md) defines the rule format, the `&` selector and the styles replacement interface.

A *rule file* holds one ordered rule list as inert data, with no quote or wrapper:

```
((".badge" :color "#B45309")
 (".badge.active" :color "#334155"))
```

Reading a rule file never evaluates the values. `ecss-file-read` reads a file, and `ecss-read-rules` and `ecss-validate-rules` accept the same list from memory. An `.ebox` file can load a same-basename `.ecss` companion or name one in its expression, and a tool can install a file's rules as a Component's styles with `etaf-component-set-styles`; [Rule Files](ecss-rule-files.md) defines the file contract, and [Component Styles and Themes](component-styles-and-themes.md) defines the replacement interface.

```elisp :figure The same declaration as a Component style rule and as an inline attribute
(etaf-define-component demo-badge ()
  :view (box (text "Draft"))
  :styles (("&" :color "#B45309"
            :background-color "#fef3c7"
            :padding ((lh 0) (ch 1)))))

(etaf-view
 (row :item-gap '(ch 1) :cross-align 'center
   (demo-badge)
   (box :color "#334155" (text "Plain text"))))
```

## Ownership

<!-- index: style ownership; property schema -->

The responsibility for a style fact follows the layering of [Ecosystem and Layers](ecosystem-and-layers.md).

| Layer | Owns in the style model |
| --- | --- |
| `ecss` | Selector matching, the cascade, normalization, computed values and their provenance |
| `ebox` | The property vocabulary, retained computed styles, the style pass, and the projection of values into paint and geometry |
| `etaf` | The authoring spellings, Theme, and the lowering of authored data into Ebox inputs |

ECSS is pure computation. Given a schema set, a subject, declarations and rules, it matches selectors, orders the candidates, resolves the winner, normalizes and validates the value, and returns a computed style; on request it retains the provenance of each winner. It does not know what a value looks like on screen.

Ebox owns the vocabulary an author writes against: the canonical property names and their aliases, each property's initial value, whether it is inherited, its value grammar, which Host kinds accept it, and whether changing it affects painting or geometry. Ebox also owns the computed style it retains per node and decides when that style must be recomputed, so a style that does not change is not recomputed and equal inputs share one style object.

ETAF owns the authoring surfaces. Host attributes and Component `:styles` rules are lowered into Ebox inputs, Theme defaults are lowered into UA-origin declarations, and the same rule-list data is accepted by `:styles`, by `etaf-component-set-styles` and by the file reader. ETAF keeps no second property vocabulary: the names, defaults and validators come from Ebox.

## Origins

<!-- index: cascade origin; importance; ua; user; author; animation; transition -->

ECSS knows five origins: `ua`, `user`, `author`, `animation` and `transition`. Together with importance they form eight levels, compared in this order:

| Level | |
| --- | --- |
| 1 (highest) | transition |
| 2 | UA important |
| 3 | user important |
| 4 | author important |
| 5 | animation |
| 6 | author normal |
| 7 | user normal |
| 8 (lowest) | UA normal |

A higher level wins regardless of selector, layer or order. Importance does not change a value's grammar; it moves the declaration to the important level of its origin. Animation declarations beat every normal declaration but lose to important ones, and a transition declaration beats everything.

The ETAF and Ebox authoring surfaces produce two of the five origins. The Theme is lowered as *UA* declarations: `etaf-theme-provide` provides a property plist to a Component subtree, ETAF resolves the entries the Host accepts, and Ebox applies them as that Host's defaults in the UA origin. This is why a Component's own rule or an inline attribute overrides a Theme default, while an important Theme default can still beat an important author declaration. Inline Host attributes, Component `:styles` rules and the local rules of `.ebox` files are *author* declarations. The *user* origin is available to a host that builds an ECSS stylesheet directly, and an Ebox shared scope can be created with an explicit origin through `ebox-style-scope-create`, but ETAF's own authoring surfaces do not emit user declarations. *Animation* and *transition* are part of the ECSS cascade; nothing in Ebox or ETAF produces them today, because ETAF animations are reactive value updates rather than declarations; the [Animation](animation.md) chapter covers those.

## Cascade layers

<!-- index: cascade layer; declare layers -->

A cascade layer orders rules within one origin. ECSS declares the order with `ecss-stylesheet-declare-layers`, and a rule carries its layer through the `:layer` argument of `ecss-stylesheet-add-rule`. A layer used by a rule before it is declared joins the origin's order at the point of first use, and a later query through `ecss-stylesheet-layers` reports the effective order. Each origin keeps its own order: layers declared for the author origin do not affect user or UA rules.

Within one origin and importance level, the layer step orders candidates as follows. Normal declarations in unlayered rules beat all layered normal declarations, and among layered normal declarations the layer declared later wins. Important declarations reverse both rules: layered important declarations beat unlayered important declarations, and among layers the one declared earlier wins.

The Ebox scopes that back inline declarations, Component styles and local `.ebox` rules add their rules unlayered, and ETAF exposes no layer declaration of its own. Cascade layers therefore matter to a host that builds an ECSS stylesheet directly, such as an application that mixes several stylesheets or a library that embeds Ebox; the [Stylesheets, Scopes and Author Ownership](ecss-stylesheets-and-scopes.md) chapter describes that interface. The `:layer` style property of Ebox, which positions an element in the paint order, is a different feature and belongs to [Positioning, Layers and Overlays](positioning-layers-and-overlays.md).

## The cascade order

<!-- index: cascade order; specificity; scope proximity; source order -->

When several declarations supply the same property, ECSS compares them in one fixed order. The first difference decides:

1. Matching and relevance: the rule's selector must match the subject and the rule's scope must allow it; each matching rule records its scope distance.
2. Origin and importance, in the eight levels above.
3. Cascade layer: ordered as the previous section describes.
4. Specificity: the selector's ID, class and type counts, compared in that order.
5. Scope proximity: the candidate whose scope is nearer to the subject wins.
6. Source order: the rule added later wins.
7. Declaration order: within one rule, the declaration written later wins.

An inline attribute is an author declaration placed above every author rule in the layer step, so it beats each normal author rule however specific that rule is. An important author rule still beats a normal inline attribute, and an important inline attribute beats an important author rule.

A property no declaration supplies takes its inherited value when the schema marks it inherited and the parent has one, and its initial value otherwise. A declaration that wins but produces an invalid computed value does not hand the property to a lower candidate: the schema's inherited or initial fallback is used instead, and the invalid winner is kept in provenance, so re-running the cascade can never change which declaration wins. [Values](values.md) covers inheritance, global keywords, custom properties, `revert` and provenance queries.

**Example.** Both rules below have the same selector and specificity, so only source order decides: the badge is rendered in the second rule's color.

```elisp :run
(etaf-define-component demo-cascade-badge ()
  :view (text "Draft")
  :styles (("&" :color "#334155")
           ("&" :color "#B45309")))
(etaf-view (demo-cascade-badge))
```
