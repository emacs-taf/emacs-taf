# Styles Implementation

<!-- index: Ebox schema; properties word list; style pass -->

Ebox owns the style property vocabulary and turns declarations into paint and geometry. This chapter describes the mechanisms behind the property reference of [Style Properties](style-properties.md): the shape of a schema definition and the two lookups over it, compilation with its caches, the computed style record and how equal styles are shared, the style pass that propagates dirty state, the viewport unit dependency table, and the steps for adding a property. The cascade that selects declarations is [The Style System](style-system.md); the functions here are Ebox library interfaces, so their behavior is described through concepts and the public entries only.

## The schema definition

<!-- index: schema field; contexts; dirty kind; validator; normalizer; aliases -->

A style property is registered as immutable data. Each definition states the canonical name and its namespaced ECSS id, its aliases, its initial value, whether it inherits, the author tags that accept it, its group, the dirty kind that a change produces, the signature that tells paint and layout apart, and its normalizer and validator. A shorthand adds an expander; a length-typed property adds a size domain. The change impact and the projection owner are derived from the group and the name when they are not stated explicitly.

The registration creates one ECSS schema package, and the same data is indexed for fast lookup by canonical name, id and alias. That index answers the two questions other layers ask: what ECSS id carries this property, and which author forms accept it. Property facts are validated when a declaration is compiled, and the axis domain of a length is validated with the value, so an invalid unit is reported at the declaration that named the property.

#### Function: ebox-style-schema-id (name)

Return the namespaced ECSS schema id of Ebox property NAME, or nil.

**Arguments.** NAME is a canonical property name such as `:color` or an alias such as `:bgcolor`.

**Semantics.** The lookup covers canonical names, aliases and the ids themselves. The id is the name the cascade and the ECSS stylesheets carry; returning nil means NAME is outside the Ebox style vocabulary, which is how ETAF separates style properties from semantic and event properties.

**Returns.** The namespaced id, or nil.

#### Function: ebox-style-property-accepted-p (tag name)

Return non-nil when author form TAG accepts property NAME.

**Arguments.** TAG is an author form tag — `text`, `box`, `row`, `column`, `flex` or `grid`. NAME is a canonical property name or an alias.

**Semantics.** The decision follows the property's contexts. A property with an explicit author-contexts list is accepted only on those tags. Otherwise the tag must appear in the contexts, or, for every non-`text` tag, the contexts must include `box` or `item`; that is why a `(text box)` property is accepted on boxes, rows, columns, flex and grid, while a `(row column)` property is not. Unknown names are never accepted.

**Returns.** Non-nil when TAG accepts NAME, nil otherwise.

#### Error: ebox-style-schema-error

The condition for an invalid Ebox style schema.

**Semantics.** The condition belongs to the package's public error vocabulary so that a host extending the schema has a stable condition to check. The property schema itself is fixed registration data, and the current public interfaces validate declarations against it rather than signaling this condition; no public path raises it today.

## Compilation and caches

<!-- index: declaration compilation; strict mode; declaration cache; shorthand expansion; shared scope -->

Compiling turns author data into canonical ECSS declarations. The pipeline checks the shape of the declaration list, expands aliases and shorthands exactly once, validates each value against its schema, and returns canonical longhands keyed by namespaced ids. Compilation is pure with respect to its inputs and is memoized with a bounded cache, so repeated declarations — a Component's static rules, the Theme defaults of a subtree — are expanded and validated once.

Rules and scopes build on the same pipeline. A rule compiles its selector into an ECSS selector AST and its declarations in strict mode, and a scope compiles an ordered rule list into an immutable stylesheet. Equal rule lists at the same origin share one compiled stylesheet, and a scope can be given new rules while keeping its membership identity, which is how a Theme change re-lowers a Component's rules without rebinding its nodes.

#### Function: ebox-style-compile-declarations (plist &optional strict)

Compile Ebox PLIST aliases to ECSS schema declarations.

**Arguments.** PLIST is an even-length property list of property names and inert values. STRICT, when non-nil, rejects property names outside the Ebox style domain.

**Semantics.** The list must be a proper even-length plist, and two entries that resolve to the same canonical property — including through aliases — are rejected. Aliases are canonicalized and shorthands are expanded exactly once to canonical longhands; values keep their data shape, including `!important` and CSS-wide tags and custom properties. Each value is validated against its property's grammar and unit domain: a malformed length in a length-typed property reports the property's allowed units, a value outside a keyword grammar reports the property and value, and a physical edge that would be targeted twice by both its physical and logical properties is reported as a duplicate edge target. In strict mode an unknown property is rejected instead of being carried as an opaque non-style entry. Results are cached in a bounded table keyed by the style-only content of PLIST and STRICT, and the returned plist is a fresh spine; the input is not modified.

