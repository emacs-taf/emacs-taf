# Errors

ECSS is a pure computation library, and that shapes its error contract: a call either returns a value or signals, with no buffer or global state left half-changed. The conditions it signals are part of the public API and form one family with a single base, so a caller can catch everything ECSS rejects with one handler. This chapter collects the conditions, says which layer raises each one, describes the data that explains a failure, and gives the recovery for each. The individual chapters document the errors of their own entries; this chapter explains the family behind them. [Values](values.md) and [Selectors](selectors.md) define the grammars being checked, [Stylesheets, Scopes and Author Ownership](ecss-stylesheets-and-scopes.md) and [Computed Style](ecss-computed-style.md) define the objects that are rejected, and [Rule Files](ecss-rule-files.md) describes the `user-error` and reader conditions that sit outside this family.

## The error hierarchy

<!-- index: error condition; condition hierarchy; error data -->

`ecss-error` descends from `error` and is the condition for a rejected ECSS operation: the caller asked for something the input cannot support. Five conditions descend from it, one per layer of the vocabulary.

| Condition | Parent | Called for |
| --- | --- | --- |
| `ecss-error` | `error` | A public ECSS operation rejected its input |
| `ecss-invalid-selector` | `ecss-error` | Selector text or a selector AST is malformed or unsupported |
| `ecss-invalid-subject-adapter` | `ecss-error` | An adapter callback is missing or not a function |
| `ecss-invalid-property-schema` | `ecss-error` | A package or property definition is malformed, or a composition collides |
| `ecss-invalid-declaration` | `ecss-error` | A declaration names an unknown property, breaks a grammar or drops a conflict |
| `ecss-invalid-rule` | `ecss-error` | A rule, origin, layer or source combination is invalid |

Two other kinds of failure stay outside the family. A *type* error is an ordinary `wrong-type-argument` naming the expected predicate and the value, such as a non-stylesheet passed where a stylesheet is required; it is not an ECSS condition because it says the caller used the wrong kind of object, not that the operation rejected a well-typed one. And a *rule file* fails through `user-error` for its grammar and through the Lisp reader conditions `end-of-file` and `invalid-read-syntax` for its source, as [Rule Files](ecss-rule-files.md) describes. A handler for `ecss-error` therefore catches every ECSS-level rejection but not a wrong argument type or a syntax error in a file.

## Conditions

#### Error: ecss-error

The base condition for a rejected ECSS operation.

**Semantics.** The condition is signaled when an entry point is given input it cannot use. Its data is a list whose first element is a description; the condition's own message is "ECSS error", and `error-message-string` combines them, as in `ECSS error: "…"`. Every condition in the family inherits this shape, so a handler can report any of them the same way.

**Recovery.** The rejected call applied nothing: ECSS has no partial state to roll back. Fix the input and call again.

**Example.**

```elisp
(condition-case err
    (signal 'ecss-error '("example failure"))
  (ecss-error (error-message-string err)))
     ⇒ "ECSS error: \"example failure\""
```

**See also.** `ecss-invalid-selector`, `ecss-invalid-property-schema`, `ecss-invalid-rule`.

#### Error: ecss-invalid-selector

The selector grammar or a selector AST is invalid.

**Semantics.** The parser, the normalizer, the matcher and the locality classifier all raise this condition before matching anything. The data locates the problem: a parser failure carries a keyword and a position, such as `(:expected-compound 3)`, `(:unclosed-string)`, `(:unclosed-comment)`, `(:attribute-flag FLAG)`, `(:invalid-nth-of ARGUMENT)`, `(:unterminated-relative)` or `(:pseudo-elements-unsupported)`; a structured AST that fails validation carries the offending AST, such as `(:unknown value)`; and a selector string that cannot be read at all carries the string. A malformed selector in a stylesheet or a rule list surfaces here too, because those paths normalize through the same parser.

**Recovery.** Fix the selector text or AST. Nothing was added to a stylesheet, no match was attempted, and no scope was created.

**See also.** `ecss-selector-parse`, `ecss-selector-normalize`, `ecss-invalid-rule`.

#### Error: ecss-invalid-subject-adapter

A subject adapter cannot be built.

**Semantics.** `ecss-subject-adapter-create` requires all seven callbacks — type, id, classes, attributes, states, parent and children — to be functions. The data is the list of the seven callback values as received, so a caller can see exactly which position is missing or wrong. An omitted keyword is nil, and nil is not a function, so a partial adapter is never created.

**Recovery.** Supply all seven callbacks and create the adapter again. No adapter exists until the call succeeds, and the host tree was not touched.

**See also.** `ecss-subject-adapter-create`, `ecss-compute-style`.

#### Error: ecss-invalid-property-schema

A package or property definition is malformed, or a composition cannot be formed.

