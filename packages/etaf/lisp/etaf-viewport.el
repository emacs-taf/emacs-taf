;;; etaf-viewport.el --- Nested viewport regions for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A viewport is the region a mounted subtree lays out into.  The mount itself
;; provides the Runtime's viewport (see `etaf-runtime-viewport').  A nested
;; `etaf-viewport-region' wraps its content in one Host whose committed size
;; becomes the viewport of every Component below it, so an application reads
;; one reactive value whether it fills a buffer, a window or a pane.

;; Regions publish after each Ebox flush, when committed geometry is readable.
;; The region Host carries no padding or border, so its border box is exactly
;; the space its descendants lay out into.

;; Resolution walks the Component segment ancestors of the reader rather than
;; the inherited Context: content passed through a slot is compiled at its
;; call site, so a Context value provided inside a wrapper would not reach it.

;;; Code:

(require 'cl-lib)
(require 'etaf-component)
(require 'etaf-events)
(require 'etaf-runtime)

(defvar etaf--viewport-region-cells (make-hash-table :test #'eq :weakness 'key)
  "Reactive viewport cell of each region, keyed by its Component instance.")

(defvar etaf--viewport-region-hosts (make-hash-table :test #'eq)
  "Viewport regions of each Runtime as HOST-REF -> CELL.")

(defun etaf--viewport-region-cell ()
  "Return the cell of the nearest enclosing viewport region, or nil."
  (let ((seg (let ((instance etaf--current-component-instance))
               (and (etaf--instance-p instance)
                    (etaf--instance-seg instance))))
        cell)
    (while (and seg (null cell))
      (let ((data (etaf--seg-data seg)))
        (when (etaf--instance-p data)
          (setq cell (gethash data etaf--viewport-region-cells))))
      (setq seg (etaf--seg-parent seg)))
    cell))

;;;###autoload
(defun etaf-viewport ()
  "Return the viewport of the current Component subtree as (PIXELS . ROWS).
PIXELS is the width in pixels and ROWS the height in lines.  Inside an
`etaf-viewport-region' the value is that region's committed size; elsewhere
it is the mounted Runtime's viewport.  A region reads as nil until its first
flush commits geometry.

The value is reactive: a render, effect or computed that reads it runs again
after the region or Runtime viewport changes."
  (if-let* ((cell (etaf--viewport-region-cell)))
      (etaf-value cell)
    (etaf-runtime-viewport)))

(defun etaf--viewport-region-install (ref cell)
  "Register the current Component's region Host REF as publishing CELL.
Called from `etaf-viewport-region' setup, which guarantees a mounted Runtime."
  (let ((runtime etaf--current-runtime)
        (instance etaf--current-component-instance))
    (unless (and runtime (etaf--instance-p instance))
      (error "Viewport region requires a mounted Component setup"))
    (puthash instance cell etaf--viewport-region-cells)
    (puthash ref cell
             (or (gethash runtime etaf--viewport-region-hosts)
                 (puthash runtime (make-hash-table :test #'eq)
                          etaf--viewport-region-hosts)))
    (etaf-on-unmounted
     (lambda () (etaf--viewport-region-remove runtime instance ref)))))

(defun etaf--viewport-region-remove (runtime instance ref)
  "Remove INSTANCE's viewport region REF from RUNTIME."
  (remhash instance etaf--viewport-region-cells)
  (when-let* ((table (gethash runtime etaf--viewport-region-hosts)))
    (remhash ref table)
    (when (zerop (hash-table-count table))
      (remhash runtime etaf--viewport-region-hosts))))

(defun etaf--viewport-region-refresh (buffer)
  "Publish the committed size of every viewport region in BUFFER."
  (when-let* ((runtime (etaf-runtime-for-buffer buffer))
              (table (gethash runtime etaf--viewport-region-hosts)))
    (maphash (lambda (ref cell)
               (when-let* ((size (etaf-host-ref-size runtime ref)))
                 (etaf-set-value cell size)))
             table)))

(add-hook 'ebox-after-flush-functions #'etaf--viewport-region-refresh)

(etaf-define-component etaf-viewport-region ()
  "Wrap its content in a nested viewport region.

The region fills the space its parent gives it and publishes that committed
box as the viewport of every Component below it (see `etaf-viewport').
Application content wrapped in it lays out for the region instead of the
whole mount.  Host attributes passed at the call site (`:class', `:width',
`:height' and the other Host attributes) override the region's own defaults.

Do not give a region padding or a border: its border box is the published
viewport, so inset the content inside the region instead."
  :bindings
  ((cell (etaf-ref nil :test #'equal :name 'etaf-viewport-region))
   (ref (etaf-local-ref 'viewport-region)))
  :setup
  (progn (etaf--viewport-region-install ref cell) nil)
  :view
  (column :ref ref :class "etaf-viewport-region"
          :width 'stretch :height 'stretch
          :flex-grow 1 :flex-shrink 1 :flex-basis '(lh 0) :min-height '(lh 0)
    (slot)))

;;; Fitting a layout to the canvas

;; A canvas draws its `ch' and `lh' in its own cell, which a canvas font or a
;; text scale sets apart from the frame's face.  Dividing viewport pixels by
;; the frame's cell therefore reports fewer columns than the canvas has, and
;; the page it lays out stops short of the region: the remainder collects on
;; one side and grows with the window.  These two readers answer from the
;; canvas itself, so an application never has to name the frame.

;;;###autoload
(defun etaf-canvas-cell (&optional runtime)
  "Return the cell the canvas draws as (CHAR-WIDTH . LINE-HEIGHT) pixels.
RUNTIME defaults to the canvas in the current buffer.  An unmounted canvas
answers from the frame's face, the only measurement left before a mount."
  (let ((metrics (ignore-errors (etaf-display-metrics runtime))))
    (cons (max 1 (or (plist-get metrics :char-width) (frame-char-width)))
          (max 1 (or (plist-get metrics :line-height) (frame-char-height))))))

;;;###autoload
(defun etaf-canvas-columns (&optional runtime)
  "Return how many whole cells wide RUNTIME's canvas viewport is.
A reactive read: a render that fits its layout this way reruns when the
viewport or the cell changes."
  (let* ((cell (etaf-canvas-cell runtime))
         (ahead (car cell))
         (pixels (car-safe (etaf-runtime-viewport runtime))))
    (max 1 (floor (if (and (numberp pixels) (> pixels 0)) pixels ahead)
                  ahead))))

;;;###autoload
(defun etaf-fit-columns (available preferred minimum &optional gap)
  "Return a plist fitting AVAILABLE canvas cells into columns.
Each item wants PREFERRED cells and keeps at least MINIMUM; GAP defaults to 3
cells between items.  The result is `(:across ACROSS :item ITEM :offset
OFFSET)`, where ACROSS is how many items a row holds, ITEM their width and
OFFSET the cells to leave on one side so the remainder is symmetric.

Columns are added only while every item keeps MINIMUM, so a wide canvas gains
a column instead of leaving one side blank, and a canvas narrower than one
preferred item keeps that item whole instead of shrinking it for nothing."
  (let* ((gap (or gap 3))
         (available (max minimum available))
         (across (max 1 (floor (+ available gap) (+ preferred gap))))
         (item (floor (- available (* gap (1- across))) across)))
    (while (and (> across 1) (< item minimum))
      (setq across (1- across)
            item (floor (- available (* gap (1- across))) across)))
    (list :across across
          :item (max 1 (min preferred item))
          :offset (max 0 (/ (- available
                              (* across (min preferred item))
                              (* gap (1- across)))
                           2)))))

(provide 'etaf-viewport)
;;; etaf-viewport.el ends here
