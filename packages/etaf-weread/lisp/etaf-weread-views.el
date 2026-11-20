;;; etaf-weread-views.el --- Views of the WeChat Reading client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation layer of etaf-weread.  The Components here are internal: they
;; take plain values and callbacks, and never read the reader model themselves.
;; The public `etaf-weread-app' Component owns that boundary, so a repaint
;; happens in exactly one place and these Views stay independently renderable.
;;
;; Only ETAF hosts and etaf-ui Components are used, and every color comes from
;; `etaf-weread-color' so both palettes share one layout.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-weread-theme)
(require 'etaf-weread-model)

;;; ---------------------------------------------------------------------------
;;; Shared geometry
;;; ---------------------------------------------------------------------------

(defconst etaf-weread--sidebar-width (list 'ch etaf-weread--sidebar-columns)
  "Width of the section sidebar.")

(defconst etaf-weread--rail-width (list 'ch etaf-weread--rail-columns)
  "Width of the glyph-only section rail of a medium layout.")

(defconst etaf-weread--pane-width (list 'ch etaf-weread--pane-columns)
  "Width of the book detail and highlight pane.")

(defconst etaf-weread--row-columns '((ch 3) (fr 1) (ch 14) (ch 13) (ch 7) (ch 8))
  "Grid columns of one book row: index, title, author, meter, time, badge.")

(defconst etaf-weread--row-columns-compact '((ch 3) (fr 1) (ch 11) (ch 7))
  "Grid columns of a compact book row: index, title, meter, badge.")

(defconst etaf-weread--hi-columns '((ch 3) (ch 12) (fr 1) (ch 10))
  "Grid columns of one indexed highlight row: index, book, text, chapter.")

(defun etaf-weread--view-border (_side color)
  "Return the border value of SIDE drawn with COLOR."
  (list '(px 1) 'solid color))

(defun etaf-weread--hover-surface ()
  "Return the hover declarations of a clickable row.
Ebox hover styles accept colours only, so this is the surface a pointer moves
over, one step above the panel it sits on."
  (list :background-color (etaf-weread-color :panel2)))

(defun etaf-weread--item-pointer ()
  "Return the cursor a clickable item shows."
  'hand)

(defun etaf-weread--clip (text width)
  "Return TEXT clipped to WIDTH columns, with an ellipsis when it was cut."
  (let ((text (or text "")))
    (if (string-empty-p text)
        ""
      (truncate-string-to-width text width nil nil "…"))))

(defun etaf-weread--row-meter (progress)
  "Return the meter cell text of a row with PROGRESS percent.
A row without progress shows an empty string, so a book that was never opened
does not pretend to have been started."
  (let ((percent (etaf-weread--parse-number progress)))
    (if (and percent (> percent 0))
        (format "%s %s"
                (etaf-weread-progress-bar percent 6)
                (etaf-weread--progress-text percent))
      "")))

;;; ---------------------------------------------------------------------------
;;; Primitive Views
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-weread--view-nav-item
    (&key icon label active compact on-press)
  "Render one section entry with ICON, LABEL and press callback.
ICON names an `etaf-ui-icon' in the shared SVG set, so the rail reads like the
rest of the catalog instead of using text glyphs.  The whole two-line cell is
the click target, but only the text row is painted, so a selected entry reads
as one highlighted line."
  :view
  (flex :width 'stretch :height '(lh 2) :flex-direction 'column
        :role 'button :tab-index 0
        :pointer (etaf-weread--item-pointer)
        :help-echo (or label "书架")
        :on-press on-press
    ;; A callbackless button here would block the cell's inherited keymap.
    (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center :padding '((lh 0) (ch 2))
          :hover-style (unless active (etaf-weread--hover-surface))
          :background-color (and active (etaf-weread-color :accent-soft))
          :color (if active (etaf-weread-color :ink) (etaf-weread-color :muted))
          :font-weight (if active 'bold 'normal)
          :border-left (and active
                            (etaf-weread--view-border 'left (etaf-weread-color :accent)))
      ;; Icons are measured against the row, so a bold variant would only
      ;; shift their metrics; the active color already carries the state.
      (etaf-ui-icon :name (or icon 'list) :set 'svg :size 1.0 :min-width 3
                    :color (if active (etaf-weread-color :accent)
                             (etaf-weread-color :muted)))
      (box :if (not compact) :flex-grow 1 :flex-basis 'auto :min-width '(ch 0)
           :height '(lh 1) :overflow 'hidden :font-weight (if active 'bold 'normal)
        (text (expr (or label "")))))
    (box :height '(lh 1))))

(etaf-define-component etaf-weread--view-row
    (&key index row selected compact press)
  "Render book ROW number INDEX, marked SELECTED when it is the selection.
COMPACT drops the author column, which a compact frame cannot show.  PRESS is
called with INDEX when the row is clicked."
  :view
  (grid :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :grid-template-columns (if compact etaf-weread--row-columns-compact
                                 etaf-weread--row-columns)
        :gap '((lh 0) (ch 1)) :align-items 'center :padding '((lh 0) (ch 1))
        :background-color (and selected (etaf-weread-color :panel2))
        :color (etaf-weread-color :ink)
        :font-weight (if selected 'bold 'normal)
        :pointer (etaf-weread--item-pointer)
        :hover-style (unless selected (etaf-weread--hover-surface))
        :help-echo (format "%s · %s" (or (plist-get row :title) "")
                           (or (plist-get row :author) "打开详情"))
        :on-press (lambda () (funcall press index))
    (box :height '(lh 1) :justify-self 'end
         :color (if selected (etaf-weread-color :accent) (etaf-weread-color :dim))
      (text (expr (format "%2s" index))))
    (box :height '(lh 1) :overflow 'hidden
      (text (expr (or (plist-get row :title) ""))))
    (box :if (not compact) :height '(lh 1) :overflow 'hidden :font-weight 'normal
         :color (etaf-weread-color :muted)
      (text (expr (etaf-weread--clip (plist-get row :author) 14))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (if selected (etaf-weread-color :accent) (etaf-weread-color :dim))
      (text (expr (etaf-weread--row-meter (plist-get row :progress)))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-weread-color :dim)
      (text (expr (or (plist-get row :right) ""))))
    (box :height '(lh 1) :justify-self 'end
      (etaf-badge :if (not (string-empty-p (or (plist-get row :badge) "")))
                  :text (plist-get row :badge)
                  :variant (cond ((plist-get row :finished) 'success)
                                 ((plist-get row :rating) 'warning)
                                 (t 'neutral))))))

(etaf-define-component etaf-weread--view-hi-row
    (&key index row selected press)
  "Render an indexed highlight ROW at number INDEX.
The quote leads and the attached thought follows it on the same line, so an
index scan reads like a page of excerpts."
  :view
  (grid :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :grid-template-columns etaf-weread--hi-columns
        :gap '((lh 0) (ch 1)) :align-items 'center :padding '((lh 0) (ch 1))
        :background-color (and selected (etaf-weread-color :panel2))
        :color (etaf-weread-color :ink)
        :font-weight (if selected 'bold 'normal)
        :pointer (etaf-weread--item-pointer)
        :hover-style (unless selected (etaf-weread--hover-surface))
        :help-echo (string-join
                    (delq nil
                          (list (plist-get row :text)
                                (and (not (string-empty-p (or (plist-get row :thought) "")))
                                     (format "✎ %s" (plist-get row :thought)))
                                (plist-get row :title)))
                    "\n")
        :on-press (lambda () (funcall press index))
    (box :height '(lh 1) :justify-self 'end
         :color (if selected (etaf-weread-color :accent) (etaf-weread-color :dim))
      (text (expr (format "%2s" index))))
    (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :muted)

      (text (expr (etaf-weread--clip (plist-get row :title) 12))))
    (box :height '(lh 1) :overflow 'hidden
      (text (expr (etaf-weread--clip
                   (if (string-empty-p (or (plist-get row :text) ""))
                       (format "✎ %s" (or (plist-get row :thought) ""))
                     (plist-get row :text))
                   40))))
    (box :height '(lh 1) :overflow 'hidden :justify-self 'end
         :color (etaf-weread-color :dim)
      (text (expr (etaf-weread--clip (or (plist-get row :chapter) "") 10))))))

(etaf-define-component etaf-weread--view-list
    (&key entries start total loaded compact loading empty-note on-press)
  "Render APP's visible book ENTRIES with a one-based range footer.
START is the 1-based index of the first entry; TOTAL is the backend total and
LOADED the number of loaded rows.  The list keeps a fixed height so the footer
does not jump while a load is pending."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis 'auto
        :min-height '(lh 0) :gap '((lh 0) (ch 0))
    (column :for (entry entries) :key (plist-get entry :index)
            :width 'stretch :item-gap '(lh 0)
      (etaf-weread--view-hi-row
       :if (eq (plist-get (plist-get entry :row) :kind) :highlight)
       :index (plist-get entry :index)
       :row (plist-get entry :row)
       :selected (plist-get entry :selected)
       :press on-press)
      (etaf-weread--view-row
       :if (not (eq (plist-get (plist-get entry :row) :kind) :highlight))
       :index (plist-get entry :index)
       :row (plist-get entry :row)
       :selected (plist-get entry :selected)
       :compact compact
       :press on-press))
    (box :if (null entries) :height '(lh 4) :text-align 'center
         :color (etaf-weread-color :dim)
      (text (expr (or empty-note "这里还没有内容"))))
    (box :flex-grow 1 :flex-basis 'auto :min-height '(lh 0))
    (flex :if (> total 0) :width 'stretch :height '(lh 1)
          :align-items 'center :padding '((lh 0) (ch 1))
          :border-top (etaf-weread--view-border 'top (etaf-weread-color :line))
      (box :height '(lh 1) :color (etaf-weread-color :dim)
        (text (expr (format "%d–%d / %s%s"
                            start (+ start (1- (length entries)))
                            total
                            (if (> total loaded)
                                (format "（已载 %d）" loaded)
                              ""))))))
    (flex :if (and loading (null entries)) :width 'stretch :height '(lh 1)
          :padding '((lh 0) (ch 1)) :color (etaf-weread-color :dim)
      (text "正在加载…"))))

(etaf-define-component etaf-weread--view-sidebar
    (&key groups section compact on-locate)
  "Render the section sidebar from GROUPS with SECTION highlighted.
COMPACT renders the glyph-only rail a medium layout has room for.  The
signed-in account belongs to the status bar, so the rail ends with its
sections instead of repeating the name."
  :view
  (flex :flex-direction 'column
        :width (if compact etaf-weread--rail-width etaf-weread--sidebar-width)
        :height 'stretch
        :flex-shrink 0
        :padding '((lh 1) (ch 1)) :gap '((lh 0) (ch 0))
        :background-color (etaf-weread-color :panel)
        :border-right (etaf-weread--view-border 'right (etaf-weread-color :line))
    (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center :padding '((lh 0) (ch 1))
      (text :font-weight 'bold :color (etaf-weread-color :accent) "读")
      (column :if (not compact) :flex-grow 1 :flex-basis 'auto :min-width '(ch 0)
              :item-gap '(lh 0)
        (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
          (text "微信读书"))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :dim)

          (text "WEREAD"))))
    (box :if (not compact) :height '(lh 1))
    (column :for (group groups) :key (car group) :width 'stretch :item-gap '(lh 0)
      (box :if (and (not compact) (not (eq group (car groups)))) :height '(lh 1))
      (box :if (and (not compact) (not (eq group (car groups)))) :height '(lh 1)
           :padding '((lh 0) (ch 2)) :font-weight 'bold
           :color (etaf-weread-color :muted)
        (text (expr (format "%s" (car group)))))
      (box :if (and (not compact) (not (eq group (car groups)))) :height '(lh 1))
      (etaf-weread--view-nav-item :for (entry (cdr group)) :key (car entry)
        :icon (nth 2 entry)
        :label (nth 1 entry)
        :compact compact
        :active (eq (car entry) section)
        :on-press (lambda () (funcall on-locate (car entry)))))))

(etaf-define-component etaf-weread--view-chips (&key groups section on-locate)
  "Render the sections as a strip of glyph chips, as a narrow layout does.
The strip replaces the sidebar: every section stays one press away while the
header keeps showing the current section's name."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
        :align-items 'center :overflow 'hidden
    (flex :for (entry (apply #'append (mapcar #'cdr groups))) :key (car entry)
      :height '(lh 1) :align-items 'center :padding '((lh 0) (ch 1))
      :role 'button :tab-index 0
      :pointer (etaf-weread--item-pointer)
      :hover-style (unless (eq (car entry) section) (etaf-weread--hover-surface))
      :help-echo (or (nth 1 entry) "书架")
      :background-color (and (eq (car entry) section) (etaf-weread-color :accent-soft))
      :color (if (eq (car entry) section) (etaf-weread-color :accent) (etaf-weread-color :dim))
      :on-press (lambda () (funcall on-locate (car entry)))
      (etaf-ui-icon :name (or (nth 2 entry) 'list) :set 'svg :size 1.0
                    :min-width 2))))

(etaf-define-component etaf-weread--view-header
    (&key title subtitle query placeholder loading mode compact on-search on-refresh)
  "Render the content header for TITLE with its actions.
COMPACT stacks the search field under the title, the shape a narrow frame
needs.  MODE `stats' hides the search field, which has no meaning there."
  :view
  (column :width 'stretch :height (if compact '(lh 3) '(lh 2)) :item-gap '(lh 0)
    (flex :if compact :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
          :align-items 'center
      (box :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :height '(lh 1)
           :overflow 'hidden :font-weight 'bold
        (text (expr (or title ""))))
      (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :muted)

        (text (expr (or subtitle ""))))
      (etaf-button :label (if loading "…" "刷新") :variant 'ghost
                   :on-press on-refresh))
    (flex :if (and compact (not (eq mode 'stats))) :width 'stretch :height '(lh 2)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (flex :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder (or placeholder "搜索书名或作者")
                         :hide-label t :on-change on-search)))
    (flex :if (not compact) :width 'stretch :height '(lh 2)
          :gap '((lh 0) (ch 1)) :align-items 'center
      (column :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :item-gap '(lh 0)
        (text :font-weight 'bold (expr (or title "")))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :muted)

          (text (expr (or subtitle "")))))
      (box :if (not (eq mode 'stats)) :width '(ch 34) :height '(lh 1)
        (etaf-text-input :value query :label "搜索"
                         :placeholder (or placeholder "搜索书名或作者")
                         :hide-label t :on-change on-search))
      (etaf-button :label (if loading "… 加载中" "刷新") :variant 'ghost
                   :on-press on-refresh))))

(etaf-define-component etaf-weread--view-tabs (&key pane on-pane layout)
  "Render the list/detail/notes switch a compact layout uses.
The switch itself is the shared Tabs control; this Component only places it
with the reader's hint line.  A narrow frame shows the short hint, because
the full binding summary cannot share a phone-like line with the switch."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
        :flex-shrink 0 :align-items 'center :padding '((lh 0) (ch 2))
        :background-color (etaf-weread-color :panel)
        :border-top (etaf-weread--view-border 'top (etaf-weread-color :line))
    (box :width '(ch 22)
      (etaf-tabs :items (list (list :key 'list :label "列表")
                              (list :key 'detail :label "详情")
                              (list :key 'notes :label "笔记"))
                 :active pane
                 :on-change (lambda (key) (funcall on-pane key))))
    (box :flex-grow 1 :flex-basis 'auto :min-width '(ch 0)
         :height '(lh 1) :text-align 'right :color (etaf-weread-color :dim)
         :overflow 'hidden
      (text (expr (if (eq layout 'narrow)
                       "? 帮助"
                     "↑/↓ 选择 · RET 打开 · v 切换面板"))))))

(etaf-define-component etaf-weread--view-note (&key text loading height)
  "Render TEXT as a quiet placeholder, or a skeleton while LOADING.
Composes the shared empty-state and skeleton controls so a placeholder keeps
the catalog's spacing and typography."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (etaf-skeleton :if loading :width 'stretch :height (or height '(lh 6)))
    (etaf-empty :if (not loading) :title (or text ""))))

;;; ---------------------------------------------------------------------------
;;; Book detail and highlights
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-weread--view-detail
    (&key detail pane chapters on-open on-export on-pane)
  "Render the book card of DETAIL with its visible CHAPTERS.
CHAPTERS is the already-sliced chapter list, so this Component never reads the
model.  PANE selects the active tab; ON-OPEN, ON-EXPORT and ON-PANE are the
actions the card offers."
  :view
  (column :width 'stretch :height 'stretch :item-gap '(lh 0)
          :padding '((lh 1) (ch 2))
    (etaf-weread--view-note
     :if (and detail (plist-get detail :loading))
     :loading t :height '(lh 8))
    (etaf-weread--view-note
     :if (and detail (plist-get detail :error))
     :text (format "加载失败：%s" (plist-get detail :error))
     :height '(lh 8))
    (etaf-weread--view-note
     :if (null detail)
     :text "选择一本书查看详情"
     :height '(lh 8))
    (column :if (and detail (not (plist-get detail :loading))
                     (not (plist-get detail :error)))
            :width 'stretch :item-gap '(lh 0)
      (flex :width 'stretch :height '(lh 5) :gap '((lh 0) (ch 2))
            :align-items 'center
        (box :width '(ch 8) :height '(lh 4) :text-align 'center
             :bgcolor (etaf-weread-color :cover)
             :color (etaf-weread-color :accent)
             ;; No font-size override: a glyph taller than the line height would
             ;; make the row taller than the grid, and the page budget counts
             ;; rows, so the canvas would overflow the window.
             :font-weight 'bold
          (text (expr (if (and (plist-get detail :title)
                               (not (string-empty-p (plist-get detail :title))))
                          (substring (plist-get detail :title) 0 1)
                        "书"))))
        (column :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :item-gap '(lh 0)
          (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
            (text (expr (or (plist-get detail :title) ""))))
          (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :muted)
            (text (expr (or (plist-get detail :author) "佚名"))))
          (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :dim)

            (text (expr (string-join
                         (delq nil
                               (list (plist-get detail :category)
                                     (and (not (string-empty-p
                                                (or (plist-get detail :rating) "")))
                                          (format "★ %s" (plist-get detail :rating)))
                                     (and (> (or (plist-get detail :word-count) 0) 0)
                                          (format "%s 字"
                                                  (plist-get detail :word-count)))))
                         " · "))))))
      (etaf-progress :value (max 0 (min 100 (or (plist-get detail :progress) 0)))
                     :max 100 :label "已读")
      (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :dim)

        (text (expr (string-join
                     (delq nil
                           (list (and (> (or (plist-get detail :notes) 0) 0)
                                      (format "划线 %d" (plist-get detail :notes)))
                                 (and (> (or (plist-get detail :reviews) 0) 0)
                                      (format "想法 %d" (plist-get detail :reviews)))
                                 (and (> (or (plist-get detail :reading-time) 0) 0)
                                      (format "读了 %s"
                                              (etaf-weread-format-duration
                                               (plist-get detail :reading-time))))
                                 (and (plist-get detail :finished) "已读完")))
                     " · "))))
      (flex :width 'stretch :height '(lh 3) :gap '((lh 0) (ch 1))
            :align-items 'center
        (etaf-button :label "继续阅读" :variant 'primary :pointer 'hand
                     :help-echo "在浏览器里打开这本书"
                     :on-press on-open)
        (etaf-button :label "导出笔记" :variant 'secondary :pointer 'hand
                     :help-echo "把划线和想法导出成 Markdown"
                     :on-press on-export))
      (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
            :align-items 'center
            :border-bottom (etaf-weread--view-border 'bottom (etaf-weread-color :line))
        (box :width '(ch 22)
          (etaf-tabs :items (list (list :key 'detail
                                        :label (format "目录 %d"
                                                       (length (plist-get detail :chapters))))
                                  (list :key 'notes
                                        :label (format "笔记 %d"
                                                       (or (plist-get detail :notes) 0))))
                     :active pane
                     :on-change (lambda (key) (funcall on-pane key)))))
      (column :width 'stretch :item-gap '(lh 0)
        (grid :for (chapter chapters) :key (plist-get chapter :index)
              :width 'stretch :height '(lh 1)
              :grid-template-columns '((ch 3) (fr 1) (ch 7))
              :gap '((lh 0) (ch 1)) :align-items 'center
          (box :height '(lh 1) :justify-self 'end :color (etaf-weread-color :dim)

            (text (expr (format "%d" (plist-get chapter :index)))))
          (box :height '(lh 1) :overflow 'hidden
            (text (expr (etaf-weread--clip (plist-get chapter :title)
                                           etaf-weread--pane-content-columns))))
          (box :height '(lh 1) :justify-self 'end :color (etaf-weread-color :dim)

            (text (expr (if (> (or (plist-get chapter :words) 0) 0)
                            (format "%d 字" (plist-get chapter :words))
                          ""))))))
      (box :if (null (plist-get detail :chapters)) :height '(lh 3)
           :text-align 'center :color (etaf-weread-color :dim)
        (text "这本书没有目录数据")))))

(etaf-define-component etaf-weread--view-notes
    (&key notes pane lines on-pane on-open)
  "Render the highlights of NOTES as a flat list of visible LINES.
LINES is already sliced, so this Component never reads the model.  PANE and
ON-PANE drive the tab line; ON-OPEN opens the book in the browser."
  :view
  (column :width 'stretch :height 'stretch :item-gap '(lh 0)
          :padding '((lh 1) (ch 2))
    (etaf-weread--view-note
     :if (and notes (plist-get notes :loading))
     :loading t :height '(lh 8))
    (etaf-weread--view-note
     :if (and notes (plist-get notes :error))
     :text (format "加载失败：%s" (plist-get notes :error)) :height '(lh 8))
    (etaf-weread--view-note
     :if (null notes)
     :text "选择一本书查看划线与想法" :height '(lh 8))
    (column :if (and notes (not (plist-get notes :loading))
                     (not (plist-get notes :error)))
            :width 'stretch :item-gap '(lh 0)
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
            :align-items 'center
        (box :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :height '(lh 1)
             :overflow 'hidden :font-weight 'bold
          (text (expr (or (plist-get notes :title) ""))))
        (box :height '(lh 1) :color (etaf-weread-color :dim)
          (text (expr (format "划线 %d · 想法 %d"
                              (or (plist-get notes :highlights) 0)
                              (or (plist-get notes :thoughts) 0))))))
      (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
            :align-items 'center
            :border-bottom (etaf-weread--view-border 'bottom (etaf-weread-color :line))
        (box :width '(ch 12)
          (etaf-tabs :items (list (list :key 'detail :label "详情")
                                  (list :key 'notes :label "笔记"))
                     :active pane
                     :on-change (lambda (key) (funcall on-pane key))))
        (box :flex-grow 1 :flex-basis 'auto :min-width '(ch 0))
        (etaf-button :label "继续阅读" :variant 'ghost :pointer 'hand
                     :help-echo "在浏览器里打开这本书" :on-press on-open))
      (column :width 'stretch :item-gap '(lh 0)
        (flex :flex-direction 'column :for (line lines) :key (plist-get line :key)
              :width 'stretch :gap '((lh 0) (ch 0))
          (box :if (eq (plist-get line :kind) 'chapter)
               :height '(lh 2) :align-self 'end :font-weight 'bold
               :color (etaf-weread-color :accent)
            (text (expr (format "· %s" (plist-get line :text)))))
          (box :if (eq (plist-get line :kind) 'quote)
               :width 'stretch :height '(lh 1) :overflow 'hidden
               :padding '((lh 0) (ch 1))
               :border-left (etaf-weread--view-border 'left (etaf-weread-color :quote))
               :color (etaf-weread-color :ink)
            (text (expr (etaf-weread--clip (plist-get line :text)
                                           (- etaf-weread--pane-content-columns 2)))))
          (box :if (and (eq (plist-get line :kind) 'quote)
                        (not (string-empty-p (or (plist-get line :thought) ""))))
               :width 'stretch :height '(lh 1) :overflow 'hidden
               :padding '((lh 0) (ch 2)) :color (etaf-weread-color :muted)

            (text (expr (format "✎ %s"
                                (etaf-weread--clip (plist-get line :thought)
                                                   (- etaf-weread--pane-content-columns 4))))))
          (box :if (eq (plist-get line :kind) 'thought)
               :width 'stretch :height '(lh 1) :overflow 'hidden
               :padding '((lh 0) (ch 1)) :color (etaf-weread-color :quote)

            (text (expr (format "✦ %s"
                                (etaf-weread--clip (plist-get line :text)
                                                   (- etaf-weread--pane-content-columns 2)))))))
      (box :if (null (plist-get notes :groups)) :height '(lh 4)
           :text-align 'center :color (etaf-weread-color :dim)
        (text "这本书还没有划线或想法"))))))

(etaf-define-component etaf-weread--view-stats (&key stats)
  "Render the reading statistics card of STATS."
  :view
  (flex :flex-direction 'column :width 'stretch :height 'stretch :gap '((lh 0) (ch 0))
        :padding '((lh 1) (ch 2))
    (etaf-weread--view-note
     :if (null stats) :loading t :height '(lh 8))
    (flex :if stats :flex-direction 'column :width 'stretch :gap '((lh 0) (ch 0))
      (text :font-weight 'bold "阅读统计")
      (box :height '(lh 1) :color (etaf-weread-color :muted)
        (text (expr (or (plist-get stats :conclusion) ""))))
      (box :height '(lh 1))
      (flex :width 'stretch :gap '((lh 0) (ch 1))
        (column :for (card (list (list "读完" (format "%d 本" (or (plist-get stats :finished) 0)))
                                 (list "在读" (format "%d 本" (or (plist-get stats :reading) 0)))
                                 (list "时长" (or (plist-get stats :total-time) "—"))
                                 (list "笔记" (format "%d 条" (or (plist-get stats :notes) 0)))))
                :key (car card)
                :flex-grow 1 :flex-basis 'auto :min-width '(ch 0)
                :padding '((lh 0) (ch 1))
                :bgcolor (etaf-weread-color :panel2)
          (etaf-statistic :label (nth 0 card) :value (nth 1 card))))
      (box :height '(lh 2))
      (text :font-weight 'bold "读完的书")
      (box :height '(lh 1) :overflow 'hidden :color (etaf-weread-color :muted)

        (text (expr (if (plist-get stats :finished-books)
                        (string-join (plist-get stats :finished-books) " · ")
                      "还没有读完的书"))))
      (box :height '(lh 2))
      (box :flex-grow 1 :flex-basis 'auto :min-height '(lh 0))
      (box :height '(lh 1) :color (etaf-weread-color :dim)
        (text "左侧列表按阅读时长排列")))))

;;; ---------------------------------------------------------------------------
;;; Footer
;;; ---------------------------------------------------------------------------

(defun etaf-weread--viewport-columns ()
  "Return the mounted viewport width in character columns.
The canvas's own cell turns the width into columns: `ch' resolves against it,
so a text scale keeps the reading column where the layout put it."
  (let ((cell (or (plist-get (ignore-errors (etaf-display-metrics)) :char-width)
                  (frame-char-width))))
    (max 20 (floor (/ (or (car (etaf-viewport)) (* 80 cell)) cell)))))

(defconst etaf-weread--footer-hint
  "g 刷新 · v 笔记 · o 浏览器 · E 导出 · T 深浅色 · ? 帮助"
  "Binding summary at the right edge of the reader's status bar.
Its column width sizes the hint box, so the summary is never clipped.")

(etaf-define-component etaf-weread--view-footer
    (&key account summary message error compact hint)
  "Render the status bar with ACCOUNT, SUMMARY and the latest MESSAGE.
HINT is the binding summary at the right edge; it defaults to
`etaf-weread--footer-hint', and the reading pane passes its own.  A failure is
painted in the danger color, a hint in the muted one, and the account name
carries its own state in its color instead of a marker glyph.  The hint box
takes exactly the columns its text needs and never shrinks, so a long message
shortens itself instead of clipping the binding summary."
  :view
  (flex :width 'stretch :height (if compact '(lh 2) '(lh 1))
        :flex-direction (if compact 'column 'row)
        :gap '((lh 0) (ch 2)) :align-items 'center
        :padding '((lh 0) (ch 2))
        :flex-shrink 0
        :bgcolor (etaf-weread-color :panel)
        :border-top (etaf-weread--view-border 'top (etaf-weread-color :line))
    (flex :width '(ch 24) :height '(lh 1)
          :align-items 'center :overflow 'hidden
      (box :height '(lh 1) :overflow 'hidden
           :color (etaf-weread-color (if account :muted :danger))

        (text (expr (or (and account (plist-get account :name)) "未登录")))))
    (box :if (not compact) :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
         :color (etaf-weread-color (if error :danger :dim))
      (text (expr (etaf-weread--clip
                   (or message summary "")
                   (max 12 (- (etaf-weread--viewport-columns)
                              (+ 24 4 4 (string-width (or hint etaf-weread--footer-hint)))))))))
    (box :if (not compact)
         :width (list 'ch (string-width (or hint etaf-weread--footer-hint)))
         :flex-shrink 0 :height '(lh 1) :text-align 'right :overflow 'hidden
         :color (etaf-weread-color :dim)
      (text (expr (or hint etaf-weread--footer-hint))))
    (box :if compact :width 'stretch :height '(lh 1) :overflow 'hidden
         :color (etaf-weread-color (if error :danger :dim))
      (text (expr (or message summary ""))))))

(provide 'etaf-weread-views)
;;; etaf-weread-views.el ends here
