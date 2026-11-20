# Scrolling

A scrolling box keeps its content larger than its viewport and shows a window of it moving by lines. Ebox owns that window: the offset is node state, not editor state, so a list can scroll inside a buffer without the buffer itself moving, several scrollers can nest, and a chat view can pin itself to its last line. This chapter describes the scroll container, the offset API, end anchoring, nested scrolling and scroll-into-view, the command, wheel and swipe layer, and the difference between an inner scroller and the buffer's own window scrolling. [Style Properties](style-properties.md) defines `:overflow` and `:scroll-anchor`; [Hosts](hosts.md) describes the Host-level API in `etaf-scroll-*`, covered here as the ETAF layer of the same model.

## Scroll containers

<!-- index: scroll container; overflow; scroll offset; scroll chain -->

A node is scrollable when its `:overflow` is `scroll` or `auto` and its content is taller than its viewport. A `hidden` box clips without scrolling, and a `visible` box grows with its content, so neither offers a scroll range. The scrollable state adds no layout of its own: the content keeps its line positions, and only the mapping from content lines to shown lines changes.

Scrolling never relayouts. Setting an offset updates the node's scroll value, records the node's lines as damaged, and queues the mount; the next flush recomposes exactly those lines. That is what makes scrolling cheap and what makes it different from a buffer edit, which rewrites text.

Several scrollers can enclose one point. The chain of scrollable ancestors, innermost first, is what a wheel or a scroll command walks before any remaining distance reaches the window.

```elisp :figure A scroll container keeps its declared height: three lines show and the fourth waits below
(etaf-view
 (box :width '(ch 26) :height '(lh 3) :overflow 'scroll
      :background-color (etaf-theme-token :ui-panel-bg "#f6f8fa")
   (column (text "1 first") (text "2 second") (text "3 third") (text "4 fourth"))))
```

## Reading and writing the offset

<!-- index: scroll offset; clamping; scroll callback -->

#### Function: ebox-node-scroll-offset (node)

Return NODE's scroll offset in lines.

**Arguments.** NODE is any node; a node that cannot scroll simply has the offset 0.

**Semantics.** The value is the number of content lines the node's viewport is past, starting at 0. It is node state and survives layout: an offset set by the application, by a wheel or by `ebox-node-scroll-into-view` is the same value read back here until something changes it or clamps it.

**Returns.** The offset in lines.

**Errors.** None.

**See also.** `ebox-node-set-scroll`, `etaf-scroll-offset`.

#### Function: ebox-node-set-scroll (node offset)

Scroll NODE's content to OFFSET lines, clamped; return the applied offset.

**Arguments.** OFFSET is a line count; it is clamped to the scrollable range, which is 0 for a node whose content fits.

**Semantics.** Reaching the last line pins the node, so a node with `:scroll-anchor end` keeps showing the end as content grows; any smaller offset releases the pin. A changed offset updates the shown lines without relayout and, once it has settled, calls the node's `:scroll` function with the new offset — the hook a list uses to load more rows at its top or bottom. Setting the offset it already has changes nothing and calls nothing.

**Returns.** The applied offset after clamping.

**Errors.** None; a non-scrollable node stays at 0.

**See also.** `ebox-node-scroll-offset`, `ebox-node-scroll-into-view`, `etaf-scroll-to`.

## End anchoring

<!-- index: end anchoring; pinning; scroll anchor -->

A chat or log view wants the newest line already visible, and it wants to stay there while new lines arrive. That is the pairing of the `:scroll-anchor end` style with the pinned state: layout resolves an end-anchored node's offset to its current limit, so growth keeps it at the end without any explicit scroll, and the application only reads the offset when it cares.

Because growth does not go through `set-scroll`, it is not reported to `:scroll`: a log that appends rows while pinned does not fire its own load-more callback. Scrolling away releases the pin and behaves like an ordinary scroller; scrolling back to the end pins it again. The ETAF wrappers expose the same behavior with `etaf-scroll-to` and the symbol `end`.

**Example.** A ten-row list in a three-row viewport under `:scroll-anchor end` starts at offset 7; appending one row leaves offset 8 with no scroll callback, because the pinned node followed its last line.

## Nested scrollers and scroll-into-view

<!-- index: scroll into view; nested scrolling; alignment -->

#### Function: ebox-node-scroll-into-view (node &optional align)

Scroll NODE's scrolling ancestors so its lines show; return NODE.

**Arguments.** NODE is the node to reveal. ALIGN is nil, `start` or `end`.

**Semantics.** Each scrolling ancestor, innermost first, moves the least distance that shows the node's margin box, or its top when the node is taller than the viewport. ALIGN `start` puts the node's top on the scroller's first line; `end` puts its bottom on the last line, as far as the content allows. Only Ebox scrollers move: window scrolling and point are the caller's business, which is what lets a keyboard selection reveal a row without moving the reader's window.

