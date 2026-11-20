# Stylesheets, Scopes and Author Ownership

A schema set says which properties exist; a *stylesheet* says which values they take for which subjects. Stylesheets are the explicitly owned, mutable side of ECSS: a host builds one, adds rules in the order it wants, declares cascade layers, and can clear or replace it. Mounting a stylesheet as a *scope* is how those rules reach a subject tree, and the mount boundary is where author ownership is drawn: the scope holds a snapshot, an optional set of eligible subjects, and nothing else. This chapter defines the authoring objects and the mount. [The Style System](style-system.md) explains origins, importance and layers as cascade concepts; the chapter that computes a style takes the stylesheet and scopes defined here as its inputs.

## Model

<!-- index: stylesheet; rule; origin; cascade layer; mounted scope; author ownership -->

A stylesheet owns three things: an ordered list of rules, one layer order per origin, and a counter that numbers the rules it has added. Nothing about it is global. Two stylesheets never see each other, and a program that wants shared rules passes the same stylesheet to the places that need it rather than registering anything in a process-wide table.

A *rule* is one fact produced by adding a selector and declarations: the selector in normalized AST form, the declarations expanded to canonical longhands, the origin it belongs to, its layer, an optional scope selector, and its source order inside the stylesheet. A rule is read back through `ecss-rule-selector` and `ecss-rule-scope`; adding, changing or removing a rule is done on the stylesheet, not by editing a rule object.

An *origin* is one of the five cascade sources: `ua`, `user`, `author`, `animation` and `transition`. Most code adds author rules, and `author` is the default. Each origin has its own layer order, so declaring layers for author rules never disturbs user or UA rules.

A *layer* orders rules inside one origin. A layer enters its origin's order at the moment it is declared or first used by a rule, and it keeps that position afterwards: later declarations can append new layers but never reorder existing ones. A rule with no layer is outside the layer order, which matters for the cascade and is described in [The Style System](style-system.md).

A *scope* mounts a snapshot of a stylesheet at a root subject. The scope keeps the snapshot, an optional membership set of eligible subject identities, and an optional parent scope association. It does not own the subject tree and does not copy it: subjects and adapter trees remain host-owned, as [Subjects and Adapters](ecss-subjects-and-adapters.md) describes.

## Authoring a stylesheet

`ecss-stylesheet-create` makes an empty stylesheet, and `ecss-stylesheet-add-rule` appends rules to it. Addition is atomic and validating: the selector is normalized, the declarations are expanded through the schema set, the origin is checked, and only then does the rule join the stylesheet.

#### Function: ecss-stylesheet-create ()

Create an empty independent stylesheet.

**Semantics.** The new stylesheet has no rules, no declared layers for any origin, and its own source-order counter at zero. Independence is the point: every part of the object lives in the value, so a stylesheet can be built in one place and passed to one or more mounts without affecting another.

**Returns.** The new stylesheet.

**Errors.** None.

**Example.**

```elisp
(ecss-stylesheet-rules (ecss-stylesheet-create))
     ⇒ nil
```

**See also.** `ecss-stylesheet-add-rule`, `ecss-scope-create`.

#### Function: ecss-stylesheet-add-rule (stylesheet schemas selector declarations &key (origin 'author) layer scope)

Add SELECTOR and DECLARATIONS to STYLESHEET using SCHEMAS.

**Arguments.** STYLESHEET is a stylesheet. SCHEMAS is a composed schema set. SELECTOR is a selector string or AST. DECLARATIONS is an even property/value list whose properties are canonical IDs or aliases. ORIGIN is one of the five cascade origins, `author` by default. LAYER is the cascade layer the rule belongs to, or nil for an unlayered rule. SCOPE is an optional selector limiting the rule to a subject or ancestor that matches it.

**Semantics.** The call normalizes SELECTOR and SCOPE through the selector engine, validates ORIGIN, and expands DECLARATIONS through SCHEMAS, so aliases are resolved and shorthands become canonical longhands before the rule exists. It then appends the rule to the sheet and numbers it one past the current source order. When LAYER is non-nil and the origin does not know it yet, the layer is appended to that origin's order at this point, which is what makes first use equivalent to a declaration. Any failure happens before the append, so a rejected call adds no rule and declares no layer. The returned rule is a detached copy; the stylesheet keeps its own.

**Returns.** A copy of the added rule.

