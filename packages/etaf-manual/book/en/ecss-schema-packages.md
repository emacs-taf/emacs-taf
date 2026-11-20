# Schema Packages and Composition

ECSS is a general-purpose cascade engine, not a style vocabulary, and this part of the manual documents its direct use without Ebox or ETAF. Selector matching, cascade order and value resolution are generic, but whether a property exists and what its values mean is decided by the consumer. A host declares its vocabulary with one or more *schema packages* and composes the packages a surface needs into a *schema set*; every later operation in this part takes that set. This chapter defines those two objects: how a package is built from property definitions, how packages compose, and what the queries on a composed set return. [Values](values.md) documents the declarations a schema validates; [Selectors](selectors.md) and [Stylesheets, Scopes and Author Ownership](ecss-stylesheets-and-scopes.md) build on the same set; [Style Implementation](style-implementation.md) shows how Ebox declares its own property vocabulary this way.

## Model

<!-- index: schema package; schema set; property definition; canonical identifier; alias; composition -->

A *property* in ECSS is a symbol whose name contains `/`, such as `demo/color` or `ebox/width`. The slash marks a namespaced, canonical identifier: the engine never asks what a name means, only that each property has one owner and one canonical spelling. Custom properties (`--name`) stand outside the vocabulary and need no schema at all, which [Values](values.md) explains.

A *property definition* is the data that describes one property. It is a plist; `:id` and `:impacts` are required and the rest are optional.

| Key | Meaning |
| --- | --- |
| `:id` | The canonical identifier: a symbol containing `/`, not starting or ending with it. |
| `:impacts` | A nonempty list of unique symbols naming what a change to this property affects. ECSS records the list for consumers; it does not interpret it. |
| `:initial` | The property's initial value. It is normalized and validated once, when the package is created. |
| `:inherits` | A truthy value makes the property inherit its parent's value by default. |
| `:normalizer` | A function applied to the initial value at creation; defaults to `identity`. |
| `:validator` | A function that decides whether a concrete value is acceptable; defaults to one that accepts every value. |
| `:equality` | A function that decides whether two values of this property are equal; defaults to `equal`. |
| `:shorthand` | A function that expands one declaration of this property into longhand declarations. |
| `:aliases` | Alternate names, as unique symbols. Aliases exist only while declarations are normalized. |
| `:projections` | A list of unique symbols naming the projections a consumer derives from the property. ECSS records the list without interpreting it. |
| `:metadata` | Any caller data retained with the schema and returned by the lookup queries. |

A *schema package* is one owner's immutable registry: an identity plus a set of property definitions, validated and copied when the package is created. A *schema set* is the immutable composition of the packages one surface uses. Neither can be changed after creation, and there is no process-global registry: two applications, or one application's two surfaces, can compose different vocabularies in the same Emacs process without seeing or disturbing each other. Composition is explicit, so which vocabulary a computation sees is visible at the call site rather than accumulated from load order.

Aliases are a convenience at the declaration boundary only. A declaration may name a property by an alias, but normalization resolves it to the canonical identifier before cascade, and the rest of the engine carries canonical identifiers only. An alias therefore cannot shadow or override anything; it must be unique exactly where canonical identifiers are.

## Defining a package

`ecss-schema-package-create` turns a list of definitions into a package. Validation is strict and eager: a malformed definition, a duplicate identifier, or an alias collision rejects the whole call, so a package that exists is always internally consistent. The caller's definition list is copied, not retained, and the package is never re-validated afterwards.

#### Function: ecss-schema-package-create (package-id definitions)

Create immutable PACKAGE-ID schema registry from DEFINITIONS.

**Arguments.** PACKAGE-ID is a non-nil symbol that is not a keyword, such as `demo`. DEFINITIONS is a proper list of property definitions; each definition is a plist.

