;;; etaf-ui-svg-tests.el --- Public SVG scene acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Exercise the scene helpers only through their public functions and one
;; retained image Host.  Implementation details are outside this contract.

;;; Code:

(require 'ert)
(require 'etaf-ui)

(ert-deftest etaf-ui-svg-elements-emit-compact-escaped-markup ()
  "Helpers format numbers, keep attribute order and escape XML input."
  (should (equal (etaf-ui-svg-rect 1 2 3 4 :rx 2 :fill "#FFF")
                 "<rect x='1' y='2' width='3' height='4' rx='2' fill='#FFF'/>"))
  (should (equal (etaf-ui-svg-rect 0.5 2.0 10.25 3)
                 "<rect x='0.5' y='2' width='10.25' height='3'/>"))
  (should (equal (etaf-ui-svg-circle 0 0 4.5)
                 "<circle cx='0' cy='0' r='4.5'/>"))
  (should (equal (etaf-ui-svg-line 0 0 10 0 :stroke "#123" :stroke-width 0.85)
                 "<line x1='0' y1='0' x2='10' y2='0' stroke='#123' stroke-width='0.85'/>"))
  (should (equal (etaf-ui-svg-path "M0 0 L1 1")
                 "<path d='M0 0 L1 1'/>"))
  (should (equal (etaf-ui-svg-group "<circle r='1'/>" :transform "translate(1,2)")
                 "<g transform='translate(1,2)'><circle r='1'/></g>"))
  (should (equal (etaf-ui-svg-text 1 2 "车 & <将>")
                 "<text x='1' y='2'>车 &amp; &lt;将&gt;</text>"))
  (should (equal (etaf-ui-svg-text 1 2 "车" :font-weight 600)
                 "<text x='1' y='2' font-weight='600'>车</text>"))
  (should (equal (etaf-ui-svg-circle 0 0 1 :fill "a'b<c" :opacity 0.65)
                 "<circle cx='0' cy='0' r='1' fill='a&apos;b&lt;c' opacity='0.65'/>"))
  (should (equal (etaf-ui-svg-circle 0 0 5 :fill "none" :stroke "#000"
                                     :stroke-width 2.3 :stroke-dasharray "3 3")
                 "<circle cx='0' cy='0' r='5' fill='none' stroke='#000' stroke-width='2.3' stroke-dasharray='3 3'/>"))
  (should (equal (etaf-ui-svg-circle 0 0 1 :fill nil :stroke "#000")
                 "<circle cx='0' cy='0' r='1' stroke='#000'/>")))

(ert-deftest etaf-ui-svg-elements-reject-invalid-geometry-and-attributes ()
  "Invalid scenes signal one readable condition before producing markup."
  (should-error (etaf-ui-svg-rect 0 0 -1 2) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-rect 0 0 1 0) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-rect "left" 0 1 2) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-circle 0 0 0) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-line 0 0 1 "x") :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-path "") :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-path nil) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-text 0 0 "two\nlines") :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-text 0 0 nil) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-group nil) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-rect 0 0 1 2 :radius 3) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-rect 0 0 1 2 :fill) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-rect 0 0 1 2 :fill "#fff" :fill "#000")
                :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-rect 0 0 1 2 :fill 3.5) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-text 0 0 "x" :font-size "big") :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-rect 0 0 1 2 :rx -1) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-circle 0 0 1 :opacity 2) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-circle 0 0 1 :opacity -1) :type 'etaf-ui-svg-error))

(ert-deftest etaf-ui-svg-image-builds-valid-documents ()
  "The descriptor carries a well-formed document sized by its arguments."
  (let* ((scene (concat (etaf-ui-svg-rect 0 0 16 10 :fill "a&b")
                        (etaf-ui-svg-text 1 1 "车 < &")))
         (descriptor (etaf-ui-svg-image scene 48 30 '(0 0 16 10)))
         (data (plist-get (cdr descriptor) :data)))
    (should (eq (car descriptor) 'image))
    (should (eq (plist-get (cdr descriptor) :type) 'svg))
    (should (string-match-p "\\`<svg xmlns='http://www.w3.org/2000/svg'" data))
    (should (string-match-p "width='48' height='30'" data))
    (should (string-match-p "viewBox='0 0 16 10'" data))
    (should-not (string-match-p "preserveAspectRatio" data))
    (when (libxml-available-p)
      (with-temp-buffer
        (insert data)
        (should (libxml-parse-xml-region (point-min) (point-max))))))
  (should (string-match-p
           "preserveAspectRatio='none'"
           (plist-get (cdr (etaf-ui-svg-image "" 10 10 '(0 0 1 1) 'none)) :data)))
  (should-error (etaf-ui-svg-image nil 10 10 '(0 0 1 1)) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-image "" 0 10 '(0 0 1 1)) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-image "" 10 10 '(0 0 1)) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-image "" 10 10 '(0 0 0 1)) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-image "" 10 10 '("a" 0 1 1)) :type 'etaf-ui-svg-error)
  (should-error (etaf-ui-svg-image "" 10 10 '(0 0 1 1) 'meet) :type 'etaf-ui-svg-error))

(ert-deftest etaf-ui-svg-image-feeds-a-retained-image-host ()
  "A composed scene keeps fixed cell metrics, focus and activation."
  (let ((buffer (generate-new-buffer " *svg host*")) pressed)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-tile-grid
             :rows 1 :columns 1 :cell-width 6 :cell-height 3
             :cell-ref (lambda (_r _c) 'svg-cell)
             :cell-label (lambda (_r _c) "Scene")
             :cell-image (lambda (_r _c)
                           (etaf-ui-svg-image
                            (concat (etaf-ui-svg-rect 0 0 16 10 :fill "#EEE")
                                    (etaf-ui-svg-circle 8 5 4 :fill "#C33"))
                            48 30 '(0 0 16 10) 'none))
             :on-cell-press (lambda (_r _c) (setq pressed t))))
           '(:viewport-width 400 :viewport-height 12))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (equal (etaf-host-ref-size runtime 'svg-cell)
                           (cons (* 6 (frame-char-width)) 3)))
            (should (equal (plist-get (etaf-runtime-host-props-for runtime 'svg-cell)
                                      :aria-label)
                           "Scene"))
            (etaf-focus runtime 'svg-cell)
            (etaf-activate runtime)
            (should pressed)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-ui-svg-tests)
;;; etaf-ui-svg-tests.el ends here
