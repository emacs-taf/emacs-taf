;;; etaf-measure.el --- Text measurement for applications -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The renderer measures text with its own fonts and text properties, and an
;; application that aligns content to glyph widths needs the same number.
;; This module is the ETAF adapter for that measurement: the Ebox measure
;; layer owns the algorithm, and this interface is the one applications and
;; catalog components use.

;;; Code:

(require 'ebox)

;;;###autoload
(defun etaf-string-pixel-width (string)
  "Return the display pixel width of STRING's first line.
The measure honors STRING's `face' and `display' properties, so styled text
and plain text can measure differently.  Only the first line is measured: a
newline ends the measurement, and an empty string is zero.  A non-string
signals `wrong-type-argument'."
  (unless (stringp string)
    (signal 'wrong-type-argument (list 'stringp string)))
  (ebox-string-pixel-width string))

(provide 'etaf-measure)
;;; etaf-measure.el ends here
