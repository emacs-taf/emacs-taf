;;; ecss-schema-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Geekinney
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ecss)

(defun ecss-schema-test--definition (id &rest options)
  "Return a complete schema definition for ID extended by OPTIONS."
  (let ((definition (list :id id :initial nil :impacts '(paint))))
    (while options
      (setq definition (plist-put definition (pop options) (pop options))))
    definition))

(defun ecss-schema-test--package (id definitions)
  "Return immutable package ID built from DEFINITIONS."
  (ecss-schema-package-create id definitions))

(ert-deftest ecss-schema-package-validates-identity-and-definitions ()
  "Package and property identities have one strict grammar."
  (dolist (id '(nil :app "app" 4))
    (should-error
     (ecss-schema-package-create id nil)
     :type 'ecss-invalid-property-schema))
  (dolist (definition
           '((:id plain :impacts (paint))
             (:id app/color :impacts nil)
             (:id app/color :impacts (paint paint))
             (:id app/color :impacts (paint) :aliases (:tone :tone))
             (:id app/color :impacts (paint) :projections (tp tp))))
    (should-error
     (ecss-schema-package-create 'app (list definition))
     :type 'ecss-invalid-property-schema))
  (dolist
      (definitions
       '(((:id app/color :impacts (paint) :aliases (:tone))
          (:id app/gap :impacts (geometry) :aliases (:tone)))
         ((:id app/color :impacts (paint) :aliases (app/gap))
          (:id app/gap :impacts (geometry)))
         ((:id app/color :impacts (paint))
          (:id app/gap :impacts (geometry) :aliases (app/color)))))
    (should-error
     (ecss-schema-package-create 'app definitions)
     :type 'ecss-invalid-property-schema)))

(ert-deftest ecss-schema-set-compose-rejects-complete-collision-matrix ()
  "Composition rejects package, canonical, and alias collisions atomically."
  (let* ((left
          (ecss-schema-test--package
           'left (list (ecss-schema-test--definition
                        'left/color :aliases '(shared/tone)))))
         (same-canonical
          (ecss-schema-test--package
           'right (list (ecss-schema-test--definition 'left/color))))
         (canonical-over-alias
          (ecss-schema-test--package
           'right (list (ecss-schema-test--definition 'shared/tone))))
         (alias-over-canonical
          (ecss-schema-test--package
           'right (list (ecss-schema-test--definition
                         'right/color :aliases '(left/color)))))
         (same-alias
          (ecss-schema-test--package
           'right (list (ecss-schema-test--definition
                         'right/color :aliases '(shared/tone))))))
    (should-error (ecss-schema-set-compose left left)
                  :type 'ecss-invalid-property-schema)
    (dolist (right (list same-canonical canonical-over-alias
                         alias-over-canonical same-alias))
      (should-error (ecss-schema-set-compose left right)
                    :type 'ecss-invalid-property-schema)
      (should (equal '(left/color)
                     (ecss-schema-set-property-ids
                      (ecss-schema-set-compose left))))
      (should (= 1 (length (ecss-schema-package-property-ids right)))))))

(ert-deftest ecss-schema-shorthand-conflicts-with-owned-longhand ()
  "One declaration source cannot produce the same canonical output twice."
  (let* ((package
          (ecss-schema-test--package
           'app
           (list
            (ecss-schema-test--definition 'app/top)
            (ecss-schema-test--definition
             'app/padding
             :shorthand (lambda (value) (list 'app/top value))))))
         (schemas (ecss-schema-set-compose package)))
    (should-error
     (ecss-expand-declarations
      schemas '(app/padding 1 app/top 2))
     :type 'ecss-invalid-declaration)
    (should (equal '(app/top 2)
                   (ecss-merge-declarations
                    schemas '(app/padding 1) '(app/top 2))))))

(provide 'ecss-schema-tests)
;;; ecss-schema-tests.el ends here
