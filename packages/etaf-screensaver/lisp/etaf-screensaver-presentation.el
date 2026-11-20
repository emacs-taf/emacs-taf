;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-presentation.el --- Viewport geometry and composition

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Geometry is computed once for both scene contexts and composition.  A wall
;; holds independent works, never pieces of one frame.  Below the minimum
;; canvas we clip the same geometry instead of passing negative sizes to scenes.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-model)

(defconst etaf-screensaver--presentation-styles '(full card band mosaic)
  "Supported presentation styles.")

(defun etaf-screensaver--presentation-rgb (color)
  "Return the RGB channels of a six-digit hex COLOR, or nil."
  (when (and (stringp color) (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color))
    (cl-loop for start in '(1 3 5)
             collect (string-to-number (substring color start (+ start 2)) 16))))

(defun etaf-screensaver--presentation-mix (color toward share)
  "Mix COLOR with TOWARD by SHARE, a fraction from zero to one."
  (apply #'format "#%02x%02x%02x"
         (cl-mapcar (lambda (a b) (round (+ (* a (- 1 share)) (* b share))))
                    (etaf-screensaver--presentation-rgb color)
                    (etaf-screensaver--presentation-rgb toward))))

(defun etaf-screensaver--presentation-palette (background)
  "Derive framing colors from BACKGROUND, without recoloring the work."
  (let* ((base (if (etaf-screensaver--presentation-rgb background) background "#05070B"))
         (rgb (etaf-screensaver--presentation-rgb base))
         (light (> (+ (* .299 (nth 0 rgb)) (* .587 (nth 1 rgb)) (* .114 (nth 2 rgb))) 128))
         (contrast (if light "#000000" "#FFFFFF"))
         (mat (etaf-screensaver--presentation-mix base "#000000" (if light .92 .4))))
    (list :mat mat :mat-text (etaf-screensaver--presentation-mix mat "#FFFFFF" .65)
          :paper base
          :border (etaf-screensaver--presentation-mix base contrast .28)
          :text (etaf-screensaver--presentation-mix base contrast .72)
          :muted (etaf-screensaver--presentation-mix base contrast .52))))

