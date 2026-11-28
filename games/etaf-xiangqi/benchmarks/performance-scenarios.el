;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- Xiangqi selection, appearance and resize workloads
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-xiangqi)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-xiangqi-benchmark--fixture (mode operation)
  "Create one complete local board for MODE and OPERATION."
  (let* ((etaf-xiangqi-appearance 'light)
         (etaf-xiangqi-opponent 'hot-seat)
         (session (etaf-xiangqi-open 11))
         (buffer (etaf-gamekit-buffer session))
         (runtime (etaf-runtime-for-buffer buffer))
         original-size expected previous-color)
    (list
     :buffer buffer
     :ready (lambda ()
              (if (eq mode 'batch) (etaf-runtime-refit runtime 1100 44)
                (etaf-refit runtime (selected-window)))
              (setq original-size (etaf-host-ref-size runtime 'xiangqi-board))
              (and original-size (eq (etaf-gamekit-status session) 'ready)))
     :invoke
     (lambda (index)
       (pcase operation
         ('select
          (setq expected (with-current-buffer buffer
                           (not (string-match-p "已选" (buffer-substring-no-properties (point-min) (point-max))))))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press))
         ('theme
          (setq previous-color (plist-get (etaf-runtime-host-props-for runtime 'xiangqi-theme) :aria-label))
          (etaf-dispatch-event runtime 'xiangqi-theme 'press))
         ('resize
          (setq expected (if (cl-evenp index) 680 1100))
          (etaf-runtime-refit runtime expected 44))))
     :settled
     (lambda ()
       (and (eq (etaf-gamekit-status session) 'ready)
            (pcase operation
              ('select
               (eq expected (with-current-buffer buffer
                              (and (string-match-p "已选" (buffer-substring-no-properties (point-min) (point-max))) t))))
              ('theme (not (equal previous-color (plist-get (etaf-runtime-host-props-for runtime 'xiangqi-theme) :aria-label))))
              ('resize (= expected (car (etaf-runtime-viewport runtime)))))))
     :verify (lambda ()
               (and (not (etaf-gamekit-last-error session))
                    (= 0 (etaf-gamekit-view session :action_count))
                    (equal original-size (etaf-host-ref-size runtime 'xiangqi-board))))
     :outcome (lambda () (list :operation (symbol-name operation)
                              :moves (etaf-gamekit-view session :action_count)))
     :cleanup (lambda () (etaf-xiangqi-close session)))))

(dolist (case '((select 50 "Pick and clear a soldier without moving the match")
                (theme 50 "Switch the complete board between light and dark")
                (resize 50 "Reflow controls without resizing the board")))
  (let ((operation (car case)))
    (taf-benchmark-register
     (format "etaf-xiangqi.%s" operation) :version 1
     :modes '(batch gui) :isolation 'series :impact 'subtree
     :budget-ms (cadr case) :description (caddr case)
     :setup (lambda (mode) (etaf-xiangqi-benchmark--fixture mode operation)))))

(provide 'etaf-xiangqi-performance-scenarios)
;;; performance-scenarios.el ends here
