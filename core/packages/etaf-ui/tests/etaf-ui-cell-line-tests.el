;;; etaf-ui-cell-line-tests.el --- Cell line painter acceptance  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-cell-line-test--face (line position property)
  "Return PROPERTY of LINE's face at POSITION, walking its face list."
  (let ((face (get-text-property position 'face line)))
    (cl-loop for spec in (cond ((null face) nil)
                               ((keywordp (car face)) (list face))
                               (t face))
             thereis (plist-get spec property))))

(ert-deftest etaf-ui-cell-line-fits-aligns-and-separates-cells ()
  "Cells keep their declared width, align their text and end in a separator."
  (let* ((cells (list (list :width 4 :text "ab")
                      (list :width 3 :text "1" :align 'right)
                      (list :width 3 :text "xyzzy" :align 'center)))
         (line (etaf-cell-line cells :border-color "#111111" :stripe 'glyph)))
    (should (= (length line) (etaf-cell-line-width cells)))
    (should (equal (substring-no-properties line 0 6) " ab   "))
    (should (eq (aref line 6) ?▕))
    (should (equal (substring-no-properties line 7 12) "   1 "))
    (should (eq (aref line 12) ?▕))
    (should (equal (substring-no-properties line 13 18) " xyz "))
    (should (eq (aref line 18) ?▕))))

(ert-deftest etaf-ui-cell-line-paints-ebox-stripes-and-the-row-rule ()
  "Separators are one-pixel spaces unless asked for a glyph, and carry the rule."
  (let* ((cells (list (list :width 2 :text "a" :edge "#ff0000")))
         (px (etaf-cell-line cells :border-color "#00ff00" :rule t :rule-color "#0000ff"
                             :leading-edge "#ffff00"))
         (glyph (etaf-cell-line cells :border-color "#00ff00" :stripe 'glyph)))
    (should (= (length px) 6))
    (should (equal (get-text-property 0 'display px) '(space :width (1))))
    (should (equal (etaf-ui-cell-line-test--face px 0 :background) "#ffff00"))
    (should (equal (etaf-ui-cell-line-test--face px 5 :background) "#ff0000"))
    (should (equal (etaf-ui-cell-line-test--face px 5 :underline)
                   '(:color "#0000ff" :position t)))
    (should (equal (etaf-ui-cell-line-test--face px 3 :underline)
                   '(:color "#0000ff" :position t)))
    (should (eq (aref glyph 4) ?▕))
    (should (equal (etaf-ui-cell-line-test--face glyph 4 :foreground) "#ff0000"))
    (should-not (etaf-ui-cell-line-test--face glyph 4 :underline))))

(ert-deftest etaf-ui-cell-line-rejects-cells-it-cannot-paint ()
  "Broken widths, multi-line text and unknown alignment fail loudly."
  (dolist (cells (list 'not-a-list
                       (list (list :width -1 :text "a"))
                       (list (list :width 2 :text 42))
                       (list (list :width 2 :text "a\nb"))
                       (list (list :width 2 :text "a\tb"))
                       (list (list :width 2 :text "a" :align 'middle))
                       '((:text "a"))))
    (should-error (etaf-cell-line cells :border-color "#000000")
                  :type 'error)))

(provide 'etaf-ui-cell-line-tests)
;;; etaf-ui-cell-line-tests.el ends here
