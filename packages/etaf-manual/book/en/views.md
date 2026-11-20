# Views

A *View* is the description of what an ETAF application shows. It is written in one small structural language, normalized by `etaf-view` and lowered by the renderer into Ebox nodes: Components return Views, `etaf-mount` publishes one, and `etaf-render` lowers one without a Runtime. This chapter defines the language, the normalized values, when the expressions inside a View are evaluated, and the functions that build Views from Lisp.

A View is a description, not a live object: it owns no state and no buffer text by itself. Its dynamic parts read reactive sources, and [Reactivity](reactivity.md) defines when such a read causes another evaluation. Which Host kinds exist and which properties they accept belongs to [the Host chapter](hosts.md); Components, props and slots belong to [the Component chapter](components.md).

<!-- index: View; structural form; View value; expr; keyed list; fragment -->

## Model

### The structural form

Every node of a View — a Host or a Component call — is written as one form:

```elisp
(NAME :PROPERTY VALUE ... CHILD ...)
```

NAME is a Host symbol such as `text` or `column`, or the name of a Component defined by `etaf-define-component`. Properties are keyword/value pairs and must come before the first child; the children follow and are the content of the node. Property values are ordinary Elisp forms, not a quoted data language, so `(text :font-weight (if alert 'bold 'normal) "Hi")` is a valid node.

```elisp :figure A column, a title box and a two-box row
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (box :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
        :padding '((lh 0) (ch 2))
     (text :color (etaf-theme-token :ui-accent "#0969da")
           :font-weight 'bold "标题"))
   (row
    (box :width '(ch 20)
         :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
         :padding '((lh 1) (ch 1))
      (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "左子节点"))
    (box :width '(ch 20)
         :background-color (etaf-theme-token :ui-disabled-bg "#e5e7eb")
         :padding '((lh 1) (ch 1))
      (text :color (etaf-theme-token :ui-disabled-fg "#687386") "右子节点")))))
```

### View values

Writing a View form produces a *normalized View*: one of a small set of typed values.

| Value | Produced from |
| --- | --- |
| nil | the form nil, or an `expr` whose value is nil |
| a text View | a string in a child position, or an `expr` inside a `text` Host |
| a Host node | a call of a Host such as `box` or `row` |
| a Component call | a call of a registered Component |
| an expression region | `expr`, a conditional branch, or a keyed list |
| a slot request | a `slot` form inside a Component |

Only these values are Views. A plain list with the same shape, such as `('text "Hi")`, is data and renders nothing; that is why a View computed by Lisp must be built with `etaf-view` or `etaf-node` and wrapped as `(expr ...)` in a child position.

### When a View is evaluated

Three moments matter:

- **Compilation.** The first time `etaf-view` expands at a call site, the form is compiled into a reusable blueprint: literal parts become a static skeleton, and properties, `expr` forms, branch conditions, list sources, keys and slots become deferred programs.
- **Instantiation.** Evaluating the compiled call site constructs the View value. Literal subtrees come from a shared cache; dynamic parts become thunks that are evaluated later.
- **Rendering.** The renderer walks the View value: a Host node binds its properties, a Component call creates or updates an instance, an expression region evaluates its function, a branch chooses one arm, a keyed list reconciles its rows, and a fragment is flattened. Only here do dynamic property values, conditions, list sources and `expr` results run.

Consequently, writing or reading a View value never runs application expressions. Every reactive read those expressions make is tracked by the binding that runs them, as [Reactivity](reactivity.md) describes.

## The `etaf-view` macro

#### Macro: etaf-view (form &optional _environment)

Construct a normalized ETAF View from the structural FORM.

**Arguments.** FORM is an unquoted structural form in the grammar above. ENVIRONMENT is accepted and ignored; Emacs passes the macro environment when it eagerly expands top-level forms. Do not quote FORM: a quoted form is a misplaced Elisp expression and is rejected.

**Semantics.**

