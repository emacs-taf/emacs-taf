;;; ecss-value-tests.el --- Staged declaration validation -*- lexical-binding: t; -*-

;;; Commentary:
;; Consumers can validate concrete input without interpreting ECSS value storage.

;;; Code:
(require 'ert)
(require 'ecss)

(ert-deftest ecss-declaration-values-validate-concrete-importance ()
  "Importance changes precedence without changing the concrete value grammar."
  (should (ecss-declaration-value-valid-p (ecss-important "red") #'stringp))
  (should-not (ecss-declaration-value-valid-p (ecss-important 42) #'stringp))
  (should-not (ecss-declaration-value-tagged-p "red"))
  (should-not (ecss-declaration-value-tagged-p (list (ecss-important "red"))))
  (should (ecss-declaration-value-tagged-p (ecss-important "red")))
  (should-error (ecss-declaration-value-valid-p "red" (lambda (_) (error "Invalid")))))

(ert-deftest ecss-declaration-values-defer-contextual-schema-validation ()
  "Deferred values pass preflight but their computed result must satisfy the schema."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'value-test '((:id value-test/color :initial "black"
                                      :validator stringp :inherits t :impacts (paint))))))
         (subject (ecss-subject-create :type "text")))
    (dolist (value (list (ecss-var '--missing 42) (ecss-wide-value 'initial)))
      (should (ecss-declaration-value-tagged-p value))
      (should (ecss-declaration-value-valid-p value #'stringp))
      (should (equal "black"
                     (ecss-computed-style-value
                      (ecss-compute-style schemas subject
                                          :declarations (list 'value-test/color value))
                      'value-test/color))))))

(provide 'ecss-value-tests)
;;; ecss-value-tests.el ends here
