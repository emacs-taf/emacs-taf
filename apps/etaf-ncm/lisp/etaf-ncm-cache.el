;;; etaf-ncm-cache.el --- Persistent SQLite cache for player media -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Lyrics are immutable per song and a downloaded cover only changes when the
;; song's cover URL does, so both survive restarts in one SQLite database built
;; with `etaf-db'.  Every entry is keyed by a `KIND:ID' string; the table stores
;; the payload (lyric text or cover file path) plus the fact that validates it
;; (the translation text or the cover URL).
;;
;; The cache is created next to the session's library snapshot, so a function
;; client without a snapshot path uses no database at all.  Opening, reading and
;; writing never signal: an unavailable SQLite, a corrupt file or a schema
;; mismatch disables the cache and leaves the player on the network path.

;;; Code:

(require 'cl-lib)
(require 'etaf-db)

(defconst etaf-ncm-cache--table
  (etaf-sqlite-table
   'media_cache
   (list (etaf-sqlite-column :key "cache_key" :type 'text :primary t)
         (etaf-sqlite-column :payload "payload" :type 'text)
         (etaf-sqlite-column :detail "detail" :type 'text)
         (etaf-sqlite-column :at "cached_at" :type 'text))
   :key)
  "The media cache table: one row per `KIND:ID' entry.")

(defun etaf-ncm-cache-open (file)
  "Open FILE as the player's media cache and return its handle, or nil.
Creating the database, its table and the handle all fail open: any error
returns nil so the caller keeps working without a cache."
  (condition-case nil
      (let ((file (expand-file-name file)))
        (make-directory (file-name-directory file) t)
        (let* ((database (etaf-sqlite-database file etaf-ncm-cache--table))
               (source (etaf-sqlite-source database)))
          (etaf-sqlite-initialize database)
          ;; Keep the two capability functions: every operation uses its own
          ;; short-lived connection, so the handle holds no database resource.
          (list :database database
                :load (plist-get source :load)
                :mutate (plist-get source :mutate))))
    (error nil)))

(defun etaf-ncm-cache-p (cache)
  "Return non-nil when CACHE is a live media cache handle."
  (and (consp cache) (plist-get cache :database) t))

(defun etaf-ncm-cache--key (kind id)
  "Return KIND's cache key for song ID."
  (format "%s:%s" kind id))

(defun etaf-ncm-cache--get (cache key)
  "Return CACHE's row for KEY, or nil on a miss or any failure."
  (when (etaf-ncm-cache-p cache)
    (condition-case nil
        (car (plist-get (funcall (plist-get cache :load) (list :key key) 1 1) :items))
      (error nil))))

(defun etaf-ncm-cache--put (cache key payload detail)
  "Store PAYLOAD with validating DETAIL under KEY in CACHE.
A failure leaves the cache unchanged and returns nil."
  (when (etaf-ncm-cache-p cache)
    (condition-case nil
        (funcall (plist-get cache :mutate) 'upsert
                 (list :key key
                       :payload (or payload "")
                       :detail (or detail "")
                       :at (format-time-string "%FT%T%z")))
      (error nil))))

(defun etaf-ncm-cache-lyric (cache song-id)
  "Return SONG-ID's cached lyric as (:lyric LYRIC :trans TRANS), or nil.
A cached empty lyric is a hit too: the song has none and must not be fetched
again.  The returned plist is detached from the database."
  (when (and (etaf-ncm-cache-p cache) (numberp song-id))
    (when-let* ((row (etaf-ncm-cache--get cache (etaf-ncm-cache--key "lyric" song-id))))
      (list :lyric (plist-get row :payload)
            :trans (plist-get row :detail)))))

(defun etaf-ncm-cache-put-lyric (cache song-id lyric trans)
  "Cache SONG-ID's LYRIC and TRANS texts in CACHE."
  (etaf-ncm-cache--put cache (etaf-ncm-cache--key "lyric" song-id) lyric trans))

(defun etaf-ncm-cache-cover-record (cache song-id)
  "Return SONG-ID's raw cover row (:payload FILE :detail URL), or nil.
The model uses it to tell a never-indexed song from one whose URL changed:
only the former may adopt a file that predates the index."
  (when (and (etaf-ncm-cache-p cache) (numberp song-id))
    (etaf-ncm-cache--get cache (etaf-ncm-cache--key "cover" song-id))))

(defun etaf-ncm-cache-cover (cache song-id url)
  "Return SONG-ID's cached cover file when URL still matches and the file exists.
A changed URL or a deleted file is a miss, so the next request refreshes the
art instead of pinning a stale one."
  (when (and (stringp url) (not (string-empty-p url)))
    (when-let* ((row (etaf-ncm-cache-cover-record cache song-id))
                ((equal url (plist-get row :detail)))
                (file (plist-get row :payload))
                ((stringp file))
                ((not (string-empty-p file)))
                ((file-readable-p file)))
      file)))

(defun etaf-ncm-cache-put-cover (cache song-id url file)
  "Cache SONG-ID's cover FILE as the local copy of URL in CACHE."
  (etaf-ncm-cache--put cache (etaf-ncm-cache--key "cover" song-id) file url))

(provide 'etaf-ncm-cache)
;;; etaf-ncm-cache.el ends here
