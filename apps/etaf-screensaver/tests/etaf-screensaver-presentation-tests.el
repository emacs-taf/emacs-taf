;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-presentation-tests.el --- Public presentation acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Observe the public buffer, status and callback contexts.  No engine helpers
;; or structures are used: a tile must actually publish its own moving work.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-screensaver)

(defmacro etaf-screensaver-presentation-tests--clean (&rest body)
  "Run BODY with isolated settings and unconditional teardown."
  (declare (indent 0))
  `(let ((etaf-screensaver-seed 99)
         (etaf-screensaver-presentation 'full)
         (etaf-screensaver-max-frame-rate 60)
         (etaf-screensaver-scene-options nil))
     (etaf-screensaver-mode -1)
     (unwind-protect (progn ,@body)
       (etaf-screensaver-stop))))

(defun etaf-screensaver-presentation-tests--wait (predicate)
  "Wait at most three seconds for public observation PREDICATE."
  (let ((deadline (+ (float-time) 3)))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (sleep-for 0.005)))
  (should (funcall predicate)))

(defun etaf-screensaver-presentation-tests--text (buffer)
  "Return BUFFER's plain visible text."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-screensaver-presentation-tests--row-widths (buffer)
  "Return the displayed pixel widths of BUFFER's canvas rows."
  (with-current-buffer buffer
    (mapcar #'etaf-string-pixel-width
            (split-string (string-remove-suffix "\n" (buffer-substring (point-min) (point-max)))
                          "\n"))))

(defun etaf-screensaver-presentation-tests--display-width (text metrics)
  "Return TEXT's displayed pixel width using its compact space runs."
  (let ((index 0) (width 0)
        (cell (plist-get metrics :char-width)))
    (while (< index (length text))
      (let* ((display (get-text-property index 'display text))
             (space (and (eq (car-safe display) 'space)
                         (plist-get (cdr display) :width))))
        (cl-incf width (if (and (listp space) (numberp (car space)))
                           (car space)
                         (* (char-width (aref text index)) cell))))
      (cl-incf index))
    width))

(ert-deftest etaf-screensaver-presentation-tests-color-only-animation ()
  "A frame changing only face properties must still repaint after its first tick."
  (etaf-screensaver-presentation-tests--clean
    (etaf-screensaver-define-scene presentation-colors
      :frame-rate 40
      :create (lambda (_context) nil)
      :step (lambda (_state _context) nil)
      :render (lambda (_state context)
                (list (propertize "CHROMA" 'face
                                  (list :foreground
                                        (if (< (plist-get context :tick) 2)
                                            "#FF0000" "#00FF00"))))))
    (let ((buffer (etaf-screensaver-start 'presentation-colors)))
      (etaf-screensaver-presentation-tests--wait
       (lambda () (>= (or (plist-get (etaf-screensaver-status) :ticks) 0) 3)))
      (let ((color (with-current-buffer buffer
                     (save-excursion
                       (goto-char (point-min))
                       (search-forward "CHROMA")
                       (let ((face (get-text-property (- (point) 6) 'face)))
                         (cl-loop for spec in (if (keywordp (car-safe face))
                                                 (list face) face)
                                  thereis (and (listp spec)
                                               (plist-get spec :foreground))))))))
        (should (equal color "#00FF00"))))))

(ert-deftest etaf-screensaver-presentation-tests-sparse-frames-clear-cells ()
  "Moving sparse layers leave no old glyphs, wide continuations or colors."
  (etaf-screensaver-presentation-tests--clean
    (etaf-screensaver-register-scene
     '(:id presentation-sparse :frame-rate 40
       :layers ((:kind particles :count 1
                 :draw (:x (if (< tick 2) 0 3) :y 0
                        :char (if (< tick 2) "中" "X")
                        :color (if (< tick 2) "#FF0000" nil))))))
    (cl-labels ((red-p (text)
                  (let ((position 0) found)
                    (while (< position (length text))
                      (let ((face (get-text-property position 'face text)))
                        (when (cl-some
                               (lambda (spec)
                                 (and (listp spec)
                                      (equal (plist-get spec :foreground) "#FF0000")))
                               (if (keywordp (car-safe face)) (list face) face))
                          (setq found t)))
                      (setq position (next-single-property-change
                                      position 'face text (length text))))
                    found)))
      (let* ((buffer (etaf-screensaver-start 'presentation-sparse))
             (snapshot (with-current-buffer buffer
                         (buffer-substring (point-min) (point-max))))
             (original (copy-sequence snapshot))
             (initial-wide (string-match-p "中" snapshot))
             (initial-red (red-p snapshot)))
        (should initial-wide)
        (should initial-red)
        (etaf-screensaver-presentation-tests--wait
         (lambda () (>= (plist-get (etaf-screensaver-status) :ticks) 3)))
        (dolist (margins '((0 0) (5 5) (0 0)))
          (apply #'set-window-margins nil margins)
          (let ((columns (1- (window-body-width))))
            (etaf-screensaver-presentation-tests--wait
             (lambda () (= (plist-get (etaf-screensaver-status) :columns) columns)))
            (with-current-buffer buffer
              (let* ((text (buffer-substring (point-min) (point-max)))
                     (old-glyph (string-match-p "中" text))
                     (old-color (red-p text))
                     (position (string-match "X" text))
                     (expected (etaf-string-pixel-width "   ")))
                (should-not old-glyph)
                (should-not old-color)
                (should position)
                (let ((prefix-width (etaf-string-pixel-width (substring text 0 position))))
                  (should (= prefix-width expected)))))
            (let* ((metrics (etaf-display-metrics (etaf-runtime-for-buffer buffer)))
                   (expected (* columns (plist-get metrics :char-width))))
              (dolist (width (etaf-screensaver-presentation-tests--row-widths buffer))
                (should (= width expected))))))
        (let ((unchanged (equal-including-properties snapshot original)))
          (should unchanged))))))

(defmacro etaf-screensaver-presentation-tests--work (id label)
  "Register a public test work ID with its own moving LABEL."
  `(etaf-screensaver-define-scene ,id
     :title ,label :frame-rate 40
     :create (lambda (context) (list :seed (plist-get context :seed)))
     :step (lambda (_state _context) nil)
     :resize (lambda (state _context) state)
     :render (lambda (_state context)
               (list (format "%s 中 %03d" ,label (plist-get context :tick))))))