- The form is compiled once per call site and reused on every evaluation. Nested forms are compiled inside the same blueprint, so one call site produces one compiled unit.
- Literal properties and children are materialized once and shared between evaluations; every other expression is deferred to rendering.
- Names are resolved when the View is built: a symbol registered as a Component is accepted anywhere a Host is, and the resulting call follows the Component rules.
- `etaf-view` is the normal constructor for both hand-written nodes and the result of ordinary Elisp that must return a View.

**Returns.** A normalized View value: nil, a text View, a Host node, a Component call, an expression region or a slot request.

**Errors.** `error→ etaf-view-syntax-error` during expansion when the structure is malformed, for example a property after a child, a missing property value, a repeated property, an `expr` with more than one form, a `text` node without exactly one payload, or an incomplete branch or `for` form. `error→ etaf-component-call-error` while the View is built when evaluated values are invalid, for example an unknown name, a non-keyword property name or a duplicate property in code-built Views.

**Example.**

```elisp
(etaf-view (text :font-weight 'bold "Hi"))
;; ⇒ a text View ; display
```

**See also.** `etaf-node`, `etaf-render`, and the chapters on [Hosts](hosts.md), [Components](components.md) and [Runtime](runtime.md).

### Property values

A property value is an ordinary Elisp expression whose evaluation is deferred to rendering; it is not a quoted literal language.

- A literal — nil, t, a number, a string, a character, a keyword or a quoted form — is stored in the compiled unit and shared. It is never evaluated again.
- Any other expression becomes a thunk that runs when its node renders, in the lexical environment of the call site. The thunk can read lexical variables, Component props and reactive sources.
- A thunk that reads a reactive source makes that source a dependency of the resulting binding. A later write runs only the bindings that read the changed source, not the whole View.
- A bare symbol is looked up as a variable, so a symbol value must be quoted: write `'bold`, not `bold`.
- The same property must not appear twice and its name must be a keyword. In the structural language both are syntax errors; when a property list is built in Lisp they are call errors.

### Child positions

A child position accepts these forms:

| Form | Meaning |
| --- | --- |
| nil | nothing; this position produces no node |
| a string | one text View |
| a nested form | a Host node or a Component call |
| `(expr FORM)` | the View result of FORM, computed at rendering |
| `(slot ...)` | caller content for a default or named Component slot |

An ordinary Elisp expression is not a child: `(column (format "n=%d" n))` is rejected and must be written as `(column (expr (format "n=%d" n)))`. The rule keeps the boundary between structure and computation explicit, so the compiler can treat every other child as structure.

The value of an `expr` in a structural child position may be nil, a string, one typed View, or a proper list of such values; nested lists are flattened. Any other value, such as a number, signals `etaf-renderer-error` at rendering.

Two nodes restrict their children further: a `text` Host takes exactly one payload, and an `image` Host takes no children at all.

### `expr`

#### Syntax: expr (expr FORM)

Evaluate one ordinary Elisp form and use its View result in place of the form.