**Returns.** NODE.

**Errors.** An ALIGN value other than nil, `start` or `end` signals `wrong-type-argument`.

**See also.** `ebox-node-set-scroll`, `etaf-scroll-into-view`.

**Example.** A middle row of a ten-row list in a three-row viewport gives offsets 3 for the default alignment, 5 for `start` and 3 for `end`; the last row gives 7 for all three because the content clamps.

## Commands, wheels and swipes

<!-- index: scroll command; wheel; swipe gesture; swipe distance -->

The interactive layer turns keys and pointer gestures into the same offset writes. Keys and wheels walk the scroll chain at point and then hand any leftover distance to the window; a two-finger horizontal swipe is a gesture with its own distance and quiet thresholds, recognized as a whole rather than per event.

#### Variable: ebox-scroll-step

Lines scrolled by one wheel step or `ebox-scroll-down`.

**Semantics.** The default is 3 lines. `ebox-scroll-down` and `ebox-scroll-up` use it when called without a numeric argument, and the wheel commands use it per event. Setting it changes the step for the whole session.

**See also.** `ebox-scroll-down`, `ebox-wheel-scroll-down`.

#### Function: ebox-scroll-down (&optional n)

Scroll the content at point down by N lines (default `ebox-scroll-step`).

**Arguments.** N is a line count; nil means the scroll step.

**Semantics.** Every scrolling ancestor at point, innermost first, consumes as much of N as it can, and the remainder scrolls the window. Scrolling down moves later lines into view: the offset increases.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-scroll-up`, `ebox-scroll-page-down`.

#### Function: ebox-scroll-up (&optional n)

Scroll the content at point up by N lines (default `ebox-scroll-step`).

**Arguments.** N is a line count; nil means the scroll step.

**Semantics.** Identical to `ebox-scroll-down` with a negated count: offsets decrease and earlier lines come into view.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-scroll-down`, `ebox-scroll-page-up`.

#### Function: ebox-scroll-page-down (&optional arg)

Scroll the content at point down by a page, or ARG lines.

**Arguments.** ARG is a prefix argument; when given, its numeric value is the distance.

**Semantics.** Without ARG the page is the window's body height minus `next-screen-context-lines`, so the commands keep the same overlap the editor's own page scrolling has; with ARG the exact line count is used. The distance walks the same scroll chain as `ebox-scroll-down`.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-scroll-page-up`.

#### Function: ebox-scroll-page-up (&optional arg)

Scroll the content at point up by a page, or ARG lines.

**Arguments.** ARG is a prefix argument; when given, its numeric value is the distance.

**Semantics.** The upward counterpart of `ebox-scroll-page-down`.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-scroll-page-down`.

#### Function: ebox-wheel-scroll-down (event)

Scroll the content under wheel EVENT down.

**Arguments.** EVENT is a wheel event.

**Semantics.** When the window under the event shows a mounted Ebox buffer and the event is in its text area, the scroll chain at the event's position consumes one `ebox-scroll-step`; otherwise the event is handed to `mwheel-scroll`, so a wheel over a normal buffer behaves exactly as before. The buffer mode binds this to `wheel-down`, `mouse-5` and their multi-click variants, in the text area and in fringes and margins.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-wheel-scroll-up`, `ebox-scroll-step`.

#### Function: ebox-wheel-scroll-up (event)

Scroll the content under wheel EVENT up.

**Arguments.** EVENT is a wheel event.

