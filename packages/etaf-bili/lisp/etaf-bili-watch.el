;;; etaf-bili-watch.el --- Dedicated Watch View and theater controls -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Implements the approved Watch View design:
;; - Wide viewport (>= 120 cols): Left 16:9 Theater + Right 38-col tabbed panel
;;   (Parts/Chapters, Searchable Subtitle Transcript, Live Danmaku, Comments
;;   with clickable MM:SS timestamps, Related videos).
;; - Narrow viewport (< 120 cols) or Theater mode (`w'): Video canvas takes
;;   maximum width; side panel opens on demand in a Drawer (`i`).
;; - Zero-reflow Retained Host leaf updates for clock, duration, progress bar,
;;   live subtitle strip and optional top danmaku lane.
;; - Quality/codec switcher dialog (`Q`), inline buffering & failover recovery,
;;   and audio-only background mode (`A`).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-bili-theme)
(require 'etaf-bili-views)
(require 'etaf-bili-model)

(defconst etaf-bili--watch-time-ref 'bili-watch-time)
(defconst etaf-bili--watch-duration-ref 'bili-watch-duration)
(defconst etaf-bili--watch-cinema-time-ref 'bili-watch-cinema-time)
(defconst etaf-bili--watch-progress-fill-ref 'bili-watch-progress-fill)
(defconst etaf-bili--watch-subtitle-ref 'bili-watch-subtitle)
(defconst etaf-bili--watch-status-ref 'bili-watch-status-line)

(defun etaf-bili--watch-canvas-fit (source stage-cols stage-rows cw lh)
  "Compute `(COLUMNS . ROWS)' fitting SOURCE's native aspect tightly in STAGE."
  (let* ((w (float (max 1 (or (plist-get source :width) 16))))
         (h (float (max 1 (or (plist-get source :height) 9))))
         (aspect (/ w h))
         (avail-px (float (max 1 (* stage-cols cw))))
         (avail-py (float (max 1 (* stage-rows lh))))
         (fit-py (min avail-py (/ avail-px aspect)))
         (rows (max 1 (min stage-rows (floor fit-py lh))))
         ;; Derive columns from snapped pixel height so the canvas box hugs the
         ;; rendered frame symmetrically inside centered flex stages.
         (fit-px (min avail-px (* rows lh aspect)))
         (cols (max 4 (min stage-cols (round (/ fit-px cw))))))
    (cons cols rows)))

