;;; etaf-video-player-views.el --- Welcome, Cinema and Studio views -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure presentation Components for the video player shell:
;; - Product-grade Welcome / Continue Watching home stage when opened empty.
;; - Elevated header with media spec badges, live semantic status pill and
;;   collapsible drawer toggles (Media, Controls, Theater).
;; - Collapsible left Media Drawer (32 cols) with four leaf-scoped tabs:
;;   Queue (filterable, sortable & sibling-discoverable), Chapters, Bookmarks
;;   and Watch History.
;; - Collapsible right Studio Drawer (30 cols) with four IINA-inspired
;;   leaf-scoped tabs: Playback (speed, A-B, stop-after-current, step/tools),
;;   Tracks (multi-audio, audio delay, embedded/external subtitles, bilingual
;;   secondary subtitle, offset & scale), Video (aspect override, rotation,
;;   mirror, deinterlace, color equalizer, render mode) and Media Info.
;; - Three-zone Transport Dock with tactile timeline, remaining-time toggle,
;;   quick utility pills, centered transport controls and volume slider.
;; - Low-noise context footer carrying active chapter / transient feedback.
;;
;; All high-frequency playback and drawer refs are read inside leaf Components
;; so interactive adjustments never republish the root shell.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-video-player-theme)
(require 'etaf-video-player-media)

(defconst etaf-video-player--sidebar-cols 32
  "Width of the left media drawer in character cells.")
(defconst etaf-video-player--aside-cols 30
  "Width of the right studio drawer in character cells.")
(defconst etaf-video-player--gutter-cols 1
  "Gutter separating the stage from side drawers or window edges, in cells.")
(defconst etaf-video-player--sidebar-min-cols 96
  "Minimum viewport width in columns to display the left media drawer.")
(defconst etaf-video-player--aside-min-cols 128
  "Minimum viewport width in columns to display the right studio drawer.")
(defconst etaf-video-player--aside-min-body-rows 22
  "Minimum body rows required to display the right drawer cleanly.")
(defconst etaf-video-player--bar-rows 5
  "Rows reserved for the transport dock (padding, timeline, gap, controls).")
(defconst etaf-video-player--chrome-rows 7
  "Non-stage rows: header (1), transport dock (5) and context footer (1).")
(defconst etaf-video-player--stage-ref 'etaf-video-player-stage
  "Host reference of the video stage.")

(defun etaf-video-player--view-value (value)
  "Read display VALUE or reactive source inside its consuming Component."
  (if (or (etaf-ref-p value) (etaf-computed-p value)) (etaf-value value) value))

(defun etaf-video-player--border (color)
  "Return a 1px solid border in COLOR."
  (list '(px 1) 'solid color))

(defun etaf-video-player--fmt-clock (seconds)
  "Format SECONDS as `MM:SS' or `H:MM:SS', or `--:--' when nil."
  (if (numberp seconds)
      (let* ((whole (max 0 (floor seconds)))
             (hours (/ whole 3600))
             (minutes (/ (% whole 3600) 60))
             (rest (% whole 60)))
        (if (> hours 0)
            (format "%d:%02d:%02d" hours minutes rest)
          (format "%02d:%02d" minutes rest)))
    "--:--"))

(etaf-define-component etaf-video-player--pill
    (&key label active selected tone ref help on-press width)
  "Render a crisp single-row interactive pill with hover discipline.
ACTIVE marks a no-op/already-selected option (suppresses hover and hand
pointer); SELECTED marks an active toggle that can still be clicked off.
TONE is `accent', `solid', `ok', `warn', `surface' or `ghost'."
  :render
  (let* ((eff-tone (or tone (if (or active selected) 'accent 'ghost)))
         (tinted (memq eff-tone '(solid accent ok warn)))
         (fg (pcase eff-tone
               ('solid (etaf-video-player-color :accent-fg))
               ('accent (etaf-video-player-color :accent-text))
               ('ok (etaf-video-player-color :ok))
               ('warn (etaf-video-player-color :warn))
               ('surface (etaf-video-player-color :ink))
               (_ (etaf-video-player-color :muted))))
         (bg (pcase eff-tone
               ('solid (etaf-video-player-color :accent))
               ('accent (etaf-video-player-color :accent-soft))
               ('ok (etaf-video-player-color :ok-bg))
               ('warn (etaf-video-player-color :warn-bg))
               ('surface (etaf-video-player-color :panel3))
               (_ nil)))
         (hover-bg (unless (or active tinted)
                     (etaf-video-player-color :panel3)))
         (hover-fg (unless (or active tinted)
                     (etaf-video-player-color :ink))))
    (etaf-view
     (box :ref ref :role 'button :tab-index 0
          :aria-selected (and (or active selected) t)
          :height '(lh 1) :width (or width 'max-content) :flex-shrink 0
          :padding '((lh 0) (ch 1)) :text-align 'center
          :font-weight (if (or active selected (memq eff-tone '(solid accent))) 'bold 'normal)
          :color fg :background-color bg
          :pointer (unless active 'hand)
          :hover-style (when (and (not active) (or hover-bg hover-fg))
                         (append (when hover-bg (list :background-color hover-bg))
                                 (when hover-fg (list :color hover-fg))))
          :help-echo help :on-press on-press
       (text (expr label))))))

(etaf-define-component etaf-video-player--tab-item
    (&key label active ref help on-press)
  "Render one drawer tab item with calm active presentation."
  :view
  (box :ref ref :role 'tab :tab-index 0 :aria-selected (and active t)
       :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
       :height '(lh 1) :text-align 'center :overflow 'hidden
       :font-weight (if active 'bold 'normal)
       :color (etaf-video-player-color (if active :accent-text :muted))
       :background-color (when active (etaf-video-player-color :accent-soft))
       :pointer (unless active 'hand)
       :hover-style (unless active (list :color (etaf-video-player-color :ink)))
       :help-echo help :on-press on-press
    (text (expr label))))

;;; ---------------------------------------------------------------------------
;;; Welcome / Continue Watching Home Stage (when opened with no source)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-video-player--view-welcome
    (&key mpv-available history-ref viewport-width viewport-rows
          on-open-file on-open-url on-demo on-open-history
          on-delete-history on-clear-history on-toggle-theme on-help)
  "Render the product-grade Welcome and Continue Watching launcher screen."
  :render
  (let* ((items (seq-take (or (etaf-video-player--view-value history-ref) nil) 6))
         (body-rows (max 1 (- viewport-rows 2)))
         (wide (>= viewport-width 900))
         (card-width (if wide '(ch 78) 'stretch))
         (engine-label (if mpv-available "● libmpv 就绪" "ffmpeg 引擎"))
         (engine-sub (if mpv-available
                         "libmpv 内核 · 硬件解码 · 多音轨 · 内嵌 / ASS / 双语字幕 · 支持 B 站 / YouTube 与文件拖放"
                       "ffmpeg 引擎 · 本地视频 / 目录 / HTTP(S) 流 / 外挂字幕 · 编译 libmpv 模块可解锁多轨与画面滤镜")))
    (etaf-view
     (flex :flex-direction 'column :width (list 'px viewport-width)
           :height (list 'lh viewport-rows) :overflow 'hidden
           :background-color (etaf-video-player-color :bg)
           :color (etaf-video-player-color :ink)
       ;; Header
       (flex :height '(lh 1) :flex-shrink 0 :align-items 'center
             :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 2))
             :region '(:id header :label "顶栏" :key "b" :enter video-welcome-open)
             :background-color (etaf-video-player-color :panel2)
             :border-bottom (etaf-video-player--border (etaf-video-player-color :line))
         (etaf-ui-icon :name 'video :set 'svg :size 0.9 :min-width 2
                       :color (etaf-video-player-color :accent))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :height '(lh 1) :overflow 'hidden :font-weight 'bold
           (text "视频播放器"))
         (box :height '(lh 1) :flex-shrink 0 :padding '((lh 0) (ch 1))
              :font-weight (if mpv-available 'bold 'normal)
              :background-color (etaf-video-player-color (if mpv-available :ok-bg :panel3))
              :color (etaf-video-player-color (if mpv-available :ok :muted))
           (text (expr engine-label)))
         (etaf-video-player--pill :ref 'video-open :label "+ 打开" :tone 'surface
                                  :help "打开视频文件、目录或 .m3u 列表 (o)"
                                  :on-press on-open-file)
         (etaf-video-player--pill :if wide :ref 'video-open-url :label "网络流 u" :tone 'surface
                                  :help "打开 HTTP(S) / B 站 / YouTube 网址 (u)"
                                  :on-press on-open-url)
         (etaf-video-player--pill :ref 'video-theme :label "明暗" :tone 'ghost
                                  :help "切换深浅主题 (T)" :on-press on-toggle-theme)
         (etaf-video-player--pill :ref 'video-help :label "?" :tone 'ghost
                                  :help "列出全部键位 (?)" :on-press on-help))
       ;; Scrollable centered launcher body
       (box :width 'stretch :height (list 'lh body-rows) :overflow 'scroll
            :padding (if wide '((lh 2) (ch 4)) '((lh 1) (ch 2)))
         (flex :width 'stretch :justify-content 'center
           (flex :flex-direction 'column :width card-width
                 :padding '((lh 2) (ch 3)) :gap '((lh 1) (ch 0))
                 :background-color (etaf-video-player-color :surface)
                 :border (etaf-video-player--border (etaf-video-player-color :line))
             ;; Hero title + subtitle
             (flex :flex-direction 'column :flex-shrink 0
               (box :height '(lh 1) :font-weight 'bold
                    :color (etaf-video-player-color :ink)
                 (text "ETAF 视频播放器"))
               (box :height '(lh 1) :overflow 'hidden
                    :color (etaf-video-player-color :muted)
                 (text (expr engine-sub))))
             ;; Primary actions
             (flex :height '(lh 1) :flex-shrink 0 :align-items 'center :gap '((lh 0) (ch 2))
               (etaf-video-player--pill :ref 'video-welcome-open
                                        :label "+ 打开视频或目录 (o)" :tone 'solid
                                        :help "选择本地视频文件、目录或 .m3u 播放列表 (o)"
                                        :on-press on-open-file)
               (etaf-video-player--pill :ref 'video-welcome-url
                                        :label "打开网络流 URL (u)" :tone 'surface
                                        :help "输入 HTTP(S) 视频流或网页视频链接 (u)"
                                        :on-press on-open-url)
               (etaf-video-player--pill :ref 'video-welcome-demo
                                        :label "测试画面 (d)" :tone 'ghost
                                        :help "播放内建测试信号 (d)"
                                        :on-press on-demo))
             (etaf-divider)
             ;; Continue Watching section
             (flex :flex-direction 'column :flex-shrink 0 :gap '((lh 1) (ch 0))
               (flex :height '(lh 1) :flex-shrink 0 :align-items 'center
                     :justify-content 'space-between
                 (box :height '(lh 1) :font-weight 'bold
                      :color (etaf-video-player-color :muted)
                   (text "继续观看"))
                 (flex :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 2))
                   (box :if items :height '(lh 1) :color (etaf-video-player-color :dim)
                     (text "点击条目直接打开并断点续播"))
                   (etaf-video-player--pill :if items :ref 'video-welcome-clear
                                            :label "清空历史" :tone 'ghost
                                            :help "清空全部观看历史"
                                            :on-press on-clear-history)))
               (flex :if items :flex-direction 'column :gap '((lh 1) (ch 0))
                 (flex :for (rec items) :key (plist-get rec :path)
                       :width 'stretch :height '(lh 2) :align-items 'center
                       :gap '((lh 0) (ch 2)) :padding '((lh 0) (ch 2))
                       :background-color (etaf-video-player-color :panel2)
                       :border-left (list '(px 2) 'solid
                                          (etaf-video-player-color
                                           (if (equal rec (car items)) :accent :line)))
                   (flex :flex-direction 'column :height '(lh 2) :flex-grow 1 :min-width '(ch 0)
                         :role 'button :tab-index 0 :pointer 'hand
                         :help-echo (format "继续播放：%s" (plist-get rec :path))
                         :on-press (lambda () (funcall on-open-history (plist-get rec :path)))
                     (box :height '(lh 1) :overflow 'hidden
                          :font-weight (if (equal rec (car items)) 'bold 'normal)
                          :color (etaf-video-player-color :ink)
                          :hover-style (list :color (etaf-video-player-color :accent-text))
                       (text (expr (file-name-nondirectory (plist-get rec :path)))))
                     (box :height '(lh 1) :overflow 'hidden
                          :color (etaf-video-player-color :dim)
                       (text (expr (let* ((dir (file-name-directory (plist-get rec :path)))
                                          (short-dir (if dir
                                                         (abbreviate-file-name
                                                          (directory-file-name dir))
                                                       "本地"))
                                          (pos (plist-get rec :position))
                                          (dur (plist-get rec :duration)))
                                     (if (and (numberp dur) (> dur 0))
                                         (format "%s · 上次看到 %s / %s"
                                                 short-dir
                                                 (etaf-video-player--fmt-clock pos)
                                                 (etaf-video-player--fmt-clock dur))
                                       (format "%s · 上次看到 %s"
                                               short-dir
                                               (etaf-video-player--fmt-clock pos))))))))
                   (etaf-video-player--pill
                    :label (let* ((pos (plist-get rec :position))
                                  (dur (plist-get rec :duration))
                                  (pct (when (and (numberp dur) (> dur 0))
                                         (min 100 (round (* 100.0 (/ (float pos) dur)))))))
                             (if pct (format "%d%% ▶" pct) "续播 ▶"))
                    :tone (if (equal rec (car items)) 'accent 'surface)
                    :help "打开并从上次位置继续播放"
                    :on-press (lambda () (funcall on-open-history (plist-get rec :path))))
                   (etaf-video-player--pill :label "×" :tone 'ghost :help "移除此条记录"
                                            :on-press (lambda ()
                                                        (funcall on-delete-history
                                                                 (plist-get rec :path))))))
               (box :if (null items) :height '(lh 2) :padding '((lh 0) (ch 2))
                    :background-color (etaf-video-player-color :panel2)
                    :color (etaf-video-player-color :dim)
                 (text "暂无观看记录 · 直接拖放 Finder 中的视频/文件夹到此窗口，或按 o 打开")))
             (etaf-divider)
             ;; Quick start hints
             (flex :flex-direction 'column :flex-shrink 0
               (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
                 (text "快捷上手"))
               (box :height '(lh 1) :overflow 'hidden :color (etaf-video-player-color :dim)
                 (text "• 拖放：支持直接把视频、文件夹、.m3u 列表或 .srt/.ass 字幕拖入此窗口"))
               (box :height '(lh 1) :overflow 'hidden :color (etaf-video-player-color :dim)
                 (text "• 播放：SPC 暂停 · f/b ±5s · ,/. 逐帧回退/前进 · A/B 循环 · g 时间/百分比跳转"))
               (box :height '(lh 1) :overflow 'hidden :color (etaf-video-player-color :dim)
                 (text "• 进阶：p 媒体栏 · i 控制/轨道/画面栏 · w 剧场 · v 切音轨 · V 切字幕 · r 旋转"))))))
       ;; Footer
       (flex :height '(lh 1) :flex-shrink 0 :align-items 'center
             :justify-content 'space-between :gap '((lh 0) (ch 2)) :padding '((lh 0) (ch 2))
             :background-color (etaf-video-player-color :bg)
             :border-top (etaf-video-player--border (etaf-video-player-color :line))
         (box :height '(lh 1) :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :overflow 'hidden :color (etaf-video-player-color :muted)
           (text "就绪 · 拖放视频文件或按 o 打开本地视频 / 目录"))
         (box :height '(lh 1) :flex-shrink 0 :overflow 'hidden
              :color (etaf-video-player-color :dim)
           (text "o 打开 · u 网址 · d 演示 · T 主题 · ? 帮助 · q 关闭")))))))

;;; ---------------------------------------------------------------------------
;;; Header (Active Playback)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-video-player--view-header-spec
    (&key media-ref spec)
  "Render concise media spec badges (resolution/fps + codec) in a leaf scope."
  :render
  (let* ((info (etaf-video-player--view-value media-ref))
         (height (or (plist-get info :height) (plist-get spec :height)))
         (fps (or (plist-get info :fps) (plist-get spec :fps)))
         (codec (plist-get info :video-codec))
         (res-tag (cond ((and (numberp height) (>= height 2000)) "4K")
                        ((and (numberp height) (>= height 1400)) "2K")
                        ((and (numberp height) (>= height 1000)) "1080p")
                        ((and (numberp height) (>= height 700)) "720p")
                        ((and (numberp height) (> height 0)) (format "%dp" (round height)))))
         (spec-text (cond ((and res-tag (numberp fps) (> fps 0))
                           (format "%s · %d fps" res-tag (round fps)))
                          (res-tag res-tag))))
    (etaf-view
     (flex :if (or spec-text codec) :height '(lh 1) :flex-shrink 0
           :align-items 'center :gap '((lh 0) (ch 1))
       (box :if spec-text :height '(lh 1) :flex-shrink 0
            :padding '((lh 0) (ch 1))
            :background-color (etaf-video-player-color :panel3)
            :color (etaf-video-player-color :muted)
         (text (expr spec-text)))
       (box :if codec :height '(lh 1) :flex-shrink 0
            :padding '((lh 0) (ch 1))
            :background-color (etaf-video-player-color :panel3)
            :color (etaf-video-player-color :muted)
         (text (expr codec)))))))

(etaf-define-component etaf-video-player--view-status-pill
    (&key status-kind-ref status-ref status)
  "Render the live semantic playback status pill in its own leaf scope."
  :render
  (let* ((kind (etaf-video-player--view-value status-kind-ref))
         (fg (pcase kind
               ('playing (etaf-video-player-color :ok))
               ('buffering (etaf-video-player-color :warn))
               ('error (etaf-video-player-color :danger))
               (_ (etaf-video-player-color :muted))))
         (bg (pcase kind
               ('playing (etaf-video-player-color :ok-bg))
               ('buffering (etaf-video-player-color :warn-bg))
               ('error (etaf-video-player-color :danger-bg))
               (_ (etaf-video-player-color :panel3)))))
    (etaf-view
     (box :height '(lh 1) :flex-shrink 0 :padding '((lh 0) (ch 1))
          :font-weight (if (memq kind '(playing error)) 'bold 'normal)
          :color fg :background-color bg
       (text :ref status-ref :id (symbol-name status-ref)
         (expr (etaf-video-player--view-value status)))))))

(etaf-define-component etaf-video-player--view-header
    (&key title spec media-ref status-kind-ref status-ref status
          left-open right-open can-sidebar can-aside tier pip-active
          on-toggle-left on-toggle-right on-toggle-theater
          on-toggle-fullscreen on-toggle-pip
          on-open-file on-toggle-theme on-help
          position left top width height)
  "Render the single-row elevated cinema header."
  :render
  (let ((wide (eq tier 'wide))
        (compact (eq tier 'compact))
        (theater (and (not left-open) (not right-open))))
    (etaf-view
     (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
           :width (or width 'stretch) :height (or height '(lh 1)) :align-items 'center
           :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 2))
           :region '(:id header :label "顶栏" :key "b" :enter video-theme)
           :background-color (etaf-video-player-color :panel2)
           :border-bottom (etaf-video-player--border (etaf-video-player-color :line))
       (etaf-ui-icon :name 'video :set 'svg :size 0.9 :min-width 2
                     :color (etaf-video-player-color :accent))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :overflow 'hidden :font-weight 'bold
         (text :color (etaf-video-player-color :ink)
           (expr (or title "未选择来源"))))
       (etaf-video-player--view-header-spec :if wide :media-ref media-ref :spec spec)
       (etaf-video-player--view-status-pill
        :status-kind-ref status-kind-ref :status-ref status-ref :status status)
       (etaf-video-player--pill
        :if (and (not compact) can-sidebar) :ref 'video-media-toggle
        :label "媒体 p" :selected left-open :tone (if left-open 'accent 'ghost)
        :help "开关左侧媒体栏 (p)" :on-press on-toggle-left)
       (etaf-video-player--pill
        :if (and (not compact) can-aside) :ref 'video-inspector-toggle
        :label "控制 i" :selected right-open :tone (if right-open 'accent 'ghost)
        :help "开关右侧控制、轨道与画面栏 (i)" :on-press on-toggle-right)
       (etaf-video-player--pill
        :if (and (not compact) (or can-sidebar can-aside)) :ref 'video-theater-toggle
        :label "剧场 w" :selected theater :tone (if theater 'accent 'ghost)
        :help "切换剧场模式 (w)" :on-press on-toggle-theater)
       (etaf-video-player--pill
        :if on-toggle-fullscreen :ref 'video-fullscreen-toggle
        :label "全屏" :tone 'ghost
        :help "纯净全屏 (W 网页全屏 / Z 系统真全屏)" :on-press on-toggle-fullscreen)
       (etaf-video-player--pill
        :if (and (not compact) on-toggle-pip) :ref 'video-pip-toggle
        :label "PiP" :selected pip-active :tone (if pip-active 'accent 'ghost)
        :help "悬浮画中画 (P)" :on-press on-toggle-pip)
       (etaf-video-player--pill
        :if wide :ref 'video-open :label "+ 打开" :tone 'surface
        :help "打开视频文件、目录或 .m3u 列表 (o)" :on-press on-open-file)
       (etaf-video-player--pill
        :ref 'video-theme :label "明暗" :tone 'ghost
        :help "切换明暗主题 (T)" :on-press on-toggle-theme)
       (etaf-video-player--pill
        :ref 'video-help :label "?" :tone 'ghost
        :help "列出全部键位 (?)" :on-press on-help)))))

(etaf-define-component etaf-video-player--view-cinema-topbar
    (&key title index count cols fs-mode
          on-toggle-frame on-toggle-pip on-exit
          position left top width height)
  "Ultra-slim 1-row Pure Fullscreen top bar mirroring PiP's aligned chrome."
  :render
  (let* ((hpad-cols (if (< cols 52) 1 2))
         (qbadge (when (and (> (or count 0) 1) (>= cols 56))
                   (format "%d / %d" (1+ (or index 0)) count)))
         (frame-p (eq fs-mode 'frame)))
    (etaf-view
     (flex :ref 'video-cinema-topbar
           :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
           :width (or width 'stretch) :height (or height '(lh 1))
           :align-items 'center :gap '((lh 0) (ch 1))
           :padding (list '(lh 0) (list 'ch hpad-cols))
           :background-color (etaf-video-player-color :panel2)
           :border-bottom (etaf-video-player--border (etaf-video-player-color :line))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
           (box :flex-shrink 1 :min-width '(ch 8) :height '(lh 1)
                :overflow 'hidden :wrap-mode 'none
             (text :color (etaf-video-player-color :ink) :font-weight 'bold
               (expr (or title "视频播放器"))))
           (box :if qbadge :flex-shrink 0 :height '(lh 1) :padding '((lh 0) (ch 1))
                :background-color (etaf-video-player-color :accent-soft)
                :color (etaf-video-player-color :accent-text)
             (text :font-weight 'bold (expr qbadge)))))
       (box :if (>= cols 76) :ref 'video-cinema-frame-fs :id "video-cinema-frame-fs"
            :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (etaf-video-player-color (if frame-p :accent-soft :panel3))
            :color (etaf-video-player-color (if frame-p :accent-text :ink))
            :font-weight (if frame-p 'bold 'normal)
            :hover-style (unless frame-p
                           (list :color (etaf-video-player-color :ink)
                                 :background-color (etaf-video-player-color :track)))
            :help-echo "切换系统真全屏，退出自动还原分屏 (Z)"
            :on-press on-toggle-frame
         (text "真全屏 Z"))
       (etaf-video-player--pill :if (and (>= cols 54) on-toggle-pip)
                                :ref 'video-cinema-pip :label "PiP" :tone 'surface
                                :help "切换到悬浮画中画 (P)" :on-press on-toggle-pip)
       (box :ref 'video-cinema-exit :id "video-cinema-exit"
            :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (etaf-video-player-color :accent-soft)
            :color (etaf-video-player-color :accent-text)
            :font-weight 'bold
            :hover-style (list :background-color (etaf-video-player-color :accent)
                               :color "#FFFFFF")
            :help-echo "退出全屏返回主界面 (W / Esc)"
            :on-press on-exit
         (text (expr (if (< cols 48) "↩" "↩ 退出"))))))))

(etaf-define-component etaf-video-player--view-cinema-deck
    (&key px-w cols rows cw playing-ref audio-ref volume-ref speed-ref
          subtitle-on-ref progress-ref progress-fill-ref progress-id
          time-ref time-text on-seek on-toggle on-prev on-next
          on-toggle-audio on-vol-delta on-cycle-speed on-toggle-sub
          gap-mid position left top width height)
  "Shared 4-tier optically-aligned transport deck for both Fullscreen and PiP."
  :render
  (let* ((playing (etaf-video-player--view-value playing-ref))
         (audio-on (etaf-video-player--view-value audio-ref))
         (vol (round (or (etaf-video-player--view-value volume-ref) 100)))
         (spd (or (etaf-video-player--view-value speed-ref) 1))
         (sub-on (and (etaf-video-player--view-value subtitle-on-ref) t))
         (mini (< cols 44))
         (cinema (>= cols 88))
         (hpad-cols (if (< cols 52) 1 2))
         (ctrl-pad-cols (max 0 (1- hpad-cols)))
         (right-pad-cols (if mini ctrl-pad-cols hpad-cols))
         (has-mid (and gap-mid (>= rows 14)))
         (has-bot (>= rows 8))
         (trans-rows (+ 2 (if has-mid 1 0) (if has-bot 1 0))))
    (etaf-view
     (column :ref 'video-cinema-deck
             :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
             :width (or width 'stretch) :height (or height (list 'lh trans-rows))
             :item-gap '(lh 0)
             :background-color (etaf-video-player-color :panel2)
             :border-top (etaf-video-player--border (etaf-video-player-color :line))
       ;; Row 1: Full-width Interactive Hairline Seek Bar
       (box :width 'stretch :height '(lh 1)
            :padding (list '(lh 0) (list 'ch hpad-cols))
         (box :width (list 'px (max 60 (- px-w (* 2 hpad-cols cw)))) :height '(lh 1)
           (etaf-range :min 0 :max 100 :bar-height 22
                       :value progress-ref
                       :fill-ref progress-fill-ref
                       :ref (or progress-id 'video-cinema-progress)
                       :color (etaf-video-player-color :accent)
                       :track-color (etaf-video-player-color :panel3)
                       :label "拖动或点击进度条跳转"
                       :on-commit on-seek)))
       ;; Optional middle breathing row in Fullscreen (matches normal transport spacing)
       (box :if has-mid :width 'stretch :height '(lh 1))
       ;; Controls Row
       (flex :width 'stretch :height '(lh 1) :align-items 'center
             :padding-left (list 'ch ctrl-pad-cols)
             :padding-right (list 'ch right-pad-cols)
             :gap (if mini '((lh 0) (ch 0)) '((lh 0) (ch 1)))
         (flex :height '(lh 1) :align-items 'center :flex-shrink 0 :gap '((lh 0) (ch 0))
           (box :ref 'video-cinema-prev :height '(lh 1) :padding '((lh 0) (ch 1))
                :flex-shrink 0 :role 'button :tab-index 0 :pointer 'hand
                :color (etaf-video-player-color :muted)
                :hover-style (list :color (etaf-video-player-color :ink)
                                   :background-color (etaf-video-player-color :track))
                :help-echo "上一个视频 (<)" :on-press on-prev
             (etaf-ui-icon :name 'previous :set 'svg :size 0.85 :min-width 2
                           :color (etaf-video-player-color :muted)))
           (box :ref 'video-cinema-play :id "video-cinema-play"
                :width '(ch 3) :height '(lh 1)
                :flex-shrink 0 :role 'button :tab-index 0 :pointer 'hand
                :background-color (etaf-video-player-color :accent) :color "#FFFFFF"
                :font-weight 'bold :help-echo "播放 / 暂停 (SPC)"
                :on-press on-toggle
             (etaf-ui-icon :name (if playing 'pause 'play) :set 'svg :size 0.85
                           :min-width 3 :color "#FFFFFF"))
           (box :ref 'video-cinema-next :height '(lh 1) :padding '((lh 0) (ch 1))
                :flex-shrink 0 :role 'button :tab-index 0 :pointer 'hand
                :color (etaf-video-player-color :muted)
                :hover-style (list :color (etaf-video-player-color :ink)
                                   :background-color (etaf-video-player-color :track))
                :help-echo "下一个视频 (>)" :on-press on-next
             (etaf-ui-icon :name 'next :set 'svg :size 0.85 :min-width 2
                           :color (etaf-video-player-color :muted))))
         (flex :if (and cinema on-vol-delta) :height '(lh 1) :align-items 'center
               :flex-shrink 0 :background-color (etaf-video-player-color :panel3)
           (etaf-video-player--pill :label "−" :tone 'ghost :help "降低音量 ([)"
                                    :on-press (lambda () (funcall on-vol-delta -10)))
           (etaf-video-player--pill :ref 'video-cinema-mute
                                    :label (if audio-on (format "♪ %3d%%" vol) "× 静音")
                                    :selected (not audio-on)
                                    :tone (if audio-on 'ghost 'accent)
                                    :help "静音 (a / M) · 音量 [ / ]"
                                    :on-press on-toggle-audio)
           (etaf-video-player--pill :label "+" :tone 'ghost :help "提高音量 (])"
                                    :on-press (lambda () (funcall on-vol-delta 10))))
         (etaf-video-player--pill :if (and (not mini) (not (and cinema on-vol-delta)))
                                  :ref 'video-cinema-mute
                                  :label (if audio-on (format "♪ %d%%" vol) "× 静音")
                                  :selected (not audio-on)
                                  :tone (if audio-on 'ghost 'accent)
                                  :help "静音 (a / M) · 音量 [ / ]"
                                  :on-press on-toggle-audio)
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :height '(lh 1) :text-align 'center :overflow 'hidden :wrap-mode 'none
              :color (etaf-video-player-color :muted)
           (text :ref time-ref :id (symbol-name time-ref)
             (expr time-text)))
         (etaf-video-player--pill :if mini :ref 'video-cinema-mute
                                  :label (if audio-on "♪" "×")
                                  :selected (not audio-on)
                                  :tone (if audio-on 'ghost 'accent)
                                  :help "静音 (a / M)" :on-press on-toggle-audio)
         (etaf-video-player--pill :if (not mini) :ref 'video-cinema-speed
                                  :label (format "%gx" spd)
                                  :selected (/= spd 1)
                                  :tone (if (/= spd 1) 'accent 'ghost)
                                  :help "切换倍速 (+ / -)" :on-press on-cycle-speed)
         (etaf-video-player--pill :if (not mini) :ref 'video-cinema-cc
                                  :label "CC" :selected sub-on
                                  :tone (if sub-on 'accent 'ghost)
                                  :help "开关字幕 (c)" :on-press on-toggle-sub))
       ;; Bottom Row: Exact 1-row bottom breathing cushion
       (box :if has-bot :width 'stretch :height '(lh 1))))))

;;; ---------------------------------------------------------------------------
;;; Left Media Drawer: Queue / Chapters / Bookmarks / History
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-video-player--view-track-row
    (&key position title subtitle duration watched active on-press)
  "Render one two-line playlist item with border-left accent and calm hover."
  :view
  (flex :position 'relative :width 'stretch :height '(lh 2)
        :align-items 'center :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
        :role 'button :tab-index 0 :aria-selected (and active t)
        :pointer (unless active 'hand)
        :ref (intern (format "video-track-%d" position))
        :help-echo (format "播放第 %d 个：%s" (1+ position) title)
        :on-press on-press
        :background-color (etaf-video-player-color (if active :accent-soft :surface))
        :border-left (list '(px 2) 'solid
                           (etaf-video-player-color (if active :accent :surface)))
    (box :width '(ch 3) :height '(lh 1) :flex-shrink 0 :text-align 'right
         :color (etaf-video-player-color (if active :accent-text :dim))
      (text (expr (number-to-string (1+ position)))))
    (flex :flex-direction 'column :height '(lh 2) :min-width '(ch 0)
          :flex-grow 1 :flex-basis '(ch 0)
      (box :height '(lh 1) :overflow 'hidden :font-weight (if active 'bold 'normal)
           :color (etaf-video-player-color (if active :accent-text :ink))
           :hover-style (unless active (list :color (etaf-video-player-color :accent-text)))
        (text (expr title)))
      (box :height '(lh 1) :overflow 'hidden
           :color (etaf-video-player-color (if active :muted :dim))
        (text (expr (if watched (format "%s · %s" subtitle watched) subtitle)))))
    (box :width '(ch 5) :height '(lh 1) :flex-shrink 0 :text-align 'right
         :color (etaf-video-player-color (if active :accent-text :muted))
      (text (expr duration)))))

(etaf-define-component etaf-video-player--view-queue-tab
    (&key entries active count filter-ref list-rows total-label
          on-play on-enqueue on-remove on-move-up on-move-down
          on-enqueue-siblings on-sort-queue)
  "Render the filterable, sortable playlist queue inside the left drawer."
  :render
  (let* ((query (string-trim (downcase (or (etaf-video-player--view-value filter-ref) ""))))
         (visible (if (string-empty-p query)
                      entries
                    (cl-remove-if-not
                     (lambda (entry)
                       (or (string-match-p (regexp-quote query)
                                           (downcase (or (plist-get (cdr entry) :title) "")))
                           (string-match-p (regexp-quote query)
                                           (downcase (or (plist-get (cdr entry) :subtitle) "")))))
                     entries)))
         (summary (if (string-empty-p query)
                      total-label
                    (format "命中 %d / %d 个" (length visible) count))))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :flex-grow 1 :min-height '(lh 0)
       (flex :height '(lh 2) :flex-shrink 0 :align-items 'center
             :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
         (etaf-text-input :bind filter-ref :placeholder "筛选队列..."
                          :hide-label t :variant 'outlined :width '(ch 18)
                          :ref 'video-queue-filter)
         (etaf-video-player--pill :ref 'video-queue-add :label "+" :tone 'surface
                                  :help "添加视频、目录或 .m3u 到队列" :on-press on-enqueue)
         (etaf-video-player--pill :ref 'video-queue-del :label "−" :tone 'surface
                                  :help "移除当前条目 (D)" :on-press on-remove))
       (box :if (> list-rows 0) :ref 'video-playlist-scroll
            :width 'stretch :height (list 'lh list-rows) :overflow 'scroll
         (flex :flex-direction 'column :width 'stretch
           (etaf-video-player--view-track-row
            :for (entry visible) :key (car entry)
            :position (car entry)
            :title (plist-get (cdr entry) :title)
            :subtitle (plist-get (cdr entry) :subtitle)
            :duration (plist-get (cdr entry) :duration)
            :watched (plist-get (cdr entry) :watched)
            :active (= (car entry) active)
            :on-press (lambda () (funcall on-play (car entry))))
           (box :if (null visible) :padding '((lh 1) (ch 2))
                :color (etaf-video-player-color :dim)
             (text "没有匹配的队列条目"))))
       (flex :height '(lh 1) :flex-shrink 0 :align-items 'center
             :justify-content 'space-between :padding '((lh 0) (ch 1))
             :border-top (etaf-video-player--border (etaf-video-player-color :line))
         (box :height '(lh 1) :flex-grow 1 :min-width '(ch 0) :overflow 'hidden
              :color (etaf-video-player-color :dim)
           (text (expr summary)))
         (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 0))
           (etaf-video-player--pill :ref 'video-queue-siblings :label "同目录" :tone 'ghost
                                    :help "把当前视频同目录全部剧集加入队列"
                                    :on-press on-enqueue-siblings)
           (etaf-video-player--pill :ref 'video-queue-sort :label "排序" :tone 'ghost
                                    :help "按名称排序队列"
                                    :on-press on-sort-queue)
           (etaf-video-player--pill :ref 'video-queue-up :label "↑" :tone 'ghost
                                    :help "上移当前项 (K)" :on-press on-move-up)
           (etaf-video-player--pill :ref 'video-queue-down :label "↓" :tone 'ghost
                                    :help "下移当前项 (J)" :on-press on-move-down)))))))

(etaf-define-component etaf-video-player--view-chapters-tab
    (&key media-ref chapters-ref active-chapter-ref list-rows on-seek)
  "Render embedded container chapters (from libmpv or ffprobe)."
  :render
  (let* ((live-ch (etaf-video-player--view-value chapters-ref))
         (info (etaf-video-player--view-value media-ref))
         (chapters (or live-ch (plist-get info :chapters)))
         (active-idx (etaf-video-player--view-value active-chapter-ref)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :flex-grow 1 :min-height '(lh 0)
       (box :if (> list-rows 0) :ref 'video-chapters-scroll
            :width 'stretch :height (list 'lh list-rows) :overflow 'scroll
         (flex :flex-direction 'column :width 'stretch
           (flex :for (ch chapters) :key (plist-get ch :index)
                 :width 'stretch :height '(lh 2) :align-items 'center
                 :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
                 :role 'button :tab-index 0
                 :aria-selected (eql (plist-get ch :index) active-idx)
                 :pointer (unless (eql (plist-get ch :index) active-idx) 'hand)
                 :background-color (etaf-video-player-color
                                    (if (eql (plist-get ch :index) active-idx)
                                        :accent-soft :surface))
                 :border-left (list '(px 2) 'solid
                                    (etaf-video-player-color
                                     (if (eql (plist-get ch :index) active-idx)
                                         :accent :surface)))
                 :help-echo (format "跳转到章节：%s" (plist-get ch :title))
                 :on-press (lambda () (funcall on-seek (plist-get ch :start)))
             (box :width '(ch 2) :height '(lh 1) :flex-shrink 0 :text-align 'right
                  :color (etaf-video-player-color
                          (if (eql (plist-get ch :index) active-idx) :accent-text :dim))
               (text (expr (format "%02d" (1+ (plist-get ch :index))))))
             (flex :flex-direction 'column :height '(lh 2) :flex-grow 1 :min-width '(ch 0)
               (box :height '(lh 1) :overflow 'hidden
                    :font-weight (if (eql (plist-get ch :index) active-idx) 'bold 'normal)
                    :color (etaf-video-player-color
                            (if (eql (plist-get ch :index) active-idx) :accent-text :ink))
                    :hover-style (unless (eql (plist-get ch :index) active-idx)
                                   (list :color (etaf-video-player-color :accent-text)))
                 (text (expr (plist-get ch :title))))
               (box :height '(lh 1) :overflow 'hidden
                    :color (etaf-video-player-color :dim)
                 (text (expr (format "%s – %s"
                                     (etaf-video-player--fmt-clock (plist-get ch :start))
                                     (etaf-video-player--fmt-clock (plist-get ch :end))))))))
           (flex :if (null chapters) :flex-direction 'column :padding '((lh 2) (ch 2))
                 :gap '((lh 1) (ch 0))
             (box :height '(lh 1) :color (etaf-video-player-color :muted)
               (text "当前视频无内嵌章节"))
             (box :height '(lh 1) :color (etaf-video-player-color :dim)
               (text "含章节的 MP4 / MKV 自动显示")))))
       (box :height '(lh 1) :flex-shrink 0 :padding '((lh 0) (ch 2)) :overflow 'hidden
            :border-top (etaf-video-player--border (etaf-video-player-color :line))
            :color (etaf-video-player-color :dim)
         (text (expr (if chapters
                         (format "共 %d 章 · M-p / M-n 切换" (length chapters))
                       "M-p / M-n 上下章"))))))))

(etaf-define-component etaf-video-player--view-bookmarks-tab
    (&key bookmarks-ref list-rows on-add on-seek on-remove)
  "Render SQLite timestamp bookmarks for the active video."
  :render
  (let ((items (etaf-video-player--view-value bookmarks-ref)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :flex-grow 1 :min-height '(lh 0)
       (flex :height '(lh 2) :flex-shrink 0 :align-items 'center
             :justify-content 'space-between :padding '((lh 0) (ch 2))
         (box :height '(lh 1) :color (etaf-video-player-color :muted)
           (text (expr (format "书签 %d 条" (length items)))))
         (etaf-video-player--pill :ref 'video-bookmark-add-drawer
                                  :label "+ 记此刻 m" :tone 'accent
                                  :help "在当前播放位置添加书签 (m)" :on-press on-add))
       (box :if (> list-rows 0) :ref 'video-bookmarks-scroll
            :width 'stretch :height (list 'lh list-rows) :overflow 'scroll
         (flex :flex-direction 'column :width 'stretch
           (flex :for (bm items) :key (plist-get bm :id)
                 :width 'stretch :height '(lh 2) :align-items 'center
                 :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
             (box :height '(lh 1) :flex-shrink 0 :padding '((lh 0) (ch 1))
                  :role 'button :tab-index 0 :pointer 'hand
                  :background-color (etaf-video-player-color :warn-bg)
                  :color (etaf-video-player-color :warn) :font-weight 'bold
                  :help-echo "跳转到此书签"
                  :on-press (lambda () (funcall on-seek (plist-get bm :position)))
               (text (expr (etaf-video-player--fmt-clock (plist-get bm :position)))))
             (box :height '(lh 1) :flex-grow 1 :min-width '(ch 0) :overflow 'hidden
                  :role 'button :tab-index 0 :pointer 'hand
                  :color (etaf-video-player-color :ink)
                  :hover-style (list :color (etaf-video-player-color :accent-text))
                  :help-echo "跳转到此书签"
                  :on-press (lambda () (funcall on-seek (plist-get bm :position)))
               (text (expr (let ((note (plist-get bm :note)))
                             (if (and (stringp note) (not (string-empty-p note)))
                                 note "时间书签")))))
             (etaf-video-player--pill :label "×" :tone 'ghost :help "删除书签"
                                      :on-press (lambda () (funcall on-remove (plist-get bm :id)))))
           (flex :if (null items) :flex-direction 'column :padding '((lh 2) (ch 2))
                 :gap '((lh 1) (ch 0))
             (box :height '(lh 1) :color (etaf-video-player-color :muted)
               (text "暂无书签"))
             (box :height '(lh 1) :color (etaf-video-player-color :dim)
               (text "按 m 标记当前画面位置")))))
       (box :height '(lh 1) :flex-shrink 0 :padding '((lh 0) (ch 2)) :overflow 'hidden
            :border-top (etaf-video-player--border (etaf-video-player-color :line))
            :color (etaf-video-player-color :dim)
         (text "m 添加书签 · 点击时间戳直达"))))))

(etaf-define-component etaf-video-player--view-history-tab
    (&key history-ref list-rows on-open on-delete on-clear)
  "Render recent playback history from SQLite with one-click resume."
  :render
  (let ((items (etaf-video-player--view-value history-ref)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :flex-grow 1 :min-height '(lh 0)
       (flex :height '(lh 2) :flex-shrink 0 :align-items 'center
             :justify-content 'space-between :padding '((lh 0) (ch 2))
         (box :height '(lh 1) :color (etaf-video-player-color :muted)
           (text (expr (format "最近观看 %d 条" (length items)))))
         (etaf-video-player--pill :if items :ref 'video-history-clear
                                  :label "清空" :tone 'ghost
                                  :help "清空全部观看历史" :on-press on-clear))
       (box :if (> list-rows 0) :ref 'video-history-scroll
            :width 'stretch :height (list 'lh list-rows) :overflow 'scroll
         (flex :flex-direction 'column :width 'stretch
           (flex :for (rec items) :key (plist-get rec :path)
                 :width 'stretch :height '(lh 2) :align-items 'center
                 :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
             (flex :flex-direction 'column :height '(lh 2) :flex-grow 1 :min-width '(ch 0)
                   :role 'button :tab-index 0 :pointer 'hand
                   :help-echo (format "打开并续播：%s" (plist-get rec :path))
                   :on-press (lambda () (funcall on-open (plist-get rec :path)))
               (box :height '(lh 1) :overflow 'hidden
                    :color (etaf-video-player-color :ink)
                    :hover-style (list :color (etaf-video-player-color :accent-text))
                 (text (expr (file-name-nondirectory (plist-get rec :path)))))
               (box :height '(lh 1) :overflow 'hidden
                    :color (etaf-video-player-color :dim)
                 (text (expr (let* ((pos (plist-get rec :position))
                                    (dur (plist-get rec :duration))
                                    (pct (when (and (numberp dur) (> dur 0))
                                           (min 100 (round (* 100.0 (/ (float pos) dur)))))))
                               (if pct
                                   (format "%s / %s · %d%%"
                                           (etaf-video-player--fmt-clock pos)
                                           (etaf-video-player--fmt-clock dur) pct)
                                 (format "已看 %s" (etaf-video-player--fmt-clock pos))))))))
             (etaf-video-player--pill :label "×" :tone 'ghost :help "删除该条历史"
                                      :on-press (lambda () (funcall on-delete (plist-get rec :path)))))
           (box :if (null items) :padding '((lh 2) (ch 2))
                :color (etaf-video-player-color :dim)
             (text "暂无本地视频观看记录"))))
       (box :height '(lh 1) :flex-shrink 0 :padding '((lh 0) (ch 2)) :overflow 'hidden
            :border-top (etaf-video-player--border (etaf-video-player-color :line))
            :color (etaf-video-player-color :dim)
         (text "点击记录直接打开并续播"))))))

(etaf-define-component etaf-video-player--view-left-drawer
    (&key left-tab-ref count entries active total-label filter-ref
          media-ref chapters-ref active-chapter-ref bookmarks-ref history-ref
          on-select-tab on-play on-enqueue on-remove on-move-up on-move-down
          on-enqueue-siblings on-sort-queue
          on-seek on-bookmark-add on-bookmark-remove
          on-history-open on-history-delete on-history-clear
          position left top width height)
  "Render the collapsible left Media Drawer with four leaf-scoped tabs."
  :render
  (let* ((tab (or (etaf-video-player--view-value left-tab-ref) 'queue))
         (total-rows (if (and (consp height) (eq (car height) 'lh)) (cadr height) 20))
         (list-rows-toolbar (max 0 (- total-rows 5)))
         (list-rows-plain (max 0 (- total-rows 3))))
    (etaf-view
     (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
           :width (or width (list 'ch etaf-video-player--sidebar-cols))
           :height (or height 'stretch)
           :flex-direction 'column :overflow 'hidden
           :region '(:id media :label "媒体栏" :key "m" :enter video-tab-queue)
           :background-color (etaf-video-player-color :surface)
           :border-right (etaf-video-player--border (etaf-video-player-color :line))
       (flex :height '(lh 2) :flex-shrink 0 :align-items 'center
             :border-bottom (etaf-video-player--border (etaf-video-player-color :line))
         (etaf-video-player--tab-item
          :ref 'video-tab-queue :label (format "队列 %d" count)
          :active (eq tab 'queue) :help "播放队列"
          :on-press (lambda () (funcall on-select-tab 'queue)))
         (etaf-video-player--tab-item
          :ref 'video-tab-chapters :label "章节"
          :active (eq tab 'chapters) :help "内嵌章节导航"
          :on-press (lambda () (funcall on-select-tab 'chapters)))
         (etaf-video-player--tab-item
          :ref 'video-tab-bookmarks :label "书签"
          :active (eq tab 'bookmarks) :help "时间戳书签"
          :on-press (lambda () (funcall on-select-tab 'bookmarks)))
         (etaf-video-player--tab-item
          :ref 'video-tab-history :label "历史"
          :active (eq tab 'history) :help "最近观看历史"
          :on-press (lambda () (funcall on-select-tab 'history))))
       (etaf-video-player--view-queue-tab
        :if (eq tab 'queue)
        :entries entries :active active :count count :filter-ref filter-ref
        :list-rows list-rows-toolbar :total-label total-label
        :on-play on-play :on-enqueue on-enqueue :on-remove on-remove
        :on-move-up on-move-up :on-move-down on-move-down
        :on-enqueue-siblings on-enqueue-siblings :on-sort-queue on-sort-queue)
       (etaf-video-player--view-chapters-tab
        :if (eq tab 'chapters)
        :media-ref media-ref :chapters-ref chapters-ref
        :active-chapter-ref active-chapter-ref
        :list-rows list-rows-plain :on-seek on-seek)
       (etaf-video-player--view-bookmarks-tab
        :if (eq tab 'bookmarks)
        :bookmarks-ref bookmarks-ref :list-rows list-rows-toolbar
        :on-add on-bookmark-add :on-seek on-seek :on-remove on-bookmark-remove)
       (etaf-video-player--view-history-tab
        :if (eq tab 'history)
        :history-ref history-ref :list-rows list-rows-toolbar
        :on-open on-history-open :on-delete on-history-delete :on-clear on-history-clear)))))

;;; ---------------------------------------------------------------------------
;;; Right Studio Drawer: Playback / Tracks / Video / Media Info
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-video-player--view-fact-rows
    (&key rows)
  "Render (LABEL . VALUE) rows with trailing-aligned values."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-shrink 0
    (flex :for (row rows) :key (car row) :height '(lh 1) :flex-shrink 0
          :align-items 'center :justify-content 'space-between
      (box :height '(lh 1) :flex-shrink 0
        (text :color (etaf-video-player-color :dim) (expr (car row))))
      (box :height '(lh 1) :text-align 'right :overflow 'hidden
        (text :color (etaf-video-player-color :ink) (expr (cdr row)))))))

(etaf-define-component etaf-video-player--view-section
    (&key icon title rows)
  "Render a titled group of fact rows."
  :view
  (flex :flex-direction 'column :width 'stretch :flex-shrink 0
    (flex :height '(lh 1) :flex-shrink 0 :align-items 'center :gap '((lh 0) (ch 1))
      (etaf-ui-icon :name icon :set 'svg :size 0.85 :min-width 2
                    :color (etaf-video-player-color :muted))
      (box :height '(lh 1) :font-weight 'bold
           :color (etaf-video-player-color :muted) (text (expr title))))
    (etaf-video-player--view-fact-rows :rows rows)))

(etaf-define-component etaf-video-player--view-speed-grid
    (&key speed-ref on-set-speed)
  "Render a two-row interactive playback speed grid in its own leaf scope."
  :render
  (let ((cur (etaf-video-player--view-value speed-ref)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :flex-shrink 0 :gap '((lh 0) (ch 0))
       (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between :align-items 'center
         (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
           (text "播放倍速"))
         (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :accent-text)
           (text (expr (format "%gx" cur)))))
       (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
         (etaf-video-player--pill
          :for (sp '(0.5 0.75 1 1.25)) :key (format "spd-%g" sp)
          :label (format "%gx" sp) :active (= cur sp)
          :tone (if (= cur sp) 'solid 'surface)
          :help (format "设为 %gx 倍速" sp)
          :on-press (lambda () (funcall on-set-speed sp))))
       (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
         (etaf-video-player--pill
          :for (sp '(1.5 2 3)) :key (format "spd-%g" sp)
          :label (format "%gx" sp) :active (= cur sp)
          :tone (if (= cur sp) 'solid 'surface)
          :help (format "设为 %gx 倍速" sp)
          :on-press (lambda () (funcall on-set-speed sp)))
         (etaf-video-player--pill
          :label "重置" :tone 'ghost :active (= cur 1)
          :help "恢复原速 1x (Backspace)" :on-press (lambda () (funcall on-set-speed 1))))))))

(etaf-define-component etaf-video-player--view-ab-panel
    (&key ab-ref on-set-a on-set-b on-clear)
  "Render interactive A-B loop controls in a leaf scope."
  :render
  (let* ((ab (etaf-video-player--view-value ab-ref))
         (a (car ab))
         (b (cdr ab))
         (active (and a b))
         (status (cond ((and a b) (format "%s–%s"
                                          (etaf-video-player--fmt-clock a)
                                          (etaf-video-player--fmt-clock b)))
                       (a (format "A %s…" (etaf-video-player--fmt-clock a)))
                       (t "未设置"))))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :flex-shrink 0
       (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between :align-items 'center
         (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
           (text "A-B 循环"))
         (box :height '(lh 1) :padding '((lh 0) (ch 1))
              :background-color (etaf-video-player-color (if (or a b) :warn-bg :panel3))
              :color (etaf-video-player-color (if (or a b) :warn :dim))
              :font-weight (if active 'bold 'normal)
           (text (expr status))))
       (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
         (etaf-video-player--pill
          :ref 'video-ab-a :label "设 A" :tone (if a 'warn 'surface)
          :help "将当前位置设为 A 点 (A)" :on-press on-set-a)
         (etaf-video-player--pill
          :ref 'video-ab-b :label "设 B" :tone (if b 'warn 'surface)
          :help "将当前位置设为 B 点并循环 (B)" :on-press on-set-b)
         (etaf-video-player--pill
          :ref 'video-ab-clear :label "清除" :tone 'ghost :active (not (or a b))
          :help "清除 A-B 循环" :on-press on-clear))))))

(etaf-define-component etaf-video-player--view-playback-tab
    (&key speed-ref ab-ref stop-after-ref media-ref engine-ref spec columns rows
          on-set-speed on-set-a on-set-b on-clear-ab
          on-toggle-stop-after on-step-back on-step-fwd on-screenshot on-copy-time)
  "Render the Playback Controls tab inside the right Studio drawer."
  :render
  (let* ((stop-after (etaf-video-player--view-value stop-after-ref))
         (engine (or (etaf-video-player--view-value engine-ref) 'ffmpeg))
         (info (etaf-video-player--view-value media-ref))
         (w (or (plist-get info :width) (plist-get spec :width)))
         (h (or (plist-get info :height) (plist-get spec :height)))
         (fps (or (plist-get info :fps) (plist-get spec :fps)))
         (vcodec (or (plist-get info :video-codec) "—"))
         (br (etaf-video-player-media-format-bitrate (plist-get info :bitrate)))
         (rows-list
          (list (cons "引擎" (if (eq engine 'mpv) "libmpv" "ffmpeg"))
                (cons "视频" (if (and w h)
                               (if (numberp fps)
                                   (format "%d×%d · %d fps" (round w) (round h) (round fps))
                                 (format "%d × %d" (round w) (round h)))
                             "未知"))
                (cons "编码" (if (equal br "—") vcodec (format "%s · %s" vcodec br)))
                (cons "画布" (format "%d × %d 格" columns rows)))))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :padding '((lh 1) (ch 1))
       (etaf-video-player--view-speed-grid
        :speed-ref speed-ref :on-set-speed on-set-speed)
       (etaf-divider)
       (etaf-video-player--view-ab-panel
        :ab-ref ab-ref :on-set-a on-set-a :on-set-b on-set-b :on-clear on-clear-ab)
       (etaf-divider)
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between :align-items 'center
           (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
             (text "精细步进与策略"))
           (etaf-video-player--pill
            :ref 'video-stop-after
            :label (if stop-after "播完暂停" "连续播")
            :selected stop-after :tone (if stop-after 'warn 'surface)
            :help "切换播完当前视频后自动暂停" :on-press on-toggle-stop-after))
         (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
           (etaf-video-player--pill :ref 'video-step-back :label "← 上一帧 ," :tone 'surface
                                    :help "暂停并单帧回退 (,)" :on-press on-step-back)
           (etaf-video-player--pill :ref 'video-step-fwd :label "下一帧 . →" :tone 'surface
                                    :help "暂停并单帧前进 (. / n)" :on-press on-step-fwd))
         (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
           (etaf-video-player--pill :label "保存截图 S" :tone 'surface
                                    :help "保存当前画面 PNG (S)" :on-press on-screenshot)
           (etaf-video-player--pill :label "复制时间 y" :tone 'surface
                                    :help "复制当前时间戳到剪贴板 (y)" :on-press on-copy-time)))
       (etaf-divider)
       (etaf-video-player--view-section :icon 'info :title "媒体速览" :rows rows-list)))))

(defun etaf-video-player--track-label (tr)
  "Format a concise display label for parsed audio/subtitle track plist TR."
  (let* ((id (plist-get tr :id))
         (lang (plist-get tr :lang))
         (title (plist-get tr :title))
         (codec (plist-get tr :codec))
         (ext (plist-get tr :external))
         (tag (cond (ext "外挂") (codec (upcase codec))))
         (parts (delq nil (list (and id (format "#%d" id))
                                (and lang (not (string-empty-p lang)) (upcase lang))
                                (and title (not (string-empty-p title)) title)
                                (and tag (not title) tag)))))
    (if parts (mapconcat #'identity parts " · ") "默认轨")))

(etaf-define-component etaf-video-player--view-tracks-tab
    (&key engine-ref tracks-ref audio-delay-ref
          subtitle-on-ref subtitle-file-ref subtitle-tracks-ref
          subtitle-offset-ref subtitle-scale-ref secondary-sid-ref
          on-select-audio on-shift-audio-delay on-reset-audio-delay
          on-toggle-sub on-select-sub on-select-secondary-sub
          on-load-sub on-shift-sub on-reset-sub on-scale-sub)
  "Render multi-audio, embedded/external subtitle and bilingual controls."
  :render
  (let* ((engine (or (etaf-video-player--view-value engine-ref) 'ffmpeg))
         (mpv-p (eq engine 'mpv))
         (tracks (etaf-video-player--view-value tracks-ref))
         (atracks (cl-remove-if-not (lambda (x) (eq (plist-get x :type) 'audio)) tracks))
         (stracks (cl-remove-if-not (lambda (x) (eq (plist-get x :type) 'sub)) tracks))
         (adelay (or (etaf-video-player--view-value audio-delay-ref) 0.0))
         (sub-on (etaf-video-player--view-value subtitle-on-ref))
         (sub-file (etaf-video-player--view-value subtitle-file-ref))
         (ext-subs (etaf-video-player--view-value subtitle-tracks-ref))
         (sub-off (or (etaf-video-player--view-value subtitle-offset-ref) 0.0))
         (sub-scale (or (etaf-video-player--view-value subtitle-scale-ref) 1.0))
         (sec-sid (etaf-video-player--view-value secondary-sid-ref)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :padding '((lh 1) (ch 1))
       ;; Audio tracks section
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between :align-items 'center
           (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
             (text "音频轨道 (v)"))
           (box :height '(lh 1) :color (etaf-video-player-color :dim)
             (text (expr (format "%d 轨" (length atracks))))))
         (flex :if (and mpv-p atracks) :flex-direction 'column :width 'stretch
           (flex :for (tr atracks) :key (format "aud-%S" (plist-get tr :id))
                 :width 'stretch :height '(lh 1) :align-items 'center
                 :justify-content 'space-between :padding '((lh 0) (ch 1))
                 :role 'button :tab-index 0
                 :aria-selected (and (plist-get tr :selected) t)
                 :pointer (unless (plist-get tr :selected) 'hand)
                 :background-color (etaf-video-player-color
                                    (if (plist-get tr :selected) :accent-soft :bg))
                 :color (etaf-video-player-color
                         (if (plist-get tr :selected) :accent-text :ink))
                 :font-weight (if (plist-get tr :selected) 'bold 'normal)
                 :hover-style (unless (plist-get tr :selected)
                                (list :color (etaf-video-player-color :accent-text)))
                 :help-echo "切换到此音轨"
                 :on-press (lambda () (funcall on-select-audio (plist-get tr :id)))
             (box :height '(lh 1) :flex-grow 1 :min-width '(ch 0) :overflow 'hidden
               (text (expr (etaf-video-player--track-label tr))))
             (box :if (plist-get tr :selected) :height '(lh 1) :flex-shrink 0
               (text "✓"))))
         (box :if (not (and mpv-p atracks)) :height '(lh 1) :color (etaf-video-player-color :dim)
           (text (expr (if mpv-p "无可选音轨" "多音轨需 libmpv 引擎"))))
         (flex :if mpv-p :height '(lh 1) :flex-shrink 0 :align-items 'center
               :justify-content 'space-between
           (box :height '(lh 1) :color (etaf-video-player-color :dim) (text "音画延迟"))
           (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
             (etaf-video-player--pill :label "-0.1" :tone 'surface
                                      :help "音频提前 100ms"
                                      :on-press (lambda () (funcall on-shift-audio-delay -0.1)))
             (box :height '(lh 1) :color (etaf-video-player-color :ink)
               (text (expr (format "%+.1fs" adelay))))
             (etaf-video-player--pill :label "+0.1" :tone 'surface
                                      :help "音频延迟 100ms"
                                      :on-press (lambda () (funcall on-shift-audio-delay 0.1)))
             (etaf-video-player--pill :label "0" :tone 'ghost :active (= adelay 0.0)
                                      :help "重置音频延迟" :on-press on-reset-audio-delay))))
       (etaf-divider)
       ;; Primary subtitle tracks (unified mpv embedded+external, or ffmpeg external)
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between :align-items 'center
           (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
             (text "主字幕轨 (V)"))
           (flex :height '(lh 1) :gap '((lh 0) (ch 1))
             (etaf-video-player--pill
              :ref 'video-sub-toggle :label (if sub-on "已开" "已关")
              :tone (if sub-on 'ok 'surface)
              :help "开关字幕 (c)" :on-press on-toggle-sub)
             (etaf-video-player--pill :ref 'video-sub-load :label "+加载" :tone 'surface
                                      :help "加载外部 .srt/.vtt/.ass 字幕" :on-press on-load-sub)))
         (flex :if (and mpv-p stracks) :flex-direction 'column :width 'stretch
           (flex :for (tr stracks) :key (format "sub-%S" (plist-get tr :id))
                 :width 'stretch :height '(lh 1) :align-items 'center
                 :justify-content 'space-between :padding '((lh 0) (ch 1))
                 :role 'button :tab-index 0
                 :aria-selected (and (plist-get tr :selected) t)
                 :pointer (unless (plist-get tr :selected) 'hand)
                 :background-color (etaf-video-player-color
                                    (if (plist-get tr :selected) :accent-soft :bg))
                 :color (etaf-video-player-color
                         (if (plist-get tr :selected) :accent-text :ink))
                 :font-weight (if (plist-get tr :selected) 'bold 'normal)
                 :hover-style (unless (plist-get tr :selected)
                                (list :color (etaf-video-player-color :accent-text)))
                 :help-echo "设为主字幕轨"
                 :on-press (lambda () (funcall on-select-sub (plist-get tr :id)))
             (box :height '(lh 1) :flex-grow 1 :min-width '(ch 0) :overflow 'hidden
               (text (expr (etaf-video-player--track-label tr))))
             (box :if (plist-get tr :selected) :height '(lh 1) :flex-shrink 0
               (text "✓"))))
         (flex :if (and (not mpv-p) (or sub-file ext-subs)) :flex-direction 'column :width 'stretch
           (box :height '(lh 1) :overflow 'hidden :padding '((lh 0) (ch 1))
                :background-color (etaf-video-player-color :bg)
                :color (etaf-video-player-color (if sub-file :ink :dim))
             (text (expr (if sub-file (file-name-nondirectory sub-file)
                           (format "%d 个外挂字幕" (length ext-subs)))))))
         (box :if (and (null stracks) (null sub-file) (null ext-subs))
              :height '(lh 1) :color (etaf-video-player-color :dim)
           (text "未检测到内嵌或外挂字幕")))
       ;; Secondary (bilingual) subtitle on libmpv
       (etaf-divider :if mpv-p)
       (flex :if mpv-p :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between :align-items 'center
           (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
             (text "次字幕（双语）"))
           (etaf-video-player--pill :label "关闭" :tone 'ghost :active (null sec-sid)
                                    :help "关闭双语次字幕"
                                    :on-press (lambda () (funcall on-select-secondary-sub nil))))
         (flex :if (>= (length stracks) 2) :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
           (etaf-video-player--pill
            :for (tr (seq-take stracks 4)) :key (format "sec-%S" (plist-get tr :id))
            :label (or (and (plist-get tr :lang) (upcase (plist-get tr :lang)))
                       (format "#%d" (plist-get tr :id)))
            :active (eql sec-sid (plist-get tr :id))
            :tone (if (eql sec-sid (plist-get tr :id)) 'accent 'surface)
            :help "设为双语次字幕轨"
            :on-press (lambda () (funcall on-select-secondary-sub (plist-get tr :id)))))
         (box :if (< (length stracks) 2) :height '(lh 1) :color (etaf-video-player-color :dim)
           (text "有 2 条以上字幕时可开启双语")))
       (etaf-divider)
       ;; Subtitle offset & scale
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :align-items 'center :justify-content 'space-between
           (box :height '(lh 1) :color (etaf-video-player-color :dim) (text "字幕偏移"))
           (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
             (etaf-video-player--pill :label "-0.5" :tone 'surface
                                      :help "字幕延迟 0.5 秒 (x)"
                                      :on-press (lambda () (funcall on-shift-sub -0.5)))
             (box :height '(lh 1) :color (etaf-video-player-color :ink)
               (text (expr (format "%+.1fs" sub-off))))
             (etaf-video-player--pill :label "+0.5" :tone 'surface
                                      :help "字幕提前 0.5 秒 (z)"
                                      :on-press (lambda () (funcall on-shift-sub 0.5)))
             (etaf-video-player--pill :label "0" :tone 'ghost :active (= sub-off 0.0)
                                      :help "重置字幕偏移" :on-press on-reset-sub)))
         (flex :if mpv-p :height '(lh 1) :flex-shrink 0 :align-items 'center
               :justify-content 'space-between
           (box :height '(lh 1) :color (etaf-video-player-color :dim) (text "字幕字号"))
           (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
             (etaf-video-player--pill :label "A-" :tone 'surface :help "缩小字幕"
                                      :on-press (lambda () (funcall on-scale-sub -0.1)))
             (box :height '(lh 1) :color (etaf-video-player-color :ink)
               (text (expr (format "%.1fx" sub-scale))))
             (etaf-video-player--pill :label "A+" :tone 'surface :help "放大字幕"
                                      :on-press (lambda () (funcall on-scale-sub 0.1))))))))))

(etaf-define-component etaf-video-player--view-video-tab
    (&key engine-ref mode columns rows
          aspect-ref rotate-ref mirror-ref deint-ref
          brightness-ref contrast-ref saturation-ref
          on-set-aspect on-set-rotate on-toggle-mirror on-toggle-deint
          on-adjust-eq on-reset-video on-set-mode on-fit)
  "Render IINA-grade video geometry, transform, color equalizer and canvas tab."
  :render
  (let* ((engine (or (etaf-video-player--view-value engine-ref) 'ffmpeg))
         (mpv-p (eq engine 'mpv))
         (aspect (or (etaf-video-player--view-value aspect-ref) 'auto))
         (rot (or (etaf-video-player--view-value rotate-ref) 0))
         (mirror (etaf-video-player--view-value mirror-ref))
         (deint (etaf-video-player--view-value deint-ref))
         (bright (or (etaf-video-player--view-value brightness-ref) 0))
         (cont (or (etaf-video-player--view-value contrast-ref) 0))
         (sat (or (etaf-video-player--view-value saturation-ref) 0)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :padding '((lh 1) (ch 1))
       ;; Aspect ratio override
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
           (text "画面比例"))
         (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
           (etaf-video-player--pill
            :for (opt '((auto . "自动") ("16:9" . "16:9") ("4:3" . "4:3") ("2.39:1" . "2.39")))
            :key (format "asp-%s" (car opt))
            :label (cdr opt) :active (equal aspect (car opt))
            :tone (if (equal aspect (car opt)) 'solid 'surface)
            :help (format "画面比例：%s" (cdr opt))
            :on-press (lambda () (funcall on-set-aspect (car opt))))))
       (etaf-divider)
       ;; Rotation & transform (libmpv)
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between
           (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
             (text "旋转与翻转 (r)"))
           (box :if (not mpv-p) :height '(lh 1) :color (etaf-video-player-color :dim)
             (text "需 libmpv")))
         (flex :if mpv-p :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
           (etaf-video-player--pill
            :for (deg '(0 90 180 270)) :key (format "rot-%d" deg)
            :label (format "%d°" deg) :active (= rot deg)
            :tone (if (= rot deg) 'solid 'surface)
            :help (format "旋转画面 %d°" deg)
            :on-press (lambda () (funcall on-set-rotate deg))))
         (flex :if mpv-p :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
           (etaf-video-player--pill :label "水平镜像" :selected mirror
                                    :tone (if mirror 'accent 'surface)
                                    :help "开关画面水平镜像" :on-press on-toggle-mirror)
           (etaf-video-player--pill :label "去隔行" :selected deint
                                    :tone (if deint 'accent 'surface)
                                    :help "开关反交错去隔行" :on-press on-toggle-deint)))
       (etaf-divider)
       ;; Color equalizer (libmpv)
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between :align-items 'center
           (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
             (text "色彩均衡"))
           (etaf-video-player--pill :if mpv-p :label "重置画面" :tone 'ghost
                                    :help "恢复默认比例、角度与色彩" :on-press on-reset-video))
         (flex :if mpv-p :flex-direction 'column :width 'stretch
           (flex :for (row (list (list 'brightness "亮度" bright)
                                 (list 'contrast "对比度" cont)
                                 (list 'saturation "饱和度" sat)))
                 :key (symbol-name (car row))
                 :height '(lh 1) :flex-shrink 0 :align-items 'center :justify-content 'space-between
             (box :height '(lh 1) :color (etaf-video-player-color :dim)
               (text (expr (nth 1 row))))
             (flex :height '(lh 1) :gap '((lh 0) (ch 1)) :align-items 'center
               (etaf-video-player--pill :label "−" :tone 'surface :help "降低 5"
                                        :on-press (lambda () (funcall on-adjust-eq (car row) -5)))
               (box :width '(ch 4) :height '(lh 1) :text-align 'center
                    :color (etaf-video-player-color :ink)
                 (text (expr (format "%+d" (nth 2 row)))))
               (etaf-video-player--pill :label "+" :tone 'surface :help "提高 5"
                                        :on-press (lambda () (funcall on-adjust-eq (car row) 5))))))
         (box :if (not mpv-p) :height '(lh 1) :color (etaf-video-player-color :dim)
           (text "亮度/对比度/饱和度需 libmpv")))
       (etaf-divider)
       ;; Render mode & canvas fit
       (flex :flex-direction 'column :width 'stretch :flex-shrink 0
         (flex :height '(lh 1) :flex-shrink 0 :justify-content 'space-between
           (box :height '(lh 1) :font-weight 'bold :color (etaf-video-player-color :muted)
             (text "渲染画布"))
           (box :height '(lh 1) :color (etaf-video-player-color :dim)
             (text (expr (format "%d × %d" columns rows)))))
         (flex :height '(lh 1) :flex-shrink 0 :gap '((lh 0) (ch 1))
           (etaf-video-player--pill :label "图像" :active (eq mode 'image)
                                    :tone (if (eq mode 'image) 'solid 'surface)
                                    :help "切换图像渲染"
                                    :on-press (lambda () (funcall on-set-mode 'image)))
           (etaf-video-player--pill :label "字符" :active (eq mode 'ascii)
                                    :tone (if (eq mode 'ascii) 'solid 'surface)
                                    :help "切换字符渲染"
                                    :on-press (lambda () (funcall on-set-mode 'ascii)))
           (etaf-video-player--pill :label "彩块" :active (eq mode 'color)
                                    :tone (if (eq mode 'color) 'solid 'surface)
                                    :help "切换彩色半块渲染"
                                    :on-press (lambda () (funcall on-set-mode 'color)))
           (etaf-video-player--pill :label "适配 F" :tone 'surface
                                    :help "画布自动适配窗口 (F)" :on-press on-fit)))))))

(etaf-define-component etaf-video-player--view-media-info-tab
    (&key title source spec index count media-ref engine-ref hwdec-ref canvas)
  "Render full video/audio stream, hardware decoder and canvas telemetry."
  :render
  (let* ((info (etaf-video-player--view-value media-ref))
         (engine (or (etaf-video-player--view-value engine-ref) 'ffmpeg))
         (hwdec (etaf-video-player--view-value hwdec-ref))
         (w (or (plist-get info :width) (plist-get spec :width)))
         (h (or (plist-get info :height) (plist-get spec :height)))
         (fps (or (plist-get info :fps) (plist-get spec :fps)))
         (vcodec (or (plist-get info :video-codec) "探测中…"))
         (vprof (plist-get info :video-profile))
         (pix (plist-get info :pix-fmt))
         (cspace (plist-get info :color-space))
         (video-rows
          (list (cons "编解码" (if vprof (format "%s (%s)" vcodec vprof) vcodec))
                (cons "硬解" (cond ((and (stringp hwdec) (not (string-empty-p hwdec))
                                         (not (equal hwdec "no")))
                                    hwdec)
                                   ((eq engine 'mpv) "软件解码")
                                   (t "ffmpeg 管线")))
                (cons "分辨率" (if (and w h) (format "%d × %d" (round w) (round h)) "未知"))
                (cons "宽高比" (or (plist-get info :aspect-label) "—"))
                (cons "源帧率" (if (numberp fps) (format "%.2f fps" fps) "—"))
                (cons "总码率" (etaf-video-player-media-format-bitrate (plist-get info :bitrate)))
                (cons "像素" (cond ((and pix cspace) (format "%s · %s" pix cspace))
                                 (pix pix)
                                 (t "—")))))
         (acodec (plist-get info :audio-codec))
         (arate (plist-get info :audio-sample-rate))
         (audio-rows
          (if acodec
              (list (cons "编解码" acodec)
                    (cons "声道" (or (plist-get info :audio-channel-layout)
                                   (and (plist-get info :audio-channels)
                                        (format "%d ch" (round (plist-get info :audio-channels))))
                                   "—"))
                    (cons "采样率" (if (numberp arate) (format "%.1f kHz" (/ (float arate) 1000.0)) "—"))
                    (cons "码率" (etaf-video-player-media-format-bitrate (plist-get info :audio-bitrate))))
            (list (cons "状态" (if (plist-get spec :audio) "有音轨" "无音轨")))))
         (fmt-name (plist-get info :format-name))
         (size-str (etaf-video-player-media-format-bytes (plist-get info :size)))
         (file-rows
          (append (list (cons "引擎" (if (eq engine 'mpv) "libmpv" "ffmpeg"))
                        (cons "时长" (etaf-video-player--fmt-clock (plist-get spec :duration)))
                        (cons "封装" (if fmt-name (format "%s · %s" fmt-name size-str) size-str))
                        (cons "播放位置" (format "%d / %d" (1+ index) count)))
                  canvas)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :padding '((lh 1) (ch 1))
       (box :height '(lh 1) :flex-shrink 0 :overflow 'hidden :font-weight 'bold
         (text (expr title)))
       (box :height '(lh 1) :flex-shrink 0 :overflow 'hidden
            :color (etaf-video-player-color :dim) (text (expr source)))
       (etaf-divider)
       (etaf-video-player--view-section :icon 'video :title "视频流" :rows video-rows)
       (etaf-divider)
       (etaf-video-player--view-section :icon 'music :title "音频流" :rows audio-rows)
       (etaf-divider)
       (etaf-video-player--view-section :icon 'image :title "文件与画布" :rows file-rows)))))

(etaf-define-component etaf-video-player--view-right-drawer
    (&key right-tab-ref title source spec index count media-ref engine-ref hwdec-ref canvas
          columns rows mode speed-ref ab-ref stop-after-ref
          tracks-ref audio-delay-ref
          subtitle-on-ref subtitle-file-ref subtitle-tracks-ref
          subtitle-offset-ref subtitle-scale-ref secondary-sid-ref
          aspect-ref rotate-ref mirror-ref deint-ref
          brightness-ref contrast-ref saturation-ref
          on-select-tab on-set-speed on-set-a on-set-b on-clear-ab
          on-toggle-stop-after on-step-back on-step-fwd on-screenshot on-copy-time
          on-select-audio on-shift-audio-delay on-reset-audio-delay
          on-toggle-sub on-select-sub on-select-secondary-sub
          on-load-sub on-shift-sub on-reset-sub on-scale-sub
          on-set-aspect on-set-rotate on-toggle-mirror on-toggle-deint
          on-adjust-eq on-reset-video on-set-mode on-fit
          position left top width height)
  "Render the collapsible right Studio Drawer (Playback / Tracks / Video / Info)."
  :render
  (let* ((tab (or (etaf-video-player--view-value right-tab-ref) 'controls))
         (total-rows (if (and (consp height) (eq (car height) 'lh)) (cadr height) 24))
         (body-rows (max 0 (- total-rows 2))))
    (etaf-view
     (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
           :width (or width (list 'ch etaf-video-player--aside-cols))
           :height (or height 'stretch)
           :flex-direction 'column :overflow 'hidden
           :region '(:id inspector :label "控制与信息" :key "r" :enter video-tab-controls)
           :background-color (etaf-video-player-color :surface)
           :border-left (etaf-video-player--border (etaf-video-player-color :line))
       (flex :height '(lh 2) :flex-shrink 0 :align-items 'center
             :border-bottom (etaf-video-player--border (etaf-video-player-color :line))
         (etaf-video-player--tab-item
          :ref 'video-tab-controls :label "播放"
          :active (eq tab 'controls) :help "倍速、A-B 循环与步进策略"
          :on-press (lambda () (funcall on-select-tab 'controls)))
         (etaf-video-player--tab-item
          :ref 'video-tab-tracks :label "轨道"
          :active (eq tab 'tracks) :help "多音轨、内嵌/外挂与双语字幕"
          :on-press (lambda () (funcall on-select-tab 'tracks)))
         (etaf-video-player--tab-item
          :ref 'video-tab-video :label "画面"
          :active (eq tab 'video) :help "比例、旋转、镜像、色彩均衡与渲染"
          :on-press (lambda () (funcall on-select-tab 'video)))
         (etaf-video-player--tab-item
          :ref 'video-tab-info :label "信息"
          :active (eq tab 'info) :help "编码、硬件解码与画布参数"
          :on-press (lambda () (funcall on-select-tab 'info))))
       (box :if (> body-rows 0) :ref 'video-right-scroll
            :width 'stretch :height (list 'lh body-rows) :overflow 'scroll
         (etaf-video-player--view-playback-tab
          :if (eq tab 'controls)
          :speed-ref speed-ref :ab-ref ab-ref :stop-after-ref stop-after-ref
          :media-ref media-ref :engine-ref engine-ref :spec spec
          :columns columns :rows rows
          :on-set-speed on-set-speed :on-set-a on-set-a :on-set-b on-set-b
          :on-clear-ab on-clear-ab :on-toggle-stop-after on-toggle-stop-after
          :on-step-back on-step-back :on-step-fwd on-step-fwd
          :on-screenshot on-screenshot :on-copy-time on-copy-time)
         (etaf-video-player--view-tracks-tab
          :if (eq tab 'tracks)
          :engine-ref engine-ref :tracks-ref tracks-ref
          :audio-delay-ref audio-delay-ref
          :subtitle-on-ref subtitle-on-ref :subtitle-file-ref subtitle-file-ref
          :subtitle-tracks-ref subtitle-tracks-ref
          :subtitle-offset-ref subtitle-offset-ref
          :subtitle-scale-ref subtitle-scale-ref
          :secondary-sid-ref secondary-sid-ref
          :on-select-audio on-select-audio
          :on-shift-audio-delay on-shift-audio-delay
          :on-reset-audio-delay on-reset-audio-delay
          :on-toggle-sub on-toggle-sub :on-select-sub on-select-sub
          :on-select-secondary-sub on-select-secondary-sub
          :on-load-sub on-load-sub :on-shift-sub on-shift-sub
          :on-reset-sub on-reset-sub :on-scale-sub on-scale-sub)
         (etaf-video-player--view-video-tab
          :if (eq tab 'video)
          :engine-ref engine-ref :mode mode :columns columns :rows rows
          :aspect-ref aspect-ref :rotate-ref rotate-ref
          :mirror-ref mirror-ref :deint-ref deint-ref
          :brightness-ref brightness-ref :contrast-ref contrast-ref
          :saturation-ref saturation-ref
          :on-set-aspect on-set-aspect :on-set-rotate on-set-rotate
          :on-toggle-mirror on-toggle-mirror :on-toggle-deint on-toggle-deint
          :on-adjust-eq on-adjust-eq :on-reset-video on-reset-video
          :on-set-mode on-set-mode :on-fit on-fit)
         (etaf-video-player--view-media-info-tab
          :if (eq tab 'info)
          :title title :source source :spec spec :index index :count count
          :media-ref media-ref :engine-ref engine-ref :hwdec-ref hwdec-ref
          :canvas canvas))))))

;;; ---------------------------------------------------------------------------
;;; Modern 3-Zone Transport Dock and Context Footer
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-video-player--view-control
    (&key icon help on-press value ref)
  "Render a shared SVG icon button at standard line height."
  :view
  (etaf-ui-toggle-icon :value (or value nil) :off icon :on icon :set 'svg :size 0.9
                       :min-width 3 :color (etaf-video-player-color :muted)
                       :on-color (etaf-video-player-color :accent)
                       :ref ref :help-echo help :on-press on-press))

(etaf-define-component etaf-video-player--view-speed-button
    (&key speed on-cycle-speed)
  "Render the speed pill in its own leaf scope."
  :render
  (let ((val (etaf-video-player--view-value speed)))
    (etaf-view
     (etaf-video-player--pill
      :ref 'video-speed :label (format "%gx" val)
      :tone (if (= val 1) 'surface 'accent)
      :help "播放速度 (+ / - / Backspace)" :on-press on-cycle-speed))))

(etaf-define-component etaf-video-player--view-loop-button
    (&key loop on-toggle-loop)
  "Render the loop toggle icon in its own leaf scope."
  :render
  (let ((mode (etaf-video-player--view-value loop)))
    (etaf-view
     (etaf-ui-toggle-icon :value (not (eq mode 'none))
                          :off 'repeat
                          :on (if (eq mode 'one) 'repeat-one 'repeat)
                          :set 'svg :size 0.9 :min-width 3 :ref 'video-loop
                          :color (etaf-video-player-color :dim)
                          :on-color (etaf-video-player-color :accent)
                          :help-echo "循环方式 (L)" :on-press on-toggle-loop))))

(etaf-define-component etaf-video-player--view-ab-pill
    (&key ab-ref on-press)
  "Render the transport A-B loop indicator pill in its own leaf scope."
  :render
  (let* ((ab (etaf-video-player--view-value ab-ref))
         (a (car ab))
         (b (cdr ab)))
    (etaf-view
     (etaf-video-player--pill
      :ref 'video-ab :label (cond ((and a b) "A-B") (a "A→") (t "A-B"))
      :tone (if (or a b) 'warn 'surface)
      :help "A-B 区间循环 (A 设起点 / B 设终点 / 再按清除)"
      :on-press on-press))))

(etaf-define-component etaf-video-player--view-cc-pill
    (&key subtitle-on-ref on-press)
  "Render the transport CC subtitle toggle pill in its own leaf scope."
  :render
  (let ((on (etaf-video-player--view-value subtitle-on-ref)))
    (etaf-view
     (etaf-video-player--pill
      :ref 'video-cc :label "CC"
      :tone (if on 'accent 'surface)
      :help "开关字幕 (c) · 切换字幕轨 (V)" :on-press on-press))))

(etaf-define-component etaf-video-player--view-progress
    (&key time-ref duration-ref time duration progress progress-fill-ref
          on-seek-preview on-seek on-toggle-remaining)
  "Render a tactile controlled timeline with clickable remaining-time clock."
  :view
  (flex :position 'relative :width 'stretch :height '(lh 1)
        :gap '((lh 0) (ch 2)) :align-items 'center
    (box :width '(ch 7) :height '(lh 1) :flex-shrink 0 :text-align 'right
         :color (etaf-video-player-color :ink)
      (text :ref time-ref :id (symbol-name time-ref)
        (expr (etaf-video-player--view-value time))))
    (flex :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
      (etaf-range :min 0 :max 100 :value progress :bar-height 24
                  :fill-ref progress-fill-ref :ref 'etaf-video-player-progress
                  :label "播放进度，点击或拖动跳转"
                  :color (etaf-video-player-color :accent)
                  :track-color (etaf-video-player-color :track)
                  :on-change on-seek-preview :on-commit on-seek))
    (box :width '(ch 8) :height '(lh 1) :flex-shrink 0 :text-align 'right
         :role 'button :tab-index 0 :pointer 'hand
         :color (etaf-video-player-color :muted)
         :hover-style (list :color (etaf-video-player-color :ink))
         :help-echo "点击切换总时长 / 剩余时长"
         :on-press on-toggle-remaining
      (text :ref duration-ref :id (symbol-name duration-ref)
        (expr (etaf-video-player--view-value duration))))))

(etaf-define-component etaf-video-player--view-transport-buttons
    (&key playing on-toggle on-previous on-next on-forward on-backward on-step tier)
  "Keep primary transport targets centered and crisp across viewport tiers."
  :render
  (let ((wide (eq tier 'wide)))
    (etaf-view
     (flex :height '(lh 1) :width 'max-content :flex-shrink 0 :align-items 'center
           :justify-content 'center :gap '((lh 0) (ch 1))
       (etaf-video-player--view-control :icon 'previous :ref 'video-previous
         :help "上一条 (<)" :on-press on-previous)
       (etaf-video-player--view-control :icon 'chevron-left :ref 'video-backward
         :help "后退 5 秒 (b)" :on-press on-backward)
       (flex :width '(ch 3) :height '(lh 1) :align-items 'center :justify-content 'center
             :background-color (etaf-video-player-color :accent)
         (etaf-ui-toggle-icon :value playing :off 'play :on 'pause :set 'svg :size 0.9
                              :min-width 3
                              :color (etaf-video-player-color :accent-fg)
                              :on-color (etaf-video-player-color :accent-fg)
                              :ref 'video-play
                              :help-echo "播放 / 暂停 (SPC)" :on-press on-toggle))
       (etaf-video-player--view-control :icon 'chevron-right :ref 'video-forward
         :help "前进 5 秒 (f)" :on-press on-forward)
       (etaf-video-player--view-control :icon 'next :ref 'video-next
         :help "下一条 (>)" :on-press on-next)
       (etaf-video-player--pill :if wide :ref 'video-step :label "逐帧" :tone 'surface
                                :help "逐帧前进 (n / .)" :on-press on-step)))))

(etaf-define-component etaf-video-player--view-volume
    (&key audio volume volume-text volume-ref on-toggle-audio
          on-volume-preview on-volume tier)
  "Compose mute, tactile volume slider and retained percentage."
  :render
  (let ((slider-w (pcase tier ('wide '(ch 10)) ('medium '(ch 9)) (_ '(ch 8)))))
    (etaf-view
     (flex :position 'relative :height '(lh 1) :flex-shrink 0 :align-items 'center
           :justify-content 'end :gap '((lh 0) (ch 1))
       (etaf-ui-toggle-icon :value audio :off 'volume-mute :on 'volume
                            :set 'svg :size 0.9 :min-width 3 :ref 'video-audio
                            :color (etaf-video-player-color :dim)
                            :on-color (etaf-video-player-color :muted)
                            :help-echo "声音开关 (a / M)" :on-press on-toggle-audio)
       (flex :width slider-w :height '(lh 1) :flex-shrink 0
         (etaf-range :min 0 :max 100 :value volume :step 1 :bar-height 22
                     :ref 'etaf-video-player-volume :fill-ref 'video-volume-fill
                     :label "音量，点击或拖动调节"
                     :color (etaf-video-player-color :accent)
                     :track-color (etaf-video-player-color :track)
                     :on-change on-volume-preview :on-commit on-volume))
       (box :width '(ch 4) :height '(lh 1) :flex-shrink 0 :text-align 'right
            :color (etaf-video-player-color :muted)
         (text :ref volume-ref :id (symbol-name volume-ref)
           (expr volume-text)))))))

(etaf-define-component etaf-video-player--view-transport
    (&key playing-ref time duration time-ref duration-ref volume-ref volume-text audio-ref
          progress progress-fill-ref speed loop shuffle volume ab-ref subtitle-on-ref
          on-toggle on-previous on-next on-forward on-backward on-step
          on-seek-preview on-seek on-toggle-remaining
          on-bookmark on-ab-cycle on-toggle-sub on-screenshot
          on-cycle-speed on-toggle-loop on-toggle-shuffle on-toggle-audio
          on-volume-preview on-volume tier
          position left top width height)
  "Render the 3-zone modern transport dock."
  :render
  (let ((compact (eq tier 'compact))
        (wide (eq tier 'wide)))
    (etaf-view
     (box :position (or position 'relative) :left (or left '(px 0)) :top (or top '(lh 0))
          :width (or width 'stretch) :height (or height (list 'lh etaf-video-player--bar-rows))
          :padding '((lh 1) (ch 2)) :background-color (etaf-video-player-color :panel2)
          :border-top (etaf-video-player--border (etaf-video-player-color :line))
          :region '(:id transport :label "播放控制" :key "c" :enter video-play)
       (flex :flex-direction 'column :height '(lh 3) :width 'stretch :gap '((lh 1) (ch 0))
         (etaf-video-player--view-progress :time time :time-ref time-ref
           :duration duration :duration-ref duration-ref
           :progress progress :progress-fill-ref progress-fill-ref
           :on-seek-preview on-seek-preview :on-seek on-seek
           :on-toggle-remaining on-toggle-remaining)
         (flex :height '(lh 1) :width 'stretch :align-items 'center
               :justify-content (if compact 'space-between 'start)
           (flex :if (not compact) :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                 :align-items 'center :gap '((lh 0) (ch 1))
             (etaf-video-player--pill :ref 'video-bookmark :label "书签" :tone 'surface
                                      :help "添加当前时间书签 (m)" :on-press on-bookmark)
             (etaf-video-player--view-ab-pill :ab-ref ab-ref :on-press on-ab-cycle)
             (etaf-video-player--view-cc-pill :subtitle-on-ref subtitle-on-ref
                                              :on-press on-toggle-sub)
             (etaf-video-player--pill :if wide :ref 'video-shot :label "截图" :tone 'surface
                                      :help "保存当前画面 PNG (S)" :on-press on-screenshot))
           (etaf-video-player--view-transport-buttons
            :playing playing-ref :tier tier
            :on-toggle on-toggle :on-previous on-previous :on-next on-next
            :on-forward on-forward :on-backward on-backward :on-step on-step)
           (flex :flex-grow (if compact 0 1) :flex-basis (if compact 'auto '(ch 0))
                 :min-width '(ch 0) :justify-content 'end :align-items 'center
                 :gap '((lh 0) (ch 1))
             (etaf-video-player--view-speed-button :speed speed
               :on-cycle-speed on-cycle-speed)
             (etaf-video-player--view-loop-button :if (not compact) :loop loop
               :on-toggle-loop on-toggle-loop)
             (etaf-video-player--view-control :if (not compact) :icon 'shuffle
               :value shuffle :ref 'video-shuffle
               :help "随机播放 (s)" :on-press on-toggle-shuffle)
             (etaf-video-player--view-volume :audio audio-ref :volume volume
               :volume-ref volume-ref :volume-text volume-text
               :on-toggle-audio on-toggle-audio
               :on-volume-preview on-volume-preview :on-volume on-volume
               :tier tier))))))))

(etaf-define-component etaf-video-player--view-footer
    (&key context-ref context hints position left top width height)
  "Render the low-noise bottom context and shortcut strip."
  :view
  (flex :position (or position 'static) :left (or left '(px 0)) :top (or top '(lh 0))
        :width (or width 'stretch) :height (or height '(lh 1))
        :align-items 'center :justify-content 'space-between
        :gap '((lh 0) (ch 2)) :padding '((lh 0) (ch 2))
        :background-color (etaf-video-player-color :bg)
        :border-top (etaf-video-player--border (etaf-video-player-color :line))
    (box :height '(lh 1) :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
         :overflow 'hidden :color (etaf-video-player-color :muted)
      (text :ref context-ref :id (symbol-name context-ref)
        (expr (etaf-video-player--view-value context))))
    (box :height '(lh 1) :flex-shrink 0 :overflow 'hidden
         :color (etaf-video-player-color :dim)
      (text (expr hints)))))

(provide 'etaf-video-player-views)
;;; etaf-video-player-views.el ends here
