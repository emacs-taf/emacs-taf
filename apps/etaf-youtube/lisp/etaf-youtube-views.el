;;; etaf-youtube-views.el --- Gallery, navigation and root shell views of etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Views are pure projections of the model: they read refs, compute layouts for
;; the live viewport and return declarative ETAF nodes.  No network call or
;; SQLite query belongs in `:render'; resume indicators read the store's O(1)
;; in-memory cache, and every action flows through the model functions.
;;
;; Implements the approved Obsidian Cinema (dark) and Editorial Daylight (light)
;; Feed Gallery, 8-destination Navigation Sidebar + Compact 8-Icon Rail,
;; Search & Topic Filter Bar, Full-Bleed Bordered Video Cards with resume badges,
;; Persistent Audio-Only Mini-Player Footer, Account Dialog, Auto-Dismissing
;; Toast, and delegates Watch routes to `etaf-youtube-watch'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-youtube-theme)
(require 'etaf-youtube-store)
(require 'etaf-youtube-login)
(require 'etaf-youtube-model)
(require 'etaf-youtube-watch)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function etaf-youtube-return-to-watch-command "etaf-youtube-app" ())
(declare-function etaf-youtube-escape-command "etaf-youtube-app" ())

(etaf-ui-icon-set-register
 'etaf-youtube-brand
 '(:kind svg :viewbox (0 0 24 24) :inset 0
   :paths ((youtube . "<rect x='1' y='4' width='22' height='16' rx='5' fill='currentColor' stroke='none'/><path d='M10 8L17 12L10 16Z' fill='white' stroke='none'/>")
           (home . "<path d='M3 11L12 3L21 11M5 9V21H10V14H14V21H19V9' fill='none' stroke='currentColor' stroke-width='1.7' stroke-linejoin='round'/>")
           (shorts . "<path d='M15 2L6 7A4 4 0 0 0 6 14L8 15L5 17A3 3 0 0 0 8 22L18 16A4 4 0 0 0 18 9L16 8L18 7A3 3 0 0 0 15 2Z' fill='none' stroke='currentColor' stroke-width='1.5'/><path d='M10 9L15 12L10 15Z' fill='currentColor' stroke='none'/>")
           (subscriptions . "<path d='M7 3H17M5 6H19' stroke='currentColor' stroke-width='1.6'/><rect x='3' y='9' width='18' height='12' rx='2' fill='none' stroke='currentColor' stroke-width='1.6'/><path d='M10 12L15 15L10 18Z' fill='currentColor' stroke='none'/>")
           (history . "<path d='M4 8A9 9 0 1 1 3 14M3 3V9H9M12 7V12L16 15' fill='none' stroke='currentColor' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/>")
           (playlists . "<path d='M3 5H21M3 10H21M3 15H12M3 20H12' stroke='currentColor' stroke-width='1.7'/><path d='M16 14L22 18L16 22Z' fill='currentColor' stroke='none'/>")
           (watch-later . "<circle cx='12' cy='12' r='9' fill='none' stroke='currentColor' stroke-width='1.7'/><path d='M12 6V12L17 15' fill='none' stroke='currentColor' stroke-width='1.7'/>")
           (liked . "<path d='M7 10L12 3C15 3 14 7 13 9H19C21 9 21 11 20 14L18 21H7ZM3 10H7V21H3Z' fill='none' stroke='currentColor' stroke-width='1.5' stroke-linejoin='round'/>")
           (live . "<circle cx='12' cy='12' r='2' fill='currentColor' stroke='none'/><path d='M7 7A7 7 0 0 0 7 17M17 7A7 7 0 0 1 17 17M4 4A11 11 0 0 0 4 20M20 4A11 11 0 0 1 20 20' fill='none' stroke='currentColor' stroke-width='1.5'/>"))
   :fallback ((youtube . ">") (home . "H") (shorts . "S")
              (subscriptions . "=") (history . "C") (playlists . "L")
              (watch-later . "W") (liked . "+") (live . "O"))))

(defvar etaf-youtube-search-ref 'etaf-youtube-search-field
  "Ref of the top bar search field, used by the application's focus key.")

(defvar etaf-youtube-caption-ref 'etaf-youtube-caption
  "Ref of the subtitle band Host above the transport controls.")

(defconst etaf-youtube-region-shell 'etaf-youtube-region-shell
  "Region id of the whole application shell.")

(defconst etaf-youtube-region-sidebar 'etaf-youtube-region-sidebar
  "Region id of the navigation sidebar, expanded or as the icon rail.")

(defconst etaf-youtube-region-content 'etaf-youtube-region-content
  "Region id of the scrollable content area.")

(defconst etaf-youtube-region-comments 'etaf-youtube-region-comments
  "Region id of the watch page comment section.")

(defconst etaf-youtube--primary-nav
  '(("首页" home "1")
    ("Shorts" shorts "2")
    ("订阅内容" subscriptions "3")
    ("直播" live "4"))
  "Primary navigation entries with label, view symbol and shortcut digit.")

(defconst etaf-youtube--personal-nav
  '(("观看历史" history "5")
    ("播放列表" playlists "6")
    ("稍后观看" watch-later "7")
    ("喜欢的视频" liked "8"))
  "Personal library navigation entries with label, view symbol and shortcut digit.")

(defconst etaf-youtube--search-filters
  '(("全部" . "all")
    ("视频" . "videos")
    ("频道" . "channels")
    ("播放列表" . "playlists")
    ("直播" . "live"))
  "Search result filter chips shown on the search route.")

;;; ---------------------------------------------------------------------------
;;; Layout & typography helpers
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--border (color &optional px)
  "Return a solid border spec in COLOR with thickness PX (default 1)."
  (list (list 'px (or px 1)) 'solid color))

(defun etaf-youtube--display-cell (metrics)
  "Return METRICS's character cell as `(WIDTH . HEIGHT)' in pixels."
  (let ((width (or (and metrics (plist-get metrics :char-width)) 8))
        (height (or (and metrics (plist-get metrics :line-height)) 17)))
    (cons (max 6 (min 24 width))
          (max 12 (min 48 height)))))

(defun etaf-youtube--columns (viewport metrics)
  "Return VIEWPORT's width in character columns using METRICS."
  (let* ((pixels (car-safe viewport))
         (char-width (car (etaf-youtube--display-cell metrics))))
    (max 24 (min 320 (floor (/ (or pixels 800) char-width))))))

