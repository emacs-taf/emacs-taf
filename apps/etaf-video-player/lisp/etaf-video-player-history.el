;;; etaf-video-player-history.el --- SQLite playback history and bookmarks -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Persistent playback position history and timestamp bookmarks stored in one
;; SQLite database through `etaf-db'.  Two tables live in the same database
;; file: `playback_history' (keyed by expanded path) and `bookmarks' (keyed by
;; unique bookmark id, indexed by path).  Every operation degrades cleanly to
;; nil when SQLite is unavailable or opening the database fails, caching open
;; failures so playback ticks never retry repeatedly.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf-db)
(require 'etaf-video-player-theme)

(defcustom etaf-video-player-history-file nil
  "Database file holding saved playback positions and timestamp bookmarks.
Nil uses `etaf-video-player/history.sqlite3' under `user-emacs-directory'."
  :type '(choice (const :tag "Default under user-emacs-directory" nil) file)
  :group 'etaf-video-player)

(defvar etaf-video-player--history-store nil
  "Cached store plist (:file :history :bookmarks :failed).")

(defvar etaf-video-player--bookmark-seq 0
  "Monotonic tie-breaker ensuring unique bookmark ids.")

(defun etaf-video-player--history-key (target)
  "Return the normalized persistence key for file path or URL TARGET."
  (when (and (stringp target) (> (length target) 0))
    (if (string-match-p "\\`https?://" target)
        target
      (expand-file-name target))))

(defun etaf-video-player--history-path ()
  "Return the expanded SQLite database file path."
  (expand-file-name
   (or etaf-video-player-history-file
       (expand-file-name "etaf-video-player/history.sqlite3"
                         user-emacs-directory))))

(defun etaf-video-player--history-table ()
  "Return the `etaf-db' table descriptor for playback positions."
  (etaf-sqlite-table
   'playback_history
   (list (etaf-sqlite-column :path "path" :type 'text :primary t)
         (etaf-sqlite-column :position "position" :type 'real)
         (etaf-sqlite-column :duration "duration" :type 'real :nullable t)
         (etaf-sqlite-column :updated "updated" :type 'real))
   :path))

(defun etaf-video-player--bookmarks-table ()
  "Return the `etaf-db' table descriptor for timestamp bookmarks."
  (etaf-sqlite-table
   'bookmarks
   (list (etaf-sqlite-column :id "id" :type 'text :primary t)
         (etaf-sqlite-column :path "path" :type 'text)
         (etaf-sqlite-column :position "position" :type 'real)
         (etaf-sqlite-column :note "note" :type 'text)
         (etaf-sqlite-column :created "created" :type 'real))
   :id))

(defun etaf-video-player--history-store ()
  "Return the initialized store plist for history and bookmarks, or nil."
  (let ((file (etaf-video-player--history-path)))
    (cond
     ((and (equal file (plist-get etaf-video-player--history-store :file))
           (plist-get etaf-video-player--history-store :failed))
      nil)
     ((and (equal file (plist-get etaf-video-player--history-store :file))
           (plist-get etaf-video-player--history-store :history))
      etaf-video-player--history-store)
     (t
      (condition-case nil
          (let ((dir (file-name-directory file)))
            (when dir (make-directory dir t))
            (let* ((hdb (etaf-sqlite-initialize
                         (etaf-sqlite-database file (etaf-video-player--history-table))))
                   (bdb (etaf-sqlite-initialize
                         (etaf-sqlite-database file (etaf-video-player--bookmarks-table))))
                   (store (list :file file
                                :history (etaf-sqlite-source hdb)
                                :bookmarks (etaf-sqlite-source bdb))))
              (setq etaf-video-player--history-store store)))
        (error
         (setq etaf-video-player--history-store (list :file file :failed t))
         nil))))))

(defun etaf-video-player--source-load (source query limit)
  "Load up to LIMIT items matching QUERY from `etaf-sqlite-source' SOURCE."
  (plist-get (funcall (plist-get source :load) query 1 limit) :items))

(defun etaf-video-player-history-record (path position &optional duration)
  "Save playback POSITION (and optional DURATION) in seconds for local PATH."
  (when-let* ((key (etaf-video-player--history-key path))
              ((numberp position))
              ((>= position 0))
              (store (etaf-video-player--history-store))
              (source (plist-get store :history)))
    (ignore-errors
      (funcall (plist-get source :mutate)
               'upsert
               (list :path key
                     :position (float position)
                     :duration (and (numberp duration) (> duration 0) (float duration))
                     :updated (float-time)))
      (float position))))

(defun etaf-video-player-history-position (path)
  "Return saved (POSITION . DURATION) for PATH, or nil when absent."
  (when-let* ((key (etaf-video-player--history-key path))
              (store (etaf-video-player--history-store))
              (source (plist-get store :history))
              (row (car (ignore-errors
                          (etaf-video-player--source-load source (list :path key) 1)))))
    (cons (plist-get row :position) (plist-get row :duration))))

(defun etaf-video-player-history-recent (&optional limit)
  "Return up to LIMIT (default 40) recent history records, newest first."
  (when-let* ((store (etaf-video-player--history-store))
              (source (plist-get store :history))
              (rows (ignore-errors
                      (etaf-video-player--source-load source nil 500))))
    (let* ((cap (max 1 (or limit 40)))
           (sorted (sort (copy-sequence rows)
                         (lambda (a b)
                           (> (or (plist-get a :updated) 0)
                              (or (plist-get b :updated) 0))))))
      (mapcar (lambda (row)
                (list :path (plist-get row :path)
                      :position (plist-get row :position)
                      :duration (plist-get row :duration)
                      :updated-at (plist-get row :updated)))
              (seq-take sorted cap)))))

(defun etaf-video-player-history-delete (path)
  "Delete the saved playback history row for PATH."
  (when-let* ((key (etaf-video-player--history-key path))
              (store (etaf-video-player--history-store))
              (source (plist-get store :history)))
    (ignore-errors
      (funcall (plist-get source :mutate) 'delete (list :path key))
      t)))

(defun etaf-video-player-history-clear ()
  "Remove all saved playback history entries from the database."
  (interactive)
  (when-let* ((store (etaf-video-player--history-store))
              (source (plist-get store :history))
              (rows (ignore-errors
                      (etaf-video-player--source-load source nil 10000))))
    (dolist (row rows)
      (ignore-errors
        (funcall (plist-get source :mutate) 'delete (list :path (plist-get row :path)))))
    t))

(defun etaf-video-player-bookmarks (path)
  "Return saved timestamp bookmarks for PATH ordered by position."
  (when-let* ((key (etaf-video-player--history-key path))
              (store (etaf-video-player--history-store))
              (source (plist-get store :bookmarks))
              (rows (ignore-errors
                      (etaf-video-player--source-load source (list :path key) 500))))
    (let ((sorted (sort (copy-sequence rows)
                        (lambda (a b)
                          (let ((pa (or (plist-get a :position) 0))
                                (pb (or (plist-get b :position) 0)))
                            (if (= pa pb)
                                (< (or (plist-get a :created) 0)
                                   (or (plist-get b :created) 0))
                              (< pa pb)))))))
      (mapcar (lambda (row)
                (list :id (plist-get row :id)
                      :path (plist-get row :path)
                      :position (plist-get row :position)
                      :note (plist-get row :note)
                      :created-at (plist-get row :created)))
              sorted))))

(defun etaf-video-player-bookmark-add (path position &optional note)
  "Store a timestamp bookmark at POSITION seconds for PATH with optional NOTE."
  (when-let* ((key (etaf-video-player--history-key path))
              ((numberp position))
              ((>= position 0))
              (store (etaf-video-player--history-store))
              (source (plist-get store :bookmarks)))
    (let* ((now (float-time))
           (seq (cl-incf etaf-video-player--bookmark-seq))
           (id (format "bm-%d-%d" (round (* 1000000 now)) seq))
           (clean-note (if (stringp note) (string-trim note) "")))
      (when (ignore-errors
              (funcall (plist-get source :mutate)
                       'insert
                       (list :id id :path key :position (float position)
                             :note clean-note :created now))
              t)
        (list :id id :path key :position (float position)
              :note clean-note :created-at now)))))

(defun etaf-video-player-bookmark-remove (id)
  "Delete bookmark row ID from the database."
  (when-let* (((stringp id))
              (store (etaf-video-player--history-store))
              (source (plist-get store :bookmarks)))
    (ignore-errors
      (funcall (plist-get source :mutate) 'delete (list :id id))
      t)))

(provide 'etaf-video-player-history)
;;; etaf-video-player-history.el ends here
