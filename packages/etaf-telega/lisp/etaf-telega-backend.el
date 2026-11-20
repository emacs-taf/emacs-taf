;;; etaf-telega-backend.el --- Telegram backends for etaf-telega -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The capability contract
;;
;; A backend owns one account's connection, data and actions.  It owns no
;; buffers and never reads the model; the application passes a CALLBACKS plist
;; and projects every answer:
;;
;;   :status   (string)                 connection state for the header
;;   :me       (plist)                  own account (:id :name :username)
;;   :chats    (list of chat plists)    (:id :title :preview :author :unread
;;                                      :pinned :muted :kind :archived :mention
;;                                      :online :can-post :username :time :order
;;                                      :photo :members :last-read :pinned-id),
;;                                      main list then
;;                                      archive, each in the server's order.
;;                                      :can-post is nil on a broadcast
;;                                      channel only administrators may post to
;;   :messages (list of message plists) the chat's newest page, newest first
;;   :older    (list of message plists) an older page, newest first
;;   :message  (message plist)          one later message for the selected
;;             chat; the application appends it in reading order
;;   :sent     (message plist)          accepted outgoing message
;;   :edited   (message plist)          message whose text this client replaced
;;   :updated  (message plist)          message changed elsewhere (content or
;;                                      edit), replacing the copy with its id
;;   :jump     (list of messages)       a page loaded around one message
;;   :upload   (:name NAME :progress P) file upload progress, P a fraction
;;   :deleted  (id)                     id of a removed message
;;   :read     (list of ids)            messages accepted as read
;;   :error    (string)                 readable failure
;;
;; A send the chat refuses (missing post rights, an invalid or empty file
;; path, a server rejection) reports through `:error'; the application keeps
;; the draft and drops any pending upload instead of showing it forever.
;;
;; Message plists carry (:id :outgoing :sender :time :date :edited :kind
;; :file :link :media :avatar :reply :reactions :duration :views :text);
;; :views is a channel post's view count or nil, :reply is
;; (:id :sender :kind :text) of the quoted message, :reactions a list of
;; (:key :label :count :chosen) in server order and :duration the length in
;; seconds of video, animation, voice and audio.  A reaction :key is an emoji
;; string or `custom:<id>' for a custom emoji, so it is always a scalar ETAF View
;; key.  A chat's :photo, a message's sender :avatar and its
;; :media :src are image sources:
;; a local file path, an Emacs image descriptor (an in-memory preview), or
;; nil.  :media is (:src :width :height) in source pixels for photos, video
;; and animation thumbnails and stickers.  A backend fetches missing files
;; itself and reports the chat list or an `:updated' message once they are
;; local, so sources only ever improve.
;; Every live backend implements the generics below; the Telega adapter reuses
;; Telega's server, TDLib calls and object cache, and the fake backend replays
;; fixed data for tests and offline use.
;;
;;   (start BACKEND CALLBACKS)            connect and report status, me, chats
;;   (stop BACKEND)                       stop observing; keep the account
;;   (select BACKEND CHAT-ID)             open a chat and load its newest page
;;   (history BACKEND &key before limit)  load messages older than BEFORE
;;   (around BACKEND MESSAGE-ID &key limit)  load the page at MESSAGE-ID,
;;                                        newest first; arrives as `:jump'
;;   (date-message BACKEND DATE)          load the message at DATE (a
;;                                        `float-time'); arrives as `:jump'
;;   (save-draft BACKEND CHAT-ID TEXT)    store a conversation's draft;
;;                                        empty TEXT clears it
;;   (search-chats BACKEND QUERY CALLBACK)  search the account for
;;                                        conversations matching QUERY
;;   (search-messages BACKEND QUERY CALLBACK)  search the selected chat's
;;                                        full history for QUERY
;;   (send-file BACKEND CHAT-ID KIND PATH CAPTION OPTIONS)  send a file
;;                                        as photo, video, voice or
;;                                        document
;;   (cancel-upload BACKEND PATH)         cancel a pending file upload
;;   (search-members BACKEND CHAT-ID QUERY CALLBACK)  chat members by name
;;   (search-stickers BACKEND QUERY CALLBACK)  stickers by emoji or keyword
;;   (send-sticker BACKEND CHAT-ID STICKER)  send a picked sticker
;;   (send BACKEND TEXT &optional REPLY-TO OPTIONS)  send, optionally
;;                                        replying, with send options
;;                                        (:silent :no-preview :at :markdown)
;;   (edit BACKEND MESSAGE TEXT)          replace one message's text
;;   (read BACKEND MESSAGE-IDS)           accept messages as read
;;   (react BACKEND MESSAGE-ID KEY)       toggle reaction KEY (emoji or custom:<id>)
;;                                        on a message; the change arrives
;;                                        as an `:updated' message
;;   (media BACKEND MESSAGE-ID CALLBACK)  fetch a message's full media file;
;;                                        CALLBACK receives (PROGRESS SOURCE)
;;                                        with PROGRESS from 0.0 to 1.0 and a
;;                                        non-nil SOURCE once it is local
;;   (native BACKEND COMMAND CHAT-ID &optional MESSAGE-ID)
;;                                        run the backend's own interactive
;;                                        COMMAND on that chat or message
;;   (chat-candidates BACKEND)            conversations and contacts to
;;                                        offer when opening a chat by name
;;   (ensure-chat BACKEND ID)             make a conversation available to
;;                                        open; a contact without a chat gets
;;                                        its private chat created
;;
;; `native' is how the client reuses Telega's own commands (transient menus,
;; reactions, forwarding, chat operations) instead of reimplementing them.

;;; Code:

(require 'cl-lib)
(require 'etaf-telega-model)

(cl-defgeneric etaf-telega-backend-start (backend callbacks)
  "Start BACKEND and report through CALLBACKS.  Return BACKEND.")

(cl-defgeneric etaf-telega-backend-select (backend chat-id)
  "Make CHAT-ID current in BACKEND and load its newest history page.")

(cl-defgeneric etaf-telega-backend-history (backend &key before limit)
  "Load a page older than BEFORE in BACKEND's selected chat.
BEFORE is the oldest loaded message id, or nil for the newest page.")

(cl-defgeneric etaf-telega-backend-around (backend message-id &key limit)
  "Load the page at MESSAGE-ID in BACKEND's selected chat.
The page arrives through the `:jump' callback, newest first.")

(cl-defgeneric etaf-telega-backend-date-message (backend date)
  "Load the message at DATE, a `float-time', in BACKEND's selected chat.
The message arrives through the `:jump' callback.")

(cl-defgeneric etaf-telega-backend-save-draft (backend chat-id text)
  "Store TEXT as CHAT-ID's draft through BACKEND; an empty TEXT clears it.")

(cl-defgeneric etaf-telega-backend-search-chats (backend query callback)
  "Search BACKEND's account for conversations matching QUERY.
CALLBACK receives a list of chat projections, including conversations the
account has not loaded into the list yet.  QUERY matching is the backend's
server-side search, not the client's local substring filter.")

(cl-defgeneric etaf-telega-backend-search-messages (backend query callback)
  "Search BACKEND's selected chat for messages matching QUERY.
CALLBACK receives message projections, newest first, including messages the
client has not loaded; QUERY matching is the backend's search.")

(cl-defgeneric etaf-telega-backend-pinned-message (backend chat-id callback)
  "Report CHAT-ID's newest pinned message id through CALLBACK.
CALLBACK receives the message id, or nil when the conversation has nothing
pinned.  A conversation's cached data does not follow pins made while a
session is open, so the pinned jump asks the backend for the message each
time instead of trusting the cache.")

(cl-defgeneric etaf-telega-backend-send-file (backend chat-id kind path caption options)
  "Send the file at PATH to CHAT-ID through BACKEND as KIND.
KIND is `photo', `video', `voice' or `document'; CAPTION is the text shown
with it, OPTIONS are the send options of `etaf-telega-backend-send'.  Upload
progress arrives through the `:upload' callback and the accepted message
through `:sent'.")

(cl-defgeneric etaf-telega-backend-cancel-upload (backend path)
  "Cancel BACKEND's pending upload of the file at PATH.")

(cl-defgeneric etaf-telega-backend-search-members (backend chat-id query callback)
  "Search CHAT-ID's members by QUERY through BACKEND.
CALLBACK receives member plists with `:id', `:name' and `:username'.")

(cl-defgeneric etaf-telega-backend-search-stickers (backend query callback)
  "Search stickers matching QUERY through BACKEND.
CALLBACK receives sticker plists with `:id', `:emoji', `:label', `:file-id',
`:thumb-id', `:thumb-width', `:thumb-height', `:width' and `:height'.")

(cl-defgeneric etaf-telega-backend-send-sticker (backend chat-id sticker)
  "Send STICKER, a picker item, to CHAT-ID through BACKEND.")

(cl-defgeneric etaf-telega-backend-send (backend text &optional reply-to options)
  "Send TEXT through BACKEND, replying to the message REPLY-TO when non-nil.
OPTIONS is a plist: `:silent' sends without a notification, `:no-preview'
disables the link preview, `:at' is a timestamp to send at, and `:markdown'
asks the backend to parse TEXT as Markdown into formatted text.")

(cl-defgeneric etaf-telega-backend-edit (backend message text)
  "Replace MESSAGE's text with TEXT through BACKEND.")

(cl-defgeneric etaf-telega-backend-read (backend message-ids)
  "Accept MESSAGE-IDS in BACKEND's selected chat as read.")

(cl-defgeneric etaf-telega-backend-react (backend message-id key)
  "Toggle reaction KEY on MESSAGE-ID in BACKEND's selected chat.
KEY is an emoji string or `custom:<id>' naming a custom emoji by its TDLib id.")

(cl-defgeneric etaf-telega-backend-media (backend message-id callback)
  "Fetch MESSAGE-ID's full media in BACKEND's selected chat.
CALLBACK receives (PROGRESS SOURCE); SOURCE is non-nil once local.")

(cl-defgeneric etaf-telega-backend-native (backend command chat-id &optional message-id)
  "Run BACKEND's interactive COMMAND on CHAT-ID, or on its MESSAGE-ID.
The command sees that chat or message as the one at point.")

(cl-defgeneric etaf-telega-backend-chat-candidates (backend)
  "Return conversations and contacts BACKEND offers by name.
Each item is a plist with `:id' and `:title'.")

(cl-defgeneric etaf-telega-backend-ensure-chat (backend id)
  "Make conversation ID available to open through BACKEND.
A backend whose account can already reach the id returns it; a backend
with a private-chat model, such as Telega, creates the missing chat.")

(cl-defgeneric etaf-telega-backend-stop (backend)
  "Release BACKEND's connection without touching Telega's account data.")

;;; Fake backend

(cl-defstruct etaf-telega-backend-fake
  chats histories sent responder callbacks chat-id replies next-sent-id natives
  sends drafts dormant files members stickers)

(cl-defun etaf-telega-backend-fake-create (&key chats histories responder dormant
                                                members stickers)
  "Create a fake backend seeded with CHATS and HISTORIES.
HISTORIES is a hash table from chat id to a list of message plists.  When
RESPONDER is non-nil it is called with (BACKEND TEXT) after each send, so a
test can acknowledge the message through `etaf-telega-backend-fake-complete'.
DORMANT holds conversations the initial list does not carry; searching finds
them like a server-side search does.  MEMBERS and STICKERS seed the composer
popovers' completion sources."
  (make-etaf-telega-backend-fake
   :chats (mapcar (lambda (chat)
                    (if (plist-member chat :can-post)
                        chat
                      (plist-put (copy-tree chat) :can-post t)))
                  chats)
   :histories (or histories (make-hash-table :test #'equal))
   :responder responder :sent nil :drafts (make-hash-table :test #'equal)
   :dormant dormant :members members :stickers stickers))

(cl-defmethod etaf-telega-backend-start ((backend etaf-telega-backend-fake)
                                         callbacks)
  "Seed CALLBACKS from BACKEND's fixed data."
  (setf (etaf-telega-backend-fake-callbacks backend) callbacks)
  (when-let* ((report (plist-get callbacks :status)))
    (funcall report "就绪"))
  (when-let* ((report (plist-get callbacks :me)))
    (funcall report (list :id 1 :name "Fixture" :username "fixture")))
  (when-let* ((report (plist-get callbacks :chats)))
    (funcall report (copy-tree (etaf-telega-backend-fake-chats backend))))
  backend)

(defconst etaf-telega-backend-fake-page-size 2
  "Messages per reported page, so tests can exercise pagination.")

(defun etaf-telega-backend-fake--page (backend chat-id start)
  "Return BACKEND's stored CHAT-ID messages from START, one page, newest first."
  (let* ((all (gethash chat-id (etaf-telega-backend-fake-histories backend)))
         (from (min start (length all)))
         (to (min (length all) (+ from etaf-telega-backend-fake-page-size))))
    (cl-subseq all from to)))

(defun etaf-telega-backend-fake--set-unread (backend chat-id unread)
  "Set CHAT-ID's stored unread count in BACKEND's chats."
  (setf (etaf-telega-backend-fake-chats backend)
        (cl-mapcar (lambda (chat)
                     (if (equal (plist-get chat :id) chat-id)
                         (plist-put (copy-tree chat) :unread unread)
                       chat))
                   (etaf-telega-backend-fake-chats backend))))

(cl-defmethod etaf-telega-backend-select ((backend etaf-telega-backend-fake)
                                          chat-id)
  "Open CHAT-ID, report its newest page and accept it as read."
  (setf (etaf-telega-backend-fake-chat-id backend) chat-id)
  (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                 :messages)))
    (funcall report (copy-tree (etaf-telega-backend-fake--page backend chat-id 0))))
  ;; Opening a conversation reads its newest page, like Telega's own chatbuf.
  (etaf-telega-backend-fake--set-unread backend chat-id 0)
  (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                 :chats)))
    (funcall report (copy-tree (etaf-telega-backend-fake-chats backend))))
  chat-id)

(cl-defmethod etaf-telega-backend-history ((backend etaf-telega-backend-fake)
                                           &key before limit)
  "Report a page older than BEFORE in BACKEND's selected chat."
  (ignore limit)
  (let* ((chat-id (etaf-telega-backend-fake-chat-id backend))
         (all (gethash chat-id (etaf-telega-backend-fake-histories backend)))
         (index (if before
                    (1+ (or (cl-position before all
                                         :key (lambda (message) (plist-get message :id))
                                         :test #'equal)
                            -1))
                  0)))
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :older)))
      (funcall report (copy-tree (etaf-telega-backend-fake--page backend chat-id index))))))

(cl-defmethod etaf-telega-backend-around ((backend etaf-telega-backend-fake)
                                          message-id &key limit)
  "Report the stored page around MESSAGE-ID in BACKEND's selected chat."
  (ignore limit)
  (let* ((chat-id (etaf-telega-backend-fake-chat-id backend))
         (all (gethash chat-id (etaf-telega-backend-fake-histories backend)))
         (index (cl-position message-id all
                             :key (lambda (message) (plist-get message :id))
                             :test #'equal))
         (start (and index
                     (max 0 (- index (1- etaf-telega-backend-fake-page-size))))))
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :jump)))
      (funcall report
               (copy-tree (and start
                               (etaf-telega-backend-fake--page backend chat-id start)))))))

(cl-defmethod etaf-telega-backend-date-message ((backend etaf-telega-backend-fake)
                                                date)
  "Report the stored message nearest before DATE in BACKEND's selected chat."
  (let* ((chat-id (etaf-telega-backend-fake-chat-id backend))
         (all (gethash chat-id (etaf-telega-backend-fake-histories backend)))
         (found (cl-find-if
                 (lambda (message)
                   (let ((stamp (ignore-errors
                                  (float-time
                                   (date-to-time
                                    (concat (or (plist-get message :date) "")
                                            " "
                                            (or (plist-get message :time) "00:00")))))))
                     (and stamp (<= stamp date))))
                 all)))
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :jump)))
      (funcall report (and found (copy-tree (list found)))))))
(cl-defmethod etaf-telega-backend-send ((backend etaf-telega-backend-fake)
                                        text &optional reply-to options)
  "Record TEXT and OPTIONS, then invoke BACKEND's responder."
  (push text (etaf-telega-backend-fake-sent backend))
  (push (list :text text :reply (plist-get reply-to :id) :options options)
        (etaf-telega-backend-fake-sends backend))
  (when reply-to
    (push (cons text (plist-get reply-to :id))
          (etaf-telega-backend-fake-replies backend)))
  (when-let* ((responder (etaf-telega-backend-fake-responder backend)))
    (funcall responder backend text))
  text)

(cl-defmethod etaf-telega-backend-edit ((backend etaf-telega-backend-fake)
                                        message text)
  "Replace MESSAGE's stored text with TEXT and report the result."
  (let* ((chat-id (etaf-telega-backend-fake-chat-id backend))
         (updated (copy-tree message)))
    (setf (plist-get updated :text) text
          (plist-get updated :edited) t)
    (puthash chat-id
             (cl-mapcar (lambda (item)
                          (if (equal (plist-get item :id) (plist-get message :id))
                              updated item))
                        (gethash chat-id (etaf-telega-backend-fake-histories backend)))
             (etaf-telega-backend-fake-histories backend))
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :edited)))
      (funcall report (copy-tree updated)))
    text))

(cl-defmethod etaf-telega-backend-save-draft ((backend etaf-telega-backend-fake)
                                              chat-id text)
  "Record TEXT as CHAT-ID's draft and store it in the conversation."
  (puthash chat-id text (etaf-telega-backend-fake-drafts backend))
  (setf (etaf-telega-backend-fake-chats backend)
        (cl-mapcar (lambda (chat)
                     (if (equal (plist-get chat :id) chat-id)
                         (plist-put (copy-tree chat) :draft text)
                       chat))
                   (etaf-telega-backend-fake-chats backend)))
  (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                 :chats)))
    (funcall report (copy-tree (etaf-telega-backend-fake-chats backend))))
  text)

(cl-defmethod etaf-telega-backend-search-chats ((backend etaf-telega-backend-fake)
                                                query callback)
  "Report BACKEND's chats, and dormant ones, whose title matches QUERY."
  (let ((needle (downcase (string-trim (or query "")))))
    (funcall callback
             (copy-tree
              (cl-remove-if-not
               (lambda (chat)
                 (or (string-empty-p needle)
                     (string-search needle (downcase (or (plist-get chat :title) "")))
                     (string-search needle (downcase (or (plist-get chat :username) "")))))
               (append (etaf-telega-backend-fake-chats backend)
                       (etaf-telega-backend-fake-dormant backend)))))))

(cl-defmethod etaf-telega-backend-search-messages ((backend etaf-telega-backend-fake)
                                                   query callback)
  "Report BACKEND's stored messages whose text matches QUERY."
  (let* ((chat-id (etaf-telega-backend-fake-chat-id backend))
         (needle (downcase (string-trim (or query ""))))
         (messages (gethash chat-id (etaf-telega-backend-fake-histories backend))))
    (funcall callback
             (copy-tree
              (cl-remove-if-not
               (lambda (message)
                 (or (string-empty-p needle)
                     (string-search needle
                                     (downcase (or (plist-get message :text) "")))))
               messages)))))

(cl-defmethod etaf-telega-backend-pinned-message ((backend etaf-telega-backend-fake)
                                                  chat-id callback)
  "Report the pinned id BACKEND stores for CHAT-ID."
  (let ((chat (cl-find chat-id (append (etaf-telega-backend-fake-chats backend)
                                       (etaf-telega-backend-fake-dormant backend))
                       :key (lambda (item) (plist-get item :id))
                       :test #'equal)))
    (funcall callback (plist-get chat :pinned-id))))

(cl-defmethod etaf-telega-backend-send-file ((backend etaf-telega-backend-fake)
                                             _chat-id kind path caption options)
  "Record the file send for KIND at PATH and report a first progress step."
  (push (list :kind kind :path path :caption caption :options options)
        (etaf-telega-backend-fake-files backend))
  (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend) :upload)))
    (funcall report (list :name (file-name-nondirectory path) :progress 0.45)))
  path)

(defun etaf-telega-backend-fake-confirm-file (backend path)
  "Report the upload of PATH as accepted and append its message.
The message id follows the stored history, like
`etaf-telega-backend-fake-complete'."
  (when-let* ((record (cl-find path (etaf-telega-backend-fake-files backend)
                               :key (lambda (item) (plist-get item :path))
                               :test #'equal)))
    (let* ((chat-id (etaf-telega-backend-fake-chat-id backend))
           (history (gethash chat-id (etaf-telega-backend-fake-histories backend)))
           (base (max (or (etaf-telega-backend-fake-next-sent-id backend) 0)
                      (or (cl-loop for message in history
                                   maximize (or (plist-get message :id) 0))
                          0)))
           (id (1+ base)))
      (setf (etaf-telega-backend-fake-next-sent-id backend) id)
      (let ((message (list :id id :outgoing t :sender "我" :time "" :date ""
                           :kind (if (eq (plist-get record :kind) 'document)
                                     'file
                                   (plist-get record :kind))
                           :text (or (plist-get record :caption) "")
                           :file (list :name (file-name-nondirectory path) :size 0))))
        (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                       :sent)))
          (funcall report message))))))

(defun etaf-telega-backend-fake-fail (backend text)
  "Report TEXT as a failed operation through BACKEND's error callback.
Lets a test drive the application's failure handling without a server."
  (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                 :error)))
    (funcall report text)))

(cl-defmethod etaf-telega-backend-cancel-upload ((backend etaf-telega-backend-fake)
                                                 path)
  "Mark PATH's record in BACKEND as cancelled."
  (when-let* ((record (cl-find path (etaf-telega-backend-fake-files backend)
                               :key (lambda (item) (plist-get item :path))
                               :test #'equal)))
    (plist-put record :cancelled t))
  path)

(cl-defmethod etaf-telega-backend-search-members ((backend etaf-telega-backend-fake)
                                                  _chat-id query callback)
  "Report BACKEND's fixture members whose name or username matches QUERY."
  (let ((needle (downcase (string-trim (or query "")))))
    (funcall callback
             (cl-remove-if-not
              (lambda (member)
                (or (string-empty-p needle)
                    (string-prefix-p needle (downcase (or (plist-get member :name) "")))
                    (string-prefix-p needle
                                     (downcase (or (plist-get member :username) "")))))
              (copy-tree (etaf-telega-backend-fake-members backend))))))

(cl-defmethod etaf-telega-backend-search-stickers ((backend etaf-telega-backend-fake)
                                                   query callback)
  "Report BACKEND's fixture stickers matching QUERY by emoji or label."
  (let ((needle (downcase (string-trim (or query "")))))
    (funcall callback
             (cl-remove-if-not
              (lambda (sticker)
                (or (string-empty-p needle)
                    (string-search needle (downcase (or (plist-get sticker :emoji) "")))
                    (string-search needle (downcase (or (plist-get sticker :label) "")))))
              (copy-tree (etaf-telega-backend-fake-stickers backend))))))

(cl-defmethod etaf-telega-backend-send-sticker ((backend etaf-telega-backend-fake)
                                                _chat-id sticker)
  "Record the sticker send for STICKER's id."
  (push (list :kind 'sticker :path (plist-get sticker :id))
        (etaf-telega-backend-fake-files backend))
  (plist-get sticker :id))

(cl-defmethod etaf-telega-backend-stop ((_backend etaf-telega-backend-fake))
  "Fake backends own no connection.")

(cl-defmethod etaf-telega-backend-read ((backend etaf-telega-backend-fake)
                                        message-ids)
  "Accept MESSAGE-IDS as read in BACKEND's selected chat."
  (let ((chat-id (etaf-telega-backend-fake-chat-id backend)))
    (etaf-telega-backend-fake--set-unread backend chat-id 0)
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :read)))
      (funcall report (copy-sequence message-ids)))
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :chats)))
      (funcall report (copy-tree (etaf-telega-backend-fake-chats backend))))
    message-ids))

(cl-defmethod etaf-telega-backend-react ((backend etaf-telega-backend-fake)
                                         message-id key)
  "Toggle KEY on MESSAGE-ID's stored reactions and report the message."
  (when-let* ((message (etaf-telega-backend-fake-message backend message-id)))
    (let* ((reactions (plist-get message :reactions))
           (old (cl-find key reactions :key (lambda (item) (plist-get item :key))
                         :test #'equal))
           (chosen (not (plist-get old :chosen)))
           (count (+ (or (plist-get old :count) 0) (if chosen 1 -1)))
           (item (list :key key :label (or (plist-get old :label) key)
                       :count count :chosen chosen))
           (updated (copy-tree message)))
      (setf (plist-get updated :reactions)
            (cond ((<= count 0) (remq old reactions))
                  (old (cl-substitute item old reactions))
                  (t (append reactions (list item)))))
      (etaf-telega-backend-fake-update backend updated)))
  key)

(cl-defmethod etaf-telega-backend-media ((backend etaf-telega-backend-fake)
                                         message-id callback)
  "Report MESSAGE-ID's stored full media, or its preview, as local."
  (let* ((message (etaf-telega-backend-fake-message backend message-id))
         (media (plist-get message :media)))
    (funcall callback 1.0 (or (plist-get media :full) (plist-get media :src)))))

(cl-defmethod etaf-telega-backend-native ((backend etaf-telega-backend-fake)
                                          command chat-id &optional message-id)
  "Record COMMAND on CHAT-ID and MESSAGE-ID instead of running it."
  (push (list command chat-id message-id)
        (etaf-telega-backend-fake-natives backend))
  command)

(cl-defmethod etaf-telega-backend-chat-candidates ((backend etaf-telega-backend-fake))
  "Return BACKEND's stored conversations as completable candidates."
  (mapcar (lambda (chat)
            (list :id (plist-get chat :id) :title (plist-get chat :title)))
          (etaf-telega-backend-fake-chats backend)))

(cl-defmethod etaf-telega-backend-ensure-chat ((_backend etaf-telega-backend-fake) id)
  "Return ID; a fake conversation is always available."
  id)

(defun etaf-telega-backend-fake-message (backend id)
  "Return BACKEND's stored message with ID, or nil."
  (cl-find id (gethash (etaf-telega-backend-fake-chat-id backend)
                       (etaf-telega-backend-fake-histories backend))
           :key (lambda (item) (plist-get item :id)) :test #'equal))

(defun etaf-telega-backend-fake-deliver (backend message)
  "Report MESSAGE as arriving in BACKEND's selected chat."
  (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                 :message)))
    (funcall report (copy-tree message))))

(defun etaf-telega-backend-fake-update (backend message)
  "Store MESSAGE in BACKEND's selected chat and report it as changed."
  (let ((chat-id (etaf-telega-backend-fake-chat-id backend)))
    (puthash chat-id
             (cl-mapcar (lambda (item)
                          (if (equal (plist-get item :id) (plist-get message :id))
                              message item))
                        (gethash chat-id (etaf-telega-backend-fake-histories backend)))
             (etaf-telega-backend-fake-histories backend))
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :updated)))
      (funcall report (copy-tree message)))))

