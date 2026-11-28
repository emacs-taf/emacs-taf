# Subjects and Adapters

A selector matches a *subject*: a node with a type, an ID, classes, attributes, states and a position in a tree. [Selectors](selectors.md) defines the language that reads those facts; this chapter defines the objects that carry them. There are two ways to supply a subject. A simple caller builds subjects with `ecss-subject-create` and links them with `ecss-subject-set-children`; a host that already has its own node type adapts it with `ecss-subject-adapter-create`, so the tree stays the host's and ECSS reads it through seven callbacks. Every selector query and the [stylesheet interface](ecss-stylesheets-and-scopes.md) accept either form: a built-in subject on its own, or a host node together with its adapter.

## Model

<!-- index: subject; subject field; tree link; adapter; host-owned node; boundary copy -->

A subject carries seven facts, and the matcher reads no others. Type and ID identify it, classes and states are token lists, attributes is an alist, and parent and children place it in a tree. These are the same seven facts [Selectors](selectors.md) defines; here the question is where a fact comes from. Every subject has exactly one owner: the built-in subject owns the values it was created with, and an adapter leaves them with the host node.

A built-in subject is a mutable record. `ecss-subject-create` fills it from keyword arguments and detaches the caller's data, and the accessors read the fields back. The parent and children fields are the exception to "set once": the tree links change while a program works, and `ecss-subject-set-children` is the interface that changes them. A subject's identity is the object itself, so tree relationships and scope membership compare subjects by identity, not by their fields.

An adapter describes how to read a host's own nodes. It holds seven callbacks and no data of its own:

| Callback | Returns |
| --- | --- |
| `type` | The node's type, compared against type selectors. |
| `id` | The node's ID, or nil. |
| `classes` | A list of class tokens. |
| `attributes` | An attribute alist. |
| `states` | A list of state tokens. |
| `parent` | The node's parent, or nil for a root. |
| `children` | The node's ordered children. |

The engine traverses a host tree only through the parent and children callbacks, so the host keeps its representation: it never copies a node, never wraps it in a subject, and never has to change its own type. The price is that every fact read during matching is a callback call, and the callbacks must keep returning the same objects for the same positions while a match or query runs.

## Building a subject

`ecss-subject-create` is the constructor for a tree the caller is happy to build in ECSS's own subject type. It takes the seven facts as keywords and returns a subject; a program can build a whole tree in one call by naming children and parents.

#### Function: ecss-subject-create (&key type id classes attributes states parent children)

Create a generic subject.

**Arguments.** TYPE and ID identify the subject and may be any values. CLASSES and STATES are token lists, ATTRIBUTES an alist. PARENT is an existing subject or nil. CHILDREN is a list of existing subjects, or nil.

**Semantics.** The five data fields are detached from the caller's objects with a deep copy, so later mutation of the strings and lists passed in cannot change the subject. The links are built after that: SUBJECT's own CHILDREN are set exactly as given, and then, when PARENT is non-nil, SUBJECT is appended to PARENT's current children. The two link arguments need not agree — passing PARENT is what makes the new subject reachable from the tree, and passing CHILDREN is what gives it a subtree. Nothing else is validated: CLASSES and STATES are expected to be token lists and ATTRIBUTES an alist, but ECSS stores what it is given and interprets the values only when matching.

**Returns.** The new subject.

**Errors.** `error→ wrong-type-argument` when PARENT is neither nil nor a subject, or when a CHILDREN element is not a subject; the data names the subject predicate and the offending value.

**Example.**

```elisp
(let* ((label (ecss-subject-create :type "span" :classes '("label")))
       (button (ecss-subject-create :type "button" :id "save"
                                    :children (list label))))
  (list (and (ecss-selector-match-p "button > span.label" label) t)
        (eq (ecss-subject-parent label) button)))
     ⇒ (t t)
```

**See also.** `ecss-subject-set-children`, `ecss-subject-adapter-create`, `ecss-selector-match-p`.

## Reading a subject

Each field has an accessor. The accessors read the field the subject stores; they are not setters and are not limited to one field, so they are also what the built-in subject's default adapter calls. Reading a field costs one slot access, which is why matching over built-in subjects is cheap.

#### Function: ecss-subject-type (x)

Return the type field of subject X.

**Semantics.** The value is what `ecss-subject-create` stored, detached from the caller's original at creation. The matcher compares it with a type selector using `equal`, so a string or a symbol both work.

**Returns.** The stored type, or nil.

**Errors.** `error→ wrong-type-argument` naming the subject type and X when X is not a subject.

**See also.** `ecss-subject-id`, `ecss-subject-create`.

#### Function: ecss-subject-id (x)

Return the ID field of subject X.

