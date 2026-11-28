;;; etaf-screensaver-tests.el --- Public API acceptance scenarios -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public acceptance scenarios for etaf-screensaver.  Every case uses only
;; symbols declared in etaf-screensaver.el and drives real timers and native
;; command-loop input where applicable.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf-screensaver)

(defun etaf-screensaver-tests--text (buffer)
  "Return plain text of BUFFER without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-screensaver-tests--wait (predicate &optional timeout)
  "Wait using `sleep-for' until PREDICATE returns non-nil or TIMEOUT elapses."
  (let ((deadline (+ (float-time) (or timeout 3.0))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (sleep-for 0.02))
    (funcall predicate)))

(defmacro etaf-screensaver-tests--with-clean-state (&rest body)
  "Run BODY with isolated screensaver options and guaranteed teardown."
  (declare (indent 0))
  `(let ((etaf-screensaver-idle-delay 300)
         (etaf-screensaver-playlist '(matrix snow))
         (etaf-screensaver-order 'sequential)
         (etaf-screensaver-duration 30)
         (etaf-screensaver-frame-rate 30)
         (etaf-screensaver-background "#05070B")
         (etaf-screensaver-frame nil)
         (etaf-screensaver-transition-duration 0))
     (unwind-protect
         (progn
           (etaf-screensaver-mode -1)
           (etaf-screensaver-stop)
           ,@body)
       (etaf-screensaver-mode -1)
       (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-tests-restores-and-releases ()
  (etaf-screensaver-tests--with-clean-state
    (let* ((gc-before (* 128 1024 1024))
           (gc-cons-threshold gc-before)
           (track-before track-mouse)
           (timers-before (length timer-list))
           (procs-before (length (process-list)))
           (origin (generate-new-buffer " *screensaver-test-origin*")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (insert "original text")
            (split-window-right)
            (let* ((windows-before (length (window-list)))
                   (buf (etaf-screensaver-open 'matrix 7))
                   (again (etaf-screensaver-open 'snow 9))
                   (gc-during gc-cons-threshold)
                   (status (etaf-screensaver-status)))
              (should (buffer-live-p buf))
              (should (eq buf again))
              (should (plist-get status :active))
              (should (eq (plist-get status :scene) 'matrix))
              (should (<= gc-during (* 32 1024 1024)))
              (should (= (length (window-list)) 1))
              (should (null (etaf-screensaver-stop)))
              (should (null (etaf-screensaver-stop)))
              (should-not (buffer-live-p buf))
              (should (= (length (window-list)) windows-before))
              (should (eq (current-buffer) origin))
              (should (eq track-mouse track-before))
              (should (= gc-cons-threshold gc-before))
              ;; Let ETAF's zero-delay refit timer drain, then verify no timers survive.
              (sleep-for 0.02)
              (should (= (length timer-list) timers-before))
              (should (= (length (process-list)) procs-before))))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest etaf-screensaver-tests-key-wakes-without-editing ()
  (etaf-screensaver-tests--with-clean-state
    (let ((origin (generate-new-buffer " *screensaver-test-key*")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (insert "untouched")
            (etaf-screensaver-open 'matrix 1)
            (execute-kbd-macro (kbd "x"))
            (let ((active (plist-get (etaf-screensaver-status) :active))
                  (content (etaf-screensaver-tests--text origin)))
              (should-not active)
              (should (eq (window-buffer) origin))
              (should (equal content "untouched"))))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest etaf-screensaver-tests-pointer-wakes ()
  (etaf-screensaver-tests--with-clean-state
    (let ((origin (generate-new-buffer " *screensaver-test-pointer*")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (dolist (event '(mouse-movement wheel-down))
              (etaf-screensaver-open 'snow 2)
              (let ((pos (list (selected-window) 1 '(2 . 2) 0)))
                (execute-kbd-macro (vector (list event pos))))
              (should-not (plist-get (etaf-screensaver-status) :active))
              (should (eq (window-buffer) origin)))
            ;; Click: down alone is consumed without waking; up dismisses.
            (etaf-screensaver-open 'snow 3)
            (let ((pos (list (selected-window) 1 '(2 . 2) 0)))
              (execute-kbd-macro (vector (list 'down-mouse-1 pos)))
              (should (plist-get (etaf-screensaver-status) :active))
              (execute-kbd-macro (vector (list 'mouse-1 pos)))
              (should-not (plist-get (etaf-screensaver-status) :active))
              (should (eq (window-buffer) origin))))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest etaf-screensaver-tests-mode-is-idempotent ()
  (etaf-screensaver-tests--with-clean-state
    (let ((idle-before (length timer-idle-list)))
      (etaf-screensaver-mode 1)
      (should (plist-get (etaf-screensaver-status) :automatic))
      (should (= (length timer-idle-list) (1+ idle-before)))
      (etaf-screensaver-mode 1)
      (should (= (length timer-idle-list) (1+ idle-before)))
      (etaf-screensaver-open 'clock)
      (etaf-screensaver-mode -1)
      (should-not (plist-get (etaf-screensaver-status) :active))
      (should-not (plist-get (etaf-screensaver-status) :automatic))
      (should (= (length timer-idle-list) idle-before)))
    (let ((etaf-screensaver-idle-delay 0))
      (should-error (etaf-screensaver-mode 1) :type 'etaf-screensaver-error)
      (should-not (plist-get (etaf-screensaver-status) :automatic)))))

(ert-deftest etaf-screensaver-tests-external-buffer-kill-cleans-up ()
  (etaf-screensaver-tests--with-clean-state
    (let ((origin (generate-new-buffer " *screensaver-test-kill*")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (let ((buf (etaf-screensaver-open 'donut 5)))
              (kill-buffer buf)
              (should-not (plist-get (etaf-screensaver-status) :active))
              (should (eq (window-buffer) origin))))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest etaf-screensaver-tests-focus-recheck-keeps-preview ()
  (etaf-screensaver-tests--with-clean-state
    (etaf-screensaver-open 'matrix 11)
    (funcall after-focus-change-function)
    (should (plist-get (etaf-screensaver-status) :active))))

(ert-deftest etaf-screensaver-tests-playlist-and-order ()
  (etaf-screensaver-tests--with-clean-state
    ;; Single configured item with inline scene param override.
    (etaf-screensaver-open '(matrix :speed 14 :duration 12 :frame card) 42)
    (let ((status (etaf-screensaver-status)))
      (should (eq (plist-get status :scene) 'matrix))
      (should (= (plist-get status :duration) 12))
      (should (eq (plist-get status :frame) 'card))
      (should (= (cdr (assq 'speed (plist-get status :params))) 14)))
    (etaf-screensaver-stop)
    ;; Shuffle covers every item once per round and is reproducible with seed.
    (let ((etaf-screensaver-order 'shuffle)
          (list '(matrix snow donut plasma)))
      (etaf-screensaver-open list 99)
      (let* ((s1 (etaf-screensaver-status))
             (r1 (cons (plist-get s1 :scene) (plist-get s1 :up-next))))
        (etaf-screensaver-stop)
        (etaf-screensaver-open list 99)
        (let* ((s2 (etaf-screensaver-status))
               (r2 (cons (plist-get s2 :scene) (plist-get s2 :up-next))))
          (etaf-screensaver-stop)
          (should (equal r1 r2))
          (should (= (length r1) 4))
          (should (equal (sort (copy-sequence r1) #'string<)
                         (sort (copy-sequence list) #'string<))))))
    ;; Invalid configurations fail before taking over windows.
    (let ((before (current-buffer)))
      (let ((etaf-screensaver-playlist nil))
        (should-error (etaf-screensaver-open) :type 'etaf-screensaver-error)
        (should-not (plist-get (etaf-screensaver-status) :active))
        (should (eq (current-buffer) before)))
      (dolist (bad (list 'no-such-scene '(matrix :unknown-param 1)
                         '(matrix :duration -5) '(matrix :frame bogus)))
        (should-error (etaf-screensaver-open bad) :type 'etaf-screensaver-error)
        (should-not (plist-get (etaf-screensaver-status) :active))
        (should (eq (current-buffer) before))))))

(ert-deftest etaf-screensaver-tests-timed-cycle-and-transition ()
  (etaf-screensaver-tests--with-clean-state
    (let ((etaf-screensaver-transition-duration 0.3)
          (etaf-screensaver-frame-rate 25))
      (etaf-screensaver-open '((matrix :duration 0.15) (poems :duration 0.8)) 7)
      (let ((saw-reveal nil))
        (should (etaf-screensaver-tests--wait
                 (lambda ()
                   (let ((st (etaf-screensaver-status)))
                     (when (plist-get st :transition-progress)
                       (setq saw-reveal t))
                     (and (eq (plist-get st :scene) 'poems)
                          (>= (plist-get st :index) 1)
                          (null (plist-get st :transition-progress)))))
                 3.0))
        (should saw-reveal)))
    (etaf-screensaver-stop)
    ;; Repeating the same scene continues its state instead of restarting.
    (let ((created 0))
      (etaf-screensaver-define-scene test-continuous
        :title "Continuous"
        :frame-rate 25
        :create (lambda (_ctx) (cl-incf created) (list :n 0))
        :step (lambda (s _ctx) (cl-incf (plist-get s :n)))
        :render (lambda (s ctx)
                  (etaf-screensaver-canvas-text
                   (plist-get ctx :canvas) 0 0 (format "n=%d" (plist-get s :n)))))
      (etaf-screensaver-open '(test-continuous :duration 0.12) 1)
      (let ((after-open created))
        (should (etaf-screensaver-tests--wait
                 (lambda () (>= (or (plist-get (etaf-screensaver-status) :index) 0) 2))
                 2.0))
        (should (= created after-open))))))

(ert-deftest etaf-screensaver-tests-resume-and-preview ()
  (etaf-screensaver-tests--with-clean-state
    (let ((etaf-screensaver-playlist '((matrix :duration 0.12) (snow :duration 30))))
      (etaf-screensaver-open)
      (should (etaf-screensaver-tests--wait
               (lambda () (eq (plist-get (etaf-screensaver-status) :scene) 'snow))
               2.0))
      (etaf-screensaver-stop)
      ;; Previewing another scene must not overwrite saved resume position.
      (etaf-screensaver-preview 'donut)
      (should (eq (plist-get (etaf-screensaver-status) :scene) 'donut))
      (etaf-screensaver-stop)
      ;; Re-opening configured playlist resumes at snow.
      (etaf-screensaver-open)
      (should (eq (plist-get (etaf-screensaver-status) :scene) 'snow))
      (etaf-screensaver-stop)
      ;; Changing playlist invalidates saved resume position.
      (let ((etaf-screensaver-playlist '(plasma snow)))
        (etaf-screensaver-open)
        (should (eq (plist-get (etaf-screensaver-status) :scene) 'plasma))))))

(ert-deftest etaf-screensaver-tests-card-framing-and-resize ()
  (etaf-screensaver-tests--with-clean-state
    (let* ((buf (etaf-screensaver-open '(poems :frame card) 5))
           (text (etaf-screensaver-tests--text buf))
           (status (etaf-screensaver-status)))
      (should (eq (plist-get status :frame) 'card))
      (should (string-match-p "┌─+┐" text))
      (should (string-match-p "└─+┘" text))
      (should (string-match-p "宣纸诗句" text)))))

(ert-deftest etaf-screensaver-tests-canvas-and-colors ()
  (let ((c (etaf-screensaver-canvas-create 10 4)))
    (etaf-screensaver-canvas-box c 0 0 10 4 "#334455")
    (etaf-screensaver-canvas-text c 1 'center "你好" "#FFFFFF")
    ;; Overwriting second cell of a wide char clears its lead cleanly.
    (etaf-screensaver-canvas-put c 2 1 ?中 "#00FF00")
    (etaf-screensaver-canvas-put c 2 2 ?X "#FF0000")
    (let ((rows (etaf-screensaver-canvas-rows c)))
      (should (= (length rows) 4))
      (dolist (row rows)
        (should (= (string-width row) 10)))
      (should (string-match-p "你好" (nth 1 rows)))
      (should-not (string-match-p "中" (nth 2 rows)))
      (should (string-match-p "X" (nth 2 rows))))
    (etaf-screensaver-canvas-clear c)
    (should (equal (car (etaf-screensaver-canvas-rows c)) (make-string 10 ?\s))))
  (should (equal (etaf-screensaver-color-mix "#000000" "#ffffff" 0.0) "#000000"))
  (should (equal (etaf-screensaver-color-mix "#000000" "#ffffff" 1.0) "#ffffff"))
  (should (equal (etaf-screensaver-color-mix "#000000" "#ffffff" 0.5) "#808080"))
  (should (eq (etaf-screensaver-ramp "abc" 0.0) ?a))
  (should (eq (etaf-screensaver-ramp "abc" 1.0) ?c))
  (should (equal (etaf-screensaver-ramp '("#111111" "#222222") 0.9) "#222222"))
  (should-error (etaf-screensaver-color-mix "bad" "#ffffff" 0.5) :type 'etaf-screensaver-error)
  (should-error (etaf-screensaver-ramp "" 0.5) :type 'etaf-screensaver-error))

(ert-deftest etaf-screensaver-tests-custom-scene-builders ()
  (etaf-screensaver-tests--with-clean-state
    ;; 1. Minimal stateless define-scene (render-only).
    (etaf-screensaver-define-scene test-minimal
      :title "Minimal"
      :render (lambda (_s ctx)
                (etaf-screensaver-canvas-text (plist-get ctx :canvas) 0 'center "HELLO")))
    (let ((buf (etaf-screensaver-open 'test-minimal 1)))
      (should (string-match-p "HELLO" (etaf-screensaver-tests--text buf))))
    (etaf-screensaver-stop)
    ;; 2. Text scene builder with live generator and all styles.
    (let ((counter 0))
      (etaf-screensaver-define-text-scene test-text-live
        :title "Live"
        :style 'static
        :items (lambda () (cl-incf counter) (list (format "tick-%d" counter))))
      (let ((buf (etaf-screensaver-open 'test-text-live 1)))
        (should (string-match-p "tick-" (etaf-screensaver-tests--text buf))))
      (etaf-screensaver-stop))
    (dolist (style '(typewriter fade scroll))
      (etaf-screensaver-define-text-scene test-text-anim
        :title "Anim"
        :style style
        :items '((:text "山高月小" :caption "苏轼")))
      (let ((buf (etaf-screensaver-open 'test-text-anim 2)))
        (should (etaf-screensaver-tests--wait
                 (lambda () (>= (or (plist-get (etaf-screensaver-status) :ticks) 0) 2))))
        (should (buffer-live-p buf)))
      (etaf-screensaver-stop))
    ;; 3. Field scene builder with block and palette.
    (etaf-screensaver-define-field-scene test-field
      :title "Field"
      :block '(2 2)
      :range '(0 1)
      :ramp " .#"
      :palette '("#111111" "#888888" "#FFFFFF")
      :value (lambda (x y _ctx) (/ (+ x y) 100.0)))
    (let ((buf (etaf-screensaver-open 'test-field 1)))
      (should (string-match-p "[.#]" (etaf-screensaver-tests--text buf))))
    (etaf-screensaver-stop)
    ;; 4. Particle scene builder with seeded determinism.
    (etaf-screensaver-define-particle-scene test-particles
      :title "Particles"
      :count 10
      :spawn (lambda (_i ctx)
               (let ((r (plist-get ctx :random)))
                 (vector (funcall r (plist-get ctx :columns))
                         (funcall r (plist-get ctx :rows)))))
      :update (lambda (p _ctx) (aset p 0 (1+ (aref p 0))))
      :draw (lambda (p c _ctx) (etaf-screensaver-canvas-put c (aref p 1) (aref p 0) ?* "#FFFFFF")))
    (let* ((b1 (etaf-screensaver-open 'test-particles 77))
           (t1 (etaf-screensaver-tests--text b1)))
      (etaf-screensaver-stop)
      (let* ((b2 (etaf-screensaver-open 'test-particles 77))
             (t2 (etaf-screensaver-tests--text b2)))
        (etaf-screensaver-stop)
        (should (equal t1 t2))
        (should (string-match-p "\\*" t1))))))

(ert-deftest etaf-screensaver-tests-builtins-and-catalog ()
  (etaf-screensaver-tests--with-clean-state
    (let ((builtins '(matrix snow plasma donut equalizer sand poems clock))
          (catalog (etaf-screensaver-scenes)))
      (dolist (id builtins)
        (should (memq id catalog))
        (let ((info (etaf-screensaver-scene-info id)))
          (should (eq (plist-get info :id) id))
          (should (stringp (plist-get info :title)))
          (should (eq (plist-get (etaf-screensaver-scene-info (plist-get info :title)) :id) id)))
        (let ((buf (etaf-screensaver-open id 13)))
          (should (etaf-screensaver-tests--wait
                   (lambda () (>= (or (plist-get (etaf-screensaver-status) :ticks) 0) 2))))
          (let ((status (etaf-screensaver-status))
                (lines (split-string (etaf-screensaver-tests--text buf) "\n")))
            (should (plist-get status :active))
            (should (= (length lines) (plist-get status :rows)))))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-tests-runtime-error-recovers ()
  (etaf-screensaver-tests--with-clean-state
    (let ((origin (generate-new-buffer " *screensaver-test-err*")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (etaf-screensaver-define-scene test-exploding
              :title "Exploding"
              :frame-rate 30
              :step (lambda (_s _ctx) (error "scene boom"))
              :render (lambda (_s ctx) (plist-get ctx :canvas)))
            (etaf-screensaver-mode 1)
            (cl-letf (((symbol-function 'display-warning) #'ignore))
              (etaf-screensaver-open 'test-exploding 1)
              (should (etaf-screensaver-tests--wait
                       (lambda () (not (plist-get (etaf-screensaver-status) :active)))
                       2.0)))
            (should-not (plist-get (etaf-screensaver-status) :automatic))
            (should (eq (window-buffer) origin)))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(provide 'etaf-screensaver-tests)
;;; etaf-screensaver-tests.el ends here
