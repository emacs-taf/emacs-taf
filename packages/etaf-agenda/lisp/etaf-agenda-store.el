;;; etaf-agenda-store.el --- SQLite storage of etaf-agenda -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; One SQLite file, five tables, one ETAF Data Source per table.  Reads go
;; through `etaf-data-source-load-page' and writes go through atomic
;; `:mutate-batch'.  To preserve cross-month habits, weekly counts and calendar
;; overflow days without dropping records on the 1st of a month, loading a
;; month fetches the adjacent previous and next YYYYMM buckets as well.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-db)

(defcustom etaf-agenda-database-file
  (locate-user-emacs-file "etaf-agenda/agenda.sqlite3")
  "SQLite file holding the agenda."
  :type 'file
  :group 'etaf-agenda)

;;; ---------------------------------------------------------------------------
;;; Schema
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--entries-table ()
  "Return the `entries' table metadata."
  (etaf-sqlite-table
   'entries
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :kind "kind" :type 'text)
         (etaf-sqlite-column :status "status" :type 'text)
         (etaf-sqlite-column :title "title" :type 'text :nullable t)
         (etaf-sqlite-column :body "body" :type 'text :nullable t)
         (etaf-sqlite-column :priority "priority" :type 'integer :nullable t)
         (etaf-sqlite-column :scheduled "scheduled" :type 'integer :nullable t)
         (etaf-sqlite-column :at "at" :type 'integer :nullable t)
         (etaf-sqlite-column :end_at "end_at" :type 'integer :nullable t)
         (etaf-sqlite-column :deadline "deadline" :type 'integer :nullable t)
         (etaf-sqlite-column :estimate "estimate" :type 'integer :nullable t)
         (etaf-sqlite-column :recurrence "recurrence" :type 'text :nullable t)
         (etaf-sqlite-column :area "area" :type 'text :nullable t)
         (etaf-sqlite-column :project "project" :type 'text :nullable t)
         (etaf-sqlite-column :stage "stage" :type 'text :nullable t)
         (etaf-sqlite-column :milestone "milestone" :type 'integer :nullable t)
         (etaf-sqlite-column :deleted "deleted" :type 'integer :nullable t)
         (etaf-sqlite-column :habit_target "habit_target" :type 'integer :nullable t)
         (etaf-sqlite-column :habit_period "habit_period" :type 'text :nullable t)
         (etaf-sqlite-column :habit_measure "habit_measure" :type 'text :nullable t)
         (etaf-sqlite-column :ref "ref" :type 'text :nullable t)
         (etaf-sqlite-column :container "container" :type 'text :nullable t)
         (etaf-sqlite-column :tags "tags" :type 'text :nullable t)
         (etaf-sqlite-column :created "created" :type 'integer :nullable t)
         (etaf-sqlite-column :updated "updated" :type 'integer :nullable t))
   :id))

(defun etaf-agenda--instances-table ()
  "Return the `instances' table metadata."
  (etaf-sqlite-table
   'instances
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :entry "entry" :type 'text)
         (etaf-sqlite-column :day "day" :type 'integer)
         (etaf-sqlite-column :bucket "bucket" :type 'integer)
         (etaf-sqlite-column :state "state" :type 'text)
         (etaf-sqlite-column :value "value" :type 'integer :nullable t)
         (etaf-sqlite-column :at "at" :type 'integer :nullable t))
   :id))

(defun etaf-agenda--logs-table ()
  "Return the `logs' table metadata."
  (etaf-sqlite-table
   'logs
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :entry "entry" :type 'text)
         (etaf-sqlite-column :day "day" :type 'integer :nullable t)
         (etaf-sqlite-column :at "at" :type 'integer :nullable t)
         (etaf-sqlite-column :event "event" :type 'text)
         (etaf-sqlite-column :note "note" :type 'text :nullable t))
   :id))

(defun etaf-agenda--containers-table ()
  "Return the `containers' table metadata."
  (etaf-sqlite-table
   'containers
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :name "name" :type 'text)
         (etaf-sqlite-column :kind "kind" :type 'text :nullable t)
         (etaf-sqlite-column :parent "parent" :type 'text :nullable t)
         (etaf-sqlite-column :goal "goal" :type 'text :nullable t)
         (etaf-sqlite-column :start "start" :type 'integer :nullable t)
         (etaf-sqlite-column :due "due" :type 'integer :nullable t)
         (etaf-sqlite-column :status "status" :type 'text :nullable t)
         (etaf-sqlite-column :deleted "deleted" :type 'integer :nullable t)
         (etaf-sqlite-column :sort "sort" :type 'integer :nullable t))
   :id))

(defun etaf-agenda--meta-table ()
  "Return the `meta' table metadata: schema version and workspace settings."
  (etaf-sqlite-table
   'meta
   (list (etaf-sqlite-column :key "key" :type 'text :primary t)
         (etaf-sqlite-column :value "value" :type 'text :nullable t))
   :key))

(defconst etaf-agenda--tables
  '((entries . etaf-agenda--entries-table)
    (instances . etaf-agenda--instances-table)
    (logs . etaf-agenda--logs-table)
    (containers . etaf-agenda--containers-table)
    (meta . etaf-agenda--meta-table))
  "Table symbol and its descriptor function.")

;;; ---------------------------------------------------------------------------
;;; Schema version and migration
;;; ---------------------------------------------------------------------------

(defconst etaf-agenda-schema-version 2
  "Schema version this build writes.")

(defun etaf-agenda--store-meta-get (store key)
  "Return string value for KEY in STORE's `meta' table, or nil."
  (let* ((page (etaf-agenda--store-page store 'meta (list :key key)))
         (row (car (plist-get page :items))))
    (plist-get row :value)))

(defun etaf-agenda--store-meta-set (store key value)
  "Persist KEY -> VALUE (string) in STORE's `meta' table."
  (etaf-agenda--store-apply
   store 'meta
   (list (list 'upsert (list :key key :value value)))))

(defun etaf-agenda--store-schema (store)
  "Return STORE's recorded schema version as an integer, or nil."
  (when-let* ((value (etaf-agenda--store-meta-get store "schema")))
    (string-to-number value)))

(defun etaf-agenda--store-set-schema (store version)
  "Record VERSION as STORE's schema version."
  (etaf-agenda--store-meta-set store "schema" (number-to-string version)))

(defun etaf-agenda--store-containers-by-id (store)
  "Return STORE's containers indexed by id."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (row (plist-get (etaf-agenda--store-page store 'containers) :items) table)
      (puthash (plist-get row :id) row table))))

(defun etaf-agenda--migrate-1-to-2 (store)
  "Move STORE's single `container' column into area, project and stage."
  (let ((containers (etaf-agenda--store-containers-by-id store))
        (updates nil))
    (dolist (entry (plist-get (etaf-agenda--store-page store 'entries) :items))
      (let ((container (plist-get entry :container)))
        (when container
          (let* ((row (gethash container containers))
                 (kind (plist-get row :kind))
                 (parent (plist-get row :parent))
                 (project-parent (gethash parent containers))
                 (entry (plist-put (copy-sequence entry) :container nil))
                 (entry (plist-put entry :stage (and (equal kind "stage") container)))
                 (entry (plist-put entry :project
                                   (pcase kind
                                     ("project" container)
                                     ("stage" parent)
                                     (_ (plist-get entry :project)))))
                 (entry (plist-put entry :area
                                   (pcase kind
                                     ("area" container)
                                     ("project" parent)
                                     ("stage" (plist-get project-parent :parent))
                                     (_ (plist-get entry :area))))))
            (push (list 'replace entry) updates)))))
    (when updates
      (etaf-agenda--store-apply store 'entries (nreverse updates)))))

(defconst etaf-agenda--migrations
  '((1 . etaf-agenda--migrate-1-to-2))
  "Migration from version KEY to the next one.")

(defun etaf-agenda--store-migrate (store)
  "Bring STORE to `etaf-agenda-schema-version'."
  (condition-case error
      (let ((version (or (etaf-agenda--store-schema store) 1)))
        (cond
         ((> version etaf-agenda-schema-version) 'read-only)
         ((= version etaf-agenda-schema-version) 'ok)
         (t
          (while (< version etaf-agenda-schema-version)
            (let ((step (cdr (assq version etaf-agenda--migrations))))
              (unless step
                (error "No migration from schema %d" version))
              (funcall step store)
              (setq version (1+ version))
              (etaf-agenda--store-set-schema store version)))
          'ok)))
    (error error)))

;;; ---------------------------------------------------------------------------
;;; Lifecycle
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--store-source (file table)
  "Return a Data Source over FILE for TABLE, creating the table if needed."
  (let ((database (etaf-sqlite-database file (funcall table))))
    (etaf-sqlite-initialize database)
    (etaf-sqlite-source database)))

(defun etaf-agenda--store-open (&optional file)
  "Open the store at FILE and return it."
  (let* ((file (or file etaf-agenda-database-file))
         (dir (file-name-directory file)))
    (when dir (make-directory dir t))
    (let* ((store (list :file file
                        :sources (mapcar (lambda (entry)
                                           (cons (car entry)
                                                 (etaf-agenda--store-source
                                                  file (cdr entry))))
                                         etaf-agenda--tables)))
           (status (etaf-agenda--store-migrate store)))
      (plist-put store :schema status))))

(defun etaf-agenda--store-close (store)
  "Release STORE.  Sources hold no connection between calls."
  (ignore store)
  nil)

(defun etaf-agenda--store-source-of (store table)
  "Return STORE's source for TABLE."
  (or (cdr (assq table (plist-get store :sources)))
      (error "No source for table %S" table)))

;;; ---------------------------------------------------------------------------
;;; Reads
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--store-page (store table &optional query)
  "Return every row of TABLE matching QUERY."
  (etaf-data-source-load-page (etaf-agenda--store-source-of store table)
                              query 1 20000))

(defun etaf-agenda--ymd-bucket (ymd)
  "Return the YYYYMM bucket of YMD, an integer YYYYMMDD."
  (/ ymd 100))

(defun etaf-agenda--shift-bucket (bucket delta)
  "Return YYYYMM BUCKET shifted by DELTA months."
  (let* ((year (/ bucket 100))
         (month (% bucket 100))
         (total (+ (* year 12) (1- month) delta)))
    (+ (* (/ total 12) 100) (1+ (mod total 12)))))

(defun etaf-agenda--store-load (store month-ymd &optional full-year today-ymd)
  "Return the working set around MONTH-YMD as a plist.
Loads instances for the previous, current and next month buckets around
MONTH-YMD, plus the current and previous buckets around TODAY-YMD (so the
21-day habit strip always stays complete regardless of the navigated date).
When FULL-YEAR is non-nil, loads all 12 month buckets of MONTH-YMD's year."
  (let* ((bucket (etaf-agenda--ymd-bucket month-ymd))
         (year (/ month-ymd 10000))
         (t-bucket (when today-ymd (etaf-agenda--ymd-bucket today-ymd)))
         (buckets (delete-dups
                   (delq nil
                         (append
                          (list (etaf-agenda--shift-bucket bucket -1)
                                bucket
                                (etaf-agenda--shift-bucket bucket 1))
                          (when t-bucket
                            (list (etaf-agenda--shift-bucket t-bucket -1)
                                  t-bucket))
                          (when full-year
                            (cl-loop for m from 1 to 12
                                     collect (+ (* year 100) m)))))))
         (instances (apply #'append
                           (mapcar (lambda (b)
                                     (plist-get (etaf-agenda--store-page
                                                 store 'instances (list :bucket b))
                                                :items))
                                   buckets)))
         (entries (etaf-agenda--store-page store 'entries nil))
         (containers (etaf-agenda--store-page store 'containers nil)))
    (list :entries (plist-get entries :items)
          :instances instances
          :containers (plist-get containers :items))))

(defun etaf-agenda--store-logs-for-entry (store entry-id)
  "Return recent log rows for ENTRY-ID in STORE, newest first."
  (let ((items (plist-get (etaf-agenda--store-page
                           store 'logs (list :entry entry-id))
                          :items)))
    (sort (copy-sequence items)
          (lambda (a b)
            (> (or (plist-get a :at) 0)
               (or (plist-get b :at) 0))))))

;;; ---------------------------------------------------------------------------
;;; Writes
;;; ---------------------------------------------------------------------------

(defun etaf-agenda--store-apply (store table operations)
  "Apply OPERATIONS, a list of (OPERATION PAYLOAD), to TABLE atomically."
  (when operations
    (let* ((source (etaf-agenda--store-source-of store table))
           (batch (plist-get (etaf-data-source-capabilities source) :mutate-batch)))
      (unless batch
        (error "The %S source has no atomic batch capability" table))
      (funcall batch operations))))

(provide 'etaf-agenda-store)
;;; etaf-agenda-store.el ends here
