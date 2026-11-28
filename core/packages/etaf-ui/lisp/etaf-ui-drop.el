;;; etaf-ui-drop.el --- A drop target that previews where a drag will land -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; When a pointer drags something over a pane, the pane has to answer two
;; questions before the release: will this land, and where.  `etaf-drop-zone'
;; draws that answer as one half of the pane: the half is tinted with the
;; accent colour and framed with a dashed rule, the way a terminal marks a
;; drop target, and the dragged thing's name sits in the middle of it.
;;
;; The preview occupies exactly the half the release will take, so the layout
;; does not jump a second time when the pointer lets go.  A text frame has no
;; alpha, so the tint is the accent mixed into the pane's own surface; the two
;; blend to the same impression of translucency in either palette.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-style)

(defun etaf-drop-zone-node (side lines cols rows label &optional accent ratio ref)
  "Return the View of LINES as a pane whose drop preview sits on SIDE.
This is the plain function behind `etaf-drop-zone': a caller that builds its
page with `etaf-node' calls it directly.  SIDE, LINES, COLS, ROWS, LABEL and
RATIO mean what the Component documents; ACCENT overrides the preview ink and
REF attaches the Host reference."
  (let* ((colours (etaf-ui--style-tokens :ui-panel-bg :ui-panel-fg
                                         :ui-muted-fg :ui-warning-fg))
         (accent (or accent (etaf-ui--drop-accent colours)))
         (surface (or (plist-get colours :ui-panel-bg) "#FFFFFF"))
         (fill (etaf-ui-color-mix accent surface 0.18))
         (ink (etaf-ui-color-legible
               (etaf-ui-color-mix (plist-get colours :ui-panel-fg) fill 0.35)
               fill))
         (mono (or (face-attribute 'fixed-pitch :family nil t) "monospace")))
    (let ((view (if (null side)
                    (etaf-ui--drop-lines-node lines cols (plist-get colours :ui-panel-fg))
                  (etaf-ui--drop-pane side lines cols rows label accent ink fill mono
                                      (or ratio 0.5)))))
      (if ref
          (etaf-node 'box (list :width (list 'ch cols) :ref ref) (list view))
        view))))

(defun etaf-ui--drop-chip (label width)
  "Return LABEL as a chip fitted into WIDTH cells, or nil when it cannot fit."
  (when (and label (not (string-empty-p label)) (> width 4))
    (truncate-string-to-width (format "[ %s ]" label) width nil nil "…")))

(defun etaf-ui--drop-rule (width chip top)
  "Return the dashed rule of WIDTH cells, carrying CHIP centered when TOP.
A rule spells its dashes in cells: Ebox paints solid borders, and only the
dashes say that the area is a target rather than a finished pane."
  (let* ((inner (max 0 (- width 2)))
         (corners (if top (cons "╭" "╮") (cons "╰" "╯")))
         (chip (and chip (<= (string-width chip) (- inner 2)) chip))
         (before (if chip (max 1 (/ (- inner (string-width chip)) 2)) 0))
         (after (max 0 (- inner before (if chip (string-width chip) 0)))))
    (concat (car corners) (make-string before ?┄) (or chip "")
            (make-string after ?┄) (cdr corners))))

(defun etaf-ui--drop-fit (text width)
  "Return TEXT cut or padded to exactly WIDTH cells."
  (let ((text (truncate-string-to-width (or text "") width nil nil "…")))
    (concat text (make-string (max 0 (- width (string-width text))) ?\s))))

(defun etaf-ui--drop-row (line width border ink mono)
  "Return one preview row of WIDTH cells: LINE between dashed side rules.
The rules take BORDER and LINE takes INK, because a text node carries one
colour and the frame must not tint the content it covers."
  (etaf-node
   'flex
   (list :width (list 'ch width) :height '(lh 1) :column-gap '(ch 0))
   (list (etaf-node 'text (list :font-family mono :color border)
                    (list "┆"))
         (etaf-node 'text (list :color ink)
                    (list (etaf-ui--drop-fit line (max 0 (- width 2)))))
         (etaf-node 'text (list :font-family mono :color border)
                    (list "┆")))))

(defun etaf-ui--drop-block (lines cols rows label border ink fill mono)
  "Return LINES painted inside a dashed frame COLS by ROWS, naming LABEL.
BORDER paints the dashes, INK the text inside them, FILL the tint behind both,
and MONO the font of the rules.  ROWS counts the two rule rows."
  (let* ((cols (max 4 cols))
         (rows (max 3 rows))
         (body (max 1 (- rows 2)))
         (chip (etaf-ui--drop-chip label (- cols 2))))
    (etaf-node
     'box
     (list :width (list 'ch cols) :height (list 'lh rows)
           :background-color fill :overflow 'hidden)
     (list
      (etaf-node
       'column
       (list :width (list 'ch cols) :item-gap '(lh 0))
       (append
        (list (etaf-node 'text (list :font-family mono :color border)
                         (list (etaf-ui--drop-rule cols chip t))))
        (cl-loop for row below body
                 collect (etaf-ui--drop-row (or (nth row lines) "") cols
                                            border ink mono))
        (list (etaf-node 'text (list :font-family mono :color border)
                         (list (etaf-ui--drop-rule cols nil nil))))))))))

(defun etaf-ui--drop-accent (colours)
  "Return the drop preview ink from COLOURS."
  (or (plist-get colours :ui-warning-fg) "#B45309"))

(defun etaf-ui--drop-rows (lines rows start)
  "Return ROWS entries of LINES, beginning at START."
  (cl-loop for index from start below (+ start rows)
           collect (or (nth index lines) "")))

(defun etaf-ui--drop-slice (lines start width rows)
  "Return ROWS of LINES cut to WIDTH cells, beginning at column START."
  (cl-loop for index below rows
           for line = (or (nth index lines) "")
           for tail = (if (> start 0)
                          (truncate-string-to-width line (string-width line) start)
                        line)
           collect (etaf-ui--drop-fit tail width)))

(defun etaf-ui--drop-lines-node (lines width colour)
  "Return LINES as one text node WIDTH wide, inked COLOUR."
  (etaf-node
   'box
   (list :width (list 'ch width) :overflow 'hidden)
   (list (etaf-node 'text (list :color colour)
                    (list (mapconcat (lambda (line) (etaf-ui--drop-fit line width))
                                     lines "\n"))))))

(defun etaf-ui--drop-pane (side lines cols rows label border ink fill mono ratio)
  "Return the pane cells of COLS by ROWS with a drop preview on SIDE.
LINES is the pane's text, LABEL the dragged thing, BORDER and INK the preview's
colours, FILL its tint, MONO its rule font and RATIO the preview's share.  The
preview covers the cells the release would take and keeps the pane's own text
inside it, dimmed under the dashed frame; the text outside it stays as it was."
  (let* ((cols (max 6 cols))
         (rows (max 3 rows))
         (frame-rows (max 3 (min rows (round (* rows ratio)))))
         (frame-cols (max 6 (min cols (round (* cols ratio)))))
         (rest-rows (max 0 (- rows frame-rows)))
         (rest-cols (max 0 (- cols frame-cols))))
    (pcase side
      ('top
       (etaf-node 'column (list :width (list 'ch cols) :height (list 'lh rows)
                                :item-gap '(lh 0) :overflow 'hidden)
                  (list (etaf-ui--drop-block
                         lines cols frame-rows label border ink fill mono)
                        (etaf-ui--drop-lines-node
                         (etaf-ui--drop-rows lines rest-rows (- frame-rows 2))
                         cols ink))))
      ('bottom
       (etaf-node 'column (list :width (list 'ch cols) :height (list 'lh rows)
                                :item-gap '(lh 0) :overflow 'hidden)
                  (list (etaf-ui--drop-lines-node
                         (etaf-ui--drop-rows lines rest-rows 0) cols ink)
                        (etaf-ui--drop-block
                         (etaf-ui--drop-rows lines (- frame-rows 2) rest-rows)
                         cols frame-rows label border ink fill mono))))
      ((or 'left 'right)
       (let ((frame (etaf-ui--drop-block
                     (etaf-ui--drop-slice lines 0 (- frame-cols 2) rows)
                     frame-cols rows label border ink fill mono))
             (rest (etaf-ui--drop-lines-node
                    (etaf-ui--drop-slice lines (- frame-cols 2) rest-cols rows)
                    rest-cols ink)))
         (etaf-node 'flex (list :width (list 'ch cols) :height (list 'lh rows)
                                :column-gap '(ch 0) :overflow 'hidden)
                    (if (eq side 'left)
                        (list frame rest)
                      (list rest frame)))))
      (_
       (etaf-node 'box (list :width (list 'ch cols) :height (list 'lh rows)
                             :overflow 'hidden)
                  (list (etaf-ui--drop-block
                         (etaf-ui--drop-slice lines 0 (- cols 2) rows)
                         cols rows label border ink fill mono)))))))

(etaf-define-component etaf-drop-zone
    (&key side lines cols rows label (ratio 0.5) accent ref)
  "Render LINES as a pane whose drop preview sits on SIDE.\nSIDE is nil, `top', `bottom', `left', `right' or `center'; nil paints the\nlines plainly.  The preview takes RATIO of the pane, names LABEL on its dashed\nrule and keeps the pane's own text inside it, so a reader sees where the pane\nwill land and what it will cover.  COLS and ROWS are the pane's size in cells.\nACCENT overrides the preview ink; the tint is that colour mixed into the pane\nsurface, which is how a text frame shows translucency."
  :validate
  (progn
    (etaf-check-prop :side side (memq side '(nil top bottom left right center))
                     "nil, `top', `bottom', `left', `right' or `center'"
                     'etaf-drop-zone)
    (etaf-check-prop :lines lines (proper-list-p lines)
                     "a list of strings" 'etaf-drop-zone)
    (etaf-check-prop :cols cols (and (integerp cols) (> cols 0))
                     "a positive cell count" 'etaf-drop-zone)
    (etaf-check-prop :rows rows (and (integerp rows) (> rows 0))
                     "a positive row count" 'etaf-drop-zone)
    (etaf-check-prop :ratio ratio (and (numberp ratio) (> ratio 0) (< ratio 1))
                     "a number between 0 and 1" 'etaf-drop-zone))
  :render
  (etaf-drop-zone-node side lines cols rows label accent ratio ref))

(provide 'etaf-ui-drop)
;;; etaf-ui-drop.el ends here
