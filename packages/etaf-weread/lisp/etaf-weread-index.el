;;; etaf-weread-index.el --- SQLite index of the account's highlights -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The local index is the reader's own copy of every highlight and thought the
;; account has, kept in a SQLite database through ETAF DB.  WeChat Reading
;; serves one book's highlights per request; the index makes the whole notebook
;; searchable at once and survives restarts.
;;
;; This module owns the schema, the database descriptor and the storage
;; primitives.  The orchestration (which books to fetch, how the rows appear in
;; the list) lives in the model, so the storage stays independently testable
;; and the model keeps owning the backend conversation.
;;
;; The Data Controller owns reactive state and the connection lifecycle; this
;; module never touches SQL.  Reading a book's highlights stores them when
;; `etaf-weread-index-on-read' is non-nil, and `etaf-weread-index-notebook'
;; walks the notebook on demand.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-db)
(require 'etaf-weread-theme)

(defcustom etaf-weread-index-file
  (locate-user-emacs-file "etaf-weread/notes.sqlite3")
  "SQLite file holding the local highlight index.
Bind it before creating a session to keep several accounts apart or to use a
disposable database, as the acceptance scenarios do."
  :type 'file
  :group 'etaf-weread)

(defcustom etaf-weread-index-on-read t
  "Whether reading a book's highlights stores them in the local index.
The default builds the index as the account browses; nil leaves the database
untouched until `etaf-weread-index-notebook' is called explicitly."
  :type 'boolean
  :group 'etaf-weread)

(defun etaf-weread-index-database ()
  "Return the SQLite database descriptor of the local notes index.
The descriptor declares the `highlights' table used by the reader's index."
  (etaf-sqlite-database
   etaf-weread-index-file
   (etaf-sqlite-table
    'highlights
    (list (etaf-sqlite-column :id "id" :type 'text :primary t)
          (etaf-sqlite-column :book "book" :type 'text)
          (etaf-sqlite-column :book-title "book_title" :type 'text)
          (etaf-sqlite-column :chapter "chapter" :type 'text)
          (etaf-sqlite-column :text "text" :type 'text)
          (etaf-sqlite-column :thought "thought" :type 'text)
          (etaf-sqlite-column :created "created" :type 'integer))
    :id)))

(defun etaf-weread--index-controller (app)
  "Return APP's local-index Data Controller, creating it on first use.
The controller is created against `etaf-weread-index-file' and its table is
created when missing; the source supplies the primary key as the item
identity, so no extra callback is needed."
  (or (plist-get app :index-controller)
      (let* ((database (etaf-weread-index-database))
             (_ (etaf-sqlite-initialize database))
             (controller (etaf-data-controller
                          (etaf-sqlite-source database)
                          :page-size 5000
                          :auto-load nil
                          :name 'etaf-weread-index)))
        (setf (plist-get app :index-controller) controller)
        controller)))

(defun etaf-weread--index-rows (app)
  "Return every stored highlight of APP's local index.
The rows are loaded through APP's Data Controller, so the controller's page
size (5000) covers a personal notebook in one query."
  (let* ((controller (etaf-weread--index-controller app))
         (items (progn
                  (etaf-data-set-page controller 1)
                  (etaf-data-load controller)
                  (etaf-value (etaf-data-items controller)))))
    (append items nil)))

(defun etaf-weread--index-note-rows (id notes)
  "Return the index rows of book ID's NOTES.
One row matches one highlight and carries its attached thought; a thought
without a highlight is its own row with an empty text."
  (let ((title (or (plist-get notes :title) "")))
    (cl-loop for group in (plist-get notes :groups)
             append (cl-loop for item in (plist-get group :items)
                             for row-id = (plist-get item :id)
                             when (and row-id (not (string-empty-p row-id)))
                             collect (list :id row-id
                                           :book id
                                           :book-title title
                                           :chapter (or (plist-get group :chapter) "")
                                           :text (or (plist-get item :text) "")
                                           :thought (or (plist-get item :thought) "")
                                           :created (or (plist-get item :time) 0))))))

(defun etaf-weread--index-store (app id notes)
  "Store the highlights of book ID's NOTES in APP's local index.
One `upsert' per row makes the store match the reply whether that row is new
or changed, so callers never need to query first.  Return a plist with the
number of `:stored' rows.  Storage failures signal, so the caller can report
them in the status line instead of pretending the index was written."
  (let* ((rows (etaf-weread--index-note-rows id notes))
         (controller (etaf-weread--index-controller app)))
    (dolist (row rows)
      (etaf-data-mutate controller 'upsert row))
    (list :stored (length rows))))

(defun etaf-weread--index-books (app)
  "Return the set of book ids already present in APP's local index."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (row (etaf-weread--index-rows app))
      (when-let* ((book (plist-get row :book)))
        (puthash book t table)))
    table))

(defun etaf-weread--index-filter (rows query)
  "Return ROWS whose highlight, thought, chapter or book title matches QUERY.
QUERY nil or empty returns every row.  Matching is case-insensitive through
`case-fold-search' and the rows keep their stored order."
  (let ((query (string-trim (or query ""))))
    (if (string-empty-p query)
        rows
      (let ((regexp (regexp-quote query)))
        (cl-remove-if-not
         (lambda (row)
           (or (string-match-p regexp (or (plist-get row :text) ""))
               (string-match-p regexp (or (plist-get row :thought) ""))
               (string-match-p regexp (or (plist-get row :chapter) ""))
               (string-match-p regexp (or (plist-get row :book-title) ""))))
         rows)))))

(defun etaf-weread--index-sorted (rows)
  "Return ROWS newest first, so the index reads as a reading trail."
  (sort (copy-sequence rows)
        (lambda (left right)
          (> (or (plist-get left :created) 0)
             (or (plist-get right :created) 0)))))

(defun etaf-weread--index-list-rows (rows)
  "Return index ROWS as list rows the book list can render.
Each row keeps `:kind' `:highlight' so the view and the activation know it is
an indexed highlight rather than a book."
  (cl-loop for row in rows
           collect (list :kind :highlight
                         :id (plist-get row :id)
                         :book (plist-get row :book)
                         :title (or (plist-get row :book-title) "")
                         :chapter (or (plist-get row :chapter) "")
                         :text (or (plist-get row :text) "")
                         :thought (or (plist-get row :thought) "")
                         :created (or (plist-get row :created) 0))))

(defun etaf-weread--index-dispose (app)
  "Stop APP's local-index controller and release its scope."
  (when-let* ((controller (plist-get app :index-controller)))
    (condition-case nil
        (etaf-data-stop controller)
      (error nil))
    (setf (plist-get app :index-controller) nil)))

(provide 'etaf-weread-index)
;;; etaf-weread-index.el ends here
