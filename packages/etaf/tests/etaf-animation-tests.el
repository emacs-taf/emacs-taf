;;; etaf-animation-tests.el --- Time-driven reactive values -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Transitions, frame sequences, their shared clock and Scope ownership are
;; public behavior: values interpolate, interruption never jumps, and stop,
;; finish, disabling and unmount all leave a stable value and no clock demand.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)

(defun etaf-animation-test-wait (predicate)
  "Process timers until PREDICATE succeeds, with a bounded deadline."
  (let ((deadline (+ (float-time) 2)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    (should (funcall predicate))))

(defun etaf-animation-test-sleep (seconds)
  "Process timers for SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.005))))

(defvar etaf-animation-test-level nil
  "Target ref owned by the test component.")

(defvar etaf-animation-test-shown nil
  "Transition ref owned by the test component's Scope.")

(etaf-define-component etaf-animation-test-card ()
  "Component whose Scope owns one transition to an internal target."
  :setup (progn
           (setq etaf-animation-test-level (etaf-ref 0 :name 'test-level))
           (setq etaf-animation-test-shown
                 (etaf-transition etaf-animation-test-level
                                  :duration 0.3 :easing 'linear))
           nil)
  :view (text (expr (format "level %.2f" (etaf-value etaf-animation-test-shown)))))

(ert-deftest etaf-animation-transition-interpolates-and-lands-exactly ()
  "A transition samples between values, lands exactly and reports completion."
  (let* ((completed 0)
         (target (etaf-ref 0))
         (shown (etaf-transition target :duration 0.25 :easing 'linear
                                 :on-complete (lambda () (cl-incf completed))))
         (samples nil)
         (stop (etaf-watch shown (lambda (new _old) (push new samples)))))
    (unwind-protect
        (progn
          (should (= 0 (etaf-value shown)))
          (should-not (etaf-animation-active-p shown))
          (setf (etaf-value target) 10)
          (should (etaf-animation-active-p shown))
          (etaf-animation-test-wait
           (lambda () (not (etaf-animation-active-p shown))))
          (should (= 10 (etaf-value shown)))
          (setq samples (nreverse samples))
          (should (> (length samples) 1))
          (should (cl-some (lambda (value) (and (> value 0) (< value 10)))
                           samples))
          (should (cl-every (lambda (a b) (<= a b)) samples (cdr samples)))
          (should (= 1 completed)))
      (etaf-animation-stop shown)
      (funcall stop))))

(ert-deftest etaf-animation-transition-retargets-from-current-value ()
  "Changing the target mid-run continues from the displayed value."
  (let* ((target (etaf-ref 0))
         (shown (etaf-transition target :duration 0.4 :easing 'linear))
         (samples nil)
         (stop (etaf-watch shown (lambda (new _old) (push new samples)))))
    (unwind-protect
        (progn
          (setf (etaf-value target) 10)
          (etaf-animation-test-wait
           (lambda () (let ((value (etaf-value shown)))
                        (and (numberp value) (> value 0)))))
          (let ((pivot (etaf-value shown)))
            (setq samples nil)
            (setf (etaf-value target) 2)
            (etaf-animation-test-wait
             (lambda () (not (etaf-animation-active-p shown))))
            (should (= 2 (etaf-value shown)))
            (setq samples (nreverse samples))
            (should (> (length samples) 1))
            (should (cl-every (lambda (value)
                                (and (>= value (- pivot 0.001)) (<= value 2)))
                              samples))))
      (etaf-animation-stop shown)
      (funcall stop))))

(ert-deftest etaf-animation-stop-and-finish-freeze-or-land ()
  "Stopping keeps the displayed value; finishing applies the target."
  (let* ((target (etaf-ref 0))
         (shown (etaf-transition target :duration 1.0 :easing 'linear)))
    (setf (etaf-value target) 100)
    (etaf-animation-test-wait (lambda () (etaf-animation-active-p shown)))
    (etaf-animation-test-sleep 0.08)
    (etaf-animation-stop shown)
    (let ((frozen (etaf-value shown)))
      (should-not (etaf-animation-active-p shown))
      (etaf-animation-test-sleep 0.12)
      (should (equal frozen (etaf-value shown)))
      (setf (etaf-value target) 5)
      (etaf-animation-test-sleep 0.08)
      (should (equal frozen (etaf-value shown)))
      (should-not (etaf-animation-active-p shown))))
  (let* ((target (etaf-ref 0))
         (shown (etaf-transition target :duration 1.0 :easing 'linear)))
    (setf (etaf-value target) 7)
    (etaf-animation-test-wait (lambda () (etaf-animation-active-p shown)))
    (etaf-animation-finish shown)
    (should (= 7 (etaf-value shown)))
    (should-not (etaf-animation-active-p shown)))
  (let ((shown (etaf-animation-frames '("a" "b" "c") :interval 0.03)))
    (etaf-animation-test-wait (lambda () (etaf-animation-active-p shown)))
    (etaf-animation-test-sleep 0.07)
    (etaf-animation-stop shown)
    (let ((frozen (etaf-value shown)))
      (etaf-animation-test-sleep 0.1)
      (should (equal frozen (etaf-value shown)))
      (should-not (etaf-animation-active-p shown)))))

(ert-deftest etaf-animation-scope-and-switch-control-the-clock ()
  "Unmounting stops the Scope's animation; a disabled switch applies at once."
  (let ((buffer (generate-new-buffer " *etaf-animation-test*"))
        unrelated unrelated-fired)
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-view (etaf-animation-test-card))
                      (list :viewport-width 400 :viewport-height 20))
          (setf (etaf-value etaf-animation-test-level) 4)
          (should (etaf-animation-active-p etaf-animation-test-shown))
          (etaf-animation-test-wait
           (lambda () (not (etaf-animation-active-p etaf-animation-test-shown))))
          (should (= 4 (etaf-value etaf-animation-test-shown)))
          (with-current-buffer buffer
            (should (string-match-p "level 4.00"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max)))))
          (setf (etaf-value etaf-animation-test-level) 9)
          (etaf-animation-test-wait
           (lambda () (etaf-animation-active-p etaf-animation-test-shown)))
          (setq unrelated (run-at-time 0.05 nil (lambda () (setq unrelated-fired t))))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should-not (etaf-animation-active-p etaf-animation-test-shown))
          (let ((frozen (etaf-value etaf-animation-test-shown)))
            (etaf-animation-test-sleep 0.1)
            (should (equal frozen (etaf-value etaf-animation-test-shown)))
            (should unrelated-fired)))
      (when unrelated (cancel-timer unrelated))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  (let* ((etaf-animation-enabled nil)
         (target (etaf-ref 0))
         (shown (etaf-transition target :duration 1.0)))
    (setf (etaf-value target) 5)
    (should (= 5 (etaf-value shown)))
    (should-not (etaf-animation-active-p shown))))

(ert-deftest etaf-animation-frames-cycle-and-finish ()
  "A frame sequence cycles, freezes on stop and finishes on its last frame."
  (let* ((shown (etaf-animation-frames '("a" "b" "c") :interval 0.03))
         (samples nil)
         (stop (etaf-watch shown (lambda (new _old) (push new samples)))))
    (unwind-protect
        (progn
          (etaf-animation-test-wait (lambda () (>= (length samples) 4)))
          (should (etaf-animation-active-p shown))
          (should (cl-every (lambda (value) (member value '("a" "b" "c")))
                            samples))
          (etaf-animation-stop shown)
          (should-not (etaf-animation-active-p shown)))
      (funcall stop)))
  (let ((completed 0)
        (shown nil))
    (setq shown (etaf-animation-frames ["x" "y"] :interval 0.03 :loop nil
                                       :on-complete (lambda () (cl-incf completed))))
    (etaf-animation-test-wait
     (lambda () (not (etaf-animation-active-p shown))))
    (should (equal "y" (etaf-value shown)))
    (should (= 1 completed))))

(ert-deftest etaf-animation-clock-pause-and-speed ()
  "Pausing freezes progress; the speed multiplier scales it."
  (let* ((target (etaf-ref 0))
         (shown (etaf-transition target :duration 0.4 :easing 'linear)))
    (unwind-protect
        (progn
          (setf (etaf-value target) 10)
          (etaf-animation-test-wait (lambda () (etaf-animation-active-p shown)))
          (etaf-animation-test-sleep 0.08)
          (setq etaf-animation-paused t)
          (let ((frozen (etaf-value shown)))
            (etaf-animation-test-sleep 0.3)
            (should (equal frozen (etaf-value shown)))
            (should (etaf-animation-active-p shown))
            (setq etaf-animation-paused nil)
            (etaf-animation-test-wait
             (lambda () (not (etaf-animation-active-p shown))))
            (should (= 10 (etaf-value shown)))))
      (setq etaf-animation-paused nil)
      (etaf-animation-stop shown)))
  (let* ((etaf-animation-speed 4.0)
         (target (etaf-ref 0))
         (shown (etaf-transition target :duration 1.0 :easing 'linear)))
    (setf (etaf-value target) 5)
    (etaf-animation-test-wait (lambda () (not (etaf-animation-active-p shown))))
    (should (= 5 (etaf-value shown))))
  (let* ((etaf-animation-speed 0.25)
         (target (etaf-ref 0))
         (shown (etaf-transition target :duration 0.2 :easing 'linear)))
    (setf (etaf-value target) 5)
    (etaf-animation-test-sleep 0.4)
    (should (etaf-animation-active-p shown))
    (etaf-animation-stop shown)))

(ert-deftest etaf-animation-interpolation-easings-and-validation ()
  "Values convert over registered easings; invalid inputs signal."
  (should (= 5.0 (etaf-animation-interpolate 0 10 0.5)))
  (should (= 10 (etaf-animation-interpolate 0 10 1)))
  (should (= 3 (etaf-animation-interpolate 3 9 0)))
  (let ((middle (etaf-animation-interpolate "#000000" "#ffffff" 0.5)))
    (should (color-name-to-rgb middle))
    (should-not (equal middle "#000000"))
    (should-not (equal middle "#ffffff")))
  (should (equal "#123456" (etaf-animation-interpolate "#000000" "#123456" 1)))
  (should (equal '(lh 2.5) (etaf-animation-interpolate '(lh 1) '(lh 4) 0.5)))
  (should (equal [1.0 5.0] (etaf-animation-interpolate [0 2] [2 8] 0.5)))
  (should (equal 'unchanged (etaf-animation-interpolate 'unchanged 'other 0.5)))
  (let ((etaf-animation-interpolators
         (cons (cons (lambda (from to) (and (stringp from) (stringp to)))
                     (lambda (_from _to progress) (format "%.2f" progress)))
               etaf-animation-interpolators)))
    (should (equal "0.50" (etaf-animation-interpolate "a" "b" 0.5))))
  (dolist (name '(linear ease ease-in ease-out ease-in-out))
    (let ((function (cdr (assq name etaf-animation-easings))))
      (should (numberp (funcall function 0.0)))
      (should (numberp (funcall function 1.0)))
      (should (<= -0.001 (funcall function 0.5) 1.001))))
  (should-error (etaf-transition (etaf-ref 0) :easing 'bogus)
                :type 'etaf-animation-error)
  (should-error (etaf-transition (etaf-ref 0) :duration -1)
                :type 'etaf-animation-error)
  (should-error (etaf-animation-frames '())
                :type 'etaf-animation-error)
  (should-error (etaf-animation-frames '("a") :interval 0)
                :type 'etaf-animation-error)
  (should-error (etaf-animation-stop (etaf-ref 0))
                :type 'etaf-animation-error)
  (should-not (etaf-animation-active-p 42)))

(ert-deftest etaf-animation-new-runs-use-the-shared-time-base ()
  "Runs joining a paused or scaled clock start at their own first frame."
  (let ((etaf-animation-speed 0.25)
        (etaf-animation-paused nil)
        first second)
    (unwind-protect
        (progn
          (setq first (etaf-animation-frames '(0 1 2) :interval 0.05))
          (etaf-animation-test-sleep 0.3)
          (setq etaf-animation-paused t)
          (etaf-animation-test-sleep 0.2)
          (setq second (etaf-animation-frames '("first" "last")
                                               :interval 0.04 :loop nil))
          (etaf-animation-test-sleep 0.15)
          (should (equal (etaf-value second) "first"))
          (setq etaf-animation-paused nil etaf-animation-speed 1.0)
          ;; Queued keyboard input must not freeze an otherwise running clock.
          (let ((unread-command-events (list ?x)))
            (etaf-animation-test-wait
             (lambda () (not (etaf-animation-active-p second)))))
          (should (equal (etaf-value second) "last")))
      (when first (etaf-animation-stop first))
      (when second (etaf-animation-stop second)))))

(ert-deftest etaf-animation-native-editing-and-other-buffers ()
  "Animation publications preserve editing, undo, selection and other buffers."
  (let* ((frame (etaf-animation-frames '("one" "two" "three") :interval 0.02))
         (draft (etaf-ref "draft"))
         (buffer (generate-new-buffer " *animation input*"))
         (other (generate-new-buffer " *animation other*"))
         runtime session)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (etaf-mount buffer
                      (etaf-view
                       (column (text (expr (etaf-value frame)))
                               (text :ref 'pad (expr (etaf-value draft)))))
                      (list :viewport-width 500 :viewport-height 10))
          (setq runtime (etaf-runtime-for-buffer buffer)
                session (etaf-input-begin
                         runtime 'pad :on-change
                         (lambda (text) (setf (etaf-value draft) text))))
          (execute-kbd-macro "XYZ")
          (should (equal (etaf-value draft) "draftXYZ"))
          (execute-kbd-macro (kbd "C-/"))
          (should (equal (etaf-value draft) "draft"))
          (execute-kbd-macro (kbd "C-a C-SPC C-e"))
          (let ((revision (etaf-runtime-revision runtime)))
            (etaf-animation-test-wait
             (lambda () (> (etaf-runtime-revision runtime) (+ revision 1)))))
          ;; Native editing owns the selection; cutting it after publications
          ;; proves the selection survived without inspecting its shadow buffer.
          (execute-kbd-macro (kbd "C-w"))
          (should (equal (etaf-value draft) ""))
          (execute-kbd-macro "Again")
          (should (equal (etaf-value draft) "Again"))
          (switch-to-buffer other)
          (insert "unrelated")
          (goto-char 4)
          (let ((revision (etaf-runtime-revision runtime)))
            (etaf-animation-test-wait
             (lambda () (> (etaf-runtime-revision runtime) (+ revision 1)))))
          (should (eq (current-buffer) other))
          (should (= (point) 4))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "unrelated")))
      (when session (etaf-input-end session))
      (when runtime (etaf-unmount runtime))
      (etaf-animation-stop frame)
      (kill-buffer buffer)
      (kill-buffer other))))

(ert-deftest etaf-animation-theatre-controls-and-edit-pad ()
  "The shipped theatre's controls and empty draft remain usable while moving."
  (let ((original (list etaf-animation-paused etaf-animation-speed
                        etaf-animation-frame-rate))
        (buffer nil) runtime)
    (unwind-protect
        (save-window-excursion
          (setq buffer (etaf-animation-example-open)
                runtime (etaf-runtime-for-buffer buffer))
          (switch-to-buffer buffer)
          (etaf-runtime-refit runtime 1200 50)
          (dolist (label '("TYPEWRITER" "SPINNERS" "HEARTBEAT" "MATRIX" "MORSE"
                           "SNOW" "FIREWORK" "SPECTRUM" "LOADING" "NEON"
                           "GRAVITY" "DVD LOGO" "LETTERS" "PENDULUM" "FISH"
                           "PULSE" "WAVE" "PLASMA" "HEAT" "RAINBOW" "EDIT PAD"))
            (should (string-match-p label (buffer-substring-no-properties
                                           (point-min) (point-max)))))
          (let* ((refs '(rail panels))
                 (sizes (mapcar (lambda (ref) (etaf-host-ref-size runtime ref)) refs)))
            (should (cl-every #'consp sizes))
            (etaf-animation-test-sleep 0.25)
            (let ((after (mapcar (lambda (ref) (etaf-host-ref-size runtime ref)) refs)))
              (should (equal sizes after))))
          (etaf-dispatch-event runtime 'pause-button 'press)
          (should etaf-animation-paused)
          (let ((revision (etaf-runtime-revision runtime)))
            (etaf-animation-test-sleep 0.15)
            (should (= revision (etaf-runtime-revision runtime))))
          (etaf-dispatch-event runtime 'speed-half 'press)
          (should (= etaf-animation-speed 0.5))
          (etaf-dispatch-event runtime 'fps-30 'press)
          (should (= etaf-animation-frame-rate 30))
          (etaf-dispatch-event runtime 'theme-toggle 'press)
          (should (string-match-p "暗色" (buffer-substring-no-properties
                                         (point-min) (point-max))))
          (etaf-dispatch-event runtime 'theme-toggle 'press)
          (etaf-dispatch-event runtime 'pause-button 'press)
          (etaf-dispatch-event runtime 'clear-button 'press)
          (etaf-focus runtime 'edit-button)
          (execute-kbd-macro (kbd "RET"))
          (let* ((session (etaf-input-active-p runtime))
                 (active (and session t)))
            (should active)
            (should (equal (etaf-input-text session) ""))
            (execute-kbd-macro "hello")
            (should (equal (etaf-input-text session) "hello"))
            (let ((revision (etaf-runtime-revision runtime)))
              (etaf-animation-test-wait
               (lambda () (> (etaf-runtime-revision runtime) (+ revision 1)))))
            (execute-kbd-macro (kbd "C-c C-c"))
            (setq active (and (etaf-input-active-p runtime) t))
            (should-not active))
          (etaf-dispatch-event runtime 'edit-button 'press)
          (etaf-unmount runtime)
          (should (equal original (list etaf-animation-paused etaf-animation-speed
                                       etaf-animation-frame-rate))))
      (when (and buffer (buffer-live-p buffer)) (kill-buffer buffer)))))

(ert-deftest etaf-animation-theatre-multiline-edit-keeps-one-footer ()
  "Growing, clearing and undoing a multiline draft cannot duplicate animation."
  (let* ((buffer (etaf-animation-example-open))
         (runtime (etaf-runtime-for-buffer buffer)))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (etaf-runtime-refit runtime 1200 52)
          (etaf-dispatch-event runtime 'clear-button 'press)
          (etaf-dispatch-event runtime 'edit-button 'press)
          (let ((session (etaf-input-active-p runtime)))
            (dotimes (_ 3)
              (execute-kbd-macro
               (vconcat "one" [return] "two" [return] "three" [return]
                        "four" [return] "five" [return] "six" [return]
                        "seven" [return] "eight"))
              (dolist (keys (list nil (kbd "C-x h C-w") (kbd "C-/") (kbd "C-x h C-w")))
                (when keys (execute-kbd-macro keys))
                (let ((revision (etaf-runtime-revision runtime)))
                  (etaf-animation-test-wait
                   (lambda () (> (etaf-runtime-revision runtime) (+ revision 1)))))
                (let ((count 0))
                  (save-excursion
                    (goto-char (point-min))
                    (while (search-forward "one shared clock" nil t) (cl-incf count)))
                  (should (= count 1)))
                (let ((toolbar (etaf-host-ref-bounds runtime 'edit-button)))
                  (should toolbar))
                (should (string-match-p "EDIT PAD" (buffer-substring-no-properties
                                                   (point-min) (point-max)))))
              (should (equal (etaf-input-text session) "")))))
      (etaf-unmount runtime)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-animation-theatre-reflows-and-fills-its-viewport ()
  "The rail fills every viewport and the gallery reflows to one through four columns."
  (let* ((buffer (etaf-animation-example-open))
         (runtime (etaf-runtime-for-buffer buffer)))
    (unwind-protect
        (dolist (case '((1300 . 4) (900 . 3) (600 . 2) (300 . 1) (1300 . 4)))
          (etaf-runtime-refit runtime (car case) 24)
          (let* ((rail (etaf-host-ref-size runtime 'rail))
                 (grid (etaf-host-ref-size runtime 'panels))
                 (columns (length (plist-get (etaf-runtime-host-props-for runtime 'panels)
                                             :grid-template-columns)))
                 (edit (etaf-host-ref-bounds runtime 'edit-button))
                 (rows (ceiling (/ 20.0 columns))))
            (should (= columns (cdr case)))
            (should (= (car rail) (car case)))
            (should (= (car grid) (car case)))
            ;; The panel area scrolls inside the viewport; the pad and footer
            ;; stay inside the same viewport height.
            (should (>= (cdr grid) 6))
            (should (< (cdr grid) 24))
            (should edit)
            (let ((pad (etaf-host-ref-position runtime 'pad))
                  (footer (etaf-host-ref-position runtime 'footer)))
              (should pad)
              (should footer)
              (with-current-buffer buffer
                (should (<= (line-number-at-pos pad) 24))
                (should (<= (line-number-at-pos footer) 24))))
            ;; The first panel row stays painted; later rows scroll inside the
            ;; panel area instead of pushing the pad out of the viewport.
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "TYPEWRITER" text))
                (should (string-match-p "EDIT PAD" text))))))
      (etaf-unmount runtime)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-animation-theatre-pad-stays-editable-in-small-windows ()
  "The pad keeps focus, native input and its toolbar at narrow or short sizes."
  (let* ((buffer (etaf-animation-example-open))
         (runtime (etaf-runtime-for-buffer buffer)))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          ;; Editing starts through the button, then the session ends outside
          ;; the pad's own lifecycle: the stale reference must not block a
          ;; later session.
          (etaf-dispatch-event runtime 'edit-button 'press)
          (execute-kbd-macro "seed")
          (etaf-input-end (etaf-input-active-p runtime))
          (dolist (size '((1200 . 44) (700 . 30) (489 . 28) (320 . 20) (1200 . 44)))
            (etaf-runtime-refit runtime (car size) (cdr size))
            (etaf-focus runtime 'pad)
            (execute-kbd-macro (kbd "RET"))
            (let ((session (etaf-input-active-p runtime)))
              (should session)
              (execute-kbd-macro "ab")
              (should (string-suffix-p "ab" (etaf-input-text session))))
            (should (etaf-host-ref-bounds runtime 'edit-button))
            (etaf-dispatch-event runtime 'finish-button 'press)
            (should-not (and (etaf-input-active-p runtime) t)))
          ;; The Edit button reopens after clearing to an empty draft.
          (etaf-dispatch-event runtime 'clear-button 'press)
          (etaf-dispatch-event runtime 'edit-button 'press)
          (should (etaf-input-active-p runtime))
          ;; An empty draft paints no text, so the pad area itself must start
          ;; the session: that is where a user clicks to type.
          (etaf-dispatch-event runtime 'finish-button 'press)
          (should-not (and (etaf-input-active-p runtime) t))
          (etaf-dispatch-event runtime 'pad 'press)
          (should (etaf-input-active-p runtime))
          (execute-kbd-macro "typed")
          (should (equal "typed"
                         (etaf-input-text (etaf-input-active-p runtime))))
          ;; Complete pointer gestures run post-command handling too.  Calling
          ;; the press callback alone cannot catch a session ending on release.
          (etaf-dispatch-event runtime 'clear-button 'press)
          (dolist (width '(400 700 320))
            (etaf-runtime-refit runtime width 24)
            (let* ((bounds (etaf-host-ref-bounds runtime 'pad))
                   (position (save-excursion
                               (goto-char (car bounds)) (forward-line 2) (point)))
                   (posn (list (selected-window) position '(2 . 2) 0))
                   ;; Batch Emacs has no pixel hit tester; route through the
                   ;; actual keymap painted on the chosen cell.
                   (overriding-local-map (get-text-property position 'keymap)))
              (execute-kbd-macro (vector (list 'down-mouse-1 posn)
                                         (list 'mouse-1 posn))))
            (let ((active (and (etaf-input-active-p runtime) t)))
              (should active))
            (execute-kbd-macro "x")
            (execute-kbd-macro (kbd "DEL"))
            (let ((text (etaf-input-text (etaf-input-active-p runtime))))
              (should (equal text "")))))
      (when-let* ((session (etaf-input-active-p runtime)))
        (etaf-input-end session))
      (etaf-unmount runtime)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-animation-transition-delay-waits-before-moving ()
  "A delayed transition holds its starting value during delay, then moves."
  (should-error (etaf-transition (etaf-ref 0) :delay -0.1)
                :type 'etaf-animation-error)
  (let* ((completed 0)
         (target (etaf-ref 0))
         (shown (etaf-transition target :duration 0.15 :delay 0.12
                                 :easing 'linear
                                 :on-complete (lambda () (cl-incf completed)))))
    (unwind-protect
        (progn
          (setf (etaf-value target) 10)
          (should (etaf-animation-active-p shown))
          (etaf-animation-test-sleep 0.06)
          (should (= 0 (etaf-value shown)))
          (etaf-animation-test-wait
           (lambda () (not (etaf-animation-active-p shown))))
          (should (= 10 (etaf-value shown)))
          (should (= 1 completed)))
      (etaf-animation-stop shown))))

(ert-deftest etaf-animation-spring-physics-retarget-and-presets ()
  "Springs settle with momentum, support presets and lists, and validate args."
  (should-error (etaf-spring (etaf-ref 0) :preset 'unknown)
                :type 'etaf-animation-error)
  (should-error (etaf-spring (etaf-ref 0) :stiffness 0)
                :type 'etaf-animation-error)
  (should-error (etaf-spring (etaf-ref 0) :damping -1)
                :type 'etaf-animation-error)
  (should-error (etaf-spring (etaf-ref 0) :mass 0)
                :type 'etaf-animation-error)
  (should-error (etaf-spring (etaf-ref 0) :precision 0)
                :type 'etaf-animation-error)
  ;; Underdamped bouncy preset overshoots target before settling.
  (let* ((completed 0)
         (target (etaf-ref 0))
         (shown (etaf-spring target :preset 'bouncy :precision 0.05
                             :on-complete (lambda () (cl-incf completed))))
         (samples nil)
         (stop (etaf-watch shown (lambda (new _old) (push new samples)))))
    (unwind-protect
        (progn
          (setf (etaf-value target) 100)
          (should (etaf-animation-active-p shown))
          (etaf-animation-test-wait
           (lambda () (not (etaf-animation-active-p shown))))
          (should (= 100 (etaf-value shown)))
          (should (= 1 completed))
          (should (cl-some (lambda (v) (> v 100.5)) samples)))
      (etaf-animation-stop shown)
      (funcall stop)))
  ;; Length list interpolation and mid-flight finish.
  (let* ((target (etaf-ref '(px 0)))
         (shown (etaf-spring target :preset 'snappy :precision 0.1)))
    (unwind-protect
        (progn
          (setf (etaf-value target) '(px 80))
          (etaf-animation-test-wait
           (lambda () (> (cadr (etaf-value shown)) 5)))
          (should (eq 'px (car (etaf-value shown))))
          (setf (etaf-value target) '(px 20))
          (etaf-animation-finish shown)
          (should (equal '(px 20) (etaf-value shown)))
          (should-not (etaf-animation-active-p shown)))
      (etaf-animation-stop shown)))
  ;; Disabled animations snap immediately.
  (let* ((etaf-animation-enabled nil)
         (target (etaf-ref 0))
         (shown (etaf-spring target :preset 'gentle)))
    (setf (etaf-value target) 42)
    (should (= 42 (etaf-value shown)))
    (should-not (etaf-animation-active-p shown))))

(ert-deftest etaf-animation-tick-reports-dt-elapsed-and-interval ()
  "Tick subscriptions report dt and elapsed, obey interval and stop cleanly."
  (should-error (etaf-animation-tick 'not-a-fn) :type 'wrong-type-argument)
  (should-error (etaf-animation-tick #'ignore :interval -1)
                :type 'etaf-animation-error)
  (let ((calls nil)
        (handle nil))
    (unwind-protect
        (progn
          (setq handle (etaf-animation-tick
                        (lambda (dt elapsed) (push (cons dt elapsed) calls))
                        :interval 0.05 :name 'tick-test))
          (should (etaf-animation-active-p handle))
          (etaf-animation-test-wait (lambda () (>= (length calls) 3)))
          (let ((ordered (nreverse (copy-sequence calls))))
            (should (cl-every (lambda (pair) (>= (car pair) 0.045)) ordered))
            (should (cl-every (lambda (a b) (< (cdr a) (cdr b)))
                              ordered (cdr ordered)))
            (should (> (etaf-value handle) 0.1)))
          (etaf-animation-stop handle)
          (should-not (etaf-animation-active-p handle))
          (let ((count (length calls)))
            (etaf-animation-test-sleep 0.1)
            (should (= count (length calls)))))
      (when handle (etaf-animation-stop handle)))))

(ert-deftest etaf-animation-timeline-sequences-parallel-and-finish ()
  "Timelines sequence calls, delays, runs and parallel steps, and finish cleanly."
  (should-error (etaf-animation-timeline nil) :type 'etaf-animation-error)
  (should-error (etaf-animation-timeline '((:bogus 1))) :type 'etaf-animation-error)
  (should-error (etaf-animation-timeline '((:delay -1))) :type 'etaf-animation-error)
  (should-error (etaf-animation-timeline '((:parallel nil))) :type 'etaf-animation-error)
  (let ((log nil)
        (run-values nil)
        (par-a nil)
        (par-b nil)
        (completed 0)
        tl)
    (unwind-protect
        (progn
          (setq tl
                (etaf-animation-timeline
                 (list
                  (list :call (lambda () (push 'first log)))
                  (list :delay 0.05)
                  (list :run (lambda (p) (push p run-values))
                        :duration 0.08 :easing 'linear)
                  (list :parallel
                        (list (list :run (lambda (p) (push p par-a)) :duration 0.05)
                              (list :delay 0.04)))
                  (list :call (lambda () (push 'last log))))
                 :on-complete (lambda () (cl-incf completed))))
          (should (etaf-animation-active-p tl))
          (etaf-animation-test-wait (lambda () (not (etaf-animation-active-p tl))))
          (should (equal '(first last) (nreverse log)))
          (should (= 1.0 (car run-values)))
          (should (= 1.0 (car par-a)))
          (should (null par-b))
          (should (= 5 (etaf-value tl)))
          (should (= 1 completed)))
      (when tl (etaf-animation-stop tl))))
  ;; Finishing mid-run executes every remaining step in order and completes.
  (let ((events nil)
        (completed 0)
        tl)
    (unwind-protect
        (progn
          (setq tl
                (etaf-animation-timeline
                 (list (list :delay 2.0)
                       (list :call (lambda () (push 'step-a events)))
                       (list :run (lambda (p) (push (list 'run p) events))
                             :duration 1.0)
                       (list :call (lambda () (push 'step-b events))))
                 :on-complete (lambda () (cl-incf completed))))
          (should (etaf-animation-active-p tl))
          (etaf-animation-finish tl)
          (should-not (etaf-animation-active-p tl))
          (should (equal '(step-a (run 1.0) step-b) (nreverse events)))
          (should (= 1 completed)))
      (when tl (etaf-animation-stop tl))))
  ;; Disabled animations resolve a non-looping timeline immediately.
  (let ((etaf-animation-enabled nil)
        (events nil)
        (completed 0))
    (let ((tl (etaf-animation-timeline
               (list (list :call (lambda () (push 'a events)))
                     (list :delay 5.0)
                     (list :call (lambda () (push 'b events))))
               :on-complete (lambda () (cl-incf completed)))))
      (should-not (etaf-animation-active-p tl))
      (should (equal '(a b) (nreverse events)))
      (should (= 1 completed)))))

(ert-deftest etaf-animation-quantize-and-oklab-color-space ()
  "Quantization snaps numeric shapes and OKLab blends colors perceptually."
  (should (= 0.375 (etaf-animation-quantize 0.37 0.125)))
  (should (equal '(px 14.0) (etaf-animation-quantize '(px 13.7) 2)))
  (should (equal [10.0 20.0] (etaf-animation-quantize [11 19] 10)))
  (should-error (etaf-animation-quantize 1 0) :type 'etaf-animation-error)
  (let ((rgb-mid (let ((etaf-animation-color-space 'rgb))
                   (etaf-animation-interpolate "#ff0000" "#00ff00" 0.5)))
        (oklab-mid (let ((etaf-animation-color-space 'oklab))
                     (etaf-animation-interpolate "#ff0000" "#00ff00" 0.5))))
    (should (color-name-to-rgb rgb-mid))
    (should (color-name-to-rgb oklab-mid))
    (should-not (equal rgb-mid oklab-mid)))
  (let ((etaf-animation-color-space 'bogus))
    (should-error (etaf-animation-interpolate "#000000" "#ffffff" 0.5)
                  :type 'etaf-animation-error)))

(defvar etaf-animation-test--hidden-elapsed nil
  "Elapsed ref owned by the hidden-pause test component.")

(etaf-define-component etaf-animation-test--hidden-card ()
  "Component owning a tick animation for visibility-pause verification."
  :setup (progn
           (setq etaf-animation-test--hidden-elapsed
                 (etaf-animation-tick #'ignore :name 'hidden-tick))
           nil)
  :view (text (expr (format "t=%.2f" (etaf-value etaf-animation-test--hidden-elapsed)))))

(ert-deftest etaf-animation-pause-hidden-holds-undisplayed-buffer ()
  "With `etaf-animation-pause-hidden' non-nil, hidden buffers pause and resume."
  (let ((etaf-animation-pause-hidden t)
        (buffer (generate-new-buffer " *etaf-anim-hidden*"))
        (other (generate-new-buffer " *etaf-anim-other*"))
        runtime)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buffer)
          (etaf-mount buffer (etaf-view (etaf-animation-test--hidden-card))
                      (list :viewport-width 300 :viewport-height 8))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (etaf-animation-test-wait
           (lambda () (> (etaf-value etaf-animation-test--hidden-elapsed) 0.04)))
          ;; Hide BUFFER by displaying OTHER in the sole window.
          (switch-to-buffer other)
          (let ((frozen (etaf-value etaf-animation-test--hidden-elapsed)))
            (etaf-animation-test-sleep 0.15)
            (should (equal frozen (etaf-value etaf-animation-test--hidden-elapsed)))
            ;; Showing BUFFER again resumes advancing from where it held.
            (switch-to-buffer buffer)
            (etaf-animation-test-wait
             (lambda () (> (etaf-value etaf-animation-test--hidden-elapsed)
                           (+ frozen 0.04))))))
      (when runtime (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p other) (kill-buffer other)))))

(provide 'etaf-animation-tests)
;;; etaf-animation-tests.el ends here
