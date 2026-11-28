;;; etaf-youtube-app.el --- Application shell, commands and doctor of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Opens the application through `etaf-app-open' with `:mode-line t' so the
;; user's original Emacs mode-line is preserved.  Declares all interactive
;; commands bound by the shell View, smart `RET' activation (preferring the
;; focused Host before falling back to the selected card), floating PiP
;; playback, external `mpv' handoff, Org timestamp links, and `etaf-youtube-doctor'
;; for `etaf-install-doctor'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-media)
(require 'etaf-ui)
(require 'etaf-youtube-service)
(require 'etaf-youtube-model)
(require 'etaf-youtube-views)

(defcustom etaf-youtube-buffer-name "*YouTube*"
  "Buffer name of a mounted application."
  :type 'string
  :group 'etaf-youtube)

(defun etaf-youtube--current-model ()
  "Return the model of the current buffer, or signal `user-error'."
  (or (etaf-app-state)
      (user-error "Current buffer is not an etaf-youtube session")))

;;; ---------------------------------------------------------------------------
;;; Navigation & focus commands
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-focus-search ()
  "Begin editing the search field of the current session."
  (let* ((model (etaf-youtube--current-model))
         (buffer (plist-get model :buffer))
         (runtime (and buffer (get-buffer buffer)
                       (etaf-runtime-for-buffer buffer))))
    (if runtime
        (etaf-text-input-begin runtime etaf-youtube-search-ref)
      (user-error "The YouTube session is not mounted"))))

(defun etaf-youtube-activate-command ()
  "Activate the focused interactive control, or open the selected list item."
  (let* ((model (etaf-youtube--current-model))
         (buffer (plist-get model :buffer))
         (runtime (and buffer (buffer-live-p buffer)
                       (etaf-runtime-for-buffer buffer)))
         (focused (and runtime (etaf-focused-host-ref runtime))))
    (if focused
        (etaf-activate runtime)
      (etaf-youtube-activate model))))

(defun etaf-youtube-select-next-command ()
  "Select the next item in the current feed list."
  (etaf-youtube-select (etaf-youtube--current-model) 1))

(defun etaf-youtube-select-prev-command ()
  "Select the previous item in the current feed list."
  (etaf-youtube-select (etaf-youtube--current-model) -1))