**Semantics.** Each definition is validated and copied. The identifier must be canonical, `:impacts` must be a nonempty list of unique symbols, `:aliases` and `:projections` are optional lists of unique symbols, and `:normalizer`, `:validator`, `:equality` and `:shorthand` must each be a function or nil. The definition may not contain an unknown key, repeat a key or end in a key without a value. The initial value is detached from the definition, normalized and validated once with the definition's normalizer and validator, and the result is stored; later computations reuse that stored value instead of running the normalizer again. All other mutable caller data is detached at this boundary too, while functions keep their identity. Two definitions may not share a canonical identifier, and an alias may not collide with another canonical identifier or alias of the same package. Zero definitions create an empty package, and the order of the definitions is retained.

**Returns.** The new package.

**Errors.** `error→ ecss-invalid-property-schema` with data `(:package-id PACKAGE-ID)` for an identity that is not a non-keyword symbol, `(:definitions DEFINITIONS)` when the list is not proper, `(:definition DEFINITION)` when an element is not a list, `(:property ID DEFINITION)` for a malformed definition, `(:KEY VALUE)` when a callable field is not a function, `(:invalid-initial VALUE)` when the validator rejects the initial value, `(:duplicate-property ID)` for a repeated identifier, and `(:collision NAME KIND EXISTING-KIND)` for an alias collision.

**Example.**

```elisp
(ecss-schema-package-property-ids
 (ecss-schema-package-create
  'demo '((:id demo/color :initial "black" :impacts (paint))
          (:id demo/gap :initial 0 :impacts (geometry) :aliases (gap)))))
     ⇒ (demo/color demo/gap)
```

**See also.** `ecss-schema-package-id`, `ecss-schema-package-property-ids`, `ecss-schema-set-compose`.

#### Function: ecss-schema-package-id (package)

Return the immutable identity of PACKAGE.

**Semantics.** The identity is the symbol the package was created with. It is what composition uses to detect a package that was supplied twice.

**Returns.** The package's identity symbol.

**Errors.** `error→ wrong-type-argument` naming the package predicate and the value when PACKAGE is not a package.

**See also.** `ecss-schema-package-create`, `ecss-schema-set-package-ids`.

#### Function: ecss-schema-package-property-ids (package)

Return the canonical property identifiers owned by PACKAGE.

**Semantics.** The identifiers come back in definition order, the order the definitions were given at creation. The returned list is fresh: changing it does not affect the package.

**Returns.** A list of canonical identifier symbols, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the package predicate and the value when PACKAGE is not a package.

**See also.** `ecss-schema-package-create`, `ecss-schema-set-property-ids`.

## Composing a schema set

A surface rarely owns every property it accepts. Composition joins the packages of several owners into one set, and the set is what `ecss-stylesheet-add-rule`, `ecss-expand-declarations` and `ecss-compute-style` later receive as their schema argument. Composition is all-or-nothing: if any package conflicts with the accumulated set, the call signals and the packages are left exactly as they were.

#### Function: ecss-schema-set-compose (&rest packages)

Compose immutable PACKAGES into one atomic schema set.

**Arguments.** PACKAGES is zero or more schema packages. Zero packages produce an empty set that still answers every query.

**Semantics.** Packages are applied from left to right. A package may appear only once; between packages, a canonical identifier or alias of the new package may not collide with a canonical identifier or alias already in the set, in either direction. The first conflict rejects the entire composition and leaves every input package unchanged. The composed set keeps the same immutable schemas the packages own rather than copying them; only the lookup indexes are built fresh. The composition order of the packages and, inside each package, the definition order are both retained.

**Returns.** A new schema set.

**Errors.** `error→ wrong-type-argument` naming the package predicate and the value when an argument is not a package; `error→ ecss-invalid-property-schema` with data `(:duplicate-package PACKAGE-ID)` for a repeated package and `(:collision NAME KIND EXISTING-KIND)` for an identifier or alias collision.

**Example.**

```elisp
(ecss-schema-set-property-ids
 (ecss-schema-set-compose
  (ecss-schema-package-create
   'demo '((:id demo/color :impacts (paint)) (:id demo/gap :impacts (geometry))))
  (ecss-schema-package-create
   'other '((:id other/size :impacts (geometry))))))
     ⇒ (demo/color demo/gap other/size)
```

