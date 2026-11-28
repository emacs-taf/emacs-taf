;;; etaf-desktop-runtime.el --- Desktop application state and view -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-desktop-theme)

(declare-function etaf-desktop-apps "etaf-desktop-apps" ())
(declare-function etaf-desktop-instances "etaf-desktop-apps" (desktop))
(declare-function etaf-desktop-launch "etaf-desktop-apps"
                  (desktop app-id &rest options))
(declare-function etaf-desktop-layout-mode "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop--layout-ensure-workspace "etaf-desktop-layout"
                  (desktop workspace))
(declare-function etaf-desktop--layout-workspace-mode "etaf-desktop-layout" (workspace))
(declare-function etaf-desktop-set-layout-mode "etaf-desktop-layout"
                  (desktop mode &optional workspace))
(declare-function etaf-desktop-layout-tree "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop--layout-swap-windows "etaf-desktop-layout"
                  (desktop first second))
(declare-function etaf-desktop-toggle-layout-mode "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-layout-refresh "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-layout-resize-split "etaf-desktop-layout"
                  (desktop path ratio &optional workspace))
(declare-function etaf-desktop-layout-split "etaf-desktop-layout"
                  (desktop target new-id orientation ratio &optional workspace))
(declare-function etaf-desktop--layout-workspace-tree "etaf-desktop-layout" (workspace))
(declare-function etaf-desktop--layout-divider-shown "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-tree-leaves "etaf-desktop-layout" (tree))
(declare-function etaf-desktop--layout-dividers "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop--layout-divider-orientation "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-left "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-top "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-width "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-height "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-content "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-visible "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-ratio "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-span "etaf-desktop-layout" (divider))
(declare-function etaf-desktop--layout-divider-extent "etaf-desktop-layout" (divider))
(declare-function etaf-desktop-app "etaf-desktop-apps" (id))

(define-error 'etaf-desktop-error "Invalid ETAF Desktop operation")

(cl-defstruct (etaf-desktop--window
               (:constructor etaf-desktop--window-create))
  id title view x-source y-source width-source height-source
  min-width min-height max-width max-height
  visible-source minimized-source maximized-source mode-source taskbar-state-source
  shown-source workspace-source normal-geometry z-index-source movable resizable
  geometry-input geometry-writer focus-writer)

(cl-defstruct (etaf-desktop--state
               (:constructor etaf-desktop--state-create))
  windows workspaces active-workspace-source active-window-source next-z)

(defmacro etaf-desktop--define-state-field (record field &optional unit)
  "Define FIELD access on RECORD with one authoritative reactive cell.
Detached mutation candidates store scalars; retained records store refs.
UNIT describes the canonical value supplied directly to UI geometry props."
  (let ((reader (intern (format "etaf-desktop--%s-%s" record field)))
        (writer (intern (format "etaf-desktop--set-%s-%s" record field)))
        (source (intern (format "etaf-desktop--%s-%s-source" record field)))
        (retain (intern (format "etaf-desktop--retain-%s-%s" record field))))
    `(progn
       (defun ,reader (record)
         ,(format "Read %s from RECORD without exposing its reactive cell." field)
         (let ((source (,source record)))
           (if (etaf-ref-p source)
               ,(if unit '(cadr (etaf-value source)) '(etaf-value source))
             source)))
       (defun ,writer (record value)
         ,(format "Write %s VALUE to RECORD's scalar or retained cell." field)
         (let ((source (,source record)))
           (if (etaf-ref-p source)
               ,(if unit
                    `(let ((current (etaf-value source)))
                       (etaf-set-value source
                                       (if (equal (cadr current) value)
                                           current
                                         (list ',unit value))))
                  '(etaf-set-value source value))
             (setf (,source record) value)))
         value)
       (gv-define-simple-setter ,reader ,writer)
       (defun ,retain (record previous)
         ,(format "Retain %s's authoritative source in RECORD from PREVIOUS." field)
         (let* ((value (,reader record))
                (source (and previous (,source previous))))
           (if (etaf-ref-p source)
               (progn
                 (setf (,source record) source)
                 (,writer record value))
             (setf (,source record)
                   (etaf-ref ,(if unit `(list ',unit value) 'value)
                             :test #'equal))))))))

(etaf-desktop--define-state-field window x px)
(etaf-desktop--define-state-field window y lh)
(etaf-desktop--define-state-field window width px)
(etaf-desktop--define-state-field window height lh)
(etaf-desktop--define-state-field window z-index)
(etaf-desktop--define-state-field window visible)
(etaf-desktop--define-state-field window minimized)
(etaf-desktop--define-state-field window maximized)
(etaf-desktop--define-state-field window workspace)
(etaf-desktop--define-state-field state active-window)
(etaf-desktop--define-state-field state active-workspace)

(defun etaf-desktop--window-mode-value (window)
  "Return WINDOW's presentation mode from its minimized and maximized facts."
  (cond ((etaf-desktop--window-minimized window) 'minimized)
        ((etaf-desktop--window-maximized window) 'maximized)
        (t 'normal)))

(defun etaf-desktop--retain-window-mode (window previous)
  "Retain WINDOW's derived mode and taskbar sources, reusing PREVIOUS's.
The computeds read the retained minimized and maximized cells, so the UI
shell and taskbar receive stable reactive inputs for the window's lifetime."
  (let ((minimized (etaf-desktop--window-minimized-source window))
        (maximized (etaf-desktop--window-maximized-source window)))
    (setf (etaf-desktop--window-mode-source window)
          (or (and previous (etaf-desktop--window-mode-source previous))
              (etaf-computed
               (lambda ()
                 (cond ((etaf-value minimized) 'minimized)
                       ((etaf-value maximized) 'maximized)
                       (t 'normal)))))
          (etaf-desktop--window-taskbar-state-source window)
          (or (and previous (etaf-desktop--window-taskbar-state-source previous))
              (etaf-computed
               (lambda () (and (etaf-value minimized) 'minimized)))))))

(defun etaf-desktop--retain-window-shown (state window previous)
  "Retain WINDOW's presentation source in STATE, reusing PREVIOUS's.
The computed reads the retained visible, workspace and active-workspace
cells, so a workspace switch hides and reveals windows through bound
visibility instead of remounting them."
  (let ((visible (etaf-desktop--window-visible-source window))
        (workspace (etaf-desktop--window-workspace-source window))
        (active (etaf-desktop--state-active-workspace-source state)))
    (setf (etaf-desktop--window-shown-source window)
          (or (and previous (etaf-desktop--window-shown-source previous))
              (etaf-computed
               (lambda ()
                 (and (etaf-value visible)
                      (equal (etaf-value workspace) (etaf-value active)))))))))

(defun etaf-desktop--taskbar-state-source (members)
  "Return the reactive taskbar state for window MEMBERS of one item.
A single window reuses its retained source; an application group derives a
minimized state only when every member window is minimized."
  (if (cdr members)
      (let ((sources (mapcar #'etaf-desktop--window-minimized-source members)))
        (etaf-computed
         (lambda () (and (cl-every #'etaf-value sources) 'minimized))))
    (etaf-desktop--window-taskbar-state-source (car members))))

(defun etaf-desktop--ref (desktop name)
  "Return the runtime Host reference NAME in DESKTOP's namespace.
A desktop embedded in another desktop's window shares that ETAF Runtime, so
component-owned references carry the desktop token; a bare name would let the
inner level shadow the outer one."
  (intern (concat (etaf-desktop--controller-token
                   (etaf-desktop--controller desktop))
                  "-" name)))

(defvar etaf-desktop--next-token 0
  "Last desktop token handed out.  Window IDs carry it so two desktops that
embed each other keep distinct ETAF Host references.")

(cl-defstruct (etaf-desktop--controller
               (:constructor etaf-desktop--controller-create))
  name token fit canvas-width canvas-height canvas-size-ref state-ref fit-timer
  buffer runtime
  launcher-ref switcher-ref settings-ref settings-open-ref layout-label-ref
  theme-mode-ref close-request-ref owns-runtime-p owns-buffer-p divider-drag-origin)

(defun etaf-desktop--default-settings ()
  "Return the detached default settings for a new Desktop controller."
  (list :theme 'system
        :accent-color nil
        :layout-mode 'floating
        :tile-outer-gap 1
        :tile-inner-gap 1
        :title-font-size nil
        :content-font-size nil
        :font-family nil
        :drag-lock-modifier 'shift
        :resize-enabled t
        :confirm-close nil
        :taskbar-grouping 'window
        :keybindings
        (list :focus-next "n"
              :focus-previous "p"
              :launcher "a"
              :switcher "w"
              :settings "o"
              :toggle-layout "l"
              :split-window "s"
              :swap-window "x"
              :maximize-window "m"
              :restore-window "r"
              :minimize-window "i"
              :close-window "q")))

(defun etaf-desktop--fail (format-string &rest arguments)
  "Signal `etaf-desktop-error' with FORMAT-STRING and ARGUMENTS."
  (signal 'etaf-desktop-error (list (apply #'format format-string arguments))))

(defun etaf-desktop--controller (desktop)
  "Validate and return DESKTOP."
  (unless (etaf-desktop--controller-p desktop)
    (etaf-desktop--fail "Expected an ETAF desktop, got %S" desktop))
  desktop)

(defun etaf-desktop--state (desktop)
  "Return DESKTOP's current state."
  (etaf-value (etaf-desktop--controller-state-ref desktop)))

(defun etaf-desktop--settings (desktop)
  "Return DESKTOP's current settings plist."
  (copy-tree
   (etaf-value (etaf-desktop--controller-settings-ref
                (etaf-desktop--controller desktop)))))

(defun etaf-desktop-settings (desktop)
  "Return a detached settings plist for DESKTOP.

Settings are caller-visible configuration, not a second geometry store.  Use
`etaf-desktop-set-setting' or `etaf-desktop-reset-settings' to change them."
  (etaf-desktop--settings desktop))

(defun etaf-desktop-settings-open-p (desktop)
  "Return non-nil when DESKTOP's settings dialog is open."
  (etaf-value (etaf-desktop--controller-settings-open-ref
               (etaf-desktop--controller desktop))))

(defun etaf-desktop-toggle-settings (desktop &optional open)
  "Set DESKTOP's settings dialog to OPEN, or toggle it when OPEN is nil."
  (let* ((desktop (etaf-desktop--controller desktop))
         (ref (etaf-desktop--controller-settings-open-ref desktop))
         (value (if (null open) (not (etaf-value ref)) open)))
    (etaf-set-value ref value)
    value))

(defun etaf-desktop-close-settings (desktop)
  "Close DESKTOP's settings dialog and return nil."
  (etaf-set-value
   (etaf-desktop--controller-settings-open-ref
    (etaf-desktop--controller desktop))
   nil)
  nil)

(defun etaf-desktop--type-ratio (value)
  "Convert a Desktop font-size setting to the ratio `etaf-window' takes.

A Desktop setting is an Emacs face height in tenths of a point, 8 to 32, which
is what a user reads and what `face-attribute' reports. `etaf-window' takes a
ratio of the body size, where 1 is body text and 0.3 to 4 is the accepted
range, so the shell never needs to know the frame's metric."
  (and value (/ value 10.0)))

(defun etaf-desktop--valid-setting-p (key value)
  "Return non-nil when KEY accepts VALUE as a Desktop setting."
  (pcase key
    (:theme (etaf-desktop--theme-name-p value))
    (:accent-color (or (null value) (etaf-desktop--theme-color-p value)))
    (:layout-mode (memq value '(floating tiling master-stack monocle)))
    (:tile-outer-gap (and (integerp value) (<= 0 value 4)))
    (:tile-inner-gap (and (integerp value) (<= 1 value 4)))
    ((or :title-font-size :content-font-size)
     (or (null value) (and (numberp value) (>= value 8) (<= value 32))))
    (:font-family (or (null value) (stringp value)))
    (:drag-lock-modifier (memq value '(nil shift control meta super hyper)))
    (:resize-enabled (booleanp value))
    (:confirm-close (booleanp value))
    (:taskbar-grouping (memq value '(window application)))
    (:keybindings
     (and (listp value)
          (cl-loop for (name binding) on value by #'cddr
                   always (and (keywordp name) (stringp binding)
                               (etaf-desktop--valid-key-p binding)))
          ;; One key cannot both run an action and start a longer sequence.
          (let ((keys (cl-loop for (_name binding) on value by #'cddr
                               collect (kbd binding))))
            (cl-loop for key in keys
                     never (cl-some (lambda (other)
                                      (and (< (length key) (length other))
                                           (equal key (substring other 0 (length key)))))
                                    keys)))))
    (_ nil)))

(defun etaf-desktop--valid-key-p (binding)
  "Return non-nil when BINDING is a usable shortcut key or key sequence.
A sequence may not start with a printing key, which is a single-key command."
  (let ((events (condition-case nil (kbd binding) (error nil))))
    (and (> (length events) 0)
         (or (= (length events) 1)
             (not (and (characterp (aref events 0))
                       (<= ?\s (aref events 0) ?~)))))))

(defun etaf-desktop-set-setting (desktop key value)
  "Set DESKTOP setting KEY to VALUE and return its detached settings.

Layout mode and tile spacing changes apply to the active workspace
immediately; other settings project through the next retained shell publication.
Title and content font sizes are nil to inherit the Emacs font, or numbers
from 8 through 32 in CSS reference pixels (not points)."
  (let ((desktop (etaf-desktop--controller desktop)))
    (unless (and (keywordp key) (etaf-desktop--valid-setting-p key value))
      (etaf-desktop--fail "Invalid Desktop setting %S=%S" key value))
    (let ((settings (etaf-desktop--settings desktop)))
      (setq settings (plist-put settings key (copy-tree value)))
      (etaf-set-value (etaf-desktop--controller-settings-ref desktop) settings)
      (when (eq key :theme)
        (etaf-set-value (etaf-desktop--controller-theme-mode-ref desktop) value))
      (when (eq key :layout-mode)
        (etaf-desktop-set-layout-mode
         desktop value (etaf-desktop-active-workspace desktop)))
      (when (memq key '(:tile-outer-gap :tile-inner-gap))
        (etaf-desktop-layout-refresh desktop))
      (etaf-desktop-settings desktop))))

(defun etaf-desktop-reset-settings (desktop)
  "Restore DESKTOP's default settings and return them."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-set-value (etaf-desktop--controller-settings-ref desktop)
                    (etaf-desktop--default-settings))
    (etaf-desktop-set-layout-mode
     desktop 'floating (etaf-desktop-active-workspace desktop))
    (etaf-desktop-settings desktop)))

(defun etaf-desktop--set-keybinding (desktop key value)
  "Set one keybinding KEY in DESKTOP settings to VALUE."
  (unless (and (keywordp key) (stringp value) (not (string-empty-p value)))
    (etaf-desktop--fail "Invalid Desktop keybinding %S=%S" key value))
  (let ((bindings (copy-tree
                   (plist-get (etaf-desktop--settings desktop) :keybindings))))
    (setq bindings (plist-put bindings key value))
    (etaf-desktop-set-setting desktop :keybindings bindings)))

(defun etaf-desktop--visible-window-ids (desktop)
  "Return visible active-workspace IDs in stable opening order.
Raising a window changes its paint order, not keyboard traversal order."
  (let ((state (etaf-desktop--state desktop)))
    (mapcar
     #'etaf-desktop--window-id
     (reverse
      (cl-remove-if-not
       (lambda (window)
         (and (equal (etaf-desktop--window-workspace window)
                     (etaf-desktop--state-active-workspace state))
              (etaf-desktop--window-visible window)
              (not (etaf-desktop--window-minimized window))))
       (etaf-desktop--state-windows state))))))

(defun etaf-desktop--relative-window-id (active ids direction)
  "Return the ID DIRECTION steps from ACTIVE in the circular IDS order."
  (let ((index (or (cl-position active ids :test #'equal)
                   (if (> direction 0) -1 (length ids)))))
    (and ids (nth (mod (+ index direction) (length ids)) ids))))

(defun etaf-desktop--focus-relative (desktop direction)
  "Activate the next or previous visible window in the active workspace.
Keyboard focus follows into the raised window once it is published, because a
window below another has no reachable focus stops until it is raised."
  (when-let* ((next (etaf-desktop--relative-window-id
                    (etaf-desktop--active-window-id desktop)
                    (etaf-desktop--visible-window-ids desktop) direction)))
    (etaf-desktop-focus-window desktop next)
    (when-let* ((runtime (etaf-desktop--controller-runtime desktop)))
      (etaf-next-tick
       (lambda ()
         (when (etaf-runtime-mounted-p runtime)
           (ignore-error user-error
             (etaf-focus-within runtime (etaf-desktop--window-ref next)))))))))

(defun etaf-desktop--active-window-id (desktop)
  "Return the active window ID or nil."
  (etaf-desktop-active-window desktop))

(defun etaf-desktop--split-active-window (desktop)
  "Split the active window beside the next visible workspace window."
  (let* ((active (etaf-desktop--active-window-id desktop))
         (ids (etaf-desktop--visible-window-ids desktop))
         (other (etaf-desktop--relative-window-id active ids 1)))
    (when (and (member active ids) other (not (equal active other)))
      (etaf-desktop-layout-split desktop active other 'horizontal 0.5)
      (etaf-desktop-set-layout-mode desktop 'tiling)))
  desktop)

(defun etaf-desktop--swap-active-window (desktop)
  "Swap the active window with the next visible window in its layout group.
Tiled windows exchange tree leaves while floating windows exchange rectangles."
  (let* ((state (etaf-desktop--state desktop))
         (active (etaf-desktop--state-active-window state))
         (tree (etaf-desktop-layout-tree desktop))
         (leaves (unless (eq (etaf-desktop-layout-mode desktop) 'floating)
                   (etaf-desktop--layout-tree-leaves tree)))
         (tiled (member active leaves))
         (ids (cl-remove-if-not
               (lambda (id) (if tiled (member id leaves)
                              (not (member id leaves))))
               (etaf-desktop--visible-window-ids desktop)))
         (other (etaf-desktop--relative-window-id active ids 1)))
    (when (and (member active ids) other (not (equal active other)))
      (if tiled
          (etaf-desktop--layout-swap-windows desktop active other)
        (let ((first-geometry
               (etaf-desktop--geometry (etaf-desktop--window-for state active)))
              (second-geometry
               (etaf-desktop--geometry (etaf-desktop--window-for state other))))
          (etaf-desktop--update
           desktop
           (lambda (next)
             (let ((left (etaf-desktop--window-for next active))
                   (right (etaf-desktop--window-for next other)))
               (dolist (pair (list (cons left second-geometry)
                                   (cons right first-geometry)))
                 (setf (etaf-desktop--window-x (car pair)) (nth 0 (cdr pair))
                       (etaf-desktop--window-y (car pair)) (nth 1 (cdr pair))
                       (etaf-desktop--window-width (car pair)) (nth 2 (cdr pair))
                       (etaf-desktop--window-height (car pair)) (nth 3 (cdr pair))
                       (etaf-desktop--window-normal-geometry (car pair))
                       (copy-sequence (cdr pair))))
               (etaf-desktop--raise next left))))))))
  desktop)

(defconst etaf-desktop--settings-shortcuts
  '((:focus-next . "Focus next") (:focus-previous . "Focus previous")
    (:launcher . "Applications") (:switcher . "Window switcher")
    (:settings . "Settings") (:toggle-layout . "Toggle layout")
    (:split-window . "Split window") (:swap-window . "Swap windows")
    (:maximize-window . "Maximize") (:restore-window . "Restore")
    (:minimize-window . "Minimize") (:close-window . "Close window"))
  "Editable desktop shortcuts and their captions.")

(defun etaf-desktop--shortcut-actions (desktop)
  "Return DESKTOP's shortcut actions as an alist of (KEY . FUNCTION)."
  (let ((active (lambda (action)
                  (lambda ()
                    (when-let* ((id (etaf-desktop--active-window-id desktop)))
                      (funcall action desktop id))))))
    (list
     (cons :focus-next (lambda () (etaf-desktop--focus-relative desktop 1)))
     (cons :focus-previous (lambda () (etaf-desktop--focus-relative desktop -1)))
     (cons :launcher (lambda () (etaf-desktop-toggle-launcher desktop)))
     (cons :switcher (lambda () (etaf-desktop-toggle-switcher desktop)))
     (cons :settings (lambda () (etaf-desktop-toggle-settings desktop)))
     (cons :toggle-layout (lambda () (etaf-desktop-toggle-layout-mode desktop)))
     (cons :split-window (lambda () (etaf-desktop--split-active-window desktop)))
     (cons :swap-window (lambda () (etaf-desktop--swap-active-window desktop)))
     (cons :maximize-window (funcall active #'etaf-desktop-maximize-window))
     (cons :restore-window (funcall active #'etaf-desktop-restore-window))
     (cons :minimize-window (funcall active #'etaf-desktop-minimize-window))
     (cons :close-window (funcall active #'etaf-desktop--request-close-window)))))

(defun etaf-desktop--shortcut-keys (desktop bindings)
  "Return the shell's Host `:keys' for DESKTOP's settings BINDINGS.
Each entry carries its settings caption for ETAF help and the command palette."
  (let ((actions (etaf-desktop--shortcut-actions desktop)))
    (cl-loop for (key binding) on bindings by #'cddr
             for action = (cdr (assq key actions))
             when (and action (stringp binding))
             collect (list binding action
                           (or (cdr (assq key etaf-desktop--settings-shortcuts))
                               (substring (symbol-name key) 1))))))

(defun etaf-desktop--lifecycle-buffer (desktop)
  "Return the buffer owned by DESKTOP's current lifecycle Runtime.

`etaf-mount' may be called with a buffer name while another buffer is
current.  Lifecycle callbacks therefore use the Runtime supplied by ETAF;
fall back to DESKTOP's recorded buffer for callbacks outside a live Runtime."
  (or (when-let* ((runtime (etaf-current-runtime)))
        (etaf-runtime-buffer runtime))
      (etaf-desktop--controller-buffer desktop)
      (current-buffer)))

(defvar etaf-desktop--mount-window nil
  "Window mounting the current desktop while its first View renders.")

(defun etaf-desktop--canvas-window (desktop)
  "Return the live Emacs window displaying DESKTOP, when available.

A consumer may render this View itself (for example a Playground preview), so
the window currently displaying the rendered buffer wins over the window that
happens to be selected."
  (or (and (buffer-live-p (etaf-desktop--controller-buffer desktop))
           (get-buffer-window (etaf-desktop--controller-buffer desktop) t))
      (get-buffer-window (current-buffer) t)
      (and (window-live-p etaf-desktop--mount-window) etaf-desktop--mount-window)
      (selected-window)))

(defun etaf-desktop--runtime-viewport (desktop)
  "Return DESKTOP's mounted Runtime viewport (WIDTH . HEIGHT), or nil.
Only a fully measured viewport is returned; an unmounted desktop or an
unmeasured axis leaves the caller to its window fallback."
  (when-let* ((buffer (etaf-desktop--controller-buffer desktop))
              ((buffer-live-p buffer))
              (runtime (etaf-runtime-for-buffer buffer))
              (viewport (etaf-runtime-viewport runtime))
              ((numberp (car viewport)))
              ((numberp (cdr viewport))))
    viewport))

(defun etaf-desktop--canvas-box-width (desktop)
  "Return the shell/canvas width value for DESKTOP's mounted surface.

A desktop that follows its Emacs window fits that viewport exactly and needs
no pixel conversion, so the shell uses `stretch' there; an explicit canvas or
a headless render keeps the measured pixel canvas for deterministic geometry."
  (cond
   ((etaf-desktop--controller-canvas-width desktop)
    (list 'px (etaf-desktop--controller-canvas-width desktop)))
   ((or (etaf-desktop--fitted-canvas-size desktop)
        (let ((viewport (etaf-desktop--runtime-viewport desktop)))
          (and viewport (> (car viewport) 0))))
    'stretch)
   (t (list 'px (etaf-desktop--canvas-width-value desktop)))))

(defun etaf-desktop--fitted-canvas-size (desktop)
  "Return DESKTOP's retained window-fitted `(WIDTH . HEIGHT)', or nil.

The cell is written by `etaf-desktop-fit-canvas' whenever the Emacs window
displaying DESKTOP changes size.  Reading it inside a Host property binding
keeps the shell frame following the window without a structural re-render."
  (when-let* ((ref (etaf-desktop--controller-canvas-size-ref desktop)))
    (etaf-value ref)))

(defun etaf-desktop--window-canvas-size (window)
  "Return the (WIDTH . HEIGHT) an unconfigured desktop filling WINDOW uses.

WIDTH is the render surface's pixel width: the same surface the shell and its
canvas box stretch into, so the workspace bar, the canvas and a maximized
window share one right edge instead of leaving a band where the display-safe
window width ends.  HEIGHT leaves one row for the workspace bar and one for the
taskbar, so a default desktop owns exactly the visible window body."
  (let* ((runtime (and (window-live-p window)
                       (etaf-runtime-for-buffer (window-buffer window))))
         (char-width
          (max 1 (or (and runtime
                          (plist-get (ignore-errors (etaf-display-metrics runtime))
                                     :char-width))
                     (frame-char-width (window-frame window)))))
         (render-width (and runtime
                            (ignore-errors (car (etaf-runtime-viewport runtime)))))
         (width (or (and (integerp render-width) (> render-width 0)
                         render-width)
                    (let ((pixel-width (window-body-width window t)))
                      (if (> pixel-width 10)
                          pixel-width
                        (* (max 1 (window-body-width window)) char-width))))))
    (cons (max char-width width)
          (max 8 (- (window-body-height window) 2)))))

(defun etaf-desktop--canvas-width-value (desktop)
  "Return DESKTOP's effective canvas width in pixels.

An explicit canvas width wins.  A default desktop follows the Emacs window it
was last fitted to, then the render viewport, so a consumer that mounts the
View itself (for example a Playground preview) still fills the window it is
displayed in; the window measurement remains the fallback outside rendering."
  ;; Read the fitted cell before the explicit override: a `region'-fitted
  ;; desktop starts with the canvas it was created with and only later learns
  ;; its surface size, so a Host property binding must subscribe to the cell
  ;; even while the override answers.  Short-circuiting on the override left
  ;; the shell bound to the creation size, and a resized hosting window then
  ;; kept the old bars and taskbar position.
  (let ((fitted (etaf-desktop--fitted-canvas-size desktop)))
    (or (etaf-desktop--controller-canvas-width desktop)
        (car fitted)
        ;; The result stays on the character grid so a rounded-up pixel column
        ;; cannot push a row into Emacs continuation.
        (let* ((runtime-viewport (etaf-desktop--runtime-viewport desktop))
               (viewport (and runtime-viewport (> (car runtime-viewport) 0)
                              (car runtime-viewport)))
               (width (or viewport
                          (let ((window (etaf-desktop--canvas-window desktop)))
                            (if (window-live-p window)
                                (car (etaf-desktop--window-canvas-size window))
                              ;; A desktop with no window has no canvas to
                              ;; measure, so the frame's own cell answers.
                              (* 80 (max 1 (frame-char-width))))))) ; frame metric
               (char-width
                (max 1 (or (and-let* ((buffer (etaf-desktop--controller-buffer desktop))
                                      ((buffer-live-p buffer))
                                      (runtime (etaf-runtime-for-buffer buffer)))
                             (plist-get (ignore-errors (etaf-display-metrics runtime))
                                        :char-width))
                           (frame-char-width)))))
          (max char-width (* char-width (floor (/ width char-width))))))))

(defun etaf-desktop--canvas-height-value (desktop)
  "Return DESKTOP's effective canvas height in text rows.

One row is reserved for the workspace bar and one for the taskbar; the mounted
desktop hides buffer chrome, so no extra padding row is needed at the bottom."
  ;; Subscribe to the fitted cell even while an explicit height answers; see
  ;; `etaf-desktop--canvas-width-value'.
  (let ((fitted (etaf-desktop--fitted-canvas-size desktop)))
    (or (etaf-desktop--controller-canvas-height desktop)
        (cdr fitted)
        (let ((viewport (etaf-desktop--runtime-viewport desktop)))
          (and viewport (> (cdr viewport) 0)
               (max 8 (- (cdr viewport) 2))))
        (let ((window (etaf-desktop--canvas-window desktop)))
          (if (window-live-p window)
              (cdr (etaf-desktop--window-canvas-size window))
            24)))))

(defun etaf-desktop--copy-window (window)
  "Copy WINDOW's application state."
  (etaf-desktop--window-create
   :id (etaf-desktop--window-id window)
   :title (etaf-desktop--window-title window)
   :view (etaf-desktop--window-view window)
   :x-source (etaf-desktop--window-x window)
   :y-source (etaf-desktop--window-y window)
   :width-source (etaf-desktop--window-width window)
   :height-source (etaf-desktop--window-height window)
   :min-width (etaf-desktop--window-min-width window)
   :min-height (etaf-desktop--window-min-height window)
   :max-width (etaf-desktop--window-max-width window)
   :max-height (etaf-desktop--window-max-height window)
   :visible-source (etaf-desktop--window-visible window)
   :minimized-source (etaf-desktop--window-minimized window)
   :maximized-source (etaf-desktop--window-maximized window)
   :workspace-source (etaf-desktop--window-workspace window)
   :normal-geometry (copy-sequence (etaf-desktop--window-normal-geometry window))
   :z-index-source (etaf-desktop--window-z-index window)
   :movable (etaf-desktop--window-movable window)
   :resizable (etaf-desktop--window-resizable window)))

(defun etaf-desktop--copy-state (state)
  "Copy STATE without copying caller-owned View values."
  (etaf-desktop--state-create
   :windows (mapcar #'etaf-desktop--copy-window
                    (etaf-desktop--state-windows state))
   :workspaces (copy-sequence (etaf-desktop--state-workspaces state))
   :active-workspace-source (etaf-desktop--state-active-workspace state)
   :active-window-source (etaf-desktop--state-active-window state)
   :next-z (etaf-desktop--state-next-z state)))

(defun etaf-desktop--state-signature (state)
  "Return the mutable Desktop facts used to detect a no-op update.

Window Views are caller-owned retained trees and must not participate in this
comparison.  Geometry and lifecycle updates only change the scalar fields
below, so avoiding a publication when those facts are unchanged keeps a drag's
terminal event from rebuilding the retained Runtime tree a second time."
  (list
   (etaf-desktop--state-workspaces state)
   (etaf-desktop--state-active-workspace state)
   (etaf-desktop--state-active-window state)
   (etaf-desktop--state-next-z state)
   (mapcar
    (lambda (window)
      (list (etaf-desktop--window-id window)
            (etaf-desktop--window-title window)
            (etaf-desktop--window-x window)
            (etaf-desktop--window-y window)
            (etaf-desktop--window-width window)
            (etaf-desktop--window-height window)
            (etaf-desktop--window-min-width window)
            (etaf-desktop--window-min-height window)
            (etaf-desktop--window-max-width window)
            (etaf-desktop--window-max-height window)
            (etaf-desktop--window-visible window)
            (etaf-desktop--window-minimized window)
            (etaf-desktop--window-maximized window)
            (etaf-desktop--window-workspace window)
            (etaf-desktop--window-normal-geometry window)
            (etaf-desktop--window-z-index window)
            (etaf-desktop--window-movable window)
            (etaf-desktop--window-resizable window)))
    (etaf-desktop--state-windows state))))

(defun etaf-desktop--window-for (state id)
  "Return the window named ID in STATE, or nil."
  (cl-find id (etaf-desktop--state-windows state)
           :key #'etaf-desktop--window-id :test #'equal))

(defun etaf-desktop--workspace-present-p (state workspace)
  "Return non-nil when WORKSPACE is present in STATE."
  (member workspace (etaf-desktop--state-workspaces state)))

(defun etaf-desktop--assert-workspace (state workspace)
  "Signal when WORKSPACE is not in STATE."
  (unless (etaf-desktop--workspace-present-p state workspace)
    (etaf-desktop--fail "Unknown desktop workspace: %S" workspace))
  workspace)

(defun etaf-desktop--number (value name minimum)
  "Validate numeric VALUE named NAME and bounded by MINIMUM."
  (unless (and (integerp value) (>= value minimum))
    (etaf-desktop--fail "%s must be an integer >= %d, got %S"
                        name minimum value))
  value)

(defun etaf-desktop--prepare-window-writers (state window)
  "Prepare reusable scalar writers for WINDOW in retained STATE.
INPUT is invocation storage, never queried as desktop state.  Geometry refs
remain authoritative; NORMAL belongs to this record and public snapshots
copy it before returning it to callers."
  (let ((input (vector 0 0 0 0))
        (normal (etaf-desktop--window-normal-geometry window)))
    (setf (etaf-desktop--window-geometry-input window) input
          (etaf-desktop--window-geometry-writer window)
          (lambda ()
            (let ((x (aref input 0)) (y (aref input 1))
                  (width (aref input 2)) (height (aref input 3)))
              (setf (etaf-desktop--window-x window) x
                    (etaf-desktop--window-y window) y
                    (etaf-desktop--window-width window) width
                    (etaf-desktop--window-height window) height)
              (setcar normal x)
              (setcar (cdr normal) y)
              (setcar (cddr normal) width)
              (setcar (cdddr normal) height)
              (etaf-desktop--raise state window)))
          (etaf-desktop--window-focus-writer window)
          (lambda ()
            (etaf-desktop--raise state window)
            (etaf-desktop--window-id window)))))

(defun etaf-desktop--publish (desktop state)
  "Publish a detached structural STATE while retaining live scalar sources."
  (let ((previous (etaf-desktop--state desktop)))
    (etaf-call-with-batch
     (lambda ()
       (etaf-desktop--retain-state-active-workspace state previous)
       (dolist (window (etaf-desktop--state-windows state))
         (let ((old (etaf-desktop--window-for
                     previous (etaf-desktop--window-id window))))
           (etaf-desktop--retain-window-x window old)
           (etaf-desktop--retain-window-y window old)
           (etaf-desktop--retain-window-width window old)
           (etaf-desktop--retain-window-height window old)
           (etaf-desktop--retain-window-z-index window old)
           (etaf-desktop--retain-window-visible window old)
           (etaf-desktop--retain-window-minimized window old)
           (etaf-desktop--retain-window-maximized window old)
           (etaf-desktop--retain-window-workspace window old)
           (etaf-desktop--retain-window-mode window old)
           (etaf-desktop--retain-window-shown state window old)
           (etaf-desktop--prepare-window-writers state window)))
       (etaf-desktop--retain-state-active-window state previous)
       (etaf-set-value (etaf-desktop--controller-state-ref desktop) state)
       ;; Layout policy is an optional application-layer consumer of the
       ;; runtime.  Its guarded refresh reflows an active tiling/monocle tree
       ;; inside this batch, so the reflow and any divider republication
       ;; publish together with the structural change instead of as a second
       ;; publication; the guard avoids a recursive publish during apply.
       (when (fboundp 'etaf-desktop-layout-refresh)
         (etaf-desktop-layout-refresh desktop)))))
  state)

(defun etaf-desktop--active-workspace-window-p (state window)
  "Return whether WINDOW belongs to STATE's active workspace."
  (equal (etaf-desktop--state-active-workspace state)
         (etaf-desktop--window-workspace window)))

(defun etaf-desktop--tiled-window-p (desktop window)
  "Return whether DESKTOP's layout policy owns WINDOW's rectangle.
A window is tiled when its workspace runs a tiling, master-stack or monocle
layout and the window is a leaf of that workspace's tree."
  (and (fboundp 'etaf-desktop-layout-tree)
       (let* ((workspace (etaf-desktop--window-workspace window))
              (policy (etaf-desktop--layout-ensure-workspace desktop workspace)))
         (and (memq (etaf-desktop--layout-workspace-mode policy)
                    '(tiling master-stack monocle))
              (member (etaf-desktop--window-id window)
                      (etaf-desktop--layout-tree-leaves
                       (etaf-desktop--layout-workspace-tree policy)))
              t))))

(defun etaf-desktop--floating-window-p (desktop state window)
  "Return whether WINDOW permits direct scalar geometry writes in STATE.
Direct writes need the window in the active workspace, unowned by the layout
policy and not maximized; other cases republish desktop structure."
  (and (etaf-desktop--active-workspace-window-p state window)
       (not (etaf-desktop--tiled-window-p desktop window))
       (not (etaf-desktop--window-maximized window))))

(defun etaf-desktop--retained-focus-p (_state window)
  "Return whether focusing WINDOW only raises it through retained cells.
A visible, non-minimized window changes nothing but its stacking order and
the active-window and active-workspace cells, whichever workspace it is in."
  (and (etaf-desktop--window-visible window)
       (not (etaf-desktop--window-minimized window))))

(defun etaf-desktop--place-window (window x y width height)
  "Write WINDOW's retained rectangle to X Y WIDTH HEIGHT without raising it.
The layout policy calls this for every allocated tile inside one batch."
  (setf (etaf-desktop--window-x window) x
        (etaf-desktop--window-y window) y
        (etaf-desktop--window-width window) width
        (etaf-desktop--window-height window) height)
  (etaf-desktop--store-normal-geometry window x y width height))

(defun etaf-desktop--restore-normal-geometry (window)
  "Leave WINDOW's maximized view and restore its normal rectangle."
  (pcase-let ((`(,x ,y ,width ,height)
               (etaf-desktop--window-normal-geometry window)))
    (setf (etaf-desktop--window-maximized window) nil
          (etaf-desktop--window-x window) x
          (etaf-desktop--window-y window) y
          (etaf-desktop--window-width window) width
          (etaf-desktop--window-height window) height)))

(defun etaf-desktop--focus-tiled-window (desktop state window)
  "Focus tiled WINDOW and let the layout policy reassert its rectangle.
Geometry requests on a tiled window never move it: the tile is the layout's
allocation, so the request only raises the window and reapplies the layout
through retained cells."
  (if (etaf-desktop--retained-focus-p state window)
      (etaf-call-with-batch (etaf-desktop--window-focus-writer window))
    (etaf-desktop-focus-window desktop (etaf-desktop--window-id window)))
  (etaf-desktop-layout-refresh
   desktop (etaf-desktop--window-workspace window))
  (etaf-desktop--window-plist window))

(defun etaf-desktop--store-normal-geometry (window x y width height)
  "Record WINDOW's normal rectangle in place for the retained geometry writer."
  (let ((normal (etaf-desktop--window-normal-geometry window)))
    (setcar normal x)
    (setcar (cdr normal) y)
    (setcar (cddr normal) width)
    (setcar (cdddr normal) height)
    normal))

(defun etaf-desktop--write-mode (desktop state window function)
  "Apply FUNCTION's mode and geometry writes to retained WINDOW in one batch.
WINDOW's mode, visibility, geometry and stacking cells are authoritative, so
the shell, taskbar and focus presentation follow through retained bindings
without rebuilding DESKTOP's Component tree.  Layout membership is
resynchronized afterwards; a tiled workspace reflows through retained cells
and republishes structurally only when its set of dividers changes."
  (etaf-call-with-batch function)
  (when (fboundp 'etaf-desktop-layout-refresh)
    (etaf-desktop-layout-refresh
     desktop (etaf-desktop--state-active-workspace state)))
  (etaf-desktop--window-plist window))

(defun etaf-desktop--write-geometry (window x y width height)
  "Write WINDOW's known geometry and raise it without rebuilding desktop state.
The four geometry cells are authoritative.  The normal rectangle is the
separate lifecycle value used when entering and leaving maximization."
  (let ((input (etaf-desktop--window-geometry-input window)))
    (aset input 0 x)
    (aset input 1 y)
    (aset input 2 width)
    (aset input 3 height)
    (etaf-call-with-batch (etaf-desktop--window-geometry-writer window)))
  (etaf-desktop--window-plist window))

(defun etaf-desktop--update (desktop function &optional force-publication)
  "Copy DESKTOP state, call FUNCTION with it, and publish the copy.
FORCE-PUBLICATION also commits a layout policy change when geometry is equal."
  (let* ((desktop (etaf-desktop--controller desktop))
         (current (etaf-desktop--state desktop))
         (state (etaf-desktop--copy-state current))
         (result (funcall function state)))
    ;; Ebox emits a terminal drag event with the same geometry as its final
    ;; move event.  Do not publish an unchanged state: the retained Runtime
    ;; tree and Ebox surface are already current.
    (when (or force-publication
              (not (equal (etaf-desktop--state-signature current)
                          (etaf-desktop--state-signature state))))
      (etaf-desktop--publish desktop state))
    result))

(defun etaf-desktop--raise (state window)
  "Raise WINDOW in STATE and make it active."
  (unless (and (equal (etaf-desktop--state-active-window state)
                      (etaf-desktop--window-id window))
               (equal (etaf-desktop--state-active-workspace state)
                      (etaf-desktop--window-workspace window))
               ;; NEXT-Z is the monotone allocation cursor, so its preceding
               ;; value identifies the highest layer without scanning peers.
               (>= (etaf-desktop--window-z-index window)
                   (1- (etaf-desktop--state-next-z state))))
    (setf (etaf-desktop--window-z-index window)
          (etaf-desktop--state-next-z state)
          (etaf-desktop--state-next-z state)
          (1+ (etaf-desktop--state-next-z state))))
  (setf (etaf-desktop--state-active-window state)
        (etaf-desktop--window-id window)
        (etaf-desktop--state-active-workspace state)
        (etaf-desktop--window-workspace window))
  window)

(defun etaf-desktop--notify-window-event (desktop id event)
  "Notify the application registry that window ID experienced EVENT.

The runtime owns window geometry and deliberately does not require the
application registry (which depends on this module).  The optional callback is
installed by `etaf-desktop-apps' when the full package is loaded, keeping the
provider dependency acyclic while allowing app-instance lifecycle state to
follow direct window interactions."
  (when (fboundp 'etaf-desktop--application-window-event)
    (funcall #'etaf-desktop--application-window-event desktop id event)))

(defun etaf-desktop--geometry (window)
  "Return WINDOW's current geometry as `(X Y WIDTH HEIGHT)'."
  (list (etaf-desktop--window-x window)
        (etaf-desktop--window-y window)
        (etaf-desktop--window-width window)
        (etaf-desktop--window-height window)))

(defun etaf-desktop--clamp (value minimum maximum)
  "Clamp VALUE to MINIMUM and optional MAXIMUM."
  (max minimum (if maximum (min maximum value) value)))

(defconst etaf-desktop--window-reach-width 48
  "Pixels of a floating window that must stay inside the canvas horizontally.")

(defun etaf-desktop--reachable-position (desktop x y width)
  "Return `(X . Y)' keeping a WIDTH-wide floating window reachable in DESKTOP.
A floating window may overflow the canvas' left, right and bottom edges, but
at least `etaf-desktop--window-reach-width' pixels of its width and its title
row stay inside the canvas so the pointer can always grab it again."
  (let* ((canvas-width (etaf-desktop--canvas-width-value desktop))
         (canvas-height (etaf-desktop--canvas-height-value desktop))
         (reach (min etaf-desktop--window-reach-width width)))
    (cons (etaf-desktop--clamp x (- reach width) (max (- reach width)
                                                     (- canvas-width reach)))
          (etaf-desktop--clamp y 0 (max 0 (1- canvas-height))))))

(defun etaf-desktop--window-plist (window)
  "Return a detached public state plist for WINDOW."
  (list :id (etaf-desktop--window-id window)
        :title (etaf-desktop--window-title window)
        :x (etaf-desktop--window-x window)
        :y (etaf-desktop--window-y window)
        :width (etaf-desktop--window-width window)
        :height (etaf-desktop--window-height window)
        :min-width (etaf-desktop--window-min-width window)
        :min-height (etaf-desktop--window-min-height window)
        :max-width (etaf-desktop--window-max-width window)
        :max-height (etaf-desktop--window-max-height window)
        :visible (etaf-desktop--window-visible window)
        :minimized (etaf-desktop--window-minimized window)
        :maximized (etaf-desktop--window-maximized window)
        :workspace (etaf-desktop--window-workspace window)
        :z-index (etaf-desktop--window-z-index window)
        :normal-geometry (copy-sequence (etaf-desktop--window-normal-geometry window))
        :movable (etaf-desktop--window-movable window)
        :resizable (etaf-desktop--window-resizable window)))

(defun etaf-desktop--window-ref (id)
  "Return a stable host ref for window ID."
  (intern (format "etaf-desktop-window-%s" id)))

(defun etaf-desktop--delta (gesture)
  "Return desktop-unit X and Y displacement from GESTURE.

Ebox reports both pointer coordinates and DELTA in text-area pixels.  Desktop
state uses pixels horizontally and text rows vertically, so normalize the
vertical component against the originating window's actual frame line height
at this boundary."
  (let* ((delta (plist-get gesture :delta))
         (window (plist-get gesture :window))
         (line-height
          (when (window-live-p window)
            (max 1 (or (and-let* ((runtime (etaf-runtime-for-buffer
                                            (window-buffer window))))
                         (plist-get (ignore-errors (etaf-display-metrics runtime))
                                    :line-height))
                       (frame-char-height (window-frame window)))))))
    (cons (round (or (car delta) 0))
          (round (/ (float (or (cdr delta) 0)) (or line-height 1))))))

(defun etaf-desktop--move-behavior (desktop id)
  "Construct a controlled move Behavior for window ID in DESKTOP."
  (etaf-draggable-controlled
   (lambda ()
     (let ((state (etaf-desktop-window-state desktop id)))
       (list :x (plist-get state :x) :y (plist-get state :y))))
   (lambda (next)
     (let ((window (etaf-desktop--window-for (etaf-desktop--state desktop) id))
           (x (plist-get next :x))
           (y (plist-get next :y)))
       ;; A title click still focuses on start.  Its unchanged end proposal
       ;; must not turn a maximized window into an explicit move request.
       (unless (and window (= x (etaf-desktop--window-x window))
                    (= y (etaf-desktop--window-y window)))
         (etaf-desktop-move-window desktop id x y))))
   :axis 'both :delta #'etaf-desktop--delta
   :on-start (lambda (_gesture)
               (etaf-desktop-focus-window desktop id))))

(defun etaf-desktop--resize-behavior (desktop id edge)
  "Construct a controlled resize Behavior for window ID on EDGE."
  (let ((state (etaf-desktop-window-state desktop id))
        origin identity
        (edges (pcase edge
                 ('top-left '(left top))
                 ('top-right '(right top))
                 ('bottom-left '(left bottom))
                 ('bottom-right '(right bottom))
                 (_ (list edge)))))
    (etaf-resizable-controlled
     (lambda ()
       (let ((current (etaf-desktop-window-state desktop id)))
         (list :x (plist-get current :x)
               :y (plist-get current :y)
               :width (plist-get current :width)
               :height (plist-get current :height))))
     (lambda (next)
       (etaf-desktop--set-window-geometry
        desktop id (plist-get next :x) (plist-get next :y)
        (plist-get next :width) (plist-get next :height)))
     :edges edges :delta #'etaf-desktop--delta
     :min-width (plist-get state :min-width)
     :max-width (plist-get state :max-width)
     :min-height (plist-get state :min-height)
     :max-height (plist-get state :max-height)
     :on-start (lambda (_gesture)
                 (let ((window (etaf-desktop--window-for
                                (etaf-desktop--state desktop) id)))
                   (setq origin (etaf-desktop--geometry window)
                         identity (etaf-desktop--window-x-source window)))
                 (etaf-desktop-focus-window desktop id))
     :on-end (lambda (_gesture) (setq origin nil identity nil))
     :on-cancel
     (lambda (gesture)
       (let ((saved origin) (source identity)
             (window (etaf-desktop--window-for (etaf-desktop--state desktop) id)))
         (setq origin nil identity nil)
         ;; Only an explicit user quit rolls back.  A removed/replaced target
         ;; or an unrelated-input boundary must not mutate another window.
         (when (and saved window (eq (plist-get gesture :reason) 'quit)
                    (eq source (etaf-desktop--window-x-source window))
                    (etaf-desktop--window-resizable window))
           (apply #'etaf-desktop--set-window-geometry desktop id saved)))))))

(defun etaf-desktop--window-shell-same-p (old new)
  "Return non-nil when window records OLD and NEW build the same shell.
Retained sources and the caller-owned View compare by identity; per-publication
writers are invocation plumbing and do not affect the shell."
  (or (eq old new)
      (and old new
           (cl-loop for accessor in '(etaf-desktop--window-view
                                      etaf-desktop--window-mode-source
                                      etaf-desktop--window-shown-source
                                      etaf-desktop--window-x-source
                                      etaf-desktop--window-y-source
                                      etaf-desktop--window-width-source
                                      etaf-desktop--window-height-source
                                      etaf-desktop--window-z-index-source)
                    always (eq (funcall accessor old) (funcall accessor new)))
           (cl-loop for accessor in '(etaf-desktop--window-id
                                      etaf-desktop--window-title
                                      etaf-desktop--window-min-width
                                      etaf-desktop--window-min-height
                                      etaf-desktop--window-max-width
                                      etaf-desktop--window-max-height
                                      etaf-desktop--window-movable
                                      etaf-desktop--window-resizable)
                    always (equal (funcall accessor old) (funcall accessor new))))))

(etaf-define-component etaf-desktop--window-surface (&key desktop id)
  "Own one window's gesture Behaviors for its retained Component lifetime."
  :bindings ((active (etaf-computed
                     (lambda ()
                       (equal id (etaf-desktop--state-active-window
                                  (etaf-desktop--state desktop))))))
             ;; Every desktop update copies the window records while retaining
             ;; their live sources and View, so closing or restacking another
             ;; window keeps this surface retained.
             (window (etaf-computed
                      (lambda ()
                        (etaf-desktop--window-for
                         (etaf-desktop--state desktop) id))
                      :test #'etaf-desktop--window-shell-same-p))
             (move (etaf-desktop--move-behavior desktop id))
             (resize-left (etaf-desktop--resize-behavior desktop id 'left))
             (resize-right (etaf-desktop--resize-behavior desktop id 'right))
             (resize-top (etaf-desktop--resize-behavior desktop id 'top))
             (resize-bottom (etaf-desktop--resize-behavior desktop id 'bottom))
             (resize-top-left (etaf-desktop--resize-behavior desktop id 'top-left))
             (resize-top-right (etaf-desktop--resize-behavior desktop id 'top-right))
             (resize-bottom-left (etaf-desktop--resize-behavior desktop id 'bottom-left))
             (resize-bottom-right (etaf-desktop--resize-behavior desktop id 'bottom-right)))
  :render
  (when-let* ((window (etaf-value window)))
    (etaf-desktop--window-shell desktop window active move
                                 resize-left resize-right resize-top resize-bottom
                                 resize-top-left resize-top-right
                                 resize-bottom-left resize-bottom-right)))

(defun etaf-desktop--window-node (desktop window)
  "Return the keyed retained Component for WINDOW in DESKTOP."
  (etaf-node 'etaf-desktop--window-surface
             (list :key (etaf-desktop--window-id window)
                   :desktop desktop :id (etaf-desktop--window-id window))
             nil))

(defun etaf-desktop--request-close-window (desktop id)
  "Close ID, or ask first through the in-buffer dialog when settings say so."
  (if (plist-get (etaf-desktop--settings desktop) :confirm-close)
      (etaf-set-value (etaf-desktop--controller-close-request-ref desktop) id)
    (etaf-desktop-close-window desktop id)))

(defun etaf-desktop--close-request (desktop)
  "Return the window id awaiting close confirmation in DESKTOP, or nil."
  (etaf-value (etaf-desktop--controller-close-request-ref desktop)))

(etaf-define-component etaf-desktop--close-confirm-surface (&key desktop)
  "Ask whether to close the window awaiting confirmation in DESKTOP.
Cancel, Escape and a press outside the card keep the window; the primary
action closes it.  The dialog owns no window state: the pending id lives in
the controller and clears on either answer."
  :render
  (let ((id (etaf-desktop--close-request desktop)))
    (when id
      (let* ((window (cl-find id (etaf-desktop-windows desktop)
                              :key (lambda (plist) (plist-get plist :id))))
             (title (or (plist-get window :title) (format "%s" id)))
             (cancel (lambda ()
                       (etaf-set-value
                        (etaf-desktop--controller-close-request-ref desktop) nil))))
        (etaf-node
         'etaf-dialog
         (list :open t :title "Close window?" :width '(ch 60) :height '(lh 8)
               :close-label nil :on-close cancel)
         (list (etaf-node 'etaf-label
                          (list :text (format "“%s” will close. Unsaved work in it is lost."
                                              title)
                                :wrap-mode 'word)
                          nil))
         (list (cons 'footer
                     (list
                      (etaf-node 'etaf-button
                                 (list :label "Cancel" :variant 'secondary
                                       :ref (etaf-desktop--ref desktop "etaf-desktop-close-cancel")
                                       :on-press cancel)
                                 nil)
                      (etaf-node 'etaf-button
                                 (list :label "Close window" :variant 'primary
                                       :ref (etaf-desktop--ref desktop "etaf-desktop-close-confirm")
                                       :on-press
                                       (lambda ()
                                         (funcall cancel)
                                         (when (cl-find id (etaf-desktop-windows desktop)
                                                        :key (lambda (plist)
                                                               (plist-get plist :id)))
                                           (etaf-desktop-close-window desktop id))))
                                 nil)))))))))

(defun etaf-desktop--frame-body (text)
  "Return a desktop-owned window body showing TEXT inside the frame margin.
A desktop window is seamless: its resize strips cover the outermost body
row and columns, so content the desktop authors itself keeps the margin
cell clear for them."
  (etaf-node 'box
             (list :width 'stretch :height 'stretch
                   :padding '((lh 0) (ch 2) (lh 1) (ch 2)))
             (list (etaf-node 'text nil (list text)))))

(defun etaf-desktop--window-shell
    (desktop window active move resize-left resize-right resize-top resize-bottom
             resize-top-left resize-top-right resize-bottom-left resize-bottom-right)
  "Build WINDOW's ETAF UI shell with its retained geometry Behaviors.
MOVE, RESIZE-RIGHT and RESIZE-BOTTOM are owned by the window Component."
  (let* ((id (etaf-desktop--window-id window))
         (settings (etaf-desktop--settings desktop))
         (title (or (etaf-desktop--window-title window) (format "%s" id)))
         (body (or (etaf-desktop--window-view window)
                   (etaf-desktop--frame-body title)))
         (resize-enabled (plist-get settings :resize-enabled))
         (mode (etaf-desktop--window-mode-source window))
         (move (and (etaf-desktop--window-movable window) move))
         (resize-left (and resize-enabled (etaf-desktop--window-resizable window) resize-left))
         (resize-right (and resize-enabled (etaf-desktop--window-resizable window) resize-right))
         (resize-top (and resize-enabled (etaf-desktop--window-resizable window) resize-top))
         (resize-bottom (and resize-enabled (etaf-desktop--window-resizable window) resize-bottom))
         (resize-top-left (and resize-enabled (etaf-desktop--window-resizable window) resize-top-left))
         (resize-top-right (and resize-enabled (etaf-desktop--window-resizable window) resize-top-right))
         (resize-bottom-left (and resize-enabled (etaf-desktop--window-resizable window) resize-bottom-left))
         (resize-bottom-right (and resize-enabled (etaf-desktop--window-resizable window) resize-bottom-right)))
    (etaf-node
     'etaf-window
     (list :key id :id (format "%s" id) :ref (etaf-desktop--window-ref id)
           :chrome-ref (intern (format "etaf-desktop-chrome-%s" id))
           ;; macOS presentation: only the active window shows colored
           ;; traffic lights; every other window renders gray lights.
           :controls-active active
           :title title :aria-label title
           :mode mode :visible (etaf-desktop--window-shown-source window)
           :title-font-size (etaf-desktop--type-ratio (plist-get settings :title-font-size))
           :content-font-size (etaf-desktop--type-ratio (plist-get settings :content-font-size))
           :font-family (plist-get settings :font-family)
           :drag-lock-modifier (plist-get settings :drag-lock-modifier)
           :x (etaf-desktop--window-x-source window)
           :y (etaf-desktop--window-y-source window)
           :width (etaf-desktop--window-width-source window)
           :height (etaf-desktop--window-height-source window)
           :z-index (etaf-desktop--window-z-index-source window)
           :min-width (list 'px (etaf-desktop--window-min-width window))
           :min-height (list 'lh (etaf-desktop--window-min-height window))
           :max-width (and (etaf-desktop--window-max-width window)
                           (list 'px (etaf-desktop--window-max-width window)))
           :max-height (and (etaf-desktop--window-max-height window)
                            (list 'lh (etaf-desktop--window-max-height window)))
           :resizable (and (etaf-desktop--window-resizable window) resize-enabled)
           :resize-edges '(left right top bottom top-left top-right
                                bottom-left bottom-right)
           ;; The window owns no inset: the body reaches the window edges and
           ;; the resize strips cover its edge cells.  Applications keep their
           ;; own margin cells clear so the strips never cover a control.
           :full-bleed t
           :resize-refs
           (mapcar (lambda (edge)
                     (cons edge (intern (format "etaf-desktop-resize-%s-%s" id edge))))
                   '(top right bottom left top-left top-right bottom-right bottom-left))
           :move-use move
           :resize-use (delq nil
                             (list (and resize-left (cons 'left resize-left))
                                   (and resize-right (cons 'right resize-right))
                                   (and resize-top (cons 'top resize-top))
                                   (and resize-bottom (cons 'bottom resize-bottom))
                                   (and resize-top-left (cons 'top-left resize-top-left))
                                   (and resize-top-right (cons 'top-right resize-top-right))
                                   (and resize-bottom-left (cons 'bottom-left resize-bottom-left))
                                   (and resize-bottom-right (cons 'bottom-right resize-bottom-right))))
           :on-minimize (lambda () (etaf-desktop-minimize-window desktop id))
           :on-maximize (lambda () (etaf-desktop-maximize-window desktop id))
           :on-restore (lambda () (etaf-desktop-restore-window desktop id))
           :on-close (lambda () (etaf-desktop--request-close-window desktop id))
           ;; Keyboard focus entering the active window needs no activation.
           :on-focus (lambda ()
                       (unless (equal id (etaf-desktop--active-window-id desktop))
                         (etaf-desktop-focus-window desktop id))))
     (list body))))

(defun etaf-desktop--taskbar-key (id grouping)
  "Return the taskbar key for window ID according to GROUPING."
  (let ((id (cond ((null id) "")
                  ((stringp id) id)
                  ((symbolp id) (symbol-name id))
                  (t (format "%s" id)))))
    (if (and (eq grouping 'application)
             (string-match "\\`\\([^/]+\\)/" id))
        (match-string 1 id)
      id)))

(defun etaf-desktop--taskbar-node (desktop state active)
  "Project STATE's taskbar membership with a live ACTIVE selection source."
  (let* ((settings (etaf-desktop--settings desktop))
         (grouping (plist-get settings :taskbar-grouping))
         ;; Every workspace's windows stay listed: selecting one switches to
         ;; its workspace through retained cells, and the bar's membership
         ;; never depends on the active workspace.
         (windows (etaf-desktop--state-windows state))
         (groups nil))
    (dolist (window windows)
      (let* ((key (etaf-desktop--taskbar-key
                   (etaf-desktop--window-id window) grouping))
             (entry (assoc key groups)))
        (if entry
            (setcdr entry (append (cdr entry) (list window)))
          (setq groups (append groups (list (cons key (list window))))))))
    (let ((items
           (mapcar
            (lambda (group)
              (let* ((key (car group))
                     (members (cdr group))
                     (first (car members))
                     (label (if (eq grouping 'application)
                                (or (ignore-errors
                                      (plist-get (etaf-desktop-app key) :title))
                                    key)
                              (or (etaf-desktop--window-title first) key))))
                (list :key key
                      :ref (etaf-desktop--window-ref (format "taskbar-%s" key))
                      :label (format "%s" label)
                      :state (etaf-desktop--taskbar-state-source members)
                      :window-id (etaf-desktop--window-id first))))
            groups)))
    (etaf-node 'etaf-taskbar
               (list :items items
                     :ref-prefix (concat (etaf-desktop--controller-token desktop) "-")
                     :active active
                     :on-select (lambda (id)
                                  (let ((target (or (plist-get
                                                     (cl-find id items :key (lambda (item)
                                                                            (plist-get item :key))
                                                                  :test #'equal)
                                                     :window-id)
                                                    id)))
                                    (etaf-desktop-focus-window desktop target)))
                     :on-launch (and (fboundp 'etaf-desktop-toggle-launcher)
                                     (lambda ()
                                       (etaf-desktop-toggle-launcher desktop))))
               nil))))

(defun etaf-desktop--layout-label (desktop workspace)
  "Return the workspace bar label for DESKTOP's WORKSPACE layout mode."
  (pcase (and (fboundp 'etaf-desktop-layout-mode)
              (etaf-desktop-layout-mode desktop workspace))
    ('tiling "Tiled")
    ('master-stack "Master")
    ('monocle "Monocle")
    (_ "Floating")))

(defun etaf-desktop--sync-layout-label (desktop &optional workspace)
  "Write the active workspace's layout label into DESKTOP's retained cell.
WORKSPACE, when given, names the workspace whose mode changed; another
workspace's change leaves the visible label alone.  The label is a Text
payload of the workspace bar, so a mode change updates that text in place
instead of re-rendering the desktop."
  (let* ((desktop (etaf-desktop--controller desktop))
         (active (etaf-desktop--state-active-workspace
                  (etaf-desktop--state desktop))))
    (when (or (null workspace) (equal workspace active))
      (etaf-set-value (etaf-desktop--controller-layout-label-ref desktop)
                      (etaf-desktop--layout-label desktop active)))))

(defun etaf-desktop--workspace-node (desktop state status)
  "Project STATE's workspace controls with a live focused-window STATUS."
  (progn
    (etaf-node 'etaf-workspace-bar
               (list :ref-prefix (concat (etaf-desktop--controller-token desktop) "-")
                     :workspaces (etaf-desktop--state-workspaces state)
                     :active (etaf-desktop--state-active-workspace-source state)
                     ;; The right side reports the focused application and the
                     ;; workspace's window-management mode, which the trailing
                     ;; control switches without leaving the desktop.  The
                     ;; label is a retained cell so toggling updates only its text.
                     :status status
                     :layout-label (etaf-desktop--controller-layout-label-ref desktop)
                     :layout-action
                     (lambda ()
                       (etaf-desktop-toggle-layout-mode
                        desktop (etaf-desktop--state-active-workspace state)))
                     :settings-label "Settings"
                     :settings-action
                     (lambda () (etaf-desktop-toggle-settings desktop))
                     :on-select
                     (lambda (workspace)
                       (etaf-desktop-switch-workspace desktop workspace)))
               nil)))

(defun etaf-desktop--splitter-ratio-change (desktop workspace path divider gesture)
  "Apply one controlled SPLITTER GESTURE to the layout ratio at PATH.
The gesture remains an ETAF UI input fact; this application callback converts
its axis delta, using DIVIDER's allocated first-pane extent and span at the
gesture start, into the caller-owned layout tree ratio through the public API.
Ebox reports `:delta' as the displacement from the press.  The allocated extent
keeps a fresh gesture responsive when minimum or maximum sizes constrained the
requested ratio.  A cancelled gesture restores the original requested ratio."
  (let* ((phase (plist-get gesture :phase))
         (current (lambda ()
                    (list (etaf-value (etaf-desktop--layout-divider-ratio divider))
                          (etaf-value (etaf-desktop--layout-divider-span divider))
                          (etaf-desktop--layout-divider-extent divider))))
         (stored (etaf-desktop--controller-divider-drag-origin desktop)))
    (when (eq phase 'start)
      (setq stored (cons divider (funcall current)))
      (setf (etaf-desktop--controller-divider-drag-origin desktop) stored))
    (when (memq phase '(move end))
      (let* ((orientation (etaf-desktop--layout-divider-orientation divider))
             (origin (if (eq (car-safe stored) divider)
                         (cdr stored)
                       (funcall current)))
             (delta (etaf-desktop--delta gesture))
             (offset (if (eq orientation 'horizontal)
                         (car delta) (cdr delta)))
             (span (max 2 (nth 1 origin)))
             (requested (* (car origin) span))
             ;; Keep subpixel intent when allocation only rounded it.  A
             ;; size constraint instead needs the visible edge as its origin.
             (extent (if (> (abs (- (nth 2 origin) requested)) 0.500001)
                         (nth 2 origin) requested))
             (next (if (zerop offset)
                       (car origin)
                     (/ (float (max 1 (min (1- span) (+ extent offset))))
                        span))))
        (when (fboundp 'etaf-desktop-layout-resize-split)
          (etaf-desktop-layout-resize-split desktop path next workspace))))
    (when (and (eq phase 'cancel)
               (eq (car-safe stored) divider)
               (fboundp 'etaf-desktop-layout-resize-split))
      (etaf-desktop-layout-resize-split desktop path (cadr stored) workspace))
    (when (memq phase '(end cancel))
      (setf (etaf-desktop--controller-divider-drag-origin desktop) nil))))

(defun etaf-desktop--splitter-overlays (desktop workspace)
  "Return the divider overlays for every split WORKSPACE has allocated.
The layout policy owns every divider rectangle and visibility as retained
refs and rewrites them when it applies the layout; ETAF UI owns only each
divider's presentation and input.  A split that left the tree keeps its
hidden node so membership changes only update its visibility.  Dividers
occupy the inner gaps between tiles, so they stack beneath every window and
a maximized window covers them."
  (mapcar
   (lambda (entry)
     (let ((path (car entry))
           (divider (cdr entry)))
       (etaf-node
        'etaf-splitter
        ;; Every workspace's dividers are siblings in the canvas slot, so the
        ;; key carries the workspace: two tiled workspaces both own a root
        ;; split at the same path.
        (list :key (format "desktop-splitter-%S-%S" workspace path)
              :orientation (etaf-desktop--layout-divider-orientation divider)
              :class "etaf-desktop-layout-splitter"
              :overlay t
              :overlay-rect
              (list :left (etaf-desktop--layout-divider-left divider)
                    :top (etaf-desktop--layout-divider-top divider)
                    :width (etaf-desktop--layout-divider-width divider)
                    :height (etaf-desktop--layout-divider-height divider))
              :z-index 0
              :visible (etaf-desktop--layout-divider-shown divider)
              :divider-content (etaf-desktop--layout-divider-content divider)
              :on-change
              (lambda (gesture)
                (etaf-desktop--splitter-ratio-change
                 desktop workspace path divider gesture)))
        nil)))
   (etaf-desktop--layout-dividers desktop workspace)))

(defun etaf-desktop--launcher-node (desktop)
  "Build the controlled application launcher for DESKTOP."
  (when (etaf-desktop-launcher-open-p desktop)
    (let* ((instances (etaf-desktop-instances desktop))
           (items
            (mapcar
             (lambda (app)
               (let* ((id (plist-get app :id))
                      (title (or (plist-get app :title) (format "%s" id)))
                      (icon (plist-get app :icon))
                      (running
                       (cl-remove-if-not
                        (lambda (instance)
                          (and (equal (plist-get instance :app-id) id)
                               (memq (plist-get instance :status)
                                     '(active inactive suspended))))
                        instances))
                      (windows (apply #'+ (mapcar (lambda (instance)
                                                    (length (plist-get instance :windows)))
                                                  running))))
                 (list :key id
                       :ref (etaf-desktop--ref
                             desktop (format "etaf-desktop-launcher-%s" id))
                       :label (if (and (stringp icon) (not (string-empty-p icon)))
                                  (concat icon " " title)
                                title)
                       :state (and running 'active)
                       :description
                       (cond ((null running) "Not running")
                             ((= windows 1) "Running · 1 window")
                             (t (format "Running · %d windows" windows))))))
             (etaf-desktop-apps))))
      (etaf-node 'etaf-launcher
                 (list :open (etaf-desktop--controller-launcher-ref desktop)
                       :items items
                       :on-select
                       (lambda (app-id)
                         (etaf-desktop-launch desktop app-id)
                         (etaf-desktop-close-launcher desktop))
                       :on-close (lambda ()
                                   (etaf-desktop-close-launcher desktop)))
                 nil))))

(defun etaf-desktop--switcher-node (desktop state)
  "Build the controlled window switcher for DESKTOP and STATE."
  (when (and (fboundp 'etaf-desktop-switcher-open-p)
             (etaf-desktop-switcher-open-p desktop))
    (let ((items
           (mapcar (lambda (window)
                     (list :key (etaf-desktop--window-id window)
                           :ref (etaf-desktop--window-ref
                                 (format "switcher-%s"
                                         (etaf-desktop--window-id window)))
                           :label (or (etaf-desktop--window-title window)
                                      (format "%s" (etaf-desktop--window-id window)))
                           :state (when (equal (etaf-desktop--window-id window)
                                               (etaf-desktop--state-active-window state))
                                    'active)))
                   (etaf-desktop--state-windows state))))
      (etaf-node 'etaf-switcher
                 (list :open (etaf-desktop--controller-switcher-ref desktop)
                       :selected (etaf-desktop--state-active-window state)
                       :items items
                       :on-select (lambda (id)
                                    (etaf-desktop-focus-window desktop id)
                                    (etaf-desktop-close-switcher desktop))
                       :on-close (lambda ()
                                   (etaf-desktop-close-switcher desktop)))
                 nil))))

(defun etaf-desktop--theme-token (key &optional transform)
  "Return the deferred Desktop Theme value for shell token KEY.
TRANSFORM, when given, maps the resolved color to the final property value."
  (etaf-theme-token key (plist-get (etaf-desktop-theme-tokens 'light) key)
                    transform))

(defconst etaf-desktop--settings-sections
  '((appearance . "Appearance") (layout . "Layout")
    (behavior . "Behavior") (shortcuts . "Shortcuts"))
  "Settings dialog sections in tab order.")

(defun etaf-desktop--settings-fields (section)
  "Return the (KIND KEY LABEL . PROPS) field specs of settings SECTION."
  (pcase section
    ('appearance
     `((etaf-select :theme "Theme" :options
                    ((system . "System")
                     ,@(mapcar (lambda (theme)
                                 (cons (plist-get theme :name)
                                       (plist-get theme :label)))
                               (etaf-desktop-themes))))
       (etaf-text-input :accent-color "Accent color" :placeholder "Theme accent")
       (etaf-text-input :font-family "Font family" :placeholder "Emacs default")
       (etaf-button :title-font-size "Title font size")
       (etaf-button :content-font-size "Content font size")))
    ('layout
     '((etaf-select :layout-mode "Window layout" :options
                    ((floating . "Floating") (tiling . "Tiling")
                     (master-stack . "Master and stack") (monocle . "Monocle")))
       (etaf-number-input :tile-outer-gap "Outer gap" :min 0 :max 4)
       (etaf-number-input :tile-inner-gap "Inner gap" :min 1 :max 4)))
    ('behavior
     '((etaf-select :drag-lock-modifier "Drag lock modifier" :options
                    ((shift . "Shift") (control . "Control")
                     (meta . "Meta") (super . "Super") (hyper . "Hyper")))
       (etaf-switch :resize-enabled "Allow window resizing")
       (etaf-switch :confirm-close "Confirm before closing")
       (etaf-select :taskbar-grouping "Taskbar grouping" :options
                    ((window . "Every window") (application . "By application")))))
    ('shortcuts
     (mapcar (lambda (entry) (list 'etaf-text-input (car entry) (cdr entry)))
             etaf-desktop--settings-shortcuts))))

(defun etaf-desktop--settings-field-nodes (desktop section field value)
  "Return the label and control nodes of FIELD showing VALUE in SECTION.
Labels sit in their own grid column, so controls hide their captions."
  (let* ((kind (nth 0 field)) (key (nth 1 field)) (label (nth 2 field))
         (extra (nthcdr 3 field))
         (on-change
          (lambda (next)
            (if (eq section 'shortcuts)
                (etaf-desktop--set-keybinding desktop key next)
              (etaf-desktop-set-setting
               desktop key (if (and (memq key '(:font-family :accent-color))
                                    (stringp next) (string-empty-p next))
                               nil next))))))
    (list
     (etaf-node 'etaf-label (list :key (format "%s-label" key) :text label
                                  :variant 'muted :wrap-mode 'none)
                nil)
     (if (memq key '(:title-font-size :content-font-size))
         (etaf-node
          'etaf-button
          (list :key key :variant 'ghost :disabled (null value)
                :label (if value
                           (format "%s px · Use Emacs default" value)
                         "Emacs default")
                :aria-label (format "Use Emacs default for %s" (downcase label))
                :on-press (lambda () (etaf-desktop-set-setting desktop key nil)))
          nil)
       (etaf-node
        kind
        (append
         (list :key key)
         (pcase kind
           ('etaf-switch (list :checked (and value t) :label (if value "On" "Off")))
           ('etaf-text-input (list :value (or value "") :label label :hide-label t))
           (_ (list :value value :label label :hide-label t)))
         (list :on-change on-change)
         extra)
        nil)))))

(defun etaf-desktop--settings-height (section fields)
  "Return the `(lh N)' dialog height fitting SECTION's FIELDS.
The body holds the tab row, the field grid and one hint row separated by
one row each inside one row of padding; the card adds its header and
footer.  Shortcuts fill two label/control column pairs."
  (let* ((rows (max 1 (1- (* 2 (if (eq section 'shortcuts)
                                    (ceiling (length fields) 2)
                                  (length fields)))))))
    (list 'lh (+ rows 9))))

(defun etaf-desktop--settings-grid (desktop section)
  "Return DESKTOP's labelled field grid for the active settings SECTION."
  (let* ((settings
          (let ((settings (etaf-desktop--settings desktop)))
            ;; Layout mode is active-workspace state that the bar control and
            ;; workspace switches change without touching the settings ref;
            ;; the label cell tracks it, so reading it keeps this form live.
            (etaf-value (etaf-desktop--controller-layout-label-ref desktop))
            (if (fboundp 'etaf-desktop-layout-mode)
                (plist-put settings :layout-mode
                           (etaf-desktop-layout-mode desktop))
              settings)))
         (bindings (plist-get settings :keybindings))
         (fields (etaf-desktop--settings-fields section))
         (shortcuts (eq section 'shortcuts)))
    (etaf-node
     'grid (list :class "etaf-desktop-settings-fields" :width 'stretch
                 :grid-template-columns (if shortcuts
                                            '((ch 16) (fr 1) (ch 16) (fr 1))
                                          '((ch 18) (fr 1)))
                 :column-gap '(ch 2) :row-gap '(lh 1)
                 :align-items 'center)
     (mapcan
      (lambda (field)
        (let* ((key (nth 1 field))
               (value (plist-get (if shortcuts bindings settings) key))
               ;; `light' and `dark' select the built-in theme of that mode.
               (value (if (and (eq key :theme) (memq value '(light dark)))
                          (plist-get (etaf-desktop--theme-entry value) :name)
                        value)))
          (etaf-desktop--settings-field-nodes desktop section field value)))
      fields))))

(etaf-define-component etaf-desktop--settings-panel (&key desktop)
  "Render DESKTOP's settings with retained tabs and one active field grid."
  :bindings
  ((controller (etaf-prop 'desktop))
   (section (etaf-ref 'appearance))
   (tab-actions
    (mapcar
     (lambda (entry)
       (let ((key (car entry)))
         (cons key (lambda () (etaf-set-value section key)))))
     etaf-desktop--settings-sections))
   (close-settings
    (lambda () (etaf-desktop-close-settings (etaf-value controller))))
   (reset-settings
    (lambda () (etaf-desktop-reset-settings (etaf-value controller)))))
  :render
  (when (etaf-desktop-settings-open-p desktop)
    (etaf-view
     (etaf-dialog
      :open t :title "Desktop Settings" :width '(ch 76)
      :height (let ((active (etaf-value section)))
                (etaf-desktop--settings-height
                 active (etaf-desktop--settings-fields active)))
      :close-label "Done" :on-close close-settings
      (etaf-tabs
       :items (mapcar (lambda (entry)
                        (list :key (car entry)
                              :label (cdr entry)
                              :ref (etaf-desktop--ref
                                    desktop (format "settings-tab-%s" (car entry)))))
                      etaf-desktop--settings-sections)
       :active (etaf-value section)
       :on-change (lambda (key) (funcall (alist-get key tab-actions))))
      (expr (etaf-desktop--settings-grid desktop (etaf-value section)))
      (etaf-label
       :text (pcase (etaf-value section)
               ('layout "Gaps use character widths across and text rows down.")
               ('shortcuts "Keys apply while the desktop is active.")
               (_ "Changes are saved with your desktop session."))
       :variant 'muted)
      (slot :name 'footer
       (etaf-button :label "Reset settings" :variant 'ghost
                    :aria-label "Reset settings" :on-press reset-settings))))))

(defun etaf-desktop--settings-node (desktop)
  "Render DESKTOP's settings through its retained section controller."
  (etaf-node 'etaf-desktop--settings-panel (list :desktop desktop) nil))

(etaf-define-component etaf-desktop--workspace-surface (&key desktop)
  "Keep focus-dependent workspace controls independent of window membership."
  :bindings
  ((controller (etaf-prop 'desktop))
   (status
    (etaf-computed
     (lambda ()
       (let* ((state (etaf-desktop--state (etaf-value controller)))
              (id (etaf-desktop--state-active-window state))
              (window (and id (etaf-desktop--window-for state id))))
         (when window
           (or (etaf-desktop--window-title window) (format "%s" id)))))
     :test #'equal)))
  :render
  (etaf-desktop--workspace-node desktop (etaf-desktop--state desktop) status))

(etaf-define-component etaf-desktop--taskbar-surface (&key desktop)
  "Project taskbar selection independently of the desktop canvas."
  :bindings
  ((controller (etaf-prop 'desktop))
   (active
    (etaf-computed
     (lambda ()
       (let ((desktop (etaf-value controller)))
         (etaf-desktop--taskbar-key
          (etaf-desktop--state-active-window (etaf-desktop--state desktop))
          (plist-get (etaf-value (etaf-desktop--controller-settings-ref desktop))
                     :taskbar-grouping))))
     :test #'equal)))
  :render
  (etaf-desktop--taskbar-node desktop (etaf-desktop--state desktop) active))

(etaf-define-component etaf-desktop--launcher-surface (&key desktop)
  "Project the launcher so opening it re-renders only this surface."
  :render (etaf-desktop--launcher-node desktop))

(etaf-define-component etaf-desktop--switcher-surface (&key desktop)
  "Project switcher focus only while the switcher is visible."
  :render (etaf-desktop--switcher-node desktop (etaf-desktop--state desktop)))

(etaf-define-component etaf-desktop--application (&key desktop)
  "Provide DESKTOP's Theme to the retained shell.

The Theme is a computed source over the settings ref: selecting a theme or
accent repaints the shell through Theme paint slots without re-rendering the
desktop tree.  An open modal dims the painted shell through the shared modal
backdrop.  The configured shortcuts become the shell root's Host `:keys';
only editing a binding re-renders the shell."
  :bindings
  ((theme
    (etaf-computed
     (lambda ()
       (etaf-desktop--theme-for-settings (etaf-desktop--settings desktop)))
     :test #'equal))
   (mode (etaf-desktop--controller-theme-mode-ref
          (etaf-desktop--controller desktop)))
   (appearance
    (etaf-computed
     (lambda () (plist-get (etaf-value theme) :ui-mode))
     :test #'eq))
   (shortcuts
    (etaf-computed
     (lambda () (plist-get (etaf-desktop--settings desktop) :keybindings))
     :test #'equal)))
  :setup
  (progn
    (etaf-theme-provide theme)
    ;; The desktop is the host of every application in its windows, so it
    ;; provides the polarity its theme resolved to; an app that follows
    ;; `etaf-appearance' repaints with the desktop instead of the frame.
    (etaf-appearance-provide appearance)
    ;; A panel's title-bar switch writes the same cell as the settings
    ;; dialog's Theme control, so both repaint the desktop and its windows.
    (etaf-watch mode
                (lambda (mode _old)
                  (unless (equal mode
                                 (plist-get (etaf-desktop--settings desktop)
                                            :theme))
                    (etaf-desktop-set-setting desktop :theme mode)))
                :name 'etaf-desktop-theme-mode)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme theme :mode mode
                            :modes etaf-desktop--surface-modes)))
  :render
  (etaf-node 'etaf-desktop--shell
             (list :desktop desktop
                   :keys (etaf-desktop--shortcut-keys
                          desktop (etaf-value shortcuts)))
             nil))

(etaf-define-component etaf-desktop--shell-frame (&key desktop)
  "Size DESKTOP's shell column and canvas box from its retained canvas size.

The `workspace-bar' slot fills the top row, the `canvas' slot holds the
positioned window layer and the default slot appends the taskbar and modal
surfaces.  Every size read happens inside a Host property binding, so a
window-fitted canvas updates the frame's bound geometry instead of
re-rendering the desktop tree."
  :view
  (column
   ;; The shell width fits the render viewport when one exists: the concrete
   ;; pixel canvas in `etaf-desktop--canvas-width-value' only measures
   ;; application geometry, so no pixel rounding can push a shell row into
   ;; Emacs continuation.  The row count stays explicit so headless renders
   ;; keep canvas-height rows between the workspace bar and the taskbar.
   :width (etaf-desktop--canvas-box-width desktop)
   :height (list 'lh (+ (etaf-desktop--canvas-height-value desktop) 2))
   ;; The desktop surface carries the canvas color behind everything; the
   ;; workspace bar and taskbar set their own background.
   :background-color (etaf-desktop--theme-token :ui-shell-bg)
   :color (etaf-desktop--theme-token :ui-shell-fg)
   :aria-label "ETAF Desktop"
   :help '("Desktop windows share this Emacs buffer; their focused content owns its local commands."
           "Use the launcher, switcher or taskbar to reach a covered window. Viewing help preserves windows and workspaces.")
   ;; Dismissal is a background policy, not a clickable-control affordance.
   :pointer 'arrow
   ;; Presses on shell background and, through capture, on any control close
   ;; the launcher, switcher or settings dialog the press landed outside of.
   ;; Claiming the background press also keeps `mouse-drag-region' from
   ;; setting the mark on the canvas.
   :on-press #'etaf-ui-dismiss-outside-press
   :on-press-capture #'etaf-ui-dismiss-outside-press
   (slot :name 'workspace-bar)
   (box :position 'relative
        :width (etaf-desktop--canvas-box-width desktop)
        :height (list 'lh (etaf-desktop--canvas-height-value desktop))
        :background-color (etaf-desktop--theme-token :ui-canvas-bg)
        :color (etaf-desktop--theme-token :ui-canvas-fg)
        ;; No right border: a row's last piece colours the character the
        ;; display reserves for its truncation glyph, so a right border there
        ;; would tint that column and read as a margin beside the canvas.
        :border-top (etaf-desktop--theme-token
                     :ui-canvas-border
                     (lambda (color) (list '(px 1) 'solid color)))
        :border-left (etaf-desktop--theme-token
                      :ui-canvas-border
                      (lambda (color) (list '(px 1) 'solid color)))
        :border-bottom (etaf-desktop--theme-token
                        :ui-canvas-border
                        (lambda (color) (list '(px 1) 'solid color)))
     (slot :name 'canvas))
   (slot :name 'default)))

(defun etaf-desktop--fit-render-region (desktop)
  "Fit DESKTOP's canvas to the surface its View is rendered into.
Reads `etaf-viewport' and `etaf-display-metrics' reactively, so a desktop
embedded in another application's window keeps filling that window as it is
moved, resized or maximized.  The window keeps one cell clear on each side and
one row at the bottom for its own resize strips.
Return the applied size, or nil before the surface has committed geometry."
  (let ((viewport (etaf-viewport)))
    (when (and (consp viewport)
               (integerp (car viewport)) (> (car viewport) 0)
               (integerp (cdr viewport)) (> (cdr viewport) 3))
      (let* (;; A desktop fills the surface edge to edge like any application
             ;; view: the canvas takes the region's pixel width and every row
             ;; above the taskbar, so the shell's own bar and taskbar are the
             ;; only rows it does not paint windows into.
             (width (car viewport))
             (height (max 8 (- (cdr viewport) 2))))
        ;; An initial canvas renders the first frame at a sane size; once the
        ;; surface is measured the region owns the size.
        (when (or (etaf-desktop--controller-canvas-width desktop)
                  (etaf-desktop--controller-canvas-height desktop))
          (setf (etaf-desktop--controller-canvas-width desktop) nil
                (etaf-desktop--controller-canvas-height desktop) nil))
        (etaf-desktop--apply-canvas desktop width height)))))

(etaf-define-component etaf-desktop--shell (&key desktop)
  "Render DESKTOP as a controlled desktop surface."
  :setup
  (progn
    ;; A desktop embedded in another application's window follows that window
    ;; body: the region's committed size drives its canvas, so resizing or
    ;; maximizing the hosting window reflows this desktop like any application
    ;; whose view fills its window.
    (when (eq (etaf-desktop--controller-fit desktop) 'region)
      (etaf-watch-effect
       (lambda () (etaf-desktop--fit-render-region desktop))))
    ;; Playground mounts the public View directly instead of calling
    ;; `etaf-desktop-mount'; keep the buffer-local shortcut lifecycle at the
    ;; Desktop Component boundary so both consumers behave identically.
    (etaf-on-mounted
     (lambda ()
       ;; Record the owning Runtime for direct View consumers.  Event callbacks
       ;; may run with a different current buffer, so use ETAF's lifecycle
       ;; context rather than relying on `current-buffer'.
       (when-let* ((runtime (etaf-current-runtime)))
         (setf (etaf-desktop--controller-runtime desktop) runtime
               (etaf-desktop--controller-buffer desktop)
               (etaf-runtime-buffer runtime)
               (etaf-desktop--controller-owns-runtime-p desktop) nil
               (etaf-desktop--controller-owns-buffer-p desktop) nil))
       (etaf-desktop--attach-window-fit
        desktop (etaf-desktop--lifecycle-buffer desktop))))
    (etaf-on-unmounted
     (lambda ()
       (etaf-desktop--detach-window-fit
        desktop (etaf-desktop--lifecycle-buffer desktop))
       (when (eq (etaf-desktop--controller-runtime desktop)
                 (etaf-current-runtime))
         (setf (etaf-desktop--controller-runtime desktop) nil
               (etaf-desktop--controller-buffer desktop) nil
               (etaf-desktop--controller-owns-runtime-p desktop) nil
               (etaf-desktop--controller-owns-buffer-p desktop) nil))))
    nil)
  :render
  ;; Every workspace's windows stay in the retained Component tree so their
  ;; child state survives; `etaf-window' projects the controlled hidden,
  ;; minimized and inactive-workspace presentation through retained cells,
  ;; so a workspace switch never re-renders this tree.
  (let* ((state (etaf-desktop--state desktop))
         (windows (etaf-desktop--state-windows state)))
    (etaf-node
     'etaf-desktop--shell-frame
     (list :desktop desktop)
     (list
      (etaf-node 'etaf-desktop--taskbar-surface (list :desktop desktop) nil)
      (etaf-node 'etaf-desktop--launcher-surface (list :desktop desktop) nil)
      (etaf-node 'etaf-desktop--switcher-surface (list :desktop desktop) nil)
      (etaf-desktop--settings-node desktop)
      (etaf-node 'etaf-desktop--close-confirm-surface (list :desktop desktop) nil))
     (list
      (cons 'workspace-bar
            (list (etaf-node 'etaf-desktop--workspace-surface
                             (list :desktop desktop) nil)))
      (cons 'canvas
            (append
             (mapcar (lambda (window) (etaf-desktop--window-node desktop window))
                     windows)
             ;; Tiling dividers are canvas overlays positioned in canvas
             ;; coordinates; their rectangles and visibility are retained
             ;; layout-policy refs, so a floating or inactive workspace keeps
             ;; its hidden divider nodes and a mode toggle or workspace switch
             ;; publishes without re-render.
             (when (fboundp 'etaf-desktop--layout-dividers)
               (mapcan (lambda (workspace)
                         (etaf-desktop--splitter-overlays desktop workspace))
                       (etaf-desktop--state-workspaces state)))))))))

(cl-defun etaf-desktop-create
    (&key (name "*ETAF Desktop*") canvas-width canvas-height fit
          (workspaces '(main)))
  "Create an application desktop with CANVAS-WIDTH and CANVAS-HEIGHT.
WORKSPACES is a nonempty list of stable workspace keys.  The returned desktop
owns its reactive state and does not mount a buffer until `etaf-desktop-mount'.

FIT is nil to follow the Emacs window that displays the desktop, or `region'
to follow the surface its View is rendered into.  Use `region' when an
application embeds `etaf-desktop-view' in one of its windows: the desktop then
keeps filling that window body as it is moved, resized or maximized."
  (unless (and (stringp name) (not (string-empty-p name)))
    (etaf-desktop--fail "Desktop name must be a nonempty string"))
  (unless (memq fit '(nil region))
    (etaf-desktop--fail "Desktop fit must be nil or `region', got %S" fit))
  (when canvas-width (etaf-desktop--number canvas-width "canvas-width" 1))
  (when canvas-height (etaf-desktop--number canvas-height "canvas-height" 8))
  (unless (and (listp workspaces) workspaces
               (not (cl-some #'null workspaces))
               (= (length workspaces) (length (delete-dups (copy-sequence workspaces)))))
    (etaf-desktop--fail "Workspaces must be a nonempty list of unique keys"))
  (let ((controller
         (etaf-desktop--controller-create
          :name name :token (format "d%d" (cl-incf etaf-desktop--next-token))
          :fit fit :canvas-width canvas-width :canvas-height canvas-height
          :state-ref nil)))
    (setf (etaf-desktop--controller-state-ref controller)
          (etaf-ref
           (etaf-desktop--state-create
            :windows nil :workspaces (copy-sequence workspaces)
            :active-workspace-source
            (etaf-ref (car workspaces) :name 'etaf-desktop-workspace :test #'equal)
            :active-window-source (etaf-ref nil :name 'etaf-desktop-focus) :next-z 1)
           :name 'etaf-desktop-state)
          (etaf-desktop--controller-launcher-ref controller)
          (etaf-ref nil :name 'etaf-desktop-launcher-open)
          (etaf-desktop--controller-canvas-size-ref controller)
          (etaf-ref nil :name 'etaf-desktop-canvas-size)
          (etaf-desktop--controller-switcher-ref controller)
          (etaf-ref nil :name 'etaf-desktop-switcher-open)
          (etaf-desktop--controller-settings-ref controller)
          (etaf-ref (etaf-desktop--default-settings)
                    :name 'etaf-desktop-settings)
          (etaf-desktop--controller-settings-open-ref controller)
          (etaf-ref nil :name 'etaf-desktop-settings-open)
          (etaf-desktop--controller-layout-label-ref controller)
          (etaf-ref "Floating" :name 'etaf-desktop-layout-label)
          (etaf-desktop--controller-theme-mode-ref controller)
          (etaf-ref (plist-get (etaf-desktop--default-settings) :theme)
                    :name 'etaf-desktop-theme-mode)
          (etaf-desktop--controller-close-request-ref controller)
          (etaf-ref nil :name 'etaf-desktop-close-request))
    controller))

(defun etaf-desktop-launcher-open-p (desktop)
  "Return non-nil when DESKTOP's application launcher is open."
  (etaf-value (etaf-desktop--controller-launcher-ref
               (etaf-desktop--controller desktop))))

(defun etaf-desktop-toggle-launcher (desktop &optional open)
  "Set DESKTOP's launcher visibility to OPEN and return its new value.
When OPEN is nil, toggle the current value unless an explicit nil is needed;
callers can use `etaf-desktop-close-launcher' to close it unambiguously."
  (let* ((desktop (etaf-desktop--controller desktop))
         (ref (etaf-desktop--controller-launcher-ref desktop))
         (value (if (null open) (not (etaf-value ref)) open)))
    (etaf-set-value ref value)
    value))

(defun etaf-desktop-close-launcher (desktop)
  "Close DESKTOP's application launcher and return nil."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-set-value (etaf-desktop--controller-launcher-ref desktop) nil)
    nil))

(defun etaf-desktop-switcher-open-p (desktop)
  "Return non-nil when DESKTOP's window switcher is open."
  (etaf-value (etaf-desktop--controller-switcher-ref
               (etaf-desktop--controller desktop))))

(defun etaf-desktop-toggle-switcher (desktop &optional open)
  "Set DESKTOP's switcher visibility to OPEN, or toggle it when omitted."
  (let* ((desktop (etaf-desktop--controller desktop))
         (ref (etaf-desktop--controller-switcher-ref desktop))
         (value (if (null open) (not (etaf-value ref)) open)))
    (etaf-set-value ref value)
    value))

(defun etaf-desktop-close-switcher (desktop)
  "Close DESKTOP's window switcher and return nil."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-set-value (etaf-desktop--controller-switcher-ref desktop) nil)
    nil))

(defun etaf-desktop-state (desktop)
  "Return DESKTOP's detached state plist, including windows and workspaces.
The `:token' entry is the namespace of DESKTOP's ETAF Host references."
  (let ((desktop (etaf-desktop--controller desktop))
        (state (etaf-desktop--state desktop)))
    (list :name (etaf-desktop--controller-name desktop)
          ;; The token namespaces this desktop's ETAF Host references, so a
          ;; desktop embedded in another one keeps its own controls addressable.
          :token (etaf-desktop--controller-token desktop)
          :canvas-width (etaf-desktop--canvas-width-value desktop)
          :canvas-height (etaf-desktop--canvas-height-value desktop)
          :settings (etaf-desktop-settings desktop)
          :active-workspace (etaf-desktop--state-active-workspace state)
          :active-window (etaf-desktop--state-active-window state)
          :workspaces (copy-sequence (etaf-desktop--state-workspaces state))
          :windows (mapcar #'etaf-desktop--window-plist
                           (etaf-desktop--state-windows state)))))

(defun etaf-desktop-windows (desktop)
  "Return DESKTOP's windows as detached plists in z-order insertion order."
  (plist-get (etaf-desktop-state desktop) :windows))

(defun etaf-desktop-window-state (desktop id)
  "Return a detached state plist for window ID in DESKTOP."
  (let ((window (etaf-desktop--window-for (etaf-desktop--state (etaf-desktop--controller desktop)) id)))
    (or (and window (etaf-desktop--window-plist window))
        (etaf-desktop--fail "Unknown desktop window: %S" id))))

(defun etaf-desktop-active-window (desktop)
  "Return the active window ID of DESKTOP, or nil."
  (etaf-desktop--state-active-window
   (etaf-desktop--state (etaf-desktop--controller desktop))))

(defun etaf-desktop-active-workspace (desktop)
  "Return DESKTOP's active workspace key."
  (etaf-desktop--state-active-workspace
   (etaf-desktop--state (etaf-desktop--controller desktop))))

(cl-defun etaf-desktop-open-window
    (desktop id &key title view (x 0) (y 0) (width 400) (height 12)
          (min-width 160) (min-height 3) max-width max-height workspace
          (visible t) (movable t) (resizable t))
  "Open window ID in DESKTOP and return its public state plist.
VIEW is an ETAF View created by `etaf-view' or nil for a text placeholder.
Geometry and size limits are logical desktop units; callers retain VIEW.
WORKSPACE defaults to the active workspace."
  (let ((desktop (etaf-desktop--controller desktop)))
    (etaf-desktop--number x "x" 0)
    (etaf-desktop--number y "y" 0)
    (etaf-desktop--number width "width" min-width)
    (etaf-desktop--number height "height" min-height)
    (etaf-desktop--number min-width "min-width" 1)
    (etaf-desktop--number min-height "min-height" 1)
    (when max-width (etaf-desktop--number max-width "max-width" min-width))
    (when max-height (etaf-desktop--number max-height "max-height" min-height))
    (etaf-desktop--update
     desktop
     (lambda (state)
       (when (etaf-desktop--window-for state id)
         (etaf-desktop--fail "Desktop window already exists: %S" id))
       (let ((workspace (or workspace (etaf-desktop--state-active-workspace state))))
         (etaf-desktop--assert-workspace state workspace)
         (let ((window
                (etaf-desktop--window-create
                 :id id :title title :view view :x-source x :y-source y
                 :width-source width :height-source height
                 :min-width min-width :min-height min-height :max-width max-width
                 :max-height max-height :visible-source visible
                 :minimized-source nil :maximized-source nil :workspace-source workspace
                 :normal-geometry (list x y width height)
                 :z-index-source (etaf-desktop--state-next-z state)
                 :movable movable :resizable resizable)))
           (push window (etaf-desktop--state-windows state))
           (setf (etaf-desktop--state-next-z state)
                 (1+ (etaf-desktop--state-next-z state)))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window)))))))

(defun etaf-desktop--highest-visible-window (state workspace)
  "Return the highest visible, non-minimized window in WORKSPACE."
  (car
   (sort
    (cl-remove-if-not
     (lambda (candidate)
       (and (equal workspace (etaf-desktop--window-workspace candidate))
            (etaf-desktop--window-visible candidate)
            (not (etaf-desktop--window-minimized candidate))))
     (copy-sequence (etaf-desktop--state-windows state)))
    (lambda (left right)
      (> (etaf-desktop--window-z-index left)
         (etaf-desktop--window-z-index right))))))

(defun etaf-desktop-close-window (desktop id)
  "Close window ID in DESKTOP and return non-nil when it existed.

When the active window is removed, the highest visible window in the same
workspace becomes active so closing a window never leaves the desktop without
a focused target while other windows remain available."
  (let* ((desktop (etaf-desktop--controller desktop))
         (was-active (equal id (etaf-desktop-active-window desktop)))
         (result
          (etaf-desktop--update
           desktop
           (lambda (state)
             (let ((window (etaf-desktop--window-for state id)))
               (if (not window)
                   nil
                 (let ((workspace (etaf-desktop--window-workspace window))
                       (was-active
                        (equal id (etaf-desktop--state-active-window state))))
                   (setf (etaf-desktop--state-windows state)
                         (delq window (etaf-desktop--state-windows state)))
                   (when was-active
                     (let ((replacement
                            (etaf-desktop--highest-visible-window state workspace)))
                       (setf (etaf-desktop--state-active-window state)
                             (and replacement
                                  (etaf-desktop--window-id replacement)))))
                   t)))))))
    (when result
      (etaf-desktop--notify-window-event desktop id 'closed)
      (when was-active
        (if-let* ((replacement-id (etaf-desktop-active-window desktop)))
            (etaf-desktop--notify-window-event desktop replacement-id 'focused)
          (etaf-desktop--notify-window-event desktop nil 'focus-cleared))))
    result))

(defun etaf-desktop-focus-window (desktop id)
  "Focus and raise window ID, switching to its workspace.
A visible window raises through retained cells; when it lives in another
workspace, the active-workspace cell and layout label switch in the same
batch and that workspace's layout is refreshed.  A hidden or minimized
window republishes desktop structure."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id))
         (switching (and window
                         (not (etaf-desktop--active-workspace-window-p
                               state window))))
         (result
          (if (and window (etaf-desktop--retained-focus-p state window))
              (prog1 (etaf-call-with-batch
                      (lambda ()
                        (prog1 (funcall (etaf-desktop--window-focus-writer window))
                          (when switching
                            (etaf-desktop--sync-layout-label desktop)))))
                (when (and switching (fboundp 'etaf-desktop-layout-refresh))
                  (etaf-desktop-layout-refresh desktop)))
            (etaf-desktop--update
             desktop
             (lambda (state)
               (let ((window (etaf-desktop--window-for state id)))
                 (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
                 (setf (etaf-desktop--window-minimized window) nil
                       (etaf-desktop--window-visible window) t)
                 (etaf-desktop--raise state window)
                 id))))))
    (etaf-desktop--notify-window-event desktop id 'focused)
    result))

(defun etaf-desktop-move-window (desktop id x y)
  "Move window ID to X and Y, returning its public state plist.
X may be negative and X or Y may exceed the canvas: the canvas clips the
overflow while `etaf-desktop--reachable-position' keeps part of the window
and its title row inside the canvas, so a drag past an edge never fails."
  (unless (integerp x)
    (etaf-desktop--fail "x must be an integer, got %S" x))
  (unless (integerp y)
    (etaf-desktop--fail "y must be an integer, got %S" y))
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id)))
    (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
    (cond
     ((etaf-desktop--tiled-window-p desktop window)
      (etaf-desktop--focus-tiled-window desktop state window))
     ((etaf-desktop--floating-window-p desktop state window)
      (pcase-let ((`(,x . ,y) (etaf-desktop--reachable-position
                              desktop x y (etaf-desktop--window-width window))))
        (etaf-desktop--write-geometry
         window x y (etaf-desktop--window-width window)
         (etaf-desktop--window-height window))))
     (t
      (etaf-desktop--update
       desktop
       (lambda (state)
         (let ((window (etaf-desktop--window-for state id)))
           (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
           (when (etaf-desktop--window-maximized window)
             (setf (etaf-desktop--window-x window) (nth 0 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-y window) (nth 1 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-width window) (nth 2 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-height window) (nth 3 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-maximized window) nil))
           (pcase-let ((`(,fit-x . ,fit-y)
                        (etaf-desktop--reachable-position
                         desktop x y (etaf-desktop--window-width window))))
             (setq x fit-x y fit-y))
           (setf (etaf-desktop--window-x window) x
                 (etaf-desktop--window-y window) y
                 (etaf-desktop--window-normal-geometry window)
                 (list x y (etaf-desktop--window-width window) (etaf-desktop--window-height window)))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window))))))))

(defun etaf-desktop--set-window-geometry (desktop id x y width height)
  "Commit one atomic geometry update for window ID.
X, Y, WIDTH and HEIGHT are logical desktop units.  This internal path is used
by combined edge and corner resize Behaviors so a left/top resize publishes
its position and size together." 
  ;; A left drag may cross the canvas origin: the window overflows and the
  ;; canvas clips it.  A top drag stops at the canvas top and preserves the
  ;; bottom edge, since clamping only Y would grow the window past it.
  (when (< y 0)
    (setq height (+ height y)
          y 0))
  (unless (integerp x)
    (etaf-desktop--fail "x must be an integer, got %S" x))
  (etaf-desktop--number y "y" 0)
  (etaf-desktop--number width "width" 1)
  (etaf-desktop--number height "height" 1)
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id)))
    (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
    (unless (etaf-desktop--window-resizable window)
      (etaf-desktop--fail "Desktop window is not resizable: %S" id))
    (cond
     ((and (= x (etaf-desktop--window-x window))
           (= y (etaf-desktop--window-y window))
           (= width (etaf-desktop--window-width window))
           (= height (etaf-desktop--window-height window)))
      (etaf-desktop--window-plist window))
     ((etaf-desktop--tiled-window-p desktop window)
      (etaf-desktop--focus-tiled-window desktop state window))
     ((etaf-desktop--floating-window-p desktop state window)
        (etaf-desktop--write-geometry
         window x y
         (etaf-desktop--clamp width (etaf-desktop--window-min-width window)
                              (etaf-desktop--window-max-width window))
         (etaf-desktop--clamp height (etaf-desktop--window-min-height window)
                              (etaf-desktop--window-max-height window))))
     (t
      (etaf-desktop--update
       desktop
       (lambda (state)
         (let ((window (etaf-desktop--window-for state id)))
           (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
           (unless (etaf-desktop--window-resizable window)
             (etaf-desktop--fail "Desktop window is not resizable: %S" id))
           (when (etaf-desktop--window-maximized window)
             (setf (etaf-desktop--window-maximized window) nil))
           (setq width (etaf-desktop--clamp width
                                            (etaf-desktop--window-min-width window)
                                            (etaf-desktop--window-max-width window))
                 height (etaf-desktop--clamp height
                                             (etaf-desktop--window-min-height window)
                                             (etaf-desktop--window-max-height window)))
           (setf (etaf-desktop--window-x window) x
                 (etaf-desktop--window-y window) y
                 (etaf-desktop--window-width window) width
                 (etaf-desktop--window-height window) height
                 (etaf-desktop--window-normal-geometry window)
                 (list x y width height))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window))))))))

(defun etaf-desktop-resize-window (desktop id width height)
  "Resize window ID to WIDTH and HEIGHT, respecting its size limits."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id)))
    (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
    (unless (etaf-desktop--window-resizable window)
      (etaf-desktop--fail "Desktop window is not resizable: %S" id))
    (cond
     ((etaf-desktop--tiled-window-p desktop window)
      (etaf-desktop--focus-tiled-window desktop state window))
     ((etaf-desktop--floating-window-p desktop state window)
        (etaf-desktop--write-geometry
         window (etaf-desktop--window-x window)
         (etaf-desktop--window-y window)
         (etaf-desktop--clamp width (etaf-desktop--window-min-width window)
                              (etaf-desktop--window-max-width window))
         (etaf-desktop--clamp height (etaf-desktop--window-min-height window)
                              (etaf-desktop--window-max-height window))))
     (t
      (etaf-desktop--update
       desktop
       (lambda (state)
         (let ((window (etaf-desktop--window-for state id)))
           (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
           (unless (etaf-desktop--window-resizable window)
             (etaf-desktop--fail "Desktop window is not resizable: %S" id))
           (when (etaf-desktop--window-maximized window)
             (setf (etaf-desktop--window-x window) (nth 0 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-y window) (nth 1 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-width window) (nth 2 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-height window) (nth 3 (etaf-desktop--window-normal-geometry window))
                   (etaf-desktop--window-maximized window) nil))
           (setf width (etaf-desktop--clamp width (etaf-desktop--window-min-width window)
                                            (etaf-desktop--window-max-width window))
                 height (etaf-desktop--clamp height (etaf-desktop--window-min-height window)
                                             (etaf-desktop--window-max-height window))
                 (etaf-desktop--window-width window) width
                 (etaf-desktop--window-height window) height
                 (etaf-desktop--window-normal-geometry window)
                 (list (etaf-desktop--window-x window) (etaf-desktop--window-y window)
                       width height))
           (etaf-desktop--raise state window)
           (etaf-desktop--window-plist window))))))))

(defun etaf-desktop--maximize-window (desktop state window)
  "Maximize retained or detached WINDOW of STATE onto DESKTOP's canvas."
  (unless (etaf-desktop--window-maximized window)
    (apply #'etaf-desktop--store-normal-geometry window
           (etaf-desktop--geometry window)))
  (setf (etaf-desktop--window-x window) 0
        (etaf-desktop--window-y window) 0
        (etaf-desktop--window-width window)
        (etaf-desktop--canvas-width-value desktop)
        (etaf-desktop--window-height window)
        (etaf-desktop--canvas-height-value desktop)
        (etaf-desktop--window-minimized window) nil
        (etaf-desktop--window-visible window) t
        (etaf-desktop--window-maximized window) t)
  (etaf-desktop--raise state window))

(defun etaf-desktop-maximize-window (desktop id)
  "Maximize window ID to DESKTOP's canvas and remember its geometry."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id)))
    (if (and window (etaf-desktop--active-workspace-window-p state window))
        (etaf-desktop--write-mode
         desktop state window
         (lambda () (etaf-desktop--maximize-window desktop state window)))
      (etaf-desktop--update
       desktop
       (lambda (state)
         (let ((window (etaf-desktop--window-for state id)))
           (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
           (etaf-desktop--maximize-window desktop state window)
           (etaf-desktop--window-plist window)))))))

(defun etaf-desktop--minimize-window (state window)
  "Minimize WINDOW of STATE and pass focus to the highest remaining window."
  (setf (etaf-desktop--window-minimized window) t
        (etaf-desktop--window-visible window) nil)
  (when (equal (etaf-desktop--window-id window)
               (etaf-desktop--state-active-window state))
    (let ((replacement
           (etaf-desktop--highest-visible-window
            state (etaf-desktop--window-workspace window))))
      (setf (etaf-desktop--state-active-window state)
            (and replacement (etaf-desktop--window-id replacement))))))

(defun etaf-desktop-minimize-window (desktop id)
  "Minimize window ID into DESKTOP's taskbar."
  (let* ((desktop (etaf-desktop--controller desktop))
         (was-active (equal id (etaf-desktop-active-window desktop)))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id))
         (result
          (if (and window (etaf-desktop--active-workspace-window-p state window))
              (etaf-desktop--write-mode
               desktop state window
               (lambda () (etaf-desktop--minimize-window state window)))
            (etaf-desktop--update
             desktop
             (lambda (state)
               (let ((window (etaf-desktop--window-for state id)))
                 (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
                 (etaf-desktop--minimize-window state window)
                 (etaf-desktop--window-plist window)))))))
    (etaf-desktop--notify-window-event desktop id 'minimized)
    (when was-active
      (if-let* ((replacement-id (etaf-desktop-active-window desktop)))
          (etaf-desktop--notify-window-event desktop replacement-id 'focused)
        (etaf-desktop--notify-window-event desktop nil 'focus-cleared)))
    result))

(defun etaf-desktop--restore-window (state window)
  "Restore WINDOW of STATE from its minimized or maximized presentation."
  (when (etaf-desktop--window-maximized window)
    (pcase-let ((`(,x ,y ,width ,height)
                 (etaf-desktop--window-normal-geometry window)))
      (setf (etaf-desktop--window-x window) x
            (etaf-desktop--window-y window) y
            (etaf-desktop--window-width window) width
            (etaf-desktop--window-height window) height)))
  (setf (etaf-desktop--window-maximized window) nil
        (etaf-desktop--window-minimized window) nil
        (etaf-desktop--window-visible window) t)
  (etaf-desktop--raise state window))

(defun etaf-desktop-restore-window (desktop id)
  "Restore minimized or maximized window ID and focus it."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop))
         (window (etaf-desktop--window-for state id))
         (result
          (if (and window (etaf-desktop--active-workspace-window-p state window))
              (etaf-desktop--write-mode
               desktop state window
               (lambda () (etaf-desktop--restore-window state window)))
            (etaf-desktop--update
             desktop
             (lambda (state)
               (let ((window (etaf-desktop--window-for state id)))
                 (unless window (etaf-desktop--fail "Unknown desktop window: %S" id))
                 (etaf-desktop--restore-window state window)
                 (etaf-desktop--window-plist window)))))))
    (etaf-desktop--notify-window-event desktop id 'restored)
    result))

(defun etaf-desktop-window-maximized-p (desktop id)
  "Return non-nil when window ID is maximized."
  (etaf-desktop--window-maximized
   (or (etaf-desktop--window-for (etaf-desktop--state desktop) id)
       (etaf-desktop--fail "Unknown desktop window: %S" id))))

(defun etaf-desktop-switch-workspace (desktop workspace)
  "Make WORKSPACE the active desktop workspace.
The switch writes the retained active-workspace, active-window and layout
label cells in one batch: every workspace's windows and dividers stay
mounted and follow through bound visibility, so no desktop structure is
republished.  Focus passes to WORKSPACE's highest visible window."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop--state desktop)))
    (etaf-desktop--assert-workspace state workspace)
    (let ((replacement (etaf-desktop--highest-visible-window state workspace)))
      (etaf-call-with-batch
       (lambda ()
         (setf (etaf-desktop--state-active-workspace state) workspace
               (etaf-desktop--state-active-window state)
               (and replacement (etaf-desktop--window-id replacement)))
         (etaf-set-value (etaf-desktop--controller-layout-label-ref desktop)
                         (etaf-desktop--layout-label desktop workspace)))))
    (when (fboundp 'etaf-desktop-layout-refresh)
      (etaf-desktop-layout-refresh desktop workspace))
    (if-let* ((active (etaf-desktop-active-window desktop)))
        (etaf-desktop--notify-window-event desktop active 'focused)
      (etaf-desktop--notify-window-event desktop nil 'focus-cleared))
    workspace))

(defun etaf-desktop-add-workspace (desktop workspace)
  "Add WORKSPACE to DESKTOP and return its key."
  (etaf-desktop--update
   desktop
   (lambda (state)
     (when (or (null workspace) (etaf-desktop--workspace-present-p state workspace))
       (etaf-desktop--fail "Workspace already exists or is nil: %S" workspace))
     (setf (etaf-desktop--state-workspaces state)
           (append (etaf-desktop--state-workspaces state) (list workspace)))
     workspace)))

(defun etaf-desktop-remove-workspace (desktop workspace)
  "Remove WORKSPACE, moving its windows to another remaining workspace."
  (let* ((desktop (etaf-desktop--controller desktop))
         (was-active (equal workspace (etaf-desktop-active-workspace desktop)))
         (result
          (etaf-desktop--update
           desktop
           (lambda (state)
             (when (= (length (etaf-desktop--state-workspaces state)) 1)
               (etaf-desktop--fail "Cannot remove the last desktop workspace"))
             (etaf-desktop--assert-workspace state workspace)
             (let ((replacement
                    (car (delete workspace
                                 (copy-sequence
                                  (etaf-desktop--state-workspaces state))))))
               (dolist (window (etaf-desktop--state-windows state))
                 (when (equal (etaf-desktop--window-workspace window) workspace)
                   (setf (etaf-desktop--window-workspace window) replacement)))
               (setf (etaf-desktop--state-workspaces state)
                     (delete workspace (etaf-desktop--state-workspaces state)))
               (when (equal workspace (etaf-desktop--state-active-workspace state))
                 (let ((replacement-window
                        (etaf-desktop--highest-visible-window state replacement)))
                   (setf (etaf-desktop--state-active-workspace state) replacement
                         (etaf-desktop--state-active-window state)
                         (and replacement-window
                              (etaf-desktop--window-id replacement-window)))))
               replacement)))))
    (when was-active
      (if-let* ((replacement-id (etaf-desktop-active-window desktop)))
          (etaf-desktop--notify-window-event desktop replacement-id 'focused)
        (etaf-desktop--notify-window-event desktop nil 'focus-cleared)))
    result))

(defvar-local etaf-desktop--buffer-desktops nil
  "Desktops whose shells are mounted in the current buffer.
Applications embed a desktop in a window of another desktop, so one buffer
can hold the outer desktop and every desktop nested in its windows.  Each of
them follows the Emacs window that displays the buffer.")

(defvar etaf-desktop--fit-pending nil
  "Desktops whose displaying Emacs window changed size, deduplicated by EQ.")

(defvar etaf-desktop--fit-timer nil
  "The single owned task scheduled to refit pending desktops.")

(defun etaf-desktop--attach-window-fit (desktop buffer)
  "Let BUFFER's Emacs window size changes refit DESKTOP's canvas.
A nested desktop joins the buffer it is embedded in without displacing the
enclosing desktop that fit the same window first."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq etaf-desktop--buffer-desktops
            (cons desktop (delq desktop etaf-desktop--buffer-desktops))))))

(defun etaf-desktop--detach-window-fit (desktop buffer)
  "Stop refitting DESKTOP from BUFFER's Emacs window size changes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq etaf-desktop--buffer-desktops
            (delq desktop etaf-desktop--buffer-desktops))))
  (setq etaf-desktop--fit-pending (delq desktop etaf-desktop--fit-pending)))

(defun etaf-desktop--display-window (desktop)
  "Return the live Emacs window displaying DESKTOP's mounted buffer, or nil."
  (when-let* ((buffer (etaf-desktop--controller-buffer desktop))
              ((buffer-live-p buffer)))
    (get-buffer-window buffer t)))

(defun etaf-desktop--fit-floating-window (desktop window width height)
  "Keep floating WINDOW of DESKTOP reachable on a WIDTH by HEIGHT canvas.
A window larger than the canvas shrinks to fit it, then its position keeps
part of the window and its title row inside the canvas; its normal rectangle
follows so leaving maximization restores a reachable one."
  (let* ((new-width (etaf-desktop--clamp
                     (min (etaf-desktop--window-width window) width)
                     (etaf-desktop--window-min-width window)
                     (etaf-desktop--window-max-width window)))
         (new-height (etaf-desktop--clamp
                      (min (etaf-desktop--window-height window) height)
                      (etaf-desktop--window-min-height window)
                      (etaf-desktop--window-max-height window)))
         (position (etaf-desktop--reachable-position
                    desktop (etaf-desktop--window-x window)
                    (etaf-desktop--window-y window) new-width))
         (new-x (car position))
         (new-y (cdr position)))
    (unless (equal (list new-x new-y new-width new-height)
                   (etaf-desktop--geometry window))
      (etaf-desktop--place-window window new-x new-y new-width new-height))))

(defun etaf-desktop-fit-canvas (desktop &optional window)
  "Fit DESKTOP's default canvas to the Emacs WINDOW displaying it.

WINDOW defaults to the live window showing DESKTOP's mounted buffer.  A
desktop created with an explicit canvas width and height keeps that geometry.
When the fitted `(WIDTH . HEIGHT)' changes, the shell frame follows through
retained bindings, every tiled and monocle workspace reflows, maximized
windows refill the canvas and floating windows on every workspace are kept
inside it, all in one batch.
Return the fitted size, or nil when nothing changed.

The desktop calls this itself from Emacs' window size hooks; consumers call
it after resizing a window outside the redisplay cycle, for example in batch
Emacs."
  (let* ((desktop (etaf-desktop--controller desktop))
         (window (or window (etaf-desktop--display-window desktop))))
    (when (and (window-live-p window)
               (memq (etaf-desktop--controller-fit desktop) '(nil window))
               (not (and (etaf-desktop--controller-canvas-width desktop)
                         (etaf-desktop--controller-canvas-height desktop))))
      (let ((size (etaf-desktop--window-canvas-size window)))
        (etaf-desktop--apply-canvas desktop (car size) (cdr size))))))

(defun etaf-desktop--apply-canvas (desktop width height)
  "Resize DESKTOP's canvas to WIDTH pixels by HEIGHT rows and reflow it.
Return the applied `(WIDTH . HEIGHT)', or nil when it already holds that size."
  (let* ((desktop (etaf-desktop--controller desktop))
         (ref (etaf-desktop--controller-canvas-size-ref desktop))
         (size (cons width height)))
    (when (and ref (not (equal size (etaf-value ref))))
      (let ((state (etaf-desktop--state desktop)))
        (etaf-call-with-batch
         (lambda ()
           (etaf-set-value ref size)
           ;; Every workspace shares the one canvas, so windows parked on
           ;; inactive workspaces refit now rather than reappearing off-canvas
           ;; when their workspace is switched to later.
           (let ((width (etaf-desktop--canvas-width-value desktop))
                 (height (etaf-desktop--canvas-height-value desktop)))
             (dolist (window (etaf-desktop--state-windows state))
               (cond
                ((etaf-desktop--window-maximized window)
                 (setf (etaf-desktop--window-x window) 0
                       (etaf-desktop--window-y window) 0
                       (etaf-desktop--window-width window) width
                       (etaf-desktop--window-height window) height))
                ((not (etaf-desktop--tiled-window-p desktop window))
                 (etaf-desktop--fit-floating-window
                  desktop window width height)))))
           ;; The layout's own batch joins this one, so the frame, the windows
           ;; and the dividers publish in a single projection.
           (when (fboundp 'etaf-desktop-layout-refresh)
             (dolist (workspace (etaf-desktop--state-workspaces state))
               (etaf-desktop-layout-refresh desktop workspace))))))
      size)))

(defun etaf-desktop--transient-space-borrowed-p (desktop window)
  "Whether WINDOW is shorter because transient UI borrows its lines.
The committed rows are the fitted canvas height plus the workspace bar and
taskbar rows `etaf-desktop-fit-canvas' adds on top of it; a desktop with an
explicit canvas keeps that geometry anyway."
  (let* ((ref (etaf-desktop--controller-canvas-size-ref desktop))
         (canvas (and ref (etaf-value ref))))
    (and canvas
         (etaf-transient-space-borrowed-p window (+ 2 (cdr canvas))))))

(defun etaf-desktop--fit-pending-desktops ()
  "Refit every desktop whose Emacs window changed size since the last task.
A borrowed minibuffer keeps the committed canvas until the prompt closes."
  (let ((desktops (nreverse etaf-desktop--fit-pending))
        first-error)
    (setq etaf-desktop--fit-pending nil
          etaf-desktop--fit-timer nil)
    (dolist (desktop desktops)
      (let ((window (etaf-desktop--display-window desktop)))
        (when (and window
                   (not (etaf-desktop--transient-space-borrowed-p desktop window)))
          (condition-case failure
              (etaf-desktop-fit-canvas desktop)
            (error (unless first-error (setq first-error failure)))))))
    (when first-error (signal (car first-error) (cdr first-error)))))

(defun etaf-desktop--window-size-change (frame)
  "Record desktops displayed in FRAME for a refit after this redisplay hook."
  (when (frame-live-p frame)
    (dolist (window (window-list frame 'no-minibuf))
      (dolist (desktop (buffer-local-value 'etaf-desktop--buffer-desktops
                                           (window-buffer window)))
        (when (and (etaf-desktop--controller-p desktop)
                   (memq (etaf-desktop--controller-fit desktop) '(nil window))
                   (not (memq desktop etaf-desktop--fit-pending)))
          (push desktop etaf-desktop--fit-pending))))
    (when (and etaf-desktop--fit-pending (null etaf-desktop--fit-timer))
      (setq etaf-desktop--fit-timer
            (run-at-time 0 nil #'etaf-desktop--fit-pending-desktops)))))

(add-hook 'window-size-change-functions #'etaf-desktop--window-size-change)
;; This also restores a window after it switches away from a Desktop image.

(defun etaf-desktop-view (desktop)
  "Return the root View for DESKTOP without mounting it."
  (etaf-desktop--controller desktop)
  (etaf-view (etaf-desktop--application :desktop desktop)))

(defun etaf-desktop-mount (desktop &optional buffer-or-name)
  "Mount DESKTOP into BUFFER-OR-NAME and return the buffer.
When BUFFER-OR-NAME is nil, DESKTOP's configured name is used.  A desktop
without explicit canvas dimensions measures the window that will display it,
so it fills the visible Emacs window body.  A desktop can be mounted once;
callers use `etaf-desktop-close' to release the Runtime.
The surface hides the native cursor on images, preserving text navigation."
  (let* ((desktop (etaf-desktop--controller desktop))
         (name (or buffer-or-name (etaf-desktop--controller-name desktop)))
         (target (get-buffer name)))
    (when (etaf-desktop--controller-runtime desktop)
      (etaf-desktop--fail "Desktop is already mounted"))
    ;; A desktop without explicit dimensions fills the window that displays
    ;; it.  The first render happens inside `etaf-mount', before the mounted
    ;; buffer is recorded, so measure the target window for that render and
    ;; re-apply the layout once the display settles.
    (let* ((mount-target (or target (get-buffer-create name)))
           (mount-window (get-buffer-window mount-target))
           (old-mode-line (buffer-local-value 'mode-line-format mount-target))
           (old-header-line (buffer-local-value 'header-line-format mount-target))
           ;; Window measurements must already describe the chrome-free
           ;; Desktop before its first View is evaluated.  Otherwise the first
           ;; state update grows the canvas by the retired mode-line row.
           (_ (with-current-buffer mount-target
                (setq-local mode-line-format nil header-line-format nil)))
           (buffer (condition-case error-data
                       (let ((etaf-desktop--mount-window mount-window))
                         (etaf-mount mount-target (etaf-desktop-view desktop)))
                     (error
                      (with-current-buffer mount-target
                        (setq-local mode-line-format old-mode-line
                                    header-line-format old-header-line))
                      (unless target (kill-buffer mount-target))
                      (signal (car error-data) (cdr error-data)))))
           (runtime (etaf-runtime-for-buffer buffer)))
      ;; The mounted desktop owns the complete Emacs window body.  Hiding the
      ;; buffer mode line avoids an extra application-looking row below the
      ;; taskbar; status and app actions are projected by the desktop shell.
      (with-current-buffer buffer
        (setq-local mode-line-format nil
                    header-line-format nil
                    etaf-cursor-follows-input-modality t)
        (add-hook 'kill-buffer-hook
                  (lambda ()
                    (when (fboundp 'etaf-desktop--close-all-instances)
                      (etaf-desktop--close-all-instances desktop 'desktop-close)))
                  nil t))
      (setf (etaf-desktop--controller-buffer desktop) buffer
            (etaf-desktop--controller-runtime desktop) runtime
            (etaf-desktop--controller-owns-runtime-p desktop) t
            (etaf-desktop--controller-owns-buffer-p desktop) (not target))
      ;; Displaying a buffer can resize its window after the first render.
      ;; Fit the default canvas to the settled window so the shell, the
      ;; layout and the retained canvas-size cell match it; the buffer may
      ;; only be displayed after the mount, so this does not depend on the
      ;; display window being known here.
      (when (and (null (etaf-desktop--controller-canvas-width desktop))
                 (null (etaf-desktop--controller-canvas-height desktop)))
        (setf (etaf-desktop--controller-fit-timer desktop)
              (run-at-time
               0.2 nil
               (lambda ()
                 (setf (etaf-desktop--controller-fit-timer desktop) nil)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (unless (etaf-desktop-fit-canvas desktop)
                       (etaf-desktop-layout-refresh desktop))))))))
      buffer)))

(defun etaf-desktop-close (desktop)
  "Release DESKTOP's mounted surface and return nil.
Only a Runtime created by `etaf-desktop-mount' is unmounted, and only a buffer
created by that call is killed.  Direct `etaf-desktop-view' consumers own their
Runtime and buffer.  Closing is idempotent."
  (let ((desktop (etaf-desktop--controller desktop))
        (runtime (etaf-desktop--controller-runtime desktop))
        (buffer (etaf-desktop--controller-buffer desktop))
        (owns-runtime (etaf-desktop--controller-owns-runtime-p desktop))
        (owns-buffer (etaf-desktop--controller-owns-buffer-p desktop)))
    (when-let* ((timer (etaf-desktop--controller-fit-timer desktop)))
      (cancel-timer timer)
      (setf (etaf-desktop--controller-fit-timer desktop) nil))
    (when (fboundp 'etaf-desktop--close-all-instances)
      (etaf-desktop--close-all-instances desktop 'desktop-close))
    (when owns-runtime
      (when runtime (etaf-unmount runtime))
      (when (and owns-buffer (buffer-live-p buffer))
        (kill-buffer buffer))
      (setf (etaf-desktop--controller-runtime desktop) nil
            (etaf-desktop--controller-buffer desktop) nil
            (etaf-desktop--controller-owns-runtime-p desktop) nil
            (etaf-desktop--controller-owns-buffer-p desktop) nil))
    nil))

(defun etaf-desktop-open (&optional desktop buffer-or-name)
  "Create and mount DESKTOP, returning the desktop controller.
When DESKTOP is nil, create a default desktop.  Interactive calls display its
buffer in the selected Emacs window, without splitting or deleting windows;
applications may then use the window/workspace mutation APIs."
  (interactive)
  (let* ((desktop (or desktop (etaf-desktop-create)))
         (buffer (etaf-desktop-mount desktop buffer-or-name)))
    (when (called-interactively-p 'interactive)
      (let ((display-buffer-overriding-action '((display-buffer-same-window))))
        (pop-to-buffer buffer)))
    desktop))

(provide 'etaf-desktop-runtime)
;;; etaf-desktop-runtime.el ends here
