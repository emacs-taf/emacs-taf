;;; maillist-store.el --- SQLite persistence of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The client keeps four tables in one SQLite file.  `threads' is the archive
;; cache: subject, date, size and author, keyed by (list_name, id) so
;; cross-posted discussions never overwrite each other across lists.
;; `messages' holds cached bodies keyed by (thread, id) so parent and buried
;; sub-threads never clobber shared messages.  `marks' holds what only the
;; reader decides: read, starred and the last-read snapshot (`read_date',
;; `read_count') used to detect new replies on previously read threads.
;; `settings' stores user preferences such as the last archive, custom sources
;; and splitter width.
;;
;; Schema upgrades from earlier compatible layouts run in place inside a
;; transaction so marks and settings survive; broken or unreadable files are
;; moved aside to a timestamped backup and rebuilt cleanly.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-db)

(defgroup maillist nil
  "Mailing-list archive client."
  :group 'applications)

(defcustom maillist-store-file
  (locate-user-emacs-file "maillist/store.sqlite3")
  "SQLite file holding the client's threads and cached bodies."
  :type 'file
  :group 'maillist)

(defcustom maillist-thread-limit 2000
  "How many threads of one list the client keeps.
The thread list merges every sync into the stored rows, so without a limit it
would grow with every page the archive ever showed.  A prune keeps the newest
rows, every starred thread and all marks; the archive can serve an older
thread again."
  :type 'integer
  :group 'maillist)

(defcustom maillist-body-limit 400
  "How many threads per list keep a cached body.
Bodies are the bulk of the file.  The newest bodies of each list and every
starred thread's body stay, so a restart still shows active and saved
conversations without downloading them again."
  :type 'integer
  :group 'maillist)

(defconst maillist--key-sep "\x1f"
  "ASCII Unit Separator joining composite keys in `threads' and `messages'.")

(defconst maillist--settings-table
  "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)"
  "Settings table created beside the typed tables.")

(defconst maillist--nntp-table
  "CREATE TABLE IF NOT EXISTS nntp_articles (
     list_name TEXT NOT NULL,
     artnum INTEGER NOT NULL,
     id TEXT NOT NULL,
     root_id TEXT NOT NULL,
     parent_id TEXT,
     subject TEXT,
     author TEXT,
     email TEXT,
     date TEXT,
     refs TEXT,
     PRIMARY KEY (list_name, artnum))"
  "NNTP overview table tracking article numbers and thread membership.")

(defun maillist--sqlite-available-p ()
  "Return non-nil when this Emacs can open SQLite databases."
  (and (fboundp 'sqlite-available-p) (sqlite-available-p)))

(defun maillist--row-key (prefix id)
  "Return composite primary key joining PREFIX and ID."
  (concat (or prefix "") maillist--key-sep (or id "")))

(defmacro maillist--with-connection (&rest body)
  "Run BODY with a connection to `maillist-store-file' bound as `connection'.
The connection waits for a writer instead of failing at once, so two Emacs
instances can prune or search while the other one saves a list."
  (declare (indent 0) (debug t))
  `(when (maillist--sqlite-available-p)
     (let ((connection (sqlite-open maillist-store-file)))
       (unwind-protect
           (progn
             (sqlite-execute connection "PRAGMA busy_timeout = 5000")
             ,@body)
         (sqlite-close connection)))))

(cl-defstruct (maillist-store (:constructor maillist--store-create))
  "Open storage of the client: three databases and two controllers.
FILE is the SQLite file the store belongs to, so short connections opened
for marks, queries, search or pruning read that file rather than the default.
REBUILT is nil, or the path of the unreadable file set aside on open."
  file thread-database message-database mark-database
  thread-controller message-controller rebuilt)

(defun maillist--store-file (store)
  "Return the SQLite file STORE reads and writes.
A store carries its file because `maillist-store-file' is a dynamic variable:
a caller holding a store opened over another file must still query that file."
  (or (and store (maillist-store-file store)) maillist-store-file))

(defun maillist--thread-database ()
  "Return the database descriptor of the thread table."
  (etaf-sqlite-database
   maillist-store-file
   (etaf-sqlite-table
    'threads
    (list (etaf-sqlite-column :row-key "row_key" :type 'text :primary t)
          (etaf-sqlite-column :id "id" :type 'text :nullable t)
          (etaf-sqlite-column :subject "subject" :type 'text :nullable t)
          (etaf-sqlite-column :date "date" :type 'text :nullable t)
          (etaf-sqlite-column :count "thread_count" :type 'integer :nullable t)
          (etaf-sqlite-column :author "author" :type 'text :nullable t)
          (etaf-sqlite-column :depth "depth" :type 'integer :nullable t)
          (etaf-sqlite-column :list "list_name" :type 'text :nullable t)
          (etaf-sqlite-column :participants "participants" :type 'integer :nullable t))
    :row-key)))

(defun maillist--mark-database ()
  "Return the database descriptor of the mark table.
A mark is the reader's own state, so it survives every refresh of the archive
cache and is written only when the reader changes it."
  (etaf-sqlite-database
   maillist-store-file
   (etaf-sqlite-table
    'marks
    (list (etaf-sqlite-column :id "id" :type 'text :primary t)
          (etaf-sqlite-column :read "read" :type 'integer :nullable t)
          (etaf-sqlite-column :starred "starred" :type 'integer :nullable t)
          (etaf-sqlite-column :read-date "read_date" :type 'text :nullable t)
          (etaf-sqlite-column :read-count "read_count" :type 'integer :nullable t))
    :id)))

(defun maillist--message-database ()
  "Return the database descriptor of the message table."
  (etaf-sqlite-database
   maillist-store-file
   (etaf-sqlite-table
    'messages
    (list (etaf-sqlite-column :row-key "row_key" :type 'text :primary t)
          (etaf-sqlite-column :id "id" :type 'text :nullable t)
          (etaf-sqlite-column :thread "thread" :type 'text :nullable t)
          (etaf-sqlite-column :author "author" :type 'text :nullable t)
          (etaf-sqlite-column :email "email" :type 'text :nullable t)
          (etaf-sqlite-column :date "date" :type 'text :nullable t)
          (etaf-sqlite-column :parent "parent" :type 'text :nullable t)
          (etaf-sqlite-column :depth "depth" :type 'integer :nullable t)
          (etaf-sqlite-column :position "position" :type 'integer :nullable t)
          (etaf-sqlite-column :text "body" :type 'text :nullable t)
          (etaf-sqlite-column :subject "subject" :type 'text :nullable t))
    :row-key)))

(defun maillist--controller (database name)
  "Return a Data Controller over DATABASE named NAME."
  (etaf-data-controller (etaf-sqlite-source database)
                        :page-size 2000
                        :auto-load nil
                        :name name))

(defun maillist--table-columns (connection table)
  "Return the list of column names in TABLE on CONNECTION, or nil if absent."
  (mapcar (lambda (row) (nth 1 row))
          (sqlite-select connection (format "PRAGMA table_info(%s)" table))))

(defun maillist--migrate-v3-tables (connection)
  "Upgrade valid v0.3.0 `threads' and `messages' tables in place on CONNECTION.
Only well-formed legacy tables are migrated; broken or incompatible schemas
are left untouched so `etaf-sqlite-initialize' triggers a clean backup and
rebuild."
  (let ((tcols (maillist--table-columns connection "threads"))
        (mcols (maillist--table-columns connection "messages")))
    (when (and tcols
               (not (member "row_key" tcols))
               (member "id" tcols)
               (member "list_name" tcols)
               (member "subject" tcols))
      (sqlite-execute connection "BEGIN IMMEDIATE")
      (condition-case err
          (progn
            (sqlite-execute
             connection
             "CREATE TABLE threads_v4 (
                row_key TEXT PRIMARY KEY,
                id TEXT,
                subject TEXT,
                date TEXT,
                thread_count INTEGER,
                author TEXT,
                depth INTEGER,
                list_name TEXT,
                participants INTEGER)")
            (sqlite-execute
             connection
             "INSERT OR REPLACE INTO threads_v4
                (row_key, id, subject, date, thread_count, author, depth, list_name, participants)
              SELECT coalesce(list_name, '') || char(31) || id,
                     id, subject, date, thread_count, author, depth, list_name, participants
                FROM threads")
            (sqlite-execute connection "DROP TABLE threads")
            (sqlite-execute connection "ALTER TABLE threads_v4 RENAME TO threads")
            (sqlite-execute connection "COMMIT"))
        (error (ignore-errors (sqlite-execute connection "ROLLBACK"))
               (signal (car err) (cdr err)))))
    (when (and mcols
               (not (member "row_key" mcols))
               (member "id" mcols)
               (member "thread" mcols)
               (member "body" mcols))
      (sqlite-execute connection "BEGIN IMMEDIATE")
      (condition-case err
          (progn
            (sqlite-execute
             connection
             "CREATE TABLE messages_v4 (
                row_key TEXT PRIMARY KEY,
                id TEXT,
                thread TEXT,
                author TEXT,
                email TEXT,
                date TEXT,
                parent TEXT,
                depth INTEGER,
                position INTEGER,
                body TEXT,
                subject TEXT)")
            (sqlite-execute
             connection
             "INSERT OR REPLACE INTO messages_v4
                (row_key, id, thread, author, email, date, parent, depth, position, body, subject)
              SELECT coalesce(thread, '') || char(31) || id,
                     id, thread, author, email, date, NULL, depth, position, body, subject
                FROM messages")
            (sqlite-execute connection "DROP TABLE messages")
            (sqlite-execute connection "ALTER TABLE messages_v4 RENAME TO messages")
            (sqlite-execute connection "COMMIT"))
        (error (ignore-errors (sqlite-execute connection "ROLLBACK"))
               (signal (car err) (cdr err)))))))

(defun maillist--ensure-indexes ()
  "Create indexes on `threads' and `messages' for fast per-list and thread reads."
  (maillist--with-connection
    (sqlite-execute
     connection
     "CREATE INDEX IF NOT EXISTS idx_threads_list_date
        ON threads (list_name, date DESC, depth ASC)")
    (sqlite-execute
     connection
     "CREATE INDEX IF NOT EXISTS idx_threads_id ON threads (id)")
    (sqlite-execute
     connection
     "CREATE INDEX IF NOT EXISTS idx_messages_thread_pos
        ON messages (thread, position ASC)")
    (sqlite-execute
     connection
     "CREATE INDEX IF NOT EXISTS idx_messages_date ON messages (date DESC)")
    (sqlite-execute
     connection
     "CREATE INDEX IF NOT EXISTS idx_nntp_list_root
        ON nntp_articles (list_name, root_id)")
    (sqlite-execute
     connection
     "CREATE INDEX IF NOT EXISTS idx_nntp_list_id
        ON nntp_articles (list_name, id)")
    (sqlite-execute
     connection
     "CREATE INDEX IF NOT EXISTS idx_nntp_list_date
        ON nntp_articles (list_name, date DESC)")))

(defun maillist--open-tables (rebuilt)
  "Open and initialize the client's tables, marking the store REBUILT or not."
  (let* ((threads (maillist--thread-database))
         (messages (maillist--message-database))
         (marks (maillist--mark-database)))
    (etaf-sqlite-initialize threads)
    (etaf-sqlite-initialize messages)
    (etaf-sqlite-initialize marks)
    (maillist--ensure-indexes)
    (maillist--store-create
     :file maillist-store-file
     :thread-database threads
     :message-database messages
     :mark-database marks
     :thread-controller (maillist--controller threads 'maillist-threads)
     :message-controller (maillist--controller messages 'maillist-messages)
     :rebuilt rebuilt)))

(defun maillist--retire-cache ()
  "Move the unreadable cache aside and return the file it went to.
The old file is kept rather than deleted: rebuilding refetches the archive,
but the marks in it cannot be refetched."
  (let ((backup (format "%s.rebuild-%s"
                        maillist-store-file
                        (format-time-string "%Y%m%d-%H%M%S"))))
    (dolist (file (list maillist-store-file
                        (concat maillist-store-file "-wal")
                        (concat maillist-store-file "-shm")))
      (when (file-exists-p file)
        (rename-file file (concat backup (substring file (length maillist-store-file)))
                     t)))
    backup))

(defun maillist--unreadable-file-p (error)
  "Return non-nil when ERROR says the store file cannot be read as a database.
A file left half written by a crash, or truncated by a full disk, opens but
fails its first statement; the archive cache in it is lost either way, so the
file is rebuilt instead of leaving the client without persistence."
  (let ((text (error-message-string error)))
    (string-match-p "not a database\\|malformed\\|corrupt\\|disk image" text)))

(defun maillist-store-open ()
  "Open the client's storage and return it, or nil when SQLite is missing.
The file is created together with its tables on first use.  A file written by
an incompatible earlier version, or one a crash left unreadable, is moved
aside and rebuilt: the archive cache and cached bodies can be fetched again,
so a reader keeps working instead of losing persistence silently.  The store
reports the backup file, because a rebuild drops the marks stored in the old
one."
  (condition-case error
      (progn
        (when-let* ((directory (file-name-directory maillist-store-file)))
          (make-directory directory t))
        (maillist--prepare-file)
        (maillist--open-tables nil))
    (etaf-sqlite-schema-error (maillist--reopen))
    (error (when (maillist--unreadable-file-p error)
             (maillist--reopen)))))

(defun maillist--reopen ()
  "Move the store aside and open an empty one.
The rebuilt store names the backup file, which still holds the marks, so the
client can tell the reader what happened."
  (let ((backup (maillist--retire-cache)))
    (condition-case nil
        (progn (maillist--prepare-file)
               (maillist--open-tables backup))
      (error nil))))

(defun maillist--prepare-file ()
  "Set the store file up for concurrent use and migrate compatible legacy tables."
  (maillist--with-connection
    (sqlite-execute connection "PRAGMA auto_vacuum = INCREMENTAL")
    (sqlite-execute connection maillist--settings-table)
    (sqlite-execute connection maillist--nntp-table)
    (maillist--migrate-v3-tables connection)
    (car (car (sqlite-select connection "PRAGMA journal_mode = wal")))))

(defun maillist-store-setting (key &optional store)
  "Return the stored setting KEY from STORE (or `maillist-store-file'), or nil."
  (let ((maillist-store-file (maillist--store-file store)))
    (maillist--with-connection
      (car (car (sqlite-select connection
                               "SELECT value FROM settings WHERE key = ?"
                               (list key)))))))

(defun maillist-store-save-setting (key value &optional store)
  "Store VALUE as setting KEY in STORE (or `maillist-store-file') and return VALUE."
  (let ((maillist-store-file (maillist--store-file store)))
    (maillist--with-connection
      (sqlite-execute connection
                      "INSERT INTO settings (key, value) VALUES (?, ?)
                       ON CONFLICT (key) DO UPDATE SET value = excluded.value"
                      (list key value))))
  value)

(defun maillist-store-save-marks (store marks)
  "Store MARKS of STORE in one transaction; return how many rows it wrote.
Each entry in MARKS is (ID READ STARRED) or
\(ID READ STARRED READ-DATE READ-COUNT)."
  (when (and store marks)
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (sqlite-execute connection "BEGIN IMMEDIATE")
        (condition-case err
            (progn
              (dolist (mark marks)
                (let* ((id (nth 0 mark))
                       (read (if (nth 1 mark) 1 0))
                       (starred (if (nth 2 mark) 1 0))
                       (has-meta (> (length mark) 3))
                       (read-date (and (= read 1) (nth 3 mark)))
                       (read-count (and (= read 1) (nth 4 mark))))
                  (if (or has-meta (= read 0))
                      (sqlite-execute
                       connection
                       "INSERT INTO marks (id, read, starred, read_date, read_count)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT (id) DO UPDATE SET
                          read = excluded.read,
                          starred = excluded.starred,
                          read_date = excluded.read_date,
                          read_count = excluded.read_count"
                       (list id read starred read-date read-count))
                    (sqlite-execute
                     connection
                     "INSERT INTO marks (id, read, starred) VALUES (?, ?, ?)
                      ON CONFLICT (id) DO UPDATE SET
                        read = excluded.read,
                        starred = excluded.starred"
                     (list id read starred)))))
              (sqlite-execute connection "COMMIT")
              (length marks))
          (error (ignore-errors (sqlite-execute connection "ROLLBACK"))
                 (signal (car err) (cdr err))))))))

(defun maillist-store-prune (store list)
  "Drop what LIST no longer needs from STORE and return the removed row counts.
Rows beyond `maillist-thread-limit' and bodies beyond `maillist-body-limit'
for LIST go, newest kept; starred threads and other lists' cached bodies are
never dropped, and marks always stay.  Reclaims freed pages incrementally
without blocking the UI with a full VACUUM."
  (when store
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (let* ((threads
                (sqlite-execute
                 connection
                 "DELETE FROM threads
                   WHERE list_name = ?
                     AND id NOT IN (SELECT id FROM marks WHERE starred = 1)
                     AND id NOT IN
                         (SELECT id FROM threads WHERE list_name = ?
                           ORDER BY date DESC LIMIT ?)"
                 (list list list maillist-thread-limit)))
               ;; Keep the newest `maillist-body-limit' threads of LIST, every
               ;; starred thread, and every thread stored under another list.
               (bodies
                (sqlite-execute
                 connection
                 "DELETE FROM messages
                   WHERE thread NOT IN (SELECT id FROM marks WHERE starred = 1)
                     AND thread NOT IN (SELECT id FROM threads WHERE list_name != ?)
                     AND thread NOT IN
                         (SELECT id FROM threads WHERE list_name = ?
                           ORDER BY date DESC LIMIT ?)"
                 (list list list maillist-body-limit))))
          (ignore-errors
            (sqlite-execute
             connection
             "DELETE FROM nntp_articles
               WHERE list_name = ?
                 AND artnum NOT IN
                     (SELECT artnum FROM nntp_articles WHERE list_name = ?
                       ORDER BY artnum DESC LIMIT ?)"
             (list list list (* maillist-thread-limit 4))))
          (when (> (+ threads bodies) 100)
            (ignore-errors (sqlite-execute connection "PRAGMA incremental_vacuum(200)"))
            (ignore-errors (sqlite-execute connection "PRAGMA wal_checkpoint(PASSIVE)")))
          (list :threads threads :bodies bodies))))))

;;; ---------------------------------------------------------------------------
;;; Local search
;;; ---------------------------------------------------------------------------

(defun maillist--like-escape (text)
  "Escape SQLite LIKE wildcards in TEXT for use with `ESCAPE \\'."
  (let* ((s (replace-regexp-in-string "\\\\" "\\\\\\\\" (downcase (or text "")) t t))
         (s (replace-regexp-in-string "%" "\\\\%" s t t)))
    (format "%%%s%%" (replace-regexp-in-string "_" "\\\\_" s t t))))

(defun maillist--clean-snippet (text)
  "Return TEXT collapsed to a single-line snippet suitable for a list row."
  (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " (or text ""))))

(defun maillist--extract-snippet (body needle)
  "Return a short single-line snippet of BODY around NEEDLE, or nil."
  (when (and (stringp body) (stringp needle) (not (string-empty-p needle)))
    (let* ((case-fold-search t)
           (pos (string-match (regexp-quote needle) body)))
      (when pos
        (let* ((start (max 0 (- pos 30)))
               (end (min (length body) (+ start 90))))
          (maillist--clean-snippet (substring body start end)))))))

(defun maillist-store-search-bodies (store text limit &optional list)
  "Return up to LIMIT (THREAD-ID . SNIPPET) pairs from STORE matching TEXT.
The scan is case-insensitive over cached bodies with SQLite LIKE wildcards
escaped, deduplicated per thread (newest matching message first), and scoped
to LIST when non-nil."
  (when (and store (not (string-empty-p (string-trim (or text "")))))
    (let* ((maillist-store-file (maillist--store-file store))
           (trimmed (string-trim text))
           (ascii-p (string-match-p "\\`[\x00-\x7f]*\\'" trimmed))
           (pattern (maillist--like-escape trimmed))
           (needle (downcase trimmed))
           (cap (max 1 (or limit 50)))
           (probe (* cap 4))
           (match-expr (if ascii-p "m.body LIKE ? ESCAPE '\\'"
                         "lower(m.body) LIKE ? ESCAPE '\\'")))
      (maillist--with-connection
        ;; Fast path: scan newest matching messages first using idx_messages_date
        ;; and deduplicate per thread in Elisp; only fall back to full GROUP BY
        ;; when a single hot thread filled the probe window.
        (let* ((fast-sql
                (if list
                    (format
                     "SELECT m.thread,
                             substr(m.body, max(1, instr(lower(m.body), ?) - 30), 90)
                        FROM messages m
                        JOIN threads t ON t.id = m.thread AND t.list_name = ?
                       WHERE %s
                       ORDER BY m.date DESC
                       LIMIT ?"
                     match-expr)
                  (format
                   "SELECT m.thread,
                           substr(m.body, max(1, instr(lower(m.body), ?) - 30), 90)
                      FROM messages m
                     WHERE %s
                     ORDER BY m.date DESC
                     LIMIT ?"
                   match-expr)))
               (fast-params (if list
                                (list needle list pattern probe)
                              (list needle pattern probe)))
               (raw (sqlite-select connection fast-sql fast-params))
               (seen (make-hash-table :test #'equal))
               (dedup nil))
          (dolist (row raw)
            (when (and (< (length dedup) cap)
                       (not (gethash (nth 0 row) seen)))
              (puthash (nth 0 row) t seen)
              (push (cons (nth 0 row) (maillist--clean-snippet (nth 1 row))) dedup)))
          (if (or (>= (length dedup) cap) (< (length raw) probe))
              (nreverse dedup)
            (let* ((slow-sql
                    (if list
                        (format
                         "SELECT m.thread,
                                 substr(m.body, max(1, instr(lower(m.body), ?) - 30), 90)
                            FROM messages m
                            JOIN (
                              SELECT m.rowid AS rid, max(m.date) AS latest
                                FROM messages m
                                JOIN threads t ON t.id = m.thread AND t.list_name = ?
                               WHERE %s
                               GROUP BY m.thread
                               ORDER BY latest DESC
                               LIMIT ?
                            ) hit ON m.rowid = hit.rid
                           ORDER BY hit.latest DESC"
                         match-expr)
                      (format
                       "SELECT m.thread,
                               substr(m.body, max(1, instr(lower(m.body), ?) - 30), 90)
                          FROM messages m
                          JOIN (
                            SELECT m.rowid AS rid, max(m.date) AS latest
                              FROM messages m
                             WHERE %s
                             GROUP BY m.thread
                             ORDER BY latest DESC
                             LIMIT ?
                          ) hit ON m.rowid = hit.rid
                         ORDER BY hit.latest DESC"
                       match-expr)))
                   (slow-params (if list
                                    (list needle list pattern cap)
                                  (list needle pattern cap))))
              (mapcar
               (lambda (row)
                 (cons (nth 0 row) (maillist--clean-snippet (nth 1 row))))
               (sqlite-select connection slow-sql slow-params)))))))))

(defun maillist-store--term-clause (term)
  "Return (SQL . PARAMS) evaluating search TERM against thread alias `t'."
  (let* ((field (plist-get term :field))
         (value (or (plist-get term :value) ""))
         (negate (plist-get term :negate))
         (pat (maillist--like-escape value))
         (pair
          (pcase field
            ('after (cons "substr(coalesce(t.date, ''), 1, 10) >= ?" (list value)))
            ('before (cons "substr(coalesce(t.date, ''), 1, 10) <= ?" (list value)))
            ('subject
             (cons "(lower(coalesce(t.subject, '')) LIKE ? ESCAPE '\\'
                     OR EXISTS (SELECT 1 FROM messages m
                                 WHERE m.thread = t.id
                                   AND lower(coalesce(m.subject, '')) LIKE ? ESCAPE '\\'))"
                   (list pat pat)))
            ('from
             (cons "(lower(coalesce(t.author, '')) LIKE ? ESCAPE '\\'
                     OR EXISTS (SELECT 1 FROM messages m
                                 WHERE m.thread = t.id
                                   AND (lower(coalesce(m.author, '')) LIKE ? ESCAPE '\\'
                                        OR lower(coalesce(m.email, '')) LIKE ? ESCAPE '\\')))"
                   (list pat pat pat)))
            ('body
             (cons "EXISTS (SELECT 1 FROM messages m
                             WHERE m.thread = t.id
                               AND lower(coalesce(m.body, '')) LIKE ? ESCAPE '\\')"
                   (list pat)))
            ('message
             (cons "(lower(coalesce(t.id, '')) LIKE ? ESCAPE '\\'
                     OR EXISTS (SELECT 1 FROM messages m
                                 WHERE m.thread = t.id
                                   AND lower(coalesce(m.id, '')) LIKE ? ESCAPE '\\'))"
                   (list pat pat)))
            (_
             (cons "(lower(coalesce(t.subject, '')) LIKE ? ESCAPE '\\'
                     OR lower(coalesce(t.author, '')) LIKE ? ESCAPE '\\'
                     OR EXISTS (SELECT 1 FROM messages m
                                 WHERE m.thread = t.id
                                   AND (lower(coalesce(m.body, '')) LIKE ? ESCAPE '\\'
                                        OR lower(coalesce(m.author, '')) LIKE ? ESCAPE '\\')))"
                   (list pat pat pat pat))))))
    (if negate
        (cons (format "NOT (%s)" (car pair)) (cdr pair))
      pair)))

(defun maillist-store--search-local (store list terms limit)
  "Evaluate structured TERMS against cached threads and bodies of LIST in STORE.
Return up to LIMIT (THREAD-ID . SNIPPET) pairs, newest first; SNIPPET is
non-nil when a cached message body matched a positive term."
  (when (and store terms)
    (let* ((maillist-store-file (maillist--store-file store))
           (cap (max 1 (or limit 50)))
           (clauses (mapcar #'maillist-store--term-clause terms))
           (where (mapconcat #'car clauses " AND "))
           (params (append (list list)
                           (cl-loop for clause in clauses append (cdr clause))
                           (list cap)))
           (snippet-terms
            (delq nil
                  (mapcar (lambda (term)
                            (when (and (not (plist-get term :negate))
                                       (memq (plist-get term :field) '(body any)))
                              (plist-get term :value)))
                          terms))))
      (maillist--with-connection
        (let ((ids (mapcar #'car
                           (sqlite-select
                            connection
                            (format "SELECT t.id FROM threads t
                                      WHERE t.list_name = ? AND %s
                                      ORDER BY t.date DESC
                                      LIMIT ?"
                                    where)
                            params))))
          (mapcar
           (lambda (id)
             (let ((snippet nil))
               (when snippet-terms
                 (let ((needle (car snippet-terms))
                       (pat (maillist--like-escape (car snippet-terms))))
                   (when-let* ((row
                                (car (sqlite-select
                                      connection
                                      "SELECT body FROM messages
                                        WHERE thread = ?
                                          AND lower(body) LIKE ? ESCAPE '\\'
                                        ORDER BY date DESC LIMIT 1"
                                      (list id pat)))))
                     (setq snippet (maillist--extract-snippet (car row) needle)))))
               (cons id snippet)))
           ids))))))

;;; ---------------------------------------------------------------------------
;;; Threads, marks and messages
;;; ---------------------------------------------------------------------------

(defun maillist-store-threads (store list)
  "Return every stored row of LIST in STORE as a plist, newest first."
  (when store
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (mapcar
         (lambda (row)
           (list :id (nth 0 row)
                 :subject (nth 1 row)
                 :date (nth 2 row)
                 :count (nth 3 row)
                 :author (nth 4 row)
                 :depth (or (nth 5 row) 0)
                 :list (nth 6 row)
                 :participants (nth 7 row)))
         (sqlite-select
          connection
          "SELECT id, subject, date, thread_count, author, depth, list_name, participants
             FROM threads
            WHERE list_name = ?
            ORDER BY date DESC, depth ASC"
          (list list)))))))

(defun maillist-store-adopt-threads (store list)
  "Tag the rows of STORE that carry no list name with LIST.
An earlier version kept one thread table for every archive, so its rows say
nothing about the list they came from.  Tagging them costs one write and
keeps the cache the reader already has; dropping them would empty it once."
  (when store
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (sqlite-execute connection "BEGIN IMMEDIATE")
        (condition-case err
            (progn
              (sqlite-execute
               connection
               "UPDATE OR IGNORE threads
                   SET row_key = ? || char(31) || id,
                       list_name = ?
                 WHERE list_name IS NULL OR list_name = ''"
               (list list list))
              (sqlite-execute
               connection
               "DELETE FROM threads WHERE list_name IS NULL OR list_name = ''")
              (sqlite-execute connection "COMMIT"))
          (error (ignore-errors (sqlite-execute connection "ROLLBACK"))
                 (signal (car err) (cdr err))))))))

(defun maillist-store-save-threads (store list rows)
  "Write ROWS of LIST to the thread table of STORE and return it.
The batch is one transaction.  An empty ROWS list writes nothing: a caller
that filtered every row out (or a sync that reported no threads) must not
reach the controller as an empty batch, which it rejects.  A row carries the
archive's facts only; read and starred live in the mark table."
  (when-let* ((controller (and store (maillist-store-thread-controller store)))
              (operations
               (mapcar (lambda (row)
                         (let ((id (plist-get row :id)))
                           (list 'upsert
                                 (list :row-key (maillist--row-key list id)
                                       :id id
                                       :list list
                                       :subject (or (plist-get row :subject) "")
                                       :date (plist-get row :date)
                                       :count (plist-get row :count)
                                       :author (or (plist-get row :author) "")
                                       :depth (or (plist-get row :depth) 0)
                                       :participants (plist-get row :participants)))))
                       rows)))
    (etaf-data-mutate-many controller operations)))

(defun maillist-store-marks (store)
  "Return every stored mark of STORE as an alist of ID to a mark plist.
Each mark carries `:read', `:starred', `:read-date' and `:read-count'."
  (when store
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (mapcar (lambda (row)
                  (cons (nth 0 row)
                        (list :read (eq 1 (nth 1 row))
                              :starred (eq 1 (nth 2 row))
                              :read-date (nth 3 row)
                              :read-count (nth 4 row))))
                (sqlite-select
                 connection
                 "SELECT id, read, starred, read_date, read_count FROM marks"))))))

(defun maillist-store-save-mark (store id read starred &optional read-date read-count)
  "Store the mark of thread ID in STORE: READ and STARRED as booleans.
Optional READ-DATE and READ-COUNT record the thread snapshot at the time it
was marked read so later syncs can detect newly arrived replies."
  (when store
    (maillist-store-save-marks
     store
     (list (if (or read-date read-count (not read))
               (list id read starred read-date read-count)
             (list id read starred))))))

(defun maillist-store-thread-messages (store id)
  "Return the messages of thread ID cached in STORE, oldest first."
  (when store
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (mapcar
         (lambda (row)
           (list :id (nth 0 row)
                 :thread (nth 1 row)
                 :author (nth 2 row)
                 :email (nth 3 row)
                 :date (nth 4 row)
                 :parent (nth 5 row)
                 :depth (or (nth 6 row) 0)
                 :position (or (nth 7 row) 0)
                 :text (or (nth 8 row) "")
                 :subject (or (nth 9 row) "")))
         (sqlite-select
          connection
          "SELECT id, thread, author, email, date, parent, depth, position, body, subject
             FROM messages
            WHERE thread = ?
            ORDER BY position ASC"
          (list id)))))))

(defun maillist-store-save-thread-messages (store id messages)
  "Cache MESSAGES as thread ID in STORE, replacing stale rows in one transaction.
An empty MESSAGES list writes nothing, so a failed fetch never replaces a
cached body with nothing."
  (when-let* ((controller (and store (consp messages)
                               (maillist-store-message-controller store))))
    (let* ((maillist-store-file (maillist--store-file store))
           (new-keys (mapcar (lambda (m) (maillist--row-key id (plist-get m :id)))
                             messages))
           (existing-keys
            (maillist--with-connection
              (mapcar #'car
                      (sqlite-select connection
                                     "SELECT row_key FROM messages WHERE thread = ?"
                                     (list id)))))
           (stale (cl-set-difference existing-keys new-keys :test #'equal))
           (deletes (mapcar (lambda (key) (list 'delete (list :row-key key))) stale))
           (upserts
            (cl-loop for message in messages
                     for position from 0
                     collect
                     (let ((mid (plist-get message :id)))
                       (list 'upsert
                             (list :row-key (maillist--row-key id mid)
                                   :id mid
                                   :thread id
                                   :author (or (plist-get message :author) "")
                                   :email (or (plist-get message :email) "")
                                   :date (plist-get message :date)
                                   :parent (plist-get message :parent)
                                   :depth (or (plist-get message :depth) 0)
                                   :position position
                                   :text (or (plist-get message :text) "")
                                   :subject (or (plist-get message :subject) "")))))))
      (etaf-data-mutate-many controller (append deletes upserts)))))

;;; ---------------------------------------------------------------------------
;;; NNTP overview & cache inspection helpers
;;; ---------------------------------------------------------------------------

(defun maillist-store--save-nntp-articles (store list articles)
  "Persist NNTP overview ARTICLES of LIST in STORE in one transaction."
  (when (and store list articles)
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (sqlite-execute connection "BEGIN IMMEDIATE")
        (condition-case err
            (progn
              (dolist (art articles)
                (let ((refs (plist-get art :references)))
                  (sqlite-execute
                   connection
                   "INSERT INTO nntp_articles
                      (list_name, artnum, id, root_id, parent_id, subject, author, email, date, refs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (list_name, artnum) DO UPDATE SET
                      id = excluded.id,
                      root_id = excluded.root_id,
                      parent_id = excluded.parent_id,
                      subject = excluded.subject,
                      author = excluded.author,
                      email = excluded.email,
                      date = excluded.date,
                      refs = excluded.refs"
                   (list list
                         (plist-get art :artnum)
                         (or (plist-get art :id) "")
                         (or (plist-get art :root-id) (plist-get art :id) "")
                         (plist-get art :parent)
                         (or (plist-get art :subject) "")
                         (or (plist-get art :author) "")
                         (or (plist-get art :email) "")
                         (or (plist-get art :date) "")
                         (if (listp refs) (string-join refs " ") (or refs ""))))))
              (sqlite-execute connection "COMMIT")
              (length articles))
          (error (ignore-errors (sqlite-execute connection "ROLLBACK"))
                 (signal (car err) (cdr err))))))))

(defun maillist-store--nntp-range (store list)
  "Return (MIN-ARTNUM . MAX-ARTNUM) stored for LIST in STORE, or nil."
  (when (and store list)
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (when-let* ((row (car (sqlite-select
                               connection
                               "SELECT min(artnum), max(artnum)
                                  FROM nntp_articles
                                 WHERE list_name = ?"
                               (list list))))
                    (lo (nth 0 row))
                    (hi (nth 1 row)))
          (cons lo hi))))))

(defun maillist-store--nntp-articles (store list &optional limit)
  "Return up to LIMIT newest NNTP overview articles of LIST from STORE."
  (when (and store list)
    (let ((maillist-store-file (maillist--store-file store))
          (cap (or limit 3000)))
      (maillist--with-connection
        (mapcar
         (lambda (row)
           (let ((refs (nth 8 row)))
             (list :artnum (nth 0 row)
                   :id (nth 1 row)
                   :root-id (nth 2 row)
                   :parent (nth 3 row)
                   :subject (or (nth 4 row) "")
                   :author (or (nth 5 row) "")
                   :email (or (nth 6 row) "")
                   :date (or (nth 7 row) "")
                   :references (if (and (stringp refs) (not (string-empty-p refs)))
                                   (split-string refs " " t)
                                 nil))))
         (sqlite-select
          connection
          "SELECT artnum, id, root_id, parent_id, subject, author, email, date, refs
             FROM nntp_articles
            WHERE list_name = ?
            ORDER BY artnum DESC
            LIMIT ?"
          (list list cap)))))))

(defun maillist-store--nntp-thread-mids (store list thread-id)
  "Return ordered canonical Message-IDs known for THREAD-ID of LIST in STORE.
Includes articles stored in `nntp_articles' for THREAD-ID as well as any
ancestor Message-IDs listed in their `References' header."
  (when (and store list thread-id)
    (let ((maillist-store-file (maillist--store-file store)))
      (maillist--with-connection
        (let* ((direct
                (sqlite-select
                 connection
                 "SELECT id, refs, root_id FROM nntp_articles
                   WHERE list_name = ? AND (root_id = ? OR id = ?)
                   ORDER BY date ASC, artnum ASC"
                 (list list thread-id thread-id)))
               (root (or (and direct (nth 2 (car direct))) thread-id))
               (rows
                (if (equal root thread-id)
                    direct
                  (sqlite-select
                   connection
                   "SELECT id, refs, root_id FROM nntp_articles
                     WHERE list_name = ? AND (root_id = ? OR id = ?)
                     ORDER BY date ASC, artnum ASC"
                   (list list root root))))
               (seen (make-hash-table :test #'equal))
               (ordered nil))
          (dolist (row rows)
            (let ((id (nth 0 row))
                  (refs (nth 1 row)))
              (when (and (stringp refs) (not (string-empty-p refs)))
                (dolist (r (split-string refs " " t))
                  (unless (gethash r seen)
                    (puthash r t seen)
                    (push r ordered))))
              (when (and (stringp id) (not (string-empty-p id))
                         (not (gethash id seen)))
                (puthash id t seen)
                (push id ordered))))
          (nreverse ordered))))))

(defun maillist-store--cached-thread-ids (store ids)
  "Return a hash-table of thread IDs in IDS that already have cached messages."
  (let ((table (make-hash-table :test #'equal)))
    (when (and store ids)
      (let* ((maillist-store-file (maillist--store-file store))
             (sample (seq-take ids 200))
             (placeholders (mapconcat (lambda (_) "?") sample ",")))
        (maillist--with-connection
          (dolist (row (sqlite-select
                        connection
                        (format "SELECT DISTINCT thread FROM messages
                                  WHERE thread IN (%s)"
                                placeholders)
                        sample))
            (puthash (car row) t table)))))
    table))

(defun maillist-store-close (store)
  "Release STORE's Data Controllers.
The mark table has no controller, so it needs no release."
  (dolist (controller (list (and store (maillist-store-thread-controller store))
                            (and store (maillist-store-message-controller store))))
    (when controller
      (condition-case nil (etaf-data-stop controller) (error nil)))))

(provide 'maillist-store)
;;; maillist-store.el ends here