(defun etaf-telega-backend-fake-remove (backend id)
  "Remove message ID from BACKEND's selected chat and report the deletion."
  (let ((chat-id (etaf-telega-backend-fake-chat-id backend)))
    (puthash chat-id
             (cl-remove id (gethash chat-id (etaf-telega-backend-fake-histories backend))
                        :key (lambda (item) (plist-get item :id)) :test #'equal)
             (etaf-telega-backend-fake-histories backend))
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :deleted)))
      (funcall report id))))

(defun etaf-telega-backend-fake-complete (backend text)
  "Report TEXT as accepted by BACKEND, exactly like a server acknowledgement.
The accepted message gets the next id after the stored history, so it sorts
like a real sent message instead of colliding with existing ids."
  (let* ((reply-id (cdr (assoc text (etaf-telega-backend-fake-replies backend))))
         (reply (and reply-id (etaf-telega-backend-fake-message backend reply-id)))
         (history (gethash (etaf-telega-backend-fake-chat-id backend)
                           (etaf-telega-backend-fake-histories backend)))
         (base (max (or (etaf-telega-backend-fake-next-sent-id backend) 0)
                   (or (cl-loop for message in history
                                maximize (or (plist-get message :id) 0))
                       0)))
         (id (1+ base)))
    (setf (etaf-telega-backend-fake-next-sent-id backend) id)
    (when-let* ((report (plist-get (etaf-telega-backend-fake-callbacks backend)
                                   :sent)))
      (funcall report
               (append (list :id id
                             :outgoing t :sender "我"
                             :time (format-time-string "%H:%M")
                             :text text)
                       (when reply (list :reply reply)))))))