**Returns.** The canonical declaration plist.

**Errors.** `error→ user-error` when PLIST is not an even-length list, and, in strict mode, when a property is outside the Ebox style domain; `error→ error` for a duplicate canonical property or a value outside its grammar; `error→ ebox-size-error` for a length with a forbidden unit or axis, with the allowed units in the data; `error→ ecss-invalid-declaration` with `(:duplicate-edge-target …)` when the same physical edge is targeted twice.

**Example.**

```elisp
(ebox-style-compile-declarations '(:bgcolor "red" :padding ((lh 1) (px 2))))
     ⇒ (ebox/background-color "red" ebox/padding-block-start (lh 1)
        ebox/padding-inline-end (px 2) ebox/padding-block-end (lh 1)
        ebox/padding-inline-start (px 2))
```

#### Function: ebox-style-compile-form (tag plist)

Compile evaluated author PLIST once and validate it for TAG.

**Arguments.** TAG is the author form tag the declarations are written on. PLIST is the evaluated property list of that form.

**Semantics.** The pipeline adds the author-form rules on top of `ebox-style-compile-declarations`: nil is a value only for properties whose grammar is boolean or an optional anchor, so an explicit nil on a color or length is rejected; every declaration must already be a canonical property id after expansion; TAG must be one of the six author form tags; and the tag must accept each property through its contexts. The result is cached like the declaration compilation it wraps.

**Returns.** The canonical declarations accepted by TAG.

**Errors.** `error→ error` for a nil author value outside the boolean and anchor grammars, an unknown author form tag, a non-canonical declaration, a duplicate canonical declaration, or a property the tag does not accept.

#### Function: ebox-style-compile-rules (rules)

Compile ordered (SELECTOR PROPERTY VALUE ...) RULES through ECSS syntax and the strict Ebox property schema.

**Arguments.** RULES is an ordered list of rules; each rule is a selector and a declaration list.

**Semantics.** Every rule's shape is validated by the ECSS rule contract and its selector is parsed into an AST; the declarations are compiled in strict mode, so an unknown property or invalid value rejects the whole list. Values stay inert: no declaration is evaluated and no stylesheet or scope is built. The result is suitable for the rule fields of a scope or a stylesheet.

**Returns.** A list of `(SELECTOR-AST . DECLARATIONS)` pairs.

**Errors.** The ECSS conditions for a malformed rule or selector, and the declaration errors of `ebox-style-compile-declarations` in strict mode.

**See also.** `ebox-style-scope-create`, `ebox-style-scope-with-rules`.

#### Function: ebox-style-scope-create (rules &key (origin 'author))

Create an immutable shared scope from ordered RULES at ORIGIN.

**Arguments.** RULES is an ordered rule list as accepted by `ebox-style-compile-rules`. ORIGIN is the cascade origin the rules enter, `author` by default.

**Semantics.** The rules are compiled once into an immutable shared stylesheet: equal RULES at the same ORIGIN reuse one compiled object, and the stylesheet is cached by content up to a bounded limit. The returned scope carries a stable membership identity that distinguishes it from every other scope, even one built from equal rules. A scope affects only the roots it is attached to; it declares no cascade layers, so its rules are unlayered at ORIGIN. Attaching it to a node makes that node a member through the node's scope bindings, and a root's snapshot is used for the members within it; a scope that is attached to no root applies no rules. Scope creation mutates neither RULES nor any other input.

**Returns.** The shared scope.

**Errors.** The rule and declaration errors of `ebox-style-compile-rules`.

**See also.** `ebox-style-scope-with-rules`.

#### Function: ebox-style-scope-with-rules (scope rules &key (origin 'author))

Return a new RULES snapshot preserving SCOPE's membership identity.

**Arguments.** SCOPE is a scope returned by `ebox-style-scope-create`. RULES is the new ordered rule list, and ORIGIN is the cascade origin, `author` by default.

**Semantics.** The result is a new scope whose membership identity is SCOPE's, so nodes already attached through that identity stay members without rebinding. The new rules are compiled as in `ebox-style-scope-create`; RULES may be nil, which removes the scope's rules while keeping its membership. Neither SCOPE nor any previously constructed input is modified. This is the interface an incremental host uses to replace a rule snapshot, for example when a Theme changes and a Component's static rules must be lowered again.

