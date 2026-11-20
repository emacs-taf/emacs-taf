;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-board.el --- Battlefield canvas: native frames or a text grid
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; This module owns the game's display geometry and its fallback text
;; battlefield.  The native frame canvas is GameKit's
;; `etaf-gamekit-frame-canvas': Godot draws the battlefield at the display's
;; device resolution and writes it as strips one text line tall, and GameKit
;; shows each changed strip as the image of one line of the board's Text
;; Host.  Text displays draw the published world description as two
;; characters per block instead.

;;; Code:
(require 'cl-lib)
(require 'etaf)

(defconst etaf-tanks--block-sizes '((small . 12) (medium . 16) (large . 20))
  "Preferred logical pixels per map block for each board size.")

(defconst etaf-tanks--smallest-block 10
  "Smallest block in logical pixels; a narrower window clips the board.")

(defun etaf-tanks--metrics (graphic)
  "Return reactive display metrics; GRAPHIC selects native frames.
DENSITY is the device pixels per logical pixel the native canvas draws for."
  (append (list :graphic graphic
                :density (if (and graphic (fboundp 'frame-scale-factor))
                             (max 1 (round (frame-scale-factor))) 1))
          (etaf-display-metrics)))

(defun etaf-tanks--fit-block (size preferred width height)
  "Return the logical block pixels showing SIZE blocks within WIDTH x HEIGHT.
The block starts at PREFERRED and shrinks by two pixels until the board fits
or reaches `etaf-tanks--smallest-block', below which the viewport clips."
  (let ((block preferred))
    (while (and (> block etaf-tanks--smallest-block)
                (or (> (* (car size) block) width) (> (* (cadr size) block) height)))
      (cl-decf block 2))
    block))

(defun etaf-tanks--board-geometry (size metrics block)
  "Return the canvas geometry for SIZE blocks of BLOCK pixels under METRICS.
DEVICE-BLOCK and DEVICE-LINE are what the native canvas draws a block and a
strip in; both are even, so half blocks stay on whole device pixels."
  (if (plist-get metrics :graphic)
      (let* ((density (plist-get metrics :density)) (line (plist-get metrics :line-height))
             (width (* (car size) block)) (height (* (cadr size) block)))
        (list :graphic t :block block :density density
              :device-block (* block density) :device-line (* line density)
              :pixel-width width :pixel-height height
              :columns (ceiling width (float (plist-get metrics :char-width)))
              :rows (ceiling height (float line)) :line-height line
              :ascent (plist-get metrics :ascent)))
    (list :graphic nil :columns (* 2 (car size)) :rows (cadr size))))

;;; Text grid

(defconst etaf-tanks--text-palettes
  '((dark :ground ("#101010" . "#101010") :brick ("#E07A3A" . "#5A2410") :steel ("#E8E8E8" . "#8A8A8A")
          :water ("#9CC4FF" . "#1E46B4") :forest ("#9AE05A" . "#1C5A1C") :ice ("#FFFFFF" . "#9FBCCB")
          :base ("#F0F0F0" . "#303030") :ruin ("#A0A0A0" . "#303030") :player ("#FFD23C" . "#101010")
          :enemy ("#E8E8E8" . "#101010") :armor ("#FF8A8A" . "#101010") :shell ("#FFFFFF" . "#101010")
          :bonus ("#FF6060" . "#FFFFFF") :cursor ("#101010" . "#FFD23C"))
    (light :ground ("#F2EFE6" . "#F2EFE6") :brick ("#F7B57A" . "#A6461C") :steel ("#4A4A4A" . "#B8B8B8")
           :water ("#E0ECFF" . "#3C6AD2") :forest ("#E4FFD2" . "#3C8A2E") :ice ("#7A8F9A" . "#DCEAF0")
           :base ("#202020" . "#D8D2C4") :ruin ("#7A7A7A" . "#D8D2C4") :player ("#B07A00" . "#F2EFE6")
           :enemy ("#3A3A3A" . "#F2EFE6") :armor ("#C03030" . "#F2EFE6") :shell ("#202020" . "#F2EFE6")
           :bonus ("#FFFFFF" . "#E04040") :cursor ("#F2EFE6" . "#202020")))
  "Foreground and background pairs for the text battlefield.")

