# Node Construction

Ebox is usable on its own: a program builds a retained node tree, mounts it in a buffer and mutates nodes in place, without ETAF, Views or Components. This part of the manual documents that standalone use. A tree comes into being here — `ebox-build` turns a compact author form into nodes, `ebox-node-create` builds one node at a time from Lisp, and `ebox-node-copy` duplicates a subtree from its current inputs. The [Mount and Lifecycle](ebox-mount-lifecycle.md) chapter mounts what is built here and the [Tree Queries](ebox-tree-queries.md) chapter reads it back; the [`.ebox` Files and Preview](ebox-files-and-preview.md) chapter reads trees from files and the [Errors](ebox-errors.md) chapter catalogues the conditions the API signals. [Rendering Model](rendering-model.md) describes the layout and paint that turn a constructed tree into text, and [Style Properties](style-properties.md) the style properties a node may carry.

## Model

<!-- index: retained node; node tag; author property; detached node; text node; selector identity -->

A node is a retained, mutable record. It has a tag, a list of author properties, zero or more children, and the state that layout and paint derive from them. The tag decides what the node is. `text` is a leaf that shows a string, `image` is a leaf that shows a prepared image, and `box`, `row`, `column`, `flex` and `grid` are containers that own children and arrange them in the ways [Boxes and Normal Flow](boxes-and-normal-flow.md) and the chapters after it describe. Containers own children; a text node has no children, and a string used where a child is expected becomes a text node.

A new tree is detached: no node has a parent and no tree has a mount. A detached tree can be rendered, inspected or copied; it comes under management when it is inserted into a parent or mounted. A node can have at most one parent, so the same subtree cannot appear in two places — duplicating it is what `ebox-node-copy` is for.

Author properties are the values a program supplies; everything else is derived. They fall into three groups. Style properties are all the properties [Style Properties](style-properties.md) defines for the node's tag, longhand or shorthand, together with `--` custom properties; a property outside the tag's domain is rejected at construction. Meta properties carry identity and structure:

| Meta property | Value and effect |
| --- | --- |
| `:id` | A string or symbol that `#id` selectors match. |
| `:key` | A token that `[key=NAME]` selectors match. |
| `:class` | A class name, or a list of names, that `.name` selectors match. |
| `:attributes` | An alist of extra `[NAME=VALUE]` selector attributes; symbol values are turned into their names. |
| `:states` | Author selector states as symbols or strings, matched by `:state` selectors; `disabled`, `focus` and `active` are derived and cannot be authored. |
| `:ecss` | Inline style rules, in the `(SELECTOR PROPERTY VALUE ...)` form [Selectors](selectors.md) and [Values](values.md) use. |
| `:ecss-file` | A file whose rules are read and installed as if written in `:ecss`. |
| `:ecss-scopes` | The scopes this node is a member of; created with `ebox-style-scope-create`. |
| `:ecss-scope-roots` | The scopes for which this node becomes a root. |
| `:defaults` | Default declarations for the node, applied at the user-agent origin. |
| `:image` | The prepared image an image leaf shows. |
| `:data` | Any value the application wants retained with the node. |

Interaction properties declare what the node responds to. Ebox reads `:help-echo`, `:pointer`, `:hover-style`, `:hover-content`, `:drag-lock-modifier` and `:hover-group` for pointer feedback, `:keymap` for key bindings, `:tab-index`, `:disabled`, `:focus-group` and `:focus-scope` for focus, and `:swipe` and `:scroll` for gestures and scrolling; the Interaction part documents each in the chapter that implements the behavior. The private properties `:content`, `:layout`, `:display` and `:ebox-type` belong to Ebox's internals: a program that writes them signals an error instead of silently perturbing layout.

## Building from author forms

An author form is ordinary Lisp data — a list whose head is a tag. `ebox-build` walks it depth-first and returns the detached tree its nodes form. This is the shape `.ebox` files and literal trees use, and the one to prefer when the whole tree is known at once.

#### Function: ebox-build (form)

