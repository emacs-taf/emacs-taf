# Tree Queries

Once a tree is built and mounted, a program reads it back through queries: which node is the root, which children a node has, where a box sits, which characters a node painted, and which node owns a buffer position. Most queries are pure tree navigation that works on a detached tree as well as a mounted one; the position and span queries need layout and, for buffer spans, a live mount. This chapter documents all of them. [Node Construction](ebox-node-construction.md) built the nodes and [Mount and Lifecycle](ebox-mount-lifecycle.md) mounted them; [Rendering Model](rendering-model.md) defines the coordinate system the geometry queries report in, and [Incremental Updates and Publication](incremental-updates-and-publication.md) explains when those values change.

## The tree model

<!-- index: node tree; parent and children; document order; buffer position; border box -->

A node's place in the tree is its parent and its position among that parent's children. The root has no parent, every other node has exactly one, and document order is the depth-first, left-to-right order in which a walk visits nodes. A node knows its root, its parent, its siblings through the parent, and its children in order; the queries never mutate the tree, and the list a query returns is a fresh copy that the caller owns.

Two coordinate systems meet here. Geometry is layout's: pixels horizontally, root lines vertically, relative to the root's border box, and it only exists for nodes that have been laid out — mounted, or rendered with `ebox-render` as in [Mount and Lifecycle](ebox-mount-lifecycle.md). Buffer positions are Emacs's: character positions in the mounted text, which depend on how wide the positioned content is and therefore belong to one specific mount. A node that has never been laid out answers nil to geometry; a node that is not in a live mount answers nil to the buffer-span and hit-test queries. The queries that only walk the tree — parents, children, order, ancestry — need neither.

## Tree structure

#### Function: ebox-node-root (node)

Return the root of NODE's tree.

**Semantics.** The search walks parent links to the top, so for a detached node it returns the node itself. Together with `ebox-node-parent` it lets a query start from any node, such as one found by `ebox-node-at`, and reach the tree that owns it.

**Returns.** The root node.

**Errors.** None.

**See also.** `ebox-node-parent`, `ebox-node-buffer`.

#### Function: ebox-node-buffer (node)

Return the buffer showing NODE, or nil.

**Semantics.** NODE's root is asked which mount feeds it, and that mount's buffer is returned when it is still live. The result is nil for a detached tree, for a tree that was rendered but never mounted, and after the mount is released. It answers "where is this node right now" for code that received a node without the buffer.

**Returns.** The buffer, or nil.

**Errors.** None.

**See also.** `ebox-node-root`, `ebox-buffer-mount`.

#### Function: ebox-node-parent (node)

Return NODE's parent node, or nil for a root or detached node.

**Semantics.** The parent link is what tree walks and ancestry tests follow. A node that was detached from a tree reports nil again, and the next query that reaches it treats it as a root.

**Returns.** The parent node, or nil.

**Errors.** None.

**See also.** `ebox-node-root`, `ebox-node-children`, `ebox-node-index`.

#### Function: ebox-node-children (node)

Return NODE's children as a fresh list.

**Semantics.** The list is a copy: adding to it, removing from it or mutating its cells does not change the tree. A leaf — a text node, or an empty container — returns nil. The order is document order, so the result lines up with the order layout and painting use.

**Returns.** The list of child nodes.

**Errors.** None.

**See also.** `ebox-node-child`, `ebox-node-child-count`, `ebox-node-walk`.

#### Function: ebox-node-child (node index)

Return NODE's child at INDEX, or nil when INDEX is out of range.

**Semantics.** INDEX is zero-based; a negative index and an index at or past the child count both return nil. It is the direct way to reach a known position, for example the second child of a form written by hand.

**Returns.** The child node, or nil.

**Errors.** None.

**See also.** `ebox-node-children`, `ebox-node-child-count`.

#### Function: ebox-node-child-count (node)

Return the number of NODE's children.

**Semantics.** A leaf answers 0. The count reads the retained sequence directly, so it is cheaper than taking the length of `ebox-node-children` when only the number matters.

**Returns.** The child count.

**Errors.** None.

**See also.** `ebox-node-children`, `ebox-node-child`.

#### Function: ebox-node-index (node)

Return NODE's position among its parent's children, 0 for a root.

**Semantics.** The index is zero-based and follows the node through structural changes: after `ebox-node-move` it reports the new position, and a detached node reports 0 again. It is the inverse of `ebox-node-child` for a node that is already in hand.

**Returns.** The index, or 0 for a root or detached node.

**Errors.** None.

**See also.** `ebox-node-child`, `ebox-node-move`.

#### Function: ebox-node-ancestor-p (ancestor node)

Return non-nil when ANCESTOR is NODE or one of its ancestors.

**Semantics.** The test includes the node itself, so it answers a question such as "is this box inside that panel" with the panel equal to the node counting as inside. It walks parent links from NODE upward and is the tree-level counterpart of the geometric containment an overlay hit test performs.

