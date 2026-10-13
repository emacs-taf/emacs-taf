;;; etaf-youtube-store.el --- Local persistence of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Local, account-independent state lives in one SQLite table through ETAF DB:
;; playback preferences (volume, speed, quality, appearance) and the resume
;; position of watched videos, each as a keyed entry.  Account lists,
;; subscriptions and comments stay in memory; the account remains their
;; authority, so nothing here is written back to YouTube.

;;; Code:

(require 'cl-lib)
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

(defun etaf-youtube-store-open ()
  "Open the store and return it, or nil when SQLite is unavailable.
A failure to open is reported once by the caller; the application continues
without persistence."
  (condition-case _error
      (let* ((database (etaf-youtube--store-database))
             (_ (etaf-sqlite-initialize database))
             (controller (etaf-data-controller (etaf-sqlite-source database)
                                               :page-size 50 :auto-load nil)))
        (list :database database :controller controller))
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
    (when-let* ((text (etaf-youtube--store-entry
                       store (concat etaf-youtube--resume-prefix video-id))))
      (string-to-number text))))

(defun etaf-youtube-store-record-resume (store video-id position)
  "Record POSITION seconds as STORE's resume point for VIDEO-ID."
  (when (and store video-id (numberp position) (>= position 0))
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
