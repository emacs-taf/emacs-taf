;;; etaf-telega.el --- Telegram client with an ETAF interface on Telega's TDLib backend -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.13
;; Package-Requires: ((emacs "29.1") (etaf "0.3.19") (etaf-ui "0.3.14") (telega "0.8.0"))
;; Keywords: convenience
;; URL: https://github.com/emacs-taf/etaf-telega

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-telega) after adding this repository
;; root and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  The client
;; renders chats and messages with ETAF and edits the composer in place; the
;; Telega package owns the account, the TDLib database and the server process.
;; Tests and offline use never need Telega: the backend is replaceable through
;; `etaf-telega-backend-create-function'.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  This Commentary is the authoritative export
;; list; implementations and precise docstrings remain beside their
;; definitions.
;;
;; The client is one buffer that switches screens like a single-page
;; application: the conversation list, then one conversation with its
;; history and composer.  Keys follow Telega's root and chat buffers, so
;; Telega users keep their habits; the keys of
;; `etaf-telega-root-native-keys' and `etaf-telega-chat-native-keys' run
;; Telega's own commands on the conversation or message under point.
;;
;; Keys are ETAF Host keys of the pane holding point: the list, the chat or
;; the details pane, after the keys every pane shares (j, Q and C-c C-u).
;; Opening or leaving a conversation moves point into the screen's pane, and
;; in a split layout moving point into the other pane switches the screen.
;; Tab and the arrows reach every control through ETAF focus; the
;; conversation list is one Tab stop roved with the arrows, and RET on a
;; conversation carries focus into its composer while q brings it back.  ? opens
;; read-only searchable help inside this buffer; the app bar's keyboard button
;; and the menus' 键盘快捷键 item open the same modal. Escape leaves search
;; editing first, then closes help; an outside click also closes it and restores
;; focus. Reading commands keep point and focus on the selected row; header
;; controls and help preserve the message selection, while the composer clears
;; it. No help buffer or window is created. M-x etaf-palette remains the
;; separate command-execution surface.
;;
;; Function: etaf-telega-doctor ()
;; Return capability facts for using the Telegram client.  The shape matches
;; `etaf-install-doctor': :required and :optional lists of
;; (LABEL AVAILABLE REMEDY).  `telega` comes from MELPA and `telega-server`
;; is a compiled binary; both are checked, neither is installed here.
;; Function: etaf-telega-login ()
;; Open Telega so its own authorization flow can ask for the phone number and
;; code, then reuse that session here.
;;
;; Function: etaf-telega-logout ()
;; Ask for confirmation, then end the Telegram session through Telega's own
;; logout so the next start asks for the phone number again.
;;
;; Function: etaf-telega-open ()
;;;###autoload (autoload 'etaf-telega-open "etaf-telega" nil t)
;; Open the client as an ETAF application in its own buffer, show the
;; conversation list and return the buffer.  The client fills its window
;; without a mode line, and running this again shows the open client.
;; Starting uses the configured backend; the Telega backend starts Telega's
;; server without displaying Telega's own buffers and never touches the saved
;; account.
;; Function: etaf-telega-create ()
;;;###autoload (autoload 'etaf-telega-create "etaf-telega" nil t)
;; Create a client session without mounting it.
;; The session owns the model and one backend; no request is sent until its
;; View is mounted by `etaf-telega-open' or by a host of your own.  Every host
;; gets its own session, and one TDLib data directory still serves one client.
;;
;; Function: etaf-telega-view (session)
;;;###autoload (autoload 'etaf-telega-view "etaf-telega" nil t)
;; Return SESSION's View for mounting in a host of your own.
;; The View lays out for the region it is given, so a desktop window or a
;; floating panel shows the list beside the chat at its own width.  Mounting
;; adopts the host buffer: the client's commands and keys act on SESSION there,
;; and the palette switch repaints that View without re-mounting the host's
;; buffer.  Unmounting stops the backend and forgets the buffer; the session's
;; model keeps its state, so a host that mounts it again resumes the client.
;;
;; Function: etaf-telega-close ()
;;;###autoload (autoload 'etaf-telega-close "etaf-telega" nil t)
;; Stop observing the backend, release the runtime and kill the client buffer.
;; Still reachable as Q inside the client.
;;
;; Function: etaf-telega-select-filter (key)
;; Show the conversations of filter KEY (`main', `important', `online',
;; `groups', `channels', `archived'); the filter tabs call it.
;; Function: etaf-telega-next-filter ()
;; Show the next conversation filter tab (] on the list); the ends hold.
;; Function: etaf-telega-previous-filter ()
;; Show the previous conversation filter tab ([ on the list); the ends hold.
;; Function: etaf-telega-next-chat ()
;; Move point to the next conversation in the list (n).
;; Function: etaf-telega-previous-chat ()
;; Move point to the previous conversation in the list (p).
;; Function: etaf-telega-next-unread-chat ()
;; Move to the next conversation with unread messages (C-c g u on the list).
;; Function: etaf-telega-open-chat (id)
;; Replace the list with conversation ID: its newest history page above the
;; composer, with point in the composer.  Interactively ID is the
;; conversation under point (RET).
;; Function: etaf-telega-chat-with (id)
;; Open conversation ID; interactively choose by name from the backend's
;; known conversations and contacts (j on either screen).
;; Function: etaf-telega-back ()
;; Leave the conversation for the list with that conversation under point
;; (q, or the back button of the app bar).
;; Function: etaf-telega-search ()
;; Show the list search and begin typing its query (/ or s on the list, or a
;; click on the header's search field).  Kind tabs narrow the matches; before
;; anything is typed the search offers frequent contacts and the recently
;; opened results, and a typed query also searches the backend server-side,
;; so conversations the list has not loaded appear.  RET opens the first
;; match, and opening any result records it as recent and leaves search.
;; Function: etaf-telega-search-exit ()
;; Leave the list search and clear its query (the header's back button, or
;; cancelling the field).
;; Function: etaf-telega-search-clear-recent ()
;; Forget the recently opened search results.
;; Function: etaf-telega-toggle-details ()
;; Show or hide the open conversation's details pane: profile, shared media
;; and links (C-c i in a chat, or the header's sidebar button).  The pane is
;; hidden by default; a window too narrow for the list, chat and pane hides
;; the list, and the compact layout shows the pane instead of the chat.
;; Function: etaf-telega-swipe (direction)
;; Handle a horizontal two-finger swipe, DIRECTION `left' or `right'.  A
;; rightward swipe leaves the conversation; on the list a swipe shows the
;; neighbouring filter tab.  Swipes are ignored while the viewer is open.
;;
;; Function: etaf-telega-next-message ()
;; Select the next message; past the newest it returns to the composer (n).
;; Function: etaf-telega-previous-message ()
;; Select the previous message; at the oldest loaded one it loads an older
;; page (p).
;; Function: etaf-telega-jump-newest ()
;; Show the newest messages and select the newest one (> or M->, and the
;; chat header's more menu).
;; Function: etaf-telega-show-message (id)
;; Select the open chat's message ID; when it is not loaded, load its page
;; first and select it once the page arrives.
;; Function: etaf-telega-jump-quote ()
;; Jump to the message quoted by the message under point (C-c g q, or a click
;; on the quote).
;; Function: etaf-telega-jump-pinned ()
;; Jump to the open conversation's pinned message (C-c g p).
;; Function: etaf-telega-jump-date (date)
;; Jump to the message nearest before DATE, a timestamp; interactively read
;; a date like 2026-10-05 (C-c g d).
;; Function: etaf-telega-next-unread-message ()
;; Select the next unread message in the open conversation (C-c g u).
;; Function: etaf-telega-next-mention ()
;; Select the next loaded message that mentions the account (C-c g m).
;; Function: etaf-telega-next-outgoing ()
;; Select the next message sent by the account (C-c g o).
;; Function: etaf-telega-chat-search ()
;; Search the open conversation (/ in a chat, or the chat header's search
;; button): a search field replaces the title, the history shows messages
;; whose text or sender contains the query, and the backend's server-side
;; search adds matches the client has not loaded.  RET on a result jumps to
;; it in the history and closes the search.
;; Function: etaf-telega-chat-search-exit ()
;; Close the message search and show the whole history again.
;; Function: etaf-telega-load-more ()
;; Prepend one page of history older than the oldest loaded message (M-<).
;; Function: etaf-telega-reload-chat ()
;; Reload the open conversation's newest history page (g).
;; Function: etaf-telega-activate ()
;; Open the media of the message under point, or start typing anywhere else
;; (RET).
;; Function: etaf-telega-open-media (id)
;; Show message ID's photo, video or animation in the in-buffer viewer over
;; the conversation: its preview at once, then the full file with download
;; progress; videos play with seeking and voice notes and audio files play
;; through the same viewer.  In the viewer n and p page between the loaded
;; media messages and q, or a click outside, closes it.  Other attachments,
;; such as stickers and files, open with Telega.
;; Function: etaf-telega-close-media ()
;; Close the viewer and return to the conversation.
;; Function: etaf-telega-react (id key)
;; Toggle reaction KEY on message ID, an emoji string or `custom:<id>' naming a
;; custom emoji; interactively pick an emoji for the message under point (+).
;; Reactions show under the message, and clicking one toggles it too.
;; Function: etaf-telega-native (command)
;; Run Telega's COMMAND on the message under point on the chat screen, or on
;; the conversation under point on the list.  Keys of the native key
;; variables call it with their command; interactively choose the command
;; among the current screen's native commands.
;;
;; Function: etaf-telega-compose ()
;; Move point into the composer and begin editing it (i).  Return submits;
;; C-c C-k leaves it and keeps the text as the conversation's draft.
;; Function: etaf-telega-history-previous ()
;; Replace the composer text with the previous sent text (M-p).
;; Function: etaf-telega-history-next ()
;; Replace the composer text with the next sent text (M-n).
;; Function: etaf-telega-toggle-silent ()
;; Send the next message without a notification (C-c C-s).
;; Function: etaf-telega-toggle-link-preview ()
;; Disable the link preview for the next message (C-c C-l).
;; Function: etaf-telega-toggle-markdown ()
;; Parse the next message as Markdown into formatted text (C-c C-m).
;; Function: etaf-telega-schedule-send (time)
;; Send the next message at TIME, a timestamp; an empty interactive answer
;; clears the schedule (C-c C-t).
;; Function: etaf-telega-clear-schedule ()
;; Send the next message immediately, cancelling the schedule.
;; Function: etaf-telega-clear-draft ()
;; Discard the composer's text and leave the input (C-c C-d).
;; Function: etaf-telega-attach (path)
;; Send the file at PATH, choosing its Telegram kind by extension (C-c C-a).
;; Function: etaf-telega-attach-as (kind &optional path)
;; Send the file at PATH as KIND, `photo', `video', `voice' or `document'.
;; The composer's paperclip menu calls it per kind; PATH defaults to a file
;; read from the minibuffer, the draft becomes the caption, like
;; `etaf-telega-attach', and the pending upload shows in the status line
;; until it is accepted or `etaf-telega-cancel-upload' stops it.
;; Function: etaf-telega-send-file-as (kind path)
;; Send the file at PATH as KIND with the composer draft as caption.
;; An empty PATH or a directory is refused before any upload starts, and a
;; conversation the user may not post to is refused like `etaf-telega-send'.
;; Function: etaf-telega-cancel-upload ()
;; Cancel the file upload in progress (C-c C-u); a failed send's pending
;; state is dropped too, so the composer never keeps reporting an upload
;; that will not finish.
;; Function: etaf-telega-open-emoji ()
;; Show the emoji picker over the composer (C-c C-e); RET inserts the
;; selected emoji at the end of the draft.
;; Function: etaf-telega-open-stickers (query)
;; Show the sticker picker over the composer (C-c C-p); QUERY is an emoji or
;; keyword.  RET sends the selected sticker.
;; Function: etaf-telega-popover-next ()
;; Move the composer popover's selection down (C-n).
;; Function: etaf-telega-popover-previous ()
;; Move the composer popover's selection up (C-p).
;; Function: etaf-telega-popover-select (&optional index)
;; Insert or send the composer popover's item INDEX, the current one by
;; default (RET, C-c C-j or a click).
;; Function: etaf-telega-reply ()
;; Arm a reply to the message under point; the next send quotes it (r).
;; Function: etaf-telega-edit ()
;; Load the outgoing message under point into the composer; the next send
;; replaces its text (e).  Incoming messages are refused.
;; Function: etaf-telega-cancel-compose ()
;; Cancel the active reply or edit (C-c C-k); an edit restores the draft
;; present before editing began.
;; Function: etaf-telega-send (text)
;; Send TEXT to the open conversation, honouring the armed reply or edit.
;; The draft stays until the backend accepts the change, so a failure keeps
;; the text for another attempt; a conversation the user may not post to (a
;; broadcast channel without administrator rights) is refused before sending.
;;
;; Function: etaf-telega-info ()
;; Return a plist of visible client facts without network I/O: :buffer
;; :screen (`root' or `chat') :status :chats (count) :filter :cursor (list
;; conversation id) :chat (open id) :messages (count) :selected (message id)
;; :compose (nil, `reply' or `edit') :draft :history-end :editing
;; :viewer (message id shown in the viewer, or nil) :search (list search
;; query while searching, else nil) :chat-search (message search query while
;; open, else nil) :details (non-nil while the details pane is shown).
;; Function: etaf-telega-toggle-theme ()
;; Switch the open client between the dark and light palettes and repaint (T
;; on the list).
;; Function: etaf-telega-color (key)
;; Return the active palette's color for KEY; every view reads its colors
;; through this function so a theme switch stays consistent.
;; Function: etaf-telega-sender-color (name)
;; Return the active palette's stable accent color for sender NAME.
;; Variable: etaf-telega-theme
;; Appearance a new client starts with: `auto' follows the frame, or the host
;; that frames the client, `dark' and `light' pin a maintained palette, and
;; `native' derives every color from the current Emacs theme.  An open client
;; keeps the live mode cell that `T' and a panel's title-bar switch both write;
;; this option only seeds it.
;; Variable: etaf-telega-buffer-name
;; Buffer name of the mounted client.
;; Variable: etaf-telega-split-columns
;; Narrowest window width, in columns, that shows the conversation list
;; beside the open chat; narrower windows show one screen at a time.
;; Variable: etaf-telega-root-native-keys
;; Alist of (KEY . COMMAND) on the conversation list that run Telega's chat
;; commands on the conversation under point.  The list reads it when it
;; renders, so set it before opening the client.
;; Variable: etaf-telega-chat-native-keys
;; Alist of (KEY . COMMAND) on a conversation that run Telega's message
;; commands on the message under point.  The chat reads it when it renders,
;; so set it before opening the client.
;;
;; Variable: etaf-telega-backend-create-function
;; Return a fresh backend for `etaf-telega-open'.  Bind it to a fake backend
;; factory for tests and offline demonstrations.  The capability contract,
;; callback names and message plists are documented in the Commentary of
;; lisp/etaf-telega-backend.el.
;; Function: etaf-telega-backend-start (backend callbacks)
;; Connect BACKEND and report status, account and chats through CALLBACKS.
;; Function: etaf-telega-backend-stop (backend)
;; Stop observing the account without closing Telega's server or data.
;; Function: etaf-telega-backend-select (backend chat-id)
;; Open the chat with CHAT-ID and load its newest history page.
;; Function: etaf-telega-backend-history (backend &key before limit)
;; Load messages older than BEFORE, the oldest loaded message id.
;; Function: etaf-telega-backend-around (backend message-id &key limit)
;; Load the page at MESSAGE-ID in the selected chat; the page arrives through
;; the `:jump' callback, newest first.
;; Function: etaf-telega-backend-date-message (backend date)
;; Load the message at DATE, a `float-time'; it arrives through the `:jump'
;; callback.
;; Function: etaf-telega-backend-save-draft (backend chat-id text)
;; Store TEXT as CHAT-ID's draft; an empty TEXT clears it.
;; Function: etaf-telega-backend-search-chats (backend query callback)
;; Search the account for conversations matching QUERY, including ones the
;; list has not loaded; CALLBACK receives chat projections.
;; Function: etaf-telega-backend-search-messages (backend query callback)
;; Search the selected chat's full history for QUERY, including messages the
;; client has not loaded; CALLBACK receives message projections, newest first.
;; Function: etaf-telega-backend-pinned-message (backend chat-id callback)
;; Report CHAT-ID's newest pinned message id through CALLBACK, which receives
;; the id or nil when nothing is pinned.  The loaded conversation keeps the
;; pinned id it had when it was read, so pins made during the session are
;; only visible through this lookup.
;; Function: etaf-telega-backend-send-file (backend chat-id kind path caption options)
;; Send the file at PATH as KIND (`photo', `video', `voice' or `document')
;; with CAPTION and OPTIONS; progress arrives through `:upload' and the
;; accepted message through `:sent'.
;; Function: etaf-telega-backend-cancel-upload (backend path)
;; Cancel the pending upload of the file at PATH.
;; Function: etaf-telega-backend-search-members (backend chat-id query callback)
;; Search the conversation's members by QUERY; CALLBACK receives (:id :name
;; :username) plists for the mention picker.
;; Function: etaf-telega-backend-search-stickers (backend query callback)
;; Search stickers by QUERY; CALLBACK receives picker plists with :id, :emoji,
;; :label, :file-id, :thumb-id, :thumb-width, :thumb-height, :width, :height.
;; Function: etaf-telega-backend-send-sticker (backend chat-id sticker)
;; Send a picked STICKER to CHAT-ID.
;; Function: etaf-telega-backend-send (backend text &optional reply-to options)
;; Send TEXT, replying to the message REPLY-TO when non-nil.  OPTIONS is a
;; plist: :silent, :no-preview, :at (a timestamp) and :markdown.
;; Function: etaf-telega-backend-edit (backend message text)
;; Replace the text of MESSAGE.
;; Function: etaf-telega-backend-read (backend message-ids)
;; Accept MESSAGE-IDS in the selected chat as read.
;; Function: etaf-telega-backend-react (backend message-id key)
;; Toggle reaction KEY on MESSAGE-ID in the selected chat, an emoji string or
;; `custom:<id>' naming a custom emoji; the changed message is reported through
;; `:updated'.
;; Function: etaf-telega-backend-media (backend message-id callback)
;; Fetch MESSAGE-ID's full photo, video, animation, sticker, voice, audio or
;; document file.  CALLBACK receives (PROGRESS SOURCE): PROGRESS from 0.0 to
;; 1.0 and SOURCE, a local file or image source, once it is available.
;; Function: etaf-telega-backend-native (backend command chat-id &optional message-id)
;; Run the backend's interactive COMMAND on CHAT-ID, or on its MESSAGE-ID, as
;; if that chat or message were at point.
;; Function: etaf-telega-backend-chat-candidates (backend)
;; Return the conversations and contacts the client offers by name, each a
;; plist with :id and :title.
;; Function: etaf-telega-backend-ensure-chat (backend id)
;; Make conversation ID available to open; a backend with a private-chat
;; model, such as Telega, creates a contact's missing chat.
;;
;; Function: etaf-telega-backend-fake-create (&key chats histories responder dormant members stickers)
;; Return an offline backend seeded with CHATS and HISTORIES (a hash table
;; from chat id to message plists, newest first).  DORMANT holds conversations
;; the initial list does not carry; searching finds them like a server-side
;; search does.  MEMBERS and STICKERS seed the composer popovers' completion
;; sources.  RESPONDER, when non-nil, is called with (BACKEND TEXT) after
;; each send so a caller can acknowledge through
;; `etaf-telega-backend-fake-complete'.
;; Function: etaf-telega-backend-fake-sent (backend)
;; Return, newest first, the texts BACKEND accepted but has not confirmed.
;; Function: etaf-telega-backend-fake-sends (backend)
;; Return, newest first, BACKEND's recorded sends as (:text :reply :options)
;; plists.
;; Function: etaf-telega-backend-fake-drafts (backend)
;; Return BACKEND's stored draft texts, a hash table from conversation id to
;; text.
;; Function: etaf-telega-backend-fake-files (backend)
;; Return, newest first, BACKEND's recorded file sends as
;; (:kind :path :caption :options) plists.
;; Function: etaf-telega-backend-fake-confirm-file (backend path)
;; Report the upload of PATH as accepted and append its message.
;; Function: etaf-telega-backend-fake-fail (backend text)
;; Report TEXT as a failed operation through BACKEND's error callback.
;; Function: etaf-telega-backend-fake-replies (backend)
;; Return the (TEXT . MESSAGE-ID) replies BACKEND recorded for its sends.
;; Function: etaf-telega-backend-fake-natives (backend)
;; Return, newest first, the (COMMAND CHAT-ID MESSAGE-ID) native commands
;; BACKEND was asked to run.
;; Function: etaf-telega-backend-fake-chats (backend)
;; Return BACKEND's stored chat projections.
;; Function: etaf-telega-backend-fake-message (backend id)
;; Return BACKEND's stored projection of the message with ID, or nil.
;; Function: etaf-telega-backend-fake-complete (backend text)
;; Confirm TEXT as accepted by BACKEND, exactly like a server acknowledgement.
;; Function: etaf-telega-backend-fake-deliver (backend message)
;; Report MESSAGE as newly arrived in BACKEND's selected chat.
;; Function: etaf-telega-backend-fake-update (backend message)
;; Store MESSAGE in the selected chat and report it as changed elsewhere.
;; Function: etaf-telega-backend-fake-remove (backend id)
;; Remove message ID from the selected chat and report the deletion.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-telega")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-telega.el" dir))
                                (file-exists-p (expand-file-name "etaf-telega.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))
(require 'etaf-telega-account)
(require 'etaf-telega-app)
(require 'etaf-telega-backend)

(defun etaf-telega-doctor ()
  "Return capability facts for the Telegram client.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Nothing is installed or changed."
  (list :required
        (list (list "telega package" (and (locate-library "telega") t)
                    "Install Telega from MELPA; the installer registers MELPA, then run M-x package-install telega.")
              (list "telega-server" (and (executable-find "telega-server") t)
                    (concat "Install TDLib, then run M-x telega-server-build or build "
                            "Telega's server manually; put telega-server on exec-path. "
                            "See https://github.com/zevlg/telega.el#installation.")))
        :optional nil))


(provide 'etaf-telega)
;;; etaf-telega.el ends here
