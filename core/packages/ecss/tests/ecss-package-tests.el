;;; ecss-package-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Geekinney
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ecss)
(require 'package)

(ert-deftest ecss-package-test-independent-schema-and-stylesheet-state ()
  (let ((left-schemas
         (ecss-schema-set-compose
          (ecss-schema-package-create
           'left '((:id left/color :initial "left" :impacts (paint))))))
        (right-schemas
         (ecss-schema-set-compose
          (ecss-schema-package-create
           'right '((:id right/color :initial "right" :impacts (paint))))))
        (left-sheet (ecss-stylesheet-create))
        (right-sheet (ecss-stylesheet-create)))
    (ecss-stylesheet-add-rule
     left-sheet left-schemas "*" '(left/color "changed"))
    (should (null (ecss-stylesheet-rules right-sheet)))
    (should (null (ecss-schema-set-property right-schemas 'left/color)))
    (should (equal (ecss-computed-style-value
                    (ecss-compute-style
                     right-schemas (ecss-subject-create :type "node")
                     :stylesheet right-sheet)
                    'right/color)
                   "right"))))

(provide 'ecss-package-tests)
;;; ecss-package-tests.el ends here
