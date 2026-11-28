;;; etaf-fullscreen-tests.el --- Tests for shared two-tier fullscreen host -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'etaf)

(ert-deftest etaf-fullscreen-window-frame-and-restore ()
  "Two-tier fullscreen tracks reactive state, hides/restores mode-line and cleans up."
  (let* ((events nil)
         (buf (get-buffer-create " *etaf-fullscreen-test*")))
    (unwind-protect
        (with-current-buffer buf
          (should-not (etaf-fullscreen-mode buf))
          (should-not (etaf-fullscreen-active-p buf))
          (let ((orig-ml mode-line-format)
                (was-local (local-variable-p 'mode-line-format)))
            ;; Reactive computed tracks transitions cleanly.
            (let ((seen (etaf-computed (lambda () (etaf-fullscreen-mode buf)))))
              (should-not (etaf-value seen))
              ;; Enter window fullscreen (hides mode-line by default).
              (should (eq 'window
                          (etaf-fullscreen-enter
                           'window buf
                           :on-change (lambda (m) (push m events)))))
              (should (eq 'window (etaf-fullscreen-mode buf)))
              (should (etaf-fullscreen-active-p buf))
              (should (eq 'window (etaf-value seen)))
              (should (null mode-line-format))
              ;; Upgrade directly to frame fullscreen without dropping mode-line hide.
              (should (eq 'frame (etaf-fullscreen-toggle 'frame buf)))
              (should (eq 'frame (etaf-fullscreen-mode buf)))
              (should (eq 'frame (etaf-value seen)))
              (should (null mode-line-format))
              ;; Downgrade directly back to window fullscreen.
              (should (eq 'window (etaf-fullscreen-toggle 'window buf)))
              (should (eq 'window (etaf-fullscreen-mode buf)))
              (should (null mode-line-format))
              ;; Toggling active tier exits cleanly and restores mode-line.
              (should-not (etaf-fullscreen-toggle 'window buf))
              (should-not (etaf-fullscreen-mode buf))
              (should-not (etaf-fullscreen-active-p buf))
              (should-not (etaf-value seen))
              (should (equal mode-line-format orig-ml))
              (should (eq (local-variable-p 'mode-line-format) was-local))
              ;; Idempotent exit and argument validation.
              (should-not (etaf-fullscreen-exit buf))
              (should-error (etaf-fullscreen-enter 'bogus buf)
                            :type 'wrong-type-argument)
              (should (equal (nreverse events) '(window frame window nil))))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest etaf-fullscreen-frame-saves-and-restores-window-splits ()
  "Frame fullscreen collapses splits and restores them cleanly on exit."
  (let ((buf-a (get-buffer-create " *etaf-fs-split-a*"))
        (buf-b (get-buffer-create " *etaf-fs-split-b*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf-a)
          (let ((win-b (split-window-right)))
            (set-window-buffer win-b buf-b)
            (select-window win-b)
            (should (= 2 (length (window-list nil 'nomini))))
            (should (eq 'frame (etaf-fullscreen-enter 'frame buf-b)))
            (should (= 1 (length (window-list nil 'nomini))))
            (should (eq (current-buffer) buf-b))
            ;; Exit restores the original 2-window split and keeps buf-b selected.
            (should-not (etaf-fullscreen-exit buf-b))
            (should (= 2 (length (window-list nil 'nomini))))
            (should (eq (window-buffer (selected-window)) buf-b))))
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

(provide 'etaf-fullscreen-tests)
;;; etaf-fullscreen-tests.el ends here
