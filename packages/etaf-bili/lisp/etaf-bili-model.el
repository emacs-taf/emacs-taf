;;; etaf-bili-model.el --- Library, watch-page state and async actions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The session owns the gallery library, active watch-page state, playback
;; preferences, request generations, cover scheduling state and toast feedback.
;; All state transitions are headless-testable without a buffer or window.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-bili-theme)
(require 'etaf-bili-service)
(require 'etaf-bili-store)

(defconst etaf-bili--play-cache-ttl 1800
  "Seconds a resolved Bilibili stream URL stays reusable in session cache.")

(defconst etaf-bili--speeds '(0.5 0.75 1 1.25 1.5 2)
  "Playback speed steps available in Watch View.")

(cl-defstruct (etaf-bili--session (:constructor etaf-bili--session--make))
  "Library, watch-page state and application-owned resources."
  client buffer mode keyword items selected status loading request playback
  ;; Gallery reactive refs
  mode-ref status-ref items-ref selected-ref loading-ref playback-ref
  theme-ref layout-ref query-ref error-ref play-loading-ref
  details-ref visible-row-ref toast-ref
  ;; View routing & navigation filters
  view-mode-ref ranking-rid-ref search-order-ref
  space-mid space-name
  fav-folders-ref fav-folder-id-ref
  ;; Pagination state
  (page 1) (has-more t) loading-more-ref dynamic-offset history-max history-view-at
  ;; Lifecycle & async tokens
  disposed (play-request 0) (watch-aux-request 0) on-change on-watch-change
  ;; Account & per-session QR login state
  account-ref account-mid account-vip account-menu-ref login-ref login-timer
  ;; Stream cache: (bvid . cid) -> (:source PLIST :at TIME)
  play-bvid play-source (play-cache (make-hash-table :test #'equal))
  ;; Watch View state
  watch-handle watch-source-ref watch-tab-ref watch-theater-ref
  watch-fullscreen-ref
  watch-drawer-ref watch-quality-menu-ref watch-quality-cursor-ref
  watch-audio-only-ref
  watch-playing-ref watch-buffering-ref watch-play-error-ref
  watch-audio-ref watch-volume-ref watch-speed-ref
  watch-auto-next-ref watch-loop-ref
  watch-subtitles-list-ref watch-subtitle-index-ref
  watch-subtitle-cues watch-subtitle-cues-ref watch-subtitle-filter-ref
  watch-danmaku-enabled-ref watch-danmaku-list-ref
  watch-dm-area-ref watch-dm-opacity-ref watch-dm-size-ref watch-dm-density-ref
  watch-dm-scroll-ref watch-dm-top-ref watch-dm-bottom-ref
  watch-dm-ass-file watch-dm-loaded-ass
  watch-chapters-ref watch-comments-ref watch-related-ref
  watch-liked-ref watch-coined-ref watch-faved-ref watch-toviewed-ref
  (watch-position 0.0) (watch-duration 0.0)
  (watch-backup-index 0) watch-ended-seen
  watch-progress-ref (watch-time-text "00:00") (watch-duration-text "00:00")
  (watch-subtitle-text "") (watch-danmaku-text "") (watch-status-text "")
  ;; Background audio-only process & PiP state
  audio-bg-process (audio-bg-base 0.0) (audio-bg-stamp 0.0)
  pip-active-ref pip-handle
  pip-src-ref pip-buffering-ref pip-error-ref (pip-backup-index 0) pip-refresh-tried
  pip-size-ref pip-corner-ref pip-playing-ref pip-cc-ref pip-dm-ref
  pip-progress-ref (pip-time-text "00:00") (pip-duration-text "00:00")
  (pip-subtitle-text "") pip-dm-loaded-ass
  ;; Retained Host timers & debounce
  watch-timer resize-timer toast-timer heartbeat-at
  ;; Cover cache & active transfer tracking: (job . (entry . temp-file))
  (covers (make-hash-table :test #'equal)) cover-queue (cover-active 0)
  cover-jobs jobs)

(defun etaf-bili--pref-sym (key default allowed)
  "Read symbol preference KEY from store, validating against ALLOWED."
  (let* ((raw (etaf-bili-store-pref-get key nil))
         (sym (cond ((symbolp raw) raw)
                    ((stringp raw) (intern raw))
                    (t nil))))
    (if (memq sym allowed) sym default)))

(cl-defun etaf-bili-session-create (&key client)
  "Create a headless session with CLIENT, or `etaf-bili-client-factory'.
Nil factory selects the default curl client.  Creation sends no requests."
  (let ((pref-audio (etaf-bili-store-pref-get "audio" t))
        (pref-vol (or (etaf-bili-store-pref-get "volume" 100) 100))
        (pref-speed (or (etaf-bili-store-pref-get "speed" 1) 1))
        (pref-danmaku (etaf-bili-store-pref-get "danmaku" t))
        (pref-dm-area (etaf-bili--pref-sym "dm-area" 'half '(quarter half full)))
        (pref-dm-opacity (or (etaf-bili-store-pref-get "dm-opacity" 80) 80))
        (pref-dm-size (etaf-bili--pref-sym "dm-size" 'medium '(small medium large)))
        (pref-dm-density (etaf-bili--pref-sym "dm-density" 'medium '(low medium high)))
        (pref-dm-scroll (etaf-bili-store-pref-get "dm-scroll" t))
        (pref-dm-top (etaf-bili-store-pref-get "dm-top" t))
        (pref-dm-bottom (etaf-bili-store-pref-get "dm-bottom" nil))
        (pref-pip-size (etaf-bili--pref-sym "pip-size" 'medium '(small medium large)))
        (pref-pip-corner (etaf-bili--pref-sym "pip-corner" 'bottom-right
                                              '(bottom-right bottom-left top-left top-right)))
        (pref-auto-next (etaf-bili-store-pref-get "auto-next" t)))
    (etaf-bili--session--make
     :client (or client (if etaf-bili-client-factory
                            (funcall etaf-bili-client-factory)
                          (etaf-bili-make-client)))
     :mode 'popular :selected 0 :status "就绪" :request 0
     :mode-ref (etaf-ref 'popular) :status-ref (etaf-ref "就绪")
     :items-ref (etaf-ref nil) :selected-ref (etaf-ref 0)
     :loading-ref (etaf-ref nil) :playback-ref (etaf-ref nil)
     :theme-ref (etaf-ref (etaf-bili-theme-defaults))
     :layout-ref (etaf-ref nil :test #'equal) :query-ref (etaf-ref "")
     :error-ref (etaf-ref nil) :play-loading-ref (etaf-ref nil)
     :details-ref (etaf-ref nil) :visible-row-ref (etaf-ref 0)
     :toast-ref (etaf-ref nil)
     :view-mode-ref (etaf-ref 'gallery)
     :ranking-rid-ref (etaf-ref 0)
     :search-order-ref (etaf-ref "totalrank")
     :fav-folders-ref (etaf-ref nil)
     :fav-folder-id-ref (etaf-ref nil)
     :loading-more-ref (etaf-ref nil)
     :account-ref (etaf-ref nil) :account-menu-ref (etaf-ref nil)
     :login-ref (etaf-ref nil)
     :watch-handle (make-symbol "etaf-bili-watch-video")
     :watch-source-ref (etaf-ref nil)
     :watch-tab-ref (etaf-ref 'parts)
     :watch-theater-ref (etaf-ref nil)
     :watch-fullscreen-ref (etaf-ref nil)
     :watch-drawer-ref (etaf-ref nil)
     :watch-quality-menu-ref (etaf-ref nil)
     :watch-quality-cursor-ref (etaf-ref 0)
     :watch-audio-only-ref (etaf-ref nil)
     :watch-playing-ref (etaf-ref nil)
     :watch-buffering-ref (etaf-ref nil)
     :watch-play-error-ref (etaf-ref nil)
     :watch-audio-ref (etaf-ref (and pref-audio t))
     :watch-volume-ref (etaf-ref (max 0 (min 100 (round pref-vol))))
     :watch-speed-ref (etaf-ref pref-speed)
     :watch-auto-next-ref (etaf-ref (and pref-auto-next t))
     :watch-loop-ref (etaf-ref 'off)
     :watch-subtitles-list-ref (etaf-ref nil)
     :watch-subtitle-index-ref (etaf-ref nil)
     :watch-subtitle-cues-ref (etaf-ref nil)
     :watch-subtitle-filter-ref (etaf-ref "")
     :watch-danmaku-enabled-ref (etaf-ref (and pref-danmaku t))
     :watch-danmaku-list-ref (etaf-ref nil)
     :watch-dm-area-ref (etaf-ref pref-dm-area)
     :watch-dm-opacity-ref (etaf-ref (max 10 (min 100 (round pref-dm-opacity))))
     :watch-dm-size-ref (etaf-ref pref-dm-size)
     :watch-dm-density-ref (etaf-ref pref-dm-density)
     :watch-dm-scroll-ref (etaf-ref (and pref-dm-scroll t))
     :watch-dm-top-ref (etaf-ref (and pref-dm-top t))
     :watch-dm-bottom-ref (etaf-ref (and pref-dm-bottom t))
     :watch-chapters-ref (etaf-ref nil)
     :watch-comments-ref (etaf-ref nil)
     :watch-related-ref (etaf-ref nil)
     :watch-liked-ref (etaf-ref nil)
     :watch-coined-ref (etaf-ref nil)
     :watch-faved-ref (etaf-ref nil)
     :watch-toviewed-ref (etaf-ref nil)
     :watch-progress-ref (etaf-ref 0.0)
     :pip-active-ref (etaf-ref nil)
     :pip-src-ref (etaf-ref nil)
     :pip-buffering-ref (etaf-ref nil)
     :pip-error-ref (etaf-ref nil)
     :pip-size-ref (etaf-ref pref-pip-size)
     :pip-corner-ref (etaf-ref pref-pip-corner)
     :pip-playing-ref (etaf-ref nil)
     :pip-cc-ref (etaf-ref nil)
     :pip-dm-ref (etaf-ref nil)
     :pip-progress-ref (etaf-ref 0.0))))

(defun etaf-bili--status (session text)
  "Set SESSION's displayed status to TEXT."
  (setf (etaf-bili--session-status session) text)
  (etaf-set-value (etaf-bili--session-status-ref session) text))

(defun etaf-bili--toast (session message &optional kind action-label action-fn)
  "Show a non-destructive toast in SESSION without replacing the gallery."
  (when-let* ((old (etaf-bili--session-toast-timer session)))
    (cancel-timer old)
    (setf (etaf-bili--session-toast-timer session) nil))
  (etaf-set-value (etaf-bili--session-toast-ref session)
                  (list :kind (or kind 'info)
                        :message message
                        :action-label action-label
                        :action-fn action-fn))
  (setf (etaf-bili--session-toast-timer session)
        (run-at-time 5 nil
                     (lambda ()
                       (unless (etaf-bili--session-disposed session)
                         (etaf-set-value (etaf-bili--session-toast-ref session) nil)))))
  nil)

(defun etaf-bili--toast-clear (session)
  "Dismiss SESSION's active toast immediately."
  (when-let* ((old (etaf-bili--session-toast-timer session)))
    (cancel-timer old)
    (setf (etaf-bili--session-toast-timer session) nil))
  (etaf-set-value (etaf-bili--session-toast-ref session) nil))

(defun etaf-bili--invalidate-play-cache (session)
  "Clear cached stream URLs in SESSION (e.g. after login or logout)."
  (setf (etaf-bili--session-play-bvid session) nil
        (etaf-bili--session-play-source session) nil)
  (clrhash (etaf-bili--session-play-cache session))
  (etaf-bili--client-reset (etaf-bili--session-client session)))

(defun etaf-bili--notify (session &optional reset)
  "Notify SESSION's application; RESET requests the new library's beginning."
  (when (etaf-bili--session-on-change session)
    (funcall (etaf-bili--session-on-change session) reset)))

(defun etaf-bili--dedup-rows (rows)
  "Deduplicate video ROWS by `:bvid', preserving order."
  (cl-delete-duplicates (copy-sequence rows)
                        :key (lambda (row) (plist-get row :bvid))
                        :test #'equal :from-end t))

(defun etaf-bili--request (session request label &optional append)
  "Load or APPEND SESSION's library with REQUEST, rejecting stale responses."
  (unless (etaf-bili--session-disposed session)
    (let ((token (if append
                     (etaf-bili--session-request session)
                   (cl-incf (etaf-bili--session-request session)))))
      (unless append
        (cl-incf (etaf-bili--session-play-request session))
        (setf (etaf-bili--session-loading session) t
              (etaf-bili--session-page session) (or (plist-get request :page) 1)
              (etaf-bili--session-has-more session) t))
      (etaf-batch
        (if append
            (etaf-set-value (etaf-bili--session-loading-more-ref session) t)
          (etaf-set-value (etaf-bili--session-loading-ref session) t)
          (etaf-set-value (etaf-bili--session-error-ref session) nil)
          (etaf-set-value (etaf-bili--session-play-loading-ref session) nil))
        (etaf-bili--status session (format "%s · 加载中…" label)))
      (etaf-bili-client-call
       (etaf-bili--session-client session) request
       (lambda (reply)
         (when (and (not (etaf-bili--session-disposed session))
                    (= token (etaf-bili--session-request session)))
           (unless append
             (setf (etaf-bili--session-loading session) nil))
           (etaf-batch
             (if append
                 (etaf-set-value (etaf-bili--session-loading-more-ref session) nil)
               (etaf-set-value (etaf-bili--session-loading-ref session) nil))
             (if (plist-member reply :ok)
                 (let* ((incoming (plist-get reply :ok))
                        (merged (if append
                                    (etaf-bili--dedup-rows
                                     (append (etaf-bili--session-items session) incoming))
                                  (etaf-bili--dedup-rows incoming))))
                   (when (plist-member reply :offset)
                     (setf (etaf-bili--session-dynamic-offset session)
                           (plist-get reply :offset)))
                   (when (plist-member reply :max)
                     (setf (etaf-bili--session-history-max session)
                           (plist-get reply :max)
                           (etaf-bili--session-history-view-at session)
                           (plist-get reply :view-at)))
                   (when (or (null incoming)
                             (and append (= (length merged)
                                            (length (etaf-bili--session-items session)))))
                     (setf (etaf-bili--session-has-more session) nil))
                   (setf (etaf-bili--session-items session) merged)
                   (unless append
                     (setf (etaf-bili--session-selected session) 0))
                   (etaf-bili--notify session (not append))
                   (etaf-set-value (etaf-bili--session-items-ref session) merged)
                   (unless append
                     (etaf-set-value (etaf-bili--session-selected-ref session) 0))
                   (etaf-bili--status session (format "%s · %d 条" label (length merged))))
               (let ((error (or (plist-get reply :error) "请求失败，请重试")))
                 (if append
                     (etaf-bili--toast session (format "加载更多失败：%s" error) 'error)
                   (etaf-set-value (etaf-bili--session-error-ref session) error))
                 (etaf-bili--status session (format "%s · %s" label error)))))))))))

;;; Channel loaders & pagination

(defun etaf-bili--mode-label (session)
  "Return the human label of SESSION's active gallery mode."
  (pcase (etaf-bili--session-mode session)
    ('rcmd "个性推荐")
    ('popular "热门")
    ('ranking
     (let* ((rid (etaf-value (etaf-bili--session-ranking-rid-ref session)))
            (name (or (cdr (assq rid etaf-bili-ranking-partitions)) "全站")))
       (if (zerop rid) "排行榜" (format "排行 %s" name))))
    ('dynamic "关注动态")
    ('toview "稍后再看")
    ('history "观看历史")
    ('fav "我的收藏")
    ('space (format "UP %s" (or (etaf-bili--session-space-name session) "空间")))
    ('search (format "搜索 %s" (or (etaf-bili--session-keyword session) "")))
    (_ "热门")))

(defun etaf-bili-load-popular (session)
  "Load the popular feed into SESSION."
  (etaf-batch
    (setf (etaf-bili--session-mode session) 'popular
          (etaf-bili--session-keyword session) nil)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'popular)
    (etaf-bili--request session '(:op :popular :page 1) "热门")))

(defun etaf-bili-load-ranking (session &optional rid)
  "Load the ranking feed (for partition RID, default current) into SESSION."
  (let ((target-rid (or rid (etaf-value (etaf-bili--session-ranking-rid-ref session)) 0)))
    (etaf-batch
      (setf (etaf-bili--session-mode session) 'ranking
            (etaf-bili--session-keyword session) nil)
      (etaf-set-value (etaf-bili--session-ranking-rid-ref session) target-rid)
      (etaf-set-value (etaf-bili--session-mode-ref session) 'ranking)
      (etaf-bili--request session (list :op :ranking :rid target-rid)
                          (etaf-bili--mode-label session)))))

(defun etaf-bili-load-rcmd (session)
  "Load personalized home recommendations into SESSION."
  (etaf-batch
    (setf (etaf-bili--session-mode session) 'rcmd
          (etaf-bili--session-keyword session) nil)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'rcmd)
    (etaf-bili--request session '(:op :rcmd :page 1) "个性推荐")))

(defun etaf-bili-load-dynamic (session)
  "Load signed-in followed creators' video feed into SESSION."
  (etaf-batch
    (setf (etaf-bili--session-mode session) 'dynamic
          (etaf-bili--session-keyword session) nil
          (etaf-bili--session-dynamic-offset session) nil)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'dynamic)
    (etaf-bili--request session '(:op :dynamic) "关注动态")))

(defun etaf-bili-load-toview (session)
  "Load the Watch Later list into SESSION."
  (etaf-batch
    (setf (etaf-bili--session-mode session) 'toview
          (etaf-bili--session-keyword session) nil)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'toview)
    (etaf-bili--request session '(:op :toview) "稍后再看")))

(defun etaf-bili-load-history (session)
  "Load watch history into SESSION."
  (etaf-batch
    (setf (etaf-bili--session-mode session) 'history
          (etaf-bili--session-keyword session) nil
          (etaf-bili--session-history-max session) nil
          (etaf-bili--session-history-view-at session) nil)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'history)
    (etaf-bili--request session '(:op :history) "观看历史")))

(defun etaf-bili-load-favorites (session &optional folder-id)
  "Load the signed-in user's favorite folders and items into SESSION."
  (let ((mid (etaf-bili--session-account-mid session)))
    (if (and (null folder-id) (not (and (numberp mid) (> mid 0))))
        (etaf-bili--toast session "查看收藏夹需要先扫码登录" 'info)
      (etaf-batch
        (setf (etaf-bili--session-mode session) 'fav
              (etaf-bili--session-keyword session) nil)
        (etaf-set-value (etaf-bili--session-mode-ref session) 'fav))
      (if folder-id
          (progn
            (etaf-set-value (etaf-bili--session-fav-folder-id-ref session) folder-id)
            (etaf-bili--request session (list :op :fav-list :media-id folder-id :page 1) "我的收藏"))
        (etaf-bili-client-call
         (etaf-bili--session-client session) (list :op :fav-folders :mid mid)
         (lambda (reply)
           (unless (etaf-bili--session-disposed session)
             (if-let* ((folders (plist-get reply :ok))
                       (first (car folders)))
                 (progn
                   (etaf-set-value (etaf-bili--session-fav-folders-ref session) folders)
                   (etaf-set-value (etaf-bili--session-fav-folder-id-ref session)
                                   (plist-get first :id))
                   (etaf-bili--request session
                                       (list :op :fav-list :media-id (plist-get first :id) :page 1)
                                       (format "收藏 %s" (plist-get first :title))))
               (etaf-bili--toast session (or (plist-get reply :error) "暂无收藏夹") 'info)))))))))

(defun etaf-bili-load-space (session mid &optional name)
  "Load videos uploaded by creator MID (display NAME) into SESSION."
  (when (and (numberp mid) (> mid 0))
    (etaf-batch
      (setf (etaf-bili--session-mode session) 'space
            (etaf-bili--session-space-mid session) mid
            (etaf-bili--session-space-name session) (or name (format "%d" mid))
            (etaf-bili--session-keyword session) nil)
      (etaf-set-value (etaf-bili--session-view-mode-ref session) 'gallery)
      (etaf-set-value (etaf-bili--session-mode-ref session) 'space)
      (etaf-bili--request session (list :op :space :mid mid :page 1)
                          (format "UP %s" (or name mid))))))

(defun etaf-bili-search (session keyword &optional order)
  "Search videos for KEYWORD in SESSION; ignore whitespace-only queries.
Optional ORDER selects the search sort (`totalrank', `click', `pubdate', `dm')."
  (unless (string-empty-p (string-trim (or keyword "")))
    (let ((ord (or order (etaf-value (etaf-bili--session-search-order-ref session)) "totalrank")))
      (etaf-bili-store-search-history-add keyword)
      (etaf-batch
        (setf (etaf-bili--session-mode session) 'search
              (etaf-bili--session-keyword session) keyword)
        (etaf-set-value (etaf-bili--session-query-ref session) keyword)
        (etaf-set-value (etaf-bili--session-search-order-ref session) ord)
        (etaf-set-value (etaf-bili--session-mode-ref session) 'search)
        (etaf-bili--request session
                            (list :op :search :keyword keyword :page 1 :order ord)
                            (format "搜索 %s" keyword))))))

(defun etaf-bili-load-more (session)
  "Fetch the next page of SESSION's current paginated channel, if available."
  (when (and (not (etaf-bili--session-disposed session))
             (not (etaf-bili--session-loading session))
             (not (etaf-value (etaf-bili--session-loading-more-ref session)))
             (etaf-bili--session-has-more session))
    (let* ((mode (etaf-bili--session-mode session))
           (next-page (1+ (or (etaf-bili--session-page session) 1)))
           (req (pcase mode
                  ('popular (list :op :popular :page next-page))
                  ('rcmd (list :op :rcmd :page next-page))
                  ('search (list :op :search
                                 :keyword (etaf-bili--session-keyword session)
                                 :page next-page
                                 :order (etaf-value (etaf-bili--session-search-order-ref session))))
                  ('dynamic (when-let* ((off (etaf-bili--session-dynamic-offset session)))
                              (list :op :dynamic :offset off)))
                  ('history (when-let* ((m (etaf-bili--session-history-max session)))
                              (list :op :history :max m
                                    :view-at (etaf-bili--session-history-view-at session))))
                  ('fav (when-let* ((fid (etaf-value (etaf-bili--session-fav-folder-id-ref session))))
                          (list :op :fav-list :media-id fid :page next-page)))
                  ('space (when-let* ((mid (etaf-bili--session-space-mid session)))
                            (list :op :space :mid mid :page next-page)))
                  (_ nil))))
      (when req
        (setf (etaf-bili--session-page session) next-page)
        (etaf-bili--request session req (etaf-bili--mode-label session) t)))))

(defun etaf-bili-session-state (session)
  "Return a detached snapshot of SESSION.
Preserves all original keys (:mode :keyword :status :loading :items :selected
:playback :error :play-loading :account :login) and adds :view-mode, :watch,
:toast and :page."
  (copy-tree
   (list :mode (etaf-bili--session-mode session)
         :keyword (etaf-bili--session-keyword session)
         :status (etaf-bili--session-status session)
         :loading (and (etaf-bili--session-loading session) t)
         :items (etaf-bili--session-items session)
         :selected (etaf-bili--session-selected session)
         :playback (etaf-bili--session-playback session)
         :error (etaf-value (etaf-bili--session-error-ref session))
         :play-loading (etaf-value (etaf-bili--session-play-loading-ref session))
         :account (etaf-value (etaf-bili--session-account-ref session))
         :login (etaf-value (etaf-bili--session-login-ref session))
         :view-mode (etaf-value (etaf-bili--session-view-mode-ref session))
         :watch (etaf-value (etaf-bili--session-watch-source-ref session))
         :toast (etaf-value (etaf-bili--session-toast-ref session))
         :page (etaf-bili--session-page session))))

(defun etaf-bili-reload (session)
  "Reload SESSION's current feed or search."
  (pcase (etaf-bili--session-mode session)
    ('rcmd (etaf-bili-load-rcmd session))
    ('ranking (etaf-bili-load-ranking session))
    ('dynamic (etaf-bili-load-dynamic session))
    ('toview (etaf-bili-load-toview session))
    ('history (etaf-bili-load-history session))
    ('fav (etaf-bili-load-favorites session (etaf-value (etaf-bili--session-fav-folder-id-ref session))))
    ('space (etaf-bili-load-space session (etaf-bili--session-space-mid session)
                                  (etaf-bili--session-space-name session)))
    ('search (etaf-bili-search session (or (etaf-bili--session-keyword session) "")))
    (_ (etaf-bili-load-popular session))))

(defun etaf-bili-move (session delta)
  "Move SESSION's selection DELTA places, clamping at the endpoints."
  (let ((count (length (etaf-bili--session-items session))))
    (when (> count 0)
      (let ((next (max 0 (min (1- count) (+ (etaf-bili--session-selected session) delta)))))
        (setf (etaf-bili--session-selected session) next)
        (etaf-set-value (etaf-bili--session-selected-ref session) next)
        (etaf-bili--notify session)))))

(defun etaf-bili-selected-row (session)
  "Return SESSION's selected video or nil."
  (nth (etaf-bili--session-selected session) (etaf-bili--session-items session)))

;;; Stream Resolution & Watch Companion Loaders

(defun etaf-bili--cached-source (session bvid cid)
  "Return fresh cached play source for BVID/CID in SESSION, or nil."
  (let* ((key (cons bvid (or cid 0)))
         (entry (gethash key (etaf-bili--session-play-cache session))))
    (when (and entry
               (< (- (float-time) (plist-get entry :at)) etaf-bili--play-cache-ttl)
               (plist-get (plist-get entry :source) :url))
      (plist-get entry :source))))

(defun etaf-bili--cache-source (session bvid cid source)
  "Store resolved SOURCE for BVID/CID in SESSION's TTL cache."
  (let ((now (float-time)))
    (setf (etaf-bili--session-play-bvid session) bvid
          (etaf-bili--session-play-source session) source)
    (puthash (cons bvid (or cid 0)) (list :source source :at now)
             (etaf-bili--session-play-cache session))
    (puthash (cons bvid 0) (list :source source :at now)
             (etaf-bili--session-play-cache session))))

(defun etaf-bili-play-target (session target on-ready &optional cid qn force-refresh)
  "Resolve stream for TARGET (`:bvid' or `:aid' plist) and call ON-READY.
Uses TTL cache unless FORCE-REFRESH or QN is explicitly given.  Play failures
set status and show a non-destructive toast rather than wiping the gallery."
  (let* ((bvid (plist-get target :bvid))
         (aid (plist-get target :aid))
         (want-qn (or qn (etaf-bili-store-pref-get "quality" etaf-bili-preferred-quality)))
         (cached (and (not force-refresh) (not qn) bvid
                      (etaf-bili--cached-source session bvid cid))))
    (if cached
        (progn
          (etaf-bili--status session (format "播放：%s" (or (plist-get cached :title) bvid)))
          (funcall on-ready cached))
      (let ((token (cl-incf (etaf-bili--session-play-request session)))
            (req (append (list :op :play)
                         (when bvid (list :bvid bvid))
                         (when (and (not bvid) aid) (list :aid aid))
                         (when cid (list :cid cid))
                         (when want-qn (list :qn want-qn)))))
        (etaf-batch
          (etaf-set-value (etaf-bili--session-play-loading-ref session) t)
          (etaf-set-value (etaf-bili--session-watch-play-error-ref session) nil)
          (etaf-bili--status session "正在获取播放地址…"))
        (etaf-bili-client-call
         (etaf-bili--session-client session) req
         (lambda (reply)
           (when (and (not (etaf-bili--session-disposed session))
                      (= token (etaf-bili--session-play-request session)))
             (etaf-batch
               (etaf-set-value (etaf-bili--session-play-loading-ref session) nil)
               (if-let* ((source (plist-get reply :ok)))
                   (let ((resolved-bvid (or (plist-get source :bvid) bvid))
                         (resolved-cid (plist-get source :cid)))
                     (etaf-bili--cache-source session resolved-bvid resolved-cid source)
                     (etaf-bili--status session (format "播放：%s" (or (plist-get source :title) "")))
                     (funcall on-ready source))
                 (let ((err (or (plist-get reply :error) "未知错误")))
                   (etaf-set-value (etaf-bili--session-watch-play-error-ref session) err)
                   (etaf-bili--status session (concat "播放失败：" err))
                   (etaf-bili--toast session (concat "播放失败：" err) 'error)))))))))))

(defun etaf-bili-play-selected (session on-ready)
  "Resolve SESSION's selected stream and call ON-READY with its source.
Uses a TTL-bounded stream cache; failures report on the status line and toast
without replacing the gallery."
  (when-let* ((row (etaf-bili-selected-row session)))
    (let ((bvid (plist-get row :bvid)))
      (if (and (equal bvid (etaf-bili--session-play-bvid session))
               (plist-get (etaf-bili--session-play-source session) :url)
               (etaf-bili--cached-source session bvid nil))
          (let ((source (etaf-bili--session-play-source session)))
            (etaf-bili--status session (format "播放：%s" (or (plist-get source :title)
                                                              (plist-get row :title))))
            (funcall on-ready source))
        (let ((token (cl-incf (etaf-bili--session-play-request session))))
          (etaf-batch
            (etaf-set-value (etaf-bili--session-play-loading-ref session) t)
            (etaf-set-value (etaf-bili--session-watch-play-error-ref session) nil)
            (etaf-bili--status session "正在获取播放地址…"))
          (etaf-bili-client-call
           (etaf-bili--session-client session) (list :op :play :bvid bvid)
           (lambda (reply)
             (when (and (not (etaf-bili--session-disposed session))
                        (= token (etaf-bili--session-play-request session)))
               (etaf-batch
                 (etaf-set-value (etaf-bili--session-play-loading-ref session) nil)
                 (if-let* ((source (plist-get reply :ok)))
                     (progn
                       (etaf-bili--cache-source session bvid (plist-get source :cid) source)
                       (etaf-bili--status session (format "播放：%s" (or (plist-get source :title)
                                                                         (plist-get row :title))))
                       (funcall on-ready source))
                   (let ((error (or (plist-get reply :error) "未知错误")))
                     (etaf-set-value (etaf-bili--session-watch-play-error-ref session) error)
                     (etaf-bili--status session (concat "播放失败：" error))
                     (etaf-bili--toast session (concat "播放失败：" error) 'error))))))))))))

(defun etaf-bili--load-watch-companions (session source &optional on-cloud-resume)
  "Load subtitles, chapters, danmaku, comments and related videos for SOURCE."
  (let ((token (cl-incf (etaf-bili--session-watch-aux-request session)))
        (client (etaf-bili--session-client session))
        (bvid (plist-get source :bvid))
        (aid (plist-get source :aid))
        (cid (plist-get source :cid)))
    (etaf-batch
      (etaf-set-value (etaf-bili--session-watch-subtitles-list-ref session) nil)
      (etaf-set-value (etaf-bili--session-watch-subtitle-index-ref session) nil)
      (setf (etaf-bili--session-watch-subtitle-cues session) nil)
      (etaf-set-value (etaf-bili--session-watch-subtitle-cues-ref session) nil)
      (etaf-set-value (etaf-bili--session-watch-subtitle-filter-ref session) "")
      (etaf-set-value (etaf-bili--session-watch-danmaku-list-ref session) nil)
      (etaf-set-value (etaf-bili--session-watch-chapters-ref session) nil)
      (etaf-set-value (etaf-bili--session-watch-comments-ref session) nil)
      (etaf-set-value (etaf-bili--session-watch-related-ref session) nil))
    ;; 1. Player v2: subtitles + chapters + cloud last_play_time
    (when (and bvid cid (> cid 0))
      (etaf-bili-client-call
       client (list :op :player-info :bvid bvid :cid cid)
       (lambda (reply)
         (when (and (not (etaf-bili--session-disposed session))
                    (= token (etaf-bili--session-watch-aux-request session))
                    (plist-get reply :ok))
           (let* ((info (plist-get reply :ok))
                  (subs (plist-get info :subtitles))
                  (chapters (plist-get info :chapters))
                  (cloud-sec (or (plist-get info :last-play-time) 0)))
             (etaf-batch
               (etaf-set-value (etaf-bili--session-watch-subtitles-list-ref session) subs)
               (etaf-set-value (etaf-bili--session-watch-chapters-ref session) chapters))
             (when (and (functionp on-cloud-resume) (> cloud-sec 5))
               (funcall on-cloud-resume cloud-sec))
             (when (and subs (etaf-bili-store-pref-get "subtitle" t))
               (etaf-bili--select-subtitle-track session 0 token)))))))
    ;; 2. Danmaku XML
    (when (and cid (> cid 0))
      (etaf-bili-client-call
       client (list :op :danmaku :cid cid)
       (lambda (reply)
         (when (and (not (etaf-bili--session-disposed session))
                    (= token (etaf-bili--session-watch-aux-request session))
                    (plist-get reply :ok))
           (etaf-set-value (etaf-bili--session-watch-danmaku-list-ref session)
                           (plist-get reply :ok))))))
    ;; 3. Hot + Pinned Comments
    (when (and aid (> aid 0))
      (etaf-bili-client-call
       client (list :op :comments :aid aid :page 0)
       (lambda (reply)
         (when (and (not (etaf-bili--session-disposed session))
                    (= token (etaf-bili--session-watch-aux-request session))
                    (plist-get reply :ok))
           (etaf-set-value (etaf-bili--session-watch-comments-ref session)
                           (plist-get reply :ok))))))
    ;; 4. Related Videos
    (when (and bvid (not (string-empty-p bvid)))
      (etaf-bili-client-call
       client (list :op :related :bvid bvid)
       (lambda (reply)
         (when (and (not (etaf-bili--session-disposed session))
                    (= token (etaf-bili--session-watch-aux-request session))
                    (plist-get reply :ok))
           (etaf-set-value (etaf-bili--session-watch-related-ref session)
                           (plist-get reply :ok))))))))

(defun etaf-bili--select-subtitle-track (session index &optional expected-token)
  "Load subtitle track at INDEX (or nil to turn subtitles off) for SESSION."
  (let ((tracks (etaf-value (etaf-bili--session-watch-subtitles-list-ref session)))
        (token (or expected-token (etaf-bili--session-watch-aux-request session))))
    (if (or (null index) (>= index (length tracks)))
        (etaf-batch
          (etaf-set-value (etaf-bili--session-watch-subtitle-index-ref session) nil)
          (setf (etaf-bili--session-watch-subtitle-cues session) nil)
          (etaf-set-value (etaf-bili--session-watch-subtitle-cues-ref session) nil))
      (let ((track (nth index tracks)))
        (etaf-set-value (etaf-bili--session-watch-subtitle-index-ref session) index)
        (etaf-bili-client-call
         (etaf-bili--session-client session)
         (list :op :subtitle-body :url (plist-get track :url))
         (lambda (reply)
           (when (and (not (etaf-bili--session-disposed session))
                      (= token (etaf-bili--session-watch-aux-request session))
                      (plist-get reply :ok))
             (let ((cues (plist-get reply :ok)))
               (setf (etaf-bili--session-watch-subtitle-cues session) cues)
               (etaf-set-value (etaf-bili--session-watch-subtitle-cues-ref session) cues)))))))))

(defun etaf-bili-subtitle-at (cues seconds)
  "Binary-search sorted CUES `(START END TEXT)' for SECONDS."
  (when (and cues (numberp seconds))
    (let ((vec (if (vectorp cues) cues (vconcat cues))))
      (let ((low 0) (high (1- (length vec))) (found nil))
        (while (<= low high)
          (let* ((mid (/ (+ low high) 2))
                 (cue (aref vec mid))
                 (start (nth 0 cue))
                 (end (nth 1 cue)))
            (cond ((< seconds start) (setq high (1- mid)))
                  ((>= seconds end) (setq low (1+ mid)))
                  (t (setq found (nth 2 cue) low (1+ high))))))
        found))))

(defun etaf-bili-danmaku-window (entries seconds &optional span limit)
  "Return up to LIMIT danmaku entries within [SECONDS - SPAN, SECONDS]."
  (when (and entries (numberp seconds))
    (let ((from (max 0.0 (- seconds (or span 4.5))))
          (to (+ seconds 0.4))
          (cap (or limit 3))
          (res nil))
      (dolist (item entries)
        (let ((tm (plist-get item :time)))
          (when (and (>= tm from) (<= tm to))
            (push item res))))
      (seq-take (nreverse res) cap))))

(defun etaf-bili-extract-timestamps (text)
  "Extract `(SECONDS . LABEL)' pairs from `MM:SS' or `HH:MM:SS' tokens in TEXT."
  (let ((pos 0) (out nil))
    (when (stringp text)
      (while (string-match "\\b\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\(?::[0-9]\\{2\\}\\)?\\)\\b" text pos)
        (let* ((tok (match-string 1 text))
               (next (match-end 0))
               (sec (etaf-bili--seconds tok)))
          (setq pos next)
          (when (> sec 0)
            (push (cons sec tok) out)))))
    (nreverse out)))

(provide 'etaf-bili-model)
;;; etaf-bili-model.el ends here
