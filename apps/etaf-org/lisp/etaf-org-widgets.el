;;; etaf-org-widgets.el --- Cognitive, visualization & Org living-doc widgets -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Registers the rich visualization, comparison, Emacs-native L1 workspace
;; widgets, Org-exclusive superpower widgets (`org-query', `kanban',
;; `clock-summary', `transclude', `backlinks'), and L2 explicit action widget
;; (`run').
;;
;; Designed in the same restrained editorial / booktabs aesthetic as `etaf-md':
;; - Borderless editorial charts, progress bars, keymaps, breadcrumbs, git-log,
;;   clock-summary, org-query and backlinks.
;; - Single-frame living-doc code cards (`include', `code-ref', `demo', `run',
;;   `git-diff') with flush syntax-highlighted bodies and zero double borders.
;; - Pure `:render' (reading pre-attached `:asset-data' only), standard 1.0x
;;   body metrics, and strict leaf-only pointer hover discipline.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-node)
(require 'etaf-org-env)
(require 'etaf-org-theme)
(require 'etaf-org-nodes)
(require 'etaf-org-assets)

(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--locate-id "etaf-org-model" (session id))
(declare-function etaf-org--open-target "etaf-org-model" (session target))
(declare-function etaf-org--code-block-view "etaf-org-views" (block env &optional label opts))
(declare-function etaf-org--block-views "etaf-org-views" (blocks env))
(declare-function etaf-org-inline-plain-text "etaf-org-parse" (inlines))

;;; ---------------------------------------------------------------------------
;;; Shared editorial helpers (matching `etaf-md-widgets')
;;; ---------------------------------------------------------------------------

(defun etaf-org-widgets--pill (env label active-p on-press &optional help)
  "Return a compact toggle pill with LABEL in ENV.
When ACTIVE-P is non-nil, renders in selected fill with NO hover;
otherwise renders as a muted clickable leaf with soft hover."
  (let* ((accent (etaf-org-accent env 'primary))
         (accent-soft (or (etaf-org--env-color env :accent-soft)
                          (etaf-org-surface env 'raised)))
         (muted (etaf-org--muted env))
         (hover (unless active-p (etaf-org--hover-fill env 'soft))))
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

(defun etaf-org-widgets--code-view (env text lang &optional start-line)
  "Return a frameless, headerless syntax-highlighted code View for TEXT in ENV."
  (let ((blk (list :type 'src-block
                   :lang (or lang "text")
                   :text (or text ""))))
    (when (and (integerp start-line) (> start-line 0))
      (setq blk (plist-put blk :switches (format "-n %d" start-line))))
    (etaf-org--code-block-view
     blk (etaf-org-env-legacy-env env) nil
     (list :frame nil :header nil :env env))))

(defun etaf-org-widgets--asset-error-view (env data &optional loading-msg)
  "Render standard error/loading view for L1 asset DATA, or nil if ready."
  (cond
   ((or (null data) (plist-get data :loading))
    (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 1)))
               (list (etaf-node 'text (list :color (etaf-org--muted env))
                                (list (or loading-msg "正在加载工作区数据…"))))))
   ((plist-get data :error)
    (etaf-node 'box
               (list :width 'stretch :padding '((lh 1) (ch 2))
                     :background-color (etaf-org-accent env 'danger t)
                     :border-left (list '(px 3) 'solid (etaf-org-accent env 'danger)))
               (list (etaf-node 'text (list :color (etaf-org-accent env 'danger))
                                (list (plist-get data :error))))))
   (t nil)))

(defun etaf-org-widgets--source-frame-view (env title meta code-text lang start-line abs-path)
  "Paint a single-frame living-doc code card without double borders."
  (let ((muted (etaf-org--muted env)))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0)
                   :border (etaf-org--hairline env)
                   :background-color (etaf-org-surface env 'raised))
     (list
      (etaf-node
       'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                   :padding '((lh 0) (ch 2))
                   :border-bottom (etaf-org--hairline env))
       (delq nil
             (list
              (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 12)
                                    :wrap-mode 'word)
                         (delq nil
                               (list
                                (etaf-node 'text (list :font-weight 'bold) (list title))
                                (when (and meta (not (string-empty-p meta)))
                                  (etaf-node 'text (list :color muted) (list (concat "  " meta)))))))
              (etaf-node 'flex (list :flex-shrink 0 :align-items 'center :column-gap '(ch 2))
                         (delq nil
                               (list
                                (when abs-path
                                  (etaf-org--leaf-button
                                   env "跳源码"
                                   (lambda ()
                                     (find-file-other-window abs-path)
                                     (when (and (integerp start-line) (> start-line 0))
                                       (goto-char (point-min))
                                       (forward-line (1- start-line))))
                                   :role 'link :help (format "在 Emacs 中打开 %s" abs-path)))
                                (etaf-org--leaf-button
                                 env "复制"
                                 (lambda ()
                                   (kill-new (or code-text ""))
                                   (message "已复制源码片段"))
                                 :help "复制此源码片段")))))))
      (etaf-org-widgets--code-view env code-text lang start-line)))))

(defun etaf-org-widgets--first-src-block (env &optional node)
  "Return the first `src-block' plist inside NODE (or ENV), or nil."
  (let ((found (cl-find-if
                (lambda (c)
                  (let ((b (if (etaf-org-node-p c) (etaf-org-node-block c) c)))
                    (and (listp b) (eq (plist-get b :type) 'src-block))))
                (etaf-org-children env node))))
    (when found
      (if (etaf-org-node-p found) (etaf-org-node-block found) found))))

(defun etaf-org-widgets--status-pill (env text variant)
  "Return a subtle soft-tinted status pill (no outer border)."
  (etaf-node 'text
             (list :color (etaf-org-accent env variant)
                   :background-color (etaf-org-accent env variant t)
                   :font-weight 'bold)
             (list (format " %s " text))))

;;; ---------------------------------------------------------------------------
;;; 1. Visualization & UI: chart, progress, keymap, breadcrumb
;;; ---------------------------------------------------------------------------

(defun etaf-org-widgets--parse-chart-series (env)
  "Extract `((LABEL . VALUE) ...)' from `:values' or `:from' Org table."
  (let ((from-name (etaf-org-attr env :from))
        (values-str (etaf-org-attr env :values))
        (labels-str (etaf-org-attr env :labels)))
    (cond
     (from-name
      (when-let* ((tbl (etaf-org-nodes--resolve-named-table env from-name)))
        (let* ((lcol (max 0 (1- (or (etaf-org-attr env :label-col) 1))))
               (vcol (max 0 (1- (or (etaf-org-attr env :value-col) 2))))
               (rows (nthcdr (or (plist-get tbl :header-count) 0)
                             (plist-get tbl :rows))))
          (cl-loop for row in rows
                   for cs = (plist-get row :cells)
                   for lbl = (or (plist-get (nth lcol cs) :raw) "")
                   for raw = (or (plist-get (nth vcol cs) :raw) "0")
                   for num = (if (string-match "-?[0-9]+\\(?:\\.[0-9]+\\)?" raw)
                                 (string-to-number (match-string 0 raw))
                               0)
                   collect (cons lbl num)))))
     ((stringp values-str)
      (let* ((sep (if (string-match-p "[:,;\n]" values-str) "[,;\n]+" "[ \t]+"))
             (tokens (mapcar #'string-trim (split-string values-str sep t)))
             (labels (when (and (stringp labels-str) (not (string-blank-p labels-str)))
                       (mapcar #'string-trim (split-string labels-str "," t)))))
        (cl-loop for tok in tokens
                 for idx from 0
                 collect
                 (if (string-match "\\`\\([^:]+\\):[ \t]*\\(-?[0-9.]+\\)\\'" tok)
                     (cons (string-trim (match-string 1 tok))
                           (string-to-number (match-string 2 tok)))
                   (cons (or (nth idx labels) (format "#%d" (1+ idx)))
                         (string-to-number tok))))))
     (t nil))))

(defun etaf-org-widgets--line-chart-view
    (series label unit accent-col muted faint avail req-w height)
  "Render SERIES as a crisp, zero-wrap box-drawing line chart.
Uses monospace box-drawing curves with Y-axis bounds and a clean baseline,
avoiding Apple Braille hollow-dot clutter and wide-glyph row wrapping."
  (let* ((vals (mapcar (lambda (p) (float (cdr p))) series))
         (n (length vals))
         (h (max 3 height))
         (lo (apply #'min vals))
         (hi (apply #'max vals))
         (span (if (= hi lo) 1.0 (- hi lo)))
         (int-p (cl-every (lambda (v) (= v (truncate v))) vals))
         (fmt-val (lambda (v)
                    (let ((s (if int-p
                                 (format "%d" (round v))
                               (format "%.1f" v))))
                      (if (string-empty-p unit) s (concat s unit)))))
         (hi-str (funcall fmt-val hi))
         (lo-str (funcall fmt-val lo))
         (mid-row (and (>= h 5) (/ (1- h) 2)))
         (mid-str (and mid-row (funcall fmt-val (/ (+ hi lo) 2.0))))
         (axis-w (max 3 (string-width hi-str) (string-width lo-str)
                      (if mid-str (string-width mid-str) 0)))
         (plot-w (max 12 (min (max 16 req-w) (max 12 (- avail axis-w 4)))))
         (grid (cl-loop repeat h collect (make-vector plot-w ?\s)))
         (ys (make-vector plot-w 0)))
    (dotimes (x plot-w)
      (let* ((pos (if (<= n 1) 0.0
                    (/ (* (float x) (1- n)) (float (max 1 (1- plot-w))))))
             (i0 (min (1- n) (floor pos)))
             (i1 (min (1- n) (1+ i0)))
             (frac (- pos i0))
             (v (+ (* (- 1.0 frac) (nth i0 vals)) (* frac (nth i1 vals))))
             (norm (if (= hi lo) 0.5 (/ (- v lo) span)))
             (row (max 0 (min (1- h) (round (* (- 1.0 norm) (1- h)))))))
        (aset ys x row)))
    (aset (nth (aref ys 0) grid) 0 ?─)
    (cl-loop for x from 1 below plot-w
             for y0 = (aref ys (1- x))
             for y1 = (aref ys x)
             do (cond
                 ((= y1 y0)
                  (aset (nth y1 grid) x ?─))
                 ((< y1 y0)
                  (aset (nth y0 grid) x ?╯)
                  (cl-loop for r from (1+ y1) below y0
                           do (aset (nth r grid) x ?│))
                  (aset (nth y1 grid) x ?╭))
                 (t
                  (aset (nth y0 grid) x ?╮)
                  (cl-loop for r from (1+ y0) below y1
                           do (aset (nth r grid) x ?│))
                  (aset (nth y1 grid) x ?╰))))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0))
     (append
      (when label
        (list (etaf-node 'text (list :font-weight 'bold) (list label))
              (etaf-node 'text nil '(" "))))
      (cl-loop for r from 0 below h
               for lbl = (cond ((= r 0) hi-str)
                               ((= r (1- h)) lo-str)
                               ((and mid-row (= r mid-row)) mid-str)
                               (t ""))
               for pad = (make-string (max 0 (- axis-w (string-width lbl))) ?\s)
               for tick = (if (string-empty-p lbl) " │ " " ┤ ")
               for curve = (apply #'string (append (nth r grid) nil))
               collect
               (etaf-node
                'flex (list :column-gap '(ch 0))
                (list (etaf-node 'text (list :color muted
                                             :font-family (etaf-org--mono-family))
                                 (list (concat pad lbl)))
                      (etaf-node 'text (list :color faint
                                             :font-family (etaf-org--mono-family))
                                 (list tick))
                      (etaf-node 'text (list :color accent-col
                                             :font-family (etaf-org--mono-family))
                                 (list curve)))))
      (list
       (etaf-node 'text (list :color faint
                              :font-family (etaf-org--mono-family))
                  (list (concat (make-string axis-w ?\s)
                                " └"
                                (make-string (1+ plot-w) ?─)))))))))

(etaf-org--define-shipped 'chart
  :name "chart"
  :summary "书刊无框数据图表（line/bar/stacked/heatmap，支持 :from 直连 Org 表格）"
  :attrs '((type :type enum :one-of (line bar stacked heatmap) :default bar :doc "图表类型")
           (label :type string :doc "图表标题")
           (values :type string :doc "逗号或空格分隔数据如 A:10,B:20 或 1,3,5")
           (labels :type string :doc "逗号分隔标签（供纯数值序列使用）")
           (from :type string :doc "绑定具名 #+NAME: Org 表格")
           (label-col :type number :integer t :default 1 :min 1 :doc "表格标签列（1-based）")
           (value-col :type number :integer t :default 2 :min 1 :doc "表格数值列（1-based）")
           (unit :type string :default "" :doc "数值单位")
           (width :type number :integer t :default 44 :min 12 :doc "图表宽度（列）")
           (height :type number :integer t :default 6 :min 2 :doc "折线图高度（行）")
           (accent :type accent :default primary :doc "强调色"))
  :view (lambda (env)
          (let* ((kind (or (etaf-org-attr env :type) 'bar))
                 (label (etaf-org-attr env :label))
                 (unit (or (etaf-org-attr env :unit) ""))
                 (accent-sym (or (etaf-org-attr env :accent) 'primary))
                 (accent-col (etaf-org-accent env accent-sym))
                 (series (etaf-org-widgets--parse-chart-series env))
                 (avail (etaf-org-available-width env))
                 (req-w (or (etaf-org-attr env :width) 44))
                 (muted (etaf-org--muted env))
                 (faint (or (etaf-org--env-color env :faint) muted)))
            (if (null series)
                (etaf-node 'text (list :color muted) '("（无图表数据）"))
              (pcase kind
                ('line
                 (etaf-org-widgets--line-chart-view
                  series label unit accent-col muted faint avail req-w
                  (max 3 (or (etaf-org-attr env :height) 6))))
                ('bar
                 (let* ((mx (max 0.001 (float (apply #'max 0.001 (mapcar (lambda (p) (abs (cdr p))) series)))))
                        (lw (min 18 (max 4 (apply #'max 4 (mapcar (lambda (p) (string-width (car p))) series)))))
                        (bar-cap (max 8 (- (min avail req-w) lw 12))))
                   (etaf-node
                    'column (list :width 'stretch :item-gap '(lh 0))
                    (append
                     (when label
                       (list (etaf-node 'text (list :font-weight 'bold) (list label))
                             (etaf-node 'text nil '(" "))))
                     (mapcar
                      (lambda (pair)
                        (let* ((name (car pair))
                               (val (cdr pair))
                               (filled (max 1 (min bar-cap (round (* bar-cap (/ (abs (float val)) mx))))))
                               (empty (max 0 (- bar-cap filled)))
                               (unit-sep (if (and (not (string-empty-p unit))
                                                  (not (equal unit "%"))
                                                  (not (string-prefix-p " " unit)))
                                             " " ""))
                               (val-str (format "%g%s%s" val unit-sep unit)))
                          (etaf-node
                           'flex (list :width 'stretch :column-gap '(ch 1))
                           (list
                            (etaf-node 'box (list :width (list 'ch lw) :flex-shrink 0 :text-align 'right)
                                       (list (etaf-node 'text (list :color muted)
                                                        (list (truncate-string-to-width name lw)))))
                            (etaf-node 'flex (list :column-gap '(ch 0))
                                       (delq nil
                                             (list
                                              (etaf-node 'text (list :color accent-col)
                                                         (list (make-string filled ?█)))
                                              (when (> empty 0)
                                                (etaf-node 'text (list :color faint)
                                                           (list (make-string empty ?░)))))))
                            (etaf-node 'text (list :font-weight 'bold) (list val-str))))))
                      series)))))
                ('stacked
                 (let* ((total (max 0.001 (apply #'+ (mapcar (lambda (p) (max 0.0 (float (cdr p)))) series))))
                        (bar-w (min (max 16 (- avail 6)) (max 16 req-w)))
                        (accents (list (etaf-org-accent env 'primary)
                                       (etaf-org-accent env 'success)
                                       (etaf-org-accent env 'warning)
                                       (etaf-org-accent env 'important)
                                       (etaf-org-accent env 'danger)
                                       muted))
                        (segs nil) (legends nil) (used 0) (count (length series)))
                   (cl-loop for pair in series for i from 0
                            for color = (nth (mod i (length accents)) accents)
                            for val = (max 0.0 (float (cdr pair)))
                            for pct = (round (* 100.0 (/ val total)))
                            for seg-w = (if (= i (1- count))
                                            (max 1 (- bar-w used))
                                          (max 1 (min (- bar-w used (max 0 (- count i 1)))
                                                      (round (* bar-w (/ val total))))))
                            do (setq used (+ used seg-w))
                               (push (etaf-node 'text (list :color color)
                                                (list (make-string seg-w ?█)))
                                     segs)
                               (push (etaf-node
                                      'flex (list :column-gap '(ch 1))
                                      (list (etaf-node 'text (list :color color) '("■"))
                                            (etaf-node 'text nil
                                                       (list (cond
                                                              ((and (equal unit "%")
                                                                    (<= (abs (- val pct)) 1.0))
                                                               (format "%s %g%%" (car pair) (cdr pair)))
                                                              ((equal unit "%")
                                                               (format "%s %g%%（占 %d%%）" (car pair) (cdr pair) pct))
                                                              (t
                                                               (format "%s %g%s (%d%%)"
                                                                       (car pair) (cdr pair) unit pct)))))))
                                     legends))
                   (etaf-node
                    'column (list :width 'stretch :item-gap '(lh 0))
                    (delq nil
                          (list
                           (when label (etaf-node 'text (list :font-weight 'bold) (list label)))
                           (etaf-node 'flex (list :width 'stretch :column-gap '(ch 0)) (nreverse segs))
                           (etaf-node 'flex (list :width 'stretch :flex-wrap 'wrap :gap '((lh 0) (ch 2)))
                                      (nreverse legends)))))))
                ('heatmap
                 (let* ((vals (mapcar #'cdr series))
                        (lo (apply #'min vals))
                        (hi (apply #'max vals))
                        (span (float (- hi lo)))
                        (glyphs ["░" "▒" "▓" "█"])
                        (rows (seq-partition vals 7)))
                   (etaf-node
                    'column (list :width 'stretch :item-gap '(lh 0))
                    (append
                     (when label (list (etaf-node 'text (list :font-weight 'bold) (list label))))
                     (mapcar
                      (lambda (row)
                        (etaf-node
                         'flex (list :column-gap '(ch 1))
                         (mapcar
                          (lambda (v)
                            (let* ((norm (if (<= span 0.0) 0.5 (/ (- v lo) span)))
                                   (idx (min 3 (max 0 (floor (* norm 3.99)))))
                                   (col (if (zerop idx) faint accent-col)))
                              (etaf-node 'text (list :color col)
                                         (list (concat (aref glyphs idx) (aref glyphs idx))))))
                          row)))
                      rows)
                     (list
                      (etaf-node 'flex (list :column-gap '(ch 1))
                                 (list (etaf-node 'text (list :color muted) '("少"))
                                       (etaf-node 'text (list :color faint) '("░░"))
                                       (etaf-node 'text (list :color accent-col) '("▒▒ ▓▓ ██"))
                                       (etaf-node 'text (list :color muted) '("多"))))))))))))))

(defun etaf-org-widgets--progress-parse-row (line)
  "Parse LINE as `(LABEL VALUE MAX PERCENT DISPLAY)' for `progress', or nil."
  (let ((s (string-trim (or line ""))))
    (cond
     ((string-match "\\`\\(.+?\\)[ \t]*[:：][ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[ \t]*/[ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\'" s)
      (let* ((lbl (string-trim (match-string 1 s)))
             (val (string-to-number (match-string 2 s)))
             (mx (max 0.001 (float (string-to-number (match-string 3 s)))))
             (pct (min 100 (max 0 (round (* 100.0 (/ (float val) mx)))))))
        (list lbl val mx pct (format "%d%%  (%s/%s)" pct (match-string 2 s) (match-string 3 s)))))
     ((string-match "\\`\\(.+?\\)[ \t]*[:：][ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)%?\\'" s)
      (let* ((lbl (string-trim (match-string 1 s)))
             (val (min 100 (max 0 (string-to-number (match-string 2 s)))))
             (pct (round val)))
        (list lbl val 100 pct (format "%d%%" pct))))
     (t nil))))

(etaf-org--define-shipped 'progress
  :name "progress"
  :summary "简洁无外框进度条（单条或列表多条，对齐 etaf-md）"
  :attrs '((title :type string :doc "进度组标题")
           (label :type string :doc "单条标签或标题")
           (value :type number :doc "当前值")
           (max :type number :default 100 :doc "最大值")
           (variant :type accent :default primary :doc "强调色")
           (accent :type accent :doc "强调色别名"))
  :view (lambda (env)
          (let* ((title (or (etaf-org-attr env :title) (etaf-org-attr env :label)))
                 (val (etaf-org-attr env :value))
                 (mx (max 1 (or (etaf-org-attr env :max) 100)))
                 (accent-sym (or (etaf-org-attr env :accent)
                                 (etaf-org-attr env :variant)
                                 'primary))
                 (accent-col (etaf-org-accent env accent-sym))
                 (muted (etaf-org--muted env))
                 (faint (or (etaf-org--env-color env :faint) muted))
                 (avail (etaf-org-available-width env))
                 (items (etaf-org-nodes--list-items-of env))
                 (rows
                  (if items
                      (delq nil (mapcar (lambda (it)
                                          (etaf-org-widgets--progress-parse-row
                                           (etaf-org-nodes--item-plain-text it)))
                                        items))
                    (when (numberp val)
                      (let ((pct (min 100 (max 0 (round (* 100.0 (/ (float val) mx)))))))
                        (list (list (or title "进度") val mx pct (format "%d%%" pct)))))))
                 (lbl-w (min 24 (max 8 (if rows
                                           (apply #'max 8 (mapcar (lambda (r) (string-width (nth 0 r))) rows))
                                         8))))
                 (bar-w (max 12 (min 36 (- avail lbl-w 16)))))
            (if (null rows)
                (etaf-node 'text (list :color muted) '("（无进度项）"))
              (etaf-node
               'column (list :width 'stretch :item-gap '(lh 0))
               (append
                (when (and title items)
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
                      'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2))
                      (list
                       (etaf-node 'box (list :width (list 'ch lbl-w) :flex-shrink 0)
                                  (list (etaf-node 'text (list :color muted)
                                                   (list (truncate-string-to-width lbl lbl-w)))))
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
                 rows)))))))

(defun etaf-org-widgets--keymap-chord-nodes (env chord)
  "Render key CHORD into subtle filled keycaps, keeping `/' plain."
  (let* ((mono (etaf-org--mono-family))
         (ink (etaf-org--env-color env :ink))
         (muted (etaf-org--muted env))
         (faint (or (etaf-org--env-color env :faint) muted))
         (cap-bg (or (etaf-org--env-color env :panel2) (etaf-org-surface env 'raised)))
         ;; Only split on mid-string ` / ' between two alternatives; keep trailing `/' as a keycap (e.g. `C-c /').
         (trimmed (string-trim chord))
         (alts (if (string-match-p "[^ \t][ \t]+/[ \t]+[^ \t]" trimmed)
                   (split-string trimmed "[ \t]+/[ \t]+" t)
                 (list trimmed)))
         (nodes nil))
    (cl-loop for alt in alts for alt-idx from 0 do
             (when (> alt-idx 0)
               (push (etaf-node 'text (list :color faint) '(" / ")) nodes))
             (let ((tokens (split-string (string-trim alt) "[ \t]+" t)))
               (cl-loop for tok in tokens for tok-idx from 0 do
                        (when (> tok-idx 0)
                          (push (etaf-node 'text nil '(" ")) nodes))
                        (push (etaf-node 'text
                                         (list :font-family mono
                                               :color ink
                                               :background-color cap-bg
                                               :font-weight 'bold)
                                         (list (format " %s " tok)))
                              nodes))))
    (etaf-node 'flex (list :align-items 'center) (nreverse nodes))))

(etaf-org--define-shipped 'keymap
  :name "keymap"
  :summary "书刊无框定宽快捷键速查表（斜杠不画键帽，对齐 etaf-md）"
  :attrs '((title :type string :doc "标题")
           (columns :type number :integer t :default 2 :min 1 :max 3 :doc "栏数"))
  :view (lambda (env)
          (let* ((title (etaf-org-attr env :title))
                 (req-cols (or (etaf-org-attr env :columns) 2))
                 (avail (etaf-org-available-width env))
                 (cols (if (< avail 56) 1 (min req-cols 2)))
                 (items (etaf-org-nodes--list-items-of env))
                 (pairs
                  (delq nil
                        (mapcar (lambda (it)
                                  (let* ((s (string-trim (etaf-org-nodes--item-plain-text it))))
                                    (if (string-match "\\`\\(.+?\\)[ \t]*[:：][ \t]*\\(.+\\)\\'" s)
                                        (cons (string-trim (match-string 1 s))
                                              (string-trim (match-string 2 s)))
                                      (unless (string-empty-p s) (cons s "")))))
                                items)))
                 (key-w (min 18 (max 10 (if pairs
                                            (+ 4 (apply #'max 6
                                                        (mapcar (lambda (p) (string-width (car p)))
                                                                pairs)))
                                          10))))
                 (muted (etaf-org--muted env)))
            (if (null pairs)
                (etaf-node 'text (list :color muted) '("（无快捷键项）"))
              (etaf-node
               'column (list :width 'stretch :item-gap '(lh 0))
               (append
                (when title
                  (list (etaf-node 'text (list :font-weight 'bold) (list title))
                        (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)))
                (cl-loop for row in (seq-partition pairs cols)
                         for row-idx from 0
                         collect
                         (etaf-node
                          'flex
                          (list :width 'stretch :column-gap '(ch 4)
                                :border-top (when (= row-idx 0) (etaf-org--hairline env))
                                :border-bottom (etaf-org--hairline env))
                          (cl-loop for pair in row
                                   collect
                                   (etaf-node
                                    'flex (list :flex-basis '(ch 0) :flex-grow 1 :width 'stretch
                                                :align-items 'center :column-gap '(ch 2))
                                    (list
                                     (etaf-node 'box (list :width (list 'ch key-w) :flex-shrink 0)
                                                (list (etaf-org-widgets--keymap-chord-nodes env (car pair))))
                                     (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'word)
                                                (list (etaf-node 'text (list :color muted)
                                                                 (list (cdr pair))))))))))))))))

(etaf-org--define-shipped 'breadcrumb
  :name "breadcrumb"
  :summary "行内文档层级面包屑（无外框，对齐 etaf-md）"
  :attrs '((items :type string :required t :doc "以 > 分隔的路径项，支持 [[target][label]]")
           (separator :type string :default "›" :doc "分隔符"))
  :view (lambda (env)
          (let* ((sep (or (etaf-org-attr env :separator) "›"))
                 (raw (or (etaf-org-attr env :items) ""))
                 (parts (split-string raw "[ \t]*[>›][ \t]*" t))
                 (last-idx (1- (length parts)))
                 (faint (or (etaf-org--env-color env :faint) (etaf-org--muted env)))
                 (muted (etaf-org--muted env))
                 (ink (etaf-org--env-color env :ink))
                 (nodes nil))
            (cl-loop for part in parts for i from 0 do
                     (when (> i 0)
                       (push (etaf-node 'text (list :color faint) (list (format " %s " sep))) nodes))
                     (cond
                      ((and (< i last-idx)
                            (string-match "\\`\\[\\[\\([^]]+\\)\\]\\[\\([^]]+\\)\\]\\]\\'" part))
                       (let ((tgt (match-string 1 part)) (lbl (match-string 2 part)))
                         (push (etaf-org--leaf-button env lbl
                                                      (lambda () (etaf-org-follow-link env tgt))
                                                      :role 'link :help tgt)
                               nodes)))
                      ((= i last-idx)
                       (push (etaf-node 'text (list :color ink :font-weight 'bold) (list part)) nodes))
                      (t
                       (push (etaf-node 'text (list :color muted) (list part)) nodes))))
            (etaf-node 'flex (list :width 'stretch :flex-wrap 'wrap :align-items 'center)
                       (nreverse nodes)))))

;;; ---------------------------------------------------------------------------
;;; 2. Comparison & Live Examples: diff, pros-cons, demo
;;; ---------------------------------------------------------------------------

(defun etaf-org-widgets--diff-extract-lines (env child)
  "Extract raw text lines from diff slot CHILD in ENV."
  (let ((src (etaf-org-widgets--first-src-block env child)))
    (if src
        (split-string (string-trim-right (or (plist-get src :text) "") "\n") "\n")
      (let* ((kids (etaf-org-children env child))
             (lines nil))
        (dolist (k kids)
          (let ((b (if (etaf-org-node-p k) (etaf-org-node-block k) k)))
            (cond
             ((and (listp b) (eq (plist-get b :type) 'paragraph))
              (push (etaf-org-inline-plain-text (plist-get b :inlines)) lines))
             ((and (listp b) (eq (plist-get b :type) 'list))
              (dolist (it (plist-get b :items))
                (push (concat "- " (etaf-org-nodes--item-plain-text it)) lines)))
             ((and (listp b) (plist-get b :text))
              (push (plist-get b :text) lines))
             ((and (listp b) (plist-get b :raw-content))
              (push (plist-get b :raw-content) lines)))))
        (let ((joined (string-trim-right (string-join (nreverse lines) "\n") "\n")))
          (if (string-empty-p joined) nil (split-string joined "\n")))))))

(defun etaf-org-widgets--diff-compute-ops (old-lines new-lines)
  "Compute LCS diff ops between OLD-LINES and NEW-LINES.
Returns list of `(OP OLD-NO NEW-NO TEXT)' where OP is `same', `del' or `add'."
  (let* ((m (length old-lines))
         (n (length new-lines))
         (a (vconcat old-lines))
         (b (vconcat new-lines))
         (dp (make-vector (1+ m) nil)))
    (dotimes (i (1+ m))
      (aset dp i (make-vector (1+ n) 0)))
    (cl-loop for i from (1- m) downto 0 do
             (cl-loop for j from (1- n) downto 0 do
                      (aset (aref dp i) j
                            (if (equal (aref a i) (aref b j))
                                (1+ (aref (aref dp (1+ i)) (1+ j)))
                              (max (aref (aref dp (1+ i)) j)
                                   (aref (aref dp i) (1+ j)))))))
    (let ((i 0) (j 0) (ops nil))
      (while (or (< i m) (< j n))
        (cond
         ((and (< i m) (< j n) (equal (aref a i) (aref b j)))
          (push (list 'same (1+ i) (1+ j) (aref a i)) ops)
          (setq i (1+ i) j (1+ j)))
         ((and (< i m)
               (or (= j n)
                   (>= (aref (aref dp (1+ i)) j) (aref (aref dp i) (1+ j)))))
          (push (list 'del (1+ i) nil (aref a i)) ops)
          (setq i (1+ i)))
         (t
          (push (list 'add nil (1+ j) (aref b j)) ops)
          (setq j (1+ j)))))
      (nreverse ops))))

(defun etaf-org-widgets--diff-normalize-ops (ops)
  "Order every contiguous change hunk in OPS so all `del' rows precede `add' rows."
  (let ((out nil) (dels nil) (adds nil))
    (cl-labels ((flush ()
                  (dolist (d (nreverse dels)) (push d out))
                  (dolist (a (nreverse adds)) (push a out))
                  (setq dels nil adds nil)))
      (dolist (op ops)
        (pcase (car op)
          ('same (flush) (push op out))
          ('del (push op dels))
          ('add (push op adds))))
      (flush))
    (nreverse out)))

(defun etaf-org-widgets--diff-pair-rows (ops)
  "Group LCS OPS into paired `(LEFT . RIGHT)' rows for aligned split view."
  (let ((rows nil) (dels nil) (adds nil))
    (cl-labels ((flush ()
                  (when (or dels adds)
                    (let* ((ds (nreverse dels))
                           (as (nreverse adds))
                           (len (max (length ds) (length as))))
                      (dotimes (k len)
                        (push (cons (nth k ds) (nth k as)) rows)))
                    (setq dels nil adds nil))))
      (dolist (op ops)
        (pcase (car op)
          ('same (flush) (push (cons op op) rows))
          ('del (push op dels))
          ('add (push op adds))))
      (flush))
    (nreverse rows)))

(defun etaf-org-widgets--diff-cell-view (env op side)
  "Return one static diff cell View for OP on SIDE."
  (let* ((mono (etaf-org--mono-family))
         (ink (etaf-org--env-color env :ink))
         (muted (etaf-org--muted env))
         (faint (or (etaf-org--env-color env :faint) muted))
         (ok-fg (etaf-org-accent env 'success))
         (del-fg (etaf-org-accent env 'danger))
         (ok-bg (or (etaf-org--env-color env :ok-soft) (etaf-org-surface env 'raised)))
         (del-bg (or (etaf-org--env-color env :danger-soft) (etaf-org-surface env 'raised)))
         (empty-bg (etaf-org-surface env 'sunken)))
    (if (null op)
        (etaf-node 'box (list :width 'stretch :background-color empty-bg
                              :padding '((lh 0) (ch 1)))
                   (list (etaf-node 'text (list :font-family mono :color faint) '(" "))))
      (let* ((kind (nth 0 op))
             (num (if (eq side 'right) (nth 2 op) (or (nth 1 op) (nth 2 op))))
             (txt (nth 3 op))
             (bg (pcase kind ('add ok-bg) ('del del-bg) (_ nil)))
             (sig (pcase kind ('add "+") ('del "-") (_ " ")))
             (sig-col (pcase kind ('add ok-fg) ('del del-fg) (_ faint)))
             (num-str (if num (format "%3d " num) "    ")))
        (etaf-node
         'flex (list :width 'stretch :background-color bg :padding '((lh 0) (ch 1)))
         (list
          (etaf-node 'text (list :font-family mono :color faint) (list num-str))
          (etaf-node 'text (list :font-family mono :color sig-col :font-weight 'bold)
                     (list (concat sig " ")))
          (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'word)
                     (list (etaf-node 'text (list :font-family mono :color ink)
                                      (list (if (string-empty-p txt) " " txt)))))))))))

(etaf-org--define-shipped 'diff
  :name "diff"
  :summary "LCS 配对对齐代码 Diff（#+before:/#+after:，宽窗并排、窄窗自动统一）"
  :accepts '((before :attrs ((title :type string)))
             (after :attrs ((title :type string))))
  :child-syntax 'markers
  :attrs '((title :type string :doc "对比标题")
           (mode :type enum :one-of (side unified) :default side :doc "默认视图"))
  :view (lambda (env)
          (let* ((children (etaf-org-children env))
                 (before (cl-find 'before children :key #'etaf-org-node-type))
                 (after (cl-find 'after children :key #'etaf-org-node-type)))
            (if (not (and before after))
                (etaf-node 'text (list :color (etaf-org-accent env 'danger))
                           '("diff 需要 #+before: 与 #+after: 两个子块"))
              (let* ((title (or (etaf-org-attr env :title) "代码变更"))
                     (old-title (or (etaf-org-attr env :title before) "修改前"))
                     (new-title (or (etaf-org-attr env :title after) "修改后"))
                     (old-lines (etaf-org-widgets--diff-extract-lines env before))
                     (new-lines (etaf-org-widgets--diff-extract-lines env after))
                     (ops (etaf-org-widgets--diff-normalize-ops
                           (etaf-org-widgets--diff-compute-ops old-lines new-lines)))
                     (adds (cl-count 'add ops :key #'car))
                     (dels (cl-count 'del ops :key #'car))
                     (avail (etaf-org-available-width env))
                     (pref (etaf-org-block-state env :mode (or (etaf-org-attr env :mode) 'side)))
                     (split-p (and (eq pref 'side) (>= avail 72)))
                     (ok-fg (etaf-org-accent env 'success))
                     (del-fg (etaf-org-accent env 'danger))
                     (muted (etaf-org--muted env)))
                (etaf-node
                 'column (list :width 'stretch :item-gap '(lh 0)
                               :border (etaf-org--hairline env)
                               :background-color (etaf-org-surface env 'raised))
                 (list
                  (etaf-node
                   'flex (list :width 'stretch :align-items 'center :column-gap '(ch 1)
                               :padding '((lh 0) (ch 2))
                               :border-bottom (etaf-org--hairline env))
                   (list
                    (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 12)
                                          :wrap-mode 'word)
                               (list (etaf-node 'text (list :font-weight 'bold) (list title))
                                     (etaf-node 'text (list :color ok-fg :font-weight 'bold)
                                                (list (format " +%d" adds)))
                                     (etaf-node 'text (list :color del-fg :font-weight 'bold)
                                                (list (format " -%d" dels)))))
                    (etaf-node 'flex (list :flex-shrink 0 :align-items 'center :column-gap '(ch 1))
                               (list
                                (etaf-org-widgets--pill env "并排" split-p
                                                        (lambda () (etaf-org-set-block-state env :mode 'side))
                                                        "并排对齐视图")
                                (etaf-org-widgets--pill env "统一" (not split-p)
                                                        (lambda () (etaf-org-set-block-state env :mode 'unified))
                                                        "单列统一视图")))))
                  (if split-p
                      (let ((paired (etaf-org-widgets--diff-pair-rows ops)))
                        (etaf-node
                         'column (list :width 'stretch :item-gap '(lh 0))
                         (cons
                          (etaf-node
                           'flex (list :width 'stretch :border-bottom (etaf-org--hairline env))
                           (list
                            (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1
                                                  :padding '((lh 0) (ch 2))
                                                  :border-right (etaf-org--hairline env))
                                       (list (etaf-node 'text (list :color del-fg) (list old-title))))
                            (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1
                                                  :padding '((lh 0) (ch 2)))
                                       (list (etaf-node 'text (list :color ok-fg) (list new-title))))))
                          (mapcar
                           (lambda (pair)
                             (etaf-node
                              'flex (list :width 'stretch :align-items 'stretch)
                              (list
                               (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1
                                                     :border-right (etaf-org--hairline env))
                                          (list (etaf-org-widgets--diff-cell-view env (car pair) 'left)))
                               (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1)
                                          (list (etaf-org-widgets--diff-cell-view env (cdr pair) 'right))))))
                           paired))))
                    (etaf-node
                     'column (list :width 'stretch :item-gap '(lh 0))
                     (append
                      (when (and (eq pref 'side) (< avail 72))
                        (list (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 2))
                                                    :border-bottom (etaf-org--hairline env))
                                         (list (etaf-node 'text (list :color muted)
                                                          '("窄窗自动切换为统一视图"))))))
                      (mapcar (lambda (op) (etaf-org-widgets--diff-cell-view env op 'unified))
                              ops)))))))))))

(etaf-org--define-shipped 'pros-cons
  :name "pros-cons"
  :summary "无外框等高优劣权衡对比（#+pro:/#+con:，对齐 etaf-md）"
  :accepts '((pro :attrs ((title :type string)))
             (con :attrs ((title :type string))))
  :child-syntax 'markers
  :attrs '((title :type string :doc "标题"))
  :view (lambda (env)
          (let* ((title (etaf-org-attr env :title))
                 (children (etaf-org-children env))
                 (pros (cl-remove-if-not (lambda (n) (eq (etaf-org-node-type n) 'pro)) children))
                 (cons-list (cl-remove-if-not (lambda (n) (eq (etaf-org-node-type n) 'con)) children))
                 (avail (etaf-org-available-width env))
                 (side-p (>= avail 68))
                 (col-w (if side-p (max 16 (- (/ (- avail 2) 2) 5)) (max 16 (- avail 5))))
                 (pane (lambda (nodes def-lbl glyph accent)
                         (when nodes
                           (let* ((fg (etaf-org-accent env accent))
                                  (bg (or (etaf-org-accent env accent t)
                                          (etaf-org-surface env 'raised)))
                                  (single (= (length nodes) 1))
                                  (hdr (if single
                                           (concat glyph " " (or (etaf-org-attr env :title (car nodes)) def-lbl))
                                         (concat glyph " " def-lbl))))
                             (etaf-node
                              'column
                              (append
                               (list :item-gap '(lh 0)
                                     :background-color bg
                                     :border-left (list '(px 3) 'solid fg)
                                     :padding '((lh 1) (ch 2)))
                               (if side-p
                                   (list :flex-basis '(ch 0) :flex-grow 1 :width 'stretch :min-width '(ch 0))
                                 (list :width 'stretch)))
                              (append
                               (list (etaf-node 'text (list :color fg :font-weight 'bold) (list hdr))
                                     (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil))
                               (if single
                                   (when-let* ((body (etaf-org-content (etaf-org--env-for-node env (car nodes) col-w))))
                                     (list body))
                                 (list
                                  (etaf-node
                                   'column (list :width 'stretch :item-gap '(lh 1))
                                   (mapcar
                                    (lambda (node)
                                      (let ((ntitle (etaf-org-attr env :title node)))
                                        (etaf-node
                                         'column (list :width 'stretch :item-gap '(lh 0))
                                         (delq nil
                                               (list (when ntitle
                                                       (etaf-node 'text (list :color fg :font-weight 'bold)
                                                                  (list ntitle)))
                                                     (etaf-org-content (etaf-org--env-for-node env node col-w)))))))
                                    nodes))))))))))
                 (body (if side-p
                           (etaf-node 'flex (list :width 'stretch :column-gap '(ch 2) :align-items 'stretch)
                                      (delq nil (list (funcall pane pros "优势" "✓" 'success)
                                                      (funcall pane cons-list "局限" "×" 'danger))))
                         (etaf-node 'column (list :width 'stretch :item-gap '(lh 1))
                                    (delq nil (list (funcall pane pros "优势" "✓" 'success)
                                                    (funcall pane cons-list "局限" "×" 'danger)))))))
            (if title
                (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
                           (list (etaf-node 'text (list :font-weight 'bold) (list title))
                                 (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)
                                 body))
              body))))

(etaf-org--define-shipped 'demo
  :name "demo"
  :summary "清爽效果预览画布 + 底部轻条按需展开源码（对齐 etaf-md）"
  :attrs '((title :type string :default "效果预览" :doc "底栏说明")
           (open :type boolean :default nil :doc "默认展开源码"))
  :view (lambda (env)
          (let* ((title (or (etaf-org-attr env :title) "效果预览"))
                 (open (etaf-org-block-state env :open (etaf-org-attr env :open)))
                 (raw (string-trim (or (plist-get (etaf-org-env-block env) :raw-content) "")))
                 (avail (etaf-org-available-width env))
                 (inner-env (etaf-org--env-with-width env (max 16 (- avail 4))))
                 (body (etaf-org-content inner-env))
                 (muted (etaf-org--muted env)))
            (etaf-node
             'column (list :width 'stretch :item-gap '(lh 0)
                           :border (etaf-org--hairline env))
             (delq nil
                   (list
                    ;; Clean preview canvas with no noisy top bar
                    (etaf-node 'box (list :width 'stretch :padding '((lh 1) (ch 2)))
                               (when body (list body)))
                    ;; Thin raised footer bar: muted label left, toggle + copy leaf buttons right
                    (etaf-node
                     'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                                 :padding '((lh 0) (ch 2))
                                 :background-color (etaf-org-surface env 'raised)
                                 :border-top (etaf-org--hairline env))
                     (list
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 10)
                                            :wrap-mode 'word)
                                 (list (etaf-node 'text (list :color muted) (list title))))
                      (etaf-node 'flex (list :flex-shrink 0 :align-items 'center :column-gap '(ch 2))
                                 (list
                                  (etaf-org--leaf-button
                                   env (if open "收起源码" "查看源码")
                                   (lambda () (etaf-org-set-block-state env :open (not open)))
                                   :help "展开或收起原始 Org 源码")
                                  (etaf-org--leaf-button
                                   env "复制"
                                   (lambda ()
                                     (kill-new raw)
                                     (message "已复制演示源码"))
                                   :help "复制原始 Org 源码")))))
                    ;; Flush frameless syntax-highlighted source block when open
                    (when open
                      (etaf-node 'box (list :width 'stretch
                                            :background-color (etaf-org-surface env 'sunken)
                                            :border-top (etaf-org--hairline env))
                                 (list (etaf-org-widgets--code-view env raw "org"))))))))))

;;; ---------------------------------------------------------------------------
;;; 3. L1 Shared Workspace Widgets: include, code-ref, symbol, project-tree,
;;;    git-log, git-diff
;;; ---------------------------------------------------------------------------

(etaf-org--define-shipped 'include
  :name "include"
  :summary "L1 沙箱内嵌工作区真实源码片段（单框可跳源码，对齐 etaf-md）"
  :attrs '((src :type string :required t :doc "相对路径")
           (lines :type string :doc "行号区间如 1-20")
           (lang :type string :doc "覆盖高亮语言")
           (title :type string :doc "卡片标题"))
  :view (lambda (env)
          (let ((data (plist-get (etaf-org-env-block env) :asset-data)))
            (or (etaf-org-widgets--asset-error-view env data "等待载入源码…")
                (let* ((rel (plist-get data :rel))
                       (title (or (etaf-org-attr env :title) rel))
                       (sline (or (plist-get data :start-line) 1))
                       (eline (or (plist-get data :end-line) sline))
                       (meta (format "L%d–L%d" sline eline)))
                  (etaf-org-widgets--source-frame-view
                   env title meta (plist-get data :content) (plist-get data :lang)
                   sline (plist-get data :path)))))))

(etaf-org--define-shipped 'code-ref
  :name "code-ref"
  :summary "L1 按符号或行号实时抽取工作区源码（单框可跳源码，完整平衡 Elisp 表单，对齐 etaf-md）"
  :attrs '((src :type string :required t :doc "源码相对路径")
           (symbol :type string :doc "函数/变量符号名")
           (lines :type string :doc "行号区间")
           (context :type number :integer t :default 0 :doc "上下文行数")
           (lang :type string :doc "高亮语言")
           (title :type string :doc "标题"))
  :view (lambda (env)
          (let ((data (plist-get (etaf-org-env-block env) :asset-data)))
            (or (etaf-org-widgets--asset-error-view env data "等待定位源码符号…")
                (let* ((rel (plist-get data :rel))
                       (sym (plist-get data :symbol))
                       (sline (or (plist-get data :start-line) 1))
                       (eline (or (plist-get data :end-line) sline))
                       (title (or (etaf-org-attr env :title) rel))
                       (meta (if sym
                                 (format "%s · L%d–L%d" sym sline eline)
                               (format "L%d–L%d" sline eline))))
                  (etaf-org-widgets--source-frame-view
                   env title meta (plist-get data :content) (plist-get data :lang)
                   sline (plist-get data :path)))))))

(etaf-org--define-shipped 'symbol
  :name "symbol"
  :summary "Emacs 实时符号词条卡（API 词条风，完整首段文档，对齐 etaf-md）"
  :attrs '((name :type string :required t :doc "Emacs 符号名"))
  :view (lambda (env)
          (let* ((data (plist-get (etaf-org-env-block env) :asset-data))
                 (mono (etaf-org--mono-family))
                 (accent (etaf-org-accent env 'primary))
                 (muted (etaf-org--muted env)))
            (or (etaf-org-widgets--asset-error-view env data "正在查询 Emacs 符号…")
                (let* ((name (or (plist-get data :name) ""))
                       (kind (or (plist-get data :kind) "符号"))
                       (sig (plist-get data :signature))
                       (val (plist-get data :value))
                       (doc (plist-get data :doc))
                       (keys (plist-get data :keys))
                       (file (plist-get data :file))
                       (rel-file (or (plist-get data :rel-file)
                                     (and file (file-name-nondirectory file))))
                       (missing (plist-get data :missing))
                       (meta-parts
                        (delq nil
                              (list (when rel-file (format "定义于 %s" rel-file))
                                    (when keys (format "按键 %s" (string-join keys " / ")))))))
                  (etaf-node
                   'column (list :width 'stretch :item-gap '(lh 0)
                                 :background-color (etaf-org-surface env 'raised)
                                 :border-left (list '(px 3) 'solid
                                                    (if missing (etaf-org-accent env 'warning) accent))
                                 :padding '((lh 1) (ch 2)))
                   (delq nil
                         (list
                          (etaf-node
                           'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2))
                           (delq nil
                                 (list
                                  (etaf-node 'text (list :font-family mono :font-weight 'bold)
                                             (list (format "ƒ %s" name)))
                                  (etaf-node 'text (list :color muted) (list kind))
                                  (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                                  (unless missing
                                    (let ((sym-obj (intern-soft name)))
                                      (when sym-obj
                                        (etaf-org--leaf-button
                                         env "查看文档"
                                         (lambda () (describe-symbol sym-obj))
                                         :role 'link :help (format "打开 %s 的 *Help* 文档" name)))))
                                  (when (and file (file-readable-p file))
                                    (etaf-org--leaf-button
                                     env "跳源码"
                                     (lambda () (find-file-other-window file))
                                     :role 'link :help file)))))
                          (when (or sig val)
                            (etaf-node 'box (list :width 'stretch :margin-top '(lh 0))
                                       (list (etaf-node 'text (list :font-family mono :color accent)
                                                        (list (or sig (format "= %s" val)))))))
                          (when doc
                            (etaf-node 'box (list :width 'stretch :margin-top '(lh 1) :wrap-mode 'word)
                                       (list (etaf-node 'text nil (list doc)))))
                          (when meta-parts
                            (etaf-node 'box (list :width 'stretch :margin-top '(lh 1))
                                       (list (etaf-node 'text (list :color muted)
                                                        (list (string-join meta-parts " · "))))))))))))))

(defun etaf-org-widgets--project-tree-rows (env entries prefix clickable)
  "Render recursive `project-tree' ENTRIES with true `├─'/`└─'/`│' guides."
  (let* ((count (length entries))
         (mono (etaf-org--mono-family))
         (accent (etaf-org-accent env 'primary))
         (ink (etaf-org--env-color env :ink))
         (muted (etaf-org--muted env))
         (faint (or (etaf-org--env-color env :faint) muted))
         (hover (etaf-org--hover-fill env 'soft))
         (collapsed (etaf-org-block-state env :collapsed))
         (rows nil))
    (cl-loop for e in entries
             for idx from 0
             for last = (= idx (1- count))
             do (let* ((name (plist-get e :name))
                       (path (plist-get e :path))
                       (dir-p (plist-get e :dir))
                       (kids (plist-get e :children))
                       (closed (and dir-p (member path collapsed)))
                       (guide (concat prefix (if last "└─ " "├─ ")))
                       (next-prefix (concat prefix (if last "   " "│  "))))
                  (push
                   (etaf-node
                    'flex (list :width 'stretch)
                    (list
                     (etaf-node 'text (list :font-family mono :color faint) (list guide))
                     (cond
                      (dir-p
                       (let ((p path) (cl closed))
                         (etaf-node 'text
                                    (append
                                     (list :font-family mono :color accent :font-weight 'bold
                                           :role 'button :tab-index 0 :pointer 'hand
                                           :help-echo (if cl "展开目录" "折叠目录")
                                           :on-press
                                           (lambda ()
                                             (let ((cur (etaf-org-block-state env :collapsed)))
                                               (etaf-org-set-block-state
                                                env :collapsed
                                                (if (member p cur)
                                                    (delete p (copy-sequence cur))
                                                  (cons p cur))))))
                                     (when hover (list :hover-style (list :background-color hover))))
                                    (list (concat (if cl "▸ " "▾ ") name)))))
                      (clickable
                       (let ((p path))
                         (etaf-node 'text
                                    (append
                                     (list :font-family mono :color ink
                                           :role 'link :tab-index 0 :pointer 'hand
                                           :help-echo (format "打开 %s" p)
                                           :on-press (lambda () (find-file-other-window p)))
                                     (when hover (list :hover-style (list :background-color hover))))
                                    (list name))))
                      (t
                       (etaf-node 'text (list :font-family mono :color muted) (list name))))))
                   rows)
                  (when (and dir-p kids (not closed))
                    (dolist (r (etaf-org-widgets--project-tree-rows env kids next-prefix clickable))
                      (push r rows)))))
    (nreverse rows)))

(etaf-org--define-shipped 'project-tree
  :name "project-tree"
  :summary "L1 工作区实时目录树（点击目录折叠、点击文件直达，对齐 etaf-md）"
  :attrs '((path :type string :default "." :doc "相对目录")
           (depth :type number :integer t :default 2 :min 1 :max 5 :doc "扫描深度")
           (title :type string :doc "标题")
           (clickable :type boolean :default t :doc "文件是否可点击打开"))
  :view (lambda (env)
          (let ((data (plist-get (etaf-org-env-block env) :asset-data))
                (muted (etaf-org--muted env)))
            (or (etaf-org-widgets--asset-error-view env data "正在扫描目录…")
                (let* ((title (or (etaf-org-attr env :title) (plist-get data :rel) "."))
                       (entries (plist-get data :entries))
                       (clickable (etaf-org-attr env :clickable)))
                  (etaf-node
                   'column (list :width 'stretch :item-gap '(lh 0)
                                 :border (etaf-org--hairline env)
                                 :background-color (etaf-org-surface env 'raised))
                   (list
                    (etaf-node
                     'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                                 :padding '((lh 0) (ch 2))
                                 :border-bottom (etaf-org--hairline env))
                     (list
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 12)
                                            :wrap-mode 'word)
                                 (list (etaf-node 'text (list :font-weight 'bold) (list title))))
                      (etaf-node 'box (list :flex-shrink 0)
                                 (list (etaf-node 'text (list :color muted)
                                                  (list (if clickable "点击目录折叠 · 文件直达" "点击目录折叠")))))))
                    (etaf-node
                     'column (list :width 'stretch :item-gap '(lh 0)
                                   :padding '((lh 1) (ch 2)))
                     (if entries
                         (etaf-org-widgets--project-tree-rows env entries "" clickable)
                       (list (etaf-node 'text (list :color muted) '("（空目录）"))))))))))))

(etaf-org--define-shipped 'git-log
  :name "git-log"
  :summary "书刊无框提交历史清单（兼容 Git 与 Jujutsu，L1 异步，对齐 etaf-md）"
  :attrs '((limit :type number :integer t :default 8 :min 1 :max 30 :doc "条数")
           (path :type string :doc "限定相对路径")
           (title :type string :doc "标题"))
  :view (lambda (env)
          (let ((data (plist-get (etaf-org-env-block env) :asset-data))
                (title (etaf-org-attr env :title))
                (mono (etaf-org--mono-family))
                (accent (etaf-org-accent env 'primary))
                (muted (etaf-org--muted env)))
            (or (etaf-org-widgets--asset-error-view env data "正在读取提交历史…")
                (let ((commits (plist-get data :commits)))
                  (etaf-node
                   'column (list :width 'stretch :item-gap '(lh 0))
                   (append
                    (when title
                      (list (etaf-node 'text (list :font-weight 'bold) (list title))
                            (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)))
                    (if (null commits)
                        (list (etaf-node 'text (list :color muted) '("（暂无提交记录）")))
                      (cl-loop for c in commits for idx from 0
                               collect
                               (etaf-node
                                'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                                            :border-top (when (= idx 0) (etaf-org--hairline env))
                                            :border-bottom (etaf-org--hairline env))
                                (delq nil
                                      (list
                                       (etaf-node 'box (list :width '(ch 8) :flex-shrink 0)
                                                  (list (etaf-node 'text (list :font-family mono :color accent)
                                                                   (list (or (plist-get c :hash) "")))))
                                       (etaf-node 'box (list :width '(ch 11) :flex-shrink 0)
                                                  (list (etaf-node 'text (list :font-family mono :color muted)
                                                                   (list (or (plist-get c :date) "")))))
                                       (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'word)
                                                  (list (etaf-node 'text nil
                                                                   (list (or (plist-get c :subject) "")))))
                                       (when-let* ((au (plist-get c :author)))
                                         (etaf-node 'text (list :color muted) (list au)))))))))))))))

(etaf-org--define-shipped 'git-diff
  :name "git-diff"
  :summary "L1 异步 Git/Jujutsu Diff 卡片（逐行增删着色，对齐 etaf-md）"
  :attrs '((rev :type string :doc "修订范围如 HEAD~1")
           (file :type string :doc "限定文件路径")
           (path :type string :doc "限定文件路径别名")
           (title :type string :default "Git 变更" :doc "标题"))
  :view (lambda (env)
          (let ((data (plist-get (etaf-org-env-block env) :asset-data))
                (title (or (etaf-org-attr env :title) "Git 变更"))
                (mono (etaf-org--mono-family))
                (ok-fg (etaf-org-accent env 'success))
                (del-fg (etaf-org-accent env 'danger))
                (accent (etaf-org-accent env 'primary))
                (ok-bg (or (etaf-org--env-color env :ok-soft) (etaf-org-surface env 'raised)))
                (del-bg (or (etaf-org--env-color env :danger-soft) (etaf-org-surface env 'raised)))
                (muted (etaf-org--muted env)))
            (or (etaf-org-widgets--asset-error-view env data "正在读取 git diff…")
                (let* ((content (or (plist-get data :content) ""))
                       (empty (string-blank-p content))
                       (lines (unless empty (split-string content "\n"))))
                  (etaf-node
                   'column (list :width 'stretch :item-gap '(lh 0)
                                 :border (etaf-org--hairline env)
                                 :background-color (etaf-org-surface env 'raised))
                   (list
                    (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 2))
                                          :border-bottom (etaf-org--hairline env))
                               (list (etaf-node 'text (list :font-weight 'bold) (list title))))
                    (if empty
                        (etaf-node 'box (list :width 'stretch :padding '((lh 1) (ch 2)))
                                   (list (etaf-node 'text (list :color muted)
                                                    '("（工作区干净，无未提交差异）"))))
                      (etaf-node
                       'column (list :width 'stretch :item-gap '(lh 0))
                       (mapcar
                        (lambda (line)
                          (let* ((add (and (string-prefix-p "+" line) (not (string-prefix-p "+++" line))))
                                 (del (and (string-prefix-p "-" line) (not (string-prefix-p "---" line))))
                                 (hunk (string-prefix-p "@@" line))
                                 (bg (cond (add ok-bg) (del del-bg) (t nil)))
                                 (fg (cond (add ok-fg) (del del-fg) (hunk accent) (t nil))))
                            (etaf-node 'box (list :width 'stretch :background-color bg
                                                  :padding '((lh 0) (ch 2)) :wrap-mode 'word)
                                       (list (etaf-node 'text (list :font-family mono :color fg)
                                                        (list (if (string-empty-p line) " " line)))))))
                        lines))))))))))

;;; ---------------------------------------------------------------------------
;;; 4. Org-Exclusive L1 Superpowers: org-query, kanban, clock-summary,
;;;    transclude, backlinks
;;; ---------------------------------------------------------------------------

(defun etaf-org-widgets--jump-query-row (session row)
  "Jump to the heading represented by query ROW."
  (let ((file (plist-get row :file))
        (id (plist-get row :id))
        (self (and session (plist-get session :file))))
    (cond
     ((and session id (or (null file) (equal file self)))
      (etaf-org--locate-id session id))
     ((and file (file-readable-p file))
      (find-file-other-window file)
      (goto-char (point-min))
      (forward-line (1- (or (plist-get row :line-start) 1))))
     (t nil))))

(defun etaf-org-widgets--render-kanban-columns (env session rows col-names title)
  "Render ROWS grouped into responsive Kanban lanes (min 22ch per lane)."
  (let* ((avail (etaf-org-available-width env))
         (n (max 1 (length col-names)))
         ;; Never crush lanes below 22ch: cap columns per row and wrap cleanly!
         (per-row (max 1 (min n (floor (/ (+ avail 2) 24)))))
         (buckets (mapcar (lambda (name)
                            (cons name
                                  (cl-remove-if-not
                                   (lambda (r) (equal (upcase (or (plist-get r :todo) "")) (upcase name)))
                                   rows)))
                          col-names))
         (lane-views
          (mapcar
           (lambda (bucket)
             (let* ((cname (car bucket))
                    (items (cdr bucket))
                    (accent (cond ((member (upcase cname) '("DONE" "CLOSED")) 'success)
                                  ((member (upcase cname) '("NEXT" "DOING" "STARTED")) 'primary)
                                  ((member (upcase cname) '("WAIT" "HOLD")) 'neutral)
                                  (t 'warning)))
                    (accent-col (etaf-org-accent env accent)))
               (etaf-node 'column
                          (append
                           (list :width 'stretch :item-gap '(lh 1)
                                 :background-color (etaf-org-surface env 'raised)
                                 :border-left (etaf-org--hairline env)
                                 :border-right (etaf-org--hairline env)
                                 :border-bottom (etaf-org--hairline env)
                                 :border-top (list '(px 1) 'solid accent-col)
                                 :padding '((lh 1) (ch 1)))
                           (when (> per-row 1)
                             '(:flex-basis (ch 0) :flex-grow 1 :min-width (ch 0))))
                          (cons
                           (etaf-node 'flex (list :width 'stretch :align-items 'center :justify-content 'space-between
                                                  :padding-bottom '(lh 0))
                                      (list (etaf-node 'text (list :color accent-col :font-weight 'bold)
                                                       (list cname))
                                            (etaf-node 'text (list :color (etaf-org--muted env))
                                                       (list (format "%d" (length items))))))
                           (if items
                               (mapcar
                                (lambda (r)
                                  (let ((row r)
                                        (pri (plist-get r :priority))
                                        (dl (plist-get r :deadline))
                                        (overdue (plist-get r :overdue)))
                                    (etaf-node 'column
                                               (list :width 'stretch :item-gap '(lh 0)
                                                     :background-color (etaf-org--env-color env :bg)
                                                     :border (etaf-org--hairline env)
                                                     :padding '((lh 0) (ch 1)))
                                               (delq nil
                                                     (list
                                                      (etaf-node 'box '(:width stretch :wrap-mode word)
                                                                 (list
                                                                  (etaf-org--leaf-button
                                                                   env (or (plist-get row :title) "")
                                                                   (lambda () (etaf-org-widgets--jump-query-row session row))
                                                                   :color (etaf-org--env-color env :ink) :bold t
                                                                   :help "跳到此任务")))
                                                      (when (or pri dl)
                                                        (etaf-node
                                                         'flex (list :width 'stretch :column-gap '(ch 1) :flex-wrap 'wrap)
                                                         (delq nil
                                                               (list
                                                                (when pri
                                                                  (etaf-org-widgets--status-pill
                                                                   env (format "#%s" pri)
                                                                   (cond ((equal pri "A") 'danger)
                                                                         ((equal pri "B") 'warning)
                                                                         (t 'neutral))))
                                                                (when dl
                                                                  (let ((short-dl
                                                                         (if (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" dl)
                                                                             (match-string 1 dl)
                                                                           dl)))
                                                                    (etaf-node 'text
                                                                               (list :color (if overdue
                                                                                                (etaf-org-accent env 'danger)
                                                                                              (etaf-org--muted env)))
                                                                               (list (if overdue
                                                                                         (concat "逾期 " short-dl)
                                                                                       short-dl))))))))))))))
                                items)
                             (list (etaf-node 'text (list :color (etaf-org--env-color env :faint)) '("（空）"))))))))
           buckets))
         (lane-rows (seq-partition lane-views per-row)))
    (etaf-node 'column (list :width 'stretch :item-gap '(lh 1))
               (delq nil
                     (cons
                      (when title
                        (etaf-node 'text (list :font-weight 'bold) (list title)))
                      (mapcar (lambda (chunk)
                                (if (= (length chunk) 1)
                                    (car chunk)
                                  (etaf-node 'flex (list :width 'stretch :column-gap '(ch 2) :align-items 'stretch)
                                             chunk)))
                              lane-rows))))))

(etaf-org--define-shipped 'org-query
  :name "org-query"
  :summary "Org 原生活任务/笔记查询视图（书刊无框列表，支持 table/list/timeline/kanban）"
  :attrs '((scope :type enum :one-of (file subtree workspace) :default file :doc "查询范围")
           (todo :type string :doc "过滤 TODO 关键词（逗号分隔）")
           (tags :type string :doc "过滤标签（支持 -tag 排除）")
           (priority :type string :doc "过滤优先级如 A,B")
           (where :type string :doc "属性等值过滤如 OWNER=我")
           (sort :type enum :one-of (none deadline scheduled priority title) :default none :doc "排序字段")
           (view :type enum :one-of (table list timeline kanban) :default table :doc "呈现形态")
           (columns :type string :default "TODO,NEXT,WAIT,DONE" :doc "kanban 模式栏列表")
           (limit :type number :integer t :default 50 :min 1 :max 200 :doc "最大条数")
           (title :type string :doc "标题"))
  :view (lambda (env)
          (let* ((data (plist-get (etaf-org-env-block env) :asset-data))
                 (session (etaf-org-env-session env))
                 (title (or (etaf-org-attr env :title) "Org 查询结果"))
                 (mode (or (etaf-org-attr env :view) 'table))
                 (muted (etaf-org--muted env))
                 (faint (or (etaf-org--env-color env :faint) muted)))
            (or (etaf-org-widgets--asset-error-view env data "正在查询 Org 节点…")
                (let ((rows (plist-get data :rows)))
                  (cond
                   ((eq mode 'kanban)
                    (etaf-org-widgets--render-kanban-columns
                     env session rows
                     (split-string (or (etaf-org-attr env :columns) "TODO,NEXT,WAIT,DONE") "[, \t]+" t)
                     title))
                   ((null rows)
                    (etaf-node 'text (list :color muted) (list (format "%s：无匹配条目" title))))
                   (t
                    (etaf-node
                     'column (list :width 'stretch :item-gap '(lh 0))
                     (append
                      (list
                       (etaf-node 'flex (list :width 'stretch :align-items 'center :padding-bottom '(lh 1))
                                  (list (etaf-node 'text (list :font-weight 'bold) (list title))
                                        (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                                        (etaf-node 'text (list :color muted) (list (format "共 %d 条" (length rows)))))))
                      (cl-loop for r in rows for idx from 0
                               collect
                               (let ((row r)
                                     (todo (plist-get r :todo))
                                     (pri (plist-get r :priority))
                                     (dl (plist-get r :deadline))
                                     (tags (plist-get r :own-tags)))
                                 (etaf-node
                                  'flex (list :width 'stretch :column-gap '(ch 1) :align-items 'center
                                              :border-top (when (= idx 0) (etaf-org--hairline env))
                                              :border-bottom (etaf-org--hairline env))
                                  (delq nil
                                        (list
                                         (when todo
                                           (etaf-org-widgets--status-pill
                                            env todo
                                            (if (eq (plist-get row :todo-state) 'done) 'success 'warning)))
                                         (when pri
                                           (etaf-org-widgets--status-pill
                                            env (format "#%s" pri)
                                            (cond ((equal pri "A") 'danger)
                                                  ((equal pri "B") 'warning)
                                                  (t 'neutral))))
                                         (etaf-node 'box '(:flex-basis (ch 0) :flex-grow 1 :wrap-mode word)
                                                    (list (etaf-org--leaf-button
                                                           env (or (plist-get row :title) "")
                                                           (lambda () (etaf-org-widgets--jump-query-row session row))
                                                           :role 'link :color (etaf-org--env-color env :link)
                                                           :help "跳到该节")))
                                         (when dl
                                           (etaf-node 'text (list :color (if (plist-get row :overdue)
                                                                             (etaf-org-accent env 'danger)
                                                                           muted))
                                                      (list dl)))
                                         (when tags
                                           (etaf-node 'text (list :color faint)
                                                      (list (concat ":" (string-join tags ":") ":"))))))))))))))))))

(etaf-org--define-shipped 'kanban
  :name "kanban"
  :summary "Org 原生响应式多栏任务看板（从当前子树、#custom-id 或工作区生成）"
  :attrs '((source :type string :default "subtree" :doc "subtree / file / workspace / #custom-id")
           (columns :type string :default "TODO,NEXT,WAIT,DONE" :doc "看板列状态（逗号分隔）")
           (tags :type string :doc "过滤标签")
           (title :type string :doc "看板标题"))
  :view (lambda (env)
          (let* ((data (plist-get (etaf-org-env-block env) :asset-data))
                 (session (etaf-org-env-session env))
                 (cols (split-string (or (etaf-org-attr env :columns) "TODO,NEXT,WAIT,DONE") "[, \t]+" t))
                 (title (or (etaf-org-attr env :title) "任务看板")))
            (or (etaf-org-widgets--asset-error-view env data "正在构建任务看板…")
                (etaf-org-widgets--render-kanban-columns
                 env session (plist-get data :rows) cols title)))))

(etaf-org--define-shipped 'clock-summary
  :name "clock-summary"
  :summary "Org LOGBOOK 书刊无框工时统计与占比条形图"
  :attrs '((scope :type enum :one-of (file subtree) :default file :doc "统计范围")
           (group-by :type enum :one-of (section tag) :default section :doc "分组维度")
           (title :type string :default "工时统计" :doc "标题"))
  :view (lambda (env)
          (let* ((data (plist-get (etaf-org-env-block env) :asset-data))
                 (title (or (etaf-org-attr env :title) "工时统计"))
                 (total (or (plist-get data :total-minutes) 0))
                 (items (plist-get data :items))
                 (accent (etaf-org-accent env 'primary))
                 (muted (etaf-org--muted env))
                 (faint (or (etaf-org--env-color env :faint) muted))
                 (avail (etaf-org-available-width env)))
            (etaf-node
             'column (list :width 'stretch :item-gap '(lh 0))
             (append
              (list
               (etaf-node 'flex (list :width 'stretch :align-items 'center :padding-bottom '(lh 1))
                          (list (etaf-node 'text (list :font-weight 'bold) (list title))
                                (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                                (etaf-node 'text (list :color accent :font-weight 'bold)
                                           (list (format "总计 %d:%02d" (/ total 60) (% total 60)))))))
              (if (null items)
                  (list (etaf-node 'text (list :color muted) '("（暂无 CLOCK 工时记录）")))
                (let* ((mx (max 1 (apply #'max 1 (mapcar #'cdr items))))
                       (lw (min 22 (max 8 (apply #'max 8 (mapcar (lambda (p) (string-width (car p))) items)))))
                       (bar-cap (max 10 (min 30 (- avail lw 16)))))
                  (mapcar (lambda (pair)
                            (let* ((mins (cdr pair))
                                   (filled (max 1 (min bar-cap (round (* bar-cap (/ (float mins) mx))))))
                                   (empty (max 0 (- bar-cap filled)))
                                   (pct (if (> total 0) (round (* 100.0 (/ (float mins) total))) 0)))
                              (etaf-node
                               'flex (list :width 'stretch :column-gap '(ch 1) :align-items 'center)
                               (list
                                (etaf-node 'box (list :width (list 'ch lw) :flex-shrink 0 :text-align 'right)
                                           (list (etaf-node 'text (list :color muted)
                                                            (list (truncate-string-to-width (car pair) lw nil nil "…")))))
                                (etaf-node 'flex (list :column-gap '(ch 0))
                                           (delq nil
                                                 (list
                                                  (etaf-node 'text (list :color accent)
                                                             (list (make-string filled ?█)))
                                                  (when (> empty 0)
                                                    (etaf-node 'text (list :color faint)
                                                               (list (make-string empty ?░)))))))
                                (etaf-node 'text (list :font-weight 'bold)
                                           (list (format "%d:%02d (%d%%)" (/ mins 60) (% mins 60) pct)))))))
                          items))))))))

(etaf-org--define-shipped 'transclude
  :name "transclude"
  :summary "L1 只读活嵌入另一篇 Org 文档的指定章节"
  :attrs '((target :type string :required t :doc "目标如 file:arch.org::#invariants")
           (only-contents :type boolean :default nil :doc "仅嵌入正文，不重复标题")
           (title :type string :doc "覆盖标题"))
  :view (lambda (env)
          (let ((data (plist-get (etaf-org-env-block env) :asset-data))
                (session (etaf-org-env-session env)))
            (or (etaf-org-widgets--asset-error-view env data "正在嵌入源节…")
                (let* ((title (or (etaf-org-attr env :title) (plist-get data :title)))
                       (target (plist-get data :target))
                       (blocks (plist-get data :blocks))
                       (leg (etaf-org-env-legacy-env env))
                       (body-views (etaf-org--block-views blocks leg))
                       (imp (etaf-org-accent env 'important)))
                  (etaf-node 'column
                             (list :width 'stretch :item-gap '(lh 1)
                                   :background-color (etaf-org--env-color env :quote-bg)
                                   :border-left (list '(px 3) 'solid imp)
                                   :padding '((lh 1) (ch 2)))
                             (delq nil
                                   (append
                                    (list
                                     (etaf-node 'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2))
                                                (list (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 12)
                                                                            :wrap-mode 'word)
                                                                 (list (etaf-node 'text (list :color imp :font-weight 'bold)
                                                                                  (list (format "⇄ %s" (or title target))))))
                                                      (etaf-node 'box (list :flex-shrink 0)
                                                                 (list (etaf-org--leaf-button
                                                                        env "跳转源节 ↗"
                                                                        (lambda () (when session (etaf-org--open-target session target)))
                                                                        :role 'link :color (etaf-org--muted env) :help target))))))
                                    body-views))))))))

(etaf-org--define-shipped 'backlinks
  :name "backlinks"
  :summary "L1 异步工作区反向链接面板（书刊无框清单）"
  :attrs '((scope :type enum :one-of (workspace) :default workspace :doc "扫描范围")
           (limit :type number :integer t :default 20 :min 1 :max 100 :doc "最大条数")
           (title :type string :default "反向链接" :doc "标题"))
  :view (lambda (env)
          (let ((data (plist-get (etaf-org-env-block env) :asset-data))
                (title (or (etaf-org-attr env :title) "反向链接"))
                (muted (etaf-org--muted env)))
            (or (etaf-org-widgets--asset-error-view env data "正在扫描反向链接…")
                (let ((links (plist-get data :links)))
                  (etaf-node
                   'column (list :width 'stretch :item-gap '(lh 0))
                   (append
                    (list
                     (etaf-node 'flex (list :width 'stretch :align-items 'center :padding-bottom '(lh 1))
                                (list (etaf-node 'text (list :font-weight 'bold) (list title))
                                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                                      (etaf-node 'text (list :color muted)
                                                 (list (format "%d 处引用" (length links)))))))
                    (if (null links)
                        (list (etaf-node 'text (list :color muted) '("（工作区内未发现反向链接）")))
                      (cl-loop for hit in links for idx from 0
                               collect
                               (let ((file (plist-get hit :file))
                                     (line (plist-get hit :line)))
                                 (etaf-node
                                  'column (list :width 'stretch :item-gap '(lh 0)
                                                :border-top (when (= idx 0) (etaf-org--hairline env))
                                                :border-bottom (etaf-org--hairline env)
                                                :padding '((lh 0) (ch 0)))
                                  (list
                                   (etaf-org--leaf-button
                                    env (format "%s:%d ↗" (plist-get hit :rel) line)
                                    (lambda ()
                                      (find-file-other-window file)
                                      (goto-char (point-min))
                                      (forward-line (1- line)))
                                    :role 'link :color (etaf-org--env-color env :link) :bold t)
                                   (etaf-node 'box '(:width stretch :wrap-mode word :padding-left (ch 2))
                                              (list (etaf-node 'text (list :color muted)
                                                               (list (or (plist-get hit :context) "")))))))))))))))))

;;; ---------------------------------------------------------------------------
;;; 5. L2 Explicit Controlled Action Widget: run
;;; ---------------------------------------------------------------------------

(etaf-org--define-shipped 'run
  :name "run"
  :summary "L2 显式确认命令运行卡（绝不自动执行，对齐 etaf-md Runbook）"
  :attrs '((title :type string :default "运行命令" :doc "卡片标题"))
  :view (lambda (env)
          (let* ((title (or (etaf-org-attr env :title) "运行命令"))
                 (first-src (etaf-org-widgets--first-src-block env))
                 (lang (or (and first-src (plist-get first-src :lang)) "sh"))
                 (cmd (string-trim (or (and first-src (plist-get first-src :text))
                                       (plist-get (etaf-org-env-block env) :raw-content) "")))
                 (status (etaf-org-block-state env :status))
                 (out (etaf-org-block-state env :output))
                 (mono (etaf-org--mono-family))
                 (muted (etaf-org--muted env))
                 (ok-fg (etaf-org-accent env 'success))
                 (bad-fg (etaf-org-accent env 'danger)))
            (etaf-node
             'column (list :width 'stretch :item-gap '(lh 0)
                           :border (etaf-org--hairline env)
                           :background-color (etaf-org-surface env 'raised))
             (delq nil
                   (list
                    (etaf-node
                     'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                                 :padding '((lh 0) (ch 2))
                                 :border-bottom (etaf-org--hairline env))
                     (list
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :min-width '(ch 12)
                                            :wrap-mode 'word)
                                 (list (etaf-node 'text (list :font-weight 'bold)
                                                  (list (format "$ %s" title)))))
                      (etaf-node 'box (list :flex-shrink 0)
                                 (list
                                  (cond
                                   ((null etaf-org-allow-actions)
                                    (etaf-node 'text (list :color muted) '("执行已禁用")))
                                   ((eq status 'running)
                                    (etaf-node 'text (list :color muted) '("执行中…")))
                                   (t
                                    (etaf-org--leaf-button
                                     env (if out "▶ 重新运行" "▶ 运行")
                                     (lambda () (etaf-org-assets-run-command env cmd))
                                     :bold t :help (format "显式确认后执行：%s" cmd))))))))
                    (if (string-empty-p cmd)
                        (etaf-node 'box (list :width 'stretch :padding '((lh 1) (ch 2)))
                                   (list (etaf-node 'text (list :color muted) '("（空命令）"))))
                      (etaf-org-widgets--code-view env cmd lang))
                    (when out
                      (etaf-node
                       'column (list :width 'stretch :item-gap '(lh 0)
                                     :background-color (etaf-org-surface env 'sunken)
                                     :border-top (etaf-org--hairline env)
                                     :padding '((lh 1) (ch 2)))
                       (list
                        (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                                   (list (etaf-node 'text (list :font-family mono
                                                                :color (if (eq status 'error) bad-fg ok-fg))
                                                    (list out))))
                        (etaf-node 'box (list :width 'stretch :margin-top '(lh 1))
                                   (list (etaf-node 'text (list :color muted)
                                                    '("安全门禁：仅显式点击触发，默认经确认后执行")))))))))))))

(provide 'etaf-org-widgets)
;;; etaf-org-widgets.el ends here
