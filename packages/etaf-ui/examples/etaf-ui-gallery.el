;;; -*- lexical-binding: t; -*-
;;; etaf-ui-gallery.el --- Browse and operate the complete ETAF UI catalog

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Open with M-x etaf-ui-gallery-open.  Each specimen uses the public catalog;
;; its displayed/copyable example is generated from the same View and bindings.
;; State belongs to this mount, survives browsing and is never written to disk.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pp)
(require 'etaf-ui)

;; Emacs 29's pretty printer ignores this newer dynamic customization and
;; uses its own formatter. Declaring it keeps the binding special on both.
(defvar pp-default-function)
(declare-function pp-fill "pp" (beg &optional end))

(defconst etaf-ui-gallery--palette
  '(:gallery-bg ("#F6F7FB" . "#141923")
    :gallery-sidebar ("#F0F2F8" . "#171D28")
    :gallery-code ("#F7F8FC" . "#202736")
    :ui-fg ("#252C42" . "#E4E8F3") :ui-bg ("#FFFFFF" . "#1C2330")
    :ui-border ("#DBE0ED" . "#343E52") :ui-muted-fg ("#66718B" . "#A1ADC4")
    :ui-accent ("#6553CA" . "#B7A5FF") :ui-accent-fg ("#FFFFFF" . "#211B37")
    :ui-accent-soft-bg ("#E9E5FC" . "#36304E")
    :ui-button-primary-bg ("#6553CA" . "#B7A5FF")
    :ui-button-primary-fg ("#FFFFFF" . "#211B37")
    :ui-button-secondary-bg ("#E9E5FC" . "#36304E")
    :ui-button-secondary-fg ("#5944B0" . "#DACFFF")
    :ui-button-ghost-fg ("#6553CA" . "#B7A5FF")
    :ui-disabled-bg ("#E1E5EF" . "#2B3446")
    :ui-disabled-fg ("#738099" . "#9AA6BD")
    :ui-disabled-border ("#DBE0ED" . "#343E52")
    :ui-checkbox-enabled-fg ("#252C42" . "#E4E8F3")
    :ui-checkbox-disabled-fg ("#738099" . "#9AA6BD")
    :ui-panel-bg ("#FFFFFF" . "#1C2330") :ui-panel-fg ("#252C42" . "#E4E8F3")
    :ui-panel-border ("#DBE0ED" . "#343E52")
    :ui-table-border ("#DBE0ED" . "#343E52")
    :ui-table-selected-bg ("#E9E5FC" . "#36304E")
    :ui-table-selected-fg ("#5944B0" . "#DACFFF")
    :ui-pagination-muted-fg ("#66718B" . "#A1ADC4")
    :ui-progress-track ("#EDF0F7" . "#252E40")
    :ui-success-fg ("#26775E" . "#9ED7BD") :ui-success-bg ("#E5F3ED" . "#223C35")
    :ui-success-border ("#B7DBCA" . "#49695C")
    :ui-warning-fg ("#94641E" . "#F0CB89") :ui-warning-bg ("#FBF1DA" . "#403626")
    :ui-warning-border ("#E3CDA0" . "#6D5A39")
    :ui-danger-fg ("#AD4763" . "#EFA9BF") :ui-danger-bg ("#F9E8ED" . "#432B38")
    :ui-danger-border ("#DFBCC6" . "#74495D")
    :ui-info-fg ("#5944B0" . "#DACFFF") :ui-info-bg ("#E9E5FC" . "#36304E")
    :ui-info-border ("#CEC5EF" . "#584C7C")
    :ui-data-grid-error-fg ("#AD4763" . "#EFA9BF")
    :ui-search-bg ("#EDF0F7" . "#252E40") :ui-search-fg ("#252C42" . "#E4E8F3")
    :ui-shell-bg ("#EDF0F7" . "#252E40") :ui-shell-fg ("#252C42" . "#E4E8F3")
    :ui-shell-muted-fg ("#66718B" . "#A1ADC4")
    :ui-shell-item-fg ("#66718B" . "#A1ADC4")
    :ui-shell-item-minimized-fg ("#738099" . "#9AA6BD")
    :ui-window-bg ("#FFFFFF" . "#1C2330") :ui-window-fg ("#252C42" . "#E4E8F3")
    :ui-window-border ("#DBE0ED" . "#343E52")
    :ui-window-title-bg ("#EDF0F7" . "#252E40")
    :ui-window-title-fg ("#66718B" . "#A1ADC4")
    :ui-window-title-active-fg ("#252C42" . "#E4E8F3")
    :ui-divider-bg ("#DBE0ED" . "#343E52")
    :ui-picker-item-bg ("#F7F8FC" . "#252E40")
    :ui-picker-item-fg ("#252C42" . "#E4E8F3")
    :ui-picker-item-muted-fg ("#66718B" . "#A1ADC4")
    :ui-playing-card-back-bg "#5944B0" :ui-playing-card-back-fg "#DACFFF"
    :ui-playing-card-empty-bg ("#EDF0F7" . "#252E40")
    :ui-playing-card-empty-fg ("#66718B" . "#A1ADC4"))
  "Semantic colors shared by the shell and every catalog specimen.")

(defconst etaf-ui-gallery--sidebar-columns 160
  "Columns needed for the sidebar plus a comfortably readable main region.")

(defconst etaf-ui-gallery--groups
  '((basic "基础与操作" "Button · Label · Icon · Avatar · Kbd")
    (input "输入与选择" "TextInput · Select · Switch · Range")
    (layout "导航与结构" "Tabs · Panel · Accordion · Splitter")
    (data "数据与集合" "Table · DataGrid · Tree · Calendar")
    (feedback "状态与反馈" "Badge · Alert · Progress · Empty")
    (surface "菜单与浮层" "Dialog · Popover · Drawer · Toast")
    (desktop "窗口与工作区" "Window · Taskbar · Launcher")
    (media "媒体与网格" "MediaViewer · TileGrid · TextGrid · PlayingCard"))
  "Browsing groups, not a second supported-API inventory.")

(defmacro etaf-ui-gallery--sample (name group title description bindings view)
  "Describe NAME in GROUP with TITLE, DESCRIPTION, BINDINGS and VIEW.
Compile the live View and retain the identical source for runnable examples."
  (declare (indent 4))
  (let ((names (mapcar #'car bindings)))
    `(list :name ',name :group ',group :title ,title :description ,description
           :bindings ',bindings :form ',view
           :create (lambda ()
                     (let* ,bindings
                       (list ,@(cl-mapcan
                                (lambda (name)
                                  (list (intern (concat ":" (symbol-name name))) name))
                                names))))
           :render (lambda (state)
                     (ignore state)
                     (let ,(mapcar
                            (lambda (name)
                              `(,name (plist-get state ,(intern (concat ":" (symbol-name name))))))
                            names)
                       (ignore ,@names)
                       (etaf-view ,view))))))

