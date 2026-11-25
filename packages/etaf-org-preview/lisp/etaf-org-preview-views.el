;;; etaf-org-preview-views.el --- Org document rendering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Document tree in, ETAF Views out.  Every function here is a pure function
;; of the parsed tree plus an environment plist; nothing reads a file, a
;; buffer or a frame's state behind the viewport.
;;
;; The environment carries the palette, the reading measure, the page
;; background and the callbacks the document needs: folding, link opening,
;; footnote jumps and media cards.  A color is always read through the palette,
;; so the same layout serves the face-derived appearance and the fixed ones.
;;
;; A headline is a Component.  It reads its own fold cell during render, so
;; one fold repaints one section instead of the document; children that a
;; folded parent hides are not rendered at all.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-preview-theme)
(declare-function etaf-org-preview--env "etaf-org-preview-model" (session))
(declare-function etaf-org-preview--typeset-figure "etaf-org-preview-typeset" (kind path env))
(declare-function etaf-ui-markdown-highlight-code "etaf-ui-markdown-highlight" (language text))
(declare-function etaf-ui-color-legible "etaf-ui" (color background &optional ratio))
(declare-function etaf-ui-color-contrast "etaf-ui" (first second))

(defconst etaf-org-preview--measure-gutter 2
  "Character cells kept blank on each side of the reading measure.")

(defconst etaf-org-preview--day-names
  '(("Mon" . "周一") ("Tue" . "周二") ("Wed" . "周三") ("Thu" . "周四")
    ("Fri" . "周五") ("Sat" . "周六") ("Sun" . "周日"))
  "English day abbreviations mapped to the Chinese label the preview shows.")

;;; ---------------------------------------------------------------------------
;;; Shared helpers
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--color (env key)
  "Return ENV's palette color for semantic KEY."
  (etaf-org-preview-color key (plist-get env :palette)))

