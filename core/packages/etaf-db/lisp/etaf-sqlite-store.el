;;; etaf-sqlite-store.el --- SQLite Data source for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; URL: https://github.com/emacs-taf/etaf-db

;;; Commentary:

;; SQLite backend implementation for `etaf-db'.  It adapts Emacs' built-in
;; SQLite API to the `etaf-data-source' capability contract owned by ETAF.
;; Backend operations own SQL, schema validation and short-lived connections;
;; reactive state and Data Controller lifecycle remain in ETAF core.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sqlite)
(require 'etaf)

(define-error 'etaf-sqlite-error "Invalid ETAF SQLite operation")
(define-error 'etaf-sqlite-schema-error "Invalid ETAF SQLite schema"
  'etaf-sqlite-error)
(define-error 'etaf-sqlite-unavailable "SQLite is unavailable"
  'etaf-sqlite-error)
(define-error 'etaf-sqlite-commit-unknown
  "SQLite commit outcome is unknown"
  'etaf-sqlite-error)

;; Opaque tokens let Data reconcile a committed external mutation without
;; coupling itself to SQLite connection or transaction objects.
(defvar etaf-sqlite--reconciliation-sequence 0)
(defvar etaf-sqlite--mutation-active nil)
(defvar etaf-sqlite--mutation-phase nil)

(defun etaf-sqlite--reconciliation-token ()
  "Return a fresh opaque token for one SQLite mutation outcome."
  (list :etaf-sqlite (cl-incf etaf-sqlite--reconciliation-sequence)))

(cl-defstruct (etaf-sqlite--column
               (:constructor etaf-sqlite--column-create))
  id sql-name type nullable primary)

(cl-defstruct (etaf-sqlite--table
               (:constructor etaf-sqlite--table-create))
  id columns primary-key index)

(cl-defstruct (etaf-sqlite--database
               (:constructor etaf-sqlite--database-create))
  file table)

(defconst etaf-sqlite--types
  '(integer real text blob any)
  "Supported SQLite declaration types.")

(defun etaf-sqlite--identifier-p (value)
  "Return non-nil when VALUE is a safe unquoted SQL identifier."
  (and (stringp value)
       (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" value)))

(defun etaf-sqlite--identifier (value kind)
  "Return quoted SQL identifier VALUE for KIND or signal an error."
  (unless (etaf-sqlite--identifier-p value)
    (signal 'etaf-sqlite-schema-error
            (list (format "Unsafe SQLite %s identifier: %S" kind value))))
  (format "\"%s\"" value))

(defun etaf-sqlite--physical-name (value kind)
  "Return the SQL name for semantic VALUE of KIND."
  (etaf-sqlite--identifier
   (cond
    ((stringp value) value)
    ((symbolp value) (symbol-name value))
    (t (signal 'etaf-sqlite-schema-error
              (list (format "SQLite %s must be a symbol or string: %S"
                            kind value)))))
   kind))

(defun etaf-sqlite--scalar-id-p (value)
  "Return non-nil when VALUE can identify a schema field."
  (and value (or (symbolp value) (stringp value) (integerp value))))

;;;###autoload
(cl-defun etaf-sqlite-column
    (id sql-name &key (type 'any) nullable primary)
  "Declare a SQLite column with semantic ID and physical SQL-NAME.

TYPE is one of `integer', `real', `text', `blob', or `any'.  NULLABLE allows
SQL NULL values.  PRIMARY marks the column as the table's identity; pass its
semantic ID as the table's PRIMARY-KEY so the source knows it.  SQL-NAME is
validated once and never comes from a runtime query."
  (unless (etaf-sqlite--scalar-id-p id)
    (signal 'etaf-sqlite-schema-error
            (list (format "Column ID must be a stable scalar: %S" id))))
  (unless (etaf-sqlite--identifier-p sql-name)
    (signal 'etaf-sqlite-schema-error
            (list (format "Invalid SQLite column name: %S" sql-name))))
  (unless (memq type etaf-sqlite--types)
    (signal 'etaf-sqlite-schema-error
            (list (format "Unsupported SQLite column type: %S" type))))
  (etaf-sqlite--column-create
   :id id :sql-name sql-name :type type
   :nullable (and nullable t) :primary (and primary t)))

(defun etaf-sqlite--column-index (columns)
  "Return an equal-tested index for COLUMNS."
  (unless (and (proper-list-p columns) columns)
    (signal 'etaf-sqlite-schema-error
            (list "SQLite table requires at least one column")))
  (let ((index (make-hash-table :test #'equal))
        (names (make-hash-table :test #'equal)))
    (dolist (column columns index)
      (unless (etaf-sqlite--column-p column)
        (signal 'etaf-sqlite-schema-error (list "Invalid SQLite column")))
      (when (gethash (etaf-sqlite--column-id column) index)
        (signal 'etaf-sqlite-schema-error
                (list "Duplicate SQLite semantic column ID")))
      (let ((name (downcase (etaf-sqlite--column-sql-name column))))
        (when (gethash name names)
          (signal 'etaf-sqlite-schema-error
                  (list "Duplicate SQLite physical column name")))
        (puthash name t names))
      (puthash (etaf-sqlite--column-id column) column index))))

;;;###autoload
(defun etaf-sqlite-table (id columns &optional primary-key)
  "Declare table ID from COLUMNS and optional PRIMARY-KEY semantic ID.
Without it the table has no identity, and the mutations that need one are
rejected."
  (unless (or (symbolp id) (stringp id))
    (signal 'etaf-sqlite-schema-error
            (list (format "Table ID must be a stable scalar: %S" id))))
  (let* ((columns (copy-sequence columns))
         (index (etaf-sqlite--column-index columns))
         (primary (and primary-key (gethash primary-key index))))
    (when (and primary-key (not primary))
      (signal 'etaf-sqlite-schema-error
              (list (format "Unknown primary column: %S" primary-key))))
    (when primary
      (setf (etaf-sqlite--column-primary primary) t
            (etaf-sqlite--column-nullable primary) nil))
    (etaf-sqlite--table-create :id id :columns columns
                                :primary-key primary-key :index index)))

;;;###autoload
(defun etaf-sqlite-database (file table)
  "Describe SQLite FILE using typed TABLE metadata."
  (unless (and (stringp file) (not (string-empty-p file)))
    (signal 'etaf-sqlite-schema-error (list "SQLite file must be nonempty")))
  (unless (etaf-sqlite--table-p table)
    (signal 'etaf-sqlite-schema-error (list "SQLite database needs a table")))
  (etaf-sqlite--database-create :file (expand-file-name file) :table table))

(defun etaf-sqlite--require-available ()
  "Signal when the running Emacs has no SQLite support."
  (unless (sqlite-available-p)
    (signal 'etaf-sqlite-unavailable nil)))

(defun etaf-sqlite--call (database function)
  "Call FUNCTION with a short-lived connection for DATABASE.

Keep a cleanup failure after a successful mutation conservative: the write may
already have committed even though closing the connection signalled.  When the
body already failed, preserve that primary condition so transaction certainty
is determined by the transaction phase rather than by cleanup noise."
  (etaf-sqlite--require-available)
  (let* ((file (etaf-sqlite--database-file database))
         (directory (file-name-directory file))
         connection)
    (when directory
      (make-directory directory t))
    (setq connection (sqlite-open file))
    (let (result body-condition close-condition)
      ;; Keep the connection cleanup on all non-local exits, including a
      ;; caller's `throw'.  Error and quit conditions are captured so cleanup
      ;; failures can be classified without masking the primary condition.
      (unwind-protect
          (condition-case err
              (setq result (funcall function connection))
            ((error quit)
             (setq body-condition err)))
        (when (sqlitep connection)
          (condition-case err
              (sqlite-close connection)
            ((error quit)
             (setq close-condition err))))
        )
      (when (and close-condition
                 etaf-sqlite--mutation-active
                 (memq etaf-sqlite--mutation-phase '(committed committing))
                 (not (and body-condition
                           (eq (car body-condition)
                               'etaf-sqlite-commit-unknown))))
        (setq body-condition
              (list 'etaf-sqlite-commit-unknown
                    (list :failure-phase 'close :error close-condition))))
      (when (and close-condition (not body-condition))
        (setq body-condition close-condition))
      (if body-condition
          (signal (car body-condition) (cdr body-condition))
        result))))

(defun etaf-sqlite--transaction (connection function)
  "Run FUNCTION in a transaction on CONNECTION and return its value."
  (sqlite-transaction connection)
  (let ((value
         (condition-case body-err
             (funcall function connection)
           ((error quit)
            (setq etaf-sqlite--mutation-phase 'rolling-back)
            (let ((rollback-err
                   (condition-case rollback-condition
                       (progn (sqlite-rollback connection) nil)
                     ((error quit) rollback-condition))))
              (if rollback-err
                  (progn
                    (setq etaf-sqlite--mutation-phase 'unknown)
                    (signal 'etaf-sqlite-commit-unknown
                            (list :failure-phase 'rollback
                                  :error body-err
                                  :rollback-error rollback-err)))
                (setq etaf-sqlite--mutation-phase 'rolled-back)
                (signal (car body-err) (cdr body-err))))))))
    (condition-case commit-err
        (progn
          (setq etaf-sqlite--mutation-phase 'committing)
          (sqlite-commit connection)
          (setq etaf-sqlite--mutation-phase 'committed)
          value)
      ((error quit)
       (setq etaf-sqlite--mutation-phase 'unknown)
       (signal 'etaf-sqlite-commit-unknown
               (list :failure-phase 'commit :error commit-err))))))

(defun etaf-sqlite--sql-type (type)
  "Return SQLite DDL type for TYPE."
  (pcase type
    ('integer "INTEGER")
    ('real "REAL")
    ('text "TEXT")
    ('blob "BLOB")
    (_ "BLOB")))

(defun etaf-sqlite--column-ddl (column)
  "Return DDL for COLUMN."
  (concat (etaf-sqlite--identifier
           (etaf-sqlite--column-sql-name column) "column")
          " " (etaf-sqlite--sql-type
                (etaf-sqlite--column-type column))
          (when (etaf-sqlite--column-primary column) " PRIMARY KEY")
          (unless (or (etaf-sqlite--column-nullable column)
                      (etaf-sqlite--column-primary column))
            " NOT NULL")))

(defun etaf-sqlite--existing-columns (connection table)
  "Return an equal-tested set of TABLE's existing physical column names."
  (let ((table-name (etaf-sqlite--physical-name
                     (etaf-sqlite--table-id table) "table"))
        (names (make-hash-table :test #'equal)))
    (dolist (row (sqlite-select connection
                                (format "PRAGMA table_info(%s)" table-name)))
      (puthash (downcase (nth 1 row)) t names))
    names))

(defun etaf-sqlite--reconcile-columns (connection table)
  "Add TABLE's missing nullable columns to CONNECTION.

A database created by an earlier release may lack a column the descriptor has
since gained.  A missing nullable column is added in place, so every existing
row reads back with SQL NULL.  A missing primary or declared non-nullable
column cannot be added safely; it signals `etaf-sqlite-schema-error' so the
application migrates deliberately instead of running against a half-matching
table."
  (let ((existing (etaf-sqlite--existing-columns connection table))
        (table-name (etaf-sqlite--physical-name
                     (etaf-sqlite--table-id table) "table")))
    (dolist (column (etaf-sqlite--table-columns table))
      (let ((name (downcase (etaf-sqlite--column-sql-name column))))
        (unless (gethash name existing)
          (cond
           ((etaf-sqlite--column-primary column)
            (signal 'etaf-sqlite-schema-error
                    (list (format "Existing table %s lacks its primary column %s"
                                  table-name
                                  (etaf-sqlite--column-sql-name column)))))
           ((etaf-sqlite--column-nullable column)
            (sqlite-execute
             connection
             (format "ALTER TABLE %s ADD COLUMN %s %s"
                     table-name
                     (etaf-sqlite--identifier
                      (etaf-sqlite--column-sql-name column) "column")
                     (etaf-sqlite--sql-type
                      (etaf-sqlite--column-type column)))))
           (t
            (signal 'etaf-sqlite-schema-error
                    (list (format "Existing table %s lacks non-nullable column %s; declare it :nullable t to migrate in place"
                                  table-name
                                  (etaf-sqlite--column-sql-name column)))))))))))

;;;###autoload
(defun etaf-sqlite-initialize (database)
  "Create DATABASE's table if it does not exist and return DATABASE.

When the table already exists, columns the descriptor has gained are added in
place as long as they are nullable; a missing primary or declared non-nullable
column signals `etaf-sqlite-schema-error' instead of leaving a half-matching
table behind."
  (etaf-sqlite--call
   database
   (lambda (connection)
     (let ((table (etaf-sqlite--database-table database)))
       (sqlite-execute
        connection
        (format "CREATE TABLE IF NOT EXISTS %s (%s)"
                (etaf-sqlite--physical-name
                 (etaf-sqlite--table-id table) "table")
                (mapconcat #'etaf-sqlite--column-ddl
                           (etaf-sqlite--table-columns table) ", ")))
       (etaf-sqlite--reconcile-columns connection table))))
  database)

(defun etaf-sqlite--record-value (record key)
  "Return KEY from plist, alist, or hash RECORD."
  (cond
   ((hash-table-p record) (gethash key record))
   ((and (proper-list-p record) (keywordp (car record)))
    (plist-get record key))
   ((listp record) (alist-get key record))
   (t nil)))

(defun etaf-sqlite--query-pairs (table query)
  "Return allowlisted (COLUMN . VALUE) pairs from QUERY using TABLE."
  (cond
   ((null query) nil)
   ((and (proper-list-p query) (keywordp (car query)))
    (cl-loop for (key value) on query by #'cddr
             collect (cons (gethash key (etaf-sqlite--table-index table)) value)))
   ((listp query)
    (cl-loop for (key . value) in query
             collect (cons (gethash key (etaf-sqlite--table-index table)) value)))
   (t
    (signal 'etaf-sqlite-error
            (list "SQLite query must be a plist or alist")))))

(defun etaf-sqlite--where (table query)
  "Return (SQL . VALUES) for allowlisted equality QUERY using TABLE."
  (let (parts values)
    (dolist (pair (etaf-sqlite--query-pairs table query))
      (unless (car pair)
        (signal 'etaf-sqlite-error (list "Unknown SQLite query column")))
      (push (format "%s = ?"
                    (etaf-sqlite--identifier
                     (etaf-sqlite--column-sql-name (car pair)) "column")
                    ) parts)
      (push (cdr pair) values))
    (cons (if parts (concat " WHERE " (string-join (nreverse parts) " AND ")) "")
          (nreverse values))))

(defun etaf-sqlite--row-plist (table row)
  "Convert positional SQLite ROW to a semantic plist using TABLE."
  (let (result)
    (cl-loop for column in (etaf-sqlite--table-columns table)
             for value in row
             do (setq result
                      (append result
                              (list (etaf-sqlite--column-id column) value))))
    result))

(defun etaf-sqlite--select-items (database query page page-size)
  "Load PAGE of PAGE-SIZE items from DATABASE for QUERY."
  (let* ((table (etaf-sqlite--database-table database))
         (where (etaf-sqlite--where table query))
         (values (cdr where))
         (page (max 1 (or page 1)))
         (page-size (max 1 (or page-size 20)))
         (offset (* (1- page) page-size))
         (names (mapcar (lambda (column)
                          (etaf-sqlite--identifier
                           (etaf-sqlite--column-sql-name column) "column"))
                        (etaf-sqlite--table-columns table)))
         (table-name (etaf-sqlite--physical-name
                      (etaf-sqlite--table-id table) "table"))
         (order (when-let* ((primary (etaf-sqlite--table-primary-key table)))
                  (format " ORDER BY %s"
                          (etaf-sqlite--identifier
                           (etaf-sqlite--column-sql-name
                            (gethash primary (etaf-sqlite--table-index table)))
                           "column")))))
    (etaf-sqlite--call
     database
     (lambda (connection)
       (let ((total (sqlite-select
                     connection
                     (format "SELECT COUNT(*) FROM %s%s" table-name
                             (car where))
                     values)))
         (let ((rows (sqlite-select
                      connection
                      (format "SELECT %s FROM %s%s%s LIMIT ? OFFSET ?"
                              (string-join names ", ") table-name (car where)
                              (or order ""))
                      (append values (list page-size offset)))))
           (list :items (mapcar (lambda (row)
                                  (etaf-sqlite--row-plist table row)) rows)
                 :total (caar total)
                 :page page :page-size page-size)))))))

(defun etaf-sqlite--payload-columns (table payload)
  "Return (COLUMN . VALUE) pairs from writable PAYLOAD fields using TABLE."
  (let (result)
    (dolist (column (etaf-sqlite--table-columns table) (nreverse result))
      (let ((key (etaf-sqlite--column-id column)))
        (when (and (not (etaf-sqlite--column-primary column))
                   (or (plist-member payload key)
                       (and (listp payload) (assoc key payload))))
          (push (cons column (etaf-sqlite--record-value payload key)) result))))))

(defun etaf-sqlite--mutation-result (connection operation value &optional id)
  "Return a normalized mutation result for OPERATION and VALUE from CONNECTION.

ID is the primary-key value of an upsert, whose INSERT ... ON CONFLICT may
have updated an existing row instead of inserting one.  The result keeps
source-specific details behind the Data contract while exposing the inserted
identity and affected row count to application code."
  (list :operation operation
        :id (or id
                (when (eq operation 'insert)
                  (caar (sqlite-select connection "SELECT last_insert_rowid()"))))
        :changes (caar (sqlite-select connection "SELECT changes()"))
        :value value))

(defun etaf-sqlite--require-primary (table)
  "Signal `etaf-sqlite-schema-error' unless TABLE declares a primary key."
  (unless (etaf-sqlite--table-primary-key table)
    (signal 'etaf-sqlite-schema-error
            (list "Mutations require a primary key"))))

(defun etaf-sqlite--apply-mutation
    (transaction-connection table operation payload)
  "Apply one OPERATION with PAYLOAD to TABLE and return its mutation result.

TRANSACTION-CONNECTION is open and already inside the caller's transaction;
TABLE must declare a primary key."
  (let ((table-name (etaf-sqlite--physical-name
                     (etaf-sqlite--table-id table) "table"))
        (primary (etaf-sqlite--table-primary-key table)))
    (let ((value
           (pcase operation
            ('insert
             (let* ((columns
                     (cl-remove-if
                      (lambda (column)
                        (null
                         (or (plist-member payload
                                            (etaf-sqlite--column-id column))
                             (and (listp payload)
                                  (assoc (etaf-sqlite--column-id column)
                                         payload)))))
                      (etaf-sqlite--table-columns table)))
                    (names
                     (mapcar
                      (lambda (column)
                        (etaf-sqlite--identifier
                         (etaf-sqlite--column-sql-name column) "column"))
                      columns))
                    (marks (make-list (length columns) "?")))
               (unless columns
                 (signal 'etaf-sqlite-error
                         (list "Insert payload is empty")))
               (sqlite-execute
                transaction-connection
                (format "INSERT INTO %s (%s) VALUES (%s)"
                        table-name (string-join names ", ")
                        (string-join marks ", "))
                (mapcar
                 (lambda (column)
                   (etaf-sqlite--record-value
                    payload (etaf-sqlite--column-id column)))
                 columns))))
            ((or 'replace 'update)
             (let* ((id (etaf-sqlite--record-value payload primary))
                    (columns (etaf-sqlite--payload-columns table payload)))
               (unless id
                 (signal 'etaf-sqlite-error
                         (list "Update payload lacks primary key")))
               (unless columns
                 (signal 'etaf-sqlite-error
                         (list "Update payload has no fields")))
               (sqlite-execute
                transaction-connection
                (format "UPDATE %s SET %s WHERE %s = ?"
                        table-name
                        (mapconcat
                         (lambda (pair)
                           (format "%s = ?"
                                   (etaf-sqlite--identifier
                                    (etaf-sqlite--column-sql-name (car pair))
                                    "column")))
                         columns ", ")
                        (etaf-sqlite--identifier
                         (etaf-sqlite--column-sql-name
                          (gethash primary (etaf-sqlite--table-index table)))
                         "column"))
                (append (mapcar #'cdr columns) (list id)))
               ;; The memory source signals for a missing identity, so a
               ;; no-op UPDATE must not read as a successful replace here.
               (when (zerop (caar (sqlite-select transaction-connection
                                                 "SELECT changes()")))
                 (signal 'etaf-sqlite-error
                         (list (format "No SQLite row for primary key %S" id))))))
            ('upsert
             (let* ((columns
                     (cl-remove-if
                      (lambda (column)
                        (null
                         (or (plist-member payload
                                            (etaf-sqlite--column-id column))
                             (and (listp payload)
                                  (assoc (etaf-sqlite--column-id column)
                                         payload)))))
                      (etaf-sqlite--table-columns table)))
                    (names
                     (mapcar
                      (lambda (column)
                        (etaf-sqlite--identifier
                         (etaf-sqlite--column-sql-name column) "column"))
                      columns))
                    (marks (make-list (length columns) "?"))
                    (id (etaf-sqlite--record-value payload primary))
                    (updates (cl-remove-if
                              (lambda (column)
                                (etaf-sqlite--column-primary column))
                              columns)))
               (unless id
                 (signal 'etaf-sqlite-error
                         (list "Upsert payload lacks primary key")))
               (unless columns
                 (signal 'etaf-sqlite-error
                         (list "Upsert payload is empty")))
               (sqlite-execute
                transaction-connection
                (format "INSERT INTO %s (%s) VALUES (%s) ON CONFLICT (%s) %s"
                        table-name (string-join names ", ")
                        (string-join marks ", ")
                        (etaf-sqlite--identifier
                         (etaf-sqlite--column-sql-name
                          (gethash primary (etaf-sqlite--table-index table)))
                         "column")
                        (if updates
                            (concat
                             "DO UPDATE SET "
                             (mapconcat
                              (lambda (column)
                                (let ((name (etaf-sqlite--identifier
                                             (etaf-sqlite--column-sql-name column)
                                             "column")))
                                  (format "%s = excluded.%s" name name)))
                              updates ", "))
                          "DO NOTHING"))
                (mapcar
                 (lambda (column)
                   (etaf-sqlite--record-value
                    payload (etaf-sqlite--column-id column)))
                 columns))))
            ('delete
             (let ((id (if (and (listp payload)
                                (or (plist-member payload primary)
                                    (assoc primary payload)))
                           (etaf-sqlite--record-value payload primary)
                         payload)))
               (unless id
                 (signal 'etaf-sqlite-error
                         (list "Delete payload lacks primary key")))
               (sqlite-execute
                transaction-connection
                (format "DELETE FROM %s WHERE %s = ?" table-name
                        (etaf-sqlite--identifier
                         (etaf-sqlite--column-sql-name
                          (gethash primary (etaf-sqlite--table-index table)))
                         "column"))
                (list id))))
            (_
             (signal 'etaf-sqlite-error
                     (list (format "Unsupported SQLite mutation: %S"
                                   operation)))))))
      (etaf-sqlite--mutation-result
       transaction-connection operation value
       (when (eq operation 'upsert)
         (etaf-sqlite--record-value payload primary))))))

(defun etaf-sqlite--mutate (database operation payload)
  "Apply one Data mutation OPERATION with PAYLOAD to DATABASE."
  (let ((table (etaf-sqlite--database-table database)))
    (etaf-sqlite--require-primary table)
    (let ((etaf-sqlite--mutation-active t)
          (etaf-sqlite--mutation-phase 'body))
      (etaf-sqlite--call
       database
       (lambda (connection)
         (etaf-sqlite--transaction
          connection
          (lambda (transaction-connection)
            (etaf-sqlite--apply-mutation
             transaction-connection table operation payload))))))))

(defun etaf-sqlite--mutate-batch (database operations)
  "Apply OPERATIONS to DATABASE in one transaction and return their results.

OPERATIONS is a list of (OPERATION PAYLOAD) pairs.  Every statement commits
together: a signaled operation rolls the whole batch back and is re-signaled,
while an unknown commit outcome signals `etaf-sqlite-commit-unknown'."
  (let ((table (etaf-sqlite--database-table database)))
    (etaf-sqlite--require-primary table)
    (let ((etaf-sqlite--mutation-active t)
          (etaf-sqlite--mutation-phase 'body))
      (etaf-sqlite--call
       database
       (lambda (connection)
         (etaf-sqlite--transaction
          connection
          (lambda (transaction-connection)
            (mapcar (lambda (operation)
                      (etaf-sqlite--apply-mutation
                       transaction-connection table
                       (car operation) (cadr operation)))
                    operations))))))))


(defun etaf-sqlite--mutate-v2 (database operation payload)
  "Return a commit-certified outcome for DATABASE mutation OPERATION and PAYLOAD.

This optional capability deliberately does not replace the v1 `:mutate'
callback.  Successful transactions return `:certainty committed' and a
reconciliation token.  A body failure is `:certainty rolled-back' only when
rollback succeeds; commit, rollback, or close uncertainty is returned as
`:certainty external-unknown' with the original condition in `:error'."
  (let ((token (etaf-sqlite--reconciliation-token)))
    (condition-case err
        (let ((result (etaf-sqlite--mutate database operation payload)))
          (list :certainty 'committed
                :external-commit-certainty 'committed
                :operation operation
                :result result
                :mutation-result result
                :reconciliation-token token))
      ((error quit)
       (list :certainty (if (eq (car err) 'etaf-sqlite-commit-unknown)
                            'external-unknown
                          'rolled-back)
             :external-commit-certainty
             (if (eq (car err) 'etaf-sqlite-commit-unknown)
                 'external-unknown
               'rolled-back)
             :operation operation
             :error err
             :reconciliation-token token)))))

;;;###autoload
(cl-defun etaf-sqlite-source (database &key mutate-v2)
  "Return an `etaf-data-source' backed by DATABASE.

The source accepts equality plist/alist queries and supports `insert',
`replace', `update', `upsert', and `delete' mutations.  `upsert' inserts a row
or updates the existing row with the same primary key, which is the natural
way to make a store match a record; `replace' and `update' signal when the
identity is missing.  The source also exposes its primary key as the Data
Controller `:item-key' capability, so selection identity needs no extra
callback.  Mutation results include the operation, affected row count, and
identity when applicable.  The source also exposes an atomic `:mutate-batch'
capability: it receives a list of (OPERATION PAYLOAD) pairs, applies every one
of them in a single transaction and returns their results in order.  A
signaled operation rolls the whole batch back and commit uncertainty signals
`etaf-sqlite-commit-unknown'.  Every operation uses a short connection;
controllers remain the owner of reactive state and lifecycle.  The legacy
`:mutate' capability is exposed by default.  When MUTATE-V2 is non-nil, add
the opt-in `:mutate-v2' capability that returns explicit commit/rollback
certainty and an opaque reconciliation token."
  (unless (etaf-sqlite--database-p database)
    (signal 'wrong-type-argument
            (list 'etaf-sqlite-database-p database)))
  (let* ((table (etaf-sqlite--database-table database))
         (primary (etaf-sqlite--table-primary-key table))
         (capabilities
          (list :name 'etaf-sqlite
                :provider 'sqlite
                :item-key (and primary
                               (lambda (record)
                                 (etaf-sqlite--record-value record primary)))
                :load (lambda (query page page-size)
                        (etaf-sqlite--select-items database query page page-size))
                :mutate (lambda (operation payload)
                          (etaf-sqlite--mutate database operation payload))
                :mutate-batch (lambda (operations)
                                (etaf-sqlite--mutate-batch database
                                                           operations)))))
    ;; Keep the typed wrapper opt-in.  The M4a additive path must not silently
    ;; change existing SQLite controllers from the v1 callback contract.
    (when mutate-v2
      (setq capabilities
            (append capabilities
                    (list :mutate-v2
                          (lambda (operation payload)
                            (etaf-sqlite--mutate-v2 database operation payload))))))
    (apply #'etaf-data-source capabilities)))

(provide 'etaf-sqlite-store)

;;; etaf-sqlite-store.el ends here