(defun etaf-youtube-nav-1-command ()
  "Open the Home feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'home))

(defun etaf-youtube-nav-2-command ()
  "Open the Shorts feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'shorts))

(defun etaf-youtube-nav-3-command ()
  "Open the Subscriptions feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'subscriptions))

(defun etaf-youtube-nav-4-command ()
  "Open the Live feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'live))

(defun etaf-youtube-nav-5-command ()
  "Open the Watch History feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'history))

(defun etaf-youtube-nav-6-command ()
  "Open the Playlists feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'playlists))

(defun etaf-youtube-nav-7-command ()
  "Open the Watch Later feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'watch-later))

(defun etaf-youtube-nav-8-command ()
  "Open the Liked Videos feed."
  (etaf-youtube-locate (etaf-youtube--current-model) 'liked))

(defun etaf-youtube-return-to-watch-command ()
  "Return to the active watch video, if one is loaded."
  (let* ((model (etaf-youtube--current-model))
         (video (etaf-youtube--read model :video))
         (media (etaf-youtube--read model :media))
         (id (or (plist-get video :id) (plist-get media :id))))
    (if id
        (progn
          (when (etaf-youtube--read model :audio-only)
            (etaf-youtube--toggle-audio-only model))
          (etaf-youtube--write model :route (list :view 'watch :args (list :id id)))
          (etaf-youtube--start-player-timer model))
      (etaf-youtube--note model "当前还没有正在观看的视频" 'info))))

(defun etaf-youtube-open-author-channel-command ()
  "Open the current video author's channel page."
  (let* ((model (etaf-youtube--current-model))
         (video (etaf-youtube--read model :video))
         (cid (and video (etaf-youtube--nonempty-string (plist-get video :channel_id)))))
    (if cid
        (etaf-youtube-locate model 'channel (list :id cid))
      (etaf-youtube-back model))))

;;; ---------------------------------------------------------------------------
;;; Playback, chapters, queue & theater commands
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-toggle-playback-command ()
  "Toggle playback of the current session."
  (etaf-youtube-toggle-playback (etaf-youtube--current-model)))

(defun etaf-youtube-seek-forward-command ()
  "Seek five seconds forward."
  (etaf-youtube-seek-by (etaf-youtube--current-model) 5))

(defun etaf-youtube-seek-backward-command ()
  "Seek five seconds backward."
  (etaf-youtube-seek-by (etaf-youtube--current-model) -5))

(defun etaf-youtube-seek-forward-10-command ()
  "Seek ten seconds forward."
  (etaf-youtube-seek-by (etaf-youtube--current-model) 10))

(defun etaf-youtube-seek-back-10-command ()
  "Seek ten seconds backward."
  (etaf-youtube-seek-by (etaf-youtube--current-model) -10))

(defun etaf-youtube--seek-percent (pct)
  "Seek the current video to PCT percent (0..90)."
  (let* ((model (etaf-youtube--current-model))
         (dur (max (float (or (plist-get model :live-duration) 0))
                   (float (or (etaf-youtube--read model :duration) 0)))))
    (when (> dur 0)
      (etaf-youtube-seek model (* dur (/ (float pct) 100.0))))))

(defun etaf-youtube-seek-percent-0-command () "Jump to 0%." (etaf-youtube--seek-percent 0))
(defun etaf-youtube-seek-percent-1-command () "Jump to 10%." (etaf-youtube--seek-percent 10))
(defun etaf-youtube-seek-percent-2-command () "Jump to 20%." (etaf-youtube--seek-percent 20))
(defun etaf-youtube-seek-percent-3-command () "Jump to 30%." (etaf-youtube--seek-percent 30))
(defun etaf-youtube-seek-percent-4-command () "Jump to 40%." (etaf-youtube--seek-percent 40))
(defun etaf-youtube-seek-percent-5-command () "Jump to 50%." (etaf-youtube--seek-percent 50))
(defun etaf-youtube-seek-percent-6-command () "Jump to 60%." (etaf-youtube--seek-percent 60))
(defun etaf-youtube-seek-percent-7-command () "Jump to 70%." (etaf-youtube--seek-percent 70))
(defun etaf-youtube-seek-percent-8-command () "Jump to 80%." (etaf-youtube--seek-percent 80))
(defun etaf-youtube-seek-percent-9-command () "Jump to 90%." (etaf-youtube--seek-percent 90))

(defun etaf-youtube-step-forward-command ()
  "Step one frame forward when the player is mounted."
  (let ((model (etaf-youtube--current-model)))
    (ignore-errors (etaf-video-step (etaf-youtube--active-handle model)))))

(defun etaf-youtube-step-back-command ()
  "Step one frame backward when the player is mounted."
  (let ((model (etaf-youtube--current-model)))
    (ignore-errors (etaf-video-step-back (etaf-youtube--active-handle model)))))

(defun etaf-youtube-speed-up-command ()
  "Increase playback speed by one preset step."
  (etaf-youtube--step-speed (etaf-youtube--current-model) 1))

(defun etaf-youtube-speed-down-command ()
  "Decrease playback speed by one preset step."
  (etaf-youtube--step-speed (etaf-youtube--current-model) -1))

(defun etaf-youtube-volume-up-command ()
  "Raise the volume by five."
  (let ((model (etaf-youtube--current-model)))
    (etaf-youtube-set-volume model (+ (or (plist-get (etaf-youtube-state model) :volume) 100) 5))))

(defun etaf-youtube-volume-down-command ()
  "Lower the volume by five."
  (let ((model (etaf-youtube--current-model)))
    (etaf-youtube-set-volume model (- (or (plist-get (etaf-youtube-state model) :volume) 100) 5))))

(defun etaf-youtube-mute-command ()
  "Toggle mute on the current session."
  (etaf-youtube-toggle-mute (etaf-youtube--current-model)))

(defun etaf-youtube-quality-dialog-command ()
  "Toggle the Watch quality and engine selection dialog."
  (let ((model (etaf-youtube--current-model)))
    (etaf-youtube--write model :quality-menu
                         (not (etaf-youtube--read model :quality-menu)))))

(defun etaf-youtube-cycle-captions-command ()
  "Cycle through available subtitle tracks and off."
  (etaf-youtube--cycle-captions (etaf-youtube--current-model)))

(defun etaf-youtube-toggle-drawer-command ()
  "Toggle the narrow/theater workbench drawer."
  (let ((model (etaf-youtube--current-model)))
    (etaf-youtube--write model :watch-drawer
                         (not (etaf-youtube--read model :watch-drawer)))))

(defun etaf-youtube-toggle-audio-only-command ()
  "Toggle zero-CPU background audio-only mode."
  (etaf-youtube--toggle-audio-only (etaf-youtube--current-model)))

(defun etaf-youtube-next-video-command ()
  "Play the next video in the queue."
  (etaf-youtube--step-queue (etaf-youtube--current-model) 1))

(defun etaf-youtube-prev-video-command ()
  "Play the previous video in the queue."
  (etaf-youtube--step-queue (etaf-youtube--current-model) -1))

(defun etaf-youtube-toggle-auto-next-command ()
  "Toggle automatic playback of the next queued/related video."
  (etaf-youtube--toggle-auto-next (etaf-youtube--current-model)))

(defun etaf-youtube-next-chapter-command ()
  "Jump to the next video chapter."
  (let* ((model (etaf-youtube--current-model))
         (chapters (etaf-youtube--read model :chapters))
         (pos (or (plist-get model :live-position) 0))
         (next (seq-find (lambda (ch) (> (or (plist-get ch :start) 0) (+ pos 1))) chapters)))
    (if next
        (progn
          (etaf-youtube-seek model (float (plist-get next :start)))
          (etaf-youtube--note model (format "章节：%s" (plist-get next :title)) 'info))
      (etaf-youtube--note model "已经是最后一个章节" 'info))))

(defun etaf-youtube-prev-chapter-command ()
  "Jump to the previous video chapter."
  (let* ((model (etaf-youtube--current-model))
         (chapters (reverse (etaf-youtube--read model :chapters)))
         (pos (or (plist-get model :live-position) 0))
         (prev (seq-find (lambda (ch) (< (or (plist-get ch :start) 0) (- pos 3))) chapters)))
    (if prev
        (progn
          (etaf-youtube-seek model (float (plist-get prev :start)))
          (etaf-youtube--note model (format "章节：%s" (plist-get prev :title)) 'info))
      (etaf-youtube-seek model 0.0))))

(defun etaf-youtube-sidebar-command ()
  "Fold or unfold the sidebar."
  (etaf-youtube-toggle-sidebar (etaf-youtube--current-model)))

(defun etaf-youtube-theater-command ()
  "Toggle theater mode."
  (etaf-youtube-toggle-theater (etaf-youtube--current-model)))

(defun etaf-youtube-fullscreen-command ()
  "Toggle in-window pure cinema fullscreen in Watch View."
  (etaf-youtube-toggle-fullscreen (etaf-youtube--current-model) 'window))

(defun etaf-youtube-frame-fullscreen-command ()
  "Toggle dedicated OS/frame fullscreen in Watch View."
  (etaf-youtube-toggle-fullscreen (etaf-youtube--current-model) 'frame))

(defun etaf-youtube-escape-command ()
  "Dismiss topmost Watch overlay or exit fullscreen first, otherwise go back."
  (let ((model (etaf-youtube--current-model)))
    (cond
     ((etaf-youtube--read model :quality-menu)
      (etaf-youtube--write model :quality-menu nil))
     ((etaf-youtube--read model :watch-drawer)
      (etaf-youtube--write model :watch-drawer nil))
     ((etaf-youtube--read model :fullscreen)
      (etaf-youtube-exit-fullscreen model))
     (t (etaf-youtube-back model)))))

(defun etaf-youtube-theme-command ()
  "Switch the appearance."
  (etaf-youtube-cycle-theme (etaf-youtube--current-model))
  (when (etaf-pip-active-p etaf-youtube--pip-id)
    (etaf-pip-refresh-chrome etaf-youtube--pip-id)))

(defun etaf-youtube-refresh-command ()
  "Reload the current view."
  (etaf-youtube-refresh (etaf-youtube--current-model)))

(defun etaf-youtube-back-command ()
  "Return to the previous view."
  (etaf-youtube-back (etaf-youtube--current-model)))

;;; ---------------------------------------------------------------------------
;;; External handoff, PiP & Org timestamp links
;;; ---------------------------------------------------------------------------

(defun etaf-youtube-open-external ()
  "Launch external `mpv' at the exact current second with audio, headers and proxy."
  (let* ((model (etaf-youtube--current-model))
         (src (etaf-youtube-media-src model))
         (mpv (executable-find "mpv")))
    (cond
     ((null mpv)
      (etaf-youtube--note model "未找到外部 mpv 命令，请先安装 mpv" 'danger))
     ((null src)
      (etaf-youtube--note model "视频流尚未解析完成" 'info))
     (t
      (let* ((url (plist-get src :url))
             (audio (plist-get src :audio-url))
             (proxy (plist-get src :proxy))
             (ua (cdr (assoc "User-Agent" (plist-get src :headers))))
             (pos (float (max 0 (or (plist-get model :live-position) 0))))
             (args (append
                    (list mpv "--no-terminal" "--ytdl=no"
                          (format "--start=%.2f" pos)
                          "--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")
                    (when audio (list (format "--audio-file=%s" audio)))
                    (when proxy (list (format "--http-proxy=%s" proxy)))
                    (when ua (list (format "--user-agent=%s" ua)))
                    (list url))))
        (etaf-youtube-exit-fullscreen model)
        (when (etaf-youtube--read model :playing)
          (etaf-youtube-toggle-playback model))
        (make-process :name "etaf-youtube-external-mpv"
                      :command args
                      :connection-type 'pipe
                      :noquery t)
        (etaf-youtube--note model
                            (format "已在外部 mpv 打开（从 %s 续播）"
                                    (etaf-youtube--clock pos))
                            'info))))))

(defun etaf-youtube-open-in-browser ()
  "Open the current YouTube video in the default system web browser."
  (let* ((model (etaf-youtube--current-model))
         (video (etaf-youtube--read model :video))
         (id (or (plist-get video :id)
                 (plist-get (plist-get (etaf-youtube--read model :route) :args) :id)))
         (pos (round (or (plist-get model :live-position) 0))))
    (if (not id)
        (etaf-youtube--note model "当前页面没有可打开的视频链接" 'info)
      (browse-url (if (> pos 5)
                      (format "https://www.youtube.com/watch?v=%s&t=%ds" id pos)
                    (format "https://www.youtube.com/watch?v=%s" id)))
      (etaf-youtube--note model "已在默认浏览器中打开视频" 'info))))

(defun etaf-youtube--open-video-link (id &optional seconds)
  "Open YouTube video ID at optional SECONDS inside `*YouTube*'."
  (let* ((buf (etaf-youtube-open))
         (model (with-current-buffer buf (etaf-app-state))))
    (when model
      (etaf-youtube--open-video-at model id seconds))))

(defun etaf-youtube-copy-org-link ()
  "Copy a clickable Org timestamp link for the current video to the kill ring."
  (let* ((model (etaf-youtube--current-model))
         (video (etaf-youtube--read model :video))
         (id (or (plist-get video :id)
                 (plist-get (plist-get (etaf-youtube--read model :route) :args) :id)))
         (title (replace-regexp-in-string
                 "[][]" "" (or (plist-get video :title) id "YouTube")))
         (sec (round (or (plist-get model :live-position) 0)))
         (link (format "[[elisp:(etaf-youtube--open-video-link %S %d)][%s (%s)]]"
                       id sec title (etaf-youtube--clock sec))))
    (if (not id)
        (etaf-youtube--note model "请先打开一个视频" 'info)
      (kill-new link)
      (etaf-youtube--note model (format "已复制 Org 链接：%s" (etaf-youtube--clock sec)) 'success))))

(defun etaf-youtube--pip-theme-colors (model)
  "Return `etaf-pip' theme color plist derived from MODEL's active palette."
  (let ((mode (or (etaf-youtube--read model :theme-mode) etaf-youtube-theme-mode)))
    (list :bg (etaf-youtube-color :bg mode)
          :panel (etaf-youtube-color :panel2 mode)
          :chip (etaf-youtube-color :panel3 mode)
          :hover (etaf-youtube-color :hover mode)
          :ink (etaf-youtube-color :ink mode)
          :muted (etaf-youtube-color :muted mode)
          :accent (etaf-youtube-color :accent mode)
          :accent-soft (etaf-youtube-color :accent-soft mode)
          :border-inactive (if (eq mode 'light) "#CBD3E0" "#2D364A"))))

(defun etaf-youtube--pip-on-close (model)
  "Save final PiP progress and clear MODEL's active PiP state."
  (when-let* ((st (ignore-errors (etaf-video-state (plist-get model :pip-handle))))
              (pos (plist-get st :position)))
    (when (and (numberp pos) (> pos 0.0))
      (etaf-youtube--set model :live-position (float pos))
      (ignore-errors (etaf-youtube--record-resume model t pos))))
  (etaf-youtube--write model :pip-active nil))

(defun etaf-youtube--pip-close (model &optional restore-focus)
  "Close YouTube's floating Picture-in-Picture window cleanly."
  (if (etaf-pip-active-p etaf-youtube--pip-id)
      (etaf-pip-close etaf-youtube--pip-id restore-focus)
    (when (etaf-youtube--read model :pip-active)
      (etaf-youtube--pip-on-close model))))

(defun etaf-youtube--pip-return (model)
  "Close YouTube PiP and seamlessly resume playback inside `*YouTube*' Watch."
  (let* ((fr (etaf-pip-frame etaf-youtube--pip-id))
         (parent (and fr (frame-live-p fr) (frame-parent fr)))
         (st (ignore-errors (etaf-video-state (plist-get model :pip-handle))))
         (pos (float (or (and st (plist-get st :position))
                         (plist-get model :live-position)
                         0.0)))
         (buf (plist-get model :buffer)))
    (etaf-youtube--pip-close model t)
    (when-let* ((media (etaf-youtube--read model :media)))
      (etaf-youtube--set model :live-position pos)
      (etaf-youtube--set model :loading-reason 'first-frame)
      (etaf-batch
        (etaf-youtube--write model :has-frame nil)
        (etaf-youtube--write model :buffering t)
        (etaf-youtube--write model :media
                             (plist-put (copy-sequence media) :start-offset pos))
        (etaf-youtube--write model :pip-active nil))
      (let* ((video (etaf-youtube--read model :video))
             (vid (or (plist-get video :id) (plist-get media :id))))
        (when (and vid (not (eq (plist-get (etaf-youtube--read model :route) :view) 'watch)))
          (etaf-youtube--write model :route (list :view 'watch :args (list :id vid)))))
      (etaf-youtube--start-player-timer model))
    (when (and parent (frame-live-p parent))
      (ignore-errors (select-frame-set-input-focus parent)))
    (when (and buf (buffer-live-p buf))
      (switch-to-buffer buf))))

(defun etaf-youtube-toggle-pip-command ()
  "Toggle an adaptive floating Picture-in-Picture window for the current video."
  (let ((model (etaf-youtube--current-model)))
    (if (etaf-pip-active-p etaf-youtube--pip-id)
        (progn
          (etaf-youtube--pip-close model t)
          (etaf-youtube--note model "已关闭画中画窗口" 'info))
      (cond
       ((not (display-graphic-p))
        (etaf-youtube--note model "终端模式不支持悬浮画中画窗口" 'info))
       ((not (or (etaf-youtube-media-src model) (etaf-youtube--read model :video)))
        (etaf-youtube--note model "请先打开一个视频再开启画中画" 'info))
       (t
        (let* ((pos (float (or (plist-get model :live-position)
                               (etaf-youtube--read model :position) 0.0)))
               (media (etaf-youtube--read model :media))
               (buf (plist-get model :buffer)))
          (etaf-youtube-exit-fullscreen model)
          (etaf-youtube--bg-audio-stop model)
          (etaf-youtube--set model :loading-reason 'first-frame)
          (etaf-batch
            (etaf-youtube--write model :audio-only nil)
            (etaf-youtube--write model :has-frame nil)
            (etaf-youtube--write model :buffering t)
            (etaf-youtube--write model :pip-cc (and (etaf-youtube--read model :captions-on) t))
            (when media
              (etaf-youtube--write model :media
                                   (plist-put (copy-sequence media) :start-offset pos)))
            (etaf-youtube--write model :pip-active t))
          ;; Flush main buffer first so Watch's libmpv releases audio & GPU cleanly.
          (when-let* ((rt (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
            (ignore-errors (etaf-runtime-flush rt)))
          (etaf-pip-open
           etaf-youtube--pip-id
           (etaf-view (etaf-youtube--pip-view :model model))
           :title (lambda ()
                    (or (plist-get (etaf-youtube--read model :video) :title)
                        (plist-get (etaf-youtube--read model :media) :title)
                        "YouTube 画中画"))
           :size (or (plist-get model :pip-size) 'medium)
           :corner (or (plist-get model :pip-corner) 'bottom-right)
           :theme (lambda () (etaf-youtube--pip-theme-colors model))
           :on-return (lambda () (etaf-youtube--pip-return model))
           :on-close (lambda () (etaf-youtube--pip-on-close model))
           :on-size-change (lambda (sz) (etaf-youtube--set model :pip-size sz))
           :on-corner-change (lambda (cr) (etaf-youtube--set model :pip-corner cr)))
          (etaf-youtube--start-player-timer model)
          (etaf-youtube--note model "画中画已开启（拖标题栏移动 · 拖边框自由缩放 · ↩ 主）" 'info)))))))

;;; ---------------------------------------------------------------------------
;;; Region focus helpers
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--focus-region (region-id label)
  "Focus REGION-ID in the current session, reporting LABEL when absent."
  (let* ((model (etaf-youtube--current-model))
         (buffer (plist-get model :buffer))
         (runtime (and buffer (get-buffer buffer)
                       (etaf-runtime-for-buffer buffer))))
    (unless runtime
      (user-error "The YouTube session is not mounted"))
    (condition-case nil
        (etaf-region-focus region-id runtime)
      (error (user-error "当前页面没有%s" label)))))

(defun etaf-youtube-focus-sidebar-command ()
  "Move focus to the navigation sidebar."
  (etaf-youtube--focus-region etaf-youtube-region-sidebar "侧栏"))

(defun etaf-youtube-focus-content-command ()
  "Move focus to the content area."
  (etaf-youtube--focus-region etaf-youtube-region-content "内容区"))

(defun etaf-youtube-focus-comments-command ()
  "Move focus to the comment section of the watch page."
  (etaf-youtube--focus-region etaf-youtube-region-comments "评论区"))

;;; ---------------------------------------------------------------------------
;;; Environment Doctor & Entry Points
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun etaf-youtube-doctor ()
  "Return capability facts for `etaf-youtube' matching `etaf-install-doctor'.
Returns `(:required FACTS :optional FACTS)' where each fact is
`(LABEL AVAILABLE REMEDY)'.  Inspects the environment without modifying it."
  (let* ((entry (expand-file-name "youtube.mjs" etaf-youtube-backend-directory))
         (node (executable-find etaf-youtube-node-program))
         (ytdlp (executable-find "yt-dlp"))
         (curl (executable-find "curl"))
         (mpv-native (and (fboundp 'etaf-video-mpv-available-p)
                          (etaf-video-mpv-available-p)))
         (gpu-native (and (fboundp 'etaf-video-gpu-available-p)
                          (etaf-video-gpu-available-p)))
         (ffmpeg (and (executable-find "ffmpeg") (executable-find "ffplay")))
         (mpv-cli (executable-find "mpv"))
         (sqlite (and (fboundp 'sqlite-available-p) (sqlite-available-p))))
    (list
     :required
     (list
      (list "Bundled backend" (file-readable-p entry)
            "Reinstall etaf-youtube from the ETAF archive so backends/youtube/youtube.mjs is installed.")
      (list "Node.js" (and node t)
            "Install Node.js 18+ (for example: brew install node) so the bundled YouTube backend can run.")
      (list "yt-dlp" (and ytdlp t)
            "Install yt-dlp (for example: brew install yt-dlp) to resolve adaptive high-resolution YouTube streams.")
      (list "curl" (and curl t)
            "Install curl so video thumbnails download asynchronously."))
     :optional
     (list
      (list "libmpv native video engine" (and mpv-native t)
            "Install libmpv (for example: brew install mpv) and run M-x etaf-install-native selecting etaf for hardware-accelerated playback.")
      (list "Native hardware GPU video layer" (and gpu-native t)
            "Run in GUI Emacs on macOS, Windows or Linux with libmpv and etaf-video-mpv native module v2 (M-x etaf-install-native) for low-CPU GPU playback.")
      (list "ffmpeg / ffplay fallback" (and ffmpeg t)
            "Install ffmpeg (for example: brew install ffmpeg) as the software fallback playback pipeline.")
      (list "External mpv handoff" (and mpv-cli t)
            "Install mpv (for example: brew install mpv) to support external window playback via `o' and audio-only mode.")
      (list "SQLite persistence" (and sqlite t)
            "Use Emacs built with SQLite support to persist playback preferences and video resume points.")))))

;;;###autoload
(defun etaf-youtube-open ()
  "Mount the application in its own buffer and return that buffer.
Preserves the user's original Emacs mode-line via `:mode-line t'."
  (interactive)
  (if-let* ((buffer (etaf-app-buffer etaf-youtube-buffer-name)))
      (progn (pop-to-buffer-same-window buffer) buffer)
    (let* ((model (etaf-youtube-create))
           (mode (plist-get model :theme-mode))
           (buffer nil))
      (setq model (plist-put model :buffer
                             (get-buffer-create etaf-youtube-buffer-name)))
      (setq buffer
            (etaf-app-open etaf-youtube-buffer-name (etaf-youtube-view model)
                           :state model
                           :mode-line t
                           :on-close (lambda ()
                                       (etaf-youtube--pip-close model nil)
                                       (etaf-youtube-destroy model))
                           :background (lambda ()
                                         (etaf-youtube-color :bg (etaf-value mode)))
                           :foreground (lambda ()
                                         (etaf-youtube-color :ink (etaf-value mode)))
                           :cursor nil
                           :meta (list :app 'etaf-youtube :kind 'application
                                       :title "YouTube")))
      (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
      buffer)))

;;;###autoload
(defun etaf-youtube-close ()
  "Unmount the application buffer and kill it."
  (interactive)
  (when-let* ((buffer (etaf-app-buffer etaf-youtube-buffer-name)))
    (etaf-app-close buffer)))

(provide 'etaf-youtube-app)
;;; etaf-youtube-app.el ends here
