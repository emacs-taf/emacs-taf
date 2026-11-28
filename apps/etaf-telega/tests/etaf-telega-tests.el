;;; etaf-telega-tests.el --- Acceptance tests for etaf-telega -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests of the single-buffer client.  Every scenario drives
;; the application through the commands and keys declared in `etaf-telega.el'
;; and asserts what a person would see or what the backend receives.  The
;; fake backend replays fixed chats and messages; no network is touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-telega)

(defun etaf-telega-test--histories (&rest entries)
  "Return a history table from ENTRIES of (CHAT-ID . MESSAGES), newest first."
  (let ((histories (make-hash-table :test #'equal)))
    (dolist (entry entries)
      (puthash (car entry) (cdr entry) histories))
    histories))

(defun etaf-telega-test--backend (&optional responder histories)
  "Return a fake backend with three chats and HISTORIES.
Chat 1 holds two messages unless HISTORIES replaces it.  RESPONDER is the
fake backend's send responder."
  (etaf-telega-backend-fake-create
   :chats (list (list :id 1 :title "Alice" :unread 2 :preview "在的"
                      :kind 'private :time "10:01")
                (list :id 2 :title "工作群" :unread 0 :preview "周报"
                      :kind 'group :time "09:30")
                (list :id 3 :title "每日新闻" :unread 5 :preview "头条"
                      :kind 'channel :time "08:00"))
   :histories (or histories
                  (etaf-telega-test--histories
                   (list 1
                         (list :id 12 :outgoing t :sender "我" :time "10:01"
                               :text "在的")
                         (list :id 11 :sender "Alice" :time "10:00"
                               :text "你好"))))
   :responder responder))

(defmacro etaf-telega-test--with-client (var backend &rest body)
  "Open a client in VAR on BACKEND, run BODY in it and always close it."
  (declare (indent 2))
  `(let* ((backend ,backend)
          (,var (let ((etaf-telega-backend-create-function (lambda () backend)))
                  (etaf-telega-open))))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer ,var)
           ,@body)
       (etaf-telega-close))))

(defun etaf-telega-test--keys (keys)
  "Press KEYS in the client like a person at the keyboard."
  (execute-kbd-macro (kbd keys)))

(defun etaf-telega-test--text ()
  "Return the client buffer's text without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun etaf-telega-test--info (key)
  "Return the visible client fact KEY."
  (plist-get (etaf-telega-info) key))

(defun etaf-telega-test--before-point-p (text)
  "Return non-nil when TEXT appears before point."
  (string-search text (buffer-substring-no-properties (point-min) (point))))

