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

(defconst etaf-ui--modal-backdrop-brightness 0.55
  "Brightness of the shared modal backdrop behind floating panels.
Below 1 dims whatever the application already painted, which stays visible
with its images and text; Ebox applies the filter to every covered cell.")

(defconst etaf-ui--modal-backdrop-start 0.82
  "Initial brightness of an animated modal backdrop before easing down.
Visibly dimmed on frame 0 so the backdrop and modal child frame arrive on the
same visual beat and smoothly ease to `etaf-ui--modal-backdrop-brightness'.")

(defconst etaf-ui--modal-backdrop-duration 0.12
  "Duration in seconds for the animated modal backdrop settle.")

(defvar etaf-ui-modal-host-function nil
  "Function projecting a centered modal dialog into a child frame, or nil.
Called with a spec plist (:key :parent-buffer :parent-window :panel :title
:width-px :height-rows :max-height-rows :help-p :theme :appearance :view
:on-close) when `etaf-ui-modal-use-child-frame' is non-nil on a graphical
display.  Must return a handle plist (:update FN :close FN :frame FRAME
:runtime-fn FN), or nil to keep rendering inside the parent buffer.
`etaf-posframe' installs its child-frame modal host here automatically when
loaded.")

(defvar etaf-ui-modal-use-child-frame nil
  "When non-nil, project centered modal dialogs into a child frame.
Default nil keeps centered dialogs rendered in-buffer via Ebox for instant
incremental updates and consistent cross-platform behavior on macOS, Windows
and Linux.  Set non-nil together with `etaf-ui-modal-host-function' (installed
automatically by `etaf-posframe') to opt into native child-frame modals on
graphical displays; batch and terminal displays always render in-buffer.")

(defvar-local etaf-ui--help-portal-buffer nil
  "Non-nil in a modal child-frame buffer currently presenting `etaf-key-help'.")

(defvar-local etaf-ui--surface-return-stack nil
  "Saved return routes for open surfaces, newest first; not current focus.")

(defvar etaf-ui--open-surfaces nil
  "Mounted floating panels as (RUNTIME PANEL . CLOSE-FN) entries, newest first.")

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
      (let ((owner (car entry))
            (panel (cadr entry))
            (close-fn (cddr entry)))
        (when (and (eq owner runtime)
                   (memq entry etaf-ui--open-surfaces)
                   (not (and panel (ignore-errors (etaf-event-target-within-p panel)))))
          (condition-case nil
              (progn
                (if (functionp close-fn)
                    (funcall close-fn)
                  (etaf-dispatch-event runtime panel 'dismiss))
                (cl-incf dismissed))
            ;; A surface without `:on-close' or one already removed by an
            ;; earlier dismissal has nothing left to request.
            (etaf-event-error nil)))))
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

(etaf-define-component etaf-ui--modal-portal-root (&key state theme-ref appearance-ref)
  "Root Component mounted inside a modal child frame.
Bridges THEME-REF and APPEARANCE-REF from the parent Runtime and re-renders
smoothly in place whenever STATE updates, without creating a double border
around the frame."
  :setup
  (progn
    (etaf-theme-provide theme-ref)
    (when appearance-ref
      (etaf-appearance-provide appearance-ref))
    (when (plist-get (etaf-value state) :help-p)
      (when-let* ((rt (etaf-current-runtime)))
        (with-current-buffer (etaf-runtime-buffer rt)
          (setq-local etaf-ui--help-portal-buffer t)))))
  :render
  (let* ((spec (etaf-value state))
         (panel (plist-get spec :panel))
         (title (plist-get spec :title))
         (compact (plist-get spec :compact))
         (on-close (plist-get spec :on-close))
         (keys (plist-get spec :keys))
         (on-direction (plist-get spec :on-direction))
         (height-rows (plist-get spec :height-rows))
         (max-height-rows (plist-get spec :max-height-rows))
         (body (plist-get spec :body))
         (footer (plist-get spec :footer))
         (theme (etaf-ui--style-tokens :ui-panel-fg :ui-panel-bg :ui-panel-border)))
    (etaf-node
     'column
     (list :ref panel :class "etaf-floating-panel etaf-modal-portal-panel"
           :role 'dialog :tab-index -1
           :aria-label title :keymap nil :on-dismiss on-close
           :keys keys :on-direction on-direction :focus-scope 'modal
           :width 'stretch
           :height (when height-rows (list 'lh height-rows))
           :max-height (cond (height-rows (list 'lh height-rows))
                             (max-height-rows (list 'lh max-height-rows)))
           :item-gap '(lh 0)
           :padding '((lh 0) (ch 0))
           :color (plist-get theme :ui-panel-fg)
           :background-color (plist-get theme :ui-panel-bg)
           :overflow (when (or height-rows max-height-rows) 'scroll))
     (etaf-ui--surface-card-children
      title on-close compact t body footer))))

(etaf-define-component etaf-ui--modal-backdrop (&key ref level use-portal on-close)
  "Leaf backdrop scrim isolated so animation ticks never re-render the dialog."
  :render
  (let ((brightness
         (if level
             (max etaf-ui--modal-backdrop-brightness
                  (min 1.0
                       (etaf-animation-quantize (etaf-value level) 0.02)))
           etaf-ui--modal-backdrop-brightness)))
    (etaf-node 'box
               (list :ref ref
                     :position 'absolute :layer 'root
                     :left '(px 0) :top '(lh 0)
                     :width '(% 100) :height '(% 100)
                     :z-index 1001
                     :class "etaf-modal-backdrop"
                     :backdrop-filter (list 'brightness brightness)
                     :role 'presentation :keymap nil :tab-index -1
                     :focus-scope (when use-portal 'modal)
                     :on-dismiss (when use-portal on-close)
                     :on-press (lambda ()
                                 (when (etaf-event-pointer-p)
                                   (funcall on-close))))
               nil)))

(defun etaf-ui--modal-portal-view (state theme-ref appearance-ref)
  "Return a zero-argument View builder for a child-frame modal portal."
  (lambda ()
    (etaf-node 'etaf-ui--modal-portal-root
               (list :state state
                     :theme-ref theme-ref
                     :appearance-ref appearance-ref)
               nil)))

(defun etaf-ui--buffer-has-raster-images-p (buffer)
  "Return non-nil when BUFFER currently paints non-SVG raster images.
Dimming each raster thumbnail through an intermediate brightness step forces
Emacs's SVG filter pipeline to re-rasterize every image on each animation
frame; skipping intermediate steps lets image-heavy pages dim in one cached
pass on the same visual beat as the modal."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((pos (point-min))
            (end (point-max))
            (found nil))
        (while (and (not found) (< pos end))
          (let ((disp (get-text-property pos 'display)))
            (when disp
              (let ((img (cond ((eq (car-safe disp) 'image) disp)
                               ((consp (car-safe disp)) (assq 'image disp)))))
                (when (and img
                           (not (eq (plist-get (cdr img) :type) 'svg)))
                  (setq found t)))))
          (setq pos (next-single-property-change pos 'display nil end)))
        found))))

(defun etaf-ui--current-theme-plist ()
  "Return the currently injected Theme plist, or nil when none is provided."
  (let ((raw (etaf-ui--reactive-value (etaf-inject 'theme))))
    (when (and (proper-list-p raw) (zerop (% (length raw) 2)))
      raw)))

(defun etaf-ui--resolve-theme-token (palette value)
  "Resolve deferred Theme token VALUE against PALETTE, or return VALUE."
  (if (etaf-theme-token-p value)
      (let* ((key (nth 1 value))
             (default (nth 2 value))
             (transform (nth 3 value))
             (raw (if (plist-member palette key) (plist-get palette key) default))
             (resolved (etaf-ui--resolve-theme-token palette raw)))
        (if transform (funcall transform resolved) resolved))
    value))

(defun etaf-ui--modal-border-color (palette panel-bg accent fallback)
  "Return an elevated accent-tinted hairline border color for a centered modal.
Matches the focused panel border contrast across dark and light palettes so an
in-buffer dialog stands out cleanly against its dimmed backdrop."
  (let* ((bg (etaf-ui--color-hex (etaf-ui--resolve-theme-token palette panel-bg)))
         (ac (etaf-ui--color-hex (etaf-ui--resolve-theme-token palette accent))))
    (if (and bg ac)
        (let* ((lum (or (etaf-ui--color-luminance bg) 0.0))
               (strength (if (>= lum 0.5) 0.58 0.52)))
          (etaf-ui-color-mix bg ac strength))
      fallback)))

(defun etaf-ui--window-visible-top-line (buffer)
  "Return the 0-based buffer line shown at the top of BUFFER's window."
  (let ((win (and (buffer-live-p buffer)
                  (or (and (eq (window-buffer (selected-window)) buffer)
                           (selected-window))
                      (get-buffer-window buffer t)))))
    (if (and (window-live-p win) (> (window-start win) (point-min)))
        (with-current-buffer buffer
          (max 0 (1- (line-number-at-pos (window-start win)))))
      0)))

(defun etaf-ui--modal-host-fn ()
  "Return the active modal child-frame host function, or nil."
  (or (and (functionp etaf-ui-modal-host-function)
           etaf-ui-modal-host-function)
      (and (fboundp 'etaf-portal-host)
           (etaf-portal-host 'child-frame))))

(defun etaf-ui--portal-eligible-p (modal center anchor side)
  "Return non-nil when a surface may project into a modal child frame."
  (and modal center (not anchor) (not side)
       etaf-ui-modal-use-child-frame
       (functionp (etaf-ui--modal-host-fn))
       (not noninteractive)
       (display-graphic-p)))

(etaf-define-component etaf-ui--open-surface
    (&key anchor (placement 'bottom-start) side (width '(ch 32)) height
          title on-close modal center compact (backdrop t) keys on-direction
          animated)
  "Render one open floating surface and own its keyboard attachment."
  :bindings
  ((panel (etaf-local-ref 'panel))
   (backdrop-ref (etaf-local-ref 'backdrop))
   (buffer (if-let* ((runtime (etaf-current-runtime)))
               (etaf-runtime-buffer runtime)
             (current-buffer)))
   (return-focus
    (delete-dups
     (delq nil (cons (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                       (etaf-focused-host-ref runtime))
                     (copy-sequence (cdar etaf-ui--surface-return-stack))))))
   (use-anim (and animated modal backdrop etaf-animation-enabled
                  (not (etaf-ui--buffer-has-raster-images-p buffer))))
   (backdrop-target (when use-anim (etaf-ref etaf-ui--modal-backdrop-start)))
   (backdrop-level (when backdrop-target
                     (etaf-transition backdrop-target
                                      :duration etaf-ui--modal-backdrop-duration
                                      :easing 'ease-out
                                      :name 'etaf-modal-backdrop)))
   (portal-state (etaf-ref nil :name 'etaf-modal-portal-state))
   (portal-theme (etaf-ref nil :name 'etaf-modal-portal-theme))
   (portal-appearance (etaf-ref 'light :name 'etaf-modal-portal-appearance))
   (help-modal-p (etaf-inject 'etaf-ui--help-modal nil))
   (portal-spec-box (list nil)))
  :setup
  (let ((portal-handle nil)
        (portal-opening nil)
        (portal-dirty nil)
        (last-synced-spec nil)
        (portal-retry-timer nil)
        (portal-retries 0)
        (anim-started nil)
        (mounted-p nil)
        (cleanup nil)
        (registration nil))
    (letrec
        ((start-backdrop-anim
          (lambda ()
            (when (and backdrop-target (not anim-started))
              (setq anim-started t)
              (setf (etaf-value backdrop-target)
                    etaf-ui--modal-backdrop-brightness))))
         (sync-portal
          (lambda ()
            (let ((latest-spec (car portal-spec-box)))
              (when (and mounted-p latest-spec (plist-get latest-spec :use-portal))
                (if portal-opening
                    (setq portal-dirty t)
                  (unless (and portal-handle (equal latest-spec last-synced-spec))
                    (let ((theme-plist (plist-get latest-spec :theme))
                          (app-mode (plist-get latest-spec :appearance)))
                      (unless (equal theme-plist (etaf-value portal-theme))
                        (setf (etaf-value portal-theme) theme-plist))
                      (when (and (memq app-mode '(light dark))
                                 (not (eq app-mode (etaf-value portal-appearance))))
                        (setf (etaf-value portal-appearance) app-mode)))
                    (setf (etaf-value portal-state) latest-spec)
                    (setq last-synced-spec latest-spec)
                    (if (and portal-handle
                             (let ((rt-fn (plist-get portal-handle :runtime-fn)))
                               (or (not (functionp rt-fn))
                                   (funcall rt-fn))))
                        (when-let* ((update (plist-get portal-handle :update)))
                          (ignore-errors (funcall update latest-spec)))
                      (setq portal-handle nil)
                      (let ((win (and (buffer-live-p buffer)
                                      (get-buffer-window buffer t))))
                        (if (window-live-p win)
                            (when-let* ((host-fn (etaf-ui--modal-host-fn)))
                              (setq portal-retries 0
                                    portal-opening t
                                    portal-dirty nil)
                              (unwind-protect
                                  (let* ((view-fn (etaf-ui--modal-portal-view
                                                   portal-state portal-theme portal-appearance))
                                         (handle
                                          (funcall
                                           host-fn
                                           (list :key (cons buffer panel)
                                                 :parent-buffer buffer
                                                 :parent-window win
                                                 :panel panel
                                                 :title (plist-get latest-spec :title)
                                                 :width-px (plist-get latest-spec :width-px)
                                                 :height-rows (plist-get latest-spec :height-rows)
                                                 :max-height-rows (plist-get latest-spec :max-height-rows)
                                                 :help-p help-modal-p
                                                 :theme portal-theme
                                                 :appearance portal-appearance
                                                 :view view-fn
                                                 :on-close (plist-get latest-spec :on-close)))))
                                    (when handle
                                      (if mounted-p
                                          (progn
                                            (setq portal-handle handle)
                                            ;; Launch backdrop dimming and child-frame
                                            ;; alpha fade-in on the exact same tick!
                                            (funcall start-backdrop-anim))
                                        (when-let* ((close-fn (plist-get handle :close)))
                                          (ignore-errors (funcall close-fn))))))
                                (setq portal-opening nil))
                              (when (and portal-dirty mounted-p portal-handle)
                                (setq portal-dirty nil)
                                (funcall sync-portal)))
                          ;; Parent buffer is not displayed in a window yet (for example
                          ;; while `etaf-posframe-show' is creating the app's own frame);
                          ;; retry briefly on the next turn.
                          (when (and (< portal-retries 3)
                                     (not (timerp portal-retry-timer)))
                            (cl-incf portal-retries)
                            (setq portal-retry-timer
                                  (run-at-time
                                   (if (= portal-retries 1) 0 0.05) nil
                                   (lambda ()
                                     (setq portal-retry-timer nil)
                                     (funcall sync-portal)))))))))))))))
      (etaf-on-mounted
       (lambda ()
         (setq mounted-p t)
         (setq cleanup (etaf-ui--surface-return buffer return-focus))
         (let ((runtime (or (etaf-current-runtime)
                            (etaf-runtime-for-buffer buffer)))
               (latest-spec (car portal-spec-box)))
           (when runtime
             (setq registration
                   (cons runtime
                         (cons panel
                               (when (and latest-spec (plist-get latest-spec :use-portal))
                                 (lambda ()
                                   (when-let* ((spec (car portal-spec-box))
                                               (fn (plist-get spec :on-close)))
                                     (funcall fn)))))))
             (push registration etaf-ui--open-surfaces))
           (if (and latest-spec (plist-get latest-spec :use-portal))
               (progn
                 ;; Enter the parent backdrop's modal scope so underlying app keys
                 ;; stay blocked even if frame focus returns before dismissal.
                 (when (and runtime
                            (ignore-errors (etaf-host-ref-position runtime backdrop-ref)))
                   (ignore-errors (etaf-focus runtime backdrop-ref)))
                 ;; Run portal mounting on `etaf-next-tick' so it executes cleanly
                 ;; outside the parent Runtime's active drain (allowing nested
                 ;; `etaf-mount' to commit its own child `etaf-on-mounted' hooks).
                 (etaf-next-tick sync-portal))
             ;; In-buffer surface: start backdrop fade immediately and focus panel.
             (funcall start-backdrop-anim)
             (when (and runtime
                        (ignore-errors (etaf-host-ref-position runtime panel)))
               (ignore-errors (etaf-focus-within runtime panel)))))))
      (etaf-on-updated
       (lambda ()
         (let ((latest-spec (car portal-spec-box)))
           (when (and latest-spec (plist-get latest-spec :use-portal))
             (etaf-next-tick sync-portal)))))
      (etaf-on-unmounted
       (lambda ()
         (setq mounted-p nil)
         (when (timerp portal-retry-timer)
           (cancel-timer portal-retry-timer)
           (setq portal-retry-timer nil))
         (when portal-handle
           (let ((close-fn (plist-get portal-handle :close)))
             (setq portal-handle nil)
             (when (functionp close-fn)
               (ignore-errors (funcall close-fn)))))
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
                   (etaf-event-error nil))))))))))
  :render
  (let* ((theme (etaf-ui--style-tokens :ui-panel-fg :ui-panel-bg :ui-panel-border :ui-accent))
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
         (max-height-rows
          (when (and modal viewport-height-known (not bounded-height-rows))
            (max 6 (floor (* viewport-height 0.82)))))
         (use-portal (etaf-ui--portal-eligible-p modal center anchor side))
         (body-slot (etaf-current-slot 'default))
         (footer-slot (etaf-current-slot 'footer))
         (backdrop-node
          (when (and modal backdrop)
            (etaf-node 'etaf-ui--modal-backdrop
                       (list :ref backdrop-ref
                             :level backdrop-level
                             :use-portal use-portal
                             :on-close on-close)
                       nil))))
    (if use-portal
        (let* ((inherited (etaf-ui--current-theme-plist))
               (portal-palette
                (append
                 inherited
                 (cl-loop for key in '(:ui-panel-bg :ui-panel-fg :ui-panel-border
                                       :ui-fg :ui-accent)
                          unless (plist-member inherited key)
                          append (list key (etaf-ui--resolve-theme-token
                                            inherited
                                            (etaf-ui--style-token key)))))))
          (setcar portal-spec-box
                  (list :use-portal t
                        :panel panel
                        :help-p help-modal-p
                        :title title
                        :compact compact
                        :width-px (or bounded-width-px requested-width-px (* 48 cell))
                        :height-rows bounded-height-rows
                        :max-height-rows max-height-rows
                        :on-close on-close
                        :keys keys
                        :on-direction on-direction
                        :body body-slot
                        :footer footer-slot
                        :appearance (etaf-appearance)
                        :theme portal-palette))
          (if backdrop-node
              (etaf-node 'fragment nil (list backdrop-node))
            (etaf-node 'fragment nil nil)))
      (setcar portal-spec-box nil)
      (let* ((visible-top (if center (etaf-ui--window-visible-top-line buffer) 0))
             (inherited (and modal center (etaf-ui--current-theme-plist)))
             (panel-border
              (if (and modal center)
                  (etaf-ui--modal-border-color
                   inherited
                   (plist-get theme :ui-panel-bg)
                   (plist-get theme :ui-accent)
                   (plist-get theme :ui-panel-border))
                (plist-get theme :ui-panel-border)))
             (content
              (etaf-node
               'column
               (list :ref panel :class "etaf-floating-panel"
                     :role (if modal 'dialog 'group) :tab-index -1
                     :aria-label title :keymap nil :on-dismiss on-close
                     :keys keys :on-direction on-direction :focus-scope 'modal
                     :position 'absolute :layer 'root
                     :z-index 1001
                     :anchor anchor
                     :placement (if (and center (not anchor) (not side))
                                    'center
                                  placement)
                     :left (cond (anchor '(px 0))
                                 ((eq side 'left) '(px 0))
                                 ((eq side 'right)
                                  (list 'calc (list '- '(% 100) width)))
                                 (t '(px 0)))
                     :top (cond (anchor '(lh 0))
                                ((memq side '(left right)) '(lh 0))
                                (center (list 'lh visible-top))
                                (t '(lh 2)))
                     :height (cond ((memq side '(left right)) '(% 100))
                                   (bounded-height-rows
                                    (list 'lh bounded-height-rows)))
                     :max-height (when modal
                                   (if bounded-height-rows
                                       (list 'lh bounded-height-rows)
                                     (when viewport-height-known
                                       (list 'lh (max 6 (floor (* viewport-height 0.88)))))))
                     :width (if bounded-width-px
                                (list 'px bounded-width-px)
                              width)
                     :item-gap '(lh 0)
                     :padding '((lh 0) (ch 0))
                     :color (plist-get theme :ui-panel-fg)
                     :background-color (plist-get theme :ui-panel-bg)
                     :overflow (when (and modal viewport-height-known) 'scroll)
                     :border (etaf-ui--style-border panel-border))
               (etaf-ui--surface-card-children
                title (and modal on-close) compact (or modal side)
                body-slot footer-slot))))
        (if backdrop-node
            (etaf-node 'fragment nil (list backdrop-node content))
          (if modal
              (etaf-node 'fragment nil (list content))
            content))))))

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
          (close-label "Close") on-close (backdrop t) keys on-direction
          (animated t))
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
                     :on-close on-close :keys keys :on-direction on-direction
                     :animated animated)
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
