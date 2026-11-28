;;; etaf-ncm-model.el --- Player state and backend actions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns everything a player session remembers: the selected library,
;; the visible rows, the keyboard selection, the playback status, the queue and
;; the lyric.  Every mutable value is an ETAF reactive source, so a View that
;; reads it repaints when a backend reply arrives; every backend request is
;; asynchronous and its reply is dropped when it belongs to a superseded load.
;;
;; The model is independent of any buffer: `etaf-ncm-create' plus the public
;; actions drive a complete session headlessly, which is how the acceptance
;; scenarios exercise it with a fake client.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ncm-cache)
(require 'etaf-ncm-service)
(require 'etaf-ncm-theme)
(require 'etaf-ncm-layout)

(defconst etaf-ncm-sections
  '((推荐
     (:daily "每日推荐" star)
     (:fm "私人 FM" radio)
     (:liked "我喜欢的音乐" heart))
    (我的音乐
     (:playlists "我的歌单" list)
     (:albums "收藏专辑" disc)
     (:artists "收藏歌手" account))
    (发现
     (:charts "排行榜" chart)
     (:podcasts "播客" mic)
     (:recent "最近播放" clock)))
  "Sidebar groups shown by the player.
Each group is (GROUP-NAME (SECTION LABEL ICON) ...); SECTION keys are accepted
by `etaf-ncm-locate', and ICON names an entry of the shared SVG icon set.")

(defconst etaf-ncm--section-subtitles
  '((:daily . "根据你的口味生成，每天更新")
    (:fm . "没听过的歌，一直放下去")
    (:liked . "你点过红心的歌")
    (:playlists . "收藏和自己建的歌单")
    (:albums . "收藏过的专辑")
    (:artists . "关注的歌手")
    (:charts . "飙升榜、新歌榜和各类榜单")
    (:podcasts . "订阅的播客节目")
    (:recent . "最近一周听过什么"))
  "One-line explanation shown under each library title.")

