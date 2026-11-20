;;; etaf-ui-sheet-gui.el --- GUI check of the sheet's pointer mapping  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verify `etaf-sheet-cell-at' on a mounted sheet: the same x/y to cell
;; mapping a pointer press uses.  Run it in a graphical Emacs with
;; `emacs -l scripts/etaf-ui-sheet-gui.el -f etaf-ui-sheet-gui-check';
;; it prints the result and exits nonzero when a position maps wrong.

;;; Code:
(require 'cl-lib)
(require 'etaf-ui)

(defconst etaf-ui-sheet-gui--rows 1000)
(defconst etaf-ui-sheet-gui--widths (vector 8 8 8 8 8 8 8))

(defun etaf-ui-sheet-gui--cell-text (row col)
  "Return the six-cell text of ROW and COL."
  (format "%03d.%02d" row col))

(defun etaf-ui-sheet-gui--mount ()
  "Show a check sheet in the selected window and return its handles."
  (let* ((cursor (etaf-ref (cons 0 0) :test #'equal))
         (heights (make-hash-table :test 'eql))
         (buffer (switch-to-buffer (get-buffer-create "*sheet pointer check*"))))
    (puthash 2 1 heights)
    (etaf-mount
     buffer
     (etaf-view
      (etaf-sheet :rows etaf-ui-sheet-gui--rows
                  :columns (length etaf-ui-sheet-gui--widths)
                  :widths etaf-ui-sheet-gui--widths
                  :heights heights :height 24
                  :cursor cursor :header t :row-head t
                  :ref 'sheet-gui :label "Sheet check"
                  :cell-text #'etaf-ui-sheet-gui--cell-text
                  :on-commit #'ignore)))
    (etaf-runtime-refit (etaf-runtime-for-buffer buffer) 900 30)
    (list :buffer buffer :runtime (etaf-runtime-for-buffer buffer)
          :cursor cursor)))

(defun etaf-ui-sheet-gui--point-of (buffer row col)
  "Return the buffer position where ROW and COL's text starts in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward (etaf-ui-sheet-gui--cell-text row col) nil t)
        (match-beginning 0)))))

(defun etaf-ui-sheet-gui-check ()
  "Assert the sheet maps a grid of pixel positions to the right cells.
Return (:checked N :failures LIST); from the command line print the result and
exit with a nonzero status when a position maps wrong."
  (unless (display-graphic-p)
    (error "The sheet pointer check needs a graphical frame"))
  (let* ((window (selected-window))
         (sheet (etaf-ui-sheet-gui--mount))
         (runtime (plist-get sheet :runtime))
         (buffer (plist-get sheet :buffer))
         (line-height (or (plist-get (etaf-display-metrics runtime) :line-height) 16))
         (failures nil)
         (checked 0))
    (unwind-protect
        (progn
          (redisplay t)
          (cl-labels
              ((check (row col)
                 "Check the pixel a pointer lands on inside ROW and COL."
                 (let ((pos (etaf-ui-sheet-gui--point-of buffer row col)))
                   (when pos
                     (cl-incf checked)
                     (let* ((xy (posn-x-y (posn-at-point pos)))
                            (found (etaf-sheet-cell-at runtime 'sheet-gui
                                                       (1+ (car xy))
                                                       (+ (cdr xy) (/ line-height 2)))))
                       (unless (equal found (cons row col))
                         (push (list :expected (cons row col) :found found
                                     :at (cons (1+ (car xy))
                                               (+ (cdr xy) (/ line-height 2))))
                               failures)))))))
            (dolist (row '(0 1 2 3 4 5 6 8 10))
              (dolist (col '(0 1 2 3 4 5 6))
                (check row col)))
            (etaf-sheet-scroll runtime 'sheet-gui 10)
            (redisplay t)
            (dolist (row '(10 11 12 14 16))
              (dolist (col '(0 2 4))
                (check row col))))
          (when noninteractive
            (princ (format "sheet pointer check: %d positions, %d failures%s\n"
                           checked (length failures)
                           (if failures
                               (concat "\n"
                                       (mapconcat (lambda (f) (format "%S" f))
                                                  (nreverse failures) "\n"))
                             "")))))
      (when-let* ((mounted (etaf-runtime-for-buffer buffer)))
        (etaf-unmount mounted))
      (when (window-live-p window) (select-window window)))
    (when noninteractive (kill-emacs (if failures 1 0)))
    (list :checked checked :failures (nreverse failures))))

(provide 'etaf-ui-sheet-gui)
;;; etaf-ui-sheet-gui.el ends here