Build a detached node tree from author FORM.

**Arguments.** FORM is a string, an existing node, or a list `(TAG PROPERTY VALUE ... CHILD ...)` with TAG among `text`, `box`, `row`, `column`, `flex` and `grid`.

**Semantics.** Each form is one node. Items are read left to right: a keyword such as `:width` or a `--` custom property starts a property and takes the next item as its value; everything else is a child, and children are built recursively. A quoted value inside the form is unwrapped once, so both `:class '(a b)` and `:class (a b)` name two classes, and a string child becomes a text node. A `text` form must carry exactly one child, a string; the `:ecss` and `:ecss-file` properties are accepted only on a Box form, where they install rules for the node and its subtree. A string, or a node already built, is returned as the tree itself, so a builder can splice subtrees together. Nothing is mounted or laid out: the result is an ordinary detached tree, ready for the next chapter.

**Returns.** The root node of the built tree, or FORM itself when it is already a node.

**Errors.** `error→ ebox-error` with a description when FORM is neither a string, a node nor a well-formed list — an unknown tag, a property without a value, a `text` form whose payload is not exactly one string, or an `:ecss` property on a text form.

**Example.**

```elisp
(let ((ebox-viewport-width 40))
  (ebox-render '(column :width (ch 10)
                        (text "Inbox")
                        (row :item-gap (ch 1) (box "open") (box "done")))))
     ⇒ "Inbox \nopen done "
```

**See also.** `ebox-node-create`, `ebox-text-create`, `ebox-render`.

## Programmatic construction

`ebox-node-create` builds one node from values the program already has. Reach for it when the tree shape is computed rather than written — a loop that produces rows, a node the program keeps a reference to, or a node of the `image` tag, which author forms do not cover.

#### Function: ebox-node-create (tag &optional props children)

Create a detached node of TAG with author PROPS and CHILDREN.

**Arguments.** TAG is one of `box`, `row`, `column`, `flex`, `grid`, `text` and `image`. PROPS is an author property plist, or nil. CHILDREN is a list of nodes or strings; a string becomes a text node.

**Semantics.** PROPS is split into the three groups of the model: style properties are validated against TAG and compiled once, meta properties set the node's identity and scopes, and interaction properties configure behavior. CHILDREN is attached in order; each child must be detached, and attaching the first child of a container fixes the container as that child's parent. A text node created this way carries no payload until `ebox-node-set-text` gives it one, or a string child creates it in one step. An image node takes its intrinsic size from its prepared image and accepts no style properties; pass the value from `ebox-image-prepare` as `:image`. Nothing is mounted or laid out here either.

**Returns.** The new detached node.

**Errors.** `error→ ebox-error` for an unknown TAG, a PROPS value that is not an even plist, a style property TAG does not accept, a private property, an interaction value outside its domain, or a child that already has a parent; a child that is neither a node nor a string is a type error.

**Example.**

```elisp
(let ((column (ebox-node-create 'column nil '("first" "second"))))
  (mapcar #'ebox-node-text-p (ebox-node-children column)))
     ⇒ (t t)
```

**See also.** `ebox-build`, `ebox-text-create`, `ebox-node-copy`.

```elisp :figure A box with one text child
(etaf-view
 (column :width '(ch 40) :item-gap '(lh 0)
   (box :padding '((lh 0) (ch 1))
        :background-color (etaf-theme-token :ui-accent-soft-bg "#ddf4ff")
     (text :color (etaf-theme-token :ui-accent "#0969da") "box  :padding 1"))
   (box :padding '((lh 0) (ch 4))
     (box :padding '((lh 0) (ch 1))
          :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
       (text :color (etaf-theme-token :ui-panel-fg "#1f2328") "text  子节点")))))
```

## Copying nodes

#### Function: ebox-node-copy (node)

Return a detached deep copy of NODE built from its current inputs.

