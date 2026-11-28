;;; etaf-youtube-model.el --- Reactive state, media, queue and actions for etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns plain data, reactive refs, stream caches, queue state,
;; binary-search subtitle lookup, chapter/timestamp parsing, and asynchronous
;; backend requests.  It never renders buffers directly; views project refs and
;; the Watch HUD pushes high-frequency playback telemetry (clock, duration,
;; progress bar, subtitle line, buffering status) through ETAF's Retained Host
;; leaf-update boundary so active playback triggers zero full-view rerenders.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-youtube-theme)
(require 'etaf-youtube-images)
(require 'etaf-youtube-service)
(require 'etaf-youtube-store)

(defvar etaf-youtube-player-handle 'etaf-youtube-player
  "Base handle name registered by the mounted video Component of the application.")

(defconst etaf-youtube--quality-levels '(2160 1440 1080 720 480 360 240 144)
  "Video heights a quality choice may name, from high to low.")

(defconst etaf-youtube--speeds '(0.5 0.75 1 1.25 1.5 1.75 2)
  "Standard playback speed presets.")

(defconst etaf-youtube--resume-interval 15
  "Position change in seconds that persists a new resume point.")

(defconst etaf-youtube--resume-end-margin 15
  "Seconds before the end where a stored resume point is not restored.")

(defconst etaf-youtube--feed-views
  '(home shorts subscriptions history playlists watch-later liked live)
  "Routes that read one of the account's feed lists.")

(defconst etaf-youtube--nav-views
  '(home shorts subscriptions history playlists watch-later liked live)
  "Sidebar destinations in their display order.")

;; Retained Host leaf refs for zero-reflow 200ms Watch HUD updates.
(defconst etaf-youtube--hud-time-ref 'yt-watch-time)
(defconst etaf-youtube--hud-duration-ref 'yt-watch-duration)
(defconst etaf-youtube--hud-cinema-time-ref 'yt-watch-cinema-time)
(defconst etaf-youtube--hud-progress-fill-ref 'yt-watch-progress-fill)
(defconst etaf-youtube--hud-subtitle-ref 'yt-watch-subtitle)
(defconst etaf-youtube--hud-status-ref 'yt-watch-status)
(defconst etaf-youtube--hud-spinner-ref 'yt-watch-spinner)
(defconst etaf-youtube--pip-id 'etaf-youtube
  "Shared `etaf-pip' host identifier for YouTube.")
(defconst etaf-youtube--pip-time-ref 'yt-pip-time)
(defconst etaf-youtube--pip-subtitle-ref 'yt-pip-subtitle)
(defconst etaf-youtube--pip-progress-fill-ref 'yt-pip-progress-fill)

(defconst etaf-youtube--spinner-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Braille spinner glyphs rotated in place during loading and buffering.")

;;; ---------------------------------------------------------------------------
;;; Formatting & timestamp/chapter helpers
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--clock (seconds)
  "Format SECONDS as `MM:SS' or `H:MM:SS'."
  (let ((secs (max 0 (round (or seconds 0)))))
    (if (>= secs 3600)
        (format "%d:%02d:%02d" (/ secs 3600) (/ (% secs 3600) 60) (% secs 60))
      (format "%02d:%02d" (/ secs 60) (% secs 60)))))

(defun etaf-youtube--nonempty-string (value)
  "Return VALUE when it is a non-empty string, otherwise nil."
  (and (stringp value) (not (string-empty-p (string-trim value))) value))

(defun etaf-youtube--parse-duration-seconds (value)
  "Parse DURATION VALUE (number or `MM:SS' / `H:MM:SS' string) to integer seconds."
  (save-match-data
    (cond
     ((numberp value) (max 0 (round value)))
     ((and (stringp value) (string-match "\\`\\([0-9]+\\):\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\'" (string-trim value)))
      (+ (* 3600 (string-to-number (match-string 1 (string-trim value))))
         (* 60 (string-to-number (match-string 2 (string-trim value))))
         (string-to-number (match-string 3 (string-trim value)))))
     ((and (stringp value) (string-match "\\`\\([0-9]+\\):\\([0-9]\\{2\\}\\)\\'" (string-trim value)))
      (+ (* 60 (string-to-number (match-string 1 (string-trim value))))
         (string-to-number (match-string 2 (string-trim value)))))
     (t 0))))

(defun etaf-youtube--extract-timestamps (text)
  "Extract unique `(SECONDS . LABEL)' timestamp markers from TEXT."
  (when (and (stringp text) (not (string-empty-p text)))
    (save-match-data
      (let ((pos 0) (seen (make-hash-table :test #'eql)) (out nil))
        (while (and (< pos (length text))
                    (string-match "\\(?:^\\|[^0-9:]\\)\\(\\(?:[0-9]+:\\)?[0-9]\\{1,2\\}:[0-5][0-9]\\)\\(?:$\\|[^0-9:]\\)" text pos))
          (let* ((tok (match-string 1 text))
                 (end (match-end 1))
                 (sec (etaf-youtube--parse-duration-seconds tok)))
            (setq pos (max (1+ pos) end))
            (unless (gethash sec seen)
              (puthash sec t seen)
              (push (cons sec tok) out))))
        (nreverse out)))))

(defun etaf-youtube--chapters-from-description (description)
  "Parse YouTube-style timestamp chapter lines from DESCRIPTION."
  (when (and (stringp description) (not (string-empty-p description)))
    (let (chapters)
      (dolist (line (split-string description "\n"))
        (let ((trimmed (string-trim line)))
          (when (string-match "\\`\\(\\(?:[0-9]+:\\)?[0-9]\\{1,2\\}:[0-5][0-9]\\)[ \t\\-–—:|]+\\(.+\\)\\'" trimmed)
            (let ((start (etaf-youtube--parse-duration-seconds (match-string 1 trimmed)))
                  (title (string-trim (match-string 2 trimmed))))
              (unless (string-empty-p title)
                (push (list :start start :title title) chapters))))))
      (when (>= (length chapters) 2)
        (sort (nreverse chapters) (lambda (a b) (< (plist-get a :start) (plist-get b :start))))))))

;;; ---------------------------------------------------------------------------
;;; Accessors & async tokens
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

(defun etaf-youtube--dismiss-note (app)
  "Clear APP's transient toast notification."
  (when-let* ((timer (plist-get app :toast-timer)))
    (cancel-timer timer)
    (etaf-youtube--set app :toast-timer nil))
  (etaf-youtube--write app :message nil))

(defun etaf-youtube--note (app text &optional variant sticky)
  "Show TEXT as APP's transient message with VARIANT styling.
Auto-dismisses after 4.5s unless STICKY is non-nil (for warnings/errors)."
  (when-let* ((timer (plist-get app :toast-timer)))
    (cancel-timer timer)
    (etaf-youtube--set app :toast-timer nil))
  (let* ((var (or variant 'info))
         (stamp (float-time))
         (msg (list :text text :variant var :at stamp)))
    (etaf-youtube--write app :message msg)
    (unless (or sticky (memq var '(warning danger)))
      (etaf-youtube--set
       app :toast-timer
       (run-at-time 4.5 nil
                    (lambda ()
                      (when (equal (plist-get (etaf-youtube--read app :message) :at) stamp)
                        (etaf-youtube--set app :toast-timer nil)
                        (etaf-youtube--write app :message nil))))))))

(defun etaf-youtube--state-name (app key)
  "Return the state word in APP's KEY status plist."
  (plist-get (etaf-youtube--read app key) :state))

(defun etaf-youtube--request (app key args callback)
  "Run backend ARGS for APP under KEY and call CALLBACK with the result."
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
  "Run ARGS and call CALLBACK with (RESULT TOKEN)."
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
;;; Session creation & teardown
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--setting-number (store name default)
  "Return STORE's numeric setting NAME, or DEFAULT."
  (let ((text (ignore-errors (etaf-youtube-store-setting store name))))
    (if (and (stringp text) (string-match-p "\\`-?[0-9.]+\\'" text))
        (string-to-number text)
      default)))

(defun etaf-youtube--setting-bool (store name default)
  "Return STORE's boolean setting NAME, or DEFAULT."
  (let ((text (ignore-errors (etaf-youtube-store-setting store name))))
    (cond
     ((equal text "t") t)
     ((equal text "nil") nil)
     (t default))))

(cl-defun etaf-youtube-create (&key service images store)
  "Create the application model and return it.
SERVICE defaults to a real backend transport, IMAGES to the default thumbnail
cache and STORE to the SQLite store.  The account check starts immediately;
`etaf-youtube-state' reports everything a caller or a test needs."
  (let* ((service (or service (etaf-youtube-service-create)))
         (images (or images (etaf-youtube-images-create)))
         (store (if (eq store :none) nil (or store (etaf-youtube-store-open))))
         (mode (or (let ((text (ignore-errors
                                 (etaf-youtube-store-setting store "theme"))))
                     (and (stringp text) (memq (intern text) '(dark light)) (intern text)))
                   etaf-youtube-theme-mode))
         (handle (make-symbol (symbol-name (or etaf-youtube-player-handle 'etaf-youtube-player))))
         (app (list
               :service service
               :images images
               :store store
               :tokens (make-hash-table :test #'eq)
               :media-cache (make-hash-table :test #'equal)
               :route (etaf-ref (list :view 'home :args nil) :name 'etaf-youtube-route)
               :history (etaf-ref nil :name 'etaf-youtube-history)
               :feed (etaf-ref nil :name 'etaf-youtube-feed)
               :feed-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-feed-status)
               :feed-more (etaf-ref nil :name 'etaf-youtube-feed-more)
               :account (etaf-ref nil :name 'etaf-youtube-account)
               :account-menu (etaf-ref nil :name 'etaf-youtube-account-menu)
               :video (etaf-ref nil :name 'etaf-youtube-video)
               :video-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-video-status)
               :media (etaf-ref nil :name 'etaf-youtube-media)
               :media-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-media-status)
               :comments (etaf-ref nil :name 'etaf-youtube-comments)
               :comments-status (etaf-ref (list :state 'idle) :name 'etaf-youtube-comments-status)
               :comments-more (etaf-ref nil :name 'etaf-youtube-comments-more)
               :related-more (etaf-ref nil :name 'etaf-youtube-related-more)
               :replies (etaf-ref (make-hash-table :test #'equal) :name 'etaf-youtube-replies)
               :replies-version (etaf-ref 0 :name 'etaf-youtube-replies-version)
               :replies-collapsed (make-hash-table :test #'equal)
               :selected (etaf-ref nil :name 'etaf-youtube-selected)
               :query (etaf-ref "" :name 'etaf-youtube-query)
               :filter (etaf-ref "all" :name 'etaf-youtube-filter)
               :sidebar (etaf-ref t :name 'etaf-youtube-sidebar)
               :theater (etaf-ref nil :name 'etaf-youtube-theater)
               :fullscreen (etaf-ref nil :name 'etaf-youtube-fullscreen)
               :theme-mode (etaf-ref mode :name 'etaf-youtube-theme-mode)
               :palette (etaf-ref (etaf-youtube-theme-defaults mode)
                                  :name 'etaf-youtube-palette)
               :volume (etaf-ref (etaf-youtube--setting-number store "volume" 100)
                                 :name 'etaf-youtube-volume)
               :speed (etaf-ref (etaf-youtube--setting-number store "speed" 1)
                                :name 'etaf-youtube-speed)
               :muted (etaf-ref nil :name 'etaf-youtube-muted)
               :audio-on (etaf-ref t :name 'etaf-youtube-audio-on)
               :quality (etaf-ref (etaf-youtube--setting-number store "quality" 720)
                                  :name 'etaf-youtube-quality)
               :captions-on (etaf-ref nil :name 'etaf-youtube-captions-on)
               :captions (etaf-ref nil :name 'etaf-youtube-captions)
               :caption-vec nil
               :caption-language (etaf-ref nil :name 'etaf-youtube-caption-language)
               :caption-filter (etaf-ref "" :name 'etaf-youtube-caption-filter)
               :chapters (etaf-ref nil :name 'etaf-youtube-chapters)
               :desc-expanded (etaf-ref nil :name 'etaf-youtube-desc-expanded)
               :watch-tab (etaf-ref 'info :name 'etaf-youtube-watch-tab)
               :watch-drawer (etaf-ref nil :name 'etaf-youtube-watch-drawer)
               :quality-menu (etaf-ref nil :name 'etaf-youtube-quality-menu)
               :audio-only (etaf-ref nil :name 'etaf-youtube-audio-only)
               :auto-next (etaf-ref (etaf-youtube--setting-bool store "auto-next" t)
                                    :name 'etaf-youtube-auto-next)
               :buffering (etaf-ref nil :name 'etaf-youtube-buffering)
               :has-frame (etaf-ref nil :name 'etaf-youtube-has-frame)
               :poster-url (etaf-ref nil :name 'etaf-youtube-poster-url)
               :play-error (etaf-ref nil :name 'etaf-youtube-play-error)
               :queue (etaf-ref nil :name 'etaf-youtube-queue)
               :queue-index (etaf-ref nil :name 'etaf-youtube-queue-index)
               :comment-draft (etaf-ref "" :name 'etaf-youtube-comment-draft)
               :comments-sort (etaf-ref nil :name 'etaf-youtube-comments-sort)
               :position (etaf-ref 0 :name 'etaf-youtube-position)
               :progress-ref (etaf-ref 0.0 :name 'etaf-youtube-progress)
               :resume (etaf-ref nil :name 'etaf-youtube-resume)
               :resume-recorded nil
               :scrub (etaf-ref nil :name 'etaf-youtube-scrub)
               :display-position nil
               :playing (etaf-ref nil :name 'etaf-youtube-playing)
               :duration (etaf-ref 0 :name 'etaf-youtube-duration)
               :message (etaf-ref nil :name 'etaf-youtube-message)
               :pending-seek (etaf-ref nil :name 'etaf-youtube-pending-seek)
               :use-alt-proto nil
               ;; Non-reactive live playback slots updated at 200ms without rerender.
               :live-position 0.0
               :live-duration 0.0
               :live-time-text "00:00"
               :live-duration-text "00:00"
               :live-subtitle-text ""
               :live-status-text ""
               :live-spinner-text ""
               :spinner-index 0
               :loading-reason nil
               :live-engine nil
               :ended-seen nil
               :bg-audio-proc nil
               :bg-audio-start-wall nil
               :bg-audio-base-pos 0.0
               :pip-active (etaf-ref nil :name 'etaf-youtube-pip-active)
               :pip-cc (etaf-ref nil :name 'etaf-youtube-pip-cc)
               :pip-handle (make-symbol "etaf-youtube-pip-video")
               :pip-size 'medium
               :pip-corner 'bottom-right
               :player-handle handle
               :player-timer nil
               :toast-timer nil
               :activity-fn nil
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

(defun etaf-youtube--bg-audio-stop (app)
  "Stop any background audio-only process owned by APP."
  (when-let* ((proc (plist-get app :bg-audio-proc)))
    (when (process-live-p proc)
      (ignore-errors (delete-process proc)))
    (etaf-youtube--set app :bg-audio-proc nil))
  (etaf-youtube--set app :bg-audio-start-wall nil))

(defun etaf-youtube--bg-audio-position (app)
  "Return estimated playback seconds for APP's background audio process."
  (let ((base (float (or (plist-get app :bg-audio-base-pos) 0.0)))
        (wall (plist-get app :bg-audio-start-wall))
        (spd (float (or (etaf-youtube--read app :speed) 1.0)))
        (dur (float (or (plist-get app :live-duration) 0.0))))
    (if (and wall (etaf-youtube--read app :playing))
        (let ((pos (+ base (* (- (float-time) wall) spd))))
          (if (> dur 0) (min pos dur) pos))
      base)))

(defun etaf-youtube--bg-audio-start (app &optional start-sec)
  "Start lightweight background audio-only playback for APP at START-SEC."
  (etaf-youtube--bg-audio-stop app)
  (when-let* ((src (etaf-youtube-media-src app)))
    (let* ((target (or (plist-get src :audio-url) (plist-get src :url)))
           (pos (float (max 0 (or start-sec (plist-get app :live-position) 0))))
           (vol (or (etaf-youtube--read app :volume) 100))
           (spd (or (etaf-youtube--read app :speed) 1))
           (muted (etaf-youtube--read app :muted))
           (proxy (plist-get src :proxy))
           (ua (cdr (assoc "User-Agent" (plist-get src :headers))))
           (mpv (executable-find "mpv"))
           (ffplay (executable-find "ffplay"))
           (cmd
            (cond
             (mpv
              (append
               (list mpv "--no-config" "--no-video" "--terminal=no" "--ytdl=no"
                     (format "--start=%.2f" pos)
                     (format "--volume=%d" (if muted 0 vol))
                     (format "--speed=%g" spd)
                     "--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")
               (when proxy (list (format "--http-proxy=%s" proxy)))
               (when ua (list (format "--user-agent=%s" ua)))
               (list target)))
             (ffplay
              (append
               (list ffplay "-nodisp" "-autoexit" "-loglevel" "error"
                     "-ss" (format "%.2f" pos)
                     "-volume" (number-to-string (if muted 0 vol)))
               (when proxy (list "-http_proxy" proxy))
               (when ua (list "-user_agent" ua))
               (list target)))
             (t nil))))
      (if (null cmd)
          (etaf-youtube--note app "未找到 mpv 或 ffplay，无法开启纯音频后台模式" 'danger)
        (let ((proc (make-process :name "etaf-youtube-bg-audio"
                                  :command cmd
                                  :connection-type 'pipe
                                  :noquery t)))
          (etaf-youtube--set app :bg-audio-proc proc)
          (etaf-youtube--set app :bg-audio-base-pos pos)
          (etaf-youtube--set app :bg-audio-start-wall (float-time))
          (etaf-youtube--set app :live-position pos)
          (etaf-youtube--write app :playing t))))))

(defun etaf-youtube-destroy (app)
  "Release APP's transport, downloads, timers, audio and store."
  (ignore-errors (etaf-youtube--record-resume app t))
  (ignore-errors (etaf-youtube-exit-fullscreen app))
  (when (etaf-pip-active-p etaf-youtube--pip-id)
    (ignore-errors (etaf-pip-close etaf-youtube--pip-id nil)))
  (etaf-youtube--write app :pip-active nil)
  (etaf-youtube--stop-player-timer app)
  (etaf-youtube--bg-audio-stop app)
  (when-let* ((timer (plist-get app :toast-timer)))
    (cancel-timer timer)
    (etaf-youtube--set app :toast-timer nil))
  (when (and (fboundp 'etaf-activity-get) (etaf-activity-get 'etaf-youtube))
    (ignore-errors (etaf-activity-remove 'etaf-youtube)))
  (ignore-errors (etaf-youtube-service-cancel (plist-get app :service)))
  (ignore-errors (etaf-youtube-service-close (plist-get app :service)))
  (ignore-errors (etaf-youtube-images-cancel (plist-get app :images)))
  (ignore-errors (etaf-youtube-store-close (plist-get app :store)))
  (etaf-youtube--write app :playing nil)
  t)

(defun etaf-youtube-check (app)
  "Request APP's account state and remember the reply."
  (etaf-youtube--request app :account (list "check")
                         (lambda (result) (etaf-youtube--apply-account app result)))
  app)

(defun etaf-youtube-state (app)
  "Return APP's state as a detached plist."
  (let* ((route (etaf-youtube--read app :route))
         (feed (etaf-youtube--read app :feed))
         (video (etaf-youtube--read app :video))
         (comments (etaf-youtube--read app :comments))
         (live-pos (plist-get app :live-position))
         (ref-pos (etaf-youtube--read app :position))
         (pos (if (and (numberp live-pos) (> live-pos 0)) live-pos (or ref-pos 0)))
         (live-dur (plist-get app :live-duration))
         (ref-dur (etaf-youtube--read app :duration))
         (dur (if (and (numberp live-dur) (> live-dur 0)) live-dur (or ref-dur 0))))
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
                             :channel-id (plist-get video :channel_id)
                             :duration (plist-get video :duration)
                             :like-status (plist-get video :like_status)
                             :subscribed (plist-get video :subscribed)
                             :playability (plist-get video :playability)))
     :media-status (etaf-youtube--read app :media-status)
     :comments (and comments
                    (list :count (plist-get comments :count)
                          :can-comment (plist-get comments :can_comment)
                          :requires-channel (plist-get comments :requires_channel)
                          :next (plist-get comments :next)
                          :items (length (plist-get comments :items))))
     :playing (etaf-youtube--read app :playing)
     :buffering (etaf-youtube--read app :buffering)
     :has-frame (etaf-youtube--read app :has-frame)
     :position pos
     :duration dur
     :resume (etaf-youtube--read app :resume)
     :volume (etaf-youtube--read app :volume)
     :speed (etaf-youtube--read app :speed)
     :quality (etaf-youtube--read app :quality)
     :muted (etaf-youtube--read app :muted)
     :captions-on (etaf-youtube--read app :captions-on)
     :caption-language (etaf-youtube--read app :caption-language)
     :audio-only (etaf-youtube--read app :audio-only)
     :auto-next (etaf-youtube--read app :auto-next)
     :watch-tab (etaf-youtube--read app :watch-tab)
     :chapters (length (etaf-youtube--read app :chapters))
     :queue-count (length (etaf-youtube--read app :queue))
     :sidebar (etaf-youtube--read app :sidebar)
     :theater (etaf-youtube--read app :theater)
     :theme (etaf-youtube--read app :theme-mode)
     :message (etaf-youtube--read app :message))))

;;; ---------------------------------------------------------------------------
;;; Lists & navigation
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--route-args (app)
  "Return the backend command for APP's current route."
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
               (when-let* ((params (etaf-youtube--nonempty-string (plist-get args :params))))
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
      (dolist (url (list (plist-get item :thumbnail) (plist-get item :avatar)))
        (etaf-youtube-images-clear-error images url)
        (etaf-youtube-images-request images url)))))

(defun etaf-youtube--apply-feed (app payload &optional append)
  "Record PAYLOAD as APP's list, appending to the current items when APPEND."
  (let* ((old (and append (etaf-youtube--read app :feed)))
         (items (append (and old (plist-get old :items))
                        (plist-get payload :items)))
         (feed (plist-put (copy-sequence payload) :items items)))
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
      (etaf-youtube--note app "已经到底，没有更多内容了" 'info))
     ((and append (plist-get (etaf-youtube--read app :feed-more) :loading))
      nil)
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
               (etaf-youtube--write app :selected nil)
               (etaf-youtube--apply-feed app (plist-get result :value)))
           (etaf-youtube--feed-failed app result))))))))

(defun etaf-youtube-locate (app view &optional args)
  "Navigate APP to VIEW with ARGS and return APP.
If audio-only background listening is active when leaving Watch, keep the
background audio running so the user can browse while listening."
  (if (eq view 'watch)
      (etaf-youtube-open-video app (plist-get args :id))
    (let ((current (etaf-youtube--read app :route)))
      (when (eq (plist-get current :view) 'watch)
        (etaf-youtube-exit-fullscreen app)
        (etaf-youtube--record-resume app t)
        (etaf-youtube--write app :watch-drawer nil)
        (etaf-youtube--write app :quality-menu nil))
      (unless (equal current (list :view view :args args))
        (etaf-youtube--write app :history
                             (cons current (seq-take (etaf-youtube--read app :history)
                                                     30))))
      (etaf-youtube--write app :route (list :view view :args args))
      (unless (or (etaf-youtube--read app :audio-only)
                  (etaf-youtube--read app :pip-active))
        (etaf-youtube--stop-player-timer app))
      (etaf-youtube--write app :feed nil)
      (etaf-youtube--write app :feed-more nil)
      (etaf-youtube--write app :selected nil)
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
    ('watch
     (let ((id (plist-get (plist-get (etaf-youtube--read app :route) :args) :id)))
       (remhash id (plist-get app :media-cache))
       (etaf-youtube-open-video app id)))
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
        (when (and (eq (plist-get (etaf-youtube--read app :route) :view) 'watch)
                   (not (eq (plist-get previous :view) 'watch)))
          (etaf-youtube-exit-fullscreen app)
          (etaf-youtube--record-resume app t)
          (etaf-youtube--write app :watch-drawer nil)
          (etaf-youtube--write app :quality-menu nil))
        (etaf-youtube--write app :history (cdr history))
        (etaf-youtube--write app :route previous)
        (unless (or (eq (plist-get previous :view) 'watch)
                    (etaf-youtube--read app :audio-only)
                    (etaf-youtube--read app :pip-active))
          (etaf-youtube--stop-player-timer app))
        (etaf-youtube--write app :feed nil)
        (etaf-youtube--write app :selected nil)
        (if (eq (plist-get previous :view) 'watch)
            (etaf-youtube-open-video app (plist-get (plist-get previous :args) :id))
          (etaf-youtube--load-feed app))))))

(defun etaf-youtube-search (app query &optional filter)
  "Search APP for QUERY with optional FILTER and show the results."
  (interactive)
  (etaf-youtube--write app :query (or query ""))
  (etaf-youtube--write app :filter (or filter "all"))
  (etaf-youtube-locate app 'search (list :query query :filter filter)))

(defun etaf-youtube--submit-search-or-url (app input)
  "Submit INPUT from the header search bar: open URL/ID directly or search."
  (let* ((trimmed (string-trim (or input "")))
         (target (etaf-youtube--parse-target trimmed)))
    (cond
     ((string-empty-p trimmed) nil)
     ((eq (plist-get target :kind) 'video)
      (etaf-youtube--open-video-at app (plist-get target :id) (plist-get target :start)))
     ((eq (plist-get target :kind) 'channel)
      (etaf-youtube-locate app 'channel (list :id (plist-get target :id))))
     ((eq (plist-get target :kind) 'playlist)
      (etaf-youtube-locate app 'playlist (list :id (plist-get target :id))))
     (t
      (etaf-youtube-search app trimmed (etaf-youtube--read app :filter))))))

(defun etaf-youtube-set-filter (app filter)
  "Switch APP's search result filter to FILTER."
  (etaf-youtube--write app :filter filter)
  (etaf-youtube--write app :feed nil)
  (etaf-youtube--write app :selected nil)
  (when (eq (plist-get (etaf-youtube--read app :route) :view) 'search)
    (etaf-youtube--load-feed app))
  app)

(defun etaf-youtube-apply-chip (app chip)
  "Follow CHIP, a selected filter or tab entry from the current payload."
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
               (etaf-youtube--write app :selected nil)
               (etaf-youtube--apply-feed app (plist-get result :value)))
           (etaf-youtube--feed-failed app result)))))
     (t (etaf-youtube--note app "该筛选条件暂不可用" 'info)))
    app))

;;; ---------------------------------------------------------------------------
;;; Selection & queue
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-select (app delta)
  "Move APP's selection by DELTA within the current list."
  (interactive)
  (let* ((items (etaf-youtube--items app))
         (count (length items))
         (current (etaf-youtube--read app :selected)))
    (when (> count 0)
      (etaf-youtube--write app :selected
                           (if (null current)
                               (if (< delta 0) (1- count) 0)
                             (max 0 (min (1- count) (+ current delta)))))))
  app)

(defun etaf-youtube-press-item (app index)
  "Activate APP's item at zero-based INDEX."
  (let ((items (etaf-youtube--items app)))
    (when (and (integerp index) (>= index 0) (< index (length items)))
      (etaf-youtube--write app :selected index)
      (etaf-youtube--activate-item app (nth index items))))
  app)

(defun etaf-youtube-activate (app)
  "Activate APP's currently selected item, or do nothing without a selection."
  (interactive)
  (when-let* ((index (etaf-youtube--read app :selected))
              (item (nth index (etaf-youtube--items app))))
    (etaf-youtube--activate-item app item))
  app)

(defun etaf-youtube--seed-queue-from-items (app active-id)
  "Build APP's playback queue from current playable feed items around ACTIVE-ID."
  (let* ((items (etaf-youtube--items app))
         (playable (seq-filter (lambda (it)
                                 (let ((k (plist-get it :kind)))
                                   (or (equal k "video") (equal k "short")
                                       (memq k '(video short)))))
                               items))
         (idx (cl-position active-id playable
                           :key (lambda (it) (plist-get it :id))
                           :test #'equal)))
    (when (and playable idx)
      (etaf-youtube--write app :queue playable)
      (etaf-youtube--write app :queue-index idx))))

(defun etaf-youtube--activate-item (app item)
  "Open ITEM from APP according to its kind."
  (let* ((raw-kind (plist-get item :kind))
         (kind (if (stringp raw-kind) (intern raw-kind) raw-kind)))
    (pcase kind
      ((or 'video 'short)
       (etaf-youtube--seed-queue-from-items app (plist-get item :id))
       (etaf-youtube-open-video app (plist-get item :id)))
      ('channel (etaf-youtube-locate app 'channel (list :id (plist-get item :id))))
      ('playlist (etaf-youtube-locate app 'playlist (list :id (plist-get item :id))))
      ('comment nil)
      (_ (when-let* ((id (plist-get item :id)))
           (etaf-youtube--seed-queue-from-items app id)
           (etaf-youtube-open-video app id))))))

(defun etaf-youtube--step-queue (app delta &optional from-end)
  "Advance or rewind APP's Watch playback by DELTA in queue or related list."
  (let* ((queue (etaf-youtube--read app :queue))
         (idx (etaf-youtube--read app :queue-index))
         (next-idx (and (integerp idx) (+ idx delta))))
    (cond
     ((and queue next-idx (>= next-idx 0) (< next-idx (length queue)))
      (let ((item (nth next-idx queue)))
        (etaf-youtube--write app :queue-index next-idx)
        (etaf-youtube-open-video app (plist-get item :id))))
     ((and from-end (> delta 0))
      (let* ((video (etaf-youtube--read app :video))
             (rel (seq-find (lambda (it)
                              (let ((k (plist-get it :kind)))
                                (or (equal k "video") (eq k 'video))))
                            (plist-get video :related))))
        (if rel
            (etaf-youtube-open-video app (plist-get rel :id))
          (etaf-youtube--note app "播放队列已结束" 'info))))
     (t
      (etaf-youtube--note app (if (> delta 0) "已经是队列最后一个视频" "已经是队列第一个视频")
                          'info)))))

;;; ---------------------------------------------------------------------------
;;; Watch page, stream resolution & zero-rerender HUD
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--merge-chapters (app)
  "Update APP's `:chapters' ref from media chapters, video chapters or description."
  (let* ((media (etaf-youtube--read app :media))
         (video (etaf-youtube--read app :video))
         (ch (or (plist-get media :chapters)
                 (plist-get video :chapters)
                 (etaf-youtube--chapters-from-description
                  (plist-get video :description)))))
    (etaf-youtube--write app :chapters ch)))

(defun etaf-youtube--open-video-at (app id &optional explicit-start)
  "Open video ID in APP, starting at EXPLICIT-START seconds if non-nil."
  (when (or (null id) (string-empty-p id))
    (user-error "A video id is required"))
  (etaf-youtube--record-resume app t)
  (etaf-youtube--bg-audio-stop app)
  (let ((current (etaf-youtube--read app :route)))
    (unless (and (eq (plist-get current :view) 'watch)
                 (equal (plist-get (plist-get current :args) :id) id))
      (etaf-youtube--write app :history
                           (cons current (seq-take (etaf-youtube--read app :history) 30)))))
  ;; Read saved resume point synchronously BEFORE media loads so libmpv starts right there.
  (let* ((saved (if (numberp explicit-start)
                    (and (> explicit-start 0) explicit-start)
                  (let ((r (ignore-errors
                             (etaf-youtube-store-resume (plist-get app :store) id))))
                    (and (numberp r) (> r 5) r))))
         (start-pos (or saved 0))
         (seed-item (or (cl-find id (etaf-youtube--read app :queue)
                                 :key (lambda (x) (plist-get x :id)) :test #'equal)
                        (cl-find id (etaf-youtube--items app)
                                 :key (lambda (x) (plist-get x :id)) :test #'equal)))
         (seed-thumb (and seed-item (etaf-youtube--nonempty-string
                                     (plist-get seed-item :thumbnail)))))
    (when seed-thumb
      (etaf-youtube-images-request (plist-get app :images) seed-thumb))
    ;; Populate non-reactive initial HUD slots BEFORE `etaf-batch' renders Watch
    ;; so the very first paint shows the exact resume clock and loading copy.
    (clrhash (plist-get app :replies-collapsed))
    (etaf-youtube--set app :caption-vec nil)
    (etaf-youtube--set app :resume-recorded saved)
    (etaf-youtube--set app :live-position (float start-pos))
    (etaf-youtube--set app :live-duration 0.0)
    (etaf-youtube--set app :live-time-text (etaf-youtube--clock start-pos))
    (etaf-youtube--set app :live-duration-text "00:00")
    (etaf-youtube--set app :live-subtitle-text "")
    (etaf-youtube--set app :spinner-index 0)
    (etaf-youtube--set app :loading-reason 'resolving)
    (etaf-youtube--set app :live-spinner-text "⠋ 正在解析高清视频流…")
    (etaf-youtube--set app :live-status-text
                       (if (and saved (> saved 5))
                           (format "⠋ 解析中 · 续播 %s" (etaf-youtube--clock saved))
                         "⠋ 解析视频流…"))
    (etaf-youtube--set app :ended-seen nil)
    (etaf-youtube--set app :use-alt-proto nil)
    (etaf-batch
      (unless (and (etaf-pip-active-p etaf-youtube--pip-id)
                   (not (eq (plist-get (etaf-youtube--read app :route) :view) 'watch)))
        (etaf-youtube--write app :route (list :view 'watch :args (list :id id))))
      (etaf-youtube--write app :video nil)
      (etaf-youtube--write app :video-status (list :state 'loading))
      (etaf-youtube--write app :media nil)
      (etaf-youtube--write app :media-status (list :state 'loading))
      (etaf-youtube--write app :comments nil)
      (etaf-youtube--write app :comments-status (list :state 'loading))
      (etaf-youtube--write app :comments-more nil)
      (etaf-youtube--write app :related-more nil)
      (etaf-youtube--write app :comments-sort nil)
      (etaf-youtube--write app :replies (make-hash-table :test #'equal))
      (etaf-youtube--write app :replies-version (1+ (or (etaf-youtube--read app :replies-version) 0)))
      (etaf-youtube--write app :captions nil)
      (etaf-youtube--write app :captions-on nil)
      (etaf-youtube--write app :caption-language nil)
      (etaf-youtube--write app :caption-filter "")
      (etaf-youtube--write app :chapters nil)
      (etaf-youtube--write app :desc-expanded nil)
      (etaf-youtube--write app :audio-only nil)
      (etaf-youtube--write app :buffering t)
      (etaf-youtube--write app :has-frame nil)
      (etaf-youtube--write app :poster-url seed-thumb)
      (etaf-youtube--write app :play-error nil)
      (etaf-youtube--write app :quality-menu nil)
      (etaf-youtube--write app :watch-drawer nil)
      (etaf-youtube--write app :position start-pos)
      (etaf-youtube--write app :progress-ref 0.0)
      (etaf-youtube--write app :resume saved)
      (etaf-youtube--write app :pending-seek nil)
      (etaf-youtube--write app :duration 0)
      (etaf-youtube--write app :playing nil))
    (etaf-youtube--start-player-timer app)
    ;; Keep queue index synced if ID is inside current queue
    (when-let* ((q (etaf-youtube--read app :queue))
                (qi (cl-position id q :key (lambda (x) (plist-get x :id)) :test #'equal)))
      (etaf-youtube--write app :queue-index qi))
    (etaf-youtube--request
     app :video (list "video" id)
     (lambda (result)
       (if (eq (plist-get result :status) 'ok)
           (let* ((video (plist-get result :value))
                  (duration (or (plist-get video :duration) 0)))
             (etaf-youtube--write app :video video)
             (etaf-youtube--write app :video-status (list :state 'ready))
             (when (etaf-pip-active-p etaf-youtube--pip-id)
               (etaf-pip-refresh-chrome etaf-youtube--pip-id))
             (when (> duration 0)
               (etaf-youtube--write app :duration duration)
               (etaf-youtube--set app :live-duration (float duration))
               (etaf-youtube--set app :live-duration-text (etaf-youtube--clock duration)))
             (etaf-youtube--merge-chapters app)
             (etaf-youtube--prefetch-thumbnails
              app (append (plist-get video :related) nil))
             (etaf-youtube-images-request (plist-get app :images)
                                          (plist-get video :thumbnail))
             (when-let* ((thumb (etaf-youtube--nonempty-string (plist-get video :thumbnail))))
               (unless (etaf-youtube--read app :poster-url)
                 (etaf-youtube--write app :poster-url thumb)))
             ;; Drop stale end-of-video resume if within tail margin
             (when (and saved (> duration 0)
                        (>= saved (- duration etaf-youtube--resume-end-margin)))
               (etaf-youtube--write app :resume nil)
               (etaf-youtube--set app :resume-recorded nil)
               (etaf-youtube--set app :live-position 0.0)
               (etaf-youtube--write app :position 0)))
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
    (etaf-youtube--resolve-media app id nil start-pos))
  app)

(defun etaf-youtube-open-video (app id)
  "Open video ID in APP: details, comments and a resolved media source."
  (interactive)
  (etaf-youtube--open-video-at app id nil))

(defun etaf-youtube--media-cache-valid-p (entry)
  "Return non-nil when cached media ENTRY is fresh and not near expiry."
  (when (and entry (plist-get entry :media))
    (let* ((now (float-time))
           (at (or (plist-get entry :at) 0))
           (exp-str (plist-get (plist-get entry :media) :expires))
           (exp (and (stringp exp-str) (string-match-p "\\`[0-9]+\\'" exp-str)
                     (string-to-number exp-str))))
      (and (< (- now at) 1800)
           (or (null exp) (< (+ now 300) exp))))))

(defun etaf-youtube--resolve-media (app id &optional quality start-pos force)
  "Resolve video ID's media at QUALITY (or APP's choice) for APP."
  (let* ((quality (or quality (etaf-youtube--read app :quality) 720))
         (cache (plist-get app :media-cache))
         (cached (and (not force) (gethash id cache))))
    (if (and (etaf-youtube--media-cache-valid-p cached)
             (plist-get (plist-get cached :media) :streams))
        (let* ((media (copy-sequence (plist-get cached :media)))
               (streams (plist-get media :streams))
               (chosen (or (seq-find (lambda (s) (<= (or (plist-get s :height) 0) quality)) streams)
                           (car (last streams)))))
          (when chosen
            (setq media (etaf-youtube--apply-stream-to-media media chosen start-pos)))
          (etaf-youtube--set app :loading-reason 'first-frame)
          (let* ((glyph (aref etaf-youtube--spinner-frames
                              (or (plist-get app :spinner-index) 0)))
                 (stage-txt (if (and (numberp start-pos) (> start-pos 5))
                                (format "%s 正在缓冲 %s 画面…" glyph (etaf-youtube--clock start-pos))
                              (format "%s 正在连接 libmpv 并缓冲首帧…" glyph))))
            (etaf-youtube--set app :live-spinner-text stage-txt)
            (etaf-youtube--set app :live-status-text (format "%s 缓冲首帧…" glyph)))
          (etaf-batch
            (etaf-youtube--write app :has-frame nil)
            (etaf-youtube--write app :buffering t)
            (etaf-youtube--write app :media media)
            (etaf-youtube--write app :media-status (list :state 'ready))
            (etaf-youtube--write app :play-error nil))
          (etaf-youtube--merge-chapters app)
          (etaf-youtube--start-player-timer app))
      (etaf-youtube--set app :loading-reason 'resolving)
      (etaf-youtube--write app :media-status (list :state 'loading))
      (etaf-youtube--start-player-timer app)
      (etaf-youtube--request
       app :source (list "source" id "--quality" (number-to-string quality))
       (lambda (result)
         (if (eq (plist-get result :status) 'ok)
             (let* ((raw (plist-get result :value))
                    (media (if (and (numberp start-pos) (> start-pos 5))
                               (plist-put (copy-sequence raw) :start-offset start-pos)
                             raw)))
               (puthash id (list :media raw :at (float-time)) cache)
               (etaf-youtube--set app :loading-reason 'first-frame)
               (let* ((glyph (aref etaf-youtube--spinner-frames
                                   (or (plist-get app :spinner-index) 0)))
                      (stage-txt (if (and (numberp start-pos) (> start-pos 5))
                                     (format "%s 正在缓冲 %s 画面…" glyph (etaf-youtube--clock start-pos))
                                   (format "%s 正在连接 libmpv 并缓冲首帧…" glyph))))
                 (etaf-youtube--set app :live-spinner-text stage-txt)
                 (etaf-youtube--set app :live-status-text (format "%s 缓冲首帧…" glyph)))
               (etaf-batch
                 (etaf-youtube--write app :has-frame nil)
                 (etaf-youtube--write app :buffering t)
                 (etaf-youtube--write app :media media)
                 (etaf-youtube--write app :media-status (list :state 'ready))
                 (etaf-youtube--write app :play-error nil))
               (when-let* ((dur (plist-get media :duration)))
                 (when (> dur 0)
                   (etaf-youtube--write app :duration dur)
                   (etaf-youtube--set app :live-duration (float dur))
                   (etaf-youtube--set app :live-duration-text (etaf-youtube--clock dur))))
               (etaf-youtube--merge-chapters app)
               (etaf-youtube--start-player-timer app))
           (etaf-youtube--set app :loading-reason nil)
           (etaf-batch
             (etaf-youtube--write app :buffering nil)
             (etaf-youtube--write app :media-status
                                  (list :state 'error
                                        :message (plist-get result :message)
                                        :hint (plist-get result :hint))))))))))

(defun etaf-youtube--apply-stream-to-media (media stream &optional start-pos)
  "Return a copy of MEDIA switched to STREAM plist at optional START-POS."
  (let ((copy (copy-sequence media)))
    (setq copy (plist-put copy :video_url (plist-get stream :video_url)))
    (setq copy (plist-put copy :audio_url (plist-get stream :audio_url)))
    (setq copy (plist-put copy :alt_video_url (plist-get stream :alt_video_url)))
    (setq copy (plist-put copy :alt_audio_url (plist-get stream :alt_audio_url)))
    (setq copy (plist-put copy :width (plist-get stream :width)))
    (setq copy (plist-put copy :height (plist-get stream :height)))
    (setq copy (plist-put copy :fps (plist-get stream :fps)))
    (setq copy (plist-put copy :quality_label (plist-get stream :label)))
    (setq copy (plist-put copy :codec_label (plist-get stream :codec_label)))
    (setq copy (plist-put copy :protocol (plist-get stream :protocol)))
    (when (plist-get stream :headers)
      (setq copy (plist-put copy :headers (plist-get stream :headers))))
    (when (and (numberp start-pos) (> start-pos 0))
      (setq copy (plist-put copy :start-offset start-pos)))
    copy))

(defun etaf-youtube--select-stream (app stream)
  "Switch active playback in APP to STREAM at the current second without refetch."
  (when-let* ((media (etaf-youtube--read app :media)))
    (let* ((pos (float (or (plist-get app :live-position)
                           (etaf-youtube--read app :position) 0)))
           (height (plist-get stream :height))
           (updated (etaf-youtube--apply-stream-to-media media stream pos)))
      (when (memq height etaf-youtube--quality-levels)
        (etaf-youtube--write app :quality height)
        (ignore-errors (etaf-youtube-store-set-setting (plist-get app :store) "quality" height)))
      (etaf-youtube--set app :use-alt-proto nil)
      (etaf-youtube--set app :loading-reason 'switching)
      (etaf-batch
        (etaf-youtube--write app :quality-menu nil)
        (etaf-youtube--write app :play-error nil)
        (etaf-youtube--write app :has-frame nil)
        (etaf-youtube--write app :buffering t)
        (etaf-youtube--write app :media updated))
      (etaf-youtube--start-player-timer app)
      (etaf-youtube--note app
                          (format "已切换至 %s %s（从 %s 续播）"
                                  (or (plist-get stream :label) (format "%dp" height))
                                  (or (plist-get stream :codec_label) "")
                                  (etaf-youtube--clock pos))
                          'info))))

(defun etaf-youtube--failover-stream (app)
  "Switch APP to an alternate protocol stream or re-resolve fresh URLs."
  (let* ((media (etaf-youtube--read app :media))
         (alt-v (etaf-youtube--nonempty-string (plist-get media :alt_video_url)))
         (alt-a (etaf-youtube--nonempty-string (plist-get media :alt_audio_url)))
         (pos (float (or (plist-get app :live-position)
                         (etaf-youtube--read app :position) 0))))
    (if (and alt-v (not (plist-get app :use-alt-proto)))
        (let ((updated (copy-sequence media)))
          (etaf-youtube--set app :use-alt-proto t)
          (etaf-youtube--set app :loading-reason 'switching)
          (setq updated (plist-put updated :video_url alt-v))
          (setq updated (plist-put updated :audio_url alt-a))
          (setq updated (plist-put updated :start-offset pos))
          (etaf-batch
            (etaf-youtube--write app :quality-menu nil)
            (etaf-youtube--write app :play-error nil)
            (etaf-youtube--write app :has-frame nil)
            (etaf-youtube--write app :buffering t)
            (etaf-youtube--write app :media updated))
          (etaf-youtube--start-player-timer app)
          (etaf-youtube--note app "已切换至备用传输协议线路" 'info))
      (when-let* ((id (or (plist-get (etaf-youtube--read app :video) :id)
                          (plist-get (plist-get (etaf-youtube--read app :route) :args) :id))))
        (remhash id (plist-get app :media-cache))
        (etaf-youtube--set app :use-alt-proto nil)
        (etaf-youtube--write app :quality-menu nil)
        (etaf-youtube--write app :play-error nil)
        (etaf-youtube--note app "正在重新解析播放源…" 'info)
        (etaf-youtube--resolve-media app id nil pos t)))))

(defun etaf-youtube--header-alist (headers)
  "Return HEADERS as an alist of (NAME . VALUE) strings."
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
  "Return APP's resolved media as a normalized `etaf-video' source, or nil.
Empty string `:audio_url' or `:proxy' are normalized to nil so `etaf-video'
never rejects direct routes or muxed streams."
  (when-let* ((media (etaf-youtube--read app :media))
              (url (etaf-youtube--nonempty-string (plist-get media :video_url))))
    (let* ((audio-url (etaf-youtube--nonempty-string (plist-get media :audio_url)))
           (proxy (etaf-youtube--nonempty-string (plist-get media :proxy)))
           (start (plist-get media :start-offset)))
      (append
       (list :kind 'url
             :url url
             :audio-url audio-url
             :headers (etaf-youtube--header-alist (plist-get media :headers))
             :proxy proxy
             :width (plist-get media :width)
             :height (plist-get media :height)
             :fps (plist-get media :fps)
             :duration (plist-get media :duration)
             :audio t)
       (when (and (numberp start) (> start 0))
         (list :start start))))))

(defun etaf-youtube--active-handle (app)
  "Return APP's mounted `etaf-video' handle (PiP when active, else Watch)."
  (if (etaf-youtube--read app :pip-active)
      (plist-get app :pip-handle)
    (plist-get app :player-handle)))

(defun etaf-youtube--player-state (app)
  "Return the mounted player's state, or nil when it is not mounted."
  (ignore-errors (etaf-video-state (etaf-youtube--active-handle app))))

(defun etaf-youtube--record-resume (app &optional force position)
  "Persist APP's resume point for the current video."
  (let* ((video (etaf-youtube--read app :video))
         (id (or (plist-get video :id)
                 (and (eq (plist-get (etaf-youtube--read app :route) :view) 'watch)
                      (plist-get (plist-get (etaf-youtube--read app :route) :args) :id))))
         (store (plist-get app :store))
         (pos (or position
                  (and (numberp (plist-get app :live-position))
                       (> (plist-get app :live-position) 0)
                       (plist-get app :live-position))
                  (etaf-youtube--read app :position)))
         (recorded (plist-get app :resume-recorded)))
    (when (and store id (numberp pos)
               (or force
                   (null recorded)
                   (>= (abs (- pos recorded)) etaf-youtube--resume-interval)))
      (etaf-youtube-store-record-resume store id pos)
      (etaf-youtube--set app :resume-recorded pos)
      (etaf-youtube--write app :resume pos))))

(defun etaf-youtube--start-player-timer (app)
  "Start APP's 200ms zero-rerender Watch HUD poll timer."
  (unless (plist-get app :player-timer)
    (etaf-youtube--set app :player-timer
                       (run-at-time 0.20 0.20
                                    (lambda () (etaf-youtube--sync-player app))))))

(defun etaf-youtube--stop-player-timer (app)
  "Stop APP's HUD poll timer."
  (when-let* ((timer (plist-get app :player-timer)))
    (cancel-timer timer)
    (etaf-youtube--set app :player-timer nil)))

(defun etaf-youtube--next-spinner-glyph (app)
  "Advance and return the next Braille spinner glyph for APP."
  (let* ((count (length etaf-youtube--spinner-frames))
         (idx (% (1+ (or (plist-get app :spinner-index) 0)) count)))
    (etaf-youtube--set app :spinner-index idx)
    (aref etaf-youtube--spinner-frames idx)))

(defun etaf-youtube--loading-copy (app glyph)
  "Return (STAGE-TEXT . STATUS-TEXT) describing APP's current loading state."
  (let* ((media (etaf-youtube--read app :media))
         (src (etaf-youtube-media-src app))
         (has-frame (etaf-youtube--read app :has-frame))
         (reason (plist-get app :loading-reason))
         (pos (or (plist-get app :live-position) 0.0))
         (q (or (plist-get media :quality_label)
                (when-let* ((h (plist-get media :height))) (format "%dp" h)))))
    (cond
     ((null src)
      (cons (format "%s 正在解析高清视频流…" glyph)
            (format "%s 解析视频流…" glyph)))
     ((not has-frame)
      (cons (cond
             ((and (eq reason 'switching) q)
              (format "%s 正在切换至 %s 画面…" glyph q))
             ((and (numberp pos) (> pos 5))
              (format "%s 正在缓冲 %s 画面…" glyph (etaf-youtube--clock pos)))
             (t
              (format "%s 正在连接 libmpv 并缓冲首帧…" glyph)))
            (format "%s 缓冲首帧…" glyph)))
     (t
      (cons (format "%s 正在缓冲…" glyph)
            (format "%s 缓冲中…" glyph))))))

(defun etaf-youtube--publish-hud (app pos dur buffering status-override)
  "Push changed Watch HUD leaf nodes through Retained Host updates (0 reflow)."
  (let* ((time-str (etaf-youtube--clock pos))
         (dur-str (etaf-youtube--clock dur))
         (sub-str (or (etaf-youtube-caption-text app) ""))
         (audio-only (etaf-youtube--read app :audio-only))
         (has-frame (etaf-youtube--read app :has-frame))
         (src (etaf-youtube-media-src app))
         (err (or (etaf-youtube--read app :play-error)
                  (eq (plist-get (etaf-youtube--read app :media-status) :state) 'error)))
         (loading-p (and (not audio-only) (not err)
                         (or (null src) (not has-frame) buffering)))
         (copy (when loading-p
                 (etaf-youtube--loading-copy app (etaf-youtube--next-spinner-glyph app))))
         (spinner-str (if copy (car copy) ""))
         (status-str (or status-override
                         (and copy (cdr copy))
                         (let ((eng (plist-get app :live-engine))
                               (m (etaf-youtube--read app :media)))
                           (if (and has-frame (eq eng 'mpv))
                               (format "● libmpv · %s%s"
                                       (or (plist-get m :quality_label)
                                           (format "%dp" (or (plist-get m :height) 720)))
                                       (if (plist-get m :codec_label)
                                           (format " %s" (plist-get m :codec_label))
                                         ""))
                             ""))))
         (pct (if (> dur 0) (min 100.0 (max 0.0 (* 100.0 (/ (float pos) dur)))) 0.0))
         (prev-time (plist-get app :live-time-text))
         (prev-dur (plist-get app :live-duration-text))
         (prev-sub (plist-get app :live-subtitle-text))
         (prev-status (plist-get app :live-status-text))
         (prev-spinner (plist-get app :live-spinner-text))
         (buf (plist-get app :buffer))
         (runtime (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf)))
         (in-watch (eq (plist-get (etaf-youtube--read app :route) :view) 'watch)))
    (etaf-youtube--set app :live-time-text time-str)
    (etaf-youtube--set app :live-duration-text dur-str)
    (etaf-youtube--set app :live-subtitle-text sub-str)
    (etaf-youtube--set app :live-status-text status-str)
    (etaf-youtube--set app :live-spinner-text spinner-str)
    (when (and runtime in-watch)
      (let* ((updates nil)
             (vp (ignore-errors (etaf-runtime-viewport runtime)))
             (met (ignore-errors (etaf-display-metrics runtime)))
             (cw (max 1 (or (plist-get met :char-width) 8)))
             (cols (max 24 (floor (or (car-safe vp) 960) cw)))
             (c-time (cond (loading-p (if (< cols 44) "···" "··· 缓冲中"))
                           ((>= cols 52) (format "%s / %s" time-str dur-str))
                           ((>= cols 30) time-str)
                           (t "")))
             (c-prev (cond (loading-p "")
                           ((>= cols 52) (format "%s / %s" prev-time prev-dur))
                           ((>= cols 30) prev-time)
                           (t ""))))
        (dolist (entry (list (list etaf-youtube--hud-time-ref time-str prev-time)
                             (list etaf-youtube--hud-duration-ref dur-str prev-dur)
                             (list etaf-youtube--hud-subtitle-ref sub-str prev-sub)
                             (list etaf-youtube--hud-status-ref status-str prev-status)
                             (list etaf-youtube--hud-spinner-ref spinner-str prev-spinner)))
          (when (and (not (equal (nth 1 entry) (nth 2 entry)))
                     (etaf-runtime-host-props-for runtime (car entry)))
            (push (cons (car entry) (nth 1 entry)) updates)))
        (when (and (not (equal c-time c-prev))
                   (etaf-runtime-host-props-for runtime etaf-youtube--hud-cinema-time-ref))
          (push (cons etaf-youtube--hud-cinema-time-ref c-time) updates))
        (when updates
          (ignore-errors (etaf-runtime-update-host-contents runtime updates)))))
      (when-let* ((pbuf (etaf-pip-buffer etaf-youtube--pip-id))
                  ((buffer-live-p pbuf))
                  (prt (etaf-runtime-for-buffer pbuf))
                  ((etaf-runtime-mounted-p prt)))
        (let* ((bounds (etaf-pip-bounds etaf-youtube--pip-id))
               (pcols (or (plist-get bounds :cols) 58))
               (p-full (>= pcols 52))
               (p-show (>= pcols 30))
               (p-time (cond (loading-p (if (< pcols 44) "···" "··· 缓冲中"))
                             (p-full (format "%s / %s" time-str dur-str))
                             (p-show time-str)
                             (t "")))
               (p-prev (cond (loading-p "")
                             (p-full (format "%s / %s" prev-time prev-dur))
                             (p-show prev-time)
                             (t "")))
               (p-sub (if (string-empty-p sub-str) "" (concat "CC  " sub-str)))
               (p-prev-sub (if (string-empty-p prev-sub) "" (concat "CC  " prev-sub)))
               (p-updates nil))
          (when (and (not (equal p-time p-prev))
                     (etaf-runtime-host-props-for prt etaf-youtube--pip-time-ref))
            (push (cons etaf-youtube--pip-time-ref p-time) p-updates))
          (when (and (not (equal p-sub p-prev-sub))
                     (etaf-runtime-host-props-for prt etaf-youtube--pip-subtitle-ref))
            (push (cons etaf-youtube--pip-subtitle-ref p-sub) p-updates))
          (when p-updates
            (ignore-errors (etaf-runtime-update-host-contents prt p-updates)))))
      (when (and (or in-watch (etaf-pip-active-p etaf-youtube--pip-id))
                 (not (etaf-youtube--read app :scrub)))
        (let ((cur-pct (etaf-youtube--read app :progress-ref)))
          (when (or (not (numberp cur-pct))
                    (>= (abs (- pct cur-pct)) 0.25)
                    (and (= pct 0.0) (/= cur-pct 0.0))
                    (and (= pct 100.0) (/= cur-pct 100.0)))
            (etaf-youtube--write app :progress-ref pct))))))

(defun etaf-youtube--sync-activity (app pos dur)
  "Publish APP's playback state to `etaf-activity-publish' when available."
  (when (fboundp 'etaf-activity-publish)
    (let* ((video (etaf-youtube--read app :video))
           (media (etaf-youtube--read app :media))
           (title (or (plist-get video :title) (plist-get media :title)))
           (author (or (plist-get video :author) "YouTube"))
           (playing (and (etaf-youtube--read app :playing) t))
           (audio-only (and (etaf-youtube--read app :audio-only) t))
           (raw-sec (max 0 (floor (or pos 0.0))))
           (sec (if (and playing (not audio-only))
                    (* 2 (/ raw-sec 2))
                  raw-sec))
           (max-sec (max 1 (floor (or dur 0.0))))
           (act-state (if (or playing audio-only) 'active 'paused))
           (existing (and (fboundp 'etaf-activity-get)
                          (etaf-activity-get 'etaf-youtube)))
           (existing-prog (and existing (plist-get existing :progress)))
           (buf (plist-get app :buffer))
           (rt (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
      (when (and title (or playing audio-only)
                 (not (and existing
                           (eq (plist-get existing :state) act-state)
                           (equal (plist-get existing :title) title)
                           (equal (plist-get existing-prog :value) sec)
                           (equal (plist-get existing-prog :max) max-sec))))
        (ignore-errors
          (etaf-activity-publish
           'etaf-youtube
           (list :app 'etaf-youtube
                 :kind 'media
                 :priority 81
                 :state act-state
                 :icon (if playing "▶" "⏸")
                 :title title
                 :compact title
                 :subtitle (format "%s · %s / %s"
                                   author
                                   (etaf-youtube--clock sec)
                                   (etaf-youtube--clock max-sec))
                 :progress (list :value sec :max max-sec :unit 'seconds)
                 :owner-runtime rt
                 :open (lambda ()
                         (when (buffer-live-p buf)
                           (pop-to-buffer buf)))
                 :actions (list (list :id 'toggle
                                      :label (if playing "⏸" "▶")
                                      :fn (lambda () (etaf-youtube-toggle-playback app)))
                                (list :id 'next
                                      :label "下一条"
                                      :fn (lambda () (etaf-youtube--step-queue app 1)))))))))))

(defun etaf-youtube--sync-player (app)
  "Read mounted player (or background audio) telemetry at 200ms without rerender."
  (cond
   ;; 1. Audio-only background mode
   ((etaf-youtube--read app :audio-only)
    (let* ((pos (etaf-youtube--bg-audio-position app))
           (dur (float (or (plist-get app :live-duration)
                           (etaf-youtube--read app :duration) 0)))
           (proc (plist-get app :bg-audio-proc)))
      (etaf-youtube--set app :live-position pos)
      (etaf-youtube--publish-hud app pos dur nil "♫ 纯音频后台")
      (etaf-youtube--sync-activity app pos dur)
      (if (and proc (not (process-live-p proc)) (etaf-youtube--read app :playing))
          (progn
            (etaf-youtube--write app :playing nil)
            (etaf-youtube--record-resume app t 0)
            (when (etaf-youtube--read app :auto-next)
              (etaf-youtube--step-queue app 1 t)))
        (etaf-youtube--record-resume app nil pos))))
   ;; 2. Mounted etaf-video playback
   ((etaf-youtube--player-state app)
    (let* ((state (etaf-youtube--player-state app))
           (playing (and (plist-get state :playing) t))
           (presented (or (plist-get state :presented) 0))
           (ended (and (plist-get state :ended) t))
           (err (plist-get state :error))
           (raw-buf (and (plist-get state :buffering) t))
           (has-frame (or (> presented 0) (etaf-youtube--read app :has-frame)))
           (buf-p (and (not err) (not ended)
                       (or raw-buf (not has-frame))))
           (eng (plist-get state :engine))
           (pos (float (or (plist-get state :position)
                           (plist-get app :live-position) 0)))
           (sdur (plist-get state :duration))
           (dur (float (if (and (numberp sdur) (> sdur 0))
                           sdur
                         (or (plist-get app :live-duration)
                             (etaf-youtube--read app :duration) 0)))))
      (etaf-youtube--set app :live-engine eng)
      (etaf-youtube--set app :live-position pos)
      (when (> dur 0)
        (etaf-youtube--set app :live-duration dur))
      (when (and (> presented 0) (not (etaf-youtube--read app :has-frame)))
        (etaf-youtube--set app :loading-reason nil)
        (etaf-youtube--write app :has-frame t))
      (when (and buf-p (etaf-youtube--read app :has-frame))
        (etaf-youtube--set app :loading-reason 'buffering))
      ;; Only write reactive refs when discrete state actually changes!
      (unless (eq playing (and (etaf-youtube--read app :playing) t))
        (etaf-youtube--write app :playing playing))
      (unless (eq buf-p (and (etaf-youtube--read app :buffering) t))
        (etaf-youtube--write app :buffering buf-p))
      (when (and err (not (equal err (etaf-youtube--read app :play-error))))
        (let ((friendly
               (if (string-match-p "403\\|unrecognized\\|Failed to open\\|loading failed" err)
                   (format "%s（可能因代理出口 IP 不一致或链接过期，可重试或用外部 mpv / 浏览器打开）" err)
                 err)))
          (etaf-youtube--write app :play-error friendly)))
      (when-let* ((seek (etaf-youtube--read app :pending-seek)))
        (etaf-youtube--write app :pending-seek nil)
        (ignore-errors (etaf-video-seek (etaf-youtube--active-handle app) seek))
        (etaf-youtube--set app :live-position (float seek))
        (setq pos (float seek)))
      (etaf-youtube--publish-hud app pos dur buf-p nil)
      (etaf-youtube--sync-activity app pos dur)
      (if ended
          (unless (plist-get app :ended-seen)
            (etaf-youtube--set app :ended-seen t)
            (etaf-youtube--write app :playing nil)
            (etaf-youtube--record-resume app t 0)
            (when (and (not err) (etaf-youtube--read app :auto-next))
              (etaf-youtube--step-queue app 1 t)))
        (etaf-youtube--set app :ended-seen nil)
        (etaf-youtube--record-resume app nil pos))))
   ;; 3. Watch route or PiP still resolving source or mounting etaf-video
   ((and (or (eq (plist-get (etaf-youtube--read app :route) :view) 'watch)
             (etaf-youtube--read app :pip-active))
         (not (etaf-youtube--read app :play-error))
         (not (eq (plist-get (etaf-youtube--read app :media-status) :state) 'error)))
    (let ((pos (float (or (plist-get app :live-position)
                          (etaf-youtube--read app :position) 0)))
          (dur (float (or (plist-get app :live-duration)
                          (etaf-youtube--read app :duration) 0))))
      (etaf-youtube--publish-hud app pos dur t nil)))))

;;; ---------------------------------------------------------------------------
;;; Playback controls
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-toggle-playback (app)
  "Toggle APP's video between playing and paused."
  (interactive)
  (cond
   ((etaf-youtube--read app :audio-only)
    (if (etaf-youtube--read app :playing)
        (let ((pos (etaf-youtube--bg-audio-position app)))
          (etaf-youtube--set app :live-position pos)
          (etaf-youtube--set app :bg-audio-base-pos pos)
          (etaf-youtube--bg-audio-stop app)
          (etaf-youtube--write app :playing nil)
          (etaf-youtube--record-resume app t pos))
      (etaf-youtube--bg-audio-start app (plist-get app :live-position))))
   ((null (etaf-youtube--read app :media))
    (when-let* ((video (etaf-youtube--read app :video)))
      (etaf-youtube--resolve-media app (plist-get video :id))))
   ((etaf-youtube--player-state app)
    (ignore-errors (etaf-video-toggle-playback (etaf-youtube--active-handle app)))
    (let ((playing (and (plist-get (etaf-youtube--player-state app) :playing) t)))
      (etaf-youtube--write app :playing playing)
      (unless playing (etaf-youtube--record-resume app t))))
   (t (etaf-youtube--note app "播放器正在准备中…" 'info)))
  app)

(defun etaf-youtube-seek (app seconds)
  "Move APP's video to SECONDS."
  (interactive)
  (let* ((duration (max (float (or (plist-get app :live-duration) 0))
                        (float (or (etaf-youtube--read app :duration) 0))))
         (target (max 0 (if (> duration 0) (min seconds duration) seconds))))
    (etaf-youtube--set app :live-position (float target))
    (etaf-youtube--write app :position target)
    (cond
     ((etaf-youtube--read app :audio-only)
      (etaf-youtube--set app :bg-audio-base-pos (float target))
      (when (etaf-youtube--read app :playing)
        (etaf-youtube--bg-audio-start app target)))
     ((etaf-youtube--player-state app)
      (ignore-errors (etaf-video-seek (etaf-youtube--active-handle app) target))
      (when (and (etaf-youtube--read app :playing)
                 (plist-get (etaf-youtube--player-state app) :buffering))
        (etaf-youtube--set app :loading-reason 'buffering)
        (etaf-youtube--write app :buffering t)))
     (t
      (etaf-youtube--write app :pending-seek target)))
    (etaf-youtube--publish-hud app (float target) duration
                               (etaf-youtube--read app :buffering) nil))
  app)

(defun etaf-youtube-seek-by (app delta)
  "Move APP's video DELTA seconds from its current position."
  (let ((base (or (and (numberp (plist-get app :live-position))
                       (plist-get app :live-position))
                  (etaf-youtube--read app :position)
                  0)))
    (etaf-youtube-seek app (+ base delta))))

(defun etaf-youtube-set-volume (app volume)
  "Set APP's volume to VOLUME between 0 and 100."
  (interactive)
  (let ((volume (max 0 (min 100 (round volume)))))
    (etaf-youtube--write app :volume volume)
    (when (and (> volume 0) (etaf-youtube--read app :muted))
      (etaf-youtube--write app :muted nil)
      (etaf-youtube--write app :audio-on t))
    (if (etaf-youtube--read app :audio-only)
        (when (etaf-youtube--read app :playing)
          (etaf-youtube--bg-audio-start app (etaf-youtube--bg-audio-position app)))
      (ignore-errors
        (when (etaf-youtube--player-state app)
          (etaf-video-set-volume (etaf-youtube--active-handle app) volume))))
    (ignore-errors
      (etaf-youtube-store-set-setting (plist-get app :store) "volume" volume)))
  app)

(defun etaf-youtube-set-speed (app speed)
  "Set APP's playback rate to SPEED, a positive number."
  (interactive)
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (etaf-youtube--write app :speed speed)
  (if (etaf-youtube--read app :audio-only)
      (when (etaf-youtube--read app :playing)
        (etaf-youtube--bg-audio-start app (etaf-youtube--bg-audio-position app)))
    (ignore-errors
      (when (etaf-youtube--player-state app)
        (etaf-video-set-speed (etaf-youtube--active-handle app) speed))))
  (ignore-errors
    (etaf-youtube-store-set-setting (plist-get app :store) "speed" speed))
  app)

(defun etaf-youtube--cycle-speed (app)
  "Cycle APP's playback speed through `etaf-youtube--speeds'."
  (let* ((cur (or (etaf-youtube--read app :speed) 1))
         (next (or (cadr (member cur etaf-youtube--speeds))
                   (car etaf-youtube--speeds))))
    (etaf-youtube-set-speed app next)
    (etaf-youtube--note app (format "播放倍速：%gx" next) 'info)))

(defun etaf-youtube--step-speed (app delta)
  "Step APP's playback speed up (+1) or down (-1)."
  (let* ((cur (or (etaf-youtube--read app :speed) 1))
         (idx (or (cl-position cur etaf-youtube--speeds) 2))
         (next (nth (max 0 (min (1- (length etaf-youtube--speeds)) (+ idx delta)))
                    etaf-youtube--speeds)))
    (etaf-youtube-set-speed app next)
    (etaf-youtube--note app (format "播放倍速：%gx" next) 'info)))

(defun etaf-youtube-set-quality (app quality)
  "Switch APP's video to QUALITY, a supported height.
When the resolved media already carries `:streams' containing QUALITY, switch
in place at the exact current second without re-running yt-dlp; otherwise
re-resolve from the backend."
  (interactive)
  (unless (memq quality etaf-youtube--quality-levels)
    (user-error "Unsupported quality: %S" quality))
  (etaf-youtube--write app :quality quality)
  (ignore-errors
    (etaf-youtube-store-set-setting (plist-get app :store) "quality" quality))
  (when-let* ((video (etaf-youtube--read app :video)))
    (let* ((media (etaf-youtube--read app :media))
           (streams (plist-get media :streams))
           (matched (and streams
                         (seq-find (lambda (s) (equal (plist-get s :height) quality))
                                   streams))))
      (if matched
          (etaf-youtube--select-stream app matched)
        (let ((pos (or (plist-get app :live-position)
                       (etaf-youtube--read app :position))))
          (etaf-youtube--write app :pending-seek
                               (and (numberp pos) (> pos 1) pos))
          (etaf-youtube--resolve-media app (plist-get video :id) quality pos t)))))
  app)

(defun etaf-youtube-toggle-mute (app)
  "Toggle APP's audio."
  (interactive)
  (let ((muted (not (etaf-youtube--read app :muted))))
    (etaf-youtube--write app :muted muted)
    (etaf-youtube--write app :audio-on (not muted))
    (if (etaf-youtube--read app :audio-only)
        (when (etaf-youtube--read app :playing)
          (etaf-youtube--bg-audio-start app (etaf-youtube--bg-audio-position app)))
      (ignore-errors
        (when (etaf-youtube--player-state app)
          (etaf-video-set-audio (etaf-youtube--active-handle app) (not muted))))))
  app)

(defun etaf-youtube--toggle-audio-only (app)
  "Toggle zero-CPU background audio-only mode for APP."
  (let* ((next (not (etaf-youtube--read app :audio-only)))
         (pos (float (or (plist-get app :live-position)
                         (etaf-youtube--read app :position) 0))))
    (if next
        (progn
          (etaf-youtube--write app :audio-only t)
          (etaf-youtube--bg-audio-start app pos)
          (etaf-youtube--start-player-timer app)
          (etaf-youtube--note app "已进入纯音频后台模式（按 b 返回列表仍可继续听）" 'info))
      (let ((resume-pos (etaf-youtube--bg-audio-position app)))
        (etaf-youtube--bg-audio-stop app)
        (etaf-youtube--set app :loading-reason 'first-frame)
        (when-let* ((media (etaf-youtube--read app :media)))
          (etaf-youtube--write app :media
                               (plist-put (copy-sequence media) :start-offset resume-pos)))
        (etaf-youtube--set app :live-position resume-pos)
        (etaf-batch
          (etaf-youtube--write app :has-frame nil)
          (etaf-youtube--write app :buffering t)
          (etaf-youtube--write app :audio-only nil))
        (etaf-youtube--start-player-timer app)
        (etaf-youtube--note app "已恢复视频画面" 'info)))))

(defun etaf-youtube--toggle-auto-next (app)
  "Toggle automatic queue advance on video end."
  (let ((next (not (etaf-youtube--read app :auto-next))))
    (etaf-youtube--write app :auto-next next)
    (ignore-errors
      (etaf-youtube-store-set-setting (plist-get app :store) "auto-next"
                                      (if next "t" "nil")))
    (etaf-youtube--note app (if next "自动连播：开启" "自动连播：关闭") 'info)))

;;; ---------------------------------------------------------------------------
;;; Multi-track subtitles & O(log N) binary search
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--available-subtitle-tracks (app)
  "Return available subtitle tracks from resolved media or video payload."
  (or (plist-get (etaf-youtube--read app :media) :subtitles)
      (plist-get (etaf-youtube--read app :video) :captions)))

(defun etaf-youtube--select-caption-track (app track)
  "Load subtitle TRACK plist for APP, or turn subtitles off when TRACK is nil."
  (if (null track)
      (progn
        (etaf-youtube--set app :caption-vec nil)
        (etaf-batch
          (etaf-youtube--write app :captions-on nil)
          (etaf-youtube--write app :captions nil)
          (etaf-youtube--write app :caption-language nil))
        (etaf-youtube--publish-hud app
                                   (or (plist-get app :live-position) 0)
                                   (or (plist-get app :live-duration) 0)
                                   nil nil))
    (let* ((language (plist-get track :language))
           (url (etaf-youtube--nonempty-string (plist-get track :url)))
           (video (etaf-youtube--read app :video))
           (id (or (plist-get video :id)
                   (plist-get (etaf-youtube--read app :media) :id))))
      (if (and language id)
          (progn
            (etaf-batch
              (etaf-youtube--write app :captions-on t)
              (etaf-youtube--write app :caption-language language))
            (etaf-youtube--request
             app :captions
             (append (list "captions" id "--language" language)
                     (when url (list "--url" url)))
             (lambda (result)
               (if (eq (plist-get result :status) 'ok)
                   (let* ((val (plist-get result :value))
                          (cues (plist-get val :cues))
                          (vec (vconcat cues)))
                     (etaf-youtube--set app :caption-vec vec)
                     (etaf-youtube--write app :captions val)
                     (etaf-youtube--publish-hud app
                                                (or (plist-get app :live-position) 0)
                                                (or (plist-get app :live-duration) 0)
                                                nil nil))
                 (etaf-youtube--set app :caption-vec nil)
                 (etaf-batch
                   (etaf-youtube--write app :captions-on nil)
                   (etaf-youtube--write app :caption-language nil))
                 (etaf-youtube--note app
                                     (or (plist-get result :message) "无法加载字幕")
                                     'danger)))))
        (etaf-youtube--note app "当前视频暂无可用字幕轨道" 'info))))
  app)

(defun etaf-youtube-toggle-captions (app)
  "Turn APP's subtitles on or off."
  (interactive)
  (if (etaf-youtube--read app :captions-on)
      (etaf-youtube--select-caption-track app nil)
    (let ((tracks (etaf-youtube--available-subtitle-tracks app)))
      (if tracks
          (etaf-youtube--select-caption-track app (car tracks))
        (etaf-youtube--note app "当前视频暂无字幕轨道" 'info))))
  app)

(defun etaf-youtube--cycle-captions (app)
  "Cycle through available subtitle tracks and off."
  (let* ((tracks (etaf-youtube--available-subtitle-tracks app))
         (cur-lang (and (etaf-youtube--read app :captions-on)
                        (etaf-youtube--read app :caption-language)))
         (idx (and cur-lang
                   (cl-position cur-lang tracks
                                :key (lambda (tr) (plist-get tr :language))
                                :test #'equal))))
    (cond
     ((null tracks)
      (etaf-youtube--note app "当前视频暂无字幕轨道" 'info))
     ((null cur-lang)
      (etaf-youtube--select-caption-track app (car tracks))
      (etaf-youtube--note app (format "字幕：%s" (or (plist-get (car tracks) :name)
                                                     (plist-get (car tracks) :language)))
                          'info))
     ((and idx (< (1+ idx) (min 4 (length tracks))))
      (let ((next (nth (1+ idx) tracks)))
        (etaf-youtube--select-caption-track app next)
        (etaf-youtube--note app (format "字幕：%s" (or (plist-get next :name)
                                                       (plist-get next :language)))
                            'info)))
     (t
      (etaf-youtube--select-caption-track app nil)
      (etaf-youtube--note app "字幕：已关闭" 'info)))))

(defun etaf-youtube-caption-text (app)
  "Return APP's subtitle text at the current position via O(log N) search, or nil.
Cues are half-open intervals: active from `start' inclusive to `end' exclusive."
  (when (etaf-youtube--read app :captions-on)
    (let* ((captions (etaf-youtube--read app :captions))
           (vec (or (plist-get app :caption-vec)
                    (and captions (vconcat (plist-get captions :cues)))))
           (pos (or (and (numberp (plist-get app :live-position))
                         (plist-get app :live-position))
                    (etaf-youtube--read app :position))))
      (when (and (vectorp vec) (> (length vec) 0) (numberp pos))
        (let ((lo 0) (hi (1- (length vec))) (best -1))
          (while (<= lo hi)
            (let* ((mid (/ (+ lo hi) 2))
                   (start (or (plist-get (aref vec mid) :start) 0)))
              (if (<= start pos)
                  (setq best mid lo (1+ mid))
                (setq hi (1- mid)))))
          (when (>= best 0)
            (let* ((cue (aref vec best))
                   (end (or (plist-get cue :end) 0))
                   (text (plist-get cue :text)))
              (when (and (< pos end) (stringp text) (not (string-empty-p text)))
                text))))))))

;;; ---------------------------------------------------------------------------
;;; Comments, pagination & reactive replies
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

(defun etaf-youtube--load-more-comments (app)
  "Append the next page of comments for APP."
  (let* ((comments (etaf-youtube--read app :comments))
         (cursor (plist-get comments :next)))
    (when (and cursor (not (etaf-youtube--read app :comments-more)))
      (etaf-youtube--write app :comments-more t)
      (etaf-youtube--request
       app :comments-more (list "more" cursor)
       (lambda (result)
         (etaf-youtube--write app :comments-more nil)
         (if (eq (plist-get result :status) 'ok)
             (let* ((payload (plist-get result :value))
                    (old (etaf-youtube--read app :comments))
                    (merged (append (plist-get old :items) (plist-get payload :items)))
                    (updated (plist-put (copy-sequence old) :items merged)))
               (setq updated (plist-put updated :next (plist-get payload :next)))
               (etaf-youtube--write app :comments updated))
           (etaf-youtube--note app (or (plist-get result :message) "无法加载更多评论") 'danger)))))))

(defun etaf-youtube--load-more-related (app)
  "Append the next page of related videos on APP's Watch page."
  (let* ((video (etaf-youtube--read app :video))
         (cursor (plist-get video :related_next)))
    (when (and cursor (not (etaf-youtube--read app :related-more)))
      (etaf-youtube--write app :related-more t)
      (etaf-youtube--request
       app :related-more (list "more" cursor)
       (lambda (result)
         (etaf-youtube--write app :related-more nil)
         (if (eq (plist-get result :status) 'ok)
             (let* ((payload (plist-get result :value))
                    (old (etaf-youtube--read app :video))
                    (new-items (plist-get payload :items))
                    (merged (append (plist-get old :related) new-items))
                    (updated (plist-put (copy-sequence old) :related merged)))
               (setq updated (plist-put updated :related_next (plist-get payload :next)))
               (etaf-youtube--prefetch-thumbnails app new-items)
               (etaf-youtube--write app :video updated))
           (etaf-youtube--note app (or (plist-get result :message) "无法加载更多推荐") 'danger)))))))

(defun etaf-youtube--comment-item (app comment-id)
  "Return APP's comment row for COMMENT-ID, or nil."
  (seq-find (lambda (item) (equal comment-id (plist-get item :id)))
            (plist-get (etaf-youtube--read app :comments) :items)))

(defun etaf-youtube--toggle-replies-collapsed (app comment-id)
  "Toggle collapsed visibility of loaded replies for COMMENT-ID."
  (let ((table (plist-get app :replies-collapsed)))
    (puthash comment-id (not (gethash comment-id table)) table)
    (etaf-youtube--write app :replies-version
                         (1+ (or (etaf-youtube--read app :replies-version) 0)))))

(defun etaf-youtube-load-replies (app comment-id &optional cursor)
  "Load CURSOR's replies to COMMENT-ID in APP, or its first page."
  (let* ((entry (gethash comment-id (etaf-youtube--read app :replies)))
         (exhausted (plist-get entry :exhausted))
         (cursor (or cursor
                     (and (not exhausted) (etaf-youtube-replies-cursor app comment-id))
                     (and (null entry)
                          (plist-get (etaf-youtube--comment-item app comment-id) :replies)))))
    (when cursor
      (remhash comment-id (plist-get app :replies-collapsed))
      (etaf-youtube--request-token
       app (intern (format "replies:%s" comment-id))
       (list "more" cursor)
       (lambda (result token)
         (when (etaf-youtube--current-p app (intern (format "replies:%s" comment-id))
                                        token)
           (let ((replies (copy-hash-table (etaf-youtube--read app :replies))))
             (if (eq (plist-get result :status) 'ok)
                 (let* ((payload (plist-get result :value))
                        (old (gethash comment-id replies))
                        (items (append (plist-get old :items)
                                       (plist-get payload :items)))
                        (next (plist-get payload :next))
                        (stored (plist-put (copy-sequence payload) :items items)))
                   (setq stored (plist-put stored :exhausted (null next)))
                   (puthash comment-id stored replies)
                   (etaf-batch
                     (etaf-youtube--write app :replies replies)
                     (etaf-youtube--write app :replies-version
                                          (1+ (or (etaf-youtube--read app :replies-version) 0)))))
               (etaf-youtube--note app (or (plist-get result :message)
                                           "无法加载回复")
                                   'danger))))))))
  app)

(defun etaf-youtube-replies-cursor (app comment-id)
  "Return APP's stored replies cursor for COMMENT-ID, or nil."
  (plist-get (gethash comment-id (etaf-youtube--read app :replies)) :next))

(defun etaf-youtube-replies (app comment-id)
  "Return APP's loaded replies for COMMENT-ID."
  (plist-get (gethash comment-id (etaf-youtube--read app :replies)) :items))

;;; ---------------------------------------------------------------------------
;;; Explicit writes (with strict preview/confirmation/verification semantics)
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--patch-video (app key value)
  "Copy APP's video and set KEY to VALUE so the watch page repaints."
  (when-let* ((video (etaf-youtube--read app :video)))
    (etaf-youtube--write app :video (plist-put (copy-sequence video) key value))))

(defun etaf-youtube--apply-write (app result operation)
  "Record write RESULT for OPERATION in APP and report its certainty.
Only mutates local UI state when STATUS is `confirmed' or `unchanged';
previews, blocked responses and failures leave UI state untouched."
  (if (not (eq (plist-get result :status) 'ok))
      (etaf-youtube--note app (or (plist-get result :message) "操作失败") 'danger)
    (let* ((payload (plist-get result :value))
           (status (plist-get payload :status))
           (verified (plist-get payload :verified)))
      (when (member status '("confirmed" "unchanged"))
        (pcase operation
          ('like (etaf-youtube--patch-video app :like_status "LIKE"))
          ('dislike (etaf-youtube--patch-video app :like_status "DISLIKE"))
          ('unrate (etaf-youtube--patch-video app :like_status "INDIFFERENT"))
          ('subscribe (etaf-youtube--patch-video app :subscribed t))
          ('unsubscribe (etaf-youtube--patch-video app :subscribed nil))))
      (cond
       ((member status '("confirmed" "unchanged"))
        (etaf-youtube--note app
                            (pcase operation
                              ('like "已点赞")
                              ('dislike "已点踩")
                              ('unrate "已取消评分")
                              ('subscribe "已订阅该频道")
                              ('unsubscribe "已取消订阅")
                              ('save "已保存到播放列表")
                              ('comment "评论已发布")
                              (_ "操作完成"))
                            'success))
       ((equal status "preview")
        (etaf-youtube--note app (format "预览操作：%s（需要显式确认才会提交）" operation) 'info))
       ((equal status "submitted")
        (etaf-youtube--note
         app (format "%s：已提交但未能回读确认，请稍后在网页核对（不会自动重发）"
                     (pcase operation
                       ('comment "评论")
                       ('subscribe "订阅")
                       ('unsubscribe "退订")
                       ('save "保存")
                       (_ "操作")))
         'warning t))
       ((equal status "blocked")
        (etaf-youtube--note app (or (plist-get payload :message)
                                    "当前账号没有权限执行该操作")
                            'danger))
       (t
        (etaf-youtube--note app (format "操作结果：%s" (or status "未知"))
                            (if verified 'success 'warning))))))
  app)

(defun etaf-youtube--write-action (app operation &optional yes extra target-override)
  "Submit OPERATION for APP's current video (or TARGET-OVERRIDE).
YES authorizes the real write; without it the backend previews only."
  (let* ((video (etaf-youtube--read app :video))
         (target (or target-override (and video (plist-get video :id)))))
    (cond
     ((null video)
      (etaf-youtube--note app "请先打开一个视频" 'info))
     ((or (null target) (string-empty-p target))
      (etaf-youtube--note app "缺少操作目标 ID，无法执行该操作" 'danger))
     (t
      (etaf-youtube--request
       app :action
       (append (list "action" operation target)
               extra
               (when yes (list "--yes")))
       (lambda (result)
         (etaf-youtube--apply-write app result (intern operation)))))))
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
  "Subscribe to APP's video author channel when SUBSCRIBE-P, else unsubscribe.
Passes the channel's `UC...' `:channel_id' as required by the backend."
  (interactive)
  (let* ((video (etaf-youtube--read app :video))
         (channel-id (and video (etaf-youtube--nonempty-string
                                 (plist-get video :channel_id)))))
    (etaf-youtube--write-action app (if subscribe-p "subscribe" "unsubscribe")
                                yes nil channel-id)))

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
;;; Appearance, layout & quality choices
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-set-theme (app mode)
  "Switch APP to the appearance MODE, `dark' or `light'."
  (unless (memq mode '(dark light))
    (signal 'etaf-youtube-error (list (format "Unknown appearance: %S" mode))))
  (etaf-batch
    (etaf-youtube--write app :theme-mode mode)
    (etaf-youtube--write app :palette (etaf-youtube-theme-defaults mode)))
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

(defun etaf-youtube-exit-fullscreen (app)
  "Exit Pure Fullscreen for APP, restoring mode-line, splits and frame."
  (let ((buf (plist-get app :buffer)))
    (if (and buf (buffer-live-p buf))
        (progn
          (etaf-fullscreen-exit buf)
          (unless (null (etaf-youtube--read app :fullscreen))
            (etaf-youtube--write app :fullscreen nil)))
      (etaf-youtube--write app :fullscreen nil)))
  app)

(defun etaf-youtube-toggle-fullscreen (app &optional mode)
  "Toggle APP's Pure Fullscreen MODE (`window' or `frame')."
  (let* ((target (or mode 'window))
         (buf (plist-get app :buffer)))
    (if (and buf (buffer-live-p buf))
        (etaf-fullscreen-toggle
         target buf :hide-mode-line t
         :on-change (lambda (m) (etaf-youtube--write app :fullscreen m)))
      (let* ((cur (etaf-youtube--read app :fullscreen))
             (next (if (eq cur target) nil target)))
        (etaf-youtube--write app :fullscreen next)))
    app))

(defun etaf-youtube-toggle-theater (app)
  "Switch APP's watch page between two columns and one."
  (interactive)
  (if (etaf-youtube--read app :fullscreen)
      (progn
        (etaf-youtube-exit-fullscreen app)
        (etaf-youtube--write app :theater t))
    (etaf-youtube--write app :theater (not (etaf-youtube--read app :theater))))
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
  "Return the quality heights APP's current media offers for selection."
  (let* ((media (etaf-youtube--read app :media))
         (available (plist-get media :qualities))
         (choices (seq-filter (lambda (height)
                                (or (null available)
                                    (memq height available)))
                              etaf-youtube--quality-levels)))
    (or choices '(720))))

(provide 'etaf-youtube-model)
;;; etaf-youtube-model.el ends here