;;; Telega backend

(declare-function telega "telega" (&optional arg))
(declare-function telega-server-live-p "telega-server" ())
(declare-function telega-chat-get "telega-chat" (chat-id &optional offline-p))
(declare-function telega-chat-title "telega-chat" (chat &optional fmt-type no-badges))
(declare-function telega-chat-match-p "telega-chat" (chat chat-temex &optional no-error))
(declare-function telega-chat--info "telega-chat" (chat &optional locally-p))
(declare-function telega-chat--info-locally "telega-chat" (chat))
(declare-function telega-msg-match-p "telega-msg" (msg msg-temex &optional no-error))
(declare-function telega-tl-str "telega-core" (obj &optional prop no-properties))
(declare-function telega-user-online-p "telega-user" (user))
(declare-function telega-chat-muted-p "telega-chat" (chat))
(declare-function telega--viewMessages "telega-tdlib" (chat messages &rest args))
(declare-function telega--getChatHistory "telega-tdlib"
                  (chat from-msg-id offset &optional limit only-local callback))
(declare-function telega--sendMessage "telega-tdlib" (chat imc &rest args))
(declare-function telega--editMessageText "telega-tdlib" (msg imc &rest args))
(declare-function telega--on-updateMessageSendFailed "telega-tdlib-events" (event))
(declare-function telega--getRepliedMessage "telega-tdlib" (msg &optional callback))
(declare-function telega-msg-content-text "telega-msg"
                  (msg &optional with-speech-recognition-p))
(declare-function telega-msg-sender "telega-msg" (tl-obj))
(declare-function telega-msg-sender-title "telega-msg" (msg-sender &rest args))
(declare-function telega-file--renew "telega-media" (place prop))
(declare-function telega-file--download "telega-media" (file &rest args))
(declare-function telega-photo--best "telega-media" (photo &optional limits))
(declare-function telega-file--downloaded-p "telega-core" (file))
(declare-function telega-file--can-download-p "telega-core" (file))
(declare-function telega-file--downloading-progress "telega-core" (file))
(declare-function telega--addMessageReaction "telega-tdlib"
                  (msg tl-reaction-type &optional big-p update-recent-reactions-p))
(declare-function telega--removeMessageReaction "telega-tdlib"
                  (msg tl-reaction-type &optional callback))
(declare-function telega-sort-chats "telega-sort" (criteria chats))
(declare-function telega-filter-chats "telega-filter" (chat-list &optional chat-temex))
(declare-function telega-user-get "telega-user" (user-id &optional locally-p))
(declare-function telega-user-chat "telega-user" (user))
(declare-function telega-user-me "telega-user" (&optional locally-p))
(declare-function telega--createPrivateChat "telega-tdlib" (user &optional callback))
(declare-function telega-markup-markdown2-fmt "telega-util" (str-or-fmt-txt))
(declare-function telega--getChatMessageByDate "telega-tdlib"
                  (chat date &optional callback))
(declare-function telega--setChatDraftMessage "telega-tdlib"
                  (chat &optional draft-msg))
(declare-function telega--deleteMessages "telega-tdlib" (messages &optional revoke))
(declare-function telega--on-updateFile "telega-tdlib-events" (event))
(declare-function telega-file--uploading-progress "telega-core" (file))
(declare-function telega--searchChatMembers "telega-tdlib"
                  (chat query &optional members-filter &rest args))
(declare-function telega--searchStickers "telega-tdlib"
                  (emojis &rest args))
(declare-function telega--tl-get "telega-core" (obj &rest keys))
(declare-function telega-sticker-emoji "telega-sticker" (sticker &optional no-props))
(declare-function telega--searchChatsOnServer "telega-tdlib"
                  (query &optional limit callback))