(defcustom etaf-ncm-page-size 24
  "Library rows shown at once.
`etaf-ncm-open' replaces this with the number that fits the window, so the
player fills the frame it is given; the default only applies to a headless
model created by `etaf-ncm-create'."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-render-limit 1000
  "Rows the library list keeps in its scrolling canvas.
The list scrolls natively, so every rendered row is laid out once: a few
hundred rows mount in a fraction of a second and scrolling stays flat, while
the cap keeps a pathological library from building an unbounded canvas."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-wheel-rows 3
  "Library and queue rows one wheel tick scrolls.
The canvas scrolls `ebox-scroll-step' lines per tick, so a player that moved
one row would feel stuck beside every other ETAF surface; three rows also keep
a small card page from needing one notch per song."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-fetch-limit 100
  "Lower bound on rows requested from the backend for one library load.
The request also respects `etaf-ncm-list-limit' and three visible pages."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-list-limit 1000
  "Rows requested from the backend for a library load.
The request uses at least `etaf-ncm-fetch-limit' and three visible pages.
When the backend reports more rows than it returns, the footer shows both the
loaded count and the total; navigation covers the loaded rows."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-status-interval 1.0
  "Seconds between playback ticks while a song is playing.
Each tick advances the local clock for a smooth progress bar and asks the
backend for playback truth; requests never overlap."
  :type 'number
  :group 'etaf-ncm)

(defcustom etaf-ncm-idle-poll-interval 15
  "Seconds between playback checks while nothing is playing."
  :type 'number
  :group 'etaf-ncm)

(defcustom etaf-ncm-library-refresh-interval 300
  "Seconds after which a cached library list is refreshed in the background.
A cached list is shown immediately when a library is opened, then refreshed;
the cache is a display shortcut, never the source of truth."
  :type 'number
  :group 'etaf-ncm)

(defcustom etaf-ncm-prefetch-libraries t
  "Whether a mounted player warms the library cache in the background.
One not-yet-cached sidebar list is loaded at a time while the player is idle,
so opening a library rarely waits for the network."
  :type 'boolean
  :group 'etaf-ncm)

;;; ---------------------------------------------------------------------------
;;; Construction and reactive access
;;; ---------------------------------------------------------------------------

(cl-defun etaf-ncm-create (&key client cache-file)
  "Create a player session that talks to CLIENT.
CLIENT defaults to `etaf-ncm-client-factory' when that is bound, and otherwise
to `etaf-ncm-make-client'.  The session owns no buffer and no timer until it is
mounted by `etaf-ncm-app' or started by `etaf-ncm-refresh'; it is also a
complete headless player for tests and other Lisp callers.
CACHE-FILE optionally selects a local library snapshot. The default subprocess
client persists in its state directory; function clients default to memory."
  (let* ((client (or client
                     (if etaf-ncm-client-factory
                         (funcall etaf-ncm-client-factory)
                       (etaf-ncm-make-client))))
         ;; One retained source per visible row slot.  A list reply writes
         ;; these sources, and the row Hosts read them in place, so switching
         ;; libraries publishes prepared text and paint instead of rebuilding
         ;; the list view.
         (playing-id (etaf-ref nil :name 'etaf-ncm-playing-id))
         (row-slots (vconcat (cl-loop for index from 0 below etaf-ncm-page-size
                                      collect (etaf-ref nil :name
                                                        (intern (format "etaf-ncm-row-%d" index))))))
         (row-playing (vconcat (cl-loop for slot across row-slots
                                        collect (let ((watched slot))
                                                  (etaf-computed
                                                   (lambda ()
                                                     (let ((row (etaf-value watched))
                                                           (played (etaf-value playing-id)))
                                                       (and row played
                                                            (equal (plist-get row :id) played)))))))))
         (cache-file (or cache-file (etaf-ncm--client-cache-file client)))
         ;; Lyrics and cover files persist in a SQLite database beside the
         ;; library snapshot.  A function client without a snapshot path keeps
         ;; its media in memory, exactly like the list cache.
         (media-cache (and cache-file
                           (etaf-ncm-cache-open
                            (expand-file-name "media-cache.sqlite"
                                              (file-name-directory cache-file))))))
    (let ((app (list :client client
          :cache-file cache-file
          :cache-identity (etaf-ncm--client-cache-identity client)
          :cache-save-timer nil
          :list-in-flight (make-hash-table :test 'equal)
          :list-positions (make-hash-table :test 'equal)
          :playing-id playing-id
          :row-slots row-slots
          :row-playing row-playing
          :page-label (etaf-ref "" :name 'etaf-ncm-page-label)
          :loaded-label (etaf-ref "" :name 'etaf-ncm-loaded-label)
          :empty-note (etaf-ref "" :name 'etaf-ncm-empty-note)
          :visible-count (etaf-ref 0 :name 'etaf-ncm-visible-count)
          :footer-visible (etaf-ref nil :name 'etaf-ncm-footer-visible)
          :playable (etaf-ref nil :name 'etaf-ncm-playable)
          :more-visible (etaf-ref nil :name 'etaf-ncm-more-visible)
          :selected-album (etaf-ref "" :name 'etaf-ncm-selected-album)
          :buffer nil
          :page-size (etaf-ref etaf-ncm-page-size :name 'etaf-ncm-page-size)
          :queue-rows (etaf-ref etaf-ncm-page-size :name 'etaf-ncm-queue-rows)
          :lyric-rows (etaf-ref (max 0 (- etaf-ncm-page-size 7))
                               :name 'etaf-ncm-lyric-rows)
          :disposed nil
          :status-in-flight nil
          :polled-at 0
          ;; The fields the commands published optimistically; a status reply
          ;; that cannot show a still-unsettled command must not move them
          ;; back.  The count tracks how many commands await their reply.
          :optimistic-at nil
          :optimistic-keys nil
          :commands-pending 0
          :last-tick (float-time)
          :timer nil
          :last-press nil
          :list-cache (etaf-list-cache-create :grace 3)
          :list-key nil
          ;; Liked-song ids: the backend status carries no like field, so the
          ;; player compares the playing song against this table.
          :liked-ids (make-hash-table :test 'eql)
          :liked-ids-loaded nil
          :liked-ids-at 0
          ;; Local library: the backend's download registry keyed by song id.
          ;; A song with a live local file gets a list marker and the backend
          ;; queue plays it from disk instead of fetching a fresh URL.
          :downloads (make-hash-table :test 'eql)
          :downloads-loaded nil
          :downloads-at 0
          :cover-requested-id nil
          ;; Holds the page's frame clock once the page opens.  It is present
          ;; from the start because `plist-put' can only update a key that is
          ;; already in the list in place; a new key would be dropped with the
          ;; local binding.
          :visual-timer nil
          ;; Cell geometry the current page backdrop was built for, so a
          ;; resize rebuilds it once instead of on every frame.
          :now-art-key nil
          :media-cache media-cache
          :section (etaf-ref :daily :name 'etaf-ncm-section)
          :title (etaf-ref "每日推荐" :name 'etaf-ncm-title)
          :subtitle (etaf-ref "根据你的口味生成，每天更新" :name 'etaf-ncm-subtitle)
          :origin (etaf-ref '(:kind :daily) :name 'etaf-ncm-origin)
          :rows (etaf-ref nil :name 'etaf-ncm-rows)
          :list-total (etaf-ref 0 :name 'etaf-ncm-list-total)
          :selection (etaf-ref 0 :name 'etaf-ncm-selection)
          :status (etaf-ref nil :name 'etaf-ncm-status)
          ;; Per-interaction display state has its own retained reactive source.
          ;; The player bar's Hosts read these refs, so a toggle publishes a
          ;; retained Host update instead of re-rendering the whole view.
          :state-ref (etaf-ref nil :name 'etaf-ncm-state)
          :liked-ref (etaf-ref nil :name 'etaf-ncm-liked)
          :shuffle-ref (etaf-ref nil :name 'etaf-ncm-shuffle)
          :repeat-ref (etaf-ref nil :name 'etaf-ncm-repeat)
          :volume-ref (etaf-ref 0 :name 'etaf-ncm-volume)
          ;; The displayed position is not reactive: a playing second changes it
          ;; and is shown through the player bar's retained Hosts, so a write
          ;; here would republish the whole view once per second.
          :clock 0
          :position-ref (etaf-ref 0 :name 'etaf-ncm-position)
          ;; (wall-clock . target) of a seek the backend has not applied yet.
          :seek-guard (etaf-ref nil :name 'etaf-ncm-seek-guard)
          :queue (etaf-ref nil :name 'etaf-ncm-queue)
          ;; Nil follows playback; a wheel gesture pins a loaded window until
          ;; the playing entry or queue contents change.
          :queue-start (etaf-ref nil :name 'etaf-ncm-queue-start)
          :lyric (etaf-ref nil :name 'etaf-ncm-lyric)
          ;; Playing song's downloaded cover art path; nil is the placeholder.
          :cover-file (etaf-ref nil :name 'etaf-ncm-cover-file)
          :aside (etaf-ref 'lyrics :name 'etaf-ncm-aside)
          ;; Which screen the window shows: the library player, or the
          ;; full-page view of the playing song.
          :screen (etaf-ref 'library :name 'etaf-ncm-screen)
          ;; Which page design the full-page view uses: `immersive' paints one
          ;; picture across the window, `split' gives the picture one pane.
          :now-mode (etaf-ref 'auto :name 'etaf-ncm-now-mode)
          ;; The page's backdrop and spectrum colour, both derived from the
          ;; playing cover by `etaf-ncm-hero-file' and `etaf-ncm-hero-accent'.
          :hero (etaf-ref nil :name 'etaf-ncm-hero)
          :hero-accent (etaf-ref nil :name 'etaf-ncm-hero-accent)
          ;; The page's spectrum, written by the audio meter once per frame.
          :spectrum (etaf-ref " " :name 'etaf-ncm-spectrum)
          :theme (etaf-ref (etaf-ncm-theme-defaults) :name 'etaf-ncm-theme)
          :account (etaf-ref nil :name 'etaf-ncm-account)
          :query (etaf-ref "" :name 'etaf-ncm-query)
          :mode (etaf-ref 'browse :name 'etaf-ncm-mode)
          :layout (etaf-ref 'wide :name 'etaf-ncm-layout)
          :columns (etaf-ref nil :name 'etaf-ncm-columns)
          :window-rows (etaf-ref nil :name 'etaf-ncm-window-rows)
          :pane (etaf-ref 'list :name 'etaf-ncm-pane)
          :loading (etaf-ref nil :name 'etaf-ncm-loading)
          :error (etaf-ref nil :name 'etaf-ncm-error)
          :message (etaf-ref nil :name 'etaf-ncm-message))))
      (etaf-ncm--restore-cache app)
      app)))

(defun etaf-ncm--ref (model key)
  "Return MODEL's reactive source named KEY."
  (plist-get model key))

(defun etaf-ncm--read (model key)
  "Return MODEL's current value for KEY, tracked while rendering."
  (etaf-value (etaf-ncm--ref model key)))

(defun etaf-ncm--write (model key value)
  "Publish VALUE as MODEL's new value for KEY; return VALUE.
A write that would not change the reading is skipped: the player re-renders on
every write, and a status tick that repeats the previous reading (an idle
poll, a reply that matches the local clock) would otherwise repaint the whole
view for nothing."
  (let ((ref (etaf-ncm--ref model key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

(defun etaf-ncm--update (model key function &rest arguments)
  "Publish (FUNCTION OLD-READING ARGUMENTS ...) as MODEL's value for KEY."
  (apply #'etaf-update-value (etaf-ncm--ref model key) function arguments))

(defconst etaf-ncm--flag-slots
  '((:state . :state-ref) (:liked . :liked-ref)
    (:shuffle . :shuffle-ref) (:repeat . :repeat-ref) (:volume . :volume-ref))
  "Status fields displayed through their own retained reactive sources.")

(defun etaf-ncm--flag-value (app key)
  "Return APP's displayed flag KEY from its retained source.
Every status reply syncs the source, so it is the current reading, including
an optimistic change the backend has not confirmed yet."
  (etaf-value (etaf-ncm--ref app (cdr (assq key etaf-ncm--flag-slots)))))

(defun etaf-ncm--sync-flags (app status &optional protected)
  "Publish STATUS's display flags to APP's retained reactive sources.
PROTECTED names status fields whose optimistic display must survive a reply
that left the backend before the user's last command."
  (dolist (pair etaf-ncm--flag-slots)
    (when (and (plist-member status (car pair))
               (not (memq (car pair) protected)))
      (etaf-ncm--write app (cdr pair) (plist-get status (car pair))))))

(defun etaf-ncm--clock (app)
  "Return APP's displayed playback position in seconds."
  (or (plist-get app :clock) 0))

(defun etaf-ncm--set-clock (app seconds)
  "Store SECONDS and publish the retained position source, not the whole status."
  (setf (plist-get app :clock) seconds)
  (etaf-ncm--write app :position-ref seconds))

(defconst etaf-ncm--reply-volatile-keys '(:elapsed :as-of :state :liked :shuffle :repeat :volume)
  "Status fields that move with every backend reply, not with the track.
Flag fields are displayed through their own retained host sources, so a reply
that only moves them updates those hosts instead of republishing the view.")

(defun etaf-ncm--status-steady (status)
  "Return STATUS without the fields that move with every backend reply."
  (let ((copy (copy-sequence status)))
    (dolist (key etaf-ncm--reply-volatile-keys)
      (setq copy (plist-put copy key nil)))
    copy))

(defun etaf-ncm--status-steady-p (previous status)
  "Return non-nil when STATUS only moves PREVIOUS's volatile fields.
A steady reply reports a new position and measurement time for the same track,
so the player bar updates in place instead of republishing the whole view."
  (and previous
       (equal (etaf-ncm--status-steady previous)
              (etaf-ncm--status-steady status))))

(defun etaf-ncm--client (model)
  "Return MODEL's backend client."
  (plist-get model :client))

(cl-defun etaf-ncm--call (model request &key on-ok on-error quiet)
  "Send REQUEST for MODEL, routing a failure into the visible status line.
ON-OK receives the reply data; ON-ERROR the failure message, its hint and the
backend's error code. QUIET leaves visible error/message state untouched.
A client that signals while turning a request into a command is treated like any
backend failure, so nothing reaches the caller of a player action."
  (let ((delivered nil)
        (fail (lambda (message hint code)
                (if (equal code "auth")
                    ;; The player can sign in itself; the backend's CLI hint is
                    ;; not what an in-player reader can act on.
                    (let ((text "登录已过期：按 L 用短信验证码重新登录"))
                      (unless quiet
                        (etaf-ncm--write model :error text)
                        (etaf-ncm--write model :message text))
                      (when on-error (funcall on-error text nil code)))
                  (unless quiet
                    (etaf-ncm--write model :error message)
                    (etaf-ncm--write model :message
                                     (if (and hint (not (string-empty-p hint)))
                                         (format "%s（%s）" message hint)
                                       message)))
                  (when on-error (funcall on-error message hint code))))))
    (condition-case error
        (etaf-ncm-client-call
         (etaf-ncm--client model) request
         (lambda (result)
           (setq delivered t)
           (if (eq (car result) :ok)
               (progn
                 (when on-ok (funcall on-ok (cadr result))))
             (funcall fail (or (cadr result) "请求失败")
                      (plist-get (cddr result) :hint)
                      (plist-get (cddr result) :code)))))
      (error (if delivered
                 (signal (car error) (cdr error))
               (funcall fail (error-message-string error) nil nil))))))

(defun etaf-ncm--note (model text)
  "Show TEXT as the player's status line message.
A routine note replaces whatever came before, so it also takes the failure
banner down: `:error' means “the message now shown is a failure”, and only a
newer message can supersede it.  Routine polls do not write messages, so a
failure the reader still has to act on survives them."
  (etaf-batch
    (etaf-ncm--write model :error nil)
    (etaf-ncm--write model :message text)))

;;; ---------------------------------------------------------------------------
;;; Formatting helpers
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--format-duration (milliseconds)
  "Return MILLISECONDS as \"M:SS\" or an empty string."
  (let ((seconds (and (numberp milliseconds) (/ (round milliseconds) 1000))))
    (if (and seconds (> seconds 0))
        (format "%d:%02d" (/ seconds 60) (% seconds 60))
      "")))

(defun etaf-ncm--format-seconds (seconds)
  "Return SECONDS as \"MM:SS\" or \"00:00\"."
  (let ((seconds (if (numberp seconds) (max 0 (round seconds)) 0)))
    (format "%02d:%02d" (/ seconds 60) (% seconds 60))))

(defun etaf-ncm--truthy-string-p (value)
  "Return non-nil when VALUE is the backend's \"true\"."
  (and (stringp value) (string= (downcase (string-trim value)) "true")))

(defun etaf-ncm--parse-number (value)
  "Return VALUE as a number, or nil when it is empty or not numeric."
  (cond ((numberp value) value)
        ((eq value :false) nil)
        ((not (stringp value)) nil)
        (t (let ((text (string-trim value)))
             (and (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" text)
                  (string-to-number text))))))

;;; ---------------------------------------------------------------------------
;;; Library loading
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--section-label (section)
  "Return the sidebar label of SECTION, or nil."
  (seq-some (lambda (group)
              (when-let* ((entry (assq section (cdr group))))
                (nth 1 entry)))
            etaf-ncm-sections))

(defun etaf-ncm-locate (app section)
  "Show library SECTION in APP and load its rows.
SECTION is one of the keys in `etaf-ncm-sections'.  A cached list is shown at
once without I/O; the periodic scheduler refreshes it in the background.
Only a list absent from memory and the previous-run snapshot needs a backend
load. A late reply warms its own cache without replacing another library.
Unknown SECTION signals `etaf-ncm-error'."
  (unless (and (symbolp section) (or (eq section :search)
                                     (etaf-ncm--section-label section)))
    (signal 'etaf-ncm-error (list (format "Unknown library: %S" section))))
  (let* ((key (list :browse section))
         (same-p (equal key (plist-get app :list-key))))
    (when (plist-get app :list-key)
      (puthash (plist-get app :list-key) (etaf-ncm--list-position app)
               (plist-get app :list-positions)))
    (etaf-batch
      (etaf-ncm--write app :mode 'browse)
      (etaf-ncm--write app :pane 'list)
      (etaf-ncm--write app :section section)
      (etaf-ncm--write app :title (or (etaf-ncm--section-label section) "音乐库"))
      (etaf-ncm--write app :subtitle (or (cdr (assq section etaf-ncm--section-subtitles)) ""))
      (etaf-ncm--write app :origin (list :kind section))
      (setf (plist-get app :list-key) key)
      (etaf-ncm--show-cached-list app key same-p))
    ;; Cache hits do no process creation or disk I/O. The existing periodic
    ;; scheduler alone revalidates/warm-loads libraries after publication.
    (unless (etaf-ncm--list-entry app key)
      (etaf-ncm--load app key (etaf-ncm--browse-request app section) nil same-p))))

(defun etaf-ncm-search (app keyword &optional scope)
  "Search KEYWORD in APP and show the matches.
SCOPE is `song' (default) or `playlist'.  An empty KEYWORD signals
`etaf-ncm-error' instead of querying the backend."
  (let* ((keyword (string-trim (or keyword "")))
         (scope (or scope 'song)))
    (when (string-empty-p keyword)
      (signal 'etaf-ncm-error '("搜索关键词不能为空")))
    (let ((key (list :search keyword scope))
          (request (list :op :search :keyword keyword
                         :scope scope
                         ;; The same depth a library browse loads: a page
                         ;; sized to the window leaves nothing to scroll, so a
                         ;; search showing every match in the first frame has
                         ;; no way to reach the rest of them.  The search API
                         ;; answers nothing past a hundred, so that is the cap:
                         ;; asking for more returned an empty list.
                         :limit (min 100
                                     (max etaf-ncm-list-limit etaf-ncm-fetch-limit
                                          (* 3 (etaf-ncm--read app :page-size))))
                         :resource (if (eq scope 'playlist) :playlists :songs)))
          (same-p (equal (list :search keyword scope)
                         (plist-get app :list-key))))
      (etaf-batch
        (etaf-ncm--write app :mode 'search)
        (etaf-ncm--write app :section :search)
        (etaf-ncm--write app :query keyword)
        (etaf-ncm--write app :title "搜索结果")
        (etaf-ncm--write app :subtitle (format "关键词：%s" keyword))
        (etaf-ncm--write app :origin nil)
        (setf (plist-get app :list-key) key)
        (etaf-ncm--show-cached-list app key same-p))
      (etaf-ncm--load app key request (and (etaf-ncm--list-entry app key) t)
                      same-p))))

(defun etaf-ncm--browse-request (app section)
  "Return the backend browse REQUEST for APP's SECTION."
  (list :op :browse :resource section
        :limit (max etaf-ncm-list-limit etaf-ncm-fetch-limit
                    (* 3 (etaf-ncm--read app :page-size)))))

(defun etaf-ncm--list-entry (app key)
  "Return APP's cached library list for KEY, or nil."
  (etaf-list-cache-entry (plist-get app :list-cache) key))

(defun etaf-ncm--store-list (app key rows total)
  "Cache ROWS and TOTAL for KEY in APP, coalescing a later disk snapshot."
  (etaf-list-cache-put (plist-get app :list-cache) key rows total)
  (when (and (plist-get app :cache-file) (not (plist-get app :cache-save-timer)))
    (setf (plist-get app :cache-save-timer)
          (run-at-time 2 nil (lambda () (etaf-ncm--save-cache app))))))

(defun etaf-ncm--save-cache (app)
  "Persist APP's sidebar lists outside the navigation/publication path."
  (when-let* ((timer (plist-get app :cache-save-timer))) (cancel-timer timer))
  (setf (plist-get app :cache-save-timer) nil)
  (when-let* ((file (plist-get app :cache-file)))
    (let (entries)
      (dolist (section (apply #'append (mapcar #'cdr etaf-ncm-sections)))
        (let* ((key (list :browse (car section)))
               (entry (etaf-ncm--list-entry app key)))
          (when entry (push (append (list :key key) entry) entries))))
      (condition-case error
          (etaf-ncm--cache-write file (plist-get app :cache-identity) entries)
        (error (message "音乐库缓存未保存：%s" (error-message-string error)))))))

(defun etaf-ncm--restore-cache (app)
  "Hydrate APP before mounting; invalid snapshots never delay a cold load."
  (dolist (entry (etaf-ncm--cache-read (plist-get app :cache-file)
                                     (plist-get app :cache-identity)))
    (when (proper-list-p entry)
      (let ((key (plist-get entry :key)) (rows (plist-get entry :rows))
            (total (plist-get entry :total)) (at (plist-get entry :at)))
        (when (and (proper-list-p key) (= (length key) 2)
                   (eq (car key) :browse) (etaf-ncm--section-label (cadr key))
                   (proper-list-p rows) (<= (length rows) 10000)
                   (cl-every (lambda (row)
                               (and (proper-list-p row) (stringp (plist-get row :name))
                                    (memq (plist-get row :kind)
                                          '(:song :playlist :album :artist :chart :podcast :episode)))) rows)
                   (numberp total) (>= total 0) (numberp at) (>= at 0))
          (etaf-list-cache-put (plist-get app :list-cache) key rows total :at at)))))
  (when (etaf-ncm--list-entry app '(:browse :daily))
    (setf (plist-get app :list-key) '(:browse :daily))
    (etaf-ncm--show-cached-list app '(:browse :daily) nil)))

(defun etaf-ncm--list-position (app)
  "Capture APP's selection and viewport by song/resource identity."
  (let* ((rows (etaf-ncm--read app :rows))
         (selected (etaf-ncm--read app :selection)))
    (list :selection selected
          :selected (list (plist-get (nth selected rows) :kind)
                          (plist-get (nth selected rows) :id)))))

(defun etaf-ncm--restore-position (app position)
  "Restore POSITION in APP, following identities through inserted/reordered rows."
  (let* ((rows (etaf-ncm--read app :rows))
         (locate (lambda (key fallback)
                   (or (and (cadr key)
                            (cl-position-if
                             (lambda (row) (equal key (list (plist-get row :kind) (plist-get row :id)))) rows))
                       fallback 0)))
         (selection (max 0 (min (max 0 (1- (length rows)))
                                (funcall locate (plist-get position :selected)
                                         (plist-get position :selection))))))
    (etaf-ncm--write app :selection selection)))

(defun etaf-ncm--show-cached-list (app key keep-position-p)
  "Show APP's cached rows for KEY when one exists, without a loading state.
KEEP-POSITION-P leaves the reader where they are, for a refresh of the list
they are already looking at."
  (let ((entry (etaf-ncm--list-entry app key)))
    (etaf-batch
      (etaf-ncm--write app :rows (plist-get entry :rows))
      (etaf-ncm--write app :list-total (or (plist-get entry :total) 0))
      (if keep-position-p
          (etaf-ncm--clamp-list-position app)
        (etaf-ncm--restore-position app (gethash key (plist-get app :list-positions))))
      (etaf-ncm--write app :loading nil)
      (etaf-ncm--refresh-slots app))))

(defun etaf-ncm--clamp-list-position (app)
  "Keep APP's selection and page inside its current rows."
  (let ((total (length (etaf-ncm--read app :rows))))
    (etaf-ncm--write app :selection
                     (max 0 (min (max 0 (1- total))
                                 (etaf-ncm--read app :selection))))
    (etaf-ncm--refresh-slots app)))

(defun etaf-ncm--load (app key request &optional background keep-position-p)
  "Deduplicate REQUEST under KEY and publish only changed visible data.
BACKGROUND never blanks a cached list. KEEP-POSITION-P follows the selected
resource and viewport through inserts or reordering. Replies for other keys
only warm the cache; disposal invalidates all request tokens."
  (let* ((pending (plist-get app :list-in-flight))
         (cache (plist-get app :list-cache))
         (kind (or (plist-get request :resource) (plist-get request :op))))
    (unless (or background (etaf-ncm--list-entry app key))
      (etaf-ncm--write app :loading t)
      (etaf-ncm--write app :error nil))
    (unless (gethash key pending)
      (let* ((token (list key))
             (finish (lambda ()
                       (when (eq token (gethash key pending))
                         (remhash key pending)
                         (etaf-list-cache-set-busy cache (> (hash-table-count pending) 0))
                         (not (plist-get app :disposed))))))
        (puthash key token pending)
        (etaf-list-cache-set-busy cache t)
        (etaf-ncm--call
         app request :quiet t
         :on-ok
         (lambda (data)
           (when (funcall finish)
             (let* ((rows (etaf-ncm--library-rows kind data))
                    (total (or (etaf-ncm--parse-number (plist-get data :total)) (length rows)))
                    (changed (not (etaf-list-cache-unchanged-p cache key rows total))))
               (if changed (etaf-ncm--store-list app key rows total)
                 (etaf-list-cache-touch cache key))
               (etaf-list-cache-note-success cache)
               (when (equal key (plist-get app :list-key))
                 (etaf-batch
                   (when changed
                     (let ((position (and (or background keep-position-p)
                                          (etaf-ncm--list-position app))))
                       (etaf-ncm--write app :rows rows)
                       (etaf-ncm--write app :list-total total)
                       (etaf-ncm--restore-position app position)))
                   (etaf-ncm--write app :loading nil)
                   (when changed (etaf-ncm--refresh-slots app))
                   (unless background
                     (etaf-ncm--note app (format "%s · %d 项" (etaf-ncm--read app :title) (length rows)))))))))
         :on-error
         (lambda (message _hint code)
           (when (funcall finish)
             (etaf-list-cache-note-failure cache code)
             (when (equal key (plist-get app :list-key))
               (etaf-ncm--write app :loading nil)
               (unless background
                 ;; Not `etaf-ncm--note': the failure must raise the banner,
                 ;; not clear it.
                 (etaf-ncm--write app :error message)
                 (etaf-ncm--write app :message message))))))))))

(defun etaf-ncm--cache-visible-p (app)
  "Return non-nil when APP's buffer can be seen, or the session is headless.
A mounted player that no window shows pauses its background library refresh:
nobody is looking at it, so the network can wait until it is shown again."
  (let ((buffer (plist-get app :buffer)))
    (or (null buffer)
        (and (buffer-live-p buffer)
             (get-buffer-window buffer t)))))

(defun etaf-ncm--background-list (app now)
  "Return the (KEY . REQUEST) APP should refresh in the background, or nil.
The stalest cached list is refreshed first; when every sidebar list is still
fresh, one not-yet-cached list is warmed so opening it can use the cache.
`etaf-list-cache' owns that order, the freshness interval and the quiet period
after the session starts; this function only maps a section to its request."
  (when (and etaf-ncm-prefetch-libraries
             (etaf-ncm--cache-visible-p app)
             (not (etaf-ncm--read app :loading)))
    (let* ((sections (mapcar #'car (apply #'append (mapcar #'cdr etaf-ncm-sections))))
           (pairs (mapcar (lambda (section) (cons (list :browse section) section))
                          sections))
           (key (etaf-list-cache-next (plist-get app :list-cache)
                                      (mapcar #'car pairs)
                                      now etaf-ncm-library-refresh-interval)))
      (when key
        (let ((section (cdr (assq key pairs))))
          (cons key (list :request (etaf-ncm--browse-request app section))))))))

(defun etaf-ncm--refresh-background-list (app now)
  "Start one stale background library refresh for APP, when one is due."
  (when-let* ((next (etaf-ncm--background-list app now)))
    (etaf-list-cache-set-busy (plist-get app :list-cache) t)
    (etaf-ncm--load app (car next) (plist-get (cdr next) :request) t)))

(defun etaf-ncm--library-rows (kind data)
  "Map backend DATA of KIND into library rows."
  (pcase kind
    ((or :daily :liked :fm :recent :search :songs)
     (etaf-ncm--song-rows (plist-get data :songs)))
    (:playlists (etaf-ncm--playlist-rows (plist-get data :playlists)))
    (:charts (etaf-ncm--chart-rows (plist-get data :charts)))
    (:albums (etaf-ncm--album-rows (plist-get data :albums)))
    (:artists (etaf-ncm--artist-rows (plist-get data :artists)))
    (:podcasts (etaf-ncm--podcast-rows (plist-get data :podcasts)))
    (_ nil)))

(defun etaf-ncm--song-rows (songs)
  "Return SONG plists as playable rows."
  (cl-loop for song in (etaf-ncm--list songs)
           for id = (etaf-ncm--parse-number (plist-get song :id))
           when id
           collect (list :kind :song
                         :id id
                         :name (etaf-ncm--string (plist-get song :name))
                         :subtitle (etaf-ncm--string (plist-get song :artist))
                         :meta (etaf-ncm--string (plist-get song :album))
                         :badge (if (eq t (plist-get song :vip)) "VIP" nil)
                         :right (etaf-ncm--format-duration
                                 (etaf-ncm--parse-number (plist-get song :ms)))
                         :ms (etaf-ncm--parse-number (plist-get song :ms))
                         :plays (etaf-ncm--parse-number (plist-get song :plays)))))

(defun etaf-ncm--playlist-rows (playlists)
  "Return PLAYLIST plists as rows that play the whole list."
  (cl-loop for playlist in (etaf-ncm--list playlists)
           for id = (etaf-ncm--parse-number (plist-get playlist :id))
           when id
           collect (list :kind :playlist
                         :id id
                         :name (etaf-ncm--string (plist-get playlist :name))
                         :subtitle (etaf-ncm--string (plist-get playlist :creator))
                         :meta (format "%s 首"
                                       (or (etaf-ncm--parse-number
                                            (plist-get playlist :count)) 0))
                         :badge (cond ((eq t (plist-get playlist :sub)) "收藏")
                                      ((etaf-ncm--parse-number
                                        (plist-get playlist :special)) "喜欢")
                                      (t nil))
                         :right "")))

(defun etaf-ncm--chart-rows (charts)
  "Return CHART plists as rows that play the whole chart."
  (cl-loop for chart in (etaf-ncm--list charts)
           for id = (etaf-ncm--parse-number (plist-get chart :id))
           when id
           collect (list :kind :chart
                         :id id
                         :name (etaf-ncm--string (plist-get chart :name))
                         :subtitle (etaf-ncm--string (plist-get chart :freq))
                         :meta (format "%s 首"
                                       (or (etaf-ncm--parse-number
                                            (plist-get chart :count)) 0))
                         :badge nil :right "")))

(defun etaf-ncm--album-rows (albums)
  "Return ALBUM plists as rows that play the whole album."
  (cl-loop for album in (etaf-ncm--list albums)
           for id = (etaf-ncm--parse-number (plist-get album :id))
           when id
           collect (list :kind :album
                         :id id
                         :name (etaf-ncm--string (plist-get album :name))
                         :subtitle (etaf-ncm--string (plist-get album :artist))
                         :meta (format "%s 首"
                                       (or (etaf-ncm--parse-number
                                            (plist-get album :size)) 0))
                         :badge nil :right "")))

(defun etaf-ncm--artist-rows (artists)
  "Return ARTIST plists as rows that play the artist's popular songs."
  (cl-loop for artist in (etaf-ncm--list artists)
           for id = (etaf-ncm--parse-number (plist-get artist :id))
           when id
           collect (list :kind :artist
                         :id id
                         :name (etaf-ncm--string (plist-get artist :name))
                         :subtitle "歌手"
                         :meta (format "%s 张专辑"
                                       (or (etaf-ncm--parse-number
                                            (plist-get artist :albums)) 0))
                         :badge nil :right "")))

(defun etaf-ncm--podcast-rows (podcasts)
  "Return PODCAST plists as rows that play the latest episodes."
  (cl-loop for podcast in (etaf-ncm--list podcasts)
           for id = (etaf-ncm--parse-number (plist-get podcast :id))
           when id
           collect (list :kind :podcast
                         :id id
                         :name (etaf-ncm--string (plist-get podcast :name))
                         :subtitle (etaf-ncm--string (plist-get podcast :dj))
                         :meta (format "%s 期"
                                       (or (etaf-ncm--parse-number
                                            (plist-get podcast :episodes)) 0))
                         :badge nil :right "")))

;;; ---------------------------------------------------------------------------
;;; Playback
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-play (app &optional item)
  "Play ITEM in APP, or the current library when ITEM is nil.
ITEM is a library row, a song id, or a keyword string.  A song row in a
playable library queues the loaded song ids and starts on that song in one
backend command.  No list is fetched again (FM may return different songs),
and no first-entry playback precedes the selection.  Other targets play
directly.  ITEM nil replays the whole current library from its first entry."
  (let* ((target (etaf-ncm--target app item))
         (origin (etaf-ncm--playable-origin app))
         (rows (etaf-ncm--read app :rows))
         (item-id (and (listp item) (plist-get item :id)))
         ;; The list, tests and other callers may hand over a decorated copy
         ;; of a row (the download marker is folded in outside `:rows'), so
         ;; identity first, then kind and id.
         (index (and origin (listp item) (eq (plist-get item :kind) :song)
                     (or (cl-position item rows :test #'eq)
                         (and item-id
                              (cl-position-if
                               (lambda (row)
                                 (and (eq (plist-get row :kind) :song)
                                      (equal (plist-get row :id) item-id)))
                               rows)))))
         (message (format "正在播放：%s" (etaf-ncm--target-label app item))))
    (etaf-ncm--command
     app (append (list :op :play :target (if index origin target))
                 (when index
                   (list :ids (mapcar (lambda (row) (plist-get row :id)) rows)
                         :start (1+ index))))
     message)))

(defun etaf-ncm--playable-origin (app)
  "Return APP's origin when the backend can play it as a whole list."
  (let ((origin (etaf-ncm--read app :origin)))
    (and (assq (plist-get origin :kind) etaf-ncm--play-commands) origin)))

(defun etaf-ncm-add-to-queue (app item)
  "Append ITEM to APP's queue without interrupting the current song."
  (let ((id (etaf-ncm--item-id item)))
    (unless id
      (signal 'etaf-ncm-error '("只能把单曲加入队列")))
    (etaf-ncm--command app (list :op :add :id id)
                       (format "已加入队列：%s" (etaf-ncm--item-name item)))))

(defun etaf-ncm-download (app item)
  "Download the song ITEM into APP's local library.
The backend fetches the best quality the account can play, stores the file
under its configured download directory and registers it, so the next queue
for that song plays the local copy.  A song that is already downloaded is
refreshed in place.  A non-song ITEM signals `etaf-ncm-error'."
  (let* ((target (etaf-ncm--target app item))
         (id (plist-get target :id)))
    (unless (and (eq (plist-get target :kind) :song)
                 (numberp id) (> id 0))
      (signal 'etaf-ncm-error (list (format "只能下载单曲：%S" item))))
    (let* ((label (etaf-ncm--target-label app item))
           (already (gethash id (plist-get app :downloads))))
      (etaf-ncm--note app (if already
                              (format "重新下载：%s" label)
                            (format "开始下载：%s" label)))
      (etaf-ncm--call
       app (list :op :download :id id :force (and already t))
       :on-ok (lambda (data)
                (let ((entry (list :id id
                                   :name (or (etaf-ncm--string (plist-get data :name)) label)
                                   :artist (etaf-ncm--string (plist-get data :artist))
                                   :file (etaf-ncm--string (plist-get data :file))
                                   :level (etaf-ncm--string (plist-get data :level))
                                   :br (etaf-ncm--parse-number (plist-get data :br))
                                   :bytes (etaf-ncm--parse-number (plist-get data :bytes))
                                   :at (etaf-ncm--string (plist-get data :at)))))
                  (puthash id entry (plist-get app :downloads))
                  (setf (plist-get app :downloads-loaded) t
                        (plist-get app :downloads-at) (float-time))
                  (etaf-ncm--note app (format "已下载：%s（%s）"
                                              (plist-get entry :name)
                                              (plist-get entry :level)))
                  (etaf-ncm--refresh-slots app)))))))

(defun etaf-ncm-download-selection (app)
  "Download the library row APP's selection points at.
An empty library does nothing."
  (when-let* ((row (etaf-ncm--selected-row app)))
    (etaf-ncm-download app row)))

(defun etaf-ncm-row-action (app index key)
  "Run action KEY on library row INDEX (counting from 1) in APP.
KEY is `play', `queue' or `download'; the row is resolved when the action
is chosen, so a list reply that moved between opening and choosing cannot
act on a stale row.  An out-of-range INDEX or unknown KEY signals
`etaf-ncm-error'."
  (let ((row (nth (1- index) (etaf-ncm--read app :rows))))
    (unless row
      (signal 'etaf-ncm-error (list (format "没有第 %s 行" index))))
    (pcase key
      ('play (etaf-ncm-play app row))
      ('queue (etaf-ncm-add-to-queue app row))
      ('download (etaf-ncm-download app row))
      (_ (signal 'etaf-ncm-error (list (format "未知行菜单动作：%S" key)))))))

(defun etaf-ncm-jump-queue (app index)
  "Play queue entry INDEX (counting from 1) in APP."
  (etaf-ncm--command app (list :op :jump :index index)
                     (format "切到队列第 %s 首" index)))

(defun etaf-ncm-toggle-playback (app)
  "Pause or resume APP, or start APP's selected song when nothing is loaded.
The toggle reaches the backend as one command, and a queue the backend
reports as empty has nothing to toggle: the selection plays instead, which is
what a person expects after selecting a song and pressing SPC or the play
pill.  Before any status has arrived the toggle is sent unchanged, so an
app still reading a pending session never starts a library item instead."
  (let* ((status (etaf-ncm--read app :status))
         (loaded (or (null status)
                     (not (equal (or (plist-get status :title) "") ""))
                     (> (or (plist-get status :queue-count) 0) 0))))
    (if loaded
        (etaf-ncm--command app (list :op :toggle) "已切换播放状态")
      (if-let* ((row (etaf-ncm--selected-row app)))
          (etaf-ncm-play app row)
        (etaf-ncm--note app "先选中一首歌再播放")))))

(defun etaf-ncm-next-track (app)
  "Play the next song in APP's queue."
  (etaf-ncm--command app (list :op :next) "下一首"))

(defun etaf-ncm-previous-track (app)
  "Play the previous song in APP's queue."
  (etaf-ncm--command app (list :op :previous) "上一首"))

(defun etaf-ncm-stop (app)
  "Stop playback in APP and keep the queue."
  (etaf-ncm--command app (list :op :stop) "已停止播放"))

(defun etaf-ncm-set-volume (app volume)
  "Set APP's volume to VOLUME, an integer between 0 and 100.
The bar's fill and the percentage label share this scale.  A value outside
that range signals `etaf-ncm-error'."
  (unless (and (numberp volume) (<= 0 volume 100))
    (signal 'etaf-ncm-error (list (format "音量要在 0-100 之间：%S" volume))))
  (etaf-ncm--command app (list :op :volume :value (round volume))
                     (format "音量 %d" (round volume))))

(defun etaf-ncm-seek (app seconds)
  "Move APP's playback position by SECONDS relative to the current one.
The target stays displayed for a short window: an asynchronous backend keeps
reporting the old position until mpv applies the seek, and without the guard
the progress bar jumps back and forth around the click."
  (unless (numberp seconds)
    (signal 'etaf-ncm-error (list (format "进度偏移必须是秒数：%S" seconds))))
  (etaf-ncm--write app :seek-guard
                   (cons (+ (float-time) 3.0)
                         (max 0 (+ (etaf-ncm--clock app) (round seconds)))))
  (etaf-ncm--command app (list :op :seek :seconds (round seconds))
                     (format "进度 %s%ss" (if (< seconds 0) "-" "+") (abs (round seconds)))))

(defun etaf-ncm-set-shuffle (app on)
  "Turn queue shuffling in APP ON or off."
  (etaf-ncm--command app (list :op :shuffle :on (and on t))
                     (if on "随机播放：开" "随机播放：关")))

(defun etaf-ncm-set-repeat (app on)
  "Turn list repeat (列表循环) in APP ON or off."
  (etaf-ncm--command app (list :op :repeat :on (and on t))
                     (if on "列表循环：开" "列表循环：关")))

(defun etaf-ncm--sync-liked-list (app song-id liked-p)
  "Reflect a just-confirmed like of SONG-ID in the cached liked list.
The row list and total are adjusted in place so switching to the liked
library shows the change immediately; a quiet reload then reconciles the
order and total with the backend."
  (let* ((key (list :browse :liked))
         (cache (plist-get app :list-cache))
         (entry (etaf-list-cache-entry cache key)))
    (when entry
      (let* ((rows (etaf-list-cache-rows cache key))
             (present (and song-id
                           (seq-some (lambda (row) (equal (plist-get row :id) song-id))
                                     rows)))
             (delta (if liked-p 1 -1))
             (total (max 0 (+ (or (etaf-list-cache-total cache key) 0) delta))))
        (cond
         ((and liked-p (not present))
          (let* ((queue (etaf-ncm--read app :queue))
                 (song (and (listp queue)
                            (seq-find (lambda (item) (equal (plist-get item :id) song-id))
                                      (plist-get queue :songs))))
                 (row (and song (car (etaf-ncm--song-rows (list song))))))
            (when row (setq rows (cons row rows)))))
         ((not liked-p)
          (setq rows (seq-remove (lambda (row) (equal (plist-get row :id) song-id)) rows))))
        (etaf-list-cache-put cache key rows total)
        (when (equal key (plist-get app :list-key))
          (etaf-ncm--write app :rows rows)
          (etaf-ncm--write app :list-total total)
          (etaf-ncm--refresh-slots app))
        ;; The backend list is the authority for order and exact totals.
        (etaf-ncm--load app key (etaf-ncm--browse-request app :liked) t
                        (equal key (plist-get app :list-key)))))))

(defun etaf-ncm-like (app &optional unlike)
  "Like the song playing in APP, or unlike it when UNLIKE is non-nil.
The heart flips before the backend answers; a failed request puts the
previous state back, and the reply reconciles it with measured facts."
  (let* ((status (etaf-ncm--read app :status))
         (song-id (plist-get status :song-id))
         (previous (etaf-ncm--flag-value app :liked)))
    (etaf-ncm--note app (if unlike "已取消喜欢" "已加入我喜欢的音乐"))
    (when (and song-id (plist-get app :liked-ids-loaded))
      (if unlike
          (remhash song-id (plist-get app :liked-ids))
        (puthash song-id t (plist-get app :liked-ids))))
    (etaf-ncm--optimistic-command-begin app '(:liked))
    (etaf-ncm--write app :liked-ref (not unlike))
    (etaf-ncm--call app (list :op (if unlike :unlike :like))
                    :on-ok (lambda (_data)
                             (etaf-ncm--optimistic-command-settle app)
                             (etaf-ncm--sync-liked-list app song-id (not unlike))
                             (etaf-ncm--request-status app))
                    :on-error (lambda (_message _hint _code)
                                (etaf-ncm--optimistic-command-settle app)
                                (when (and song-id (plist-get app :liked-ids-loaded))
                                  (if unlike
                                      (puthash song-id t (plist-get app :liked-ids))
                                    (remhash song-id (plist-get app :liked-ids))))
                                (etaf-ncm--write app :liked-ref previous)))))

(defconst etaf-ncm--queue-commands '(:play :next :previous :jump :stop :add)
  "Commands whose reply can move the queue, which is then reloaded.")

(defun etaf-ncm--optimistic-command-begin (app keys)
  "Record KEYS as the display a command is about to change in APP.
A status reply that left the backend before the command settled cannot show
its effect yet, so the fields stay protected until every in-flight command
answered.  Two overlapping commands union their fields, so the later one
cannot drop the earlier one's protection."
  (setf (plist-get app :optimistic-at) (float-time)
        (plist-get app :optimistic-keys)
        (if (> (or (plist-get app :commands-pending) 0) 0)
            (delete-dups (append keys (plist-get app :optimistic-keys)))
          (copy-sequence keys)))
  (setf (plist-get app :commands-pending)
        (1+ (or (plist-get app :commands-pending) 0))))

(defun etaf-ncm--optimistic-command-settle (app)
  "Mark one of APP's in-flight commands as answered.
The last command to settle releases the protected fields: every status
request sent from now on describes the state after all commands."
  (let ((pending (max 0 (1- (or (plist-get app :commands-pending) 0)))))
    (setf (plist-get app :commands-pending) pending)
    (when (zerop pending)
      (setf (plist-get app :optimistic-keys) nil))))

(defun etaf-ncm--optimistic-status (app update)
  "Publish UPDATE over APP's displayed playback status.
A transport command shows its local effect before the backend confirms it; the
reply then replaces that guess with measured facts."
  (etaf-ncm--write app :status
                   (funcall update
                            (copy-sequence (or (etaf-ncm--read app :status)
                                               (list))))))

(defun etaf-ncm--optimistic-command (app request)
  "Publish REQUEST's locally known effect in APP before its reply arrives."
  (pcase (plist-get request :op)
    (:toggle
     ;; The transport state is displayed through its retained source, so the
     ;; optimistic flip stays off the :status ref that repaints the view.
     (etaf-ncm--write app :state-ref
                      (if (eq (etaf-ncm--flag-value app :state) 'playing)
                          'paused
                        'playing)))
    (:stop
     (etaf-ncm--write app :state-ref 'stopped))
    (:play
     (let* ((ids (plist-get request :ids))
            (start (or (plist-get request :start) 1))
            (id (or (and ids (nth (1- start) ids))
                    (let ((target (plist-get request :target)))
                      (and (eq (plist-get target :kind) :song)
                           (plist-get target :id)))))
            ;; The picked row is already on screen: publish its name, artist
            ;; and length together with the marker, so the bar never shows
            ;; the previous track's text under the new song's marker.
            (row (and id
                      (seq-find (lambda (item)
                                  (and (eq (plist-get item :kind) :song)
                                       (equal (plist-get item :id) id)))
                                (etaf-ncm--read app :rows)))))
       (etaf-ncm--set-clock app 0)
       (etaf-ncm--write app :state-ref 'playing)
       (etaf-ncm--optimistic-status
        app (lambda (status)
              (setq status (plist-put status :state 'playing))
              (setq status (plist-put status :elapsed 0))
              (when id
                (setq status (plist-put status :song-id id))
                (when row
                  (setq status (plist-put status :title (plist-get row :name)))
                  (setq status (plist-put status :artist (plist-get row :subtitle)))
                  (when (plist-get row :ms)
                    (setq status (plist-put status :duration
                                            (round (/ (plist-get row :ms) 1000))))))
                (when ids
                  (setq status (plist-put status :queue-pos start))
                  (setq status (plist-put status :queue-count (length ids)))))
              status))
       (etaf-ncm--sync-playing app)))
    (:volume
     (etaf-ncm--write app :volume-ref (plist-get request :value)))
    (:shuffle
     (etaf-ncm--write app :shuffle-ref (plist-get request :on)))
    (:repeat
     (etaf-ncm--write app :repeat-ref (plist-get request :on)))
    (_ nil)))

(defun etaf-ncm--optimistic-status-keys (request)
  "Return the status fields REQUEST shows before its reply arrives."
  (pcase (plist-get request :op)
    ((or :toggle :stop) '(:state))
    (:play '(:state :song-id :elapsed :title :artist :duration :queue-pos :queue-count))
    (:volume '(:volume))
    (:shuffle '(:shuffle))
    (:repeat '(:repeat))
    (:seek '(:elapsed))
    (_ nil)))

(defvar etaf-ncm--player-owner nil
  "The client whose playback this Emacs started, or nil when none.
A play, skip or jump command hands the player to this Emacs; resuming
takes it back, and a stop releases it.  Exiting Emacs stops an owned
player synchronously, so mpv never outlives the Emacs that started it,
while playback started by another client (the CLI) is left alone.")

(defun etaf-ncm--own-player-for (app request)
  "Record whether REQUEST leaves APP's player owned by this Emacs.
See `etaf-ncm--player-owner' for the meaning of ownership."
  (pcase (plist-get request :op)
    ((or :play :next :previous :jump)
     (setq etaf-ncm--player-owner (etaf-ncm--client app)))
    (:toggle
     (when (etaf-ncm--playing-p app)
       (setq etaf-ncm--player-owner (etaf-ncm--client app))))
    (:stop
     (setq etaf-ncm--player-owner nil))))

(defun etaf-ncm--stop-owned-player ()
  "Stop the player this Emacs started and release it.
Runs synchronously because `kill-emacs' provides no event loop for an
asynchronous reply.  Return non-nil when an owned player was stopped."
  (when-let* ((owner etaf-ncm--player-owner))
    (setq etaf-ncm--player-owner nil)
    (etaf-ncm--stop-synchronously owner)
    t))

(defun etaf-ncm--stop-player-on-exit ()
  "Stop an owned player when Emacs exits, so mpv is never left behind."
  (ignore-errors (etaf-ncm--stop-owned-player)))

(defun etaf-ncm--command (app request message)
  "Send REQUEST for APP, showing MESSAGE and its local effect immediately.
The backend reply reconciles the optimistic state; only a command that can
move the queue reloads it."
  (etaf-ncm--optimistic-command-begin app
                                      (etaf-ncm--optimistic-status-keys request))
  (etaf-batch
    (etaf-ncm--note app message)
    (etaf-ncm--optimistic-command app request))
  (etaf-ncm--own-player-for app request)
  (etaf-ncm--call app request
                  :on-ok (lambda (_data)
                           (etaf-ncm--optimistic-command-settle app)
                           (etaf-batch
                             (etaf-ncm--request-status app)
                             (when (memq (plist-get request :op)
                                         etaf-ncm--queue-commands)
                               (etaf-ncm--request-queue app))))
                  :on-error (lambda (_message _hint _code)
                              (etaf-ncm--optimistic-command-settle app)
                              (etaf-ncm--request-status app))))

(defconst etaf-ncm--double-press-window 1.0
  "Seconds within which a second press on the same row counts as a double press.
The window is generous on purpose: publishing a selection can take a moment,
and the gesture must not depend on how long the previous press took.")

(defun etaf-ncm--press-row (app entry)
  "Select the row of ENTRY in APP, or play it when it was pressed twice.
ENTRY is a list entry as `etaf-ncm--view-entries' builds it.  A press on the
row that is already selected plays it: the gesture then does not depend on a
second press arriving inside a timing window, which a slow repaint can miss."
  (let* ((row (plist-get entry :row))
         (id (plist-get row :id))
         (now (float-time))
         (last (plist-get app :last-press))
         (selection (etaf-ncm--read app :selection))
         (index (max 0 (1- (or (plist-get entry :index) 1))))
         (delta (- index selection))
         (repeat-p (and last (equal (car last) id)
                        (< (- now (cdr last)) etaf-ncm--double-press-window))))
    (setf (plist-get app :last-press)
          (unless (or repeat-p (= index selection)) (cons id now)))
    (etaf-batch
      (if (or repeat-p (= index selection))
          (etaf-ncm-play app row)
        (progn
          (etaf-ncm-move-selection app delta)
          (etaf-ncm--note app (format "已选中：%s（再点一次播放）"
                                      (or (plist-get row :name) "这一行"))))))))

(defun etaf-ncm-press-row (app index)
  "Press library row INDEX (counting from 1) in APP.
Select the row, or play it when it is the selected row or was pressed twice in
quick succession; this is the gesture a click on a list row performs.  An
out-of-range INDEX signals `etaf-ncm-error'."
  (let ((row (nth (1- index) (etaf-ncm--read app :rows))))
    (unless row
      (signal 'etaf-ncm-error (list (format "没有第 %s 行" index))))
    (etaf-ncm--press-row app (list :row row :index index))))

(defun etaf-ncm-seek-to (app seconds)
  "Seek APP to the absolute position SECONDS.
The player bar's range component reports absolute positions, while the backend
seeks by offset: show the target immediately, then ask for the difference."
  (unless (numberp seconds)
    (signal 'etaf-ncm-error (list (format "进度目标必须是秒数：%S" seconds))))
  (let* ((current (etaf-ncm--clock app))
         (target (max 0 seconds))
         (last (plist-get app :seek-commit)))
    ;; A range press reports its commit once, but a duplicated pointer event
    ;; must not apply the same seek twice.
    (unless (and last (equal (car last) target)
                 (< (- (float-time) (cdr last)) 0.8))
      (plist-put app :seek-commit (cons target (float-time)))
      (etaf-ncm--set-clock app target)
      ;; Hold the exact pointed target: the relative command rounds to whole
      ;; seconds, which would leave the guard one second off it.
      (etaf-ncm--write app :seek-guard (cons (+ (float-time) 3.0) target))
      (etaf-ncm--command app (list :op :seek :seconds (round (- target current)))
                         (format "进度 %s%ss"
                                 (if (< target current) "-" "+")
                                 (abs (round (- target current))))))))

(defun etaf-ncm--target (app item)
  "Return the backend play target for ITEM inside APP."
  (cond
   ((null item) (or (etaf-ncm--read app :origin) '(:kind :daily)))
   ((listp item)
    (let ((kind (plist-get item :kind))
          (id (plist-get item :id)))
      (if (memq kind '(:song :playlist :album :artist :chart :podcast :episode))
          (list :kind kind :id id)
        (signal 'etaf-ncm-error (list (format "不能播放这一行：%S" item))))))
   ((numberp item) (list :kind :song :id item))
   ((and (stringp item) (not (string-empty-p (string-trim item))))
    (list :kind :query :id (string-trim item)))
   (t (signal 'etaf-ncm-error (list (format "不能播放：%S" item))))))

(defun etaf-ncm--target-label (app item)
  "Return a human label for ITEM in APP, used in the status line."
  (cond
   ((null item)
    (or (etaf-ncm--section-label (etaf-ncm--read app :section))
        (format "%s" (etaf-ncm--read app :origin))))
   ((listp item) (or (plist-get item :name) "选中项"))
   (t (format "%s" item))))

(defun etaf-ncm--item-id (item)
  "Return ITEM's song id when ITEM names a song."
  (when (and (listp item) (eq (plist-get item :kind) :song))
    (plist-get item :id)))

(defun etaf-ncm--item-name (item)
  "Return ITEM's display name."
  (cond ((listp item) (or (plist-get item :name) "这一项"))
        ((numberp item) (format "%s" item))
        (t (format "%s" item))))

;;; ---------------------------------------------------------------------------
;;; Login
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--login-phone (phone)
  "Return PHONE as a digits-only string, or signal `etaf-ncm-error'."
  (let ((text (string-trim (format "%s" (or phone "")))))
    (unless (string-match-p "\\`[0-9]\\{5,20\\}\\'" text)
      (signal 'etaf-ncm-error (list (format "手机号应是 5-20 位数字：%S" phone))))
    text))

(defun etaf-ncm--login-code (code)
  "Return CODE as a digits-only string, or signal `etaf-ncm-error'."
  (let ((text (string-trim (format "%s" (or code "")))))
    (unless (string-match-p "\\`[0-9]\\{3,8\\}\\'" text)
      (signal 'etaf-ncm-error (list (format "验证码应是 3-8 位数字：%S" code))))
    text))

(defun etaf-ncm--login-send (app phone done)
  "Ask the backend to text an SMS code to PHONE for APP.
DONE is called with (:ok) or (:error MESSAGE) after the visible state was
updated; the interactive flow uses it to ask for the code when it goes out."
  (let ((phone (etaf-ncm--login-phone phone)))
    (etaf-ncm--call
     app (list :op :login-sms :phone phone)
     :on-ok (lambda (_data)
              (etaf-ncm--note app (format "验证码已发到 %s：收到后输入验证码" phone))
              (when done (funcall done (list :ok))))
     :on-error (lambda (message _hint _code)
                 (when done (funcall done (list :error message)))))))

(defun etaf-ncm--login-finish (app phone code done)
  "Complete APP's sign-in with the SMS CODE sent to PHONE.
The backend stores the cookie and the account and libraries reload; DONE is
called with (:ok DATA) or (:error MESSAGE) at the end."
  (let ((phone (etaf-ncm--login-phone phone))
        (code (etaf-ncm--login-code code)))
    (etaf-ncm--note app "正在登录…（网易云要求安全验证时会弹出二维码，用手机 App 扫一下）")
    (etaf-ncm--call
     app (list :op :login-sms-code :phone phone :code code :timeout 240)
     :on-ok (lambda (data)
              (etaf-ncm--note app (format "登录成功：%s"
                                          (or (etaf-ncm--string (plist-get data :nick))
                                              phone)))
              (etaf-ncm-refresh app)
              (when done (funcall done (list :ok data))))
     :on-error (lambda (message _hint _code)
                 (when done (funcall done (list :error message)))))))

;;; ---------------------------------------------------------------------------
;;; Playback status, queue and lyric
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-refresh (app)
  "Reload APP's library, playback status, queue and account.
The library reload refreshes the list the view already shows, so the reader's
position is kept; a mounted player fits its layout and row budgets to its
viewport separately."
  (etaf-ncm--write app :error nil)
  (setf (plist-get app :polled-at) 0)
  (if (eq (etaf-ncm--read app :mode) 'search)
      (let* ((query (etaf-ncm--read app :query))
             (key (list :search query 'song)))
        (setf (plist-get app :list-key) key)
        (etaf-ncm--load app key
                        (list :op :search :keyword query :scope 'song
                              :resource :songs
                              :limit (max etaf-ncm-fetch-limit
                                          (* 3 (etaf-ncm--read app :page-size))))
                        (and (etaf-ncm--list-entry app key) t) t))
    (let* ((section (etaf-ncm--read app :section))
           (key (list :browse section)))
      (setf (plist-get app :list-key) key)
      (etaf-ncm--load app key (etaf-ncm--browse-request app section)
                      (and (etaf-ncm--list-entry app key) t) t)))
  (etaf-ncm--request-status app)
  (etaf-ncm--request-liked-ids app)
  (etaf-ncm--request-downloads app)
  (etaf-ncm--request-queue app)
  (etaf-ncm--request-account app))

(defun etaf-ncm--request-liked-ids (app)
  "Load APP's liked-song id table when it is missing or old.
The backend status carries no like field, so the table is what lets the
player show a filled heart for a song in the liked library."
  (when (or (not (plist-get app :liked-ids-loaded))
            (> (- (float-time) (or (plist-get app :liked-ids-at) 0))
               etaf-ncm-library-refresh-interval))
    (etaf-ncm--call
     app (list :op :liked-ids)
     :on-ok (lambda (data)
              (let ((table (make-hash-table :test 'eql)))
                (dolist (id (etaf-ncm--list (plist-get data :ids)))
                  (let ((number (etaf-ncm--parse-number id)))
                    (when number (puthash number t table))))
                (setf (plist-get app :liked-ids) table
                      (plist-get app :liked-ids-loaded) t
                      (plist-get app :liked-ids-at) (float-time))
                (etaf-ncm--reflect-liked app))))))

(defun etaf-ncm--request-downloads (app)
  "Load APP's local download registry.
The backend owns the registry (a successful `download' registers its file), so
this asks for the current truth instead of reading the state directory; a file
deleted outside the player simply stops being listed."
  (etaf-ncm--call
   app (list :op :downloads)
   :on-ok (lambda (data)
            (let ((table (make-hash-table :test 'eql)))
              (dolist (entry (etaf-ncm--list (plist-get data :downloads)))
                (let ((id (etaf-ncm--parse-number (plist-get entry :id))))
                  (when id (puthash id entry table))))
              (setf (plist-get app :downloads) table
                    (plist-get app :downloads-loaded) t
                    (plist-get app :downloads-at) (float-time))
              (etaf-ncm--refresh-slots app)))))

(defun etaf-ncm--decorate-row (app row)
  "Return a copy of ROW with APP's local-download facts folded in.
A registered and still-present file adds `:downloaded' (non-nil) and
`:download-level' (the file's quality); other rows are returned as copies
without those keys, so a headless caller can read the marker straight from
`etaf-ncm-state' items and still never touches the session's own plists."
  (when row
    (let ((copy (copy-sequence row)))
      (when (eq (plist-get copy :kind) :song)
        (let* ((id (plist-get copy :id))
               (entry (and id (gethash id (plist-get app :downloads)))))
          (plist-put copy :downloaded (and entry t))
          (plist-put copy :download-level (and entry (plist-get entry :level)))))
      copy)))

(defun etaf-ncm--reflect-liked (app)
  "Refresh APP's displayed like state from its liked-id table."
  (let* ((status (etaf-ncm--read app :status))
         (song-id (plist-get status :song-id)))
    (when (and status song-id)
      (let ((liked (and (gethash song-id (plist-get app :liked-ids)) t)))
        (unless (equal liked (etaf-ncm--flag-value app :liked))
          (etaf-ncm--write app :liked-ref liked))))))

(defun etaf-ncm--request-account (app)
  "Load APP's account display name."
  (etaf-ncm--call app (list :op :session)
                  :on-ok (lambda (data)
                           (etaf-ncm--write app :account
                                            (list :nick (etaf-ncm--string (plist-get data :nick))
                                                  :uid (etaf-ncm--parse-number (plist-get data :uid))
                                                  :vip (plist-get data :vip)
                                                  :logged-in (eq t (plist-get data :loggedIn)))))))

(defun etaf-ncm--request-status (app)
  "Ask the backend for APP's playback truth.
The reply carries the position measured when the backend answered, so the
round trip is added back before publishing it: without that the lyric line and
the progress bar run one backend latency behind the song."
  (setf (plist-get app :status-in-flight) t
        (plist-get app :requested-at) (float-time))
  (let ((requested-at (plist-get app :requested-at))
        ;; A request sent while a command was unsettled cannot show that
        ;; command's effect yet: carry the fields it published so this reply
        ;; cannot move them back, even when it arrives after the command
        ;; settled.  A request sent before the command is covered by
        ;; `:optimistic-at' below.
        (protected (and (> (or (plist-get app :commands-pending) 0) 0)
                        (copy-sequence (plist-get app :optimistic-keys)))))
    (etaf-ncm--call
     app (list :op :status)
     :on-ok (lambda (data)
              (let* ((now (float-time))
                     (trip (- now (or requested-at now)))
                     (status (etaf-ncm--normalize-status data))
                     (elapsed (or (plist-get status :elapsed) 0)))
                (setf (plist-get app :status-in-flight) nil
                      (plist-get app :polled-at) now
                      (plist-get app :last-tick) now)
                (etaf-ncm--apply-status
                 app (plist-put status :elapsed (+ elapsed trip))
                 requested-at protected)))
     :on-error (lambda (_message _hint _code)
                 (setf (plist-get app :status-in-flight) nil
                       (plist-get app :polled-at) (float-time))))))

(defun etaf-ncm--apply-status (app status &optional requested-at protected)
  "Publish STATUS and fetch the lyric when the song changed.
A reply that only moves the position is displayed through
`etaf-ncm--set-clock', so a playing second does not republish the view; a
reply that carries new playback facts publishes `:status'.  A reply that left
the backend before the user's last command keeps that command's display for
the fields it changed, so the bar does not jump back and forth.  REQUESTED-AT
is when the answered status request was sent, and PROTECTED the fields a
still-unsettled command published when that request was sent."
  (etaf-batch
  (let* ((previous (etaf-ncm--read app :status))
         (song-id (plist-get status :song-id))
         (lyric (etaf-ncm--read app :lyric))
         (stale-p (or protected
                      (and requested-at
                           (let ((optimistic-at (plist-get app :optimistic-at)))
                             (and optimistic-at (< requested-at optimistic-at))))))
         (protected (or protected (and stale-p (plist-get app :optimistic-keys))))
         (elapsed (or (plist-get status :elapsed) 0)))
    ;; A status reply older than the user's last command still describes the
    ;; old playback facts.  Keep the command's optimistic display for the
    ;; fields it changed until its own follow-up status confirms them.
    (when stale-p
      (dolist (key protected)
        (setq status (plist-put status key (plist-get previous key)))
        (when (eq key :elapsed)
          (setq elapsed (or (plist-get previous :elapsed) elapsed)))))
    ;; A seek that mpv has not applied yet must not drag the bar back: keep
    ;; showing the requested target until the backend reaches it or the guard
    ;; expires.
    (let ((guard (etaf-ncm--read app :seek-guard)))
      (when guard
        (let ((until (car guard)) (target (cdr guard)))
          (cond ((and (< (float-time) until)
                      (> (abs (- (or elapsed 0) target)) 0.6))
                 (setq elapsed target)
                 (setq status (plist-put status :elapsed target)))
                ((or (>= (float-time) until)
                     (<= (abs (- (or elapsed 0) target)) 0.6))
                 (etaf-ncm--write app :seek-guard nil))))))
    ;; The backend status carries no like state: the session's liked-id table
    ;; decides it once it arrived, and the same-song fallback covers the
    ;; window before that.
    (setq status (plist-put status :liked
                            (cond ((plist-get app :liked-ids-loaded)
                                   (and song-id
                                        (gethash song-id (plist-get app :liked-ids))
                                        t))
                                  (previous
                                   (and (equal song-id (plist-get previous :song-id))
                                        (plist-get previous :liked))))))
    (if (etaf-ncm--status-steady-p previous status)
        (progn
          ;; Only the volatile fields moved: update the retained flag Hosts and
          ;; the clock instead of republishing the whole view.
          (etaf-ncm--sync-flags app status protected)
          (etaf-ncm--set-clock app elapsed))
      (etaf-ncm--set-clock app elapsed)
      (etaf-ncm--sync-flags app status protected)
      (etaf-ncm--write app :status status))
    ;; A song change moves the list's play marker; the status stays the source
    ;; of truth, so publish the new id even when no list reply arrives.
    (etaf-ncm--sync-playing app)
    ;; Queue metadata often arrives before status, and its position can lag
    ;; playback.  Select the art again from playback truth without waiting for
    ;; another queue round trip (including the first status of a session).
    (when (and song-id (not (equal song-id (plist-get app :cover-requested-id))))
      (etaf-ncm--request-cover
       app (etaf-ncm--queue-current-song app (etaf-ncm--read app :queue))))
    (when (and song-id (not (equal song-id (plist-get lyric :id))))
      (etaf-ncm--request-lyric app song-id))
    (when (and previous
               (or (not (equal (plist-get status :queue-pos)
                               (plist-get previous :queue-pos)))
                   (and (plist-get previous :song-id) song-id
                        (not (equal song-id (plist-get previous :song-id))))))
      (etaf-ncm--request-queue app)))))

(defun etaf-ncm--status-flag (value)
  "Read a boolean or numeric status flag VALUE supplied by the backend."
  (or (eq value t) (and (numberp value) (> value 0))
      (and (stringp value) (member (downcase value) '("true" "1" "yes")))))

(defun etaf-ncm--status-quality (data)
  "Return DATA's supplied quality label, or nil when no hint was reported."
  (let ((quality (string-trim (etaf-ncm--string (plist-get data :quality))))
        (bitrate (plist-get data :bitrate))
        (hint (string-trim (etaf-ncm--string (plist-get data :vip_hint)))))
    (cond ((or (etaf-ncm--status-flag (plist-get data :lossless))
               (member (downcase quality) '("lossless" "flac" "无损"))) "无损")
          ((not (string-empty-p quality)) quality)
          ((and bitrate (not (string-empty-p (etaf-ncm--string bitrate))))
           (let ((number (etaf-ncm--parse-number bitrate)))
             (if number
                 (format "%g kbps" (if (> number 1000) (/ number 1000.0) number))
               (etaf-ncm--string bitrate))))
          ((not (string-empty-p hint)) hint)
          ((etaf-ncm--status-flag (plist-get data :vip)) "VIP"))))

(defun etaf-ncm--normalize-status (data)
  "Return the backend playback DATA as the player's status plist."
  (let* ((position (etaf-ncm--string (plist-get data :queue_pos)))
         (parts (split-string position "/" t)))
    (list :title (etaf-ncm--string (plist-get data :title))
          :artist (etaf-ncm--string (plist-get data :artist))
          :song-id (etaf-ncm--parse-number (plist-get data :song_id))
          :state (intern (or (etaf-ncm--string (plist-get data :state)) "idle"))
          :elapsed (or (etaf-ncm--parse-number (plist-get data :elapsed)) 0)
          :duration (or (etaf-ncm--parse-number (plist-get data :duration)) 0)
          :volume (or (etaf-ncm--parse-number (plist-get data :volume)) 0)
          :vip (and (etaf-ncm--status-flag (plist-get data :vip)) t)
          :quality (etaf-ncm--status-quality data)
          :queue-pos (or (etaf-ncm--parse-number (car parts)) 0)
          :queue-count (or (etaf-ncm--parse-number (cadr parts)) 0)
          :shuffle (etaf-ncm--truthy-string-p (plist-get data :shuffle))
          :repeat (etaf-ncm--truthy-string-p (plist-get data :repeat))
          ;; The source mpv plays: the meter decodes the same file or stream
          ;; so the page's spectrum follows the audio, not a canned loop.
          :source (etaf-ncm--string (plist-get data :path))
          :as-of (etaf-ncm--string (plist-get data :as_of)))))

(defun etaf-ncm--cover-file (id)
  "Return the local cover-art cache path for song ID."
  (expand-file-name (format "covers/%s" id) etaf-ncm-state-directory))

(defun etaf-ncm--request-cover (app song)
  "Load SONG's cover art for APP when the playing song changed.
The previous art stays on screen until the new one is ready, so a cover-to-
cover switch never flashes a differently sized placeholder.  A song without a
cover URL clears it immediately, and a failed download clears it only when it
still belongs to the song that asked for it.  A file already in the media
cache (or at the song's deterministic path) is published without a request."
  (let ((id (plist-get song :id)))
    (when (and id (not (equal id (plist-get app :cover-requested-id))))
      (setf (plist-get app :cover-requested-id) id)
      (let* ((url (plist-get song :cover))
             (file (and id (etaf-ncm--cover-file id)))
             (cache (plist-get app :media-cache))
             (cached (and (stringp url) (not (string-empty-p url))
                          (or (etaf-ncm-cache-cover cache id url)
                              ;; Adopt art downloaded before the index existed;
                              ;; an indexed entry with another URL must reload.
                              (and (null (etaf-ncm-cache-cover-record cache id))
                                   (file-readable-p file)
                                   (progn (etaf-ncm-cache-put-cover cache id url file)
                                          file))))))
        (cond
         (cached (etaf-ncm--write app :cover-file cached))
         ((and id (stringp url) (not (string-empty-p url)))
          (condition-case nil
              (make-directory (file-name-directory file) t)
            (error nil))
          (etaf-ncm--call
           app (list :op :cover :id id :file file)
           :on-ok (lambda (data)
                    (let ((saved (plist-get data :file)))
                      (when (and (stringp saved) (file-readable-p saved))
                        (etaf-ncm-cache-put-cover cache id url saved)
                        (when (equal id (plist-get app :cover-requested-id))
                          (etaf-ncm--write app :cover-file saved)))))
           :on-error (lambda (_message _hint _code)
                       (when (equal id (plist-get app :cover-requested-id))
                         (etaf-ncm--write app :cover-file nil)))))
         (t (etaf-ncm--write app :cover-file nil)))))))

(defun etaf-ncm--queue-current-song (app queue)
  "Return QUEUE's entry matching APP's playing song.
Use the queue position only before playback status identifies the song."
  (let* ((songs (plist-get queue :songs))
         (status-id (plist-get (etaf-ncm--read app :status) :song-id))
         (pos (plist-get queue :pos)))
    (or (and status-id
             (seq-find (lambda (entry) (equal (plist-get entry :id) status-id)) songs))
        (and (null status-id) (integerp pos) (> pos 0) (nth (1- pos) songs)))))

(defun etaf-ncm--request-queue (app)
  "Load APP's queue count, index and track list."
  (etaf-ncm--call
   app (list :op :queue :limit 200)
   :on-ok (lambda (data)
            (let ((previous (etaf-ncm--read app :queue))
                  (queue (list :count (or (etaf-ncm--parse-number
                                          (plist-get data :count)) 0)
                               :pos (or (etaf-ncm--parse-number
                                         (plist-get data :pos)) 0)
                               :songs (etaf-ncm--list (plist-get data :songs)))))
              (etaf-batch
                (unless (and (equal (plist-get previous :pos) (plist-get queue :pos))
                             (equal (plist-get previous :songs) (plist-get queue :songs)))
                  (etaf-ncm--write app :queue-start nil))
                (etaf-ncm--write app :queue queue))
              (etaf-ncm--request-cover app (etaf-ncm--queue-current-song app queue))))))

(defun etaf-ncm--request-lyric (app song-id)
  "Fetch the lyric of SONG-ID for APP, serving a persisted copy when possible.
Lyrics are immutable, so a SQLite hit publishes the parsed lines without a
backend request; a miss fetches and stores the text for the next session."
  (let ((cached (etaf-ncm-cache-lyric (plist-get app :media-cache) song-id)))
    (if cached
        (etaf-ncm--write app :lyric
                         (list :id song-id
                               :lines (etaf-ncm-parse-lyric (plist-get cached :lyric))
                               :trans (etaf-ncm-parse-lyric (plist-get cached :trans) t)
                               :loading nil))
      (etaf-ncm--write app :lyric (list :id song-id :lines nil :trans nil :loading t))
      (etaf-ncm--call
       app (list :op :lyric :id song-id)
       :on-ok (lambda (data)
                (let ((lyric (etaf-ncm--string (plist-get data :lyric)))
                      (trans (etaf-ncm--string (plist-get data :trans))))
                  ;; Cache the replied song even when the player moved on.
                  (etaf-ncm-cache-put-lyric (plist-get app :media-cache)
                                            song-id lyric trans)
                  (when (equal song-id (plist-get (etaf-ncm--read app :lyric) :id))
                    (etaf-ncm--write app :lyric
                                     (list :id song-id
                                           :lines (etaf-ncm-parse-lyric lyric)
                                           :trans (etaf-ncm-parse-lyric trans t)
                                           :loading nil)))))
       :on-error (lambda (_message _hint _code)
                   (when (equal song-id (plist-get (etaf-ncm--read app :lyric) :id))
                     (etaf-ncm--write app :lyric
                                      (list :id song-id :lines nil :trans nil :loading nil))))))))

(defun etaf-ncm--playing-p (app)
  "Return non-nil when APP currently plays audio.
The retained state source is the current reading, including an optimistic
toggle the backend has not confirmed yet."
  (eq (etaf-ncm--flag-value app :state) 'playing))

(defun etaf-ncm--tick (app)
  "Advance APP's local clock and poll the backend when due.
While a status request is on its way the clock is left alone: the reply is the
truth and writing a local guess first would repaint the whole view twice a
second for the same second."
  (unless (plist-get app :disposed)
    (let ((now (float-time))
          (last (or (plist-get app :last-tick) 0)))
      (setf (plist-get app :last-tick) now)
      (when (and (etaf-ncm--playing-p app)
                 (not (etaf-ncm--poll-due-p app now)))
        (let* ((elapsed (+ (etaf-ncm--clock app) (- now last)))
               (duration (or (plist-get (etaf-ncm--read app :status) :duration) 0)))
          (etaf-ncm--set-clock
           app (if (> duration 0) (min elapsed duration) elapsed))))
      (when (etaf-ncm--poll-due-p app now)
        (etaf-ncm--request-status app))
      (etaf-ncm--refresh-background-list app now))))

(defun etaf-ncm--poll-due-p (app now)
  "Return non-nil when APP should ask the backend for status at NOW."
  (and (not (plist-get app :status-in-flight))
       (or (etaf-ncm--playing-p app)
           (> (- now (or (plist-get app :polled-at) 0))
              etaf-ncm-idle-poll-interval))))

(defun etaf-ncm--start (app)
  "Start APP's playback polling; remounting a disposed session revives it."
  (setf (plist-get app :disposed) nil
        (plist-get app :polled-at) 0
        (plist-get app :last-tick) (float-time))
  (etaf-list-cache-start (plist-get app :list-cache))
  (unless (plist-get app :timer)
    (setf (plist-get app :timer)
          (run-with-timer etaf-ncm-status-interval etaf-ncm-status-interval
                          (lambda () (etaf-ncm--tick app))))))

(defun etaf-ncm--dispose (app)
  "Release APP's timer and in-flight requests."
  (setf (plist-get app :disposed) t)
  (clrhash (plist-get app :list-in-flight))
  (when (plist-get app :cache-save-timer) (etaf-ncm--save-cache app))
  (etaf-list-cache-disarm (plist-get app :list-cache))
  (when-let* ((timer (plist-get app :timer)))
    (cancel-timer timer)
    (setf (plist-get app :timer) nil))
  (etaf-ncm-cancel (etaf-ncm--client app)))

;;; ---------------------------------------------------------------------------
;;; Keyboard navigation and panels
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--display-metrics (&optional buffer)
  "Return the cell Ebox paints with in BUFFER, as a metrics plist.
BUFFER defaults to the current one.  One source for every budget, cover grid
and backdrop build: `etaf-display-metrics' measures the box the renderer
actually draws into, while the frame's own face is a different cell whenever
the canvas font, a text scale or the selected frame differs from it.  `ch' and
`lh' lengths resolve against the canvas, so a budget turned from pixels with
the frame's face draws a page narrower than the region it measured and leaves
the right side empty."
  (let* ((buffer (or buffer (current-buffer)))
         (runtime (and (buffer-live-p buffer)
                       (etaf-runtime-for-buffer buffer)))
         (metrics (and runtime (ignore-errors (etaf-display-metrics runtime)))))
    (or metrics
        (list :char-width (frame-char-width) :line-height (frame-char-height)))))

(defun etaf-ncm--viewport-columns (pixels &optional app)
  "Return the library column budget for a region PIXELS wide on APP's canvas.
The canvas's own cell width turns the region's pixel width into text columns,
so the budget and the boxes drawn from it agree.  APP supplies that canvas;
without it the selected frame's face stands in."
  (let ((char-width (or (plist-get (etaf-ncm--display-metrics
                                    (and app (plist-get app :buffer)))
                                   :char-width)
                        (frame-char-width))))
    (max 1 (floor pixels (max 1 char-width)))))

(defun etaf-ncm--layout-for (columns &optional window-rows)
  "Return the layout COLUMNS by WINDOW-ROWS of text can hold.
The result is `wide', `medium', `narrow', `card' or `tile'; the breakpoints
live in `etaf-ncm-layout'."
  (etaf-ncm-layout-for columns window-rows))

(defun etaf-ncm--sync-viewport (app viewport)
  "Match APP's layout and row budgets to VIEWPORT.
VIEWPORT is the `(PIXELS . ROWS)' region the player is mounted into (see
`etaf-viewport'): the buffer window when it stands alone, or the host window,
pane or tab that embeds it.  One region drives every budget, so an embedded
and a standalone player lay out by the same rule."
  (let* ((columns (etaf-ncm--viewport-columns (car viewport) app))
         ;; The panels own their one clear line at the top and the player bar
         ;; owns the one under it, so the region's rows are the row budget.
         (height (max 1 (cdr viewport)))
         (layout (etaf-ncm--layout-for columns height))
         (widget (etaf-ncm-layout-widget-p layout))
         ;; A card opens on what it is read for.  Entering the card family
         ;; from a larger layout brings the lyric pane to the front; moving
         ;; between card sizes leaves the chosen pane alone.
         (entering (and widget
                        (not (etaf-ncm-layout-widget-p (etaf-ncm--read app :layout)))))
         ;; A card shows one pane in its content area and nothing else, so the
         ;; library page and the lyric pool share one row budget.
         (size (etaf-ncm-layout-content-rows layout height)))
    (etaf-batch
      ;; A card draws no text field, and its point can sit on a stale buffer
      ;; position after a resize; the native cursor would then paint a stray
      ;; bar over the canvas.  The larger tiers keep it for the search field.
      (when-let* ((buffer (plist-get app :buffer))
                  ((buffer-live-p buffer)))
        (with-current-buffer buffer
          (setq-local cursor-type (unless widget (default-value 'cursor-type)))))
      (when (eq layout 'wide)
        (etaf-ncm--write app :pane 'list))
      (when entering
        (etaf-ncm--write app :pane 'aside))
      (etaf-ncm--write app :columns columns)
      (etaf-ncm--write app :window-rows height)
      (etaf-ncm--write app :layout layout)
      (etaf-ncm--write app :page-size size)
      (etaf-ncm--refresh-slots app)
      (etaf-ncm--write app :queue-rows
                       (if widget size
                         (etaf-ncm-layout-queue-rows layout height)))
      ;; The lyric cover, spacer and footer take seven more lines than the
      ;; queue heading.  Translations share this budget with lyric lines.
      (etaf-ncm--write app :lyric-rows
                       (if widget size
                         (etaf-ncm-layout-lyric-rows layout height))))
    layout))

(defun etaf-ncm--compact-layout-p (app)
  "Return non-nil when APP shows one pane at a time."
  (not (eq (etaf-ncm--read app :layout) 'wide)))

(defun etaf-ncm--list-shown-p (app)
  "Return non-nil when APP's library list fits in the frame."
  (or (not (etaf-ncm--compact-layout-p app))
      (eq (etaf-ncm--read app :pane) 'list)))

(defun etaf-ncm--aside-shown-p (app)
  "Return non-nil when APP's lyrics and queue panel fits in the frame."
  (or (not (etaf-ncm--compact-layout-p app))
      (eq (etaf-ncm--read app :pane) 'aside)))

(defun etaf-ncm--render-rows (app)
  "Return how many of APP's loaded rows its scrolling canvas holds."
  (min (length (etaf-ncm--read app :rows))
       (max 1 etaf-ncm-render-limit)))

(defun etaf-ncm--page-rows (app)
  "Return the rendered rows of APP as (ROWS 0 TOTAL)."
  (let* ((rows (etaf-ncm--read app :rows))
         (total (length rows))
         (size (etaf-ncm--render-rows app)))
    (list (seq-take rows size) 0 total)))

(defun etaf-ncm--ensure-row-slots (app size)
  "Grow APP's retained row slots so at least SIZE rows have one."
  (let ((slots (plist-get app :row-slots)))
    (when (> size (length slots))
      (let* ((playing-id (plist-get app :playing-id))
             (extra (cl-loop for index from (length slots) below size
                             collect (etaf-ref nil :name
                                               (intern (format "etaf-ncm-row-%d" index))))))
        (setq slots (vconcat slots extra))
        (plist-put app :row-slots slots)
        (plist-put app :row-playing
                   (vconcat (plist-get app :row-playing)
                            (cl-loop for slot across (vconcat extra)
                                     ;; Each computed must watch its own slot:
                                     ;; `cl-loop' rebinds one variable, so a
                                     ;; closure over SLOT directly would make
                                     ;; every row read the last one.
                                     collect (let ((watched slot))
                                               (etaf-computed
                                                (lambda ()
                                                  (let ((row (etaf-value watched))
                                                        (played (etaf-value playing-id)))
                                                    (and row played
                                                         (equal (plist-get row :id) played)))))))))))))

(defun etaf-ncm--sync-playing (app)
  "Publish APP's playing song id to the row markers.
The list's `:row-playing' sources compare their row against this id, so a song
change must reach it even when no list reply follows."
  (let ((song-id (plist-get (etaf-ncm--read app :status) :song-id)))
    (unless (equal (etaf-value (plist-get app :playing-id)) song-id)
      (etaf-set-value (plist-get app :playing-id) song-id))))

(defun etaf-ncm--refresh-slots (app)
  "Publish APP's rendered rows through its retained slot sources.
The canvas scrolls natively, so every slot holds the row at its own index and
a cleared slot keeps its identity, which lets a reply update prepared text
without rebuilding the list."
  (pcase-let* ((`(,rows ,start ,_loaded) (etaf-ncm--page-rows app))
               (size (max 1 (length rows))))
    (etaf-ncm--ensure-row-slots app size)
    (let ((slots (plist-get app :row-slots)))
      (dotimes (index (length slots))
        (let ((value (etaf-ncm--decorate-row
                      app (and (< index (length rows)) (nth index rows)))))
          (when value (setq value (plist-put value :display-index (1+ (+ start index)))))
          (unless (equal (etaf-value (aref slots index)) value)
            (etaf-set-value (aref slots index) value)))))
    (etaf-ncm--sync-playing app)
    (let* ((loaded (length (etaf-ncm--read app :rows)))
           (total (etaf-ncm--read app :list-total))
           (page-label (format "共 %s 首" total))
           (loaded-label (format "已加载 %s / 共 %s 首" loaded total))
           (empty-note (if (etaf-ncm--read app :loading)
                           "正在加载…"
                         "这里还没有内容：g 刷新，s 搜索"))
           (visible-count (length rows))
           (footer-visible (and (or rows (> total 0)) t))
           (more-visible (< loaded total))
           (selected-album (or (plist-get (etaf-ncm--selected-row app) :meta) "")))
      (dolist (pair (list (cons :page-label page-label)
                          (cons :loaded-label loaded-label)
                          (cons :empty-note empty-note)
                          (cons :visible-count visible-count)
                          (cons :footer-visible footer-visible)
                          (cons :playable (and (etaf-ncm--playable-origin app) t))
                          (cons :more-visible more-visible)
                          (cons :selected-album selected-album)))
        (let ((ref (plist-get app (car pair))))
          (unless (equal (etaf-value ref) (cdr pair))
            (etaf-set-value ref (cdr pair))))))))

(defun etaf-ncm--queue-window-start (app)
  "Return the clamped start of APP's loaded queue window, counting from zero.
A nil scroll position centres the window on the playing entry."
  (let* ((queue (etaf-ncm--read app :queue))
         (size (etaf-ncm--read app :queue-rows))
         (total (length (plist-get queue :songs)))
         (start (or (etaf-ncm--read app :queue-start)
                    (- (max 0 (1- (or (plist-get queue :pos) 0))) (/ size 2)))))
    (max 0 (min start (max 0 (- total size))))))

(defun etaf-ncm--scroll-queue (app delta)
  "Move APP's loaded queue window by DELTA rows without changing playback."
  (let* ((total (length (plist-get (etaf-ncm--read app :queue) :songs)))
         (size (etaf-ncm--read app :queue-rows)))
    (etaf-ncm--write app :queue-start
                     (max 0 (min (+ (etaf-ncm--queue-window-start app) delta)
                                 (max 0 (- total size)))))))

(defun etaf-ncm-move-selection (app delta)
  "Move APP's list selection by DELTA rows and keep it inside the list."
  (let* ((rows (etaf-ncm--read app :rows))
         (total (length rows)))
    (when (> total 0)
      (etaf-ncm--write app :selection
                       (max 0 (min (1- total)
                                   (+ (etaf-ncm--read app :selection) delta)))))))

(defun etaf-ncm--selected-row (app)
  "Return the row APP's selection points at, or nil."
  (nth (etaf-ncm--read app :selection) (etaf-ncm--read app :rows)))

(defun etaf-ncm-activate-selection (app)
  "Play the row selected in APP."
  (when-let* ((row (etaf-ncm--selected-row app)))
    (etaf-ncm-play app row)))

(defun etaf-ncm-toggle-aside (app)
  "Switch APP's side panel between lyrics and the queue and show it.
In a compact layout, where only one pane fits, this also brings the panel to
the front; `etaf-ncm-show-pane' returns to the library list."
  (etaf-ncm--write app :aside (if (eq (etaf-ncm--read app :aside) 'lyrics) 'queue 'lyrics))
  (unless (eq (etaf-ncm--read app :layout) 'wide)
    (etaf-ncm--write app :pane 'aside)))

(defun etaf-ncm-show-pane (app pane)
  "Show PANE in APP.
PANE is `list' for the library list or `aside' for the lyric and queue panel.
A wide layout shows every column at once, so there PANE is remembered but does
not remove anything from the frame."
  (unless (memq pane '(list aside))
    (signal 'etaf-ncm-error (list (format "Unknown pane: %S" pane))))
  (etaf-ncm--write app :pane pane)
  pane)

(defun etaf-ncm--lyric-index (lines elapsed)
  "Return the index in LINES that ELAPSED seconds falls into."
  (let ((index 0)
        (position 0))
    (while (and (< position (length lines))
                (<= (car (nth position lines)) elapsed))
      (setq index position
            position (1+ position)))
    index))

;;; ---------------------------------------------------------------------------
;;; Detached state for callers and tests
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-state (app)
  "Return APP's session state as a detached plist.
The snapshot is a copy: mutating it never changes the player.  Keys are
`:section', `:title', `:subtitle', `:mode', `:query', `:items' (the library
rows), `:visible' (the rows the scrolling canvas holds), `:selection',
`:page-size' (row budget, not a painted page), `:rows-total' (loaded count),
`:list-total' (backend total or the loaded count), `:queue-rows',
`:queue-start' (zero-based loaded window start),
`:lyric-rows' (display lines including translations), `:status', `:queue',
`:lyric', `:lyric-line', `:aside',
`:layout', `:pane', `:screen' (`library' or the full-page `now'),
`:now-mode' (`immersive' or `split'),
`:viewport-width' (the pixel canvas the player paints),
`:theme', `:account', `:downloads' (the local download registry; song rows in
`:items' and `:visible' carry `:downloaded'/`:download-level' when the file is
present), `:loading', `:error' and `:message'."
  (let* ((rows (etaf-ncm--read app :rows))
         (page (etaf-ncm--page-rows app))
         (status (let ((status (plist-put
                                (copy-sequence (or (etaf-ncm--read app :status) nil))
                                :elapsed (etaf-ncm--clock app))))
                   ;; Display flags live in their own retained sources; the
                   ;; snapshot reports the current reading, not the ref shape.
                   (dolist (pair etaf-ncm--flag-slots)
                     (setq status (plist-put status (car pair)
                                             (etaf-ncm--flag-value app (car pair)))))
                   status))
         (lyric (etaf-ncm--read app :lyric))
         (lines (plist-get lyric :lines))
         (index (and lines (etaf-ncm--lyric-index lines (etaf-ncm--clock app)))))
    (list :section (etaf-ncm--read app :section)
          :title (etaf-ncm--read app :title)
          :subtitle (etaf-ncm--read app :subtitle)
          :mode (etaf-ncm--read app :mode)
          :query (etaf-ncm--read app :query)
          :items (mapcar (lambda (row) (etaf-ncm--decorate-row app row)) rows)
          :visible (mapcar (lambda (row) (etaf-ncm--decorate-row app row)) (nth 0 page))
          :selection (etaf-ncm--read app :selection)
          :page-size (etaf-ncm--read app :page-size)
          :viewport-width
          (let ((runtime (and (buffer-live-p (plist-get app :buffer))
                              (etaf-runtime-for-buffer (plist-get app :buffer)))))
            (and runtime (etaf-runtime-mounted-p runtime)
                 (car (etaf-runtime-viewport runtime))))
          :rows-total (length rows)
          :list-total (etaf-ncm--read app :list-total)
          :queue-rows (etaf-ncm--read app :queue-rows)
          :queue-start (etaf-ncm--queue-window-start app)
          :lyric-rows (etaf-ncm--read app :lyric-rows)
          :status (and status (copy-sequence status))
          :queue (let ((queue (etaf-ncm--read app :queue)))
                   (when queue
                     (list :count (plist-get queue :count)
                           :pos (plist-get queue :pos)
                           :current (nth (max 0 (1- (or (plist-get queue :pos) 0)))
                                         (etaf-ncm--list (plist-get queue :songs)))
                           :songs (mapcar #'copy-sequence
                                          (etaf-ncm--list (plist-get queue :songs))))))
          :lyric (and lyric
                      (list :id (plist-get lyric :id)
                            :lines (length lines)
                            :index (and index (1+ index))
                            :line (and lines index (cdr (nth index lines)))
                            :loading (plist-get lyric :loading)))
          :lyric-line (and lines index (cdr (nth index lines)))
          :aside (etaf-ncm--read app :aside)
          :layout (etaf-ncm--read app :layout)
          :pane (etaf-ncm--read app :pane)
          :screen (etaf-ncm--read app :screen)
          :now-mode (etaf-ncm--read app :now-mode)
          :theme (etaf-ncm--read app :theme)
          :account (let ((account (etaf-ncm--read app :account)))
                     (and account (copy-sequence account)))
          :downloads (let (entries)
                       (maphash (lambda (_id entry)
                                  (push (copy-sequence entry) entries))
                                (plist-get app :downloads))
                       (nreverse entries))
          :loading (etaf-ncm--read app :loading)
          :error (etaf-ncm--read app :error)
          :message (etaf-ncm--read app :message))))

(provide 'etaf-ncm-model)
;;; etaf-ncm-model.el ends here
