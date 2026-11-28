;;; performance-scenarios.el --- Public application interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; The shared driver owns sampling, profiling, timeouts and artifacts. These
;; adapters declare only application setup, real input and visible correctness.

;;; Code:
(require 'cl-lib)
(require 'etaf-ui)
(require 'ebox)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-ui-benchmark--observe (runtime buffer sink)
  "Observe RUNTIME in unique BUFFER and deliver public reports to SINK."
  (etaf-performance-start runtime)
  (let ((before (mapcar (lambda (operation)
                         (cons (plist-get operation :runtime-id) (plist-get operation :id)))
                       (plist-get (etaf-performance-report-data) :operations))))
    (lambda ()
      (etaf-performance-stop runtime)
      (dolist (operation (plist-get (etaf-performance-report-data) :operations))
        (when (and (equal (plist-get operation :buffer-name) (buffer-name buffer))
                   (not (member (cons (plist-get operation :runtime-id)
                                      (plist-get operation :id)) before)))
          (dolist (stage (plist-get operation :stages))
            (funcall sink (append (list :provider (plist-get stage :provider)
                                       :stage (plist-get stage :stage)
                                       :duration-ms (plist-get stage :duration-ms))
                                 (plist-get stage :metadata)))))))))

(defun etaf-ui-benchmark--environment ()
  "Return stable capability facts of the measured session."
  (list :graphic (if (display-graphic-p) t :false)
        :gc_cons_threshold gc-cons-threshold
        :gc_cons_percentage gc-cons-percentage))

(defun etaf-ui-benchmark--outcome (buffer runtime)
  "Return BUFFER's last committed write facts and RUNTIME's revision."
  (let ((report (ebox-buffer-update-report buffer)))
    (list :strategy (format "%s" (plist-get report :strategy))
          :edits (plist-get report :edits)
          :lines (plist-get report :lines)
          :revision (etaf-runtime-revision runtime))))

(defun etaf-ui-benchmark--gallery (label expected route mode &optional steps existing-buffer category)
  "Prepare Gallery LABEL through ROUTE in MODE and verify EXPECTED text.
STEPS cycles through public activations and visible expectations on one mount.
EXISTING-BUFFER borrows a mounted page without resetting or disposing it.
CATEGORY is an optional category label to open before sampling, through
the sidebar or the compact category picker."
  (let ((buffer (or existing-buffer (generate-new-buffer " *TAF Gallery*")))
        (invocations 0) viewport-ready runtime target position observing step expected-text expected-visible)
    (unless existing-buffer (etaf-ui-gallery-open buffer))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (unless runtime (error "The selected buffer has no mounted ETAF application"))
    (list
     :buffer buffer :environment #'etaf-ui-benchmark--environment
     :ready
     (lambda ()
       (unless (or existing-buffer viewport-ready)
         ;; SETUP mounts before the driver displays the buffer. Resolve the
         ;; actual containing viewport once it is visible, outside timing.
         (etaf-runtime-refit
          runtime
          (if (eq mode 'gui) (window-body-width (selected-window) t)
            (* 160 (frame-char-width)))
          (if (eq mode 'gui) (window-body-height (selected-window)) 50))
         (when category
           (cl-flet ((named (name)
                       (car (cl-find-if
                             (lambda (entry) (equal name (plist-get (cdr entry) :aria-label)))
                             (etaf-runtime-host-props-entries runtime)))))
             (unless (named category)
               (when-let* ((picker (named "组件分类")))
                 (etaf-dispatch-event runtime picker 'press)))
             (let ((ref (named category)))
               (unless ref (error "Gallery category is unavailable: %s" category))
               (etaf-dispatch-event runtime ref 'press))))
         (setq viewport-ready t))
       t)
     :prepare
     (lambda ()
       (setq step (if steps (nth (% invocations (length steps)) steps)
                    (list :label label :text expected :visible t)))
       (let* ((text (with-current-buffer buffer
                      (buffer-substring-no-properties (point-min) (point-max))))
              (alternatives (plist-get step :alternate)))
         (setq expected-text (plist-get step :text)
               expected-visible (plist-get step :visible))
         (when alternatives
           (setq expected-text
                 (cond ((string-match-p (regexp-quote (car alternatives)) text) (cadr alternatives))
                       ((string-match-p (regexp-quote (cadr alternatives)) text) (car alternatives))
                       (t (error "The current Gallery does not show either expected value")))
                 expected-visible t))
         (when (plist-get step :toggle)
           (setq expected-visible
                 (not (string-match-p (regexp-quote expected-text) text)))))
       (unless (plist-get step :keys)
         (setq target
             (or (car (cl-find-if
                       (lambda (entry) (equal (plist-get step :label)
                                              (plist-get (cdr entry) :aria-label)))
                       (etaf-runtime-host-props-entries runtime)))
                 (error "Gallery target is absent: %s" (plist-get step :label))))
       (when target (etaf-scroll-into-view runtime target))
       (when (eq route 'mouse)
         (unless (eq mode 'gui) (error "Mouse requires GUI mode"))
         (let ((point (etaf-host-ref-position runtime target)))
           (unless (and point (pos-visible-in-window-p point (selected-window)))
             (error "Gallery mouse target is not visible: %s" label))
           (setq position (posn-at-point point (selected-window)))))))
     :invoke
     (lambda (_sample)
       (let ((action
              (lambda ()
                (if-let* ((keys (plist-get step :keys)))
                    (execute-kbd-macro (kbd keys))
                  (pcase route
                  ('callback (etaf-dispatch-event runtime target 'press))
                  ('keyboard (etaf-focus runtime target)
                             (execute-kbd-macro (kbd (or (plist-get step :key) "RET"))))
                  ('mouse (execute-kbd-macro (vector (list 'down-mouse-1 position)
                                                   (list 'mouse-1 position)))))))))
         ;; Pressed-state publication precedes ETAF's application callback;
         ;; release/focus publication can follow it. Observe the complete input
         ;; operation so those provider commits are not reported as outside Ebox.
         ;; Latency and profiler passes retain the unobserved native route.
         (if observing
             (etaf-performance-call-operation
              runtime 'input (or (plist-get step :label) (plist-get step :keys)) action)
           (funcall action)))
       (cl-incf invocations))
     :outcome
     (lambda ()
       ;; Read the accepted last commit after timing, without enabling tracing
       ;; or changing the event boundary of the latency sample itself.
       (etaf-ui-benchmark--outcome buffer runtime))
     :verify (lambda ()
               (with-current-buffer buffer
                 (and (etaf-runtime-for-buffer buffer)
                      (eq (not (null (string-match-p
                                     (regexp-quote expected-text)
                                     (buffer-substring-no-properties (point-min) (point-max)))))
                          (not (null expected-visible))))))
     :observe (lambda (sink)
                (let ((finish (etaf-ui-benchmark--observe runtime buffer sink)))
                  (setq observing t)
                  (lambda ()
                    (setq observing nil)
                    (funcall finish))))
     :cleanup (lambda ()
                (when (and (not existing-buffer) (buffer-live-p buffer))
                  (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
                  (kill-buffer buffer))))))

(dolist (case '(("selection" "自动保存" "自动保存已关闭" 50 local nil)
                ("toast" "显示通知" "保存完成" 100 overlay "菜单与浮层")
                ("menu" "操作菜单" "复制内容" 100 overlay nil)
                ("tooltip" "显示提示" "Tab 切换控件，Enter" 100 overlay "菜单与浮层")
                ("key-help" "查看快捷键" "快捷键 · 只读" 100 overlay "菜单与浮层")))
  (dolist (route '(callback keyboard mouse))
    (let ((label (nth 1 case)) (expected (nth 2 case)) (method route) (category (nth 5 case)))
      (taf-benchmark-register
       (format "gallery.%s.%s" (car case) route)
       :version 3 :modes (if (eq route 'callback) '(batch gui) '(gui))
       :required-providers '(ebox)
       ;; Mouse activation includes the native press/release tracking boundary;
       ;; keep its explicit category budget at 100 ms while callback/keyboard
       ;; local updates retain the 50 ms target.
       :budget-ms (if (eq route 'mouse) 100 (nth 3 case)) :impact (nth 4 case)
       :description (format "%s via %s%s" label route
                            (if (eq route 'keyboard) " (focus then RET)" ""))
       :setup (lambda (mode) (etaf-ui-benchmark--gallery label expected method mode nil nil category))))))

(dolist (route '(callback keyboard mouse))
  (let ((method route))
    (taf-benchmark-register
     (format "gallery.selection.steady.%s" route)
     :version 3 :modes (if (eq route 'callback) '(batch gui) '(gui))
     :isolation 'series :required-providers '(ebox)
     :budget-ms 50 :impact 'local
     :description (format "Repeated Checkbox toggles on one mounted Gallery via %s" route)
     :setup (lambda (mode)
              (etaf-ui-benchmark--gallery
               "自动保存" "自动保存已关闭" method mode
               '((:label "自动保存" :alternate ("自动保存已开启" "自动保存已关闭"))))))))

(dolist (case '(("dropdown" "操作菜单" "复制内容" nil)
                ("context" "更多操作" "检查属性" "菜单与浮层")))
  (dolist (route '(callback mouse))
    (let ((name (car case)) (label (cadr case)) (marker (nth 2 case)) (method route) (category (nth 3 case)))
      (taf-benchmark-register
       (format "gallery.%s.steady.%s" name route)
       :version 3 :modes (if (eq route 'callback) '(batch gui) '(gui))
       :isolation 'series :required-providers '(ebox)
       :budget-ms 100 :impact 'overlay
       :description (format "Repeated %s open/close on one mounted Gallery via %s" label route)
       :setup (lambda (mode)
                (etaf-ui-benchmark--gallery
                 label marker method mode
                 (list (list :label label :text marker :toggle t)) nil category))))))

(taf-benchmark-register
 "gallery.key-help.steady.keyboard"
 :version 1 :modes '(gui) :isolation 'series :required-providers '(ebox)
 :budget-ms 100 :impact 'overlay
 :description "Open help, type a literal query, leave editing and close on one Gallery"
 :setup (lambda (mode)
          (etaf-ui-benchmark--gallery
           nil nil 'keyboard mode
           '((:keys "?" :text "快捷键 · 只读" :visible t)
             (:keys "/ ?" :text "查看快捷键" :visible t)
             (:keys "<escape>" :text "关闭帮助" :visible t)
             (:keys "<escape>" :text "快捷键 · 只读" :visible nil)))))

(taf-benchmark-register
 "gallery.range.steady.keyboard"
 :version 1 :modes '(gui) :isolation 'series :required-providers '(ebox)
 :budget-ms 100 :impact 'local
 :description "Alternate Range arrows and verify live and committed Gallery values"
 :setup
 (lambda (mode)
   (let* ((fixture
           (etaf-ui-benchmark--gallery
            nil nil 'keyboard mode
            '((:label "音量示例" :key "<right>" :text "当前 61% · 已提交 61%" :visible t)
              (:label "音量示例" :key "<left>" :text "当前 60% · 已提交 60%" :visible t))))
          (ready (plist-get fixture :ready))
          prepared)
     (setf (plist-get fixture :ready)
           (lambda ()
             (funcall ready)
             (unless prepared
               (etaf-text-input-begin (etaf-runtime-for-buffer (plist-get fixture :buffer))
                                      'gallery-search)
               (execute-kbd-macro (vconcat "etaf-range" (kbd "RET")))
               (setq prepared t))
             t))
     fixture)))

(defconst etaf-ui-benchmark--mixed-steps
  '((:label "操作菜单" :text "复制内容" :toggle t)
    (:label "操作菜单" :text "复制内容" :toggle t)
    (:label "自动保存" :alternate ("自动保存已开启" "自动保存已关闭"))
    (:label "自动保存" :alternate ("自动保存已开启" "自动保存已关闭"))
    (:label "展开抽屉" :text "组件详情" :visible t)
    (:label "关闭抽屉" :text "组件详情" :visible nil)
    (:label "自动保存" :alternate ("自动保存已开启" "自动保存已关闭"))
    (:label "自动保存" :alternate ("自动保存已开启" "自动保存已关闭")))
  "Public overlay and content operations exercised on one retained page.")

(dolist (route '(callback mouse))
  (let ((method route))
    (taf-benchmark-register
     (format "gallery.categories.steady.%s" route)
     :version 2 :modes (if (eq route 'callback) '(batch gui) '(gui))
     :isolation 'series :required-providers '(ebox)
     :budget-ms 100 :impact 'subtree
     :description (format "Input, data and overview subtree replacement via %s" route)
     :setup (lambda (mode)
              (etaf-ui-benchmark--gallery
               nil nil method mode
               '((:label "输入与选择" :text "etaf-text-input" :visible t)
                 (:label "数据与集合" :text "etaf-table" :visible t)
                 (:label "组件总览" :text "本地示例，放心操作" :visible t)))))))

(dolist (existing '(nil t))
  (let ((borrow existing))
    (taf-benchmark-register
     (if borrow "gallery.current.mixed.mouse" "gallery.mixed.sequence.mouse")
     :version (if borrow 2 3) :modes '(gui) :isolation 'series :required-providers '(ebox)
     :budget-ms 100 :impact 'mixed
     :description (if borrow "Dropdown, Checkbox and Drawer on the selected Gallery overview"
                    "Dropdown, Checkbox and Drawer alternated on one mounted Gallery")
     :setup (lambda (mode)
              (etaf-ui-benchmark--gallery
               nil nil 'mouse mode etaf-ui-benchmark--mixed-steps
               (and borrow (window-buffer (selected-window))))))))

(taf-benchmark-register
 "etaf.counter" :version 1 :modes '(batch gui) :isolation 'series
 :required-providers '(ebox)
 :budget-ms 10 :impact 'local :description "Minimal reactive counter with visible text verification"
 :setup
 (lambda (_mode)
   (let ((buffer (generate-new-buffer " *TAF counter*"))
         (count (etaf-ref 0)) (expected 0) runtime)
     (etaf-mount buffer
                 (etaf-view
                  (box :ref 'counter :width '(ch 20) :tab-index 0
                       :on-press (lambda () (cl-incf (etaf-value count)))
                    (text (expr (format "Count: %d" (etaf-value count)))))))
     (setq runtime (etaf-runtime-for-buffer buffer))
     (list :buffer buffer :environment #'etaf-ui-benchmark--environment
           :invoke (lambda (_sample)
                     (cl-incf expected)
                     (etaf-dispatch-event runtime 'counter 'press))
           :verify (lambda ()
                     (with-current-buffer buffer
                       (and (= expected (etaf-value count))
                            (not (null (string-match-p (format "Count: %d" expected) (buffer-string)))))))
           :observe (lambda (sink) (etaf-ui-benchmark--observe runtime buffer sink))
           :cleanup (lambda ()
                      (when (buffer-live-p buffer)
                        (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
                        (kill-buffer buffer)))))))

;; Single catalog window resize workloads compare direct Ebox geometry
;; publication with mounted ETAF reactive state.  The body has fixed
;; dimensions and does not reflow; the real window frame, chrome and all
;; resize handles remain.  A passing small sample is not desktop acceptance.

(defun etaf-ui-resize-benchmark--view (width height)
  "Build a fixed-content catalog window with WIDTH and HEIGHT inputs."
  (etaf-view
   (box :width '(px 720) :height '(lh 30) :position 'relative
        :background-color "#EAF0F6"
     (etaf-window :id "resize-window" :ref 'resize-window
                  :chrome-ref 'resize-title :title "Fixed content"
                  :x '(px 16) :y '(lh 2) :width width :height height
                  :resize-refs '((left . resize-left) (right . resize-right)
                                 (top . resize-top) (bottom . resize-bottom)
                                 (top-left . resize-top-left)
                                 (top-right . resize-top-right)
                                 (bottom-left . resize-bottom-left)
                                 (bottom-right . resize-bottom-right))
                  :on-resize (lambda (_edge _gesture) nil)
       (box :id "resize-body" :ref 'resize-body
            :width '(px 480) :height '(lh 6) :wrap-mode 'none
            :overflow 'hidden
         (text "Retained body: 0123456789 abcdefghijklmnopqrstuvwxyz\nSecond line stays unchanged."))))))

(defun etaf-ui-resize-benchmark--fresh-p (buffer size)
  "Check BUFFER text and display properties against a fresh mount at SIZE.
SIZE is the expected (WIDTH-PIXELS HEIGHT-LINES) window rectangle."
  (let ((fresh (generate-new-buffer " *ETAF fresh window resize*")))
    (unwind-protect
        (progn
          (etaf-mount fresh (etaf-ui-resize-benchmark--view
                             (etaf-ref (list 'px (car size)))
                             (etaf-ref (list 'lh (cadr size)))))
          (let ((viewport (etaf-runtime-viewport (etaf-runtime-for-buffer buffer))))
            (etaf-runtime-refit (etaf-runtime-for-buffer fresh)
                                (car viewport) (cdr viewport)))
          (let* ((actual (with-current-buffer buffer (buffer-string)))
                 (expected (with-current-buffer fresh (buffer-string)))
                 (valid (equal (substring-no-properties actual)
                               (substring-no-properties expected)))
                 (position 0))
            (while (and valid (< position (length actual)))
              (dolist (property '(face display font-lock-face pointer help-echo mouse-face))
                (unless (equal (get-text-property position property actual)
                               (get-text-property position property expected))
                  (setq valid nil)))
              (setq position (1+ position)))
            valid))
      (when-let* ((runtime (etaf-runtime-for-buffer fresh))) (etaf-unmount runtime))
      (kill-buffer fresh))))

(defun etaf-ui-resize-benchmark--fixture (route axis)
  "Build one fixed-window fixture for publication ROUTE and resize AXIS."
  (let* ((buffer (generate-new-buffer " *ETAF fixed window resize*"))
         (width (etaf-ref '(px 320) :test #'equal))
         (height (etaf-ref '(lh 12) :test #'equal))
         (step 0) expected revision runtime mounted)
    ;; `etaf-window' is stateful, so both routes mount it; the direct route
    ;; then commits geometry through ETAF's retained Host geometry update.
    (etaf-mount buffer (etaf-ui-resize-benchmark--view width height))
    (setq mounted (etaf-runtime-for-buffer buffer)
          runtime (and (eq route 'runtime) mounted))
    (list
     :buffer buffer
     :environment (lambda () (list :route (symbol-name route)
                                   :body-reflow :false :window-count 1
                                   :canvas-width 720 :canvas-height 30))
     :prepare
     (lambda ()
       (setq step (1+ step)
             expected (if (cl-oddp step)
                          (list (if (eq axis 'height) 320 328)
                                (if (eq axis 'width) 12 13))
                        '(320 12))
             revision (etaf-runtime-revision mounted)))
     :invoke
     (lambda (_sample)
       (if runtime
           (progn
             (etaf-call-with-batch
              (lambda ()
                (etaf-set-value width (list 'px (car expected)))
                (etaf-set-value height (list 'lh (cadr expected)))))
             (etaf-runtime-flush runtime))
         (etaf-runtime-update-host-geometry
          mounted 'resize-window :width (list 'px (car expected))
          :height (list 'lh (cadr expected)))))
     :verify
     (lambda ()
       (and (= (etaf-runtime-revision mounted) (1+ revision))
            (equal (etaf-host-ref-size mounted 'resize-window)
                   (cons (car expected) (cadr expected)))
            (etaf-host-ref-position mounted 'resize-title)
            (etaf-host-ref-position mounted 'resize-right)
            (etaf-host-ref-position mounted 'resize-bottom-right)
            (or (null runtime)
                (equal (plist-get (etaf-runtime-host-props-for runtime 'resize-window) :width)
                       (etaf-value width)))
            (etaf-ui-resize-benchmark--fresh-p buffer expected)))
     :outcome
     (lambda ()
       (append (list :route (symbol-name route) :rectangle (vconcat expected)
                     :revision-before revision)
               (etaf-ui-benchmark--outcome buffer mounted)))
     :observe
     (lambda (sink)
       (ebox-buffer-set-observer buffer sink)
       (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup
     (lambda ()
       (when (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer))
         (etaf-unmount mounted))
       (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (route '(direct runtime))
  (dolist (axis '(width height corner))
    (let ((selected-route route) (selected-axis axis))
      (taf-benchmark-register
       (format "window.resize.%s.%s" route axis)
       :version 1 :modes '(batch gui) :isolation 'series
       :required-providers '(ebox) :budget-ms 10 :impact 'mixed
       :description (format "Single real etaf-window %s resize via %s; fixed body, live chrome/handles" axis route)
       :setup (lambda (_mode)
                (etaf-ui-resize-benchmark--fixture selected-route selected-axis))))))

(defun etaf-ui-resize-benchmark--native-fixture ()
  "Use real native down, movement and release events on the catalog example."
  (let* ((buffer (etaf-ui-window-resize-open
                  (generate-new-buffer " *ETAF native window resize*")))
         (runtime (etaf-runtime-for-buffer buffer))
         (step 0) events expected)
    (list
     :buffer buffer
     :environment (lambda () (list :input-route "native-keymap" :motion-queue "prequeued"
                                   :motion-count 1 :body-reflow :false
                                   :physical-pointer-latency-certified :false))
     :prepare
     (lambda ()
       (redisplay t)
       (let* ((window (get-buffer-window buffer t))
              (position (etaf-host-ref-position runtime 'resize-bottom-right))
              (start (and position (posn-at-point position window)))
              (xy (and start (posn-x-y start)))
              (sign (if (cl-oddp (cl-incf step)) 1 -1))
              (props (etaf-runtime-host-props-for runtime 'resize-window))
              (dx (* sign 8)) (dy (* sign (frame-char-height (window-frame window)))))
         (unless (and (eq window (selected-window)) (consp xy)
                      (pos-visible-in-window-p position window))
           (error "Window corner is not visible in the selected native window"))
         (setq expected (list (+ (cadr (plist-get props :width)) dx)
                              (+ (cadr (plist-get props :height)) sign)))
         (let ((end (list window position (cons (+ (car xy) dx) (+ (cdr xy) dy)) 2)))
           (setq events (vector (list 'down-mouse-1 start)
                                (list 'mouse-movement end) (list 'drag-mouse-1 start end))))))
     :invoke (lambda (_sample) (execute-kbd-macro events) (etaf-runtime-flush runtime))
     :verify
     (lambda ()
       (let ((props (etaf-runtime-host-props-for runtime 'resize-window)))
         (and (equal expected (list (cadr (plist-get props :width))
                                    (cadr (plist-get props :height))))
              (etaf-host-ref-position runtime 'resize-bottom-right)
              (etaf-ui-resize-benchmark--fresh-p buffer expected))))
     :outcome (lambda () (append (list :size (vconcat expected))
                                 (etaf-ui-benchmark--outcome buffer runtime)))
     :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda () (etaf-unmount runtime)
                (when (buffer-live-p buffer) (kill-buffer buffer))))))

(taf-benchmark-register
 "window.resize.native.corner" :version 1 :modes '(gui) :isolation 'series
 :required-providers '(ebox) :budget-ms 10 :impact 'mixed
 :description "Real catalog window corner through native press, movement and release"
 :setup (lambda (_mode) (etaf-ui-resize-benchmark--native-fixture)))

;;;; Scrolling text grid

(defconst etaf-ui-text-grid-benchmark--rows 1000000
  "Rows of the scrolling spreadsheet workload.")

(defconst etaf-ui-text-grid-benchmark--height 40
  "Visible lines of the scrolling spreadsheet workload.")

(defun etaf-ui-text-grid-benchmark--cell (row column)
  "Return the eight-column cell text of ROW and COLUMN."
  (format "%7d " (% (+ (* row 100) column) 10000000)))

(defun etaf-ui-text-grid-benchmark--fixture (mode action)
  "Mount a million-row, 31-cell styled grid for MODE and repeat ACTION.
ACTION is `step', `page', `jump' or `column'."
  (let* ((buffer (generate-new-buffer " *Text grid benchmark*"))
         (rows etaf-ui-text-grid-benchmark--rows)
         (height etaf-ui-text-grid-benchmark--height)
         (left (etaf-ref 0))
         (row-text
          (lambda (row)
            (let ((first (etaf-value left)))
              (concat (propertize (format "%7d " row) 'face 'bold)
                      (mapconcat
                       (lambda (column)
                         (propertize (etaf-ui-text-grid-benchmark--cell row column)
                                     'face (if (zerop (% (+ row column) 7)) 'italic 'default)))
                       (number-sequence first (+ first 29)) "")))))
         (runtime (progn
                    (etaf-mount buffer
                                (etaf-view (etaf-text-grid :rows rows :columns 248
                                                           :height height :ref 'sheet
                                                           :row-text row-text)))
                    (etaf-runtime-for-buffer buffer)))
         (offset 0) (column 0))
    (list
     :buffer buffer :environment #'etaf-ui-benchmark--environment
     :ready (lambda ()
              (if (eq mode 'gui) (etaf-refit runtime (selected-window))
                (etaf-runtime-refit runtime (* 250 (frame-char-width)) 50))
              t)
     :invoke
     (lambda (index)
       (pcase action
         ('step (setq offset (1+ offset)) (etaf-scroll-by runtime 'sheet 1))
         ('page (setq offset (+ offset height)) (etaf-scroll-by runtime 'sheet height))
         ('jump (setq offset (% (* (1+ index) 104729) (- rows height)))
                (etaf-scroll-to runtime 'sheet offset))
         ('column (setq column (1+ column)) (setf (etaf-value left) column))))
     :outcome (lambda () (append (list :offset offset :column column)
                                 (etaf-ui-benchmark--outcome buffer runtime)))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let ((first (buffer-substring-no-properties
                       (point-min) (min (point-max) (+ (point-min) 16))))
               (expected (concat (format "%7d " offset)
                                 (etaf-ui-text-grid-benchmark--cell offset column))))
           (cond ((/= (etaf-scroll-offset runtime 'sheet) offset)
                  (format "Viewport shows row %d, not %d"
                          (etaf-scroll-offset runtime 'sheet) offset))
                 ((not (equal first expected))
                  (format "First line starts %S, not %S" first expected))
                 (t t)))))
     :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda ()
                (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
                (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (case '((step 16 "one line") (page 50 "one viewport")
                (jump 50 "a far row") (column 50 "one column")))
  (let ((action (car case)))
    (taf-benchmark-register
     (format "text-grid.scroll.%s" action)
     :version 1 :modes '(batch gui) :isolation 'series
     :required-providers '(ebox) :budget-ms (nth 1 case) :impact 'subtree
     :description (format "Scroll a million-row, 31-cell styled text grid by %s"
                          (nth 2 case))
     :setup (lambda (mode) (etaf-ui-text-grid-benchmark--fixture mode action)))))

;;;; Scrolling cell sheet

(defconst etaf-ui-sheet-benchmark--rows 1000000
  "Rows of the cell sheet workload.")

(defconst etaf-ui-sheet-benchmark--height 40
  "Visible body lines of the cell sheet workload.")

(defconst etaf-ui-sheet-benchmark--widths
  (vector 9 5 6 8 10 7 12 9 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7)
  "Column widths of the cell sheet workload.")

(defun etaf-ui-sheet-benchmark--text (row column)
  "Return the cell text of ROW and COLUMN."
  (cl-case column
    (0 (format "Item %d" row))
    (1 (number-to-string (% (* row 37) 500)))
    (2 (format "%.2f" (/ (* 1.0 (1+ (% (* row 91) 900))) 7)))
    (4 (format "2026-%02d-%02d" (1+ (% row 12)) (1+ (% (* row 7) 28))))
    (t (number-to-string (% (+ (* row 100) column) 10000000)))))

(defun etaf-ui-sheet-benchmark--align (_row column)
  "Return the alignment of ROW and COLUMN."
  (if (memq column '(1 2 3)) 'right 'left))

(defun etaf-ui-sheet-benchmark--fixture (mode action)
  "Mount a million-row cell sheet for MODE and repeat ACTION.
ACTION is `step', `page' or `jump'."
  (let* ((buffer (generate-new-buffer " *Sheet benchmark*"))
         (rows etaf-ui-sheet-benchmark--rows)
         (height etaf-ui-sheet-benchmark--height)
         (cursor (etaf-ref (cons 0 0) :test #'equal))
         (runtime
          (progn
            (etaf-mount buffer
                        (etaf-view
                         (etaf-sheet :rows rows
                                     :columns (length etaf-ui-sheet-benchmark--widths)
                                     :widths etaf-ui-sheet-benchmark--widths
                                     :height height :cursor cursor :ref 'sheet
                                     :cell-text #'etaf-ui-sheet-benchmark--text
                                     :cell-align #'etaf-ui-sheet-benchmark--align
                                     :on-commit #'ignore)))
            (etaf-runtime-for-buffer buffer)))
         (offset 0))
    (list
     :buffer buffer :environment #'etaf-ui-benchmark--environment
     :ready (lambda ()
              (if (eq mode 'gui) (etaf-refit runtime (selected-window))
                (etaf-runtime-refit runtime (* 250 (frame-char-width)) 50))
              t)
     :invoke
     (lambda (index)
       (pcase action
         ('step (setq offset (1+ offset))
                (etaf-sheet-scroll runtime 'sheet 1))
         ('page (setq offset (+ offset height))
                (etaf-sheet-scroll runtime 'sheet height))
         ('jump (setq offset (% (* (1+ index) 104729) (- rows height)))
                (etaf-set-value cursor (cons offset 1))
                (etaf-sheet-reveal runtime 'sheet))))
     :outcome (lambda () (append (list :offset offset)
                                 (etaf-ui-benchmark--outcome buffer runtime)))
     :verify
     (lambda ()
       (with-current-buffer buffer
         ;; The viewport keeps overscan rows around the target, so the jump is
         ;; correct when the cursor's row is painted at all.
         (let ((painted (buffer-substring-no-properties (point-min) (point-max)))
               ;; The first column is narrower than a long row number, so the
               ;; needle is the text as painted, not as computed.
               (expected (truncate-string-to-width
                          (etaf-ui-sheet-benchmark--text offset 0)
                          (aref etaf-ui-sheet-benchmark--widths 0))))
           (cond ((not (string-match-p (regexp-quote expected) painted))
                  (format "Row %d (%s) is not painted" offset expected))
                 (t t)))))
     :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda ()
                (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
                (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (case '((step 16 "one line") (page 50 "one viewport") (jump 50 "a far row")))
  (let ((action (car case)))
    (taf-benchmark-register
     (format "sheet.scroll.%s" action)
     :version 1 :modes '(batch gui) :isolation 'series
     :required-providers '(ebox) :budget-ms (nth 1 case) :impact 'subtree
     :description (format "Scroll a million-row cell sheet by %s" (nth 2 case))
     :setup (lambda (mode) (etaf-ui-sheet-benchmark--fixture mode action)))))

(defun etaf-ui-editor-benchmark--typing (shared)
  "Compare native typing with SHARED editing behavior on the same text size."
  (let ((buffer (generate-new-buffer " *Editor typing benchmark*"))
        (initial (make-string 4096 ?x)))
    (with-current-buffer buffer
      (text-mode)
      (buffer-enable-undo)
      (insert initial)
      (visual-line-mode 1)
      (when shared
        (etaf-ui-editor-mode 1)
        (etaf-ui-editor-configure :placeholder "Write here"))
      (goto-char (point-max)))
    (list :buffer buffer
          :invoke (lambda (_sample)
                    (with-current-buffer buffer
                      (goto-char (point-max))
                      (let ((last-command-event ?字))
                        (call-interactively #'self-insert-command))
                      (redisplay t)))
          :verify (lambda ()
                    (with-current-buffer buffer
                      (and (> (buffer-size) 4096) (eq (char-before (point-max)) ?字))))
          :cleanup (lambda ()
                     (when (buffer-live-p buffer) (kill-buffer buffer))))))

(taf-benchmark-register
 "editor.native.typing" :version 1 :modes '(batch gui) :budget-ms 10
 :impact 'local :isolation 'series
 :description "Native self-insert plus redisplay on a 4 KiB multiline draft"
 :setup (lambda (_mode) (etaf-ui-editor-benchmark--typing nil)))

(taf-benchmark-register
 "editor.shared.typing" :version 1 :modes '(batch gui) :budget-ms 10
 :impact 'local :isolation 'series
 :description "Shared UI editing behavior on the same native 4 KiB draft"
 :setup (lambda (_mode) (etaf-ui-editor-benchmark--typing t)))

;;; performance-scenarios.el ends here
