;;; etaf-posframe.el --- Floating ETAF panels in child frames -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.3.0") (posframe "0.9.0"))
;; Keywords: frames, ui
;; URL: https://github.com/emacs-taf/etaf-posframe

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
;;
;; Signal `etaf-posframe-error' for an unknown option, an invalid anchor or a
;; display that cannot show child frames.  A failed show unmounts the View and
;; deletes the frame before the error is re-signaled.
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

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'posframe)

(defgroup etaf-posframe nil
  "Floating ETAF panels in child frames."
  :group 'etaf
  :prefix "etaf-posframe-")

(defcustom etaf-posframe-default-width 56
  "Content columns of a panel without :width."
  :type 'integer
  :group 'etaf-posframe)

(defcustom etaf-posframe-default-max-height 30
  "Maximum content lines of a panel without :height."
  :type 'integer
  :group 'etaf-posframe)

(defcustom etaf-posframe-move-step 3
  "Cells a panel moves per `etaf-posframe-move' without an explicit count.
One cell is one character: a graphical frame moves by the frame's character
width and height, a terminal by its single cell.  The default moves a panel
far enough to see one press and still lets a held arrow key stop where the
user means."
  :type 'integer
  :group 'etaf-posframe)

(defcustom etaf-posframe-resize-step 1
  "Columns or rows a panel changes per `etaf-posframe-resize'.
The default changes one cell, which keeps a narrow panel from overshooting
its frame; raise it to reach a wanted width in fewer presses."
  :type 'integer
  :group 'etaf-posframe)

(defcustom etaf-posframe-dark-shade 0.5
  "How far a dark theme's panel surface sinks toward `etaf-posframe-dark-surface'.
Dark applications such as the NetEase player paint a flat near-black surface;
sinking the panel by half keeps the panel in that family instead of lifting the
theme colour into a grey card."
  :type 'number
  :group 'etaf-posframe)

(defcustom etaf-posframe-dark-surface "#101214"
  "Neutral near-black a dark panel surface sinks toward.
This is the surface family dark applications use, so a panel and such an
application read as one design."
  :type 'color
  :group 'etaf-posframe)

(defcustom etaf-posframe-surface-lift 0.03
  "How far a light theme's panel surface sinks toward black, 0 to 0.5.
A light panel keeps a faint grey so it still reads as a surface."
  :type 'number
  :group 'etaf-posframe)

(defcustom etaf-posframe-focus-follows-mouse nil
  "Move the input focus to a panel the mouse pointer enters.
The panel under the pointer takes the keyboard as soon as the pointer is on it,
so hovering shows the focused border and a click does not change the panel.
Only panels that accept the keyboard are focused; nil keeps the focus on what
you click, which is the default because a resting pointer should not move the
keyboard away from another window."
  :type 'boolean
  :group 'etaf-posframe)

(defcustom etaf-posframe-hide-inactive t
  "Hide panels while Emacs is not the active application.
A child frame is a window of its own, so a window manager can list it beside the
real windows, where clicking one activates Emacs instead of the intended
application.  Hiding the panels while Emacs is inactive keeps them out of that
list; they come back when Emacs is active again.  Nil keeps them visible."
  :type 'boolean
  :group 'etaf-posframe)

(defcustom etaf-posframe-border-width 1
  "Border drawn around a panel, in pixels, unless `:border' sets a width.
A one pixel border in the theme's border colour is what separates the panel
from the buffer behind it and makes it read as a floating surface."
  :type 'integer
  :group 'etaf-posframe)

(defcustom etaf-posframe-border-focus-strength 0.60
  "How much of the Theme accent a focused border shows, 0 to 1.
The border is the panel surface tinted toward the Theme's `link' colour: 0
keeps the surface and 1 paints the accent itself.  A per-panel `:border'
`:focus' colour replaces the tint entirely."
  :type 'number
  :group 'etaf-posframe)

(defcustom etaf-posframe-border-hover-strength 0.30
  "How much of the Theme accent a hovered border shows, 0 to 1.
A hovered panel does not hold the keyboard, so it hints at the accent more
weakly than a focused one.  Keep it below `etaf-posframe-border-focus-strength'
so the two states stay distinct; a per-panel `:border' `:hover' colour
replaces the tint entirely."
  :type 'number
  :group 'etaf-posframe)

(defconst etaf-posframe--stack-gap 6
  "Pixels left between panels stacked at the same place.")

(defconst etaf-posframe--margin 2
  "Free columns kept between a panel and its parent frame edge.")

(define-error 'etaf-posframe-error "ETAF panel error")

(defvar etaf-posframe--panels nil
  "Live panels, most recent first.")

(defvar etaf-posframe--counter 0
  "Panel sequence number used for buffer names.")

(defvar-local etaf-posframe--panel nil
  "Panel shown in this buffer, or nil.")

(defvar etaf-posframe--dismissing nil
  "Non-nil while a dismissal pass runs, to avoid re-entrant hooks.")

(defvar etaf-posframe--hover-panel nil
  "Panel whose surface the mouse pointer is on, or nil.")

(defconst etaf-posframe--hover-interval 0.2
  "Seconds between pointer readings while panels exist.")

(defvar etaf-posframe--hover-timer nil
  "Timer that reads the pointer while panels exist.")

(defvar etaf-posframe--theme-timer nil
  "Pending coalesced theme pass for the live panels.")

(defvar-local etaf-posframe--parent-panel nil
  "Panel anchored to this buffer, or nil.")

(defun etaf-posframe--parent-killed ()
  "Hide every panel anchored to the buffer being killed."
  (let ((buffer (current-buffer)))
    (dolist (panel (copy-sequence (etaf-posframe-panels)))
      (when (eq (etaf-posframe--panel-parent panel) buffer)
        (etaf-posframe-hide panel)))))

(defun etaf-posframe--panel-for-frame (frame)
  "Return the live panel displayed by FRAME, or nil."
  (cl-find-if (lambda (panel) (eq (etaf-posframe--panel-frame panel) frame))
              etaf-posframe--panels))

(defun etaf-posframe--anchor-frame (frame)
  "Return the frame a panel opened from FRAME belongs to.
A panel frame is itself a child: a new panel belongs to the frame underneath,
so closing the covering panel cannot delete the new one with it."
  (if-let* ((panel (etaf-posframe--panel-for-frame frame))
            (parent (etaf-posframe--panel-parent-frame panel))
            ((frame-live-p parent)))
      (etaf-posframe--anchor-frame parent)
    frame))

(defun etaf-posframe--anchor-buffer (buffer)
  "Return the buffer a panel opened in BUFFER belongs to.
A panel whose buffer is current is another panel's surface, possibly shown on
top of a third; the new panel belongs to the first plain buffer, so closing the
covering panel cannot take the new panel with it."
  (let ((panel (and (buffer-live-p buffer)
                    (buffer-local-value 'etaf-posframe--panel buffer))))
    (if (and (etaf-posframe--panel-p panel)
             (buffer-live-p (etaf-posframe--panel-parent panel)))
        (etaf-posframe--anchor-buffer (etaf-posframe--panel-parent panel))
      buffer)))

(defvar etaf-posframe-panel-keys
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'etaf-posframe-hide)
    (define-key map [escape] #'etaf-posframe-hide)
    (define-key map (kbd "C-g") #'etaf-posframe-hide)
    map)
  "Keys active while a focusable panel has focus.
They close the panel without consulting the View.")

(add-to-list 'emulation-mode-map-alists
             (list (cons 'etaf-posframe--panel etaf-posframe-panel-keys)))

(cl-defstruct (etaf-posframe--panel (:constructor etaf-posframe--make-panel))
  buffer frame parent parent-frame options timer restore-frame focused
  fit-timer settled fit-window fit-count fit-muted-until close-callback size
  position pin-applied)

;; A panel is returned to callers, so it must print: the Runtime and the Theme
;; ref are cyclic (refs, keymaps, closures), and `prin1' on them loops until
;; Emacs runs out of memory.  Both live beside the panel buffer instead and are
;; looked up here; the panel itself only keeps printable slots (buffers,
;; frames, a data plist, timers).

(defvar-local etaf-posframe--theme-ref nil
  "Theme ref of the panel mounted in this buffer.")

(defvar-local etaf-posframe--surface nil
  "Surface declaration the panel provides to its content, or nil.")

(defvar-local etaf-posframe--appearance-ref nil
  "Appearance ref the panel provides to the View mounted in this buffer.")

(defvar-local etaf-posframe--surface-scope nil
  "Effect scope watching the surface the panel's content declared.")

(defun etaf-posframe--panel-surface (panel)
  "Return the surface declaration PANEL provides to its content, or nil."
  (let ((buffer (etaf-posframe--panel-buffer panel)))
    (and (buffer-live-p buffer)
         (buffer-local-value 'etaf-posframe--surface buffer))))

(defun etaf-posframe--panel-appearance (panel)
  "Return the appearance ref PANEL provides to its content, or nil."
  (let ((buffer (etaf-posframe--panel-buffer panel)))
    (and (buffer-live-p buffer)
         (buffer-local-value 'etaf-posframe--appearance-ref buffer))))

(defun etaf-posframe--panel-runtime (panel)
  "Return PANEL's mounted Runtime.
It is looked up from the panel buffer, so the panel struct stays printable."
  (let ((buffer (etaf-posframe--panel-buffer panel)))
    (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer))))

(defun etaf-posframe--panel-theme (panel)
  "Return PANEL's Theme ref, or nil when the panel is not live."
  (let ((buffer (etaf-posframe--panel-buffer panel)))
    (and (buffer-live-p buffer)
         (buffer-local-value 'etaf-posframe--theme-ref buffer))))

(defconst etaf-posframe--fit-limit 20
  "Fits a panel allows within one second before it backs off.")

(defconst etaf-posframe--fit-backoff 2
  "Seconds a panel stops fitting after it exceeded `etaf-posframe--fit-limit'.")

;;; Theme

(defun etaf-posframe--color (color)
  "Return COLOR as an #RRGGBB string, or nil when it is not a color."
  (when (and (stringp color)
             (ignore-errors (color-name-to-rgb color)))
    (apply #'color-rgb-to-hex
           (append (color-name-to-rgb color) '(2)))))

(defun etaf-posframe--mix (from to amount)
  "Mix hex colors FROM and TO by AMOUNT toward TO."
  (let ((start (color-name-to-rgb from))
        (end (color-name-to-rgb to)))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (a b) (+ a (* (- b a) amount))) start end)
                   '(2)))))

(defun etaf-posframe--dark-color-p (color)
  "Return non-nil when COLOR is a dark surface."
  (let ((rgb (ignore-errors (color-name-to-rgb color))))
    (and rgb (< (+ (* 0.2126 (nth 0 rgb))
                   (* 0.7152 (nth 1 rgb))
                   (* 0.0722 (nth 2 rgb)))
                0.5))))

(defun etaf-posframe--ink-on (color)
  "Return readable ink for text on a fill of COLOR.
The ink follows the fill's luminance, not the palette's mode: a dark theme may
carry a pale accent and a light theme a deep one, and the label has to stay
readable on the accent either way."
  (let ((rgb (ignore-errors (color-name-to-rgb color))))
    (if (and rgb (> (+ (* 0.2126 (nth 0 rgb))
                       (* 0.7152 (nth 1 rgb))
                       (* 0.0722 (nth 2 rgb)))
                    0.55))
        "#101418"
      "#FFFFFF")))

(defconst etaf-posframe--light-base '("#F7F8FA" . "#1F2328")
  "Background and foreground of a panel pinned to the light mode.")

(defconst etaf-posframe--dark-base '("#16191D" . "#D8DEE6")
  "Background and foreground of a panel pinned to the dark mode.")

(defun etaf-posframe-theme (&optional frame mode)
  "Return an ETAF UI Theme plist for FRAME, pinned to MODE when given.
MODE is `light' or `dark' to keep the panel on that mode whoever the Emacs
theme is, which is what a game with a fixed board needs; nil derives the mode
from FRAME.  A pinned panel keeps the frame's accent, so its controls still
follow the user's palette.  Every value is an #RRGGBB color, so the result is a
literal token plist accepted by `etaf-theme-provide'."
  (let* ((frame (or frame (selected-frame)))
         (pinned (memq mode '(light dark)))
         ;; Ask FRAME itself.  An explicit nil INHERIT answers for the selected
         ;; frame instead, and signals on an inherited face such as `link', so
         ;; a panel that held the keyboard derived its palette from its own
         ;; frame.
         (frame-bg (etaf-posframe--color
                    (face-attribute 'default :background frame)))
         (frame-fg (etaf-posframe--color
                    (face-attribute 'default :foreground frame)))
         (frame-base (and frame-bg frame-fg (cons frame-bg frame-fg)))
         ;; The frame's own surface decides the mode: a theme may leave the
         ;; `background-mode' parameter stale after the colors change.
         (frame-dark (and frame-base (etaf-posframe--dark-color-p frame-bg)))
         (dark (cond (pinned (eq mode 'dark))
                     (frame-base frame-dark)
                     (t (eq (frame-parameter frame 'background-mode) 'dark))))
         ;; A pin that agrees with the frame keeps the frame's own surface, so
         ;; following the theme and pinning to its mode paint the same panel.
         ;; A pin that disagrees, or a frame without resolved colours such as a
         ;; batch frame, needs a base of the pinned polarity.
         (base (if (or (and pinned (not (eq dark frame-dark)))
                       (null frame-base))
                   (if dark etaf-posframe--dark-base etaf-posframe--light-base)
                 frame-base))
         (bg (car base))
         (fg (cdr base))
         ;; The panel must read as a surface above the buffer, not blend
         ;; into it: lift it clearly in dark themes and drop it in light ones.
         (panel (if dark
                    (etaf-posframe--mix bg etaf-posframe-dark-surface
                                        etaf-posframe-dark-shade)
                  (etaf-posframe--mix bg "#000000"
                                      etaf-posframe-surface-lift)))
         ;; A hairline, not a frame: enough to separate the surface from the
         ;; buffer, light enough not to read as a drawn box.
         (border (etaf-posframe--mix panel fg 0.16))
         (muted (etaf-posframe--mix fg panel 0.42))
         (accent (or (etaf-posframe--color
                      (ignore-errors (face-attribute 'link :foreground frame)))
                     (if dark "#6CB6FF" "#2F6FE4")))
         (tint (lambda (color amount)
                 (etaf-posframe--mix panel color amount))))
    (list :ui-mode (if dark 'dark 'light)
          :ui-bg bg
          :ui-fg fg
          :ui-muted-fg muted
          :ui-border border
          :ui-panel-bg panel
          :ui-panel-fg fg
          :ui-panel-border border
          :ui-accent accent
          :ui-accent-fg (etaf-posframe--ink-on accent)
          :ui-accent-soft-bg (funcall tint accent 0.12)
          :ui-disabled-fg (etaf-posframe--mix fg panel 0.6)
          :ui-disabled-bg (etaf-posframe--mix panel border 0.12)
          :ui-disabled-border border
          :ui-button-primary-fg (etaf-posframe--ink-on accent)
          :ui-button-primary-bg accent
          :ui-button-secondary-fg (etaf-posframe--mix fg accent 0.35)
          :ui-button-secondary-bg (funcall tint accent 0.18)
          :ui-button-ghost-fg fg
          :ui-info-bg (funcall tint "#6CB6FF" 0.20)
          :ui-info-fg (etaf-posframe--mix fg "#6CB6FF" 0.55)
          :ui-info-border (etaf-posframe--mix panel "#6CB6FF" 0.40)
          :ui-success-bg (funcall tint "#4FB477" 0.20)
          :ui-success-fg (etaf-posframe--mix fg "#4FB477" 0.50)
          :ui-success-border (etaf-posframe--mix panel "#4FB477" 0.40)
          :ui-warning-bg (funcall tint "#E8B45C" 0.20)
          :ui-warning-fg (etaf-posframe--mix fg "#E8B45C" 0.55)
          :ui-warning-border (etaf-posframe--mix panel "#E8B45C" 0.40)
          :ui-danger-bg (funcall tint "#FF7A7A" 0.20)
          :ui-danger-fg (etaf-posframe--mix fg "#FF7A7A" 0.55)
          :ui-danger-border (etaf-posframe--mix panel "#FF7A7A" 0.40))))

;;; Themed surface

(etaf-define-component etaf-posframe--surface (&key theme appearance surface content)
  "Provide THEME, APPEARANCE and the SURFACE slot to CONTENT.
CONTENT is a function returning the View, so the View is built inside this
component's context and inherits all three.  SURFACE lets an application that
owns its palette declare it to the panel instead of taking the panel's; see
`etaf-surface-declare'."
  :setup (progn
           (etaf-theme-provide theme)
           (etaf-appearance-provide appearance)
           (etaf-surface-provide surface)
           nil)
  :render (etaf-view (expr (funcall content))))

;;; Options

(defconst etaf-posframe--anchor-places
  '(top-left top-center top-right
    center-left center center-right
    bottom-left bottom-center bottom-right)
  "Nine places an anchor can name inside its rectangle.")

(defconst etaf-posframe--anchors
  (append '(point point-top)
          (cl-loop for kind in '(frame window)
                   append (cl-loop for place in etaf-posframe--anchor-places
                                   collect (intern (format "%s-%s" kind place)))))
  "Anchors accepted by `etaf-posframe-show' :at.
`frame-*' names the whole parent frame, `window-*' the parent window's text
area, and every place is one of `etaf-posframe--anchor-places'.  `point' and
`point-top' place the panel at point.")

(defconst etaf-posframe--show-keys
  '(:at :stack :width :height :fill-height :focusable :focus-on-open
    :auto-hide :theme :border :draggable :title :key :resizable)
  "Options accepted by `etaf-posframe-show'.")

(defconst etaf-posframe--app-keys
  '(:create :view :require :shortcut :keep-alive :on-stop)
  "Options accepted by `etaf-posframe-register-app'.")

(defconst etaf-posframe--resize-sides '(left right top bottom)
  "Sides a panel may be resized from, as `:resizable' lists them.
`left' and `right' allow a width change from that edge, `top' and `bottom' a
height change from that edge.")

(defconst etaf-posframe--border-keys '(:width :color :focus :hover)
  "Fields of the `:border' option plist.")

(defun etaf-posframe--placement (value)
  "Return the placement VALUE as (KIND . DATA).
KIND is `anchor', `anchor+offset', `cells', `pixels' or `function'."
  (cond
   ((memq value etaf-posframe--anchors) (cons 'anchor value))
   ((functionp value) (cons 'function value))
   ((and (consp value) (eq (car value) 'cells) (= 3 (length value))
         (wholenump (nth 1 value)) (wholenump (nth 2 value)))
    (cons 'cells (cons (nth 1 value) (nth 2 value))))
   ((and (consp value) (eq (car value) 'pixels) (consp (cdr value))
         (numberp (nth 1 value)) (numberp (cddr value)))
    (cons 'pixels (cdr value)))
   ((and (consp value) (memq (car value) etaf-posframe--anchors)
         (= 3 (length value))
         (integerp (nth 1 value)) (integerp (nth 2 value)))
    (list 'anchor+offset (car value) (nth 1 value) (nth 2 value)))
   (t (signal 'etaf-posframe-error
              (list (format "Unsupported panel :at: %S" value))))))

(defun etaf-posframe--validate (options &optional app)
  "Return OPTIONS after checking every key and value.
With APP non-nil the registration keys are accepted as well."
  (unless (proper-list-p options)
    (signal 'etaf-posframe-error (list "Panel options must be a plist" options)))
  (let (result)
    (while options
      (let ((key (pop options))
            (value (pop options)))
        (unless (or (memq key etaf-posframe--show-keys)
                    (and app (memq key etaf-posframe--app-keys)))
          (signal 'etaf-posframe-error
                  (list (format "Unknown panel option: %S" key))))
        (pcase key
          (:at (etaf-posframe--placement value))
          (:resizable
           (unless (or (memq value '(t nil))
                       (and (proper-list-p value)
                            (cl-every (lambda (side)
                                        (memq side etaf-posframe--resize-sides))
                                      value)))
             (signal 'etaf-posframe-error
                     (list (format "Panel :resizable must be t, nil or a list of %s: %S"
                                   etaf-posframe--resize-sides value)))))
          ((or :stack :fill-height :focusable :focus-on-open :draggable
               :keep-alive)
           (unless (memq value '(t nil))
             (signal 'etaf-posframe-error
                     (list (format "Panel %s must be t or nil: %S" key value)))))
          ((or :width :height)
           (unless (or (and (wholenump value) (> value 0))
                       (and (consp value) (eq (car value) 'fraction)
                            (= 2 (length value))
                            (numberp (nth 1 value)) (> (nth 1 value) 0)
                            (<= (nth 1 value) 1)))
             (signal 'etaf-posframe-error
                     (list (format "Panel %s must be a positive cells count or (fraction F): %S"
                                   key value)))))
          (:auto-hide
           (unless (or (memq value '(t nil))
                       (and (numberp value) (> value 0)))
             (signal 'etaf-posframe-error
                     (list (format "Panel :auto-hide must be t, nil or positive seconds: %S"
                                   value)))))
          (:theme
           (unless (or (memq value '(auto light dark))
                       (proper-list-p value)
                       (etaf-ref-p value) (etaf-computed-p value))
             (signal 'etaf-posframe-error
                     (list "Panel :theme must be auto, light, dark, a plist, ref or computed"
                           value))))
          (:border
           (unless (and (proper-list-p value)
                        (zerop (% (length value) 2)))
             (signal 'etaf-posframe-error
                     (list "Panel :border must be a plist" value)))
           (let ((plist value))
             (while plist
               (let ((field (pop plist))
                     (field-value (pop plist)))
                 (unless (memq field etaf-posframe--border-keys)
                   (signal 'etaf-posframe-error
                           (list (format "Unknown :border key: %S" field))))
                 (if (eq field :width)
                     (unless (and (wholenump field-value) (< field-value 20))
                       (signal 'etaf-posframe-error
                               (list (format "Panel :border :width must be 0..19 pixels: %S"
                                             field-value))))
                   (unless (or (null field-value) (stringp field-value))
                     (signal 'etaf-posframe-error
                             (list (format "Panel :border %s must be a color or nil: %S"
                                           field field-value)))))))))
          (:title
           (unless (or (null value) (stringp value))
             (signal 'etaf-posframe-error
                     (list "Panel :title must be a string or nil" value))))
          (:key
           (unless (or (null value) (symbolp value))
             (signal 'etaf-posframe-error
                     (list "Panel :key must be a symbol identity" value))))
          (:create
           (unless (functionp value)
             (signal 'etaf-posframe-error
                     (list "Application :create must be a function" value))))
          (:view
           (unless (functionp value)
             (signal 'etaf-posframe-error
                     (list "Application :view must be a function" value))))
          (:require
           (unless (symbolp value)
             (signal 'etaf-posframe-error
                     (list "Application :require must be a feature symbol" value))))
          (:shortcut
           (unless (and (stringp value) (> (length value) 0))
             (signal 'etaf-posframe-error
                     (list "Application :shortcut must be a key string" value))))
          (:on-stop
           (unless (or (null value) (functionp value))
             (signal 'etaf-posframe-error
                     (list "Application :on-stop must be a function or nil" value)))))
        (setq result (plist-put result key value))))
    (when (and (plist-get result :stack)
               (not (memq (car (etaf-posframe--placement
                                (or (plist-get result :at) 'point)))
                          '(anchor anchor+offset))))
      (signal 'etaf-posframe-error
              (list "Panel :stack needs an anchored :at")))
    result))

(defun etaf-posframe--defaults (options)
  "Return OPTIONS with the panel defaults applied once."
  (let ((options (copy-sequence options)))
    (dolist (pair (list (cons :at 'point)
                        (cons :width etaf-posframe-default-width)
                        (cons :height etaf-posframe-default-max-height)
                        (cons :stack nil)
                        (cons :fill-height nil)
                        (cons :focusable nil)
                        (cons :draggable nil)
                        (cons :title nil)
                        (cons :resizable t)
                        (cons :theme 'auto)))
      (unless (plist-member options (car pair))
        (setq options (plist-put options (car pair) (cdr pair)))))
    (unless (plist-member options :focus-on-open)
      (setq options (plist-put options :focus-on-open
                               (plist-get options :focusable))))
    (unless (plist-member options :auto-hide)
      (setq options (plist-put options :auto-hide
                               (if (plist-get options :focusable) nil t))))
    options))

(defun etaf-posframe--display-supported-p ()
  "Return non-nil when this display can show a child frame.
A graphical frame always can.  A text terminal can when Emacs was built with
the TTY child frame implementation, which Emacs 31 provides as the feature
`tty-child-frames'."
  (or (display-graphic-p) (featurep 'tty-child-frames)))

(defun etaf-posframe--terminal-bevel (frame)
  "Return the cells a terminal child frame border adds around FRAME.
A graphical frame paints its border outside the pixels `frame-pixel-width'
reports, while a terminal draws it in cells that the frame size does not count.
Anchoring a panel with the bare frame size would therefore cut its bottom and
left border off the screen edge."
  (let ((parent (and (frame-live-p frame) (frame-parent frame))))
    (if (and parent
             (not (display-graphic-p parent))
             (> etaf-posframe-border-width 0))
        2
      0)))

(defun etaf-posframe--rect (info kind)
  "Return (LEFT TOP RIGHT BOTTOM) pixels for anchor KIND.
KIND is `frame' for the whole parent frame or `window' for the parent window's
text area."
  (if (eq kind 'window)
      (let* ((window (plist-get info :parent-window))
             (edges (and (window-live-p window)
                         (window-inside-pixel-edges window))))
        (or edges (list 0 0 0 0)))
    (let* ((frame (plist-get info :parent-frame))
           ;; A terminal border sits outside the frame's own cells, so inset
           ;; the anchors by it and let the frame size grow by the same amount.
           (bevel (etaf-posframe--terminal-bevel (plist-get info :posframe)))
           (width (or (plist-get info :parent-frame-width)
                      (and (frame-live-p frame) (frame-pixel-width frame))
                      0))
           (height (or (plist-get info :parent-frame-height)
                       (and (frame-live-p frame) (frame-pixel-height frame))
                       0)))
      (list bevel bevel (max 0 (- width bevel)) (max 0 (- height bevel))))))

(defun etaf-posframe--anchor-position (info kind place)
  "Return the pixel position of PLACE inside KIND for INFO.
The panel keeps a margin to the edge it is anchored to, so it never sits on the
parent's scroll bar or window border."
  (let* ((rect (etaf-posframe--rect info kind))
         (left (nth 0 rect))
         (top (nth 1 rect))
         (right (nth 2 rect))
         (bottom (nth 3 rect))
         (bevel (etaf-posframe--terminal-bevel (plist-get info :posframe)))
         (width (+ (or (plist-get info :posframe-width) 0) bevel))
         (height (+ (or (plist-get info :posframe-height) 0) bevel))
         ;; The margin is one character against a frame's edge and half of one
         ;; against a window's text area.  A TTY reports one pixel per cell, so
         ;; a literal pixel count would push a panel eight cells off the edge.
         (cell (or (plist-get info :font-width) 8))
         (margin (if (eq kind 'window) (max 1 (/ cell 2)) cell))
         (right-edge (max left (- right width margin)))
         (bottom-edge (max top (- bottom height margin)))
         (x (pcase place
              ((or 'top-left 'center-left 'bottom-left) left)
              ((or 'top-right 'center-right 'bottom-right) right-edge)
              (_ (max left (/ (- right left width) 2)))))
         (y (pcase place
              ((or 'top-left 'top-center 'top-right) (+ top margin))
              ((or 'bottom-left 'bottom-center 'bottom-right) bottom-edge)
              (_ (max top (/ (- bottom top height) 2))))))
    (cons x y)))

(defvar etaf-posframe--anchor-handlers
  (let (table)
    (dolist (kind '(frame window))
      (dolist (place etaf-posframe--anchor-places)
        (let ((kind kind) (place place))
          (push (cons (intern (format "%s-%s" kind place))
                      (lambda (info) (etaf-posframe--anchor-position info kind place)))
                table))))
    table)
  "Poshandler of every symbol in `etaf-posframe--anchors'.")

(defun etaf-posframe--frame-rect (frame)
  "Return (X Y WIDTH HEIGHT) of FRAME in its parent's pixels.
`frame-position' is the read side of the `set-frame-position' that placed the
frame: a TTY child frame keeps its origin there and reports nil `left' and
`top' parameters, which would stack every panel at the frame's top left."
  (when (frame-live-p frame)
    (let* ((position (frame-position frame))
           (bevel (etaf-posframe--terminal-bevel frame)))
      (list (or (car position) 0)
            (or (cdr position) 0)
            (+ (frame-pixel-width frame) bevel)
            (+ (frame-pixel-height frame) bevel)))))

(defun etaf-posframe--rect-overlap-p (a b)
  "Return non-nil when rectangles A and B, both (X Y WIDTH HEIGHT), overlap."
  (and (< (nth 0 a) (+ (nth 0 b) (nth 2 b)))
       (> (+ (nth 0 a) (nth 2 a)) (nth 0 b))
       (< (nth 1 a) (+ (nth 1 b) (nth 3 b)))
       (> (+ (nth 1 a) (nth 3 a)) (nth 1 b))))

(defun etaf-posframe--stack-gap (info)
  "Return the cell gap between panels stacked through INFO.
The package gap is in pixels; a terminal reports one pixel per cell, where six
cells would read as a hole rather than a gap."
  (if (> (etaf-posframe--terminal-bevel (plist-get info :posframe)) 0)
      1
    etaf-posframe--stack-gap))

(defun etaf-posframe--stack-clear-y (x y width height top bottom down others info)
  "Return the Y nearest Y where a WIDTH by HEIGHT panel at X is clear.
DOWN stacks the panel below every panel it meets and otherwise stacks it above
them, keeping `etaf-posframe--stack-gap' between the frames.  OTHERS are the
live panels as (X Y WIDTH HEIGHT).  Return nil when no such Y lies between TOP
and BOTTOM."
  (let ((y y)
        (gap (etaf-posframe--stack-gap info))
        (guard 0))
    (while (and (< guard 100)
                (cl-some (lambda (other)
                           (etaf-posframe--rect-overlap-p
                            (list x y width height) other))
                         others))
      (let* ((rect (list x y width height))
             (blocking (cl-remove-if-not
                        (lambda (other)
                          (etaf-posframe--rect-overlap-p rect other))
                        others))
             (edge (if down
                       (apply #'max
                              (mapcar (lambda (other)
                                        (+ (nth 1 other) (nth 3 other)))
                                      blocking))
                     (apply #'min
                            (mapcar (lambda (other) (nth 1 other))
                                    blocking)))))
        (setq y (if down
                    (+ edge gap)
                  (- edge gap height)))
        (cl-incf guard)))
    (and (>= y top)
         (<= (+ y height) bottom)
         y)))

(defun etaf-posframe--stacking-poshandler (at)
  "Return a poshandler placing the panel at AT, clear of live panels.
A panel stacks against the live panels however tall each of them turned out:
from a top or centre anchor it sits directly below the lowest panel it meets,
from a bottom one directly above the highest, and a column to the left takes it
when the frame has no room left, never outside the frame."
  (let* ((base (etaf-posframe--poshandler at))
         (place (cadr (split-string (symbol-name at) "-")))
         (down (not (and place (string-prefix-p "bottom" place)))))
    (lambda (info)
      (let* ((position (funcall base info))
             (x0 (car position))
             (y0 (cdr position))
             (bevel (etaf-posframe--terminal-bevel (plist-get info :posframe)))
             (width (+ (or (plist-get info :posframe-width) 0) bevel))
             (height (+ (or (plist-get info :posframe-height) 0) bevel))
             (frame-rect (etaf-posframe--rect info 'frame))
             (left (nth 0 frame-rect))
             (top (nth 1 frame-rect))
             (bottom (nth 3 frame-rect))
             (others (delq nil (mapcar (lambda (panel)
                                         (etaf-posframe--frame-rect
                                          (etaf-posframe--panel-frame panel)))
                                       (etaf-posframe-panels)))))
        (or (cl-loop for column from 0 below 60
                     for x = (- x0 (* column (+ width (etaf-posframe--stack-gap info))))
                     while (>= x left)
                     for y = (etaf-posframe--stack-clear-y
                              x y0 width height top bottom down others info)
                     when y return (cons x y))
            (cons x0 y0))))))

(defun etaf-posframe--cell-poshandler (cell)
  "Return a poshandler that puts the panel at CELL, a (ROW . COLUMN) pair.
Rows and columns count from the top left of the parent window's text area and
start at zero, so (0 . 0) is its first cell."
  (lambda (info)
    (let* ((rect (etaf-posframe--rect info 'window))
           (row (car cell))
           (column (cdr cell))
           (char-width (or (plist-get info :font-width)
                           (frame-char-width (or (plist-get info :parent-frame)
                                                 (selected-frame)))))
           (line-prefix (if (plist-get info :respect-header-line)
                            (plist-get info :header-line-height)
                          0))
           (char-height (or (plist-get info :font-height) 0)))
      (cons (+ (nth 0 rect) (* column char-width))
            (+ (nth 1 rect) (* row char-height) (or line-prefix 0))))))

(defun etaf-posframe--offset-poshandler (base offset)
  "Return a poshandler shifting BASE by OFFSET, a (ROWS . COLUMNS) cell pair."
  (lambda (info)
    (let* ((position (funcall base info))
           (cells (if (functionp offset) (funcall offset) offset))
           (char-width (or (plist-get info :font-width)
                           (frame-char-width (or (plist-get info :parent-frame)
                                                 (selected-frame)))))
           (char-height (or (plist-get info :font-height) 0)))
      (cons (+ (car position) (* (or (cdr cells) 0) char-width))
            (+ (cdr position) (* (or (car cells) 0) char-height))))))

(defun etaf-posframe--poshandler (at)
  "Return the posframe poshandler for anchor AT."
  (pcase at
    ('point #'posframe-poshandler-point-bottom-left-corner-upward)
    ('point-top #'posframe-poshandler-point-top-left-corner)
    ((pred functionp) at)
    (_ (or (cdr (assq at etaf-posframe--anchor-handlers))
           (signal 'etaf-posframe-error (list "Unsupported panel :at" at))))))

(defun etaf-posframe--draggable-p (options)
  "Return non-nil when OPTIONS make the panel draggable."
  (and (plist-get options :title)
       (plist-get options :draggable)))

;;; Dismissal

(defun etaf-posframe--auto-panel-p (panel)
  "Return non-nil when PANEL hides before the next outside command."
  (eq (plist-get (etaf-posframe--panel-options panel) :auto-hide) t))

(defun etaf-posframe--pre-command ()
  "Hide auto panels before a command that runs outside them."
  (unless etaf-posframe--dismissing
    (let ((etaf-posframe--dismissing t))
      (dolist (panel (copy-sequence etaf-posframe--panels))
        (when (and (etaf-posframe--auto-panel-p panel)
                   (not (eq (current-buffer)
                            (etaf-posframe--panel-buffer panel))))
          (etaf-posframe-hide panel))))))

(defun etaf-posframe--focus-change ()
  "Track which panel holds the focus and repaint after a focus change."
  (unless etaf-posframe--dismissing
    (let ((selected (selected-frame)))
      (dolist (panel (copy-sequence etaf-posframe--panels))
        (when (eq selected (etaf-posframe--panel-frame panel))
          (setf (etaf-posframe--panel-focused panel) t)))
      (etaf-posframe--refresh-hover)
      (etaf-posframe--paint-borders)
      (etaf-posframe--sync-activation))))

(defun etaf-posframe--refresh-hooks ()
  "Install the dismiss hooks exactly while a panel needs them."
  (if (cl-some #'etaf-posframe--auto-panel-p etaf-posframe--panels)
      (add-hook 'pre-command-hook #'etaf-posframe--pre-command)
    (remove-hook 'pre-command-hook #'etaf-posframe--pre-command))
  (if etaf-posframe--panels
      (add-hook 'post-command-hook #'etaf-posframe--follow-focus)
    (remove-hook 'post-command-hook #'etaf-posframe--follow-focus))
  (if etaf-posframe--panels
      (add-function :after after-focus-change-function
                    #'etaf-posframe--focus-change)
    (remove-function after-focus-change-function
                     #'etaf-posframe--focus-change))
  (etaf-posframe--watch-hover))

;;; Rendering

(defun etaf-posframe--lines (buffer)
  "Return the number of rendered lines in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (not (eobp))
          (forward-line 1)
          (cl-incf count))
        count))))

(defconst etaf-posframe--theme-modes
  '((light . "亮") (auto . "随") (dark . "暗"))
  "Segments of the title-bar theme toggle, in display order.
The selected one is the panel's current `:theme'.")

(defun etaf-posframe--header-format (header theme width &optional modes mode)
  "Return HEADER as a full-width title bar for THEME and WIDTH columns.
MODES, an alist of (MODE . LABEL), adds the theme toggle at the right with
MODE selected; a panel without a switch passes nil and keeps a plain title
bar.  A content may hold a mode its switch does not offer, as the reader's
sepia paper is, and the strip then shows its choices with none selected.

The bar keeps the panel surface and adds a single hairline below it: a band
lifted toward the foreground reads as a second surface in a light theme, and
the theme's `header-line' box would draw a coloured outline around it."
  (when header
    (let* ((text (concat " " header))
           (surface (etaf-posframe--mix (plist-get theme :ui-panel-bg)
                                        (plist-get theme :ui-panel-fg) 0.03))
           (strip (and modes
                       (etaf-toggle-strip
                        :options modes
                        :value (and (assq mode modes) mode)
                        :theme theme
                        :surface surface
                        :on-change #'etaf-posframe--choose-theme-mode)))
           (padding (max 0 (- width (string-width text)
                              (if strip (string-width strip) 0))))
           (plain (propertize (concat text (make-string padding ?\s))
                              'face (list :background surface
                                          :foreground (plist-get theme :ui-panel-fg)
                                          :weight 'bold
                                          :height 1.0
                                          ;; A theme may render its own header
                                          ;; line inverted and boxed; the title
                                          ;; bar keeps the panel's palette,
                                          ;; paints every column and owns its
                                          ;; own separator.
                                          :inverse-video nil
                                          :box nil
                                          :extend t)
                              'underline (list :color (plist-get theme :ui-panel-border)
                                               :style 'line))))
      ;; The strip keeps its own faces: `propertize' over the whole bar would
      ;; replace the segment faces with the title bar's.
      (concat plain (or strip "")))))

(defun etaf-posframe--prepare-buffer (buffer header theme width &optional mode)
  "Set BUFFER up as a panel surface with HEADER and THEME.
MODE adds the title-bar theme toggle over `etaf-posframe--theme-modes', as in
`etaf-posframe--header-format'."
  (let ((theme theme))
    (with-current-buffer buffer
      (erase-buffer)
      (setq-local truncate-lines t)
      (setq-local buffer-display-table
                  (copy-sequence (or buffer-display-table
                                     standard-display-table
                                     (make-display-table))))
      (set-display-table-slot buffer-display-table 'truncation ?\s)
      (setq-local header-line-format
                  (etaf-posframe--header-format
                   header theme width
                   (and (assq mode etaf-posframe--theme-modes)
                        etaf-posframe--theme-modes)
                   mode))
      (setq-local mode-line-format nil)
      (setq-local cursor-type nil)
      (setq-local vertical-scroll-bar nil)
      (setq-local horizontal-scroll-bar nil)
      ;; Mouse tracking in the buffer would make Emacs select the frame under
      ;; the pointer whenever it moves, so leaving a panel would take the
      ;; keyboard with it.  A panel keeps Emacs' focus rules: only a click moves
      ;; the keyboard.  The hover border reads the pointer from a timer instead.
      (setq-local track-mouse nil))))

(defun etaf-posframe--clamp-terminal-poshandler (handler)
  "Return HANDLER with its result kept inside a terminal frame.
A terminal border takes a cell outside the frame size, so a poshandler that
puts the frame origin at a screen edge (`point' at the first column, for
example) would lose its left or top border."
  (lambda (info)
    (let ((position (funcall handler info))
          (bevel (etaf-posframe--terminal-bevel (plist-get info :posframe))))
      (if (zerop bevel)
          position
        (let ((width (+ (or (plist-get info :posframe-width) 0) bevel))
              (height (+ (or (plist-get info :posframe-height) 0) bevel))
              (parent-width (or (plist-get info :parent-frame-width) 0))
              (parent-height (or (plist-get info :parent-frame-height) 0)))
          (cons (max 1 (min (car position)
                            (max 1 (- parent-width width 1))))
                (max 1 (min (cdr position)
                            (max 1 (- parent-height height 1))))))))))

(defun etaf-posframe--placement-poshandler (placement options)
  "Return the poshandler for PLACEMENT with OPTIONS."
  (etaf-posframe--clamp-terminal-poshandler
   (let ((stack (plist-get options :stack)))
     (pcase (car placement)
       ('cells (etaf-posframe--cell-poshandler (cdr placement)))
       ('pixels (lambda (_info) (cdr placement)))
       ('function (cdr placement))
       ('anchor
        (if stack
            (etaf-posframe--stacking-poshandler (cdr placement))
          (etaf-posframe--poshandler (cdr placement))))
       ('anchor+offset
        (let* ((anchor (nth 1 placement))
               (offset (cons (nth 2 placement) (nth 3 placement)))
               (base (if stack
                         (etaf-posframe--stacking-poshandler anchor)
                       (etaf-posframe--poshandler anchor))))
          (etaf-posframe--offset-poshandler base offset)))))))

(defun etaf-posframe--frame-args (panel lines)
  "Return the `posframe-show' arguments for PANEL showing LINES of content."
  (let* ((options (etaf-posframe--panel-options panel))
         (title (plist-get options :title))
         (border (plist-get options :border))
         (theme (etaf-value (etaf-posframe--panel-theme panel))))
    (append
     (list :width (plist-get options :width)
           :height (+ lines (if title 1 0))
           :min-height (+ 1 (if title 1 0))
           :left-fringe 0
           :right-fringe 0
           ;; A frame mid-drag is narrower than the canvas it still shows.
           ;; Posframe writes `truncate-lines' from this key, so without it
           ;; the old rows wrap and the board scrambles until the fit runs.
           :lines-truncate t
           :border-width (if (display-graphic-p)
                             (or (plist-get border :width)
                                 etaf-posframe-border-width)
                           ;; A terminal draws a frame border one cell wide, so a
                           ;; wider request keeps the border instead of the
                           ;; exact width.
                           (if (> (or (plist-get border :width)
                                      etaf-posframe-border-width)
                                  0)
                               1
                             0))
           :border-color (or (plist-get border :color)
                             (plist-get theme :ui-panel-border))
           :internal-border-width 0
           :respect-header-line (and title t)
           :accept-focus (and (plist-get options :focusable) t)
           ;; The frame paint matches the canvas surface so a sub-cell
           ;; remainder at the edge cannot show a second colour.
           :background-color (or (plist-get theme :ui-panel-bg) "#FFFFFF")
           :foreground-color (or (plist-get theme :ui-fg) "#000000")
           :override-parameters
           (append
            '((horizontal-scroll-bars . nil)
              (vertical-scroll-bars . nil)
              (top-visible . 24)
              (snap-width . 12))
            (when (etaf-posframe--draggable-p options)
              '((drag-with-header-line . t)))))
     (list :poshandler
           (etaf-posframe--placement-poshandler
            (etaf-posframe--placement (plist-get options :at))
            options)))))

(defun etaf-posframe--fit (panel)
  "Fit PANEL's Runtime to WINDOW's frame width and its body height.
Follow the frame width, not the window's, because a transient scroll bar
would otherwise narrow the canvas and leave a scroll bar strip on the right."
  (let ((runtime (etaf-posframe--panel-runtime panel))
        (width (plist-get (etaf-posframe--panel-options panel) :pixel-width)))
    (etaf-runtime-refit runtime width nil)))

(defun etaf-posframe--text-height (panel window)
  "Return the pixel height of PANEL's rendered content in WINDOW.
A terminal cell is one pixel, and `window-text-pixel-size' counts the header
line there as one of the rows it measures.  Counting the buffer's text rows
keeps the frame at header plus content instead of adding a blank row."
  (condition-case nil
      (with-current-buffer (etaf-posframe--panel-buffer panel)
        (save-excursion
          (goto-char (point-max))
          (skip-chars-backward " \t\n")
          (if (display-graphic-p)
              (cdr (window-text-pixel-size window nil (point) nil 10000 t))
            (* (count-lines (point-min) (point))
               (frame-char-height (window-frame window))))))
    (error nil)))

(defun etaf-posframe--row-budget (panel)
  "Return PANEL's content row budget, the `:height' it opened with."
  (let ((options (etaf-posframe--panel-options panel)))
    (or (plist-get options :height) etaf-posframe-default-max-height)))

(defun etaf-posframe--resize-to-content (panel window)
  "Fit PANEL's frame height to WINDOW's rendered rows.
The rendered content decides the height, but never beyond the rows the panel
was opened for: a View that fills its viewport, such as a complete app, would
otherwise stretch the frame to the measuring budget.  The clamp also keeps a
transient measurement from stretching the frame into an empty rectangle.
Return non-nil when the frame size changed; sizing a frame to the size it
already has is what turns one resize into a stream of size-change hooks."
  (let* ((frame (window-frame window))
         (options (etaf-posframe--panel-options panel))
         (width (plist-get options :pixel-width))
         (line (frame-char-height frame))
         (header (if (plist-get options :title)
                     (window-header-line-height window)
                   0))
         (limit (+ (* (etaf-posframe--row-budget panel) line) header))
         (content (+ (or (etaf-posframe--text-height panel window) 0) header))
         ;; `:fill-height' keeps the frame at the row budget, so an application
         ;; with a fixed-size board gets a full stage and the surface fills the
         ;; rest.
         (height (if (plist-get options :fill-height)
                     limit
                   (min content limit))))
    (when (and width (> height 0)
               (or (/= width (frame-pixel-width frame))
                   (/= height (frame-pixel-height frame))))
      (set-frame-size frame width height t)
      t)))

(defun etaf-posframe--fit-height (panel window)
  "Lay PANEL out in its row budget, then fit the frame to the content."
  (let* ((options (etaf-posframe--panel-options panel))
         (width (plist-get options :pixel-width))
         (runtime (etaf-posframe--panel-runtime panel)))
    ;; The measuring layout uses the row budget rather than an open-ended
    ;; height: a View that paints a full viewport would report that budget as
    ;; its content, and its `:height' rows are what the panel promises.
    (etaf-runtime-refit runtime width (etaf-posframe--row-budget panel))
    (etaf-posframe--resize-to-content panel window)
    (etaf-runtime-refit runtime width nil)
    (etaf-posframe--fit panel)))

(defun etaf-posframe--show-frame (panel lines)
  "Show PANEL's frame for LINES of content and return its frame.
Re-fit once when the settled window width changes the content height."
  (let* ((budget (etaf-posframe--row-budget panel))
         ;; A filled panel is created at its full height, so the poshandler
         ;; places the stage it will keep instead of the one-row frame a short
         ;; View produces before the fit.
         (lines (max 1 (if (plist-get (etaf-posframe--panel-options panel)
                                     :fill-height)
                           budget
                         (min lines budget))))
         (args (etaf-posframe--frame-args panel lines))
         (buffer (etaf-posframe--panel-buffer panel)))
    (apply #'posframe-show buffer args)
    (dotimes (_ 2)
      (let ((window (get-buffer-window buffer t)))
        (when (window-live-p window)
          (set-window-scroll-bars window 0 nil nil)
          (etaf-posframe--fit panel)
          (let ((settled (min budget (etaf-posframe--lines buffer))))
            (unless (= settled lines)
              (setq lines settled)
              (apply #'posframe-show buffer
                     (plist-put (copy-sequence args) :height
                                (+ settled (if (plist-get
                                               (etaf-posframe--panel-options panel)
                                               :title)
                                               1 0)))))))))
    (let ((window (get-buffer-window buffer t)))
      (unless (window-live-p window)
        (signal 'etaf-posframe-error (list "Panel frame did not appear" buffer)))
      (set-window-scroll-bars window 0 nil nil)
      (etaf-posframe--fit-height panel window)
      ;; The poshandler ran while the fresh frame still had its one-row size,
      ;; so a vertical anchor would be off by the difference.  Show once more
      ;; with the settled height: posframe then places the frame it will keep.
      (let ((settled (+ (window-body-height window)
                        (if (plist-get (etaf-posframe--panel-options panel) :title)
                            1
                          0))))
        (unless (= settled lines)
          (apply #'posframe-show buffer
                 (plist-put (copy-sequence args) :height settled))
          (etaf-posframe--fit-height panel window)))
      (etaf-posframe--remember-size panel window)
      (window-frame window))))

(defun etaf-posframe--border-color (panel focused hovered)
  "Return PANEL's border colour for the FOCUSED or HOVERED state.
Focus and hover are the accent mixed into the surface, so the theme's own
hue still shows without a saturated one-pixel outline; hover is the weaker
hint and focus is the stronger one."
  (let* ((theme-ref (etaf-posframe--panel-theme panel))
         (palette (and (etaf-ref-p theme-ref) (etaf-value theme-ref)))
         (options (etaf-posframe--panel-options panel))
         (border (plist-get options :border))
         (surface (or (plist-get palette :ui-panel-bg)
                      (plist-get palette :ui-panel-border)))
         (resting (or (plist-get border :color)
                      (plist-get palette :ui-panel-border)))
         (accent (or (plist-get border :focus)
                     (plist-get palette :ui-accent))))
    (cond ((and focused (plist-get border :focus)) (plist-get border :focus))
          (focused (and accent (etaf-posframe--mix surface accent
                                                   etaf-posframe-border-focus-strength)))
          ;; A hovered panel does not hold the keyboard, so it takes a weak
          ;; accent hint; the border commits to the accent when the click lands.
          (hovered (or (plist-get border :hover)
                       (and accent (etaf-posframe--mix surface accent
                                                      etaf-posframe-border-hover-strength))))
          (t resting))))

(defun etaf-posframe--paint-border (panel)
  "Colour PANEL's border by whether it holds the focus or the pointer."
  (let ((frame (etaf-posframe--panel-frame panel)))
    (when (frame-live-p frame)
      (let* ((face (if (facep 'child-frame-border)
                       'child-frame-border
                     'internal-border))
             (color (etaf-posframe--border-color
                     panel (eq (selected-frame) frame)
                     (eq panel etaf-posframe--hover-panel))))
        (when (and color (not (equal color (face-attribute face :background frame))))
          (set-face-background face color frame))))))

(defvar etaf-posframe--painted-focus nil
  "Frame the panel borders were last painted for.")


(defun etaf-posframe--paint-borders ()
  "Refresh the focus border of every live panel."
  (setq etaf-posframe--painted-focus (selected-frame))
  (dolist (panel etaf-posframe--panels)
    (ignore-errors (etaf-posframe--paint-border panel))))

(defun etaf-posframe--pointer-panel ()
  "Return the panel under the mouse pointer, or nil.
`mouse-pixel-position' asks the window system which frame has the pointer,
child frames included, so this is the hover question itself.  The current
buffer cannot answer it: a motion command inside a panel runs while another
frame still holds the keyboard."
  (let* ((position (and (display-graphic-p) (mouse-pixel-position)))
         (frame (car-safe position)))
    (when (and (frame-live-p frame) (numberp (nth 1 position)))
      (cl-find-if (lambda (panel)
                    (and (plist-get (etaf-posframe--panel-options panel)
                                    :focusable)
                         (eq (etaf-posframe--panel-frame panel) frame)))
                  etaf-posframe--panels))))

(defun etaf-posframe--refresh-hover ()
  "Point the hover hint at the panel under the pointer.
Return that panel, and paint only when the hint moved."
  (let ((panel (etaf-posframe--pointer-panel)))
    (unless (eq panel etaf-posframe--hover-panel)
      (setq etaf-posframe--hover-panel panel)
      (etaf-posframe--paint-borders))
    panel))

(defun etaf-posframe--watch-hover ()
  "Keep one pointer timer exactly while a panel frame is on screen.
Entering a panel runs a motion command, which paints the hint at once; leaving
one runs no command in the buffer the pointer lands in, so a reading clears the
hint instead.  A reading is one position query, not a poll of an application."
  (if (cl-some (lambda (panel)
                 (frame-live-p (etaf-posframe--panel-frame panel)))
               etaf-posframe--panels)
      (unless (timerp etaf-posframe--hover-timer)
        (setq etaf-posframe--hover-timer
              (run-with-timer etaf-posframe--hover-interval
                              etaf-posframe--hover-interval
                              #'etaf-posframe--refresh-hover)))
    (when (timerp etaf-posframe--hover-timer)
      (cancel-timer etaf-posframe--hover-timer)
      (setq etaf-posframe--hover-timer nil)
      (setq etaf-posframe--hover-panel nil))))

(defun etaf-posframe--focus-pointer-panel ()
  "Give the keyboard to the panel the pointer rests on.
Only a panel that accepts the keyboard enters the hover state."
  (when-let* ((panel etaf-posframe--hover-panel)
              (frame (etaf-posframe--panel-frame panel)))
    (unless (eq (selected-frame) frame)
      (etaf-posframe--restore-input-focus frame)
      (setf (etaf-posframe--panel-focused panel) t))))

(defun etaf-posframe--sync-activation ()
  "Show or hide the panel frames with Emacs' activation.
Hiding is what keeps the child frames out of the window manager's window list
while another application is in front."
  (when (and etaf-posframe-hide-inactive (display-graphic-p))
    (let ((active (cl-some #'frame-focus-state (frame-list))))
      (dolist (panel etaf-posframe--panels)
        (let ((frame (etaf-posframe--panel-frame panel)))
          (when (frame-live-p frame)
            (if active
                (unless (frame-parameter frame 'visibility)
                  (make-frame-visible frame))
              (when (frame-parameter frame 'visibility)
                (make-frame-invisible frame)))))))))

(defun etaf-posframe--raise-clicked-panel ()
  "Bring the panel a mouse button was pressed in to the front.
Emacs selects the clicked child frame but leaves the stacking order alone, so a
panel behind another stayed covered even while it held the keyboard.  Clicking
any part of a window is expected to raise it, so the click itself does that;
the keyboard only moves when the panel accepts it."
  (ignore-errors
    (let* ((event last-command-event)
           (position (and (consp event)
                          (memq (event-basic-type event)
                                '(mouse-1 mouse-2 mouse-3))
                          (event-start event)))
           (window (and position (posn-window position)))
           (frame (cond ((window-live-p window) (window-frame window))
                        ((frame-live-p window) window)))
           (panel (and frame (etaf-posframe--panel-for-frame frame))))
      (when panel
        (raise-frame frame)
        (when (and (window-live-p window)
                   (plist-get (etaf-posframe--panel-options panel) :focusable)
                   (not (eq (selected-frame) frame)))
          (select-window window)
          (setf (etaf-posframe--panel-focused panel) t))))))

(defun etaf-posframe--follow-focus ()
  "Follow the pointer and the selection for the panel borders.
The panel under the pointer gets the hover border without taking the keyboard;
the keyboard moves only on a click, or on hover when
`etaf-posframe-focus-follows-mouse' asks for it."
  (etaf-posframe--refresh-hover)
  (etaf-posframe--raise-clicked-panel)
  (when etaf-posframe-focus-follows-mouse
    (etaf-posframe--focus-pointer-panel))
  (etaf-posframe--sync-activation)
  (etaf-posframe--paint-borders))

(defun etaf-posframe--top-frame (&optional frame)
  "Return the top level frame above FRAME.
A panel is never derived from another panel's frame: a child frame, possibly a
stale one, would give it that frame's face metrics and colours."
  (let ((frame (or frame (selected-frame))))
    (while (and (frame-live-p frame) (frame-parent frame))
      (setq frame (frame-parent frame)))
    (if (frame-live-p frame)
        frame
      (or (cl-find-if (lambda (candidate) (null (frame-parent candidate)))
                      (frame-list))
          (selected-frame)))))

(defun etaf-posframe--restore-input-focus (frame)
  "Select FRAME and give it the window system's input focus.
`select-frame' alone leaves the system without a key window after a focused
child frame is deleted, which then swallows the next command."
  (when (frame-live-p frame)
    (select-frame-set-input-focus frame)))

(defun etaf-posframe--teardown (panel)
  "Release PANEL's frame, Runtime and timer without callbacks."
  (let ((buffer (etaf-posframe--panel-buffer panel))
        (frame (etaf-posframe--panel-frame panel))
        (parent (etaf-posframe--panel-parent panel))
        (restore (etaf-posframe--panel-restore-frame panel)))
    (when (buffer-live-p parent)
      (with-current-buffer parent
        (unless (etaf-posframe--panel-for-buffer parent)
          (remove-hook 'kill-buffer-hook #'etaf-posframe--parent-killed t))
        (when (eq etaf-posframe--parent-panel panel)
          (setq etaf-posframe--parent-panel nil))))
    ;; Deleting a child frame that held the window system's focus leaves macOS
    ;; without a key window: `select-frame' only moves Emacs's own selection, so
    ;; the next command has nowhere to go and the session appears frozen.  Hand
    ;; input focus back to the frame the panel was opened from.
    (when (frame-live-p restore)
      (cond
       ((eq (selected-frame) frame)
        (etaf-posframe--restore-input-focus restore))
       ((not (frame-focus-state frame))
        (when (frame-parent frame)
          (etaf-posframe--restore-input-focus restore)))))
    (when-let* ((timer (etaf-posframe--panel-timer panel)))
      (cancel-timer timer)
      (setf (etaf-posframe--panel-timer panel) nil))
    (when-let* ((timer (etaf-posframe--panel-fit-timer panel)))
      (cancel-timer timer)
      (setf (etaf-posframe--panel-fit-timer panel) nil))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when etaf-posframe--surface-scope
          (ignore-errors (etaf-scope-stop etaf-posframe--surface-scope))
          (setq etaf-posframe--surface-scope nil))))
    (when (buffer-live-p buffer)
      (ignore-errors (posframe-hide buffer)))
    (when (buffer-live-p buffer)
      (ignore-errors (posframe-delete-frame buffer)))
    (when (buffer-live-p buffer)
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (ignore-errors (etaf-unmount runtime)))
      (ignore-errors (kill-buffer buffer)))
    (ignore frame)))

;;;###autoload
(defun etaf-posframe--focus (panel)
  "Select PANEL's frame and window, remembering the frame to restore."
  (let ((frame (etaf-posframe--panel-frame panel)))
    (when (frame-live-p frame)
      (setf (etaf-posframe--panel-restore-frame panel) (selected-frame))
      (select-frame frame)
      (when (frame-parameter frame 'window-id)
        (ignore-errors (x-focus-frame frame)))
      (when-let* ((window (get-buffer-window (etaf-posframe--panel-buffer panel) t)))
        (select-window window)
        (set-window-point window (point-min))
        (setf (etaf-posframe--panel-focused panel) t)))
    (etaf-posframe--paint-borders)))

(defun etaf-posframe-hide (&optional panel)
  "Hide PANEL and release its Runtime, timer and frame.
PANEL defaults to the panel of the current buffer.  Return non-nil when a live
panel was hidden."
  (interactive)
  (when-let* ((panel (or panel (etaf-posframe--current-panel))))
    (setq etaf-posframe--panels (delq panel etaf-posframe--panels))
    (when (eq panel etaf-posframe--hover-panel)
      (setq etaf-posframe--hover-panel nil))
    (etaf-posframe--teardown panel)
    (etaf-posframe--refresh-hooks)
    (etaf-posframe--paint-borders)
    (when-let* ((callback (etaf-posframe--panel-close-callback panel)))
      (condition-case error
          (funcall callback panel)
        (error (message "ETAF panel close callback failed: %s"
                        (error-message-string error)))))
    t))

(defun etaf-posframe--set-frame-palette (frame palette)
  "Paint FRAME as PANEL's surface from PALETTE.
A theme switch resets a child frame's default face, so the surface colours and
that face are set together; setting only the frame parameters leaves text
without an explicit background on the old theme's colour.  The surface, not
the page, is the frame paint: a sub-cell remainder at the edge must not show a
second colour."
  (set-face-attribute 'default frame
                      :background (plist-get palette :ui-panel-bg)
                      :foreground (plist-get palette :ui-panel-fg))
  (set-frame-parameter frame 'background-color (plist-get palette :ui-panel-bg))
  (set-frame-parameter frame 'foreground-color (plist-get palette :ui-fg)))

(defun etaf-posframe--hold-theme (panel)
  "Keep PANEL on the palette it already paints.
`load-theme' changes the default face of every frame before it reports the
switch, and disabling every theme resets a child frame to white.  Holding the
palette keeps either intermediate state off the screen; the coalesced pass
then re-derives once."
  (let* ((theme (etaf-posframe--panel-theme panel))
         (palette (and (etaf-ref-p theme) (etaf-value theme)))
         (frame (etaf-posframe--panel-frame panel)))
    (when (and palette (frame-live-p frame))
      (etaf-posframe--set-frame-palette frame palette)
      (ignore-errors (etaf-posframe--paint-border panel)))))

(defun etaf-posframe--panel-adopted-p (panel)
  "Return non-nil when PANEL's content declared the surface it paints.
The slot itself always exists; only a content that declared its Theme owns
the palette, and only then does the panel paint that palette."
  (let ((surface (etaf-posframe--panel-surface panel)))
    (and surface (etaf-surface-theme surface) t)))

(defun etaf-posframe--panel-modes (panel)
  "Return (MODES MODE) PANEL's title bar offers, or nil when it has no switch.
An application that declared its surface brings its own modes and its own
mode cell; otherwise the panel offers its own `:theme' mode."
  (let* ((surface (etaf-posframe--panel-surface panel))
         (modes (and surface (etaf-surface-modes surface)))
         (mode-ref (and surface (etaf-surface-mode surface))))
    (if (and modes mode-ref)
        (list modes (etaf-value mode-ref))
      (let ((option (plist-get (etaf-posframe--panel-options panel) :theme)))
        (when (memq option '(light auto dark))
          (list etaf-posframe--theme-modes option))))))

(defun etaf-posframe--refresh-header (panel palette &optional width)
  "Rebuild PANEL's title bar for PALETTE and the mode it currently shows.
WIDTH, when given, is the new content width of a panel being resized."
  (let ((buffer (etaf-posframe--panel-buffer panel))
        (options (etaf-posframe--panel-options panel))
        (offered (etaf-posframe--panel-modes panel)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local header-line-format
                    (etaf-posframe--header-format
                     (plist-get options :title) palette
                     (or width (plist-get options :width))
                     (nth 0 offered) (nth 1 offered)))))))

(defun etaf-posframe--update-appearance (panel)
  "Point PANEL's appearance ref at the appearance its content should see.
An application that declared its surface follows the parent frame, because
the panel frame itself now paints that application's palette; every other
panel passes the polarity of its own palette."
  (let ((appearance (etaf-posframe--panel-appearance panel))
        (theme (etaf-posframe--panel-theme panel))
        (parent (etaf-posframe--panel-parent-frame panel)))
    (when (etaf-ref-p appearance)
      (let ((value
             (if (etaf-posframe--panel-adopted-p panel)
                 (let ((bg (and (frame-live-p parent)
                                (etaf-posframe--color
                                 (face-attribute 'default :background parent)))))
                   (if (and bg (etaf-posframe--dark-color-p bg)) 'dark 'light))
               (plist-get (and (etaf-ref-p theme) (etaf-value theme)) :ui-mode))))
        (when (and value (not (eq value (etaf-value appearance))))
          (etaf-batch (setf (etaf-value appearance) value)))))))

(defun etaf-posframe--apply-pinned-mode (panel surface)
  "Start SURFACE's content in PANEL's pinned mode, once.
The caller asked for that mode with `:theme' when it showed the panel, so a
content that owns its palette starts in it instead of in whatever its own
default is.  The mode cell then belongs to the content: the title-bar switch
writes it, and this function never overrides the choice again."
  (when (and surface (not (etaf-posframe--panel-pin-applied panel)))
    (let* ((options (etaf-posframe--panel-options panel))
           (pinned (plist-get options :theme))
           (modes (etaf-surface-modes surface))
           (mode-ref (etaf-surface-mode surface)))
      (when (and mode-ref (memq pinned '(light dark)) (assq pinned modes))
        (setf (etaf-posframe--panel-pin-applied panel) t)
        (unless (eq (etaf-value mode-ref) pinned)
          (etaf-set-value mode-ref pinned))))))

(defun etaf-posframe--sync-surface (panel)
  "Repaint PANEL's chrome from the surface its content declared.
A panel whose content owns its palette paints its frame, title bar and border
from that palette and offers that content's modes, so the switch in the title
bar and the application's own switch remain one state."
  (let ((theme-ref (etaf-posframe--panel-theme panel))
        (surface (etaf-posframe--panel-surface panel))
        (source (let ((surface (etaf-posframe--panel-surface panel)))
                  (and surface (etaf-surface-theme surface)))))
    (etaf-posframe--apply-pinned-mode panel surface)
    (when (and (etaf-ref-p theme-ref) source)
      (let ((palette (etaf-value source))
            (frame (etaf-posframe--panel-frame panel)))
        (unless (equal palette (etaf-value theme-ref))
          (etaf-batch (setf (etaf-value theme-ref) palette)))
        (when (frame-live-p frame)
          (ignore-errors (etaf-posframe--set-frame-palette frame palette))
          (ignore-errors (etaf-posframe--paint-border panel)))
        (etaf-posframe--update-appearance panel)
        (etaf-posframe--refresh-header panel (etaf-value theme-ref))))))

(defun etaf-posframe--watch-surface (panel)
  "Repaint PANEL's chrome whenever its content's surface changes.
The watcher lives in its own scope, held beside the panel buffer, so it is
released with the panel and never runs while the View renders."
  (let* ((buffer (etaf-posframe--panel-buffer panel))
         (surface (etaf-posframe--panel-surface panel)))
    (when (and surface (buffer-live-p buffer))
      (with-current-buffer buffer
        (let ((scope (etaf-effect-scope :detached t
                                        :name 'etaf-posframe-surface)))
          (setq etaf-posframe--surface-scope scope)
          (etaf-scope-run
           scope
           (lambda ()
             (etaf-watch
              (lambda ()
                (let ((theme (etaf-surface-theme surface))
                      (mode (etaf-surface-mode surface)))
                  (list (and theme (etaf-value theme))
                        (and mode (etaf-value mode)))))
              (lambda (_new _old)
                (when (buffer-live-p buffer)
                  (when-let* ((live (buffer-local-value 'etaf-posframe--panel
                                                        buffer)))
                    (etaf-posframe--sync-surface live))))
              :test #'equal
              :name 'etaf-posframe-surface))))))))

(defun etaf-posframe--apply-theme-to (panel)
  "Derive PANEL's Theme from its parent frame and repaint its title bar.
A pass that leaves the palette unchanged only re-asserts the frame colours,
because repainting the View is the expensive part of a theme change.  A panel
whose content declared its surface owns the palette already; the pass only
updates the appearance that content may follow."
  (if (etaf-posframe--panel-adopted-p panel)
      (ignore-errors (etaf-posframe--update-appearance panel))
    (let ((theme (etaf-posframe--panel-theme panel))
          (parent-frame (etaf-posframe--panel-parent-frame panel))
          (options (etaf-posframe--panel-options panel)))
      (when (and (etaf-ref-p theme) (frame-live-p parent-frame)
                 (memq (plist-get options :theme) '(auto light dark)))
        (ignore-errors
          (let* ((mode (plist-get options :theme))
                 (palette (etaf-posframe-theme
                           parent-frame
                           (and (not (eq mode 'auto)) mode)))
                 (frame (etaf-posframe--panel-frame panel)))
            (when (frame-live-p frame)
              (etaf-posframe--set-frame-palette frame palette))
            (unless (equal palette (etaf-value theme))
              (etaf-batch (setf (etaf-value theme) palette))
              (ignore-errors (etaf-posframe--paint-border panel))
              (ignore-errors (etaf-posframe--sync-activation)))
            (etaf-posframe--update-appearance panel)
            ;; The title bar repaints in both cases: the palette may be the same
            ;; while the toggle moved, as `auto' and `light' are in a light frame.
            (etaf-posframe--refresh-header panel palette)))))))

(defun etaf-posframe--apply-theme ()
  "Derive every live panel's Theme once from its parent frame."
  (dolist (panel (copy-sequence etaf-posframe--panels))
    (etaf-posframe--apply-theme-to panel)))

(defun etaf-posframe--choose-theme-mode (mode)
  "Switch the current panel to MODE.
A panel whose content declared its surface writes that content's mode cell, so
the application repaints and the title bar follows one state.  Every other
panel keeps the choice in its own `:theme' option for the rest of its life;
the caller's configuration is never written either way."
  (let ((panel (etaf-posframe--current-panel)))
    (when (etaf-posframe-live-p panel)
      (let* ((surface (etaf-posframe--panel-surface panel))
             (mode-ref (and surface (etaf-surface-mode surface))))
        (cond
         ((and mode-ref (assq mode (etaf-surface-modes surface)))
          (etaf-set-value mode-ref mode))
         ((memq mode '(light auto dark))
          (setf (etaf-posframe--panel-options panel)
                (plist-put (copy-sequence (etaf-posframe--panel-options panel))
                           :theme mode))
          (etaf-posframe--apply-theme-to panel)))))))

(defun etaf-posframe--theme-changed (&rest _)
  "Coalesce a theme switch into one pass after the current command.
`enable-theme-functions' and `disable-theme-functions' both report steps of
one switch, and disabling every theme in the middle resets each child frame to
white.  Holding the palette the panels already paint and re-deriving once
after the command keeps them from flashing a half-switched surface."
  (dolist (panel etaf-posframe--panels)
    (ignore-errors (etaf-posframe--hold-theme panel)))
  (when (timerp etaf-posframe--theme-timer)
    (cancel-timer etaf-posframe--theme-timer))
  (setq etaf-posframe--theme-timer
        (and etaf-posframe--panels
             (run-at-time 0 nil #'etaf-posframe--apply-theme))))

(add-hook 'enable-theme-functions #'etaf-posframe--theme-changed)
(add-hook 'disable-theme-functions #'etaf-posframe--theme-changed)
(add-hook 'window-size-change-functions #'etaf-posframe--window-size-changed)

(defun etaf-posframe--panel-for-key (key)
  "Return the live panel whose `:key' is KEY, or nil.
Panels without a `:key' share the nil identity, so showing one replaces the
previous one; panels with distinct keys coexist."
  (cl-find-if (lambda (panel)
                (equal key (plist-get (etaf-posframe--panel-options panel) :key)))
              etaf-posframe--panels))

(defun etaf-posframe--panel-for-buffer (buffer)
  "Return the live panel anchored to BUFFER."
  (cl-find-if (lambda (panel) (eq (etaf-posframe--panel-parent panel) buffer))
              etaf-posframe--panels))

(defun etaf-posframe--current-panel ()
  "Return the panel of the current buffer, panel buffer included."
  (or etaf-posframe--panel
      (etaf-posframe--panel-for-buffer (current-buffer))))

;;;###autoload
(defun etaf-posframe-show (view &rest options)
  "Show VIEW in a floating panel and return the panel.
VIEW is a View or a zero-argument function returning one.  OPTIONS is the plist
described in the package Commentary."
  (unless (or (functionp view) view)
    (signal 'etaf-posframe-error (list "Panel View is nil")))
  ;; A new panel belongs to the frame the user is working in.  When a panel has
  ;; focus, its child frame is selected, and parenting the new panel to it would
  ;; delete the new panel together with the covering one.  Keep the caller's
  ;; buffer as the anchor, not the buffer the outer window happens to show.
  (let* ((called-buffer (current-buffer))
         (anchor-frame (etaf-posframe--anchor-frame (selected-frame))))
    (when (and (frame-live-p anchor-frame)
               (not (eq anchor-frame (selected-frame))))
      (select-frame anchor-frame)
      (set-buffer called-buffer)))
  (let* ((options (etaf-posframe--defaults
                   (etaf-posframe--validate (copy-sequence options))))
         (parent-frame (etaf-posframe--top-frame))
         (parent-buffer (etaf-posframe--anchor-buffer (current-buffer)))
         (char-width (max 1 (frame-char-width parent-frame)))
         (char-height (max 1 (frame-char-height parent-frame)))
         (parent-width (frame-pixel-width parent-frame))
         (parent-height (frame-pixel-height parent-frame))
         (available (max 20 (- (/ parent-width char-width)
                               (* 2 etaf-posframe--margin))))
         (width-spec (plist-get options :width))
         (columns (max 1 (min (if (numberp width-spec)
                                  width-spec
                                (round (/ (* parent-width (nth 1 width-spec))
                                          char-width)))
                              available)))
         ;; A panel must fit its parent frame: the row budget is clamped to the
         ;; rows the frame can show, so a tall game panel cannot run off screen.
         (height-spec (plist-get options :height))
         (budget (if (numberp height-spec)
                     height-spec
                   (round (/ (* parent-height (nth 1 height-spec)) char-height))))
         ;; Two rows stay free for the panel's border and the parent's mode
         ;; line.  The margin is measured in cells, not in pixels: a TTY frame
         ;; reports one pixel per cell, so a pixel count would cap a panel on a
         ;; 40-row terminal at eight rows.
         (capacity (max 4 (floor (- parent-height (* 2 char-height))
                                 (float char-height))))
         (max-height (min budget capacity))
         (theme-spec (plist-get options :theme))
         (theme (if (memq theme-spec '(auto light dark))
                    (etaf-posframe-theme parent-frame
                                         (and (not (eq theme-spec 'auto))
                                              theme-spec))
                  theme-spec))
         (theme-ref (if (or (etaf-ref-p theme) (etaf-computed-p theme))
                        theme
                      (etaf-ref theme)))
         ;; The slot an application that owns its palette declares itself on,
         ;; and the appearance a panel gives the View it frames.  Both outlive
         ;; the mount, so the panel keeps one readable state on each side.
         (surface (etaf-surface-create))
         (appearance (etaf-ref (plist-get (etaf-value theme-ref) :ui-mode)))
         (resolved (if (functionp view) (funcall view) view))
         (options (plist-put (plist-put options :width columns) :height max-height))
         (options (plist-put options :pixel-width (* columns char-width)))
         (panel nil)
         buffer)
    (unless (etaf-posframe--display-supported-p)
      (signal 'etaf-posframe-error
              (list "ETAF panels need a graphical frame or a terminal with child frames")))
    ;; Only the same key replaces a panel: different keys keep their own
    ;; frame, Runtime and position, so several panels stay open at once.
    (when-let* ((previous (etaf-posframe--panel-for-key
                           (plist-get options :key))))
      (etaf-posframe-hide previous))
    (unless resolved
      (signal 'etaf-posframe-error (list "Panel View returned nil" view)))
    (setq buffer (generate-new-buffer
                  (format " *ETAF Panel %d*" (cl-incf etaf-posframe--counter))))
    (etaf-posframe--prepare-buffer buffer (plist-get options :title)
                                   (etaf-value theme-ref)
                                   (plist-get options :width)
                                   (and (memq (plist-get options :theme)
                                              '(light auto dark))
                                        (plist-get options :theme)))
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (lambda ()
                        (etaf-view
                         (etaf-posframe--surface :theme theme-ref
                                                 :appearance appearance
                                                 :surface surface
                                                 :content (lambda () resolved))))
                      (list :viewport-width (* columns char-width)
                            :viewport-height max-height))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (unless runtime
              (signal 'etaf-posframe-error
                      (list "Panel View did not mount" view)))
            ;; The Theme ref and the surface live beside the panel buffer: the
            ;; panel struct stays printable, and the frame arguments read the
            ;; same ref.
            (with-current-buffer buffer
              (setq etaf-posframe--theme-ref theme-ref
                    etaf-posframe--surface surface
                    etaf-posframe--appearance-ref appearance))
            (setq panel (etaf-posframe--make-panel
                         :buffer buffer
                         :options options
                         :parent parent-buffer
                         :parent-frame parent-frame))
            ;; An application that declared its surface paints the frame this
            ;; panel is about to show, so the first paint is already its own.
            (etaf-posframe--sync-surface panel)
            (setf (etaf-posframe--panel-frame panel)
                  (etaf-posframe--show-frame
                   panel (max 1 (etaf-posframe--lines buffer))))
            ;; From here on a frame resized from outside re-lays the View out
            ;; at its new width instead of being snapped back.
            (setf (etaf-posframe--panel-settled panel) t)
            (etaf-posframe--set-frame-palette
             (etaf-posframe--panel-frame panel) (etaf-value theme-ref))
            (ignore-errors (etaf-posframe--paint-border panel))
            (ignore-errors (etaf-posframe--sync-activation))
            (etaf-posframe--watch-surface panel)
            (with-current-buffer buffer
              (setq etaf-posframe--panel panel))
            (with-current-buffer parent-buffer
              (setq etaf-posframe--parent-panel panel)
              (add-hook 'kill-buffer-hook #'etaf-posframe--parent-killed nil t))
            (push panel etaf-posframe--panels)
            (when-let* ((seconds (plist-get options :auto-hide))
                        ((numberp seconds)))
              (setf (etaf-posframe--panel-timer panel)
                    (run-at-time seconds nil
                                 (lambda ()
                                   (when (memq panel etaf-posframe--panels)
                                     (etaf-posframe-hide panel))))))
            (when (plist-get options :focus-on-open)
              (etaf-posframe--focus panel))
            (etaf-posframe--refresh-hooks)
            panel))
      (unless panel
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (ignore-errors (etaf-unmount runtime)))
        (when (buffer-live-p buffer)
          (ignore-errors (posframe-hide buffer))
          (ignore-errors (posframe-delete-frame buffer))
          (kill-buffer buffer))))))

;;;###autoload
(defun etaf-posframe-toggle (view &rest options)
  "Hide the panel of the same `:key', or show VIEW with OPTIONS.
Without `:key' this is the panel of the current buffer.  Return the new panel,
or nil when it hid one."
  (let* ((options (etaf-posframe--validate (copy-sequence options)))
         (panel (if (plist-member options :key)
                    (etaf-posframe--panel-for-key (plist-get options :key))
                  (etaf-posframe--current-panel))))
    (if panel
        (progn (etaf-posframe-hide panel) nil)
      (apply #'etaf-posframe-show view options))))

(defun etaf-posframe--remember-size (panel window)
  "Record WINDOW's settled text size as PANEL's resize baseline.
The size is (WIDTH . HEIGHT) of the text area in pixels, which is what
`set-frame-size' takes back; a refused resize returns to it.  The frame's
position is recorded with it, because a top or left edge drag moves the frame
origin while it resizes, and a refused axis must not leave the panel
somewhere else."
  (when (window-live-p window)
    (let ((frame (window-frame window)))
      (setf (etaf-posframe--panel-size panel)
            (cons (window-body-width window t) (window-pixel-height window))
            (etaf-posframe--panel-position panel)
            (frame-position frame)))))

(defun etaf-posframe--resize-permitted (panel)
  "Return the (WIDTH-OK . HEIGHT-OK) PANEL's `:resizable' option allows.
`t' allows both axes, nil allows neither, and a list allows an axis whose
edges it names: `left' or `right' for a width change, `top' or `bottom' for a
height change."
  (let ((resizable (plist-get (etaf-posframe--panel-options panel) :resizable)))
    (cond
     ((eq resizable t) (cons t t))
     ((null resizable) (cons nil nil))
     ((listp resizable)
      (cons (or (memq 'left resizable) (memq 'right resizable) nil)
            (or (memq 'top resizable) (memq 'bottom resizable) nil)))
     (t (cons t t)))))

(defun etaf-posframe--restore-frame-size (panel window permitted)
  "Set back the axes PANEL's `:resizable' does not allow.
PERMITTED is its (WIDTH-OK . HEIGHT-OK).  An allowed axis keeps the size the
caller asked for and the origin its edge moved; a refused axis returns to the
settled size and origin, so a top or left edge drag cannot slide the panel.
Return non-nil when the frame was set back."
  (let* ((frame (window-frame window))
         (size (etaf-posframe--panel-size panel))
         (position (etaf-posframe--panel-position panel))
         (origin (frame-position frame))
         (width (if (car permitted)
                    (window-body-width window t)
                  (car size)))
         (height (if (cdr permitted)
                     (window-pixel-height window)
                   (cdr size)))
         (moved nil))
    (when (and size
               (or (/= width (window-body-width window t))
                   (/= height (window-pixel-height window))))
      (set-frame-size frame width height t)
      (setq moved t))
    (when (and position
               (or (and (not (car permitted))
                        (/= (car origin) (car position)))
                   (and (not (cdr permitted))
                        (/= (cdr origin) (cdr position)))))
      (set-frame-position frame
                          (if (car permitted) (car origin) (car position))
                          (if (cdr permitted) (cdr origin) (cdr position)))
      (setq moved t))
    moved))

(defun etaf-posframe--adopt-frame-size (panel window)
  "Adopt the width and row budget of a frame resized from outside.
An outside resize (the user dragging an edge, a caller's `set-frame-size', a
tiling step) sets the frame size, so the canvas follows it instead of snapping
the frame back to the columns and rows the panel opened with.  A taller or
shorter frame becomes the new row budget, which lets a View that fills its
viewport, such as a complete app, show more or fewer rows.  `:resizable'
decides which axes accept the change, and a refused axis is put back.  Return
non-nil when the panel adopted or restored a size."
  (let* ((frame (window-frame window))
         (options (etaf-posframe--panel-options panel))
         (char (frame-char-width frame))
         (width (window-body-width window t))
         (header (if (plist-get options :title)
                     (window-header-line-height window)
                   0))
         (rows (max 1 (floor (- (window-pixel-height window) header)
                             (float (frame-char-height frame)))))
         (budget (etaf-posframe--row-budget panel))
         (content (etaf-posframe--lines (etaf-posframe--panel-buffer panel)))
         (permitted (etaf-posframe--resize-permitted panel))
         (adopted options)
         (resized nil)
         (restored nil))
    (when (and (etaf-posframe--panel-settled panel) (> width 0))
      (cond
       ((= width (or (plist-get options :pixel-width) 0)))
       ((not (car permitted))
        (setq restored (etaf-posframe--restore-frame-size
                        panel window permitted)))
       (t
        (setq adopted (plist-put (plist-put (copy-sequence adopted)
                                           :pixel-width width)
                                 :width (max 1 (round (/ width (float char)))))
              resized t)
        (let ((theme-ref (etaf-posframe--panel-theme panel)))
          (when (and (plist-get adopted :title) (etaf-ref-p theme-ref))
            (etaf-posframe--refresh-header
             panel (etaf-value theme-ref) (plist-get adopted :width)))))))
    ;; A resize away from the row budget is the new budget: taller always, and
    ;; shorter only when it cuts into the content.  The panel's own fit sets
    ;; the frame to the content height, which must not shrink the budget.
    (when (and (etaf-posframe--panel-settled panel)
               (or (> rows budget) (< rows (min budget content))))
      (if (cdr permitted)
          (setq adopted (plist-put (copy-sequence adopted) :height rows)
                resized t)
        ;; The height is restored by this panel's own fit, which runs next.
        (unless restored
          (setq restored (etaf-posframe--restore-frame-size
                          panel window permitted)))))
    (when resized
      (setf (etaf-posframe--panel-options panel) adopted)
      ;; The retained renderer owns the layout, so the new size is laid out
      ;; once here, deferred out of the resize event that reported it.
      (etaf-runtime-refit (etaf-posframe--panel-runtime panel)
                          (plist-get adopted :pixel-width) rows))
    (or resized restored)))

;;;###autoload
(defun etaf-posframe--fit-now (panel)
  "Re-lay out PANEL at its frame size and fit the frame to the content.
Runs outside render and event callbacks; it never touches the buffer.  Only a
real size change re-lays the View out: re-laying out for a size the panel
already has is the cost that made a resize feel like a stall.  A panel that
fits more often than `etaf-posframe--fit-limit' in one second backs off for
`etaf-posframe--fit-backoff', so a condition that keeps resizing it can never
run away with the CPU."
  (when (and (etaf-posframe-live-p panel)
             (or (null (etaf-posframe--panel-fit-muted-until panel))
                 (< (float-time) (etaf-posframe--panel-fit-muted-until panel))))
    (let* ((now (float-time))
           (start (etaf-posframe--panel-fit-window panel))
           (count (if (and start (< (- now start) 1.0))
                      (1+ (or (etaf-posframe--panel-fit-count panel) 0))
                    1)))
      (setf (etaf-posframe--panel-fit-window panel) (if (= count 1) now start)
            (etaf-posframe--panel-fit-count panel) count)
      (if (> count etaf-posframe--fit-limit)
          (progn
            (setf (etaf-posframe--panel-fit-muted-until panel)
                  (+ now etaf-posframe--fit-backoff)
                  (etaf-posframe--panel-fit-count panel) 0
                  (etaf-posframe--panel-fit-window panel) nil)
            (message "ETAF panel: %s fitted %d times in one second; backing off %ss"
                     (buffer-name (etaf-posframe--panel-buffer panel))
                     count etaf-posframe--fit-backoff))
        (let* ((buffer (etaf-posframe--panel-buffer panel))
               (window (get-buffer-window buffer t)))
          (when (window-live-p window)
            ;; A frame resized from outside re-lays the View out at its new
            ;; width and rows; a content change needs no re-layout, because
            ;; ETAF already rendered it and a second layout writer duplicates
            ;; rows.  Either way only the frame height follows the content.
            (let ((adopted (etaf-posframe--adopt-frame-size panel window))
                  (fitted (etaf-posframe--resize-to-content panel window)))
              (when (and (or adopted fitted)
                         (etaf-posframe--panel-settled panel))
                (etaf-posframe--fit panel)))
            (etaf-posframe--remember-size panel window)))))))

;;;###autoload
(defun etaf-posframe-refresh (&optional panel)
  "Schedule PANEL to fit its frame after the current event finishes.
PANEL defaults to the current buffer's panel.  Call it after the View's
content or style changed, or after the frame was resized; a frame resized from
outside becomes the panel width and the View re-lays out at it.  The fit is
deferred so it never runs inside a render or an event callback.  Return
non-nil when PANEL is live."
  (interactive)
  (let ((panel (or panel (etaf-posframe--current-panel))))
    (when (etaf-posframe-live-p panel)
      (when-let* ((timer (etaf-posframe--panel-fit-timer panel)))
        (cancel-timer timer))
      (setf (etaf-posframe--panel-fit-timer panel)
            ;; Zero delay runs on the next timer tick, after the redisplay
            ;; that reported the size: a resize therefore shows at most one
            ;; frame of the old layout instead of a visible garble.
            (run-at-time 0 nil
                         (lambda ()
                           (setf (etaf-posframe--panel-fit-timer panel) nil)
                           (ignore-errors (etaf-posframe--fit-now panel)))))
      t)))

(defun etaf-posframe--terminal-refit (panel)
  "Re-place PANEL in its terminal frame after the terminal changed size.
A terminal resize changes the parent frame's columns and rows, while a child
frame keeps the geometry it was created with.  Clamping the column count and
the row budget to the new frame and running the poshandler again keeps the
panel on screen at the anchor it was opened with."
  (when (etaf-posframe-live-p panel)
    (let* ((buffer (etaf-posframe--panel-buffer panel))
           (parent (etaf-posframe--panel-parent-frame panel))
           (options (etaf-posframe--panel-options panel))
           (char (max 1 (frame-char-width parent)))
           ;; One cell on each side stays free, so the frame border still fits.
           (columns (max 1 (min (or (plist-get options :width) 1)
                                (- (frame-width parent) 2))))
           (budget (max 1 (min (etaf-posframe--row-budget panel)
                               (- (frame-height parent) 2))))
           (lines (max 1 (min (etaf-posframe--lines buffer) budget))))
      (setf (etaf-posframe--panel-options panel)
            (plist-put (plist-put (plist-put (copy-sequence options)
                                             :width columns)
                                  :pixel-width (* columns char))
                       :height budget))
      (apply #'posframe-show buffer
             (etaf-posframe--frame-args panel lines))
      (when-let* ((window (get-buffer-window buffer t)))
        (etaf-posframe--fit-height panel window)))))

(defun etaf-posframe--window-size-changed (frame)
  "Re-fit the panels FRAME hosts or the panel FRAME itself after a resize."
  (let ((terminal (not (display-graphic-p frame))))
    (dolist (panel (copy-sequence etaf-posframe--panels))
      (cond
       ((eq (etaf-posframe--panel-frame panel) frame)
        (etaf-posframe-refresh panel))
       ((eq (etaf-posframe--panel-parent-frame panel) frame)
        (if terminal
            (etaf-posframe--terminal-refit panel)
          (etaf-posframe-refresh panel)))))))

(defun etaf-posframe-panel-theme (panel)
  "Return PANEL's current Theme plist, or nil when it is not live."
  (when (etaf-posframe-live-p panel)
    (let ((theme (etaf-posframe--panel-theme panel)))
      (and (etaf-ref-p theme) (etaf-value theme)))))

(defun etaf-posframe-current-theme ()
  "Return the Theme of the panel whose View is rendering, or nil."
  (let ((runtime (ignore-errors (etaf-runtime-for-buffer (current-buffer)))))
    (when runtime
      (let ((panel (cl-find-if
                    (lambda (panel)
                      (eq (etaf-posframe--panel-runtime panel) runtime))
                    etaf-posframe--panels)))
        (and panel (etaf-posframe-panel-theme panel))))))

;;;###autoload
(defun etaf-posframe-panel-frame (panel)
  "Return PANEL's child frame, or nil when PANEL is not live."
  (when (etaf-posframe-live-p panel)
    (etaf-posframe--panel-frame panel)))

(defun etaf-posframe-live-p (panel)
  "Return non-nil while PANEL's frame exists and its Runtime is mounted."
  (and (etaf-posframe--panel-p panel)
       (frame-live-p (etaf-posframe--panel-frame panel))
       (etaf-runtime-mounted-p (etaf-posframe--panel-runtime panel))))

(defun etaf-posframe-panels ()
  "Return the live panels, most recent first."
  (cl-remove-if-not #'etaf-posframe-live-p etaf-posframe--panels))

;;; Panel input

(defun etaf-posframe--app-target ()
  "Return the panel the app prefix commands act on.
The panel of the selected frame comes first, then the most recent panel, so a
prefix command can nudge a panel while the keyboard sits in an ordinary buffer:
a text terminal cannot give a child frame the keyboard or the mouse."
  (or (etaf-posframe--panel-for-frame (selected-frame))
      (car (etaf-posframe-panels))))

(defun etaf-posframe--pin-position (panel x y)
  "Make (X . Y) PANEL's anchor, so a later refresh keeps that place."
  (setf (etaf-posframe--panel-options panel)
        (plist-put (copy-sequence (etaf-posframe--panel-options panel))
                   :at (cons 'pixels (cons x y)))))

(defun etaf-posframe--pin-size (panel width height)
  "Record WIDTH by HEIGHT as PANEL's size, so later refreshes keep it.
The height becomes the panel's row budget, which is why it is kept through
`:fill-height'."
  (setf (etaf-posframe--panel-options panel)
        (plist-put (plist-put (plist-put (copy-sequence (etaf-posframe--panel-options panel))
                                         :width width)
                              :height height)
                   :fill-height t)))

;;;###autoload
(defun etaf-posframe-move (direction &optional steps panel)
  "Move PANEL STEPS character cells in DIRECTION.
DIRECTION is `left', `right', `up' or `down'.  STEPS defaults to
`etaf-posframe-move-step'; one step is one character, so a graphical frame
moves by its character width and height and a terminal by its single cell.
The panel keeps the new place through later refreshes.  A text terminal
reaches this from the app prefix map, because a child frame there takes
neither the keyboard nor the mouse."
  (interactive
   (list (intern (completing-read "方向: " '("left" "right" "up" "down") nil t))
         (and current-prefix-arg (prefix-numeric-value current-prefix-arg))))
  (let* ((panel (or panel (etaf-posframe--app-target)))
         (frame (and panel (etaf-posframe-panel-frame panel))))
    (unless (frame-live-p frame)
      (signal 'etaf-posframe-error (list "No live ETAF panel to move")))
    (let* ((steps (or steps etaf-posframe-move-step))
           (cell-width (max 1 (frame-char-width frame)))
           (cell-height (max 1 (frame-char-height frame)))
           (dx (* cell-width (pcase direction ('left (- steps)) ('right steps) (_ 0))))
           (dy (* cell-height (pcase direction ('up (- steps)) ('down steps) (_ 0))))
           (position (frame-position frame))
           (parent (etaf-posframe--panel-parent-frame panel))
           (parent-width (if (frame-live-p parent) (frame-pixel-width parent) 0))
           (parent-height (if (frame-live-p parent) (frame-pixel-height parent) 0))
           ;; A panel stays inside its parent frame, so a run of moves cannot
           ;; push it off screen where only part of it would be reachable.
           (x (max 0 (min (+ (or (car-safe position) 0) dx)
                          (max 0 (- parent-width (frame-pixel-width frame))))))
           (y (max 0 (min (+ (or (cdr-safe position) 0) dy)
                          (max 0 (- parent-height (frame-pixel-height frame)))))))
      (set-frame-position frame x y)
      (etaf-posframe--pin-position panel x y)
      panel)))

;;;###autoload
(defun etaf-posframe-resize (axis &optional steps panel)
  "Change PANEL's size by STEPS cells along AXIS.
AXIS is `wider', `narrower', `taller' or `shorter'.  STEPS defaults to
`etaf-posframe-resize-step'.  The panel keeps its new width and row budget
through later refreshes."
  (interactive
   (list (intern (completing-read "方向: " '("wider" "narrower" "taller" "shorter") nil t))
         (and current-prefix-arg (prefix-numeric-value current-prefix-arg))))
  (let* ((panel (or panel (etaf-posframe--app-target)))
         (frame (and panel (etaf-posframe-panel-frame panel))))
    (unless (frame-live-p frame)
      (signal 'etaf-posframe-error (list "No live ETAF panel to resize")))
    (let* ((steps (or steps etaf-posframe-resize-step))
           (dw (pcase axis ('wider steps) ('narrower (- steps)) (_ 0)))
           (dh (pcase axis ('taller steps) ('shorter (- steps)) (_ 0)))
           (width (max 4 (+ (frame-width frame) dw)))
           (height (max 2 (+ (frame-height frame) dh))))
      ;; Record the size first: the frame's own size change runs a refresh
      ;; that would otherwise put the old width back.
      (etaf-posframe--pin-size panel width height)
      (set-frame-size frame width height)
      (etaf-posframe-refresh panel)
      panel)))

;;;###autoload
(defun etaf-posframe-send-key (&optional panel)
  "Read one key sequence and run it in PANEL's View.
A text terminal cannot give a child frame the keyboard, so this is how the
panel's own keys are reached: the key runs with the panel's buffer current.
A key the View declares runs there; a control that needs the keyboard focus on
a particular row, such as a button reached through Tab, still needs a
graphical frame.  Return the key sequence that ran."
  (interactive)
  (let* ((panel (or panel (etaf-posframe--app-target)))
         (buffer (and panel (etaf-posframe--panel-buffer panel))))
    (unless (buffer-live-p buffer)
      (signal 'etaf-posframe-error (list "No live ETAF panel to send a key to")))
    (let ((keys (read-key-sequence-vector "面板按键: ")))
      (with-current-buffer buffer
        (execute-kbd-macro keys))
      keys)))

;;; Applications

(defcustom etaf-posframe-app-repeat-delay 0.3
  "Seconds during which a repeated app toggle is ignored.
Opening a panel mounts a whole application, so key repeat would otherwise mount
it once per repeat and stall Emacs."
  :type 'number
  :group 'etaf-posframe)

(defvar etaf-posframe-apps nil
  "Registered applications, a list of (ID . PLIST) in registration order.")

(defvar etaf-posframe-app-map (make-sparse-keymap)
  "Keymap with one binding per registered application `:key'.")

(defvar etaf-posframe--app-panels (make-hash-table :test #'eq)
  "Live panel of each registered application, by ID.")

(defvar etaf-posframe--app-toggled-at (make-hash-table :test #'eq)
  "Time of each application's last real toggle, for the repeat guard.")

(defconst etaf-posframe--app-options etaf-posframe--show-keys
  "Registration keys handed to `etaf-posframe-show' unchanged.")

(defvar etaf-posframe--app-sessions (make-hash-table :test #'eq)
  "Live application sessions by registration ID, for `:keep-alive' apps.")

(defun etaf-posframe--app-show-options (record)
  "Return the `etaf-posframe-show' options RECORD carries.
Every key in `etaf-posframe--app-options' is passed through, so a registration
can use the whole panel vocabulary without the registry listing it again."
  (let (options)
    (dolist (key etaf-posframe--app-options)
      (when (plist-member record key)
        (setq options (plist-put options key (plist-get record key)))))
    options))

(defun etaf-posframe-app-record (id)
  "Return the registration plist of application ID."
  (or (cdr (assq id etaf-posframe-apps))
      (signal 'etaf-posframe-error
              (list (format "Application %s is not registered" id)))))

(defvar etaf-posframe--nudge-map nil
  "Keys that keep moving or resizing a panel while the prefix stays active.
`etaf-posframe--nudge' installs it as a transient map, so the arrow keys keep
working until a key it does not bind ends the run.")

(defun etaf-posframe--nudge (direction)
  "Move the target panel DIRECTION and keep the arrow keys nudging it.
The map stays active until a key it does not bind is pressed, so one prefix
reaches a run of moves instead of stopping after one cell."
  (etaf-posframe-move direction)
  (set-transient-map etaf-posframe--nudge-map t))

(defun etaf-posframe--nudge-resize (axis)
  "Change the target panel's size along AXIS and keep the keys nudging it."
  (etaf-posframe-resize axis)
  (set-transient-map etaf-posframe--nudge-map t))

(setq etaf-posframe--nudge-map
      (let ((map (make-sparse-keymap)))
        (define-key map [left] (lambda () (interactive) (etaf-posframe--nudge 'left)))
        (define-key map [right] (lambda () (interactive) (etaf-posframe--nudge 'right)))
        (define-key map [up] (lambda () (interactive) (etaf-posframe--nudge 'up)))
        (define-key map [down] (lambda () (interactive) (etaf-posframe--nudge 'down)))
        ;; Control plus an arrow is a desktop shortcut on macOS: the window
        ;; manager switches spaces before Emacs sees the key.  Plain `=' and
        ;; `-' size the width, `>' and '<' the height, and every terminal sends
        ;; them.
        (define-key map (kbd "=") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
        (define-key map (kbd "+") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
        (define-key map (kbd "-") (lambda () (interactive) (etaf-posframe--nudge-resize 'narrower)))
        (define-key map (kbd ">") (lambda () (interactive) (etaf-posframe--nudge-resize 'taller)))
        (define-key map (kbd "<") (lambda () (interactive) (etaf-posframe--nudge-resize 'shorter)))
        map))

(defun etaf-posframe--app-keymap ()
  "Return a keymap binding every registered application `:key'."
  (let ((map (make-sparse-keymap)))
    (dolist (entry etaf-posframe-apps)
      (let ((id (car entry))
            (shortcut (plist-get (cdr entry) :shortcut)))
        (when shortcut
          (define-key map (kbd shortcut)
                      (lambda () (interactive) (etaf-posframe-app id))))))
    ;; The panel's place and keys are reached from the buffer the user is in:
    ;; a text terminal gives a child frame neither the keyboard nor the mouse.
    ;; Each of these also installs `etaf-posframe--nudge-map', so the next
    ;; arrow presses move the same panel without the prefix again.
    (define-key map [left] (lambda () (interactive) (etaf-posframe--nudge 'left)))
    (define-key map [right] (lambda () (interactive) (etaf-posframe--nudge 'right)))
    (define-key map [up] (lambda () (interactive) (etaf-posframe--nudge 'up)))
    (define-key map [down] (lambda () (interactive) (etaf-posframe--nudge 'down)))
    (define-key map (kbd "=") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
    (define-key map (kbd "+") (lambda () (interactive) (etaf-posframe--nudge-resize 'wider)))
    (define-key map (kbd "-") (lambda () (interactive) (etaf-posframe--nudge-resize 'narrower)))
    (define-key map (kbd ">") (lambda () (interactive) (etaf-posframe--nudge-resize 'taller)))
    (define-key map (kbd "<") (lambda () (interactive) (etaf-posframe--nudge-resize 'shorter)))
    (define-key map (kbd "k") #'etaf-posframe-send-key)
    map))

;;;###autoload
(defun etaf-posframe-register-app (id &rest options)
  "Register application ID with OPTIONS, as described in the package Commentary."
  (unless (symbolp id)
    (signal 'etaf-posframe-error (list "Application ID must be a symbol" id)))
  (unless (plist-get options :create)
    (signal 'etaf-posframe-error
            (list (format "Application %s needs :create" id))))
  (unless (plist-get options :view)
    (signal 'etaf-posframe-error
            (list (format "Application %s needs :view" id))))
  ;; Registering again replaces the record but keeps the order.
  (setq etaf-posframe-apps
        (append (assq-delete-all id etaf-posframe-apps)
                (list (cons id options)))
        etaf-posframe-app-map (etaf-posframe--app-keymap))
  id)

;;;###autoload
(defun etaf-posframe-cycle ()
  "Move input focus to the next open panel, then back to its frame.
With no panel focused, focus the most recent panel.  Return the frame that now
has focus."
  (interactive)
  (let* ((panels (etaf-posframe-panels))
         (selected (selected-frame))
         (current (cl-position-if (lambda (panel)
                                    (eq (etaf-posframe--panel-frame panel) selected))
                                  panels))
         (target (cond ((null panels) (selected-frame))
                       ((null current) (etaf-posframe--panel-frame (car panels)))
                       ((< (1+ current) (length panels))
                        (etaf-posframe--panel-frame (nth (1+ current) panels)))
                       (t (or (etaf-posframe--panel-parent-frame
                               (nth current panels))
                              (selected-frame))))))
    (when (frame-live-p target)
      (etaf-posframe--restore-input-focus target)
      (when-let* ((panel (etaf-posframe--panel-for-frame target))
                  (window (get-buffer-window (etaf-posframe--panel-buffer panel) t)))
        (select-window window)
        (setf (etaf-posframe--panel-focused panel) t)))
    (etaf-posframe--paint-borders)
    target))

;;;###autoload
(defun etaf-posframe-app-prefix ()
  "Read one key and open the registered application bound to it."
  (interactive)
  (let* ((keys (read-key-sequence-vector nil t))
         (command (and keys (lookup-key etaf-posframe-app-map keys))))
    (if (commandp command)
        (call-interactively command)
      (signal 'etaf-posframe-error
              (list (format "No ETAF application on %s"
                            (if keys (key-description keys) "no key")))))))

;;;###autoload
(defun etaf-posframe-app (id)
  "Open or close the registered application ID's panel.
A `:keep-alive' application is only hidden: its session stays in the registry
and the next open resumes it.  Return the panel, or nil when it hid one."
  (interactive
   (list (intern (completing-read "ETAF 应用: "
                                  (mapcar #'car etaf-posframe-apps) nil t))))
  (let* ((record (etaf-posframe-app-record id))
         (panel (gethash id etaf-posframe--app-panels))
         (keep (plist-get record :keep-alive))
         (now (float-time)))
    (if (etaf-posframe-live-p panel)
        (progn
          (puthash id now etaf-posframe--app-toggled-at)
          (puthash id nil etaf-posframe--app-panels)
          (etaf-posframe-hide panel)
          nil)
      (unless (< (- now (or (gethash id etaf-posframe--app-toggled-at) 0))
                 etaf-posframe-app-repeat-delay)
        (puthash id now etaf-posframe--app-toggled-at)
        (when-let* ((feature (plist-get record :require)))
          (require feature nil t))
        (let* ((session (or (and keep (gethash id etaf-posframe--app-sessions))
                            (funcall (plist-get record :create))))
               (panel (apply #'etaf-posframe-show
                             (funcall (plist-get record :view) session)
                             (append
                              ;; Defaults first, then the registration, then
                              ;; the keys this registry owns.
                              (list :at 'frame-top-right
                                    :stack t
                                    :width etaf-posframe-default-width
                                    :height etaf-posframe-default-max-height
                                    :title (plist-get record :title)
                                    :focusable t)
                              (etaf-posframe--app-show-options record)
                              (list :key id)))))
          (when keep
            (puthash id session etaf-posframe--app-sessions))
          (setf (etaf-posframe--panel-close-callback panel)
                (lambda (_panel)
                  (puthash id nil etaf-posframe--app-panels)
                  (unless keep
                    (etaf-posframe--app-stop id session))))
          (puthash id panel etaf-posframe--app-panels)
          panel)))))

(defun etaf-posframe--app-stop (id session)
  "Release SESSION of application ID and forget it."
  (remhash id etaf-posframe--app-sessions)
  (when-let* ((record (ignore-errors (etaf-posframe-app-record id)))
              (stop (plist-get record :on-stop)))
    (condition-case error
        (funcall stop session)
      (error (message "ETAF application %s :on-stop failed: %s"
                      id (error-message-string error))))))

;;;###autoload
(defun etaf-posframe-app-quit (id)
  "Stop application ID, hide its panel and release its session."
  (interactive
   (list (intern (completing-read "退出 ETAF 应用: "
                                  (mapcar #'car etaf-posframe-apps) nil t))))
  (let ((panel (gethash id etaf-posframe--app-panels))
        (session (gethash id etaf-posframe--app-sessions)))
    (when (etaf-posframe-live-p panel)
      (etaf-posframe-hide panel))
    (when session
      (etaf-posframe--app-stop id session))
    (puthash id nil etaf-posframe--app-panels)
    nil))

(provide 'etaf-posframe)
;;; etaf-posframe.el ends here
