;;; etaf-rss-views.el --- Views of the RSS reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation layer of etaf-rss.  The Components here are internal: they
;; take plain values and callbacks and never read the reader model, so a
;; repaint happens in exactly one place (the application Component) and each
;; View stays independently renderable.
;;
;; Only ETAF hosts and etaf-ui Components are used, and every color comes from
;; `etaf-rss-color' so both palettes share one layout.  The application
;; registers its own SVG icon set, sized like the shared one, so sidebar and
;; toolbar glyphs never grow a row.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-rss-theme)
(require 'etaf-rss-model)

;;; ---------------------------------------------------------------------------
;;; Icons
;;; ---------------------------------------------------------------------------

(defconst etaf-rss--icon-set 'etaf-rss
  "Icon set registered by this application.")

(etaf-ui-icon-set-register
 'etaf-rss
 (list
  :kind 'svg :viewbox [0 0 14 14] :inset 2
  :fallback
  '((rss . "R") (feed . "R") (folder . "D") (list . "=") (radio . "o")
    (radio-empty . ".") (star . "*") (star-filled . "*") (check . "ok")
    (search . "?") (refresh . "@") (plus . "+") (minus . "-") (close . "x")
    (chevron-right . ">") (chevron-down . "v") (external . "^")
    (import . "<") (export . ">") (clock . "c") (trash . "x") (dot . "!"))
  :paths
  '((rss . "<circle cx='3' cy='11' r='1.4' fill='currentColor'/><path d='M2 6A6 6 0 0 1 8 12M2 2A10 10 0 0 1 12 12'/>")
    (feed . "<circle cx='3' cy='11' r='1.4' fill='currentColor'/><path d='M2 6A6 6 0 0 1 8 12M2 2A10 10 0 0 1 12 12'/>")
    (folder . "<path d='M1.5 3.5H5.5L7 5.5H12.5V11.5H1.5Z'/>")
    (list . "<path d='M2 3H3M6 3H12M2 7H3M6 7H12M2 11H3M6 11H12'/>")
    (radio . "<circle cx='7' cy='7' r='2.4' fill='currentColor'/>")
    (radio-empty . "<circle cx='7' cy='7' r='2.2'/>")
    (star . "<path d='M7 1.5L8.6 5.4L12.5 7L8.6 8.6L7 12.5L5.4 8.6L1.5 7L5.4 5.4Z'/>")
    (star-filled . "<path fill='currentColor' d='M7 1.5L8.6 5.4L12.5 7L8.6 8.6L7 12.5L5.4 8.6L1.5 7L5.4 5.4Z'/>")
    (check . "<path d='M2 7L5 10L12 3'/>")
    (search . "<circle cx='6' cy='6' r='4'/><path d='M9 9L13 13'/>")
    (refresh . "<path d='M12 5A5 5 0 1 0 12 9M9 5H12V2'/>")
    (plus . "<path d='M2 7H12M7 2V12'/>")
    (minus . "<path d='M2 7H12'/>")
    (close . "<path d='M3 3L11 11M11 3L3 11'/>")
    (chevron-right . "<path d='M5 3L9 7L5 11'/>")
    (chevron-down . "<path d='M3 5L7 9L11 5'/>")
    (external . "<path d='M6.5 2.5H2.5V11.5H11.5V7.5M8.5 2H12V5.5M12 2L7 7'/>")
    (import . "<path d='M7 2V9M4 6L7 9L10 6M2 12H12'/>")
    (export . "<path d='M7 9V2M4 5L7 2L10 5M2 12H12'/>")
    (clock . "<circle cx='7' cy='7' r='5'/><path d='M7 4.5V7.5L9.2 9.2'/>")
    (trash . "<path d='M2.5 4H11.5M5.5 4V2.5H8.5V4M3.5 4L4.5 12H9.5L10.5 4'/>")
    (dot . "<circle cx='7' cy='7' r='2.4' fill='currentColor'/>"))))

;;; ---------------------------------------------------------------------------
;;; Shared geometry
;;; ---------------------------------------------------------------------------

(defun etaf-rss--border (_side color)
  "Return the border value of SIDE drawn with COLOR."
  (list '(px 1) 'solid color))

(defun etaf-rss--hover-surface ()
  "Return the hover declarations of a clickable row."
  (list :background-color (etaf-rss-color :panel2)))

(defun etaf-rss--clip (text width)
  "Return TEXT clipped to WIDTH columns, with an ellipsis when it was cut."
  (let ((text (or text "")))
    (if (string-empty-p text)
        ""
      (truncate-string-to-width text width nil nil "…"))))

(defun etaf-rss--time-text (row)
  "Return the right-hand time cell of ROW."
  (let ((time (plist-get row :published)))
    (if time (etaf-rss-relative-time time) "")))

(defun etaf-rss--row-columns (pane)
  "Return the grid columns of one article row inside a PANE-wide list.
The title takes the remaining space; the feed column appears only when the
list can spare it, so a narrow list keeps readable titles instead of one
letter per word."
  ;; A feed name costs the title nine columns, so it only earns its place
  ;; once the title still gets a readable width beside it.
  (cond ((>= pane 62) '((ch 2) (fr 1) (ch 12) (ch 9) (ch 2)))
        ((>= pane 52) '((ch 2) (fr 1) (ch 9) (ch 9) (ch 2)))
        (t '((ch 2) (fr 1) (ch 9) (ch 2)))))

(defun etaf-rss--title-columns (pane)
  "Return how many columns an article title may use in a PANE-wide list.
The title is the row's only flexible column, so it gets what the fixed
columns, the row's gaps, its padding and one slack column leave; the same
column list renders the row, so the budget cannot drift from the grid."
  (let* ((columns (etaf-rss--row-columns pane))
         (fixed (apply #'+ (mapcar (lambda (column)
                                     (if (eq (car column) 'ch) (cadr column) 0))
                                   columns)))
         (chrome (+ fixed (* 2 (1- (length columns))) 2 1)))
    (max 8 (- pane chrome))))

;;; ---------------------------------------------------------------------------
;;; Navigation
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-rss--view-action
    (&key icon help active on-press)
  "Render one toolbar icon button with a uniform target.
Every action gets the same three-column, one-row target with a hover surface,
so a row of them reads as a toolbar instead of a cluster of glyphs."
  :view
  (flex :width '(ch 3) :height '(lh 1) :align-items 'center :justify-content 'center
        :role 'button :tab-index 0 :pointer 'hand
        :hover-style (etaf-rss--hover-surface)
        :help-echo help
        :on-press on-press
    (etaf-ui-icon :name icon :set etaf-rss--icon-set :size 1.0 :min-width 2
                  :color (if active (etaf-rss-color :accent)
                           (etaf-rss-color :muted)))))

(etaf-define-component etaf-rss--view-nav-item
    (&key icon label active unread error compact indent on-press)
  "Render one scope or subscription entry.
ICON names a glyph of the application set, LABEL is its title, UNREAD is the
count painted at the right edge and ERROR marks a failed subscription.  A
selected entry is carried by its surface and color, never by a prefix glyph,
so switching scopes never shifts the label."
  :view
  (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
        :align-items 'center
        :padding (list (list 'lh 0) (list 'ch (or indent (if compact 0 1))))
        :flex-shrink 0
        :role 'button :tab-index 0 :pointer 'hand
        :hover-style (unless active (etaf-rss--hover-surface))
        :background-color (and active (etaf-rss-color :accent-soft))
        :color (if active (etaf-rss-color :ink) (etaf-rss-color :muted))
        :font-weight (if active 'bold 'normal)
        :help-echo (or label "订阅")
        :on-press on-press
    (etaf-ui-icon :name (or icon 'rss) :set etaf-rss--icon-set :size 1.0 :min-width 2 :color (if active (etaf-rss-color :accent) (etaf-rss-color :muted)))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
      (text (expr (or label ""))))
    (box :if (and unread (> unread 0)) :height '(lh 1) :min-width '(ch 2)
         :text-align 'right :font-weight 'normal
         :color (if active (etaf-rss-color :accent) (etaf-rss-color :dim))
      (text (expr (format "%d" unread))))
    (etaf-ui-icon :if error :name 'dot :set etaf-rss--icon-set :size 0.8 :min-width 2 :color (etaf-rss-color :danger))))

(etaf-define-component etaf-rss--view-folder
    (&key folder open spaced on-toggle on-locate)
  "Render one folder row with FOLDER being the folder plist.
SPACED leaves one empty row above the folder, so sibling groups read as
separate blocks instead of one continuous list.  Clicking the chevron toggles
OPEN; clicking the name selects the folder's articles.  When OPEN, the
folder's feeds follow as ordinary entries."
  :view
  (column :width 'stretch :item-gap '(lh 0) :flex-shrink 0
    (box :if spaced :height '(lh 1))
    (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 0))
          :align-items 'center :font-weight 'bold
          :color (if (plist-get folder :active)
                     (etaf-rss-color :ink)
                   (etaf-rss-color :muted))
      (etaf-ui-icon :name (if open 'chevron-down 'chevron-right) :set etaf-rss--icon-set :size 1.0 :min-width 2 :on-press on-toggle :help-echo (if open "折叠文件夹" "展开文件夹") :color (etaf-rss-color :dim))
      (flex :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
            :role 'button :tab-index 0 :pointer 'hand
            :hover-style (etaf-rss--hover-surface)
            :help-echo (or (plist-get folder :label) "文件夹")
            :on-press on-locate
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height '(lh 1) :overflow 'hidden
          (text (expr (or (plist-get folder :label) ""))))
        (box :if (> (or (plist-get folder :unread) 0) 0)
             :height '(lh 1) :min-width '(ch 2) :text-align 'right
             :font-weight 'normal :color (etaf-rss-color :dim)
          (text (expr (format "%d" (or (plist-get folder :unread) 0)))))))
    (flex :if open :flex-direction 'column :width 'stretch :gap '((lh 0) (ch 0))
      (etaf-rss--view-nav-item :for (feed (plist-get folder :feeds))
                               :key (plist-get feed :id)
        :icon 'feed
        :label (plist-get feed :title)
        :indent 2
        :active (plist-get feed :active)
        :unread (plist-get feed :unread)
        :error (plist-get feed :error)
        :on-press (lambda () (funcall on-locate (plist-get feed :id)))))))

(defun etaf-rss--wheel-keys (on-scroll)
  "Return the wheel key entries that call ON-SCROLL with -1 and 1.
The reader's chrome carries them so a wheel turn over a header row, a tab or
the status bar still scrolls the article, while the panes declare their own
gesture and the subscription list keeps its native scrolling."
  (list (list "<wheel-up>" (lambda () (funcall on-scroll -1)) "阅读上一页")
        (list "<wheel-down>" (lambda () (funcall on-scroll 1)) "阅读下一页")))

(etaf-define-component etaf-rss--view-sidebar
    (&key smart folders compact on-locate on-toggle on-add on-import on-export)
  "Render the subscription sidebar.
SMART is the three fixed scopes, FOLDERS the folder tree; COMPACT renders the
narrow sidebar a medium frame has room for.  The action row keeps subscribe,
import and export one press away on every layout."
  :view
  (flex :flex-direction 'column
        :width (list 'ch (if compact etaf-rss--sidebar-narrow-columns
                           etaf-rss--sidebar-columns))
        :height 'stretch :flex-shrink 0
        :padding (if compact '((lh 1) (ch 1)) '((lh 1) (ch 1)))
        :gap '((lh 0) (ch 0))
        :background-color (etaf-rss-color :panel)
        :border-right (etaf-rss--border 'right (etaf-rss-color :line))
    (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
          :align-items 'center :padding '((lh 0) (ch 1))
      (etaf-ui-icon :name 'rss :set etaf-rss--icon-set :size 1.1 :min-width 2 :color (etaf-rss-color :accent))
      (flex :if (not compact) :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0)
            :min-width '(ch 0) :gap '((lh 0) (ch 0))
        (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
          (text "ETAF 阅读"))
        (box :height '(lh 1) :overflow 'hidden :color (etaf-rss-color :dim)
          (text "RSS READER"))))
    (box :if (not compact) :height '(lh 1))
    (flex :flex-direction 'column :width 'stretch :gap '((lh 0) (ch 0)) :flex-shrink 0
      (etaf-rss--view-nav-item :for (item smart) :key (plist-get item :key)
        :icon (plist-get item :icon)
        :label (plist-get item :label)
        :active (plist-get item :active)
        :unread (plist-get item :unread)
        :compact compact
        :on-press (lambda () (funcall on-locate (plist-get item :key)))))
    (box :height '(lh 1) :border-bottom (etaf-rss--border 'bottom (etaf-rss-color :line-soft)))
    (box :height '(lh 1))
    ;; The feed list scrolls inside its own region; a zero basis keeps the
    ;; region at the space left under the scopes instead of growing with it.
    (flex :flex-direction 'column :flex-grow 1 :flex-basis '(lh 0)
          :min-height '(lh 0)
          :gap '((lh 0) (ch 0)) :overflow 'scroll
          :id 'etaf-rss-sidebar-feeds
          :aria-label "订阅源"
      (flex :flex-direction 'column :width 'stretch :gap '((lh 0) (ch 0))
        (etaf-rss--view-folder :for (folder folders)
                               :key (or (plist-get folder :name) "top")
          :folder folder
          :spaced (not (equal (plist-get folder :name)
                              (plist-get (car folders) :name)))
          :open (plist-get folder :open)
          :on-toggle (lambda () (funcall on-toggle (plist-get folder :name)))
          :on-locate (lambda (id) (funcall on-locate (list :kind :feed :id id))))))
    (box :height '(lh 1) :flex-shrink 0)
    (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 0))
          :justify-content 'space-between :align-items 'center :flex-shrink 0
          :padding '((lh 0) (ch 1))
          :border-top (etaf-rss--border 'top (etaf-rss-color :line-soft))
      (etaf-rss--view-action :icon 'plus :help "添加订阅（a）"
                             :active t :on-press on-add)
      (etaf-rss--view-action :icon 'import :help "导入 OPML（i）"
                             :on-press on-import)
      (etaf-rss--view-action :icon 'export :help "导出 OPML（e）"
                             :on-press on-export))))

(etaf-define-component etaf-rss--view-chips (&key smart on-locate)
  "Render the fixed scopes as a strip of chips, as a narrow layout does.
The three scopes fit every narrow window; folders and single feeds are chosen
from the header's source menu, which scales to any number of them."
  :view
  (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
        :align-items 'center :flex-shrink 0 :overflow 'hidden
    (flex :for (item smart) :key (plist-get item :key)
      :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
      :padding '((lh 0) (ch 1))
      :role 'button :tab-index 0 :pointer 'hand
      :hover-style (unless (plist-get item :active) (etaf-rss--hover-surface))
      :help-echo (plist-get item :label)
      :background-color (and (plist-get item :active) (etaf-rss-color :accent-soft))
      :color (if (plist-get item :active) (etaf-rss-color :accent) (etaf-rss-color :dim))
      :on-press (lambda () (funcall on-locate (plist-get item :key)))
      (etaf-ui-icon :name (plist-get item :icon) :set etaf-rss--icon-set :size 0.9 :min-width 2)
      (text (expr (plist-get item :label))))))

(etaf-define-component etaf-rss--view-header
    (&key title subtitle refreshing loading sources on-locate
          on-search on-refresh on-add on-scroll)
  "Render the content header for TITLE with its actions.
The right edge keeps search, refresh and subscribe one press away on every
layout; the subtitle carries the counts of the current scope."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 1))
        :align-items 'center :flex-shrink 0
        :keys (when on-scroll (etaf-rss--wheel-keys on-scroll))
    (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :item-gap '(lh 0)
      (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
        (text (expr (or title ""))))
      (box :height '(lh 1) :overflow 'hidden :color (etaf-rss-color :muted)
        (text (expr (or subtitle "")))))
    (box :if sources :width '(ch 10)
      (etaf-menu :label "订阅" :items sources :on-select on-locate))
    (etaf-rss--view-action :icon 'search :help "搜索文章（/）"
                           :on-press on-search)
    (etaf-rss--view-action :icon (if loading 'clock 'refresh)
                           :help (if refreshing "正在刷新…（g）" "刷新（g）")
                           :active refreshing :on-press on-refresh)
    (etaf-rss--view-action :icon 'plus :help "添加订阅（a）"
                           :active t :on-press on-add)))

(etaf-define-component etaf-rss--view-row
    (&key index row selected pane press)
  "Render article ROW number INDEX, marked SELECTED when it is the selection.
PANE is the list's width in columns, which decides whether the row can show
the feed name.  PRESS is called with INDEX when the row is clicked; an unread
row is bold with a filled dot, a starred row carries a gold star, and both
states never change the text's width."
  :view
  (grid :width 'stretch :height '(lh 1) :role 'button :tab-index 0
        :grid-template-columns (etaf-rss--row-columns pane)
        :gap '((lh 0) (ch 1)) :align-items 'center :padding '((lh 0) (ch 1))
        :background-color (and selected (etaf-rss-color :panel2))
        :color (etaf-rss-color :ink)
        :font-weight (if (plist-get row :read) 'normal 'bold)
        :pointer 'hand
        :hover-style (unless selected (etaf-rss--hover-surface))
        :help-echo (or (plist-get row :title) "打开文章")
        :on-press (lambda () (funcall press index))
    (box :height '(lh 1) :justify-self 'center
      (etaf-ui-icon :name (if (plist-get row :read) 'radio-empty 'radio) :set etaf-rss--icon-set :size 0.75 :min-width 2 :color (if (plist-get row :read)
                                 (etaf-rss-color :panel3)
                               (etaf-rss-color :accent))))
    (box :height '(lh 1) :overflow 'hidden
      (text (expr (etaf-rss--clip (or (plist-get row :title) "")
                                  (etaf-rss--title-columns pane)))))
    (box :if (>= pane 52) :height '(lh 1) :overflow 'hidden
         :font-weight 'normal :color (etaf-rss-color :dim)
      (text (expr (or (plist-get row :feed-title) ""))))
    (box :height '(lh 1) :justify-self 'end :font-weight 'normal
         :color (etaf-rss-color :time)
      (text (expr (etaf-rss--time-text row))))
    (box :height '(lh 1) :justify-self 'center
      (etaf-ui-icon :if (plist-get row :starred) :name 'star-filled :set etaf-rss--icon-set :size 0.75 :min-width 2 :color (etaf-rss-color :gold)))))

(etaf-define-component etaf-rss--view-list
    (&key entries start total loaded pane compact loading refreshing empty-note on-press on-scroll)
  "Render APP's visible article ENTRIES with a range footer.
START is the 1-based index of the first entry, TOTAL the scope's total and
LOADED the number of rows loaded.  The list keeps its height while a load or
refresh is pending, so the footer never jumps.  ON-SCROLL receives -1 or 1
from a wheel turn over the list: the pane owns its wheel, so turning it over
the list never scrolls the article."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-grow 1 :flex-basis 'auto
        :min-height '(lh 0) :gap '((lh 0) (ch 0))
        :keys (when on-scroll
                (list (list "<wheel-up>" (lambda () (funcall on-scroll -1)) "上一篇文章")
                      (list "<wheel-down>" (lambda () (funcall on-scroll 1)) "下一篇文章")))
    (column :for (entry entries) :key (plist-get entry :index)
            :width 'stretch :item-gap '(lh 0) :flex-shrink 0
      (etaf-rss--view-row
       :index (plist-get entry :index)
       :row (plist-get entry :row)
       :selected (plist-get entry :selected)
       :pane pane
       :press on-press))
    (box :if (null entries) :height '(lh 4) :text-align 'center
         :color (etaf-rss-color :dim)
      (text (expr (or empty-note "这里还没有内容"))))
    (box :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
    (flex :if (> total 0) :width 'stretch :height '(lh 1)
          :align-items 'center :padding '((lh 0) (ch 1)) :flex-shrink 0
          :border-top (etaf-rss--border 'top (etaf-rss-color :line-soft))
      (box :height '(lh 1) :color (etaf-rss-color :dim)
        (text (expr (format "%d–%d / %s%s"
                            start (+ start (1- (length entries)))
                            total
                            (if (> total loaded)
                                (format "（已载 %d）" loaded)
                              "")))))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
      (box :if refreshing :height '(lh 1) :color (etaf-rss-color :accent)
        (text "正在刷新…")))
    (flex :if (and loading (null entries)) :width 'stretch :height '(lh 1)
          :padding '((lh 0) (ch 1)) :color (etaf-rss-color :dim)
      (text "正在加载…"))))

;;; ---------------------------------------------------------------------------
;;; Reading pane
;;; ---------------------------------------------------------------------------

(defun etaf-rss--line-style (kind)
  "Return the paint declarations of a reading line of KIND."
  (pcase kind
    ('heading (list :font-weight 'bold :color (etaf-rss-color :ink)))
    ('quote (list :color (etaf-rss-color :quote)
                  :border-left (etaf-rss--border 'left (etaf-rss-color :quote))
                  :padding-left '(ch 1)))
    ('code (list :background-color (etaf-rss-color :panel2)
                 :color (etaf-rss-color :ink)))
    ('link (list :color (etaf-rss-color :feed)))
    (_ (list :color (etaf-rss-color :ink)))))

(etaf-define-component etaf-rss--view-line (&key line)
  "Render one reading LINE with the paint of its kind.
The style is resolved once per line, so a long article does not re-derive it
five times for every painted row."
  :render
  (let ((style (etaf-rss--line-style (plist-get line :kind))))
    (etaf-view
     (box :width 'stretch :height '(lh 1) :overflow 'hidden
          :color (plist-get style :color)
          :font-weight (plist-get style :font-weight)
          :background-color (plist-get style :background-color)
          :border-left (plist-get style :border-left)
          :padding-left (plist-get style :padding-left)
       (text (expr (or (plist-get line :text) "")))))))

(etaf-define-component etaf-rss--view-reader
    (&key title meta lines loading error starred scroll total empty-note on-scroll)
  "Render the open article: TITLE, META and the visible LINES.
LOADING shows a skeleton, ERROR its message and an empty state its note.  The
pane never measures text: LINES is the already-wrapped slice of the article,
so scrolling paints without reflowing.  ON-SCROLL receives -1 or 1 from a
wheel turn over the article."
  :view
  (flex :ref 'etaf-rss-reader-pane
        :flex-direction 'column :width 'stretch :height 'stretch
        :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
        :padding '((lh 1) (ch 2)) :gap '((lh 0) (ch 0))
        :background-color (etaf-rss-color :panel)
        :border-left (etaf-rss--border 'left (etaf-rss-color :line))
        :keys (when on-scroll
                (list (list "<wheel-up>" (lambda () (funcall on-scroll -1)) "阅读上一页")
                      (list "<wheel-down>" (lambda () (funcall on-scroll 1)) "阅读下一页")))
    (box :if loading :width 'stretch :height '(lh 8)
      (etaf-skeleton :width 'stretch :height '(lh 8)))
    (box :if (and (not loading) error) :width 'stretch :height '(lh 2)
         :color (etaf-rss-color :danger)
      (text (expr (or error "这篇加载失败"))))
    (box :if (and (not loading) (not error) (not title))
         :width 'stretch :height '(lh 2) :text-align 'center
         :color (etaf-rss-color :dim)
      (text (expr (or empty-note "选择一篇文章"))))
    (flex :if (and (not loading) (not error) title)
          :flex-direction 'column :width 'stretch :height 'stretch :gap '((lh 0) (ch 0))
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
            :align-items 'center :flex-shrink 0
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height '(lh 1) :overflow 'hidden :font-weight 'bold
          (text (expr (or title ""))))
        (etaf-ui-icon :if starred :name 'star-filled :set etaf-rss--icon-set :size 0.8 :min-width 2 :color (etaf-rss-color :gold)))
      (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1))
            :align-items 'center :flex-shrink 0
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height '(lh 1) :overflow 'hidden :color (etaf-rss-color :muted)
          (text (expr (or meta ""))))
        (box :if (and total (> total 0)) :height '(lh 1) :color (etaf-rss-color :dim)
          (text (expr (format "%d%%" (round (* 100.0 (/ (float (or scroll 0))
                                                         (max 1 total)))))))))
      (box :height '(lh 1) :width 'stretch :flex-shrink 0
           :border-bottom (etaf-rss--border 'bottom (etaf-rss-color :line-soft)))
      (column :width 'stretch :item-gap '(lh 0) :flex-shrink 0
        (etaf-rss--view-line :for (line lines) :key (plist-get line :key)
          :line line)))))

(etaf-define-component etaf-rss--view-tabs (&key pane on-pane layout on-scroll)
  "Render the list/reading switch a compact layout uses.
The switch itself is the shared Tabs control; this Component only places it
with the reader's binding hint."
  :view
  (flex :width 'stretch :height '(lh 2) :gap '((lh 0) (ch 2))
        :flex-shrink 0 :align-items 'center :padding '((lh 0) (ch 2))
        :keys (when on-scroll (etaf-rss--wheel-keys on-scroll))
        :background-color (etaf-rss-color :panel)
        :border-top (etaf-rss--border 'top (etaf-rss-color :line))
    (box :width '(ch 16)
      (etaf-tabs :items (list (list :key 'list :label "文章")
                              (list :key 'reader :label "阅读"))
                 :active pane
                 :on-change (lambda (key) (funcall on-pane key))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :text-align 'right :color (etaf-rss-color :dim)
         :overflow 'hidden
      (text (expr (if (eq layout 'narrow)
                       "? 帮助"
                     "方向键选择 · RET 阅读 · v 切换"))))))

(etaf-define-component etaf-rss--view-footer
    (&key message error summary hint refreshing done total compact on-scroll)
  "Render the status bar with MESSAGE, SUMMARY and the refresh progress.
A failure is painted in the danger color; HINT is the binding summary at the
right edge, and COMPACT shortens what shares the line."
  :view
  (flex :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2))
        :align-items 'center :padding '((lh 0) (ch 2)) :flex-shrink 0
        :keys (when on-scroll (etaf-rss--wheel-keys on-scroll))
        :background-color (etaf-rss-color :panel)
        :border-top (etaf-rss--border 'top (etaf-rss-color :line))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
         :color (etaf-rss-color (if error :danger :dim))
      (text (expr (or message summary ""))))
    (box :if refreshing :height '(lh 1) :color (etaf-rss-color :accent)
      (text (expr (format "刷新 %d/%d" (or done 0) (or total 0)))))
    (box :width (list 'ch (string-width (or hint "")))
         :flex-shrink 0 :height '(lh 1) :text-align 'right :overflow 'hidden
         :color (etaf-rss-color :dim)
      (text (expr (or hint ""))))))

(provide 'etaf-rss-views)
;;; etaf-rss-views.el ends here
