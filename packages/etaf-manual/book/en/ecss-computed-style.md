# Computed Style

Computing a style is the point where everything ECSS knows about a subject is turned into a result: the property vocabulary from a schema set, the rules of a stylesheet, mounted scopes and inline declarations, an optional parent style, and the custom properties those values reference. The result is an immutable *computed style* that answers three different questions with three different sets of identifiers, and this chapter defines both that object and every reader on it. The cascade comparison that produces the winners is [The Style System](style-system.md); the stylesheet and scope inputs are [Stylesheets, Scopes and Author Ownership](ecss-stylesheets-and-scopes.md); declaration values, custom properties and `var()` references are [Values](values.md).

## Model

<!-- index: computed style; computed value; custom property; active property; specified property; provenance; diagnostic -->

A computed style is a value object. It is produced once by `ecss-compute-style` and never changes; every reader returns detached data, so a caller can mutate what it receives without affecting the style or anything computed from it. It holds the schema set it was computed with, the computed values, the resolved custom properties, three property-identifier sets, the winning facts, optional provenance and diagnostics. It owns no buffer, no runtime and no global state.

The three identifier sets answer different questions, and the difference matters exactly when a winning declaration turns out to be invalid:

| Question | Reader | Meaning |
| --- | --- | --- |
| What value does each property have? | `ecss-computed-style-values` | Every property that is not a shorthand, in schema order. |
| Does this property have a declaration that won? | `ecss-computed-style-specified-p` | A cascade winner exists, whether or not its value validated. |
| Was this property actually supplied? | `ecss-computed-style-present-p` | A valid declaration won, or the property inherits from an active parent. |

A *value* can come from a declaration, from inheritance, or from the schema's initial value, and it always exists for every non-shorthand property. A *specified* property has a winner; an *active* property was really supplied. The two diverge in three cases: a winner whose value the schema rejects is specified but not active and falls back to the inherited or initial value; an explicit nil that the schema accepts is both specified and active; a property that inherits from an active parent is active without a winner in the child.

*Custom properties* are values without schemas. They inherit, resolve through `var()` references, and appear as a name/value plist on the computed style; a reference cycle does not destroy the style, it is recorded as a diagnostic and the affected references fall back.

*Provenance* is opt-in. With `:provenance t` the style keeps, for each property, the winner facts and how the final value was reached; without it the style keeps only what the readers above need. *Diagnostics* are always collected, because they describe values that could not be resolved rather than a request for extra detail.

## Computing a style

`ecss-compute-style` is the entry point. Its inputs are the schema set, the subject, and the style sources; everything else is optional context.

#### Function: ecss-compute-style (schemas subject &key stylesheet rules declarations parent-style adapter provenance value-resolver scopes)

Compute a deterministic style for SUBJECT using SCHEMAS.

**Arguments.** SCHEMAS is a composed schema set. SUBJECT is a built-in subject or a caller-owned node, in which case ADAPTER exposes it. STYLESHEET is a stylesheet; RULES is a validated rule list instead, such as the one `ecss-stylesheet-rules` returns. DECLARATIONS is an inline property/value list. PARENT-STYLE is another computed style or a values plist. PROVENANCE asks for winner facts. VALUE-RESOLVER is the function allowed to evaluate caller-owned value sources. SCOPES is a list of mounted scopes.

**Semantics.** At most one of STYLESHEET and RULES may be supplied; the rule list is validated against SCHEMAS, including each rule's selector, origin and declarations. Inline DECLARATIONS are expanded through the schema set, so aliases resolve and shorthands become longhands; custom properties need no schema. Candidates from the rules, the scopes and the declarations are ordered by the cascade, and for every non-shorthand schema property the winning candidate is resolved: custom-property references are substituted, CSS-wide values and inheritance are applied, and the schema normalizer and validator are run. The winner of an invalid value is retained as specified and its fallback is recorded, but the cascade is not rerun. A VALUE-RESOLVER, when given, is called once for each candidate that is considered, receiving the value, the canonical property and the subject; it is the only place caller-owned value sources are evaluated, and its result becomes the value after validation. Mutable values are detached from the declarations, while functions keep their identity, so a function value passes through unresolved unless the resolver returns something else. A `:parent-style` values plist is treated as a bare set of parent values: only inheriting properties read it, and no custom properties come from it.

