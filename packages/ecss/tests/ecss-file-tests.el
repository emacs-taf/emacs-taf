;;; ecss-file-tests.el --- Static rule input acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Static file and program input share inert rule-list syntax.

;;; Code:
(require 'ert)
(require 'ecss)

(ert-deftest ecss-file-reads-one-rule-list ()
  "Files preserve rule order and permit comments without an outer quote."
  (let ((file (make-temp-file "ecss-file-" nil ".ecss")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "; Header\n((\".card\" :color \"red\") (\"& > .title\")) ; End\n"))
          (should (equal (ecss-file-read file)
                         '((".card" :color "red") ("& > .title")))))
      (delete-file file))))

(ert-deftest ecss-file-rejects-trailing-expression ()
  "A second expression is rejected even if both expressions are valid lists."
  (let ((file (make-temp-file "ecss-file-" nil ".ecss")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "nil\n((\".item\" :color \"red\"))"))
          (should-error (ecss-file-read file) :type 'user-error))
      (delete-file file))))

(ert-deftest ecss-rules-reader-rejects-wrappers-and-malformed-data ()
  "Static syntax has one grammar and never executes source expressions."
  (dolist (source '("'((\".card\" :color \"red\"))"
                    "(styles (\".card\" :color \"red\"))"
                    "((\".card\" :color))" "((\"[\" :color \"red\"))"
                    "((\".card\" 42 \"red\"))" "((\".card\") . tail)"
                    "" "; no expression" "(progn (error \"must not run\"))"
                    "#.(error \"must not run\")"))
    (should-error (ecss-read-rules source)))
  (should-not (ecss-read-rules "nil ; empty"))
  (should-not (ecss-read-rules "()")))

(ert-deftest ecss-rules-validation-preserves-inert-values ()
  "Values are retained as data and domain validation remains with schemas."
  (let* ((calls 0)
         (value (lambda () (cl-incf calls)))
         (rules (list (list ".item" 'demo/value value))))
    (should (eq rules (ecss-validate-rules rules)))
    (should (= calls 0)))
  (should (equal (ecss-read-rules "((\".item\" demo/value (error \"inert\")))")
                 '((".item" demo/value (error "inert"))))))

(provide 'ecss-file-tests)
;;; ecss-file-tests.el ends here