**Returns.** Non-nil when the relation holds.

**Errors.** None.

**See also.** `ebox-node-parent`, `ebox-node-root`.

#### Function: ebox-node-text-p (node)

Return non-nil when NODE is a text node.

**Semantics.** The test is on the node's tag, so it works without layout. It distinguishes the leaves that carry the visible string from the containers and from image nodes, and it is how a walk labels what it visited.

**Returns.** Non-nil for a text node.

**Errors.** None.

**See also.** `ebox-node-walk`, `ebox-node-children`.

#### Function: ebox-node-walk (node function)

Call FUNCTION on NODE and its descendants in document order.

**Semantics.** The walk is pre-order: each node is visited before its children, and a node's whole subtree is visited before its next sibling. FUNCTION receives one node per call and its result is ignored. The walk starts at NODE, not at the root, so it visits a subtree; because it recurses on the tree, its depth follows the tree's nesting depth. It is the general visit-everything query — collecting tags, counting text nodes, applying a test to a subtree.

**Returns.** nil.

**Errors.** None from the walk itself; an error in FUNCTION propagates unchanged.

**See also.** `ebox-node-children`, `ebox-node-text-p`.

## Geometry

#### Function: ebox-node-geometry (node)

Return NODE's border box as a plist (:x :y :width :height).

**Semantics.** The plist reports the border box in layout coordinates: `:x` and `:width` in pixels, `:y` and `:height` in root lines. It is available once the node has been laid out, which happens at render or mount; before that, and for a node whose tree was never laid out, the answer is nil. A text node reports geometry when it is laid out as its own layout item, such as a direct child of a `row` or `column`; a text node whose line layout is owned by an anonymous paragraph held by its `box` has no border box of its own and answers nil, and its painted run is what `ebox-node-bounds` reports instead. The values are a snapshot of the current layout: a mutation that relayouts the node changes them at the next flush.

**Returns.** The plist, or nil when NODE is not laid out or is a text node owned by an anonymous paragraph.

**Errors.** None.

**Example.**

```elisp
(let* ((root (ebox-build '(column :width (px 40)
                                  (box :height (lh 1) "head")
                                  (box :height (lh 2) "body"))))
       (first (ebox-node-child root 0))
       (second (ebox-node-child root 1)))
  (let ((ebox-viewport-width 40))
    (ebox-render root))
  (list (ebox-node-geometry first)
        (ebox-node-geometry second)))
     ⇒ ((:x 0 :y 0 :width 40 :height 1) (:x 0 :y 1 :width 40 :height 2))
```

**See also.** `ebox-node-root-line`, `ebox-node-bounds`.

#### Function: ebox-node-root-line (node)

Return the root line of NODE's border-box top, or nil when not laid out.

**Semantics.** This is the vertical position alone, the same value as the `:y` of `ebox-node-geometry` without building the plist. Use it to sort nodes by their vertical position or to test whether two nodes start on the same row. Like geometry, it answers nil for a node that is not laid out and for a text node whose line layout is owned by an anonymous paragraph.

**Returns.** The root line as an integer, or nil.

**Errors.** None.

**Example.**

```elisp
(let* ((ebox-viewport-width 40)
       (root (ebox-build '(column :width (px 40)
                                  (box :height (lh 1) "head")
                                  (box :height (lh 2) "body"))))
       (second (ebox-node-child root 1)))
  (ebox-render root)
  (ebox-node-root-line second))
     ⇒ 1
```

**See also.** `ebox-node-geometry`.

## Painted spans

#### Function: ebox-node-bounds (node &optional all-lines)

Return (START . END) buffer positions of NODE's first painted line.

**Arguments.** NODE is a box or text node. ALL-LINES non-nil extends END to the end of NODE's last painted line instead of its first.

**Semantics.** The query needs a live mount: a detached node, or one whose mount was released, has no buffer positions and answers nil. For a text node the span is the node's first painted run of characters; for a box it is the span of its first border-box line, from its first cell that an overlay does not cover to its right edge on that line — which can include blank fill after the visible glyphs. With ALL-LINES the span covers every painted row of a multi-line box. A box whose first line is entirely covered by overlays answers nil, a `:visibility hidden` box in flow still reports its blank slot, and a hidden or unplaced absolute box has no span. These positions are valid for the current text; a later flush can move them, so code that must survive updates stores nodes, not positions.

**Returns.** The `(START . END)` cons, or nil when NODE owns no cells in a live mount.

**Errors.** None.

**Example.**

```elisp
(let ((ebox-viewport-width 40))
  (let* ((buffer (ebox-render-to-buffer
                  "*panel*" '(column :width (px 40)
                                     (box :height (lh 1) "head")
                                     (box :height (lh 2) "body long"))))
         (first (ebox-node-child (ebox-buffer-root buffer) 0))
         (text (ebox-node-child first 0)))
    (list (ebox-node-bounds first) (ebox-node-bounds text)
          (ebox-node-bounds first t))))
     ⇒ ((1 . 6) (1 . 5) (1 . 6))
```

