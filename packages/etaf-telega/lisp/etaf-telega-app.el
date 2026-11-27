;;; etaf-telega-app.el --- Application shell of etaf-telega -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The client is one buffer that follows Telega's own workflow: a conversation
;; list screen and a chat screen showing one conversation's history above its
;; composer.  The buffer mounts one View over the model, so a backend report
;; updates whichever rows it touches and nothing else.
;;
;; Point is the selection, as in Telega: moving point onto a row selects its
;; conversation or message, and every message or chat command acts on the row
;; under point.  Commands Telega already implements (transient menus,
;; reactions, forwarding, chat operations) run natively through
;; `etaf-telega-backend-native' with the row's chat or message as their target.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-telega-model)
(require 'etaf-telega-backend)
(require 'etaf-telega-views)

(declare-function telega-msg-at "telega-msg" (&optional pos))
(declare-function telega-msg-open-content "telega-msg" (msg &optional clicked-p))
(declare-function telega-chat-create "telega-chat" (chat-type))
(declare-function telega-chat-join-by-link "telega-chat" (link))

(defcustom etaf-telega-buffer-name "*ETAF Telegram*"
  "Buffer name of the client.
Do not start it with \"*Telegram\": `telega-buffer-p' claims that prefix and
Telega's root-buffer cleanup kills every matching buffer."
  :type 'string
  :group 'etaf-telega)