**Semantics.** The copy is rebuilt from what NODE holds now: its current text or prepared image, its current author properties and its children, recursively. No mutable structure is shared with NODE, so later mutations of one tree do not appear in the other. Because a node may have only one parent, a copy is how the same current contents are used in a second place; a copy of a mounted subtree is detached and can be rendered as a snapshot. Copying preserves everything the constructor accepts — identity, states, scopes, interaction properties and, for an image node, the prepared image itself.

**Returns.** A new detached node.

**Errors.** None; NODE is assumed to be a node.

**Example.**

```elisp
(let* ((node (ebox-build "before"))
       (copy (ebox-node-copy node)))
  (ebox-node-set-text node "after")
  (ebox-render copy))
     ⇒ "before"
```

**See also.** `ebox-node-create`, `ebox-node-set-props`, `ebox-node-set-text`.

## How the entries work together

The two builders produce the same nodes; only the input style differs. `ebox-build` is the front end for data — `.ebox` files, literal trees, forms received from elsewhere — and its recursion turns strings into text nodes. `ebox-node-create` is the front end for code that composes nodes by hand, and `ebox-text-create` is its text-specific shorthand. A program that starts from either can grow the tree later with `ebox-node-insert`, change properties with `ebox-node-put` or `ebox-node-set-props`, and move or remove nodes, all of which [Incremental Updates and Publication](incremental-updates-and-publication.md) describes.

`ebox-node-copy` closes the two remaining gaps. It is the only way to place the same contents under two parents, and it is how a subtree that a program no longer wants to mutate is preserved while its original keeps changing. Copying a mounted subtree and rendering the copy is the standalone route to a snapshot.

## Semantic details

<!-- index: construction cost; declaration cache; user-agent origin -->

Construction is offline. No buffer is touched, no mount is queued and no viewport is consulted, so trees can be built anywhere — in batch, in a timer, or before a buffer exists. Layout starts at the first render or mount, which is why errors about size values that only layout can decide (a percentage resolved against a containing block, for example) surface later than errors about property names and grammar, which construction reports at once.

Property validation is cached. Each distinct `(tag . style-plist)` pair compiles to canonical declarations once and is reused afterwards, and equal inline `:ecss` rule lists share one compiled scope; a program that builds many similar rows pays for the first one only. The computed style itself is derived at layout, so construction does not compute colors or sizes.

`ebox-node-copy` costs what rebuilding the subtree costs: one node per node, with each node's properties recompiled through the same caches. It is cheap for a few nodes and proportional to the subtree for many, and it never shares the mutable parts of a tree — which is what makes it safe as a snapshot.

Two orders are worth remembering. Inside an author form, items are classified as properties and children strictly left to right, so a keyword in a child's place consumes the next item as its value; and a quoted value is unwrapped only one level, so a form that needs a list value can write the list directly or quote it once. A form is data first and a tree second: what the reader supplies is exactly what the builder sees.

## Errors and recovery

Construction never publishes a partial tree. A call either returns a complete detached node or signals; on the way out, already built nodes are dropped and the tree is unaffected, so a program can fix the form or property and retry without cleaning up a buffer.

| Situation | Signal |
| --- | --- |
| FORM is not a string, node or list, or a tag is unknown | `error→ ebox-error`, with the offending value |
| A property is missing its value | `error→ ebox-error "Missing value for"` |
| A `text` form has no string payload, or several children | `error→ ebox-error "Ebox text requires exactly one string payload"` |
| `:ecss` or `:ecss-file` on a text form | `error→ ebox-error "Ebox :ecss requires a Box form"` |
| PROPS is not an even plist | `error→ ebox-error "Properties must be an even plist"` |
| A private property is authored | `error→ ebox-error "Private Ebox property"` |
| A style property is outside the tag's domain | `error→ ebox-error` naming the tag and the rejected property |
| An interaction value is outside its domain | `error→ ebox-error` naming the option and what it requires |
| A child already has a parent | `error→ ebox-error "Ebox node already has a parent"` |
| A text node is given children | `error→ ebox-error "Ebox text nodes cannot contain children"` |
| A child is neither a node nor a string | a type error naming the constructor |
