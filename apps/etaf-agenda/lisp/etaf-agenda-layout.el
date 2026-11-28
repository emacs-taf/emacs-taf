;;; etaf-agenda-layout.el --- Responsive layout table and geometry of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Single source of truth for responsive breakpoints, pane widths, column
;; budgets and string-width clipping.  Both views and interactive handlers read
;; from here so calendar grids, lists, rails and narrow screens never drift.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)

(defconst etaf-agenda-wide-min-cols 126
  "Minimum columns for the three-pane layout (sidebar + main + right rail).")

(defconst etaf-agenda-medium-min-cols 88
  "Minimum columns for the two-pane layout (main + right rail).")

(defconst etaf-agenda-short-max-rows 25
  "Maximum window rows considered a short viewport.")

(defconst etaf-agenda-default-sidebar-cols 24
  "Default column width of the left navigation sidebar.")

(defconst etaf-agenda-default-rail-cols 32
  "Default column width of the right context / inspector rail.")

(defun etaf-agenda-layout-tier (columns)
  "Return layout tier symbol (`wide', `medium' or `narrow') for COLUMNS."
  (cond ((>= columns etaf-agenda-wide-min-cols) 'wide)
        ((>= columns etaf-agenda-medium-min-cols) 'medium)
        (t 'narrow)))

(defun etaf-agenda-layout-metrics (columns rows sidebar-cols rail-cols inspector-open)
  "Compute the resolved layout plist for viewport COLUMNS x ROWS.
SIDEBAR-COLS and RAIL-COLS are user-preferred widths; INSPECTOR-OPEN is non-nil
when the entry inspector is active."
  (let* ((cols (max 40 (or columns 128)))
         (rws (max 12 (or rows 36)))
         (tier (etaf-agenda-layout-tier cols))
         (short-p (<= rws etaf-agenda-short-max-rows))
         (show-sidebar (eq tier 'wide))
         (show-rail (or (memq tier '(wide medium)) inspector-open))
         (show-main (or (not (eq tier 'narrow)) (not inspector-open)))
         (sb-w (if show-sidebar
                   (max 18 (min 34 (or sidebar-cols etaf-agenda-default-sidebar-cols)))
                 0))
         (rl-w (cond
                ((not show-rail) 0)
                ((eq tier 'narrow) cols)
                ((eq tier 'medium)
                 (max 22 (min 28 (or rail-cols 28))))
                (t (max 22 (min 40 (or rail-cols etaf-agenda-default-rail-cols))))))
         (dividers (+ (if show-sidebar 1 0)
                      (if (and show-rail show-main) 1 0)))
         (center-w (if show-main
                       (max 24 (- cols sb-w rl-w dividers))
                     0))
         ;; Keep a cohesive reading measure on ultra-wide frames while giving
         ;; the 7-column calendar full width.  Content (titles, hairlines,
         ;; section heads and the selection bar `▎') all start flush at Col 0
         ;; inside center-pad — zero overhang past titles on any viewport!
         (center-pad (cond ((memq tier '(narrow medium)) 2)
                           ((> center-w 114) (min 10 (+ 3 (/ (- center-w 106) 2))))
                           (t 3)))
         (cal-pad (if (eq tier 'narrow) 1 2))
         (inner-w (max 20 (- center-w (* 2 center-pad))))
         (cal-inner-w (max 28 (- center-w (* 2 cal-pad))))
         (topbar-rows (if (eq tier 'narrow) (if short-p 3 4) (if short-p 2 3)))
         (footer-rows 1)
         (body-rows (max 6 (- rws topbar-rows footer-rows)))
         ;; Calendar: 7 equal columns inside cal-inner-w (minus 2 border cells)
         (cal-cell-w (max 6 (/ (max 42 (- cal-inner-w 2)) 7)))
         ;; Week rows height inside body-rows minus top/bottom pad(2), header(2), weekday-head(1).
         ;; No artificial upper ceiling so tall windows fill down to 1 empty row above the footer.
         (cal-week-lines (max 3 (/ (max 18 (- body-rows 5)) 6))))
    (list :tier tier
          :short short-p
          :columns cols
          :rows rws
          :show-sidebar show-sidebar
          :show-main show-main
          :show-rail show-rail
          :sidebar-cols sb-w
          :rail-cols rl-w
          :center-cols center-w
          :center-pad center-pad
          :cal-pad cal-pad
          :inner-cols inner-w
          :cal-inner-cols cal-inner-w
          :topbar-rows topbar-rows
          :footer-rows footer-rows
          :body-rows body-rows
          :cal-cell-cols cal-cell-w
          :cal-week-lines cal-week-lines)))

(defun etaf-agenda-clip-text (text max-cols)
  "Clip TEXT to at most MAX-COLS display columns using real `char-width'.
Appends an ellipsis when truncated."
  (let ((str (or text "")))
    (if (or (null max-cols) (<= max-cols 0) (<= (string-width str) max-cols))
        str
      (let ((used 0)
            (limit (max 1 (1- max-cols)))
            (chars nil)
            (truncated nil))
        (cl-loop for ch across str
                 for cw = (max 0 (char-width ch))
                 do (if (> (+ used cw) limit)
                        (progn (setq truncated t) (cl-return))
                      (setq used (+ used cw))
                      (push ch chars)))
        (if truncated
            (concat (string-trim-right (apply #'string (nreverse chars))) "…")
          str)))))

(defun etaf-agenda-layout-year-columns (cal-inner-w &optional char-px)
  "Return the number of month cards per row (4, 3 or 2) for CAL-INNER-W.
On text terminals where CHAR-PX is 1, each 1px card border occupies a full
character cell so four cards need slightly more horizontal room to keep
day numbers separated cleanly."
  (let ((tty-p (<= (or char-px 8) 1)))
    (cond ((>= cal-inner-w (if tty-p 102 86)) 4)
          ((>= cal-inner-w (if tty-p 76 64)) 3)
          (t 2))))

(defun etaf-agenda-plan-char-px (plan &optional runtime)
  "Return effective pixels per character cell for PLAN and RUNTIME.
Distinguishes graphical/pixel viewports from text-cell viewports even in batch."
  (let* ((w-px (plist-get plan :width-px))
         (cols (plist-get plan :width))
         (plan-px (if (and (numberp w-px) (numberp cols) (> cols 0))
                      (max 1 (/ w-px cols))
                    1))
         (rt-px (or (when-let* ((m (and runtime (ignore-errors (etaf-display-metrics runtime)))))
                      (plist-get m :char-width))
                    1)))
    (max rt-px plan-px)))

(defun etaf-agenda-char-pixel-width (runtime &optional window)
  "Return the effective pixel width of one character cell on RUNTIME or WINDOW.
Reads `etaf-display-metrics' so text scaling is respected."
  (or (when-let* ((metrics (and runtime (ignore-errors (etaf-display-metrics runtime)))))
        (plist-get metrics :char-width))
      (when (window-live-p window)
        (max 1 (/ (window-body-width window t)
                  (max 1 (window-body-width window)))))
      8))

(provide 'etaf-agenda-layout)
;;; etaf-agenda-layout.el ends here