(etaf-define-component etaf-bili--cinema-topbar
    (&key source cols fs-mode on-drawer on-toggle-frame on-toggle-pip on-exit)
  "Ultra-slim 1-row Pure Fullscreen top bar mirroring PiP's aligned chrome."
  :render
  (let* ((hpad-cols (if (< cols 52) 1 2))
         (title (or (plist-get source :title) "正在加载视频…"))
         (pages (plist-get source :pages))
         (part-idx (or (plist-get source :part-index) 1))
         (part-badge (when (and (> (length pages) 1) (>= cols 56))
                       (format "P%d / %d" part-idx (length pages))))
         (author (or (plist-get source :author) ""))
         (q-label (plist-get source :quality-label))
         (meta (when (and (>= cols 108)
                          (or (not (string-empty-p author)) q-label))
                 (string-join
                  (delq nil (list (unless (string-empty-p author)
                                    (format "UP %s" author))
                                  q-label))
                  " · ")))
         (frame-p (eq fs-mode 'frame)))
    (etaf-view
     (flex :ref 'bili-cinema-topbar :width 'stretch :height '(lh 1)
           :align-items 'center :gap '((lh 0) (ch 1))
           :padding (list '(lh 0) (list 'ch hpad-cols))
           :background-color (etaf-bili-color :panel2)
           :border-bottom (etaf-bili--border (etaf-bili-color :line))
       ;; Left cluster: Title + Part Badge + Quiet Meta (flush with Seek Bar left edge)
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
           (box :flex-shrink 1 :min-width '(ch 8) :height '(lh 1)
                :overflow 'hidden :wrap-mode 'none
             (text :color (etaf-bili-color :ink) :font-weight 'bold
               (expr title)))
           (box :if part-badge :flex-shrink 0 :height '(lh 1) :padding '((lh 0) (ch 1))
                :background-color (etaf-bili-color :accent-soft)
                :color (etaf-bili-color :accent)
             (text :font-weight 'bold (expr part-badge)))
           (box :if meta :flex-shrink 0 :height '(lh 1) :overflow 'hidden :wrap-mode 'none
                :color (etaf-bili-color :dim)
             (text (expr meta)))))
       ;; Right cluster: Mode Actions (rightmost pill flush with Seek Bar right edge)
       (etaf-bili--watch-chip :if (>= cols 68) :ref 'bili-cinema-drawer
                              :label "侧栏 i" :soft t
                              :accent-color (etaf-bili-color :ink)
                              :help "打开选集 / 字幕 / 评论抽屉 (i)"
                              :on-press on-drawer)
       (box :if (>= cols 80) :ref 'bili-cinema-frame-fs :id "bili-cinema-frame-fs"
            :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (etaf-bili-color (if frame-p :accent-soft :panel3))
            :color (etaf-bili-color (if frame-p :accent :ink))
            :font-weight (if frame-p 'bold 'normal)
            :hover-style (unless frame-p
                           (list :color (etaf-bili-color :ink)
                                 :background-color (etaf-bili-color :hover)))
            :help-echo "切换系统真全屏，退出自动还原分屏 (F)"
            :on-press on-toggle-frame
         (text "真全屏 F"))
       (etaf-bili--watch-chip :if (>= cols 54) :ref 'bili-cinema-pip
                              :label "PiP" :soft t
                              :accent-color (etaf-bili-color :ink)
                              :help "切换到悬浮画中画 (v)"
                              :on-press on-toggle-pip)
       (box :ref 'bili-cinema-exit :id "bili-cinema-exit"
            :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (etaf-bili-color :accent-soft)
            :color (etaf-bili-color :accent)
            :font-weight 'bold
            :hover-style (list :background-color (etaf-bili-color :accent)
                               :color "#FFFFFF")
            :help-echo "退出全屏返回观影页 (f / Esc)"
            :on-press on-exit
         (text (expr (if (< cols 48) "↩" "↩ 退出"))))))))

(etaf-define-component etaf-bili--cinema-deck
    (&key px-w cols rows cw gap-mid playing buffering audio-on vol spd cc-on dm-on
          quality-label progress-ref progress-fill-ref progress-id
          time-ref time-text on-seek on-toggle on-prev on-next
          on-toggle-audio on-vol-delta on-cycle-speed on-open-quality
          on-toggle-cc on-toggle-dm)
  "Shared 4-tier optically-aligned transport deck for both Fullscreen and PiP."
  :render
  (let* ((mini (< cols 44))
         (wide (>= cols 56))
         (cinema (>= cols 88))
         (hpad-cols (if (< cols 52) 1 2))
         (ctrl-pad-cols (max 0 (1- hpad-cols)))
         (right-pad-cols (if mini ctrl-pad-cols hpad-cols))
         (has-mid (and gap-mid (>= rows 14)))
         (has-bot (>= rows 8))
         (trans-rows (+ 2 (if has-mid 1 0) (if has-bot 1 0))))
    (etaf-view
     (column :ref 'bili-cinema-deck :width 'stretch :height (list 'lh trans-rows)
             :item-gap '(lh 0)
             :background-color (etaf-bili-color :panel2)
             :border-top (etaf-bili--border (etaf-bili-color :line))
       ;; Row 1: Full-width Interactive Hairline Seek Bar
       (box :width 'stretch :height '(lh 1)
            :padding (list '(lh 0) (list 'ch hpad-cols))
         (box :width (list 'px (max 60 (- px-w (* 2 hpad-cols cw)))) :height '(lh 1)
           (etaf-range :min 0 :max 100 :bar-height 22
                       :value progress-ref
                       :fill-ref progress-fill-ref
                       :ref (or progress-id 'bili-cinema-progress)
                       :color (etaf-bili-color :accent)
                       :track-color (etaf-bili-color :panel3)
                       :label "拖动或点击进度条跳转"
                       :on-commit on-seek)))
       ;; Optional middle breathing row in Fullscreen (matches normal Watch spacing)
       (box :if has-mid :width 'stretch :height '(lh 1))
       ;; Controls Row (left & right flush with Seek Bar)
       (flex :width 'stretch :height '(lh 1) :align-items 'center
             :padding-left (list 'ch ctrl-pad-cols)
             :padding-right (list 'ch right-pad-cols)
             :gap (if mini '((lh 0) (ch 0)) '((lh 0) (ch 1)))
         (flex :height '(lh 1) :align-items 'center :flex-shrink 0 :gap '((lh 0) (ch 0))
           (etaf-bili--watch-chip :ref 'bili-cinema-prev :id "bili-cinema-prev"
                                  :icon 'previous :help "上一集 / 上一视频 (P / <)"
                                  :on-press on-prev)
           (box :ref 'bili-cinema-play :id "bili-cinema-play"
                :width '(ch 3) :height '(lh 1)
                :flex-shrink 0 :role 'button :tab-index 0 :pointer 'hand
                :background-color (etaf-bili-color :accent) :color "#FFFFFF"
                :font-weight 'bold :help-echo "播放 / 暂停 (SPC)"
                :on-press on-toggle
             (etaf-ui-icon :name (if playing 'pause 'play) :set 'svg :size 0.85
                           :min-width 3 :color "#FFFFFF"))
           (etaf-bili--watch-chip :ref 'bili-cinema-next :id "bili-cinema-next"
                                  :icon 'next :help "下一集 / 下一视频 (N / >)"
                                  :on-press on-next))
         ;; Volume: stepper on Cinema (>= 88), compact label on Standard/Wide (44..87)
         (flex :if (and cinema on-vol-delta) :height '(lh 1) :align-items 'center
               :flex-shrink 0 :background-color (etaf-bili-color :panel3)
           (etaf-bili--watch-chip :label "−" :help "降低音量 ([ / ↓)"
                                  :on-press (lambda () (funcall on-vol-delta -10)))
           (etaf-bili--watch-chip :ref 'bili-cinema-mute :id "bili-cinema-mute"
                                  :label (if audio-on (format "♪ %3d%%" vol) "× 静音")
                                  :active (not audio-on)
                                  :accent-color (when audio-on (etaf-bili-color :ink))
                                  :help "静音 (m) · 音量 [ / ]"
                                  :on-press on-toggle-audio)
           (etaf-bili--watch-chip :label "+" :help "提高音量 (] / ↑)"
                                  :on-press (lambda () (funcall on-vol-delta 10))))
         (etaf-bili--watch-chip :if (and (not mini) (not (and cinema on-vol-delta)))
                                :ref 'bili-cinema-mute :id "bili-cinema-mute"
                                :label (if audio-on (format "♪ %d%%" vol) "× 静音")
                                :active (not audio-on)
                                :accent-color (when audio-on (etaf-bili-color :ink))
                                :help "静音 (m) · 音量 [ / ]"
                                :on-press on-toggle-audio)
         ;; Centered Retained Host Live Time Readout
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :height '(lh 1) :text-align 'center :overflow 'hidden :wrap-mode 'none
              :color (etaf-bili-color (if buffering :accent :muted))
           (text :ref time-ref :id (symbol-name time-ref)
             (expr time-text)))
         ;; Right Cluster
         (etaf-bili--watch-chip :if mini :ref 'bili-cinema-mute :id "bili-cinema-mute"
                                :label (if audio-on "♪" "×")
                                :active (not audio-on)
                                :accent-color (when audio-on (etaf-bili-color :ink))
                                :help "静音 (m) · 音量 [ / ]"
                                :on-press on-toggle-audio)
         (etaf-bili--watch-chip :if (and cinema quality-label on-open-quality)
                                :ref 'bili-cinema-quality :id "bili-cinema-quality"
                                :label quality-label
                                :accent-color (etaf-bili-color :accent)
                                :help "切换画质与线路 (Q)"
                                :on-press on-open-quality)
         (etaf-bili--watch-chip :if (not mini) :ref 'bili-cinema-speed :id "bili-cinema-speed"
                                :label (format "%gx" spd)
                                :active (/= spd 1)
                                :help "切换倍速 (+ / - / .)"
                                :on-press on-cycle-speed)
         (etaf-bili--watch-chip :if (not mini) :ref 'bili-cinema-cc :id "bili-cinema-cc"
                                :label "CC" :active cc-on
                                :help "开关字幕条 (c)"
                                :on-press on-toggle-cc)
         (etaf-bili--watch-chip :if wide :ref 'bili-cinema-dm :id "bili-cinema-dm"
                                :label "弹" :active dm-on
                                :help "开关原生画面弹幕 (d)"
                                :on-press on-toggle-dm))
       ;; Bottom Row: Exact 1-row bottom breathing cushion
       (box :if has-bot :width 'stretch :height '(lh 1))))))

(etaf-define-component etaf-bili--watch-chip
    (&key label icon active accent-color soft help on-press ref id)
  "Borderless modern transport/action control with quiet active/hover wash."
  :render
  (let ((fg (cond (active (etaf-bili-color :accent))
                  (accent-color accent-color)
                  (t (etaf-bili-color :muted))))
        (bg (cond (active (etaf-bili-color :accent-soft))
                  (soft (etaf-bili-color :panel3))
                  (t nil))))
    (etaf-view
     (box :ref ref :id id :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
          :role 'button :tab-index 0 :help-echo help
          :background-color bg :color fg
          :font-weight (if (or active accent-color) 'bold 'normal)
          :pointer (unless active 'hand)
          :hover-style (unless active
                         (list :color (etaf-bili-color :ink)
                               :background-color (etaf-bili-color :hover)))
          :on-press on-press
       (etaf-ui-icon :if icon :name icon :set 'svg :size 0.85 :min-width 2 :color fg)
       (text :if (not icon) (expr label))))))

(etaf-define-component etaf-bili--watch-header
    (&key source compact height on-back on-drawer on-theme)
  "Serene top Watch bar: Back, full-width title, part badge, drawer and theme."
  :render
  (let* ((title (or (plist-get source :title) "正在加载视频…"))
         (pages (plist-get source :pages))
         (part-idx (or (plist-get source :part-index) 1))
         (part-badge (when (> (length pages) 1)
                       (format "P%d / %d" part-idx (length pages)))))
    (etaf-view
     (flex :width 'stretch :height (list 'lh (or height 3)) :align-items 'center
           :gap '((lh 0) (ch 2)) :padding '((lh 0) (ch 2))
           :background-color (etaf-bili-color :panel2)
           :border-bottom (etaf-bili--border (etaf-bili-color :line))
       (etaf-bili--watch-chip :ref 'bili-watch-back :label "← 返回" :soft t
                              :accent-color (etaf-bili-color :ink)
                              :help "返回视频列表 (b / Esc)" :on-press on-back)
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (text :color (etaf-bili-color :ink) :font-weight 'bold
           (expr title)))
       (box :if part-badge :flex-shrink 0 :height '(lh 1) :padding '((lh 0) (ch 1))
            :background-color (etaf-bili-color :accent-soft)
            :color (etaf-bili-color :accent)
         (text :font-weight 'bold (expr part-badge)))
       (etaf-bili--watch-chip :if compact :ref 'bili-watch-drawer-btn
                              :label "侧栏 (i)" :soft t
                              :accent-color (etaf-bili-color :ink)
                              :help "打开选集 / 字幕 / 评论抽屉 (i)"
                              :on-press on-drawer)
       (etaf-bili--watch-chip :ref 'bili-theme :label "明暗"
                              :help "切换明暗主题 (T)" :on-press on-theme)
       (etaf-bili--watch-chip :label "?" :help "查看完整快捷键列表 (?)"
                              :on-press #'etaf-help)))))

(etaf-define-component etaf-bili--watch-side-content
    (&key session source tab-ref height width tab-height on-select-part on-seek
          on-select-sub on-sub-filter on-play-related on-toggle-auto-next
          on-toggle-danmaku on-dm-setting)
  "Editorial side panel for Parts, Subtitles, Danmaku, Comments and Related."
  :render
  (let* ((tab (etaf-value tab-ref))
         (th (or tab-height 3))
         (list-h (max 6 (- height th)))
         (pages (plist-get source :pages))
         (season (plist-get source :season))
         (cur-cid (plist-get source :cid))
         (cur-bvid (plist-get source :bvid))
         (q-label (or (plist-get source :quality-label) ""))
         (c-label (or (plist-get source :codec-label) ""))
         (chapters (etaf-value (etaf-bili--session-watch-chapters-ref session)))
         (auto-next (etaf-value (etaf-bili--session-watch-auto-next-ref session)))
         (sub-tracks (etaf-value (etaf-bili--session-watch-subtitles-list-ref session)))
         (sub-idx (etaf-value (etaf-bili--session-watch-subtitle-index-ref session)))
         (sub-cues (etaf-value (etaf-bili--session-watch-subtitle-cues-ref session)))
         (sub-filter (string-trim (or (etaf-value (etaf-bili--session-watch-subtitle-filter-ref session)) "")))
         (danmaku (etaf-value (etaf-bili--session-watch-danmaku-list-ref session)))
         (comments (etaf-value (etaf-bili--session-watch-comments-ref session)))
         (related (etaf-value (etaf-bili--session-watch-related-ref session)))
         (tabs (list (cons 'parts (if (> (length pages) 1)
                                      (format "选集 %d" (length pages))
                                    "选集"))
                     (cons 'subtitles "字幕")
                     (cons 'danmaku "弹幕")
                     (cons 'comments "评论")
                     (cons 'related "相关"))))
    (etaf-node
     'column
     (list :width (list 'ch width) :height (list 'lh height)
           :background-color (etaf-bili-color :surface) :overflow 'hidden)
     (list
      ;; Tab bar aligned flush with left Creator/Action strip
      (etaf-node
       'flex
       (list :width 'stretch :height (list 'lh th) :align-items 'center
             :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 2))
             :background-color (etaf-bili-color :surface)
             :border-bottom (etaf-bili--border (etaf-bili-color :line)))
       (mapcar
        (lambda (pair)
          (let ((key (car pair)) (lbl (cdr pair)) (active (eq (car pair) tab)))
            (etaf-node
             'box
             (list :ref (intern (format "bili-watch-tab-%s" key))
                   :id (format "bili-watch-tab-%s" key)
                   :height '(lh 1) :padding '((lh 0) (ch 1))
                   :role 'button :tab-index 0
                   :color (etaf-bili-color (if active :accent :muted))
                   :font-weight (if active 'bold 'normal)
                   :background-color (when active (etaf-bili-color :accent-soft))
                   :pointer (unless active 'hand)
                   :hover-style (unless active
                                  (list :color (etaf-bili-color :ink)
                                        :background-color (etaf-bili-color :hover)))
                   :on-press (lambda () (etaf-set-value tab-ref key)))
             (list (etaf-node 'text nil (list lbl))))))
        tabs))
      ;; Scrollable tab body with generous 2ch horizontal padding
      (etaf-node
       'box
       (list :ref 'bili-watch-side-scroll :width 'stretch :height (list 'lh list-h)
             :overflow 'scroll :padding '((lh 1) (ch 2)))
       (list
        (pcase tab
          ('parts
           (etaf-node
            'column (list :width 'stretch :item-gap '(lh 1))
            (append
             (list
              (etaf-view
               (flex :width 'stretch :height '(lh 1) :align-items 'center
                     :justify-content 'space-between
                 (box :role 'button :tab-index 0 :pointer 'hand
                      :color (etaf-bili-color (if auto-next :ok :muted))
                      :hover-style (list :color (etaf-bili-color :ink))
                      :on-press on-toggle-auto-next
                   (text :font-weight 'bold
                     (expr (if auto-next "● 连播开 (L)" "○ 连播关 (L)"))))
                 (text :color (etaf-bili-color :dim)
                   (expr (format "共 %d 集" (max 1 (length (or (and (> (length pages) 1) pages)
                                                               season pages)))))))))
             ;; Multi-part pages (borderless rows; soft highlight + left bar on active)
             (when (> (length pages) 1)
               (mapcar
                (lambda (p)
                  (let* ((cid (plist-get p :cid))
                         (active (equal cid cur-cid))
                         (pnum (plist-get p :page))
                         (ptitle (etaf-bili--truncate (plist-get p :part) (- width 16)))
                         (pdur (etaf-bili--clock (plist-get p :duration))))
                    (etaf-node
                     'flex
                     (list :width 'stretch :height '(lh 1) :align-items 'center
                           :justify-content 'space-between :padding '((lh 0) (ch 1))
                           :role 'button :tab-index 0
                           :background-color (when active (etaf-bili-color :accent-soft))
                           :pointer (unless active 'hand)
                           :on-press (lambda () (funcall on-select-part cur-bvid cid)))
                     (list
                      (etaf-node 'box
                                 (list :height '(lh 1)
                                       :color (etaf-bili-color (if active :accent :ink))
                                       :font-weight (if active 'bold 'normal)
                                       :hover-style (unless active
                                                      (list :color (etaf-bili-color :accent))))
                                 (list (etaf-node 'text nil
                                                  (list (format "P%d  %s" pnum ptitle)))))
                      (etaf-node 'text (list :color (etaf-bili-color (if active :accent :dim)))
                                 (list pdur))))))
                pages))
             ;; Collection (ugc_season) episodes (borderless, flush-aligned editorial list)
             (when (and (<= (length pages) 1) (> (length season) 1))
               (cons
                (etaf-node 'text (list :color (etaf-bili-color :dim) :font-weight 'bold)
                           (list "所属合集"))
                (mapcar
                 (lambda (ep)
                   (let* ((ebvid (plist-get ep :bvid))
                          (ecid (plist-get ep :cid))
                          (active (equal ebvid cur-bvid))
                          (etitle (etaf-bili--truncate (plist-get ep :title) (- width 12)))
                          (edur (etaf-bili--clock (plist-get ep :duration))))
                     (etaf-node
                      'flex
                      (list :width 'stretch :height '(lh 1) :align-items 'center
                            :justify-content 'space-between :padding '((lh 0) (ch 1))
                            :role 'button :tab-index 0
                            :background-color (when active (etaf-bili-color :accent-soft))
                            :pointer (unless active 'hand)
                            :on-press (lambda () (funcall on-select-part ebvid ecid)))
                      (list
                       (etaf-node 'box
                                  (list :height '(lh 1)
                                        :color (etaf-bili-color (if active :accent :ink))
                                        :font-weight (if active 'bold 'normal)
                                        :hover-style (unless active
                                                       (list :color (etaf-bili-color :accent))))
                                  (list (etaf-node 'text nil (list etitle))))
                       (etaf-node 'text (list :color (etaf-bili-color (if active :accent :dim)))
                                  (list edur))))))
                 (seq-take season 30))))
             ;; Description, stream tech metadata & clickable chapters
             (list
              (etaf-node 'etaf-divider nil nil)
              (etaf-node 'text (list :color (etaf-bili-color :ink) :font-weight 'bold)
                         (list "视频简介"))
              (etaf-node 'text (list :color (etaf-bili-color :dim))
                         (list (format "%s%s"
                                       (or cur-bvid "")
                                       (if (not (string-empty-p q-label))
                                           (format "  ·  %s %s" q-label c-label)
                                         ""))))
              (etaf-node 'box (list :width 'stretch :color (etaf-bili-color :muted))
                         (list (etaf-node 'text nil
                                          (list (let ((d (or (plist-get source :description) "")))
                                                  (if (string-empty-p d) "暂无简介" d)))))))
             (when chapters
               (cons
                (etaf-node 'text (list :color (etaf-bili-color :ink) :font-weight 'bold)
                           (list "看点章节（点击空降）"))
                (mapcar
                 (lambda (ch)
                   (let ((from (or (plist-get ch :from) 0))
                         (ctitle (or (plist-get ch :title) "")))
                     (etaf-node
                      'box
                      (list :width 'stretch :height '(lh 1) :role 'button :tab-index 0
                            :pointer 'hand
                            :hover-style (list :color (etaf-bili-color :accent))
                            :on-press (lambda () (funcall on-seek (float from))))
                      (list (etaf-node 'text (list :color (etaf-bili-color :info))
                                       (list (format "%s  %s"
                                                     (etaf-bili--clock from)
                                                     (etaf-bili--truncate ctitle (- width 12)))))))))
                 chapters))))))
          ('subtitles
           (let* ((filtered
                   (if (string-empty-p sub-filter)
                       sub-cues
                     (let ((needle (downcase sub-filter)))
                       (seq-filter (lambda (c)
                                     (string-match-p (regexp-quote needle)
                                                     (downcase (nth 2 c))))
                                   sub-cues)))))
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 1))
              (append
               (list
                (etaf-node
                 'flex (list :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1)))
                 (append
                  (list (etaf-node 'etaf-bili--watch-chip
                                   (list :label "关" :active (null sub-idx)
                                         :on-press (lambda () (funcall on-select-sub nil)))
                                   nil))
                  (cl-loop for tr in sub-tracks for idx from 0 collect
                           (let ((i idx))
                             (etaf-node 'etaf-bili--watch-chip
                                        (list :label (etaf-bili--truncate (plist-get tr :label) 8)
                                              :active (equal sub-idx i)
                                              :on-press (lambda () (funcall on-select-sub i)))
                                        nil)))))
                (etaf-node 'etaf-search-field
                           (list :ref 'bili-sub-search
                                 :bind (etaf-bili--session-watch-subtitle-filter-ref session)
                                 :placeholder "筛选字幕关键词（点击空降）"
                                 :on-submit on-sub-filter)
                           nil))
               (if filtered
                   (mapcar
                    (lambda (cue)
                      (let ((sec (nth 0 cue))
                            (txt (nth 2 cue)))
                        (etaf-node
                         'box
                         (list :width 'stretch :padding '((lh 0) (ch 1))
                               :role 'button :tab-index 0 :pointer 'hand
                               :hover-style (list :background-color (etaf-bili-color :hover))
                               :on-press (lambda () (funcall on-seek sec)))
                         (list (etaf-node 'text (list :color (etaf-bili-color :ink))
                                          (list (format "%s  %s"
                                                        (etaf-bili--clock sec)
                                                        (etaf-bili--truncate txt (- width 13)))))))))
                    (seq-take filtered 80))
                 (list (etaf-node 'text (list :color (etaf-bili-color :dim))
                                  (list (if sub-tracks
                                            "无匹配字幕条目"
                                          "当前视频暂无 CC / AI 字幕（登录账号可解锁更多 AI 字幕）")))))))))
          ('danmaku
           (let* ((pos (or (etaf-bili--session-watch-position session) 0.0))
                  (dm-on (etaf-value (etaf-bili--session-watch-danmaku-enabled-ref session)))
                  (dm-area (etaf-value (etaf-bili--session-watch-dm-area-ref session)))
                  (dm-op (etaf-value (etaf-bili--session-watch-dm-opacity-ref session)))
                  (dm-sz (etaf-value (etaf-bili--session-watch-dm-size-ref session)))
                  (dm-den (etaf-value (etaf-bili--session-watch-dm-density-ref session)))
                  (dm-scr (etaf-value (etaf-bili--session-watch-dm-scroll-ref session)))
                  (dm-top (etaf-value (etaf-bili--session-watch-dm-top-ref session)))
                  (dm-bot (etaf-value (etaf-bili--session-watch-dm-bottom-ref session)))
                  (dm-row
                   (lambda (label items)
                     (etaf-node
                      'flex (list :width 'stretch :height '(lh 1)
                                  :align-items 'center :gap '((lh 0) (ch 1)))
                      (cons
                       (etaf-node 'box (list :width '(ch 4) :flex-shrink 0
                                             :color (etaf-bili-color :muted))
                                  (list (etaf-node 'text nil (list label))))
                       items))))
                  (dm-pill
                   (lambda (lbl active key val)
                     (let ((tag (format "bili-dm-%s-%s" (substring (symbol-name key) 1) val)))
                       (etaf-node 'etaf-bili--watch-chip
                                  (list :ref (intern tag) :id tag :label lbl
                                        :active active :soft (not active)
                                        :on-press (lambda ()
                                                    (when on-dm-setting
                                                      (funcall on-dm-setting key val))))
                                  nil))))
                  (dm-toggle-pill
                   (lambda (lbl active key)
                     (etaf-node 'etaf-bili--watch-chip
                                (list :label (concat (if active "✓ " "× ") lbl)
                                      :active active :soft (not active)
                                      :on-press (lambda ()
                                                  (when on-dm-setting
                                                    (funcall on-dm-setting key (not active)))))
                                nil)))
                  (settings-card
                   (etaf-node
                    'column
                    (list :width 'stretch :padding '((lh 1) (ch 1)) :item-gap '(lh 1)
                          :background-color (etaf-bili-color :panel2)
                          :border (etaf-bili--border (etaf-bili-color :line)))
                    (list
                     (etaf-node
                      'flex (list :width 'stretch :height '(lh 1)
                                  :align-items 'center :justify-content 'space-between)
                      (list
                       (etaf-node 'text (list :color (etaf-bili-color :ink) :font-weight 'bold)
                                  (list "弹幕显示设置"))
                       (etaf-node 'etaf-bili--watch-chip
                                  (list :label (if dm-on "● 开启" "○ 关闭")
                                        :active dm-on :soft (not dm-on)
                                        :help "开关原生画面弹幕 (d)，画面零抖动"
                                        :on-press on-toggle-danmaku)
                                  nil)))
                     (funcall dm-row "区域"
                              (list (funcall dm-pill "1/4" (eq dm-area 'quarter) :area 'quarter)
                                    (funcall dm-pill "半屏" (eq dm-area 'half) :area 'half)
                                    (funcall dm-pill "全屏" (eq dm-area 'full) :area 'full)))
                     (funcall dm-row "透明"
                              (list (funcall dm-pill "100%" (eql dm-op 100) :opacity 100)
                                    (funcall dm-pill "80%" (eql dm-op 80) :opacity 80)
                                    (funcall dm-pill "60%" (eql dm-op 60) :opacity 60)
                                    (funcall dm-pill "40%" (eql dm-op 40) :opacity 40)))
                     (funcall dm-row "字号"
                              (list (funcall dm-pill "小" (eq dm-sz 'small) :font-size 'small)
                                    (funcall dm-pill "中" (eq dm-sz 'medium) :font-size 'medium)
                                    (funcall dm-pill "大" (eq dm-sz 'large) :font-size 'large)))
                     (funcall dm-row "密度"
                              (list (funcall dm-pill "精简" (eq dm-den 'low) :density 'low)
                                    (funcall dm-pill "适中" (eq dm-den 'medium) :density 'medium)
                                    (funcall dm-pill "海量" (eq dm-den 'high) :density 'high)))
                     (funcall dm-row "类型"
                              (list (funcall dm-toggle-pill "滚动" dm-scr :show-scroll)
                                    (funcall dm-toggle-pill "顶部" dm-top :show-top)
                                    (funcall dm-toggle-pill "底部" dm-bot :show-bottom)))))))
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 1))
              (cons
               settings-card
               (if danmaku
                   (let* ((nearby (or (seq-filter (lambda (d)
                                                    (>= (plist-get d :time) (max 0.0 (- pos 5.0))))
                                                  danmaku)
                                      danmaku)))
                     (list
                      (etaf-node
                       'column (list :width 'stretch :item-gap '(lh 0))
                       (cons
                        (etaf-node 'text (list :color (etaf-bili-color :dim))
                                   (list (format "共 %d 条弹幕（点击空降）" (length danmaku))))
                        (mapcar
                         (lambda (d)
                           (let* ((tm (plist-get d :time))
                                  (raw-col (plist-get d :color))
                                  (hex-col (cond
                                            ((and (stringp raw-col)
                                                  (string-prefix-p "#" raw-col))
                                             raw-col)
                                            ((integerp raw-col)
                                             (format "#%06X" (logand raw-col #xffffff)))
                                            (t nil)))
                                  (col (if (or (null hex-col)
                                               (string-equal-ignore-case hex-col "#FFFFFF"))
                                           (etaf-bili-color :dim)
                                         hex-col))
                                  (txt (plist-get d :text)))
                             (etaf-node
                              'flex
                              (list :width 'stretch :height '(lh 1) :align-items 'center
                                    :gap '((lh 0) (ch 1)) :role 'button :tab-index 0
                                    :pointer 'hand
                                    :on-press (lambda () (funcall on-seek tm)))
                              (list
                               (etaf-node 'text (list :color (etaf-bili-color :dim))
                                          (list (etaf-bili--clock tm)))
                               (etaf-node 'text (list :color col) (list "●"))
                               (etaf-node 'box
                                          (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                                                :height '(lh 1) :overflow 'hidden :wrap-mode 'none
                                                :color (etaf-bili-color :ink)
                                                :hover-style (list :color (etaf-bili-color :accent)))
                                          (list (etaf-node 'text nil
                                                           (list (etaf-bili--truncate txt (- width 14))))))))))
                         (seq-take nearby 60))))))
                 (list (etaf-node 'text (list :color (etaf-bili-color :dim))
                                  (list "暂无弹幕数据"))))))))
          ('comments
           (etaf-node
            'column (list :width 'stretch :item-gap '(lh 1))
            (if comments
                (mapcar
                 (lambda (c)
                   (let* ((author (plist-get c :author))
                          (likes (plist-get c :likes))
                          (msg (plist-get c :message))
                          (top (plist-get c :top))
                          (stamps (etaf-bili-extract-timestamps msg)))
                     (etaf-node
                      'column
                      (append
                       (list :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                             :background-color (etaf-bili-color :panel2))
                       (when top
                         (list :border-left (etaf-bili--border (etaf-bili-color :accent)))))
                      (append
                       (list
                        (etaf-node 'text
                                   (list :color (etaf-bili-color (if top :accent :muted))
                                         :font-weight 'bold)
                                   (list (format "%s%s  ·  ♥ %s"
                                                 (if top "[置顶] " "")
                                                 author
                                                 (etaf-bili--count likes))))
                        (etaf-node 'box (list :width 'stretch :color (etaf-bili-color :ink))
                                   (list (etaf-node 'text nil (list (etaf-bili--truncate msg 140))))))
                       (when stamps
                         (list
                          (etaf-node
                           'flex (list :width 'stretch :gap '((lh 0) (ch 1)))
                           (mapcar
                            (lambda (pair)
                              (let ((sec (car pair)) (tok (cdr pair)))
                                (etaf-node
                                 'box
                                 (list :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
                                       :color (etaf-bili-color :info)
                                       :hover-style (list :color (etaf-bili-color :accent))
                                       :on-press (lambda () (funcall on-seek (float sec))))
                                 (list (etaf-node 'text nil (list (format "↗ %s" tok)))))))
                            (seq-take stamps 4)))))))))
                 (seq-take comments 20))
              (list (etaf-node 'text (list :color (etaf-bili-color :dim))
                               (list "正在加载热评或暂无评论…"))))))
          ('related
           (etaf-node
            'column (list :width 'stretch :item-gap '(lh 1))
            (if related
                (mapcar
                 (lambda (row)
                   (let ((bvid (plist-get row :bvid))
                         (rtitle (etaf-bili--truncate (plist-get row :title) (- width 8)))
                         (rmeta (format "%s · %s 播放 · %s"
                                        (etaf-bili--truncate (plist-get row :author) 10)
                                        (etaf-bili--count (plist-get row :views))
                                        (etaf-bili--clock (plist-get row :duration)))))
                     (etaf-node
                      'column
                      (list :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
                            :role 'button :tab-index 0 :pointer 'hand
                            :background-color (etaf-bili-color :panel2)
                            :on-press (lambda () (funcall on-play-related bvid)))
                      (list
                       (etaf-node 'box
                                  (list :width 'stretch :color (etaf-bili-color :ink)
                                        :hover-style (list :color (etaf-bili-color :accent)))
                                  (list (etaf-node 'text nil (list rtitle))))
                       (etaf-node 'text (list :color (etaf-bili-color :dim)) (list rmeta))))))
                 (seq-take related 20))
              (list (etaf-node 'text (list :color (etaf-bili-color :dim))
                               (list "正在加载相关推荐…")))))))))))))

(etaf-define-component etaf-bili--quality-list
    (&key session source on-select-quality)
  "Column-aligned quality stream picker with automatic keyboard focus on mount."
  :setup
  (progn
    (etaf-on-mounted
     (lambda ()
       (let* ((rt (etaf-current-runtime))
              (streams (plist-get source :streams))
              (cur (or (etaf-value (etaf-bili--session-watch-quality-cursor-ref session)) 0)))
         (when (and rt streams (< cur (length streams)))
           (let* ((row-ref (intern (format "bili-quality-row-%d" cur)))
                  (apply-focus
                   (lambda (r ref check-cur)
                     (when (and r (etaf-runtime-mounted-p r)
                                (equal (etaf-value
                                        (etaf-bili--session-watch-quality-cursor-ref session))
                                       check-cur))
                       (ignore-errors (etaf-focus r ref))))))
             (ignore-errors (etaf-focus rt row-ref))
             ;; Re-assert focus after both next-tick and child-frame portal
             ;; modal reveal so initial focus lands on the active quality row.
             (run-at-time 0 nil apply-focus rt row-ref cur)
             (run-at-time 0.06 nil apply-focus rt row-ref cur))))))
    nil)
  :render
  (let* ((streams (plist-get source :streams))
         (cur-qid (plist-get source :quality-id))
         (albl (plist-get source :audio-label))
         (cursor-idx (or (etaf-value (etaf-bili--session-watch-quality-cursor-ref session)) 0)))
    (etaf-node
     'column (list :width 'stretch :item-gap '(lh 1))
     (append
      (list
       (etaf-node 'text (list :color (etaf-bili-color :dim))
                  (list (if albl
                            (format "音频轨道：%s（原声同源） · ↑↓ 选择 · RET 切换" albl)
                          "↑↓ 选择清晰度 · RET 确认切换 · 自动保持当前进度"))))
      (if streams
          (cl-loop
           for st in streams
           for idx from 0
           collect
           (let* ((stream st)
                  (row-idx idx)
                  (qid (plist-get st :id))
                  (active (equal qid cur-qid))
                  (focused (= idx cursor-idx))
                  (sw (plist-get st :width))
                  (sh (plist-get st :height))
                  (sfps (plist-get st :fps))
                  (spec (string-join
                         (delq nil
                               (list (when active "当前")
                                     (when (and (numberp sw) (numberp sh) (> sw 0))
                                       (format "%dx%d" sw sh))
                                     (when (and (numberp sfps) (>= sfps 45))
                                       (format "%dfps" (round sfps)))
                                     (plist-get st :codec-label)))
                         " · ")))
             (etaf-node
              'flex
              (list :ref (intern (format "bili-quality-row-%d" row-idx))
                    :id (format "bili-quality-row-%d" row-idx)
                    :width 'stretch :height '(lh 1) :align-items 'center
                    :justify-content 'space-between :padding '((lh 0) (ch 2))
                    :role 'button :tab-index 0
                    :background-color (cond (active (etaf-bili-color :accent-soft))
                                            (focused (etaf-bili-color :hover))
                                            (t nil))
                    :pointer (unless active 'hand)
                    :hover-style (unless (or active focused)
                                   (list :background-color (etaf-bili-color :hover)))
                    :on-press (lambda ()
                                (etaf-set-value
                                 (etaf-bili--session-watch-quality-cursor-ref session)
                                 row-idx)
                                (funcall on-select-quality stream)))
              (list
               (etaf-node 'text
                          (list :color (etaf-bili-color
                                        (cond (active :accent)
                                              (focused :ink)
                                              (t :ink)))
                                :font-weight (if (or active focused) 'bold 'normal))
                          (list (plist-get st :label)))
               (etaf-node 'text
                          (list :color (etaf-bili-color
                                        (cond (active :accent)
                                              (focused :muted)
                                              (t :dim))))
                          (list spec))))))
        (list (etaf-node 'text (list :color (etaf-bili-color :muted))
                         (list "当前视频无可选多画质轨道"))))))))

(etaf-define-component etaf-bili--watch-view
    (&key session layout on-back on-toggle on-seek on-seek-by on-prev on-next
          on-toggle-audio on-vol-delta on-cycle-speed on-open-quality
          on-select-quality on-failover-cdn on-retry-play
          on-toggle-sub on-select-sub on-sub-filter on-toggle-danmaku
          on-dm-setting on-toggle-audio-only on-toggle-theater
          on-toggle-fullscreen on-toggle-frame-fullscreen on-exit-fullscreen
          on-toggle-pip on-pip-return on-open-mpv on-open-browser
          on-toggle-auto-next on-select-part on-play-related on-author
          on-like on-coin on-fav on-toview on-theme)
  "Spacious, cinema-grade responsive Watch View with zero-restart Fullscreen."
  :render
  (let* ((source (etaf-value (etaf-bili--session-watch-source-ref session)))
         (width-px (plist-get layout :width))
         (fs-mode (etaf-value (etaf-bili--session-watch-fullscreen-ref session)))
         (fullscreen (and fs-mode t))
         (total-rows (max (if fullscreen 10 20)
                          (min (plist-get layout :rows)
                               (or (plist-get layout :raw-rows)
                                   (plist-get layout :rows)))))
         (cw (plist-get layout :cell-width))
         (lh (plist-get layout :cell-height))
         (total-cols (max (if fullscreen 24 64) (floor width-px cw)))
         (theater (etaf-value (etaf-bili--session-watch-theater-ref session)))
         (show-side (and (>= total-cols 120) (not theater) (not fullscreen)))
         (compact (< total-cols 96))
         (side-cols (cond ((not show-side) 0)
                          ((>= total-cols 136) 42)
                          (t 38)))
         (left-cols (- total-cols side-cols))
         (danmaku-on (etaf-value (etaf-bili--session-watch-danmaku-enabled-ref session)))
         (audio-only (etaf-value (etaf-bili--session-watch-audio-only-ref session)))
         (pip-active (etaf-value (etaf-bili--session-pip-active-ref session)))
         (playing (etaf-value (etaf-bili--session-watch-playing-ref session)))
         (buffering (etaf-value (etaf-bili--session-watch-buffering-ref session)))
         (play-err (etaf-value (etaf-bili--session-watch-play-error-ref session)))
         (audio-on (etaf-value (etaf-bili--session-watch-audio-ref session)))
         (vol (etaf-value (etaf-bili--session-watch-volume-ref session)))
         (spd (etaf-value (etaf-bili--session-watch-speed-ref session)))
         (sub-idx (etaf-value (etaf-bili--session-watch-subtitle-index-ref session)))
         (q-open (etaf-value (etaf-bili--session-watch-quality-menu-ref session)))
         (drawer-open (etaf-bili--session-watch-drawer-ref session))
         (is-liked (etaf-value (etaf-bili--session-watch-liked-ref session)))
         (is-coined (etaf-value (etaf-bili--session-watch-coined-ref session)))
         (is-faved (etaf-value (etaf-bili--session-watch-faved-ref session)))
         (is-toview (etaf-value (etaf-bili--session-watch-toviewed-ref session)))
         ;; Never use lh 2 (causes integer top-snap); use lh 3 when tall, lh 1 when short.
         (header-rows (cond (fullscreen 1)
                            ((>= total-rows 30) 3)
                            (t 1)))
         (top-strip-rows (cond (fullscreen 0)
                               ((>= total-rows 34) 3)
                               (t 1)))
         (body-rows (max 8 (- total-rows header-rows)))
         ;; Danmaku renders natively via libass inside the video frame, so stage
         ;; geometry stays 100% invariant when toggling danmaku on or off.
         (sub-rows (if fullscreen
                       (if (and (not (null sub-idx)) (>= total-rows 9)) 1 0)
                     1))
         ;; Transport deck:
         ;; - Fullscreen: exact 3-row shared cinema deck (seek + controls + 1 bottom row)
         ;; - Watch >= 36 rows: 5 rows (top pad + seek + gap + controls + bottom pad)
         ;; - Watch 30..35 rows: 4 rows (seek + gap + controls + bottom pad)
         ;; - Watch 24..29 rows: 3 rows (seek + gap + controls)
         ;; - Watch < 24 rows: 2 rows (seek + controls)
         (trans-pad-top (and (not fullscreen) (>= total-rows 36)))
         (trans-gap-mid (and (not fullscreen) (>= total-rows 24)))
         (trans-pad-bottom (and (not fullscreen) (>= total-rows 30)))
         (trans-rows (if fullscreen
                         (+ 2 (if (>= total-rows 14) 1 0)
                            (if (>= total-rows 8) 1 0))
                       (+ 2 (if trans-pad-top 1 0)
                          (if trans-gap-mid 1 0)
                          (if trans-pad-bottom 1 0))))
         (dur-sec (or (plist-get source :duration)
                      (etaf-bili--session-watch-duration session) 0))
         (clock-w (if (>= dur-sec 3600) 7 5))
         (range-w (max 8 (- left-cols (+ 8 (* 2 clock-w)))))
         (stage-rows (max 4 (- body-rows top-strip-rows sub-rows trans-rows)))
         (stage-cols (if fullscreen left-cols (max 20 (- left-cols 2))))
         (canvas-size (etaf-bili--watch-canvas-fit
                       source stage-cols stage-rows cw lh))
         (q-label (or (plist-get source :quality-label) "自动"))
         (audio-label (plist-get source :audio-label))
         (q-badge (if (and audio-label (not compact) (>= left-cols 102))
                      (format "%s · %s" q-label audio-label)
                    q-label))
         (author (or (plist-get source :author) ""))
         (mid (plist-get source :mid))
         (likes (plist-get source :likes))
         (date-str (or (plist-get source :date) ""))
         (short-date (if (>= (length date-str) 10) (substring date-str 5 10) date-str))
         (meta-rest (format "·  %s 播放  ·  %s 弹幕%s"
                            (etaf-bili--count (plist-get source :views))
                            (etaf-bili--count (plist-get source :danmaku))
                            (if (string-empty-p short-date) ""
                              (format "  ·  %s" short-date))))
         (show-engage (>= left-cols 88))
         (cinema-time-txt
          (cond
           (buffering (if (< total-cols 44) "···" "··· 缓冲中"))
           ((>= total-cols 52)
            (format "%s / %s"
                    (etaf-bili--session-watch-time-text session)
                    (etaf-bili--session-watch-duration-text session)))
           ((>= total-cols 30)
            (etaf-bili--session-watch-time-text session))
           (t ""))))
    (etaf-view
     (column :ref 'bili-watch-shell :position 'relative
             :width (list 'px width-px) :height (list 'lh total-rows)
             :item-gap '(lh 0) :overflow 'hidden
             :background-color (etaf-bili-color :panel2) :color (etaf-bili-color :ink)
       ;; 1. Watch Header (Standard/Theater) OR Ultra-slim 1-row Cinema Top Bar (Fullscreen)
       (etaf-bili--watch-header
        :if (not fullscreen)
        :source source :compact (not show-side) :height header-rows
        :on-back on-back
        :on-drawer (lambda () (etaf-set-value drawer-open t))
        :on-theme on-theme)
       (etaf-bili--cinema-topbar
        :if fullscreen
        :source source :cols total-cols :fs-mode fs-mode
        :on-drawer (lambda () (etaf-set-value drawer-open t))
        :on-toggle-frame on-toggle-frame-fullscreen
        :on-toggle-pip on-toggle-pip
        :on-exit (or on-exit-fullscreen on-toggle-fullscreen))
       ;; 2. Body Row: Left Theater (same stable mount path across all modes!) + Optional Right Side Panel
       (flex :width 'stretch :height (list 'lh body-rows) :align-items 'stretch
         ;; Left Theater Column (uses 'stretch when no side panel to avoid right-edge sliver)
         (column :width (if show-side (list 'ch left-cols) 'stretch)
                 :height (list 'lh body-rows)
                 :item-gap '(lh 0) :overflow 'hidden
           ;; Creator, concise stats & borderless engagement actions (hidden in Fullscreen)
           (flex :if (not fullscreen)
                 :width 'stretch :height (list 'lh (max 1 top-strip-rows)) :align-items 'center
                 :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 1))
                 :background-color (etaf-bili-color :surface)
                 :border-bottom (etaf-bili--border (etaf-bili-color :line))
             (box :flex-shrink 0 :height '(lh 1) :role 'button :tab-index 0
                  :color (etaf-bili-color :accent) :font-weight 'bold
                  :pointer (when (and mid (> mid 0)) 'hand)
                  :hover-style (when (and mid (> mid 0))
                                 (list :color (etaf-bili-color :ink)))
                  :help-echo "进入 UP 主投稿空间 (u)"
                  :on-press (lambda () (when (and mid (> mid 0))
                                         (funcall on-author mid author)))
               (text (expr (format "UP %s" author))))
             (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :height '(lh 1) :overflow 'hidden :wrap-mode 'none
                  :color (etaf-bili-color :dim)
               (text (expr meta-rest)))
             (box :flex-shrink 0 :height '(lh 1) :color (etaf-bili-color :accent)
               (text :ref etaf-bili--watch-status-ref
                     :id (symbol-name etaf-bili--watch-status-ref)
                 (expr (or (and buffering "··· 缓冲中")
                           (etaf-bili--session-watch-status-text session)
                           ""))))
             (etaf-bili--watch-chip :if show-engage
                                    :label (format "♥ %s" (etaf-bili--count likes))
                                    :active is-liked :help "点赞视频" :on-press on-like)
             (etaf-bili--watch-chip :if show-engage
                                    :label (if is-coined "◉ 已投币" "◉ 投币")
                                    :active is-coined
                                    :accent-color (when is-coined (etaf-bili-color :gold))
                                    :help "投币支持" :on-press on-coin)
             (etaf-bili--watch-chip :if show-engage
                                    :label (if is-faved "★ 已收藏" "☆ 收藏")
                                    :active is-faved :help "加入默认收藏夹" :on-press on-fav)
             (etaf-bili--watch-chip :if show-engage
                                    :label (if is-toview "✓ 稍后" "+ 稍后")
                                    :active is-toview :help "加入稍后再看" :on-press on-toview))
           ;; Video / PiP-Active / Audio-only / Error Stage (stays mounted across mode switches!)
           (flex :ref 'bili-watch-stage :width 'stretch :height (list 'lh stage-rows)
                 :align-items 'center :justify-content 'center
                 :background-color "#050607" :overflow 'hidden
                 :on-press (unless pip-active on-toggle)
             (column :if play-err :width (list 'ch (min 56 (max 16 (- left-cols 4))))
                     :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :background-color (etaf-bili-color :danger-bg)
                     :border (etaf-bili--border (etaf-bili-color :danger))
               (text :color (etaf-bili-color :danger) :font-weight 'bold
                 (expr (format "播放异常：%s" play-err)))
               (flex :gap '((lh 0) (ch 2))
                 (etaf-button :label "重试" :variant 'primary :on-press on-retry-play)
                 (etaf-button :label "切换备用线路" :variant 'secondary :on-press on-failover-cdn)
                 (etaf-button :label "用 mpv 打开" :variant 'ghost :on-press on-open-mpv)))
             (column :if (and (not play-err) audio-only)
                     :width (list 'ch (min 54 (max 16 (- left-cols 4))))
                     :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :cross-align 'center
                     :background-color (etaf-bili-color :panel2)
                     :border (etaf-bili--border (etaf-bili-color :accent))
               (text :color (etaf-bili-color :accent) :font-weight 'bold
                 "♫ 纯音频后台模式（零视频解码 CPU）")
               (text :color (etaf-bili-color :ink)
                 (expr (etaf-bili--truncate (or (plist-get source :title) "") 46)))
               (text :color (etaf-bili-color :muted)
                 "按 b 返回列表或切去其他 Buffer 写代码，声音将继续播放；按 A 恢复画面"))
             (column :if (and (not play-err) (not audio-only) pip-active)
                     :width (list 'ch (min 56 (max 16 (- left-cols 4))))
                     :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :cross-align 'center
                     :background-color (etaf-bili-color :surface)
                     :border (etaf-bili--border (etaf-bili-color :accent))
               (text :color (etaf-bili-color :accent) :font-weight 'bold
                 "▣ 画中画悬浮播放中")
               (text :color (etaf-bili-color :muted)
                 "可切去其他 Buffer 写代码 · 拖标题栏移动 · 点 ⊞ 换角")
               (flex :gap '((lh 0) (ch 2))
                 (etaf-button :label "↩ 收回主界面继续" :variant 'primary
                              :on-press (or on-pip-return on-toggle-pip))
                 (etaf-button :label "× 关闭画中画" :variant 'secondary
                              :on-press on-toggle-pip)))
             (etaf-video :if (and (not play-err) (not audio-only) (not pip-active)
                                  (plist-get source :url))
                         :src source
                         :columns (car canvas-size)
                         :rows (cdr canvas-size)
                         :handle (etaf-bili--session-watch-handle session)
                         :audio (etaf-bili--session-watch-audio-ref session)
                         :volume (etaf-bili--session-watch-volume-ref session)
                         :speed (etaf-bili--session-watch-speed-ref session)
                         :autoplay t))
           ;; Cinema-integrated Subtitle strip (hidden when CC off in Fullscreen to maximize video)
           (box :if (> sub-rows 0) :width 'stretch :height '(lh 1) :padding '((lh 0) (ch 2))
                :text-align 'center :overflow 'hidden :wrap-mode 'none
                :background-color "#080A0F" :color "#F4F6FA"
             (text :ref etaf-bili--watch-subtitle-ref
                   :id (symbol-name etaf-bili--watch-subtitle-ref)
               (expr (etaf-bili--session-watch-subtitle-text session))))
           ;; Pure Fullscreen Transport Deck (100% shared component with PiP!)
           (etaf-bili--cinema-deck
            :if fullscreen
            :px-w width-px :cols total-cols :rows total-rows :cw cw :gap-mid t
            :playing playing :buffering buffering
            :audio-on audio-on :vol vol :spd spd
            :cc-on (not (null sub-idx)) :dm-on danmaku-on
            :quality-label q-badge
            :progress-ref (etaf-bili--session-watch-progress-ref session)
            :progress-fill-ref etaf-bili--watch-progress-fill-ref
            :progress-id 'bili-watch-progress
            :time-ref etaf-bili--watch-cinema-time-ref
            :time-text cinema-time-txt
            :on-seek (lambda (pct)
                       (let ((dur (etaf-bili--session-watch-duration session)))
                         (when (> dur 0)
                           (funcall on-seek (* dur (/ pct 100.0))))))
            :on-toggle on-toggle
            :on-prev on-prev :on-next on-next
            :on-toggle-audio on-toggle-audio
            :on-vol-delta on-vol-delta
            :on-cycle-speed on-cycle-speed
            :on-open-quality on-open-quality
            :on-toggle-cc on-toggle-sub
            :on-toggle-dm on-toggle-danmaku)
           ;; Spacious, De-boxed Studio Transport Deck (Standard & Theater Watch)
           (column :if (not fullscreen)
                   :width 'stretch :height (list 'lh trans-rows) :item-gap '(lh 0)
                   :padding '((lh 0) (ch 2))
                   :background-color (etaf-bili-color :panel2)
                   :border-top (etaf-bili--border (etaf-bili-color :line))
             ;; Optional top cushion row on tall viewports
             (box :if trans-pad-top :width 'stretch :height '(lh 1))
             ;; Row 1: Elapsed | Hairline Seek Bar | Total
             (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 2))
               (box :width (list 'ch clock-w) :height '(lh 1) :flex-shrink 0 :color (etaf-bili-color :ink)
                 (text :ref etaf-bili--watch-time-ref
                       :id (symbol-name etaf-bili--watch-time-ref)
                       :font-weight 'bold
                   (expr (etaf-bili--session-watch-time-text session))))
               (box :width (list 'ch range-w) :height '(lh 1)
                 (etaf-range :min 0 :max 100 :bar-height 22
                             :value (etaf-bili--session-watch-progress-ref session)
                             :fill-ref etaf-bili--watch-progress-fill-ref
                             :ref 'bili-watch-progress
                             :color (etaf-bili-color :accent)
                             :track-color (etaf-bili-color :panel3)
                             :label "拖动或点击进度条跳转"
                             :on-commit (lambda (pct)
                                          (let ((dur (etaf-bili--session-watch-duration session)))
                                            (when (> dur 0)
                                              (funcall on-seek (* dur (/ pct 100.0))))))))
               (box :width (list 'ch clock-w) :height '(lh 1) :flex-shrink 0 :text-align 'right
                    :color (etaf-bili-color :dim)
                 (text :ref etaf-bili--watch-duration-ref
                       :id (symbol-name etaf-bili--watch-duration-ref)
                   (expr (etaf-bili--session-watch-duration-text session)))))
             ;; Clean 1-row breathing gap between seek bar and playback controls
             (box :if trans-gap-mid :width 'stretch :height '(lh 1))
             ;; Row 2: Calm, borderless grouped controls
             (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
               (box :ref 'bili-watch-play :width '(ch 3) :height '(lh 1)
                    :flex-shrink 0 :role 'button :tab-index 0 :pointer 'hand
                    :background-color (etaf-bili-color :accent) :color "#FFFFFF"
                    :font-weight 'bold :help-echo "播放 / 暂停 (SPC)"
                    :on-press on-toggle
                 (etaf-ui-icon :name (if playing 'pause 'play) :set 'svg :size 0.85
                               :min-width 3 :color "#FFFFFF"))
               (etaf-bili--watch-chip :icon 'previous :help "上一集 / 上一视频 (P)" :on-press on-prev)
               (etaf-bili--watch-chip :icon 'next :help "下一集 / 下一视频 (N)" :on-press on-next)
               (flex :height '(lh 1) :align-items 'center :flex-shrink 0
                     :background-color (etaf-bili-color :panel3)
                 (etaf-bili--watch-chip :if (not compact) :label "−"
                                        :help "降低音量 ([ / ↓)"
                                        :on-press (lambda () (funcall on-vol-delta -10)))
                 (etaf-bili--watch-chip :label (if audio-on (format "♪ %3d%%" vol) "× 静音")
                                        :active (not audio-on)
                                        :accent-color (when audio-on (etaf-bili-color :ink))
                                        :help "静音 (m) · 100% 即原声 0 dB 输出"
                                        :on-press on-toggle-audio)
                 (etaf-bili--watch-chip :if (not compact) :label "+"
                                        :help "提高音量 (] / ↑)"
                                        :on-press (lambda () (funcall on-vol-delta 10))))
               (box :flex-grow 1 :flex-basis '(ch 0))
               (etaf-bili--watch-chip :ref 'bili-watch-quality :label q-badge
                                      :accent-color (etaf-bili-color :accent)
                                      :help "切换画质与线路 (Q)" :on-press on-open-quality)
               (etaf-bili--watch-chip :label (format "%gx" spd)
                                      :active (/= spd 1)
                                      :help "切换倍速 (+ / - / .)" :on-press on-cycle-speed)
               (etaf-bili--watch-chip :label "CC" :active (not (null sub-idx))
                                      :help "开关 / 切换字幕 (c)" :on-press on-toggle-sub)
               (etaf-bili--watch-chip :if (not compact) :label "弹" :active danmaku-on
                                      :help "开关原生画面弹幕 (d)" :on-press on-toggle-danmaku)
               (box :if (not compact) :width '(ch 1) :height '(lh 1) :color (etaf-bili-color :line)
                 (text "│"))
               (etaf-bili--watch-chip :if (not compact) :label "听" :active audio-only
                                      :help "纯音频后台模式 (A)" :on-press on-toggle-audio-only)
               (etaf-bili--watch-chip :if (>= total-cols 120) :label (if theater "侧栏" "宽屏")
                                      :active theater :help "宽屏纯净剧场 (w)"
                                      :on-press on-toggle-theater)
               (etaf-bili--watch-chip :ref 'bili-watch-fullscreen :label "全屏"
                                      :help "纯净全屏 (f 网页全屏 / F 系统真全屏)"
                                      :on-press on-toggle-fullscreen)
               (etaf-bili--watch-chip :if (not compact) :label "PiP" :active pip-active
                                      :help "悬浮画中画 (v)" :on-press on-toggle-pip)
               (etaf-bili--watch-chip :label "mpv" :help "用外部 mpv 播放当前进度 (o)"
                                      :on-press on-open-mpv))
             ;; Clean empty bottom cushion above mode-line
             (box :if trans-pad-bottom :width 'stretch :height '(lh 1))))
         ;; Right Side Panel (wide mode only)
         (box :if show-side :width (list 'ch side-cols) :height (list 'lh body-rows)
              :border-left (etaf-bili--border (etaf-bili-color :line))
           (etaf-bili--watch-side-content
            :session session :source source
            :tab-ref (etaf-bili--session-watch-tab-ref session)
            :height body-rows :width (1- side-cols) :tab-height top-strip-rows
            :on-select-part on-select-part :on-seek on-seek
            :on-select-sub on-select-sub :on-sub-filter on-sub-filter
            :on-play-related on-play-related
            :on-toggle-auto-next on-toggle-auto-next
            :on-toggle-danmaku on-toggle-danmaku
            :on-dm-setting on-dm-setting)))
       ;; Narrow-screen / Theater Drawer holding the same Side Panel
       (etaf-drawer :open drawer-open :title "视频信息与互动" :width '(ch 44)
                    :on-close (lambda () (etaf-set-value drawer-open nil))
         (etaf-bili--watch-side-content
          :session session :source source
          :tab-ref (etaf-bili--session-watch-tab-ref session)
          :height (max 16 (- total-rows 6)) :width 40 :tab-height 1
          :on-select-part (lambda (bvid cid)
                            (etaf-set-value drawer-open nil)
                            (funcall on-select-part bvid cid))
          :on-seek on-seek
          :on-select-sub on-select-sub :on-sub-filter on-sub-filter
          :on-play-related (lambda (bvid)
                             (etaf-set-value drawer-open nil)
                             (funcall on-play-related bvid))
          :on-toggle-auto-next on-toggle-auto-next
          :on-toggle-danmaku on-toggle-danmaku
          :on-dm-setting on-dm-setting))
       ;; Quality & CDN Failover Picker Dialog (`Q') — column-aligned + full keyboard nav
       (etaf-dialog
        :open q-open :title "选择画质与线路" :width '(ch 50)
        :close-label nil
        :on-close (lambda ()
                    (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) nil))
        :on-direction
        (lambda (dir)
          (let* ((streams (plist-get source :streams))
                 (cnt (length streams))
                 (cref (etaf-bili--session-watch-quality-cursor-ref session))
                 (cur (or (etaf-value cref) 0)))
            (if (and (> cnt 0) (memq dir '(up down)))
                (let ((next (mod (+ cur (if (eq dir 'down) 1 -1)) cnt)))
                  (etaf-set-value cref next)
                  (ignore-errors
                    (etaf-focus (etaf-current-runtime)
                                (intern (format "bili-quality-row-%d" next))))
                  'handled)
              'release)))
        :keys
        (let* ((move
                (lambda (delta)
                  (let* ((streams (plist-get source :streams))
                         (cnt (length streams))
                         (cref (etaf-bili--session-watch-quality-cursor-ref session))
                         (cur (or (etaf-value cref) 0)))
                    (when (> cnt 0)
                      (let ((next (mod (+ cur delta) cnt)))
                        (etaf-set-value cref next)
                        (ignore-errors
                          (etaf-focus (etaf-current-runtime)
                                      (intern (format "bili-quality-row-%d" next)))))))))
               (confirm
                (lambda ()
                  (let* ((streams (plist-get source :streams))
                         (cur (or (etaf-value
                                   (etaf-bili--session-watch-quality-cursor-ref session))
                                  0))
                         (st (nth cur streams)))
                    (when st (funcall on-select-quality st))))))
          (list (list "j" (lambda () (funcall move 1)) "下一画质")
                (list "n" (lambda () (funcall move 1)) "下一画质")
                (list "k" (lambda () (funcall move -1)) "上一画质")
                (list "p" (lambda () (funcall move -1)) "上一画质")
                (list "SPC" confirm "确认切换选中画质")
                (list "f" on-failover-cdn "切换备用 CDN")
                (list "O" on-open-browser "在浏览器打开")))
        (etaf-bili--quality-list
         :session session :source source :on-select-quality on-select-quality)
        (slot :name 'footer
          (flex :width 'stretch :justify-content 'space-between :gap '((lh 0) (ch 1))
            (etaf-button :label "切换备用 CDN" :variant 'secondary :on-press on-failover-cdn)
            (etaf-button :label "浏览器 (O)" :variant 'ghost :on-press on-open-browser)
            (etaf-button :label "关闭" :variant 'ghost
                         :on-press (lambda ()
                                     (etaf-set-value
                                      (etaf-bili--session-watch-quality-menu-ref session) nil))))))))))

(provide 'etaf-bili-watch)
;;; etaf-bili-watch.el ends here