**Semantics.** The value is compared with an `#id` selector using `equal`. Attribute selectors do not read this field — a plain subject's ID is not automatically an `id` attribute — so a caller that needs `[id=…]` adds the ID to the attribute alist, and an adapter that wants both returns it from both callbacks.

**Returns.** The stored ID, or nil.

**Errors.** `error→ wrong-type-argument` naming the subject type and X when X is not a subject.

**See also.** `ecss-subject-type`, `ecss-subject-attributes`.

#### Function: ecss-subject-classes (x)

Return the class token list of subject X.

**Semantics.** A class selector matches when its name is a member of the list. The accessor returns the subject's own list rather than a copy, as do the other data accessors; treat the result as read-only and create a new subject when the metadata must change.

**Returns.** The stored list of class tokens, or nil.

**Errors.** `error→ wrong-type-argument` naming the subject type and X when X is not a subject.

**See also.** `ecss-subject-states`, `ecss-subject-attributes`.

#### Function: ecss-subject-attributes (x)

Return the attribute alist of subject X.

**Semantics.** Attribute selectors read this alist, and the pseudo-classes `:lang` and `:dir` look up inherited `lang` and `dir` entries through it. The list is the subject's own; treat it as read-only.

**Returns.** The stored attribute alist, or nil.

**Errors.** `error→ wrong-type-argument` naming the subject type and X when X is not a subject.

**See also.** `ecss-subject-id`, `ecss-subject-classes`.

#### Function: ecss-subject-states (x)

Return the state token list of subject X.

**Semantics.** A state pseudo-class matches when its token is a member of the list. A host that computes states dynamically updates them outside the subject object or exposes them through an adapter, so the built-in list is the fixed set an author deliberately recorded.

**Returns.** The stored list of state tokens, or nil.

**Errors.** `error→ wrong-type-argument` naming the subject type and X when X is not a subject.

**See also.** `ecss-subject-classes`, `ecss-subject-parent`.

#### Function: ecss-subject-parent (x)

Return the parent of subject X, or nil.

**Semantics.** The field is maintained by `ecss-subject-create` and `ecss-subject-set-children`. A subject that was never linked, or whose previous parent replaced its children, has no parent; the topmost subject of a detached tree also has none, which is what the `:root` pseudo-class tests.

**Returns.** The parent subject, or nil.

**Errors.** `error→ wrong-type-argument` naming the subject type and X when X is not a subject.

**See also.** `ecss-subject-children`, `ecss-subject-set-children`.

#### Function: ecss-subject-children (x)

Return the child list of subject X.

**Semantics.** The list is ordered as it was supplied and is the subject's own list, not a copy; positional pseudo-classes and combinators read it in that order. Treat the result as read-only and change the tree with `ecss-subject-set-children`.

**Returns.** The stored list of child subjects, or nil.

**Errors.** `error→ wrong-type-argument` naming the subject type and X when X is not a subject.

**See also.** `ecss-subject-parent`, `ecss-subject-set-children`.

## Linking subjects

Tree links are replaced, not edited in place. `ecss-subject-set-children` takes the complete new child list, detaches the subjects that used to be children, and attaches the new ones, so moving a subject between parents is one call and no link can go stale in the middle.

#### Function: ecss-subject-set-children (subject children)

Replace SUBJECT's CHILDREN and maintain their parent links.

**Arguments.** SUBJECT is a subject. CHILDREN is a list of subjects; an empty list or nil clears the children.

**Semantics.** The call first clears the parent of every current child whose parent is SUBJECT, then stores a copy of CHILDREN and, for each new child, removes it from its previous parent's child list and points its parent at SUBJECT. The old and new lists overlap freely: calling the function with different orders, or with a child that already had another parent, both work and leave exactly one parent link per child. Any existing parent link outside the subject's current children is not the function's business, so a program that mutates the lists returned by the accessors can still corrupt the tree; the supported path is this function. It also performs no cycle check, and a caller is responsible for keeping the result a tree.

**Returns.** SUBJECT.

**Errors.** `error→ wrong-type-argument` when SUBJECT is not a subject or a CHILDREN element is not a subject; the data names the subject predicate and the offending value.

**Example.**

```elisp
(let* ((row (ecss-subject-create :type "row"))
       (first (ecss-subject-create :type "cell"))
       (second (ecss-subject-create :type "cell" :parent row)))
  (ecss-subject-set-children row (list first second))
  (list (mapcar #'ecss-subject-type (ecss-subject-children row))
        (eq (ecss-subject-parent second) row)))
     ⇒ (("cell" "cell") t)
```

**See also.** `ecss-subject-create`, `ecss-subject-children`, `ecss-subject-parent`.

## Adapting host-owned trees