(defmacro etaf-ui-gallery--window-sample (name title)
  "Describe a controlled NAME window with TITLE and public geometry Behaviors."
  `(etaf-ui-gallery--sample ,name desktop ,title
       "拖动标题或边缘；M-方向键移动，M-S-方向键缩放。"
     ((geometry (etaf-ref '(:x 0 :y 0 :width 320 :height 6)))
      (mode (etaf-ref 'normal)) (visible (etaf-ref t))
      (origin (list nil))
      (read (lambda () (copy-sequence (etaf-value geometry))))
      (write (lambda (next)
               (setf (etaf-value geometry)
                     (list :x (max 0 (min 80 (plist-get next :x)))
                           :y (max 0 (min 2 (plist-get next :y)))
                           :width (max 200 (min 400 (plist-get next :width)))
                           :height (max 4 (min 8 (plist-get next :height)))))))
      (delta (lambda (gesture)
               (let ((pixels (plist-get gesture :delta)))
                 (cons (car pixels)
                       (round (/ (float (cdr pixels))
                                 (plist-get (etaf-display-metrics) :line-height)))))))
      (start (lambda (_) (setcar origin (funcall read))))
      (cancel (lambda (_) (when (car origin) (funcall write (car origin)))))
      (move (etaf-draggable-controlled read write :axis 'both :delta delta
                                      :on-start start :on-cancel cancel))
      (resize (mapcar
               (lambda (edge)
                 (cons edge (etaf-resizable-controlled
                             read write :edges (if (eq edge 'bottom-right)
                                                   '(right bottom) (list edge))
                             :min-width 200 :max-width 400 :min-height 4 :max-height 8
                             :delta delta :on-start start :on-cancel cancel)))
               '(right bottom bottom-right))))
     (column :item-gap '(lh 1)
       (etaf-button :label "恢复窗口" :variant 'secondary
                    :on-press (lambda () (setf (etaf-value visible) t
                                               (etaf-value mode) 'normal
                                               (etaf-value geometry)
                                               '(:x 0 :y 0 :width 320 :height 6))))
       (box :height '(lh 10) :width 'stretch :overflow 'hidden
            :background-color (etaf-theme-token :gallery-code)
         (,name :visible visible
                :x (list 'px (plist-get (etaf-value geometry) :x))
                :y (list 'lh (plist-get (etaf-value geometry) :y))
                :width (list 'px (plist-get (etaf-value geometry) :width))
                :height (list 'lh (plist-get (etaf-value geometry) :height))
                ,@(when (eq name 'etaf-window)
                    '(:title "预览窗口" :mode mode :move-use move
                      :on-minimize (lambda () (setf (etaf-value mode) 'minimized))
                      :on-maximize (lambda ()
                                     (setf (etaf-value mode) 'maximized
                                           (etaf-value geometry) '(:x 0 :y 0 :width 400 :height 8)))
                      :on-restore (lambda () (setf (etaf-value mode) 'normal
                                                   (etaf-value geometry) '(:x 0 :y 0 :width 320 :height 6)))
                      :on-close (lambda () (setf (etaf-value visible) nil))))
                :resize-edges '(right bottom bottom-right) :resize-use resize
           ,@(when (eq name 'etaf-resizable-panel)
               '((slot :name 'header
                   (box :use move :background-color (etaf-theme-token :ui-window-title-bg)
                     (etaf-label :text "拖动这个标题")))))
           (etaf-label :text "真实组件，尺寸不会随卡片拉伸。" :padding '((lh 0) (ch 1))))))))

(defconst etaf-ui-gallery--samples
  (list
   (etaf-ui-gallery--sample etaf-button basic "按钮" "主操作、次操作、轻量与禁用状态。"
     ((count (etaf-ref 0)))
     (column :item-gap '(lh 1)
       (flex :gap '((lh 1) (ch 2)) :flex-wrap 'wrap
         (etaf-button :label "主要操作" :on-press (lambda () (cl-incf (etaf-value count))))
         (etaf-button :label "次要操作" :variant 'secondary :on-press (lambda () (cl-incf (etaf-value count))))
         (etaf-button :label "轻量操作" :variant 'ghost :on-press (lambda () (cl-incf (etaf-value count))))
         (etaf-button :label "不可操作" :disabled t))
       (etaf-label :text (format "已点击 %d 次" (etaf-value count)) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-label basic "标签" "语义文本保持标准行高，长文本按可用宽度换行。" ()
     (flex :gap '((lh 1) (ch 2)) :flex-wrap 'wrap
       (etaf-label :text "普通文本") (etaf-label :text "次要说明" :variant 'muted)
       (etaf-label :text "强调文本" :variant 'strong) (etaf-label :text "成功" :variant 'success)
       (etaf-label :text "需要处理" :variant 'danger)))
   (etaf-ui-gallery--sample etaf-ui-icon basic "图标" "统一尺寸的 SVG 图标，点击播放图标试试。"
     ((count (etaf-ref 0)))
     (row :item-gap '(ch 2)
       (etaf-ui-icon :name 'play :set 'svg :aria-label "播放示例" :on-press (lambda () (cl-incf (etaf-value count))))
       (etaf-ui-icon :name 'search :set 'svg) (etaf-ui-icon :name 'settings :set 'svg)
       (etaf-ui-icon :name 'heart :set 'svg)
       (etaf-label :text (format "播放 %d 次" (etaf-value count)) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-ui-toggle-icon basic "切换图标" "播放与暂停共享同一个操作入口。"
     ((playing (etaf-ref nil)))
     (row :item-gap '(ch 2)
       (etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg
                            :aria-label "播放或暂停" :on-press (lambda () (setf (etaf-value playing) (not (etaf-value playing)))))
       (etaf-label :text (if (etaf-value playing) "正在播放" "已暂停"))))
   (etaf-ui-gallery--sample etaf-avatar basic "头像" "圆形头像、姓名缩写与紧凑行高。" ()
     (row :item-gap '(ch 2)
       (etaf-avatar :name "林" :initials "林" :variant 'info)
       (etaf-avatar :name "陈" :initials "陈" :variant 'success)
       (etaf-avatar :name "Ada Lovelace" :initials "AL" :lines 2 :size '(ch 4))
       (etaf-avatar :name "Emacs" :initials "E" :shape 'square :lines 2 :size '(ch 4))))
   (etaf-ui-gallery--sample etaf-kbd basic "键帽" "把操作提示显示成一组清晰的按键。" ()
     (row :item-gap '(ch 3)
       (etaf-kbd :keys '("Tab")) (etaf-kbd :keys '("Ctrl" "Return"))
       (etaf-kbd :keys '("Esc"))))
   (etaf-ui-gallery--sample etaf-divider basic "分隔线" "用轻量分隔建立内容层次。" ()
     (column :item-gap '(lh 1)
       (etaf-label :text "内容分组") (etaf-divider :label "下一节")
       (etaf-label :text "分隔线跟随主题。" :variant 'muted)))

   (etaf-ui-gallery--sample etaf-text-input input "文本输入" "原位编辑，支持中文、撤销与多行输入。"
     ((title (etaf-ref "ETAF Gallery")) (notes (etaf-ref "把一个想法写下来，\n再用组件把它做出来。")))
     (flex :flex-wrap 'wrap :gap '((lh 1) (ch 3))
       (column :flex-grow 1 :flex-basis '(ch 28) :min-width '(ch 20)
         (etaf-text-input :bind title :label "项目名称" :placeholder "输入名称")
         (etaf-label :text (concat "当前值：" (etaf-value title)) :variant 'muted :wrap-mode 'word))
       (etaf-text-input :bind notes :label "多行备注" :rows 2 :flex-grow 1 :flex-basis '(ch 28) :min-width '(ch 20))))
   (etaf-ui-gallery--sample etaf-checkbox input "复选框" "独立选择；禁用的选项不会修改状态。"
     ((save (etaf-ref t)) (notice (etaf-ref nil)))
     (column :item-gap '(lh 1)
       (flex :flex-wrap 'wrap :gap '((lh 1) (ch 3))
         (etaf-checkbox :bind save :label "自动保存")
         (etaf-checkbox :bind notice :label "接收通知")
         (etaf-checkbox :checked nil :disabled t :label "禁用状态"))
       (etaf-label :text (format "自动保存 = %s    接收通知 = %s" (etaf-value save) (etaf-value notice)) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-select input "选择器" "少量选项内联显示，更多选项放进下拉面板。"
     ((kind (etaf-ref 'design)) (language (etaf-ref 'zh)))
     (flex :flex-wrap 'wrap :gap '((lh 1) (ch 4))
       (etaf-select :bind kind :label "项目类型" :options '((design . "设计") (code . "开发") (docs . "文档")))
       (etaf-select :bind language :label "语言" :presentation 'dropdown
                    :options '((zh . "中文（简体）") (en . "English") (ja . "日本語") (fr . "Français") (de . "Deutsch")))))
   (etaf-ui-gallery--sample etaf-search-field input "搜索框" "支持原位输入与清空；示例不会访问网络。"
     ((query (etaf-ref "")))
     (column
       (etaf-search-field :bind query :icon t :placeholder "搜索示例内容")
       (etaf-label :text (concat "查询：" (etaf-value query)) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-number-input input "数字输入" "步进器与原生数字输入，共享范围约束。"
     ((value (etaf-ref 3)))
     (etaf-number-input :bind value :label "列数" :min 1 :max 12))
   (etaf-ui-gallery--sample etaf-radio input "单选组" "用方向键在同组的互斥选项间移动。"
     ((value (etaf-ref 'comfortable)))
     (etaf-radio :bind value :label "阅读密度" :options '((compact . "紧凑") (comfortable . "舒适") (airy . "宽松"))))
   (etaf-ui-gallery--sample etaf-switch input "开关" "切换即时生效，值由调用方持有。"
     ((value (etaf-ref t)))
     (column :item-gap '(lh 1)
       (etaf-switch :bind value :label "实时预览")
       (etaf-label :text (if (etaf-value value) "预览已开启" "预览已关闭") :variant 'muted)))
   (etaf-ui-gallery--sample etaf-segmented input "分段选择" "紧凑的互斥切换器；选中状态不叠加悬停色。"
     ((value (etaf-ref 'day)))
     (etaf-segmented :bind value :options '((day . "日") (week . "周") (month . "月"))))
   (etaf-ui-gallery--sample etaf-slider input "整数滑块" "左右键按步长调整；激活后可直接输入数字。"
     ((value (etaf-ref 60)))
     (etaf-slider :bind value :label "预览缩放" :min 0 :max 100 :step 10))
   (etaf-ui-gallery--sample etaf-range input "连续范围" "拖动或用方向键调整，释放时提交当前值。"
     ((value (etaf-ref 60)) (committed (etaf-ref 60)))
     (column :item-gap '(lh 1)
       (etaf-range :value value :min 0 :max 100 :step 1 :label "音量示例"
                   :on-change (lambda (next) (setf (etaf-value value) next))
                   :on-commit (lambda (next) (setf (etaf-value committed) next)))
       (etaf-label :text (format "当前 %.0f%% · 已提交 %.0f%%" (etaf-value value) (etaf-value committed)) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-date-picker input "日期输入" "输入 ISO 日期；无效日期不会覆盖已接受的值。"
     ((date (etaf-ref "2026-10-14")))
     (etaf-date-picker :bind date :label "计划日期"))

   (etaf-ui-gallery--sample etaf-panel layout "面板" "标题、页头插槽与正文组成一个内容区域。" ()
     (etaf-panel :title "项目概览"
       (slot :name 'header (etaf-badge :text "进行中" :variant 'info))
       (etaf-label :text "用同一套组件组织你的应用。")))
   (etaf-ui-gallery--sample etaf-card layout "卡片" "带标题和说明的可复用内容容器。" ()
     (etaf-card :title "一个小想法" :description "从清晰的组件开始。"
       (etaf-label :text "留白、层次和主题保持一致。" :variant 'muted)))
   (etaf-ui-gallery--sample etaf-tabs layout "标签页" "切换当前页面，正文由调用方组合。"
     ((page (etaf-ref 'overview)))
     (column :item-gap '(lh 1)
       (etaf-tabs :active page :items '((:key overview :label "概览") (:key examples :label "示例") (:key settings :label "设置"))
                  :on-change (lambda (next) (setf (etaf-value page) next)))
       (etaf-label :text (pcase (etaf-value page) ('overview "这是概览页面。") ('examples "这是示例页面。") (_ "这是设置页面。")))))
   (etaf-ui-gallery--sample etaf-accordion layout "折叠面板" "展开一个或多个章节，不增加新的窗口。"
     ((open (etaf-ref '(intro))))
     (etaf-accordion :open open :multiple t
                     :items '((:key intro :label "组件是什么？" :content "组件是普通的 ETAF View 组合。")
                              (:key usage :label "如何使用？" :content "使用公开入口与受控状态。"))
                     :on-toggle (lambda (next) (setf (etaf-value open) next))))
   (etaf-ui-gallery--sample etaf-breadcrumb layout "面包屑" "显示当前位置并允许返回上一层。"
     ((selected (etaf-ref 2)))
     (column :item-gap '(lh 1)
       (etaf-breadcrumb :items '("组件库" "导航" "面包屑") :on-select (lambda (next) (setf (etaf-value selected) next)))
       (etaf-label :text (format "已选择第 %d 层" (1+ (etaf-value selected))) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-steps layout "步骤条" "按步骤展示任务进展。"
     ((step (etaf-ref 'design)))
     (etaf-steps :items '((:key design :label "设计") (:key build :label "实现") (:key verify :label "验证"))
                 :current step :on-change (lambda (next) (setf (etaf-value step) next))))
   (etaf-ui-gallery--sample etaf-splitter layout "分栏" "拖动分隔线，或聚焦后用左右键调整比例。"
     ((ratio (etaf-ref 0.4)) (origin (list 0.4 1)))
     (etaf-splitter :ratio ratio :height '(lh 4) :ref 'example-split
       :min-ratio 0.15 :max-ratio 0.85
       :on-change (lambda (gesture)
                    (pcase (plist-get gesture :phase)
                      ('start
                       (setcar origin (etaf-value ratio))
                       (setcar (cdr origin)
                               (max 1 (car (etaf-host-ref-size
                                            (etaf-runtime-for-buffer (current-buffer)) 'example-split)))))
                      ((or 'move 'end)
                       (setf (etaf-value ratio)
                             (max 0.15 (min 0.85 (+ (car origin)
                                                  (/ (float (car (plist-get gesture :delta)))
                                                     (cadr origin)))))))
                      ('cancel (setf (etaf-value ratio) (car origin)))))
       (slot :name 'first (etaf-label :text "左侧内容" :padding '((lh 0) (ch 1))))
       (slot :name 'second (etaf-label :text "右侧内容" :padding '((lh 0) (ch 1))))))
   (etaf-ui-gallery--sample etaf-pane-resizer layout "侧栏调宽" "固定宽度的窗格与可抓取的分隔线。"
     ((size (etaf-ref 160)))
     (flex :height '(lh 4)
       (box :width (list 'px (etaf-value size)) :background-color (etaf-theme-token :gallery-code)
         (etaf-label :text "可调宽侧栏" :padding '((lh 0) (ch 1))))
       (etaf-pane-resizer :size size :min 80 :max 260 :on-change (lambda (next) (setf (etaf-value size) next)))
       (etaf-label :text "主体内容" :padding '((lh 0) (ch 1)))))

   (etaf-ui-gallery--sample etaf-table data "表格" "稳定行身份、受控选择与自定义列宽。"
     ((selected (etaf-ref 1)))
     (etaf-table :columns '((:key :name :label "组件" :width (fr 2)) (:key :kind :label "分类" :width (fr 1)))
                 :rows '((:id 1 :name "Button" :kind "基础") (:id 2 :name "DataGrid" :kind "数据") (:id 3 :name "Dialog" :kind "浮层"))
                 :row-key (lambda (row) (plist-get row :id))
                 :row-selected-p (lambda (row) (= (etaf-value selected) (plist-get row :id)))
                 :on-row-press (lambda (row) (setf (etaf-value selected) (plist-get row :id)))))
   (etaf-ui-gallery--sample etaf-data-grid data "数据表格" "本地数据源驱动加载、选择与分页。"
     ((controller (etaf-data-controller
                   (etaf-data-memory-source '((:id 1 :name "Button") (:id 2 :name "Select") (:id 3 :name "Dialog") (:id 4 :name "Tree") (:id 5 :name "Window")) :id-key :id)
                   :page-size 2 :auto-load t)))
     (etaf-data-grid :controller controller :columns '((:key :name :label "组件" :width (fr 1)))
                     :row-key (lambda (row) (plist-get row :id))
                     :row-selected-p (lambda (row) (member (plist-get row :id) (etaf-value (etaf-data-selection controller))))
                     :on-row-press (lambda (row) (etaf-data-select-one controller (plist-get row :id)))))
   (etaf-ui-gallery--sample etaf-pagination data "分页" "页码属于数据控制器，前后翻页共享同一状态。"
     ((controller (etaf-data-controller (etaf-data-memory-source '("第一项" "第二项" "第三项" "第四项" "第五项")) :page-size 2 :auto-load t)))
     (column :item-gap '(lh 1)
       (etaf-label :text (string-join (etaf-value (etaf-data-items controller)) " · "))
       (etaf-pagination :controller controller :previous-label "上一页" :next-label "下一页")))
   (etaf-ui-gallery--sample etaf-list data "列表" "标题与说明组成一个完整的操作目标。"
     ((selected (etaf-ref "尚未选择")))
     (column :item-gap '(lh 1)
       (etaf-list :items '((:key browse :title "浏览组件" :description "寻找合适的基础能力")
                          (:key compose :title "组合界面" :description "用组件构建完整应用"))
                  :on-select (lambda (next) (setf (etaf-value selected) (symbol-name next))))
       (etaf-label :text (concat "当前选择：" (etaf-value selected)) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-tree data "树" "展开目录，并用方向键在层级中移动。"
     ((expanded (etaf-ref '(root))) (selected (etaf-ref "root")))
     (column :item-gap '(lh 1)
       (etaf-tree :items '((:key root :label "组件目录" :children ((:key basic :label "基础控件") (:key data :label "数据视图"))))
                  :expanded expanded :on-toggle (lambda (next) (setf (etaf-value expanded) next))
                  :on-select (lambda (next) (setf (etaf-value selected) (symbol-name next))))
       (etaf-label :text (concat "当前节点：" (etaf-value selected)) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-calendar data "日历" "按月显示日期，选中值由调用方保存。"
     ((day (etaf-ref 14)))
     (etaf-calendar :month '(2026 10) :value (etaf-value day) :label "选择日期"
                    :on-change (lambda (date) (setf (etaf-value day) (nth 2 date)))))
   (etaf-ui-gallery--sample etaf-timeline data "时间线" "把一组进展按时间顺序展示。" ()
     (etaf-timeline :items '((:title "设计确认" :content "布局与配色已经确定。" :status "完成")
                            (:title "组件组合" :content "用公开接口搭建界面。" :status "当前")
                            (:title "交互验证" :content "检查键盘、鼠标与布局。" :status "下一步"))))

   (etaf-ui-gallery--sample etaf-badge feedback "状态徽标" "同一组语义色用于所有状态反馈。" ()
     (flex :gap '((lh 1) (ch 2)) :flex-wrap 'wrap
       (etaf-badge :text "默认") (etaf-badge :text "已完成" :variant 'success)
       (etaf-badge :text "待检查" :variant 'warning) (etaf-badge :text "需处理" :variant 'danger)
       (etaf-badge :text "提示" :variant 'info)))
   (etaf-ui-gallery--sample etaf-tag feedback "标签" "可关闭的标签由调用方决定移除。"
     ((visible (etaf-ref t)))
     (row :item-gap '(ch 2)
       (etaf-tag :text "稳定" :variant 'success)
       (expr (if (etaf-value visible)
                 (etaf-view (etaf-tag :text "草稿" :variant 'warning :closable t :on-close (lambda () (setf (etaf-value visible) nil))))
               (etaf-view (etaf-button :label "恢复标签" :variant 'ghost :on-press (lambda () (setf (etaf-value visible) t))))))))
   (etaf-ui-gallery--sample etaf-progress feedback "进度" "确定进度以数值为准，不运行假计时器。"
     ((value (etaf-ref 72)))
     (column :item-gap '(lh 1)
       (etaf-progress :value value :max 100 :label "完成度" :variant 'info)
       (etaf-button :label "推进进度" :variant 'secondary :on-press (lambda () (setf (etaf-value value) (% (+ 10 (etaf-value value)) 101))))))
   (etaf-ui-gallery--sample etaf-alert feedback "提示条" "内联反馈保留上下文，并支持关闭与恢复。"
     ((visible (etaf-ref t)))
     (column
       (expr (if (etaf-value visible)
                 (etaf-view (etaf-alert :title "设置已保存" :message "随时可以继续修改。" :variant 'success
                                        :dismissible t :on-dismiss (lambda () (setf (etaf-value visible) nil))))
               (etaf-view (etaf-button :label "恢复提示" :variant 'secondary :on-press (lambda () (setf (etaf-value visible) t))))))))
   (etaf-ui-gallery--sample etaf-statistic feedback "统计值" "标题、数值与趋势构成一个紧凑信息单元。" ()
     (etaf-statistic :label "已完成任务" :value "24" :trend "+3 本周"))
   (etaf-ui-gallery--sample etaf-empty feedback "空状态" "没有数据时，提供清楚的说明和下一步。"
     ((created (etaf-ref nil)))
     (column
       (expr (if (etaf-value created)
                 (etaf-view (etaf-alert :title "示例集合已创建" :message "使用重置示例可恢复空状态。" :variant 'success))
               (etaf-view (etaf-empty :title "还没有集合" :description "从第一个小想法开始。" :action-label "创建示例集合"
                                      :on-action (lambda () (setf (etaf-value created) t))))))))
   (etaf-ui-gallery--sample etaf-skeleton feedback "加载占位" "只表达加载状态，不持有网络请求或定时器。" ()
     (column :item-gap '(lh 1)
       (etaf-skeleton :width '(% 75) :height '(lh 1))
       (etaf-skeleton :width '(% 55) :height '(lh 1))))
   (etaf-ui-gallery--sample etaf-reactions feedback "回应" "点击表情切换回应，计数跟随受控数据。"
     ((items (etaf-ref '((:key like :label "赞" :count 3 :chosen nil) (:key heart :label "喜欢" :count 2 :chosen t)))))
     (etaf-reactions :items items
                     :on-toggle (lambda (key)
                                  (setf (etaf-value items)
                                        (mapcar (lambda (item)
                                                  (if (not (eq (plist-get item :key) key)) item
                                                    (let* ((copy (copy-sequence item)) (chosen (plist-get item :chosen)))
                                                      (plist-put copy :chosen (not chosen))
                                                      (plist-put copy :count (+ (plist-get item :count) (if chosen -1 1))) copy)))
                                                (etaf-value items))))))

   (etaf-ui-gallery--sample etaf-menu surface "原生菜单" "在原生补全中选择操作，取消不改变结果。"
     ((selected (etaf-ref "尚未选择")))
     (row :item-gap '(ch 2)
       (etaf-menu :label "原生操作菜单" :items '((:key copy :label "复制内容") (:key rename :label "重命名") (:key remove :label "删除" :disabled t))
                  :on-select (lambda (next) (setf (etaf-value selected) (symbol-name next))))
       (etaf-label :text selected :variant 'muted)))
   (etaf-ui-gallery--sample etaf-dropdown-menu surface "下拉菜单" "菜单直接显示在当前 Buffer，禁用项不可选。"
     ((selected (etaf-ref "尚未选择")))
     (row :item-gap '(ch 2)
       (etaf-dropdown-menu :label "操作菜单" :items '((:key copy :label "复制内容") (:key rename :label "重命名") (:key remove :label "删除" :disabled t))
                           :on-select (lambda (next) (setf (etaf-value selected) (symbol-name next))))
       (etaf-label :text selected :variant 'muted)))
   (etaf-ui-gallery--sample etaf-context-menu surface "上下文菜单" "键盘与鼠标共用一个明确的操作入口。"
     ((selected (etaf-ref "尚未选择")))
     (row :item-gap '(ch 2)
       (etaf-context-menu :label "更多操作" :items '((:key inspect :label "检查属性") (:key duplicate :label "复制一份"))
                          :on-select (lambda (next) (setf (etaf-value selected) (symbol-name next))))
       (etaf-label :text selected :variant 'muted)))
   (etaf-ui-gallery--sample etaf-popover surface "气泡面板" "面板锚定在入口旁，关闭后恢复入口焦点。"
     ((open (etaf-ref nil)) (anchor (symbol-name (make-symbol "gallery-popover"))))
     (column
       (etaf-button :id anchor :label "打开气泡" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-popover :open open :anchor anchor :title "快捷设置" :on-close (lambda () (setf (etaf-value open) nil))
         (etaf-label :text "这是一个真正的浮层。")
         (slot :name 'footer (etaf-button :label "关闭气泡" :on-press (lambda () (setf (etaf-value open) nil)))))))
   (etaf-ui-gallery--sample etaf-dialog surface "对话框" "模态表单保留背景，取消与提交明确分开。"
     ((open (etaf-ref nil)) (draft (etaf-ref "")) (saved (etaf-ref "尚未创建")))
     (column :item-gap '(lh 1)
       (etaf-button :label "打开对话框" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-label :text saved :variant 'muted)
       (etaf-dialog :open open :title "创建示例项目" :close-label "取消" :on-close (lambda () (setf (etaf-value open) nil))
         (etaf-text-input :bind draft :label "示例项目名称" :placeholder "输入中文或英文")
         (slot :name 'footer
           (etaf-button :label "创建项目" :on-press (lambda () (setf (etaf-value saved) (concat "已创建：" (etaf-value draft))
                                                                    (etaf-value open) nil)))))))
   (etaf-ui-gallery--sample etaf-key-help surface "快捷键帮助" "可搜索的只读帮助；etaf-help 自动使用此组件，无需应用持有弹窗状态。" ()
     (column :help "查看帮助不会执行列表里的操作。"
       (etaf-button :label "查看快捷键" :variant 'secondary :on-press #'etaf-help)))
   (etaf-ui-gallery--sample etaf-tooltip surface "工具提示" "明确打开短提示；Escape 关闭并恢复焦点。"
     ((open (etaf-ref nil)))
     (column
       (etaf-button :id "gallery-tooltip-anchor" :label "显示提示" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-tooltip :open open :anchor "gallery-tooltip-anchor" :text "Tab 切换控件，Enter 执行操作。" :on-close (lambda () (setf (etaf-value open) nil)))))
   (etaf-ui-gallery--sample etaf-toast surface "通知" "通知生命周期由调用方控制，不自动丢失信息。"
     ((open (etaf-ref nil)))
     (column
       (etaf-button :id "gallery-toast-anchor" :label "显示通知" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-toast :open open :anchor "gallery-toast-anchor" :title "保存完成" :message "你的示例设置已保存。"
                   :variant 'success :on-close (lambda () (setf (etaf-value open) nil)))))
   (etaf-ui-gallery--sample etaf-drawer surface "抽屉" "从侧边展开详情，关闭后回到当前页面。"
     ((open (etaf-ref nil)))
     (column
       (etaf-button :label "展开抽屉" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-drawer :open open :title "组件详情" :on-close (lambda () (setf (etaf-value open) nil))
         (etaf-label :text "详情与主页面在同一个 Buffer。" :wrap-mode 'word)
         (slot :name 'footer (etaf-button :label "关闭抽屉" :on-press (lambda () (setf (etaf-value open) nil)))))))
   (etaf-ui-gallery--sample etaf-command-palette surface "命令面板" "在模态面板中选择一个本地命令。"
     ((open (etaf-ref nil)) (selected (etaf-ref "尚未执行")))
     (column :item-gap '(lh 1)
       (etaf-button :label "打开命令面板" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-label :text selected :variant 'muted)
       (etaf-command-palette :open open :title "示例命令" :items '((:key new :label "新建项目" :title "新建项目") (:key save :label "保存项目" :title "保存项目"))
                             :on-close (lambda () (setf (etaf-value open) nil))
                             :on-select (lambda (next) (setf (etaf-value selected) (format "已执行：%s" next) (etaf-value open) nil)))))

   (etaf-ui-gallery--window-sample etaf-resizable-panel "可调整面板")
   (etaf-ui-gallery--sample etaf-window-controls desktop "窗口控制" "红黄绿三个入口，只请求调用方改变窗口状态。"
     ((mode (etaf-ref 'normal)) (status (etaf-ref "普通窗口")))
     (row :item-gap '(ch 3)
       (etaf-window-controls :mode mode
         :on-close (lambda () (setf (etaf-value status) "已请求关闭"))
         :on-minimize (lambda () (setf (etaf-value mode) 'minimized (etaf-value status) "已最小化"))
         :on-maximize (lambda () (setf (etaf-value mode) 'maximized (etaf-value status) "已最大化"))
         :on-restore (lambda () (setf (etaf-value mode) 'normal (etaf-value status) "普通窗口")))
       (etaf-label :text status :variant 'muted)))
   (etaf-ui-gallery--sample etaf-window-chrome desktop "窗口标题栏" "标题、窗口控制与自定义操作共用标准行高。"
     ((status (etaf-ref "预览窗口")))
     (etaf-window-chrome :title (etaf-value status)
       :on-close (lambda () (setf (etaf-value status) "已请求关闭"))
       :on-minimize (lambda () (setf (etaf-value status) "已请求最小化"))
       :on-maximize (lambda () (setf (etaf-value status) "已请求最大化"))))
   (etaf-ui-gallery--window-sample etaf-window "窗口")
   (etaf-ui-gallery--sample etaf-taskbar desktop "任务栏" "当前任务与最小化任务共享受控选择。"
     ((active (etaf-ref 'editor)))
     (etaf-taskbar :items '((:key editor :label "编辑器") (:key preview :label "预览" :state minimized))
                   :active active :on-select (lambda (next) (setf (etaf-value active) next))))
   (etaf-ui-gallery--sample etaf-workspace-bar desktop "工作区栏" "切换工作区，状态跟随当前选择。"
     ((active (etaf-ref 'one)))
     (etaf-workspace-bar :brand "示例" :workspaces '((:key one :label "工作区 1") (:key two :label "工作区 2"))
                         :active active :on-select (lambda (next) (setf (etaf-value active) next))
                         :status "本地示例"))
   (etaf-ui-gallery--sample etaf-launcher desktop "启动器" "选择应用只更新示例状态，不启动外部程序。"
     ((open (etaf-ref nil)) (selected (etaf-ref "尚未启动")))
     (column :item-gap '(lh 1)
       (etaf-button :label "打开启动器" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-label :text selected :variant 'muted)
       (etaf-launcher :open open :title "选择示例应用" :close-label "关闭"
                      :items '((:key editor :label "编辑器" :description "记录你的想法") (:key preview :label "预览" :description "查看内容效果"))
                      :on-close (lambda () (setf (etaf-value open) nil))
                      :on-select (lambda (next) (setf (etaf-value selected) (format "已选择：%s" next) (etaf-value open) nil)))))
   (etaf-ui-gallery--sample etaf-switcher desktop "窗口切换器" "展示当前窗口，并选择另一个目标。"
     ((open (etaf-ref nil)) (selected (etaf-ref 'editor)))
     (column
       (etaf-button :label "打开切换器" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-switcher :open open :title "切换示例窗口" :selected selected :close-label "关闭"
                      :items '((:key editor :label "编辑器") (:key preview :label "预览"))
                      :on-close (lambda () (setf (etaf-value open) nil))
                      :on-select (lambda (next) (setf (etaf-value selected) next (etaf-value open) nil)))))

   (etaf-ui-gallery--sample etaf-media-viewer media "媒体查看器" "本地生成的图片保持比例，无网络与自动播放。"
     ((open (etaf-ref nil))
      (image (etaf-ui-svg-image
              (concat (etaf-ui-svg-rect 0 0 640 360 :fill "#E9E5FC")
                      (etaf-ui-svg-circle 440 100 42 :fill "#B7A5FF")
                      (etaf-ui-svg-path "M0 330 L180 120 L330 280 L440 190 L640 360 H0Z" :fill "#6553CA"))
              640 360 '(0 0 640 360))))
     (column :item-gap '(lh 1)
       (image :src image :columns 32
              :rows (max 1 (round (/ (* 18.0 (plist-get (etaf-display-metrics) :char-width))
                                     (plist-get (etaf-display-metrics) :line-height)))))
       (etaf-button :label "查看图片" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
       (etaf-media-viewer :open open :src image :source-size '(640 . 360) :title "山与光"
                          :caption "在当前 Buffer 中查看，Escape 关闭。" :autoplay nil
                          :on-close (lambda () (setf (etaf-value open) nil)))))
   (etaf-ui-gallery--sample etaf-tile-grid media "单元网格" "单元尺寸固定，点击格子改变当前选择。"
     ((selected (etaf-ref '(1 . 1))))
     (column :item-gap '(lh 1)
       (etaf-tile-grid :rows 3 :columns 6 :cell-width 3 :cell-height 1
                       :cell-text (lambda (_row _col) " · ")
                       :cell-background (lambda (row col) (etaf-theme-token (if (equal (cons row col) (etaf-value selected)) :ui-accent :ui-accent-soft-bg)))
                       :cell-color (lambda (row col) (etaf-theme-token (if (equal (cons row col) (etaf-value selected)) :ui-accent-fg :ui-fg)))
                       :on-cell-press (lambda (row col) (setf (etaf-value selected) (cons row col))))
       (etaf-label :text (format "选中第 %d 行、第 %d 列" (1+ (car (etaf-value selected))) (1+ (cdr (etaf-value selected)))) :variant 'muted)))
   (etaf-ui-gallery--sample etaf-text-grid media "字符表面" "每行保持固定字符宽度，适合终端与字符画。" ()
     (etaf-text-grid :rows 4 :columns 28 :label "字符画示例"
                     :row-text (lambda (row) (nth row '("    +----------------+" "    |  ETAF / TEXT   |" "    |  . . . . . .   |" "    +----------------+")))))
   (etaf-ui-gallery--sample etaf-playing-card media "扑克牌" "正面、背面与空牌堆保持固有尺寸。"
     ((selected (etaf-ref nil)))
     (row :item-gap '(ch 2)
       (etaf-playing-card :rank "A" :suit 'hearts :selected selected :on-press (lambda () (setf (etaf-value selected) (not (etaf-value selected)))))
       (etaf-playing-card :face-down t) (etaf-playing-card :empty t))))
  "Maintained live specimens and their reproducible public-API examples.")

(defun etaf-ui-gallery--items (group)
  "Return specimens in GROUP, or all specimens when GROUP is nil."
  (cl-remove-if-not (lambda (entry) (or (null group) (eq group (plist-get entry :group))))
                    etaf-ui-gallery--samples))

(defun etaf-ui-gallery--source (entry)
  "Build a standalone lexical-binding example from ENTRY's live specimen."
  (let* ((bindings (plist-get entry :bindings))
         (form `(let* ,(append bindings
                               `((buffer (etaf-mount "*ETAF UI Example*"
                                                     (etaf-view ,(plist-get entry :form))))))
                  ,@(when (assq 'controller bindings)
                      '((with-current-buffer buffer
                          (add-hook 'kill-buffer-hook (lambda () (etaf-data-stop controller)) nil t))))
                  (pop-to-buffer buffer))))
    (concat ";;; -*- lexical-binding: t; -*-\n(require 'etaf-ui)\n\n"
            (let ((print-circle nil) (print-length nil) (print-level nil)
                  (pp-default-function
                   (if (fboundp 'pp-fill) #'pp-fill
                     (and (boundp 'pp-default-function) pp-default-function)))
                  (fill-column 88)
                  (indent-tabs-mode nil))
              (pp-to-string form)))))

(defun etaf-ui-gallery--read-documentation ()
  "Read Component records from the installed public entry before mounting.
The Gallery consumes Commentary, not the component registry or a second API
inventory.  Each Parameters paragraph lists keyword groups and their prose."
  (with-temp-buffer
    (insert-file-contents
     (or (locate-library "etaf-ui.el")
         (user-error "Gallery needs the installed etaf-ui.el source documentation")))
    (goto-char (point-min))
    (search-forward ";;; Commentary:")
    (let ((begin (point)))
      (search-forward ";;; Code:")
      (narrow-to-region begin (match-beginning 0)))
    (goto-char (point-min))
    (let (documents)
      (while (re-search-forward "^;; Component: \\(\\S-+\\) \\(.*\\)$" nil t)
        (let ((name (intern (match-string 1)))
              (signature (concat (match-string 1) " " (match-string 2)))
              (keywords (cdr (read (match-string 2))))
              lines parameters prose)
          (forward-line 1)
          (while (and (not (looking-at ";; \\(Component\\|Function\\|Macro\\|Variable\\|Hook\\|Error\\):"))
                      (looking-at ";;\\(?: \\(.*\\)\\)?$"))
            (push (or (match-string 1) "") lines)
            (forward-line 1))
          (dolist (paragraph (split-string (string-join (nreverse lines) "\n") "\n\n+" t))
            (if (string-prefix-p "Parameters:\n" paragraph)
                (dolist (line (split-string (substring paragraph (length "Parameters:\n")) "\n" t))
                  (if (string-match "\\`\\(:[^—]+\\) — \\(.*\\)\\'" line)
                      (push (cons (string-trim (match-string 1 line)) (match-string 2 line)) parameters)
                    (unless parameters (error "Malformed parameter documentation for %s" name))
                    (setcdr (car parameters) (concat (cdar parameters) " " (string-trim line)))))
              (push (string-join (split-string paragraph "\n" t) " ") prose)))
          (let ((documented (mapconcat #'car parameters ", ")))
            (dolist (keyword keywords)
              (unless (string-match-p (concat ":" (regexp-quote (symbol-name keyword)) "\\_>") documented)
                (error "Missing parameter documentation for %s :%s" name keyword))))
          (push (cons name (list :signature signature :parameters (nreverse parameters)
                                 :prose (nreverse prose))) documents)))
      (dolist (entry etaf-ui-gallery--samples)
        (unless (assq (plist-get entry :name) documents)
          (error "Missing public Component documentation for %s" (plist-get entry :name))))
      documents)))

