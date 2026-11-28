;;; etaf-telega-views.el --- Views of etaf-telega -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Views are pure projections of the model into one window-tall shell: a
;; fixed app bar above one of two screens that follow Telega's own buffers,
;; and the media viewer over both.  The list screen pins its filter tabs above
;; a scrolling column of two-line conversation rows; the chat screen scrolls
;; its history, anchored at the newest message, above a fixed composer.
;; Messages share one left-aligned style, the account's own included: an
;; avatar and sender line open each sender group and reactions sit under the
;; text.  Only the scrolling bodies move, so headers, tabs and the composer
;; never shift.
;;
;; Every chat and message row carries an explicit Host ref, so the
;; application maps point to the row under it and moves point between rows.
;; Selection highlighting reads a keyed selector: moving the selection
;; re-renders the previous and the new row only.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-telega-theme)

(declare-function etaf-telega--adopt "etaf-telega-app" (model))
(declare-function etaf-telega--release "etaf-telega-app" (model))
(declare-function etaf-telega-send "etaf-telega-app" (text))
(declare-function etaf-telega--keep-draft "etaf-telega-app" (text))
(declare-function etaf-telega--can-post-p "etaf-telega-app" (chat))
(declare-function etaf-telega--no-post-text "etaf-telega-app" (chat))
(declare-function etaf-telega-attach-as "etaf-telega-app" (kind &optional path))
(declare-function etaf-telega-open-chat "etaf-telega-app" (id))
(declare-function etaf-telega-select-filter "etaf-telega-app" (key))
(declare-function etaf-telega-back "etaf-telega-app" ())
(declare-function etaf-telega-react "etaf-telega-app" (id key))
(declare-function etaf-telega-close-media "etaf-telega-app" ())
(declare-function etaf-telega--show-help "etaf-telega-app" ())
(declare-function etaf-telega--client-keys "etaf-telega-app" ())
(declare-function etaf-telega--list-keys "etaf-telega-app" ())
(declare-function etaf-telega--chat-keys "etaf-telega-app" ())
(declare-function etaf-telega--details-keys "etaf-telega-app" ())
(declare-function etaf-telega-swipe "etaf-telega-app" (direction))
(declare-function etaf-telega--history-scrolled "etaf-telega-app" (offset))
(declare-function etaf-telega--viewer-step "etaf-telega-app" (delta))
(declare-function etaf-telega-jump-newest "etaf-telega-app" ())
(declare-function etaf-telega-open-media "etaf-telega-app" (id))
(declare-function etaf-telega-show-message "etaf-telega-app" (id))
(declare-function etaf-telega-search-exit "etaf-telega-app" ())
(declare-function etaf-telega-search-clear-recent "etaf-telega-app" ())
(declare-function etaf-telega--search-focused "etaf-telega-app" ())
(declare-function etaf-telega--search-changed "etaf-telega-app" (query))
(declare-function etaf-telega--search-submit "etaf-telega-app" (query))
(declare-function etaf-telega--search-cancelled "etaf-telega-app" (query))
(defvar etaf-telega--composer-keymap)
(declare-function etaf-telega-model-send-options "etaf-telega-model" (model))
(declare-function etaf-telega-toggle-silent "etaf-telega-app" ())
(declare-function etaf-telega-toggle-link-preview "etaf-telega-app" ())
(declare-function etaf-telega-toggle-markdown "etaf-telega-app" ())
(declare-function etaf-telega-clear-schedule "etaf-telega-app" ())
(declare-function etaf-telega--search-kind-select "etaf-telega-app" (kind))
(declare-function etaf-telega-chat-search "etaf-telega-app" ())
(declare-function etaf-telega-chat-search-exit "etaf-telega-app" ())
(declare-function etaf-telega--chat-search-cancelled "etaf-telega-app" (query))
(declare-function etaf-telega--chat-search-changed "etaf-telega-app" (query))
(declare-function etaf-telega--compose-changed "etaf-telega-app" (text))
(declare-function etaf-telega--popover-choose "etaf-telega-app" (item))
(declare-function etaf-telega-toggle-details "etaf-telega-app" ())
(declare-function etaf-telega--list-menu-select "etaf-telega-app" (key))
(declare-function etaf-telega--chat-menu-select "etaf-telega-app" (key))

(defvar etaf-telega--refs (obarray-make)
  "Private obarray holding the Host ref symbols of chat and message rows.")

