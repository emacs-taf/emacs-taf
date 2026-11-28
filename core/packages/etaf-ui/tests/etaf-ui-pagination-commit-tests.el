;;; etaf-ui-pagination-commit-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-pagination-test--controller ()
  "Return an independently loaded three-page Controller."
  (etaf-data-controller
   (etaf-data-memory-source '((:id 1) (:id 2) (:id 3)) :id-key :id)
   :page-size 1 :auto-load t))

(ert-deftest etaf-ui-pagination-wraps-complete-controls-in-narrow-space ()
  "A narrow allocation wraps whole controls without clipping page text."
  (let ((controller (etaf-ui-pagination-test--controller))
        (buffer (generate-new-buffer " *pagination-narrow*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-pagination :controller controller
                             :previous-ref 'previous :next-ref 'next)))
          (dolist (width '(280 180 140))
            (etaf-runtime-refit (etaf-runtime-for-buffer buffer) width 30)
            (with-current-buffer buffer
              (let ((text (buffer-string)))
                (dolist (label '("‹ Previous" "Next ›" "Page 1 / 3" "1–1 of 3"))
                  (should (string-match-p (regexp-quote label) text))))
              (goto-char (point-min))
              (while (< (point) (point-max))
                (should (<= (ebox-string-pixel-width
                             (buffer-substring (line-beginning-position)
                                               (line-end-position)))
                            (+ width 2)))
                (forward-line 1)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (etaf-data-stop controller)
      (kill-buffer buffer))))

(ert-deftest etaf-ui-pagination-keeps-explicit-colors-and-semantic-defaults ()
  "Explicit colors remain effective without replacing omitted variant defaults."
  (dolist (styles '(nil (:color "#F01234" :bgcolor "#123456"
                        :border ((px 1) solid "#ABCDEF"))))
    (let ((controller (etaf-ui-pagination-test--controller)))
      (with-temp-buffer
        (unwind-protect
            (progn
              (etaf-data-set-page controller 2)
              (etaf-mount
               (current-buffer)
               (etaf-node
                'column nil
                (list (etaf-node 'etaf-button
                                 '(:label "Reference" :ref reference
                                   :variant secondary) nil)
                      (etaf-node 'etaf-button
                                 '(:label "Disabled" :ref disabled :disabled t) nil)
                      (etaf-node 'etaf-pagination
                                 (append (list :controller controller
                                               :previous-ref 'previous :next-ref 'next)
                                         styles)
                                 nil))))
              (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                     (reference (etaf-runtime-host-props-for runtime 'reference))
                     (disabled (etaf-runtime-host-props-for runtime 'disabled)))
                (dolist (ref '(previous next))
                  (let ((props (etaf-runtime-host-props-for runtime ref)))
                    (should (equal (plist-get props :color)
                                   (or (plist-get styles :color)
                                       (plist-get reference :color))))
                    (should (equal (plist-get props :background-color)
                                   (or (plist-get styles :bgcolor)
                                       (plist-get reference :background-color))))
                    (when styles
                      (should (equal (plist-get props :border)
                                     (plist-get styles :border))))))
                (etaf-dispatch-event runtime 'previous 'press)
                (let ((props (etaf-runtime-host-props-for runtime 'previous)))
                  (should (plist-get props :disabled))
                  (should (equal (plist-get props :color) (plist-get disabled :color)))
                  (should (equal (plist-get props :background-color)
                                 (or (plist-get styles :bgcolor)
                                     (plist-get disabled :background-color)))))))
          (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
            (etaf-unmount runtime))
          (etaf-data-stop controller))))))

(provide 'etaf-ui-pagination-commit-tests)
;;; etaf-ui-pagination-commit-tests.el ends here