(declare-function telega--searchChatMessages "telega-tdlib"
                  (chat tdlib-msg-filter from-msg-id offset
                        &key query limit sender topic callback))
(defvar telega-chat-completing-sort-criteria)
(defvar telega--info)
(defvar telega--chats)
(defvar telega--cached-messages)
(defvar telega-ready-hook)
(defvar telega-chat-update-hook)
(defvar telega-chat-post-message-hook)

(cl-defstruct (etaf-telega-backend-telega
               (:constructor etaf-telega-backend-telega-create))
  callbacks chat-id pending
  (raws (make-hash-table :test #'equal))
  uploads)

(defvar etaf-telega-backend-telega-instances nil
  "Live telega backends observing the shared Telega event stream.")

(defun etaf-telega-backend-telega--time-label (seconds)
  "Return SECONDS as a chat list stamp: time today, weekday this week, date."
  (let ((time (seconds-to-time (or seconds 0))))
    (cond ((null seconds) "")
          ((equal (format-time-string "%F" time) (format-time-string "%F"))
           (format-time-string "%H:%M" time))
          ((< (float-time (time-subtract nil time)) (* 6 24 3600))
           (format-time-string "%a" time))
          (t (format-time-string "%m-%d" time)))))

(defun etaf-telega-backend-telega--kind (chat)
  "Return CHAT's interface kind: `channel', `private' or `group'."
  (cond ((ignore-errors (telega-chat-match-p chat '(type channel))) 'channel)
        ((ignore-errors (telega-chat-match-p chat '(type private))) 'private)
        (t 'group)))

(defun etaf-telega-backend-telega--sender (message)
  "Return MESSAGE's sender title, or the empty string."
  (or (ignore-errors (telega-msg-sender-title (telega-msg-sender message))) ""))

(defvar etaf-telega-backend-telega--downloads (make-hash-table :test #'eql)
  "Ids of Telega files whose download this client has requested.")

(defun etaf-telega-backend-telega--minithumb (minithumbnail)
  "Return MINITHUMBNAIL as an in-memory JPEG image descriptor, or nil."
  (when-let* ((data (plist-get minithumbnail :data))
              ((stringp data))
              (bytes (ignore-errors (base64-decode-string data))))
    (list 'image :type 'jpeg :data bytes)))

(defun etaf-telega-backend-telega--file-source (place prop &optional on-ready)
  "Return the local path of the Telega file at PLACE's PROP, or nil.
A missing file starts downloading once; ON-READY runs when it is local."
  (when-let* ((file (and place (ignore-errors (telega-file--renew place prop)))))
    (if (telega-file--downloaded-p file)
        (plist-get (plist-get file :local) :path)
      (let ((id (plist-get file :id)))
        (when (and id on-ready
                   (not (gethash id etaf-telega-backend-telega--downloads))
                   (telega-file--can-download-p file))
          (puthash id t etaf-telega-backend-telega--downloads)
          (telega-file--download
           file :priority 16
           :update-callback
           (lambda (updated)
             (when (telega-file--downloaded-p updated)
               (funcall on-ready))))))
      nil)))

(defun etaf-telega-backend-telega--position (chat)
  "Return CHAT's main or archive chat list position, or nil."
  (let (main archive)
    (seq-doseq (position (plist-get chat :positions))
      (pcase (plist-get (plist-get position :list) :@type)
        ("chatListMain" (setq main position))
        ("chatListArchive" (setq archive position))))
    (let ((position (or main archive)))
      (and position (not (equal (plist-get position :order) "0"))
           position))))

(defun etaf-telega-backend-telega--draft-text (chat)
  "Return CHAT's text draft, or \"\"."
  (let* ((content (plist-get (plist-get chat :draft_message) :content))
         (text (and content (plist-get content :text))))
    (or (and text (telega-tl-str text :text)) "")))

(defun etaf-telega-backend-telega--can-post-p (chat)
  "Return non-nil when the current user may send messages to CHAT.
TDLib checks the same local permissions when a send arrives, so a broadcast
channel the user does not administer is refused here before any request."
  (and chat
       (ignore-errors (telega-chat-match-p chat 'can-send-or-post))
       t))

(defun etaf-telega-backend-telega--project-chat (chat &optional position)
  "Return CHAT's projection plist at chat list POSITION."
  (let* ((last (plist-get chat :last_message))
         (position (or position (etaf-telega-backend-telega--position chat)))
         (kind (etaf-telega-backend-telega--kind chat))
         (text (or (and last (ignore-errors (telega-msg-content-text last))) "")))
    (list :id (plist-get chat :id)
          :title (or (ignore-errors (telega-chat-title chat)) "?")
          :preview text
          :author (and last (eq kind 'group)
                       (if (eq t (plist-get last :is_outgoing))
                           "我"
                         (etaf-telega-backend-telega--sender last)))
          :unread (or (plist-get chat :unread_count) 0)
          :pinned (eq t (plist-get position :is_pinned))
          :muted (and (ignore-errors (telega-chat-muted-p chat)) t)
          :kind kind
          :archived (equal (plist-get (plist-get position :list) :@type)
                           "chatListArchive")
          :mention (or (plist-get chat :unread_mention_count) 0)
          :draft (etaf-telega-backend-telega--draft-text chat)
          :last-read (or (plist-get chat :last_read_inbox_message_id) 0)
          :pinned-id (let ((id (plist-get chat :pinned_message_id)))
                       (and (natnump id) (> id 0) id))
          :online (and (ignore-errors
                        (telega-user-online-p (telega-chat--info-locally chat)))
                       t)
          :can-post (etaf-telega-backend-telega--can-post-p chat)
          :username (or (ignore-errors
                         (telega-tl-str (telega-chat--info-locally chat) :username))
                        "")
          :members (and (memq kind '(group channel))
                        (let ((count (ignore-errors
                                       (plist-get (telega-chat--info-locally chat)
                                                  :member_count))))
                          (and (natnump count) (> count 0) count)))
          :time (if last
                    (etaf-telega-backend-telega--time-label (plist-get last :date))
                  "")
          :order (string-to-number (or (plist-get position :order) "0"))
          :photo (etaf-telega-backend-telega--file-source
                  (plist-get chat :photo) :small
                  #'etaf-telega-backend-telega--schedule-chats))))

(defun etaf-telega-backend-telega--raw (backend chat-id id)
  "Return the raw TDLib message ID of CHAT-ID known to BACKEND or Telega."
  (let ((key (cons chat-id id)))
    (or (and (hash-table-p telega--cached-messages)
             (gethash key telega--cached-messages))
        (gethash key (etaf-telega-backend-telega-raws backend)))))

(defvar etaf-telega-backend-telega--quote-requests (make-hash-table :test #'equal)
  "Messages whose quoted message was requested from TDLib, by (CHAT . ID).")

(defun etaf-telega-backend-telega--quoted (backend message)
  "Return the raw message MESSAGE replies to, or nil while unknown.
An unloaded quote is requested once; MESSAGE is reported again when it
arrives, so its reply preview appears without a placeholder."
  (let* ((reply-to (plist-get message :reply_to))
         (reply-id (plist-get reply-to :message_id))
         (chat-id (plist-get message :chat_id))
         (quote-chat (let ((id (plist-get reply-to :chat_id)))
                       (if (and (numberp id) (/= id 0)) id chat-id))))
    (when (and reply-id (/= reply-id 0))
      (or (etaf-telega-backend-telega--raw backend quote-chat reply-id)
          (let ((key (cons chat-id (plist-get message :id))))
            (unless (gethash key etaf-telega-backend-telega--quote-requests)
              (puthash key t etaf-telega-backend-telega--quote-requests)
              (ignore-errors
                (telega--getRepliedMessage message
                  (lambda (quoted)
                    (when (equal (plist-get quoted :@type) "message")
                      (puthash (cons (plist-get quoted :chat_id)
                                     (plist-get quoted :id))
                               quoted (etaf-telega-backend-telega-raws backend))
                      (etaf-telega-backend-telega--media-ready
                       backend chat-id (cdr key)))))))
            nil)))))

(defun etaf-telega-backend-telega--project-message (backend message)
  "Return MESSAGE's projection plist and remember MESSAGE in BACKEND.
The raw message stays available to Telega's own commands run through
`etaf-telega-backend-native'."
  (let* ((chat-id (plist-get message :chat_id))
         (date (seconds-to-time (or (plist-get message :date) 0)))
         (edit-date (plist-get message :edit_date))
         (quoted (etaf-telega-backend-telega--quoted backend message)))
    (puthash (cons chat-id (plist-get message :id)) message
             (etaf-telega-backend-telega-raws backend))
    (list :id (plist-get message :id)
          :outgoing (eq t (plist-get message :is_outgoing))
          :sender (etaf-telega-backend-telega--sender message)
          :time (format-time-string "%H:%M" date)
          :date (format-time-string "%Y-%m-%d" date)
          :edited (and (numberp edit-date) (> edit-date 0))
          :kind (etaf-telega-backend-telega--message-kind message)
          :file (etaf-telega-backend-telega--message-file message)
          :link (etaf-telega-backend-telega--message-link message)
          :media (etaf-telega-backend-telega--message-media backend message)
          :avatar (etaf-telega-backend-telega--sender-photo backend message)
          :reactions (etaf-telega-backend-telega--reactions message)
          :duration (etaf-telega-backend-telega--duration message)
          :views (let ((count (ignore-errors
                                (plist-get (plist-get message :interaction_info)
                                           :view_count))))
                   (and (numberp count) (> count 0) count))
          :reply (and quoted
                      (list :id (plist-get quoted :id)
                            :sender (etaf-telega-backend-telega--sender quoted)
                            :kind (etaf-telega-backend-telega--message-kind quoted)
                            :text (or (ignore-errors
                                        (telega-msg-content-text quoted))
                                      "")))
          :text (or (ignore-errors (telega-msg-content-text message)) ""))))

(defconst etaf-telega-backend-telega--custom-reaction-prefix "custom:"
  "Prefix of the reaction key naming a custom emoji by its TDLib id.
An interface reaction key is a scalar ETAF identity, so a custom emoji is
reported as a `custom:'-prefixed id rather than as an emoji: the id is not a
glyph.")

(defun etaf-telega-backend-telega--reaction-key (type)
  "Return the interface key of TDLib reaction TYPE, or nil."
  (pcase (plist-get type :@type)
    ("reactionTypeEmoji" (telega-tl-str type :emoji 'no-properties))
    ("reactionTypeCustomEmoji"
     (concat etaf-telega-backend-telega--custom-reaction-prefix
             (format "%s" (plist-get type :custom_emoji_id))))
    ("reactionTypePaid" 'paid)))

(defun etaf-telega-backend-telega--reaction-label (key)
  "Return the chip label of interface reaction KEY."
  (cond ((and (stringp key)
              (string-prefix-p etaf-telega-backend-telega--custom-reaction-prefix
                               key))
         "✦")
        ((stringp key) key)
        ((eq key 'paid) "⭐")
        (t "✦")))

(defun etaf-telega-backend-telega--reactions (message)
  "Return MESSAGE's reactions as (:key :label :count :chosen) plists."
  (let (result)
    (seq-doseq (reaction (ignore-errors
                           (plist-get (plist-get (plist-get message :interaction_info)
                                                 :reactions)
                                      :reactions)))
      (when-let* ((key (etaf-telega-backend-telega--reaction-key
                        (plist-get reaction :type))))
        (push (list :key key
                    :label (etaf-telega-backend-telega--reaction-label key)
                    :count (or (plist-get reaction :total_count) 0)
                    :chosen (eq t (plist-get reaction :is_chosen)))
              result)))
    (nreverse result)))

(defun etaf-telega-backend-telega--duration (message)
  "Return the playing time in seconds of MESSAGE's media, or nil."
  (let ((content (plist-get message :content)))
    (ignore-errors
      (pcase (plist-get content :@type)
        ("messageVideo" (plist-get (plist-get content :video) :duration))
        ("messageAnimation" (plist-get (plist-get content :animation) :duration))
        ("messageVoiceNote" (plist-get (plist-get content :voice_note) :duration))
        ("messageAudio" (plist-get (plist-get content :audio) :duration))))))

(defun etaf-telega-backend-telega--full-file (message)
  "Return (PLACE . PROP) of MESSAGE's full-size media file, or nil."
  (let ((content (plist-get message :content)))
    (pcase (plist-get content :@type)
      ("messagePhoto"
       (let (best)
         (seq-doseq (size (plist-get (plist-get content :photo) :sizes))
           (when (or (null best)
                     (> (* (or (plist-get size :width) 0) (or (plist-get size :height) 0))
                        (* (or (plist-get best :width) 0) (or (plist-get best :height) 0))))
             (setq best size)))
         (and best (cons best :photo))))
      ("messageVideo" (cons (plist-get content :video) :video))
      ("messageAnimation" (cons (plist-get content :animation) :animation))
      ("messageSticker" (cons (plist-get content :sticker) :sticker))
      ("messageDocument" (cons (plist-get content :document) :document))
      ("messageVoiceNote" (cons (plist-get content :voice_note) :voice))
      ("messageAudio" (cons (plist-get content :audio) :audio)))))

(defun etaf-telega-backend-telega--message-kind (message)
  "Return MESSAGE's content kind for the interface."
  (cond ((ignore-errors (telega-msg-match-p message '(type Photo))) 'photo)
        ((ignore-errors (telega-msg-match-p message '(type Video))) 'video)
        ((ignore-errors (telega-msg-match-p message '(type Animation))) 'animation)
        ((ignore-errors (telega-msg-match-p message '(type VoiceNote))) 'voice)
        ((ignore-errors (telega-msg-match-p message '(type Audio))) 'audio)
        ((ignore-errors (telega-msg-match-p message '(type Sticker))) 'sticker)
        ((ignore-errors (telega-msg-match-p message '(type Document))) 'file)
        (t 'text)))

(defun etaf-telega-backend-telega--media-ready (backend chat-id id)
  "Report message ID of CHAT-ID again to BACKEND once its media is local."
  (when (and (memq backend etaf-telega-backend-telega-instances)
             (equal (etaf-telega-backend-telega-chat-id backend) chat-id))
    (etaf-telega-backend-telega--guard
     backend "加载媒体"
     (lambda ()
       (when-let* ((raw (etaf-telega-backend-telega--raw backend chat-id id))
                   (report (plist-get (etaf-telega-backend-telega-callbacks backend)
                                      :updated)))
         (funcall report (etaf-telega-backend-telega--project-message
                          backend raw)))))))

(defun etaf-telega-backend-telega--senders-ready (backend chat-id sender)
  "Report BACKEND's loaded CHAT-ID messages from SENDER again."
  (when (and (memq backend etaf-telega-backend-telega-instances)
             (equal (etaf-telega-backend-telega-chat-id backend) chat-id))
    (let (ids)
      (maphash (lambda (key raw)
                 (when (and (equal (car key) chat-id)
                            (equal (plist-get raw :sender_id) sender))
                   (push (cdr key) ids)))
               (etaf-telega-backend-telega-raws backend))
      (dolist (id ids)
        (etaf-telega-backend-telega--media-ready backend chat-id id)))))

(defun etaf-telega-backend-telega--sender-photo (backend message)
  "Return the image source of MESSAGE's sender photo, or nil."
  (let* ((sender-id (plist-get message :sender_id))
         (chat-id (plist-get message :chat_id))
         (sender (ignore-errors (telega-msg-sender message)))
         (photo (or (plist-get sender :profile_photo) (plist-get sender :photo))))
    (and photo
         (etaf-telega-backend-telega--file-source
          photo :small
          (lambda ()
            (etaf-telega-backend-telega--senders-ready backend chat-id sender-id))))))

(defun etaf-telega-backend-telega--thumbnail (owner ready)
  "Return (SRC WIDTH HEIGHT) of OWNER's displayable thumbnail.
READY runs once a missing thumbnail file becomes local."
  (let* ((thumb (plist-get owner :thumbnail))
         (format (plist-get (plist-get thumb :format) :@type))
         (src (and (member format '("thumbnailFormatJpeg" "thumbnailFormatPng"
                                    "thumbnailFormatWebp" "thumbnailFormatGif"))
                   (etaf-telega-backend-telega--file-source thumb :file ready))))
    (list (or src (etaf-telega-backend-telega--minithumb
                   (plist-get owner :minithumbnail)))
          (or (plist-get owner :width) (plist-get thumb :width))
          (or (plist-get owner :height) (plist-get thumb :height)))))

(defun etaf-telega-backend-telega--message-media (backend message)
  "Return MESSAGE's visual media (:src :width :height), or nil."
  (let* ((content (plist-get message :content))
         (chat-id (plist-get message :chat_id))
         (id (plist-get message :id))
         (ready (lambda ()
                  (etaf-telega-backend-telega--media-ready backend chat-id id)))
         (found
          (ignore-errors
            (pcase (plist-get content :@type)
              ("messagePhoto"
               (let* ((photo (plist-get content :photo))
                      (size (telega-photo--best photo)))
                 (list (or (etaf-telega-backend-telega--file-source size :photo ready)
                           (etaf-telega-backend-telega--minithumb
                            (plist-get photo :minithumbnail)))
                       (plist-get size :width) (plist-get size :height))))
              ("messageVideo"
               (etaf-telega-backend-telega--thumbnail (plist-get content :video) ready))
              ("messageAnimation"
               (etaf-telega-backend-telega--thumbnail
                (plist-get content :animation) ready))
              ("messageSticker"
               (let ((sticker (plist-get content :sticker)))
                 (if (and (equal (plist-get (plist-get sticker :format) :@type)
                                 "stickerFormatWebp")
                          (image-type-available-p 'webp))
                     (list (etaf-telega-backend-telega--file-source
                            sticker :sticker ready)
                           (plist-get sticker :width) (plist-get sticker :height))
                   (etaf-telega-backend-telega--thumbnail sticker ready))))))))
    (when (and found (natnump (nth 1 found)) (natnump (nth 2 found))
               (> (nth 1 found) 0) (> (nth 2 found) 0))
      (list :src (nth 0 found) :width (nth 1 found) :height (nth 2 found)))))

(defun etaf-telega-backend-telega--message-file (message)
  "Return MESSAGE's document (:name :size) when it carries one."
  (let ((document (ignore-errors (plist-get (plist-get message :content) :document))))
    (when document
      (list :name (or (plist-get document :file_name) "")
            :size (or (plist-get document :file_size) 0)))))

(defun etaf-telega-backend-telega--message-link (message)
  "Return MESSAGE's web page (:site :title) when it carries one."
  (let ((page (ignore-errors (plist-get (plist-get message :content) :web_page))))
    (when page
      (list :site (or (plist-get page :site_name) "")
            :title (or (plist-get page :title) "")
            :description (or (plist-get page :description) "")))))

(defun etaf-telega-backend-telega--chats ()
  "Return the main list then the archive as projections, in server order."
  (let (result)
    (maphash (lambda (_id chat)
               (when-let* ((position (etaf-telega-backend-telega--position chat)))
                 (push (etaf-telega-backend-telega--project-chat chat position)
                       result)))
             telega--chats)
    (sort result (lambda (a b)
                   (if (eq (plist-get a :archived) (plist-get b :archived))
                       (> (plist-get a :order) (plist-get b :order))
                     (plist-get b :archived))))))

(cl-defun etaf-telega-backend-telega--report (backend &key status chats me error)
  "Report BACKEND's current facts through its callbacks.
Only the supplied keys are reported; STATUS and CHATS are recomputed when
requested so every live backend sees the shared Telega state."
  (let ((callbacks (etaf-telega-backend-telega-callbacks backend)))
    (when (and status (plist-get callbacks :status))
      (funcall (plist-get callbacks :status) status))
    (when (and me (plist-get callbacks :me))
      (funcall (plist-get callbacks :me) me))
    (when (and chats (plist-get callbacks :chats))
      (funcall (plist-get callbacks :chats)
               (etaf-telega-backend-telega--chats)))
    (when (and error (plist-get callbacks :error))
      (funcall (plist-get callbacks :error) error))))

(defun etaf-telega-backend-telega--guard (backend label function)
  "Call FUNCTION for BACKEND, reporting failures as readable status text.
These entry points run inside Telega's command dispatch and TDLib callbacks;
an escaping error makes Telega print the whole failing command, including
message bodies, to the echo area and can hang Emacs on a large payload.  The
failure reaches the application as a clipped status line instead."
  (condition-case err
      (funcall function)
    ((error quit)
     (let ((text (error-message-string err)))
       (etaf-telega-backend-telega--report
        backend :error
        (format "%s：%s" label
                (if (> (length text) 120)
                    (concat (substring text 0 120) "…")
                  text)))))))

(defun etaf-telega-backend-telega--ready ()
  "Report readiness to every live telega backend."
  (when etaf-telega-backend-telega--chats-timer
    (cancel-timer etaf-telega-backend-telega--chats-timer)
    (setq etaf-telega-backend-telega--chats-timer nil))
  (dolist (backend etaf-telega-backend-telega-instances)
    (etaf-telega-backend-telega--guard
     backend "连接就绪"
     (lambda ()
       (when-let* ((me (ignore-errors (telega-user-me))))
         (etaf-telega-backend-telega--report
          backend :me
          (list :id (plist-get me :id)
                :name (or (ignore-errors (telega-msg-sender-title me)) "")
                :username (etaf-telega-backend-telega--username me))))
       (etaf-telega-backend-telega--report backend :status "就绪" :chats t)))))

(defun etaf-telega-backend-telega--username (user)
  "Return USER's first active username, or nil."
  (or (telega-tl-str user :username)
      (let ((active (plist-get (plist-get user :usernames) :active_usernames)))
        (cond ((and (vectorp active) (> (length active) 0)) (aref active 0))
              ((consp active) (car active))))))

(defvar etaf-telega-backend-telega--chats-timer nil
  "Pending chat-list refresh; a TDLib sync storm becomes one report.")

(defun etaf-telega-backend-telega--flush-chats ()
  "Report the current chat list to every live backend."
  (setq etaf-telega-backend-telega--chats-timer nil)
  (dolist (backend etaf-telega-backend-telega-instances)
    (when-let* ((callbacks (etaf-telega-backend-telega-callbacks backend))
                (report (plist-get callbacks :chats)))
      (funcall report (etaf-telega-backend-telega--chats)))))

(defun etaf-telega-backend-telega--schedule-chats ()
  "Coalesce chat updates into one refreshed list per window."
  (unless etaf-telega-backend-telega--chats-timer
    (setq etaf-telega-backend-telega--chats-timer
          (run-at-time 0.15 nil #'etaf-telega-backend-telega--flush-chats))))

(defun etaf-telega-backend-telega--chat-update (_chat)
  "Schedule a chat-list refresh for every live telega backend.
The message list of an open chat is maintained by
`etaf-telega-backend-telega--message' instead of reloading its history."
  (etaf-telega-backend-telega--schedule-chats))

(defun etaf-telega-backend-telega--message (message)
  "Report a later MESSAGE to every backend viewing its chat.
An outgoing message that matches a pending send or an upload confirms it
through `:sent'; every other message reaches the application through
`:message'.  Telega only posts messages that are already sent, so an
upload reports its confirmation from here: the send callback's own answer
is the local copy TDLib replaces once the upload finishes."
  (let ((chat-id (plist-get message :chat_id)))
    (dolist (backend etaf-telega-backend-telega-instances)
      (when (equal (etaf-telega-backend-telega-chat-id backend) chat-id)
        (etaf-telega-backend-telega--guard
         backend "接收消息"
         (lambda ()
           (let* ((callbacks (etaf-telega-backend-telega-callbacks backend))
                  (projected (etaf-telega-backend-telega--project-message
                              backend message))
                  (pending (etaf-telega-backend-telega-pending backend))
                  (text (plist-get projected :text))
                  (record (cl-find text pending
                                   :key (lambda (item) (plist-get item :text))
                                   :test #'equal))
                  (file (plist-get (plist-get projected :file) :name))
                  (upload (and file (plist-get projected :outgoing)
                               (cl-find file (etaf-telega-backend-telega-uploads backend)
                                        :key (lambda (item) (plist-get item :name))
                                        :test #'equal)))
                  (ack (and (plist-get projected :outgoing) (or record upload))))
             (if ack
                 (progn
                   (when record
                     (setf (etaf-telega-backend-telega-pending backend)
                           (delq record pending)))
                   (when upload
                     (setf (etaf-telega-backend-telega-uploads backend)
                           (delq upload (etaf-telega-backend-telega-uploads backend))))
                   (when-let* ((report (plist-get callbacks :sent)))
                     (funcall report
                              (append projected
                                      (when (plist-get record :reply)
                                        (list :reply (plist-get record :reply)))))))
               (when-let* ((report (plist-get callbacks :message)))
                 (funcall report projected))))))))))

(defun etaf-telega-backend-telega--send-failed (event)
  "Report a failed message send to every backend viewing its chat.
The text stays pending, so a later retry that succeeds still confirms the
draft normally; the failure only reaches the status line."
  (let* ((message (plist-get event :message))
         (chat-id (plist-get message :chat_id))
         (detail (or (plist-get (plist-get event :error) :message) "未知原因")))
    (dolist (backend etaf-telega-backend-telega-instances)
      (when (equal (etaf-telega-backend-telega-chat-id backend) chat-id)
        (etaf-telega-backend-telega--guard
         backend "发送失败"
         (lambda ()
           (etaf-telega-backend-telega--report
            backend :error (format "发送失败：%s" detail))))))))

(cl-defmethod etaf-telega-backend-chat-candidates ((_backend etaf-telega-backend-telega))
  "Return Telega's known chats and contacts in its completion order."
  (let* ((chats (telega-sort-chats
                 telega-chat-completing-sort-criteria
                 (telega-filter-chats (hash-table-values telega--chats) 'is-known)))
         (users (cl-remove-if-not
                 (lambda (user)
                   (and (plist-get user :is_contact)
                        (not (memq (telega-user-chat user) chats))))
                 (hash-table-values (alist-get 'user telega--info)))))
    (append (mapcar (lambda (chat)
                      (list :id (plist-get chat :id)
                            :title (telega-chat-title chat)))
                    chats)
            (mapcar (lambda (user)
                      (list :id (plist-get user :id)
                            :title (telega-msg-sender-title user)))
                    users))))

(cl-defmethod etaf-telega-backend-ensure-chat ((_backend etaf-telega-backend-telega)
                                               id)
  "Return conversation ID, creating a contact's private chat when needed."
  (or (telega-chat-get id 'offline)
      (when-let* ((user (telega-user-get id)))
        (telega--createPrivateChat user))))

(cl-defmethod etaf-telega-backend-save-draft ((_backend etaf-telega-backend-telega)
                                              chat-id text)
  "Store TEXT as CHAT-ID's draft through Telega; empty TEXT clears it."
  (when-let* ((chat (telega-chat-get chat-id)))
    (if (string-empty-p text)
        (telega--setChatDraftMessage chat)
      (telega--setChatDraftMessage
       chat (list :@type "draftMessage"
                  :content (list :@type "draftMessageContentText"
                                 :text (list :@type "formattedText" :text text)))))))

(cl-defmethod etaf-telega-backend-search-chats ((backend etaf-telega-backend-telega)
                                                query callback)
  "Report Telega's server-side matches for QUERY."
  (when (and query (not (string-empty-p (string-trim query))))
    (telega--searchChatsOnServer
     query 30
     (lambda (chats)
       (etaf-telega-backend-telega--guard
        backend "搜索会话"
        (lambda ()
          (funcall callback
                   (mapcar (lambda (chat)
                             (etaf-telega-backend-telega--project-chat chat))
                           (delq nil (append chats nil))))))))))

(cl-defmethod etaf-telega-backend-search-messages ((backend etaf-telega-backend-telega)
                                                   query callback)
  "Report Telega's matches for QUERY in the selected chat's history."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (chat (and chat-id (telega-chat-get chat-id))))
    (when (and chat query (not (string-empty-p (string-trim query))))
      (telega--searchChatMessages
       chat (list :@type "searchMessagesFilterEmpty") 0 0
       :query query :limit 50
       :callback
       (lambda (reply)
         (etaf-telega-backend-telega--guard
          backend "搜索消息"
          (lambda ()
            (funcall callback
                     (mapcar (lambda (message)
                               (etaf-telega-backend-telega--project-message
                                backend message))
                             (append (plist-get reply :messages) nil))))))))))

(cl-defmethod etaf-telega-backend-pinned-message ((backend etaf-telega-backend-telega)
                                                  chat-id callback)
  "Report CHAT-ID's newest pinned message id from Telega's server data.
The pinned filter answers with an empty list when nothing is pinned, so the
callback runs either way."
  (if-let* ((chat (telega-chat-get chat-id)))
      (telega--searchChatMessages
       chat (list :@type "searchMessagesFilterPinned") 0 0
       :query nil :limit 1
       :callback
       (lambda (reply)
         (etaf-telega-backend-telega--guard
          backend "置顶消息"
          (lambda ()
            (funcall callback
                     (plist-get (car (append (plist-get reply :messages) nil)) :id))))))
    (funcall callback nil)))

(cl-defmethod etaf-telega-backend-start ((backend etaf-telega-backend-telega)
                                         callbacks)
  "Start Telega's server if needed and observe CALLBACKS.
The root buffer is created without being displayed; Telega keeps owning the
account and its database."
  (setf (etaf-telega-backend-telega-callbacks backend) callbacks)
  (add-to-list 'etaf-telega-backend-telega-instances backend)
  (condition-case err
      (progn
        (require 'telega)
        (add-hook 'telega-ready-hook #'etaf-telega-backend-telega--ready)
        (add-hook 'telega-chat-update-hook #'etaf-telega-backend-telega--chat-update)
        (add-hook 'telega-chat-post-message-hook #'etaf-telega-backend-telega--message)
        (dolist (advice etaf-telega-backend-telega--advices)
          (advice-add (nth 0 advice) (nth 1 advice) (nth 2 advice)))
        (if (telega-server-live-p)
            (etaf-telega-backend-telega--ready)
          (telega '(4))))
    (error (when-let* ((report (plist-get callbacks :error)))
             (funcall report (error-message-string err)))))
  backend)

(cl-defmethod etaf-telega-backend-select ((backend etaf-telega-backend-telega)
                                          chat-id)
  "Load CHAT-ID's newest history page through Telega and read it."
  (setf (etaf-telega-backend-telega-chat-id backend) chat-id)
  (clrhash (etaf-telega-backend-telega-raws backend))
  (let ((callbacks (etaf-telega-backend-telega-callbacks backend)))
    (condition-case err
        (when-let* ((chat (telega-chat-get chat-id)))
          (telega--getChatHistory
           chat 0 0 50 nil
           (lambda (event)
             (etaf-telega-backend-telega--guard
              backend "加载会话历史"
              (lambda ()
                (let ((messages (append (plist-get event :messages) nil)))
                  (when-let* ((report (plist-get callbacks :messages)))
                    (funcall report
                             (mapcar (lambda (message)
                                       (etaf-telega-backend-telega--project-message
                                        backend message))
                                     messages)))
                  ;; Opening a conversation reads its loaded page, exactly like
                  ;; Telega's own chat buffer.
                  (when messages
                    (ignore-errors
                      (telega--viewMessages
                       chat messages :source '(:@type "messageSourceChatHistory"))))))))))
      (error (when-let* ((report (plist-get callbacks :error)))
               (funcall report (error-message-string err)))))))

(cl-defmethod etaf-telega-backend-history ((backend etaf-telega-backend-telega)
                                           &key before limit)
  "Load a page older than BEFORE in the selected Telega chat."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (callbacks (etaf-telega-backend-telega-callbacks backend))
         (chat (and chat-id (telega-chat-get chat-id))))
    (condition-case err
        (when chat
          (telega--getChatHistory
           chat (or before 0) 0 (or limit 50) nil
           (lambda (event)
             (etaf-telega-backend-telega--guard
              backend "加载更早历史"
              (lambda ()
                (when-let* ((report (plist-get callbacks :older)))
                  (funcall report
                           (mapcar (lambda (message)
                                     (etaf-telega-backend-telega--project-message
                                      backend message))
                                   (append (plist-get event :messages) nil)))))))))
      (error (etaf-telega-backend-telega--report
              backend :error (error-message-string err))))))

(cl-defmethod etaf-telega-backend-around ((backend etaf-telega-backend-telega)
                                          message-id &key limit)
  "Load MESSAGE-ID's page through Telega, newest first."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (callbacks (etaf-telega-backend-telega-callbacks backend))
         (chat (and chat-id (telega-chat-get chat-id))))
    (condition-case err
        (when chat
          (telega--getChatHistory
           chat message-id 0 (or limit 50) nil
           (lambda (event)
             (etaf-telega-backend-telega--guard
              backend "跳转消息"
              (lambda ()
                (when-let* ((report (plist-get callbacks :jump)))
                  (funcall report
                           (mapcar (lambda (message)
                                     (etaf-telega-backend-telega--project-message
                                      backend message))
                                   (append (plist-get event :messages) nil)))))))))
      (error (etaf-telega-backend-telega--report
              backend :error (error-message-string err))))))

(cl-defmethod etaf-telega-backend-date-message ((backend etaf-telega-backend-telega)
                                                date)
  "Load the message at DATE through Telega, newest first."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (callbacks (etaf-telega-backend-telega-callbacks backend))
         (chat (and chat-id (telega-chat-get chat-id))))
    (condition-case err
        (when chat
          (telega--getChatMessageByDate
           chat (round date)
           (lambda (message)
             (etaf-telega-backend-telega--guard
              backend "跳到日期"
              (lambda ()
                (when-let* ((report (plist-get callbacks :jump)))
                  (funcall report
                           (delq nil
                                 (list (when message
                                         (etaf-telega-backend-telega--project-message
                                          backend message)))))))))))
      (error (etaf-telega-backend-telega--report
              backend :error (error-message-string err))))))

(cl-defmethod etaf-telega-backend-read ((backend etaf-telega-backend-telega)
                                        message-ids)
  "Accept MESSAGE-IDS as read through Telega."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (callbacks (etaf-telega-backend-telega-callbacks backend))
         (chat (and chat-id (telega-chat-get chat-id))))
    (when (and chat message-ids)
      (condition-case err
          (progn
            (telega--viewMessages
             chat (mapcar (lambda (id) (list :chat_id chat-id :id id)) message-ids)
             :source '(:@type "messageSourceChatHistory"))
            (when-let* ((report (plist-get callbacks :read)))
              (funcall report (copy-sequence message-ids))))
        (error (etaf-telega-backend-telega--report
                backend :error (error-message-string err)))))))

(cl-defmethod etaf-telega-backend-send ((backend etaf-telega-backend-telega)
                                        text &optional reply-to options)
  "Send TEXT to the selected Telega chat, replying to REPLY-TO.
OPTIONS add a silent send, a disabled link preview, a scheduled date or
Markdown parsing.  Telega confirms the message asynchronously through its
message hook, so the draft stays until `etaf-telega-backend-telega--message'
accepts it; immediate failures are reported without keeping a half-send."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (chat (and chat-id (telega-chat-get chat-id)))
         (imc (list :@type "inputMessageText"
                    :text (if (plist-get options :markdown)
                              (telega-markup-markdown2-fmt text)
                            (list :@type "formattedText" :text text))
                    :link_preview_options
                    (when (plist-get options :no-preview)
                      (list :@type "linkPreviewOptions" :is_disabled t))))
         (send-options (append (when (plist-get options :silent)
                                 (list :disable_notification t))
                               (when (plist-get options :at)
                                 (list :scheduling_state
                                       (list :@type "messageSchedulingStateSendAtDate"
                                             :send_date (round (plist-get options :at)))))))
         (send-options (when send-options
                         (cons :@type (cons "messageSendOptions" send-options)))))
    (unless chat
      (error "没有选中的对话"))
    (unless (etaf-telega-backend-telega--can-post-p chat)
      (error "当前对话不能发言"))
    (push (list :text text :reply reply-to)
          (etaf-telega-backend-telega-pending backend))
    (condition-case err
        ;; Telega's own sends wait for the answer, so a message refused right
        ;; away (permissions, invalid input) reaches this handler instead of
        ;; only printing a server error and leaving the draft pending forever.
        (telega--sendMessage
         chat imc
         (when reply-to
           (list :@type "inputMessageReplyToMessage"
                 :message_id (plist-get reply-to :id) :quote nil))
         send-options
         :sync-p t)
      (error
       (setf (etaf-telega-backend-telega-pending backend)
             (cl-remove text (etaf-telega-backend-telega-pending backend)
                        :key (lambda (item) (plist-get item :text)) :test #'equal))
       (etaf-telega-backend-telega--report
        backend :error (error-message-string err))))
    text))

(defun etaf-telega-backend-telega--error-p (result)
  "Return non-nil when RESULT is a TDLib error object."
  (equal (plist-get result :@type) "error"))

(cl-defmethod etaf-telega-backend-edit ((backend etaf-telega-backend-telega)
                                        message text)
  "Replace MESSAGE's text with TEXT through Telega."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (callbacks (etaf-telega-backend-telega-callbacks backend))
         (target (list :chat_id chat-id :id (plist-get message :id))))
    (condition-case err
        (telega--editMessageText
         target (list :@type "inputMessageText"
                      :text (list :@type "formattedText" :text text))
         :callback
         (lambda (result)
           (etaf-telega-backend-telega--guard
            backend "编辑消息"
            (lambda ()
              (cond
               ((etaf-telega-backend-telega--error-p result)
                (etaf-telega-backend-telega--report
                 backend :error
                 (format "编辑失败：%s" (plist-get result :message))))
               (t (when-let* ((report (plist-get callbacks :edited)))
                    (funcall report
                             (etaf-telega-backend-telega--project-message
                              backend result)))))))))
      (error (etaf-telega-backend-telega--report
              backend :error (error-message-string err))))
    text))

(cl-defmethod etaf-telega-backend-react ((backend etaf-telega-backend-telega)
                                         message-id key)
  "Toggle reaction KEY on MESSAGE-ID through Telega.
TDLib answers with an interaction update, reported as `:updated'."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (raw (etaf-telega-backend-telega--raw backend chat-id message-id))
         (custom-p (and (stringp key)
                        (string-prefix-p
                         etaf-telega-backend-telega--custom-reaction-prefix key)))
         (type (cond (custom-p
                      (list :@type "reactionTypeCustomEmoji"
                            :custom_emoji_id
                            (substring key
                                       (length
                                        etaf-telega-backend-telega--custom-reaction-prefix))))
                     ((stringp key)
                      (list :@type "reactionTypeEmoji" :emoji key))))
         (chosen (cl-find key (etaf-telega-backend-telega--reactions raw)
                          :key (lambda (item) (plist-get item :key)) :test #'equal)))
    (etaf-telega-backend-telega--guard
     backend "表情回应"
     (lambda ()
       (unless (and raw type)
         (error "无法回应这条消息"))
       (if (plist-get chosen :chosen)
           (telega--removeMessageReaction raw type)
         (telega--addMessageReaction raw type))))
    key))

(cl-defmethod etaf-telega-backend-media ((backend etaf-telega-backend-telega)
                                         message-id callback)
  "Download MESSAGE-ID's full media through Telega, reporting progress."
  (let* ((chat-id (etaf-telega-backend-telega-chat-id backend))
         (raw (etaf-telega-backend-telega--raw backend chat-id message-id))
         (where (and raw (etaf-telega-backend-telega--full-file raw)))
         (file (and where (car where)
                    (ignore-errors (telega-file--renew (car where) (cdr where)))))
         (report (lambda (file)
                   (etaf-telega-backend-telega--guard
                    backend "加载媒体"
                    (lambda ()
                      (if (telega-file--downloaded-p file)
                          (funcall callback 1.0
                                   (plist-get (plist-get file :local) :path))
                        (funcall callback
                                 (telega-file--downloading-progress file) nil)))))))
    (cond ((null file)
           (etaf-telega-backend-telega--report backend :error "这条消息没有媒体文件"))
          ((telega-file--downloaded-p file) (funcall report file))
          (t (funcall report file)
             (telega-file--download file :priority 32 :update-callback report)))))

(defvar-local etaf-telega-backend-telega--target nil
  "The (CHAT . MESSAGE) a native command run from this buffer operates on.
It stays after the command returns so transient suffixes invoked later from
the same buffer still find their target.")

(defun etaf-telega-backend-telega--chat-at (&rest _)
  "Return the current buffer's native command chat, if any."
  (car-safe etaf-telega-backend-telega--target))

(defun etaf-telega-backend-telega--msg-at (&rest _)
  "Return the current buffer's native command message, if any."
  (cdr-safe etaf-telega-backend-telega--target))

(cl-defmethod etaf-telega-backend-native ((backend etaf-telega-backend-telega)
                                          command chat-id &optional message-id)
  "Run Telega's interactive COMMAND with CHAT-ID or MESSAGE-ID at point.
Telega's commands resolve their target through `telega-chat-at' and
`telega-msg-at'; this buffer answers both with the requested objects."
  (let* ((chat (or (ignore-errors (telega-chat-get chat-id 'offline))
                   (user-error "没有这个对话：%s" chat-id)))
         (message (and message-id
                       (or (etaf-telega-backend-telega--raw backend chat-id message-id)
                           (user-error "这条消息尚未载入")))))
    (setq etaf-telega-backend-telega--target (cons chat message))
    (call-interactively command)))

(defun etaf-telega-backend-telega--message-changed (event)
  "Report the message changed by update EVENT to backends viewing its chat."
  (let ((chat-id (plist-get event :chat_id))
        (id (plist-get event :message_id)))
    (dolist (backend etaf-telega-backend-telega-instances)
      (when (equal (etaf-telega-backend-telega-chat-id backend) chat-id)
        (etaf-telega-backend-telega--guard
         backend "更新消息"
         (lambda ()
           (when-let* ((raw (etaf-telega-backend-telega--raw backend chat-id id))
                       (report (plist-get (etaf-telega-backend-telega-callbacks backend)
                                          :updated)))
             ;; Telega patches only messages it displays or caches; keep the
             ;; client's own copy current too.
             (pcase (plist-get event :@type)
               ("updateMessageContent"
                (plist-put raw :content (plist-get event :new_content)))
               ("updateMessageEdited"
                (plist-put raw :edit_date (plist-get event :edit_date)))
               ("updateMessageInteractionInfo"
                (plist-put raw :interaction_info
                           (plist-get event :interaction_info))))
             (funcall report (etaf-telega-backend-telega--project-message
                              backend raw)))))))))

(defun etaf-telega-backend-telega--messages-deleted (event)
  "Report the permanently deleted messages of EVENT to viewing backends."
  (let ((chat-id (plist-get event :chat_id)))
    (when (eq t (plist-get event :is_permanent))
      (dolist (backend etaf-telega-backend-telega-instances)
        (when (equal (etaf-telega-backend-telega-chat-id backend) chat-id)
          (etaf-telega-backend-telega--guard
           backend "删除消息"
           (lambda ()
             (when-let* ((report (plist-get (etaf-telega-backend-telega-callbacks
                                             backend)
                                            :deleted)))
               (seq-doseq (id (plist-get event :message_ids))
                 (remhash (cons chat-id id)
                          (etaf-telega-backend-telega-raws backend))
                 (funcall report id))))))))))

(defconst etaf-telega-backend-telega--advices
  '((telega--on-updateMessageSendFailed :after
                                        etaf-telega-backend-telega--send-failed)
    (telega--on-updateMessageContent :after
                                     etaf-telega-backend-telega--message-changed)
    (telega--on-updateMessageEdited :after
                                    etaf-telega-backend-telega--message-changed)
    (telega--on-updateMessageInteractionInfo
     :after etaf-telega-backend-telega--message-changed)
    (telega--on-updateDeleteMessages :after
                                     etaf-telega-backend-telega--messages-deleted)
    (telega--on-updateFile :after etaf-telega-backend-telega--file-updated)
    (telega-chat-at :before-until etaf-telega-backend-telega--chat-at)
    (telega-msg-at :before-until etaf-telega-backend-telega--msg-at))
  "Advices the Telega backend installs while any instance is live.")

(defun etaf-telega-backend-telega--audio-duration (path)
  "Return the length of the audio file at PATH in seconds, at least 1.
TDLib wants a positive duration for a voice note; the file itself is
probed with ffprobe, and a missing probe falls back to one second."
  (or (ignore-errors
        (with-temp-buffer
          (when (zerop (call-process "ffprobe" nil (current-buffer) nil
                                     "-v" "error"
                                     "-show_entries" "format=duration"
                                     "-of" "default=noprint_wrappers=1:nokey=1"
                                     path))
            (let ((text (string-trim (buffer-string))))
              (unless (string-empty-p text)
                (max 1 (round (string-to-number text))))))))
      1))

(defun etaf-telega-backend-telega--file-imc (kind path caption)
  "Return the input message content for KIND at PATH with CAPTION."
  (let ((ifile (list :@type "inputFileLocal" :path path))
        (text (and caption (not (string-empty-p caption))
                    (list :@type "formattedText" :text caption))))
    (append
     (pcase kind
       ('photo (list :@type "inputMessagePhoto"
                     :photo (list :@type "inputPhoto" :photo ifile)))
       ('video (list :@type "inputMessageVideo"
                     :video (list :@type "inputVideo" :video ifile
                                  :supports_streaming t)))
       ;; A voice note is its own object: a bare input file there makes TDLib
       ;; answer "InputFile is not specified" and the upload never starts.
       ('voice (list :@type "inputMessageVoiceNote"
                     :voice_note (list :@type "inputVoiceNote"
                                       :voice_note ifile
                                       :duration (etaf-telega-backend-telega--audio-duration path)
                                       :waveform (unibyte-string))))
       (_ (list :@type "inputMessageDocument"
                :document (list :@type "inputDocument" :document ifile
                                :disable_content_type_detection :false))))
     (when text (list :caption text)))))

(cl-defmethod etaf-telega-backend-send-file ((backend etaf-telega-backend-telega)
                                             chat-id kind path caption options)
  "Send the file at PATH as KIND through Telega, with CAPTION and OPTIONS."
  (let* ((chat (and chat-id (telega-chat-get chat-id)))
         (name (file-name-nondirectory path))
         (callbacks (etaf-telega-backend-telega-callbacks backend))
         (send-options (let ((silent (plist-get options :silent))
                             (at (plist-get options :at))
                             (flags nil))
                         (when silent (setq flags (list :disable_notification t)))
                         (when at
                           (setq flags (append flags
                                               (list :scheduling_state
                                                     (list :@type "messageSchedulingStateSendAtDate"
                                                           :send_date (round at))))))
                         (when flags
                           (cons :@type (cons "messageSendOptions" flags))))))
    (unless chat (error "没有选中的对话"))
    (unless (etaf-telega-backend-telega--can-post-p chat)
      (error "当前对话不能发言"))
    (let ((record (list :path path :name name :message nil)))
      ;; Record before the round trip, so upload progress can match the file;
      ;; the message is filled in when Telega answers with the local copy.
      (push record (etaf-telega-backend-telega-uploads backend))
      (condition-case err
          (progn
            (setf (plist-get record :message)
                  (telega--sendMessage
                   chat (etaf-telega-backend-telega--file-imc kind path caption)
                   nil send-options
                   :sync-p t))
            (when-let* ((report (plist-get callbacks :upload)))
              (funcall report (list :name name :progress 0))))
        (error
         (setf (etaf-telega-backend-telega-uploads backend)
               (delq record (etaf-telega-backend-telega-uploads backend)))
         (etaf-telega-backend-telega--report
          backend :error (error-message-string err)))))
    path))

(cl-defmethod etaf-telega-backend-cancel-upload ((backend etaf-telega-backend-telega)
                                                 path)
  "Cancel BACKEND's pending upload of PATH by deleting its message."
  (when-let* ((upload (cl-find path (etaf-telega-backend-telega-uploads backend)
                               :key (lambda (item) (plist-get item :path))
                               :test #'equal))
              (message (plist-get upload :message)))
    (setf (etaf-telega-backend-telega-uploads backend)
          (delq upload (etaf-telega-backend-telega-uploads backend)))
    (ignore-errors (telega--deleteMessages (list message) nil)))
  path)

(defun etaf-telega-backend-telega--file-updated (event)
  "Report upload progress of EVENT's file to backends whose uploads match it."
  (let* ((file (plist-get event :file))
         (path (ignore-errors (plist-get (plist-get file :local) :path))))
    (when (and path (stringp path))
      (dolist (backend etaf-telega-backend-telega-instances)
        (dolist (upload (etaf-telega-backend-telega-uploads backend))
          (when (equal path (plist-get upload :path))
            (let ((progress (ignore-errors (telega-file--uploading-progress file)))
                  (report (plist-get (etaf-telega-backend-telega-callbacks backend)
                                     :upload)))
              (when (and (numberp progress) report)
                (funcall report (list :name (plist-get upload :name)
                                      :progress progress))))))))))

(defun etaf-telega-backend-telega--member (user)
  "Return USER's projection for the composer's mention picker."
  (list :id (plist-get user :id)
        :name (or (ignore-errors (telega-msg-sender-title user)) "")
        :username (or (telega-tl-str user :username) "")))

(defun etaf-telega-backend-telega--sticker (sticker)
  "Return STICKER's projection for the composer's sticker picker."
  (let* ((thumb (plist-get sticker :thumbnail))
         (emoji (or (ignore-errors (telega-sticker-emoji sticker)) "")))
    (list :id (plist-get sticker :id)
          :emoji emoji
          :label (if (string-empty-p emoji) "贴纸" emoji)
          :file-id (ignore-errors (telega--tl-get sticker :sticker :id))
          :thumb-id (ignore-errors (telega--tl-get thumb :photo :id))
          :thumb-width (or (plist-get thumb :width) 0)
          :thumb-height (or (plist-get thumb :height) 0)
          :width (or (plist-get sticker :width) 0)
          :height (or (plist-get sticker :height) 0))))

(cl-defmethod etaf-telega-backend-search-members ((backend etaf-telega-backend-telega)
                                                  chat-id query callback)
  "Report Telega's members of CHAT-ID matching QUERY."
  (let ((chat (and chat-id (telega-chat-get chat-id))))
    (when chat
      (telega--searchChatMembers
       chat (or query "") nil
       :limit 20
       :callback
       (lambda (members)
         (etaf-telega-backend-telega--guard
          backend "搜索成员"
          (lambda ()
            (funcall callback
                     (mapcar #'etaf-telega-backend-telega--member
                             (delq nil (append members nil)))))))))))

(cl-defmethod etaf-telega-backend-search-stickers ((backend etaf-telega-backend-telega)
                                                   query callback)
  "Report Telega's stickers matching QUERY."
  (telega--searchStickers
   (or query "") :limit 20
   :callback
   (lambda (stickers)
     (etaf-telega-backend-telega--guard
      backend "搜索贴纸"
      (lambda ()
        (funcall callback
                 (mapcar #'etaf-telega-backend-telega--sticker
                         (delq nil (append stickers nil)))))))))

(cl-defmethod etaf-telega-backend-send-sticker ((backend etaf-telega-backend-telega)
                                                chat-id sticker)
  "Send STICKER to CHAT-ID through Telega."
  (let ((chat (and chat-id (telega-chat-get chat-id)))
        (callbacks (etaf-telega-backend-telega-callbacks backend)))
    (unless chat (error "没有选中的对话"))
    (unless (etaf-telega-backend-telega--can-post-p chat)
      (error "当前对话不能发言"))
    (condition-case err
        (let ((message
               (telega--sendMessage
                chat
                (list :@type "inputMessageSticker"
                      :sticker (append
                                (list :@type "inputSticker"
                                      :sticker (list :@type "inputFileId"
                                                     :id (plist-get sticker :file-id))
                                      :width (or (plist-get sticker :width) 0)
                                      :height (or (plist-get sticker :height) 0))
                                (when (plist-get sticker :thumb-id)
                                  (list :thumbnail
                                        (list :@type "inputThumbnail"
                                              :width (or (plist-get sticker :thumb-width) 0)
                                              :height (or (plist-get sticker :thumb-height) 0)
                                              :thumbnail (list :@type "inputFileId"
                                                               :id (plist-get sticker :thumb-id))))))
                      :emoji (or (plist-get sticker :emoji) ""))
                nil nil
                :sync-p t)))
          (when-let* ((report (plist-get callbacks :sent)))
            (etaf-telega-backend-telega--guard
             backend "发送贴纸"
             (lambda ()
               (funcall report
                        (etaf-telega-backend-telega--project-message backend message))))))
      (error (etaf-telega-backend-telega--report
              backend :error (error-message-string err))))
    (plist-get sticker :id)))

(cl-defmethod etaf-telega-backend-stop ((backend etaf-telega-backend-telega))
  "Stop observing Telega without closing its server or account."
  (setq etaf-telega-backend-telega-instances
        (delq backend etaf-telega-backend-telega-instances))
  (unless etaf-telega-backend-telega-instances
    (when etaf-telega-backend-telega--chats-timer
      (cancel-timer etaf-telega-backend-telega--chats-timer)
      (setq etaf-telega-backend-telega--chats-timer nil))
    (remove-hook 'telega-ready-hook #'etaf-telega-backend-telega--ready)
    (remove-hook 'telega-chat-update-hook
                 #'etaf-telega-backend-telega--chat-update)
    (remove-hook 'telega-chat-post-message-hook
                 #'etaf-telega-backend-telega--message)
    (dolist (advice etaf-telega-backend-telega--advices)
      (advice-remove (nth 0 advice) (nth 2 advice)))))

(provide 'etaf-telega-backend)
;;; etaf-telega-backend.el ends here
