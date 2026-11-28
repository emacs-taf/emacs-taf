;;; performance-scenarios.el --- ETAF Desktop interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; The workspace performance driver owns sampling, settlement and diagnostics.
;; The geometry/policy workloads keep four text windows in the active workspace.
;; The demo workloads use the complete application demo and its live Clock.
;; A sample
;; performs one real public operation; its precondition is restored and flushed
;; before timing, and its publication is flushed inside the timed operation.
;; Geometry alternates direction so long sample sets never reach size limits.
;; A GUI fixture mounts a default desktop and fits it to the benchmark window,
;; exactly as a user's desktop fills its Emacs window; batch Emacs has no
;; graphical window, so it uses a fixed canvas the size of a full-width frame.
;; Window placement, drag expectations and the environment probe derive from
;; the fitted canvas, so a frame resized between runs is recorded, not hidden.
;; Native GUI sequences use real rendered targets and prequeued Emacs mouse
;; events: eight motions for a sequence and 130 for a burst.  The distinct
;; release endpoint must be published after all pending motions are consumed.
;; These synthetic sequences do not measure paced hardware input or physical
;; pointer-to-presentation latency.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'ebox)
(require 'etaf-desktop)

(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-desktop-benchmark--ids
  '(desktop-one desktop-two desktop-three desktop-four))

(defconst etaf-desktop-benchmark--batch-canvas '(1421 . 49)
  "Canvas for batch Emacs, which has no graphical window to fit.
It equals a default desktop filling a 1440 px wide frame with 7 px characters
and a 51-row body, so batch workloads render as much as a full GUI window.")

(defun etaf-desktop-benchmark--window-geometry (canvas index)
  "Return the (X Y WIDTH HEIGHT) of window INDEX on a two-by-two grid of CANVAS.
CANVAS is `(WIDTH . HEIGHT)' in pixels and text rows.  Every window keeps a
gutter to the canvas edges and its neighbours so moves and resizes in either
direction stay inside the canvas without touching another window."
  (let* ((column (/ (car canvas) 2))
         (row (/ (1- (cdr canvas)) 2))
         (gutter (max 8 (round (/ (car canvas) 45.0)))))
    (list (+ gutter (* column (mod index 2)))
          (+ 1 (* row (/ index 2)))
          (max 120 (- column (* 2 gutter)))
          (max 5 (- row 2)))))

(defun etaf-desktop-benchmark--open-window (desktop id index workspace canvas)
  "Open text window ID at grid INDEX of CANVAS in DESKTOP's WORKSPACE."
  (pcase-let ((`(,x ,y ,width ,height)
               (etaf-desktop-benchmark--window-geometry canvas index)))
    (etaf-desktop-open-window
     desktop id :workspace workspace :title (format "Window %s" id)
     ;; A desktop window is seamless: its resize strips cover the frame's
     ;; outermost body row and columns, so the fixture body keeps that margin.
     :view (etaf-view (box :width 'stretch :height 'stretch
                           :padding '((lh 0) (ch 2) (lh 1) (ch 2))
                        (text (expr (format "Content %s" id)))))
     :x x :y y :width width :height height :min-width 120 :min-height 5)))

(defun etaf-desktop-benchmark--canvas (desktop)
  "Return DESKTOP's current `(WIDTH . HEIGHT)' canvas."
  (let ((state (etaf-desktop-state desktop)))
    (cons (plist-get state :canvas-width) (plist-get state :canvas-height))))

