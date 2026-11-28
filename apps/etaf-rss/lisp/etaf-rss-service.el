;;; etaf-rss-service.el --- Feed storage and fetching for etaf-rss -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The service is the reader's only door to the outside world: it owns the
;; JSON store, fetches and parses feeds over HTTP(S), merges new articles
;; while preserving read and starred state, answers scoped queries, and
;; imports and exports OPML.  It knows nothing about ETAF, buffers or views,
;; so a whole session can run headless.
;;
;; Requests are plists and every call is asynchronous: CALLBACK receives
;; exactly one (:ok DATA) or (:error MESSAGE :hint HINT), from a timer for a
;; local query or from the network callback of a fetch.  Tests replace the
;; transport by binding `etaf-rss-client-factory' to a function that returns a
;; two-argument client, so no scenario needs the network.
;;
;; A client is one of: the local client from `etaf-rss-make-client', a
;; function of (REQUEST CALLBACK), or a plist (:call FUNCTION [:cancel
;; FUNCTION]) for a backend that owns requests of its own.  Only the local
;; client keeps a store; `etaf-rss-miniflux-client' is such a plist client and
;; speaks a server's API instead.
;;
;; Operations:
;;
;;   (:op :snapshot)                       feeds, totals and preferences
;;   (:op :feeds)                          sidebar feeds with unread counts
;;   (:op :articles :scope SCOPE)          rows of one scope
;;   (:op :article :id ID)                 one article with its HTML
;;   (:op :mark-read :ids (…) :read BOOL)  set read state of articles
;;   (:op :mark-read-scope :scope S :read BOOL)
;;   (:op :star :id ID :starred BOOL)      set one article's star
;;   (:op :set-theme :theme "dark")        remember the chosen appearance
;;   (:op :add-feed :url URL)              subscribe; fetches and merges now
;;   (:op :refresh :id ID)                 re-fetch one feed (conditional GET)
;;   (:op :remove-feed :id ID)             unsubscribe (starred articles stay)
;;   (:op :move-feed :id ID :folder NAME)  file a feed under a folder
;;   (:op :opml-import :path FILE)         add subscriptions from OPML
;;   (:op :opml-export :path FILE)         write subscriptions as OPML
;;   (:op :flush)                          persist pending changes now
;;
;; SCOPE is a plist: (:kind :all), (:kind :unread), (:kind :starred),
;; (:kind :feed :id ID), (:kind :folder :name NAME) or
;; (:kind :search :query TEXT).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'url-util)
(require 'etaf-rss-theme)
(require 'etaf-rss-parse)
(require 'etaf-rss-store)

(declare-function url-http-response-status "url-http" (&optional noerror))

(defcustom etaf-rss-request-timeout 20
  "Seconds before one feed request is abandoned.
The timer kills the transfer, so a hung server cannot leave a refresh
pending forever; the caller sees a readable timeout error."
  :type 'number
  :group 'etaf-rss)

(defcustom etaf-rss-articles-per-feed 200
  "Newest articles kept for one feed.
Older articles are pruned, except starred ones; see
`etaf-rss-store-prune'."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-starred-limit 1000
  "Most starred articles the reader keeps."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-search-limit 200
  "Most rows one search returns."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-save-delay 1.5
  "Seconds of quiet before a changed store is written to disk.
Read and star actions land immediately in memory; the debounce keeps a burst
of them from serializing the file once per keystroke."
  :type 'number
  :group 'etaf-rss)

