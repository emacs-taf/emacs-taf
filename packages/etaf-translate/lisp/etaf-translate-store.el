;;; etaf-translate-store.el --- SQLite L2 cache and user state persistence -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Persistent storage layer for `etaf-translate':
;; 1. SQLite-backed L2 translation cache using Emacs 29+ native SQLite
;;    (gracefully degrading to nil when SQLite support is unavailable).
;; 2. Plain Elisp data-file persistence for user-remembered site rules and
;;    glossary terms.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-translate-core)

(declare-function sqlite-available-p "sqlite.c" ())
(declare-function sqlite-open "sqlite.c" (&optional file))
(declare-function sqlite-close "sqlite.c" (db))
(declare-function sqlite-execute "sqlite.c" (db query &optional values))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

;;;; Native SQLite L2 cache backend

(defun etaf-translate--sqlite-available-p ()
  "Return non-nil when this Emacs build provides native SQLite."
  (and (fboundp 'sqlite-available-p)
       (sqlite-available-p)))

(defun etaf-translate--sqlite-init-db (file)
  "Open and initialize SQLite database FILE, returning the live handle or nil."
  (when (and file (stringp file) (etaf-translate--sqlite-available-p))
    (condition-case nil
        (let ((dir (file-name-directory (expand-file-name file))))
          (when (and dir (not (file-directory-p dir)))
            (make-directory dir t))
          (let ((db (sqlite-open (expand-file-name file))))
            (sqlite-execute db "PRAGMA journal_mode=WAL")
            (sqlite-execute db "PRAGMA synchronous=NORMAL")
            (sqlite-execute db "PRAGMA busy_timeout=2000")
            (sqlite-execute
             db
             (concat "CREATE TABLE IF NOT EXISTS translations ("
                     "cache_key TEXT PRIMARY KEY, "
                     "value TEXT NOT NULL, "
                     "created_at INTEGER NOT NULL, "
                     "last_used_at INTEGER NOT NULL, "
                     "hits INTEGER NOT NULL DEFAULT 0)"))
            (sqlite-execute
             db
             (concat "CREATE INDEX IF NOT EXISTS idx_translations_lru "
                     "ON translations(last_used_at)"))
            db))
      (error nil))))

(defun etaf-translate-sqlite-persistence (&optional file ttl-days max-entries)
  "Create an L2 SQLite persistence plist for `etaf-translate-cache-create'.
