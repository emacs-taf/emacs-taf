# Focus

Keyboard focus in a mounted tree is one Host at a time, chosen by the user's navigation rather than by where the caret sits. It lives on the mount, not in the buffer text: Ebox records which node is focused and derives a `focus` selector state for it, while point follows for editing and mouse semantics. This chapter describes the focus state, the Tab order, focus groups and their position memory, the modal scope that confines navigation, spatial movement, the relation between point and focus, the ETAF and Ebox interfaces, and the focus change hook. [Hosts](hosts.md#accessibility-and-focus) defines the `:tab-index`, `:disabled`, `:focus-group` and `:focus-scope` properties themselves; [Actions, Behaviors and Error Boundaries](actions-behaviors-and-error-boundaries.md) defines `etaf-focusable`.

## Focus is mount state

<!-- index: focus; focusable; derived focus state; stale focus -->

Focus is a field of the mount, set and cleared through Ebox's focus API. A node can receive focus when it is live in the mount, visible, not disabled, has a nonzero layout height, and owns at least one painted cell that no overlay completely covers. `:tab-index` is not part of that test: it orders Tab navigation, but an explicit `ebox-focus` may target a Host with a negative index or none at all, and a Host that lost its tab index keeps explicit focus.

Ebox derives the `focus` selector state from the mount's focused node, so Component styles and stylesheets match `&:focus` on exactly the focused Host, and `:active` and `:focus` can be styled independently. Focus is not buffer text position: moving point does not move focus, and clearing focus does not move point.

When the focused node stops being focusable — it is removed, hidden or disabled — focus is released. `ebox-focused-node` notices this on its next read, clears the mount's focus field and returns nil, and the mount remembers the node's last rectangle as the *anchor*. The next Tab or arrow movement continues from the anchor instead of restarting at the first stop, so a control that disappears under the focus does not send the user back to the top of the interface.

## Tab order

<!-- index: tab stop; tab order; cyclic navigation -->

Tab navigation walks the *tab stops* of the current modal scope: nodes whose `:tab-index` is an integer zero or greater and which are focusable. Lower indices come first; equal indices keep tree order, so the controls of one region are visited together even when regions sit side by side. A focus group inside the scope contributes one entry instead of its members, as the next section describes.

#### Function: ebox-focus-first (&optional buffer-or-name)

Focus the first tab stop of BUFFER-OR-NAME.

**Arguments.** BUFFER-OR-NAME names a mounted Ebox buffer; the current buffer is the default.

**Semantics.** The first stop of the current modal scope in tab order receives focus, regardless of the current focus, so this is the "start of the form" entry. Point moves to the node and its scrollers reveal it.

**Returns.** The focused node.

**Errors.** `error→ user-error` with the message `"No Ebox focus stop"` when the scope has no stop.

**Example.** `(ebox-focus-first)`

**See also.** `ebox-focus-next`, `ebox-focused-node`.

#### Function: ebox-focus-next (&optional count cycle buffer-or-name)

Move focus COUNT (default 1) tab stops forward; CYCLE wraps at the end.

**Arguments.** COUNT may be negative to move backward. CYCLE non-nil wraps around both ends; otherwise leaving the range signals.

**Semantics.** Movement starts from the current focus. When focus was lost because its node stopped being focusable, movement continues from the anchor rectangle instead, and when there is no focus at all it starts at the beginning (or the end, for a negative COUNT). A focus group counts as one stop, so a Tab step enters or leaves a whole group.

**Returns.** The newly focused node. With a zero COUNT and an existing focus it returns that node without moving.

**Errors.** `error→ user-error` with `"No next Ebox focus stop"` (or `"previous"`) when the move would leave the range and CYCLE is nil, and `"No Ebox focus stop"` when the scope is empty.

**Example.** `(ebox-focus-next 1 t)`

**See also.** `ebox-focus-previous`, `ebox-focus-first`, `:tab-index`.

#### Function: ebox-focus-previous (&optional count cycle buffer-or-name)

