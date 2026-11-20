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

(provide 'etaf-animation-tests)
;;; etaf-animation-tests.el ends here
