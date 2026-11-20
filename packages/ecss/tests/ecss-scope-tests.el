;;; ecss-scope-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ecss)

(ert-deftest ecss-scope-nested-cascade-and-boundaries ()
  "Scopes combine by specificity then distance, without external traversal."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test '((:id test/color :initial "default"
                             :validator stringp :impacts (paint))))))
         (outside (ecss-subject-create :classes '("outside")))
         (outer (ecss-subject-create :parent outside :classes '("item")))
         (inner (ecss-subject-create :parent outer))
         (item (ecss-subject-create :parent inner :id "chosen"
                                    :classes '("item")))
         (sibling (ecss-subject-create :parent outside :classes '("item")))
         (a (ecss-stylesheet-create))
         (b (ecss-stylesheet-create)))
    (ecss-stylesheet-add-rule a schemas ".item" '(test/color "outer"))
    (ecss-stylesheet-add-rule b schemas ".item" '(test/color "inner"))
    (let ((scopes (list (ecss-scope-create outer a)
                        (ecss-scope-create inner b))))
      (should (equal "inner" (ecss-computed-style-value
                              (ecss-compute-style schemas item :scopes scopes)
                              'test/color)))
      (dolist (subject (list outer sibling))
        (should (equal "default" (ecss-computed-style-value
                                  (ecss-compute-style schemas subject :scopes scopes)
                                  'test/color)))))
    (ecss-stylesheet-add-rule a schemas "#chosen" '(test/color "specific"))
    (should (equal "specific" (ecss-computed-style-value
                               (ecss-compute-style
                                schemas item :scopes
                                (list (ecss-scope-create outer a)
                                      (ecss-scope-create inner b))) 'test/color)))
    (let ((sheet (ecss-stylesheet-create)))
      (ecss-stylesheet-add-rule sheet schemas ".outside .item"
                                '(test/color "leak"))
      (ecss-stylesheet-add-rule sheet schemas "&:has(+ .item)"
                                '(test/color "leak"))
      (let ((scope (ecss-scope-create outer sheet)))
        (dolist (subject (list item outer sibling))
          (should (equal "default" (ecss-computed-style-value
                                    (ecss-compute-style schemas subject
                                                        :scopes (list scope))
                                    'test/color))))))))

(ert-deftest ecss-scope-root-state-and-has-anchor-are-independent ()
  "Root references survive :has relative anchor rebinding."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test '((:id test/color :initial "default"
                             :validator stringp :impacts (paint))))))
         (root (ecss-subject-create :states '("hover")))
         (child (ecss-subject-create :parent root :classes '("title")))
         (sheet (ecss-stylesheet-create)))
    (ecss-stylesheet-add-rule sheet schemas "&:hover:has(> .title)"
                              '(test/color "root"))
    (ecss-stylesheet-add-rule sheet schemas "& > .title"
                              '(test/color "child"))
    (let ((scopes (list (ecss-scope-create root sheet))))
      (should (equal "root" (ecss-computed-style-value
                             (ecss-compute-style schemas root :scopes scopes)
                             'test/color)))
      (should (equal "child" (ecss-computed-style-value
                              (ecss-compute-style schemas child :scopes scopes)
                              'test/color))))))

(ert-deftest ecss-scope-property-independent-cascade ()
  "Every registered property uses specificity, proximity and source order."
  (let* ((properties '(test/foreground test/background test/size test/spacing))
         (schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test (mapcar (lambda (id)
                                    (list :id id :initial 0 :validator #'numberp
                                          :impacts '(paint geometry)))
                                  properties))))
         (outer (ecss-subject-create))
         (inner (ecss-subject-create :parent outer))
         (item (ecss-subject-create :parent inner :id "target"
                                    :classes '("item")))
         (a (ecss-stylesheet-create))
         (b (ecss-stylesheet-create)))
    (cl-labels ((declarations (value)
                  (cl-loop for property in properties append (list property value)))
                (verify (expected scopes)
                  (let ((style (ecss-compute-style schemas item :scopes scopes)))
                    (dolist (property properties)
                      (should (= expected (ecss-computed-style-value style property)))))))
      (ecss-stylesheet-add-rule a schemas ".item" (declarations 1))
      (ecss-stylesheet-add-rule b schemas ".item" (declarations 2))
      (verify 2 (list (ecss-scope-create inner b) (ecss-scope-create outer a)))
      (ecss-stylesheet-add-rule a schemas "#target" (declarations 3))
      (verify 3 (list (ecss-scope-create outer a) (ecss-scope-create inner b)))
      ;; Equal roots and specificity: later sheet wins even when its local
      ;; rule number is smaller than the earlier sheet's rule number.
      (ecss-stylesheet-add-rule b schemas "#target" (declarations 4))
      (ecss-stylesheet-add-rule a schemas "#target" (declarations 5))
      (verify 4 (list (ecss-scope-create inner a) (ecss-scope-create inner b)))
      (verify 5 (list (ecss-scope-create inner b) (ecss-scope-create inner a))))))

(ert-deftest ecss-scope-distinguishes-document-root-from-scope-root ()
  "`:root' remains document-relative while `:scope' names a mounted root."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test '((:id test/marker :initial "none"
                             :validator stringp :impacts (paint))))))
         (document (ecss-subject-create :type "document"))
         (mounted (ecss-subject-create :parent document))
         (child (ecss-subject-create :parent mounted))
         (global (ecss-stylesheet-create))
         (local (ecss-stylesheet-create)))
    (ecss-stylesheet-add-rule global schemas ":root" '(test/marker "document"))
    (ecss-stylesheet-add-rule local schemas ":root" '(test/marker "wrong"))
    (ecss-stylesheet-add-rule local schemas ":scope" '(test/marker "scope"))
    (should (equal "document"
                   (ecss-computed-style-value
                    (ecss-compute-style schemas document
                                        :stylesheet global)
                    'test/marker)))
    (let ((scope (ecss-scope-create mounted local)))
      (should (equal "scope"
                     (ecss-computed-style-value
                      (ecss-compute-style schemas mounted :scopes (list scope))
                      'test/marker)))
      (should (equal "none"
                     (ecss-computed-style-value
                      (ecss-compute-style schemas child :scopes (list scope))
                      'test/marker))))))

(ert-deftest ecss-scope-freezes-stylesheet-at-mount-time ()
  "A mounted scope is unaffected by later edits to its source stylesheet."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test '((:id test/color :initial "none" :validator stringp
                             :impacts (paint))))))
         (root (ecss-subject-create))
         (sheet (ecss-stylesheet-create)))
    (ecss-stylesheet-add-rule sheet schemas "&" '(test/color "before"))
    (let ((scope (ecss-scope-create root sheet)))
      (ecss-stylesheet-add-rule sheet schemas "&" '(test/color "after"))
      (should (equal "before"
                     (ecss-computed-style-value
                      (ecss-compute-style schemas root :scopes (list scope))
                      'test/color))))))

(ert-deftest ecss-scope-explicit-targets-preserve-slot-ownership ()
  "Noncontiguous author targets exclude child internals without changing structure."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test '((:id test/color :initial "none" :validator stringp
                             :impacts (paint))))))
         (root (ecss-subject-create))
         (child (ecss-subject-create :parent root :classes '("child")))
         (slot (ecss-subject-create :parent child :classes '("item")))
         (fallback (ecss-subject-create :parent child :classes '("item")))
         (outside (ecss-subject-create :classes '("item")))
         (parent-sheet (ecss-stylesheet-create))
         (child-sheet (ecss-stylesheet-create))
         (members (list root slot outside)))
    (ecss-stylesheet-add-rule parent-sheet schemas "&" '(test/color "root"))
    (ecss-stylesheet-add-rule parent-sheet schemas ".child > .item:first-child"
                              '(test/color "caller"))
    (ecss-stylesheet-add-rule parent-sheet schemas ".item:last-child"
                              '(test/color "leak"))
    (ecss-stylesheet-add-rule child-sheet schemas ".item"
                              '(test/color "child"))
    (let* ((parent-scope (ecss-scope-create root parent-sheet :subjects members))
           (scopes (list parent-scope
                         (ecss-scope-create child child-sheet :parent parent-scope
                                            :subjects (list child fallback)))))
      ;; Caller mutation cannot transfer ownership in a mounted scope.
      (setcar (cdr members) fallback)
      (cl-mapc
       (lambda (subject expected)
         (should (equal expected
                        (ecss-computed-style-value
                         (ecss-compute-style schemas subject :scopes scopes)
                         'test/color))))
       (list root slot fallback outside) '("root" "caller" "child" "none")))))

(ert-deftest ecss-scope-target-membership-does-not-block-inheritance ()
  "Excluded nodes inherit computed values but receive no scoped declarations."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test '((:id test/color :initial "none" :inherits t
                             :validator stringp :impacts (paint))))))
         (root (ecss-subject-create))
         (child (ecss-subject-create :parent root))
         (sheet (ecss-stylesheet-create)))
    (ecss-stylesheet-add-rule sheet schemas "&" '(test/color "inherited"))
    (ecss-stylesheet-add-rule sheet schemas "*" '(test/color "leak"))
    (let* ((scopes (list (ecss-scope-create root sheet :subjects (list root))))
           (parent (ecss-compute-style schemas root :scopes scopes)))
      (should (equal "inherited"
                     (ecss-computed-style-value
                      (ecss-compute-style schemas child :scopes scopes
                                          :parent-style parent)
                      'test/color))))
    (should (equal "none"
                   (ecss-computed-style-value
                    (ecss-compute-style
                     schemas root :scopes
                     (list (ecss-scope-create root sheet :subjects nil)))
                    'test/color)))
    (should-error (ecss-scope-create root sheet :subjects [invalid])
                  :type 'wrong-type-argument)
    (should-error (ecss-scope-create root sheet :subjects '(bad . tail))
                  :type 'wrong-type-argument)))

(ert-deftest ecss-scope-resolver-cannot-mutate-mounted-declarations ()
  "Resolving mutable values preserves later computations of the same scope."
  (let* ((schemas (ecss-schema-set-compose
                   (ecss-schema-package-create
                    'test '((:id test/color :initial "none" :validator stringp
                             :impacts (paint))))))
         (root (ecss-subject-create))
         (sheet (ecss-stylesheet-create)))
    (ecss-stylesheet-add-rule sheet schemas "&" '(test/color "before"))
    (let ((scopes (list (ecss-scope-create root sheet))))
      (dotimes (_ 3)
        (let ((changed
               (ecss-compute-style
                schemas root :scopes scopes :provenance t
                :value-resolver
                (lambda (value _property _subject)
                  (aset value 0 ?B)
                  value))))
          (should (equal "Before"
                         (ecss-computed-style-value changed 'test/color)))
          (let ((value (ecss-computed-style-value changed 'test/color)))
            (aset value 1 ?X)))
        (should (equal "before"
                       (ecss-computed-style-value
                        (ecss-compute-style schemas root :scopes scopes)
                        'test/color)))))))

(provide 'ecss-scope-tests)
;;; ecss-scope-tests.el ends here
