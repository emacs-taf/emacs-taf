;;; etaf-video-player-app.el --- Buffers, keys and commands for etaf-video-player -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Application controller for `etaf-video-player':
;; - Product-grade Welcome / Continue Watching launcher when opened empty.
;; - Drag-and-drop file/folder/.m3u/subtitle support via `dnd-protocol-alist'.
;; - Full libmpv integration through ETAF's public `etaf-video' API (seamless
;;   multi-audio tracks, embedded/ASS/dual subtitles, frame-accurate step-back,
;;   native A-B loop, aspect/rotate/mirror/deinterlace/color equalizer, audio
;;   delay, hardware decode telemetry) with transparent fallback to `ffmpeg'.
;; - Collapsible Cinema Theater and 4-tab Studio drawers, filterable/sortable
;;   queue with sibling discovery & .m3u playlists, SQLite history & bookmarks.

;;; Code:

(require 'cl-lib)
(require 'dnd)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-video-player-theme)
(require 'etaf-video-player-views)
(require 'etaf-video-player-subtitle)
(require 'etaf-video-player-media)
(require 'etaf-video-player-history)

;;; ---------------------------------------------------------------------------
;;; Constants, customization and root key bindings
;;; ---------------------------------------------------------------------------

(defconst etaf-video-player--buffer-name "*Video Player*"
  "Name of the single application buffer.")
(defconst etaf-video-player--hud-ref 'etaf-video-player-hud)
(defconst etaf-video-player--time-ref 'etaf-video-player-time)
(defconst etaf-video-player--duration-ref 'etaf-video-player-duration)
(defconst etaf-video-player--volume-ref 'etaf-video-player-volume-text)
(defconst etaf-video-player--progress-fill-ref 'etaf-video-player-progress-fill)
(defconst etaf-video-player--subtitle-ref 'etaf-video-player-subtitle)
(defconst etaf-video-player--context-ref 'etaf-video-player-context)
(defconst etaf-video-player--pip-id 'etaf-video-player
  "Shared `etaf-pip' host identifier for `etaf-video-player'.")
