# Incremental Hosts

An incremental host reuses work: after an update, it wants to keep the matches and computed facts that cannot have changed instead of recomputing everything. The key question before reusing one subject's result is whether the selector that produced it reads only facts of that subject, or whether it also depends on ancestors, siblings or positions that the update may have moved. This chapter defines the one interface that answers that question. It is a classification, not a cache: ECSS tells a host which selectors are safe to reason about locally, and the host owns the reuse decision and the cache it feeds. [Incremental Updates and Publication](incremental-updates-and-publication.md) describes how Ebox uses such classification internally, and [Selectors](selectors.md) defines the selector language being classified.

## Model

<!-- index: selector locality; subject-local fact; tree-sensitive selector; scope root stability -->

A selector is *subject-local* when deciding whether it matches a particular subject requires no fact outside that subject. Type, ID, classes, attributes and states are subject-local facts; a compound selector that uses only them, such as `button#save.primary[role=submit]:active`, is local. So are logical combinations whose every branch is local: `:is(.a, #b)`, `:not(.disabled)` and a selector list of local branches.

Everything that reads tree position is not local. Descendant, child, adjacent and general-sibling combinators reach other nodes, `:has()` looks at a relative target, and the structural and positional pseudo-classes — `:first-child`, `:empty`, `:root`, `:nth-child(2)`, `:nth-last-of-type(odd)` and their relatives — depend on the subject's siblings or parent. A selector containing any such part is not local even when the rest is: locality is a property of the whole selector, not of its first compound.

`&` and `:scope` are a special case because they name the scope root rather than a fixed relationship. By default they are not local, since a subject's match depends on where the root is. A host that has separately proved the subject's relationship to the same scope root is unchanged may pass that proof in as the optional second argument, and the anchors then count as local facts. The proof is the caller's: the function records the assumption, it does not verify it.

Locality is not the whole reuse condition. A local selector still says nothing about whether the rule it belongs to is a member of the current scope, whether the cascade's other inputs changed, whether an inherited value moved, or whether the subject's own local metadata is stale. The host checks those before reusing a computed style; this interface only removes the tree-sensitivity question from that list.

## Classifying a selector

#### Function: ecss-selector-subject-local-p (selector &optional scope-root-stable-p)

Return non-nil when SELECTOR depends only on the matched subject.

**Arguments.** SELECTOR is a selector string or a parsed AST. SCOPE-ROOT-STABLE-P, when non-nil, states that the caller has proved that the matched subject's relationship to the same scope root is unchanged.

**Semantics.** The selector is normalized and validated first, then classified by the kind of each part. Type, ID, class, attribute and state selectors are local; a functional state pseudo-class is local unless it is a positional one, so `:lang(en)`, `:dir(ltr)` and a host-defined `:my-state(on)` read only the subject even though their arguments look structural. Logical combinations (`:is`, `:where`, `:not`, and the internal forms a compound or list lowers to) are local exactly when every branch is. Combinators, `:has()` and the structural and positional pseudo-classes are not local. The scope anchors `&` and `:scope` are local only with SCOPE-ROOT-STABLE-P. The check needs no subject and does no matching: it classifies the selector alone.

**Returns.** Non-nil when the selector is subject-local under the given assumption, nil otherwise.

**Errors.** `error→ ecss-invalid-selector` when SELECTOR cannot be parsed or is not a valid selector AST, including a pseudo-element that the language does not support.

**Example.**

```elisp
(list (and (ecss-selector-subject-local-p ".card:hover") t)
      (and (ecss-selector-subject-local-p "section > .card") t)
      (and (ecss-selector-subject-local-p "&:hover" t) t)
      (and (ecss-selector-subject-local-p "& > .card" t) t))
     ⇒ (t nil t nil)
```

**See also.** `ecss-selector-parse`, `ecss-selector-match-p`, `ecss-scope-create`.

## Semantic details

<!-- index: classification cost; stability proof; logical branches -->

The two levels of the API exist because stability is a fact only the caller can know. Without the flag, a selector that mentions `&` or `:scope` is treated as tree-sensitive, because matching it depends on where the scope root sits relative to the subject. With the flag, the caller promises that this relationship did not change; the anchors then join the same category as a class or an attribute, and a selector such as `&.active` becomes local. The promise is narrow: it covers the subject's relationship to the same root, not membership, not the rules that are currently mounted, and not inherited values.

Functional pseudo-classes are classified by what they read, not by their syntax. The positional forms — `:nth-child`, `:nth-last-child`, `:nth-of-type`, `:nth-last-of-type`, including an `of` filter — count siblings and are not local. Other functional pseudos are state or metadata lookups on the subject itself: `:lang(en)` reads an inherited attribute, but the match still depends only on the subject's own attribute chain, and an unknown pseudo such as `:my-state(on)` is a state token the host supplied. Both are local, which is what lets a host define custom state pseudos without losing locality.

Locality composes downward through logical forms and not upward through anything else. A selector list, `:is()`, `:where()`, `:not()` and the conjunction of one compound are local only when all their branches are; a single non-local branch makes the whole selector non-local, and no outer wrapper can make a tree-sensitive selector local again. The classification is a pure function of the selector, so a host can classify once and keep the answer beside a compiled selector or a rule.

## Errors and recovery

<!-- index: classification errors -->

The call reads no subject, changes nothing, and returns a boolean for every valid selector; the only failure is an invalid selector, which is rejected before classification starts.

| Situation | Signal |
| --- | --- |
| SELECTOR cannot be parsed, or an AST does not validate | `error→ ecss-invalid-selector` with parser data or the offending AST |
| SELECTOR uses a pseudo-element, which the language does not support | `error→ ecss-invalid-selector`, data `(:pseudo-elements-unsupported)` |
