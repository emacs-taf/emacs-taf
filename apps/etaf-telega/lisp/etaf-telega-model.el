;;; etaf-telega-model.el --- State of etaf-telega -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns plain data and reactive sources.  It never touches a buffer,
;; the network or storage; views read the refs and commands mutate them.
;; Chats and messages are plain plists so a backend can replace a record
;; without depending on any mutable object identity.
;;
;; Besides status, chats, history, the draft and the shown screen (the
;; conversation list `root' or the open `chat'), the model mirrors what Telega
;; keeps in point and its input prompt: the conversation and message under
;; point (`:cursor', `:selected') and the composer's compose state, which is
;; either a reply to, or an edit of, one message.
;;
;; The shell's own presentation state lives here too: the list search (its
;; query, whether search is shown, the kind tab and the recently opened
;; results), the in-chat message search, the details pane switch and the
;; list pane width the reader dragged.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf)

(defun etaf-telega-model ()
  "Create the application model."
  (list :status (etaf-ref "正在连接 Telegram…" :name 'etaf-telega-status)
        :me (etaf-ref nil :name 'etaf-telega-me)
        :chats (etaf-ref nil :name 'etaf-telega-chats)
        :chat (etaf-ref nil :name 'etaf-telega-chat)
        :messages (etaf-ref nil :name 'etaf-telega-messages)
        :selected (etaf-ref nil :name 'etaf-telega-selected)
        :compose (etaf-ref nil :name 'etaf-telega-compose)
        :cursor (etaf-ref nil :name 'etaf-telega-cursor)
        :filter (etaf-ref 'main :name 'etaf-telega-filter)
        :draft (etaf-ref "" :name 'etaf-telega-draft)
        :screen (etaf-ref 'root :name 'etaf-telega-screen)
        :viewer (etaf-ref nil :name 'etaf-telega-viewer)
        :search (etaf-ref "" :name 'etaf-telega-search)
        :searching (etaf-ref nil :name 'etaf-telega-searching)
        :search-kind (etaf-ref 'all :name 'etaf-telega-search-kind)
        :search-results (etaf-ref nil :name 'etaf-telega-search-results)
        :recent (etaf-ref nil :name 'etaf-telega-recent)
        :chat-search (etaf-ref nil :name 'etaf-telega-chat-search)
        :chat-search-results (etaf-ref nil :name 'etaf-telega-chat-search-results)
        :details (etaf-ref nil :name 'etaf-telega-details)
        :list-width (etaf-ref nil :name 'etaf-telega-list-width)
        :send-silent (etaf-ref nil :name 'etaf-telega-send-silent)
        :send-no-preview (etaf-ref nil :name 'etaf-telega-send-no-preview)
        :send-at (etaf-ref nil :name 'etaf-telega-send-at)
        :send-markdown (etaf-ref nil :name 'etaf-telega-send-markdown)
        :upload (etaf-ref nil :name 'etaf-telega-upload)
        :popover (etaf-ref nil :name 'etaf-telega-popover)))

(defun etaf-telega-model-screen (model)
  "Return MODEL's shown screen, `root' or `chat'."
  (etaf-value (plist-get model :screen)))

(defun etaf-telega-model-set-screen (model screen)
  "Show SCREEN, `root' or `chat', in MODEL."
  (setf (etaf-value (plist-get model :screen)) screen))

(defun etaf-telega-model-status (model)
  "Return MODEL's connection status."
  (etaf-value (plist-get model :status)))

(defun etaf-telega-model-me (model)
  "Return MODEL's own account projection."
  (etaf-value (plist-get model :me)))

(defun etaf-telega-model-chats (model)
  "Return MODEL's chat projections."
  (etaf-value (plist-get model :chats)))

(defun etaf-telega-model-chat (model)
  "Return MODEL's selected chat projection."
  (etaf-value (plist-get model :chat)))

(defun etaf-telega-model-messages (model)
  "Return MODEL's messages for the selected chat."
  (etaf-value (plist-get model :messages)))

(defun etaf-telega-model-draft (model)
  "Return MODEL's composer text."
  (etaf-value (plist-get model :draft)))

(defun etaf-telega-model-selected-id (model)
  "Return MODEL's selected message id, or nil."
  (etaf-value (plist-get model :selected)))

(defun etaf-telega-model-compose (model)
  "Return MODEL's compose state, a plist with `:kind' and `:target'."
  (etaf-value (plist-get model :compose)))

(defun etaf-telega-model-cursor (model)
  "Return MODEL's selected conversation id in the chat list."
  (etaf-value (plist-get model :cursor)))

(defun etaf-telega-model-set-cursor (model id)
  "Select the conversation with ID in MODEL's chat list."
  (setf (etaf-value (plist-get model :cursor)) id))

(defun etaf-telega-model-filter (model)
  "Return MODEL's active chat filter key."
  (or (etaf-value (plist-get model :filter)) 'main))

(defun etaf-telega-model-set-filter (model key)
  "Set MODEL's active chat filter to KEY."
  (setf (etaf-value (plist-get model :filter)) key))

(defun etaf-telega-model-message-by-id (model id)
  "Return MODEL's message with ID, or nil."
  (cl-find id (etaf-telega-model-messages model)
           :key (lambda (message) (plist-get message :id)) :test #'equal))

(defun etaf-telega-model-selected-message (model)
  "Return MODEL's selected message, or nil."
  (let ((id (etaf-telega-model-selected-id model)))
    (and id (etaf-telega-model-message-by-id model id))))

(defun etaf-telega-model-set-status (model status)
  "Set MODEL's STATUS."
  (setf (etaf-value (plist-get model :status)) status))

(defun etaf-telega-model-set-me (model me)
  "Set MODEL's account projection ME."
  (setf (etaf-value (plist-get model :me)) me))

(defun etaf-telega-model-set-chats (model chats)
  "Replace MODEL's chats with CHATS.
A chat whose projection is unchanged keeps its previous record, so only the
rows of chats that really changed render again.  The list cursor keeps its
conversation when it is still present and falls back to the newest one."
  (let* ((old (make-hash-table :test #'equal))
         (current (etaf-telega-model-cursor model)))
    (dolist (chat (etaf-telega-model-chats model))
      (puthash (plist-get chat :id) chat old))
    (setq chats (mapcar (lambda (chat)
                          (let ((previous (gethash (plist-get chat :id) old)))
                            (if (equal previous chat) previous chat)))
                        chats))
    (etaf-batch
      (unless (equal chats (etaf-telega-model-chats model))
        (setf (etaf-value (plist-get model :chats)) chats))
      (setf (etaf-value (plist-get model :cursor))
            (if (and current
                     (cl-find current chats
                              :key (lambda (chat) (plist-get chat :id))
                              :test #'equal))
                current
              (and chats (plist-get (car chats) :id)))))))

(defun etaf-telega-model-select (model chat)
  "Select CHAT in MODEL.
The loaded history, the message selection and any compose
state clear until the backend reports the chat's messages."
  (setf (etaf-value (plist-get model :chat)) chat
        (etaf-value (plist-get model :messages)) nil
        (etaf-value (plist-get model :selected)) nil
        (etaf-value (plist-get model :compose)) nil))

(defun etaf-telega--merge-messages (old new)
  "Return OLD and NEW merged by message id, oldest first.
NEW wins for an id both lists carry, so a refresh replaces an edited
message instead of keeping the stale copy."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (message (append old new))
      (when-let* ((id (plist-get message :id)))
        (puthash id message table)))
    (sort (hash-table-values table)
          (lambda (left right)
            (< (or (plist-get left :id) 0)
               (or (plist-get right :id) 0))))))

(defun etaf-telega-model-set-messages (model messages)
  "Merge MESSAGES into MODEL's loaded history.
A refresh that reports only part of the cached history must not drop
already loaded pages, so pages merge by id."
  (setf (etaf-value (plist-get model :messages))
        (etaf-telega--merge-messages (etaf-telega-model-messages model) messages)))

(defun etaf-telega-model-set-selected (model id)
  "Select the message with ID in MODEL."
  (setf (etaf-value (plist-get model :selected)) id))

(defun etaf-telega-model-viewer (model)
  "Return MODEL's open media viewer state, a plist, or nil."
  (etaf-value (plist-get model :viewer)))

(defun etaf-telega-model-set-viewer (model viewer)
  "Set MODEL's media VIEWER state; nil closes the viewer."
  (setf (etaf-value (plist-get model :viewer)) viewer))

(defun etaf-telega-model-set-compose (model compose)
  "Set MODEL's compose state to COMPOSE, a `(:kind :target)' plist or nil."
  (setf (etaf-value (plist-get model :compose)) compose))

(defun etaf-telega-model-prepend-messages (model messages)
  "Prepend older MESSAGES, in reading order, to MODEL's history.
Overlapping pages merge by id."
  (when messages
    (setf (etaf-value (plist-get model :messages))
          (etaf-telega--merge-messages
           (etaf-telega-model-messages model) messages))))

(defun etaf-telega-model-append-message (model message)
  "Append MESSAGE to MODEL's message list.
A message whose non-nil id is already present replaces its earlier copy, so a
confirmation delivered twice still shows once."
  (let* ((id (plist-get message :id))
         (messages (etaf-telega-model-messages model)))
    (setf (etaf-value (plist-get model :messages))
          (if (and id (cl-find id messages
                               :key (lambda (item) (plist-get item :id))
                               :test #'equal))
              (cl-mapcar (lambda (existing)
                           (if (equal (plist-get existing :id) id)
                               message existing))
                         messages)
            (append messages (list message))))))

(defun etaf-telega-model-replace-message (model message)
  "Replace MODEL's message with MESSAGE's id."
  (when (plist-get message :id)
    (setf (etaf-value (plist-get model :messages))
          (cl-mapcar (lambda (existing)
                       (if (equal (plist-get existing :id) (plist-get message :id))
                           message existing))
                     (etaf-telega-model-messages model)))))

(defun etaf-telega-model-remove-message (model id)
  "Remove the message with ID from MODEL.
The selection moves to the nearest remaining message."
  (let* ((messages (etaf-telega-model-messages model))
         (index (cl-position id messages :key (lambda (item) (plist-get item :id))
                             :test #'equal))
         (rest (cl-remove id messages :key (lambda (item) (plist-get item :id))
                          :test #'equal)))
    (setf (etaf-value (plist-get model :messages)) rest)
    (when (equal (etaf-telega-model-selected-id model) id)
      (setf (etaf-value (plist-get model :selected))
            (and rest (plist-get (nth (min (max 0 (1- (or index 0)))
                                          (1- (length rest)))
                                      rest)
                                 :id))))))

(defun etaf-telega-model-set-draft (model text)
  "Set MODEL's composer draft to TEXT."
  (setf (etaf-value (plist-get model :draft)) text))

(defun etaf-telega-model-chat-by-id (model id)
  "Return MODEL's chat projection with ID, or nil."
  (cl-find id (etaf-telega-model-chats model)
           :key (lambda (chat) (plist-get chat :id)) :test #'equal))

(defconst etaf-telega-model--recent-limit 12
  "Most recently opened search results the model remembers.")

(defun etaf-telega-model-searching (model)
  "Return non-nil while MODEL shows the list search."
  (etaf-value (plist-get model :searching)))

(defun etaf-telega-model-search (model)
  "Return MODEL's list search query."
  (or (etaf-value (plist-get model :search)) ""))

(defun etaf-telega-model-set-search (model searching &optional query)
  "Show the list search in MODEL when SEARCHING, with QUERY.
Leaving search clears the query and the kind tab."
  (etaf-batch
    (setf (etaf-value (plist-get model :searching)) (and searching t))
    (setf (etaf-value (plist-get model :search)) (if searching (or query "") ""))
    (unless searching
      (setf (etaf-value (plist-get model :search-kind)) 'all))))

(defun etaf-telega-model-set-search-kind (model kind)
  "Narrow MODEL's search results to chats of KIND, or `all'."
  (setf (etaf-value (plist-get model :search-kind)) kind))

(defun etaf-telega-model-search-results (model)
  "Return MODEL's backend-side search results."
  (etaf-value (plist-get model :search-results)))

(defun etaf-telega-model-set-search-results (model chats)
  "Set MODEL's backend-side search results to CHATS."
  (setf (etaf-value (plist-get model :search-results)) chats))

(defun etaf-telega-model-recent (model)
  "Return MODEL's recently opened search result ids, newest first."
  (etaf-value (plist-get model :recent)))

(defun etaf-telega-model-add-recent (model id)
  "Record chat ID as MODEL's most recently opened search result."
  (setf (etaf-value (plist-get model :recent))
        (seq-take (cons id (remove id (etaf-telega-model-recent model)))
                  etaf-telega-model--recent-limit)))

(defun etaf-telega-model-clear-recent (model)
  "Forget MODEL's recently opened search results."
  (setf (etaf-value (plist-get model :recent)) nil))

(defun etaf-telega-model-chat-search (model)
  "Return MODEL's in-chat search query, or nil while it is closed."
  (etaf-value (plist-get model :chat-search)))

(defun etaf-telega-model-set-chat-search (model query)
  "Open MODEL's in-chat search with QUERY, or close it when QUERY is nil."
  (setf (etaf-value (plist-get model :chat-search)) query))

(defun etaf-telega-model-chat-search-results (model)
  "Return MODEL's backend-side message-search results."
  (etaf-value (plist-get model :chat-search-results)))

(defun etaf-telega-model-set-chat-search-results (model messages)
  "Set MODEL's backend-side message-search results to MESSAGES."
  (setf (etaf-value (plist-get model :chat-search-results)) messages))

(defun etaf-telega-model-details (model)
  "Return non-nil while MODEL shows the chat details pane."
  (etaf-value (plist-get model :details)))

(defun etaf-telega-model-set-details (model shown)
  "Show MODEL's chat details pane when SHOWN."
  (setf (etaf-value (plist-get model :details)) (and shown t)))

(defun etaf-telega-model-set-list-width (model pixels)
  "Set MODEL's list pane width to PIXELS, or nil for the default."
  (setf (etaf-value (plist-get model :list-width)) pixels))

(defun etaf-telega-model-send-options (model)
  "Return MODEL's pending send options as a plist.
Keys are `:silent', `:no-preview', `:at' (a timestamp) and `:markdown'."
  (list :silent (etaf-value (plist-get model :send-silent))
        :no-preview (etaf-value (plist-get model :send-no-preview))
        :at (etaf-value (plist-get model :send-at))
        :markdown (etaf-value (plist-get model :send-markdown))))

(defun etaf-telega-model-set-send-option (model key value)
  "Set MODEL's send option KEY to VALUE.
KEY is `silent', `no-preview', `at' or `markdown'."
  (let ((ref (pcase key
               ('silent (plist-get model :send-silent))
               ('no-preview (plist-get model :send-no-preview))
               ('at (plist-get model :send-at))
               ('markdown (plist-get model :send-markdown))
               (_ (error "Unknown send option %S" key)))))
    (setf (etaf-value ref) value)))

(defun etaf-telega-model-upload (model)
  "Return MODEL's pending file upload, a (:path :name :progress) plist, or nil."
  (etaf-value (plist-get model :upload)))

(defun etaf-telega-model-set-upload (model upload)
  "Set MODEL's pending file UPLOAD plist, or nil when none is running."
  (setf (etaf-value (plist-get model :upload)) upload))

(defun etaf-telega-model-popover (model)
  "Return MODEL's composer popover, a (:kind :title :items :index) plist, or nil."
  (etaf-value (plist-get model :popover)))

(defun etaf-telega-model-set-popover (model popover)
  "Set MODEL's composer POPOVER plist, or nil to close it."
  (setf (etaf-value (plist-get model :popover)) popover))

(provide 'etaf-telega-model)
;;; etaf-telega-model.el ends here
