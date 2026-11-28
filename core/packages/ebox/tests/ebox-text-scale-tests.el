;;; -*- lexical-binding: t; -*-
;;; ebox-text-scale-tests.el --- Settled display metrics and retained layouts

(require 'ebox-test-support)

(defun ebox-test-await-display (predicate)
  "Wait at most two seconds for PREDICATE and return its result."
  (let ((end (+ (float-time) 2)))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (sleep-for 0.01))
    (funcall predicate)))

(ert-deftest ebox-text-scale-change-relayouts-its-mount-once ()
  "A burst publishes one settled display without replacing the tree."
  (ebox-test-with-mounted (buffer root '(box :width (ch 5) "00000") :width 400 :height 10)
    (let* ((seen nil)
           (hook (lambda (changed)
                   (when (eq changed buffer)
                     (push (ebox-display-metrics changed) seen)))))
      (unwind-protect
          (progn
            (add-hook 'ebox-display-change-functions hook)
            (text-scale-increase 1)
            (text-scale-increase 1)
            (should (ebox-test-await-display (lambda () seen)))
            (should (= (length seen) 1))
            (let ((same (eq root (ebox-buffer-root buffer)))
                  (width (plist-get (ebox-node-geometry root) :width))
                  (expected (ebox-test-native-width "00000" buffer)))
              (should same)
              (should (= width expected)))
            ;; A fixed viewport still receives metric changes and reset.
            (setq seen nil)
            (text-scale-set 0)
            (should (ebox-test-await-display (lambda () seen)))
            (should (equal (ebox-mount-viewport buffer) '(400 . 10))))
        (remove-hook 'ebox-display-change-functions hook)))))

(ert-deftest ebox-text-scale-change-refreshes-only-the-scaled-mount ()
  "Shared styles must not share character widths across scaled buffers."
  (ebox-test-with-mounted (other other-root '(box :width (ch 5) :background-color "black" "00000"))
    (ebox-test-with-mounted (buffer root '(box :width (ch 5) :background-color "black" "00000"))
      (let* ((seen nil)
             (hook (lambda (changed) (push changed seen))))
        (unwind-protect
            (progn
              (add-hook 'ebox-display-change-functions hook)
              (dolist (scale '(2 -2 0))
                (setq seen nil)
                (text-scale-set scale)
                (should (ebox-test-await-display (lambda () (memq buffer seen))))
                (should-not (memq other seen))
                ;; Exercise an ordinary retained update between refreshes.
                (ebox-node-set-text (car (ebox-node-children other-root)) "11111")
                (ebox-node-set-text (car (ebox-node-children root)) "22222")
                (let ((own-width (plist-get (ebox-node-geometry root) :width))
                      (other-width (plist-get (ebox-node-geometry other-root) :width))
                      (expected (ebox-test-native-width "00000" buffer))
                      (other-expected (ebox-test-native-width "00000" other)))
                  (should (= own-width expected))
                  (should (= other-width other-expected)))))
          (remove-hook 'ebox-display-change-functions hook))))))

(ert-deftest ebox-text-scale-change-skips-buffers-without-a-live-mount ()
  "Pending changes of unmounted or killed buffers publish no display."
  (let ((buffer (generate-new-buffer " *ebox-released-scale*"))
        (seen nil))
    (unwind-protect
        (let ((hook (lambda (changed) (when (eq changed buffer) (push t seen)))))
          (unwind-protect
              (progn
                (add-hook 'ebox-display-change-functions hook)
                (ebox-mount buffer '(box "Released"))
                (with-current-buffer buffer (text-scale-set 1))
                (ebox-unmount-buffer buffer)
                (sleep-for (+ ebox-viewport-settle-delay 0.05))
                (should-not seen)
                (with-current-buffer buffer (text-scale-set 2))
                (kill-buffer buffer)
                (sleep-for (+ ebox-viewport-settle-delay 0.05))
                (should-not seen))
            (remove-hook 'ebox-display-change-functions hook)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-display-metrics-are-owned-and-match-native-measurement ()
  "Metrics agree with the effective default face and callers own the plist."
  (with-temp-buffer
    (dolist (scale '(0 2 -2 0))
      (text-scale-set scale)
      (let* ((metrics (ebox-display-metrics))
             (expected (ebox-test-native-width "0" (current-buffer))))
        (should (= (plist-get metrics :char-width) expected))
        (should (> (plist-get metrics :line-height) 0))
        (should (<= 1 (plist-get metrics :ascent) 100))
        (setf (plist-get metrics :char-width) 999999)
        (should (= (plist-get (ebox-display-metrics) :char-width) expected))))))

(ert-deftest ebox-text-scale-keeps-untouched-row-heights ()
  "A text scale change raises every row, including rows the update did not rewrite."
  (skip-unless (and (display-graphic-p)
                    (find-font (font-spec :family "Noto Serif CJK SC"))))
  (let* ((frame (selected-frame))
         (range '(#x4e00 . #x9fff))
         (prior (fontset-font "fontset-default" #x4e00))
         (shown (window-buffer (selected-window)))
         (buffer (generate-new-buffer " *ebox-text-scale*")))
    (unwind-protect
        (progn
          (set-fontset-font "fontset-default" range
                            (font-spec :family "Noto Serif CJK SC") frame)
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (let* ((root (ebox-mount buffer '(column :width 'stretch
                                                    (text :id "first" "0 0")
                                                    (text :id "second" "汉汉"))
                                     :width 200 :height 2))
                   (first (car (ebox-selector-query root "#first")))
                   (before (plist-get (ebox-display-metrics buffer) :line-height)))
              (text-scale-increase 1)
              (ebox-node-set-text first "00000")
              (ebox-flush)
              (redisplay t)
              (let* ((line (plist-get (ebox-display-metrics buffer) :line-height))
                     (second-start (save-excursion (goto-char (point-min))
                                                   (forward-line 1) (point))))
                (should (> line before))
                (should (= (cdr (window-text-pixel-size
                                 (selected-window)
                                 second-start
                                 (save-excursion (goto-char second-start)
                                                 (line-end-position))))
                           line))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (set-window-buffer (selected-window) shown)
      (set-fontset-font "fontset-default" range
                        (and prior (font-spec :family (car prior)
                                              :registry (cdr prior)))
                        frame))))

(provide 'ebox-text-scale-tests)
;;; ebox-text-scale-tests.el ends here
