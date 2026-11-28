;;; etaf-bili-app.el --- Application shell, Watch lifecycle and commands -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Connects `etaf-bili-model', `etaf-bili-views' and `etaf-bili-watch':
;; - Standalone entry via `etaf-app-open' with `:mode-line t' (preserving the
;;   user's original Emacs theme mode-line) and live buffer reuse
;; - Embeddable `etaf-bili-create' / `etaf-bili-view' honoring `(etaf-viewport)'
;; - Dedicated Watch View with Retained Host 250ms polling (zero per-second
;;   full rerenders), debounced resize, CDN failover, auto-next, local/cloud
;;   resume, background audio-only mode, Posframe PiP, external mpv and Org links
;; - Clean teardown releasing cover transfers (and temp files), timers & audio

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'browse-url)
(require 'etaf)
(require 'etaf-media)
(require 'etaf-ui)
(require 'etaf-bili-model)
(require 'etaf-bili-views)
(require 'etaf-bili-watch)
(require 'etaf-bili-account)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))

(defcustom etaf-bili-external-player "mpv"
  "External video player program launched by `etaf-bili-open-external'."
  :type 'string
  :group 'etaf-bili)

(defconst etaf-bili--buffer-name "*Bili*")
(defvar-local etaf-bili--session nil)

(defun etaf-bili--current ()
  "Return this buffer's live session."
  (or (etaf-bili--session)
      (user-error "当前缓冲区不是 B 站客户端")))

;;; Key declarations (single source of truth for bindings + `?` help)

(defun etaf-bili--gallery-keys ()
  "Return Gallery View shortcuts and help labels."
  (append
   (unless (eq etaf-direction-scheme 'vim)
     (list (list "j" #'etaf-bili-next "下一视频")
           (list "k" #'etaf-bili-previous "上一视频")))
   (list (list "n" #'etaf-bili-next "下一视频")
         (list "p" #'etaf-bili-previous "上一视频")
         (list "RET" #'etaf-bili--activate "播放／激活控件")
         (list "/" #'etaf-bili-search-prompt "搜索或粘贴 BV 号")
         (list "1" #'etaf-bili-popular "发现热门")
         (list "2" #'etaf-bili-ranking "全站排行")
         (list "3" #'etaf-bili-rcmd "个性推荐")
         (list "4" #'etaf-bili-dynamic "关注动态")
         (list "5" #'etaf-bili-toview "稍后再看")
         (list "6" #'etaf-bili-history "观看历史")
         (list "7" #'etaf-bili-favorites "我的收藏")
         (list "g" #'etaf-bili-refresh "刷新")
         (list "T" #'etaf-bili-toggle-theme "切换明暗主题")
         (list "i" #'etaf-bili-details "视频详情")
         (list "u" #'etaf-bili-open-author-space "查看 UP 主投稿")
         (list "w" #'etaf-bili-return-to-watch "回到观影页")
         (list "q" #'etaf-bili-close "关闭客户端"))))

(defun etaf-bili--watch-keys ()
  "Return Watch View shortcuts and help labels."
  (list (list "SPC" #'etaf-bili-watch-toggle "播放／暂停")
        (list "j" #'etaf-bili-watch-back-10 "后退 10 秒")
        (list "l" #'etaf-bili-watch-forward-10 "前进 10 秒")
        (list "," #'etaf-bili-watch-step "逐帧前进")
        (list "." #'etaf-bili-watch-cycle-speed "切换播放倍速")
        (list "+" #'etaf-bili-watch-speed-up "提高倍速")
        (list "-" #'etaf-bili-watch-speed-down "降低倍速")
        (list "[" #'etaf-bili-watch-volume-down "降低音量")
        (list "]" #'etaf-bili-watch-volume-up "提高音量")
        (list "m" #'etaf-bili-watch-toggle-audio "静音／开启声音")
        (list "Q" #'etaf-bili-watch-quality-menu "选择画质与线路")
        (list "c" #'etaf-bili-watch-cycle-subtitle "开关／切换字幕")
        (list "d" #'etaf-bili-watch-toggle-danmaku "开关弹幕")
        (list "w" #'etaf-bili-watch-toggle-theater "宽屏纯净剧场")
        (list "f" #'etaf-bili-watch-toggle-fullscreen "网页全屏（纯净影院）")
        (list "F" #'etaf-bili-watch-toggle-frame-fullscreen "系统真全屏（整屏独占）")
        (list "i" #'etaf-bili-watch-toggle-drawer "打开／收起侧栏")
        (list "A" #'etaf-bili-watch-toggle-audio-only "纯音频后台模式")
        (list "v" #'etaf-bili-watch-toggle-pip "悬浮画中画 (PiP)")
        (list "L" #'etaf-bili-watch-toggle-auto-next "切换自动连播")
        (list "N" #'etaf-bili-watch-next "下一集／下一视频")
        (list "P" #'etaf-bili-watch-previous "上一集／上一视频")
        (list "n" #'etaf-bili-watch-next "下一集／下一视频")
        (list "p" #'etaf-bili-watch-previous "上一集／上一视频")
        (list "o" #'etaf-bili-open-external "用外部 mpv 播放")
        (list "O" #'etaf-bili-open-in-browser "在浏览器打开")
        (list "y" #'etaf-bili-copy-org-link "复制 Org 时间戳链接")
        (list "u" #'etaf-bili-open-author-space "查看 UP 主投稿")
        (list "T" #'etaf-bili-toggle-theme "切换明暗主题")
        (list "0" #'etaf-bili-watch-jump-digit "跳转到 0%")
        (list "1" #'etaf-bili-watch-jump-digit "跳转到 10%")
        (list "2" #'etaf-bili-watch-jump-digit "跳转到 20%")
        (list "3" #'etaf-bili-watch-jump-digit "跳转到 30%")
        (list "4" #'etaf-bili-watch-jump-digit "跳转到 40%")
        (list "5" #'etaf-bili-watch-jump-digit "跳转到 50%")
        (list "6" #'etaf-bili-watch-jump-digit "跳转到 60%")
        (list "7" #'etaf-bili-watch-jump-digit "跳转到 70%")
        (list "8" #'etaf-bili-watch-jump-digit "跳转到 80%")
        (list "9" #'etaf-bili-watch-jump-digit "跳转到 90%")
        (list "b" #'etaf-bili-watch-back "返回视频列表")
        (list "q" #'etaf-bili-watch-back "返回视频列表")))

;;; Virtual scrolling & cover scheduling

(defun etaf-bili--visible-slice (first count layout)
  "Return the virtual row window for FIRST observed row, COUNT and LAYOUT."
  (let* ((across (plist-get layout :across))
         (pitch (1+ (plist-get layout :card-height)))
         (rows (ceiling (float count) across))
         (start-row (min (max 0 (1- rows)) (max 0 (1- first))))
         (visible-rows (min (- rows start-row)
                            (+ 3 (ceiling (float (plist-get layout :body)) pitch))))
         (total (max 0 (1- (* rows pitch))))
         (leading (* start-row pitch))
         (height (max 0 (1- (* visible-rows pitch)))))
    (list :start (* start-row across) :end (min count (* (+ start-row visible-rows) across))
          :leading leading :height height :trailing (max 0 (- total leading height))
          :total total :rows visible-rows :total-rows rows)))

(defun etaf-bili--has-filter-bar-p (session)
  "Return non-nil when SESSION's current gallery mode displays a filter strip."
  (memq (etaf-value (etaf-bili--session-mode-ref session))
        '(ranking search fav space)))

(etaf-define-component etaf-bili--gallery (&key session layout on-play on-select on-author)
  "Native scroll owner over a virtual card window with infinite scroll."
  :render
  (let* ((items (etaf-value (etaf-bili--session-items-ref session)))
         (first (etaf-value (etaf-bili--session-visible-row-ref session)))
         (loading (etaf-value (etaf-bili--session-loading-ref session)))
         (error (etaf-value (etaf-bili--session-error-ref session)))
         (slice (etaf-bili--visible-slice first (length items) layout))
         (start (plist-get slice :start))
         (visible (seq-subseq items start (plist-get slice :end)))
         (width (plist-get layout :grid-columns))
         (card-width (plist-get layout :card-width))
         (height (plist-get layout :card-height))
         (image-rows (plist-get layout :cover-rows))
         (columns (make-list (plist-get layout :across) (list 'ch card-width))))
    (cond
     (error (etaf-view
             (column :width (list 'ch width) :item-gap '(lh 1)
               (etaf-alert :variant 'danger :title "暂时无法加载" :message error)
               (etaf-button :label "重试" :ref 'bili-retry :on-press #'etaf-bili-refresh))))
     ((and (not loading) (null items))
      (etaf-view (etaf-empty :title "没有找到视频" :description "换个关键词或频道，再发现一点有趣的内容。"
                             :action-label "重新搜索" :on-action #'etaf-bili-search-prompt)))
     ((null items)
      (etaf-node 'grid (list :grid-template-columns columns :gap '((lh 1) (ch 3)))
                 (cl-loop repeat (plist-get layout :capacity) collect
                          (etaf-node 'etaf-bili--skeleton-card
                                     (list :columns card-width :image-rows image-rows :height height) nil))))
     (t
      (etaf-node
       'box
       (list :ref 'bili-gallery :width (list 'ch width)
             :height (list 'lh (plist-get layout :body)) :overflow 'scroll
             :background-color (etaf-bili-color :bg)
             :region (list :id 'gallery :label "视频" :key "v"
                           :enter (intern (format "bili-card-%d"
                                                  (min (1- (length items))
                                                       (* first (plist-get layout :across))))))
             :on-scroll (lambda (offset) (etaf-bili--observe-scroll session offset))
             :on-direction (lambda (direction) (etaf-bili--direction session layout direction)))
       (list
        (etaf-node
         'column (list :width 'stretch :item-gap '(lh 0))
         (list
          (etaf-node 'box (list :height (list 'lh (plist-get slice :leading)) :width 'stretch) nil)
          (etaf-node
           'grid
           (list :width 'stretch :height (list 'lh (plist-get slice :height))
                 :background-color (etaf-bili-color :bg)
                 :grid-template-columns columns
                 :grid-template-rows (make-list (plist-get slice :rows) (list 'lh height))
                 :gap '((lh 1) (ch 3)))
           (cl-loop for row in visible for index from start collect
                    (let* ((bvid (plist-get row :bvid))
                           (saved (or (plist-get row :progress)
                                      (car-safe (gethash (etaf-bili-store--progress-key bvid 0)
                                                         etaf-bili-store--mem-progress)))))
                      (etaf-node
                       'etaf-bili--video-card
                       (list :key bvid :row row :index index
                             :selection (etaf-bili--session-selected-ref session)
                             :cover (cdr (gethash (plist-get row :cover)
                                                  (etaf-bili--session-covers session)))
                             :resume-sec saved
                             :columns card-width :image-rows image-rows :height height
                             :cell-width (plist-get layout :cell-width)
                             :cell-height (plist-get layout :cell-height)
                             :on-play on-play :on-select on-select :on-author on-author)
                       nil))))
          (etaf-node 'box (list :height (list 'lh (plist-get slice :trailing)) :width 'stretch) nil)))))))))

(etaf-define-component etaf-bili--footer
    (&key session layout on-return-watch on-toggle-bg-audio on-stop-bg-audio)
  "Padded footer aligned flush with the card grid, plus audio-only mini-player."
  :render
  (let* ((count (length (etaf-value (etaf-bili--session-items-ref session))))
         (more (etaf-value (etaf-bili--session-loading-more-ref session)))
         (watch-src (etaf-value (etaf-bili--session-watch-source-ref session)))
         (audio-only (etaf-value (etaf-bili--session-watch-audio-only-ref session)))
         (playing (etaf-value (etaf-bili--session-watch-playing-ref session)))
         (bg-active (and watch-src audio-only))
         (footer-w (or (plist-get layout :grid-columns) (plist-get layout :columns))))
    (if bg-active
        (etaf-view
         (flex :height '(lh 3) :align-items 'center :gap '((lh 0) (ch 2))
               :width (list 'ch footer-w)
               :padding '((lh 0) (ch 2))
               :background-color (etaf-bili-color :panel2)
               :border-top (etaf-bili--border (etaf-bili-color :accent))
           (text :color (etaf-bili-color :accent) :font-weight 'bold "♫ 正在听")
           (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :overflow 'hidden :wrap-mode 'none
             (text :color (etaf-bili-color :ink)
               (expr (format "%s   %s / %s"
                             (or (plist-get watch-src :title) "")
                             (etaf-bili--clock (etaf-bili--session-watch-position session))
                             (etaf-bili--clock (etaf-bili--session-watch-duration session))))))
           (etaf-bili--watch-chip :icon (if playing 'pause 'play) :soft t
                                  :accent-color (etaf-bili-color :accent)
                                  :help (if playing "暂停音频" "继续播放")
                                  :on-press on-toggle-bg-audio)
           (etaf-bili--watch-chip :label "回剧场" :soft t
                                  :accent-color (etaf-bili-color :ink)
                                  :on-press on-return-watch)
           (etaf-bili--watch-chip :label "停止" :on-press on-stop-bg-audio)
           (etaf-button :ref 'bili-details :label "详情" :variant 'ghost
                        :disabled (= count 0) :on-press #'etaf-bili-details)
           (etaf-button :label "?" :variant 'ghost :on-press #'etaf-help)))
      (etaf-view
       (flex :height '(lh 3) :align-items 'center :gap '((lh 0) (ch 2))
             :width (list 'ch footer-w)
         (etaf-label :text (cond
                            (more (format "%d 个视频 · 正在加载下一页…" count))
                            ((> count 0) (format "%d 个视频 · 向下滚动浏览" count))
                            (t "等待新的发现"))
                     :variant 'muted)
         (box :flex-grow 1 :flex-basis '(ch 0))
         (etaf-button :if watch-src :label "回到观影页 (w)" :variant 'ghost
                      :on-press on-return-watch)
         (etaf-button :ref 'bili-details :label "详情" :variant 'ghost
                      :disabled (= count 0) :on-press #'etaf-bili-details)
         (etaf-button :label "?" :variant 'ghost :on-press #'etaf-help))))))

;;; Top-level Application Shell (Gallery View <-> Watch View)

(etaf-define-component etaf-bili--shell (&key session)
  "Compose Gallery View and Watch View over one reactive session."
  :bindings
  ((theme (etaf-bili--session-theme-ref session))
   (details (etaf-bili--session-details-ref session))
   (account-menu (etaf-bili--session-account-menu-ref session))
   (on-select (lambda (index) (etaf-bili--select session index)))
   (on-play (lambda (index)
              (etaf-bili--select session index)
              (etaf-bili--play-selected-into-watch session)))
   (on-author (lambda (mid name) (etaf-bili-load-space session mid name)))
   (submit (lambda (query) (etaf-bili--handle-search-submit session query)))
   (mode-change (lambda (mode) (etaf-bili--switch-channel session mode)))
   (on-account (lambda ()
                 (if (etaf-value (etaf-bili--session-account-ref session))
                     (etaf-update-value account-menu #'not)
                   (etaf-bili-login session))))
   (close-sign-in (lambda () (etaf-bili--login-cancel session))))
  :setup
  (progn
    (unless (eq (etaf-value etaf-bili--theme-mode-ref) etaf-bili-theme-mode)
      (etaf-set-value etaf-bili--theme-mode-ref etaf-bili-theme-mode))
    (etaf-theme-provide theme)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme theme
                            :mode etaf-bili--theme-mode-ref
                            :modes etaf-bili--theme-modes))
    (etaf-watch etaf-bili--theme-mode-ref
                (lambda (mode _old)
                  (setq etaf-bili-theme-mode mode)
                  (etaf-set-value (etaf-bili--session-theme-ref session)
                                  (etaf-bili-theme-defaults mode))
                  (etaf-bili--pip-apply-theme session))
                :name 'etaf-bili-theme)
    (etaf-watch #'etaf-viewport
                (lambda (vp _old)
                  (etaf-bili--sync-viewport session vp)
                  nil)
                :immediate t)
    (etaf-watch (etaf-bili--session-mode-ref session)
                (lambda (_new _old)
                  (etaf-bili--sync-viewport session)
                  nil))
    (etaf-on-mounted (lambda () (etaf-bili--mounted session)))
    (etaf-on-unmounted (lambda () (etaf-bili--unmounted session))))
  :render
  (let* ((_theme (etaf-value theme))
         (view-mode (etaf-value (etaf-bili--session-view-mode-ref session)))
         (has-filter (etaf-bili--has-filter-bar-p session))
         (layout (or (etaf-value (etaf-bili--session-layout-ref session))
                     (etaf-bili--layout nil has-filter)))
         (row (etaf-value details))
         (account (etaf-value (etaf-bili--session-account-ref session)))
         (login (etaf-value (etaf-bili--session-login-ref session)))
         (width (or (plist-get layout :grid-columns) (plist-get layout :columns)))
         (height (plist-get layout :rows)))
    (if (eq view-mode 'watch)
        (let* ((fullscreen (and (etaf-value (etaf-bili--session-watch-fullscreen-ref session)) t))
               (watch-h (max (if fullscreen 10 20)
                             (min height (or (plist-get layout :raw-rows) height))))
               (cw (max 1 (or (plist-get layout :cell-width) 7)))
               (total-cols (max (if fullscreen 24 64) (floor (plist-get layout :width) cw)))
               (theater (etaf-value (etaf-bili--session-watch-theater-ref session)))
               (show-side (and (>= total-cols 120) (not theater) (not fullscreen)))
               (side-cols (cond ((not show-side) 0)
                                ((>= total-cols 136) 42)
                                (t 38)))
               (left-cols (- total-cols side-cols)))
          (etaf-view
           (column :ref 'bili-shell :position 'relative
                   :width (list 'px (plist-get layout :width)) :height (list 'lh watch-h)
                   :item-gap '(lh 0) :overflow 'hidden
                   :background-color (etaf-bili-color :panel2) :color (etaf-bili-color :ink)
                   :keys (etaf-bili--watch-keys)
                   :on-dismiss (lambda () (etaf-bili-watch-escape))
                   :on-direction (lambda (dir) (etaf-bili--watch-direction session dir))
             (etaf-bili--watch-view
              :session session :layout layout
              :on-back (lambda () (etaf-bili--watch-leave session))
              :on-toggle (lambda () (etaf-bili--watch-toggle session))
              :on-seek (lambda (sec) (etaf-bili--watch-seek session sec))
              :on-seek-by (lambda (delta) (etaf-bili--watch-seek-by session delta))
              :on-prev (lambda () (etaf-bili--watch-step-episode session -1))
              :on-next (lambda () (etaf-bili--watch-step-episode session 1))
              :on-toggle-audio (lambda () (etaf-bili--watch-toggle-audio session))
              :on-vol-delta (lambda (d) (etaf-bili--watch-volume-delta session d))
              :on-cycle-speed (lambda () (etaf-bili--watch-cycle-speed session))
              :on-open-quality (lambda () (etaf-bili--watch-toggle-quality-menu session))
              :on-select-quality (lambda (st) (etaf-bili--watch-switch-quality session st))
              :on-failover-cdn (lambda () (etaf-bili--watch-failover-cdn session))
              :on-retry-play (lambda () (etaf-bili--watch-retry session))
              :on-toggle-sub (lambda () (etaf-bili--watch-cycle-subtitle session))
              :on-select-sub (lambda (idx) (etaf-bili--watch-select-subtitle session idx))
              :on-sub-filter (lambda (q) (etaf-set-value (etaf-bili--session-watch-subtitle-filter-ref session) q))
              :on-toggle-danmaku (lambda () (etaf-bili--watch-toggle-danmaku session))
              :on-dm-setting (lambda (k v) (etaf-bili--watch-set-dm-setting session k v))
              :on-toggle-audio-only (lambda () (etaf-bili--watch-toggle-audio-only session))
              :on-toggle-theater (lambda () (etaf-bili--watch-toggle-theater session))
              :on-toggle-fullscreen (lambda () (etaf-bili--watch-toggle-fullscreen session 'window))
              :on-toggle-frame-fullscreen (lambda () (etaf-bili--watch-toggle-fullscreen session 'frame))
              :on-exit-fullscreen (lambda () (etaf-bili--watch-exit-fullscreen session))
              :on-toggle-pip (lambda () (etaf-bili--watch-toggle-pip session))
              :on-pip-return (lambda () (etaf-bili--pip-return session))
              :on-open-mpv (lambda () (etaf-bili--open-external session))
              :on-open-browser (lambda () (etaf-bili--open-browser session))
              :on-toggle-auto-next (lambda () (etaf-bili--watch-toggle-auto-next session))
              :on-select-part (lambda (bvid cid) (etaf-bili--watch-open-bvid session bvid cid))
              :on-play-related (lambda (bvid) (etaf-bili--watch-open-bvid session bvid nil))
              :on-author on-author
              :on-like (lambda () (etaf-bili--watch-action session :like))
              :on-coin (lambda () (etaf-bili--watch-action session :coin))
              :on-fav (lambda () (etaf-bili--watch-action session :fav))
              :on-toview (lambda () (etaf-bili--watch-action session :toview))
              :on-theme #'etaf-bili-toggle-theme)
             (etaf-bili--toast-banner
              :toast (etaf-bili--session-toast-ref session)
              :ui-store (etaf-bili--session-ui-store session)
              :width (if show-side total-cols left-cols)
              :height watch-h
              :center (not show-side)
              :bottom-offset (if show-side 2 1)
              :on-dismiss (lambda () (etaf-bili--toast-clear session)))
             (etaf-ui-qr-login :open (and (plist-get login :open) t)
                               :code (plist-get login :qr)
                               :status (plist-get login :status)
                               :on-close close-sign-in))))
      (etaf-view
       (column :ref 'bili-shell :position 'relative
               :width (list 'px (plist-get layout :width)) :height (list 'lh height)
               :item-gap '(lh 0) :cross-align 'center
               :overflow 'hidden :background-color (etaf-bili-color :bg) :color (etaf-bili-color :ink)
               :keys (etaf-bili--gallery-keys)
         (box :width 'stretch :height '(lh 1) :background-color (etaf-bili-color :bg))
         (column :width 'stretch :height '(lh 3) :cross-align 'center
                 :background-color (etaf-bili-color :bg)
           (etaf-bili--header :query (etaf-bili--session-query-ref session)
                              :width width :compact (< width 96)
                              :account account :on-account on-account
                              :on-submit submit :on-theme #'etaf-bili-toggle-theme))
         (column :width 'stretch :height '(lh 1) :cross-align 'center
                 :background-color (etaf-bili-color :bg)
           (etaf-bili--navigation :mode (etaf-bili--session-mode-ref session)
                                  :status (etaf-bili--session-status-ref session)
                                  :loading (etaf-bili--session-loading-ref session)
                                  :play-loading (etaf-bili--session-play-loading-ref session)
                                  :account account :compact (< width 104)
                                  :width width :on-mode mode-change :on-refresh #'etaf-bili-refresh))
         (box :width 'stretch :height '(lh 1) :background-color (etaf-bili-color :bg))
         (column :if has-filter :width 'stretch :height '(lh 1) :cross-align 'center
                 :background-color (etaf-bili-color :bg)
           (etaf-bili--filter-bar
            :mode (etaf-bili--session-mode-ref session)
            :ranking-rid (etaf-bili--session-ranking-rid-ref session)
            :search-order (etaf-bili--session-search-order-ref session)
            :fav-folders (etaf-bili--session-fav-folders-ref session)
            :fav-folder-id (etaf-bili--session-fav-folder-id-ref session)
            :space-name (etaf-bili--session-space-name session)
            :width width
            :on-rid (lambda (rid) (etaf-bili-load-ranking session rid))
            :on-order (lambda (ord) (etaf-bili-search session (etaf-bili--session-keyword session) ord))
            :on-fav-folder (lambda (fid) (etaf-bili-load-favorites session fid))
            :on-leave-space (lambda () (etaf-bili-load-popular session))))
         (box :if has-filter :width 'stretch :height '(lh 1) :background-color (etaf-bili-color :bg))
         (column :width 'stretch :height (list 'lh (plist-get layout :body))
                 :cross-align 'center :overflow 'hidden :background-color (etaf-bili-color :bg)
           (etaf-bili--gallery :session session :layout layout
                               :on-play on-play :on-select on-select :on-author on-author))
         (column :width 'stretch :height '(lh 3) :cross-align 'center
                 :background-color (etaf-bili-color :bg)
           (etaf-bili--footer
            :session session :layout layout
            :on-return-watch (lambda () (etaf-bili--return-to-watch session))
            :on-toggle-bg-audio (lambda () (etaf-bili--bg-audio-toggle session))
            :on-stop-bg-audio (lambda () (etaf-bili--stop-all-playback session))))
         (etaf-drawer :open details :title "视频详情" :width '(ch 52)
                      :on-close (lambda () (etaf-set-value details nil))
           (column :width 'stretch :item-gap '(lh 1)
             (text :font-weight 'bold :color (etaf-bili-color :ink)
               (expr (or (plist-get row :title) "未选择视频")))
             (text :color (etaf-bili-color :accent) :font-weight 'bold
               (expr (format "UP %s" (or (plist-get row :author) ""))))
             (etaf-label :text (format "%s 播放  ·  %s  ·  %s"
                                       (etaf-bili--count (plist-get row :views))
                                       (or (plist-get row :date) "")
                                       (or (plist-get row :bvid) ""))
                         :variant 'muted)
             (flex :gap '((lh 0) (ch 2))
               (etaf-badge :text (etaf-bili--clock (plist-get row :duration)))
               (etaf-badge :if (let ((tn (plist-get row :tname)))
                                 (and (stringp tn) (not (string-empty-p tn))))
                           :text (plist-get row :tname))
               (etaf-badge :if (> (or (plist-get row :videos) 1) 1)
                           :text (format "%dP" (plist-get row :videos))))
             (etaf-divider)
             (box :if (let ((d (or (plist-get row :description) (plist-get row :desc))))
                        (and (stringp d) (not (string-empty-p (string-trim d)))))
                  :width 'stretch :color (etaf-bili-color :muted)
               (text (expr (etaf-bili--truncate
                            (or (plist-get row :description) (plist-get row :desc) "") 260))))
             (flex :gap '((lh 0) (ch 2))
               (etaf-button :label "播放视频" :variant 'primary
                            :on-press (lambda ()
                                        (etaf-set-value details nil)
                                        (etaf-bili--play-selected-into-watch session)))
               (etaf-button :if (and (plist-get row :mid) (> (plist-get row :mid) 0))
                            :label "UP 主空间" :variant 'secondary
                            :on-press (lambda ()
                                        (etaf-set-value details nil)
                                        (etaf-bili-load-space session
                                                              (plist-get row :mid)
                                                              (plist-get row :author))))
               (etaf-button :label "浏览器打开" :variant 'ghost
                            :on-press (lambda ()
                                        (etaf-set-value details nil)
                                        (etaf-bili--open-browser session))))))
         (etaf-dialog :open account-menu :title (format "账号 · %s" (or account "")) :width '(ch 42)
                      :close-label "关闭"
                      :on-close (lambda () (etaf-set-value account-menu nil))
           (column :width 'stretch :item-gap '(lh 1)
             (etaf-label :text (format "UID：%s%s"
                                       (or (etaf-bili--session-account-mid session) "—")
                                       (if (etaf-bili--session-account-vip session) " · 大会员" ""))
                         :variant 'muted)
             (flex :gap '((lh 0) (ch 1))
               (etaf-button :label "个性推荐" :variant 'secondary
                            :on-press (lambda ()
                                        (etaf-set-value account-menu nil)
                                        (etaf-bili-load-rcmd session)))
               (etaf-button :label "稍后再看" :variant 'secondary
                            :on-press (lambda ()
                                        (etaf-set-value account-menu nil)
                                        (etaf-bili-load-toview session)))
               (etaf-button :label "历史" :variant 'secondary
                            :on-press (lambda ()
                                        (etaf-set-value account-menu nil)
                                        (etaf-bili-load-history session))))
             (etaf-divider)
             (flex :justify-content 'space-between
               (etaf-button :label "重新扫码切换账号" :variant 'ghost
                            :on-press (lambda () (etaf-bili-login session)))
               (etaf-button :label "退出登录" :variant 'ghost
                            :on-press (lambda () (etaf-bili-logout session))))))
         (etaf-bili--toast-banner
          :toast (etaf-bili--session-toast-ref session)
          :ui-store (etaf-bili--session-ui-store session)
          :width (plist-get layout :columns) :height height :center t :bottom-offset 5
          :on-dismiss (lambda () (etaf-bili--toast-clear session)))
         (etaf-ui-qr-login :open (and (plist-get login :open) t)
                           :code (plist-get login :qr)
                           :status (plist-get login :status)
                           :on-close close-sign-in))))))

;;; Navigation, Selection & Cover Pipeline

(defun etaf-bili--switch-channel (session mode)
  "Switch SESSION to gallery channel MODE."
  (pcase mode
    ('rcmd (etaf-bili-load-rcmd session))
    ('popular (etaf-bili-load-popular session))
    ('ranking (etaf-bili-load-ranking session))
    ('dynamic (etaf-bili-load-dynamic session))
    ('toview (etaf-bili-load-toview session))
    ('history (etaf-bili-load-history session))
    ('fav (etaf-bili-load-favorites session))
    (_ (if (etaf-bili--session-keyword session)
           (etaf-bili-search session (etaf-bili--session-keyword session))
         (etaf-bili-search-prompt)))))

(defun etaf-bili--handle-search-submit (session query)
  "Handle SearchField submit: open direct BV/av/URL targets or search KEYWORD."
  (let ((target (etaf-bili-parse-target query)))
    (cond
     ((plist-get target :short-url)
      (etaf-bili--status session "正在解析短链接…")
      (etaf-bili-client-call
       (etaf-bili--session-client session)
       (list :op :resolve-url :url (plist-get target :short-url))
       (lambda (reply)
         (unless (etaf-bili--session-disposed session)
           (if-let* ((resolved (plist-get reply :ok)))
               (etaf-bili--watch-open-target session resolved)
             (etaf-bili--toast session (or (plist-get reply :error) "无法解析短链接") 'error))))))
     (target
      (etaf-bili--watch-open-target session target))
     (t
      (etaf-bili-search session query)))))

(defun etaf-bili--select (session index)
  "Select INDEX without unnecessarily publishing an identical state."
  (unless (= index (etaf-bili--session-selected session))
    (etaf-bili-move session (- index (etaf-bili--session-selected session)))))

(defun etaf-bili--direction (session layout direction)
  "Move SESSION across the card grid using DIRECTION and LAYOUT."
  (etaf-bili-move session (pcase direction
                            ('left -1) ('right 1)
                            ('up (- (plist-get layout :across)))
                            ('down (plist-get layout :across)) (_ 0)))
  (etaf-bili--focus-selected session)
  'handled)

(defun etaf-bili--observe-scroll (session offset)
  "Project OFFSET from the native scroll owner and auto-load next page."
  (unless (etaf-bili--session-disposed session)
    (when-let* ((layout (etaf-value (etaf-bili--session-layout-ref session)))
                (pitch (1+ (plist-get layout :card-height)))
                (first (/ offset pitch)))
      (unless (= first (etaf-value (etaf-bili--session-visible-row-ref session)))
        (etaf-set-value (etaf-bili--session-visible-row-ref session) first)
        (etaf-bili--prepare-covers session))
      ;; Auto-load next page when within 2 rows of the bottom.
      (let* ((count (length (etaf-bili--session-items session)))
             (across (max 1 (plist-get layout :across)))
             (total-rows (ceiling (float count) across))
             (vis-rows (max 1 (ceiling (float (plist-get layout :body)) pitch))))
        (when (and (> count 0) (>= (+ first vis-rows 2) total-rows))
          (etaf-bili-load-more session))))))

(defun etaf-bili--library-changed (session reset)
  "Prepare SESSION's resources and reset native scroll only for a new library."
  (when reset
    (etaf-set-value (etaf-bili--session-visible-row-ref session) 0)
    (etaf-next-tick
     (lambda ()
       (when-let* ((buffer (etaf-bili--session-buffer session))
                   (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
                   ((etaf-host-ref-size runtime 'bili-gallery)))
         (etaf-scroll-to runtime 'bili-gallery 'start)))))
  (etaf-bili--prepare-covers session))

(defun etaf-bili--focus-selected (session)
  "Reveal and focus SESSION's card using the native scroll offset authority."
  (etaf-next-tick
   (lambda ()
     (unless (or (etaf-bili--session-disposed session)
                 (null (etaf-bili--session-items session))
                 (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch))
       (when-let* ((buffer (etaf-bili--session-buffer session))
                   (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
                   (layout (etaf-value (etaf-bili--session-layout-ref session)))
                   ((etaf-host-ref-size runtime 'bili-gallery)))
         (let* ((row (/ (etaf-bili--session-selected session) (plist-get layout :across)))
                (top (* row (1+ (plist-get layout :card-height))))
                (bottom (+ top (plist-get layout :card-height)))
                (offset (etaf-scroll-offset runtime 'bili-gallery))
                (target (cond ((< top offset) top)
                              ((> bottom (+ offset (plist-get layout :body)))
                               (- bottom (plist-get layout :body)))
                              (t offset))))
           (etaf-scroll-to runtime 'bili-gallery target)
           (etaf-bili--observe-scroll session (etaf-scroll-offset runtime 'bili-gallery))
           (etaf-next-tick
            (lambda ()
              (unless (etaf-bili--session-disposed session)
                (ignore-errors
                  (etaf-focus runtime
                              (intern (format "bili-card-%d"
                                              (etaf-bili--session-selected session))))))))))))))

(defun etaf-bili--prepare-covers (session)
  "Prepare cover refs for SESSION's visible rows and their overscan neighbors."
  (unless (etaf-bili--session-disposed session)
    (let* ((table (etaf-bili--session-covers session))
           (items (etaf-bili--session-items session))
           (layout (or (etaf-value (etaf-bili--session-layout-ref session))
                       (etaf-bili--layout nil (etaf-bili--has-filter-bar-p session))))
           (slice (etaf-bili--visible-slice
                   (etaf-value (etaf-bili--session-visible-row-ref session))
                   (length items) layout)))
      (dolist (row items)
        (let ((url (plist-get row :cover)))
          (unless (gethash url table) (puthash url (cons nil (etaf-ref nil)) table))))
      (setf (etaf-bili--session-cover-queue session)
            (delete-dups
             (delq nil (mapcar
                        (lambda (row)
                          (let ((url (plist-get row :cover)))
                            (and (stringp url) (not (string-empty-p url))
                                 (null (car (gethash url table))) url)))
                        (seq-subseq items (plist-get slice :start) (plist-get slice :end))))))
      (when (display-graphic-p) (etaf-bili--pump-covers session)))))

(defun etaf-bili--pump-covers (session)
  "Run at most three cover transfers concurrently for SESSION."
  (while (and (not (etaf-bili--session-disposed session))
              (< (etaf-bili--session-cover-active session) 3)
              (etaf-bili--session-cover-queue session))
    (let* ((url (pop (etaf-bili--session-cover-queue session)))
           (entry (gethash url (etaf-bili--session-covers session))))
      (when (and entry (null (car entry)))
        (setcar entry 'loading)
        (cl-incf (etaf-bili--session-cover-active session))
        (let* ((client (etaf-bili--session-client session))
               (op (if (functionp client) :cover :cover-tracked))
               (record nil)
               (handle
                (etaf-bili-client-call
                 client (list :op op :url url)
                 (lambda (reply)
                   (cl-decf (etaf-bili--session-cover-active session))
                   (when record
                     (setf (etaf-bili--session-cover-jobs session)
                           (delq record (etaf-bili--session-cover-jobs session))))
                   (setcar entry 'done)
                   (unless (etaf-bili--session-disposed session)
                     (etaf-set-value
                      (cdr entry)
                      (if-let* ((file (plist-get reply :ok)))
                          (condition-case _unreadable
                              (let ((size (image-size (create-image file) t)))
                                (list :file file :size size))
                            (error 'unavailable))
                        'unavailable))
                     (etaf-bili--pump-covers session)))))
               (job (if (consp handle) (car handle) handle))
               (tmp (and (consp handle) (cdr handle))))
          (when (etaf-process-live-p job)
            (setq record (list job entry tmp))
            (push record (etaf-bili--session-cover-jobs session))))))))

(defun etaf-bili--cancel-covers (session)
  "Cancel in-flight cover transfers, reset `cover-active' and clean temp files."
  (dolist (rec (etaf-bili--session-cover-jobs session))
    (pcase-let ((`(,job ,entry ,tmp) rec))
      (ignore-errors (etaf-process-cancel job))
      (when (and (consp entry) (eq (car entry) 'loading))
        (setcar entry nil))
      (when (and (stringp tmp) (file-exists-p tmp))
        (ignore-errors (delete-file tmp)))))
  ;; Also reset any non-process in-flight entries so :keep-alive remount retries.
  (maphash (lambda (_url entry)
             (when (and (consp entry) (eq (car entry) 'loading))
               (setcar entry nil)))
           (etaf-bili--session-covers session))
  (setf (etaf-bili--session-cover-jobs session) nil
        (etaf-bili--session-cover-active session) 0))

;;; Viewport synchronization (region-aware + watch resize debounce)

(defun etaf-bili--layout-matches-p (layout viewport cell has-filter)
  "Return non-nil when LAYOUT already represents VIEWPORT, CELL and HAS-FILTER."
  (and layout
       (eql (plist-get layout :width) (max (* 64 (car cell)) (car viewport)))
       (eql (plist-get layout :raw-rows) (cdr viewport))
       (eql (plist-get layout :cell-width) (car cell))
       (eql (plist-get layout :cell-height) (cdr cell))
       (eq (not (null (plist-get layout :has-filter))) (not (null has-filter)))))

(defun etaf-bili--apply-viewport (session viewport cell)
  "Commit computed layout for VIEWPORT and CELL into SESSION."
  (setf (etaf-bili--session-resize-timer session) nil)
  (unless (etaf-bili--session-disposed session)
    (let ((has-filter (etaf-bili--has-filter-bar-p session))
          (current (etaf-value (etaf-bili--session-layout-ref session))))
      (unless (etaf-bili--layout-matches-p current viewport cell has-filter)
        (etaf-set-value
         (etaf-bili--session-layout-ref session)
         (etaf-bili--layout (list (car viewport) (cdr viewport)
                                  (car cell) (cdr cell))
                            has-filter))
        (unless (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch)
          (etaf-bili--prepare-covers session))))))

(defun etaf-bili--sync-viewport (session &optional region-viewport immediate)
  "Lay SESSION out for REGION-VIEWPORT (from `etaf-viewport') or its window.
Commits immediately for native libmpv (zero-restart resize), non-playing states,
height-only transitions (such as fullscreen mode-line toggling) and when
IMMEDIATE is non-nil.  Debounces only width drags on legacy non-mpv playback."
  (when-let* ((buffer (etaf-bili--session-buffer session))
              (runtime (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
              ((etaf-runtime-mounted-p runtime))
              (viewport (or (and (consp region-viewport)
                                 (numberp (car region-viewport))
                                 (numberp (cdr region-viewport))
                                 region-viewport)
                            (etaf-runtime-viewport runtime)
                            (etaf-runtime-window-viewport runtime)))
              (metrics (ignore-errors (etaf-display-metrics runtime)))
              (cell (cons (max 1 (or (plist-get metrics :char-width) 7))
                          (max 1 (or (plist-get metrics :line-height) 16)))))
    (let* ((win (get-buffer-window buffer t))
           (current (etaf-value (etaf-bili--session-layout-ref session)))
           (committed-rows (plist-get current :raw-rows))
           (has-filter (etaf-bili--has-filter-bar-p session))
           (effective-vp
            (if (and (not immediate)
                     (integerp committed-rows)
                     win (window-live-p win)
                     (etaf-transient-space-borrowed-p win committed-rows))
                (cons (car viewport) committed-rows)
              viewport)))
      (when (etaf-bili--layout-matches-p current effective-vp cell has-filter)
        (when-let* ((old (etaf-bili--session-resize-timer session)))
          (cancel-timer old)
          (setf (etaf-bili--session-resize-timer session) nil)))
      (unless (etaf-bili--layout-matches-p current effective-vp cell has-filter)
        (when-let* ((old (etaf-bili--session-resize-timer session)))
          (cancel-timer old)
          (setf (etaf-bili--session-resize-timer session) nil))
        (let* ((in-watch (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch))
               (playing (etaf-value (etaf-bili--session-watch-playing-ref session)))
               (same-width (and current
                                (eql (plist-get current :width)
                                     (max (* 64 (car cell)) (car effective-vp)))))
               (mpv-live (and in-watch
                              (or (etaf-video-mpv-available-p)
                                  (eq (plist-get
                                       (ignore-errors
                                         (etaf-video-state
                                          (etaf-bili--session-watch-handle session)))
                                       :engine)
                                      'mpv)))))
          (if (and (not immediate) in-watch current playing
                   (not mpv-live) (not same-width))
              (setf (etaf-bili--session-resize-timer session)
                    (run-at-time 0.15 nil #'etaf-bili--apply-viewport
                                 session effective-vp cell))
            (etaf-bili--apply-viewport session effective-vp cell)))))))

;;; Watch View Playback, Retained Updates, Audio-Only & PiP

(defun etaf-bili--save-progress (session &optional send-heartbeat)
  "Persist SESSION's current watch position locally and optionally to Bilibili."
  (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session)))
              (bvid (plist-get src :bvid))
              (cid (plist-get src :cid))
              (pos (etaf-bili--session-watch-position session)))
    (when (> pos 1.0)
      (etaf-bili-store-progress-put bvid cid pos
                                    (etaf-bili--session-watch-duration session)
                                    (plist-get src :title))
      (when (and send-heartbeat
                 (etaf-value (etaf-bili--session-account-ref session))
                 (plist-get src :aid) (> (plist-get src :aid) 0))
        (let ((now (float-time)))
          (when (or (null (etaf-bili--session-heartbeat-at session))
                    (>= (- now (etaf-bili--session-heartbeat-at session)) 15.0))
            (setf (etaf-bili--session-heartbeat-at session) now)
            (etaf-bili-client-call
             (etaf-bili--session-client session)
             (list :op :heartbeat :aid (plist-get src :aid)
                   :cid cid :played-time pos)
             #'ignore)))))))

(defun etaf-bili--bg-audio-stop (session)
  "Stop SESSION's background audio-only ffplay process."
  (when-let* ((proc (etaf-bili--session-audio-bg-process session)))
    (when (process-live-p proc)
      (delete-process proc))
    (when-let* ((buf (process-buffer proc)))
      (when (buffer-live-p buf) (kill-buffer buf)))
    (setf (etaf-bili--session-audio-bg-process session) nil)))

(defun etaf-bili--bg-audio-start (session &optional start-pos)
  "Start ffplay in audio-only mode for SESSION's active watch source."
  (etaf-bili--bg-audio-stop session)
  (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session)))
              (target (or (plist-get src :audio-url) (plist-get src :url)))
              (prog (executable-find etaf-video-ffplay-program)))
    (let* ((pos (max 0.0 (float (or start-pos (etaf-bili--session-watch-position session) 0.0))))
           (spd (etaf-value (etaf-bili--session-watch-speed-ref session)))
           (vol (if (etaf-value (etaf-bili--session-watch-audio-ref session))
                    (etaf-value (etaf-bili--session-watch-volume-ref session))
                  0))
           (headers (format "Referer: %s\r\n" etaf-bili--referer))
           (buf (generate-new-buffer " *etaf-bili-audio*"))
           (cmd (append (list prog "-nodisp" "-autoexit" "-hide_banner" "-loglevel" "error"
                              "-volume" (number-to-string (round vol)))
                        (when (> pos 0) (list "-ss" (format "%.3f" pos)))
                        (when (and (numberp spd) (/= spd 1))
                          (list "-af" (format "atempo=%s" spd)))
                        (list "-user_agent" etaf-bili--user-agent
                              "-headers" headers
                              "-reconnect" "1" "-reconnect_streamed" "1"
                              "-reconnect_delay_max" "5"
                              "-probesize" "32768" "-analyzeduration" "200000"
                              target)))
           (proc (condition-case nil
                     (make-process
                      :name "etaf-bili-bg-audio"
                      :command cmd :buffer buf
                      :coding '(no-conversion . no-conversion)
                      :connection-type 'pipe :noquery t
                      :sentinel
                      (lambda (p _ev)
                        (when (memq (process-status p) '(exit signal))
                          (when (buffer-live-p (process-buffer p))
                            (kill-buffer (process-buffer p)))
                          (when (eq p (etaf-bili--session-audio-bg-process session))
                            (setf (etaf-bili--session-audio-bg-process session) nil)
                            (unless (etaf-bili--session-disposed session)
                              (etaf-set-value (etaf-bili--session-watch-playing-ref session) nil))))))
                   (error (when (buffer-live-p buf) (kill-buffer buf)) nil))))
      (when proc
        (setf (etaf-bili--session-audio-bg-process session) proc
              (etaf-bili--session-audio-bg-base session) pos
              (etaf-bili--session-audio-bg-stamp session) (float-time)
              (etaf-bili--session-watch-position session) pos)
        (etaf-set-value (etaf-bili--session-watch-playing-ref session) t)))))

(defun etaf-bili--bg-audio-toggle (session)
  "Toggle background audio-only playback in SESSION."
  (if (etaf-bili--session-audio-bg-process session)
      (progn
        (etaf-bili--save-progress session t)
        (etaf-bili--bg-audio-stop session)
        (etaf-set-value (etaf-bili--session-watch-playing-ref session) nil))
    (etaf-bili--bg-audio-start session (etaf-bili--session-watch-position session))))

;;; Native libass Danmaku & Floating Picture-in-Picture (PiP)

(defconst etaf-bili--pip-time-ref 'bili-pip-time
  "Retained Host ref for PiP elapsed / total time readout.")

(defconst etaf-bili--pip-subtitle-ref 'bili-pip-subtitle
  "Retained Host ref for PiP optional CC subtitle strip.")

(defconst etaf-bili--pip-progress-fill-ref 'bili-pip-progress-fill
  "Retained Host ref for PiP progress fill.")

(defconst etaf-bili--pip-id 'etaf-bili
  "Shared `etaf-pip' host identifier for Bilibili.")

(defun etaf-bili--watch-dm-options (session)
  "Return SESSION's current ASS danmaku compilation options plist."
  (list :area (etaf-value (etaf-bili--session-watch-dm-area-ref session))
        :opacity (etaf-value (etaf-bili--session-watch-dm-opacity-ref session))
        :font-size (etaf-value (etaf-bili--session-watch-dm-size-ref session))
        :density (etaf-value (etaf-bili--session-watch-dm-density-ref session))
        :show-scroll (etaf-value (etaf-bili--session-watch-dm-scroll-ref session))
        :show-top (etaf-value (etaf-bili--session-watch-dm-top-ref session))
        :show-bottom (etaf-value (etaf-bili--session-watch-dm-bottom-ref session))))

(defun etaf-bili--watch-dm-cleanup (session)
  "Remove SESSION's temporary ASS danmaku file and clear load state."
  (when-let* ((file (etaf-bili--session-watch-dm-ass-file session)))
    (ignore-errors (when (file-exists-p file) (delete-file file)))
    (setf (etaf-bili--session-watch-dm-ass-file session) nil))
  (setf (etaf-bili--session-watch-dm-loaded-ass session) nil
        (etaf-bili--session-pip-dm-loaded-ass session) nil))

(defun etaf-bili--watch-dm-compile (session &optional force)
  "Compile SESSION's danmaku list into a temporary `.ass' file and return path.
Reuses an existing compiled file unless FORCE is non-nil."
  (let* ((entries (etaf-value (etaf-bili--session-watch-danmaku-list-ref session)))
         (existing (etaf-bili--session-watch-dm-ass-file session)))
    (cond
     ((null entries) nil)
     ((and (not force) existing (file-exists-p existing)) existing)
     (t
      (let ((path (or existing
                      (make-temp-file (format "etaf-bili-dm-%d-" (emacs-pid))
                                      nil ".ass"))))
        (setf (etaf-bili--session-watch-dm-ass-file session) path)
        (etaf-bili--danmaku-write-ass entries path
                                      (etaf-bili--watch-dm-options session)))))))

(defun etaf-bili--watch-dm-sync-handle (session handle enabled &optional reload pip-p)
  "Attach or toggle SESSION's ASS danmaku on live libmpv HANDLE.
When ENABLED is non-nil, ensures the compiled `.ass' track is loaded and
visible; when nil, hides the track via `sub-visibility' with zero layout
shift.  RELOAD forces re-attaching after danmaku display settings change."
  (when handle
    (let* ((st (ignore-errors (etaf-video-state handle)))
           (mpv-ready (and st (eq (plist-get st :engine) 'mpv)
                           (> (or (plist-get st :presented) 0) 0))))
      (when mpv-ready
        (let* ((loaded (if pip-p
                           (etaf-bili--session-pip-dm-loaded-ass session)
                         (etaf-bili--session-watch-dm-loaded-ass session)))
               (same-handle (and (consp loaded) (eq (car loaded) handle)))
               (path (when (or enabled reload same-handle)
                       (etaf-bili--watch-dm-compile session reload))))
          (cond
           ((and path reload same-handle)
            (ignore-errors (etaf-video-command handle "sub-remove"))
            (ignore-errors (etaf-video-command handle "sub-add" path "select"))
            (if pip-p
                (setf (etaf-bili--session-pip-dm-loaded-ass session) (cons handle path))
              (setf (etaf-bili--session-watch-dm-loaded-ass session) (cons handle path))))
           ((and path (not same-handle))
            (when (eql 0 (ignore-errors (etaf-video-command handle "sub-add" path "select")))
              (if pip-p
                  (setf (etaf-bili--session-pip-dm-loaded-ass session) (cons handle path))
                (setf (etaf-bili--session-watch-dm-loaded-ass session) (cons handle path))))))
          (ignore-errors
            (etaf-video-set-property handle "sub-visibility" (and enabled t))))))))

(defun etaf-bili--pip-theme-colors ()
  "Return theme color plist for `etaf-pip-open'."
  (let ((mode (etaf-value etaf-bili--theme-mode-ref)))
    (list :bg (etaf-bili-color :bg mode)
          :panel (etaf-bili-color :panel2 mode)
          :chip (etaf-bili-color :panel3 mode)
          :hover (etaf-bili-color :hover mode)
          :ink (etaf-bili-color :ink mode)
          :muted (etaf-bili-color :muted mode)
          :accent (etaf-bili-color :accent mode)
          :accent-soft (etaf-bili-color :accent-soft mode)
          :border-inactive (if (eq mode 'light) "#CBD3E0" "#2D364A"))))

(defun etaf-bili--pip-apply-theme (_session)
  "Repaint Bilibili's PiP chrome when Dark/Light mode changes."
  (when (etaf-pip-active-p etaf-bili--pip-id)
    (etaf-pip-refresh-chrome etaf-bili--pip-id)))

(defun etaf-bili--pip-canvas-fit (source cols rows cw lh)
  "Fit SOURCE aspect inside COLS by ROWS without clamping over ROWS."
  (let* ((w (float (max 1 (or (plist-get source :width) 16))))
         (h (float (max 1 (or (plist-get source :height) 9))))
         (aspect (/ w h))
         (avail-px (float (max cw (* cols cw))))
         (avail-py (float (max lh (* rows lh))))
         (fit-py (min avail-py (/ avail-px aspect)))
         (crows (max 1 (min rows (floor fit-py lh))))
         (fit-px (min avail-px (* crows lh aspect)))
         (ccols (max 4 (min cols (round (/ fit-px cw))))))
    (cons ccols crows)))

(defun etaf-bili--pip-cycle-size (_session)
  "Cycle PiP window size among Small, Medium and Large."
  (etaf-pip-cycle-size etaf-bili--pip-id))

(defun etaf-bili--pip-cycle-corner (_session)
  "Snap PiP clockwise to the next parent-frame corner."
  (etaf-pip-cycle-corner etaf-bili--pip-id))

(defun etaf-bili--pip-toggle-cc (session)
  "Toggle CC subtitle strip inside PiP."
  (etaf-update-value (etaf-bili--session-pip-cc-ref session) #'not))

(defun etaf-bili--pip-toggle-danmaku (session)
  "Toggle native libass danmaku inside PiP without layout shift."
  (let ((next (not (etaf-value (etaf-bili--session-pip-dm-ref session)))))
    (etaf-set-value (etaf-bili--session-pip-dm-ref session) next)
    (etaf-bili--watch-dm-sync-handle
     session (etaf-bili--session-pip-handle session) next nil t)))

(defun etaf-bili--pip-seek (session seconds)
  "Seek active PiP video to SECONDS and update PiP HUD."
  (when-let* ((h (etaf-bili--session-pip-handle session)))
    (let* ((dur (etaf-bili--session-watch-duration session))
           (target (max 0.0 (if (> dur 0) (min (float seconds) dur) (float seconds)))))
      (setf (etaf-bili--session-watch-position session) target)
      (ignore-errors (etaf-video-seek h target))
      (etaf-bili--save-progress session))))

(defun etaf-bili--pip-on-close (session)
  "Save latest PiP progress and clear SESSION's PiP refs when host closes."
  (when-let* ((h (etaf-bili--session-pip-handle session))
              (st (ignore-errors (etaf-video-state h)))
              (pos (plist-get st :position)))
    (when (and (numberp pos) (> pos 0.0))
      (setf (etaf-bili--session-watch-position session) (float pos))
      (etaf-bili--save-progress session t)))
  (setf (etaf-bili--session-pip-handle session) nil
        (etaf-bili--session-pip-backup-index session) 0
        (etaf-bili--session-pip-refresh-tried session) nil
        (etaf-bili--session-pip-dm-loaded-ass session) nil)
  (etaf-batch
    (etaf-set-value (etaf-bili--session-pip-src-ref session) nil)
    (etaf-set-value (etaf-bili--session-pip-buffering-ref session) nil)
    (etaf-set-value (etaf-bili--session-pip-error-ref session) nil)
    (etaf-set-value (etaf-bili--session-pip-active-ref session) nil)))

(defun etaf-bili--pip-close (session &optional restore-focus)
  "Close SESSION's Picture-in-Picture floating frame cleanly."
  (if (etaf-pip-active-p etaf-bili--pip-id)
      (etaf-pip-close etaf-bili--pip-id restore-focus)
    (when (or (etaf-bili--session-pip-handle session)
              (etaf-value (etaf-bili--session-pip-active-ref session)))
      (etaf-bili--pip-on-close session))))

(defun etaf-bili--pip-return (session)
  "Close PiP and seamlessly resume playback in `*Bili*' Watch View."
  (let* ((fr (etaf-pip-frame etaf-bili--pip-id))
         (parent (and fr (frame-live-p fr) (frame-parent fr)))
         (pos (or (when-let* ((h (etaf-bili--session-pip-handle session))
                              (st (ignore-errors (etaf-video-state h))))
                    (plist-get st :position))
                  (etaf-bili--session-watch-position session)
                  0.0)))
    (etaf-bili--pip-close session t)
    (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session))))
      (setf (etaf-bili--session-watch-position session) (float pos)
            (etaf-bili--session-watch-dm-loaded-ass session) nil)
      (etaf-batch
        (etaf-set-value (etaf-bili--session-watch-source-ref session)
                        (plist-put (copy-sequence src) :start (float pos)))
        (etaf-set-value (etaf-bili--session-watch-audio-only-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-playing-ref session) t)
        (etaf-set-value (etaf-bili--session-view-mode-ref session) 'watch))
      (when (and parent (frame-live-p parent))
        (select-frame-set-input-focus parent))
      (when-let* ((buf (etaf-bili--session-buffer session))
                  ((buffer-live-p buf)))
        (switch-to-buffer buf)))))

(defun etaf-bili--url-expired-p (url &optional margin)
  "Return non-nil when Bilibili CDN URL's `deadline=' timestamp is expired."
  (when (and (stringp url)
             (string-match "[?&]deadline=\\([0-9]+\\)" url))
    (let ((dl (string-to-number (match-string 1 url))))
      (and (> dl 0) (< (- dl (or margin 180)) (float-time))))))

(defun etaf-bili--pip-refresh-stream (session pos)
  "Re-fetch fresh Bilibili stream URLs for SESSION's PiP and resume at POS."
  (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session)))
              (bvid (plist-get src :bvid)))
    (let ((cid (plist-get src :cid))
          (qn (plist-get src :quality-id))
          (target-pos (float (max 0.0 (or pos 0.0)))))
      (etaf-batch
        (etaf-set-value (etaf-bili--session-pip-error-ref session) nil)
        (etaf-set-value (etaf-bili--session-pip-buffering-ref session) t))
      (etaf-bili-client-call
       (etaf-bili--session-client session)
       (append (list :op :play :bvid bvid)
               (when cid (list :cid cid))
               (when qn (list :qn qn)))
       (lambda (reply)
         (unless (or (etaf-bili--session-disposed session)
                     (not (etaf-pip-active-p etaf-bili--pip-id)))
           (if-let* ((fresh (plist-get reply :ok)))
               (let ((pip-fresh (plist-put (copy-sequence fresh) :start target-pos)))
                 (setf (etaf-bili--session-pip-backup-index session) 0
                       (etaf-bili--session-pip-dm-loaded-ass session) nil)
                 (etaf-batch
                   (etaf-set-value (etaf-bili--session-watch-source-ref session) fresh)
                   (etaf-set-value (etaf-bili--session-pip-error-ref session) nil)
                   (etaf-set-value (etaf-bili--session-pip-buffering-ref session) nil)
                   (etaf-set-value (etaf-bili--session-pip-playing-ref session) t)
                   (etaf-set-value (etaf-bili--session-pip-src-ref session) pip-fresh))
                 (etaf-pip-refresh-chrome etaf-bili--pip-id))
             (etaf-batch
               (etaf-set-value (etaf-bili--session-pip-buffering-ref session) nil)
               (etaf-set-value (etaf-bili--session-pip-playing-ref session) nil)
               (etaf-set-value (etaf-bili--session-pip-error-ref session)
                               (or (plist-get reply :error) "无法刷新视频流"))))))))))

(defun etaf-bili--pip-failover-or-refresh (session err)
  "Recover SESSION's PiP stream from ERR via backup CDN or fresh `:play' URL."
  (let* ((cur (or (etaf-value (etaf-bili--session-pip-src-ref session))
                  (etaf-value (etaf-bili--session-watch-source-ref session))))
         (pos (etaf-bili--session-watch-position session))
         (backups (and cur (plist-get cur :backup-urls)))
         (audio-backups (and cur (plist-get cur :audio-backup-urls)))
         (bidx (or (etaf-bili--session-pip-backup-index session) 0)))
    (cond
     ((and cur (< bidx (length backups)))
      (let ((updated (copy-sequence cur)))
        (setf (etaf-bili--session-pip-backup-index session) (1+ bidx)
              (etaf-bili--session-pip-dm-loaded-ass session) nil)
        (setq updated (plist-put updated :url (nth bidx backups)))
        (setq updated (plist-put updated :start (float (max 0.0 pos))))
        (when (and audio-backups (< bidx (length audio-backups)))
          (setq updated (plist-put updated :audio-url (nth bidx audio-backups))))
        (etaf-batch
          (etaf-set-value (etaf-bili--session-pip-error-ref session) nil)
          (etaf-set-value (etaf-bili--session-pip-buffering-ref session) t)
          (etaf-set-value (etaf-bili--session-pip-playing-ref session) t)
          (etaf-set-value (etaf-bili--session-pip-src-ref session) updated))))
     ((and cur (plist-get cur :bvid) (not (etaf-bili--session-pip-refresh-tried session)))
      (setf (etaf-bili--session-pip-refresh-tried session) t)
      (etaf-bili--pip-refresh-stream session pos))
     (t
      (etaf-batch
        (etaf-set-value (etaf-bili--session-pip-buffering-ref session) nil)
        (etaf-set-value (etaf-bili--session-pip-playing-ref session) nil)
        (etaf-set-value (etaf-bili--session-pip-error-ref session) (or err "播放连接失败")))))))

(defun etaf-bili--pip-toggle-play (session)
  "Toggle play/pause inside SESSION's PiP, or retry immediately if errored."
  (let* ((ph (etaf-bili--session-pip-handle session))
         (st (and ph (ignore-errors (etaf-video-state ph))))
         (err (or (etaf-value (etaf-bili--session-pip-error-ref session))
                  (and st (plist-get st :error))))
         (stalled (or (null st)
                      (and (plist-get st :ended)
                           (= 0 (or (plist-get st :presented) 0))))))
    (if (or err stalled)
        (let ((pos (etaf-bili--session-watch-position session)))
          (setf (etaf-bili--session-pip-refresh-tried session) nil
                (etaf-bili--session-pip-backup-index session) 0)
          (if (plist-get (etaf-value (etaf-bili--session-watch-source-ref session)) :bvid)
              (etaf-bili--pip-refresh-stream session pos)
            (when-let* ((cur (etaf-value (etaf-bili--session-pip-src-ref session))))
              (etaf-batch
                (etaf-set-value (etaf-bili--session-pip-error-ref session) nil)
                (etaf-set-value (etaf-bili--session-pip-playing-ref session) t)
                (etaf-set-value (etaf-bili--session-pip-src-ref session)
                                (plist-put (copy-sequence cur) :start (float pos)))))))
      (ignore-errors (etaf-video-toggle-playback ph))
      (let* ((after (ignore-errors (etaf-video-state ph)))
             (now-playing (and after (plist-get after :playing) t)))
        (etaf-set-value (etaf-bili--session-pip-playing-ref session) now-playing)
        (etaf-set-value (etaf-bili--session-watch-playing-ref session) now-playing)))))

(defun etaf-bili--pip-step-episode (session delta)
  "Switch to previous/next episode inside SESSION's PiP without closing PiP."
  (etaf-bili--watch-step-episode session delta))

(etaf-define-component etaf-bili--pip-view (&key session src-ref handle)
  "Reactive floating Picture-in-Picture player adapting to any window geometry."
  :render
  (let* ((_mode (etaf-value etaf-bili--theme-mode-ref))
         (pip-src (etaf-value src-ref))
         (bounds (or (etaf-pip-bounds etaf-bili--pip-id)
                     '(:width-px 464 :height-px 288 :cols 58 :rows 18 :cell-w 8 :cell-h 16)))
         (px-w (plist-get bounds :width-px))
         (cols (plist-get bounds :cols))
         (rows (plist-get bounds :rows))
         (cw (plist-get bounds :cell-w))
         (lh (plist-get bounds :cell-h))
         (mini (< cols 44))
         (full-time (>= cols 52))
         (show-time (>= cols 30))
         (hpad-cols (if (< cols 52) 1 2))
         (cc-on (and (etaf-value (etaf-bili--session-pip-cc-ref session)) t))
         (dm-on (and (etaf-value (etaf-bili--session-pip-dm-ref session)) t))
         (show-cc (and cc-on (>= rows 9)))
         (trans-rows (if (>= rows 8) 3 2))
         (vrows (max 2 (- rows (if show-cc 1 0) trans-rows)))
         (playing (etaf-value (etaf-bili--session-pip-playing-ref session)))
         (buffering (etaf-value (etaf-bili--session-pip-buffering-ref session)))
         (play-err (etaf-value (etaf-bili--session-pip-error-ref session)))
         (audio-on (etaf-value (etaf-bili--session-watch-audio-ref session)))
         (vol (etaf-value (etaf-bili--session-watch-volume-ref session)))
         (spd (etaf-value (etaf-bili--session-watch-speed-ref session)))
         (canvas (etaf-bili--pip-canvas-fit (or pip-src '(:width 16 :height 9))
                                            cols vrows cw lh))
         (vpad-top (max 0 (/ (- vrows (cdr canvas)) 2)))
         (vpad-bot (max 0 (- vrows (cdr canvas) vpad-top)))
         (time-txt (cond
                    (buffering (if mini "···" "··· 缓冲中"))
                    (full-time (format "%s / %s"
                                       (etaf-bili--session-pip-time-text session)
                                       (etaf-bili--session-pip-duration-text session)))
                    (show-time (etaf-bili--session-pip-time-text session))
                    (t "")))
         (on-toggle (lambda () (etaf-bili--pip-toggle-play session)))
         (on-prev (lambda () (etaf-bili--pip-step-episode session -1)))
         (on-next (lambda () (etaf-bili--pip-step-episode session 1)))
         (on-seek-by (lambda (delta)
                       (etaf-bili--pip-seek
                        session (+ (etaf-bili--session-watch-position session) delta)))))
    (etaf-view
     (column :width (list 'px px-w) :height (list 'lh rows)
             :item-gap '(lh 0) :overflow 'hidden
             :background-color "#050607" :color (etaf-bili-color :ink)
             :keys (list (list "SPC" on-toggle "播停")
                         (list "P" on-prev "上一集 / 上一视频")
                         (list "<" on-prev "上一集 / 上一视频")
                         (list "N" on-next "下一集 / 下一视频")
                         (list ">" on-next "下一集 / 下一视频")
                         (list "j" (lambda () (funcall on-seek-by -10)) "快退 10 秒")
                         (list "l" (lambda () (funcall on-seek-by 10)) "快进 10 秒")
                         (list "[" (lambda () (etaf-bili--watch-volume-delta session -10)) "降低音量")
                         (list "]" (lambda () (etaf-bili--watch-volume-delta session 10)) "提高音量")
                         (list "m" (lambda () (etaf-bili--watch-toggle-audio session)) "静音")
                         (list "+" (lambda () (etaf-bili--watch-step-speed session 1)) "加速")
                         (list "=" (lambda () (etaf-bili--watch-step-speed session 1)) "加速")
                         (list "-" (lambda () (etaf-bili--watch-step-speed session -1)) "减速")
                         (list "." (lambda () (etaf-bili--watch-cycle-speed session)) "切换倍速")
                         (list "c" (lambda () (etaf-bili--pip-toggle-cc session)) "开关字幕")
                         (list "d" (lambda () (etaf-bili--pip-toggle-danmaku session)) "开关弹幕")
                         (list "s" (lambda () (etaf-bili--pip-cycle-size session)) "切换窗口大小")
                         (list "p" (lambda () (etaf-bili--pip-cycle-corner session)) "换角停靠")
                         (list "r" (lambda () (etaf-bili--pip-return session)) "回主界面")
                         (list "b" (lambda () (etaf-bili--pip-return session)) "回主界面")
                         (list "q" (lambda () (etaf-bili--pip-close session t)) "关闭画中画")
                         (list "v" (lambda () (etaf-bili--pip-close session t)) "关闭画中画"))
             :on-dismiss (lambda () (etaf-bili--pip-close session t))
       ;; Adaptive Video Stage (fits aspect ratio cleanly to live window height/width)
       (column :width 'stretch :height (list 'lh vrows) :item-gap '(lh 0)
               :background-color "#050607" :overflow 'hidden
               :border-top (etaf-bili--border (etaf-bili-color :line))
               :on-press on-toggle
         (box :if (and (not play-err) pip-src (> vpad-top 0))
              :width 'stretch :height (list 'lh vpad-top)
              :background-color "#050607")
         (flex :width 'stretch
               :height (list 'lh (if (and (not play-err) pip-src) (cdr canvas) vrows))
               :align-items 'center :justify-content 'center
               :background-color (if play-err (etaf-bili-color :panel2) "#050607")
               :overflow 'hidden
           (column :if play-err
                   :width (list 'ch (max 16 (- cols 6)))
                   :padding '((lh 1) (ch 2)) :item-gap '(lh 1) :cross-align 'center
                   :background-color (etaf-bili-color :danger-bg)
                   :border (etaf-bili--border (etaf-bili-color :danger))
             (text :color (etaf-bili-color :danger) :font-weight 'bold
               (expr (etaf-bili--truncate (format "播放异常：%s" play-err) (max 10 (- cols 10)))))
             (etaf-button :label "重试续播" :variant 'primary :on-press on-toggle))
           (box :if (and (not play-err) (null pip-src))
                :padding '((lh 0) (ch 1)) :color (etaf-bili-color :muted)
             (text "··· 正在获取视频流…"))
           (etaf-video :if (and (not play-err) pip-src)
                       :src pip-src
                       :columns (car canvas) :rows (cdr canvas)
                       :handle handle
                       :audio (etaf-bili--session-watch-audio-ref session)
                       :volume (etaf-bili--session-watch-volume-ref session)
                       :speed (etaf-bili--session-watch-speed-ref session)
                       :autoplay t))
         (box :if (and (not play-err) pip-src (> vpad-bot 0))
              :width 'stretch :height (list 'lh vpad-bot)
              :background-color "#050607"))
       ;; Optional 1-row CC Subtitle Strip (auto-hidden when window is very short)
       (box :if show-cc :width 'stretch :height '(lh 1)
            :padding (list '(lh 0) (list 'ch hpad-cols)) :text-align 'center
            :overflow 'hidden :wrap-mode 'none
            :background-color "#080A0F" :color "#F4F6FA"
         (text :ref etaf-bili--pip-subtitle-ref
               :id (symbol-name etaf-bili--pip-subtitle-ref)
           (expr (etaf-bili--session-pip-subtitle-text session))))
       ;; Shared Adaptive Transport Deck (reused 1:1 with Pure Fullscreen!)
       (etaf-bili--cinema-deck
        :px-w px-w :cols cols :rows rows :cw cw
        :playing playing :buffering buffering
        :audio-on audio-on :vol vol :spd spd
        :cc-on cc-on :dm-on dm-on
        :progress-ref (etaf-bili--session-pip-progress-ref session)
        :progress-fill-ref etaf-bili--pip-progress-fill-ref
        :progress-id 'bili-pip-progress
        :time-ref etaf-bili--pip-time-ref
        :time-text time-txt
        :on-seek (lambda (pct)
                   (let ((dur (etaf-bili--session-watch-duration session)))
                     (when (> dur 0)
                       (etaf-bili--pip-seek session (* dur (/ pct 100.0))))))
        :on-toggle on-toggle
        :on-prev on-prev :on-next on-next
        :on-toggle-audio (lambda () (etaf-bili--watch-toggle-audio session))
        :on-cycle-speed (lambda () (etaf-bili--watch-cycle-speed session))
        :on-toggle-cc (lambda () (etaf-bili--pip-toggle-cc session))
        :on-toggle-dm (lambda () (etaf-bili--pip-toggle-danmaku session)))))))

(defun etaf-bili--watch-toggle-pip (session)
  "Toggle a draggable floating adaptive Picture-in-Picture player."
  (if (etaf-pip-active-p etaf-bili--pip-id)
      (progn
        (etaf-bili--pip-close session t)
        (etaf-bili--toast session "已关闭画中画" 'info))
    (if (not (display-graphic-p))
        (etaf-bili--toast session "终端模式不支持悬浮画中画，请用 A 键切换纯音频后台模式" 'info)
      (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session))))
        (let* ((pos (etaf-bili--session-watch-position session))
               (dur (etaf-bili--session-watch-duration session))
               (expired (and (plist-get src :bvid)
                             (etaf-bili--url-expired-p (plist-get src :url))))
               (pip-src (unless expired (plist-put (copy-sequence src) :start pos)))
               (pip-handle (make-symbol "etaf-bili-pip-video")))
          (etaf-bili--watch-exit-fullscreen session)
          (etaf-bili--bg-audio-stop session)
          ;; Unmount Watch's libmpv immediately before opening PiP.
          (setf (etaf-bili--session-pip-handle session) pip-handle
                (etaf-bili--session-pip-backup-index session) 0
                (etaf-bili--session-pip-refresh-tried session) nil
                (etaf-bili--session-pip-dm-loaded-ass session) nil
                (etaf-bili--session-pip-time-text session) (etaf-bili--clock pos)
                (etaf-bili--session-pip-duration-text session) (etaf-bili--clock dur)
                (etaf-bili--session-pip-subtitle-text session)
                (etaf-bili--session-watch-subtitle-text session))
          (etaf-batch
            (etaf-set-value (etaf-bili--session-pip-src-ref session) pip-src)
            (etaf-set-value (etaf-bili--session-pip-error-ref session) nil)
            (etaf-set-value (etaf-bili--session-pip-buffering-ref session) t)
            (etaf-set-value (etaf-bili--session-pip-playing-ref session) t)
            (etaf-set-value (etaf-bili--session-pip-cc-ref session)
                            (not (null (etaf-value (etaf-bili--session-watch-subtitle-index-ref session)))))
            (etaf-set-value (etaf-bili--session-pip-dm-ref session) nil)
            (etaf-set-value (etaf-bili--session-pip-progress-ref session)
                            (if (> dur 0) (max 0.0 (min 100.0 (* 100.0 (/ pos dur)))) 0.0))
            (etaf-set-value (etaf-bili--session-pip-active-ref session) t))
          (when-let* ((mbuf (etaf-bili--session-buffer session))
                      ((buffer-live-p mbuf))
                      (mrt (etaf-runtime-for-buffer mbuf)))
            (ignore-errors (etaf-runtime-flush mrt)))
          (etaf-pip-open
           etaf-bili--pip-id
           (etaf-view
            (etaf-bili--pip-view
             :session session
             :src-ref (etaf-bili--session-pip-src-ref session)
             :handle pip-handle))
           :title (lambda ()
                    (let ((s (etaf-value (etaf-bili--session-watch-source-ref session))))
                      (or (and s (plist-get s :title)) "画中画")))
           :size (or (etaf-value (etaf-bili--session-pip-size-ref session)) 'medium)
           :corner (or (etaf-value (etaf-bili--session-pip-corner-ref session)) 'bottom-right)
           :theme #'etaf-bili--pip-theme-colors
           :on-return (lambda () (etaf-bili--pip-return session))
           :on-close (lambda () (etaf-bili--pip-on-close session))
           :on-size-change (lambda (next)
                             (etaf-set-value (etaf-bili--session-pip-size-ref session) next)
                             (etaf-bili-store-pref-put "pip-size" (symbol-name next)))
           :on-corner-change (lambda (next)
                               (etaf-set-value (etaf-bili--session-pip-corner-ref session) next)
                               (etaf-bili-store-pref-put "pip-corner" (symbol-name next))))
          (when expired
            (etaf-bili--pip-refresh-stream session pos))
          (etaf-bili--watch-start-timer session)
          (etaf-bili--toast session "画中画已开启（拖标题栏移动 · 拖边框自由缩放 · ↩ 主）" 'info))))))

(defun etaf-bili--watch-stop-timer (session)
  "Cancel SESSION's 250ms watch HUD timer."
  (when-let* ((tm (etaf-bili--session-watch-timer session)))
    (cancel-timer tm)
    (setf (etaf-bili--session-watch-timer session) nil)))

(defun etaf-bili--watch-start-timer (session)
  "Start SESSION's 200ms Retained Host HUD timer."
  (etaf-bili--watch-stop-timer session)
  (setf (etaf-bili--session-watch-timer session)
        (run-at-time 0.2 0.2 #'etaf-bili--watch-tick session)))

(defun etaf-bili--pip-publish-hud (session pos dur)
  "Push Retained Host updates to SESSION's active PiP buffer."
  (when-let* ((pbuf (etaf-pip-buffer etaf-bili--pip-id))
              ((buffer-live-p pbuf))
              (prt (etaf-runtime-for-buffer pbuf))
              ((etaf-runtime-mounted-p prt)))
    (let* ((bounds (etaf-pip-bounds etaf-bili--pip-id))
           (cols (or (plist-get bounds :cols) 58))
           (full-time (>= cols 52))
           (show-time (>= cols 30))
           (t-str (etaf-bili--clock pos))
           (d-str (etaf-bili--clock dur))
           (disp-time (cond (full-time (format "%s / %s" t-str d-str))
                            (show-time t-str)
                            (t "")))
           (prev-t (etaf-bili--session-pip-time-text session))
           (prev-d (etaf-bili--session-pip-duration-text session))
           (prev-disp (cond (full-time (format "%s / %s" prev-t prev-d))
                            (show-time prev-t)
                            (t "")))
           (cues (etaf-bili--session-watch-subtitle-cues session))
           (sub-line (let ((cue (etaf-bili-subtitle-at cues pos)))
                       (if cue (concat "CC  " cue) "")))
           (prev-sub (etaf-bili--session-pip-subtitle-text session))
           (pct (if (> dur 0) (max 0.0 (min 100.0 (* 100.0 (/ pos dur)))) 0.0))
           (updates nil))
      (setf (etaf-bili--session-pip-time-text session) t-str
            (etaf-bili--session-pip-duration-text session) d-str
            (etaf-bili--session-pip-subtitle-text session) sub-line)
      (when (and (not (etaf-value (etaf-bili--session-pip-buffering-ref session)))
                 (not (equal disp-time prev-disp))
                 (etaf-runtime-host-props-for prt etaf-bili--pip-time-ref))
        (push (cons etaf-bili--pip-time-ref disp-time) updates))
      (when (and (not (equal sub-line prev-sub))
                 (etaf-runtime-host-props-for prt etaf-bili--pip-subtitle-ref))
        (push (cons etaf-bili--pip-subtitle-ref sub-line) updates))
      (when updates
        (ignore-errors (etaf-runtime-update-host-contents prt updates)))
      (let ((cur-pct (etaf-value (etaf-bili--session-pip-progress-ref session))))
        (when (or (not (numberp cur-pct))
                  (>= (abs (- pct cur-pct)) 0.2)
                  (and (= pct 0.0) (/= cur-pct 0.0))
                  (and (= pct 100.0) (/= cur-pct 100.0)))
          (etaf-set-value (etaf-bili--session-pip-progress-ref session) pct))))))

(defun etaf-bili--watch-tick (session)
  "Update Watch/PiP clock, progress, subtitle, and native libass danmaku."
  (if (etaf-bili--session-disposed session)
      (etaf-bili--watch-stop-timer session)
    (let* ((buffer (etaf-bili--session-buffer session))
           (runtime (and buffer (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
           (in-watch (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch))
           (audio-only (etaf-value (etaf-bili--session-watch-audio-only-ref session)))
           (pip-live (and (etaf-pip-active-p etaf-bili--pip-id)
                          (etaf-bili--session-pip-handle session)))
           (handle (etaf-bili--session-watch-handle session))
           (src (etaf-value (etaf-bili--session-watch-source-ref session))))
      (cond
       ;; Clean up if user closed PiP child frame externally.
       ((and (etaf-value (etaf-bili--session-pip-active-ref session))
             (not pip-live))
        (etaf-bili--pip-close session))
       (pip-live
        (when-let* ((ph (etaf-bili--session-pip-handle session))
                    (state (ignore-errors (etaf-video-state ph))))
          (let* ((pos (float (or (plist-get state :position) 0.0)))
                 (dur (float (or (plist-get state :duration)
                                 (and src (plist-get src :duration)) 0.0)))
                 (playing (and (plist-get state :playing) t))
                 (presented (or (plist-get state :presented) 0))
                 (buffering (or (and (plist-get state :buffering) t)
                                (and playing (= presented 0))))
                 (err (plist-get state :error))
                 (ended (and (plist-get state :ended) t)))
            (setf (etaf-bili--session-watch-position session) pos
                  (etaf-bili--session-watch-duration session) dur)
            (unless (eq playing (etaf-value (etaf-bili--session-pip-playing-ref session)))
              (etaf-set-value (etaf-bili--session-pip-playing-ref session) playing))
            (unless (eq playing (etaf-value (etaf-bili--session-watch-playing-ref session)))
              (etaf-set-value (etaf-bili--session-watch-playing-ref session) playing))
            (unless (eq buffering (etaf-value (etaf-bili--session-pip-buffering-ref session)))
              (etaf-set-value (etaf-bili--session-pip-buffering-ref session) buffering))
            (when (and err (null (etaf-value (etaf-bili--session-pip-error-ref session))))
              (etaf-bili--pip-failover-or-refresh session err))
            (etaf-bili--watch-dm-sync-handle
             session ph (etaf-value (etaf-bili--session-pip-dm-ref session)) nil t)
            (etaf-bili--pip-publish-hud session pos dur)
            (etaf-bili--watch-publish-hud session runtime in-watch pos dur buffering err)
            (when (and playing (> pos 5.0) (zerop (mod (floor pos) 5)))
              (etaf-bili--save-progress session t))
            (if (and ended (not err))
                (unless (etaf-bili--session-watch-ended-seen session)
                  (setf (etaf-bili--session-watch-ended-seen session) t)
                  (etaf-bili--save-progress session t)
                  (cond
                   ((eq (etaf-value (etaf-bili--session-watch-loop-ref session)) 'one)
                    (etaf-bili--pip-seek session 0.0)
                    (ignore-errors (etaf-video-play ph)))
                   ((etaf-value (etaf-bili--session-watch-auto-next-ref session))
                    (etaf-bili--watch-step-episode session 1 t))))
              (setf (etaf-bili--session-watch-ended-seen session) nil)))))
       (audio-only
        (when-let* ((proc (etaf-bili--session-audio-bg-process session)))
          (when (process-live-p proc)
            (let* ((spd (or (etaf-value (etaf-bili--session-watch-speed-ref session)) 1))
                   (dur (or (etaf-bili--session-watch-duration session) 0.0))
                   (pos (+ (etaf-bili--session-audio-bg-base session)
                           (* (- (float-time) (etaf-bili--session-audio-bg-stamp session)) spd)))
                   (clamped (if (> dur 0) (min pos dur) pos)))
              (setf (etaf-bili--session-watch-position session) clamped)
              (etaf-bili--watch-publish-hud session runtime in-watch clamped dur nil nil)))))
       ((and in-watch src)
        (when-let* ((state (ignore-errors (etaf-video-state handle))))
          (let* ((pos (float (or (plist-get state :position) 0.0)))
                 (dur (float (or (plist-get state :duration)
                                 (plist-get src :duration) 0.0)))
                 (playing (and (plist-get state :playing) t))
                 (buffering (and (plist-get state :buffering) t))
                 (err (plist-get state :error))
                 (ended (and (plist-get state :ended) t)))
            (setf (etaf-bili--session-watch-position session) pos
                  (etaf-bili--session-watch-duration session) dur)
            (unless (eq playing (etaf-value (etaf-bili--session-watch-playing-ref session)))
              (etaf-set-value (etaf-bili--session-watch-playing-ref session) playing))
            (unless (eq buffering (etaf-value (etaf-bili--session-watch-buffering-ref session)))
              (etaf-set-value (etaf-bili--session-watch-buffering-ref session) buffering))
            ;; Attach & sync native libass danmaku track lazily once video & XML are ready.
            (when (and (etaf-value (etaf-bili--session-watch-danmaku-list-ref session))
                       (not (and (consp (etaf-bili--session-watch-dm-loaded-ass session))
                                 (eq (car (etaf-bili--session-watch-dm-loaded-ass session)) handle))))
              (etaf-bili--watch-dm-sync-handle
               session handle
               (etaf-value (etaf-bili--session-watch-danmaku-enabled-ref session))
               nil nil))
            ;; Auto-failover on decoder error if backup CDN URL exists.
            (when (and err (null (etaf-value (etaf-bili--session-watch-play-error-ref session))))
              (let ((backups (plist-get src :backup-urls))
                    (bidx (etaf-bili--session-watch-backup-index session)))
                (if (< bidx (length backups))
                    (etaf-bili--watch-failover-cdn session t)
                  (etaf-set-value (etaf-bili--session-watch-play-error-ref session) err))))
            (etaf-bili--watch-publish-hud session runtime t pos dur buffering err)
            ;; Persist progress periodically while playing.
            (when (and playing (> pos 5.0)
                       (zerop (mod (floor pos) 5)))
              (etaf-bili--save-progress session t))
            ;; Handle natural end of video.
            (if (and ended (not err))
                (unless (etaf-bili--session-watch-ended-seen session)
                  (setf (etaf-bili--session-watch-ended-seen session) t)
                  (etaf-bili--save-progress session t)
                  (etaf-bili--watch-handle-ended session))
              (setf (etaf-bili--session-watch-ended-seen session) nil)))))))))

(defun etaf-bili--sync-activity (session pos dur)
  "Publish SESSION's active video or audio playback to ETAF Live Activity."
  (let* ((src (etaf-value (etaf-bili--session-watch-source-ref session)))
         (in-watch (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch))
         (pip-on (and (etaf-value (etaf-bili--session-pip-active-ref session)) t))
         (audio-only (and (etaf-value (etaf-bili--session-watch-audio-only-ref session)) t))
         (playing (and (etaf-value (etaf-bili--session-watch-playing-ref session)) t)))
    (if (not (and src (or in-watch audio-only pip-on)))
        (when (etaf-activity-get 'etaf-bili)
          (etaf-activity-remove 'etaf-bili))
      (let* ((raw-sec (max 0 (floor (or pos 0.0))))
             ;; Quantize to 2s buckets during active video playback so floating
             ;; shells (e.g. etaf-island) do not refit their posframe every second.
             (sec (if (and (or in-watch pip-on) (not audio-only) playing)
                      (* 2 (/ raw-sec 2))
                    raw-sec))
             (max-sec (max 1 (floor (or dur 0.0))))
             (state (if (or playing audio-only) 'active 'paused))
             (title (or (plist-get src :title) "哔哩哔哩"))
             (existing (etaf-activity-get 'etaf-bili))
             (existing-prog (and existing (plist-get existing :progress))))
        (unless (and existing
                     (eq (plist-get existing :state) state)
                     (equal (plist-get existing :title) title)
                     (equal (plist-get existing-prog :value) sec)
                     (equal (plist-get existing-prog :max) max-sec))
          (let* ((author (string-trim (or (plist-get src :author) "")))
                 (sub-parts (delq nil
                                  (list (unless (string-empty-p author) author)
                                        (cond (audio-only "后台音频")
                                              (pip-on "画中画"))
                                        (format "%s / %s"
                                                (etaf-bili--clock sec)
                                                (etaf-bili--clock max-sec))))))
            (etaf-activity-publish
             'etaf-bili
             (list
              :app 'etaf-bili
              :kind 'media
              :priority 82
              :state state
              :icon (if (eq state 'active) "▶" "⏸")
              :title title
              :subtitle (mapconcat #'identity sub-parts " · ")
              :compact title
              :progress (list :value sec :max max-sec :unit 'seconds)
              :open (lambda ()
                      (when (fboundp 'etaf-bili-open)
                        (etaf-bili-open)))
              :actions
              (list (list :id 'toggle :label (if (eq state 'active) "⏸" "▶")
                          :fn (lambda () (etaf-bili--watch-toggle session)))
                    (list :id 'stop :label "停止"
                          :fn (lambda () (etaf-bili--stop-all-playback session))))))))))))

(defun etaf-bili--watch-publish-hud (session runtime in-watch pos dur buffering _err)
  "Push Retained Host leaf updates for clock, subtitle, status and progress."
  (let* ((time-txt (etaf-bili--clock pos))
         (dur-txt (etaf-bili--clock dur))
         (cues (etaf-bili--session-watch-subtitle-cues session))
         (sub-line (let ((cue (etaf-bili-subtitle-at cues pos)))
                     (if cue (concat "CC  " cue) "")))
         (status-txt (if buffering "··· 缓冲中" ""))
         (pct (if (> dur 0) (max 0.0 (min 100.0 (* 100.0 (/ pos dur)))) 0.0))
         (prev-time (etaf-bili--session-watch-time-text session))
         (prev-dur (etaf-bili--session-watch-duration-text session))
         (prev-sub (etaf-bili--session-watch-subtitle-text session))
         (prev-status (etaf-bili--session-watch-status-text session)))
    (setf (etaf-bili--session-watch-time-text session) time-txt
          (etaf-bili--session-watch-duration-text session) dur-txt
          (etaf-bili--session-watch-subtitle-text session) sub-line
          (etaf-bili--session-watch-status-text session) status-txt)
    (etaf-bili--sync-activity session pos dur)
    (when (and in-watch runtime (etaf-runtime-mounted-p runtime))
      (let* ((updates nil)
             (layout (etaf-value (etaf-bili--session-layout-ref session)))
             (cw (max 1 (or (plist-get layout :cell-width) 8)))
             (cols (max 24 (floor (or (plist-get layout :width) 960) cw)))
             (cinema-time (cond ((>= cols 52) (format "%s / %s" time-txt dur-txt))
                                ((>= cols 30) time-txt)
                                (t "")))
             (prev-cinema (cond ((>= cols 52) (format "%s / %s" prev-time prev-dur))
                                ((>= cols 30) prev-time)
                                (t ""))))
        (dolist (entry (list (list etaf-bili--watch-time-ref time-txt prev-time)
                             (list etaf-bili--watch-duration-ref dur-txt prev-dur)
                             (list etaf-bili--watch-subtitle-ref sub-line prev-sub)
                             (list etaf-bili--watch-status-ref status-txt prev-status)))
          (when (and (not (equal (nth 1 entry) (nth 2 entry)))
                     (etaf-runtime-host-props-for runtime (car entry)))
            (push (cons (car entry) (nth 1 entry)) updates)))
        (when (and (not buffering)
                   (not (equal cinema-time prev-cinema))
                   (etaf-runtime-host-props-for runtime etaf-bili--watch-cinema-time-ref))
          (push (cons etaf-bili--watch-cinema-time-ref cinema-time) updates))
        (when updates
          (ignore-errors (etaf-runtime-update-host-contents runtime updates))))
      (let ((cur-pct (etaf-value (etaf-bili--session-watch-progress-ref session))))
        (when (or (not (numberp cur-pct))
                  (>= (abs (- pct cur-pct)) 0.15)
                  (and (= pct 0.0) (/= cur-pct 0.0))
                  (and (= pct 100.0) (/= cur-pct 100.0)))
          (etaf-set-value (etaf-bili--session-watch-progress-ref session) pct))))))

(defun etaf-bili--watch-handle-ended (session)
  "Handle natural video completion: loop one or advance to next part/video."
  (cond
   ((eq (etaf-value (etaf-bili--session-watch-loop-ref session)) 'one)
    (etaf-bili--watch-seek session 0.0)
    (ignore-errors (etaf-video-play (etaf-bili--session-watch-handle session))))
   ((etaf-value (etaf-bili--session-watch-auto-next-ref session))
    (etaf-bili--watch-step-episode session 1 t))))

(defun etaf-bili--start-playback (session source &optional explicit-start)
  "Open Watch View (or switch in-place inside active PiP) for SOURCE."
  (unless (etaf-bili--session-disposed session)
    (etaf-bili--bg-audio-stop session)
    (let* ((in-pip (etaf-pip-active-p etaf-bili--pip-id))
           (bvid (plist-get source :bvid))
           (cid (plist-get source :cid))
           (dur (float (or (plist-get source :duration) 0.0)))
           (start (if (numberp explicit-start)
                      (max 0.0 (float explicit-start))
                    (etaf-bili-store-resume-seconds bvid cid 0.0 dur)))
           (prepared (if (> start 0.0)
                         (plist-put (copy-sequence source) :start start)
                       source))
           (value (list :source prepared :title (plist-get prepared :title))))
      (etaf-bili--watch-dm-cleanup session)
      (setf (etaf-bili--session-playback session) value
            (etaf-bili--session-watch-position session) start
            (etaf-bili--session-watch-duration session) dur
            (etaf-bili--session-watch-backup-index session) 0
            (etaf-bili--session-watch-ended-seen session) nil
            (etaf-bili--session-watch-time-text session) (etaf-bili--clock start)
            (etaf-bili--session-watch-duration-text session) (etaf-bili--clock dur)
            (etaf-bili--session-watch-subtitle-text session) ""
            (etaf-bili--session-watch-danmaku-text session) ""
            (etaf-bili--session-watch-status-text session) (if (> start 5.0)
                                                               (format "已续播 %s" (etaf-bili--clock start))
                                                             ""))
      (when in-pip
        (setf (etaf-bili--session-pip-backup-index session) 0
              (etaf-bili--session-pip-refresh-tried session) nil
              (etaf-bili--session-pip-dm-loaded-ass session) nil
              (etaf-bili--session-pip-time-text session) (etaf-bili--clock start)
              (etaf-bili--session-pip-duration-text session) (etaf-bili--clock dur)
              (etaf-bili--session-pip-subtitle-text session) ""))
      (etaf-batch
        (etaf-set-value (etaf-bili--session-playback-ref session) value)
        (etaf-set-value (etaf-bili--session-watch-source-ref session) prepared)
        (etaf-set-value (etaf-bili--session-watch-audio-only-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-play-error-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-playing-ref session) t)
        (etaf-set-value (etaf-bili--session-watch-liked-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-coined-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-faved-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-toviewed-ref session) nil)
        (etaf-set-value (etaf-bili--session-watch-progress-ref session)
                        (if (> dur 0) (* 100.0 (/ start dur)) 0.0))
        (if in-pip
            (progn
              (etaf-set-value (etaf-bili--session-pip-error-ref session) nil)
              (etaf-set-value (etaf-bili--session-pip-buffering-ref session) t)
              (etaf-set-value (etaf-bili--session-pip-playing-ref session) t)
              (etaf-set-value (etaf-bili--session-pip-progress-ref session)
                              (if (> dur 0) (* 100.0 (/ start dur)) 0.0))
              (etaf-set-value (etaf-bili--session-pip-src-ref session) prepared))
          (etaf-set-value (etaf-bili--session-view-mode-ref session) 'watch)))
      (when in-pip
        (etaf-pip-refresh-chrome etaf-bili--pip-id))
      (etaf-bili--watch-start-timer session)
      (etaf-bili--sync-activity session start dur)
      ;; Load subtitles, chapters, danmaku, comments, related and cloud resume asynchronously.
      (etaf-bili--load-watch-companions
       session prepared
       (lambda (cloud-sec)
         ;; If user hasn't manually moved far and cloud progress is further ahead, offer/seek.
         (when (and (null explicit-start)
                    (< start 5.0)
                    (< (etaf-bili--session-watch-position session) 8.0)
                    (> cloud-sec 10.0)
                    (or (<= dur 0) (< cloud-sec (- dur 12.0))))
           (etaf-bili--watch-seek session cloud-sec)
           (etaf-bili--toast session
                             (format "已同步云端续播至 %s" (etaf-bili--clock cloud-sec))
                             'info)))))))

(defun etaf-bili--play-selected-into-watch (session)
  "Resolve SESSION's selected gallery video and open Watch View."
  (etaf-bili-play-selected session (lambda (source) (etaf-bili--start-playback session source))))

(defun etaf-bili--watch-open-target (session target &optional start-sec cid)
  "Resolve TARGET plist (`:bvid' or `:aid') and open Watch View."
  (etaf-bili-play-target
   session target
   (lambda (source) (etaf-bili--start-playback session source start-sec))
   cid))

(defun etaf-bili--watch-open-bvid (session bvid &optional cid start-sec)
  "Open BVID (optional CID and START-SEC) in SESSION's Watch View."
  (etaf-bili--save-progress session t)
  (etaf-bili--watch-open-target session (list :bvid bvid) start-sec cid))

(defun etaf-bili--watch-leave (session)
  "Return from Watch View to Gallery View.
If Audio-only mode or floating PiP is active, keep playback running!"
  (etaf-bili--watch-exit-fullscreen session)
  (etaf-bili--save-progress session t)
  (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) nil)
  (etaf-set-value (etaf-bili--session-watch-drawer-ref session) nil)
  (if (or (etaf-value (etaf-bili--session-watch-audio-only-ref session))
          (etaf-value (etaf-bili--session-pip-active-ref session)))
      (etaf-set-value (etaf-bili--session-view-mode-ref session) 'gallery)
    (etaf-bili--stop-playback session)))

(defun etaf-bili--return-to-watch (session)
  "Re-enter Watch View for SESSION's current video."
  (if (etaf-value (etaf-bili--session-watch-source-ref session))
      (etaf-set-value (etaf-bili--session-view-mode-ref session) 'watch)
    (etaf-bili--toast session "当前没有正在播放的视频" 'info)))

(defun etaf-bili--stop-playback (session)
  "Stop Watch View playback and return to the Gallery."
  (cl-incf (etaf-bili--session-play-request session))
  (etaf-bili--watch-exit-fullscreen session)
  (etaf-bili--save-progress session t)
  (etaf-bili--watch-stop-timer session)
  (etaf-bili--bg-audio-stop session)
  (etaf-bili--pip-close session)
  (etaf-bili--watch-dm-cleanup session)
  (when (etaf-activity-get 'etaf-bili)
    (etaf-activity-remove 'etaf-bili))
  (setf (etaf-bili--session-playback session) nil)
  (etaf-batch
    (etaf-set-value (etaf-bili--session-playback-ref session) nil)
    (etaf-set-value (etaf-bili--session-watch-playing-ref session) nil)
    (etaf-set-value (etaf-bili--session-watch-audio-only-ref session) nil)
    (etaf-set-value (etaf-bili--session-view-mode-ref session) 'gallery)))

(defun etaf-bili--stop-all-playback (session)
  "Stop playback completely and clear the persistent mini-player."
  (etaf-bili--stop-playback session)
  (etaf-set-value (etaf-bili--session-watch-source-ref session) nil))

;;; Watch Controls & Actions

(defun etaf-bili--watch-direction (session dir)
  "Handle arrow keys in Watch View: Left/Right seek ±5s, Up/Down adjust volume."
  (pcase dir
    ('left (etaf-bili--watch-seek-by session -5) 'handled)
    ('right (etaf-bili--watch-seek-by session 5) 'handled)
    ('up (etaf-bili--watch-volume-delta session 10) 'handled)
    ('down (etaf-bili--watch-volume-delta session -10) 'handled)
    (_ 'release)))

(defun etaf-bili--watch-toggle (session)
  "Toggle play/pause in Watch View or active PiP."
  (cond
   ((etaf-value (etaf-bili--session-watch-audio-only-ref session))
    (etaf-bili--bg-audio-toggle session))
   ((etaf-bili--session-pip-handle session)
    (etaf-bili--pip-toggle-play session))
   (t
    (ignore-errors (etaf-video-toggle-playback (etaf-bili--session-watch-handle session)))
    (etaf-bili--watch-tick session))))

(defun etaf-bili--watch-seek (session seconds)
  "Seek active Watch or PiP playback to SECONDS."
  (let* ((dur (etaf-bili--session-watch-duration session))
         (target (max 0.0 (if (> dur 0) (min (float seconds) dur) (float seconds)))))
    (setf (etaf-bili--session-watch-position session) target)
    (cond
     ((etaf-value (etaf-bili--session-watch-audio-only-ref session))
      (when (etaf-bili--session-audio-bg-process session)
        (etaf-bili--bg-audio-start session target)))
     ((etaf-bili--session-pip-handle session)
      (ignore-errors (etaf-video-seek (etaf-bili--session-pip-handle session) target)))
     (t
      (ignore-errors (etaf-video-seek (etaf-bili--session-watch-handle session) target))))
    (etaf-bili--save-progress session)
    (let ((buf (etaf-bili--session-buffer session)))
      (etaf-bili--watch-publish-hud
       session (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf))
       (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch)
       target dur nil nil))))

(defun etaf-bili--watch-seek-by (session delta)
  "Seek active Watch playback by DELTA seconds."
  (etaf-bili--watch-seek session (+ (etaf-bili--session-watch-position session) delta)))

(defun etaf-bili--watch-toggle-audio (session)
  "Mute or unmute Watch audio and persist preference."
  (let ((next (not (etaf-value (etaf-bili--session-watch-audio-ref session)))))
    (etaf-set-value (etaf-bili--session-watch-audio-ref session) next)
    (etaf-bili-store-pref-put "audio" next)
    (when (etaf-value (etaf-bili--session-watch-audio-only-ref session))
      (when (etaf-bili--session-audio-bg-process session)
        (etaf-bili--bg-audio-start session (etaf-bili--session-watch-position session))))))

(defun etaf-bili--watch-volume-delta (session delta)
  "Adjust Watch volume by DELTA (clamped 0..100) and persist preference."
  (let ((next (max 0 (min 100 (+ (etaf-value (etaf-bili--session-watch-volume-ref session)) delta)))))
    (etaf-set-value (etaf-bili--session-watch-volume-ref session) next)
    (when (and (> next 0) (not (etaf-value (etaf-bili--session-watch-audio-ref session))))
      (etaf-set-value (etaf-bili--session-watch-audio-ref session) t)
      (etaf-bili-store-pref-put "audio" t))
    (etaf-bili-store-pref-put "volume" next)
    (when (and (etaf-value (etaf-bili--session-watch-audio-only-ref session))
               (etaf-bili--session-audio-bg-process session))
      (etaf-bili--bg-audio-start session (etaf-bili--session-watch-position session)))
    (etaf-bili--toast session (format "音量：%d%%" next) 'info)))

(defun etaf-bili--watch-set-speed (session speed)
  "Set Watch playback speed to SPEED and persist preference."
  (etaf-set-value (etaf-bili--session-watch-speed-ref session) speed)
  (etaf-bili-store-pref-put "speed" speed)
  (when (and (etaf-value (etaf-bili--session-watch-audio-only-ref session))
             (etaf-bili--session-audio-bg-process session))
    (etaf-bili--bg-audio-start session (etaf-bili--session-watch-position session)))
  (etaf-bili--toast session (format "倍速：%gx" speed) 'info))

(defun etaf-bili--watch-cycle-speed (session)
  "Cycle Watch playback speed through `etaf-bili--speeds'."
  (let* ((cur (etaf-value (etaf-bili--session-watch-speed-ref session)))
         (next (or (cadr (member cur etaf-bili--speeds)) (car etaf-bili--speeds))))
    (etaf-bili--watch-set-speed session next)))

(defun etaf-bili--watch-step-speed (session delta)
  "Step Watch playback speed up (+1) or down (-1)."
  (let* ((cur (etaf-value (etaf-bili--session-watch-speed-ref session)))
         (idx (or (cl-position cur etaf-bili--speeds) 2))
         (next (nth (max 0 (min (1- (length etaf-bili--speeds)) (+ idx delta)))
                    etaf-bili--speeds)))
    (etaf-bili--watch-set-speed session next)))

(defun etaf-bili--watch-toggle-quality-menu (session)
  "Toggle the quality picker dialog in Watch View."
  (let ((next (not (etaf-value (etaf-bili--session-watch-quality-menu-ref session)))))
    (when next
      (let* ((src (etaf-value (etaf-bili--session-watch-source-ref session)))
             (streams (and src (plist-get src :streams)))
             (cur-qid (and src (plist-get src :quality-id)))
             (idx (or (and streams
                           (cl-position cur-qid streams
                                        :key (lambda (s) (plist-get s :id))
                                        :test #'equal))
                      0)))
        (etaf-set-value (etaf-bili--session-watch-quality-cursor-ref session) idx)))
    (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) next)))

(defun etaf-bili--watch-switch-quality (session stream)
  "Switch active Watch video to STREAM plist at the exact current second."
  (when-let* ((cur (etaf-value (etaf-bili--session-watch-source-ref session)))
              (url (plist-get stream :url)))
    (if (equal (plist-get stream :id) (plist-get cur :quality-id))
        (progn
          (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) nil)
          (etaf-bili--toast session
                            (format "当前已是 %s" (or (plist-get stream :label) "该画质"))
                            'info))
      (let* ((pos (etaf-bili--session-watch-position session))
             (updated (copy-sequence cur)))
        (setq updated (plist-put updated :url url))
        (setq updated (plist-put updated :start pos))
        (setq updated (plist-put updated :quality-id (plist-get stream :id)))
        (setq updated (plist-put updated :quality-label (plist-get stream :label)))
        (setq updated (plist-put updated :codec-label (plist-get stream :codec-label)))
        (setq updated (plist-put updated :backup-urls (plist-get stream :backup-urls)))
        (when (plist-get stream :width)
          (setq updated (plist-put updated :width (plist-get stream :width))))
        (when (plist-get stream :height)
          (setq updated (plist-put updated :height (plist-get stream :height))))
        (when (plist-get stream :fps)
          (setq updated (plist-put updated :fps (plist-get stream :fps))))
        (etaf-bili-store-pref-put "quality" (plist-get stream :id))
        (setf (etaf-bili--session-watch-backup-index session) 0
              (etaf-bili--session-watch-dm-loaded-ass session) nil)
        (etaf-batch
          (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) nil)
          (etaf-set-value (etaf-bili--session-watch-play-error-ref session) nil)
          (etaf-set-value (etaf-bili--session-watch-source-ref session) updated))
        (etaf-bili--toast session
                          (format "已切换至 %s %s（从 %s 续播）"
                                  (plist-get stream :label)
                                  (or (plist-get stream :codec-label) "")
                                  (etaf-bili--clock pos))
                          'info)))))

(defun etaf-bili--watch-failover-cdn (session &optional auto)
  "Switch active Watch source to its next backup CDN URL at current position."
  (when-let* ((cur (etaf-value (etaf-bili--session-watch-source-ref session))))
    (let* ((backups (plist-get cur :backup-urls))
           (audio-backups (plist-get cur :audio-backup-urls))
           (idx (etaf-bili--session-watch-backup-index session)))
      (if (< idx (length backups))
          (let* ((pos (etaf-bili--session-watch-position session))
                 (updated (copy-sequence cur)))
            (setf (etaf-bili--session-watch-backup-index session) (1+ idx)
                  (etaf-bili--session-watch-dm-loaded-ass session) nil)
            (setq updated (plist-put updated :url (nth idx backups)))
            (setq updated (plist-put updated :start pos))
            (when (and audio-backups (< idx (length audio-backups)))
              (setq updated (plist-put updated :audio-url (nth idx audio-backups))))
            (etaf-batch
              (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) nil)
              (etaf-set-value (etaf-bili--session-watch-play-error-ref session) nil)
              (etaf-set-value (etaf-bili--session-watch-source-ref session) updated))
            (etaf-bili--toast session
                              (if auto "主线路异常，已自动切换备用线路"
                                (format "已切换备用 CDN 线路 #%d" (1+ idx)))
                              'info))
        (etaf-bili--toast session "没有更多备用线路，正在重新获取地址…" 'info)
        (etaf-bili--watch-retry session)))))

(defun etaf-bili--watch-retry (session)
  "Re-resolve current video stream fresh (bypassing cache) and resume."
  (when-let* ((cur (etaf-value (etaf-bili--session-watch-source-ref session))))
    (let ((pos (etaf-bili--session-watch-position session)))
      (etaf-bili-play-target
       session (list :bvid (plist-get cur :bvid))
       (lambda (source) (etaf-bili--start-playback session source pos))
       (plist-get cur :cid) (plist-get cur :quality-id) t))))

(defun etaf-bili--watch-select-subtitle (session index)
  "Select subtitle track INDEX (or nil to disable) and persist preference."
  (etaf-bili-store-pref-put "subtitle" (not (null index)))
  (etaf-bili--select-subtitle-track session index))

(defun etaf-bili--watch-cycle-subtitle (session)
  "Cycle through available subtitle tracks (and off)."
  (let* ((tracks (etaf-value (etaf-bili--session-watch-subtitles-list-ref session)))
         (cur (etaf-value (etaf-bili--session-watch-subtitle-index-ref session))))
    (if (null tracks)
        (etaf-bili--toast session "当前视频没有可用的 CC / AI 字幕" 'info)
      (let ((next (cond ((null cur) 0)
                        ((< (1+ cur) (length tracks)) (1+ cur))
                        (t nil))))
        (etaf-bili--watch-select-subtitle session next)
        (etaf-bili--toast session
                          (if next
                              (format "字幕：%s" (plist-get (nth next tracks) :label))
                            "字幕：已关闭")
                          'info)))))

(defun etaf-bili--watch-toggle-danmaku (session)
  "Toggle native libass danmaku overlay without shifting video layout."
  (let ((next (not (etaf-value (etaf-bili--session-watch-danmaku-enabled-ref session)))))
    (etaf-set-value (etaf-bili--session-watch-danmaku-enabled-ref session) next)
    (etaf-bili-store-pref-put "danmaku" next)
    (etaf-bili--watch-dm-sync-handle
     session (etaf-bili--session-watch-handle session) next nil nil)
    (etaf-bili--toast session (if next "弹幕：开启" "弹幕：关闭") 'info)))

(defun etaf-bili--watch-set-dm-setting (session key value)
  "Update danmaku display setting KEY to VALUE and hot-reload ASS track."
  (pcase key
    (:area
     (etaf-set-value (etaf-bili--session-watch-dm-area-ref session) value)
     (etaf-bili-store-pref-put "dm-area" (symbol-name value)))
    (:opacity
     (etaf-set-value (etaf-bili--session-watch-dm-opacity-ref session) value)
     (etaf-bili-store-pref-put "dm-opacity" value))
    (:font-size
     (etaf-set-value (etaf-bili--session-watch-dm-size-ref session) value)
     (etaf-bili-store-pref-put "dm-size" (symbol-name value)))
    (:density
     (etaf-set-value (etaf-bili--session-watch-dm-density-ref session) value)
     (etaf-bili-store-pref-put "dm-density" (symbol-name value)))
    (:show-scroll
     (etaf-set-value (etaf-bili--session-watch-dm-scroll-ref session) (and value t))
     (etaf-bili-store-pref-put "dm-scroll" (and value t)))
    (:show-top
     (etaf-set-value (etaf-bili--session-watch-dm-top-ref session) (and value t))
     (etaf-bili-store-pref-put "dm-top" (and value t)))
    (:show-bottom
     (etaf-set-value (etaf-bili--session-watch-dm-bottom-ref session) (and value t))
     (etaf-bili-store-pref-put "dm-bottom" (and value t))))
  (etaf-bili--watch-dm-sync-handle
   session (etaf-bili--session-watch-handle session)
   (etaf-value (etaf-bili--session-watch-danmaku-enabled-ref session)) t nil)
  (when-let* ((ph (etaf-bili--session-pip-handle session)))
    (etaf-bili--watch-dm-sync-handle
     session ph (etaf-value (etaf-bili--session-pip-dm-ref session)) t t)))

(defun etaf-bili--watch-exit-fullscreen (session)
  "Exit Pure Fullscreen for SESSION, restoring mode-line, splits and frame."
  (let ((buf (etaf-bili--session-buffer session)))
    (if (and buf (buffer-live-p buf))
        (progn
          (etaf-fullscreen-exit buf)
          (unless (null (etaf-value (etaf-bili--session-watch-fullscreen-ref session)))
            (etaf-batch
              (etaf-set-value (etaf-bili--session-watch-fullscreen-ref session) nil)
              (etaf-bili--sync-viewport session nil t))))
      (etaf-set-value (etaf-bili--session-watch-fullscreen-ref session) nil)))
  nil)

(defun etaf-bili--watch-toggle-fullscreen (session &optional mode)
  "Toggle SESSION's Pure Fullscreen MODE (`window' or `frame')."
  (let* ((target (or mode 'window))
         (buf (etaf-bili--session-buffer session)))
    (if (and buf (buffer-live-p buf))
        (etaf-fullscreen-toggle
         target buf :hide-mode-line t
         :on-change (lambda (m)
                      (unless (etaf-bili--session-disposed session)
                        (etaf-set-value (etaf-bili--session-watch-fullscreen-ref session) m)
                        (etaf-bili--sync-viewport session nil t))))
      (let* ((cur (etaf-value (etaf-bili--session-watch-fullscreen-ref session)))
             (res (if (eq cur target) nil target)))
        (etaf-set-value (etaf-bili--session-watch-fullscreen-ref session) res)
        res))))

(defun etaf-bili--watch-toggle-theater (session)
  "Toggle wide theater mode (hides/shows right side panel)."
  (if (etaf-value (etaf-bili--session-watch-fullscreen-ref session))
      (progn
        (etaf-bili--watch-exit-fullscreen session)
        (etaf-set-value (etaf-bili--session-watch-theater-ref session) t))
    (etaf-update-value (etaf-bili--session-watch-theater-ref session) #'not)))

(defun etaf-bili--watch-toggle-auto-next (session)
  "Toggle auto-advance to next part/video on end."
  (let ((next (not (etaf-value (etaf-bili--session-watch-auto-next-ref session)))))
    (etaf-set-value (etaf-bili--session-watch-auto-next-ref session) next)
    (etaf-bili-store-pref-put "auto-next" next)))

(defun etaf-bili--watch-toggle-audio-only (session)
  "Switch between full video playback and zero-CPU audio-only background mode."
  (let* ((cur (etaf-value (etaf-bili--session-watch-audio-only-ref session)))
         (next (not cur))
         (pos (etaf-bili--session-watch-position session)))
    (if next
        (progn
          (etaf-set-value (etaf-bili--session-watch-audio-only-ref session) t)
          (etaf-bili--bg-audio-start session pos)
          (etaf-bili--toast session "已进入纯音频模式（按 b 返回列表仍可继续听）" 'info))
      (etaf-bili--bg-audio-stop session)
      (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session))))
        (etaf-set-value (etaf-bili--session-watch-source-ref session)
                        (plist-put (copy-sequence src) :start pos)))
      (etaf-set-value (etaf-bili--session-watch-audio-only-ref session) nil)
      (etaf-bili--toast session "已恢复视频画面" 'info))))

(defun etaf-bili--watch-step-episode (session delta &optional from-end)
  "Move DELTA parts/episodes/videos forward or backward without looping self."
  (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session))))
    (let* ((bvid (plist-get src :bvid))
           (cid (plist-get src :cid))
           (pages (plist-get src :pages))
           (season (plist-get src :season))
           (p-idx (and (> (length pages) 1)
                       (cl-position cid pages :key (lambda (p) (plist-get p :cid)))))
           (s-idx (and (null p-idx) (> (length season) 1)
                       (cl-position bvid season :key (lambda (e) (plist-get e :bvid))))))
      (cond
       ;; 1. Multi-part next/prev
       ((and p-idx (<= 0 (+ p-idx delta) (1- (length pages))))
        (let ((next-p (nth (+ p-idx delta) pages)))
          (etaf-bili--watch-open-bvid session bvid (plist-get next-p :cid) 0.0)))
       ;; 2. Collection (ugc_season) next/prev
       ((and s-idx (<= 0 (+ s-idx delta) (1- (length season))))
        (let ((next-ep (nth (+ s-idx delta) season)))
          (etaf-bili--watch-open-bvid session (plist-get next-ep :bvid) (plist-get next-ep :cid) 0.0)))
       ;; 3. Gallery list next/prev (avoid replaying the same video at boundaries!)
       (t
        (let* ((count (length (etaf-bili--session-items session)))
               (cur-i (etaf-bili--session-selected session))
               (next-i (+ cur-i delta)))
          (cond
           ((and (> count 0) (<= 0 next-i (1- count)))
            (etaf-bili-move session delta)
            (etaf-bili--play-selected-into-watch session))
           ((and from-end (> delta 0)
                 (car (etaf-value (etaf-bili--session-watch-related-ref session))))
            (let ((rel (car (etaf-value (etaf-bili--session-watch-related-ref session)))))
              (etaf-bili--watch-open-bvid session (plist-get rel :bvid) nil 0.0)))
           (t
            (etaf-bili--toast session
                              (if (> delta 0) "已经是列表最后一个视频" "已经是列表第一个视频")
                              'info)))))))))

(defun etaf-bili--watch-action (session action)
  "Perform signed-in Bilibili ACTION (`:like', `:coin', `:fav', `:toview')."
  (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session))))
    (let ((client (etaf-bili--session-client session))
          (bvid (plist-get src :bvid))
          (aid (plist-get src :aid)))
      (pcase action
        (:like
         (etaf-bili-client-call
          client (list :op :like :bvid bvid :like 1)
          (lambda (reply)
            (if (plist-get reply :error)
                (etaf-bili--toast session (plist-get reply :error) 'error)
              (etaf-set-value (etaf-bili--session-watch-liked-ref session) t)
              (etaf-bili--toast session "点赞成功！" 'ok)))))
        (:coin
         (etaf-bili-client-call
          client (list :op :coin :bvid bvid :multiply 1)
          (lambda (reply)
            (if (plist-get reply :error)
                (etaf-bili--toast session (plist-get reply :error) 'error)
              (etaf-set-value (etaf-bili--session-watch-coined-ref session) t)
              (etaf-bili--toast session "投币成功！" 'ok)))))
        (:toview
         (etaf-bili-client-call
          client (list :op :toview-add :bvid bvid)
          (lambda (reply)
            (if (plist-get reply :error)
                (etaf-bili--toast session (plist-get reply :error) 'error)
              (etaf-set-value (etaf-bili--session-watch-toviewed-ref session) t)
              (etaf-bili--toast session "已加入稍后再看" 'ok)))))
        (:fav
         (let ((mid (etaf-bili--session-account-mid session)))
           (if (not (and (numberp mid) (> mid 0)))
               (etaf-bili--toast session "收藏需要先扫码登录" 'info)
             (etaf-bili-client-call
              client (list :op :fav-folders :mid mid)
              (lambda (reply)
                (if-let* ((first (car (plist-get reply :ok)))
                          (fid (plist-get first :id)))
                    (etaf-bili-client-call
                     client (list :op :fav-add :aid aid :folder-id fid)
                     (lambda (r2)
                       (if (plist-get r2 :error)
                           (etaf-bili--toast session (plist-get r2 :error) 'error)
                         (etaf-set-value (etaf-bili--session-watch-faved-ref session) t)
                         (etaf-bili--toast session
                                           (format "已收藏到「%s」" (plist-get first :title))
                                           'ok))))
                  (etaf-bili--toast session (or (plist-get reply :error) "未找到收藏夹") 'error)))))))))))

(defun etaf-bili--open-external (session)
  "Launch `etaf-bili-external-player' (e.g. mpv) at SESSION's current position."
  (when-let* ((src (etaf-value (etaf-bili--session-watch-source-ref session)))
              (url (plist-get src :url)))
    (let ((prog (executable-find etaf-bili-external-player)))
      (if (not prog)
          (etaf-bili--toast session
                            (format "未找到外部播放器：%s" etaf-bili-external-player)
                            'error)
        (let* ((pos (etaf-bili--session-watch-position session))
               (audio (plist-get src :audio-url))
               (title (or (plist-get src :title) (plist-get src :bvid) "Bilibili"))
               (dm-ass (when (etaf-value (etaf-bili--session-watch-danmaku-enabled-ref session))
                         (etaf-bili--watch-dm-compile session)))
               (args (append
                      (list (format "--referrer=%s" etaf-bili--referer)
                            (format "--user-agent=%s" etaf-bili--user-agent)
                            (format "--force-media-title=%s" title)
                            (format "--start=%.1f" (max 0.0 pos)))
                      (when audio (list (format "--audio-file=%s" audio)))
                      (when (and dm-ass (file-exists-p dm-ass))
                        (list (format "--sub-file=%s" dm-ass)))
                      (list url))))
          (ignore-errors (etaf-video-pause (etaf-bili--session-watch-handle session)))
          (etaf-bili--watch-exit-fullscreen session)
          (etaf-bili--bg-audio-stop session)
          (apply #'start-process "etaf-bili-external" nil prog args)
          (etaf-bili--toast session
                            (format "已在 %s 中从 %s 打开播放"
                                    (file-name-nondirectory prog)
                                    (etaf-bili--clock pos))
                            'info))))))

(defun etaf-bili--open-browser (session)
  "Open active video in system browser at the current part and timestamp."
  (when-let* ((src (or (etaf-value (etaf-bili--session-watch-source-ref session))
                       (etaf-bili-selected-row session)))
              (bvid (plist-get src :bvid)))
    (let* ((part (or (plist-get src :part-index) 1))
           (sec (max 0 (round (or (etaf-bili--session-watch-position session) 0))))
           (url (format "https://www.bilibili.com/video/%s?p=%d&t=%d" bvid part sec)))
      (browse-url url)
      (etaf-bili--toast session (format "已在浏览器打开 %s" bvid) 'info))))

;;; Mount & Unmount Lifecycle

(defun etaf-bili--mounted (session)
  "Adopt the buffer that mounted SESSION's View and start the client there."
  (when-let* ((runtime (etaf-current-runtime))
              (buffer (and runtime (etaf-runtime-buffer runtime))))
    (when (buffer-live-p buffer)
      (setf (etaf-bili--session-disposed session) nil
            (etaf-bili--session-buffer session) buffer
            (etaf-bili--session-on-change session)
            (lambda (reset) (etaf-bili--library-changed session reset)))
      (with-current-buffer buffer
        (setq-local etaf-bili--session session)
        (add-hook 'kill-buffer-hook (lambda () (etaf-bili--unmounted session)) nil t))
      (etaf-bili--sync-viewport session)
      (when (etaf-bili--session-loading session)
        (setf (etaf-bili--session-loading session) nil)
        (etaf-set-value (etaf-bili--session-loading-ref session) nil))
      (etaf-bili--account-query session t)
      (if (etaf-bili--session-items session)
          (unless (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch)
            (etaf-bili--prepare-covers session))
        (etaf-bili-load-popular session)))))

(defun etaf-bili--unmounted (session)
  "Release SESSION's host-buffer resources cleanly; a later mount revives it."
  (etaf-bili--save-progress session t)
  (setf (etaf-bili--session-disposed session) t
        (etaf-bili--session-on-change session) nil
        (etaf-bili--session-loading session) nil)
  (cl-incf (etaf-bili--session-request session))
  (cl-incf (etaf-bili--session-play-request session))
  (cl-incf (etaf-bili--session-watch-aux-request session))
  (etaf-bili--login-stop session)
  (etaf-bili--watch-stop-timer session)
  (etaf-bili--bg-audio-stop session)
  (etaf-bili--watch-exit-fullscreen session)
  (etaf-bili--pip-close session)
  (etaf-bili--watch-dm-cleanup session)
  (when-let* ((tm (etaf-bili--session-resize-timer session)))
    (cancel-timer tm)
    (setf (etaf-bili--session-resize-timer session) nil))
  (when-let* ((tm (etaf-bili--session-toast-timer session)))
    (cancel-timer tm)
    (setf (etaf-bili--session-toast-timer session) nil))
  (etaf-bili--cancel-covers session)
  (dolist (job (etaf-bili--session-jobs session))
    (ignore-errors (etaf-process-cancel job)))
  (setf (etaf-bili--session-jobs session) nil))

;;; Public Entry Points & Commands

;;;###autoload
(defun etaf-bili-create ()
  "Create a client session to mount through `etaf-bili-view'."
  (etaf-bili-session-create))

;;;###autoload
(defun etaf-bili-view (session)
  "Return SESSION's View for mounting in a host of your own."
  (etaf-view (etaf-bili--shell :session session)))

;;;###autoload
(defun etaf-bili-open (&optional fresh)
  "Open or focus the responsive Bilibili client buffer.
Preserves the user's Emacs mode-line (`:mode-line t').  When `*Bili*' is
already open, switch to it without interrupting playback unless FRESH."
  (interactive "P")
  (let ((existing (get-buffer etaf-bili--buffer-name)))
    (if (and existing (not fresh)
             (buffer-live-p existing)
             (etaf-runtime-for-buffer existing))
        (progn (switch-to-buffer existing) existing)
      (when existing (etaf-bili-close))
      (let* ((session (etaf-bili-create))
             (bg (etaf-computed
                  (lambda ()
                    (let ((mode (etaf-value etaf-bili--theme-mode-ref))
                          (view (etaf-value (etaf-bili--session-view-mode-ref session))))
                      ;; Match the Watch transport deck so sub-row fullscreen
                      ;; pixel remainders above the mode-line blend seamlessly.
                      (etaf-bili-color (if (eq view 'watch) :panel2 :bg) mode)))))
             (fg (etaf-computed (lambda ()
                                  (etaf-bili-color :ink (etaf-value etaf-bili--theme-mode-ref)))))
             (buffer
              (etaf-app-open
               etaf-bili--buffer-name
               (etaf-bili-view session)
               :state session
               :mode-line t
               :cursor nil
               :background bg
               :foreground fg
               :on-fit (lambda (_win) (etaf-bili--sync-viewport session))
               :on-close (lambda () (etaf-bili--unmounted session)))))
        buffer))))

;;;###autoload
(defun etaf-bili-open-video (bvid-or-url &optional start-seconds cid)
  "Open BVID-OR-URL directly in Watch View at optional START-SECONDS and CID."
  (interactive "sBilibili BV 号或视频链接: ")
  (let* ((buffer (etaf-bili-open))
         (session (with-current-buffer buffer (etaf-bili--current)))
         (target (or (etaf-bili-parse-target bvid-or-url)
                     (list :bvid (string-trim bvid-or-url)))))
    (if (plist-get target :short-url)
        (etaf-bili--handle-search-submit session (plist-get target :short-url))
      (etaf-bili--watch-open-target session target
                                    (or start-seconds (plist-get target :start))
                                    cid))
    buffer))

;;;###autoload
(defun etaf-bili-close ()
  "Close only the Bilibili application buffer, releasing its resources."
  (interactive)
  (when-let* ((buffer (get-buffer etaf-bili--buffer-name)))
    (kill-buffer buffer))
  t)

(defun etaf-bili-next ()
  "Select and focus the next video."
  (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-bili-move session 1)
    (etaf-bili--focus-selected session)))

(defun etaf-bili-previous ()
  "Select and focus the previous video."
  (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-bili-move session -1)
    (etaf-bili--focus-selected session)))

(defun etaf-bili-popular () "Load the popular feed." (interactive)
  (etaf-bili-load-popular (etaf-bili--current)))
(defun etaf-bili-ranking () "Load the ranking." (interactive)
  (etaf-bili-load-ranking (etaf-bili--current)))
(defun etaf-bili-rcmd () "Load personalized recommendations." (interactive)
  (etaf-bili-load-rcmd (etaf-bili--current)))
(defun etaf-bili-dynamic () "Load followed creators' dynamic videos." (interactive)
  (etaf-bili-load-dynamic (etaf-bili--current)))
(defun etaf-bili-toview () "Load the Watch Later list." (interactive)
  (etaf-bili-load-toview (etaf-bili--current)))
(defun etaf-bili-history () "Load watch history." (interactive)
  (etaf-bili-load-history (etaf-bili--current)))
(defun etaf-bili-favorites () "Load favorites." (interactive)
  (etaf-bili-load-favorites (etaf-bili--current)))
(defun etaf-bili-refresh () "Reload the current feed." (interactive)
  (etaf-bili-reload (etaf-bili--current)))

(defun etaf-bili-search-prompt ()
  "Begin editing the catalog SearchField, without opening a minibuffer."
  (interactive)
  (etaf-text-input-begin (etaf-runtime-for-buffer (current-buffer)) 'bili-search))

(defun etaf-bili--activate ()
  "Activate a focused catalog control, or play the selected card."
  (if (etaf-focused-host-ref) (etaf-activate) (etaf-bili-play)))

(defun etaf-bili-play ()
  "Play the selected video in Watch View."
  (interactive)
  (etaf-bili--play-selected-into-watch (etaf-bili--current)))

(defun etaf-bili-details ()
  "Open the selected video's details Drawer and fetch full metadata."
  (interactive)
  (let* ((session (etaf-bili--current))
         (row (etaf-bili-selected-row session)))
    (when row
      (etaf-set-value (etaf-bili--session-details-ref session) row)
      (when-let* ((bvid (plist-get row :bvid)))
        (etaf-bili-client-call
         (etaf-bili--session-client session) (list :op :video :bvid bvid)
         (lambda (reply)
           (when-let* (((not (etaf-bili--session-disposed session)))
                       (cur (etaf-value (etaf-bili--session-details-ref session)))
                       ((equal (plist-get cur :bvid) bvid))
                       (detail (plist-get reply :ok)))
             (etaf-set-value (etaf-bili--session-details-ref session) detail))))))))

(defun etaf-bili-open-author-space ()
  "Open the current or selected video creator's upload space."
  (interactive)
  (let* ((session (etaf-bili--current))
         (src (if (eq (etaf-value (etaf-bili--session-view-mode-ref session)) 'watch)
                  (etaf-value (etaf-bili--session-watch-source-ref session))
                (etaf-bili-selected-row session)))
         (mid (and src (plist-get src :mid)))
         (author (and src (plist-get src :author))))
    (if (and (numberp mid) (> mid 0))
        (etaf-bili-load-space session mid author)
      (etaf-bili--toast session "当前条目未包含 UP 主 UID" 'info))))

(defun etaf-bili-return-to-watch ()
  "Return to Watch View for the current active video."
  (interactive)
  (etaf-bili--return-to-watch (etaf-bili--current)))

(defun etaf-bili-toggle-theme ()
  "Switch the client palette without changing the frame or user theme."
  (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-set-value etaf-bili--theme-mode-ref
                    (if (eq (etaf-value etaf-bili--theme-mode-ref) 'dark)
                        'light 'dark))
    (setq etaf-bili-theme-mode (etaf-value etaf-bili--theme-mode-ref))
    (etaf-set-value (etaf-bili--session-theme-ref session) (etaf-bili-theme-defaults))))

;;; Interactive Watch Commands

(defun etaf-bili-watch-toggle () "Toggle playback." (interactive)
  (etaf-bili--watch-toggle (etaf-bili--current)))
(defun etaf-bili-watch-back-10 () "Seek backward 10 seconds." (interactive)
  (etaf-bili--watch-seek-by (etaf-bili--current) -10))
(defun etaf-bili-watch-forward-10 () "Seek forward 10 seconds." (interactive)
  (etaf-bili--watch-seek-by (etaf-bili--current) 10))
(defun etaf-bili-watch-step () "Step one frame while paused." (interactive)
  (let ((session (etaf-bili--current)))
    (ignore-errors (etaf-video-step (etaf-bili--session-watch-handle session)))))
(defun etaf-bili-watch-cycle-speed () "Cycle playback speed." (interactive)
  (etaf-bili--watch-cycle-speed (etaf-bili--current)))
(defun etaf-bili-watch-speed-up () "Increase playback speed." (interactive)
  (etaf-bili--watch-step-speed (etaf-bili--current) 1))
(defun etaf-bili-watch-speed-down () "Decrease playback speed." (interactive)
  (etaf-bili--watch-step-speed (etaf-bili--current) -1))
(defun etaf-bili-watch-volume-down () "Decrease volume by 10%." (interactive)
  (etaf-bili--watch-volume-delta (etaf-bili--current) -10))
(defun etaf-bili-watch-volume-up () "Increase volume by 10%." (interactive)
  (etaf-bili--watch-volume-delta (etaf-bili--current) 10))
(defun etaf-bili-watch-toggle-audio () "Mute or unmute sound." (interactive)
  (etaf-bili--watch-toggle-audio (etaf-bili--current)))
(defun etaf-bili-watch-quality-menu () "Open quality and CDN selector." (interactive)
  (etaf-bili--watch-toggle-quality-menu (etaf-bili--current)))
(defun etaf-bili-watch-cycle-subtitle () "Toggle or cycle CC/AI subtitles." (interactive)
  (etaf-bili--watch-cycle-subtitle (etaf-bili--current)))
(defun etaf-bili-watch-toggle-danmaku () "Toggle danmaku." (interactive)
  (etaf-bili--watch-toggle-danmaku (etaf-bili--current)))
(defun etaf-bili-watch-toggle-theater () "Toggle theater mode." (interactive)
  (etaf-bili--watch-toggle-theater (etaf-bili--current)))
(defun etaf-bili-watch-toggle-fullscreen () "Toggle in-window pure cinema fullscreen." (interactive)
  (etaf-bili--watch-toggle-fullscreen (etaf-bili--current) 'window))
(defun etaf-bili-watch-toggle-frame-fullscreen () "Toggle dedicated OS/frame fullscreen." (interactive)
  (etaf-bili--watch-toggle-fullscreen (etaf-bili--current) 'frame))
(defun etaf-bili-watch-toggle-drawer () "Toggle narrow-screen side drawer." (interactive)
  (let ((session (etaf-bili--current)))
    (etaf-update-value (etaf-bili--session-watch-drawer-ref session) #'not)))
(defun etaf-bili-watch-toggle-audio-only () "Toggle zero-CPU audio-only mode." (interactive)
  (etaf-bili--watch-toggle-audio-only (etaf-bili--current)))
(defun etaf-bili-watch-toggle-pip () "Toggle Picture-in-Picture floating window." (interactive)
  (etaf-bili--watch-toggle-pip (etaf-bili--current)))
(defun etaf-bili-watch-toggle-auto-next () "Toggle auto-advance." (interactive)
  (etaf-bili--watch-toggle-auto-next (etaf-bili--current)))
(defun etaf-bili-watch-next () "Play next part or next video." (interactive)
  (etaf-bili--watch-step-episode (etaf-bili--current) 1))
(defun etaf-bili-watch-previous () "Play previous part or previous video." (interactive)
  (etaf-bili--watch-step-episode (etaf-bili--current) -1))
(defun etaf-bili-watch-back () "Leave Watch View and return to Gallery." (interactive)
  (etaf-bili--watch-leave (etaf-bili--current)))
(defun etaf-bili-watch-escape ()
  "Close open Watch overlay or exit fullscreen first, otherwise return to Gallery."
  (interactive)
  (let ((session (etaf-bili--current)))
    (cond
     ((etaf-value (etaf-bili--session-watch-quality-menu-ref session))
      (etaf-set-value (etaf-bili--session-watch-quality-menu-ref session) nil))
     ((etaf-value (etaf-bili--session-watch-drawer-ref session))
      (etaf-set-value (etaf-bili--session-watch-drawer-ref session) nil))
     ((etaf-value (etaf-bili--session-watch-fullscreen-ref session))
      (etaf-bili--watch-exit-fullscreen session))
     (t (etaf-bili--watch-leave session)))))
(defun etaf-bili-watch-jump-digit ()
  "Jump to 0%..90% of video duration based on the pressed digit key."
  (interactive)
  (let* ((session (etaf-bili--current))
         (ch (and (integerp last-command-event) (- last-command-event ?0)))
         (dur (etaf-bili--session-watch-duration session)))
    (when (and (integerp ch) (<= 0 ch 9) (> dur 0))
      (etaf-bili--watch-seek session (* dur (/ ch 10.0))))))
(defun etaf-bili-open-external () "Open current video in external player (mpv)." (interactive)
  (etaf-bili--open-external (etaf-bili--current)))
(defun etaf-bili-open-in-browser () "Open current video in browser." (interactive)
  (etaf-bili--open-browser (etaf-bili--current)))
(defun etaf-bili-copy-org-link ()
  "Copy an Org timestamp link reopening this video at the current second."
  (interactive)
  (let* ((session (etaf-bili--current))
         (src (etaf-value (etaf-bili--session-watch-source-ref session))))
    (if (not src)
        (etaf-bili--toast session "当前没有正在观看的视频" 'info)
      (let* ((bvid (plist-get src :bvid))
             (cid (or (plist-get src :cid) 0))
             (sec (max 0 (round (or (etaf-bili--session-watch-position session) 0))))
             (title (or (plist-get src :title) bvid))
             (link (format "[[elisp:(etaf-bili-open-video %S %d %d)][%s (%s)]]"
                           bvid sec cid title (etaf-bili--clock sec))))
        (kill-new link)
        (etaf-bili--toast session
                          (format "已复制 Org 链接：%s" (etaf-bili--clock sec))
                          'ok)))))

;;;###autoload
(defun etaf-bili-doctor ()
  "Return capability facts for `etaf-bili' matching `etaf-install-doctor'.
Returns `(:required FACTS :optional FACTS)' where each fact is
`(LABEL AVAILABLE REMEDY)'.  Inspects the environment without modifying it."
  (let ((curl (executable-find etaf-bili-curl-program))
        (node (executable-find etaf-bili-node-program))
        (mpv-native (and (fboundp 'etaf-video-mpv-available-p)
                         (etaf-video-mpv-available-p)))
        (gpu-native (and (fboundp 'etaf-video-gpu-available-p)
                         (etaf-video-gpu-available-p)))
        (ffmpeg (and (executable-find etaf-video-ffmpeg-program)
                     (executable-find etaf-video-ffplay-program)))
        (mpv-cli (executable-find "mpv"))
        (sqlite (and (fboundp 'sqlite-available-p) (sqlite-available-p))))
    (list
     :required
     (list
      (list "curl" (and curl t)
            "Install curl so Bilibili API calls, WBI DASH stream resolution and cover downloads can run."))
     :optional
     (list
      (list "Node.js" (and node t)
            "Install Node.js 18+ so in-app QR sign-in (M-x etaf-bili-login) and account status checks can run.")
      (list "libmpv native video engine" (and mpv-native t)
            "Install libmpv (or run M-x etaf-install-native selecting etaf) for hardware-accelerated playback and live ASS danmaku.")
      (list "Native hardware GPU video layer" (and gpu-native t)
            "Run in GUI Emacs on macOS, Windows or Linux with libmpv and etaf-video-mpv native module v2 (M-x etaf-install-native) for low-CPU GPU playback.")
      (list "ffmpeg / ffplay fallback" (and ffmpeg t)
            "Install ffmpeg as the software fallback playback pipeline.")
      (list "External mpv handoff" (and mpv-cli t)
            "Install mpv to support external window playback via `o' and audio-only mode.")
      (list "SQLite persistence" (and sqlite t)
            "Use Emacs built with SQLite support to persist watch resume positions, preferences and search history.")))))

(provide 'etaf-bili-app)
;;; etaf-bili-app.el ends here
