;;; performance-scenarios.el --- ETAF runtime interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; Adapters for the workspace performance driver (scripts/performance.py).
;; The retained resize scenarios crop the same two-panel native scene either
;; through reactive props (ordinary fine-grained bindings) or through the
;; retained Host geometry boundary.  This is fixed text cropping, not the
;; catalog window or paragraph reflow.  The driver measures invocation
;; through the buffer write and forced redisplay.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'ebox)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-resize-benchmark--view (width height)
  "Build the same native scene with dynamic WIDTH and HEIGHT."
  (etaf-view
   (box :width '(px 640) :height '(lh 24) :position 'relative :background-color "#EAF0F6"
     (box :id "crop" :ref 'crop :position 'absolute :left '(px 16) :top '(lh 2)
          :width (if (etaf-ref-p width) (etaf-value width) width)
          :height (if (etaf-ref-p height) (etaf-value height) height)
          :min-width '(px 0) :min-height '(lh 0) :z-index 2
          :overflow 'hidden :wrap-mode 'none :background-color "#243447" :color "#F1F5F9"
          :role 'button :tab-index 0 :on-press #'ignore
       (text "Fixed native text: ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\nSecond row stays unchanged.\n第三行：裁剪与恢复。"))
     (box :id "peer" :ref 'peer :position 'absolute :left '(px 300) :top '(lh 8)
          :width '(px 160) :height '(lh 5) :z-index 1 :background-color "#705070"
       (text "Independent peer\nRestored after shrink")))))