(defconst etaf-tanks--terrain-glyphs
  '((?. "  " :ground) (?# "▓▓" :brick) (?@ "██" :steel) (?~ "≈≈" :water) (?* "♣♣" :forest)
    (?= "░░" :ice) (?H "◆◆" :base) (?X "▒▒" :ruin) (?P "  " :ground) (?E "··" :ground))
  "Two-character text cell and palette role of each map symbol.")

(defun etaf-tanks--facing-glyph (facing)
  "Return the text glyph for FACING."
  (pcase facing ("n" "▲▲") ("e" "▶▶") ("s" "▼▼") (_ "◀◀")))

(defun etaf-tanks--text-board (rows theme &optional world cursor)
  "Return text drawing terrain ROWS in THEME with WORLD units and CURSOR.
ROWS are map strings; WORLD is the published world plist; CURSOR is
(X Y SIZE) in blocks.  Each block is two characters; a tank covers 2x2
blocks.  Forest hides tanks below it, as on the graphical canvas."
  (let* ((palette (alist-get theme etaf-tanks--text-palettes))
         (height (length rows)) (width (length (car rows)))
         (cells (make-vector (* width height) nil)))
    (cl-loop for row in rows for y from 0 do
             (dotimes (x width)
               (let ((glyph (assq (aref row x) etaf-tanks--terrain-glyphs)))
                 (aset cells (+ (* y width) x) (cons (cadr glyph) (nth 2 glyph))))))
    (let ((put (lambda (x y text role)
                 (when (and (<= 0 x) (< x width) (<= 0 y) (< y height)
                            (not (eq (cdr (aref cells (+ (* y width) x))) :forest)))
                   (aset cells (+ (* y width) x) (cons text role))))))
      (dolist (unit (plist-get world :units))
        (let ((x (round (plist-get unit :x))) (y (round (plist-get unit :y)))
              (glyph (etaf-tanks--facing-glyph (plist-get unit :facing)))
              (role (cond ((equal (plist-get unit :kind) "player") :player)
                          ((eq t (plist-get unit :bonus)) :bonus)
                          ((equal (plist-get unit :type) "armor") :armor)
                          (t :enemy))))
          (dotimes (dy 2) (dotimes (dx 2) (funcall put (+ x dx) (+ y dy) glyph role)))))
      (dolist (shell (plist-get world :shells))
        (funcall put (floor (plist-get shell :x)) (floor (plist-get shell :y)) "• " :shell))
      (when-let* ((bonus (plist-get world :bonus)))
        (let ((x (floor (plist-get bonus :x))) (y (floor (plist-get bonus :y))))
          (dotimes (dy 2) (dotimes (dx 2) (funcall put (+ x dx) (+ y dy) "★★" :bonus))))))
    (when cursor
      (cl-destructuring-bind (cx cy size) cursor
        (dotimes (dy size)
          (dotimes (dx size)
            (let ((x (+ cx dx)) (y (+ cy dy)))
              (when (and (< x width) (< y height))
                (setcdr (aref cells (+ (* y width) x)) :cursor)))))))
    (mapconcat
     (lambda (y)
       (let ((parts nil) (run nil) (role nil))
         (dotimes (x width)
           (let ((cell (aref cells (+ (* y width) x))))
             (unless (eq (cdr cell) role)
               (when run (push (etaf-tanks--text-run (apply #'concat (nreverse run)) role palette) parts))
               (setq run nil role (cdr cell)))
             (push (car cell) run)))
         (push (etaf-tanks--text-run (apply #'concat (nreverse run)) role palette) parts)
         (apply #'concat (nreverse parts))))
     (number-sequence 0 (1- height)) "\n")))

(defun etaf-tanks--text-run (text role palette)
  "Paint TEXT with ROLE's colors from PALETTE."
  (let ((colors (plist-get palette role)))
    (propertize text 'face (list :foreground (car colors) :background (cdr colors)))))

(provide 'etaf-tanks-board)
;;; etaf-tanks-board.el ends here
