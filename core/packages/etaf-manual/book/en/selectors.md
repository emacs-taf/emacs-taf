# Selectors

A *selector* decides which subjects a style rule applies to and which nodes a query finds. The selector language is CSS-like but owns its own semantics: ECSS parses, matches and scores selectors, and Ebox exposes every retained node as a subject, so the same selector text drives both the style cascade and direct tree queries. This chapter defines the subject model, the selector language from type, ID, class and attribute selectors through pseudo-classes and combinators to `&` and `:scope`, how specificity is computed, and the functions that parse, validate, match and query. The subject and adapter objects themselves belong to [Subjects and Adapters](ecss-subjects-and-adapters.md); the use of selectors in the cascade is described in [The Style System](style-system.md).

## Subjects

<!-- index: subject; Ebox node as subject -->

A *subject* is the thing a selector matches. The matcher reads seven facts from a subject: a type, an ID, a list of class tokens, an attribute alist, a state token list, a parent and an ordered list of children. ECSS can match its own subject values or adapt a caller's tree; a style rule and a tree query therefore run the same matcher over the same facts.

Ebox exposes each retained node as a subject, so the selector vocabulary maps directly onto the node model:

| Fact | Ebox node source |
| --- | --- |
| Type | the tag name: `text`, `box`, `row`, `column`, `flex`, `grid`, `image` |
| ID | the node's `:id` |
| Classes | the node's `:class` tokens; a string splits on whitespace, a symbol names one class |
| Attributes | the node's attributes, plus the node's `id` and its View key |
| States | the node's author states, plus the derived `disabled`, `focus` and `active` |
| Tree | the retained parent and children |

Type names, IDs and class tokens are compared case-sensitively. An ID and a key are also exposed as the attributes `id` and `key`, so `[id=…]` and `[key=…]` match values that a `#…` selector cannot spell; a plain ECSS subject keeps its ID and classes as separate fields, and an attribute selector reads only its attribute alist.

States are a token set, not node metadata a clause sets at will. Ebox derives `disabled` from the Host's `:disabled`, and `focus` and `active` from the focused or pressed node of a mounted buffer; a node also carries author states, which `ebox-node-set-states` replaces. The three derived names cannot be authored. A function-shaped pseudo-class that the matcher does not know, such as `:my-state(on)`, matches only when the state set contains the literal entry `("my-state" "on")`, so a host can expose its own states through the same mechanism.

## Selector syntax

<!-- index: selector syntax; compound selector; selector list -->

A selector is a list of complex selectors separated by commas; a subject matches the list when it matches any item. Every complex selector is a chain of compound selectors joined by combinators, and a compound selector is one or more simple selectors written without whitespace: a type or `*`, `#id`, `.class`, an attribute selector or a pseudo-class.

### Type, ID and class

<!-- index: type selector; ID selector; class selector; universal selector -->

A type selector such as `text` matches the node's tag name, `#save` matches the node's ID, and `.primary` matches one class token. `*` is the universal selector and matches every subject. Two simple selectors in one compound must all match, so `text.primary#print` matches only a `text` node that has both the class and the ID. Type, ID and class names are case-sensitive.

An ID written as `#…` must be a selector identifier: letters, digits and escapes, with the punctuation that the selector grammar reserves. For any other value, write an attribute selector instead, such as `[id="save button"]`.

### Attributes

<!-- index: attribute selector; attribute operator -->

An attribute selector tests one attribute. There are seven forms: presence, and six operators, each optionally followed by a case flag:

| Form | Matches |
| --- | --- |
| `[name]` | the attribute is present, whatever its value |
| `[name=value]` | the value is exactly `value` |
| `[name~=value]` | the value is a whitespace-separated list containing `value` |
| `[name\|=value]` | the value is `value` or begins with `value-` |
| `[name^=value]` | the value begins with `value` |
| `[name$=value]` | the value ends with `value` |
| `[name*=value]` | the value contains `value` |

