# Rule Files

A rule file is how a stylesheet travels outside Lisp: a `.ecss` file holds one ordered list of rules as inert data, and a tool or an application reads it back, validates its grammar, and mounts it with whatever schema it owns. The reader is deliberately separate from the cascade: reading a file never evaluates a value, never consults a schema, and never mounts anything. This chapter defines the file contract and the three functions around it. [Stylesheets, Scopes and Author Ownership](ecss-stylesheets-and-scopes.md) defines the object a validated list is added to; [Values](values.md) and [Selectors](selectors.md) define what the values and selectors inside the file mean once a schema is applied.

## Model

<!-- index: rule file; inert data; read stage; schema validation stage -->

A `.ecss` file contains exactly one Lisp expression: a list of rules. There is no quote and no wrapper form — the file is data, not code that builds data. Rules come in order, and comments and whitespace may surround the list.

A *rule* is `(SELECTOR PROPERTY VALUE ...)`. The selector is an ECSS selector string, each property is a non-nil symbol, and the items after it pair properties with values. The list may be empty (`nil` or `()`), which is a valid empty rule set, and a rule may have no declarations at all. Nothing in the file says which origin, layer or scope a rule belongs to; that is authoring information the stylesheet layer supplies when the list is added.

Reading happens in two stages, and the split is the point of the contract. The *read stage* parses the text and checks the grammar: one expression, proper lists, a string selector, symbol properties, an even declaration count. The *schema stage* happens later, when the rules are expanded against a schema set: only then are property names resolved and values validated. A rule file can therefore be read, stored and passed around in a process with no schema at all.

Values are never evaluated. The reader binds the read table so that `#.` is rejected outright, and a function or a form in a declaration is ordinary data that passes through unchanged. This is what makes reading safe: a rule file cannot run code, and a function value in a declaration keeps its identity until the consumer's `:value-resolver` chooses to evaluate it, as [Computed Style](ecss-computed-style.md) describes.

## Validating rules

`ecss-validate-rules` is the grammar check on an in-memory list. A caller that has already built rules with `list` or read them some other way uses it to get the same contract the file reader enforces.

#### Function: ecss-validate-rules (rules)

Validate ordered static RULES and return them without evaluating values.

**Arguments.** RULES is a proper list of `(SELECTOR PROPERTY VALUE ...)` rules. SELECTOR is an ECSS selector string; PROPERTY is a non-nil symbol. Empty lists and empty declarations are allowed.

**Semantics.** The call checks the list shape, each rule's shape and its declaration count, parses every selector through the selector engine, and verifies that each property is a non-nil symbol. It does not look at the values, does not resolve property names against any schema, and does not mutate the input; a valid call returns the very list it was given, so a caller can chain the result. Property names and values are validated later against the consumer's schema.

**Returns.** RULES itself.

**Errors.** `error→ user-error` "ECSS rules must be a proper list" when RULES is not a proper list; `error→ user-error` "Invalid ECSS rule: RULE" for a rule that is not a proper list, does not begin with a string, or has an odd declaration count; `error→ ecss-invalid-selector` when the selector parser rejects a selector; `error→ user-error` "ECSS property must be a non-nil symbol: VALUE" for a declaration whose property is not a non-nil symbol.

**Example.**

```elisp
(ecss-validate-rules '((".card" :color "red") ("& > .title")))
     ⇒ ((".card" :color "red") ("& > .title"))
```

**See also.** `ecss-read-rules`, `ecss-stylesheet-add-rule`.

## Reading source

`ecss-read-rules` turns a string — the contents of a file, or what an editor holds — into a validated rule list. It reads exactly one expression and refuses anything else.

#### Function: ecss-read-rules (source)

Read exactly one inert rule list from string SOURCE.

**Arguments.** SOURCE is a string. Comments and whitespace are allowed around the rule list.

**Semantics.** The reader parses one Lisp expression with evaluation of `#.` disabled, checks that the expression is the only one in the source, and passes the result through `ecss-validate-rules`. Nothing is evaluated: a declaration value that looks like a call is data, and a wrapper such as `'`, `styles` or `progn` fails validation because it is not a rule list. An empty source, or one that contains only comments, does not supply the required expression at all.

