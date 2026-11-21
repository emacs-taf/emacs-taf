;;; maillist-views.el --- Views of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation layer.  Components take plain values plus callbacks and never
;; read the session directly; the application Component is the one place that
;; reads reactive sources, so an interaction repaints one subtree.  Every
;; color comes from `maillist-color', derived from the active Emacs theme.
;;
;; The wide layout is a thread list beside the open thread with a draggable
;; divider; the list width is clamped to the live canvas so shrinking a window
;; never pushes the reader off-screen.  Below `maillist-narrow-width' the same
;; components show one column: the list, or the open thread with a way back.
;; Regions (`search', `threads', `reader') and `:focus-group' wire into ETAF's
;; keyboard navigation contract (`M-g', `Tab' and `?').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'maillist-service)
(require 'maillist-theme)

(defvar maillist-narrow-width)

(defun maillist--border (color)
  "Return a one-pixel solid border drawn with COLOR."
  (list '(px 1) 'solid color))

(defun maillist--hover ()
  "Return the hover declarations of a selectable row."
  (list :background-color (maillist-color :line-soft)))

(defun maillist--collapse-quotes (lines hide-quotes)
  "Return LINES with runs of 3+ quoted lines folded when HIDE-QUOTES is non-nil."
  (if (not hide-quotes)
      lines
    (let ((out nil)
          (run nil))
      (cl-flet
          ((flush ()
             (when run
               (let ((chunk (nreverse run)))
                 (if (>= (length chunk) 3)
                     (push (list :id (concat (plist-get (car chunk) :id) "-qfold")
                                 :kind "quote-fold"
                                 :text (format "[已折叠 %d 行引文 · 按 Q 展开]"
                                               (length chunk)))
                           out)
                   (dolist (item chunk) (push item out))))
               (setq run nil))))
        (dolist (line lines)
          (if (equal (plist-get line :kind) "quote")
              (push line run)
            (flush)
            (push line out)))
        (flush))
      (nreverse out))))

;;; ---------------------------------------------------------------------------
;;; Header
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-search-box
    (&key value placeholder on-change on-submit on-clear)
  "Render a rectangular box-model search field with icon and clear button."
  :bindings ((runtime (etaf-current-runtime)))
  :render
  (let ((text (or value "")))
    (etaf-view
     (flex :role 'search :align-items 'center :width 'stretch
           :min-height '(lh 1)
           :padding (list (list 'lh 0) (list 'ch 1))
           :gap (list (list 'lh 0) (list 'ch 1))
           :background-color (maillist-color :surface)
           :border (maillist--border (maillist-color :line))
           :pointer 'text
           :on-press (lambda () (etaf-text-input-begin runtime 'maillist-search))
       (box :flex-shrink 0 :color (maillist-color :muted)
         (expr (etaf-ui-icon 'search :min-width 1)))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         (etaf-text-input :value text
                          :on-change on-change
                          :label placeholder
                          :hide-label t
                          :placeholder placeholder
                          :variant 'plain
                          :width 'stretch
                          :on-submit on-submit
                          :ref 'maillist-search))
       (box :if (not (string-empty-p text))
            :flex-shrink 0 :color (maillist-color :muted) :pointer 'hand
         (expr (etaf-ui-icon 'close :min-width 1 :help-echo "清空搜索"
                             :on-press (lambda ()
                                         (when (etaf-text-input-active-p runtime)
                                           (etaf-text-input-end 'blur))
                                         (funcall on-clear)))))))))

(etaf-define-component maillist-appbar
    (&key model scope summary search-input narrow
          on-scope on-switch-list on-search-change on-search-submit on-search-clear)
  "Render the list name, the scopes, the search box and the summary."
  :view
  (column :width 'stretch :item-gap '(lh 0)
          :region '(:id search :label "搜索与筛选" :key "f"
                        :enter maillist-search :neighbors (:down threads))
          :border-bottom (maillist--border (maillist-color :line))
    ;; Normal flex allocation guarantees the search box yields room to the
    ;; summary at every wide width without overlapping or running past the edge.
    (flex :if (not narrow) :width 'stretch :height '(lh 2) :align-items 'center
          :padding (list (list 'lh 0) (list 'ch 2))
          :gap (list (list 'lh 0) (list 'ch 2))
      (flex :flex-shrink 0 :height '(lh 1) :align-items 'center
            :gap (list (list 'lh 0) (list 'ch 0.5))
            :role 'button :tab-index 0 :pointer 'hand
            :help-echo "切换或添加邮件列表（L）"
            :hover-style (maillist--hover)
            :on-press on-switch-list
        (box :height '(lh 1) :font-weight 'bold :color (maillist-color :ink)
          (text (expr (plist-get model :list-name))))
        (box :height '(lh 1) :color (maillist-color :muted)
          (text "▾")))
      (box :flex-shrink 0
        (etaf-segmented :value scope
                        :options '((all . "全部")
                                   (unread . "未读")
                                   (starred . "已收藏"))
                        :on-change on-scope))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 14)
        (maillist-search-box :value search-input
                             :placeholder "搜索标题或正文"
                             :on-change on-search-change
                             :on-submit on-search-submit
                             :on-clear on-search-clear))
      (box :flex-shrink 0 :height '(lh 1) :overflow 'hidden
        (etaf-label :text summary :variant 'muted)))
    (column :if narrow :width 'stretch :item-gap '(lh 0)
      (flex :width 'stretch :height '(lh 1) :align-items 'center
            :padding (list (list 'lh 0) (list 'ch 2))
            :gap (list (list 'lh 0) (list 'ch 2))
        (flex :flex-shrink 0 :height '(lh 1) :align-items 'center
              :gap (list (list 'lh 0) (list 'ch 0.5))
              :role 'button :tab-index 0 :pointer 'hand
              :help-echo "切换或添加邮件列表（L）"
              :hover-style (maillist--hover)
              :on-press on-switch-list
          (box :height '(lh 1) :font-weight 'bold :color (maillist-color :ink)
            (text (expr (plist-get model :list-name))))
          (box :height '(lh 1) :color (maillist-color :muted)
            (text "▾")))
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
        (box :flex-shrink 0
          (etaf-segmented :value scope
                          :options '((all . "全部")
                                     (unread . "未读")
                                     (starred . "已收藏"))
                          :on-change on-scope)))
      (flex :width 'stretch :height '(lh 2) :align-items 'center
            :padding (list (list 'lh 0) (list 'ch 2))
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
          (maillist-search-box :value search-input
                               :placeholder "搜索标题或正文"
                               :on-change on-search-change
                               :on-submit on-search-submit
                               :on-clear on-search-clear)))
      (flex :width 'stretch :height '(lh 1) :align-items 'center
            :padding (list (list 'lh 0) (list 'ch 2))
        (etaf-label :text summary :variant 'muted)))))

;;; ---------------------------------------------------------------------------
;;; Thread list
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-thread-row (&key thread selected compact-author on-press)
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
    ;; Dedicated two-cell status indicator (`*' starred, `+' unread) in one
    ;; node so both marks show simultaneously without adding per-row nodes.
    (box :width '(ch 2) :flex-shrink 0 :height '(lh 1)
         :color (cond ((plist-get thread :starred) (maillist-color :warning))
                      ((plist-get thread :unread) (maillist-color :accent))
                      (t (maillist-color :dim)))
      (text (expr (concat (if (plist-get thread :starred) "*" " ")
                          (if (plist-get thread :unread) "+" " ")))))
    (box :width (list 'ch (if compact-author 12 16)) :flex-shrink 0
         :height '(lh 1) :overflow 'hidden
         :color (cond ((string-empty-p (or (plist-get thread :author) ""))
                       (maillist-color :dim))
                      ((plist-get thread :unread) (maillist-color :ink))
                      (t (maillist-color :muted)))
      (text (expr (let ((author (plist-get thread :author)))
                    (if (string-empty-p (or author "")) "…" author)))))
    (box :width '(ch 4) :flex-shrink 0 :height '(lh 1) :text-align 'right
         :color (if (plist-get thread :count)
                    (maillist-color :muted)
                  (maillist-color :dim))
      (text (expr (if (plist-get thread :count)
                      (number-to-string (plist-get thread :count))
                    ""))))
    (box :width '(ch 5) :flex-shrink 0 :height '(lh 1) :text-align 'right
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

(etaf-define-component maillist-thread-list
    (&key groups selected scope searching compact-author on-press)
  "Render GROUPS of thread rows, each labelled by its date."
  :view
  (column :width 'stretch :height 'stretch :min-height '(lh 0)
          :overflow 'scroll
          :focus-group 'vertical
          :region '(:id threads :label "线程列表" :key "t"
                        :neighbors (:up search :right reader))
          :ref 'maillist-thread-list :role 'region :tab-index 0
          :aria-label "线程列表"
          :item-gap '(lh 0)
          :padding (list (list 'lh 0) (list 'ch 0))
    (column :if (null groups) :width 'stretch :height 'stretch
            :padding (list (list 'lh 3) (list 'ch 2))
      (etaf-empty
       :title (cond (searching "没有匹配的线程")
                    ((eq scope 'starred) "还没有收藏的线程")
                    ((eq scope 'unread) "没有未读线程")
                    (t "这里还没有线程"))
       :description (cond (searching "换个关键词，或清空搜索框回到列表。")
                          ((eq scope 'starred) "在列表中按 s 收藏线程，或按 1 返回全部。")
                          ((eq scope 'unread) "当前列表已全部读完，按 1 返回全部或按 g 同步。")
                          (t "按 g 从邮件列表档案同步。"))))
    (column :for (group groups) :key (car group)
            :width 'stretch :item-gap '(lh 0)
      (box :if (not (eq group (car groups))) :height '(lh 1))
      (flex :align-items 'center :height '(lh 1)
            :padding (list (list 'lh 0) (list 'ch 1))
            :gap (list (list 'lh 0) (list 'ch 1))
        (box :flex-shrink 0 :height '(lh 1) :color (maillist-color :muted)
          (text (expr (car group))))
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
             :height '(lh 1)
             :border-bottom (maillist--border (maillist-color :line-soft))))
      (maillist-thread-row :for (thread (cdr group))
                           :key (plist-get thread :id)
                           :thread thread
                           :selected (equal (plist-get thread :id) selected)
                           :compact-author compact-author
                           :on-press (lambda () (funcall on-press (plist-get thread :id)))))))

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-body-line (&key line on-toggle-quotes)
  "Render one body LINE: prose, quote, folded quote, signature or diff."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (box :if (equal (plist-get line :kind) "blank") :height '(lh 1))
    (flex :if (equal (plist-get line :kind) "quote-fold")
          :width 'stretch :height '(lh 1) :align-items 'center
          :background-color (maillist-color :quote-bg)
          :border-left (list '(px 2) 'solid (maillist-color :dim))
          :padding-left '(ch 1)
          :role 'button :tab-index 0 :pointer 'hand
          :hover-style (maillist--hover)
          :on-press on-toggle-quotes
      (etaf-label :text (plist-get line :text) :variant 'muted))
    (box :if (equal (plist-get line :kind) "quote")
         :width 'stretch
         :background-color (maillist-color :quote-bg)
         :border-left (list '(px 2) 'solid
                            (if (> (or (plist-get line :quote-depth) 1) 1)
                                (maillist-color :dim)
                              (maillist-color :line)))
         :padding-left '(ch 1)
      (etaf-label :text (plist-get line :text)
                  :variant 'muted
                  :width 'stretch :wrap-mode 'word))
    (flex :if (not (member (plist-get line :kind) '("blank" "quote" "quote-fold")))
          :width 'stretch :align-items 'flex-start
          :background-color
          (pcase (plist-get line :kind)
            ("patch-add" (maillist-color :ok-soft))
            ("patch-del" (maillist-color :danger-soft))
            (_ nil))
      (etaf-label :text (plist-get line :text)
                  :variant (cond ((equal (plist-get line :kind) "patch-add") 'success)
                                 ((equal (plist-get line :kind) "patch-del") 'danger)
                                 ((member (plist-get line :kind) '("patch-meta" "signature")) 'muted)
                                 (t nil))
                  :width 'stretch :wrap-mode 'word))))

(etaf-define-component maillist-message-links (&key links)
  "Render the LINKS a message mentions, each opened by its own press."
  :view
  (column :width 'stretch :item-gap '(lh 0)
          :padding-top '(lh 0.5) :padding-left '(ch 2)
    (etaf-label :text "链接" :variant 'muted)
    (flex :for (link links)
          :key link
          :width 'stretch :height '(lh 1) :align-items 'center
          :gap (list (list 'lh 0) (list 'ch 1))
          :role 'button :tab-index 0 :pointer 'hand
          :hover-style (maillist--hover)
          :on-press (lambda () (browse-url link))
      (box :width '(ch 1) :flex-shrink 0 :color (maillist-color :accent) (text "↗"))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
           :height '(lh 1) :overflow 'hidden
           :color (maillist-color :accent)
           :text-decoration-line 'underline
        (text (expr link))))))

(etaf-define-component maillist-message
    (&key message focused is-first-new hide-quotes on-press on-toggle-quotes)
  "Render one MESSAGE of the open thread.
Nesting indents the left edge only and caps at depth 6 so deep discussions
remain readable on ordinary viewports."
  :view
  (column :width 'stretch :item-gap '(lh 0)
          :padding-left (list 'ch (* 2 (min 6 (or (plist-get message :depth) 0))))
    (flex :if is-first-new :width 'stretch :height '(lh 1) :align-items 'center
          :gap (list (list 'lh 0) (list 'ch 1))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
           :height '(lh 1)
           :border-bottom (maillist--border (maillist-color :accent)))
      (box :flex-shrink 0 :height '(lh 1) :color (maillist-color :accent)
        (text "新回复"))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
           :height '(lh 1)
           :border-bottom (maillist--border (maillist-color :accent))))
    (flex :width 'stretch :height '(lh 1) :align-items 'center
          :gap (list (list 'lh 0) (list 'ch 1))
          :padding-left '(ch 1)
          :border-left (list '(px 2) 'solid
                             (if focused (maillist-color :accent)
                               (maillist-color :bg)))
          :background-color (when focused (maillist-color :select))
          :role 'button :tab-index 0 :pointer 'hand
          :ref (intern (concat "maillist-message-" (plist-get message :id)))
          :hover-style (unless focused (maillist--hover))
          :on-press on-press
      (box :width '(ch 2) :flex-shrink 0 :height '(lh 1)
           :color (if focused (maillist-color :accent) (maillist-color :dim))
           (text (expr (if (plist-get message :collapsed) "▸" "▾"))))
      (box :font-weight 'bold :height '(lh 1) :flex-shrink 0
           :color (maillist-color :ink)
        (text (expr (or (plist-get message :author) ""))))
      (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
      (box :flex-shrink 0
        (etaf-label :text (maillist-long-label (plist-get message :date))
                    :variant 'muted)))
    (flex :if (plist-get message :reply-to)
          :width 'stretch :height '(lh 1) :align-items 'center
          :padding-left '(ch 1)
          :gap (list (list 'lh 0) (list 'ch 1))
      (box :flex-shrink 0 :height '(lh 1) :color (maillist-color :dim)
        (text "↳"))
      (box :flex-shrink 0 :height '(lh 1) :color (maillist-color :muted)
        (text "回复"))
      (box :flex-shrink 0 :height '(lh 1) :color (maillist-color :warning)
        (text (expr (plist-get message :reply-to)))))
    (column :if (not (plist-get message :collapsed))
            :width 'stretch :item-gap '(lh 0)
            :padding-left '(ch 3)
      (maillist-body-line
       :for (line (maillist--collapse-quotes (plist-get message :lines) hide-quotes))
       :key (plist-get line :id)
       :line line
       :on-toggle-quotes on-toggle-quotes)
      (maillist-message-links :if (plist-get message :links)
                              :links (plist-get message :links)))
    (box :height '(lh 1))))

(etaf-define-component maillist-reader
    (&key thread focused-message hide-quotes narrow
          on-message on-back on-earlier on-toggle-quotes)
  "Render the open THREAD: a fixed header above a scrolling body."
  :view
  (flex :flex-direction 'column :width 'stretch :height 'stretch
        :min-height '(lh 0) :overflow 'hidden
        :region '(:id reader :label "邮件正文" :key "v"
                      :enter maillist-reader :neighbors (:up search :left threads))
        :padding (list (list 'lh 1) (list 'ch 2))
    (column :width 'stretch :flex-shrink 0 :item-gap '(lh 0)
      (flex :if narrow :height '(lh 1) :align-items 'center
        (etaf-button :label "← 列表" :variant 'ghost :on-press on-back))
      (etaf-label :text (plist-get thread :subject)
                  :variant 'heading :width 'stretch :wrap-mode 'word)
      (box :height '(lh 1))
      (flex :width 'stretch :height '(lh 1) :align-items 'center
            :gap (list (list 'lh 0) (list 'ch 1))
        (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :overflow 'hidden
          (etaf-label :text (plist-get thread :meta)
                      :variant (if (plist-get thread :error) 'danger 'muted)))
        (box :if (plist-get thread :starred)
             :flex-shrink 0 :height '(lh 1)
             :color (maillist-color :warning)
          (text "* 已收藏")))
      (box :height '(lh 1) :width 'stretch
           :border-bottom (maillist--border (maillist-color :line))))
    (column :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
            :overflow 'scroll :ref 'maillist-reader :role 'region :tab-index 0
            :aria-label "邮件正文"
            :item-gap '(lh 0)
            :padding (list (list 'lh 1) (list 'ch 0))
      ;; Only show a loading skeleton when no cached messages are on screen yet.
      (flex :if (and (plist-get thread :loading)
                     (null (plist-get thread :messages)))
            :height '(lh 2) :align-items 'center
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
                        :focused (equal (plist-get message :id) focused-message)
                        :is-first-new (equal (plist-get message :id)
                                             (plist-get thread :first-new-id))
                        :hide-quotes hide-quotes
                        :on-toggle-quotes on-toggle-quotes
                        :on-press (lambda () (funcall on-message (plist-get message :id)))))))

;;; ---------------------------------------------------------------------------
;;; Shell
;;; ---------------------------------------------------------------------------

(etaf-define-component maillist-pane
    (&key groups selected scope thread focused-message hide-quotes narrow show-list
          show-reader list-width compact-author width-ref max-list-width
          searching on-select on-message on-back on-earlier on-resize
          on-toggle-quotes)
  "Render the list and the open thread, with a draggable divider between them."
  :view
  (flex :flex-direction (if narrow 'column 'row)
        :width 'stretch :height 'stretch
        :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0)
    (flex :if show-list :flex-direction 'column
          :width (if narrow 'stretch (list 'px list-width))
          :flex-shrink 0 :height 'stretch :min-height '(lh 0)
      (maillist-thread-list :groups groups :selected selected
                            :scope scope
                            :searching searching
                            :compact-author compact-author
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
              :role 'region :tab-index 0 :aria-label "邮件正文"
              :region '(:id reader :label "邮件正文" :key "v"
                            :enter maillist-reader :neighbors (:up search :left threads))
              :padding (list (list 'lh 3) (list 'ch 2))
        (etaf-empty :title "没有打开的线程"
                    :description "在左侧列表里选择一个线程，或用 j / k 移动。"))
      (maillist-reader :if thread :thread thread
                       :focused-message focused-message
                       :hide-quotes hide-quotes
                       :narrow narrow
                       :on-message on-message :on-back on-back
                       :on-earlier on-earlier
                       :on-toggle-quotes on-toggle-quotes))))

(etaf-define-component maillist-toast (&key toast left top width)
  "Render TOAST as a rectangular floating notice at (LEFT, TOP) with WIDTH.
Absolute placement keeps it out of the layout, positioned at the bottom-right
above the footer so notices never cover the header or thread subject."
  :view
  (box :if toast :position 'absolute :layer 'root :z-index 1000
       :left (list 'ch left) :top (list 'lh top)
       :width (list 'ch width) :role 'status :aria-label "通知"
       :background-color (maillist-color :select)
       :color (maillist-color :ink)
       :border-top (maillist--border (maillist-color :line))
       :border-right (maillist--border (maillist-color :line))
       :border-bottom (maillist--border (maillist-color :line))
       :border-left (list '(px 3) 'solid
                          (if (eq (plist-get toast :kind) 'error)
                              (maillist-color :danger)
                            (maillist-color :accent)))
       :padding (list (list 'lh 0) (list 'ch 2))
    (etaf-label :text (plist-get toast :text)
                :width 'stretch :wrap-mode 'word)))

(etaf-define-component maillist-hint (&key caps label)
  "Render one KEY hint with its LABEL."
  :view
  (flex :flex-shrink 0 :height '(lh 1) :align-items 'center
        :gap (list (list 'lh 0) (list 'ch 0.5))
    (box :height '(lh 1) :color (maillist-color :subject)
      (text (expr caps)))
    (etaf-label :text label :variant 'muted)))

(etaf-define-component maillist-hints (&key columns)
  "Render key hints budgeted to COLUMNS so the bar never clips past the canvas."
  :view
  (flex :width 'stretch :height '(lh 1) :align-items 'center
        :overflow 'hidden
        :gap (list (list 'lh 0) (list 'ch 1))
    (maillist-hint :caps "j/k" :label "移动")
    (maillist-hint :caps "RET" :label "打开")
    (maillist-hint :caps "n/p" :label "未读")
    (maillist-hint :caps "s" :label "收藏")
    (maillist-hint :caps "M-u" :label "标未读")
    (maillist-hint :caps "A" :label "全已读")
    (maillist-hint :caps "/" :label "搜索")
    (maillist-hint :if (>= columns 104) :caps "o" :label "更早")
    (maillist-hint :if (>= columns 104) :caps "r" :label "回复")
    (maillist-hint :if (>= columns 114) :caps "c" :label "新帖")
    (maillist-hint :if (>= columns 114) :caps "L" :label "列表")
    (maillist-hint :if (>= columns 114) :caps "g" :label "刷新")
    (maillist-hint :if (>= columns 136) :caps "[/]" :label "消息")
    (maillist-hint :if (>= columns 136) :caps "Q" :label "引文")
    (maillist-hint :caps "?" :label "帮助")))

(etaf-define-component maillist-footer (&key columns)
  "Render the key hints of the client."
  :view
  (column :width 'stretch :item-gap '(lh 0)
    (etaf-divider)
    (flex :width 'stretch :height '(lh 1) :align-items 'center
          :padding (list (list 'lh 0) (list 'ch 2))
      (maillist-hints :columns columns))))

(etaf-define-component maillist-app
    (&key model viewport viewport-px viewport-rows list-width groups selected thread
          focused-message hide-quotes scope summary status toast search-input query
          reading keys help on-select on-message on-scope on-switch-list
          on-search-change on-search-submit on-search-clear on-back on-earlier
          on-resize on-toggle-quotes)
  "Render the whole application, reading its reactive sources."
  :setup
  ;; A provided plain plist keeps the colors of the theme that was active at
  ;; mount, so the shared components would stay dark in a light theme.  The
  ;; computed reads the switch generation ETAF bumps after a theme change.
  (etaf-theme-provide
   (etaf-computed (lambda ()
                    (etaf-theme-current-mode)
                    (maillist-theme-defaults))
                  :name 'maillist-theme-tokens))
  :render
  (let* ((width (etaf-value viewport))
         (rows (max 8 (etaf-value viewport-rows)))
         (pixels (etaf-value viewport-px))
         (narrow (< width maillist-narrow-width))
         (scope-value (etaf-value scope))
         (thread-value (etaf-value thread))
         (toast-value (etaf-value toast))
         (show-reader (or (not narrow) (etaf-value reading)))
         (max-list (max 260 (- pixels 400)))
         (clamped-list (max 240 (min (or (etaf-value list-width) 480) max-list)))
         (toast-text (or (and toast-value (plist-get toast-value :text)) ""))
         (toast-max (min 46 (max 20 (- width 4))))
         (toast-width (min toast-max (max 14 (+ 6 (string-width toast-text)))))
         (toast-left (max 2 (- width toast-width 2)))
         (toast-lines
          (if toast-value
              (max 1 (min 3 (ceiling (/ (float (max 1 (string-width toast-text)))
                                        (max 10 (- toast-width 5))))))
            1))
         (toast-top (max 3 (- rows 3 toast-lines))))
    (etaf-view
     ;; The canvas is exactly the window body the fit measured.  `vw 100' and
     ;; `vh 100' count the viewport the mount was opened with: they keep the
     ;; old size after a resize, one extra row scrolls the whole page, and the
     ;; hint row runs under the canvas edge.
     (flex :flex-direction 'column
           :width (list 'px (max 240 (or pixels 0)))
           :height (list 'lh rows)
           :box-sizing 'border-box :overflow 'hidden
           :min-height '(lh 0) :keys keys :help help
       (maillist-appbar :model model
                        :scope scope-value
                        :summary (etaf-value summary)
                        :search-input (etaf-value search-input)
                        :narrow narrow
                        :on-scope on-scope
                        :on-switch-list on-switch-list
                        :on-search-change on-search-change
                        :on-search-submit on-search-submit
                        :on-search-clear on-search-clear)
       (maillist-pane :groups (etaf-value groups)
                      :selected (etaf-value selected)
                      :scope scope-value
                      :thread thread-value
                      :focused-message (etaf-value focused-message)
                      :hide-quotes (etaf-value hide-quotes)
                      :narrow narrow
                      :searching (not (string-empty-p (etaf-value query)))
                      :show-list (or (not narrow) (not show-reader))
                      :show-reader show-reader
                      :list-width clamped-list
                      :compact-author (and (not narrow) (< clamped-list 360))
                      :width-ref list-width
                      :max-list-width max-list
                      :on-resize on-resize
                      :on-earlier on-earlier
                      :on-select on-select :on-message on-message :on-back on-back
                      :on-toggle-quotes on-toggle-quotes)
       (maillist-footer :columns width)
       (maillist-toast :toast toast-value
                       :left toast-left
                       :top toast-top
                       :width toast-width)))))

(provide 'maillist-views)
;;; maillist-views.el ends here
