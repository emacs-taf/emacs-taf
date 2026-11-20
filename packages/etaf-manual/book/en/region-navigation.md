# Region Navigation

A *region* gives a functional area of the interface a stable name and a keyboard path to it: the sidebar, the result list, the editor pane or the detail view. A Host declares its region with the `:region` property, and the application or the user can then jump to the region's current entry position — where the user last was, or a declared default — instead of tabbing through everything between. `M-g` opens the selector, which shows every region in scope with a hint key and reads one key to jump; `etaf-region-focus` performs the same jump by region id for an application's own keys. This chapter describes the declaration, how the entry is resolved and remembered, how adjacency decides where an arrow goes, and the selector. [Hosts](hosts.md#property-region) defines the `:region` property itself; [Keyboard](keyboard.md) defines the key layer the selector lives in, and [Focus](focus.md) the focus movement it performs.

## Declaring a region

<!-- index: region; :region; nested regions -->

A region declaration is a plist: `:id` is the stable identity and the only required key, `:label` is the display name used in hints and help, `:key` is one hint character, `:enter` is the Host reference the region falls back to, and `:neighbors` maps `:left`, `:right`, `:up` and `:down` to region ids. The declaration is opaque to everything else: styles, selectors and events do not read it, and a Host without a declaration cannot be found by region functions.

Regions nest by Host ancestry. A region declared on a pane inside a region declared on its window has the window's region as its parent; the parent is the nearest enclosing region, and the selector shows the nesting as a path such as `Window/Editor`. Nesting is what makes a jump reach a pane inside a panel instead of stopping at the panel, and it is the level at which adjacency is resolved.

The declaration is validated when the Host commits: a malformed plist, an unknown key, a missing or non-symbol `:id`, a `:key` that is not one character (or is `?`), an `:enter` that is not a Host reference, and a `:neighbors` value outside the four directions are all `error→ etaf-renderer-error`. Duplicate region ids and duplicate hint keys across a Runtime are detected when the selector opens, because identity and hints must be unique for the selector to be unambiguous. Under the `vim` direction scheme a hint character may not be `h`, `j`, `k` or `l`, because those letters belong to direction navigation.

The selector lists the regions of the current focus scope, in document order; the direct entry point searches the whole Runtime, so an application can jump into a region outside the modal scope when it has a reason to. [Help](keyboard.md#help-and-the-command-palette) lists the current scope's regions with their labels and hint keys.

## Resolving the entry

<!-- index: region entry; entry memory; focus position -->

A region's *effective entry* is resolved in a fixed order: the last accepted focus position remembered inside the region, then the declared `:enter` Host, then the region's first eligible focus stop. "Eligible" means committed, enabled, painted (it has bounds) and inside the region — the region's own Host counts as inside itself. A remembered position that no longer qualifies because the Host was removed, hidden or disabled is skipped, which is what keeps a jump working after a list item disappears.

The memory is per Runtime and per region id. Every focus change records the newly focused Host under each region that encloses it, so moving through a list updates what the region will return to, and moving away does not clear it. Disposing the Runtime releases the table.

#### Function: etaf-region-focus (region-id &optional runtime)

Focus REGION-ID's effective entry in mounted RUNTIME.

**Arguments.** REGION-ID is the region's `:id` symbol. RUNTIME defaults to the active Runtime.

**Semantics.** The region is looked up among every committed region in the Runtime, not only the current scope, so an application's direct key or menu item can cross panes. Resolving the entry and focusing it follows the order above: memory, `:enter`, first eligible stop. The selector uses the same resolution, so a hint key and a programmatic jump always land in the same place. The call does not open the selector and does not read a key.

**Returns.** The focused Host reference.

**Errors.** `error→ etaf-event-error` with `"No ETAF region named %S"` when no committed region has that id, and with `"ETAF region %S has no focusable entry"` when memory, `:enter` and the region's stops all fail; `error→ etaf-runtime-error` when the Runtime is not mounted.

**Example.** `(etaf-region-focus 'results runtime)`

**See also.** `etaf-region-select`, `:region`, `etaf-focus-within`.

## Adjacency

<!-- index: region adjacency; geometry; parent climb -->

Arrow keys inside a region move focus within it; when the direction finds no stop there, the layer looks for the adjacent region in that direction. Adjacency comes from a declared mapping first and from the regions' committed geometry otherwise. Among the regions that share the anchor's parent, the candidates are those lying wholly beyond the anchor rectangle in the requested direction — the anchor is the focused Host, or the Host at point when nothing is focused. Candidates are ranked by perpendicular overlap first, then by the smallest axial gap, then by the smallest perpendicular centre distance, and finally by document order, so a region beside the anchor beats one diagonally across the layout, and ties resolve predictably. A declared `:neighbors` entry wins: the lookup asks the current region's mapping for the requested direction first, and when it names an existing region id, that region is the target; the geometric rule decides only where no usable declaration exists, at each level before the lookup climbs to the parent. Adjacency therefore follows the layout by default and a declaration overrides it.

When the current level has no candidate, the search climbs to the parent region and looks for a sibling there, so leaving a pane at the edge of its window can reach the next window over. A direction with no candidate anywhere does nothing at the region level: `etaf-direction` then falls through to spatial focus movement or viewport scrolling as [Keyboard](keyboard.md#direction) describes.

## Selecting a region

<!-- index: region selector; hint key; M-g -->

The selector is the user-facing entry point, bound to `M-g` in Runtime buffers and also callable from Lisp. It is a modal one-key interaction layered on the echo area rather than a buffer, so it never disturbs the application's own windows.

#### Function: etaf-region-select (&optional runtime)

Select a region of mounted RUNTIME from the keyboard.

**Arguments.** RUNTIME defaults to the active Runtime.

**Semantics.** The selector lists the declared regions of the current focus scope, in document order, with their hint keys and ancestor paths, marking the region that contains the current focus. It then reads one key. A hint key focuses that region's effective entry, exactly as `etaf-region-focus` would. An arrow key moves to the adjacent region in that direction, using the geometric rule above, and under the `vim` scheme `h`, `j`, `k` and `l` do the same. `?` repeats the hint with an explanation. Escape cancels and leaves focus alone, `C-g` aborts like any native quit, and any other key changes nothing: the selector stays open and shows a notice naming the key. A jump that fails — a region with no eligible entry, or a direction with no neighbouring region — also stays open with a notice instead of ending the interaction or signalling. The framework reserves `M-g` for this selector, so `:keys` cannot bind it.

**Returns.** nil.

**Errors.** `error→ user-error` with the message `"No ETAF region is declared in this scope"` when the current scope has no region; `error→ etaf-renderer-error` when two regions share an id or a hint key; `error→ etaf-runtime-error` when the Runtime is not mounted.

**Example.** `(etaf-region-select runtime)`

**See also.** `etaf-region-focus`, `etaf-help`, `:region`.

## How selection works

<!-- index: region memory; key override; hint display -->

Two mechanisms make the selector reliable. First, the entry memory is updated by the same focus change hook ETAF already runs for `:on-focus-enter`, so every focus movement — by Tab, by arrow, by a press or by an application call — feeds the region memory without any extra bookkeeping, and the region a user returns to is wherever that hook last recorded them. Second, the selector installs a temporary key override for the duration of the read, which makes the hint characters, the four direction keys, `?` and Escape complete events rather than prefixes of longer application bindings; a hint character that also starts a key sequence elsewhere still selects the region here. The hint line itself is rebuilt after every unknown key so the notice and the available choices stay visible.

## Errors and recovery

<!-- index: region errors -->

Declaration problems are caught before anything runs: an invalid `:region` value fails the Host commit, and duplicate ids or hint keys are reported when the selector opens instead of silently choosing one region. Entry problems are reported by the direct entry point as `etaf-event-error`, because an application names a region id and deserves a specific failure. The selector treats the same problems as recoverable: a region without an eligible entry, a direction with no neighbour and an unrecognized key each produce a notice and keep reading, so the user can choose another region or cancel. Cancelling with Escape never moves focus, and `C-g` quits the selection like any prefix.
