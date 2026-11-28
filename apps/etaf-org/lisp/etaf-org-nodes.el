;;; etaf-org-nodes.el --- Core Org nodes & L0 structure/collection/interactive containers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Registers both the built-in Org core node types (`headline', `src', `table',
;; `quote', `callout', `drawer', `planning', `math') so style rules and
;; `etaf-org-set-view' apply to them uniformly, and the L0 container vocabulary
;; (`note'..`danger', `box', `card', `columns', `details', alignment boxes,
;; `steps', `timeline', `stats', `field', `file-tree', `chat', `tabs',
;; `code-tabs', `accordion', `swiper', `code-tree', `window', `panel',
;; `tab-panel', `form', `log', `statusbar', `home-box', `image-card',
;; `link-card', `qrcode').
;;
;; Every widget keeps standard 1.0x body metrics and strict leaf-only pointer
;; hover via `etaf-org--leaf-button'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-node)
(require 'etaf-org-env)
(require 'etaf-org-theme)
(require 'etaf-org-typeset)
(require 'etaf-org-qrcode)

(declare-function etaf-org--block-view "etaf-org-views" (block env))
(declare-function etaf-org--table-view "etaf-org-views" (block env &optional opts))
(declare-function etaf-org--code-block-view "etaf-org-views" (block env &optional label opts))
(declare-function etaf-org--quote-view "etaf-org-views" (block env &optional opts))
(declare-function etaf-org--heading-view "etaf-org-views" (section state env))
(declare-function etaf-org--planning-view "etaf-org-views" (planning env))
(declare-function etaf-org--drawer-view "etaf-org-views" (drawer env hidden))
(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--activate-media "etaf-org-model" (session kind path))
(declare-function etaf-org--inline-nodes "etaf-org-views" (inlines env &optional inherited))
(declare-function etaf-org-inline-plain-text "etaf-org-parse" (inlines))

;;; ---------------------------------------------------------------------------
;;; Helpers shared by containers
;;; ---------------------------------------------------------------------------

(defun etaf-org-nodes--list-items-of (env)
  "Extract flat list items from ENV's children when body contains a plain list."
  (let ((out nil))
    (dolist (ch (etaf-org-children env))
      (let ((b (if (etaf-org-node-p ch) (etaf-org-node-block ch) ch)))
        (when (and (listp b) (eq (plist-get b :type) 'list))
          (setq out (append out (plist-get b :items))))))
    out))

(defun etaf-org-nodes--item-plain-text (item)
  "Return plain text of first paragraph of list ITEM."
  (let ((first (car (plist-get item :blocks))))
    (cond
     ((plist-get item :term)
      (concat (etaf-org-inline-plain-text (plist-get item :term))
              " : "
              (if (and first (eq (plist-get first :type) 'paragraph))
                  (etaf-org-inline-plain-text (plist-get first :inlines))
                "")))
     ((and first (eq (plist-get first :type) 'paragraph))
      (etaf-org-inline-plain-text (plist-get first :inlines)))
     (t (or (plist-get first :text) "")))))

(defun etaf-org-nodes--sparkline (values-str)
  "Render comma-separated numeric VALUES-STR as a Unicode sparkline string."
  (let* ((nums (cl-loop for tok in (split-string (or values-str "") "[, \t]+" t)
                        when (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" tok)
                        collect (string-to-number tok)))
         (bars ["▁" "▂" "▃" "▄" "▅" "▆" "▇" "█"]))
    (when nums
      (let* ((lo (apply #'min nums))
             (hi (apply #'max nums))
             (span (max 1e-6 (float (- hi lo)))))
        (mapconcat (lambda (n)
                     (aref bars (min 7 (max 0 (round (* 7.0 (/ (- n lo) span)))))))
                   nums "")))))

(defun etaf-org-nodes--block-children (env child-type)
  "Return child blocks of ENV that are special blocks named CHILD-TYPE."
  (let ((want (downcase (symbol-name child-type)))
        (out nil))
    (dolist (ch (etaf-org-children env))
      (cond
       ((and (etaf-org-node-p ch) (eq (etaf-org-node-type ch) child-type))
        (push ch out))
       ((and (listp ch) (eq (plist-get ch :type) 'special-block)
             (equal (downcase (or (plist-get ch :name) "")) want))
        (push (etaf-org-node-create
               :type child-type
               :attrs (plist-get ch :attrs)
               :children (or (plist-get ch :children) (plist-get ch :blocks))
               :source (plist-get ch :source)
               :line (plist-get ch :line-start)
               :block ch)
              out))))
    (nreverse out)))

(defun etaf-org-nodes--resolve-named-table (env table-name)
  "Look up a parsed Org table named TABLE-NAME in ENV's document."
  (when-let* ((session (etaf-org-env-session env))
              (doc (etaf-org--read session :document))
              (named (plist-get doc :named-blocks))
              (block (and (hash-table-p named) (gethash table-name named)))
              ((eq (plist-get block :type) 'table)))
    block))

;;; ---------------------------------------------------------------------------
;;; 1. Built-in Org Core Node Types (styleable via `etaf-org-set-attr')
;;; ---------------------------------------------------------------------------

(etaf-org--define-shipped 'headline
  :summary "Org 标题节，级别由星号个数决定"
  :derived '((level :type number :min 1 :max 8 :integer t :doc "标题层级")
             (number :type string :doc "派生章节号")
             (todo :type string :doc "TODO 关键词")
             (todo-state :type enum :one-of (active done) :doc "待办分类")
             (priority :type string :doc "优先级字母")
             (tags :type string :doc "有效标签")
             (archived :type boolean :doc "是否归档")
             (commented :type boolean :doc "是否注释标题")
             (has-children :type boolean :doc "是否含子标题"))
  :attrs '((color :type color :doc "标题字色")
           (font-weight :type enum :one-of (normal bold) :default bold :doc "字重")
           (prefix :type string :default "" :doc "标题显示前缀（不影响锚点）")
           (numbering :type enum :one-of (none decimal lower-roman upper-alpha)
                      :default none :doc "章节编号格式")
           (rule :type boolean :doc "标题下方分隔线")
           (accent :type accent :default neutral :doc "标题左侧强调色"))
  :view (lambda (env)
          (when-let* ((sec (etaf-org-env-section env))
                      (leg (etaf-org-env-legacy-env env)))
            (etaf-org--heading-view sec 'open leg))))

(etaf-org--define-shipped 'src
  :summary "Org 源码块（#+begin_src）"
  :derived '((language :type string :doc "源码语言")
             (tangled :type boolean :doc "是否声明 :tangle")
             (has-results :type boolean :doc "是否附带 #+RESULTS:"))
  :attrs '((title :type string :doc "代码块标题")
           (line-numbers :type boolean :default nil :doc "显示行号")
           (collapsed-lines :type number :min 1 :integer t :doc "默认折叠行数")
           (highlight :type string :doc "高亮行区间如 1,3-5")
           (word :type string :doc "高亮关键词")
           (indent-guides :type boolean :default nil :doc "缩进参考线")
           (whitespace :type boolean :default nil :doc "显示空白符")
           (background :type surface :default raised :doc "底色面")
           (label-color :type color :default "muted" :doc "语言标签色")
           (copy :type boolean :default t :doc "显示复制按钮"))
  :view (lambda (env)
          (etaf-org--code-block-view
           (etaf-org-env-block env)
           (etaf-org-env-legacy-env env)
           nil
           (list :title (etaf-org-attr env :title)
                 :line-numbers (etaf-org-attr env :line-numbers)
                 :collapsed-lines (etaf-org-attr env :collapsed-lines)
                 :highlight (etaf-org-attr env :highlight)
                 :word (etaf-org-attr env :word)
                 :indent-guides (etaf-org-attr env :indent-guides)
                 :whitespace (etaf-org-attr env :whitespace)
                 :background (etaf-org-attr env :background)
                 :label-color (etaf-org-attr env :label-color)
                 :copy (etaf-org-attr env :copy)
                 :env env))))

(etaf-org--define-shipped 'table
  :name "table"
  :summary "Org 表格（支持排序、行列高亮与复制）"
  :derived '((number :type string :doc "派生表格编号")
             (columns :type number :integer t :doc "列数")
             (rows :type number :integer t :doc "行数")
             (has-formula :type boolean :doc "是否附带 #+TBLFM:"))
  :attrs '((title :type string :doc "表格标题")
           (sortable :type boolean :default nil :doc "点击表头排序")
           (copy :type boolean :default nil :doc "显示复制按钮")
           (highlight-rows :type string :doc "高亮行号，空格分隔")
           (highlight-columns :type string :doc "高亮列号，空格分隔")
           (highlight-cells :type string :doc "高亮单元格 行:列")
           (highlight :type accent :default warning :doc "高亮强调色")
           (zebra :type boolean :default nil :doc "启用条纹行")
           (align :type align :doc "整表对齐")
           (header-background :type surface :default table-header :doc "表头面")
           (stripe-background :type surface :default table-stripe :doc "条纹面")
           (numbering :type enum :one-of (none decimal) :default none :doc "表格编号"))
  :view (lambda (env)
          (let* ((block (etaf-org-env-block env))
                 (tbl (if (eq (plist-get block :type) 'table)
                          block
                        (cl-find-if (lambda (b) (eq (plist-get b :type) 'table))
                                    (etaf-org-children env)))))
            (if tbl
                (etaf-org--table-view
                 tbl (etaf-org-env-legacy-env env)
                 (list :title (or (etaf-org-attr env :title) (plist-get tbl :caption))
                       :sortable (etaf-org-attr env :sortable)
                       :copy (etaf-org-attr env :copy)
                       :highlight-rows (etaf-org-attr env :highlight-rows)
                       :highlight-columns (etaf-org-attr env :highlight-columns)
                       :highlight-cells (etaf-org-attr env :highlight-cells)
                       :highlight (etaf-org-attr env :highlight)
                       :zebra (etaf-org-attr env :zebra)
                       :align (etaf-org-attr env :align)
                       :header-background (etaf-org-attr env :header-background)
                       :stripe-background (etaf-org-attr env :stripe-background)
                       :numbering (etaf-org-attr env :numbering)
                       :env env))
              (etaf-org-content env)))))

(etaf-org--define-shipped 'quote
  :summary "Org 引用块（#+begin_quote）"
  :derived '((has-attribution :type boolean :doc "是否带署名行"))
  :attrs '((background :type surface :default quote :doc "引用底色")
           (border-left-width :type length :default "1ch" :doc "左侧竖条宽")
           (font-style :type enum :one-of (normal italic) :default normal :doc "倾斜")
           (margin-top :type length :default "0lh" :doc "上间距")
           (margin-bottom :type length :default "0lh" :doc "下间距"))
  :view (lambda (env)
          (etaf-org--quote-view
           (etaf-org-env-block env)
           (etaf-org-env-legacy-env env)
           (list :background (etaf-org-attr env :background)
                 :font-style (etaf-org-attr env :font-style)))))

(etaf-org--define-shipped 'drawer
  :summary "Org 抽屉（:PROPERTIES: / :LOGBOOK: / 自定义抽屉）"
  :derived '((name :type string :doc "抽屉名称")
             (has-clock :type boolean :doc "是否包含 CLOCK 记录"))
  :attrs '((open :type boolean :default nil :doc "默认展开")
           (surface :type surface :default raised :doc "抽屉底面"))
  :view (lambda (env)
          (etaf-org--drawer-view
           (etaf-org-env-block env)
           (etaf-org-env-legacy-env env)
           (etaf-org-attr env :open))))

