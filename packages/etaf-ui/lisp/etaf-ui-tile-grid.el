;;; -*- lexical-binding: t; -*-
;;; etaf-ui-tile-grid.el --- Controlled rectangular tile grid

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Coordinate callbacks project caller-owned data into independently retained
;; cells.  This component owns layout and activation, not board state or timers.

;;; Code:
(require 'etaf-ui-basic)

(defun etaf-ui--tile-projector ()
  "Capture one set of reactive coordinate callbacks for a retained grid."
  (let ((sources (mapcar (lambda (name) (cons name (etaf-prop name)))
                         '(cell-background cell-color cell-text cell-label cell-image))))
    (lambda (row column)
      (mapcar (lambda (source)
                (if-let* ((callback (etaf-value (cdr source))))
                    (funcall callback row column)
                  (pcase (car source)
                    ('cell-text " ")
                    ('cell-label (format "Cell %d,%d" row column)))))
              sources))))

(etaf-define-component etaf-ui--tile
    (&key row column cell-width cell-height project cell-ref on-cell-press on-cell-focus)
  :bindings ((local (etaf-local-ref 'tile))
             (projection (etaf-computed (lambda () (funcall project row column)) :test #'equal)))
  :view
  (box :class "etaf-tile-grid-cell"
       :ref (if cell-ref (funcall cell-ref row column) local)
       :width (list 'ch cell-width) :height (list 'lh cell-height)
       :wrap-mode 'none :overflow 'hidden :text-align 'center
       :background-color (nth 0 (etaf-value projection))
       :color (nth 1 (etaf-value projection))
       :role (if on-cell-press 'button 'cell)
       :aria-label (let ((label (nth 3 (etaf-value projection))))
                     (etaf-check-prop :cell-label label (stringp label)
                                      "a string" 'etaf-tile-grid)
                     label)
       :help-echo (nth 3 (etaf-value projection))
       :tab-index (when on-cell-press 0)
       :on-press (when on-cell-press
                   (lambda () (funcall on-cell-press row column)))
       :on-focus-enter (when on-cell-focus
                         (lambda () (funcall on-cell-focus row column)))
       (image :if (nth 4 (etaf-value projection))
         :src (nth 4 (etaf-value projection)) :columns cell-width :rows cell-height)
       (text :if (not (nth 4 (etaf-value projection)))
         (expr (let ((label (nth 2 (etaf-value projection))))
                     (etaf-check-prop :cell-text label
                                      (and (stringp label)
                                           (not (string-match-p "[\n\r]" label))
                                           (<= (string-width label) cell-width))
                                      "single-line text fitting :cell-width"
                                      'etaf-tile-grid)
                     label))))
  :styles (("&:focus"
            :background-color (etaf-theme-token :ui-button-ghost-hover-bg
                                                (etaf-theme-token :ui-bg "#FFFDF8"
                                                                  etaf-ui--state-hover-shift)))))

(etaf-define-component etaf-tile-grid
    (&key rows columns (cell-width 2) (cell-height 1) cell-background cell-color cell-text cell-label cell-image cell-ref on-cell-press on-cell-focus)
  "Render a fixed rectangular grid through zero-based coordinate callbacks."
  :bindings ((project (etaf-ui--tile-projector)))
  :validate
  (progn
    (dolist (entry (list (cons :rows rows) (cons :columns columns)))
      (etaf-check-prop (car entry) (cdr entry)
                       (and (integerp (cdr entry)) (> (cdr entry) 0))
                       "a positive integer" 'etaf-tile-grid))
    (etaf-check-prop :cell-width cell-width
                     (and (integerp cell-width) (> cell-width 0))
                     "a positive character count" 'etaf-tile-grid)
    (etaf-check-prop :cell-height cell-height
                     (and (integerp cell-height) (> cell-height 0))
                     "a positive line count" 'etaf-tile-grid)
    (dolist (entry (list (cons :cell-background cell-background)
                        (cons :cell-color cell-color)
                        (cons :cell-text cell-text) (cons :cell-label cell-label)
                        (cons :cell-image cell-image) (cons :cell-ref cell-ref)
                        (cons :on-cell-press on-cell-press)
                        (cons :on-cell-focus on-cell-focus)))
      (etaf-check-prop (car entry) (cdr entry)
                       (or (null (cdr entry)) (functionp (cdr entry)))
                       "a coordinate callback or nil" 'etaf-tile-grid)))
  :view
  (column :class "etaf-tile-grid" :role 'grid :focus-group 'grid
          :width (list 'ch (* columns cell-width))
    (row :for (r (number-sequence 0 (1- rows))) :key r :role 'row
      (etaf-ui--tile :for (c (number-sequence 0 (1- columns))) :key c
        :row r :column c :cell-width cell-width :cell-height cell-height :project project
        :cell-ref cell-ref :on-cell-press on-cell-press :on-cell-focus on-cell-focus))))

(provide 'etaf-ui-tile-grid)
;;; etaf-ui-tile-grid.el ends here