Move focus COUNT (default 1) tab stops backward; CYCLE wraps at the start.

**Arguments.** COUNT counts backward, so a negative COUNT moves forward. CYCLE wraps.

**Semantics.** The backward twin of `ebox-focus-next`, with the same anchor fallback and the same group folding.

**Returns.** The newly focused node.

**Errors.** `error→ user-error` with `"No previous Ebox focus stop"` when the move would leave the range and CYCLE is nil, and `"No Ebox focus stop"` when the scope is empty.

**Example.** `(ebox-focus-previous 2 t)`

**See also.** `ebox-focus-next`, `etaf-focus-previous`.

#### Function: etaf-focus-next (&optional runtime)

Focus the next visible Host in mounted RUNTIME.

**Arguments.** RUNTIME defaults to the active Runtime.

**Semantics.** The ETAF wrapper of `ebox-focus-next` with cycle enabled, so Tab-like navigation never stops at the end of the interface. The order is the Ebox tab order described above; hidden and disabled Hosts are skipped by Ebox's focusability test.

**Returns.** The Ebox node that received focus.

**Errors.** `error→ etaf-runtime-error` when the Runtime is not mounted, `error→ user-error` with `"No Ebox focus stop"` when there is no stop.

**Example.** `(etaf-focus-next runtime)`

**See also.** `etaf-focus-previous`, `etaf-focus`.

#### Function: etaf-focus-previous (&optional runtime)

Focus the previous visible Host in mounted RUNTIME.

**Arguments.** RUNTIME defaults to the active Runtime.

**Semantics.** The backward twin of `etaf-focus-next`, also cyclic.

**Returns.** The Ebox node that received focus.

**Errors.** `error→ etaf-runtime-error` when the Runtime is not mounted, `error→ user-error` with `"No Ebox focus stop"` when there is no stop.

**Example.** `(etaf-focus-previous runtime)`

**See also.** `etaf-focus-next`, `etaf-focus`.

## Focus groups and position memory

<!-- index: focus group; group entry; position memory -->

A container with `:focus-group` (`vertical`, `horizontal` or `grid`) turns its focusable descendants into one Tab stop. Tab enters the group at one chosen member and leaves it as a unit; the arrow keys then move between its members, which keeps a toolbar, list or keypad from costing one Tab press per item.

The entry member is chosen in this order: the member that currently has focus, the member focused last in that group during this mount's life, the member whose `aria-selected`, `aria-current` or `aria-checked` attribute is truthy, then the first member in tab order. The memory is per mount and per group, and focusing any member updates it, so returning to a group lands where the user left it.

#### Function: ebox-focus-within (node &optional count cycle buffer-or-name)

Move focus among the tab stops inside NODE.

**Arguments.** COUNT nil focuses the first stop inside NODE; an integer moves relative to the current focus; zero queries membership. CYCLE wraps.

**Semantics.** With no COUNT, or when the current focus lies outside NODE, the first stop of the subtree is selected (the last, for a negative COUNT). With the current focus inside NODE, an integer COUNT moves forward or backward among the stops inside it and wraps only when CYCLE is non-nil. A count of zero changes nothing and returns the current focus, so a caller can ask whether focus is inside the subtree. NODE itself participates when it is a tab stop of its own subtree. The move creates no persistent restriction and installs no bindings.

**Returns.** The focused node.

**Errors.** `error→ user-error` with `"Ebox focus root is not mounted"` when NODE is not live, and with `"No Ebox focus stop"` when the subtree has none.

**Example.** `(ebox-focus-within sidebar nil t)` focuses the first control in the sidebar.

**See also.** `etaf-focus-within`, `ebox-focus-edge`, `:focus-group`.

#### Function: etaf-focus-within (runtime host-ref &optional count)

Focus a stop inside HOST-REF's committed subtree in RUNTIME.

**Arguments.** COUNT nil selects the first stop; an integer moves with wrapping; zero queries current focus membership.