(defun etaf-screensaver--presentation-crop (text width &optional start)
  "Fit TEXT to WIDTH display columns starting at START, preserving properties.
A partially visible wide character becomes padding.  Cropped image runs keep
only the corresponding horizontal slice, rather than displaying the full image
from a shortened character span.  Reel image runs reserve their cell footprint."
  (cond
   ((zerop width) "")
   ((and (zerop (or start 0)) (<= (string-width text) width))
    ;; Padding is not cropping: preserve complete text/image runs without
    ;; slicing and rebuilding them just to append empty canvas cells.
    (let ((padding (- width (string-width text))))
      (if (zerop padding) text
        (concat text (make-string padding ?\s)))))
   (t
    (let ((start (or start 0)) (position 0) (column 0) pieces)
      (while (and (< position (length text)) (< column (+ start width)))
        (let* ((end (next-single-property-change position 'display text (length text)))
               (run (substring text position end))
               (cells (string-width run))
               (from (max 0 (- start column)))
               (to (min cells (- (+ start width) column))))
          (when (< from to)
            (let* ((piece (truncate-string-to-width run to from ?\s))
                   (display (get-text-property position 'display text))
                   (slice (car-safe display)))
              (when (and (eq (car-safe slice) 'slice) (> cells 0)
                         (or (> from 0) (< to cells)))
                (let* ((x (nth 1 slice)) (w (nth 3 slice))
                       (left (round (* w (/ (float from) cells)))))
                  (put-text-property
                   0 (length piece) 'display
                   (list (list 'slice (+ x left) (nth 2 slice)
                               (- (round (* w (/ (float to) cells))) left)
                               (nth 4 slice))
                         (cadr display)) piece)))
              (push piece pieces)))
          (setq column (+ column cells) position end)))
      (let ((result (apply #'concat (nreverse pieces))))
        (concat result (make-string (max 0 (- width (string-width result))) ?\s)))))))

(defconst etaf-screensaver--card-margin-rows 3
  "Rows of mat between a card's frame and the window edge.
The card's side margin is derived from this value and the frame's cell
metrics, so the four distances match on screen rather than in cells.")

(defun etaf-screensaver--card-margin-columns (rows)
  "Return the column count whose pixel width matches ROWS line heights."
  (let* ((metrics (ignore-errors (etaf-display-metrics)))
         (cell-width (max 1 (or (plist-get metrics :char-width) (frame-char-width))))
         (line-height (max 1 (or (plist-get metrics :line-height) (frame-char-height)))))
    (max 1 (round (/ (* rows line-height) (float cell-width))))))

(defun etaf-screensaver--card-echo-rows ()
  "Return the echo row height below a presentation window, or zero.
The minibuffer row is outside the presentation window but part of the visible
frame; the canvas paints it with the scene background and the card counts it
as mat so the bottom and top distances stay equal."
  (let ((window (minibuffer-window)))
    (if (window-live-p window) (window-total-height window) 0)))

(defun etaf-screensaver--presentation-layout (style columns rows &optional count)
  "Return STYLE's layout with COLUMNS, ROWS and COUNT independent works.
Slots are (X Y WIDTH HEIGHT) content rectangles.  The same slots size the
callbacks and place their output.  A narrow wall stacks works vertically."
  (let* ((width (if (eq style 'full) columns (max 24 columns)))
         (height (if (eq style 'full) rows (max 10 rows)))
         (count (or count 1)))
    (pcase style
      ('full (list :width width :height height :slots (list (list 0 0 width height))))
      ('card
       ;; A centered work-colored page, framed by an even mat and two ordinary
       ;; caption rows at the lower left.  The mat is measured in line heights
       ;; vertically and in the matching pixel width horizontally; compact
       ;; windows shrink it before squeezing the work below four rows.  The
       ;; painted echo row below the window counts as part of the bottom mat.
       (let* ((margin (max 1 (min etaf-screensaver--card-margin-rows
                                  (floor (- height 8) 2))))
              (bottom (max 1 (- margin (etaf-screensaver--card-echo-rows))))
              (side (max 1 (min (etaf-screensaver--card-margin-columns margin)
                                (floor (- width 22) 2)))))
         (list :width width :height height
               :slots (list (list (1+ side) (1+ margin)
                                  (- width (* 2 side) 2)
                                  (- height margin bottom 4))))))
      ('band
       (let* ((h (max 3 (min (- height 5) (round (* height .5)))))
              (y (max 1 (/ (- height (+ h 3)) 2))))
         ;; Reserve a clock row below the picture, within the band.  It never
         ;; overwrites a work's last line or replaces an image slice.
         (list :width width :height height :slots (list (list 0 (1+ y) width h)))))
      ('mosaic
       (let* ((across (if (and (> count 1) (>= width 64)) 2 1))
              (down (ceiling count across))
              (height (max height (* down 6)))
              (cell-w (/ (- width (1- across)) across))
              (cell-h (/ (- height (1- down)) down))
              slots)
         (dotimes (index count)
           (let* ((col (% index across)) (row (/ index across))
                  (x (* col (1+ cell-w))) (y (* row (1+ cell-h)))
                  (w (if (= col (1- across)) (- width x) cell-w))
                  (h (if (= row (1- down)) (- height y) cell-h)))
             (push (list (1+ x) (1+ y) (- w 2) (- h 3)) slots)))
         (list :width width :height height :slots (nreverse slots))))
      (_ (etaf-screensaver--fail "Unknown presentation style: %s" style)))))

(defun etaf-screensaver--presentation-put (canvas x y text)
  "Place property-bearing TEXT at X,Y in row-vector CANVAS."
  (when (and (>= y 0) (< y (length canvas)))
    (let* ((row (aref canvas y)) (width (string-width row))
           (text (etaf-screensaver--presentation-crop text (min (- width x) (string-width text))))
           (end (+ x (string-width text))))
      (aset canvas y (concat (etaf-screensaver--presentation-crop row x)
                            text (etaf-screensaver--presentation-crop row (- width end) end))))))

(defun etaf-screensaver--presentation-label (text width foreground background)
  "Return a WIDTH-column TEXT label in FOREGROUND on BACKGROUND."
  (propertize (etaf-screensaver--presentation-crop text width)
              'face (list :foreground foreground :background background)))

(defun etaf-screensaver--presentation-template (style context)
  "Build STYLE's row plans from CONTEXT, outside the per-frame path.
Each plan holds static mat/border/caption strings and (WORK . ROW) slots.
Plans are shared read-only until the page, geometry or minute changes."
  (let* ((layout (plist-get context :layout))
         (width (plist-get layout :width))
         (height (plist-get layout :height))
         (backgrounds (plist-get context :backgrounds))
         (palette (etaf-screensaver--presentation-palette (car backgrounds)))
         (mat (plist-get palette (if (eq style 'card) :paper :mat)))
         (blank (propertize (make-string width ?\s) 'face (list :background mat)))
         (canvas (make-vector height blank)))
    (cl-loop for slot in (plist-get layout :slots)
             for title in (plist-get context :titles)
             for summary in (plist-get context :summaries)
             for background in backgrounds
             do
             (pcase-let ((`(,x ,y ,w ,h) slot))
               (let* ((colors (etaf-screensaver--presentation-palette background))
                      (paper (plist-get colors :paper))
                      (border (list :foreground (plist-get colors :border) :background paper))
                      (caption-rows (if (eq style 'card) 2 1))
                      (caption (if (and (eq style 'band) (plist-get context :pack-title))
                                   (format "%s · %s" (plist-get context :pack-title) title)
                                 title)))
                 (pcase style
                   ((or 'card 'mosaic)
                    (etaf-screensaver--presentation-put
                     canvas (1- x) (1- y)
                     (propertize (concat "┌" (make-string w ?─) "┐") 'face border))
                    (dotimes (row (+ h caption-rows))
                      (etaf-screensaver--presentation-put canvas (1- x) (+ y row) (propertize "│" 'face border))
                      (etaf-screensaver--presentation-put canvas (+ x w) (+ y row) (propertize "│" 'face border)))
                    (etaf-screensaver--presentation-put
                     canvas x (+ y h)
                     (etaf-screensaver--presentation-label
                      (if (eq style 'card) (concat " " caption) caption)
                      w (plist-get colors :text) paper))
                    (when (eq style 'card)
                      (etaf-screensaver--presentation-put
                       canvas x (+ y h 1)
                       (etaf-screensaver--presentation-label
                        (concat " " summary) w (plist-get colors :muted) paper)))
                    (etaf-screensaver--presentation-put
                     canvas (1- x) (+ y h caption-rows)
                     (propertize (concat "└" (make-string w ?─) "┘") 'face border)))
                   ('band
                    (let* ((clock (or (plist-get context :clock) (format-time-string "%H:%M")))
                           (clock-row (concat (make-string (max 0 (- w (string-width clock) 2)) ?\s) clock "  ")))
                      (etaf-screensaver--presentation-put canvas 0 (1- y) (propertize (make-string w ?─) 'face border))
                      (etaf-screensaver--presentation-put
                       canvas 0 (+ y h) (etaf-screensaver--presentation-label clock-row w (plist-get colors :text) paper))
                      (etaf-screensaver--presentation-put canvas 0 (+ y h 1) (propertize (make-string w ?─) 'face border))
                      (etaf-screensaver--presentation-put
                       canvas 0 (+ y h 2)
                       (etaf-screensaver--presentation-label (concat " " caption) w (plist-get palette :mat-text) mat))))))))
    ;; Split static rows once.  Repeatedly splicing a second tile into an
    ;; already composed row would remeasure/copy the first tile's face and
    ;; image runs, although every work is already fitted to its own slot.
    (dotimes (row height)
      (let ((text (aref canvas row)) (column 0) parts)
        (cl-loop for slot in (plist-get layout :slots) for work from 0
                 do (pcase-let ((`(,x ,y ,w ,h) slot))
                      (when (and (>= row y) (< row (+ y h)))
                        (when (< column x)
                          (push (etaf-screensaver--presentation-crop text (- x column) column) parts))
                        (push (cons work (- row y)) parts)
                        (setq column (+ x w)))))
        (when (< column width)
          (push (etaf-screensaver--presentation-crop text (- width column) column) parts))
        (aset canvas row (nreverse parts))))
    canvas))

(cl-defstruct (etaf-screensaver--frame-fragment
               (:constructor etaf-screensaver--frame-fragment-new))
  "A borrowed logical work row and its presentation-only background."
  text background)

(defun etaf-screensaver--frame-fragment-copy (part &optional background)
  "Copy PART's logical text and faces, adding fallback BACKGROUND.
Used when a row must be clipped or frozen for a reveal, not on ordinary frames."
  (let* ((fragment (etaf-screensaver--frame-fragment-p part))
         (text (copy-sequence (if fragment
                                  (etaf-screensaver--frame-fragment-text part) part)))
         (paper (and fragment (etaf-screensaver--frame-fragment-background part))))
    (when paper (add-face-text-property 0 (length text) (list :background paper) t text))
    (when background
      (add-face-text-property 0 (length text) (list :background background) t text))
    text))

(defun etaf-screensaver--presentation-compose (frames context template)
  "Place FRAMES in read-only TEMPLATE as rows of logical fragments.
Keep static strings and work rows separate until glyph projection.  Only a
viewport narrower than the layout requires joining and clipping logical text."
  (let ((works (vconcat (mapcar #'vconcat frames)))
        (backgrounds (vconcat (plist-get context :backgrounds)))
        (columns (plist-get context :columns))
        (width (plist-get (plist-get context :layout) :width)))
    (cl-loop for index below (plist-get context :rows)
             for row = (mapcar
                        (lambda (part)
                          (if (stringp part) part
                            (etaf-screensaver--frame-fragment-new
                             :text (aref (aref works (car part)) (cdr part))
                             :background (aref backgrounds (car part)))))
                        (aref template index))
             collect (if (= columns width) row
                       (list (etaf-screensaver--presentation-crop
                              (mapconcat #'etaf-screensaver--frame-fragment-copy row "")
                              columns))))))

(provide 'etaf-screensaver-presentation)
;;; etaf-screensaver-presentation.el ends here
