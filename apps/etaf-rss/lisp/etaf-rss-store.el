;;; etaf-rss-store.el --- JSON persistence for etaf-rss -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader keeps its subscriptions, articles and reading state in one JSON
;; document.  Records are association lists exactly as `json-serialize'
;; writes them and `json-parse-string' reads them, so nothing here remaps a
;; structure between an in-memory and an on-disk shape.  What this layer adds
;; is tolerance: a missing file is an empty reader, a damaged file is kept
;; aside instead of being overwritten, and retention rules bound the file so
;; a feed that publishes its whole history every day cannot grow it forever.
;;
;; Shape (schema 1):
;;
;;   ((schema . 1)
;;    (feeds . [((id . …) (url . …) (title . …) (site . …) (folder . …)
;;               (updated . FLOAT) (last_fetch . FLOAT) (etag . …)
;;               (last_modified . …) (error . …)) …])
;;    (articles . [((id . …) (feed . …) (feed-title . …) (title . …)
;;                  (url . …) (author . …) (published . FLOAT) (added . FLOAT)
;;                  (summary . …) (content . …) (read . BOOL)
;;                  (starred . BOOL)) …])
;;    (settings . ((theme . "dark") …)))

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'etaf-rss-theme)

(defcustom etaf-rss-data-file
  (expand-file-name "etaf-rss/data.json" user-emacs-directory)
  "JSON file the reader stores its subscriptions and reading state in.
Bind it before creating a session to keep several profiles apart or to use a
disposable file."
  :type 'file
  :group 'etaf-rss)

(defconst etaf-rss--store-schema 1
  "Schema version written by this release.")

(defvar etaf-rss-store-error nil
  "Message of the last `etaf-rss-store-read' or write problem, or nil.
A reader shows it in the status line while continuing with an empty store,
so a damaged file never makes the interface unusable.")

(defun etaf-rss-store-default ()
  "Return a fresh empty store."
  (list (cons 'schema etaf-rss--store-schema)
        (cons 'feeds [])
        (cons 'articles [])
        (cons 'settings (list (cons 'theme "dark")))))

(defun etaf-rss-store-read (file)
  "Read the store of FILE and return it, or a fresh store.
A missing FILE is not an error: it is a reader with no subscriptions yet.  A
file that cannot be parsed is renamed aside (FILE.bad) and the returned store
is empty, so the damaged contents stay recoverable instead of being
overwritten by the next save.  Problems are reported through
`etaf-rss-store-error'."
  (setq etaf-rss-store-error nil)
  (cond
   ((not (file-exists-p file)) (etaf-rss-store-default))
   (t
    (condition-case error
        (let* ((text (with-temp-buffer
                       (let ((coding-system-for-read 'utf-8))
                         (insert-file-contents file))
                       (buffer-substring-no-properties (point-min) (point-max))))
               (data (json-parse-string (string-trim text)
                                        :object-type 'alist
                                        :array-type 'array
                                        :false-object :false
                                        :null-object nil)))
          (unless (alist-get 'schema data)
            (signal 'etaf-rss-error
                    (list "store has no schema")) )
          (etaf-rss-store-normalize data))
      (error
       (let ((backup (concat file ".bad")))
         (ignore-errors (rename-file file backup t))
         (setq etaf-rss-store-error
               (format "数据文件无法读取（已移到 %s）：%s"
                       (file-name-nondirectory backup)
                       (error-message-string error)))
         (etaf-rss-store-default)))))))

(defun etaf-rss-store-normalize (data)
  "Return DATA as a complete, typed store.
Fields a stored file is missing (an older writer, a hand-edited file) take
their defaults; records without an ID are dropped because nothing can refer
to them."
  (let ((feeds (alist-get 'feeds data))
        (articles (alist-get 'articles data))
        (settings (alist-get 'settings data)))
    (list (cons 'schema etaf-rss--store-schema)
          (cons 'feeds
                (vconcat
                 (delq nil
                       (mapcar (lambda (feed)
                                 (when (alist-get 'id feed)
                                   (list (cons 'id (alist-get 'id feed))
                                         (cons 'url (or (alist-get 'url feed) ""))
                                         (cons 'title (or (alist-get 'title feed) ""))
                                         (cons 'site (or (alist-get 'site feed) ""))
                                         (cons 'folder (or (alist-get 'folder feed) ""))
                                         (cons 'updated (alist-get 'updated feed))
                                         (cons 'last_fetch (alist-get 'last_fetch feed))
                                         (cons 'etag (alist-get 'etag feed))
                                         (cons 'last_modified (alist-get 'last_modified feed))
                                         (cons 'error (alist-get 'error feed)))))
                               (append feeds nil)))))
          (cons 'articles
                (vconcat
                 (delq nil
                       (mapcar (lambda (article)
                                 (when (alist-get 'id article)
                                   (list (cons 'id (alist-get 'id article))
                                         (cons 'feed (alist-get 'feed article))
                                         (cons 'feed-title (or (alist-get 'feed-title article) ""))
                                         (cons 'title (or (alist-get 'title article) ""))
                                         (cons 'url (or (alist-get 'url article) ""))
                                         (cons 'author (or (alist-get 'author article) ""))
                                         (cons 'published (alist-get 'published article))
                                         (cons 'added (or (alist-get 'added article) 0))
                                         (cons 'summary (or (alist-get 'summary article) ""))
                                         (cons 'content (or (alist-get 'content article) ""))
                                         (cons 'read (eq t (alist-get 'read article)))
                                         (cons 'starred (eq t (alist-get 'starred article))))))
                               (append articles nil)))))
          (cons 'settings
                (list (cons 'theme
                            (or (alist-get 'theme settings) "dark")))))))

(defun etaf-rss-store--feed-json (feed)
  "Return FEED with JSON-safe values.
`json-serialize' turns a nil alist value into an empty object, not null, so
every absent value is written as an explicit null and every boolean as
`t'/`:false'."
  (list (cons 'id (alist-get 'id feed))
        (cons 'url (or (alist-get 'url feed) ""))
        (cons 'title (or (alist-get 'title feed) ""))
        (cons 'site (or (alist-get 'site feed) ""))
        (cons 'folder (or (alist-get 'folder feed) ""))
        (cons 'updated (or (alist-get 'updated feed) :null))
        (cons 'last_fetch (or (alist-get 'last_fetch feed) :null))
        (cons 'etag (or (alist-get 'etag feed) ""))
        (cons 'last_modified (or (alist-get 'last_modified feed) ""))
        (cons 'error (or (alist-get 'error feed) ""))))

