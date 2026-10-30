;;; maillist-views.el --- Views of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation layer.  Components take plain values plus callbacks and never
;; read the session directly; the application Component is the one place that
;; reads reactive sources, so an interaction repaints one subtree.  Every
;; color comes from `maillist-color', derived from the active Emacs theme.
;;
;; The wide layout is a thread list beside the open thread.  Below
;; `maillist-narrow-width' the same components show one column: the list, or
;; the open thread with a way back.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'maillist-theme)

(defcustom maillist-narrow-width 104
  "Viewport width below which the client shows one column."
  :type 'integer
  :group 'maillist)

(defun maillist--border (color)
  "Return a one-pixel solid border drawn with COLOR."
  (list '(px 1) 'solid color))

(defun maillist--hover ()
  "Return the hover declarations of a selectable row."
  (list :background-color (maillist-color :line-soft)))

;;; ---------------------------------------------------------------------------
;;; Header
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-appbar
    (&key model scope summary query narrow columns search-width on-scope on-search)
  "Render the list name, the scopes and the search field."
  :view
  (column :width 'stretch :item-gap '(lh 0)
        :border-bottom (maillist--border (maillist-color :line))
    ;; The controls take the room that is left after the summary keeps its
    ;; own width: a spacer that grows first would push the summary past the
    ;; canvas as soon as the window narrows.
    (column :if (not narrow) :width 'stretch :height '(lh 3)
      (flex :width 'stretch :height '(lh 3) :align-items 'center
            :padding (list (list 'lh 0) (list 'ch 2))
            :gap (list (list 'lh 0) (list 'ch 2))
        (box :height '(lh 1) :font-weight 'bold :color (maillist-color :ink)
          (text (expr (plist-get model :list-name))))
        (etaf-segmented :value scope
                        :options '((all . "全部")
                                   (unread . "未读")
                                   (starred . "已收藏"))
                        :on-change on-scope)
        (etaf-search-field :value query
                           :icon t
                           :ref 'maillist-search
                           :placeholder "搜索标题或正文"
                           :width (list 'ch search-width)
                           :on-change on-search))
      ;; The summary is placed on the row rather than joining the flex line:
      ;; a growing spacer would push it past the canvas as the window
      ;; narrows, and the field keeps the width it needs.
      (box :position 'absolute :top (list 'lh 1)
           :left (list 'ch (max 0 (- columns 2 (string-width summary))))
           :width (list 'ch (string-width summary)) :height '(lh 1)
           :overflow 'hidden
        (etaf-label :text summary :variant 'muted)))
    (column :if narrow :width 'stretch :item-gap '(lh 0)
      (flex :width 'stretch :height '(lh 1) :align-items 'center
            :padding (list (list 'lh 0) (list 'ch 2))
            :gap (list (list 'lh 0) (list 'ch 2))
        (box :height '(lh 1) :font-weight 'bold :color (maillist-color :ink)
          (text (expr (plist-get model :list-name))))
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
        (etaf-segmented :value scope
                        :options '((all . "全部")
                                   (unread . "未读")
                                   (starred . "已收藏"))
                        :on-change on-scope))
      (flex :width 'stretch :height '(lh 3) :align-items 'center
            :padding (list (list 'lh 0) (list 'ch 2))
        (etaf-search-field :value query
                           :icon t
                           :ref 'maillist-search
                           :placeholder "搜索"
                           :width 'stretch
                           :on-change on-search))
      (flex :width 'stretch :height '(lh 1) :align-items 'center
            :padding (list (list 'lh 0) (list 'ch 2))
        (etaf-label :text summary :variant 'muted)))))

;;; ---------------------------------------------------------------------------
;;; Thread list
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-thread-row (&key thread selected on-press)
  "Render one THREAD row; SELECTED marks the open row."
  :view
  (flex :width 'stretch :height '(lh 1) :align-items 'center
        :padding (list (list 'lh 0) (list 'ch 1))
        :gap (list (list 'lh 0) (list 'ch 1))
        :background-color (when selected (maillist-color :select))
        :hover-style (unless selected (maillist--hover))
        :role 'button :tab-index 0 :pointer 'hand
        :ref (intern (concat "maillist-thread-" (plist-get thread :id)))
        :help-echo (plist-get thread :subject)
        :on-press on-press
    (box :width '(ch 1) :height '(lh 1)
         :color (cond ((plist-get thread :starred) (maillist-color :warning))
                      ((plist-get thread :unread) (maillist-color :accent))
                      (t (maillist-color :dim)))
      (text (expr (cond ((plist-get thread :starred) "+")
                        ((plist-get thread :unread) "*")
                        (t " ")))))
    (box :width '(ch 18) :height '(lh 1) :overflow 'hidden
         :color (cond ((string-empty-p (or (plist-get thread :author) ""))
                       (maillist-color :dim))
                      ((plist-get thread :unread) (maillist-color :ink))
                      (t (maillist-color :muted)))
      (text (expr (let ((author (plist-get thread :author)))
                    (if (string-empty-p (or author "")) "…" author)))))
    (box :width '(ch 3) :height '(lh 1) :text-align 'right
         :color (if (plist-get thread :count)
                    (maillist-color :muted)
                  (maillist-color :dim))
      (text (expr (if (plist-get thread :count)
                      (number-to-string (plist-get thread :count))
                    ""))))
    (box :width '(ch 5) :height '(lh 1) :text-align 'right
         :color (maillist-color :dim)
      (text (expr (maillist-time-label (plist-get thread :date)))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
         :font-weight (if (plist-get thread :unread) 'bold 'normal)
         :color (cond ((plist-get thread :new) (maillist-color :accent))
                      ((plist-get thread :unread) (maillist-color :subject))
                      (t (maillist-color :muted)))
      (text (expr (or (plist-get thread :subject) ""))))
    ;; A search that fell back to the cache matched the body, so the row
    ;; names the text that matched beside the thread it belongs to.
    (box :if (plist-get thread :snippet)
         :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
         :color (maillist-color :dim)
      (text (expr (or (plist-get thread :snippet) ""))))))

(etaf-define-component maillist-thread-list (&key groups selected searching on-press)
  "Render GROUPS of thread rows, each labelled by its date."
  :view
  (column :width 'stretch :height 'stretch :min-height '(lh 0)
          :overflow 'scroll
          :ref 'maillist-thread-list :role 'region :tab-index 0
          :aria-label "线程列表"
          :item-gap '(lh 0)
          :padding (list (list 'lh 0) (list 'ch 0))
    (column :if (null groups) :width 'stretch :height 'stretch
            :padding (list (list 'lh 3) (list 'ch 2))
      (etaf-empty :title (if searching "没有匹配的线程" "这里还没有线程")
                  :description (if searching
                                   "换个关键词，或清空搜索框回到列表。"
                                 "按 g 从邮件列表档案同步。")))
    (column :for (group groups) :key (car group)
            :width 'stretch :item-gap '(lh 0)
      (box :if (not (eq group (car groups))) :height '(lh 1))
      (flex :align-items 'center :height '(lh 1)
            :padding (list (list 'lh 0) (list 'ch 1))
            :gap (list (list 'lh 0) (list 'ch 1))
        (box :height '(lh 1) :color (maillist-color :muted)
          (text (expr (car group))))
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height '(lh 1)
             :border-bottom (maillist--border (maillist-color :line-soft))))
      (maillist-thread-row :for (thread (cdr group))
                             :key (plist-get thread :id)
                             :thread thread
                             :selected (equal (plist-get thread :id) selected)
                             :on-press (lambda () (funcall on-press (plist-get thread :id)))))))

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-body-line (&key line)
  "Render one body LINE: prose, quote, patch marker or patch diff."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (box :if (equal (plist-get line :kind) "blank") :height '(lh 1))
    (flex :if (not (equal (plist-get line :kind) "blank"))
          :width 'stretch :align-items 'flex-start
          :gap (list (list 'lh 0) (list 'ch 1))
          :background-color
          (pcase (plist-get line :kind)
            ("quote" (maillist-color :quote-bg))
            ("patch-add" (maillist-color :ok-soft))
            ("patch-del" (maillist-color :danger-soft))
            (_ nil))
      (box :if (equal (plist-get line :kind) "quote")
           :width '(ch 1) :height '(lh 1) :color (maillist-color :line)
        (text "|"))
      (etaf-label :text (plist-get line :text)
                  :variant (cond ((equal (plist-get line :kind) "quote") 'muted)
                                 ((equal (plist-get line :kind) "patch-add") 'success)
                                 ((equal (plist-get line :kind) "patch-del") 'danger)
                                 ((member (plist-get line :kind) '("patch-meta" "patch-label")) 'muted)
                                 (t nil))
                  :width 'stretch :wrap-mode 'word))))

(etaf-define-component maillist-message (&key message on-press)
  "Render one MESSAGE of the open thread."
  :view
  (column :width 'stretch :item-gap '(lh 0)
          :padding (list (list 'lh 0)
                         (list 'ch (* 2 (or (plist-get message :depth) 0))))
    (flex :width 'stretch :height '(lh 1) :align-items 'center
          :gap (list (list 'lh 0) (list 'ch 1))
          :role 'button :tab-index 0 :pointer 'hand
          :ref (intern (concat "maillist-message-" (plist-get message :id)))
          :hover-style (maillist--hover)
          :on-press on-press
      (box :width '(ch 1) :color (maillist-color :dim)
           (text (expr (if (plist-get message :collapsed) ">" "v"))))
      (box :font-weight 'bold :height '(lh 1)
           :color (maillist-color :ink)
        (text (expr (or (plist-get message :author) ""))))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
      (etaf-label :text (maillist-long-label (plist-get message :date))
                  :variant 'muted))
    (flex :if (plist-get message :reply-to)
          :width 'stretch :height '(lh 1) :align-items 'center
          :gap (list (list 'lh 0) (list 'ch 1))
      (box :height '(lh 1) :color (maillist-color :dim)
        (text "↳"))
      (box :height '(lh 1) :color (maillist-color :muted)
        (text "reply to"))
      (box :height '(lh 1) :color (maillist-color :warning)
        (text (expr (plist-get message :reply-to)))))
    (column :if (not (plist-get message :collapsed))
            :width 'stretch :item-gap '(lh 0)
            :padding (list (list 'lh 0) (list 'ch 2))
      (maillist-body-line :for (line (plist-get message :lines))
                            :key (plist-get line :id)
                            :line line)
      (box :height '(lh 1))
      (maillist-message-links :if (plist-get message :links)
                              :links (plist-get message :links)))))

(etaf-define-component maillist-message-links (&key links)
  "Render the LINKS a message mentions, each opened by its own press."
  :view
  (column :width 'stretch :item-gap '(lh 0)
          :padding (list (list 'lh 0.5) (list 'ch 2))
    (etaf-label :text "链接" :variant 'muted)
    (flex :for (link links)
          :key link
          :width 'stretch :height '(lh 1) :align-items 'center
          :gap (list (list 'lh 0) (list 'ch 1))
          :role 'button :tab-index 0 :pointer 'hand
          :ref (intern (concat "maillist-link-" link))
          :hover-style (maillist--hover)
          :on-press (lambda () (browse-url link))
      (box :width '(ch 1) :color (maillist-color :accent) (text "↗"))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
           :height '(lh 1) :overflow 'hidden
           :color (maillist-color :accent)
           :text-decoration-line 'underline
        (text (expr link))))))

(etaf-define-component maillist-reader (&key thread narrow on-message on-back on-earlier)
  "Render the open THREAD: a fixed header above a scrolling body."
  :view
  (flex :flex-direction 'column :width 'stretch :height 'stretch
        :min-height '(lh 0) :overflow 'hidden
        :padding (list (list 'lh 1) (list 'ch 2))
    (column :width 'stretch :flex-shrink 0 :item-gap '(lh 0)
      (flex :if narrow :height '(lh 1) :align-items 'center
        (etaf-button :label "← 列表" :variant 'ghost :on-press on-back))
      (etaf-label :text (plist-get thread :subject)
                  :variant 'heading :width 'stretch :wrap-mode 'word)
      (box :height '(lh 1))
      (etaf-label :text (plist-get thread :meta)
                  :variant (if (plist-get thread :error) 'danger 'muted))
      (box :height '(lh 1) :width 'stretch
           :border-bottom (maillist--border (maillist-color :line))))
    (column :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
            :overflow 'scroll :ref 'maillist-reader :role 'region :tab-index 0
            :aria-label "邮件正文"
            :item-gap '(lh 0)
            :padding (list (list 'lh 1) (list 'ch 0))
      (flex :if (plist-get thread :loading) :height '(lh 2) :align-items 'center
        (etaf-skeleton :width '(ch 24) :height '(lh 1)))
      (flex :if (> (or (plist-get thread :hidden) 0) 0)
            :width 'stretch :height '(lh 1) :align-items 'center
            :role 'button :tab-index 0 :pointer 'hand
            :ref 'maillist-earlier
            :hover-style (maillist--hover)
            :on-press on-earlier
        (etaf-label :text (format "↑ 更早的 %d 封邮件（按 e 展开）"
                                  (plist-get thread :hidden))
                    :variant 'muted))
      (maillist-message :for (message (plist-get thread :messages))
                          :key (plist-get message :id)
                          :message message
                          :on-press (lambda () (funcall on-message (plist-get message :id)))))))

;;; ---------------------------------------------------------------------------
;;; Shell
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-pane
    (&key groups selected thread narrow show-list show-reader list-width width-ref
          max-list-width searching on-select on-message on-back on-earlier on-resize)
  "Render the list and the open thread, with a draggable divider between them."
  :view
  (flex :flex-direction (if narrow 'column 'row)
        :width 'stretch :height 'stretch
        :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
    (flex :if show-list :flex-direction 'column
          :width (if narrow 'stretch (list 'px list-width))
          :flex-shrink 0 :height 'stretch :min-height '(lh 0)
      (maillist-thread-list :groups groups :selected selected :searching searching
                              :on-press on-select))
    (etaf-pane-resizer :if (and show-list show-reader)
                       :ref 'maillist-splitter
                       :size width-ref
                       :min 240 :max max-list-width
                       :on-change on-resize)
    (flex :if show-reader :flex-direction 'column
          ;; Beside the list the reader takes the room that is left; `stretch'
          ;; there would ask for the whole row and run under the canvas.
          :width (if narrow 'stretch '(ch 0))
          :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          :height 'stretch :min-height '(lh 0) :overflow 'hidden
      (column :if (null thread) :width 'stretch :height 'stretch
              :min-height '(lh 0) :overflow 'scroll :ref 'maillist-reader
              :padding (list (list 'lh 3) (list 'ch 2))
        (etaf-empty :title "没有打开的线程"
                    :description "在左侧列表里选择一个线程，或用 j / k 移动。"))
      (maillist-reader :if thread :thread thread :narrow narrow
                         :on-message on-message :on-back on-back
                         :on-earlier on-earlier))))

(etaf-define-component maillist-toast (&key toast left)
  "Render TOAST as a floating notice at LEFT columns.
Absolute placement keeps it out of the layout, so a sync message never moves
the list or the reader.  The surface is the theme's raised row colour, the
border is the divider hairline, and only the left stripe carries the
semantic colour."
  :view
  (box :if toast :position 'absolute :layer 'root :z-index 1000
       :left (list 'ch left) :top '(lh 4)
       :width '(ch 46) :role 'status :aria-label "通知"
       :background-color (maillist-color :select)
       :border-top (maillist--border (maillist-color :line))
       :border-right (maillist--border (maillist-color :line))
       :border-bottom (maillist--border (maillist-color :line))
       :border-left (list '(px 3) 'solid
                          (if (eq (plist-get toast :kind) 'error)
                              (maillist-color :danger)
                            (maillist-color :accent)))
       :border-radius '(px 8)
       :padding (list (list 'lh 0.75) (list 'ch 2))
    (etaf-label :text (plist-get toast :text)
                :width 'stretch :wrap-mode 'word)))

(etaf-define-component maillist-hints (&key narrow)
  "Render the key hints with the keys in the accent colour."
  :view
  (flex :width 'stretch :height '(lh 1) :align-items 'center
        :gap (list (list 'lh 0) (list 'ch 1))
    (maillist-hint :caps "j/k" :label "移动")
    (maillist-hint :caps "RET" :label "打开")
    (maillist-hint :caps "s" :label "收藏")
    (maillist-hint :caps "M-u" :label "未读")
    (maillist-hint :caps "A" :label "已读")
    (maillist-hint :caps "o" :label "更早")
    (maillist-hint :caps "/" :label "搜索")
    (maillist-hint :if (not narrow) :caps "r" :label "回复")
    (maillist-hint :if (not narrow) :caps "c" :label "写新帖")
    (maillist-hint :if (not narrow) :caps "L" :label "列表")
    (maillist-hint :if (not narrow) :caps "g" :label "刷新")
    (maillist-hint :caps "?" :label "帮助")))

(etaf-define-component maillist-hint (&key caps label)
  "Render one KEY hint with its LABEL."
  :view
  (flex :height '(lh 1) :align-items 'center
        :gap (list (list 'lh 0) (list 'ch 0.5))
    (box :height '(lh 1) :color (maillist-color :subject)
      (text (expr caps)))
    (etaf-label :text label :variant 'muted)))

(etaf-define-component maillist-footer (&key narrow)
  "Render the key hints of the client."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (etaf-divider)
    (flex :width 'stretch :height '(lh 1) :align-items 'center
          :padding (list (list 'lh 0) (list 'ch 2))
      (maillist-hints :narrow narrow))))

(etaf-define-component maillist-app
    (&key model viewport viewport-px viewport-rows list-width groups selected thread
          scope summary status toast query reading keys on-select on-message
          on-scope on-search on-back on-earlier on-resize)
  "Render the whole application, reading its reactive sources."
  :setup
  (etaf-theme-provide (maillist-theme-defaults))
  :render
  (let* ((width (etaf-value viewport))
         (pixels (etaf-value viewport-px))
         (narrow (< width maillist-narrow-width))
         (thread-value (etaf-value thread))
         (show-reader (or (not narrow) (etaf-value reading))))
    (etaf-view
     ;; The canvas is exactly the window body the fit measured.  `vw 100' and
     ;; `vh 100' count the viewport the mount was opened with: they keep the
     ;; old size after a resize, one extra row scrolls the whole page, and the
     ;; hint row runs under the canvas edge.
     (flex :flex-direction 'column
           :width (list 'px (max 240 (or pixels 0)))
           :height (list 'lh (max 8 (etaf-value viewport-rows)))
           :box-sizing 'border-box :overflow 'hidden
           :min-height '(lh 0) :keys keys
       (maillist-appbar :model model
                        :scope (etaf-value scope)
                        :summary (etaf-value summary)
                        :query (etaf-value query)
                        :narrow narrow
                        :columns width
                        ;; The row holds the name, the scopes, the field and
                        ;; the summary; the field gives way first so the
                        ;; summary never runs past the canvas.
                        ;; The field gives way before the summary: the row
                        ;; holds the name, the scopes, the field and the
                        ;; summary within one canvas width.
                        :search-width (max 20 (min 56 (- width 88)))
                        :on-scope on-scope :on-search on-search)
       (maillist-pane :groups (etaf-value groups)
                      :selected (etaf-value selected)
                      :thread thread-value
                      :narrow narrow
                      :searching (not (string-empty-p (etaf-value query)))
                      :show-list (or (not narrow) (not show-reader))
                      :show-reader show-reader
                      :list-width (etaf-value list-width)
                      :width-ref list-width
                      :max-list-width (max 300 (- pixels 420))
                      :on-resize on-resize
                      :on-earlier on-earlier
                      :on-select on-select :on-message on-message :on-back on-back)
       (maillist-footer :narrow narrow)
       (maillist-toast :toast (etaf-value toast)
                       :left (max 0 (- width 48)))))))

(provide 'maillist-views)
;;; maillist-views.el ends here
