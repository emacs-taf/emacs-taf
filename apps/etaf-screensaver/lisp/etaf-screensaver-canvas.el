;;; etaf-screensaver-canvas.el --- Character canvas and color helpers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure cell-grid drawing primitives shared by built-in and custom scenes.
;; Cells track wide-character continuations so CJK text never overflows or
;; tears on overlap, and projection merges adjacent equal faces into single
;; text-property runs.  All helpers are pure and touch no buffers or timers.

;;; Code:
(require 'cl-lib)

(define-error 'etaf-screensaver-error "ETAF screensaver error")

(defun etaf-screensaver--fail (message &rest arguments)
  "Signal `etaf-screensaver-error' with formatted MESSAGE and ARGUMENTS."
  (signal 'etaf-screensaver-error (list (apply #'format message arguments))))

;;; Colors and sampling.

(defun etaf-screensaver--hex-rgb (color)
  "Return (R G B) integers for a six-digit hex COLOR, or nil."
  (when (and (stringp color) (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color))
    (list (string-to-number (substring color 1 3) 16)
          (string-to-number (substring color 3 5) 16)
          (string-to-number (substring color 5 7) 16))))

(defun etaf-screensaver--color-light-p (color)
  "Return non-nil when hex COLOR has light perceptual luminance."
  (when-let* ((rgb (etaf-screensaver--hex-rgb color)))
    (> (+ (* 0.299 (nth 0 rgb)) (* 0.587 (nth 1 rgb)) (* 0.114 (nth 2 rgb))) 128.0)))

(defun etaf-screensaver-color-mix (from to ratio)
  "Linearly blend six-digit hex colors FROM and TO by RATIO in [0, 1].
RATIO 0 returns FROM; 1 returns TO."
  (let ((a (etaf-screensaver--hex-rgb from))
        (b (etaf-screensaver--hex-rgb to)))
    (unless (and a b (numberp ratio))
      (etaf-screensaver--fail "color-mix needs two #RRGGBB colors and a numeric ratio"))
    (let ((k (max 0.0 (min 1.0 (float ratio)))))
      (format "#%02x%02x%02x"
              (round (+ (* (nth 0 a) (- 1.0 k)) (* (nth 0 b) k)))
              (round (+ (* (nth 1 a) (- 1.0 k)) (* (nth 1 b) k)))
              (round (+ (* (nth 2 a) (- 1.0 k)) (* (nth 2 b) k)))))))

(defun etaf-screensaver-ramp (sequence ratio)
  "Sample SEQUENCE (nonempty string, vector or list) at clamped RATIO in [0, 1]."
  (unless (numberp ratio)
    (etaf-screensaver--fail "ramp needs a numeric ratio"))
  (let* ((k (max 0.0 (min 1.0 (float ratio))))
         (len (cond ((stringp sequence) (length sequence))
                    ((vectorp sequence) (length sequence))
                    ((proper-list-p sequence) (length sequence))
                    (t 0))))
    (when (zerop len)
      (etaf-screensaver--fail "ramp needs a nonempty string, vector or list"))
    (let ((index (min (1- len) (floor (* k len)))))
      (if (listp sequence) (nth index sequence) (aref sequence index)))))

(defun etaf-screensaver--card-palette (background)
  "Derive card framing colors from BACKGROUND."
  (let* ((base (if (etaf-screensaver--hex-rgb background) background "#05070B"))
         (contrast (if (etaf-screensaver--color-light-p base) "#000000" "#FFFFFF")))
    (list :paper base
          :border (etaf-screensaver-color-mix base contrast 0.28)
          :text (etaf-screensaver-color-mix base contrast 0.72)
          :muted (etaf-screensaver-color-mix base contrast 0.50))))

;;; Character canvas.

(cl-defstruct (etaf-screensaver--canvas
               (:constructor etaf-screensaver--canvas-new))
  "Mutable scratch canvas of WIDTH by HEIGHT display cells."
  width height chars faces colored)

