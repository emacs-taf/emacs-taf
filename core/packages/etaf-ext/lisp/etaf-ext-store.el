;;; etaf-ext-store.el --- Persistent isolated storage and policies for etaf-ext -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Namespaced key-value storage and persisted enable/per-app policy state for
;; `etaf-ext'.  Uses Emacs 29+ native SQLite in WAL mode when available and
;; degrades cleanly to in-memory hash tables otherwise.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-ext-core)

(declare-function sqlite-available-p "sqlite.c" ())
(declare-function sqlite-open "sqlite.c" (&optional file))
(declare-function sqlite-close "sqlite.c" (db))
(declare-function sqlite-execute "sqlite.c" (db query &optional values))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

(defvar etaf-ext--store-db nil
  "Open SQLite database handle for `etaf-ext', or nil.")

(defvar etaf-ext--store-db-file nil
  "Path of the currently open `etaf-ext--store-db'.")

(defvar etaf-ext--store-mem (make-hash-table :test #'equal)
  "In-memory fallback store keyed by (EXT-ID . KEY).")

(defvar etaf-ext--disabled-set (make-hash-table :test #'eq)
  "Hash table of globally disabled extension IDs.")

(defvar etaf-ext--app-policies (make-hash-table :test #'equal)
  "Hash table mapping (EXT-ID . APP-ID) to `allow' or `deny'.")

(defvar etaf-ext--key-overrides (make-hash-table :test #'equal)
  "Hash table mapping (EXT-ID . CMD-ID) to normalized key string or `:unbound'.")

(defvar etaf-ext--store-loaded nil
  "Non-nil once persisted enable/policy state has been loaded for current file.")

(defun etaf-ext--sqlite-available-p ()
  "Return non-nil when this Emacs build provides native SQLite."
  (and (fboundp 'sqlite-available-p)
       (sqlite-available-p)))

(defun etaf-ext--store-close ()
  "Close the open SQLite handle if any and reset loaded flag."
  (when etaf-ext--store-db
    (ignore-errors (sqlite-close etaf-ext--store-db))
    (setq etaf-ext--store-db nil
          etaf-ext--store-db-file nil))
  (setq etaf-ext--store-loaded nil))

(defun etaf-ext--store-ensure-db ()
  "Return an open SQLite handle for `etaf-ext-storage-file', or nil."
  (let ((path (and (stringp etaf-ext-storage-file)
                   (expand-file-name etaf-ext-storage-file))))
    (when (and etaf-ext--store-db (not (equal path etaf-ext--store-db-file)))
      (etaf-ext--store-close))
    (cond
     (etaf-ext--store-db etaf-ext--store-db)
     ((and path (etaf-ext--sqlite-available-p))
      (condition-case nil
          (let ((dir (file-name-directory path)))
            (when (and dir (not (file-directory-p dir)))
              (make-directory dir t))
            (let ((db (sqlite-open path)))
              (sqlite-execute db "PRAGMA journal_mode=WAL")
              (sqlite-execute db "PRAGMA synchronous=NORMAL")
              (sqlite-execute db "PRAGMA busy_timeout=2000")
              (sqlite-execute
               db
               (concat "CREATE TABLE IF NOT EXISTS ext_kv ("
                       "ext_id TEXT NOT NULL, "
                       "k TEXT NOT NULL, "
                       "v TEXT NOT NULL, "
                       "updated_at INTEGER NOT NULL, "
                       "PRIMARY KEY (ext_id, k))"))
              (setq etaf-ext--store-db db
                    etaf-ext--store-db-file path)
              db))
        (error nil)))
     (t nil))))

(defun etaf-ext--store-encode (value)
  "Serialize Lisp VALUE into a safe readable string."
  (let ((print-circle t)
        (print-length nil)
        (print-level nil))
    (prin1-to-string value)))

(defun etaf-ext--store-decode (raw)
  "Deserialize RAW string back into a Lisp value, or nil on parse failure."
  (when (stringp raw)
    (condition-case nil
        (car (read-from-string raw))
      (error nil))))

(defun etaf-ext--store-key-string (key)
  "Normalize storage KEY (string or symbol) to a non-empty string."
  (cond
   ((and (stringp key) (not (string-empty-p key)))
    (substring-no-properties key))
   ((and (symbolp key) key)
    (symbol-name key))
   (t
    (signal 'etaf-ext-error (list "Storage key must be a non-empty string or symbol" key)))))

(defun etaf-ext--kv-get (ext-id key &optional default)
  "Read KEY under namespace EXT-ID, returning DEFAULT when absent."
  (let* ((ns (symbol-name ext-id))
         (ks (etaf-ext--store-key-string key))
         (db (etaf-ext--store-ensure-db)))
    (if db
        (let ((rows (condition-case nil
                        (sqlite-select
                         db "SELECT v FROM ext_kv WHERE ext_id = ? AND k = ?"
                         (list ns ks))
                      (error nil))))
          (if rows
              (etaf-ext--store-decode (caar rows))
            default))
      (let ((val (gethash (cons ns ks) etaf-ext--store-mem 'etaf-ext--missing)))
        (if (eq val 'etaf-ext--missing) default (copy-tree val))))))

(defun etaf-ext--kv-set (ext-id key value)
  "Write VALUE for KEY under namespace EXT-ID and return VALUE."
  (let* ((ns (symbol-name ext-id))
         (ks (etaf-ext--store-key-string key))
         (db (etaf-ext--store-ensure-db)))
    (if db
        (sqlite-execute
         db
         (concat "INSERT INTO ext_kv (ext_id, k, v, updated_at) "
                 "VALUES (?, ?, ?, ?) "
                 "ON CONFLICT(ext_id, k) DO UPDATE SET "
                 "v = excluded.v, updated_at = excluded.updated_at")
         (list ns ks (etaf-ext--store-encode value) (truncate (float-time))))
      (puthash (cons ns ks) (copy-tree value) etaf-ext--store-mem))
    value))

(defun etaf-ext--kv-delete (ext-id key)
  "Delete KEY under namespace EXT-ID; return non-nil when present."
  (let* ((ns (symbol-name ext-id))
         (ks (etaf-ext--store-key-string key))
         (db (etaf-ext--store-ensure-db)))
    (if db
        (let ((changes (sqlite-execute
                        db "DELETE FROM ext_kv WHERE ext_id = ? AND k = ?"
                        (list ns ks))))
          (and (integerp changes) (> changes 0)))
      (let ((had (not (eq (gethash (cons ns ks) etaf-ext--store-mem 'etaf-ext--missing)
                          'etaf-ext--missing))))
        (remhash (cons ns ks) etaf-ext--store-mem)
        had))))

(defun etaf-ext--kv-keys (ext-id)
  "Return sorted list of stored key strings under namespace EXT-ID."
  (let* ((ns (symbol-name ext-id))
         (db (etaf-ext--store-ensure-db)))
    (if db
        (mapcar #'car
                (condition-case nil
                    (sqlite-select
                     db "SELECT k FROM ext_kv WHERE ext_id = ? ORDER BY k ASC"
                     (list ns))
                  (error nil)))
      (let (keys)
        (maphash (lambda (pair _v)
                   (when (equal (car pair) ns)
                     (push (cdr pair) keys)))
                 etaf-ext--store-mem)
        (sort keys #'string<)))))

;;;; Persisted enable/disable and per-app policies

(defun etaf-ext--policy-ensure-loaded ()
  "Load persisted disabled set, app policies and key overrides once per file."
  (let ((path (and (stringp etaf-ext-storage-file)
                   (expand-file-name etaf-ext-storage-file))))
    (when (and etaf-ext--store-db (not (equal path etaf-ext--store-db-file)))
      (etaf-ext--store-close)))
  (unless etaf-ext--store-loaded
    (setq etaf-ext--store-loaded t)
    (clrhash etaf-ext--disabled-set)
    (clrhash etaf-ext--app-policies)
    (clrhash etaf-ext--key-overrides)
    (let ((disabled (etaf-ext--kv-get 'etaf-ext--system "disabled" nil))
          (policies (etaf-ext--kv-get 'etaf-ext--system "app-policies" nil))
          (keybinds (etaf-ext--kv-get 'etaf-ext--system "keybindings" nil)))
      (when (proper-list-p disabled)
        (dolist (id disabled)
          (when (symbolp id) (puthash id t etaf-ext--disabled-set))))
      (when (proper-list-p policies)
        (dolist (entry policies)
          (when (and (consp entry) (consp (car entry))
                     (memq (cdr entry) '(allow deny)))
            (puthash (car entry) (cdr entry) etaf-ext--app-policies))))
      (when (proper-list-p keybinds)
        (dolist (entry keybinds)
          (when (and (consp entry) (consp (car entry))
                     (symbolp (caar entry)) (symbolp (cdar entry))
                     (or (eq (cdr entry) :unbound)
                         (and (stringp (cdr entry))
                              (not (string-empty-p (cdr entry))))))
            (puthash (car entry) (cdr entry) etaf-ext--key-overrides)))))))

(defun etaf-ext--policy-save ()
  "Persist disabled set, per-app policies and user key overrides."
  (let (disabled policies keybinds)
    (maphash (lambda (id _v) (push id disabled)) etaf-ext--disabled-set)
    (maphash (lambda (k v) (push (cons k v) policies)) etaf-ext--app-policies)
    (maphash (lambda (k v) (push (cons k v) keybinds)) etaf-ext--key-overrides)
    (ignore-errors
      (etaf-ext--kv-set 'etaf-ext--system "disabled" disabled)
      (etaf-ext--kv-set 'etaf-ext--system "app-policies" policies)
      (etaf-ext--kv-set 'etaf-ext--system "keybindings" keybinds))))

(defun etaf-ext--policy-key-override (id cmd-id)
  "Return persisted key override (string, `:unbound' or nil) for ID and CMD-ID."
  (etaf-ext--policy-ensure-loaded)
  (gethash (cons id cmd-id) etaf-ext--key-overrides))

(defun etaf-ext--policy-set-key-override (id cmd-id value)
  "Persist key override VALUE (string, `:unbound' or nil) for ID and CMD-ID."
  (etaf-ext--policy-ensure-loaded)
  (if (null value)
      (remhash (cons id cmd-id) etaf-ext--key-overrides)
    (puthash (cons id cmd-id) value etaf-ext--key-overrides))
  (etaf-ext--policy-save)
  value)

(defun etaf-ext-enabled-p (id)
  "Return non-nil when extension ID is globally enabled."
  (etaf-ext--get-spec id)
  (etaf-ext--policy-ensure-loaded)
  (not (gethash id etaf-ext--disabled-set)))

(defun etaf-ext-app-policy (id app-id)
  "Return explicit per-app policy (`allow', `deny' or nil) for ID and APP-ID."
  (etaf-ext--get-spec id)
  (etaf-ext--policy-ensure-loaded)
  (gethash (cons id app-id) etaf-ext--app-policies))

(defun etaf-ext-app-policies (id)
  "Return alist of `(APP-ID . POLICY)' rules configured for extension ID."
  (etaf-ext--get-spec id)
  (etaf-ext--policy-ensure-loaded)
  (let (out)
    (maphash (lambda (pair policy)
               (when (eq (car pair) id)
                 (push (cons (cdr pair) policy) out)))
             etaf-ext--app-policies)
    (sort out (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))))

(defun etaf-ext--policy-set-enabled (id enabled-p)
  "Record global ENABLED-P state for extension ID."
  (etaf-ext--policy-ensure-loaded)
  (if enabled-p
      (remhash id etaf-ext--disabled-set)
    (puthash id t etaf-ext--disabled-set))
  (etaf-ext--policy-save))

(defun etaf-ext--policy-set-app (id app-id policy)
  "Record per-app POLICY (`allow', `deny' or nil) for ID on APP-ID."
  (unless (and (symbolp app-id) app-id)
    (signal 'etaf-ext-error (list "App ID must be a non-nil symbol" app-id)))
  (unless (memq policy '(nil allow deny))
    (signal 'etaf-ext-error (list "App policy must be allow, deny or nil" policy)))
  (etaf-ext--policy-ensure-loaded)
  (if (null policy)
      (remhash (cons id app-id) etaf-ext--app-policies)
    (puthash (cons id app-id) policy etaf-ext--app-policies))
  (etaf-ext--policy-save))

(provide 'etaf-ext-store)
;;; etaf-ext-store.el ends here