(defun etaf-telega--ref (kind id)
  "Return the Host ref symbol of the KIND row (`chat' or `message') with ID."
  (let ((symbol (intern (format "%s:%s" kind id) etaf-telega--refs)))
    (unless (get symbol 'etaf-telega-kind)
      (put symbol 'etaf-telega-kind kind)
      (put symbol 'etaf-telega-id id))
    symbol))

(defun etaf-telega--ref-id (kind ref)
  "Return the row id carried by REF when it is a KIND row ref, else nil."
  (and (symbolp ref) (eq (get ref 'etaf-telega-kind) kind)
       (get ref 'etaf-telega-id)))

(defconst etaf-telega--pictograph-regexp
  "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U00002B00-\U00002BFF\uFE0F\u200D]"
  "Pictographic ranges whose fallback fonts grow the canvas line height.
Rows and pane headers keep a fixed row budget, so their text drops these
characters instead of letting a colour emoji font stretch the line.")

(defun etaf-telega--plain-text (text)
  "Return TEXT without pictographs or Telega's faces.
Pictographs would grow the canvas line height, and faces Telega attaches
to titles and entities would override the application's palette."
  (if (stringp text)
      (replace-regexp-in-string etaf-telega--pictograph-regexp ""
                                (substring-no-properties text))
    text))

(defun etaf-telega--one-line (text &optional limit)
  "Return TEXT's first line, truncated to LIMIT display cells.
Pictographs are removed so the row keeps the canvas line height."
  (let ((line (etaf-telega--plain-text
               (car (split-string (or text "") "\n" nil)))))
    (if (and limit (> (string-width line) limit))
        (concat (truncate-string-to-width line (max 1 (- limit 1))) "…")
      line)))

(defun etaf-telega--initial (title)
  "Return TITLE's avatar initial, skipping leading punctuation."
  (let* ((title (or title ""))
         (char (cl-find-if (lambda (character)
                             (string-match-p "\\w" (char-to-string character)))
                           (string-to-list title))))
    (if char (upcase (char-to-string char)) "?")))

(defun etaf-telega--count-label (count)
  "Return COUNT as a compact badge label for narrow columns."
  (cond ((>= count 10000) (format "%.0fK" (/ count 1000.0)))
        ((>= count 1000) (format "%.1fK" (/ count 1000.0)))
        (t (number-to-string count))))

(defun etaf-telega--message-body-text (message)
  "Return MESSAGE's body text."
  (or (plist-get message :text) ""))

(defun etaf-telega--media-label (kind)
  "Return KIND's short placeholder label."
  (pcase kind
    ('photo "[图片]")
    ('video "▶ 视频")
    ('animation "▶ 动图")
    ('voice "[语音]")
    ('audio "[音频]")
    ('sticker "[贴纸]")
    ('file "[文件]")
    (_ "")))

(defun etaf-telega--format-size (size)
  "Return SIZE bytes as a short readable string."
  (cond ((or (null size) (zerop size)) "")
        ((< size 1024) (format "%dB" size))
        ((< size (* 1024 1024)) (format "%.0fK" (/ size 1024.0)))
        (t (format "%.1fM" (/ size (* 1024.0 1024.0))))))

(defun etaf-telega--message-extras (message)
  "Return MESSAGE's extra display lines (media, file, link)."
  (let ((kind (plist-get message :kind))
        (file (plist-get message :file))
        (link (plist-get message :link))
        lines)
    (when (and kind (not (eq kind 'text))
               (not (and (plist-get message :media)
                         (memq kind '(photo sticker video animation)))))
      (push (if (and (eq kind 'file) file)
                (format "%s %s %s"
                        (etaf-telega--media-label kind)
                        (or (plist-get file :name) "")
                        (etaf-telega--format-size (plist-get file :size)))
              (etaf-telega--media-label kind))
            lines))
    (when link
      (push (format "链接 %s：%s"
                    (or (plist-get link :site) "")
                    (or (plist-get link :title) ""))
            lines))
    (mapcar #'etaf-telega--plain-text (nreverse lines))))

(defun etaf-telega--reply-text (reply)
  "Return REPLY's one-line quote text, naming its media when it has no text."
  (let ((text (etaf-telega--one-line (plist-get reply :text) 60)))
    (if (string-empty-p (string-trim text))
        (let ((label (etaf-telega--media-label (plist-get reply :kind))))
          (if (string-empty-p label) "消息" label))
      text)))

(defun etaf-telega--compose-label (compose)
  "Return COMPOSE's prompt line, or nil while plainly composing."
  (let ((target (plist-get compose :target)))
    (pcase (plist-get compose :kind)
      ('reply (format "回复 %s：%s"
                      (etaf-telega--plain-text (or (plist-get target :sender) "?"))
                      (etaf-telega--one-line (plist-get target :text) 40)))
      ('edit (format "编辑：%s"
                     (etaf-telega--one-line (plist-get target :text) 40)))
      (_ nil))))

(defun etaf-telega--send-chip (label action)
  "Return a clickable LABEL chip running ACTION."
  (etaf-node 'box (list :flex-shrink 0 :padding-inline '(ch 1)
                        :color (etaf-telega-color :accent)
                        :background-color (etaf-telega-color :surface-2)
                        :pointer 'hand :help-echo label
                        :role 'button :aria-label label :on-press action)
             (list (etaf-node 'text nil (list label)))))

(defun etaf-telega--send-options-strip (model)
  "Return the pending send options as clickable chips, or nil.
Each chip clears or toggles its option."
  (let* ((options (etaf-telega-model-send-options model))
         (chips (delq nil
                      (list (when (plist-get options :silent)
                              (etaf-telega--send-chip "静默"
                                                      #'etaf-telega-toggle-silent))
                            (when (plist-get options :no-preview)
                              (etaf-telega--send-chip "不预览链接"
                                                      #'etaf-telega-toggle-link-preview))
                            (when (plist-get options :at)
                              (etaf-telega--send-chip
                               (format "定时 %s"
                                       (format-time-string "%m-%d %H:%M"
                                                           (plist-get options :at)))
                               #'etaf-telega-clear-schedule))
                            (when (plist-get options :markdown)
                              (etaf-telega--send-chip "Markdown"
                                                      #'etaf-telega-toggle-markdown))))))
    (when chips
      (etaf-node 'flex (list :flex-direction 'row :align-items 'center
                             :column-gap '(ch 1) :width 'stretch
                             :padding-bottom '(lh 1))
                 chips))))

(defun etaf-telega--upload-strip (model)
  "Return the pending upload's progress line, or nil."
  (let ((upload (etaf-value (plist-get model :upload))))
    (when upload
      (etaf-node 'flex (list :flex-direction 'row :align-items 'center
                             :column-gap '(ch 1) :width 'stretch
                             :padding-bottom '(lh 1))
                 (list (etaf-node 'text (list :color (etaf-telega-color :accent))
                                  (list (format "正在上传 %s：%d%%"
                                                (or (plist-get upload :name) "文件")
                                                (round (* 100
                                                          (or (plist-get upload :progress)
                                                              0))))))
                       (etaf-node 'text (list :color (etaf-telega-color :muted))
                                  (list "C-c C-u 取消")))))))

(defun etaf-telega--popover-panel (model)
  "Return the composer's open completion popover, or nil."
  (let ((popover (etaf-value (plist-get model :popover))))
    (when popover
      (let ((index (or (plist-get popover :index) 0)))
        (etaf-node
         'flex (list :flex-direction 'column :width 'stretch
                     :background-color (etaf-telega-color :surface-2)
                     :border (list '(px 1) 'solid (etaf-telega-color :border))
                     :padding '((lh 0) (ch 1)) :margin-bottom '(lh 1)
                     :max-height '(lh 9) :overflow 'hidden)
         (append
          (list (etaf-node 'text (list :color (etaf-telega-color :muted)
                                       :font-weight 'bold)
                           (list (format "%s · C-n/C-p 选择 · RET/C-c C-j 插入"
                                         (or (plist-get popover :title) "")))))
          (cl-loop for item in (plist-get popover :items)
                   for i from 0
                   collect
                   (let ((entry item))
                     (etaf-node
                      'flex (list :flex-direction 'row :align-items 'center
                                  :column-gap '(ch 1) :width 'stretch
                                  :background-color (when (= i index)
                                                      (etaf-telega-color :selected))
                                  :role 'button :tab-index 0
                                  :aria-label (plist-get entry :label)
                                  :hover-style
                                  (list :background-color (etaf-telega-color :selected))
                                  :on-press (lambda ()
                                              (etaf-telega--popover-choose entry)))
                      (list (etaf-node 'text nil (list (plist-get entry :label)))))))))))))

(defun etaf-telega--group-digits (count)
  "Return natural number COUNT with thousands separated by commas."
  (let ((digits (number-to-string count)))
    (while (string-match "\\([0-9]\\)\\([0-9]\\{3\\}\\)\\(?:,\\|$\\)" digits)
      (setq digits (replace-match "\\1,\\2" t nil digits)))
    digits))

(defun etaf-telega--chat-meta (chat)
  "Return CHAT's one-line meta text: members, subscribers or presence."
  (let ((members (plist-get chat :members))
        (username (or (plist-get chat :username) "")))
    (pcase (plist-get chat :kind)
      ('channel (if members
                    (format "%s 位订阅者" (etaf-telega--group-digits members))
                  "频道"))
      ('group (if members
                  (format "%s 位成员" (etaf-telega--group-digits members))
                "群组"))
      ('private (cond ((plist-get chat :online) "在线")
                      ((not (string-empty-p username)) (format "@%s" username))
                      (t "私聊")))
      (_ ""))))

;;;; Root list

(defconst etaf-telega-filters
  '((main . "全部") (important . "重要") (online . "在线")
    (groups . "群组") (channels . "频道") (archived . "归档"))
  "Chat filters shown in the root tab strip.")

(defun etaf-telega--filter-chats (chats key)
  "Return CHATS matching filter KEY."
  (pcase key
    ('main (cl-remove-if (lambda (chat) (plist-get chat :archived)) chats))
    ('important (cl-remove-if-not (lambda (chat)
                                    (> (or (plist-get chat :mention) 0) 0))
                                  chats))
    ('online (cl-remove-if-not (lambda (chat) (plist-get chat :online)) chats))
    ('groups (cl-remove-if-not (lambda (chat)
                                 (eq (plist-get chat :kind) 'group)) chats))
    ('channels (cl-remove-if-not (lambda (chat)
                                   (eq (plist-get chat :kind) 'channel)) chats))
    ('archived (cl-remove-if-not (lambda (chat)
                                   (plist-get chat :archived)) chats))
    (_ chats)))

(defun etaf-telega--filter-items (chats)
  "Return the filter tab items over CHATS, with unread chat counts."
  (mapcar (lambda (entry)
            (let* ((matching (etaf-telega--filter-chats chats (car entry)))
                   (unread (cl-count-if (lambda (chat)
                                          (> (or (plist-get chat :unread) 0) 0))
                                        matching)))
              (append (list :key (car entry) :label (cdr entry))
                      (when (> unread 0) (list :count unread)))))
          etaf-telega-filters))

;;;; Layout

(defcustom etaf-telega-split-columns 120
  "Narrowest window, in columns, that shows the list beside the open chat.
Narrower windows show one screen at a time in Telega's compact line style;
wider ones use Telegram's two-pane layout with message bubbles."
  :type 'natnum
  :group 'etaf-telega)

(defconst etaf-telega--list-pane-columns 52
  "Default width, in columns, of the conversation list beside the chat.")

(defconst etaf-telega--list-pane-min-columns 30
  "Narrowest width, in columns, the list pane can be dragged to.")

(defconst etaf-telega--chat-pane-min-columns 64
  "Narrowest chat, in columns, kept beside the list and the details pane.
When the details pane would squeeze the chat below it, the list hides.")

(defconst etaf-telega--details-pane-columns 44
  "Width, in columns, of the chat details pane.")

(defun etaf-telega--cell ()
  "Return (CHAR-WIDTH . LINE-HEIGHT) pixels of the canvas being drawn.
`ch' and `lh' resolve against the canvas's own face, so a text scale keeps the
grid, the panes and the thumbnails inside the region they measured."
  (let ((metrics (ignore-errors (etaf-display-metrics))))
    (cons (max 1 (or (plist-get metrics :char-width) (frame-char-width)))
          (max 1 (or (plist-get metrics :line-height) (frame-char-height))))))

(defun etaf-telega--columns ()
  "Return the canvas width in columns; the read is reactive.
The width is the host region's, so the client adapts when a desktop or
pane embeds it instead of the whole buffer (see `etaf-viewport')."
  (/ (or (car (etaf-viewport)) 0) (car (etaf-telega--cell))))

(defun etaf-telega--layout ()
  "Return the layout the canvas width selects: `compact' or `split'.
The read is reactive, so a resize across the threshold switches layouts."
  (if (< (etaf-telega--columns) etaf-telega-split-columns) 'compact 'split))

(defun etaf-telega--list-pixels (model)
  "Return the list pane width in pixels: MODEL's dragged width or the default.
The width stays between the minimum and half the canvas."
  (let* ((cw (car (etaf-telega--cell)))
         (canvas (or (car (etaf-viewport)) 0))
         (width (or (etaf-value (plist-get model :list-width))
                    (* etaf-telega--list-pane-columns cw))))
    (round (max (* etaf-telega--list-pane-min-columns cw)
                (min width (/ canvas 2))))))

(defun etaf-telega--pane-style (ref &optional width keys)
  "Return the style of a full-height pane with REF answering KEYS.
A pane with WIDTH keeps it; one without grows into the remaining width."
  (append (list :ref ref :flex-direction 'column :min-width '(ch 0)
                :min-height '(lh 0) :keys keys
                :aria-label (pcase ref
                              ('telega-list-pane "会话列表")
                              ('telega-chat-pane "消息区")
                              ('telega-details-pane "对话信息")))
          (if width
              (list :width width :flex-shrink 0)
            (list :flex-grow 1 :flex-basis '(ch 0)))))

;;;; Bars

(defun etaf-telega--spacer ()
  "Return a flexible gap that pushes the following items to the end."
  (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
             (list "")))

(defun etaf-telega--bar-button (icon help action)
  "Return a flat app bar icon button showing ICON that runs ACTION.
HELP is its tooltip; the icon is muted and its cell tints on hover."
  (let ((color (etaf-telega-color :muted)))
    (etaf-node 'box (list :flex-shrink 0 :padding-inline '(ch 1) :color color
                          :hover-style (list :background-color
                                             (etaf-telega-color :surface-2))
                          :pointer 'hand :help-echo help
                          :role 'button :aria-label help :on-press action)
               (list (etaf-ui-icon icon :color color :min-width 1)))))

(defun etaf-telega--bar-menu (icon label items on-select placement)
  "Return an app bar ICON opening the menu of ITEMS, named LABEL.
ON-SELECT receives the chosen item's key; PLACEMENT follows `etaf-popover'."
  (etaf-node 'box (list :flex-shrink 0 :padding-inline '(ch 1)
                        :color (etaf-telega-color :muted))
             (list (etaf-node 'etaf-dropdown-menu
                              (list :icon icon :label label :items items
                                    :on-select on-select :width '(ch 28)
                                    :placement placement)
                              nil))))

(defun etaf-telega--bar (children &optional field)
  "Return a three-line header band centering the non-nil CHILDREN.
Every pane's header has this height, so headers side by side line up.
FIELD non-nil drops the band's own block padding because a search field
among CHILDREN is already three lines tall."
  (etaf-node 'flex (list :flex-shrink 0 :flex-direction 'row :align-items 'center
                         :width 'stretch
                         :padding (list (if field '(lh 0) '(lh 1)) '(ch 1))
                         :column-gap '(ch 1)
                         :background-color (etaf-telega-color :surface)
                         :border-bottom (list '(px 1) 'solid (etaf-telega-color :border)))
             (delq nil children)))

(defun etaf-telega--bar-title (title subtitle &optional color)
  "Return bold TITLE in COLOR followed by muted SUBTITLE on one line.
The title keeps its width first; the subtitle is clipped before it."
  (etaf-node 'flex (list :flex-direction 'row :column-gap '(ch 2)
                         :flex-shrink 1 :min-width '(ch 0))
             (delq nil
                   (list (etaf-node 'box (list :overflow 'hidden :wrap-mode 'none
                                               :flex-shrink 1 :min-width '(ch 0))
                                    (list (etaf-node 'text
                                                     (list :font-weight 'bold
                                                           :color (or color (etaf-telega-color :ink)))
                                                     (list title))))
                         (and subtitle (not (string-empty-p subtitle))
                              (etaf-node 'box (list :overflow 'hidden :wrap-mode 'none
                                                    :flex-shrink 100 :min-width '(ch 0))
                                         (list (etaf-node 'text (list :color (etaf-telega-color :muted))
                                                          (list subtitle)))))))))

(defun etaf-telega--list-menu-items (me)
  "Return the list menu items, headed by account name ME."
  (list (list :key 'account :label (if (string-empty-p me) "未登录" me)
              :icon 'account :disabled t)
        (list :key 'create :label "新建对话" :icon 'plus)
        (list :key 'join :label "通过链接加入" :icon 'users)
        (list :key 'help :label "键盘快捷键" :icon 'info)
        (list :key 'theme :label "切换主题" :icon 'settings)
        (list :key 'close :label "关闭" :icon 'close)))

(etaf-define-component etaf-telega-list-bar (&key model)
  "Render the list header: the menu, or search's back button, and the search.
Until the account is ready the empty search field shows the connection
state instead of its prompt."
  :render
  (let* ((status (or (etaf-value (plist-get model :status)) ""))
         (ready (equal status "就绪"))
         (me (etaf-telega--plain-text
              (or (plist-get (etaf-value (plist-get model :me)) :name) ""))))
    (etaf-telega--bar
     (list (if (etaf-value (plist-get model :searching))
               (etaf-telega--bar-button 'chevron-left "退出搜索 (ESC)"
                                        #'etaf-telega-search-exit)
             (etaf-telega--bar-menu 'menu "菜单" (etaf-telega--list-menu-items me)
                                    #'etaf-telega--list-menu-select 'bottom-start))
           (etaf-view
            (etaf-search-field :ref 'telega-search :value (plist-get model :search)
                               :placeholder (if ready "搜索" status) :icon t
                               :on-change #'etaf-telega--search-changed
                               :on-focus #'etaf-telega--search-focused
                               :on-submit #'etaf-telega--search-submit
                               :on-cancel #'etaf-telega--search-cancelled)))
     t)))

(defconst etaf-telega--chat-menu-items
  '((:key details :label "对话信息" :icon info)
    (:key search :label "搜索消息" :icon search)
    (:key newest :label "跳到最新消息" :icon chevron-down)
    (:key reload :label "重新载入" :icon refresh)
    (:key help :label "键盘快捷键" :icon info)
    (:key back :label "关闭对话" :icon close))
  "Items of the chat header's more menu.")

(etaf-define-component etaf-telega-chat-bar (&key model back)
  "Render the open chat's header; BACK adds the return-to-list button.
The title and member count lead; message search, the details pane switch
and the more menu end the band.  While searching, a search field takes the
title's place and the history shows only matching messages."
  :render
  (let* ((chat (etaf-value (plist-get model :chat)))
         (title (or (plist-get chat :title) "?"))
         (query (etaf-value (plist-get model :chat-search)))
         (back (and back (etaf-telega--bar-button 'chevron-left "返回会话列表 (q)"
                                                  #'etaf-telega-back))))
    (if query
        (etaf-telega--bar
         (list (etaf-telega--bar-button 'chevron-left "关闭搜索 (ESC)"
                                        #'etaf-telega-chat-search-exit)
               (etaf-view
                (etaf-search-field :ref 'telega-chat-search
                                   :value (plist-get model :chat-search)
                                   :placeholder "搜索消息" :icon t
                                   :on-change #'etaf-telega--chat-search-changed
                                   :on-cancel #'etaf-telega--chat-search-cancelled)))
         t)
      (etaf-telega--bar
       (list back
             (etaf-node 'box (list :flex-shrink 1 :flex-grow 1 :flex-basis '(ch 0)
                                   :min-width '(ch 0) :padding-inline '(ch 1))
                        (list (etaf-telega--bar-title (etaf-telega--plain-text title)
                                                      (etaf-telega--chat-meta chat))))
             (etaf-telega--bar-button 'search "搜索消息 (/)" #'etaf-telega-chat-search)
             (etaf-telega--bar-button 'sidebar "对话信息 (C-c i)"
                                      #'etaf-telega-toggle-details)
             (etaf-telega--bar-help)
             (etaf-telega--bar-menu 'more-vertical "更多" etaf-telega--chat-menu-items
                                    #'etaf-telega--chat-menu-select 'bottom-end))))))

;;;; Conversation list

(defun etaf-telega--clip (text color &rest props)
  "Return one line of TEXT in COLOR clipped to the width it is given.
In a row it takes the free width.  PROPS add text style such as
`:font-weight'."
  (etaf-node 'box (list :flex-grow 1 :flex-basis 'auto :flex-shrink 1
                        :width 'stretch :min-width '(ch 0)
                        :overflow 'hidden :wrap-mode 'none)
             (list (etaf-node 'text (append (list :color color) props) (list text)))))

(defun etaf-telega--unread-badge (unread muted)
  "Return the pill counting UNREAD messages, gray when MUTED."
  (etaf-node 'box (list :padding-inline '(ch 1) :font-weight 'bold
                        :color (if muted (etaf-telega-color :ink) "#FFFFFF")
                        :background-color (if muted (etaf-telega-color :border)
                                            (etaf-telega-color :accent)))
             (list (etaf-telega--count-label unread))))

(etaf-define-component etaf-telega-chat-row (&key chat selected)
  "Render CHAT as a four-line row; SELECTED is the cursor selector.
A centered round avatar sits beside the title and time over two preview lines:
a group's last sender over its text, or the text wrapped across both.  The
unread count, or the pin, ends the last line.  A hairline under the text
column separates rows without crossing the avatars."
  :render
  (let* ((id (plist-get chat :id))
         (title (or (plist-get chat :title) "?"))
         (unread (or (plist-get chat :unread) 0))
         (mention (or (plist-get chat :mention) 0))
         (muted (plist-get chat :muted))
         (author (plist-get chat :author))
         (preview (etaf-telega--plain-text (or (plist-get chat :preview) "")))
         (current (funcall selected id))
         (muted-color (if current (etaf-telega-color :ink) (etaf-telega-color :muted))))
    (etaf-node
     'flex (list :ref (etaf-telega--ref 'chat id)
                 :flex-direction 'row :align-items 'flex-start :width 'stretch
                 :padding-inline '(ch 1) :column-gap '(ch 1)
                 :background-color (if current (etaf-telega-color :selected)
                                     (etaf-telega-color :bg))
                 :hover-style (unless current
                                (list :background-color (etaf-telega-color :surface-2)))
                 :role 'button :tab-index 0 :aria-selected (and current t)
                 :on-press (lambda () (etaf-telega-open-chat id)))
     (list
      (etaf-node 'etaf-avatar
                 (list :name title :initials (etaf-telega--initial title)
                       :src (plist-get chat :photo) :size '(ch 6) :lines 4
                       :background (etaf-telega-sender-color title))
                 nil)
      (etaf-node
       'flex (list :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0)
                   :min-width '(ch 0) :padding-top '(lh 1)
                   :border-bottom (list '(px 1) 'solid
                                        (if current (etaf-telega-color :selected)
                                          (etaf-telega-color :hairline))))
       (list
        (etaf-node 'flex (list :flex-direction 'row :align-items 'center
                               :width 'stretch :column-gap '(ch 1))
                   (delq nil
                         (list (etaf-telega--clip (etaf-telega--plain-text title)
                                                  (etaf-telega-color :ink)
                                                  :font-weight 'bold)
                               (and muted (etaf-ui-icon 'bell-off :min-width 1
                                                        :color muted-color))
                               (etaf-node 'text (list :color muted-color)
                                          (list (or (plist-get chat :time) ""))))))
        (etaf-node
         'flex (list :flex-direction 'row :align-items 'flex-end :width 'stretch
                     :column-gap '(ch 1))
         (delq nil
               (list
                (if (and author (not (string-empty-p author)))
                    (etaf-node 'flex (list :flex-direction 'column :flex-grow 1
                                           :flex-basis '(ch 0) :min-width '(ch 0))
                               (list (etaf-telega--clip (etaf-telega--plain-text author)
                                                        (etaf-telega-color :ink))
                                     (etaf-telega--clip (etaf-telega--one-line preview)
                                                        muted-color)))
                  (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                                        :height '(lh 2) :overflow 'hidden)
                             (list (etaf-node 'text (list :color muted-color)
                                              (list (replace-regexp-in-string
                                                     "[\n\t ]+" " " preview))))))
                (and (> mention 0)
                     (etaf-ui-icon 'at :min-width 1 :color (etaf-telega-color :accent)))
                (cond ((> unread 0) (etaf-telega--unread-badge unread muted))
                      ((plist-get chat :pinned)
                       (etaf-ui-icon 'pin :min-width 1 :color muted-color))))))))))))

(defun etaf-telega--scroll-body (ref &rest props)
  "Return the style of a scrolling screen body with REF and extra PROPS.
The body takes the height its fixed siblings leave in the shell."
  (append (list :ref ref :overflow 'scroll :width 'stretch :flex-grow 1
                :flex-basis '(lh 0) :min-height '(lh 0))
          props))

(defconst etaf-telega--search-kinds
  '((all . "全部") (private . "私聊") (group . "群组") (channel . "频道"))
  "Kinds of conversation the search tabs narrow results to.")

(defun etaf-telega--search-chats (chats query kind)
  "Return CHATS of KIND, or `all', whose title or username contains QUERY."
  (let ((needle (downcase (string-trim (or query "")))))
    (cl-remove-if-not
     (lambda (chat)
       (and (or (eq kind 'all) (eq (plist-get chat :kind) kind))
            (or (string-empty-p needle)
                (string-search needle (downcase (etaf-telega--plain-text
                                                 (or (plist-get chat :title) ""))))
                (string-search needle (downcase (or (plist-get chat :username) ""))))))
     chats)))

(defun etaf-telega--list-chats (model)
  "Return the conversations MODEL's list pane shows, in order.
While searching these are the matches of the query, or the recently
opened results before anything is typed; otherwise the active filter's."
  (let ((chats (etaf-value (plist-get model :chats))))
    (if (etaf-value (plist-get model :searching))
        (let ((query (or (etaf-value (plist-get model :search)) ""))
              (kind (etaf-value (plist-get model :search-kind))))
          (if (string-empty-p (string-trim query))
              (etaf-telega--search-chats
               (delq nil (mapcar (lambda (id)
                                   (cl-find id chats :key (lambda (chat) (plist-get chat :id))
                                            :test #'equal))
                                 (etaf-value (plist-get model :recent))))
               query kind)
            ;; Local matches stay instant; the backend's server-side results
            ;; add conversations the list has not loaded.
            (let* ((local (etaf-telega--search-chats chats query kind))
                   (found (etaf-telega--search-chats
                           (etaf-value (plist-get model :search-results))
                           query kind)))
              (append local
                      (cl-remove-if
                       (lambda (chat)
                         (cl-find (plist-get chat :id) local
                                  :key (lambda (item) (plist-get item :id))
                                  :test #'equal))
                       found)))))
      (etaf-telega--filter-chats chats (etaf-value (plist-get model :filter))))))

(defun etaf-telega--frequent-chats (chats count)
  "Return COUNT conversations of CHATS to offer as frequent contacts.
People come before groups and channels, each in the list's order."
  (let ((chats (cl-remove-if (lambda (chat) (plist-get chat :archived)) chats)))
    (seq-take (append (cl-remove-if-not (lambda (chat) (eq (plist-get chat :kind) 'private))
                                        chats)
                      (cl-remove-if (lambda (chat) (eq (plist-get chat :kind) 'private))
                                    chats))
              count)))

(defun etaf-telega--section-title (title &optional action label)
  "Return a muted section TITLE line; LABEL is a link running ACTION."
  (etaf-node 'flex (list :flex-direction 'row :width 'stretch
                         :padding-inline '(ch 2) :padding-top '(lh 1))
             (delq nil
                   (list (etaf-node 'text (list :font-weight 'bold
                                                :color (etaf-telega-color :muted))
                                    (list title))
                         (etaf-telega--spacer)
                         (and action
                              (etaf-node 'box (list :color (etaf-telega-color :accent)
                                                    :pointer 'hand :role 'button
                                                    :help-echo label :on-press action)
                                         (list label)))))))

(defun etaf-telega--frequent-contact (chat)
  "Return CHAT as a frequent contact: its avatar over its clipped name."
  (let* ((id (plist-get chat :id))
         (title (or (plist-get chat :title) "?")))
    (etaf-node 'flex (list :flex-direction 'column :align-items 'center
                           :width '(ch 8) :flex-shrink 0
                           :pointer 'hand :role 'button :help-echo title
                           :hover-style (list :background-color
                                              (etaf-telega-color :surface-2))
                           :on-press (lambda () (etaf-telega-open-chat id)))
               (list (etaf-node 'etaf-avatar
                                (list :name title :initials (etaf-telega--initial title)
                                      :src (plist-get chat :photo) :size '(ch 6) :lines 4
                                      :background (etaf-telega-sender-color title))
                                nil)
                     (etaf-node 'box (list :width 'stretch :overflow 'hidden
                                           :wrap-mode 'none :text-align 'center)
                                (list (etaf-node 'text (list :color (etaf-telega-color :ink))
                                                 (list (etaf-telega--plain-text title)))))))))

(etaf-define-component etaf-telega-search-row (&key chat selected)
  "Render CHAT as a two-line search result; SELECTED is the cursor selector.
A two-line avatar sits beside the title over its member count or presence."
  :render
  (let* ((id (plist-get chat :id))
         (title (or (plist-get chat :title) "?"))
         (current (funcall selected id)))
    (etaf-node
     'flex (list :ref (etaf-telega--ref 'chat id)
                 :flex-direction 'row :align-items 'center :width 'stretch
                 :padding-inline '(ch 2) :column-gap '(ch 2)
                 :background-color (if current (etaf-telega-color :selected)
                                     (etaf-telega-color :bg))
                 :hover-style (unless current
                                (list :background-color (etaf-telega-color :surface-2)))
                 :role 'button :tab-index 0 :aria-selected (and current t)
                 :on-press (lambda () (etaf-telega-open-chat id)))
     (list (etaf-node 'etaf-avatar
                      (list :name title :initials (etaf-telega--initial title)
                            :src (plist-get chat :photo) :size '(ch 4) :lines 2
                            :background (etaf-telega-sender-color title))
                      nil)
           (etaf-node 'flex (list :flex-direction 'column :flex-grow 1
                                  :flex-basis '(ch 0) :min-width '(ch 0))
                      (list (etaf-telega--clip (etaf-telega--plain-text title)
                                               (etaf-telega-color :ink)
                                               :font-weight 'bold)
                            (etaf-telega--clip (etaf-telega--chat-meta chat)
                                               (if current (etaf-telega-color :ink)
                                                 (etaf-telega-color :muted)))))))))

(defun etaf-telega--muted-line (text)
  "Return a padded muted line of TEXT for an empty list."
  (etaf-node 'box (list :padding '((lh 1) (ch 2)) :color (etaf-telega-color :muted))
             (list text)))

(etaf-define-component etaf-telega-search-results (&key model selected columns)
  "Render the list search below the header in a pane COLUMNS wide.
Kind tabs narrow the results.  Before anything is typed the frequent
contacts and the recently opened results show; afterwards the matching
conversations.  SELECTED is the cursor selector."
  :render
  (let* ((query (string-trim (or (etaf-value (plist-get model :search)) "")))
         (chats (etaf-value (plist-get model :chats)))
         (results (etaf-telega--list-chats model))
         (rows (when results
                 (list (etaf-node
                        'flex (list :flex-direction 'column :width 'stretch
                                    :focus-group 'vertical)
                        (mapcar (lambda (chat)
                                  (etaf-view (etaf-telega-search-row
                                              :key (plist-get chat :id)
                                              :chat chat :selected selected)))
                                results))))))
    (etaf-node
     'flex (list :flex-direction 'column :width 'stretch :flex-grow 1
                 :flex-basis '(lh 0) :min-height '(lh 0))
     (list
      (etaf-node
       'flex (list :flex-shrink 0 :flex-direction 'row :width 'stretch
                   :padding-inline '(ch 1)
                   :border-bottom (list '(px 1) 'solid (etaf-telega-color :border)))
       (list (etaf-view
              (etaf-tabs :items (mapcar (lambda (entry)
                                          (list :key (car entry) :label (cdr entry)))
                                        etaf-telega--search-kinds)
                         :active (etaf-value (plist-get model :search-kind))
                         :on-change #'etaf-telega--search-kind-select))))
      (etaf-node
       'box (etaf-telega--scroll-body 'telega-list)
       (list
        (etaf-node
         'flex (list :flex-direction 'column :width 'stretch)
         (if (string-empty-p query)
             (let ((frequent (etaf-telega--frequent-chats
                              chats (max 1 (/ (- columns 2) 10)))))
               (append
                (when frequent
                  (list (etaf-telega--section-title "常用联系人")
                        (etaf-node 'flex (list :flex-direction 'row :width 'stretch
                                               :padding '((lh 1) (ch 1))
                                               :column-gap '(ch 2)
                                               :focus-group 'horizontal)
                                   (mapcar #'etaf-telega--frequent-contact frequent))))
                (list (etaf-telega--section-title
                       "最近" (and results #'etaf-telega-search-clear-recent) "清除"))
                (or rows (list (etaf-telega--muted-line "打开的搜索结果会列在这里")))))
           (or rows (list (etaf-telega--muted-line
                           (format "没有找到“%s”" query))))))))))))

(etaf-define-component etaf-telega-chat-list (&key model width columns)
  "Render MODEL's list pane: header, filter tabs and scrolling conversations.
WIDTH fixes the pane beside the chat; without it the pane fills the window.
COLUMNS is the pane's width in columns.  While searching the search results
replace the tabs and the list."
  :bindings ((selected (etaf-selector (plist-get model :cursor))))
  :render
  (etaf-node
   'flex (etaf-telega--pane-style 'telega-list-pane width (etaf-telega--list-keys))
   (list
    (etaf-view (etaf-telega-list-bar :model model))
    (if (etaf-value (plist-get model :searching))
        (etaf-view (etaf-telega-search-results :model model :selected selected
                                               :columns columns))
      (etaf-node
       'flex (list :flex-direction 'column :width 'stretch :flex-grow 1
                   :flex-basis '(lh 0) :min-height '(lh 0))
       (list
        (etaf-node
         'flex (list :flex-shrink 0 :flex-direction 'row :width 'stretch
                     :padding-inline '(ch 1)
                     :border-bottom (list '(px 1) 'solid (etaf-telega-color :border)))
         (list (etaf-view
                (etaf-tabs :items (etaf-telega--filter-items
                                   (etaf-value (plist-get model :chats)))
                           :active (etaf-value (plist-get model :filter))
                           :on-change #'etaf-telega-select-filter))))
        (etaf-node
         'box (etaf-telega--scroll-body 'telega-list)
         (list
          (etaf-view
           (flex :flex-direction 'column :width 'stretch :focus-group 'vertical
             (expr
              (let ((chats (etaf-telega--list-chats model)))
                (if chats
                    (mapcar (lambda (chat)
                              (etaf-view (etaf-telega-chat-row :key (plist-get chat :id)
                                                               :chat chat
                                                               :selected selected)))
                            chats)
                  (list (etaf-telega--muted-line
                         (if (etaf-value (plist-get model :chats))
                             "这个分组没有对话"
                           "正在载入对话…"))))))))))))))))

;;;; Chat

(defun etaf-telega--day-label (date)
  "Return DATE (YYYY-MM-DD) as a day separator label."
  (cond ((null date) nil)
        ((equal date (format-time-string "%Y-%m-%d")) "今天")
        ((equal date (format-time-string "%Y-%m-%d"
                                         (time-subtract nil (* 24 3600))))
         "昨天")
        (t date)))

(defun etaf-telega--media-grid (media kind)
  "Return (COLUMNS . ROWS) showing MEDIA of KIND at its aspect ratio.
Photos and videos fit 432x432 pixels and stickers 160x160, measured in the
canvas's character cells so the grid keeps the source's shape."
  (let* ((cell (etaf-telega--cell))
         (cw (car cell))
         (lh (cdr cell))
         (width (max 1 (or (plist-get media :width) 4)))
         (height (max 1 (or (plist-get media :height) 3)))
         (limit (if (eq kind 'sticker) '(160 . 160) '(432 . 432)))
         (scale (min (/ (float (car limit)) width)
                     (/ (float (cdr limit)) height))))
    (cons (max 2 (round (/ (* width scale) cw)))
          (max 1 (round (/ (* height scale) lh))))))

(defun etaf-telega--media-columns (message)
  "Return the width in columns of MESSAGE's thumbnail, or nil without one."
  (when-let* ((media (plist-get message :media))
              ((plist-get media :src))
              ((display-images-p)))
    (car (etaf-telega--media-grid media (plist-get message :kind)))))

(defun etaf-telega--media-view (message &optional inset)
  "Return the clickable thumbnail View of MESSAGE, or nil without one.
INSET is the image's (TOP . BOTTOM) pixel gap from adjacent text."
  (when-let* ((media (plist-get message :media))
              (src (plist-get media :src))
              ((display-images-p)))
    (let ((grid (etaf-telega--media-grid media (plist-get message :kind)))
          (id (plist-get message :id)))
      (etaf-node 'box (list :overflow 'hidden :flex-shrink 0
                            :pointer 'hand :help-echo "预览 (RET)" :role 'button
                            :on-press (lambda () (etaf-telega-open-media id)))
                 (list (etaf-node 'image
                                  (list :src src :columns (car grid)
                                        :rows (cdr grid) :inset inset)
                                  nil))))))

(defun etaf-telega--media-duration (message)
  "Return the play prompt shown under MESSAGE's video thumbnail, or nil."
  (when (and (memq (plist-get message :kind) '(video animation))
             (etaf-telega--media-columns message))
    (etaf-node 'flex (list :flex-direction 'row :column-gap '(ch 1)
                           :color (etaf-telega-color :accent))
               (list (etaf-ui-icon 'play :color (etaf-telega-color :accent))
                     (etaf-node 'text nil
                                (list (etaf-telega--duration-label
                                       (plist-get message :duration))))))))

(defun etaf-telega--duration-label (seconds)
  "Return SECONDS as a playing time such as 1:05, or a play prompt."
  (if (and (numberp seconds) (> seconds 0))
      (format "%d:%02d" (/ seconds 60) (% seconds 60))
    "播放"))

(defconst etaf-telega-reaction-choices
  '(("👍" . "👍") ("❤" . "❤️") ("🔥" . "🔥") ("😂" . "😂") ("😮" . "😮")
    ("😢" . "😢") ("🎉" . "🎉") ("👏" . "👏") ("🙏" . "🙏") ("👌" . "👌")
    ("🤔" . "🤔") ("💯" . "💯"))
  "Reactions offered by a message's add-reaction chip, as (KEY . LABEL).")

(defun etaf-telega--message-quote (reply &optional jump)
  "Return the quote of REPLY: its sender over one line behind a colored bar.
JUMP, when non-nil, runs when the quote is activated."
  (let ((color (etaf-telega-sender-color (plist-get reply :sender))))
    (etaf-node 'flex (append
                      (list :flex-direction 'column :min-width '(ch 0)
                            :align-self 'stretch :padding-inline '(ch 1)
                            :border-left (list '(px 3) 'solid color))
                      (when jump
                        (list :role 'button :tab-index 0
                              :help-echo "跳到被引消息"
                              :aria-label "跳到被引消息"
                              :hover-style
                              (list :background-color (etaf-telega-color :surface-2))
                              :on-press jump)))
               (list (etaf-node 'box (list :overflow 'hidden :wrap-mode 'none)
                                (list (etaf-node 'text (list :font-weight 'bold :color color)
                                                 (list (etaf-telega--plain-text
                                                        (or (plist-get reply :sender) "?"))))))
                     (etaf-node 'box (list :overflow 'hidden :wrap-mode 'none)
                                (list (etaf-node 'text (list :color (etaf-telega-color :muted))
                                                 (list (etaf-telega--reply-text reply)))))))))

(defun etaf-telega--message-meta (message)
  "Return MESSAGE's muted meta: views, edited mark, time and delivery mark."
  (let ((views (plist-get message :views))
        (muted (etaf-telega-color :muted)))
    (etaf-node
     'flex (list :flex-direction 'row :flex-shrink 0 :column-gap '(ch 1)
                 :color muted)
     (delq nil
           (list (when views (etaf-ui-icon 'eye :color muted))
                 (when views
                   (etaf-node 'text nil (list (etaf-telega--count-label views))))
                 (etaf-node 'text nil
                            (list (concat (if (plist-get message :edited) "已编辑 " "")
                                          (or (plist-get message :time) "")
                                          (if (plist-get message :outgoing) " ✓" "")))))))))

(defun etaf-telega--message-body (message reactions)
  "Return MESSAGE's text and meta rows, with the REACTIONS View or nil.
The meta ends the text's row when both fit on one line and wraps below
otherwise, so long text keeps the bubble's full width; with reactions it ends
their row instead, and a message without text puts it on its own row."
  (let* ((text (etaf-telega--message-body-text message))
         (text-view (unless (string-empty-p text)
                      (etaf-node 'box (list :flex-grow 1 :flex-basis 'auto
                                            :flex-shrink 1 :min-width '(ch 0))
                                 (list (etaf-node 'text
                                                  (list :color (etaf-telega-color :ink))
                                                  (list text))))))
         (row (lambda (lead)
                (etaf-node 'flex (list :flex-direction 'row :align-items 'flex-end
                                       :justify-content 'flex-end :flex-wrap 'wrap
                                       :column-gap '(ch 2) :width 'stretch)
                           (delq nil (list lead (etaf-telega--message-meta message)))))))
    (if reactions
        (delq nil (list text-view
                        (funcall row (etaf-node 'box (list :flex-grow 1 :flex-shrink 1
                                                           :min-width '(ch 0))
                                                (list reactions)))))
      (list (funcall row text-view)))))

(defun etaf-telega--message-parts (message head bubble)
  "Return the content Views of MESSAGE; HEAD adds the sender name.
With BUBBLE the thumbnail spans the bubble edge to edge while every other
part keeps the bubble's inline padding."
  (let* ((sender (or (plist-get message :sender) "?"))
         (reply (plist-get message :reply))
         (reactions (plist-get message :reactions))
         (id (plist-get message :id))
         (pad (lambda (view)
                (if bubble
                    (etaf-node 'flex (list :flex-direction 'column :width 'stretch
                                           :min-width '(ch 0) :padding-inline '(ch 2))
                               (list view))
                  view))))
    (append
     (when head
       (list (funcall
              pad (etaf-node 'box (list :overflow 'hidden :wrap-mode 'none)
                             (list (etaf-node 'text
                                              (list :font-weight 'bold
                                                    :color (if (plist-get message :outgoing)
                                                               (etaf-telega-color :accent)
                                                             (etaf-telega-sender-color sender)))
                                              (list (etaf-telega--plain-text sender))))))))
     (when reply
       (list (funcall pad
                      (etaf-telega--message-quote
                       reply
                       (lambda () (etaf-telega-show-message (plist-get reply :id)))))))
     (delq nil (list (etaf-telega--media-view
                      message (cons (if (or head reply) 6 0) 6))))
     (mapcar pad (delq nil (list (etaf-telega--media-duration message))))
     (mapcar (lambda (line)
               (funcall pad (etaf-node 'text (list :color (etaf-telega-color :accent))
                                       (list line))))
             (etaf-telega--message-extras message))
     (mapcar pad
             (etaf-telega--message-body
              message
              (when reactions
                (etaf-view
                 (etaf-reactions
                  :items reactions
                  :choices etaf-telega-reaction-choices
                  :add-label "添加表情"
                  :on-toggle (lambda (key) (etaf-telega-react id key))))))))))

(defun etaf-telega--message-gutter (message head)
  "Return the four-cell gutter of MESSAGE: the avatar when HEAD, else blank."
  (let ((sender (or (plist-get message :sender) "?")))
    (if head
        (etaf-node 'etaf-avatar
                   (list :name sender :initials (etaf-telega--initial sender)
                         :src (plist-get message :avatar)
                         :size '(ch 4) :lines 2
                         :background (etaf-telega-sender-color sender))
                   nil)
      (etaf-node 'box (list :width '(ch 4) :flex-shrink 0) (list "")))))

(defconst etaf-telega--bubble-inner-padding '(lh 0.875)
  "Bubble block padding between messages of one sender group.
Each fractional padding line leaves its unpainted rest outside the bubble,
so consecutive bubbles of a group sit a few pixels apart.")

(defconst etaf-telega--bubble-group-padding '(lh 0.625)
  "Bubble block padding at a sender group's edge, spacing groups apart.")

(etaf-define-component etaf-telega-message-row
    (&key message head tail gap separator selected bubble posts)
  "Render MESSAGE as compact lines or, with BUBBLE, as a Telegram bubble.
SELECTED is the message selector; the selected message tints a reserved
two-pixel rule at the row's left, so selection never moves text.  HEAD
starts a sender group with the avatar and name and TAIL ends it; SEPARATOR
is the day label shown above.  Compact rows leave a blank line above when
GAP is non-nil; bubbles instead space groups with their own block padding.
Every bubble sits at the left like Telegram's wide layout, shrinks to its
content up to a reading width, and a thumbnail sets its width.  POSTS marks
channel posts, which carry no avatar gutter."
  :render
  (let* ((id (plist-get message :id))
         (outgoing (plist-get message :outgoing))
         (rule (if (funcall selected id)
                   (etaf-telega-color :accent)
                 (etaf-telega-color :canvas)))
         (parts (etaf-telega--message-parts message head bubble))
         (media (and bubble (etaf-telega--media-columns message))))
    (etaf-node
     'flex (list :ref (etaf-telega--ref 'message id)
                 ;; Reading commands focus rows without adding Tab stops.
                 :tab-index -1
                 :flex-direction 'column :width 'stretch
                 :padding-top (if (or separator (and gap (not bubble))) '(lh 1) '(lh 0))
                 :background-color (etaf-telega-color :chat-bg))
     (delq
      nil
      (list
       (when separator
         (etaf-node 'flex (list :flex-direction 'row :justify-content 'center
                                :width 'stretch :padding-bottom '(lh 1))
                    (list (etaf-node 'box (list :padding-inline '(ch 2)
                                                :background-color (etaf-telega-color :surface-2)
                                                :color (etaf-telega-color :muted))
                                     (list separator)))))
       (if bubble
           (etaf-node
            'flex (list :flex-direction 'row :align-items 'flex-start :width 'stretch
                        :padding-inline '(ch 2) :column-gap '(ch 1)
                        :border-left (list '(px 2) 'solid rule))
            (delq nil (list (unless posts (etaf-telega--message-gutter message head))
                  (etaf-node 'flex
                             (append
                              (list :flex-direction 'column :flex-shrink 1
                                    :min-width '(ch 0)
                                    :padding-top (if head
                                                     etaf-telega--bubble-group-padding
                                                   etaf-telega--bubble-inner-padding)
                                    :padding-bottom (if tail
                                                        etaf-telega--bubble-group-padding
                                                      etaf-telega--bubble-inner-padding)
                                    :border-radius '(px 12)
                                    :background-color
                                    (etaf-telega-color (if outgoing :bubble-out :bubble-in)))
                              (if media
                                  (list :width (list 'ch media))
                                (list :max-width '(ch 72))))
                             parts))))
         (etaf-node
          'flex (list :flex-direction 'row :align-items 'flex-start :width 'stretch
                      :padding-inline '(ch 1) :column-gap '(ch 1))
          (list (etaf-telega--message-gutter message head)
                (etaf-node 'flex (list :flex-direction 'column :flex-grow 1
                                       :flex-basis '(ch 0) :min-width '(ch 0)
                                       :padding-left '(ch 1)
                                       :border-left (list '(px 2) 'solid rule))
                           parts)))))))))

(defun etaf-telega--message-rows (messages selected posts bubble)
  "Return keyed row Views for MESSAGES with SELECTED as their selector.
A day separator opens each new date and a sender group starts whenever the
sender changes or a separator intervenes.  Groups are spaced apart; with
POSTS, as in a channel, every message is its own group.  BUBBLE renders
Telegram bubbles instead of compact lines."
  (let (entries last-date last-sender)
    (dolist (message messages)
      (let* ((date (plist-get message :date))
             (separator (and date (not (equal date last-date))
                             (etaf-telega--day-label date)))
             (sender (plist-get message :sender))
             (head (or posts separator (not (equal sender last-sender)))))
        (setq last-date (or date last-date) last-sender sender)
        (push (list message separator (and head t)) entries)))
    (let (rows (next-head t))
      (dolist (entry entries)
        (pcase-let ((`(,message ,separator ,head) entry))
          (push (etaf-view (etaf-telega-message-row
                            :key (plist-get message :id) :message message
                            :head head :tail next-head :gap head
                            :separator separator
                            :selected selected :bubble bubble :posts posts))
                rows)
          (setq next-head head)))
      rows)))

(defun etaf-telega--search-messages (messages query)
  "Return MESSAGES whose text or sender contains QUERY; all when it is blank."
  (let ((needle (downcase (string-trim (or query "")))))
    (if (string-empty-p needle)
        messages
      (cl-remove-if-not
       (lambda (message)
         (or (string-search needle (downcase (etaf-telega--plain-text
                                              (or (plist-get message :text) ""))))
             (string-search needle (downcase (etaf-telega--plain-text
                                              (or (plist-get message :sender) ""))))))
       messages))))

(defun etaf-telega--chat-search-results (model)
  "Return MODEL's visible message-search results, oldest first.
Local matches over the loaded history and the backend's search results merge
by id, so a result can be a message the client has not loaded yet."
  (let* ((query (or (etaf-value (plist-get model :chat-search)) ""))
         (local (etaf-telega--search-messages
                 (etaf-value (plist-get model :messages)) query))
         (found (etaf-value (plist-get model :chat-search-results))))
    (sort (etaf-telega--merge-messages local found)
          (lambda (left right)
            (< (or (plist-get left :id) 0) (or (plist-get right :id) 0))))))

(defun etaf-telega--composer-attach ()
  "Return the composer's attach control: a paperclip menu of send kinds.
Each item sends a chosen file as its Telegram kind, so a photo, video,
voice note or document goes out with the right type; the composer draft
becomes the caption, exactly like the `C-c C-a' key."
  (etaf-node 'box
             (list :flex-shrink 0 :padding-inline '(ch 0.5)
                   :color (etaf-telega-color :muted))
             (list (etaf-node 'etaf-dropdown-menu
                              (list :icon 'paperclip
                                    :label "发送图片或文件"
                                    :width '(ch 24)
                                    :placement 'top-start
                                    :items '((:key photo :label "图片" :icon image)
                                             (:key video :label "视频" :icon video)
                                             (:key voice :label "语音" :icon mic)
                                             (:key document :label "文件" :icon file))
                                    :on-select #'etaf-telega-attach-as)
                              nil))))

(etaf-define-component etaf-telega-chat-screen (&key model layout)
  "Render MODEL's chat pane: header, scrolling history and fixed composer.
LAYOUT `compact' shows Telega's lines with a back button; the wider layouts
show Telegram bubbles.  The history starts at and follows its newest message
until the reader scrolls away; reaching its top asks for older messages."
  :bindings ((selected (etaf-selector (plist-get model :selected))))
  :render
  (etaf-node
   'flex (etaf-telega--pane-style 'telega-chat-pane nil (etaf-telega--chat-keys))
   (list
    (etaf-view (etaf-telega-chat-bar :model model :back (eq layout 'compact)))
    (etaf-node
     'box (etaf-telega--scroll-body 'telega-history
                                    :scroll-anchor 'end
                                    :background-color (etaf-telega-color :chat-bg)
                                    :on-scroll #'etaf-telega--history-scrolled)
     (list
      (etaf-view
       (flex :flex-direction 'column :width 'stretch :padding-bottom '(lh 1)
             :background-color (etaf-telega-color :chat-bg)
         (expr
          (let* ((loaded (etaf-value (plist-get model :messages)))
                 (query (etaf-value (plist-get model :chat-search)))
                 (messages (if query
                               (etaf-telega--chat-search-results model)
                             loaded)))
            (if messages
                (etaf-telega--message-rows
                 messages selected
                 (eq (plist-get (etaf-value (plist-get model :chat)) :kind) 'channel)
                 (not (eq layout 'compact)))
              (list (etaf-telega--muted-line
                     (if loaded
                         (format "没有匹配“%s”的消息" (string-trim (or query "")))
                       "正在载入消息…"))))))))))
    (etaf-view
     (flex :flex-shrink 0 :flex-direction 'column :width 'stretch
           :padding '((lh 1) (ch 2))
           :background-color (etaf-telega-color :surface)
           :border-top (list '(px 1) 'solid (etaf-telega-color :border))
       (expr (when-let* ((label (etaf-telega--compose-label
                                 (etaf-value (plist-get model :compose)))))
               (etaf-view
                (flex :flex-direction 'row :column-gap '(ch 1) :width 'stretch
                  (text :color (etaf-telega-color :accent) "▎")
                  (text :color (etaf-telega-color :accent) (expr label))
                  (expr (etaf-telega--spacer))
                  (text :color (etaf-telega-color :muted) "C-c C-k 取消")))))
       (expr (etaf-telega--popover-panel model))
       (expr (etaf-telega--upload-strip model))
       (expr (etaf-telega--send-options-strip model))
       (expr (if (etaf-telega--can-post-p (etaf-value (plist-get model :chat)))
                 (etaf-view
                  (flex :flex-direction 'row :align-items 'center :width 'stretch
                        :column-gap '(ch 1)
                    (expr (etaf-telega--composer-attach))
                    (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                      (etaf-text-input
                       :ref 'telega-composer :value (plist-get model :draft)
                       :label "消息" :hide-label t :rows 1 :width 'stretch :variant 'plain
                       :placeholder "写消息…  (i 输入 · RET 发送 · S-RET 换行)"
                       :submit-on-return t
                       :keymap etaf-telega--composer-keymap
                       :on-change #'etaf-telega--compose-changed
                       :on-submit #'etaf-telega-send
                       :on-cancel #'etaf-telega--keep-draft))
                    (etaf-ui-icon :name 'send :color (etaf-telega-color :accent)
                                  :help-echo "发送 (RET)"
                                  :on-press (lambda ()
                                              (etaf-telega-send
                                               (etaf-value (plist-get model :draft)))))))
               (etaf-view
                (flex :flex-direction 'row :align-items 'center
                      :justify-content 'center :width 'stretch
                      :padding-top '(lh 0.5)
                  (text :color (etaf-telega-color :muted)
                        (expr (etaf-telega--no-post-text
                               (etaf-value (plist-get model :chat))))))))))))))

(defun etaf-telega--empty-chat-pane ()
  "Return the chat pane shown beside the list before a chat is opened."
  (etaf-node 'flex (append (etaf-telega--pane-style 'telega-chat-pane)
                           (list :justify-content 'center :align-items 'center
                                 :background-color (etaf-telega-color :chat-bg)))
             (list (etaf-node 'flex (list :flex-direction 'column
                                          :align-items 'center
                                          :row-gap '(lh 1))
                              (list (etaf-node 'box
                                               (list :padding-inline '(ch 2)
                                                     :background-color
                                                     (etaf-telega-color :surface-2)
                                                     :color (etaf-telega-color :muted))
                                               (list "选择一个对话开始聊天"))
                                    (etaf-node 'box (list :color (etaf-telega-color :muted))
                                               (list "按 ? 查看全部键盘快捷键")))))))

(defun etaf-telega--bar-help ()
  "Return the app bar button that opens read-only help for the current pane."
  (etaf-telega--bar-button 'info "键盘快捷键 (?)" #'etaf-telega--show-help))

(defun etaf-telega--details-section (title children)
  "Return a details section headed by muted TITLE over CHILDREN."
  (etaf-node 'flex (list :flex-direction 'column :width 'stretch
                         :padding-top '(lh 1))
             (cons (etaf-node 'text (list :font-weight 'bold
                                          :color (etaf-telega-color :muted))
                              (list title))
                   children)))

(defun etaf-telega--details-media (messages)
  "Return thumbnail rows of the newest photos and videos among MESSAGES."
  (let* ((cell (etaf-telega--cell))
         (cw (car cell))
         (lh (cdr cell))
         (columns 10)
         (rows (max 2 (round (/ (* columns cw) (float lh)))))
         (items (seq-take (nreverse (seq-filter
                                     (lambda (message)
                                       (plist-get (plist-get message :media) :src))
                                     messages))
                          9))
         lines)
    (while items
      (push (etaf-node
             'flex (list :flex-direction 'row :column-gap '(ch 1) :padding-top '(lh 0))
             (mapcar (lambda (message)
                       (let ((id (plist-get message :id)))
                         (etaf-node 'box (list :overflow 'hidden :pointer 'hand
                                               :role 'button :help-echo "预览"
                                               :on-press (lambda () (etaf-telega-open-media id)))
                                    (list (etaf-node 'image
                                                     (list :src (plist-get (plist-get message :media) :src)
                                                           :columns columns :rows rows)
                                                     nil)))))
                     (seq-take items 3)))
            lines)
      (setq items (nthcdr 3 items)))
    (nreverse lines)))

(defun etaf-telega--details-links (messages)
  "Return rows of the newest web pages shared among MESSAGES."
  (mapcar (lambda (message)
            (let ((link (plist-get message :link))
                  (id (plist-get message :id)))
              (etaf-node 'flex (list :flex-direction 'column :width 'stretch
                                     :padding-top '(lh 0) :pointer 'hand :role 'button
                                     :hover-style (list :background-color
                                                        (etaf-telega-color :surface-2))
                                     :on-press (lambda () (etaf-telega-show-message id)))
                         (list (etaf-node 'box (list :overflow 'hidden :wrap-mode 'none)
                                          (list (etaf-node 'text (list :color (etaf-telega-color :accent))
                                                           (list (etaf-telega--one-line
                                                                  (let ((title (plist-get link :title)))
                                                                    (if (string-empty-p title)
                                                                        (plist-get link :site)
                                                                      title)))))))
                               (etaf-node 'box (list :overflow 'hidden :wrap-mode 'none)
                                          (list (etaf-node 'text (list :color (etaf-telega-color :muted))
                                                           (list (plist-get link :site)))))))))
          (seq-take (nreverse (seq-filter (lambda (message) (plist-get message :link))
                                          messages))
                    6)))

(etaf-define-component etaf-telega-chat-details (&key model width)
  "Render the open chat's profile, shared media and links.
WIDTH fixes the pane beside the chat; without it the pane fills the window."
  :render
  (let* ((chat (etaf-value (plist-get model :chat)))
         (messages (etaf-value (plist-get model :messages)))
         (title (or (plist-get chat :title) "?"))
         (unread (or (plist-get chat :unread) 0))
         (chips (delq nil (list (and (plist-get chat :pinned) "置顶")
                                (and (plist-get chat :muted) "免打扰")
                                (and (plist-get chat :archived) "已归档")
                                (and (> unread 0) (format "%s 条未读"
                                                          (etaf-telega--count-label unread))))))
         (media (etaf-telega--details-media messages))
         (links (etaf-telega--details-links messages)))
    (etaf-node
     'flex (append (etaf-telega--pane-style 'telega-details-pane width
                                                     (etaf-telega--details-keys))
                   (list :background-color (etaf-telega-color :surface))
                   (and width
                        (list :border-left (list '(px 1) 'solid
                                                 (etaf-telega-color :border)))))
     (list
      (etaf-telega--bar (list (etaf-node 'box (list :padding-inline '(ch 1))
                                         (list (etaf-telega--bar-title "对话信息" nil)))
                              (etaf-telega--spacer)
                              (etaf-telega--bar-button 'close "关闭 (C-c i)"
                                                       #'etaf-telega-toggle-details)))
      (etaf-node
       'box (etaf-telega--scroll-body 'telega-details :padding '((lh 1) (ch 3)))
       (list
        (etaf-node
         'flex (list :flex-direction 'column :width 'stretch)
         (delq
          nil
          (append
           (list
            (etaf-node 'flex (list :flex-direction 'column :align-items 'center
                                   :width 'stretch)
                       (list (etaf-node 'etaf-avatar
                                        (list :name title :initials (etaf-telega--initial title)
                                              :src (plist-get chat :photo) :size '(ch 10) :lines 5
                                              :background (etaf-telega-sender-color title))
                                        nil)
                             (etaf-node 'box (list :padding-top '(lh 1) :overflow 'hidden
                                                   :wrap-mode 'none :max-width 'stretch)
                                        (list (etaf-node 'text (list :font-weight 'bold
                                                                     :color (etaf-telega-color :ink))
                                                         (list (etaf-telega--plain-text title)))))
                             (etaf-node 'text (list :color (etaf-telega-color :muted))
                                        (list (etaf-telega--chat-meta chat)))))
            (and chips
                 (etaf-node 'flex (list :flex-direction 'row :justify-content 'center
                                        :column-gap '(ch 1) :width 'stretch
                                        :padding-top '(lh 1))
                            (mapcar (lambda (chip)
                                      (etaf-node 'box (list :padding-inline '(ch 1)
                                                            :background-color (etaf-telega-color :surface-2)
                                                            :color (etaf-telega-color :muted))
                                                 (list chip)))
                                    chips))))
           (list (and media (etaf-telega--details-section "共享媒体" media))
                 (and links (etaf-telega--details-section "链接" links))))))))))))

(etaf-define-component etaf-telega-viewer (&key model)
  "Show MODEL's open photo, video or audio in the in-buffer media viewer."
  :render
  (let ((viewer (etaf-value (plist-get model :viewer))))
    (etaf-node
     'etaf-media-viewer
     (list :open (and viewer t)
           :kind (or (plist-get viewer :kind) 'image)
           :src (plist-get viewer :src)
           :source-size (plist-get viewer :size)
           :duration (plist-get viewer :duration)
           :title (or (plist-get viewer :title) "")
           :subtitle (plist-get viewer :subtitle)
           :caption (plist-get viewer :caption)
           :on-close #'etaf-telega-close-media
           :on-previous (and (plist-get viewer :previous)
                             (lambda () (etaf-telega--viewer-step -1)))
           :on-next (and (plist-get viewer :next)
                         (lambda () (etaf-telega--viewer-step 1))))
     nil)))

;;;; Application

(etaf-define-component etaf-telega-app (&key model)
  "Render MODEL as the whole client in one window-tall shell.
The window width selects the layout (see `etaf-telega-split-columns'): one
compact screen at a time, or the list beside a bubble chat.  The list's
right edge drags to resize it.  The details pane, when switched on, joins
the chat, hiding the list when the window cannot fit all three, or
replaces the compact chat.  The media viewer opens over every pane.  A
two-finger swipe goes back from a chat or switches filter tabs."
  :setup
  (progn
    ;; The catalog reads this plist through the Theme scope, so it has to track
    ;; the palette cell: otherwise a switch repaints this client's own rows but
    ;; leaves shared etaf-ui controls such as the search field at the old look.
    (etaf-theme-provide theme)
    ;; One appearance state: a host that frames the client paints its frame,
    ;; title bar and border from this palette and offers these modes, so its
    ;; switch and `T' write the same cell and neither can leave the panel on
    ;; one palette while the messages keep the other.
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme theme
                            :mode etaf-telega--theme-mode
                            :modes etaf-telega--surface-modes))
    ;; A host mounts this View without `etaf-app-open', so the client adopts
    ;; the buffer it renders into and releases it when the host unmounts.
    (etaf-on-mounted (lambda () (etaf-telega--adopt model)))
    (etaf-on-unmounted (lambda () (etaf-telega--release model))))
  :bindings ((theme (etaf-computed
                     (lambda ()
                       (etaf-value etaf-telega--canvas-version)
                       (etaf-telega-theme-defaults))))
             (layout (etaf-computed #'etaf-telega--layout))
             (open (etaf-computed (lambda ()
                                    (and (etaf-value (plist-get model :chat)) t)))))
  :render
  (let* ((layout (etaf-value layout))
         (open (etaf-value open))
         (details (and open (etaf-value (plist-get model :details))))
         (chat-screen (eq (etaf-value (plist-get model :screen)) 'chat))
         (cw (car (etaf-telega--cell)))
         (columns (etaf-telega--columns))
         (panes
          (if (eq layout 'compact)
              (list (cond ((and open chat-screen details)
                           (etaf-view (etaf-telega-chat-details :key 'details
                                                                :model model)))
                          ((and open chat-screen)
                           (etaf-view (etaf-telega-chat-screen :key 'chat :model model
                                                               :layout layout)))
                          (t (etaf-view (etaf-telega-chat-list :key 'list :model model
                                                               :columns columns)))))
            (let* ((list-px (etaf-telega--list-pixels model))
                   (show-list (or (not details)
                                  (>= columns (+ (/ list-px cw)
                                                 etaf-telega--chat-pane-min-columns
                                                 etaf-telega--details-pane-columns)))))
              (append
               (when show-list
                 (list (etaf-view (etaf-telega-chat-list
                                   :key 'list :model model :width (list 'px list-px)
                                   :columns (/ list-px cw)))
                       (etaf-view (etaf-pane-resizer
                                   :key 'resizer :size list-px
                                   :min (* etaf-telega--list-pane-min-columns cw)
                                   :max (/ (* columns cw) 2)
                                   :background (etaf-telega-color :bg)
                                   :on-change (lambda (pixels)
                                                (etaf-telega-model-set-list-width
                                                 model pixels))))))
               (list (if open
                         (etaf-view (etaf-telega-chat-screen :key 'chat :model model
                                                             :layout layout))
                       (etaf-telega--empty-chat-pane)))
               (when details
                 (list (etaf-view (etaf-telega-chat-details
                                   :key 'details :model model
                                   :width (list 'ch etaf-telega--details-pane-columns))))))))))
    (etaf-node
     'flex (list :flex-direction 'column :width 'stretch :height 'stretch
                 ;; The palette owns the inherited ink: without this, plain
                 ;; text such as the composer falls back to the frame's
                 ;; default foreground, which the light palette can render
                 ;; invisible on its own surfaces.
                 :color (etaf-telega-color :ink)
                 :background-color (etaf-telega-color :bg)
                 :keys (etaf-telega--client-keys)
                 :aria-label "Telegram 客户端"
                 :help '("会话与消息由 Telega 的 TDLib 后端提供；关闭客户端不注销账号。"
                         "按键随当前会话列表、消息区或资料栏变化；帮助只读，不发送消息或执行命令。"
                         "同一 TDLib 数据目录只能由一个实例使用。")
                 :on-swipe #'etaf-telega-swipe)
     (list (etaf-node 'flex (list :flex-direction 'row :width 'stretch
                                  :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
                      (delq nil panes))
           (etaf-view (etaf-telega-viewer :model model))))))

(provide 'etaf-telega-views)
;;; etaf-telega-views.el ends here
