;;; etaf-video-player-history.el --- Playback positions in a small database -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Where each local video stopped, so reopening it continues instead of
;; restarting.  One SQLite table built with `etaf-db' keeps one row per file:
;; the playback position, the source duration and when it was written.  The
;; table only grows with the number of files a user watches, and every read is
;; an equality lookup on the primary key.
;;
;; Everything fails open: an unavailable SQLite, a corrupt file or a schema
;; mismatch turns history off and leaves the player fully usable.  The
;; database opens lazily on the first question and is shared for the session.

;;; Code:

(require 'cl-lib)
(require 'etaf-db nil t)
;; Optional at runtime, but declaring the interface keeps compilation
;; warning-free when etaf-db is not installed.
(declare-function etaf-sqlite-table "etaf-db" (id columns &optional primary-key))
(declare-function etaf-sqlite-column "etaf-db" (id sql-name &rest options))
(declare-function etaf-sqlite-database "etaf-db" (file table))
(declare-function etaf-sqlite-source "etaf-db" (database))
(declare-function etaf-sqlite-initialize "etaf-db" (database))

(defcustom etaf-video-player-history-file nil
  "Database file holding saved playback positions.
Nil uses `etaf-video-player/history.sqlite3' under the Emacs user directory.
Set it to a different file to isolate a session; a value that cannot be
opened disables history instead of signaling."
  :type '(choice (const :tag "User directory" nil) file)
  :group 'etaf-video-player)

(defconst etaf-video-player-history--table
  (when (fboundp 'etaf-sqlite-table)
    (etaf-sqlite-table
   'playback
   (list (etaf-sqlite-column :path "path" :type 'text :primary t)
         (etaf-sqlite-column :position "position" :type 'real)
         (etaf-sqlite-column :duration "duration" :type 'real)
         (etaf-sqlite-column :updated "updated" :type 'real))
     :path))
  "The playback table: one row per watched file, keyed by its path.
Nil when this Emacs lacks `etaf-db' or SQLite support; playback still works.")

(defvar etaf-video-player-history--handle nil
  "Cached history handle as a plist, or nil when unavailable.
The plist carries the file it was opened from plus the `:load' and `:mutate'
capability functions of the SQLite source; each call opens its own short
connection, so the handle owns no database resource.")

(defun etaf-video-player-history--open (file)
  "Open FILE as the playback database and return a handle, or nil.
Creating the file, the table and the handle all fail open."
  (condition-case nil
      (let ((file (expand-file-name file)))
        (unless etaf-video-player-history--table
          (error "Playback history needs etaf-db with SQLite"))
        (make-directory (file-name-directory file) t)
        (let* ((database (etaf-sqlite-database file etaf-video-player-history--table))
               (source (etaf-sqlite-source database)))
          (etaf-sqlite-initialize database)
          (list :file file
                :load (plist-get source :load)
                :mutate (plist-get source :mutate))))
    (error nil)))

(defun etaf-video-player-history--database ()
  "Return the session history handle, opening it on first use.
A different `etaf-video-player-history-file' replaces the cached handle."
  (let ((file (or etaf-video-player-history-file
                  (locate-user-emacs-file "etaf-video-player/history.sqlite3"))))
    (if (and etaf-video-player-history--handle
             (equal file (plist-get etaf-video-player-history--handle :file)))
        etaf-video-player-history--handle
      (setq etaf-video-player-history--handle
            (etaf-video-player-history--open file)))))

(defun etaf-video-player-history-position (path)
  "Return PATH's saved playback record as `(POSITION . DURATION)', or nil.
A missing database, a missing row and any read failure all return nil."
  (when (and (stringp path) (not (string-empty-p path)))
    (when-let* ((handle (etaf-video-player-history--database)))
      (condition-case nil
          (when-let* ((row (car (plist-get (funcall (plist-get handle :load)
                                                    (list :path path) 1 1)
                                          :items))))
            (cons (plist-get row :position) (plist-get row :duration)))
        (error nil)))))

(defun etaf-video-player-history-record (path position duration)
  "Save PATH's playback POSITION and source DURATION.
A row already present for PATH is replaced.  Returns POSITION on success and
nil when history is unavailable; never signals."
  (when (and (stringp path) (not (string-empty-p path)) (numberp position))
    (when-let* ((handle (etaf-video-player-history--database)))
      (condition-case nil
          (progn
            (funcall (plist-get handle :mutate) 'upsert
                     (list :path path
                           :position (float position)
                           :duration (float (or duration 0))
                           :updated (float-time)))
            position)
        (error nil)))))

(provide 'etaf-video-player-history)
;;; etaf-video-player-history.el ends here
