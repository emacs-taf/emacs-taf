;;; maillist-model.el --- State of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns every value a View reads: the thread rows, the groups they
;; are shown in, the open thread, the scope, the focused message, quote
;; folding, search input and sync status.  The archive's authoritative rows
;; live in `:archive-threads' separately from `:threads' (which may display
;; search results), so clearing a search restores the cached list instantly
;; and background syncs never contaminate SQLite with search rows.
;;
;; Reading is a two-stage load.  Cached rows appear immediately, the archive
;; index merges into them when it arrives, and thread bodies are fetched when
;; a row is opened.  Marks record the last-read snapshot (`:read-date' and
;; `:read-count') so new replies on a previously read discussion re-surface as
;; unread and new.  Cached bodies stay on screen when a background refresh
;; fails offline.
;;
;; Every asynchronous answer carries a generation number so a slow reply for a
;; previously selected row never overwrites the current one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'maillist-service)
(require 'maillist-nntp)
(require 'maillist-store)

(defvar maillist--live-sessions 0
  "Number of currently open maillist sessions.")

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

(defcustom maillist-thread-freshness 60
  "Seconds a freshly fetched thread stays fresh without re-fetching `t.atom'.
Reopening a thread within this window serves its cached messages immediately
unless a sync reported newer replies.  Set to 0 to always refresh."
  :type 'integer
  :group 'maillist)

(defcustom maillist-prefetch-parallel 1
  "How many HTTP sender requests the client keeps in flight.
Kept conservative (`1' by default) so HTTP-only archives behind anti-bot
proxies are not rate-limited; NNTP-backed sources receive senders directly
from `XOVER' and need no `/raw' prefetch."
  :type 'integer
  :group 'maillist)

(defcustom maillist-prefetch-bodies 10
  "How many uncached unread/recent threads to pre-cache quietly in the background.
Prefetching runs one thread at a time at low priority after a sync and pauses
immediately while a user-initiated thread open is in flight, so stepping down
the list hits the local SQLite cache in 0 ms.  Set to 0 to disable."
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

(defcustom maillist-auto-refresh 300
  "Seconds between automatic syncs of an open client.
Nil syncs only on demand.  A quiet sync never announces itself; a thread the
archive added since the previous sync shows in the summary and in its own
colour."
  :type '(choice (const :tag "Only on demand" nil) integer)
  :group 'maillist)

(defcustom maillist-older-batch 50
  "How many older messages one `maillist-load-older' adds.
When paging through the archive's date search, rows are grouped by subject
and capped at this count."
  :type 'integer
  :group 'maillist)

(defcustom maillist-local-search-limit 50
  "How many cached threads a search reports when the archive cannot answer."
  :type 'integer
  :group 'maillist)

(defcustom maillist-narrow-width 104
  "Viewport width below which the client shows one column."
  :type 'integer
  :group 'maillist)

;;; ---------------------------------------------------------------------------
;;; Custom archive sources
;;; ---------------------------------------------------------------------------

(defun maillist--load-custom-sources (store)
  "Return custom source plists saved in STORE's settings, or nil."
  (when store
    (when-let* ((raw (ignore-errors (maillist-store-setting "custom-sources" store))))
      (let ((parsed (ignore-errors (read raw))))
        (and (listp parsed) parsed)))))

(defun maillist--save-custom-sources (sources &optional store)
  "Persist custom SOURCES plists into STORE's settings."
  (ignore-errors
    (maillist-store-save-setting "custom-sources" (prin1-to-string sources) store)))

(defun maillist--merge-custom-sources (store)
  "Register custom sources stored in STORE into `maillist-sources'."
  (dolist (src (maillist--load-custom-sources store))
    (let ((name (plist-get src :name)))
      (when (and (stringp name)
                 (not (cl-find name maillist-sources
                               :key (lambda (s) (plist-get s :name))
                               :test #'equal)))
        (setq maillist-sources (append maillist-sources (list src)))))))

(defun maillist-add-source (name base address &optional reply-style)
  "Add or update public-inbox archive NAME at BASE with list ADDRESS.
Optional REPLY-STYLE may be `debbugs' for GNU bug lists.  The source is added
to `maillist-sources' and saved in the store so later sessions keep it."
  (interactive
   (let* ((name (string-trim (read-string "列表名称（如 orgmode）: ")))
          (base (string-trim (read-string "档案根地址（如 https://yhetil.org/orgmode/）: ")))
          (address (string-trim (read-string "发信地址（如 emacs-orgmode@gnu.org）: "))))
     (list name base address)))
  (when (or (string-empty-p name) (string-empty-p base) (string-empty-p address))
    (user-error "名称、档案地址与发信地址均不能为空"))
  (let* ((norm-base (if (string-suffix-p "/" base) base (concat base "/")))
         (entry (append (list :name name :base norm-base :address address)
                        (when reply-style (list :reply-style reply-style))))
         (others (cl-remove name maillist-sources
                            :key (lambda (s) (plist-get s :name))
                            :test #'equal))
         (store (ignore-errors (maillist-store-open))))
    (setq maillist-sources (append others (list entry)))
    (when store
      (unwind-protect
          (let* ((custom (cl-remove name (maillist--load-custom-sources store)
                                    :key (lambda (s) (plist-get s :name))
                                    :test #'equal)))
            (maillist--save-custom-sources (append custom (list entry)) store))
        (maillist-store-close store)))
    entry))

(defun maillist-remove-source (name)
  "Remove archive NAME from `maillist-sources' and from saved custom sources."
  (interactive
   (list (completing-read
          "移除邮件列表："
          (mapcar (lambda (s) (plist-get s :name)) maillist-sources)
          nil t)))
  (setq maillist-sources
        (cl-remove name maillist-sources
                   :key (lambda (s) (plist-get s :name))
                   :test #'equal))
  (when-let* ((store (ignore-errors (maillist-store-open))))
    (unwind-protect
        (let ((custom (cl-remove name (maillist--load-custom-sources store)
                                 :key (lambda (s) (plist-get s :name))
                                 :test #'equal)))
          (maillist--save-custom-sources custom store))
      (maillist-store-close store)))
  name)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

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
still warming must not cancel the author prefetch."
  (and (maillist--alive-p session)
       (equal token (plist-get session :sync-token))))

(defun maillist--clear-toast (session)
  "Remove SESSION's floating notice."
  (when-let* ((timer (plist-get session :toast-timer)))
    (cancel-timer timer)
    (plist-put session :toast-timer nil))
  (when (etaf-value (plist-get session :toast))
    (etaf-set-value (plist-get session :toast) nil)))

(defun maillist-thread-url (session id)
  "Return the archive's own page for thread ID of SESSION.
It is the address a reader shares with someone who does not use this client."
  (concat (plist-get (plist-get session :source) :base)
          (maillist--encode-path-id id) "/"))

(defun maillist-thread-mbox-url (session id)
  "Return the downloadable gzipped mbox URL for thread ID of SESSION.
Public-inbox serves `<id>/t.mbox.gz' for applying patch series with `git am'."
  (concat (plist-get (plist-get session :source) :base)
          (maillist--encode-path-id id) "/t.mbox.gz"))

(defun maillist--remember-query (session query)
  "Put QUERY at the head of SESSION's search history.
An empty query is the archive's own list, not a search, and a query already in
the history keeps its place: recalling it must not reorder the walk."
  (when (and (stringp query) (not (string-empty-p query)))
    (let ((history (plist-get session :query-history)))
      (unless (member query history)
        (plist-put session :query-history
                   (seq-take (cons query history) 20))))))

(defun maillist-recall-query (session &optional forward)
  "Search SESSION again with an older or newer query from its history.
History holds the queries this client ran, newest first.  Without FORWARD the
walk moves toward the oldest query and, past it, to the archive's own list;
FORWARD moves back toward the newest.  Return the query now shown, empty for
the list."
  (let* ((history (plist-get session :query-history))
         (current (or (etaf-value (plist-get session :query)) ""))
         (at (cl-position current history :test #'equal))
         (index (if forward (if at (1- at) 0) (if at (1+ at) 0)))
         (query (if (and (>= index 0) (< index (length history)))
                    (nth index history)
                  "")))
    (maillist-search session query)
    query))

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
;;; Rows & new-reply detection
;;; ---------------------------------------------------------------------------

(defun maillist--remembered-list (store)
  "Return the archive name STORE last opened, or nil."
  (when store
    (ignore-errors (maillist-store-setting "last-list" store))))

(defun maillist--has-new-replies-p (old-date old-count new-date new-count)
  "Return non-nil when NEW-DATE or NEW-COUNT advances past OLD-DATE / OLD-COUNT."
  (or (and (stringp new-date) (stringp old-date)
           (not (string-empty-p new-date))
           (not (string-empty-p old-date))
           (string> new-date old-date))
      (and (integerp new-count) (integerp old-count)
           (> new-count old-count))))

(defun maillist--row-from-record (record mark)
  "Return the visible row described by the stored RECORD and MARK.
MARK is the reader's own state of the thread, or nil for a thread never
opened or starred.  If the archive record is newer than the mark's last-read
snapshot, the thread surfaces as unread with `:new-since' set."
  (let* ((was-read (and mark (plist-get mark :read)))
         (read-date (and mark (plist-get mark :read-date)))
         (read-count (and mark (plist-get mark :read-count)))
         (rec-date (plist-get record :date))
         (rec-count (plist-get record :count))
         (new-replies (and was-read
                           (maillist--has-new-replies-p
                            read-date read-count rec-date rec-count))))
    (list :id (plist-get record :id)
          :subject (or (plist-get record :subject) "")
          :date rec-date
          :count rec-count
          :depth (or (plist-get record :depth) 0)
          :author (or (plist-get record :author) "")
          :participants (plist-get record :participants)
          :unread (or (not was-read) new-replies)
          :starred (and (plist-get mark :starred) t)
          :read-date read-date
          :read-count read-count
          :new-since (when new-replies read-date))))

(defun maillist--known-table (rows)
  "Build an id -> row hash table from ROWS."
  (let ((known (make-hash-table :test #'equal)))
    (dolist (row rows known)
      (puthash (plist-get row :id) row known))))

(defun maillist--merge-rows (fetched session &optional base-rows)
  "Return FETCHED rows carrying read, starred and author state from BASE-ROWS.
BASE-ROWS defaults to SESSION's `:archive-threads' (falling back to `:threads').
A previously read thread that gained newer replies re-surfaces as unread and
new; an already-known thread whose date and count did not advance keeps its
mark."
  (let* ((source-rows (or base-rows
                          (plist-get session :archive-threads)
                          (etaf-value (plist-get session :threads))))
         (known (maillist--known-table source-rows))
         (synced (plist-get session :last-sync)))
    (mapcar
     (lambda (row)
       (let* ((id (plist-get row :id))
              (old (gethash id known))
              (new-date (or (plist-get row :date) (plist-get old :date)))
              (new-count (or (plist-get row :count) (plist-get old :count)))
              (was-read (and old (not (plist-get old :unread))))
              (ref-date (and old (or (plist-get old :read-date) (plist-get old :date))))
              (ref-count (and old (or (plist-get old :read-count) (plist-get old :count))))
              (got-replies (and was-read
                                (maillist--has-new-replies-p
                                 ref-date ref-count new-date new-count)))
              (unread (cond ((null old) t)
                            (got-replies t)
                            (t (plist-get old :unread))))
              (is-new (and synced
                           (or (null old) got-replies)
                           t)))
         (when got-replies
           ;; Invalidate freshness so opening fetches the newly arrived mail.
           (remhash id (plist-get session :thread-fetched-at)))
         (list :id id
               :subject (or (plist-get row :subject) "")
               :date new-date
               :count new-count
               :depth (or (plist-get row :depth) 0)
               :author (or (and (not (string-empty-p (or (plist-get row :author) "")))
                                (plist-get row :author))
                           (plist-get old :author)
                           "")
               :participants (plist-get old :participants)
               :unread unread
               :starred (and old (plist-get old :starred))
               :read-date (and old (plist-get old :read-date))
               :read-count (and old (plist-get old :read-count))
               :new-since (cond (got-replies ref-date)
                                (old (plist-get old :new-since)))
               :new is-new)))
     fetched)))

(defun maillist--by-date (rows)
  "Return ROWS newest first, keeping their given order where dates are equal.
A buried reply keeps the archive's depth, and a reply sorts after the message
it answers when both carry one date, so the list keeps the thread's shape."
  (let* ((indexed (cl-loop for row in rows
                           for index from 0
                           collect (cons index row)))
         (sorted (sort indexed
                       (lambda (first second)
                         (let ((left (or (plist-get (cdr first) :date) ""))
                               (right (or (plist-get (cdr second) :date) ""))
                               (left-depth (or (plist-get (cdr first) :depth) 0))
                               (right-depth (or (plist-get (cdr second) :depth) 0)))
                           (cond
                            ((not (equal left right)) (string> left right))
                            ((/= left-depth right-depth) (< left-depth right-depth))
                            (t (< (car first) (car second)))))))))
    (mapcar #'cdr sorted)))

(defun maillist--window-rows (fetched session)
  "Return FETCHED rows merged with SESSION's `:archive-threads', newest first.
An index page lists recent threads only; cached threads it no longer names
stay in `:archive-threads' so a refresh never shortens the reader's list.
Rows not newly added on this refresh drop any stale `:new' flag once older."
  (let* ((existing (plist-get session :archive-threads))
         (seen (make-hash-table :test #'equal))
         (all nil))
    (dolist (row (maillist--merge-rows fetched session existing))
      (puthash (plist-get row :id) t seen)
      (push row all))
    (dolist (row existing)
      (unless (gethash (plist-get row :id) seen)
        (puthash (plist-get row :id) t seen)
        (push (if (and (plist-get row :new) (not (plist-get row :unread)))
                  (maillist--plist-merge row (list :new nil))
                row)
              all)))
    (maillist--by-date (nreverse all))))

(defun maillist--plist-merge (plist fields)
  "Return PLIST with FIELDS applied, keeping one entry per key.
FIELDS wins; every other PLIST entry keeps its order after them."
  (let ((result (copy-sequence fields)))
    (cl-loop for (key value) on plist by #'cddr
             unless (plist-member fields key)
             do (setq result (append result (list key value))))
    result))

(defun maillist--replace-in-list (rows id fields)
  "Return ROWS with FIELDS applied to the row whose `:id' equals ID."
  (mapcar (lambda (row)
            (if (equal id (plist-get row :id))
                (maillist--plist-merge row fields)
              row))
          rows))

(defun maillist--replace-row (session id fields &optional archive-too)
  "Update row ID in SESSION's visible `:threads' with FIELDS.
When ARCHIVE-TOO is non-nil (or when showing the archive list), also update
`:archive-threads'."
  (let* ((archive-view (maillist--archive-list-p session))
         (updated (maillist--replace-in-list
                   (etaf-value (plist-get session :threads)) id fields)))
    (etaf-set-value (plist-get session :threads) updated)
    (cond
     (archive-view
      (plist-put session :archive-threads updated))
     (archive-too
      (plist-put session :archive-threads
                 (maillist--replace-in-list
                  (plist-get session :archive-threads) id fields))))
    updated))

(defun maillist--row-matches-filter-p (row filter)
  "Return non-nil when ROW satisfies local query FILTER."
  (pcase filter
    ('unread (plist-get row :unread))
    ('read (not (plist-get row :unread)))
    ('starred (plist-get row :starred))
    ('unstarred (not (plist-get row :starred)))
    (_ t)))

(defun maillist-rows (session)
  "Return the visible rows of SESSION in list order.
A local filter from the current query (`is:unread', `is:read', `is:starred'
and their `-is:' negations) hides rows that do not match it.  Under a scope
or local filter, `:sticky-row' keeps a row that was opened or toggled *within*
that view visible until the user moves on or switches scope, without dragging
unrelated rows across scope changes."
  (let* ((rows (etaf-value (plist-get session :threads)))
         (filters (etaf-value (plist-get session :filters)))
         (scope (etaf-value (plist-get session :scope)))
         (sticky (plist-get session :sticky-row)))
    (when filters
      (setq rows
            (seq-filter (lambda (row)
                          (or (equal (plist-get row :id) sticky)
                              (cl-every
                               (lambda (filter)
                                 (maillist--row-matches-filter-p row filter))
                               filters)))
                        rows)))
    (if (eq scope 'all)
        rows
      (seq-filter (lambda (row)
                    (or (equal (plist-get row :id) sticky)
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
  (let* ((today (format-time-string "%Y-%m-%d"))
         (yesterday (format-time-string "%Y-%m-%d" (time-subtract nil 86400)))
         (week-ago (format-time-string "%Y-%m-%d" (time-subtract nil (* 7 86400))))
         (groups nil))
    (dolist (row rows)
      (let* ((stamp (plist-get row :date))
             (label (if (and (stringp stamp) (>= (length stamp) 10)
                             (not (string-suffix-p "Z" stamp)))
                        (let ((day (substring stamp 0 10)))
                          (cond ((equal day today) "今天")
                                ((equal day yesterday) "昨天")
                                ((string> day week-ago) "本周")
                                (t "更早")))
                      (maillist-day-label stamp)))
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
         (filters (etaf-value (plist-get session :filters)))
         (rows (etaf-value (plist-get session :threads)))
         (sync (plist-get session :last-sync)))
    (if (not (string-empty-p query))
        (format "搜索结果 %d 个线程%s"
                (length (maillist-rows session))
                (if filters "（本地筛选）" ""))
      (concat (format "%d 个线程 · %d 未读" (length rows) (maillist--unread-count rows))
              (let ((news (seq-count (lambda (row) (plist-get row :new)) rows)))
                (if (> news 0) (format " · %d 新" news) ""))
              (if sync (format " · %s 同步" (format-time-string "%H:%M" sync)) "")))))

(defun maillist--narrow-session-p (session)
  "Return non-nil when SESSION's viewport is narrower than `maillist-narrow-width'."
  (< (or (etaf-value (plist-get session :viewport)) 160) maillist-narrow-width))

(defun maillist--apply-view (session &optional open-p)
  "Publish the groups, summary and selection SESSION's rows imply.
OPEN-P opens the first row when the previous selection is gone AND the reader
is visible (wide layout or narrow reading state); in a narrow list-only window
it moves selection without fetching or marking unread threads read off-screen."
  (etaf-batch
    (let ((rows (maillist-rows session)))
      (etaf-set-value (plist-get session :groups) (maillist--grouped rows))
      (etaf-set-value (plist-get session :summary) (maillist--summary session))
      (when (and (maillist--alive-p session)
                 rows
                 (not (maillist-selected-row session)))
        (let ((reader-visible (or (not (maillist--narrow-session-p session))
                                  (etaf-value (plist-get session :reading)))))
          (if (and open-p reader-visible)
              (maillist-select session (plist-get (car rows) :id))
            (etaf-set-value (plist-get session :selected)
                            (plist-get (car rows) :id))))))))

;;; ---------------------------------------------------------------------------
;;; Selection, navigation and marks
;;; ---------------------------------------------------------------------------

(defun maillist--persist-mark (session id)
  "Persist the current read, starred and read-snapshot state of thread ID."
  (when-let* ((store (plist-get session :store))
              (row (or (maillist-row session id)
                       (seq-find (lambda (r) (equal (plist-get r :id) id))
                                 (plist-get session :archive-threads)))))
    (let ((read (not (plist-get row :unread))))
      (condition-case err
          (maillist-store-save-mark store id
                                    read
                                    (and (plist-get row :starred) t)
                                    (when read (plist-get row :read-date))
                                    (when read (plist-get row :read-count)))
        (error (message "maillist: 无法保存线程标记：%s"
                        (error-message-string err)))))))

(defun maillist--mark-read (session id)
  "Mark thread ID of SESSION read, clear `:new', record snapshot and persist.
Called once its body is on screen, so a fetch that never answered leaves the
row unread."
  (when-let* ((row (maillist-row session id)))
    (when (or (plist-get row :unread) (plist-get row :new))
      (let ((read-date (plist-get row :date))
            (read-count (plist-get row :count)))
        (maillist--replace-row
         session id
         (list :unread nil :new nil
               :read-date read-date :read-count read-count)
         t)
        (maillist--persist-mark session id)
        (maillist--apply-view session)))))

(defun maillist--clear-open (session)
  "Close SESSION's open thread and drop its selection.
A new query shows a different set of rows, so the reader starts empty rather
than showing a thread the list no longer contains."
  (etaf-set-value (plist-get session :open) nil)
  (etaf-set-value (plist-get session :reading) nil)
  (etaf-set-value (plist-get session :selected) nil)
  (etaf-set-value (plist-get session :focused-message) nil)
  (plist-put session :open-messages nil)
  (plist-put session :open-messages-id nil))

(defun maillist--archive-list-p (session)
  "Return non-nil when SESSION shows the archive's list, not search results.
Only that list may write the thread table: search results carry another
source's view of a row and must not become the stored fact."
  (string-empty-p (etaf-value (plist-get session :query))))

(defun maillist-select (session id &optional no-mark)
  "Open the row ID of SESSION.
NO-MARK leaves the read state alone; otherwise the thread is marked read once
its body has been shown, not when the row was selected."
  (when-let* ((row (maillist-row session id)))
    (etaf-batch
      (etaf-set-value (plist-get session :selected) id)
      (plist-put session :sticky-row
                 (when (or (not (eq (etaf-value (plist-get session :scope)) 'all))
                           (etaf-value (plist-get session :filters)))
                   id))
      (plist-put session :mark-on-render (not no-mark))
      (maillist--open-thread session row)
      (when (or (not (eq (etaf-value (plist-get session :scope)) 'all))
                (etaf-value (plist-get session :filters)))
        (maillist--apply-view session)))
    (etaf-value (plist-get session :open))))

(defun maillist-move (session delta &optional no-open)
  "Move the selection of SESSION by DELTA rows and open the new row.
When NO-OPEN is non-nil, move the selection highlight without fetching or
marking the row read (used in narrow list-only mode)."
  (let* ((rows (maillist-rows session))
         (current (etaf-value (plist-get session :selected)))
         (found (cl-position current rows
                             :key (lambda (row) (plist-get row :id))
                             :test #'equal))
         ;; A filtered list can lack the old selection; the first move then
         ;; starts at the first row in that direction.
         (index (or found (if (< delta 0) (length rows) -1)))
         (next (and rows
                    (nth (max 0 (min (1- (length rows)) (+ index delta))) rows))))
    (when next
      (let ((id (plist-get next :id)))
        (if no-open
            (progn
              (etaf-set-value (plist-get session :selected) id)
              id)
          (maillist-select session id))))))

(defun maillist-next-unread (session)
  "Open the first unread row after SESSION's selection and return its id.
The walk starts at the row after the selected one, so pressing `n' repeatedly
visits each unread thread once; past the last row it returns nil and leaves
the selection where it was."
  (let* ((rows (maillist-rows session))
         (current (etaf-value (plist-get session :selected)))
         (at (cl-position current rows :key (lambda (row) (plist-get row :id))
                          :test #'equal))
         (rest (nthcdr (if at (1+ at) 0) rows))
         (unread (cl-find-if (lambda (row) (plist-get row :unread)) rest)))
    (when unread
      (maillist-select session (plist-get unread :id))
      (plist-get unread :id))))

(defun maillist-prev-unread (session)
  "Open the nearest unread row before SESSION's selection and return its id.
Returns nil without changing selection when no earlier row is unread."
  (let* ((rows (maillist-rows session))
         (current (etaf-value (plist-get session :selected)))
         (at (cl-position current rows :key (lambda (row) (plist-get row :id))
                          :test #'equal))
         (before (if at (seq-take rows at) rows))
         (unread (cl-find-if (lambda (row) (plist-get row :unread))
                             (reverse before))))
    (when unread
      (maillist-select session (plist-get unread :id))
      (plist-get unread :id))))

(defun maillist-select-edge (session edge &optional no-open)
  "Select the EDGE row of SESSION: `first' or `last'.
When NO-OPEN is non-nil, move selection without opening the reader."
  (let* ((rows (maillist-rows session))
         (row (pcase edge ('last (car (last rows))) (_ (car rows)))))
    (when row
      (let ((id (plist-get row :id)))
        (if no-open
            (etaf-set-value (plist-get session :selected) id)
          (maillist-select session id))
        id))))

(defun maillist-select-message (session id)
  "Focus message ID inside SESSION's open thread and return ID, or nil."
  (let* ((open (etaf-value (plist-get session :open)))
         (found (cl-find id (plist-get open :messages)
                         :key (lambda (m) (plist-get m :id))
                         :test #'equal)))
    (when found
      (etaf-set-value (plist-get session :focused-message) id)
      id)))

(defun maillist-move-message (session delta)
  "Move the focused message in SESSION's open thread by DELTA and return its id."
  (let* ((open (etaf-value (plist-get session :open)))
         (messages (plist-get open :messages)))
    (when messages
      (let* ((current (etaf-value (plist-get session :focused-message)))
             (at (cl-position current messages
                              :key (lambda (m) (plist-get m :id))
                              :test #'equal))
             (index (or at (if (< delta 0) (length messages) -1)))
             (next (nth (max 0 (min (1- (length messages)) (+ index delta)))
                        messages))
             (id (plist-get next :id)))
        (etaf-set-value (plist-get session :focused-message) id)
        id))))

(defun maillist-toggle-message (session id)
  "Fold or unfold message ID in the open thread of SESSION.
Also focuses message ID so a subsequent reply targets it.  The fold state
survives a body reload because the session remembers it."
  (let* ((open (etaf-value (plist-get session :open)))
         (message (cl-find id (plist-get open :messages)
                           :key (lambda (item) (plist-get item :id))
                           :test #'equal)))
    (when message
      (let* ((collapsed (not (plist-get message :collapsed)))
             (thread-id (plist-get open :id))
             (known (copy-sequence
                     (gethash thread-id (plist-get session :collapsed))))
             (updated (if collapsed
                          (cl-adjoin id known :test #'equal)
                        (delete id known))))
        (puthash thread-id updated (plist-get session :collapsed))
        (etaf-set-value (plist-get session :focused-message) id)
        (etaf-set-value
         (plist-get session :open)
         (plist-put (copy-sequence open) :messages
                    (mapcar (lambda (item)
                              (if (equal id (plist-get item :id))
                                  (plist-put (copy-sequence item) :collapsed collapsed)
                                item))
                            (plist-get open :messages))))
        collapsed))))

(defun maillist-toggle-all-messages (session)
  "Collapse every visible message in SESSION's open thread, or expand all.
If any visible message is currently expanded, collapse all of them; otherwise
expand all.  Return non-nil when messages are now collapsed."
  (when-let* ((open (etaf-value (plist-get session :open)))
              (messages (plist-get open :messages)))
    (let* ((collapse-p (cl-some (lambda (m) (not (plist-get m :collapsed))) messages))
           (thread-id (plist-get open :id))
           (ids (if collapse-p
                    (mapcar (lambda (m) (plist-get m :id)) messages)
                  nil)))
      (puthash thread-id ids (plist-get session :collapsed))
      (etaf-set-value
       (plist-get session :open)
       (plist-put (copy-sequence open) :messages
                  (mapcar (lambda (m)
                            (plist-put (copy-sequence m) :collapsed collapse-p))
                          messages)))
      collapse-p)))

(defun maillist-toggle-quotes (session)
  "Toggle collapsing long quoted blocks inside SESSION's reader.
Return the new boolean state (non-nil means quotes are collapsed)."
  (let ((next (not (etaf-value (plist-get session :hide-quotes)))))
    (etaf-set-value (plist-get session :hide-quotes) next)
    next))

(defun maillist-toggle-star (session)
  "Toggle the star of SESSION's selected row and persist it."
  (when-let* ((row (maillist-selected-row session)))
    (let ((starred (not (plist-get row :starred)))
          (id (plist-get row :id)))
      (when (eq (etaf-value (plist-get session :scope)) 'starred)
        (plist-put session :sticky-row id))
      (maillist--replace-row session id (list :starred starred) t)
      (when-let* ((open (etaf-value (plist-get session :open)))
                  (_ (equal (plist-get open :id) id)))
        (etaf-set-value (plist-get session :open)
                        (plist-put (copy-sequence open) :starred starred)))
      (maillist--persist-mark session id)
      (maillist--apply-view session)
      starred)))

(defun maillist-set-read (session id read)
  "Set thread ID of SESSION read or unread, persist the mark and return it.
Marking a thread unread puts it back in the queue, and a sync does not undo
it; marking read clears `:new' and records the current snapshot."
  (when-let* ((row (maillist-row session id)))
    (let ((unread (not (and read t))))
      (unless (eq (and (plist-get row :unread) t) unread)
        (maillist--replace-row
         session id
         (if unread
             (list :unread t :read-date nil :read-count nil :new-since nil)
           (list :unread nil :new nil
                 :read-date (plist-get row :date)
                 :read-count (plist-get row :count)))
         t)
        (maillist--persist-mark session id)
        (maillist--apply-view session))
      (not unread))))

(defun maillist-mark-all-read (session)
  "Mark every row SESSION shows read and return how many changed.
One scope or search result is what the reader sees, so that is what the
command covers; the marks go to the store in one transaction."
  (let* ((rows (maillist-rows session))
         (unread (seq-filter (lambda (row) (plist-get row :unread)) rows)))
    (when unread
      (let ((by-id (maillist--known-table unread)))
        (etaf-set-value
         (plist-get session :threads)
         (mapcar (lambda (row)
                   (if (gethash (plist-get row :id) by-id)
                       (maillist--plist-merge
                        row (list :unread nil :new nil
                                  :read-date (plist-get row :date)
                                  :read-count (plist-get row :count)))
                     row))
                 (etaf-value (plist-get session :threads))))
        (plist-put session :archive-threads
                   (mapcar (lambda (row)
                             (if (gethash (plist-get row :id) by-id)
                                 (maillist--plist-merge
                                  row (list :unread nil :new nil
                                            :read-date (plist-get row :date)
                                            :read-count (plist-get row :count)))
                               row))
                           (plist-get session :archive-threads)))
        (maillist--persist-marks
         session
         (mapcar (lambda (row)
                   (list (plist-get row :id) t (and (plist-get row :starred) t)
                         (plist-get row :date) (plist-get row :count)))
                 unread))
        (maillist--apply-view session)))
    (length unread)))

(defun maillist--persist-marks (session marks)
  "Persist MARKS for SESSION."
  (when-let* ((store (plist-get session :store)))
    (condition-case err
        (maillist-store-save-marks store marks)
      (error (message "maillist: 无法保存线程标记：%s" (error-message-string err))))))

;;; ---------------------------------------------------------------------------
;;; Thread bodies
;;; ---------------------------------------------------------------------------

(defun maillist--thread-placeholder (row text)
  "Return the open-thread value for ROW while TEXT describes its state."
  (list :id (plist-get row :id)
        :subject (or (plist-get row :subject) "")
        :meta text
        :starred (and (plist-get row :starred) t)
        :total nil
        :hidden 0
        :loading t
        :refreshing nil
        :messages nil))

(defun maillist--parent-author (message messages)
  "Return the author that MESSAGE replies to among MESSAGES, or nil.
The reader names the person a reply answers, which is the relationship a
thread is actually about."
  (when-let* ((parent (plist-get message :parent))
              (found (cl-find parent messages
                              :key (lambda (item) (plist-get item :id))
                              :test #'equal)))
    (plist-get found :author)))

(defun maillist--unique-participants (messages)
  "Return the count of unique non-empty authors across MESSAGES."
  (let ((names (make-hash-table :test #'equal)))
    (dolist (message messages)
      (let ((author (string-trim (or (plist-get message :author) ""))))
        (unless (string-empty-p author)
          (puthash author t names))))
    (max (hash-table-count names) (if messages 1 0))))

(defun maillist--first-new-message-id (messages watermark)
  "Return the id of the first message in MESSAGES newer than WATERMARK, or nil."
  (when (and (stringp watermark) (not (string-empty-p watermark)))
    (when-let* ((found (cl-find-if
                        (lambda (m)
                          (let ((d (plist-get m :date)))
                            (and (stringp d) (string> d watermark))))
                        messages)))
      (plist-get found :id))))

(defun maillist--thread-value (row messages &optional loading collapsed window refreshing)
  "Return the open-thread value of ROW built from MESSAGES.
LOADING marks a thread still awaiting its first full body; REFRESHING marks
a cached body being checked in the background without showing a skeleton;
WINDOW limits the shown messages to the newest ones and a message whose id is
in COLLAPSED shows only its header."
  (let* ((total (length messages))
         (size (max 1 (min total (or window maillist-message-window))))
         (shown (last messages size))
         (participants (maillist--unique-participants messages))
         (last-message (car (last messages)))
         (data (or (plist-get last-message :date) (plist-get row :date)))
         (first-new (maillist--first-new-message-id
                     shown (plist-get row :new-since))))
    (list :id (plist-get row :id)
          :subject (or (plist-get row :subject) "")
          :meta (concat (format "%d 封 · %d 人参与 · 最后回复 %s"
                                total participants
                                (maillist-long-label data))
                        (if refreshing " · 正在更新…" ""))
          :starred (and (plist-get row :starred) t)
          :total total
          :hidden (- total size)
          :loading loading
          :refreshing refreshing
          :first-new-id first-new
          :messages
          (cl-loop for message in shown
                   collect (append message
                                   (list :collapsed (and collapsed
                                                         (member (plist-get message :id)
                                                                 collapsed))
                                         :reply-to (maillist--parent-author
                                                    message messages)
                                         :links (maillist-message-links
                                                 (or (plist-get message :text) ""))
                                         :lines (maillist-classify-lines
                                                 (or (plist-get message :text) "")
                                                 (plist-get message :id))))))))

(defun maillist--publish-thread (session row messages &optional loading refreshing)
  "Publish MESSAGES as the open thread of SESSION for ROW.
The message list is tagged with the row it belongs to, so an older list can
never be replayed under another thread's header.  Showing the body is what
marks the thread read."
  (let* ((value (maillist--thread-value
                 row messages loading
                 (gethash (plist-get row :id) (plist-get session :collapsed))
                 (plist-get session :message-window)
                 refreshing))
         (shown (plist-get value :messages))
         (current-focus (etaf-value (plist-get session :focused-message)))
         (focus-valid (and current-focus
                           (cl-find current-focus shown
                                    :key (lambda (m) (plist-get m :id))
                                    :test #'equal)))
         (default-focus (or (plist-get value :first-new-id)
                            (plist-get (car (last shown)) :id))))
    (plist-put session :open-messages messages)
    (plist-put session :open-messages-id (plist-get row :id))
    (etaf-set-value (plist-get session :open) value)
    (unless focus-valid
      (etaf-set-value (plist-get session :focused-message) default-focus))
    (when (and (plist-get session :mark-on-render) messages)
      (maillist--mark-read session (plist-get row :id)))))

(defun maillist-load-earlier (session)
  "Show another window of older messages in SESSION's open thread."
  (when-let* ((open (etaf-value (plist-get session :open)))
              (row (maillist-row session (plist-get open :id)))
              (messages (plist-get session :open-messages))
              ;; A placeholder, a partial render or a stale fallback must not
              ;; rebuild the reader from another thread's list.
              ((equal (plist-get session :open-messages-id)
                      (plist-get open :id)))
              ((consp messages)))
    (plist-put session :message-window
               (+ (or (plist-get session :message-window) 0)
                  maillist-message-window))
    (maillist--publish-thread session row messages)
    (plist-get session :message-window)))

(defun maillist--list-name (session)
  "Return the name of the archive SESSION reads."
  (plist-get (plist-get session :source) :name))

(defun maillist--update-row-from-thread (session id thread)
  "Copy the author, count and participant facts of THREAD onto row ID."
  (let* ((messages (plist-get thread :messages))
         (first (car messages))
         (old (maillist-row session id))
         (existing-author (and old (plist-get old :author)))
         (author (if (and existing-author (not (string-empty-p existing-author)))
                     existing-author
                   (or (and first (plist-get first :author)) "")))
         (count (max (or (and old (plist-get old :count)) 0)
                     (length messages)))
         (fields (list :author author
                       :count count
                       :participants (or (plist-get thread :participants)
                                         (maillist--unique-participants messages)))))
    (maillist--replace-row session id fields nil)
    (etaf-set-value (plist-get session :groups)
                    (maillist--grouped (maillist-rows session)))
    (when-let* ((store (plist-get session :store)))
      (when (maillist--archive-list-p session)
        (condition-case nil
            (maillist-store-save-threads
             store (maillist--list-name session)
             (seq-filter (lambda (row) (equal id (plist-get row :id)))
                         (plist-get session :archive-threads)))
          (error nil))))))

(defun maillist--stamp-at-least-p (have want)
  "Return non-nil when ISO timestamp HAVE is at least as recent as WANT."
  (cond
   ((or (null want) (string-empty-p want)) t)
   ((or (null have) (string-empty-p have)) nil)
   (t (not (string< have want)))))

(defun maillist--thread-fresh-p (session row)
  "Return non-nil when ROW's cached body is within `maillist-thread-freshness'."
  (when (and (> maillist-thread-freshness 0)
             (not (plist-get row :new)))
    (when-let* ((stamp (gethash (plist-get row :id)
                                (plist-get session :thread-fetched-at))))
      (< (- (float-time) stamp) maillist-thread-freshness))))

(defun maillist--cache-up-to-date-p (session row cached)
  "Return non-nil when CACHED messages already satisfy ROW without a network call.
When `maillist-thread-freshness' is 0, always returns nil so callers can force
a refresh.  Otherwise a cached thread whose count and newest message timestamp
cover ROW (and is not flagged `:new') opens in 0 ms across restarts."
  (when (and cached (> maillist-thread-freshness 0)
             (not (plist-get row :new)))
    (or (maillist--thread-fresh-p session row)
        (let* ((expected (max 1 (or (plist-get row :count) 1)))
               (row-date (plist-get row :date))
               (cached-date
                (car (sort (delq nil
                                 (mapcar (lambda (m) (plist-get m :date))
                                         cached))
                           #'string>))))
          (and (>= (length cached) expected)
               (maillist--stamp-at-least-p cached-date row-date))))))

(defun maillist--open-thread (session row)
  "Show ROW of SESSION, from cache when possible and from the archive after."
  (let* ((token (cl-incf (plist-get session :token)))
         (id (plist-get row :id))
         (cached (and (plist-get session :store)
                      (condition-case nil
                          (maillist-store-thread-messages (plist-get session :store) id)
                        (error nil))))
         (valid-cache (and cached
                           (maillist--thread-matches-subject-p
                            cached (plist-get row :subject) id)))
         (fresh (and valid-cache (maillist--cache-up-to-date-p session row cached))))
    (plist-put session :message-window maillist-message-window)
    (etaf-set-value (plist-get session :focused-message) nil)
    (cond
     (fresh
      (plist-put session :user-loading nil)
      (maillist--publish-thread session row cached nil nil))
     (valid-cache
      ;; Show cached messages immediately without a jumping skeleton; refresh
      ;; quietly in the background and keep cached text if the network fails.
      (maillist--publish-thread session row cached nil t)
      (maillist--load-thread session row token cached))
     ;; A huge thread is megabytes over HTTP; show its newest mail from the
     ;; small search feed first when not backed by NNTP.
     ((and (not (maillist-nntp-available-p (plist-get session :source)))
           (integerp (plist-get row :count))
           (>= (plist-get row :count) maillist-fast-open-threshold))
      (etaf-set-value (plist-get session :open)
                      (maillist--thread-placeholder row "正在加载最新一封…"))
      (plist-put session :open-messages nil)
      (plist-put session :open-messages-id nil)
      (maillist--load-newest session row token)
      (maillist--load-thread session row token nil))
     (t
      (etaf-set-value (plist-get session :open)
                      (maillist--thread-placeholder row "正在加载线程…"))
      (plist-put session :open-messages nil)
      (plist-put session :open-messages-id nil)
      (maillist--load-thread session row token nil)))))

(defun maillist--merge-messages (cached fetched)
  "Merge CACHED and FETCHED message lists by `:id' in chronological order."
  (let ((by-id (make-hash-table :test #'equal))
        (merged nil))
    (dolist (m cached)
      (when-let* ((mid (plist-get m :id)))
        (puthash mid m by-id)))
    (dolist (m fetched)
      (when-let* ((mid (plist-get m :id)))
        (puthash mid m by-id)))
    (maphash (lambda (_k v) (push v merged)) by-id)
    (maillist--chronological merged)))

(defun maillist--load-thread-http (session row token &optional on-done)
  "Fetch the body of ROW over HTTP for SESSION generation TOKEN.
When ON-DONE is non-nil, runs silently as a background prefetch and calls
ON-DONE with non-nil on success without touching the open reader."
  (let ((id (plist-get row :id))
        (subject (plist-get row :subject)))
    (unless on-done
      (plist-put session :user-loading t))
    (maillist-fetch-thread
     (plist-get session :source) id
     (lambda (result)
       (unless on-done
         (when (maillist--current-p session token)
           (plist-put session :user-loading nil)))
       (cond
        (on-done
         (if-let* ((_ (maillist--alive-p session))
                   (thread (plist-get result :ok))
                   (messages (plist-get thread :messages))
                   (_ (maillist--thread-matches-subject-p messages subject id)))
             (progn
               (puthash id (float-time) (plist-get session :thread-fetched-at))
               (maillist--cache-thread session id messages)
               (maillist--update-row-from-thread session id thread)
               (funcall on-done t))
           (funcall on-done nil)))
        ((maillist--current-p session token)
         (if-let* ((error (plist-get result :error)))
             (maillist--load-newest-fallback session row token error)
           (let* ((thread (plist-get result :ok))
                  (messages (plist-get thread :messages)))
             (if (and (cl-find id messages
                               :key (lambda (message) (plist-get message :id))
                               :test #'equal)
                      (maillist--thread-matches-subject-p messages subject id))
                 (progn
                   (puthash id (float-time) (plist-get session :thread-fetched-at))
                   (maillist--cache-thread session id messages)
                   (maillist--update-row-from-thread session id thread)
                   (maillist--publish-thread session row messages nil nil)
                   (maillist--apply-view session))
               ;; The archive can merge a thread into an older discussion;
               ;; its document then stops at the entry cap and misses the mail
               ;; the index named.  The subject feed still has them.
               (maillist--load-by-subject session row token)))))))
     subject)))

(defun maillist--load-thread-nntp (session row token cached &optional priority on-done)
  "Fetch missing messages of ROW via NNTP pipelining for SESSION.
CACHED holds messages already in SQLite so only new/missing articles are
transferred.  Falls back to HTTP when NNTP has no overview for ROW or fails."
  (let* ((source (plist-get session :source))
         (store (plist-get session :store))
         (list-name (maillist--list-name session))
         (id (plist-get row :id))
         (mids (and store (ignore-errors
                            (maillist-store--nntp-thread-mids store list-name id)))))
    (if (null mids)
        (if on-done
            (funcall on-done nil)
          (maillist--load-thread-http session row token))
      (let* ((have (make-hash-table :test #'equal))
             (_ (dolist (m cached) (puthash (plist-get m :id) t have)))
             (missing (seq-filter (lambda (m) (not (gethash m have))) mids))
             ;; For very long threads, fetch newest messages first so reading
             ;; starts immediately without downloading hundreds of old replies.
             (cap (max maillist-message-window 30))
             (target (if (> (length missing) cap)
                         (last missing cap)
                       missing)))
        (if (null target)
            (progn
              (puthash id (float-time) (plist-get session :thread-fetched-at))
              (if on-done
                  (funcall on-done t)
                (when (maillist--current-p session token)
                  (plist-put session :user-loading nil)
                  (maillist--publish-thread session row cached nil nil)
                  (maillist--apply-view session))))
          (unless on-done
            (plist-put session :user-loading t))
          (maillist-nntp-fetch-articles
           source target
           (lambda (res)
             (unless on-done
               (when (maillist--current-p session token)
                 (plist-put session :user-loading nil)))
             (cond
              (on-done
               (if-let* ((_ (maillist--alive-p session))
                         (fetched (plist-get res :ok))
                         (merged (maillist--merge-messages cached fetched)))
                   (progn
                     (puthash id (float-time) (plist-get session :thread-fetched-at))
                     (maillist--cache-thread session id merged)
                     (maillist--update-row-from-thread
                      session id
                      (list :messages merged
                            :participants (maillist--unique-participants merged)))
                     (funcall on-done t))
                 (funcall on-done nil)))
              ((maillist--current-p session token)
               (let ((fetched (plist-get res :ok)))
                 (if (and (null (plist-get res :error)) fetched)
                     (let ((merged (maillist--merge-messages cached fetched)))
                       (puthash id (float-time) (plist-get session :thread-fetched-at))
                       (maillist--cache-thread session id merged)
                       (maillist--update-row-from-thread
                        session id
                        (list :messages merged
                              :participants (maillist--unique-participants merged)))
                       (maillist--publish-thread session row merged nil nil)
                       (maillist--apply-view session))
                   ;; Fall back seamlessly to HTTP when NNTP errors or returns nothing.
                   (if (eq maillist-transport 'auto)
                       (maillist--load-thread-http session row token)
                     (maillist--load-newest-fallback
                      session row token (plist-get res :error))))))))
           (or priority 'high)))))))

(defun maillist--load-thread (session row token &optional cached)
  "Fetch the body of ROW for SESSION generation TOKEN."
  (if (maillist-nntp-available-p (plist-get session :source))
      (maillist--load-thread-nntp session row token cached 'high nil)
    (maillist--load-thread-http session row token nil)))

(defun maillist--fetch-raw (session id callback)
  "Fetch raw RFC 5322 text of message ID for SESSION, preferring NNTP."
  (let ((source (plist-get session :source)))
    (if (maillist-nntp-available-p source)
        (maillist-nntp-fetch-raw
         source id
         (lambda (res)
           (if (and (plist-get res :error) (eq maillist-transport 'auto))
               (maillist-fetch-raw source id callback)
             (funcall callback res)))
         'high)
      (maillist-fetch-raw source id callback))))

(defun maillist--cache-thread (session id messages)
  "Cache MESSAGES as thread ID of SESSION, replacing any older copy.
An archive merge or a truncated feed must never keep a body that does not
belong to the row the list shows."
  (when-let* ((store (plist-get session :store)))
    (condition-case err
        (maillist-store-save-thread-messages store id messages)
      (error (message "maillist: 无法缓存线程正文：%s" (error-message-string err))))))

(defun maillist--thread-matches-subject-p (messages subject &optional target-id)
  "Return non-nil when MESSAGES belong to the discussion named SUBJECT.
A public-inbox thread can be merged into a massive unrelated discussion by a
reply with broken References; reject mega-threads where fewer than half the
messages share SUBJECT, while tolerating normal mid-thread subject renames in
smaller threads when TARGET-ID itself matches."
  (let* ((wanted (maillist-thread-subject subject))
         (total (length messages))
         (matching (seq-count
                    (lambda (message)
                      (equal wanted
                             (maillist-thread-subject
                              (plist-get message :subject))))
                    messages))
         (target (and target-id
                      (cl-find target-id messages
                               :key (lambda (m) (plist-get m :id))
                               :test #'equal))))
    (or (zerop total)
        (>= (* matching 2) total)
        (and (<= total 100)
             target
             (equal wanted
                    (maillist-thread-subject (plist-get target :subject)))))))

(defun maillist--chronological (messages)
  "Return MESSAGES oldest first with their reply depth recomputed.
The search feed answers newest first, while the thread view needs the archive's
reading order."
  (let ((sorted (sort (copy-sequence messages)
                      (lambda (first second)
                        (string< (or (plist-get first :date) "")
                                 (or (plist-get second :date) ""))))))
    (maillist--compute-depths sorted)))

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
             (progn
               (puthash (plist-get row :id) (float-time)
                        (plist-get session :thread-fetched-at))
               (maillist--cache-thread session (plist-get row :id) messages)
               (maillist--update-row-from-thread
                session (plist-get row :id)
                (list :messages messages
                      :participants (maillist--unique-participants messages)))
               (maillist--publish-thread session row messages nil nil)
               (etaf-set-value
                (plist-get session :open)
                (plist-put (copy-sequence (etaf-value (plist-get session :open)))
                           :meta
                           (format "%d 封 · 档案把该线程并进了旧讨论，按标题显示"
                                   (length messages))))
               (maillist--apply-view session))
           (maillist--load-newest-fallback session row token)))))))

(defun maillist--load-newest-fallback (session row token &optional reason)
  "Show only the newest mail of ROW when no thread document has it.
If cached messages for ROW are already on screen, keep them intact and only
note the offline/refresh failure instead of wiping the reader."
  (let* ((id (plist-get row :id))
         (current-open (etaf-value (plist-get session :open)))
         (has-cached (and current-open
                          (equal (plist-get current-open :id) id)
                          (consp (plist-get current-open :messages)))))
    (if has-cached
        ;; Never discard a cached body just because a background refresh failed.
        (let* ((meta (replace-regexp-in-string
                      " · 正在更新…\\'" "" (or (plist-get current-open :meta) "")))
               (updated (maillist--plist-merge
                         current-open
                         (list :loading nil
                               :refreshing nil
                               :meta (concat meta " · 离线缓存")))))
          (etaf-set-value (plist-get session :open) updated)
          (when reason
            (maillist--toast session 'info
                             (format "刷新失败（%s），当前显示本地缓存" reason) 6)))
      (maillist-fetch-message
       (plist-get session :source) id
       (lambda (result)
         (when (maillist--current-p session token)
           (if-let* ((messages (plist-get (plist-get result :ok) :messages)))
               (progn
                 (maillist--publish-thread session row messages nil nil)
                 (etaf-set-value
                  (plist-get session :open)
                  (plist-put (copy-sequence (etaf-value (plist-get session :open)))
                             :meta
                             "档案的线程数据不完整，只找到这一封（按 g 重试）")))
             (let ((open (etaf-value (plist-get session :open))))
               (when (and open (equal (plist-get open :id) id)
                          (null (plist-get open :messages)))
                 (etaf-set-value
                  (plist-get session :open)
                  (maillist--plist-merge
                   (maillist--thread-placeholder
                    row (or reason "档案没有返回这个线程的邮件，按 g 重试"))
                   (list :loading nil :error t)))
                 (plist-put session :open-messages nil)
                 (plist-put session :open-messages-id nil))))))))))

(defun maillist--load-newest (session row token)
  "Show the newest mail of ROW for SESSION generation TOKEN while the thread loads."
  (maillist-fetch-message
   (plist-get session :source) (plist-get row :id)
   (lambda (result)
     (when (maillist--current-p session token)
       (when-let* ((messages (plist-get (plist-get result :ok) :messages)))
         (let ((open (etaf-value (plist-get session :open))))
           ;; Only fill the gap: a finished thread is authoritative.
           (when (and (plist-get open :loading)
                      (equal (plist-get open :id) (plist-get row :id)))
             (maillist--publish-thread session row messages t nil)
             (etaf-set-value
              (plist-get session :open)
              (plist-put (copy-sequence (etaf-value (plist-get session :open)))
                         :meta "正在加载完整线程…（先显示最新一封）")))))))))

;;; ---------------------------------------------------------------------------
;;; Sync & batched author prefetch
;;; ---------------------------------------------------------------------------

(defun maillist--store-rows (session &optional rows)
  "Persist SESSION's `:archive-threads' (or ROWS) when it has a store."
  (when-let* ((store (plist-get session :store))
              (target (or rows (plist-get session :archive-threads))))
    (condition-case err
        (maillist-store-save-threads store (maillist--list-name session) target)
      (error (message "maillist: 无法保存线程列表：%s" (error-message-string err))))))

(defun maillist--merge-authors (rows hints)
  "Return ROWS with missing authors filled from HINTS alist (ID . AUTHOR)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (pair hints)
      (when (and (car pair) (cdr pair) (not (string-empty-p (cdr pair))))
        (puthash (car pair) (cdr pair) table)))
    (mapcar
     (lambda (row)
       (let ((author (plist-get row :author))
             (hint (gethash (plist-get row :id) table)))
         (if (or (and author (not (string-empty-p author))) (null hint))
             row
           (maillist--plist-merge row (list :author hint)))))
     rows)))

(defun maillist--apply-author-hints (session hints)
  "Apply HINTS (alist of ID . AUTHOR) to SESSION in one update and one save."
  (when hints
    (let* ((archive (maillist--merge-authors
                     (plist-get session :archive-threads) hints))
           (changed-ids (mapcar #'car hints)))
      (plist-put session :archive-threads archive)
      (if (maillist--archive-list-p session)
          (progn
            (etaf-set-value (plist-get session :threads) archive)
            (etaf-set-value (plist-get session :groups)
                            (maillist--grouped (maillist-rows session))))
        (etaf-set-value (plist-get session :threads)
                        (maillist--merge-authors
                         (etaf-value (plist-get session :threads)) hints))
        (etaf-set-value (plist-get session :groups)
                        (maillist--grouped (maillist-rows session))))
      (maillist--store-rows
       session
       (seq-filter (lambda (row) (member (plist-get row :id) changed-ids))
                   archive)))))

(defun maillist--cache-recent-singles (session messages)
  "Cache bodies of single-message threads received inside `new.atom' MESSAGES."
  (when (and messages (plist-get session :store))
    (let* ((store (plist-get session :store))
           (by-id (make-hash-table :test #'equal))
           (singles nil))
      (dolist (m messages)
        (when-let* ((mid (plist-get m :id)))
          (puthash mid m by-id)))
      (dolist (row (plist-get session :archive-threads))
        (let ((id (plist-get row :id))
              (cnt (plist-get row :count)))
          (when (and (or (null cnt) (= cnt 1))
                     (gethash id by-id))
            (push id singles))))
      (when singles
        (let ((cached (maillist-store--cached-thread-ids store singles)))
          (dolist (id singles)
            (unless (gethash id cached)
              (let ((msg (gethash id by-id)))
                (maillist--cache-thread session id (list msg))
                (puthash id (float-time)
                         (plist-get session :thread-fetched-at))))))))))

(defun maillist--fetch-authors (session token &optional then)
  "Fill missing authors and single-message bodies from `new.atom', then THEN."
  (maillist--fetch-recent-payload
   (plist-get session :source)
   (lambda (result)
     (when (maillist--current-sync-p session token)
       (when-let* ((payload (plist-get result :ok)))
         (when-let* ((hints (plist-get payload :hints)))
           (maillist--apply-author-hints session hints))
         (when-let* ((msgs (plist-get payload :messages)))
           (maillist--cache-recent-singles session msgs)))
       (when then (funcall then))))))

(defun maillist--prefetch-continue (session token rest failures batch-failures size)
  "Continue the sender prefetch of SESSION after one batch."
  (cond
   ((>= batch-failures size)
    (unless (plist-get session :prefetch-retried)
      (plist-put session :prefetch-retried t)
      (run-at-time 30 nil
                   (lambda ()
                     (when (maillist--current-sync-p session token)
                       (maillist--prefetch session token))))))
   (rest
    (run-at-time 0.4 nil
                 (lambda ()
                   (maillist--prefetch-batch
                    session token rest (+ failures batch-failures)))))))

(defun maillist--prefetch-batch (session token queue failures)
  "Fetch QUEUE in polite batches for SESSION generation TOKEN.
Yields automatically while a user-initiated thread load is in flight so
background `/raw' requests never contend with opening a thread."
  (when (and (maillist--current-sync-p session token) queue)
    (if (plist-get session :user-loading)
        (run-at-time 0.8 nil
                     (lambda ()
                       (maillist--prefetch-batch session token queue failures)))
      (let* ((size (max 1 maillist-prefetch-parallel))
             (batch (seq-take queue size))
             (rest (seq-drop queue size))
             (pending (length batch))
             (batch-failures 0)
             (resolved nil))
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
                       (push (cons id name) resolved))))
                 (cl-decf pending)
                 (when (zerop pending)
                   (when resolved
                     (maillist--apply-author-hints session resolved))
                   (maillist--prefetch-continue
                    session token rest failures batch-failures size)))))))))))

(defun maillist--prefetch (session token)
  "Fill the senders of `:archive-threads' that still lack one."
  (when (> maillist-prefetch-threads 0)
    (plist-put session :prefetch-retried nil)
    (maillist--prefetch-batch
     session token
     (seq-take
      (seq-filter (lambda (row)
                    (string-empty-p (or (plist-get row :author) "")))
                  (plist-get session :archive-threads))
      maillist-prefetch-threads)
     0)))

(defun maillist--cancel-body-prefetch (session)
  "Cancel any scheduled background body prefetch timer on SESSION."
  (when-let* ((timer (plist-get session :body-prefetch-timer)))
    (cancel-timer timer)
    (plist-put session :body-prefetch-timer nil)))

(defun maillist--prefetch-bodies-step (session token queue)
  "Quietly pre-cache thread bodies in QUEUE, one at a time, yielding to user."
  (when (and (maillist--current-sync-p session token) queue)
    (if (plist-get session :user-loading)
        (plist-put session :body-prefetch-timer
                   (run-at-time
                    1.0 nil
                    (lambda ()
                      (plist-put session :body-prefetch-timer nil)
                      (maillist--prefetch-bodies-step session token queue))))
      (let* ((row (car queue))
             (rest (cdr queue))
             (use-nntp (maillist-nntp-available-p (plist-get session :source)))
             (delay (if use-nntp 0.25 1.0))
             (next
              (lambda (_ok)
                (when (and (maillist--current-sync-p session token) rest)
                  (plist-put session :body-prefetch-timer
                             (run-at-time
                              delay nil
                              (lambda ()
                                (plist-put session :body-prefetch-timer nil)
                                (maillist--prefetch-bodies-step
                                 session token rest))))))))
        (if use-nntp
            (maillist--load-thread-nntp session row token nil 'low next)
          (maillist--load-thread-http session row token next))))))

(defun maillist--schedule-body-prefetch (session token)
  "Schedule background body prefetching for top uncached threads of SESSION."
  (maillist--cancel-body-prefetch session)
  (when (and (> maillist-prefetch-bodies 0)
             (plist-get session :store)
             (maillist--current-sync-p session token))
    (plist-put session :body-prefetch-timer
               (run-at-time
                0.8 nil
                (lambda ()
                  (plist-put session :body-prefetch-timer nil)
                  (when (maillist--current-sync-p session token)
                    (let* ((store (plist-get session :store))
                           (use-nntp (maillist-nntp-available-p
                                      (plist-get session :source)))
                           (limit (if use-nntp
                                      maillist-prefetch-bodies
                                    (min 4 maillist-prefetch-bodies)))
                           (rows (plist-get session :archive-threads))
                           (unread (seq-filter (lambda (r) (plist-get r :unread)) rows))
                           (ordered (append unread
                                            (seq-filter
                                             (lambda (r) (not (plist-get r :unread)))
                                             rows)))
                           (eligible
                            (if use-nntp
                                ordered
                              (seq-filter
                               (lambda (r)
                                 (let ((c (plist-get r :count)))
                                   (or (null c) (<= c 15))))
                               ordered)))
                           (sample (seq-take eligible (* limit 3)))
                           (cached (maillist-store--cached-thread-ids
                                    store
                                    (mapcar (lambda (r) (plist-get r :id)) sample)))
                           (queue (seq-take
                                   (seq-filter
                                    (lambda (r)
                                      (not (gethash (plist-get r :id) cached)))
                                    sample)
                                   limit)))
                      (when queue
                        (maillist--prefetch-bodies-step session token queue)))))))))

(defun maillist--finish-sync (session token fetched next-cursor quiet used-nntp)
  "Apply FETCHED rows from a completed sync of SESSION generation TOKEN."
  (let* ((had-sync (plist-get session :last-sync))
         (rows (maillist--window-rows fetched session))
         (news (seq-count (lambda (row) (plist-get row :new)) rows)))
    (plist-put session :archive-threads rows)
    (when next-cursor
      (plist-put session :next-cursor next-cursor))
    (plist-put session :last-sync (current-time))
    (maillist--store-rows session rows)
    (maillist--prune session)
    (when (maillist--archive-list-p session)
      (etaf-set-value (plist-get session :threads) rows)
      (maillist--apply-view session t))
    (maillist--status session 'idle "")
    (cond
     ((and quiet (> news 0))
      (maillist--toast session 'info (format "%d 个新动态" news) 6))
     ((and (not quiet) had-sync)
      (maillist--toast session 'info
                       (if (> news 0)
                           (format "同步完成 · %d 个新动态" news)
                         "同步完成 · 已是最新")
                       3)))
    (if used-nntp
        ;; NNTP XOVER already carries every sender; go straight to body warmup.
        (maillist--schedule-body-prefetch session token)
      ;; Wait for `new.atom' before prefetching `/raw' so newest threads are
      ;; not fetched twice, then warm top uncached bodies gently.
      (maillist--fetch-authors
       session token
       (lambda ()
         (maillist--prefetch session token)
         (maillist--schedule-body-prefetch session token))))))

(defun maillist--refresh-http (session token quiet)
  "Sync SESSION generation TOKEN from its HTTP public-inbox index page."
  (maillist--fetch-index-page
   (plist-get session :source)
   (lambda (result)
     (when (maillist--current-sync-p session token)
       (if-let* ((error (plist-get result :error)))
           (maillist--status session 'error
                             (format "同步失败：%s · 按 g 重试" error))
         (let ((payload (plist-get result :ok)))
           (maillist--finish-sync
            session token
            (plist-get payload :rows)
            (plist-get payload :next)
            quiet nil)))))))

(defun maillist--merge-nntp-articles (existing fresh)
  "Return combined NNTP article list deduplicated by `:artnum'."
  (let ((by-num (make-hash-table :test #'eql))
        (out nil))
    (dolist (a existing)
      (puthash (plist-get a :artnum) a by-num))
    (dolist (a fresh)
      (puthash (plist-get a :artnum) a by-num))
    (maphash (lambda (_k v) (push v out)) by-num)
    out))

(defun maillist--refresh-nntp (session token quiet)
  "Sync SESSION generation TOKEN incrementally via NNTP, falling back to HTTP."
  (let* ((source (plist-get session :source))
         (store (plist-get session :store))
         (list-name (maillist--list-name session))
         (range (and store (ignore-errors (maillist-store--nntp-range store list-name))))
         (stored-high (cdr range)))
    (maillist-nntp-fetch-overview
     source
     (lambda (result)
       (when (maillist--current-sync-p session token)
         (if-let* ((err (plist-get result :error)))
             (if (eq maillist-transport 'auto)
                 (maillist--refresh-http session token quiet)
               (maillist--status session 'error
                                 (format "同步失败：%s · 按 g 重试" err)))
           (let* ((payload (plist-get result :ok))
                  (fresh (plist-get payload :articles))
                  (existing (and store
                                 (ignore-errors
                                   (maillist-store--nntp-articles store list-name))))
                  (combined (maillist--merge-nntp-articles existing fresh))
                  (rows (and combined (maillist-nntp-group-articles combined))))
             ;; Persist newly fetched articles (now normalized with canonical :root-id).
             (when (and store fresh)
               (ignore-errors
                 (maillist-store--save-nntp-articles store list-name combined)))
             (if rows
                 (maillist--finish-sync session token rows nil quiet t)
               ;; Empty NNTP group or overview: fall back to HTTP if allowed.
               (if (and (null (plist-get session :archive-threads))
                        (eq maillist-transport 'auto))
                   (maillist--refresh-http session token quiet)
                 (plist-put session :last-sync (current-time))
                 (maillist--status session 'idle "")
                 (maillist--schedule-body-prefetch session token)))))))
     stored-high nil 'high)))

(defun maillist-refresh (session &optional quiet)
  "Reload SESSION's thread list from its archive.
QUIET keeps a background sync out of the notice area; a failure still
reports, because a client that hides its errors cannot be trusted with mail.
If a search is currently active, the fetched archive rows update
`:archive-threads' and SQLite without overwriting the visible search view.
Uses persistent incremental NNTP when the source declares `:nntp', falling back
transparently to HTTP."
  (when (maillist--alive-p session)
    (let ((token (cl-incf (plist-get session :sync-token)))
          (source (plist-get session :source)))
      (maillist--cancel-body-prefetch session)
      (unless quiet
        (maillist-nntp-clear-cooldown source)
        (maillist--status session 'loading "正在同步邮件列表…"))
      (if (maillist-nntp-available-p source)
          (maillist--refresh-nntp session token quiet)
        (maillist--refresh-http session token quiet)))))

(defun maillist--prune (session)
  "Drop what SESSION's store no longer needs after a sync."
  (when-let* ((store (plist-get session :store)))
    (condition-case err
        (maillist-store-prune store (maillist--list-name session))
      (error (message "maillist: 无法清理缓存：%s" (error-message-string err))))))

(defun maillist-set-scope (session scope)
  "Show only SCOPE (`all', `unread' or `starred') rows of SESSION."
  (plist-put session :sticky-row nil)
  (etaf-set-value (plist-get session :scope) scope)
  (maillist--apply-view session))

;;; ---------------------------------------------------------------------------
;;; Search
;;; ---------------------------------------------------------------------------

(defun maillist--restore-archive-list (session)
  "Restore SESSION's visible list from `:archive-threads' without a network call."
  (let ((archive (plist-get session :archive-threads)))
    (plist-put session :sticky-row nil)
    (etaf-set-value (plist-get session :query) "")
    (etaf-set-value (plist-get session :search-input) "")
    (etaf-set-value (plist-get session :filters) nil)
    (if archive
        (progn
          (etaf-set-value (plist-get session :threads) archive)
          (maillist--apply-view session)
          (maillist--status session 'idle ""))
      (plist-put session :last-sync nil)
      (maillist-refresh session))))

(defun maillist-search (session text)
  "Search SESSION's archive for TEXT.
An empty TEXT returns immediately to `:archive-threads'.  TEXT may name
fields (`from:', `to:', `subject:', `body:', `message:', optionally negated
with `-'), a date range (`after:', `before:') and local marks (`is:unread',
`is:read', `is:starred' and `-is:...').  A query naming only local marks
filters `:archive-threads' without a request.  When the archive cannot answer,
cached threads and bodies answer locally using the structured query terms."
  (let* ((query (string-trim (or text "")))
         (compiled (maillist-compile-query query))
         (remote (plist-get compiled :query))
         (filters (plist-get compiled :filters))
         (terms (plist-get compiled :terms)))
    (plist-put session :sticky-row nil)
    (etaf-set-value (plist-get session :search-input) query)
    (etaf-set-value (plist-get session :query) query)
    (maillist--remember-query session query)
    (etaf-set-value (plist-get session :filters) filters)
    (etaf-set-value (plist-get session :scope) 'all)
    (cond
     ((string-empty-p query)
      (maillist--restore-archive-list session))
     ((string-empty-p remote)
      ;; Only local filters: always filter the authoritative archive list.
      (etaf-set-value (plist-get session :threads)
                      (plist-get session :archive-threads))
      (maillist--clear-open session)
      (maillist--apply-view session)
      (maillist--status session 'idle "")
      (when (null (maillist-rows session))
        (maillist--toast session 'info "当前列表没有符合条件的线程" 5)))
     (t
      (let ((token (cl-incf (plist-get session :sync-token))))
        (maillist--status session 'loading (format "正在搜索「%s」…" query))
        (maillist-fetch-search
         (plist-get session :source) remote
         (lambda (result)
           (when (maillist--current-sync-p session token)
             (if-let* ((error (plist-get result :error)))
                 (let ((local (maillist--local-search session terms remote)))
                   (if local
                       (progn
                         (maillist--clear-open session)
                         (maillist--apply-view session)
                         (maillist--status session 'idle "")
                         (maillist--toast
                          session 'info
                          (format "档案不可用，显示 %d 条本地缓存结果" local)
                          8))
                     (maillist--status session 'error
                                       (format "搜索失败：%s · 按 g 重试" error))))
               (let ((rows (maillist--merge-rows
                            (plist-get result :ok) session
                            (plist-get session :archive-threads))))
                 ;; The reader starts empty for a new result set; a failed
                 ;; request leaves the thread the reader already had.
                 (maillist--clear-open session)
                 (etaf-set-value (plist-get session :threads) rows)
                 (maillist--apply-view session)
                 (maillist--status session 'idle "")
                 (when (null (maillist-rows session))
                   (maillist--toast session 'info
                                    "没有匹配的线程，清空搜索框回到列表" 5))))))))))))

(defun maillist--local-search (session terms raw-text)
  "Show cached threads of SESSION matching structured TERMS (or RAW-TEXT).
Return how many rows the list now holds, or nil when nothing matched.  Rows
are resolved from `:archive-threads' so consecutive offline searches always
cover the entire cached list."
  (let* ((store (plist-get session :store))
         (list-name (maillist--list-name session))
         (hits (and store
                    (if terms
                        (maillist-store--search-local
                         store list-name terms maillist-local-search-limit)
                      (maillist-store-search-bodies
                       store raw-text maillist-local-search-limit list-name))))
         (snippets (make-hash-table :test #'equal))
         (matched (make-hash-table :test #'equal))
         (rows nil))
    (dolist (hit hits)
      (puthash (car hit) t matched)
      (when (and (cdr hit) (not (gethash (car hit) snippets)))
        (puthash (car hit) (cdr hit) snippets)))
    (dolist (row (plist-get session :archive-threads))
      (let ((id (plist-get row :id)))
        (when (gethash id matched)
          (let ((snippet (gethash id snippets)))
            (push (if (and snippet (not (string-empty-p snippet)))
                      (maillist--plist-merge row (list :snippet snippet))
                    row)
                  rows)))))
    (when rows
      (etaf-set-value (plist-get session :threads) (maillist--by-date rows))
      (length rows))))

;;; ---------------------------------------------------------------------------
;;; Older mail pagination
;;; ---------------------------------------------------------------------------

(defun maillist--oldest-date (rows)
  "Return the oldest `:date' of ROWS, or nil."
  (let (dates)
    (dolist (row rows)
      (when-let* ((date (plist-get row :date)))
        (push date dates)))
    (car (sort dates #'string<))))

(defun maillist--older-rows (session older)
  "Return the rows of OLDER that extend SESSION's `:archive-threads', newest first.
A search answers per message, so rows are grouped one per subject (newest of
each), deduplicated against known ids and subjects, and filtered strictly
before the oldest timestamp held so same-day earlier mail is not skipped."
  (let* ((rows (plist-get session :archive-threads))
         (oldest (maillist--oldest-date rows))
         (known (make-hash-table :test #'equal))
         (subjects (make-hash-table :test #'equal))
         kept)
    (dolist (row rows)
      (puthash (plist-get row :id) t known)
      (puthash (downcase (maillist-thread-subject (or (plist-get row :subject) "")))
               t subjects))
    (dolist (row (sort (copy-sequence older)
                       (lambda (a b)
                         (string> (or (plist-get a :date) "")
                                  (or (plist-get b :date) "")))))
      (let ((subject (downcase (maillist-thread-subject
                                (or (plist-get row :subject) ""))))
            (date (plist-get row :date)))
        (when (and date
                   (not (gethash (plist-get row :id) known))
                   (not (gethash subject subjects))
                   (or (null oldest) (string< date oldest)))
          (puthash (plist-get row :id) t known)
          (puthash subject t subjects)
          (push (maillist--plist-merge row (list :unread t :new nil)) kept))))
    (seq-take (nreverse kept) maillist-older-batch)))

(defun maillist--apply-older-rows (session added)
  "Append ADDED older rows into SESSION's archive list, persist and notify."
  (let* ((count (length added))
         (combined (maillist--by-date
                    (append added (plist-get session :archive-threads)))))
    (plist-put session :archive-threads combined)
    (when (maillist--archive-list-p session)
      (etaf-set-value (plist-get session :threads) combined))
    (maillist--store-rows session combined)
    (maillist--apply-view session)
    (maillist--status session 'idle "")
    (maillist--toast session 'info
                     (if (> count 0)
                         (format "已取回 %d 封更早的邮件" count)
                       "没有更多更早的邮件了")
                     6)))

(defun maillist--load-older-via-search (session token query offset attempts)
  "Fetch older mail for SESSION generation TOKEN via search QUERY at OFFSET.
If a full page contains only already-seen messages from the cutoff day, step
OFFSET forward (up to ATTEMPTS) so busy 200+ msg/day dates never deadlock."
  (maillist-fetch-search
   (plist-get session :source) query
   (lambda (result)
     (when (maillist--current-sync-p session token)
       (if-let* ((error (plist-get result :error)))
           (maillist--status session 'error
                             (format "取更早的邮件失败：%s · 按 o 重试" error))
         (let* ((raw (plist-get result :ok))
                (rows (maillist--older-rows session raw)))
           (if (and (null rows) (>= (length raw) 100) (> attempts 0))
               (maillist--load-older-via-search
                session token query (+ offset (length raw)) (1- attempts))
             (maillist--apply-older-rows session rows))))))
   offset))

(defun maillist--load-older-http (session token)
  "Fetch older mail for SESSION generation TOKEN via HTTP cursor or date search."
  (let ((cursor (plist-get session :next-cursor)))
    (if cursor
        (maillist--fetch-index-page
         (plist-get session :source)
         (lambda (result)
           (when (maillist--current-sync-p session token)
             (if-let* ((error (plist-get result :error)))
                 (maillist--status session 'error
                                   (format "取更早的邮件失败：%s · 按 o 重试" error))
               (let* ((payload (plist-get result :ok))
                      (fetched (plist-get payload :rows))
                      (next (plist-get payload :next))
                      (known (maillist--known-table
                              (plist-get session :archive-threads)))
                      (fresh (seq-filter
                              (lambda (r) (not (gethash (plist-get r :id) known)))
                              (maillist--merge-rows
                               fetched session
                               (plist-get session :archive-threads))))
                      (added (mapcar (lambda (r)
                                       (maillist--plist-merge r (list :new nil)))
                                     fresh)))
                 (plist-put session :next-cursor
                            (and next (not (equal next cursor)) next))
                 (maillist--apply-older-rows session added)
                 (maillist--prefetch session token)))))
         cursor)
      (let* ((oldest (maillist--oldest-date (plist-get session :archive-threads)))
             (query (if oldest (format "d:..%s" (substring oldest 0 10)) "d:..")))
        (maillist--load-older-via-search session token query 0 3)))))

(defun maillist--load-older-nntp (session token stored-low)
  "Fetch older articles below STORED-LOW for SESSION generation TOKEN via NNTP."
  (let* ((source (plist-get session :source))
         (store (plist-get session :store))
         (list-name (maillist--list-name session))
         (end-art (1- stored-low))
         (start-art (max 1 (- stored-low maillist-nntp-older-batch))))
    (if (< end-art 1)
        (progn
          (maillist--status session 'idle "")
          (maillist--toast session 'info "没有更多更早的邮件了" 6))
      (maillist-nntp-fetch-overview
       source
       (lambda (result)
         (when (maillist--current-sync-p session token)
           (if-let* ((err (plist-get result :error)))
               (if (eq maillist-transport 'auto)
                   (maillist--load-older-http session token)
                 (maillist--status session 'error
                                   (format "取更早的邮件失败：%s · 按 o 重试" err)))
             (let* ((payload (plist-get result :ok))
                    (fresh (plist-get payload :articles))
                    (existing (and store
                                   (ignore-errors
                                     (maillist-store--nntp-articles store list-name))))
                    (combined (maillist--merge-nntp-articles existing fresh))
                    (grouped (and combined (maillist-nntp-group-articles combined)))
                    (known (maillist--known-table
                            (plist-get session :archive-threads)))
                    (added (mapcar (lambda (r)
                                     (maillist--plist-merge r (list :unread t :new nil)))
                                   (seq-filter
                                    (lambda (r) (not (gethash (plist-get r :id) known)))
                                    grouped))))
               (when (and store fresh)
                 (ignore-errors
                   (maillist-store--save-nntp-articles store list-name combined)))
               (maillist--apply-older-rows session added)))))
       start-art end-art 'high))))

(defun maillist-load-older (session)
  "Add mail older than SESSION's list.
Uses NNTP `XOVER' paging when the source is backed by NNTP; otherwise pages
the archive's native `?t=...' index cursor or falls back to date search with
timestamp comparison and automatic offset stepping."
  (when (maillist--alive-p session)
    (if (not (maillist--archive-list-p session))
        (maillist--toast session 'info "搜索视图下无法加载更早档案，请先清空搜索框" 5)
      (let* ((token (cl-incf (plist-get session :sync-token)))
             (source (plist-get session :source))
             (store (plist-get session :store))
             (range (and store (maillist-nntp-available-p source)
                         (ignore-errors
                           (maillist-store--nntp-range
                            store (maillist--list-name session))))))
        (maillist--status session 'loading "正在取更早的邮件…")
        (if (and range (car range))
            (maillist--load-older-nntp session token (car range))
          (maillist--load-older-http session token))))))

;;; ---------------------------------------------------------------------------
;;; Lifecycle
;;; ---------------------------------------------------------------------------

(defun maillist-dispose (session)
  "Release SESSION's store, cancel timers and ignore late archive answers."
  (when (plist-get session :alive)
    (plist-put session :alive nil)
    (setq maillist--live-sessions (max 0 (1- maillist--live-sessions)))
    (when (zerop maillist--live-sessions)
      (maillist-nntp-close-all)))
  (dolist (key '(:toast-timer :refresh-timer :search-timer :body-prefetch-timer))
    (when-let* ((timer (plist-get session key)))
      (cancel-timer timer)
      (plist-put session key nil)))
  (when-let* ((store (plist-get session :store)))
    (condition-case nil (maillist-store-close store) (error nil))))

;;; ---------------------------------------------------------------------------
;;; Creation
;;; ---------------------------------------------------------------------------

(cl-defun maillist-create (&key list)
  "Create a client session over the archive LIST.
LIST defaults to the one this client opened last, then to
`maillist-default-list'; rows come from the local cache first and from the
archive after `maillist-refresh'.  The return value is the session plist
whose refs the Views read."
  (let* ((store (maillist-store-open))
         (_ (maillist--merge-custom-sources store))
         (name (or list (maillist--remembered-list store) maillist-default-list))
         (source (or (ignore-errors (maillist-source name))
                     (ignore-errors (maillist-source maillist-default-list))
                     (car maillist-sources)))
         (marks (and store
                     (condition-case nil
                         (maillist-store-marks store)
                       (error nil))))
         (cached (or (and store
                          (condition-case nil
                              (progn
                                (maillist-store-adopt-threads
                                 store (plist-get source :name))
                                (maillist-store-threads store (plist-get source :name)))
                            (error nil)))
                     '()))
         (rows (maillist--by-date
                (mapcar (lambda (record)
                          (maillist--row-from-record
                           record (cdr (assoc (plist-get record :id) marks))))
                        cached)))
         (saved-width (when store
                        (when-let* ((raw (ignore-errors
                                           (maillist-store-setting "list-width" store))))
                          (let ((n (string-to-number raw)))
                            (and (> n 0) n)))))
         (session (list :source source
                        :store store
                        :alive t
                        :token 0
                        :sync-token 0
                        :last-sync nil
                        :next-cursor nil
                        :refresh-timer nil
                        :search-timer nil
                        :toast-timer nil
                        :body-prefetch-timer nil
                        :user-loading nil
                        :query-history nil
                        :mark-on-render nil
                        :sticky-row nil
                        :archive-threads rows
                        :thread-fetched-at (make-hash-table :test #'equal)
                        :threads (maillist--ref rows 'maillist-threads)
                        :groups (maillist--ref (maillist--grouped rows) 'maillist-groups)
                        :open (maillist--ref nil 'maillist-open)
                        :selected (maillist--ref nil 'maillist-selected)
                        :focused-message (maillist--ref nil 'maillist-focused-message)
                        :hide-quotes (maillist--ref nil 'maillist-hide-quotes)
                        :scope (maillist--ref 'all 'maillist-scope)
                        :query (maillist--ref "" 'maillist-query)
                        :search-input (maillist--ref "" 'maillist-search-input)
                        :filters (maillist--ref nil 'maillist-filters)
                        :summary (maillist--ref "" 'maillist-summary)
                        :status (maillist--ref (list :kind 'idle :text "") 'maillist-status)
                        :toast (maillist--ref nil 'maillist-toast)
                        :reading (maillist--ref nil 'maillist-reading)
                        :collapsed (make-hash-table :test #'equal)
                        :message-window maillist-message-window
                        :open-messages nil
                        :open-messages-id nil
                        :viewport (maillist--ref 160 'maillist-viewport)
                        :viewport-px (maillist--ref 0 'maillist-viewport-px)
                        :viewport-rows (maillist--ref 24 'maillist-rows)
                        :list-width (maillist--ref (or saved-width 0) 'maillist-list-width))))
    (cl-incf maillist--live-sessions)
    (when store
      (ignore-errors (maillist-store-save-setting "last-list" (plist-get source :name) store))
      (maillist--prune session))
    (etaf-set-value (plist-get session :summary) (maillist--summary session))
    (when-let* ((backup (and store (maillist-store-rebuilt store))))
      (maillist--toast session 'info
                       (format "缓存无法读取，列表已重建（旧文件 %s）"
                               (file-name-nondirectory backup))
                       12))
    session))

(provide 'maillist-model)
;;; maillist-model.el ends here