(etaf-org--define-shipped 'planning
  :summary "Org 计划行（SCHEDULED / DEADLINE / CLOSED）"
  :derived '((overdue :type boolean :doc "是否已逾期")
             (due-soon :type boolean :doc "是否即将到期")
             (has-deadline :type boolean :doc "是否含截止日期")
             (has-scheduled :type boolean :doc "是否含计划日期"))
  :attrs '((relative-date :type boolean :default t :doc "显示相对到期提示")
           (accent :type accent :default danger :doc "逾期强调色"))
  :view (lambda (env)
          (etaf-org--planning-view
           (etaf-org-env-block env)
           (etaf-org-env-legacy-env env))))

(etaf-org--define-shipped 'math
  :summary "Org 块级数学公式"
  :derived '((number :type string :doc "公式编号")
             (environment :type string :doc "LaTeX 环境名"))
  :attrs '((numbering :type enum :one-of (none decimal) :default decimal :doc "公式编号")
           (align :type align :default center :doc "对齐方式"))
  :view (lambda (env)
          (etaf-org--block-view (etaf-org-env-block env)
                                (etaf-org-env-legacy-env env))))

;;; ---------------------------------------------------------------------------
;;; 2. Callouts (note, info, tip, important, warning, caution, danger)
;;; ---------------------------------------------------------------------------

(defconst etaf-org-nodes--callout-specs
  '((note      . ("提示" primary "i"))
    (info      . ("信息" primary "i"))
    (tip       . ("要点" success "✔"))
    (important . ("重要" important "★"))
    (warning   . ("警告" warning "⚠"))
    (caution   . ("小心" danger "⊘"))
    (danger    . ("危险" danger "⊘")))
  "Mapping from callout node type to `(DEFAULT-LABEL ACCENT ICON)'.
Monochrome glyphs match `etaf-doc-markdown--alert-defaults' so no color
emoji clashes with the editorial palette.")

(defun etaf-org-nodes--paint-callout (env)
  "Shared paint for all seven callout containers (`note'..`danger').
Matches `etaf-doc-markdown--blockquote-node' alerts: compact 3px solid left
accent bar, soft semantic tint, zero vertical slab padding, monochrome icon
and bold title, and leaf-only disclosure toggle when collapsible."
  (let* ((type (etaf-org-type env))
         (spec (or (assq type etaf-org-nodes--callout-specs)
                   '(note "提示" primary "i")))
         (default-label (nth 1 spec))
         (default-accent (nth 2 spec))
         (icon (or (nth 3 spec) "i"))
         (title (or (etaf-org-attr env :title) default-label))
         (accent (or (etaf-org-attr env :accent) default-accent))
         (collapsible (etaf-org-attr env :collapsible))
         (default-open (let ((v (etaf-org-attr env :open)))
                         (if (null v) (not collapsible) v)))
         (open (if collapsible
                   (etaf-org-block-state env :open default-open)
                 t))
         (fg (etaf-org-accent env accent))
         (bg (or (etaf-org-surface env (etaf-org-attr env :background))
                 (etaf-org-accent env accent t)))
         (header (if collapsible
                     (etaf-org--leaf-button
                      env
                      (format "%s %s %s" (if open "▾" "▸") icon title)
                      (lambda () (etaf-org-set-block-state env :open (not open)))
                      :color fg :bold t :hover-variant 'soft
                      :help (if open "收起提示块" "展开提示块"))
                   (etaf-node 'text (list :color fg :font-weight 'bold)
                              (list (format "%s %s" icon title)))))
         (body (when open (etaf-org-content env))))
    (etaf-node 'column
               (list :width 'stretch
                     :item-gap '(lh 0)
                     :background-color bg
                     :border-left (list '(px 3) 'solid fg)
                     :padding '((lh 0) (ch 2)))
               (delq nil (list header body)))))

(dolist (entry etaf-org-nodes--callout-specs)
  (let ((type (car entry))
        (label (nth 1 entry))
        (accent (nth 2 entry)))
    (etaf-org--define-shipped type
      :name (symbol-name type)
      :summary (format "%s提示块" label)
      :attrs `((title :type string :doc "自定义标题")
               (accent :type accent :default ,accent :doc "强调色")
               (collapsible :type boolean :default nil :doc "允许折叠")
               (open :type boolean :default t :doc "默认展开")
               (background :type surface :default none :doc "底色面")
               (border-left-width :type length :default "1ch" :doc "左侧竖条宽")
               (id :type string :doc "锚点 ID"))
      :view #'etaf-org-nodes--paint-callout)))

(etaf-org--define-shipped 'callout
  :summary "通用提示块语义类型"
  :derived '((kind :type string :doc "提示类别"))
  :attrs '((title :type string :doc "标题")
           (accent :type accent :default primary :doc "强调色")
           (collapsible :type boolean :default nil :doc "允许折叠")
           (open :type boolean :default t :doc "默认展开")
           (background :type surface :default none :doc "底色面")
           (border-left-width :type length :default "1ch" :doc "竖条宽"))
  :view #'etaf-org-nodes--paint-callout)

;;; ---------------------------------------------------------------------------
;;; 3. Structure containers: box, card, columns, details, alignments, window, panes
;;; ---------------------------------------------------------------------------

