;;; maillist-model.el --- State of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns every value a View reads: the thread rows, the groups they
;; are shown in, the open thread, the scope and the sync status.  A row is a
;; plist (:id :subject :date :count :depth :author :participants :unread
;; :starred), and an open thread is a plist (:id :subject :meta :messages
;; :loading :error); Views only project those values.
;;
;; Reading is a two-stage load.  Cached rows appear immediately, the archive
;; index replaces them when it arrives, and thread bodies are fetched when a
;; row is opened.  Every asynchronous answer carries a generation number so a
;; slow reply for a previously selected row never overwrites the current one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'maillist-service)
(require 'maillist-store)

(defcustom maillist-default-list "emacs-devel"
  "Archive a new client opens."
  :type 'string
  :group 'maillist)

(defcustom maillist-fast-open-threshold 40
  "Thread size from which the newest mail is shown before the whole thread.
A public-inbox thread document carries every message, so a thousand-message
conversation is megabytes; one search feed answers with the newest mail in a
few kilobytes.  Below this size the whole thread arrives just as fast."
  :type 'integer
  :group 'maillist)

(defcustom maillist-message-window 20
  "How many of the newest messages a thread shows at first.
Long archive threads reach a thousand messages; a window keeps the canvas
small, and `maillist-load-earlier' grows it on demand."
  :type 'integer
  :group 'maillist)

(defcustom maillist-prefetch-parallel 3
  "How many sender requests the client keeps in flight.
The archive answers one raw message quickly; a few parallel requests fill a
page in seconds without loading the server."
  :type 'integer
  :group 'maillist)

(defcustom maillist-prefetch-threads 500
  "How many missing senders to fetch after each sync.
A public-inbox index names no senders at all, so the client reads one raw
message per thread whose sender it does not know yet.  A raw message is a few
kilobytes, so a whole page fills in seconds; senders are stored and never
fetched again.  Set it to 0 to fetch only opened threads."
  :type 'integer
  :group 'maillist)

(defun maillist--ref (value name)
  "Return a reactive cell named NAME holding VALUE."
  (etaf-ref value :name name))

(defun maillist--alive-p (session)
  "Return non-nil while SESSION may still be updated."
  (and (plist-get session :alive) t))

(defun maillist--current-p (session token)
  "Return non-nil when TOKEN is the current thread generation of SESSION."
  (and (maillist--alive-p session)
       (equal token (plist-get session :token))))

(defun maillist--current-sync-p (session token)
  "Return non-nil when TOKEN is the current sync generation of SESSION.
A sync generation outlives thread selection: opening a row while the list is
still warming must not cancel the author and body prefetch."
  (and (maillist--alive-p session)
       (equal token (plist-get session :sync-token))))

(defun maillist--clear-toast (session)
  "Remove SESSION's floating notice."
  (when-let* ((timer (plist-get session :toast-timer)))
    (cancel-timer timer)
    (plist-put session :toast-timer nil))
  (when (etaf-value (plist-get session :toast))
    (etaf-set-value (plist-get session :toast) nil)))

(defun maillist--toast (session kind text &optional seconds)
  "Show TEXT as SESSION's floating notice of KIND.
SECONDS nil keeps it until the next notice, which is what a running sync
uses; a finished notice leaves on its own."
  (when-let* ((timer (plist-get session :toast-timer)))
    (cancel-timer timer)
    (plist-put session :toast-timer nil))
  (etaf-set-value (plist-get session :toast) (list :kind kind :text text))
  (when seconds
    (plist-put session :toast-timer
               (run-at-time seconds nil
                            (lambda ()
                              (when (maillist--alive-p session)
                                (plist-put session :toast-timer nil)
                                (etaf-set-value (plist-get session :toast) nil)))))))

(defun maillist--status (session kind text)
  "Set SESSION's sync state to KIND with TEXT and show TEXT as a notice."
  (etaf-set-value (plist-get session :status) (list :kind kind :text text))
  (pcase kind
    ('loading (maillist--toast session 'info text))
    ('error (maillist--toast session 'error text 9))
    ('idle (maillist--clear-toast session))))

;;; ---------------------------------------------------------------------------
;;; Rows
;;; ---------------------------------------------------------------------------

(defun maillist--row-from-record (record)
  "Return the visible row described by the stored RECORD."
  (list :id (plist-get record :id)
        :subject (or (plist-get record :subject) "")
        :date (plist-get record :date)
        :count (plist-get record :count)
        :depth 0
        :author (or (plist-get record :author) "")
        :participants (plist-get record :participants)
        :unread (not (eq 1 (plist-get record :read)))
        :starred (eq 1 (plist-get record :starred))))

(defun maillist--merge-rows (fetched session)
  "Return FETCHED rows carrying the read, starred and author state of SESSION.
FETCHED order is the archive's order and is kept."
  (let ((known (make-hash-table :test #'equal)))
    (dolist (row (etaf-value (plist-get session :threads)))
      (puthash (plist-get row :id) row known))
    (dolist (record (or (maillist-store-threads (plist-get session :store)) '()))
      (unless (gethash (plist-get record :id) known)
        (puthash (plist-get record :id) (maillist--row-from-record record) known)))
    (mapcar
     (lambda (row)
       (let ((old (gethash (plist-get row :id) known)))
         (list :id (plist-get row :id)
               :subject (or (plist-get row :subject) "")
               :date (or (plist-get row :date) (plist-get old :date))
               :count (or (plist-get row :count) (plist-get old :count))
               :depth (or (plist-get row :depth) 0)
               :author (or (plist-get old :author) "")
               :participants (plist-get old :participants)
               :unread (if old (plist-get old :unread) t)
               :starred (and old (plist-get old :starred)))))
     fetched)))

(defun maillist--plist-merge (plist fields)
  "Return PLIST with FIELDS applied, keeping one entry per key.
FIELDS wins; every other PLIST entry keeps its order after them."
  (let ((result (copy-sequence fields)))
    (cl-loop for (key value) on plist by #'cddr
             unless (plist-member fields key)
             do (setq result (append result (list key value))))
    result))

(defun maillist--replace-row (session id fields)
  "Return SESSION's rows with FIELDS applied to the row ID."
  (mapcar (lambda (row)
            (if (equal id (plist-get row :id))
                (maillist--plist-merge row fields)
              row))
          (etaf-value (plist-get session :threads))))

(defun maillist-rows (session)
  "Return the visible rows of SESSION in list order.
The open row stays visible while it is read even under the unread scope, so a
row never disappears under the pointer that selected it."
  (let* ((rows (etaf-value (plist-get session :threads)))
         (scope (etaf-value (plist-get session :scope)))
         (selected (etaf-value (plist-get session :selected))))
    (if (eq scope 'all)
        rows
      (seq-filter (lambda (row)
                    (or (equal (plist-get row :id) selected)
                        (if (eq scope 'unread)
                            (plist-get row :unread)
                          (plist-get row :starred))))
                  rows))))

(defun maillist-row (session id)
  "Return the row of SESSION whose id is ID."
  (seq-find (lambda (row) (equal (plist-get row :id) id))
            (etaf-value (plist-get session :threads))))

(defun maillist-selected-row (session)
  "Return the row SESSION currently shows, or nil."
  (when-let* ((id (etaf-value (plist-get session :selected))))
    (maillist-row session id)))

(defun maillist--grouped (rows)
  "Return ROWS grouped by their date label, newest group first."
  (let (groups)
    (dolist (row rows)
      (let* ((label (maillist-day-label (plist-get row :date)))
             (cell (assoc label groups)))
        (if cell
            (setcdr cell (cons row (cdr cell)))
          (push (list label row) groups))))
    (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
            (nreverse groups))))

(defun maillist--unread-count (rows)
  "Return how many of ROWS are unread."
  (seq-count (lambda (row) (plist-get row :unread)) rows))

(defun maillist--summary (session)
  "Return the status line text of SESSION."
  (let* ((query (etaf-value (plist-get session :query)))
         (rows (etaf-value (plist-get session :threads)))
         (sync (plist-get session :last-sync)))
    (if (not (string-empty-p query))
        (format "搜索结果 %d 个线程" (length rows))
      (concat (format "%d 个线程 · %d 未读" (length rows) (maillist--unread-count rows))
              (if sync (format " · %s 同步" (format-time-string "%H:%M" sync)) "")))))

(defun maillist--apply-view (session)
  "Publish the groups, summary and selection SESSION's rows imply."
  (let ((rows (maillist-rows session)))
    (etaf-set-value (plist-get session :groups) (maillist--grouped rows))
    (etaf-set-value (plist-get session :summary) (maillist--summary session))
    (when (and (maillist--alive-p session)
               rows
               (not (maillist-selected-row session)))
      (maillist-select session (plist-get (car rows) :id)))))

;;; ---------------------------------------------------------------------------
;;; Selection and state
;;; ---------------------------------------------------------------------------

(defun maillist--persist-state (session id fields)
  "Persist FIELDS of thread ID in SESSION's store."
  (when-let* ((store (plist-get session :store)))
    (condition-case err
        (maillist-store-set-thread-state store id fields)
      (error (message "maillist: 无法保存线程状态：%s" (error-message-string err))))))

(defun maillist-select (session id &optional no-mark)
  "Open the row ID of SESSION.
NO-MARK leaves the read state alone; otherwise opening a thread marks it
read and persists that."
  (when-let* ((row (maillist-row session id)))
    (etaf-set-value (plist-get session :selected) id)
    (when (and (not no-mark) (plist-get row :unread))
      (etaf-set-value (plist-get session :threads)
                      (maillist--replace-row session id (list :unread nil)))
      (maillist--persist-state session id (list :read t)))
    (maillist--open-thread session row)
    (maillist--apply-view session)
    (etaf-value (plist-get session :open))))

(defun maillist-move (session delta)
  "Move the selection of SESSION by DELTA rows and open the new row."
  (let* ((rows (maillist-rows session))
         (current (etaf-value (plist-get session :selected)))
         (index (or (cl-position current rows
                                 :key (lambda (row) (plist-get row :id))
                                 :test #'equal)
                    0))
         (next (nth (max 0 (min (1- (length rows)) (+ index delta))) rows)))
    (when next (maillist-select session (plist-get next :id)))))

(defun maillist-toggle-message (session id)
  "Fold or unfold message ID in the open thread of SESSION.
The choice survives a body reload because the session remembers it."
  (let* ((open (etaf-value (plist-get session :open)))
         (message (cl-find id (plist-get open :messages)
                           :key (lambda (item) (plist-get item :id))
                           :test #'equal)))
    (when message
      (let* ((collapsed (not (plist-get message :collapsed)))
             (thread-id (plist-get open :id))
             (known (gethash thread-id (plist-get session :collapsed)))
             (updated (if collapsed
                          (cons id known)
                        (delete id known))))
        (puthash thread-id updated (plist-get session :collapsed))
        (etaf-set-value
         (plist-get session :open)
         (plist-put (copy-sequence open) :messages
                    (mapcar (lambda (item)
                              (if (equal id (plist-get item :id))
                                  (plist-put (copy-sequence item) :collapsed collapsed)
                                item))
                            (plist-get open :messages))))
        collapsed))))

(defun maillist-toggle-star (session)
  "Toggle the star of SESSION's selected row and persist it."
  (when-let* ((row (maillist-selected-row session)))
    (let ((starred (not (plist-get row :starred))))
      (etaf-set-value (plist-get session :threads)
                      (maillist--replace-row session (plist-get row :id)
                                             (list :starred starred)))
      (maillist--persist-state session (plist-get row :id) (list :starred starred))
      (maillist--apply-view session)
      starred)))

;;; ---------------------------------------------------------------------------
;;; Thread bodies
;;; ---------------------------------------------------------------------------

(defun maillist--thread-placeholder (row text)
  "Return the open-thread value for ROW while TEXT describes its state."
  (list :id (plist-get row :id)
        :subject (or (plist-get row :subject) "")
        :meta text
        :total nil
        :hidden 0
        :loading t
        :messages nil))

(defun maillist--thread-value (row messages &optional loading collapsed window)
  "Return the open-thread value of ROW built from MESSAGES.
LOADING marks a thread whose full body is still being fetched; WINDOW limits
the shown messages to the newest ones and a message whose id is in COLLAPSED
shows only its header."
  (let* ((total (length messages))
         (size (max 1 (min total (or window maillist-message-window))))
         (shown (last messages size))
         (participants (length (delete-dups
                                (mapcar (lambda (message)
                                          (plist-get message :author))
                                        messages))))
         (last-message (car (last messages)))
         (data (or (plist-get last-message :date) (plist-get row :date))))
    (list :id (plist-get row :id)
          :subject (or (plist-get row :subject) "")
          :meta (format "%d 封 · %d 人参与 · 最后回复 %s"
                        total participants
                        (maillist-long-label data))
          :total total
          :hidden (- total size)
          :loading loading
          :messages
          (cl-loop for message in shown
                   collect (append message
                                   (list :collapsed (and collapsed
                                                         (member (plist-get message :id)
                                                                 collapsed))
                                         :lines (maillist-classify-lines
                                                 (or (plist-get message :text) "")
                                                 (plist-get message :id))))))))

(defun maillist--publish-thread (session row messages &optional loading)
  "Publish MESSAGES as the open thread of SESSION for ROW."
  (plist-put session :open-messages messages)
  (etaf-set-value
   (plist-get session :open)
   (maillist--thread-value row messages loading
                           (gethash (plist-get row :id)
                                    (plist-get session :collapsed))
                           (plist-get session :message-window))))

(defun maillist-load-earlier (session)
  "Show another window of older messages in SESSION's open thread."
  (when-let* ((open (etaf-value (plist-get session :open)))
              (row (maillist-row session (plist-get open :id)))
              (messages (plist-get session :open-messages)))
    (plist-put session :message-window
               (+ (or (plist-get session :message-window) 0)
                  maillist-message-window))
    (maillist--publish-thread session row messages)
    (plist-get session :message-window)))

(defun maillist--update-row-from-thread (session id thread)
  "Copy the author facts of THREAD onto row ID of SESSION."
  (let* ((messages (plist-get thread :messages))
         (first (car messages))
         (fields (list :author (or (and first (plist-get first :author)) "")
                       :participants (or (plist-get thread :participants)
                                         (length messages)))))
    (etaf-set-value (plist-get session :threads)
                    (maillist--replace-row session id fields))
    (etaf-set-value (plist-get session :groups)
                    (maillist--grouped (maillist-rows session)))
    (when-let* ((store (plist-get session :store)))
      (condition-case nil
          (maillist-store-save-threads
           store (seq-filter (lambda (row) (equal id (plist-get row :id)))
                             (etaf-value (plist-get session :threads))))
        (error nil)))))

(defun maillist--load-thread (session row token)
  "Fetch the body of ROW for SESSION generation TOKEN."
  (let ((id (plist-get row :id))
        (subject (plist-get row :subject)))
    (maillist-fetch-thread
     (plist-get session :source) id
     (lambda (result)
       (when (maillist--current-p session token)
         (if-let* ((error (plist-get result :error)))
             (when (plist-get (etaf-value (plist-get session :open)) :loading)
               (etaf-set-value (plist-get session :open)
                               (plist-put (maillist--thread-placeholder row error)
                                          :error t)))
           (let ((thread (plist-get result :ok)))
             (when-let* ((store (plist-get session :store)))
               (condition-case err
                   (maillist-store-save-thread-messages
                    store id (plist-get thread :messages))
                 (error (message "maillist: 无法缓存线程正文：%s"
                                 (error-message-string err)))))
             (if (and (cl-find id (plist-get thread :messages)
                               :key (lambda (message) (plist-get message :id))
                               :test #'equal)
                      (maillist--thread-matches-subject-p
                       (plist-get thread :messages) subject))
                 (progn
                   (maillist--update-row-from-thread session id thread)
                   (maillist--publish-thread session row (plist-get thread :messages))
                   (maillist--apply-view session))
               ;; The archive can merge a thread into an older discussion;
               ;; its document then stops at the entry cap and misses the mail
               ;; the index named.  The subject feed still has them.
               (maillist--load-by-subject session row token))))))
     subject)))

(defun maillist--thread-matches-subject-p (messages subject)
  "Return non-nil when most MESSAGES share SUBJECT.
A public-inbox thread can be merged into an older discussion by a reply with
broken References; the merged document then carries dozens of subjects while
the index names this one."
  (let* ((wanted (maillist-thread-subject subject))
         (total (length messages))
         (matching (seq-count
                    (lambda (message)
                      (equal wanted
                             (maillist-thread-subject
                              (plist-get message :subject))))
                    messages)))
    (or (zerop total) (>= (* matching 2) total))))

(defun maillist--chronological (messages)
  "Return MESSAGES oldest first with their reply depth recomputed.
The search feed answers newest first, while the thread view needs the archive's
reading order."
  (let* ((sorted (sort (copy-sequence messages)
                       (lambda (first second)
                         (string< (or (plist-get first :date) "")
                                  (or (plist-get second :date) "")))))
         (depths (make-hash-table :test #'equal)))
    (dolist (message sorted)
      (let* ((id (plist-get message :id))
             (parent (plist-get message :parent))
             (depth (if (and parent (gethash parent depths))
                        (1+ (gethash parent depths))
                      0)))
        (puthash id depth depths)
        (plist-put message :depth depth)))
    sorted))

(defun maillist--load-by-subject (session row token)
  "Show ROW's messages by subject for SESSION generation TOKEN.
Used when the thread document lost the message the index announced."
  (maillist-fetch-subject
   (plist-get session :source) (plist-get row :subject)
   (lambda (result)
     (when (maillist--current-p session token)
       (let ((messages (maillist--chronological
                        (plist-get (plist-get result :ok) :messages))))
         (if (and messages
                  (cl-find (plist-get row :id) messages
                           :key (lambda (message) (plist-get message :id))
                           :test #'equal))
             (let ((value (maillist--thread-value
                           row messages nil
                           (gethash (plist-get row :id)
                                    (plist-get session :collapsed))
                           (plist-get session :message-window))))
               (etaf-set-value (plist-get session :open)
                               (plist-put value :meta
                                          (format "%d 封 · 档案把该线程并进了旧讨论，按标题显示"
                                                  (length messages))))
               (maillist--apply-view session))
           (maillist--load-newest-fallback session row token)))))))

(defun maillist--load-newest-fallback (session row token)
  "Show only the newest mail of ROW when no thread document has it."
  (maillist-fetch-message
   (plist-get session :source) (plist-get row :id)
   (lambda (result)
     (when (maillist--current-p session token)
       (when-let* ((messages (plist-get (plist-get result :ok) :messages)))
         (let ((value (maillist--thread-value
                       row messages nil
                       (gethash (plist-get row :id)
                                (plist-get session :collapsed))
                       (plist-get session :message-window))))
           (etaf-set-value (plist-get session :open)
                           (plist-put value :meta
                                      "档案的线程数据不完整，只找到这一封（按 g 重试）"))))))))

(defun maillist--open-thread (session row)
  "Show ROW of SESSION, from cache when possible and from the archive after."
  (let* ((token (cl-incf (plist-get session :token)))
         (id (plist-get row :id))
         (cached (and (plist-get session :store)
                      (condition-case nil
                          (maillist-store-thread-messages (plist-get session :store) id)
                        (error nil)))))
    (plist-put session :message-window maillist-message-window)
    (cond
     (cached
      (maillist--publish-thread session row cached t))
     ;; A huge thread is megabytes; show its newest mail from the small
     ;; search feed first, then replace it with the whole conversation.
     ((and (integerp (plist-get row :count))
           (>= (plist-get row :count) maillist-fast-open-threshold))
      (etaf-set-value (plist-get session :open)
                      (maillist--thread-placeholder row "正在加载最新一封…"))
      (maillist--load-newest session row token))
     (t
      (etaf-set-value (plist-get session :open)
                      (maillist--thread-placeholder row "正在加载线程…"))))
    (maillist--load-thread session row token)))

(defun maillist--load-newest (session row token)
  "Show the newest mail of ROW for SESSION generation TOKEN while the thread loads."
  (maillist-fetch-message
   (plist-get session :source) (plist-get row :id)
   (lambda (result)
     (when (maillist--current-p session token)
       (when-let* ((thread (plist-get result :ok))
                   (messages (plist-get thread :messages)))
         (let ((open (etaf-value (plist-get session :open))))
           ;; Only fill the gap: a finished thread is authoritative.
           (when (and (plist-get open :loading)
                      (equal (plist-get open :id) (plist-get row :id)))
             (etaf-set-value
              (plist-get session :open)
              (plist-put (maillist--thread-value row messages t
                                                 (gethash (plist-get row :id)
                                                          (plist-get session :collapsed))
                                                 1)
                         :meta "正在加载完整线程…（先显示最新一封）")))))))))

;;; ---------------------------------------------------------------------------
;;; Sync
;;; ---------------------------------------------------------------------------

(defun maillist--store-rows (session)
  "Persist SESSION's current rows when it has a store."
  (when-let* ((store (plist-get session :store)))
    (condition-case err
        (maillist-store-save-threads store (etaf-value (plist-get session :threads)))
      (error (message "maillist: 无法保存线程列表：%s" (error-message-string err))))))

(defun maillist--merge-authors (rows hints)
  "Return ROWS with missing authors filled from HINTS."
  (mapcar
   (lambda (row)
     (let ((author (plist-get row :author))
           (hint (cdr (assoc (plist-get row :id) hints))))
       (if (or (and author (not (string-empty-p author))) (null hint))
           row
         (maillist--plist-merge row (list :author hint)))))
   rows))

(defun maillist--fetch-authors (session token)
  "Fill missing authors of SESSION generation TOKEN from the archive feed."
  (maillist-fetch-recent
   (plist-get session :source)
   (lambda (result)
     (when (and (maillist--current-sync-p session token)
                (plist-get result :ok))
       (etaf-set-value (plist-get session :threads)
                       (maillist--merge-authors
                        (etaf-value (plist-get session :threads))
                        (plist-get result :ok)))
       (etaf-set-value (plist-get session :groups)
                       (maillist--grouped (maillist-rows session)))
       (maillist--store-rows session)))))

(defun maillist--set-author (session id author)
  "Store AUTHOR on row ID of SESSION and publish the new list."
  (etaf-set-value (plist-get session :threads)
                  (maillist--replace-row session id (list :author author)))
  (etaf-set-value (plist-get session :groups)
                  (maillist--grouped (maillist-rows session)))
  (when-let* ((store (plist-get session :store)))
    (condition-case nil
        (maillist-store-save-threads
         store (seq-filter (lambda (row) (equal id (plist-get row :id)))
                           (etaf-value (plist-get session :threads))))
      (error nil))))

(defun maillist--prefetch-continue (session token rest failures batch-failures size)
  "Continue the sender prefetch of SESSION after one batch.
REST is the remaining queue, FAILURES the count from earlier batches, and a
whole failed batch schedules one retry instead of hammering."
  (cond
   ((>= batch-failures size)
    (unless (plist-get session :prefetch-retried)
      (plist-put session :prefetch-retried t)
      (run-at-time 30 nil
                   (lambda ()
                     (when (maillist--current-sync-p session token)
                       (maillist--prefetch session token))))))
   (rest
    (run-at-time 0.1 nil
                 (lambda ()
                   (maillist--prefetch-batch
                    session token rest (+ failures batch-failures)))))))

(defun maillist--prefetch-batch (session token queue failures)
  "Fetch QUEUE in parallel batches for SESSION generation TOKEN.
FAILURES counts sender requests an earlier batch could not complete."
  (when (and (maillist--current-sync-p session token) queue)
    (let* ((size (max 1 maillist-prefetch-parallel))
           (batch (seq-take queue size))
           (rest (seq-drop queue size))
           (pending (length batch))
           (batch-failures 0))
      (dolist (row batch)
        (let ((id (plist-get row :id)))
          (maillist-fetch-author
           (plist-get session :source) id
           (lambda (result)
             (when (maillist--current-sync-p session token)
               (if (plist-get result :error)
                   (cl-incf batch-failures)
                 (when-let* ((name (plist-get result :ok)))
                   (unless (string-empty-p name)
                     (maillist--set-author session id name))))
               (cl-decf pending)
               (when (zerop pending)
                 (maillist--prefetch-continue
                  session token rest failures batch-failures size))))))))))

(defun maillist--prefetch (session token)
  "Fill the senders of SESSION's threads that still lack one."
  (when (> maillist-prefetch-threads 0)
    (plist-put session :prefetch-retried nil)
    (maillist--prefetch-batch
     session token
     (seq-take
      (seq-filter (lambda (row)
                    (string-empty-p (or (plist-get row :author) "")))
                  (etaf-value (plist-get session :threads)))
      maillist-prefetch-threads)
     0)))

(defun maillist-refresh (session)
  "Reload SESSION's thread list from its archive."
  (when (maillist--alive-p session)
    (let ((token (cl-incf (plist-get session :sync-token))))
      (maillist--status session 'loading "正在同步邮件列表…")
      (maillist-fetch-index
       (plist-get session :source)
       (lambda (result)
         (when (maillist--current-sync-p session token)
           (if-let* ((error (plist-get result :error)))
               (maillist--status session 'error
                                 (format "同步失败：%s · 按 g 重试" error))
             (progn
               (etaf-set-value (plist-get session :threads)
                               (maillist--merge-rows (plist-get result :ok) session))
               (plist-put session :last-sync (current-time))
               (maillist--store-rows session)
               (maillist--apply-view session)
               (maillist--status session 'idle "")
               (maillist--fetch-authors session token)
               (maillist--prefetch session token)))))))))

(defun maillist-set-scope (session scope)
  "Show only SCOPE (`all', `unread' or `starred') rows of SESSION."
  (etaf-set-value (plist-get session :scope) scope)
  (maillist--apply-view session))

(defun maillist-search (session text)
  "Search SESSION's archive for TEXT.
An empty TEXT returns to the archive's own thread index."
  (let ((query (string-trim (or text ""))))
    (etaf-set-value (plist-get session :query) query)
    (etaf-set-value (plist-get session :scope) 'all)
    (if (string-empty-p query)
        (progn
          (plist-put session :last-sync nil)
          (maillist-refresh session))
      (let ((token (cl-incf (plist-get session :sync-token))))
        (maillist--status session 'loading (format "正在搜索「%s」…" query))
        (maillist-fetch-search
         (plist-get session :source) query
         (lambda (result)
           (when (maillist--current-sync-p session token)
             (if-let* ((error (plist-get result :error)))
                 (maillist--status session 'error
                                   (format "搜索失败：%s · 按 g 重试" error))
               (let ((rows (maillist--merge-rows (plist-get result :ok) session)))
                 (etaf-set-value (plist-get session :threads) rows)
                 (maillist--apply-view session)
                 (maillist--status session 'idle "")
                 (when (null rows)
                   (maillist--toast session 'info
                                    "没有匹配的线程，清空搜索框回到列表" 5)))))))))))

(defun maillist-dispose (session)
  "Release SESSION's store and ignore late archive answers."
  (plist-put session :alive nil)
  (when-let* ((timer (plist-get session :toast-timer)))
    (cancel-timer timer)
    (plist-put session :toast-timer nil))
  (when-let* ((store (plist-get session :store)))
    (condition-case nil (maillist-store-close store) (error nil))))

;;; ---------------------------------------------------------------------------
;;; Creation
;;; ---------------------------------------------------------------------------

(cl-defun maillist-create (&key (list maillist-default-list))
  "Create a client session over the archive LIST.
Rows come from the local cache first and from the archive after
`maillist-refresh'; the return value is the session plist whose refs the
Views read."
  (let* ((source (maillist-source list))
         (store (maillist-store-open))
         (cached (or (and store
                          (condition-case nil
                              (maillist-store-threads store)
                            (error nil)))
                     '()))
         (rows (mapcar #'maillist--row-from-record cached))
         (session (list :source source
                        :store store
                        :alive t
                        :token 0
                        :sync-token 0
                        :last-sync nil
                        :threads (maillist--ref rows 'maillist-threads)
                        :groups (maillist--ref (maillist--grouped rows) 'maillist-groups)
                        :open (maillist--ref nil 'maillist-open)
                        :selected (maillist--ref nil 'maillist-selected)
                        :scope (maillist--ref 'all 'maillist-scope)
                        :query (maillist--ref "" 'maillist-query)
                        :summary (maillist--ref "" 'maillist-summary)
                        :status (maillist--ref (list :kind 'idle :text "") 'maillist-status)
                        :toast (maillist--ref nil 'maillist-toast)
                        :reading (maillist--ref nil 'maillist-reading)
                        :collapsed (make-hash-table :test #'equal)
                        :message-window maillist-message-window
                        :open-messages nil
                        :viewport (maillist--ref 160 'maillist-viewport)
                        :viewport-px (maillist--ref 0 'maillist-viewport-px)
                        :list-width (maillist--ref 0 'maillist-list-width))))
    (etaf-set-value (plist-get session :summary) (maillist--summary session))
    session))

(provide 'maillist-model)
;;; maillist-model.el ends here
