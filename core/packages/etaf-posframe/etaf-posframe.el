;;; etaf-posframe.el --- Floating ETAF panels in child frames -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.6
;; Package-Requires: ((emacs "29.1") (etaf "0.3.20") (etaf-ui "0.3.15") (posframe "0.9.0"))
;; Keywords: frames, ui
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; Public API
;;
;; This package shows any ETAF View in a floating child frame, so a panel does
;; not occupy a window, does not replace the current buffer and does not disturb
;; the user's window layout.  It renders with ETAF, sizes the frame from the
;; rendered content and owns the panel lifecycle.  A graphical frame and a text
;; terminal with the Emacs 31 child frame feature both work.  A terminal draws
;; the frame border in one cell that sits outside the frame size, so the panel
;; anchors and the frame fit count that cell, and the border takes the
;; terminal's colours.
;;
;; Panels are independent: each has its own frame, Runtime and behaviour, and
;; several may be open at once.  A panel never changes the selected buffer; with
;; `:focusable' it can take the keyboard.  It stays until it is closed unless
;; `:auto-hide' asks it to hide when the user works elsewhere.  A click anywhere
;; in a panel raises it above the other panels.
;;
;; Load this package with (require 'etaf-posframe) after adding this repository,
;; ETAF and Posframe roots to `load-path'.  Only the interfaces listed below are
;; supported for use by other packages; unlisted symbols are internal even
;; without a double hyphen.  The ETAF Reference Manual holds the workflows, in
;; its Floating Panels and Panel Applications chapters.
;;
;; Function: etaf-posframe-show (view &rest options)
;;;###autoload (autoload 'etaf-posframe-show "etaf-posframe" nil t)
;; Show VIEW in a floating panel and return the panel.  VIEW is a View or a
;; zero-argument function returning one; it is mounted fresh for this panel and
;; receives its own Runtime.  The panel follows the current buffer at call time.
;; OPTIONS is a plist:
;;
;;   :at         Placement.  An anchor (`frame-top-right', `window-center',
;;               `point' ...), `(ANCHOR ROWS COLS)' to shift an anchor by
;;               character cells (negative rows go up and columns left),
;;               `(cells ROW COL)' for a character cell of the current window,
;;               `(pixels X . Y)' for frame pixels, or a posframe poshandler.
;;               Default 'point.
;;   :stack      With an anchor `:at', place the panel against the live panels
;;               at that anchor: directly below the lowest one it meets, or
;;               above the highest from a bottom anchor, in a column to the
;;               left only when the frame has no room.  Default nil.
;;   :width      Content columns, default `etaf-posframe-default-width', or
;;               `(fraction 0.5)' for half the parent frame's width.  Clamped
;;               to the parent frame; a frame resized from outside becomes the
;;               width instead and the View re-lays out at it.
;;   :height     Row budget, default `etaf-posframe-default-max-height', or
;;               `(fraction 0.5)' for half the parent frame's height.  Taller
;;               content clips; a frame resized from outside becomes the budget.
;;   :fill-height  Keep the frame at the row budget instead of shrinking to the
;;               content, so an application with a fixed-size board fills the
;;               stage it asked for.
;;   :resizable  Which edges accept a resize, default t: the user or a caller
;;               may change the frame from any edge.  Nil refuses them and puts
;;               the frame back where it was; a list of `left', `right', `top'
;;               and `bottom'
;;               accepts only the edges it names.  A width change that also
;;               moved the frame counts as its left edge, otherwise as the
;;               right one, and a height change reads the same way as `top' or
;;               `bottom'.  The panel's own fit to its content is not a resize,
;;               so a `nil' panel still shrinks to short content.
;;   :title      Title-bar text.  Without it the panel has no header line and
;;               cannot be dragged.
;;   :draggable  Move the panel by dragging its title bar.  Needs `:title'.
;;   :focusable  Let the panel take the keyboard, so its View's `:keys', text
;;               inputs and buttons receive input.  Default nil.  Clicking any
;;               part of a panel raises it above the other panels either way.
;;   :focus-on-open  Select the panel on open, default `:focusable'.  Nil on a
;;               focusable panel leaves it unfocused until it is clicked.
;;   :auto-hide  nil (default) keeps the panel until it is closed; t hides it
;;               when the user works elsewhere, so a preview disappears as soon
;;               as the pointer or the keyboard moves on; a number hides it
;;               after that many seconds.
;;   :theme      `auto' (default) follows the Emacs theme; `light' or `dark'
;;               pin the panel to that palette; a Theme plist (or a ref) uses
;;               that palette as it is.  An application that declares its own
;;               surface with `etaf-surface-declare' paints the panel from that
;;               palette and brings its own mode switch, so `:theme' applies to
;;               the panels whose content does not.
;;   :border     Plist `(:width W :color C :focus F :hover H)' for the frame
;;               border: W pixels 0..19, and the resting, focused and hovered
;;               colours.  Defaults: `etaf-posframe-border-width', the Theme's
;;               panel border, and its accent mixed into the panel surface
;;               with `etaf-posframe-border-focus-strength' or
;;               `etaf-posframe-border-hover-strength'.  A text terminal draws
;;               one border cell in the terminal's colours, whatever W and the
;;               colours ask for.
;;   :key        Identity of the panel.  Showing a View with a key that is
;;               already live replaces that panel; different keys keep their
;;               own frame, Runtime and position.
;;   :scrollable When non-nil (default), the panel buffer may scroll when its
;;               content exceeds the window.  Nil locks the viewport at the top
;;               and swallows wheel and scroll commands so fixed popovers never
;;               scroll accidentally.
;;   :on-escape  Optional function called with `(PANEL)' when `ESC' or `C-g'
;;               runs inside the focused panel instead of hiding it.
;;   :on-blur    Optional function called with `(PANEL)' when input focus
;;               leaves the panel for another frame.
;;   :on-move    Optional function called with `(X Y PANEL)' after the user
;;               drags the panel to a new position.
;;
;; Signal `etaf-posframe-error' for an unknown option, an invalid anchor or a
;; display that cannot show child frames.  A failed show unmounts the View and
;; deletes the frame before the error is re-signaled.
;;
;; Function: etaf-posframe-reshape (panel &rest options)
;;;###autoload (autoload 'etaf-posframe-reshape "etaf-posframe" nil nil)
;; Update a live PANEL in place without recreating its frame or unmounting its
;; View.  OPTIONS accepts `:width', `:height', `:at', `:theme', `:border',
;; `:fill-height' and `:focus-on-open'.  Resizes, re-lays out and re-anchors
;; the existing child frame smoothly around its anchor or pinned position.
;; Return PANEL when live, or nil.
;;
;; Function: etaf-posframe-focus (panel)
;;;###autoload (autoload 'etaf-posframe-focus "etaf-posframe" nil nil)
;; Give input focus to a live focusable PANEL, remembering the parent frame so
;; hiding or unfocusing returns focus cleanly.  Return PANEL when focused.
;;
;; Function: etaf-posframe-unfocus (panel)
;;;###autoload (autoload 'etaf-posframe-unfocus "etaf-posframe" nil nil)
;; Return input focus from a live PANEL back to its remembered host frame
;; without hiding PANEL.  Return non-nil when focus was restored.
;;
;; Function: etaf-posframe-drag (panel &optional on-done)
;;;###autoload (autoload 'etaf-posframe-drag "etaf-posframe" nil nil)
;; Drag a live PANEL interactively with the mouse pointer, keeping it clamped
;; inside its parent frame.  Works on headerless panels without `:title'.  Only
;; a real drag pins the moved position and calls ON-DONE with `(X Y PANEL)'.
;;
;; Function: etaf-posframe-hide (&optional panel)
;;;###autoload (autoload 'etaf-posframe-hide "etaf-posframe" nil t)
;; Hide PANEL and release its Runtime, timer and frame.  PANEL defaults to the
;; newest panel of the current buffer, which is what the panel's own keys call.
;; Other panels stay open.  Return non-nil when a live panel was hidden.  Safe
;; to call repeatedly.
;;
;; Function: etaf-posframe-toggle (view &rest options)
;;;###autoload (autoload 'etaf-posframe-toggle "etaf-posframe" nil t)
;; Hide the panel of the same `:key', or show VIEW with OPTIONS.  Without `:key'
;; this is the newest panel of the current buffer.  Return the new panel, or nil
;; when it hid one.  This is the entry for a key binding that opens and closes
;; the same panel without touching the others.
;;
;; Function: etaf-posframe-refresh (&optional panel)
;;;###autoload (autoload 'etaf-posframe-refresh "etaf-posframe" nil t)
;; Schedule PANEL to re-lay out at its frame width and fit the frame to the
;; rendered content.  PANEL defaults to the current buffer's panel.  A frame
;; resized from outside becomes the panel width, so the View reflows and the
;; title bar repaints to the new column count.  The fit is deferred past the
;; current event and render, so it is safe to call from a Button, a timer or a
;; theme callback.  A panel also re-fits automatically when its host frame
;; changes size.  Return non-nil when PANEL is live.
;;
;; Function: etaf-posframe-register-app (id &rest options)
;;;###autoload (autoload 'etaf-posframe-register-app "etaf-posframe" nil t)
;; Register an ETAF application as a floating panel, so callers open it with one
;; call instead of writing their own command.  ID is a symbol naming the
;; application.  OPTIONS is a plist:
;;
;;   :title      Human name; it is the panel's title-bar text.
;;   :shortcut   Key string that `etaf-posframe-app-prefix' binds to this app.
;;   :create     Function returning a fresh session for the application.
;;   :view       Function taking that session and returning its View.
;;   :require    Feature to load before creating a session.
;;   :keep-alive t hides the panel on close and keeps the session for the next
;;               open, so music or a game continues; nil (default) stops the
;;               application.  `etaf-posframe-app-quit' stops it either way.
;;   :on-stop    Function called with the session when the application stops.
;;   :width, :height, :at, :stack, :focusable, :focus-on-open, :auto-hide,
;;   :theme, :border, :draggable, :resizable
;;               Same meaning as in `etaf-posframe-show'.  Defaults: top-right
;;               anchor, stacked, the default size, focused on open.
;;
;; Registering the same ID again replaces its record and its shortcut.  A closed
;; panel leaves nothing running unless `:keep-alive' is set.  Registration checks
;; ID, `:create' and `:view'; the remaining values are used and checked when the
;; panel opens, so an invalid panel option signals from `etaf-posframe-app'.
;;
;; Function: etaf-posframe-bind-app (id &optional shortcut &rest overrides)
;;;###autoload (autoload 'etaf-posframe-bind-app "etaf-posframe" nil nil)
;; Register application ID from ETAF's `etaf-app-get' registry as a floating
;; panel without repeating `:title', `:create', `:view', `:on-stop' or `:panel'
;; defaults.  Optional SHORTCUT binds a key in `etaf-posframe-app-map'; keyword
;; OVERRIDES replace any manifest panel or lifecycle option.  Signals
;; `etaf-posframe-error' when ID is not registered in `etaf-app' or declares
;; no `:session'.  Return ID.
;;
;; Function: etaf-posframe-bind-apps (specs)
;;;###autoload (autoload 'etaf-posframe-bind-apps "etaf-posframe" nil nil)
;; Bind multiple applications from ETAF's `etaf-app' registry in one call.
;; Each item in SPECS is `ID', `(ID . SHORTCUT)' or `(ID SHORTCUT . OVERRIDES)'.
;; Entries whose ID is not currently registered or declares no `:session' are
;; skipped cleanly.  Return the list of bound application IDs.
;;
;; Function: etaf-posframe-app-quit (id)
;;;###autoload (autoload 'etaf-posframe-app-quit "etaf-posframe" nil t)
;; Stop application ID: hide its panel, call its `:on-stop' with the session and
;; drop the session, so a `:keep-alive' app really exits.
;;
;; Function: etaf-posframe-app (id)
;;;###autoload (autoload 'etaf-posframe-app "etaf-posframe" nil t)
;; Open ID's panel, or close it when it is already open.  Interactively with no
;; ID it prompts among the registered applications.  Opening mounts the whole
;; application, so a repeat within `etaf-posframe-app-repeat-delay' seconds is
;; ignored.
;;
;; Function: etaf-posframe-cycle ()
;;;###autoload (autoload 'etaf-posframe-cycle "etaf-posframe" nil t)
;; Move input focus to the next open panel, and from the last one back to the
;; frame it belongs to.  With no panel focused this focuses the most recent
;; panel.  Bind it to a key to walk between the open applications and the
;; buffer behind them.
;;
;; Function: etaf-posframe-app-prefix ()
;;;###autoload (autoload 'etaf-posframe-app-prefix "etaf-posframe" nil t)
;; Read one key and open the registered application bound to it.  Bind this once,
;; for example to (kbd "C-c p"), and every registration's `:key' works without
;; the caller rebuilding a keymap.  The same prefix carries the panel controls:
;; the arrow keys move the panel, `=' and `-' widen or narrow it, `>' and `<'
;; heighten or shorten it, and `k' forwards the next key to the panel.  The
;; arrow keys stay live after the first press, so one prefix reaches a run of
;; moves.  Those controls are what a text terminal has, because a child frame
;; there takes neither the keyboard nor the mouse.
;;
;; Function: etaf-posframe-move (direction &optional steps panel)
;;;###autoload (autoload 'etaf-posframe-move "etaf-posframe" nil t)
;; Move PANEL STEPS cells in DIRECTION (`left', `right', `up' or `down'; STEPS
;; defaults to 1) and keep that place through later refreshes.  PANEL defaults
;; to the panel of the selected frame, else the most recent one.  Interactively
;; it prompts for the direction.  Signals `etaf-posframe-error' when no live
;; panel is available.
;;
;; Function: etaf-posframe-resize (axis &optional steps panel)
;;;###autoload (autoload 'etaf-posframe-resize "etaf-posframe" nil t)
;; Change PANEL's size by STEPS cells along AXIS (`wider', `narrower', `taller'
;; or `shorter'; STEPS defaults to 1).  The new width and row budget survive
;; later refreshes because the size becomes the panel's `:fill-height' budget.
;; PANEL defaults as for `etaf-posframe-move'.
;;
;; Function: etaf-posframe-send-key (&optional panel)
;;;###autoload (autoload 'etaf-posframe-send-key "etaf-posframe" nil t)
;; Read one key sequence and run it with PANEL's buffer current.  This reaches
;; the panel's own keys from an ordinary buffer, which is the only route a text
;; terminal has.  A key the View declares runs there; a control that needs the
;; keyboard focus on one row, such as a button reached through Tab, still needs
;; a graphical frame.  Signals `etaf-posframe-error' without a live panel.
;;
;; Variable: etaf-posframe-apps
;; Registered applications as (ID . PLIST) records, in registration order.
;;
;; Variable: etaf-posframe-app-map
;; Keymap with one binding per registered `:key', for callers that prefer to
;; bind the map itself.
;;
;; Function: etaf-posframe-panel-frame (panel)
;; Return PANEL's child frame, or nil when PANEL is not live.
;; Read or compare the frame with this instead of reaching into package
;; internals, for example to place another panel relative to it.
;;
;; Function: etaf-posframe-live-p (panel)
;; Return non-nil while PANEL's frame exists and its Runtime is mounted.
;;
;; Function: etaf-posframe-panels ()
;; Return the live panels, most recent first.
;;
;; Function: etaf-posframe-theme (&optional frame mode)
;; Return an ETAF UI Theme plist derived from FRAME's default face.
;; MODE `light' or `dark' pins the palette to that mode instead; nil follows
;; FRAME.  Pass it to `etaf-theme-provide' in a Component `:setup' when a panel
;; builds its own boundary.  Panels created by `etaf-posframe-show' already
;; provide it.
;;
;; Variable: etaf-posframe-default-width
;; Columns of a new panel when `:width' is absent.
;;
;; Variable: etaf-posframe-default-max-height
;; Maximum content lines of a new panel when `:height' is absent.
;;
;; Variable: etaf-posframe-move-step
;; Character cells `etaf-posframe-move' moves when it gets no step count, 3.
;; One step is one character, so a graphical frame moves by its character width
;; and height and a terminal by its single cell.
;;
;; Variable: etaf-posframe-resize-step
;; Columns or rows `etaf-posframe-resize' changes when it gets no step count,
;; 1.  Raise it to reach a wanted size in fewer presses.
;;
;; Variable: etaf-posframe-hide-inactive
;; Hide the panels while Emacs is not the active application.  A child frame is
;; a window of its own, so a window manager that lists windows (macOS Mission
;; Control) would offer the panel as a target and clicking it activates Emacs
;; instead of the application behind it.  Default t.  It applies to graphical
;; frames only: a terminal frame is not listed as a window and its panels are
;; always visible.
;;
;; Variable: etaf-posframe-focus-follows-mouse
;; Move the input focus to a panel the mouse pointer rests on, so hovering shows
;; the focused border and a click does not change it.  Default nil; only panels
;; that accept the keyboard are focused.  The hover border needs no option:
;; the panel under the pointer paints its border accent and keeps the keyboard.
;;
;; Variable: etaf-posframe-dark-surface
;; Neutral near-black a dark panel surface sinks toward, `#101214' by default.
;; Dark applications paint a flat near-black surface, so sinking the panel by
;; `etaf-posframe-dark-shade' keeps it in that family instead of lifting the
;; theme colour into a grey card.
;;
;; Variable: etaf-posframe-dark-shade
;; How far a dark panel surface sinks toward `etaf-posframe-dark-surface', 0 to
;; 1, 0.5 by default.
;;
;; Variable: etaf-posframe-surface-lift
;; How far a light panel surface sinks toward black, 0 to 0.5, 0.03 by default.
;; A light panel keeps a faint grey so it still reads as a surface.
;;
;; Variable: etaf-posframe-border-width
;; Frame border width in pixels, 0..19, used when `:border' has no `:width'.
;; Default 1.  A text terminal draws the border in one cell, so a wider request
;; keeps a one-cell border, and the border takes the terminal's default
;; foreground colour because terminal frames have no per-frame border face.
;;
;; Variable: etaf-posframe-border-focus-strength
;; How much of the Theme accent a focused border shows, 0 to 1.  Default 0.6;
;; the border is the panel surface tinted toward the theme's `link' colour, so
;; the panel follows the user's palette.  A panel's `:border' `:focus' colour
;; replaces the tint.
;;
;; Variable: etaf-posframe-border-hover-strength
;; The same for a hovered panel, default 0.3.  Keep it below
;; `etaf-posframe-border-focus-strength' so hovering hints and clicking commits
;; stay distinct; a panel's `:border' `:hover' colour replaces the tint.
;;
;; A panel never enables `track-mouse': Emacs then selects the frame under the
;; pointer whenever it moves, so leaving a panel would take the keyboard with
;; the pointer.  The hover border reads the pointer from a timer instead, and
;; only a click moves the keyboard.
;;;;
;; Variable: etaf-posframe-app-repeat-delay
;; Seconds during which a repeated app toggle is ignored, 0.3 by default.
;; Opening a panel mounts a whole application, so key repeat would otherwise
;; mount it once per repeat and stall Emacs.
;;
;; Variable: etaf-posframe-panel-keys
;; Keymap that is always active while a focusable panel has focus.  It closes
;; the panel on `q', `ESC' and `C-g' and outranks the View's own keys only for
;; those three bindings.
;;
;; Error: etaf-posframe-error
;; Signals invalid panel input and unavailable capabilities.

;;; Code:

(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-posframe")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-posframe.el" dir))
                                (file-exists-p (expand-file-name "etaf-posframe.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'posframe)
(require 'etaf-posframe-pool)
(require 'etaf-posframe-panel)
(require 'etaf-posframe-layout)
(require 'etaf-posframe-app)
(require 'etaf-posframe-modal)

(provide 'etaf-posframe)
;;; etaf-posframe.el ends here