**Semantics.** The ETAF wrapper of `ebox-focus-within` with cycle enabled. It addresses the subtree by Host reference, so an application can confine a navigation command to a named pane without knowing Ebox nodes. A zero COUNT is the membership query: it returns the focused Host when focus is inside the subtree. Missing roots or stops signal without changing focus or point.

**Returns.** The focused Ebox node.

**Errors.** `error→ etaf-runtime-error` when the Runtime is not mounted; `error→ user-error` when the Host is not committed, not live, or the subtree has no stop.

**Example.** `(etaf-focus-within runtime 'results 1)`

**See also.** `ebox-focus-within`, `etaf-focus`, `etaf-focused-host-ref`.

#### Function: ebox-focus-edge (last &optional buffer-or-name root)

Focus the first member of the focused node's group, or the LAST one.

**Arguments.** LAST non-nil selects the last member; nil the first. BUFFER-OR-NAME selects the mounted buffer, defaulting to the current buffer. ROOT optionally restricts candidates and participating focus groups to a mounted subtree; nil uses the current modal scope.

**Semantics.** With a focused node inside a focus group, the group's first or last member in tab order receives focus, which is how Home and End behave inside a toolbar or list. Outside a group, the same choice applies to the first or last stop of the modal scope. The group is looked up within ROOT or the current modal scope, so an outer group cannot pull navigation outside an explicit subtree. If current focus is outside ROOT, the first or last eligible stop in ROOT is selected.

**Returns.** The focused node.

**Errors.** `error→ user-error` with `"No Ebox focus stop"` when there is no stop, or `"Ebox focus root is not mounted"` when ROOT is not live in the selected mount.

**Example.** `(ebox-focus-edge t)`

**See also.** `ebox-focus-within`, `ebox-focus-stops`, `:focus-group`.

## The modal scope

<!-- index: modal scope; focus scope; focus stops -->

A node with `:focus-scope modal` confines Tab, arrow navigation and `:keys` to itself while it is visible. The innermost visible modal node is the current focus scope; without one the scope is the mount root. This is how a dialog or menu keeps the keyboard inside itself until it is closed, and how a nested dialog takes over from its parent.

#### Function: ebox-focus-scope (&optional buffer-or-name)

Return the innermost visible modal focus scope of BUFFER-OR-NAME.

**Arguments.** BUFFER-OR-NAME names a mounted Ebox buffer; the current buffer is the default.

**Semantics.** The scope is the innermost visible node whose `:focus-scope` is `modal`; when no such node is visible the mount root is returned. Key dispatch and command palettes read it to stay inside an open dialog. A hidden modal subtree is not a scope, so hiding a dialog returns navigation to the one behind it.

**Returns.** The scope node, or the mount root.

**Errors.** `error→ user-error` when the buffer has no mount.

**Example.** `(ebox-focus-scope)`

**See also.** `ebox-focus-stops`, `:focus-scope`.

#### Function: ebox-focus-stops (&optional buffer-or-name)

Return every focus stop of BUFFER-OR-NAME's modal scope in tab order.

**Arguments.** BUFFER-OR-NAME names a mounted Ebox buffer; the current buffer is the default.

**Semantics.** Unlike Tab navigation, this listing expands focus groups: every focusable member appears, because a command palette or help buffer wants to name each control. The order is the raw tab order of the scope — index first, then tree order — so callers can present the controls in the order Tab reaches their groups.

**Returns.** A list of nodes.

**Errors.** `error→ user-error` when the buffer has no mount.

**Example.** `(mapcar #'ebox-node-id (ebox-focus-stops))`

**See also.** `ebox-focus-scope`, `ebox-focus-within`.

## Directional movement

<!-- index: focus direction; spatial navigation; grid focus group -->

Arrow keys move focus rather than scroll it: the caller asks Ebox for the stop in a direction, and only when nothing lies that way does the ETAF layer step a separator or slider, enter an adjacent region or scroll the viewport. Inside a focus group the direction is interpreted by the group's orientation, and outside any group or at a group edge it becomes a geometric search.

