;;; maillist-store.el --- SQLite persistence of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The client keeps three tables in one SQLite file.  `threads' is the archive
;; cache: subject, date, size and author, all replaceable on the next sync.
;; `messages' holds cached bodies per thread.  `marks' holds what only the
;; reader decides, read and starred per thread; a refresh rewrites the archive
;; cache and cannot lose them.  Rows carry the name of the archive they came
;; from, so two lists never mix.
;;
;; The store owns the schema and one Data Controller per table; callers read
;; and write through the functions below and never touch SQL.  Batches are
;; written in one transaction, so a refresh never rewrites the file per row.
;;
;; The cache is rebuildable.  When an older file cannot be read with the
;; current columns, opening rebuilds it instead of leaving the client with no
;; persistence at all.

;;; Code:

(require 'cl-lib)
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

(cl-defstruct (maillist-store (:constructor maillist--store-create))
  "Open storage of the client: three databases and two controllers.
REBUILT is nil, or the path of the incompatible file set aside on open."
  thread-database message-database mark-database
  thread-controller message-controller rebuilt)

(defun maillist--thread-database ()
  "Return the database descriptor of the thread table."
  (etaf-sqlite-database
   maillist-store-file
   (etaf-sqlite-table
    'threads
    (list (etaf-sqlite-column :id "id" :type 'text :primary t)
          (etaf-sqlite-column :subject "subject" :type 'text :nullable t)
          (etaf-sqlite-column :date "date" :type 'text :nullable t)
          (etaf-sqlite-column :count "thread_count" :type 'integer :nullable t)
          (etaf-sqlite-column :author "author" :type 'text :nullable t)
          (etaf-sqlite-column :depth "depth" :type 'integer :nullable t)
          (etaf-sqlite-column :list "list_name" :type 'text :nullable t)
          (etaf-sqlite-column :participants "participants" :type 'integer :nullable t))
    :id)))

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
          (etaf-sqlite-column :starred "starred" :type 'integer :nullable t))
    :id)))

(defun maillist--message-database ()
  "Return the database descriptor of the message table."
  (etaf-sqlite-database
   maillist-store-file
   (etaf-sqlite-table
    'messages
    (list (etaf-sqlite-column :id "id" :type 'text :primary t)
          (etaf-sqlite-column :thread "thread" :type 'text :nullable t)
          (etaf-sqlite-column :author "author" :type 'text :nullable t)
          (etaf-sqlite-column :email "email" :type 'text :nullable t)
          (etaf-sqlite-column :date "date" :type 'text :nullable t)
          (etaf-sqlite-column :depth "depth" :type 'integer :nullable t)
          (etaf-sqlite-column :position "position" :type 'integer :nullable t)
          (etaf-sqlite-column :text "body" :type 'text :nullable t)
          (etaf-sqlite-column :subject "subject" :type 'text :nullable t))
    :id)))

(defun maillist--controller (database name)
  "Return a Data Controller over DATABASE named NAME."
  (etaf-data-controller (etaf-sqlite-source database)
                        :page-size 2000
                        :auto-load nil
                        :name name))

(defun maillist--open-tables (rebuilt)
  "Open and initialize the client's tables, marking the store REBUILT or not."
  (let* ((threads (maillist--thread-database))
         (messages (maillist--message-database))
         (marks (maillist--mark-database)))
    (etaf-sqlite-initialize threads)
    (etaf-sqlite-initialize messages)
    (etaf-sqlite-initialize marks)
    (maillist--store-create
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

(defun maillist-store-open ()
  "Open the client's storage and return it, or nil when SQLite is missing.
The file is created together with its tables on first use.  A file written by
an incompatible earlier version is moved aside and rebuilt: the archive cache
and cached bodies can be fetched again, so a reader keeps working instead of
losing persistence silently.  The store reports the backup file, because a
rebuild drops the marks stored in the old one."
  (condition-case nil
      (progn
        (when-let* ((directory (file-name-directory maillist-store-file)))
          (make-directory directory t))
        (maillist--open-tables nil))
    (etaf-sqlite-schema-error
     (let ((backup (maillist--retire-cache)))
       (condition-case nil
           (maillist--open-tables backup)
         (error nil))))
    (error nil)))

(defun maillist-store-threads (store list)
  "Return every stored row of LIST as a plist, newest first."
  (when-let* ((controller (and store (maillist-store-thread-controller store))))
    (etaf-data-set-query controller (list :list list))
    (etaf-data-set-page controller 1)
    (etaf-data-load controller)
    (sort (append (etaf-value (etaf-data-items controller)) nil)
          (lambda (first second)
            (string> (or (plist-get first :date) "")
                     (or (plist-get second :date) ""))))))

(defun maillist-store-adopt-threads (store list)
  "Tag stored rows that carry no list name with LIST.
An earlier version kept one thread table for every archive, so its rows say
nothing about the list they came from.  Tagging them costs one write and
keeps the cache the reader already has; dropping them would empty it once."
  (when-let* ((controller (and store (maillist-store-thread-controller store))))
    (etaf-data-set-query controller nil)
    (etaf-data-set-page controller 1)
    (etaf-data-load controller)
    (let ((orphans
           (seq-filter (lambda (record)
                         (string-empty-p (or (plist-get record :list) "")))
                       (append (etaf-value (etaf-data-items controller)) nil))))
      (when orphans
        (etaf-data-mutate-many
         controller
         (mapcar (lambda (record)
                   (list 'upsert (plist-put (copy-sequence record) :list list)))
                 orphans))))))

(defun maillist-store-save-threads (store list rows)
  "Write ROWS of LIST to the thread table in one transaction and return it.
An empty ROWS list writes nothing: a caller that filtered every row out (or a
sync that reported no threads) must not reach the controller as an empty
batch, which it rejects.  A row carries the archive's facts only; read and
starred live in the mark table."
  (when-let* ((controller (and store (maillist-store-thread-controller store)))
              (operations
               (mapcar (lambda (row)
                         (list 'upsert
                               (list :id (plist-get row :id)
                                     :list list
                                     :subject (or (plist-get row :subject) "")
                                     :date (plist-get row :date)
                                     :count (plist-get row :count)
                                     :author (or (plist-get row :author) "")
                                     :depth (or (plist-get row :depth) 0)
                                     :participants (plist-get row :participants))))
                       rows)))
    (etaf-data-mutate-many controller operations)))

(defun maillist-store-marks (store)
  "Return every stored mark as an alist of ID to (:read BOOLEAN :starred BOOLEAN)."
  (when-let* ((database (maillist-store-mark-database store)))
    (let* ((source (etaf-sqlite-source database))
           (page (funcall (plist-get source :load) nil 1 5000)))
      (mapcar (lambda (item)
                (cons (plist-get item :id)
                      (list :read (eq 1 (plist-get item :read))
                            :starred (eq 1 (plist-get item :starred)))))
              (plist-get page :items)))))

(defun maillist-store-save-mark (store id read starred)
  "Store the mark of thread ID: READ and STARRED as booleans.
The whole mark is written, so a toggle never clears the other flag."
  (when-let* ((database (maillist-store-mark-database store)))
    (funcall (plist-get (etaf-sqlite-source database) :mutate)
             'upsert
             (list :id id
                   :read (if read 1 0)
                   :starred (if starred 1 0)))))

(defun maillist-store-thread-messages (store id)
  "Return the cached messages of thread ID, oldest first."
  (when-let* ((controller (and store (maillist-store-message-controller store))))
    (etaf-data-set-query controller (list (cons :thread id)))
    (etaf-data-set-page controller 1)
    (etaf-data-load controller)
    (sort (append (etaf-value (etaf-data-items controller)) nil)
          (lambda (first second)
            (< (or (plist-get first :position) 0)
               (or (plist-get second :position) 0))))))

(defun maillist-store-save-thread-messages (store id messages)
  "Cache MESSAGES as thread ID in one transaction.
An empty MESSAGES list writes nothing, so a failed fetch never replaces a
cached body with nothing."
  (when-let* ((controller (and store (maillist-store-message-controller store)))
              (operations
               (cl-loop for message in messages
                        for position from 0
                        collect
                        (list 'upsert
                              (list :id (plist-get message :id)
                                    :thread id
                                    :author (or (plist-get message :author) "")
                                    :email (or (plist-get message :email) "")
                                    :date (plist-get message :date)
                                    :depth (or (plist-get message :depth) 0)
                                    :position position
                                    :text (or (plist-get message :text) "")
                                    :subject (or (plist-get message :subject) ""))))))
    (etaf-data-mutate-many controller operations)))

(defun maillist-store-close (store)
  "Release STORE's Data Controllers.
The mark table has no controller, so it needs no release."
  (dolist (controller (list (and store (maillist-store-thread-controller store))
                            (and store (maillist-store-message-controller store))))
    (when controller
      (condition-case nil (etaf-data-stop controller) (error nil)))))

(provide 'maillist-store)
;;; maillist-store.el ends here
