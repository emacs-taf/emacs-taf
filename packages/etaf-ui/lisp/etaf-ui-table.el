;;; etaf-ui-table.el --- Presentational Table Component for ETAF UI -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Table renders ordinary rows and columns.  It owns no loading, database,
;; pagination, or selection state; callers provide optional controlled row
;; interaction.  DataGrid adapts ETAF Data onto this Component.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-basic)

(defun etaf-ui--column-value (column key)
  "Return KEY from COLUMN, accepting a plist or alist descriptor."
  (if (and (listp column) (keywordp (car column)))
      (plist-get column key)
    (alist-get key column)))

(defun etaf-ui--table-validate-columns (columns)
  "Return COLUMNS after checking stable identities and optional cell functions."
  (unless (proper-list-p columns)
    (error "ETAF Table :columns must be a proper list"))
  (let ((seen (make-hash-table :test #'equal)))
    (cl-loop for column in columns for index from 1 do
             (let ((key (etaf-ui--column-value column :key))
                   (cell (etaf-ui--column-value column :cell))
                   (width (etaf-ui--column-value column :width)))
               (unless (and key (or (symbolp key) (stringp key) (integerp key)))
                 (error "ETAF Table column %d :key must be a non-nil symbol, integer, or string; got %S"
                        index key))
               (when (gethash key seen)
                 (error "ETAF Table column %d duplicates :key %S; use a unique key and :cell to repeat a field"
                        index key))
               (puthash key t seen)
               (when (and cell (not (functionp cell)))
                 (error "ETAF Table column %d (%S) :cell must be a function of one row; got %S"
                        index key cell))
               (when (and (consp width) (eq (car width) 'fr)
                          (not (and (proper-list-p width) (= (length width) 2)
                                    (numberp (cadr width)) (> (cadr width) 0))))
                 (error "ETAF Table column %d (%S) :width must use (fr POSITIVE-WEIGHT); got %S"
                        index key width)))))
  columns)

(defun etaf-ui--table-cell-value (row key)
  "Return KEY from ROW, accepting a plist, alist, or hash table."
  (cond
   ((hash-table-p row) (gethash key row))
   ((and (proper-list-p row)
         (zerop (% (length row) 2))
         (keywordp (car row)))
    (plist-get row key))
   ((listp row) (alist-get key row nil nil #'equal))
   (t nil)))

(defun etaf-ui--table-fit-text (value column)
  "Return VALUE fitted to COLUMN's declared character capacity."
  (let* ((value (format "%s" (or value "")))
         (width (etaf-ui--column-value column :width)))
    (if (and (integerp width) (> width 0)
             (> (string-width value) width))
        (truncate-string-to-width value width 0 nil "…")
      value)))

(defun etaf-ui--table-fixed-text-columns-p (columns)
  "Return non-nil when COLUMNS can share the compact fixed-text path."
  (and columns
       (cl-every
        (lambda (column)
          (let ((width (etaf-ui--column-value column :width)))
            (and (not (etaf-ui--column-value column :cell))
                 (integerp width) (> width 0))))
        columns)))

(defun etaf-ui--table-grid (columns cells)
  "Allocate CELLS with shared COLUMNS tracks and one character between them."
  (etaf-node
   'grid
   (list :width 'stretch
         :grid-template-columns
         (mapcar (lambda (column)
                   (let ((width (etaf-ui--column-value column :width)))
                     (if (integerp width) (list 'ch width)
                       (or width 'max-content))))
                 columns)
         :column-gap '(ch 1))
   cells))

(defun etaf-ui--table-header-cell (column)
  "Return one header for COLUMN inside its allocated Grid track."
  (etaf-node
   'box
   (list :class "etaf-table-header-cell"
         :width 'stretch :overflow 'hidden
         :wrap-mode 'none)
   (list
    (etaf-node
     'text nil
     (list
      (etaf-ui--table-fit-text
       (or (etaf-ui--column-value column :label)
           (etaf-ui--column-value column :key))
       column))))))

(defun etaf-ui--table-fixed-header-text (columns)
  "Return one fixed-width header string for COLUMNS, or nil."
  (when (etaf-ui--table-fixed-text-columns-p columns)
    (mapconcat
     (lambda (column)
       (let* ((width (etaf-ui--column-value column :width))
              (value
               (etaf-ui--table-fit-text
                (or (etaf-ui--column-value column :label)
                    (etaf-ui--column-value column :key))
                column)))
         (concat value
                 (make-string (max 0 (- width (string-width value))) ?\s))))
     columns " ")))

(defun etaf-ui--table-header (columns)
  "Return a Table header row for COLUMNS."
  (etaf-ui--table-validate-columns columns)
  (let ((theme (etaf-ui--style-tokens :ui-table-border))
        (fixed-text (etaf-ui--table-fixed-header-text columns)))
    (etaf-node
     'row
     (append
      (unless fixed-text '(:padding ((lh 0) (ch 0))))
      (list :class "etaf-table-header"
            :border-bottom-width '(px 1) :border-bottom-style 'solid
            :border-bottom-color (plist-get theme :ui-table-border)))
     (if fixed-text
         (list (etaf-node 'text nil (list fixed-text)))
       (list (etaf-ui--table-grid
              columns (mapcar #'etaf-ui--table-header-cell columns)))))))

(defun etaf-ui--table-cell (row column)
  "Return COLUMN's ordinary View cell for ROW inside its allocated track.
Custom cell functions run at this consuming position; Component output owns
its usual Context, styles, state, and lifecycle."
  (etaf-node
   'box
   (list :key (etaf-ui--column-value column :key)
         :class "etaf-table-cell"
         :width 'stretch
         :overflow 'hidden
         :wrap-mode 'none)
   (list
    (if-let* ((cell (etaf-ui--column-value column :cell)))
        (etaf-view (expr (funcall cell row)))
      (etaf-node
       'text nil
       (list
        (etaf-ui--table-fit-text
         (etaf-ui--table-cell-value
          row (etaf-ui--column-value column :key))
         column)))))))

(defun etaf-ui--table-cells (row columns)
  "Return cell Components for ROW using COLUMNS."
  (cl-loop for column in columns
           collect
           (etaf-ui--table-cell row column)))

(defun etaf-ui--table-fixed-row-text (row columns)
  "Return one fixed-width ROW string for COLUMNS, or nil when not applicable."
  (when (etaf-ui--table-fixed-text-columns-p columns)
    (mapconcat
     (lambda (column)
       (let* ((width (etaf-ui--column-value column :width))
              (value
               (etaf-ui--table-fit-text
                (etaf-ui--table-cell-value
                 row (etaf-ui--column-value column :key))
                column)))
         (concat value
                 (make-string (max 0 (- width (string-width value))) ?\s))))
     columns " ")))

(defun etaf-ui--table-row-children (row columns)
  "Return the smallest presentation-equivalent child list for ROW.
COLUMNS with fixed positive character widths use one padded Text Host.
Other cells always share a Grid parent, preserving their identity when column
widths change between fixed and fractional tracks."
  (if-let* ((text (etaf-ui--table-fixed-row-text row columns)))
      (list (etaf-node 'text nil (list text)))
    (list (etaf-ui--table-grid columns (etaf-ui--table-cells row columns)))))

(defun etaf-ui--table-rows (rows row-key)
  "Validate ROW-KEY and return the original ROWS for keyed iteration.
ETAF validates the collection, keys and uniqueness."
  (unless (functionp row-key)
    (error "ETAF Table requires a function-valued :row-key"))
  rows)

(defun etaf-ui--table-row-node
    (row columns row-ref on-row-press row-selected-p)
  "Return one canonical row Host for ROW.

Table and DataGrid compose the same retained row Component and its cells.
COLUMNS define the visible cells;
ROW-REF, ON-ROW-PRESS, and ROW-SELECTED-P define optional interaction.
Without ROW-REF the Host receives ETAF's usual instance-local reference."
  (let* ((callback on-row-press)
         (row-value row)
         (interactive-p (not (null callback)))
         (selected-p
          (progn
            (when (and row-selected-p (not (functionp row-selected-p)))
              (error "ETAF Table :row-selected-p must be a function"))
            (and row-selected-p (funcall row-selected-p row))))
         (host-ref nil)
         (theme (etaf-ui--style-tokens
                 :ui-table-border :ui-table-selected-fg
                 :ui-table-selected-bg)))
    (when interactive-p
      (unless (functionp on-row-press)
        (error "ETAF Table :on-row-press must be a function"))
      (when (and row-ref (not (functionp row-ref)))
        (error "ETAF Table :row-ref must be a function"))
      (when row-ref
        (setq host-ref (funcall row-ref row))
        (unless host-ref
          (error "ETAF Table :row-ref must return a non-nil stable ref"))))
    (etaf-node
     'row
     (append
      (unless (etaf-ui--table-fixed-text-columns-p columns) '(:padding ((lh 0) (ch 0))))
      (list :class (concat "etaf-table-row" (if selected-p " selected" ""))
            :ref host-ref :role (when interactive-p 'button)
            :tab-index (when interactive-p 0)
            :aria-selected (and interactive-p selected-p t)
            :color
            (when selected-p (plist-get theme :ui-table-selected-fg))
            :background-color
            (when selected-p (plist-get theme :ui-table-selected-bg))
            :border-bottom-width '(px 1) :border-bottom-style 'solid
            :border-bottom-color (plist-get theme :ui-table-border)
            :on-press
            (when interactive-p
              (lambda () (funcall callback row-value)))))
     (etaf-ui--table-row-children row columns))))

(etaf-define-component etaf-ui--table-header (&key columns)
  "Render one retained Table header."
  :render (etaf-ui--table-header columns)
  :styles
  (("&.etaf-table-header" :font-weight bold :padding ((lh 0) (ch 1)))
   (".etaf-table-header-cell" :font-weight bold)))

(etaf-define-component etaf-ui--table-row
    (&key row columns row-ref on-row-press row-selected-p)
  "Render one retained Table ROW."
  :render
  (etaf-ui--table-row-node
   row columns row-ref on-row-press row-selected-p)
  :styles
  (("&.etaf-table-row" :padding ((lh 0) (ch 1)))))

(etaf-define-component etaf-table
    (&key columns rows row-key row-ref on-row-press row-selected-p)
  "Render ordinary ROWS as a presentational Table.

COLUMNS contain a unique non-nil `:key', optional `:label', `:width',
and `:cell' function accepting one row and returning ordinary View content.
Integer widths are character capacities; `(fr N)' shares the remaining width
by positive weight N.
Without `:cell', the key reads a text field from the row.  Cell state belongs
in a returned Component, whose Context comes from the consuming Table.
ROW-KEY supplies stable identity.  ROW-REF is only needed for caller-owned
addresses; interactive rows otherwise receive instance-local references.
Interaction and selection are controlled optional inputs; Table never owns
application or Data Controller state.
Rows retain their application object identity. A replacement row updates
callbacks even with equal contents; its stable key preserves cell state."
  :view
  (column
   :class "etaf-table"
   :color (plist-get (etaf-ui--style-tokens :ui-fg) :ui-fg)
   (etaf-ui--table-header :columns columns)
   (column :class "etaf-table-body" :focus-group 'vertical
     (etaf-ui--table-row
      :for (item (etaf-ui--table-rows rows row-key))
      :key (funcall row-key item)
      :row item :columns columns
      :row-ref row-ref :on-row-press on-row-press
      :row-selected-p row-selected-p))))

(etaf-define-component etaf-list (&key items on-select checkbox selected)
  "Render a list of item plists with :title and optional :description."
  :validate
  (progn
    (etaf-check-prop :items items (proper-list-p items)
                     "a list of item plists" 'etaf-list)
    (let (keys)
      (dolist (item items)
        (etaf-check-prop :items item
                         (and (proper-list-p item) (zerop (% (length item) 2))
                              (plist-get item :key)
                              (not (member (plist-get item :key) keys))
                              (stringp (plist-get item :title))
                              (not (string-empty-p (plist-get item :title)))
                              (or (null (plist-get item :description))
                                  (stringp (plist-get item :description)))
                              (or (null (plist-get item :meta))
                                  (stringp (plist-get item :meta)))
                              (or (null (plist-get item :checked))
                                  (booleanp (plist-get item :checked))))
                         "items with unique :key, string :title and optional string :description, string :meta, boolean :checked"
                         'etaf-list)
        (push (plist-get item :key) keys))
      (etaf-check-prop :selected selected
                       (or (null selected) (member selected keys))
                       "nil or the :key of one item" 'etaf-list))
    (etaf-check-prop :on-select on-select (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-list)
    (etaf-check-prop :checkbox checkbox (or (null checkbox) (booleanp checkbox))
                     "a boolean or nil" 'etaf-list))
  :render
  (let* ((theme (etaf-ui--style-tokens
                 :ui-muted-fg :ui-accent
                 :ui-table-selected-bg :ui-table-selected-fg))
         (muted (plist-get theme :ui-muted-fg)))
    (etaf-view
     (flex :class "etaf-list" :flex-direction 'column
             :align-items 'stretch :width 'stretch :gap '((lh 0) (ch 0))
             :focus-group 'vertical
       (expr
        (mapcar
         (lambda (item)
           (let* ((key (plist-get item :key))
                  (current (and selected (equal key selected)))
                  (checked (plist-get item :checked))
                  (meta (plist-get item :meta)))
             (etaf-view
              (row :key key
                   :class (etaf-ui--class-value
                           "etaf-list-row"
                           (cond ((and current checked) "selected done")
                                 (current "selected")
                                 (checked "idle done")
                                 (t "idle"))
                           nil)
                   :width 'stretch :role 'button :tab-index 0
                   :aria-label (plist-get item :title)
                   :color (and current (plist-get theme :ui-table-selected-fg))
                   :background-color (and current
                                          (plist-get theme :ui-table-selected-bg))
                   :on-press (and on-select
                                  (lambda () (funcall on-select key)))
                (expr (when checkbox
                        (etaf-view
                         (text :color (cond (checked muted)
                                            (current (plist-get theme :ui-accent))
                                            (t muted))
                               (expr (concat (if checked "[x]" "[ ]") " "))))))
                (text :color (and checked muted)
                      (expr (plist-get item :title)))
                (expr (when (plist-get item :description)
                        (etaf-view
                         (text :color muted
                               (expr (concat "  " (plist-get item :description)))))))
                (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(px 0) "")
                (expr (when meta
                        (etaf-view (text :color muted (expr meta)))))))))
         items)))))
  :styles
  ((".etaf-list-row" :min-height (lh 1) :padding ((lh 0) (ch 1)))
   (".etaf-list-row.done" :text-decoration-line (line-through))))

(provide 'etaf-ui-table)
;;; etaf-ui-table.el ends here
