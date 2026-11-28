;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-tests.el --- Public screensaver lifecycle acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Drive the public presentation API, documented configuration and Emacs input.
;; Resource assertions compare Emacs's timer/process inventories, never private
;; callbacks or scene structures.  Actual idle activation is covered in the GUI.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-screensaver)

(defun etaf-screensaver-tests--text (buffer)
  "Read BUFFER without display properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro etaf-screensaver-tests--clean (&rest body)
  "Run BODY with isolated configuration and unconditional presentation cleanup."
  (declare (indent 0))
  `(let ((etaf-screensaver-seed 4242)
         (etaf-screensaver-scene-options nil)
         (etaf-screensaver-scene-duration 30)
         (etaf-screensaver-max-frame-rate 60)
         (etaf-screensaver-idle-delay 300))
     (etaf-screensaver-mode -1)
     ;; Batch Emacs initially reports a body overlapping its menu-bar row;
     ;; even a bare save/restore normalizes it.  Snapshot a settled layout.
     (set-window-configuration (current-window-configuration))
     (unwind-protect (progn ,@body)
       (etaf-screensaver-mode -1)
       (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-tests-restores-and-releases ()
  "Repeated start/stop restores windows and releases presentation resources."
  (etaf-screensaver-tests--clean
    (let ((configuration (current-window-configuration))
          (timers (copy-sequence timer-list))
          (processes (process-list))
          (tracking track-mouse)
          (input-map overriding-terminal-local-map))
      (dotimes (_ 3)
        (let* ((buffer (etaf-screensaver-start 'matrix))
               (again (etaf-screensaver-start 'snow))
               (status (etaf-screensaver-status)))
          (should (eq buffer again))
          (should (eq (plist-get status :scene) 'matrix))
          (should (eq (window-buffer) buffer))
          (should (etaf-runtime-for-buffer buffer))
          (etaf-screensaver-stop)
          (etaf-screensaver-stop)
          (should-not (buffer-live-p buffer))))
      ;; ETAF schedules one immediate refit when it fits the application.
      ;; Let that provider cleanup run before comparing inventories.
      (sit-for 0.02)
      (let ((restored (window-configuration-equal-p configuration (current-window-configuration)))
            (new-timers (cl-set-difference timer-list timers))
            (new-processes (cl-set-difference (process-list) processes)))
        (should restored)
        (should-not new-timers)
        (should-not new-processes)
        (should (eq track-mouse tracking))
        (should (eq overriding-terminal-local-map input-map))))))

(ert-deftest etaf-screensaver-tests-key-wakes-without-editing ()
  "The first key restores the original buffer without inserting the key."
  (etaf-screensaver-tests--clean
    (save-window-excursion
      (with-temp-buffer
        (insert "Original content")
        (switch-to-buffer (current-buffer))
        (let ((original (current-buffer)) (position (point)))
          (dolist (key '("x" "C-x" "C-g" "<f5>"))
            (etaf-screensaver-start 'donut)
            (execute-kbd-macro (kbd key))
            (let ((active (plist-get (etaf-screensaver-status) :active))
                  (text (etaf-screensaver-tests--text original)))
              (should-not active)
              (should (eq (window-buffer) original))
              (should (= (point) position))
              (should (equal text "Original content")))))))))

(ert-deftest etaf-screensaver-tests-pointer-wakes ()
  "Motion, click and wheel input dismiss instead of interacting with a scene."
  (etaf-screensaver-tests--clean
    (dolist (kind '(mouse-movement mouse-1 wheel-down))
      (etaf-screensaver-start 'falling-sand)
      (let ((position (list (selected-window) 1 '(3 . 3) 0)))
        (if (eq kind 'mouse-1)
            (execute-kbd-macro (vector (list 'down-mouse-1 position)
                                      (list 'mouse-1 position)))
          (execute-kbd-macro (vector (list kind position)))))
      (let ((active (plist-get (etaf-screensaver-status) :active)))
        (should-not active)))))

(ert-deftest etaf-screensaver-tests-mode-is-idempotent ()
  "Automatic mode owns only one watcher, then releases it when disabled."
  (etaf-screensaver-tests--clean
    (let ((before (copy-sequence timer-idle-list)))
      (etaf-screensaver-mode 1)
      (etaf-screensaver-mode 1)
      (let ((count (length (cl-set-difference timer-idle-list before))))
        (should (= count 1)))
      (etaf-screensaver-start 'snow)
      (let ((count (length (cl-set-difference timer-idle-list before))))
        (should (zerop count)))
      (etaf-screensaver-mode -1)
      (let ((status (etaf-screensaver-status))
            (remaining (cl-set-difference timer-idle-list before)))
        (should-not (plist-get status :active))
        (should-not (plist-get status :automatic))
        (should-not remaining)))))

(ert-deftest etaf-screensaver-tests-program-order-and-options ()
  "Nested groups preserve sequences and merge Lisp configuration by key."
  (etaf-screensaver-tests--clean
    (let ((etaf-screensaver-scene-options '((matrix :duration 12 :params ((speed . 2)))))
          (etaf-screensaver-max-frame-rate 10))
      (etaf-screensaver-start
       '(:order sequential :scenes
         ((:order sequential :scenes ((:scene matrix :params ((speed . 3))) snow))
          (:order sequential :scenes (donut plasma)))))
      (let ((status (etaf-screensaver-status)))
        (should (eq (plist-get status :scene) 'matrix))
        (should (equal (plist-get status :up-next) '(snow donut plasma)))
        (should (= (cdr (assq 'speed (plist-get status :params))) 3))
        (should (= (plist-get status :frame-rate) 10))))))

(ert-deftest etaf-screensaver-tests-shuffle-and-random ()
  "Shuffled bags cover each scene; random groups honor count and seed."
  (etaf-screensaver-tests--clean
    (let ((program '(:order shuffle :scenes (matrix snow donut plasma))) first)
      (dotimes (round 2)
        (etaf-screensaver-start program)
        (let* ((status (etaf-screensaver-status))
               (order (cons (plist-get status :scene) (plist-get status :up-next))))
          (should (equal (sort (copy-sequence order) #'string-lessp) '(donut matrix plasma snow)))
          (if (zerop round) (setq first order) (should (equal first order))))
        (etaf-screensaver-stop)))
    (etaf-screensaver-start '(:order random :count 12 :scenes (snow matrix)))
    (let* ((status (etaf-screensaver-status))
           (order (cons (plist-get status :scene) (plist-get status :up-next))))
      (should (= (length order) 12))
      (should (cl-every (lambda (scene) (memq scene '(snow matrix))) order)))))

(ert-deftest etaf-screensaver-tests-timed-cycle ()
  "A running presentation advances scenes and repeats its program."
  (etaf-screensaver-tests--clean
    (let ((etaf-screensaver-scene-duration 0.06))
      (etaf-screensaver-start '(:order sequential :scenes (matrix snow)))
      (let ((deadline (+ (float-time) 2)))
        (while (and (< (float-time) deadline)
                    (< (or (plist-get (etaf-screensaver-status) :index) 0) 2))
          (sleep-for 0.01)))
      (let ((status (etaf-screensaver-status)))
        (should (plist-get status :active))
        (should (>= (plist-get status :index) 2))
        (should (eq (plist-get status :scene) 'matrix))))))

(ert-deftest etaf-screensaver-tests-repeated-page-continues ()
  "A repeated page keeps the running work instead of resetting its state."
  (etaf-screensaver-tests--clean
    (etaf-screensaver-define-scene etaf-screensaver-tests-counter
      :title "Counter"
      :frame-rate 30
      :create (lambda (_context) (list :count 0))
      :step (lambda (state _context)
              (setf (plist-get state :count) (1+ (plist-get state :count))))
      :render (lambda (state _context)
                (format "count=%d" (plist-get state :count))))
    (let ((buffer (etaf-screensaver-start
                   '(:scene etaf-screensaver-tests-counter :duration 0.2))))
      (let ((deadline (+ (float-time) 3)))
        (while (and (< (float-time) deadline)
                    (< (or (plist-get (etaf-screensaver-status) :index) 0) 3))
          (sleep-for 0.01)))
      (let ((status (etaf-screensaver-status)))
        (should (>= (plist-get status :index) 3))
        (should (eq (plist-get status :scene) 'etaf-screensaver-tests-counter))
        (should (> (plist-get status :ticks) 6))
        (should (string-match
                 (format "count=%d" (plist-get status :ticks))
                 (etaf-screensaver-tests--text buffer)))))))

(ert-deftest etaf-screensaver-tests-flat-playlist ()
  "A flat name list mixes a pack and a scene; scene options set its layout."
  (etaf-screensaver-tests--clean
    (let ((etaf-screensaver-program '(neon snow))
          (etaf-screensaver-presentation 'card))
      (etaf-screensaver-start)
      (let ((status (etaf-screensaver-status)))
        (should (eq (plist-get status :scene) 'tte-beams))
        (should (equal (plist-get status :up-next)
                       '(tte-synthgrid equalizer matrix snow)))
        (should (eq (plist-get status :presentation) 'card)))
    (etaf-screensaver-stop)
    (let ((etaf-screensaver-program '(matrix snow))
          (etaf-screensaver-presentation 'card)
          (etaf-screensaver-scene-options
           '((matrix :presentation full))))
      (etaf-screensaver-start)
      (let ((status (etaf-screensaver-status)))
        (should (eq (plist-get status :scene) 'matrix))
        (should (eq (plist-get status :presentation) 'full))
        (should (equal (plist-get status :up-next) '(snow)))))
    (etaf-screensaver-stop)
    ;; A lone pack name also expands.
    (let ((etaf-screensaver-program 'neon))
      (etaf-screensaver-start 'neon)
      (should (eq (plist-get (etaf-screensaver-status) :scene) 'tte-beams))
      (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-tests-unicode-and-seeded-particles ()
  "Canvas publication preserves Unicode and seeded particle initialization."
  (etaf-screensaver-tests--clean
    (etaf-screensaver-register-scene
     '(:id test-unicode :layers ((:kind text :lines "A 中 B ▓ ○ 🚀 Z" :scroll nil
                                 :color "#66CCAA"))))
    (let* ((buffer (etaf-screensaver-start 'test-unicode))
           (text (etaf-screensaver-tests--text buffer))
           (position (string-match (regexp-quote "A 中 B ▓ ○ 🚀 Z") text)))
      (should position)
      (should-not (string-match-p "SPC\|fps\|参数" text))
      (with-current-buffer buffer
        (let ((face (get-text-property (+ (point-min) position) 'face)))
          (should (cl-some (lambda (spec)
                             (and (listp spec) (equal (plist-get spec :foreground) "#66CCAA")))
                           face)))))
    (etaf-screensaver-stop)
    (let (first)
      (dotimes (round 2)
        (let* ((buffer (etaf-screensaver-start 'snow))
               (digest (secure-hash 'sha256 (etaf-screensaver-tests--text buffer))))
          (if (zerop round) (setq first digest) (should (equal first digest))))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-tests-bundled-scenes-run ()
  "All bundled scenes publish autonomous frames without a control surface."
  (etaf-screensaver-tests--clean
    (dolist (scene '(donut falling-sand matrix plasma snow equalizer
                          tte-beams tte-synthgrid tte-blackhole tte-fireworks tte-bubbles
                          tte-ink-snow-mud tte-ink-rain tte-ink-river
                          poem-qingzhou poem-tiancai poem-lingjue
                          poem-mingyue poem-qingquan poem-genglou
                          poem-qingkong poem-chanjuan poem-caiju
                          poem-luoxia poem-ciqing))
      (ert-info ((format "Scene: %s" scene))
        (let ((buffer (etaf-screensaver-start scene)))
          (let ((deadline (+ (float-time) 1)))
            (while (and (< (float-time) deadline)
                        (zerop (or (plist-get (etaf-screensaver-status) :ticks) 0)))
              (sleep-for 0.01)))
          (let ((status (etaf-screensaver-status))
                (text (etaf-screensaver-tests--text buffer)))
            (should (eq (plist-get status :scene) scene))
            (should (> (plist-get status :ticks) 0))
            (should-not (string-match-p "SPC\|fps\|参数" text)))
          (etaf-screensaver-stop))))))

(ert-deftest etaf-screensaver-tests-equalizer-color-bars ()
  "Equalizer publishes colored bars, peak caps and a reflection."
  (skip-unless (display-graphic-p))
  (etaf-screensaver-tests--clean
    (let ((buffer (etaf-screensaver-start '(:scene equalizer :duration 30))))
      (let ((deadline (+ (float-time) 3)))
        (while (and (< (float-time) deadline)
                    (< (or (plist-get (etaf-screensaver-status) :ticks) 0) 4))
          (sleep-for 0.02)))
      (with-current-buffer buffer
        (let ((position (point-min)) (colors nil) (caps 0) (blocks 0) (baseline 0))
          (while (< position (point-max))
            (let ((char (char-after position))
                  (face (get-text-property position 'face)))
              (cond
               ((eq char ?█)
                (cl-incf blocks)
                (let ((foreground (cl-some
                                   (lambda (part)
                                     (and (listp part) (plist-get part :foreground)))
                                   face)))
                  (when foreground (push foreground colors))))
               ((eq char ?▀) (cl-incf caps))
               ((eq char ?─) (cl-incf baseline))))
            (setq position (1+ position)))
          (should (>= (length (delete-dups colors)) 5))
          (should (> caps 3))
          (should (> blocks 100))
          (should (> baseline 10))))
      (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-tests-playback-gc-threshold-restores ()
  "Playback bounds GC pauses and restores the caller's threshold on stop."
  (etaf-screensaver-tests--clean
    (let ((before (* 128 1024 1024)))
      (let ((gc-cons-threshold before))
        (etaf-screensaver-start 'matrix)
        (should (< gc-cons-threshold before))
        (etaf-screensaver-stop)
        (should (= gc-cons-threshold before))))))

(ert-deftest etaf-screensaver-tests-packs-play-as-configured ()
  "Pack items play their scenes, honor counts and reject unknown packs."
  (etaf-screensaver-tests--clean
    (add-to-list 'etaf-screensaver-packs
                 '(test-pack :title "Test" :order sequential :background "#101820"
                             :scenes (matrix snow)))
    (unwind-protect
        (progn
          (should-error (etaf-screensaver-start '(:pack missing-pack))
                        :type 'etaf-screensaver-error)
          (etaf-screensaver-start '(:pack test-pack))
          (let ((status (etaf-screensaver-status)))
            (should (eq (plist-get status :scene) 'matrix))
            (should (equal (plist-get status :up-next) '(snow))))
          (etaf-screensaver-stop)
          ;; COUNT keeps the round inside the pack, wrapping its scenes.
          (etaf-screensaver-start '(:pack test-pack :count 3))
          (let ((status (etaf-screensaver-status)))
            (should (eq (plist-get status :scene) 'matrix))
            (should (equal (plist-get status :up-next) '(snow matrix))))
          (etaf-screensaver-stop))
      (setq etaf-screensaver-packs (assq-delete-all 'test-pack etaf-screensaver-packs)))))

(ert-deftest etaf-screensaver-tests-resumes-after-dismissal ()
  "A later start of the configured program resumes at its current work."
  (etaf-screensaver-tests--clean
    (let ((etaf-screensaver-program
           '(:order sequential
             :scenes ((:scene matrix :duration 0.15) (:scene snow :duration 30)))))
      (etaf-screensaver-start)
      (let ((deadline (+ (float-time) 3)))
        (while (and (< (float-time) deadline)
                    (eq (plist-get (etaf-screensaver-status) :scene) 'matrix))
          (sleep-for 0.02)))
      (should (eq (plist-get (etaf-screensaver-status) :scene) 'snow))
      (etaf-screensaver-stop)
      (etaf-screensaver-start)
      (should (eq (plist-get (etaf-screensaver-status) :scene) 'snow))
      (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-tests-invalid-start-rolls-back ()
  "Invalid configuration or a scene error leaves no takeover or resources."
  (etaf-screensaver-tests--clean
    (let ((configuration (current-window-configuration))
          (buffers (buffer-list))
          (timers (copy-sequence timer-list)))
      (dolist (program '(5 missing-scene (:order shuffle :scenes 7)
                        (:order unknown :scenes (matrix))
                        (:order shuffle :scenes ()) (:scene matrix :duration -1)
                        (:scene matrix :params ((missing . 5)))))
        (should-error (etaf-screensaver-start program) :type 'etaf-screensaver-error))
      (etaf-screensaver-define-scene test-broken
        :create (lambda (_context) nil)
        :step (lambda (_state _context) nil)
        :render (lambda (_state _context) (error "Scene render failed")))
      (should-error (etaf-screensaver-start 'test-broken))
      (let ((status (etaf-screensaver-status))
            (restored (window-configuration-equal-p configuration (current-window-configuration)))
            (new-buffers (cl-set-difference (buffer-list) buffers))
            (new-timers (cl-set-difference timer-list timers)))
        (should-not (plist-get status :active))
        (should restored)
        (should-not new-buffers)
        (should-not new-timers)))))

(ert-deftest etaf-screensaver-tests-external-buffer-kill-cleans-up ()
  "External buffer death also releases playback and restores the editor."
  (etaf-screensaver-tests--clean
    (let* ((configuration (current-window-configuration))
           (timers (copy-sequence timer-list))
           (buffer (etaf-screensaver-start 'matrix)))
      (kill-buffer buffer)
      ;; Let ETAF's immediate refit cleanup run, as in the explicit stop test.
      (sit-for 0.02)
      (let ((status (etaf-screensaver-status))
            (restored (window-configuration-equal-p configuration (current-window-configuration)))
            (remaining (cl-set-difference timer-list timers)))
        (should-not (plist-get status :active))
        (should restored)
        (should-not remaining)))))

(ert-deftest etaf-screensaver-tests-loader-and-catalog ()
  "Data files override registrations and report malformed files independently."
  (let ((directory (make-temp-file "screensaver-scenes-" t)))
    (unwind-protect
        (progn
          (dolist (id '(donut falling-sand matrix plasma snow equalizer))
            (should (memq id (etaf-screensaver-scenes))))
          (with-temp-file (expand-file-name "one.esc" directory)
            (insert "(etaf-scene :id test-file :title \"First\" :layers ((:kind field :value 0 :ramp \"Q\")))"))
          (let ((count (etaf-screensaver-load-scenes (list directory)))) (should (= count 1)))
          (with-temp-file (expand-file-name "one.esc" directory)
            (insert "(etaf-scene :id test-file :title \"Changed\" :layers ((:kind field :value 0 :ramp \"R\")))"))
          (with-temp-file (expand-file-name "broken.esc" directory)
            (insert "(etaf-scene :id test-bad :layers ((:kind unsupported)))"))
          (let ((count (etaf-screensaver-load-scenes (list directory)))
                (title nil))
            (setq title (plist-get (etaf-screensaver-scene-info 'test-file) :title))
            (should (= count 1))
            (should (equal title "Changed"))))
      (delete-directory directory t))))

(ert-deftest etaf-screensaver-tests-field-arithmetic ()
  "Dense fields preserve unary, binary and variadic arithmetic semantics."
  (etaf-screensaver-tests--clean
    (dolist (case '(((+ (sin 0) (cos 0)) . 1)
                    ((- 4 3) . 1) ((* 0.5 2) . 1) ((/ 3 2) . 1.5)
                    ((pow 2 3) . 8) ((min 2 1) . 1) ((max 0 1) . 1)
                    ((sqrt 4) . 2) ((float 2) . 2.0) ((floor 2.9) . 2)
                    ((ceiling 2.1) . 3) ((round 2.9) . 3) ((abs -2) . 2)
                    ((tan 0) . 0) ((+ 1 2 3) . 6) ((/ 12 2 3) . 2)
                    ((+ 1e16 1.0 -1e16) . 0.0) ((+ 1e16 1.0 -1e16 1.0) . 1.0)
                    ((- 20 2 3) . 15) ((- 20 2 3 4) . 11)
                    ((* 0.5 2 3) . 3.0) ((* 0.5 2 3 4) . 12.0)
                    ((min 2 1.5 3) . 1.5) ((min 2 1.5 3 -4) . -4)
                    ((max 2 1.5 3) . 3) ((max 2 1.5 3 4.5) . 4.5)))
      (etaf-screensaver-register-scene
       (list :id 'test-arithmetic
             :layers (list (list :kind 'field :block '(8 8) :ramp "01"
                                 :value (list 'if (list '= (car case) (cdr case)) 1 0)))))
      (let* ((buffer (etaf-screensaver-start 'test-arithmetic))
             (text (etaf-screensaver-tests--text buffer)))
        (should (string-prefix-p "1111" text)))
      (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-tests-field-coordinate-precedence ()
  "Every field cell gets its own coordinates, ahead of same-named parameters."
  (etaf-screensaver-tests--clean
    (etaf-screensaver-register-scene
     '(:id test-coordinates
       :params ((:key x :label "Parameter x" :type number :default 5 :min 0 :max 10))
       :layers ((:kind field :value (mod (+ x y) 2) :ramp ".#"))))
    (let* ((buffer (etaf-screensaver-start 'test-coordinates))
           (lines (split-string (etaf-screensaver-tests--text buffer) "\n")))
      (should (string-prefix-p ".#.#" (nth 0 lines)))
      (should (string-prefix-p "#.#." (nth 1 lines))))))

(ert-deftest etaf-screensaver-tests-field-invariant-axes ()
  "Field values retain x/y variation and refresh time-dependent subexpressions."
  (etaf-screensaver-tests--clean
    (etaf-screensaver-register-scene
     '(:id test-field-axes :frame-rate 40
       :layers ((:kind field :value (mod (+ (* x y) x (* 2 y) tick) 10)
                       :range (0 10) :ramp "0123456789"))))
    (let ((buffer (etaf-screensaver-start 'test-field-axes)))
      (dotimes (pass 2)
        (when (> pass 0)
          (let ((deadline (+ (float-time) 3)))
            (while (and (< (float-time) deadline)
                        (< (or (plist-get (etaf-screensaver-status) :ticks) 0) 2))
              (sleep-for 0.005)))
          (let ((ticks (plist-get (etaf-screensaver-status) :ticks)))
            (should (>= ticks 2))))
        (let* ((status (etaf-screensaver-status))
               (tick (plist-get status :ticks))
               (lines (split-string (etaf-screensaver-tests--text buffer) "\n")))
          (dotimes (y 4)
            (let ((expected (apply #'string
                                   (cl-loop for x below 10
                                            collect (+ ?0 (mod (+ (* x y) x (* 2 y) tick) 10))))))
              (should (string-prefix-p expected (nth y lines))))))))))

(ert-deftest etaf-screensaver-tests-field-random-short-circuit ()
  "A field draws the same seeded random stream as a callback, skipping dead branches."
  (etaf-screensaver-tests--clean
    (etaf-screensaver-register-scene
     '(:id test-field-random :frame-rate 1
       :layers ((:kind field :value (if (< x 0) (/ 1 0)
                                     (mod (- (+ (* 7 (rndi 10))
                                                (* 3 (rndi 10)) (rndi 10))
                                             (rndi 10) (* 2 (rndi 10)) (* 4 (rndi 10))) 10))
                       :range (0 10) :ramp "0123456789"))))
    (etaf-screensaver-define-scene test-field-reference
      :frame-rate 1 :create (lambda (_context) nil) :step (lambda (_state _context) nil)
      :resize (lambda (state _context) state)
      :render (lambda (_state context)
                (let ((random (plist-get context :random)))
                  (cl-loop repeat (plist-get context :rows)
                           collect (apply #'string
                                          (cl-loop repeat (plist-get context :columns)
                                                   collect
                                                   (let* ((a (floor (* 10 (funcall random))))
                                                          (b (floor (* 10 (funcall random))))
                                                          (c (floor (* 10 (funcall random))))
                                                          (d (floor (* 10 (funcall random))))
                                                          (e (floor (* 10 (funcall random))))
                                                          (f (floor (* 10 (funcall random)))))
                                                     (+ ?0 (mod (- (+ (* 7 a) (* 3 b) c)
                                                                   d (* 2 e) (* 4 f)) 10)))))))))
    (let ((actual (etaf-screensaver-tests--text (etaf-screensaver-start 'test-field-random))))
      (etaf-screensaver-stop)
      (let* ((expected (etaf-screensaver-tests--text (etaf-screensaver-start 'test-field-reference)))
             (same (equal actual expected)))
        (should same)))))

(ert-deftest etaf-screensaver-tests-focus-recheck-keeps-preview ()
  "A global focus notification without a transition leaves a manual preview alive."
  (etaf-screensaver-tests--clean
    (etaf-screensaver-start 'matrix)
    (funcall after-focus-change-function)
    (let ((active (plist-get (etaf-screensaver-status) :active)))
      (should active))))

(provide 'etaf-screensaver-tests)
;;; etaf-screensaver-tests.el ends here
