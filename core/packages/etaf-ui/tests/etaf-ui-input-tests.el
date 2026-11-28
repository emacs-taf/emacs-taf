;;; etaf-ui-input-tests.el --- Controlled native input behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Native readers supply results; mounted public Components own acceptance.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-ui)

(ert-deftest etaf-ui-number-input-validates-configuration-and-live-value ()
  "Numeric input checks configuration and follows its caller-owned value."
  (dolist (props '((:min "low") (:max high) (:min 4 :max 2)
                   (:label 7) (:value "bad")))
    (with-temp-buffer
      (let ((problem (should-error
                      (etaf-mount (current-buffer)
                                  (etaf-node 'etaf-number-input props nil))
                      :type 'etaf-component-call-error)))
        (should (string-match-p "etaf-number-input.*property.*received.*expected"
                                (cadr problem))))))
  (let ((value (etaf-ref 2)) (maximum (etaf-ref 5)))
    (with-temp-buffer
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (etaf-number-input :ref 'number :bind value :label "Count"
                                 :min 1.5 :max (etaf-value maximum))))
            (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
              (should-error (setf (etaf-value maximum) 1)
                            :type 'etaf-component-call-error)
              (should (string-match-p "Count[^0-9]*2" (buffer-string)))
              (setf (etaf-value maximum) 4)
              (etaf-dispatch-event runtime 'number 'press)
              (switch-to-buffer (current-buffer))
              (execute-kbd-macro (kbd "DEL 3"))
              (etaf-text-input-end)
              (should (= 3 (etaf-value value)))
              (should-error (setf (etaf-value value) "bad")
                            :type 'etaf-component-call-error)
              (should (string-match-p "Count[^0-9]*3" (buffer-string)))
              (setf (etaf-value value) 4)
              (should (string-match-p "Count[^0-9]*4" (buffer-string)))))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(defun etaf-ui-input-test--control (runtime label)
  "Find the visible control with LABEL in RUNTIME's public Host properties."
  (car (cl-find-if
        (lambda (entry)
          (and (equal label (plist-get (cdr entry) :aria-label))
               (etaf-host-ref-position runtime (car entry))))
        (etaf-runtime-host-props-entries runtime))))

(ert-deftest etaf-ui-select-maps-labels-to-controlled-values ()
  "Chips and dropdown selection preserve nil values and disable empty lists."
  (let ((buffer (generate-new-buffer " *select-input*"))
        (value (etaf-ref nil)) (options (etaf-ref '((nil . "进行中") (t . "已完成"))))
        (presentation (etaf-ref 'auto)) observed)
    (unwind-protect
        (progn
          (etaf-mount buffer
                      (etaf-view
                       (column :width '(ch 60) :height '(lh 12)
                         (etaf-select :ref 'state :value value :label "状态"
                                      :options (etaf-value options)
                                      :presentation (etaf-value presentation)
                                      :on-change (lambda (next)
                                                   (setf (etaf-value value) next)
                                                   (push next observed))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            ;; Two options render as chips; no minibuffer is involved.
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) (error "chips must not read"))))
              (etaf-dispatch-event
               runtime (etaf-ui-input-test--control runtime "已完成") 'press)
              (should (etaf-value value))
              (etaf-dispatch-event
               runtime (etaf-ui-input-test--control runtime "进行中") 'press)
              (should-not (etaf-value value)))
            (should (equal observed '(nil t)))
            ;; A dropdown lists the options in a Popover under one anchor.
            (setf (etaf-value presentation) 'dropdown)
            (should-not (etaf-ui-input-test--control runtime "已完成"))
            (etaf-dispatch-event runtime 'state 'press)
            (should (etaf-ui-input-test--control runtime "已完成"))
            (etaf-dispatch-event
             runtime (etaf-ui-input-test--control runtime "已完成") 'press)
            (should (etaf-value value))
            (should-not (etaf-ui-input-test--control runtime "已完成"))
            (should (string-match-p "已完成 ⌄"
                                    (with-current-buffer buffer
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
            (setf (etaf-value value) nil)
            (setf (etaf-value options) nil)
            (should-error (etaf-dispatch-event runtime 'state 'press)
                          :type 'etaf-event-error)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-menu-selects-enabled-actions-and-returns-focus ()
  "Menu choices follow current props and cancel without invoking an action."
  (let ((buffer (generate-new-buffer " *action-menu*"))
        (done (etaf-ref nil)) (enabled (etaf-ref t)) selected)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-menu :ref 'menu :label "操作" :disabled (not (etaf-value enabled))
                       :items (list '(:key edit :label "编辑")
                                    (list :key 'delete :label "删除" :disabled (not (etaf-value done))))
                       :on-select (lambda (key) (push key selected)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-focus runtime 'menu)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt choices &rest _)
                         (should (equal choices '("编辑"))) "编辑")))
              (etaf-activate runtime))
            (should (equal selected '(edit)))
            (should (eq (etaf-focused-host-ref runtime) 'menu))
            (setf (etaf-value done) t)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt choices &rest _)
                         (should (equal choices '("编辑" "删除"))) "删除")))
              (etaf-activate runtime))
            (should (equal selected '(delete edit)))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
              (should (eq 'cancelled (condition-case nil (etaf-activate runtime) (quit 'cancelled)))))
            (should (equal selected '(delete edit)))
            (should (eq (etaf-focused-host-ref runtime) 'menu))
            (setf (etaf-value enabled) nil)
            (should-error (etaf-dispatch-event runtime 'menu 'press) :type 'etaf-event-error)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-confirm-dialog-composes-with-menu-actions ()
  "A chosen action changes data only after confirmation; no preserves focus."
  (let ((buffer (generate-new-buffer " *confirm-menu*")) (deleted 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-menu :ref 'menu :items '((:key delete :label "删除"))
                       :on-select (lambda (_)
                                    (when (etaf-confirm-dialog "删除任务？")
                                      (cl-incf deleted))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (answer '(nil t))
              (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "删除"))
                        ((symbol-function 'yes-or-no-p) (lambda (&rest _) answer)))
                (etaf-dispatch-event runtime 'menu 'press))
              (should (= deleted (if answer 1 0)))
              (should (eq (etaf-focused-host-ref runtime) 'menu)))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "删除"))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) (signal 'quit nil))))
              (should (eq 'cancelled (condition-case nil (etaf-dispatch-event runtime 'menu 'press)
                                      (quit 'cancelled)))))
            (should (= deleted 1))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-native-inputs-report-invalid-props-in-context ()
  "Invalid values, options and bindings identify the Component and property."
  (dolist (case '((etaf-text-input :value 42) (etaf-text-input :label 42)
                  (etaf-select :options ((a . "Same") (b . "Same")))
                  (etaf-select :options ((a . "One") (a . "Two")))
                  (etaf-select :options ((a . ""))) (etaf-select :options 42)
                  (etaf-select :value missing) (etaf-select :bind 42)
                  (etaf-menu :items ((:key a :label "Same") (:key b :label "Same")))
                  (etaf-menu :items ((:key a :label "One") (:key a :label "Two")))
                  (etaf-menu :items ((:key a :label ""))) (etaf-menu :items 42)))
    (let ((buffer (generate-new-buffer " *invalid-input*")))
      (unwind-protect
          (let ((error (should-error (etaf-mount buffer (etaf-node (car case) (cdr case) nil))
                                    :type 'etaf-view-error)))
            (should (string-match-p (symbol-name (car case)) (error-message-string error)))
            (should (string-match-p (symbol-name (cadr case)) (error-message-string error))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
        (kill-buffer buffer)))))

(provide 'etaf-ui-input-tests)
;;; etaf-ui-input-tests.el ends here