(defun etaf-desktop-benchmark--rectangle (state)
  "Return the public geometry fields from window STATE."
  (mapcar (lambda (key) (plist-get state key)) '(:x :y :width :height)))

(defun etaf-desktop-benchmark--focused-p (desktop id)
  "Check that ID is active and above the other visible workspace windows."
  (let ((state (etaf-desktop-window-state desktop id)))
    (and (equal id (etaf-desktop-active-window desktop))
         (plist-get state :visible)
         (not (plist-get state :minimized))
         (cl-every
          (lambda (other)
            (or (equal id (plist-get other :id))
                (not (equal (plist-get state :workspace)
                            (plist-get other :workspace)))
                (not (plist-get other :visible))
                (plist-get other :minimized)
                (> (plist-get state :z-index) (plist-get other :z-index))))
          (etaf-desktop-windows desktop)))))

(defun etaf-desktop-benchmark--content-p (buffer id)
  "Return non-nil when BUFFER visibly contains window ID's body marker."
  (with-current-buffer buffer
    (not (null (string-match-p (regexp-quote (format "Content %s" id))
                               (buffer-string))))))

(defun etaf-desktop-benchmark--native-events (runtime ref window delta count)
  "Prepare COUNT native motions and a distinct release for RUNTIME's REF.
WINDOW must display REF.  DELTA is the release displacement in physical
pixels.  Construct every event before timing; execution uses Emacs's native
keymap route with no replacement reader or direct gesture phase dispatch."
  (unless (and (window-live-p window)
               (display-graphic-p (window-frame window))
               (eq window (selected-window))
               (eq (window-buffer window) (etaf-runtime-buffer runtime)))
    (error "Native Desktop workload needs its selected graphical target window"))
  (redisplay t)
  (let* ((position (etaf-host-ref-position runtime ref))
         (start (and position (pos-visible-in-window-p position window)
                     (posn-at-point position window)))
         (xy (and start (posn-x-y start)))
         (press (and start (list 'down-mouse-1 start)))
         (width (window-body-width window t))
         (height (window-body-height window t))
         motions last-delta)
    (unless (and (consp xy) (numberp (car xy)) (numberp (cdr xy))
                 (eq ref (etaf-host-ref-at runtime position))
                 (commandp (key-binding (vector press) nil nil position)))
      (error "Native Desktop drag target is not visibly bound: %s" ref))
    (cl-labels
        ((point-data (offset timestamp)
           (let ((x (+ (car xy) (car offset)))
                 (y (+ (cdr xy) (cdr offset))))
             (unless (and (<= 0 x) (< x width) (<= 0 y) (< y height))
               (error "Native Desktop pointer endpoint leaves its text window"))
             (list window position (cons x y) timestamp)))
         (progress (value index)
           (* (if (< value 0) -1 1)
              (/ (* (abs value) index) (1+ count)))))
      (dotimes (index count)
        (setq last-delta (cons (progress (car delta) (1+ index))
                              (progress (cdr delta) (1+ index))))
        (push (list 'mouse-movement (point-data last-delta (1+ index))) motions))
      (when (equal last-delta delta)
        (error "Native Desktop release must differ from its last motion"))
      (list :events (vconcat (list press) (nreverse motions)
                            (list (list 'drag-mouse-1 start
                                        (point-data delta (+ count 2)))))
            :start (cons (car xy) (cdr xy)) :last-motion last-delta
            :release (cons (car delta) (cdr delta))))))

(defun etaf-desktop-benchmark--fixture (scenario mode)
  "Create a four-window workload for public SCENARIO in MODE.
A `tiled-' prefix runs the remaining operation on a tiled workspace.  In
`gui' MODE the desktop fits the selected benchmark window; `batch' uses
`etaf-desktop-benchmark--batch-canvas'."
  (let* ((tiled (string-prefix-p "tiled-" (symbol-name scenario)))
         (operation (if tiled
                        (intern (substring (symbol-name scenario) 6))
                      scenario))
         (buffer (generate-new-buffer " *ETAF Desktop benchmark*"))
         (gui (eq mode 'gui))
         (desktop (apply #'etaf-desktop-create
                         :name (buffer-name buffer) :workspaces '(main dev)
                         (unless gui
                           (list :canvas-width (car etaf-desktop-benchmark--batch-canvas)
                                 :canvas-height (cdr etaf-desktop-benchmark--batch-canvas)))))
         (canvas nil)
         (ids etaf-desktop-benchmark--ids)
         (step 0)
         (target (car ids))
         (runtime nil)
         (revision nil)
         (event-window nil)
         (before nil)
         (expected nil)
         (delta nil)
         (native (string-prefix-p "native-" (symbol-name operation)))
         (moving (memq operation '(move native-move-sequence native-move-burst)))
         (motion-count (and native (if (string-suffix-p "-burst" (symbol-name operation))
                                       130 8)))
         (native-plan nil)
         (native-ref nil)
         (edge (cond ((string-prefix-p "resize-" (symbol-name operation))
                      (substring (symbol-name operation) 7))
                     ((and native (not moving))
                      (string-remove-suffix
                       (if (string-suffix-p "-burst" (symbol-name operation))
                           "-burst" "-sequence")
                       (string-remove-prefix "native-resize-" (symbol-name operation))))))
         (shell (cond ((string-prefix-p "launcher-" (symbol-name operation)) 'launcher)
                      ((string-prefix-p "switcher-" (symbol-name operation)) 'switcher)
                      ((string-prefix-p "settings-" (symbol-name operation)) 'settings)))
         (shell-open (string-suffix-p "-open" (symbol-name operation))))
    ;; Mount before opening windows: a GUI desktop learns its canvas from the
    ;; window that displays it, and the grid below is laid out on that canvas.
    (setq runtime (etaf-runtime-for-buffer (etaf-desktop-mount desktop buffer)))
    (when gui
      (set-window-buffer (selected-window) buffer)
      (etaf-desktop-fit-canvas desktop (selected-window)))
    (setq canvas (etaf-desktop-benchmark--canvas desktop))
    (cl-loop for id in ids for index from 0 do
             (etaf-desktop-benchmark--open-window desktop id index 'main canvas))
    (when (eq operation 'workspace)
      (cl-loop for index below 4 do
               (etaf-desktop-benchmark--open-window
                desktop (intern (format "desktop-dev-%s" index)) index 'dev canvas)))
    (etaf-desktop-switch-workspace desktop 'main)
    (etaf-desktop-focus-window desktop (car (last ids)))
    (when (or tiled (eq operation 'layout-ratio))
      (etaf-desktop-layout-set-tree
       desktop '(:split horizontal 0.5
                        (:split vertical 0.5 (:leaf desktop-one) (:leaf desktop-three))
                        (:split vertical 0.5 (:leaf desktop-two) (:leaf desktop-four)))
       'main)
      (etaf-desktop-set-layout-mode desktop 'tiling 'main))
    (etaf-runtime-flush runtime)
    (cl-labels
        ((flush () (etaf-runtime-flush runtime))
         (open-shell ()
           (pcase shell
             ('launcher (etaf-desktop-toggle-launcher desktop t))
             ('switcher (etaf-desktop-toggle-switcher desktop t))
             ('settings (etaf-desktop-toggle-settings desktop t))))
         (close-shell ()
           (pcase shell
             ('launcher (etaf-desktop-close-launcher desktop))
             ('switcher (etaf-desktop-close-switcher desktop))
             ('settings (etaf-desktop-close-settings desktop))))
         (shell-visible-p ()
           (pcase shell
             ('launcher (etaf-desktop-launcher-open-p desktop))
             ('switcher (etaf-desktop-switcher-open-p desktop))
             ('settings (etaf-desktop-settings-open-p desktop))))
         (state () (etaf-desktop-window-state desktop target)))
      (list
       :buffer buffer
       :ready (lambda () t)
       :environment (lambda ()
                      (let ((current (etaf-desktop-benchmark--canvas desktop)))
                        (list :operation (symbol-name operation)
                              :canvas-width (car current) :canvas-height (cdr current)
                              :canvas-policy (if gui "window-fitted" "batch-fixed")
                              :workspace-window-count 4
                              :input-route (if native "native-keymap" "public-api")
                              :motion-queue (and native "prequeued")
                              :motion-count motion-count
                              :physical-pointer-latency-certified :false)))
       :prepare
       (lambda ()
         (cl-incf step)
         (setq target (nth (mod (1- step) 4) ids))
         (cond
          (shell (if shell-open (close-shell) (open-shell)))
          ((eq operation 'close)
           ;; Reopen the preceding closed window so every timed close starts
           ;; from four windows, then make the target the active one.
           (cl-loop for id in ids for index from 0
                    unless (cl-find id (etaf-desktop-windows desktop)
                                    :key (lambda (window) (plist-get window :id)))
                    do (etaf-desktop-benchmark--open-window desktop id index 'main canvas))
           (etaf-desktop-focus-window desktop target))
          ((memq operation '(maximize minimize restore-maximized restore-minimized))
           (dolist (id ids) (etaf-desktop-restore-window desktop id))
           (etaf-desktop-focus-window desktop target)
           (setq expected (etaf-desktop-benchmark--rectangle (state)))
           (pcase operation
             ('restore-maximized (etaf-desktop-maximize-window desktop target))
             ('restore-minimized (etaf-desktop-minimize-window desktop target))))
          ((eq operation 'workspace)
           (setq expected (if (eq (etaf-desktop-active-workspace desktop) 'main)
                              'dev 'main)))
          ((eq operation 'layout-ratio)
           (setq expected (if (= (nth 2 (etaf-desktop-layout-tree desktop 'main)) 0.4)
                              0.6 0.4)))
          ((eq operation 'layout-mode)
           (setq expected (if (eq (etaf-desktop-layout-mode desktop) 'floating)
                              'tiling 'floating))))
         (flush)
         (setq before (etaf-desktop-windows desktop)
               revision (etaf-runtime-revision runtime)
               event-window (get-buffer-window buffer t))
         (when (or edge moving)
           (let* ((direction (if (cl-evenp (/ (1- step) 4)) 1 -1))
                  (dx (if (or moving
                              (string-match-p "left\\|right" edge)) (* direction 8) 0))
                  (dy (if (or moving
                              (string-match-p "top\\|bottom" edge)) direction 0))
                  (rectangle (etaf-desktop-benchmark--rectangle (state)))
                  (left (and edge (string-match-p "left" edge)))
                  (top (and edge (string-match-p "top" edge))))
             (setq delta (cons dx (* dy (if (window-live-p event-window)
                                           (frame-char-height (window-frame event-window))
                                         1)))
                   expected
                   (list (+ (nth 0 rectangle) (if (or left moving) dx 0))
                         (+ (nth 1 rectangle) (if (or top moving) dy 0))
                         (+ (nth 2 rectangle) (if edge (if left (- dx) dx) 0))
                         (+ (nth 3 rectangle) (if edge (if top (- dy) dy) 0))))))
         (when native
           (setq native-ref
                 (intern (if edge
                             (format "etaf-desktop-resize-%s-%s" target edge)
                           (format "etaf-desktop-chrome-%s" target)))
                 native-plan
                 (etaf-desktop-benchmark--native-events
                  runtime native-ref event-window delta motion-count))))
       :invoke
       (lambda (_sample)
         (cond
          (shell (if shell-open (open-shell) (close-shell)))
          (native
           (execute-kbd-macro (plist-get native-plan :events)))
          ((or edge moving)
           (let ((ref (intern (if edge
                                  (format "etaf-desktop-resize-%s-%s" target edge)
                                (format "etaf-desktop-chrome-%s" target)))))
             (etaf-dispatch-event runtime ref 'drag
                                  (list :phase 'start :delta '(0 . 0) :window event-window) t)
             (etaf-dispatch-event runtime ref 'drag
                                  (list :phase 'move :delta delta :window event-window) t)
             (etaf-dispatch-event runtime ref 'drag
                                  (list :phase 'end :delta delta :window event-window) t)))
          (t
           (pcase operation
             ('focus (etaf-desktop-focus-window desktop target))
             ('maximize (etaf-desktop-maximize-window desktop target))
             ('minimize (etaf-desktop-minimize-window desktop target))
             ((or 'restore-maximized 'restore-minimized)
              (etaf-desktop-restore-window desktop target))
             ('close (etaf-desktop-close-window desktop target))
             ('workspace (etaf-desktop-switch-workspace desktop expected))
             ('layout-ratio (etaf-desktop-layout-resize-split desktop nil expected 'main))
             ('layout-mode (etaf-desktop-set-layout-mode desktop expected 'main)))))
         (flush))
       :settled (lambda () (> (etaf-runtime-revision runtime) revision))
       :verify
       (lambda ()
         (or
          (cond
           (shell (eq (not (null (shell-visible-p))) shell-open))
           ((or edge moving)
            (and (equal expected (etaf-desktop-benchmark--rectangle (state)))
                 (> (etaf-runtime-revision runtime) revision)
                 (etaf-desktop-benchmark--focused-p desktop target)
                 (etaf-desktop-benchmark--content-p buffer target)
                 (or (not native)
                     (and (eq event-window (selected-window))
                          (eq buffer (window-buffer event-window))
                          (etaf-host-ref-position runtime native-ref)
                          (not (ebox-selector-query-buffer buffer ":active"))
                          (cl-every (lambda (id)
                                      (etaf-desktop-benchmark--content-p buffer id)) ids)))
                 (cl-every
                  (lambda (old)
                    (or (equal target (plist-get old :id))
                        (equal (etaf-desktop-benchmark--rectangle old)
                               (etaf-desktop-benchmark--rectangle
                                (etaf-desktop-window-state desktop (plist-get old :id))))))
                  before)))
           ((eq operation 'focus)
            (and (etaf-desktop-benchmark--focused-p desktop target)
                 (cl-every (lambda (id) (etaf-desktop-benchmark--content-p buffer id)) ids)))
           ((eq operation 'maximize)
            (and (etaf-desktop-window-maximized-p desktop target)
                 (equal (list 0 0 (car canvas) (cdr canvas))
                        (etaf-desktop-benchmark--rectangle (state)))
                 (etaf-desktop-benchmark--content-p buffer target)))
           ((eq operation 'minimize)
            (and (plist-get (state) :minimized)
                 (not (equal target (etaf-desktop-active-window desktop)))
                 (not (etaf-desktop-benchmark--content-p buffer target))))
           ((memq operation '(restore-maximized restore-minimized))
            (and (not (plist-get (state) :minimized))
                 (not (etaf-desktop-window-maximized-p desktop target))
                 (equal expected (etaf-desktop-benchmark--rectangle (state)))
                 (etaf-desktop-benchmark--focused-p desktop target)
                 (etaf-desktop-benchmark--content-p buffer target)))
           ((eq operation 'close)
            (and (= 3 (length (etaf-desktop-windows desktop)))
                 (not (cl-find target (etaf-desktop-windows desktop)
                               :key (lambda (window) (plist-get window :id))))
                 (not (etaf-desktop-benchmark--content-p buffer target))
                 (etaf-desktop-benchmark--focused-p
                  desktop (etaf-desktop-active-window desktop))))
           ((eq operation 'workspace)
            (and (eq expected (etaf-desktop-active-workspace desktop))
                 (cl-every
                  (lambda (window)
                    (eq (equal expected (plist-get window :workspace))
                        (etaf-desktop-benchmark--content-p buffer (plist-get window :id))))
                  (etaf-desktop-windows desktop))))
           ((eq operation 'layout-ratio)
            (and (= expected (nth 2 (etaf-desktop-layout-tree desktop 'main)))
                 (not (equal (etaf-desktop-benchmark--rectangle (car before))
                             (etaf-desktop-benchmark--rectangle
                              (etaf-desktop-window-state desktop (plist-get (car before) :id)))))))
           ((eq operation 'layout-mode)
            (and (eq expected (etaf-desktop-layout-mode desktop))
                 (cl-every (lambda (id) (etaf-desktop-benchmark--content-p buffer id)) ids))))
          (format "%s did not publish the expected window state and content" operation)))
       :outcome
       (lambda ()
         (let* ((windows (etaf-desktop-windows desktop))
                (window (cl-find target windows :key (lambda (value) (plist-get value :id)))))
           (list :operation (symbol-name operation) :target (symbol-name target)
                 :window-count (length windows)
                 :active (format "%s" (etaf-desktop-active-window desktop))
                 :workspace (format "%s" (etaf-desktop-active-workspace desktop))
                 :layout (format "%s" (etaf-desktop-layout-mode desktop 'main))
                 :rectangle (and window (vconcat (etaf-desktop-benchmark--rectangle window)))
                 :revision-before revision
                 :revision-after (etaf-runtime-revision runtime)
                 :native-input
                 (when native
                   (list :route "execute-kbd-macro" :queue "prequeued"
                         :motion-count motion-count
                         :target-ref (symbol-name native-ref)
                         :press-pixels (vector (car (plist-get native-plan :start))
                                               (cdr (plist-get native-plan :start)))
                         :last-motion-delta-pixels
                         (vector (car (plist-get native-plan :last-motion))
                                 (cdr (plist-get native-plan :last-motion)))
                         :release-delta-pixels (vector (car delta) (cdr delta))
                         :expected-rectangle (vconcat expected)
                         :held-targets-cleared
                         (if (ebox-selector-query-buffer buffer ":active") :false t)))
                 :shell-open (and shell (if (shell-visible-p) t :false)))))
       :observe (lambda (sink)
                  (ebox-buffer-set-observer buffer sink)
                  (lambda () (ebox-buffer-set-observer buffer nil)))
       :cleanup (lambda ()
                  (etaf-desktop-close desktop)
                  (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(dolist (operation '(move resize-left resize-right resize-top resize-bottom
                         resize-top-left resize-top-right resize-bottom-left resize-bottom-right
                         focus maximize minimize restore-maximized restore-minimized close
                         workspace layout-ratio layout-mode
                         tiled-focus tiled-maximize tiled-minimize tiled-close
                         launcher-open launcher-close switcher-open switcher-close
                         settings-open settings-close))
  (taf-benchmark-register
   (format "etaf-desktop.%s.%s"
           (if (or (eq operation 'move)
                   (string-prefix-p "resize-" (symbol-name operation))) "geometry" "policy")
           operation)
   :version 4 :modes '(batch gui) :isolation 'series :required-providers '(ebox)
   :budget-ms 10 :impact 'mixed
   :description (format "Four-window Desktop %s with the committed buffer update" operation)
   :setup (let ((selected-operation operation))
            (lambda (mode) (etaf-desktop-benchmark--fixture selected-operation mode)))))

(dolist (operation '(native-move-sequence native-move-burst
                    native-resize-left-sequence native-resize-right-sequence
                    native-resize-top-sequence native-resize-bottom-sequence
                    native-resize-top-left-sequence native-resize-top-right-sequence
                    native-resize-bottom-left-sequence native-resize-bottom-right-sequence
                    native-resize-bottom-right-burst))
  (taf-benchmark-register
   (format "etaf-desktop.geometry.%s" operation)
   :version 4 :modes '(gui) :isolation 'series :required-providers '(ebox)
   :budget-ms 10 :impact 'mixed
   :description (format "Four-window %s with prequeued native motions and exact release" operation)
   :setup (let ((selected-operation operation))
            (lambda (mode) (etaf-desktop-benchmark--fixture selected-operation mode)))))


(defun etaf-desktop-benchmark--class-p (props class)
  "Return non-nil when public Host PROPS contain CLASS."
  (let ((value (plist-get props :class)))
    (member class (if (stringp value) (split-string value) value))))

(defun etaf-desktop-benchmark--demo-host (runtime predicate &optional scope)
  "Find one live Host in RUNTIME matching PREDICATE, within optional SCOPE.
PREDICATE and SCOPE inspect public Host props.  Scope membership uses committed
semantic ancestry, so repeated Close controls cannot select another window."
  (let* ((entries (etaf-runtime-host-props-entries runtime))
         (candidates (cl-remove-if-not
                      (lambda (entry) (funcall predicate (cdr entry))) entries))
         (parent (and scope (cl-find-if
                             (lambda (entry) (funcall scope (cdr entry))) entries)))
         (ancestries (and parent (etaf-runtime-host-ancestries
                                  runtime (cons (car parent) (mapcar #'car candidates)))))
         (ancestor (and parent (car (gethash (car parent) ancestries)))))
    (when (and scope (not ancestor))
      (error "Real demo control scope is absent"))
    (setq candidates
          (cl-remove-if-not
           (lambda (entry)
             (and (or (not scope) (member ancestor (gethash (car entry) ancestries)))
                  (etaf-host-ref-position runtime (car entry))))
           candidates))
    (unless (= (length candidates) 1)
      (error "Real demo expected one live control, found %d" (length candidates)))
    (caar candidates)))

(defun etaf-desktop-benchmark--click-events (runtime ref window)
  "Return a native mouse press/release pair for RUNTIME's REF in WINDOW."
  (unless (and (window-live-p window) (eq window (selected-window))
               (display-graphic-p (window-frame window))
               (eq (window-buffer window) (etaf-runtime-buffer runtime)))
    (error "Real demo click requires the selected graphical target window"))
  (redisplay t)
  (let* ((point (etaf-host-ref-position runtime ref))
         (position (and point (pos-visible-in-window-p point window)
                        (posn-at-point point window)))
         (press (and position (list 'down-mouse-1 position)))
         (release (and position (list 'mouse-1 position))))
    (unless (and position
                 (commandp (key-binding (vector press) nil nil point))
                 (commandp (key-binding (vector release) nil nil point)))
      (error "Real demo mouse target is not visibly bound: %s" ref))
    (vector press release)))

(defun etaf-desktop-benchmark--demo-window-facts (window)
  "Return WINDOW's public geometry and lifecycle facts, excluding focus order."
  (mapcar (lambda (key) (plist-get window key))
          '(:id :workspace :x :y :width :height :visible :minimized :maximized)))

(defun etaf-desktop-benchmark--demo-fixture (operation mode)
  "Exercise OPERATION in the complete six-application demo in GUI MODE.
Clock keeps its normal timer.  Only preconditions and native target discovery
run outside timing; the native click and its completed publication are timed."
  (unless (eq mode 'gui) (error "Real demo native workloads require GUI mode"))
  (let* ((buffer (generate-new-buffer " *ETAF Desktop demo benchmark*"))
         (desktop (etaf-desktop-demo-open (buffer-name buffer)))
         (runtime (etaf-runtime-for-buffer buffer))
         (step 0)
         (tabs '(("Layout" . "Window layout")
                 ("Behavior" . "Drag lock modifier")
                 ("Shortcuts" . "Focus next")
                 ("Appearance" . "Accent color")))
         (baseline-ids (mapcar (lambda (window) (plist-get window :id))
                              (etaf-desktop-windows desktop)))
         (notes-app (plist-get
                     (cl-find "Notes" (etaf-desktop-apps)
                              :key (lambda (app) (plist-get app :title)) :test #'equal)
                     :id))
         (focus-ids (mapcar
                     (lambda (title)
                       (or (plist-get
                            (cl-find title (etaf-desktop-windows desktop)
                                     :key (lambda (window) (plist-get window :title))
                                     :test #'equal)
                            :id)
                           (error "Real demo window is absent: %s" title)))
                     '("Notes" "Tasks")))
         before active-before revision target target-window target-instance
         events section ready)
    (unless (and notes-app (= (length baseline-ids) 6))
      (error "Real demo did not create its six application windows"))
    (cl-labels
        ((flush () (etaf-runtime-flush runtime))
         (label (value &optional scope)
           (etaf-desktop-benchmark--demo-host
            runtime (lambda (props) (equal value (plist-get props :aria-label))) scope))
         (window-scope (id)
           (lambda (props) (equal (format "%s" id) (plist-get props :id))))
         (settings-scope (props)
           (equal "Desktop Settings" (plist-get props :aria-label)))
         (unchanged-p ()
           (cl-every
            (lambda (old)
              (or (and (eq operation 'app-close)
                       (equal target-window (plist-get old :id)))
                  (equal (etaf-desktop-benchmark--demo-window-facts old)
                         (etaf-desktop-benchmark--demo-window-facts
                          (etaf-desktop-window-state desktop (plist-get old :id))))))
            before))
         (text-present-p (text)
           (with-current-buffer buffer
             (string-match-p (regexp-quote text)
                             (buffer-substring-no-properties (point-min) (point-max))))))
      (list
       :buffer buffer
       :ready
       (lambda ()
         (unless ready
           (etaf-desktop-fit-canvas desktop (selected-window))
           (flush)
           (when (eq operation 'app-close)
             (let ((instance (etaf-desktop-launch desktop notes-app :workspace 'main)))
               (setq target-instance (plist-get instance :id)
                     target-window (car (plist-get instance :windows)))))
           (when (eq operation 'settings-tabs)
             (etaf-desktop-toggle-settings desktop t))
           (flush)
           (setq ready t))
         t)
       :environment
       (lambda ()
         (let ((canvas (etaf-desktop-benchmark--canvas desktop)))
           (list :fixture "six-application-demo" :operation (symbol-name operation)
                 :canvas-width (car canvas) :canvas-height (cdr canvas)
                 :canvas-policy "window-fitted" :initial-window-count 6
                 :clock-policy "normal-live-timer" :input-route "native-keymap"
                 :physical-pointer-latency-certified :false)))
       :prepare
       (lambda ()
         (pcase operation
           ('app-open (etaf-desktop-toggle-launcher desktop t))
           ('settings-open (etaf-desktop-close-settings desktop))
           ('settings-close (etaf-desktop-toggle-settings desktop t))
           ('settings-tabs (setq section (nth (mod step (length tabs)) tabs)))
           ('focus (setq target-window (nth (mod step (length focus-ids)) focus-ids))))
         (flush)
         (setq before (etaf-desktop-windows desktop)
               active-before (etaf-desktop-active-window desktop)
               revision (etaf-runtime-revision runtime)
               target
               (pcase operation
                 ('app-open
                  (label (let* ((app (etaf-desktop-app notes-app))
                                (icon (plist-get app :icon)))
                           (concat (if (and (stringp icon) (not (string-empty-p icon)))
                                       (concat icon " ") "")
                                   (plist-get app :title)))
                         (lambda (props)
                           (etaf-desktop-benchmark--class-p props "etaf-launcher-list"))))
                 ('app-close (label "Close" (window-scope target-window)))
                 ('settings-open (label "Settings"))
                 ('settings-close (label "Dismiss" #'settings-scope))
                 ('settings-tabs (label (car section) #'settings-scope))
                 ('focus
                  (etaf-desktop-benchmark--demo-host
                   runtime
                   (lambda (props)
                     (etaf-desktop-benchmark--class-p props "etaf-window-content"))
                   (window-scope target-window)))))
         (when (and (eq operation 'focus) (equal target-window active-before))
           (error "Real demo focus sample must cross window boundaries"))
         (setq events (etaf-desktop-benchmark--click-events
                       runtime target (selected-window))))
       :invoke
       (lambda (_sample)
         (execute-kbd-macro events)
         (flush)
         (cl-incf step))
       :settled (lambda () (> (etaf-runtime-revision runtime) revision))
       :verify
       (lambda ()
         (let* ((windows (etaf-desktop-windows desktop))
                (ids (mapcar (lambda (window) (plist-get window :id)) windows))
                (added (cl-set-difference ids baseline-ids :test #'equal))
                (active (etaf-desktop-active-window desktop)))
           (if
            (and (> (etaf-runtime-revision runtime) revision)
                 (eq (etaf-desktop-active-workspace desktop) 'main)
                 (unchanged-p)
                 (not (ebox-selector-query-buffer buffer ":active"))
                 (pcase operation
                   ('app-open
                    (and (= (length windows) 7) (= (length added) 1)
                         (equal active (car added))
                         (etaf-desktop-benchmark--focused-p desktop active)
                         (equal "Notes" (plist-get
                                         (etaf-desktop-window-state desktop active) :title))
                         (not (etaf-desktop-launcher-open-p desktop))
                         (label "Title" (window-scope active))))
                   ('app-close
                    (and (= (length windows) 6) (not (member target-window ids))
                         (eq 'closed (plist-get (etaf-desktop-instance desktop target-instance)
                                                :status))
                         (etaf-desktop-benchmark--focused-p desktop active)))
                   ('focus
                    (and (= (length windows) 6)
                         (etaf-desktop-benchmark--focused-p desktop target-window)))
                   ((or 'settings-open 'settings-close 'settings-tabs)
                    (and (= (length windows) 6) (equal active active-before)
                         (eq (not (null (etaf-desktop-settings-open-p desktop)))
                             (not (eq operation 'settings-close)))
                         (if (eq operation 'settings-tabs)
                             (and (etaf-desktop-benchmark--class-p
                                   (etaf-runtime-host-props-for runtime target) "secondary")
                                  (text-present-p (cdr section)))
                           (eq (not (null (text-present-p "Desktop Settings")))
                               (eq operation 'settings-open)))))))
            t
            (format "Real demo %s changed geometry or failed native control/lifecycle verification"
                    operation))))
       :outcome
       (lambda ()
         (list :operation (symbol-name operation)
               :target-window (and target-window (format "%s" target-window))
               :section (car section) :input-route "native-keymap"
               :active (format "%s" (etaf-desktop-active-window desktop))
               :settings-open (if (etaf-desktop-settings-open-p desktop) t :false)
               :revision-before revision
               :revision-after (etaf-runtime-revision runtime)
               :windows
               (vconcat
                (mapcar (lambda (window)
                          (list :id (format "%s" (plist-get window :id))
                                :title (plist-get window :title)
                                :rectangle (vconcat (etaf-desktop-benchmark--rectangle window))))
                        (etaf-desktop-windows desktop)))))
       :observe (lambda (sink)
                  (ebox-buffer-set-observer buffer sink)
                  (lambda () (ebox-buffer-set-observer buffer nil)))
       :cleanup (lambda ()
                  (etaf-desktop-close desktop)
                  (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(dolist (operation '(app-open app-close settings-open settings-close settings-tabs focus))
  (taf-benchmark-register
   (format "etaf-desktop.demo.%s" operation)
   :version 1 :modes '(gui)
   ;; Each application lifecycle sample starts with six pristine live apps;
   ;; repeated launches would otherwise accumulate closed instance history.
   :isolation (if (memq operation '(app-open app-close)) 'fresh 'series)
   :required-providers '(ebox) :budget-ms 10 :impact 'mixed
   :description (format "Six-app demo native %s with live Clock and stable window geometry"
                        operation)
   :setup (let ((selected-operation operation))
            (lambda (mode) (etaf-desktop-benchmark--demo-fixture selected-operation mode)))))

;;; performance-scenarios.el ends here
