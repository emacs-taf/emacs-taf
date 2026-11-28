;;; etaf-posframe-pool.el --- Shared child-frame pool, theme and options for etaf-posframe -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Customization options, panel record definition, macOS-safe graphical
;; child-frame reuse pool (shared with `etaf-pip'), panel Theme derivation,
;; surface wrapper and placement option normalization.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'posframe)

(declare-function etaf-posframe--current-panel "etaf-posframe-panel" ())
(declare-function etaf-posframe-hide "etaf-posframe-panel" (&optional panel))
(declare-function etaf-posframe-panels "etaf-posframe-layout" ())
(declare-function etaf-posframe--restore-input-focus "etaf-posframe-panel" (frame))

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

(defconst etaf-posframe--park-buffer-name " *ETAF Panel Park*"
  "Hidden live buffer displayed in parked graphical child frames.")

(defvar etaf-posframe--frame-pool nil
  "Parked graphical child frames awaiting reuse.
Recycling graphical child frames avoids both repeated native window
creation and macOS NS `NSTextInputContext' crashes when `delete-frame'
runs `ns_free_frame_resources' on a child frame.")

(defvar etaf-posframe--counter 0
  "Panel sequence number used for buffer names.")

(defvar-local etaf-posframe--panel nil
  "Panel shown in this buffer, or nil.")

(defvar etaf-posframe--dismissing nil
  "Non-nil while a dismissal pass runs, to avoid re-entrant hooks.")

(defvar etaf-posframe--dragging nil
  "Non-nil while `etaf-posframe-drag' actively tracks mouse movement.")

(defvar etaf-posframe--positioning nil
  "Non-nil while `etaf-posframe' itself moves a child frame.")

(defvar etaf-posframe--stack-obstacles :auto
  "Obstacle rects for `etaf-posframe--stacking-poshandler', or `:auto'.
When `:auto', the poshandler reads live non-modal panels on the same parent
frame, excluding the frame being placed.  During a multi-panel stack reflow,
this binds to the already-placed rectangles in oldest-first order.")

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

(defvar-local etaf-posframe--panel-keys-p nil
  "Non-nil while `etaf-posframe-panel-keys' is active in this panel buffer.
Ordinary focusable panels enable it so `q', `ESC' and `C-g' close them;
modal child frames leave it nil so ETAF's modal scope owns Escape, search
editing and native `C-g'.")

(defvar etaf-posframe--fitting nil
  "Non-nil while a panel fit pass is re-rendering its buffer.")

(defun etaf-posframe--escape-command ()
  "Handle `ESC' / `C-g' inside a focused panel.
Calls the panel's `:on-escape' callback when configured, else hides it."
  (when-let* ((panel (etaf-posframe--current-panel)))
    (let ((cb (plist-get (etaf-posframe--panel-options panel) :on-escape)))
      (if (functionp cb)
          (condition-case err
              (funcall cb panel)
            (error (message "ETAF panel escape callback failed: %s"
                            (error-message-string err))))
        (etaf-posframe-hide panel)))))

(defvar etaf-posframe-panel-keys
  (let ((map (make-sparse-keymap))
        (esc (lambda () (interactive) (etaf-posframe--escape-command))))
    (define-key map (kbd "q") #'etaf-posframe-hide)
    (define-key map [escape] esc)
    (define-key map (kbd "C-g") esc)
    map)
  "Keys active while a focusable panel has focus.
`q' hides the panel; `ESC' and `C-g' delegate to `:on-escape' or hide it.")

(add-to-list 'emulation-mode-map-alists
             (list (cons 'etaf-posframe--panel-keys-p etaf-posframe-panel-keys)))

(cl-defstruct (etaf-posframe--panel (:constructor etaf-posframe--make-panel))
  buffer frame parent parent-frame parent-window parent-geometry
  parent-window-edges options timer restore-frame restore-window
  focused fit-timer settled fit-window fit-count fit-muted-until
  close-callback size position pin-applied modal-p modal-window help-p
  closed-p)

(defun etaf-posframe--frame-active-p (frame)
  "Return non-nil when FRAME is live and not parked in the reuse pool."
  (and (frame-live-p frame)
       (not (frame-parameter frame 'etaf-posframe-pooled))))

(defun etaf-posframe--park-buffer ()
  "Return the hidden live buffer kept in parked graphical child frames.
Keeping a live buffer in a parked child frame guarantees its window's
buffer pointer never becomes nil if AppKit queries the view."
  (let ((buf (get-buffer-create etaf-posframe--park-buffer-name)))
    (with-current-buffer buf
      (setq-local mode-line-format nil
                  header-line-format nil
                  tab-line-format nil
                  cursor-type nil
                  cursor-in-non-selected-windows nil
                  truncate-lines t))
    buf))

(defun etaf-posframe--park-frame (frame &optional parent-frame)
  "Hide and park graphical child FRAME for reuse instead of deleting it.
Return non-nil when FRAME was parked."
  (when (and (frame-live-p frame)
             (display-graphic-p frame)
             (frame-parent frame))
    (when (frame-visible-p frame)
      (ignore-errors (make-frame-invisible frame)))
    (let ((win (frame-root-window frame))
          (park (etaf-posframe--park-buffer)))
      (when (window-live-p win)
        (ignore-errors (set-window-dedicated-p win nil))
        (ignore-errors (set-window-buffer win park))
        (ignore-errors (set-window-hscroll win 0))
        (ignore-errors (set-window-start win (point-min) t))
        (ignore-errors (set-window-point win (point-min)))))
    (ignore-errors
      (modify-frame-parameters
       frame
       `((posframe-buffer . nil)
         (posframe-hidehandler . nil)
         (posframe-parent-buffer . nil)
         (no-accept-focus . t)
         (etaf-posframe-pooled . t)
         ,@(when (and (frame-live-p parent-frame)
                      (not (eq (frame-parent frame) parent-frame)))
             (list (cons 'parent-frame parent-frame))))))
    (setq etaf-posframe--frame-pool
          (cons frame
                (cl-remove-if (lambda (f)
                                (or (eq f frame)
                                    (not (frame-live-p f))
                                    (not (frame-parent f))))
                              etaf-posframe--frame-pool)))
    t))

(defun etaf-posframe--acquire-pooled-frame (parent-frame)
  "Pop and return a live parked graphical child frame for PARENT-FRAME."
  (when (and (frame-live-p parent-frame) (display-graphic-p parent-frame))
    (setq etaf-posframe--frame-pool
          (cl-remove-if-not
           (lambda (f)
             (and (frame-live-p f)
                  (display-graphic-p f)
                  (frame-parent f)
                  (frame-parameter f 'etaf-posframe-pooled)))
           etaf-posframe--frame-pool))
    (let ((match (cl-find-if
                  (lambda (f)
                    (and (eq (frame-parent f) parent-frame)
                         (not (cl-some (lambda (p)
                                         (eq (etaf-posframe--panel-frame p) f))
                                       etaf-posframe--panels))))
                  etaf-posframe--frame-pool)))
      (when match
        (setq etaf-posframe--frame-pool (delq match etaf-posframe--frame-pool))
        (set-frame-parameter match 'etaf-posframe-pooled nil)
        match))))

(defun etaf-posframe--configure-pooled-frame (frame panel lines)
  "Reconfigure parked graphical child FRAME in place for PANEL and LINES.
Leaves FRAME invisible so callers can fit and place it without flashing."
  (let* ((options (etaf-posframe--panel-options panel))
         (buffer (etaf-posframe--panel-buffer panel))
         (parent-frame (etaf-posframe--panel-parent-frame panel))
         (parent-buffer (etaf-posframe--panel-parent panel))
         (title (plist-get options :title))
         (border (plist-get options :border))
         (focusable (and (plist-get options :focusable) t))
         (theme-ref (etaf-posframe--panel-theme panel))
         (theme (and theme-ref (etaf-value theme-ref)))
         (bg (or (plist-get theme :ui-panel-bg) "#FFFFFF"))
         (fg (or (plist-get theme :ui-fg) "#000000"))
         (border-width (or (plist-get border :width)
                           etaf-posframe-border-width))
         (border-color (or (plist-get border :color)
                           (plist-get theme :ui-panel-border)))
         (char-w (max 1 (frame-char-width parent-frame)))
         (char-h (max 1 (frame-char-height parent-frame)))
         (pixel-w (or (plist-get options :pixel-width)
                      (* (or (plist-get options :width) 1) char-w)))
         (pixel-h (* (max 1 (+ lines (if title 1 0))) char-h))
         (win (frame-root-window frame)))
    (when (frame-visible-p frame)
      (ignore-errors (make-frame-invisible frame)))
    (with-current-buffer buffer
      (setq-local posframe--frame frame
                  posframe--accept-focus focusable))
    (modify-frame-parameters
     frame
     `((parent-frame . ,parent-frame)
       (posframe-buffer . ,(cons (buffer-name buffer) buffer))
       (posframe-hidehandler . nil)
       (posframe-parent-buffer . ,(when (buffer-live-p parent-buffer)
                                    (cons (buffer-name parent-buffer)
                                          parent-buffer)))
       (foreground-color . ,fg)
       (background-color . ,bg)
       (font . ,(face-attribute 'default :font parent-frame))
       (no-accept-focus . ,(not focusable))
       (left-fringe . 0)
       (right-fringe . 0)
       (border-width . 0)
       (internal-border-width . ,border-width)
       (child-frame-border-width . ,border-width)
       (vertical-scroll-bars . nil)
       (horizontal-scroll-bars . nil)
       (menu-bar-lines . 0)
       (tool-bar-lines . 0)
       (tab-bar-lines . 0)
       (line-spacing . 0)
       (cursor-type . nil)
       (unsplittable . t)
       (no-other-frame . t)
       (undecorated . t)
       (no-special-glyphs . t)
       (skip-taskbar . t)
       (desktop-dont-save . t)
       (minibuffer . ,(minibuffer-window parent-frame))
       (top-visible . 24)
       (snap-width . 12)
       (drag-with-header-line . ,(and (etaf-posframe--draggable-p options) t))
       (drag-internal-border . ,(not (null (plist-get options :resizable))))
       (etaf-posframe-pooled . nil)))
    (set-face-attribute 'default frame
                        :background (or (plist-get theme :ui-panel-bg) bg)
                        :foreground (or (plist-get theme :ui-panel-fg) fg))
    (when border-color
      (set-face-background
       (if (facep 'child-frame-border) 'child-frame-border 'internal-border)
       border-color frame))
    (when (window-live-p win)
      (set-window-dedicated-p win nil)
      (set-window-parameter win 'mode-line-format 'none)
      (set-window-parameter win 'header-line-format (if title nil 'none))
      (set-window-buffer win buffer)
      (set-window-dedicated-p win t)
      (set-window-scroll-bars win 0 nil nil)
      (set-window-hscroll win 0)
      (set-window-start win (point-min) t)
      (set-window-point win (point-min)))
    (let ((frame-resize-pixelwise t))
      (set-frame-size frame pixel-w pixel-h t))
    frame))

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
    :auto-hide :theme :border :draggable :title :key :resizable
    :scrollable :on-escape :on-blur :on-move)
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
               :keep-alive :scrollable)
           (unless (memq value '(t nil))
             (signal 'etaf-posframe-error
                     (list (format "Panel %s must be t or nil: %S" key value)))))
          ((or :on-escape :on-blur :on-move)
           (unless (or (null value) (functionp value))
             (signal 'etaf-posframe-error
                     (list (format "Panel %s must be a function or nil: %S" key value)))))
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
                        (cons :scrollable t)
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

(defun etaf-posframe--stacking-poshandler (at &optional base-handler)
  "Return a poshandler placing the panel at AT, clear of live panels.
BASE-HANDLER, when non-nil, computes the starting anchor position (such as an
offset anchor); otherwise `etaf-posframe--poshandler' for AT is used.
A panel stacks against live non-modal panels on the same parent frame,
excluding itself: from a top or centre anchor it sits directly below the lowest
panel it meets, from a bottom one directly above the highest, and a column to
the left takes it when the frame has no room left, never outside the frame."
  (let* ((base (or base-handler (etaf-posframe--poshandler at)))
         (place (cadr (split-string (symbol-name at) "-")))
         (down (not (and place (string-prefix-p "bottom" place)))))
    (lambda (info)
      (let* ((position (funcall base info))
             (x0 (car position))
             (y0 (cdr position))
             (self (plist-get info :posframe))
             (parent (or (plist-get info :parent-frame)
                         (and (frame-live-p self) (frame-parent self))))
             (bevel (etaf-posframe--terminal-bevel self))
             (width (+ (or (plist-get info :posframe-width) 0) bevel))
             (height (+ (or (plist-get info :posframe-height) 0) bevel))
             (frame-rect (etaf-posframe--rect info 'frame))
             (left (nth 0 frame-rect))
             (top (nth 1 frame-rect))
             (bottom (nth 3 frame-rect))
             (others
              (if (eq etaf-posframe--stack-obstacles :auto)
                  (delq nil
                        (mapcar (lambda (panel)
                                  (let ((frame (etaf-posframe--panel-frame panel)))
                                    (when (and (not (etaf-posframe--panel-modal-p panel))
                                               (not (eq frame self))
                                               (or (null parent)
                                                   (eq (etaf-posframe--panel-parent-frame panel)
                                                       parent)))
                                      (etaf-posframe--frame-rect frame))))
                                (etaf-posframe-panels)))
                etaf-posframe--stack-obstacles)))
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

;;; Unified child-frame backend for `etaf-pip'

(defun etaf-posframe--pip-paint-border (frame color)
  "Paint 1px child-frame hairline border on FRAME with COLOR."
  (when (and (frame-live-p frame) color)
    (let ((face (if (facep 'child-frame-border)
                    'child-frame-border
                  'internal-border)))
      (unless (equal color (face-attribute face :background frame))
        (set-face-background face color frame)))))

(defun etaf-posframe--pip-acquire-frame (parent geo bg fg)
  "Acquire a recycled graphical child frame for `etaf-pip' on PARENT.
Reuses `etaf-posframe--frame-pool' so floating panels, modals and PiP windows
share one macOS-safe graphical child-frame pool."
  (let* ((params `((parent-frame . ,parent)
                   (minibuffer . nil)
                   (undecorated . t)
                   (tab-bar-lines . 0)
                   (tool-bar-lines . 0)
                   (menu-bar-lines . 0)
                   (left-fringe . 0)
                   (right-fringe . 0)
                   (vertical-scroll-bars . nil)
                   (horizontal-scroll-bars . nil)
                   (border-width . 0)
                   (internal-border-width . 1)
                   (child-frame-border-width . 1)
                   (line-spacing . 0)
                   (drag-with-header-line . t)
                   (drag-internal-border . t)
                   (top-visible . 24)
                   (snap-width . 12)
                   (z-group . above)
                   (no-other-frame . t)
                   (no-accept-focus . nil)
                   (background-color . ,bg)
                   (foreground-color . ,fg)))
         (pooled (etaf-posframe--acquire-pooled-frame parent)))
    (if pooled
        (progn
          (modify-frame-parameters pooled params)
          (let ((frame-resize-pixelwise t))
            (set-frame-size pooled
                            (plist-get geo :frame-px-w)
                            (plist-get geo :frame-px-h) t))
          (set-frame-position pooled (plist-get geo :left) (plist-get geo :top))
          (unless (frame-visible-p pooled)
            (make-frame-visible pooled))
          pooled)
      (make-frame
       (append params
               `((width . (text-pixels . ,(plist-get geo :frame-px-w)))
                 (height . (text-pixels . ,(plist-get geo :frame-px-h)))
                 (left . ,(plist-get geo :left))
                 (top . ,(plist-get geo :top))))))))

(defun etaf-posframe--pip-park-frame (frame parent-frame _restore-focus)
  "Park graphical PiP child FRAME into the shared `etaf-posframe' pool."
  (etaf-posframe--park-frame frame parent-frame))

(setq etaf-pip-frame-backend
      (list :acquire #'etaf-posframe--pip-acquire-frame
            :park #'etaf-posframe--pip-park-frame
            :paint-border #'etaf-posframe--pip-paint-border
            :focus #'etaf-posframe--restore-input-focus))


(provide 'etaf-posframe-pool)
;;; etaf-posframe-pool.el ends here