(defun etaf-org-preview--scaled (factor)
  "Return FACTOR as a ratio of the body size.
Ebox reads `:font-size' against the body, so the preview's own type scale is a
set of ratios: the reader's default font decides the pixels on every platform
and no height has to be measured from the frame."
  (max 0.3 (min 4 factor)))

(defun etaf-org-preview--mono ()
  "Return the frame's fixed-pitch family, or nil."
  (let ((family (face-attribute 'fixed-pitch :family nil t)))
    (and (stringp family) (not (string-empty-p family)) family)))

(defun etaf-org-preview--spacer (&optional lines)
  "Return an empty spacer Box LINES lines tall."
  (etaf-node 'box (list :height (list 'lh (or lines 1))) nil))

(defun etaf-org-preview--rule (_env &optional spacing)
  "Return a hairline divider, separated from its neighbours by SPACING lines."
  (etaf-node 'etaf-divider
             (list :orientation 'horizontal
                   :margin-top (list 'lh (or spacing 0.5))
                   :margin-bottom (list 'lh (or spacing 0.5)))
             nil))

(defun etaf-org-preview--chip (env text ink background &optional bold)
  "Return a compact chip for TEXT in ENV.
INK and BACKGROUND are palette keys; BOLD picks the weight.  The chip keeps one
character cell of inline padding and a square edge, so a row of chips reads as
labels rather than as words with a fill."
  (etaf-node 'box
             (list :background-color (etaf-org-preview--color env background)
                   :color (etaf-org-preview--color env ink)
                   :width 'max-content
                   :flex-shrink 0
                   :padding-left '(ch 1)
                   :padding-right '(ch 1)
                   :font-size (etaf-org-preview--scaled 0.82))
             (list (etaf-node 'text (list :font-weight (if bold 'bold 'normal))
                              (list text)))))

(defun etaf-org-preview--heading-size (level)
  "Return the heading size for LEVEL, as a ratio of the body size.
The ladder is the shared Markdown one: level 1 is twice the body, level 2 one
and a half, level 3 one and a quarter, level 4 a little above the body, and
deeper levels keep the body size so a heading is never smaller than the text
it introduces."
  (etaf-org-preview--scaled (pcase level
     (1 2.00)
     (2 1.50)
     (3 1.25)
     (4 1.10)
     (_ 1.00))))

(defun etaf-org-preview--heading-ink (level)
  "Return the palette key a LEVEL heading is written in.
Levels one to four use the heading ink and a deeper level the muted ink; rank
shows in the type scale, the colour and the rule under the top two levels."
  (if (<= level 4) :heading :muted))

(defun etaf-org-preview--heading-gap (_env _level)
  "Return one body line above a heading.
Markdown separates every block with one blank line, so a heading keeps that
same rhythm instead of a margin that grows with its level."
  (list 'lh 1.0))

;;; ---------------------------------------------------------------------------
;;; Inline rendering
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--timestamp-text (stamp)
  "Return STAMP formatted for reading."
  (let* ((start (plist-get stamp :start))
         (day (cdr (assoc (or (plist-get start :day) "") etaf-org-preview--day-names)))
         (hh (plist-get start :hh))
         (mm (plist-get start :mm))
         (end-hh (plist-get start :end-hh))
         (end-mm (plist-get start :end-mm))
         (time (if hh
                   (format " %02d:%02d%s" hh (or mm 0)
                           (if end-hh (format "-%02d:%02d" end-hh (or end-mm 0)) ""))
                 ""))
         (repeater (or (plist-get stamp :repeater) "")))
    (format "%04d-%02d-%02d%s%s%s"
            (plist-get start :y) (plist-get start :m) (plist-get start :d)
            (if day (concat " " day) "") time
            (if (string-empty-p repeater) "" (concat " " repeater)))))

(defun etaf-org-preview--emphasis-props (marker)
  "Return the style props of an emphasis MARKER."
  (pcase marker
    ("*" (list :font-weight 'bold))
    ("/" (list :font-style 'italic))
    ("_" (list :text-decoration-line '(underline)))
    ("+" (list :text-decoration-line '(line-through)))
    (_ nil)))

(defun etaf-org-preview--fold-ref (env id)
  "Return the fold cell of section ID through ENV."
  (funcall (plist-get env :fold-ref) id))

(defun etaf-org-preview--act (env key &rest args)
  "Call ENV's action KEY with ARGS, when the callbacks are present."
  (when-let* ((actions (plist-get env :actions)))
    (when-let* ((function (plist-get actions key)))
      (apply function args))))

(defun etaf-org-preview--link-node (target children env)
  "Return a link View for TARGET holding CHILDREN in ENV.
A text node carries one string, so a link with formatted text is a box that
holds the inline nodes and owns the activation."
  (etaf-node 'box
             (list :color (etaf-org-preview--color env :link)
                   :text-decoration-line '(underline)
                   :on-press (lambda () (etaf-org-preview--act env :open target))
                   :role 'button
                   :tab-index 0
                   :pointer 'hand
                   :help-echo (format "%s（RET 打开）" target))
             (or children
                 (list (etaf-node 'text nil (list target))))))

(defun etaf-org-preview--inline-entries (inlines env &optional inherited)
  "Flatten INLINES into styled entries for ENV.
INHERITED is the style plist of the enclosing inline element.  An entry is
(:text STRING :props PLIST :press FUNCTION :help STRING) or (:view NODE)."
  (let (result)
    (dolist (node inlines)
      (let ((type (plist-get node :type)))
        (pcase type
          ('text
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('emphasis
           (setq result
                 (append
                  (nreverse
                   (etaf-org-preview--inline-entries
                    (plist-get node :children) env
                    (append (etaf-org-preview--emphasis-props
                             (plist-get node :marker))
                            inherited)))
                  result)))
          ('code
           (push (list :text (or (plist-get node :text) "")
                       :props (append
                               (list :background-color
                                     (etaf-org-preview--color env :panel2)
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('link
           (let* ((target (plist-get node :target))
                  (desc (plist-get node :desc))
                  (text (if desc
                            (etaf-org-preview-inline-plain-text desc)
                          target)))
             (push (list :text text
                         :props (append
                                 (list :color (etaf-org-preview--color env :link)
                                       :text-decoration-line '(underline))
                                 inherited)
                         :press (lambda ()
                                  (etaf-org-preview--act env :open target))
                         :help (format "%s（RET 打开）" target))
                   result)))
          ('timestamp
           (push (list :text (etaf-org-preview--timestamp-text node)
                       :props (append
                               (list :color (etaf-org-preview--color
                                             env (if (plist-get node :active)
                                                     :date :muted))
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('footnote-ref
           (let ((label (plist-get node :label)))
             (push (list :text (format "[%d]" (plist-get node :number))
                         :props (append
                                 (list :color (etaf-org-preview--color env :link)
                                       :font-size (etaf-org-preview--scaled 0.78))
                                 inherited)
                         :press (lambda ()
                                  (etaf-org-preview--act env :footnote label))
                         :help "跳到脚注")
                   result)))
          ('entity
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('subsup
           (push (list :text (or (plist-get node :text) "") :props inherited)
                 result))
          ('statistics-cookie
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :color (etaf-org-preview--color env :muted)
                                     :font-family (etaf-org-preview--mono)
                                     :font-size (etaf-org-preview--scaled 0.85))
                               inherited))
                 result))
          ('citation
           (push (list :text (mapconcat (lambda (key) (concat "@" key))
                                        (plist-get node :keys) " ")
                       :props (append
                               (list :color (etaf-org-preview--color env :muted)
                                     :font-family (etaf-org-preview--mono)
                                     :background-color (etaf-org-preview--color env :panel))
                               inherited))
                 result))
          ('latex-fragment
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :color (etaf-org-preview--color env :link)
                                     :font-family (etaf-org-preview--mono)
                                     :font-style 'italic)
                               inherited))
                 result))
          ('inline-src
           (push (list :text (plist-get node :text)
                       :props (append
                               (list :background-color
                                     (etaf-org-preview--color env :panel2)
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('export-snippet
           (push (list :text (or (plist-get node :text) "")
                       :props (append
                               (list :background-color
                                     (etaf-org-preview--color env :panel2)
                                     :font-family (etaf-org-preview--mono))
                               inherited))
                 result))
          ('break
           (push (list :text "\n" :props inherited) result))
          ('target
           (let ((name (or (plist-get node :name) "")))
             (if (plist-get node :radio)
                 (push (list :text (concat "◆ " name)
                             :props (append
                                     (list :color (etaf-org-preview--color env :faint)
                                           :font-family (etaf-org-preview--mono)
                                           :font-size (etaf-org-preview--scaled 0.8))
                                     inherited))
                       result)
               (push (list :text name
                           :press (lambda ()
                                    (etaf-org-preview--act env :target name))
                           :help (format "跳到目标：%s" name)
                           :props (append
                                   (list :color (etaf-org-preview--color env :link)
                                         :text-decoration-line '(underline))
                                   inherited))
                     result))))
          (_
           (when-let* ((text (plist-get node :text)))
             (push (list :text text :props inherited) result))))))
    (nreverse result)))

(defun etaf-org-preview--merge-entries (entries)
  "Merge adjacent text ENTRIES that share their style."
  (let ((result nil))
    (dolist (entry entries)
      (let ((previous (car result)))
        (if (and previous
                 (not (plist-get previous :view))
                 (not (plist-get entry :view))
                 (null (plist-get previous :press))
                 (null (plist-get entry :press))
                 (equal (plist-get previous :props) (plist-get entry :props)))
            (setcar result (plist-put previous :text
                                      (concat (plist-get previous :text)
                                              (plist-get entry :text))))
          (push entry result))))
    (nreverse result)))

(defun etaf-org-preview--entries-nodes (entries)
  "Turn merged ENTRIES into ETAF nodes."
  (mapcar
   (lambda (entry)
     (if (plist-get entry :view)
         (plist-get entry :view)
       (etaf-node 'text
                  (append (plist-get entry :props)
                          (when (plist-get entry :press)
                            (list :on-press (plist-get entry :press)
                                  :role 'button :tab-index 0 :pointer 'hand
                                  :help-echo (plist-get entry :help))))
                  (list (plist-get entry :text)))))
   entries))

(defun etaf-org-preview--inline-nodes (inlines env &optional inherited)
  "Return INLINES as ETAF text nodes for ENV."
  (etaf-org-preview--entries-nodes
   (etaf-org-preview--merge-entries
    (etaf-org-preview--inline-entries inlines env inherited))))

(defun etaf-org-preview--runs-box (inlines env &optional props)
  "Return a wrapping paragraph Box of INLINES in ENV with PROPS."
  (etaf-node 'box
             (append (list :width 'stretch :wrap-mode 'word)
                     props)
             (etaf-org-preview--inline-nodes inlines env)))

;;; ---------------------------------------------------------------------------
;;; Images
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--attr-columns (value env)
  "Return VALUE as a column count in ENV, or nil.
VALUE is an Org attribute width: an integer pixel count or a percentage of the
reading measure."
  (when-let* ((text (cond ((numberp value) (number-to-string value))
                          ((stringp value) value)))
              ((string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?%?\\'" text)))
    (let ((number (string-to-number text))
          (percent (string-suffix-p "%" text)))
      (max 4 (round (if percent
                        (* (or (plist-get env :width) 92) (/ number 100.0))
                      (/ number (max 1 (frame-char-width)))))))))

(defun etaf-org-preview--attr-rows (value)
  "Return VALUE as a row count, or nil."
  (when-let* ((text (cond ((numberp value) (number-to-string value))
                          ((stringp value) value)))
              ((string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" text)))
    (max 1 (round (/ (string-to-number text) (max 1 (frame-char-height)))))))

(defun etaf-org-preview--media-grid (media env)
  "Return the (COLUMNS . ROWS) of MEDIA in ENV.
The image keeps its aspect ratio; ATTR width and height cap the natural size."
  (let* ((pixels (and (plist-get media :width)
                      (cons (plist-get media :width) (plist-get media :height))))
         (grid (etaf-org-preview--grid-for-pixels env pixels))
         (attrs (plist-get media :attrs))
         (column-cap (etaf-org-preview--attr-columns (plist-get attrs :width) env))
         (row-cap (etaf-org-preview--attr-rows (plist-get attrs :height)))
         (scale (min 1.0
                     (if (and column-cap (< column-cap (car grid)))
                         (/ (float column-cap) (car grid))
                       1.0)
                     (if (and row-cap (< row-cap (cdr grid)))
                         (/ (float row-cap) (cdr grid))
                       1.0))))
    (if (< scale 1.0)
        (cons (max 4 (round (* (car grid) scale)))
              (max 1 (round (* (cdr grid) scale))))
      grid)))

(defun etaf-org-preview--grid-for-pixels (env pixels)
  "Return (COLUMNS . ROWS) for PIXELS in ENV's reading measure.
The image keeps its aspect ratio: its natural cell size is reduced until both
dimensions fit, first the reading measure and then the row budget."
  (let* ((max-columns (max 8 (- (or (plist-get env :width) 92) 4)))
         (max-rows (or (plist-get env :image-max-rows) 24))
         (char-width (max 1 (frame-char-width)))
         (char-height (max 1 (frame-char-height))))
    (if pixels
        (let* ((width (max 1 (car pixels)))
               (height (max 1 (cdr pixels)))
               (columns (max 4 (round (/ (* 1.0 width) char-width))))
               (rows (max 1 (round (/ (* 1.0 height) char-height))))
               (scale (min 1.0 (/ (float max-columns) columns)
                           (/ (float max-rows) rows))))
          (cons (max 4 (round (* columns scale)))
                (max 1 (round (* rows scale)))))
      (cons (min 48 max-columns) 12))))

(defun etaf-org-preview--media-grid-for-pixels (pixels max-columns)
  "Return the (COLUMNS . ROWS) grid for PIXELS capped by MAX-COLUMNS.
One scale decides both sides, so a diagram keeps its aspect ratio; rounding
each side on its own made a drawing a few percent too wide or too tall for
its own height."
  (if (or (not (consp pixels))
          (not (numberp (car pixels)))
          (not (numberp (cdr pixels))))
      (cons (min max-columns 48) 14)
    (let* ((cell-width (max 1 (or (ignore-errors (frame-char-width)) 8)))
           (cell-height (max 1 (or (ignore-errors (frame-char-height)) 16)))
           (natural-width (float (car pixels)))
           (natural-height (float (cdr pixels)))
           (fitted (min natural-width (* max-columns cell-width)))
           (fitted-height (* natural-height (/ fitted natural-width)))
           (rows (max 1 (round (/ fitted-height cell-height))))
           (scale (min 1.0 (/ (* rows cell-height) natural-height)))
           (columns (max 1 (round (/ (* natural-width scale) cell-width)))))
      (cons columns rows))))

(defun etaf-org-preview--image-card (media env)
  "Return the image card for MEDIA in ENV, or a placeholder card."
  (let* ((path (plist-get media :path))
         (grid (etaf-org-preview--media-grid media env))
         (caption (plist-get media :caption))
         (alt (plist-get media :alt)))
    (etaf-node 'column
               (list :width 'stretch :cross-align 'center :item-gap '(lh 0.5))
               (append
                (list
                 (if (and path (plist-get media :exists))
                     (etaf-node 'image
                                (list :src path
                                      :columns (car grid) :rows (cdr grid)
                                      :adapter 'auto
                                      :role 'button :tab-index 0 :pointer 'hand
                                      :on-press (lambda ()
                                                  (etaf-org-preview--act
                                                   env :open-file path))
                                      :help-echo (format "%s（RET 打开）"
                                                         (or alt
                                                             (file-name-nondirectory path))))
                                nil)
                   (etaf-node 'box
                              (list :border (list '(px 1) 'solid
                                                  (etaf-org-preview--color env :border))
                                    :background-color (etaf-org-preview--color env :panel)
                                    :padding '((lh 1) (ch 2))
                                    :on-press (lambda ()
                                                (etaf-org-preview--act
                                                 env :open (or path "")))
                                    :role 'button :tab-index 0 :pointer 'hand)
                              (list (etaf-node 'text
                                               (list :color (etaf-org-preview--color
                                                             env :muted))
                                               (list (format "图片不可用：%s"
                                                             (or path "未知路径"))))))))
                (when (and caption (not (string-empty-p caption)))
                  (list (etaf-node 'text
                                   (list :color (etaf-org-preview--color env :muted)
                                         :font-size (etaf-org-preview--scaled 0.85))
                                   (list caption))))))))

(defun etaf-org-preview--file-card (block env)
  "Return a card for a file BLOCK in ENV.
BLOCK's `:label' is what the card says; its `:path' is what activation opens."
  (let ((path (or (plist-get block :path) (plist-get block :target) ""))
        (label (or (plist-get block :label) "文件")))
    (etaf-node 'box
               (list :width 'stretch
                     :border (list '(px 1) 'solid
                                   (etaf-org-preview--color env :border))
                     :background-color (etaf-org-preview--color env :panel)
                     :padding '((lh 1) (ch 2))
                     :on-press (lambda () (etaf-org-preview--act env :open path))
                     :role 'button :tab-index 0 :pointer 'hand)
               (list (etaf-node 'text
                                (list :color (etaf-org-preview--color env :muted))
                                (list (format "%s：%s" label path)))))))