The value is a bare identifier or a quoted string, so values with spaces or punctuation can be written. By default every comparison is case-sensitive; the flag `i` compares without case and the flag `s` states the default explicitly, as in `[data-kind=commit i]`. The attribute name is always case-sensitive. A present-but-nil attribute matches a presence selector; it only fails an operator selector unless the operator compares against an empty value.

### Pseudo-classes

<!-- index: pseudo-class; state pseudo-class; structural pseudo-class; positional pseudo-class -->

A pseudo-class refines the subject, written with one colon. A plain state pseudo-class such as `:hover` or `:disabled` matches when the state set contains that token; pseudo-class names are compared without case, so `:HOVER` is the same as `:hover`. Ebox supplies `disabled`, `focus` and `active`, plus the author states; a host adapter can supply any other tokens.

Structural pseudo-classes match the subject's position among its siblings and read the tree: `:first-child`, `:last-child`, `:only-child`, `:empty` (no children), `:root` (no parent), and the per-type forms `:first-of-type`, `:last-of-type` and `:only-of-type`, which compare the type of the siblings.

Positional pseudo-classes take an argument: `:nth-child(2n+1)`, `:nth-last-child(1)`, `:nth-of-type(2)` and `:nth-last-of-type(odd)`. The argument is an `An+B` expression: an integer, `odd`, `even`, or a form such as `2n`, `2n+1`, `-n+3`. The two child forms also accept an `of` filter that first reduces the sibling list to the subjects matching a selector, as in `:nth-child(2 of .item)`; the `-of-type` forms do not accept a filter.

The metadata pseudo-classes `:lang(en)` and `:dir(ltr)` read an attribute that is inherited: the matcher looks for `lang` or `dir` on the subject and then on each ancestor. `:lang` matches when the value is equal, ignoring case, or when it begins with the requested language and a hyphen; `:dir` matches the value exactly, ignoring case. Pseudo-elements with `::` are not supported.

**Example.** A list can mark exactly one row through a positional pseudo-class; the second item is rendered in the rule's color.

```elisp :run
(etaf-define-component demo-selector-pick ()
  :view (column
         (text :class "item" "alpha")
         (text :class "item" "beta")
         (text :class "item" "gamma"))
  :styles (("& .item:nth-child(2)" :color "#B45309")))
(etaf-view (demo-selector-pick))
```

### Logical pseudo-classes

<!-- index: is; where; not; has; relative selector -->

`:is(SELECTORS)` matches when any of its arguments matches, `:where(SELECTORS)` does the same and contributes no specificity, and `:not(SELECTORS)` matches when none of its arguments matches. All three accept a full selector list, so complex selectors such as `:is(div > .label, .badge)` are valid inside them.

`:has(SELECTORS)` matches when the subject has a relative target: a descendant, or a following sibling or a descendant of a following sibling, that matches one of the relative selectors. A relative selector may begin with `>`, `+` or `~` to state the relationship to the subject, and the relationships may chain: `:has(> .row)`, `:has(+ .hint)`, `:has(~ .note)` and `:has(+ .row .cell)` are all valid. `:has` never looks at preceding siblings.

### Combinators

<!-- index: descendant combinator; child combinator; sibling combinator -->

Four combinators join compound selectors. Whitespace is the descendant combinator and matches any ancestor; `>` is the child combinator and matches the parent; `+` is the adjacent-sibling combinator and matches the immediately preceding sibling; `~` is the general-sibling combinator and matches any preceding sibling. For example, `box > .row .item` matches an `.item` below a `.row` whose parent is a `box`, and `button + button` matches a button that directly follows another button.

### & and :scope

<!-- index: scope root; & selector; :scope -->

A selector may name the root of the scope it is evaluated in: both `&` and `:scope` match that root. Inside a Component's `:styles` rules or an `.ebox` file's local rules the scope root is the node the scope is attached to, so `&` styles that node itself while `&.active` styles it only while it matches, and `:scope > .row` styles its direct children.