FILE defaults to `etaf-translate-cache-file'.  TTL-DAYS defaults to
`etaf-translate-cache-ttl-days' (0 disables expiration).  MAX-ENTRIES defaults
to `etaf-translate-cache-max-disk-entries'.  Return nil when native SQLite is
unavailable or FILE is nil."
  (let* ((path (or file etaf-translate-cache-file))
         (ttl (if (numberp ttl-days) ttl-days etaf-translate-cache-ttl-days))
         (limit (if (and (integerp max-entries) (> max-entries 0))
                    max-entries
                  (max 100 etaf-translate-cache-max-disk-entries)))
         (db nil)
         (writes-since-prune 0))
    (when (and path (etaf-translate--sqlite-available-p))
      (letrec
          ((ensure-db
            (lambda ()
              (or db (setq db (etaf-translate--sqlite-init-db path)))))
           (now-sec (lambda () (truncate (float-time))))
           (prune-fn
            (lambda ()
              (if-let* ((conn (funcall ensure-db)))
                  (let ((deleted 0)
                        (now (funcall now-sec)))
                    (condition-case nil
                        (progn
                          (when (and (numberp ttl) (> ttl 0))
                            (let ((cutoff (- now (truncate (* ttl 86400)))))
                              (setq deleted
                                    (+ deleted
                                       (or (sqlite-execute
                                            conn
                                            "DELETE FROM translations WHERE created_at < ?"
                                            (list cutoff))
                                           0)))))
                          (let* ((row (car (sqlite-select
                                            conn "SELECT COUNT(*) FROM translations")))
                                 (total (or (car row) 0)))
                            (when (> total limit)
                              (let ((excess (- total limit)))
                                (setq deleted
                                      (+ deleted
                                         (or (sqlite-execute
                                              conn
                                              (concat "DELETE FROM translations WHERE cache_key IN "
                                                      "(SELECT cache_key FROM translations "
                                                      "ORDER BY last_used_at ASC LIMIT ?)")
                                              (list excess))
                                             0)))))))
                      (error nil))
                    deleted)
                0))))
        (when (funcall ensure-db)
          (list
           :get
           (lambda (key)
             (when-let* ((conn (funcall ensure-db)))
               (condition-case nil
                   (let ((row (car (sqlite-select
                                    conn
                                    "SELECT value, created_at FROM translations WHERE cache_key = ?"
                                    (list key)))))
                     (when row
                       (let* ((val (nth 0 row))
                              (created (nth 1 row))
                              (now (funcall now-sec)))
                         (if (and (numberp ttl) (> ttl 0)
                                  (numberp created)
                                  (> (- now created) (truncate (* ttl 86400))))
                             (progn
                               (sqlite-execute
                                conn
                                "DELETE FROM translations WHERE cache_key = ?"
                                (list key))
                               nil)
                           (sqlite-execute
                            conn
                            "UPDATE translations SET last_used_at = ?, hits = hits + 1 WHERE cache_key = ?"
                            (list now key))
                           val))))
                 (error nil))))
           :put
           (lambda (key value)
             (when-let* ((conn (funcall ensure-db)))
               (condition-case nil
                   (let ((now (funcall now-sec)))
                     (sqlite-execute
                      conn
                      (concat "INSERT INTO translations "
                              "(cache_key, value, created_at, last_used_at, hits) "
                              "VALUES (?, ?, ?, ?, 0) "
                              "ON CONFLICT(cache_key) DO UPDATE SET "
                              "value = excluded.value, "
                              "created_at = excluded.created_at, "
                              "last_used_at = excluded.last_used_at")
                      (list key value now now))
                     (cl-incf writes-since-prune)
                     (when (>= writes-since-prune 100)
                       (setq writes-since-prune 0)
                       (funcall prune-fn)))
                 (error nil))))
           :remove
           (lambda (key)
             (when-let* ((conn (funcall ensure-db)))
               (ignore-errors
                 (sqlite-execute conn "DELETE FROM translations WHERE cache_key = ?"
                                 (list key)))))
           :clear
           (lambda ()
             (when-let* ((conn (funcall ensure-db)))
               (ignore-errors
                 (sqlite-execute conn "DELETE FROM translations"))))
           :prune prune-fn
           :stats
           (lambda ()
             (let* ((conn (funcall ensure-db))
                    (row (and conn
                              (ignore-errors
                                (car (sqlite-select
                                      conn
                                      "SELECT COUNT(*), COALESCE(SUM(hits), 0) FROM translations")))))
                    (attrs (and (file-exists-p path) (file-attributes path))))
               (list :backend 'sqlite
                     :file (expand-file-name path)
                     :entries (or (nth 0 row) 0)
                     :hits (or (nth 1 row) 0)
                     :size-bytes (if attrs (file-attribute-size attrs) 0))))
           :close
           (lambda ()
             (when db
               (ignore-errors (sqlite-close db))
               (setq db nil)))))))))

;;;; Plain Elisp data-file persistence for user site rules and glossary

(defun etaf-translate-store-load-state (&optional file)
  "Load persisted user state from FILE (default `etaf-translate-state-file').
Return a plist `(:prefs PLIST :site-rules ALIST :glossary ALIST)' or nil."
  (let ((path (or file etaf-translate-state-file)))
    (when (and (stringp path) (file-readable-p path))
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (let ((data (read (current-buffer))))
              (when (and (listp data) (plist-member data :version))
                data)))
        (error nil)))))

(defun etaf-translate-store-save-state (state &optional file)
  "Persist user STATE plist to FILE (default `etaf-translate-state-file').
Return non-nil when written."
  (let ((path (or file etaf-translate-state-file)))
    (when (stringp path)
      (let* ((expanded (expand-file-name path))
             (dir (file-name-directory expanded))
             (payload (list :version 1
                            :prefs (plist-get state :prefs)
                            :site-rules (plist-get state :site-rules)
                            :glossary (plist-get state :glossary)))
             (print-length nil)
             (print-level nil)
             (print-circle nil)
             (coding-system-for-write 'utf-8-unix))
        (when (and dir (not (file-directory-p dir)))
          (make-directory dir t))
        (with-temp-buffer
          (insert ";; -*- mode: lisp-data; coding: utf-8; -*-\n")
          (insert ";; Persisted panel preferences, site rules and glossary for etaf-translate.\n")
          (prin1 payload (current-buffer))
          (insert "\n")
          (write-region (point-min) (point-max) expanded nil 'silent))
        t))))

(provide 'etaf-translate-store)
;;; etaf-translate-store.el ends here
