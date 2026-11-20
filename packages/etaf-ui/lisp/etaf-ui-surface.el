;;; etaf-ui-surface.el --- Composable retained floating panels -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Ebox owns placement, occlusion and focus. These Components own the panel
;; presentation and dismissal policy; each panel is an ETAF modal focus scope,
;; so Tab, arrows and Escape stay inside it while it is open.  A modal's
;; backdrop keeps the application underneath painted and dims it through
;; Ebox's backdrop filter instead of covering it with an opaque color.

;;; Code:
(require 'etaf-ui-input)
(require 'etaf-ui-feedback)
(require 'etaf-ui-icon)
(require 'ebox)

(defconst etaf-ui--modal-backdrop-brightness 0.55
  "Brightness of the shared modal backdrop behind floating panels.
Below 1 dims whatever the application already painted, which stays visible
with its images and text; Ebox applies the filter to every covered cell.")

(defvar-local etaf-ui--surface-return-stack nil
  "Saved return routes for open surfaces, newest first; not current focus.")

(defvar etaf-ui--open-surfaces nil
  "Mounted floating panels as (RUNTIME . PANEL) entries, newest first.")

;;;###autoload
(defun etaf-ui-dismiss-outside-press ()
  "Dismiss every mounted floating surface the current press did not land in.
Call from the `:on-press' or `:on-press-capture' callback of a Host enclosing
the application, such as a shell root.  Each dialog, launcher, switcher,
popover, menu or drawer mounted in the event's Runtime whose panel does not
contain the pressed Host receives its dismissal, which requests its
`:on-close'.  A surface opened by the press being handled is not mounted yet
and stays open.  Return the number of surfaces dismissed.  Outside an event
callback signal `etaf-event-error'."
  (let ((runtime (etaf-current-runtime))
        (dismissed 0))
    (unless runtime
      (signal 'etaf-event-error
              (list "Dismissing surfaces requires a Host event callback")))
    (dolist (entry (copy-sequence etaf-ui--open-surfaces))
      (when (and (eq (car entry) runtime)
                 (memq entry etaf-ui--open-surfaces)
                 (not (etaf-event-target-within-p (cdr entry))))
        (condition-case nil
            (progn
              (etaf-dispatch-event runtime (cdr entry) 'dismiss)
              (cl-incf dismissed))
          ;; A surface without `:on-close' or one already removed by an
          ;; earlier dismissal has nothing left to request.
          (etaf-event-error nil))))
    dismissed))

(defun etaf-ui--surface-return (buffer return-targets)
  "Record RETURN-TARGETS of a surface opened in BUFFER; return its cleanup.
A surface opened from another one hands focus back along this stack."
  (let ((route (cons 'surface return-targets)))
    (with-current-buffer buffer
      (push route etaf-ui--surface-return-stack))
    (lambda ()
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq etaf-ui--surface-return-stack
                (delq route etaf-ui--surface-return-stack)))))))

(defun etaf-ui--surface-card-children (title close compact spacious body footer)
  "Return the header, body and footer nodes of one floating card.

Every surface shares this anatomy: a one-row header carrying TITLE under a
hairline, a BODY column padded by one row and two columns, and a right-aligned
FOOTER row.  CLOSE, when a function, adds a pointer-only ghost x to the header
so keyboard focus still lands on the first body control.  COMPACT
removes the body's vertical air; SPACIOUS separates body items by one row."
  (let ((theme (etaf-ui--style-tokens :ui-panel-border :ui-panel-fg :ui-muted-fg)))
    (append
     (when title
       (list
        (etaf-node
         'flex
         (list :class "etaf-surface-header"
               :width 'stretch :flex-direction 'row
               :justify-content 'space-between :align-items 'center
               :padding '((lh 0) (ch 2))
               :border-bottom (etaf-ui--style-border
                               (plist-get theme :ui-panel-border)))
         (append
          (list (etaf-node 'etaf-label
                           (list :text title :variant 'strong
                                 :color (plist-get theme :ui-panel-fg)) nil))
          (when close
            (list (etaf-node 'etaf-button
                             (list :label "x" :variant 'ghost
                                   :aria-label "Dismiss" :help-echo "Dismiss"
                                   :tab-index -1
                                   :color (plist-get theme :ui-muted-fg)
                                   :on-press close)
                             nil)))))))
     (list
      (etaf-node 'column
                 (list :class "etaf-surface-body"
                       :padding (if compact '((lh 0) (ch 2)) '((lh 1) (ch 2)))
                       :item-gap (if (and spacious (not compact))
                                     '(lh 1)
                                   '(lh 0)))
                 body))
     (when footer
       (list
        (etaf-node 'flex
                   (list :class "etaf-surface-footer"
                         :width 'stretch :flex-direction 'row
                         :justify-content 'flex-end :align-items 'center
                         :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 2)))
                   footer)
        (etaf-node 'box (list :class "etaf-surface-footer-air"
                              :height '(lh 1))
                   nil))))))

(etaf-define-component etaf-ui--open-surface
    (&key anchor (placement 'bottom-start) side (width '(ch 32)) height
          title on-close modal center compact (backdrop t) keys on-direction)
  "Render one open floating surface and own its keyboard attachment."
  :bindings
  ((panel (etaf-local-ref 'panel))
   (buffer (if-let* ((runtime (etaf-current-runtime)))
               (etaf-runtime-buffer runtime)
             (current-buffer)))
   (return-focus
    (delete-dups
     (delq nil (cons (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                       (etaf-focused-host-ref runtime))
                     (copy-sequence (cdar etaf-ui--surface-return-stack))))))
   (cleanup nil)
   (registration nil))
  :setup
  (progn
    (etaf-on-mounted
     (lambda ()
       (setq cleanup (etaf-ui--surface-return buffer return-focus))
       (let ((runtime (or (etaf-current-runtime)
                          (etaf-runtime-for-buffer buffer))))
         (when runtime
           (setq registration (cons runtime panel))
           (push registration etaf-ui--open-surfaces))
         ;; A surface closed before its mount hook settles leaves PANEL
         ;; unresolved; an unknown position is simply nothing to focus.
           (when (and runtime
                      (ignore-errors (etaf-host-ref-position runtime panel)))
           ;; A surface without a focusable child does not need a second
           ;; publication just to focus its -1 panel root; its modal scope
           ;; still routes Escape and keys to the panel.
           (ignore-errors (etaf-focus-within runtime panel))))))
    (etaf-on-unmounted
     (lambda ()
       (when cleanup (funcall cleanup))
       (when registration
         (setq etaf-ui--open-surfaces (delq registration etaf-ui--open-surfaces)
               registration nil))
       (when-let* ((runtime (etaf-runtime-for-buffer buffer))
                   ((etaf-runtime-mounted-p runtime)))
         (catch 'restored
           (dolist (target return-focus)
             (when (etaf-host-ref-position runtime target)
               (condition-case nil
                   (progn (etaf-focus runtime target) (throw 'restored t))
                 (etaf-event-error nil)))))))))
  :render
  (let* ((theme (etaf-ui--style-tokens :ui-panel-fg :ui-panel-bg :ui-panel-border))
         (runtime (etaf-current-runtime))
         ;; `ch' widths and the centring margins are page pixels, so they are
         ;; stated in the cell the canvas draws with.
         (cell (max 1 (car (etaf-ui--canvas-cell))))
         (window-viewport
          (and runtime (etaf-runtime-window-viewport runtime)))
         (canvas-viewport (and runtime (etaf-runtime-viewport runtime)))
         (viewport-width (or (car window-viewport) (car canvas-viewport)))
         (viewport-height (or (cdr window-viewport) (cdr canvas-viewport)))
         (viewport-height-known
          (and (numberp viewport-height) (> viewport-height 0)))
         (viewport-width-known
          (and (numberp viewport-width) (> viewport-width 0)))
         (requested-width-px
          (pcase width
            (`(ch ,(and n (pred numberp)))
             (* cell n))
            (`(px ,(and n (pred numberp))) n)))
         (bounded-width-px
          (when (and center viewport-width-known requested-width-px)
            (min requested-width-px
                 (max 1 (- viewport-width (* 2 cell))))))
         (requested-height-rows
          (pcase height (`(lh ,(and n (pred integerp))) n)))
         (bounded-height-rows
          (when requested-height-rows
            (if viewport-height-known
                (min requested-height-rows (max 1 (- viewport-height 4)))
              requested-height-rows)))
         (center-left
          (when bounded-width-px
            (list 'px
                  (max 0 (floor (/ (- viewport-width bounded-width-px) 2))))))
         ;; Without a known height the panel sizes to its content, so a
         ;; modest offset keeps a short dialog in the upper third rather than
         ;; guessing a center for an unknown extent.
         (center-top
          (when (and center viewport-height-known)
            (list 'lh
                  (if bounded-height-rows
                      (max 0 (floor (/ (- viewport-height bounded-height-rows)
                                       2)))
                    (max 1 (floor (/ viewport-height 5)))))))
         (content
          (etaf-node
           'column
           (list :ref panel :class "etaf-floating-panel"
                 :role (if modal 'dialog 'group) :tab-index -1
                 :aria-label title :keymap nil :on-dismiss on-close
                 :keys keys :on-direction on-direction :focus-scope 'modal
                 :position 'absolute :layer 'root :z-index 1001
                 :anchor anchor :placement placement
                 :left (cond (anchor '(px 0))
                             ((eq side 'left) '(px 0))
                             ((eq side 'right)
                             (list 'calc (list '- '(% 100) width)))
                             (center-left center-left)
                             (t '(px 0)))
                 :top (cond (anchor '(lh 0))
                            ((memq side '(left right)) '(lh 0))
                            (center-top center-top)
                            (t '(lh 2)))
                 :height (cond ((memq side '(left right)) '(% 100))
                               (bounded-height-rows
                                (list 'lh bounded-height-rows)))
                 :max-height (when modal
                               (if bounded-height-rows
                                   (list 'lh bounded-height-rows)
                                 (when viewport-height-known '(% 80))))
                 :width (if bounded-width-px
                            (list 'px bounded-width-px)
                          width)
                 :item-gap '(lh 0)
                 :padding '((lh 0) (ch 0))
                 :color (plist-get theme :ui-panel-fg)
                 :background-color (plist-get theme :ui-panel-bg)
                 :overflow (when (and modal viewport-height-known) 'scroll)
                 :border (etaf-ui--style-border (plist-get theme :ui-panel-border)))
           (etaf-ui--surface-card-children
            title (and modal on-close) compact (or modal side)
            (etaf-current-slot 'default) (etaf-current-slot 'footer)))))
    (if (and modal backdrop)
        (etaf-node 'fragment nil
                   (list
                    (etaf-node 'box
                               (list :position 'absolute :layer 'root
                                     :left '(px 0) :top '(lh 0)
                                     :width '(% 100) :height '(% 100)
                                     :z-index 1001
                                     :class "etaf-modal-backdrop"
                                     :backdrop-filter
                                     (list 'brightness
                                           etaf-ui--modal-backdrop-brightness)
                                     :role 'presentation :keymap nil :tab-index -1
                                     :on-press (lambda ()
                                                 (when (etaf-event-pointer-p)
                                                   (funcall on-close))))
                               nil)
                    content))
      ;; A Desktop may request an unpainted modal while retaining its
      ;; application surface underneath.  The panel's modal focus scope
      ;; still owns keyboard dismissal and navigation.
      (if modal
          (etaf-node 'fragment nil (list content))
        content))))

(etaf-define-component etaf-popover
    (&key open anchor (placement 'bottom-start) (width '(ch 32)) title on-close)
  "Show controlled OPEN content anchored to a semantic ID."
  :validate
  (progn
    (etaf-check-prop :on-close on-close (functionp on-close) "a function")
    (etaf-check-prop :anchor anchor
                     (and anchor (or (symbolp anchor)
                                     (and (stringp anchor) (not (string-empty-p anchor)))))
                     "a nonempty semantic ID")
    (etaf-check-prop :title title (or (null title) (stringp title)) "a string or nil"))
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-ui--open-surface
               (list :anchor anchor :placement placement :width width :title title :on-close on-close)
               (etaf-current-slot 'default)
               (list (cons 'footer (etaf-current-slot 'footer))))))

(etaf-define-component etaf-dialog
    (&key open (title "Dialog") (width '(ch 48)) height compact
          (close-label "Close") on-close (backdrop t) keys on-direction)
  "Show a controlled modal panel with default content and a footer slot.
A pointer press on the backdrop requests ON-CLOSE without activating the
background; presses inside the panel do not close it.  When BACKDROP is nil,
retain the underlying surface's paint while keeping the panel as a root-layer
projection; the caller owns any outside-click policy.
HEIGHT optionally fixes the panel to text rows, bounded by the visible window;
COMPACT removes the body's vertical air.  CLOSE-LABEL nil omits the default
footer button so the footer slot owns every action; Escape and the header x
still request ON-CLOSE.  KEYS and ON-DIRECTION declare the panel's scoped
keyboard commands and direction handler, not the backdrop's."
  :validate
  (progn
    (etaf-check-prop :on-close on-close (functionp on-close) "a function")
    (etaf-check-prop :title title (stringp title) "a string")
    (etaf-check-prop :height height
                     (or (null height)
                         (and (proper-list-p height)
                              (= (length height) 2)
                              (eq (car height) 'lh)
                              (integerp (cadr height))
                              (> (cadr height) 0)))
                     "nil or (lh POSITIVE-INTEGER)" 'etaf-dialog)
    (etaf-check-prop :compact compact (booleanp compact) "a boolean" 'etaf-dialog)
    (etaf-check-prop :close-label close-label
                     (or (null close-label) (stringp close-label))
                     "a string or nil"))
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-ui--open-surface
               (list :modal t :center t :backdrop backdrop :title title
                     :width width :height height :compact compact
                     :on-close on-close :keys keys :on-direction on-direction)
               (etaf-current-slot 'default)
               (list (cons 'footer
                           (append (etaf-current-slot 'footer)
                                   (when close-label
                                     (list (etaf-node 'etaf-button
                                                      (list :label close-label :variant 'secondary :on-press on-close)
                                                      nil)))))))))

(etaf-define-component etaf-tooltip
    (&key open anchor text (placement 'top-start) on-close)
  "Show short controlled TEXT near ANCHOR.
Tooltip visibility is controlled by OPEN; applications may toggle it from a
button or another host event. It does not invent a second hover event system."
  :validate
  (progn
    (etaf-check-prop :text text (stringp (etaf-ui--reactive-value text))
                     "a string or reactive string" 'etaf-tooltip)
    (etaf-check-prop :on-close on-close (functionp on-close)
                     "a function" 'etaf-tooltip))
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-popover
               (list :open t :anchor anchor :placement placement :width '(ch 32)
                     :on-close on-close)
               (list (etaf-node 'etaf-label
                                (list :text text :variant 'default) nil)))))

(etaf-define-component etaf-toast
    (&key open anchor message (title "Notification") (variant 'info) on-close)
  "Show controlled MESSAGE as a dismissible anchored notification.
The caller owns OPEN and chooses when the toast is removed; VARIANT controls
the message's semantic color. Anchored placement follows Popover."
  :validate
  (progn
    (etaf-check-prop :message message (stringp (etaf-ui--reactive-value message))
                     "a string or reactive string" 'etaf-toast)
    (etaf-check-prop :title title (stringp title) "a string" 'etaf-toast)
    (etaf-check-prop :on-close on-close (functionp on-close)
                     "a function" 'etaf-toast))
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-popover
               (list :open t :anchor anchor :placement 'top-end :width '(ch 42)
                     :title title :on-close on-close)
               (list (etaf-node 'column nil
                                (list (etaf-node 'etaf-badge
                                                 (list :text (capitalize (symbol-name variant))
                                                       :variant variant) nil)
                                      (etaf-node 'etaf-label
                                                 (list :text message) nil)))))))

(defun etaf-ui--menu-entry (item iconic close on-select)
  "Return the popover row selecting ITEM after CLOSE runs.
ICONIC rows reserve an icon cell so labels align when ITEM has no :icon."
  (let* ((key (plist-get item :key))
         (disabled (plist-get item :disabled))
         (press (lambda () (funcall close) (funcall on-select key))))
    (if (not iconic)
        (etaf-node 'etaf-button
                   (list :key key :label (plist-get item :label)
                         :variant 'ghost :disabled disabled :on-press press)
                   nil)
      (etaf-node
       'flex
       (list :key key :flex-direction 'row :align-items 'center :width 'stretch
             :column-gap '(ch 2) :padding-inline '(ch 1)
             :role 'menuitem :aria-label (plist-get item :label)
             :disabled disabled :tab-index (unless disabled 0)
             :color (etaf-ui--style-token (if disabled :ui-muted-fg :ui-fg))
             :hover-style (unless disabled
                            (list :background-color
                                  ;; The application's accent tint wins; a
                                  ;; Theme without one hovers with its own
                                  ;; shifted surface instead of a fixed
                                  ;; light tint.
                                  (etaf-theme-token
                                   :ui-accent-soft-bg
                                   (etaf-theme-token :ui-bg "#FFFDF8"
                                                     'etaf-ui--state-hover-shift))))
             :pointer (unless disabled 'hand)
             :on-press (unless disabled press))
       (list (if-let* ((icon (plist-get item :icon)))
                 (etaf-ui-icon icon :min-width 2)
               (etaf-node 'box (list :width '(ch 2)) (list "")))
             (etaf-node 'text nil (list (plist-get item :label))))))))

(etaf-define-component etaf-dropdown-menu
    (&key (label "Actions") items on-select disabled (width '(ch 28)) icon
          (placement 'bottom-start))
  "Open an anchored menu of ITEMS and pass the selected key to ON-SELECT.
ICON makes the trigger that icon, with LABEL as its help and accessible name.
Items may carry an :icon shown before the label.  PLACEMENT follows
`etaf-popover'."
  :bindings ((open (etaf-ref nil))
             (anchor (symbol-name (gensym "etaf-menu-"))))
  :render
  (progn
    (etaf-ui--check-menu-items items 'etaf-dropdown-menu)
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-dropdown-menu)
    (etaf-check-prop :on-select on-select (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-dropdown-menu)
    (let* ((enabled (and (not disabled) on-select
                         (cl-some (lambda (item) (not (plist-get item :disabled))) items)))
           (toggle (lambda () (setf (etaf-value open) (not (etaf-value open)))))
           (close (lambda () (setf (etaf-value open) nil)))
           (iconic (cl-some (lambda (item) (plist-get item :icon)) items)))
      (etaf-node 'fragment nil (list
       (if icon
           (etaf-ui-icon icon :id anchor :help-echo label
                         :on-press (and enabled toggle))
         (etaf-node 'etaf-button
                    (list :id anchor :label (etaf-ui--disclosure-label label 'chevron-down)
                          :aria-label label
                          :disabled (not enabled) :variant 'secondary
                          :on-press toggle)
                    nil))
       (etaf-node
        'etaf-popover
        (list :open (and enabled (etaf-value open)) :anchor anchor :width width
              :placement placement :on-close close)
        (mapcar (lambda (item) (etaf-ui--menu-entry item iconic close on-select))
                items)))))))

(etaf-define-component etaf-context-menu
    (&key (label "More") items on-select disabled (width '(ch 30)))
  "Render a compact context action surface from ITEMS.
The trigger is an ordinary Ebox Button so keyboard, mouse and focus behavior
remain shared with DropdownMenu; applications may place it beside any target."
  :render
  (etaf-node 'etaf-dropdown-menu
             (list :label label :items items :on-select on-select
                   :disabled disabled :width width)
             nil))

(etaf-define-component etaf-drawer
    (&key open (title "Drawer") (placement 'right) (width '(ch 42))
          (modal t) on-close)
  "Show a controlled side DRAWER with default content.
PLACEMENT is `left' or `right'.  ON-CLOSE is required; OPEN and form data
remain caller-owned."
  :validate
  (progn
    (etaf-check-prop :placement placement (memq placement '(left right))
                     "left or right" 'etaf-drawer)
    (etaf-check-prop :modal modal (booleanp modal) "a boolean" 'etaf-drawer)
    (etaf-check-prop :title title (or (null title) (stringp title))
                     "a string or nil" 'etaf-drawer)
    (etaf-check-prop :on-close on-close (functionp on-close)
                     "a function" 'etaf-drawer))
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-ui--open-surface
               (list :modal modal :placement 'top-start :side placement
                     :width (list 'min width '(% 100))
                     :title title :on-close on-close)
               (etaf-current-slot 'default)
               (list (cons 'footer (etaf-current-slot 'footer))))))

(provide 'etaf-ui-surface)
;;; etaf-ui-surface.el ends here