**Returns.** The validated rule list, possibly empty.

**Errors.** `error→ end-of-file` when SOURCE contains no expression; `error→ invalid-read-syntax` for `#.`; `error→ user-error` "ECSS source must contain one rule list" when a second expression follows; otherwise the errors of `ecss-validate-rules`, including `ecss-invalid-selector` for a bad selector.

**Example.**

```elisp
(ecss-read-rules "; header\n((\".card\" demo/color \"red\")) ; footer\n")
     ⇒ ((".card" demo/color "red"))
```

**See also.** `ecss-validate-rules`, `ecss-file-read`.

## Reading files

#### Function: ecss-file-read (file)

Read FILE as one inert rule list via `ecss-read-rules`.

**Arguments.** FILE is the path of a readable file.

**Semantics.** The function checks that FILE is readable, reads its contents into a temporary buffer and hands the text to `ecss-read-rules`, so a file has exactly the contract of a source string: one expression, no quote or styles wrapper, comments allowed, values inert, and the file's rule order preserved. No schema is consulted and nothing is mounted; the returned list is the same data a caller would pass to a stylesheet. The file name is only used for reading, so the same rules can come from any path.

**Returns.** The validated rule list, possibly empty.

**Errors.** `error→ user-error` "ECSS file is not readable: FILE" when FILE cannot be read; otherwise the errors of `ecss-read-rules`, including `end-of-file` for a blank file and `ecss-invalid-selector` for a bad selector.

**See also.** `ecss-read-rules`, `ecss-validate-rules`.

## Semantic details

<!-- index: error layering; read-eval; values retained -->

The grammar errors and the selector errors come from different layers, and the distinction is useful when a tool reports them. A shape problem — not a list, a rule whose head is not a string, an odd declaration count, a property that is not a symbol — is a `user-error` with a message that names the offending value. A selector problem is `ecss-invalid-selector` from the selector parser, with parser data such as the position that failed. And the two source-level problems are Lisp reading conditions: an empty input is `end-of-file`, while `#.` is `invalid-read-syntax`.

Reading is inert in both directions. Nothing checks that a property name is known: a file may name a property from any vocabulary, and whether it is legal is decided when the rules meet a schema set. Nothing evaluates a value: `#.` is disabled, a quoted form stays a list, and a function value is retained as a function so that a later `:value-resolver` can decide what to do with it. This makes a rule file a safe interchange format: it can be read from disk or received over a wire without granting the sender any execution.

The static list is not a stylesheet. It carries no origin, layer or scope, and it cannot be computed against on its own; a host adds it to a stylesheet, where the authoring parameters are supplied, and then mounts the stylesheet. Read, validate, add, mount — each step has one owner, and the file format stays a pure data contract.

## Errors and recovery

<!-- index: rule file errors; recovery -->

Every rejection leaves the caller with no partially applied state: validation returns a value or signals, reading creates no rules, and mounting is a separate step that has not happened yet. Recovery is to fix the file or the list and read again.

| Situation | Signal |
| --- | --- |
| RULES is not a proper list, or a rule is dotted | `error→ user-error` "ECSS rules must be a proper list" |
| A rule is not a list, does not start with a string, or has an odd declaration count | `error→ user-error` "Invalid ECSS rule: RULE" |
| A selector cannot be parsed | `error→ ecss-invalid-selector` with parser data |
| A property is nil or not a symbol | `error→ user-error` "ECSS property must be a non-nil symbol: VALUE" |
| The source contains no expression (empty or comments only) | `error→ end-of-file` |
| The source contains a second expression | `error→ user-error` "ECSS source must contain one rule list" |
| The source uses `#.` | `error→ invalid-read-syntax` |
| The source has an outer quote, `styles` or other wrapper | `error→ user-error` "Invalid ECSS rule: …" |
| FILE is not readable | `error→ user-error` "ECSS file is not readable: FILE" |
| FILE is a directory | `error→ file-error` from the file system read |