(etaf-screensaver-presentation-tests--work presentation-one "ONE")
(etaf-screensaver-presentation-tests--work presentation-two "TWO")
(etaf-screensaver-presentation-tests--work presentation-three "THREE")
(etaf-screensaver-presentation-tests--work presentation-four "FOUR")
(etaf-screensaver-presentation-tests--work presentation-five "FIVE")

(ert-deftest etaf-screensaver-presentation-tests-independent-wall ()
  "A wall visibly advances four separate works and keeps the fifth for its next page."
  (etaf-screensaver-presentation-tests--clean
    (let* ((buffer (etaf-screensaver-start
                    '(:presentation mosaic :scenes
                      ((:scene presentation-one :duration 0.35)
                       (:scene presentation-two :duration 0.35)
                       (:scene presentation-three :duration 0.35)
                       (:scene presentation-four :duration 0.35)
                       (:scene presentation-five :duration 30)))))
           (initial (etaf-screensaver-status)))
      (should (equal (plist-get initial :works)
                     '(presentation-one presentation-two presentation-three presentation-four)))
      (should (equal (plist-get initial :up-next-works) '((presentation-five))))
      (etaf-screensaver-presentation-tests--wait
       (lambda () (>= (or (plist-get (etaf-screensaver-status) :ticks) 0) 2)))
      (let ((text (etaf-screensaver-presentation-tests--text buffer)))
        (dolist (label '("ONE" "TWO" "THREE" "FOUR"))
          (should (string-match-p (concat label " 中 00[2-9]") text)))
        (should-not (string-match-p "FIVE" text)))
      (etaf-screensaver-presentation-tests--wait
       (lambda ()
         (let ((status (etaf-screensaver-status)))
           (and (eq (plist-get status :scene) 'presentation-five)
                (null (plist-get status :transition-progress))))))
      (let ((text (etaf-screensaver-presentation-tests--text buffer))
            (works (plist-get (etaf-screensaver-status) :works)))
        (should (equal works '(presentation-five)))
        (should (string-match-p "FIVE 中" text))
        (should-not (string-match-p "ONE 中" text))))))

(ert-deftest etaf-screensaver-presentation-tests-card-mats-evenly ()
  "The card frame is inset by an even mat and keeps ordinary captions."
  (etaf-screensaver-presentation-tests--clean
    (set-window-configuration (current-window-configuration))
    (etaf-screensaver-define-scene presentation-gallery-caption
      :title "纸翼迁徙" :summary "Artist · Source" :background "#f4f1e9"
      :create (lambda (_context) nil) :step (lambda (_state _context) nil)
      :render (lambda (_state context)
                (list (format "SIZE %dx%d" (plist-get context :columns)
                              (plist-get context :rows)))))
    (dolist (paper '("#f4f1e9" "#102030"))
      (let* ((buffer (etaf-screensaver-start
                      (list :scene 'presentation-gallery-caption
                            :background paper :presentation 'card)))
             (status (etaf-screensaver-status))
             (columns (plist-get status :columns))
             (rows (plist-get status :rows))
             (text (etaf-screensaver-presentation-tests--text buffer))
             (lines (split-string (string-remove-suffix "\n" text) "\n"))
             (top (cl-position-if (lambda (line) (string-match-p "┌" line)) lines))
             (bottom (cl-position-if (lambda (line) (string-match-p "└" line)) lines :from-end t))
             (left (string-match "┌" (nth top lines)))
             (right (string-match "┐" (nth top lines)))
             (metrics (etaf-display-metrics (etaf-runtime-for-buffer buffer)))
             (line (with-current-buffer buffer
                     (forward-line top)
                     (buffer-substring (line-beginning-position) (line-end-position))))
             (left-width (etaf-screensaver-presentation-tests--display-width
                          (substring line 0 left) metrics))
             (right-width (etaf-screensaver-presentation-tests--display-width
                           (substring line (1+ right)) metrics))
             (top-width (* top (plist-get metrics :line-height)))
             (cell (plist-get metrics :char-width))
             (echo (if (window-live-p (minibuffer-window))
                       (window-total-height (minibuffer-window))
                     0))
             (frame-width (* (1+ (- right left)) cell))
             (content-width (- right left 1))
             (content-height (- bottom top 3)))
        (should top)
        (should bottom)
        (should (<= 1 top 3))
        (should (if (>= rows 14) (<= 2 top 3) t))
        (should (> left-width 0))
        (should (> right-width 0))
        (should (> top 0))
        (should (< bottom (1- rows)))
        ;; The painted echo row below the window is part of the bottom mat.
        (should (equal top (+ (- rows bottom 1) echo)))
        (should (<= (abs (- left-width top-width)) cell))
        (should (<= (abs (- right-width top-width)) cell))
        (should (<= (abs (- left-width right-width)) cell))
        (should (<= (abs (- (+ left-width right-width frame-width)
                            (* columns cell)))
                    cell))
        (should (string-match-p (format "SIZE %dx%d" content-width content-height) text))
        (should (string-match-p "纸翼迁徙" (nth (- bottom 2) lines)))
        (should (string-match-p "Artist · Source" (nth (1- bottom) lines)))
        (with-current-buffer (window-buffer (minibuffer-window))
          (should (equal (plist-get (get-text-property (point-min) 'face) :background)
                         paper)))
        (with-current-buffer buffer
          (save-excursion
            (goto-char (point-min)) (search-forward "纸翼迁徙")
            (let* ((face (get-text-property (1- (point)) 'face))
                   (faces (if (keywordp (car-safe face)) (list face) face)))
              (should (cl-some (lambda (entry) (equal (plist-get entry :background) paper)) faces))
              (should-not (cl-some (lambda (entry) (plist-get entry :height)) faces))
              (should-not (cl-some (lambda (entry) (plist-get entry :weight)) faces))))))
      (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-presentation-tests-styles-preserve-unicode ()
  "Every presentation publishes a rectangular canvas without splitting wide glyphs."
  (etaf-screensaver-presentation-tests--clean
    (dolist (style '(full card band mosaic))
      (let* ((buffer (etaf-screensaver-start
                      (list :scene 'presentation-one :presentation style)))
             (status (etaf-screensaver-status))
             (text (etaf-screensaver-presentation-tests--text buffer))
             (lines (split-string (string-remove-suffix "\n" text) "\n")))
        (should (eq (plist-get status :presentation) style))
        (should (string-match-p "ONE 中 000" text))
        (should (= (length lines) (plist-get status :rows)))
        (let* ((metrics (etaf-display-metrics (etaf-runtime-for-buffer buffer)))
               (expected (* (plist-get status :columns) (plist-get metrics :char-width))))
          (dolist (width (etaf-screensaver-presentation-tests--row-widths buffer))
            (should (= width expected)))))
      (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-presentation-tests-style-precedence ()
  "A global style overrides pack suggestions; explicit item/group styles win."
  (etaf-screensaver-presentation-tests--clean
    (let ((etaf-screensaver-packs
           '((test-style :presentation card :scenes (presentation-one presentation-two))))
          (etaf-screensaver-presentation 'band))
      (dolist (case '(((:pack test-style) . band)
                      ((:pack test-style :presentation full) . full)
                      ((:presentation mosaic :scenes ((:pack test-style))) . mosaic)))
        (etaf-screensaver-start (car case))
        (let ((actual (plist-get (etaf-screensaver-status) :presentation)))
          (should (eq actual (cdr case))))
        (etaf-screensaver-stop))
      (let ((etaf-screensaver-presentation nil))
        (etaf-screensaver-start '(:pack test-style))
        (let ((style (plist-get (etaf-screensaver-status) :presentation)))
          (should (eq style 'card)))))))

(ert-deftest etaf-screensaver-presentation-tests-full-default-catalog ()
  "The default program does not permanently omit the tail of a pack."
  (etaf-screensaver-presentation-tests--clean
    (let ((etaf-screensaver-presentation nil))
      (etaf-screensaver-start etaf-screensaver-program)
      (let* ((status (etaf-screensaver-status))
             (selected (apply #'append (cons (plist-get status :works)
                                            (plist-get status :up-next-works)))))
        (dolist (pack etaf-screensaver-packs)
          (dolist (scene (plist-get (cdr pack) :scenes))
            (should (memq scene selected))))))))

(ert-deftest etaf-screensaver-presentation-tests-resume-configuration ()
  "A preview preserves position; changing effective settings invalidates it."
  (etaf-screensaver-presentation-tests--clean
    (let ((etaf-screensaver-program
           '(:scenes ((:scene presentation-one :duration 0.08) presentation-two))))
      (etaf-screensaver-start)
      (etaf-screensaver-presentation-tests--wait
       (lambda () (eq (plist-get (etaf-screensaver-status) :scene) 'presentation-two)))
      (let ((seed (plist-get (etaf-screensaver-status) :seed)))
        (etaf-screensaver-stop)
        (etaf-screensaver-start 'presentation-three)
        (etaf-screensaver-stop)
        (etaf-screensaver-start)
        (let ((status (etaf-screensaver-status)))
          (should (eq (plist-get status :scene) 'presentation-two))
          (should (= (plist-get status :seed) seed))))
      (etaf-screensaver-stop)
      (let ((etaf-screensaver-presentation 'card))
        (etaf-screensaver-start)
        (let ((status (etaf-screensaver-status)))
          (should (eq (plist-get status :scene) 'presentation-one))
          (should (eq (plist-get status :presentation) 'card)))))))

(ert-deftest etaf-screensaver-presentation-tests-wall-failure-rolls-back ()
  "Any failed tile aborts startup without taking over or leaking timers."
  (etaf-screensaver-presentation-tests--clean
    (etaf-screensaver-define-scene presentation-broken
      :create (lambda (_context) nil)
      :step (lambda (_state _context) nil)
      :render (lambda (_state _context) (error "Broken work")))
    (set-window-configuration (current-window-configuration))
    (let ((configuration (current-window-configuration))
          (timers (copy-sequence timer-list)))
      (should-error (etaf-screensaver-start
                     '(:presentation mosaic :scenes (presentation-one presentation-broken))))
      (let ((active (plist-get (etaf-screensaver-status) :active))
            (restored (window-configuration-equal-p configuration (current-window-configuration)))
            (remaining (cl-set-difference timer-list timers)))
        (should-not active)
        (should restored)
        (should-not remaining)))))

(ert-deftest etaf-screensaver-presentation-tests-styled-blank-geometry ()
  "Publication preserves styled blank widths, color boundaries and source rows."
  (etaf-screensaver-presentation-tests--clean
    (let* ((source (concat "L"
                           (propertize "    " 'face
                                       '(:background "#335577" :height 1.2 :weight bold))
                           (propertize "   " 'face
                                       '(:background "#776644" :height 0.9))
                           "中R"))
           (original (copy-sequence source)))
      (etaf-screensaver-define-scene presentation-blanks
        :frame-rate 40
        :create (lambda (_context) nil)
        :step (lambda (_state _context) nil)
        :render (lambda (_state context)
                  (list (concat source (number-to-string (mod (plist-get context :tick) 10))))))
      (dolist (style '(full card band mosaic))
        (let ((buffer (etaf-screensaver-start
                       (list :scene 'presentation-blanks :presentation style))))
          (dotimes (pass 2)
            (when (> pass 0)
              (etaf-screensaver-presentation-tests--wait
               (lambda () (>= (plist-get (etaf-screensaver-status) :ticks) 3))))
            (with-current-buffer buffer
              (save-excursion
                (goto-char (point-min))
                (search-forward "L")
                (let ((start (1- (point))))
                  (search-forward "中R")
                  (let* ((published (buffer-substring start (point)))
                         (width (etaf-string-pixel-width published))
                         (expected (etaf-string-pixel-width source))
                         (wide-position (string-match "中R" published)))
                    (should wide-position)
                    (should (= width expected))
                    (dolist (sample (list (cons 1 "#335577")
                                          (cons (1- wide-position) "#776644")))
                      (let* ((face (get-text-property (car sample) 'face published))
                             (specs (if (keywordp (car-safe face)) (list face) face))
                             (background (cl-loop for spec in specs
                                                  when (and (listp spec)
                                                            (plist-get spec :background))
                                                  return (plist-get spec :background))))
                        (should (equal background (cdr sample))))))))))
          (let ((unchanged (equal-including-properties source original)))
            (should unchanged)))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-presentation-tests-preserves-source-faces ()
  "Framing a shared exact-width row must not recolor the scene's source string."
  (etaf-screensaver-presentation-tests--clean
    (let (source-row)
      (etaf-screensaver-define-scene presentation-shared
        :create (lambda (context)
                  (setq source-row (propertize (make-string (plist-get context :columns) ?X)
                                                'face '(:foreground "#559977"))))
        :step (lambda (_state _context) nil)
        :render (lambda (state _context) (list state)))
      (dolist (style '(full card band mosaic))
        (etaf-screensaver-start (list :scene 'presentation-shared :presentation style
                                     :background "#F4F1EA"))
        (let ((face (get-text-property 0 'face source-row)))
          (should (equal face '(:foreground "#559977"))))
        (etaf-screensaver-stop)))))

(etaf-screensaver-define-scene presentation-reveal-old
  :title "Outgoing" :background "#F3F0E8" :frame-rate 40
  :create (lambda (_context) nil) :step (lambda (_state _context) nil)
  :render (lambda (_state context)
            (make-list (plist-get context :rows)
                       (make-string (plist-get context :columns) ?O))))

(etaf-screensaver-define-scene presentation-reveal-new
  :title "Incoming" :background "#071018" :frame-rate 40
  :create (lambda (_context) nil) :step (lambda (_state _context) nil)
  :render (lambda (_state context)
            (make-list (plist-get context :rows)
                       (concat (make-string (max 0 (- (plist-get context :columns) 4)) ?N)
                               (format "%04d" (plist-get context :tick))))))

(ert-deftest etaf-screensaver-presentation-tests-progressive-reveal ()
  "All layouts reveal a live incoming page while preserving outgoing colors."
  (etaf-screensaver-presentation-tests--clean
    (let ((etaf-screensaver-transition-duration 0.4))
      (dolist (style '(full card band mosaic))
        (let ((buffer (etaf-screensaver-start
                       (list :presentation style :scenes
                             (append
                              (make-list (if (eq style 'mosaic) 4 1)
                                         '(:scene presentation-reveal-old :duration 0.08))
                              (make-list (if (eq style 'mosaic) 4 1)
                                         '(:scene presentation-reveal-new :duration 3)))))))
          (etaf-screensaver-presentation-tests--wait
           (lambda ()
             (let ((progress (plist-get (etaf-screensaver-status) :transition-progress)))
               (and progress (<= 0.4 progress 0.7)))))
          (let ((text (etaf-screensaver-presentation-tests--text buffer)))
            (should (string-match-p "NNNN" text))
            (should (string-match-p "OOOO" text)))
          (with-current-buffer buffer
            (save-excursion
              (goto-char (point-min))
              (search-forward "OOOO")
              (let* ((face (get-text-property (1- (point)) 'face))
                     (specs (if (keywordp (car-safe face)) (list face) face)))
                (should (cl-some (lambda (spec)
                                   (and (listp spec)
                                        (equal (plist-get spec :background) "#F3F0E8"))) specs)))))
          (etaf-screensaver-presentation-tests--wait
           (lambda () (null (plist-get (etaf-screensaver-status) :transition-progress))))
          (let ((text (etaf-screensaver-presentation-tests--text buffer))
                (status (etaf-screensaver-status)))
            (should (string-match-p "NNNN" text))
            (should-not (string-match-p "OOOO" text))
            (should (> (plist-get status :ticks) 5))
            (let* ((metrics (etaf-display-metrics (etaf-runtime-for-buffer buffer)))
                   (expected (* (plist-get status :columns) (plist-get metrics :char-width))))
              (dolist (width (etaf-screensaver-presentation-tests--row-widths buffer))
                (should (= width expected))))))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-presentation-tests-reveal-wake-and-options ()
  "Wake during a reveal consumes input and releases resources; bad options roll back."
  (etaf-screensaver-presentation-tests--clean
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (let ((editor (current-buffer)) (timers (copy-sequence timer-list))
              (etaf-screensaver-transition-duration 0.4))
          (etaf-screensaver-start
           '(:scenes ((:scene presentation-reveal-old :duration 0.08)
                      (:scene presentation-reveal-new :duration 3))))
          (etaf-screensaver-presentation-tests--wait
           (lambda () (numberp (plist-get (etaf-screensaver-status) :transition-progress))))
          (execute-kbd-macro "x")
          (let ((active (plist-get (etaf-screensaver-status) :active))
                (remaining (cl-set-difference timer-list timers)))
            (should-not active)
            (should-not remaining)
            (should (eq (window-buffer) editor))
            (should (= (buffer-size editor) 0))))))
    (dolist (value '(-1 6 "slow"))
      (let ((etaf-screensaver-transition-duration value))
        (should-error (etaf-screensaver-start 'presentation-one)
                      :type 'etaf-screensaver-error)))))

(ert-deftest etaf-screensaver-presentation-tests-reveal-disabled-and-repeat ()
  "Zero disables reveals, and a repeated identical page never flashes a transition."
  (etaf-screensaver-presentation-tests--clean
    (dolist (case '((0 . (:scenes ((:scene presentation-reveal-old :duration 0.08)
                                  (:scene presentation-reveal-new :duration 3))))
                    (1.2 . (:scene presentation-reveal-old :duration 0.08))))
      (let ((etaf-screensaver-transition-duration (car case)))
        (etaf-screensaver-start (cdr case))
        (etaf-screensaver-presentation-tests--wait
         (lambda () (> (plist-get (etaf-screensaver-status) :index) 0)))
        (let ((progress (plist-get (etaf-screensaver-status) :transition-progress)))
          (should-not progress))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-presentation-tests-reused-mutable-rows ()
  "Text and color edits to a reused scene row publish independently in every layout."
  (etaf-screensaver-presentation-tests--clean
    (etaf-screensaver-define-scene presentation-mutable
      :frame-rate 40
      :create (lambda (context)
                (propertize (make-string (plist-get context :columns) ?A)
                            'face '(:foreground "#FF0000")))
      :step (lambda (state context)
              (when (= (plist-get context :tick) 1) (aset state 0 ?B))
              (when (>= (plist-get context :tick) 4)
                (put-text-property 0 (length state) 'face '(:foreground "#00FF00") state)))
      :render (lambda (state _context) (list "STATIC TOP" state "" "STATIC BOTTOM")))
    (dolist (style '(full card band mosaic))
      (let ((buffer (etaf-screensaver-start (list :scene 'presentation-mutable
                                                 :presentation style))))
        (etaf-screensaver-presentation-tests--wait
         (lambda () (string-match-p "BAAA" (etaf-screensaver-presentation-tests--text buffer))))
        (etaf-screensaver-presentation-tests--wait
         (lambda ()
           (with-current-buffer buffer
             (save-excursion
               (goto-char (point-min))
               (search-forward "BAAA")
               (let ((face (get-text-property (- (point) 4) 'face)))
                 (cl-some (lambda (spec)
                            (and (listp spec) (equal (plist-get spec :foreground) "#00FF00")))
                          (if (keywordp (car-safe face)) (list face) face)))))))
        (let ((text (etaf-screensaver-presentation-tests--text buffer)))
          (should (string-match-p
                   "STATIC TOP[^\n]*\n[^\n]*BAAA[^\n]*\n[^\n]*\n[^\n]*STATIC BOTTOM" text)))
        (etaf-screensaver-stop)))))

;; Requires the application runtime: before it the canvas face and the buffer
;; death were handled by a hand-written remap cookie and kill-buffer hook.
(ert-deftest etaf-screensaver-presentation-tests-canvas-is-an-application ()
  "The presentation is an ETAF application whose canvas paints the mat."
  (etaf-screensaver-presentation-tests--clean
    (let* ((buffer (etaf-screensaver-start
                    '(:presentation card :scenes
                      ((:scene presentation-one :duration 30)))))
           (canvas (with-current-buffer buffer
                     (plist-get (car (last (alist-get 'default
                                                      face-remapping-alist)))
                                :background))))
      (should (etaf-app-state buffer))
      (should (stringp canvas))
      ;; Killing the buffer releases the presentation through the application.
      (kill-buffer buffer)
      (should-not (plist-get (etaf-screensaver-status) :active)))))

(provide 'etaf-screensaver-presentation-tests)
;;; etaf-screensaver-presentation-tests.el ends here