**Returns.** The new scope snapshot.

**Errors.** `error→ error` when SCOPE is not a scope; otherwise the rule and declaration errors of `ebox-style-compile-rules`.

## The computed style record

<!-- index: computed style; hash consing; inheritance key; layout key -->

Each node keeps one computed style record: the canonical values of every longhand plus the facts paint and layout read directly — tag, hidden state, background, faces, font metrics, decoration, the eight padding and margin edges, the four border widths and colors, box sizing, positioning, outer participation, overflow, wrap mode, alignment, gaps, stacking and anchoring. The record is the single source for both paint and geometry, and the style pass replaces it as one object rather than mutating it.

Records are hash-consed. A computed style is cached under a key made of the node's tag, its compiled declarations and the snapshots of the scopes that apply to it, so nodes that are styled identically share one object and a style comparison can be object identity. Children are looked up in a table bucketed by what they can inherit from their parent: the parent's inheritance key covers the inherited values, so siblings with the same inherited result reuse their parent's entry. An explicit `inherit` declaration can copy a non-inherited parent value, and such a node is bucketed by the parent style itself instead.

Geometry comparison has its own shared key: the list of geometry-relevant values of a record is interned in a weak table, so two records compare their layout inputs with identity as well. That key decides whether a style change needs a repaint or a relayout.

## The style pass

<!-- index: style pass; dirty bits; relayout boundary -->

The style pass visits a node when it is force-marked, when its style dirty bit is set, or when it has no computed style yet. The new record is computed and compared with the old one by identity; when they are the same object, the node is done — that is the payoff of hash-consing. When the record changed, the pass marks the path so layout and paint can find the node from their roots.

The change is then classified. If the layout key is unchanged, or only the font weight differences that cannot change metrics, the node is marked for repaint only. Otherwise its intrinsic caches are cleared and it is marked for layout; when the parent is a container whose placement depends on item facts — a flex or grid container, or any parent whose child changed outer participation or absolute positioning — the parent is marked for layout as well. A node that gains or loses absolute positioning is unhosted or rehosted, and anchored overlays are re-registered.

Propagation follows inheritance, not the whole tree. Children are force-visited only when the parent's inheritance key changed or when the node environment changed; otherwise the pass descends only into the children already recorded as dirty. That keeps a change whose inherited result is unchanged — a background tweak on one card, a hover repaint — from walking a large subtree.

## Viewport unit dependencies

<!-- index: viewport unit; refit; dependency table -->

A length may read `vw` or `vh`, whose values depend on the mounted viewport rather than on the node tree. The style pass records the nodes whose computed style reads those units in a weak table, together with which of the two units each node uses, and removes the registration when a restyle stops reading them.

`ebox-refit` uses that table when a buffer's viewport size changed. A width change marks the root, because the root's available width is the viewport, and marks only the registered nodes that read `vw`; a height change marks the root only when its own block size follows the containing height, and marks only the registered nodes that read `vh`. A relayout follows, then the viewport change hook runs. Nodes with no viewport dependency and no changed constraint are not relaid out.

## Adding a style property

<!-- index: extending the schema; property registration; acceptance test -->

A new property is added in the schema data and then made real through projection and tests:

1. Add the definition: canonical name, namespaced id, aliases, initial value, inheritance, contexts, group, dirty kind, signature, validator and, when needed, normalizer, shorthand, size axis and explicit impacts or projections. The impact and projection owners can be omitted when the group and the name let the registry derive them.
2. Make the value grammar exact: the validator decides what is accepted, a size axis constrains the units and, for track-like grammars, the nested values.
3. For a shorthand, add an expander that produces canonical longhands and is applied exactly once; for an alias, only the name entry is needed.
4. Project the computed value where it is consumed: a paint property is read when faces and parts are composed, a geometry property when layout resolves sizes and positions, and a structural property where participation and placement are decided. A property that changes what a parent must recompute belongs in the parent-relevant dirty class.
5. Verify through public behavior: cover the value grammar, the initial and inherited behavior, the applicable tags, and the paint-or-geometry effect with tests; then add the entry to [Style Properties](style-properties.md) and, when the vocabulary is complete, to its coverage list.

The matching ETAF work — a Host attribute that reaches the property, or a component rule that declares it — uses the existing author surfaces; the schema entry is the only place the property itself is defined.
