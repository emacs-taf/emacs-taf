;;; etaf-md-nodes.el --- Shipped node definitions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The definitions the package ships, written the same way a reader writes one:
;; attributes, then a paint.  A paint reads only its environment, so it never
;; touches a session, a file or a global.  A container whose shape already
;; exists as an etaf-ui Component translates its attributes to that Component;
;; only a shape used here alone is built from the DSL, as article 9.2 says.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf-md-env)

;;; Shared helpers

(defun etaf-md--accepts (env child)
  "Return ENV's declaration of CHILD's type, or nil when it accepts it open."
  (let* ((definition (etaf-md-node-definition (etaf-md-type env)))
         (accepts (plist-get definition :accepts))
         (entry (and accepts (assq (etaf-md-node-type child) accepts))))
    (when accepts (or entry 'rejected))))

(defun etaf-md--child-problems (env child)
  "Return messages for CHILD's attributes that break ENV's declaration."
  (let* ((entry (etaf-md--accepts env child))
         (attrs (etaf-md-node-attrs child))
         (decls (etaf-md--declarations
                 (plist-get (and (consp (cdr-safe entry)) (cdr entry)) :attrs)))
         (problems nil))
    (cond
     ((null entry) nil)
     ((eq entry 'rejected)
      (list (format "%s is not a child of %s"
                    (etaf-md-node-type child) (etaf-md-type env))))
     (t
      (dolist (decl decls (nreverse problems))
        (let* ((key (car decl))
               (value (plist-get attrs key))
               (problem (and value
                             (etaf-md--value-problem
                              key (cdr decl) value 'document))))
          (cond ((and (plist-get (cdr decl) :required) (null value))
                 (push (format "%s is required"
                               (substring (symbol-name key) 1))
                       problems))
                (problem (push problem problems)))))))))

(defun etaf-md--child-view (env child)
  "Return CHILD's own body painted under ENV, or its failure line."
  (let ((problems (etaf-md--child-problems env child)))
    (if problems
        (etaf-md--failure-view
         env (or (etaf-md-attr env :title child)
                 (format "%s" (etaf-md-node-type child)))
         (car problems))
      (etaf-md-render env (etaf-md-children env child)))))

(defun etaf-md--vertical-length (length)
  "Return LENGTH as vertical spacing Ebox accepts.
Vertical space is a whole number of lines, so a width unit draws none."
  (if (memq (car-safe length) '(lh %)) length '(lh 0)))

(defun etaf-md--number-list (text)
  "Return the space separated numbers in TEXT as integers."
  (delq nil
        (mapcar (lambda (word)
                  (when (string-match-p "\\`[0-9]+\\'" word)
                    (string-to-number word)))
                (split-string (or text "") "[ \t]+" t))))


;;; Structure

(etaf-md--define-shipped 'box
  :name "box"
  :summary "带底色与内边距的容器"
  :attrs '((surface    :type surface :default none  :doc "外壳底色")
           (padding    :type length  :default "2ch" :doc "左右内边距")
           (text-align :type align   :default start :doc "内容的水平位置")
           (width      :type length                 :doc "自身宽度"))
  :view (lambda (env)
          (etaf-view
           (box :width (or (etaf-md-attr env :width) 'stretch)
                :text-align (etaf-md-attr env :text-align)
                :padding (list '(lh 1) (etaf-md-attr env :padding))
                :background-color (etaf-md-surface env (etaf-md-attr env :surface))
                :border (etaf-md--hairline env)
             (expr (etaf-md-content env))))))

(etaf-md--define-shipped 'card
  :name "card"
  :summary "带标题与摘要的卡片"
  :attrs '((title       :type string :required t :pattern "[^[:space:]]" :doc "卡片标题")
           (icon        :type string                          :doc "标题前的图标名")
           (description :type string                          :doc "标题下的一行")
           (href        :type string                          :doc "整张卡片可点")
           (accent      :type accent  :default neutral        :doc "标题的强调色")
           (text-align  :type align   :default start          :doc "内容的水平位置")
           (width       :type length                          :doc "自身宽度"))
  :view (lambda (env)
          (let ((href (etaf-md-attr env :href)))
            (etaf-view
             (etaf-card :title (etaf-md-attr env :title)
                        :icon (etaf-md-attr env :icon)
                        :description (etaf-md-attr env :description)
                        :variant (etaf-md-attr env :accent)
                        :width (or (etaf-md-attr env :width) 'stretch)
                        :text-align (etaf-md-attr env :text-align)
                        :on-press (when href
                                    (lambda () (etaf-md-follow-link env href)))
               (expr (etaf-md-content env)))))))

(defun etaf-md--justify (word)
  "Return WORD as the justification Ebox names.
A document writes `between' and `around'; the engine spells them
`space-between' and `space-around'.  The others are the same word."
  (pcase word
    ('between 'space-between)
    ('around 'space-around)
    (_ word)))

(defun etaf-md--column-tracks (env count)
  "Return the width spec of each column of ENV's row.
A number of columns shares the width equally; a track string gives each column
its own `fr' share or fixed size."
  (let ((columns (etaf-md-attr env :columns)))
    (cond
     ((and (stringp columns) (string-match-p "\\`[0-9]+\\'" columns))
      (make-list count (list :flex-grow 1)))
     ((stringp columns)
      (mapcar
       (lambda (token)
         (cond ((string-match "\\`\\([0-9.]+\\)fr\\'" token)
                (list :flex-grow (string-to-number (match-string 1 token))))
               ((string-match "\\`\\([0-9]+\\)\\(ch\\|%\\)\\'" token)
                (list :width (list (intern (match-string 2 token))
                                   (string-to-number (match-string 1 token)))))))
       (split-string columns "[ \t]+" t)))
     ((> count 0) (make-list count (list :flex-grow 1))))))

(defun etaf-md--column-divider (env)
  "Return the one-pixel rule between two columns of ENV."
  (etaf-node 'box
             (list :width '(px 1)
                   :flex-shrink 0
                   :border-left (etaf-md--hairline env))
             nil))

(etaf-md--define-shipped 'columns
  :name "columns"
  :summary "等宽分栏，窄窗减栏"
  :attrs '((columns       :type string :default "2"
             :doc "一行几栏，或一串轨道")
           (gap           :type length :default "2ch" :doc "栏间距")
           (padding       :type length :doc "左右内边距")
           (min-width     :type length :default "24ch" :doc "每栏最小宽度")
           (align-items   :type enum :one-of (start center end stretch)
                          :default stretch :doc "子块在交叉轴的对齐")
           (justify-content :type enum :one-of (start center end between around)
                            :default start :doc "子块在主轴的对齐")
           (wrap          :type boolean :default nil :doc "放不下时换行")
           (divider       :type boolean :default t   :doc "栏与栏之间画一条竖线")
           (align-self    :type enum :one-of (start center end)
                          :default start :doc "自身在父级里的水平位置"))
  :accepts '((col :attrs ((grow :type number :default 1 :doc "宽度份数"))))
  :view (lambda (env)
          (let* ((columns (etaf-md-attr env :columns))
                 (count (if (stringp columns)
                            (if (string-match-p "\\`[0-9]+\\'" columns)
                                (max 1 (min 6 (string-to-number columns)))
                              2)
                          (max 1 (min 6 columns))))
                 (gap (etaf-md-attr env :gap))
                 (width (etaf-md-available-width env))
                 (min-width (etaf-md-attr env :min-width))
                 (min-columns (if min-width
                                  (max 1 (floor (/ width (cadr min-width))))
                                count))
                 (per (if (etaf-md-attr env :wrap)
                          count
                        (max 1 (min count min-columns))))
                 (tracks (etaf-md--column-tracks env per))
                 (divider (etaf-md-attr env :divider))
                 (rows (seq-partition (etaf-md-children env) per)))
            ;; The number of rows is only known while painting, so the rows are
            ;; built as nodes instead of being written out in the DSL.
            (etaf-node
             'column
             (list :width 'stretch
                   :item-gap '(lh 1)
                   :align-self (etaf-md-attr env :align-self)
                   :padding (when-let* ((padding (etaf-md-attr env :padding)))
                              (list '(lh 0) padding)))
             (mapcar
              (lambda (row)
                (etaf-node
                 'flex
                 (list :width 'stretch
                       :gap (list '(lh 0) gap)
                       :align-items (etaf-md-attr env :align-items)
                       :justify-content (etaf-md--justify
                                         (etaf-md-attr env :justify-content)))
                 (cl-loop
                  for col in row
                  for first = t then nil
                  for track in tracks
                  ;; A column is a declared child, not a type of its own, so
                  ;; the parent paints its content instead of asking for a
                  ;; definition the child never has.  The rule between two
                  ;; columns is its own one-pixel box, so a stretched column
                  ;; never decides where it sits.
                  append
                  (append
                   (when (and divider (not first))
                     (list (etaf-md--column-divider env)))
                   (list (etaf-node
                          'column
                          (append
                           (list :item-gap '(lh 0))
                           ;; Equal tracks start from zero and share the row:
                           ;; a column that starts from its content width
                           ;; would make a long paragraph wider than its
                           ;; neighbour, and the panes would never line up.
                           (if (eq (car track) :width)
                               (list :width (cadr track))
                             (list :flex-basis '(ch 0)
                                   :flex-grow (cadr track)
                                   :width 'stretch)))
                          (list (etaf-md-render
                                 env
                                 (etaf-md-children env col)))))))))
              rows)))))


;;; Callouts

(defun etaf-md--callout-accent (type)
  "Return the accent word a callout TYPE fixes."
  (pcase type
    ('note 'primary)
    ('info 'primary)
    ('tip 'success)
    ('important 'important)
    ('warning 'warning)
    ('caution 'danger)
    ('danger 'danger)
    (_ 'neutral)))

(defconst etaf-md--callout-titles
  '((note . "Note") (info . "Info") (tip . "Tip") (important . "Important")
    (warning . "Warning") (caution . "Caution") (danger . "Danger"))
  "The fixed title each callout name draws when the document gives none.")

(defconst etaf-md--callout-attrs
  '((title             :type string  :doc "提示块的标题，省略用固定标题")
    (collapsible       :type boolean :default nil :doc "允许收起")
    (open              :type boolean :default t   :doc "收起时默认展开")
    (background        :type surface :default quote :doc "底色")
    (border-left-width :type length :default "1ch" :doc "左侧竖条宽度"))
  "Attributes every callout name shares.")

(defun etaf-md--toggle-line (label color command)
  "Return LABEL painted in COLOR as a focusable disclosure line.
COMMAND runs when the line is activated."
  (etaf-node 'box
             (list :color color :font-weight 'bold :on-press command)
             (list (etaf-node 'text nil (list label)))))

(defun etaf-md--callout-open-p (env)
  "Return non-nil when ENV's callout shows its body."
  (if (etaf-md-attr env :collapsible)
      (etaf-md-block-state env :open (etaf-md-attr env :open))
    t))

(defun etaf-md--callout-view (env)
  "Paint a callout; the five names share this view."
  (let* ((accent (etaf-md--callout-accent (etaf-md-type env)))
         (title (or (etaf-md-attr env :title)
                    (alist-get (etaf-md-type env) etaf-md--callout-titles)))
         (open (etaf-md--callout-open-p env))
         (collapsible (etaf-md-attr env :collapsible)))
    (etaf-node
     'box
     (list :width 'stretch
           :padding '((lh 1) (ch 2))
           :background-color (etaf-md-surface env (etaf-md-attr env :background))
           :border-top (etaf-md--hairline env)
           :border-right (etaf-md--hairline env)
           :border-bottom (etaf-md--hairline env)
           :border-left (list (etaf-md-attr env :border-left-width)
                              'solid (etaf-md-accent env accent)))
     (append
      (list
       (if collapsible
           (etaf-md--toggle-line
            (concat (if open "[-] " "[+] ") title)
            (etaf-md-accent env accent)
            (lambda () (etaf-md-set-block-state env :open (not open))))
         (etaf-node 'text (list :color (etaf-md-accent env accent)
                                :font-weight 'bold)
                    (list title))))
      (when open (list (etaf-md-content env)))))))

(dolist (type '(note info tip important warning caution danger))
  (etaf-md--define-shipped type
    :name (symbol-name type)
    :summary "提示块，一个名字一个固定强调色"
    :attrs etaf-md--callout-attrs
    :view #'etaf-md--callout-view))

;;; A single fold and the alignment containers

(etaf-md--define-shipped 'details
  :name "details"
  :summary "一整块的折叠区，默认收起"
  :attrs '((title :type string  :doc "收起时的标题")
           (open  :type boolean :default nil :doc "默认展开"))
  :view
  (lambda (env)
    (let* ((block (etaf-md--block-identity env))
           (title (or (etaf-md-attr env :title) "详情"))
           (open (etaf-md-block-state env :open (etaf-md-attr env :open))))
      (etaf-view
        (etaf-accordion
         :items (list (list :key 0
                            :ref (intern (format "etaf-md-details-%s" block))
                            :label title
                            :content (lambda () (etaf-md-content env))))
         :open (when open '(0))
         :multiple t
         :on-toggle (lambda (opened)
                      (etaf-md-set-block-state env :open opened)))))))

(defun etaf-md--align-view (env)
  "Paint ENV's body with the alignment its own container name asks for."
  (etaf-view
    (box :width 'stretch :text-align (etaf-md-type env)
      (expr (etaf-md-content env)))))

(dolist (type '(left center right justify))
  (etaf-md--define-shipped type
    :name (symbol-name type)
    :summary "把正文按这个方向对齐"
    :view #'etaf-md--align-view))

;;; Sequences

(defun etaf-md--steps-items (env)
  "Return ENV's steps as `etaf-steps' items.
Plume writes the steps as an ordered list; a document may also write
`:step' blocks, each with its own body.  Both forms reach the same component."
  (let ((children (etaf-md-children env)))
    (if (and (= 1 (length children))
             (eq (etaf-md-node-type (car children)) 'list))
        (seq-map-indexed
         (lambda (item index)
           (list :key index
                 :label (or (etaf-md-attr env :text item) "")))
         (etaf-md-children env (car children)))
      (seq-map-indexed
       (lambda (step index)
         (list :key index
               :label (or (etaf-md-attr env :title step) "")
               :content (lambda () (etaf-md--child-view env step))))
       children))))

(etaf-md--define-shipped 'steps
  :name "steps"
  :summary "有序步骤，每步带正文"
  :attrs '((start      :type number :default 1 :integer t :min 0 :doc "起始编号")
           (list-style :type enum   :one-of (decimal bullet none)
                       :default decimal :doc "记号"))
  :accepts '((step :attrs ((title :type string :required t :doc "步骤标题")))
             (list :attrs nil))
  :view (lambda (env)
          (etaf-view
           (etaf-steps
            :orientation 'vertical
            :start (etaf-md-attr env :start)
            :list-style (etaf-md-attr env :list-style)
            :current 0
            :items (etaf-md--steps-items env)))))

(etaf-md--define-shipped 'timeline
  :name "timeline"
  :summary "按时间排的事件，每条带正文"
  :attrs '((list-style :type enum :one-of (decimal bullet none)
                       :default bullet :doc "记号的样式")
           (start      :type number :default 1 :integer t :min 0 :doc "第一项的序号"))
  :accepts '((event :attrs ((title  :type string :required t :doc "标题")
                            (time   :type string :doc "时间文字")
                            (status :type enum :one-of (success warning danger info)
                                    :doc "状态，决定圆点颜色并画成一个徽标"))))
  :view (lambda (env)
          (etaf-view
           (etaf-timeline
            :list-style (etaf-md-attr env :list-style)
            :start (etaf-md-attr env :start)
            :items (seq-map-indexed
                    (lambda (event index)
                      (list :key index
                            :title (or (etaf-md-attr env :title event) "")
                            :time (etaf-md-attr env :time event)
                            :status (when-let* ((status (etaf-md-attr env :status event)))
                                      (list :text (pcase status
                                                    ('success "成功")
                                                    ('warning "警告")
                                                    ('danger "错误")
                                                    (_ "说明"))
                                            :variant status))
                            :content (lambda () (etaf-md--child-view env event))))
                    (etaf-md-children env))))))

(etaf-md--define-shipped 'stats
  :name "stats"
  :summary "一排数字，窄窗换行"
  :attrs '((columns :type number :default 3 :min 1 :max 6 :integer t
             :doc "一行几个"))
  :accepts '((stat :attrs ((title :type string :required t :doc "说明文字")
                           (value :type string :required t :doc "数字文本"))))
  :view (lambda (env)
          (let ((per (max 1 (etaf-md-attr env :columns))))
            (etaf-node
             'column (list :width 'stretch :item-gap '(lh 1))
             (mapcar
              (lambda (row)
                (etaf-node
                 'flex
                 (list :width 'stretch :gap (list '(lh 1) '(ch 3))
                       :align-items 'start)
                 (mapcar
                  (lambda (stat)
                    (etaf-node
                     'column (list :width 'stretch :flex-grow 1
                                  :item-gap '(lh 0))
                     (list (etaf-node
                            'etaf-statistic
                            (list :label (etaf-md-attr env :title stat)
                                  :value (etaf-md-attr env :value stat))
                            nil))))
                  row)))
              (seq-partition (etaf-md-children env) per))))))

(defun etaf-md--field-row (env pair width separator)
  "Return one field row: the name in WIDTH, then SEPARATOR and the value."
  (etaf-node
   'flex (list :width 'stretch :gap '((lh 0) (ch 0))
               :padding '((lh 0) (ch 1))
               :border-bottom (etaf-md--hairline env))
   (list
    (etaf-node 'box (list :width width :text-align 'right
                          :color (etaf-md-accent env 'neutral))
               (list (etaf-node 'text nil
                                (list (concat (car pair) separator)))))
    (etaf-node 'box (list :width 'stretch)
               (list (etaf-node 'text nil (list (cdr pair))))))))

(defun etaf-md--field-chip (env text variant)
  "Return TEXT as a small filled chip in VARIANT's palette pair.
A field's state words are badges, not prose: a fill keeps them apart from the
description without adding a border or a second row."
  (let* ((palette (etaf-md-env-palette env))
         (fill (etaf-md--palette-value
                palette
                (pcase variant
                  ('warning :warn-soft)
                  ('danger :danger-soft)
                  ('info :accent-soft)
                  (_ :panel2)))))
    (etaf-node 'text
               (list :background-color fill
                     :color (or (etaf-md--palette-value palette :ink)
                                (etaf-md--muted env))
                     :font-weight 'bold)
               (list (format " %s " text)))))

(defun etaf-md--field-state-chips (env)
  "Return the chips a field's required, deprecated and experimental flags ask for."
  (let ((required (etaf-md-attr env :required))
        (deprecated (etaf-md-attr env :deprecated))
        (experimental (etaf-md-attr env :experimental))
        (chips nil))
    (when required
      (push (etaf-md--field-chip env "必填" 'warning) chips))
    (when deprecated
      (push (etaf-md--field-chip env
                                 (if (string-empty-p deprecated)
                                     "已弃用"
                                   (format "已弃用 %s" deprecated))
                                 'danger)
            chips))
    (when experimental
      (push (etaf-md--field-chip env
                                 (if (string-empty-p experimental)
                                     "实验性"
                                   (format "实验性 %s" experimental))
                                 'info)
            chips))
    (nreverse chips)))

(defun etaf-md--field-card (env)
  "Paint ENV as one parameter card: name, state, type, default, description.
The attribute form describes a single named value, which is what an API page
repeats; the list form below still describes a whole set of facts."
  (let* ((name (etaf-md-attr env :name))
         (type (etaf-md-attr env :type))
         (type-link (etaf-md-attr env :type-link))
         (default (etaf-md-attr env :default))
         (since (etaf-md-attr env :since))
         (enum (etaf-md-attr env :enum))
         (unit (etaf-md-attr env :unit))
         (format-value (etaf-md-attr env :format))
         (constraint (etaf-md-attr env :constraint))
         (muted (etaf-md--muted env))
         (name-row
          (etaf-node 'flex (list :width 'stretch :column-gap '(ch 1))
                     (cons (etaf-node 'text (list :font-weight 'bold)
                                      (list name))
                           (etaf-md--field-state-chips env))))
         (type-node
          (when type
            (etaf-node 'text
                       (list :color (etaf-md-accent env 'primary)
                             :role (and type-link 'link)
                             :tab-index (and type-link 0)
                             :on-press (when type-link
                                         (lambda ()
                                           (etaf-md-follow-link env type-link))))
                       (list type))))
         (default-node
          (when default
            (etaf-node 'text (list :color muted)
                       (list (format "默认 %s" default)))))
         (since-node
          (when since
            (etaf-node 'text (list :color muted)
                       (list (format "自 %s" since)))))
         (meta-row
          (when (or type-node default-node since-node)
            (etaf-node 'flex (list :width 'stretch :column-gap '(ch 2))
                       (delq nil (list type-node default-node since-node)))))
         (extras
          (delq nil
                (list (when enum
                        (format "可选值 %s"
                                (string-join
                                 (split-string enum "[|,]" t "[ \\t]+") " / ")))
                      (when unit (format "单位 %s" unit))
                      (when format-value (format "格式 %s" format-value))
                      (when constraint (format "约束 %s" constraint)))))
         (extra-row
          (when extras
            (etaf-node 'text (list :color muted)
                       (list (string-join extras "    ")))))
         (body (when (etaf-md-children env)
                 (etaf-md-content env)))
         (blank (etaf-node 'text nil (list " "))))
    (etaf-node
     'column
     (list :width 'stretch :item-gap '(lh 0)
           :padding-inline '(ch 1)
           :border-left (etaf-md--hairline env))
     ;; One blank row separates the metadata from the description and the
     ;; description from the notes, the way a heading breathes above its body.
     (delq nil (list name-row meta-row
                     (when body blank) body
                     (when (and body extra-row) blank)
                     extra-row)))))

(defun etaf-md--field-pair (env row)
  "Return ROW's name and value as one cons."
  (let ((text (or (etaf-md-attr env :text row) "")))
    (if (string-match "[：:]" text)
        (cons (string-trim (substring text 0 (match-beginning 0)))
              (string-trim (substring text (match-end 0))))
      (cons (string-trim text) ""))))

(defun etaf-md--field-list (env)
  "Paint ENV's list body as name and value rows."
  (let* ((list-node (car (etaf-md-children env)))
         (rows (and list-node (etaf-md-children env list-node)))
         (pairs (mapcar (lambda (row) (etaf-md--field-pair env row))
                        rows))
         (separator (if (eq (etaf-md-attr env :separator) 'none)
                        "  " "："))
         (width (or (etaf-md-attr env :label-width)
                    (list 'ch
                          (+ (string-width separator)
                             (max 2 (apply #'max
                                           (mapcar (lambda (pair)
                                                     (string-width (car pair)))
                                                   pairs))))))))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 0))
     (mapcar (lambda (pair)
               (etaf-md--field-row env pair width separator))
             pairs))))

(etaf-md--define-shipped 'field
  :name "field"
  :summary "一个参数的说明卡，或一张名称与值的字段表"
  :attrs '((name         :type string  :doc "参数名；写了就画成参数卡")
           (type         :type string  :doc "类型注解")
           (type-link    :type string  :doc "类型的链接地址")
           (default      :type string  :doc "默认值")
           (required     :type boolean :default nil :doc "必填")
           (deprecated   :type string  :doc "弃用说明，写了显示弃用徽标")
           (experimental :type string  :doc "实验性说明，写了显示实验徽标")
           (enum         :type string  :doc "可选值，用 | 或逗号分隔")
           (unit         :type string  :doc "单位")
           (format       :type string  :doc "格式")
           (constraint   :type string  :doc "约束")
           (since        :type string  :doc "引入版本")
           (label-width  :type length  :doc "名称列宽度，省略按最长的名称算")
           (separator    :type enum :one-of (colon none)
                         :default colon :doc "名称与值的分隔"))
  :accepts '((list :attrs nil))
  :view (lambda (env)
          (if (etaf-md-attr env :name)
              (etaf-md--field-card env)
            (etaf-md--field-list env))))

(defun etaf-md--tree-entry-info (text)
  "Return (NAME COMMENT DIFF FOCUS) read from a file tree item's TEXT.
Plume writes a comment after `#', a new file as `++ name' and a removed one as
`-- name'; a name wrapped in `**' is the one the reader should look at."
  (let ((text (string-trim (or text "")))
        (diff nil)
        (focus nil))
    (when (string-match "\\`\\(++\\|--\\)[ \t]*\\(.+\\)\\'" text)
      (setq diff (if (equal (match-string 1 text) "++") 'add 'remove))
      (setq text (match-string 2 text)))
    (when (string-match "\\`\\*\\*\\(.+\\)\\*\\*\\'" text)
      (setq focus t)
      (setq text (match-string 1 text)))
    (let ((comment nil))
      (when (string-match "\\`\\(.+?\\)[ \t]+#[ \t]+\\(.+\\)\\'" text)
        (setq comment (match-string 2 text))
        (setq text (string-trim (match-string 1 text))))
      (list text comment diff focus))))

(defun etaf-md--tree-rows (env items prefix)
  "Return the painted rows of ITEMS under PREFIX.
The parser flattens a nested list into its item's children, so the rows walk
each item's own list-item children."
  (let* ((items (seq-filter (lambda (node)
                              (eq (etaf-md-node-type node) 'list-item))
                            items))
         (count (length items))
         (rows nil))
    (cl-loop for item in items
             for index from 0
             for last = (= index (1- count))
             do (let* ((info (etaf-md--tree-entry-info
                              (etaf-md-attr env :text item)))
                       (name (nth 0 info))
                       (comment (nth 1 info))
                       (diff (nth 2 info))
                       (focus (nth 3 info))
                       (guide (concat prefix (if last "└─ " "├─ ")))
                       (ink (pcase diff
                              ('add (etaf-md--palette-value
                                     (etaf-md-env-palette env) :ok))
                              ('remove (etaf-md--palette-value
                                        (etaf-md-env-palette env) :danger)))))
                  (push (etaf-node
                         'flex
                         (list :width 'stretch)
                         (delq nil
                               (list
                                (etaf-node 'text
                                           (list :font-family
                                                 (face-attribute 'fixed-pitch :family nil t)
                                                 :color (or ink (etaf-md--muted env))
                                                 :font-weight (and focus 'bold))
                                           (list (concat guide name
                                                         (when comment "  "))))
                                (when comment
                                  (etaf-node 'text
                                             (list :color (etaf-md--muted env))
                                             (list comment))))))
                        rows)
                  (dolist (row (etaf-md--tree-rows
                                env (etaf-md-children env item)
                                (concat prefix (if last "   " "│  "))))
                    (push row rows))))
    (nreverse rows)))

(etaf-md--define-shipped 'file-tree
  :name "file-tree"
  :summary "带树线的目录树"
  :attrs '((title :type string :doc "树上方一行标题")
           (lines :type boolean :default t :doc "画不画树线")
           (icon  :type enum :one-of (simple colored)
                  :doc "plume 的图标样式，文字页面里不画图标，只接受这个参数"))
  :accepts '((list :attrs nil))
  :view (lambda (env)
          (let ((list-node (car (etaf-md-children env))))
            (etaf-node
             'box
             (list :width 'stretch
                   :padding '((lh 1) (ch 2))
                   :background-color (etaf-md-surface env 'raised)
                   :border (etaf-md--hairline env))
             (list
              (etaf-node
               'column (list :width 'stretch :item-gap '(lh 0))
               (append
                (when-let* ((title (etaf-md-attr env :title)))
                  (list (etaf-node 'text (list :font-weight 'bold)
                                   (list title))))
                (etaf-md--tree-rows env (etaf-md-children env list-node) ""))))))))

;;; Chat

(defun etaf-md--chat-marker (node)
  "Return (KIND . TEXT) when NODE is a chat marker paragraph.
Plume writes a sender as `{name}' and a date as `{:date}'; `{.}' means the
reader themself.  Anything else is message content."
  (when (eq (etaf-md-node-type node) 'paragraph)
    (let ((text (string-trim (etaf-md--inline-text (etaf-md-node-block node)))))
      (cond
       ((string-match "\\`{:\\(.+\\)}\\'" text) (cons 'date (match-string 1 text)))
       ((string-match "\\`{\\(.+\\)}\\'" text) (cons 'sender (match-string 1 text)))))))

(defun etaf-md--chat-finish (current)
  "Return CURRENT as a finished chat message.
CURRENT is (NAME SELF BLOCKS...); the blocks read in the order they appear."
  (list :name (nth 0 current)
        :self (nth 1 current)
        :blocks (nreverse (nth 2 current))))

(defun etaf-md--chat-messages (env)
  "Return ENV's children grouped into chat messages.
The result is a list of (KIND . PAYLOAD): `date' carries its text and
`message' carries a plist of :name, :self and :blocks."
  (let ((items nil)
        (current nil))
    (dolist (child (etaf-md-children env))
      (let ((marker (etaf-md--chat-marker child)))
        (pcase (car-safe marker)
          ('date
           (when current
             (push (cons 'message (etaf-md--chat-finish current)) items))
           (setq current nil)
           (push (cons 'date (cdr marker)) items))
          ('sender
           (when current
             (push (cons 'message (etaf-md--chat-finish current)) items))
           (let ((name (cdr marker)))
             (setq current (list (if (equal name ".") nil name)
                                 (equal name ".")
                                 nil))))
          (_ (when current
               (setcar (nthcdr 2 current)
                       (cons child (nth 2 current))))))))
    (when current
      (push (cons 'message (etaf-md--chat-finish current)) items))
    (nreverse items)))

(defun etaf-md--chat-date-view (env text)
  "Return the date row TEXT of a chat in ENV."
  (etaf-node 'box
             (list :width 'stretch :text-align 'center)
             (list (etaf-node 'text
                              (list :color (etaf-md--muted env))
                              (list text)))))

(defun etaf-md--chat-message-view (env message)
  "Return MESSAGE of a chat painted in ENV.
The name sits above the words; what the reader wrote is aligned right and
carries no name."
  (let ((name (plist-get message :name))
        (self (plist-get message :self)))
    (etaf-node
     'box
     (list :width 'stretch :text-align (if self 'right 'left))
     (list
      (etaf-node
       'column
       (list :width 'stretch :item-gap '(lh 0))
       (append
        (when name
          (list (etaf-node 'text
                           (list :color (etaf-md-accent env 'neutral)
                                 :font-weight 'bold)
                           (list name))))
        (list (etaf-md-render env (plist-get message :blocks)))))))))

(etaf-md--define-shipped 'chat
  :name "chat"
  :summary "一问一答的对话，不画气泡"
  :attrs '((title :type string :doc "对话上方的标题"))
  :view (lambda (env)
          (etaf-view
           (column :width 'stretch :item-gap '(lh 0)
             (expr (when-let* ((title (etaf-md-attr env :title)))
                     (etaf-view
                      (box :width 'stretch :padding-bottom '(lh 1)
                        (etaf-label :text title :variant 'strong)))))
             (expr
              (etaf-node
               'column
               (list :width 'stretch :item-gap '(lh 1))
               (mapcar
                (lambda (item)
                  (if (eq (car item) 'date)
                      (etaf-md--chat-date-view env (cdr item))
                    (etaf-md--chat-message-view env (cdr item))))
                (etaf-md--chat-messages env))))))))

;;; Interaction

(defun etaf-md--tab-language (env tab)
  "Return TAB's first fenced language, or nil."
  (let ((code (seq-find (lambda (child)
                          (eq (etaf-md-node-type child) 'code-block))
                        (etaf-md-children env tab))))
    (and code (etaf-md-attr env :language code))))

(defun etaf-md--tab-label (env tab)
  "Return TAB's label: its title, or its fenced language."
  (or (etaf-md-attr env :title tab)
      (etaf-md--tab-language env tab)
      ""))

(defun etaf-md--tabs-view (env &optional page-view label-fn)
  "Paint a tab strip and the selected page; both tab styles share it.
PAGE-VIEW, when given, paints the selected page's body instead of the
default child view.  LABEL-FN, when given, names each tab from the child,
its index and the count instead of the title-or-language default."
  (let* ((tabs (etaf-md-children env))
         (count (length tabs))
         (initial (or (cl-position-if
                       (lambda (tab) (etaf-md-attr env :selected tab))
                       tabs)
                      0))
         (active (min (or (etaf-md-block-state env :active initial) 0)
                      (max 0 (1- count))))
         (selected (nth active tabs)))
    (etaf-view
     ;; The strip is a bar, not a panel: its own rule separates it from the
     ;; page, and a code page keeps its code block's frame as the only frame.
     (column :width 'stretch :item-gap '(lh 0)
             :border (etaf-md--hairline env)
       (etaf-tabs
        :items (seq-map-indexed
                (lambda (tab index)
                  (list :key index
                        :label (if label-fn
                                   (funcall label-fn tab index count)
                                 (etaf-md--tab-label env tab))))
                tabs)
        :active active
        :framed nil
        :on-change (lambda (key) (etaf-md-set-block-state env :active key)))
       (box :width 'stretch
            :padding '((lh 1) (ch 2))
            :border-top (etaf-md--hairline env)
         (expr (when selected
                 (if page-view
                     (funcall page-view env selected)
                   (etaf-md--child-view env selected)))))))))

(defun etaf-md--code-tabs-view (env)
  "Paint a code tab strip and the selected page without a repeated language."
  (etaf-md--tabs-view env #'etaf-md--code-tab-page))

(defun etaf-md--code-tab-page (env page)
  "Paint PAGE's body in ENV the way a code tab shows it.
The strip already names the page's language, so a fence that repeats it in a
header strip inside the page reads as a second header.  The code keeps its
frame and its colours; only the language row is left out."
  (etaf-view
   (column :width 'stretch :item-gap '(lh 0)
    (expr
     (mapcar
      (lambda (child)
        (if (eq (etaf-md-node-type child) 'code-block)
            (etaf-ui-markdown-view-block
             (plist-put (copy-sequence (etaf-md-node-block child)) :header nil)
             (list :theme (etaf-md-env-theme env)
                   :palette (etaf-md-env-palette env)
                   :width (etaf-md-env-width env)))
          (etaf-md--paint child env)))
      (etaf-md-children env page))))))

(etaf-md--define-shipped 'tabs
  :name "tabs"
  :summary "标签页，只画选中那一页的正文"
  :accepts '((tab :attrs ((title    :type string  :required t :doc "标签文字")
                          (selected :type boolean :default nil :doc "打开时选中这一页"))))
  :child-syntax 'markers
  :view #'etaf-md--tabs-view)

(etaf-md--define-shipped 'code-tabs
  :name "code-tabs"
  :summary "代码标签页，标题省略时用围栏语言名"
  :accepts '((tab :attrs ((title    :type string :doc "标签文字，省略取围栏语言")
                          (selected :type boolean :default nil :doc "打开时选中这一页"))))
  :child-syntax 'markers
  :view #'etaf-md--code-tabs-view)

(etaf-md--define-shipped 'accordion
  :name "accordion"
  :summary "折叠组，默认同时只开一块"
  :attrs '((expand    :type boolean :default nil :doc "打开时所有块都展开")
           (accordion :type boolean :default t   :doc "同时只开一块；false 可以开多块"))
  :accepts '((collapse :attrs ((title :type string :required t :doc "收起时的标题")
                               (open  :type boolean :default nil :doc "默认展开")
                               (index :type number :integer t :min 0
                                      :doc "显示顺序，省略按书写顺序"))))
  :view (lambda (env)
          (let* ((block (etaf-md--block-identity env))
                 (expand (etaf-md-attr env :expand))
                 ;; A document may number its folds; the display order follows
                 ;; those numbers and unnumbered folds keep their own order.
                 (collapses (seq-sort-by
                             (lambda (collapse)
                               (or (etaf-md-attr env :index collapse)
                                   most-positive-fixnum))
                             #'<
                             (etaf-md-children env)))
                 (count (length collapses))
                 (all (number-sequence 0 (1- count))))
            (etaf-view
             (etaf-accordion
              :items (seq-map-indexed
                      (lambda (collapse index)
                        (list :key index
                              :ref (intern (format "etaf-md-accordion-%s-%d"
                                                   block index))
                              :label (or (etaf-md-attr env :title collapse) "")
                              :content (lambda () (etaf-md--child-view env collapse))))
                      collapses)
              :open (or (etaf-md-block-state env :open)
                        (if expand
                            all
                          (seq-filter
                           (lambda (index)
                             (etaf-md-attr env :open (nth index collapses)))
                           all)))
              ;; Opening every fold needs the group to allow more than one.
              :multiple (or expand (not (etaf-md-attr env :accordion)))
              :on-toggle (lambda (open)
                           (etaf-md-set-block-state env :open open)))))))

;;; Edge containers

(defun etaf-md--edge-accent (env)
  "Return ENV's accent colour, or nil when it asks for the plain rule."
  (let ((accent (etaf-md-attr env :accent)))
    (unless (or (null accent) (eq accent 'neutral))
      (etaf-md-accent env accent))))

(defun etaf-md--panel-view (env)
  "Paint ENV's panel: its title and status sit on the top rule."
  (etaf-view
   (etaf-edge-panel :title (etaf-md-attr env :title)
                    :status (etaf-md-attr env :status)
                    :variant (etaf-md-attr env :variant)
                    :focus (etaf-md-attr env :focus)
                    :accent (etaf-md--edge-accent env)
                    :background (etaf-md-surface env 'raised)
                    :width (or (etaf-md-attr env :width) 'stretch)
                    :margin-top (etaf-md--vertical-length
                                 (etaf-md-attr env :margin-top))
     (expr (etaf-md-content env)))))

(defun etaf-md--tab-panel (env)
  "Return ENV's tabs, the active index and the table of tab nodes."
  (let* ((tabs (etaf-md-children env))
         (count (length tabs))
         (initial (or (cl-position-if
                       (lambda (tab) (etaf-md-attr env :selected tab))
                       tabs)
                      0))
         (active (min (or (etaf-md-block-state env :active initial) 0)
                      (max 0 (1- count)))))
    (list tabs active (nth active tabs))))

(defun etaf-md--tab-panel-view (env)
  "Paint ENV's tab panel: the tabs share the pane's top rule."
  (pcase-let* ((`(,tabs ,active ,selected) (etaf-md--tab-panel env)))
    (etaf-view
     (etaf-edge-tabs
      :items (seq-map-indexed
              (lambda (tab index)
                (list :key index :label (etaf-md--tab-label env tab)))
              tabs)
      :active active
      :accent (etaf-md--edge-accent env)
      :width (or (etaf-md-attr env :width) 'stretch)
      :margin-top (etaf-md--vertical-length (etaf-md-attr env :margin-top))
      :on-change (lambda (key) (etaf-md-set-block-state env :active key))
      (expr (when selected (etaf-md--child-view env selected)))))))

(defun etaf-md--form-rows (env)
  "Return ENV's list items as (LABEL . VALUE) pairs.
A row is written `名称：值'; the first colon in either width splits it, and a
row without one is a label with an empty value."
  (let* ((list-node (car (etaf-md-children env)))
         (items (and list-node
                     (seq-filter (lambda (node)
                                   (eq (etaf-md-node-type node) 'list-item))
                                 (etaf-md-children env list-node)))))
    (mapcar
     (lambda (item)
       (let ((text (or (etaf-md-attr env :text item) "")))
         (if (string-match "\\`\\([^：:]+\\)[：:]\\s-*\\(.*\\)\\'" text)
             (cons (string-trim (match-string 1 text))
                   (string-trim (match-string 2 text)))
           (cons (string-trim text) ""))))
     items)))

(defun etaf-md--form-view (env)
  "Paint ENV's form rows as labelled values with a rule under each."
  (etaf-view
   (column :width (or (etaf-md-attr env :width) 'stretch) :item-gap '(lh 1)
     (expr (mapcar (lambda (row)
                     (etaf-view
                      (etaf-underline-field
                       :label (car row) :value (cdr row))))
                   (etaf-md--form-rows env))))))

(etaf-md--define-shipped 'panel
  :name "panel"
  :summary "标题与状态都写在顶边上的面板"
  :attrs '((title   :type string :doc "面板标题，写在顶边上")
           (status  :type string :doc "顶边右端的说明")
           (variant :type enum :one-of (default flat) :default default
                    :doc "flat 只留框线，不铺底色")
           (focus   :type boolean :default nil :doc "用强调色画框线")
           (accent  :type accent :default neutral
                    :doc "框线与标题的颜色；neutral 用页面描边色")
           (width   :type length :doc "面板宽度，省略铺满一行")
           (margin-top :type length :default "1lh" :doc "与上一块的距离"))
  :view #'etaf-md--panel-view)

(etaf-md--define-shipped 'tab-panel
  :name "tab-panel"
  :summary "标签坐在面板顶边上的标签页"
  :attrs '((margin-top :type length :default "1lh" :doc "与上一块的距离")
           (width   :type length :doc "面板宽度，省略铺满一行")
           (accent :type accent :default neutral
                   :doc "框线与选中标签的颜色；neutral 用页面描边色"))
  :accepts '((tab :attrs ((title    :type string  :required t :doc "标签文字")
                          (selected :type boolean :default nil :doc "打开时选中这一页"))))
  :child-syntax 'markers
  :view #'etaf-md--tab-panel-view)

(etaf-md--define-shipped 'form
  :name "form"
  :summary "标签加下划线的表单行"
  :attrs '((width :type length :doc "表单宽度，省略铺满一行"))
  :accepts '((list :attrs nil))
  :view #'etaf-md--form-view)

;;; Pane furniture

(defun etaf-md--log-rows (env)
  "Return ENV's list items as log entries.
A row is written `09:41:14 WARN message': the first word is the time, the
second the level, and the rest the message; a row without a level keeps its
whole text as the message."
  (let* ((list-node (car (etaf-md-children env)))
         (items (and list-node
                     (seq-filter (lambda (node)
                                   (eq (etaf-md-node-type node) 'list-item))
                                 (etaf-md-children env list-node)))))
    (mapcar
     (lambda (item)
       (let ((text (or (etaf-md-attr env :text item) "")))
         (if (string-match "\\`\\([^ \t]+\\)[ \t]+\\([A-Za-z]+\\)[ \t]+\\(.*\\)\\'" text)
             (list :time (match-string 1 text)
                   :level (match-string 2 text)
                   :message (match-string 3 text))
           (list :time "" :level "" :message text))))
     items)))

(defun etaf-md--log-view (env)
  "Paint ENV's list items as a log."
  (etaf-view
   (etaf-log :rows (etaf-md--log-rows env))))

(defun etaf-md--status-keys (text)
  "Return TEXT's `key:label' pairs as a list."
  (mapcar (lambda (part)
            (let ((colon (string-search ":" part)))
              (if colon
                  (cons (substring part 0 colon)
                        (substring part (1+ colon)))
                (cons part ""))))
          (split-string (or text "") "[,，]" t)))

(defun etaf-md--status-view (env)
  "Paint ENV's status bar."
  (etaf-view
   (etaf-status-bar :mode (etaf-md-attr env :mode)
                    :keys (etaf-md--status-keys (etaf-md-attr env :keys))
                    :note (etaf-md-attr env :note))))

(defun etaf-md--chart-values (text)
  "Return the numbers TEXT writes, separated by spaces or commas."
  (let (values)
    (dolist (token (split-string (or text "") "[ \t,]+" t))
      (when (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" token)
        (push (string-to-number token) values)))
    (nreverse values)))

(defun etaf-md--chart-view (env)
  "Paint ENV's block chart."
  (let ((values (etaf-md--chart-values (etaf-md-attr env :values))))
    (unless (> (length values) 1)
      (signal 'etaf-md-node-error
              (list "chart: values needs at least two numbers")))
    (etaf-view
     (etaf-braille-chart :values values
                         :width (etaf-md-attr env :width)
                         :height (etaf-md-attr env :height)
                         :label (etaf-md-attr env :label)))))

(etaf-md--define-shipped 'log
  :name "log"
  :summary "按级别上色的日志，不画框"
  :accepts '((list :attrs nil))
  :view #'etaf-md--log-view)

(etaf-md--define-shipped 'statusbar
  :name "statusbar"
  :summary "一行状态栏：模式、按键提示与右端说明"
  :attrs '((mode :type string :doc "当前模式，画成一个填色的小块")
           (keys :type string :doc "按键提示，写成 key:说明，逗号分隔")
           (note :type string :doc "右端的说明"))
  :view #'etaf-md--status-view)

(etaf-md--define-shipped 'chart
  :name "chart"
  :summary "盲文点阵画的折线图"
  :attrs '((values :type string :required t :doc "用空格或逗号分隔的数字")
           (width  :type number :default 40 :integer t :min 1 :doc "宽度，单位格")
           (height :type number :default 6  :integer t :min 1 :doc "高度，单位行")
           (label  :type string :doc "图表上方的标题"))
  :view #'etaf-md--chart-view)

;;; Documents

(etaf-md--define-shipped 'table
  :name "table"
  :summary "带标题与行列高亮的表格"
  :attrs '((title             :type string :doc "表格上方一行标题")
           (highlight-rows    :type string :doc "高亮的行号，空格分隔")
           (highlight-columns :type string :doc "高亮的列号，空格分隔")
           (highlight-cells   :type string :doc "高亮的单元格，写成 行:列，空格分隔")
           (align             :type enum :one-of (left center right)
                              :doc "整张表的对齐，盖过 text-align")
           (copy              :type boolean :default nil :doc "在标题下画一个复制整表的一行")
           (highlight         :type accent :default warning :doc "高亮用哪个强调值")
           (background        :type surface :default page :doc "表格底色")
           (color             :type color :default "foreground" :doc "表格文字色")
           (header-background :type surface :default table-header :doc "表头底")
           (stripe-background :type surface :default table-stripe :doc "条纹底")
           (text-align        :type align :default start :doc "单元格文字位置")
           (margin-top        :type length :default "0ch" :doc "与上一块的距离")
           (margin-bottom     :type length :default "0ch" :doc "与下一块的距离"))
  :accepts '((table-block :attrs nil))
  :view (lambda (env)
          (let* ((table-node (car (etaf-md-children env)))
                 (rows (and table-node (etaf-md-children env table-node))))
            (if (null rows)
                (etaf-md--child-view env table-node)
              (etaf-md--table-view env rows)))))

(defun etaf-md--table-cells (text)
  "Return the `row:column' pairs written in TEXT as conses."
  (delq nil
        (mapcar (lambda (word)
                  (when (string-match "\\`\\([0-9]+\\):\\([0-9]+\\)\\'" word)
                    (cons (string-to-number (match-string 1 word))
                          (string-to-number (match-string 2 word)))))
                (split-string (or text "") "[ \t]+" t))))

(defun etaf-md--table-text (env rows)
  "Return ROWS as tab separated lines, the form a spreadsheet pastes."
  (mapconcat
   (lambda (row)
     (mapconcat (lambda (cell)
                  (or (etaf-md-attr env :text cell) ""))
                (etaf-md-children env row)
                "\t"))
   rows "\n"))

(defun etaf-md--table-view (env rows)
  "Paint ROWS of the table container in ENV."
  (let* ((first-row (car rows))
         (columns (length (etaf-md-children env first-row)))
         (hit-rows (etaf-md--number-list (etaf-md-attr env :highlight-rows)))
         (hit-columns (etaf-md--number-list
                       (etaf-md-attr env :highlight-columns)))
         (hit-cells (etaf-md--table-cells (etaf-md-attr env :highlight-cells)))
         (hit (etaf-md-accent env (etaf-md-attr env :highlight)))
         (table-align (etaf-md-attr env :align))
         (header-fill (etaf-md-surface env (etaf-md-attr env :header-background)))
         (stripe-fill (etaf-md-surface env (etaf-md-attr env :stripe-background)))
         (tracks (cl-loop for column below columns
                          collect (list 'ch
                                        (+ 4 (cl-loop
                                              for row in rows
                                              maximize
                                              (string-width
                                               (or (etaf-md-attr
                                                    env :text
                                                    (nth column
                                                         (etaf-md-children env row)))
                                                   "")))))))
         ;; The frame hugs the grid: a page-wide frame around a short grid
         ;; reads as an empty box, and the cells already carry the rules.
         (table-width (list 'ch (cl-loop for track in tracks
                                         sum (cadr track))))
         (row-views nil)
         (row-number 0))
    (dolist (row rows)
      (setq row-number (1+ row-number))
      (let ((cell-views nil)
            (column 0))
        (dolist (cell (etaf-md-children env row))
          (setq column (1+ column))
          (let ((highlighted (or (memq row-number hit-rows)
                                 (memq column hit-columns)
                                 (member (cons row-number column) hit-cells))))
            (push (etaf-node
                   'box
                   (list :width (nth (1- column) tracks)
                         :padding '((lh 0) (ch 1))
                         :overflow 'hidden
                         :wrap-mode 'word
                         :text-align (or (etaf-md-attr env :align cell)
                                         table-align
                                         (etaf-md-attr env :text-align))
                         :background-color
                         (cond ((= row-number 1) header-fill)
                               ((and stripe-fill (cl-oddp row-number))
                                stripe-fill))
                         ;; Every cell draws its own right and bottom rule,
                         ;; and the first row and column close the grid on
                         ;; the other two sides; that is one pixel between
                         ;; neighbours instead of two.
                         :border-bottom (etaf-md--hairline env)
                         :border-right (etaf-md--hairline env)
                         :border-left (and (= column 1) (etaf-md--hairline env))
                         :border-top (and (= row-number 1) (etaf-md--hairline env))
                         :color (and highlighted hit)
                         :font-weight (and (or (= row-number 1) highlighted)
                                           'bold))
                   (list (etaf-node 'text nil
                                    (list (or (etaf-md-attr env :text cell)
                                              "")))))
                  cell-views)))
        (push (etaf-node 'flex (list :width table-width)
                         (nreverse cell-views))
              row-views)))
    (etaf-node
     'column
     (list :width 'stretch
           :margin-top (etaf-md--vertical-length (etaf-md-attr env :margin-top))
           :margin-bottom (etaf-md--vertical-length (etaf-md-attr env :margin-bottom))
           :item-gap '(lh 0))
     (append
      ;; The caption and the copy line sit above the frame, the way a table
      ;; caption sits outside its grid.
      (when-let* ((title (etaf-md-attr env :title)))
        (list (etaf-node 'text (list :font-weight 'bold) (list title))
              (etaf-node 'text nil (list " "))))
      (when (etaf-md-attr env :copy)
        (let ((content (etaf-md--table-text env rows)))
          (list (etaf-node 'text
                           (list :color (etaf-md-accent env 'primary)
                                 :font-weight 'bold
                                 :role 'button :tab-index 0
                                 :help-echo "把整张表复制成制表符分隔的文本"
                                 :on-press (lambda () (kill-new content)))
                           (list "复制表格"))
                (etaf-node 'text nil (list " ")))))
      (list
       (etaf-node
        'column
        (list :width table-width
              ;; The cells own the whole grid, so the container adds no frame:
              ;; a second edge next to theirs would read as a double line.
              :background-color (etaf-md-surface env (etaf-md-attr env :background))
              :item-gap '(lh 0))
        (nreverse row-views)))))))

(etaf-md--define-shipped 'window
  :name "window"
  :summary "带标题栏的演示窗口"
  :attrs '((title      :type string  :doc "标题栏文字")
           (height     :type length  :doc "内容区高度")
           (gap        :type length  :doc "标题栏与内容之间的空行")
           (no-padding :type boolean :default nil :doc "内容区不留内边距"))
  :view (lambda (env)
          (let ((padded (not (etaf-md-attr env :no-padding)))
                (gap (etaf-md--vertical-length (etaf-md-attr env :gap))))
            (etaf-view
             (column :width 'stretch :item-gap '(lh 0)
                     :border (etaf-md--hairline env)
                     :overflow 'hidden
               ;; The title bar is the catalog's own window chrome, so the
               ;; traffic lights are the same Mac-style control the desktop
               ;; applications use instead of three look-alike glyphs.
               (etaf-window-chrome
                :title (or (etaf-md-attr env :title) "")
                :active t
                :show-minimize t :show-maximize t :show-close t)
               ;; GAP is space the document asked for; it belongs between the
               ;; bar and the content, not inside the content's padding.
               (box :width 'stretch
                    :margin-top gap
                    :padding (when padded '((lh 1) (ch 2)))
                    :height (etaf-md-attr env :height)
                    :overflow (and (etaf-md-attr env :height) 'hidden)
                 (expr (etaf-md-content env))))))))


;;; Text blocks

(etaf-md--define-shipped 'list
  :summary "列表；子节点是它的每一项")
(etaf-md--define-shipped 'list-item
  :summary "列表的一项，容器可读它的行文字与层级"
  :derived '((text  :type string :doc "这一项的纯文本")
             (depth :type number :integer t :doc "从零开始的嵌套层数")))
(etaf-md--define-shipped 'table-block
  :summary "表格块；子节点是它的每一行")
(etaf-md--define-shipped 'table-row
  :summary "表格的一行；子节点是它的单元格"
  :derived '((header :type boolean :doc "是不是表头行")))
(etaf-md--define-shipped 'cell
  :summary "表格的一个单元格，容器可读它的文字与对齐"
  :derived '((text  :type string :doc "单元格的纯文本")
             (align :type align  :doc "这一列的对齐")))
(etaf-md--define-shipped 'code-block
  :summary "围栏代码；语言名供代码标签页取用"
  :derived '((language :type string :doc "围栏的语言名")))

;; The site component catalog builds on the prose definitions above and
;; registers before reader definitions, so a document can still override one.
(require 'etaf-md-components)

;; Reader definitions load after the shipped ones, so :extends can rely
;; on them and a plain definition may still add a new type.
(etaf-md-load-node-directory)

(provide 'etaf-md-nodes)
;;; etaf-md-nodes.el ends here