A rule selector that does not name the scope root is anchored to the scope: it is matched as a descendant of the root, so `.title` picks a node inside the scope and never the root itself. The scope and the rules written for it are the subject of [Component Styles and Themes](component-styles-and-themes.md).

Outside a scope there is no root to name, so `&` and `:scope` match nothing in a plain `ecss-selector-match-p` call or an `ebox-selector-query`; they become meaningful only while a scoped stylesheet is being matched.

```elisp :figure Class selectors in a Component's rules: .item styles every row, .item.selected the selected row, and .item .marker the text inside a row
(etaf-define-component demo-selector-list ()
  :styles ((".item" :padding ((lh 0) (ch 1)) :background-color "#f6f8fa")
           (".item.selected" :background-color "#dbeafe")
           (".item .marker" :color "#0969da" :font-weight bold))
  :view
  (column :width '(ch 44) :item-gap '(lh 0)
          (row :class "item" (text "普通行"))
          (row :class "item selected" (text "选中行"))
          (row :class "item" (text :class "marker" "标记文字"))))
(etaf-view (demo-selector-list))
```

## The selector interface

<!-- index: selector AST; selector validation -->

A selector crosses the Lisp interface either as its source text or as a parsed value, the *AST*. `ecss-selector-parse` turns text into an AST, `ecss-selector-normalize` validates and copies an AST, `ecss-selector-match-p` matches one subject, and `ecss-selector-specificity` scores one selector. Parsing is a separate step because an AST can be stored once and matched many times, and the stylesheet objects of the cascade keep their rule selectors in this form.

#### Function: ecss-selector-parse (selector)

Parse CSS-like SELECTOR text into a structured selector AST.

**Arguments.** SELECTOR is a non-empty string. The accepted language is the selector syntax above: selector lists, compound selectors, type, `#id`, `.class`, `*`, attribute selectors with the six operators and the `i` and `s` flags, state, structural, positional and metadata pseudo-classes, `:is`, `:where`, `:not` and `:has` with relative selectors, the four combinators, `&`, `:scope`, backslash escapes and `/* */` comments.

**Semantics.** The result is data. A compound selector becomes `(:and ITEM ...)`; a combinator becomes `(:descendant LEFT RIGHT)`, `(:child LEFT RIGHT)`, `(:adjacent LEFT RIGHT)` or `(:sibling LEFT RIGHT)`; an ID is `(:id "save")`, a type `(:type "text")`, a class `(:class "item")`, an attribute `(:attr "name" "=" "value" nil)`, `*` is `(:universal)` and `&` is `(:scope-root)`. A pseudo-class becomes `(:state "hover")`, `(:state ("nth-child" "2n+1"))` or `(:state ("nth-child" "2n+1" FILTER))`; the logical forms become `(:is ...)`, `(:where ...)`, `(:not ...)` and `(:has ...)`, with `:has` arguments anchored on the subject. Pseudo-class names are lowercased; type, ID, class and attribute names keep their case.

Parsing checks the selector grammar only, not every argument: an invalid `An+B` formula such as `:nth-child(2x)` parses and only fails when the AST is validated or used. Comments and whitespace are skipped, and `::` pseudo-elements are rejected.

**Returns.** The AST as fresh list structure.

**Errors.** `error→ ecss-invalid-selector` when SELECTOR is not a string, is empty, has unbalanced parentheses or an unterminated string or comment, contains a pseudo-element, an unknown attribute flag, an unexpected character or a trailing escape; the condition data names the failure, such as `(:pseudo-elements-unsupported)`, `(:attribute-flag "x")` or `(:unclosed-string)`.

**Example.**

```elisp
(ecss-selector-parse "div.app > #save:hover")
     ⇒ (:child (:and (:type "div") (:class "app"))
               (:and (:id "save") (:state "hover")))
```