(defun etaf-org-nodes--padding-spec (pad)
  "Normalize PAD into a valid integer 2-axis `((lh V) (ch H))' padding spec."
  (cond
   ((null pad) nil)
   ((and (consp pad) (consp (car pad))) pad)
   ((and (consp pad) (eq (car pad) 'ch))
    (let ((n (round (cadr pad))))
      (list (list 'lh (if (<= n 0) 0 1))
            (list 'ch (max 0 n)))))
   ((and (consp pad) (eq (car pad) 'lh))
    (let ((n (max 0 (round (cadr pad)))))
      (list (list 'lh n) (list 'ch (* 2 n)))))
   ((and (consp pad) (eq (car pad) '%))
    (list '(lh 1) pad))
   (t '((lh 1) (ch 2)))))

(defun etaf-org-nodes--length-columns (length available)
  "Return horizontal LENGTH resolved to whole character cells against AVAILABLE."
  (pcase (car-safe length)
    ('ch (max 0 (round (cadr length))))
    ('% (max 0 (floor (* available (/ (float (cadr length)) 100.0)))))
    (_ 0)))

(etaf-org--define-shipped 'box
  :name "box"
  :summary "带底色、框线、强调边与内边距的容器盒（对齐 etaf-md）"
  :attrs '((surface :type surface :default none :doc "底色面")
           (accent :type accent :default neutral :doc "左边框强调")
           (padding :type length :default "2ch" :doc "内边距")
           (text-align :type align :default start :doc "水平对齐")
           (width :type length :doc "宽度")
           (id :type string :doc "块 ID（供跨块接线或宿主推送）")
           (empty :type string :doc "无内容时的占位提示"))
  :view (lambda (env)
          (let* ((surface (etaf-org-surface env (etaf-org-attr env :surface)))
                 (accent (or (etaf-org-attr env :accent) 'neutral))
                 (pad-attr (etaf-org-attr env :padding))
                 (pad (or (etaf-org-nodes--padding-spec pad-attr)
                          '((lh 1) (ch 2))))
                 (declared-width (etaf-org-attr env :width))
                 (available (etaf-org-available-width env))
                 (outer (if (consp declared-width)
                            (min available
                                 (max 1 (etaf-org-nodes--length-columns
                                         declared-width available)))
                          available))
                 (pad-ch (* 2 (etaf-org-nodes--length-columns (cadr pad) outer)))
                 (inner-env (etaf-org--env-with-width env (max 8 (- outer pad-ch 2))))
                 (align (etaf-org-attr env :text-align))
                 (pushed (etaf-org-block-state env :pushed-view))
                 (body (or pushed (etaf-org-content inner-env)))
                 (line (etaf-org--hairline env)))
            (etaf-node 'box
                       (append
                        (list :width (or declared-width 'stretch)
                              :text-align (pcase align
                                            ('center 'center)
                                            ('end 'right)
                                            (_ 'left)))
                        (when surface (list :background-color surface))
                        (if (not (eq accent 'neutral))
                            (list :border-top line
                                  :border-right line
                                  :border-bottom line
                                  :border-left (list '(px 3) 'solid
                                                     (etaf-org-accent env accent)))
                          (list :border line))
                        (when pad (list :padding pad))
                        (when-let* ((id (etaf-org-attr env :id))) (list :id id)))
                       (if body (list body)
                         (when-let* ((empty (etaf-org-attr env :empty)))
                           (list (etaf-node 'text
                                            (list :color (etaf-org--muted env))
                                            (list empty)))))))))

(etaf-org--define-shipped 'card
  :name "card"
  :summary "带标题与语义强调边的卡片容器（etaf-card）"
  :attrs '((title :type string :doc "卡片标题")
           (description :type string :doc "标题下摘要")
           (icon :type string :doc "图标名")
           (href :type string :doc "整卡跳转链接")
           (accent :type accent :default neutral :doc "强调色")
           (text-align :type align :default start :doc "内容对齐")
           (width :type length :doc "自身宽度")
           (id :type string :doc "锚点 ID"))
  :view (lambda (env)
          (let* ((title (etaf-org-attr env :title))
                 (desc (etaf-org-attr env :description))
                 (icon (etaf-org-attr env :icon))
                 (href (etaf-org-attr env :href))
                 (accent (or (etaf-org-attr env :accent) 'neutral))
                 (align (or (etaf-org-attr env :text-align) 'start))
                 (avail (max 12 (- (etaf-org-available-width env) 6)))
                 (inner-env (etaf-org--env-with-width env avail))
                 (body (etaf-org-content inner-env))
                 (card-view
                  (etaf-node 'etaf-card
                             (list :title (if (and title href)
                                              (concat title " ↗")
                                            title)
                                   :description desc
                                   :icon icon
                                   :variant accent
                                   :width (or (etaf-org-attr env :width) 'stretch)
                                   :text-align (pcase align
                                                 ('center 'center)
                                                 ('end 'end)
                                                 (_ 'start))
                                   :on-press (when href
                                               (lambda ()
                                                 (etaf-org-follow-link env href))))
                             (when body (list body)))))
            (if-let* ((id (etaf-org-attr env :id)))
                (etaf-node 'box (list :id id :width 'stretch) (list card-view))
              card-view))))

(defun etaf-org-nodes--justify (word)
  "Convert document justification WORD to Ebox flex `:justify-content'."
  (pcase word
    ('between 'space-between)
    ('around 'space-around)
    (_ (or word 'start))))

(defun etaf-org-nodes--parse-column-tracks (columns)
  "Return track width specs parsed from track string COLUMNS, or nil.
Recognizes `2fr', `20ch', and `30%' tokens."
  (when (stringp columns)
    (delq nil
          (mapcar
           (lambda (token)
             (cond ((string-match "\\`\\([0-9.]+\\)fr\\'" token)
                    (list :flex-grow (max 0.1 (string-to-number (match-string 1 token)))))
                   ((string-match "\\`\\([0-9]+\\)\\(ch\\|%\\)\\'" token)
                    (list :width (list (intern (match-string 2 token))
                                       (string-to-number (match-string 1 token)))))))
           (split-string columns "[ \t]+" t)))))

(defun etaf-org-nodes--column-divider (env)
  "Return the 1px vertical hairline divider between columns in ENV."
  (etaf-node 'box
             (list :width '(px 1)
                   :flex-shrink 0
                   :align-self 'stretch
                   :border-left (etaf-org--hairline env))
             nil))

(defun etaf-org-nodes--column-widths (available tracks gap divider padding)
  "Return per-column integer cell widths for TRACKS inside AVAILABLE cells."
  (let* ((count (max 1 (length tracks)))
         (pad-ch (* 2 (etaf-org-nodes--length-columns padding available)))
         (gap-ch (if (consp gap) (etaf-org-nodes--length-columns gap available) 2))
         (gaps (* (max 0 (1- count)) gap-ch))
         (dividers (if divider (max 0 (1- count)) 0))
         (usable (max count (- available pad-ch gaps dividers)))
         (fixed-sum 0)
         (grow-sum 0.0)
         (resolved
          (mapcar (lambda (track)
                    (if (eq (car track) :width)
                        (let ((w (max 1 (etaf-org-nodes--length-columns
                                         (cadr track) usable))))
                          (setq fixed-sum (+ fixed-sum w))
                          (cons 'fixed w))
                      (let ((g (max 0.01 (float (or (cadr track) 1)))))
                        (setq grow-sum (+ grow-sum g))
                        (cons 'flex g))))
                  tracks))
         (flex-pool (max 1 (- usable fixed-sum))))
    (mapcar (lambda (entry)
              (if (eq (car entry) 'fixed)
                  (cdr entry)
                (max 1 (floor (* flex-pool (/ (cdr entry) grow-sum))))))
            resolved)))

(defun etaf-org-nodes--columns-fit-tracks (tracks width gap divider padding)
  "Return how many leading TRACKS fit inside WIDTH cells (at least 1)."
  (let* ((pad-ch (* 2 (etaf-org-nodes--length-columns padding width)))
         (gap-ch (if (consp gap) (etaf-org-nodes--length-columns gap width) 2))
         (div-ch (if divider 1 0))
         (usable (max 1 (- width pad-ch)))
         (used 0)
         (fit 0))
    (cl-loop for track in tracks
             for i from 0
             for w = (if (eq (car track) :width)
                         (max 1 (etaf-org-nodes--length-columns (cadr track) usable))
                       20)
             for extra = (if (zerop i) 0 (+ gap-ch div-ch))
             while (or (zerop i) (<= (+ used extra w) usable))
             do (setq used (+ used extra w)
                      fit (1+ fit)))
    (max 1 fit)))

(etaf-org--define-shipped 'col
  :name "col"
  :summary "columns 容器内的单个分栏"
  :attrs '((grow :type number :default 1 :min 0.1 :doc "宽度权重"))
  :view (lambda (env) (etaf-org-content env)))

(etaf-org--define-shipped 'columns
  :name "columns"
  :summary "响应式多栏布局容器（支持 col :grow、轨道串、wrap 与 justify-content，对齐 etaf-md）"
  :accepts '((col :attrs ((grow :type number :default 1))))
  :attrs '((columns :type string :default "2" :doc "栏数（如 2、3）或轨道串（如 2fr 1fr、20ch 30%）")
           (gap :type length :default "2ch" :doc "栏间距")
           (padding :type length :doc "左右内边距")
           (min-width :type length :default "24ch" :doc "每栏最小宽度")
           (divider :type boolean :default nil :doc "栏间竖线")
           (wrap :type boolean :default nil :doc "放不下时换行")
           (align-items :type enum :one-of (start center end stretch) :default stretch :doc "交叉轴对齐")
           (justify-content :type enum :one-of (start center end between around) :default start :doc "主轴对齐")
           (align-self :type enum :one-of (start center end) :default start :doc "自身水平位置")
           (id :type string :doc "锚点 ID"))
  :view (lambda (env)
          (let* ((cols (or (etaf-org-nodes--block-children env 'col)
                           (etaf-org-children env)))
                 (col-count (length cols)))
            (if (zerop col-count)
                (etaf-node 'text (list :color (etaf-org--muted env)) '("（空分栏）"))
              (let* ((columns (etaf-org-attr env :columns))
                     (numeric (and (stringp columns)
                                   (string-match-p "\\`[0-9]+\\'" (string-trim columns))))
                     (parsed-tracks (and (stringp columns)
                                         (not numeric)
                                         (etaf-org-nodes--parse-column-tracks columns)))
                     (count (cond
                             (numeric
                              (max 1 (min 6 (string-to-number (string-trim columns)))))
                             (parsed-tracks
                              (max 1 (min 6 (length parsed-tracks))))
                             ((numberp columns)
                              (max 1 (min 6 (round columns))))
                             (t (max 1 (min 3 col-count)))))
                     (gap (or (etaf-org-attr env :gap) '(ch 2)))
                     (divider (etaf-org-attr env :divider))
                     (padding (etaf-org-attr env :padding))
                     (width (etaf-org-available-width env))
                     (min-width (etaf-org-attr env :min-width))
                     (min-ch (max 1 (etaf-org-nodes--length-columns min-width width)))
                     (min-columns (if min-width
                                      (max 1 (floor (/ width min-ch)))
                                    count))
                     (wrap (etaf-org-attr env :wrap))
                     (per (cond
                           ((and parsed-tracks wrap)
                            (min count (etaf-org-nodes--columns-fit-tracks
                                        parsed-tracks width gap divider padding)))
                           (parsed-tracks count)
                           (t (max 1 (min count min-columns)))))
                     (justify (or (etaf-org-attr env :justify-content) 'start))
                     (rows (seq-partition cols per))
                     (view
                      (etaf-node
                       'column
                       (append
                        (list :width 'stretch
                              :item-gap '(lh 1)
                              :align-self (or (etaf-org-attr env :align-self) 'start))
                        (when padding
                          (list :padding (list '(lh 0) padding))))
                       (mapcar
                        (lambda (row)
                          (let* ((row-tracks
                                  (if (and parsed-tracks (= per count))
                                      (seq-take parsed-tracks (length row))
                                    (mapcar (lambda (c)
                                              (let ((g (or (etaf-org-attr env :grow c) 1)))
                                                (list :flex-grow (max 0.1 (float g)))))
                                            row)))
                                 (explicit-grow-p
                                  (cl-some (lambda (c)
                                             (let ((g (etaf-org-attr env :grow c)))
                                               (and g (/= (float g) 1.0))))
                                           row))
                                 (shrink-for-justify
                                  (and (not (eq justify 'start))
                                       (not parsed-tracks)
                                       (not explicit-grow-p)))
                                 (col-widths (etaf-org-nodes--column-widths
                                              width row-tracks gap divider padding)))
                            (etaf-node
                             'flex
                             (list :width 'stretch
                                   :gap (list '(lh 0) gap)
                                   :align-items (or (etaf-org-attr env :align-items) 'stretch)
                                   :justify-content (etaf-org-nodes--justify justify))
                             (cl-loop
                              for c in row
                              for first = t then nil
                              for track in row-tracks
                              for col-width in col-widths
                              append
                              (append
                               (when (and divider (not first))
                                 (list (etaf-org-nodes--column-divider env)))
                               (list
                                (etaf-node
                                 'column
                                 (append
                                  (list :item-gap '(lh 0))
                                  (cond
                                   ((eq (car track) :width)
                                    (list :width (cadr track)))
                                   (shrink-for-justify
                                    (list :width 'max-content
                                          :max-width (list 'ch col-width)))
                                   (t
                                    (list :flex-basis '(ch 0)
                                          :flex-grow (cadr track)
                                          :width 'stretch
                                          :min-width '(ch 0)))))
                                 (when-let* ((rendered
                                              (etaf-org--paint
                                               c (etaf-org--env-with-width env col-width))))
                                   (list rendered)))))))))
                        rows))))
                (if-let* ((id (etaf-org-attr env :id)))
                    (etaf-node 'box (list :id id :width 'stretch) (list view))
                  view))))))

(etaf-org--define-shipped 'details
  :name "details"
  :summary "单块可折叠详情容器（etaf-accordion）"
  :attrs '((title :type string :default "详情" :doc "折叠标题")
           (open :type boolean :default nil :doc "默认展开")
           (id :type string :doc "锚点 ID"))
  :view (lambda (env)
          (let* ((title (or (etaf-org-attr env :title) "详情"))
                 (open (etaf-org-block-state env :open (etaf-org-attr env :open)))
                 (slot-key (or (plist-get (etaf-org-env-slot env) :key)
                               (sxhash title)))
                 (has-body (and (etaf-org-children env) t))
                 (acc (etaf-node
                       'etaf-accordion
                       (list :items (list (list :key 0
                                                :ref (intern (format "etaf-org-details-%s" slot-key))
                                                :label title
                                                :content (if has-body
                                                             (lambda () (etaf-org-content env))
                                                           "")))
                             :open (when open '(0))
                             :multiple t
                             :on-toggle (lambda (opened)
                                          (etaf-org-set-block-state env :open (and opened t))))
                       nil)))
            (if-let* ((id (etaf-org-attr env :id)))
                (etaf-node 'box (list :id id :width 'stretch) (list acc))
              acc))))

(dolist (pair '((left . left) (center . center) (right . right) (justify . left)))
  (let ((sym (car pair)) (align (cdr pair)))
    (etaf-org--define-shipped sym
      :name (symbol-name sym)
      :summary (format "块级对齐容器（%s）" sym)
      :attrs '((width :type length :doc "宽度"))
      :view (lambda (env)
              (let* ((leg (etaf-org-env-legacy-env env))
                     (aligned-env (if leg
                                      (etaf-org-env-create
                                       :session (etaf-org-env-session env)
                                       :node (etaf-org-env-node env)
                                       :width (etaf-org-env-width env)
                                       :state (etaf-org-env-state env)
                                       :palette (etaf-org-env-palette env)
                                       :theme (etaf-org-env-theme env)
                                       :block (etaf-org-env-block env)
                                       :slot (etaf-org-env-slot env)
                                       :section (etaf-org-env-section env)
                                       :legacy-env (plist-put (copy-sequence leg)
                                                              :text-align align))
                                    env)))
                (etaf-node 'box
                           (list :width (or (etaf-org-attr env :width) 'stretch)
                                 :text-align align)
                           (when-let* ((body (etaf-org-content aligned-env)))
                             (list body))))))))

(etaf-org--define-shipped 'window
  :name "window"
  :summary "带标题栏的演示窗口容器（etaf-window-chrome）"
  :attrs '((title :type string :default "窗口" :doc "标题栏文字")
           (height :type length :doc "内容区高度")
           (no-padding :type boolean :default nil :doc "关闭内容内边距"))
  :view (lambda (env)
          (let* ((title (or (etaf-org-attr env :title) ""))
                 (height (etaf-org-attr env :height))
                 (padded (not (etaf-org-attr env :no-padding)))
                 (body (etaf-org-content env)))
            (etaf-node 'column
                       (list :width 'stretch :item-gap '(lh 0)
                             :border (etaf-org--hairline env)
                             :overflow 'hidden)
                       (list
                        (etaf-node 'etaf-window-chrome
                                   (list :title title
                                         :active t
                                         :show-minimize t
                                         :show-maximize t
                                         :show-close t)
                                   nil)
                        (etaf-node 'box
                                   (append (list :width 'stretch)
                                           (when padded (list :padding '((lh 1) (ch 2))))
                                           (when height (list :height height :overflow 'hidden)))
                                   (when body (list body))))))))

(etaf-org--define-shipped 'panel
  :name "panel"
  :summary "顶边嵌标题的窗格面板（etaf-edge-panel）"
  :attrs '((title :type string :doc "顶边标题")
           (status :type string :doc "右端状态文字")
           (variant :type enum :one-of (default flat) :default default :doc "风格")
           (focus :type boolean :default nil :doc "强调边框")
           (accent :type accent :default neutral :doc "强调色")
           (width :type length :doc "面板宽度"))
  :view (lambda (env)
          (let* ((body (etaf-org-content env))
                 (accent (etaf-org-attr env :accent))
                 (accent-color (and accent (not (eq accent 'neutral))
                                    (etaf-org-accent env accent))))
            (etaf-node 'etaf-edge-panel
                       (list :title (etaf-org-attr env :title)
                             :status (etaf-org-attr env :status)
                             :variant (etaf-org-attr env :variant)
                             :focus (etaf-org-attr env :focus)
                             :accent accent-color
                             :background (etaf-org-surface env 'raised)
                             :width (or (etaf-org-attr env :width) 'stretch))
                       (when body (list body))))))

(etaf-org--define-shipped 'form
  :name "form"
  :summary "下划线键值表单（etaf-underline-field）"
  :attrs '((width :type length :doc "表单宽度"))
  :view (lambda (env)
          (let* ((items (etaf-org-nodes--list-items-of env))
                 (rows
                  (mapcar
                   (lambda (item)
                     (let* ((txt (etaf-org-nodes--item-plain-text item))
                            (split (string-match "[：:]" txt))
                            (label (if split (string-trim (substring txt 0 split)) txt))
                            (val (if split (string-trim (substring txt (1+ split))) "")))
                       (etaf-node 'etaf-underline-field
                                  (list :label label :value val
                                        :width (or (etaf-org-attr env :width) 'stretch))
                                  nil)))
                   items)))
            (etaf-node 'column (list :width 'stretch :item-gap '(lh 1))
                       (or rows (when-let* ((c (etaf-org-content env))) (list c)))))))

(etaf-org--define-shipped 'log
  :name "log"
  :summary "结构化日志流（etaf-log）"
  :attrs '((title :type string :doc "日志标题"))
  :view (lambda (env)
          (let* ((raw (or (plist-get (etaf-org-env-block env) :raw-content) ""))
                 (title (etaf-org-attr env :title))
                 (rows (cl-loop for line in (split-string raw "\n" t)
                                for trimmed = (string-trim line)
                                collect
                                (cond
                                 ((string-match "\\`\\[\\([^]]+\\)\\][ \t]+\\([A-Za-z]+\\)[ \t]+\\(.*\\)\\'" trimmed)
                                  (list :time (match-string 1 trimmed)
                                        :level (upcase (match-string 2 trimmed))
                                        :message (match-string 3 trimmed)))
                                 ((string-match "\\`\\([0-9:.-]+\\)[ \t]+\\([A-Za-z]+\\)[ \t]+\\(.*\\)\\'" trimmed)
                                  (list :time (match-string 1 trimmed)
                                        :level (upcase (match-string 2 trimmed))
                                        :message (match-string 3 trimmed)))
                                 (t
                                  (list :time "" :level "INFO" :message trimmed))))))
            (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
                       (delq nil
                             (list (when title
                                     (etaf-node 'box (list :width 'stretch :padding-bottom '(lh 1))
                                                (list (etaf-node 'text
                                                                 (list :color (etaf-org--muted env) :font-weight 'bold)
                                                                 (list title)))))
                                   (etaf-node 'etaf-log
                                              (list :rows rows :width 'stretch)
                                              nil)))))))

(defun etaf-org-nodes--parse-status-keys (keys-str)
  "Parse KEYS-STR into a list of `(KEY . LABEL)' pairs for `etaf-status-bar'."
  (when (and (stringp keys-str) (not (string-empty-p (string-trim keys-str))))
    (cl-loop for raw in (split-string keys-str "[·,|;]+" t "[ \t]+")
             for item = (string-trim raw)
             unless (string-empty-p item)
             collect
             (cond
              ((string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" item)
               (cons (string-trim (match-string 1 item))
                     (string-trim (match-string 2 item))))
              ((string-match "\\`\\(.+\\)[ \t]+\\([^ \t]+\\)\\'" item)
               (cons (string-trim (match-string 1 item))
                     (string-trim (match-string 2 item))))
              (t (cons item ""))))))

(etaf-org--define-shipped 'statusbar
  :name "statusbar"
  :summary "静态状态条（etaf-status-bar）"
  :attrs '((mode :type string :default "ORG" :doc "模式标签")
           (keys :type string :default "" :doc "快捷键提示")
           (note :type string :default "" :doc "右侧说明"))
  :view (lambda (env)
          (etaf-node 'etaf-status-bar
                     (list :mode (or (etaf-org-attr env :mode) "ORG")
                           :keys (etaf-org-nodes--parse-status-keys
                                  (etaf-org-attr env :keys))
                           :note (or (etaf-org-attr env :note) "")
                           :width 'stretch)
                     nil)))

;;; ---------------------------------------------------------------------------
;;; 4. Collections: steps, timeline, stats, field, file-tree, chat
;;; ---------------------------------------------------------------------------

(etaf-org--define-shipped 'step
  :name "step"
  :summary "steps 内的单个步骤"
  :attrs '((title :type string :required t :doc "步骤标题"))
  :view (lambda (env) (etaf-org-content env)))

(etaf-org--define-shipped 'steps
  :name "steps"
  :summary "编号步骤条（etaf-steps，支持 step 子块或有序列表）"
  :accepts '((step :attrs ((title :type string :required t))))
  :attrs '((start :type number :integer t :default 1 :doc "起始编号")
           (list-style :type enum :one-of (decimal bullet none) :default decimal :doc "序号样式"))
  :view (lambda (env)
          (let* ((start (max 0 (or (etaf-org-attr env :start) 1)))
                 (style (or (etaf-org-attr env :list-style) 'decimal))
                 (step-nodes (etaf-org-nodes--block-children env 'step))
                 (list-items (unless step-nodes (etaf-org-nodes--list-items-of env)))
                 (items
                  (if step-nodes
                      (cl-loop for sn in step-nodes for i from 0
                               collect
                               (let ((node sn))
                                 (list :key i
                                       :label (or (etaf-org-attr env :title node)
                                                  (format "步骤 %d" (+ start i)))
                                       :content (lambda ()
                                                  (etaf-org-content
                                                   (etaf-org--env-for-node env node))))))
                    (cl-loop for item in list-items for i from 0
                             collect
                             (list :key i
                                   :label (etaf-org-nodes--item-plain-text item))))))
            (if (null items)
                (etaf-node 'text (list :color (etaf-org--muted env)) '("（空步骤）"))
              (etaf-node 'etaf-steps
                         (list :orientation 'vertical
                               :start start
                               :list-style style
                               :current 0
                               :items items)
                         nil)))))

(etaf-org--define-shipped 'event
  :name "event"
  :summary "timeline 内的单条时间线事件"
  :attrs '((title :type string :required t :doc "事件标题")
           (time :type string :doc "时间文字")
           (status :type enum :one-of (neutral info success warning danger) :default info :doc "状态色"))
  :view (lambda (env) (etaf-org-content env)))

(defun etaf-org-nodes--timeline-horizontal (env events card-p)
  "Paint EVENTS as `etaf-md'-style horizontal timeline with continuous top rail."
  (let* ((count (length events))
         (avail (etaf-org-available-width env))
         (col-w (max 14 (floor (/ (- avail (* 2 (max 0 (1- count)))) count))))
         (rule-color (or (etaf-org--env-color env :border) (etaf-org--muted env)))
         (surface (etaf-org-surface env 'raised)))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0))
     (list
      ;; Row 1: continuous dot + hairline rail across columns
      (etaf-node
       'flex (list :width 'stretch :column-gap '(ch 2) :align-items 'center
                   :margin-bottom '(lh 0))
       (cl-loop for ev in events
                for idx from 0
                for last = (= idx (1- count))
                for status = (or (etaf-org-attr env :status ev) 'primary)
                for dot-color = (etaf-org-accent env (if (eq status 'neutral) 'primary status))
                collect
                (etaf-node
                 'flex (list :flex-basis '(ch 0) :flex-grow 1 :width 'stretch
                             :column-gap '(ch 1) :align-items 'center)
                 (delq nil
                       (list
                        (etaf-node 'text (list :color dot-color :font-weight 'bold)
                                   '("●"))
                        (unless last
                          (etaf-node 'text (list :color rule-color)
                                     (list (make-string (max 3 (- col-w 2)) ?─)))))))))
      ;; Row 2: equal-height aligned cards (`:time' eyebrow above bold wrapped title)
      (etaf-node
       'flex (list :width 'stretch :column-gap '(ch 2) :align-items 'stretch)
       (cl-loop for ev in events
                for status = (or (etaf-org-attr env :status ev) 'primary)
                for accent-col = (etaf-org-accent env (if (eq status 'neutral) 'primary status))
                for title = (or (etaf-org-attr env :title ev) "")
                for time = (etaf-org-attr env :time ev)
                for inner-env = (etaf-org--env-for-node env ev (max 8 (- col-w (if card-p 4 2))))
                for body = (etaf-org-content inner-env)
                collect
                (etaf-node
                 'column
                 (append
                  (list :flex-basis '(ch 0) :flex-grow 1 :width 'stretch
                        :item-gap '(lh 0))
                  (if card-p
                      (list :background-color surface
                            :border (etaf-org--hairline env)
                            :padding '((lh 1) (ch 2)))
                    (list :padding '((lh 0) (ch 0)))))
                 (delq nil
                       (list
                        (when time
                          (etaf-node 'text (list :color accent-col :font-weight 'bold)
                                     (list time)))
                        (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                                   (list (etaf-node 'text (list :font-weight 'bold)
                                                    (list title))))
                        (when body
                          (etaf-node 'box (list :margin-top '(lh 1) :width 'stretch)
                                     (list body))))))))))))

(etaf-org--define-shipped 'timeline
  :name "timeline"
  :summary "垂直或水平时间线容器（单列宽 < 28ch 自动退化纵向，对齐 etaf-md）"
  :accepts '((event :attrs ((title :type string :required t) (time :type string) (status :type string))))
  :attrs '((list-style :type enum :one-of (bullet decimal none) :default bullet :doc "标记样式")
           (start :type number :integer t :default 1 :doc "起始序号")
           (orientation :type enum :one-of (vertical horizontal) :default vertical :doc "排版方向")
           (card :type boolean :default nil :doc "卡片化每一项"))
  :view (lambda (env)
          (let* ((events (etaf-org-nodes--block-children env 'event))
                 (count (length events))
                 (orient (or (etaf-org-attr env :orientation) 'vertical))
                 (card-p (etaf-org-attr env :card))
                 (avail (etaf-org-available-width env))
                 (horiz (and (eq orient 'horizontal)
                             (> count 0)
                             (<= count 5)
                             (>= (/ avail count) 28))))
            (cond
             ((null events)
              (etaf-node 'text (list :color (etaf-org--muted env)) '("（空时间线）")))
             (horiz
              (etaf-org-nodes--timeline-horizontal env events card-p))
             (t
              (etaf-node
               'etaf-timeline
               (list :list-style (or (etaf-org-attr env :list-style) 'bullet)
                     :start (max 0 (or (etaf-org-attr env :start) 1))
                     :items
                     (cl-loop for ev in events for i from 0
                              collect
                              (let* ((node ev)
                                     (status (etaf-org-attr env :status node))
                                     (badge-st (when (memq status '(success warning danger info))
                                                 (list :text (pcase status
                                                               ('success "成功")
                                                               ('warning "警告")
                                                               ('danger "错误")
                                                               (_ "说明"))
                                                       :variant status))))
                                (list :key i
                                      :title (or (etaf-org-attr env :title node) "")
                                      :time (etaf-org-attr env :time node)
                                      :status badge-st
                                      :content
                                      (lambda ()
                                        (let ((inner (etaf-org-content
                                                      (etaf-org--env-for-node env node))))
                                          (if (and card-p inner)
                                              (etaf-node 'box
                                                         (list :width 'stretch
                                                               :background-color (etaf-org-surface env 'raised)
                                                               :border (etaf-org--hairline env)
                                                               :padding '((lh 0) (ch 2)))
                                                         (list inner))
                                            inner)))))))
               nil))))))

(etaf-org--define-shipped 'stat
  :name "stat"
  :summary "stats 内的单个 4 象限指标卡（对齐 etaf-md）"
  :attrs '((title :type string :required t :doc "指标名称")
           (value :type string :required t :doc "指标数值")
           (trend :type string :doc "变化趋势如 +18%")
           (note :type string :doc "右下角补充说明")
           (accent :type accent :doc "强调色")
           (spark :type string :doc "趋势微线数字序列"))
  :view (lambda (env)
          (let* ((title (or (etaf-org-attr env :title) ""))
                 (val (or (etaf-org-attr env :value) ""))
                 (trend (etaf-org-attr env :trend))
                 (note (etaf-org-attr env :note))
                 (accent (etaf-org-attr env :accent))
                 (spark (etaf-org-nodes--sparkline (etaf-org-attr env :spark)))
                 (muted (etaf-org--muted env))
                 (trend-color
                  (cond
                   ((and trend (string-match-p "\\`[+↑]" (string-trim trend)))
                    (etaf-org-accent env 'success))
                   ((and trend (string-match-p "\\`[-↓]" (string-trim trend)))
                    (etaf-org-accent env 'danger))
                   (accent (etaf-org-accent env accent))
                   (t muted)))
                 (spark-color (etaf-org-accent env (or accent 'primary)))
                 (val-color (if accent
                                (etaf-org-accent env accent)
                              (etaf-org--env-color env :ink))))
            ;; 4-quadrant equal-height card: Row 1 (title | trend), Row 2 (value | spark/note)
            (etaf-node
             'column (list :width 'stretch
                           :background-color (etaf-org-surface env 'raised)
                           :border (etaf-org--hairline env)
                           :padding '((lh 1) (ch 2))
                           :item-gap '(lh 1))
             (list
              (etaf-node
               'flex (list :width 'stretch :align-items 'center :column-gap '(ch 1))
               (delq nil
                     (list
                      (etaf-node 'text (list :color muted) (list title))
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                      (when trend
                        (etaf-node 'text (list :color trend-color :font-weight 'bold)
                                   (list trend))))))
              (etaf-node
               'flex (list :width 'stretch :align-items 'center :column-gap '(ch 1))
               (delq nil
                     (list
                      (etaf-node 'text (list :color val-color :font-weight 'bold)
                                 (list val))
                      (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                      (cond
                       (spark (etaf-node 'text (list :color spark-color) (list spark)))
                       (note (etaf-node 'text (list :color muted) (list note))))))))))))

(etaf-org--define-shipped 'stats
  :name "stats"
  :summary "关键数字指标组（4 象限等高卡，支持 :from 绑定 Org 表格）"
  :accepts '((stat :attrs ((title :type string) (value :type string)
                           (trend :type string) (note :type string)
                           (accent :type accent) (spark :type string))))
  :child-syntax 'markers
  :attrs '((columns :type number :integer t :default 3 :min 1 :max 6 :doc "每行指标数")
           (from :type string :doc "绑定具名 #+NAME: Org 表格作为指标数据源"))
  :view (lambda (env)
          (let* ((from-name (etaf-org-attr env :from))
                 (stat-nodes
                  (if from-name
                      (when-let* ((tbl (etaf-org-nodes--resolve-named-table env from-name)))
                        (let ((body-rows (nthcdr (or (plist-get tbl :header-count) 0)
                                                 (plist-get tbl :rows))))
                          (mapcar (lambda (row)
                                    (let ((cs (plist-get row :cells)))
                                      (etaf-org-node-create
                                       :type 'stat
                                       :attrs (list :title (or (plist-get (nth 0 cs) :raw) "")
                                                    :value (or (plist-get (nth 1 cs) :raw) "")
                                                    :trend (plist-get (nth 2 cs) :raw)))))
                                  body-rows)))
                    (or (etaf-org-nodes--block-children env 'stat)
                        (cl-remove-if-not (lambda (c) (and (etaf-org-node-p c)
                                                           (eq (etaf-org-node-type c) 'stat)))
                                          (etaf-org-children env)))))
                 (cols (max 1 (min (or (etaf-org-attr env :columns) 3)
                                   (max 1 (floor (/ (+ (etaf-org-available-width env) 2) 23))))))
                 (cards (mapcar (lambda (sn) (etaf-org--paint sn env)) stat-nodes))
                 (rows nil)
                 (rest cards))
            (while rest
              (let ((chunk (cl-subseq rest 0 (min cols (length rest)))))
                (setq rest (nthcdr (length chunk) rest))
                (push (etaf-node 'flex
                                 (list :width 'stretch :gap '((lh 1) (ch 2)) :align-items 'stretch)
                                 (mapcar (lambda (c)
                                           (etaf-node 'column
                                                      (list :flex-basis '(ch 0) :flex-grow 1
                                                            :width 'stretch :min-width '(ch 0))
                                                      (list c)))
                                         chunk))
                      rows)))
            (etaf-node 'column (list :width 'stretch :item-gap '(lh 1))
                       (or (nreverse rows)
                           (list (etaf-node 'text (list :color (etaf-org--muted env)) '("（无指标数据）"))))))))

(defun etaf-org-nodes--field-chip (env text variant)
  "Return TEXT as a compact filled chip matching `etaf-md--field-chip'."
  (let ((fill (pcase variant
                ('warning (etaf-org--env-color env :warn-soft))
                ('danger (etaf-org--env-color env :danger-soft))
                ('info (etaf-org--env-color env :accent-soft))
                (_ (etaf-org--env-color env :panel2)))))
    (etaf-node 'text
               (list :background-color fill
                     :color (etaf-org--env-color env :ink)
                     :font-weight 'bold)
               (list (format " %s " text)))))

(etaf-org--define-shipped 'field
  :name "field"
  :summary "API 参数卡或书刊风键值字段表（对齐 etaf-md）"
  :attrs '((name :type string :doc "参数名（声明即进入参数卡模式）")
           (type :type string :doc "类型注解")
           (type-link :type string :doc "类型跳转链接")
           (default :type string :doc "默认值")
           (required :type boolean :default nil :doc "是否必填")
           (deprecated :type string :doc "弃用说明")
           (experimental :type string :doc "实验性说明")
           (enum :type string :doc "枚举值")
           (unit :type string :doc "单位")
           (format :type string :doc "格式")
           (constraint :type string :doc "约束")
           (since :type string :doc "引入版本")
           (label-width :type length :doc "字段表名称列宽")
           (separator :type enum :one-of (colon none) :default colon :doc "名称与值分隔"))
  :view (lambda (env)
          (let ((name (etaf-org-attr env :name))
                (muted (etaf-org--muted env)))
            (if name
                ;; Parameter card mode (matches `etaf-md--field-card')
                (let* ((ty (etaf-org-attr env :type))
                       (ty-link (etaf-org-attr env :type-link))
                       (def (etaf-org-attr env :default))
                       (req (etaf-org-attr env :required))
                       (dep (etaf-org-attr env :deprecated))
                       (exp (etaf-org-attr env :experimental))
                       (enm (etaf-org-attr env :enum))
                       (unit (etaf-org-attr env :unit))
                       (fmt (etaf-org-attr env :format))
                       (cons-s (etaf-org-attr env :constraint))
                       (since (etaf-org-attr env :since))
                       (chips
                        (delq nil
                              (list (when req (etaf-org-nodes--field-chip env "必填" 'warning))
                                    (when dep
                                      (etaf-org-nodes--field-chip
                                       env (if (string-empty-p dep) "已弃用" (format "已弃用 %s" dep))
                                       'danger))
                                    (when exp
                                      (etaf-org-nodes--field-chip
                                       env (if (string-empty-p exp) "实验性" (format "实验性 %s" exp))
                                       'info)))))
                       (name-row
                        (etaf-node 'flex (list :width 'stretch :column-gap '(ch 1))
                                   (cons (etaf-node 'text (list :font-weight 'bold) (list name))
                                         chips)))
                       (type-node
                        (when ty
                          (if ty-link
                              (etaf-org--leaf-button env ty
                                                     (lambda () (etaf-org-follow-link env ty-link))
                                                     :role 'link :color (etaf-org-accent env 'primary)
                                                     :help ty-link)
                            (etaf-node 'text (list :color (etaf-org-accent env 'primary))
                                       (list ty)))))
                       (default-node
                        (when def
                          (etaf-node 'text (list :color muted) (list (format "默认 %s" def)))))
                       (since-node
                        (when since
                          (etaf-node 'text (list :color muted) (list (format "自 %s" since)))))
                       (meta-row
                        (when (or type-node default-node since-node)
                          (etaf-node 'flex (list :width 'stretch :column-gap '(ch 2))
                                     (delq nil (list type-node default-node since-node)))))
                       (extras
                        (delq nil
                              (list (when enm
                                      (format "可选值 %s"
                                              (string-join (split-string enm "[|,]" t "[ \t]+") " / ")))
                                    (when unit (format "单位 %s" unit))
                                    (when fmt (format "格式 %s" fmt))
                                    (when cons-s (format "约束 %s" cons-s)))))
                       (extra-row
                        (when extras
                          (etaf-node 'text (list :color muted)
                                     (list (string-join extras "    ")))))
                       (body (when (etaf-org-children env) (etaf-org-content env)))
                       (blank (etaf-node 'text nil (list " "))))
                  (etaf-node 'column
                             (list :width 'stretch :item-gap '(lh 0)
                                   :padding-inline '(ch 1)
                                   :border-left (etaf-org--hairline env))
                             (delq nil
                                   (list name-row meta-row
                                         (when body blank) body
                                         (when (and body extra-row) blank)
                                         extra-row))))
              ;; Borderless booktabs key-value list form (matches `etaf-md--field-list')
              (let* ((items (etaf-org-nodes--list-items-of env))
                     (pairs (mapcar (lambda (it)
                                      (let* ((txt (etaf-org-nodes--item-plain-text it))
                                             (sp (or (string-match "[ \t]+[：:][ \t]+" txt)
                                                     (and (> (length txt) 1)
                                                          (string-match "[：:]" txt 1)))))
                                        (if sp (cons (string-trim (substring txt 0 sp))
                                                     (string-trim (substring txt (match-end 0))))
                                          (cons (string-trim txt) ""))))
                                    items))
                     (sep (if (eq (etaf-org-attr env :separator) 'none) "  " "："))
                     (lw (or (etaf-org-attr env :label-width)
                             (list 'ch (+ (string-width sep)
                                          (max 2 (apply #'max 2
                                                        (mapcar (lambda (p) (string-width (car p)))
                                                                pairs))))))))
                (etaf-node 'column
                           (list :width 'stretch :item-gap '(lh 0))
                           (mapcar (lambda (p)
                                     (etaf-node 'flex
                                                (list :width 'stretch :gap '((lh 0) (ch 0))
                                                      :padding '((lh 0) (ch 1))
                                                      :border-bottom (etaf-org--hairline env))
                                                (list (etaf-node 'box
                                                                 (list :width lw :flex-shrink 0
                                                                       :text-align 'right
                                                                       :color muted)
                                                                 (list (etaf-node 'text nil (list (concat (car p) sep)))))
                                                      (etaf-node 'box
                                                                 (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'word)
                                                                 (list (etaf-node 'text nil (list (cdr p))))))))
                                   pairs)))))))

(defun etaf-org-nodes--file-tree-parse (raw)
  "Parse indented RAW lines into a forest of `(TEXT . CHILDREN)'."
  (let ((entries nil))
    (dolist (line (split-string (or raw "") "\n" t))
      (when (string-match "\\`\\([ \t]*\\)\\(?:[-+*][ \t]+\\)?\\(.*\\)\\'" line)
        (let* ((ws (replace-regexp-in-string "\t" "  " (match-string 1 line)))
               (body (string-trim (match-string 2 line))))
          (unless (string-empty-p body)
            (push (cons (length ws) body) entries)))))
    (setq entries (nreverse entries))
    (cl-labels ((take (min-indent)
                  (let ((nodes nil))
                    (while (and entries (>= (caar entries) min-indent))
                      (let* ((cur (pop entries))
                             (ind (car cur))
                             (txt (cdr cur))
                             (kids (when (and entries (> (caar entries) ind))
                                     (take (caar entries)))))
                        (push (cons txt kids) nodes)))
                    (nreverse nodes))))
      (take 0))))

(defun etaf-org-nodes--file-tree-entry-info (text)
  "Return `(NAME COMMENT DIFF FOCUS)' parsed from file-tree entry TEXT."
  (let ((text (string-trim (or text "")))
        (comment nil)
        (diff nil)
        (focus nil))
    (when (string-match "\\`\\(.+?\\)[ \t]+#[ \t]+\\(.+\\)\\'" text)
      (setq comment (match-string 2 text)
            text (string-trim (match-string 1 text))))
    (when (string-match "\\`\\(++\\|--\\)[ \t]*\\(.+\\)\\'" text)
      (setq diff (if (equal (match-string 1 text) "++") 'add 'remove)
            text (string-trim (match-string 2 text))))
    (when (string-match "\\`\\*\\{1,2\\}\\(.+?\\)\\*\\{1,2\\}\\'" text)
      (setq focus t
            text (match-string 1 text)))
    (list text comment diff focus)))

(defun etaf-org-nodes--file-tree-rows (env nodes prefix path-prefix collapsible clickable lines)
  "Paint file-tree NODES under PREFIX with true `├─'/`└─'/`│' guides."
  (let* ((count (length nodes))
         (mono (etaf-org--mono-family))
         (ink-main (etaf-org--env-color env :ink))
         (muted (etaf-org--muted env))
         (faint (or (etaf-org--env-color env :faint) muted))
         (hover (etaf-org--hover-fill env 'soft))
         (rows nil))
    (cl-loop for node in nodes
             for idx from 0
             for last = (= idx (1- count))
             do (let* ((info (etaf-org-nodes--file-tree-entry-info (car node)))
                       (name (nth 0 info))
                       (comment (nth 1 info))
                       (diff (nth 2 info))
                       (focus (nth 3 info))
                       (kids (cdr node))
                       (dir-p (or (and kids t) (string-suffix-p "/" name)))
                       (clean-name (string-remove-suffix "/" name))
                       (rel-path (if (and path-prefix (not (string-empty-p path-prefix)))
                                     (concat path-prefix "/" clean-name)
                                   clean-name))
                       (fold-key (cons 'tree-fold rel-path))
                       (collapsed (and collapsible dir-p
                                       (etaf-org-block-state env fold-key nil)))
                       (guide (if lines
                                  (concat prefix (if last "└─ " "├─ "))
                                prefix))
                       (next-prefix (if lines
                                        (concat prefix (if last "   " "│  "))
                                      (concat prefix "  ")))
                       (diff-ink (pcase diff
                                   ('add (etaf-org-accent env 'success))
                                   ('remove (etaf-org-accent env 'danger))))
                       (label-node
                        (cond
                         ((and collapsible dir-p)
                          (let ((fk fold-key) (cl collapsed))
                            (etaf-node 'text
                                       (append
                                        (list :font-family mono
                                              :color (or diff-ink (etaf-org-accent env 'primary))
                                              :font-weight 'bold
                                              :role 'button :tab-index 0 :pointer 'hand
                                              :help-echo (if cl "展开目录" "折叠目录")
                                              :on-press (lambda ()
                                                          (etaf-org-set-block-state env fk (not cl))))
                                        (when hover (list :hover-style (list :background-color hover))))
                                       (list (concat (if cl "▸ " "▾ ") name)))))
                         ((and clickable (not dir-p))
                          (let ((rp rel-path))
                            (etaf-node 'text
                                       (append
                                        (list :font-family mono
                                              :color (or diff-ink (etaf-org-accent env 'primary))
                                              :font-weight (and focus 'bold)
                                              :role 'link :tab-index 0 :pointer 'hand
                                              :help-echo (format "打开 %s" rp)
                                              :on-press (lambda ()
                                                          (etaf-org-follow-link env (concat "file:" rp))))
                                        (when hover (list :hover-style (list :background-color hover))))
                                       (list name))))
                         (t
                          (etaf-node 'text
                                     (list :font-family mono
                                           :color (or diff-ink
                                                      (if (or focus dir-p) ink-main muted))
                                           :font-weight (when (or focus dir-p) 'bold))
                                     (list name))))))
                  (push (etaf-node
                         'flex (list :width 'stretch)
                         (delq nil
                               (list
                                (unless (string-empty-p guide)
                                  (etaf-node 'text (list :font-family mono :color faint)
                                             (list guide)))
                                label-node
                                (when comment
                                  (etaf-node 'box
                                             (list :flex-basis '(ch 0) :flex-grow 1
                                                   :padding-left '(ch 2) :wrap-mode 'word)
                                             (list (etaf-node 'text (list :color muted)
                                                              (list (concat "# " comment)))))))))
                        rows)
                  (when (and kids (not collapsed))
                    (dolist (r (etaf-org-nodes--file-tree-rows
                                env kids next-prefix rel-path collapsible clickable lines))
                      (push r rows)))))
    (nreverse rows)))

(etaf-org--define-shipped 'file-tree
  :name "file-tree"
  :summary "带树线的目录文件树（支持 ++/-- 变更标色、# 注释与可折叠目录）"
  :attrs '((title :type string :doc "树标题")
           (lines :type boolean :default t :doc "绘制框线树枝")
           (collapsible :type boolean :default nil :doc "允许折叠目录")
           (clickable :type boolean :default nil :doc "点击文件打开"))
  :view (lambda (env)
          (let* ((title (etaf-org-attr env :title))
                 (draw-lines (etaf-org-attr env :lines))
                 (collapsible (etaf-org-attr env :collapsible))
                 (clickable (etaf-org-attr env :clickable))
                 (raw (or (plist-get (etaf-org-env-block env) :raw-content) ""))
                 (forest (etaf-org-nodes--file-tree-parse raw))
                 (rows (etaf-org-nodes--file-tree-rows
                        env forest "" "" collapsible clickable draw-lines)))
            (etaf-node 'box
                       (list :width 'stretch
                             :padding '((lh 1) (ch 2))
                             :background-color (etaf-org-surface env 'raised)
                             :border (etaf-org--hairline env))
                       (list
                        (etaf-node 'column
                                   (list :width 'stretch :item-gap '(lh 0))
                                   (append
                                    (when title
                                      (list (etaf-node 'text (list :font-weight 'bold) (list title))
                                            (etaf-node 'text nil '(" "))))
                                    rows)))))))

(etaf-org--define-shipped 'chat
  :name "chat"
  :summary "书刊风一问一答对话记录（不画气泡，支持 {名}/{.}/{:日期} 与 #+msg:）"
  :attrs '((title :type string :doc "对话标题"))
  :view (lambda (env)
          (let* ((title (etaf-org-attr env :title))
                 (raw (or (plist-get (etaf-org-env-block env) :raw-content) ""))
                 (muted (etaf-org--muted env))
                 (items nil)
                 (sender nil)
                 (self-p nil)
                 (buf nil))
            (cl-labels ((flush ()
                          (when buf
                            (push (list :kind 'message
                                        :name (unless self-p sender)
                                        :self self-p
                                        :text (string-join (nreverse buf) "\n"))
                                  items)
                            (setq buf nil))))
              (dolist (line (split-string raw "\n"))
                (let ((tr (string-trim line)))
                  (cond
                   ((string-match "\\`{:\\(.+\\)}\\'" tr)
                    (flush)
                    (push (list :kind 'date :text (match-string 1 tr)) items))
                   ((equal tr "{.}")
                    (flush) (setq sender nil self-p t))
                   ((string-match "\\`{\\([^}]+\\)}\\'" tr)
                    (flush) (setq sender (match-string 1 tr) self-p nil))
                   ((string-match "\\`#\\+msg:[ \t]*\\(.*\\)\\'" tr)
                    (flush)
                    (let* ((rest (match-string 1 tr))
                           (right-p (string-match-p ":side[ \t]+right" rest))
                           (clean (string-trim (replace-regexp-in-string ":side[ \t]+\\S-+" "" rest))))
                      (setq sender (unless right-p (if (string-empty-p clean) nil clean))
                            self-p (and right-p t))))
                   ((not (string-empty-p tr))
                    (push tr buf)))))
              (flush))
            (etaf-node
             'column (list :width 'stretch :item-gap '(lh 0))
             (delq nil
                   (list
                    (when title
                      (etaf-node 'box (list :width 'stretch :padding-bottom '(lh 1))
                                 (list (etaf-node 'text (list :font-weight 'bold) (list title)))))
                    (etaf-node
                     'column (list :width 'stretch :item-gap '(lh 1))
                     (mapcar
                      (lambda (it)
                        (if (eq (plist-get it :kind) 'date)
                            (etaf-node 'box (list :width 'stretch :text-align 'center)
                                       (list (etaf-node 'text (list :color muted)
                                                        (list (plist-get it :text)))))
                          (let ((name (plist-get it :name))
                                (self (plist-get it :self))
                                (msg (plist-get it :text)))
                            (etaf-node
                             'box (list :width 'stretch :text-align (if self 'right 'left))
                             (list
                              (etaf-node
                               'column (list :width 'stretch :item-gap '(lh 0))
                               (delq nil
                                     (list
                                      (when name
                                        (etaf-node 'text (list :color muted :font-weight 'bold)
                                                   (list name)))
                                      (etaf-node 'box (list :width 'stretch :wrap-mode 'word)
                                                 (list (etaf-node 'text nil (list msg))))))))))))
                      (nreverse items)))))))))

;;; ---------------------------------------------------------------------------
;;; 5. Interactive Containers: tabs, code-tabs, tab-panel, accordion, swiper, code-tree
;;; ---------------------------------------------------------------------------

(defun etaf-org-nodes--tab-label (env tb index &optional code-p)
  "Return display label for tab node TB at INDEX in ENV."
  (let ((first-block (car (etaf-org-children env tb))))
    (or (etaf-org-attr env :title tb)
        (and code-p (listp first-block) (plist-get first-block :lang))
        (format "标签 %d" (1+ index)))))

(defun etaf-org-nodes--code-tab-page (env page)
  "Paint code-tabs PAGE flush without repeating a second border or language bar."
  (let ((leg (etaf-org-env-legacy-env env)))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0))
     (delq nil
           (mapcar
            (lambda (child)
              (let ((blk (if (etaf-org-node-p child) (etaf-org-node-block child) child)))
                (if (and (listp blk) (eq (plist-get blk :type) 'src-block))
                    (etaf-org--code-block-view blk leg nil '(:frame nil :header nil))
                  (etaf-org--paint child env))))
            (etaf-org-children env page))))))

(defun etaf-org-nodes--paint-tabs (env &optional code-p edge-p)
  "Shared paint for `tabs', `code-tabs' and `tab-panel'."
  (let* ((tabs (etaf-org-children env))
         (default-idx (or (cl-position-if (lambda (tb) (etaf-org-attr env :selected tb)) tabs) 0))
         (active (etaf-org-block-state env :selected default-idx))
         (active (if (and (integerp active) (>= active 0) (< active (length tabs))) active 0)))
    (if (null tabs)
        (etaf-node 'text (list :color (etaf-org--muted env)) '("（空标签页）"))
      (let* ((items (cl-loop for tb in tabs for i from 0
                             collect (list :key i
                                           :label (etaf-org-nodes--tab-label env tb i code-p))))
             (cur-tab (nth active tabs))
             (cur-env (etaf-org--env-for-node env cur-tab))
             (body (if code-p
                       (etaf-org-nodes--code-tab-page cur-env cur-tab)
                     (etaf-org-content cur-env))))
        (if edge-p
            ;; Top-edge integrated tab panel (`etaf-edge-tabs', matches `etaf-md--tab-panel-view')
            (let* ((accent (etaf-org-attr env :accent))
                   (accent-col (unless (or (null accent) (eq accent 'neutral))
                                 (etaf-org-accent env accent))))
              (etaf-node 'etaf-edge-tabs
                         (list :items items
                               :active active
                               :accent accent-col
                               :width (or (etaf-org-attr env :width) 'stretch)
                               :on-change (lambda (key)
                                            (etaf-org-set-block-state env :selected key)))
                         (when body
                           (list (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 1)))
                                            (list body))))))
          ;; Framed `etaf-tabs' (`tabs' / flush `code-tabs')
          (etaf-node 'column
                     (list :width 'stretch :item-gap '(lh 0)
                           :border (etaf-org--hairline env)
                           :background-color (when code-p (etaf-org-surface env 'raised)))
                     (list
                      (etaf-node 'etaf-tabs
                                 (list :items items
                                       :active active
                                       :framed nil
                                       :on-change (lambda (key)
                                                    (etaf-org-set-block-state env :selected key)))
                                 nil)
                      (etaf-node 'box
                                 (list :width 'stretch
                                       :padding (if code-p '((lh 0) (ch 0)) '((lh 1) (ch 2)))
                                       :border-top (etaf-org--hairline env))
                                 (when body (list body))))))))))

(etaf-org--define-shipped 'tabs
  :name "tabs"
  :summary "可切换标签页容器（etaf-tabs，#+tab: 标记子块）"
  :accepts '((tab :attrs ((title :type string) (selected :type boolean))))
  :child-syntax 'markers
  :attrs '((accent :type accent :default primary :doc "选中标签强调色")
           (target :type string :doc "联动目标区域 ID")
           (id :type string :doc "锚点 ID"))
  :view (lambda (env) (etaf-org-nodes--paint-tabs env nil nil)))

(etaf-org--define-shipped 'code-tabs
  :name "code-tabs"
  :summary "单框多语言代码标签页（etaf-tabs，省略标题时取代码块语言名）"
  :accepts '((tab :attrs ((title :type string) (selected :type boolean))))
  :child-syntax 'markers
  :attrs '((accent :type accent :default primary :doc "强调色"))
  :view (lambda (env) (etaf-org-nodes--paint-tabs env t nil)))

(etaf-org--define-shipped 'tab-panel
  :name "tab-panel"
  :summary "顶边一体化标签面板（etaf-edge-tabs）"
  :accepts '((tab :attrs ((title :type string) (selected :type boolean))))
  :child-syntax 'markers
  :attrs '((accent :type accent :default neutral :doc "框线与选中强调色")
           (width :type length :doc "宽度"))
  :view (lambda (env) (etaf-org-nodes--paint-tabs env nil t)))

(etaf-org--define-shipped 'collapse
  :name "collapse"
  :summary "accordion 内的单个可折叠子块"
  :attrs '((title :type string :required t :doc "折叠标题")
           (open :type boolean :default nil :doc "默认展开")
           (index :type number :integer t :min 0 :doc "显示顺序"))
  :view (lambda (env) (etaf-org-content env)))

(etaf-org--define-shipped 'accordion
  :name "accordion"
  :summary "手风琴折叠组容器（etaf-accordion）"
  :accepts '((collapse :attrs ((title :type string :required t)
                               (open :type boolean)
                               (index :type number))))
  :attrs '((expand :type boolean :default nil :doc "打开时展开全部项")
           (accordion :type boolean :default t :doc "同时仅展开一项"))
  :view (lambda (env)
          (let* ((raw-items (etaf-org-nodes--block-children env 'collapse))
                 (items (seq-sort-by
                         (lambda (c) (or (etaf-org-attr env :index c) most-positive-fixnum))
                         #'< raw-items))
                 (count (length items)))
            (if (zerop count)
                (etaf-node 'text (list :color (etaf-org--muted env)) '("（空折叠组）"))
              (let* ((all (number-sequence 0 (1- count)))
                     (expand-all (etaf-org-attr env :expand))
                     (single (etaf-org-attr env :accordion))
                     (multiple (or expand-all (not single)))
                     (slot-key (or (plist-get (etaf-org-env-slot env) :key)
                                   (sxhash items)))
                     (raw-default
                      (if expand-all all
                        (cl-loop for it in items for i from 0
                                 when (etaf-org-attr env :open it) collect i)))
                     (default-open (if (and (not multiple) (cdr raw-default))
                                       (list (car raw-default))
                                     raw-default))
                     (stored (etaf-org-block-state env :open default-open))
                     (valid-open (seq-filter (lambda (k) (and (integerp k) (>= k 0) (< k count)))
                                             (if (listp stored) stored nil)))
                     (open-set (if (and (not multiple) (cdr valid-open))
                                   (list (car valid-open))
                                 valid-open)))
                (etaf-node
                 'etaf-accordion
                 (list :items (cl-loop for it in items for i from 0
                                       collect
                                       (let* ((node it)
                                              (cenv (etaf-org--env-for-node env node))
                                              (has-body (and (etaf-org-children cenv) t)))
                                         (list :key i
                                               :ref (intern (format "etaf-org-accordion-%s-%d"
                                                                    slot-key i))
                                               :label (or (etaf-org-attr env :title node)
                                                          (format "项目 %d" (1+ i)))
                                               :content (if has-body
                                                            (lambda () (etaf-org-content cenv))
                                                          ""))))
                       :open open-set
                       :multiple multiple
                       :on-toggle (lambda (opened)
                                    (etaf-org-set-block-state env :open opened)))
                 nil))))))

(etaf-org--define-shipped 'swiper
  :name "swiper"
  :summary "分页轮播展示容器（etaf-tabs + 沉底舞台，#+slide: 标记每页）"
  :accepts '((slide :attrs ((title :type string) (selected :type boolean))))
  :child-syntax 'markers
  :attrs '((accent :type accent :default primary :doc "强调色"))
  :view (lambda (env)
          (let* ((slides (etaf-org-children env))
                 (total (length slides))
                 (initial (or (cl-position-if (lambda (s) (etaf-org-attr env :selected s)) slides) 0))
                 (cur (mod (or (etaf-org-block-state env :selected initial) 0) (max 1 total))))
            (if (zerop total)
                (etaf-node 'text (list :color (etaf-org--muted env)) '("（空轮播）"))
              (let* ((slide (nth cur slides))
                     (body (etaf-org-content (etaf-org--env-for-node env slide))))
                (etaf-node 'column
                           (list :width 'stretch :item-gap '(lh 0)
                                 :border (etaf-org--hairline env))
                           (list
                            (etaf-node 'etaf-tabs
                                       (list :items (cl-loop for s in slides for i from 0
                                                             collect
                                                             (list :key i
                                                                   :label (or (etaf-org-attr env :title s)
                                                                              (format "%d/%d" (1+ i) total))))
                                             :active cur
                                             :framed nil
                                             :on-change (lambda (key)
                                                          (etaf-org-set-block-state env :selected key)))
                                       nil)
                            (etaf-node 'box
                                       (list :width 'stretch
                                             :background-color (etaf-org-surface env 'sunken)
                                             :border-top (etaf-org--hairline env)
                                             :padding '((lh 1) (ch 2)))
                                       (when body (list body))))))))))

(defun etaf-org-nodes--code-tree-rows (files)
  "Group `(PATH . NODE)' FILES into dir and file display rows."
  (let ((rows nil) (last 'none))
    (cl-loop for pair in files for idx from 0 do
             (let* ((path (car pair))
                    (dir (file-name-directory path))
                    (name (file-name-nondirectory path)))
               (when (and dir (not (equal dir last)))
                 (push (cons 'dir dir) rows)
                 (setq last dir))
               (push (cons 'file (cons idx name)) rows)))
    (nreverse rows)))

(etaf-org--define-shipped 'code-tree
  :name "code-tree"
  :summary "左侧文件列表 + 右侧单框代码面板（#+file: 标记每个文件）"
  :accepts '((file :attrs ((title :type string))))
  :child-syntax 'markers
  :attrs '((title :type string :doc "标题")
           (height :type number :integer t :doc "代码区行数（超出滚动），省略自适应"))
  :view (lambda (env)
          (let* ((file-nodes (etaf-org-children env))
                 (count (length file-nodes))
                 (active (min (max 0 (or (etaf-org-block-state env :selected) 0))
                              (max 0 (1- count))))
                 (avail (etaf-org-available-width env))
                 (wide (>= avail 76)))
            (if (zerop count)
                (etaf-node 'text (list :color (etaf-org--muted env)) '("（空代码树）"))
              (let* ((files (cl-loop for f in file-nodes for i from 0
                                     collect (cons (or (etaf-org-attr env :title f)
                                                       (format "file-%d" (1+ i)))
                                                   f)))
                     (rows (etaf-org-nodes--code-tree-rows files))
                     (selected-node (cdr (nth active files)))
                     (first-src (cl-find-if
                                 (lambda (c)
                                   (let ((b (if (etaf-org-node-p c) (etaf-org-node-block c) c)))
                                     (and (listp b) (eq (plist-get b :type) 'src-block))))
                                 (etaf-org-children env selected-node)))
                     (src-blk (when first-src
                                (if (etaf-org-node-p first-src)
                                    (etaf-org-node-block first-src)
                                  first-src)))
                     (accent (etaf-org-accent env 'primary))
                     (accent-soft (or (etaf-org--env-color env :accent-soft)
                                      (etaf-org-surface env 'sunken)))
                     (muted (etaf-org--muted env))
                     (faint (or (etaf-org--env-color env :faint) muted))
                     (nav-w (min (max 16 (floor (* avail 0.34)))
                                 (max 16 (+ 6 (apply #'max 10
                                                     (mapcar (lambda (r)
                                                               (if (eq (car r) 'dir)
                                                                   (string-width (cdr r))
                                                                 (+ 2 (string-width (cddr r)))))
                                                             rows))))))
                     (pane-w (if wide (max 24 (- avail nav-w 3)) avail))
                     (code-view
                      (if src-blk
                          (etaf-org--code-block-view
                           src-blk
                           (etaf-org-env-legacy-env (etaf-org--env-with-width env pane-w))
                           nil '(:frame nil :header nil))
                        (etaf-org-content (etaf-org--env-for-node env selected-node pane-w))))
                     (nav-views
                      (mapcar
                       (lambda (r)
                         (if (eq (car r) 'dir)
                             (etaf-node 'box (list :width 'stretch :padding-inline '(ch 1))
                                        (list (etaf-node 'text (list :color faint) (list (cdr r)))))
                           (let* ((idx (cadr r))
                                  (name (cddr r))
                                  (chosen (= idx active))
                                  (hover (unless chosen (etaf-org--hover-fill env 'soft))))
                             (etaf-node 'box (list :width 'stretch :padding-inline '(ch 2))
                                        (list
                                         (etaf-node 'text
                                                    (append
                                                     (list :background-color (when chosen accent-soft)
                                                           :color (if chosen accent muted)
                                                           :font-weight (when chosen 'bold)
                                                           :role 'button :tab-index 0
                                                           :pointer (unless chosen 'hand)
                                                           :on-press (lambda ()
                                                                       (etaf-org-set-block-state env :selected idx)))
                                                     (when hover
                                                       (list :hover-style (list :background-color hover))))
                                                    (list name)))))))
                       rows))
                     (req-height (etaf-org-attr env :height))
                     (scroll-h (when (and (integerp req-height) (> req-height 0))
                                 (max 4 req-height)))
                     ;; Account for header (1lh) + borders/divider (1lh) so
                     ;; bottom code line is never half-clipped inside scroll box.
                     (total-h (when scroll-h (+ scroll-h 2)))
                     (scroll-ref (when scroll-h
                                   (intern (format "org-code-tree-scroll-%s"
                                                   (or (plist-get (etaf-org-env-slot env) :key)
                                                       (sxhash files))))))
                     (code-body-box
                      (if scroll-h
                          (etaf-node 'box
                                     (list :width 'stretch
                                           :height (list 'lh scroll-h)
                                           :min-height (list 'lh scroll-h)
                                           :max-height (list 'lh scroll-h)
                                           :overflow 'scroll
                                           :wrap-mode 'word
                                           :tab-index 0
                                           :ref scroll-ref
                                           :on-scroll (lambda (_offset) nil)
                                           :on-direction
                                           (lambda (direction)
                                             (pcase direction
                                               ((or 'up 'down)
                                                (let ((rt (etaf-runtime-for-buffer (current-buffer)))
                                                      (delta (if (eq direction 'up) -1 1)))
                                                  (when rt
                                                    (if (eq (etaf-focused-host-ref rt) scroll-ref)
                                                        (etaf-scroll-to
                                                         rt scroll-ref
                                                         (+ (etaf-scroll-offset rt scroll-ref)
                                                            delta))
                                                      (etaf-scroll-viewport rt delta))))
                                                'handled)
                                               (_ 'release)))
                                           :aria-label "代码，滚动查看")
                                     (when code-view (list code-view)))
                        (etaf-node 'box (list :width 'stretch :padding '((lh 0) (ch 0)))
                                   (when code-view (list code-view)))))
                     (code-pane
                      (etaf-node 'column
                                 (append
                                  (list :width 'stretch :item-gap '(lh 0)
                                        :border (etaf-org--hairline env)
                                        :background-color (or (etaf-org--env-color env :code-bg)
                                                              (etaf-org-surface env 'raised)))
                                  (when total-h
                                    (list :height (list 'lh total-h)
                                          :min-height (list 'lh total-h)
                                          :max-height (list 'lh total-h)))
                                  (when wide '(:flex-basis (ch 0) :flex-grow 1 :min-width (ch 0))))
                                 (list
                                  (etaf-node 'flex
                                             (list :width 'stretch :align-items 'center
                                                   :border-bottom (etaf-org--hairline env)
                                                   :padding '((lh 0) (ch 2)))
                                             (list (etaf-node 'text (list :color muted)
                                                              (list (car (nth active files))))
                                                   (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
                                                   (when (and src-blk (plist-get src-blk :lang))
                                                     (etaf-node 'text (list :color faint)
                                                                (list (plist-get src-blk :lang))))))
                                  code-body-box))))
                (if wide
                    (etaf-node 'flex
                               (list :width 'stretch :column-gap '(ch 1) :align-items 'stretch)
                               (list
                                (etaf-node 'box
                                           (append
                                            (list :width (list 'ch nav-w) :flex-shrink 0
                                                  :border (etaf-org--hairline env)
                                                  :background-color (etaf-org-surface env 'raised)
                                                  :padding '((lh 1) (ch 1)))
                                            (when total-h
                                              (list :height (list 'lh total-h)
                                                    :min-height (list 'lh total-h)
                                                    :max-height (list 'lh total-h))))
                                           (list (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
                                                            nav-views)))
                                code-pane))
                  (etaf-node 'column (list :width 'stretch :item-gap '(lh 1))
                             (list
                              (etaf-node 'box (list :width 'stretch
                                                    :border (etaf-org--hairline env)
                                                    :background-color (etaf-org-surface env 'raised)
                                                    :padding '((lh 0) (ch 1)))
                                         (list (etaf-node 'column (list :width 'stretch :item-gap '(lh 0))
                                                          nav-views)))
                              code-pane))))))))

;;; ---------------------------------------------------------------------------
;;; 6. Site & Showcase Cards: home-box, image-card, link-card, qrcode
;;; ---------------------------------------------------------------------------

(etaf-org--define-shipped 'home-box
  :name "home-box"
  :summary "首屏强调展示盒（对齐 etaf-md）"
  :attrs '((title :type string :required t :doc "主标题")
           (description :type string :doc "副标题摘要")
           (href :type string :doc "行动链接")
           (accent :type accent :default primary :doc "强调色")
           (background :type surface :default raised :doc "底色"))
  :view (lambda (env)
          (let* ((title (etaf-org-attr env :title))
                 (desc (etaf-org-attr env :description))
                 (href (etaf-org-attr env :href))
                 (accent (or (etaf-org-attr env :accent) 'primary))
                 (surface (or (etaf-org-surface env (or (etaf-org-attr env :background) 'raised))
                              (etaf-org-surface env 'raised)))
                 (body (etaf-org-content env)))
            (etaf-node 'box
                       (list :width 'stretch
                             :background-color surface
                             :border (etaf-org--hairline env)
                             :padding '((lh 1) (ch 3)))
                       (list
                        (etaf-node 'column
                                   (list :width 'stretch :item-gap '(lh 0))
                                   (delq nil
                                         (list
                                          (when title
                                            (etaf-node 'text
                                                       (list :color (etaf-org-accent env accent)
                                                             :font-weight 'bold)
                                                       (list title)))
                                          (when desc
                                            (etaf-node 'text (list :color (etaf-org--muted env))
                                                       (list desc)))
                                          (when href
                                            (etaf-org--leaf-button
                                             env (format "→ %s" href)
                                             (lambda () (etaf-org-follow-link env href))
                                             :role 'link :color (etaf-org-accent env accent)
                                             :bold t :help href))
                                          (when (and body (or title desc href))
                                            (etaf-node 'text nil '(" ")))
                                          body))))))))

(etaf-org--define-shipped 'link-card
  :name "link-card"
  :summary "整块可点链接卡片（对齐 etaf-md）"
  :attrs '((href :type string :required t :doc "跳转地址")
           (title :type string :required t :doc "链接标题")
           (description :type string :doc "摘要说明"))
  :view (lambda (env)
          (let ((href (etaf-org-attr env :href))
                (title (etaf-org-attr env :title))
                (desc (etaf-org-attr env :description)))
            (etaf-node 'column
                       (list :width 'stretch :item-gap '(lh 0)
                             :background-color (etaf-org-surface env 'raised)
                             :border (etaf-org--hairline env)
                             :padding '((lh 1) (ch 2))
                             :pointer 'hand
                             :on-press (lambda () (etaf-org-follow-link env href)))
                       (delq nil
                             (list
                              (etaf-node 'text (list :font-weight 'bold) (list title))
                              (etaf-node 'text nil '(" "))
                              (when desc
                                (etaf-node 'text (list :color (etaf-org--muted env)) (list desc)))
                              (etaf-org--leaf-button
                               env (format "→ %s" href)
                               (lambda () (etaf-org-follow-link env href))
                               :role 'link :bold nil :help href)))))))

(etaf-org--define-shipped 'image-card
  :name "image-card"
  :summary "图文展示卡片（对齐 etaf-md）"
  :attrs '((src :type string :required t :doc "图片路径或 URL")
           (title :type string :doc "图片标题")
           (description :type string :doc "说明文字")
           (href :type string :doc "点击链接")
           (width :type length :doc "卡片宽度"))
  :view (lambda (env)
          (let* ((src (etaf-org-attr env :src))
                 (title (etaf-org-attr env :title))
                 (desc (etaf-org-attr env :description))
                 (href (etaf-org-attr env :href))
                 (session (etaf-org-env-session env))
                 (dir (and session (plist-get session :dir)))
                 (local (cond
                         ((etaf-org-cache--http-url-p src) (etaf-org-cache-image-path src))
                         (src (expand-file-name src (or dir default-directory)))))
                 (avail (min 46 (max 20 (- (etaf-org-available-width env) 4)))))
            (etaf-node 'column
                       (list :width (or (etaf-org-attr env :width) 'stretch)
                             :cross-align 'start
                             :item-gap '(lh 0)
                             :background-color (etaf-org-surface env 'raised)
                             :border (etaf-org--hairline env)
                             :padding '((lh 1) (ch 2))
                             :pointer (when href 'hand)
                             :on-press (when href (lambda () (etaf-org-follow-link env href))))
                       (delq nil
                             (list
                              (if (and local (file-exists-p local))
                                  (let* ((px (etaf-org-typeset--image-pixels local))
                                         (grid (etaf-org-typeset--grid-for-pixels px avail 14)))
                                    (etaf-node 'image (list :src local :columns (car grid) :rows (cdr grid) :adapter 'auto) nil))
                                (etaf-node 'text (list :color (etaf-org--muted env))
                                           (list (format "图片：%s" src))))
                              (when (or title desc) (etaf-node 'text nil '(" ")))
                              (when title
                                (if href
                                    (etaf-org--leaf-button env title
                                                           (lambda () (etaf-org-follow-link env href))
                                                           :role 'link :bold t :help href)
                                  (etaf-node 'text (list :font-weight 'bold) (list title))))
                              (when desc
                                (etaf-node 'text (list :color (etaf-org--muted env)) (list desc)))))))))

(etaf-org--define-shipped 'qrcode
  :name "qrcode"
  :summary "可扫描二维码块（qrencode 异步绘制，居中无框）"
  :attrs '((text :type string :doc "编码文本")
           (title :type string :doc "二维码说明"))
  :view (lambda (env)
          (let* ((block (etaf-org-env-block env))
                 (text (or (etaf-org-attr env :text)
                           (string-trim (or (plist-get block :raw-content) ""))))
                 (title (etaf-org-attr env :title))
                 (qr-path (plist-get block :qr)))
            (etaf-node 'column
                       (list :width 'stretch :cross-align 'center :item-gap '(lh 0))
                       (delq nil
                             (list
                              (when title
                                (etaf-node 'text (list :color (etaf-org--muted env)) (list title)))
                              (if (and qr-path (file-exists-p qr-path))
                                  (etaf-node 'image (list :src qr-path :columns 20 :rows 10 :adapter 'auto) nil)
                                (etaf-node 'text (list :color (etaf-org--env-color env :faint))
                                           (list (if (etaf-org-qrcode-available-p)
                                                     (format "（二维码生成中：%s）" text)
                                                   (format "（需要 qrencode 绘制二维码：%s）" text)))))))))))

(provide 'etaf-org-nodes)
;;; etaf-org-nodes.el ends here
