;;; -*- lexical-binding: t; -*-
;;; etaf-display-tests.el --- Reactive display metrics through public interfaces
(require 'etaf-test-support)

(etaf-define-component etaf-test-display-view ()
  :bindings ((count (etaf-ref 0)))
  :view
  (column
    (text :ref 'metrics (expr (format "%d/%d" (plist-get (etaf-display-metrics) :char-width)
                                      (plist-get (etaf-display-metrics) :line-height))))
    (box :ref 'advance :role 'button :tab-index 0
         :on-press (lambda () (cl-incf (etaf-value count)))
      (text (expr (number-to-string (etaf-value count)))))))

(ert-deftest etaf-display-metrics-update-fixed-viewport-with-retained-state ()
  "Display readers refresh after zoom without replacing Component state."
  (etaf-test-with-mount (runtime (etaf-view (etaf-test-display-view)))
    (etaf-focus runtime 'advance)
    (etaf-activate runtime)
    (dolist (scale '(2 -2 0))
      (text-scale-set scale)
      (sleep-for 0.3)
      (let* ((metrics (etaf-display-metrics runtime))
             (expected (format "%d/%d" (plist-get metrics :char-width)
                               (plist-get metrics :line-height)))
             (text (etaf-test-text))
             (viewport (etaf-runtime-viewport runtime)))
        (should (string-match-p (regexp-quote expected) text))
        (should (string-match-p "\n1\\'" text))
        (should (equal viewport '(800 . 40)))
        (setf (plist-get metrics :char-width) 999999)
        (should (< (plist-get (etaf-display-metrics runtime) :char-width) 999999))))))

(ert-deftest etaf-display-metrics-require-a-mounted-runtime ()
  "A display read outside a mounted Runtime signals the documented error."
  (with-temp-buffer
    (should-error (etaf-display-metrics) :type 'etaf-runtime-error)))

(provide 'etaf-display-tests)
;;; etaf-display-tests.el ends here
