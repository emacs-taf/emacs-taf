;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-ansi.el --- SGR frames to canvas faces

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Imported recordings may carry ANSI SGR runs for color and attributes.
;; The canvas colors cells with a `face' text property, so this module turns
;; SGR runs into that same property and reports which color depths and
;; attributes a frame uses.  Only SGR sequences are interpreted; a provider
;; rejects every other control sequence before frames reach the canvas.

;;; Code:
(require 'cl-lib)

(defconst etaf-screensaver--ansi-sgr-regexp "\x1b\\[\\([0-9;]*\\)m"
  "Regular expression matching one SGR sequence; group 1 holds its parameters.")

(defconst etaf-screensaver--ansi-colors
  ["#000000" "#cd0000" "#00cd00" "#cdcd00" "#0000ee" "#cd00cd" "#00cdcd" "#e5e5e5"
   "#7f7f7f" "#ff0000" "#00ff00" "#ffff00" "#5c5cff" "#ff00ff" "#00ffff" "#ffffff"]
  "The 16 ANSI colors as true-color equivalents.")

(defun etaf-screensaver--ansi-256-color (number)
  "Return xterm color NUMBER (0..255) as an #RRGGBB string, or nil."
  (cond
   ((and (>= number 0) (< number 16)) (aref etaf-screensaver--ansi-colors number))
   ((and (>= number 16) (< number 232))
    (let* ((index (- number 16))
           (red (/ index 36))
           (green (% (/ index 6) 6))
           (blue (% index 6))
           (level (lambda (value) (if (zerop value) 0 (+ 55 (* 40 value))))))
      (format "#%02x%02x%02x" (funcall level red) (funcall level green) (funcall level blue))))
   ((and (>= number 232) (<= number 255))
    (let ((level (+ 8 (* 10 (- number 232)))))
      (format "#%02x%02x%02x" level level level)))
   (t nil)))

(defun etaf-screensaver--ansi-numbers (text start end)
  "Read semicolon-separated SGR numbers in TEXT's START..END range.
Return a vector of integers, with nil for empty fields, without token strings."
  (let ((number 0) digits numbers)
    (while (< start end)
      (let ((character (aref text start)))
        (if (= character ?\;)
            (progn (push (and digits number) numbers)
                   (setq number 0 digits nil))
          (setq number (+ (* number 10) (- character ?0)) digits t)))
      (cl-incf start))
    (push (and digits number) numbers)
    (vconcat (nreverse numbers))))

(defun etaf-screensaver--ansi-number (numbers index)
  "Return NUMBERS' INDEX value, defaulting an absent or empty field to zero."
  (or (and (< index (length numbers)) (aref numbers index)) 0))

(defun etaf-screensaver--ansi-update (face text start end)
  "Apply TEXT's START..END SGR range to a fresh copy of FACE.
An empty range resets all attributes.  Previously emitted runs keep their
own face values when a later sequence changes or removes an attribute."
  (unless (= start end)
    (let ((tokens (etaf-screensaver--ansi-numbers text start end))
          (face (copy-sequence face))
          (index 0))
      (while (< index (length tokens))
        (let ((value (aref tokens index)))
          (when value
              (cond
               ((= value 0) (setq face nil))
               ((= value 1) (setq face (plist-put face :weight 'bold)))
               ((= value 2) (setq face (plist-put face :weight 'light)))
               ((= value 3) (setq face (plist-put face :slant 'italic)))
               ((= value 4) (setq face (plist-put face :underline t)))
               ((= value 7) (setq face (plist-put face :inverse-video t)))
               ((= value 9) (setq face (plist-put face :strike-through t)))
               ((= value 22) (cl-remf face :weight))
               ((= value 23) (cl-remf face :slant))
               ((= value 24) (cl-remf face :underline))
               ((= value 27) (cl-remf face :inverse-video))
               ((= value 29) (cl-remf face :strike-through))
               ((and (>= value 30) (<= value 37))
                (setq face (plist-put face :foreground
                                      (aref etaf-screensaver--ansi-colors (- value 30)))))
               ((= value 39) (cl-remf face :foreground))
               ((and (>= value 40) (<= value 47))
                (setq face (plist-put face :background
                                      (aref etaf-screensaver--ansi-colors (- value 40)))))
               ((= value 49) (cl-remf face :background))
               ((and (>= value 90) (<= value 97))
                (setq face (plist-put face :foreground
                                      (aref etaf-screensaver--ansi-colors (- value 82)))))
               ((and (>= value 100) (<= value 107))
                (setq face (plist-put face :background
                                      (aref etaf-screensaver--ansi-colors (- value 92)))))
               ((or (= value 38) (= value 48))
                (let ((slot (if (= value 38) :foreground :background))
                      (kind (etaf-screensaver--ansi-number tokens (1+ index))))
                  (cond
                   ((= kind 5)
                    (when-let* ((color (etaf-screensaver--ansi-256-color
                                        (etaf-screensaver--ansi-number tokens (+ index 2)))))
                      (setq face (plist-put face slot color))
                      (cl-incf index 2)))
                   ((= kind 2)
                    (let ((red (etaf-screensaver--ansi-number tokens (+ index 2)))
                          (green (etaf-screensaver--ansi-number tokens (+ index 3)))
                          (blue (etaf-screensaver--ansi-number tokens (+ index 4))))
                      (when (and (<= 0 red 255) (<= 0 green 255) (<= 0 blue 255))
                        (setq face (plist-put face slot
                                              (format "#%02x%02x%02x" red green blue)))
                        (cl-incf index 4))))))))))
        (cl-incf index))
      face)))

(defun etaf-screensaver--ansi-run (text start end face)
  "Return TEXT's START..END substring carrying FACE, or plain text."
  (let ((chunk (substring text start end)))
    (when face (put-text-property 0 (length chunk) 'face face chunk))
    chunk))

(defun etaf-screensaver--ansi-render (text)
  "Return TEXT with every SGR run converted to a `face' text property."
  (if (not (string-match-p etaf-screensaver--ansi-sgr-regexp text))
      text
    (let ((index 0) (length (length text)) (face nil) (start 0) (parts nil))
      (while (string-match etaf-screensaver--ansi-sgr-regexp text index)
        (let ((begin (match-beginning 0))
              (finish (match-end 0))
              (parameters-start (match-beginning 1))
              (parameters-end (match-end 1)))
          (when (< start begin)
            (push (etaf-screensaver--ansi-run text start begin face) parts))
          (setq face (etaf-screensaver--ansi-update face text parameters-start parameters-end)
                start finish
                index finish)))
      (when (< start length)
        (push (etaf-screensaver--ansi-run text start length face) parts))
      (apply #'concat (nreverse parts)))))

(defun etaf-screensaver--ansi-strip (text)
  "Return TEXT without SGR sequences."
  (if (string-match-p etaf-screensaver--ansi-sgr-regexp text)
      (replace-regexp-in-string etaf-screensaver--ansi-sgr-regexp "" text)
    text))

(defun etaf-screensaver--ansi-features-from-parameters (parameters)
  "Classify the semicolon-separated SGR PARAMETERS string.
Return a plist with :colors, most capable first, among `truecolor',
`256-color' and `16-color', and :attributes for the modifiers that appear."
  (let ((tokens (etaf-screensaver--ansi-numbers parameters 0 (length parameters)))
        (position 0) (truecolor nil) (color-256 nil) (color-16 nil) (attributes nil))
    (unless (equal parameters "")
      (while (< position (length tokens))
        (let ((value (etaf-screensaver--ansi-number tokens position)))
          (cond
           ((and (>= value 30) (<= value 37)) (setq color-16 t))
           ((and (>= value 40) (<= value 47)) (setq color-16 t))
           ((and (>= value 90) (<= value 97)) (setq color-16 t))
           ((and (>= value 100) (<= value 107)) (setq color-16 t))
           ((or (= value 38) (= value 48))
            (let ((kind (etaf-screensaver--ansi-number tokens (1+ position))))
              (cond ((= kind 5) (setq color-256 t))
                    ((= kind 2) (setq truecolor t)))))
           ((memq value '(1 2 3 4 7 9))
            (cl-pushnew (pcase value (1 'bold) (2 'faint) (3 'italic)
                          (4 'underline) (7 'inverse) (9 'strike-through))
                        attributes)))
          (cl-incf position))))
    (list :colors (delq nil (list (and truecolor 'truecolor)
                                  (and color-256 '256-color)
                                  (and color-16 '16-color)))
          :attributes attributes)))

(defun etaf-screensaver--ansi-features (text)
  "Return a plist describing the SGR runs in TEXT.
:colors is a list, most capable first, of symbols among `truecolor',
`256-color' and `16-color'; :attributes lists the modifiers that appear."
  (let ((index 0) (colors nil) (attributes nil))
    (while (string-match etaf-screensaver--ansi-sgr-regexp text index)
      (let ((parameters (match-string 1 text))
            (finish (match-end 0)))
        (setq index finish)
        (let ((features (etaf-screensaver--ansi-features-from-parameters parameters)))
          (setq colors (append colors (plist-get features :colors))
                attributes (append attributes (plist-get features :attributes))))))
    (list :colors (delete-dups colors) :attributes (delete-dups attributes))))

(provide 'etaf-screensaver-ansi)
;;; etaf-screensaver-ansi.el ends here