(defconst etaf-video-player--cinema-time-ref 'video-cinema-time)
(defconst etaf-video-player--pip-time-ref 'video-pip-time)
(defconst etaf-video-player--pip-subtitle-ref 'video-pip-subtitle)
(defconst etaf-video-player--pip-progress-fill-ref 'video-pip-progress-fill)

(defconst etaf-video-player--hint-line
  "SPC 播放 · f/b ±5s · ,/. 逐帧 · w 剧场 · p 媒体 · i 控制 · v/V 音字轨 · ? 帮助"
  "Concise right-aligned footer hint for wide windows.")
(defconst etaf-video-player--hint-line-medium
  "SPC 播放 · f/b ±5s · w 剧场 · p 媒体 · ? 帮助"
  "Medium right-aligned footer hint for medium windows.")
(defconst etaf-video-player--hint-line-compact
  "SPC 播放 · f/b ±5s · ? 帮助 · q 关闭"
  "Short footer hint for compact windows.")

(defconst etaf-video-player--hud-interval 0.25)
(defconst etaf-video-player--stage-top-fallback 1)
(defconst etaf-video-player--initial-columns 16)
(defconst etaf-video-player--initial-rows 9)
(defconst etaf-video-player--speeds '(0.5 0.75 1 1.25 1.5 2 3)
  "Playback rates offered by the speed controls.")
(defconst etaf-video-player--resume-min-seconds 5)
(defconst etaf-video-player--resume-end-margin 10)
(defconst etaf-video-player--history-interval 5)
(defconst etaf-video-player--volume-step 10)
(defconst etaf-video-player--subtitle-offset-step 0.5)
(defconst etaf-video-player--video-extensions
  '("mp4" "mkv" "webm" "mov" "avi" "m4v" "flv" "ts" "ogv" "wmv" "mpg" "mpeg")
  "File extensions collected when opening a directory as a playlist.")
(defconst etaf-video-player--m3u-extensions '("m3u" "m3u8")
  "Playlist file extensions expanded by the player.")
(defconst etaf-video-player--sub-drop-extensions '("srt" "vtt" "ass" "ssa" "sub")
  "Subtitle file extensions accepted on drag-and-drop.")

(defcustom etaf-video-player-default-layout 'auto
  "Initial drawer layout when opening a video source.
`auto' (default) opens a single video in Cinema Theater mode (both drawers
collapsed so the picture fills the full window width) and opens a multi-item
playlist or directory with the left Media drawer expanded.  `theater' always
collapses both drawers; `studio' opens both drawers whenever the viewport fits."
  :type '(choice (const :tag "Auto (theater for single, media for playlist)" auto)
                 (const :tag "Cinema theater (full-width video)" theater)
                 (const :tag "Studio (media + controls drawers)" studio))
  :group 'etaf-video-player)

(defcustom etaf-video-player-grid-presets
  '((?1 . 64) (?2 . 96) (?3 . 128) (?4 . 176))
  "Grid width presets reached by the `1' to `4' keys."
  :type '(alist :key-type character :value-type integer)
  :group 'etaf-video-player)

(defcustom etaf-video-player-render-mode 'image
  "Render mode of new players: `image', `ascii' or `color'."
  :type '(choice (const :tag "Image frames" image)
                 (const :tag "ASCII density ramp" ascii)
                 (const :tag "True-color half blocks" color))
  :group 'etaf-video-player)

(defcustom etaf-video-player-color-columns 32
  "Column limit applied while the render mode is `color'."
  :type '(choice (const :tag "Unlimited (fit window)" nil) integer)
  :group 'etaf-video-player)

(defcustom etaf-video-player-audio t
  "Whether new players play their source's audio track."
  :type 'boolean
  :group 'etaf-video-player)

(defcustom etaf-video-player-volume 100
  "Initial audio volume for new players, from 0 to 100."
  :type 'integer
  :group 'etaf-video-player)

(defcustom etaf-video-player-display-fps 24
  "Maximum presentation rate for a new player, in frames per second."
  :type '(integer :tag "Frames per second")
  :group 'etaf-video-player)

(defcustom etaf-video-player-device-pixel-ratio nil
  "Device pixels per logical pixel for image frames (nil follows frame)."
  :type '(choice (const :tag "Automatic from frame" nil) number)
  :group 'etaf-video-player)

(defconst etaf-video-player--bindings
  '(("SPC" etaf-video-player-toggle-playback "播放／暂停")
    ("n" etaf-video-player-step "逐帧前进")
    ("." etaf-video-player-step "逐帧前进")
    ("," etaf-video-player-step-back "逐帧后退")
    ("f" etaf-video-player--forward-command "快进 5 秒")
    ("b" etaf-video-player--backward-command "后退 5 秒")
    ("C-f" etaf-video-player--forward-long-command "快进 30 秒")
    ("C-b" etaf-video-player--backward-long-command "后退 30 秒")
    ("0" etaf-video-player--restart-command "从头播放")
    ("g" etaf-video-player-goto-time "跳转到时间 / 百分比")
    ("+" etaf-video-player--speed-up-command "提高播放速度")
    ("=" etaf-video-player--speed-up-command "提高播放速度")
    ("-" etaf-video-player--speed-down-command "降低播放速度")
    ("DEL" etaf-video-player--speed-reset-command "恢复原速 1x")
    ("[" etaf-video-player--volume-down-command "降低音量")
    ("]" etaf-video-player--volume-up-command "提高音量")
    ("a" etaf-video-player--toggle-audio-command "开启 / 关闭声音")
    ("M" etaf-video-player--toggle-audio-command "静音开关")
    ("v" etaf-video-player-cycle-audio-track "切换音频轨道")
    ("V" etaf-video-player-cycle-subtitle-track "切换字幕轨道")
    ("r" etaf-video-player-rotate "旋转画面 90°")
    ("y" etaf-video-player-copy-timestamp "复制当前时间戳")
    ("A" etaf-video-player-set-ab-start "设置 A-B 循环起点")
    ("B" etaf-video-player-set-ab-end "设置或清除 A-B 终点")
    ("m" etaf-video-player-add-bookmark "添加当前时间书签")
    ("M-n" etaf-video-player-next-chapter "下一章节")
    ("M-p" etaf-video-player-previous-chapter "上一章节")
    ("w" etaf-video-player-toggle-theater "切换剧场模式")
    ("W" etaf-video-player-toggle-fullscreen "网页全屏（纯净影院）")
    ("Z" etaf-video-player-toggle-frame-fullscreen "系统真全屏（整屏独占）")
    ("C-c f" etaf-video-player-toggle-fullscreen "网页全屏（纯净影院）")
    ("C-c F" etaf-video-player-toggle-frame-fullscreen "系统真全屏（整屏独占）")
    ("P" etaf-video-player-toggle-pip "悬浮画中画 (PiP)")
    ("C-c v" etaf-video-player-toggle-pip "悬浮画中画 (PiP)")
    ("p" etaf-video-player-toggle-media-panel "开关左侧媒体栏")
    ("i" etaf-video-player-toggle-inspector "开关右侧控制/轨道/画面栏")
    ("1" etaf-video-player--preset-command "画布 64 列")
    ("2" etaf-video-player--preset-command "画布 96 列")
    ("3" etaf-video-player--preset-command "画布 128 列")
    ("4" etaf-video-player--preset-command "画布 176 列")
    (">" etaf-video-player-next "下一个视频")
    ("<" etaf-video-player-previous "上一个视频")
    ("K" etaf-video-player-move-up "队列中上移当前项")
    ("J" etaf-video-player-move-down "队列中下移当前项")
    ("D" etaf-video-player--remove-current-command "从队列移除当前项")
    ("L" etaf-video-player-toggle-loop "切换循环方式")
    ("s" etaf-video-player-toggle-shuffle "切换随机播放")
    ("F" etaf-video-player-fit "适配窗口")
    ("T" etaf-video-player--toggle-theme "切换深浅主题")
    ("o" etaf-video-player-open-file "打开视频 / 目录 / .m3u")
    ("u" etaf-video-player-open-url "打开视频网址")
    ("c" etaf-video-player--subtitle-toggle-command "开关 / 加载字幕")
    ("z" etaf-video-player--subtitle-earlier-command "字幕提前 0.5 秒")
    ("x" etaf-video-player--subtitle-later-command "字幕延迟 0.5 秒")
    ("S" etaf-video-player-save-screenshot "保存当前画面")
    ("C" etaf-video-player-cycle-render-mode "切换渲染方式")
    ("d" etaf-video-player-demo "播放测试画面")
    ("C-c h" etaf-help "查看快捷键")
    ("q" etaf-video-player-close "关闭播放器"))
  "Root keys of the player, as (KEY COMMAND LABEL).")

;;; ---------------------------------------------------------------------------
;;; Player state (reactive refs are the single source of truth)
;;; ---------------------------------------------------------------------------

(cl-defstruct (etaf-video-player--player (:constructor etaf-video-player--player--make))
  "Application state for one video player buffer."
  buffer handle pip-handle welcome
  ;; Structural refs read by the root shell:
  spec-ref queue-ref index-ref columns-ref rows-ref mode-ref
  theme-ref layout-ref stage-ref subtitle-on-ref left-open-ref right-open-ref
  aspect-ref pip-active-ref fullscreen-ref
  ;; Leaf refs never dereferenced by the root shell:
  speed-ref audio-ref volume-ref loop-ref shuffle-ref playing-ref progress-ref
  status-kind-ref ab-ref media-ref chapters-ref active-chapter-ref
  bookmarks-ref history-ref left-tab-ref right-tab-ref queue-filter-ref
  subtitle-file-ref subtitle-tracks-ref subtitle-offset-ref subtitle-scale-ref
  secondary-sid-ref engine-ref backend-ref hwdec-ref tracks-ref audio-delay-ref
  stop-after-ref rotate-ref mirror-ref deint-ref
  brightness-ref contrast-ref saturation-ref
  ;; Non-reactive runtime state & retained Host text caches:
  subtitle-vec shuffle-order history-at mpv-meta-at saved-drawers show-remaining
  ab-seek-at flash pip-size pip-corner pip-clock-text pip-subtitle-text
  hud-text clock-text duration-text volume-text subtitle-text context-text
  hud-timer sample sample-fps ended-seen explicit-grid scrubbing last-error)

(defun etaf-video-player--buffer-player ()
  "Return the player of the current buffer's application, or nil."
  (let ((state (etaf-app-state)))
    (and (etaf-video-player--player-p state) state)))

(defun etaf-video-player--current (&optional allow-welcome)
  "Return the current buffer's player, or signal `user-error'.
Unless ALLOW-WELCOME is non-nil, signal on the Welcome screen."
  (let ((player (or (etaf-video-player--buffer-player)
                    (user-error "Not an etaf-video-player buffer"))))
    (when (and (not allow-welcome) (etaf-video-player--player-welcome player))
      (user-error "No video loaded; press o to open a file or u for a URL"))
    player))

(defsubst etaf-video-player--spec (p) (etaf-value (etaf-video-player--player-spec-ref p)))
(defsubst etaf-video-player--queue (p) (etaf-value (etaf-video-player--player-queue-ref p)))
(defsubst etaf-video-player--index (p) (etaf-value (etaf-video-player--player-index-ref p)))
(defsubst etaf-video-player--mode (p) (etaf-value (etaf-video-player--player-mode-ref p)))
(defsubst etaf-video-player--loop (p) (etaf-value (etaf-video-player--player-loop-ref p)))
(defsubst etaf-video-player--shuffle (p) (etaf-value (etaf-video-player--player-shuffle-ref p)))
(defsubst etaf-video-player--speed (p) (etaf-value (etaf-video-player--player-speed-ref p)))
(defsubst etaf-video-player--audio (p) (etaf-value (etaf-video-player--player-audio-ref p)))
(defsubst etaf-video-player--volume (p) (etaf-value (etaf-video-player--player-volume-ref p)))
(defsubst etaf-video-player--subtitle-on (p) (etaf-value (etaf-video-player--player-subtitle-on-ref p)))
(defsubst etaf-video-player--subtitle-file (p) (etaf-value (etaf-video-player--player-subtitle-file-ref p)))
(defsubst etaf-video-player--subtitle-offset (p) (or (etaf-value (etaf-video-player--player-subtitle-offset-ref p)) 0.0))
(defsubst etaf-video-player--left-open (p) (etaf-value (etaf-video-player--player-left-open-ref p)))
(defsubst etaf-video-player--right-open (p) (etaf-value (etaf-video-player--player-right-open-ref p)))
(defsubst etaf-video-player--engine (p) (or (etaf-value (etaf-video-player--player-engine-ref p)) 'ffmpeg))
(defsubst etaf-video-player--mpv-p (p) (eq (etaf-video-player--engine p) 'mpv))
(defsubst etaf-video-player--columns (p)
  (or (etaf-value (etaf-video-player--player-columns-ref p)) etaf-video-player--initial-columns))
(defsubst etaf-video-player--rows (p)
  (or (etaf-value (etaf-video-player--player-rows-ref p)) etaf-video-player--initial-rows))

(defun etaf-video-player--clock (seconds)
  "Format SECONDS as a playback clock, or `--:--' when nil."
  (etaf-video-player--fmt-clock seconds))

(defun etaf-video-player--aspect (spec &optional override)
  "Return SPEC's effective video aspect ratio honoring OVERRIDE."
  (pcase override
    ("16:9" (/ 16.0 9))
    ("4:3" (/ 4.0 3))
    ("2.39:1" 2.39)
    (_ (let ((width (plist-get spec :width))
             (height (plist-get spec :height)))
         (if (and (numberp width) (numberp height) (> width 0) (> height 0))
             (/ (float width) height)
           (/ 16.0 9))))))

(defun etaf-video-player--active-handle (player)
  "Return PLAYER's mounted `etaf-video' handle (PiP when active, else main)."
  (if (and (etaf-video-player--player-pip-active-ref player)
           (etaf-value (etaf-video-player--player-pip-active-ref player)))
      (etaf-video-player--player-pip-handle player)
    (etaf-video-player--player-handle player)))

(defun etaf-video-player--state (player)
  "Return PLAYER's native video state as a detached plist."
  (etaf-video-state (etaf-video-player--active-handle player)))

(defun etaf-video-player--spec-target (spec)
  "Return the persistence/probe target (file path or URL) for SPEC, or nil."
  (pcase (plist-get spec :kind)
    ('file (plist-get spec :file))
    ('url (plist-get spec :url))))

(defun etaf-video-player--flash (player fmt &rest args)
  "Show a transient context-bar status message on PLAYER for 3.5 seconds."
  (let ((msg (apply #'format fmt args)))
    (setf (etaf-video-player--player-flash player) (cons msg (+ (float-time) 3.5)))
    (unless (etaf-video-player--player-welcome player)
      (etaf-video-player--player-render player))
    msg))

;;; ---------------------------------------------------------------------------
;;; Source validation, directory/.m3u expansion and lazy probing
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--url-p (value)
  "Return non-nil when VALUE is an HTTP(S) URL string."
  (and (stringp value) (string-match-p "\\`https?://[^[:space:]]+\\'" value)))

(defun etaf-video-player--video-file-p (path)
  "Return non-nil when PATH is a readable file with a video extension."
  (and (file-regular-p path)
       (file-readable-p path)
       (let ((ext (file-name-extension path)))
         (and ext (member (downcase ext) etaf-video-player--video-extensions)))))

(defun etaf-video-player--m3u-file-p (path)
  "Return non-nil when PATH is a readable local .m3u/.m3u8 playlist."
  (and (stringp path)
       (not (etaf-video-player--url-p path))
       (file-regular-p path)
       (file-readable-p path)
       (let ((ext (file-name-extension path)))
         (and ext (member (downcase ext) etaf-video-player--m3u-extensions)))))

(defun etaf-video-player--parse-m3u (file)
  "Parse local M3U/M3U8 playlist FILE into a list of source plists."
  (let ((base-dir (file-name-directory (expand-file-name file)))
        (pending-title nil)
        (entries nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position)))))
          (cond
           ((string-empty-p line))
           ((string-prefix-p "#EXTINF:" line)
            (when (string-match ",\\(.+\\)\\'" line)
              (setq pending-title (string-trim (match-string 1 line)))))
           ((string-prefix-p "#" line))
           ((etaf-video-player--url-p line)
            (push (append (list :url line)
                          (when pending-title (list :title pending-title)))
                  entries)
            (setq pending-title nil))
           (t
            (let ((resolved (expand-file-name line base-dir)))
              (when (and (file-readable-p resolved) (not (file-directory-p resolved)))
                (push (append (list :file resolved)
                              (when pending-title (list :title pending-title)))
                      entries)))
            (setq pending-title nil))))
        (forward-line 1)))
    (unless entries
      (user-error "No playable entries found in playlist: %s" file))
    (nreverse entries)))

(defun etaf-video-player--directory-videos (directory)
  "Return sorted readable video files in DIRECTORY, or signal `user-error'."
  (let ((files (cl-remove-if-not
                #'etaf-video-player--video-file-p
                (directory-files (expand-file-name directory) t "\\`[^.]"))))
    (unless files
      (user-error "No video files found in directory: %s" directory))
    (sort files #'string-lessp)))

(defun etaf-video-player--expand-sources (sources)
  "Expand directory and .m3u/.m3u8 entries in SOURCES into individual items."
  (cl-mapcan
   (lambda (entry)
     (let ((path (cond ((and (stringp entry) (not (etaf-video-player--url-p entry)))
                        entry)
                       ((and (consp entry) (stringp (plist-get entry :file))
                             (not (plist-member entry :kind)))
                        (plist-get entry :file)))))
       (cond
        ((and path (file-directory-p path))
         (mapcar (lambda (file) (list :file file))
                 (etaf-video-player--directory-videos path)))
        ((and path (etaf-video-player--m3u-file-p path))
         (etaf-video-player--parse-m3u path))
        (t (list entry)))))
   sources))

(defun etaf-video-player--pick-plist (plist keys)
  "Return a fresh plist containing only KEYS present in PLIST."
  (cl-loop for key in keys
           for tail = (plist-member plist key)
           when tail append (list key (cadr tail))))

(defun etaf-video-player--prepare-source (source)
  "Validate SOURCE without running ffprobe for deferred playlist entries."
  (cond
   ((or (null source)
        (and (consp source) (or (plist-member source :kind)
                                (eq (car source) :demo)
                                (plist-get source :demo))))
    (etaf-video-source-info source))
   ((etaf-video-player--url-p source)
    (list :kind 'url :url source :target source :audio-target source :unprobed t))
   ((stringp source)
    (let ((file (expand-file-name source)))
      (unless (and (file-readable-p file) (not (file-directory-p file)))
        (user-error "Video file is not readable: %S" file))
      (list :kind 'file :file file :target file :audio-target file :unprobed t)))
   ((and (consp source) (or (plist-get source :url) (plist-get source :file)))
    (let* ((url (plist-get source :url))
           (raw-file (plist-get source :file))
           (file (and (not url) (stringp raw-file) (expand-file-name raw-file)))
           (audio-url (plist-get source :audio-url))
           (proxy (plist-get source :proxy)))
      (if url
          (unless (etaf-video-player--url-p url)
            (user-error "Video URL must be http or https: %S" url))
        (unless (and file (file-readable-p file) (not (file-directory-p file)))
          (user-error "Video file is not readable: %S" raw-file)))
      (when (and audio-url (not (etaf-video-player--url-p audio-url)))
        (user-error "Video audio URL must be http or https: %S" audio-url))
      (when (and proxy (not (etaf-video-player--url-p proxy)))
        (user-error "Video proxy must be an http or https URL: %S" proxy))
      (append (if url
                  (list :kind 'url :url url :target url :audio-target (or audio-url url))
                (list :kind 'file :file file :target file :audio-target (or audio-url file)))
              (etaf-video-player--pick-plist
               source '(:title :audio-url :headers :proxy :width :height :duration :fps :audio :start))
              (list :unprobed t))))
   (t (user-error "Unsupported etaf-video source: %S" source))))

(defun etaf-video-player--probe-entry (entry)
  "Probe deferred playlist ENTRY with `etaf-video-source-info', once."
  (if (not (plist-get entry :unprobed))
      entry
    (let* ((kind (plist-get entry :kind))
           (title (plist-get entry :title))
           (probed
            (etaf-video-source-info
             (pcase kind
               ((or 'file 'url)
                (append (list (if (eq kind 'file) :file :url)
                              (plist-get entry (if (eq kind 'file) :file :url)))
                        (etaf-video-player--pick-plist
                         entry '(:audio-url :headers :proxy :start))))
               (_ entry)))))
      (if (and title (not (plist-get probed :title)))
          (append probed (list :title title))
        probed))))

(defun etaf-video-player--ensure-probed (player index)
  "Ensure playlist item INDEX in PLAYER is probed and return its spec."
  (let* ((queue (etaf-video-player--queue player))
         (entry (nth index queue)))
    (if (not (plist-get entry :unprobed))
        entry
      (let ((probed (etaf-video-player--probe-entry entry))
            (updated (copy-sequence queue)))
        (setf (nth index updated) probed)
        (etaf-set-value (etaf-video-player--player-queue-ref player) updated)
        probed))))

;;; ---------------------------------------------------------------------------
;;; Layout geometry, stage fitting, fringe and drag-and-drop
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--window (player)
  "Return a live window displaying PLAYER's buffer, or nil."
  (let ((buffer (etaf-video-player--player-buffer player)))
    (and buffer (buffer-live-p buffer) (get-buffer-window buffer t))))

(defun etaf-video-player--frame (player)
  "Return the frame showing PLAYER's buffer, or the selected frame."
  (if-let* ((window (etaf-video-player--window player)))
      (window-frame window)
    (selected-frame)))

(defun etaf-video-player--cell (&optional runtime)
  "Return the cell RUNTIME draws as (CHAR-WIDTH . LINE-HEIGHT) pixels."
  (let* ((buffer (and runtime (ignore-errors (etaf-runtime-buffer runtime))))
         (window (and buffer (buffer-live-p buffer)
                      (get-buffer-window buffer t)))
         (frame (if window (window-frame window) (selected-frame)))
         (metrics (ignore-errors
                    (if runtime (etaf-display-metrics runtime)
                      (etaf-display-metrics)))))
    (cons (max 1 (or (plist-get metrics :char-width) (frame-char-width frame)))
          (max 1 (or (plist-get metrics :line-height)
                     (frame-char-height frame))))))

(defun etaf-video-player--rows-for-columns (aspect columns &optional runtime)
  "Return the row count of an ASPECT frame COLUMNS cells wide."
  (let* ((cell (etaf-video-player--cell runtime))
         (scale (* aspect (/ (float (cdr cell)) (car cell)))))
    (max 1 (round (/ columns scale)))))

(defun etaf-video-player--columns-for-rows (aspect rows &optional runtime)
  "Return the column count of an ASPECT frame ROWS cells tall."
  (let* ((cell (etaf-video-player--cell runtime))
         (scale (* aspect (/ (float (cdr cell)) (car cell)))))
    (max 1 (round (* rows scale)))))

(defun etaf-video-player--stage-budget (viewport-width viewport-rows cell left-open right-open &optional fullscreen)
  "Compute responsive pane geometry for viewport, CELL, drawers and FULLSCREEN."
  (let* ((cw (max 1 (car cell)))
         (viewport-cols (max 1 (/ viewport-width cw)))
         (trans-rows (if fullscreen
                         (+ 2 (if (>= viewport-rows 14) 1 0)
                            (if (>= viewport-rows 8) 1 0))
                       etaf-video-player--bar-rows))
         (chrome-rows (if fullscreen (+ 1 trans-rows) etaf-video-player--chrome-rows))
         (body-rows (max 2 (- viewport-rows chrome-rows)))
         (can-sidebar (and (not fullscreen)
                           (>= viewport-cols etaf-video-player--sidebar-min-cols)))
         (can-aside (and (not fullscreen)
                         (>= viewport-cols etaf-video-player--aside-min-cols)
                         (>= body-rows etaf-video-player--aside-min-body-rows)))
         (sidebar (and can-sidebar left-open))
         (details (and can-aside right-open))
         (tier (cond ((>= viewport-cols etaf-video-player--aside-min-cols) 'wide)
                     ((>= viewport-cols etaf-video-player--sidebar-min-cols) 'medium)
                     (t 'compact)))
         (gutter (if fullscreen 0 etaf-video-player--gutter-cols))
         (stage-left-ch (if sidebar (+ etaf-video-player--sidebar-cols gutter) gutter))
         (stage-right-ch (if details (+ etaf-video-player--aside-cols gutter) gutter))
         (stage-width-px (max cw (- viewport-width (* (+ stage-left-ch stage-right-ch) cw)))))
    (list :sidebar sidebar :details details :can-sidebar can-sidebar :can-aside can-aside
          :tier tier :body-rows body-rows :trans-rows trans-rows
          :cols viewport-cols
          :stage-left-ch stage-left-ch :stage-right-ch stage-right-ch
          :stage-left-px (* stage-left-ch cw)
          :stage-width-px stage-width-px)))

(defun etaf-video-player--fit-grid
    (spec mode width-px height-rows cell &optional caption-row aspect-override)
  "Return (COLUMNS . ROWS) fitting SPEC in MODE inside WIDTH-PX by HEIGHT-ROWS."
  (let* ((aspect (etaf-video-player--aspect spec aspect-override))
         (cell-width (car cell))
         (cell-height (cdr cell))
         (usable-rows (if (and caption-row (> height-rows 2))
                          (1- height-rows)
                        (max 1 height-rows)))
         (available-width (float (max 1 width-px)))
         (available-height (float (max 1 (* usable-rows cell-height))))
         (fit-height (min available-height (/ available-width aspect)))
         (fit-width (* fit-height aspect))
         (columns (min (max 1 (floor fit-width cell-width))
                       (max 1 (floor available-width cell-width))))
         (rows (min (max 1 (floor fit-height cell-height)) usable-rows)))
    (if (and (eq mode 'color)
             (integerp etaf-video-player-color-columns)
             (> etaf-video-player-color-columns 0)
             (> columns etaf-video-player-color-columns))
        (let* ((limited (max 1 etaf-video-player-color-columns))
               (scale (* aspect (/ (float cell-height) cell-width))))
          (cons limited (min rows (max 1 (round (/ limited scale))))))
      (cons columns rows))))

(defun etaf-video-player--center-in-stage
    (grid stage-left stage-top stage-width stage-rows cell-width &optional caption-row)
  "Return centered (LEFT-PX . TOP-ROWS) for GRID inside the stage box."
  (let* ((usable-rows (if (and caption-row (> stage-rows 2))
                          (1- stage-rows)
                        stage-rows))
         (left (+ stage-left
                  (max 0 (floor (- stage-width (* (car grid) cell-width)) 2))))
         (top (+ stage-top
                 (max 0 (/ (- usable-rows (cdr grid)) 2)))))
    (cons left top)))

(defun etaf-video-player--fit-fringe (player &optional window)
  "Keep the player window's own fringe painted without touching the frame."
  (let* ((buffer (etaf-video-player--player-buffer player))
         (window (or window (etaf-video-player--window player))))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (face-remap-set-base 'fringe
                             :background (etaf-video-player-color :panel2)))
      (when (and window (window-live-p window) (display-graphic-p (window-frame window)))
        (let* ((left (car (window-fringes window)))
               (cell (car (etaf-video-player--cell (etaf-runtime-for-buffer buffer))))
               (width (- (window-pixel-width window) left))
               (rest (if (> cell 0) (mod width cell) 0)))
          (ignore-errors
            (set-window-fringes window left rest nil t)))))))

(defun etaf-video-player--caption-row-p (player)
  "Return non-nil when PLAYER reserves a bottom stage row for text captions.
On the libmpv engine subtitles render natively onto the video frame via libass."
  (and (etaf-video-player--subtitle-on player)
       (not (etaf-video-player--mpv-p player))))

(defun etaf-video-player--sync-layout (player)
  "Publish PLAYER's framework viewport and fit its canvas to the stage budget."
  (when-let* ((buffer (etaf-video-player--player-buffer player))
              (runtime (and (buffer-live-p buffer)
                            (etaf-runtime-for-buffer buffer)))
              (mounted (and runtime (etaf-runtime-mounted-p runtime))))
    (etaf-video-player--fit-fringe player)
    (let* ((raw-viewport (etaf-runtime-viewport runtime))
           (cur-layout (etaf-value (etaf-video-player--player-layout-ref player)))
           (committed-rows (cdr-safe cur-layout))
           (win (get-buffer-window buffer t))
           (viewport (if (and (consp raw-viewport)
                              (integerp committed-rows)
                              win (window-live-p win)
                              (etaf-transient-space-borrowed-p win committed-rows))
                         (cons (car raw-viewport) committed-rows)
                       raw-viewport))
           (vp-width (or (car-safe viewport) 0))
           (vp-rows (or (cdr-safe viewport) 0)))
      (when (and (> vp-width 0) (> vp-rows 0))
        (if (etaf-video-player--player-welcome player)
            (unless (equal viewport
                           (etaf-value (etaf-video-player--player-layout-ref player)))
              (etaf-set-value (etaf-video-player--player-layout-ref player) viewport))
          (let* ((cell (etaf-video-player--cell runtime))
                 (fullscreen (and (etaf-value (etaf-video-player--player-fullscreen-ref player)) t))
                 (budget (etaf-video-player--stage-budget
                          vp-width vp-rows cell
                          (etaf-video-player--left-open player)
                          (etaf-video-player--right-open player)
                          fullscreen))
                 (stage-width (plist-get budget :stage-width-px))
                 (stage-rows (plist-get budget :body-rows))
                 (caption-row (etaf-video-player--caption-row-p player))
                 (aspect-ov (etaf-value (etaf-video-player--player-aspect-ref player)))
                 (explicit (etaf-video-player--player-explicit-grid player))
                 (grid (if explicit
                           (cons (etaf-video-player--columns player)
                                 (etaf-video-player--rows player))
                         (etaf-video-player--fit-grid
                          (etaf-video-player--spec player)
                          (etaf-video-player--mode player)
                          stage-width stage-rows cell caption-row aspect-ov)))
                 (origin (etaf-video-player--center-in-stage
                          grid
                          (plist-get budget :stage-left-px)
                          etaf-video-player--stage-top-fallback
                          stage-width stage-rows (car cell) caption-row)))
            (etaf-batch
              (unless (equal viewport
                             (etaf-value (etaf-video-player--player-layout-ref player)))
                (etaf-set-value (etaf-video-player--player-layout-ref player) viewport))
              (unless (equal origin
                             (etaf-value (etaf-video-player--player-stage-ref player)))
                (etaf-set-value (etaf-video-player--player-stage-ref player) origin))
              (unless explicit
                (unless (eql (car grid) (etaf-value (etaf-video-player--player-columns-ref player)))
                  (etaf-set-value (etaf-video-player--player-columns-ref player) (car grid)))
                (unless (eql (cdr grid) (etaf-value (etaf-video-player--player-rows-ref player)))
                  (etaf-set-value (etaf-video-player--player-rows-ref player) (cdr grid)))))))))
    t))

(defun etaf-video-player--fit (player)
  "Fit PLAYER's canvas and panes synchronously when mounted."
  (let* ((buf (etaf-video-player--player-buffer player))
         (rt (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
    (cond
     ((and rt (etaf-runtime-mounted-p rt))
      (etaf-video-player--sync-layout player))
     (rt
      (etaf-next-tick (lambda () (etaf-video-player--sync-layout player))))
     (t
      (etaf-video-player--fit-fringe player)))))

(defun etaf-video-player--dnd-handle-uri (uri _action)
  "Handle dropped file URI (video, directory, .m3u or subtitle) in player."
  (let* ((path (dnd-get-local-file-name uri t))
         (ext (and path (file-name-extension path) (downcase (file-name-extension path))))
         (player (etaf-video-player--buffer-player)))
    (when (and path (file-exists-p path))
      (cond
       ((and ext (member ext etaf-video-player--sub-drop-extensions)
             player (not (etaf-video-player--player-welcome player)))
        (etaf-video-player-subtitle-load path))
       ((or (file-directory-p path) (file-readable-p path))
        (etaf-video-player-open (list :file path))))))
  'private)

(defun etaf-video-player--install-dnd (buffer)
  "Install buffer-local Finder/OS drag-and-drop handler on BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local dnd-protocol-alist
                  (cons '("^file:" . etaf-video-player--dnd-handle-uri)
                        dnd-protocol-alist)))))

;;; ---------------------------------------------------------------------------
;;; Retained status updates, libmpv telemetry sync, chapters and subtitles
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--sampled-fps (player state)
  "Update PLAYER's presented frame rate sample from STATE and return it."
  (let* ((now (float-time))
         (presented (plist-get state :presented))
         (sample (etaf-video-player--player-sample player))
         (fps (or (etaf-video-player--player-sample-fps player) 0.0)))
    (when (or (null sample) (>= (- now (car sample)) 0.5))
      (when sample
        (setq fps (/ (float (- presented (cdr sample)))
                     (max 0.001 (- now (car sample))))))
      (setf (etaf-video-player--player-sample player) (cons now presented)
            (etaf-video-player--player-sample-fps player) fps))
    fps))

(defun etaf-video-player--status-kind (state)
  "Return semantic status symbol for STATE."
  (cond ((plist-get state :error) 'error)
        ((plist-get state :ended) 'ended)
        ((plist-get state :buffering) 'buffering)
        ((plist-get state :playing) 'playing)
        (t 'paused)))

(defun etaf-video-player--hud (state)
  "Return the one-line status badge label for STATE."
  (pcase (etaf-video-player--status-kind state)
    ('error "✕ 出错")
    ('ended "已结束")
    ('buffering "◌ 缓冲中")
    ('playing "● 播放中")
    (_ "已暂停")))

(defun etaf-video-player--parse-mpv-tracks (raw-tracks &optional primary-sid)
  "Convert libmpv `track-list' node list RAW-TRACKS into normalized plists.
When PRIMARY-SID is an integer, only that subtitle id is marked `:selected'."
  (cl-loop for tr in raw-tracks
           for type-str = (cdr (assoc "type" tr))
           when (member type-str '("audio" "sub"))
           collect
           (let* ((id (cdr (assoc "id" tr)))
                  (is-sub (equal type-str "sub"))
                  (sel (if (and is-sub (integerp primary-sid))
                           (eql id primary-sid)
                         (and (cdr (assoc "selected" tr))
                              (or (not is-sub)
                                  (not (eql (cdr (assoc "main-selection" tr)) 1)))))))
             (list :id id
                   :type (if is-sub 'sub 'audio)
                   :lang (cdr (assoc "lang" tr))
                   :title (cdr (assoc "title" tr))
                   :codec (cdr (assoc "codec" tr))
                   :external (and (cdr (assoc "external" tr)) t)
                   :selected (and sel t)))))

(defun etaf-video-player--parse-mpv-chapters (raw-chapters duration)
  "Convert libmpv `chapter-list' node list RAW-CHAPTERS into normalized plists."
  (let ((count (length raw-chapters)))
    (cl-loop for idx from 0 below count
             for ch = (nth idx raw-chapters)
             for start = (float (or (cdr (assoc "time" ch)) 0.0))
             for next-start = (if (< (1+ idx) count)
                                  (float (or (cdr (assoc "time" (nth (1+ idx) raw-chapters))) start))
                                (float (or duration start)))
             for title = (or (cdr (assoc "title" ch)) (format "第 %d 章" (1+ idx)))
             collect (list :index idx :title (string-trim title)
                           :start start :end next-start))))

(defun etaf-video-player--sync-mpv-telemetry (player state)
  "Synchronize live tracks, chapters, hwdec and subtitle state from libmpv.
Expensive node-tree queries (`track-list' and `chapter-list') are throttled
once populated and refreshed immediately on track switches."
  (let* ((handle (etaf-video-player--active-handle player))
         (engine (or (plist-get state :engine) 'ffmpeg))
         (backend (plist-get state :render-backend)))
    (unless (eq engine (etaf-value (etaf-video-player--player-engine-ref player)))
      (etaf-set-value (etaf-video-player--player-engine-ref player) engine))
    (when (and backend
               (not (eq backend (etaf-value (etaf-video-player--player-backend-ref player)))))
      (etaf-set-value (etaf-video-player--player-backend-ref player) backend))
    (when (eq engine 'mpv)
      (let* ((now (float-time))
             (last-meta (etaf-video-player--player-mpv-meta-at player))
             (have-tracks (etaf-value (etaf-video-player--player-tracks-ref player)))
             (need-meta (or (null last-meta)
                            (null have-tracks)
                            (>= (- now last-meta) 2.0))))
        (when need-meta
          (setf (etaf-video-player--player-mpv-meta-at player) now)
          (let* ((raw-tracks (ignore-errors (etaf-video-get-property handle "track-list" 'node)))
                 (primary-sid (ignore-errors (etaf-video-get-property handle "sid" 'int)))
                 (secondary-sid (ignore-errors (etaf-video-get-property handle "secondary-sid" 'int)))
                 (tracks (and (listp raw-tracks)
                              (etaf-video-player--parse-mpv-tracks raw-tracks primary-sid)))
                 (raw-ch (ignore-errors (etaf-video-get-property handle "chapter-list" 'node)))
                 (dur (or (plist-get state :duration)
                          (plist-get (etaf-video-player--spec player) :duration)))
                 (chapters (and (listp raw-ch) (> (length raw-ch) 0)
                                (etaf-video-player--parse-mpv-chapters raw-ch dur)))
                 (hwdec (ignore-errors (etaf-video-get-property handle "hwdec-current" 'string)))
                 (sub-vis (ignore-errors (etaf-video-get-property handle "sub-visibility" 'bool)))
                 (has-sub-sel (cl-some (lambda (tr)
                                         (and (eq (plist-get tr :type) 'sub)
                                              (plist-get tr :selected)))
                                       tracks))
                 (sub-active (and sub-vis has-sub-sel t)))
            (unless (equal tracks have-tracks)
              (etaf-set-value (etaf-video-player--player-tracks-ref player) tracks))
            (let ((norm-sec (and (integerp secondary-sid) (> secondary-sid 0) secondary-sid)))
              (unless (equal norm-sec (etaf-value (etaf-video-player--player-secondary-sid-ref player)))
                (etaf-set-value (etaf-video-player--player-secondary-sid-ref player) norm-sec)))
            (when (and chapters
                       (not (equal chapters (etaf-value (etaf-video-player--player-chapters-ref player)))))
              (etaf-set-value (etaf-video-player--player-chapters-ref player) chapters))
            (unless (equal hwdec (etaf-value (etaf-video-player--player-hwdec-ref player)))
              (etaf-set-value (etaf-video-player--player-hwdec-ref player) hwdec))
            (unless (eq sub-active (etaf-video-player--subtitle-on player))
              (etaf-set-value (etaf-video-player--player-subtitle-on-ref player) sub-active))))))))

(defun etaf-video-player--active-chapters (player)
  "Return the active chapter list for PLAYER (libmpv live or ffprobe)."
  (or (etaf-value (etaf-video-player--player-chapters-ref player))
      (plist-get (etaf-value (etaf-video-player--player-media-ref player)) :chapters)))

(defun etaf-video-player--subtitle-display-text (player position)
  "Return the subtitle line PLAYER shows at POSITION on the ffmpeg backend."
  (let ((vec (etaf-video-player--player-subtitle-vec player)))
    (if (and vec (etaf-video-player--caption-row-p player))
        (or (etaf-video-player-subtitle-text-at
             vec (+ (or position 0) (etaf-video-player--subtitle-offset player)))
            "")
      "")))

(defun etaf-video-player--player-set-subtitle (player cues file)
  "Install CUES from FILE into PLAYER; empty or nil CUES clears the track."
  (let ((vec (and cues (> (length cues) 0) (vconcat cues))))
    (setf (etaf-video-player--player-subtitle-vec player) vec
          (etaf-video-player--player-subtitle-text player) nil)
    (etaf-batch
      (etaf-set-value (etaf-video-player--player-subtitle-file-ref player) (and vec file))
      (etaf-set-value (etaf-video-player--player-subtitle-offset-ref player) 0.0)
      (etaf-set-value (etaf-video-player--player-subtitle-on-ref player) (and vec t)))))

(defun etaf-video-player--player-adopt-subtitle (player spec)
  "Load matching subtitle beside SPEC and record all sibling subtitle tracks."
  (let* ((file (and (eq (plist-get spec :kind) 'file) (plist-get spec :file)))
         (tracks (and file (etaf-video-player-media-subtitles-for file)))
         (chosen (or (and file (etaf-video-player-subtitle-beside file))
                     (car tracks)))
         (cues (and chosen (ignore-errors (etaf-video-player-subtitle-parse chosen)))))
    (etaf-set-value (etaf-video-player--player-subtitle-tracks-ref player) tracks)
    (etaf-video-player--player-set-subtitle player cues chosen)))

(defun etaf-video-player--load-track-extras (player spec)
  "Refresh bookmarks, recent history and async ffprobe metadata for SPEC."
  (let ((target (etaf-video-player--spec-target spec)))
    (etaf-batch
      (etaf-set-value (etaf-video-player--player-bookmarks-ref player)
                      (and target (etaf-video-player-bookmarks target)))
      (etaf-set-value (etaf-video-player--player-history-ref player)
                      (etaf-video-player-history-recent 40))
      (etaf-set-value (etaf-video-player--player-media-ref player)
                      (and target (etaf-video-player-media-cached target)))
      (etaf-set-value (etaf-video-player--player-chapters-ref player) nil)
      (etaf-set-value (etaf-video-player--player-tracks-ref player) nil)
      (etaf-set-value (etaf-video-player--player-secondary-sid-ref player) nil)
      (etaf-set-value (etaf-video-player--player-active-chapter-ref player) nil))
    (when target
      (etaf-video-player-media-probe-async
       spec
       (etaf-video-player--screenshot-http-args spec)
       (lambda (probed-target info)
         (when (and info
                    (buffer-live-p (etaf-video-player--player-buffer player))
                    (not (etaf-video-player--player-welcome player))
                    (equal probed-target
                           (etaf-video-player--spec-target (etaf-video-player--spec player))))
           (etaf-set-value (etaf-video-player--player-media-ref player) info)
           (etaf-video-player--player-render player)))))))

(defun etaf-video-player--player-source-file (player)
  "Return the local file PLAYER is watching, or nil."
  (let ((spec (etaf-video-player--spec player)))
    (and (eq (plist-get spec :kind) 'file) (plist-get spec :file))))

(defun etaf-video-player--player-record-position (player state &optional force)
  "Save PLAYER's playback position from STATE (throttled unless FORCE)."
  (when-let* ((file (etaf-video-player--player-source-file player)))
    (let ((now (float-time))
          (position (or (plist-get state :position) 0)))
      (when (and (numberp position)
                 (>= position 0)
                 (or force
                     (and (> position 0)
                          (>= (- now (or (etaf-video-player--player-history-at player) 0))
                              etaf-video-player--history-interval))))
        (setf (etaf-video-player--player-history-at player) now)
        (etaf-video-player-history-record file position (plist-get state :duration))))))

(defun etaf-video-player--resume-position (spec)
  "Return a useful saved resume position for SPEC, or nil."
  (when (and (eq (plist-get spec :kind) 'file)
             (not (plist-member spec :start)))
    (when-let* ((file (plist-get spec :file))
                (record (etaf-video-player-history-position file))
                (position (car record))
                ((numberp position))
                ((> position etaf-video-player--resume-min-seconds)))
      (let ((duration (or (plist-get spec :duration) (cdr record))))
        (when (or (not (numberp duration))
                  (<= duration 0)
                  (< position (- duration etaf-video-player--resume-end-margin)))
          position)))))

(defun etaf-video-player--scrubbing-p (player &optional kind)
  "Return non-nil while PLAYER is actively scrubbing KIND (`seek' or `volume')."
  (let ((entry (etaf-video-player--player-scrubbing player)))
    (and (consp entry)
         (or (null kind) (eq (car entry) kind))
         (< (- (float-time) (cdr entry)) 3.0))))

(defun etaf-video-player--context-line (player position)
  "Return the left context-footer string for PLAYER at POSITION."
  (let* ((now (float-time))
         (flash (etaf-video-player--player-flash player)))
    (if (and flash (< now (cdr flash)))
        (car flash)
      (when flash (setf (etaf-video-player--player-flash player) nil))
      (let* ((ch (etaf-video-player-media-chapter-at
                  (etaf-video-player--active-chapters player) position))
             (ab (etaf-value (etaf-video-player--player-ab-ref player)))
             (ab-str (cond ((and (car ab) (cdr ab))
                            (format "A-B %s–%s"
                                    (etaf-video-player--clock (car ab))
                                    (etaf-video-player--clock (cdr ab))))
                           ((car ab)
                            (format "A 点 %s" (etaf-video-player--clock (car ab))))))
             (ch-str (when ch
                       (format "章节 %02d：%s" (1+ (plist-get ch :index))
                               (plist-get ch :title)))))
        (cond ((and ch-str ab-str) (format "%s · %s" ch-str ab-str))
              (ch-str ch-str)
              (ab-str (format "区间循环：%s" ab-str))
              (t (etaf-video-player--source-label (etaf-video-player--spec player))))))))

(defun etaf-video-player--duration-label (player position total)
  "Format the right timeline clock (total duration or remaining time)."
  (if (and (etaf-video-player--player-show-remaining player)
           (numberp total) (> total 0))
      (format "-%s" (etaf-video-player--clock (max 0 (- total (or position 0)))))
    (etaf-video-player--clock total)))

(defun etaf-video-player--publish-status (player runtime state duration)
  "Publish changed status Hosts of PLAYER through the retained boundary."
  (let* ((err (plist-get state :error))
         (position (or (plist-get state :position) 0))
         (total (or (plist-get state :duration) duration))
         (scrubbing-seek (etaf-video-player--scrubbing-p player 'seek))
         (scrubbing-vol (etaf-video-player--scrubbing-p player 'volume))
         (kind (etaf-video-player--status-kind state))
         (hud (etaf-video-player--hud state))
         (clock-text (etaf-video-player--clock position))
         (duration-text (etaf-video-player--duration-label player position total))
         (volume-text (format "%d%%" (round (etaf-video-player--volume player))))
         (caption-row (etaf-video-player--caption-row-p player))
         (subtitle-text (when caption-row
                          (etaf-video-player--subtitle-display-text player position)))
         (context-text (etaf-video-player--context-line player position))
         (ch (etaf-video-player-media-chapter-at
              (etaf-video-player--active-chapters player) position))
         (ch-idx (and ch (plist-get ch :index)))
         (updates nil))
    (unless (eq kind (etaf-value (etaf-video-player--player-status-kind-ref player)))
      (etaf-set-value (etaf-video-player--player-status-kind-ref player) kind))
    (unless (eql ch-idx (etaf-value (etaf-video-player--player-active-chapter-ref player)))
      (etaf-set-value (etaf-video-player--player-active-chapter-ref player) ch-idx))
    (when (and err (not (equal err (etaf-video-player--player-last-error player))))
      (setf (etaf-video-player--player-last-error player) err)
      (message "etaf-video-player: %s" err))
    (unless (equal hud (etaf-video-player--player-hud-text player))
      (setf (etaf-video-player--player-hud-text player) hud)
      (push (cons etaf-video-player--hud-ref hud) updates))
    (unless (or scrubbing-seek (equal clock-text (etaf-video-player--player-clock-text player)))
      (setf (etaf-video-player--player-clock-text player) clock-text)
      (push (cons etaf-video-player--time-ref clock-text) updates))
    (unless (equal duration-text (etaf-video-player--player-duration-text player))
      (setf (etaf-video-player--player-duration-text player) duration-text)
      (push (cons etaf-video-player--duration-ref duration-text) updates))
    (unless (or scrubbing-vol (equal volume-text (etaf-video-player--player-volume-text player)))
      (setf (etaf-video-player--player-volume-text player) volume-text)
      (push (cons etaf-video-player--volume-ref volume-text) updates))
    (when (and caption-row
               (not (equal subtitle-text (etaf-video-player--player-subtitle-text player))))
      (setf (etaf-video-player--player-subtitle-text player) subtitle-text)
      (push (cons etaf-video-player--subtitle-ref
                  (if (string-empty-p subtitle-text) " " subtitle-text))
            updates))
    (unless (equal context-text (etaf-video-player--player-context-text player))
      (setf (etaf-video-player--player-context-text player) context-text)
      (push (cons etaf-video-player--context-ref
                  (if (string-empty-p context-text) " " context-text))
            updates))
    (when (and updates runtime (etaf-runtime-mounted-p runtime))
      (let* ((vp (ignore-errors (etaf-runtime-viewport runtime)))
             (cw (max 1 (car (etaf-video-player--cell runtime))))
             (cols (max 24 (/ (or (car-safe vp) 960) cw)))
             (c-time (cond ((eq kind 'buffering) (if (< cols 44) "···" "··· 缓冲中"))
                           ((>= cols 52) (format "%s / %s" clock-text duration-text))
                           ((>= cols 30) clock-text)
                           (t "")))
             (all-updates (if (etaf-host-ref-position runtime etaf-video-player--cinema-time-ref)
                              (cons (cons etaf-video-player--cinema-time-ref c-time) updates)
                            updates))
             (present (cl-remove-if-not
                       (lambda (entry) (etaf-host-ref-position runtime (car entry)))
                       (nreverse all-updates))))
        (when present
          (etaf-runtime-update-host-contents runtime present))))
    (when-let* ((pbuf (etaf-pip-buffer etaf-video-player--pip-id))
                ((buffer-live-p pbuf))
                (prt (etaf-runtime-for-buffer pbuf))
                ((etaf-runtime-mounted-p prt)))
      (let* ((bounds (etaf-pip-bounds etaf-video-player--pip-id))
             (pcols (or (plist-get bounds :cols) 58))
             (p-time (cond ((eq kind 'buffering) (if (< pcols 44) "···" "··· 缓冲中"))
                           ((>= pcols 52) (format "%s / %s" clock-text duration-text))
                           ((>= pcols 30) clock-text)
                           (t "")))
             (p-sub (if (and caption-row (stringp subtitle-text)
                             (not (string-empty-p subtitle-text)))
                        (concat "CC  " subtitle-text)
                      ""))
             (p-updates nil))
        (unless (equal p-time (etaf-video-player--player-pip-clock-text player))
          (setf (etaf-video-player--player-pip-clock-text player) p-time)
          (when (etaf-runtime-host-props-for prt etaf-video-player--pip-time-ref)
            (push (cons etaf-video-player--pip-time-ref p-time) p-updates)))
        (unless (equal p-sub (etaf-video-player--player-pip-subtitle-text player))
          (setf (etaf-video-player--player-pip-subtitle-text player) p-sub)
          (when (etaf-runtime-host-props-for prt etaf-video-player--pip-subtitle-ref)
            (push (cons etaf-video-player--pip-subtitle-ref p-sub) p-updates)))
        (when p-updates
          (ignore-errors (etaf-runtime-update-host-contents prt p-updates)))))
    (unless scrubbing-seek
      (let ((pct (if (and (numberp total) (> total 0))
                     (/ (round (* 10.0 (max 0.0 (min 100.0 (* 100.0 (/ (float position) total))))))
                        10.0)
                   0.0)))
        (unless (eql pct (etaf-value (etaf-video-player--player-progress-ref player)))
          (etaf-set-value (etaf-video-player--player-progress-ref player) pct))))))

(defun etaf-video-player--sync-activity (player state)
  "Publish PLAYER's playback state to `etaf-activity-publish' when available."
  (when (fboundp 'etaf-activity-publish)
    (let* ((spec (etaf-video-player--spec player))
           (title (and spec (etaf-video-player--title spec)))
           (playing (and (plist-get state :playing) t))
           (pos (or (plist-get state :position) 0.0))
           (dur (or (plist-get state :duration) (plist-get spec :duration) 0.0))
           (raw-sec (max 0 (floor pos)))
           ;; Quantize to 2s buckets while playing so floating shells stay calm.
           (sec (if playing (* 2 (/ raw-sec 2)) raw-sec))
           (max-sec (max 1 (floor dur)))
           (act-state (if playing 'active 'paused))
           (existing (and (fboundp 'etaf-activity-get)
                          (etaf-activity-get 'etaf-video-player)))
           (existing-prog (and existing (plist-get existing :progress)))
           (buf (etaf-video-player--player-buffer player))
           (rt (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
      (when (and title
                 (not (and existing
                           (eq (plist-get existing :state) act-state)
                           (equal (plist-get existing :title) title)
                           (equal (plist-get existing-prog :value) sec)
                           (equal (plist-get existing-prog :max) max-sec))))
        (ignore-errors
          (etaf-activity-publish
           'etaf-video-player
           (list :app 'etaf-video-player
                 :kind 'media
                 :priority 80
                 :state act-state
                 :icon (if playing "▶" "⏸")
                 :title title
                 :compact title
                 :subtitle (format "%s · %s / %s"
                                   (etaf-video-player--source-label spec)
                                   (etaf-video-player--clock sec)
                                   (etaf-video-player--clock max-sec))
                 :progress (list :value sec :max max-sec :unit 'seconds)
                 :owner-runtime rt
                 :open (lambda ()
                         (when (buffer-live-p buf)
                           (pop-to-buffer buf)))
                 :actions
                 (list (list :id 'toggle
                             :label (if playing "⏸" "▶")
                             :fn (lambda ()
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (etaf-video-player-toggle-playback)))))
                       (list :id 'next
                             :label "下一条"
                             :fn (lambda ()
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (etaf-video-player-next)))))))))))))

(defun etaf-video-player--player-render (player)
  "Publish PLAYER's transport, status, mpv telemetry and A-B loop check."
  (unless (etaf-video-player--player-welcome player)
    (let* ((state (etaf-video-player--state player))
           (runtime (etaf-runtime-for-buffer (etaf-video-player--player-buffer player)))
           (playing (and (plist-get state :playing) t))
           (position (or (plist-get state :position) 0))
           (duration (plist-get (etaf-video-player--spec player) :duration))
           (ab (etaf-value (etaf-video-player--player-ab-ref player))))
      (etaf-video-player--sync-mpv-telemetry player state)
      (etaf-video-player--sampled-fps player state)
      (etaf-video-player--sync-activity player state)
      (when playing
        (etaf-video-player--player-record-position player state)
        ;; Software A-B fallback when running on the ffmpeg backend.
        (when (and (not (etaf-video-player--mpv-p player))
                   (car ab) (cdr ab) (>= position (cdr ab))
                   (> (- (float-time) (or (etaf-video-player--player-ab-seek-at player) 0)) 0.35))
          (setf (etaf-video-player--player-ab-seek-at player) (float-time))
          (ignore-errors
            (etaf-video-seek (etaf-video-player--active-handle player) (car ab)))))
      (unless (eq playing (etaf-value (etaf-video-player--player-playing-ref player)))
        (etaf-set-value (etaf-video-player--player-playing-ref player) playing))
      (when runtime
        (etaf-video-player--publish-status player runtime state duration))
      (if (plist-get state :ended)
          (unless (etaf-video-player--player-ended-seen player)
            (setf (etaf-video-player--player-ended-seen player) t)
            (when (and (not (plist-get state :error))
                       (buffer-live-p (etaf-video-player--player-buffer player)))
              (cond
               ((etaf-value (etaf-video-player--player-stop-after-ref player))
                (etaf-set-value (etaf-video-player--player-stop-after-ref player) nil)
                (etaf-video-player--flash player "本集已播完并自动暂停"))
               ((and (not (etaf-video-player--mpv-p player)) (car ab) (cdr ab))
                (let ((handle (etaf-video-player--active-handle player)))
                  (setf (etaf-video-player--player-ended-seen player) nil)
                  (ignore-errors (etaf-video-seek handle (car ab)))
                  (ignore-errors (etaf-video-play handle))))
               (t (etaf-video-player--player-advance player)))))
        (setf (etaf-video-player--player-ended-seen player) nil)))))

(defun etaf-video-player--stop-timer (player)
  "Cancel PLAYER's status refresh timer when active."
  (when-let* ((timer (etaf-video-player--player-hud-timer player)))
    (cancel-timer timer)
    (setf (etaf-video-player--player-hud-timer player) nil)))

(defun etaf-video-player--update-host (player ref text)
  "Update PLAYER's mounted retained Host REF to TEXT when present."
  (when-let* ((runtime (etaf-runtime-for-buffer (etaf-video-player--player-buffer player)))
              ((etaf-runtime-mounted-p runtime))
              ((etaf-host-ref-position runtime ref)))
    (etaf-runtime-update-host-content runtime ref text)))

(defun etaf-video-player--player-tick (player)
  "Refresh PLAYER's status line while its buffer is alive."
  (if (not (buffer-live-p (etaf-video-player--player-buffer player)))
      (etaf-video-player--stop-timer player)
    (condition-case problem
        (etaf-video-player--player-render player)
      ((error quit)
       (etaf-video-player--stop-timer player)
       (message "etaf-video-player: %s" (error-message-string problem))))))

;;; ---------------------------------------------------------------------------
;;; Player creation, shuffle and playlist selection
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--shuffle-list (items)
  "Return a fresh Fisher-Yates permutation of list ITEMS."
  (let* ((vec (vconcat items))
         (n (length vec)))
    (cl-loop for i from (1- n) downto 1 do
             (let* ((j (random (1+ i)))
                    (tmp (aref vec i)))
               (aset vec i (aref vec j))
               (aset vec j tmp)))
    (append vec nil)))

(defun etaf-video-player--rebuild-shuffle (player &optional keep-current avoid-first)
  "Build a fresh shuffle order over PLAYER's queue."
  (let* ((count (length (etaf-video-player--queue player)))
         (order (etaf-video-player--shuffle-list (number-sequence 0 (1- count)))))
    (cond
     ((and keep-current (> count 1))
      (let ((cur (etaf-video-player--index player)))
        (setq order (cons cur (delq cur order)))))
     ((and avoid-first (> count 1) (eql (car order) avoid-first))
      (setq order (append (cdr order) (list (car order))))))
    (setf (etaf-video-player--player-shuffle-order player) order)))

(defun etaf-video-player--shuffle-step (player delta wrap)
  "Return the index DELTA steps (+1 or -1) from current in shuffle order."
  (let* ((count (length (etaf-video-player--queue player)))
         (current (etaf-video-player--index player))
         (order (etaf-video-player--player-shuffle-order player)))
    (unless (and (= (length order) count) (memq current order))
      (setq order (etaf-video-player--rebuild-shuffle player t)))
    (let* ((pos (cl-position current order))
           (next-pos (+ pos delta)))
      (cond
       ((and (<= 0 next-pos) (< next-pos count)) (nth next-pos order))
       (wrap
        (let ((fresh (etaf-video-player--rebuild-shuffle player nil current)))
          (if (< delta 0) (car (last fresh)) (car fresh))))
       (t nil)))))

(cl-defun etaf-video-player--player-create
    (queue &key initial-spec welcome speed audio volume columns rows index loop shuffle mode
           left-open right-open)
  "Create a player for QUEUE, or the Welcome screen when WELCOME is non-nil."
  (let* ((idx (or index 0))
         (spec (unless welcome (or initial-spec (nth idx queue))))
         (mode (or mode etaf-video-player-render-mode))
         (init-engine (if (and (not welcome)
                               (not (eq (plist-get spec :kind) 'demo))
                               (eq mode 'image)
                               (display-graphic-p)
                               (not (eq etaf-video-engine 'ffmpeg))
                               (etaf-video-mpv-available-p))
                          'mpv
                        'ffmpeg))
         (player
          (etaf-video-player--player--make
           :handle (make-symbol "etaf-video-player")
           :pip-handle (make-symbol "etaf-video-player-pip")
           :welcome (and welcome t)
           :spec-ref (etaf-ref spec)
           :queue-ref (etaf-ref queue)
           :index-ref (etaf-ref idx)
           :columns-ref (etaf-ref columns)
           :rows-ref (etaf-ref rows)
           :mode-ref (etaf-ref mode)
           :theme-ref (etaf-ref (etaf-video-player-theme-defaults))
           :layout-ref (etaf-ref nil :test #'equal)
           :stage-ref (etaf-ref nil :test #'equal)
           :subtitle-on-ref (etaf-ref nil)
           :left-open-ref (etaf-ref (and left-open t))
           :right-open-ref (etaf-ref (and right-open t))
           :aspect-ref (etaf-ref 'auto :test #'equal)
           :pip-active-ref (etaf-ref nil)
           :fullscreen-ref (etaf-ref nil)
           :pip-size 'medium
           :pip-corner 'bottom-right
           :pip-clock-text "00:00"
           :pip-subtitle-text ""
           :speed-ref (etaf-ref (or speed 1))
           :audio-ref (etaf-ref (and audio t))
           :volume-ref (etaf-ref (or volume 100))
           :loop-ref (etaf-ref (or loop 'none))
           :shuffle-ref (etaf-ref (and shuffle t))
           :playing-ref (etaf-ref nil)
           :progress-ref (etaf-ref 0.0)
           :status-kind-ref (etaf-ref 'paused)
           :ab-ref (etaf-ref nil :test #'equal)
           :media-ref (etaf-ref nil :test #'equal)
           :chapters-ref (etaf-ref nil :test #'equal)
           :active-chapter-ref (etaf-ref nil)
           :bookmarks-ref (etaf-ref nil :test #'equal)
           :history-ref (etaf-ref (etaf-video-player-history-recent 40) :test #'equal)
           :left-tab-ref (etaf-ref 'queue)
           :right-tab-ref (etaf-ref 'controls)
           :queue-filter-ref (etaf-ref "")
           :subtitle-file-ref (etaf-ref nil)
           :subtitle-tracks-ref (etaf-ref nil :test #'equal)
           :subtitle-offset-ref (etaf-ref 0.0)
           :subtitle-scale-ref (etaf-ref 1.0)
           :secondary-sid-ref (etaf-ref nil)
           :engine-ref (etaf-ref init-engine)
           :backend-ref (etaf-ref (when (and (eq init-engine 'mpv)
                                             (fboundp 'etaf-video-gpu-available-p)
                                             (etaf-video-gpu-available-p)
                                             (memq etaf-video-render-backend '(gpu auto)))
                                    'gpu))
           :hwdec-ref (etaf-ref nil :test #'equal)
           :tracks-ref (etaf-ref nil :test #'equal)
           :audio-delay-ref (etaf-ref 0.0)
           :stop-after-ref (etaf-ref nil)
           :rotate-ref (etaf-ref 0)
           :mirror-ref (etaf-ref nil)
           :deint-ref (etaf-ref nil)
           :brightness-ref (etaf-ref 0)
           :contrast-ref (etaf-ref 0)
           :saturation-ref (etaf-ref 0)
           :hud-text "已暂停"
           :clock-text "00:00"
           :duration-text (etaf-video-player--clock (and spec (plist-get spec :duration)))
           :volume-text (format "%d%%" (round (or volume 100)))
           :context-text (if spec (etaf-video-player--source-label spec) "就绪"))))
    (when (and shuffle queue)
      (etaf-video-player--rebuild-shuffle player t))
    player))

(defun etaf-video-player--title (spec)
  "Return a short display title for normalized source SPEC."
  (or (let ((custom (plist-get spec :title)))
        (and (stringp custom) (not (string-empty-p custom)) custom))
      (pcase (plist-get spec :kind)
        ('file (file-name-nondirectory (or (plist-get spec :file) "")))
        ('url (or (plist-get spec :url) "stream"))
        (_ "内建演示"))))

(defun etaf-video-player--source-label (spec)
  "Return SPEC's one-line origin label."
  (pcase (plist-get spec :kind)
    ('file
     (let ((directory (file-name-directory (or (plist-get spec :file) ""))))
       (if (or (null directory) (string-empty-p directory))
           "本地文件"
         (let ((abbr (abbreviate-file-name (directory-file-name directory))))
           (if (<= (length abbr) 22)
               abbr
             (let* ((parts (split-string abbr "/" t))
                    (tail (last parts 2)))
               (concat "…/" (mapconcat #'identity tail "/"))))))))
    ('url (or (plist-get spec :url) "网络流"))
    (_ "内建演示")))

(defun etaf-video-player--reset-track-picture-state (player)
  "Reset per-track A-B, audio delay and transform refs for PLAYER."
  (etaf-batch
    (etaf-set-value (etaf-video-player--player-ab-ref player) nil)
    (etaf-set-value (etaf-video-player--player-audio-delay-ref player) 0.0)
    (etaf-set-value (etaf-video-player--player-subtitle-scale-ref player) 1.0)
    (etaf-set-value (etaf-video-player--player-rotate-ref player) 0)
    (etaf-set-value (etaf-video-player--player-mirror-ref player) nil)
    (etaf-set-value (etaf-video-player--player-deint-ref player) nil)
    (etaf-set-value (etaf-video-player--player-brightness-ref player) 0)
    (etaf-set-value (etaf-video-player--player-contrast-ref player) 0)
    (etaf-set-value (etaf-video-player--player-saturation-ref player) 0)))

(defun etaf-video-player--player-select (player index &optional play)
  "Show queue item INDEX in PLAYER, starting from the beginning."
  (let* ((count (length (etaf-video-player--queue player)))
         (index (max 0 (min (1- count) index)))
         (old-spec (etaf-video-player--spec player)))
    (ignore-errors
      (etaf-video-player--player-record-position
       player (etaf-video-player--state player) t))
    (let* ((spec (etaf-video-player--ensure-probed player index))
           (same-spec (equal old-spec spec))
           (handle (etaf-video-player--active-handle player)))
      (setf (etaf-video-player--player-ended-seen player) nil
            (etaf-video-player--player-last-error player) nil
            (etaf-video-player--player-scrubbing player) nil
            (etaf-video-player--player-ab-seek-at player) nil
            (etaf-video-player--player-mpv-meta-at player) nil)
      (etaf-video-player--reset-track-picture-state player)
      (etaf-video-player--player-adopt-subtitle player spec)
      (etaf-batch
        (etaf-set-value (etaf-video-player--player-spec-ref player) spec)
        (etaf-set-value (etaf-video-player--player-index-ref player) index))
      (when same-spec
        (ignore-errors (etaf-video-seek handle 0)))
      (when play
        (ignore-errors (etaf-video-play handle)))
      (when (etaf-pip-active-p etaf-video-player--pip-id)
        (etaf-pip-refresh-chrome etaf-video-player--pip-id))
      (etaf-video-player--load-track-extras player spec)
      (etaf-video-player--sync-layout player)
      (when-let* ((runtime (etaf-runtime-for-buffer
                            (etaf-video-player--player-buffer player))))
        (ignore-errors
          (etaf-scroll-into-view runtime (intern (format "video-track-%d" index)))))
      (etaf-video-player--player-render player)
      index)))

(defun etaf-video-player--player-advance (player)
  "Advance PLAYER after its current item ended, honoring loop and shuffle."
  (let* ((count (length (etaf-video-player--queue player)))
         (index (etaf-video-player--index player))
         (loop (etaf-video-player--loop player))
         (shuffle (etaf-video-player--shuffle player)))
    (if (eq loop 'one)
        (let ((handle (etaf-video-player--active-handle player)))
          (setf (etaf-video-player--player-ended-seen player) nil)
          (ignore-errors (etaf-video-seek handle 0))
          (ignore-errors (etaf-video-play handle))
          (etaf-video-player--player-render player))
      (let* ((wrap (eq loop 'all))
             (next (cond (shuffle (etaf-video-player--shuffle-step player 1 wrap))
                         (wrap (mod (1+ index) count))
                         ((< (1+ index) count) (1+ index)))))
        (when next
          (etaf-video-player--player-select player next t))))))

;;; ---------------------------------------------------------------------------
;;; View projections and Shell Component
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--playlist-entries (queue)
  "Return display entries for QUEUE with optional watched progress markers."
  (cl-loop for position from 0
           for item in queue
           for file = (and (eq (plist-get item :kind) 'file) (plist-get item :file))
           for rec = (and file (etaf-video-player-history-position file))
           for watched = (when (and rec (numberp (car rec)) (numberp (cdr rec)) (> (cdr rec) 0))
                           (let ((pct (min 100 (round (* 100.0 (/ (float (car rec)) (cdr rec)))))))
                             (when (>= pct 5)
                               (if (>= pct 95) "已看完" (format "%d%%" pct)))))
           collect (cons position
                         (list :title (etaf-video-player--title item)
                               :subtitle (etaf-video-player--source-label item)
                               :duration (etaf-video-player--clock (plist-get item :duration))
                               :watched watched))))

(defun etaf-video-player--queue-summary (queue index)
  "Return the bottom summary label for QUEUE at INDEX."
  (let ((count (length queue))
        (total (cl-loop for item in queue
                        for d = (plist-get item :duration)
                        when (numberp d) sum d)))
    (if (> total 0)
        (format "%d/%d · %s" (1+ index) count (etaf-video-player--clock total))
      (format "%d/%d" (1+ index) count))))

(defun etaf-video-player--effective-canvas-backend-p (frame)
  "Return non-nil when `etaf-video' uses the canvas backend on FRAME."
  (and (boundp 'etaf-video-render-backend)
       (memq etaf-video-render-backend '(canvas auto))
       (display-graphic-p frame)
       (image-type-available-p 'canvas)
       (fboundp 'etaf-video-canvas-read)))

(defun etaf-video-player--details-canvas (columns rows frame mode &optional backend)
  "Return the canvas rows for COLUMNS by ROWS on FRAME in MODE.
Optional BACKEND names the active rendering backend (`gpu', `canvas' or
`image')."
  (let* ((graphic (display-graphic-p frame))
         (effective (if (and (eq mode 'image) (not graphic)) 'ascii mode))
         (gpu-p (and (eq effective 'image)
                     (or (eq backend 'gpu)
                         (and (null backend)
                              (boundp 'etaf-video-render-backend)
                              (memq etaf-video-render-backend '(gpu auto))
                              (fboundp 'etaf-video-gpu-available-p)
                              (etaf-video-gpu-available-p)))))
         (canvas-p (and (eq effective 'image) (not gpu-p)
                        (or (eq backend 'canvas)
                            (etaf-video-player--effective-canvas-backend-p frame))))
         (ratio (or etaf-video-player-device-pixel-ratio
                    (and graphic (ignore-errors (frame-scale-factor frame))))))
    (list (cons "渲染" (cond (gpu-p "图像 (GPU 零拷贝)")
                             (canvas-p "图像 (canvas)")
                             ((eq effective 'image) "图像")
                             ((eq effective 'ascii) "字符")
                             ((eq effective 'color) "彩色字符")
                             (t (format "%s" effective))))
          (cons "画布" (format "%d × %d 格" columns rows))
          (cons "倍率" (cond ((not (eq effective 'image)) "—")
                             (gpu-p (if (numberp ratio) (format "%gx (Retina GPU)" ratio) "原生 GPU"))
                             (canvas-p "1x")
                             ((numberp ratio) (format "%gx" ratio))
                             (t "自动")))
          (cons "帧率上限" (if gpu-p "源帧率 (GPU 直通)"
                             (format "%d fps" etaf-video-player-display-fps))))))

(defun etaf-video-player--player-seek-relative (player delta)
  "Move PLAYER DELTA seconds from its current position and repaint."
  (let* ((state (etaf-video-player--state player))
         (position (or (plist-get state :position) 0))
         (duration (or (plist-get state :duration)
                       (plist-get (etaf-video-player--spec player) :duration)))
         (target (max 0 (if (numberp duration)
                            (min duration (+ position delta))
                          (+ position delta)))))
    (etaf-video-seek (etaf-video-player--active-handle player) target)
    (etaf-video-player--player-render player)))

(defun etaf-video-player--player-seek-percent (player percent)
  "Seek PLAYER to PERCENT of its duration and repaint."
  (setf (etaf-video-player--player-scrubbing player) nil)
  (let ((duration (or (plist-get (etaf-video-player--state player) :duration)
                      (plist-get (etaf-video-player--spec player) :duration))))
    (when (and (numberp duration) (> duration 0))
      (etaf-video-seek (etaf-video-player--active-handle player)
                       (* duration (/ (float percent) 100.0)))
      (etaf-video-player--player-render player))))

(defun etaf-video-player--preview-seek (player percent)
  "Update PLAYER's clock Host while dragging the progress bar without seeking."
  (setf (etaf-video-player--player-scrubbing player) (cons 'seek (float-time)))
  (let ((duration (plist-get (etaf-video-player--spec player) :duration)))
    (when (and (numberp duration) (> duration 0))
      (let ((clock (etaf-video-player--clock (* duration (/ (float percent) 100.0)))))
        (unless (equal clock (etaf-video-player--player-clock-text player))
          (setf (etaf-video-player--player-clock-text player) clock)
          (etaf-video-player--update-host player etaf-video-player--time-ref clock))))))

(defun etaf-video-player--preview-volume (player percent)
  "Update PLAYER's volume percentage Host while dragging the volume slider."
  (setf (etaf-video-player--player-scrubbing player) (cons 'volume (float-time)))
  (let ((text (format "%d%%" (round percent))))
    (unless (equal text (etaf-video-player--player-volume-text player))
      (setf (etaf-video-player--player-volume-text player) text)
      (etaf-video-player--update-host player etaf-video-player--volume-ref text))))

(defun etaf-video-player--ab-cycle-button (player)
  "Cycle A-B loop state from the transport pill: none -> A -> B -> clear."
  (let ((ab (etaf-value (etaf-video-player--player-ab-ref player))))
    (cond ((and (car ab) (cdr ab)) (etaf-video-player-clear-ab))
          ((car ab) (etaf-video-player-set-ab-end))
          (t (etaf-video-player-set-ab-start)))))

(defun etaf-video-player--set-aspect (player aspect)
  "Override PLAYER's video aspect ratio (`auto', `16:9', `4:3' or `2.39:1')."
  (etaf-set-value (etaf-video-player--player-aspect-ref player) aspect)
  (when (etaf-video-player--mpv-p player)
    (etaf-video-set-property (etaf-video-player--active-handle player)
                             "video-aspect-override"
                             (if (eq aspect 'auto) "-1" aspect)))
  (unless (etaf-video-player--player-explicit-grid player)
    (etaf-video-player--sync-layout player))
  (etaf-video-player--flash player "画面比例：%s" (if (eq aspect 'auto) "自动" aspect)))

(defun etaf-video-player--sync-mpv-vf (player)
  "Compose and apply libmpv's `vf' chain for rotation, mirror and color EQ.
Software rendering (`MPV_RENDER_API_TYPE_SW') executes libavfilter chains
reliably across platforms without relying on GPU shaders or `video-rotate'."
  (when (etaf-video-player--mpv-p player)
    (let* ((deg (or (etaf-value (etaf-video-player--player-rotate-ref player)) 0))
           (mirror (etaf-value (etaf-video-player--player-mirror-ref player)))
           (b (or (etaf-value (etaf-video-player--player-brightness-ref player)) 0))
           (c (or (etaf-value (etaf-video-player--player-contrast-ref player)) 0))
           (s (or (etaf-value (etaf-video-player--player-saturation-ref player)) 0))
           (filters
            (delq nil
                  (list
                   (pcase deg
                     (90 "transpose=1")
                     (180 "hflip,vflip")
                     (270 "transpose=2")
                     (_ nil))
                   (when mirror "hflip")
                   (when (or (/= b 0) (/= c 0) (/= s 0))
                     (format "eq=brightness=%.3f:contrast=%.3f:saturation=%.3f"
                             (/ (float b) 200.0)
                             (max 0.0 (+ 1.0 (/ (float c) 100.0)))
                             (max 0.0 (+ 1.0 (/ (float s) 100.0)))))))))
      (etaf-video-set-property (etaf-video-player--active-handle player)
                               "vf" (mapconcat #'identity filters ",")))))

(defun etaf-video-player--set-rotate (player degrees)
  "Rotate PLAYER's video output to DEGREES (0, 90, 180, 270) on libmpv."
  (let ((deg (mod (round degrees) 360)))
    (etaf-set-value (etaf-video-player--player-rotate-ref player) deg)
    (if (etaf-video-player--mpv-p player)
        (progn
          (etaf-video-player--sync-mpv-vf player)
          (etaf-video-player--flash player "画面旋转：%d°" deg))
      (etaf-video-player--flash player "画面旋转需要 libmpv 引擎"))))

(defun etaf-video-player--toggle-mirror (player)
  "Toggle horizontal mirror flip on PLAYER (libmpv)."
  (if (not (etaf-video-player--mpv-p player))
      (etaf-video-player--flash player "水平镜像需要 libmpv 引擎")
    (let ((next (not (etaf-value (etaf-video-player--player-mirror-ref player)))))
      (etaf-set-value (etaf-video-player--player-mirror-ref player) next)
      (etaf-video-player--sync-mpv-vf player)
      (etaf-video-player--flash player (if next "已开启水平镜像" "已关闭水平镜像")))))

(defun etaf-video-player--toggle-deinterlace (player)
  "Toggle deinterlacing on PLAYER (libmpv)."
  (if (not (etaf-video-player--mpv-p player))
      (etaf-video-player--flash player "去隔行需要 libmpv 引擎")
    (let ((next (not (etaf-value (etaf-video-player--player-deint-ref player)))))
      (etaf-set-value (etaf-video-player--player-deint-ref player) next)
      (etaf-video-set-property (etaf-video-player--active-handle player)
                               "deinterlace" next)
      (etaf-video-player--flash player (if next "已开启去隔行" "已关闭去隔行")))))

(defun etaf-video-player--adjust-eq (player prop delta)
  "Adjust libmpv color equalizer PROP by DELTA on PLAYER."
  (if (not (etaf-video-player--mpv-p player))
      (etaf-video-player--flash player "色彩均衡需要 libmpv 引擎")
    (let* ((ref (pcase prop
                  ('brightness (etaf-video-player--player-brightness-ref player))
                  ('contrast (etaf-video-player--player-contrast-ref player))
                  ('saturation (etaf-video-player--player-saturation-ref player))))
           (label (pcase prop
                    ('brightness "亮度")
                    ('contrast "对比度")
                    ('saturation "饱和度")))
           (next (max -100 (min 100 (+ (or (etaf-value ref) 0) delta)))))
      (etaf-set-value ref next)
      (etaf-video-player--sync-mpv-vf player)
      (etaf-video-player--flash player "%s：%+d" label next))))

(defun etaf-video-player--reset-video (player)
  "Reset aspect, rotation, mirror, deinterlace and color equalizer on PLAYER."
  (let ((handle (etaf-video-player--active-handle player)))
    (etaf-batch
      (etaf-set-value (etaf-video-player--player-aspect-ref player) 'auto)
      (etaf-set-value (etaf-video-player--player-rotate-ref player) 0)
      (etaf-set-value (etaf-video-player--player-mirror-ref player) nil)
      (etaf-set-value (etaf-video-player--player-deint-ref player) nil)
      (etaf-set-value (etaf-video-player--player-brightness-ref player) 0)
      (etaf-set-value (etaf-video-player--player-contrast-ref player) 0)
      (etaf-set-value (etaf-video-player--player-saturation-ref player) 0))
    (when (etaf-video-player--mpv-p player)
      (etaf-video-set-property handle "video-aspect-override" "-1")
      (etaf-video-set-property handle "vf" "")
      (etaf-video-set-property handle "deinterlace" nil))
    (unless (etaf-video-player--player-explicit-grid player)
      (etaf-video-player--sync-layout player))
    (etaf-video-player--flash player "已重置画面参数")))

(defun etaf-video-player--shift-audio-delay (player delta)
  "Shift libmpv audio delay by DELTA seconds on PLAYER."
  (if (not (etaf-video-player--mpv-p player))
      (etaf-video-player--flash player "音画延迟调节需要 libmpv 引擎")
    (let ((next (/ (round (* 10.0 (+ (or (etaf-value (etaf-video-player--player-audio-delay-ref player)) 0.0)
                                     delta)))
                   10.0)))
      (etaf-set-value (etaf-video-player--player-audio-delay-ref player) next)
      (etaf-video-set-property (etaf-video-player--active-handle player) "audio-delay" (float next))
      (etaf-video-player--flash player "音频延迟：%+.1f 秒" next))))

(defun etaf-video-player--scale-subtitle (player delta)
  "Adjust libmpv subtitle scale by DELTA on PLAYER."
  (when (etaf-video-player--mpv-p player)
    (let* ((cur (or (etaf-value (etaf-video-player--player-subtitle-scale-ref player)) 1.0))
           (next (max 0.4 (min 3.0 (/ (round (* 10.0 (+ cur delta))) 10.0)))))
      (etaf-set-value (etaf-video-player--player-subtitle-scale-ref player) next)
      (etaf-video-set-property (etaf-video-player--active-handle player) "sub-scale" (float next))
      (etaf-video-player--flash player "字幕字号：%.1fx" next))))

(etaf-define-component etaf-video-player--shell (&key player)
  "Render the Welcome launcher or Cinema/Studio player shell for PLAYER.
Leaf refs (speed, loop, shuffle, audio, volume, playing, progress, status-kind,
ab, media, chapters, tracks, hwdec, bookmarks, history, tabs, filter, video
equalizer/transforms, audio delay, stop-after) are passed by reference and
never read here, so interactive adjustments trigger zero root-shell re-renders."
  :bindings ((theme (etaf-video-player--player-theme-ref player)))
  :setup
  (etaf-theme-provide theme)
  :render
  (let* ((_palette (etaf-value theme))
         (layout (or (etaf-value (etaf-video-player--player-layout-ref player))
                     (ignore-errors (etaf-viewport))))
         (viewport-width (or (car-safe layout) 960))
         (viewport-rows (or (cdr-safe layout) 28)))
    (if (etaf-video-player--player-welcome player)
        (etaf-view
         (box :position 'relative :aria-label "视频播放器"
              :help "按 o 打开本地视频、目录或 .m3u 列表，按 u 打开网络流，或直接拖放文件到窗口。"
              :width (list 'px viewport-width)
              :height (list 'lh viewport-rows)
              :background-color (etaf-video-player-color :bg)
              :color (etaf-video-player-color :ink)
              :overflow 'hidden
           (etaf-video-player--view-welcome
            :mpv-available (etaf-video-mpv-available-p)
            :history-ref (etaf-video-player--player-history-ref player)
            :viewport-width viewport-width :viewport-rows viewport-rows
            :on-open-file (lambda () (call-interactively #'etaf-video-player-open-file))
            :on-open-url (lambda () (call-interactively #'etaf-video-player-open-url))
            :on-demo (lambda () (etaf-video-player-demo))
            :on-open-history (lambda (path)
                               (if (file-readable-p path)
                                   (etaf-video-player-open (list :file path))
                                 (message "文件不存在：%s" path)))
            :on-delete-history (lambda (path)
                                 (etaf-video-player-history-delete path)
                                 (etaf-set-value (etaf-video-player--player-history-ref player)
                                                 (etaf-video-player-history-recent 40)))
            :on-clear-history (lambda ()
                                (etaf-video-player-history-clear)
                                (etaf-set-value (etaf-video-player--player-history-ref player) nil))
            :on-toggle-theme (lambda () (etaf-video-player--toggle-theme))
            :on-help (lambda () (call-interactively #'etaf-help)))))
      (let* ((spec (etaf-value (etaf-video-player--player-spec-ref player)))
             (queue (etaf-value (etaf-video-player--player-queue-ref player)))
             (index (etaf-value (etaf-video-player--player-index-ref player)))
             (mode (etaf-value (etaf-video-player--player-mode-ref player)))
             (subtitle-on (etaf-value (etaf-video-player--player-subtitle-on-ref player)))
             (left-open (etaf-value (etaf-video-player--player-left-open-ref player)))
             (right-open (etaf-value (etaf-video-player--player-right-open-ref player)))
             (aspect-ov (etaf-value (etaf-video-player--player-aspect-ref player)))
             (pip-active (and (etaf-value (etaf-video-player--player-pip-active-ref player)) t))
             (fs-mode (etaf-value (etaf-video-player--player-fullscreen-ref player)))
             (fullscreen (and fs-mode t))
             (raw-columns (etaf-value (etaf-video-player--player-columns-ref player)))
             (raw-rows (etaf-value (etaf-video-player--player-rows-ref player)))
             (handle (etaf-video-player--player-handle player))
             (runtime (ignore-errors (etaf-current-runtime)))
             (cell (etaf-video-player--cell runtime))
             (budget (etaf-video-player--stage-budget
                      viewport-width viewport-rows cell left-open right-open fullscreen))
             (sidebar (plist-get budget :sidebar))
             (details (plist-get budget :details))
             (can-sidebar (plist-get budget :can-sidebar))
             (can-aside (plist-get budget :can-aside))
             (tier (plist-get budget :tier))
             (body-rows (plist-get budget :body-rows))
             (trans-rows (plist-get budget :trans-rows))
             (vp-cols (plist-get budget :cols))
             (stage-left-ch (plist-get budget :stage-left-ch))
             (stage-right-ch (plist-get budget :stage-right-ch))
             (caption-row (and subtitle-on
                               (not (eq (etaf-video-player--engine player) 'mpv))))
             (auto-grid (if (and (> viewport-width 0) (> viewport-rows 0))
                            (etaf-video-player--fit-grid
                             spec mode (plist-get budget :stage-width-px)
                             body-rows cell caption-row aspect-ov)
                          (cons etaf-video-player--initial-columns
                                etaf-video-player--initial-rows)))
             (columns (or raw-columns (car auto-grid)))
             (canvas-rows (or raw-rows (cdr auto-grid)))
             (auto-origin (if (and (> viewport-width 0) (> viewport-rows 0))
                              (etaf-video-player--center-in-stage
                               (cons columns canvas-rows)
                               (plist-get budget :stage-left-px)
                               etaf-video-player--stage-top-fallback
                               (plist-get budget :stage-width-px)
                               body-rows (car cell) caption-row)
                            (cons 0 etaf-video-player--stage-top-fallback)))
             (stage-origin (or (etaf-value (etaf-video-player--player-stage-ref player))
                               auto-origin))
             (stage-left-px (car stage-origin))
             (stage-top-rows (cdr stage-origin))
             ;; Leaf refs forwarded untouched:
             (speed (etaf-video-player--player-speed-ref player))
             (loop (etaf-video-player--player-loop-ref player))
             (shuffle (etaf-video-player--player-shuffle-ref player))
             (volume (etaf-video-player--player-volume-ref player))
             (audio (etaf-video-player--player-audio-ref player))
             (ab (etaf-video-player--player-ab-ref player))
             (media (etaf-video-player--player-media-ref player))
             (duration (plist-get spec :duration))
             (stage-left (list 'ch stage-left-ch))
             (stage-width (list 'calc (list '- (list 'px viewport-width)
                                            (list 'ch (+ stage-left-ch stage-right-ch)))))
             (details-left (list 'calc (list '- (list 'px viewport-width)
                                             (list 'ch (+ etaf-video-player--aside-cols
                                                          etaf-video-player--gutter-cols)))))
             (transport-top (+ 1 body-rows))
             (footer-top (+ transport-top etaf-video-player--bar-rows))
             (subtitle-top (min (+ stage-top-rows canvas-rows) body-rows))
             (clk (or (etaf-video-player--player-clock-text player) "00:00"))
             (dur-str (or (etaf-video-player--player-duration-text player)
                          (etaf-video-player--clock duration)))
             (cinema-time (cond ((>= vp-cols 52) (format "%s / %s" clk dur-str))
                                ((>= vp-cols 30) clk)
                                (t ""))))
        (etaf-view
         (box :position 'relative
              :on-direction #'etaf-video-player--direction
              :on-dismiss (when fullscreen
                            (lambda () (etaf-video-player--exit-fullscreen player)))
              :aria-label "视频播放器"
              :help "单视频默认剧场全宽；按 p 开关媒体栏，按 i 开关控制/轨道/画面栏，按 w 切换剧场模式，按 W/Z 切换纯净全屏，按 v/V 切换音轨与字幕，按 r 旋转画面。"
              :width (list 'px viewport-width)
              :height (list 'lh viewport-rows)
              :background-color (etaf-video-player-color :bg)
              :color (etaf-video-player-color :ink)
              :overflow 'hidden
           (etaf-video-player--view-header
            :if (not fullscreen)
            :position 'absolute :left '(px 0) :top '(lh 0)
            :width (list 'px viewport-width) :height '(lh 1)
            :title (etaf-video-player--title spec)
            :spec spec :media-ref media
            :status-kind-ref (etaf-video-player--player-status-kind-ref player)
            :status-ref etaf-video-player--hud-ref
            :status (etaf-video-player--player-hud-text player)
            :left-open sidebar :right-open details
            :can-sidebar can-sidebar :can-aside can-aside :tier tier
            :pip-active pip-active
            :on-toggle-left (lambda () (etaf-video-player-toggle-media-panel))
            :on-toggle-right (lambda () (etaf-video-player-toggle-inspector))
            :on-toggle-theater (lambda () (etaf-video-player-toggle-theater))
            :on-toggle-fullscreen (lambda () (etaf-video-player-toggle-fullscreen))
            :on-toggle-pip (lambda () (etaf-video-player-toggle-pip))
            :on-open-file (lambda () (call-interactively #'etaf-video-player-open-file))
            :on-toggle-theme (lambda () (etaf-video-player--toggle-theme))
            :on-help (lambda () (call-interactively #'etaf-help)))
           (etaf-video-player--view-cinema-topbar
            :if fullscreen
            :position 'absolute :left '(px 0) :top '(lh 0)
            :width (list 'px viewport-width) :height '(lh 1)
            :title (etaf-video-player--title spec)
            :index index :count (length queue)
            :cols vp-cols :fs-mode fs-mode
            :on-toggle-frame (lambda () (etaf-video-player-toggle-frame-fullscreen))
            :on-toggle-pip (lambda () (etaf-video-player-toggle-pip))
            :on-exit (lambda () (etaf-video-player--exit-fullscreen player)))
           (etaf-video-player--view-left-drawer
            :if sidebar :position 'absolute :left '(ch 0) :top '(lh 1)
            :width (list 'ch etaf-video-player--sidebar-cols)
            :height (list 'lh body-rows)
            :left-tab-ref (etaf-video-player--player-left-tab-ref player)
            :count (length queue)
            :entries (etaf-video-player--playlist-entries queue)
            :active index
            :total-label (etaf-video-player--queue-summary queue index)
            :filter-ref (etaf-video-player--player-queue-filter-ref player)
            :media-ref media
            :chapters-ref (etaf-video-player--player-chapters-ref player)
            :active-chapter-ref (etaf-video-player--player-active-chapter-ref player)
            :bookmarks-ref (etaf-video-player--player-bookmarks-ref player)
            :history-ref (etaf-video-player--player-history-ref player)
            :on-select-tab (lambda (tab)
                             (etaf-set-value (etaf-video-player--player-left-tab-ref player) tab)
                             (when (eq tab 'history)
                               (etaf-set-value (etaf-video-player--player-history-ref player)
                                               (etaf-video-player-history-recent 40))))
            :on-play (lambda (pos) (etaf-video-player-play-index pos))
            :on-enqueue (lambda () (call-interactively #'etaf-video-player-enqueue))
            :on-remove (lambda () (etaf-video-player--remove-current-command))
            :on-move-up (lambda () (etaf-video-player-move-up))
            :on-move-down (lambda () (etaf-video-player-move-down))
            :on-enqueue-siblings (lambda () (etaf-video-player-enqueue-siblings))
            :on-sort-queue (lambda () (etaf-video-player-sort-queue))
            :on-seek (lambda (sec) (etaf-video-player-seek sec))
            :on-bookmark-add (lambda () (call-interactively #'etaf-video-player-add-bookmark))
            :on-bookmark-remove (lambda (id)
                                  (etaf-video-player-bookmark-remove id)
                                  (let ((target (etaf-video-player--spec-target spec)))
                                    (etaf-set-value (etaf-video-player--player-bookmarks-ref player)
                                                    (and target (etaf-video-player-bookmarks target))))
                                  (etaf-video-player--flash player "已删除书签"))
            :on-history-open (lambda (path)
                               (if (file-readable-p path)
                                   (etaf-video-player-open (list :file path))
                                 (etaf-video-player--flash player "文件不存在：%s"
                                                           (file-name-nondirectory path))))
            :on-history-delete (lambda (path)
                                 (etaf-video-player-history-delete path)
                                 (etaf-set-value (etaf-video-player--player-history-ref player)
                                                 (etaf-video-player-history-recent 40)))
            :on-history-clear (lambda ()
                                (etaf-video-player-history-clear)
                                (etaf-set-value (etaf-video-player--player-history-ref player) nil)
                                (etaf-video-player--flash player "已清空观看历史")))
           (box :position 'absolute :left stage-left :top '(lh 1)
                :width stage-width :height (list 'lh body-rows)
                :overflow 'hidden :background-color (etaf-video-player-color :stage)
                :ref etaf-video-player--stage-ref
                :id (symbol-name etaf-video-player--stage-ref))
           (etaf-video-player--view-right-drawer
            :if details :position 'absolute :left details-left :top '(lh 1)
            :width (list 'ch etaf-video-player--aside-cols)
            :height (list 'lh body-rows)
            :right-tab-ref (etaf-video-player--player-right-tab-ref player)
            :title (etaf-video-player--title spec)
            :source (etaf-video-player--source-label spec)
            :spec spec :index index :count (length queue)
            :media-ref media
            :engine-ref (etaf-video-player--player-engine-ref player)
            :hwdec-ref (etaf-video-player--player-hwdec-ref player)
            :canvas (etaf-video-player--details-canvas
                     columns canvas-rows (etaf-video-player--frame player) mode
                     (etaf-value (etaf-video-player--player-backend-ref player)))
            :columns columns :rows canvas-rows :mode mode
            :speed-ref speed :ab-ref ab
            :stop-after-ref (etaf-video-player--player-stop-after-ref player)
            :tracks-ref (etaf-video-player--player-tracks-ref player)
            :audio-delay-ref (etaf-video-player--player-audio-delay-ref player)
            :subtitle-on-ref (etaf-video-player--player-subtitle-on-ref player)
            :subtitle-file-ref (etaf-video-player--player-subtitle-file-ref player)
            :subtitle-tracks-ref (etaf-video-player--player-subtitle-tracks-ref player)
            :subtitle-offset-ref (etaf-video-player--player-subtitle-offset-ref player)
            :subtitle-scale-ref (etaf-video-player--player-subtitle-scale-ref player)
            :secondary-sid-ref (etaf-video-player--player-secondary-sid-ref player)
            :aspect-ref (etaf-video-player--player-aspect-ref player)
            :rotate-ref (etaf-video-player--player-rotate-ref player)
            :mirror-ref (etaf-video-player--player-mirror-ref player)
            :deint-ref (etaf-video-player--player-deint-ref player)
            :brightness-ref (etaf-video-player--player-brightness-ref player)
            :contrast-ref (etaf-video-player--player-contrast-ref player)
            :saturation-ref (etaf-video-player--player-saturation-ref player)
            :on-select-tab (lambda (tab)
                             (etaf-set-value (etaf-video-player--player-right-tab-ref player) tab))
            :on-set-speed (lambda (sp) (etaf-video-player-set-speed sp))
            :on-set-a (lambda () (etaf-video-player-set-ab-start))
            :on-set-b (lambda () (etaf-video-player-set-ab-end))
            :on-clear-ab (lambda () (etaf-video-player-clear-ab))
            :on-toggle-stop-after (lambda () (etaf-video-player-toggle-stop-after-current))
            :on-step-back (lambda () (etaf-video-player-step-back))
            :on-step-fwd (lambda () (etaf-video-player-step))
            :on-screenshot (lambda () (etaf-video-player-save-screenshot))
            :on-copy-time (lambda () (etaf-video-player-copy-timestamp))
            :on-select-audio (lambda (id) (etaf-video-player-set-audio-track id))
            :on-shift-audio-delay (lambda (d) (etaf-video-player--shift-audio-delay player d))
            :on-reset-audio-delay (lambda ()
                                    (etaf-set-value (etaf-video-player--player-audio-delay-ref player) 0.0)
                                    (when (etaf-video-player--mpv-p player)
                                      (etaf-video-set-property (etaf-video-player--active-handle player) "audio-delay" 0.0))
                                    (etaf-video-player--flash player "音频延迟已重置"))
            :on-toggle-sub (lambda () (etaf-video-player--subtitle-toggle-command))
            :on-select-sub (lambda (id) (etaf-video-player-set-subtitle-track id))
            :on-select-secondary-sub (lambda (id) (etaf-video-player-set-secondary-subtitle id))
            :on-load-sub (lambda () (call-interactively #'etaf-video-player-subtitle-load))
            :on-shift-sub (lambda (delta) (etaf-video-player--subtitle-shift delta))
            :on-reset-sub (lambda ()
                            (etaf-set-value (etaf-video-player--player-subtitle-offset-ref player) 0.0)
                            (when (etaf-video-player--mpv-p player)
                              (etaf-video-set-property (etaf-video-player--active-handle player) "sub-delay" 0.0))
                            (etaf-video-player--flash player "字幕偏移已重置"))
            :on-scale-sub (lambda (d) (etaf-video-player--scale-subtitle player d))
            :on-set-aspect (lambda (a) (etaf-video-player--set-aspect player a))
            :on-set-rotate (lambda (deg) (etaf-video-player--set-rotate player deg))
            :on-toggle-mirror (lambda () (etaf-video-player--toggle-mirror player))
            :on-toggle-deint (lambda () (etaf-video-player--toggle-deinterlace player))
            :on-adjust-eq (lambda (prop d) (etaf-video-player--adjust-eq player prop d))
            :on-reset-video (lambda () (etaf-video-player--reset-video player))
            :on-set-mode (lambda (m) (etaf-video-player-set-render-mode m))
            :on-fit (lambda () (etaf-video-player-fit)))
           (flex :if pip-active :position 'absolute
                 :left stage-left :top '(lh 1)
                 :width stage-width :height (list 'lh body-rows)
                 :align-items 'center :justify-content 'center
                 :background-color (etaf-video-player-color :stage)
             (column :width (list 'ch (min 52 (max 24 (- (floor (plist-get budget :stage-width-px) (car cell)) 4))))
                     :padding '((lh 1) (ch 2)) :item-gap '(lh 1) :cross-align 'center
                     :background-color (etaf-video-player-color :panel2)
                     :border (etaf-video-player--border (etaf-video-player-color :accent))
               (text :color (etaf-video-player-color :accent) :font-weight 'bold
                 "📺 正在悬浮画中画中播放")
               (text :color (etaf-video-player-color :ink)
                 (expr (etaf-video-player--title spec)))
               (text :color (etaf-video-player-color :muted)
                 "拖拽画中画边框可自由缩放；按 P 回到主窗口")
               (flex :gap '((lh 0) (ch 2))
                 (etaf-button :label "回到主窗口 (P)" :variant 'primary
                              :on-press (lambda () (etaf-video-player--pip-return player)))
                 (etaf-button :label "关闭画中画" :variant 'secondary
                              :on-press (lambda () (etaf-video-player--pip-close player t))))))
           (etaf-video :if (not pip-active)
                       :position 'absolute
                       :ref 'video-canvas
                       :left (list 'px stage-left-px)
                       :top (list 'lh stage-top-rows)
                       :src spec :mode mode
                       :columns columns :rows canvas-rows
                       :speed speed :audio audio :volume volume
                       :device-pixel-ratio etaf-video-player-device-pixel-ratio
                       :display-fps etaf-video-player-display-fps
                       :autoplay t :handle handle
                       :on-press (lambda () (etaf-video-player-toggle-playback)))
           (box :if caption-row
                :position 'absolute :z-index 2
                :left stage-left :top (list 'lh subtitle-top)
                :width stage-width :height '(lh 1)
                :overflow 'hidden :text-align 'center
                :color (etaf-video-player-color :ink)
                :background-color (etaf-video-player-color :stage)
             (text :ref etaf-video-player--subtitle-ref
                   :id (symbol-name etaf-video-player--subtitle-ref)
               (expr (let ((line (etaf-video-player--player-subtitle-text player)))
                       (if (and (stringp line) (not (string-empty-p line))) line " ")))))
           (etaf-video-player--view-cinema-deck
            :if fullscreen
            :position 'absolute :left '(px 0) :top (list 'lh transport-top)
            :width (list 'px viewport-width) :height (list 'lh trans-rows)
            :px-w viewport-width :cols vp-cols :rows viewport-rows :cw (car cell)
            :gap-mid t
            :playing-ref (etaf-video-player--player-playing-ref player)
            :audio-ref audio :volume-ref volume :speed-ref speed
            :subtitle-on-ref (etaf-video-player--player-subtitle-on-ref player)
            :progress-ref (etaf-video-player--player-progress-ref player)
            :progress-fill-ref etaf-video-player--progress-fill-ref
            :progress-id 'etaf-video-player-progress
            :time-ref etaf-video-player--cinema-time-ref
            :time-text cinema-time
            :on-seek (lambda (pct) (etaf-video-player--player-seek-percent player pct))
            :on-toggle (lambda () (etaf-video-player-toggle-playback))
            :on-prev (lambda () (etaf-video-player-previous))
            :on-next (lambda () (etaf-video-player-next))
            :on-toggle-audio (lambda ()
                               (etaf-video-player-set-audio
                                (not (etaf-video-player--audio player))))
            :on-vol-delta (lambda (d)
                            (etaf-video-player-set-volume
                             (max 0 (min 100 (+ (etaf-video-player--volume player) d)))))
            :on-cycle-speed (lambda () (etaf-video-player-cycle-speed))
            :on-toggle-sub (lambda () (etaf-video-player--subtitle-toggle-command)))
           (etaf-video-player--view-transport
            :if (not fullscreen)
            :position 'absolute :left '(px 0) :top (list 'lh transport-top)
            :width (list 'px viewport-width) :height (list 'lh etaf-video-player--bar-rows)
            :progress (etaf-video-player--player-progress-ref player)
            :playing-ref (etaf-video-player--player-playing-ref player)
            :time (etaf-video-player--player-clock-text player)
            :duration (or (etaf-video-player--player-duration-text player)
                          (etaf-video-player--clock duration))
            :time-ref etaf-video-player--time-ref
            :duration-ref etaf-video-player--duration-ref
            :volume-ref etaf-video-player--volume-ref
            :volume-text (etaf-video-player--player-volume-text player)
            :audio-ref audio
            :progress-fill-ref etaf-video-player--progress-fill-ref
            :speed speed :loop loop :shuffle shuffle :volume volume
            :ab-ref ab :subtitle-on-ref (etaf-video-player--player-subtitle-on-ref player)
            :on-toggle (lambda () (etaf-video-player-toggle-playback))
            :on-previous (lambda () (etaf-video-player-previous))
            :on-next (lambda () (etaf-video-player-next))
            :on-forward (lambda () (etaf-video-player--player-seek-relative player 5))
            :on-backward (lambda () (etaf-video-player--player-seek-relative player -5))
            :on-step (lambda () (etaf-video-player-step))
            :on-toggle-remaining (lambda ()
                                   (setf (etaf-video-player--player-show-remaining player)
                                         (not (etaf-video-player--player-show-remaining player)))
                                   (etaf-video-player--player-render player))
            :on-bookmark (lambda () (call-interactively #'etaf-video-player-add-bookmark))
            :on-ab-cycle (lambda () (etaf-video-player--ab-cycle-button player))
            :on-toggle-sub (lambda () (etaf-video-player--subtitle-toggle-command))
            :on-screenshot (lambda () (etaf-video-player-save-screenshot))
            :on-cycle-speed (lambda () (etaf-video-player-cycle-speed))
            :on-toggle-loop (lambda () (etaf-video-player-toggle-loop))
            :on-toggle-shuffle (lambda () (etaf-video-player-toggle-shuffle))
            :on-toggle-audio (lambda ()
                               (etaf-video-player-set-audio
                                (not (etaf-video-player--audio player))))
            :on-volume-preview (lambda (percent)
                                 (etaf-video-player--preview-volume player percent))
            :on-volume (lambda (percent) (etaf-video-player-set-volume percent))
            :on-seek-preview (lambda (percent)
                               (etaf-video-player--preview-seek player percent))
            :on-seek (lambda (percent) (etaf-video-player--player-seek-percent player percent))
            :tier tier)
           (etaf-video-player--view-footer
            :if (not fullscreen)
            :position 'absolute :left '(px 0) :top (list 'lh footer-top)
            :width (list 'px viewport-width) :height '(lh 1)
            :context-ref etaf-video-player--context-ref
            :context (or (etaf-video-player--player-context-text player) " ")
            :hints (pcase tier
                     ('compact etaf-video-player--hint-line-compact)
                     ('medium etaf-video-player--hint-line-medium)
                     (_ etaf-video-player--hint-line)))))))))

(defun etaf-video-player--view (player)
  "Return the mountable View of PLAYER."
  (etaf-view (etaf-video-player--shell :player player
                                       :keys etaf-video-player--bindings)))

;;; ---------------------------------------------------------------------------
;;; Mode, theme, drawers and close lifecycle
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--player-set-mode (player mode)
  "Switch PLAYER to render MODE: `image', `ascii' or `color'."
  (unless (memq mode '(image ascii color))
    (user-error "Render mode must be `image', `ascii' or `color': %S" mode))
  (unless (eq mode (etaf-video-player--mode player))
    (etaf-set-value (etaf-video-player--player-mode-ref player) mode)
    (unless (etaf-video-player--player-explicit-grid player)
      (etaf-video-player--sync-layout player)))
  mode)

(defun etaf-video-player--toggle-theme ()
  "Switch the player between dark and light palettes."
  (let* ((player (etaf-video-player--current t))
         (next (if (eq etaf-video-player-theme-mode 'dark) 'light 'dark)))
    (setq etaf-video-player-theme-mode next)
    (etaf-set-value (etaf-video-player--player-theme-ref player)
                    (etaf-video-player-theme-defaults next))
    (etaf-video-player--fit-fringe player)
    (when (etaf-pip-active-p etaf-video-player--pip-id)
      (etaf-pip-refresh-chrome etaf-video-player--pip-id))
    t))

(defun etaf-video-player--player-close (player)
  "Release what PLAYER holds outside its View."
  (unless (etaf-video-player--player-welcome player)
    (ignore-errors
      (etaf-video-player--player-record-position
       player (etaf-video-player--state player) t)))
  (ignore-errors (etaf-video-player--exit-fullscreen player))
  (when (etaf-pip-active-p etaf-video-player--pip-id)
    (ignore-errors (etaf-pip-close etaf-video-player--pip-id nil)))
  (when (and (fboundp 'etaf-activity-get) (etaf-activity-get 'etaf-video-player))
    (ignore-errors (etaf-activity-remove 'etaf-video-player)))
  (etaf-video-player--stop-timer player))

(defun etaf-video-player--initial-drawers (layout count)
  "Return (LEFT-OPEN . RIGHT-OPEN) for requested LAYOUT and queue COUNT."
  (pcase (or layout etaf-video-player-default-layout)
    ('theater '(nil . nil))
    ('studio '(t . t))
    ('media '(t . nil))
    (_ (if (> count 1) '(t . nil) '(nil . nil)))))

;;; ---------------------------------------------------------------------------
;;; Public commands
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--open-welcome ()
  "Open the player buffer on the empty Welcome / Continue Watching home screen."
  (let* ((player (etaf-video-player--player-create nil :welcome t))
         (buffer
          (etaf-app-open
           etaf-video-player--buffer-name (etaf-video-player--view player)
           :state player
           :mode-line t
           :background (lambda ()
                         (plist-get (etaf-value
                                     (etaf-video-player--player-theme-ref player))
                                    :ui-shell-bg))
           :cursor nil
           :on-fit (lambda (_window) (etaf-video-player--fit player))
           :on-close (lambda () (etaf-video-player--player-close player)))))
    (setf (etaf-video-player--player-buffer player) buffer)
    (etaf-video-player--install-dnd buffer)
    (etaf-video-player--sync-layout player)
    buffer))

;;;###autoload
(defun etaf-video-player-open (&optional source)
  "Open the video player and return its buffer.
When SOURCE is nil (or called interactively), opens the Welcome and Continue
Watching launcher without starting a decoder.  SOURCE may also be a file name,
a directory of videos, a `.m3u'/`.m3u8' playlist, an HTTP(S) URL, or a plist:
`(:file PATH)', `(:url URL)', `(:demo)', or `(:playlist SOURCES ...)'.
Additional plist hints include `:columns', `:rows', `:speed', `:audio',
`:volume' (0 to 100), `:mode' (`image', `ascii' or `color'), `:layout'
(`auto', `theater', `media' or `studio'), `:index', `:loop' and `:shuffle'."
  (interactive)
  (if (null source)
      (etaf-video-player--open-welcome)
    (let* ((hints (and (consp source) source))
           (speed (or (plist-get hints :speed) 1))
           (audio (if (plist-member hints :audio)
                      (plist-get hints :audio)
                    etaf-video-player-audio))
           (volume (or (plist-get hints :volume) etaf-video-player-volume))
           (mode (or (plist-get hints :mode) etaf-video-player-render-mode))
           (loop (or (plist-get hints :loop) 'none))
           (shuffle (and (plist-get hints :shuffle) t))
           (layout-hint (plist-get hints :layout))
           (req-cols (plist-get hints :columns))
           (req-rows (plist-get hints :rows))
           (raw-sources (if (plist-member hints :playlist)
                            (plist-get hints :playlist)
                          (list source)))
           (sources (etaf-video-player--expand-sources raw-sources))
           (index (or (plist-get hints :index) 0))
           (queue (mapcar #'etaf-video-player--prepare-source sources)))
      (unless queue
        (user-error "A video player needs at least one item in its playlist"))
      (unless (and (integerp index) (<= 0 index) (< index (length queue)))
        (user-error "Playlist index is outside the queue: %S" index))
      (unless (memq mode '(image ascii color))
        (user-error "Render mode must be `image', `ascii' or `color': %S" mode))
      (unless (memq loop '(none all one))
        (user-error "Loop mode must be `none', `all' or `one': %S" loop))
      (unless (and (numberp speed) (> speed 0))
        (user-error "Playback speed must be a positive number: %S" speed))
      (unless (and (numberp volume) (<= 0 volume 100))
        (user-error "Audio volume must be between 0 and 100: %S" volume))
      (when (and (plist-member hints :columns)
                 (not (and (integerp req-cols) (> req-cols 0))))
        (user-error "Canvas columns must be a positive integer: %S" req-cols))
      (when (and (plist-member hints :rows)
                 (not (and (integerp req-rows) (> req-rows 0))))
        (user-error "Canvas rows must be a positive integer: %S" req-rows))
      (let* ((active-spec (etaf-video-player--probe-entry (nth index queue)))
             (queue (let ((copy (copy-sequence queue)))
                      (setf (nth index copy) active-spec)
                      copy))
             (resume-pos (etaf-video-player--resume-position active-spec))
             (initial-spec (if resume-pos
                               (append active-spec (list :start resume-pos))
                             active-spec))
             (explicit (or req-cols req-rows))
             (aspect (etaf-video-player--aspect active-spec))
             (init-cols (cond (req-cols req-cols)
                              (req-rows (etaf-video-player--columns-for-rows aspect req-rows))
                              (t nil)))
             (init-rows (cond (req-rows req-rows)
                              (req-cols (etaf-video-player--rows-for-columns aspect req-cols))
                              (t nil)))
             (drawers (etaf-video-player--initial-drawers layout-hint (length queue)))
             (player (etaf-video-player--player-create
                      queue
                      :initial-spec initial-spec
                      :speed speed :audio audio :volume volume :mode mode
                      :columns init-cols :rows init-rows
                      :index index :loop loop :shuffle shuffle
                      :left-open (car drawers) :right-open (cdr drawers))))
        (setf (etaf-video-player--player-explicit-grid player) (and explicit t))
        (etaf-video-player--player-adopt-subtitle player active-spec)
        (let ((buffer
               (etaf-app-open
                etaf-video-player--buffer-name (etaf-video-player--view player)
                :state player
                :mode-line t
                :background (lambda ()
                              (plist-get (etaf-value
                                          (etaf-video-player--player-theme-ref player))
                                         :ui-shell-bg))
                :cursor nil
                :on-fit (lambda (_window) (etaf-video-player--fit player))
                :on-close (lambda () (etaf-video-player--player-close player)))))
          (setf (etaf-video-player--player-buffer player) buffer)
          (etaf-video-player--install-dnd buffer)
          (condition-case problem
              (progn
                (etaf-video-player--sync-layout player)
                (etaf-video-player--load-track-extras player active-spec)
                (when resume-pos
                  (message "从 %s 继续播放" (etaf-video-player--clock resume-pos)))
                (setf (etaf-video-player--player-hud-timer player)
                      (run-at-time 0.0 etaf-video-player--hud-interval
                                   #'etaf-video-player--player-tick player))
                buffer)
            ((error)
             (etaf-app-close buffer)
             (signal (car problem) (cdr problem)))))))))

;;;###autoload
(defun etaf-video-player-open-file (file)
  "Play local video FILE, directory of videos, or .m3u/.m3u8 playlist."
  (interactive
   (list (read-file-name "Video file, directory or .m3u: " nil default-directory
                         (confirm-nonexistent-file-or-buffer))))
  (etaf-video-player-open (list :file file)))

;;;###autoload
(defun etaf-video-player-open-url (url)
  "Play HTTP(S) stream or yt-dlp supported video URL with sound."
  (interactive "sVideo URL: ")
  (etaf-video-player-open (list :url url)))

;;;###autoload
(defun etaf-video-player-demo ()
  "Play the built-in generated 30 second test pattern."
  (interactive)
  (etaf-video-player-open '(:demo)))

(defun etaf-video-player-close ()
  "Close the video player in the current buffer."
  (interactive)
  (etaf-video-player--current t)
  (etaf-app-close))

(defun etaf-video-player--exit-fullscreen (player)
  "Exit Pure Fullscreen for PLAYER, restoring mode-line, splits and frame."
  (let ((buf (etaf-video-player--player-buffer player)))
    (if (and buf (buffer-live-p buf))
        (progn
          (etaf-fullscreen-exit buf)
          (unless (null (etaf-value (etaf-video-player--player-fullscreen-ref player)))
            (etaf-batch
              (etaf-set-value (etaf-video-player--player-fullscreen-ref player) nil)
              (etaf-video-player--sync-layout player))))
      (etaf-set-value (etaf-video-player--player-fullscreen-ref player) nil)))
  nil)

(defun etaf-video-player--toggle-fullscreen (player &optional mode)
  "Toggle PLAYER's Pure Fullscreen MODE (`window' or `frame')."
  (let* ((target (or mode 'window))
         (buf (etaf-video-player--player-buffer player)))
    (if (and buf (buffer-live-p buf))
        (etaf-fullscreen-toggle
         target buf :hide-mode-line t
         :on-change (lambda (m)
                      (etaf-set-value (etaf-video-player--player-fullscreen-ref player) m)
                      (etaf-video-player--sync-layout player)))
      (let* ((cur (etaf-value (etaf-video-player--player-fullscreen-ref player)))
             (next (if (eq cur target) nil target)))
        (etaf-set-value (etaf-video-player--player-fullscreen-ref player) next)
        (etaf-video-player--sync-layout player)
        next))))

(defun etaf-video-player-toggle-fullscreen ()
  "Toggle in-window pure cinema fullscreen mode."
  (interactive)
  (etaf-video-player--toggle-fullscreen (etaf-video-player--current) 'window))

(defun etaf-video-player-toggle-frame-fullscreen ()
  "Toggle dedicated OS/frame fullscreen mode."
  (interactive)
  (etaf-video-player--toggle-fullscreen (etaf-video-player--current) 'frame))

(defun etaf-video-player-toggle-theater ()
  "Toggle Cinema Theater mode (collapse or restore both side drawers)."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (left (etaf-video-player--left-open player))
         (right (etaf-video-player--right-open player)))
    (when (etaf-value (etaf-video-player--player-fullscreen-ref player))
      (etaf-video-player--exit-fullscreen player))
    (if (or left right)
        (progn
          (setf (etaf-video-player--player-saved-drawers player) (cons left right))
          (etaf-batch
            (etaf-set-value (etaf-video-player--player-left-open-ref player) nil)
            (etaf-set-value (etaf-video-player--player-right-open-ref player) nil))
          (etaf-video-player--sync-layout player)
          (etaf-video-player--flash player "已进入剧场模式"))
      (let* ((saved (etaf-video-player--player-saved-drawers player))
             (restore-l (if (consp saved) (car saved) t))
             (restore-r (if (consp saved) (cdr saved) t)))
        (etaf-batch
          (etaf-set-value (etaf-video-player--player-left-open-ref player) restore-l)
          (etaf-set-value (etaf-video-player--player-right-open-ref player) restore-r))
        (etaf-video-player--sync-layout player)
        (etaf-video-player--flash player "已退出剧场模式")))
    t))

(defun etaf-video-player-toggle-media-panel ()
  "Toggle the left Media drawer (Queue, Chapters, Bookmarks, History)."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (next (not (etaf-video-player--left-open player))))
    (etaf-set-value (etaf-video-player--player-left-open-ref player) next)
    (when next
      (etaf-set-value (etaf-video-player--player-history-ref player)
                      (etaf-video-player-history-recent 40)))
    (etaf-video-player--sync-layout player)
    (etaf-video-player--flash player (if next "已展开媒体栏" "已收起媒体栏"))
    next))

(defun etaf-video-player-toggle-inspector ()
  "Toggle the right Studio drawer (Playback, Tracks, Video and Media Info)."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (next (not (etaf-video-player--right-open player))))
    (etaf-set-value (etaf-video-player--player-right-open-ref player) next)
    (etaf-video-player--sync-layout player)
    (etaf-video-player--flash player (if next "已展开控制与信息栏" "已收起控制与信息栏"))
    next))

(defun etaf-video-player-toggle-playback ()
  "Toggle the current player between playing and paused."
  (interactive)
  (let ((player (etaf-video-player--current)))
    (etaf-video-toggle-playback (etaf-video-player--active-handle player))
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-step ()
  "Pause the current player and present one frame forward."
  (interactive)
  (let ((player (etaf-video-player--current)))
    (etaf-video-step (etaf-video-player--active-handle player))
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-step-back ()
  "Pause the current player and step one frame backward."
  (interactive)
  (let ((player (etaf-video-player--current)))
    (etaf-video-step-back (etaf-video-player--active-handle player))
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-seek (seconds)
  "Move the current player to SECONDS."
  (interactive "nSeconds: ")
  (unless (numberp seconds)
    (user-error "Seek target must be a number in seconds: %S" seconds))
  (let ((player (etaf-video-player--current)))
    (etaf-video-seek (etaf-video-player--active-handle player) seconds)
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player--parse-time-input (input &optional position duration)
  "Parse INPUT into seconds: `SS', `MM:SS', `H:MM:SS', `50%' or `+15'/`-10'."
  (let ((s (string-trim (format "%s" input))))
    (cond
     ((string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)%\\'" s)
      (let ((pct (string-to-number (match-string 1 s))))
        (unless (and (numberp duration) (> duration 0))
          (user-error "Cannot jump by percentage when duration is unknown"))
        (* duration (/ (max 0.0 (min 100.0 pct)) 100.0))))
     ((string-match "\\`\\([+-]\\)\\(.+\\)\\'" s)
      (let* ((sign (if (string= (match-string 1 s) "-") -1 1))
             (mag (etaf-video-player--parse-time-input (match-string 2 s))))
        (max 0.0 (+ (or position 0.0) (* sign mag)))))
     ((string-match "\\`\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\'" s)
      (+ (* 3600 (string-to-number (match-string 1 s)))
         (* 60 (string-to-number (match-string 2 s)))
         (string-to-number (match-string 3 s))))
     ((string-match "\\`\\([0-9]+\\):\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\'" s)
      (+ (* 60 (string-to-number (match-string 1 s)))
         (string-to-number (match-string 2 s))))
     ((string-match "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" s)
      (string-to-number s))
     (t (user-error "Invalid time (use SS, MM:SS, H:MM:SS, 50%% or +15/-10): %s" s)))))

(defun etaf-video-player-goto-time (time)
  "Seek the current player to TIME (`SS', `MM:SS', `H:MM:SS', `50%' or `+15')."
  (interactive "sJump to time (MM:SS, 50%%, +30/-15): ")
  (let* ((player (etaf-video-player--current))
         (state (etaf-video-player--state player))
         (pos (or (plist-get state :position) 0.0))
         (dur (or (plist-get state :duration)
                  (plist-get (etaf-video-player--spec player) :duration)))
         (target (if (numberp time)
                     time
                   (etaf-video-player--parse-time-input time pos dur))))
    (etaf-video-player-seek target)
    (etaf-video-player--flash player "已跳转到 %s" (etaf-video-player--clock target))
    target))

(defun etaf-video-player-copy-timestamp ()
  "Copy the current playback timestamp (`MM:SS' or `H:MM:SS') to `kill-ring'."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (pos (or (plist-get (etaf-video-player--state player) :position) 0.0))
         (stamp (etaf-video-player--clock pos)))
    (kill-new stamp)
    (etaf-video-player--flash player "已复制时间戳：%s" stamp)
    stamp))

(defun etaf-video-player-toggle-stop-after-current ()
  "Toggle pausing automatically when the current video finishes."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (next (not (etaf-value (etaf-video-player--player-stop-after-ref player)))))
    (etaf-set-value (etaf-video-player--player-stop-after-ref player) next)
    (etaf-video-player--flash player (if next "已开启：播完当前集自动暂停" "已关闭：播完自动暂停"))
    next))

(defun etaf-video-player-set-ab-start (&optional seconds)
  "Set the A-B loop start point to SECONDS or the current playback position."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (pos (float (or seconds (plist-get (etaf-video-player--state player) :position) 0.0)))
         (ab (etaf-value (etaf-video-player--player-ab-ref player)))
         (b (and (cdr ab) (> (cdr ab) (+ pos 0.25)) (cdr ab))))
    (etaf-set-value (etaf-video-player--player-ab-ref player) (cons pos b))
    (when (etaf-video-player--mpv-p player)
      (let ((h (etaf-video-player--active-handle player)))
        (etaf-video-set-property h "ab-loop-a" pos)
        (unless b (etaf-video-set-property h "ab-loop-b" "no"))))
    (etaf-video-player--flash player "已设 A 点：%s" (etaf-video-player--clock pos))
    (cons pos b)))

(defun etaf-video-player-set-ab-end (&optional seconds)
  "Set the A-B loop end point to SECONDS or the current position.
When a complete A-B loop is already active and SECONDS is nil, clear it."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (ab (etaf-value (etaf-video-player--player-ab-ref player))))
    (if (and (null seconds) (car ab) (cdr ab))
        (etaf-video-player-clear-ab)
      (let* ((pos (float (or seconds (plist-get (etaf-video-player--state player) :position) 0.0)))
             (a (or (car ab) 0.0)))
        (unless (> pos (+ a 0.25))
          (user-error "A-B loop end (%s) must be after start (%s)"
                      (etaf-video-player--clock pos) (etaf-video-player--clock a)))
        (let ((pair (cons a pos)))
          (etaf-set-value (etaf-video-player--player-ab-ref player) pair)
          (when (etaf-video-player--mpv-p player)
            (let ((h (etaf-video-player--active-handle player)))
              (etaf-video-set-property h "ab-loop-a" a)
              (etaf-video-set-property h "ab-loop-b" pos)))
          (etaf-video-player--flash player "A-B 循环生效：%s – %s"
                                    (etaf-video-player--clock a)
                                    (etaf-video-player--clock pos))
          pair)))))

(defun etaf-video-player-clear-ab ()
  "Clear any active A-B loop range on the current player."
  (interactive)
  (let ((player (etaf-video-player--current)))
    (etaf-set-value (etaf-video-player--player-ab-ref player) nil)
    (setf (etaf-video-player--player-ab-seek-at player) nil)
    (when (etaf-video-player--mpv-p player)
      (let ((h (etaf-video-player--active-handle player)))
        (etaf-video-set-property h "ab-loop-a" "no")
        (etaf-video-set-property h "ab-loop-b" "no")))
    (etaf-video-player--flash player "已清除 A-B 循环")
    nil))

(defun etaf-video-player-add-bookmark (&optional note)
  "Save a persistent timestamp bookmark at the current playback position."
  (interactive (list (read-string "书签备注 (可留空): ")))
  (let* ((player (etaf-video-player--current))
         (spec (etaf-video-player--spec player))
         (target (etaf-video-player--spec-target spec))
         (pos (or (plist-get (etaf-video-player--state player) :position) 0.0)))
    (unless target
      (user-error "The built-in demo cannot store bookmarks"))
    (let ((bm (etaf-video-player-bookmark-add target pos note)))
      (etaf-set-value (etaf-video-player--player-bookmarks-ref player)
                      (etaf-video-player-bookmarks target))
      (etaf-video-player--flash player "已添加书签 %s%s"
                                (etaf-video-player--clock pos)
                                (if (and (stringp note) (not (string-empty-p (string-trim note))))
                                    (format " · %s" (string-trim note))
                                  ""))
      bm)))

(defun etaf-video-player--step-chapter (delta)
  "Jump DELTA chapters (+1 or -1) in the current video."
  (let* ((player (etaf-video-player--current))
         (chapters (etaf-video-player--active-chapters player)))
    (unless chapters
      (user-error "Current video has no embedded chapters"))
    (let* ((pos (or (plist-get (etaf-video-player--state player) :position) 0.0))
           (cur (etaf-video-player-media-chapter-at chapters pos))
           (idx (if cur (plist-get cur :index) 0))
           (target-idx (max 0 (min (1- (length chapters)) (+ idx delta))))
           (ch (nth target-idx chapters)))
      (etaf-video-player-seek (plist-get ch :start))
      (etaf-video-player--flash player "章节 %02d：%s"
                                (1+ target-idx) (plist-get ch :title))
      ch)))

(defun etaf-video-player-next-chapter ()
  "Jump to the next embedded chapter."
  (interactive)
  (etaf-video-player--step-chapter 1))

(defun etaf-video-player-previous-chapter ()
  "Jump to the previous embedded chapter."
  (interactive)
  (etaf-video-player--step-chapter -1))

(defun etaf-video-player-set-audio-track (track-id)
  "Select audio TRACK-ID (integer) on the current libmpv player."
  (interactive "nAudio track id: ")
  (let ((player (etaf-video-player--current)))
    (unless (etaf-video-player--mpv-p player)
      (user-error "Audio track switching requires the libmpv engine"))
    (etaf-video-set-property (etaf-video-player--active-handle player) "aid" track-id)
    (setf (etaf-video-player--player-mpv-meta-at player) nil)
    (etaf-video-player--player-render player)
    (etaf-video-player--flash player "已切换至音轨 #%d" track-id)
    track-id))

(defun etaf-video-player-cycle-audio-track ()
  "Cycle through available embedded audio tracks on libmpv."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (atracks (cl-remove-if-not (lambda (x) (eq (plist-get x :type) 'audio))
                                    (etaf-value (etaf-video-player--player-tracks-ref player)))))
    (unless (etaf-video-player--mpv-p player)
      (user-error "Audio track switching requires the libmpv engine"))
    (unless atracks
      (user-error "Current video has no selectable audio tracks"))
    (let* ((cur-idx (or (cl-position-if (lambda (x) (plist-get x :selected)) atracks) -1))
           (next (nth (mod (1+ cur-idx) (length atracks)) atracks)))
      (etaf-video-player-set-audio-track (plist-get next :id)))))

(defun etaf-video-player-set-subtitle-track (track-id)
  "Select primary subtitle TRACK-ID (integer or nil to hide) on libmpv."
  (interactive "nSubtitle track id: ")
  (let* ((player (etaf-video-player--current))
         (handle (etaf-video-player--active-handle player)))
    (unless (etaf-video-player--mpv-p player)
      (user-error "Track-id subtitle selection requires the libmpv engine"))
    (if track-id
        (progn
          (etaf-video-set-property handle "sid" track-id)
          (etaf-video-set-property handle "sub-visibility" t)
          (etaf-set-value (etaf-video-player--player-subtitle-on-ref player) t)
          (etaf-video-player--flash player "已切换至字幕轨 #%d" track-id))
      (etaf-video-set-property handle "sub-visibility" nil)
      (etaf-set-value (etaf-video-player--player-subtitle-on-ref player) nil)
      (etaf-video-player--flash player "已关闭字幕"))
    (setf (etaf-video-player--player-mpv-meta-at player) nil)
    (etaf-video-player--player-render player)
    track-id))

(defun etaf-video-player-set-secondary-subtitle (track-id)
  "Select bilingual secondary subtitle TRACK-ID (or nil to disable) on libmpv."
  (interactive "P")
  (let ((player (etaf-video-player--current)))
    (unless (etaf-video-player--mpv-p player)
      (user-error "Bilingual secondary subtitles require the libmpv engine"))
    (etaf-video-set-property (etaf-video-player--active-handle player)
                             "secondary-sid" (if track-id track-id "no"))
    (etaf-set-value (etaf-video-player--player-secondary-sid-ref player) track-id)
    (etaf-video-player--flash player (if track-id
                                         (format "已开启双语次字幕 #%d" track-id)
                                       "已关闭双语次字幕"))
    track-id))

(defun etaf-video-player-cycle-subtitle-track ()
  "Cycle through embedded and external subtitle tracks."
  (interactive)
  (let ((player (etaf-video-player--current)))
    (if (etaf-video-player--mpv-p player)
        (let ((stracks (cl-remove-if-not (lambda (x) (eq (plist-get x :type) 'sub))
                                         (etaf-value (etaf-video-player--player-tracks-ref player)))))
          (if (null stracks)
              (call-interactively #'etaf-video-player-subtitle-load)
            (let* ((cur-idx (or (cl-position-if (lambda (x) (plist-get x :selected)) stracks) -1))
                   (next (nth (mod (1+ cur-idx) (length stracks)) stracks)))
              (etaf-video-player-set-subtitle-track (plist-get next :id)))))
      (let* ((tracks (etaf-value (etaf-video-player--player-subtitle-tracks-ref player)))
             (cur (etaf-video-player--subtitle-file player)))
        (if (null tracks)
            (call-interactively #'etaf-video-player-subtitle-load)
          (let* ((pos (cl-position cur tracks :test #'equal))
                 (next (nth (if pos (mod (1+ pos) (length tracks)) 0) tracks)))
            (etaf-video-player-subtitle-load next)))))))

(defun etaf-video-player-rotate (&optional degrees)
  "Rotate video by DEGREES, or cycle 0° -> 90° -> 180° -> 270° -> 0°."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (cur (or (etaf-value (etaf-video-player--player-rotate-ref player)) 0))
         (next (if (numberp degrees) degrees (mod (+ cur 90) 360))))
    (etaf-video-player--set-rotate player next)
    next))

(defun etaf-video-player-set-render-mode (mode)
  "Switch the current player to render MODE (`image', `ascii' or `color')."
  (interactive
   (list (intern (completing-read "Render mode: " '("image" "ascii" "color")
                                  nil t nil nil
                                  (symbol-name etaf-video-player-render-mode)))))
  (let ((player (etaf-video-player--current)))
    (etaf-video-player--player-set-mode player mode)
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-cycle-render-mode ()
  "Cycle the current player through render modes."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (graphic (display-graphic-p (etaf-video-player--frame player)))
         (order (if graphic '(image ascii color) '(ascii color)))
         (current (if graphic
                      (etaf-video-player--mode player)
                    (or (plist-get (etaf-video-player--state player) :mode)
                        (etaf-video-player--mode player))))
         (next (or (cadr (memq current order)) (car order)))
         (label (pcase next ('image "图像") ('ascii "字符") ('color "彩色字符"))))
    (etaf-video-player--player-set-mode player next)
    (etaf-video-player--flash player "渲染方式：%s" label)
    (message "渲染方式：%s" label)
    next))

(defun etaf-video-player-set-speed (speed)
  "Set the current player's rate to SPEED, a positive number."
  (interactive "nPlayback speed: ")
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (let ((player (etaf-video-player--current)))
    (etaf-set-value (etaf-video-player--player-speed-ref player) speed)
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-set-volume (volume)
  "Set the current player's audio volume to VOLUME, from 0 to 100."
  (interactive "nAudio volume (0-100): ")
  (unless (and (numberp volume) (<= 0 volume 100))
    (user-error "Audio volume must be between 0 and 100: %S" volume))
  (let ((player (etaf-video-player--current)))
    (setf (etaf-video-player--player-scrubbing player) nil)
    (etaf-set-value (etaf-video-player--player-volume-ref player) volume)
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-set-audio (audio)
  "Turn the current player's audio on (non-nil) or off (nil)."
  (interactive "P")
  (let ((player (etaf-video-player--current)))
    (etaf-set-value (etaf-video-player--player-audio-ref player) (and audio t))
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-set-grid (columns rows)
  "Resize the current player's canvas to COLUMNS by ROWS cells."
  (interactive "nColumns: \nnRows: ")
  (unless (and (integerp columns) (> columns 0) (integerp rows) (> rows 0))
    (user-error "Canvas size must be positive integers: %S by %S" columns rows))
  (let ((player (etaf-video-player--current)))
    (setf (etaf-video-player--player-explicit-grid player) t)
    (unless (and (eql columns (etaf-value (etaf-video-player--player-columns-ref player)))
                 (eql rows (etaf-value (etaf-video-player--player-rows-ref player))))
      (etaf-batch
        (etaf-set-value (etaf-video-player--player-columns-ref player) columns)
        (etaf-set-value (etaf-video-player--player-rows-ref player) rows)))
    (etaf-video-player--sync-layout player)
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-fit ()
  "Fit the current player's canvas to the window showing it."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (window (etaf-video-player--window player)))
    (setf (etaf-video-player--player-explicit-grid player) nil)
    (unless window
      (user-error "The video player buffer is not shown in a window"))
    (etaf-video-player--sync-layout player)
    t))

(defun etaf-video-player--step-track (delta)
  "Step DELTA tracks (+1 or -1) in the current player, honoring shuffle."
  (let* ((player (etaf-video-player--current))
         (count (length (etaf-video-player--queue player)))
         (index (etaf-video-player--index player))
         (state (etaf-video-player--state player))
         (playing (or (plist-get state :playing) (plist-get state :ended)))
         (target (if (etaf-video-player--shuffle player)
                     (etaf-video-player--shuffle-step player delta t)
                   (mod (+ index delta) count))))
    (etaf-video-player--player-select player target playing))
  t)

(defun etaf-video-player-next ()
  "Play the next playlist item, wrapping to the first one at the end."
  (interactive)
  (etaf-video-player--step-track 1))

(defun etaf-video-player-previous ()
  "Play the previous playlist item, wrapping around at the first one."
  (interactive)
  (etaf-video-player--step-track -1))

(defun etaf-video-player-play-index (index)
  "Play playlist item INDEX, starting from the beginning."
  (interactive "nPlaylist index: ")
  (etaf-video-player--player-select (etaf-video-player--current) index t)
  t)

(defun etaf-video-player-enqueue (source)
  "Append SOURCE (file, directory or .m3u) to the current player's playlist."
  (interactive (list (read-file-name "Add video, directory or .m3u: " nil default-directory
                                     (confirm-nonexistent-file-or-buffer))))
  (let* ((player (etaf-video-player--current))
         (added (mapcar #'etaf-video-player--prepare-source
                        (etaf-video-player--expand-sources (list source))))
         (queue (append (etaf-video-player--queue player) added)))
    (etaf-set-value (etaf-video-player--player-queue-ref player) queue)
    (when (etaf-video-player--shuffle player)
      (etaf-video-player--rebuild-shuffle player t))
    (etaf-video-player--flash player "已加入队列 %d 项" (length added)))
  t)

(defun etaf-video-player-enqueue-siblings ()
  "Add all sibling video files from the active video's directory to the queue."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (file (etaf-video-player--player-source-file player)))
    (unless file
      (user-error "Sibling discovery requires a local video file"))
    (let* ((dir (file-name-directory file))
           (existing (mapcar (lambda (it) (plist-get it :file))
                             (etaf-video-player--queue player)))
           (siblings (cl-remove-if (lambda (f) (member f existing))
                                   (etaf-video-player--directory-videos dir)))
           (added (mapcar #'etaf-video-player--prepare-source siblings)))
      (if (null added)
          (etaf-video-player--flash player "同目录视频已全部在队列中")
        (etaf-set-value (etaf-video-player--player-queue-ref player)
                        (append (etaf-video-player--queue player) added))
        (when (etaf-video-player--shuffle player)
          (etaf-video-player--rebuild-shuffle player t))
        (etaf-video-player--flash player "已加入同目录 %d 个视频" (length added)))
      (length added))))

(defun etaf-video-player-sort-queue ()
  "Sort the current playlist alphabetically by title, preserving active item."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (queue (etaf-video-player--queue player))
         (active-item (nth (etaf-video-player--index player) queue))
         (sorted (sort (copy-sequence queue)
                       (lambda (a b)
                         (string-lessp (downcase (etaf-video-player--title a))
                                       (downcase (etaf-video-player--title b))))))
         (new-idx (or (cl-position active-item sorted :test #'eq) 0)))
    (etaf-batch
      (etaf-set-value (etaf-video-player--player-queue-ref player) sorted)
      (etaf-set-value (etaf-video-player--player-index-ref player) new-idx))
    (when (etaf-video-player--shuffle player)
      (etaf-video-player--rebuild-shuffle player t))
    (etaf-video-player--flash player "已按名称排序队列")
    t))

(defun etaf-video-player-remove (index)
  "Remove playlist item INDEX from the current player."
  (interactive "nRemove playlist index: ")
  (let* ((player (etaf-video-player--current))
         (queue (etaf-video-player--queue player))
         (count (length queue))
         (index (max 0 (min (1- count) index))))
    (when (<= count 1)
      (user-error "The playlist has only one item"))
    (let ((remaining (append (seq-take queue index) (seq-drop queue (1+ index))))
          (current (etaf-video-player--index player)))
      (etaf-set-value (etaf-video-player--player-queue-ref player) remaining)
      (if (= index current)
          (etaf-video-player--player-select
           player (min index (1- (length remaining)))
           (plist-get (etaf-video-player--state player) :playing))
        (when (> current index) (cl-decf current))
        (etaf-set-value (etaf-video-player--player-index-ref player) current)
        (etaf-video-player--player-render player))
      (when (etaf-video-player--shuffle player)
        (etaf-video-player--rebuild-shuffle player t))))
  t)

(defun etaf-video-player--remove-current-command ()
  "Remove the currently active item from the playlist."
  (let ((player (etaf-video-player--current)))
    (etaf-video-player-remove (etaf-video-player--index player))))

(defun etaf-video-player--move-item (delta)
  "Move the active playlist item by DELTA (-1 up, +1 down)."
  (let* ((player (etaf-video-player--current))
         (queue (copy-sequence (etaf-video-player--queue player)))
         (count (length queue))
         (idx (etaf-video-player--index player))
         (target (+ idx delta)))
    (when (and (> count 1) (<= 0 target) (< target count))
      (let ((tmp (nth idx queue)))
        (setf (nth idx queue) (nth target queue)
              (nth target queue) tmp))
      (etaf-batch
        (etaf-set-value (etaf-video-player--player-queue-ref player) queue)
        (etaf-set-value (etaf-video-player--player-index-ref player) target))
      (when (etaf-video-player--shuffle player)
        (etaf-video-player--rebuild-shuffle player t))
      (etaf-video-player--flash player "已移至第 %d 位" (1+ target)))
    t))

(defun etaf-video-player-move-up ()
  "Move the current item one position up in the playlist."
  (interactive)
  (etaf-video-player--move-item -1))

(defun etaf-video-player-move-down ()
  "Move the current item one position down in the playlist."
  (interactive)
  (etaf-video-player--move-item 1))

(defun etaf-video-player-toggle-loop ()
  "Cycle the current player's loop mode: none, all, one."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (next (pcase (etaf-video-player--loop player)
                 ('none 'all) ('all 'one) (_ 'none))))
    (etaf-set-value (etaf-video-player--player-loop-ref player) next)
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-toggle-shuffle ()
  "Toggle shuffle playback for the current player."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (next (not (etaf-video-player--shuffle player))))
    (etaf-set-value (etaf-video-player--player-shuffle-ref player) next)
    (if next
        (etaf-video-player--rebuild-shuffle player t)
      (setf (etaf-video-player--player-shuffle-order player) nil))
    (etaf-video-player--player-render player))
  t)

(defun etaf-video-player-state ()
  "Return the current player's state as a detached plist."
  (let ((player (etaf-video-player--current t)))
    (if (etaf-video-player--player-welcome player)
        (list :welcome t
              :engine (if (etaf-video-mpv-available-p) 'mpv 'ffmpeg)
              :source nil :playing nil :position 0 :duration nil
              :queue-length 0 :index 0 :ended nil)
      (let* ((state (etaf-video-player--state player))
             (spec (etaf-video-player--spec player)))
        (list :welcome nil
              :engine (or (plist-get state :engine) (etaf-video-player--engine player))
              :render-backend (or (plist-get state :render-backend)
                                  (etaf-value (etaf-video-player--player-backend-ref player)))
              :source (plist-get state :source)
              :playing (plist-get state :playing)
              :position (plist-get state :position)
              :duration (plist-get state :duration)
              :speed (plist-get state :speed)
              :columns (etaf-video-player--columns player)
              :rows (etaf-video-player--rows player)
              :mode (etaf-video-player--mode player)
              :render-mode (plist-get state :mode)
              :fps (plist-get state :display-fps)
              :presented-fps (or (etaf-video-player--player-sample-fps player) 0.0)
              :source-fps (plist-get state :source-fps)
              :source-width (plist-get spec :width)
              :source-height (plist-get spec :height)
              :received (plist-get state :received)
              :presented (plist-get state :presented)
              :dropped (plist-get state :dropped)
              :audio (etaf-video-player--audio player)
              :volume (etaf-video-player--volume player)
              :title (etaf-video-player--title spec)
              :queue-length (length (etaf-video-player--queue player))
              :index (etaf-video-player--index player)
              :loop (etaf-video-player--loop player)
              :shuffle (and (etaf-video-player--shuffle player) t)
              :stop-after-current (and (etaf-value (etaf-video-player--player-stop-after-ref player)) t)
              :ab-loop (etaf-value (etaf-video-player--player-ab-ref player))
              :theater (and (not (etaf-video-player--left-open player))
                            (not (etaf-video-player--right-open player)))
              :media-panel (and (etaf-video-player--left-open player) t)
              :inspector (and (etaf-video-player--right-open player) t)
              :chapters (length (etaf-video-player--active-chapters player))
              :bookmarks (length (etaf-value (etaf-video-player--player-bookmarks-ref player)))
              :tracks (etaf-value (etaf-video-player--player-tracks-ref player))
              :rotate (or (etaf-value (etaf-video-player--player-rotate-ref player)) 0)
              :aspect (etaf-value (etaf-video-player--player-aspect-ref player))
              :subtitle-file (etaf-video-player--subtitle-file player)
              :subtitle-on (and (etaf-video-player--subtitle-on player) t)
              :buffering (and (plist-get state :buffering) t)
              :error (plist-get state :error)
              :ended (plist-get state :ended))))))

;;; ---------------------------------------------------------------------------
;;; Key commands, subtitles and screenshot
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--forward-command ()
  "Seek five seconds forward."
  (etaf-video-player--player-seek-relative (etaf-video-player--current) 5))

(defun etaf-video-player--backward-command ()
  "Seek five seconds backward."
  (etaf-video-player--player-seek-relative (etaf-video-player--current) -5))

(defun etaf-video-player--forward-long-command ()
  "Seek thirty seconds forward."
  (etaf-video-player--player-seek-relative (etaf-video-player--current) 30))

(defun etaf-video-player--backward-long-command ()
  "Seek thirty seconds backward."
  (etaf-video-player--player-seek-relative (etaf-video-player--current) -30))

(defun etaf-video-player--restart-command ()
  "Restart the current video from position zero."
  (etaf-video-player-seek 0))

(defun etaf-video-player--direction (direction)
  "Seek the media with DIRECTION and return the result symbol."
  (pcase direction
    ('left (etaf-video-player--backward-command) 'handled)
    ('right (etaf-video-player--forward-command) 'handled)
    (_ 'release)))

(defun etaf-video-player--step-speed (direction &optional wrap)
  "Move the current player's speed one step in DIRECTION (`up' or `down')."
  (let* ((speed (etaf-video-player--speed (etaf-video-player--current)))
         (next (if (eq direction 'up)
                   (or (cl-find-if (lambda (c) (> c speed)) etaf-video-player--speeds)
                       (if wrap (car etaf-video-player--speeds)
                         (car (last etaf-video-player--speeds))))
                 (or (car (last (cl-remove-if (lambda (c) (>= c speed))
                                              etaf-video-player--speeds)))
                     (car etaf-video-player--speeds)))))
    (etaf-video-player-set-speed next)))

(defun etaf-video-player-cycle-speed ()
  "Cycle the current player through the supported playback rates."
  (interactive)
  (etaf-video-player--step-speed 'up t))

(defun etaf-video-player--speed-up-command ()
  "Raise the playback rate to the next supported value."
  (etaf-video-player--step-speed 'up))

(defun etaf-video-player--speed-down-command ()
  "Lower the playback rate to the next supported value."
  (etaf-video-player--step-speed 'down))

(defun etaf-video-player--speed-reset-command ()
  "Reset the playback rate to 1x."
  (etaf-video-player-set-speed 1))

(defun etaf-video-player--step-volume (delta)
  "Adjust the current player's volume by DELTA, clamped to 0..100."
  (let ((vol (etaf-video-player--volume (etaf-video-player--current))))
    (etaf-video-player-set-volume (max 0 (min 100 (+ vol delta))))))

(defun etaf-video-player--volume-up-command ()
  "Raise the audio volume by one step, capped at 100."
  (etaf-video-player--step-volume etaf-video-player--volume-step))

(defun etaf-video-player--volume-down-command ()
  "Lower the audio volume by one step, capped at 0."
  (etaf-video-player--step-volume (- etaf-video-player--volume-step)))

(defun etaf-video-player--toggle-audio-command ()
  "Toggle the current player's audio output."
  (etaf-video-player-set-audio (not (etaf-video-player--audio (etaf-video-player--current)))))

;;;###autoload
(defun etaf-video-player-subtitle-load (file)
  "Load external subtitle FILE (.srt, .vtt, .ass, .ssa) into the player."
  (interactive
   (list (read-file-name
          "字幕文件: "
          (let* ((player (etaf-video-player--buffer-player))
                 (spec (and player (not (etaf-video-player--player-welcome player))
                            (etaf-video-player--spec player))))
            (if (plist-get spec :file)
                (file-name-directory (plist-get spec :file))
              default-directory)))))
  (let* ((player (etaf-video-player--current))
         (expanded (expand-file-name file)))
    (if (etaf-video-player--mpv-p player)
        (progn
          (unless (file-readable-p expanded)
            (signal 'etaf-video-player-subtitle-error
                    (list (format "Subtitle file is not readable: %s" expanded))))
          (let ((h (etaf-video-player--active-handle player)))
            (etaf-video-command h "sub-add" expanded "select")
            (etaf-video-set-property h "sub-visibility" t))
          (etaf-batch
            (etaf-set-value (etaf-video-player--player-subtitle-file-ref player) expanded)
            (etaf-set-value (etaf-video-player--player-subtitle-on-ref player) t))
          (setf (etaf-video-player--player-mpv-meta-at player) nil)
          (etaf-video-player--player-render player)
          (etaf-video-player--flash player "字幕已加载：%s" (file-name-nondirectory expanded))
          (message "字幕已加载：%s" (file-name-nondirectory expanded))
          (ignore-errors (etaf-video-player-subtitle-parse expanded)))
      (let ((cues (etaf-video-player-subtitle-parse expanded)))
        (etaf-video-player--player-set-subtitle player cues expanded)
        (unless (etaf-video-player--player-explicit-grid player)
          (etaf-video-player--sync-layout player))
        (etaf-video-player--flash player "字幕已加载：%s（%d 条）"
                                  (file-name-nondirectory expanded) (length cues))
        (message "字幕已加载：%s（%d 条）" (file-name-nondirectory expanded) (length cues))
        cues))))

(defun etaf-video-player--subtitle-shift (delta)
  "Shift subtitle timing by DELTA seconds for the current player."
  (let* ((player (etaf-video-player--current))
         (next (+ (etaf-video-player--subtitle-offset player) delta)))
    (if (etaf-video-player--mpv-p player)
        (progn
          (etaf-set-value (etaf-video-player--player-subtitle-offset-ref player) next)
          (etaf-video-set-property (etaf-video-player--active-handle player)
                                   "sub-delay" (float (- next)))
          (etaf-video-player--flash player "字幕偏移：%+.1f 秒" next)
          (message "字幕偏移：%+.1f 秒" next))
      (unless (etaf-video-player--player-subtitle-vec player)
        (user-error "No subtitle track is loaded"))
      (etaf-set-value (etaf-video-player--player-subtitle-offset-ref player) next)
      (etaf-video-player--flash player "字幕偏移：%+.1f 秒" next)
      (message "字幕偏移：%+.1f 秒" next))))

(defun etaf-video-player--subtitle-earlier-command ()
  "Advance subtitles by 0.5 seconds."
  (etaf-video-player--subtitle-shift etaf-video-player--subtitle-offset-step))

(defun etaf-video-player--subtitle-later-command ()
  "Delay subtitles by 0.5 seconds."
  (etaf-video-player--subtitle-shift (- etaf-video-player--subtitle-offset-step)))

(defun etaf-video-player--subtitle-toggle-command ()
  "Toggle subtitles for the current player."
  (let ((player (etaf-video-player--current)))
    (if (etaf-video-player--mpv-p player)
        (let ((stracks (cl-remove-if-not (lambda (x) (eq (plist-get x :type) 'sub))
                                         (etaf-value (etaf-video-player--player-tracks-ref player))))
              (h (etaf-video-player--active-handle player)))
          (if stracks
              (let ((next (not (etaf-video-player--subtitle-on player))))
                (etaf-video-set-property h "sub-visibility" next)
                (when (and next (not (cl-some (lambda (x) (plist-get x :selected)) stracks)))
                  (etaf-video-set-property h "sid" (plist-get (car stracks) :id)))
                (etaf-set-value (etaf-video-player--player-subtitle-on-ref player) next)
                (etaf-video-player--flash player (if next "字幕已开启" "字幕已关闭"))
                (message (if next "字幕已开启" "字幕已关闭")))
            (call-interactively #'etaf-video-player-subtitle-load)))
      (let ((vec (etaf-video-player--player-subtitle-vec player))
            (file (etaf-video-player--subtitle-file player)))
        (if (and vec file)
            (let ((next (not (etaf-video-player--subtitle-on player))))
              (etaf-set-value (etaf-video-player--player-subtitle-on-ref player) next)
              (setf (etaf-video-player--player-subtitle-text player) nil)
              (unless (etaf-video-player--player-explicit-grid player)
                (etaf-video-player--sync-layout player))
              (if next
                  (progn
                    (etaf-video-player--flash player "字幕已开启：%s" (file-name-nondirectory file))
                    (message "字幕已开启：%s" (file-name-nondirectory file)))
                (etaf-video-player--flash player "字幕已关闭")
                (message "字幕已关闭")))
          (let* ((spec (etaf-video-player--spec player))
                 (beside (and (eq (plist-get spec :kind) 'file)
                              (etaf-video-player-subtitle-beside (plist-get spec :file)))))
            (if beside
                (etaf-video-player-subtitle-load beside)
              (call-interactively #'etaf-video-player-subtitle-load))))))))

(defun etaf-video-player--screenshot-http-args (spec)
  "Return ffmpeg/ffprobe HTTP input arguments for stream SPEC."
  (when (eq (plist-get spec :kind) 'url)
    (let* ((headers (plist-get spec :headers))
           (proxy (plist-get spec :proxy))
           (pairs (cond ((stringp headers)
                         (cl-loop for line in (split-string headers "\r\n" t)
                                  when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
                                  collect (cons (match-string 1 line) (match-string 2 line))))
                        ((hash-table-p headers)
                         (let (out)
                           (maphash (lambda (k v) (push (cons (format "%s" k) (format "%s" v)) out))
                                    headers)
                           (nreverse out)))
                        ((listp headers) headers)))
           user-agent rest)
      (dolist (pair pairs)
        (when (consp pair)
          (if (string= (downcase (car pair)) "user-agent")
              (setq user-agent (cdr pair))
            (push pair rest))))
      (append (when user-agent (list "-user_agent" user-agent))
              (when rest
                (list "-headers"
                      (mapconcat (lambda (p) (format "%s: %s\r\n" (car p) (cdr p)))
                                 (nreverse rest) "")))
              (when (and (stringp proxy) (not (string-empty-p proxy)))
                (list "-http_proxy" proxy))))))

;;;###autoload
(defun etaf-video-player-save-screenshot (&optional file)
  "Save the current video frame as a PNG image."
  (interactive)
  (let* ((player (etaf-video-player--current))
         (state (etaf-video-player--state player))
         (spec (etaf-video-player--spec player))
         (position (or (plist-get state :position) 0))
         (source (etaf-video-player--spec-target spec))
         (output (if file
                     (expand-file-name file)
                   (etaf-video-player--screenshot-output spec))))
    (unless source
      (user-error "The built-in demo has no frame to capture"))
    (if (and (etaf-video-player--mpv-p player)
             (let ((h (etaf-video-player--active-handle player)))
               (or (and (eql 0 (etaf-video-command h "screenshot-to-file" output "subtitles"))
                        (file-readable-p output))
                   (and (eql 0 (etaf-video-command h "screenshot-to-file" output "video"))
                        (file-readable-p output)))))
        (progn
          (etaf-video-player--flash player "截图已保存：%s" (file-name-nondirectory output))
          (message "截图已保存：%s" output))
      (etaf-process-run
       (append (list etaf-video-ffmpeg-program "-hide_banner" "-loglevel" "error")
               (etaf-video-player--screenshot-http-args spec)
               (list "-ss" (format "%.3f" position) "-i" source
                     "-frames:v" "1" "-y" output))
       :name "etaf-video-player-screenshot"
       :callback (lambda (result)
                   (if (and (eq (plist-get result :status) 'exit)
                            (eql (plist-get result :exit) 0)
                            (file-readable-p output))
                       (progn
                         (when (buffer-live-p (etaf-video-player--player-buffer player))
                           (etaf-video-player--flash player "截图已保存：%s"
                                                     (file-name-nondirectory output)))
                         (message "截图已保存：%s" output))
                     (let ((detail (string-trim
                                    (or (plist-get result :message)
                                        (plist-get result :stderr) ""))))
                       (message "截图失败：%s"
                                (if (string-empty-p detail)
                                    (format "ffmpeg %s %s" (plist-get result :status)
                                            (plist-get result :exit))
                                  detail)))))))
    output))

(defun etaf-video-player--screenshot-output (spec)
  "Return a non-colliding default PNG path for SPEC's current frame."
  (let* ((file-p (eq (plist-get spec :kind) 'file))
         (base (if file-p (file-name-base (plist-get spec :file)) "stream"))
         (dir (if file-p (file-name-directory (plist-get spec :file))
                temporary-file-directory))
         (stamp (format-time-string "%Y%m%d-%H%M%S"))
         (candidate (expand-file-name (format "%s-%s.png" base stamp) dir))
         (suffix 1))
    (while (file-exists-p candidate)
      (setq candidate (expand-file-name (format "%s-%s-%d.png" base stamp suffix) dir)
            suffix (1+ suffix)))
    candidate))

(defun etaf-video-player--preset-command ()
  "Apply the grid preset named by the key that invoked this command."
  (let* ((player (etaf-video-player--current))
         (key last-command-event)
         (columns (cdr (assq key etaf-video-player-grid-presets)))
         (runtime (etaf-runtime-for-buffer (etaf-video-player--player-buffer player))))
    (unless columns
      (user-error "No video player grid preset for %S" key))
    (etaf-video-player-set-grid
     columns
     (etaf-video-player--rows-for-columns
      (etaf-video-player--aspect (etaf-video-player--spec player)
                                 (etaf-value (etaf-video-player--player-aspect-ref player)))
      columns runtime))))

;;; ---------------------------------------------------------------------------
;;; Floating Adaptive Picture-in-Picture (PiP)
;;; ---------------------------------------------------------------------------

(defun etaf-video-player--in-buffer (player fn)
  "Invoke zero-argument FN with PLAYER's main buffer current."
  (when-let* ((buf (etaf-video-player--player-buffer player))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (funcall fn))))

(defun etaf-video-player--pip-theme-colors ()
  "Return `etaf-pip' theme color plist derived from the active palette."
  (let ((mode etaf-video-player-theme-mode))
    (list :bg (etaf-video-player-color :bg)
          :stage (etaf-video-player-color :stage)
          :panel (etaf-video-player-color :panel2)
          :chip (etaf-video-player-color :panel3)
          :hover (etaf-video-player-color :track)
          :ink (etaf-video-player-color :ink)
          :muted (etaf-video-player-color :muted)
          :accent (etaf-video-player-color :accent)
          :accent-soft (etaf-video-player-color :accent-soft)
          :border-inactive (if (eq mode 'light) "#CBD3E0" "#2D364A"))))

(defun etaf-video-player--pip-canvas-fit (spec aspect-ov cols rows cw lh)
  "Fit SPEC aspect inside COLS by ROWS without clamping over ROWS."
  (let* ((aspect (etaf-video-player--aspect spec aspect-ov))
         (avail-px (float (max cw (* cols cw))))
         (avail-py (float (max lh (* rows lh))))
         (fit-py (min avail-py (/ avail-px aspect)))
         (crows (max 1 (min rows (floor fit-py lh))))
         (fit-px (min avail-px (* crows lh aspect)))
         (ccols (max 4 (min cols (round (/ fit-px cw))))))
    (cons ccols crows)))

(defun etaf-video-player--pip-on-close (player)
  "Save final PiP progress and clear PLAYER's active PiP state."
  (when-let* ((st (ignore-errors
                    (etaf-video-state (etaf-video-player--player-pip-handle player)))))
    (ignore-errors (etaf-video-player--player-record-position player st t)))
  (etaf-set-value (etaf-video-player--player-pip-active-ref player) nil))

(defun etaf-video-player--pip-close (player &optional restore-focus)
  "Close `etaf-video-player' Picture-in-Picture window cleanly."
  (if (etaf-pip-active-p etaf-video-player--pip-id)
      (etaf-pip-close etaf-video-player--pip-id restore-focus)
    (when (etaf-value (etaf-video-player--player-pip-active-ref player))
      (etaf-video-player--pip-on-close player))))

(defun etaf-video-player--pip-return (player)
  "Close PiP and seamlessly resume playback in `*Video Player*'."
  (let* ((fr (etaf-pip-frame etaf-video-player--pip-id))
         (parent (and fr (frame-live-p fr) (frame-parent fr)))
         (st (ignore-errors
               (etaf-video-state (etaf-video-player--player-pip-handle player))))
         (pos (and st (plist-get st :position)))
         (spec (etaf-video-player--spec player))
         (buf (etaf-video-player--player-buffer player)))
    (etaf-video-player--pip-close player t)
    (when (and spec (numberp pos) (> pos 0.0))
      (etaf-set-value (etaf-video-player--player-spec-ref player)
                      (plist-put (copy-sequence spec) :start (float pos))))
    (etaf-set-value (etaf-video-player--player-pip-active-ref player) nil)
    (when (and parent (frame-live-p parent))
      (ignore-errors (select-frame-set-input-focus parent)))
    (when (and buf (buffer-live-p buf))
      (switch-to-buffer buf))))

(etaf-define-component etaf-video-player--pip-view (&key player)
  "Adaptive floating Picture-in-Picture player for `etaf-video-player'."
  :bindings ((theme (etaf-video-player--player-theme-ref player)))
  :setup (etaf-theme-provide theme)
  :render
  (let* ((_palette (etaf-value theme))
         (bounds (or (etaf-pip-bounds etaf-video-player--pip-id)
                     '(:width-px 464 :height-px 288 :cols 58 :rows 18 :cell-w 8 :cell-h 16)))
         (px-w (plist-get bounds :width-px))
         (cols (plist-get bounds :cols))
         (rows (plist-get bounds :rows))
         (cw (plist-get bounds :cell-w))
         (lh (plist-get bounds :cell-h))
         (full-time (>= cols 52))
         (show-time (>= cols 30))
         (hpad-cols (if (< cols 52) 1 2))
         (spec (etaf-value (etaf-video-player--player-spec-ref player)))
         (mode (etaf-value (etaf-video-player--player-mode-ref player)))
         (aspect-ov (etaf-value (etaf-video-player--player-aspect-ref player)))
         (sub-on (and (etaf-value (etaf-video-player--player-subtitle-on-ref player)) t))
         (caption-row (and sub-on (not (etaf-video-player--mpv-p player)) (>= rows 9)))
         (trans-rows (if (>= rows 8) 3 2))
         (vrows (max 2 (- rows (if caption-row 1 0) trans-rows)))
         (canvas (etaf-video-player--pip-canvas-fit spec aspect-ov cols vrows cw lh))
         (vpad-top (max 0 (/ (- vrows (cdr canvas)) 2)))
         (vpad-bot (max 0 (- vrows (cdr canvas) vpad-top)))
         (clk (or (etaf-video-player--player-clock-text player) "00:00"))
         (dur-str (or (etaf-video-player--player-duration-text player) "00:00"))
         (time-txt (cond (full-time (format "%s / %s" clk dur-str))
                         (show-time clk)
                         (t "")))
         (sub-txt (or (etaf-video-player--player-pip-subtitle-text player) ""))
         (on-toggle (lambda () (etaf-video-player--in-buffer player #'etaf-video-player-toggle-playback)))
         (on-prev (lambda () (etaf-video-player--in-buffer player #'etaf-video-player-previous)))
         (on-next (lambda () (etaf-video-player--in-buffer player #'etaf-video-player-next))))
    (etaf-view
     (column :width (list 'px px-w) :height (list 'lh rows)
             :item-gap '(lh 0) :overflow 'hidden
             :background-color (etaf-video-player-color :stage)
             :color (etaf-video-player-color :ink)
             :keys (list (list "SPC" on-toggle "播停")
                         (list "<" on-prev "上一个视频")
                         (list ">" on-next "下一个视频")
                         (list "j" (lambda () (etaf-video-player--player-seek-relative player -10)) "快退 10 秒")
                         (list "l" (lambda () (etaf-video-player--player-seek-relative player 10)) "快进 10 秒")
                         (list "b" (lambda () (etaf-video-player--player-seek-relative player -5)) "快退 5 秒")
                         (list "f" (lambda () (etaf-video-player--player-seek-relative player 5)) "快进 5 秒")
                         (list "[" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--volume-down-command)) "降低音量")
                         (list "]" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--volume-up-command)) "提高音量")
                         (list "m" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--toggle-audio-command)) "静音")
                         (list "a" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--toggle-audio-command)) "静音")
                         (list "+" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--speed-up-command)) "加速")
                         (list "=" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--speed-up-command)) "加速")
                         (list "-" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--speed-down-command)) "减速")
                         (list "." (lambda () (etaf-video-player--in-buffer player #'etaf-video-player-cycle-speed)) "切换倍速")
                         (list "c" (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--subtitle-toggle-command)) "开关字幕")
                         (list "s" (lambda () (etaf-pip-cycle-size etaf-video-player--pip-id)) "切换窗口大小")
                         (list "p" (lambda () (etaf-pip-cycle-corner etaf-video-player--pip-id)) "换角停靠")
                         (list "r" (lambda () (etaf-video-player--pip-return player)) "回到主窗口")
                         (list "P" (lambda () (etaf-video-player--pip-return player)) "回到主窗口")
                         (list "q" (lambda () (etaf-video-player--pip-close player t)) "关闭画中画"))
             :on-dismiss (lambda () (etaf-video-player--pip-close player t))
       ;; Adaptive Video Stage
       (column :width 'stretch :height (list 'lh vrows) :item-gap '(lh 0)
               :background-color (etaf-video-player-color :stage)
               :overflow 'hidden
               :border-top (etaf-video-player--border (etaf-video-player-color :line))
               :on-press on-toggle
         (box :if (> vpad-top 0)
              :width 'stretch :height (list 'lh vpad-top)
              :background-color (etaf-video-player-color :stage))
         (flex :width 'stretch :height (list 'lh (cdr canvas))
               :align-items 'center :justify-content 'center
               :background-color (etaf-video-player-color :stage)
               :overflow 'hidden
           (etaf-video :src spec :mode mode
                       :columns (car canvas) :rows (cdr canvas)
                       :speed (etaf-video-player--player-speed-ref player)
                       :audio (etaf-video-player--player-audio-ref player)
                       :volume (etaf-video-player--player-volume-ref player)
                       :device-pixel-ratio etaf-video-player-device-pixel-ratio
                       :display-fps etaf-video-player-display-fps
                       :autoplay t
                       :handle (etaf-video-player--player-pip-handle player)))
         (box :if (> vpad-bot 0)
              :width 'stretch :height (list 'lh vpad-bot)
              :background-color (etaf-video-player-color :stage)))
       ;; Optional 1-row CC Subtitle Strip (ffmpeg fallback)
       (box :if caption-row :width 'stretch :height '(lh 1)
            :padding (list '(lh 0) (list 'ch hpad-cols)) :text-align 'center
            :overflow 'hidden :wrap-mode 'none
            :background-color "#080A0F" :color "#F4F6FA"
         (text :ref etaf-video-player--pip-subtitle-ref
               :id (symbol-name etaf-video-player--pip-subtitle-ref)
           (expr sub-txt)))
       ;; Shared Adaptive Transport Deck (reused 1:1 with Pure Fullscreen!)
       (etaf-video-player--view-cinema-deck
        :px-w px-w :cols cols :rows rows :cw cw
        :playing-ref (etaf-video-player--player-playing-ref player)
        :audio-ref (etaf-video-player--player-audio-ref player)
        :volume-ref (etaf-video-player--player-volume-ref player)
        :speed-ref (etaf-video-player--player-speed-ref player)
        :subtitle-on-ref (etaf-video-player--player-subtitle-on-ref player)
        :progress-ref (etaf-video-player--player-progress-ref player)
        :progress-fill-ref etaf-video-player--pip-progress-fill-ref
        :progress-id 'video-pip-progress
        :time-ref etaf-video-player--pip-time-ref
        :time-text time-txt
        :on-seek (lambda (pct) (etaf-video-player--player-seek-percent player pct))
        :on-toggle on-toggle
        :on-prev on-prev :on-next on-next
        :on-toggle-audio (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--toggle-audio-command))
        :on-cycle-speed (lambda () (etaf-video-player--in-buffer player #'etaf-video-player-cycle-speed))
        :on-toggle-sub (lambda () (etaf-video-player--in-buffer player #'etaf-video-player--subtitle-toggle-command)))))))

(defun etaf-video-player-toggle-pip ()
  "Toggle a floating adaptive Picture-in-Picture window for the active video."
  (interactive)
  (let ((player (etaf-video-player--current)))
    (if (etaf-pip-active-p etaf-video-player--pip-id)
        (progn
          (etaf-video-player--pip-return player)
          (etaf-video-player--flash player "已回到主窗口继续播放")
          nil)
      (if (not (display-graphic-p))
          (progn
            (etaf-video-player--flash player "终端模式不支持悬浮画中画")
            nil)
        (let* ((st (etaf-video-player--state player))
               (pos (and st (plist-get st :position)))
               (spec (etaf-video-player--spec player))
               (buf (etaf-video-player--player-buffer player)))
          (etaf-video-player--exit-fullscreen player)
          (when (and spec (numberp pos) (> pos 0.0))
            (etaf-set-value (etaf-video-player--player-spec-ref player)
                            (plist-put (copy-sequence spec) :start (float pos))))
          (etaf-set-value (etaf-video-player--player-pip-active-ref player) t)
          ;; Flush main buffer first so its libmpv releases audio & GPU cleanly.
          (when-let* ((rt (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf))))
            (ignore-errors (etaf-runtime-flush rt)))
          (etaf-pip-open
           etaf-video-player--pip-id
           (etaf-view (etaf-video-player--pip-view :player player))
           :title (lambda () (etaf-video-player--title (etaf-video-player--spec player)))
           :size (or (etaf-video-player--player-pip-size player) 'medium)
           :corner (or (etaf-video-player--player-pip-corner player) 'bottom-right)
           :theme #'etaf-video-player--pip-theme-colors
           :on-return (lambda () (etaf-video-player--pip-return player))
           :on-close (lambda () (etaf-video-player--pip-on-close player))
           :on-size-change (lambda (sz) (setf (etaf-video-player--player-pip-size player) sz))
           :on-corner-change (lambda (cr) (setf (etaf-video-player--player-pip-corner player) cr)))
          (etaf-video-player--flash player "画中画已开启（拖标题栏移动 · 拖边框自由缩放）")
          t)))))

(provide 'etaf-video-player-app)
;;; etaf-video-player-app.el ends here
