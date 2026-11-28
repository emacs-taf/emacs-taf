# ecss Architecture

[中文](architecture.zh-CN.md)

## Position

`ecss` is the generic pure-computation layer that answers which rule wins and what each final property value is. It transforms consumer-provided property schemas, subjects, stylesheets, inline declarations, and a parent computed style into computed values, custom properties, active properties, specified properties, provenance, and diagnostics.

```text
consumer schemas + subject adapter + stylesheet + parent style
                              │
                              ▼
       selector match → candidate collection → cascade winner
                              │
                              ▼
        CSS-wide/custom-property resolution → normalize/validate
                              │
                              ▼
    computed style + specified properties + provenance + diagnostics
```

`ecss` does not know how computed values are displayed. Ebox consumes them for measurement, Box/Flex/Grid layout, painting, and its own retained buffer publication. Other callers can use `ecss` without Ebox or any buffer.

## Package schemas and explicit surfaces

Each owning package creates one immutable `ecss-schema-package`. A concrete surface then atomically composes the required packages with `ecss-schema-set-compose`. Composition rejects duplicate packages and canonical/canonical, canonical/alias, and alias/alias collisions. There is no process-global mutable registry and no last-wins registration, so applications can compose different property vocabularies in one Emacs process without interference.

Aliases exist only at declaration normalization and disappear before cascade. An alias/canonical duplicate or a shorthand/owned-longhand conflict inside one declaration fails immediately. The schema set retains owner, impact, and projection facts, and a computed style references that set instead of building a second computed tree. Packages and schema sets expose no mutator; public queries return detached data.

Stylesheets remain explicitly owned mutable authoring objects. UA, user, and author origins inside one stylesheet keep independent layer orders. Rule addition is atomic, so failure cannot leave a half-added layer or an incorrect source order.

## Subjects and adapters

Simple callers use `ecss-subject` directly. Existing tree models use `ecss-subject-adapter-create` to provide type, id, classes, attributes, states, parent, and children callbacks without copying business nodes into ECSS nodes. Selector queries and stylesheets share one parser, matcher, and specificity implementation, so query matching cannot drift from rule matching.

Mounted scopes snapshot their stylesheet and an optional identity set of eligible
rule targets. Membership filters candidate collection, while selector relationships
remain those of the host adapter within the mounted root. This separates author
ownership from physical parentage without duplicating cascade logic or suppressing
inherited values. An absent membership constraint covers the subtree; an empty set
matches no targets. Sets use identity lookup and do not copy host subjects.
Candidate collection reads these owned rule snapshots directly. Defensive
copies belong at public queries and callback boundaries, so computing each
subject does not copy all rules from every mounted scope.

## Cascade order

Candidates compare by CSS order: relevance and matching, origin plus importance, cascade layer, specificity, scope proximity, source order, and declaration order. Standard origin levels are UA normal, user normal, author normal, animation, author important, user important, UA important, and transition. Later normal layers win and unlayered normal declarations beat layered ones. Important layers reverse order. Inline author declarations retain the highest priority inside the author origin.

`revert` removes the entire current origin, across normal and important declarations, before choosing again. `revert-layer` removes the entire current layer inside that origin. An invalid-at-computed-value winner never recascades to a lower candidate; it uses the inherited or initial fallback and records the invalid winner in provenance.

## Value-source boundary

ECSS never calls an ordinary function stored in a property and defines no reactive or computed wrapper. A caller that needs evaluation explicitly passes `:value-resolver` to `ecss-compute-style`. The resolver receives value, property, and subject. ECSS invokes it once for each selected source and never executes its result a second time. Resolver errors propagate. Because computation is pure, ECSS has no buffer or runtime state to roll back.

## Custom properties

Custom properties use `--name` symbols. Their raw values first pass through ordinary cascade, inherit from the parent computed style by default, and then resolve through `ecss-var`. References may occur inside lists or vectors. Missing values and cycles can use fallback at the reference site. A cycle does not destroy the whole computed style: it creates a deterministic diagnostic and makes the affected value invalid at computed-value time.

## Package boundary

```text
ecss: selector / stylesheet / cascade / computed values
ebox: box semantics / measurement / flex-grid layout / painting / dirty ownership
      display bindings / text-property projection / retained publication / transactions
```

Ebox depends on `ecss`; `ecss` remains independently usable and does not depend on Ebox. The `ecss` public API defines no Ebox node, display binding, mount, marker, patch, or buffer mutation. Each consumer owns its rendering and publication behavior.