(defun etaf-rss-store--article-json (article)
  "Return ARTICLE with JSON-safe values."
  (list (cons 'id (alist-get 'id article))
        (cons 'feed (alist-get 'feed article))
        (cons 'feed-title (or (alist-get 'feed-title article) ""))
        (cons 'title (or (alist-get 'title article) ""))
        (cons 'url (or (alist-get 'url article) ""))
        (cons 'author (or (alist-get 'author article) ""))
        (cons 'published (or (alist-get 'published article) :null))
        (cons 'added (or (alist-get 'added article) :null))
        (cons 'summary (or (alist-get 'summary article) ""))
        (cons 'content (or (alist-get 'content article) ""))
        (cons 'read (if (eq t (alist-get 'read article)) t :false))
        (cons 'starred (if (eq t (alist-get 'starred article)) t :false))))

(defun etaf-rss-store-write (file store)
  "Write STORE to FILE atomically and return FILE.
A missing directory is created.  The document is written to a neighbour and
renamed over the target, so an interrupted save never leaves half a store.
The store is normalized and mapped to JSON-safe values first, so what lands
on disk always matches the documented schema."
  (setq etaf-rss-store-error nil)
  (let* ((store (etaf-rss-store-normalize store))
         (document (list (cons 'schema etaf-rss--store-schema)
                         (cons 'feeds
                               (vconcat (mapcar #'etaf-rss-store--feed-json
                                                (append (alist-get 'feeds store) nil))))
                         (cons 'articles
                               (vconcat (mapcar #'etaf-rss-store--article-json
                                                (append (alist-get 'articles store) nil))))
                         (cons 'settings (alist-get 'settings store))))
         (directory (file-name-directory file)))
    (unless (file-directory-p directory)
      (make-directory directory t))
    (condition-case error
        (let ((temporary (make-temp-file (expand-file-name ".etaf-rss-" directory) nil ".json"))
              (coding-system-for-write 'utf-8))
          (with-temp-buffer
            (insert (json-serialize document))
            (write-region (point-min) (point-max) temporary nil 'quiet))
          (rename-file temporary file t)
          file)
      (error
       (setq etaf-rss-store-error (error-message-string error))
       (signal 'etaf-rss-error
               (list (format "无法保存数据文件 %s：%s" file (error-message-string error))))))))

(defun etaf-rss-store-prune (store &optional per-feed starred-limit)
  "Enforce retention in STORE and return it.
Each feed keeps its newest PER-FEED articles (default 200) and any starred
article older than that cut is kept while the reader holds fewer than
STARED-LIMIT starred articles (default 1000).  Articles of a feed that is no
longer subscribed are dropped unless they are starred, so unsubscribing does
not orphan content.  The surviving articles are sorted newest first, which is
the order every reply wants."
  (let* ((per-feed (or per-feed 200))
         (starred-limit (or starred-limit 1000))
         (feeds (append (alist-get 'feeds store) nil))
         (articles (append (alist-get 'articles store) nil))
         (feed-ids (mapcar (lambda (feed) (alist-get 'id feed)) feeds))
         (by-feed (make-hash-table :test 'equal))
         (kept nil)
         (starred-kept nil))
    (dolist (article articles)
      (push article (gethash (alist-get 'feed article) by-feed)))
    (maphash
     (lambda (feed-id bucket)
       (let ((count 0))
         (dolist (article (sort bucket
                                 (lambda (a b)
                                   (> (or (alist-get 'published a) (alist-get 'added a) 0)
                                      (or (alist-get 'published b) (alist-get 'added b) 0)))))
           (let ((fresh (and (member feed-id feed-ids) (< count per-feed))))
             (when fresh (cl-incf count))
             (when (or fresh (eq t (alist-get 'starred article)))
               (push article kept)
               (when (eq t (alist-get 'starred article))
                 (push article starred-kept)))))))
     by-feed)
    ;; A reader only keeps so many starred articles; the oldest beyond the
    ;; limit leave the store, newest first.
    (let ((excess (nthcdr starred-limit
                          (sort starred-kept
                                (lambda (a b)
                                  (> (or (alist-get 'published a) (alist-get 'added a) 0)
                                     (or (alist-get 'published b) (alist-get 'added b) 0)))))))
      (when excess
        (setq kept (seq-difference kept excess))))
    (setf (alist-get 'articles store)
          (vconcat (sort kept (lambda (a b)
                                (> (or (alist-get 'published a) (alist-get 'added a) 0)
                                   (or (alist-get 'published b) (alist-get 'added b) 0))))))
    (setf (alist-get 'schema store) etaf-rss--store-schema)
    store))

(provide 'etaf-rss-store)
;;; etaf-rss-store.el ends here
