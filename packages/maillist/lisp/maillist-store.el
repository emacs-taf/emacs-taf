;;; maillist-store.el --- SQLite persistence of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The client keeps two tables in one SQLite file: `threads' holds what the
;; list needs (subject, date, size, author, and the client's own read and
;; starred marks) and `messages' holds cached bodies per thread.  Metadata and
;; bodies are separate because a refresh rewrites the list while bodies only
;; arrive when a thread is opened.
;;
;; The store owns the schema and one Data Controller per table; callers read
;; and write through the functions below and never touch SQL.  Batches are
;; written in one transaction, so a refresh never rewrites the file per row.

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
  "Open storage of the client: two databases and their controllers."
  thread-database message-database thread-controller message-controller)

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
          (etaf-sqlite-column :participants "participants" :type 'integer :nullable t)
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

(defun maillist-store-open ()
  "Open the client's storage and return it, or nil when SQLite is missing.
The database file is created together with its tables on first use."
  (condition-case nil
      (let* ((threads (maillist--thread-database))
             (messages (maillist--message-database))
             (_ (make-directory (file-name-directory maillist-store-file) t)))
        (etaf-sqlite-initialize threads)
        (etaf-sqlite-initialize messages)
        (maillist--store-create
         :thread-database threads
         :message-database messages
         :thread-controller (maillist--controller threads 'maillist-threads)
         :message-controller (maillist--controller messages 'maillist-messages)))
    (error nil)))

(defun maillist-store-threads (store)
  "Return every stored thread row as a plist."
  (when-let* ((controller (and store (maillist-store-thread-controller store))))
    (etaf-data-set-query controller nil)
    (etaf-data-set-page controller 1)
    (etaf-data-load controller)
    (sort (append (etaf-value (etaf-data-items controller)) nil)
          (lambda (first second)
            (string> (or (plist-get first :date) "")
                     (or (plist-get second :date) ""))))))

(defun maillist-store-save-threads (store rows)
  "Write ROWS to the thread table in one transaction and return the result."
  (when-let* ((controller (and store (maillist-store-thread-controller store))))
    (etaf-data-mutate-many
     controller
     (mapcar (lambda (row)
               (list 'upsert
                     (list :id (plist-get row :id)
                           :subject (or (plist-get row :subject) "")
                           :date (plist-get row :date)
                           :count (plist-get row :count)
                           :author (or (plist-get row :author) "")
                           :participants (plist-get row :participants)
                           :read (if (plist-get row :unread) 0 1)
                           :starred (if (plist-get row :starred) 1 0))))
             rows))))

(defun maillist-store-set-thread-state (store id fields)
  "Update the state FIELDS of thread ID and return the mutation result.
FIELDS is a plist holding `:read' and/or `:starred' booleans; every other
column keeps its stored value."
  (when-let* ((controller (and store (maillist-store-thread-controller store))))
    (etaf-data-mutate controller 'upsert
                      (append (list :id id)
                              (cl-loop for (key value) on fields by #'cddr
                                       collect key
                                       collect (if value 1 0))))))

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
  "Release STORE's Data Controllers."
  (dolist (controller (list (and store (maillist-store-thread-controller store))
                            (and store (maillist-store-message-controller store))))
    (when controller
      (condition-case nil (etaf-data-stop controller) (error nil)))))

(provide 'maillist-store)
;;; maillist-store.el ends here