(defvar etaf-telega-backend-create-function
  #'etaf-telega-backend-telega-create
  "Return a fresh backend for `etaf-telega-open'.
Tests bind this to a fake backend factory so no network is touched.")

(defvar etaf-telega--model nil
  "Model shared by the conversation list and the chat buffer.")

(defvar etaf-telega--backend nil
  "Backend feeding `etaf-telega--model'.")

(defvar etaf-telega--buffer nil
  "The mounted client buffer.")

(defvar etaf-telega--history-end nil
  "Non-nil when the open chat has no older history.")

(defvar etaf-telega--older-pending nil
  "Non-nil while an older history page is in flight.")

(defvar etaf-telega--history-retries 0
  "Empty answers accepted so far for the open chat's history.")

(defvar etaf-telega--jump-pending nil
  "Non-nil until the opened chat's first page moves point to the composer.")

(defvar etaf-telega--jump-target nil
  "Message id a jump is loading around, or nil.")

(defvar etaf-telega--input-history (make-hash-table :test #'equal)
  "Sent texts per conversation id, newest first, for M-p and M-n.")

(defvar etaf-telega--input-index nil
  "Position while browsing the open conversation's input history.")

(defvar etaf-telega--input-stash nil
  "Composer text kept while browsing the input history.")

(defvar etaf-telega--submitted-text nil
  "Composer text last handed to the backend.
A send acknowledgement carries the message as the server parsed it, and
Markdown loses its markup on the way, so the draft is compared against this
copy as well before it is cleared.")

(defconst etaf-telega--input-history-limit 50
  "Sent texts remembered per conversation for M-p and M-n.")

(defvar etaf-telega--upload-ref nil
  "Unused placeholder removed; uploads live on the model.")

(defconst etaf-telega--history-retry-limit 2
  "Empty history answers retried before the history counts as complete.
TDLib answers its first requests for a chat from the local database and may
return nothing until the server synchronized it.")

(defconst etaf-telega--history-retry-delay 0.8
  "Seconds before an empty history answer is asked again.")

;;;; Helpers

(defun etaf-telega--model ()
  "Return the live model or signal a user error."
  (or etaf-telega--model (user-error "Telegram 客户端没有打开")))

(defun etaf-telega--runtime (buffer)
  "Return BUFFER's mounted Runtime, or nil."
  (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))

(defun etaf-telega--window (buffer)
  "Return a window showing BUFFER, if any."
  (and (buffer-live-p buffer) (get-buffer-window buffer t)))

(defconst etaf-telega--status-limit 160
  "Longest status or error text kept in the header.
Backend or renderer failures can carry huge payloads (a Telega command with
message bodies); the header keeps only a readable prefix.")

(defun etaf-telega--clip-text (text)
  "Return TEXT shortened to one readable status line."
  (let ((text (or text "")))
    (if (<= (length text) etaf-telega--status-limit)
        text
      (concat (substring text 0 etaf-telega--status-limit) "…"))))

(defun etaf-telega--report-callback-failure (error)
  "Report ERROR from a backend callback without letting it escape.
These callbacks run inside Telega's command dispatch; an escaping failure
makes Telega print the entire failing command, including message bodies, to
the echo area and can hang Emacs.  The status line carries a clipped reason."
  (condition-case nil
      (etaf-telega-model-set-status
       etaf-telega--model
       (format "回调错误：%s" (etaf-telega--clip-text (error-message-string error))))
    (error nil)))

(defun etaf-telega--row-at (kind &optional buffer)
  "Return the id of the KIND row under point in BUFFER, or nil."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((runtime (etaf-telega--runtime buffer)))
      (with-current-buffer buffer
        (etaf-telega--ref-id
         kind (etaf-host-ref-at runtime (point)
                                (lambda (ref) (etaf-telega--ref-id kind ref))))))))

(defun etaf-telega--goto-ref (buffer ref)
  "Scroll REF into view and move point, and BUFFER's window point, to it."
  (when-let* ((runtime (etaf-telega--runtime buffer)))
    (ignore-errors (etaf-scroll-into-view runtime ref))
    (when-let* ((position (etaf-host-ref-position runtime ref)))
      (with-current-buffer buffer (goto-char position))
      (when-let* ((window (etaf-telega--window buffer)))
        (set-window-point window position))
      position)))

(defun etaf-telega--history-scroll (function &rest arguments)
  "Apply FUNCTION to the history Host and ARGUMENTS when the chat is shown."
  (when-let* ((runtime (etaf-telega--runtime etaf-telega--buffer))
              ((and etaf-telega--model
                    (eq (etaf-telega-model-screen etaf-telega--model) 'chat))))
    (ignore-errors (apply function runtime 'telega-history arguments))))

(defun etaf-telega--show-newest ()
  "Scroll the history to its newest message and keep following it."
  (etaf-telega--history-scroll #'etaf-scroll-to 'end))

;;;; Older history

(defun etaf-telega-load-more ()
  "Load one page of history older than the oldest loaded message."
  (interactive)
  (let* ((model (etaf-telega--model))
         (oldest (car (etaf-telega-model-messages model))))
    (when (and oldest (etaf-telega-model-chat model)
               (not etaf-telega--older-pending)
               (not etaf-telega--history-end))
      (setq etaf-telega--older-pending t)
      (etaf-telega-backend-history etaf-telega--backend
                                   :before (plist-get oldest :id)))))

(defun etaf-telega--fill-older ()
  "Load older history while the history's top line is shown."
  (when (and etaf-telega--model (not etaf-telega--jump-pending)
             (eql 0 (etaf-telega--history-scroll #'etaf-scroll-offset)))
    (with-current-buffer etaf-telega--buffer
      (etaf-telega-load-more))))

(defun etaf-telega--schedule-fill ()
  "Check, once the current update is painted, whether older history should load."
  (etaf-next-tick #'etaf-telega--fill-older))

(defun etaf-telega--history-scrolled (offset)
  "Load older history when the reader scrolls the history to OFFSET 0."
  (when (zerop offset)
    (etaf-telega--schedule-fill)))

(defun etaf-telega--retry (function &rest arguments)
  "Call FUNCTION with ARGUMENTS after the history retry delay.
The call is dropped when the client closed or the chat changed meanwhile."
  (let ((model etaf-telega--model)
        (chat (and etaf-telega--model (etaf-telega-model-chat etaf-telega--model))))
    (run-at-time etaf-telega--history-retry-delay nil
                 (lambda ()
                   (when (and model (eq model etaf-telega--model)
                              (equal (plist-get chat :id)
                                     (plist-get (etaf-telega-model-chat model) :id)))
                     (apply function arguments))))))

;;;; Backend callbacks

(defun etaf-telega--on-messages (messages)
  "Show MESSAGES, newest first, as the open chat's newest page."
  (let ((model etaf-telega--model))
    (etaf-telega-model-set-messages model (reverse messages))
    (cond
     ((and (null messages)
           (< etaf-telega--history-retries etaf-telega--history-retry-limit))
      (cl-incf etaf-telega--history-retries)
      (etaf-telega--retry #'etaf-telega-backend-select etaf-telega--backend
                          (plist-get (etaf-telega-model-chat model) :id)))
     (t
      (setq etaf-telega--history-end (null messages))
      (when etaf-telega--jump-pending
        (setq etaf-telega--jump-pending nil)
        (etaf-telega--show-newest)
        (etaf-telega--goto-ref etaf-telega--buffer 'telega-composer))
      (etaf-telega--schedule-fill)))))

(defun etaf-telega--keeping-view (function)
  "Call FUNCTION, which adds rows above the history, keeping the reader's row.
When the history was scrolled to its top, the previously oldest message
stays on the first line afterwards, like a chat app growing upwards; a
history following its newest message keeps following it."
  (let* ((oldest (car (etaf-telega-model-messages etaf-telega--model)))
         (anchor (and oldest (etaf-telega--ref 'message (plist-get oldest :id))))
         (runtime (etaf-telega--runtime etaf-telega--buffer))
         (top (eql 0 (etaf-telega--history-scroll #'etaf-scroll-offset))))
    (prog1 (funcall function)
      (when (and anchor top runtime)
        (etaf-next-tick
         (lambda ()
           (ignore-errors (etaf-scroll-into-view runtime anchor 'start))))))))

(defun etaf-telega--on-older (messages)
  "Prepend the older MESSAGES page, newest first."
  (setq etaf-telega--older-pending nil)
  (cond
   (messages
    (setq etaf-telega--history-retries 0)
    (etaf-telega--keeping-view
     (lambda ()
       (etaf-telega-model-prepend-messages etaf-telega--model (reverse messages))))
    (etaf-telega--schedule-fill))
   ((< etaf-telega--history-retries etaf-telega--history-retry-limit)
    (cl-incf etaf-telega--history-retries)
    (etaf-telega--retry #'etaf-telega-load-more))
   (t (setq etaf-telega--history-end t))))

(defun etaf-telega--on-jump (messages)
  "Merge the MESSAGES page loaded around a requested message and select it.
`etaf-telega--jump-target' names the message to select; the value t selects
the newest message of the reported page, which is what a date jump wants."
  (let* ((model etaf-telega--model)
         (target etaf-telega--jump-target)
         (id (if (eq target t)
                 (plist-get (car messages) :id)
               target)))
    (when messages
      (etaf-telega-model-prepend-messages model (reverse messages)))
    (when (or target messages)
      (setq etaf-telega--jump-target nil)
      (if (and id (etaf-telega-model-message-by-id model id))
          (progn
            (etaf-telega-model-set-selected model id)
            (etaf-telega--goto-ref etaf-telega--buffer
                                   (etaf-telega--ref 'message id)))
        (etaf-telega-model-set-status model "没有找到这条消息")))))

(defun etaf-telega--on-updated (message)
  "Replace MESSAGE's copy and refresh a viewer still showing its preview."
  (let ((model etaf-telega--model))
    (etaf-telega-model-replace-message model message)
    (let ((viewer (etaf-telega-model-viewer model)))
      (when (and viewer (equal (plist-get viewer :id) (plist-get message :id))
                 (not (plist-get viewer :full)))
        (etaf-telega--show-media message)))))

(defun etaf-telega--callbacks (model)
  "Return backend callbacks that update MODEL while it is the live model."
  (cl-labels ((report (function &rest arguments)
                (lambda (value)
                  (when (eq model etaf-telega--model)
                    (condition-case error
                        (apply function (append arguments (list value)))
                      ((error quit)
                       (etaf-telega--report-callback-failure error))))))
              (finish-compose (message)
                (when (or (equal (etaf-telega-model-draft model)
                                 (plist-get message :text))
                          (equal (etaf-telega-model-draft model)
                                 etaf-telega--submitted-text))
                  (etaf-telega-model-set-draft model ""))
                (setq etaf-telega--submitted-text nil)
                (etaf-telega--save-draft
                 (plist-get (etaf-telega-model-chat model) :id) "")
                (when (etaf-telega-model-upload model)
                  (etaf-telega-model-set-upload model nil)
                  (etaf-telega-model-set-status model "就绪"))
                (etaf-telega-model-set-compose model nil)))
    (list :status (report (lambda (status)
                            (etaf-telega-model-set-status
                             model (etaf-telega--clip-text status))))
          :me (report #'etaf-telega-model-set-me model)
          :chats (report #'etaf-telega-model-set-chats model)
          :messages (report #'etaf-telega--on-messages)
          :older (report #'etaf-telega--on-older)
          :sent (report (lambda (message)
                          (etaf-telega--remember-input
                           (plist-get (etaf-telega-model-chat model) :id)
                           (plist-get message :text))
                          (etaf-batch
                            (finish-compose message)
                            (etaf-telega-model-append-message model message))
                          (etaf-telega--show-newest)))
          :edited (report (lambda (message)
                            (etaf-batch
                              (finish-compose message)
                              (etaf-telega-model-replace-message model message))))
          :updated (report #'etaf-telega--on-updated)
          :jump (report #'etaf-telega--on-jump)
          :upload (report (lambda (event)
                            (etaf-telega--on-upload model event)))
          :deleted (report #'etaf-telega-model-remove-message model)
          :message (report #'etaf-telega-model-append-message model)
          :error (report (lambda (text)
                           (setq etaf-telega--older-pending nil)
                           ;; A failed send must not leave the composer
                           ;; reporting an upload that will never finish.
                           (when (etaf-telega-model-upload model)
                             (etaf-telega-model-set-upload model nil))
                           (etaf-telega-model-set-status
                            model (format "错误：%s"
                                          (etaf-telega--clip-text
                                           (replace-regexp-in-string
                                            "\\`telega error=[0-9]+: " ""
                                            (or text ""))))))))))

;;;; Point selection

(defun etaf-telega--follow-point-pane ()
  "Make the screen follow point into the other pane of a split layout.
Beside each other, the list and chat panes both stay visible, so the
screen only records which of them point, and so the keys, are in."
  (when-let* (((etaf-telega-model-chat etaf-telega--model))
              (screen (etaf-telega--pane-at-point)))
    (unless (eq screen (etaf-telega-model-screen etaf-telega--model))
      (etaf-telega--show-screen screen))))

(defun etaf-telega--track-point ()
  "Select the conversation or message under point in an application pane.
Temporary surfaces such as help do not replace the background selection."
  (when (and etaf-telega--model (etaf-telega--pane-at-point))
    (etaf-telega--follow-point-pane)
    (pcase (etaf-telega-model-screen etaf-telega--model)
      ('root
       (when-let* ((id (etaf-telega--row-at 'chat)))
         (unless (equal id (etaf-telega-model-cursor etaf-telega--model))
           (etaf-telega-model-set-cursor etaf-telega--model id))))
      ('chat
       (let ((id (etaf-telega--row-at 'message))
             (runtime (etaf-telega--runtime (current-buffer))))
         ;; Header controls and transient surfaces keep the selected message.
         ;; Only entering the composer explicitly clears that selection.
         (when (and (or id (etaf-host-ref-at
                            runtime nil (lambda (ref) (eq ref 'telega-composer))))
                    (not (equal id (etaf-telega-model-selected-id etaf-telega--model))))
           (etaf-telega-model-set-selected etaf-telega--model id)))))))

(defun etaf-telega--step (ids current delta)
  "Return the id DELTA steps from CURRENT in IDS, clamped to its ends.
A nil CURRENT steps from past the last id."
  (let* ((index (or (cl-position current ids :test #'equal) (length ids)))
         (next (+ index delta)))
    (and ids (nth (max 0 (min (1- (length ids)) next)) ids))))

(defun etaf-telega--visible-chat-ids ()
  "Return the ids of the conversations the list pane shows."
  (mapcar (lambda (chat) (plist-get chat :id))
          (etaf-telega--list-chats (etaf-telega--model))))

(defun etaf-telega--move-chat (delta)
  "Move point DELTA conversations in the list."
  (let* ((model (etaf-telega--model))
         (ids (etaf-telega--visible-chat-ids))
         (current (or (etaf-telega--row-at 'chat) (etaf-telega-model-cursor model)))
         (target (if (member current ids)
                     (etaf-telega--step ids current delta)
                   (car ids))))
    (when target
      (etaf-telega-model-set-cursor model target)
      (etaf-telega--focus-ref (current-buffer) (etaf-telega--ref 'chat target)))))

(defun etaf-telega-next-chat ()
  "Move to the next conversation."
  (interactive)
  (etaf-telega--move-chat 1))

(defun etaf-telega-previous-chat ()
  "Move to the previous conversation."
  (interactive)
  (etaf-telega--move-chat -1))

(defun etaf-telega-next-unread-chat ()
  "Move to the next conversation with unread messages (M-g u on the list)."
  (interactive)
  (let* ((model (etaf-telega--model))
         (chats (etaf-telega--list-chats model))
         (ids (mapcar (lambda (chat) (plist-get chat :id)) chats))
         (current (or (etaf-telega--row-at 'chat) (etaf-telega-model-cursor model)))
         (start (or (cl-position current ids :test #'equal) -1))
         (target (cl-loop for offset from 1 to (length ids)
                          for id = (nth (mod (+ start offset) (length ids)) ids)
                          for chat = (cl-find id chats
                                              :key (lambda (item)
                                                     (plist-get item :id))
                                              :test #'equal)
                          when (and chat
                                    (or (> (or (plist-get chat :unread) 0) 0)
                                        (> (or (plist-get chat :mention) 0) 0)))
                          return id)))
    (unless target (user-error "没有未读会话"))
    (etaf-telega-model-set-cursor model target)
    (etaf-telega--focus-ref (current-buffer) (etaf-telega--ref 'chat target))))

(defun etaf-telega--move-message (delta)
  "Move point DELTA messages; past the newest message lands on the composer.
While the message search is open the movement walks its results."
  (let* ((model (etaf-telega--model))
         (ids (mapcar (lambda (message) (plist-get message :id))
                      (if (etaf-telega-model-chat-search model)
                          (etaf-telega--chat-search-results model)
                        (etaf-telega-model-messages model))))
         (current (etaf-telega--row-at 'message))
         (index (or (cl-position current ids :test #'equal) (length ids)))
         (next (+ index delta)))
    (cond
     ((null ids))
     ((>= next (length ids))
      (etaf-telega-model-set-selected model nil)
      (etaf-telega--focus-ref (current-buffer) 'telega-composer))
     (t
      (let ((target (nth (max 0 next) ids)))
        (when (and (< next 0) (not (etaf-telega-model-chat-search model)))
          (etaf-telega-load-more))
        (etaf-telega-model-set-selected model target)
        (etaf-telega--focus-ref (current-buffer)
                                (etaf-telega--ref 'message target)))))))

(defun etaf-telega-show-message (id)
  "Select the open chat's message ID, loading its page when not loaded."
  (interactive (list (or (etaf-telega--row-at 'message)
                         (user-error "先把光标移到一条消息上"))))
  (let ((model (etaf-telega--model)))
    (unless (etaf-telega-model-chat model)
      (user-error "先打开一个对话"))
    (etaf-telega--show-screen 'chat)
    (if (etaf-telega-model-message-by-id model id)
        (progn
          (etaf-telega-model-set-selected model id)
          (etaf-telega--focus-ref etaf-telega--buffer
                                  (etaf-telega--ref 'message id)))
      (setq etaf-telega--jump-target id)
      (etaf-telega-backend-around etaf-telega--backend id))))

(defun etaf-telega-jump-quote ()
  "Jump to the message quoted by the message under point (M-g q)."
  (interactive)
  (let* ((message (etaf-telega--message-at-point))
         (id (plist-get (plist-get message :reply) :id)))
    (unless id (user-error "这条消息没有引用"))
    (etaf-telega-show-message id)))

(defun etaf-telega-jump-pinned ()
  "Jump to the open conversation's pinned message (M-g p).
The conversation list's pinned id is only as fresh as the last load, so the
message is looked up through the backend before reporting that nothing is
pinned."
  (interactive)
  (let* ((model (etaf-telega--model))
         (chat (etaf-telega-model-chat model)))
    (unless chat (user-error "先打开一个对话"))
    (etaf-telega-model-set-status model "正在查找置顶消息…")
    (etaf-telega-backend-pinned-message
     etaf-telega--backend (plist-get chat :id)
     (lambda (id)
       (when (eq model etaf-telega--model)
         (condition-case error
             (etaf-batch
               (etaf-telega-model-set-status model "就绪")
               (if id
                   (etaf-telega-show-message id)
                 (message "这个对话没有置顶消息")))
           ((error quit)
            (etaf-telega--report-callback-failure error))))))))

(defun etaf-telega-jump-date (date)
  "Jump to the message nearest before DATE, a timestamp (M-g d).
Interactively read a date like 2026-10-05 or 2026-10-05 14:30."
  (interactive (list (etaf-telega--read-date)))
  (let ((model (etaf-telega--model)))
    (unless (etaf-telega-model-chat model)
      (user-error "先打开一个对话"))
    (setq etaf-telega--jump-target t)
    (etaf-telega-backend-date-message etaf-telega--backend date)))

(defun etaf-telega--read-date ()
  "Read a timestamp the client can jump to."
  (float-time
   (date-to-time
    (read-string "跳到日期（YYYY-MM-DD [HH:MM]）："
                 (format-time-string "%Y-%m-%d")))))

(defun etaf-telega--select-next-message (candidates)
  "Select the first CANDIDATE newer than the selected message.
With no newer candidate, select the oldest one, so repeated presses cycle."
  (let* ((model (etaf-telega--model))
         (current (etaf-telega-model-selected-id model))
         (target (or (cl-find-if (lambda (message)
                                   (> (or (plist-get message :id) 0)
                                      (or current 0)))
                                 candidates)
                     (car candidates))))
    (etaf-telega-show-message (plist-get target :id))))

(defun etaf-telega-next-unread-message ()
  "Select the next unread message in the open conversation (M-g u)."
  (interactive)
  (let* ((model (etaf-telega--model))
         (chat (etaf-telega-model-chat model))
         (last-read (or (and chat (plist-get chat :last-read)) 0))
         (candidates (cl-remove-if-not
                      (lambda (message)
                        (and (> (or (plist-get message :id) 0) last-read)
                             (not (plist-get message :outgoing))))
                      (etaf-telega-model-messages model))))
    (unless candidates (user-error "没有未读消息"))
    (etaf-telega--select-next-message candidates)))

(defun etaf-telega-next-mention ()
  "Select the next loaded message that mentions the account (M-g m)."
  (interactive)
  (let* ((model (etaf-telega--model))
         (username (plist-get (etaf-telega-model-me model) :username))
         (candidates
          (and (stringp username) (not (string-empty-p username))
               (let ((case-fold-search t)
                     (needle (regexp-quote (concat "@" username))))
                 (cl-remove-if-not
                  (lambda (message)
                    (string-match-p needle (or (plist-get message :text) "")))
                  (etaf-telega-model-messages model))))))
    (unless candidates (user-error "没有提及"))
    (etaf-telega--select-next-message candidates)))

(defun etaf-telega-next-outgoing ()
  "Select the next message sent by the account (M-g o)."
  (interactive)
  (let* ((model (etaf-telega--model))
         (candidates (cl-remove-if-not (lambda (message)
                                         (plist-get message :outgoing))
                                       (etaf-telega-model-messages model))))
    (unless candidates (user-error "没有自己发送的消息"))
    (etaf-telega--select-next-message candidates)))

(defun etaf-telega-next-message ()
  "Move to the next message, or to the composer after the newest one."
  (interactive)
  (etaf-telega--move-message 1))

(defun etaf-telega-previous-message ()
  "Move to the previous message, loading older history at the top."
  (interactive)
  (etaf-telega--move-message -1))

;;;; Keys

(defvar etaf-telega-root-native-keys
  '(("i" . telega-describe-chat) ("h" . telega-describe-chat)
    ("a" . telega-chat-add-member) ("o" . telega-transient-chat-operate)
    ("r" . telega-chat-toggle-read) ("d" . telega-transient-chat-delete)
    ("P" . telega-chat-toggle-pin) ("^" . telega-chat-toggle-pin)
    ("M" . telega-chat-toggle-muted) ("A" . telega-chat-toggle-archive)
    ("L" . telega-chat-leave)
    ("DEL" . telega-chat-delete))
  "Keys of the conversation list that run Telega's own chat commands.
Each command operates on the conversation under point.")

(defvar etaf-telega-chat-native-keys
  '(("c" . telega-msg-copy-dwim) ("d" . telega-transient-msg-delete)
    ("DEL" . telega-transient-msg-delete) ("f" . telega-transient-msg-forward)
    ("l" . telega-msg-copy-link) ("s" . telega-transient-msg-save)
    ("t" . telega-transient-msg-translate) ("!" . telega-msg-add-reaction)
    ("^" . telega-transient-msg-pin-toggle) ("*" . telega-msg-favorite-toggle)
    ("T" . telega-msg-open-thread-or-topic) ("=" . telega-msg-diff-edits)
    ("B" . telega-msg-ban-sender) ("R" . telega-msg-resend)
    ("o" . telega-transient-msg-operate) ("I" . telega-describe-message))
  "Keys of the chat buffer that run Telega's own message commands.
Each command operates on the message under point.")

(defun etaf-telega--telega-command (command)
  "Return a command calling Telega's COMMAND, which loads with Telega."
  (lambda () (interactive) (call-interactively command)))

(defconst etaf-telega--native-labels
  '((telega-describe-chat . "会话资料")
    (telega-chat-add-member . "添加会话成员")
    (telega-transient-chat-operate . "会话操作")
    (telega-chat-toggle-read . "切换会话已读状态")
    (telega-transient-chat-delete . "删除会话选项")
    (telega-chat-toggle-pin . "置顶／取消置顶会话")
    (telega-chat-toggle-muted . "静音／取消静音会话")
    (telega-chat-toggle-archive . "归档／取消归档会话")
    (telega-chat-leave . "离开会话")
    (telega-chat-delete . "删除会话")
    (telega-msg-copy-dwim . "复制消息")
    (telega-transient-msg-delete . "删除消息")
    (telega-transient-msg-forward . "转发消息")
    (telega-msg-copy-link . "复制消息链接")
    (telega-transient-msg-save . "保存消息")
    (telega-transient-msg-translate . "翻译消息")
    (telega-msg-add-reaction . "添加表情回应")
    (telega-transient-msg-pin-toggle . "置顶／取消置顶消息")
    (telega-msg-favorite-toggle . "收藏／取消收藏消息")
    (telega-msg-open-thread-or-topic . "打开消息话题")
    (telega-msg-diff-edits . "查看编辑记录")
    (telega-msg-ban-sender . "封禁发送者")
    (telega-msg-resend . "重新发送消息")
    (telega-transient-msg-operate . "消息操作")
    (telega-describe-message . "消息详情"))
  "Short names of the supported Telega commands, independent of key choices.")

(defun etaf-telega--native-keys (keys)
  "Return `:keys' entries running each Telega command of KEYS at point."
  (mapcar (lambda (entry)
            (let ((command (cdr entry)))
              (list (car entry)
                    (lambda () (interactive) (etaf-telega-native command))
                    (or (alist-get command etaf-telega--native-labels)
                        (format "Telega：%s" command)))))
          keys))

(defun etaf-telega--client-keys ()
  "Return the keys every screen of the client answers to."
  `(("j" ,#'etaf-telega-chat-with "按名字打开会话")
    ;; A failed send can leave an upload pending; keep its cancel
    ;; reachable from every pane of a split layout.
    ("C-c C-u" ,#'etaf-telega-cancel-upload "取消正在上传的文件")
    ("Q" ,#'etaf-telega-close "关闭客户端")))

(defun etaf-telega--list-keys ()
  "Return the conversation list pane's keys, after Telega's root buffer."
  (append
   (etaf-telega--native-keys etaf-telega-root-native-keys)
   `(("n" ,#'etaf-telega-next-chat "下一个会话")
     ("p" ,#'etaf-telega-previous-chat "上一个会话")
     ("RET" ,#'etaf-telega-open-chat "打开会话")
     ("[" ,#'etaf-telega-previous-filter "上一个分组")
     ("]" ,#'etaf-telega-next-filter "下一个分组")
     ("/" ,#'etaf-telega-search "搜索会话")
     ("s" ,#'etaf-telega-search "搜索会话")
     ("C-c g u" ,#'etaf-telega-next-unread-chat "下一个未读会话")
     ("J" ,(etaf-telega--telega-command 'telega-chat-join-by-link) "通过链接加入")
     ("N" ,(etaf-telega--telega-command 'telega-chat-create) "新建会话")
     ("+" ,(etaf-telega--telega-command 'telega-chat-create) "新建会话")
     ("T" ,#'etaf-telega-toggle-theme "切换主题")
     ("q" ,#'bury-buffer "隐藏客户端"))))

(defun etaf-telega--chat-keys ()
  "Return the chat pane's keys, after Telega's chat buffer."
  (append
   (etaf-telega--native-keys etaf-telega-chat-native-keys)
   `(("n" ,#'etaf-telega-next-message "下一条消息")
     ("p" ,#'etaf-telega-previous-message "上一条消息")
     ("RET" ,#'etaf-telega-activate "打开媒体或开始输入")
     ("i" ,#'etaf-telega-compose "输入消息")
     (">" ,#'etaf-telega-jump-newest "跳到最新消息")
     ("M->" ,#'etaf-telega-jump-newest "跳到最新消息")
     ("M-<" ,#'etaf-telega-load-more "加载更早的历史")
     ("C-c g q" ,#'etaf-telega-jump-quote "跳到被引用的消息")
     ("C-c g p" ,#'etaf-telega-jump-pinned "跳到置顶消息")
     ("C-c g d" ,#'etaf-telega-jump-date "跳到指定日期")
     ("C-c g u" ,#'etaf-telega-next-unread-message "下一条未读消息")
     ("C-c g m" ,#'etaf-telega-next-mention "下一条提及我的消息")
     ("C-c g @" ,#'etaf-telega-next-mention "下一条提及我的消息")
     ("C-c g o" ,#'etaf-telega-next-outgoing "下一条我发送的消息")
     ("+" ,#'etaf-telega-react "表情回应")
     ("r" ,#'etaf-telega-reply "回复")
     ("e" ,#'etaf-telega-edit "编辑")
     ("C-c C-k" ,#'etaf-telega-cancel-compose "取消回复或编辑")
     ("g" ,#'etaf-telega-reload-chat "重新载入最新历史")
     ("/" ,#'etaf-telega-chat-search "搜索消息")
     ("C-c i" ,#'etaf-telega-toggle-details "显示或隐藏对话信息")
     ("C-c C-s" ,#'etaf-telega-toggle-silent "静默发送")
     ("C-c C-l" ,#'etaf-telega-toggle-link-preview "不带链接预览")
     ("C-c C-m" ,#'etaf-telega-toggle-markdown "按 Markdown 解析")
     ("C-c C-t" ,#'etaf-telega-schedule-send "定时发送")
     ("C-c C-d" ,#'etaf-telega-clear-draft "放弃草稿")
     ("C-c C-a" ,#'etaf-telega-attach "发送文件")
     ("C-c C-e" ,#'etaf-telega-open-emoji "表情选择器")
     ("C-c C-p" ,#'etaf-telega-open-stickers "贴纸选择器")
     ("q" ,#'etaf-telega-back "返回会话列表"))))

(defun etaf-telega--details-keys ()
  "Return the details pane's keys."
  `(("C-c i" ,#'etaf-telega-toggle-details "隐藏对话信息")
    ("q" ,#'etaf-telega-back "返回会话列表")))

(defconst etaf-telega--screen-panes
  '((root . telega-list-pane) (chat . telega-chat-pane))
  "The pane whose keys answer on each screen.")

(defun etaf-telega--pane-at-point ()
  "Return the screen whose pane holds point, or nil."
  (when-let* ((runtime (etaf-telega--runtime (current-buffer)))
              (pane (etaf-host-ref-at runtime (point)
                                      (lambda (ref)
                                        (rassq ref etaf-telega--screen-panes)))))
    (car (rassq pane etaf-telega--screen-panes))))

(defun etaf-telega--focus-ref (buffer ref)
  "Move point and keyboard focus to REF, so Tab continues from it."
  (when (etaf-telega--goto-ref buffer ref)
    (etaf-focus (etaf-telega--runtime buffer) ref)
    t))

(defun etaf-telega--enter-pane (screen)
  "Move point to SCREEN's entry: the list's conversation or the composer.
Keys answer in the pane holding point, so a screen switch moves point and
focus there too."
  (when (buffer-live-p etaf-telega--buffer)
    (with-current-buffer etaf-telega--buffer
      (let ((cursor (and etaf-telega--model
                         (etaf-telega-model-cursor etaf-telega--model))))
        (or (if (eq screen 'chat)
                (etaf-telega--focus-ref etaf-telega--buffer 'telega-composer)
              (and cursor
                   (etaf-telega--focus-ref etaf-telega--buffer
                                           (etaf-telega--ref 'chat cursor))))
            (etaf-telega--goto-ref etaf-telega--buffer
                                   (cdr (assq screen etaf-telega--screen-panes))))))))

(defun etaf-telega--show-screen (screen)
  "Show SCREEN, `root' or `chat', with point in its pane once painted.
Point already in SCREEN's pane of a split layout stays where it is."
  (let ((entered (eq (etaf-telega--pane-at-point) screen)))
    (etaf-telega-model-set-screen (etaf-telega--model) screen)
    (unless entered
      (etaf-next-tick (lambda () (etaf-telega--enter-pane screen))))))

(defun etaf-telega-open-chat (id)
  "Open the conversation with ID on the chat screen."
  (interactive (list (or (etaf-telega--row-at 'chat)
                         (and etaf-telega--model
                              (etaf-telega-model-cursor etaf-telega--model))
                         (user-error "先把光标移到一个对话上"))))
  (let* ((model (etaf-telega--model))
         (chat (or (etaf-telega-model-chat-by-id model id)
                   (cl-find id (etaf-telega-model-search-results model)
                            :key (lambda (item) (plist-get item :id))
                            :test #'equal)
                   (user-error "没有这个对话：%s" id)))
         (previous (etaf-telega-model-chat model))
         (searching (etaf-telega-model-searching model)))
    (when (etaf-text-input-active-p (etaf-telega--runtime etaf-telega--buffer))
      (etaf-text-input-end t))
    (setq etaf-telega--history-end nil
          etaf-telega--older-pending nil
          etaf-telega--history-retries 0
          etaf-telega--jump-pending t
          etaf-telega--jump-target nil)
    (etaf-telega--reset-input-history)
    (etaf-batch
      (when searching
        (etaf-telega-model-add-recent model id)
        (etaf-telega-model-set-search model nil))
      (etaf-telega-model-set-popover model nil)
      (unless (equal (plist-get previous :id) id)
        (etaf-telega-model-set-chat-search model nil)
        (etaf-telega--save-draft (plist-get previous :id)
                                 (etaf-telega-model-draft model))
        (etaf-telega-model-set-draft model (or (plist-get chat :draft) "")))
      (etaf-telega-model-select model chat)
      (etaf-telega-model-set-cursor model id)
      (etaf-telega--show-screen 'chat))
    (etaf-telega-backend-select etaf-telega--backend id)
    id))

(defun etaf-telega--await-chat (id)
  "Wait briefly for the backend to list conversation ID."
  (let ((deadline (+ (float-time) 2)))
    (while (and (not (etaf-telega-model-chat-by-id (etaf-telega--model) id))
                (< (float-time) deadline))
      (sit-for 0.05))))

(defun etaf-telega-chat-with (id)
  "Open conversation ID, chosen by name when called interactively.
The backend offers its known conversations and contacts.  A contact whose
private chat is not loaded yet is created and opened once the refreshed
list carries it."
  (interactive
   (let* ((candidates (etaf-telega-backend-chat-candidates etaf-telega--backend))
          (counts (let ((table (make-hash-table :test #'equal)))
                    (dolist (item candidates)
                      (let ((name (etaf-telega--plain-text (or (plist-get item :title) "?"))))
                        (puthash name (1+ (gethash name table 0)) table)))
                    table))
          (names (mapcar (lambda (item)
                           (let ((name (etaf-telega--plain-text
                                        (or (plist-get item :title) "?"))))
                             (if (> (gethash name counts) 1)
                                 (format "%s (%s)" name
                                         (pcase (plist-get item :kind)
                                           ('group "群组") ('channel "频道")
                                           (_ "私聊")))
                               name)))
                         candidates)))
     (unless names (user-error "没有可用的会话"))
     ;; A plain string list keeps the command usable in completion setups that
     ;; choke on an alist collection.
     (let ((choice (completing-read "会话：" names nil t)))
       (list (plist-get (nth (cl-position choice names :test #'equal)
                             candidates)
                        :id)))))
  (unless (etaf-telega-model-chat-by-id (etaf-telega--model) id)
    (etaf-telega-backend-ensure-chat etaf-telega--backend id)
    (etaf-telega--await-chat id))
  (etaf-telega-open-chat id))

;;;; Search

(defun etaf-telega--end-editing ()
  "Leave the active text input, keeping its text."
  (when (etaf-text-input-active-p (etaf-telega--runtime etaf-telega--buffer))
    (etaf-text-input-end 'blur)))

(defun etaf-telega-search ()
  "Show the list search and begin typing its query (/ or s on the list).
On a compact chat screen the client first returns to the list."
  (interactive)
  (let ((model (etaf-telega--model))
        (runtime (etaf-telega--runtime etaf-telega--buffer)))
    (unless (etaf-host-ref-position runtime 'telega-list-pane)
      (etaf-telega-back))
    (etaf-telega-model-set-search model t (etaf-telega-model-search model))
    (with-current-buffer etaf-telega--buffer
      (etaf-text-input-begin runtime 'telega-search))))

(defun etaf-telega-search-exit ()
  "Leave the list search, clearing its query, and show the list again."
  (interactive)
  (etaf-telega--end-editing)
  (etaf-telega-model-set-search (etaf-telega--model) nil)
  (etaf-telega-model-set-search-results (etaf-telega--model) nil))

(defun etaf-telega--search-focused ()
  "Show the list search when its field begins editing."
  (let ((model (etaf-telega--model)))
    (unless (etaf-telega-model-searching model)
      (etaf-telega-model-set-search model t (etaf-telega-model-search model)))))

(defun etaf-telega--search-changed (query)
  "Track QUERY and ask the backend for conversations matching it.
The local substring filter already shows loaded matches; the backend search
fills in conversations the list has not loaded.  A stale answer, one whose
query is no longer current, is dropped."
  (when etaf-telega--model
    (let ((model etaf-telega--model))
      (etaf-batch
        (etaf-telega-model-set-search model t query)
        (etaf-telega-model-set-search-results model nil))
      (unless (string-empty-p (string-trim query))
        (let ((token query))
          (etaf-telega-backend-search-chats
           etaf-telega--backend query
           (lambda (chats)
             (when (and (eq model etaf-telega--model)
                        (equal token (etaf-telega-model-search model)))
               (etaf-telega-model-set-search-results model chats)))))))))

(defun etaf-telega--search-submit (_query)
  "Open the first conversation the list search shows."
  (if-let* ((id (car (etaf-telega--visible-chat-ids))))
      (etaf-telega-open-chat id)
    (message "没有匹配的对话")))

(defun etaf-telega--search-cancelled (_query)
  "Leave the list search after its field was cancelled."
  (etaf-telega-model-set-search (etaf-telega--model) nil)
  (etaf-telega-model-set-search-results (etaf-telega--model) nil))

(defun etaf-telega--search-kind-select (kind)
  "Narrow the list search to conversations of KIND."
  (etaf-telega-model-set-search-kind (etaf-telega--model) kind))

(defun etaf-telega-search-clear-recent ()
  "Forget the recently opened search results."
  (interactive)
  (etaf-telega-model-clear-recent (etaf-telega--model)))

(defun etaf-telega-chat-search ()
  "Search the open conversation's loaded messages, typing the query (/)."
  (interactive)
  (let ((model (etaf-telega--model)))
    (unless (etaf-telega-model-chat model)
      (user-error "先打开一个对话"))
    (unless (etaf-telega-model-chat-search model)
      (etaf-telega-model-set-chat-search model ""))
    (with-current-buffer etaf-telega--buffer
      (etaf-text-input-begin (etaf-telega--runtime etaf-telega--buffer)
                             'telega-chat-search))))

(defun etaf-telega-chat-search-exit ()
  "Close the message search and show the whole history again."
  (interactive)
  (etaf-telega--end-editing)
  (etaf-telega-model-set-chat-search (etaf-telega--model) nil)
  (etaf-telega-model-set-chat-search-results (etaf-telega--model) nil))

(defun etaf-telega--chat-search-cancelled (_query)
  "Close the message search after its field was cancelled."
  (etaf-telega-model-set-chat-search (etaf-telega--model) nil)
  (etaf-telega-model-set-chat-search-results (etaf-telega--model) nil))

(defun etaf-telega--chat-search-changed (query)
  "Track the message search QUERY and ask the backend for matches.
Local matches over the loaded history show at once; the backend fills in
messages the client has not loaded.  A stale answer is dropped."
  (when etaf-telega--model
    (let ((model etaf-telega--model))
      (etaf-batch
        (etaf-telega-model-set-chat-search model query)
        (etaf-telega-model-set-chat-search-results model nil))
      (unless (string-empty-p (string-trim query))
        (let ((token query))
          (etaf-telega-backend-search-messages
           etaf-telega--backend query
           (lambda (messages)
             (when (and (eq model etaf-telega--model)
                        (equal token (etaf-telega-model-chat-search model)))
               (etaf-telega-model-set-chat-search-results model messages)))))))))

(defun etaf-telega-toggle-details ()
  "Show or hide the open conversation's details pane (C-c i)."
  (interactive)
  (let ((model (etaf-telega--model)))
    (unless (etaf-telega-model-chat model)
      (user-error "先打开一个对话"))
    (etaf-telega-model-set-details model (not (etaf-telega-model-details model)))))

(defun etaf-telega--show-help ()
  "Show read-only help after the current menu has closed and restored focus."
  (when-let* ((runtime (etaf-telega--runtime etaf-telega--buffer)))
    (etaf-next-tick
     (lambda ()
       (when (etaf-runtime-mounted-p runtime)
         (etaf-help runtime))))))

(defun etaf-telega--list-menu-select (key)
  "Run the list menu item KEY.
Commands that remount or close the client run after the menu's own event."
  (pcase key
    ('create (call-interactively #'telega-chat-create))
    ('join (call-interactively #'telega-chat-join-by-link))
    ('help (etaf-telega--show-help))
    ('theme (run-at-time 0 nil #'etaf-telega-toggle-theme))
    ('close (run-at-time 0 nil #'etaf-telega-close))))

(defun etaf-telega--chat-menu-select (key)
  "Run the chat menu item KEY."
  (pcase key
    ('details (etaf-telega-toggle-details))
    ('search (etaf-telega-chat-search))
    ('newest (etaf-telega-jump-newest))
    ('reload (etaf-telega-reload-chat))
    ('help (etaf-telega--show-help))
    ('back (etaf-telega-back))))

;;;; Filters

(defun etaf-telega-select-filter (key)
  "Show the conversations of filter KEY."
  (interactive
   (list (intern (completing-read "分组："
                                  (mapcar (lambda (entry) (symbol-name (car entry)))
                                          etaf-telega-filters)
                                  nil t))))
  (etaf-telega-model-set-filter (etaf-telega--model) key))

(defun etaf-telega--step-filter (delta)
  "Show the filter DELTA tabs away, staying at the strip's ends."
  (let* ((keys (mapcar #'car etaf-telega-filters))
         (index (or (cl-position (etaf-telega-model-filter (etaf-telega--model))
                                 keys)
                    0))
         (next (+ index delta)))
    (when (< -1 next (length keys))
      (etaf-telega-select-filter (nth next keys)))))

(defun etaf-telega-next-filter ()
  "Show the next conversation filter (] on the list); the ends hold."
  (interactive)
  (etaf-telega--step-filter 1))

(defun etaf-telega-previous-filter ()
  "Show the previous conversation filter ([ on the list); the ends hold."
  (interactive)
  (etaf-telega--step-filter -1))

(defun etaf-telega-native (command)
  "Run Telega's COMMAND on the conversation or message under point.
On the chat screen COMMAND receives the message under point, on the list
the conversation under point.  The keys of `etaf-telega-root-native-keys'
and `etaf-telega-chat-native-keys' call it with their command."
  (interactive
   (let ((keys (if (eq (etaf-telega-model-screen (etaf-telega--model)) 'chat)
                   etaf-telega-chat-native-keys
                 etaf-telega-root-native-keys)))
     (list (intern (completing-read "Telega 命令："
                                    (delete-dups
                                     (mapcar (lambda (entry) (symbol-name (cdr entry)))
                                             keys))
                                    nil t)))))
  (let ((model (etaf-telega--model)))
    (if (eq (etaf-telega-model-screen model) 'chat)
        (let ((id (or (etaf-telega--row-at 'message)
                      (user-error "先把光标移到一条消息上"))))
          (etaf-telega-backend-native etaf-telega--backend command
                                      (plist-get (etaf-telega-model-chat model) :id)
                                      id))
      (etaf-telega-backend-native etaf-telega--backend command
                                  (or (etaf-telega--row-at 'chat)
                                      (etaf-telega-model-cursor model)
                                      (user-error "先把光标移到一个对话上"))))))

;;;; Chat buffer commands

(defun etaf-telega--open-content ()
  "Open the content of Telega's message at point like clicking it."
  (telega-msg-open-content (telega-msg-at (point)) t))

(defconst etaf-telega--viewable-kinds '(photo video animation sticker voice audio)
  "Message kinds the in-buffer media viewer shows.")

(defun etaf-telega--media-ids ()
  "Return the ids of the open chat's viewable messages, oldest first."
  (cl-loop for message in (etaf-telega-model-messages (etaf-telega--model))
           when (and (memq (plist-get message :kind) etaf-telega--viewable-kinds)
                     (or (plist-get message :media)
                         (memq (plist-get message :kind) '(voice audio))))
           collect (plist-get message :id)))

(defun etaf-telega--show-media (message &optional source progress)
  "Show MESSAGE's media in the viewer, playing SOURCE once it is local.
Until the full file arrives the viewer shows the message's preview image
and the download PROGRESS, a fraction, when known."
  (let* ((model (etaf-telega--model))
         (id (plist-get message :id))
         (media (plist-get message :media))
         (video (memq (plist-get message :kind) '(video animation)))
         (audio (memq (plist-get message :kind) '(voice audio)))
         (ids (etaf-telega--media-ids))
         (index (cl-position id ids :test #'equal)))
    (etaf-telega-model-set-viewer
     model
     (list :id id
           :kind (cond ((and video source) 'video)
                       (audio 'audio)
                       (t 'image))
           :src (or source (plist-get media :src))
           :full (and source t)
           :duration (plist-get message :duration)
           :size (and (plist-get media :width) (plist-get media :height)
                      (cons (plist-get media :width) (plist-get media :height)))
           :title (etaf-telega--plain-text (or (plist-get message :sender) ""))
           :subtitle (concat (string-trim
                              (concat (or (plist-get message :date) "") " "
                                      (or (plist-get message :time) "")))
                             (if (and (not source) progress)
                                 (format " · 正在下载 %d%%" (round (* 100 progress)))
                               ""))
           :caption (let ((text (plist-get message :text)))
                      (and text (not (string-empty-p text)) text))
           :previous (and index (> index 0))
           :next (and index (< index (1- (length ids))))))))

(defun etaf-telega-open-media (id)
  "Preview message ID's photo, play its video or audio in the viewer.
Voice notes and audio files play in the same in-buffer viewer; other
attachments, such as files and stickers, open through Telega."
  (interactive (list (or (etaf-telega--row-at 'message)
                         (user-error "先把光标移到一条消息上"))))
  (let* ((model (etaf-telega--model))
         (message (or (etaf-telega-model-message-by-id model id)
                      (user-error "没有这条消息：%s" id))))
    (if (and (memq (plist-get message :kind) etaf-telega--viewable-kinds)
             (or (plist-get message :media)
                 (memq (plist-get message :kind) '(voice audio))))
        (progn
          (etaf-telega-model-set-selected model id)
          (etaf-telega--show-media message)
          (etaf-telega-backend-media
           etaf-telega--backend id
           (lambda (progress source)
             (when-let* ((model etaf-telega--model)
                         ((equal (plist-get (etaf-telega-model-viewer model) :id) id))
                         (current (etaf-telega-model-message-by-id model id)))
               (etaf-telega--show-media current source progress)))))
      (etaf-telega-backend-native etaf-telega--backend #'etaf-telega--open-content
                                  (plist-get (etaf-telega-model-chat model) :id)
                                  id))))

(defun etaf-telega--viewer-step (delta)
  "Show the viewable message DELTA steps from the viewer's message."
  (when-let* ((viewer (etaf-telega-model-viewer (etaf-telega--model)))
              (ids (etaf-telega--media-ids))
              (index (cl-position (plist-get viewer :id) ids :test #'equal))
              ((< -1 (+ index delta) (length ids))))
    (etaf-telega-open-media (nth (+ index delta) ids))))

(defun etaf-telega-close-media ()
  "Close the media viewer and return to the message it showed."
  (interactive)
  (let* ((model (etaf-telega--model))
         (id (plist-get (etaf-telega-model-viewer model) :id)))
    (etaf-telega-model-set-viewer model nil)
    (when id
      (etaf-telega--goto-ref etaf-telega--buffer (etaf-telega--ref 'message id)))))

(defun etaf-telega-react (id key)
  "Toggle reaction KEY on message ID.
KEY is an emoji string, or `custom:<id>' naming a custom emoji by its TDLib
id; reactions of the message under point toggle by clicking them too.
Interactively, pick an emoji reaction for the message under point."
  (interactive
   (let ((id (or (etaf-telega--row-at 'message)
                 (user-error "先把光标移到一条消息上"))))
     (list id (completing-read "表情：" (mapcar #'car etaf-telega-reaction-choices)
                               nil t))))
  (etaf-telega--model)
  (etaf-telega-backend-react etaf-telega--backend id key))

(defun etaf-telega-swipe (direction)
  "Handle a two-finger swipe in DIRECTION, `left' or `right'.
A rightward swipe in a chat goes back to the conversation list; on the list
a swipe shows the neighbouring filter tab."
  (let ((model (etaf-telega--model)))
    (unless (etaf-telega-model-viewer model)
      (if (eq (etaf-telega-model-screen model) 'chat)
          (when (eq direction 'right) (etaf-telega-back))
        (etaf-telega--step-filter (if (eq direction 'left) 1 -1))))))

(defun etaf-telega-activate ()
  "Open the media of the message at point, or start typing elsewhere.
While the message search is open, activating a result jumps to it in the
history and closes the search."
  (interactive)
  (let* ((model (etaf-telega--model))
         (id (etaf-telega--row-at 'message))
         (message (and id (cl-find id (etaf-telega-model-messages model)
                                   :key (lambda (item) (plist-get item :id))
                                   :test #'equal))))
    (cond
     ((and id (etaf-telega-model-chat-search model)
           (cl-find id (etaf-telega--chat-search-results model)
                    :key (lambda (item) (plist-get item :id))
                    :test #'equal))
      ;; Close the search first, so the jump lands in the full history.
      (etaf-telega-chat-search-exit)
      (etaf-telega-show-message id))
     ((and message (not (memq (plist-get message :kind) '(nil text))))
      (etaf-telega-open-media id))
     (t (etaf-telega-compose)))))

(defun etaf-telega-jump-newest ()
  "Show the newest messages and select the newest one."
  (interactive)
  (let* ((model (etaf-telega--model))
         (newest (car (last (etaf-telega-model-messages model)))))
    (when (etaf-text-input-active-p (etaf-telega--runtime etaf-telega--buffer))
      (etaf-text-input-end t))
    (etaf-telega--show-newest)
    (when newest
      (etaf-telega-model-set-selected model (plist-get newest :id))
      (etaf-telega--focus-ref etaf-telega--buffer
                              (etaf-telega--ref 'message (plist-get newest :id))))))

(defconst etaf-telega--composer-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-p") #'etaf-telega-history-previous)
    (define-key map (kbd "M-n") #'etaf-telega-history-next)
    (define-key map (kbd "C-c C-s") #'etaf-telega-toggle-silent)
    (define-key map (kbd "C-c C-l") #'etaf-telega-toggle-link-preview)
    (define-key map (kbd "C-c C-m") #'etaf-telega-toggle-markdown)
    (define-key map (kbd "C-c C-t") #'etaf-telega-schedule-send)
    (define-key map (kbd "C-c C-d") #'etaf-telega-clear-draft)
    (define-key map (kbd "C-c C-a") #'etaf-telega-attach)
    (define-key map (kbd "C-c C-u") #'etaf-telega-cancel-upload)
    (define-key map (kbd "RET")
      (lambda () (interactive) (etaf-telega--compose-return)))
    (define-key map (kbd "C-n") #'etaf-telega-popover-next)
    (define-key map (kbd "C-p") #'etaf-telega-popover-previous)
    (define-key map (kbd "C-c C-j") #'etaf-telega-popover-select)
    (define-key map (kbd "C-c C-e") #'etaf-telega-open-emoji)
    (define-key map (kbd "C-c C-p") #'etaf-telega-open-stickers)
    map)
  "Composer keys: sent texts, send options, attachments and popovers.")

(defun etaf-telega--reset-input-history ()
  "Stop browsing the open conversation's input history."
  (setq etaf-telega--input-index nil
        etaf-telega--input-stash nil))

(defun etaf-telega--remember-input (chat-id text)
  "Remember TEXT as CHAT-ID's latest sent text, newest first."
  (when (and chat-id (stringp text) (not (string-empty-p text)))
    (let ((texts (cons text (remove text (gethash chat-id etaf-telega--input-history)))))
      (puthash chat-id
               (if (> (length texts) etaf-telega--input-history-limit)
                   (cl-subseq texts 0 etaf-telega--input-history-limit)
                 texts)
               etaf-telega--input-history))))

(defun etaf-telega--save-draft (chat-id text)
  "Store TEXT as CHAT-ID's draft through the backend."
  (when chat-id
    (etaf-telega-backend-save-draft etaf-telega--backend chat-id text)))

(defun etaf-telega--save-current-draft ()
  "Store the open conversation's current draft through the backend."
  (when etaf-telega--model
    (etaf-telega--save-draft (plist-get (etaf-telega-model-chat etaf-telega--model) :id)
                             (etaf-telega-model-draft etaf-telega--model))))

(defun etaf-telega--set-composer (text)
  "Show TEXT in the composer, keeping it editable."
  (let ((runtime (etaf-telega--runtime etaf-telega--buffer)))
    (when (etaf-text-input-active-p runtime)
      (etaf-text-input-end 'blur))
    (etaf-telega-model-set-draft (etaf-telega--model) text)
    (etaf-telega--goto-ref etaf-telega--buffer 'telega-composer)
    (etaf-text-input-begin runtime 'telega-composer)))

(defun etaf-telega--history-step (delta)
  "Replace the composer text with the sent text DELTA positions away."
  (let* ((model (etaf-telega--model))
         (chat (etaf-telega-model-chat model))
         (texts (and chat (gethash (plist-get chat :id) etaf-telega--input-history))))
    (unless texts (user-error "没有输入历史"))
    (cond
     ((null etaf-telega--input-index)
      (when (> delta 0)
        (setq etaf-telega--input-stash (etaf-telega-model-draft model)
              etaf-telega--input-index 0)
        (etaf-telega--set-composer (car texts))))
     (t
      (let ((index (+ etaf-telega--input-index delta)))
        (cond
         ((< index 0)
          (setq etaf-telega--input-index nil)
          (etaf-telega--set-composer (or etaf-telega--input-stash "")))
         ((>= index (length texts))
          (etaf-telega--set-composer (nth (1- (length texts)) texts)))
         (t
          (setq etaf-telega--input-index index)
          (etaf-telega--set-composer (nth index texts)))))))))

(defun etaf-telega-history-previous ()
  "Replace the composer text with the previous sent text (M-p)."
  (interactive)
  (etaf-telega--history-step 1))

(defun etaf-telega-history-next ()
  "Replace the composer text with the next sent text (M-n)."
  (interactive)
  (etaf-telega--history-step -1))

(defun etaf-telega-clear-draft ()
  "Discard the composer's text and leave the input (C-c C-d)."
  (interactive)
  (let ((model (etaf-telega--model))
        (runtime (etaf-telega--runtime etaf-telega--buffer)))
    (when (etaf-text-input-active-p runtime)
      (etaf-text-input-end 'blur))
    (etaf-telega--reset-input-history)
    (etaf-telega-model-set-draft model "")
    (etaf-telega--save-current-draft)))

(defun etaf-telega--toggle-send-option (key)
  "Toggle the send option KEY for the next message."
  (let* ((model (etaf-telega--model))
         (options (etaf-telega-model-send-options model)))
    (etaf-telega-model-set-send-option model key (not (plist-get options key)))))

(defun etaf-telega-toggle-silent ()
  "Send the next message without a notification (C-c C-s)."
  (interactive)
  (etaf-telega--toggle-send-option 'silent))

(defun etaf-telega-toggle-link-preview ()
  "Disable the link preview for the next message (C-c C-l)."
  (interactive)
  (etaf-telega--toggle-send-option 'no-preview))

(defun etaf-telega-toggle-markdown ()
  "Parse the next message as Markdown into formatted text (C-c C-m)."
  (interactive)
  (etaf-telega--toggle-send-option 'markdown))

(defun etaf-telega-schedule-send (time)
  "Send the next message at TIME, a timestamp; nil sends it now.
Interactively read HH:MM or a full date; an empty answer clears the
schedule."
  (interactive (list (etaf-telega--read-schedule)))
  (etaf-telega-model-set-send-option (etaf-telega--model) 'at time))

(defun etaf-telega-clear-schedule ()
  "Send the next message immediately, cancelling the schedule."
  (interactive)
  (etaf-telega-model-set-send-option (etaf-telega--model) 'at nil))

(defun etaf-telega--read-schedule ()
  "Read the timestamp the next message should be sent at, or nil.
An empty answer clears the schedule; an HH:MM answer uses today, or
tomorrow when that time has already passed."
  (let ((text (string-trim
               (read-string "定时发送（HH:MM 或 YYYY-MM-DD HH:MM，留空取消）："))))
    (unless (string-empty-p text)
      (let ((time (date-to-time
                   (if (and (string-match-p ":" text)
                            (not (string-match-p " " text)))
                       (concat (format-time-string "%Y-%m-%d") " " text)
                     text))))
        (float-time (if (time-less-p time (current-time))
                        (time-add time 86400)
                      time))))))

(defconst etaf-telega--attach-kinds
  '((photo . "图片") (video . "视频") (voice . "语音") (document . "文件"))
  "Attachment kinds of the composer's paperclip menu, as (KIND . LABEL).")

(defun etaf-telega--file-kind (path)
  "Return the Telegram kind for the file at PATH from its extension."
  (pcase (downcase (or (file-name-extension path) ""))
    ((or "png" "jpg" "jpeg" "gif" "webp" "heic" "bmp") 'photo)
    ((or "mp4" "mov" "m4v" "mkv" "webm" "avi") 'video)
    ((or "ogg" "oga" "opus" "m4a" "mp3" "wav" "flac") 'voice)
    (_ 'document)))

(defun etaf-telega-attach (path)
  "Send the file at PATH, choosing its Telegram kind by extension (C-c C-a)."
  (interactive (list (read-file-name "附件：")))
  (etaf-telega-send-file-as (etaf-telega--file-kind path) path))

(defun etaf-telega-attach-as (kind &optional path)
  "Send the file at PATH as KIND, the composer's paperclip menu action.
KIND is `photo', `video', `voice' or `document' and decides how Telegram
treats the file, so a text file can go as a photo and a PNG as a document
when the sender says so.  PATH defaults to a file read from the minibuffer
with a prompt for KIND; interactively the kind is read first too.  The
draft becomes the caption, like `etaf-telega-attach'."
  (interactive
   (list (intern (completing-read "附件类型："
                                  (mapcar (lambda (entry)
                                            (symbol-name (car entry)))
                                          etaf-telega--attach-kinds)
                                  nil t))))
  (unless (assq kind etaf-telega--attach-kinds)
    (user-error "未知附件类型：%s" kind))
  (etaf-telega-send-file-as
   kind (or path
            (read-file-name
             (format "发送%s："
                     (cdr (assq kind etaf-telega--attach-kinds)))))))

(defun etaf-telega-send-file-as (kind path)
  "Send the file at PATH as KIND, using the composer draft as its caption.
KIND is `photo', `video', `voice' or `document'; the draft stays until the
message is accepted and the pending upload shows in the status line."
  (interactive
   (list (intern (completing-read "附件类型：" '("photo" "video" "voice" "document")
                                  nil t))
         (read-file-name "附件：")))
  (let* ((model (etaf-telega--model))
         (chat (etaf-telega-model-chat model))
         (caption (etaf-telega-model-draft model)))
    (unless chat (user-error "先选择一个对话"))
    (unless (etaf-telega--can-post-p chat)
      (user-error "%s" (etaf-telega--no-post-text chat)))
    (unless (and (stringp path) (not (string-empty-p path)))
      (user-error "没有选择文件"))
    (when (file-directory-p path)
      (user-error "不能发送文件夹：%s" path))
    (etaf-telega--reset-input-history)
    (etaf-telega-model-set-upload model
                                  (list :path path
                                        :name (file-name-nondirectory path)
                                        :progress 0))
    (etaf-telega-model-set-status model (format "正在上传 %s…"
                                                (file-name-nondirectory path)))
    (etaf-telega-backend-send-file
     etaf-telega--backend (plist-get chat :id) kind path
     (and caption (not (string-empty-p (string-trim caption))) caption)
     (etaf-telega-model-send-options model))
    (etaf-telega--reset-send-options model)
    path))

(defun etaf-telega-cancel-upload ()
  "Cancel the file upload in progress (C-c C-u)."
  (interactive)
  (let* ((model (etaf-telega--model))
         (upload (etaf-telega-model-upload model)))
    (if (null upload)
        (user-error "没有正在上传的文件")
      (etaf-telega-backend-cancel-upload etaf-telega--backend
                                         (plist-get upload :path))
      (etaf-telega-model-set-upload model nil)
      (etaf-telega-model-set-status model "已取消上传"))))

(defun etaf-telega--on-upload (model event)
  "Show upload EVENT's progress in MODEL's status line and upload row."
  (let ((name (or (plist-get event :name) "文件"))
        (progress (or (plist-get event :progress) 0))
        (upload (etaf-telega-model-upload model)))
    (etaf-telega-model-set-upload
     model (list :path (plist-get upload :path)
                 :name name :progress progress))
    (etaf-telega-model-set-status
     model (format "正在上传 %s：%d%%" name (round (* 100 progress))))))

(defconst etaf-telega--emoji-choices
  '("👍" "❤️" "🔥" "😂" "😮" "😢" "🎉" "👏" "🙏" "👌"
    "🤔" "💯" "😍" "🥰" "😎" "🤝" "✨" "☕" "🍺" "🌙")
  "Emoji offered by the composer's emoji picker.")

(defun etaf-telega--popover-close ()
  "Close the composer popover."
  (when etaf-telega--model
    (etaf-telega-model-set-popover etaf-telega--model nil)))

(defun etaf-telega--popover-open (kind title items)
  "Show the composer popover of KIND with TITLE over ITEMS."
  (when items
    (etaf-telega-model-set-popover
     (etaf-telega--model)
     (list :kind kind :title title :items items :index 0))))

(defun etaf-telega--popover-mention (query)
  "Offer the open conversation's members matching QUERY."
  (let* ((model (etaf-telega--model))
         (chat (etaf-telega-model-chat model)))
    (etaf-telega-backend-search-members
     etaf-telega--backend (plist-get chat :id) query
     (lambda (members)
       (when (and (eq model etaf-telega--model)
                  (string-match-p "@\\([[:alnum:]_]*\\)\\'"
                                  (etaf-telega-model-draft model)))
         (etaf-telega--popover-open
          'mention "选择成员"
          (mapcar (lambda (member)
                    (let ((handle (or (plist-get member :username)
                                      (plist-get member :name))))
                      (list :label (format "@%s" handle)
                            :insert (format "@%s " handle))))
                  members)))))))

(defun etaf-telega--popover-hashtag (query)
  "Offer hashtags from the loaded history matching QUERY."
  (let* ((model (etaf-telega--model))
         (tags (let (result)
                 (dolist (message (etaf-telega-model-messages model))
                   (let ((start 0)
                         (text (or (plist-get message :text) "")))
                     (while (string-match "#\\([[:alnum:]_]+\\)" text start)
                       (push (match-string 1 text) result)
                       (setq start (match-end 0)))))
                 (delete-dups (nreverse result))))
         (items (cl-remove-if-not
                 (lambda (tag) (string-prefix-p query tag t))
                 tags)))
    (etaf-telega--popover-open
     'hashtag "标签"
     (mapcar (lambda (tag)
               (list :label (format "#%s" tag) :insert (format "#%s " tag)))
             (cl-subseq items 0 (min 12 (length items)))))))

(defun etaf-telega--compose-changed (text)
  "Track composer TEXT and open a completion popover when it asks for one.
A closing client still ends its active input session, so a missing model
just drops the update."
  (when etaf-telega--model
    (let ((model etaf-telega--model))
      (etaf-telega-model-set-draft model text)
      (cond
       ((and (etaf-telega-model-chat model)
             (string-match "@\\([[:alnum:]_]*\\)\\'" text))
        (etaf-telega--popover-mention (match-string 1 text)))
       ((string-match "#\\([[:alnum:]_]*\\)\\'" text)
        (etaf-telega--popover-hashtag (match-string 1 text)))
       (t (etaf-telega--popover-close))))))

(defun etaf-telega-open-emoji ()
  "Show the emoji picker over the composer (C-c C-e)."
  (interactive)
  (etaf-telega-compose)
  (etaf-telega--popover-open
   'emoji "表情"
   (mapcar (lambda (emoji) (list :label emoji :insert emoji))
           etaf-telega--emoji-choices)))

(defun etaf-telega-open-stickers (query)
  "Show the sticker picker over the composer (C-c C-p).
QUERY is an emoji or keyword; an empty one asks for trending stickers."
  (interactive (list (read-string "贴纸（表情或关键词，可留空）：")))
  (etaf-telega-compose)
  (let ((model (etaf-telega--model)))
    (etaf-telega-backend-search-stickers
     etaf-telega--backend query
     (lambda (stickers)
       (when (eq model etaf-telega--model)
         (etaf-telega--popover-open
          'sticker "贴纸"
          (mapcar (lambda (sticker)
                    (list :label (or (plist-get sticker :emoji) "贴纸")
                          :sticker sticker))
                  stickers)))))))

(defun etaf-telega--popover-step (delta)
  "Move the popover selection DELTA items, wrapping at the ends."
  (let* ((model (etaf-telega--model))
         (popover (etaf-telega-model-popover model)))
    (when popover
      (let* ((items (plist-get popover :items))
             (index (mod (+ (plist-get popover :index) delta) (length items))))
        (etaf-telega-model-set-popover
         model (plist-put (copy-sequence popover) :index index))))))

(defun etaf-telega-popover-next ()
  "Move the composer popover's selection down (C-n)."
  (interactive)
  (etaf-telega--popover-step 1))

(defun etaf-telega-popover-previous ()
  "Move the composer popover's selection up (C-p)."
  (interactive)
  (etaf-telega--popover-step -1))

(defun etaf-telega-popover-select (&optional index)
  "Select the composer popover's item INDEX, the current one by default."
  (interactive)
  (let* ((model (etaf-telega--model))
         (popover (etaf-telega-model-popover model)))
    (when popover
      (when (numberp index)
        (setq popover (plist-put (copy-sequence popover) :index index))
        (etaf-telega-model-set-popover model popover))
      (let ((item (nth (or (plist-get popover :index) 0) (plist-get popover :items))))
        (pcase (plist-get popover :kind)
          ('sticker
           (etaf-telega--popover-close)
           (etaf-telega-backend-send-sticker
            etaf-telega--backend
            (plist-get (etaf-telega-model-chat model) :id)
            (plist-get item :sticker)))
          (_
           (let ((text (etaf-telega-model-draft model))
                 (insert (plist-get item :insert)))
             (etaf-telega--popover-close)
             (etaf-telega--set-composer
              (pcase (plist-get popover :kind)
                ((or 'mention 'hashtag)
                 (replace-regexp-in-string "[@#][[:alnum:]_]*\\'" insert text))
                (_ (concat text insert)))))))))))

(defun etaf-telega--popover-choose (item)
  "Select ITEM from the open composer popover."
  (let* ((model (etaf-telega--model))
         (popover (etaf-telega-model-popover model))
         (index (cl-position item (plist-get popover :items) :test #'equal)))
    (when index
      (etaf-telega-popover-select index))))

(defun etaf-telega--compose-return ()
  "Select the popover's item, or submit the composer."
  (if (etaf-telega-model-popover (etaf-telega--model))
      (etaf-telega-popover-select)
    (etaf-text-input-end)))

(defun etaf-telega-compose ()
  "Start typing in the composer."
  (interactive)
  (unless (etaf-telega-model-chat (etaf-telega--model))
    (user-error "先选择一个对话"))
  (etaf-telega--reset-input-history)
  (let ((runtime (etaf-telega--runtime etaf-telega--buffer)))
    (etaf-telega--goto-ref etaf-telega--buffer 'telega-composer)
    (etaf-text-input-begin runtime 'telega-composer)))

(defun etaf-telega--message-at-point ()
  "Return the message under point or signal a user error."
  (let* ((model (etaf-telega--model))
         (id (or (etaf-telega--row-at 'message) (etaf-telega-model-selected-id model))))
    (or (and id (etaf-telega-model-message-by-id model id))
        (user-error "先把光标移到一条消息上"))))

(defun etaf-telega-reply ()
  "Compose a reply to the message under point."
  (interactive)
  (let ((message (etaf-telega--message-at-point)))
    (etaf-telega-model-set-compose etaf-telega--model
                                   (list :kind 'reply :target message))
    (etaf-telega-compose)))

(defun etaf-telega-edit ()
  "Edit the outgoing message under point in the composer."
  (interactive)
  (let ((message (etaf-telega--message-at-point))
        (model etaf-telega--model))
    (unless (plist-get message :outgoing)
      (user-error "只能编辑自己发送的消息"))
    (etaf-batch
      (etaf-telega-model-set-compose
       model (list :kind 'edit :target message :draft (etaf-telega-model-draft model)))
      (etaf-telega-model-set-draft model (or (plist-get message :text) "")))
    (etaf-telega-compose)))

(defun etaf-telega-cancel-compose ()
  "Cancel the active reply or edit.
An edit restores the draft that was present before editing began."
  (interactive)
  (when (etaf-text-input-active-p (etaf-telega--runtime etaf-telega--buffer))
    (etaf-text-input-end t))
  (let* ((model (etaf-telega--model))
         (compose (etaf-telega-model-compose model)))
    (etaf-telega--popover-close)
    (when compose
      (etaf-batch
        (when (eq (plist-get compose :kind) 'edit)
          (etaf-telega-model-set-draft model (or (plist-get compose :draft) "")))
        (etaf-telega-model-set-compose model nil))
      (etaf-telega--save-current-draft))))

(defun etaf-telega--can-post-p (chat)
  "Return non-nil when CHAT accepts new messages from the user.
A projection without the flag is assumed writable, so alternate backends
keep working; an explicit nil marks a read-only channel or conversation."
  (or (null chat)
      (not (plist-member chat :can-post))
      (and (plist-get chat :can-post) t)))

(defun etaf-telega--no-post-text (chat)
  "Return the reason CHAT cannot be posted to right now."
  (if (eq (plist-get chat :kind) 'channel)
      "此频道只允许管理员发言"
    "你不能在此对话发言"))

(defun etaf-telega-send (text)
  "Send TEXT to the open chat, honouring the compose state.
A reply carries its quoted message; an edit replaces its target.  The draft
stays until the backend accepts it, so a failure keeps the text for retry."
  (let* ((model (etaf-telega--model))
         (chat (etaf-telega-model-chat model))
         (compose (etaf-telega-model-compose model)))
    (unless chat
      (user-error "先选择一个对话"))
    (unless (etaf-telega--can-post-p chat)
      (user-error "%s" (etaf-telega--no-post-text chat)))
    (etaf-telega--popover-close)
    (unless (string-empty-p (string-trim text))
      (etaf-telega--reset-input-history)
      (setq etaf-telega--submitted-text text)
      (let ((options (etaf-telega-model-send-options model)))
        (pcase (plist-get compose :kind)
          ('reply (etaf-telega-backend-send etaf-telega--backend text
                                            (plist-get compose :target) options))
          ('edit (etaf-telega-backend-edit etaf-telega--backend
                                           (plist-get compose :target) text))
          (_ (etaf-telega-backend-send etaf-telega--backend text nil options)))
        (etaf-telega--reset-send-options model)))))

(defun etaf-telega--reset-send-options (model)
  "Clear MODEL's pending send options after a send."
  (etaf-telega-model-set-send-option model 'silent nil)
  (etaf-telega-model-set-send-option model 'no-preview nil)
  (etaf-telega-model-set-send-option model 'at nil)
  (etaf-telega-model-set-send-option model 'markdown nil))

(defun etaf-telega--keep-draft (text)
  "Keep TEXT as the draft after leaving the composer.
Leaving an edit restores the draft captured before editing."
  (when etaf-telega--model
    (etaf-telega--popover-close)
    (etaf-telega--reset-input-history)
    (let ((compose (etaf-telega-model-compose etaf-telega--model)))
      (etaf-batch
        (etaf-telega-model-set-draft
         etaf-telega--model
         (if (eq (plist-get compose :kind) 'edit)
             (or (plist-get compose :draft) "")
           text))
        (etaf-telega-model-set-compose etaf-telega--model nil))
      (etaf-telega--save-current-draft))))

(defun etaf-telega-reload-chat ()
  "Reload the open chat's newest history page."
  (interactive)
  (let ((chat (etaf-telega-model-chat (etaf-telega--model))))
    (unless chat (user-error "先选择一个对话"))
    (setq etaf-telega--history-end nil
          etaf-telega--older-pending nil
          etaf-telega--history-retries 0)
    (etaf-telega-backend-select etaf-telega--backend (plist-get chat :id))))

(defun etaf-telega-back ()
  "Leave the chat for the conversation list, keeping its conversation at point."
  (interactive)
  (let ((model (etaf-telega--model)))
    (when (etaf-text-input-active-p (etaf-telega--runtime etaf-telega--buffer))
      (etaf-text-input-end t))
    (etaf-telega--save-current-draft)
    (etaf-telega--show-screen 'root)
    (or (and (etaf-telega-model-cursor model)
             (etaf-telega--focus-ref etaf-telega--buffer
                                     (etaf-telega--ref 'chat
                                                       (etaf-telega-model-cursor model))))
        (with-current-buffer etaf-telega--buffer (goto-char (point-min))))))

;;;; Information, theme and lifecycle

(defun etaf-telega--canvas (key)
  "Return the active palette's color KEY for the application canvas.
The value is re-read when `etaf-telega--canvas-version' changes, because a
palette switch also repaints the window area around the View."
  (etaf-value etaf-telega--canvas-version)
  (etaf-telega-color key))

(defun etaf-telega-info ()
  "Return visible client facts without network I/O."
  (let* ((model etaf-telega--model)
         (chat (and model (etaf-telega-model-chat model))))
    (list :buffer (and (buffer-live-p etaf-telega--buffer) etaf-telega--buffer)
          :screen (and model (etaf-telega-model-screen model))
          :status (and model (etaf-telega-model-status model))
          :chats (length (and model (etaf-telega-model-chats model)))
          :filter (and model (etaf-telega-model-filter model))
          :cursor (and model (etaf-telega-model-cursor model))
          :chat (plist-get chat :id)
          :messages (length (and model (etaf-telega-model-messages model)))
          :selected (and model (etaf-telega-model-selected-id model))
          :compose (plist-get (and model (etaf-telega-model-compose model)) :kind)
          :draft (and model (etaf-telega-model-draft model))
          :history-end etaf-telega--history-end
          :viewer (plist-get (and model (etaf-telega-model-viewer model)) :id)
          :search (and model (etaf-telega-model-searching model)
                       (etaf-telega-model-search model))
          :chat-search (and model (etaf-telega-model-chat-search model))
          :details (and model (etaf-telega-model-details model))
          :editing (and (etaf-text-input-active-p
                         (etaf-telega--runtime etaf-telega--buffer))
                        t))))

(defun etaf-telega-toggle-theme ()
  "Cycle the client through the dark, light and native palettes.
The choice is written to the client's mode cell, which is also what a panel's
title-bar switch writes, so both stay one state."
  (interactive)
  (let ((mode (pcase (etaf-telega--theme-name)
                ('dark 'light)
                ('light 'native)
                (_ 'dark))))
    (etaf-set-value etaf-telega--theme-mode mode)
    ;; Keep the next client and the customization UI on the same choice.
    (setq etaf-telega-theme mode))
  (etaf-set-value etaf-telega--canvas-version
                  (1+ (etaf-value etaf-telega--canvas-version)))
  ;; A View mounted by a host repaints from the version cell alone.  The
  ;; client's own buffer also owns the window area around the View, and those
  ;; colors come from `etaf-app-open', so that buffer re-mounts.
  (when-let* ((model etaf-telega--model)
              (buffer (and (buffer-live-p etaf-telega--buffer) etaf-telega--buffer))
              ((equal (buffer-name buffer) etaf-telega-buffer-name)))
    (with-current-buffer buffer
      (let ((point (point)))
        (etaf-mount buffer (etaf-view (etaf-telega-app :model model)))
        (goto-char (min point (point-max))))))
  (message "etaf-telega 主题：%s" (etaf-telega--theme-name)))

;;;###autoload
(defun etaf-telega-create ()
  "Create a client session without mounting it.
The session owns the model and one backend; no request is sent until its View
is mounted by `etaf-telega-open' or a host."
  (let ((model (etaf-telega-model)))
    (list :model (plist-put model :backend
                            (funcall etaf-telega-backend-create-function)))))

;;;###autoload
(defun etaf-telega-view (session)
  "Return SESSION's View for mounting in a host of your own.
The View lays out for the region it is given, so a desktop window or a
floating panel gets the list beside the chat at its own width.  Mounting
adopts the host buffer: the client's commands and keys find the session
there, and unmounting stops the backend."
  (etaf-view (etaf-telega-app :model (plist-get session :model))))

(defun etaf-telega--adopt (model)
  "Adopt the buffer that mounted MODEL's View and start the client there."
  (when-let* ((runtime (etaf-current-runtime))
              (buffer (and runtime (etaf-runtime-buffer runtime))))
    (when (buffer-live-p buffer)
      (setq etaf-telega--model model
            etaf-telega--backend (plist-get model :backend)
            etaf-telega--buffer buffer)
      (with-current-buffer buffer
        (add-hook 'post-command-hook #'etaf-telega--track-point nil t))
      (unless (plist-get model :started)
        (plist-put model :started t)
        (etaf-telega--show-screen 'root)
        (etaf-telega-backend-start etaf-telega--backend
                                   (etaf-telega--callbacks model))))))

(defun etaf-telega--release (model)
  "Stop MODEL's backend and forget the buffer that showed it."
  (when (eq model etaf-telega--model)
    (etaf-telega--dispose)))

;;;###autoload
(defun etaf-telega-open ()
  "Show the client, starting it when needed, and return its buffer."
  (interactive)
  (if-let* ((buffer (etaf-app-buffer etaf-telega-buffer-name)))
      (pop-to-buffer-same-window buffer)
    (etaf-telega-close)
    (let* ((session (etaf-telega-create))
           (buffer (etaf-app-open etaf-telega-buffer-name
                                  (etaf-telega-view session)
                                  :state (plist-get session :model)
                                  ;; The View paints its own surfaces; the
                                  ;; canvas colors show in the rows and columns
                                  ;; it leaves.
                                  :background (lambda () (etaf-telega--canvas :bg))
                                  :foreground (lambda () (etaf-telega--canvas :ink))
                                  :cursor nil
                                  :on-close #'etaf-telega--dispose)))
      (setq etaf-telega--buffer buffer)
      (pop-to-buffer-same-window buffer)
      buffer)))

(defun etaf-telega--dispose ()
  "Stop the backend and release the client session.
The application runtime unmounts the View after this returns."
  (let ((backend etaf-telega--backend)
        (buffer etaf-telega--buffer))
    (setq etaf-telega--model nil
          etaf-telega--backend nil
          etaf-telega--buffer nil)
    (when backend (etaf-telega-backend-stop backend))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'post-command-hook #'etaf-telega--track-point t)
        (when-let* ((runtime (etaf-telega--runtime buffer)))
          (when (etaf-text-input-active-p runtime)
            (etaf-text-input-end t)))))))

;;;###autoload
(defun etaf-telega-close ()
  "Close the client buffer.
The backend stops observing without closing Telega's server or account."
  (interactive)
  (if-let* ((buffer (etaf-app-buffer etaf-telega-buffer-name)))
      (etaf-app-close buffer)
    (let ((live etaf-telega--buffer))
      (etaf-telega--dispose)
      (when (buffer-live-p live) (kill-buffer live)))))

(provide 'etaf-telega-app)
;;; etaf-telega-app.el ends here