A host with its own node type does not build subjects at all. It writes seven callbacks, one per fact, and passes the adapter beside its node wherever a subject is expected. The node type stays private to the host, and the selector engine asks the adapter for every fact it needs, including the parent and child links it uses to traverse.

#### Function: ecss-subject-adapter-create (&key type id classes attributes states parent children)

Create a subject adapter from the supplied callbacks.

**Arguments.** TYPE, ID, CLASSES, ATTRIBUTES, STATES, PARENT and CHILDREN each accept one caller-owned subject and return the named field. Every callback is required.

**Semantics.** The seven callbacks are stored as given; creating the adapter calls none of them, and it copies no node. Each callback receives the host's own object — the same object the host passed as the subject — and its result is used directly, so the callback for a list-valued field must return a list and the parent and children callbacks must return the host's own parent and child objects for identity-based traversal to work. The callbacks may be called any number of times while a match, query or computation runs, and they are called again for each use; the adapter holds no cache and ECSS caches nothing per adapter. A host should not mutate the tree in a way that changes what the callbacks return while such an operation is in progress.

**Returns.** A new adapter.

**Errors.** `error→ ecss-invalid-subject-adapter` with the list of seven callback values when any of them is not a function; since omitted keywords are nil and nil is not a function, an adapter can never be created with a missing callback. An error signaled inside a callback propagates to the caller of the match or query unchanged.

**Example.**

```elisp
(let* ((adapter (ecss-subject-adapter-create
                 :type (lambda (node) (car node))
                 :id (lambda (node) (cadr node))
                 :classes (lambda (node) (caddr node))
                 :attributes (lambda (node) (nth 3 node))
                 :states (lambda (node) (nth 4 node))
                 :parent (lambda (node) (nth 5 node))
                 :children (lambda (node) (nth 6 node))))
       (root (list "div" "panel" '("app") nil nil nil nil))
       (child (list "span" nil '("label") nil nil root nil)))
  (setcar (nthcdr 6 root) (list child))
  (list (and (ecss-selector-match-p "div.app > span.label" child adapter) t)
        (and (ecss-selector-match-p "div:has(span)" root adapter) t)))
     ⇒ (t t)
```

**See also.** `ecss-subject-create`, `ecss-selector-match-p`.

## Semantic details

<!-- index: link maintenance; identity; callback cost; snapshot -->

Creation and linking answer different questions. `ecss-subject-create` answers "what fields does this subject have", and it snapshots the data fields so the subject is stable from the moment it exists. `ecss-subject-set-children` answers "where does this subject sit in the tree", and it is the only interface that rewrites links; the accessors that return lists are read-only views of the stored state, not setters.

The link rules are symmetric. A child can have one parent, and both directions describe the same edge: whenever the function attaches a child it also removes the child from its previous parent, and whenever it detaches a former child it also clears that child's parent. Within one call the order is fixed — old links are cleared before new ones are attached — which is why replacing children with an overlapping list is safe. A subject may appear twice in the same child list, and the function does not reject it; likewise it does not detect a cycle, so a program that passes a subject its own descendant creates a loop that later traversal will follow.

Matching cost depends on the subject type. A built-in subject answers each fact with one slot read, and the tree traversal walks Lisp lists that are already in memory. An adapter pays one host callback per fact and per traversal step, so a host whose callbacks are cheap sees almost the same cost and a host that computes fields on the fly pays for each read. Neither form copies the tree: the built-in constructor copies only the caller's field values, and the adapter copies nothing at all.

Identity matters when a fact must match a specific object. Tree links and scope membership compare subjects with `eq`, so an adapter that rebuilds a wrapper object on every call breaks parent and sibling relationships even though its fields look correct. The host should return the object it actually holds in its tree.

## Errors and recovery

<!-- index: subject type error; adapter error -->

No rejected call leaves partial state behind: a failed constructor returns no subject, a failed link update changes nothing, and an invalid callback list produces no adapter. Recovery is to fix the argument and call again.

| Situation | Signal |
| --- | --- |
| PARENT is neither nil nor a subject | `error→ wrong-type-argument`, data naming the subject predicate and the value |
| A CHILDREN element is not a subject, in `ecss-subject-create` or `ecss-subject-set-children` | `error→ wrong-type-argument`, data naming the subject predicate and the value list |
| `ecss-subject-set-children` is given a non-subject SUBJECT | `error→ wrong-type-argument`, data naming the subject predicate and the value |
| An accessor is called on a non-subject | `error→ wrong-type-argument`, data naming the subject type and the value |
| A field value has the wrong shape for the selector that reads it | the match simply fails, or a type error from the code that reads the field; creation does not validate field shapes |
| An adapter callback is omitted or is not a function | `error→ ecss-invalid-subject-adapter`, data the list of seven callback values |
| An error is signaled inside an adapter callback | that error propagates unchanged from the match, query or computation |