**Semantics.** The upward counterpart of `ebox-wheel-scroll-down`, sharing its mounted-buffer check and its fallback to `mwheel-scroll`.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-wheel-scroll-down`.

#### Function: ebox-wheel-swipe (event)

Recognize a horizontal two-finger swipe from wheel EVENT.

**Arguments.** EVENT is a horizontal wheel event.

**Semantics.** One gesture accumulates travel until it reaches `ebox-swipe-distance`; then the innermost enabled node under the pointer whose `:swipe` interaction property is a function receives the finger direction, `left` or `right`, exactly once. Later events of the same gesture, including momentum, are absorbed. A pause longer than `ebox-swipe-quiet` or a direction reversal starts the next gesture, so consecutive swipes in opposite directions each fire without waiting for momentum to stop. Under macOS natural scrolling fingers moving right report `wheel-left`, which is why the direction mapping consults `mouse-wheel-flip-direction`; the buffer mode binds this command to `wheel-left` and `wheel-right`.

**Returns.** Nil.

**Errors.** None.

**See also.** `ebox-swipe-distance`, `ebox-swipe-quiet`.

#### Variable: ebox-swipe-distance

Horizontal pixels a gesture travels before it counts as a swipe.

**Semantics.** The default is 60 pixels. The distance is the absolute horizontal delta of the wheel events; an event without a usable delta counts as the whole distance, so a device that reports only direction still fires on its first event.

**See also.** `ebox-wheel-swipe`.

#### Variable: ebox-swipe-quiet

Seconds without horizontal wheel events that end a swipe gesture; a direction change also ends it immediately.

**Semantics.** The default is 0.35 seconds, which absorbs the momentum events that follow one physical swipe. Raising it merges slower successive swipes; lowering it separates them earlier.

**See also.** `ebox-wheel-swipe`, `ebox-swipe-distance`.

## Inner scrolling versus buffer scrolling

<!-- index: inner scrolling; window scrolling; scroll fallback; ETAF scroll API -->

An inner scroller and the buffer's window are two different vertical positions, and the command layer uses them in that order: Ebox scrollers consume the distance they can, and only what remains scrolls the window. Scrolling the window down is suppressed once the buffer end is visible, so a tree that fits its window keeps its pinned top and bottom rows in place while an inner scroller moves. `scroll-into-view` deliberately stops at the inner layer, leaving window scrolling and point to the caller.

The ETAF layer wraps the same offsets for Hosts. The host property `:on-scroll` is relayed to Ebox's `:scroll` function and receives the new offset after a wheel, a scroll key or any `etaf-scroll-*` call; growth under a pinned end anchor is not a scroll; the relay survives re-renders of its Host.

#### Function: etaf-scroll-offset (runtime host-ref)

Return the scroll offset in lines of a Host with `:overflow scroll`.

**Arguments.** RUNTIME is a mounted Runtime; HOST-REF names the scrolling Host.

**Semantics.** The value is the Host's current offset, the same number `ebox-node-scroll-offset` returns for its Ebox node.

**Returns.** The offset in lines.

**Errors.** An unknown HOST-REF signals an error.

**See also.** `etaf-scroll-to`, `ebox-node-scroll-offset`.

#### Function: etaf-scroll-to (runtime host-ref offset)

Scroll a Host to OFFSET lines, `start` or `end`; return the clamped offset.

**Arguments.** OFFSET is a line count, or the symbol `start` or `end`. `start` means the first line, `end` the last.

**Semantics.** The value is clamped to the Host's scroll range and applied through the Ebox offset API, so `end` pins a `:scroll-anchor end` Host and a smaller offset releases it. Combining `end` with that style is the chat and log pattern: the Host starts at its last line, follows content growth, and returns to the end when the user scrolls back.

**Returns.** The applied offset.

**Errors.** An OFFSET that is neither an integer nor `start` nor `end` signals `wrong-type-argument`; an unknown HOST-REF signals an error.

**See also.** `etaf-scroll-by`, `etaf-scroll-offset`.

#### Function: etaf-scroll-by (runtime host-ref delta)

Scroll a Host by DELTA lines (negative scrolls up); return the new offset.

**Arguments.** DELTA is a line count; negative values scroll towards earlier lines.

**Semantics.** The delta is added to the Host's current offset and the sum is applied through the clamped offset API, so a scroll past either end lands exactly at that end.

**Returns.** The new, clamped offset.

**Errors.** An unknown HOST-REF signals an error.

**See also.** `etaf-scroll-to`, `etaf-scroll-offset`.

#### Function: etaf-scroll-into-view (runtime host-ref &optional align)

Scroll every scrolling Host around HOST-REF by the least distance that shows it.

**Arguments.** HOST-REF is the Host to reveal; ALIGN is nil, `start` or `end`.

**Semantics.** Each enclosing scroller moves the least distance, with `start` aligning the Host's top to a scroller's first line or `end` aligning its bottom to the last line — for example to keep the reader's row in place after older rows are prepended. Window scrolling and point stay with the caller.

**Returns.** HOST-REF.

**Errors.** An ALIGN value other than nil, `start` or `end` signals `wrong-type-argument`; an unknown HOST-REF signals an error.

**See also.** `ebox-node-scroll-into-view`, `etaf-scroll-to`.

**Example.** `(etaf-scroll-into-view runtime 'row5)` returns `row5` and leaves the enclosing panel at offset 3 on a ten-row list in a three-row viewport.

## Errors and recovery

<!-- index: scroll errors; clamping; unknown host -->

Most scroll calls cannot fail: an offset is clamped, a node that cannot scroll stays at zero, and a swipe that never reaches its distance simply does nothing. The errors are argument errors — an alignment other than nil, `start` or `end`, a non-integer offset to `etaf-scroll-to`, or a Host reference that is not mounted — and they name the offending value.

The one behavior worth remembering is that content shrinking re-clamps the offset: remove rows from a scrolled list and the offset moves up to the new limit, while an end-anchored Host follows its new last line. An application that keeps its own copy of an offset should read it back after mutations that change content height rather than trust the value it last wrote.
