;;; etaf-ui-cell-line.el --- Cell lines with Ebox-style borders  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A cell line is one row of a grid surface: caller-owned cells laid out at
;; caller-owned widths, separated by the same one-pixel stripes an Ebox box
;; paints for its side borders and closed by the same underline an Ebox box
;; paints on its last line.  The result is one styled string, so a row of
;; cells costs one Host instead of two Hosts per cell.
;;
;; The painter owns fitting, padding, alignment and the separators.  It owns
;; no state, no scrolling and no interaction; the grid surface decides which
;; cells are visible and what each one says.

;;; Code:
(require 'cl-lib)

(defconst etaf-cell-line-padding 1
  "Spaces each cell keeps beside its content.")

(defun etaf-cell-line-validate (cells)
  "Signal an error unless CELLS is a paintable list of cells."
  (unless (proper-list-p cells)
    (error "ETAF cell line: CELLS must be a proper list, got %S" cells))
  (let ((index 0))
    (dolist (cell cells)
      (unless (proper-list-p cell)
        (error "ETAF cell line: cell %d must be a plist, got %S" index cell))
      (let ((width (plist-get cell :width))
            (text (plist-get cell :text))
            (align (plist-get cell :align)))
        (unless (and (integerp width) (>= width 0))
          (error "ETAF cell line: cell %d :width must be a non-negative integer, got %S"
                 index width))
        (unless (or (null text) (stringp text))
          (error "ETAF cell line: cell %d :text must be a string or nil, got %S"
                 index text))
        (when (and (stringp text) (string-match-p "[\n\r\t]" text))
          (error "ETAF cell line: cell %d :text must be one line without tabs, got %S"
                 index text))
        (unless (memq align '(nil left right center))
          (error "ETAF cell line: cell %d :align must be left, right or center, got %S"
                 index align))
        (cl-incf index))))
  cells)

(defun etaf-cell-line-width (cells)
  "Return how many characters wide a line of CELLS is, separators included."
  (etaf-cell-line-validate cells)
  (+ (cl-loop for cell in cells
              sum (+ (* 2 etaf-cell-line-padding) (plist-get cell :width)))
     (length cells)))

(defun etaf-ui--cell-line-fit (text width align)
  "Return TEXT fitted into WIDTH characters, aligned per ALIGN."
  (let* ((text (or text ""))
         (text (if (> (string-width text) width)
                   (truncate-string-to-width text width)
                 text))
         (fill (max 0 (- width (string-width text)))))
    (pcase (or align 'left)
      ('right (concat (make-string fill ?\s) text))
      ('center (concat (make-string (/ fill 2) ?\s) text
                       (make-string (- fill (/ fill 2)) ?\s)))
      (_ (concat text (make-string fill ?\s))))))

(defun etaf-ui--cell-line-stripe (colour stripe)
  "Return one cell separator painted with COLOUR.
STRIPE `glyph' draws the box-rule character a text frame can paint;
anything else draws the one-pixel space a graphical frame paints."
  (if (eq stripe 'glyph)
      (propertize "▕" 'face (list :foreground colour))
    (propertize " " 'display (list 'space :width '(1))
                'face (list :background colour))))

(cl-defun etaf-cell-line (cells &key (stripe 'px) border-color rule rule-color
                                leading-edge)
  "Return the styled text of one grid line holding CELLS.
CELLS is a list of plists: `:width' is the content width in characters,
`:text' its content, `:align' `left' (default), `right' or `center',
`:face' a face or face plist merged over the cell's text, and `:edge' the
colour of the separator drawn after that cell (default BORDER-COLOR).
Each cell is padded by `etaf-cell-line-padding' spaces on both sides.

The separator after a cell is the stripe an Ebox box paints for a side
border: a one-pixel space with a background, so a selected cell's fill
reaches the stroke and no half-cell gap can appear.  STRIPE `glyph' draws
one box-rule character instead, for a frame that cannot paint pixels.
LEADING-EDGE draws a separator before the first cell in that colour, for
the near edge of the first visible column.

With RULE, the whole line carries a bottom rule in RULE-COLOR: the
underline an Ebox box paints on its last line, continuous across every
separator."
  (etaf-cell-line-validate cells)
  (let (parts)
    (when leading-edge
      (push (etaf-ui--cell-line-stripe leading-edge stripe) parts))
    (dolist (cell cells)
      (let* ((width (plist-get cell :width))
             (text (etaf-ui--cell-line-fit (plist-get cell :text) width
                                           (plist-get cell :align)))
             (face (plist-get cell :face))
             (pad (make-string etaf-cell-line-padding ?\s))
             (body (concat pad text pad)))
        (push (if face (propertize body 'face face) body) parts)
        (push (etaf-ui--cell-line-stripe (or (plist-get cell :edge) border-color)
                                         stripe)
              parts)))
    (let ((line (apply #'concat (nreverse parts))))
      (when (and rule rule-color)
        (add-face-text-property 0 (length line)
                                (list :underline (list :color rule-color
                                                       :position t))
                                t line))
      line)))

(provide 'etaf-ui-cell-line)
;;; etaf-ui-cell-line.el ends here
