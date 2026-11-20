;;; etaf-reader-store.el --- SQLite storage of etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The library lives in one SQLite file through ETAF DB.  Six tables share
;; the file, one Data Controller per table; every read goes through the
;; controller's equality query, so the store never touches SQL.  Chapter
;; metadata is separate from chapter content, which keeps listing a table of
;; contents cheap while a single chapter still loads in one row.
;;
;; Call `etaf-reader-store-close' when a session is disposed.  A module-level
;; store is reopened automatically when `etaf-reader-store-file' changes, so
;; tests can bind it to a temporary database.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'etaf)
(require 'etaf-db)
(require 'etaf-reader-theme)

(defcustom etaf-reader-store-file
  (locate-user-emacs-file "etaf-reader/library.sqlite3")
  "SQLite file holding the reader's library, annotations and progress."
  :type 'file
  :group 'etaf-reader)

(defvar etaf-reader--store nil
  "Open store plist, or nil when no store is open.")

;;; ---------------------------------------------------------------------------
;;; Schema
;;; ---------------------------------------------------------------------------

(defun etaf-reader--books-table ()
  "Return the `books' table metadata."
  (etaf-sqlite-table
   'books
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :title "title" :type 'text :nullable t)
         (etaf-sqlite-column :author "author" :type 'text :nullable t)
         (etaf-sqlite-column :format "format" :type 'text :nullable t)
         (etaf-sqlite-column :path "path" :type 'text :nullable t)
         (etaf-sqlite-column :cover "cover" :type 'text :nullable t)
         (etaf-sqlite-column :chapters "chapters" :type 'integer :nullable t)
         (etaf-sqlite-column :chars "chars" :type 'integer :nullable t)
         (etaf-sqlite-column :pages "pages" :type 'integer :nullable t)
         (etaf-sqlite-column :size "size" :type 'integer :nullable t)
         (etaf-sqlite-column :mtime "mtime" :type 'real :nullable t)
         (etaf-sqlite-column :added "added" :type 'integer :nullable t)
         (etaf-sqlite-column :opened "opened" :type 'integer :nullable t))
   :id))

(defun etaf-reader--chapters-table ()
  "Return the `chapters' table metadata (metadata only)."
  (etaf-sqlite-table
   'chapters
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :book "book" :type 'text :nullable t)
         (etaf-sqlite-column :idx "idx" :type 'integer :nullable t)
         (etaf-sqlite-column :title "title" :type 'text :nullable t)
         (etaf-sqlite-column :chars "chars" :type 'integer :nullable t))
   :id))

(defun etaf-reader--contents-table ()
  "Return the `contents' table metadata (chapter text and blocks)."
  (etaf-sqlite-table
   'contents
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :text "text" :type 'text :nullable t)
         (etaf-sqlite-column :blocks "blocks" :type 'text :nullable t))
   :id))

(defun etaf-reader--annotations-table ()
  "Return the `annotations' table metadata."
  (etaf-sqlite-table
   'annotations
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :book "book" :type 'text :nullable t)
         (etaf-sqlite-column :chapter "chapter" :type 'integer :nullable t)
         (etaf-sqlite-column :start "start" :type 'integer :nullable t)
         (etaf-sqlite-column :end "end" :type 'integer :nullable t)
         (etaf-sqlite-column :kind "kind" :type 'text :nullable t)
         (etaf-sqlite-column :color "color" :type 'text :nullable t)
         (etaf-sqlite-column :quote "quote" :type 'text :nullable t)
         (etaf-sqlite-column :note "note" :type 'text :nullable t)
         (etaf-sqlite-column :created "created" :type 'integer :nullable t)
         (etaf-sqlite-column :updated "updated" :type 'integer :nullable t))
   :id))

(defun etaf-reader--states-table ()
  "Return the `states' table metadata (reading progress)."
  (etaf-sqlite-table
   'states
   (list (etaf-sqlite-column :book "book" :type 'text :primary t)
         (etaf-sqlite-column :chapter "chapter" :type 'integer :nullable t)
         (etaf-sqlite-column :offset "offset" :type 'integer :nullable t)
         (etaf-sqlite-column :percent "percent" :type 'real :nullable t)
         (etaf-sqlite-column :seconds "seconds" :type 'integer :nullable t)
         (etaf-sqlite-column :last_read "last_read" :type 'integer :nullable t))
   :book))

(defun etaf-reader--bookmarks-table ()
  "Return the `bookmarks' table metadata."
  (etaf-sqlite-table
   'bookmarks
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :book "book" :type 'text :nullable t)
         (etaf-sqlite-column :chapter "chapter" :type 'integer :nullable t)
         (etaf-sqlite-column :offset "offset" :type 'integer :nullable t)
         (etaf-sqlite-column :label "label" :type 'text :nullable t)
         (etaf-sqlite-column :created "created" :type 'integer :nullable t))
   :id))

(defun etaf-reader--preferences-table ()
  "Return persisted application reading preferences."
  (etaf-sqlite-table
   'preferences
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :value "value" :type 'text))
   :id))

(defun etaf-reader-store-preferences ()
  "Return the saved preference object, or nil."
  (when-let* ((row (car (etaf-reader--rows 'preferences (list :id "reading")))))
    (json-parse-string (plist-get row :value) :object-type 'plist)))

(defun etaf-reader-store-put-preferences (preferences)
  "Persist the validated PREFERENCES object."
  (etaf-reader--put 'preferences 'upsert
                    (list :id "reading" :value (json-encode preferences))))

(defconst etaf-reader--table-builders
  '((books . etaf-reader--books-table)
    (chapters . etaf-reader--chapters-table)
    (contents . etaf-reader--contents-table)
    (annotations . etaf-reader--annotations-table)
    (states . etaf-reader--states-table)
    (bookmarks . etaf-reader--bookmarks-table)
    (preferences . etaf-reader--preferences-table))
  "Table keyword -> descriptor builder.")

;;; ---------------------------------------------------------------------------
;;; Lifecycle
;;; ---------------------------------------------------------------------------

(defun etaf-reader-store-open (&optional file)
  "Open (or reopen) the store for FILE and return it.
FILE defaults to `etaf-reader-store-file'."
  (let* ((file (expand-file-name (or file etaf-reader-store-file)))
         (current (plist-get etaf-reader--store :file)))
    (unless (and etaf-reader--store (equal current file))
      (when etaf-reader--store (etaf-reader-store-close))
      (condition-case error
          (setq etaf-reader--store (etaf-reader--build-store file))
        ((error quit)
         (signal 'etaf-reader-error
                 (list (format "无法打开书库数据库 %s: %s" file error))))))
    etaf-reader--store))

(defun etaf-reader--build-store (file)
  "Create the controllers for FILE and return the store plist."
  (let ((store (list :file file)))
    (dolist (entry etaf-reader--table-builders)
      (let* ((keyword (car entry))
             (database (etaf-sqlite-database file (funcall (cdr entry)))))
        (etaf-sqlite-initialize database)
        (setq store (plist-put store keyword
                               (etaf-data-controller
                                (etaf-sqlite-source database)
                                :page-size 10000 :auto-load nil
                                :name (intern (format "etaf-reader-%s" keyword)))))))
    store))

(defun etaf-reader-store-close ()
  "Stop every controller of the open store."
  (when etaf-reader--store
    (dolist (entry etaf-reader--table-builders)
      (when-let* ((controller (plist-get etaf-reader--store (car entry))))
        (ignore-errors (etaf-data-stop controller))))
    (setq etaf-reader--store nil)))

(defun etaf-reader--controller (table)
  "Return TABLE's controller, opening the store on first use."
  (plist-get (etaf-reader-store-open) table))

;;; ---------------------------------------------------------------------------
;;; Reads and writes
;;; ---------------------------------------------------------------------------

(defun etaf-reader--rows (table query)
  "Return every row of TABLE matching equality QUERY."
  (let ((controller (etaf-reader--controller table)))
    (etaf-data-set-query controller query)
    (etaf-data-set-page controller 1)
    (etaf-data-load controller)
    (append (etaf-value (etaf-data-items controller)) nil)))

(defun etaf-reader--put (table operation row)
  "Apply OPERATION with ROW to TABLE and return the mutation result."
  (etaf-data-mutate (etaf-reader--controller table) operation row))

(defun etaf-reader--remove (table identity)
  "Delete the row of TABLE identified by IDENTITY."
  (etaf-data-mutate (etaf-reader--controller table) 'delete identity))

;;; ---------------------------------------------------------------------------
;;; Books
;;; ---------------------------------------------------------------------------

(defun etaf-reader-store-books ()
  "Return every stored book, most recently opened first."
  (sort (etaf-reader--rows 'books nil)
        (lambda (left right)
          (> (or (plist-get left :opened) 0)
             (or (plist-get right :opened) 0)))))

(defun etaf-reader-store-book (id)
  "Return the book row with ID, or nil."
  (car (etaf-reader--rows 'books (list :id id))))

(defun etaf-reader-store-put-book (row)
  "Insert or update book ROW."
  (etaf-reader--put 'books 'upsert row))

;;; ---------------------------------------------------------------------------
;;; Chapters and contents
;;; ---------------------------------------------------------------------------

(defun etaf-reader-store-chapters (book)
  "Return BOOK's chapter rows ordered by index."
  (sort (etaf-reader--rows 'chapters (list :book book))
        (lambda (left right)
          (< (or (plist-get left :idx) 0) (or (plist-get right :idx) 0)))))

(defun etaf-reader-store-chapter-count (book)
  "Return how many chapters BOOK has in the store."
  (length (etaf-reader-store-chapters book)))

(defun etaf-reader-store-put-chapters (rows)
  "Insert or update chapter metadata ROWS in one batch.
One source batch and one Controller reconciliation replace a write per
chapter, so importing a long book stays linear.  An empty ROWS list writes
nothing, so a book whose parser found no chapter still imports."
  (when-let* ((operations (mapcar (lambda (row) (list 'upsert row)) rows)))
    (etaf-data-mutate-many (etaf-reader--controller 'chapters) operations)))

(defun etaf-reader-store-content (chapter-id)
  "Return the content row of CHAPTER-ID, or nil."
  (car (etaf-reader--rows 'contents (list :id chapter-id))))

(defun etaf-reader-store-put-contents (rows)
  "Insert or update chapter content ROWS in one batch.
An empty ROWS list writes nothing, so a book whose parser found no chapter
still imports."
  (when-let* ((operations (mapcar (lambda (row) (list 'upsert row)) rows)))
    (etaf-data-mutate-many (etaf-reader--controller 'contents) operations)))

;;; ---------------------------------------------------------------------------
;;; Annotations
;;; ---------------------------------------------------------------------------

(defun etaf-reader-store-annotations (book &optional chapter)
  "Return BOOK's annotations, optionally restricted to CHAPTER."
  (let ((query (if chapter (list :book book :chapter chapter)
                 (list :book book))))
    (sort (etaf-reader--rows 'annotations query)
          (lambda (left right)
            (let ((left-key (list (or (plist-get left :chapter) 0)
                                  (or (plist-get left :start) 0)))
                  (right-key (list (or (plist-get right :chapter) 0)
                                   (or (plist-get right :start) 0))))
              (string-lessp (format "%S" left-key) (format "%S" right-key)))))))

(defun etaf-reader-store-put-annotation (row)
  "Insert or update annotation ROW."
  (etaf-reader--put 'annotations 'upsert row))

(defun etaf-reader-store-delete-annotation (id)
  "Delete the annotation with ID."
  (etaf-reader--remove 'annotations (list :id id)))

;;; ---------------------------------------------------------------------------
;;; Reading state and bookmarks
;;; ---------------------------------------------------------------------------

(defun etaf-reader-store-states ()
  "Return every reading state row."
  (etaf-reader--rows 'states nil))

(defun etaf-reader-store-state (book)
  "Return BOOK's reading state row, or nil."
  (car (etaf-reader--rows 'states (list :book book))))

(defun etaf-reader-store-put-state (row)
  "Insert or update reading state ROW."
  (etaf-reader--put 'states 'upsert row))

(defun etaf-reader-store-bookmarks (book)
  "Return BOOK's bookmarks ordered by position."
  (sort (etaf-reader--rows 'bookmarks (list :book book))
        (lambda (left right)
          (< (+ (* (or (plist-get left :chapter) 0) 100000000)
                (or (plist-get left :offset) 0))
             (+ (* (or (plist-get right :chapter) 0) 100000000)
                (or (plist-get right :offset) 0))))))

(defun etaf-reader-store-put-bookmark (row)
  "Insert or update bookmark ROW."
  (etaf-reader--put 'bookmarks 'upsert row))

(defun etaf-reader-store-delete-bookmark (id)
  "Delete the bookmark with ID."
  (etaf-reader--remove 'bookmarks (list :id id)))

(provide 'etaf-reader-store)
;;; etaf-reader-store.el ends here
