;;; etaf-ui-data.el --- Data-aware ETAF UI Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; DataGrid and Pagination adapt ETAF Data Controller state onto basic
;; Components.  They do not duplicate Table or Button behavior.

;;; Code:

(require 'etaf-ui-table)

(defun etaf-ui--data-grid-row-selected-p (controller row row-selected-p)
  "Return whether ROW is selected in CONTROLLER or by ROW-SELECTED-P."
  (or (and row-selected-p (funcall row-selected-p row))
      (etaf-value
       (etaf-data-selected-ref
        controller (etaf-data-item-identity controller row)))))

(etaf-define-component etaf-data-grid
    (&key controller columns row-key on-row-press row-ref row-selected-p
          loading-label error-label empty-label)
  "Compose Table rows with DATA CONTROLLER state and controlled selection.

DataGrid shows idle, loading, refreshing, cancelled, error and empty states.
Accepted rows remain interactive during loading, refreshing, cancellation and
failure; status is shown above them.  Refresh uses LOADING-LABEL, defaulting
to `Refreshing...'.  Cancellation uses ERROR-LABEL or `Loading cancelled.'.
The shared Table row Components retain keyed identity and custom cell state.
ETAF owns their Host references, committed callbacks and lifetime.  COLUMNS
use Table's unique keys and optional `:cell' row-to-View functions."
  :view
  (column
   :class "etaf-data-grid etaf-table"
   :color (plist-get (etaf-ui--style-tokens :ui-fg) :ui-fg)
   (etaf-label
    :if (let ((status (etaf-value (etaf-data-status controller))))
          (or (eq status 'refreshing)
              (and (etaf-value (etaf-data-items controller))
                   (memq status '(loading error cancelled)))))
    :variant (if (memq (etaf-value (etaf-data-status controller)) '(error cancelled)) 'danger 'muted)
    :text (pcase (etaf-value (etaf-data-status controller))
            ('loading (or loading-label "Loading..."))
            ('refreshing (or loading-label "Refreshing..."))
            ('cancelled (or error-label "Loading cancelled."))
            (_ (or error-label "Unable to load data."))))
   (etaf-ui--table-header :columns columns)
   (column
    :class "etaf-table-body" :focus-group 'vertical
    (etaf-label
     :if (null (etaf-value (etaf-data-items controller)))
     :class (when (memq (etaf-value (etaf-data-status controller)) '(error cancelled))
              "etaf-data-grid-error")
     :color (when (memq (etaf-value (etaf-data-status controller)) '(error cancelled))
              (plist-get (etaf-ui--style-tokens :ui-data-grid-error-fg) :ui-data-grid-error-fg))
     :text (pcase (etaf-value (etaf-data-status controller))
             ('loading (or loading-label "Loading..."))
             ('error (or error-label "Unable to load data."))
             ('cancelled (or error-label "Loading cancelled."))
             ('idle "Not loaded.")
             (_ (or empty-label "No data."))))
    (etaf-ui--table-row
     :for (item (when (etaf-value (etaf-data-items controller))
                  (etaf-ui--table-rows
                    (etaf-value (etaf-data-items controller)) row-key)))
     :key (funcall row-key item)
     :row item :columns columns
     :row-ref row-ref :on-row-press on-row-press
     :row-selected-p (lambda (row)
                       (etaf-ui--data-grid-row-selected-p controller row row-selected-p))))
   (slot :name 'footer)))

(etaf-define-component etaf-pagination
    (&key controller previous-ref next-ref previous-label next-label
          class color bgcolor border padding aria-label)
  "Render a controlled pager whose callbacks follow its committed CONTROLLER.
PREVIOUS-LABEL and NEXT-LABEL override the complete Button captions.
Each Button captures its render's Controller; Runtime publishes that callback
together with the visible control after a successful render."
  :render
  (let ((controller-value controller))
    (let* ((theme (etaf-ui--style-tokens
                   :ui-fg :ui-bg :ui-pagination-muted-fg))
           (parent-color (or color (plist-get theme :ui-fg)))
           (parent-bgcolor (or bgcolor (plist-get theme :ui-bg)))
           (page (max 1 (or (and controller-value
                                 (etaf-value (etaf-data-page controller-value)))
                            1)))
           (page-size
            (max 1 (or (and controller-value
                            (etaf-value (etaf-data-page-size controller-value)))
                       1)))
           (total (max 0 (or (and controller-value
                                  (etaf-value (etaf-data-total controller-value)))
                             0)))
           (pages (max 1 (ceiling (/ (float total) page-size))))
           (loading-p (and controller-value
                           (not (null
                                 (memq (etaf-value (etaf-data-status controller-value))
                                       '(loading refreshing))))))
           (previous-disabled (or loading-p (<= page 1)))
           (next-disabled (or loading-p (>= page pages)))
           (first-item (if (zerop total) 0
                         (1+ (* (1- page) page-size))))
           (last-item (min total (* page page-size))))
      (etaf-node
       'flex
       (list :class (etaf-ui--class-value "etaf-pagination" nil class)
             :width 'stretch :flex-direction 'row :align-items 'center
             :flex-wrap 'wrap :justify-content 'center
             :role 'navigation :aria-label (or aria-label "Pagination")
             :color parent-color :background-color parent-bgcolor
             :box-sizing 'border-box :padding (or padding '((lh 0) (ch 1)))
             :gap '((lh 1) (px 16)))
       (list
        (etaf-node
         'column
         (list :width 'max-content
               :flex-grow 0 :flex-shrink 0 :flex-basis 'auto)
         (list
          (etaf-node
           'etaf-button
           (list :label (or previous-label "‹ Previous") :ref previous-ref
                 :aria-label "Previous page"
                 :disabled previous-disabled :padding '((lh 0) (ch 2))
                 :variant 'secondary :border border
                 :color (and (not previous-disabled) color) :bgcolor bgcolor
                 :on-press
                 (lambda () (etaf-data-previous-page controller-value)))
           nil)))
        (etaf-node
         'column
         (list :width 'max-content
               :flex-grow 0 :flex-shrink 0 :flex-basis 'auto)
         (list
          (etaf-node
           'box
           (list :class "etaf-pagination-label" :text-align 'center
                 :wrap-mode 'none :min-width 'max-content)
           (list (format "Page %d / %d" page pages)))
          (etaf-node
           'box
           (list :class "etaf-pagination-summary" :text-align 'center
                 :color (plist-get theme :ui-pagination-muted-fg)
                 :wrap-mode 'none :min-width 'max-content)
           (list (format "%d–%d of %d" first-item last-item total)))))
        (etaf-node
         'column
         (list :width 'max-content
               :flex-grow 0 :flex-shrink 0 :flex-basis 'auto)
         (list
          (etaf-node
           'etaf-button
           (list :label (or next-label "Next ›") :ref next-ref
                 :aria-label "Next page"
                 :disabled next-disabled :padding '((lh 0) (ch 2))
                 :variant 'secondary :border border
                 :color (and (not next-disabled) color) :bgcolor bgcolor
                 :on-press
                 (lambda () (etaf-data-next-page controller-value)))
           nil)))))))
  :styles
  (("&" :width stretch)
   (".etaf-pagination-label" :font-weight bold)))



;;; Braille chart

(defun etaf-ui--braille-points (values width height min max)
  "Return the dot coordinates of VALUES in a WIDTH by HEIGHT cell area.
A value's dot column follows its index across the chart, and its dot row
follows its distance from MIN at the top to MAX at the bottom.  Both axes count
dots, because one cell holds two dot columns and four dot rows."
  (let* ((count (length values))
         (vmin (float (or min (apply #'min values))))
         (vmax (float (or max (apply #'max values))))
         (span (if (= vmax vmin) 1 (- vmax vmin)))
         (columns (1- (* 2 width)))
         (rows (1- (* 4 height))))
    (cl-loop for value in values
             for index from 0
             for x = (if (> count 1)
                         (round (/ (* index columns) (1- count)))
                       0)
             for y = (round (* (/ (- vmax value) span) rows))
             collect (cons x y))))

(defun etaf-ui--braille-line (from to)
  "Return the dot coordinates along the segment FROM TO."
  (let* ((x0 (car from))
         (y0 (cdr from))
         (x1 (car to))
         (y1 (cdr to))
         (dx (abs (- x1 x0)))
         (dy (abs (- y1 y0)))
         (sx (if (< x0 x1) 1 -1))
         (sy (if (< y0 y1) 1 -1))
         (err (- dx dy))
         (points nil))
    (catch 'done
      (while t
        (push (cons x0 y0) points)
        (when (and (= x0 x1) (= y0 y1))
          (throw 'done (nreverse points)))
        (let ((step (* 2 err)))
          (when (>= step (- dy))
            (setq err (- err dy)
                  x0 (+ x0 sx)))
          (when (<= step dx)
            (setq err (+ err dx)
                  y0 (+ y0 sy))))))))

(defun etaf-ui--braille-bit (x y)
  "Return the braille bit of the dot at X, Y inside its cell."
  (pcase (cons (% x 2) (% y 4))
    ('(0 . 0) 1)
    ('(0 . 1) 2)
    ('(0 . 2) 4)
    ('(1 . 0) 8)
    ('(1 . 1) 16)
    ('(1 . 2) 32)
    ('(0 . 3) 64)
    ('(1 . 3) 128)
    (_ 0)))

(defun etaf-ui--braille-rows (values width height min max)
  "Return WIDTH by HEIGHT braille rows plotting VALUES.
A dot that the series does not pass through stays empty, so the rows read as a
thin line rather than a filled block."
  (let* ((points (etaf-ui--braille-points values width height min max))
         (cells (make-hash-table :test #'equal))
         (rows nil))
    (cl-loop for (from . rest) on points
             while rest
             do (dolist (dot (etaf-ui--braille-line from (car rest)))
                  (let ((cell (cons (/ (car dot) 2) (/ (cdr dot) 4))))
                    (puthash cell
                             (logior (gethash cell cells 0)
                                     (etaf-ui--braille-bit (car dot) (cdr dot)))
                             cells))))
    (dotimes (row height)
      (push (apply #'string
                   (cl-loop for column below width
                            collect (+ #x2800
                                       (gethash (cons column row) cells 0))))
            rows))
    (nreverse rows)))

(etaf-define-component etaf-braille-chart
    (&key values (width 40) (height 6) min max label ref)
  "Render VALUES as a braille chart WIDTH cells by HEIGHT cells.
Each cell carries a two by four dot grid, so the chart resolves four times as
many vertical steps as it has rows.  Dots the series does not pass through stay
empty, which is what makes the line thin.  MIN and MAX fix the scale; without
them the series' own range is used.  LABEL names the chart above it."
  :validate
  (progn
    (etaf-check-prop :values values
                     (and (listp values) (> (length values) 1)
                          (cl-every #'numberp values))
                     "a list of at least two numbers" 'etaf-braille-chart)
    (etaf-check-prop :width width (and (integerp width) (> width 0))
                     "a positive cell count" 'etaf-braille-chart)
    (etaf-check-prop :height height (and (integerp height) (> height 0))
                     "a positive row count" 'etaf-braille-chart))
  :render
  (let* ((colours (etaf-ui--style-tokens :ui-accent :ui-muted-fg))
         (mono (or (face-attribute 'fixed-pitch :family nil t) "monospace")))
    (etaf-node
     'column
     (list :class "etaf-braille-chart" :ref ref
           :width (list 'ch width) :item-gap '(lh 0))
     (append
      (when label
        (list (etaf-node 'text
                         (list :color (plist-get colours :ui-muted-fg))
                         (list label))))
      (mapcar
       (lambda (row)
         (etaf-node 'text
                    (list :font-family mono
                          :color (plist-get colours :ui-accent))
                    (list row)))
       (etaf-ui--braille-rows values width height min max))))))

(provide 'etaf-ui-data)
;;; etaf-ui-data.el ends here