**See also.** `ecss-selector-normalize` and `ecss-selector-match-p`.

#### Function: ecss-selector-normalize (selector)

Return a validated defensive AST for string or structured SELECTOR.

**Arguments.** SELECTOR is a selector string or an AST.

**Semantics.** A string is parsed first; then the full AST is validated: every form carries the right number of arguments, type, ID and class names are non-empty, attribute selectors use one of the known forms, positional arguments are valid `An+B` expressions and an `of` filter appears only on the child forms. The result is a copy that shares no mutable structure with the input, so a caller can keep and modify the returned AST without changing the selector it was made from. Matching, specificity and the cascade accept an already-normalized AST and re-validate it.

**Returns.** The validated AST.

**Errors.** `error→ ecss-invalid-selector` when the selector is invalid; the condition data is the offending AST or string.

**Example.**

```elisp
(ecss-selector-normalize "&.active")
     ⇒ (:and (:scope-root) (:class "active"))
```

**See also.** `ecss-selector-parse`.

#### Function: ecss-selector-match-p (selector subject &optional adapter)

Return non-nil when SELECTOR matches SUBJECT through optional ADAPTER.

**Arguments.** SELECTOR is a selector string or an AST. SUBJECT is any value the adapter can read. ADAPTER is an optional subject adapter; when it is omitted, the built-in adapter reads the subjects created by `ecss-subject-create`.

**Semantics.** The call validates SELECTOR, parses it when it is a string, and matches it against SUBJECT using the rules of this chapter: type, ID and class equality, the seven attribute forms with their case flags, state, structural, positional and metadata pseudo-classes, the logical forms, and the combinators. A string is parsed on every call, so a caller that matches the same selector many times should parse it once and pass the AST.

`:scope` and `&` match only while a scope root or a relative-selector anchor is active; a plain call from application code has neither, so they match nothing there. Type, ID and class comparisons are case-sensitive; the `i` attribute flag and the `:lang` and `:dir` pseudo-classes compare without case.

**Returns.** A non-nil value when SUBJECT matches and nil otherwise; the value need not be `t`.

**Errors.** `error→ ecss-invalid-selector` when SELECTOR is invalid. `error→ wrong-type-argument` when ADAPTER is not a subject adapter.

**Example.**

```elisp
(let ((subject (ecss-subject-create
                :type "button" :classes '("primary") :states '("hover"))))
  (ecss-selector-match-p "button.primary:hover" subject))
     ⇒ t
```

**See also.** `ecss-selector-parse`, `ecss-selector-normalize` and `ebox-selector-match-node-p`.

## Specificity

<!-- index: specificity; ID count; class count; type count -->

