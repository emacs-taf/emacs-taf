;;; etaf-youtube-watch.el --- Cinema Watch View & 5-Tab Workbench for etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Implements the approved Cinema Watch View design:
;; - 3-row Watch Header (`← 返回', title, queue badge, narrow Drawer trigger,
;;   明暗, 宽屏, `?').
;; - Wide viewport (>= 116 cols, non-theater): Left 16:9 Theater + Right 42-col
;;   5-Tab Workbench (`简介' with expandable full description & clickable
;;   chapters, `字幕' with multi-language track pills & searchable transcript
;;   jump, `评论' with sort pills, composer, clickable MM:SS timestamps,
;;   reactive collapsible replies & pagination, `推荐' with auto-next & load
;;   more, `队列' with active indicator).
;; - Narrow viewport (< 116 cols) or Theater mode (`w'/`t'): Video canvas takes
;;   maximum width; workbench opens on demand inside `etaf-drawer' (`i').
;; - Pure dark `#050608' video stage, `#080A0F' 1-row Retained Host subtitle
;;   strip, de-boxed Studio transport deck with Retained Host clock/duration/
;;   seek bar and SVG icons (zero raw emoji, zero per-second rerenders).
;; - Quality & Engine Dialog (`Q`) for 0ms quality switching and failover.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-youtube-theme)
(require 'etaf-youtube-model)

(declare-function etaf-youtube-open-external "etaf-youtube-app" ())
(declare-function etaf-youtube-open-in-browser "etaf-youtube-app" ())
(declare-function etaf-youtube-copy-org-link "etaf-youtube-app" ())
(declare-function etaf-youtube-toggle-pip-command "etaf-youtube-app" ())
(declare-function etaf-youtube--pip-return "etaf-youtube-app" (model))
(declare-function etaf-youtube--pip-close "etaf-youtube-app" (model &optional restore-focus))

(defvar etaf-youtube-region-comments)
(defvar etaf-youtube-region-content)

(defun etaf-youtube--watch-border (color)
  "Return a 1px solid border spec in COLOR."
  (list '(px 1) 'solid color))

(defun etaf-youtube--watch-truncate (text max-cols)
  "Truncate TEXT to at most MAX-COLS display columns with an ellipsis."
  (let ((str (or text "")))
    (if (<= (string-width str) max-cols)
        str
      (let ((limit (max 1 (1- max-cols)))
            (acc "")
            (w 0)
            (i 0)
            (len (length str)))
        (while (and (< i len)
                    (<= (+ w (char-width (aref str i))) limit))
          (setq w (+ w (char-width (aref str i)))
                acc (concat acc (substring str i (1+ i)))
                i (1+ i)))
        (concat acc "…")))))

(defun etaf-youtube--watch-canvas-fit (media stage-cols stage-rows cw lh)
  "Compute `(COLUMNS . ROWS)' fitting MEDIA's native aspect tightly in STAGE."
  (let* ((w (float (max 1 (or (and media (plist-get media :width)) 16))))
         (h (float (max 1 (or (and media (plist-get media :height)) 9))))
         (aspect (/ w h))
         (avail-px (float (max 1 (* stage-cols cw))))
         (avail-py (float (max 1 (* stage-rows lh))))
         (fit-py (min avail-py (/ avail-px aspect)))
         (rows (max 1 (min stage-rows (floor fit-py lh))))
         (fit-px (min avail-px (* rows lh aspect)))
         (cols (max 4 (min stage-cols (round (/ fit-px cw))))))
    (cons cols rows)))

(defun etaf-youtube--confirm-action (prompt callback)
  "Ask user PROMPT via `y-or-n-p' (skipped in batch), then run CALLBACK."
  (when (or noninteractive (y-or-n-p prompt))
    (funcall callback)))

;;; ---------------------------------------------------------------------------
;;; Shared borderless Watch Chip
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube--watch-chip
    (&key label icon active accent-color soft width help on-press ref mode)
  "De-boxed Watch control with zero-jitter invariant geometry and strict hover."
  :render
  (let* ((m (or mode etaf-youtube-theme-mode))
         (fg (cond (active (etaf-youtube-color :accent m))
                   (accent-color accent-color)
                   (t (etaf-youtube-color :muted m))))
         (bg (cond (active (etaf-youtube-color :accent-soft m))
                   (soft (etaf-youtube-color :panel3 m))
                   (t nil))))
    (etaf-view
     (box :ref ref :width width :height '(lh 1) :padding '((lh 0) (ch 1))
          :text-align (when width 'center) :flex-shrink 0
          :role 'button :tab-index 0 :help-echo help
          :background-color bg :color fg
          :pointer (unless active 'hand)
          :hover-style (unless active
                         (list :color (etaf-youtube-color :ink m)
                               :background-color (etaf-youtube-color :hover m)))
          :on-press on-press
       (etaf-ui-icon :if icon :name icon :set 'svg :size 0.85 :min-width 2 :color fg)
       (text :if (not icon) (expr label))))))

;;; ---------------------------------------------------------------------------
;;; Watch Header (always height 3 on standard viewports, matches banner role)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube--watch-header
    (&key model compact mode theater height on-drawer)
  "Clean Watch header: Back, full title, queue badge, drawer, theme, theater, help."
  :render
  (let* ((video (etaf-value (plist-get model :video)))
         (media (etaf-value (plist-get model :media)))
         (title (or (plist-get video :title) (plist-get media :title) "正在加载视频…"))
         (queue (etaf-value (plist-get model :queue)))
         (qidx (etaf-value (plist-get model :queue-index)))
         (qbadge (when (and (> (length queue) 1) (integerp qidx))
                   (format "列表 %d / %d" (1+ qidx) (length queue))))
         (h (or height 3)))
    (etaf-view
     (flex :role 'banner :width 'stretch :height (list 'lh h) :align-items 'center
           :gap '((lh 0) (ch 2)) :padding '((lh 0) (ch 2))
           :background-color (etaf-youtube-color :panel2 mode)
           :border-bottom (etaf-youtube--watch-border (etaf-youtube-color :line mode))
       (etaf-youtube--watch-chip
        :ref 'yt-watch-back :mode mode :label "← 返回" :soft t
        :accent-color (etaf-youtube-color :ink mode)
        :help "返回列表 (b / Esc)"
        :on-press (lambda () (etaf-youtube-back model)))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (text :color (etaf-youtube-color :ink mode) :font-weight 'bold
           (expr title)))
       (box :if qbadge :flex-shrink 0 :height '(lh 1) :padding '((lh 0) (ch 1))
            :background-color (etaf-youtube-color :accent-soft mode)
            :color (etaf-youtube-color :accent mode)
         (text :font-weight 'bold (expr qbadge)))
       (etaf-youtube--watch-chip
        :if compact :ref 'yt-watch-drawer-btn :mode mode
        :label "侧栏 (i)" :soft t
        :accent-color (etaf-youtube-color :ink mode)
        :help "打开工作台抽屉 (i)" :on-press on-drawer)
       (etaf-youtube--watch-chip
        :ref 'yt-watch-theme :mode mode :label "明暗"
        :help "切换明暗外观 (d / T)"
        :on-press (lambda () (etaf-youtube-cycle-theme model)))
       (etaf-youtube--watch-chip
        :if (not compact) :ref 'yt-watch-theater :mode mode
        :label (if theater "侧栏" "宽屏") :active theater
        :help "切换宽屏纯净剧场 (w / t)"
        :on-press (lambda () (etaf-youtube-toggle-theater model)))
       (etaf-youtube--watch-chip
        :mode mode :label "?" :help "查看快捷键 (?)"
        :on-press #'etaf-help)))))

;;; ---------------------------------------------------------------------------
;;; Right 5-Tab Workbench (简介 / 字幕 / 评论 / 推荐 / 队列)
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--render-comment-card (model comment width mode replies-map collapsed-map)
  "Render one COMMENT card with clickable timestamps and reactive replies."
  (let* ((cid (plist-get comment :id))
         (author (or (plist-get comment :author) "匿名"))
         (pub (or (plist-get comment :published) ""))
         (likes (or (plist-get comment :likes) ""))
         (body (or (plist-get comment :text) ""))
         (reply-count (or (plist-get comment :reply_count) ""))
         (has-cursor (plist-get comment :replies))
         (entry (and (hash-table-p replies-map) (gethash cid replies-map)))
         (loaded-replies (plist-get entry :items))
         (next-cursor (plist-get entry :next))
         (exhausted (plist-get entry :exhausted))
         (collapsed (and (hash-table-p collapsed-map) (gethash cid collapsed-map)))
         (stamps (etaf-youtube--extract-timestamps body))
         (meta (string-join
                (delq nil (list (unless (string-empty-p pub) pub)
                                (unless (string-empty-p likes) (format "♥ %s" likes))))
                " · ")))
    (etaf-node
     'column
     (list :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
           :background-color (etaf-youtube-color :panel2 mode)
           :border (etaf-youtube--watch-border (etaf-youtube-color :line-soft mode)))
     (append
      (list
       (etaf-node
        'flex (list :width 'stretch :height '(lh 1) :align-items 'center
                    :justify-content 'space-between :gap '((lh 0) (ch 1)))
        (list
         (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                               :overflow 'hidden :wrap-mode 'none
                               :color (etaf-youtube-color :ink mode) :font-weight 'bold)
                    (list (etaf-node 'text nil (list author))))
         (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                    (list meta))))
       (etaf-node 'box (list :width 'stretch :color (etaf-youtube-color :muted mode))
                  (list (etaf-node 'text nil (list (etaf-youtube--watch-truncate body 280))))))
      ;; Clickable timestamps inside comment
      (when stamps
        (list
         (etaf-node
          'flex (list :width 'stretch :gap '((lh 0) (ch 1)))
          (mapcar
           (lambda (pair)
             (let ((sec (car pair)) (tok (cdr pair)))
               (etaf-node
                'box (list :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
                           :color (etaf-youtube-color :link mode)
                           :hover-style (list :color (etaf-youtube-color :accent mode))
                           :help-echo (format "跳转到 %s" tok)
                           :on-press (lambda () (etaf-youtube-seek model (float sec))))
                (list (etaf-node 'text nil (list (format "↗ %s" tok)))))))
           (seq-take stamps 4)))))
      ;; Loaded replies list (when not collapsed)
      (when (and loaded-replies (not collapsed))
        (list
         (etaf-node
          'column (list :width 'stretch :padding '((lh 0) (ch 2)) :item-gap '(lh 0)
                        :border-left (etaf-youtube--watch-border (etaf-youtube-color :line mode)))
          (mapcar
           (lambda (rep)
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 0))
              (list
               (etaf-node 'text (list :color (etaf-youtube-color :ink mode) :font-weight 'bold)
                          (list (format "%s  ·  %s"
                                        (or (plist-get rep :author) "")
                                        (or (plist-get rep :published) ""))))
               (etaf-node 'text (list :color (etaf-youtube-color :muted mode))
                          (list (etaf-youtube--watch-truncate
                                 (or (plist-get rep :text) "") (max 24 (- width 10))))))))
           loaded-replies))))
      ;; Reply action row (load / load more / collapse / expand)
      (when (or has-cursor loaded-replies)
        (list
         (etaf-node
          'flex (list :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 2)))
          (delq
           nil
           (list
            (when (or (and (null entry) has-cursor) (and entry next-cursor (not exhausted)))
              (etaf-node
               'box (list :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
                          :color (etaf-youtube-color :link mode)
                          :hover-style (list :color (etaf-youtube-color :accent mode))
                          :on-press (lambda () (etaf-youtube-load-replies model cid)))
               (list (etaf-node 'text nil
                                (list (cond
                                       (loaded-replies "加载更多回复")
                                       ((not (string-empty-p reply-count))
                                        (format "展开 %s 条回复" reply-count))
                                       (t "查看回复")))))))
            (when loaded-replies
              (etaf-node
               'box (list :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
                          :color (etaf-youtube-color :dim mode)
                          :hover-style (list :color (etaf-youtube-color :ink mode))
                          :on-press (lambda () (etaf-youtube--toggle-replies-collapsed model cid)))
               (list (etaf-node 'text nil
                                (list (if collapsed
                                          (format "显示已加载回复 (%d)" (length loaded-replies))
                                        "收起回复")))))))))))))))

(etaf-define-component etaf-youtube--watch-workbench
    (&key model width height tab-height mode on-close-drawer)
  "5-Tab editorial workbench: 简介, 字幕, 评论, 推荐, 队列."
  :render
  (let* ((tab (etaf-value (plist-get model :watch-tab)))
         (th (or tab-height 3))
         (body-h (max 6 (- height th)))
         (video (etaf-value (plist-get model :video)))
         (media (etaf-value (plist-get model :media)))
         (chapters (etaf-value (plist-get model :chapters)))
         (desc-exp (etaf-value (plist-get model :desc-expanded)))
         (tracks (etaf-youtube--available-subtitle-tracks model))
         (cap-on (etaf-value (plist-get model :captions-on)))
         (cap-lang (etaf-value (plist-get model :caption-language)))
         (captions (etaf-value (plist-get model :captions)))
         (cap-filter (string-trim (or (etaf-value (plist-get model :caption-filter)) "")))
         (comments (etaf-value (plist-get model :comments)))
         (c-status (etaf-value (plist-get model :comments-status)))
         (c-more (etaf-value (plist-get model :comments-more)))
         (r-more (etaf-value (plist-get model :related-more)))
         (replies-map (etaf-value (plist-get model :replies)))
         (_rver (etaf-value (plist-get model :replies-version)))
         (collapsed-map (plist-get model :replies-collapsed))
         (auto-next (etaf-value (plist-get model :auto-next)))
         (queue (etaf-value (plist-get model :queue)))
         (qidx (etaf-value (plist-get model :queue-index)))
         (tabs (list (cons 'info "简介")
                     (cons 'subtitles "字幕")
                     (cons 'comments "评论")
                     (cons 'related "推荐")
                     (cons 'queue (if (> (length queue) 0)
                                      (format "队列 %d" (length queue))
                                    "队列")))))
    (etaf-node
     'column
     (list :width 'stretch :height (list 'lh height)
           :background-color (etaf-youtube-color :surface mode)
           :overflow 'hidden
           :region (list :id etaf-youtube-region-comments :label "评论与工作台" :key ?m))
     (list
      ;; Tab bar aligned flush with Left Creator/Engagement strip
      (etaf-node
       'flex
       (list :width 'stretch :height (list 'lh th) :align-items 'center
             :gap '((lh 0) (ch 1)) :padding '((lh 0) (ch 1))
             :background-color (etaf-youtube-color :surface mode)
             :border-bottom (etaf-youtube--watch-border (etaf-youtube-color :line mode)))
       (mapcar
        (lambda (pair)
          (let ((key (car pair)) (lbl (cdr pair)) (active (eq (car pair) tab)))
            (etaf-node
             'box
             (list :height '(lh 1) :padding '((lh 0) (ch 1))
                   :role 'button :tab-index 0
                   :aria-label lbl :aria-selected active
                   :color (etaf-youtube-color (if active :accent :muted) mode)
                   :background-color (when active (etaf-youtube-color :accent-soft mode))
                   :pointer (unless active 'hand)
                   :hover-style (unless active
                                  (list :color (etaf-youtube-color :ink mode)
                                        :background-color (etaf-youtube-color :hover mode)))
                   :on-press (lambda () (etaf-youtube--write model :watch-tab key)))
             (list (etaf-node 'text nil (list lbl))))))
        tabs))
      ;; Scrollable Tab Body
      (etaf-node
       'box
       (list :ref 'yt-watch-side-scroll :width 'stretch :height (list 'lh body-h)
             :overflow 'scroll :padding '((lh 1) (ch 2)))
       (list
        (pcase tab
          ;; 1. Info & Chapters
          ('info
           (let* ((desc (or (plist-get video :description) ""))
                  (short-desc (if (and (not desc-exp) (> (length desc) 220))
                                  (concat (substring desc 0 220) "…")
                                desc))
                  (needs-toggle (> (length desc) 220))
                  (q-label (or (plist-get media :quality_label)
                               (when-let* ((h (plist-get media :height))) (format "%dp" h))
                               "解析中…"))
                  (c-label (or (plist-get media :codec_label) ""))
                  (proto (or (plist-get media :protocol) ""))
                  (vid (or (plist-get video :id) (plist-get media :id) "")))
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 1))
              (append
               (list
                (etaf-node 'text (list :color (etaf-youtube-color :ink mode) :font-weight 'bold)
                           (list "视频信息"))
                (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                           (list (string-join
                                  (delq nil
                                        (list (plist-get video :views)
                                              (plist-get video :published)
                                              (plist-get video :subscribers)))
                                  " · ")))
                (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                           (list (format "ID: %s · %s %s %s" vid q-label c-label proto)))
                (etaf-node 'box (list :width 'stretch :color (etaf-youtube-color :muted mode))
                           (list (etaf-node 'text nil
                                            (list (if (string-empty-p desc) "暂无简介" short-desc))))))
               (when needs-toggle
                 (list
                  (etaf-node
                   'box (list :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
                              :color (etaf-youtube-color :link mode)
                              :hover-style (list :color (etaf-youtube-color :accent mode))
                              :on-press (lambda ()
                                          (etaf-youtube--write model :desc-expanded (not desc-exp))))
                   (list (etaf-node 'text nil (list (if desc-exp "收起简介" "展开全部简介")))))))
               ;; Clickable timestamps inside description (when no formal chapters)
               (when (and (null chapters) (etaf-youtube--extract-timestamps desc))
                 (list
                  (etaf-node
                   'flex (list :width 'stretch :gap '((lh 0) (ch 1)))
                   (mapcar
                    (lambda (pair)
                      (let ((sec (car pair)) (tok (cdr pair)))
                        (etaf-node
                         'box (list :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
                                    :color (etaf-youtube-color :link mode)
                                    :hover-style (list :color (etaf-youtube-color :accent mode))
                                    :on-press (lambda () (etaf-youtube-seek model (float sec))))
                         (list (etaf-node 'text nil (list (format "↗ %s" tok)))))))
                    (seq-take (etaf-youtube--extract-timestamps desc) 6)))))
               ;; Native / Parsed Chapters
               (when chapters
                 (cons
                  (etaf-node 'text (list :color (etaf-youtube-color :ink mode) :font-weight 'bold)
                             (list (format "章节导航（共 %d 章 · 点击空降）" (length chapters))))
                  (mapcar
                   (lambda (ch)
                     (let ((start (or (plist-get ch :start) 0))
                           (ctitle (or (plist-get ch :title) "")))
                       (etaf-node
                        'box
                        (list :width 'stretch :height '(lh 1) :role 'button :tab-index 0
                              :pointer 'hand
                              :hover-style (list :background-color (etaf-youtube-color :hover mode)
                                                 :color (etaf-youtube-color :accent mode))
                              :on-press (lambda () (etaf-youtube-seek model (float start))))
                        (list (etaf-node 'text (list :color (etaf-youtube-color :link mode))
                                         (list (format "%s  %s"
                                                       (etaf-youtube--clock start)
                                                       (etaf-youtube--watch-truncate
                                                        ctitle (max 14 (- width 13))))))))))
                   chapters)))
               ;; Quick utility links
               (list
                (etaf-node 'etaf-divider nil nil)
                (etaf-node
                 'flex (list :width 'stretch :gap '((lh 0) (ch 1)))
                 (list
                  (etaf-node 'etaf-youtube--watch-chip
                             (list :mode mode :soft t :label "复制 Org 链接 (y)"
                                   :on-press #'etaf-youtube-copy-org-link) nil)
                  (etaf-node 'etaf-youtube--watch-chip
                             (list :mode mode :soft t :label "浏览器 (O)"
                                   :on-press #'etaf-youtube-open-in-browser) nil))))))))

          ;; 2. Subtitles & Searchable Transcript
          ('subtitles
           (let* ((cues (plist-get captions :cues))
                  (filtered
                   (if (string-empty-p cap-filter)
                       cues
                     (let ((needle (downcase cap-filter)))
                       (seq-filter (lambda (c)
                                     (string-match-p (regexp-quote needle)
                                                     (downcase (or (plist-get c :text) ""))))
                                   cues)))))
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 1))
              (append
               (list
                (etaf-node
                 'flex (list :width 'stretch :height '(lh 1) :gap '((lh 0) (ch 1)))
                 (append
                  (list (etaf-node 'etaf-youtube--watch-chip
                                   (list :mode mode :label "关" :active (not cap-on)
                                         :on-press (lambda () (etaf-youtube--select-caption-track model nil)))
                                   nil))
                  (mapcar
                   (lambda (tr)
                     (let* ((lang (plist-get tr :language))
                            (active (and cap-on (equal cap-lang lang)))
                            (lbl (etaf-youtube--watch-truncate
                                  (or (plist-get tr :name) lang) 10)))
                       (etaf-node 'etaf-youtube--watch-chip
                                  (list :mode mode :label lbl :active active
                                        :help (format "%s (%s)" (or (plist-get tr :name) lang)
                                                      (or (plist-get tr :kind) ""))
                                        :on-press (lambda () (etaf-youtube--select-caption-track model tr)))
                                  nil)))
                   (seq-take tracks 5))))
                (etaf-node 'etaf-search-field
                           (list :ref 'yt-sub-search
                                 :bind (plist-get model :caption-filter)
                                 :placeholder "筛选字幕文稿（点击空降）")
                           nil))
               (if filtered
                   (mapcar
                    (lambda (cue)
                      (let ((sec (or (plist-get cue :start) 0))
                            (txt (or (plist-get cue :text) "")))
                        (etaf-node
                         'box
                         (list :width 'stretch :padding '((lh 0) (ch 1))
                               :role 'button :tab-index 0 :pointer 'hand
                               :hover-style (list :background-color (etaf-youtube-color :hover mode))
                               :on-press (lambda () (etaf-youtube-seek model (float sec))))
                         (list (etaf-node 'text (list :color (etaf-youtube-color :ink mode))
                                          (list (format "%s  %s"
                                                        (etaf-youtube--clock sec)
                                                        (etaf-youtube--watch-truncate
                                                         txt (max 14 (- width 13))))))))))
                    (seq-take filtered 90))
                 (list (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                                  (list (cond
                                         ((and cap-on (null cues)) "正在加载字幕文稿…")
                                         (tracks "点击上方语言开启字幕，即可全文检索并点击空降")
                                         (t "当前视频暂无 CC / 自动字幕轨道"))))))))))

          ;; 3. Comments (sort chips + composer + cards + pagination)
          ('comments
           (let* ((items (plist-get comments :items))
                  (sort-opts (plist-get comments :sort))
                  (cur-sort (etaf-value (plist-get model :comments-sort)))
                  (can-comment (plist-get comments :can_comment))
                  (req-channel (plist-get comments :requires_channel))
                  (next-cur (plist-get comments :next)))
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 1))
              (append
               ;; Header + Sort chips
               (list
                (etaf-node
                 'flex (list :width 'stretch :height '(lh 1) :align-items 'center
                             :justify-content 'space-between :gap '((lh 0) (ch 1)))
                 (list
                  (etaf-node 'text (list :color (etaf-youtube-color :ink mode) :font-weight 'bold)
                             (list (format "评论 %s" (or (plist-get comments :count) ""))))
                  (etaf-node
                   'flex (list :height '(lh 1) :gap '((lh 0) (ch 1)))
                   (mapcar
                    (lambda (s)
                      (let* ((scur (plist-get s :cursor))
                             (sel (if cur-sort (equal cur-sort scur) (plist-get s :selected))))
                        (etaf-node 'etaf-youtube--watch-chip
                                   (list :mode mode :label (plist-get s :title) :active sel
                                         :on-press (lambda () (etaf-youtube-sort-comments model scur)))
                                   nil)))
                    sort-opts)))))
               ;; Comment composer (when permitted)
               (cond
                (can-comment
                 (list
                  (etaf-node
                   'flex (list :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center)
                   (list
                    (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
                               (list (etaf-node 'etaf-text-input
                                                (list :ref 'yt-comment-input
                                                      :bind (plist-get model :comment-draft)
                                                      :width 'stretch
                                                      :hide-label t
                                                      :placeholder "写一条公开评论…")
                                                nil)))
                    (etaf-node
                     'etaf-button
                     (list :label "发布" :variant 'primary
                           :on-press
                           (lambda ()
                             (let ((draft (string-trim (or (etaf-value (plist-get model :comment-draft)) ""))))
                               (if (string-empty-p draft)
                                   (etaf-youtube--note model "请先输入评论内容" 'info)
                                 (etaf-youtube--confirm-action
                                  (format "确认公开提交评论：「%s」？" (etaf-youtube--watch-truncate draft 40))
                                  (lambda ()
                                    (etaf-youtube-comment model draft t)
                                    (etaf-youtube--write model :comment-draft "")))))))
                     nil)))))
                (req-channel
                 (list (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                                  (list "当前账号尚未创建 YouTube 频道，暂不可评论")))))
               ;; Comment status / cards
               (cond
                ((eq (plist-get c-status :state) 'loading)
                 (list (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                                  (list "正在加载评论…"))))
                ((eq (plist-get c-status :state) 'error)
                 (list (etaf-node 'text (list :color (etaf-youtube-color :danger mode))
                                  (list (or (plist-get c-status :message) "评论加载失败")))))
                (items
                 (mapcar (lambda (c)
                           (etaf-youtube--render-comment-card
                            model c width mode replies-map collapsed-map))
                         items))
                (t
                 (list (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                                  (list "暂无评论或已关闭评论")))))
               ;; Pagination button
               (when next-cur
                 (list
                  (etaf-node
                   'etaf-button
                   (list :label (if c-more "正在加载更多评论…" "加载更多评论")
                         :variant 'secondary :disabled c-more
                         :on-press (lambda () (etaf-youtube--load-more-comments model)))
                   nil)))))))

          ;; 4. Related videos (with auto-next toggle + load more)
          ('related
           (let ((rel (plist-get video :related))
                 (rel-next (plist-get video :related_next)))
             (etaf-node
              'column (list :width 'stretch :item-gap '(lh 1))
              (append
               (list
                (etaf-node
                 'flex (list :width 'stretch :height '(lh 1) :align-items 'center
                             :justify-content 'space-between)
                 (list
                  (etaf-node
                   'box (list :height '(lh 1) :role 'button :tab-index 0 :pointer 'hand
                              :color (etaf-youtube-color (if auto-next :ok :muted) mode)
                              :hover-style (list :color (etaf-youtube-color :ink mode))
                              :on-press (lambda () (etaf-youtube--toggle-auto-next model)))
                   (list (etaf-node 'text (list :font-weight 'bold)
                                    (list (if auto-next "● 自动连播开 (L)" "○ 自动连播关 (L)")))))
                  (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                             (list (format "%d 条" (length rel)))))))
               (if rel
                   (mapcar
                    (lambda (row)
                      (let* ((rid (plist-get row :id))
                             (rtitle (etaf-youtube--watch-truncate
                                      (or (plist-get row :title) "") (max 16 (- width 8))))
                             (rmeta (string-join
                                     (delq nil
                                           (list (etaf-youtube--nonempty-string (plist-get row :author))
                                                 (etaf-youtube--nonempty-string (plist-get row :views))
                                                 (let ((d (plist-get row :duration)))
                                                   (cond ((and (stringp d) (not (string-empty-p d))) d)
                                                         ((and (numberp d) (> d 0)) (etaf-youtube--clock d))))))
                                     " · ")))
                        (etaf-node
                         'column
                         (list :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
                               :role 'button :tab-index 0 :pointer 'hand
                               :background-color (etaf-youtube-color :panel2 mode)
                               :on-press (lambda ()
                                           (when on-close-drawer (funcall on-close-drawer))
                                           (etaf-youtube-open-video model rid)))
                         (list
                          (etaf-node 'box (list :width 'stretch :color (etaf-youtube-color :ink mode)
                                                :hover-style (list :color (etaf-youtube-color :accent mode)))
                                     (list (etaf-node 'text nil (list rtitle))))
                          (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                                     (list (etaf-youtube--watch-truncate rmeta (max 14 (- width 8)))))))))
                    rel)
                 (list (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                                  (list "正在加载相关推荐…"))))
               (when rel-next
                 (list
                  (etaf-node
                   'etaf-button
                   (list :label (if r-more "正在加载更多推荐…" "加载更多推荐")
                         :variant 'secondary :disabled r-more
                         :on-press (lambda () (etaf-youtube--load-more-related model)))
                   nil)))))))

          ;; 5. Playback Queue
          ('queue
           (etaf-node
            'column (list :width 'stretch :item-gap '(lh 1))
            (append
             (list
              (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                         (list (format "当前播放队列 · 共 %d 条（N 下一条 / P 上一条）" (length queue)))))
             (if queue
                 (cl-loop for item in queue for i from 0 collect
                          (let* ((active (eql i qidx))
                                 (iid (plist-get item :id))
                                 (ititle (etaf-youtube--watch-truncate
                                          (or (plist-get item :title) "") (max 16 (- width 12))))
                                 (iauthor (or (plist-get item :author) "")))
                            (etaf-node
                             'column
                             (list :width 'stretch :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
                                   :role 'button :tab-index 0
                                   :background-color (when active (etaf-youtube-color :accent-soft mode))
                                   :border-left (etaf-youtube--watch-border
                                                 (etaf-youtube-color (if active :accent :surface) mode))
                                   :pointer (unless active 'hand)
                                   :on-press (lambda ()
                                               (unless active
                                                 (etaf-youtube--write model :queue-index i)
                                                 (when on-close-drawer (funcall on-close-drawer))
                                                 (etaf-youtube-open-video model iid))))
                             (list
                              (etaf-node
                               'flex (list :width 'stretch :height '(lh 1) :align-items 'center)
                               (list
                                (etaf-node 'box (list :width '(ch 2) :flex-shrink 0
                                                      :color (etaf-youtube-color (if active :accent :dim) mode))
                                           (list (etaf-node 'text nil (list (if active "▸" "")))))
                                (etaf-node 'box (list :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                                                      :overflow 'hidden :wrap-mode 'none
                                                      :color (etaf-youtube-color (if active :accent :ink) mode)
                                                      :hover-style (unless active
                                                                     (list :color (etaf-youtube-color :accent mode))))
                                           (list (etaf-node 'text nil
                                                            (list (format "%d. %s" (1+ i) ititle)))))))
                              (etaf-node 'box (list :padding '((lh 0) (ch 2))
                                                    :color (etaf-youtube-color :dim mode))
                                         (list (etaf-node 'text nil (list iauthor))))))))
               (list (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                                (list "从列表或播放列表打开视频时会自动生成播放队列"))))))))))))))

;;; ---------------------------------------------------------------------------
;;; Shared Cinema Top Bar & 4-Tier Aligned Transport Deck (Fullscreen + PiP)
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube--cinema-topbar
    (&key model cols mode fs-mode on-drawer on-toggle-frame on-toggle-pip on-exit)
  "Ultra-slim 1-row Pure Fullscreen top bar mirroring PiP's aligned chrome."
  :render
  (let* ((hpad-cols (if (< cols 52) 1 2))
         (video (etaf-value (plist-get model :video)))
         (media (etaf-value (plist-get model :media)))
         (title (or (plist-get video :title) (plist-get media :title) "正在加载视频…"))
         (queue (etaf-value (plist-get model :queue)))
         (qidx (etaf-value (plist-get model :queue-index)))
         (qbadge (when (and (> (length queue) 1) (integerp qidx) (>= cols 56))
                   (format "%d / %d" (1+ qidx) (length queue))))
         (author (or (plist-get video :author) ""))
         (q-label (or (plist-get media :quality_label)
                      (when-let* ((h (plist-get media :height))) (format "%dp" h))))
         (meta (when (and (>= cols 108)
                          (or (not (string-empty-p author)) q-label))
                 (string-join
                  (delq nil (list (unless (string-empty-p author) author)
                                  q-label))
                  " · ")))
         (frame-p (eq fs-mode 'frame)))
    (etaf-view
     (flex :ref 'yt-cinema-topbar :width 'stretch :height '(lh 1)
           :align-items 'center :gap '((lh 0) (ch 1))
           :padding (list '(lh 0) (list 'ch hpad-cols))
           :background-color (etaf-youtube-color :panel2 mode)
           :border-bottom (etaf-youtube--watch-border (etaf-youtube-color :line mode))
       (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
            :height '(lh 1) :overflow 'hidden :wrap-mode 'none
         (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
           (box :flex-shrink 1 :min-width '(ch 8) :height '(lh 1)
                :overflow 'hidden :wrap-mode 'none
             (text :color (etaf-youtube-color :ink mode) :font-weight 'bold
               (expr title)))
           (box :if qbadge :flex-shrink 0 :height '(lh 1) :padding '((lh 0) (ch 1))
                :background-color (etaf-youtube-color :accent-soft mode)
                :color (etaf-youtube-color :accent mode)
             (text :font-weight 'bold (expr qbadge)))
           (box :if meta :flex-shrink 0 :height '(lh 1) :overflow 'hidden :wrap-mode 'none
                :color (etaf-youtube-color :dim mode)
             (text (expr meta)))))
       (etaf-youtube--watch-chip :if (>= cols 68) :ref 'yt-cinema-drawer :mode mode
                                 :label "侧栏 i" :soft t
                                 :accent-color (etaf-youtube-color :ink mode)
                                 :help "打开工作台抽屉 (i)" :on-press on-drawer)
       (box :if (>= cols 80) :ref 'yt-cinema-frame-fs :id "yt-cinema-frame-fs"
            :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (etaf-youtube-color (if frame-p :accent-soft :panel3) mode)
            :color (etaf-youtube-color (if frame-p :accent :ink) mode)
            :font-weight (if frame-p 'bold 'normal)
            :hover-style (unless frame-p
                           (list :color (etaf-youtube-color :ink mode)
                                 :background-color (etaf-youtube-color :hover mode)))
            :help-echo "切换系统真全屏，退出自动还原分屏 (F)"
            :on-press on-toggle-frame
         (text "真全屏 F"))
       (etaf-youtube--watch-chip :if (>= cols 54) :ref 'yt-cinema-pip :mode mode
                                 :label "PiP" :soft t
                                 :accent-color (etaf-youtube-color :ink mode)
                                 :help "切换到悬浮画中画 (v)" :on-press on-toggle-pip)
       (box :ref 'yt-cinema-exit :id "yt-cinema-exit"
            :height '(lh 1) :padding '((lh 0) (ch 1)) :flex-shrink 0
            :role 'button :tab-index 0 :pointer 'hand
            :background-color (etaf-youtube-color :accent-soft mode)
            :color (etaf-youtube-color :accent mode)
            :font-weight 'bold
            :hover-style (list :background-color (etaf-youtube-color :accent mode)
                               :color "#FFFFFF")
            :help-echo "退出全屏返回观影页 (f / Esc)"
            :on-press on-exit
         (text (expr (if (< cols 48) "↩" "↩ 退出"))))))))

(etaf-define-component etaf-youtube--cinema-deck
    (&key px-w cols rows cw gap-mid mode playing loading-p muted vol spd cc-on
          quality-label progress-ref progress-fill-ref progress-id
          time-ref time-text on-seek on-toggle on-prev on-next
          on-toggle-mute on-vol-delta on-cycle-speed on-open-quality on-toggle-cc)
  "Shared 4-tier optically-aligned transport deck for both Fullscreen and PiP."
  :render
  (let* ((mini (< cols 44))
         (cinema (>= cols 88))
         (hpad-cols (if (< cols 52) 1 2))
         (ctrl-pad-cols (max 0 (1- hpad-cols)))
         (right-pad-cols (if mini ctrl-pad-cols hpad-cols))
         (has-mid (and gap-mid (>= rows 14)))
         (has-bot (>= rows 8))
         (trans-rows (+ 2 (if has-mid 1 0) (if has-bot 1 0))))
    (etaf-view
     (column :ref 'yt-cinema-deck :width 'stretch :height (list 'lh trans-rows)
             :item-gap '(lh 0)
             :background-color (etaf-youtube-color :panel2 mode)
             :border-top (etaf-youtube--watch-border (etaf-youtube-color :line mode))
       ;; Row 1: Full-width Interactive Hairline Seek Bar
       (box :width 'stretch :height '(lh 1)
            :padding (list '(lh 0) (list 'ch hpad-cols))
         (box :width (list 'px (max 60 (- px-w (* 2 hpad-cols cw)))) :height '(lh 1)
           (etaf-range :min 0 :max 100 :bar-height 22
                       :value progress-ref
                       :fill-ref progress-fill-ref
                       :ref (or progress-id 'yt-cinema-progress)
                       :color (etaf-youtube-color :accent mode)
                       :track-color (etaf-youtube-color :panel3 mode)
                       :label "拖动或点击进度条跳转"
                       :on-commit on-seek)))
       ;; Optional middle breathing row in Fullscreen (matches normal Watch spacing)
       (box :if has-mid :width 'stretch :height '(lh 1))
       ;; Controls Row
       (flex :width 'stretch :height '(lh 1) :align-items 'center
             :padding-left (list 'ch ctrl-pad-cols)
             :padding-right (list 'ch right-pad-cols)
             :gap (if mini '((lh 0) (ch 0)) '((lh 0) (ch 1)))
         (flex :height '(lh 1) :align-items 'center :flex-shrink 0 :gap '((lh 0) (ch 0))
           (etaf-youtube--watch-chip :ref 'yt-cinema-prev :mode mode :icon 'previous
                                     :help "上一条视频 (P / <)" :on-press on-prev)
           (box :ref 'yt-cinema-play :id "yt-cinema-play"
                :width '(ch 3) :height '(lh 1)
                :flex-shrink 0 :role 'button :tab-index 0 :pointer 'hand
                :background-color (etaf-youtube-color :accent mode) :color "#FFFFFF"
                :font-weight 'bold :help-echo "播放 / 暂停 (SPC / k)"
                :on-press on-toggle
             (etaf-ui-icon :name (if playing 'pause 'play) :set 'svg :size 0.85
                           :min-width 3 :color "#FFFFFF"))
           (etaf-youtube--watch-chip :ref 'yt-cinema-next :mode mode :icon 'next
                                     :help "下一条视频 (N / >)" :on-press on-next))
         (flex :if (and cinema on-vol-delta) :height '(lh 1) :align-items 'center
               :flex-shrink 0 :background-color (etaf-youtube-color :panel3 mode)
           (etaf-youtube--watch-chip :mode mode :label "−" :help "降低音量 ([ / ↓)"
                                     :on-press (lambda () (funcall on-vol-delta -5)))
           (etaf-youtube--watch-chip :ref 'yt-cinema-mute :mode mode
                                     :label (if muted "× 静音" (format "♪ %3d%%" vol))
                                     :active muted
                                     :accent-color (unless muted (etaf-youtube-color :ink mode))
                                     :help "静音 (m) · 音量 [ / ]"
                                     :on-press on-toggle-mute)
           (etaf-youtube--watch-chip :mode mode :label "+" :help "提高音量 (] / ↑)"
                                     :on-press (lambda () (funcall on-vol-delta 5))))
         (etaf-youtube--watch-chip :if (and (not mini) (not (and cinema on-vol-delta)))
                                   :ref 'yt-cinema-mute :mode mode
                                   :label (if muted "× 静音" (format "♪ %d%%" vol))
                                   :active muted
                                   :accent-color (unless muted (etaf-youtube-color :ink mode))
                                   :help "静音 (m) · 音量 [ / ]"
                                   :on-press on-toggle-mute)
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
              :height '(lh 1) :text-align 'center :overflow 'hidden :wrap-mode 'none
              :color (etaf-youtube-color (if loading-p :accent :muted) mode)
           (text :ref time-ref :id (symbol-name time-ref)
             (expr time-text)))
         (etaf-youtube--watch-chip :if mini :ref 'yt-cinema-mute :mode mode
                                   :label (if muted "×" "♪")
                                   :active muted
                                   :accent-color (unless muted (etaf-youtube-color :ink mode))
                                   :help "静音 (m) · 音量 [ / ]"
                                   :on-press on-toggle-mute)
         (etaf-youtube--watch-chip :if (and cinema quality-label on-open-quality)
                                   :ref 'yt-cinema-quality :mode mode
                                   :label quality-label
                                   :accent-color (etaf-youtube-color :accent mode)
                                   :help "切换画质与线路 (Q)"
                                   :on-press on-open-quality)
         (etaf-youtube--watch-chip :if (not mini) :ref 'yt-cinema-speed :mode mode
                                   :label (format "%gx" spd) :active (/= spd 1)
                                   :help "切换倍速 (+ / -)" :on-press on-cycle-speed)
         (etaf-youtube--watch-chip :if (not mini) :ref 'yt-cinema-cc :mode mode
                                   :label "CC" :active cc-on
                                   :help "开关字幕 (c)" :on-press on-toggle-cc))
       ;; Bottom Row: Exact 1-row bottom breathing cushion
       (box :if has-bot :width 'stretch :height '(lh 1))))))

;;; ---------------------------------------------------------------------------
;;; Top-Level Watch View
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-youtube--watch-view (&key model mode viewport)
  "Full-screen Watch View with Retained Host HUD and zero-restart Fullscreen."
  :render
  (let* ((width-px (max 320 (or (nth 0 viewport) 1040)))
         (total-rows (max 10 (or (nth 1 viewport) 40)))
         (cw (max 1 (or (nth 2 viewport) 7)))
         (lh (max 1 (or (nth 3 viewport) 16)))
         (fs-mode (etaf-value (plist-get model :fullscreen)))
         (fullscreen (and fs-mode t))
         (total-cols (max (if fullscreen 24 48) (floor width-px cw)))
         (theater (etaf-value (plist-get model :theater)))
         (show-side (and (>= total-cols 116) (not theater) (not fullscreen)))
         (compact (< total-cols 96))
         (side-cols (cond ((not show-side) 0)
                          ((>= total-cols 136) 42)
                          (t 38)))
         (left-cols (- total-cols side-cols))
         (video (etaf-value (plist-get model :video)))
         (media (etaf-value (plist-get model :media)))
         (media-status (etaf-value (plist-get model :media-status)))
         (media-src (etaf-youtube-media-src model))
         (playing (etaf-value (plist-get model :playing)))
         (buffering (etaf-value (plist-get model :buffering)))
         (has-frame (etaf-value (plist-get model :has-frame)))
         (play-err (etaf-value (plist-get model :play-error)))
         (audio-only (etaf-value (plist-get model :audio-only)))
         (pip-active (and (etaf-value (plist-get model :pip-active)) t))
         (muted (etaf-value (plist-get model :muted)))
         (vol (etaf-value (plist-get model :volume)))
         (spd (etaf-value (plist-get model :speed)))
         (cap-on (etaf-value (plist-get model :captions-on)))
         (q-open (etaf-value (plist-get model :quality-menu)))
         (drawer-open (plist-get model :watch-drawer))
         (like-status (or (plist-get video :like_status) "INDIFFERENT"))
         (is-liked (equal like-status "LIKE"))
         (is-disliked (equal like-status "DISLIKE"))
         (is-sub (eq t (plist-get video :subscribed)))
         (channel-id (etaf-youtube--nonempty-string (plist-get video :channel_id)))
         (author (or (plist-get video :author) ""))
         (author-init (let ((tr (string-trim author)))
                        (if (string-empty-p tr) "?" (upcase (substring tr 0 (min 2 (length tr)))))))
         (subs-text (or (plist-get video :subscribers) ""))
         (header-rows (if fullscreen 1 3))
         (top-strip-rows (cond (fullscreen 0)
                               ((>= total-rows 32) 3)
                               (t 1)))
         (body-rows (max 8 (- total-rows header-rows)))
         (sub-rows (if fullscreen
                       (if (and cap-on (>= total-rows 9)) 1 0)
                     1))
         (trans-pad-top (and (not fullscreen) (>= total-rows 36)))
         (trans-gap-mid (and (not fullscreen) (>= total-rows 24)))
         (trans-pad-bottom (and (not fullscreen) (>= total-rows 30)))
         (trans-rows (if fullscreen
                         (+ 2 (if (>= total-rows 14) 1 0)
                            (if (>= total-rows 8) 1 0))
                       (+ 2 (if trans-pad-top 1 0)
                          (if trans-gap-mid 1 0)
                          (if trans-pad-bottom 1 0))))
         (dur-sec (max (or (plist-get media :duration) 0)
                       (or (plist-get video :duration) 0)
                       (or (plist-get model :live-duration) 0)))
         (clock-w (if (>= dur-sec 3600) 7 5))
         (range-w (max 8 (- left-cols (+ 8 (* 2 clock-w)))))
         (stage-rows (max 4 (- body-rows top-strip-rows sub-rows trans-rows)))
         (stage-cols (if fullscreen left-cols (max 20 (- left-cols 2))))
         (canvas-size (etaf-youtube--watch-canvas-fit
                       media stage-cols stage-rows cw lh))
         (q-label (or (plist-get media :quality_label)
                      (when-let* ((h (or (plist-get media :height)
                                         (etaf-value (plist-get model :quality)))))
                        (format "%dp" h))
                      "720p"))
         (err-text (or play-err
                       (and (eq (plist-get media-status :state) 'error)
                            (or (plist-get media-status :message) "播放源解析失败"))))
         (awaiting-frame (and (not err-text) (not audio-only) (not pip-active)
                              (or (null media-src) (not has-frame))))
         (loading-p (and (not err-text) (not audio-only) (not pip-active)
                         (or awaiting-frame buffering)))
         (poster-img
          (when awaiting-frame
            (etaf-value (etaf-youtube-images-version (plist-get model :images)))
            (let ((url (or (etaf-value (plist-get model :poster-url))
                           (plist-get video :thumbnail))))
              (and url (etaf-youtube-images-descriptor
                        (plist-get model :images) url)))))
         (pill-cols (min (max 24 (- left-cols 6)) 36))
         (pill-h (if (>= stage-rows 5) 3 1))
         (pill-left (max 1 (/ (- left-cols pill-cols) 2)))
         (pill-top (max 0 (/ (- stage-rows pill-h) 2)))
         (init-status (or (plist-get model :live-status-text)
                          (and loading-p "⠋ 缓冲中…")
                          ""))
         (init-spinner (or (and (stringp (plist-get model :live-spinner-text))
                                (not (string-empty-p (plist-get model :live-spinner-text)))
                                (plist-get model :live-spinner-text))
                           "⠋ 正在缓冲…"))
         (show-engage (>= left-cols 76))
         (time-str (or (plist-get model :live-time-text) "00:00"))
         (dur-str (or (plist-get model :live-duration-text) "00:00"))
         (cinema-time-txt
          (cond (loading-p (if (< total-cols 44) "···" "··· 缓冲中"))
                ((>= total-cols 52) (format "%s / %s" time-str dur-str))
                ((>= total-cols 30) time-str)
                (t ""))))
    (etaf-view
     (column :ref 'yt-watch-shell :position 'relative
             :width 'stretch :height 'stretch
             :item-gap '(lh 0) :overflow 'hidden
             :background-color (etaf-youtube-color :panel2 mode)
             :color (etaf-youtube-color :ink mode)
       ;; 1. Watch Header (Standard/Theater) OR Ultra-slim 1-row Cinema Top Bar (Fullscreen)
       (etaf-youtube--watch-header
        :if (not fullscreen)
        :model model :compact (not show-side) :mode mode :theater theater
        :height header-rows
        :on-drawer (lambda () (etaf-youtube--write model :watch-drawer t)))
       (etaf-youtube--cinema-topbar
        :if fullscreen
        :model model :cols total-cols :mode mode :fs-mode fs-mode
        :on-drawer (lambda () (etaf-youtube--write model :watch-drawer t))
        :on-toggle-frame (lambda () (etaf-youtube-toggle-fullscreen model 'frame))
        :on-toggle-pip #'etaf-youtube-toggle-pip-command
        :on-exit (lambda () (etaf-youtube-exit-fullscreen model)))
       ;; 2. Main Split Body (single stable mount path for <etaf-video> across all modes!)
       (flex :width 'stretch :height (list 'lh body-rows) :align-items 'stretch
         ;; Left Cinema Theater Column (flex-grow fills exact remaining pixels)
         (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                 :height (list 'lh body-rows)
                 :item-gap '(lh 0) :overflow 'hidden
                 :region (list :id etaf-youtube-region-content :label "视频剧场" :key ?c)
           ;; Creator & Engagement Strip (hidden in Fullscreen)
           (flex :if (not fullscreen)
                 :width 'stretch :height (list 'lh (max 1 top-strip-rows)) :align-items 'center
                 :padding '((lh 0) (ch 2)) :gap '((lh 0) (ch 1))
                 :background-color (etaf-youtube-color :surface mode)
                 :border-bottom (etaf-youtube--watch-border (etaf-youtube-color :line mode))
             (etaf-avatar :if (not (string-empty-p author)) :name author
                          :initials author-init :size '(ch 3) :lines 1
                          :background (etaf-youtube-color :accent mode))
             (box :flex-shrink 0 :height '(lh 1) :role 'button :tab-index 0
                  :color (etaf-youtube-color :ink mode) :font-weight 'bold
                  :pointer (when channel-id 'hand)
                  :hover-style (when channel-id (list :color (etaf-youtube-color :accent mode)))
                  :help-echo (when channel-id (format "进入频道：%s (u)" author))
                  :on-press (lambda ()
                              (when channel-id
                                (etaf-youtube-locate model 'channel (list :id channel-id))))
               (text (expr (if (string-empty-p author) "加载频道…" author))))
             (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :height '(lh 1) :overflow 'hidden :wrap-mode 'none
                  :color (etaf-youtube-color :dim mode)
               (text (expr (if (string-empty-p subs-text) "" (format "· %s" subs-text)))))
             ;; Retained Host status indicator (amber spinner while loading/buffering, green once presenting)
             (box :flex-shrink 0 :height '(lh 1)
                  :color (etaf-youtube-color (if loading-p :warn :ok) mode)
               (text :ref etaf-youtube--hud-status-ref
                     :id (symbol-name etaf-youtube--hud-status-ref)
                 (expr init-status)))
             ;; Engagement actions (like/unrate, dislike/unrate, subscribe/unsub, save)
             (etaf-youtube--watch-chip
              :if show-engage :mode mode
              :label (format "♥ %s" (or (etaf-youtube--nonempty-string (plist-get video :likes)) "赞"))
              :active is-liked
              :help (if is-liked "取消点赞" "点赞视频")
              :on-press (lambda ()
                          (etaf-youtube--confirm-action
                           (if is-liked "确认取消点赞？" "确认点赞此视频？")
                           (lambda ()
                             (if is-liked
                                 (etaf-youtube-unrate model t)
                               (etaf-youtube-like model t))))))
             (etaf-youtube--watch-chip
              :if show-engage :mode mode :width '(ch 6)
              :label (if is-disliked "▼ 踩" "▽ 踩")
              :active is-disliked
              :help (if is-disliked "取消点踩" "点踩视频")
              :on-press (lambda ()
                          (etaf-youtube--confirm-action
                           (if is-disliked "确认取消点踩？" "确认点踩此视频？")
                           (lambda ()
                             (if is-disliked
                                 (etaf-youtube-unrate model t)
                               (etaf-youtube-dislike model t))))))
             (etaf-youtube--watch-chip
              :if (and show-engage channel-id) :mode mode :width '(ch 11)
              :label (if is-sub "✓ 已订阅" "+ 订阅")
              :active is-sub :soft (not is-sub)
              :accent-color (unless is-sub (etaf-youtube-color :accent mode))
              :help (if is-sub "取消订阅此频道" "订阅此频道")
              :on-press (lambda ()
                          (etaf-youtube--confirm-action
                           (if is-sub (format "确认取消订阅 %s？" author)
                             (format "确认订阅频道 %s？" author))
                           (lambda ()
                             (etaf-youtube-subscribe model (not is-sub) t)))))
             (etaf-youtube--watch-chip
              :if show-engage :mode mode
              :label "+ 稍后" :help "保存到稍后观看 (WL)"
              :on-press (lambda ()
                          (etaf-youtube--confirm-action
                           "确认保存到「稍后观看」？"
                           (lambda () (etaf-youtube-save model "WL" t))))))

           ;; Pure Dark Cinema Stage (#050608 in both Dark & Light modes)
           (flex :ref 'yt-watch-stage :position 'relative
                 :width 'stretch :height (list 'lh stage-rows)
                 :align-items 'center :justify-content 'center
                 :background-color (etaf-youtube-color :scrim mode)
                 :overflow 'hidden
                 :on-press (lambda () (etaf-youtube-toggle-playback model))
             ;; Error Recovery Card
             (column :if err-text :width (list 'ch (min 62 (- left-cols 4)))
                     :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :background-color (etaf-youtube-color :danger-bg mode)
                     :border (etaf-youtube--watch-border (etaf-youtube-color :danger mode))
               (text :color (etaf-youtube-color :danger mode) :font-weight 'bold
                 (expr (format "播放异常：%s" err-text)))
               (flex :gap '((lh 0) (ch 2))
                 (etaf-button :label "刷新重试" :variant 'primary
                              :on-press (lambda () (etaf-youtube--failover-stream model)))
                 (etaf-button :label "外部 mpv (o)" :variant 'secondary
                              :on-press #'etaf-youtube-open-external)
                 (etaf-button :label "浏览器 (O)" :variant 'ghost
                              :on-press #'etaf-youtube-open-in-browser)))
             ;; Audio-only Card
             (column :if (and (not err-text) audio-only)
                     :width (list 'ch (min 56 (- left-cols 4)))
                     :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :cross-align 'center
                     :background-color (etaf-youtube-color :panel2 mode)
                     :border (etaf-youtube--watch-border (etaf-youtube-color :accent mode))
               (text :color (etaf-youtube-color :accent mode) :font-weight 'bold
                 "♫ 纯音频后台模式（零视频解码 CPU）")
               (text :color (etaf-youtube-color :ink mode)
                 (expr (etaf-youtube--watch-truncate (or (plist-get video :title) "") 48)))
               (text :color (etaf-youtube-color :muted mode)
                 "按 b 返回列表或切去写代码，声音继续播放；按 A 恢复画面"))
             ;; Floating PiP Placeholder Card
             (column :if (and (not err-text) (not audio-only) pip-active)
                     :width (list 'ch (min 56 (- left-cols 4)))
                     :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :cross-align 'center
                     :background-color (etaf-youtube-color :panel2 mode)
                     :border (etaf-youtube--watch-border (etaf-youtube-color :accent mode))
               (text :color (etaf-youtube-color :accent mode) :font-weight 'bold
                 "📺 正在悬浮画中画中播放")
               (text :color (etaf-youtube-color :ink mode)
                 (expr (etaf-youtube--watch-truncate (or (plist-get video :title) "") 48)))
               (text :color (etaf-youtube-color :muted mode)
                 "按 b 可继续浏览主页或切去写代码；拖拽画中画边框可自由缩放")
               (flex :gap '((lh 0) (ch 2))
                 (etaf-button :label "回到主画面 (v)" :variant 'primary
                              :on-press (lambda () (etaf-youtube--pip-return model)))
                 (etaf-button :label "关闭画中画" :variant 'secondary
                              :on-press (lambda () (etaf-youtube--pip-close model t)))))
             ;; Live etaf-video Canvas (stays mounted across seek/rebuffering)
             (etaf-video :if (and (not err-text) (not audio-only) (not pip-active) media-src)
                         :src media-src
                         :columns (car canvas-size)
                         :rows (cdr canvas-size)
                         :handle (plist-get model :player-handle)
                         :audio (plist-get model :audio-on)
                         :volume (plist-get model :volume)
                         :speed (plist-get model :speed)
                         :autoplay t)
             ;; Cached thumbnail poster overlay while resolving or decoding first frame
             (flex :if (and awaiting-frame poster-img)
                   :position 'absolute :z-index 4
                   :left '(px 0) :top '(lh 0)
                   :width 'stretch :height (list 'lh stage-rows)
                   :align-items 'center :justify-content 'center
                   :background-color (etaf-youtube-color :scrim mode)
               (image :src poster-img
                      :columns (car canvas-size)
                      :rows (cdr canvas-size)))
             ;; Compact floating animated spinner pill (resolving, first-frame, seek & rebuffering)
             (flex :if loading-p :ref 'yt-watch-loading-pill
                   :position 'absolute :z-index 5
                   :left (list 'ch pill-left) :top (list 'lh pill-top)
                   :width (list 'ch pill-cols) :height (list 'lh pill-h)
                   :align-items 'center :justify-content 'center
                   :padding '((lh 0) (ch 2))
                   :background-color "#12151E"
                   :border (etaf-youtube--watch-border "#2B3245")
                   :color "#F1F3F8"
               (text :ref etaf-youtube--hud-spinner-ref
                     :id (symbol-name etaf-youtube--hud-spinner-ref)
                     :font-weight 'bold
                 (expr init-spinner))))

           ;; 1-Row Cinema-Integrated Retained Host Subtitle Strip (hidden when CC off in Fullscreen)
           (box :if (> sub-rows 0) :width 'stretch :height '(lh 1) :padding '((lh 0) (ch 2))
                :text-align 'center :overflow 'hidden :wrap-mode 'none
                :background-color "#080A0F" :color "#F4F6FA"
             (text :ref etaf-youtube--hud-subtitle-ref
                   :id (symbol-name etaf-youtube--hud-subtitle-ref)
               (expr (or (plist-get model :live-subtitle-text) ""))))

           ;; Pure Fullscreen Transport Deck (100% shared component with PiP!)
           (etaf-youtube--cinema-deck
            :if fullscreen
            :px-w width-px :cols total-cols :rows total-rows :cw cw :gap-mid t :mode mode
            :playing playing :loading-p loading-p
            :muted muted :vol vol :spd spd :cc-on cap-on
            :quality-label q-label
            :progress-ref (plist-get model :progress-ref)
            :progress-fill-ref etaf-youtube--hud-progress-fill-ref
            :progress-id 'yt-watch-progress
            :time-ref etaf-youtube--hud-cinema-time-ref
            :time-text cinema-time-txt
            :on-seek (lambda (pct)
                       (let ((dur (max (or (plist-get model :live-duration) 0)
                                       (or (etaf-value (plist-get model :duration)) 0))))
                         (when (> dur 0)
                           (etaf-youtube-seek model (* dur (/ pct 100.0))))))
            :on-toggle (lambda () (etaf-youtube-toggle-playback model))
            :on-prev (lambda () (etaf-youtube--step-queue model -1))
            :on-next (lambda () (etaf-youtube--step-queue model 1))
            :on-toggle-mute (lambda () (etaf-youtube-toggle-mute model))
            :on-vol-delta (lambda (d) (etaf-youtube-set-volume model (+ vol d)))
            :on-cycle-speed (lambda () (etaf-youtube--cycle-speed model))
            :on-open-quality (lambda () (etaf-youtube--write model :quality-menu t))
            :on-toggle-cc (lambda () (etaf-youtube--cycle-captions model)))

           ;; De-boxed Studio Transport Deck (Standard & Theater Watch)
           (column :if (not fullscreen)
                   :width 'stretch :height (list 'lh trans-rows) :item-gap '(lh 0)
                   :padding '((lh 0) (ch 2))
                   :background-color (etaf-youtube-color :panel2 mode)
                   :border-top (etaf-youtube--watch-border (etaf-youtube-color :line mode))
             (box :if trans-pad-top :width 'stretch :height '(lh 1))
             ;; Row 1: Elapsed | Hairline Seek Bar | Duration
             (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 2))
               (box :width (list 'ch clock-w) :height '(lh 1) :flex-shrink 0
                    :color (etaf-youtube-color :ink mode)
                 (text :ref etaf-youtube--hud-time-ref
                       :id (symbol-name etaf-youtube--hud-time-ref)
                       :font-weight 'bold
                   (expr (or (plist-get model :live-time-text) "00:00"))))
               (box :width (list 'ch range-w) :height '(lh 1) :overflow 'hidden
                 (etaf-range :min 0 :max 100 :bar-height 22
                             :value (plist-get model :progress-ref)
                             :fill-ref etaf-youtube--hud-progress-fill-ref
                             :ref 'yt-watch-progress
                             :color (etaf-youtube-color :accent mode)
                             :track-color (etaf-youtube-color :panel3 mode)
                             :label "拖动或点击进度条跳转"
                             :on-commit (lambda (pct)
                                          (let ((dur (max (or (plist-get model :live-duration) 0)
                                                          (or (etaf-value (plist-get model :duration)) 0))))
                                            (when (> dur 0)
                                              (etaf-youtube-seek model (* dur (/ pct 100.0))))))))
               (box :width (list 'ch clock-w) :height '(lh 1) :flex-shrink 0 :text-align 'right
                    :color (etaf-youtube-color :dim mode)
                 (text :ref etaf-youtube--hud-duration-ref
                       :id (symbol-name etaf-youtube--hud-duration-ref)
                   (expr (or (plist-get model :live-duration-text) "00:00")))))
             (box :if trans-gap-mid :width 'stretch :height '(lh 1))
             ;; Row 2: Borderless Grouped Controls (zero emoji, equal-width states)
             (flex :width 'stretch :height '(lh 1) :align-items 'center :gap '((lh 0) (ch 1))
               (box :ref 'yt-watch-play :width '(ch 3) :height '(lh 1)
                    :flex-shrink 0 :role 'button :tab-index 0 :pointer 'hand
                    :background-color (etaf-youtube-color :accent mode) :color "#FFFFFF"
                    :font-weight 'bold :help-echo "播放 / 暂停 (SPC / k)"
                    :on-press (lambda () (etaf-youtube-toggle-playback model))
                 (etaf-ui-icon :name (if playing 'pause 'play) :set 'svg :size 0.85
                               :min-width 3 :color "#FFFFFF"))
               (etaf-youtube--watch-chip
                :mode mode :icon 'previous :help "上一条 (P)"
                :on-press (lambda () (etaf-youtube--step-queue model -1)))
               (etaf-youtube--watch-chip
                :mode mode :icon 'next :help "下一条 (N)"
                :on-press (lambda () (etaf-youtube--step-queue model 1)))
               (etaf-youtube--watch-chip
                :mode mode :width '(ch 9)
                :label (if muted "× 静音" (format "♪ %3d%%" vol))
                :active muted
                :help "静音 (m) · 音量 [ / ] 或 ↑ / ↓"
                :on-press (lambda () (etaf-youtube-toggle-mute model)))
               (box :flex-grow 1 :flex-basis '(ch 0))
               (etaf-youtube--watch-chip
                :ref 'yt-watch-quality :mode mode :label q-label
                :accent-color (etaf-youtube-color :accent mode)
                :help "切换画质与线路 (Q)"
                :on-press (lambda () (etaf-youtube--write model :quality-menu t)))
               (etaf-youtube--watch-chip
                :mode mode :label (format "%gx" spd)
                :active (/= spd 1)
                :help "切换倍速 (+ / -)"
                :on-press (lambda () (etaf-youtube--cycle-speed model)))
               (etaf-youtube--watch-chip
                :mode mode :label "CC" :active cap-on
                :help "开关 / 切换字幕 (c)"
                :on-press (lambda () (etaf-youtube--cycle-captions model)))
               (box :if (not compact) :width '(ch 1) :height '(lh 1)
                    :color (etaf-youtube-color :line mode)
                 (text "│"))
               (etaf-youtube--watch-chip
                :if (not compact) :mode mode :label "听" :active audio-only
                :help "纯音频后台模式 (A)"
                :on-press (lambda () (etaf-youtube--toggle-audio-only model)))
               (etaf-youtube--watch-chip
                :ref 'yt-watch-fullscreen :mode mode :label "全屏"
                :help "纯净全屏 (f 网页全屏 / F 系统真全屏)"
                :on-press (lambda () (etaf-youtube-toggle-fullscreen model 'window)))
               (etaf-youtube--watch-chip
                :if (not compact) :mode mode :label "PiP" :active pip-active
                :help "悬浮画中画 (v)"
                :on-press #'etaf-youtube-toggle-pip-command)
               (etaf-youtube--watch-chip
                :mode mode :label "mpv" :help "外部 mpv 播放当前进度 (o)"
                :on-press #'etaf-youtube-open-external))
             (box :if trans-pad-bottom :width 'stretch :height '(lh 1))))

         ;; Right 5-Tab Workbench (Wide Mode)
         (box :if show-side :width (list 'ch side-cols) :flex-shrink 0
              :height (list 'lh body-rows)
              :border-left (etaf-youtube--watch-border (etaf-youtube-color :line mode))
           (etaf-youtube--watch-workbench
            :model model :width (1- side-cols) :height body-rows
            :tab-height top-strip-rows :mode mode)))

       ;; Narrow / Theater Drawer
       (etaf-drawer :open drawer-open :title "视频工作台" :width '(ch 44)
                    :on-close (lambda () (etaf-youtube--write model :watch-drawer nil))
         (etaf-youtube--watch-workbench
          :model model :width 40 :height (max 16 (- total-rows 6))
          :tab-height 1 :mode mode
          :on-close-drawer (lambda () (etaf-youtube--write model :watch-drawer nil))))

       ;; Quality & Engine Dialog (`Q')
       (etaf-dialog :open q-open :title "画质与解码线路" :width '(ch 50)
                    :close-label nil
                    :on-close (lambda () (etaf-youtube--write model :quality-menu nil))
         (expr
          (let* ((streams (plist-get media :streams))
                 (cur-h (plist-get media :height))
                 (cur-proto (plist-get media :protocol))
                 (eng (or (plist-get model :live-engine)
                          (if (and (fboundp 'etaf-video-mpv-available-p)
                                   (etaf-video-mpv-available-p))
                              'mpv 'ffmpeg))))
            (etaf-node
             'column (list :width 'stretch :item-gap '(lh 1))
             (append
              (list
               (etaf-node 'text (list :color (etaf-youtube-color :dim mode))
                          (list (format "当前解码引擎：%s · 切换画质将保持当前播放秒数续播"
                                        (cond
                                         ((and (eq eng 'mpv)
                                               (fboundp 'etaf-video-gpu-available-p)
                                               (etaf-video-gpu-available-p))
                                          "libmpv 原生 GPU 零拷贝")
                                         ((eq eng 'mpv) "libmpv 硬件加速")
                                         (t "ffmpeg 兼容管线"))))))
              (if streams
                  (mapcar
                   (lambda (st)
                     (let* ((sh (plist-get st :height))
                            (active (equal sh cur-h))
                            (sw (plist-get st :width))
                            (sfps (plist-get st :fps))
                            (spec (string-join
                                   (delq nil
                                         (list (when (and (numberp sw) (numberp sh))
                                                 (format "%dx%d" sw sh))
                                               (when (and (numberp sfps) (>= sfps 45))
                                                 (format "%dfps" (round sfps)))
                                               (plist-get st :codec_label)
                                               (plist-get st :protocol)))
                                   " · ")))
                       (etaf-node
                        'flex
                        (list :width 'stretch :height '(lh 1) :align-items 'center
                              :justify-content 'space-between :padding '((lh 0) (ch 1))
                              :role 'button :tab-index 0
                              :background-color (when active (etaf-youtube-color :accent-soft mode))
                              :border-left (etaf-youtube--watch-border
                                            (etaf-youtube-color (if active :accent :panel2) mode))
                              :pointer (unless active 'hand)
                              :on-press (lambda () (etaf-youtube--select-stream model st)))
                        (list
                         (etaf-node
                          'flex (list :height '(lh 1) :align-items 'center)
                          (list
                           (etaf-node 'box (list :width '(ch 3) :flex-shrink 0
                                                 :color (etaf-youtube-color (if active :accent :dim) mode))
                                      (list (etaf-node 'text nil (list (if active "●" "○")))))
                           (etaf-node 'box (list :height '(lh 1)
                                                 :color (etaf-youtube-color (if active :accent :ink) mode)
                                                 :hover-style (unless active
                                                                (list :color (etaf-youtube-color :accent mode))))
                                      (list (etaf-node 'text nil
                                                       (list (or (plist-get st :label)
                                                                 (format "%dp" sh))))))))
                         (etaf-node 'text (list :color (etaf-youtube-color (if active :accent :dim) mode))
                                    (list spec))))))
                   streams)
                ;; Fallback quality list when using simple fixture without :streams
                (mapcar
                 (lambda (q)
                   (let ((active (equal q (etaf-value (plist-get model :quality)))))
                     (etaf-node
                      'flex (list :width 'stretch :height '(lh 1) :align-items 'center
                                  :padding '((lh 0) (ch 1))
                                  :role 'button :tab-index 0
                                  :background-color (when active (etaf-youtube-color :accent-soft mode))
                                  :border-left (etaf-youtube--watch-border
                                                (etaf-youtube-color (if active :accent :panel2) mode))
                                  :color (etaf-youtube-color (if active :accent :ink) mode)
                                  :pointer (unless active 'hand)
                                  :on-press (lambda ()
                                              (etaf-youtube--write model :quality-menu nil)
                                              (etaf-youtube-set-quality model q)))
                      (list
                       (etaf-node 'box (list :width '(ch 3) :flex-shrink 0
                                             :color (etaf-youtube-color (if active :accent :dim) mode))
                                  (list (etaf-node 'text nil (list (if active "●" "○")))))
                       (etaf-node 'text nil (list (format "%dp (%s)" q (or cur-proto ""))))))))
                 (etaf-youtube-quality-choices model)))))))
         (slot :name 'footer
           (flex :width 'stretch :justify-content 'space-between :gap '((lh 0) (ch 1))
             (etaf-button :label "刷新 / 切换备用线路" :variant 'secondary
                          :on-press (lambda () (etaf-youtube--failover-stream model)))
             (etaf-button :label "外部 mpv (o)" :variant 'ghost
                          :on-press #'etaf-youtube-open-external)
             (etaf-button :label "关闭" :variant 'ghost
                          :on-press (lambda () (etaf-youtube--write model :quality-menu nil))))))))))

;;; ---------------------------------------------------------------------------
;;; Floating Adaptive Picture-in-Picture (PiP) View
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--pip-canvas-fit (media cols rows cw lh)
  "Fit MEDIA aspect inside COLS by ROWS without clamping over ROWS."
  (let* ((w (float (max 1 (or (and media (plist-get media :width)) 16))))
         (h (float (max 1 (or (and media (plist-get media :height)) 9))))
         (aspect (/ w h))
         (avail-px (float (max cw (* cols cw))))
         (avail-py (float (max lh (* rows lh))))
         (fit-py (min avail-py (/ avail-px aspect)))
         (crows (max 1 (min rows (floor fit-py lh))))
         (fit-px (min avail-px (* crows lh aspect)))
         (ccols (max 4 (min cols (round (/ fit-px cw))))))
    (cons ccols crows)))

(etaf-define-component etaf-youtube--pip-view (&key model)
  "Adaptive floating Picture-in-Picture player for YouTube."
  :render
  (let* ((mode (or (etaf-value (plist-get model :theme-mode)) etaf-youtube-theme-mode))
         (bounds (or (etaf-pip-bounds etaf-youtube--pip-id)
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
         (media (etaf-value (plist-get model :media)))
         (media-src (etaf-youtube-media-src model))
         (media-status (etaf-value (plist-get model :media-status)))
         (playing (etaf-value (plist-get model :playing)))
         (buffering (etaf-value (plist-get model :buffering)))
         (has-frame (etaf-value (plist-get model :has-frame)))
         (play-err (etaf-value (plist-get model :play-error)))
         (err-text (or play-err
                       (and (eq (plist-get media-status :state) 'error)
                            (or (plist-get media-status :message) "播放源解析失败"))))
         (loading-p (and (not err-text) (or (null media-src) (not has-frame) buffering)))
         (muted (etaf-value (plist-get model :muted)))
         (vol (or (etaf-value (plist-get model :volume)) 100))
         (spd (or (etaf-value (plist-get model :speed)) 1))
         (cap-on (and (etaf-value (plist-get model :captions-on)) t))
         (pip-cc (and (etaf-value (plist-get model :pip-cc)) t))
         (show-cc (and (or cap-on pip-cc) (>= rows 9)))
         (trans-rows (if (>= rows 8) 3 2))
         (vrows (max 2 (- rows (if show-cc 1 0) trans-rows)))
         (canvas (etaf-youtube--pip-canvas-fit media cols vrows cw lh))
         (vpad-top (max 0 (/ (- vrows (cdr canvas)) 2)))
         (vpad-bot (max 0 (- vrows (cdr canvas) vpad-top)))
         (time-str (or (plist-get model :live-time-text) "00:00"))
         (dur-str (or (plist-get model :live-duration-text) "00:00"))
         (time-txt (cond (loading-p (if mini "···" "··· 缓冲中"))
                         (full-time (format "%s / %s" time-str dur-str))
                         (show-time time-str)
                         (t "")))
         (sub-str (or (plist-get model :live-subtitle-text) ""))
         (on-toggle (lambda () (etaf-youtube-toggle-playback model)))
         (on-prev (lambda () (etaf-youtube--step-queue model -1)))
         (on-next (lambda () (etaf-youtube--step-queue model 1))))
    (etaf-view
     (column :width (list 'px px-w) :height (list 'lh rows)
             :item-gap '(lh 0) :overflow 'hidden
             :background-color (etaf-youtube-color :scrim mode)
             :color (etaf-youtube-color :ink mode)
             :keys (list (list "SPC" on-toggle "播停")
                         (list "k" on-toggle "播停")
                         (list "P" on-prev "上一条视频")
                         (list "<" on-prev "上一条视频")
                         (list "N" on-next "下一条视频")
                         (list ">" on-next "下一条视频")
                         (list "j" (lambda () (etaf-youtube-seek-by model -10)) "快退 10 秒")
                         (list "l" (lambda () (etaf-youtube-seek-by model 10)) "快进 10 秒")
                         (list "[" (lambda () (etaf-youtube-set-volume model (- vol 10))) "降低音量")
                         (list "]" (lambda () (etaf-youtube-set-volume model (+ vol 10))) "提高音量")
                         (list "m" (lambda () (etaf-youtube-toggle-mute model)) "静音")
                         (list "+" (lambda () (etaf-youtube--step-speed model 1)) "加速")
                         (list "=" (lambda () (etaf-youtube--step-speed model 1)) "加速")
                         (list "-" (lambda () (etaf-youtube--step-speed model -1)) "减速")
                         (list "." (lambda () (etaf-youtube--cycle-speed model)) "切换倍速")
                         (list "c" (lambda ()
                                     (etaf-youtube--cycle-captions model)
                                     (etaf-youtube--write model :pip-cc
                                                          (and (etaf-youtube--read model :captions-on) t)))
                               "开关字幕")
                         (list "s" (lambda () (etaf-pip-cycle-size etaf-youtube--pip-id)) "切换窗口大小")
                         (list "p" (lambda () (etaf-pip-cycle-corner etaf-youtube--pip-id)) "换角停靠")
                         (list "r" (lambda () (etaf-youtube--pip-return model)) "回主界面")
                         (list "b" (lambda () (etaf-youtube--pip-return model)) "回主界面")
                         (list "q" (lambda () (etaf-youtube--pip-close model t)) "关闭画中画")
                         (list "v" (lambda () (etaf-youtube--pip-close model t)) "关闭画中画"))
             :on-dismiss (lambda () (etaf-youtube--pip-close model t))
       ;; Adaptive Video Stage
       (column :width 'stretch :height (list 'lh vrows) :item-gap '(lh 0)
               :background-color (etaf-youtube-color :scrim mode)
               :overflow 'hidden
               :border-top (etaf-youtube--watch-border (etaf-youtube-color :line mode))
               :on-press on-toggle
         (box :if (and (not err-text) media-src (> vpad-top 0))
              :width 'stretch :height (list 'lh vpad-top)
              :background-color (etaf-youtube-color :scrim mode))
         (flex :width 'stretch
               :height (list 'lh (if (and (not err-text) media-src) (cdr canvas) vrows))
               :align-items 'center :justify-content 'center
               :background-color (if err-text
                                     (etaf-youtube-color :panel2 mode)
                                   (etaf-youtube-color :scrim mode))
               :overflow 'hidden
           (column :if err-text
                   :width (list 'ch (max 16 (- cols 6)))
                   :padding '((lh 1) (ch 2)) :item-gap '(lh 1) :cross-align 'center
                   :background-color (etaf-youtube-color :danger-bg mode)
                   :border (etaf-youtube--watch-border (etaf-youtube-color :danger mode))
             (text :color (etaf-youtube-color :danger mode) :font-weight 'bold
               (expr (etaf-youtube--watch-truncate (format "播放异常：%s" err-text) (max 10 (- cols 10)))))
             (etaf-button :label "刷新重试" :variant 'primary
                          :on-press (lambda () (etaf-youtube--failover-stream model))))
           (box :if (and (not err-text) (null media-src))
                :padding '((lh 0) (ch 1)) :color (etaf-youtube-color :muted mode)
             (text "··· 正在解析视频流…"))
           (etaf-video :if (and (not err-text) media-src)
                       :src media-src
                       :columns (car canvas) :rows (cdr canvas)
                       :handle (plist-get model :pip-handle)
                       :audio (plist-get model :audio-on)
                       :volume (plist-get model :volume)
                       :speed (plist-get model :speed)
                       :autoplay t))
         (box :if (and (not err-text) media-src (> vpad-bot 0))
              :width 'stretch :height (list 'lh vpad-bot)
              :background-color (etaf-youtube-color :scrim mode)))
       ;; Optional 1-row CC Subtitle Strip (auto-hidden when window is very short)
       (box :if show-cc :width 'stretch :height '(lh 1)
            :padding (list '(lh 0) (list 'ch hpad-cols)) :text-align 'center
            :overflow 'hidden :wrap-mode 'none
            :background-color "#080A0F" :color "#F4F6FA"
         (text :ref etaf-youtube--pip-subtitle-ref
               :id (symbol-name etaf-youtube--pip-subtitle-ref)
           (expr (if (string-empty-p sub-str) "" (concat "CC  " sub-str)))))
       ;; Shared Adaptive Transport Deck (reused 1:1 with Pure Fullscreen!)
       (etaf-youtube--cinema-deck
        :px-w px-w :cols cols :rows rows :cw cw :mode mode
        :playing playing :loading-p loading-p
        :muted muted :vol vol :spd spd :cc-on (or cap-on pip-cc)
        :progress-ref (plist-get model :progress-ref)
        :progress-fill-ref etaf-youtube--pip-progress-fill-ref
        :progress-id 'yt-pip-progress
        :time-ref etaf-youtube--pip-time-ref
        :time-text time-txt
        :on-seek (lambda (pct)
                   (let ((dur (max (or (plist-get model :live-duration) 0)
                                   (or (etaf-value (plist-get model :duration)) 0))))
                     (when (> dur 0)
                       (etaf-youtube-seek model (* dur (/ pct 100.0))))))
        :on-toggle on-toggle
        :on-prev on-prev :on-next on-next
        :on-toggle-mute (lambda () (etaf-youtube-toggle-mute model))
        :on-cycle-speed (lambda () (etaf-youtube--cycle-speed model))
        :on-toggle-cc (lambda ()
                        (etaf-youtube--cycle-captions model)
                        (etaf-youtube--write
                         model :pip-cc
                         (and (etaf-youtube--read model :captions-on) t))))))))

(provide 'etaf-youtube-watch)
;;; etaf-youtube-watch.el ends here