**See also.** `ecss-schema-package-create`, `ecss-schema-set-canonical-id`, `ecss-schema-set-property`.

#### Function: ecss-schema-set-package-ids (schemas)

Return the package identities composed into SCHEMAS.

**Semantics.** Identities come back in the order the packages were passed to `ecss-schema-set-compose`. The returned list is fresh.

**Returns.** A list of package identity symbols, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the schema-set predicate and the value when SCHEMAS is not a schema set.

**See also.** `ecss-schema-set-compose`, `ecss-schema-set-property-ids`.

#### Function: ecss-schema-set-property-ids (schemas)

Return the property identifiers from SCHEMAS in registration order.

**Semantics.** Identifiers come back package by package, and inside each package in definition order, so the order is exactly the order in which the composed packages were created and passed. The returned list is fresh.

**Returns.** A list of canonical identifier symbols, possibly empty.

**Errors.** `error→ wrong-type-argument` naming the schema-set predicate and the value when SCHEMAS is not a schema set.

**See also.** `ecss-schema-package-property-ids`, `ecss-schema-set-compose`.

## Looking up properties in a schema set

The lookup queries resolve names to identifiers and hand out schema facts. They are the only way to read a schema through a set, and each returns detached data: a caller may mutate what it receives without changing the set or any computation that uses it.

#### Function: ecss-schema-set-canonical-id (schemas name)

Return the canonical property identifier for NAME in SCHEMAS, or nil.

**Semantics.** NAME may be a canonical identifier or an exact alias. Lookup compares symbols by identity; it does not fold case, coerce strings into symbols or accept a name that merely resembles an identifier. The result is the canonical identifier that declaration normalization and the cascade use, so callers use this query to answer which property a name denotes.

**Returns.** The canonical identifier symbol, or nil when NAME names no property in the set.

**Errors.** `error→ wrong-type-argument` naming the schema-set predicate and the value when SCHEMAS is not a schema set.

**Example.**

```elisp
(let ((schemas (ecss-schema-set-compose
                (ecss-schema-package-create
                 'demo '((:id demo/gap :impacts (geometry) :aliases (gap)))))))
  (list (ecss-schema-set-canonical-id schemas 'gap)
        (ecss-schema-set-canonical-id schemas 'demo/gap)
        (ecss-schema-set-canonical-id schemas 'nope)))
     ⇒ (demo/gap demo/gap nil)
```

**See also.** `ecss-schema-set-property`, `ecss-schema-set-property-metadata`, `ecss-expand-declarations`.

#### Function: ecss-schema-set-property (schemas id)

Return a defensive property schema copy for ID or alias in SCHEMAS.

**Semantics.** ID may be a canonical identifier or an exact alias. The returned copy carries the schema's facts — its identifier, initial value, inheritance flag, functions, aliases, impacts, projections and metadata — with every mutable part detached from the set, while functions keep their identity. Mutating the copy therefore cannot perturb the set, and two lookups return equal copies. Custom properties have no schema and yield nil here even though declarations may use them.

**Returns.** A property schema copy, or nil when ID names no property in the set.

**Errors.** `error→ wrong-type-argument` naming the schema-set predicate and the value when SCHEMAS is not a schema set.

**See also.** `ecss-schema-set-canonical-id`, `ecss-schema-set-property-metadata`.

#### Function: ecss-schema-set-property-metadata (schemas id)

Return detached property metadata for ID in SCHEMAS.

**Semantics.** ID may be a canonical identifier or an exact alias. Only the metadata is copied out; a caller that needs the rest of the schema facts uses `ecss-schema-set-property`. A property whose definition carried no metadata returns nil, as does an unknown name.

**Returns.** The property's metadata, detached, or nil.

**Errors.** `error→ wrong-type-argument` naming the schema-set predicate and the value when SCHEMAS is not a schema set.

**See also.** `ecss-schema-set-property`.

## Semantic details

<!-- index: eager validation; collision; defensive copy; registration order -->