**Returns.** An immutable computed style.

**Errors.** `error→ wrong-type-argument` naming the schema-set predicate when SCHEMAS is not a schema set, or the adapter predicate when ADAPTER is not an adapter. `error→ ecss-invalid-rule` with data `(:stylesheet-and-rules)` when both sources are given, or `(:rule RULE)` when a supplied rule fails validation. `error→ ecss-invalid-declaration` for an inline declaration the schemas reject. An error from VALUE-RESOLVER propagates unchanged.

**Example.**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :validator stringp
                           :impacts (paint))))))
       (subject (ecss-subject-create :type "button" :classes '("primary")))
       (sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-add-rule sheet schemas ".primary" '(demo/color "red"))
  (ecss-computed-style-values
   (ecss-compute-style schemas subject :stylesheet sheet)))
     ⇒ (demo/color "red")
```

**See also.** `ecss-computed-style-values`, `ecss-computed-style-copy-with-values`, `ecss-stylesheet-add-rule`, `ecss-scope-create`.

## Values and custom properties

`ecss-computed-style-values` is the whole result as a plist, `ecss-computed-style-value` reads one property with an optional fallback, and `ecss-computed-style-custom-properties` reads the resolved custom properties. All three return detached data.

#### Function: ecss-computed-style-values (style)

Return a defensive values plist from computed STYLE.

**Semantics.** The plist has one entry for every non-shorthand property the schema set registers, in registration order, whether or not anything declared it: a property with no candidate carries its inherited or initial value. Shorthands never appear — the schema expansion has already turned them into longhands. Inherited values are copies, so the returned plist does not share mutable data with STYLE.

**Returns.** A property/value plist in schema order.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(let ((style (ecss-compute-style
              (ecss-schema-set-compose
               (ecss-schema-package-create
                'demo '((:id demo/color :initial "black" :validator stringp
                         :impacts (paint))
                        (:id demo/gap :initial 0 :validator numberp
                         :impacts (geometry)))))
              (ecss-subject-create :type "button"))))
  (ecss-computed-style-values style))
     ⇒ (demo/color "black" demo/gap 0)
```

**See also.** `ecss-computed-style-value`, `ecss-computed-style-custom-properties`.

#### Function: ecss-computed-style-value (style property &optional fallback)

Return PROPERTY from computed STYLE, or FALLBACK when absent.

**Semantics.** PROPERTY may be a canonical identifier or an exact alias. A property that has a value always answers with it — the fallback is reached only for a name the style does not carry at all, such as an unknown property or a custom property. The returned value is detached, so assigning to a string or list it contains does not change the style.

**Returns.** The computed value, or FALLBACK.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(let ((style (ecss-compute-style
              (ecss-schema-set-compose
               (ecss-schema-package-create
                'demo '((:id demo/color :initial "black" :validator stringp
                         :impacts (paint)))))
              (ecss-subject-create :type "button"))))
  (list (ecss-computed-style-value style 'demo/color)
        (ecss-computed-style-value style 'demo/unknown "fallback")))
     ⇒ ("black" "fallback")
```

**See also.** `ecss-computed-style-values`, `ecss-computed-style-property-fact`.

#### Function: ecss-computed-style-custom-properties (style)

Return a defensive custom property plist from computed STYLE.

**Semantics.** The plist contains every resolvable custom property, sorted by name, including the ones inherited from the parent style and the ones no declaration referenced. A custom property whose value cannot be resolved — because it forms a cycle or references a missing name without a fallback — is left out, and the same computation records a diagnostic explaining it.

**Returns.** A custom-property/value plist, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(ecss-computed-style-custom-properties
 (ecss-compute-style
  (ecss-schema-set-compose
   (ecss-schema-package-create
    'demo '((:id demo/color :initial "black" :validator stringp
             :impacts (paint)))))
  (ecss-subject-create :type "button")
  :declarations '( --accent "blue")))
     ⇒ (--accent "blue")
```

**See also.** `ecss-computed-style-diagnostics`, `ecss-var`.

## Supply: active and specified

Whether a property was declared and whether its value was accepted are different facts, and these four readers report them separately. They matter to consumers that must tell "this value came from a declaration" from "this value is only the fallback".

#### Function: ecss-computed-style-active-properties (style)

Return actively supplied property identifiers from computed STYLE.

**Semantics.** A property is active when a declaration won and its value validated, or when the property inherits and the parent actively supplies it. An explicit nil that the schema accepts is active like any other value; a winner whose value failed validation is not active even though it is specified. Identifiers come in schema order.

**Returns.** A list of property identifiers, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**See also.** `ecss-computed-style-present-p`, `ecss-computed-style-specified-properties`.

#### Function: ecss-computed-style-present-p (style property)

Return non-nil when PROPERTY is actively supplied in computed STYLE.

**Semantics.** This is the membership test for the active set, so it answers "was this property really supplied" without materializing the whole list. PROPERTY may be a canonical identifier or an exact alias; a custom property has no schema entry and is not active. The value is unspecified — use it as a boolean.

**Returns.** Non-nil when the property is active, nil otherwise.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**See also.** `ecss-computed-style-active-properties`, `ecss-computed-style-specified-p`.

#### Function: ecss-computed-style-specified-properties (style)

Return property identifiers with cascade winners from computed STYLE.

**Semantics.** Every property whose winning declaration exists is listed, valid or not, so this set is the answer to "what did the cascade decide" independent of what the schema accepted. Like the active set it comes in schema order.

**Returns.** A list of property identifiers, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**See also.** `ecss-computed-style-specified-p`, `ecss-computed-style-active-properties`.

#### Function: ecss-computed-style-specified-p (style property)

Return non-nil when PROPERTY has a cascade winner in computed STYLE.

**Semantics.** This is the membership test for the specified set. Together with `ecss-computed-style-present-p` it distinguishes the three cases: specified and active is a valid declaration, specified but not active is an invalid winner that fell back, and neither is a value from inheritance or the initial state. PROPERTY may be a canonical identifier or an exact alias; the value is unspecified.

**Returns.** Non-nil when the property has a winner, nil otherwise.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(let* ((style (ecss-compute-style
               (ecss-schema-set-compose
                (ecss-schema-package-create
                 'demo '((:id demo/color :initial "black" :validator stringp
                          :impacts (paint))
                         (:id demo/payload :initial "none"
                          :validator (lambda (_value) t)
                          :impacts (paint)))))
               (ecss-subject-create :type "button")
               :declarations '(demo/color nil demo/payload nil))))
  (list (and (ecss-computed-style-specified-p style 'demo/color) t)
        (and (ecss-computed-style-present-p style 'demo/color) t)
        (ecss-computed-style-active-properties style)
        (ecss-computed-style-value style 'demo/color)))
     ⇒ (t nil (demo/payload) "black")
```

**See also.** `ecss-computed-style-present-p`, `ecss-computed-style-values`.

## Winner facts

The internal winner record is not public, but two queries expose what a consumer needs: one property's complete fact, and which of several properties won the highest-precedence argument.

#### Function: ecss-computed-style-property-fact (style property)

Return one immutable computed fact for PROPERTY in STYLE, or nil.

**Semantics.** The fact bundles the canonical property, its computed value, the owning package identity, the schema's impacts and projections, the property's provenance when the style was computed with `:provenance t`, and the schema metadata, all in one detached value. A name that resolves to no schema property — an unknown name or a custom property — returns nil.

**Returns.** The property fact, or nil.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(let* ((style (ecss-compute-style
               (ecss-schema-set-compose
                (ecss-schema-package-create
                 'demo '((:id demo/color :initial "black" :validator stringp
                          :impacts (paint) :projections (paint)
                          :metadata (:note "color")))))
               (ecss-subject-create :type "button"))))
  (list (and (ecss-computed-style-property-fact style 'demo/color) t)
        (ecss-computed-style-property-fact style 'demo/unknown)))
     ⇒ (t nil)
```

**See also.** `ecss-computed-style-value`, `ecss-computed-style-precedence-winner`.

#### Function: ecss-computed-style-precedence-winner (style properties)

Return the highest-precedence declared property in PROPERTIES for STYLE.

**Semantics.** PROPERTIES is a list of canonical identifiers or aliases. The function compares the already-recorded winners with the exact cascade ordering and returns the one that would win if the properties were the only ones in play; properties without a winner are ignored, and nil is returned when none of them was declared. It never reruns the cascade and works whether or not the style was computed with `:provenance t`.

**Returns.** The canonical identifier of the highest-precedence declared property, or nil.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style; `error→ ecss-invalid-declaration` with data `(:unknown-property PROPERTY)` when a name is not in the schema set.

**Example.**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :validator stringp
                           :impacts (paint))
                          (:id demo/size :initial 0 :validator numberp
                           :impacts (geometry))))))
       (subject (ecss-subject-create :type "button" :id "save" :classes '("target")))
       (sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-add-rule sheet schemas ".target" '(demo/color "red"))
  (ecss-stylesheet-add-rule sheet schemas "#save" '(demo/size 5))
  (ecss-computed-style-precedence-winner
   (ecss-compute-style schemas subject :stylesheet sheet)
   '(demo/color demo/size)))
     ⇒ demo/size
```

**See also.** `ecss-computed-style-property-fact`, `ecss-computed-style-provenance`.

## Provenance and diagnostics

Provenance is the opt-in record of how each property reached its value. Diagnostics are always collected and describe values the computation could not resolve.

#### Function: ecss-computed-style-provenance (style)

Return defensive winner provenance from computed STYLE.

**Semantics.** The plist maps each property to its facts. A property decided by a declaration reports the source, the normalized selector, the origin, importance and inline status, the layer, the specificity, the scope distance, the source and declaration order, whether the value validated, where the value came from, and the fallback when one was used. A property with no winner reports a bare `(:source initial :origin ua)` or `(:source inherit :origin inherit)`; an inherited custom property reports `(:source inherit)`. Nil is returned when the style was computed without `:provenance t`, which is the default.

**Returns.** A property/plist mapping, or nil.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :validator stringp
                           :impacts (paint))))))
       (subject (ecss-subject-create :type "button" :classes '("target")))
       (sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-add-rule sheet schemas ".target" '(demo/color "red"))
  (plist-get
   (plist-get
    (ecss-computed-style-provenance
     (ecss-compute-style schemas subject :stylesheet sheet :provenance t))
    'demo/color)
   :valid))
     ⇒ t
```

**See also.** `ecss-computed-style-diagnostics`, `ecss-computed-style-property-fact`.

#### Function: ecss-computed-style-diagnostics (style)

Return defensive diagnostics from computed STYLE.

**Semantics.** Each diagnostic is a plist with a `:type` and the data that explains it; today the type is `variable-cycle`, and its `:path` lists the custom properties around the loop. Diagnostics are deduplicated and ordered deterministically, so the same inputs produce the same list. A cycle is not an error: the affected references fall back, the custom property is left out of the custom-property plist, and the diagnostic says why.

**Returns.** A list of diagnostic plists, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(ecss-computed-style-diagnostics
 (ecss-compute-style
  (ecss-schema-set-compose
   (ecss-schema-package-create
    'demo '((:id demo/color :initial "black" :validator stringp
             :impacts (paint)))))
  (ecss-subject-create :type "button")
  :declarations (list '--a (ecss-var '--b) '--b (ecss-var '--a))))
     ⇒ ((:type variable-cycle :path (--a --b --a)))
```

**See also.** `ecss-computed-style-custom-properties`, `ecss-computed-style-provenance`.

## Deriving a style

#### Function: ecss-computed-style-copy-with-values (style values &key active-properties specified-properties)

Return STYLE copied with replacement VALUES and optional metadata.

**Semantics.** This is a narrow transformation for a consumer that has already proved that selector and cascade facts are unchanged and only needs to propagate a computed-value delta. VALUES replaces the whole values plist rather than merging into it; ACTIVE-PROPERTIES and SPECIFIED-PROPERTIES replace their sets when given and retain STYLE's when omitted. Provenance and diagnostics are retained as they are. Every mutable value is copied at the boundary, so mutating VALUES after the call cannot change the copy.

**Returns.** A new computed style.

**Errors.** `error→ wrong-type-argument` naming the computed-style predicate and the value when STYLE is not a computed style.

**Example.**

```elisp
(let ((style (ecss-compute-style
              (ecss-schema-set-compose
               (ecss-schema-package-create
                'demo '((:id demo/color :initial "black" :validator stringp
                         :impacts (paint))
                        (:id demo/gap :initial 0 :validator numberp
                         :impacts (geometry)))))
              (ecss-subject-create :type "button")
              :declarations '(demo/gap 3))))
  (list (ecss-computed-style-values
         (ecss-computed-style-copy-with-values style '(demo/color "copied")))
        (ecss-computed-style-active-properties
         (ecss-computed-style-copy-with-values style '(demo/color "copied")))))
     ⇒ ((demo/color "copied") (demo/gap))
```

**See also.** `ecss-compute-style`, `ecss-computed-style-p`.

#### Function: ecss-computed-style-p (x)

Return non-nil when X is a computed style.

**Semantics.** The predicate is the type guard every reader uses, and the way a consumer tells a computed style from a values plist when both may be passed as a parent style.

**Returns.** Non-nil when X is a computed style, nil otherwise.

**Errors.** None.

**See also.** `ecss-compute-style`, `ecss-computed-style-values`.

## Semantic details

<!-- index: invalid winner; fallback; winner ordering; boundary copy -->

The three identifier sets are the heart of the interface, and their divergence is deliberate. When the top candidate's value fails validation, the winner stays in the specified set — the cascade decided it and that decision will not change on a recomputation — but it leaves the active set and the value falls back to inheritance or the initial value. Provenance records both facts: `:valid` is nil and `:fallback` names where the value came from. A consumer that wants "what was declared" asks the specified set; one that wants "what is in force" asks the active set.

Values always cover the whole vocabulary. Every non-shorthand property registered in the schema set gets an entry, even when nothing mentions it, because initial and inherited values are part of the answer. This makes the values plist a stable shape to iterate: a consumer can walk the schema order and find every property it knows about, and a properties list handed to `ecss-computed-style-precedence-winner` is resolved against the same vocabulary.

Provenance is opt-in because it costs memory and allocation: without it the style keeps the winner records internally (that is what `ecss-computed-style-precedence-winner` reads) but does not build the public fact plists. Diagnostics are not opt-in because they report a computation that could not produce a value; the affected custom property is omitted and the reference falls back, so the result is still complete.

The resolver is the only evaluation hook. ECSS never calls a function stored in a property by itself; when `:value-resolver` is supplied it is called once for each candidate considered, with the value detached and the canonical property and subject passed along, and whatever it returns becomes the value before the schema normalizer and validator run. This keeps construction and computation pure by default while letting a host evaluate dynamic values on its own terms.

Every public reader copies. The style is immutable and the readers return fresh plists or lists, so a caller can sort, mutate or store what it receives without any risk of changing the style or another consumer's view of it. The copies are shallow in the same sense as the schema and subject boundaries: nested mutable values are detached, while functions keep their identity.

## Errors and recovery

<!-- index: compute errors; reader errors -->

Computation rejects its whole input or returns a complete style; there is no partial result. Input errors are signaled before any value is resolved, and a resolver error propagates at the point the resolver is called, leaving the caller with no style to clean up.

| Situation | Signal |
| --- | --- |
| SCHEMAS is not a schema set | `error→ wrong-type-argument` naming the schema-set predicate and the value |
| ADAPTER is neither nil nor an adapter | `error→ wrong-type-argument` naming the adapter predicate and the value |
| Both `:stylesheet` and `:rules` are supplied | `error→ ecss-invalid-rule`, data `(:stylesheet-and-rules)` |
| A rule in `:rules` fails validation | `error→ ecss-invalid-rule`, data `(:rule RULE)` |
| An inline declaration names an unknown property or is malformed | `error→ ecss-invalid-declaration` with the offending property |
| VALUE-RESOLVER signals | that error propagates unchanged |
| A reader or `ecss-computed-style-copy-with-values` receives a non-style | `error→ wrong-type-argument` naming the computed-style predicate and the value |
| `ecss-computed-style-precedence-winner` is given an unknown property | `error→ ecss-invalid-declaration`, data `(:unknown-property PROPERTY)` |
