;;; etaf-doc-widgets.el --- Shared editorial document widget primitives -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Shared restrained editorial / booktabs block and leaf widget primitives used
;; by `etaf-md' and `etaf-org': leaf buttons obeying strict leaf-only hover
;; discipline, toggle pills, soft-tinted status badges, inline notice strips,
;; progress bar groups, crisp box-drawing line charts, and single-frame
;; living-doc source cards.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)

(defun etaf-doc-widget--color (palette key &optional fallback)
  "Look up KEY in PALETTE (alist or plist), returning FALLBACK when absent."
  (or (and (consp (car palette)) (cdr (assq key palette)))
      (plist-get palette key)
      fallback))

(defun etaf-doc-widget--accent (palette variant &optional soft)
  "Resolve semantic accent VARIANT in PALETTE (foreground or SOFT fill)."
  (if soft
      (pcase variant
        ('primary (etaf-doc-widget--color palette :accent-soft (etaf-doc-widget--color palette :panel)))
        ('info (etaf-doc-widget--color palette :info-soft (etaf-doc-widget--color palette :accent-soft)))
        ('success (etaf-doc-widget--color palette :ok-soft (etaf-doc-widget--color palette :panel)))
        ('warning (etaf-doc-widget--color palette :warn-soft (etaf-doc-widget--color palette :panel)))
        ('danger (etaf-doc-widget--color palette :danger-soft (etaf-doc-widget--color palette :panel)))
        ('important (etaf-doc-widget--color palette :important-soft (etaf-doc-widget--color palette :panel)))
        (_ (etaf-doc-widget--color palette :panel)))
    (pcase variant
      ('primary (etaf-doc-widget--color palette :accent "#0969da"))
      ('info (etaf-doc-widget--color palette :info (etaf-doc-widget--color palette :accent "#0969da")))
      ('success (etaf-doc-widget--color palette :ok "#2da44e"))
      ('warning (etaf-doc-widget--color palette :warn "#bf8700"))
      ('danger (etaf-doc-widget--color palette :danger "#cf222e"))
      ('important (etaf-doc-widget--color palette :important "#8250df"))
      ('neutral (etaf-doc-widget--color palette :muted "#9198a1"))
      (_ (etaf-doc-widget--color palette :ink "#1f2328")))))

(defun etaf-doc-widget-leaf-button (palette label on-press &rest opts)
  "Return a single-face interactive leaf control styled from PALETTE.
OPTS accepts `:selected', `:disabled', `:keep-pointer', `:color',
`:background', `:role', `:help', `:bold', `:underline', `:hover',
`:hover-variant' (`soft' or default) and `:id'.  Selected or disabled leaves
suppress `:hover-style' so interactive states never stack."
  (let* ((selected (plist-get opts :selected))
         (disabled (plist-get opts :disabled))
         (keep-pointer (plist-get opts :keep-pointer))
         (role (or (plist-get opts :role) 'button))
         (help (plist-get opts :help))
         (id (plist-get opts :id))
         (ref (plist-get opts :ref))
         (underline (plist-get opts :underline))
         (bold (if (plist-member opts :bold) (plist-get opts :bold) selected))
         (hover-enabled (if (plist-member opts :hover) (plist-get opts :hover) t))
         (accent (etaf-doc-widget--color palette :accent "#0969da"))
         (muted (etaf-doc-widget--color palette :muted "#9198a1"))
         (color (or (plist-get opts :color)
                    (cond (disabled (etaf-doc-widget--color palette :faint muted))
                          (selected accent)
                          (t accent))))
         (bg (or (plist-get opts :background)
                 (when selected
                   (etaf-doc-widget--color
                    palette :accent-soft
                    (etaf-doc-widget--color palette :panel2)))))
         (interactive-p (and (not disabled) (functionp on-press)))
         (hover (and interactive-p (not selected) hover-enabled
                     (pcase (plist-get opts :hover-variant)
                       ('soft (etaf-doc-widget--color
                               palette :panel2
                               (etaf-doc-widget--color palette :panel)))
                       (_ (etaf-doc-widget--color
                           palette :accent-soft
                           (etaf-doc-widget--color palette :panel2)))))))
    (etaf-node 'text
               (append
                (list :color color)
                (when id (list :id id))
                (when ref (list :ref ref))
                (when bg (list :background-color bg))
                (when bold (list :font-weight 'bold))
                (when underline (list :text-decoration-line '(underline)))
                (when help (list :help-echo help))
                (when selected (list :aria-selected t))
                (when interactive-p
                  (append
                   (list :role role :tab-index 0 :on-press on-press)
                   (when (or (not selected) keep-pointer)
                     (list :pointer 'hand))))
                (when hover
                  (list :hover-style (list :background-color hover))))
               (list label))))

(defun etaf-doc-widget-pill (palette label active-p on-press &optional help hover-p)
  "Return a compact toggle pill with LABEL styled from PALETTE.
When ACTIVE-P is non-nil, renders in selected fill with no hover; otherwise
renders as a muted clickable leaf with soft hover when HOVER-P (default t)."
  (let* ((accent (etaf-doc-widget--color palette :accent "#0969da"))
         (accent-soft (etaf-doc-widget--color palette :accent-soft
                                              (etaf-doc-widget--color palette :panel)))
         (muted (etaf-doc-widget--color palette :muted "#9198a1"))
         (allow-hover (if (null hover-p) nil t))
         (hover (and (not active-p) allow-hover
                     (etaf-doc-widget--color palette :panel2
                                             (etaf-doc-widget--color palette :panel)))))
    (etaf-node 'text
               (append
                (list :color (if active-p accent muted)
                      :background-color (when active-p accent-soft)
                      :font-weight (when active-p 'bold)
                      :role 'button :tab-index 0
                      :aria-selected (when active-p t)
                      :pointer (unless active-p 'hand)
                      :help-echo help
                      :on-press on-press)
                (when hover (list :hover-style (list :background-color hover))))
               (list (format " %s " label)))))

(defun etaf-doc-widget-status-badge (palette text variant)
  "Return a borderless soft-tinted status pill for TEXT in VARIANT."
  (etaf-node 'text
             (list :color (etaf-doc-widget--accent palette variant nil)
                   :background-color (etaf-doc-widget--accent palette variant t)
                   :font-weight 'bold)
             (list (format " %s " text))))

(defun etaf-doc-widget-notice (palette message &optional variant)
  "Return an inline notice or loading strip for MESSAGE styled from PALETTE.
VARIANT may be `loading' (muted compact text), `danger' (default, left bar +
soft fill), `warning' or `info'."
  (if (eq variant 'loading)
      (etaf-node 'box
                 (list :width 'stretch :padding '((lh 0) (ch 1)))
                 (list (etaf-node 'text (list :color (etaf-doc-widget--color palette :muted "#9198a1"))
                                  (list (or message "正在加载…")))))
    (let* ((v (or variant 'danger))
           (fg (etaf-doc-widget--accent palette v nil))
           (bg (etaf-doc-widget--accent palette v t)))
      (etaf-node 'box
                 (list :width 'stretch :padding '((lh 1) (ch 2))
                       :border-left (list '(px 3) 'solid fg)
                       :background-color bg)
                 (list (etaf-node 'text (list :color fg)
                                  (list (or message "无法加载内容"))))))))

(defun etaf-doc-widget-progress-bars (palette rows available-width &optional options)
  "Render ROWS as a borderless editorial progress bar group from PALETTE.
Each element of ROWS is `(LABEL VALUE MAX PERCENT DISPLAY)'.  OPTIONS accepts
`:title' and `:accent' (accent symbol or color string)."
  (let* ((title (plist-get options :title))
         (accent-opt (or (plist-get options :accent) 'primary))
         (accent-col (if (stringp accent-opt) accent-opt
                       (etaf-doc-widget--accent palette accent-opt nil)))
         (muted (etaf-doc-widget--color palette :muted "#9198a1"))
         (faint (etaf-doc-widget--color palette :faint muted))
         (avail (max 28 (or available-width 80)))
         (lbl-w (min 24 (max 8 (if rows
                                   (apply #'max (mapcar (lambda (r) (string-width (nth 0 r))) rows))
                                 8))))
         (bar-w (max 12 (min 36 (- avail lbl-w 16)))))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0))
     (append
      (when title
        (list (etaf-node 'text (list :font-weight 'bold) (list title))
              (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)))
      (mapcar
       (lambda (r)
         (let* ((lbl (nth 0 r))
                (pct (nth 3 r))
                (disp (nth 4 r))
                (filled (min bar-w (max 0 (round (* bar-w (/ pct 100.0))))))
                (empty (- bar-w filled)))
           (etaf-node
            'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                        :padding '((lh 0) (ch 0)))
            (list
             (etaf-node 'box (list :width (list 'ch lbl-w))
                        (list (etaf-node 'text (list :color muted) (list lbl))))
             (etaf-node 'flex (list :align-items 'center)
                        (delq nil
                              (list
                               (when (> filled 0)
                                 (etaf-node 'text (list :color accent-col)
                                            (list (make-string filled ?█))))
                               (when (> empty 0)
                                 (etaf-node 'text (list :color faint)
                                            (list (make-string empty ?░)))))))
             (etaf-node 'text (list :color muted) (list disp))))))
       rows)))))

(defun etaf-doc-widget-line-chart (palette series available-width &optional options)
  "Render SERIES `((LABEL . NUMBER) ...)' as a zero-wrap box-drawing line chart.
OPTIONS accepts `:label', `:unit', `:accent', `:width', `:height' and
`:mono-family'."
  (let* ((label (plist-get options :label))
         (unit (or (plist-get options :unit) ""))
         (accent-opt (or (plist-get options :accent) 'primary))
         (accent-col (if (stringp accent-opt) accent-opt
                       (etaf-doc-widget--accent palette accent-opt nil)))
         (muted (etaf-doc-widget--color palette :muted "#9198a1"))
         (faint (etaf-doc-widget--color palette :faint muted))
         (mono (plist-get options :mono-family))
         (req-w (or (plist-get options :width) 44))
         (height (max 3 (or (plist-get options :height) 6)))
         (vals (mapcar (lambda (p) (float (cdr p))) series))
         (n (length vals))
         (lo (apply #'min vals))
         (hi (apply #'max vals))
         (span (if (= hi lo) 1.0 (- hi lo)))
         (int-p (cl-every (lambda (v) (= v (truncate v))) vals))
         (fmt-val (lambda (v)
                    (let ((s (if int-p (format "%d" (round v)) (format "%.1f" v))))
                      (if (string-empty-p unit) s (concat s unit)))))
         (hi-str (funcall fmt-val hi))
         (lo-str (funcall fmt-val lo))
         (mid-row (and (>= height 5) (/ (1- height) 2)))
         (mid-str (and mid-row (funcall fmt-val (/ (+ hi lo) 2.0))))
         (axis-w (max 3 (string-width hi-str) (string-width lo-str)
                      (if mid-str (string-width mid-str) 0)))
         (plot-w (max 12 (min (max 16 req-w) (max 12 (- (or available-width 80) axis-w 4)))))
         (grid (cl-loop repeat height collect (make-vector plot-w ?\s)))
         (ys (make-vector plot-w 0)))
    (dotimes (x plot-w)
      (let* ((pos (if (<= n 1) 0.0
                    (/ (* (float x) (1- n)) (float (max 1 (1- plot-w))))))
             (i0 (min (1- n) (floor pos)))
             (i1 (min (1- n) (1+ i0)))
             (frac (- pos i0))
             (v (+ (* (- 1.0 frac) (nth i0 vals)) (* frac (nth i1 vals))))
             (norm (if (= hi lo) 0.5 (/ (- v lo) span)))
             (row (max 0 (min (1- height) (round (* (- 1.0 norm) (1- height)))))))
        (aset ys x row)))
    (aset (nth (aref ys 0) grid) 0 ?─)
    (cl-loop for x from 1 below plot-w
             for y0 = (aref ys (1- x))
             for y1 = (aref ys x)
             do (cond
                 ((= y1 y0) (aset (nth y1 grid) x ?─))
                 ((< y1 y0)
                  (aset (nth y0 grid) x ?╯)
                  (cl-loop for r from (1+ y1) below y0 do (aset (nth r grid) x ?│))
                  (aset (nth y1 grid) x ?╭))
                 (t
                  (aset (nth y0 grid) x ?╮)
                  (cl-loop for r from (1+ y0) below y1 do (aset (nth r grid) x ?│))
                  (aset (nth y1 grid) x ?╰))))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0))
     (append
      (when label
        (list (etaf-node 'text (list :font-weight 'bold) (list label))
              (etaf-node 'text nil '(" "))))
      (cl-loop for r from 0 below height
               for lbl = (cond ((= r 0) hi-str)
                               ((= r (1- height)) lo-str)
                               ((and mid-row (= r mid-row)) mid-str)
                               (t ""))
               for pad = (make-string (max 0 (- axis-w (string-width lbl))) ?\s)
               for tick = (if (string-empty-p lbl) " │ " " ┤ ")
               for curve = (apply #'string (append (nth r grid) nil))
               collect
               (etaf-node
                'flex (list :column-gap '(ch 0))
                (list (etaf-node 'text (append (list :color muted)
                                               (when mono (list :font-family mono)))
                                 (list (concat pad lbl)))
                      (etaf-node 'text (append (list :color faint)
                                               (when mono (list :font-family mono)))
                                 (list tick))
                      (etaf-node 'text (append (list :color accent-col)
                                               (when mono (list :font-family mono)))
                                 (list curve)))))
      (list
       (etaf-node 'text (append (list :color faint)
                                (when mono (list :font-family mono)))
                  (list (concat (make-string axis-w ?\s)
                                " └"
                                (make-string (1+ plot-w) ?─)))))))))

(defun etaf-doc-widget-source-card (palette title meta code-view &optional options)
  "Render a single-frame living-doc code card around CODE-VIEW from PALETTE.
OPTIONS accepts `:border' (border spec), `:background', `:actions' (list of
Views placed on the right of the header bar)."
  (let* ((muted (etaf-doc-widget--color palette :muted "#9198a1"))
         (border (or (plist-get options :border)
                     (list '(px 1) 'solid (etaf-doc-widget--color palette :border "#d1d9e0"))))
         (bg (or (plist-get options :background)
                 (etaf-doc-widget--color palette :panel)))
         (actions (plist-get options :actions)))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0)
                   :border border
                   :background-color bg)
     (list
      (etaf-node
       'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                   :padding '((lh 0) (ch 2))
                   :border-bottom border)
       (delq nil
             (list
              (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 12)
                                    :wrap-mode 'word)
                         (delq nil
                               (list
                                (etaf-node 'text (list :font-weight 'bold) (list title))
                                (when (and meta (not (string-empty-p meta)))
                                  (etaf-node 'text (list :color muted) (list (concat "  " meta)))))))
              (when actions
                (etaf-node 'flex (list :flex-shrink 0 :align-items 'center :column-gap '(ch 2))
                           actions)))))
      code-view))))

(provide 'etaf-doc-widgets)
;;; etaf-doc-widgets.el ends here
