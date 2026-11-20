;;; ebox.el --- Pixel-perfect box model renderer -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ebox contributors
;; Version: 3.1.2
;; Package-Requires: ((emacs "29.1") (ecss "0.1.0"))
;; Keywords: ui, graphics, convenience
;; URL: https://github.com/emacs-taf/ebox

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.  See LICENSE for the full text.

;;; Commentary:

;; Ebox renders retained box trees into Emacs buffers.  Build a tree from an
;; author form, mount it in a buffer, then update nodes in place: every
;; update restyles, relayouts and repaints only the affected boxes and writes
;; only the changed lines.  Updates outside `ebox-with-batch' flush at once.
;;
;; `swiftc' is optional: on macOS it compiles a small helper that renders
;; color emoji, and without it emoji fall back to ordinary text.
;;
;; This Commentary is the supported API inventory; unlisted symbols are
;; internal.  Workflows are in the ETAF Reference Manual.
;;
;;;; Building trees
;;
;; Function: ebox-build (form)
;;;###autoload (autoload 'ebox-build "ebox" nil nil)
;; Build a detached node tree from author FORM.
;;
;; Function: ebox-node-create (tag &optional props children)
;;;###autoload (autoload 'ebox-node-create "ebox" nil nil)
;; Create a detached node of TAG with author PROPS and CHILDREN.
;;
;; Function: ebox-text-create (string &optional props)
;;;###autoload (autoload 'ebox-text-create "ebox" nil nil)
;; Create a detached text node showing STRING with author PROPS.
;;
;; Function: ebox-node-copy (node)
;;;###autoload (autoload 'ebox-node-copy "ebox" nil nil)
;; Return a detached deep copy of NODE built from its current inputs.
;;
;; Function: ebox-help-create (function)
;;;###autoload (autoload 'ebox-help-create "ebox" nil nil)
;; Adapt zero-argument FUNCTION to a native `help-echo' callback.
;;
;; Function: ebox-keymap-create (&rest options)
;;;###autoload (autoload 'ebox-keymap-create "ebox" nil nil)
;; Create a native keymap from OPTIONS.
;; :activate is a zero-argument callback for RET, return, SPC and the primary
;; mouse button; :bindings is an alist of key descriptions or vectors paired
;; with zero-argument callbacks; :drag is a one-argument gesture callback;
;; :drag-lock-modifier names a modifier that keeps the gesture alive after
;; release; :drag-edge non-nil reports edge intent during a drag.
;;
;; A :drag callback receives one plist per phase.  :phase is start, move, end,
;; cancel or edge.  :event is the native event that produced the phase (the
;; last read event for edge); :node, :window and :buffer identify the retained
;; owner and its display; :start and :position are (X . Y) pixels in the
;; window's text area and :delta is the displacement from :start.  The pointer
;; may leave the text area while the button is held: :position then stays at
;; the nearest point inside it and :overshoot is the pointer's (DX . DY)
;; distance past it, negative to the left and above, (0 . 0) inside.  A cancel
;; also carries :reason: target-unavailable, input, quit or error.  An edge
;; phase carries :edges, the window edges the pointer rests against or has
;; passed, in the fixed order left, right, top, bottom, and :elapsed, the
;; seconds since the previous edge phase began or, for the first, since the
;; pointer reached the band.
;;
;; A gesture ends with end on release, wherever the pointer is, or with cancel
;; when the target disappears, Escape is pressed or another input arrives.
;; Escape cancels with quit and is consumed; other input is preserved.  The
;; window system can lose a release, so a new press of the primary button
;; ends an unlocked gesture with end at the last position, and the press is
;; then handled as usual.  While a gesture is tracked, a shown tooltip is
;; hidden and help echo is suppressed.  Read the pointer from :position: the
;; start of a native drag or release event is the press, and the event of an
;; end implied by a new press is that press.  Ebox never scrolls for an edge
;; phase: the callback owns the viewport, the scroll step and how a
;; content-anchored target follows it.
;;
;; Variable: ebox-drag-edge-band
;; Lines and columns from a window edge where a drag reports edge intent.
;;
;; Variable: ebox-drag-edge-interval
;; Seconds between edge gestures while a drag rests in or past the edge band.
;;
;; Function: ebox-display-metrics (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-display-metrics "ebox" nil nil)
;; Return a fresh plist describing BUFFER-OR-NAME's effective default face.
;; Default to the current buffer.  :char-width and :line-height are positive
;; pixel sizes; :line-height is one row, sized by the face's body fonts;
;; :ascent is the percentage aligning images to its baseline.
;; Buffer-local text scaling is included.  Use its displaying frame, or the
;; selected frame for hidden buffers.  Text displays use unit cells and 100
;; percent ascent.  An unknown buffer signals `error'.  Image producers use
;; these metrics to partition pixel content into aligned text rows.
;;
;; Hook: ebox-display-change-functions
;; Abnormal hook called with a mounted buffer after its display metrics have
;; settled and its retained tree has been remeasured.  Read
;; `ebox-display-metrics' in the callback to update externally prepared rows.
;; Scaling does not remount state or fire callbacks for released mounts.
;;
;; Function: ebox-pixel-space (pixel-width)
;;;###autoload (autoload 'ebox-pixel-space "ebox" nil nil)
;; Return a display space PIXEL-WIDTH pixels wide.
;;
;; Function: ebox-string-pixel-width (string)
;;;###autoload (autoload 'ebox-string-pixel-width "ebox" nil nil)
;; Return the display pixel width of STRING's first line.
;;
;;;; Mounting and rendering
;;
;; Function: ebox-mount (buffer-or-name input &rest options)
;;;###autoload (autoload 'ebox-mount "ebox" nil nil)
;; Mount INPUT, a root node or author form, in BUFFER-OR-NAME and return the root.
;; While mounted, the buffer's default background follows the root's
;; background color, so window space beyond the laid-out rows matches it.
;; OPTIONS accepts :width and :height for a fixed viewport, plus :observer,
;; a function of buffer and report installed before the first flush. Nil
;; disables observation.  Invalid observers signal wrong-type-argument before
;; replacing an existing mount; reports follow ebox-buffer-set-observer.
;;
;; Function: ebox-render (input)
;;;###autoload (autoload 'ebox-render "ebox" nil nil)
;; Render INPUT, a node or author form, and return its lines as a string.
;; Measure under the current buffer's faces, including text scaling.
;;
;; Function: ebox-render-to-buffer (buffer-or-name input &rest options)
;;;###autoload (autoload 'ebox-render-to-buffer "ebox" nil nil)
;; Mount INPUT in BUFFER-OR-NAME with OPTIONS and return the buffer.
;;
;; Function: ebox-unmount-buffer (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-unmount-buffer "ebox" nil nil)
;; Release the mount of BUFFER-OR-NAME, keeping its text.  Return non-nil if any.
;;
;; Function: ebox-buffer-mount (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-buffer-mount "ebox" nil nil)
;; Return the mount of BUFFER-OR-NAME (default current buffer), or nil.
;;
;; Function: ebox-buffer-root (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-buffer-root "ebox" nil nil)
;; Return the root node mounted in BUFFER-OR-NAME, or nil.
;;
;; Function: ebox-mount-viewport (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-mount-viewport "ebox" nil nil)
;; Return (WIDTH . HEIGHT) of BUFFER-OR-NAME's mounted viewport, or nil.
;; WIDTH is in pixels and HEIGHT in lines.  Without a fixed viewport the size
;; follows the window displaying the buffer, in batch sessions too.  HEIGHT is
;; nil when indefinite (an undisplayed batch buffer without
;; `ebox-viewport-height'), so viewport-height units size to content there.
;;
;; Function: ebox-mount-set-viewport (buffer-or-name width height)
;;;###autoload (autoload 'ebox-mount-set-viewport "ebox" nil nil)
;; Lay out BUFFER-OR-NAME's mount for a WIDTH by HEIGHT viewport.
;;
;; Function: ebox-mount-flush-count (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-mount-flush-count "ebox" nil nil)
;; Return the number of flushes that wrote BUFFER-OR-NAME's mount.
;;
;; Function: ebox-viewport-window-width (window)
;;;###autoload (autoload 'ebox-viewport-window-width "ebox" nil nil)
;; Return the pixel width WINDOW offers to a mounted tree.
;;
;; Function: ebox-viewport-measure (buffer-or-name &optional width height)
;;;###autoload (autoload 'ebox-viewport-measure "ebox" nil nil)
;; Return the (WIDTH . HEIGHT) viewport a mount of BUFFER-OR-NAME would use
;; now, whether or not it is mounted yet.  Non-nil WIDTH or HEIGHT fixes that
;; dimension; the rest follows the window displaying the buffer, like
;; `ebox-mount-viewport'.  A layer mounting a tree after computing its content
;; uses it to size that content to the viewport the mount will have.
;;
;; Function: ebox-refit (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-refit "ebox" nil nil)
;; Relayout BUFFER-OR-NAME's mount when its viewport size changed.  A
;; window showing the whole buffer starts at its top again, so a tree that
;; scrolled while transient UI borrowed window lines returns to place.
;; Return non-nil when the layout changed.
;;
;; Function: ebox-buffer-mode (&optional arg)
;;;###autoload (autoload 'ebox-buffer-mode "ebox" nil t)
;; Minor mode for mounted Ebox buffers.  `ebox-mount' enables it and
;; `ebox-unmount-buffer' disables it; customize `ebox-buffer-mode-map'.
;; The canvas has no text selection: a press or drag on it only moves point
;; and an activated mark is deactivated; input sessions keep their region.
;;
;; Variable: ebox-viewport-width
;; Viewport width in pixels for rendering outside a mount, or nil.
;;
;; Variable: ebox-viewport-height
;; Viewport height in lines for rendering outside a mount, or nil.
;;
;; Variable: ebox-viewport-settle-delay
;; Seconds of quiet after the last window size or text scale change before
;; Ebox reflows; successive events share one trailing refresh.
;;
;; Hook: ebox-unmount-functions
;; Abnormal hook run with a buffer whose mount is being released.
;;
;; Hook: ebox-focus-change-functions
;; Abnormal hook run in a mounted buffer after `ebox-focus' (and the focus
;; navigation built on it) moved focus.  Functions receive the previously
;; focused node, or nil, and the new node, or nil when focus was cleared.
;; Focus that Ebox restores after a publication does not run it.
;;
;; Hook: ebox-viewport-change-functions
;; Abnormal hook run with a mounted buffer after its viewport size changed,
;; whether a window resize or `ebox-mount-set-viewport' caused it.  It runs
;; once the relayout for the new size has settled; read the new size with
;; `ebox-mount-viewport'.
;;
;; Hook: ebox-display-window-change-functions
;; Abnormal hook run in a mounted buffer, with the buffer and its display
;; window, once a window change settles, after the mount was refit.  It runs when the window
;; became the buffer's display window or its body pixel size changed since the
;; hook last ran for that buffer, even when a fixed viewport kept the layout.
;; A shorter window while the minibuffer, a completion popup or the echo area
;; borrows lines does not run it.  Use it to fit state that follows the window
;; rather than the mounted viewport, such as page sizes and row budgets.
;;
;;;; Updating nodes
;;
;; Function: ebox-node-put (node key value)
;;;###autoload (autoload 'ebox-node-put "ebox" nil nil)
;; Set NODE's author property KEY to VALUE.
;;
;; Function: ebox-node-set-props (node props)
;;;###autoload (autoload 'ebox-node-set-props "ebox" nil nil)
;; Replace NODE's author properties with PROPS.
;;
;; Function: ebox-node-set-text (node string)
;;;###autoload (autoload 'ebox-node-set-text "ebox" nil nil)
;; Set text NODE's content to STRING.
;;
;; Function: ebox-node-set-image (node image)
;;;###autoload (autoload 'ebox-node-set-image "ebox" nil nil)
;; Set image NODE's prepared IMAGE.
;;
;; Function: ebox-node-set-states (node states)
;;;###autoload (autoload 'ebox-node-set-states "ebox" nil nil)
;; Set NODE's author selector STATES, a list of symbols or strings.
;;
;; Function: ebox-node-restyle (node)
;;;###autoload (autoload 'ebox-node-restyle "ebox" nil nil)
;; Recompute NODE's style after derived selector state changed.
;;
;; Function: ebox-node-insert (parent child &optional index)
;;;###autoload (autoload 'ebox-node-insert "ebox" nil nil)
;; Insert detached CHILD into PARENT at INDEX (default last) and return CHILD.
;;
;; Function: ebox-node-remove (node)
;;;###autoload (autoload 'ebox-node-remove "ebox" nil nil)
;; Detach NODE from its parent and return it.
;;
;; Function: ebox-node-move (node index)
;;;###autoload (autoload 'ebox-node-move "ebox" nil nil)
;; Move NODE to INDEX among its siblings.
;;
;; Function: ebox-node-replace-children (parent children)
;;;###autoload (autoload 'ebox-node-replace-children "ebox" nil nil)
;; Replace PARENT's children with CHILDREN, reusing nodes already present.
;;
;; Macro: ebox-with-batch (&rest body)
;;;###autoload (autoload 'ebox-with-batch "ebox" nil nil 'macro)
;; Run BODY as one update batch; flush queued mounts when it ends.
;;
;; Function: ebox-call-with-batch (function)
;;;###autoload (autoload 'ebox-call-with-batch "ebox" nil nil)
;; Call FUNCTION as one update batch and return its value.
;;
;; Function: ebox-flush ()
;;;###autoload (autoload 'ebox-flush "ebox" nil nil)
;; Bring every queued mount's buffer up to date.
;;
;; Hook: ebox-after-flush-functions
;; Abnormal hook run with each mount's buffer after a flush wrote it.
;;
;; Function: ebox-buffer-set-observer (buffer-or-name observer)
;;;###autoload (autoload 'ebox-buffer-set-observer "ebox" nil nil)
;; Call OBSERVER with the buffer and a report plist after each flush.
;; The report contains :provider (always ebox), :strategy (lines or full),
;; :edits, :lines, :ranges (START OLD NEW) line replacements, :flush and
;; :duration-ms.
;;
;; Function: ebox-buffer-update-report (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-buffer-update-report "ebox" nil nil)
;; Return a copy of the report of BUFFER-OR-NAME's latest flush, or nil.
;;
;; Function: ebox-clear-cache ()
;;;###autoload (autoload 'ebox-clear-cache "ebox" nil nil)
;; Clear pixel width caches after font or named face metrics change.
;;
;;;; Querying nodes
;;
;; Function: ebox-node-root (node)
;;;###autoload (autoload 'ebox-node-root "ebox" nil nil)
;; Return the root of NODE's tree.
;;
;; Function: ebox-node-buffer (node)
;;;###autoload (autoload 'ebox-node-buffer "ebox" nil nil)
;; Return the buffer showing NODE, or nil.
;;
;; Function: ebox-node-parent (node)
;;;###autoload (autoload 'ebox-node-parent "ebox" nil nil)
;; Return NODE's parent node, or nil for a root or detached node.
;;
;; Function: ebox-node-children (node)
;;;###autoload (autoload 'ebox-node-children "ebox" nil nil)
;; Return NODE's children as a fresh list.
;;
;; Function: ebox-node-child (node index)
;;;###autoload (autoload 'ebox-node-child "ebox" nil nil)
;; Return NODE's child at INDEX, or nil when INDEX is out of range.
;;
;; Function: ebox-node-child-count (node)
;;;###autoload (autoload 'ebox-node-child-count "ebox" nil nil)
;; Return the number of NODE's children.
;;
;; Function: ebox-node-index (node)
;;;###autoload (autoload 'ebox-node-index "ebox" nil nil)
;; Return NODE's position among its parent's children, 0 for a root.
;;
;; Function: ebox-node-ancestor-p (ancestor node)
;;;###autoload (autoload 'ebox-node-ancestor-p "ebox" nil nil)
;; Return non-nil when ANCESTOR is NODE or one of its ancestors.
;;
;; Function: ebox-node-text-p (node)
;;;###autoload (autoload 'ebox-node-text-p "ebox" nil nil)
;; Return non-nil when NODE is a text node.
;;
;; Function: ebox-node-walk (node function)
;;;###autoload (autoload 'ebox-node-walk "ebox" nil nil)
;; Call FUNCTION on NODE and its descendants in document order.
;;
;; Function: ebox-node-at (&optional position buffer-or-name)
;;;###autoload (autoload 'ebox-node-at "ebox" nil nil)
;; Return the innermost node painted at POSITION in BUFFER-OR-NAME.
;;
;; Function: ebox-node-position (node)
;;;###autoload (autoload 'ebox-node-position "ebox" nil nil)
;; Return the buffer position of NODE's first painted character, or nil.
;;
;; Function: ebox-node-bounds (node &optional all-lines)
;;;###autoload (autoload 'ebox-node-bounds "ebox" nil nil)
;; Return (START . END) buffer positions of NODE's first painted line.
;; With ALL-LINES, END ends NODE's last painted line, spanning every row.
;; A box's span starts at the first cell of that line not covered by an
;; overlay outside NODE; the result is nil when overlays cover the whole line.
;; A `:visibility hidden' box in flow reports its blank slot; a hidden or
;; unplaced absolute box, and its content, has no bounds.
;; Covered boxes are likewise not focusable.
;;
;; Function: ebox-node-geometry (node)
;;;###autoload (autoload 'ebox-node-geometry "ebox" nil nil)
;; Return NODE's border box as a plist (:x :y :width :height).
;;
;; Function: ebox-node-root-line (node)
;;;###autoload (autoload 'ebox-node-root-line "ebox" nil nil)
;; Return the root line of NODE's border-box top, or nil when not laid out.
;;
;; Function: ebox-selector-query (root selector)
;;;###autoload (autoload 'ebox-selector-query "ebox" nil nil)
;; Return ROOT's descendants-or-self matching SELECTOR in document order.
;;
;; Function: ebox-selector-query-buffer (buffer-or-name selector)
;;;###autoload (autoload 'ebox-selector-query-buffer "ebox" nil nil)
;; Return nodes mounted in BUFFER-OR-NAME matching SELECTOR.
;;
;; Function: ebox-selector-match-node-p (node selector)
;;;###autoload (autoload 'ebox-selector-match-node-p "ebox" nil nil)
;; Return non-nil when NODE matches structured or string SELECTOR.
;;
;;;; Scrolling
;;
;; Function: ebox-node-scroll-offset (node)
;;;###autoload (autoload 'ebox-node-scroll-offset "ebox" nil nil)
;; Return NODE's scroll offset in lines.  A laid-out node reports the offset
;; it shows: an offset past content that shrank clamps to the content's end,
;; and scrolling commands move from that offset.
;;
;; Function: ebox-node-set-scroll (node offset)
;;;###autoload (autoload 'ebox-node-set-scroll "ebox" nil nil)
;; Scroll NODE's content to OFFSET lines, clamped; return the applied offset.
;; Reaching the last line pins a `:scroll-anchor end' node so it follows
;; growing content; a smaller offset releases the pin.  A changed offset is
;; then passed to the node's `:scroll' function, for example to load more
;; rows when a list reaches its top or bottom.
;;
;; Function: ebox-node-scroll-into-view (node &optional align)
;;;###autoload (autoload 'ebox-node-scroll-into-view "ebox" nil nil)
;; Scroll NODE's scrolling ancestors, innermost first, by the least distance
;; that shows NODE (its top when taller than the viewport); return NODE.
;; ALIGN `start' or `end' puts NODE's top at a scroller's first line or its
;; bottom at the last line instead, as far as the content allows.
;; Only Ebox scrollers move; window scrolling is the caller's choice.
;;
;; Function: ebox-scroll-up (&optional n)
;;;###autoload (autoload 'ebox-scroll-up "ebox" nil t)
;; Scroll the content at point up by N lines (default `ebox-scroll-step').
;;
;; Function: ebox-scroll-down (&optional n)
;;;###autoload (autoload 'ebox-scroll-down "ebox" nil t)
;; Scroll the content at point down by N lines (default `ebox-scroll-step').
;;
;; Function: ebox-scroll-page-up (&optional arg)
;;;###autoload (autoload 'ebox-scroll-page-up "ebox" nil t)
;; Scroll the content at point up by a page, or ARG lines.
;;
;; Function: ebox-scroll-page-down (&optional arg)
;;;###autoload (autoload 'ebox-scroll-page-down "ebox" nil t)
;; Scroll the content at point down by a page, or ARG lines.
;;
;; Function: ebox-wheel-scroll-up (event)
;;;###autoload (autoload 'ebox-wheel-scroll-up "ebox" nil t)
;; Scroll the content under wheel EVENT up.
;;
;; Function: ebox-wheel-scroll-down (event)
;;;###autoload (autoload 'ebox-wheel-scroll-down "ebox" nil t)
;; Scroll the content under wheel EVENT down.
;;
;; Variable: ebox-scroll-step
;; Lines scrolled by one wheel step or `ebox-scroll-down'.
;;
;; Function: ebox-wheel-swipe (event)
;;;###autoload (autoload 'ebox-wheel-swipe "ebox" nil t)
;; Recognize a horizontal two-finger swipe from wheel EVENT; mounted buffers
;; bind it to wheel-left/right.  Once a gesture travels `ebox-swipe-distance'
;; pixels, the innermost enabled node under the pointer whose `:swipe'
;; interaction property is a function receives the finger direction, `left'
;; or `right', exactly once; the rest of the gesture, including momentum, is
;; absorbed.  A reversal of direction starts the next gesture at once, so
;; consecutive left and right swipes each fire without waiting for a pause.
;; Under macOS natural scrolling fingers moving right report `wheel-left';
;; `mouse-wheel-flip-direction' reverses the mapping.
;;
;; Variable: ebox-swipe-distance
;; Horizontal pixels a gesture travels before it counts as a swipe.
;;
;; Variable: ebox-swipe-quiet
;; Seconds without horizontal wheel events that end a swipe gesture; a
;; direction change also ends it immediately.
;;
;;;; Focus and interaction
;;
;; Function: ebox-focus (node &optional buffer-or-name)
;;;###autoload (autoload 'ebox-focus "ebox" nil nil)
;; Focus NODE in BUFFER-OR-NAME and move point to its first character.
;; NODE's Ebox scrollers reveal it, its focus group remembers it as the
;; group's entry and its `:hover-content' shows as under the mouse.  When
;; the focused node disappears, the next navigation continues from its last
;; position instead of restarting at the first stop.
;;
;; Focus navigation follows two interaction facts.  `:focus-group' on a
;; container (`vertical', `horizontal' or `grid') makes its `:tab-index'
;; descendants one Tab stop: Tab enters at the remembered member, else the
;; member whose `aria-selected', `aria-current' or `aria-checked' attribute
;; is true, else the first member; arrows move inside it.  A stop belongs to
;; its nearest group.  `:focus-scope modal' confines Tab, arrows and
;; `ebox-focus-first' to the innermost visible modal node.
;;
;; Function: ebox-focused-node (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-focused-node "ebox" nil nil)
;; Return the focused node of BUFFER-OR-NAME, or nil.
;;
;; Function: ebox-focus-first (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-focus-first "ebox" nil t)
;; Focus the first tab stop of BUFFER-OR-NAME.
;;
;; Function: ebox-focus-next (&optional count cycle buffer-or-name)
;;;###autoload (autoload 'ebox-focus-next "ebox" nil t)
;; Move focus COUNT (default 1) tab stops forward; CYCLE wraps at the end.
;;
;; Function: ebox-focus-previous (&optional count cycle buffer-or-name)
;;;###autoload (autoload 'ebox-focus-previous "ebox" nil t)
;; Move focus COUNT (default 1) tab stops backward; CYCLE wraps at the start.
;;
;; Function: ebox-focus-within (node &optional count cycle buffer-or-name)
;;;###autoload (autoload 'ebox-focus-within "ebox" nil nil)
;; Move focus among the tab stops inside NODE.
;;
;; Function: ebox-focus-direction (direction &optional buffer-or-name root)
;;;###autoload (autoload 'ebox-focus-direction "ebox" nil nil)
;; Move focus toward DIRECTION (`up', `down', `left' or `right') and return
;; the focused node, or nil when no stop lies that way.  A `vertical' group
;; steps through its members with up/down, a `horizontal' group with
;; left/right and a `grid' group moves to the nearest member.  Other
;; directions, group edges and ungrouped stops move to the nearest stop
;; beyond the current one in the modal scope; entering a group lands on
;; its entry.  ROOT restricts movement to ROOT itself and its descendants,
;; and a group participates only when it lies inside ROOT, so a caller can
;; keep navigation inside a named area and detect its boundary.
;;
;; Function: ebox-focus-edge (last &optional buffer-or-name root)
;;;###autoload (autoload 'ebox-focus-edge "ebox" nil nil)
;; Focus the first member of the focused node's group, or the LAST one;
;; outside a group, the first or LAST stop of the modal scope.
;; ROOT restricts candidates and participating groups to its subtree, as
;; with `ebox-focus-direction'.  A root outside the mount signals `user-error'.
;;
;; Function: ebox-focus-scope (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-focus-scope "ebox" nil nil)
;; Return the innermost visible `:focus-scope modal' node, or the mount
;; root.  Key dispatch and command palettes use it to stay inside an open
;; dialog.
;;
;; Function: ebox-focus-stops (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-focus-stops "ebox" nil nil)
;; Return every focus stop in the modal scope in tab order, including all
;; members of focus groups, for listing the actionable controls on screen.
;;
;; Function: ebox-activate (&optional position noerror)
;;;###autoload (autoload 'ebox-activate "ebox" nil t)
;; Invoke the RET binding of the node at POSITION, defaulting to point.
;;
;; Function: ebox-next-interaction (&optional count)
;;;###autoload (autoload 'ebox-next-interaction "ebox" nil t)
;; Move point to the next keymap owner COUNT times; return the position.
;;
;; Function: ebox-previous-interaction (&optional count)
;;;###autoload (autoload 'ebox-previous-interaction "ebox" nil t)
;; Move point to the previous keymap owner COUNT times; return the position.
;;
;; Variable: ebox-buffer-mode-map
;; Keymap of mounted Ebox buffers: scrolling, focus navigation and activation.
;; Arrows and C-n/C-p/C-b/C-f call `ebox-focus-direction', scrolling when no
;; stop lies above or below; Home/End and M-</M-> call `ebox-focus-edge'.
;;
;;;; Input sessions
;;
;; Function: ebox-input-begin (buffer-or-name node &rest options)
;;;###autoload (autoload 'ebox-input-begin "ebox" nil nil)
;; Begin native editing of laid-out text NODE in BUFFER-OR-NAME and return a
;; session.  NODE's text becomes the session value with the caret at its end.
;; Keys typed in the buffer then edit the value through their ordinary Emacs
;; commands (insertion, deletion, motion, kill and yank, undo, the region and
;; input methods) while the buffer stays read-only.  NODE keeps its layout and
;; shows each edit at once: wrapping, padding and borders stay in place, point
;; follows the caret, up/down move by painted rows and a click inside NODE's
;; box moves the caret or selects.  OPTIONS is a plist: :on-change receives the
;; new value after each command that changes it; :keymap holds bindings
;; consulted first, which run in the buffer except `ebox-input-edit-commands';
;; :on-leave is called without arguments when a later click lands outside NODE's
;; box; the gesture opening the session does not also count as leaving it.
;; :local-variables is an alist of buffer-local settings, such as
;; `completion-at-point-functions', for the commands editing the value;
;; :caret is a value offset placing the caret, and a session whose node text
;; is unchanged since the last one reuses its editing buffer, keeping the
;; previous caret, region and undo history.  Without :caret a fresh session
;; opens at the end.  Setting NODE's text to the session value is a no-op;
;; another string replaces the value and clears its undo history.  One
;; session per buffer; an unmounted buffer or a node that is not laid-out
;; text signals `ebox-input-error'.  Unmounting the buffer ends the session.
;;
;; Variable: ebox-input-edit-commands
;; Commands that edit the session value when a session :keymap binds them,
;; such as `newline' for a multi-line field.  Other :keymap bindings run in
;; the mounted buffer.
;;
;; Function: ebox-input-end (session)
;;;###autoload (autoload 'ebox-input-end "ebox" nil nil)
;; End SESSION and return its value; NODE keeps displaying it.  Ending a
;; session that already ended returns nil.
;;
;; Function: ebox-input-text (session)
;;;###autoload (autoload 'ebox-input-text "ebox" nil nil)
;; Return SESSION's current property-free value, or nil once it ended.
;;
;; Function: ebox-input-active-p (&optional buffer-or-name)
;;;###autoload (autoload 'ebox-input-active-p "ebox" nil nil)
;; Return the active input session of BUFFER-OR-NAME, or nil.
;;
;; Function: ebox-input-session-node (session)
;;;###autoload (autoload 'ebox-input-session-node "ebox" nil nil)
;; Return the node SESSION edits.
;;
;; Function: ebox-call-with-input (node reader &optional buffer-or-name)
;;;###autoload (autoload 'ebox-call-with-input "ebox" nil nil)
;; Call zero-argument READER for visible, enabled NODE in BUFFER-OR-NAME.
;; Return its result when NODE is still available; otherwise signal
;; `ebox-input-cancelled'.  Afterwards NODE holds logical focus, or the
;; earlier focus returns when NODE is gone.
;;
;;;; Styles and images
;;
;; Function: ebox-style-compile-rules (rules)
;;;###autoload (autoload 'ebox-style-compile-rules "ebox" nil nil)
;; Compile ordered (SELECTOR PROPERTY VALUE ...) RULES through ECSS syntax
;; and the strict Ebox property schema.  Invalid rules signal an error.
;;
;; Function: ebox-style-compile-declarations (plist &optional strict)
;;;###autoload (autoload 'ebox-style-compile-declarations "ebox" nil nil)
;; Compile Ebox PLIST aliases to ECSS schema declarations.
;; When STRICT is non-nil, reject properties outside the Ebox style domain.
;;
;; Function: ebox-style-compile-form (tag plist)
;;;###autoload (autoload 'ebox-style-compile-form "ebox" nil nil)
;; Compile evaluated author PLIST once and validate it for TAG.
;;
;; Function: ebox-style-canonical-name (name)
;;;###autoload (autoload 'ebox-style-canonical-name "ebox" nil nil)
;; Return canonical CSS-like longhand property name for NAME.
;;
;; Function: ebox-style-schema-id (name)
;;;###autoload (autoload 'ebox-style-schema-id "ebox" nil nil)
;; Return the namespaced ECSS schema id of Ebox property NAME, or nil.
;;
;; Function: ebox-style-property-accepted-p (tag name)
;;;###autoload (autoload 'ebox-style-property-accepted-p "ebox" nil nil)
;; Return non-nil when author form TAG accepts property NAME.
;;
;; Function: ebox-style-scope-create (rules &key (origin 'author))
;;;###autoload (autoload 'ebox-style-scope-create "ebox" nil nil)
;; Create an immutable shared scope from ordered RULES at ORIGIN.
;;
;; Function: ebox-style-scope-with-rules (scope rules &key (origin 'author))
;;;###autoload (autoload 'ebox-style-scope-with-rules "ebox" nil nil)
;; Return a new RULES snapshot preserving SCOPE's membership identity.
;;
;; Function: ebox-image-prepare (source columns rows &key (adapter 'auto) (frame (selected-frame)) inset (converters ebox-image-converters))
;;;###autoload (autoload 'ebox-image-prepare "ebox" nil nil)
;; Prepare SOURCE for an integer COLUMNS by ROWS character area.  INSET
;; (TOP . BOTTOM) leaves that many pixels, under one line each, empty inside a
;; graphics image's first and last rows; the gap shows the box background.
;; Graphics images composite transparent pixels over their box background.
;; With native SVG support, filtered overlays dim prepared PNG/JPEG/SVG
;; pixels as cached in-memory composites, keeping alpha, slices and geometry.
;; Other native image formats remain visible without pixel filtering.
;;
;; Function: ebox-image-content (prepared)
;;;###autoload (autoload 'ebox-image-content "ebox" nil nil)
;; Return an owned character string for PREPARED, without any I/O.
;;
;; Function: ebox-image-info (prepared)
;;;###autoload (autoload 'ebox-image-info "ebox" nil nil)
;; Return PREPARED's adapter, converter, columns and rows as a fresh plist.
;;
;; Function: ebox-image-cache-clear ()
;;;###autoload (autoload 'ebox-image-cache-clear "ebox" nil nil)
;; Release cached preparations and paint composites without changing live images.
;;
;; Variable: ebox-image-converters
;; Ordered (NAME . FUNCTION) image converters, called only by preparation.
;;
;;;; Ebox files
;;
;; Function: ebox-file-read-form (source)
;;;###autoload (autoload 'ebox-file-read-form "ebox" nil nil)
;; Read exactly one Elisp expression from SOURCE.
;;
;; Function: ebox-file-read-file (file)
;;;###autoload (autoload 'ebox-file-read-file "ebox" nil nil)
;; Read one Ebox expression from FILE without evaluating it.
;;
;; Function: ebox-file-evaluate-form (form &optional source-file)
;;;###autoload (autoload 'ebox-file-evaluate-form "ebox" nil nil)
;; Evaluate FORM once, loading SOURCE-FILE companions and local styles.
;;
;; Function: ebox-file-evaluate-buffer (&optional buffer)
;;;###autoload (autoload 'ebox-file-evaluate-buffer "ebox" nil nil)
;; Evaluate the Ebox expression in BUFFER through the core file contract.
;;
;; Function: ebox-file-load-companion (&optional file)
;;;###autoload (autoload 'ebox-file-load-companion "ebox" nil nil)
;; Load FILE's same-basename `.el' companion when it exists.  A compiled
;; companion is used only when it is newer than the source.
;;
;; Function: ebox-file-preview (&optional buffer)
;;;###autoload (autoload 'ebox-file-preview "ebox" nil t)
;; Render the `.ebox' source in BUFFER into a dedicated preview buffer.
;;
;;;; Errors
;;
;; Error: ebox-error
;; Ebox error
;;
;; Error: ebox-input-error
;; Invalid Ebox input session
;;
;; Error: ebox-input-cancelled
;; Ebox input target is no longer available
;;
;; Error: ebox-size-error
;; Invalid Ebox size
;;
;; Error: ebox-style-schema-error
;; Invalid Ebox style schema
;;
;;;; Build
;;
;; Function: ebox-byte-compile ()
;;;###autoload (autoload 'ebox-byte-compile "ebox" nil t)
;; Recompile every Ebox Lisp source into a neighboring `.elc' file.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name
                "lisp"
                (file-name-directory
                 (or (and load-file-name
                          ;; A native-compiled file lives in `eln-cache',
                          ;; where no sibling `lisp' directory exists.
                          (not (string-suffix-p ".eln" load-file-name))
                          load-file-name)
                     (bound-and-true-p byte-compile-current-file)
                     (locate-library "ebox")
                     buffer-file-name)))))

(require 'ebox-node)
(require 'ebox-layout)
(require 'ebox-flex)
(require 'ebox-buffer)
(require 'ebox-interaction)
(require 'ebox-viewport)
(require 'ebox-image)
(require 'ebox-file)

(provide 'ebox)
;;; ebox.el ends here
