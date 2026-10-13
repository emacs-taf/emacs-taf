;;; etaf-youtube-model.el --- State of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns plain data and reactive sources.  It never touches a buffer
;; or the display; commands mutate refs, views project them, and every request
;; is asynchronous so a slow response never blocks a render.  Each request
;; carries a token, so a reply from a route or video the user has already left
;; is dropped instead of repainting stale state.
;;
;; The player side talks to the mounted `etaf-video' Component through its
;; public handle functions.  Playback state is polled once a second, which is
;; the only recurring work this layer schedules.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf)
(require 'etaf-youtube-theme)
(require 'etaf-youtube-images)
(require 'etaf-youtube-service)
(require 'etaf-youtube-store)

(defvar etaf-youtube-player-handle 'etaf-youtube-player
  "Handle registered by the mounted video Component of the application.")

(defconst etaf-youtube--quality-levels '(2160 1440 1080 720 480 360 240 144)
  "Video heights a quality choice may name, from high to low.")

(defconst etaf-youtube--feed-views
  '(home shorts subscriptions history playlists watch-later liked live)
  "Routes that read one of the account's feed lists.")

(defconst etaf-youtube--nav-views
  '(home shorts subscriptions history playlists watch-later liked live)
  "Sidebar destinations in their display order.")

;;; ---------------------------------------------------------------------------
;;; Accessors
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--set (app key value)
  "Set APP's KEY to VALUE, mutating the shared plist in place."
  (if (etaf-ref-p (plist-get app key))
      (setf (etaf-value (plist-get app key)) value)
    (setf (plist-get app key) value))
  value)

(defun etaf-youtube--read (app key)
  "Return APP's KEY value, following the ref when there is one."
  (let ((value (plist-get app key)))
    (if (etaf-ref-p value) (etaf-value value) value)))

(defun etaf-youtube--write (app key value)
  "Set APP's KEY to VALUE, following the ref when there is one."
  (etaf-youtube--set app key value))

(defun etaf-youtube--next-token (app key)
  "Return a fresh request token for APP's KEY."
  (let* ((tokens (plist-get app :tokens))
         (token (1+ (or (gethash key tokens) 0))))
    (puthash key token tokens)
    token))

(defun etaf-youtube--current-p (app key token)
  "Return non-nil when TOKEN is APP's newest token for KEY."
  (= token (or (gethash key (plist-get app :tokens)) 0)))

(defun etaf-youtube--note (app text &optional variant)
  "Show TEXT as APP's transient message with VARIANT styling."
  (etaf-youtube--write app :message
                       (list :text text :variant (or variant 'info) :at (float-time))))

(defun etaf-youtube--state-name (app key)
  "Return the state word in APP's KEY status plist."
  (plist-get (etaf-youtube--read app key) :state))

(defun etaf-youtube--request (app key args callback)
  "Run skill ARGS for APP under KEY and call CALLBACK with the result.
An obsolete reply (its token was replaced) is dropped.  A callback error is
reported but never reaches the process sentinel."
  (let ((token (etaf-youtube--next-token app key)))
    (etaf-youtube-service-call
     (plist-get app :service) args
     (lambda (result)
       (when (etaf-youtube--current-p app key token)
         (condition-case error
             (funcall callback result)
           (error
            (etaf-youtube--note app (error-message-string error) 'danger)))))
     key)))

(defun etaf-youtube--request-token (app key args callback)
  "Run ARGS and call CALLBACK with (RESULT TOKEN).
The callback is responsible for checking the token with
`etaf-youtube--current-p' when it needs to drop obsolete replies."
  (let ((token (etaf-youtube--next-token app key)))
    (etaf-youtube-service-call
     (plist-get app :service) args
     (lambda (result)
       (condition-case error
           (funcall callback result token)
         (error
          (etaf-youtube--note app (error-message-string error) 'danger))))
     key)))

(defun etaf-youtube--apply-account (app result)
  "Record the account RESULT in APP."
  (if (eq (plist-get result :status) 'ok)
      (etaf-youtube--write app :account (plist-get result :value))
    (etaf-youtube--write app :account
                         (list :ok nil
                               :message (or (plist-get result :message)
                                            "Could not read the account")))))

;;; ---------------------------------------------------------------------------
;;; Session
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--setting-number (store name default)
  "Return STORE's numeric setting NAME, or DEFAULT."
  (let ((text (ignore-errors (etaf-youtube-store-setting store name))))
    (if (and (stringp text) (string-match-p "\\`-?[0-9.]+\\'" text))
        (string-to-number text)
      default)))

(cl-defun etaf-youtube-create (&key service images store)
  "Create the application model and return it.
SERVICE defaults to a real skill transport, IMAGES to the default thumbnail
cache and STORE to the SQLite store.  The account check starts immediately;
`etaf-youtube-state' reports everything a caller or a test needs."
  (let* ((service (or service (etaf-youtube-service-create)))
         (images (or images (etaf-youtube-images-create)))
         (store (if (eq store :none) nil (or store (etaf-youtube-store-open))))
         (mode (or (let ((text (ignore-errors
                                 (etaf-youtube-store-setting store "theme"))))
                     (and (stringp text) (intern text)))
                   etaf-youtube-theme-mode))
         (app (list
               :service service
               :images images
               :store store
               :tokens (make-hash-table :test #'eq)
               :route (etaf-ref (list :view 'home :args nil) :name 'etaf-youtube-route)
               :history (etaf-ref nil :name 'etaf-youtube-history)
               :feed (etaf-ref nil :name 'etaf-youtube-feed)
               :feed-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-feed-status)
               :feed-more (etaf-ref nil :name 'etaf-youtube-feed-more)
               :account (etaf-ref nil :name 'etaf-youtube-account)
               :video (etaf-ref nil :name 'etaf-youtube-video)
               :video-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-video-status)
               :media (etaf-ref nil :name 'etaf-youtube-media)
               :media-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-media-status)
               :comments (etaf-ref nil :name 'etaf-youtube-comments)
               :comments-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-comments-status)
               :replies (etaf-ref (make-hash-table :test #'equal) :name 'etaf-youtube-replies)
               :selected (etaf-ref 0 :name 'etaf-youtube-selected)
               :query (etaf-ref "" :name 'etaf-youtube-query)
               :filter (etaf-ref "all" :name 'etaf-youtube-filter)
               :sidebar (etaf-ref t :name 'etaf-youtube-sidebar)
               :theater (etaf-ref nil :name 'etaf-youtube-theater)
               :theme-mode (etaf-ref mode :name 'etaf-youtube-theme-mode)
               :palette (etaf-ref (etaf-youtube-theme-defaults mode)
                                  :name 'etaf-youtube-palette)
               :volume (etaf-ref (etaf-youtube--setting-number store "volume" 100)
                                 :name 'etaf-youtube-volume)
               :speed (etaf-ref (etaf-youtube--setting-number store "speed" 1)
                                :name 'etaf-youtube-speed)
               :muted (etaf-ref nil :name 'etaf-youtube-muted)
               :quality (etaf-ref (etaf-youtube--setting-number store "quality" 720)
                                  :name 'etaf-youtube-quality)
               :captions-on (etaf-ref nil :name 'etaf-youtube-captions-on)
               :captions (etaf-ref nil :name 'etaf-youtube-captions)
               :comment-draft (etaf-ref "" :name 'etaf-youtube-comment-draft)
               :comments-sort (etaf-ref nil :name 'etaf-youtube-comments-sort)
               :position (etaf-ref 0 :name 'etaf-youtube-position)
               :scrub (etaf-ref nil :name 'etaf-youtube-scrub)
               :display-position nil
               :playing (etaf-ref nil :name 'etaf-youtube-playing)
               :duration (etaf-ref 0 :name 'etaf-youtube-duration)
               :message (etaf-ref nil :name 'etaf-youtube-message)
               :pending-seek (etaf-ref nil :name 'etaf-youtube-pending-seek)
               :player-handle etaf-youtube-player-handle
               :player-timer nil
               :buffer nil)))
    (etaf-youtube--set app :display-position
                       (etaf-computed
                        (lambda ()
                          (or (etaf-youtube--read app :scrub)
                              (etaf-youtube--read app :position)))
                        :name 'etaf-youtube-display-position))
    (when-let* ((quality (etaf-youtube--read app :quality)))
      (unless (memq quality etaf-youtube--quality-levels)
        (etaf-youtube--write app :quality 720)))
    (etaf-youtube-check app)
    app))

(defun etaf-youtube-destroy (app)
  "Release APP's transport, downloads, timer and store."
  (when-let* ((timer (plist-get app :player-timer)))
    (cancel-timer timer)
    (etaf-youtube--set app :player-timer nil))
  (ignore-errors (etaf-youtube-service-cancel (plist-get app :service)))
  (ignore-errors (etaf-youtube-service-close (plist-get app :service)))
  (ignore-errors (etaf-youtube-images-cancel (plist-get app :images)))
  (ignore-errors (etaf-youtube-store-close (plist-get app :store)))
  t)

(defun etaf-youtube-check (app)
  "Request APP's account state and remember the reply."
  (etaf-youtube--request app :account (list "check")
                         (lambda (result) (etaf-youtube--apply-account app result)))
  app)

(defun etaf-youtube-state (app)
  "Return APP's state as a detached plist.
Keys are `:view' and its `:params', `:account', `:feed-status', `:items',
`:next', `:selected', `:video', `:media-status', `:comments', `:playing',
`:position', `:duration', `:volume', `:speed', `:quality', `:muted',
`:captions-on', `:sidebar', `:theater', `:theme' and `:message'."
  (let* ((route (etaf-youtube--read app :route))
         (feed (etaf-youtube--read app :feed))
         (video (etaf-youtube--read app :video))
         (comments (etaf-youtube--read app :comments)))
    (list
     :view (plist-get route :view)
     :params (plist-get route :args)
     :account (etaf-youtube--read app :account)
     :feed-status (etaf-youtube--read app :feed-status)
     :title (plist-get feed :title)
     :items (length (plist-get feed :items))
     :next (plist-get feed :next)
     :selected (etaf-youtube--read app :selected)
     :video (and video (list :id (plist-get video :id)
                             :title (plist-get video :title)
                             :author (plist-get video :author)
                             :duration (plist-get video :duration)
                             :like-status (plist-get video :like_status)
                             :subscribed (plist-get video :subscribed)
                             :playability (plist-get video :playability)))
     :media-status (etaf-youtube--read app :media-status)
     :comments (and comments
                    (list :count (plist-get comments :count)
                          :can-comment (plist-get comments :can_comment)
                          :requires-channel (plist-get comments :requires_channel)
                          :items (length (plist-get comments :items))))
     :playing (etaf-youtube--read app :playing)
     :position (etaf-youtube--read app :position)
     :duration (etaf-youtube--read app :duration)
     :volume (etaf-youtube--read app :volume)
     :speed (etaf-youtube--read app :speed)
     :quality (etaf-youtube--read app :quality)
     :muted (etaf-youtube--read app :muted)
     :captions-on (etaf-youtube--read app :captions-on)
     :sidebar (etaf-youtube--read app :sidebar)
     :theater (etaf-youtube--read app :theater)
     :theme (etaf-youtube--read app :theme-mode)
     :message (etaf-youtube--read app :message))))

;;; ---------------------------------------------------------------------------
;;; Lists
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--route-args (app)
  "Return the skill command for APP's current route."
  (let* ((route (etaf-youtube--read app :route))
         (view (plist-get route :view))
         (args (plist-get route :args)))
    (pcase view
      ((pred (lambda (v) (memq v etaf-youtube--feed-views)))
       (list "feed" (symbol-name view)))
      ('search
       (append (list "search" (etaf-youtube--read app :query))
               (unless (equal (etaf-youtube--read app :filter) "all")
                 (list "--filter" (etaf-youtube--read app :filter)))))
      ('channel
       (append (list "browse" (plist-get args :id))
               (when-let* ((params (plist-get args :params)))
                 (list "--params" params))))
      ('playlist (list "browse" (plist-get args :id)))
      (_ nil))))

(defun etaf-youtube--items (app)
  "Return APP's current list items."
  (plist-get (etaf-youtube--read app :feed) :items))

(defun etaf-youtube--prefetch-thumbnails (app items)
  "Request the thumbnails of ITEMS for APP."
  (let ((images (plist-get app :images)))
    (dolist (item items)
      (etaf-youtube-images-request images (plist-get item :thumbnail))
      (etaf-youtube-images-request images (plist-get item :avatar)))))

(defun etaf-youtube--apply-feed (app payload &optional append)
  "Record PAYLOAD as APP's list, appending to the current items when APPEND.
Return the item list."
  (let* ((old (and append (etaf-youtube--read app :feed)))
         (items (append (and old (plist-get old :items))
                        (plist-get payload :items)))
         (feed (plist-put (copy-sequence payload) :items items)))
    ;; Start the downloads before publishing the list: a render problem must
    ;; not be able to skip the prefetch as a side effect.
    (etaf-youtube--prefetch-thumbnails app items)
    (etaf-youtube--write app :feed feed)
    (etaf-youtube--write app :feed-status (list :state 'ready))
    (etaf-youtube--write app :feed-more nil)
    items))

(defun etaf-youtube--feed-failed (app result)
  "Record RESULT as APP's list failure."
  (etaf-youtube--write app :feed-status
                       (list :state 'error
                             :message (plist-get result :message)
                             :hint (plist-get result :hint)))
  (etaf-youtube--write app :feed-more nil)
  (etaf-youtube--note app (or (plist-get result :message) "Could not load the list")
                      'danger))

(defun etaf-youtube--load-feed (app &optional append)
  "Load APP's route list, or the next page when APPEND is non-nil."
  (let* ((feed (etaf-youtube--read app :feed))
         (cursor (and append (plist-get feed :next))))
    (cond
     ((and append (null cursor))
      (etaf-youtube--note app "No more results" 'info))
     (append
      (etaf-youtube--write app :feed-more (list :loading t))
      (etaf-youtube--request
       app :feed (list "more" cursor)
       (lambda (result)
         (if (eq (plist-get result :status) 'ok)
             (etaf-youtube--apply-feed app (plist-get result :value) t)
           (etaf-youtube--feed-failed app result)))))
     (t
      (etaf-youtube--write app :feed-status (list :state 'loading))
      (etaf-youtube--request
       app :feed (etaf-youtube--route-args app)
       (lambda (result)
         (if (eq (plist-get result :status) 'ok)
             (progn
               (etaf-youtube--write app :selected 0)
               (etaf-youtube--apply-feed app (plist-get result :value)))
           (etaf-youtube--feed-failed app result))))))))

(defun etaf-youtube-locate (app view &optional args)
  "Navigate APP to VIEW with ARGS and return APP.
VIEW is `home', `shorts', `subscriptions', `history', `playlists',
`watch-later', `liked', `live', `search', `channel', `playlist' or `watch'."
  (if (eq view 'watch)
      (etaf-youtube-open-video app (plist-get args :id))
    (let ((current (etaf-youtube--read app :route)))
      (unless (equal current (list :view view :args args))
        (etaf-youtube--write app :history
                             (cons current (seq-take (etaf-youtube--read app :history)
                                                     30))))
      (etaf-youtube--write app :route (list :view view :args args))
      (etaf-youtube--stop-player-timer app)
      (etaf-youtube--write app :feed nil)
      (etaf-youtube--write app :feed-more nil)
      (etaf-youtube--write app :selected 0)
      (cond
       ((null (etaf-youtube--route-args app))
        (etaf-youtube--write app :feed-status (list :state 'error :message "Unknown view")))
       (t
        (etaf-youtube--write app :feed-status (list :state 'loading))
        (etaf-youtube--load-feed app)))))
  app)

(defun etaf-youtube-refresh (app)
  "Reload APP's current route."
  (interactive)
  (pcase (plist-get (etaf-youtube--read app :route) :view)
    ('watch (etaf-youtube-open-video
             app (plist-get (plist-get (etaf-youtube--read app :route) :args) :id)))
    (_ (etaf-youtube--write app :feed nil)
       (etaf-youtube--load-feed app)))
  app)

(defun etaf-youtube-load-more (app)
  "Append the next page of APP's list."
  (interactive)
  (etaf-youtube--load-feed app t)
  app)

(defun etaf-youtube-back (app)
  "Return APP to the previous route."
  (interactive)
  (let ((history (etaf-youtube--read app :history)))
    (if (null history)
        (etaf-youtube-locate app 'home)
      (let ((previous (car history)))
        (etaf-youtube--write app :history (cdr history))
        (etaf-youtube--write app :route previous)
        (unless (eq (plist-get previous :view) 'watch)
          (etaf-youtube--stop-player-timer app))
        (etaf-youtube--write app :feed nil)
        (etaf-youtube--write app :selected 0)
        (if (eq (plist-get previous :view) 'watch)
            (etaf-youtube-open-video app (plist-get (plist-get previous :args) :id))
          (etaf-youtube--load-feed app))))))

(defun etaf-youtube-search (app query &optional filter)
  "Search APP for QUERY with optional FILTER and show the results."
  (interactive)
  (etaf-youtube--write app :query (or query ""))
  (etaf-youtube--write app :filter (or filter "all"))
  (etaf-youtube-locate app 'search (list :query query :filter filter)))

(defun etaf-youtube-set-filter (app filter)
  "Switch APP's search result filter to FILTER."
  (etaf-youtube--write app :filter filter)
  (etaf-youtube--write app :feed nil)
  (etaf-youtube--write app :selected 0)
  (when (eq (plist-get (etaf-youtube--read app :route) :view) 'search)
    (etaf-youtube--load-feed app))
  app)

(defun etaf-youtube-apply-chip (app chip)
  "Follow CHIP, a selected filter or tab entry from the current payload.
A cursor reads the next list through `more'; tab params browse the channel
tab they name."
  (let* ((cursor (plist-get chip :cursor))
         (params (plist-get chip :params)))
    (cond
     ((and (stringp params) (> (length params) 0))
      (etaf-youtube-locate app 'channel
                           (list :id (plist-get (plist-get (etaf-youtube--read
                                                            app :route) :args) :id)
                                 :params params)))
     ((stringp cursor)
      (etaf-youtube--write app :feed-status (list :state 'loading))
      (etaf-youtube--request
       app :feed (list "more" cursor)
       (lambda (result)
         (if (eq (plist-get result :status) 'ok)
             (progn
               (etaf-youtube--write app :selected 0)
               (etaf-youtube--apply-feed app (plist-get result :value)))
           (etaf-youtube--feed-failed app result)))))
     (t (etaf-youtube--note app "This filter is not available" 'info)))
    app))

;;; ---------------------------------------------------------------------------
;;; Selection
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-select (app delta)
  "Move APP's selection by DELTA within the current list."
  (interactive)
  (let* ((items (etaf-youtube--items app))
         (count (length items))
         (current (etaf-youtube--read app :selected)))
    (when (> count 0)
      (etaf-youtube--write app :selected
                           (max 0 (min (1- count) (+ current delta))))))
  app)

(defun etaf-youtube-press-item (app index)
  "Activate APP's item at zero-based INDEX."
  (let ((items (etaf-youtube--items app)))
    (when (and (integerp index) (>= index 0) (< index (length items)))
      (etaf-youtube--write app :selected index)
      (etaf-youtube--activate-item app (nth index items))))
  app)

(defun etaf-youtube-activate (app)
  "Activate APP's currently selected item."
  (interactive)
  (when-let* ((item (nth (etaf-youtube--read app :selected)
                         (etaf-youtube--items app))))
    (etaf-youtube--activate-item app item))
  app)

(defun etaf-youtube--activate-item (app item)
  "Open ITEM from APP according to its kind."
  (pcase (plist-get item :kind)
    ((or 'video 'short) (etaf-youtube-open-video app (plist-get item :id)))
    ('channel (etaf-youtube-locate app 'channel (list :id (plist-get item :id))))
    ('playlist (etaf-youtube-locate app 'playlist (list :id (plist-get item :id))))
    ('comment nil)
    (_ (when-let* ((id (plist-get item :id)))
         (etaf-youtube-open-video app id)))))

;;; ---------------------------------------------------------------------------
;;; Watch page
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-open-video (app id)
  "Open video ID in APP: details, comments and a resolved media source."
  (interactive)
  (when (or (null id) (string-empty-p id))
    (user-error "A video id is required"))
  (let ((current (etaf-youtube--read app :route)))
    (unless (and (eq (plist-get current :view) 'watch)
                 (equal (plist-get (plist-get current :args) :id) id))
      (etaf-youtube--write app :history
                           (cons current (seq-take (etaf-youtube--read app :history)
                                                   30)))))
  (etaf-youtube--write app :route (list :view 'watch :args (list :id id)))
  (etaf-youtube--write app :video nil)
  (etaf-youtube--write app :video-status (list :state 'loading))
  (etaf-youtube--write app :media nil)
  (etaf-youtube--write app :media-status (list :state 'loading))
  (etaf-youtube--write app :comments nil)
  (etaf-youtube--write app :comments-status (list :state 'loading))
  (etaf-youtube--write app :comments-sort nil)
  (etaf-youtube--write app :replies (make-hash-table :test #'equal))
  (etaf-youtube--write app :captions nil)
  (etaf-youtube--write app :captions-on nil)
  (etaf-youtube--write app :position 0)
  (etaf-youtube--write app :duration 0)
  (etaf-youtube--write app :playing nil)
  (etaf-youtube--stop-player-timer app)
  (etaf-youtube--request
   app :video (list "video" id)
   (lambda (result)
     (if (eq (plist-get result :status) 'ok)
         (let ((video (plist-get result :value)))
           (etaf-youtube--write app :video video)
           (etaf-youtube--write app :video-status (list :state 'ready))
           (etaf-youtube--write app :duration (or (plist-get video :duration) 0))
           (etaf-youtube--prefetch-thumbnails
            app (append (plist-get video :related) nil))
           (etaf-youtube-images-request (plist-get app :images)
                                        (plist-get video :thumbnail))
           (when-let* ((resume (ignore-errors
                                 (etaf-youtube-store-resume
                                  (plist-get app :store) id))))
             (when (and (numberp resume) (> resume 5))
               (etaf-youtube--write app :pending-seek resume))))
       (etaf-youtube--write app :video-status
                            (list :state 'error
                                  :message (plist-get result :message))))))
  (etaf-youtube--request
   app :comments (list "comments" id)
   (lambda (result)
     (if (eq (plist-get result :status) 'ok)
         (progn
           (etaf-youtube--write app :comments (plist-get result :value))
           (etaf-youtube--write app :comments-status (list :state 'ready)))
       (etaf-youtube--write app :comments-status
                            (list :state 'error
                                  :message (plist-get result :message))))))
  (etaf-youtube--resolve-media app id)
  app)

(defun etaf-youtube--resolve-media (app id &optional quality)
  "Resolve video ID's media at QUALITY (or APP's choice) for APP."
  (let ((quality (or quality (etaf-youtube--read app :quality) 720)))
    (etaf-youtube--write app :media-status (list :state 'loading))
    (etaf-youtube--request
     app :source (list "source" id "--quality" (number-to-string quality))
     (lambda (result)
       (if (eq (plist-get result :status) 'ok)
           (let ((media (plist-get result :value)))
             (etaf-youtube--write app :media media)
             (etaf-youtube--write app :media-status (list :state 'ready))
             (etaf-youtube--start-player-timer app))
         (etaf-youtube--write app :media-status
                              (list :state 'error
                                    :message (plist-get result :message)
                                    :hint (plist-get result :hint))))))))

(defun etaf-youtube--header-alist (headers)
  "Return HEADERS as an alist of (NAME . VALUE) strings.
The skill emits a JSON object as a plist with keyword names; the ETAF video
source normalizer takes an alist."
  (let (result)
    (while (and (consp headers) (cdr headers))
      (let ((name (car headers)))
        (push (cons (if (keywordp name)
                        (substring (symbol-name name) 1)
                      (format "%s" name))
                    (format "%s" (cadr headers)))
              result))
      (setq headers (cddr headers)))
    (nreverse result)))

(defun etaf-youtube-media-src (app)
  "Return APP's resolved media as a normalized `etaf-video' source, or nil."
  (when-let* ((media (etaf-youtube--read app :media)))
    (list :kind 'url
          :url (plist-get media :video_url)
          :audio-url (plist-get media :audio_url)
          :headers (etaf-youtube--header-alist (plist-get media :headers))
          :proxy (plist-get media :proxy)
          :width (plist-get media :width)
          :height (plist-get media :height)
          :fps (plist-get media :fps)
          :duration (plist-get media :duration)
          :audio t)))

(defun etaf-youtube--player-state (app)
  "Return the mounted player's state, or nil when it is not mounted."
  (ignore-errors (etaf-video-state (plist-get app :player-handle))))

(defun etaf-youtube--start-player-timer (app)
  "Start polling APP's player once a second."
  (unless (plist-get app :player-timer)
    (etaf-youtube--set app :player-timer
                       (run-at-time 1.0 1.0 (lambda () (etaf-youtube--sync-player app))))))

(defun etaf-youtube--stop-player-timer (app)
  "Stop APP's player timer."
  (when-let* ((timer (plist-get app :player-timer)))
    (cancel-timer timer)
    (etaf-youtube--set app :player-timer nil)))

(defun etaf-youtube--sync-player (app)
  "Read the mounted player's state into APP and apply a pending seek."
  (when-let* ((state (etaf-youtube--player-state app)))
    (etaf-youtube--write app :playing (and (plist-get state :playing) t))
    (etaf-youtube--write app :position (or (plist-get state :position) 0))
    (when-let* ((duration (plist-get state :duration)))
      (when (> duration 0) (etaf-youtube--write app :duration duration)))
    (when-let* ((seek (etaf-youtube--read app :pending-seek)))
      (etaf-youtube--write app :pending-seek nil)
      (ignore-errors (etaf-video-seek (plist-get app :player-handle) seek))
      (etaf-youtube--write app :position seek))
    (when (plist-get state :ended)
      (etaf-youtube--write app :playing nil))))

(defun etaf-youtube-toggle-playback (app)
  "Toggle APP's video between playing and paused."
  (interactive)
  (cond
   ((null (etaf-youtube--read app :media))
    (when-let* ((video (etaf-youtube--read app :video)))
      (etaf-youtube--resolve-media app (plist-get video :id))))
   ((etaf-youtube--player-state app)
    (ignore-errors
      (etaf-video-toggle-playback (plist-get app :player-handle)))
    (etaf-youtube--write app :playing
                         (and (plist-get (etaf-youtube--player-state app)
                                         :playing)
                              t)))
   (t (etaf-youtube--note app "The player is not ready yet" 'info)))
  app)

(defun etaf-youtube-seek (app seconds)
  "Move APP's video to SECONDS."
  (interactive)
  (let* ((duration (etaf-youtube--read app :duration))
         (target (max 0 (if (and (numberp duration) (> duration 0))
                            (min seconds duration)
                          seconds))))
    (if (etaf-youtube--player-state app)
        (progn
          (ignore-errors (etaf-video-seek (plist-get app :player-handle) target))
          (etaf-youtube--write app :position target))
      (etaf-youtube--write app :pending-seek target)
      (etaf-youtube--write app :position target)))
  app)

(defun etaf-youtube-seek-by (app delta)
  "Move APP's video DELTA seconds from its current position."
  (etaf-youtube-seek app (+ (etaf-youtube--read app :position) delta)))

(defun etaf-youtube-set-volume (app volume)
  "Set APP's volume to VOLUME between 0 and 100."
  (interactive)
  (let ((volume (max 0 (min 100 (round volume)))))
    (etaf-youtube--write app :volume volume)
    (ignore-errors
      (when (etaf-youtube--player-state app)
        (etaf-video-set-volume (plist-get app :player-handle) volume)))
    (ignore-errors
      (etaf-youtube-store-set-setting (plist-get app :store) "volume" volume)))
  app)

(defun etaf-youtube-set-speed (app speed)
  "Set APP's playback rate to SPEED, a positive number."
  (interactive)
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (etaf-youtube--write app :speed speed)
  (ignore-errors
    (when (etaf-youtube--player-state app)
      (etaf-video-set-speed (plist-get app :player-handle) speed)))
  (ignore-errors
    (etaf-youtube-store-set-setting (plist-get app :store) "speed" speed))
  app)

(defun etaf-youtube-set-quality (app quality)
  "Switch APP's video to QUALITY, a supported height."
  (interactive)
  (unless (memq quality etaf-youtube--quality-levels)
    (user-error "Unsupported quality: %S" quality))
  (etaf-youtube--write app :quality quality)
  (ignore-errors
    (etaf-youtube-store-set-setting (plist-get app :store) "quality" quality))
  (when-let* ((video (etaf-youtube--read app :video)))
    (let ((position (etaf-youtube--read app :position)))
      (etaf-youtube--write app :pending-seek
                           (and (numberp position) (> position 1) position))
      (etaf-youtube--resolve-media app (plist-get video :id) quality)))
  app)

(defun etaf-youtube-toggle-mute (app)
  "Toggle APP's audio."
  (interactive)
  (let ((muted (not (etaf-youtube--read app :muted))))
    (etaf-youtube--write app :muted muted)
    (ignore-errors
      (when (etaf-youtube--player-state app)
        (etaf-video-set-audio (plist-get app :player-handle) (not muted)))))
  app)

(defun etaf-youtube-toggle-captions (app)
  "Turn APP's subtitles on or off."
  (interactive)
  (if (etaf-youtube--read app :captions-on)
      (progn
        (etaf-youtube--write app :captions-on nil)
        (etaf-youtube--write app :captions nil))
    (let* ((media (etaf-youtube--read app :media))
           (tracks (plist-get media :subtitles))
           (language (plist-get (car tracks) :language))
           (video (etaf-youtube--read app :video)))
      (if (and language video)
          (progn
            (etaf-youtube--write app :captions-on t)
            (etaf-youtube--request
             app :captions
             (list "captions" (plist-get video :id) "--language" language)
             (lambda (result)
               (if (eq (plist-get result :status) 'ok)
                   (etaf-youtube--write app :captions (plist-get result :value))
                 (etaf-youtube--write app :captions-on nil)
                 (etaf-youtube--note app
                                     (or (plist-get result :message)
                                         "Could not load subtitles")
                                     'danger)))))
        (etaf-youtube--note app "This video has no subtitle track" 'info))))
  app)

(defun etaf-youtube-caption-text (app)
  "Return APP's subtitle text at the current position, or nil.
Cues are half-open intervals: a cue is active from its `start' inclusive to
its `end' exclusive."
  (when-let* ((captions (etaf-youtube--read app :captions))
              (position (etaf-youtube--read app :position)))
    (when (numberp position)
      (when-let* ((cue (seq-find (lambda (cue)
                                   (and (>= position (or (plist-get cue :start) 0))
                                        (< position (or (plist-get cue :end) 0))))
                                 (plist-get captions :cues)))
                  (text (plist-get cue :text)))
        (and (stringp text) (not (string-empty-p text)) text)))))

;;; ---------------------------------------------------------------------------
;;; Comments
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-sort-comments (app cursor)
  "Read APP's comments in the order CURSOR names."
  (when cursor
    (etaf-youtube--write app :comments-status (list :state 'loading))
    (etaf-youtube--write app :comments-sort cursor)
    (etaf-youtube--request
     app :comments (list "more" cursor)
     (lambda (result)
       (if (eq (plist-get result :status) 'ok)
           (progn
             (etaf-youtube--write app :comments (plist-get result :value))
             (etaf-youtube--write app :comments-status (list :state 'ready)))
         (etaf-youtube--write app :comments-status
                              (list :state 'error
                                    :message (plist-get result :message)))))))
  app)

(defun etaf-youtube--comment-item (app comment-id)
  "Return APP's comment row for COMMENT-ID, or nil."
  (seq-find (lambda (item) (equal comment-id (plist-get item :id)))
            (plist-get (etaf-youtube--read app :comments) :items)))

(defun etaf-youtube-load-replies (app comment-id &optional cursor)
  "Load CURSOR's replies to COMMENT-ID in APP, or its first page."
  (let ((cursor (or cursor
                    (etaf-youtube-replies-cursor app comment-id)
                    (plist-get (etaf-youtube--comment-item app comment-id) :replies))))
    (when cursor
      (etaf-youtube--request-token
       app (intern (format "replies:%s" comment-id))
       (list "more" cursor)
       (lambda (result token)
         (when (etaf-youtube--current-p app (intern (format "replies:%s" comment-id))
                                        token)
           (let ((replies (etaf-youtube--read app :replies)))
             (if (eq (plist-get result :status) 'ok)
                 (let* ((payload (plist-get result :value))
                        (old (gethash comment-id replies))
                        (items (append (plist-get old :items)
                                       (plist-get payload :items))))
                   (puthash comment-id
                            (plist-put (copy-sequence payload) :items items)
                            replies)
                   (etaf-youtube--write app :replies replies))
               (etaf-youtube--note app (or (plist-get result :message)
                                           "Could not load replies")
                                   'danger))))))))
  app)

(defun etaf-youtube-replies-cursor (app comment-id)
  "Return APP's stored replies cursor for COMMENT-ID, or nil."
  (plist-get (gethash comment-id (etaf-youtube--read app :replies)) :next))

(defun etaf-youtube-replies (app comment-id)
  "Return APP's loaded replies for COMMENT-ID."
  (plist-get (gethash comment-id (etaf-youtube--read app :replies)) :items))

;;; ---------------------------------------------------------------------------
;;; Writes
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--apply-write (app result operation)
  "Record write RESULT for OPERATION in APP and report its certainty."
  (if (not (eq (plist-get result :status) 'ok))
      (etaf-youtube--note app (or (plist-get result :message)
                                  "The action failed")
                          'danger)
    (let* ((payload (plist-get result :value))
           (status (plist-get payload :status))
           (verified (plist-get payload :verified)))
      (pcase operation
        ('like (etaf-youtube--patch-video app :like_status "LIKE"))
        ('dislike (etaf-youtube--patch-video app :like_status "DISLIKE"))
        ('unrate (etaf-youtube--patch-video app :like_status "INDIFFERENT"))
        ('subscribe (etaf-youtube--patch-video app :subscribed t))
        ('unsubscribe (etaf-youtube--patch-video app :subscribed nil)))
      (cond
       ((member status '("confirmed" "unchanged"))
        (etaf-youtube--note app
                            (pcase operation
                              ('like "已点赞")
                              ('dislike "已点踩")
                              ('unrate "已取消评分")
                              ('subscribe "已订阅")
                              ('unsubscribe "已取消订阅")
                              ('save "已保存到播放列表")
                              ('comment "评论已发布")
                              (_ "完成"))
                            'success))
       ((equal status "submitted")
        (etaf-youtube--note
         app (format "%s：已提交但未能回读确认，请稍后在网页核对"
                     (pcase operation
                       ('comment "评论")
                       ('subscribe "订阅")
                       ('unsubscribe "退订")
                       ('save "保存")
                       (_ "操作")))
         'warning))
       ((equal status "blocked")
        (etaf-youtube--note app (or (plist-get payload :message)
                                    "当前账号没有权限执行该操作")
                            'danger))
       (t
        (etaf-youtube--note app (format "操作结果：%s" (or status "未知"))
                            (if verified 'success 'warning))))))
  app)

(defun etaf-youtube--patch-video (app key value)
  "Copy APP's video and set KEY to VALUE so the watch page repaints."
  (when-let* ((video (etaf-youtube--read app :video)))
    (etaf-youtube--write app :video (plist-put (copy-sequence video) key value))))

(defun etaf-youtube--write-action (app operation &optional yes extra)
  "Submit OPERATION for APP's current video.
YES authorizes the real write; without it the caller must have preflighted.
EXTRA appends the operation's own arguments."
  (let ((video (etaf-youtube--read app :video)))
    (if (null video)
        (etaf-youtube--note app "Open a video first" 'info)
      (etaf-youtube--request
       app :action
       (append (list "action" operation (plist-get video :id))
               extra
               (when yes (list "--yes")))
       (lambda (result)
         (etaf-youtube--apply-write app result (intern operation))))))
  app)

(defun etaf-youtube-like (app &optional yes)
  "Like APP's video; YES submits the write instead of its offline preview."
  (interactive)
  (etaf-youtube--write-action app "like" yes))

(defun etaf-youtube-dislike (app &optional yes)
  "Dislike APP's video; YES submits the write."
  (interactive)
  (etaf-youtube--write-action app "dislike" yes))

(defun etaf-youtube-unrate (app &optional yes)
  "Remove APP's rating; YES submits the write."
  (interactive)
  (etaf-youtube--write-action app "unrate" yes))

(defun etaf-youtube-subscribe (app subscribe-p &optional yes)
  "Subscribe to APP's video author when SUBSCRIBE-P, otherwise unsubscribe.
YES submits the write instead of its offline preview."
  (interactive)
  (etaf-youtube--write-action app (if subscribe-p "subscribe" "unsubscribe") yes))

(defun etaf-youtube-save (app &optional playlist yes)
  "Save APP's video to PLAYLIST; without it the account's default list.
YES submits the write instead of its offline preview."
  (interactive)
  (etaf-youtube--write-action app "save" yes
                              (when playlist (list "--playlist" playlist))))

(defun etaf-youtube-comment (app text &optional yes)
  "Post TEXT as a comment on APP's video; YES submits the write."
  (interactive)
  (unless (and (stringp text) (not (string-empty-p (string-trim text))))
    (user-error "A comment needs text"))
  (etaf-youtube--write-action app "comment" yes (list "--text" text)))

;;; ---------------------------------------------------------------------------
;;; Appearance
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-set-theme (app mode)
  "Switch APP to the appearance MODE, `dark' or `light'."
  (unless (memq mode '(dark light))
    (signal 'etaf-youtube-error (list (format "Unknown appearance: %S" mode))))
  (etaf-youtube--write app :theme-mode mode)
  (etaf-youtube--write app :palette (etaf-youtube-theme-defaults mode))
  (ignore-errors
    (etaf-youtube-store-set-setting (plist-get app :store) "theme"
                                    (symbol-name mode)))
  app)

(defun etaf-youtube-cycle-theme (app)
  "Switch APP to the other appearance."
  (interactive)
  (etaf-youtube-set-theme app (if (eq (etaf-youtube--read app :theme-mode) 'dark)
                                  'light
                                'dark)))

(defun etaf-youtube-toggle-sidebar (app)
  "Fold or unfold APP's sidebar."
  (interactive)
  (etaf-youtube--write app :sidebar (not (etaf-youtube--read app :sidebar)))
  app)

(defun etaf-youtube-toggle-theater (app)
  "Switch APP's watch page between two columns and one."
  (interactive)
  (etaf-youtube--write app :theater (not (etaf-youtube--read app :theater)))
  app)

(defun etaf-youtube-scrub (app value)
  "Preview APP's progress at VALUE seconds without seeking yet."
  (etaf-youtube--write app :scrub (and (numberp value) value))
  app)

(defun etaf-youtube-commit-scrub (app)
  "Seek APP's video to its scrubbed position and clear the preview."
  (when-let* ((value (etaf-youtube--read app :scrub)))
    (etaf-youtube--write app :scrub nil)
    (etaf-youtube-seek app value))
  app)

(defun etaf-youtube-quality-choices (app)
  "Return the quality heights APP's current media offers for selection.
The resolved source's `:qualities' is filtered to the supported levels, or
`(720)' when no source has been resolved yet."
  (let* ((media (etaf-youtube--read app :media))
         (available (plist-get media :qualities))
         (choices (seq-filter (lambda (height)
                                (or (null available)
                                    (memq height available)))
                              etaf-youtube--quality-levels)))
    (or choices '(720))))

(provide 'etaf-youtube-model)
;;; etaf-youtube-model.el ends here