#### Function: ebox-focus-direction (direction &optional buffer-or-name root)

Move focus toward DIRECTION, one of `up`, `down`, `left` or `right`.

**Arguments.** ROOT, when non-nil, restricts every candidate stop to ROOT or its descendants, and a focus group participates only when it lies inside ROOT.

**Semantics.** A `vertical` focus group steps through its members with up and down, a `horizontal` group with left and right, and a `grid` group moves to the geometrically nearest member in DIRECTION. A direction the group does not handle, a group edge, and an ungrouped stop all fall through to a spatial search: the nearest stop in DIRECTION that lies wholly beyond the current node's rectangle, scored by the distance along the axis plus twice the perpendicular gap plus a small center-offset tiebreak. When that stop belongs to another group, focus lands on that group's entry instead of the member itself. With no focus at all, down and right select the first stop and up and left the last. A restricted search returns nil rather than leaving the subtree, which is how a caller detects a boundary. The window is never scrolled here; the ETAF direction command does that only after no move was possible.

**Returns.** The focused node, or nil when no stop lies in DIRECTION.

**Errors.** `error→ wrong-type-argument` with data `(member up down left right)` for another direction; `error→ user-error` when the buffer has no mount.

**Example.** `(ebox-focus-direction 'down)`

**See also.** `etaf-direction`, `ebox-focus-next`, `:focus-group`.

## Point, focus and visibility

<!-- index: point and focus; focus reveal; hover content on focus -->