Validation is eager and happens exactly once per definition. `ecss-schema-package-create` is the only place where definitions are checked, and composition checks only the identity and alias indexes, not the schemas again. Because a package that exists was valid when it was created and cannot be mutated afterwards, later operations can treat its facts as stable without re-checking them.

The `:initial` value crosses the boundary twice. At creation, ECSS first detaches the caller's object, then runs the normalizer on the detached copy, then validates the result and stores a detached copy of that. A normalizer therefore cannot retain a reference to the caller's data, and the stored initial never changes; computations that fall back to the initial value use the stored object, which is why the normalizer does not run again per computed style.

Collisions are rejected, not resolved. Inside a package, the canonical identifiers and all aliases form one namespace: a repeated identifier, an alias equal to its own or another identifier, and an alias equal to another alias each reject the package. Between packages, composition rejects a repeated package and any canonical/alias cross collision in either direction. There is no last-wins registration to depend on, so load order cannot silently change which property a name denotes. An application that needs two packages with the same name composes them under different owner identities, because the collision is on the full identifier, not on the slash-separated segments alone.

Order is part of the contract in two places. `ecss-schema-set-package-ids` returns the argument order of composition, and `ecss-schema-set-property-ids` returns the definition order inside each package flattened over that order. The computed-style readers iterate properties in this order, so a stable order gives stable output for the same schema set.

Lookups are cheap and exact. A set keeps two hash tables, one for canonical identifiers and one for aliases, so `ecss-schema-set-canonical-id` and the lookups built on it are constant-time symbol lookups with no parsing and no case handling. The queries that return data — identifiers, schema copies and metadata — copy only the small values the schema holds, never the whole package, which is what makes them safe to call from hot paths that only need one fact.

## Errors and recovery

<!-- index: error data; atomic failure -->

Creation and composition never publish a partial result. A rejected `ecss-schema-package-create` returns no package; a rejected `ecss-schema-set-compose` leaves every argument package intact and the caller's earlier sets untouched. Recovery is always to fix the offending value and call again — there is no half-built state to undo.

| Situation | Signal |
| --- | --- |
| A package identity is nil, a keyword, a string or a number | `error→ ecss-invalid-property-schema`, data `(:package-id VALUE)` |
| The definitions argument is not a proper list | `error→ ecss-invalid-property-schema`, data `(:definitions VALUE)` |
| A definition is not a list | `error→ ecss-invalid-property-schema`, data `(:definition VALUE)` |
| The identifier is missing, unnamespaced or empty on either side of the slash | `error→ ecss-invalid-property-schema`, data `(:property ID DEFINITION)` |
| An option key is unknown, repeated, or lacks its value | `error→ ecss-invalid-property-schema`, data `(:property ID DEFINITION)` |
| `:impacts` is missing, empty, not all symbols or contains duplicates | `error→ ecss-invalid-property-schema`, data `(:property ID DEFINITION)` |
| `:aliases` or `:projections` is not a unique list of symbols | `error→ ecss-invalid-property-schema`, data `(:property ID DEFINITION)` |
| A callable field is neither nil nor a function | `error→ ecss-invalid-property-schema`, data `(:KEY VALUE)` |
| The validator rejects the initial value | `error→ ecss-invalid-property-schema`, data `(:invalid-initial VALUE)` |
| Two definitions share an identifier | `error→ ecss-invalid-property-schema`, data `(:duplicate-property ID)` |
| An alias collides with an identifier or alias of the same package | `error→ ecss-invalid-property-schema`, data `(:collision NAME KIND EXISTING-KIND)` |
| A composition repeats a package | `error→ ecss-invalid-property-schema`, data `(:duplicate-package PACKAGE-ID)` |
| Two packages' identifiers or aliases collide | `error→ ecss-invalid-property-schema`, data `(:collision NAME KIND EXISTING-KIND)` |
| An argument is not a package, or SCHEMAS is not a set | `error→ wrong-type-argument` naming the expected predicate and the value |

A malformed package leaves nothing behind: the definitions were copied only after validation succeeded, so the caller's list is untouched as well. The same holds for aliases and metadata — they are detached only when the whole package is accepted.
