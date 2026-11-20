;;; etaf-ui-button-commit-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf-ui)

(ert-deftest etaf-ui-button-callback-uses-only-committed-props ()
  "A later sibling failure cannot replace the live Button callback."
  (let ((label (etaf-ref "A"))
        (buffer (generate-new-buffer " *button-commit*"))
        events)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (lambda ()
             (let ((caption (etaf-value label)))
               (etaf-view
                (column
                 (etaf-button :ref 'button-commit :label caption
                  :on-press (lambda () (push caption events)))
                 (text (expr (if (equal (etaf-value label) "Rejected")
                                 (error "Rejected sibling")
                               "Sibling"))))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'button-commit 'press)
            (setf (etaf-value label) "B")
            (etaf-dispatch-event runtime 'button-commit 'press)
            (let ((published (with-current-buffer buffer (buffer-string)))
                  (generation (etaf-runtime-revision runtime)))
              (should-error (setf (etaf-value label) "Rejected"))
              (should (eq generation (etaf-runtime-revision runtime)))
              (should (equal-including-properties
                       published (with-current-buffer buffer (buffer-string)))))
            (etaf-dispatch-event runtime 'button-commit 'press)
            (should (equal '("B" "B" "A") events))
            (setf (etaf-value label) "C")
            (etaf-dispatch-event runtime 'button-commit 'press)
            (should (equal '("C" "B" "B" "A") events))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-ui-button-commit-tests)
;;; etaf-ui-button-commit-tests.el ends here