Focusing a node moves point to the node's first painted character and sets the window point of every window showing the buffer, without selecting a window; an application that wants a window shows it itself. Clearing focus leaves point alone. Focus and point then stay independent: point can rest on another row while a dialog keeps focus, until a command moves point out of the focused Host, at which point the key layer answers from point instead. Point is not repaired when a publication moves text — Ebox's line tracking preserves it, as [Incremental Updates and Publication](incremental-updates-and-publication.md#writing-the-buffer) describes.

Focusing also reveals the node: Ebox scrolls every enclosing scroller by the least distance that shows it, so a list or editable surface scrolls as the user tabs through it. A focused Host with `:hover-content` shows that content exactly as if the pointer rested on it, and restoring the text when focus leaves. Neither effect persists: clearing focus does not scroll back.

## The two layers

<!-- index: focus API; Host reference; explicit focus -->

Ebox owns the focused node and every navigation function above. ETAF adds the Host-reference layer so application code can focus and query by the same `:ref` it uses elsewhere, and translates the failures of a missing or invalid target into the event error vocabulary.

#### Function: ebox-focus (node &optional buffer-or-name)

Focus NODE in BUFFER-OR-NAME and move point to its first character.

**Arguments.** NODE nil clears focus. BUFFER-OR-NAME defaults to the current buffer.

**Semantics.** A focusable NODE is revealed, recorded as its group's memory, marked with the derived `focus` state, shown with its hover content, and given point. The mount also records the node's rectangle as the anchor used if the node later disappears. Passing nil clears focus and runs the focus change hook when the focus actually changed.

**Returns.** NODE, or nil when clearing.

**Errors.** `error→ user-error` with the message `"Ebox node cannot receive focus"` when NODE is not live, visible, enabled, has no painted cell or is wholly covered; `error→ user-error` when the buffer has no mount.

**Example.** `(ebox-focus button "*Ebox Form*")`

**See also.** `ebox-focused-node`, `etaf-focus`, `ebox-focus-change-functions`.

#### Function: ebox-focused-node (&optional buffer-or-name)

Return the focused node of BUFFER-OR-NAME, or nil.

**Arguments.** BUFFER-OR-NAME names a mounted Ebox buffer; the current buffer is the default.

**Semantics.** This is the single source of truth for where focus is. If the recorded node stopped being focusable, the read clears the mount's focus field and returns nil, so a removed, hidden or disabled control never keeps a stale focus. The anchor stays behind for the next movement.

**Returns.** The focused node, or nil.

**Errors.** None; an unmounted buffer returns nil.

**Example.** `(ebox-focused-node)`

**See also.** `ebox-focus`, `etaf-focused-host-ref`.

#### Function: etaf-focus (&optional runtime host-ref)

Move focus to HOST-REF in mounted RUNTIME and move point to its position.

**Arguments.** HOST-REF is an application reference. Without it the first eligible tab stop of the Runtime is selected.

**Semantics.** The explicit form focuses a committed Host even when its tab index is negative or absent, because tab index only orders navigation. The implicit form selects the first tab stop of the modal scope without changing existing focus when there is no stop. Focus follows the Host's lifetime: removal, hiding and disabling release it, while a tab index change alone leaves explicit focus on a surviving Host. Point moves with the target, so a click or a direct key command can land the caret in the focused Host.

**Returns.** The focused Ebox node.

**Errors.** `error→ etaf-event-error` for an explicit target that is not committed or not focusable; `error→ user-error` when the implicit form finds no stop; `error→ etaf-runtime-error` when the Runtime is not mounted.

**Example.** `(etaf-focus runtime 'search-field)`

**See also.** `etaf-focused-host-ref`, `ebox-focus`, `etaf-focus-within`.

#### Function: etaf-focused-host-ref (&optional runtime)

Return the currently focused Host reference in mounted RUNTIME.

**Arguments.** RUNTIME defaults to the active Runtime.

**Semantics.** Ebox's focused node is mapped back to its Host reference, so an application can compare focus against the references it wrote. Direct Ebox focus operations and the ETAF API observe the same state; a Host addressed through a local handle returns that handle. An unfocused or stale state returns nil, which matches `ebox-focused-node` clearing it.

**Returns.** The Host reference, or nil.

**Errors.** `error→ etaf-runtime-error` when the Runtime is not mounted.

**Example.** `(etaf-focused-host-ref runtime)`

**See also.** `etaf-focus`, `ebox-focused-node`, `etaf-local-ref`.

## Focus change hooks

<!-- index: focus change hook; on-focus-enter -->

#### Hook: ebox-focus-change-functions

Abnormal hook run in a mounted buffer after `ebox-focus` moved its focus.

**Arguments.** Each function receives the previously focused node, or nil, and the newly focused node, or nil when focus was cleared.

**Semantics.** The hook runs in the mount's buffer, once per focus change, and does not run when the focused node is unchanged. It is the observation point for layers that react to focus, and `:on-focus-enter` is built on it: ETAF computes which Hosts lie between the previous and the new node and dispatches the callback on each, nearest first. Because the hook runs inside the focus operation, it sees the new focus as the mount's current focus.

**Returns.** Not applicable; the hook's return values are ignored.

**Errors.** An error in a hook function propagates from the focus operation that ran it.

**Example.** `(add-hook 'ebox-focus-change-functions (lambda (old new) (message "%S" (and new (ebox-node-id new)))) nil t)`

**See also.** `ebox-focus`, `:on-focus-enter`, [Events](events.md).

## Errors and recovery

<!-- index: focus errors; stale focus recovery -->

Focus failures fall into three groups. A move that has nowhere to go signals `user-error` — `"No Ebox focus stop"` for an empty scope, `"No next Ebox focus stop"` or `"No previous Ebox focus stop"` when the range ends without cycling, and `"Ebox focus root is not mounted"` for a focus-within root that is not live. An explicit target that is not usable is different: `ebox-focus` signals `"Ebox node cannot receive focus"`, and `etaf-focus` translates an uncommitted Host reference into `etaf-event-error` so application code can catch its own addressing mistakes. A bad direction value is a type error: `wrong-type-argument` with the `(member up down left right)` data.

Recovery is automatic where the tree changed. A focused control that is removed, hidden or disabled releases focus on the next read instead of leaving a dangling node, and the next movement continues from the lost node's rectangle, so navigation stays near the user's place. An unfocused tree is a normal state: `etaf-focused-host-ref` and `ebox-focused-node` return nil, and the key layer falls back to point.
