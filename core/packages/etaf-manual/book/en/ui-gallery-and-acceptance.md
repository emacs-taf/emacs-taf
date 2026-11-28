# Gallery and Acceptance

The catalog ships three runnable examples that double as its acceptance surfaces. They mount real components with ordinary caller-owned state: the surfaces example exercises menus, popovers and dialogs, the gallery composes the whole catalog into one workspace, and the window example drives a controlled window through the native gesture path. Each function mounts into a buffer and returns it, so a test or a person can open the example without going through a menu. [UI Overview](ui-overview.md) defines the contract the components follow, and each earlier chapter defines the pieces an example composes.

## Running an example

<!-- index: runnable example; acceptance surface; independent mount -->

An example function is interactive and non-interactive at once: an interactive call displays its buffer so the user sees it immediately, while a Lisp call simply mounts and returns the buffer, which is what batch acceptance uses. Reopening resets the example's own application state where the component allows it, and the caller disposes the example by unmounting its Runtime or killing the buffer. Functions that accept a buffer name allow several independent mounts of the same example, which is what a GUI scenario uses to run two windows side by side.

The examples are demonstration content, not framework behavior: the data they show is illustrative, their local helpers are not catalog APIs, and they add no contract to the components they compose. Their value is coverage — every catalog family appears in at least one of them, so a GUI pass over the three touches the layout, feedback, navigation, input, data and floating surfaces together.

## The example functions

<!-- index: etaf-ui-surfaces-open; etaf-ui-gallery-open; etaf-ui-window-resize-open -->

#### Function: etaf-ui-surfaces-open ()

Mount the runnable floating-component example in `*ETAF UI Surfaces*` and return its buffer.

**Semantics.** Interactive calls display it. Reopening resets its application state; unmount the Runtime or close the buffer to dispose it.

**Returns.** The example buffer.

**Example.** `(etaf-ui-surfaces-open)`

#### Function: etaf-ui-gallery-open (&optional buffer-or-name)

Mount the integrated catalog Gallery and return its buffer.

**Arguments.** BUFFER-OR-NAME defaults to `*ETAF UI Gallery*`; an explicit name allows independent mounts.

**Semantics.** The Gallery presents 63 specimens in eight categories, each a live view with a complete runnable example. The QR sign-in panel is a modal surface documented in [Composite Components](ui-composite-components.md#the-scanned-code-sign-in-panel), not a Gallery specimen. Search matches public symbols, Chinese titles and purpose text across categories, without case sensitivity; clearing the query returns to the current category or overview. Expand a specimen's usage to read its public signature, parameter types, required/default values, units, callback arguments and behavioral constraints, then copy the complete example to the kill ring to run it in a lexical-binding `.el` file. Reference text is read from the installed `etaf-ui.el` Commentary before mounting; keep that source file with the package. The Gallery neither reflects on private component registrations nor requires the manual package, and it reads no documentation files while rendering. The source is generated from the same bindings and View as the live specimen, rather than maintained separately.

Specimen values belong to this mount and survive category and light/dark Theme changes. Reset restores all specimens and collapses their usage panels without changing the category or query. Overview previews are independent small compositions and restart when revisited. All data is local; actions do not start external applications or network requests. Interactive calls display the buffer; a Lisp call only mounts and returns it. Unmounting or killing the buffer stops its owned data controllers, and reopening starts a fresh Gallery. A nonempty unrelated buffer or another application's Runtime raises `user-error` and remains untouched.

At 160 character widths the category sidebar is visible; smaller widths use a dropdown. The overview uses two columns when its content region has at least 96 character widths, otherwise one scrolling column. Specimens use a scrolling detail column, with header and footer kept outside the scrolling region. The minimum usable viewport is 72 character widths by 24 rows; smaller viewports deliberately clip rather than squeeze the controls. Native font metrics determine the pixel sizes.

**Returns.** The example buffer.

**Example.** `(etaf-ui-gallery-open "*Gallery A*")`

#### Function: etaf-ui-window-resize-open (&optional buffer-or-name)

Mount a controlled catalog window with a fixed body and an independent peer.

**Arguments.** BUFFER-OR-NAME defaults to `*ETAF Window Resize*`.

**Semantics.** The title moves the window, eight native handles resize it, Shift locks a gesture, a second press confirms and Escape restores the starting rectangle; the fixed body clips rather than reflowing paragraphs. Interactive calls show the buffer, and reopening replaces only an existing example mount. This example is a GUI workload, not a performance certification: it demonstrates the gesture path on the real component, and a latency budget is measured with the performance tooling instead.

**Returns.** The example buffer.

**Example.** `(etaf-ui-window-resize-open)`

## Errors and recovery

- An example mounts with ordinary components, so a defect in an example surfaces as that component's own error; the examples add no error conditions of their own.
- Reopening an example replaces its mount instead of stacking a second Runtime on the same buffer, which is what keeps an interactive retry idempotent.
- Disposal is explicit: unmount the Runtime or kill the buffer. Leaving an example mounted keeps its state and its key bindings until then.

**See also.** [UI Overview](ui-overview.md#errors-and-recovery).