(defun etaf-ui-gallery--create-states ()
  "Create the mount's specimen states outside rendering."
  (mapcar (lambda (entry)
            (cons (plist-get entry :name)
                  (append (funcall (plist-get entry :create)) (list :code (etaf-ref nil)))))
          etaf-ui-gallery--samples))

(defun etaf-ui-gallery--dispose-states (states)
  "Stop the local controllers owned by STATES."
  (dolist (entry states)
    (when-let* ((controller (plist-get (cdr entry) :controller)))
      (etaf-data-stop controller))))

(etaf-define-component etaf-ui-gallery--reference (&key documentation)
  :render
  (etaf-view
   (column :width 'stretch :item-gap '(lh 1)
     (etaf-label :text "调用签名" :variant 'strong)
     (etaf-label :text (plist-get documentation :signature) :wrap-mode 'word :width 'stretch)
     (etaf-label :text "参数与默认值" :variant 'strong)
     (etaf-label :text "以下为组件参数；其他布局、样式和可访问性属性遵循 ETAF 的公共 Host 透传契约，不会自动传给所有内部控件。"
                 :variant 'muted :wrap-mode 'word :width 'stretch)
     (expr
      (mapcar
       (lambda (parameter)
         (etaf-view
          (column :width 'stretch
            (etaf-label :text (car parameter) :variant 'strong :wrap-mode 'word :width 'stretch)
            (etaf-label :text (cdr parameter) :wrap-mode 'word :width 'stretch))))
       (plist-get documentation :parameters)))
     (etaf-label :text "行为与限制" :variant 'strong)
     (expr
      (mapcar (lambda (paragraph)
                (etaf-view (etaf-label :text paragraph :wrap-mode 'word :width 'stretch)))
              (plist-get documentation :prose))))))

(etaf-define-component etaf-ui-gallery--specimen (&key entry state documentation)
  :render
  (let* ((name (plist-get entry :name)) (code (plist-get state :code)))
    (etaf-view
     (etaf-card :padding '((lh 0) (ch 0)) :item-gap '(lh 0) :ref name :id (symbol-name name)
       (flex :justify-content 'space-between :align-items 'center :flex-wrap 'wrap
             :gap '((lh 1) (ch 1)) :padding '((lh 0.5) (ch 2))
             :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (etaf-theme-token :ui-border)
         (row :item-gap '(ch 2)
           (etaf-label :text (plist-get entry :title) :variant 'strong)
           (etaf-label :text (symbol-name name) :variant 'muted))
         (etaf-button :label (concat (if (etaf-value code) "收起用法" "查看用法") " "
                                    (car (etaf-ui-icon-lines
                                          (if (etaf-value code) 'chevron-up 'chevron-down)
                                          :set 'svg :size 0.75))) :variant 'ghost
                      :aria-label (concat "查看用法：" (symbol-name name))
                      :on-press (lambda () (setf (etaf-value code) (not (etaf-value code))))))
       (column :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
         (etaf-label :text (plist-get entry :description) :variant 'muted :wrap-mode 'word)
         (expr (funcall (plist-get entry :render) state)))
       (expr
        (when (etaf-value code)
          (etaf-view
           (column :padding '((lh 1) (ch 2)) :item-gap '(lh 1) :width 'stretch
                   :ref (intern (format "gallery-reference-%s" name))
                   :background-color (etaf-theme-token :gallery-code)
                   :border-top-width '(px 1) :border-top-style 'solid :border-top-color (etaf-theme-token :ui-border)
             (flex :justify-content 'space-between :align-items 'center :flex-wrap 'wrap
               (etaf-label :text "组件参考" :variant 'strong)
               (etaf-button :label "复制示例" :variant 'ghost
                            :aria-label (concat "复制示例：" (symbol-name name))
                            :on-press (lambda () (kill-new (etaf-ui-gallery--source entry)) (message "已复制完整示例，可保存为 .el 文件运行。"))))
             (etaf-ui-gallery--reference :documentation documentation)
             (etaf-label :text "完整示例" :variant 'strong)
             (etaf-label :text (etaf-ui-gallery--source entry) :wrap-mode 'word :width 'stretch)))))))))

(etaf-define-component etaf-ui-gallery--preview (&key group)
  :bindings ((count (etaf-ref 0)) (checked (etaf-ref t)) (query (etaf-ref ""))
             (tab (etaf-ref 'overview)) (open (etaf-ref nil)) (drawer (etaf-ref nil))
             (image (etaf-ui-svg-image
                     (concat (etaf-ui-svg-rect 0 0 160 90 :fill "#E9E5FC")
                             (etaf-ui-svg-circle 120 24 12 :fill "#B7A5FF")
                             (etaf-ui-svg-path "M0 90 L45 25 L90 75 L120 45 L160 90Z" :fill "#6553CA"))
                     160 90 '(0 0 160 90))))
  :render
  (pcase group
    ('basic
     (etaf-view
      (column :item-gap '(lh 1)
        (flex :gap '((lh 1) (ch 1)) :flex-wrap 'wrap
          (etaf-button :label "主要操作" :on-press (lambda () (cl-incf (etaf-value count))))
          (etaf-button :label "次要操作" :variant 'secondary :on-press (lambda () (cl-incf (etaf-value count))))
          (etaf-button :label "轻量操作" :variant 'ghost :on-press (lambda () (cl-incf (etaf-value count)))))
        (row :item-gap '(ch 2)
          (etaf-kbd :keys '("Tab")) (etaf-label :text (format "已点击 %d 次" (etaf-value count)) :variant 'muted)
          (etaf-ui-icon :name 'play :set 'svg) (etaf-ui-icon :name 'heart :set 'svg)
          (etaf-avatar :name "林" :initials "林" :variant 'info)
          (etaf-avatar :name "陈" :initials "陈" :variant 'success)))))
    ('input
     (etaf-view
      (column
        (etaf-text-input :bind query :label "预览名称" :hide-label t :placeholder "给你的想法取个名字")
        (row :item-gap '(ch 2)
          (etaf-checkbox :bind checked :label "自动保存")
          (etaf-switch :checked checked :label "实时预览" :on-change (lambda (next) (setf (etaf-value checked) next))))
        (etaf-label :text (if (etaf-value checked) "自动保存已开启" "自动保存已关闭") :variant 'muted))))
    ('layout
     (etaf-view
      (flex :column-gap '(ch 2)
        (column :flex-grow 1 :flex-basis '(px 0) :item-gap '(lh 1)
          (etaf-breadcrumb :items '("组件库" "导航" "标签页"))
          (etaf-tabs :active tab :items '((:key overview :label "概览") (:key examples :label "示例") (:key settings :label "设置"))
                     :on-change (lambda (next) (setf (etaf-value tab) next))))
        (etaf-panel :title "内容面板" :width '(ch 19) :padding '((lh 0) (ch 1))
          (etaf-label :text "组合你的界面" :variant 'muted)))))
    ('data
     (etaf-view
      (flex :column-gap '(ch 2)
        (etaf-table :flex-grow 1 :flex-basis '(px 0)
                    :columns '((:key :name :label "组件" :width (fr 2)) (:key :kind :label "分类" :width (fr 1)) (:key :state :label "状态" :width (fr 1)))
                    :rows '((:name "Button" :kind "基础" :state "就绪") (:name "DataGrid" :kind "数据" :state "就绪"))
                    :row-key (lambda (row) (plist-get row :name)))
        (etaf-tree :width '(ch 18) :expanded '(root)
                    :items '((:key root :label "组件目录" :children ((:key basic :label "基础控件") (:key data :label "数据视图"))))))))
    ('feedback
     (etaf-view
      (flex :column-gap '(ch 3)
        (column :flex-grow 1 :flex-basis '(px 0) :item-gap '(lh 1)
          (row :item-gap '(ch 1)
            (etaf-badge :text "已完成" :variant 'success) (etaf-badge :text "待检查" :variant 'warning)
            (etaf-badge :text "需处理" :variant 'danger))
          (etaf-alert :title "设置已保存" :message "随时可以继续修改" :variant 'success :padding '((lh 0) (ch 1))))
        (etaf-progress :width '(ch 20) :value 72 :max 100 :label "完成度" :variant 'info))))
    ('surface
     (etaf-view
      (column :item-gap '(lh 1)
        (flex :gap '((lh 1) (ch 1)) :flex-wrap 'wrap
          (etaf-dropdown-menu :label "操作菜单" :items '((:key copy :label "复制内容") (:key rename :label "重命名"))
                              :on-select (lambda (_) (cl-incf (etaf-value count))))
          (etaf-button :label "打开对话框" :variant 'secondary :on-press (lambda () (setf (etaf-value open) t)))
          (etaf-button :label "展开抽屉" :variant 'secondary :on-press (lambda () (setf (etaf-value drawer) t))))
        (etaf-label :text "关闭后回到原来的控件。" :variant 'muted)
        (etaf-dialog :open open :title "创建示例项目" :close-label "取消" :on-close (lambda () (setf (etaf-value open) nil))
          (etaf-text-input :bind query :label "示例项目名称" :placeholder "输入中文或英文")
          (slot :name 'footer (etaf-button :label "创建项目" :on-press (lambda () (setf (etaf-value open) nil)))))
        (etaf-drawer :open drawer :title "组件详情" :on-close (lambda () (setf (etaf-value drawer) nil))
          (etaf-label :text "用公开组件组合完整界面。")
          (slot :name 'footer (etaf-button :label "关闭抽屉" :on-press (lambda () (setf (etaf-value drawer) nil))))))))
    ('desktop
     (etaf-view
      (flex :column-gap '(ch 3)
        (column :flex-grow 1 :flex-basis '(px 0) :border-width '(px 1) :border-style 'solid :border-color (etaf-theme-token :ui-border)
          (etaf-window-chrome :title "预览窗口"
            :on-close (lambda () (cl-incf (etaf-value count)))
            :on-minimize (lambda () (cl-incf (etaf-value count)))
            :on-maximize (lambda () (cl-incf (etaf-value count))))
          (etaf-label :text (format "窗口控制 · 已操作 %d 次" (etaf-value count)) :variant 'muted :padding '((lh 0) (ch 1))))
        (column :flex-grow 1 :flex-basis '(px 0) :item-gap '(lh 1)
          (etaf-workspace-bar :workspaces '((:key overview :label "工作区 1") (:key examples :label "工作区 2"))
                              :active tab :on-select (lambda (next) (setf (etaf-value tab) next)))
          (etaf-label :text "窗口 · 启动器 · 任务栏" :variant 'muted)))))
    ('media
     (etaf-view
      (row :item-gap '(ch 3)
        (image :src image :columns 12 :rows 3)
        (column
          (etaf-label :text "图片预览")
          (etaf-label :text "保持原始比例" :variant 'muted))
        (etaf-tile-grid :rows 3 :columns 4 :cell-width 2 :cell-height 1
                        :cell-text (lambda (_r _c) "· ")
                        :cell-background (lambda (r c) (etaf-theme-token (if (= (% (+ r c) 3) 0) :ui-accent :ui-accent-soft-bg))))
        (etaf-playing-card :rank "A" :suit 'hearts :lines 3 :columns 7 :selected checked
                           :on-press (lambda () (setf (etaf-value checked) (not (etaf-value checked)))))
        (etaf-playing-card :face-down t :lines 3 :columns 7))))))

(etaf-define-component etaf-ui-gallery--overview (&key on-select columns card-width generation)
  :render
  (etaf-node
   'flex (list :flex-wrap 'wrap :gap '((lh 1) (ch 2)) :align-items 'flex-start)
   (mapcar
    (lambda (group)
      (let ((key (car group)))
        (etaf-view
         (etaf-card :key key :width (list 'px card-width) :padding '((lh 0) (ch 0)) :item-gap '(lh 0)
           (flex :justify-content 'space-between :align-items 'center :height '(lh 3)
                 :box-sizing 'border-box :padding '((lh 0) (ch 2))
                 :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (etaf-theme-token :ui-border)
             (etaf-label :text (nth 1 group) :variant 'strong)
             (etaf-button :label (format "查看 %d 项 →" (length (etaf-ui-gallery--items key))) :variant 'ghost
                          :aria-label (concat "浏览" (nth 1 group)) :on-press (lambda () (funcall on-select key))))
           (box :padding '((lh 0) (ch 2)) :min-height '(lh 4) :box-sizing 'border-box
             (etaf-ui-gallery--preview :key (format "%s-%s" key generation) :group key))
           (etaf-label :text (nth 2 group) :variant 'muted :padding '((lh 0) (ch 2))
                       :height '(lh 2) :box-sizing 'border-box :wrap-mode 'word)))))
    etaf-ui-gallery--groups)))

(etaf-define-component etaf-ui-gallery--results (&key category query states generation on-select documents)
  :render
  (let* ((viewport (etaf-viewport))
         (cw (plist-get (etaf-display-metrics) :char-width))
         (width (or (car viewport) (* 120 cw)))
         (total-columns (/ width (float cw)))
         (sidebar (if (>= total-columns etaf-ui-gallery--sidebar-columns) 24 0))
         (available (max (* cw 38) (- width (* cw (+ sidebar 4)))))
         (columns (if (>= available (* cw 96)) 2 1))
         (card-width (floor (/ (- available (* cw 2 (1- columns))) columns)))
         (needle (downcase (string-trim (etaf-value query))))
         (selected (etaf-value category))
         (entries (if (string-empty-p needle) (etaf-ui-gallery--items selected)
                    (cl-remove-if-not
                     (lambda (entry)
                       (string-match-p
                        (regexp-quote needle)
                        (downcase (format "%s %s %s" (plist-get entry :name) (plist-get entry :title)
                                          (plist-get entry :description)))))
                     etaf-ui-gallery--samples))))
    (cond
     ((and (null selected) (string-empty-p needle))
      (etaf-view (etaf-ui-gallery--overview :on-select on-select :columns columns :card-width card-width :generation (etaf-value generation))))
     ((null entries)
      (etaf-view (etaf-empty :title "没有找到组件" :description "试试组件名称或用途，例如 Button、日期。"
                             :action-label "清空搜索" :on-action (lambda () (setf (etaf-value query) "")))))
     (t
      (etaf-node 'column (list :item-gap '(lh 1) :width 'stretch)
                 (mapcar (lambda (entry)
                           (etaf-node 'etaf-ui-gallery--specimen
                                      (list :key (plist-get entry :name) :entry entry
                                            :documentation (cdr (assq (plist-get entry :name) documents))
                                            :state (cdr (assq (plist-get entry :name) (etaf-value states)))) nil))
                         entries))))))

(etaf-define-component etaf-ui-gallery--app (&key states documents)
  :bindings ((category (etaf-ref nil)) (query (etaf-ref "")) (mode (etaf-ref 'light))
             (generation (etaf-ref 0))
             (theme (etaf-computed (lambda () (etaf-theme-resolve-palette etaf-ui-gallery--palette (etaf-value mode))))))
  :setup
  (progn
    (etaf-theme-provide theme)
    (etaf-on-unmounted (lambda () (etaf-ui-gallery--dispose-states (etaf-value states)))))
  :render
  (let* ((viewport (etaf-viewport)) (cw (plist-get (etaf-display-metrics) :char-width))
         (wide (>= (/ (or (car viewport) (* 120 cw)) (float cw)) etaf-ui-gallery--sidebar-columns))
         (rows (max 24 (or (cdr viewport) 40))) (body-height (- rows (if wide 5 7)))
         (select (lambda (key)
                   (etaf-batch (setf (etaf-value category) key (etaf-value query) ""))
                   (etaf-scroll-to (etaf-runtime-for-buffer (current-buffer)) 'gallery-scroll 0)))
         (reset (lambda ()
                  (let ((old (etaf-value states)) (fresh (etaf-ui-gallery--create-states)))
                    (etaf-batch (setf (etaf-value states) fresh) (cl-incf (etaf-value generation)))
                    (etaf-ui-gallery--dispose-states old)))))
    (etaf-view
     (column :width '(vw 100) :height '(vh 100) :min-width '(ch 72) :overflow 'hidden :box-sizing 'border-box
             :color (etaf-theme-token :ui-fg) :background-color (etaf-theme-token :gallery-bg)
       (expr (unless wide
               (etaf-view
                (box :height '(lh 2) :padding '((lh 0) (ch 2)) :box-sizing 'border-box
                     :background-color (etaf-theme-token :ui-bg)
                  (etaf-label :text "ETAF UI Gallery" :variant 'strong)))))
       (flex :height '(lh 3) :box-sizing 'border-box :align-items 'center :column-gap '(ch 2) :padding '((lh 0) (ch 2))
             :background-color (etaf-theme-token :ui-bg)
             :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color (etaf-theme-token :ui-border)
         (expr (when wide (etaf-view (etaf-label :text "ETAF UI / Gallery" :variant 'strong :width '(ch 22)))))
         (expr (unless wide
                 (etaf-view (etaf-select :value category :label "组件分类" :hide-label t :presentation 'dropdown
                                         :options (cons '(nil . "组件总览") (mapcar (lambda (g) (cons (car g) (cadr g))) etaf-ui-gallery--groups))
                                         :on-change select))))
         (etaf-search-field :bind query :icon t :placeholder "搜索组件名称或用途" :ref 'gallery-search
                            :flex-grow 1 :flex-basis '(ch 26) :min-width '(ch 18))
         (etaf-segmented :bind mode :options '((light . "浅色") (dark . "深色"))))
       (flex :height (list 'lh body-height) :width 'stretch :box-sizing 'border-box
         (expr
          (when wide
            (etaf-view
             (column :width '(ch 24) :height 'stretch :box-sizing 'border-box :overflow 'scroll :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :background-color (etaf-theme-token :gallery-sidebar)
                     :border-right-width '(px 1) :border-right-style 'solid :border-right-color (etaf-theme-token :ui-border)
               (etaf-label :text "浏览组件" :variant 'muted)
               (etaf-button :label "组件总览" :variant 'ghost
                            :aria-selected (null (etaf-value category)) :on-press (lambda () (funcall select nil)))
               (expr
                (mapcar
                 (lambda (group)
                   (let ((key (car group)))
                     (etaf-view
                      (etaf-button :key key :label (nth 1 group)
                                   :variant 'ghost
                                   :aria-selected (eq key (etaf-value category))
                                   :color (etaf-theme-token (if (eq key (etaf-value category)) :ui-button-secondary-fg :ui-fg))
                                   :on-press (lambda () (funcall select key))))))
                 etaf-ui-gallery--groups))
               (etaf-divider)
               (etaf-label :text (format "8 类 · %d 个组件" (length etaf-ui-gallery--samples)) :variant 'muted)
               (etaf-label :text "本地示例，放心操作" :variant 'muted)))))
         (column :flex-grow 1 :flex-basis '(px 0) :min-width '(px 0) :height 'stretch :box-sizing 'border-box
           (flex :height '(lh 3) :box-sizing 'border-box :padding '((lh 0) (ch 2)) :align-items 'center :justify-content 'space-between
             (etaf-label :text (if (not (string-empty-p (etaf-value query))) "搜索结果"
                                 (or (cadr (assq (etaf-value category) etaf-ui-gallery--groups)) "组件总览")) :variant 'heading)
             (etaf-button :label "重置示例" :variant 'ghost :on-press reset))
           (column :ref 'gallery-scroll :height (list 'lh (- body-height 3)) :width 'stretch :box-sizing 'border-box
                   :overflow 'scroll :padding '((lh 0) (ch 2))
             (etaf-ui-gallery--results :category category :query query :states states :generation generation :on-select select :documents documents))))
       (box :height '(lh 2) :box-sizing 'border-box :padding '((lh 0) (ch 2)) :background-color (etaf-theme-token :ui-bg)
            :border-top-width '(px 1) :border-top-style 'solid :border-top-color (etaf-theme-token :ui-border)
         (etaf-label :text (if wide "Tab 切换控件    方向键 调整选项    Enter 操作    Esc 返回    ? 帮助"
                            "Tab 切换    Enter 操作    Esc 返回    ? 帮助") :variant 'muted))))))

(defvar-local etaf-ui-gallery--runtime nil
  "The Runtime this Gallery mounted, kept to recognize its own buffers.")

(defun etaf-ui-gallery-open (&optional buffer-or-name)
  "Open the complete component Gallery in BUFFER-OR-NAME and return it.
The default is *ETAF UI Gallery*.  Interactive calls display it.  Browse by
category or search, operate live specimens, switch the scoped light/dark
Theme, read parameter/callback reference and copy runnable examples.
Reference data is read from the installed public etaf-ui.el Commentary before
mounting.  Reopening resets this mount only.
An unrelated nonempty buffer is never replaced.  Kill or unmount to dispose."
  (interactive)
  (let* ((buffer (get-buffer-create (or buffer-or-name "*ETAF UI Gallery*")))
         (runtime (etaf-runtime-for-buffer buffer))
         (ours (buffer-local-value 'etaf-ui-gallery--runtime buffer))
         (documents (etaf-ui-gallery--read-documentation)))
    (when (or (and runtime (not (eq runtime ours)))
              (and (> (buffer-size buffer) 0) (not ours)))
      (user-error "Refusing to replace unrelated buffer contents"))
    (when runtime (etaf-unmount runtime))
    (with-current-buffer buffer
      (setq-local truncate-lines t)
      (setq-local buffer-display-table (copy-sequence (or buffer-display-table standard-display-table (make-display-table))))
      (set-display-table-slot buffer-display-table 'truncation ?\s))
    (let ((states (etaf-ref (etaf-ui-gallery--create-states))))
      (condition-case error
          (progn
            (etaf-mount buffer (etaf-view (etaf-ui-gallery--app :states states :documents documents)))
            (with-current-buffer buffer
              (setq etaf-ui-gallery--runtime (etaf-runtime-for-buffer buffer))))
        (error (etaf-ui-gallery--dispose-states (etaf-value states))
               (signal (car error) (cdr error)))))
    (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
    buffer))

(provide 'etaf-ui-gallery)
;;; etaf-ui-gallery.el ends here
