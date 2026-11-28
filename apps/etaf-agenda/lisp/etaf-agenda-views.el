;;; etaf-agenda-views.el --- Shell, topbar, rails, inspector and footer of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Composes the single-canvas ETAF shell: calm tonal topbar with search and
;; tabs, left area/project navigation rail, scrollable main stage, right
;; context panel / interactive entry inspector, and quiet bottom status/key
;; hint bar above the preserved Emacs mode-line.  Wires into ETAF's native
;; `:region', `M-g', `:on-direction' and `?` help modal contracts.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-agenda-theme)
(require 'etaf-agenda-layout)
(require 'etaf-agenda-model)
(require 'etaf-agenda-views-pages)

;;; ---------------------------------------------------------------------------
;;; Topbar (Appbar)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-search-box
    (&key value placeholder on-change on-submit on-clear)
  "Render a crisp 1px-bordered rectangular search input box."
  :bindings ((runtime (etaf-current-runtime)))
  :render
  (let ((text (or value "")))
    (etaf-view
     (flex :flex-direction 'row :align-items 'center
           :role 'search :width 'stretch :min-height '(lh 1)
           :padding '((lh 0) (ch 1)) :gap '((lh 0) (ch 1))
           :border (etaf-agenda-views--border :line)
           :pointer 'text
           :on-press (lambda ()
                       (when runtime
                         (ignore-errors (etaf-text-input-begin runtime 'etaf-agenda-search))))
       (box :flex-shrink 0 :color (etaf-agenda-color :muted)
         (etaf-ui-icon :name 'search :set 'svg :size 0.78 :min-width 1
                       :color (etaf-agenda-color :muted)))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
         (etaf-text-input :value text
                          :on-change on-change
                          :label (or placeholder "搜索")
                          :hide-label t
                          :placeholder (or placeholder "搜索任务、标签或项目…")
                          :variant 'plain
                          :width 'stretch
                          :on-submit on-submit
                          :ref 'etaf-agenda-search))
       (box :if (not (string-empty-p text))
            :flex-shrink 0 :color (etaf-agenda-color :muted) :pointer 'hand
         (etaf-ui-icon :name 'close :min-width 1 :color (etaf-agenda-color :muted)
                       :help-echo "清空搜索"
                       :on-press (lambda ()
                                   (when (and runtime (etaf-text-input-active-p runtime))
                                     (etaf-text-input-end 'blur))
                                   (when on-clear (funcall on-clear)))))
       (box :if (string-empty-p text)
            :flex-shrink 0 :color (etaf-agenda-color :dim)
         (text "/"))))))

(etaf-define-component etaf-agenda-tab (&key title view current compact on-switch)
  "Render a clean topbar tab with invariant box geometry across states."
  :view
  (let ((trim (list '(px 1) 'solid (etaf-agenda-color :bg))))
    (box :flex-shrink 0 :height '(lh 1)
         :padding (if compact '((lh 0) (ch 1)) '((lh 0) (ch 1)))
         :background-color (when current (etaf-agenda-color :accent-soft))
         :border-top trim
         :border-bottom trim
         :font-weight (if current 'bold 'normal)
         :color (if current (etaf-agenda-color :accent) (etaf-agenda-color :muted))
         :hover-style (unless current
                        (list :background-color (etaf-agenda-color :hover)
                              :color (etaf-agenda-color :ink)))
         :role 'tab :aria-selected (and current t) :tab-index 0
         :pointer (unless current 'hand)
         :on-press (lambda () (when (and on-switch (not current))
                                (funcall on-switch view)))
      (text title))))

(etaf-define-component etaf-agenda-topbar
    (&key plan on-switch-view on-switch-scope on-search-change on-search-submit
          on-search-clear on-new on-help)
  "Render the responsive topbar with brand/scope, tabs, search, new and help."
  :view
  (let* ((layout (plist-get plan :layout))
         (tier (plist-get layout :tier))
         (short-p (plist-get layout :short))
         (narrow (eq tier 'narrow))
         (view (plist-get plan :view))
         (search-val (plist-get plan :search-input)))
    (column :width 'stretch :flex-shrink 0 :item-gap '(lh 0)
            :border-bottom (etaf-agenda-views--border :line)
            :region '(:id search :label "搜索与顶栏" :key "f"
                          :enter etaf-agenda-search :neighbors (:down main))
      (unless short-p
        (box :height '(lh 1)))
      (cond
       ((not narrow)
        (flex :flex-direction 'row :align-items 'center
              :width 'stretch :min-height '(lh 1)
              :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 2))
          (cond
           ((eq tier 'wide)
            (flex :flex-direction 'row :align-items 'center :flex-shrink 0
                  :gap '((lh 0) (ch 1))
              (box :color (etaf-agenda-color :accent) :font-weight 'bold (text "◈"))
              (box :color (etaf-agenda-color :ink) :font-weight 'bold (text "Agenda"))))
           (t
            (flex :flex-direction 'row :align-items 'center :flex-shrink 0
                  :gap '((lh 0) (ch 1)) :role 'button :tab-index 0 :pointer 'hand
                  :help-echo "切换领域或项目筛选"
                  :on-press on-switch-scope
              (box :color (etaf-agenda-color :accent) (text "☰"))
              (box :color (etaf-agenda-color :ink) :font-weight 'bold
                   :hover-style (etaf-agenda-views--hover-text :accent)
                (text (plist-get plan :area-label)))
              (box :color (etaf-agenda-color :muted) (text "▾")))))
          (flex :flex-direction 'row :align-items 'center :flex-shrink 0
                :gap '((lh 0) (ch 1))
            (etaf-agenda-tab :for (spec etaf-agenda-views) :key (car spec)
                             :title (cadr spec) :view (car spec)
                             :current (eq (car spec) view)
                             :on-switch on-switch-view))
          (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 14)
            (etaf-agenda-search-box
             :value search-val
             :placeholder (if (eq tier 'wide) "搜索任务、标签或项目…" "搜索…")
             :on-change on-search-change
             :on-submit on-search-submit
             :on-clear on-search-clear))
          (box :flex-shrink 0 :height '(lh 1)
               :padding '((lh 0) (ch 1))
               :background-color (etaf-agenda-color :accent-soft)
               :border (etaf-agenda-views--border :accent)
               :color (etaf-agenda-color :accent) :font-weight 'bold
               :role 'button :tab-index 0 :pointer 'hand
               :help-echo "原位新建条目（a）"
               :on-press on-new
            (text "+ 新建"))
          (box :flex-shrink 0 :height '(lh 1)
               :padding '((lh 0) (ch 1))
               :border (etaf-agenda-views--border :line)
               :color (etaf-agenda-color :muted) :font-weight 'bold
               :hover-style (etaf-agenda-views--hover)
               :role 'button :tab-index 0 :pointer 'hand
               :help-echo "查看快捷键帮助（?）"
               :on-press on-help
            (text "?"))))
       (t
        (column :width 'stretch :item-gap '(lh 0)
          (flex :flex-direction 'row :align-items 'center
                :width 'stretch :height '(lh 1)
                :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 1))
            (flex :flex-direction 'row :align-items 'center :flex-shrink 0
                  :role 'button :tab-index 0 :pointer 'hand
                  :on-press on-switch-scope
              (box :color (etaf-agenda-color :ink) :font-weight 'bold
                   :hover-style (etaf-agenda-views--hover-text :accent)
                (text (format "☰ %s ▾"
                              (etaf-agenda-clip-text (plist-get plan :area-label) 8)))))
            (box :flex-grow 1 :flex-basis '(px 0) "")
            (flex :flex-direction 'row :align-items 'center :flex-shrink 0
              (etaf-agenda-tab :for (spec etaf-agenda-views) :key (car spec)
                               :title (cadr spec) :view (car spec)
                               :current (eq (car spec) view)
                               :compact t
                               :on-switch on-switch-view)))
          (flex :flex-direction 'row :align-items 'center
                :width 'stretch :height '(lh 1)
                :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 1))
            (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 10)
              (etaf-agenda-search-box :value search-val
                                      :placeholder "搜索任务或标签…"
                                      :on-change on-search-change
                                      :on-submit on-search-submit
                                      :on-clear on-search-clear))
            (box :flex-shrink 0 :height '(lh 1) :padding '((lh 0) (ch 1))
                 :background-color (etaf-agenda-color :accent-soft)
                 :border (etaf-agenda-views--border :accent)
                 :color (etaf-agenda-color :accent) :font-weight 'bold
                 :role 'button :tab-index 0 :pointer 'hand
                 :on-press on-new
              (text "+ 新建"))
            (box :flex-shrink 0 :height '(lh 1) :padding '((lh 0) (ch 1))
                 :border (etaf-agenda-views--border :line)
                 :color (etaf-agenda-color :muted)
                 :hover-style (etaf-agenda-views--hover)
                 :role 'button :tab-index 0 :pointer 'hand
                 :on-press on-help
              (text "?"))))))
      (box :height '(lh 1)))))

;;; ---------------------------------------------------------------------------
;;; Left Sidebar (Areas & Projects on subtle :surface)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-nav-item
    (&key icon icon-color title count-text active max-cols on-press)
  "Render one left-sidebar navigation item with `▎' flush at Col 0."
  :render
  (etaf-view
   (flex :flex-direction 'row :align-items 'center
         :width 'stretch :height '(lh 1)
         :padding '((lh 0) (ch 1) (lh 0) (ch 0))
         :background-color (when active (etaf-agenda-color :select))
         :role 'button :tab-index 0 :pointer (unless active 'hand)
         :on-press (unless active on-press)
     ;; Col 0: flush `▎' aligned dead-straight with `◈', `领域', `项目' & hairlines
     (box :width '(ch 1) :flex-shrink 0 :color (etaf-agenda-color :accent)
       (text (expr (if active "▎" ""))))
     ;; Col 1..2: flush-left icon cleanly indented 1ch under `领域' / `项目'
     (box :width '(ch 2) :flex-shrink 0
          :color (or icon-color (if active (etaf-agenda-color :accent)
                                  (etaf-agenda-color :muted)))
       (text (expr icon)))
     ;; Scope hover to the homogeneous label box so coloured area/project dots
     ;; and dim counts never get blackened by parent `mouse-face'.
     (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          :height '(lh 1) :wrap-mode 'none :overflow 'hidden
          :font-weight (if active 'bold 'normal)
          :color (if active (etaf-agenda-color :ink) (etaf-agenda-color :muted))
          :hover-style (unless active (etaf-agenda-views--hover-text :accent))
       (text (expr (etaf-agenda-clip-text title (max 8 (- (or max-cols 24) 10))))))
     (box :flex-shrink 0 :padding '((lh 0) (ch 0) (lh 0) (ch 1))
          :color (if active (etaf-agenda-color :ink) (etaf-agenda-color :dim))
       (text (expr count-text))))))

(etaf-define-component etaf-agenda-sidebar
    (&key plan on-select-area on-select-project on-add-area on-add-project)
  "Render the left sidebar aligned dead-straight under `◈ Agenda' at window Col 2."
  :render
  (let* ((sb (plist-get plan :sidebar))
         (sb-cols (plist-get (plist-get plan :layout) :sidebar-cols))
         (view (plist-get plan :view))
         (cur-area (plist-get plan :area))
         (cur-proj (and (eq view 'project) (plist-get plan :project)))
         (areas (plist-get sb :areas))
         (projects (plist-get sb :projects)))
    (etaf-view
     (column :width 'stretch :height 'stretch :min-height '(lh 0)
             :overflow 'scroll :item-gap '(lh 0)
             :padding '((lh 1) (ch 1) (lh 1) (ch 2))
             :region '(:id sidebar :label "领域与项目" :key "s"
                           :neighbors (:right main :up search))
             :focus-group 'vertical
       ;; Fixed perspectives
       (column :width 'stretch :item-gap '(lh 0)
         (etaf-agenda-nav-item
          :icon "▣" :title "全部"
          :count-text (number-to-string (plist-get sb :total))
          :active (and (not cur-proj) (eq cur-area 'all))
          :max-cols sb-cols
          :on-press (lambda () (when on-select-area (funcall on-select-area 'all))))
         (etaf-agenda-nav-item
          :icon "▤" :title "收件箱"
          :count-text (number-to-string (plist-get sb :inbox))
          :active (and (not cur-proj) (eq cur-area 'inbox))
          :max-cols sb-cols
          :on-press (lambda () (when on-select-area (funcall on-select-area 'inbox)))))
       (box :height '(lh 1))
       (etaf-agenda-hrule :color :line-soft)
       ;; Areas block (header flush at Col 0 with `▎' and `◈')
       (column :width 'stretch :item-gap '(lh 0)
         (flex :flex-direction 'row :align-items 'center
               :width 'stretch :height '(lh 1)
               :padding '((lh 0) (ch 1) (lh 0) (ch 0))
           (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :muted)
             (text "领域"))
           (box :flex-grow 1 :flex-basis '(px 0) "")
           (box :flex-shrink 0 :color (etaf-agenda-color :muted) :font-weight 'bold
                :role 'button :tab-index 0 :pointer 'hand
                :help-echo "新建领域（A）"
                :hover-style (etaf-agenda-views--hover-text :accent)
                :on-press on-add-area
             (text "+")))
         (expr
          (mapcar
           (lambda (pair)
             (let ((a (car pair)) (idx (cdr pair)))
               (etaf-view
                (etaf-agenda-nav-item
                 :icon "●" :icon-color (etaf-agenda-area-color idx)
                 :title (plist-get a :title)
                 :count-text (number-to-string (plist-get a :count))
                 :active (and (not cur-proj) (equal cur-area (plist-get a :id)))
                 :max-cols sb-cols
                 :on-press (lambda ()
                             (when on-select-area
                               (funcall on-select-area (plist-get a :id))))))))
           (cl-mapcar #'cons areas (number-sequence 0 (1- (length areas)))))))
       (box :height '(lh 1))
       (etaf-agenda-hrule :color :line-soft)
       ;; Projects header + add (flush at Col 0 with `▎' and `◈')
       (flex :flex-direction 'row :align-items 'center
             :width 'stretch :height '(lh 1)
             :padding '((lh 0) (ch 1) (lh 0) (ch 0))
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :muted)
           (text "项目"))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (box :flex-shrink 0 :color (etaf-agenda-color :muted) :font-weight 'bold
              :role 'button :tab-index 0 :pointer 'hand
              :help-echo "新建项目（P）"
              :hover-style (etaf-agenda-views--hover-text :accent)
              :on-press on-add-project
           (text "+")))
       (expr
        (if (null projects)
            (list (etaf-view
                   (box :padding '((lh 0) (ch 1)) :height '(lh 1)
                        :color (etaf-agenda-color :dim)
                     (text "暂无项目"))))
          (cl-mapcar
           (lambda (pr idx)
             (etaf-view
              (etaf-agenda-nav-item
               :icon "◆" :icon-color (etaf-agenda-area-color (1+ idx))
               :title (plist-get pr :title)
               :count-text (format "%d/%d" (plist-get pr :done) (plist-get pr :total))
               :active (equal cur-proj (plist-get pr :id))
               :max-cols sb-cols
               :on-press (lambda ()
                           (when on-select-project
                             (funcall on-select-project (plist-get pr :id)))))))
           projects
           (number-sequence 0 (1- (length projects))))))))))

;;; ---------------------------------------------------------------------------
;;; Right Rail: Context Panels (aligned with main baseline, strict 1:1 tiles)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-rail-today (&key plan on-toggle-habit)
  "Render Today's right rail with 1:1 habit tiles, week rhythm and heatmap."
  :render
  (let* ((habits (seq-take (plist-get plan :habits) 4))
         (hstats (plist-get plan :habit-stats))
         (day (plist-get plan :day))
         (wc (plist-get plan :week-counts))
         (rev (plist-get plan :review))
         (daily (plist-get rev :daily))
         (first-wd (or (plist-get rev :first-weekday) 0))
         (rl-cols (plist-get (plist-get plan :layout) :rail-cols))
         (name-budget (max 8 (- rl-cols 12))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0) :padding '((lh 1) (ch 2))
       ;; 1. Today's Habits block
       (column :width 'stretch :item-gap '(lh 0)
         (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
           (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
             (text "今日习惯"))
           (box :flex-grow 1 :flex-basis '(px 0) "")
           (box :flex-shrink 0 :color (etaf-agenda-color :ok)
             (text (expr (format "%d/%d 已打卡"
                                 (plist-get hstats :today-done)
                                 (plist-get hstats :total))))))
         (etaf-agenda-hrule :color :line-soft)
         (expr
          (if (null habits)
              (list (etaf-view (box :height '(lh 1) :color (etaf-agenda-color :dim)
                                 (text "还没有习惯，去习惯页按 a 新建"))))
            (apply
             #'append
             (cl-mapcar
              (lambda (h idx)
                (let* ((hid (plist-get h :id))
                       (tdone (plist-get h :today-done))
                       (last7 (last (plist-get h :cells) 7)))
                  (delq nil
                        (list
                         (when (> idx 0) (etaf-view (box :height '(lh 1))))
                         (etaf-view
                          (flex :flex-direction 'row :align-items 'center
                                :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
                                :role 'button :tab-index 0 :pointer 'hand
                                :on-press (lambda ()
                                            (when on-toggle-habit
                                              (funcall on-toggle-habit hid day)))
                            (box :width '(ch 2) :flex-shrink 0
                              (etaf-check-mark :state (if tdone 'done 'empty)
                                               :color (if tdone
                                                          (etaf-agenda-color :ok)
                                                        (etaf-agenda-color :accent))))
                            (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                                 :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                                 :color (if tdone (etaf-agenda-color :dim) (etaf-agenda-color :ink))
                                 :hover-style (etaf-agenda-views--hover-text :accent)
                              (text (expr (etaf-agenda-clip-text (plist-get h :title) name-budget))))
                            (box :flex-shrink 0 :color (etaf-agenda-color :muted)
                              (text (expr (format "%d/%d" (plist-get h :measured)
                                                  (plist-get h :target)))))))
                         ;; 7 strict 1:1 square tiles right under the title
                         (etaf-view
                          (flex :flex-direction 'row :align-items 'center
                                :width 'stretch :height '(lh 1) :padding '((lh 0) (ch 0) (lh 0) (ch 3))
                            (expr
                             (mapcar
                              (lambda (cell)
                                (let ((cdone (plist-get cell :done))
                                      (cday (plist-get cell :day)))
                                  (etaf-view
                                   (etaf-agenda-square-tile
                                    :filled (or cdone (not (equal cday day)))
                                    :color (cond (cdone (etaf-agenda-color :ok))
                                                 ((equal cday day) (etaf-agenda-color :accent))
                                                 (t (etaf-agenda-color :heat0)))
                                    :size 0.78
                                    :cell-cols 2
                                    :help (format "%s · %s（点击切换）"
                                                  (etaf-agenda--date-label cday)
                                                  (if cdone "已打卡" "未打卡"))
                                    :on-press (lambda ()
                                                (when on-toggle-habit
                                                  (funcall on-toggle-habit hid cday)))))))
                              last7))))))))
              habits
              (number-sequence 0 (1- (length habits))))))))
       (etaf-agenda-hrule :color :line-soft)
       ;; 2. Airy 3-column Week Rhythm (clean gap under title, no harsh column dividers)
       (column :width 'stretch :item-gap '(lh 0)
         (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
           (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
             (text "本周节奏"))
           (box :flex-grow 1 :flex-basis '(px 0) "")
           (box :flex-shrink 0 :color (etaf-agenda-color :dim)
             (text (expr (format "第 %d 周" (plist-get plan :week))))))
         (box :height '(lh 1))
         (flex :flex-direction 'row :width 'stretch
           (column :flex-grow 1 :flex-basis '(px 0) :cross-align 'center :item-gap '(lh 0)
             (box :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :ok)
               (text (expr (number-to-string (nth 0 wc)))))
             (box :height '(lh 1) :color (etaf-agenda-color :muted) (text "完成")))
           (column :flex-grow 1 :flex-basis '(px 0) :cross-align 'center :item-gap '(lh 0)
             (box :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :warning)
               (text (expr (number-to-string (nth 1 wc)))))
             (box :height '(lh 1) :color (etaf-agenda-color :muted) (text "迁移")))
           (column :flex-grow 1 :flex-basis '(px 0) :cross-align 'center :item-gap '(lh 0)
             (box :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :muted)
               (text (expr (number-to-string (nth 2 wc)))))
             (box :height '(lh 1) :color (etaf-agenda-color :muted) (text "放弃")))))
       (etaf-agenda-hrule :color :line-soft)
       ;; 3. Monthly weekday-aligned 7-col 1:1 square heatmap (centered cleanly)
       (column :width 'stretch :item-gap '(lh 0)
         (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
           (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
             (text (expr (format "%d 月活跃" (% (plist-get plan :month) 100)))))
           (box :flex-grow 1 :flex-basis '(px 0) "")
           (box :flex-shrink 0 :color (etaf-agenda-color :muted)
             (text (expr (format "%d 天有完成" (plist-get rev :active-days))))))
         (box :height '(lh 1))
         ;; 7-day calendar-aligned rows of strict 1:1 squares
         (expr
          (let* ((padded (append (make-list first-wd nil) daily))
                 (rem (% (length padded) 7))
                 (full (if (zerop rem) padded (append padded (make-list (- 7 rem) nil))))
                 (rows nil) (cursor full)
                 (tile-w (if (>= rl-cols 28) 3 2)))
            (while cursor
              (push (seq-take cursor 7) rows)
              (setq cursor (nthcdr 7 cursor)))
            (mapcar
             (lambda (wk)
               (etaf-view
                (flex :flex-direction 'row :align-items 'center :justify-content 'center
                      :width 'stretch :height '(lh 1)
                  (expr
                   (mapcar
                    (lambda (pair)
                      (if (null pair)
                          (etaf-view (box :width (list 'ch tile-w) :flex-shrink 0 :height '(lh 1) ""))
                        (etaf-view
                         (etaf-agenda-square-tile
                          :filled t
                          :color (etaf-agenda-views--heat-color (cdr pair))
                          :size 0.82
                          :cell-cols tile-w
                          :help (format "%s：完成 %d 项"
                                        (etaf-agenda--date-label (car pair))
                                        (cdr pair))))))
                    wk)))))
             (nreverse rows))))
         (box :height '(lh 1))
         (flex :flex-direction 'row :align-items 'center :justify-content 'center
               :width 'stretch :height '(lh 1)
           (box :color (etaf-agenda-color :dim) :padding '((lh 0) (ch 1) (lh 0) (ch 0)) (text "少"))
           (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat0) :size 0.72 :cell-cols 2)
           (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat1) :size 0.72 :cell-cols 2)
           (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat2) :size 0.72 :cell-cols 2)
           (etaf-agenda-square-tile :filled t :color (etaf-agenda-color :heat3) :size 0.72 :cell-cols 2)
           (box :color (etaf-agenda-color :dim) :padding '((lh 0) (ch 0) (lh 0) (ch 1)) (text "多"))))))))

(etaf-define-component etaf-agenda-rail-calendar
    (&key plan on-select on-toggle on-open on-new)
  "Render Calendar's right rail with timed events and tasks for the selected day."
  :render
  (let* ((drows (plist-get plan :day-rows))
         (events (plist-get drows :events))
         (tasks (plist-get drows :tasks))
         (rl-cols (plist-get (plist-get plan :layout) :rail-cols))
         (budget (max 10 (- rl-cols 11))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0) :padding '((lh 1) (ch 2))
       (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
             :padding '((lh 0) (ch 1) (lh 0) (ch 0))
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :ink)
           (text (expr (format "%s %s" (plist-get plan :day-label)
                               (plist-get plan :weekday-label)))))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (box :flex-shrink 0 :color (etaf-agenda-color :accent)
              :role 'button :tab-index 0 :pointer 'hand
              :hover-style (etaf-agenda-views--hover-text :ink)
              :on-press on-new
           (text "+ 记")))
       (etaf-agenda-hrule :color :line-soft)
       ;; Events
       (box :height '(lh 1) :padding '((lh 0) (ch 1) (lh 0) (ch 0))
            :font-weight 'bold :color (etaf-agenda-color :info)
         (text (expr (format "日程 · %d" (length events)))))
       (box :height '(lh 1))
       (expr
        (if (null events)
            (list (etaf-view (box :padding '((lh 0) (ch 1))
                                  :height '(lh 1) :color (etaf-agenda-color :dim)
                               (text "无排定日程"))))
          (mapcar
           (lambda (row)
             (let* ((rid (plist-get row :id))
                    (sel (equal (plist-get plan :selected) rid)))
               (etaf-view
                (flex :flex-direction 'row :align-items 'center
                      :width 'stretch :height '(lh 1)
                      :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                      :background-color (when sel (etaf-agenda-color :select))
                      :role 'button :tab-index 0 :pointer 'hand
                      :on-press (lambda ()
                                  (if sel
                                      (when on-open (funcall on-open rid))
                                    (when on-select (funcall on-select rid))))
                  (box :width '(ch 1) :flex-shrink 0 :color (etaf-agenda-color :accent)
                    (text (expr (if sel "▎" ""))))
                  (box :width '(ch 6) :flex-shrink 0 :color (etaf-agenda-color :info)
                    (text (expr (or (and (plist-get row :time-label)
                                         (substring (plist-get row :time-label) 0 5))
                                    "全天"))))
                  (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                       :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                       :color (etaf-agenda-color :ink)
                       :hover-style (unless sel (etaf-agenda-views--hover-text :accent))
                    (text (expr (etaf-agenda-clip-text (plist-get row :title) (max 8 (- budget 1))))))))))
           events)))
       (etaf-agenda-hrule :color :line-soft)
       ;; Tasks
       (box :height '(lh 1) :padding '((lh 0) (ch 1) (lh 0) (ch 0))
            :font-weight 'bold :color (etaf-agenda-color :accent)
         (text (expr (format "待办 · %d" (length tasks)))))
       (box :height '(lh 1))
       (expr
        (if (null tasks)
            (list (etaf-view (box :padding '((lh 0) (ch 1))
                                  :height '(lh 1) :color (etaf-agenda-color :dim)
                               (text "无待办条目"))))
          (mapcar
           (lambda (row)
             (let* ((rid (plist-get row :id))
                    (sel (equal (plist-get plan :selected) rid))
                    (done (plist-get row :done))
                    (prio (plist-get row :priority)))
               (etaf-view
                (flex :flex-direction 'row :align-items 'center
                      :width 'stretch :height '(lh 1)
                      :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                      :background-color (when sel (etaf-agenda-color :select))
                      :role 'button :tab-index 0 :pointer 'hand
                      :on-press (lambda ()
                                  (if sel
                                      (when on-open (funcall on-open rid))
                                    (when on-select (funcall on-select rid))))
                  (box :width '(ch 1) :flex-shrink 0 :color (etaf-agenda-color :accent)
                    (text (expr (if sel "▎" ""))))
                  (box :width '(ch 2) :flex-shrink 0 :pointer 'hand
                       :help-echo (if done "撤销完成（x）" "标记完成（x）")
                       :on-press (lambda () (when on-toggle (funcall on-toggle rid)))
                    (etaf-check-mark :state (if done 'done 'empty)
                                     :color (cond (done (etaf-agenda-color :ok))
                                                  ((eql prio 1) (etaf-agenda-color :danger))
                                                  (t (etaf-agenda-color :muted)))))
                  (box :width '(ch 1) :flex-shrink 0 "")
                  (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                       :height '(lh 1) :wrap-mode 'none :overflow 'hidden
                       :color (if done (etaf-agenda-color :dim) (etaf-agenda-color :ink))
                       :hover-style (unless sel (etaf-agenda-views--hover-text :accent))
                    (text (expr (etaf-agenda-clip-text (plist-get row :title) (+ budget 1)))))))))
           tasks)))))))

(etaf-define-component etaf-agenda-rail-kv (&key label value color)
  "Render one aligned label/value line inside a right rail."
  :render
  (etaf-view
   (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
         :gap '((lh 0) (ch 1))
     (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          :height '(lh 1) :wrap-mode 'none :overflow 'hidden
          :color (etaf-agenda-color :muted)
       (text (expr label)))
     (box :flex-shrink 0 :font-weight 'bold
          :color (or color (etaf-agenda-color :ink))
       (text (expr (if (stringp value) value (number-to-string (or value 0)))))))))

(etaf-define-component etaf-agenda-rail-context (&key plan on-toggle-habit on-select on-toggle on-open on-new)
  "Render the page-appropriate right rail context."
  :render
  (let* ((view (plist-get plan :view))
         (layout (plist-get plan :layout))
         (short-p (plist-get layout :short))
         (kv-gap (if short-p '(lh 0) '(lh 1)))
         (rl-cols (plist-get layout :rail-cols)))
    (etaf-view
     (expr
      (pcase view
        ('calendar
         (etaf-view (etaf-agenda-rail-calendar
                     :plan plan :on-select on-select
                     :on-toggle on-toggle :on-open on-open :on-new on-new)))
        ('list
         (let ((st (plist-get plan :list-stats)))
           (etaf-view
            (column :width 'stretch :item-gap '(lh 0) :padding '((lh 1) (ch 2))
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :ink)
                (text "清单统计"))
              (etaf-agenda-hrule :color :line-soft)
              (column :width 'stretch :item-gap kv-gap
                (etaf-agenda-rail-kv :label "全部条目" :value (plist-get st :all))
                (etaf-agenda-rail-kv :label "待完成" :value (plist-get st :open)
                                     :color (etaf-agenda-color :accent))
                (etaf-agenda-rail-kv :label "已完成" :value (plist-get st :done)
                                     :color (etaf-agenda-color :ok))
                (etaf-agenda-rail-kv :label "已逾期" :value (plist-get st :overdue)
                                     :color (if (> (plist-get st :overdue) 0)
                                                (etaf-agenda-color :danger)
                                              (etaf-agenda-color :muted)))
                (etaf-agenda-rail-kv :label "本周排期" :value (plist-get st :week))
                (etaf-agenda-rail-kv :label "无日期" :value (plist-get st :undated)))
              (etaf-agenda-hrule :color :line-soft)
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :muted)
                (text "按领域分布"))
              (box :height '(lh 1))
              (column :width 'stretch :item-gap kv-gap
                (expr
                 (mapcar (lambda (pair)
                           (etaf-view (etaf-agenda-rail-kv :label (car pair) :value (cdr pair))))
                         (plist-get st :areas))))))))
        ('project
         (let* ((proj (plist-get plan :project-plan))
                (stages (plist-get proj :stages))
                (bar-w (max 10 (- rl-cols 4))))
           (etaf-view
            (column :width 'stretch :item-gap '(lh 0) :padding '((lh 1) (ch 2))
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :ink)
                (text "项目概览"))
              (etaf-agenda-hrule :color :line-soft)
              (column :width 'stretch :item-gap kv-gap
                (etaf-agenda-rail-kv :label "已完成" :value (plist-get proj :done)
                                     :color (etaf-agenda-color :ok))
                (etaf-agenda-rail-kv :label "进行中" :value (plist-get proj :open)
                                     :color (etaf-agenda-color :accent))
                (etaf-agenda-rail-kv :label "已逾期" :value (plist-get proj :overdue)
                                     :color (if (> (or (plist-get proj :overdue) 0) 0)
                                                (etaf-agenda-color :danger)
                                              (etaf-agenda-color :muted)))
                (etaf-agenda-rail-kv :label "阶段数" :value (length stages)))
              (etaf-agenda-hrule :color :line-soft)
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :muted)
                (text "阶段进度"))
              (box :height '(lh 1))
              (expr
               (apply
                #'append
                (cl-mapcar
                 (lambda (s idx)
                   (delq nil
                         (list
                          (when (> idx 0) (etaf-view (box :height '(lh 1))))
                          (etaf-view
                           (etaf-agenda-rail-kv
                            :label (etaf-agenda-clip-text (plist-get s :title) (- rl-cols 10))
                            :value (format "%d/%d" (plist-get s :done) (plist-get s :count))))
                          (etaf-view
                           (etaf-agenda-hbar
                            :ratio (/ (float (or (plist-get s :progress) 0)) 100.0)
                            :width bar-w :color (etaf-agenda-color :ok))))))
                 stages
                 (number-sequence 0 (1- (length stages))))))))))
        ('habits
         (let* ((hs (plist-get plan :habit-stats))
                (bar-w (max 10 (- rl-cols 4)))
                (name-w (max 8 (- rl-cols 11))))
           (etaf-view
            (column :width 'stretch :item-gap '(lh 0) :padding '((lh 1) (ch 2))
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :ink)
                (text "本周达标率"))
              (etaf-agenda-hrule :color :line-soft)
              (etaf-agenda-hbar :ratio (/ (float (plist-get hs :rate)) 100.0)
                                :width bar-w :color (etaf-agenda-color :ok))
              (box :if (not short-p) :height '(lh 1))
              (etaf-agenda-rail-kv :label (format "%d / %d 次"
                                                  (plist-get hs :done)
                                                  (plist-get hs :due))
                                   :value (format "%d%%" (plist-get hs :rate))
                                   :color (etaf-agenda-color :ok))
              (etaf-agenda-hrule :color :line-soft)
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :muted)
                (text "当前连击榜"))
              (box :height '(lh 1))
              (column :width 'stretch :item-gap kv-gap
                (expr
                 (mapcar
                  (lambda (pair)
                    (etaf-view
                     (etaf-agenda-rail-kv
                      :label (etaf-agenda-clip-text (car pair) name-w)
                      :value (format "%d 天" (cdr pair))
                      :color (if (> (cdr pair) 0)
                                 (etaf-agenda-color :warning)
                               (etaf-agenda-color :dim)))))
                  (seq-take (plist-get hs :best) 5))))))))
        ('review
         (let* ((rev (plist-get plan :review))
                (blank (plist-get rev :blank)))
           (etaf-view
            (column :width 'stretch :item-gap '(lh 0) :padding '((lh 1) (ch 2))
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :ink)
                (text "效率洞察"))
              (etaf-agenda-hrule :color :line-soft)
              (column :width 'stretch :item-gap kv-gap
                (etaf-agenda-rail-kv :label "本月完成率"
                                     :value (format "%d%%" (plist-get rev :completion-rate))
                                     :color (etaf-agenda-color :ok))
                (etaf-agenda-rail-kv :label "拖延迁移率"
                                     :value (format "%d%%" (plist-get rev :migrate-rate))
                                     :color (etaf-agenda-color :warning))
                (etaf-agenda-rail-kv :label "习惯达标率"
                                     :value (format "%d%%" (plist-get rev :habit-rate))
                                     :color (etaf-agenda-color :accent))
                (etaf-agenda-rail-kv :label "最长活跃连击"
                                     :value (format "%d 天" (plist-get rev :longest-streak))
                                     :color (etaf-agenda-color :info))
                (etaf-agenda-rail-kv :label "空白日数"
                                     :value (format "%d 天" (length blank))
                                     :color (etaf-agenda-color :muted)))
              (etaf-agenda-hrule :color :line-soft)
              (box :width 'stretch :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :muted)
                (text "空白日"))
              (box :height '(lh 1))
              (box :color (etaf-agenda-color :muted) :wrap-mode 'word
                (text (expr (if blank
                                (concat (mapconcat #'identity (seq-take blank 8) " · ")
                                        (if (> (length blank) 8) " …" ""))
                              "本月每天都有记录"))))))))
        (_
         (etaf-view (etaf-agenda-rail-today :plan plan :on-toggle-habit on-toggle-habit))))))))

;;; ---------------------------------------------------------------------------
;;; Right Rail: Interactive Inspector (editable fields, body notes & logs)
;;; ---------------------------------------------------------------------------

(defun etaf-agenda-views--log-label (event)
  "Return Chinese label for audit log EVENT."
  (cond
   ((string-prefix-p "status:" (or event ""))
    (let ((st (substring event 7)))
      (format "状态 → %s" (or (cdr (assoc st etaf-agenda-status-labels)) st))))
   (t
    (pcase event
      ("created" "创建条目")
      ("done" "标记完成")
      ("reopened" "撤销完成")
      ((or "migrated" "moved") "迁移日期")
      ("pulled-back" "迁回本日")
      ("rescheduled" "调整计划日")
      ("dropped" "标记放弃")
      ("deleted" "软删除")
      ("status" "变更状态")
      ("priority" "变更优先级")
      ("title" "修改标题")
      ("body" "更新备注")
      (_ (or event ""))))))

(etaf-define-component etaf-agenda-inspector-field
    (&key label value color bg on-press)
  "Render one clickable property row in the Inspector.
Static field labels stay calm and coloured semantic pills retain their
own tint; only plain editable value text takes hover highlight."
  :render
  (etaf-view
   (flex :flex-direction 'row :align-items 'center
         :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
         :role (when on-press 'button) :tab-index (when on-press 0)
         :pointer (when on-press 'hand)
         :on-press on-press
     (box :width '(ch 6) :flex-shrink 0 :color (etaf-agenda-color :muted)
       (text (expr label)))
     (expr
      (if bg
          (etaf-view (etaf-agenda-pill :text value :fg color :bg bg :bold t))
        (etaf-view
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :height '(lh 1) :wrap-mode 'none :overflow 'hidden
              :color (or color (etaf-agenda-color :ink))
              :hover-style (when on-press (etaf-agenda-views--hover-text :accent))
           (text (expr value)))))))))

(etaf-define-component etaf-agenda-inspector
    (&key model plan on-close on-set-kind on-cycle-status on-cycle-priority
          on-edit-title on-edit-submit on-edit-cancel
          on-pick-scheduled on-pick-deadline on-pick-time
          on-pick-estimate on-pick-area on-pick-project on-pick-tags
          on-pick-recurrence on-edit-body on-submit-body on-cancel-body
          on-toggle on-delete)
  "Render the interactive Entry Inspector in the right rail."
  :render
  (let* ((e (plist-get plan :inspector-entry))
         (id (plist-get e :id))
         (kind (plist-get e :kind))
         (status (plist-get e :status))
         (prio (plist-get e :priority))
         (done (equal status "done"))
         (body (or (plist-get e :body) ""))
         (title-editing (equal (plist-get plan :editing) id))
         (body-editing (plist-get plan :inspector-body-editing))
         (logs (plist-get plan :inspector-logs))
         (sched (plist-get e :scheduled))
         (dl (plist-get e :deadline))
         (time-str (etaf-agenda--time-range-label (plist-get e :at) (plist-get e :end-at)))
         (est (etaf-agenda--duration-label (plist-get e :estimate)))
         (rec (plist-get e :recurrence))
         (rl-cols (plist-get (plist-get plan :layout) :rail-cols))
         (val-budget (max 10 (- rl-cols 11)))
         (proj-raw (cond
                    ((and (plist-get e :project-name) (plist-get e :stage-name))
                     (format "%s / %s" (plist-get e :project-name) (plist-get e :stage-name)))
                    ((plist-get e :project-name))
                    (t "无")))
         (proj-label (etaf-agenda-clip-text proj-raw val-budget))
         (pushes (or (plist-get e :pushes) 0))
         (history-meta (if (> pushes 0)
                           (format "建于 %s · 推 %d" (plist-get e :created) pushes)
                         (format "建于 %s" (plist-get e :created))))
         (status-label (or (cdr (assoc status etaf-agenda-status-labels)) "待办"))
         (prio-label (pcase prio (1 "P1 紧急 ▾") (2 "P2 重要 ▾") (3 "P3 普通 ▾") (_ "无 ▾"))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 0) :padding '((lh 1) (ch 2))
       ;; Header: ‹ 返回 | 条目详情
       (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :accent)
              :role 'button :tab-index 0 :pointer 'hand
              :hover-style (etaf-agenda-views--hover-text :ink)
              :on-press on-close
           (text "‹ 返回"))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (box :flex-shrink 0 :color (etaf-agenda-color :muted)
           (text "条目详情")))
       (etaf-agenda-hrule :color :line-soft)
       ;; Kind switcher pills
       (flex :flex-direction 'row :width 'stretch :gap '((lh 0) (ch 1))
         (expr
          (mapcar
           (lambda (pair)
             (let ((k (car pair)) (lbl (cdr pair)) (act (equal kind (car pair))))
               (etaf-view
                (box :flex-grow 1 :flex-basis '(px 0) :height '(lh 1)
                     :text-align 'center
                     :background-color (when act (etaf-agenda-color :accent-soft))
                     :border (etaf-agenda-views--border (if act :accent :line))
                     :color (if act (etaf-agenda-color :accent) (etaf-agenda-color :muted))
                     :font-weight (if act 'bold 'normal)
                     :hover-style (unless act (etaf-agenda-views--hover))
                     :role 'button :tab-index 0 :pointer (unless act 'hand)
                     :on-press (lambda () (when (and on-set-kind (not act))
                                            (funcall on-set-kind id k)))
                  (text (expr lbl))))))
           '(("task" . "待办") ("event" . "日程") ("note" . "记录")))))
       (box :height '(lh 1))
       ;; Clickable title card — edits inline right inside Inspector across all views!
       (expr
        (if title-editing
            (etaf-view
             (box :width 'stretch :padding '((lh 0) (ch 1))
                  :border (etaf-agenda-views--border :accent)
               (etaf-text-input :bind (plist-get model :edit-draft)
                                :label "编辑标题"
                                :hide-label t
                                :variant 'plain
                                :width 'stretch
                                :ref 'etaf-agenda-edit
                                :on-submit on-edit-submit
                                :on-cancel on-edit-cancel)))
          (etaf-view
           (box :width 'stretch :padding '((lh 0) (ch 1))
                :border (etaf-agenda-views--border :line)
                :font-weight 'bold :color (etaf-agenda-color :ink) :wrap-mode 'word
                :role 'button :tab-index 0 :pointer 'hand
                :help-echo "点击或按 e 修改标题"
                :on-press (lambda () (when on-edit-title (funcall on-edit-title id)))
             (text (expr (plist-get e :title)))))))
       (box :height '(lh 1))
       ;; Interactive property rows grouped cleanly into 3 breathable blocks
       (etaf-agenda-inspector-field
        :label "状态" :value (concat status-label " ▾")
        :color (cond (done (etaf-agenda-color :ok))
                     ((equal status "doing") (etaf-agenda-color :info))
                     ((equal status "waiting") (etaf-agenda-color :warning))
                     (t (etaf-agenda-color :ink)))
        :bg (cond (done (etaf-agenda-color :ok-soft))
                  ((equal status "doing") (etaf-agenda-color :info-soft))
                  ((equal status "waiting") (etaf-agenda-color :warning-soft))
                  (t (etaf-agenda-color :surface2)))
        :on-press (lambda () (when on-cycle-status (funcall on-cycle-status id))))
       (etaf-agenda-inspector-field
        :label "优先级" :value prio-label
        :color (pcase prio
                 (1 (etaf-agenda-color :danger))
                 (2 (etaf-agenda-color :warning))
                 (_ (etaf-agenda-color :muted)))
        :bg (pcase prio
              (1 (etaf-agenda-color :danger-soft))
              (2 (etaf-agenda-color :warning-soft))
              (_ (etaf-agenda-color :surface2)))
        :on-press (lambda () (when on-cycle-priority (funcall on-cycle-priority id))))
       (box :height '(lh 1))
       (etaf-agenda-inspector-field
        :label "计划日"
        :value (if sched (etaf-agenda--date-label sched) "未排期")
        :on-press (lambda () (when on-pick-scheduled (funcall on-pick-scheduled id))))
       (etaf-agenda-inspector-field
        :if (or time-str (equal kind "event"))
        :label "时间段"
        :value (or time-str "—")
        :color (if time-str (etaf-agenda-color :info) (etaf-agenda-color :dim))
        :on-press (lambda () (when on-pick-time (funcall on-pick-time id))))
       (etaf-agenda-inspector-field
        :label "截止日"
        :value (if dl (etaf-agenda--date-label dl) "—")
        :color (if dl (etaf-agenda-color :warning) (etaf-agenda-color :dim))
        :on-press (lambda () (when on-pick-deadline (funcall on-pick-deadline id))))
       (etaf-agenda-inspector-field
        :label "预估"
        :value (or est "—")
        :on-press (lambda () (when on-pick-estimate (funcall on-pick-estimate id))))
       (etaf-agenda-inspector-field
        :if (not (member kind '("note" "question")))
        :label "重复"
        :value (or (cdr (assoc rec etaf-agenda-recurrence-labels))
                   (and (plist-get e :habit-target)
                        (format "%d 天/周" (plist-get e :habit-target)))
                   "不重复")
        :color (if (or rec (plist-get e :habit-target))
                   (etaf-agenda-color :ink)
                 (etaf-agenda-color :dim))
        :on-press (lambda () (when on-pick-recurrence (funcall on-pick-recurrence id))))
       (box :height '(lh 1))
       (etaf-agenda-inspector-field
        :label "领域"
        :value (concat "● " (plist-get e :area-name) " ▾")
        :color (etaf-agenda-color :info)
        :on-press (lambda () (when on-pick-area (funcall on-pick-area id))))
       (etaf-agenda-inspector-field
        :label "项目"
        :value proj-label
        :on-press (lambda () (when on-pick-project (funcall on-pick-project id))))
       (etaf-agenda-inspector-field
        :label "标签"
        :value (if (string-empty-p (plist-get e :tags)) "+ 添加标签"
                 (concat (mapconcat (lambda (tag) (concat "#" tag))
                                    (split-string (plist-get e :tags) " " t) " ")
                         " +"))
        :color (if (string-empty-p (plist-get e :tags))
                   (etaf-agenda-color :dim)
                 (etaf-agenda-color :accent))
        :on-press (lambda () (when on-pick-tags (funcall on-pick-tags id))))
       ;; Notes Body (:body column)
       (etaf-agenda-hrule :color :line-soft)
       (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :muted) (text "备注"))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (expr
          (if body-editing
              (list
               (etaf-view
                (box :flex-shrink 0 :color (etaf-agenda-color :ok) :font-weight 'bold
                     :padding '((lh 0) (ch 1) (lh 0) (ch 0))
                     :role 'button :tab-index 0 :pointer 'hand
                     :hover-style (etaf-agenda-views--hover-text :ink)
                     :on-press (lambda ()
                                 (when on-submit-body
                                   (funcall on-submit-body
                                            (etaf-value (plist-get model :inspector-body-draft)))))
                  (text "保存")))
               (etaf-view
                (box :flex-shrink 0 :color (etaf-agenda-color :muted)
                     :role 'button :tab-index 0 :pointer 'hand
                     :hover-style (etaf-agenda-views--hover-text :ink)
                     :on-press on-cancel-body
                  (text "取消"))))
            (list
             (etaf-view
              (box :flex-shrink 0 :color (etaf-agenda-color :accent)
                   :role 'button :tab-index 0 :pointer 'hand
                   :hover-style (etaf-agenda-views--hover-text :ink)
                   :on-press on-edit-body
                (text "编辑")))))))
       (box :height '(lh 1))
       (expr
        (if body-editing
            (etaf-view
             (box :width 'stretch :padding '((lh 0) (ch 1))
                  :border (etaf-agenda-views--border :accent)
               (etaf-text-input :bind (plist-get model :inspector-body-draft)
                                :label "备注"
                                :hide-label t
                                :rows 3
                                :variant 'plain
                                :width 'stretch
                                :placeholder "输入备注，C-c C-c 保存，Esc 退出…"
                                :ref 'etaf-agenda-body-edit
                                :on-submit on-submit-body
                                :on-cancel on-cancel-body)))
          (etaf-view
           (box :width 'stretch :min-height '(lh 2) :padding '((lh 0) (ch 1))
                :border (etaf-agenda-views--border :line-soft)
                :color (if (string-empty-p body) (etaf-agenda-color :dim)
                         (etaf-agenda-color :muted))
                :wrap-mode 'word
                :role 'button :tab-index 0 :pointer nil
                :help-echo "点击编辑备注说明"
                :on-press on-edit-body
             (text (expr (if (string-empty-p body) "点击添加备注说明…" body)))))))
       ;; Operation Logs (:logs table)
       (etaf-agenda-hrule :color :line-soft)
       (flex :flex-direction 'row :align-items 'center :width 'stretch :height '(lh 1)
         (box :flex-shrink 0 :font-weight 'bold :color (etaf-agenda-color :muted)
           (text "历史记录"))
         (box :flex-grow 1 :flex-basis '(px 0) "")
         (box :flex-shrink 0 :color (etaf-agenda-color :dim)
           (text (expr history-meta))))
       (box :height '(lh 1))
       (expr
        (mapcar
         (lambda (log)
           (let ((at (plist-get log :at)))
             (etaf-view
              (box :height '(lh 1) :color (etaf-agenda-color :dim)
                   :wrap-mode 'none :overflow 'hidden
                (text (expr (format "%s  %s"
                                    (if (integerp at)
                                        (format-time-string "%m-%d %H:%M" (seconds-to-time at))
                                      "—")
                                    (etaf-agenda-views--log-label (plist-get log :event)))))))))
         (seq-take logs 4)))
       ;; Bottom primary actions
       (box :height '(lh 1))
       (flex :flex-direction 'row :width 'stretch :gap '((lh 0) (ch 1))
         (box :flex-grow 1 :flex-basis '(px 0) :height '(lh 1) :text-align 'center
              :background-color (etaf-agenda-color :ok-soft)
              :border (etaf-agenda-views--border :ok)
              :color (etaf-agenda-color :ok) :font-weight 'bold
              :role 'button :tab-index 0 :pointer 'hand
              :on-press (lambda () (when on-toggle (funcall on-toggle id)))
           (text (expr (if done "撤销完成" "✓ 完成"))))
         (box :flex-grow 1 :flex-basis '(px 0) :height '(lh 1) :text-align 'center
              :background-color (etaf-agenda-color :danger-soft)
              :border (etaf-agenda-views--border :danger)
              :color (etaf-agenda-color :danger)
              :role 'button :tab-index 0 :pointer 'hand
              :on-press (lambda () (when on-delete (funcall on-delete id)))
           (text "删除")))))))

;;; ---------------------------------------------------------------------------
;;; Bottom Status & Quiet Key Hint Bar (maillist style)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-hint (&key caps label)
  "Render one quiet KEY + LABEL pair in the bottom bar."
  :view
  (flex :flex-direction 'row :flex-shrink 0 :height '(lh 1) :align-items 'center
        :gap '((lh 0) (ch 0.5))
    (box :height '(lh 1) :font-weight 'bold :color (etaf-agenda-color :accent)
      (text caps))
    (box :height '(lh 1) :color (etaf-agenda-color :muted)
      (text label))))

(etaf-define-component etaf-agenda-footer (&key plan ui-store)
  "Render the single-line bottom status and contextual key hint bar."
  :view
  (let* ((cols (plist-get plan :width))
         (view (plist-get plan :view))
         (msg (if ui-store
                  (etaf-store-get ui-store :notice :message)
                (plist-get plan :message)))
         (counts (plist-get plan :counts))
         (status-left
          (cond
           (msg msg)
           ((not (string-empty-p (or (plist-get plan :query) "")))
            (format "搜索「%s」" (plist-get plan :query)))
           ((plist-get plan :inspector-entry)
            (format "详情：%s"
                    (etaf-agenda-clip-text
                     (plist-get (plist-get plan :inspector-entry) :title) 28)))
           ((eq view 'today)
            (format "%s · 今日 %d/%d 完成%s"
                    (plist-get plan :area-label)
                    (plist-get counts :done)
                    (+ (plist-get counts :open) (plist-get counts :done))
                    (if (> (plist-get counts :overdue) 0)
                        (format " · %d 项逾期" (plist-get counts :overdue))
                      "")))
           ((eq view 'calendar)
            (format "%s %s · %d 场日程 · %d 条待办"
                    (plist-get plan :day-label)
                    (plist-get plan :weekday-label)
                    (plist-get counts :events)
                    (+ (plist-get counts :open) (plist-get counts :done))))
           ((eq view 'habits)
            (let ((hs (plist-get plan :habit-stats)))
              (format "%d 个习惯 · 本周 %d/%d (%d%%)"
                      (plist-get hs :total) (plist-get hs :done)
                      (plist-get hs :due) (plist-get hs :rate))))
           ((eq view 'review)
            (format "%s 复盘 · 完成率 %d%%"
                    (plist-get plan :month-label)
                    (plist-get (plist-get plan :review) :completion-rate)))
           (t (plist-get plan :area-label))))
         (hints
          (cond
           ((plist-get plan :inspector-entry)
            '(("e" . "标题") ("s" . "状态") ("!" . "优") ("x" . "完成")
              ("Esc" . "返回") ("?" . "帮助")))
           ((eq view 'calendar)
            (let ((cmode (plist-get plan :calendar-mode)))
              (list (cons "←↓↑→" (if (eq cmode 'year) "移月" "移日"))
                    (cons "[/]" (pcase cmode ('year "切年") ('week "切周") (_ "切月")))
                    '("w" . "年/月/周") '("a" . "新建") '("RET" . "详情") '("?" . "帮助"))))
           ((eq view 'habits)
            '(("j/k" . "选习惯") ("←/→" . "补卡日") ("x" . "打卡")
              ("a" . "新习惯") ("?" . "帮助")))
           ((eq view 'list)
            '(("j/k" . "移动") ("g" . "换分组") ("x" . "完成")
              ("a" . "新建") ("/" . "搜索") ("?" . "帮助")))
           ((eq view 'project)
            '(("j/k" . "移动") ("a" . "新任务") ("A" . "新阶段")
              ("x" . "完成") ("RET" . "详情") ("?" . "帮助")))
           ((eq view 'review)
            '(("[/]" . "切月") ("t" . "本月") ("1-6" . "切页") ("?" . "帮助")))
           (t
            (if (>= cols 120)
                '(("j/k" . "移动") ("x" . "完成") ("a" . "新建") ("e" . "编辑")
                  ("RET" . "详情") ("m" . "迁移") ("u" . "撤销") ("/" . "搜索")
                  ("M-g" . "切区") ("?" . "帮助"))
              '(("j/k" . "移") ("x" . "完") ("a" . "建") ("RET" . "详") ("?" . "帮助")))))))
    (flex :flex-direction 'row :align-items 'center
          :width 'stretch :height '(lh 1) :flex-shrink 0
          :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 2))
          :border-top (etaf-agenda-views--border :line)
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 8)
           :height '(lh 1) :wrap-mode 'none :overflow 'hidden
           :color (if msg (etaf-agenda-color :accent) (etaf-agenda-color :muted))
        (text status-left))
      (flex :flex-direction 'row :align-items 'center :flex-shrink 0
            :gap '((lh 0) (ch 1)) :overflow 'hidden
        (etaf-agenda-hint :for (pair hints) :key (car pair)
                          :caps (car pair) :label (cdr pair))))))

;;; ---------------------------------------------------------------------------
;;; Root Application Shell
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-agenda-shell (&key model keys help actions)
  "Render the complete single-canvas Agenda application."
  :setup
  (progn
    (etaf-theme-provide (etaf-agenda-theme))
    (etaf-watch
     (plist-get model :drafting)
     (lambda (value _old)
       (when (and value (etaf-current-runtime))
         (ignore-errors (etaf-text-input-begin (etaf-current-runtime) 'etaf-agenda-draft))))
     :flush 'post :name 'etaf-agenda-draft-focus)
    (etaf-watch
     (plist-get model :editing)
     (lambda (value _old)
       (when (and value (etaf-current-runtime))
         (ignore-errors (etaf-text-input-begin (etaf-current-runtime) 'etaf-agenda-edit))))
     :flush 'post :name 'etaf-agenda-edit-focus)
    (etaf-watch
     (plist-get model :inspector-body-editing)
     (lambda (value _old)
       (when (and value (etaf-current-runtime))
         (ignore-errors (etaf-text-input-begin (etaf-current-runtime) 'etaf-agenda-body-edit))))
     :flush 'post :name 'etaf-agenda-body-focus)
    nil)
  :render
  (let* ((plan (etaf-agenda-plan model))
         (layout (plist-get plan :layout))
         (char-px (max 1 (etaf-agenda-char-pixel-width (etaf-current-runtime))))
         (width-px (max (* 35 char-px)
                        (or (plist-get plan :width-px)
                            (* (plist-get plan :width) char-px))))
         (rows (max 12 (plist-get plan :height)))
         (show-sb (plist-get layout :show-sidebar))
         (show-main (plist-get layout :show-main))
         (show-rail (plist-get layout :show-rail))
         (sb-cols (plist-get layout :sidebar-cols))
         (rl-cols (plist-get layout :rail-cols))
         (sb-px (* sb-cols char-px))
         (rl-px (* rl-cols char-px))
         (pad-ch (if (eq (plist-get plan :view) 'calendar)
                     (plist-get layout :cal-pad)
                   (plist-get layout :center-pad)))
         (view (plist-get plan :view))
         (on-dir (plist-get actions :on-direction)))
    (etaf-view
     (flex :flex-direction 'column
           :width (list 'px width-px)
           :height (list 'lh rows)
           :box-sizing 'border-box :overflow 'hidden
           :color (etaf-agenda-color :ink)
           :keys keys
           :help help
           :on-dismiss (plist-get actions :on-dismiss)
       ;; 1. Topbar (plain Emacs background + 1 empty breathing line on top)
       (etaf-agenda-topbar
        :plan plan
        :on-switch-view (plist-get actions :on-switch-view)
        :on-switch-scope (plist-get actions :on-switch-scope)
        :on-search-change (plist-get actions :on-search-change)
        :on-search-submit (plist-get actions :on-search-submit)
        :on-search-clear (plist-get actions :on-search-clear)
        :on-new (plist-get actions :on-new)
        :on-help (plist-get actions :on-help))
       ;; 2. Main 1/2/3-pane body separated only by `etaf-pane-resizer' hairlines
       (flex :flex-direction 'row :align-items 'stretch
             :width 'stretch :flex-grow 1 :flex-basis '(px 0)
             :min-height '(lh 0) :overflow 'hidden
         ;; Left sidebar (wide only)
         (box :if show-sb :width (list 'px sb-px) :height 'stretch
              :flex-shrink 0 :overflow 'hidden
           (etaf-agenda-sidebar
            :plan plan
            :on-select-area (plist-get actions :on-select-area)
            :on-select-project (plist-get actions :on-select-project)
            :on-add-area (plist-get actions :on-add-area)
            :on-add-project (plist-get actions :on-add-project)))
         ;; Left thin draggable hairline (shared `etaf-pane-resizer' like maillist)
         (etaf-pane-resizer
          :if show-sb
          :ref 'agenda-sidebar-resizer
          :side 'right
          :size sb-px
          :min (* 18 char-px)
          :max (* 34 char-px)
          :on-change (lambda (px)
                       (etaf-set-value (plist-get model :sidebar-width)
                                       (max 18 (min 34 (round (/ (float px) char-px))))))
          :on-end (lambda (px)
                    (let ((cols (max 18 (min 34 (round (/ (float px) char-px))))))
                      (etaf-set-value (plist-get model :sidebar-width) cols)
                      (ignore-errors
                        (etaf-agenda--store-meta-set (plist-get model :store)
                                                     "sidebar-width"
                                                     (number-to-string cols))))))
         ;; Center scrollable stage (plain Emacs background)
         (column :if show-main
                 :flex-grow 1 :flex-basis '(px 0) :min-width '(ch 0)
                 :height 'stretch :min-height '(lh 0) :overflow 'scroll
                 :padding (list '(lh 1) (list 'ch pad-ch))
                 :region '(:id main :label "主工作区" :key "m"
                               :neighbors (:left sidebar :right rail :up search))
                 :on-direction on-dir
                 :ref 'etaf-agenda-main
           (expr
            (pcase view
              ('calendar
               (etaf-view
                (etaf-agenda-calendar-page
                 :model model :plan plan
                 :on-pick-day (plist-get actions :on-pick-day)
                 :on-zoom-month (plist-get actions :on-zoom-month)
                 :on-prev-month (plist-get actions :on-prev-month)
                 :on-next-month (plist-get actions :on-next-month)
                 :on-today (plist-get actions :on-today)
                 :on-mode (plist-get actions :on-calendar-mode)
                 :on-draft-submit (plist-get actions :on-draft-submit)
                 :on-draft-cancel (plist-get actions :on-draft-cancel))))
              ('list
               (etaf-view
                (etaf-agenda-list-page
                 :model model :plan plan
                 :on-grouping (plist-get actions :on-grouping)
                 :on-toggle-completed (plist-get actions :on-toggle-completed)
                 :on-select (plist-get actions :on-select)
                 :on-toggle (plist-get actions :on-toggle)
                 :on-open (plist-get actions :on-open)
                 :on-draft-submit (plist-get actions :on-draft-submit)
                 :on-draft-cancel (plist-get actions :on-draft-cancel)
                 :on-edit-submit (plist-get actions :on-edit-submit)
                 :on-edit-cancel (plist-get actions :on-edit-cancel))))
              ('project
               (etaf-view
                (etaf-agenda-project-page
                 :model model :plan plan
                 :on-select (plist-get actions :on-select)
                 :on-toggle (plist-get actions :on-toggle)
                 :on-open (plist-get actions :on-open)
                 :on-add-stage (plist-get actions :on-add-stage)
                 :on-add-task-in-stage (plist-get actions :on-add-task-in-stage)
                 :on-add-project (plist-get actions :on-add-project)
                 :on-draft-submit (plist-get actions :on-draft-submit)
                 :on-draft-cancel (plist-get actions :on-draft-cancel)
                 :on-edit-submit (plist-get actions :on-edit-submit)
                 :on-edit-cancel (plist-get actions :on-edit-cancel))))
              ('habits
               (etaf-view
                (etaf-agenda-habits-page
                 :model model :plan plan
                 :on-select (plist-get actions :on-select)
                 :on-toggle-day (plist-get actions :on-toggle-habit)
                 :on-open (plist-get actions :on-open)
                 :on-draft-submit (plist-get actions :on-draft-submit)
                 :on-draft-cancel (plist-get actions :on-draft-cancel))))
              ('review
               (etaf-view
                (etaf-agenda-review-page
                 :model model :plan plan
                 :on-prev-month (plist-get actions :on-prev-month)
                 :on-next-month (plist-get actions :on-next-month)
                 :on-today (plist-get actions :on-today)
                 :on-draft-submit (plist-get actions :on-draft-submit)
                 :on-draft-cancel (plist-get actions :on-draft-cancel))))
              (_
               (etaf-view
                (etaf-agenda-today-page
                 :model model :plan plan
                 :on-select (plist-get actions :on-select)
                 :on-toggle (plist-get actions :on-toggle)
                 :on-open (plist-get actions :on-open)
                 :on-prev-day (plist-get actions :on-prev-day)
                 :on-next-day (plist-get actions :on-next-day)
                 :on-today (plist-get actions :on-today)
                 :on-migrate-overdue (plist-get actions :on-migrate-overdue)
                 :on-clear-area (plist-get actions :on-clear-area)
                 :on-draft-submit (plist-get actions :on-draft-submit)
                 :on-draft-cancel (plist-get actions :on-draft-cancel)
                 :on-edit-submit (plist-get actions :on-edit-submit)
                 :on-edit-cancel (plist-get actions :on-edit-cancel)))))))
         ;; Right thin draggable hairline (shared `etaf-pane-resizer' like maillist)
         (etaf-pane-resizer
          :if (and show-rail show-main)
          :ref 'agenda-rail-resizer
          :side 'left
          :size rl-px
          :min (* 22 char-px)
          :max (* 40 char-px)
          :on-change (lambda (px)
                       (etaf-set-value (plist-get model :rail-width)
                                       (max 22 (min 40 (round (/ (float px) char-px))))))
          :on-end (lambda (px)
                    (let ((cols (max 22 (min 40 (round (/ (float px) char-px))))))
                      (etaf-set-value (plist-get model :rail-width) cols)
                      (ignore-errors
                        (etaf-agenda--store-meta-set (plist-get model :store)
                                                     "rail-width"
                                                     (number-to-string cols))))))
         ;; Right context / interactive inspector rail (plain Emacs background)
         (column :if show-rail
                 :width (if show-main (list 'px rl-px) 'stretch)
                 :flex-grow (if show-main 0 1)
                 :height 'stretch :min-height '(lh 0)
                 :flex-shrink 0 :overflow 'scroll
                 :region '(:id rail :label "上下文与详情" :key "r"
                               :neighbors (:left main :up search))
                 :ref 'etaf-agenda-rail
           (expr
            (if (plist-get plan :inspector-entry)
                (etaf-view
                 (etaf-agenda-inspector
                  :model model :plan plan
                  :on-close (plist-get actions :on-close-inspector)
                  :on-set-kind (plist-get actions :on-set-kind)
                  :on-cycle-status (plist-get actions :on-cycle-status)
                  :on-cycle-priority (plist-get actions :on-cycle-priority)
                  :on-edit-title (plist-get actions :on-edit-title)
                  :on-edit-submit (plist-get actions :on-edit-submit)
                  :on-edit-cancel (plist-get actions :on-edit-cancel)
                  :on-pick-scheduled (plist-get actions :on-pick-scheduled)
                  :on-pick-deadline (plist-get actions :on-pick-deadline)
                  :on-pick-time (plist-get actions :on-pick-time)
                  :on-pick-estimate (plist-get actions :on-pick-estimate)
                  :on-pick-area (plist-get actions :on-pick-area)
                  :on-pick-project (plist-get actions :on-pick-project)
                  :on-pick-tags (plist-get actions :on-pick-tags)
                  :on-pick-recurrence (plist-get actions :on-pick-recurrence)
                  :on-edit-body (plist-get actions :on-edit-body)
                  :on-submit-body (plist-get actions :on-submit-body)
                  :on-cancel-body (plist-get actions :on-cancel-body)
                  :on-toggle (plist-get actions :on-toggle)
                  :on-delete (plist-get actions :on-delete)))
              (etaf-view
               (etaf-agenda-rail-context
                :plan plan
                :on-toggle-habit (plist-get actions :on-toggle-habit)
                :on-select (plist-get actions :on-select)
                :on-toggle (plist-get actions :on-toggle)
                :on-open (plist-get actions :on-open)
                :on-new (plist-get actions :on-new)))))))
       ;; 3. Quiet bottom status + key hint bar
       (etaf-agenda-footer :plan plan :ui-store (plist-get model :ui-store))))))

(defun etaf-agenda-view (model keys help actions)
  "Return the single-canvas root View of MODEL."
  (etaf-view (etaf-agenda-shell :model model :keys keys :help help :actions actions)))

(provide 'etaf-agenda-views)
;;; etaf-agenda-views.el ends here
