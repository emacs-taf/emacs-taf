;;; etaf-youtube-store.el --- Local persistence of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Local, account-independent state lives in one SQLite table through ETAF DB:
;; playback preferences (volume, speed, quality, appearance, auto-next,
;; preferred subtitle language) and the resume position of watched videos.
;; An in-memory mirror of recent resume entries lets Views display card resume
;; badges and progress bars without ever touching SQLite during render.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-db)

(defcustom etaf-youtube-store-file
  (locate-user-emacs-file "etaf-youtube/store.sqlite3")
  "SQLite file holding local preferences and resume positions."
  :type 'file
  :group 'etaf-youtube)

(defconst etaf-youtube--setting-prefix "setting:"
  "Key prefix of a persisted scalar setting.")

(defconst etaf-youtube--resume-prefix "resume:"
  "Key prefix of a persisted video resume position.")

(defun etaf-youtube--store-database ()
  "Return the SQLite database descriptor of the store."
  (etaf-sqlite-database
   etaf-youtube-store-file
   (etaf-sqlite-table
    'entries
    (list (etaf-sqlite-column :key "key" :type 'text :primary t)
          (etaf-sqlite-column :value "value" :type 'text :nullable t)
          (etaf-sqlite-column :updated "updated" :type 'integer :nullable t))
    :key)))

(defun etaf-youtube--store-preload-resumes (controller cache)
  "Load recent resume rows from CONTROLLER into CACHE hash table."
  (condition-case nil
      (progn
        (etaf-data-set-query controller nil)
        (etaf-data-set-page controller 1)
        (etaf-data-load controller)
        (dolist (row (append (etaf-value (etaf-data-items controller)) nil))
          (let ((key (plist-get row :key))
                (val (plist-get row :value)))
            (when (and (stringp key)
                       (string-prefix-p etaf-youtube--resume-prefix key)
                       (stringp val))
              (let ((vid (substring key (length etaf-youtube--resume-prefix)))
                    (num (string-to-number val)))
                (when (> num 0)
                  (puthash vid num cache)))))))
    (error nil)))

(defun etaf-youtube-store-open ()
  "Open the store and return it, or nil when SQLite is unavailable.
A failure to open is reported once by the caller; the application continues
without persistence."
  (condition-case _error
      (let* ((database (etaf-youtube--store-database))
             (_ (etaf-sqlite-initialize database))
             (controller (etaf-data-controller (etaf-sqlite-source database)
                                               :page-size 200 :auto-load nil))
             (cache (make-hash-table :test #'equal)))
        (etaf-youtube--store-preload-resumes controller cache)
        (list :database database :controller controller :resume-cache cache))
    (error nil)))

(defun etaf-youtube--store-entry (store key)
  "Return STORE's raw entry string for KEY, or nil."
  (when store
    (let ((controller (plist-get store :controller)))
      (etaf-data-set-query controller (list :key key))
      (etaf-data-set-page controller 1)
      (etaf-data-load controller)
      (plist-get (car (append (etaf-value (etaf-data-items controller)) nil))
                 :value))))

(defun etaf-youtube--store-write (store key value)
  "Write STORE's KEY to VALUE."
  (when store
    (etaf-data-mutate-many
     (plist-get store :controller)
     (list (list 'upsert (list :key key
                               :value (if (stringp value) value (format "%s" value))
                               :updated (floor (float-time))))))))

(defun etaf-youtube-store-setting (store name)
  "Return STORE's setting NAME as a string, or nil."
  (etaf-youtube--store-entry store (concat etaf-youtube--setting-prefix name)))

(defun etaf-youtube-store-set-setting (store name value)
  "Write STORE's setting NAME to VALUE."
  (etaf-youtube--store-write store (concat etaf-youtube--setting-prefix name) value))

(defun etaf-youtube-store-resume (store video-id)
  "Return STORE's resume position for VIDEO-ID in seconds, or nil."
  (when (and store video-id)
    (let ((cache (plist-get store :resume-cache)))
      (or (and (hash-table-p cache) (gethash video-id cache))
          (when-let* ((text (etaf-youtube--store-entry
                             store (concat etaf-youtube--resume-prefix video-id))))
            (let ((num (string-to-number text)))
              (when (hash-table-p cache)
                (if (> num 0) (puthash video-id num cache) (remhash video-id cache)))
              num))))))

(defun etaf-youtube--store-cached-resume (store video-id)
  "Return VIDEO-ID's cached resume seconds from STORE without hitting SQLite.
Safe to call inside `:render'."
  (when (and store video-id)
    (let ((cache (plist-get store :resume-cache)))
      (and (hash-table-p cache) (gethash video-id cache)))))

(defun etaf-youtube-store-record-resume (store video-id position)
  "Record POSITION seconds as STORE's resume point for VIDEO-ID."
  (when (and store video-id (numberp position) (>= position 0))
    (when-let* ((cache (plist-get store :resume-cache)))
      (if (> position 0)
          (puthash video-id (float position) cache)
        (remhash video-id cache)))
    (etaf-youtube--store-write store
                               (concat etaf-youtube--resume-prefix video-id)
                               (format "%.3f" position))))

(defun etaf-youtube-store-close (store)
  "Release STORE's Data Controller."
  (when store
    (when-let* ((controller (plist-get store :controller)))
      (ignore-errors (etaf-data-stop controller)))))

(provide 'etaf-youtube-store)
;;; etaf-youtube-store.el ends here
