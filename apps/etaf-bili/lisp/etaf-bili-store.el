;;; etaf-bili-store.el --- SQLite persistence for playback progress and prefs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Fail-open SQLite persistence via `etaf-db':
;; - `progress' table: exact playback position per (bvid, cid) for instant resume
;; - `prefs' table: user viewing defaults (audio, volume, speed, quality,
;;   subtitle, danmaku, auto-next, search history)
;;
;; When `etaf-db' or SQLite support is unavailable, every read returns nil and
;; every write is a safe no-op; the client keeps an in-memory fallback so
;; sessions remain fully usable.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'etaf-bili-service)
(require 'etaf-db nil t)

(declare-function etaf-sqlite-table "etaf-db" (id columns &optional primary-key))
(declare-function etaf-sqlite-column "etaf-db" (id sql-name &rest options))
(declare-function etaf-sqlite-database "etaf-db" (file table))
(declare-function etaf-sqlite-source "etaf-db" (database))
(declare-function etaf-sqlite-initialize "etaf-db" (database))

(defcustom etaf-bili-store-file nil
  "SQLite database file for `etaf-bili' watch progress and preferences.
Nil places `state.sqlite3' under `etaf-bili-state-directory'."
  :type '(choice (const :tag "Under state directory" nil) file)
  :group 'etaf-bili)

(defconst etaf-bili-store--resume-min-seconds 5
  "Positions at or below this threshold restart from zero.")

(defconst etaf-bili-store--resume-end-margin 12
  "Positions within this margin of the end are treated as finished.")

(defconst etaf-bili-store--progress-table
  (when (fboundp 'etaf-sqlite-table)
    (etaf-sqlite-table
     'bili_progress
     (list (etaf-sqlite-column :key "key" :type 'text :primary t)
           (etaf-sqlite-column :bvid "bvid" :type 'text)
           (etaf-sqlite-column :cid "cid" :type 'integer)
           (etaf-sqlite-column :position "position" :type 'real)
           (etaf-sqlite-column :duration "duration" :type 'real)
           (etaf-sqlite-column :title "title" :type 'text :nullable t)
           (etaf-sqlite-column :updated "updated" :type 'real))
     :key))
  "SQLite table storing watch resume positions keyed by `bvid:cid'.")

(defconst etaf-bili-store--prefs-table
  (when (fboundp 'etaf-sqlite-table)
    (etaf-sqlite-table
     'bili_prefs
     (list (etaf-sqlite-column :key "key" :type 'text :primary t)
           (etaf-sqlite-column :value "value" :type 'text)
           (etaf-sqlite-column :updated "updated" :type 'real))
     :key))
  "SQLite table storing user viewing preferences as JSON values.")

(defvar etaf-bili-store--handles nil
  "Cached SQLite handles plist (:file :progress :prefs), or nil.")

(defvar etaf-bili-store--mem-progress (make-hash-table :test #'equal)
  "In-memory fallback for watch progress when SQLite is unavailable.")

(defvar etaf-bili-store--mem-prefs (make-hash-table :test #'equal)
  "In-memory fallback for viewing preferences when SQLite is unavailable.")

(defun etaf-bili-store--file ()
  "Return the resolved SQLite database file path."
  (expand-file-name
   (or etaf-bili-store-file
       (expand-file-name "state.sqlite3" etaf-bili-state-directory))))

(defun etaf-bili-store--open-table (file table)
  "Initialize TABLE in FILE and return (:load FN :mutate FN), or nil."
  (when table
    (condition-case nil
        (let* ((db (etaf-sqlite-database file table))
               (src (etaf-sqlite-source db)))
          (etaf-sqlite-initialize db)
          (list :load (plist-get src :load)
                :mutate (plist-get src :mutate)))
      (error nil))))

(defun etaf-bili-store--handles ()
  "Return the active SQLite handles plist, opening lazily."
  (let ((file (etaf-bili-store--file)))
    (if (and etaf-bili-store--handles
             (equal file (plist-get etaf-bili-store--handles :file)))
        etaf-bili-store--handles
      (clrhash etaf-bili-store--mem-progress)
      (clrhash etaf-bili-store--mem-prefs)
      (condition-case nil
          (progn
            (make-directory (file-name-directory file) t)
            (setq etaf-bili-store--handles
                  (list :file file
                        :progress (etaf-bili-store--open-table file etaf-bili-store--progress-table)
                        :prefs (etaf-bili-store--open-table file etaf-bili-store--prefs-table))))
        (error nil)))))

(defun etaf-bili-store--progress-key (bvid cid)
  "Build the primary key string for BVID and CID."
  (format "%s:%s" (or bvid "") (or cid 0)))

(defun etaf-bili-store-progress-put (bvid cid position duration &optional title)
  "Record playback POSITION and DURATION for BVID and CID."
  (when (and (stringp bvid) (not (string-empty-p bvid)) (numberp position))
    (let* ((cid-num (if (numberp cid) cid 0))
           (key (etaf-bili-store--progress-key bvid cid-num))
           (pos (max 0.0 (float position)))
           (dur (max 0.0 (float (or duration 0))))
           (now (float-time))
           (row (list :key key :bvid bvid :cid cid-num
                      :position pos :duration dur
                      :title (or title "") :updated now))
           (h (plist-get (etaf-bili-store--handles) :progress)))
      (puthash key (cons pos dur) etaf-bili-store--mem-progress)
      (puthash (etaf-bili-store--progress-key bvid 0) (cons pos dur)
               etaf-bili-store--mem-progress)
      (when h
        (ignore-errors
          (funcall (plist-get h :mutate) 'upsert row)
          (when (> cid-num 0)
            (funcall (plist-get h :mutate) 'upsert
                     (plist-put (copy-sequence row)
                                :key (etaf-bili-store--progress-key bvid 0))))))
      pos)))

(defun etaf-bili-store-progress-get (bvid &optional cid)
  "Return saved `(POSITION . DURATION)' for BVID (and optional CID), or nil."
  (when (and (stringp bvid) (not (string-empty-p bvid)))
    (let* ((cid-num (if (numberp cid) cid 0))
           (key (etaf-bili-store--progress-key bvid cid-num))
           (h (plist-get (etaf-bili-store--handles) :progress)))
      (if h
          (condition-case nil
              (when-let* ((row (car (plist-get (funcall (plist-get h :load)
                                                        (list :key key) 1 1)
                                               :items))))
                (cons (plist-get row :position) (plist-get row :duration)))
            (error (gethash key etaf-bili-store--mem-progress)))
        (gethash key etaf-bili-store--mem-progress)))))

(defun etaf-bili-store-resume-seconds (bvid &optional cid cloud-seconds duration)
  "Return the effective resume second for BVID/CID, or 0 near start/end.
Compares local progress and CLOUD-SECONDS, picking the further valid point."
  (let* ((local (etaf-bili-store-progress-get bvid cid))
         (local-pos (or (car-safe local) 0.0))
         (dur (or (and (numberp duration) (> duration 0) (float duration))
                  (cdr-safe local) 0.0))
         (cloud (if (and (numberp cloud-seconds) (> cloud-seconds 0))
                    (float cloud-seconds) 0.0))
         (best (max local-pos cloud)))
    (if (and (> best etaf-bili-store--resume-min-seconds)
             (or (<= dur 0)
                 (< best (- dur etaf-bili-store--resume-end-margin))))
        best
      0.0)))

(defun etaf-bili-store-pref-put (key value)
  "Persist preference KEY with JSON-serializable VALUE."
  (let* ((k (format "%s" key))
         (json-val (cond
                    ((null value) :false)
                    ((listp value) (vconcat value))
                    (t value)))
         (encoded (json-serialize (list :v json-val)))
         (h (plist-get (etaf-bili-store--handles) :prefs)))
    (puthash k value etaf-bili-store--mem-prefs)
    (when h
      (ignore-errors
        (funcall (plist-get h :mutate) 'upsert
                 (list :key k :value encoded :updated (float-time)))))
    value))

(defun etaf-bili-store-pref-get (key &optional default)
  "Return persisted preference for KEY, or DEFAULT when absent."
  (let* ((k (format "%s" key))
         (h (plist-get (etaf-bili-store--handles) :prefs)))
    (if h
        (condition-case nil
            (if-let* ((row (car (plist-get (funcall (plist-get h :load)
                                                    (list :key k) 1 1)
                                           :items)))
                      (raw (plist-get row :value))
                      (parsed (json-parse-string raw :object-type 'plist
                                                 :array-type 'list
                                                 :null-object nil
                                                 :false-object :false)))
                (let ((v (plist-get parsed :v)))
                  (if (eq v :false) nil v))
              default)
          (error default))
      (let ((m (gethash k etaf-bili-store--mem-prefs :missing)))
        (if (eq m :missing) default m)))))

(defun etaf-bili-store-search-history-add (keyword)
  "Record KEYWORD at the front of the recent search history (max 12)."
  (let ((clean (string-trim (or keyword ""))))
    (unless (string-empty-p clean)
      (let* ((prev (etaf-bili-store-pref-get "search-history" nil))
             (next (seq-take (cons clean (delete clean (copy-sequence prev))) 12)))
        (etaf-bili-store-pref-put "search-history" next)))))

(defun etaf-bili-store-search-history ()
  "Return the list of recent search keywords."
  (etaf-bili-store-pref-get "search-history" nil))

(provide 'etaf-bili-store)
;;; etaf-bili-store.el ends here