(defconst etaf-resize-benchmark--properties
  '(face display font-lock-face pointer help-echo mouse-face)
  "Native text properties compared by value against a fresh mount.
Keymaps hold per-node closures, so only their presence is compared.")

(defun etaf-resize-benchmark--fresh-p (buffer view)
  "Return non-nil when BUFFER matches a fresh mount of VIEW.
The fresh mount uses BUFFER's viewport, so equal text and native properties
show the incremental writes left no stale cell behind."
  (let ((fresh (generate-new-buffer " *ETAF resize fresh*"))
        (viewport (etaf-runtime-viewport (etaf-runtime-for-buffer buffer))))
    (unwind-protect
        (progn
          (etaf-mount fresh view (list :viewport-width (car viewport)
                                       :viewport-height (cdr viewport)))
          (let ((actual (with-current-buffer buffer (buffer-string)))
                (expected (with-current-buffer fresh (buffer-string)))
                (position 0) same)
            (setq same (equal (substring-no-properties actual)
                              (substring-no-properties expected)))
            (while (and same (< position (length actual)))
              (dolist (property etaf-resize-benchmark--properties)
                (unless (equal (get-text-property position property actual)
                               (get-text-property position property expected))
                  (setq same nil)))
              (unless (eq (null (get-text-property position 'keymap actual))
                          (null (get-text-property position 'keymap expected)))
                (setq same nil))
              (setq position (1+ position)))
            same))
      (let ((runtime (etaf-runtime-for-buffer fresh)))
        (when runtime (etaf-unmount runtime)))
      (kill-buffer fresh))))

(defun etaf-resize-benchmark--fixture (route axis)
  "Create matched native output for ROUTE and resize AXIS.
ROUTE `runtime' writes reactive props; `geometry' calls
`etaf-runtime-update-host-geometry' on the retained Host."
  (let* ((buffer (generate-new-buffer " *ETAF retained resize benchmark*"))
         (width (etaf-ref '(px 320) :test #'equal))
         (height (etaf-ref '(lh 8) :test #'equal))
         (step 0) expected revision runtime)
    (etaf-mount buffer (etaf-resize-benchmark--view width height)
                (list :viewport-width 800 :viewport-height 30))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (list
     :buffer buffer
     :environment (lambda () (list :route (symbol-name route) :axis (symbol-name axis)
                                   :canvas-width 640 :canvas-height 24
                                   :body-reflow :false :physical-pointer-latency-certified :false))
     :prepare
     (lambda ()
       (setq step (1+ step)
             expected (if (cl-oddp step)
                          (list (if (eq axis 'height) 320 352)
                                (if (eq axis 'width) 8 10))
                        '(320 8))
             revision (etaf-runtime-revision runtime)))
     :invoke
     (lambda (_sample)
       (pcase route
         ('geometry
          (etaf-runtime-update-host-geometry
           runtime 'crop :width (list 'px (car expected)) :height (list 'lh (cadr expected))))
         ('runtime
          (etaf-batch
            (etaf-set-value width (list 'px (car expected)))
            (etaf-set-value height (list 'lh (cadr expected))))
          (etaf-runtime-flush runtime))))
     :verify
     (lambda ()
       (let ((geometry (etaf-host-ref-size runtime 'crop)))
         (cond
          ((/= (1+ revision) (etaf-runtime-revision runtime))
           "Resize did not publish exactly one revision")
          ((not (equal geometry
                       (cons (car expected) (cadr expected))))
           (format "Crop size %S, expected %S" geometry expected))
          ((not (etaf-resize-benchmark--fresh-p
                 buffer (etaf-resize-benchmark--view
                         (list 'px (car expected)) (list 'lh (cadr expected)))))
           "Incremental output differs from a fresh mount")
          (t t))))
     :outcome (lambda () (list :route (symbol-name route) :size (vconcat expected)
                               :revision (etaf-runtime-revision runtime)
                               :strategy (format "%s" (plist-get (ebox-buffer-update-report buffer)
                                                                 :strategy))))
     :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda ()
                (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
                (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (route '(runtime geometry))
  (dolist (axis '(width height corner))
    (let ((selected-route route) (selected-axis axis))
      (taf-benchmark-register
       (format "retained.resize.%s.%s" route axis)
       :version 2 :modes '(batch gui) :isolation 'series :required-providers '(ebox)
       :budget-ms 10 :impact 'local
       :description (format "Two native panels, fixed text %s crop via %s" axis route)
       :setup (lambda (_mode) (etaf-resize-benchmark--fixture selected-route selected-axis))))))

(defun etaf-resize-benchmark--native-fixture (sweep)
  "Exercise the mounted example's native input, optionally with a broad SWEEP."
   (let* ((buffer (etaf-retained-resize-open
                   (generate-new-buffer " *ETAF native resize benchmark*")))
          (runtime (etaf-runtime-for-buffer buffer))
          (step 0) expected events)
     (list
      :buffer buffer
      :environment (lambda () (list :input-route "native-keymap" :motion-queue "prequeued"
                                    :motion-count 1 :body-reflow :false
                                    :physical-pointer-latency-certified :false))
      :prepare
      (lambda ()
        (redisplay t)
        (let* ((window (get-buffer-window buffer t))
               (position (etaf-host-ref-position runtime 'resize-panel))
               (start (and position (posn-at-point position window)))
               (xy (and start (posn-x-y start)))
               (sign (if (if sweep (< (mod (1- (cl-incf step)) 16) 8)
                           (cl-oddp (cl-incf step))) 1 -1))
               (props (etaf-runtime-host-props-for runtime 'resize-panel))
               (dx (* sign (if sweep 32 8)))
               (dy (* sign (frame-char-height (window-frame window)))))
          (when (and sweep xy)
            ;; This example resizes from any painted body position. Use a
            ;; visible text cell with room for a negative movement, not the
            ;; leading position of a stretched trailing fill cell.
            (setq start (posn-at-x-y (+ (car xy) 48)
                                     (+ (cdr xy) 2) window)
                  xy (and start (posn-x-y start))
                  position (and start (posn-point start))))
          (unless (and (eq window (selected-window)) (consp xy)
                       (pos-visible-in-window-p position window))
            (error "Native resize example target is not visibly selected"))
          (setq expected (list (+ (cadr (plist-get props :width)) dx)
                               (+ (cadr (plist-get props :height)) sign)))
          (let ((end (list window position (cons (+ (car xy) dx) (+ (cdr xy) dy)) 2)))
            (setq events (vector (list 'down-mouse-1 start)
                                 (list 'mouse-movement end)
                                 (list 'drag-mouse-1 start end))))))
      :invoke (lambda (_sample) (execute-kbd-macro events) (etaf-runtime-flush runtime))
      :verify
      (lambda ()
        (let ((props (etaf-runtime-host-props-for runtime 'resize-panel)))
          (and (equal expected (list (cadr (plist-get props :width))
                                     (cadr (plist-get props :height))))
               (etaf-host-ref-position runtime 'resize-panel)
               (not (ebox-selector-query-buffer buffer ":active")))))
      :outcome (lambda () (list :size (vconcat expected)
                                :strategy (format "%s" (plist-get (ebox-buffer-update-report buffer)
                                                                  :strategy))))
      :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                 (lambda () (ebox-buffer-set-observer buffer nil)))
      :cleanup (lambda () (etaf-unmount runtime)
                 (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (sweep '(nil t))
  (let ((selected sweep))
    (taf-benchmark-register
     (if sweep "retained.resize.native.sweep" "retained.resize.native.corner")
     :version 1 :modes '(gui) :isolation 'series :required-providers '(ebox)
     :budget-ms 10 :impact 'local
     :description (if sweep "Native example resizing from 320x8 to 576x16 and back"
                    "Mounted resize example through native press, movement and release")
     :setup (lambda (_mode) (etaf-resize-benchmark--native-fixture selected)))))

;;; ---------------------------------------------------------------------------
;;; One row's update must not scale with the scene
;;; ---------------------------------------------------------------------------

;; A fixed-height row whose paint and weight change is the smallest possible
;; update; it must cost about the same in a 30-row and a 400-row scene.  Only
;; the bound row is restyled and only its buffer line is rewritten.

(etaf-define-component etaf-row-update-benchmark--probe (&key rows marked)
  "Render ROWS fixed-height rows; row 1's paint follows MARKED."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (box :for (row (number-sequence 1 rows)) :key row
         :height '(lh 1) :overflow 'hidden
         :bgcolor (if (and (equal row 1) (etaf-value marked))
                      "#1A2436" "#223344")
         :font-weight (if (and (equal row 1) (etaf-value marked)) 'bold 'normal)
         (text (expr (format "row %04d 汉字 ABC abcdefghijklmnopqrstuvwxyz" row))))))

(defun etaf-row-update-benchmark--bold-p (face)
  "Return non-nil when FACE carries a bold weight."
  (let ((faces (if (and (consp face) (keywordp (car face))) (list face) face)))
    (cl-some (lambda (entry) (eq (plist-get entry :weight) 'bold))
             (if (listp faces) faces nil))))

(defun etaf-row-update-benchmark--fixture (rows _mode)
  "Mount ROWS fixed-height rows and toggle one row's style per sample.
The runtime stays mounted until the driver calls the returned `:cleanup'."
  (let* ((buffer (generate-new-buffer (format " *TAF row update %s*" rows)))
         (marked (etaf-ref t :name 'etaf-row-update-marked))
         (runtime nil))
    (with-current-buffer buffer (setq-local truncate-lines t))
    (etaf-mount buffer
                (etaf-view (etaf-row-update-benchmark--probe
                            :rows rows :marked marked))
                (list :viewport-width 1200 :viewport-height 40))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (etaf-runtime-flush runtime)
    (list
     :buffer buffer
     :invoke (lambda (_sample)
               (etaf-performance-call-operation
                runtime 'benchmark "row-update"
                (lambda ()
                  (etaf-set-value marked (not (etaf-value marked)))
                  (etaf-runtime-flush runtime))))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let* ((position (+ (point-min) (string-match "row 0001" (buffer-string))))
                (bold (etaf-row-update-benchmark--bold-p
                       (get-text-property position 'face))))
           (if (eq bold (not (null (etaf-value marked)))) t
             (format "Row 1 bold=%s while marked=%s"
                     bold (etaf-value marked))))))
     :observe
     (lambda (sink)
       (etaf-performance-start runtime)
       (let ((before (mapcar (lambda (operation)
                              (cons (plist-get operation :runtime-id)
                                    (plist-get operation :id)))
                            (plist-get (etaf-performance-report-data) :operations))))
         (lambda ()
           (etaf-performance-stop runtime)
           (dolist (operation (plist-get (etaf-performance-report-data) :operations))
             (when (and (equal (plist-get operation :buffer-name) (buffer-name buffer))
                        (not (member (cons (plist-get operation :runtime-id)
                                           (plist-get operation :id)) before)))
               (dolist (stage (plist-get operation :stages))
                 (funcall sink
                          (append (list :provider (plist-get stage :provider)
                                        :stage (plist-get stage :stage)
                                        :duration-ms (plist-get stage :duration-ms))
                                  (plist-get stage :metadata)))))))))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
         (kill-buffer buffer))))))

(dolist (rows '(30 120 400))
  (let ((count rows))
    (taf-benchmark-register
     (format "row-update.%s" count)
     :version 1 :modes '(batch) :isolation 'series
     :required-providers '(etaf ebox)
     :impact 'local :budget-ms 10
     :description
     (format "One row's paint and weight toggle in a %d-row fixed-height scene; the cost must not scale with the scene"
             count)
     :setup (lambda (_mode) (etaf-row-update-benchmark--fixture count nil)))))

;; A keyed list append must cost like a one-row change: the keyed region
;; inserts one retained row and the buffer receives one inserted line.

(etaf-define-component etaf-list-append-benchmark--probe (&key rows)
  "Render ROWS one-line rows keyed by their number."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (box :for (row (etaf-value rows)) :key row
         :height '(lh 1) :overflow 'hidden
         (text (expr (format "row %04d 汉字 ABC abcdefghijklmnopqrstuvwxyz" row))))))

(defun etaf-list-append-benchmark--fixture (rows _mode)
  "Mount ROWS keyed rows and append one row per sample.
The runtime stays mounted until the driver calls the returned `:cleanup'."
  (let* ((buffer (generate-new-buffer (format " *TAF list append %s*" rows)))
         (rows-ref (etaf-ref (number-sequence 1 rows) :name 'etaf-list-append-rows))
         (appended 0)
         runtime)
    (with-current-buffer buffer (setq-local truncate-lines t))
    (etaf-mount buffer
                (etaf-view (etaf-list-append-benchmark--probe :rows rows-ref))
                (list :viewport-width 1200 :viewport-height 40))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (etaf-runtime-flush runtime)
    (list
     :buffer buffer
     :environment (lambda () (list :rows rows :viewport-rows 40))
     :invoke (lambda (_sample)
               (cl-incf appended)
               (etaf-performance-call-operation
                runtime 'benchmark "list-append"
                (lambda ()
                  (etaf-set-value rows-ref
                                  (append (etaf-value rows-ref)
                                          (list (+ rows appended))))
                  (etaf-runtime-flush runtime))))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let ((newest (format "row %04d" (+ rows appended))))
           (if (string-match-p newest (buffer-substring-no-properties
                                       (point-min) (point-max)))
               t
             (format "appended %s is not published" newest)))))
     :observe
     (lambda (sink)
       (etaf-performance-start runtime)
       (let ((before (mapcar (lambda (operation)
                               (cons (plist-get operation :runtime-id)
                                     (plist-get operation :id)))
                             (plist-get (etaf-performance-report-data) :operations))))
         (lambda ()
           (etaf-performance-stop runtime)
           (dolist (operation (plist-get (etaf-performance-report-data) :operations))
             (when (and (equal (plist-get operation :buffer-name) (buffer-name buffer))
                        (not (member (cons (plist-get operation :runtime-id)
                                           (plist-get operation :id)) before)))
               (dolist (stage (plist-get operation :stages))
                 (funcall sink
                          (append (list :provider (plist-get stage :provider)
                                        :stage (plist-get stage :stage)
                                        :duration-ms (plist-get stage :duration-ms))
                                  (plist-get stage :metadata)))))))))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
         (kill-buffer buffer))))))

(dolist (rows '(30 120))
  (let ((count rows))
    (taf-benchmark-register
     (format "list-append.%s" count)
     :version 1 :modes '(batch) :isolation 'series
     :required-providers '(etaf ebox)
     :impact 'local :budget-ms 10
     :description
     (format "Append one keyed row to a %d-row list; the cost must not scale with the list"
             count)
     :setup (lambda (_mode) (etaf-list-append-benchmark--fixture count nil)))))

;;; ---------------------------------------------------------------------------
;;; Retained Host content frames
;;; ---------------------------------------------------------------------------

(defconst etaf-video-frame-benchmark--ramp " .:-=+*#%@"
  "Density ramp used by the ASCII video application.")

(defun etaf-video-frame-benchmark--frame (columns rows index)
  "Return a deterministic video-like frame of COLUMNS by ROWS ramp cells.
INDEX moves the pattern so consecutive invocations publish different text."
  (let ((ramp etaf-video-frame-benchmark--ramp)
        (last (1- (length etaf-video-frame-benchmark--ramp)))
        (lines nil))
    (dotimes (row rows)
      (let ((line (make-string columns ?\s)))
        (dotimes (column columns)
          (let* ((phase (mod (+ (* 3 column) (* 7 index) (* 13 row)) 256))
                 (level (max 0 (min last (/ (+ (* phase last) 127) 255)))))
            (aset line column (aref ramp level))))
        (push line lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun etaf-video-frame-benchmark--fixture (columns rows _mode)
  "Mount a fixed COLUMNS by ROWS canvas and publish frame texts.
The fixture is steady state: one retained Host text update per sample, and no
layout, style or interaction change."
  (let* ((buffer (generate-new-buffer
                  (format " *TAF video frame %dx%d*" columns rows)))
         (frames (cl-loop for index below 32
                          collect (etaf-video-frame-benchmark--frame columns rows index)))
         (index 0)
         (expected nil)
         runtime)
    (with-current-buffer buffer (setq-local truncate-lines t))
    (etaf-mount buffer
                (etaf-view
                 (flex :flex-direction 'column :width (list 'ch columns)
                       (box :width (list 'ch columns) :height (list 'lh rows)
                            :wrap-mode 'none :overflow 'hidden
                            (text :id "grid" :ref 'grid " "))
                       (box :height '(lh 1)
                            (text :id "hud" :ref 'hud "hud"))))
                (list :viewport-width 1200 :viewport-height (+ rows 4)))
    (setq runtime (etaf-runtime-for-buffer buffer))
    (etaf-runtime-flush runtime)
    (list
     :buffer buffer
     :environment (lambda ()
                    (list :columns columns :rows rows :chars (* columns rows)
                          :frames (length frames)))
     :invoke (lambda (_sample)
               (setq expected (nth (% index (length frames)) frames)
                     index (1+ index))
               (etaf-runtime-update-host-contents
                runtime (list (cons 'grid expected))))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (let* ((actual (substring-no-properties (buffer-string)))
                (first (car (split-string expected "\n"))))
           (if (string-prefix-p first actual) t
             (format "Published first row differs for frame %d" (1- index))))))
     :observe (lambda (sink) (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup
     (lambda ()
       (when (buffer-live-p buffer)
         (when (etaf-runtime-for-buffer buffer) (etaf-unmount runtime))
         (kill-buffer buffer))))))

(dolist (size '((160 . 45) (96 . 27)))
  (let ((columns (car size))
        (rows (cdr size)))
    (taf-benchmark-register
     (format "host-content.video-frame.%dx%d" columns rows)
     :version 1 :modes '(batch gui) :isolation 'series
     :required-providers '(ebox)
     :impact 'local :budget-ms 33
     :description
     (format "One video-like frame (%d ramp cells) as a retained Host text update; the cost must fit a 30 fps frame budget"
             (* columns rows))
     :setup (lambda (_mode) (etaf-video-frame-benchmark--fixture columns rows nil)))))

;;; ---------------------------------------------------------------------------
;;; Fine-grained update gates
;;; ---------------------------------------------------------------------------

;; Each gate isolates one class of change in a scene of 30, 400 or 10000
;; rows.  A local change must cost the same at every scale; mount and resize
;; are measured per row.  Row 1 carries the changing value so the scenes
;; differ only by their unchanged tail.

(defconst etaf-gate-benchmark--row-text "row %05d 汉字 ABC abcdefghijklmnopqrstuvwxyz"
  "Format of an unchanged gate row.")

(etaf-define-component etaf-gate-benchmark--rows (&key rows marked label)
  "Render ROWS fixed one-line rows; row 1 follows MARKED and LABEL."
  :view
  (column :width 'stretch
    (box :for (row (number-sequence 1 rows)) :key row
         :height '(lh 1) :overflow 'hidden
         :bgcolor (if (and (equal row 1) (etaf-value marked)) "#1A2436" "#223344")
         :font-weight (if (and (equal row 1) (etaf-value marked)) 'bold 'normal)
         (text (expr (if (equal row 1) (etaf-value label)
                       (format etaf-gate-benchmark--row-text row)))))))

(etaf-define-component etaf-gate-benchmark--flex-rows (&key rows label)
  "Render ROWS flex rows whose first item is auto-width text."
  :view
  (column :width 'stretch
    (flex :for (row (number-sequence 1 rows)) :key row
          :height '(lh 1) :column-gap '(ch 1)
      (box (text (expr (if (equal row 1) (etaf-value label)
                         (format "row %05d" row)))))
      (box :flex-grow 1 :min-width '(px 0) :overflow 'hidden :wrap-mode 'none
           "汉字 ABC abcdefghijklmnopqrstuvwxyz")
      (box :width '(ch 8) "fixed"))))

(etaf-define-component etaf-gate-benchmark--list (&key rows)
  "Render the keyed one-line ROWS ref."
  :view
  (column :width 'stretch
    (box :for (row (etaf-value rows)) :key row
         :height '(lh 1) :overflow 'hidden
         (text (expr (format etaf-gate-benchmark--row-text row))))))

(etaf-define-component etaf-gate-benchmark--wrapped (&key rows)
  "Render ROWS stretch-width paragraphs that rewrap with the viewport."
  :view
  (column :width 'stretch :padding-inline '(ch 1)
    (box :for (row (number-sequence 1 rows)) :key row
         :border-bottom '((px 1) solid "#556677")
         (text (expr (format "%05d the quick brown fox jumps over the lazy dog; 汉字排版 %s"
                             row (make-string (% row 7) ?x)))))))

(etaf-define-component etaf-gate-benchmark--counter (&key count)
  "Render COUNT and one focusable button."
  :view
  (column
    (text (expr (format "Count: %d" (etaf-value count))))
    (box :role 'button :tab-index 0 "Increment")))

(defun etaf-gate-benchmark--mount (view)
  "Mount VIEW in a fresh buffer and return (BUFFER . RUNTIME)."
  (let ((buffer (generate-new-buffer " *TAF gate*")))
    (with-current-buffer buffer (setq-local truncate-lines t))
    (etaf-mount buffer view (list :viewport-width 1200 :viewport-height 40))
    (let ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-runtime-flush runtime)
      (cons buffer runtime))))

(defun etaf-gate-benchmark--first-line (buffer)
  "Return BUFFER's first line without properties."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (buffer-substring-no-properties (point) (line-end-position)))))

(defun etaf-gate-benchmark--cleanup (mounted)
  "Return a cleanup function for MOUNTED (BUFFER . RUNTIME)."
  (lambda ()
    (let ((buffer (car mounted)))
      (when (buffer-live-p buffer)
        (when (etaf-runtime-for-buffer buffer) (etaf-unmount (cdr mounted)))
        (kill-buffer buffer)))))

(defun etaf-gate-benchmark--observed (fixture)
  "Return FIXTURE with an :observe hook for the GUI gate's diff twin.
Each sample must flush the mounted buffer at most once; the hook passes that
flush's Ebox report, whose :ranges let the gate replay the same edit on a
plain buffer."
  (let* ((buffer (plist-get fixture :buffer))
         (invoke (plist-get fixture :invoke))
         (sink nil))
    (append
     (list :invoke
           (lambda (sample)
             (if (null sink)
                 (funcall invoke sample)
               (let ((before (ebox-mount-flush-count buffer)))
                 (funcall invoke sample)
                 (pcase (- (ebox-mount-flush-count buffer) before)
                   (0 nil)
                   (1 (funcall sink buffer (ebox-buffer-update-report buffer)))
                   (n (error "Sample %d flushed %d times" sample n))))))
           :observe (lambda (function)
                      (setq sink function)
                      (lambda () (setq sink nil))))
     fixture)))

(defun etaf-gate-benchmark--row-fixture (rows kind)
  "Mount ROWS rows and change row 1 by KIND: paint, text or text-width."
  (let* ((marked (etaf-ref nil))
         (label (etaf-ref (format etaf-gate-benchmark--row-text 1)))
         (mounted (etaf-gate-benchmark--mount
                   (etaf-view (etaf-gate-benchmark--rows
                               :rows rows :marked marked :label label))))
         (expected nil))
    (list
     :buffer (car mounted)
     :invoke
     (lambda (sample)
       (pcase kind
         ('paint (etaf-set-value marked (not (etaf-value marked))))
         ('text (setq expected (format "row %05d 汉字 ABC changed!!!!!!!!!!!" (% sample 100000)))
                (etaf-set-value label expected))
         (_ (setq expected (make-string (+ 4 (% (* 7 sample) 41)) ?x))
            (etaf-set-value label expected)))
       (etaf-runtime-flush (cdr mounted)))
     :verify
     (lambda ()
       (let ((line (etaf-gate-benchmark--first-line (car mounted))))
         (cond
          ((eq kind 'paint)
           (with-current-buffer (car mounted)
             (let ((face (get-text-property (point-min) 'face)))
               (if (eq (not (null (etaf-value marked)))
                       (not (null (or (eq (plist-get face :weight) 'bold)
                                      (and (consp (car-safe face))
                                           (cl-some (lambda (f) (eq (plist-get f :weight) 'bold))
                                                    face))))))
                   t
                 "Row 1 weight does not follow its state"))))
          ((string-prefix-p expected line) t)
          (t (format "Row 1 shows %S" line)))))
     :cleanup (etaf-gate-benchmark--cleanup mounted))))

(defun etaf-gate-benchmark--flex-fixture (rows)
  "Mount ROWS flex rows and change row 1's auto-width label."
  (let* ((label (etaf-ref "row 00001"))
         (mounted (etaf-gate-benchmark--mount
                   (etaf-view (etaf-gate-benchmark--flex-rows :rows rows :label label))))
         (expected nil))
    (list
     :buffer (car mounted)
     :invoke (lambda (sample)
               (setq expected (concat "item " (make-string (+ 1 (% (* 5 sample) 23)) ?y)))
               (etaf-set-value label expected)
               (etaf-runtime-flush (cdr mounted)))
     :verify (lambda ()
               (let ((line (etaf-gate-benchmark--first-line (car mounted))))
                 (if (and (string-prefix-p expected line) (string-match-p "fixed" line)) t
                   (format "Row 1 shows %S" line))))
     :cleanup (etaf-gate-benchmark--cleanup mounted))))

(defun etaf-gate-benchmark--append-fixture (rows)
  "Mount a ROWS keyed list and append one row per sample by snapshot."
  (let* ((items (etaf-ref (number-sequence 1 rows)))
         (mounted (etaf-gate-benchmark--mount
                   (etaf-view (etaf-gate-benchmark--list :rows items))))
         (next rows))
    (list
     :buffer (car mounted)
     :invoke (lambda (_sample)
               (cl-incf next)
               (etaf-set-value items (append (etaf-value items) (list next)))
               (etaf-runtime-flush (cdr mounted)))
     :verify (lambda ()
               (with-current-buffer (car mounted)
                 (save-excursion
                   (goto-char (point-max))
                   (if (string-prefix-p (format "row %05d" next)
                                        (buffer-substring-no-properties
                                         (line-beginning-position) (point)))
                       t
                     "The appended row is not last"))))
     :cleanup (etaf-gate-benchmark--cleanup mounted))))

(defun etaf-gate-benchmark--data-fixture (rows)
  "Mount a ROWS Data-backed list and insert one item per sample."
  (let* ((source (etaf-data-memory-source (number-sequence 1 rows)))
         (controller (etaf-data-controller source :page-size 1000000 :auto-load t))
         (mounted (etaf-gate-benchmark--mount
                   (etaf-view (etaf-gate-benchmark--list :rows (etaf-data-items controller)))))
         (next rows))
    (list
     :buffer (car mounted)
     :invoke (lambda (_sample)
               (cl-incf next)
               (etaf-data-mutate controller 'insert next)
               (etaf-runtime-flush (cdr mounted)))
     :verify (lambda ()
               (if (string-match-p (format "row %05d" next)
                                   (with-current-buffer (car mounted)
                                     (buffer-substring-no-properties
                                      (max (point-min) (- (point-max) 200)) (point-max))))
                   t
                 "The inserted item is not visible at the end"))
     :cleanup (lambda ()
                (funcall (etaf-gate-benchmark--cleanup mounted))
                (etaf-data-stop controller)))))

(defun etaf-gate-benchmark--counter-fixture ()
  "Mount the counter and increment it once per sample."
  (let* ((count (etaf-ref 0))
         (mounted (etaf-gate-benchmark--mount
                   (etaf-view (etaf-gate-benchmark--counter :count count)))))
    (list
     :buffer (car mounted)
     :invoke (lambda (_sample)
               (etaf-set-value count (1+ (etaf-value count)))
               (etaf-runtime-flush (cdr mounted)))
     :verify (lambda ()
               (let ((line (etaf-gate-benchmark--first-line (car mounted))))
                 (if (string-prefix-p (format "Count: %d" (etaf-value count)) line) t
                   (format "Counter shows %S" line))))
     :cleanup (etaf-gate-benchmark--cleanup mounted))))

(defun etaf-gate-benchmark--mount-fixture (rows)
  "Mount ROWS rows once per sample into a fresh buffer."
  (let ((mounted nil))
    (list
     :buffer (get-buffer-create " *TAF gate mount host*")
     :prepare (lambda ()
                (when mounted (funcall (etaf-gate-benchmark--cleanup mounted)))
                (setq mounted nil))
     :invoke (lambda (_sample)
               (let ((marked (etaf-ref nil))
                     (label (etaf-ref (format etaf-gate-benchmark--row-text 1))))
                 (setq mounted (etaf-gate-benchmark--mount
                                (etaf-view (etaf-gate-benchmark--rows
                                            :rows rows :marked marked :label label))))))
     :verify (lambda ()
               (with-current-buffer (car mounted)
                 (if (= rows (count-lines (point-min) (point-max))) t
                   (format "Mounted %d lines" (count-lines (point-min) (point-max))))))
     :cleanup (lambda ()
                (when mounted (funcall (etaf-gate-benchmark--cleanup mounted)))
                (kill-buffer " *TAF gate mount host*")))))

(defun etaf-gate-benchmark--resize-fixture (rows)
  "Mount ROWS rewrapping paragraphs and alternate the viewport width."
  (let* ((mounted (etaf-gate-benchmark--mount
                   (etaf-view (etaf-gate-benchmark--wrapped :rows rows))))
         (width nil))
    (list
     :buffer (car mounted)
     :invoke (lambda (sample)
               (setq width (if (cl-oddp sample) 400 1200))
               (etaf-runtime-refit (cdr mounted) width 40)
               (etaf-runtime-flush (cdr mounted)))
     :verify (lambda ()
               (if (equal width (car (etaf-runtime-viewport (cdr mounted)))) t
                 (format "Viewport is %S" (etaf-runtime-viewport (cdr mounted)))))
     :cleanup (etaf-gate-benchmark--cleanup mounted))))

(dolist (rows '(30 400 10000))
  (let ((count rows))
    (dolist (kind '(paint text text-width))
      (let ((selected kind))
        (taf-benchmark-register
         (format "gate.%s.%d" kind count)
         :version 1 :modes '(batch gui) :isolation 'series :impact 'local
         :budget-ms (if (eq kind 'paint) 0.2 0.2)
         :description (format "Row 1 %s change in a %d-row scene; must not scale with the scene"
                              kind count)
         :gate '(:class local :twin diff)
         :setup (lambda (_mode)
                  (etaf-gate-benchmark--observed
                   (etaf-gate-benchmark--row-fixture count selected))))))
    (taf-benchmark-register
     (format "gate.flex-text.%d" count)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 0.2
     :description (format "Auto-width Flex text change in row 1 of %d rows" count)
     :gate '(:class propagate :twin diff)
     :setup (lambda (_mode)
              (etaf-gate-benchmark--observed (etaf-gate-benchmark--flex-fixture count))))
    (taf-benchmark-register
     (format "gate.append.%d" count)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'local
     :budget-ms (if (>= count 10000) 2 0.3)
     :description (format "Snapshot append of one keyed row to %d rows" count)
     :gate '(:class snapshot :twin diff)
     :setup (lambda (_mode)
              (etaf-gate-benchmark--observed (etaf-gate-benchmark--append-fixture count))))
    (taf-benchmark-register
     (format "gate.data-append.%d" count)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 0.3
     :description (format "Data insert of one item into %d loaded items" count)
     :gate '(:class structure :twin diff)
     :setup (lambda (_mode)
              (etaf-gate-benchmark--observed (etaf-gate-benchmark--data-fixture count))))
    (taf-benchmark-register
     (format "gate.mount.%d" count)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'global
     :budget-ms (* 0.04 count)
     :description (format "Mount %d fixed rows (40 us per row)" count)
     :gate '(:class rows)
     :setup (lambda (_mode) (etaf-gate-benchmark--mount-fixture count)))))

(taf-benchmark-register
 "gate.counter"
 :version 1 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 0.03
 :description "Increment a minimal reactive counter"
 :gate '(:class counter :twin diff)
 :setup (lambda (_mode)
          (etaf-gate-benchmark--observed (etaf-gate-benchmark--counter-fixture))))

(taf-benchmark-register
 "gate.resize.400"
 :version 1 :modes '(batch gui) :isolation 'series :impact 'global :budget-ms 16
 :description "Rewrap 400 stretch-width paragraphs after a viewport width change"
 :gate '(:class resize)
 :setup (lambda (_mode) (etaf-gate-benchmark--resize-fixture 400)))

(defun etaf-animation-benchmark--scene (buffer)
  "Read only the animated scene's visible text in BUFFER, not its edit pad."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (search-forward "EDIT PAD")
      (buffer-substring-no-properties (point-min) (match-beginning 0)))))

(defun etaf-animation-benchmark--fixture (paused &optional sustained)
  "Type in the theatre with its clock running or PAUSED.
SUSTAINED omits inter-key waits and checks visible animation continuity.
The shared driver owns timing, redisplay and diagnostics."
  (let* ((buffer (etaf-animation-example-open))
         (runtime (etaf-runtime-for-buffer buffer))
         (last-change (float-time)) (longest-gap 0.0) (changes 0)
         scene session before expected started (keystrokes 0))
    (etaf-dispatch-event runtime 'clear-button 'press)
    (when paused (etaf-dispatch-event runtime 'pause-button 'press))
    (list
     :buffer buffer
     :environment (lambda () (list :panels 20 :frame-rate 15 :paused (if paused t :false)
                                   :sustained (if sustained t :false)
                                   :input-route "native-keyboard-macro"
                                   :physical-pointer-latency-certified :false))
     :prepare
     (lambda ()
       ;; Keyboard macros use the selected window, not `with-current-buffer'.
       (switch-to-buffer buffer)
       (unless session
         (etaf-dispatch-event runtime 'edit-button 'press)
         (setq session (etaf-input-active-p runtime)))
       ;; Allow actual animation publications between keystrokes, outside the
       ;; timed input boundary.  The paused twin uses the same waiting period.
       (unless sustained (sleep-for 0.1))
       (setq before (etaf-input-text session)
             expected (if (equal before "X") "" "X")))
     :invoke
     (lambda (_sample)
       (etaf-performance-call-operation
        runtime 'benchmark "animation-input"
        (lambda ()
          ;; Measure continuity inside the burst.  The driver's environment
          ;; snapshots between samples deliberately do not count as input load.
          (setq started (float-time) last-change started longest-gap 0.0
                changes 0 keystrokes 0
                scene (and sustained (etaf-animation-benchmark--scene buffer)))
          (while (or (zerop keystrokes)
                     (and sustained (< (- (float-time) started) 0.2)))
            (cl-incf keystrokes)
            (setq before (etaf-input-text session)
                  expected (if (equal before "X") "" "X"))
            (execute-kbd-macro (if (equal before "X") (kbd "DEL") "X"))
            (when sustained
              ;; Yield to the same timers as the native command loop; no
              ;; synthetic human pause is inserted between keystrokes.
              (accept-process-output nil 0.001)
              (redisplay t)
              (let ((now (float-time))
                    (visible (etaf-animation-benchmark--scene buffer)))
                (setq longest-gap (max longest-gap (- now last-change)))
                (unless (equal visible scene)
                  (setq scene visible last-change now changes (1+ changes)))))))))
     :verify (lambda ()
               (cond
                ((not (equal (etaf-input-text session) expected))
                 "Native editing lost the typed or deleted character")
                ((and sustained (> longest-gap 0.15))
                 "Visible animations stopped for over 150 ms during sustained input")
                ((and sustained (zerop changes))
                 "No visible animation advanced during the continuous input burst")
                (t t)))
     :outcome (lambda () (list :text (etaf-input-text session)
                               :keystrokes keystrokes :scene-changes changes
                               :max-observed-scene-gap-ms (* 1000 longest-gap)
                               :revision (etaf-runtime-revision runtime)))
     :observe
     (lambda (sink)
       (etaf-performance-clear)
       (etaf-performance-start runtime)
       (lambda ()
         (etaf-performance-stop runtime)
         (dolist (operation (plist-get (etaf-performance-report-data) :operations))
           (dolist (stage (plist-get operation :stages))
             (funcall sink
                      (append (list :provider (plist-get stage :provider)
                                    :stage (plist-get stage :stage)
                                    :duration-ms (plist-get stage :duration-ms))
                              (plist-get stage :metadata)))))))
     :cleanup (lambda () (etaf-unmount runtime)
                (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (paused '(nil t))
  (let ((selected paused))
    (taf-benchmark-register
     (if paused "animation.theatre.edit.paused" "animation.theatre.edit.running")
     :version 2 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 50
     :required-providers '(ebox)
     :description "One native keystroke with twenty responsive animation panels, including forced redisplay"
     :setup (lambda (_mode) (etaf-animation-benchmark--fixture selected)))))

(taf-benchmark-register
 "animation.theatre.edit.sustained"
 :version 4 :modes '(gui) :isolation 'series :impact 'local :budget-ms 400
 :required-providers '(ebox)
 :description "200 ms of native keystrokes at full speed with redisplay; animation gaps under 150 ms"
 :setup (lambda (_mode) (etaf-animation-benchmark--fixture nil t)))

(defun etaf-animation-benchmark--multiline-fixture ()
  "Replace multiline native drafts while the theatre continues animating."
  (let* ((fixture (etaf-animation-benchmark--fixture nil))
         (buffer (plist-get fixture :buffer))
         (runtime (etaf-runtime-for-buffer buffer))
         (drafts (list (mapconcat #'identity (make-list 12 "line 汉字") "\n")
                       "" (make-string 400 ?x)))
         expected)
    (plist-put fixture :invoke
               (lambda (sample)
                 (setq expected (nth (mod sample (length drafts)) drafts))
                 (etaf-performance-call-operation
                  runtime 'benchmark "animation-multiline-input"
                  (lambda ()
                    (let ((interprogram-cut-function nil)
                          (interprogram-paste-function nil))
                      (execute-kbd-macro (kbd "C-x h C-w"))
                      (unless (string-empty-p expected)
                        (let* ((kill-ring (list expected))
                               (kill-ring-yank-pointer kill-ring))
                          (execute-kbd-macro (kbd "C-y")))))))))
    (plist-put fixture :verify
               (lambda ()
                 (let ((session (etaf-input-active-p runtime)) (footers 0))
                   (with-current-buffer buffer
                     (save-excursion
                       (goto-char (point-min))
                       (while (search-forward "one shared clock" nil t)
                         (cl-incf footers))))
                   (cond ((not (equal (etaf-input-text session) expected))
                          "Multiline native draft differs from the edited value")
                         ((/= footers 1) "Multiline editing duplicated or erased the footer")
                         ((not (etaf-host-ref-bounds runtime 'edit-button))
                          "Multiline editing collapsed its toolbar")
                         (t t)))))
    (plist-put fixture :outcome
               (lambda () (list :draft-chars (length expected)
                                 :revision (etaf-runtime-revision runtime))))
    fixture))

(taf-benchmark-register
 "animation.theatre.edit.multiline"
 :version 2 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 50
 :required-providers '(ebox)
 :description "Native multiline paste, empty draft and long-line wrapping with animated neighbours"
 :setup (lambda (_mode) (etaf-animation-benchmark--multiline-fixture)))

(defun etaf-animation-benchmark--pointer-fixture ()
  "Exercise complete native clicks on the empty pad and its Edit button."
  (let* ((fixture (etaf-animation-benchmark--fixture nil))
         (buffer (plist-get fixture :buffer))
         (runtime (etaf-runtime-for-buffer buffer))
         (step 0) target
         (position (lambda ()
                     (if (eq target 'edit-button)
                         (etaf-host-ref-position runtime target)
                       (save-excursion
                         (goto-char (car (etaf-host-ref-bounds runtime 'pad)))
                         (forward-line 2) (point))))))
    (plist-put fixture :prepare
               (lambda ()
                 (switch-to-buffer buffer)
                 (etaf-refit runtime (selected-window))
                 (etaf-dispatch-event runtime 'clear-button 'press)
                 (setq target (if (cl-oddp (cl-incf step)) 'edit-button 'pad))
                 (redisplay t)
                 (let* ((position (funcall position))
                        (window (get-buffer-window buffer t))
                        (posn (progn
                                (goto-char position)
                                (recenter)
                                (redisplay t)
                                (posn-at-point position window))))
                   (unless (and (eq window (selected-window)) posn
                                (pos-visible-in-window-p position window))
                     (error "The empty pad click target is not visibly selected"))
                   t)))
    (plist-put fixture :invoke
               (lambda (_sample)
                 (etaf-performance-call-operation
                  runtime 'benchmark "animation-pointer-input"
                  (lambda ()
                    ;; Animation changes buffer positions while the driver
                    ;; records its environment. Resolve the published target
                    ;; at dispatch, not from the earlier prepare snapshot.
                    (redisplay t)
                    (let ((posn (posn-at-point (funcall position) (selected-window))))
                      (unless posn (error "Pointer target is no longer visible"))
                      (execute-kbd-macro (vector (list 'down-mouse-1 posn)
                                                 (list 'mouse-1 posn))))
                    (execute-kbd-macro "x")
                    (execute-kbd-macro (kbd "DEL"))))))
    (plist-put fixture :verify
               (lambda ()
                 (let ((session (etaf-input-active-p runtime)))
                   (cond ((not session) "Mouse release ended the newly opened editor")
                         ((not (equal (etaf-input-text session) ""))
                          "Typing and deleting after the click did not edit the draft")
                         (t t)))))
    (plist-put fixture :outcome
               (lambda () (list :target (symbol-name target)
                                 :active (if (etaf-input-active-p runtime) t :false))))
    fixture))

(taf-benchmark-register
 "animation.theatre.edit.pointer"
 :version 1 :modes '(gui) :isolation 'series :impact 'local :budget-ms 50
 :required-providers '(ebox)
 :description "Full mouse press/release on the empty pad or Edit button, then type and delete"
 :setup (lambda (_mode) (etaf-animation-benchmark--pointer-fixture)))

;;; performance-scenarios.el ends here