The *specificity* of a selector is an `(ID CLASS TYPE)` triple that the cascade compares after origin, importance and layer (see [The Style System](style-system.md#the-cascade-order)). An ID contributes to the first number, a class, attribute or pseudo-class to the second, and a type to the third; universal selectors and `&` contribute nothing. Sums appear when a selector has several parts, and the logical forms take the maximum of their arguments instead:

| Selector | Specificity |
| --- | --- |
| `#save` | `(1 0 0)` |
| `.item[data-kind]` | `(0 2 0)` |
| `text:hover` | `(0 1 1)` |
| `:is(.a, #b)` | `(1 0 0)` |
| `:where(#b)` | `(0 0 0)` |
| `:not(.a) .b` | `(0 2 0)` |
| `:has(> #save)` | `(1 0 0)` |

#### Function: ecss-selector-specificity (selector)

Return SELECTOR specificity as an (ID CLASS TYPE) list.

**Arguments.** SELECTOR is a selector string or an AST.

**Semantics.** A string is parsed and an AST validated, as by `ecss-selector-normalize`. A compound selector adds the contributions of its items; a combinator or the `:and` of a compound adds both sides; `:is`, `:not`, `:has` and a selector list take the maximum over their arguments; `:where` is zero; `:scope` counts as a pseudo-class; an `of` filter adds its own specificity to the class contribution of its positional pseudo-class.

**Returns.** A fresh three-element list of non-negative integers.

**Errors.** `error→ ecss-invalid-selector` when SELECTOR is invalid.

**Example.**

```elisp
(ecss-selector-specificity ":is(.a, #b) .x")
     ⇒ (1 1 0)
```

**See also.** [The cascade order](style-system.md#the-cascade-order).

## Querying the node tree

<!-- index: selector query; document order -->

The same selectors can be run over the retained tree instead of the cascade. `ebox-selector-query` finds the matches under one node, `ebox-selector-query-buffer` finds them under a mounted buffer's root, and `ebox-selector-match-node-p` tests a single node. Queries walk the tree in document order — a node before its children, siblings in order — and include the start node itself, so a query rooted at a node can return that node. Running a query never changes the tree or any style.

Because a query matches against the node tree, the Ebox states are visible: `:disabled` follows the `:disabled` property, and author states set with `ebox-node-set-states` are available. `:focus` and `:active` need the live state of a mounted buffer.

#### Function: ebox-selector-query (root selector)

Return ROOT's descendants-or-self matching SELECTOR in document order.

**Arguments.** ROOT is an Ebox node. SELECTOR is a selector string or an AST.

**Semantics.** The function walks ROOT and all its descendants in document order and collects every node that matches, including ROOT itself; the result has no duplicates. While matching, it binds the mount context of ROOT's tree when ROOT belongs to a mounted buffer, so mount-derived states are visible. `:scope` and `&` match nothing here because no scope is active for a bare query.

**Returns.** The list of matching nodes, in document order; an empty list when nothing matches. A node is returned once even when several of its ancestors are visited.

**Errors.** `error→ ecss-invalid-selector` when SELECTOR is invalid.

**Example.**

```elisp
(let ((root (ebox-build
             '(box
               (text :class "item" "A")
               (text :class "item" "B")))))
  (mapcar #'ebox-node-text-p (ebox-selector-query root ".item")))
     ⇒ (t t)
```

**See also.** `ebox-selector-query-buffer` and `ebox-selector-match-node-p`.

#### Function: ebox-selector-query-buffer (buffer-or-name selector)

Return nodes mounted in BUFFER-OR-NAME matching SELECTOR.

**Arguments.** BUFFER-OR-NAME is a buffer or a buffer name. SELECTOR is a selector string or an AST.

**Semantics.** The function takes the root mounted in BUFFER-OR-NAME and returns the result of `ebox-selector-query` on it. When the buffer has no mounted root the result is nil.

**Returns.** The list of matching nodes, in document order, or nil without a mounted root.

**Errors.** `error→ ecss-invalid-selector` when a root exists and SELECTOR is invalid.

**Example.**

```elisp
(let ((buffer (ebox-render-to-buffer
               "*items*"
               (ebox-build '(box
                             (text :class "item" "A")
                             (text :class "item" "B"))))))
  (mapcar #'ebox-node-text-p (ebox-selector-query-buffer buffer ".item")))
     ⇒ (t t)
```

**See also.** `ebox-selector-query`.

#### Function: ebox-selector-match-node-p (node selector)

Return non-nil when NODE matches structured or string SELECTOR.

**Arguments.** NODE is an Ebox node. SELECTOR is a selector string or an AST.

**Semantics.** The function matches the single node with the same adapter and matcher as the queries, so the whole selector language applies, including the Ebox state set. A string is parsed on every call.

**Returns.** A non-nil value when NODE matches and nil otherwise.

**Errors.** `error→ ecss-invalid-selector` when SELECTOR is invalid.

**Example.**

```elisp
(ebox-selector-match-node-p
 (ebox-text-create "Draft" '(:class "item")) ".item")
     ⇒ ("item")
```

**See also.** `ebox-selector-query` and `ecss-selector-match-p`.