**See also.** `ebox-node-position`, `ebox-node-at`, `ebox-node-geometry`.

#### Function: ebox-node-position (node)

Return the buffer position of NODE's first painted character, or nil.

**Semantics.** The value is the CAR of `ebox-node-bounds`, so it inherits every rule of that query: it exists only in a live mount, it points at the first cell the node painted, and it moves when the text changes.

**Returns.** The buffer position, or nil.

**Errors.** None.

**Example.**

```elisp
(let ((ebox-viewport-width 40))
  (let* ((buffer (ebox-render-to-buffer
                  "*panel*" '(column :width (px 40)
                                     (box :height (lh 1) "head")
                                     (box :height (lh 2) "body long"))))
         (first (ebox-node-child (ebox-buffer-root buffer) 0)))
    (ebox-node-position first)))
     ⇒ 1
```

**See also.** `ebox-node-bounds`, `ebox-node-at`.

#### Function: ebox-node-at (&optional position buffer-or-name)

Return the innermost node painted at POSITION in BUFFER-OR-NAME.

**Arguments.** POSITION defaults to point; BUFFER-OR-NAME defaults to the current buffer.

**Semantics.** The query turns a buffer position back into the node a user would think they clicked on. A position inside a text node resolves to that text node; a position on a blank cell inside a box — padding, a slot, fill — resolves to the innermost box covering it, following paint order so overlays win over what they cover. It is the predicate behind hit testing and the counterpart of `ebox-node-bounds`: bounds turns a node into positions, this turns a position back into a node. The buffer must hold a mounted tree, and the answer is a snapshot of the current layout.

**Returns.** The innermost node at POSITION, or the best match available, or nil when nothing covers it.

**Errors.** None for positions inside the buffer; a buffer without a mount yields nil.

**Example.**

```elisp
(let ((ebox-viewport-width 40))
  (let* ((buffer (ebox-render-to-buffer
                  "*panel*" '(box :height (lh 1) "head")))
         (root (ebox-buffer-root buffer))
         (text (ebox-node-child root 0)))
    (eq (ebox-node-at 2 buffer) text)))
     ⇒ t
```

**See also.** `ebox-node-bounds`, `ebox-node-position`, `ebox-node-text-p`.

## How the entries work together

The structure queries turn any node into the facts a program needs about its place: the root it belongs to (`ebox-node-root`), the buffer showing it (`ebox-node-buffer`), its parent, children, index and ancestry, whether it is text, and a walk over its subtree. They are pure tree reads — no layout, no mount, no mutation — and the fresh children list means a caller can hold the result while the tree changes.

The geometry queries add layout facts for boxes, and the span queries connect those facts to the buffer. `ebox-node-geometry` and `ebox-node-root-line` report where a box is; `ebox-node-bounds` reports the characters it painted, `ebox-node-position` the start of that span, and `ebox-node-at` walks back from a position to a node. Used together they support the common tasks: find the box under point, scroll a named node into view, highlight the text of a row, or check that a mutation really moved what it should have.

## Semantic details

<!-- index: query cost; position staleness; hit test -->

Tree queries are cheap and allocation-light: parent and index reads are constant time, child access goes through the retained sequence without copying more than the requested node, and `ebox-node-walk` is the one query that touches every node of its subtree. Its recursion uses the Lisp stack, so its depth is the tree's depth.

Geometry and spans are snapshots. Geometry reflects the last layout; a mutation that changes it takes effect at the next flush, and reading it before that returns the previous values. Buffer spans and hit tests reflect the current text, and every update can move positions: the layout shifts rows, painting rewrites lines, and a position that pointed at a node's first character can point elsewhere or at nothing. Code that holds a node and re-queries its bounds after an update is stable; code that caches positions across updates is not.

Box spans and text spans differ on purpose. A text node's span is exactly its painted run, so it ends at the last glyph. A box's first-line span reaches its right edge, which on a stretched box includes the blank fill and can end far after the visible content; when the goal is "the characters of this row", query the text node or use `all-lines` on the box. The overlay rules follow paint: a box covered entirely by a higher overlay owns no visible cells and reports no bounds, while a hidden-in-flow box still owns its blank slot and reports it.

## Errors and recovery

The queries themselves signal nothing; they answer nil for the states they cannot describe. A nil answer means one of: no parent (a root), no children (a leaf), out of range (an index), not laid out (geometry, root-line), or not in a live mount (buffer, bounds, position, at). Passing nil or a non-node where a node is expected is a type error, not an `ebox-error`, so callers should check the node they hold.

Recovery is a re-read. If geometry is nil, render or mount the tree, or wait for the flush that lays it out. If bounds are nil for a node you expect to see, check whether an overlay covers it or whether its mount was released. After a structural or text update, ask the queries again rather than reusing a stored position — the node is the stable handle, the numbers are not.
