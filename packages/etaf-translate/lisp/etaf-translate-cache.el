;;; etaf-translate-cache.el --- Two-tier pluggable translation cache -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Bounded L1 in-memory cache with an optional L2 persistence backend protocol
;; (`:get', `:put', `:remove', `:clear', `:stats', `:prune', `:close').
;; The shared default cache automatically attaches the native SQLite L2 store
;; from `etaf-translate-store' when enabled and supported by Emacs.

;;; Code:

(require 'cl-lib)
(require 'etaf-translate-core)
(require 'etaf-translate-store)

(cl-defstruct (etaf-translate-cache
               (:constructor etaf-translate-cache--make))
  "Translation cache combining bounded L1 memory storage and L2 persistence."
  (table (make-hash-table :test #'equal))
  (max-entries 4096)
  (hits 0)
  (misses 0)
  persistence)

(defvar etaf-translate--default-cache nil
  "Shared default `etaf-translate-cache' instance.")

(defvar etaf-translate--default-cache-key nil
  "Configuration key `(DISK-ENABLED . FILE)' for `etaf-translate--default-cache'.")

(defun etaf-translate-cache-create (&rest options)
  "Create and return a new `etaf-translate-cache' from plist OPTIONS.
Supported keys are `:max-entries' (positive integer, default 4096) and
`:persistence' (optional plist with `:get', `:put' and optional `:remove',
`:clear', `:stats', `:prune', `:close')."
  (let ((max-entries (or (plist-get options :max-entries) 4096))
        (persistence (plist-get options :persistence)))
    (unless (and (integerp max-entries) (> max-entries 0))
      (signal 'etaf-translate-error
              (list "Cache :max-entries must be a positive integer" max-entries)))
    (when persistence
      (unless (and (proper-list-p persistence)
                   (functionp (plist-get persistence :get))
                   (functionp (plist-get persistence :put)))
        (signal 'etaf-translate-error
                (list "Cache :persistence requires :get and :put functions"
                      persistence))))
    (etaf-translate-cache--make :max-entries max-entries
                                :persistence persistence)))

(defun etaf-translate-default-cache ()
  "Return the shared process-wide translation cache.
Automatically attaches an L2 SQLite backend when
`etaf-translate-enable-disk-cache' and `etaf-translate-cache-file' are set."
  (let ((key (cons (not (null etaf-translate-enable-disk-cache))
                   (and etaf-translate-enable-disk-cache
                        etaf-translate-cache-file))))
    (unless (and etaf-translate--default-cache
                 (equal key etaf-translate--default-cache-key))
      (let ((persist (when (cdr key)
                       (etaf-translate-sqlite-persistence
                        (cdr key)
                        etaf-translate-cache-ttl-days
                        etaf-translate-cache-max-disk-entries))))
        (setq etaf-translate--default-cache-key key
              etaf-translate--default-cache
              (etaf-translate-cache-create :persistence persist))))
    etaf-translate--default-cache))

(defun etaf-translate-cache-key (markup-text source-lang target-lang engine-id glossary-hash)
  "Return a deterministic string cache key for one translation unit."
  (format "%s|%s|%s|%s|%s"
          (or engine-id 'default)
          (if (symbolp source-lang) (symbol-name source-lang) (or source-lang "auto"))
          (or target-lang "")
          (or glossary-hash "")
          (etaf-translate-text-hash markup-text)))

(defun etaf-translate-cache-get (cache key)
  "Return cached translated string for KEY in CACHE, or nil on a miss."
  (let* ((table (etaf-translate-cache-table cache))
         (hit (gethash key table)))
    (cond
     (hit
      (cl-incf (etaf-translate-cache-hits cache))
      hit)
     (t
      (let* ((backend (etaf-translate-cache-persistence cache))
             (getter (and backend (plist-get backend :get)))
             (persisted (and getter (ignore-errors (funcall getter key)))))
        (if (stringp persisted)
            (progn
              (cl-incf (etaf-translate-cache-hits cache))
              (etaf-translate-cache--l1-put cache key persisted)
              persisted)
          (cl-incf (etaf-translate-cache-misses cache))
          nil))))))

(defun etaf-translate-cache--l1-put (cache key value)
  "Store KEY -> VALUE in CACHE's bounded L1 hash table."
  (let ((table (etaf-translate-cache-table cache))
        (limit (etaf-translate-cache-max-entries cache)))
    (when (>= (hash-table-count table) limit)
      ;; Evict roughly a quarter of existing entries to keep insertion O(1) amortized.
      (let ((drop (/ limit 4))
            (keys nil))
        (catch 'enough
          (maphash (lambda (k _v)
                     (push k keys)
                     (when (>= (length keys) drop)
                       (throw 'enough nil)))
                   table))
        (dolist (k keys) (remhash k table))))
    (puthash key value table)))

(defun etaf-translate-cache-put (cache key value)
  "Store translated string VALUE under KEY in CACHE and return VALUE."
  (when (stringp value)
    (etaf-translate-cache--l1-put cache key value)
    (when-let* ((backend (etaf-translate-cache-persistence cache))
                (putter (plist-get backend :put)))
      (ignore-errors (funcall putter key value))))
  value)

(defun etaf-translate-cache-remove (cache key)
  "Remove KEY from CACHE's L1 table and L2 backend if supported."
  (remhash key (etaf-translate-cache-table cache))
  (when-let* ((backend (etaf-translate-cache-persistence cache))
              (remover (plist-get backend :remove)))
    (ignore-errors (funcall remover key))))

(defun etaf-translate-cache-clear (&optional cache)
  "Clear CACHE (defaulting to the shared cache) and its L2 backend if present."
  (let ((target (or cache (etaf-translate-default-cache))))
    (clrhash (etaf-translate-cache-table target))
    (setf (etaf-translate-cache-hits target) 0
          (etaf-translate-cache-misses target) 0)
    (when-let* ((backend (etaf-translate-cache-persistence target))
                (clearer (plist-get backend :clear)))
      (ignore-errors (funcall clearer)))
    t))

(defun etaf-translate-cache-prune (&optional cache)
  "Prune expired and excess LRU entries from CACHE's L2 persistence backend.
Return the number of entries deleted."
  (let* ((target (or cache (etaf-translate-default-cache)))
         (backend (etaf-translate-cache-persistence target))
         (pruner (and backend (plist-get backend :prune))))
    (if (functionp pruner) (or (ignore-errors (funcall pruner)) 0) 0)))

(defun etaf-translate-cache-stats (&optional cache)
  "Return a detached statistics plist for CACHE (default shared cache).
Keys include `:l1-entries', `:l1-max', `:hits', `:misses', `:l2-backend',
`:l2-entries', `:l2-hits', `:l2-file' and `:l2-size-bytes'."
  (let* ((target (or cache (etaf-translate-default-cache)))
         (backend (etaf-translate-cache-persistence target))
         (l2-fn (and backend (plist-get backend :stats)))
         (l2 (and (functionp l2-fn) (ignore-errors (funcall l2-fn)))))
    (list :l1-entries (hash-table-count (etaf-translate-cache-table target))
          :l1-max (etaf-translate-cache-max-entries target)
          :hits (etaf-translate-cache-hits target)
          :misses (etaf-translate-cache-misses target)
          :l2-backend (plist-get l2 :backend)
          :l2-entries (or (plist-get l2 :entries) 0)
          :l2-hits (or (plist-get l2 :hits) 0)
          :l2-file (plist-get l2 :file)
          :l2-size-bytes (or (plist-get l2 :size-bytes) 0))))

(provide 'etaf-translate-cache)
;;; etaf-translate-cache.el ends here
