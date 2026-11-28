;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-glyphs.el --- Scalable recorded text on fixed canvas rows

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Vector glyphs enlarge text, not recorded pixels.  Their slices retain the
;; canvas line metrics and original characters; framing keeps its normal font.
;; SVG currentColor inherits each character's face, so changing color never
;; rebuilds its image descriptor or flushes a still-visible glyph shape.

;;; Code:
(require 'cl-lib)
(require 'svg)
(require 'etaf-screensaver-presentation)

(defun etaf-screensaver--glyph-attribute (face attribute)
  "Read ATTRIBUTE from a face plist, named face or ordered list of faces."
  (let ((value
         (cond ((keywordp (car-safe face)) (plist-get face attribute))
               ((consp face)
                (cl-some (lambda (part) (etaf-screensaver--glyph-attribute part attribute)) face))
               ((and face (facep face)) (face-attribute face attribute nil t)))))
    (unless (eq value 'unspecified) value)))

(defun etaf-screensaver--glyph-focus (rows)
  "Return the nonblank cell bounds (LEFT TOP RIGHT BOTTOM) of ROWS."
  (let (left top right bottom)
    (dotimes (y (length rows))
      (let ((row (aref rows y)) (x 0))
        (dotimes (i (length row))
          (let* ((char (aref row i)) (width (char-width char)))
            (unless (or (zerop width) (memq char '(?\s ?\t)))
              (setq left (if left (min left x) x)
                    top (if top (min top y) y)
                    right (max (or right 0) (+ x width))
                    bottom (1+ y)))
            (cl-incf x width)))))
    (when left (list left top right bottom))))

(defun etaf-screensaver--glyph-font-stack ()
  "Return the frame's configured font stack for Latin and CJK text.
Resolve both through the active fontset, so an enlarged glyph uses the same
fonts the buffer text uses instead of a family chosen by the application."
  (let* ((latin (face-attribute 'default :family nil t))
         (cjk (let ((font (and (fboundp 'internal-char-font)
                               (internal-char-font nil #x4e2d))))
                (setq font (car-safe font))
                (and (fontp font) (font-get font :family))))
         (families (delete-dups (delq nil (mapcar (lambda (family) (format "%s" family))
                                                  (list latin cjk))))))
    (mapconcat #'identity families ", ")))

(defun etaf-screensaver--glyph-slices (char face scale metrics cache)
  "Return CHAR's immutable display slices in FACE at SCALE using METRICS.
Colors come from the displaying character's face, not the image descriptor.
CACHE keeps at most 64 shapes for the current font/scale geometry."
  (let* ((bold (memq (etaf-screensaver--glyph-attribute face :weight) '(bold semi-bold extra-bold ultra-bold)))
         (italic (memq (etaf-screensaver--glyph-attribute face :slant) '(italic oblique)))
         (decoration (mapconcat #'identity
                                (delq nil (list (and (etaf-screensaver--glyph-attribute face :underline) "underline")
                                                (and (etaf-screensaver--glyph-attribute face :strike-through) "line-through")
                                                (and (etaf-screensaver--glyph-attribute face :overline) "overline"))) " "))
         (key (list char bold italic decoration))
         (slices (gethash key cache)))
    (unless slices
      (let* ((cells (max 1 (char-width char)))
             (width (* scale cells (plist-get metrics :char-width)))
             (height (* scale (plist-get metrics :line-height)))
             ;; Size the glyph in pixels so it fits its cell box: a wide
             ;; character is about square, a narrow one about 0.6 em wide.
             ;; Points would overflow the box and clip to a sliver.
             (font-size (min (* height .92)
                             (/ width (if (> cells 1) 1.0 .62))))
             (svg (svg-create width height)))
        (svg-text svg (char-to-string char) :x 0
                  :y (/ (* height (plist-get metrics :ascent)) 100.0)
                  :font-family (plist-get metrics :family)
                  :font-size font-size
                  :font-weight (if bold "bold" "normal")
                  :font-style (if italic "italic" "normal")
                  :text-decoration decoration :fill "currentColor")
        (let ((image (svg-image svg :scale 1 :ascent (plist-get metrics :ascent)
                                :max-width width :max-height height))
              (line-height (plist-get metrics :line-height)))
          (setq slices (vconcat (cl-loop for row below scale
                                         collect (list (list 'slice 0 (* row line-height) width line-height) image)))))
        ;; At the bound, keep live entries and compute a transient shape for
        ;; this frame; clearing would rebuild every shape on every frame.
        (when (< (hash-table-count cache) 64) (puthash key slices cache))))
    slices))

(defun etaf-screensaver--glyph-subject (rows focus)
  "Return FOCUS's settled characters in ROWS as a hash set.
Only these characters grow; transient effect glyphs stay at native size."
  (let ((chars (make-hash-table :test #'eq)))
    (cl-loop for y from (nth 1 focus) below (nth 3 focus)
             while (< y (length rows))
             do (let ((row (aref rows y)) (x 0))
                  (dotimes (i (length row))
                    (let* ((char (aref row i)) (width (char-width char)))
                      (when (and (> width 0) (>= x (nth 0 focus))
                                 (< x (nth 2 focus)) (not (memq char '(?\s ?\t))))
                        (puthash char t chars))
                      (cl-incf x width)))))
    chars))

(defun etaf-screensaver--glyph-color-luma (color)
  "Return the luminance of a #RRGGBB COLOR, or 0 when it is not a color."
  (save-match-data
    (if (and (stringp color)
             (string-match "\\`#\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\'" color))
        (+ (* .299 (string-to-number (match-string 1 color) 16))
           (* .587 (string-to-number (match-string 2 color) 16))
           (* .114 (string-to-number (match-string 3 color) 16)))
      0)))

(defun etaf-screensaver--glyph-subject-ink (frames background)
  "Return the recording colour in FRAMES that contrasts most with BACKGROUND.
One fixed ink avoids re-rasterizing glyphs at every step of a colour fade; the
choice follows the page, so paper pages take dark ink and dark pages bright
ink.  FRAMES is sampled sparsely, keeping the scan to a few milliseconds."
  (save-match-data
    (let ((bg-luma (etaf-screensaver--glyph-color-luma background))
          (ink nil) (best -1) (index 0) (length (length frames)))
      (while (and (< index length) (< index 2400))
        (let ((frame (aref frames index)) (position 0))
          (when (stringp frame)
            (while (string-match "\e\\[38;2;\\([0-9]+\\);\\([0-9]+\\);\\([0-9]+\\)m"
                                 frame position)
              (let* ((color (format "#%02x%02x%02x"
                                    (string-to-number (match-string 1 frame))
                                    (string-to-number (match-string 2 frame))
                                    (string-to-number (match-string 3 frame))))
                     (distance (abs (- (etaf-screensaver--glyph-color-luma color)
                                       bg-luma))))
                (setq position (match-end 0))
                (when (> distance best)
                  (setq best distance ink color))))))
        (setq index (+ index 7)))
      ink)))

(defun etaf-screensaver--glyph-quantize-color (color)
  "Return COLOR snapped to a small palette step, or nil.
An animated fade otherwise re-rasterizes every SVG glyph on each step; eight
levels per channel keep the motion while bounding recolouring work."
  (when (and (stringp color) (string-match "\\`#\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\'" color))
    (let ((levels (lambda (index)
                    (let ((value (/ (string-to-number (match-string index color) 16) 32.0)))
                      (* 36 (round value))))))
      (format "#%02x%02x%02x" (funcall levels 1) (funcall levels 2) (funcall levels 3)))))

(defun etaf-screensaver--glyph-runs (char face scale metrics shapes paints)
  "Return immutable styled slice strings for CHAR and FACE.
SHAPES caches geometry; PAINTS keeps at most 512 styled glyphs, separately
from the shape's native image so color changes never rebuild its SVG."
  (let* ((ink (or (plist-get metrics :ink)
                  (etaf-screensaver--glyph-quantize-color
                   (etaf-screensaver--glyph-attribute face :foreground))))
         (face (if ink (list :foreground ink) face))
         (key (cons char face))
         (runs (gethash key paints)))
    (unless runs
      (let* ((width (char-width char)) (span (* width scale))
             (slices (unless (= char ?\s) (etaf-screensaver--glyph-slices char face scale metrics shapes))))
        (setq runs (make-vector scale nil))
        (dotimes (slice scale)
          (let ((text (if (= slice 0)
                          (concat (char-to-string char) (make-string (- span width) ?\s))
                        (make-string span ?\s))))
            (when face (put-text-property 0 (length text) 'face face text))
            (when slices (put-text-property 0 (length text) 'display (aref slices slice) text))
            (aset runs slice text)))
        (when (< (hash-table-count paints) 512) (puthash key runs paints))))
    runs))

(defun etaf-screensaver--glyph-compose-row (base runs columns)
  "Overlay RUNS on BASE row and fit the result to COLUMNS display cells.
RUNS is a list of (START . TEXT) with nonoverlapping column spans.  Text the
work already draws in those cells keeps its native size; only the enlarged
subject replaces it."
  (let ((position 0) pieces)
    (dolist (run runs)
      (when (< position (car run))
        (push (etaf-screensaver--presentation-crop
               base (- (car run) position) position)
              pieces))
      (push (cdr run) pieces)
      (setq position (+ (car run) (string-width (cdr run)))))
    (when (< position columns)
      (push (etaf-screensaver--presentation-crop base (- columns position) position)
            pieces))
    (apply #'concat (nreverse pieces))))

(defun etaf-screensaver--glyph-rows (source focus columns rows scale metrics cache paints subject base)
  "Enlarge SOURCE's FOCUS over BASE, retaining the surrounding animation.
Fit into COLUMNS by ROWS with SCALE-cell glyphs.  METRICS, bounded shape
CACHE and styled PAINTS belong to this geometry.  Never alter source rows.
Native glyphs outside the focus stay in the enlarged block; only cells the
subject occupies are replaced."
  (let* ((source-columns (- (nth 2 focus) (nth 0 focus)))
         (source-rows (- (nth 3 focus) (nth 1 focus)))
         (source-left (nth 0 focus))
         (source-top (nth 1 focus))
         (left (/ (- columns (* source-columns scale)) 2))
         (top (/ (- rows (* source-rows scale)) 2))
         (right (+ left (* source-columns scale)))
         (bottom (+ top (* source-rows scale)))
         (base (vconcat base))
         (output (make-vector rows nil))
         (ends (make-vector rows left)))
    (dotimes (row source-rows)
      (let ((y (+ source-top row)))
        (when (and (>= y 0) (< y (length source)))
          (let ((text (aref source y)) (column 0))
            (dotimes (index (length text))
              (let* ((char (aref text index)) (width (char-width char))
                     (x (+ left (* (- column source-left) scale)))
                     (span (* width scale))
                     (face (get-text-property index 'face text)))
                (when (and (> width 0) (>= column source-left)
                           (<= (+ column width) (nth 2 focus))
                           (>= x left) (<= (+ x span) right)
                           (gethash char subject))
                  (let ((runs (etaf-screensaver--glyph-runs char face scale metrics cache paints)))
                    (dotimes (slice scale)
                      (let* ((row (+ top (* row scale) slice))
                             (end (aref ends row)))
                        (when (>= x end)
                          (push (cons x (aref runs slice)) (aref output row))
                          (aset ends row (+ x span)))))))
                (cl-incf column width)))))))
    (cl-loop for y below rows
             for runs = (aref output y)
             collect (if (or (< y top) (>= y bottom)) (aref base y)
                       (etaf-screensaver--glyph-compose-row
                        (aref base y) (nreverse runs) columns)))))

(provide 'etaf-screensaver-glyphs)
;;; etaf-screensaver-glyphs.el ends here