**Semantics.** `ecss-schema-package-create` and `ecss-schema-set-compose` raise this condition for every structural problem: `(:package-id VALUE)` for a bad package identity, `(:definitions VALUE)` and `(:definition VALUE)` for malformed lists, `(:property ID DEFINITION)` for a definition that breaks the identifier, option, impacts, aliases or projections grammar, `(:KEY VALUE)` for a callable field that is not a function, `(:invalid-initial VALUE)` when the validator rejects the initial value, `(:duplicate-property ID)` for a repeated identifier, `(:collision NAME KIND EXISTING-KIND)` for a package-internal or cross-package name collision, and `(:duplicate-package PACKAGE-ID)` for a package supplied twice.

**Recovery.** Fix the definition or drop the colliding package, then create the package or compose again. The rejected call stored nothing and left every input package untouched.

**See also.** `ecss-schema-package-create`, `ecss-schema-set-compose`.

#### Error: ecss-invalid-declaration

A declaration cannot be used as written.

**Semantics.** Declaration handling raises this condition in several shapes. An unknown property is `(:unknown-property NAME)`; a declaration list that is not an even property/value list is `(:declarations VALUE)`; a canonical longhand produced twice by one declaration source — directly or through a shorthand — is `(:duplicate-property PROPERTY :first-source FIRST :second-source SECOND)`; a shorthand whose expansion is malformed is `(:shorthand SHORTHAND DECLARATIONS)` or `(:nested-shorthand SHORTHAND PROPERTY)`; an unknown CSS-wide kind is `(:wide-value KIND)`; and a variable reference whose name is not a custom property is `(:custom-property NAME)`. Inline declarations in `ecss-compute-style`, declaration expansion and merging, `ecss-wide-value` and `ecss-var` all raise the same condition, so a caller can handle all declaration problems in one place.

**Recovery.** Fix the property name, the value list or the conflicting declaration. Expansion and merging are pure, and computation stores nothing when it rejects the input.

**See also.** `ecss-expand-declarations`, `ecss-merge-declarations`, `ecss-wide-value`, `ecss-var`.

#### Error: ecss-invalid-rule

A rule, an origin, a layer or a source combination is invalid.

**Semantics.** The rule layer raises this condition when a rule cannot be accepted: `(:origin ORIGIN)` for an unknown cascade origin, `(:layers LAYERS)` for a layer list with a nil entry or a non-list, `(:rule RULE)` for an object supplied as a rule that is not one, and — when a rule list is replayed through `ecss-compute-style` — `(:source-order RULE)`, `(:declarations RULE)` or `(:shorthand-snapshot PROPERTY)` for a snapshot whose internal facts are inconsistent. Supplying both a stylesheet and a rule list is `(:stylesheet-and-rules)`. A selector problem inside a rule is reported as `ecss-invalid-selector` instead, because the parser owns that grammar.

**Recovery.** Fix the rule or the option and try again. Adding a rule is atomic: a rejected addition leaves the rule list, the layer orders and the source-order counter as they were, and a rejected computation produced no style.

**See also.** `ecss-stylesheet-add-rule`, `ecss-stylesheet-declare-layers`, `ecss-compute-style`.

## Where errors come from

<!-- index: trigger matrix; layer ownership -->

Each layer owns one condition, and that makes the condition name a quick way to tell where a problem is. The table lists the common triggers; the chapter of the entry named in the middle column documents the full contract.

| Trigger | Condition | Raised by |
| --- | --- | --- |
| Selector text or AST that the grammar rejects | `ecss-invalid-selector` | `ecss-selector-parse`, `ecss-selector-normalize`, `ecss-selector-match-p`, `ecss-selector-subject-local-p`, selector use in rules |
| Fewer than seven functions in an adapter | `ecss-invalid-subject-adapter` | `ecss-subject-adapter-create` |
| Bad package identity, definition, collision or duplicate | `ecss-invalid-property-schema` | `ecss-schema-package-create`, `ecss-schema-set-compose` |
| Unknown property, malformed list, duplicate canonical, bad wide value or variable name | `ecss-invalid-declaration` | `ecss-expand-declarations`, `ecss-merge-declarations`, `ecss-wide-value`, `ecss-var`, inline declarations |
| Bad origin, bad layer list, non-rule in a rule list, both sources supplied | `ecss-invalid-rule` | `ecss-stylesheet-add-rule`, `ecss-stylesheet-declare-layers`, `ecss-compute-style` |
| Wrong kind of object for an argument | `wrong-type-argument` | every typed entry point, naming the expected predicate |
| Rule file grammar and file problems | `user-error`, `end-of-file`, `invalid-read-syntax` | `ecss-validate-rules`, `ecss-read-rules`, `ecss-file-read` |

## Recovery

<!-- index: recovery; atomicity -->

Recovery follows the ownership rule. When a selector is rejected, fix the selector; when a package or composition is rejected, fix the definitions; when a declaration is rejected, fix the declaration; when a rule is rejected, fix the rule or its options. Because every one of these calls validates before it stores, a rejected call changes nothing — there is no partially added rule, no half-composed schema set, and no computed style to discard. A handler that wants to distinguish an invalid input from a type mistake catches `ecss-error` for the former and `wrong-type-argument` for the latter; a handler that wants to report everything catches `error`, which covers both, and the file readers' conditions as well.
