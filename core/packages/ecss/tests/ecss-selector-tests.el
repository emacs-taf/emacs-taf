;;; ecss-selector-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Geekinney
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ecss)

(defun ecss-selector-test--tree ()
  "Return a small subject tree for selector tests."
  (let* ((label (ecss-subject-create
                 :type "span" :classes '("label")
                 :attributes '(("lang" . "en-US"))))
         (button (ecss-subject-create
                  :type "button" :id "save" :classes '("primary" "action")
                  :attributes '(("data-kind" . "commit")
                                ("data-tags" . "fast safe"))
                  :states '("hover") :children (list label)))
         (cancel (ecss-subject-create
                  :type "button" :id "cancel" :classes '("action")))
         (root (ecss-subject-create
                :type "div" :classes '("app")
                :children (list button cancel))))
    (list root button cancel label)))

(ert-deftest ecss-selector-test-parser-matches-compounds-and-combinators ()
  (pcase-let ((`(,_root ,button ,cancel ,label)
               (ecss-selector-test--tree)))
    (should (ecss-selector-match-p
             "div.app > button#save.primary:hover > span.label" label))
    (should (ecss-selector-match-p "div .label" label))
    (should (ecss-selector-match-p "button + button#cancel" cancel))
    (should (ecss-selector-match-p "button ~ button#cancel" cancel))
    (should-not (ecss-selector-match-p "button#cancel" button))))

(ert-deftest ecss-selector-test-attribute-operators-and-flags ()
  (pcase-let ((`(,_root ,button ,_cancel ,label)
               (ecss-selector-test--tree)))
    (should (ecss-selector-match-p "[data-kind]" button))
    (should (ecss-selector-match-p "[data-kind=commit]" button))
    (should (ecss-selector-match-p "[data-tags~=safe]" button))
    (should (ecss-selector-match-p "[lang|=en]" label))
    (should (ecss-selector-match-p "[data-kind^=com]" button))
    (should (ecss-selector-match-p "[data-kind$=MIT i]" button))
    (should-not (ecss-selector-match-p "[data-kind$=MIT s]" button))
    (should (ecss-selector-match-p "[data-kind*=omm]" button))
    (should-not (ecss-selector-match-p "[data-kind=other]" button))))

(ert-deftest ecss-selector-test-functional-pseudos-and-specificity ()
  (pcase-let ((`(,root ,button ,_cancel ,_label)
               (ecss-selector-test--tree)))
    (should (ecss-selector-match-p "button:is(.primary, #other)" button))
    (should (ecss-selector-match-p "button:not(.disabled)" button))
    (should (ecss-selector-match-p "div:has(span.label)" root))
    (should (equal (ecss-selector-specificity
                    "button:is(.primary, #other)")
                   '(1 0 1)))
    (should (equal (ecss-selector-specificity
                    "button:where(.primary, #other)")
                   '(0 0 1)))))

(ert-deftest ecss-selector-test-structural-child-pseudos ()
  "Structural child pseudos inspect the subject's actual sibling position."
  (let* ((first (ecss-subject-create :type "span"))
         (last (ecss-subject-create :type "span"))
         (parent (ecss-subject-create :type "div"
                                      :children (list first last))))
    (should (ecss-selector-match-p "span:first-child" first))
    (should (ecss-selector-match-p "span:last-child" last))
    (should-not (ecss-selector-match-p "span:first-child" last))
    (should-not (ecss-selector-match-p "span:last-child" first))
    (should parent)))

(ert-deftest ecss-selector-test-complete-structural-pseudos ()
  "Match positional, type-relative, root, empty, and only-child selectors."
  (let* ((a (ecss-subject-create :type "row"))
         (b (ecss-subject-create :type "cell"))
         (c (ecss-subject-create :type "row"))
         (empty (ecss-subject-create :type "empty"))
         (root (ecss-subject-create :type "list"
                                    :children (list a b c empty))))
    (should (ecss-selector-match-p ":root" root))
    (should (ecss-selector-match-p "row:nth-child(2n+1)" a))
    (should (ecss-selector-match-p "row:last-of-type" c))
    (should (ecss-selector-match-p "cell:only-of-type" b))
    (should (ecss-selector-match-p ":empty" empty))
    (should-not (ecss-selector-match-p "row:first-of-type" c))))

(ert-deftest ecss-selector-test-language-and-direction-pseudos ()
  "Match :lang and :dir against subject metadata."
  (let ((subject (ecss-subject-create
                  :attributes '(("lang" . "zh-CN") ("dir" . "rtl")))))
    (should (ecss-selector-match-p ":lang(zh)" subject))
    (should (ecss-selector-match-p ":lang(zh-CN)" subject))
    (should (ecss-selector-match-p ":dir(rtl)" subject))
    (should-not (ecss-selector-match-p ":lang(en)" subject))
    (should-not (ecss-selector-match-p ":dir(ltr)" subject))))

(ert-deftest ecss-selector-test-nth-of-selector-filter ()
  "Filter sibling positions before applying CSS AN+B arithmetic."
  (let* ((first (ecss-subject-create :type "row" :classes '("item")))
         (second (ecss-subject-create :type "row"))
         (third (ecss-subject-create :type "row" :classes '("item")))
         (fourth (ecss-subject-create :type "row" :classes '("item")))
         (_root (ecss-subject-create
                 :type "list" :children (list first second third fourth))))
    (should (ecss-selector-match-p ".item:nth-child(2n of .item)" third))
    (should-not (ecss-selector-match-p ".item:nth-child(2n of .item)" first))
    (should (ecss-selector-match-p
             ":nth-last-child(odd of .item, .special)" fourth))
    (should (equal (ecss-selector-specificity
                    ":nth-child(2n of #important, .item)")
                   '(1 1 0)))
    (should-error (ecss-selector-normalize ":nth-child(what)"))
    (should-error (ecss-selector-normalize ":nth-of-type(2n of .item)"))))

(ert-deftest ecss-selector-test-inherited-language-and-direction ()
  "Language and direction metadata inherit through the subject tree."
  (let* ((root (ecss-subject-create
                :attributes '(("lang" . "zh-CN") ("dir" . "rtl"))))
         (child (ecss-subject-create :parent root))
         (english (ecss-subject-create
                   :parent child :attributes '(("lang" . "en-US")))))
    (should (ecss-selector-match-p ":lang(zh)" child))
    (should (ecss-selector-match-p ":dir(rtl)" child))
    (should-not (ecss-selector-match-p ":lang(zh)" english))
    (should (ecss-selector-match-p ":dir(rtl)" english))))

(ert-deftest ecss-selector-test-scope-alias-is-local-root ()
  "The standard :scope spelling addresses the mounted Ebox root."
  (let* ((root (ecss-subject-create))
         (child (ecss-subject-create :parent root)))
    (let ((ecss--scope-root root))
      (should (ecss-selector-match-p ":scope" root))
      (should-not (ecss-selector-match-p ":scope" child)))
    (should-not (ecss-selector-match-p ":scope" root))))

(ert-deftest ecss-selector-test-has-supports-relative-combinators ()
  (let* ((direct (ecss-subject-create :type "button" :classes '("direct")))
         (nested (ecss-subject-create :type "span" :classes '("nested")))
         (wrapper (ecss-subject-create :type "section" :children (list nested)))
         (root (ecss-subject-create
                :type "div" :children (list direct wrapper)))
         (adjacent (ecss-subject-create :type "button" :id "adjacent"))
         (later (ecss-subject-create :type "button" :id "later"))
         (_siblings (ecss-subject-create
                     :type "row" :children (list root adjacent later))))
    (should (ecss-selector-match-p "div:has(> button.direct)" root))
    (should (ecss-selector-match-p "div:has(> section .nested)" root))
    (should (ecss-selector-match-p "div:has(+ button#adjacent)" root))
    (should (ecss-selector-match-p "div:has(~ button#later)" root))
    (should-not (ecss-selector-match-p "div:has(> span.nested)" root))))

(ert-deftest ecss-selector-test-selector-lists-use-matching-branches ()
  (pcase-let ((`(,_root ,button ,_cancel ,_label)
               (ecss-selector-test--tree)))
    (let ((selector (ecss-selector-parse "#other, .primary")))
      (should (ecss-selector-match-p selector button))
      (should (equal (ecss--selector-matched-specificity
                      selector button ecss-default-subject-adapter)
                     '(0 1 0))))))

(ert-deftest ecss-selector-test-structured-tokens-use-value-equality ()
  (let ((subject (ecss-subject-create
                  :type (copy-sequence "button")
                  :classes (list (copy-sequence "primary"))
                  :states (list (copy-sequence "focus")))))
    (should (ecss-selector-match-p '(:type "button") subject))
    (should (ecss-selector-match-p '(:class "primary") subject))
    (should (ecss-selector-match-p '(:state "focus") subject))))

(ert-deftest ecss-selector-test-normalize-copies-structured-selector-data ()
  (let* ((token (copy-sequence "target"))
         (selector (list :class token))
         (normalized (ecss-selector-normalize selector)))
    (aset (cadr normalized) 0 ?X)
    (should (equal selector '(:class "target")))
    (aset token 1 ?Y)
    (should (equal normalized '(:class "Xarget")))))

(ert-deftest ecss-selector-test-subject-snapshots-mutable-fields ()
  (let* ((type (copy-sequence "button"))
         (id (copy-sequence "save"))
         (classes (list (copy-sequence "primary")))
         (attributes (list (cons "role" (copy-sequence "submit"))))
         (states (list (copy-sequence "active")))
         (subject (ecss-subject-create
                   :type type :id id :classes classes
                   :attributes attributes :states states)))
    (aset type 0 ?X)
    (aset id 0 ?X)
    (aset (car classes) 0 ?X)
    (aset (cdar attributes) 0 ?X)
    (aset (car states) 0 ?X)
    (should (equal (ecss-subject-type subject) "button"))
    (should (equal (ecss-subject-id subject) "save"))
    (should (equal (ecss-subject-classes subject) '("primary")))
    (should (equal (ecss-subject-attributes subject) '(("role" . "submit"))))
    (should (equal (ecss-subject-states subject) '("active")))))

(ert-deftest ecss-selector-test-caller-owned-subject-adapter ()
  (let* ((root (vector "panel" "root" '("app") nil nil nil nil))
         (child (vector "button" "save" '("primary")
                        '(("role" . "submit")) '("active") root nil))
         (adapter
          (ecss-subject-adapter-create
           :type (lambda (node) (aref node 0))
           :id (lambda (node) (aref node 1))
           :classes (lambda (node) (aref node 2))
           :attributes (lambda (node) (aref node 3))
           :states (lambda (node) (aref node 4))
           :parent (lambda (node) (aref node 5))
           :children (lambda (node) (aref node 6)))))
    (aset root 6 (list child))
    (should (ecss-selector-match-p
             "panel.app > button#save[role=submit]:active" child adapter))
    (should (ecss-selector-match-p
             "panel:has(button.primary)" root adapter))))

(ert-deftest ecss-selector-test-invalid-input-is-rejected ()
  (should-error (ecss-selector-parse "") :type 'ecss-invalid-selector)
  (should-error (ecss-selector-parse "div >") :type 'ecss-invalid-selector)
  (should-error (ecss-selector-parse "[name=value q]")
                :type 'ecss-invalid-selector)
  (should-error (ecss-selector-normalize '(:unknown value))
                :type 'ecss-invalid-selector))

(ert-deftest ecss-selector-test-reports-subject-local-dependencies ()
  "Selector dependency classification distinguishes tree-sensitive forms."
  (dolist (selector
           '("*" ".card" "button#save.primary[role=submit]:active"
             "button:is(.primary, [role=submit])"
             ".card:not(.disabled)" ".card, #fallback"))
    (should (ecss-selector-subject-local-p selector)))
  (dolist (selector
           '("section .card" "section > .card" ".active + .target"
             ".active ~ .target" "section:has(.card)"))
    (should-not (ecss-selector-subject-local-p selector)))
  (should-not (ecss-selector-subject-local-p '(:anchor)))
  (should-error (ecss-selector-subject-local-p '(:unknown value))
                :type 'ecss-invalid-selector))

(ert-deftest ecss-selector-test-locality-requires-stable-scope-context ()
  "Scope anchors need caller proof; structural dependencies remain nonlocal."
  (dolist (selector '("&" ":scope" "&.active" ":scope:not(.disabled)"
                      ":is(&, .active)" ":where(:scope, .active)"))
    (should-not (ecss-selector-subject-local-p selector))
    (should (ecss-selector-subject-local-p selector t))
    (should (ecss-selector-subject-local-p (ecss-selector-parse selector) t)))
  (dolist (selector '("& > .active" ":scope .active" "& + .active"
                      "&:has(.active)" ":is(&, :empty)" ":nth-child(2)"
                      ":first-child" ":last-of-type" ":root"))
    (should-not (ecss-selector-subject-local-p selector t)))
  (should-not (ecss-selector-subject-local-p '(:anchor) t))
  (should-error (ecss-selector-subject-local-p '(:unknown value) t)
                :type 'ecss-invalid-selector))

(ert-deftest ecss-selector-test-comments-escapes-and-quoted-attributes ()
  (let ((subject (ecss-subject-create
                  :type "div" :classes '("card" "a:b")
                  :attributes '(("title" . "Save now")))))
    (should (ecss-selector-match-p "div/* comment */.card" subject))
    (should (ecss-selector-match-p ".a\\:b" subject))
    (should (ecss-selector-match-p "[title=\"Save now\"]" subject))))

(ert-deftest ecss-selector-test-subject-reparenting-detaches-old-parent ()
  (let* ((child (ecss-subject-create :type "button"))
         (old-parent (ecss-subject-create
                      :type "old" :children (list child)))
         (new-parent (ecss-subject-create :type "new")))
    (ecss-subject-set-children new-parent (list child))
    (should (eq (ecss-subject-parent child) new-parent))
    (should-not (memq child (ecss-subject-children old-parent)))
    (should (memq child (ecss-subject-children new-parent)))))

(ert-deftest ecss-selector-test-subject-parent-construction-is-bidirectional ()
  (let* ((parent (ecss-subject-create :type "panel"))
         (child (ecss-subject-create :type "button" :parent parent)))
    (should (eq (ecss-subject-parent child) parent))
    (should (equal (ecss-subject-children parent) (list child)))
    (should (ecss-selector-match-p "panel:has(> button)" parent))))

(ert-deftest ecss-selector-test-nth-boundary-arithmetic ()
  "Exercise keyword, zero and negative coefficients through public matching."
  (let* ((nodes (cl-loop repeat 5 collect (ecss-subject-create :type "row")))
         (_root (ecss-subject-create :children nodes)))
    (dolist (case '(("odd" (1 3 5)) ("even" (2 4)) ("0n+2" (2))
                    ("0n" nil) ("-n+3" (1 2 3)) ("2n-1" (1 3 5))))
      (cl-loop for node in nodes for index from 1 do
               (should (eq (not (null (ecss-selector-match-p
                                      (format ":nth-child(%s)" (car case)) node)))
                           (not (null (memq index (cadr case))))))))))

(ert-deftest ecss-selector-test-tree-pseudos-are-not-local ()
  "Tree-sensitive selectors must never enter subject-only invalidation paths."
  (dolist (selector '(":only-child" ":empty" ":root" ":first-of-type"
                      ":last-of-type" ":only-of-type" ":nth-child(2n)"
                      ":nth-last-child(2)" ":nth-of-type(2)"
                      ":nth-last-of-type(2)" ":is(.a, :empty)"))
    (should-not (ecss-selector-subject-local-p selector))))

(ert-deftest ecss-selector-test-metadata-is-not-interaction-state ()
  "Unrelated state tokens must not fabricate language or direction metadata."
  (let ((subject (ecss-subject-create :states '("rtl" "zh"))))
    (should-not (ecss-selector-match-p ":dir(rtl)" subject))
    (should-not (ecss-selector-match-p ":lang(rtl)" subject))))

(provide 'ecss-selector-tests)
;;; ecss-selector-tests.el ends here