(defun etaf-youtube--image-rows (columns metrics)
  "Return the 16:9 preview height in rows for COLUMNS character columns."
  (pcase-let* ((`(,char-width . ,line-height) (etaf-youtube--display-cell metrics)))
    (max 4 (min 20 (round (/ (* columns char-width 9.0)
                             (* 16.0 line-height)))))))

(defun etaf-youtube--thumbnail-size (image columns rows)
  "Fit IMAGE inside COLUMNS by ROWS without stretching portrait artwork."
  (let* ((size (and image (display-graphic-p) (image-size image t)))
         (cell (etaf-youtube--display-cell (etaf-display-metrics))))
    (if (not (and size (> (car size) 0) (> (cdr size) 0)))
        (cons columns rows)
      (let ((scale (min (/ (* columns (car cell)) (float (car size)))
                        (/ (* rows (cdr cell)) (float (cdr size))))))
        (cons (max 1 (min columns (round (/ (* scale (car size)) (car cell)))))
              (max 1 (min rows (round (/ (* scale (cdr size)) (cdr cell))))))))))

(defun etaf-youtube--clip (text width)
  "Return TEXT clipped to WIDTH columns with an ellipsis."
  (let ((text (replace-regexp-in-string "[\n\r]+" " " (or text ""))))
    (if (<= (string-width text) width)
        text
      (let ((result "") (index 0))
        (while (and (< index (length text))
                    (< (+ 1 (string-width result)) width))
          (setq result (concat result (char-to-string (aref text index)))
                index (1+ index)))
        (concat (string-trim-right result) "…")))))

(defun etaf-youtube--display-copy (text)
  "Keep one space between Chinese and Latin letters or digits in TEXT."
  (replace-regexp-in-string
   "\\([A-Za-z0-9]\\)\\([一-鿿]\\)" "\\1 \\2"
   (replace-regexp-in-string "\\([一-鿿]\\)\\([A-Za-z0-9]\\)" "\\1 \\2"
                             (or text ""))))

(defun etaf-youtube--clip-pixels (text pixels)
  "Return TEXT shortened so it fits PIXELS display pixels."
  (setq text (etaf-youtube--display-copy text))
  (if (or (string-empty-p text) (<= (etaf-string-pixel-width text) pixels))
      text
    (let ((result "")
          (index 0))
      (while (and (< index (length text))
                  (let ((candidate (concat result (char-to-string (aref text index)))))
                    (<= (etaf-string-pixel-width candidate) pixels)))
        (setq result (concat result (char-to-string (aref text index)))
              index (1+ index)))
      (string-trim-right result))))

(defun etaf-youtube--caption-lines (text pixels &optional lines)
  "Return TEXT as at most LINES lines fitting PIXELS pixels.
Prefers breaking on ASCII spaces when wrapping Latin words."
  (let ((text (replace-regexp-in-string "[\n\r]+" " "
                                       (etaf-youtube--display-copy text)))
        (lines (or lines 2))
        (result nil)
        (current "")
        (index 0)
        (overflow nil))
    (while (and (< index (length text)) (not overflow))
      (let* ((char (char-to-string (aref text index)))
             (candidate (concat current char)))
        (if (and (not (string-empty-p current))
                 (> (etaf-string-pixel-width candidate) pixels))
            (if (>= (length result) (1- lines))
                (setq overflow t)
              (let* ((len (length current))
                     (space-pos (cl-position ?\s current :from-end t)))
                (if (and space-pos (> space-pos (/ len 2))
                         (not (string= char " ")))
                    (let ((head (string-trim-right (substring current 0 space-pos)))
                          (tail (concat (substring current (1+ space-pos)) char)))
                      (push head result)
                      (setq current tail
                            index (1+ index)))
                  (push (string-trim-right current) result)
                  (setq current (if (string= char " ") "" char)
                        index (1+ index)))))
          (setq current candidate
                index (1+ index)))))
    (setq result (nreverse result))
    (if overflow
        (append result
                (list (concat (etaf-youtube--clip-pixels
                               current (- pixels (etaf-string-pixel-width "…")))
                              "…")))
      (if (string-empty-p current) result (append result (list current))))))

(defun etaf-youtube--chunk (items size)
  "Return ITEMS split into lists of at most SIZE."
  (let ((result nil))
    (while items
      (push (seq-take items size) result)
      (setq items (seq-drop items size)))
    (nreverse result)))

(defun etaf-youtube--card-rows (items columns)
  "Group ITEMS into landscape and portrait rows fitting COLUMNS.
Each entry retains its original zero-based index so visual grouping never
alters which video an activation opens."
  (let* ((entries (cl-loop for item in items for index from 0
                           collect (cons index item)))
         (short-p (lambda (entry)
                    (member (plist-get (cdr entry) :kind) '(short "short"))))
         (rows nil))
    (dolist (portrait '(nil t))
      (let* ((group (seq-filter (lambda (entry)
                                  (eq (not (null (funcall short-p entry))) portrait))
                                entries))
             (count (max 1 (min (if portrait 5 4)
                                (/ (+ columns 2) (if portrait 24 38)))))
             (width (max 18 (/ (- columns (* 2 (1- count))) count)))
             (first t))
        (dolist (row (etaf-youtube--chunk group count))
          (push (list :entries row :columns width :portrait portrait
                      :heading (and portrait first)) rows)
          (setq first nil))))
    (nreverse rows)))

(defun etaf-youtube--seconds (value)
  "Return VALUE formatted as `M:SS' or `H:MM:SS'."
  (let ((total (etaf-youtube--parse-duration-seconds value)))
    (if (>= total 3600)
        (format "%d:%02d:%02d" (/ total 3600) (/ (% total 3600) 60) (% total 60))
      (format "%d:%02d" (/ total 60) (% total 60)))))

(defun etaf-youtube--view-title (view model)
  "Return human-readable title for VIEW using MODEL."
  (pcase view
    ('home "首页")
    ('shorts "Shorts")
    ('subscriptions "订阅内容")
    ('history "观看历史")
    ('playlists "播放列表")
    ('watch-later "稍后观看")
    ('liked "喜欢的视频")
    ('live "直播")
    ('search (format "搜索：%s" (etaf-youtube--read model :query)))
    ('channel "频道")
    ('playlist "播放列表")
    (_ "YouTube")))

(defun etaf-youtube--shell-keys (view)
  "Return the root `:keys' table appropriate for VIEW."
  (if (eq view 'watch)
      (list
       (list "SPC" 'etaf-youtube-toggle-playback-command "播放 / 暂停")
       (list "k" 'etaf-youtube-toggle-playback-command "播放 / 暂停")
       (list "j" 'etaf-youtube-seek-back-10-command "快退 10 秒")
       (list "l" 'etaf-youtube-seek-forward-10-command "快进 10 秒")
       (list "0" 'etaf-youtube-seek-percent-0-command "跳转到 0%")
       (list "1" 'etaf-youtube-seek-percent-1-command "跳转到 10%")
       (list "2" 'etaf-youtube-seek-percent-2-command "跳转到 20%")
       (list "3" 'etaf-youtube-seek-percent-3-command "跳转到 30%")
       (list "4" 'etaf-youtube-seek-percent-4-command "跳转到 40%")
       (list "5" 'etaf-youtube-seek-percent-5-command "跳转到 50%")
       (list "6" 'etaf-youtube-seek-percent-6-command "跳转到 60%")
       (list "7" 'etaf-youtube-seek-percent-7-command "跳转到 70%")
       (list "8" 'etaf-youtube-seek-percent-8-command "跳转到 80%")
       (list "9" 'etaf-youtube-seek-percent-9-command "跳转到 90%")
       (list "," 'etaf-youtube-step-back-command "上一帧")
       (list "." 'etaf-youtube-step-forward-command "下一帧")
       (list "+" 'etaf-youtube-speed-up-command "加快倍速")
       (list "=" 'etaf-youtube-speed-up-command "加快倍速")
       (list "-" 'etaf-youtube-speed-down-command "减慢倍速")
       (list "]" 'etaf-youtube-volume-up-command "音量 +5")
       (list "[" 'etaf-youtube-volume-down-command "音量 -5")
       (list "m" 'etaf-youtube-mute-command "静音")
       (list "Q" 'etaf-youtube-quality-dialog-command "画质与线路选择")
       (list "c" 'etaf-youtube-cycle-captions-command "开关 / 切换字幕")
       (list "w" 'etaf-youtube-theater-command "切换宽屏剧场")
       (list "t" 'etaf-youtube-theater-command "切换宽屏剧场")
       (list "f" 'etaf-youtube-fullscreen-command "网页全屏（纯净影院）")
       (list "F" 'etaf-youtube-frame-fullscreen-command "系统真全屏（整屏独占）")
       (list "i" 'etaf-youtube-toggle-drawer-command "展开 / 收起工作台抽屉")
       (list "A" 'etaf-youtube-toggle-audio-only-command "纯音频后台模式")
       (list "v" 'etaf-youtube-toggle-pip-command "悬浮画中画 PiP")
       (list "N" 'etaf-youtube-next-video-command "队列下一条")
       (list "P" 'etaf-youtube-prev-video-command "队列上一条")
       (list "L" 'etaf-youtube-toggle-auto-next-command "自动连播开关")
       (list "M-n" 'etaf-youtube-next-chapter-command "下一章节")
       (list "M-p" 'etaf-youtube-prev-chapter-command "上一章节")
       (list "o" 'etaf-youtube-open-external "外部 mpv 播放")
       (list "O" 'etaf-youtube-open-in-browser "浏览器打开")
       (list "y" 'etaf-youtube-copy-org-link "复制带时间戳 Org 链接")
       (list "u" 'etaf-youtube-open-author-channel-command "进入作者频道")
       (list "b" 'etaf-youtube-back-command "返回列表")
       (list "d" 'etaf-youtube-theme-command "切换深浅外观")
       (list "T" 'etaf-youtube-theme-command "切换深浅外观")
       (list "r" 'etaf-youtube-refresh-command "重新加载视频")
       (list "s" 'etaf-youtube-sidebar-command "折叠 / 展开侧栏")
       (list "RET" 'etaf-youtube-activate-command "激活聚焦控件")
       (list "C-c c" 'etaf-youtube-focus-content-command "焦点：剧场")
       (list "C-c m" 'etaf-youtube-focus-comments-command "焦点：工作台"))
    (list
     (list "n" 'etaf-youtube-select-next-command "下一项")
     (list "p" 'etaf-youtube-select-prev-command "上一项")
     (list "1" 'etaf-youtube-nav-1-command "首页")
     (list "2" 'etaf-youtube-nav-2-command "Shorts")
     (list "3" 'etaf-youtube-nav-3-command "订阅内容")
     (list "4" 'etaf-youtube-nav-4-command "直播")
     (list "5" 'etaf-youtube-nav-5-command "观看历史")
     (list "6" 'etaf-youtube-nav-6-command "播放列表")
     (list "7" 'etaf-youtube-nav-7-command "稍后观看")
     (list "8" 'etaf-youtube-nav-8-command "喜欢的视频")
     (list "SPC" 'etaf-youtube-toggle-playback-command "播放 / 暂停后台音频")
     (list "f" 'etaf-youtube-seek-forward-command "快进 5 秒")
     (list "b" 'etaf-youtube-seek-backward-command "快退 5 秒")
     (list "]" 'etaf-youtube-volume-up-command "音量 +5")
     (list "[" 'etaf-youtube-volume-down-command "音量 -5")
     (list "m" 'etaf-youtube-mute-command "静音")
     (list "s" 'etaf-youtube-sidebar-command "折叠 / 展开侧栏")
     (list "t" 'etaf-youtube-theater-command "影院模式")
     (list "w" 'etaf-youtube-return-to-watch-command "回到当前观影页")
     (list "d" 'etaf-youtube-theme-command "切换深浅外观")
     (list "T" 'etaf-youtube-theme-command "切换深浅外观")
     (list "r" 'etaf-youtube-refresh-command "刷新")
     (list "g" 'etaf-youtube-refresh-command "刷新")
     (list "u" 'etaf-youtube-back-command "返回")
     (list "RET" 'etaf-youtube-activate-command "激活聚焦控件或打开选中项")
     (list "/" 'etaf-youtube-focus-search "搜索或粘贴链接")
     (list "C-c s" 'etaf-youtube-focus-sidebar-command "焦点：侧栏")
     (list "C-c c" 'etaf-youtube-focus-content-command "焦点：内容")
     (list "C-c m" 'etaf-youtube-focus-comments-command "焦点：评论"))))

;;; ---------------------------------------------------------------------------
;;; Root Application Shell
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-app (&key model)
  "Render the YouTube application for MODEL and own its lifecycle."
  :bindings ((mode (plist-get model :theme-mode))
             (palette (plist-get model :palette))
             (viewport (etaf-computed (lambda () (etaf-viewport))))
             (metrics (etaf-computed (lambda () (etaf-display-metrics))))
             (route (plist-get model :route))
             (sidebar (plist-get model :sidebar))
             (message (plist-get model :message))
             (audio-only (plist-get model :audio-only))
             (account-menu (plist-get model :account-menu))
             (colors (etaf-computed
                      (lambda ()
                        (etaf-youtube-colors (etaf-value mode))))))
  :setup
  (progn
    (etaf-theme-provide palette)
    ;; Single source of appearance truth: a host panel switch writes the mode
    ;; cell and the palette follows it so every surface repaints together.
    (etaf-watch mode
                (lambda (m _old)
                  (etaf-youtube--write model :palette
                                       (etaf-youtube-theme-defaults m)))
                :immediate t :name 'etaf-youtube-palette)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme palette :mode mode
                            :modes etaf-youtube--surface-modes))
    (etaf-on-mounted
     (lambda ()
       (let ((view (plist-get (etaf-youtube--read model :route) :view)))
         (when (or (eq view 'watch)
                   (etaf-youtube--read model :audio-only))
           (etaf-youtube--start-player-timer model))
         (when (and (not (eq view 'watch))
                    (eq 'idle (plist-get (etaf-youtube--read model :feed-status) :state)))
           (etaf-youtube-refresh model)))))
    (etaf-on-unmounted
     (lambda () (etaf-youtube-destroy model))))
  :render
  (let* ((vp (etaf-value viewport))
         (met (etaf-value metrics))
         (cell (etaf-youtube--display-cell met))
         (columns (etaf-youtube--columns vp met))
         (rows (max 12 (or (cdr-safe vp) 40)))
         (watch-vp (list (or (car-safe vp) (* columns (car cell)))
                         rows (car cell) (cdr cell)))
         (cur-mode (etaf-value mode))
         (c (etaf-value colors))
         (view (plist-get (etaf-value route) :view))
         (narrow (<= columns 88))
         (sidebar-visible (and (etaf-value sidebar) (> columns 88)))
         (rail-visible (and narrow (etaf-value sidebar)))
         (content-columns (- columns (cond (sidebar-visible 24)
                                           (rail-visible 6)
                                           (t 0))))
         (show-audio-bar (and (not (eq view 'watch)) (etaf-value audio-only))))
    (etaf-view
     (flex :flex-direction 'column :width '(vw 100) :height '(vh 100)
           :position 'relative
           :background-color (plist-get c :bg)
           :color (plist-get c :ink)
           :overflow 'hidden
           :region (list :id etaf-youtube-region-shell :label "应用" :key ?a)
           :keys (etaf-youtube--shell-keys view)
           :on-dismiss (when (eq view 'watch)
                         (lambda () (etaf-youtube-escape-command)))
       ;; Watch Route: full-bleed Cinema Watch View
       (etaf-youtube--watch-view
        :if (eq view 'watch)
        :model model :mode cur-mode :viewport watch-vp)
       ;; Gallery / Browse Routes: Topbar + Sidebar/Rail + Feed Content + Mini-Player
       (etaf-youtube-topbar
        :if (not (eq view 'watch))
        :model model :colors c :columns columns)
       (flex :if (not (eq view 'watch))
             :flex-direction 'row :flex-grow 1 :flex-basis '(lh 0)
             :min-height '(lh 0) :overflow 'hidden
             :background-color (plist-get c :bg)
         (etaf-youtube-sidebar :model model :colors c :columns columns
                               :active sidebar-visible)
         (etaf-youtube-sidebar-rail :model model :colors c
                                    :active rail-visible)
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(px 0)
              :height 'stretch :min-height '(lh 0) :overflow 'scroll
              :background-color (plist-get c :bg)
              :ref 'etaf-youtube-content
              :region (list :id etaf-youtube-region-content :label "内容" :key ?c
                            :neighbors (list :left etaf-youtube-region-sidebar))
           (etaf-youtube-list :model model :colors c
                              :columns content-columns
                              :metrics met)))
       (etaf-youtube-audio-bar
        :if show-audio-bar
        :model model :colors c :columns columns)
       ;; Account Dialog Modal
       (etaf-youtube-account-dialog
        :open (etaf-value account-menu)
        :model model :colors c)
       ;; Auto-dismissing Toast Notification
       (etaf-youtube-toast
        :if (etaf-value message)
        :model model
        :message (etaf-value message)
        :colors c
        :columns columns
        :watch-p (eq view 'watch)
        :has-side (and (eq view 'watch) (>= columns 120)
                       (not (etaf-value (plist-get model :theater)))
                       (not (etaf-value (plist-get model :fullscreen)))))))))

;;; ---------------------------------------------------------------------------
;;; Topbar & Account Menu
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-topbar (&key model colors columns)
  "Render the elevated 3-row feed topbar with anchored brand, search and account."
  :bindings ((query (plist-get model :query))
             (account (plist-get model :account))
             (mode (plist-get model :theme-mode)))
  :render
  (let* ((small (<= columns 72))
         (tiny (<= columns 48))
         (left-width (cond (tiny '(ch 6)) (small '(ch 12)) (t '(ch 22))))
         (right-width (cond (tiny '(ch 12)) (small '(ch 18)) (t '(ch 28)))))
    (etaf-view
     (flex :ref 'etaf-youtube-topbar :role 'banner :aria-label "YouTube 顶栏"
           :flex-direction 'row :height '(lh 3) :flex-shrink 0
           :box-sizing 'border-box :align-items 'center
           :column-gap (list 'ch (if small 1 2))
           :padding (list '(lh 0) (list 'ch (if small 1 2)))
           :background-color (plist-get colors :panel2)
           :border-bottom (etaf-youtube--border (plist-get colors :line))
       ;; Left-anchored brand + sidebar toggle
       (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
             :width left-width :flex-shrink 0
         (box :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
              :role 'button :tab-index 0 :aria-label "切换侧栏"
              :help-echo "展开或收起侧栏 (s)" :pointer 'hand
              :color (plist-get colors :muted)
              :hover-style (list :color (plist-get colors :ink)
                                 :background-color (plist-get colors :hover))
              :on-press (lambda () (etaf-youtube-toggle-sidebar model))
           (etaf-ui-icon :name 'menu :set 'svg :color (plist-get colors :ink)))
         (box :height '(lh 1) :role 'button :tab-index 0 :aria-label "YouTube 首页"
              :help-echo "回到首页 (1)" :pointer 'hand
              :on-press (lambda () (etaf-youtube-locate model 'home))
           (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
             (etaf-ui-icon :name 'youtube :set 'etaf-youtube-brand
                           :color (plist-get colors :accent) :min-width 3)
             (text :if (not small) :color (plist-get colors :ink)
                   :font-weight 'bold "YouTube"))))
       ;; Flexible center search & direct URL/ID field
       (flex :flex-direction 'row :justify-content 'center
             :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         (etaf-search-field
          :bind query :ref etaf-youtube-search-ref
          :placeholder (if (<= columns 104) "搜索 (/)" "搜索视频、频道或粘贴链接 / ID (/)")
          :icon t
          :width 'stretch :max-width '(ch 64)
          :on-submit (lambda (text)
                       (etaf-youtube--write model :query (or text ""))
                       (etaf-youtube--submit-search-or-url model (or text "")))))
       ;; Right-anchored actions + account status pill
       (flex :flex-direction 'row :align-items 'center
             :justify-content 'flex-end :column-gap '(ch 1)
             :width right-width :flex-shrink 0
         (box :if (not small) :height '(lh 1) :padding '((lh 0) (ch 1))
              :flex-shrink 0 :role 'button :tab-index 0 :aria-label "刷新"
              :help-echo "刷新当前页面 (r)" :pointer 'hand
              :color (plist-get colors :muted)
              :hover-style (list :color (plist-get colors :ink)
                                 :background-color (plist-get colors :hover))
              :on-press (lambda () (etaf-youtube-refresh model))
           (text "刷新"))
         (box :if (not tiny) :height '(lh 1) :padding '((lh 0) (ch 1))
              :flex-shrink 0 :role 'button :tab-index 0 :aria-label "切换外观"
              :help-echo (if (eq (etaf-value mode) 'dark)
                             "切换到浅色外观 (d)" "切换到深色外观 (d)")
              :pointer 'hand :color (plist-get colors :muted)
              :hover-style (list :color (plist-get colors :ink)
                                 :background-color (plist-get colors :hover))
              :on-press (lambda () (etaf-youtube-cycle-theme model))
           (text "明暗"))
         (etaf-youtube--account-avatar :model model
                                       :account (etaf-value account)
                                       :colors colors
                                       :compact small))))))

(etaf-define-component etaf-youtube--account-avatar (&key model account colors compact)
  "Render a 1-row account status pill opening the account menu, or sign-in link."
  :render
  (if (and account (plist-get account :signed_in))
      (let* ((full-name (or (plist-get account :name) "账号"))
             (first-word (car (split-string (string-trim full-name) " " t)))
             (display-base (if (and first-word (> (string-width full-name) 8))
                               first-word full-name))
             (shown (etaf-youtube--clip display-base (if compact 6 8))))
        (etaf-view
         (flex :height '(lh 1) :flex-shrink 0 :align-items 'center
               :column-gap '(ch 1) :padding '((lh 0) (ch 1))
               :role 'button :tab-index 0 :aria-label full-name
               :help-echo (format "已登录：%s（点击管理账号）" full-name)
               :background-color (plist-get colors :panel3)
               :color (plist-get colors :ink)
               :pointer 'hand
               :on-press (lambda () (etaf-youtube--write model :account-menu t))
           (text :color (plist-get colors :ok) "●")
           (box :height '(lh 1) :color (plist-get colors :ink)
                :hover-style (list :color (plist-get colors :accent))
             (text (expr (if compact shown (format "%s ▾" shown))))))))
    (etaf-view
     (box :height '(lh 1) :flex-shrink 0 :role 'button :tab-index 0
          :aria-label "登录" :padding '((lh 0) (ch 1))
          :background-color (plist-get colors :panel3)
          :color (plist-get colors :link) :pointer 'hand
          :hover-style (list :color (plist-get colors :ink)
                             :background-color (plist-get colors :hover))
          :help-echo "在受控浏览器中登录 YouTube 后刷新"
          :on-press (lambda () (etaf-youtube-login model))
       (text "登录")))))

(etaf-define-component etaf-youtube-account-dialog (&key open model colors)
  "Render the account management dialog for switching or logging out."
  :bindings ((account (plist-get model :account)))
  :render
  (let* ((acc (etaf-value account))
         (signed (and acc (plist-get acc :signed_in)))
         (name (or (and signed (plist-get acc :name)) "未登录"))
         (handle (and signed (etaf-youtube--nonempty-string (plist-get acc :handle)))))
    (etaf-view
     (etaf-dialog :open open :title "YouTube 账号与会话" :width '(ch 48)
                  :close-label nil
                  :on-close (lambda () (etaf-youtube--write model :account-menu nil))
       (column :width 'stretch :item-gap '(lh 1)
         (flex :align-items 'center :column-gap '(ch 1)
           (text :color (plist-get colors (if signed :ok :dim)) (expr (if signed "●" "○")))
           (text :color (plist-get colors :ink) :font-weight 'bold
             (expr (if handle (format "%s (%s)" name handle) name))))
         (text :color (plist-get colors :muted)
           "账号会话保存在本机受控浏览器中，Emacs 不会存储任何密码或 Cookie。")
         (text :color (plist-get colors :dim)
           (expr (format "播放引擎：%s"
                         (if (and (fboundp 'etaf-video-mpv-available-p)
                                  (etaf-video-mpv-available-p))
                             "libmpv 硬件加速已就绪"
                           "ffmpeg / ffplay 兼容管线")))))
       (slot :name 'footer
         (flex :width 'stretch :justify-content 'space-between :column-gap '(ch 1)
           (etaf-button :label "重新检测" :variant 'secondary
                        :on-press (lambda ()
                                    (etaf-youtube--write model :account-menu nil)
                                    (etaf-youtube-check model)))
           (etaf-button :label (if signed "切换账号" "登录") :variant 'primary
                        :on-press (lambda ()
                                    (etaf-youtube--write model :account-menu nil)
                                    (etaf-youtube-login model)))
           (etaf-button :if signed :label "退出登录" :variant 'ghost
                        :on-press (lambda ()
                                    (etaf-youtube--write model :account-menu nil)
                                    (etaf-youtube-logout model)))
           (etaf-button :label "关闭" :variant 'ghost
                        :on-press (lambda () (etaf-youtube--write model :account-menu nil)))))))))

;;; ---------------------------------------------------------------------------
;;; Sidebar & Compact 8-Icon Rail
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-sidebar (&key model colors columns active)
  "Render the expanded 8-destination navigation sidebar when ACTIVE."
  :bindings ((route (plist-get model :route)))
  :render
  (let* ((current (plist-get (etaf-value route) :view))
         (mpv-ok (and (fboundp 'etaf-video-mpv-available-p)
                      (etaf-video-mpv-available-p))))
    (etaf-view
     (flex :flex-direction 'column :width '(ch 24)
           :box-sizing 'border-box :flex-shrink 0 :height 'stretch
           :overflow 'scroll :padding '((lh 1) (ch 1))
           :background-color (plist-get colors :panel)
           :border-right (etaf-youtube--border (plist-get colors :line))
           :row-gap '(lh 0)
           :region (list :id etaf-youtube-region-sidebar :label "侧栏" :key ?s
                         :neighbors (list :right etaf-youtube-region-content))
           :if active
       (etaf-youtube-sidebar-items :model model :colors colors
                                   :current current :entries etaf-youtube--primary-nav)
       (box :height '(lh 1) :flex-shrink 0)
       (etaf-divider :flex-shrink 0)
       (box :flex-shrink 0 :padding '((lh 1) (ch 2))
         (text :color (plist-get colors :dim) :font-weight 'bold "我的内容"))
       (etaf-youtube-sidebar-items :model model :colors colors
                                   :current current :entries etaf-youtube--personal-nav)
       (box :flex-grow 1 :min-height '(lh 1))
       (flex :flex-direction 'column :flex-shrink 0 :padding '((lh 0) (ch 2))
             :row-gap '(lh 0)
         (text :color (plist-get colors (if mpv-ok :ok :dim))
           (expr (if mpv-ok "● libmpv 就绪" "● ffmpeg 模式"))))))))

(etaf-define-component etaf-youtube-sidebar-rail (&key model colors active)
  "Render the compact 8-icon rail used below the sidebar breakpoint."
  :view
  (flex :flex-direction 'column :width '(ch 6) :align-items 'center
        :box-sizing 'border-box :flex-shrink 0 :height 'stretch
        :overflow 'scroll :padding '((lh 1) (ch 0))
        :background-color (plist-get colors :panel)
        :border-right (etaf-youtube--border (plist-get colors :line))
        :row-gap '(lh 0)
        :region (list :id etaf-youtube-region-sidebar :label "侧栏" :key ?s
                      :neighbors (list :right etaf-youtube-region-content))
        :if active
    (etaf-youtube-rail-button
     :for (entry (append etaf-youtube--primary-nav etaf-youtube--personal-nav))
     :key (nth 1 entry)
     :label (nth 0 entry)
     :view (nth 1 entry)
     :shortcut (nth 2 entry)
     :model model :colors colors)))

(etaf-define-component etaf-youtube-rail-button
    (&key label view shortcut model colors)
  "Render one accessible, selected-state-aware compact rail button."
  :bindings ((route (plist-get model :route)))
  :render
  (let* ((active (eq view (plist-get (etaf-value route) :view)))
         (fg (plist-get colors (if active :accent :muted))))
    (etaf-view
     (box :role 'button :tab-index 0 :aria-label label :aria-selected active
          :help-echo (format "%s (%s)" label shortcut)
          :width '(ch 5) :padding '((lh 0.5) (ch 1)) :flex-shrink 0
          :background-color (when active (plist-get colors :accent-soft))
          :border-left (etaf-youtube--border
                        (plist-get colors (if active :accent :panel)) 2)
          :color fg
          :pointer (unless active 'hand)
          :hover-style (unless active
                         (list :background-color (plist-get colors :hover)
                               :color (plist-get colors :ink)))
          :on-press (lambda () (unless active (etaf-youtube-locate model view)))
       (flex :align-items 'center :justify-content 'center
         (etaf-ui-icon :name view :set 'etaf-youtube-brand
                       :color fg :min-width 3))))))

(etaf-define-component etaf-youtube-sidebar-items
    (&key model colors current entries)
  "Render ENTRIES as stacked sidebar navigation buttons."
  :view
  (flex :flex-direction 'column :row-gap '(lh 0) :flex-shrink 0
    (etaf-youtube-sidebar-item
     :for (entry entries)
     :key (nth 1 entry)
     :label (nth 0 entry)
     :view (nth 1 entry)
     :shortcut (nth 2 entry)
     :current current
     :model model
     :colors colors)))

(etaf-define-component etaf-youtube-sidebar-item
    (&key label view shortcut current model colors)
  "Render one navigation entry with invariant border geometry and no active hover."
  :render
  (let* ((active (eq view current))
         (fg (plist-get colors (if active :accent :muted))))
    (etaf-view
     (box :role 'button :tab-index 0 :aria-label label :aria-selected active
          :width 'stretch :flex-shrink 0
          :padding '((lh 0.5) (ch 1))
          :background-color (when active (plist-get colors :accent-soft))
          :border-left (etaf-youtube--border
                        (plist-get colors (if active :accent :panel)) 2)
          :color fg
          :pointer (unless active 'hand)
          :hover-style (unless active
                         (list :background-color (plist-get colors :hover)
                               :color (plist-get colors :ink)))
          :on-press (lambda () (unless active (etaf-youtube-locate model view)))
       (flex :flex-direction 'row :align-items 'center :justify-content 'space-between
             :column-gap '(ch 1)
         (flex :flex-direction 'row :align-items 'center :column-gap '(ch 1)
           (etaf-ui-icon :name view :set 'etaf-youtube-brand
                         :color fg :min-width 2)
           (text (expr label)))
         (text :color (plist-get colors (if active :accent :dim))
           (expr shortcut)))))))

;;; ---------------------------------------------------------------------------
;;; Persistent Audio-Only Footer & Auto-Dismissing Toast
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-audio-bar (&key model colors columns)
  "Render the persistent mini-player bar while audio-only background mode runs."
  :bindings ((video (plist-get model :video))
             (media (plist-get model :media))
             (playing (plist-get model :playing)))
  :render
  (let* ((vid (etaf-value video))
         (med (etaf-value media))
         (is-play (etaf-value playing))
         (title (or (plist-get vid :title) (plist-get med :title) "后台音频播放中"))
         (pos (or (plist-get model :live-position) 0))
         (dur (or (plist-get model :live-duration) 0))
         (clock (format "%s / %s" (etaf-youtube--clock pos) (etaf-youtube--clock dur)))
         (max-t (max 14 (- columns 44))))
    (etaf-view
     (flex :flex-direction 'row :height '(lh 3) :flex-shrink 0
           :align-items 'center :column-gap '(ch 2)
           :padding '((lh 0) (ch 2))
           :background-color (plist-get colors :panel)
           :border-top (etaf-youtube--border (plist-get colors :accent))
       (text :color (plist-get colors :accent) :font-weight 'bold "♫ 正在听")
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (text :color (plist-get colors :ink)
           (expr (format "%s  %s" (etaf-youtube--clip title max-t) clock))))
       (box :width '(ch 3) :height '(lh 1) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (plist-get colors :accent) :color "#FFFFFF"
            :help-echo "播放 / 暂停 (SPC)"
            :on-press (lambda () (etaf-youtube-toggle-playback model))
         (etaf-ui-icon :name (if is-play 'pause 'play) :set 'svg
                       :size 0.85 :min-width 3 :color "#FFFFFF"))
       (box :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (plist-get colors :panel3)
            :color (plist-get colors :ink)
            :hover-style (list :background-color (plist-get colors :hover))
            :help-echo "回到观影页 (w)"
            :on-press (lambda () (etaf-youtube-return-to-watch-command))
         (text "回剧场 (w)"))
       (box :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :color (plist-get colors :muted)
            :hover-style (list :color (plist-get colors :danger))
            :help-echo "停止后台音频"
            :on-press (lambda () (etaf-youtube--toggle-audio-only model))
         (text "停止"))))))

(etaf-define-component etaf-youtube-toast
    (&key model message colors columns watch-p has-side)
  "Render MESSAGE as an auto-dismissing notification with close button.
In Watch View, anchor bottom-right outside the video canvas so transient
toasts never trigger native GPU occlusion fallbacks."
  :render
  (let* ((variant (plist-get message :variant))
         (bg (pcase variant
               ('danger (plist-get colors :danger-bg))
               ('warning (etaf-youtube-color :warn-bg (etaf-youtube--read model :theme-mode)))
               ('success (plist-get colors :ok))
               (_ (plist-get colors :panel3))))
         (fg (cond ((eq variant 'success) "#FFFFFF")
                   ((eq variant 'danger) (plist-get colors :danger))
                   ((eq variant 'warning) (plist-get colors :warn))
                   (t (plist-get colors :ink))))
         (bd (pcase variant
               ('danger (plist-get colors :danger))
               ('warning (plist-get colors :warn))
               ('success (plist-get colors :ok))
               (_ (plist-get colors :line))))
         (max-text (if watch-p (min 36 (max 10 (- columns 12)))
                     (max 10 (- columns 12))))
         (clipped (etaf-youtube--clip (or (plist-get message :text) "") max-text))
         (est-w (+ 8 (string-width clipped)))
         (left-ch (if watch-p
                      (max 2 (- columns est-w 2))
                    2))
         (top-expr (if (and watch-p (not has-side))
                       '(calc (- (vh 100) (lh 2)))
                     '(calc (- (vh 100) (lh 3))))))
    (etaf-view
     (flex :flex-direction 'row :align-items 'center :column-gap '(ch 2)
           :padding '((lh 0) (ch 2))
           :background-color bg :color fg
           :border (etaf-youtube--border bd)
           :position 'absolute :left (list 'ch left-ch)
           :top top-expr :z-index 20
       (text (expr clipped))
       (box :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
            :aria-label "关闭提示" :color fg
            :on-press (lambda () (etaf-youtube--dismiss-note model))
         (text "×"))))))

;;; ---------------------------------------------------------------------------
;;; Feed Gallery, Context Filter Bar & Video Cards
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube-list (&key model colors columns metrics)
  "Render the current feed, search or channel list as a responsive card grid."
  :bindings ((feed (plist-get model :feed))
             (status (plist-get model :feed-status))
             (more (plist-get model :feed-more))
             (route (plist-get model :route))
             (search-filter (plist-get model :filter)))
  :render
  (let* ((payload (etaf-value feed))
         (items (plist-get payload :items))
         (state (plist-get (etaf-value status) :state))
         (view (plist-get (etaf-value route) :view))
         (cur-filter (etaf-value search-filter))
         (padding (if (< columns 70) 1 2))
         (inner (max 20 (- columns (* 2 padding))))
         (rows (etaf-youtube--card-rows items inner)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch
           :background-color (plist-get colors :bg)
           :padding (list '(lh 1) (list 'ch padding)) :row-gap '(lh 1)
       (etaf-youtube-list-header :model model :colors colors :payload payload
                                 :state state :view view :filter cur-filter
                                 :count (length items))
       (flex :flex-direction 'column :row-gap '(lh 1) :if (eq state 'loading)
         (etaf-youtube-skeleton-row :columns inner :colors colors)
         (etaf-youtube-skeleton-row :columns inner :colors colors))
       (flex :flex-direction 'column :padding '((lh 2) (ch 2)) :row-gap '(lh 1)
             :background-color (plist-get colors :surface)
             :border (etaf-youtube--border (plist-get colors :line))
             :if (eq state 'error)
         (text :color (plist-get colors :danger) :font-weight 'bold
               (expr (or (plist-get (etaf-value status) :message) "加载失败")))
         (text :color (plist-get colors :muted)
               (expr (or (plist-get (etaf-value status) :hint)
                         "检查网络代理或受控浏览器登录状态后重试。")))
         (etaf-button :label "重试" :variant 'secondary
                      :on-press (lambda () (etaf-youtube-refresh model))))
       (flex :flex-direction 'column :padding '((lh 2) (ch 2)) :row-gap '(lh 1)
             :if (and (eq state 'ready) (null items))
         (text :color (plist-get colors :ink) :font-weight 'bold "这里还没有内容")
         (text :color (plist-get colors :muted) "换个筛选条件，或按 r 刷新一次"))
       (expr
        (when (and items (not (eq state 'loading)))
          (mapcar
           (lambda (row)
             (let* ((width (plist-get row :columns))
                    (portrait (plist-get row :portrait))
                    (cell (etaf-youtube--display-cell metrics))
                    (height (if portrait
                                (max 4 (min 18 (round (/ (* width (car cell) 16.0)
                                                         (* 9.0 (cdr cell))))))
                              (etaf-youtube--image-rows width metrics))))
               (etaf-view
                (flex :flex-direction 'column :row-gap '(lh 1)
                  (flex :if (and (not (eq view 'shorts)) (plist-get row :heading))
                        :flex-direction 'row
                        :column-gap '(ch 1) :align-items 'center
                    (etaf-ui-icon :name 'shorts :set 'etaf-youtube-brand
                                  :color (plist-get colors :accent))
                    (text :color (plist-get colors :ink) :font-weight 'bold "Shorts"))
                  (flex :flex-direction 'row :column-gap '(ch 2)
                        :align-items 'flex-start
                    (expr
                     (mapcar
                      (lambda (entry)
                        (let ((item (cdr entry)))
                          (etaf-view
                           (etaf-youtube-card :model model :colors colors
                                              :item item :columns width
                                              :image-rows height
                                              :key (or (plist-get item :id) (car entry))
                                              :index (car entry)))))
                      (plist-get row :entries))))))))
           rows)))
       (flex :flex-direction 'row :justify-content 'center :padding '((lh 1) (ch 0))
             :if (and (plist-get payload :next) (not (eq state 'loading)))
         (etaf-button :label (if (plist-get (etaf-value more) :loading)
                                 "正在加载更多…"
                               "加载更多")
                      :variant 'secondary
                      :disabled (and (plist-get (etaf-value more) :loading) t)
                      :on-press (lambda () (etaf-youtube-load-more model))))))))

(etaf-define-component etaf-youtube-list-header
    (&key model colors payload state view filter count)
  "Render the context header, search filter pills, topic chips or channel tabs."
  :render
  (let* ((title (or (etaf-youtube--nonempty-string (plist-get payload :title))
                    (etaf-youtube--view-title view model)))
         (filters (plist-get payload :filters))
         (tabs (plist-get payload :tabs))
         (count-label (if (and (integerp count) (> count 0))
                          (format "%s · %d 条" title count)
                        title)))
    (etaf-view
     (flex :flex-direction 'column :row-gap '(lh 1)
       (flex :flex-direction 'row :align-items 'center :justify-content 'space-between
             :column-gap '(ch 2)
         ;; Left: search filter chips, topic chips, or route heading
         (flex :if (eq view 'search) :flex-direction 'row :flex-wrap 'wrap
               :column-gap '(ch 1) :row-gap '(lh 0) :flex-grow 1
           (expr
            (mapcar
             (lambda (pair)
               (let* ((lbl (car pair))
                      (val (cdr pair))
                      (active (equal val (or filter "all"))))
                 (etaf-node
                  'box (list :height '(lh 1) :padding '((lh 0) (ch 2))
                             :role 'button :tab-index 0
                             :aria-label lbl :aria-selected active
                             :background-color (plist-get colors (if active :accent-soft :panel2))
                             :border (etaf-youtube--border
                                      (plist-get colors (if active :accent :line)))
                             :color (plist-get colors (if active :accent :muted))
                             :pointer (unless active 'hand)
                             :hover-style (unless active
                                            (list :background-color (plist-get colors :hover)
                                                  :color (plist-get colors :ink)))
                             :on-press (lambda ()
                                         (unless active
                                           (etaf-youtube-set-filter model val))))
                  (list (etaf-node 'text nil (list lbl))))))
             etaf-youtube--search-filters)))
         (etaf-youtube-chips :if (and (not (eq view 'search)) filters)
                             :model model :colors colors :chips filters)
         (text :if (and (not (eq view 'search)) (null filters))
               :font-weight 'bold :color (plist-get colors :ink)
           (expr title))
         ;; Right: subtle count badge
         (box :if (not (eq state 'loading)) :flex-shrink 0
           (text :color (plist-get colors :dim)
             (expr count-label))))
       (etaf-youtube-chips :if tabs
                           :model model :colors colors :chips tabs)))))

(etaf-define-component etaf-youtube-chips (&key model colors chips)
  "Render selectable topic or channel tab chips."
  :view
  (flex :flex-direction 'row :flex-wrap 'wrap :column-gap '(ch 1)
        :row-gap '(lh 1) :flex-grow 1
    (etaf-youtube-chip :for (chip chips)
                       :key (or (plist-get chip :title) "")
                       :model model :colors colors :chip chip)))

(etaf-define-component etaf-youtube-chip (&key model colors chip)
  "Render one filter chip with invariant border geometry and no active hover."
  :render
  (let ((selected (and (plist-get chip :selected) t))
        (title (or (plist-get chip :title) "")))
    (etaf-view
     (box :height '(lh 1) :padding '((lh 0) (ch 2))
          :role 'button :tab-index 0 :aria-label title :aria-selected selected
          :background-color (plist-get colors (if selected :accent-soft :panel2))
          :border (etaf-youtube--border (plist-get colors (if selected :accent :line)))
          :color (plist-get colors (if selected :accent :muted))
          :pointer (unless selected 'hand)
          :hover-style (unless selected
                         (list :background-color (plist-get colors :hover)
                               :color (plist-get colors :ink)))
          :on-press (lambda () (unless selected (etaf-youtube-apply-chip model chip)))
       (text (expr title))))))

(etaf-define-component etaf-youtube-skeleton-row (&key columns colors)
  "Render a placeholder card row while a list loads."
  :render
  (let* ((per-row (max 1 (min 4 (floor (/ (+ columns 2) 38)))))
         (card-columns (max 18 (floor (/ (- columns (* 2 (1- per-row))) per-row)))))
    (etaf-view
     (flex :flex-direction 'row :column-gap '(ch 2)
       (box :for (i (number-sequence 1 per-row)) :key i
            :width (list 'ch card-columns) :height '(lh 8)
            :background-color (plist-get colors :surface)
            :border (etaf-youtube--border (plist-get colors :line-soft)))))))

(etaf-define-component etaf-youtube-card
    (&key model colors item columns image-rows index)
  "Render one full-bleed bordered media card for ITEM.
Per-card reactive `:bindings' ensure selecting an item repaints only the two
affected cards, and image arrival repaints only the card whose thumbnail loaded."
  :bindings ((selected (plist-get model :selected))
             (item-index (etaf-prop :index))
             (item-source (etaf-prop :item))
             (selected-p (etaf-computed
                          (lambda () (eql (etaf-value selected) (etaf-value item-index)))))
             (image-version (etaf-youtube-images-version (plist-get model :images)))
             (artwork (etaf-computed
                       (lambda ()
                         (etaf-value image-version)
                         (etaf-youtube-images-descriptor
                          (plist-get model :images)
                          (plist-get (etaf-value item-source) :thumbnail)))
                       :test #'equal)))
  :render
  (let* ((active (etaf-value selected-p))
         (image (etaf-value artwork))
         (inner-cols (max 14 (- columns 2)))
         (image-size (etaf-youtube--thumbnail-size image inner-cols image-rows))
         (kind (plist-get item :kind))
         (portrait (member kind '(short "short")))
         (vid (plist-get item :id))
         (author (or (plist-get item :author) ""))
         (channel-id (etaf-youtube--nonempty-string (plist-get item :channel_id)))
         (has-author (not (string-empty-p author)))
         (text-cols (max 10 (- inner-cols 2)))
         (pixels (* (max 8 (1- text-cols))
                    (car (etaf-youtube--display-cell (etaf-display-metrics)))))
         (title-lines (etaf-youtube--caption-lines (plist-get item :title) pixels 2))
         (meta (string-join
                (seq-remove #'string-empty-p
                            (list (or (plist-get item :views) "")
                                  (or (plist-get item :published) "")))
                " · "))
         (duration (plist-get item :duration))
         (dur-sec (etaf-youtube--parse-duration-seconds duration))
         (is-live (or (plist-get item :live)
                      (and (stringp duration)
                           (string-match-p "LIVE\\|直播" duration))))
         (cached-resume (and (not is-live) (not portrait)
                             (etaf-youtube--store-cached-resume
                              (plist-get model :store) vid)))
         (resume-sec (and (numberp cached-resume) (> cached-resume 5) cached-resume))
         (pct-watched (let ((pw (plist-get item :percent_watched)))
                        (cond
                         ((and resume-sec (> dur-sec 0))
                          (min 100 (max 5 (round (* 100.0 (/ (float resume-sec) dur-sec))))))
                         ((and (numberp pw) (> pw 0)) (min 100 (round pw)))
                         (t nil))))
         ;; Top-left semantic pill (LIVE / Resume / Playlist)
         (top-badge (cond
                     (is-live "直播中")
                     (resume-sec (format "续播 %s" (etaf-youtube--clock resume-sec)))
                     ((member kind '(playlist "playlist")) "播放列表")))
         (top-badge-accent (or is-live resume-sec))
         ;; Bottom-right duration badge (never "0:00" for Shorts)
         (dur-badge (cond
                     (is-live "LIVE")
                     ((or portrait (equal duration "Shorts")) "Shorts")
                     ((and duration (not (equal duration ""))
                           (> dur-sec 0)
                           (not (member kind '(channel "channel" playlist "playlist"))))
                      (etaf-youtube--seconds duration)))))
    (etaf-view
     (box :role 'button :tab-index 0 :aria-label (or (plist-get item :title) "")
          :aria-selected active
          :width (list 'ch columns) :box-sizing 'border-box :overflow 'hidden
          :background-color (plist-get colors (if active :accent-soft :surface))
          :border (etaf-youtube--border (plist-get colors (if active :accent :line)))
          :pointer (unless active 'hand)
          :on-press (lambda () (etaf-youtube-press-item model index))
       (flex :flex-direction 'column :row-gap '(lh 0)
         ;; Full-bleed thumbnail stage
         (box :position 'relative :width 'stretch
              :height (list 'lh image-rows) :overflow 'hidden
              :background-color (plist-get colors :panel3)
           (flex :if image :flex-direction 'row :justify-content 'center
                 :align-items 'center :height (list 'lh image-rows)
             (image :src image :columns (car image-size) :rows (cdr image-size)))
           (box :if (not image) :width 'stretch :height 'stretch
                :text-align 'center
                :padding-top (list 'lh (max 0 (/ (- image-rows 1) 2)))
                :color (plist-get colors :dim)
             (text (expr (cond ((member kind '(channel "channel")) "频道")
                               ((member kind '(playlist "playlist")) "播放列表")
                               (t "视频")))))
           ;; Top-left status pill
           (box :if top-badge :position 'absolute :z-index 1
                :left '(ch 1) :top '(lh 0) :padding '((lh 0) (ch 1))
                :background-color (if top-badge-accent
                                      (plist-get colors :accent)
                                    (plist-get colors :badge))
                :color (if top-badge-accent "#FFFFFF" (plist-get colors :badge-ink))
             (text :font-weight 'bold (expr (or top-badge ""))))
           ;; Bottom-right duration pill
           (box :if dur-badge :position 'absolute :z-index 1
                :left (list 'ch (max 0 (- inner-cols (string-width (or dur-badge "")) 2)))
                :top (list 'lh (max 0 (1- image-rows))) :padding '((lh 0) (ch 1))
                :background-color (plist-get colors :badge)
                :color (plist-get colors :badge-ink)
             (text (expr (or dur-badge "")))))
         ;; Optional crimson watch-progress strip (zero border shift)
         (flex :if pct-watched :flex-direction 'row :width 'stretch :height '(lh 1)
               :background-color (plist-get colors :panel3)
           (box :width (list '% (or pct-watched 0)) :height '(lh 1)
                :background-color (plist-get colors :accent)))
         ;; Card info body (strict hover scoped to title/author text only)
         (flex :flex-direction 'column :padding '((lh 0.5) (ch 1)) :row-gap '(lh 0)
           (box :height '(lh 2) :overflow 'hidden
                :color (plist-get colors :ink)
                :hover-style (unless active
                               (list :color (plist-get colors :accent)))
             (text :font-weight 'bold
                   (expr (string-join title-lines "\n"))))
           (flex :flex-direction 'row :align-items 'center
                 :justify-content 'space-between :column-gap '(ch 1)
                 :height '(lh 1) :overflow 'hidden :wrap-mode 'none
             (box :if (and has-author (not portrait))
                  :flex-shrink 1 :height '(lh 1) :overflow 'hidden :wrap-mode 'none
                  :role (when channel-id 'button) :tab-index (when channel-id 0)
                  :color (plist-get colors (if active :accent :muted))
                  :pointer (when channel-id 'hand)
                  :hover-style (when channel-id
                                 (list :color (plist-get colors :accent)))
                  :help-echo (when channel-id (format "进入频道：%s" author))
                  :on-press (when channel-id
                              (lambda ()
                                (etaf-youtube-locate model 'channel (list :id channel-id))))
               (text (expr (etaf-youtube--clip-pixels author (/ pixels 2)))))
             (text :color (plist-get colors :dim)
                   (expr (etaf-youtube--clip-pixels meta (if has-author (/ pixels 2) pixels)))))))))))

(defun etaf-youtube-view (model)
  "Return the application View for MODEL."
  (etaf-view (etaf-youtube-app :model model)))

(provide 'etaf-youtube-views)
;;; etaf-youtube-views.el ends here
