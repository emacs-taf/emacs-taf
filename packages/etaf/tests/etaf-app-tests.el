;;; etaf-app-tests.el --- Application buffer lifecycle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(defconst etaf-app-test-name " *etaf-app-test*"
  "Buffer name the application scenarios open.")

(defmacro etaf-app-test-cleanup (&rest body)
  "Run BODY and kill the scenario application buffer afterwards."
  (declare (indent 0) (debug t))
  `(unwind-protect (progn ,@body)
     (when-let* ((buffer (get-buffer etaf-app-test-name)))
       (kill-buffer buffer))))

(defun etaf-app-test-settle-window-change ()
  "Run the settled window-change pass for every frame in batch."
  (let ((noninteractive nil))
    (run-hook-with-args 'window-size-change-functions (selected-frame)))
  (sleep-for (+ ebox-viewport-settle-delay 0.1)))

(ert-deftest etaf-app-open-mounts-a-canvas-and-closes-once ()
  "Opening mounts the View on a canvas; ON-CLOSE runs once, mounted, with STATE."
  (etaf-app-test-cleanup
    (let* ((closed nil)
           (buffer (etaf-app-open
                    etaf-app-test-name (etaf-view (box "Hello"))
                    :display nil :state 'model
                    :on-close (lambda ()
                                (push (list (etaf-runtime-mounted-p
                                             (etaf-runtime-for-buffer
                                              (current-buffer)))
                                            (etaf-app-state))
                                      closed))
                    :mount-options '(:viewport-width 400 :viewport-height 5))))
      (should (eq (etaf-app-buffer etaf-app-test-name) buffer))
      (should (eq (etaf-app-state buffer) 'model))
      (with-current-buffer buffer
        (should (equal (string-trim (etaf-test-text)) "Hello"))
        (should truncate-lines)
        (should-not mode-line-format)
        (should (eq (display-table-slot buffer-display-table 'truncation) ?\s)))
      (should (eq (etaf-app-close buffer) t))
      (should-not (buffer-live-p buffer))
      (should (equal closed '((t model))))
      (should-not (etaf-app-buffer etaf-app-test-name)))))

(ert-deftest etaf-app-killing-the-buffer-or-reopening-closes-the-application ()
  "Killing the buffer and reopening the same name each run ON-CLOSE once."
  (etaf-app-test-cleanup
    (let ((closed 0))
      (dotimes (_ 2)
        (etaf-app-open etaf-app-test-name (etaf-view (box "A")) :display nil
                       :on-close (lambda () (cl-incf closed))
                       :mount-options '(:viewport-width 400 :viewport-height 5)))
      (should (= closed 1))
      (kill-buffer etaf-app-test-name)
      (should (= closed 2))
      (should-error (etaf-app-close (get-buffer-create etaf-app-test-name))
                    :type 'user-error))))

(ert-deftest etaf-app-open-failure-closes-and-propagates ()
  "A failing mount kills the buffer, runs ON-CLOSE and propagates the error."
  (etaf-app-test-cleanup
    (let ((closed 0))
      (should-error
       (etaf-app-open etaf-app-test-name (lambda () (error "Broken view"))
                      :display nil :on-close (lambda () (cl-incf closed))
                      :mount-options '(:viewport-width 400 :viewport-height 5)))
      (should (= closed 1))
      (should-not (get-buffer etaf-app-test-name)))))

(ert-deftest etaf-app-close-reports-the-close-error-after-teardown ()
  "A failing ON-CLOSE still tears the application down, then signals."
  (etaf-app-test-cleanup
    (let ((buffer (etaf-app-open
                   etaf-app-test-name (etaf-view (box "A")) :display nil
                   :on-close (lambda () (error "Close failed"))
                   :mount-options '(:viewport-width 400 :viewport-height 5))))
      (should (equal (cadr (should-error (etaf-app-close buffer)))
                     "Close failed"))
      (should-not (buffer-live-p buffer)))))

(ert-deftest etaf-app-canvas-follows-the-theme-source ()
  "A reactive background remaps the default face and repaints on change."
  (etaf-app-test-cleanup
    (let* ((color (etaf-ref "#101010"))
           (buffer (etaf-app-open
                    etaf-app-test-name (etaf-view (box "A")) :display nil
                    :background color :foreground (lambda () "#eeeeee")
                    :cursor nil
                    :mount-options '(:viewport-width 400 :viewport-height 5))))
      (with-current-buffer buffer
        (should-not cursor-type)
        (should (equal (alist-get 'default face-remapping-alist)
                       '((:background "#101010" :foreground "#eeeeee"))))
        (etaf-set-value color "#202020")
        (should (equal (alist-get 'default face-remapping-alist)
                       '((:background "#202020" :foreground "#eeeeee")))))
      (etaf-app-close buffer)
      ;; A closed application stops following its source.
      (etaf-set-value color "#303030"))))

(ert-deftest etaf-app-canvas-matches-the-window-after-hiding-the-mode-line ()
  "The canvas is the window's body, not the mode line's larger body.
Hiding the mode line does not resize the window, so its cached body height
still counts that row until the next redisplay; a canvas one row taller than
the window scrolls as a whole and slides every pane at once."
  (etaf-app-test-cleanup
    (let ((buffer (etaf-app-open etaf-app-test-name (etaf-view (box "A"))
                                 :mode-line nil)))
      (accept-process-output nil 0.05)
      (with-current-buffer buffer
        (let ((window (get-buffer-window buffer t)))
          (should window)
          (should (= (cdr (etaf-runtime-viewport
                           (etaf-runtime-for-buffer buffer)))
                     (window-body-height window))))))))

(ert-deftest etaf-app-mount-options-function-follows-the-fit ()
  "A MOUNT-OPTIONS function runs in the buffer after ON-FIT with its window."
  (etaf-app-test-cleanup
    (let* ((fitted nil) (calls nil)
           (buffer (etaf-app-open
                    etaf-app-test-name (etaf-view (box "A"))
                    :on-fit (lambda (_window) (setq fitted 7))
                    :mount-options
                    (lambda (window)
                      (push (list fitted (current-buffer)
                                  (eq window (get-buffer-window (current-buffer) t)))
                            calls)
                      (list :viewport-width 400 :viewport-height fitted)))))
      (should (equal calls (list (list 7 buffer t))))
      (should (equal (cdr (etaf-runtime-viewport (etaf-runtime-for-buffer buffer)))
                     7)))))

(ert-deftest etaf-app-fits-after-a-settled-window-change ()
  "ON-FIT runs before mount and again after the display window settles."
  (etaf-app-test-cleanup
    (let* ((heights nil)
           (frame-window (selected-window))
           (buffer (etaf-app-open
                    etaf-app-test-name (etaf-view (box "A"))
                    :on-fit (lambda (window)
                              (push (list (current-buffer)
                                          (window-body-height window))
                                    heights)))))
      (unwind-protect
          (progn
            (should (equal heights (list (list buffer (window-body-height frame-window)))))
            (split-window frame-window)
            (etaf-app-test-settle-window-change)
            (should (= (length heights) 2))
            (should (eq (car (car heights)) buffer))
            (should (< (cadr (car heights)) (cadr (cadr heights))))
            ;; A settle without a change of the window does not fit again.
            (etaf-app-test-settle-window-change)
            (should (= (length heights) 2))
            (etaf-app-close buffer)
            (delete-other-windows frame-window)
            (etaf-app-test-settle-window-change)
            (should (= (length heights) 2)))
        (delete-other-windows frame-window)))))

;;; etaf-app-tests.el ends here