(ert-deftest etaf-telega-tests-open-lists-chats-and-close-releases ()
  "Opening shows the account's chats in one buffer; closing kills it."
  (let (client)
    (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
      (setq client buffer)
      (should (eq (etaf-telega-test--info :screen) 'root))
      (should (equal (etaf-telega-test--info :status) "就绪"))
      (should (= (etaf-telega-test--info :chats) 3))
      (let ((text (etaf-telega-test--text)))
        (dolist (title '("搜索" "Alice" "工作群" "每日新闻" "全部" "群组"))
          (should (string-search title text)))
        (should (< (string-search "Alice" text) (string-search "工作群" text)))))
    (should-not (buffer-live-p client))
    (should-not (etaf-telega-test--info :buffer))))

(ert-deftest etaf-telega-tests-filter-shows-matching-chats ()
  "A filter tab narrows the list and the main tab restores it."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-select-filter 'groups)
    (should (eq (etaf-telega-test--info :filter) 'groups))
    (let ((text (etaf-telega-test--text)))
      (should (string-search "工作群" text))
      (should-not (string-search "每日新闻" text)))
    (etaf-telega-select-filter 'main)
    (should (string-search "每日新闻" (etaf-telega-test--text)))))

(ert-deftest etaf-telega-tests-filter-keys-cycle ()
  "The [ and ] keys walk the list's filter tabs and narrow the list."
  (let ((backend (etaf-telega-backend-fake-create
                  :chats (list (list :id 1 :title "Alice" :unread 2 :mention 1
                                     :preview "在的" :kind 'private :time "10:01")
                               (list :id 2 :title "工作群" :unread 0 :online t
                                     :preview "周报" :kind 'group :time "09:30")))))
    (etaf-telega-test--with-client buffer backend
      (should (eq (etaf-telega-test--info :filter) 'main))
      (should (string-search "Alice" (etaf-telega-test--text)))
      (etaf-telega-test--keys "]")
      (should (eq (etaf-telega-test--info :filter) 'important))
      (let ((text (etaf-telega-test--text)))
        (should (string-search "Alice" text))
        (should-not (string-search "工作群" text)))
      (etaf-telega-test--keys "]")
      (should (eq (etaf-telega-test--info :filter) 'online))
      (let ((text (etaf-telega-test--text)))
        (should (string-search "工作群" text))
        (should-not (string-search "Alice" text)))
      (etaf-telega-test--keys "[")
      (should (eq (etaf-telega-test--info :filter) 'important))
      (etaf-telega-test--keys "[")
      (should (eq (etaf-telega-test--info :filter) 'main)))))

(ert-deftest etaf-telega-tests-list-keys-move-and-open ()
  "n and p walk the list and RET opens the conversation under point."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (should (equal (etaf-telega-test--info :cursor) 1))
    (etaf-telega-test--keys "n")
    (should (equal (etaf-telega-test--info :cursor) 2))
    (etaf-telega-test--keys "n")
    (should (equal (etaf-telega-test--info :cursor) 3))
    (etaf-telega-test--keys "p")
    (should (equal (etaf-telega-test--info :cursor) 2))
    (should (eq (etaf-telega-test--info :screen) 'root))
    (etaf-telega-test--keys "RET")
    (should (eq (etaf-telega-test--info :screen) 'chat))
    (should (equal (etaf-telega-test--info :chat) 2))))

(ert-deftest etaf-telega-tests-chat-with-opens-by-name ()
  "Known conversations are offered by name and the chosen one opens."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (should (equal (mapcar (lambda (item) (plist-get item :title))
                             (etaf-telega-backend-chat-candidates backend))
                     '("Alice" "工作群" "每日新闻")))
      (etaf-telega-chat-with 3)
      (should (eq (etaf-telega-test--info :screen) 'chat))
      (should (equal (etaf-telega-test--info :chat) 3))
      (should (string-search "每日新闻" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-chat-with-offers-names-and-resolves-the-pick ()
  "The interactive chat-with prompt offers names and opens the pick."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection &rest _)
                 (should (equal prompt "会话："))
                 (should (equal collection '("Alice" "工作群" "每日新闻")))
                 "工作群")))
      (call-interactively #'etaf-telega-chat-with))
    (should (eq (etaf-telega-test--info :screen) 'chat))
    (should (equal (etaf-telega-test--info :chat) 2))
    (should (string-search "工作群" (etaf-telega-test--text)))))

(ert-deftest etaf-telega-tests-open-chat-shows-history-and-lands-on-composer ()
  "Opening a chat replaces the list with its history, oldest first."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (should (eq (etaf-telega-test--info :screen) 'chat))
    (should (= (etaf-telega-test--info :messages) 2))
    (let ((text (etaf-telega-test--text)))
      (should (string-search "Alice" text))
      (should-not (string-search "工作群" text))
      (should (< (string-search "你好" text) (string-search "在的" text))))
    (should (etaf-telega-test--before-point-p "在的"))
    (should-not (etaf-telega-test--info :editing))))

(ert-deftest etaf-telega-tests-back-returns-to-the-list ()
  "q leaves the chat for the list with that conversation under point."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 2)
    (etaf-telega-test--keys "q")
    (should (eq (etaf-telega-test--info :screen) 'root))
    (should (equal (etaf-telega-test--info :cursor) 2))
    (should (string-search "每日新闻" (etaf-telega-test--text)))
    (etaf-telega-test--keys "RET")
    (should (equal (etaf-telega-test--info :chat) 2))))

(ert-deftest etaf-telega-tests-message-keys-walk-history-and-composer ()
  "p selects older messages and n past the newest returns to the composer."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "p")
    (should (equal (etaf-telega-test--info :selected) 12))
    (etaf-telega-test--keys "p")
    (should (equal (etaf-telega-test--info :selected) 11))
    (should-not (etaf-telega-test--before-point-p "你好"))
    (etaf-telega-test--keys "n")
    (should (equal (etaf-telega-test--info :selected) 12))
    (etaf-telega-test--keys "n")
    (should-not (etaf-telega-test--info :selected))
    (should (etaf-telega-test--before-point-p "在的"))))

(ert-deftest etaf-telega-tests-jump-newest-selects-the-newest-message ()
  "> shows the newest message from anywhere in the history."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "p p")
    (should (equal (etaf-telega-test--info :selected) 11))
    (etaf-telega-test--keys ">")
    (should (equal (etaf-telega-test--info :selected) 12))))

(defun etaf-telega-test--palette (choice)
  "Return the palette's command names, running CHOICE."
  (let (names)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (setq names (all-completions "" collection))
                 choice)))
      (etaf-palette (etaf-runtime-for-buffer (current-buffer))))
    names))

(ert-deftest etaf-telega-tests-palette-lists-and-runs-the-pane-keys ()
  "The palette lists the keys of the pane at point with what they do and runs one."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (let ((names (etaf-telega-test--palette "下一个会话")))
      (should (member "下一个会话" names))
      (should (member "按名字打开会话" names))
      (should (member "会话资料" names))
      (should-not (member "下一条消息" names)))
    (should (equal (etaf-telega-test--info :cursor) 2))
    (etaf-telega-test--keys "p RET")
    (should-not (etaf-telega-test--info :selected))
    (let ((names (etaf-telega-test--palette "上一条消息")))
      (should (member "下一条消息" names))
      (should (member "跳到被引用的消息" names))
      (should (member "复制消息" names))
      (should-not (member "下一个会话" names)))
    (should (etaf-telega-test--info :selected))))

(ert-deftest etaf-telega-tests-split-layout-keys-follow-the-pane-at-point ()
  "Beside each other, the list and chat answer keys where point is."
  (let ((etaf-telega-split-columns 40))
    (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
      (etaf-telega-test--keys "RET")
      (should (eq (etaf-telega-test--info :screen) 'chat))
      (should (string-search "工作群" (etaf-telega-test--text)))
      (etaf-telega-test--keys "p")
      (should (equal (etaf-telega-test--info :selected) 12))
      ;; Point moved onto a list row: the list's keys answer again.
      (goto-char (point-min))
      (search-forward "工作群")
      (etaf-telega-test--keys "n")
      (should (eq (etaf-telega-test--info :screen) 'root))
      (should (equal (etaf-telega-test--info :cursor) 3))
      (etaf-telega-test--keys "RET")
      (should (eq (etaf-telega-test--info :screen) 'chat))
      (should (equal (etaf-telega-test--info :chat) 3))
      (should (eq (etaf-telega-test--info :selected) nil))
      (etaf-telega-test--keys "q")
      (should (eq (etaf-telega-test--info :screen) 'root))
      (etaf-telega-test--keys "p")
      (should (equal (etaf-telega-test--info :cursor) 2)))))

(ert-deftest etaf-telega-tests-split-layout-tab-and-ret-move-between-panes ()
  "From a focused list row, RET carries focus into the chat; q brings it back."
  (let ((etaf-telega-split-columns 40))
    (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
      (let ((runtime (etaf-runtime-for-buffer buffer)))
        (dotimes (_ 6)
          (unless (string-prefix-p "chat:" (format "%s" (etaf-focused-host-ref runtime)))
            (etaf-telega-test--keys "TAB")))
        (should (equal (format "%s" (etaf-focused-host-ref runtime)) "chat:1"))
        (etaf-telega-test--keys "<down> <up> RET")
        (should (equal (etaf-telega-test--info :chat) 1))
        (should (eq (etaf-focused-host-ref runtime) 'telega-composer))
        ;; The chat pane's keys answer, not the list row that was focused.
        (etaf-telega-test--keys "p")
        (should (equal (etaf-telega-test--info :selected) 12))
        (etaf-telega-test--keys "q")
        (should (eq (etaf-telega-test--info :screen) 'root))
        (should (equal (format "%s" (etaf-focused-host-ref runtime)) "chat:1"))))))

(ert-deftest etaf-telega-tests-composer-option-keys-reach-their-toggles ()
  "The composer's option keys toggle silent, preview and markdown.
These keys share the `C-c C-' prefix, so a new binding must not shadow an
existing one."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "i C-c C-s")
    (should (string-search "静默" (etaf-telega-test--text)))
    (etaf-telega-test--keys "C-c C-l")
    (should (string-search "不预览链接" (etaf-telega-test--text)))
    (etaf-telega-test--keys "C-c C-m")
    (should (string-search "Markdown" (etaf-telega-test--text)))))

(ert-deftest etaf-telega-tests-composer-sends-and-clears-on-ack ()
  "Typing in the composer sends the text and clears it after acceptance."
  (let ((backend (etaf-telega-test--backend
                  (lambda (fake text) (etaf-telega-backend-fake-complete fake text)))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i")
      (should (etaf-telega-test--info :editing))
      (etaf-telega-test--keys "今晚见")
      (etaf-telega-test--keys "RET")
      (should (equal (etaf-telega-backend-fake-sent backend) '("今晚见")))
      (should (equal (etaf-telega-test--info :draft) ""))
      (should (= (etaf-telega-test--info :messages) 3))
      (let ((text (etaf-telega-test--text)))
        (should (< (string-search "在的" text) (string-search "今晚见" text)))))))

(ert-deftest etaf-telega-tests-markdown-ack-clears-the-typed-draft ()
  "An accepted send clears the typed draft when the server text differs."
  (let ((backend (etaf-telega-test--backend
                  (lambda (fake text)
                    ;; Like a Markdown send: the markup is gone from the message.
                    (etaf-telega-backend-fake-complete
                     fake (replace-regexp-in-string "[*]" "" text))))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i C-c C-m")
      (etaf-telega-test--keys "**今晚见**")
      (etaf-telega-test--keys "RET")
      (should (equal (etaf-telega-backend-fake-sent backend) '("**今晚见**")))
      (should (equal (etaf-telega-test--info :draft) ""))
      (should (string-search "今晚见" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-input-history-recalls-sent-texts ()
  "M-p and M-n recall the texts sent in the open conversation."
  (let ((backend (etaf-telega-test--backend
                  (lambda (fake text) (etaf-telega-backend-fake-complete fake text)))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i 第一条 RET")
      (etaf-telega-test--keys "i 第二条 RET")
      (should (equal (etaf-telega-test--info :draft) ""))
      (etaf-telega-test--keys "i")
      (etaf-telega-test--keys "M-p")
      (should (equal (etaf-telega-test--info :draft) "第二条"))
      (etaf-telega-test--keys "M-p")
      (should (equal (etaf-telega-test--info :draft) "第一条"))
      (etaf-telega-test--keys "M-n")
      (should (equal (etaf-telega-test--info :draft) "第二条"))
      (etaf-telega-test--keys "M-n")
      (should (equal (etaf-telega-test--info :draft) "")))))

(ert-deftest etaf-telega-tests-send-options-reach-the-backend ()
  "Silent, preview, schedule and markdown options ride on the next send."
  (let* ((at (float-time (date-to-time "2030-01-02 03:04")))
         (backend (etaf-telega-test--backend
                   (lambda (fake text) (etaf-telega-backend-fake-complete fake text)))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-toggle-silent)
      (etaf-telega-toggle-link-preview)
      (etaf-telega-toggle-markdown)
      (etaf-telega-schedule-send at)
      (let ((text (etaf-telega-test--text)))
        (should (string-search "静默" text))
        (should (string-search "不预览链接" text))
        (should (string-search "Markdown" text))
        (should (string-search "定时 01-02 03:04" text)))
      (etaf-telega-test--keys "i 消息 RET")
      (let* ((send (car (etaf-telega-backend-fake-sends backend)))
             (options (plist-get send :options)))
        (should (equal (plist-get send :text) "消息"))
        (should (equal (plist-get options :silent) t))
        (should (equal (plist-get options :no-preview) t))
        (should (equal (plist-get options :markdown) t))
        (should (equal (plist-get options :at) at)))
      (should-not (string-search "静默" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-clear-draft-discards-the-composer ()
  "C-c C-d clears a draft and leaves the composer."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "i 草稿")
    (should (equal (etaf-telega-test--info :draft) "草稿"))
    (etaf-telega-test--keys "C-c C-d")
    (should (equal (etaf-telega-test--info :draft) ""))
    (should-not (etaf-telega-test--info :editing))))

(ert-deftest etaf-telega-tests-drafts-persist-per-conversation ()
  "Leaving a composer saves its draft and reopening restores it."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i 给Alice的草稿")
      (etaf-telega-test--keys "C-c C-k")
      (should (equal (gethash 1 (etaf-telega-backend-fake-drafts backend))
                     "给Alice的草稿"))
      (etaf-telega-open-chat 2)
      (should (equal (etaf-telega-test--info :draft) ""))
      (etaf-telega-test--keys "i 群草稿")
      (etaf-telega-test--keys "C-c C-k")
      (etaf-telega-open-chat 1)
      (should (equal (etaf-telega-test--info :draft) "给Alice的草稿"))
      (etaf-telega-open-chat 2)
      (should (equal (etaf-telega-test--info :draft) "群草稿")))))

(ert-deftest etaf-telega-tests-send-file-uses-caption-and-progress ()
  "Attaching a file reports progress, uses the draft as caption and clears it."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i 文件说明")
      (etaf-telega-test--keys "C-c C-k")
      (etaf-telega-send-file-as 'document "/tmp/notes.txt")
      (let ((record (car (etaf-telega-backend-fake-files backend))))
        (should (equal (plist-get record :kind) 'document))
        (should (equal (plist-get record :path) "/tmp/notes.txt"))
        (should (equal (plist-get record :caption) "文件说明")))
      (let ((status (etaf-telega-test--info :status)))
        (should (string-search "正在上传" status))
        (should (string-search "45%" status)))
      (etaf-telega-backend-fake-confirm-file backend "/tmp/notes.txt")
      (should (equal (etaf-telega-test--info :status) "就绪"))
      (should (equal (etaf-telega-test--info :draft) ""))
      (should (string-search "notes.txt" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-cancel-upload-stops-the-file ()
  "Cancelling an upload marks it cancelled and clears the status."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-send-file-as 'photo "/tmp/pic.png")
      (etaf-telega-cancel-upload)
      (should (equal (plist-get (car (etaf-telega-backend-fake-files backend))
                                :cancelled)
                     t))
      (should (equal (etaf-telega-test--info :status) "已取消上传")))))

(ert-deftest etaf-telega-tests-attach-menu-sends-the-chosen-kind ()
  "The composer's paperclip menu sends a file as the kind it names.
The kind wins over the extension, so the menu covers the same four types
as Telega's own attachment commands; the draft still becomes the caption."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i 图说")
      (etaf-telega-test--keys "C-c C-k")
      (etaf-telega-attach-as 'photo "/tmp/notes.txt")
      (let ((record (car (etaf-telega-backend-fake-files backend))))
        (should (equal (plist-get record :kind) 'photo))
        (should (equal (plist-get record :path) "/tmp/notes.txt"))
        (should (equal (plist-get record :caption) "图说")))
      (should-error (etaf-telega-attach-as 'sticker "/tmp/notes.txt")
                    :type 'user-error)
      ;; The control is mounted and opens its four kinds.
      (etaf-telega-backend-fake-confirm-file backend "/tmp/notes.txt")
      (let* ((runtime (etaf-runtime-for-buffer buffer))
             (host (cl-find-if (lambda (entry)
                                 (equal (plist-get (cdr entry) :aria-label)
                                        "发送图片或文件"))
                               (etaf-runtime-host-props-entries runtime))))
        (should host)
        (etaf-dispatch-event runtime (car host) 'press)
        (sit-for 0.2)
        (dolist (label '("图片" "视频" "语音" "文件"))
          (should (cl-find-if (lambda (entry)
                                (equal (plist-get (cdr entry) :aria-label) label))
                              (etaf-runtime-host-props-entries runtime))))))))

(ert-deftest etaf-telega-tests-read-only-channel-shows-why-it-cannot-post ()
  "A channel the user may not post to hides the composer and refuses sends."
  (let* ((backend (etaf-telega-backend-fake-create
                   :chats (list (list :id 1 :title "新闻频道" :unread 0 :preview "头条"
                                      :kind 'channel :can-post nil :time "10:00")
                                (list :id 2 :title "工作群" :unread 0 :preview "周报"
                                      :kind 'group :time "09:30"))
                   :histories (etaf-telega-test--histories
                               (list 1 (list :id 11 :sender "新闻" :time "10:00" :text "头条"))
                               (list 2 (list :id 21 :sender "Bob" :time "09:30" :text "周报"))))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (should (string-search "只允许管理员发言" (etaf-telega-test--text)))
      (should-not (string-search "写消息" (etaf-telega-test--text)))
      (should-error (etaf-telega-send "你好") :type 'user-error)
      (should-not (etaf-telega-backend-fake-sends backend))
      ;; A writable conversation keeps the composer and sends normally.
      (etaf-telega-open-chat 2)
      (should (string-search "写消息" (etaf-telega-test--text)))
      (etaf-telega-send "在的")
      (should (equal (car (etaf-telega-backend-fake-sent backend)) "在的")))))

(ert-deftest etaf-telega-tests-attach-refuses-an-empty-path ()
  "An empty file answer starts no upload and keeps the draft."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i 说明")
      (etaf-telega-test--keys "C-c C-k")
      (should-error (etaf-telega-send-file-as 'document "") :type 'user-error)
      (should-error (etaf-telega-send-file-as 'photo nil) :type 'user-error)
      (should-error (etaf-telega-send-file-as 'document "/tmp") :type 'user-error)
      (should-not (etaf-telega-backend-fake-files backend))
      (should (equal (etaf-telega-test--info :draft) "说明"))
      (should-not (string-search "正在上传" (etaf-telega-test--text)))
      (should-not (string-search "正在上传" (etaf-telega-test--info :status))))))

(ert-deftest etaf-telega-tests-failed-send-clears-the-pending-upload ()
  "A backend failure drops the upload strip and keeps the draft for retry."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i 说明")
      (etaf-telega-test--keys "C-c C-k")
      (etaf-telega-send-file-as 'document "/tmp/notes.txt")
      (should (string-search "正在上传" (etaf-telega-test--text)))
      (etaf-telega-backend-fake-fail backend "telega error=400: 管理员权限不足")
      (should (equal (etaf-telega-test--info :status) "错误：管理员权限不足"))
      (should-not (string-search "正在上传" (etaf-telega-test--text)))
      (should (equal (etaf-telega-test--info :draft) "说明")))))

(ert-deftest etaf-telega-tests-compose-popovers-complete-and-pick ()
  "Typing @ or # completes; the emoji and sticker pickers insert or send."
  (let ((backend (etaf-telega-backend-fake-create
                  :chats (list (list :id 1 :title "Alice" :unread 0 :preview "在的"
                                     :kind 'private :time "10:01"))
                  :histories (etaf-telega-test--histories
                              (list 1 (list :id 11 :sender "Alice" :time "10:00"
                                            :text "下周见 #计划")))
                  :members (list (list :id 2 :name "Alice" :username "alice"))
                  :stickers (list (list :id 7 :emoji "🎉" :label "派对"
                                        :file-id 71 :thumb-id 72
                                        :width 512 :height 512)))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "i @al")
      (should (string-search "@alice" (etaf-telega-test--text)))
      (etaf-telega-test--keys "C-c C-j")
      (should (equal (etaf-telega-test--info :draft) "@alice "))
      (etaf-telega-test--keys "C-c C-k")
      (etaf-telega-test--keys "i ")
      (etaf-telega-test--keys "#计")
      (should (string-search "#计划" (etaf-telega-test--text)))
      (etaf-telega-test--keys "RET")
      (should (equal (etaf-telega-test--info :draft) "@alice #计划 "))
      (etaf-telega-test--keys "C-c C-k")
      (etaf-telega-test--keys "i C-c C-e")
      (should (string-search "👍" (etaf-telega-test--text)))
      ;; Clicking the first popover item via mouse-1 inserts that exact item (not the last one).
      (save-excursion
        (goto-char (point-min))
        (should (search-forward "👍" nil t))
        (goto-char (match-beginning 0))
        (let* ((pos (point))
               (km (get-text-property pos 'keymap))
               (cmd (and (keymapp km) (lookup-key km [mouse-1])))
               (last-input-event (list 'mouse-1 (list (selected-window) pos '(0 . 0) 0))))
          (should (functionp cmd))
          (call-interactively cmd)))
      (should (string-search "👍" (etaf-telega-test--info :draft)))
      (etaf-telega-test--keys "C-c C-k")
      (etaf-telega-open-stickers "")
      (should (string-search "🎉" (etaf-telega-test--text)))
      (etaf-telega-test--keys "RET")
      (should (equal (car (etaf-telega-backend-fake-files backend))
                     '(:kind sticker :path 7))))))

(ert-deftest etaf-telega-tests-draft-survives-until-ack ()
  "A pending send keeps the draft and clears only after acceptance."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-compose)
      (etaf-telega-test--keys "未确认")
      (etaf-telega-test--keys "RET")
      (should (equal (etaf-telega-test--info :draft) "未确认"))
      (etaf-telega-backend-fake-complete backend "未确认")
      (should (equal (etaf-telega-test--info :draft) "")))))

(ert-deftest etaf-telega-tests-leaving-the-composer-keeps-the-draft ()
  "Cancelling plain typing keeps the text as the chat's draft."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "i")
    (etaf-telega-test--keys "草稿")
    (etaf-telega-test--keys "C-c C-k")
    (should-not (etaf-telega-test--info :editing))
    (should (equal (etaf-telega-test--info :draft) "草稿"))
    (should (string-search "草稿" (etaf-telega-test--text)))))

(ert-deftest etaf-telega-tests-reply-quotes-the-selected-message ()
  "r arms a reply to the message under point and the sent message quotes it."
  (let ((backend (etaf-telega-test--backend
                  (lambda (fake text) (etaf-telega-backend-fake-complete fake text)))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "p p r")
      (should (eq (etaf-telega-test--info :compose) 'reply))
      (should (string-search "回复 Alice：你好" (etaf-telega-test--text)))
      (etaf-telega-test--keys "收到")
      (etaf-telega-test--keys "RET")
      (should (equal (etaf-telega-backend-fake-replies backend) '(("收到" . 11))))
      (should-not (etaf-telega-test--info :compose))
      (let ((text (etaf-telega-test--text)))
        (should-not (string-search "回复 Alice" text))
        ;; 回复以带竖线的引用块呈现，正文在新消息之前。
        (should (string-match-p "Alice[ \n│]*你好\\(.\\|\n\\)*收到" text))))))

(ert-deftest etaf-telega-tests-edit-replaces-and-cancel-restores-the-draft ()
  "e edits an outgoing message; cancelling an edit restores the old draft."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "i")
    (etaf-telega-test--keys "原草稿")
    (etaf-telega-test--keys "C-c C-k p e")
    (should (eq (etaf-telega-test--info :compose) 'edit))
    (should (equal (etaf-telega-test--info :draft) "在的"))
    (etaf-telega-test--keys "C-c C-k")
    (should-not (etaf-telega-test--info :compose))
    (should (equal (etaf-telega-test--info :draft) "原草稿"))
    (etaf-telega-test--keys "p e")
    (etaf-telega-test--keys "C-e ！")
    (etaf-telega-test--keys "RET")
    (should-not (etaf-telega-test--info :compose))
    (should (string-match-p "在的！ +已编辑" (etaf-telega-test--text)))))

(ert-deftest etaf-telega-tests-edit-refuses-incoming-messages ()
  "Only the account's own messages can be edited."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "p p")
    (should-error (etaf-telega-edit) :type 'user-error)
    (should-not (etaf-telega-test--info :compose))))

(ert-deftest etaf-telega-tests-live-changes-update-the-open-chat ()
  "Arrivals append once, updates replace in place and deletions remove."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (let ((message (list :id 13 :sender "Alice" :time "10:02" :text "晚上见")))
        (etaf-telega-backend-fake-deliver backend message)
        (etaf-telega-backend-fake-deliver backend (copy-tree message)))
      (should (= (etaf-telega-test--info :messages) 3))
      (should (< (string-search "在的" (etaf-telega-test--text))
                 (string-search "晚上见" (etaf-telega-test--text))))
      (etaf-telega-backend-fake-update
       backend (list :id 11 :sender "Alice" :time "10:00" :text "你好呀" :edited t))
      (should (string-match-p "你好呀[ \n]*已编辑 10:00" (etaf-telega-test--text)))
      (etaf-telega-backend-fake-remove backend 12)
      (should (= (etaf-telega-test--info :messages) 2))
      (should-not (string-search "在的" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-load-more-prepends-older-pages ()
  "Older pages load above the history until the chat's first message."
  (let ((backend (etaf-telega-test--backend
                  nil
                  (etaf-telega-test--histories
                   (cons 1 (cl-loop for id from 15 downto 11
                                    collect (list :id id :sender "Alice"
                                                  :time "10:00"
                                                  :text (format "第%d条" id))))))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (cl-loop repeat 5 until (etaf-telega-test--info :history-end)
               do (etaf-telega-load-more))
      (should (etaf-telega-test--info :history-end))
      (should (= (etaf-telega-test--info :messages) 5))
      (let ((text (etaf-telega-test--text)))
        (should (< (string-search "第11条" text) (string-search "第13条" text)
                   (string-search "第15条" text)))))))

(ert-deftest etaf-telega-tests-jump-loads-and-selects-a-message ()
  "Jumping to an unloaded message loads its page and selects it."
  (let ((backend (etaf-telega-test--backend
                  nil
                  (etaf-telega-test--histories
                   (cons 1 (cl-loop for id from 50 downto 11
                                    collect (list :id id :sender "Alice"
                                                  :time "10:00"
                                                  :text (format "第%d条" id))))))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (should (< (etaf-telega-test--info :messages) 40))
      (should-not (string-search "第11条" (etaf-telega-test--text)))
      (etaf-telega-show-message 11)
      (should (equal (etaf-telega-test--info :selected) 11))
      (should (string-search "第11条" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-jumps-reach-quoted-pinned-and-dated-messages ()
  "Quoted, pinned and dated jumps select the right message."
  (let* ((histories
          (etaf-telega-test--histories
           (list 1
                 (list :id 13 :sender "Alice" :time "09:00" :date "2026-10-05"
                       :text "今天")
                 (list :id 12 :outgoing t :sender "我" :time "10:00" :date "2026-10-04"
                       :text "在的"
                       :reply (list :id 11 :sender "Alice" :kind 'text :text "你好"))
                 (list :id 11 :sender "Alice" :time "10:00" :date "2026-10-03"
                       :text "你好"))))
         (backend (etaf-telega-backend-fake-create
                   :chats (list (list :id 1 :title "Alice" :unread 0 :preview "在的"
                                      :kind 'private :time "10:01" :pinned-id 13))
                   :histories histories)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "p p")
      (etaf-telega-jump-quote)
      (should (equal (etaf-telega-test--info :selected) 11))
      (etaf-telega-jump-pinned)
      (should (equal (etaf-telega-test--info :selected) 13))
      (etaf-telega-jump-date (float-time (date-to-time "2026-10-04 10:00")))
      (should (equal (etaf-telega-test--info :selected) 12)))))

(ert-deftest etaf-telega-tests-pinned-jump-follows-the-backend-over-the-cache ()
  "C-c g p asks the backend, so pins made after loading still jump."
  (let* ((histories
          (etaf-telega-test--histories
           (list 1
                 (list :id 13 :sender "Alice" :time "09:00" :date "2026-10-05"
                       :text "今天")
                 (list :id 12 :outgoing t :sender "我" :time "10:00" :date "2026-10-04"
                       :text "在的"))))
         (loaded (list :id 1 :title "Alice" :unread 0 :preview "在的"
                       :kind 'private :time "10:01" :pinned-id 12))
         (backend (etaf-telega-backend-fake-create
                   :chats (list loaded) :histories histories)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      ;; A pin made after the list loaded: the backend knows, the cache does not.
      (setf (etaf-telega-backend-fake-chats backend)
            (list (plist-put (copy-sequence loaded) :pinned-id 13)))
      (etaf-telega-jump-pinned)
      (should (equal (etaf-telega-test--info :selected) 13))
      ;; The conversation was unpinned after loading: the cache still shows a
      ;; pinned message, the backend does not, and no message is selected.
      (setf (etaf-telega-backend-fake-chats backend)
            (list (cl-remove :pinned-id (copy-sequence loaded))))
      (let ((said nil)
            (selected (etaf-telega-test--info :selected)))
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args)
                     (setq said (apply #'format format args)))))
          (etaf-telega-jump-pinned))
        (should (equal said "这个对话没有置顶消息"))
        (should (equal (etaf-telega-test--info :selected) selected))))))

(ert-deftest etaf-telega-tests-next-unread-chat-moves-to-the-unread-one ()
  "C-c g u on the list selects the next conversation with unread messages."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (should (equal (etaf-telega-test--info :cursor) 1))
    (etaf-telega-test--keys "C-c g u")
    (should (equal (etaf-telega-test--info :cursor) 3))
    (etaf-telega-test--keys "C-c g u")
    (should (equal (etaf-telega-test--info :cursor) 1))))

(ert-deftest etaf-telega-tests-fastnav-walks-unread-mentions-and-outgoing ()
  "C-c g u/m/o select unread, mentioning and outgoing messages."
  (let* ((histories
          (etaf-telega-test--histories
           (list 1
                 (list :id 15 :outgoing t :sender "我" :time "10:04" :text "收到")
                 (list :id 14 :sender "Alice" :time "10:03" :text "在吗 @fixture")
                 (list :id 13 :sender "Alice" :time "10:02" :text "新消息")
                 (list :id 12 :sender "Alice" :time "10:01" :text "已读")
                 (list :id 11 :outgoing t :sender "我" :time "10:00" :text "在的"))))
         (backend (etaf-telega-test--backend nil histories)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "C-c g u")
      (should (equal (etaf-telega-test--info :selected) 12))
      (etaf-telega-test--keys "C-c g u")
      (should (equal (etaf-telega-test--info :selected) 13))
      (etaf-telega-test--keys "C-c g m")
      (should (equal (etaf-telega-test--info :selected) 14))
      (etaf-telega-test--keys "C-c g o")
      (should (equal (etaf-telega-test--info :selected) 15)))))

(ert-deftest etaf-telega-tests-day-separators-label-each-date ()
  "Each new date opens with a day label; today reads as 今天."
  (let ((today (format-time-string "%Y-%m-%d")))
    (etaf-telega-test--with-client buffer
        (etaf-telega-test--backend
         nil (etaf-telega-test--histories
              (list 1 (list :id 12 :sender "Alice" :date today :time "09:00" :text "早")
                    (list :id 11 :sender "Alice" :date "2020-01-02" :time "22:00"
                          :text "晚安"))))
      (etaf-telega-open-chat 1)
      (let ((text (etaf-telega-test--text)))
        (should (< (string-search "2020-01-02" text) (string-search "晚安" text)
                   (string-search "今天" text) (string-search "早" text)))))))

(ert-deftest etaf-telega-tests-activate-opens-media-or-composes ()
  "RET on a media message opens it through Telega; elsewhere it composes."
  (let ((backend (etaf-telega-test--backend
                  nil (etaf-telega-test--histories
                       (list 1 (list :id 12 :sender "Alice" :time "10:01" :text "看看"
                                     :kind 'photo)
                             (list :id 11 :sender "Alice" :time "10:00" :text "你好"))))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (should (string-search "看看" (etaf-telega-test--text)))
      (etaf-telega-test--keys "p RET")
      (should (equal (cdr (car (etaf-telega-backend-fake-natives backend))) '(1 12)))
      (should-not (etaf-telega-test--info :editing))
      (etaf-telega-test--keys "p RET")
      (should (= (length (etaf-telega-backend-fake-natives backend)) 1))
      (should (etaf-telega-test--info :editing)))))

(defun etaf-telega-test--image ()
  "Return a temporary SVG file standing in for downloaded media."
  (let ((file (make-temp-file "etaf-telega-test" nil ".svg")))
    (with-temp-file file
      (insert "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='3'>"
              "<rect width='4' height='3' fill='red'/></svg>"))
    file))

(ert-deftest etaf-telega-tests-viewer-pages-and-closes-in-the-buffer ()
  "RET on a photo opens the in-buffer viewer; n and p page; q closes it."
  (let* ((image (etaf-telega-test--image))
         (media (list :src image :width 4 :height 3))
         (backend (etaf-telega-test--backend
                   nil (etaf-telega-test--histories
                        (list 1 (list :id 12 :sender "Alice" :time "10:01"
                                      :text "第二张" :kind 'photo :media media)
                              (list :id 11 :sender "Alice" :time "10:00"
                                    :text "第一张" :kind 'photo :media media))))))
    (unwind-protect
        (etaf-telega-test--with-client buffer backend
          (etaf-telega-open-chat 1)
          (etaf-telega-test--keys "p RET")
          (should (equal (etaf-telega-test--info :viewer) 12))
          (should-not (etaf-telega-backend-fake-natives backend))
          (etaf-telega-test--keys "p")
          (should (equal (etaf-telega-test--info :viewer) 11))
          (etaf-telega-test--keys "n")
          (should (equal (etaf-telega-test--info :viewer) 12))
          (etaf-telega-test--keys "q")
          (should-not (etaf-telega-test--info :viewer))
          (should (eq (etaf-telega-test--info :screen) 'chat)))
      (delete-file image))))

(ert-deftest etaf-telega-tests-viewer-plays-voice-messages ()
  "A voice message opens in the in-buffer viewer with its total time."
  (let* ((histories (etaf-telega-test--histories
                     (list 1 (list :id 11 :sender "Alice" :time "10:00" :text ""
                                   :kind 'voice :duration 3
                                   :media (list :full "/tmp/voice.ogg")))))
         (backend (etaf-telega-test--backend nil histories)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (etaf-telega-open-media 11)
      (should (equal (etaf-telega-test--info :viewer) 11))
      (should (string-search "0:03" (etaf-telega-test--text)))
      (etaf-telega-close-media)
      (should-not (etaf-telega-test--info :viewer)))))

(ert-deftest etaf-telega-tests-react-toggles-a-visible-reaction ()
  "Reacting shows the emoji and its count; reacting again removes it."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (should-not (string-search "👍" (etaf-telega-test--text)))
    (etaf-telega-react 11 "👍")
    (should (string-search "👍" (etaf-telega-test--text)))
    (etaf-telega-react 11 "👍")
    (should-not (string-search "👍" (etaf-telega-test--text)))))

(ert-deftest etaf-telega-tests-custom-emoji-reaction-renders-and-toggles ()
  "A custom emoji reaction renders as a chip and toggles by clicking it.
Its key is the scalar `custom:<id>' form, so the chip row never asks ETAF for
a compound View key."
  (let* ((key "custom:6183560906786479310")
         (backend (etaf-telega-test--backend
                   nil (etaf-telega-test--histories
                        (list 1 (list :id 11 :sender "Alice" :time "10:00"
                                      :text "你好"
                                      :reactions (list (list :key key :label "✦"
                                                             :count 3 :chosen nil))))))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (let ((text (etaf-telega-test--text)))
        (should (string-search "✦ 3" text))
        (should-not (string-search "回调错误" text)))
      (etaf-telega-test--activate-label (etaf-runtime-for-buffer buffer) "✦ 3")
      (let ((text (etaf-telega-test--text)))
        (should (string-search "✦ 4" text))
        (should-not (string-search "回调错误" text))))))

(ert-deftest etaf-telega-tests-own-messages-align-with-everyone-else ()
  "Outgoing and incoming messages start in the same column."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (cl-flet ((column (text)
                (save-excursion
                  (goto-char (point-min))
                  (search-forward text)
                  (- (current-column) (length text)))))
      (should (= (column "你好") (column "在的"))))))

(ert-deftest etaf-telega-tests-swipes-go-back-and-change-filters ()
  "Swiping right leaves a chat; swiping on the list changes the filter."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-swipe 'right)
    (should (eq (etaf-telega-test--info :screen) 'root))
    (let ((filter (etaf-telega-test--info :filter)))
      (etaf-telega-swipe 'left)
      (should-not (equal (etaf-telega-test--info :filter) filter))
      (etaf-telega-swipe 'right)
      (should (equal (etaf-telega-test--info :filter) filter)))))

(ert-deftest etaf-telega-tests-printing-keys-never-edit-the-history ()
  "Unbound printing keys on a message leave the history text unchanged."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "p")
    (let ((before (etaf-telega-test--text)))
      (etaf-telega-test--keys "z")
      (should (equal (etaf-telega-test--text) before))
      (should-not (etaf-telega-test--info :editing)))))

(ert-deftest etaf-telega-tests-telega-keys-run-native-commands ()
  "Telega's own keys run Telega's commands on the chat or message at point."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-test--keys "n P")
      (should (equal (car (etaf-telega-backend-fake-natives backend))
                     '(telega-chat-toggle-pin 2 nil)))
      (etaf-telega-open-chat 1)
      (etaf-telega-test--keys "p c")
      (should (equal (car (etaf-telega-backend-fake-natives backend))
                     '(telega-msg-copy-dwim 1 12))))))

(ert-deftest etaf-telega-tests-chat-action-keys-run-native-commands ()
  "M, A and L run Telega's mute, archive and leave on the chat under point."
  (let ((backend (etaf-telega-test--backend)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-test--keys "n")
      (should (equal (etaf-telega-test--info :cursor) 2))
      (etaf-telega-test--keys "M")
      (should (equal (car (etaf-telega-backend-fake-natives backend))
                     '(telega-chat-toggle-muted 2 nil)))
      (etaf-telega-test--keys "A")
      (should (equal (car (etaf-telega-backend-fake-natives backend))
                     '(telega-chat-toggle-archive 2 nil)))
      (etaf-telega-test--keys "L")
      (should (equal (car (etaf-telega-backend-fake-natives backend))
                     '(telega-chat-leave 2 nil))))))

(defun etaf-telega-test--painted-row (buffer)
  "Return (POSITION . BACKGROUND) of BUFFER's first row that paints a fill."
  (with-current-buffer buffer
    (let ((pos (point-min))
          found)
      (while (and (< pos (point-max)) (not found))
        (let ((background (plist-get (get-text-property pos 'face) :background)))
          (when background (setq found (cons pos background))))
        (setq pos (1+ pos)))
      found)))

(defun etaf-telega-test--painted-background (buffer position)
  "Return the background BUFFER paints at POSITION."
  (with-current-buffer buffer
    (plist-get (get-text-property position 'face) :background)))

(defun etaf-telega-test--row-painting (buffer color)
  "Return the first position in BUFFER whose face paints COLOR as background."
  (with-current-buffer buffer
    (let ((pos (point-min))
          found)
      (while (and (< pos (point-max)) (not found))
        (when (equal color
                     (plist-get (get-text-property pos 'face) :background))
          (setq found pos))
        (setq pos (1+ pos)))
      found)))

(ert-deftest etaf-telega-tests-theme-switch-repaints-the-client ()
  "Toggling the theme repaints the mounted rows and keeps the open chat."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (let* ((row (etaf-telega-test--painted-row buffer))
           (mode etaf-telega-theme))
      (should (cdr row))
      (etaf-telega-toggle-theme)
      (should-not (eq mode etaf-telega-theme))
      (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
      ;; A cycle can land on a palette the frame already painted; the next
      ;; switch then has to be visible in the mounted rows.
      (when (equal (cdr row) (etaf-telega-test--painted-background buffer (car row)))
        (etaf-telega-toggle-theme)
        (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
      (should-not (equal (cdr row)
                         (etaf-telega-test--painted-background buffer (car row))))
      (should (eq (etaf-telega-test--info :screen) 'chat))
      (should (string-search "在的" (etaf-telega-test--text))))))

(etaf-define-component etaf-telega-test--framing-host (&key surface session)
  "Provide SURFACE to the client SESSION and render it below."
  :setup (etaf-surface-provide surface)
  :render (etaf-telega-view session))

(ert-deftest etaf-telega-tests-declares-its-surface-to-a-host ()
  "A host frames the client from the surface the client declares.
Without the declaration a panel's title-bar switch painted the frame chrome
light while the messages kept the palette they had already painted."
  (let* ((etaf-telega-backend-create-function
          (lambda () (etaf-telega-test--backend)))
         (surface (etaf-surface-create))
         (session (etaf-telega-create))
         (buffer (generate-new-buffer " *etaf-telega framing host*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (etaf-mount buffer
                      (etaf-view (etaf-telega-test--framing-host
                                  :surface surface :session session)))
          (should (equal '((light . "亮") (auto . "随") (dark . "暗"))
                         (etaf-surface-modes surface)))
          ;; The client may also hold `native', a palette its host's standard
          ;; three-mode switch does not offer.
          (should (memq (etaf-value (etaf-surface-mode surface))
                        '(auto light dark native)))
          ;; The host's switch writes the cell the client reads, so every
          ;; mounted row repaints with the palette of that mode instead of
          ;; keeping the one it rendered with.
          (etaf-set-value (etaf-surface-mode surface) 'dark)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (let ((dark (etaf-telega-color :bg))
                (pos (etaf-telega-test--row-painting
                      buffer (etaf-telega-color :bg))))
            (should pos)
            (should (equal dark (etaf-telega-test--painted-background buffer pos)))
            (etaf-set-value (etaf-surface-mode surface) 'light)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should-not (equal dark (etaf-telega-color :bg)))
            (should (equal (etaf-telega-color :bg)
                           (etaf-telega-test--painted-background buffer pos)))
            (should (equal (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg)
                           (etaf-telega-color :bg)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-telega-tests-search-finds-opens-and-remembers-chats ()
  "/ searches the list; RET opens the first match, which becomes recent."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-test--keys "/")
    (should (equal (etaf-telega-test--info :search) ""))
    (should (string-search "常用联系人" (etaf-telega-test--text)))
    (etaf-telega-test--keys "工作")
    (should (equal (etaf-telega-test--info :search) "工作"))
    (let ((text (etaf-telega-test--text)))
      (should (string-search "工作群" text))
      (should-not (string-search "每日新闻" text)))
    (etaf-telega-test--keys "RET")
    (should (eq (etaf-telega-test--info :screen) 'chat))
    (should (equal (etaf-telega-test--info :chat) 2))
    (should-not (etaf-telega-test--info :search))
    (etaf-telega-test--keys "q /")
    (let ((text (etaf-telega-test--text)))
      (should (string-match-p "最近\\(.\\|\n\\)*工作群" text)))
    (etaf-telega-search-clear-recent)
    (should (string-search "打开的搜索结果会列在这里" (etaf-telega-test--text)))
    (etaf-telega-search-exit)
    (should-not (etaf-telega-test--info :search))
    (should (string-search "每日新闻" (etaf-telega-test--text)))))

(ert-deftest etaf-telega-tests-search-finds-server-only-chats ()
  "Typing in the list search finds conversations the list has not loaded."
  (let ((backend (etaf-telega-backend-fake-create
                  :chats (list (list :id 1 :title "Alice" :unread 0 :preview "在的"
                                     :kind 'private :time "10:01"))
                  :dormant (list (list :id 9 :title "远端频道" :unread 0 :preview "订阅"
                                       :kind 'channel :time "08:00")))))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-search)
      (etaf-telega-test--keys "远端")
      (let ((text (etaf-telega-test--text)))
        (should (string-search "远端频道" text))
        (should-not (string-search "Alice" text)))
      (etaf-telega-test--keys "RET")
      (should (equal (etaf-telega-test--info :chat) 9))
      (should (string-search "远端频道" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-chat-search-finds-server-history ()
  "Message search reaches a match the loaded history does not carry."
  (let* ((histories
          (etaf-telega-test--histories
           (cons 1 (cl-loop for id from 40 downto 1
                            collect (list :id id :sender "Alice" :time "10:00"
                                          :text (if (= id 3) "很久以前"
                                                  (format "消息%d" id)))))))
         (backend (etaf-telega-test--backend nil histories)))
    (etaf-telega-test--with-client buffer backend
      (etaf-telega-open-chat 1)
      (should-not (string-search "很久以前" (etaf-telega-test--text)))
      (etaf-telega-chat-search)
      (etaf-telega-test--keys "很久")
      (should (string-search "很久以前" (etaf-telega-test--text)))
      (etaf-telega-test--keys "RET")
      (should (equal (etaf-telega-test--info :chat-search) "很久"))
      (etaf-telega-test--keys "p")
      (should (equal (etaf-telega-test--info :selected) 3))
      (etaf-telega-test--keys "RET")
      (should-not (etaf-telega-test--info :chat-search))
      (should (equal (etaf-telega-test--info :selected) 3))
      (should (string-search "很久以前" (etaf-telega-test--text))))))

(ert-deftest etaf-telega-tests-chat-search-and-details-pane ()
  "/ in a chat narrows the history; C-c i shows and hides the details."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (etaf-telega-open-chat 1)
    (etaf-telega-test--keys "C-c C-k /")
    (should (equal (etaf-telega-test--info :chat-search) ""))
    (etaf-telega-test--keys "你好")
    (let ((text (etaf-telega-test--text)))
      (should (string-search "你好" text))
      (should-not (string-search "在的" text)))
    (etaf-telega-chat-search-exit)
    (should-not (etaf-telega-test--info :chat-search))
    (should (string-search "在的" (etaf-telega-test--text)))
    (should-not (etaf-telega-test--info :details))
    (etaf-telega-test--keys "C-c i")
    (should (etaf-telega-test--info :details))
    (should (string-search "对话信息" (etaf-telega-test--text)))
    (etaf-telega-test--keys "C-c i")
    (should-not (etaf-telega-test--info :details))))

(defun etaf-telega-test--activate-label (runtime label)
  "Activate the visible control named LABEL in RUNTIME and return its ref."
  (let* ((entry (cl-find-if (lambda (item)
                            (equal (plist-get (cdr item) :aria-label) label))
                          (etaf-runtime-host-props-entries runtime)))
         (ref (car entry)))
    (unless ref (error "Missing control: %s" label))
    (etaf-focus runtime ref)
    (execute-kbd-macro (kbd "RET"))
    ref))

(ert-deftest etaf-telega-tests-help-entries-are-read-only ()
  "Keys, the info button and both menus share scoped in-buffer help."
  (etaf-telega-test--with-client buffer (etaf-telega-test--backend)
    (let ((runtime (etaf-runtime-for-buffer buffer))
          (windows (window-list)))
      (dolist (screen '(root chat))
        (when (eq screen 'root) (etaf-telega-next-chat))
        (when (eq screen 'chat)
          (etaf-telega-open-chat 1)
          (etaf-telega-test--keys "p"))
        (dolist (entry (if (eq screen 'root) '(key menu) '(key button menu)))
          (let ((chat (etaf-telega-test--info :chat))
                (cursor (etaf-telega-test--info :cursor))
                (selected (etaf-telega-test--info :selected))
                (focus (etaf-focused-host-ref runtime)))
            (pcase entry
              ('key (execute-kbd-macro (kbd "?")))
              ('button
               (setq focus (etaf-telega-test--activate-label runtime "键盘快捷键 (?)")))
              ('menu
               (setq focus (etaf-telega-test--activate-label
                            runtime (if (eq screen 'root) "菜单" "更多")))
               (etaf-telega-test--activate-label runtime "键盘快捷键")))
            (let ((deadline (+ (float-time) 2)))
              (while (and (< (float-time) deadline)
                          (not (string-match-p "快捷键 · 只读" (etaf-telega-test--text))))
                (sleep-for 0.01)))
            (should (string-match-p "快捷键 · 只读" (etaf-telega-test--text)))
            (let* ((data (etaf-help-data runtime))
                   (entries (apply #'append
                                   (mapcar (lambda (group) (plist-get group :entries))
                                           (plist-get data :groups))))
                   (next (cl-find "n" entries :test #'equal
                                  :key (lambda (item) (plist-get item :key))))
                   (same-runtime (eq runtime (etaf-runtime-for-buffer buffer))))
              (should same-runtime)
              (should (equal windows (window-list)))
              (should (eq (window-buffer) buffer))
              (should (equal (plist-get next :label)
                             (if (eq screen 'root) "下一个会话" "下一条消息")))
              (should (string-match-p (if (eq screen 'root) "会话列表" "消息区")
                                      (plist-get next :source))))
            (when (and (eq screen 'chat) (eq entry 'key))
              (let ((snapshot (etaf-help-data runtime)))
                (etaf-telega-backend-fake-deliver
                 backend (list :id 13 :sender "Alice" :time "10:02" :text "新消息"))
                (let ((after (etaf-help-data runtime)))
                  (should (equal snapshot after)))))
            (execute-kbd-macro (kbd "/"))
            (execute-kbd-macro "?")
            (execute-kbd-macro (kbd "<escape>"))
            (should (string-match-p "快捷键 · 只读" (etaf-telega-test--text)))
            (execute-kbd-macro (kbd "<escape>"))
            (let ((restored (equal focus (etaf-focused-host-ref runtime))))
              (should restored))
            (should (equal chat (etaf-telega-test--info :chat)))
            (should (equal cursor (etaf-telega-test--info :cursor)))
            (should (equal (list screen entry selected)
                           (list screen entry (etaf-telega-test--info :selected))))))))))

;; Requires the application runtime: before it the client mounted by hand,
;; kept a buffer-local caret hook and left the canvas at the default face.
(ert-deftest etaf-telega-tests-open-uses-the-application-canvas ()
  "The client is an ETAF application whose canvas follows its palette."
  (etaf-telega-test--with-client client (etaf-telega-test--backend)
    (let ((canvas (lambda ()
                    (plist-get (car (last (alist-get 'default
                                                     face-remapping-alist)))
                               :background))))
      (should (etaf-app-state client))
      (should-not (buffer-local-value 'mode-line-format client))
      (should-not (buffer-local-value 'cursor-type client))
      (let ((before (funcall canvas)))
        (should (stringp before))
        (should (equal before (etaf-telega-color :bg)))
        (etaf-telega-toggle-theme)
        (etaf-runtime-flush (etaf-runtime-for-buffer client))
        (should (equal (funcall canvas) (etaf-telega-color :bg)))))))

(provide 'etaf-telega-tests)
;;; etaf-telega-tests.el ends here

(ert-deftest etaf-telega-tests-view-mounts-in-a-host-buffer ()
  "A host mounts the View, drives the client's commands and releases it.
The View lays out for the buffer it is given, the client adopts that buffer so
its commands act on the mounted session, and unmounting stops the backend."
  (let* ((etaf-telega-backend-create-function
          (lambda () (etaf-telega-test--backend)))
         (session (etaf-telega-create))
         (buffer (generate-new-buffer " *etaf-telega host*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (etaf-mount buffer (etaf-telega-view session))
          (should (eq buffer (etaf-telega-test--info :buffer)))
          (should (= 3 (etaf-telega-test--info :chats)))
          (should (string-search "Alice" (etaf-telega-test--text)))
          (etaf-telega-open-chat 1)
          (should (= 1 (etaf-telega-test--info :chat)))
          (etaf-unmount (etaf-runtime-for-buffer buffer))
          (should-not (etaf-telega-test--info :buffer)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))