**Arguments.** FORM is exactly one ordinary Elisp form. It may read lexical variables and Component props, call functions and read reactive sources. It must not perform side effects: a ref write or the creation of a reactive object during rendering signals `etaf-render-side-effect-error`, as [Reactivity](reactivity.md#rendering-is-free-of-side-effects) explains.

**Semantics.** The form becomes a retained expression region with its own binding. The binding evaluates FORM when the region is first rendered and again after any source read by FORM changes; only this region is patched. Inside a `text` Host the result must resolve to text, so it accepts a string, nil for the empty string, or a proper list of strings, which are concatenated; any other value signals `etaf-renderer-error`.

**Returns.** The value of FORM. In a structural position that value must be a View or a proper sequence of Views, as described in [Child positions](#child-positions).

**Errors.** `error→ etaf-view-syntax-error` when the form does not hold exactly one expression. `error→ etaf-renderer-error` when the result cannot be shown in its position, for example a number in a structural position or a non-string payload in a `text` Host.

**Example.**

```elisp
(etaf-view (column (text (expr (format "%d items" (etaf-value count))))))
```

**See also.** [Reactivity](reactivity.md), which defines tracking and the phases in which regions run.

### Conditional branches

#### Syntax: :if (:if CONDITION)

Choose between alternative sibling nodes with `:if`, `:else-if` and `:else`.

**Arguments.** CONDITION is an ordinary Elisp expression evaluated at rendering. The first node of a chain carries `:if`; the following siblings carry `:else-if` with their own condition, or `:else` with the literal t. A chain has at most one `:else`, and it comes last.

**Semantics.** The conditions are evaluated in order until one is non-nil, and only that arm is built; conditions after the matching arm are not evaluated. Without a match and without an `:else`, the position shows nothing. The conditions are tracked reads, so a change re-chooses the arm.

Switching arms patches the region's children by identity: a node of the new arm whose identity matches a node of the previous arm is updated in place and keeps retained state, while the other nodes of the previous arm are released. Two arms that are Component calls of the same Component therefore share one instance across the switch unless keys separate them.

**Errors.** `error→ etaf-view-syntax-error` when a node carries more than one branch directive, when one node carries both a branch and `:for`, when `:else` is not the literal t, when `:else-if` follows an `:else`, when a chain has more than one `:else`, or when an `:else-if` or `:else` node has no preceding `:if`.

**Example.**

```elisp
(etaf-view (column (text :if online "Online")
                   (text :else t "Offline")))
```

### Keyed lists

#### Syntax: :for (:for (ITEM ITEMS) :key KEY)

Render one row per item of a list and retain rows across updates by KEY.

**Arguments.**

- The node carrying `:for` is repeated once per item. `(ITEM ITEMS)` binds ITEM, a plain symbol, in the properties and children of that node.
- ITEMS is an ordinary Elisp expression whose value must be a proper list.
- `:key` is required on the same node. It is an ordinary Elisp expression evaluated with ITEM bound; its value identifies the row and must be a non-nil symbol, integer or string.

**Semantics.**

- The list region evaluates ITEMS at rendering and builds one row per item from the node carrying `:for`. The region and its rows follow the ordinary reconciliation: rows whose key equals a retained row's key are reused, new keys build rows, and keys that disappeared release their rows.
- When the new item under a retained key is a different object, the row receives it through its item binding, so the row's properties, `expr` forms and Component state update to the new item instead of being rebuilt. An equal key is enough; the item need not be the same object.
- Keys must be unique within the list. A duplicate key signals `etaf-runtime-error` with the message `"Keyed Range keys must be unique"` and leaves the previous rows committed.
- A change that only appends or removes items near either end costs one comparison per unchanged row at that end plus the rows built or released, not a pass over the whole list.

**Errors.** `error→ etaf-view-syntax-error` when `:key` is absent, when the binding is not `(ITEM ITEMS)` with a plain symbol, when ITEM collides with a Component prop, or when a branch shares the node. `error→ etaf-component-call-error` when ITEMS does not evaluate to a proper list. `error→ etaf-runtime-error` for duplicate keys.

**Example.**

```elisp
(etaf-view (column (text :for (name names) :key name
                         (expr (symbol-name name)))))
```

### Fragments

#### Syntax: fragment (fragment CHILD ...)

Group children without adding a node to the layout.

**Arguments.** CHILD forms follow the ordinary child rules. A fragment accepts `:key` and the compiler directives `:if`, `:else-if`, `:else` and `:for`; it has no Ebox node, so other Host properties have no target.

**Semantics.** The renderer inserts the fragment's children into the enclosing layout in order, so a fragment adds nothing between parent and children and needs no styling. A Component whose render result is a fragment therefore keeps its content in the parent layout, which is how a Component returns several roots.

A fragment is identified by its `:key`, or, without one, by the call site it was compiled from. Two fragments written at two call sites are distinct even when their forms are equal; the same call site re-evaluated keeps its identity.

**Errors.** No error is specific to a fragment. Its children and directives are checked as for any other node.

**Example.**

```elisp
(etaf-view (column (fragment (text "a") (text "b")) (text "c")))
```

## Building Views in Lisp

#### Function: etaf-node (tag props children &optional named-slots)

Construct one typed View node from already evaluated ordinary Elisp values.

**Arguments.**

- TAG is an exact Host or Component symbol. There is no alias or fallback resolution.
- PROPS is a keyword plist. It must have even length and no repeated key. The compiler directives `:if`, `:else-if`, `:else` and `:for` belong to the structural language and are rejected.
- CHILDREN is a proper list of typed children: nil, strings, View values built earlier, expression regions and slot requests.
- NAMED-SLOTS is a Component-only alist mapping stable non-keyword symbols to child lists. A Host rejects it.

**Semantics.** `etaf-node` is the code-mode counterpart of a structural form: it applies the same validation to values that are already evaluated, which is what a render function or a programmatic builder needs. A `:key` property is validated here as well. For a Component the children become its default slot and NAMED-SLOTS its named slots; the caller's properties are partitioned into the Component's declared props and its Host attributes.

**Returns.** A typed View value, ready for `etaf-mount` or for a child position inside another View.

**Errors.** `error→ etaf-component-call-error` for a non-symbol TAG, a malformed or repeated property, a directive property, an invalid child, an invalid key, named slots on a Host, or an unknown TAG.

**Example.**

```elisp
(etaf-node 'row nil (list (etaf-node 'text nil (list "left"))
                          "right"))
```

**See also.** `etaf-view`, which constructs the same values from a structural form.

#### Function: etaf-render (view)

Lower a normalized VIEW to one canonical detached Ebox root without a Runtime.

**Arguments.** VIEW is a normalized View value, as returned by `etaf-view` or `etaf-node`.

**Semantics.**

- The whole View is evaluated once, in a render phase: a reactive write during rendering signals `etaf-render-side-effect-error`.
- Host class and id, a non-nil `:role` and explicitly supplied `:aria-*` attributes reach Ebox selector subjects. `:selector-attributes` and `:selector-state` are adapter facts and cannot be given as View properties.
- Components without `:setup` are supported. A Component with `:setup` needs a mounted Runtime, because its Scope must have a lifecycle owner; `etaf-render` signals `etaf-renderer-error` for it.

**Returns.** One detached Ebox root node. When the View produces several nodes, they are wrapped in one column root.

**Errors.** `error→ etaf-renderer-error` when the View cannot be shown: an unresolved child value, a text payload that is not text, children on an `image` Host, duplicate sibling keys, or a stateful Component. `error→ etaf-render-side-effect-error` for a reactive write during rendering.

**Example.**

```elisp
(etaf-render (etaf-view (text "Hi")))
;; ⇒ an Ebox text node ; display
```

**See also.** `etaf-mount` and [Runtime](runtime.md) for mounting and lifecycle.

## Semantic details

### Compilation and reuse

A structural form is compiled once per call site into a *blueprint*: a tree of literal nodes and property values, with a table of deferred programs for everything that must run at rendering — property thunks, `expr` bodies, branch conditions, list sources and key expressions, and slot requests. Evaluating the call site instantiates the blueprint.

- A subtree is static when every property and child in it is a literal. Static subtrees are materialized once and cached for the process, keyed by the compiled form, the position inside it and the Component registry generation. Re-evaluating the same call site, or another call site with an equal form, reuses those values instead of building them again.
- Defining or redefining a Component starts a new registry generation and discards the static caches, so a redefined Component is not served from a stale blueprint. An authoring tool that reloads a Component should dispose its Runtime first, as [the Component chapter](components.md) describes.
- A non-literal value makes its subtree dynamic: it is built on every evaluation, and a Host with a deferred property gets a retained binding that re-runs when the sources it read change.
- If the compiler is not loaded, `etaf-view` falls back to an equivalent direct expansion. Both paths accept the same forms and produce the same View values; the fallback exists for loading `etaf-view` alone.

### Identity

Reconciliation matches a parent's children to the children of the previous render by an identity key.

| Child | Identity |
| --- | --- |
| Host node | its tag and its `:key` |
| Component call | its Component and its `:key` |
| fragment | its `:key`, or its call site |
| `expr`, branch, keyed list | its call site |

An explicit `:key` must be a non-nil symbol, integer or string, and a string key is copied when the View is built. Explicit keys must be unique among the siblings of one parent; a duplicate signals `etaf-renderer-error`. Rows of a `:for` list are matched by their key values as described in [Keyed lists](#keyed-lists).

Because a key retains the instance and not the inputs, a reactive value that a View shows should be read inside the property or `expr` that shows it. A View that embeds a value into its structure instead produces a new structure on every change, which is still correct but rebuilds what a keyed read would have updated.

### Cost

- A fully static subtree costs one cache lookup per evaluation; its nodes and values are shared.
- A dynamic Host costs the evaluation of its property thunks and the patching of its own node and binding, not of unrelated parts of the View.
- A branch evaluates its conditions until the first match and materializes one arm.
- A keyed list reconciles only the middle that changed: unchanged rows at either end are skipped with one comparison each, and a retained key updates its row through the item binding.

## Errors and recovery

The View language raises three conditions, in one hierarchy: `etaf-view-syntax-error` and `etaf-component-call-error` are both subtypes of `etaf-view-error`.

#### Error: etaf-view-error

The base condition for an invalid View, with the message "Invalid ETAF View". It has no signaling site of its own: structural problems raise `etaf-view-syntax-error` and value problems raise `etaf-component-call-error`, so one handler for `etaf-view-error` catches either. Its data is the argument list given to the raising signal, usually one formatted message string.

#### Error: etaf-view-syntax-error

A structural form is malformed. The condition is raised while `etaf-view` expands, so the failing call site never evaluates and no View value is built. The data is a list holding one message string.

| Message | Cause |
| --- | --- |
| `"Attributes must precede children; found %S after a child"` | A property after the first child |
| `"Missing value for View property %S"` | A property without a value |
| `"Duplicate View property %S"` | The same property twice |
| `"Expr accepts exactly one form: (expr FORM)"` | An `expr` with zero or several forms |
| `"Text requires exactly one string or expr payload"` | A `text` Host with zero or several payloads |
| `":for requires an explicit :key"` | A keyed list without `:key` |
| `":for must be (ITEM ITEMS): %S"` | A malformed list binding |
| `":else requires literal t"` | An `:else` whose value is not the literal t |
| `"A View node accepts one branch directive"` | Several of `:if`, `:else-if` and `:else` on one node |
| `"Branch directives cannot share a node with :for"` | A branch and `:for` on one node |
| `"Orphan branch arm: %S"` | An `:else-if` or `:else` without a preceding `:if` |
| `"Elisp expression %S must be inside (expr FORM)"` | An unwrapped function call or special form in a child position |
| `"View children must be strings, nil, View forms, or expr results: %S"` | A child that is not a child form |

#### Error: etaf-renderer-error

A normalized View cannot be shown, or a mounted Runtime is required but absent. The data is a list holding one message string.

| Message | Cause |
| --- | --- |
| `"Unresolved View item: %S"` | An `expr` produced a value that is not a View, such as a number |
| `"Text payload must resolve to one string"` | A text payload is not a string, nil or a list of strings |
| `"Image Host takes no children"` | An `image` Host was given children |
| `"View has duplicate sibling key: %S"` | Two siblings carry the same `:key` |
| ``"Stateful Component requires `etaf-mount'"`` | `etaf-render` met a Component with `:setup` |
| `"Expected text, image, box, row, column, flex, or grid Host; received %S"` | A node reached the renderer with a name it cannot build |

### Recovery

| Failure | What remains |
| --- | --- |
| `etaf-view` rejects a form at expansion | Nothing is built; the call site does not evaluate |
| A View cannot be built from evaluated values | No View value is returned; an already published Runtime is unaffected |
| `etaf-render` fails | No node is returned and no buffer is touched |
| A failing update of a mounted Runtime | The committed buffer stays; the failed work is retried at the next drain or `etaf-runtime-flush`, as [Reactivity](reactivity.md#recovery) describes |

A malformed form is a programming error, not an input error: it is not catchable at the point where the application could recover, and it should be fixed in the source. Render-time errors from data are the ones an application can handle, and they leave the previous output committed.
