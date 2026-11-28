;;; -*- lexical-binding: t; -*-
;;; etaf-ui-text-grid.el --- Controlled fixed-width text rows

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Display caller-owned character surfaces with one retained boundary per row.
;; With a viewport height the surface scrolls and builds only the rows near
;; the viewport: spacers stand for the rest, so mounting, scrolling and
;; replacing visible text cost the same for any number of rows.

;;; Code:
(require 'etaf-ui-basic)

(defconst etaf-ui--text-grid-overscan 8
  "Rows built beyond each edge of a scrolling text grid's viewport.")

(defun etaf-ui--text-grid-span (rows height start)
  "Return the built rows (FIRST . END) of ROWS shown in HEIGHT lines from START."
  (let* ((span (min rows (+ height (* 2 etaf-ui--text-grid-overscan))))
         (first (max 0 (min start (- rows span)))))
    (cons first (+ first span))))

(defun etaf-ui--text-grid-follow (start rows height offset)
  "Move the built rows of START when the viewport at OFFSET leaves them.
ROWS and HEIGHT describe the grid."
  (let ((span (etaf-ui--text-grid-span rows height (etaf-value start))))
    (when (or (< offset (car span)) (> (+ offset height) (cdr span)))
      (setf (etaf-value start)
            (max 0 (- offset etaf-ui--text-grid-overscan))))))

(defun etaf-ui--text-grid-line (row-text row columns)
  "Return ROW-TEXT's ROW padded to COLUMNS, rejecting text that does not fit."
  (let* ((content (funcall row-text row))
         (width (and (stringp content)
                     (not (string-match-p "[\n\r\t]" content))
                     (string-width content))))
    (etaf-check-prop :row-text content (and width (<= width columns))
                     "single-line text without tabs fitting :columns" 'etaf-text-grid)
    (if (= width columns) content
      (concat content (make-string (- columns width) ?\s)))))

(etaf-define-component etaf-text-grid
    (&key rows columns row-text row-ref (label "Text grid") height ref on-scroll)
  "Display caller-owned text in fixed-width, independently retained rows.
With HEIGHT, show HEIGHT lines that scroll and build only nearby rows."
  :bindings ((start (etaf-ref 0))
             (local (etaf-local-ref 'text-grid)))
  :validate
  (progn
    (dolist (entry (list (cons :rows rows) (cons :columns columns)))
      (etaf-check-prop (car entry) (cdr entry)
                       (and (integerp (cdr entry)) (> (cdr entry) 0))
                       "a positive integer" 'etaf-text-grid))
    (etaf-check-prop :row-text row-text (functionp row-text)
                     "a row callback" 'etaf-text-grid)
    (etaf-check-prop :row-ref row-ref (or (null row-ref) (functionp row-ref))
                     "a row callback or nil" 'etaf-text-grid)
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-text-grid)
    (etaf-check-prop :height height
                     (or (null height) (and (integerp height) (> height 0)))
                     "a positive integer or nil" 'etaf-text-grid)
    (etaf-check-prop :on-scroll on-scroll (or (null on-scroll) (functionp on-scroll))
                     "a callback or nil" 'etaf-text-grid))
  :render
  (if (null height)
      (etaf-view
       (column :class "etaf-text-grid" :ref (or ref local)
               :width (list 'ch columns) :role 'img :aria-label label
         (box :for (r (number-sequence 0 (1- rows))) :key r
              :width (list 'ch columns) :height '(lh 1) :wrap-mode 'none :overflow 'hidden
           (text :ref (and row-ref (funcall row-ref r))
                 (expr (etaf-ui--text-grid-line row-text r columns))))))
    (etaf-view
     (column :class "etaf-text-grid" :ref (or ref local)
             :width (list 'ch columns) :height (list 'lh height)
             :overflow 'scroll :role 'img :aria-label label
             :on-scroll (lambda (offset)
                          (etaf-ui--text-grid-follow start rows height offset)
                          (when on-scroll (funcall on-scroll offset)))
       (box :key 'above
            :height (list 'lh (car (etaf-ui--text-grid-span
                                    rows height (etaf-value start)))))
       (box :for (r (let ((span (etaf-ui--text-grid-span rows height (etaf-value start))))
                      (number-sequence (car span) (1- (cdr span)))))
            :key r :width (list 'ch columns) :height '(lh 1) :wrap-mode 'none :overflow 'hidden
         (text :ref (and row-ref (funcall row-ref r))
               (expr (etaf-ui--text-grid-line row-text r columns))))
       (box :key 'below
            :height (list 'lh (- rows (cdr (etaf-ui--text-grid-span
                                            rows height (etaf-value start))))))))))

(provide 'etaf-ui-text-grid)
;;; etaf-ui-text-grid.el ends here
