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
    (&key model scope summary query narrow search-width on-scope on-search)
  "Render the list name, the scopes and the search field."
  :view
  (column :width 'stretch :item-gap '(lh 0)
        :border-bottom (maillist--border (maillist-color :line))
    (flex :if (not narrow) :width 'stretch :height '(lh 3)
          :align-items 'center
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
                         :on-change on-search)
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
      (etaf-label :text summary :variant 'muted))
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
        (etaf-label :text summary :variant 'muted)))
    ))

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
         :color (maillist-color :dim)
      (text (expr (if (plist-get thread :count)
                      (number-to-string (plist-get thread :count))
                    ""))))
    (box :width '(ch 5) :height '(lh 1) :text-align 'right
         :color (maillist-color :dim)
      (text (expr (maillist-time-label (plist-get thread :date)))))
    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :height '(lh 1) :overflow 'hidden
         :font-weight (if (plist-get thread :unread) 'bold 'normal)
         :color (if (plist-get thread :unread)
                    (maillist-color :ink)
                  (maillist-color :muted))
      (text (expr (or (plist-get thread :subject) ""))))))

(etaf-define-component maillist-thread-list (&key groups selected searching on-press)
  "Render GROUPS of thread rows, each labelled by its date."
  :view
  (column :width 'stretch :height 'stretch :overflow 'scroll
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
        (etaf-label :text (car group) :variant 'strong))
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
    (column :if (not (plist-get message :collapsed))
            :width 'stretch :item-gap '(lh 0)
            :padding (list (list 'lh 0) (list 'ch 2))
      (maillist-body-line :for (line (plist-get message :lines))
                            :key (plist-get line :id)
                            :line line)
      (box :height '(lh 1)))))

(etaf-define-component maillist-reader (&key thread narrow on-message on-back on-earlier)
  "Render the open THREAD: a fixed header above a scrolling body."
  :view
  (flex :flex-direction 'column :width 'stretch :height 'stretch
        :overflow 'hidden
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
          :flex-shrink 0 :height 'stretch
      (maillist-thread-list :groups groups :selected selected :searching searching
                              :on-press on-select))
    (etaf-pane-resizer :if (and show-list show-reader)
                       :ref 'maillist-splitter
                       :size width-ref
                       :min 240 :max max-list-width
                       :on-change on-resize)
    (flex :if show-reader :flex-direction 'column
          :width (if narrow 'stretch 'stretch)
          :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          :height 'stretch :overflow 'hidden
      (column :if (null thread) :width 'stretch :height 'stretch
              :overflow 'scroll :ref 'maillist-reader
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

(etaf-define-component maillist-footer (&key narrow)
  "Render the key hints of the client."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (etaf-divider)
    (flex :width 'stretch :height '(lh 1) :align-items 'center
          :padding (list (list 'lh 0) (list 'ch 2))
      (etaf-label :text (if narrow
                            "j/k 移动 · RET 打开 · s 收藏 · / 搜索 · ? 帮助"
                          "j/k 移动    RET 打开    s 收藏    r 回复    c 写新帖    e 更早    / 搜索    g 刷新    ? 帮助")
                  :variant 'muted))))

(etaf-define-component maillist-app
    (&key model viewport viewport-px list-width groups selected thread scope summary
          status toast query reading keys on-select on-message on-scope on-search
          on-back on-earlier on-resize)
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
     (flex :flex-direction 'column :width 'stretch :height 'stretch
           :min-height '(lh 0) :keys keys
       (maillist-appbar :model model
                        :scope (etaf-value scope)
                        :summary (etaf-value summary)
                        :query (etaf-value query)
                        :narrow narrow
                        :search-width (max 34 (min 56 (- width 78)))
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