(defconst etaf-screensaver--canvas-continuation ?\uE000
  "Cell marker reserved by the wide character immediately preceding it.")

(defun etaf-screensaver-canvas-create (columns rows)
  "Return a blank COLUMNS by ROWS character canvas."
  (unless (and (integerp columns) (> columns 0) (integerp rows) (> rows 0))
    (etaf-screensaver--fail "Canvas dimensions must be positive integers"))
  (let ((size (* columns rows)))
    (etaf-screensaver--canvas-new
     :width columns
     :height rows
     :chars (make-vector size ?\s)
     :faces (make-vector size nil)
     :colored nil)))

(defun etaf-screensaver-canvas-clear (canvas)
  "Clear CANVAS characters and colors in place and return CANVAS."
  (fillarray (etaf-screensaver--canvas-chars canvas) ?\s)
  (fillarray (etaf-screensaver--canvas-faces canvas) nil)
  (setf (etaf-screensaver--canvas-colored canvas) nil)
  canvas)

(defun etaf-screensaver--canvas-clear-cell (chars faces index)
  "Reset cell INDEX in CHARS and FACES to a plain space."
  (aset chars index ?\s)
  (aset faces index nil))

(defun etaf-screensaver-canvas-put (canvas row col char &optional color)
  "Draw CHAR at ROW, COL in CANVAS with optional COLOR or face plist.
Out-of-bounds coordinates are ignored.  COLOR may be a color string (used as
foreground) or a face property list.  Wide characters reserve two cells and
never overflow the right edge."
  (let ((width (etaf-screensaver--canvas-width canvas))
        (height (etaf-screensaver--canvas-height canvas)))
    (when (and (integerp row) (integerp col)
               (>= row 0) (< row height)
               (>= col 0) (< col width))
      (let* ((ch (cond ((characterp char) char)
                       ((and (stringp char) (> (length char) 0)) (aref char 0))
                       (t ?\s)))
             (cw (max 1 (char-width ch)))
             (chars (etaf-screensaver--canvas-chars canvas))
             (faces (etaf-screensaver--canvas-faces canvas))
             (index (+ (* row width) col)))
        (when (<= (+ col cw) width)
          ;; Clean up any prior wide character partially overlapped by this write.
          (when (and (> col 0)
                     (eq (aref chars index) etaf-screensaver--canvas-continuation))
            (etaf-screensaver--canvas-clear-cell chars faces (1- index)))
          (when (and (< (1+ col) width)
                     (eq (aref chars (1+ index)) etaf-screensaver--canvas-continuation))
            (etaf-screensaver--canvas-clear-cell chars faces (1+ index)))
          (when (and (> cw 1) (< (+ col 2) width)
                     (eq (aref chars (+ index 2)) etaf-screensaver--canvas-continuation))
            (etaf-screensaver--canvas-clear-cell chars faces (+ index 2)))
          (aset chars index ch)
          (aset faces index color)
          (when (> cw 1)
            (aset chars (1+ index) etaf-screensaver--canvas-continuation)
            (aset faces (1+ index) color))
          (when color
            (setf (etaf-screensaver--canvas-colored canvas) t))))))
  canvas)