;;; ---------------------------------------------------------------------------
;;; Blocks
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--table-column-widths (floors available)
  "Return the column widths of FLOORS inside AVAILABLE cells.
A table that fits keeps its natural width, so a short table stays compact.
A wide table shrinks its columns to three cells at least, then hands the
cells left by rounding back to columns that are still below their floor."
  (let* ((count (length floors))
         (total (apply #'+ floors)))
    (if (<= total available)
        floors
      (let* ((budget (max (* 3 count) available))
             (result (cl-loop for floor in floors
                              collect (max 3 (floor (* floor (/ (float budget)
                                                               total))))))
             (leftover (- budget (apply #'+ result))))
        (while (> (apply #'+ result) budget)
          (let ((widest (cl-position (apply #'max result) result)))
            (setf (nth widest result) (1- (nth widest result)))))
        ;; Rounding down leaves cells unspent; a column that can still use
        ;; one keeps its text on fewer lines.
        (cl-loop for index from 0 below count
                 while (> leftover 0)
                 when (< (nth index result) (nth index floors))
                 do (setf (nth index result) (1+ (nth index result)))
                 and do (cl-decf leftover))
        result))))

(cl-defun etaf-org-preview--table-row (row env widths &key header)
  "Return one table row View of ROW in ENV.
WIDTHS holds the content width of each column.  HEADER fills the header
surface."
  (let* ((cell-count (length (plist-get row :cells)))
         (separator (etaf-node 'box
                               (list :width '(px 1)
                                     :flex-shrink 0
                                     :align-self 'stretch
                                     :background-color
                                     (etaf-org-preview--color
                                      env :table-border))
                               nil))
         (cells nil)
         (index 0))
    (dolist (cell (plist-get row :cells))
      (let ((width (or (nth index widths) 3)))
        (push (etaf-node 'box
                         (list :width (list 'ch (+ 2 width))
                               :flex-shrink 0
                               :padding-inline '(ch 1)
                               :wrap-mode 'word
                               :text-align (or (nth index (plist-get env :table-aligns))
                                               'left))
                         (etaf-org-preview--inline-nodes
                          (plist-get cell :inlines) env
                          (when header '(:font-weight bold))))
              cells))
      (when (< index (1- cell-count))
        (push separator cells))
      (cl-incf index))
    (etaf-node 'flex
               (list :width 'stretch :align-items 'center
                     :background-color (when header
                                         (etaf-org-preview--color env :table-header))
                     ;; A full grid, not a spreadsheet: every row is bounded
                     ;; and the first and last cell close the outer edge.
                     :border-top (when header
                                   (list '(px 1) 'solid
                                         (etaf-org-preview--color env :table-border)))
                     :border-bottom (list '(px 1) 'solid
                                          (etaf-org-preview--color
                                           env :table-border)))
               (nreverse cells))))

(defun etaf-org-preview--table-view (block env)
  "Return the table View of BLOCK in ENV.
Rows are flex lines of fixed-width cells, so a wide cell wraps inside its own
column and the table never grows past the reading measure."
  (let* ((rows (plist-get block :rows))
         (columns (max 1 (or (plist-get block :columns) 1)))
         (aligns (or (plist-get block :aligns) nil))
         (widths-cookie (or (plist-get block :widths) nil))
         (header-count (or (plist-get block :header-count) 0))
         (floors (cl-loop for column from 0 below columns
                          collect (or (nth column widths-cookie)
                                      (cl-loop for row in rows
                                               maximize (min 24
                                                             (string-width
                                                              (etaf-org-preview-inline-plain-text
                                                               (plist-get
                                                                (nth column (plist-get row :cells))
                                                                :inlines))))
                                               into width
                                               finally return (max 2 width)))))
         (env (plist-put env :table-aligns aligns))
         (separator-cells
          (ceiling (1- columns) (max 1 (frame-char-width))))
         (widths (etaf-org-preview--table-column-widths
                  floors (max 8 (- (or (plist-get env :width) 92)
                                   (+ 2 (* 2 columns) separator-cells)))))
         (row-views nil)
         (index 0))
    (dolist (row rows)
      (push (etaf-org-preview--table-row
             row env widths
             :header (< index header-count))
            row-views)
      (cl-incf index))
    (let* ((total (+ (* 2 columns) (apply #'+ widths) separator-cells))
           (table (etaf-node 'column
                             (list :width 'stretch :item-gap '(lh 0))
                             (nreverse row-views))))
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 0.5))
                 (append
                  (list (etaf-node 'box
                                   (list :width (list 'ch (1+ total))
                                         :border (list '(px 1) 'solid
                                                       (etaf-org-preview--color
                                                        env :table-border))
                                         :overflow 'hidden)
                                   (list table)))
                  (when-let* ((caption (plist-get block :caption)))
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :muted)
                                           :font-size (etaf-org-preview--scaled 0.85))
                                     (list caption))))
                  (when-let* ((tblfm (plist-get block :tblfm)))
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :faint)
                                           :font-size (etaf-org-preview--scaled 0.8))
                                     (list (format "公式未求值：%s" tblfm))))))))))

(defun etaf-org-preview--list-marker-text (item)
  "Return the text that marks ITEM in an ordered list, or nil."
  (when (plist-get item :ordered)
    (let* ((marker (plist-get item :marker))
           (suffix (if (and marker
                            (eq (aref marker (1- (length marker))) ?\)))
                       ")" "."))
           (counter (plist-get item :counter)))
      (cond
       (counter (concat counter suffix))
       (marker marker)
       (t (format "%d." (or (plist-get item :number) 1)))))))

(defun etaf-org-preview--list-marks (items)
  "Return the marker column width shared by ITEMS.
The column fits the widest number in the list, so a two-digit item still
lines up with a one-digit one.  A bullet or a checkbox needs one cell."
  (let ((width 1))
    (dolist (item items)
      (cond
       ;; The drawn check mark fills two cells in the default font, so its
       ;; column keeps one more cell of air before the text starts.
       ((plist-get item :checkbox) (setq width (max width 2)))
       ((plist-get item :term) nil)
       (t (when-let* ((text (etaf-org-preview--list-marker-text item)))
            (setq width (max width (string-width text)))))))
    width))

(defun etaf-org-preview--list-marker (item env marks)
  "Return the marker View of list ITEM in ENV, in a MARKS wide column."
  (cond
   ((plist-get item :checkbox)
    (etaf-node 'etaf-check-mark
               (list :state (pcase (plist-get item :checkbox)
                              ('on 'done)
                              ('partial 'skipped)
                              (_ 'empty))
                     :color (if (eq (plist-get item :checkbox) 'on)
                                (etaf-org-preview--color env :ok)
                              (etaf-org-preview--color env :muted)))
               nil))
   ((plist-get item :ordered)
    (etaf-node 'text
               (list :color (etaf-org-preview--color env :muted)
                     :font-family (etaf-org-preview--mono))
               (list (format (format "%%%ds" marks)
                             (etaf-org-preview--list-marker-text item)))))
   (t (etaf-node 'text
                 (list :color (etaf-org-preview--color env :muted))
                 (list "•")))))

(defun etaf-org-preview--item-views (blocks env)
  "Return BLOCKS rendered as list item content in ENV.
A nested list is laid out by the content column itself, so each level steps in
by that list's own marker column instead of by an extra fixed indent."
  (let (views)
    (dolist (block blocks)
      (when-let* ((view (etaf-org-preview--block-view block env)))
        (push view views)))
    (nreverse views)))

(defun etaf-org-preview--list-view (block env)
  "Return the list View of BLOCK in ENV.
The marker column is as wide as the widest mark plus one cell of air, and the
content column starts right after it.  A description item puts its bold term on
its own line and hangs the definition behind a quiet rule, the way a glossary
reads."
  (let* ((items (plist-get block :items))
         (marks (etaf-org-preview--list-marks items))
         (description (cl-some (lambda (item) (plist-get item :term)) items))
         (views nil))
    (dolist (item items)
      (let* ((term (plist-get item :term))
             (content (etaf-org-preview--item-views (plist-get item :blocks) env)))
        (push
         (if term
             (etaf-node 'column
                        (list :width 'stretch :item-gap '(lh 0.45)
                              :margin-bottom '(vh 0.55))
                        (list
                         (etaf-node 'box
                                    (list :width 'stretch :wrap-mode 'word)
                                    (etaf-org-preview--inline-nodes
                                     term env '(:font-weight bold)))
                         (etaf-node 'box
                                    (list :width 'stretch
                                          :border-left (list '(px 2) 'solid
                                                             (etaf-org-preview--color
                                                              env :border))
                                          :padding-left '(ch 2)
                                          :padding-top '(lh 0.10))
                                    content)))
           (etaf-node 'flex
                      (list :width 'stretch :align-items 'start
                            :margin-bottom '(vh 0.55))
                      (list
                       (etaf-node 'box
                                  (list :width (list 'ch (1+ marks))
                                        :flex-shrink 0)
                                  (list (etaf-org-preview--list-marker
                                         item env marks)))
                       (etaf-node 'column
                                  (list :width 'stretch :min-width '(ch 0)
                                        :item-gap '(lh 0.35))
                                  content))))
         views)))
    (etaf-node 'column
               (list :width 'stretch
                     :item-gap (list 'lh (if description 1.0 0.40)))
               (nreverse views))))

(defconst etaf-org-preview--code-token-colors
  '((light . ((keyword . "#cf222e") (builtin . "#0550ae") (string . "#0a3069")
              (comment . "#6e7781") (function . "#8250df") (variable . "#953800")
              (type . "#953800") (constant . "#0550ae")
              (preprocessor . "#953800") (warning . "#9a6700")))
    (dark . ((keyword . "#ff7b72") (builtin . "#79c0ff") (string . "#a5d6ff")
             (comment . "#8b949e") (function . "#d2a8ff") (variable . "#ffa657")
             (type . "#ffa657") (constant . "#79c0ff")
             (preprocessor . "#ffa657") (warning . "#e3b341"))))
  "Syntax colours a source block takes on a light and on a dark page.
They are the same pairs the shared Markdown view uses, so a code block reads
the same in either preview.")

(defun etaf-org-preview--dark-page-p (env)
  "Return non-nil when ENV paints its own dark page."
  (let ((background (plist-get env :background)))
    (if (and (stringp background)
             (string-match-p "\\`#[0-9a-fA-F]\\{3,8\\}\\'" background))
        (<= (etaf-ui-color-contrast background "#000000") 1.5)
      (eq (etaf-appearance) 'dark))))

(defun etaf-org-preview--code-token-color (props env)
  "Return the colour for code run PROPS on ENV's page.
A token with a font-lock role takes the shared syntax palette.  A token whose
mode only set its own face keeps that hue, made readable on the code surface."
  (let* ((dark (etaf-org-preview--dark-page-p env))
         (role (plist-get props :role))
         (palette (alist-get (if dark 'dark 'light)
                             etaf-org-preview--code-token-colors))
         (surface (etaf-org-preview--color env :panel)))
    (or (alist-get role palette)
        (etaf-ui-color-legible
         (or (plist-get props :color)
             (etaf-org-preview--color env :ink))
         surface))))

(defun etaf-org-preview--code-runs (language text env)
  "Return highlighted runs of TEXT as LANGUAGE for ENV, or nil.
The shared highlighter runs the language's own major mode, so the colour comes
from the same font-lock rules as the source buffer; a language with no
available mode simply keeps the block's normal ink."
  (when (and (stringp language)
             (not (string-empty-p language)))
    (when-let* ((runs (etaf-ui-markdown-highlight-code language text)))
      (mapcar
       (lambda (run)
         (let* ((props (copy-sequence (plist-get run :props)))
                (color (etaf-org-preview--code-token-color props env)))
           (list :text (plist-get run :text)
                 :props (plist-put props :color color))))
       runs))))

(defun etaf-org-preview--code-text-nodes (runs)
  "Return highlighted RUNS as text nodes."
  (mapcar (lambda (run)
            (etaf-node 'text (plist-get run :props)
                       (list (plist-get run :text))))
          runs))

(defun etaf-org-preview--code-lines (text runs)
  "Return TEXT split into lines of highlighted RUNS.
Each line is a list of `(:text STRING :props PLIST)' pieces.  RUNS may be nil,
in which case every line is one unstyled piece."
  (if (not runs)
      (mapcar (lambda (line) (list (list :text line :props nil)))
              (split-string text "\n"))
    (let ((lines nil)
          (current nil))
      (dolist (run runs)
        (let ((remaining (plist-get run :text))
              (props (plist-get run :props)))
          (while (not (string-empty-p remaining))
            (let ((newline (string-match "\n" remaining)))
              (if newline
                  (progn
                    (when (> newline 0)
                      (push (list :text (substring remaining 0 newline)
                                  :props props)
                            current))
                    (push (nreverse current) lines)
                    (setq current nil)
                    (setq remaining (substring remaining (1+ newline))))
                (push (list :text remaining :props props) current)
                (setq remaining ""))))))
      (push (nreverse current) lines)
      (nreverse lines))))

(defun etaf-org-preview--code-first-line (switches)
  "Return the first line number SWITCHES asks for, or nil.
`-n' numbers from one, `-n 20' numbers from 20; any other switch keeps the
block unnumbered."
  (let ((tokens (and switches (split-string switches "[ \t]+" t))))
    (when (member "-n" tokens)
      (let ((rest (cdr (member "-n" tokens))))
        (if (and rest (string-match-p "\\`[0-9]+\\'" (car rest)))
            (string-to-number (car rest))
          1)))))

(defun etaf-org-preview--numbered-code-lines (text first env &optional runs)
  "Return TEXT as numbered rows starting at FIRST in ENV.
RUNS, when present, paints each line with the language's own syntax colours.
The gutter keeps its width for the whole block and the code column wraps under
itself, so a long line stays aligned with the rest of the block."
  (let* ((lines (etaf-org-preview--code-lines text runs))
         (width (length (number-to-string (+ first (1- (length lines))))))
         (rows nil))
    (dolist (segments lines)
      (push
       (etaf-node 'flex
                  (list :width 'stretch :align-items 'start)
                  (list
                   (etaf-node 'box
                              (list :width (list 'ch (1+ width))
                                    :flex-shrink 0
                                    :text-align 'right
                                    :color (etaf-org-preview--color env :faint)
                                    :font-size (etaf-org-preview--scaled 0.82)
                                    :font-family (etaf-org-preview--mono))
                              (list (etaf-node 'text nil
                                               (list (number-to-string first)))))
                   (etaf-node 'box
                              (list :flex-basis '(ch 0) :flex-grow 1
                                    :padding-left '(ch 1)
                                    :wrap-mode 'char)
                              (if segments
                                  (etaf-org-preview--code-text-nodes segments)
                                (list (etaf-node 'text nil (list " ")))))))
       rows)
      (cl-incf first))
    (nreverse rows)))

(defun etaf-org-preview--code-block-view (block env &optional label)
  "Return the code card for BLOCK in ENV, labeled LABEL when given.
A block longer than the fold threshold shows its first lines and a chip to
reveal the rest."
  (let* ((text (or (plist-get block :text) ""))
         (language (or label (plist-get block :lang)))
         (body text)
         (first-line (etaf-org-preview--code-first-line
                      (plist-get block :switches)))
         (runs (etaf-org-preview--code-runs language text env))
         (header (when (and language (not (string-empty-p language)))
                   (etaf-node 'box
                              (list :width 'stretch
                                    :border-bottom (list '(px 1) 'solid
                                                         (etaf-org-preview--color env :border))
                                    :padding '((lh 0) (ch 2)))
                              (list (etaf-node 'text
                                               (list :color (etaf-org-preview--color env :muted)
                                                     :font-family (etaf-org-preview--mono)
                                                     :font-size (etaf-org-preview--scaled 0.82))
                                               (list language)))))))
    (etaf-node 'box
               (list :width 'stretch
                     :background-color (etaf-org-preview--color env :panel)
                     :border (list '(px 1) 'solid
                                   (etaf-org-preview--color env :border)))
               (append
                (when header (list header))
                (list
                 (etaf-node 'box
                            (list :width 'stretch :wrap-mode 'char
                                  :font-family (etaf-org-preview--mono)
                                  ;; Horizontal air only: vertical padding in
                                  ;; whole-line units paints an empty code line
                                  ;; above and below the block.
                                  :padding-inline '(ch 2)
                                  :padding-top (unless header '(vh 0.6))
                                  :color (etaf-org-preview--color env :ink))
                            (list
                             (if first-line
                                 (etaf-node 'column
                                            (list :width 'stretch
                                                  :item-gap '(lh 0))
                                            (etaf-org-preview--numbered-code-lines
                                             body first-line env runs))
                               (if runs
                                   (etaf-node 'box
                                              (list :width 'stretch
                                                    :wrap-mode 'char
                                                    :font-family (etaf-org-preview--mono))
                                              (etaf-org-preview--code-text-nodes runs))
                                 (etaf-node 'text nil (list body)))))))))))

(defun etaf-org-preview--reveal-chip (env label help)
  "Return a chip reading LABEL in ENV that reveals hidden content on press.
HELP explains what pressing it shows."
  (etaf-node 'box
             (list :on-press (lambda ()
                               (etaf-org-preview--act env :hidden))
                   :role 'button :tab-index 0 :pointer 'hand
                   :help-echo help)
             (list (etaf-org-preview--chip env label :muted :panel))))

(defun etaf-org-preview--drawer-view (drawer env hidden)
  "Return the View of an unknown DRAWER in ENV.
A folded drawer keeps a chip with its name; HIDDEN reveals the content, so no
drawer text is ever silently dropped."
  (let ((name (or (plist-get drawer :name) "DRAWER"))
        (text (or (plist-get drawer :text) "")))
    (if hidden
        (etaf-node 'box
                   (list :width 'stretch
                         :border-left (list '(px 2) 'solid
                                            (etaf-org-preview--color env :border))
                         :padding '((lh 0.25) (ch 2)))
                   (append
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :muted)
                                           :font-family (etaf-org-preview--mono)
                                           :font-size (etaf-org-preview--scaled 0.8))
                                     (list (format "抽屉 %s" name))))
                    (unless (string-empty-p text)
                      (list (etaf-node 'box
                                       (list :width 'stretch :wrap-mode 'word
                                             :padding-top '(lh 0.25))
                                       (list (etaf-node 'text
                                                        (list :color
                                                              (etaf-org-preview--color
                                                               env :ink)
                                                              :font-size
                                                              (etaf-org-preview--scaled 0.85))
                                                        (list text))))))))
      (etaf-node 'box
                 (list :padding-left '(ch 2) :padding-top '(lh 0.25))
                 (list (etaf-org-preview--reveal-chip
                        env (format "抽屉 %s" name) "显示抽屉内容"))))))

(defun etaf-org-preview--callout-view (block env)
  "Return the callout View of special BLOCK in ENV."
  (let* ((name (downcase (or (plist-get block :name) "")))
         (kind (pcase name
                 ((or "note" "info") (list "提示" :info :info-soft))
                 ((or "tip" "hint") (list "要点" :ok :ok-soft))
                 ((or "important" "success") (list "重要" :info :info-soft))
                 ((or "warning" "attention") (list "警告" :warn :warn-soft))
                 ("caution" (list "小心" :warn :warn-soft))
                 ((or "danger" "error") (list "危险" :danger :danger-soft))
                 (_ nil))))
    (if (null kind)
        (etaf-node 'box
                   (list :width 'stretch
                         :background-color (etaf-org-preview--color env :panel)
                         :border (list '(px 1) 'solid
                                       (etaf-org-preview--color env :border))
                         :padding '((lh 1) (ch 2)))
                   (append
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :muted)
                                           :font-size (etaf-org-preview--scaled 0.82)
                                           :font-family (etaf-org-preview--mono))
                                     (list (upcase name))))
                    (etaf-org-preview--block-views
                     (plist-get block :blocks) env)))
      (etaf-node 'box
                 (list :width 'stretch
                       :background-color (etaf-org-preview--color env (nth 2 kind))
                       :border-left (list '(px 2) 'solid
                                          (etaf-org-preview--color env (nth 1 kind)))
                       :padding '((lh 1) (ch 2)))
                 (append
                  (list (etaf-node 'text
                                   (list :color (etaf-org-preview--color env (nth 1 kind))
                                         :font-weight 'bold)
                                   (list (nth 0 kind))))
                  (etaf-org-preview--block-views
                   (plist-get block :blocks) env))))))

(defun etaf-org-preview--quote-view (block env)
  "Return the quote View of BLOCK in ENV."
  (etaf-node 'box
             (list :width 'stretch
                   :background-color (etaf-org-preview--color env :quote-bg)
                   :border-left (list '(px 2) 'solid
                                      (etaf-org-preview--color env :quote-bar))
                   :padding '((lh 1) (ch 2)))
             (append
              (list (etaf-node 'column
                               (list :width 'stretch :item-gap '(lh 1))
                               (etaf-org-preview--block-views
                                (plist-get block :blocks) env)))
              (when-let* ((attribution (plist-get block :attribution)))
                (list (etaf-node 'box
                                 (list :width 'stretch :text-align 'right
                                       :padding-top '(lh 0.5))
                                 (list (etaf-node 'text
                                                  (list :color (etaf-org-preview--color
                                                                env :muted))
                                                  (list (format "— %s" attribution))))))))))

(defun etaf-org-preview--block-view (block env)
  "Return the View of BLOCK in ENV, or nil when nothing renders."
  (let ((type (plist-get block :type))
        (hidden (plist-get env :hidden)))
    (pcase type
      ('paragraph
       (if-let* ((media (plist-get block :media)))
           (if (eq (plist-get media :kind) 'video)
               (etaf-org-preview--file-card
                (list :path (plist-get media :path) :label "视频") env)
             (etaf-org-preview--image-card
              (plist-put media :caption (plist-get block :caption)) env))
         (etaf-org-preview--runs-box (plist-get block :inlines) env)))
      ('list (etaf-org-preview--list-view block env))
      ('table (etaf-org-preview--table-view block env))
      ('src-block
       (if (and (equal (downcase (or (plist-get block :lang) "")) "mermaid")
                (plist-get block :picture))
           (etaf-org-preview--typeset-figure 'mermaid
                                             (plist-get block :picture) env)
         (etaf-org-preview--code-block-view block env)))
      ('example-block (etaf-org-preview--code-block-view block env))
      ('results (etaf-org-preview--code-block-view block env "结果"))
      ('fixed-width
       (etaf-node 'box
                  (list :width 'stretch :wrap-mode 'char
                        :font-family (etaf-org-preview--mono)
                        :color (etaf-org-preview--color env :muted))
                  (list (etaf-node 'text nil
                                   (list (or (plist-get block :text) ""))))))
      ('quote-block (etaf-org-preview--quote-view block env))
      ('special-block (etaf-org-preview--callout-view block env))
      ('center-block
       (etaf-node 'column
                  (list :width 'stretch :cross-align 'center
                        :max-width (list 'ch (round (* (or (plist-get env :width) 92)
                                                       0.8))))
                  (etaf-org-preview--block-views
                   (plist-get block :blocks) env)))
      ('verse-block
       (etaf-node 'box
                  (list :width 'stretch :wrap-mode 'word
                        :color (etaf-org-preview--color env :ink))
                  (list (etaf-node 'text nil
                                   (list (or (plist-get block :text) ""))))))
      ('comment-block
       (when hidden
         (etaf-node 'box
                    (list :width 'stretch
                          :background-color (etaf-org-preview--color env :panel)
                          :padding '((lh 1) (ch 2)))
                    (list (etaf-node 'text
                                     (list :color (etaf-org-preview--color env :faint)
                                           :font-family (etaf-org-preview--mono))
                                     (list (or (plist-get block :text) "")))))))
      ('export-block
       (etaf-org-preview--code-block-view
        block env (format "export %s" (or (plist-get block :backend) ""))))
      ('comment
       (when hidden
         (etaf-node 'text
                    (list :color (etaf-org-preview--color env :faint)
                          :font-family (etaf-org-preview--mono)
                          :font-size (etaf-org-preview--scaled 0.85))
                    (list (or (plist-get block :text) "")))))
      ('keyword
       (when (and hidden (not (plist-get block :attached)))
         (etaf-node 'text
                    (list :color (etaf-org-preview--color env :faint)
                          :font-family (etaf-org-preview--mono)
                          :font-size (etaf-org-preview--scaled 0.85))
                    (list (format "#+%s: %s" (plist-get block :key)
                                  (plist-get block :value))))))
      ('horizontal-rule (etaf-org-preview--rule env 0.75))
      ('latex-environment
       (or (when-let* ((picture (plist-get block :picture)))
             (etaf-org-preview--typeset-figure 'math picture env))
           (etaf-node 'box
                      (list :width 'stretch
                            :background-color (etaf-org-preview--color env :panel)
                            :border (list '(px 1) 'solid
                                          (etaf-org-preview--color env :border))
                            :padding '((lh 1) (ch 2))
                            :wrap-mode 'char)
                      (list (etaf-node 'text
                                       (list :color (etaf-org-preview--color env :muted)
                                             :font-family (etaf-org-preview--mono))
                                       (list (or (plist-get block :text) "")))))))
      ('display-math
       (or (when-let* ((picture (plist-get block :picture)))
             (etaf-org-preview--typeset-figure 'math picture env))
           (etaf-node 'box
                      (list :width 'stretch
                            :background-color (etaf-org-preview--color env :panel)
                            :padding '((lh 1) (ch 2))
                            :text-align 'center)
                      (list (etaf-node 'text
                                       (list :color (etaf-org-preview--color env :ink)
                                             :font-family (etaf-org-preview--mono)
                                             :font-style 'italic)
                                       (list (or (plist-get block :text) "")))))))
      ((or 'dynamic-block 'babel-call)
       (etaf-node 'box
                  (list :width 'stretch
                        :background-color (etaf-org-preview--color env :panel)
                        :border (list '(px 1) 'solid
                                      (etaf-org-preview--color env :border))
                        :padding '((lh 1) (ch 2)))
                  (append
                   (list (etaf-node 'text
                                    (list :color (etaf-org-preview--color env :muted)
                                          :font-size (etaf-org-preview--scaled 0.82))
                                    (list (if (eq type 'dynamic-block)
                                              (format "未求值的动态块：%s"
                                                      (or (plist-get block :name) ""))
                                            (format "未执行的调用：%s"
                                                    (or (plist-get block :name) ""))))))
                   (when-let* ((text (plist-get block :text)))
                     (list (etaf-node 'text
                                      (list :color (etaf-org-preview--color env :faint)
                                            :font-family (etaf-org-preview--mono)
                                            :font-size (etaf-org-preview--scaled 0.85))
                                      (list text)))))))
      ('include-card
       (etaf-org-preview--file-card
        (list :path (plist-get block :target)) env))
      ('drawer (etaf-org-preview--drawer-view block env hidden))
      ('footnote-def nil)
      (_ nil))))

(defun etaf-org-preview--block-views (blocks env)
  "Return the list of Views for BLOCKS in ENV.
The caller owns the spacing between blocks through its column gap."
  (let (views)
    (dolist (block blocks)
      (when-let* ((view (etaf-org-preview--block-view block env)))
        (push view views)))
    (nreverse views)))

;;; ---------------------------------------------------------------------------
;;; Headline
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--keyword-kind (todo todo-keywords)
  "Return the semantic kind of TODO from TODO-KEYWORDS."
  (when todo
    (let* ((entry (assoc todo todo-keywords))
           (state (cdr entry)))
      (cond
       ((eq state 'done)
        (if (string-match-p "CANCEL\\|ARCHIVE\\|REJECT" (upcase todo)) 'hold 'done))
       ((string-match-p "NEXT\\|STARTED\\|PROGRESS\\|DOING" (upcase todo)) 'progress)
       ((string-match-p "WAIT\\|HOLD\\|BLOCK" (upcase todo)) 'hold)
       (t 'todo)))))

(defun etaf-org-preview--keyword-chip (todo kind _env)
  "Return the keyword chip for TODO of KIND in ENV."
  (let ((variant (pcase kind
                   ('done 'success)
                   ('progress 'info)
                   ('hold 'neutral)
                   (_ 'warning))))
    ;; The tag computes its own width, but it is a flex item here: a tight
    ;; heading row would shrink it and clip the last glyph of the keyword.
    (etaf-node 'box
               (list :flex-shrink 0)
               (list (etaf-node 'etaf-tag
                                (list :text todo :variant variant)
                                nil)))))

(defun etaf-org-preview--planning-view (planning env)
  "Return the planning line View of PLANNING in ENV.
Each field is a written label and its date, so the line stays readable
without a font that carries calendar or alarm glyphs."
  (let ((entries nil))
    (dolist (pair '((:scheduled "计划" :date)
                    (:deadline "截止" :urgent)
                    (:closed "完成" :muted)))
      (when-let* ((stamp (plist-get planning (nth 0 pair))))
        (push (etaf-node 'flex
                         (list :gap '((lh 0) (ch 1)) :align-items 'baseline)
                         (list (etaf-node 'text
                                          (list :color (etaf-org-preview--color
                                                        env (nth 2 pair))
                                                :font-size (etaf-org-preview--scaled 0.78)
                                                :font-weight 'bold)
                                          (list (nth 1 pair)))
                               (etaf-node 'text
                                          (list :color (etaf-org-preview--color
                                                        env (nth 2 pair))
                                                :font-size (etaf-org-preview--scaled 0.85)
                                                :font-family (etaf-org-preview--mono))
                                          (list (etaf-org-preview--timestamp-text
                                                 stamp)))))
              entries)))
    (when entries
      (etaf-node 'flex
                 (list :width 'stretch :gap '((lh 0) (ch 3))
                       :padding-left '(ch 2))
                 (nreverse entries)))))

(defun etaf-org-preview--properties-chip (section env hidden)
  "Return the property View of SECTION in ENV.
An expanded view (HIDDEN set) is a two-column grid; otherwise one chip."
  (let ((properties (etaf-org-preview-section-properties section)))
    (when properties
      (if hidden
          (etaf-node 'column
                     (list :width 'stretch :padding-left '(ch 2)
                           :item-gap '(lh 0.25))
                     (mapcar (lambda (pair)
                               (etaf-node 'flex
                                          (list :width 'stretch :gap '((lh 0) (ch 1)))
                                          (list
                                           (etaf-node 'text
                                                      (list :color (etaf-org-preview--color
                                                                    env :muted)
                                                            :font-family (etaf-org-preview--mono)
                                                            :font-size (etaf-org-preview--scaled 0.82))
                                                      (list (car pair)))
                                           (etaf-node 'text
                                                      (list :color (etaf-org-preview--color
                                                                    env :ink)
                                                            :font-family (etaf-org-preview--mono)
                                                            :font-size (etaf-org-preview--scaled 0.82))
                                                      (list (cdr pair))))))
                             properties))
        (etaf-node 'box
                   (list :padding-left '(ch 2)
                         :padding-top '(lh 0.25))
                   (list (etaf-org-preview--chip
                          env (format "属性 %d" (length properties))
                          :muted :panel)))))))

(defun etaf-org-preview--logbook-chip (section env hidden)
  "Return the LOGBOOK summary of SECTION in ENV, or nil.
HIDDEN also shows the recorded lines under the summary."
  (when-let* ((entries (etaf-org-preview-section-logbook section)))
    (let* ((minutes (cl-loop for entry in entries
                             sum (or (plist-get entry :minutes) 0)))
           (label (if (> minutes 0)
                      (format "记录 %d · %d:%02d" (length entries)
                              (/ minutes 60) (% minutes 60))
                    (format "记录 %d" (length entries)))))
      (if hidden
          (etaf-node 'column
                     (list :width 'stretch :padding-left '(ch 2)
                           :padding-top '(lh 0.25) :item-gap '(lh 0.25))
                     (list (etaf-org-preview--chip env label :muted :panel)
                           (when-let* ((text (etaf-org-preview-section-logbook-text
                                              section))
                                       ((not (string-empty-p text))))
                             (etaf-node 'box
                                        (list :width 'stretch :wrap-mode 'char
                                              :color (etaf-org-preview--color env :muted)
                                              :font-family (etaf-org-preview--mono)
                                              :font-size (etaf-org-preview--scaled 0.8))
                                        (list (etaf-node 'text nil (list text)))))))
        (etaf-node 'box
                   (list :padding-left '(ch 2) :padding-top '(lh 0.25))
                   (list (etaf-org-preview--reveal-chip
                          env label "显示记录内容")))))))

(defun etaf-org-preview--tags-view (tags env)
  "Return TAGS as right-aligned chips in ENV."
  (when tags
    (etaf-node 'flex
               (list :flex-shrink 0 :gap '((lh 0) (ch 1)) :justify-content 'end
                     :max-width (list 'ch 32))
               (mapcar (lambda (tag)
                         (etaf-org-preview--chip
                          env (concat ":" tag ":") :muted :tag-bg))
                       tags))))

(defun etaf-org-preview--priority-box (priority env)
  "Return the priority chip of PRIORITY in ENV."
  (etaf-node 'box
             (list :flex-shrink 0
                   :border (list '(px 1) 'solid
                                 (etaf-org-preview--color
                                  env (if (equal priority "A") :danger :border)))
                   :color (etaf-org-preview--color
                           env (pcase priority
                                 ("A" :danger)
                                 ("B" :warn)
                                 (_ :muted)))
                   :font-size (etaf-org-preview--scaled 0.78)
                   :padding-left '(ch 0.5)
                   :padding-right '(ch 0.5))
             (list (etaf-node 'text nil (list (format "#%s" priority))))))

(defun etaf-org-preview--heading-view (section _state env)
  "Return the headline row of SECTION at STATE in ENV.
The row is plain reading text: it carries no fold affordance."
  (let* ((level (max 1 (etaf-org-preview-section-level section)))
         (todo (etaf-org-preview-section-todo section))
         (kind (etaf-org-preview--keyword-kind
                todo (plist-get env :todo-keywords)))
         (priority (etaf-org-preview-section-priority section))
         (cookie (etaf-org-preview-section-cookie section))
         (tags (and (plist-get env :show-tags)
                    (etaf-org-preview-section-tags section)))
         (label (format "第%d级标题：%s%s"
                        level
                        (if todo (concat todo " ") "")
                        (etaf-org-preview-section-title-plain section)))
         (title-box (etaf-node 'box
                               (list :width 'stretch
                                     :min-width '(ch 10)
                                     :wrap-mode 'word)
                               (etaf-org-preview--inline-nodes
                                (etaf-org-preview-section-title-inlines section)
                                env
                                (list :font-size
                                      (etaf-org-preview--heading-size level)
                                      :font-weight 'bold
                                      :color (etaf-org-preview--color
                                              env (etaf-org-preview--heading-ink level))))))
         (left (append
                (when todo
                  (list (etaf-org-preview--keyword-chip todo kind env)))
                (when priority
                  (list (etaf-org-preview--priority-box priority env)))
                (when (etaf-org-preview-section-commented section)
                  (list (etaf-org-preview--chip env "注释" :muted :panel)))
                (when (etaf-org-preview-section-archived section)
                  (list (etaf-org-preview--chip env "归档" :muted :hold-soft)))
                (list title-box)))
         (right (append
                 (list (etaf-node 'box
                                  (list :width '(ch 1) :flex-shrink 0)
                                  nil))
                 (when cookie
                   (list (etaf-org-preview--chip env cookie :muted :panel)))
                 (when tags
                   (list (etaf-org-preview--tags-view tags env)))))
         (row (etaf-node 'flex
                         (list :width 'stretch
                               :justify-content 'space-between
                               :align-items 'center
                               :flex-wrap 'wrap
                               :gap '((lh 0.2) (ch 1))
                               ;; Markdown's top two headings carry a rule;
                               ;; Org keeps the same reading rhythm.
                               :border-bottom (when (<= level 2)
                                                (list '(px 1) 'solid
                                                      (etaf-org-preview--color
                                                       env :heading-rule)))
                               :padding-bottom (when (<= level 2)
                                                 '(lh 0.25)))
                         (list (etaf-node 'flex
                                          (list :flex-grow 1 :flex-shrink 1
                                                :min-width '(ch 0)
                                                :align-items 'center
                                                :gap '((lh 0) (ch 1)))
                                          left)
                               (etaf-node 'flex
                                          (list :flex-shrink 0
                                                :justify-content 'end
                                                :max-width '(ch 32))
                                          right)))))
    (etaf-node 'column
               (list :width 'stretch
                     :id (concat "org-section-" (etaf-org-preview-section-id section))
                     :padding-top (etaf-org-preview--heading-gap env level)
                     :aria-label label)
               (list row))))

(etaf-define-component etaf-org-preview-block (&key session block)
  "Render one published body BLOCK of SESSION.
The Component owns one block, so a publish that changes another block leaves
this block's instance and output alone."
  :render
  (etaf-org-preview--block-view block (etaf-org-preview--env session)))

(etaf-define-component etaf-org-preview-section
    (&key section fold session body children)
  "Render one headline SECTION with its own fold cell.
FOLD is the section's fold ref, read here so a fold repaints this section only.
BODY and CHILDREN are the published Component calls of its body and subtree, so
an unchanged block keeps its instance and a changed one is the only block that
paints.  A parent in the `children' state renders its children through those
calls; entering that state folds them in one batch."
  :render
  (let* ((env (etaf-org-preview--env session))
         (state (etaf-value fold))
         (open (eq state 'open))
         (hidden (plist-get env :hidden))
         (views nil))
    (setq views (list (etaf-org-preview--heading-view section state env)))
    (when-let* ((planning (etaf-org-preview-section-planning section)))
      (when (not (eq state 'folded))
        (push (etaf-org-preview--planning-view planning env) views)))
    (when (not (eq state 'folded))
      (when-let* ((chip (etaf-org-preview--properties-chip
                         section env hidden)))
        (push chip views))
      (when-let* ((chip (etaf-org-preview--logbook-chip
                         section env hidden)))
        (push chip views)))
    (when open
      (when body
        (push (etaf-node 'column
                         (list :width 'stretch :item-gap '(lh 1)
                               :padding-top '(lh 0.5))
                         body)
              views)))
    (when (and children (not (eq state 'folded)))
      (dolist (child children)
        (push child views)))
    (etaf-node 'column
               (list :width 'stretch :item-gap '(lh 0))
               (nreverse views))))

;;; ---------------------------------------------------------------------------
;;; Document
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--hero-view (document env)
  "Return the title block of DOCUMENT in ENV.
The title, the subtitle and the byline get one line of air each, so the
opening reads as a title page instead of a stack of metadata."
  (let* ((title (or (plist-get document :title)
                    (plist-get env :fallback-title)
                    "Org 文档"))
         (subtitle (plist-get document :subtitle))
         (author (plist-get document :author))
         (date (plist-get document :date))
         (modified (plist-get env :modified))
         (keywords (plist-get document :keywords))
         (filetags (plist-get document :filetags))
         (byline (string-join (delq nil (list author date)) " · "))
         (degraded (plist-get document :degraded)))
    (etaf-node 'column
               (list :width 'stretch)
               (append
                (list
                 (etaf-node 'text
                            (list :color (etaf-org-preview--color env :heading)
                                  :font-size (etaf-org-preview--scaled 2.15)
                                  :font-weight 'bold)
                            (list title)))
                (when (and subtitle (not (string-empty-p subtitle)))
                  (list (etaf-org-preview--spacer 1)
                        (etaf-node 'text
                                   (list :color (etaf-org-preview--color env :muted)
                                         :font-size (etaf-org-preview--scaled 1.12))
                                   (list subtitle))))
                (when (or (not (string-empty-p byline)) modified)
                  (list (etaf-org-preview--spacer 1)
                        (etaf-node 'flex
                                   (list :width 'stretch
                                         :gap '((lh 0) (ch 1))
                                         :align-items 'center
                                         :flex-wrap 'wrap)
                                   (append
                                    (when (not (string-empty-p byline))
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint)
                                                             :font-size
                                                             (etaf-org-preview--scaled 0.85))
                                                       (list byline))))
                                    (when (and modified
                                               (not (string-empty-p byline)))
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint))
                                                       (list "·"))))
                                    (when modified
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint)
                                                             :font-size
                                                             (etaf-org-preview--scaled 0.78))
                                                       (list modified))))))))
                (when (or keywords filetags)
                  (list (etaf-org-preview--spacer 1)
                        (etaf-node 'flex
                                   (list :width 'stretch
                                         :gap '((lh 0.5) (ch 1))
                                         :align-items 'center
                                         :flex-wrap 'wrap)
                                   (append
                                    (mapcar (lambda (keyword)
                                              (etaf-org-preview--chip
                                               env keyword :muted :panel))
                                            keywords)
                                    (when filetags
                                      (list (etaf-node 'text
                                                       (list :color (etaf-org-preview--color
                                                                     env :faint)
                                                             :font-size
                                                             (etaf-org-preview--scaled 0.82))
                                                       (list (string-join
                                                              (mapcar (lambda (tag)
                                                                        (concat "#" tag))
                                                                      filetags)
                                                              " ")))))))))
                (when (> (or degraded 0) 0)
                  (list (etaf-org-preview--spacer 0.5)
                        (etaf-org-preview--chip
                         env (format "%d 处已降级" degraded) :muted :panel)))
                ))))

(defun etaf-org-preview--toc-row (entry base env)
  "Return one table of contents row for ENTRY under BASE indentation."
  (etaf-node 'box
             (list :width 'stretch
                   :padding-left (list 'ch (* 2 (max 0 (- (nth 0 entry) base))))
                   :role 'button
                   :tab-index 0
                   :pointer 'hand
                   :help-echo "跳到这一节"
                   :on-press (lambda ()
                               (etaf-org-preview--act env :locate (nth 2 entry))))
             (list (etaf-node 'text
                              (list :color (etaf-org-preview--color env :muted)
                                    :font-size (etaf-org-preview--scaled 0.95))
                              (list (nth 1 entry))))))

(defun etaf-org-preview--toc-view (document env)
  "Return the table of contents of DOCUMENT in ENV.
Entries indent relative to the shallowest heading the document uses, so a book
whose chapters start at level three still reads as a flat list.  The contents
sit directly on the page: a small label and quiet rows, without a card."
  (when-let* ((depth (plist-get env :toc-depth)))
    (let* ((commented (make-hash-table :test #'equal))
           (entries nil))
      (cl-labels ((walk (sections)
                    (dolist (section sections)
                      (when (etaf-org-preview-section-commented section)
                        (puthash (etaf-org-preview-section-id section)
                                 t commented))
                      (walk (etaf-org-preview-section-children section)))))
        (walk (plist-get document :sections)))
      (setq entries (cl-remove-if
                     (lambda (entry)
                       (or (> (nth 0 entry) depth)
                           (gethash (nth 2 entry) commented)))
                     (plist-get document :outline)))
      (when entries
        (let* ((base (apply #'min (mapcar (lambda (entry) (nth 0 entry)) entries)))
               (rows (mapcar (lambda (entry)
                               (etaf-org-preview--toc-row entry base env))
                             entries)))
          (etaf-node 'box
                     (list :width 'stretch
                           :border-left (list '(px 2) 'solid
                                              (etaf-org-preview--color env :rule))
                           :padding-left '(ch 2)
                           :margin-top '(lh 0.5)
                           :margin-bottom '(lh 1))
                     (list
                      (etaf-node 'text
                                 (list :color (etaf-org-preview--color env :muted)
                                       :font-size (etaf-org-preview--scaled 0.82)
                                       :font-weight 'bold)
                                 (list "目录"))
                      (etaf-node 'box
                                 (list :width 'stretch :height '(lh 0.5)) nil)
                      (etaf-node 'column (list :width 'stretch) rows))))))))

(defun etaf-org-preview--footnotes-view (document env)
  "Return the footnote section of DOCUMENT in ENV."
  (when-let* ((footnotes (plist-get document :footnotes)))
    (etaf-node 'column
               (list :width 'stretch :item-gap '(lh 0.5)
                     :padding-top '(lh 2))
               (append
                (list (etaf-org-preview--rule env 0.75)
                      (etaf-node 'text
                                 (list :color (etaf-org-preview--color env :muted)
                                       :font-weight 'bold)
                                 (list "脚注")))
                (mapcar
                 (lambda (footnote)
                   (etaf-node 'flex
                              (list :width 'stretch :gap '((lh 0) (ch 1))
                                    :align-items 'start)
                              (list
                               (etaf-node 'box
                                          (list :width '(ch 4) :flex-shrink 0)
                                          (list (etaf-node 'text
                                                           (list :color
                                                                 (etaf-org-preview--color env :link)
                                                                 :font-family
                                                                 (etaf-org-preview--mono))
                                                           (list (format "[%d]"
                                                                         (plist-get footnote :number))))))
                               (etaf-node 'box
                                          (list :width 'stretch :wrap-mode 'word
                                                :font-size
                                                (etaf-org-preview--scaled 0.9))
                                          (etaf-org-preview--inline-nodes
                                           (plist-get footnote :inlines) env)))))
                 footnotes)))))

(defun etaf-org-preview--view-document (document env)
  "Return the mounted reading View of DOCUMENT in ENV.
The column is centered and capped by ENV's `:width'; a narrow window fills down
to the gutter on both sides.  Sections are Components, so a fold only repaints
the section it changes."
  (let* ((width (max 24 (or (plist-get env :width) 92)))
         (gutter etaf-org-preview--measure-gutter)
         (background (plist-get env :background))
         (sections (plist-get document :section-entries))
         ;; Metadata keywords and footnote definitions are not page blocks:
         ;; the title block and the footnote list already show them.
         (preamble (cl-remove-if
                    (lambda (entry)
                      (memq (plist-get (plist-get entry :block) :type)
                            '(keyword footnote-def)))
                    (plist-get document :preamble-entries))))
    (etaf-node 'column
               (append (list :width '(vw 100) :cross-align 'center
                             :aria-label "Org 预览"
                             :on-direction
                             (lambda (direction)
                               (pcase direction
                                 ('down
                                  (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                    (etaf-scroll-viewport rt 1))
                                  'handled)
                                 ('up
                                  (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                    (etaf-scroll-viewport rt -1))
                                  'handled)
                                 (_ 'release))))
                       (when background
                         (list :background-color background)))
               (list
                (etaf-node 'column
                           (list :width 'stretch
                                 :max-width (list 'ch (+ width (* 2 gutter)))
                                 :overflow 'hidden
                                 :padding (list (list 'lh 1) (list 'ch gutter))
                                 :color (etaf-org-preview--color env :ink))
                           (append
                            (list (etaf-org-preview--hero-view document env)
                                  (etaf-org-preview--spacer 2)
                                  (etaf-org-preview--toc-view document env)
                                  (etaf-node 'column
                                             (list :width 'stretch
                                                   :item-gap '(lh 1))
                                             (mapcar (lambda (entry)
                                                       (plist-get entry :view))
                                                     preamble)))
                            (mapcar (lambda (entry) (plist-get entry :view))
                                    sections)
                            (list (etaf-org-preview--footnotes-view document env))))))))

(provide 'etaf-org-preview-views)
;;; etaf-org-preview-views.el ends here
