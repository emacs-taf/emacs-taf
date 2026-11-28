;;; etaf-telega-gui-scenarios.el --- GUI acceptance for the Telegram client -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Run inside an owned graphical Emacs instance.  Drives the real client
;; through its declared public API with the offline backend, using command-loop
;; keys and shared control activation; Telega's account is never touched and no
;; frame is raised.
;;; Code:
(require 'cl-lib)
(require 'etaf-telega)
(require 'emacs-gui-verifier)

(defvar etaf-telega-gui--buffer nil)
(defvar etaf-telega-gui--backend nil)
(defvar etaf-telega-gui--hold nil
  "When non-nil the fake backend withholds its send acknowledgement.")

(defvar etaf-telega-gui--attach nil
  "Path of the fixture file used by the attachment actions.")

(defun etaf-telega-gui--responder (backend text)
  "Acknowledge TEXT for BACKEND unless the scenario holds the receipt."
  (unless etaf-telega-gui--hold
    (etaf-telega-backend-fake-complete backend text)))

(defun etaf-telega-gui--photo ()
  "Return an in-memory photo preview, like Telega's minithumbnail."
  (create-image
   (concat "<svg xmlns='http://www.w3.org/2000/svg' width='320' height='200'>"
           "<rect width='320' height='200' fill='#3b6ea8'/>"
           "<circle cx='250' cy='60' r='30' fill='#f2c14e'/>"
           "<path d='M0 200 L110 90 L200 170 L250 130 L320 200 Z' fill='#2c4f72'/></svg>")
   'svg t))

(defun etaf-telega-gui--silent-wav ()
  "Write a one-second silent WAV and return its path."
  (let* ((path (expand-file-name "etaf-telega-silent.wav" temporary-file-directory))
         (rate 8000)
         (data (make-string (* rate 2) 0))
         (le16 (lambda (n) (unibyte-string (logand n 255) (logand (ash n -8) 255))))
         (le32 (lambda (n) (unibyte-string (logand n 255) (logand (ash n -8) 255)
                                           (logand (ash n -16) 255)
                                           (logand (ash n -24) 255)))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert "RIFF" (funcall le32 (+ 36 (length data))) "WAVE"
              "fmt " (funcall le32 16) (funcall le16 1) (funcall le16 1)
              (funcall le32 rate) (funcall le32 (* rate 2))
              (funcall le16 2) (funcall le16 16)
              "data" (funcall le32 (length data)) data)
      (write-region (point-min) (point-max) path nil 'silent))
    path))

(defun etaf-telega-gui--backend-create ()
  "Return a fake backend with three chats, a short history and one photo."
  (let ((histories (make-hash-table :test #'equal)))
    (puthash 1 (list (list :id 13 :sender "Alice" :time "10:02" :date "2026-10-04"
                           :kind 'photo :text "海边"
                           :media (list :src (etaf-telega-gui--photo)
                                        :width 320 :height 200))
                     (list :id 12 :outgoing t :sender "我" :time "10:01" :date "2026-10-04" :text "在的"
                           :link (list :site "Example" :title "示例链接")
                           :reply (list :id 11 :sender "Alice" :kind 'text :text "你好"))
                     (list :id 11 :sender "Alice" :time "10:00" :date "2026-10-04" :text "你好 @fixture")
                     (list :id 10 :sender "Alice" :time "09:59" :date "2026-10-04"
                           :kind 'voice :duration 3
                           :media (list :full (etaf-telega-gui--silent-wav))))
             histories)
    (puthash 2 (list (list :id 21 :sender "Bob" :time "09:30" :date "2026-10-04" :text "周报收到"))
             histories)
    (setq etaf-telega-gui--backend
          (etaf-telega-backend-fake-create
           :chats (list (list :id 1 :title "Alice" :unread 2 :preview "晚上见" :time "10:02"
                              :kind 'private :username "alice" :pinned t :pinned-id 13
                              :last-read 11
                              :description "GUI 验收用的假档案")
                        (list :id 2 :title "工作群" :unread 0 :preview "周报收到" :time "09:30"
                              :kind 'group)
                        (list :id 3 :title "每日新闻" :unread 5 :preview "头条速览" :time "08:00"
                              :kind 'channel))
           :dormant (list (list :id 4 :title "远端频道" :unread 0 :preview "订阅消息"
                                :kind 'channel :time "08:00"))
           :members (list (list :id 2 :name "Alice" :username "alice")
                          (list :id 5 :name "Bob" :username "bob"))
           :stickers (list (list :id 7 :emoji "🎉" :label "派对"
                                 :file-id 71 :thumb-id 72
                                 :width 512 :height 512))
           :histories histories :responder #'etaf-telega-gui--responder))))

(defun etaf-telega-gui--main ()
  "Select the client window."
  (if-let* ((window (get-buffer-window etaf-telega-gui--buffer t)))
      (select-window window)
    (switch-to-buffer etaf-telega-gui--buffer)))

(defun etaf-telega-gui--info ()
  "Return the client facts of the owned buffer."
  (with-current-buffer etaf-telega-gui--buffer (etaf-telega-info)))

(defun etaf-telega-gui--idle (_)
  "Check settled client facts."
  (and (stringp (plist-get (etaf-telega-gui--info) :status))
       (not (string-prefix-p "错误" (plist-get (etaf-telega-gui--info) :status)))))

(defun etaf-telega-gui--text ()
  "Return the owned buffer's visible text."
  (with-current-buffer etaf-telega-gui--buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-telega-gui--geometry ()
  "Check that the document spans the window's width without overflowing.
The client is a scrolling document, so its height follows the content; its
width must follow the window exactly at every size."
  (let* ((window (get-buffer-window etaf-telega-gui--buffer))
         (size (and window (window-text-pixel-size window)))
         (body-width (and window (window-body-width window t)))
         (char-width (and window (frame-char-width (window-frame window)))))
    (and window
         (<= (car size) body-width)
         ;; `window-text-pixel-size' omits trailing whitespace, so a filled
         ;; row may measure up to two character cells short.
         (>= (car size) (- body-width (* 2 char-width)))
         (= (window-hscroll window) 0)
         (let ((info (etaf-telega-gui--info)))
           (and (integerp (plist-get info :chats))
                (<= 1 (plist-get info :chats)))))))

(defun etaf-telega-gui--action (id execute &optional ready screenshot)
  "Build the verifier action ID with EXECUTE, READY and SCREENSHOT."
  (etaf-gui-verifier-action-create
   :id id :screenshot screenshot
   :execute (lambda (context)
              (etaf-telega-gui--main) (funcall execute context)
              (setf (etaf-gui-verifier-context-target-buffer context)
                    (window-buffer (selected-window))))
   :settled-p
   (lambda (_context)
     (with-current-buffer etaf-telega-gui--buffer
       (and (or (not ready) (funcall ready nil))
            (etaf-telega-gui--geometry))))
   :assertions
   (lambda (_context)
     (with-current-buffer etaf-telega-gui--buffer
       (append (list (etaf-gui-verifier-assert
                      "no client error"
                      (not (string-prefix-p "错误" (plist-get (etaf-telega-info) :status)))))
               (etaf-gui-verifier-line-height-assertions etaf-telega-gui--buffer)
               (list (etaf-gui-verifier-assert
                      "composer lives inside the conversation screen"
                      (let ((info (etaf-telega-info)))
                        (or (not (eq (plist-get info :screen) 'chat))
                            ;; A modal media viewer owns the commit while it is open.
                            (plist-get info :viewer)
                            (let* ((runtime (etaf-runtime-for-buffer etaf-telega-gui--buffer))
                                   (bounds (and runtime
                                                (etaf-host-ref-bounds runtime 'telega-composer))))
                              (and runtime (consp bounds))))))))))))

(defun etaf-telega-gui--type (text)
  "Type TEXT into the active composer session through the command loop."
  (execute-kbd-macro (vconcat text)))

(defun etaf-telega-gui--press (help)
  "Press the control HELP names: its help, aria label or button label.
Wait briefly for a layout or menu change to finish rendering the control."
  (let* ((runtime (etaf-runtime-for-buffer etaf-telega-gui--buffer))
         (deadline (+ (float-time) 3))
         host)
    (while (and (not host) (< (float-time) deadline))
      (setq host
            (cl-find-if (lambda (entry)
                          (let ((props (cdr entry)))
                            (or (equal (plist-get props :help-echo) help)
                                (equal (plist-get props :aria-label) help)
                                (equal (plist-get props :label) help))))
                        (etaf-runtime-host-props-entries runtime)))
      (unless host (sit-for 0.05)))
    (unless host (error "No app bar control %S" help))
    (etaf-dispatch-event runtime (car host) 'press)))

(defun etaf-telega-gui--native-p (command message)
  "Return non-nil when Telega's COMMAND last ran on MESSAGE of chat 1."
  (equal (car (etaf-telega-backend-fake-natives etaf-telega-gui--backend))
         (list command 1 message)))

(defvar etaf-telega-gui--walk nil
  "Focus refs visited by the last Tab walk.")

(defun etaf-telega-gui--tab-walk ()
  "Press TAB until focus cycles back, restore it and return the visited refs."
  (let* ((runtime (etaf-runtime-for-buffer etaf-telega-gui--buffer))
         (original (etaf-focused-host-ref runtime))
         (start (progn (execute-kbd-macro (kbd "TAB"))
                       (etaf-focused-host-ref runtime)))
         (walk (list start)))
    (catch 'done
      (dotimes (_ 60)
        (execute-kbd-macro (kbd "TAB"))
        (let ((ref (etaf-focused-host-ref runtime)))
          (push ref walk)
          (when (equal ref start) (throw 'done nil)))))
    ;; Hand focus back to the stop focused before the walk, if any.
    (when original (etaf-focus runtime original))
    (setq etaf-telega-gui--walk (nreverse walk))))

(defun etaf-telega-gui--walk-closed-p (minimum)
  "Return non-nil when the last walk cycled through MINIMUM distinct stops."
  (let ((walk etaf-telega-gui--walk))
    (and (car walk) (equal (car walk) (car (last walk)))
         (>= (length (delete-dups (copy-sequence (butlast walk)))) minimum))))

(defun etaf-telega-gui--palette-labels ()
  "Open the palette, cancel it, and return its labels."
  (let (names)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (setq names (all-completions "" collection))
                 (keyboard-quit))))
      (condition-case nil
          (etaf-palette (etaf-runtime-for-buffer (current-buffer)))
        (quit nil)))
    names))

(defun etaf-telega-gui-run (directory)
  "Run the offline product workflow and save evidence to DIRECTORY."
  (let* ((original-frame (selected-frame))
         (frame (make-frame '((name . "Telegram / GUI acceptance") (no-focus-on-map . t))))
         (scenario
          (etaf-gui-verifier-scenario-create
           :name "etaf-telega-product"
           :claim "Single-buffer Telega client: list, chat, media, composer, native keys"
           :initialize
           (lambda (context)
             (select-frame frame) (delete-frame original-frame t)
             (set-frame-size frame 140 44)
             ;; Emacs 31 (NS) crashes measuring a fallback-font character
             ;; after an SVG <text> avatar loads on a never-displayed frame.
             (redisplay t)
             (setq etaf-telega-gui--hold nil)
             (let ((etaf-telega-backend-create-function
                    (lambda () (etaf-telega-gui--backend-create) etaf-telega-gui--backend)))
               (setq etaf-telega-gui--buffer (etaf-telega-open))
               (with-current-buffer etaf-telega-gui--buffer (etaf-telega-open-chat 1)))
             (setf (etaf-gui-verifier-context-target-buffer context) etaf-telega-gui--buffer))
           :actions
           (append
            (list
             (etaf-telega-gui--action
              "chat-open" #'ignore
              (lambda (_)
                (and (etaf-telega-gui--idle nil)
                     (eq (plist-get (etaf-telega-gui--info) :screen) 'chat)
                     (with-current-buffer etaf-telega-gui--buffer
                       (string-search "海边" (buffer-substring-no-properties
                                              (point-min) (point))))))
              t)
             (etaf-telega-gui--action
              "chat-back" (lambda (_) (execute-kbd-macro (kbd "q")))
              (lambda (_) (and (eq (plist-get (etaf-telega-gui--info) :screen) 'root)
                               (equal (plist-get (etaf-telega-gui--info) :cursor) 1)))
              t)
             (etaf-telega-gui--action
              "root-tab-walk"
              (lambda (_)
                (etaf-telega-gui--tab-walk)
                ;; The walk moved the list cursor; Shift-Tab back to the
                ;; first row so the next actions start from it.
                (let ((runtime (etaf-runtime-for-buffer etaf-telega-gui--buffer)))
                  (dotimes (_ 20)
                    (unless (equal (format "%s" (etaf-focused-host-ref runtime))
                                   "chat:1")
                      (execute-kbd-macro (kbd "<backtab>"))))))
              (lambda (_) (and (etaf-telega-gui--walk-closed-p 3)
                               (memq 'telega-search etaf-telega-gui--walk)
                               (eq (plist-get (etaf-telega-gui--info) :screen) 'root)
                               (equal (plist-get (etaf-telega-gui--info) :cursor) 1)))
              t)
             (etaf-telega-gui--action
              "root-palette" #'ignore
              (lambda (_) (> (length (etaf-telega-gui--palette-labels)) 5)))
             (etaf-telega-gui--action
              "filter-key-next" (lambda (_) (execute-kbd-macro (kbd "] ] ]")))
              (lambda (_)
                (and (eq (plist-get (etaf-telega-gui--info) :filter) 'groups)
                     (string-match-p "工作群" (etaf-telega-gui--text))
                     (not (string-match-p "每日新闻" (etaf-telega-gui--text))))))
             (etaf-telega-gui--action
              "filter-key-previous" (lambda (_) (execute-kbd-macro (kbd "[ [ [")))
              (lambda (_)
                (and (eq (plist-get (etaf-telega-gui--info) :filter) 'main)
                     (string-match-p "Alice" (etaf-telega-gui--text)))))
             (etaf-telega-gui--action
              "filter-groups" (lambda (_) (etaf-telega-select-filter 'groups))
              (lambda (_) (and (eq (plist-get (etaf-telega-gui--info) :filter) 'groups)
                               (string-match-p "工作群" (etaf-telega-gui--text))
                               (not (string-match-p "每日新闻" (etaf-telega-gui--text))))))
             (etaf-telega-gui--action
              "filter-main" (lambda (_) (etaf-telega-select-filter 'main))
              (lambda (_) (and (eq (plist-get (etaf-telega-gui--info) :filter) 'main)
                               (string-match-p "Alice" (etaf-telega-gui--text)))))
             (etaf-telega-gui--action
              "next-chat" (lambda (_) (execute-kbd-macro (kbd "n")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :cursor) 2)))
             (etaf-telega-gui--action
              "previous-chat" (lambda (_) (execute-kbd-macro (kbd "p")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :cursor) 1)))
             (etaf-telega-gui--action
              "chat-open-again" (lambda (_) (execute-kbd-macro (kbd "RET")))
              (lambda (_) (and (eq (plist-get (etaf-telega-gui--info) :screen) 'chat)
                               (equal (plist-get (etaf-telega-gui--info) :chat) 1))))
             (etaf-telega-gui--action
              "select-older-messages" (lambda (_) (execute-kbd-macro (kbd "p p p")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 11)) t)
             (etaf-telega-gui--action
              "jump-newest" (lambda (_) (execute-kbd-macro (kbd ">")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 13)))
             (etaf-telega-gui--action
              "jump-quote-click" (lambda (_) (etaf-telega-gui--press "跳到被引消息"))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 11)))
             (etaf-telega-gui--action
              "show-message" (lambda (_) (etaf-telega-show-message 12))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 12)))
             (etaf-telega-gui--action
              "jump-pinned-key" (lambda (_) (execute-kbd-macro (kbd "C-c g p")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 13)))
             (etaf-telega-gui--action
              "jump-date-key"
              (lambda (_)
                (cl-letf (((symbol-function 'read-string)
                           (lambda (&rest _) "2026-10-04 10:00")))
                  (call-interactively #'etaf-telega-jump-date)))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 11)))
             (etaf-telega-gui--action
              "native-copy" (lambda (_) (execute-kbd-macro (kbd "> p p c")))
              (lambda (_) (etaf-telega-gui--native-p 'telega-msg-copy-dwim 11)))
             (etaf-telega-gui--action
              "reply" (lambda (_)
                        (execute-kbd-macro (kbd "r"))
                        (unless (eq (plist-get (etaf-telega-gui--info) :compose) 'reply)
                          (error "Reply mode did not arm"))
                        (etaf-telega-gui--type "收到，明早见")
                        (execute-kbd-macro (kbd "RET")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (null (plist-get info :compose))
                       (equal (plist-get info :draft) "")
                       (string-match-p "Alice\\(.\\|\n\\)*你好\\(.\\|\n\\)*收到，明早见"
                                       (etaf-telega-gui--text)))))
              t)
             (etaf-telega-gui--action
              "edit" (lambda (_)
                       (execute-kbd-macro (kbd "> e"))
                       (unless (eq (plist-get (etaf-telega-gui--info) :compose) 'edit)
                         (error "Edit mode did not arm"))
                       (execute-kbd-macro (kbd "C-e"))
                       (etaf-telega-gui--type "！")
                       (execute-kbd-macro (kbd "RET")))
              (lambda (_)
                (and (null (plist-get (etaf-telega-gui--info) :compose))
                     (string-match-p "收到，明早见！" (etaf-telega-gui--text))
                     (string-match-p "已编辑" (etaf-telega-gui--text)))))
             (etaf-telega-gui--action
              "cancel-edit-restores-draft"
              (lambda (_)
                (execute-kbd-macro (kbd "> e"))
                (etaf-telega-gui--type "不要这个")
                (execute-kbd-macro (kbd "C-c C-k")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (null (plist-get info :compose))
                       (equal (plist-get info :draft) "")
                       (not (string-match-p "不要这个" (etaf-telega-gui--text))))))
              t)
             (etaf-telega-gui--action
              "live-message-appends"
              (lambda (_)
                (etaf-telega-backend-fake-deliver
                 etaf-telega-gui--backend
                 (list :id 99 :sender "Alice" :time "10:05" :date "2026-10-05" :text "好的，明早见")))
              (lambda (_) (string-match-p "好的，明早见" (etaf-telega-gui--text)))
              t)
             (etaf-telega-gui--action
              "live-message-removed"
              (lambda (_) (etaf-telega-backend-fake-remove etaf-telega-gui--backend 99))
              (lambda (_) (not (string-match-p "好的，明早见" (etaf-telega-gui--text)))))
             (etaf-telega-gui--action
              "composer-draft" (lambda (_)
                                 (execute-kbd-macro (kbd "i"))
                                 (etaf-telega-gui--type "未发送的草稿")
                                 (execute-kbd-macro (kbd "C-c C-k")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (not (plist-get info :editing))
                       (equal (plist-get info :draft) "未发送的草稿"))))
              t)
             (etaf-telega-gui--action
              "late-receipt-keeps-draft"
              (lambda (_)
                (setq etaf-telega-gui--hold t)
                (execute-kbd-macro (kbd "i"))
                (execute-kbd-macro (kbd "RET")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (not (plist-get info :editing))
                       (equal (plist-get info :draft) "未发送的草稿")))))
             (etaf-telega-gui--action
              "confirm-clears-draft"
              (lambda (_)
                (setq etaf-telega-gui--hold nil)
                (etaf-telega-backend-fake-complete
                 etaf-telega-gui--backend "未发送的草稿"))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :draft) "")) t)
             (etaf-telega-gui--action
              "composer-caret-and-clean-lines"
              (lambda (_)
                (execute-kbd-macro (kbd "i"))
                (etaf-telega-gui--type "光标")
                (unless (eq (plist-get (etaf-telega-gui--info) :editing) t)
                  (error "Composer session did not open"))
                (unless (buffer-local-value 'cursor-type etaf-telega-gui--buffer)
                  (error "Editing shows no caret"))
                (when (buffer-local-value 'truncate-lines etaf-telega-gui--buffer)
                  (error "Editing enabled truncate-lines"))
                (execute-kbd-macro (kbd "C-j"))
                (etaf-telega-gui--type "第二行")
                (execute-kbd-macro (kbd "C-c C-k")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (not (plist-get info :editing))
                       (equal (plist-get info :draft) "光标\n第二行"))))
              t)
             (etaf-telega-gui--action
              "composer-resize-keeps-editing"
              (lambda (_)
                (execute-kbd-macro (kbd "i"))
                (etaf-telega-gui--type "缩放")
                (set-frame-size frame 120 40)
                (unless (eq (plist-get (etaf-telega-gui--info) :editing) t)
                  (error "Resize ended the composer session"))
                (etaf-telega-gui--type "中")
                (execute-kbd-macro (kbd "C-c C-k")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (not (plist-get info :editing))
                       (equal (plist-get info :draft) "光标\n第二行缩放中"))))
              t)
             (etaf-telega-gui--action
              "app-bar-back-keeps-draft"
              (lambda (_)
                (execute-kbd-macro (kbd "p p"))
                (etaf-telega-gui--press "返回会话列表 (q)"))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (eq (plist-get info :screen) 'root)
                       (equal (plist-get info :cursor) 1))))
              t)
             (etaf-telega-gui--action
              "native-chat-key" (lambda (_) (execute-kbd-macro (kbd "n P")))
              (lambda (_)
                (equal (car (etaf-telega-backend-fake-natives etaf-telega-gui--backend))
                       '(telega-chat-toggle-pin 2 nil))))
             (etaf-telega-gui--action
              "native-mute-key" (lambda (_) (execute-kbd-macro (kbd "M")))
              (lambda (_)
                (equal (car (etaf-telega-backend-fake-natives etaf-telega-gui--backend))
                       '(telega-chat-toggle-muted 2 nil))))
             (etaf-telega-gui--action
              "native-archive-key" (lambda (_) (execute-kbd-macro (kbd "A")))
              (lambda (_)
                (equal (car (etaf-telega-backend-fake-natives etaf-telega-gui--backend))
                       '(telega-chat-toggle-archive 2 nil))))
             (etaf-telega-gui--action
              "native-leave-key" (lambda (_) (execute-kbd-macro (kbd "L")))
              (lambda (_)
                (equal (car (etaf-telega-backend-fake-natives etaf-telega-gui--backend))
                       '(telega-chat-leave 2 nil))))
             (etaf-telega-gui--action
              "next-unread-chat" (lambda (_) (execute-kbd-macro (kbd "C-c g u")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :cursor) 3)))
             (etaf-telega-gui--action
              "reopen-restores-draft"
              (lambda (_) (etaf-telega-open-chat 1))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (eq (plist-get info :screen) 'chat)
                       (equal (plist-get info :draft) "光标\n第二行缩放中")))))
             (etaf-telega-gui--action
              "history-previous"
              (lambda (_)
                (execute-kbd-macro (kbd "i"))
                (execute-kbd-macro (kbd "M-p")))
              (lambda (_)
                (and (eq (plist-get (etaf-telega-gui--info) :editing) t)
                     (equal (plist-get (etaf-telega-gui--info) :draft) "未发送的草稿"))))
             (etaf-telega-gui--action
              "history-next"
              (lambda (_)
                (execute-kbd-macro (kbd "M-n"))
                (execute-kbd-macro (kbd "C-c C-k")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (not (plist-get info :editing))
                       (equal (plist-get info :draft) "光标\n第二行缩放中")))))
             (etaf-telega-gui--action
              "next-unread-message" (lambda (_) (execute-kbd-macro (kbd "C-c g u")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 13)))
             (etaf-telega-gui--action
              "next-mention" (lambda (_) (execute-kbd-macro (kbd "C-c g m")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 11)))
             (etaf-telega-gui--action
              "next-outgoing" (lambda (_) (execute-kbd-macro (kbd "C-c g o")))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 12)))
             (etaf-telega-gui--action
              "app-bar-jump-newest"
              (lambda (_)
                (execute-kbd-macro (kbd "p p p"))
                (etaf-telega-gui--press "更多")
                (etaf-telega-gui--press "跳到最新消息"))
              (lambda (_) (equal (plist-get (etaf-telega-gui--info) :selected) 13)))
             (etaf-telega-gui--action
              "reload-history" (lambda (_) (execute-kbd-macro (kbd "g")))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (equal (plist-get info :chat) 1)
                       (< 0 (plist-get info :messages))))))
             (etaf-telega-gui--action
              "open-voice-viewer"
              (lambda (_)
                (etaf-telega-open-media 10)
                (etaf-telega-gui--press "Play / pause (Space)"))
              (lambda (_)
                (and (equal (plist-get (etaf-telega-gui--info) :viewer) 10)
                     (string-match-p "0:00 / 0:03" (etaf-telega-gui--text))
                     (get-process "etaf-ui-audio")))
              t)
             (etaf-telega-gui--action
              "close-voice-viewer"
              (lambda (_) (etaf-telega-close-media))
              (lambda (_)
                (and (not (plist-get (etaf-telega-gui--info) :viewer))
                     (not (get-process "etaf-ui-audio")))))
             (etaf-telega-gui--action
              "send-options"
              (lambda (_)
                (etaf-telega-toggle-silent)
                (etaf-telega-toggle-link-preview)
                (etaf-telega-toggle-markdown)
                (etaf-telega-schedule-send
                 (float-time (date-to-time "2030-01-02 03:04"))))
              (lambda (_)
                (let ((text (etaf-telega-gui--text)))
                  (and (string-match-p "静默" text)
                       (string-match-p "不预览链接" text)
                       (string-match-p "Markdown" text)
                       (string-match-p "定时 01-02 03:04" text))))
              t)
             (etaf-telega-gui--action
              "send-options-message"
              (lambda (_)
                (etaf-telega-clear-draft)
                (execute-kbd-macro (kbd "i"))
                (etaf-telega-gui--type "带选项的消息")
                (execute-kbd-macro (kbd "RET")))
              (lambda (_)
                (let* ((send (car (etaf-telega-backend-fake-sends
                                   etaf-telega-gui--backend)))
                       (options (plist-get send :options)))
                  (and (equal (plist-get send :text) "带选项的消息")
                       (equal (plist-get options :silent) t)
                       (equal (plist-get options :no-preview) t)
                       (equal (plist-get options :markdown) t)
                       (equal (plist-get options :at)
                              (float-time (date-to-time "2030-01-02 03:04")))
                       (equal (plist-get (etaf-telega-gui--info) :draft) "")
                       (not (string-match-p "静默" (etaf-telega-gui--text)))))))
             (etaf-telega-gui--action
              "drafts-persist"
              (lambda (_)
                (execute-kbd-macro (kbd "i"))
                (etaf-telega-gui--type "草稿A")
                (execute-kbd-macro (kbd "C-c C-k"))
                (etaf-telega-open-chat 2)
                (execute-kbd-macro (kbd "i"))
                (etaf-telega-gui--type "草稿B")
                (execute-kbd-macro (kbd "C-c C-k"))
                (etaf-telega-open-chat 1))
              (lambda (_)
                (let ((drafts (etaf-telega-backend-fake-drafts etaf-telega-gui--backend)))
                  (and (equal (plist-get (etaf-telega-gui--info) :draft) "草稿A")
                       (equal (gethash 1 drafts) "草稿A")
                       (equal (gethash 2 drafts) "草稿B"))))
              t)
             (etaf-telega-gui--action
              "compose-mention"
              (lambda (_)
                (execute-kbd-macro (kbd "i C-c C-d i @al")))
              (lambda (_)
                (and (string-match-p "@alice" (etaf-telega-gui--text))
                     (equal (plist-get (etaf-telega-gui--info) :draft) "@al")))
              t)
             (etaf-telega-gui--action
              "compose-mention-insert"
              (lambda (_)
                (execute-kbd-macro (kbd "RET"))
                (execute-kbd-macro (kbd "C-c C-k")))
              (lambda (_)
                (equal (plist-get (etaf-telega-gui--info) :draft) "@alice "))
              t)
             (etaf-telega-gui--action
              "compose-emoji"
              (lambda (_)
                (execute-kbd-macro (kbd "i C-c C-e")))
              (lambda (_)
                (and (string-match-p "👍" (etaf-telega-gui--text))
                     (string-match-p "表情" (etaf-telega-gui--text))))
              t)
             (etaf-telega-gui--action
              "compose-emoji-insert"
              (lambda (_)
                (execute-kbd-macro (kbd "RET"))
                (execute-kbd-macro (kbd "C-c C-k")))
              (lambda (_)
                (string-match-p "👍" (or (plist-get (etaf-telega-gui--info) :draft) ""))))
             (etaf-telega-gui--action
              "compose-sticker"
              (lambda (_)
                (etaf-telega-open-stickers ""))
              (lambda (_)
                (and (string-match-p "🎉" (etaf-telega-gui--text))
                     (string-match-p "贴纸" (etaf-telega-gui--text)))))
             (etaf-telega-gui--action
              "compose-sticker-send"
              (lambda (_) (execute-kbd-macro (kbd "RET")))
              (lambda (_)
                (equal (car (etaf-telega-backend-fake-files etaf-telega-gui--backend))
                       '(:kind sticker :path 7))))
             (etaf-telega-gui--action
              "attach-file"
              (lambda (_)
                (setq etaf-telega-gui--attach
                      (make-temp-file "etaf-telega-attach" nil ".txt"))
                (with-temp-file etaf-telega-gui--attach (insert "attachment fixture"))
                (etaf-telega-send-file-as 'document etaf-telega-gui--attach))
              (lambda (_)
                (let ((status (or (plist-get (etaf-telega-gui--info) :status) "")))
                  (and (string-match-p "正在上传" status)
                       (string-match-p "45%" status)
                       (string-match-p "正在上传.*45%" (etaf-telega-gui--text)))))
              t)
             (etaf-telega-gui--action
              "confirm-attachment"
              (lambda (_)
                (etaf-telega-backend-fake-confirm-file etaf-telega-gui--backend
                                                       etaf-telega-gui--attach))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (equal (plist-get info :status) "就绪")
                       (equal (plist-get info :draft) "")
                       (string-match-p "etaf-telega-attach.*\\.txt"
                                       (etaf-telega-gui--text))))))
             (etaf-telega-gui--action
              "chat-search-server"
              (lambda (_)
                (etaf-telega-chat-search)
                (etaf-telega-gui--type "你好"))
              (lambda (_)
                (and (string-match-p "你好" (etaf-telega-gui--text))
                     (equal (plist-get (etaf-telega-gui--info) :chat-search) "你好")))
              t)
             (etaf-telega-gui--action
              "chat-search-jump"
              (lambda (_)
                (execute-kbd-macro (kbd "RET"))
                (execute-kbd-macro (kbd "p"))
                (execute-kbd-macro (kbd "RET")))
              (lambda (_)
                (and (null (plist-get (etaf-telega-gui--info) :chat-search))
                     (equal (plist-get (etaf-telega-gui--info) :selected) 11))))
             (etaf-telega-gui--action
              "search-server-chat"
              (lambda (_)
                (etaf-telega-search)
                (etaf-telega-gui--type "远端"))
              (lambda (_)
                (and (string-match-p "远端频道" (etaf-telega-gui--text))
                     (equal (plist-get (etaf-telega-gui--info) :search) "远端")))
              t)
             (etaf-telega-gui--action
              "open-server-chat"
              (lambda (_) (execute-kbd-macro (kbd "RET")))
              (lambda (_)
                (and (eq (plist-get (etaf-telega-gui--info) :screen) 'chat)
                     (equal (plist-get (etaf-telega-gui--info) :chat) 4)
                     (string-match-p "远端频道" (etaf-telega-gui--text)))))
             (etaf-telega-gui--action
              "chat-with-name"
              (lambda (_)
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (&rest _) "工作群")))
                  (call-interactively #'etaf-telega-chat-with)))
              (lambda (_)
                (let ((info (etaf-telega-gui--info)))
                  (and (eq (plist-get info :screen) 'chat)
                       (equal (plist-get info :chat) 2)
                       (string-match-p "工作群" (etaf-telega-gui--text))))))
             (etaf-telega-gui--action
              "chat-tab-walk" (lambda (_) (etaf-telega-gui--tab-walk))
              (lambda (_) (and (etaf-telega-gui--walk-closed-p 3)
                               (memq 'telega-composer etaf-telega-gui--walk)))
              t))
            (mapcar
             (lambda (size)
               (etaf-telega-gui--action
                (format "layout-%dx%d" (car size) (cadr size))
                (lambda (_) (set-frame-size frame (car size) (cadr size)))
                (lambda (_) (and (= (frame-width frame) (car size))
                                 (= (frame-height frame) (cadr size)))) t))
             '((120 40) (60 30) (200 50) (140 44))))
           :completion (lambda (_) (etaf-telega-gui--idle nil)))))
    (unwind-protect
        (etaf-gui-verifier-run scenario directory)
      (when (buffer-live-p etaf-telega-gui--buffer)
        (with-current-buffer etaf-telega-gui--buffer
          (let ((text (buffer-substring-no-properties (point-min) (point-max)))
                (info (etaf-telega-info)))
            (with-temp-file (expand-file-name "client.txt" directory)
              (insert (format "%S\n\n%s" info text))))
          (etaf-telega-close))))))
(provide 'etaf-telega-gui-scenarios)
;;; etaf-telega-gui-scenarios.el ends here
