;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- Solitaire selection, play, appearance and resize workloads
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-solitaire)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-solitaire-benchmark--fixture (mode operation)
  "Create one complete card table for MODE and OPERATION."
  (let* ((etaf-solitaire-appearance 'light)
         (session (etaf-solitaire-open 11))
         (buffer (etaf-gamekit-buffer session))
         (runtime (etaf-runtime-for-buffer buffer))
         original-size expected previous-label)
    (cl-labels
        ((paint () (with-current-buffer buffer
                     (buffer-substring-no-properties (point-min) (point-max))))
         (selected-p () (string-match-p "已选" (paint)))
         (settle-until (predicate)
           (let ((end (+ (float-time) 5)))
             (while (and (< (float-time) end) (not (funcall predicate)))
               (accept-process-output nil 0.01))))
         (count () (or (etaf-gamekit-view session :action_count) 0))
         (reset ()
           ;; Undo every accepted move so each sample starts from the deal.
           (settle-until (lambda () (eq (etaf-gamekit-status session) 'ready)))
           (when (> (count) 0)
             (when (eq t (etaf-gamekit-view session :can_undo))
               (etaf-dispatch-event runtime 'solitaire-undo 'press))
             (settle-until (lambda () (= 0 (count)))))))
      (list
       :buffer buffer
       :ready
       (lambda ()
         (if (eq mode 'batch) (etaf-runtime-refit runtime 1000 44)
           (etaf-refit runtime (selected-window)))
         (reset)
         (when (eq operation 'move)
           ;; Select the legal source outside the timed input; only the target
           ;; press that completes the move is measured.
           (unless (selected-p)
             (when (eq (etaf-gamekit-status session) 'ready)
               (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press)))
           (settle-until #'selected-p))
         (setq original-size (etaf-host-ref-size runtime 'solitaire-board))
         (and original-size (eq (etaf-gamekit-status session) 'ready)
              (or (not (eq operation 'move)) (selected-p))))
       :invoke
       (lambda (index)
         (pcase operation
           ('select
            ;; The same legal source is chosen and cleared again, so every
            ;; sample repeats without changing the native deal.
            (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press)
            (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press))
           ('move (etaf-dispatch-event runtime 'solitaire-foundation-2 'press))
           ('theme
            (setq previous-label
                  (plist-get (etaf-runtime-host-props-for runtime 'solitaire-theme) :aria-label))
            (etaf-dispatch-event runtime 'solitaire-theme 'press))
           ('resize
            (setq expected (if (cl-evenp index) 780 1000))
            (etaf-runtime-refit runtime expected 44))))
       :settled
       (lambda ()
         (and (eq (etaf-gamekit-status session) 'ready)
              (pcase operation
                ('select (not (selected-p)))
                ('move (= 1 (count)))
                ('theme (not (equal previous-label
                                    (plist-get (etaf-runtime-host-props-for
                                                runtime 'solitaire-theme)
                                               :aria-label))))
                ('resize (= expected (car (etaf-runtime-viewport runtime)))))))
       :verify (lambda ()
                 (and (not (etaf-gamekit-last-error session))
                      (<= (count) 1)
                      (equal original-size (etaf-host-ref-size runtime 'solitaire-board))))
       :outcome (lambda () (list :operation (symbol-name operation)
                                :actions (count)))
       :cleanup (lambda () (etaf-solitaire-close session))))))

(dolist (case '((select 50 "Pick and clear a card without moving the deal")
                (move 50 "Complete one native legal move from a prepared selection")
                (theme 50 "Switch the complete table between light and dark")
                (resize 50 "Reflow the table without resizing the cards")))
  (let ((operation (car case)))
    (taf-benchmark-register
     (format "etaf-solitaire.%s" operation) :version 1
     :modes '(batch gui) :isolation 'series :impact 'subtree
     :budget-ms (cadr case) :description (caddr case)
     :setup (lambda (mode) (etaf-solitaire-benchmark--fixture mode operation)))))

(provide 'etaf-solitaire-performance-scenarios)
;;; performance-scenarios.el ends here