**Errors.** `error→ wrong-type-argument` naming the stylesheet predicate when STYLESHEET is not a stylesheet, or the schema-set predicate when SCHEMAS is not a schema set; `error→ ecss-invalid-selector` for a selector or scope the parser rejects; `error→ ecss-invalid-rule` with data `(:origin ORIGIN)` for an unknown origin; `error→ ecss-invalid-declaration` for a declaration the schemas reject, such as an unknown property.

**Example.**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :impacts (paint))))))
       (sheet (ecss-stylesheet-create)))
  (list (ecss-rule-selector
         (ecss-stylesheet-add-rule sheet schemas "p" '(demo/color "red")))
        (ecss-stylesheet-layers sheet)))
     ⇒ ((:type "p") nil)
```

**See also.** `ecss-stylesheet-rules`, `ecss-stylesheet-declare-layers`, `ecss-scope-create`.

#### Function: ecss-stylesheet-rules (stylesheet)

Return defensive rule copies from STYLESHEET.

**Semantics.** Rules come back in the order they were added, each as an independent copy with its selector, declarations, layer and scope detached. Mutating a returned rule, or the list itself, cannot change the stylesheet, and a later query returns fresh copies again.

**Returns.** A list of rule copies, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the stylesheet predicate and the value when STYLESHEET is not a stylesheet.

**See also.** `ecss-stylesheet-add-rule`, `ecss-rule-selector`.

## Reading a rule

A rule handed back by `ecss-stylesheet-add-rule` or `ecss-stylesheet-rules` exposes its selector facts through accessors. The declarations, origin, layer and source order are internal to the cascade; a caller inspects what a rule targets with these two accessors and changes the rule by changing the stylesheet.

#### Function: ecss-rule-selector (x)

Return the normalized selector of rule X.

**Semantics.** The value is the same selector AST the selector engine matches, so it can be passed back to `ecss-selector-match-p` or compared with the result of `ecss-selector-parse`. A rule added from a string therefore reports the parsed form, not the string.

**Returns.** The rule's selector AST.

**Errors.** `error→ wrong-type-argument` naming the rule type and X when X is not a rule.

**Example.**

```elisp
(ecss-rule-selector
 (ecss-stylesheet-add-rule (ecss-stylesheet-create)
                           (ecss-schema-set-compose
                            (ecss-schema-package-create
                             'demo '((:id demo/color :impacts (paint)))))
                           "div > .x" '(demo/color "v") :scope ".outer"))
     ⇒ (:child (:type "div") (:class "x"))
```

**See also.** `ecss-rule-scope`, `ecss-stylesheet-rules`.

#### Function: ecss-rule-scope (x)

Return the scope selector of rule X, or nil.

**Semantics.** A rule added with `:scope` carries the normalized selector that limits it to a matching subject or ancestor; a rule added without the option reports nil. The scope of a rule and the mounted scope of `ecss-scope-create` are different mechanisms: the first is a condition written into the rule, the second is the mount that publishes the rule.

**Returns.** The rule's scope selector AST, or nil.

**Errors.** `error→ wrong-type-argument` naming the rule type and X when X is not a rule.

**See also.** `ecss-rule-selector`, `ecss-stylesheet-add-rule`.

## Layers

Layers are declared, not created. `ecss-stylesheet-declare-layers` predeclares the order of an origin's layers, and adding a rule with a `:layer` that is not declared yet appends it at first use. Both operations only append; the effective order is what `ecss-stylesheet-layers` reports.

#### Function: ecss-stylesheet-declare-layers (stylesheet layers &optional origin)

Append unseen LAYERS to STYLESHEET for ORIGIN and return their order.

**Arguments.** STYLESHEET is a stylesheet. LAYERS is a proper list of non-nil layer values; declaring the same layer twice is allowed and adds it once. ORIGIN defaults to `author`.

**Semantics.** Each layer in LAYERS that the origin does not already know is appended to that origin's order, keeping the argument order. The function returns the full resulting order, not just the newly added layers, so a caller can inspect the effective order after the call. Existing layers are never reordered, which is what makes a predeclaration meaningful: writing the complete order once lets later rules rely on any position in it.

**Returns.** A fresh copy of the origin's layer order after the call.

**Errors.** `error→ wrong-type-argument` naming the stylesheet predicate when STYLESHEET is not a stylesheet; `error→ ecss-invalid-rule` with data `(:layers LAYERS)` when LAYERS is not a non-empty-element list, or `(:origin ORIGIN)` for an unknown origin.

**Example.**

```elisp
(let ((sheet (ecss-stylesheet-create)))
  (list (ecss-stylesheet-declare-layers sheet '(base components))
        (ecss-stylesheet-declare-layers sheet '(components extra))
        (ecss-stylesheet-layers sheet)))
     ⇒ ((base components) (base components extra) (base components extra))
```

**See also.** `ecss-stylesheet-layers`, `ecss-stylesheet-add-rule`.

#### Function: ecss-stylesheet-layers (stylesheet &optional origin)

Return STYLESHEET layers for ORIGIN in declared order.

**Semantics.** The result is a detached copy of the origin's effective order: declared layers followed by layers that entered through first use, in the order they entered. Origins are independent, so the same stylesheet reports a different order for each origin that has rules or declarations. ORIGIN defaults to `author`.

**Returns.** A list of layer values in order, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the stylesheet predicate when STYLESHEET is not a stylesheet; `error→ ecss-invalid-rule` with data `(:origin ORIGIN)` for an unknown origin.

**See also.** `ecss-stylesheet-declare-layers`, `ecss-stylesheet-clear`.

## Clearing a stylesheet

#### Function: ecss-stylesheet-clear (stylesheet)

Remove all rules and layers from STYLESHEET.

**Semantics.** The call empties the rule list, forgets every origin's layer order and resets the source-order counter, returning the same stylesheet so calls can be chained. It is the rebuild path: a hot-reload loop can clear the sheet and add a fresh set of rules while every mount that already snapshotted the old content keeps its snapshot until a new scope is created.

**Returns.** STYLESHEET.

**Errors.** `error→ wrong-type-argument` naming the stylesheet predicate and the value when STYLESHEET is not a stylesheet.

**Example.**

```elisp
(let ((sheet (ecss-stylesheet-create)))
  (ecss-stylesheet-declare-layers sheet '(base))
  (ecss-stylesheet-add-rule sheet
                            (ecss-schema-set-compose
                             (ecss-schema-package-create
                              'demo '((:id demo/color :impacts (paint)))))
                            "p" '(demo/color "red") :layer 'base)
  (ecss-stylesheet-clear sheet)
  (list (ecss-stylesheet-rules sheet)
        (ecss-stylesheet-layers sheet)))
     ⇒ (nil nil)
```

**See also.** `ecss-stylesheet-create`, `ecss-scope-create`.

## Mounted scopes

A scope publishes a stylesheet to a subject tree. `ecss-scope-create` takes the root of the tree and the stylesheet, snapshots the stylesheet, and records which subjects the sheet's rules may target. The snapshot is what separates authoring from ownership: after the mount, changing the stylesheet does not change the scope, and creating a new scope is how a host adopts new rules.

#### Function: ecss-scope-create (root stylesheet &key parent (subjects t))

Mount a snapshot of STYLESHEET at ROOT with optional PARENT scope.

**Arguments.** ROOT is the non-nil subject or host node that the scope's `&` addresses. STYLESHEET is a stylesheet. PARENT is an optional associated scope. SUBJECTS is `t` for unrestricted targets, a proper list of subject identities to allow, or nil to select none.

**Semantics.** The stylesheet is frozen at the mount boundary: its rules, layer orders and source order are copied into the scope, so later `ecss-stylesheet-add-rule`, `ecss-stylesheet-declare-layers` or `ecss-stylesheet-clear` calls on the source affect only later mounts. Ordinary selector branches in the mounted rules address strict descendants of ROOT, while `&` and `:scope` address ROOT itself; the remaining traversal and inheritance semantics are those of the selector engine. SUBJECTS restricts which subjects may receive declarations from the scope's rules: identities are compared with `eq` and snapshotted, a listed subject must still lie inside ROOT's tree to match, and membership never restricts structural traversal or inherited values. `t` and the empty list are different: `t` is every descendant, nil is none. PARENT is an association only — it records that one scope belongs under another and does not add or exclude subjects, so pass every active scope to the computation that uses them.

**Returns.** The new scope.

**Errors.** `error→ wrong-type-argument` with data naming the constructor and ROOT and STYLESHEET when ROOT is nil or STYLESHEET is not a stylesheet; naming the scope predicate and PARENT when PARENT is neither nil nor a scope; naming the list predicate and SUBJECTS when SUBJECTS is neither `t` nor a proper list.

**Example.**

```elisp
(let* ((schemas (ecss-schema-set-compose
                 (ecss-schema-package-create
                  'demo '((:id demo/color :initial "black" :impacts (paint))))))
       (source (ecss-stylesheet-create))
       (root (ecss-subject-create :type "div"))
       (scope (ecss-scope-create root source)))
  (ecss-stylesheet-add-rule source schemas ".target" '(demo/color "after-mount"))
  (list (length (ecss-stylesheet-rules source))
        (length (ecss-stylesheet-rules (ecss-scope-stylesheet scope)))))
     ⇒ (1 0)
```

**See also.** `ecss-scope-stylesheet`, `ecss-stylesheet-create`, `ecss-subject-create`.

#### Function: ecss-scope-stylesheet (x)

Return the mounted snapshot of scope X.

**Semantics.** The accessor returns the scope's own snapshot stylesheet, the same object on every call; the scope reads it when it matches rules, so adding a rule or declaring a layer through this object changes what that scope applies. Treat it as read-only: the supported way to change a mount is to build the stylesheet and create a new scope. The snapshot is detached from the source stylesheet, so editing the source never changes an existing scope.

**Returns.** The scope's snapshot stylesheet.

**Errors.** `error→ wrong-type-argument` naming the scope type and X when X is not a scope.

**Example.**

```elisp
(let* ((source (ecss-stylesheet-create))
       (scope (ecss-scope-create (ecss-subject-create :type "div") source)))
  (eq (ecss-scope-stylesheet scope)
      (ecss-scope-stylesheet scope)))
     ⇒ t
```

**See also.** `ecss-scope-create`, `ecss-stylesheet-rules`.

## Semantic details

<!-- index: source order; mount snapshot; membership; independent origins -->

Rule addition has one order. Validation, normalization and declaration expansion all happen before the rule is appended, so a caller never sees a half-added rule and an error never leaves a declared layer behind either. Within one stylesheet the source order is simply the addition order, numbered from one; across stylesheets the computation decides precedence, and each sheet's numbers are flattened in the order the scopes are supplied.

Layer order is append-only and per origin. A layer that is declared before any rule joins the origin's order in the declared position; a layer that is first used by a rule joins at that point. Since existing layers never move, a sheet that declares its complete order up front gets deterministic layer ranks no matter how rules arrive afterwards, and a sheet that declares nothing still has a discoverable order through `ecss-stylesheet-layers`.

The mount is a value boundary. Everything the scope reads is frozen at creation: the rules, every origin's layer order, the membership identities. This is what lets a preview, a running application and a hot-reload loop each hold their own view of one authoring stylesheet. The cost is that adopting new rules means creating a new scope; a host that computes styles from scopes should rebuild the scope rather than mutate the old one.

The snapshot is shallow in the sense that matters: rules are copied as values with their selectors and declarations detached, but the subject identities the scope matches are the host's own objects, compared with `eq`. That identity rule is why membership lists work without copying the tree, and why a listed subject that lies outside ROOT still cannot match: the tree position decides reachability, the list only narrows targets.

## Errors and recovery

<!-- index: rule validation; atomic add; scope errors -->

Every rejection happens before any state changes. A failed rule addition leaves the stylesheet's rules, layers and source order exactly as they were; a failed scope creation returns no scope; and a failed query changes nothing. Recovery is to fix the offending value and call again.

| Situation | Signal |
| --- | --- |
| STYLESHEET is not a stylesheet, in any operation that takes one | `error→ wrong-type-argument` naming the stylesheet predicate and the value |
| SCHEMAS is not a schema set | `error→ wrong-type-argument` naming the schema-set predicate and the value |
| SELECTOR or SCOPE cannot be parsed | `error→ ecss-invalid-selector` with parser data |
| DECLARATIONS name an unknown property or an invalid declaration | `error→ ecss-invalid-declaration` with the offending property |
| ORIGIN is not one of `ua`, `user`, `author`, `animation` or `transition` | `error→ ecss-invalid-rule`, data `(:origin ORIGIN)` |
| LAYERS is not a list, or contains nil | `error→ ecss-invalid-rule`, data `(:layers LAYERS)` |
| ROOT is nil, or STYLESHEET is not a stylesheet, in `ecss-scope-create` | `error→ wrong-type-argument` naming the constructor and both arguments |
| PARENT is neither nil nor a scope | `error→ wrong-type-argument` naming the scope predicate and the value |
| SUBJECTS is neither `t` nor a proper list | `error→ wrong-type-argument` naming the list predicate and the value |
| A rule accessor is given a non-rule, or a scope accessor a non-scope | `error→ wrong-type-argument` naming the expected type and the value |