(defun etaf-screensaver-canvas-text (canvas row col text &optional color)
  "Draw TEXT on ROW starting at COL in CANVAS with optional COLOR or face plist.
COL may be an integer column or one of the alignment symbols `left', `center'
or `right'."
  (when (and (stringp text) (> (length text) 0))
    (let* ((width (etaf-screensaver--canvas-width canvas))
           (text-width (string-width text))
           (cell (pcase col
                   ('left 0)
                   ('center (/ (- width text-width) 2))
                   ('right (- width text-width))
                   ((pred integerp) col)
                   (_ (etaf-screensaver--fail "Invalid canvas text column: %S" col)))))
      (dotimes (i (length text))
        (let ((ch (aref text i)))
          (etaf-screensaver-canvas-put canvas row cell ch color)
          (cl-incf cell (max 1 (char-width ch)))))))
  canvas)

(defun etaf-screensaver-canvas-fill (canvas row col width height char &optional color)
  "Fill rectangle at ROW, COL of size WIDTH by HEIGHT with CHAR and COLOR."
  (let* ((cw (etaf-screensaver--canvas-width canvas))
         (ch (etaf-screensaver--canvas-height canvas))
         (r0 (max 0 row))
         (r1 (min ch (+ row height)))
         (c0 (max 0 col))
         (c1 (min cw (+ col width))))
    (cl-loop for r from r0 below r1 do
             (cl-loop for c from c0 below c1 do
                      (etaf-screensaver-canvas-put canvas r c char color))))
  canvas)

(defun etaf-screensaver-canvas-box (canvas row col width height &optional color)
  "Draw a thin Unicode box at ROW, COL of size WIDTH by HEIGHT in COLOR."
  (when (and (>= width 2) (>= height 2))
    (let ((right (+ col width -1))
          (bottom (+ row height -1)))
      (etaf-screensaver-canvas-put canvas row col ?┌ color)
      (etaf-screensaver-canvas-put canvas row right ?┐ color)
      (etaf-screensaver-canvas-put canvas bottom col ?└ color)
      (etaf-screensaver-canvas-put canvas bottom right ?┘ color)
      (cl-loop for c from (1+ col) below right do
               (etaf-screensaver-canvas-put canvas row c ?─ color)
               (etaf-screensaver-canvas-put canvas bottom c ?─ color))
      (cl-loop for r from (1+ row) below bottom do
               (etaf-screensaver-canvas-put canvas r col ?│ color)
               (etaf-screensaver-canvas-put canvas r right ?│ color))))
  canvas)

(defun etaf-screensaver--canvas-row (canvas row)
  "Project ROW of CANVAS to an owned string with merged face runs."
  (let* ((width (etaf-screensaver--canvas-width canvas))
         (chars (etaf-screensaver--canvas-chars canvas))
         (faces (etaf-screensaver--canvas-faces canvas))
         (start (* row width))
         (end (+ start width))
         (continuations (cl-count etaf-screensaver--canvas-continuation chars
                                  :start start :end end))
         (text (if (zerop continuations)
                   (concat (substring chars start end))
                 (let ((result (make-vector (- width continuations) ?\s))
                       (out 0))
                   (cl-loop for index from start below end
                            for ch = (aref chars index)
                            unless (eq ch etaf-screensaver--canvas-continuation)
                            do (aset result out ch) (cl-incf out))
                   (concat result)))))
    (when (etaf-screensaver--canvas-colored canvas)
      (let ((out 0) (run-start 0) run-face)
        (cl-loop for index from start below end
                 unless (eq (aref chars index) etaf-screensaver--canvas-continuation)
                 do (let ((face (aref faces index)))
                      (unless (equal face run-face)
                        (when run-face
                          (put-text-property
                           run-start out 'face
                           (if (stringp run-face) (list :foreground run-face) run-face)
                           text))
                        (setq run-start out run-face face))
                      (cl-incf out)))
        (when run-face
          (put-text-property
           run-start out 'face
           (if (stringp run-face) (list :foreground run-face) run-face)
           text))))
    text))

(defun etaf-screensaver-canvas-rows (canvas)
  "Return CANVAS projected as a list of owned, merged-face row strings."
  (cl-loop for row below (etaf-screensaver--canvas-height canvas)
           collect (etaf-screensaver--canvas-row canvas row)))

(defun etaf-screensaver--fit-row (text width)
  "Fit TEXT to exactly WIDTH display columns, preserving face properties.
A wide character that crosses WIDTH becomes padding."
  (let* ((clean (string-replace "\r" "" (string-replace "\t" " " text)))
         (w (string-width clean)))
    (cond
     ((<= width 0) "")
     ((= w width) (copy-sequence clean))
     ((< w width) (concat clean (make-string (- width w) ?\s)))
     (t (truncate-string-to-width clean width 0 ?\s)))))

(provide 'etaf-screensaver-canvas)
;;; etaf-screensaver-canvas.el ends here
