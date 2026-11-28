;;; etaf-ui-sheet.el --- Scrollable sheet of cells with Ebox-style borders  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Sheet shows a caller-owned grid of cells: caller-owned column widths and
;; row heights, a cursor cell and a rectangular selection, one line of text per
;; row built by `etaf-cell-line', and an in-place editor that promotes the cell
;; being edited into a real `etaf-text-input' Host.
;;
;; The Sheet owns the viewport: which rows and columns are built, where the
;; scroller sits, and which cell a pointer landed on.  It owns no cells: the
;; caller supplies the text, the widths, the heights and the callbacks, and the
;; caller's model stays authoritative.  Row heights may differ from one line,
;; so the caller declares the exceptions in a hash instead of a height per row:
;; a sheet of a million rows keeps one line per row and pays for nothing else.

;;; Code:
(require 'cl-lib)
(require 'etaf-ui-basic)
(require 'etaf-ui-cell-line)
(require 'etaf-ui-field)

(defconst etaf-ui--sheet-overscan 8
  "Rows built beyond each edge of a sheet's viewport.")

(defconst etaf-ui--sheet-cache-limit 200000
  "Cell texts a sheet keeps before dropping its cache.")

(defvar etaf-ui--sheet-caches (make-hash-table :test 'eq)
  "Cell text cache of each mounted sheet, keyed by its reference.")

(defvar etaf-ui--sheet-faces (make-hash-table :test 'equal)
  "Cached cell faces, keyed by kind, rule and palette.")

(defvar etaf-ui--sheet-stripes (make-hash-table :test 'equal)
  "Cached separators, keyed by stripe and colour.")

(defvar etaf-ui--sheet-drag nil
  "Transient state of the sheet gesture in flight.")

(defun etaf-ui--sheet-prop-value (value)
  "Return VALUE, reading it when it is a reactive source."
  (if (or (etaf-ref-p value) (etaf-computed-p value))
      (etaf-value value)
    value))

;;; Geometry

(defun etaf-ui--sheet-height (heights row)
  "Return how many lines ROW takes, from HEIGHTS."
  (1+ (or (and heights (gethash row heights)) 0)))

(defun etaf-ui--sheet-offset (heights row)
  "Return the first line of ROW, from HEIGHTS."
  (let ((line row))
    (when heights
      (maphash (lambda (other extra)
                 (when (< other row) (cl-incf line extra)))
               heights))
    line))

(defun etaf-ui--sheet-total (heights rows)
  "Return how many lines ROWS rows take, from HEIGHTS."
  (etaf-ui--sheet-offset heights rows))

(defun etaf-ui--sheet-row-at (heights rows line)
  "Return the row holding LINE of ROWS, from HEIGHTS."
  (let ((row (max 0 (min (1- rows) line))))
    (while (and (> row 0) (> (etaf-ui--sheet-offset heights row) line))
      (cl-decf row))
    (while (and (< row (1- rows))
                (<= (+ (etaf-ui--sheet-offset heights row)
                       (etaf-ui--sheet-height heights row))
                    line))
      (cl-incf row))
    row))

(defun etaf-ui--sheet-span (heights rows height start)
  "Return the built rows (FIRST . END) of ROWS shown for HEIGHT lines from START."
  (let* ((first (max 0 (min start (1- rows))))
         (end first)
         (lines 0)
         (target (+ height (* 2 etaf-ui--sheet-overscan))))
    (while (and (< end rows) (< lines target))
      (cl-incf lines (etaf-ui--sheet-height heights end))
      (cl-incf end))
    (cons first end)))

(defun etaf-ui--sheet-head-width (rows)
  "Return the row number column's content width in characters."
  (max 3 (1+ (length (number-to-string rows)))))

(defun etaf-ui--sheet-cell-px (width char-width)
  "Return the pixels column content WIDTH takes, separator included."
  (+ (* (+ (* 2 etaf-cell-line-padding) width) char-width) 1))

(defun etaf-ui--sheet-head-px (state char-width)
  "Return the pixels STATE's row number column takes, separator included."
  (+ (* (+ 2 (etaf-ui--sheet-head-width (plist-get state :rows))) char-width) 1))

(defun etaf-ui--sheet-avail (state &optional runtime)
  "Return the pixels STATE has for columns right of its row numbers."
  (let ((metrics (if runtime (etaf-display-metrics runtime) (etaf-display-metrics)))
        (viewport (if runtime (etaf-runtime-viewport runtime) (etaf-viewport))))
    (- (car viewport) (etaf-ui--sheet-head-px state (plist-get metrics :char-width)))))

(defun etaf-ui--sheet-visible-cols (state char-width avail &optional left)
  "Return the columns of STATE shown in AVAIL pixels from LEFT."
  (let* ((widths (etaf-ui--sheet-prop-value (plist-get state :widths)))
         (columns (length widths))
         (used 0)
         (col (or left 0))
         shown)
    (while (and (< col columns)
                (<= (+ used (etaf-ui--sheet-cell-px (aref widths col) char-width))
                    avail))
      (push col shown)
      (cl-incf used (etaf-ui--sheet-cell-px (aref widths col) char-width))
      (cl-incf col))
    (or (nreverse shown) (and (> columns 0) (list 0)))))

;;; Paint

(defconst etaf-ui--sheet-dark-colors
  '(:border "#4b515a" :rule "#4b515a" :selected "#2c4166" :selected-fg nil
    :head "#262a31" :muted "#7c8797" :accent "#5b9cf5")
  "Sheet colours for a dark frame, where the catalog palette is too bright.")

(defun etaf-ui--sheet-palette (&optional colors)
  "Return the colours a sheet paints with, overridden by COLORS.
The catalog palette supplies a light frame; a dark frame gets the sheet's own
dark colours, and the caller's COLORS win over either."
  (append colors
          (if (eq (etaf-theme-current-mode) 'dark)
              etaf-ui--sheet-dark-colors
            (list :border (plist-get etaf-ui--style-palette :ui-table-border)
                  :rule (plist-get etaf-ui--style-palette :ui-table-border)
                  :selected (plist-get etaf-ui--style-palette :ui-table-selected-bg)
                  :selected-fg (plist-get etaf-ui--style-palette :ui-table-selected-fg)
                  :head (plist-get etaf-ui--style-palette :ui-panel-bg)
                  :muted (plist-get etaf-ui--style-palette :ui-muted-fg)
                  :accent (plist-get etaf-ui--style-palette :ui-accent)))))

(defun etaf-ui--sheet-face (kind under palette)
  "Return the face of a cell of KIND with the row rule when UNDER."
  (let ((key (list kind under palette)))
    (or (gethash key etaf-ui--sheet-faces)
        (puthash key
                 (let ((rule (list :color (plist-get palette :rule) :position t)))
                   (append
                    (pcase kind
                      ('normal nil)
                      ('selected (append (list :background (plist-get palette :selected))
                                         (and (plist-get palette :selected-fg)
                                              (list :foreground
                                                    (plist-get palette :selected-fg)))))
                      ('cursor (list :overline (plist-get palette :accent)))
                      ('head (list :background (plist-get palette :head)
                                   :foreground (plist-get palette :muted)))
                      ('head-selected (list :background (plist-get palette :selected)
                                            :weight 'bold)))
                    (when under (list :underline rule))))
                 etaf-ui--sheet-faces))))

(defun etaf-ui--sheet-stripe (colour stripe)
  "Return the separator painted with COLOUR for STRIPE."
  (let ((key (list colour stripe)))
    (or (gethash key etaf-ui--sheet-stripes)
        (puthash key (etaf-ui--cell-line-stripe colour stripe)
                 etaf-ui--sheet-stripes))))

(defun etaf-ui--sheet-cell-text (state row col)
  "Return the text of the cell at ROW and COL in STATE, from its cache."
  (let* ((self (plist-get state :self))
         (version (etaf-ui--sheet-prop-value (plist-get state :version)))
         (entry (gethash self etaf-ui--sheet-caches)))
    (unless (and entry (equal (car entry) version))
      (setq entry (cons version (make-hash-table :test 'equal)))
      (puthash self entry etaf-ui--sheet-caches))
    (let* ((table (cdr entry))
           (key (cons row col))
           (cached (gethash key table)))
      (unless cached
        (when (> (hash-table-count table) etaf-ui--sheet-cache-limit)
          (clrhash table))
        (setq cached (or (funcall (plist-get state :cell-text) row col) ""))
        (puthash key cached table))
      cached)))

(defun etaf-ui--sheet-region (state)
  "Return STATE's selection as (TOP BOTTOM LEFT RIGHT)."
  (let* ((cursor (etaf-value (plist-get state :cursor)))
         (region-ref (plist-get state :region))
         (region (and region-ref (etaf-value region-ref))))
    (if (null region)
        (list (car cursor) (car cursor) (cdr cursor) (cdr cursor))
      (list (min (car cursor) (car region)) (max (car cursor) (car region))
            (min (cdr cursor) (cdr region)) (max (cdr cursor) (cdr region))))))

(defun etaf-ui--sheet-cells (state row line)
  "Return the cells of ROW's LINE as `etaf-cell-line' cell plists."
  (let* ((widths (etaf-ui--sheet-prop-value (plist-get state :widths)))
         (heights (plist-get state :heights))
         (palette (plist-get state :palette))
         (cursor (etaf-value (plist-get state :cursor)))
         (region (etaf-ui--sheet-region state))
         (left (etaf-value (plist-get state :left)))
         (char-width (plist-get (etaf-display-metrics) :char-width))
         (columns (etaf-ui--sheet-visible-cols
                   state char-width (etaf-ui--sheet-avail state) left))
         (under (= line (1- (etaf-ui--sheet-height heights row))))
         (blank (> line 0))
         (top-row (nth 0 region))
         (bottom-row (nth 1 region))
         (left-col (nth 2 region))
         (right-col (nth 3 region))
         (in-row (<= top-row row bottom-row))
         (head (plist-get state :row-head))
         (border (plist-get palette :border))
         (accent (plist-get palette :accent))
         (cells nil))
    (when head
      (push (list :width (etaf-ui--sheet-head-width (plist-get state :rows))
                  :text (unless blank
                          (pcase head
                            ('t (number-to-string (1+ row)))
                            (_ (funcall head row))))
                  :align 'right
                  :face (etaf-ui--sheet-face
                         (if in-row 'head-selected 'head) under palette)
                  :edge (if (eql (cdr cursor) left) accent border))
            cells))
    (dolist (col columns)
      (let ((kind (cond ((and (eql col (cdr cursor)) (eql row (car cursor))) 'cursor)
                        ((and in-row (<= left-col col right-col)) 'selected)
                        (t 'normal))))
        (push (list :width (aref widths col)
                    :text (unless blank
                            (etaf-ui--sheet-cell-text state row col))
                    :align (let ((align (plist-get state :cell-align)))
                             (if align (funcall align row col) 'left))
                    :face (let ((own (and (plist-get state :cell-face)
                                          (funcall (plist-get state :cell-face)
                                                   row col))))
                            (if own
                                (list own (etaf-ui--sheet-face kind under palette))
                              (etaf-ui--sheet-face kind under palette)))
                    :edge (if (or (eql col (cdr cursor))
                                  (eql (1+ col) (cdr cursor)))
                              accent border))
              cells)))
    (nreverse cells)))

(defun etaf-ui--sheet-line (state row line &optional part)
  "Return ROW's LINE of STATE as styled text.
PART `before' or `after' stops at the edited cell, which is a Host of its own."
  (let ((cells (etaf-ui--sheet-cells state row line))
        (editing (and (plist-get state :editing)
                      (etaf-value (plist-get state :editing))))
        (left (etaf-value (plist-get state :left)))
        (palette (plist-get state :palette)))
    (when (and editing (eql (car editing) row))
      (let* ((head (if (plist-get state :row-head) 1 0))
             (index (+ head (- (cdr editing) left)))
             (index (max 0 (min index (1- (length cells))))))
        (setq cells (pcase part
                      ('before (cl-subseq cells 0 index))
                      ('after (cl-subseq cells (1+ index)))
                      (_ cells)))))
    (etaf-cell-line cells
                    :stripe (if (display-graphic-p) 'px 'glyph)
                    :border-color (plist-get palette :border)
                    :rule t
                    :rule-color (plist-get palette :rule)
                    :leading-edge (if (and (plist-get state :row-head)
                                           (eql (cdr (etaf-value
                                                      (plist-get state :cursor)))
                                                left))
                                      (plist-get palette :accent)
                                    (plist-get palette :border)))))

(defun etaf-ui--sheet-row-text (state row)
  "Return ROW's whole text in STATE, filling its extra lines with cells."
  (let ((height (etaf-ui--sheet-height (plist-get state :heights) row))
        (lines nil))
    (dotimes (line height)
      (push (etaf-ui--sheet-line state row line) lines))
    (mapconcat #'identity (nreverse lines) "\n")))

;;; Header

(defun etaf-ui--sheet-column-name (col)
  "Return the spreadsheet name of COL."
  (let ((name "")
        (number (1+ col)))
    (while (> number 0)
      (let ((remainder (% (1- number) 26)))
        (setq name (concat (string (+ ?A remainder)) name)
              number (/ (- number remainder) 26))))
    name))

(defun etaf-ui--sheet-column-ref (state col)
  "Return the Host reference of STATE's heading for COL."
  (let ((self (plist-get state :self)))
    (intern (format "%s-header-%d" self col))))

(defun etaf-ui--sheet-header-children (state)
  "Return STATE's column header as a list of Hosts."
  (let* ((palette (plist-get state :palette))
         (header (plist-get state :header))
         (left (etaf-value (plist-get state :left)))
         (cursor (etaf-value (plist-get state :cursor)))
         (region (etaf-ui--sheet-region state))
         (char-width (plist-get (etaf-display-metrics) :char-width))
         (columns (etaf-ui--sheet-visible-cols
                   state char-width (etaf-ui--sheet-avail state) left))
         (widths (etaf-ui--sheet-prop-value (plist-get state :widths)))
         (head-width (etaf-ui--sheet-head-width (plist-get state :rows)))
         (border (plist-get palette :border))
         (accent (plist-get palette :accent))
         (head-face (etaf-ui--sheet-face 'head t palette))
         (children (list (etaf-node 'text (list :key 'leading)
                                    (list (etaf-ui--sheet-stripe border 'px)))
                         (etaf-node 'text (list :key 'corner)
                                    (list (concat (propertize
                                                   (make-string (+ 2 head-width) ?\s)
                                                   'face head-face)
                                                  (etaf-ui--sheet-stripe border 'px))))))
         (left-col (nth 2 region))
         (right-col (nth 3 region)))
    (when (null header)
      (setq children nil))
    (dolist (col (if header columns nil))
      (let* ((width (aref widths col))
             (face (etaf-ui--sheet-face
                    (if (<= left-col col right-col) 'head-selected 'head)
                    t palette))
             (name (pcase header
                     ('t (etaf-ui--sheet-column-name col))
                     (_ (funcall header col))))
             (pad (/ (max 0 (- (1+ width) (length name))) 2))
             (text (concat " " (make-string pad ?\s) name
                           (make-string (max 0 (- width pad (length name))) ?\s)
                           " ")))
        (push (etaf-node 'box (list :ref (etaf-ui--sheet-column-ref state col)
                                    :on-drag (lambda (gesture)
                                               (etaf-ui--sheet-resize-column
                                                state gesture col))
                                    :width (list 'ch (+ 2 width))
                                    :padding '((lh 0) (ch 0))
                                    :height '(lh 1) :wrap-mode 'none)
                         (list (etaf-node 'text nil
                                          (list (propertize text 'face face)))))
              children)
        (push (etaf-node 'text nil
                         (list (etaf-ui--sheet-stripe
                                (if (eql col (cdr cursor)) accent border) 'px)))
              children)))
    (nreverse children)))

;;; Rows

(defun etaf-ui--sheet-editor (state row col)
  "Return the editor Host for the cell at ROW and COL in STATE."
  (let* ((widths (etaf-ui--sheet-prop-value (plist-get state :widths)))
         (text-fn (or (plist-get state :cell-edit-text) (plist-get state :cell-text))))
    (etaf-node 'box
               (list :width (list 'ch (+ 2 (aref widths col)))
                     :padding '((lh 0) (ch 0))
                     :height '(lh 1) :wrap-mode 'none :overflow 'hidden)
               (list (etaf-node 'etaf-text-input
                                (list :ref (plist-get state :editor)
                                      :value (or (funcall text-fn row col) "")
                                      :variant 'plain :hide-label t
                                      :width 'stretch
                                      :on-submit (plist-get state :submit)
                                      :on-cancel (plist-get state :cancel))
                                nil)))))

(defun etaf-ui--sheet-row-children (state row)
  "Return ROW's children in STATE: its text, or text around the edited cell."
  (let ((editing (and (plist-get state :editing)
                      (etaf-value (plist-get state :editing)))))
    (if (and editing (eql (car editing) row))
        (list (etaf-view (text (expr (etaf-ui--sheet-line state row 0 'before))))
              (etaf-ui--sheet-editor state row (cdr editing))
              (etaf-view (text (expr (etaf-ui--sheet-line state row 0 'after)))))
      (list (etaf-view (text (expr (etaf-ui--sheet-row-text state row))))))))

;;; View

(defun etaf-ui--sheet-view (state)
  "Return the view of STATE's sheet."
  (let* ((rows (plist-get state :rows))
         (height (plist-get state :height))
         (heights (plist-get state :heights))
         (start (etaf-value (plist-get state :start)))
         (version (plist-get state :version))
         (header (plist-get state :header))
         (span (etaf-ui--sheet-span heights rows height start))
         (first (car span))
         (end (cdr span)))
    (etaf-view
     (column :ref (plist-get state :self)
             :role 'img :aria-label (plist-get state :label)
             :keys (plist-get state :keys)
             :on-direction (plist-get state :direction)
             :on-reveal (plist-get state :reveal)
             :on-scroll (plist-get state :scroll)
             :on-cell-at (plist-get state :cell-at)
       (row :ref (plist-get state :header-host)
            :height (list 'lh (if header 1 0))
            :wrap-mode 'none :overflow 'hidden
         (expr (etaf-ui--sheet-header-children state)))
       (column :ref (plist-get state :body)
               :height (list 'lh height) :overflow 'scroll
               :on-scroll (plist-get state :follow)
               :on-drag (plist-get state :drag)
         (box :key 'above
              :height (list 'lh (progn (etaf-value version)
                                       (etaf-ui--sheet-offset heights first))))
         (row :for (r (number-sequence first (1- end))) :key r
              :ref (etaf-ui--sheet-row-ref state r)
              :on-drag (plist-get state :drag)
              :height (list 'lh (progn (etaf-value version)
                                       (etaf-ui--sheet-height heights r)))
              :wrap-mode 'none :overflow 'hidden
           (expr (etaf-ui--sheet-row-children state r)))
         (box :key 'below
              :height (list 'lh (progn (etaf-value version)
                                       (- (etaf-ui--sheet-total heights rows)
                                          (etaf-ui--sheet-offset heights end))))))))))

;;; Commands

(defun etaf-ui--sheet-clamp (state cell)
  "Return CELL clamped to STATE's cells."
  (cons (max 0 (min (1- (plist-get state :rows)) (car cell)))
        (max 0 (min (1- (plist-get state :columns)) (cdr cell)))))

(defun etaf-ui--sheet-line-height-px ()
  "Return one sheet line's height in pixels."
  (or (plist-get (etaf-display-metrics) :line-height) 16))

(defun etaf-ui--sheet-reveal-now (state)
  "Scroll STATE's viewport so its cursor cell is visible."
  (when-let* ((runtime (etaf-current-runtime))
              (body (plist-get state :body))
              (cursor (etaf-value (plist-get state :cursor))))
    (let* ((heights (plist-get state :heights))
           (height (plist-get state :height))
           (top (etaf-ui--sheet-offset heights (car cursor)))
           (bottom (+ top (etaf-ui--sheet-height heights (car cursor))))
           (offset (etaf-scroll-offset runtime body)))
      (cond ((< top offset) (etaf-scroll-to runtime body top))
            ((> bottom (+ offset height))
             (etaf-scroll-to runtime body (- bottom height))))
      (let* ((left-ref (plist-get state :left))
             (char-width (plist-get (etaf-display-metrics runtime) :char-width))
             (avail (etaf-ui--sheet-avail state runtime))
             (shown (etaf-ui--sheet-visible-cols state char-width avail
                                                 (etaf-value left-ref))))
        (cond ((< (cdr cursor) (etaf-value left-ref))
               (etaf-set-value left-ref (cdr cursor)))
              ((not (memq (cdr cursor) shown))
               (let ((next (etaf-value left-ref)))
                 (while (and (< next (cdr cursor))
                             (not (memq (cdr cursor)
                                        (etaf-ui--sheet-visible-cols
                                         state char-width avail next))))
                   (cl-incf next))
                 (etaf-set-value left-ref next))))))))

(defun etaf-ui--sheet-move (state row-delta col-delta extend)
  "Move STATE's cursor by ROW-DELTA and COL-DELTA, extending when EXTEND."
  (let* ((cursor-ref (plist-get state :cursor))
         (region-ref (plist-get state :region))
         (cursor (etaf-value cursor-ref))
         (cell (etaf-ui--sheet-clamp state
                                     (cons (+ (car cursor) row-delta)
                                           (+ (cdr cursor) col-delta)))))
    (when (and extend region-ref (null (etaf-value region-ref)))
      (etaf-set-value region-ref cursor))
    (etaf-set-value cursor-ref cell)
    (when (and region-ref (not extend))
      (etaf-set-value region-ref cell))
    (etaf-ui--sheet-reveal-now state)))

(defun etaf-ui--sheet-begin-edit-now (state)
  "Begin editing STATE's cursor cell."
  (when-let* ((editing (plist-get state :editing))
              (cell (etaf-value (plist-get state :cursor))))
    (etaf-set-value editing cell)
    (etaf-text-input-begin (etaf-current-runtime) (plist-get state :editor))))

(defun etaf-ui--sheet-finish-edit (state text)
  "Finish STATE's edit with TEXT and tell its caller."
  (let ((editing (plist-get state :editing)))
    (when-let* ((cell (and editing (etaf-value editing))))
      (etaf-set-value editing nil)
      (when (plist-get state :commit)
        (funcall (plist-get state :commit) (car cell) (cdr cell) text)))))

(defun etaf-ui--sheet-cancel-edit (state text)
  "Abandon STATE's edit of TEXT."
  (when-let* ((editing (plist-get state :editing)))
    (etaf-set-value editing nil)
    (when (plist-get state :cancel-edit)
      (funcall (plist-get state :cancel-edit) text))))

;;; Pointer

(defun etaf-ui--sheet-row-ref (state row)
  "Return the Host reference of STATE's ROW."
  (let ((ref (intern (format "%s-row-%d" (plist-get state :self) row))))
    (put ref 'etaf-sheet-row row)
    ref))

(defun etaf-ui--sheet-line-at (_state y)
  "Return the row the sheet paints at Y."
  (when-let* ((runtime (etaf-current-runtime))
              (window (get-buffer-window (current-buffer) t))
              (position (posn-point (posn-at-x-y 1 y window)))
              (ref (etaf-host-ref-at
                    runtime position
                    (lambda (reference)
                      (and (symbolp reference)
                           (get reference 'etaf-sheet-row))))))
    (get ref 'etaf-sheet-row)))

(defun etaf-ui--sheet-col-at (state x)
  "Return the column STATE paints at X."
  (when-let* ((runtime (etaf-current-runtime))
              (char-width (plist-get (etaf-display-metrics runtime) :char-width))
              (avail (etaf-ui--sheet-avail state runtime))
              (widths (etaf-ui--sheet-prop-value (plist-get state :widths)))
              (columns (etaf-ui--sheet-visible-cols
                        state char-width avail (etaf-value (plist-get state :left)))))
    (let ((relative (- x (etaf-ui--sheet-head-px state char-width)))
          (used 0)
          (col nil))
      (dolist (candidate columns)
        (when (null col)
          (cl-incf used (etaf-ui--sheet-cell-px (aref widths candidate) char-width))
          (when (< relative used) (setq col candidate))))
      col)))

(defun etaf-ui--sheet-drag (state gesture)
  "Track STATE's GESTURE: select cells, or resize a row's height.
A gesture without a position comes from the keyboard: its `:delta' moves the
cursor by whole cells from wherever the cursor was when the gesture started."
  (pcase (plist-get gesture :phase)
    ('start
     (let* ((position (plist-get gesture :position))
            (x (car position))
            (y (cdr position))
            (char-width (plist-get (etaf-display-metrics) :char-width))
            (head-px (etaf-ui--sheet-head-px state char-width))
            (row-head (and position (plist-get state :row-head) (< x head-px))))
       (setq etaf-ui--sheet-drag
             (list :mode (if row-head 'row 'select)
                   :row (and row-head (etaf-ui--sheet-line-at state y))
                   :anchor (etaf-value (plist-get state :cursor))))
       (unless row-head
         (if (null position)
             ;; Keyboard drag: the cursor is already the gesture's target.
             (when-let* ((region (plist-get state :region)))
               (etaf-set-value region (etaf-value (plist-get state :cursor))))
           (when-let* ((col (etaf-ui--sheet-col-at state x))
                       (row (etaf-ui--sheet-line-at state y)))
             (etaf-set-value (plist-get state :cursor) (cons row col))
             (when-let* ((region (plist-get state :region)))
               (etaf-set-value region (cons row col))))))))
    ('move
     (let ((mode (plist-get etaf-ui--sheet-drag :mode))
           (position (plist-get gesture :position)))
       (if (eq mode 'row)
           (when-let* ((row (plist-get etaf-ui--sheet-drag :row))
                       (resize (plist-get state :resize-row)))
             (let ((lines (max 1 (min 4 (1+ (round (cdr (plist-get gesture :delta))
                                                   (etaf-ui--sheet-line-height-px)))))))
               (unless (= lines (etaf-ui--sheet-height (plist-get state :heights) row))
                 (funcall resize row lines))))
         (if (null position)
             (let* ((delta (plist-get gesture :delta))
                    (char-width (plist-get (etaf-display-metrics) :char-width))
                    (lines (round (cdr delta) (etaf-ui--sheet-line-height-px)))
                    (columns (round (car delta) char-width))
                    (anchor (or (plist-get etaf-ui--sheet-drag :anchor)
                                (etaf-value (plist-get state :cursor)))))
               (etaf-set-value (plist-get state :cursor)
                               (etaf-ui--sheet-clamp
                                state (cons (+ (car anchor) lines)
                                            (+ (cdr anchor) columns)))))
           (when-let* ((col (etaf-ui--sheet-col-at state (car position)))
                       (row (etaf-ui--sheet-line-at state (cdr position))))
             (etaf-set-value (plist-get state :cursor) (cons row col)))))))
    ('end (setq etaf-ui--sheet-drag nil))))

(defun etaf-ui--sheet-resize-column (state gesture &optional own-col)
  "Resize a column of STATE from its heading GESTURE through the caller.
OWN-COL names the heading's column for a gesture without a position; a pointer
gesture finds the column under it."
  (let ((resize (plist-get state :resize-column))
        (phase (plist-get gesture :phase))
        (position (plist-get gesture :position)))
    (when (and resize (memq phase '(start move end)))
      (let* ((char-width (plist-get (etaf-display-metrics) :char-width))
             (col (or own-col
                      (if position
                          (etaf-ui--sheet-col-at state (car position))
                        (plist-get etaf-ui--sheet-drag :col))))
             (widths (etaf-ui--sheet-prop-value (plist-get state :widths))))
        (when col
          (if (eq phase 'start)
              (setq etaf-ui--sheet-drag (list :mode 'column :col col
                                              :width (aref widths col)))
            (let* ((start-width (plist-get etaf-ui--sheet-drag :width))
                   (width (max 2 (+ (or start-width (aref widths col))
                                    (round (car (plist-get gesture :delta))
                                           char-width)))))
              (unless (= width (aref widths col))
                (funcall resize col width)))))))))

(defun etaf-ui--sheet-wheel-columns (state)
  "Scroll STATE's columns with the horizontal wheel."
  (let* ((event last-command-event)
         (delta (ignore-errors (event-line-count event)))
         (dx (and (consp delta) (car delta)))
         (left-ref (plist-get state :left))
         (left (etaf-value left-ref)))
    (when dx
      (let* ((steps (max 1 (round (abs dx) 14)))
             (direction (if (eq mouse-wheel-flip-direction t) (- dx) dx))
             (next (if (> direction 0) (+ left steps) (- left steps))))
        (etaf-set-value left-ref
                        (max 0 (min (1- (plist-get state :columns)) next)))))))

;;; Component

(defun etaf-ui--sheet-build (spec)
  "Return the view of a sheet described by SPEC."
  (let* ((state spec)
         (start (plist-get state :start))
         (move-command
          (lambda (row-delta col-delta extend)
            (lambda () (interactive)
              (etaf-ui--sheet-move state row-delta col-delta extend))))
         (edit-command (lambda () (interactive)
                         (etaf-ui--sheet-begin-edit-now state)))
         (keys (append
                (plist-get state :keys)
                (list (list "<f2>" edit-command "Edit cell")
                      (list "<return>" edit-command "Edit cell")
                      (list "S-<left>" (funcall move-command 0 -1 t) "Extend left")
                      (list "S-<right>" (funcall move-command 0 1 t) "Extend right")
                      (list "S-<up>" (funcall move-command -1 0 t) "Extend up")
                      (list "S-<down>" (funcall move-command 1 0 t) "Extend down")
                      (list "<wheel-left>"
                            (lambda () (interactive)
                              (etaf-ui--sheet-wheel-columns state))
                            "Columns left")
                      (list "<wheel-right>"
                            (lambda () (interactive)
                              (etaf-ui--sheet-wheel-columns state))
                            "Columns right")))))
    (setq state (plist-put state :palette
                           (etaf-ui--sheet-palette (plist-get state :colors))))
    (setq state (plist-put state :keys keys))
    (setq state (plist-put state :commit (plist-get state :on-commit)))
    (setq state (plist-put state :cancel-edit (plist-get state :on-edit-cancel)))
    (setq state
          (plist-put state :header-drag
                     (lambda (gesture) (etaf-ui--sheet-resize-column state gesture))))
    (setq state
          (plist-put state :direction
                     (lambda (direction)
                       (pcase direction
                         ('up (etaf-ui--sheet-move state -1 0 nil))
                         ('down (etaf-ui--sheet-move state 1 0 nil))
                         ('left (etaf-ui--sheet-move state 0 -1 nil))
                         ('right (etaf-ui--sheet-move state 0 1 nil)))
                       'handled)))
    (setq state
          (plist-put state :reveal
                     (lambda () (etaf-ui--sheet-reveal-now state))))
    (setq state
          (plist-put state :cell-at
                     (lambda (xy)
                       (let ((col (etaf-ui--sheet-col-at state (car xy)))
                             (row (etaf-ui--sheet-line-at state (cdr xy))))
                         (and col row (cons row col))))))
    (setq state
          (plist-put state :scroll
                     (lambda (lines)
                       (let ((delta (if (eq lines 'page)
                                        (plist-get state :height)
                                      lines)))
                         (when (integerp delta)
                           (etaf-scroll-by (etaf-current-runtime)
                                           (plist-get state :body) delta))))))
    (setq state
          (plist-put state :follow
                     (lambda (offset)
                       (let* ((height (plist-get state :height))
                              (span (etaf-ui--sheet-span
                                     (plist-get state :heights)
                                     (plist-get state :rows) height
                                     (etaf-value start))))
                         (when (or (< offset (car span))
                                   (> (+ offset height) (cdr span)))
                           (setf (etaf-value start)
                                 (max 0 (- offset etaf-ui--sheet-overscan))))))))
    (setq state
          (plist-put state :drag
                     (lambda (gesture) (etaf-ui--sheet-drag state gesture))))
    (setq state
          (plist-put state :submit
                     (lambda (text) (etaf-ui--sheet-finish-edit state text))))
    (setq state
          (plist-put state :cancel
                     (lambda (text) (etaf-ui--sheet-cancel-edit state text))))
    (etaf-ui--sheet-view state)))

(etaf-define-component etaf-sheet
    (&key rows columns widths heights version cell-text cell-face cell-align
          header row-head cursor region height editing cell-edit-text colors
          on-commit on-edit-cancel on-resize-column on-resize-row keys
          label ref)
  "Show a caller-owned grid of cells as a scrolling sheet.

ROWS and COLUMNS are the sheet's size.  WIDTHS is a vector of content widths
in characters, or a reactive source holding one.  CELL-TEXT is called with a
row and a column and returns the cell's one-line text; CELL-ALIGN returns
`left' (the default), `right' or `center'.  HEIGHTS is an optional eql hash
mapping rows to extra lines, for the few rows taller than one line.  VERSION
is an optional writable ref the caller bumps after changing cell text, so the
sheet asks CELL-TEXT again.

CURSOR is the writable ref of the active cell (ROW . COL) and REGION the
writable ref of the selection's other corner; without REGION the sheet selects
the cursor cell alone.  HEIGHT is the visible body in lines.  HEADER and
ROW-HEAD draw column letters and row numbers: `t' for the built-in naming, a
function of the index, or nil to leave them out.

EDITING, a writable ref, promotes the cell it names into an `etaf-text-input'
Host; ON-COMMIT receives (ROW COL TEXT) after a submit and ON-EDIT-CANCEL the
abandoned text.  A sheet edited programmatically needs a stable REF, because
`etaf-sheet-begin-edit' addresses the editor through it.  ON-RESIZE-COLUMN
receives (COL WIDTH) from a dragged column header and ON-RESIZE-ROW receives
(ROW LINES) from a dragged row number.

The sheet builds one text Host per visible row, so its cost follows the
viewport rather than the sheet.  It owns no cells, no caller data and no
formulas: every cell it paints comes from CELL-TEXT, and every change goes
back through the caller's callbacks."
  :bindings ((local (etaf-local-ref 'sheet))
             (self (or ref local))
             (start (etaf-ref 0))
             (left (etaf-ref 0))
             (body (etaf-local-ref 'sheet-body))
             (header-host (etaf-local-ref 'sheet-header))
             (editor (if ref (intern (format "%s-editor" ref))
                       (etaf-local-ref 'sheet-editor)))
             (edit-cell (or editing (etaf-ref nil :test #'equal)))
             (revision (or version (etaf-ref 0))))
  :setup
  (etaf-on-unmounted (lambda () (remhash self etaf-ui--sheet-caches)))
  :validate
  (progn
    (etaf-check-prop :rows rows (and (integerp rows) (> rows 0))
                     "a positive integer" 'etaf-sheet)
    (etaf-check-prop :columns columns (and (integerp columns) (> columns 0))
                     "a positive integer" 'etaf-sheet)
    (etaf-check-prop :widths widths
                     (or (vectorp widths) (etaf-ref-p widths) (etaf-computed-p widths))
                     "a vector of widths or a reactive source" 'etaf-sheet)
    (etaf-check-prop :height height (and (integerp height) (> height 0))
                     "a positive integer" 'etaf-sheet)
    (etaf-check-prop :cell-text cell-text (functionp cell-text)
                     "a function of row and column" 'etaf-sheet)
    (etaf-check-prop :cell-align cell-align (or (null cell-align) (functionp cell-align))
                     "a function or nil" 'etaf-sheet)
    (etaf-check-prop :cell-face cell-face (or (null cell-face) (functionp cell-face))
                     "a function or nil" 'etaf-sheet)
    (etaf-check-prop :heights heights (or (null heights) (hash-table-p heights))
                     "a hash table or nil" 'etaf-sheet)
    (etaf-check-prop :cursor cursor (etaf-ref-p cursor)
                     "a writable ref" 'etaf-sheet)
    (etaf-check-prop :region region (or (null region) (etaf-ref-p region))
                     "a writable ref or nil" 'etaf-sheet)
    (etaf-check-prop :editing editing (or (null editing) (etaf-ref-p editing))
                     "a writable ref or nil" 'etaf-sheet)
    (etaf-check-prop :on-commit on-commit (functionp on-commit)
                     "a function of row, column and text" 'etaf-sheet)
    (etaf-check-prop :header header
                     (or (null header) (eq header t) (functionp header))
                     "t, a function or nil" 'etaf-sheet)
    (etaf-check-prop :row-head row-head
                     (or (null row-head) (eq row-head t) (functionp row-head))
                     "t, a function or nil" 'etaf-sheet)
    (etaf-check-prop :keys keys (or (null keys) (listp keys))
                     "a key list or nil" 'etaf-sheet)
    (etaf-check-prop :colors colors (or (null colors) (listp colors))
                     "a colour plist or nil" 'etaf-sheet)
    (etaf-check-prop :label label (or (null label) (stringp label))
                     "a string or nil" 'etaf-sheet))
  :render
  (etaf-ui--sheet-build
   (list :self self :rows rows :columns columns
         :widths widths :heights heights :version revision
         :cell-text cell-text :cell-face cell-face :cell-align cell-align
         :cell-edit-text cell-edit-text
         :header header :row-head row-head
         :cursor cursor :region region :editing edit-cell
         :height height :editor editor :body body :header-host header-host
         :start start :left left
         :colors colors :label (or label "Sheet")
         :keys keys :on-commit on-commit :on-edit-cancel on-edit-cancel
         :resize-row on-resize-row :resize-column on-resize-column
         :on-commit on-commit)))

(defun etaf-sheet-cell-at (runtime ref x y)
  "Return the cell `(ROW . COL)' of the sheet REF in RUNTIME at X and Y.
X and Y are window pixels, as a pointer gesture reports them. The result is
nil when the position is outside the sheet's body, which is what an
application needs to tell a press on a cell from one on the chrome."
  (etaf-dispatch-event runtime ref 'cell-at (cons x y) t))

(defun etaf-sheet-begin-edit (runtime ref editing cell)
  "Begin editing CELL in the sheet REF of RUNTIME.
EDITING is the writable ref the sheet took as `:editing'; REF is the sheet's
stable `:ref'.  Return the field's reference, or nil when the sheet or its
editor is not mounted."
  (when (etaf-runtime-mounted-p runtime)
    (etaf-set-value editing cell)
    (etaf-text-input-begin runtime (intern (format "%s-editor" ref)))))

(defun etaf-sheet-reveal (runtime &optional ref)
  "Scroll the sheet REF of RUNTIME so its cursor cell is visible.
REF defaults to `etaf-sheet'."
  (etaf-dispatch-event runtime (or ref 'etaf-sheet) 'reveal))

(defun etaf-sheet-scroll (runtime &optional ref lines)
  "Scroll the sheet REF of RUNTIME by LINES, negative upwards.
REF defaults to `etaf-sheet'.  LINES defaults to one page, which is the
sheet's visible body height; scrolling keeps the cursor where it is, so an
application that pages the viewport also moves `:cursor'."
  (etaf-dispatch-event runtime (or ref 'etaf-sheet) 'scroll
                       (or lines 'page) t))

(provide 'etaf-ui-sheet)
;;; etaf-ui-sheet.el ends here