(defcustom etaf-rss-user-agent
  (format "etaf-rss/0.1 (Emacs %s)" emacs-version)
  "User-Agent header sent with every feed request."
  :type 'string
  :group 'etaf-rss)

(defvar etaf-rss-client-factory nil
  "Function returning the client of new sessions.
It is called with no arguments and must return a client built by
`etaf-rss-make-client', or any function accepting (REQUEST CALLBACK) as
`etaf-rss-client-call' documents.  Nil selects the default client; tests bind
this to a scripted client.")

(cl-defstruct (etaf-rss--client (:constructor etaf-rss--client-create))
  "Local backend client that owns the store and fetches feeds."
  store file timeout queue busy pending save-timer)

(cl-defstruct (etaf-rss--pending (:constructor etaf-rss--pending-create))
  "One queued or in-flight feed request."
  url callback cancelled delivered buffer timer)

;;; ---------------------------------------------------------------------------
;;; Construction and entry
;;; ---------------------------------------------------------------------------

(cl-defun etaf-rss-make-client (&key data-file timeout)
  "Create a client whose store lives in DATA-FILE.
DATA-FILE and TIMEOUT default to `etaf-rss-data-file' and
`etaf-rss-request-timeout'.  The store is read lazily on the first request,
so constructing a client touches no disk."
  (etaf-rss--client-create
   :file (expand-file-name (or data-file etaf-rss-data-file))
   :timeout (or timeout etaf-rss-request-timeout)))

(defun etaf-rss-client-call (client request callback)
  "Send REQUEST through CLIENT and deliver the reply to CALLBACK.
CLIENT is a client from `etaf-rss-make-client', a function of two arguments
(REQUEST CALLBACK), or a plist (:call FUNCTION [:cancel FUNCTION]); the last
two are how another backend or a test drives the same reader.

CALLBACK receives exactly one of (:ok DATA) or (:error MESSAGE :hint HINT).
Local queries and mutations answer from a timer and network fetches from the
transfer callback, so the call never blocks the caller."
  (let ((call (cond ((etaf-rss--client-p client) nil)
                    ((functionp client) client)
                    ((consp client) (plist-get client :call))
                    (t nil))))
    (cond ((etaf-rss--client-p client)
           (etaf-rss--client-dispatch client request callback))
          ((functionp call) (funcall call request callback))
          (t (signal 'etaf-rss-error (list (format "Not a backend client: %S" client)))))))

(defun etaf-rss-cancel (client)
  "Abandon CLIENT's queued and in-flight requests and persist its store.
Cancelled requests never run their callbacks, and a session can keep using
the same client afterwards.  Return the number of abandoned transfers."
  (when-let* ((cancel (and (consp client) (plist-get client :cancel))))
    (funcall cancel))
  (let ((count 0))
    (when (etaf-rss--client-p client)
      (etaf-rss--client-save client)
      (dolist (pending (etaf-rss--client-pending client))
        (setf (etaf-rss--pending-cancelled pending) t)
        (when-let* ((timer (etaf-rss--pending-timer pending)))
          (cancel-timer timer))
        (when-let* ((buffer (etaf-rss--pending-buffer pending)))
          (when (buffer-live-p buffer)
            (cl-incf count)
            (with-current-buffer buffer
              (when-let* ((process (get-buffer-process buffer)))
                (when (process-live-p process) (delete-process process))))
            (kill-buffer buffer))))
      (setf (etaf-rss--client-pending client) nil
            (etaf-rss--client-queue client) nil
            (etaf-rss--client-busy client) nil))
    count))

;;; ---------------------------------------------------------------------------
;;; Store access and persistence
;;; ---------------------------------------------------------------------------

(defun etaf-rss--client-ensure-store (client)
  "Return CLIENT's store, reading it from disk on first use."
  (or (etaf-rss--client-store client)
      (setf (etaf-rss--client-store client)
            (etaf-rss-store-read (etaf-rss--client-file client)))))

(defun etaf-rss--client-dirty (client)
  "Schedule CLIENT's store to be written once its changes settle."
  (when-let* ((timer (etaf-rss--client-save-timer client)))
    (cancel-timer timer))
  (setf (etaf-rss--client-save-timer client)
        (run-at-time etaf-rss-save-delay nil
                     (lambda () (etaf-rss--client-save client)))))

(defun etaf-rss--client-save (client)
  "Write CLIENT's store to disk now, if it has one loaded."
  (when-let* ((timer (etaf-rss--client-save-timer client)))
    (cancel-timer timer)
    (setf (etaf-rss--client-save-timer client) nil))
  (when (etaf-rss--client-store client)
    (condition-case error
        (etaf-rss-store-write (etaf-rss--client-file client)
                              (etaf-rss-store-prune
                               (etaf-rss--client-store client)
                               etaf-rss-articles-per-feed
                               etaf-rss-starred-limit))
      (error (setq etaf-rss-store-error (error-message-string error))))))

(defun etaf-rss--deliver (_client callback value)
  "Deliver VALUE to CALLBACK on the event loop.
Local operations answer a tick later so a caller never runs a model callback
inside its own action; that keeps a reply from a superseded request from
being mistaken for a fresh one."
  (run-at-time 0 nil (lambda () (funcall callback value))))

(defun etaf-rss--client-dispatch (client request callback)
  "Handle REQUEST for CLIENT, answering through CALLBACK."
  (condition-case error
      (progn
        (etaf-rss--client-ensure-store client)
        (pcase (plist-get request :op)
          (:snapshot
           (etaf-rss--deliver client callback (list :ok (etaf-rss--snapshot client))))
          (:feeds
           (etaf-rss--deliver client callback (list :ok (etaf-rss--feeds-reply client))))
          (:articles
           (etaf-rss--deliver client callback
                              (list :ok (etaf-rss--rows-reply client
                                                              (plist-get request :scope)))))
          (:article
           (etaf-rss--deliver client callback
                              (etaf-rss--article-reply client (plist-get request :id))))
          (:mark-read
           (etaf-rss--deliver client callback
                              (etaf-rss--mark-read client request)))
          (:mark-read-scope
           (etaf-rss--deliver client callback
                              (etaf-rss--mark-read-scope client request)))
          (:star
           (etaf-rss--deliver client callback (etaf-rss--set-star client request)))
          (:set-theme
           (etaf-rss--deliver client callback (etaf-rss--set-theme client request)))
          (:add-feed
           (etaf-rss--add-feed client (plist-get request :url)
                               (plist-get request :folder) callback))
          (:refresh
           (etaf-rss--refresh-feed client (plist-get request :id) callback))
          (:remove-feed
           (etaf-rss--deliver client callback
                              (etaf-rss--remove-feed client (plist-get request :id))))
          (:move-feed
           (etaf-rss--deliver client callback
                              (etaf-rss--move-feed client request)))
          (:opml-import
           (etaf-rss--deliver client callback
                              (etaf-rss--opml-import client (plist-get request :path))))
          (:opml-export
           (etaf-rss--deliver client callback
                              (etaf-rss--opml-export client (plist-get request :path))))
          (:flush
           (etaf-rss--client-save client)
           (etaf-rss--deliver client callback (list :ok t)))
          (_ (signal 'etaf-rss-error
                     (list (format "Unknown request: %S" request))))))
    (etaf-rss-error
     (etaf-rss--deliver client callback (list :error (error-message-string error))))
    (error
     (etaf-rss--deliver client callback
                        (list :error (error-message-string error))))))

;;; ---------------------------------------------------------------------------
;;; Store projections
;;; ---------------------------------------------------------------------------

(defun etaf-rss--client-feeds (client)
  "Return CLIENT's feeds as a list."
  (append (alist-get 'feeds (etaf-rss--client-ensure-store client)) nil))

(defun etaf-rss--client-articles (client)
  "Return CLIENT's articles as a list, newest first."
  (append (alist-get 'articles (etaf-rss--client-ensure-store client)) nil))

(defun etaf-rss--feed-by-id (client id)
  "Return CLIENT's feed record for ID, or nil."
  (seq-find (lambda (feed) (equal (alist-get 'id feed) id))
            (etaf-rss--client-feeds client)))

(defun etaf-rss--article-by-id (client id)
  "Return CLIENT's article record for ID, or nil."
  (seq-find (lambda (article) (equal (alist-get 'id article) id))
            (etaf-rss--client-articles client)))

(defun etaf-rss--article-rank (article)
  "Return ARTICLE's sort key: its publish time, or when it arrived."
  (let ((published (alist-get 'published article))
        (added (alist-get 'added article)))
    (cond ((and (numberp published) (> published 0)) published)
          ((and (numberp added) (> added 0)) added)
          (t 0))))

(defun etaf-rss--counts (client)
  "Return a hash of feed ID to (UNREAD . TOTAL) for CLIENT."
  (let ((counts (make-hash-table :test 'equal)))
    (dolist (article (etaf-rss--client-articles client))
      (let* ((id (alist-get 'feed article))
             (entry (gethash id counts (cons 0 0))))
        (puthash id (cons (+ (car entry) (if (eq t (alist-get 'read article)) 0 1))
                          (1+ (cdr entry)))
                 counts)))
    counts))

(defun etaf-rss--feed-row (feed counts)
  "Return FEED as the plist the model keeps, with COUNTS from `etaf-rss--counts'."
  (let ((entry (gethash (alist-get 'id feed) counts (cons 0 0))))
    (list :id (alist-get 'id feed)
          :url (alist-get 'url feed)
          :title (let ((title (alist-get 'title feed)))
                   (if (or (null title) (string-empty-p title))
                       (or (alist-get 'url feed) "未命名订阅")
                     title))
          :site (alist-get 'site feed)
          :folder (or (alist-get 'folder feed) "")
          :unread (car entry)
          :total (cdr entry)
          :updated (alist-get 'updated feed)
          :last-fetch (alist-get 'last_fetch feed)
          :error (let ((error (alist-get 'error feed)))
                   (and error (not (string-empty-p error)) error)))))

(defun etaf-rss--feeds-reply (client)
  "Return the sidebar reply of CLIENT: feeds with counts and reader totals."
  (let* ((counts (etaf-rss--counts client))
         (rows (mapcar (lambda (feed) (etaf-rss--feed-row feed counts))
                       (etaf-rss--client-feeds client)))
         (rows (sort rows
                     (lambda (a b)
                       (let ((folder-a (or (plist-get a :folder) ""))
                             (folder-b (or (plist-get b :folder) "")))
                         (cond ((and (string-empty-p folder-a)
                                     (not (string-empty-p folder-b))) t)
                               ((and (string-empty-p folder-b)
                                     (not (string-empty-p folder-a))) nil)
                               ((not (equal folder-a folder-b))
                                (string-lessp folder-a folder-b))
                               (t (string-lessp (plist-get a :title)
                                                (plist-get b :title))))))))
         (articles (etaf-rss--client-articles client)))
    (list :feeds (apply #'vector rows)
          :total (length articles)
          :unread (cl-count-if-not (lambda (article)
                                     (eq t (alist-get 'read article)))
                                   articles)
          :starred (cl-count-if (lambda (article)
                                  (eq t (alist-get 'starred article)))
                                articles))))

(defun etaf-rss--snapshot (client)
  "Return feeds, totals and preferences of CLIENT."
  (append (etaf-rss--feeds-reply client)
          (list :theme (or (alist-get 'theme (alist-get 'settings
                                                       (etaf-rss--client-ensure-store client)))
                           "dark"))))

(defun etaf-rss--article-row (article)
  "Return ARTICLE as the light plist a list row carries."
  (list :id (alist-get 'id article)
        :feed (alist-get 'feed article)
        :feed-title (or (alist-get 'feed-title article) "")
        :title (or (alist-get 'title article) "")
        :url (or (alist-get 'url article) "")
        :author (or (alist-get 'author article) "")
        :published (alist-get 'published article)
        :summary (or (alist-get 'summary article) "")
        :read (eq t (alist-get 'read article))
        :starred (eq t (alist-get 'starred article))))

(defun etaf-rss--article-in-scope-p (client article scope)
  "Return non-nil when ARTICLE belongs to SCOPE of CLIENT."
  (pcase (plist-get scope :kind)
    (:all t)
    (:unread (not (eq t (alist-get 'read article))))
    (:starred (eq t (alist-get 'starred article)))
    (:feed (equal (alist-get 'feed article) (plist-get scope :id)))
    (:folder
     (let ((feed (etaf-rss--feed-by-id client (alist-get 'feed article))))
       (and feed (equal (alist-get 'folder feed) (plist-get scope :name)))))
    (:search
     (etaf-rss--article-match-p article (plist-get scope :query)))
    (_ nil)))

(defun etaf-rss--article-match-p (article query)
  "Return non-nil when ARTICLE matches every term of QUERY.
Terms are literal, case-insensitive substrings of the title, the summary or
the raw content; a query with no terms matches nothing."
  (let ((terms (delete-dups (split-string (downcase (or query "")) "\\s-+" t))))
    (and terms
         (let ((haystack (downcase
                          (mapconcat (lambda (key)
                                       (or (alist-get key article) ""))
                                     '(title summary content)
                                     "\n"))))
           (cl-every (lambda (term) (string-match-p (regexp-quote term) haystack))
                     terms)))))

(defun etaf-rss--search-snippet (article query)
  "Return a plain-text snippet of ARTICLE around the first QUERY match."
  (let* ((text (replace-regexp-in-string
                "<[^>]*>" " "
                (mapconcat (lambda (key) (or (alist-get key article) ""))
                           '(title summary content) " ")))
         (text (string-trim (replace-regexp-in-string "\\s-+" " " text)))
         (terms (split-string (downcase (or query "")) "\\s-+" t))
         (position nil))
    (dolist (term terms)
      (unless position
        (let ((found (string-match-p (regexp-quote term) (downcase text))))
          (when found (setq position found)))))
    (if (null position)
        (etaf-rss--clip text 120)
      (let* ((start (max 0 (- position 40)))
             (end (min (length text) (+ position 120))))
        (concat (if (> start 0) "…" "")
                (etaf-rss--clip (substring text start end) 120))))))

(defun etaf-rss--rows-reply (client scope)
  "Return (:rows VECTOR :total N) for SCOPE of CLIENT.
Search rows carry a `:snippet' so a match inside the body is visible; every
other scope returns the light row shape."
  (let* ((scope (or scope (list :kind :all)))
         (search (eq (plist-get scope :kind) :search))
         (matched (seq-filter (lambda (article)
                                (etaf-rss--article-in-scope-p client article scope))
                              (etaf-rss--client-articles client)))
         (rows (mapcar (lambda (article)
                         (let ((row (etaf-rss--article-row article)))
                           (if search
                               (append row (list :snippet
                                                 (etaf-rss--search-snippet
                                                  article (plist-get scope :query))))
                             row)))
                       matched)))
    (list :rows (apply #'vector (seq-take rows etaf-rss-search-limit))
          :total (length rows))))

(defun etaf-rss--article-reply (client id)
  "Return the full article reply for ID, or an error result."
  (let ((article (etaf-rss--article-by-id client id)))
    (if (null article)
        (list :error (format "找不到文章：%s" id))
      (list :ok (append (etaf-rss--article-row article)
                        (list :content (or (alist-get 'content article) "")
                              :added (alist-get 'added article)))))))

;;; ---------------------------------------------------------------------------
;;; Mutations
;;; ---------------------------------------------------------------------------

(defun etaf-rss--mark-read (client request)
  "Set the read state of the IDs in REQUEST and return the reply."
  (let* ((read (if (eq (plist-get request :read) :false) nil
                 (plist-get request :read)))
         (ids (plist-get request :ids))
         (changed 0))
    (dolist (article (etaf-rss--client-articles client))
      (when (member (alist-get 'id article) ids)
        (unless (eq (eq t (alist-get 'read article)) (eq t read))
          (setf (alist-get 'read article) read)
          (cl-incf changed))))
    (when (> changed 0)
      (etaf-rss--client-dirty client))
    (let ((feeds (etaf-rss--feeds-reply client)))
      (list :ok (list :changed changed
                      :feeds (plist-get feeds :feeds)
                      :unread (plist-get feeds :unread)
                      :total (plist-get feeds :total)
                      :starred (plist-get feeds :starred))))))

(defun etaf-rss--mark-read-scope (client request)
  "Set the read state of every article in REQUEST's scope."
  (let* ((read (if (eq (plist-get request :read) :false) nil
                 (plist-get request :read)))
         (scope (plist-get request :scope))
         (ids nil))
    (dolist (article (etaf-rss--client-articles client))
      (when (and (etaf-rss--article-in-scope-p client article scope)
                 (not (eq (eq t (alist-get 'read article)) (eq t read))))
        (setf (alist-get 'read article) read)
        (push (alist-get 'id article) ids)))
    (when ids (etaf-rss--client-dirty client))
    (let ((feeds (etaf-rss--feeds-reply client)))
      (list :ok (list :ids (apply #'vector ids)
                      :feeds (plist-get feeds :feeds)
                      :unread (plist-get feeds :unread)
                      :total (plist-get feeds :total)
                      :starred (plist-get feeds :starred))))))

(defun etaf-rss--set-star (client request)
  "Set one article's star in REQUEST and return the reply."
  (let* ((id (plist-get request :id))
         (starred (eq t (plist-get request :starred)))
         (article (etaf-rss--article-by-id client id)))
    (unless article
      (signal 'etaf-rss-error (list (format "找不到文章：%s" id))))
    (setf (alist-get 'starred article) starred)
    (etaf-rss--client-dirty client)
    (let ((feeds (etaf-rss--feeds-reply client)))
      ;; :starred here is the reader's starred count, matching the feeds
      ;; reply; the article's own new value is not repeated because the model
      ;; already flipped it optimistically.
      (list :ok (list :id id
                      :feeds (plist-get feeds :feeds)
                      :unread (plist-get feeds :unread)
                      :total (plist-get feeds :total)
                      :starred (plist-get feeds :starred))))))

(defun etaf-rss--set-theme (client request)
  "Remember REQUEST's theme in CLIENT's settings."
  (let* ((store (etaf-rss--client-ensure-store client))
         (settings (alist-get 'settings store))
         (theme (or (plist-get request :theme) "dark")))
    (setf (alist-get 'theme settings) theme)
    (setf (alist-get 'settings store) settings)
    (etaf-rss--client-dirty client)
    (list :ok (list :theme theme))))

(defun etaf-rss--remove-feed (client id)
  "Remove feed ID from CLIENT; its starred articles stay in the reader."
  (let* ((store (etaf-rss--client-ensure-store client))
         (feed (etaf-rss--feed-by-id client id)))
    (unless feed
      (signal 'etaf-rss-error (list (format "找不到订阅：%s" id))))
    (setf (alist-get 'feeds store)
          (vconcat (seq-remove (lambda (item) (equal (alist-get 'id item) id))
                               (append (alist-get 'feeds store) nil))))
    (let ((orphans (seq-remove (lambda (article)
                                 (and (equal (alist-get 'feed article) id)
                                      (not (eq t (alist-get 'starred article)))))
                               (etaf-rss--client-articles client))))
      (setf (alist-get 'articles store)
            (vconcat (sort orphans
                           (lambda (a b)
                             (> (etaf-rss--article-rank a)
                                (etaf-rss--article-rank b)))))))
    (etaf-rss--client-dirty client)
    (let ((feeds (etaf-rss--feeds-reply client)))
      (list :ok (list :removed (etaf-rss--feed-row feed (make-hash-table :test 'equal))
                      :feeds (plist-get feeds :feeds)
                      :unread (plist-get feeds :unread)
                      :total (plist-get feeds :total)
                      :starred (plist-get feeds :starred))))))

(defun etaf-rss--move-feed (client request)
  "File the feed of REQUEST under its folder."
  (let ((feed (etaf-rss--feed-by-id client (plist-get request :id))))
    (unless feed
      (signal 'etaf-rss-error
              (list (format "找不到订阅：%s" (plist-get request :id)))))
    (setf (alist-get 'folder feed) (string-trim (or (plist-get request :folder) "")))
    (etaf-rss--client-dirty client)
    (list :ok (etaf-rss--feeds-reply client))))

;;; ---------------------------------------------------------------------------
;;; Fetching
;;; ---------------------------------------------------------------------------

(defun etaf-rss--normalize-url (url)
  "Return URL with a scheme, defaulting to https:// for a bare host."
  (let ((url (string-trim (or url ""))))
    (cond ((string-empty-p url) (signal 'etaf-rss-error '("订阅地址不能为空")))
          ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" url) url)
          ((string-prefix-p "//" url) (concat "https:" url))
          (t (concat "https://" url)))))

(defun etaf-rss--enqueue (client thunk)
  "Queue THUNK on CLIENT and start it when no transfer is running."
  (setf (etaf-rss--client-queue client)
        (append (etaf-rss--client-queue client) (list thunk)))
  (etaf-rss--pump client))

(defun etaf-rss--pump (client)
  "Start the next queued transfer of CLIENT, if it is idle."
  (unless (etaf-rss--client-busy client)
    (let ((thunk (pop (etaf-rss--client-queue client))))
      (when thunk
        (setf (etaf-rss--client-busy client) t)
        (funcall thunk)))))

(cl-defun etaf-rss--fetch (client url callback &key etag last-modified)
  "Fetch URL for CLIENT and deliver the transfer to CALLBACK.
CALLBACK receives (:ok BODY :status CODE :etag E :modified M :url U) or
(:error MESSAGE :hint HINT).  Requests run one at a time so a refresh of many
feeds never opens many connections at once."
  (let ((pending (etaf-rss--pending-create :url url :callback callback)))
    (push pending (etaf-rss--client-pending client))
    (etaf-rss--enqueue
     client
     (lambda ()
       (etaf-rss--fetch-start client pending etag last-modified)))))

(defun etaf-rss--fetch-start (client pending etag last-modified)
  "Begin the transfer of PENDING for CLIENT, with conditional headers."
  (let* ((headers (append
                   (list (cons "User-Agent" etaf-rss-user-agent)
                         (cons "Accept"
                               (concat "application/rss+xml, application/atom+xml, "
                                       "application/feed+json, application/json;q=0.9, "
                                       "application/xml;q=0.8, text/xml;q=0.8, "
                                       "text/html;q=0.5, */*;q=0.1")))
                   (when (and etag (not (string-empty-p etag)))
                     (list (cons "If-None-Match" etag)))
                   (when (and last-modified (not (string-empty-p last-modified)))
                     (list (cons "If-Modified-Since" last-modified)))))
         (timeout (etaf-rss--client-timeout client)))
    (setf (etaf-rss--pending-timer pending)
          (run-at-time
           timeout nil
           (lambda ()
             (unless (etaf-rss--pending-delivered pending)
               (etaf-rss--fetch-abort pending)
               (etaf-rss--fetch-finish
                client pending
                (list :error (format "请求超时（%s 秒）" timeout)
                      :hint (etaf-rss--pending-url pending)))))))
    (condition-case error
        (let ((url-request-extra-headers headers)
              (url-request-method "GET"))
          (setf (etaf-rss--pending-buffer pending)
                (url-retrieve (etaf-rss--pending-url pending)
                              (lambda (status)
                                (etaf-rss--fetch-settle client pending status))
                              nil t t)))
      (error
       (etaf-rss--fetch-finish client pending
                               (list :error (error-message-string error)
                                     :hint (etaf-rss--pending-url pending)))))))

(defun etaf-rss--fetch-abort (pending)
  "Abandon PENDING's transfer without running its callback."
  (when-let* ((timer (etaf-rss--pending-timer pending)))
    (cancel-timer timer)
    (setf (etaf-rss--pending-timer pending) nil))
  (when-let* ((buffer (etaf-rss--pending-buffer pending)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when-let* ((process (get-buffer-process buffer)))
          (when (process-live-p process) (delete-process process))))
      (kill-buffer buffer)))
  (setf (etaf-rss--pending-buffer pending) nil))

(defun etaf-rss--fetch-finish (client pending result)
  "Deliver RESULT for PENDING, release CLIENT's slot and start the next fetch."
  (unless (etaf-rss--pending-delivered pending)
    (setf (etaf-rss--pending-delivered pending) t)
    (when-let* ((timer (etaf-rss--pending-timer pending)))
      (cancel-timer timer)
      (setf (etaf-rss--pending-timer pending) nil))
    (setf (etaf-rss--client-pending client)
          (delq pending (etaf-rss--client-pending client)))
    (setf (etaf-rss--client-busy client) nil)
    (unless (etaf-rss--pending-cancelled pending)
      (funcall (etaf-rss--pending-callback pending) result))
    (etaf-rss--pump client)))

(defun etaf-rss--fetch-settle (client pending status)
  "Collect the transfer of PENDING in CLIENT from its current buffer."
  (let ((buffer (current-buffer)))
    (when-let* ((timer (etaf-rss--pending-timer pending)))
      (cancel-timer timer)
      (setf (etaf-rss--pending-timer pending) nil))
    (setf (etaf-rss--pending-buffer pending) nil)
    (cond
     ((etaf-rss--pending-cancelled pending)
      (kill-buffer buffer)
      (etaf-rss--fetch-finish client pending (list :error "已取消")))
     ((plist-get status :error)
      (kill-buffer buffer)
      (etaf-rss--fetch-finish
       client pending
       (list :error (format "%s" (plist-get status :error))
             :hint (etaf-rss--pending-url pending))))
     (t
      (let ((code (etaf-rss--response-code))
            (headers nil)
            (body ""))
        (unwind-protect
            (progn
              (setq headers (etaf-rss--response-headers))
              (setq body (etaf-rss--response-body)))
          (kill-buffer buffer))
        (etaf-rss--fetch-finish
         client pending
         (pcase code
           (304 (list :ok "" :status 304 :url (etaf-rss--pending-url pending)))
           ((or 200 203 0)
            (list :ok body :status (if (zerop code) 200 code)
                  :etag (cdr (assoc "etag" headers))
                  :modified (cdr (assoc "last-modified" headers))
                  :url (or (plist-get status :url) (etaf-rss--pending-url pending))))
           ((and (pred integerp)
                 (pred (lambda (value) (and (>= value 200) (< value 300)))))
            (list :ok body :status code
                  :etag (cdr (assoc "etag" headers))
                  :modified (cdr (assoc "last-modified" headers))
                  :url (or (plist-get status :url) (etaf-rss--pending-url pending))))
           (_ (list :error (format "HTTP %s" code)
                    :hint (etaf-rss--pending-url pending))))))))))

(defun etaf-rss--response-code ()
  "Return the HTTP status code of the current response, if any."
  (cond ((fboundp 'url-http-response-status)
         (ignore-errors (url-http-response-status)))
        ((boundp 'url-http-response-status)
         (ignore-errors (symbol-value 'url-http-response-status)))
        (t 0)))

(defun etaf-rss--header-end ()
  "Return the position where the current response's headers end.
An HTTP transfer records it in `url-http-end-of-headers'; a file transfer
(the scheme tests use) has no such variable, so the first blank line stands
in for it."
  (or (bound-and-true-p url-http-end-of-headers)
      (save-excursion
        (goto-char (point-min))
        (if (re-search-forward "\r?\n\r?\n" (min (point-max) (+ (point-min) 4096)) t)
            (point)
          (point-min)))))

(defun etaf-rss--response-headers ()
  "Return the response headers as (LOWERCASE-NAME . VALUE) pairs."
  (save-excursion
    (goto-char (point-min))
    (let ((end (etaf-rss--header-end))
          (headers nil))
      (while (re-search-forward "^\\([^:\n]+\\): *\\([^\n]*\\)$" end t)
        (push (cons (downcase (match-string 1)) (string-trim (match-string 2)))
              headers))
      (nreverse headers))))

(defun etaf-rss--response-body ()
  "Return the decoded response body of the current buffer.
The charset comes from the Content-Type header, then from an XML declaration,
and falls back to UTF-8; an already-decoded multibyte body is kept as is."
  (save-excursion
    (goto-char (etaf-rss--header-end))
    (let* ((body (buffer-substring-no-properties (point) (point-max)))
           (type (or (cdr (assoc "content-type" (etaf-rss--response-headers))) ""))
           (charset (or (and (string-match "charset=\\([^; \r\n\"]+\\)" type)
                             (match-string 1 type))
                        (and (string-match "encoding=\"\\([^\"]+\\)\"" body)
                             (match-string 1 body))
                        "utf-8")))
      (if (multibyte-string-p body)
          body
        (decode-coding-string
         body (or (ignore-errors (coding-system-from-name charset)) 'utf-8))))))

;;; ---------------------------------------------------------------------------
;;; Refresh, merge and subscription management
;;; ---------------------------------------------------------------------------

(defun etaf-rss--merge-articles (client feed parsed)
  "Merge the articles of PARSED into FEED for CLIENT; return the new count.
An article already stored keeps its read and starred state, and a fresh copy
of its text refreshes the summary and content.  New articles are prepended
with the current time as their arrival order."
  (let* ((store (etaf-rss--client-ensure-store client))
         (articles (etaf-rss--client-articles client))
         (known (make-hash-table :test 'equal))
         (new nil)
         (new-count 0)
         (now (float-time))
         (feed-id (alist-get 'id feed)))
    (dolist (article articles)
      (puthash (alist-get 'id article) article known))
    (dolist (item (plist-get parsed :articles))
      (let* ((id (plist-get item :id))
             (existing (gethash id known)))
        (if existing
            (progn
              (setf (alist-get 'title existing) (plist-get item :title)
                    (alist-get 'url existing) (plist-get item :url)
                    (alist-get 'author existing) (plist-get item :author)
                    (alist-get 'published existing) (plist-get item :published)
                    (alist-get 'summary existing) (plist-get item :summary)
                    (alist-get 'content existing) (plist-get item :content)
                    (alist-get 'feed-title existing) (alist-get 'title feed)))
          (cl-incf new-count)
          (push (list (cons 'id id)
                      (cons 'feed feed-id)
                      (cons 'feed-title (alist-get 'title feed))
                      (cons 'title (plist-get item :title))
                      (cons 'url (plist-get item :url))
                      (cons 'author (plist-get item :author))
                      (cons 'published (plist-get item :published))
                      (cons 'added now)
                      (cons 'summary (plist-get item :summary))
                      (cons 'content (plist-get item :content))
                      (cons 'read nil)
                      (cons 'starred nil))
                new))))
    (setf (alist-get 'articles store)
          (vconcat (sort (append new articles)
                         (lambda (a b)
                           (> (etaf-rss--article-rank a)
                              (etaf-rss--article-rank b))))))
    (etaf-rss--client-dirty client)
    new-count))

(defun etaf-rss--merge-feed-meta (feed parsed)
  "Update FEED's own fields from PARSED."
  (let ((title (plist-get parsed :title)))
    (when (and title (not (string-empty-p title)))
      (setf (alist-get 'title feed) title)))
  (setf (alist-get 'site feed) (or (plist-get parsed :site)
                                   (alist-get 'site feed) "")
        (alist-get 'last_fetch feed) (float-time)
        (alist-get 'error feed) nil)
  (let ((newest (cl-loop for article in (plist-get parsed :articles)
                         maximize (or (plist-get article :published) 0))))
    (when (> newest 0)
      (setf (alist-get 'updated feed) newest))))

(defun etaf-rss--refresh-feed (client id callback)
  "Re-fetch feed ID for CLIENT and report the result to CALLBACK.
A conditional request carries the stored ETag and Last-Modified, so an
unchanged feed costs one 304; a changed one merges its articles and reports
how many are new.  A failure is remembered on the feed and reported, so the
sidebar can show which subscription needs attention."
  (let ((feed (etaf-rss--feed-by-id client id)))
    (unless feed
      (etaf-rss--deliver client callback
                         (list :error (format "找不到订阅：%s" id))))
    (when feed
      (etaf-rss--fetch
       client (alist-get 'url feed)
       (lambda (result)
         (if (eq (car result) :error)
             (progn
               (setf (alist-get 'error feed)
                     (etaf-rss--clean-error (cadr result)))
               (etaf-rss--client-dirty client)
               (funcall callback
                        (append (list :error (cadr result))
                                (cddr result)
                                (list :feed-id id))))
           (let ((status (plist-get result :status)))
             (cond
              ((eq status 304)
               (setf (alist-get 'last_fetch feed) (float-time)
                     (alist-get 'error feed) nil)
               (etaf-rss--client-dirty client)
               (etaf-rss--reply-refresh client callback feed 0 t))
              (t
               (condition-case error
                   (let* ((parsed (etaf-rss-parse-feed
                                   (plist-get result :ok)
                                   (alist-get 'url feed)))
                          (new (etaf-rss--merge-articles client feed parsed)))
                     (etaf-rss--merge-feed-meta feed parsed)
                     (setf (alist-get 'etag feed) (plist-get result :etag)
                           (alist-get 'last_modified feed) (plist-get result :modified))
                     (etaf-rss--client-dirty client)
                     (etaf-rss--reply-refresh client callback feed new nil))
                 (etaf-rss-error
                  (setf (alist-get 'error feed)
                        (etaf-rss--clean-error (error-message-string error)))
                  (etaf-rss--client-dirty client)
                  (funcall callback
                           (list :error (error-message-string error)
                                 :hint (alist-get 'url feed)
                                 :feed-id id)))))))))
       :etag (alist-get 'etag feed)
       :last-modified (alist-get 'last_modified feed)))))

(defun etaf-rss--reply-refresh (client callback feed new not-modified)
  "Report a finished refresh of FEED to CALLBACK."
  (let ((feeds (etaf-rss--feeds-reply client)))
    (funcall callback
             (list :ok (list :feed (etaf-rss--feed-row
                                    feed (etaf-rss--counts client))
                             :new new
                             :not-modified not-modified
                             :feeds (plist-get feeds :feeds)
                             :unread (plist-get feeds :unread)
                             :total (plist-get feeds :total)
                             :starred (plist-get feeds :starred))))))

(defun etaf-rss--clean-error (message)
  "Return MESSAGE shortened to one status-line sentence."
  (let ((message (string-trim (or message "请求失败"))))
    (if (> (length message) 120)
        (concat (substring message 0 117) "…")
      message)))

(defun etaf-rss--add-feed (client url folder callback)
  "Subscribe CLIENT to URL; CALLBACK receives the new feed or a readable error.
A document that is not a feed is treated as a site page: its advertised feed
links are tried in order before giving up."
  (let ((url (condition-case error
                 (etaf-rss--normalize-url url)
               (etaf-rss-error
                (etaf-rss--deliver client callback
                                   (list :error (error-message-string error)))
                nil))))
    (when url
      (if (seq-find (lambda (feed) (equal (alist-get 'url feed) url))
                    (etaf-rss--client-feeds client))
          (etaf-rss--deliver client callback
                             (list :error "这个订阅已经在列表里了" :hint url))
        (etaf-rss--fetch
         client url
         (lambda (result)
           (if (eq (car result) :error)
               (funcall callback result)
             (etaf-rss--add-feed-body client url folder result callback))))))))

(defun etaf-rss--add-feed-body (client url folder result callback)
  "Subscribe CLIENT to the fetched feed or page in RESULT.
URL names what was fetched, FOLDER files it, and CALLBACK answers the caller."
  (let* ((body (plist-get result :ok))
         (final (or (plist-get result :url) url)))
    (condition-case error
        (let* ((parsed (etaf-rss-parse-feed body final)))
          (etaf-rss--add-parsed client final folder parsed callback))
      (etaf-rss-error
       (let* ((links (and (string-match-p "<\\s-*html" body)
                          (etaf-rss-html-feed-links body final)))
              (html-error error))
         (if (null links)
             (funcall callback
                      (list :error
                            (if (string-match-p "<\\s-*html" body)
                                "这个页面里没有找到订阅链接"
                              (error-message-string html-error))
                            :hint final))
           (etaf-rss--fetch
            client (car links)
            (lambda (discovered)
              (if (eq (car discovered) :error)
                  (funcall callback discovered)
                (condition-case second
                    (etaf-rss--add-parsed
                     client (car links) folder
                     (etaf-rss-parse-feed (plist-get discovered :ok) (car links))
                     callback)
                  (etaf-rss-error
                   (funcall callback
                            (list :error (error-message-string second)
                                  :hint (car links))))))))))))))

(defun etaf-rss--add-parsed (client url folder parsed callback)
  "Add freshly PARSED feed at URL to CLIENT and answer CALLBACK."
  (let* ((store (etaf-rss--client-ensure-store client))
         (title (or (plist-get parsed :title) url))
         (feed (list (cons 'id (sha1 url))
                     (cons 'url url)
                     (cons 'title title)
                     (cons 'site (or (plist-get parsed :site) ""))
                     (cons 'folder (string-trim (or folder "")))
                     (cons 'updated (float-time))
                     (cons 'last_fetch (float-time))
                     (cons 'etag nil)
                     (cons 'last_modified nil)
                     (cons 'error nil))))
    (setf (alist-get 'feeds store)
          (vconcat (append (alist-get 'feeds store) (list feed))))
    (let ((new (etaf-rss--merge-articles client feed parsed)))
      (etaf-rss--merge-feed-meta feed parsed)
      (etaf-rss--client-dirty client)
      (let ((feeds (etaf-rss--feeds-reply client)))
        (funcall callback
                 (list :ok (list :feed (etaf-rss--feed-row
                                        feed (etaf-rss--counts client))
                                 :new new
                                 :feeds (plist-get feeds :feeds)
                                 :unread (plist-get feeds :unread)
                                 :total (plist-get feeds :total)
                                 :starred (plist-get feeds :starred))))))))

;;; ---------------------------------------------------------------------------
;;; OPML
;;; ---------------------------------------------------------------------------

(defun etaf-rss--xml-escape (text)
  "Return TEXT safe inside an XML attribute."
  (let ((text (or text "")))
    (setq text (replace-regexp-in-string "&" "&amp;" text t t))
    (setq text (replace-regexp-in-string "<" "&lt;" text t t))
    (setq text (replace-regexp-in-string ">" "&gt;" text t t))
    (setq text (replace-regexp-in-string "\"" "&quot;" text t t))
    text))

(defun etaf-rss--opml-import (client path)
  "Add the subscriptions of the OPML file at PATH to CLIENT.
Feeds already subscribed by URL are skipped; nothing is fetched here, so the
import returns at once and the caller can refresh afterwards."
  (let ((text (condition-case error
                  (with-temp-buffer
                    (let ((coding-system-for-read 'utf-8))
                      (insert-file-contents path))
                    (buffer-substring-no-properties (point-min) (point-max)))
                (error (signal 'etaf-rss-error
                               (list (format "无法读取 OPML：%s"
                                             (error-message-string error)))))))
        (store (etaf-rss--client-ensure-store client))
        (existing (mapcar (lambda (feed) (alist-get 'url feed))
                          (etaf-rss--client-feeds client)))
        (added 0)
        (skipped 0))
    (dolist (entry (etaf-rss-parse-opml text))
      (let ((url (condition-case nil
                     (etaf-rss--normalize-url (plist-get entry :url))
                   (etaf-rss-error nil))))
        (cond
         ((null url) (cl-incf skipped))
         ((member url existing) (cl-incf skipped))
         (t
          (push url existing)
          (cl-incf added)
          (setf (alist-get 'feeds store)
                (vconcat (append (alist-get 'feeds store)
                                 (list (list (cons 'id (sha1 url))
                                             (cons 'url url)
                                             (cons 'title (or (plist-get entry :title)
                                                              url))
                                             (cons 'site "")
                                             (cons 'folder (or (plist-get entry :folder) ""))
                                             (cons 'updated nil)
                                             (cons 'last_fetch nil)
                                             (cons 'etag nil)
                                             (cons 'last_modified nil)
                                             (cons 'error nil))))))))))
    (when (> added 0) (etaf-rss--client-dirty client))
    (let ((feeds (etaf-rss--feeds-reply client)))
      (list :ok (list :added added
                      :skipped skipped
                      :feeds (plist-get feeds :feeds)
                      :unread (plist-get feeds :unread)
                      :total (plist-get feeds :total)
                      :starred (plist-get feeds :starred))))))

(defun etaf-rss--opml-export (client path)
  "Write CLIENT's subscriptions to the OPML file at PATH."
  (let ((feeds (etaf-rss--client-feeds client))
        (folders nil))
    (dolist (feed feeds)
      (let ((folder (or (alist-get 'folder feed) "")))
        (unless (member folder folders) (push folder folders))))
    (setq folders (sort folders #'string-lessp))
    (condition-case error
        (let ((coding-system-for-write 'utf-8))
          (with-temp-file path
            (insert "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                    "<opml version=\"2.0\">\n  <head>\n    <title>etaf-rss 订阅</title>\n"
                    "  </head>\n  <body>\n")
            (dolist (folder folders)
              (let ((members (seq-filter
                              (lambda (feed)
                                (equal (or (alist-get 'folder feed) "") folder))
                              feeds)))
                (when (and (not (string-empty-p folder)) members)
                  (insert (format "    <outline text=\"%s\" title=\"%s\">\n"
                                  (etaf-rss--xml-escape folder)
                                  (etaf-rss--xml-escape folder))))
                (dolist (feed members)
                  (insert (format "      <outline type=\"rss\" text=\"%s\" title=\"%s\" xmlUrl=\"%s\"%s/>\n"
                                  (etaf-rss--xml-escape (alist-get 'title feed))
                                  (etaf-rss--xml-escape (alist-get 'title feed))
                                  (etaf-rss--xml-escape (alist-get 'url feed))
                                  (if (or (null (alist-get 'site feed))
                                          (string-empty-p (alist-get 'site feed)))
                                      ""
                                    (format " htmlUrl=\"%s\""
                                            (etaf-rss--xml-escape (alist-get 'site feed)))))))
                (when (and (not (string-empty-p folder)) members)
                  (insert "    </outline>\n"))))
            (insert "  </body>\n</opml>\n")))
      (error (signal 'etaf-rss-error
                     (list (format "无法写入 OPML：%s" (error-message-string error))))))
    (list :ok (list :path (expand-file-name path) :count (length feeds)))))

(provide 'etaf-rss-service)
;;; etaf-rss-service.el ends here
