;;; etaf-db.el --- Database backends for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1"))
;; URL: https://github.com/emacs-taf/etaf-db

;;; Commentary:

;; ETAF DB provides database backends for the ETAF Data Source contract.
;; SQLite is the only implemented backend.  Its etaf-sqlite-* constructors
;; describe SQLite storage explicitly; Data Controllers remain in ETAF core.
;;
;; Public API
;;
;; Load this package with (require 'etaf-db) after adding the repository
;; root to load-path.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen. Do not require files below lisp/ from consumers.
;; This Commentary is the authoritative export list; implementations and precise
;; docstrings remain beside their definitions. The ETAF Reference Manual contains workflows.
;;
;; Function: etaf-sqlite-column (id sql-name &key (type 'any) nullable primary)
;;;###autoload (autoload 'etaf-sqlite-column "etaf-db" nil nil)
;; Declare a SQLite column with semantic ID and physical SQL-NAME.
;;
;; TYPE is one of `integer', `real', `text', `blob', or `any'.  NULLABLE allows
;; SQL NULL values.  PRIMARY marks the column as the table's identity; pass its
;; semantic ID as the table's PRIMARY-KEY so the source knows it.  SQL-NAME is
;; validated once and never comes from a runtime query.
;;
;; Error: etaf-sqlite-commit-unknown
;; SQLite commit outcome is unknown
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-sqlite-database (file table)
;;;###autoload (autoload 'etaf-sqlite-database "etaf-db" nil nil)
;; Describe SQLite FILE using typed TABLE metadata.
;;
;; Error: etaf-sqlite-error
;; Invalid ETAF SQLite operation
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-sqlite-initialize (database)
;;;###autoload (autoload 'etaf-sqlite-initialize "etaf-db" nil nil)
;; Create DATABASE's table if it does not exist and return DATABASE.
;; When the table already exists, columns the descriptor has gained are added
;; in place as long as they are nullable; a missing primary or declared
;; non-nullable column signals `etaf-sqlite-schema-error'.
;;
;; Error: etaf-sqlite-schema-error
;; Invalid ETAF SQLite schema
;; Catch this condition with condition-case; failed calls do not return a value.
;;
;; Function: etaf-sqlite-source (database &key mutate-v2)
;;;###autoload (autoload 'etaf-sqlite-source "etaf-db" nil nil)
;; Return an `etaf-data-source' backed by DATABASE.
;;
;; The source accepts equality plist/alist queries and supports `insert',
;; `replace', `update', `upsert', and `delete' mutations.  `upsert' inserts a
;; row or updates the existing row with the same primary key; `replace' and
;; `update' signal when the identity is missing.  The source exposes its
;; primary key as the Data Controller `:item-key' capability.  Mutation
;; results include the operation, affected row count, and identity when
;; applicable.  The source also exposes an atomic `:mutate-batch' capability:
;; it receives a list of (OPERATION PAYLOAD) pairs, applies them in one
;; transaction, and returns one result per operation; a signaled operation
;; rolls the whole batch back.  Every operation uses a short connection; controllers remain
;; the owner of reactive state and lifecycle.  The legacy `:mutate' capability
;; is exposed by default.  When MUTATE-V2 is non-nil, add the opt-in
;; `:mutate-v2' capability that returns explicit commit/rollback certainty and
;; an opaque reconciliation token.
;;
;; Function: etaf-sqlite-table (id columns &optional primary-key)
;;;###autoload (autoload 'etaf-sqlite-table "etaf-db" nil nil)
;; Declare table ID from COLUMNS and optional PRIMARY-KEY semantic ID; without
;; it the table has no identity, and the mutations that need one are rejected.
;;
;; Error: etaf-sqlite-unavailable
;; SQLite is unavailable
;; Catch this condition with condition-case; failed calls do not return a value.
;;

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-sqlite-store)

(provide 'etaf-db)
;;; etaf-db.el ends here
