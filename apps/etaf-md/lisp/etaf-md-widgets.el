;;; etaf-md-widgets.el --- Focused editorial and living-doc widgets for etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Curated Markdown container widgets for `etaf-md', designed in the same
;; restrained editorial / booktabs aesthetic as the base reader:
;; - Lightweight structure (`progress', `keymap', `breadcrumb')
;; - Comparison & live examples (`diff', `pros-cons', `demo')
;; - Emacs living-document blocks (`include', `code-ref', `symbol',
;;   `project-tree', `git-log', `git-diff', `run')
;;
;; Every view reads only its `env' and pre-attached `:asset-data' snapshots;
;; filesystem reads, subprocesses and user-triggered commands live in
;; `etaf-md-assets' and never run inside `:render'.  Hover styling follows
;; strict leaf-only discipline: static prose, code lines and active/selected
;; tabs never carry hover faces.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf-md-node)
(require 'etaf-md-env)
(require 'etaf-md-assets)
(require 'etaf-ui)
(require 'etaf-doc)

(declare-function etaf-md--child-view "etaf-md-nodes" (env child))
(declare-function etaf-md--component-ink "etaf-md-components" (env key))

;;; ---------------------------------------------------------------------------
;;; Shared helpers
;;; ---------------------------------------------------------------------------

(defun etaf-md--widget-asset (env)
  "Return the pre-attached `:asset-data' plist on ENV's container node, or nil."
  (let* ((node (etaf-md-env-node env))
         (block (and node (etaf-md-node-block node))))
    (and (listp block) (plist-get block :asset-data))))

(defun etaf-md--widget-list-items (env)
  "Return plain text strings of all top-level list items inside ENV."
  (let ((items nil))
    (dolist (child (etaf-md-children env))
      (when (eq (etaf-md-node-type child) 'list)
        (dolist (li (etaf-md-children env child))
          (when (eq (etaf-md-node-type li) 'list-item)
            (push (or (etaf-md-attr env :text li) "") items)))))
    (nreverse items)))

(defun etaf-md--widget-first-code (env &optional node)
  "Return the first `code-block' plist inside NODE (or ENV), or nil."
  (let* ((kids (etaf-md-children env node))
         (code (seq-find (lambda (c) (eq (etaf-md-node-type c) 'code-block)) kids)))
    (and code (etaf-md-node-block code))))

(defun etaf-md--widget-code-view (env text lang &optional start-line)
  "Return a frameless, headerless syntax-highlighted code View for TEXT in ENV."
  (let ((block (list :type 'code-block
                     :lang (or lang "text")
                     :header nil
                     :frame nil
                     :text (or text ""))))
    (when (and (integerp start-line) (> start-line 0))
      (setq block (plist-put block :info
                             (format "%s :line-numbers=%d"
                                     (or lang "text") start-line))))
    (etaf-doc-markdown-view-block block (etaf-md--markdown-env env))))

(defun etaf-md--widget-error-body (env message)
  "Return a concise danger-colored fallback text View for MESSAGE in ENV."
  (etaf-doc-widget-notice (etaf-md-env-palette env) message 'danger))

(defun etaf-md--widget-loading-body (env message)
  "Return a muted loading placeholder View for MESSAGE in ENV."
  (etaf-doc-widget-notice (etaf-md-env-palette env) message 'loading))

(defun etaf-md--widget-pill (env label active-p on-press &optional help)
  "Return a compact toggle pill with LABEL."
  (etaf-doc-widget-pill (etaf-md-env-palette env) label active-p on-press help
                        (etaf-md--hover-p env)))

;;; ---------------------------------------------------------------------------
;;; 1. Lightweight editorial structure: progress, keymap, breadcrumb
;;; ---------------------------------------------------------------------------

(defun etaf-md--progress-parse-row (line)
  "Parse LINE as `(LABEL VALUE MAX PERCENT DISPLAY)' for `progress', or nil."
  (let ((s (string-trim (or line ""))))
    (cond
     ((string-match "\\`\\(.+?\\)[ \t]*[:：][ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[ \t]*/[ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\'" s)
      (let* ((lbl (string-trim (match-string 1 s)))
             (val (string-to-number (match-string 2 s)))
             (mx (max 0.001 (float (string-to-number (match-string 3 s)))))
             (pct (min 100 (max 0 (round (* 100.0 (/ (float val) mx)))))))
        (list lbl val mx pct (format "%d%%  (%s/%s)" pct (match-string 2 s) (match-string 3 s)))))
     ((string-match "\\`\\(.+?\\)[ \t]*[:：][ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)%\\'" s)
      (let* ((lbl (string-trim (match-string 1 s)))
             (val (min 100 (max 0 (string-to-number (match-string 2 s)))))
             (pct (round val)))
        (list lbl val 100 pct (format "%d%%" pct))))
     (t nil))))

(etaf-md--define-shipped 'progress
  :name "progress"
  :summary "简洁进度条（单条或列表多条，无重外框）"
  :attrs '((title  :type string :doc "进度组标题")
           (value  :type number :doc "单条当前值")
           (max    :type number :default 100 :doc "单条最大值，默认 100")
           (label  :type string :doc "单条标签")
           (accent :type accent :default primary :doc "进度条主色"))
  :view
  (lambda (env)
    (let* ((title (etaf-md-attr env :title))
           (single-val (etaf-md-attr env :value))
           (single-max (max 1 (or (etaf-md-attr env :max) 100)))
           (single-label (or (etaf-md-attr env :label) title "进度"))
           (accent-col (etaf-md-accent env (or (etaf-md-attr env :accent) 'primary)))
           (avail (etaf-md-available-width env))
           (rows (if (numberp single-val)
                     (let ((pct (min 100 (max 0 (round (* 100.0 (/ (float single-val) single-max)))))))
                       (list (list single-label single-val single-max pct (format "%d%%" pct))))
                   (delq nil (mapcar #'etaf-md--progress-parse-row
                                     (etaf-md--widget-list-items env))))))
      (if (null rows)
          (etaf-md--widget-error-body env "progress 需要 value 属性或「标签 : 数值%」列表")
        (etaf-doc-widget-progress-bars
         (etaf-md-env-palette env) rows avail
         (list :title (when (and title (null single-val)) title)
               :accent accent-col))))))

(defun etaf-md--keymap-chord-nodes (env chord)
  "Render key CHORD into subtle keycap pills; keep `/' as a plain separator."
  (let* ((mono (face-attribute 'fixed-pitch :family nil t))
         (ink (etaf-md--component-ink env :ink))
         (muted (etaf-md--muted env))
         (faint (or (etaf-md--palette-value (etaf-md-env-palette env) :faint) muted))
         (cap-bg (or (etaf-md--palette-value (etaf-md-env-palette env) :panel2)
                     (etaf-md-surface env 'raised)))
         (alts (split-string (string-trim chord) "[ \t]*/[ \t]*" t))
         (nodes nil))
    (cl-loop for alt in alts
             for alt-idx from 0 do
             (when (> alt-idx 0)
               (push (etaf-node 'text (list :color faint) (list " / ")) nodes))
             (let ((tokens (split-string (string-trim alt) "[ \t]+" t)))
               (cl-loop for tok in tokens
                        for tok-idx from 0 do
                        (when (> tok-idx 0)
                          (push (etaf-node 'text nil (list " ")) nodes))
                        (push (etaf-node 'text
                                         (list :font-family mono
                                               :color ink
                                               :background-color cap-bg
                                               :font-weight 'bold)
                                         (list (format " %s " tok)))
                              nodes))))
    (etaf-node 'flex (list :align-items 'center) (nreverse nodes))))

(etaf-md--define-shipped 'keymap
  :name "keymap"
  :summary "书刊定宽快捷键速查表（斜杠不画键帽，无外框）"
  :attrs '((title   :type string :doc "快捷键组标题")
           (columns :type number :default 2 :min 1 :max 3 :integer t :doc "列数，默认 2"))
  :accepts '((list :attrs nil))
  :view
  (lambda (env)
    (let* ((title (etaf-md-attr env :title))
           (req-cols (or (etaf-md-attr env :columns) 2))
           (avail (etaf-md-available-width env))
           (cols (if (< avail 56) 1 (min req-cols 2)))
           (raw (etaf-md--widget-list-items env))
           (pairs
            (delq nil
                  (mapcar
                   (lambda (line)
                     (let ((s (string-trim line)))
                       (if (string-match "\\`\\(.+?\\)[ \t]*[:：][ \t]*\\(.+\\)\\'" s)
                           (cons (string-trim (match-string 1 s))
                                 (string-trim (match-string 2 s)))
                         (unless (string-empty-p s) (cons s "")))))
                   raw)))
           (key-w (min 16 (max 10 (if pairs
                                      (+ 4 (apply #'max
                                                  (mapcar (lambda (p) (string-width (car p)))
                                                          pairs)))
                                    10))))
           (muted (etaf-md--muted env)))
      (if (null pairs)
          (etaf-md--widget-error-body env "keymap 需要「快捷键 : 说明」列表")
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
                          :padding '((lh 0) (ch 0))
                          :border-top (when (= row-idx 0) (etaf-md--hairline env))
                          :border-bottom (etaf-md--hairline env))
                    (cl-loop for pair in row
                             collect
                             (etaf-node
                              'flex (list :flex-basis '(ch 0) :flex-grow 1 :width 'stretch
                                          :align-items 'center :column-gap '(ch 2)
                                          :padding '((lh 0) (ch 0)))
                              (list
                               (etaf-node 'box (list :width (list 'ch key-w) :flex-shrink 0)
                                          (list (etaf-md--keymap-chord-nodes env (car pair))))
                               (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1
                                                     :wrap-mode 'word)
                                          (list (etaf-node 'text (list :color muted)
                                                           (list (cdr pair))))))))))))))))

(defun etaf-md--breadcrumb-parse (line)
  "Parse breadcrumb item LINE -> (LABEL . URL-OR-NIL)."
  (let ((s (string-trim (or line ""))))
    (cond
     ((string-match "\\`\\[\\([^]]+\\)\\](\\([^)]+\\))\\'" s)
      (cons (string-trim (match-string 1 s)) (string-trim (match-string 2 s))))
     ((string-match "\\`\\(.+?\\)[ \t]*|[ \t]*\\(.+\\)\\'" s)
      (cons (string-trim (match-string 1 s)) (string-trim (match-string 2 s))))
     ((not (string-empty-p s))
      (cons s nil)))))

(defun etaf-md--breadcrumb-parse-items (items-str)
  "Parse inline `items' string like `[Home](a.md) > Guide > Page' into conses."
  (when (and (stringp items-str) (not (string-blank-p items-str)))
    (delq nil
          (mapcar #'etaf-md--breadcrumb-parse
                  (split-string items-str "[>›]" t "[ \t]+")))))

(etaf-md--define-shipped 'breadcrumb
  :name "breadcrumb"
  :summary "行内文档层级面包屑（无外框）"
  :attrs '((items     :type string :doc "用 > 分隔的层级路径，支持 [标签](链接)")
           (separator :type string :default "›" :doc "分隔符，默认 ›"))
  :view
  (lambda (env)
    (let* ((sep (or (etaf-md-attr env :separator) "›"))
           (items (or (etaf-md--breadcrumb-parse-items (etaf-md-attr env :items))
                      (delq nil (mapcar #'etaf-md--breadcrumb-parse
                                        (etaf-md--widget-list-items env)))))
           (last-idx (1- (length items)))
           (faint (or (etaf-md--palette-value (etaf-md-env-palette env) :faint)
                      (etaf-md--muted env)))
           (muted (etaf-md--muted env))
           (ink (etaf-md--component-ink env :ink))
           (nodes nil))
      (cl-loop for item in items
               for idx from 0 do
               (when (> idx 0)
                 (push (etaf-node 'text (list :color faint) (list (format " %s " sep)))
                       nodes))
               (let ((lbl (car item))
                     (url (cdr item))
                     (is-last (= idx last-idx)))
                 (push
                  (cond
                   ((and url (not is-last))
                    (etaf-md--leaf-button env lbl
                                          (lambda () (etaf-md-follow-link env url))
                                          :role 'link :help url))
                   (is-last
                    (etaf-node 'text (list :color ink :font-weight 'bold) (list lbl)))
                   (t
                    (etaf-node 'text (list :color muted) (list lbl))))
                  nodes)))
      (etaf-node 'flex (list :width 'stretch :align-items 'center)
                 (nreverse nodes)))))

;;; ---------------------------------------------------------------------------
;;; 2. Comparison & live examples: diff, pros-cons, demo
;;; ---------------------------------------------------------------------------

(defun etaf-md--diff-extract-lines (env child)
  "Extract raw text lines from diff slot CHILD in ENV."
  (let ((code (etaf-md--widget-first-code env child)))
    (if code
        (split-string (string-trim-right (or (plist-get code :text) "") "\n") "\n")
      (let* ((block (etaf-md-node-block child))
             (kids (and (listp block) (plist-get block :children))))
        (split-string
         (string-trim-right
          (mapconcat (lambda (b) (or (plist-get b :text) "")) kids "\n")
          "\n")
         "\n")))))

(defun etaf-md--diff-compute-ops (old-lines new-lines)
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

(defun etaf-md--diff-pair-rows (ops)
  "Group LCS OPS into paired `(LEFT . RIGHT)' rows for aligned split view.
Contiguous `del' and `add' runs are zipped side-by-side so changes align row
for row; asymmetric runs pad the shorter side with nil."
  (let ((rows nil)
        (dels nil)
        (adds nil))
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
          ('same
           (flush)
           (push (cons op op) rows))
          ('del (push op dels))
          ('add (push op adds))))
      (flush))
    (nreverse rows)))

(defun etaf-md--diff-cell-view (env op side)
  "Return one static diff cell View for OP on SIDE (`left', `right', `unified')."
  (let* ((mono (face-attribute 'fixed-pitch :family nil t))
         (palette (etaf-md-env-palette env))
         (ink (etaf-md--component-ink env :ink))
         (muted (etaf-md--muted env))
         (faint (or (etaf-md--palette-value palette :faint) muted))
         (ok-fg (etaf-md-accent env 'success))
         (del-fg (etaf-md-accent env 'danger))
         (ok-bg (or (etaf-md--palette-value palette :ok-soft) (etaf-md-surface env 'raised)))
         (del-bg (or (etaf-md--palette-value palette :danger-soft) (etaf-md-surface env 'raised)))
         (empty-bg (etaf-md-surface env 'sunken)))
    (if (null op)
        (etaf-node 'box (list :width 'stretch :background-color empty-bg
                              :padding '((lh 0) (ch 1)))
                   (list (etaf-node 'text (list :font-family mono :color faint)
                                    (list " "))))
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
          (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'char)
                     (list (etaf-node 'text (list :font-family mono :color ink)
                                      (list (if (string-empty-p txt) " " txt)))))))))))

(etaf-md--define-shipped 'diff
  :name "diff"
  :summary "配对对齐的代码 Diff（宽窗并排、窄窗自动统一）"
  :attrs '((title :type string :doc "标题")
           (mode  :type enum :one-of (side unified) :default side :doc "默认视图模式"))
  :accepts '((before :attrs ((title :type string :doc "旧版本标题")))
             (after  :attrs ((title :type string :doc "新版本标题"))))
  :child-syntax 'markers
  :view
  (lambda (env)
    (let* ((kids (etaf-md-children env))
           (old-node (seq-find (lambda (c) (eq (etaf-md-node-type c) 'before)) kids))
           (new-node (seq-find (lambda (c) (eq (etaf-md-node-type c) 'after)) kids)))
      (if (not (and old-node new-node))
          (etaf-md--widget-error-body env "diff 需要 @before 与 @after 两个子块")
        (let* ((title (or (etaf-md-attr env :title) "代码变更"))
               (old-title (or (etaf-md-attr env :title old-node) "旧实现"))
               (new-title (or (etaf-md-attr env :title new-node) "新实现"))
               (old-lines (etaf-md--diff-extract-lines env old-node))
               (new-lines (etaf-md--diff-extract-lines env new-node))
               (ops (etaf-md--diff-compute-ops old-lines new-lines))
               (adds (cl-count 'add ops :key #'car))
               (dels (cl-count 'del ops :key #'car))
               (avail (etaf-md-available-width env))
               (pref (etaf-md-block-state env :mode (or (etaf-md-attr env :mode) 'side)))
               (split-p (and (eq pref 'side) (>= avail 72)))
               (ok-fg (etaf-md-accent env 'success))
               (del-fg (etaf-md-accent env 'danger))
               (muted (etaf-md--muted env)))
          (etaf-node
           'column (list :width 'stretch :item-gap '(lh 0)
                         :border (etaf-md--hairline env)
                         :background-color (etaf-md-surface env 'raised))
           (list
            ;; Compact top header bar
            (etaf-node
             'flex (list :width 'stretch :align-items 'center :column-gap '(ch 1)
                         :padding '((lh 0) (ch 2))
                         :border-bottom (etaf-md--hairline env))
             (list
              (etaf-node 'text (list :font-weight 'bold) (list title))
              (etaf-node 'text (list :color ok-fg :font-weight 'bold)
                         (list (format "+%d" adds)))
              (etaf-node 'text (list :color del-fg :font-weight 'bold)
                         (list (format "-%d" dels)))
              (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
              (etaf-md--widget-pill env "并排" split-p
                                    (lambda () (etaf-md-set-block-state env :mode 'side))
                                    "并排对齐视图")
              (etaf-md--widget-pill env "统一" (not split-p)
                                    (lambda () (etaf-md-set-block-state env :mode 'unified))
                                    "单列统一视图")))
            (if split-p
                (let ((paired (etaf-md--diff-pair-rows ops)))
                  (etaf-node
                   'column (list :width 'stretch :item-gap '(lh 0))
                   (cons
                    ;; Sub-header naming old vs new sides
                    (etaf-node
                     'flex (list :width 'stretch :border-bottom (etaf-md--hairline env))
                     (list
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1
                                            :padding '((lh 0) (ch 2))
                                            :border-right (etaf-md--hairline env))
                                 (list (etaf-node 'text (list :color del-fg)
                                                  (list old-title))))
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1
                                            :padding '((lh 0) (ch 2)))
                                 (list (etaf-node 'text (list :color ok-fg)
                                                  (list new-title))))))
                    (mapcar
                     (lambda (pair)
                       (etaf-node
                        'flex (list :width 'stretch :align-items 'stretch)
                        (list
                         (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1
                                               :border-right (etaf-md--hairline env))
                                    (list (etaf-md--diff-cell-view env (car pair) 'left)))
                         (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1)
                                    (list (etaf-md--diff-cell-view env (cdr pair) 'right))))))
                     paired))))
              ;; Unified mode (explicitly chosen or auto-fallback < 72 cols)
              (etaf-node
               'column (list :width 'stretch :item-gap '(lh 0))
               (append
                (when (and (eq pref 'side) (< avail 72))
                  (list (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 2))
                                              :border-bottom (etaf-md--hairline env))
                                   (list (etaf-node 'text (list :color muted)
                                                    (list "窄窗自动切换为统一视图"))))))
                (mapcar (lambda (op) (etaf-md--diff-cell-view env op 'unified))
                        ops)))))))))))

(etaf-md--define-shipped 'pros-cons
  :name "pros-cons"
  :summary "无外框等高优劣权衡对比（窄窗自动堆叠）"
  :attrs '((title :type string :doc "可选整体标题"))
  :accepts '((pro :attrs ((title :type string :doc "优势栏标题")))
             (con :attrs ((title :type string :doc "局限栏标题"))))
  :child-syntax 'markers
  :view
  (lambda (env)
    (let* ((kids (etaf-md-children env))
           (title (etaf-md-attr env :title))
           (pros (seq-find (lambda (c) (eq (etaf-md-node-type c) 'pro)) kids))
           (cons-n (seq-find (lambda (c) (eq (etaf-md-node-type c) 'con)) kids))
           (p-title (or (and pros (etaf-md-attr env :title pros)) "优势"))
           (c-title (or (and cons-n (etaf-md-attr env :title cons-n)) "局限"))
           (avail (etaf-md-available-width env))
           (side-by-side (>= avail 68))
           (col-w (if side-by-side (max 16 (- (/ (- avail 2) 2) 5)) (max 16 (- avail 5))))
           (inner-env (etaf-md--env-with-width env col-w))
           (palette (etaf-md-env-palette env))
           (ok-fg (etaf-md-accent env 'success))
           (ok-bg (or (etaf-md--palette-value palette :ok-soft) (etaf-md-surface env 'raised)))
           (bad-fg (etaf-md-accent env 'danger))
           (bad-bg (or (etaf-md--palette-value palette :danger-soft) (etaf-md-surface env 'raised)))
           (make-pane
            (lambda (label fg bg node)
              (etaf-node
               'column
               (append
                (list :item-gap '(lh 0)
                      :background-color bg
                      :border-left (list '(px 3) 'solid fg)
                      :padding '((lh 1) (ch 2)))
                (if side-by-side
                    (list :flex-basis '(ch 0) :flex-grow 1 :width 'stretch)
                  (list :width 'stretch)))
               (delq nil
                     (list
                      (etaf-node 'text (list :color fg :font-weight 'bold) (list label))
                      (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)
                      (when node (etaf-md--child-view inner-env node)))))))
           (body (if side-by-side
                     (etaf-node 'flex (list :width 'stretch :column-gap '(ch 2) :align-items 'stretch)
                                (list (funcall make-pane (concat "✓ " p-title) ok-fg ok-bg pros)
                                      (funcall make-pane (concat "× " c-title) bad-fg bad-bg cons-n)))
                   (etaf-node 'column (list :width 'stretch :item-gap '(lh 1))
                              (list (funcall make-pane (concat "✓ " p-title) ok-fg ok-bg pros)
                                    (funcall make-pane (concat "× " c-title) bad-fg bad-bg cons-n))))))
      (if title
          (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
                     (list (etaf-node 'text (list :font-weight 'bold) (list title))
                           (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)
                           body))
        body))))

(etaf-md--define-shipped 'demo
  :name "demo"
  :summary "清爽效果预览画布 + 底部轻条按需展开源码"
  :attrs '((title :type string :default "效果预览" :doc "底栏说明")
           (open  :type boolean :default nil :doc "默认展开源码"))
  :view
  (lambda (env)
    (let* ((title (or (etaf-md-attr env :title) "效果预览"))
           (open (etaf-md-block-state env :open (etaf-md-attr env :open)))
           (raw (let ((src (or (etaf-md-node-source (etaf-md-env-node env)) "")))
                  (string-trim
                   (replace-regexp-in-string
                    "\\`[ \t]*:::[^\n]*\n\\|\n[ \t]*:::[ \t]*\\'" "" src))))
           (avail (etaf-md-available-width env))
           (inner-env (etaf-md--env-with-width env (max 16 (- avail 4))))
           (muted (etaf-md--muted env)))
      (etaf-node
       'column (list :width 'stretch :item-gap '(lh 0)
                     :border (etaf-md--hairline env))
       (delq nil
             (list
              ;; Clean preview canvas with no noisy top bar
              (etaf-node 'box (list :width 'stretch :padding '((lh 1) (ch 2)))
                         (list (etaf-md-content inner-env)))
              ;; Thin footer bar: muted label left, toggle + copy leaf links right
              (etaf-node
               'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                           :padding '((lh 0) (ch 2))
                           :background-color (etaf-md-surface env 'raised)
                           :border-top (etaf-md--hairline env))
               (list
                (etaf-node 'text (list :color muted) (list title))
                (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                (etaf-md--leaf-button
                 env (if open "收起源码" "查看源码")
                 (lambda () (etaf-md-set-block-state env :open (not open)))
                 :help "展开或收起原始 Markdown")
                (etaf-md--leaf-button
                 env "复制"
                 (lambda ()
                   (kill-new raw)
                   (message "已复制演示源码"))
                 :help "复制原始 Markdown")))
              ;; Flush frameless source block when open
              (when open
                (etaf-node 'box (list :width 'stretch
                                      :background-color (etaf-md-surface env 'sunken)
                                      :border-top (etaf-md--hairline env))
                           (list (etaf-md--widget-code-view env raw "markdown"))))))))))

;;; ---------------------------------------------------------------------------
;;; 3. Emacs living-document widgets: include, code-ref, symbol,
;;;    project-tree, git-log, git-diff, run
;;; ---------------------------------------------------------------------------

(defun etaf-md--source-frame-view (env title meta code-text lang start-line abs-path)
  "Paint a single-frame living-doc code card without double borders."
  (let ((session (etaf-md-env-session env))
        (muted (etaf-md--muted env)))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0)
                   :border (etaf-md--hairline env)
                   :background-color (etaf-md-surface env 'raised))
     (list
      (etaf-node
       'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                   :padding '((lh 0) (ch 2))
                   :border-bottom (etaf-md--hairline env))
       (delq nil
             (list
              (etaf-node 'text (list :font-weight 'bold) (list title))
              (when (and meta (not (string-empty-p meta)))
                (etaf-node 'text (list :color muted) (list meta)))
              (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
              (when abs-path
                (etaf-md--leaf-button
                 env "跳源码"
                 (lambda () (etaf-md-assets-jump-file session abs-path start-line))
                 :role 'link :help (format "在 Emacs 中打开 %s" abs-path)))
              (etaf-md--leaf-button
               env "复制"
               (lambda ()
                 (kill-new (or code-text ""))
                 (message "已复制源码片段"))
               :help "复制此源码片段"))))
      (etaf-md--widget-code-view env code-text lang start-line)))))

(etaf-md--define-shipped 'include
  :name "include"
  :summary "直接嵌入工作区真实源码片段（单层代码块，可跳源码）"
  :attrs '((src     :type string :required t :doc "工作区内相对路径")
           (lines   :type string :doc "行号范围，如 10-30")
           (region  :type string :doc "#region 名称")
           (section :type string :doc "Markdown 标题节名")
           (lang    :type string :doc "覆盖高亮语言")
           (title   :type string :doc "自定义标题"))
  :view
  (lambda (env)
    (let ((data (etaf-md--widget-asset env)))
      (cond
       ((null data) (etaf-md--widget-loading-body env "等待载入源码…"))
       ((plist-get data :error)
        (etaf-md--widget-error-body env (plist-get data :error)))
       (t
        (let* ((rel (plist-get data :rel))
               (title (or (etaf-md-attr env :title) rel))
               (sline (plist-get data :start-line))
               (eline (plist-get data :end-line))
               (meta (format "L%d–L%d" sline eline)))
          (etaf-md--source-frame-view
           env title meta (plist-get data :content) (plist-get data :lang)
           sline (plist-get data :path))))))))

(etaf-md--define-shipped 'code-ref
  :name "code-ref"
  :summary "按符号名自动抓取完整顶层定义并保持与源码同步"
  :attrs '((src     :type string :required t :doc "工作区内源码路径")
           (symbol  :type string :doc "函数/宏/变量/类定义名")
           (lines   :type string :doc "回退行号范围")
           (context :type number :default 0 :integer t :min 0 :doc "上下附加行数")
           (lang    :type string :doc "覆盖语言")
           (title   :type string :doc "自定义标题"))
  :view
  (lambda (env)
    (let ((data (etaf-md--widget-asset env)))
      (cond
       ((null data) (etaf-md--widget-loading-body env "等待定位源码符号…"))
       ((plist-get data :error)
        (etaf-md--widget-error-body env (plist-get data :error)))
       (t
        (let* ((rel (plist-get data :rel))
               (sym (plist-get data :symbol))
               (sline (plist-get data :start-line))
               (eline (plist-get data :end-line))
               (title (or (etaf-md-attr env :title) rel))
               (meta (if sym
                         (format "%s · L%d–L%d" sym sline eline)
                       (format "L%d–L%d" sline eline))))
          (etaf-md--source-frame-view
           env title meta (plist-get data :content) (plist-get data :lang)
           sline (plist-get data :path))))))))

(etaf-md--define-shipped 'symbol
  :name "symbol"
  :summary "Emacs 实时符号词条卡（API 词条风，完整首段文档）"
  :attrs '((name :type string :required t :doc "Emacs 函数/变量/命令名"))
  :view
  (lambda (env)
    (let ((data (etaf-md--widget-asset env))
          (session (etaf-md-env-session env))
          (mono (face-attribute 'fixed-pitch :family nil t))
          (accent (etaf-md-accent env 'primary))
          (muted (etaf-md--muted env)))
      (cond
       ((null data) (etaf-md--widget-loading-body env "正在查询 Emacs 符号…"))
       ((plist-get data :error)
        (etaf-md--widget-error-body env (plist-get data :error)))
       (t
        (let* ((name (plist-get data :name))
               (kind (plist-get data :kind))
               (sig (plist-get data :signature))
               (val (plist-get data :value))
               (doc (plist-get data :doc))
               (keys (plist-get data :keys))
               (file (plist-get data :file))
               (rel-file (plist-get data :rel-file))
               (missing (plist-get data :missing))
               (meta-parts
                (delq nil
                      (list (when rel-file (format "定义于 %s" rel-file))
                            (when keys (format "按键 %s" (string-join keys " / ")))))))
          (etaf-node
           'column (list :width 'stretch :item-gap '(lh 0)
                         :background-color (etaf-md-surface env 'raised)
                         :border-left (list '(px 3) 'solid
                                            (if missing (etaf-md-accent env 'warning) accent))
                         :padding '((lh 1) (ch 2)))
           (delq nil
                 (list
                  ;; Header row: symbol name + kind on left, doc/source links on right
                  (etaf-node
                   'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2))
                   (delq nil
                         (list
                          (etaf-node 'text (list :font-family mono :font-weight 'bold)
                                     (list (format "ƒ %s" name)))
                          (etaf-node 'text (list :color muted) (list kind))
                          (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                          (unless missing
                            (etaf-md--leaf-button
                             env "查看文档"
                             (lambda () (etaf-md-assets-open-symbol session name))
                             :role 'link :help (format "打开 %s 的 *Help* 文档" name)))
                          (when (and file (file-readable-p file))
                            (etaf-md--leaf-button
                             env "跳源码"
                             (lambda () (etaf-md-assets-jump-file session file))
                             :role 'link :help file)))))
                  ;; Signature / value row
                  (when (or sig val)
                    (etaf-node 'box (list :width 'stretch :margin-top '(lh 0))
                               (list (etaf-node 'text (list :font-family mono :color accent)
                                                (list (or sig (format "= %s" val)))))))
                  ;; Complete intact first paragraph of docstring
                  (when doc
                    (etaf-node 'box (list :width 'stretch :margin-top '(lh 1) :wrap-mode 'word)
                               (list (etaf-node 'text nil (list doc)))))
                  ;; Location / keybinding footer
                  (when meta-parts
                    (etaf-node 'box (list :width 'stretch :margin-top '(lh 1))
                               (list (etaf-node 'text (list :color muted)
                                                (list (string-join meta-parts " · ")))))))))))))))

(defun etaf-md--project-tree-rows (env items prefix clickable)
  "Render recursive `project-tree' ITEMS under PREFIX in ENV."
  (let* ((count (length items))
         (mono (face-attribute 'fixed-pitch :family nil t))
         (session (etaf-md-env-session env))
         (accent (etaf-md-accent env 'primary))
         (muted (etaf-md--muted env))
         (faint (or (etaf-md--palette-value (etaf-md-env-palette env) :faint) muted))
         (hover (etaf-md--hover-fill env 'soft))
         (rows nil))
    (cl-loop for item in items
             for idx from 0
             for last = (= idx (1- count))
             do (let* ((name (plist-get item :name))
                       (rel (plist-get item :rel))
                       (abs (plist-get item :path))
                       (dir-p (plist-get item :dir-p))
                       (kids (plist-get item :children))
                       (fold-key (cons 'ptree-fold rel))
                       (collapsed (and dir-p (etaf-md-block-state env fold-key nil)))
                       (guide (concat prefix (if last "└─ " "├─ "))))
                  (push
                   (etaf-node
                    'flex (list :width 'stretch)
                    (list
                     (etaf-node 'text (list :font-family mono :color faint) (list guide))
                     (cond
                      (dir-p
                       (etaf-node 'text
                                  (append
                                   (list :font-family mono :color accent :font-weight 'bold
                                         :role 'button :tab-index 0 :pointer 'hand
                                         :help-echo (if collapsed "展开目录" "折叠目录")
                                         :on-press (lambda ()
                                                     (etaf-md-set-block-state
                                                      env fold-key (not collapsed))))
                                   (when hover (list :hover-style (list :background-color hover))))
                                  (list (concat (if collapsed "▸ " "▾ ") name "/"))))
                      (clickable
                       (etaf-node 'text
                                  (append
                                   (list :font-family mono :color (etaf-md--component-ink env :ink)
                                         :role 'link :tab-index 0 :pointer 'hand
                                         :help-echo (format "打开 %s" abs)
                                         :on-press (lambda ()
                                                     (etaf-md-assets-jump-file session abs)))
                                   (when hover (list :hover-style (list :background-color hover))))
                                  (list name)))
                      (t
                       (etaf-node 'text (list :font-family mono :color muted) (list name))))))
                   rows)
                  (when (and dir-p kids (not collapsed))
                    (dolist (r (etaf-md--project-tree-rows
                                env kids (concat prefix (if last "   " "│  ")) clickable))
                      (push r rows)))))
    (nreverse rows)))

(etaf-md--define-shipped 'project-tree
  :name "project-tree"
  :summary "实时扫描工作区目录树（点击目录折叠、点击文件直达）"
  :attrs '((path      :type string :default "." :doc "相对路径")
           (depth     :type number :default 3 :min 1 :max 6 :integer t :doc "扫描深度")
           (title     :type string :doc "自定义标题")
           (ignore    :type string :doc "额外忽略目录，逗号分隔")
           (clickable :type boolean :default t :doc "文件是否可点击打开"))
  :view
  (lambda (env)
    (let ((data (etaf-md--widget-asset env))
          (muted (etaf-md--muted env)))
      (cond
       ((null data) (etaf-md--widget-loading-body env "正在扫描目录…"))
       ((plist-get data :error)
        (etaf-md--widget-error-body env (plist-get data :error)))
       (t
        (let ((title (or (etaf-md-attr env :title) (plist-get data :rel) "."))
              (items (plist-get data :items))
              (clickable (etaf-md-attr env :clickable)))
          (etaf-node
           'column (list :width 'stretch :item-gap '(lh 0)
                         :border (etaf-md--hairline env)
                         :background-color (etaf-md-surface env 'raised))
           (list
            (etaf-node
             'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                         :padding '((lh 0) (ch 2))
                         :border-bottom (etaf-md--hairline env))
             (list
              (etaf-node 'text (list :font-weight 'bold) (list title))
              (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
              (etaf-node 'text (list :color muted)
                         (list (if clickable "点击目录折叠 · 点击文件直达" "点击目录折叠")))))
            (etaf-node
             'column (list :width 'stretch :item-gap '(lh 0)
                           :padding '((lh 1) (ch 2)))
             (append
              (if items
                  (etaf-md--project-tree-rows env items "" clickable)
                (list (etaf-node 'text (list :color muted) (list "（空目录）"))))
              (when (plist-get data :truncated)
                (list (etaf-node 'text (list :color muted)
                                 (list "…（条目过多，已按上限截断）"))))))))))))))

(etaf-md--define-shipped 'git-log
  :name "git-log"
  :summary "书刊无框提交历史清单（兼容 Git 与 Jujutsu）"
  :attrs '((limit :type number :default 8 :min 1 :max 50 :integer t :doc "最多显示条数")
           (path  :type string :doc "限定子路径")
           (title :type string :doc "可选标题"))
  :view
  (lambda (env)
    (let ((data (etaf-md--widget-asset env))
          (title (etaf-md-attr env :title))
          (mono (face-attribute 'fixed-pitch :family nil t))
          (accent (etaf-md-accent env 'primary))
          (muted (etaf-md--muted env)))
      (cond
       ((null data) (etaf-md--widget-loading-body env "正在读取提交历史…"))
       ((plist-get data :error)
        (etaf-md--widget-error-body env (plist-get data :error)))
       (t
        (let ((commits (plist-get data :commits)))
          (etaf-node
           'column (list :width 'stretch :item-gap '(lh 0))
           (append
            (when title
              (list (etaf-node 'text (list :font-weight 'bold) (list title))
                    (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil)))
            (if (null commits)
                (list (etaf-node 'text (list :color muted) (list "（暂无提交记录）")))
              (cl-loop for c in commits
                       for idx from 0
                       collect
                       (etaf-node
                        'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                                    :padding '((lh 0) (ch 0))
                                    :border-top (when (= idx 0) (etaf-md--hairline env))
                                    :border-bottom (etaf-md--hairline env))
                        (list
                         (etaf-node 'box (list :width '(ch 8) :flex-shrink 0)
                                    (list (etaf-node 'text (list :font-family mono :color accent)
                                                     (list (plist-get c :hash)))))
                         (etaf-node 'box (list :width '(ch 11) :flex-shrink 0)
                                    (list (etaf-node 'text (list :font-family mono :color muted)
                                                     (list (plist-get c :date)))))
                         (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'word)
                                    (list (etaf-node 'text nil
                                                     (list (plist-get c :subject)))))
                         (etaf-node 'text (list :color muted)
                                    (list (plist-get c :author)))))))))))))))

(etaf-md--define-shipped 'git-diff
  :name "git-diff"
  :summary "实时展示当前工作区或提交范围的 git diff"
  :attrs '((range :type string :doc "git diff 范围，如 HEAD~1..HEAD")
           (path  :type string :doc "限定子路径")
           (title :type string :doc "标题"))
  :view
  (lambda (env)
    (let ((data (etaf-md--widget-asset env))
          (mono (face-attribute 'fixed-pitch :family nil t))
          (palette (etaf-md-env-palette env))
          (ok-fg (etaf-md-accent env 'success))
          (del-fg (etaf-md-accent env 'danger))
          (accent (etaf-md-accent env 'primary))
          (muted (etaf-md--muted env)))
      (cond
       ((null data) (etaf-md--widget-loading-body env "正在读取 git diff…"))
       ((plist-get data :error)
        (etaf-md--widget-error-body env (plist-get data :error)))
       (t
        (let* ((title (or (etaf-md-attr env :title)
                          (format "git diff%s"
                                  (if-let* ((r (plist-get data :range))) (concat " " r) ""))))
               (empty (plist-get data :empty))
               (lines (plist-get data :lines))
               (ok-bg (or (etaf-md--palette-value palette :ok-soft) (etaf-md-surface env 'raised)))
               (del-bg (or (etaf-md--palette-value palette :danger-soft) (etaf-md-surface env 'raised))))
          (etaf-node
           'column (list :width 'stretch :item-gap '(lh 0)
                         :border (etaf-md--hairline env)
                         :background-color (etaf-md-surface env 'raised))
           (list
            (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 2))
                                  :border-bottom (etaf-md--hairline env))
                       (list (etaf-node 'text (list :font-weight 'bold) (list title))))
            (if empty
                (etaf-node 'box (list :width 'stretch :padding '((lh 1) (ch 2)))
                           (list (etaf-node 'text (list :color muted)
                                            (list "（工作区干净，无未提交差异）"))))
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
                                          :padding '((lh 0) (ch 2)) :wrap-mode 'char)
                               (list (etaf-node 'text
                                                (list :font-family mono :color fg)
                                                (list (if (string-empty-p line) " " line)))))))
                lines)))))))))))

(etaf-md--define-shipped 'run
  :name "run"
  :summary "可执行 Runbook 命令行块（仅显式触发，带安全门禁与沉底输出区）"
  :attrs '((title :type string :default "运行命令" :doc "标题")
           (cwd   :type string :doc "工作区内执行目录"))
  :view
  (lambda (env)
    (let* ((title (or (etaf-md-attr env :title) "运行命令"))
           (cwd (etaf-md-attr env :cwd))
           (code (etaf-md--widget-first-code env))
           (cmd (string-trim (or (and code (plist-get code :text)) "")))
           (lang (or (and code (plist-get code :lang)) "sh"))
           (session (etaf-md-env-session env))
           (res (etaf-md-block-state env :run-result nil))
           (status (plist-get res :status))
           (mono (face-attribute 'fixed-pitch :family nil t))
           (ok-fg (etaf-md-accent env 'success))
           (bad-fg (etaf-md-accent env 'danger))
           (muted (etaf-md--muted env))
           (status-node
            (pcase status
              ('running (etaf-node 'text (list :color muted) (list "执行中…")))
              ('ok (etaf-node 'text (list :color ok-fg)
                              (list (format "exit %s · %.1fs"
                                            (or (plist-get res :exit) 0)
                                            (or (plist-get res :duration) 0.0)))))
              ('error (etaf-node 'text (list :color bad-fg)
                                 (list (format "exit %s · %.1fs"
                                               (or (plist-get res :exit) "?")
                                               (or (plist-get res :duration) 0.0)))))
              (_ nil))))
      (etaf-node
       'column (list :width 'stretch :item-gap '(lh 0)
                     :border (etaf-md--hairline env)
                     :background-color (etaf-md-surface env 'raised))
       (delq nil
             (list
              ;; Compact top strip: $ title left, exit/duration + run button right
              (etaf-node
               'flex (list :width 'stretch :align-items 'center :column-gap '(ch 2)
                           :padding '((lh 0) (ch 2))
                           :border-bottom (etaf-md--hairline env))
               (delq nil
                     (list
                      (etaf-node 'text (list :font-weight 'bold)
                                 (list (format "$ %s" title)))
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                      status-node
                      (when (not (string-empty-p cmd))
                        (etaf-md--leaf-button
                         env (if res "▶ 重新运行" "▶ 运行")
                         (lambda () (etaf-md-assets-run-command session env cmd cwd))
                         :bold t :help (format "执行：%s" cmd))))))
              ;; Flush command row
              (if (string-empty-p cmd)
                  (etaf-md--widget-error-body env "run 容器需要包含一个命令代码块")
                (etaf-md--widget-code-view env cmd lang))
              ;; Sunken output strip when executed
              (when (and res (plist-get res :lines))
                (let ((out-fg (if (eq status 'ok) ok-fg bad-fg)))
                  (etaf-node
                   'column (list :width 'stretch :item-gap '(lh 0)
                                 :background-color (etaf-md-surface env 'sunken)
                                 :border-top (etaf-md--hairline env)
                                 :padding '((lh 1) (ch 2)))
                   (append
                    (mapcar
                     (lambda (entry)
                       (etaf-node 'text (list :font-family mono :color out-fg)
                                  (list (or (plist-get entry :message) ""))))
                     (plist-get res :lines))
                    (list
                     (etaf-node 'box (list :width 'stretch :margin-top '(lh 1))
                                (list (etaf-node 'text (list :color muted)
                                                 (list "安全门禁：仅显式点击触发，默认经 minibuffer 确认后执行")))))))))))))))

(provide 'etaf-md-widgets)
;;; etaf-md-widgets.el ends here
