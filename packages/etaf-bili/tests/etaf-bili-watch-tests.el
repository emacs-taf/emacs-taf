;;; etaf-bili-watch-tests.el --- Watch view, store, channels and cookie tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Offline public-API acceptance scenarios covering:
;; - Direct BV/av/URL target parsing
;; - Fail-open SQLite progress, preference and search-history persistence
;; - Pure subtitle binary search, danmaku windowing and timestamp extraction
;; - Bundled Node account backend `#HttpOnly_' cookie preservation
;; - Expanded channels (rcmd, ranking partitions, search sort, dynamic,
;;   toview, history, favorites, UP space) and deduplicated pagination
;; - Non-destructive Toast on play failure (preserving the gallery)
;; - Full Watch View lifecycle (quality dialog, theater, audio-only
;;   background mini-player, Org timestamp link)
;; - Mode-line preservation and live buffer reuse in `etaf-bili-open'
;; - Clean cancellation of in-flight covers on unmount + remount recovery

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-bili)

(defun etaf-bili-watch-tests--sample-rows (&optional prefix count)
  "Build COUNT fixture video rows with optional bvid PREFIX."
  (let ((pfx (or prefix "BV1watch"))
        (n (or count 4)))
    (cl-loop for i below n collect
             (list :bvid (format "%s%d" pfx i)
                   :aid (+ 1000 i)
                   :cid (+ 5000 i)
                   :mid (+ 8000 i)
                   :title (format "深度教程 %d · Emacs 视频体验" i)
                   :author (format "作者 %d" i)
                   :duration 600
                   :views "3.6 万"
                   :date "2026-10-20"
                   :videos (if (= i 0) 2 1)
                   :cover ""))))

(defun etaf-bili-watch-tests--sample-play (&optional bvid cid)
  "Build a pre-normalized fake `:play' payload for BVID and CID."
  (let ((bv (or bvid "BV1watch0"))
        (c (or cid 5000)))
    (list :kind 'url
          :url "https://cdn1.example.test/video.m4s"
          :backup-urls '("https://cdn2.example.test/video.m4s")
          :audio-url "https://cdn1.example.test/audio.m4s"
          :audio-backup-urls '("https://cdn2.example.test/audio.m4s")
          :headers '(("Referer" . "https://www.bilibili.com/")
                     ("User-Agent" . "TestAgent/1.0"))
          :bvid bv :aid 1000 :cid c :mid 8000
          :title "深度教程 0 · Emacs 视频体验"
          :author "作者 0"
          :desc "完整介绍如何用 ETAF 打造丝滑视频体验"
          :duration 600 :width 1920 :height 1080 :fps 30 :audio t
          :quality-id 80 :quality-label "1080P" :codec-label "H.264"
          :audio-id 30251 :audio-label "Hi-Res"
          :part-index 1 :part-title "开篇架构"
          :pages (list (list :page 1 :cid 5000 :part "开篇架构" :duration 600)
                       (list :page 2 :cid 5001 :part "实战演练" :duration 480))
          :streams (list (list :id 80 :label "1080P" :codec-label "H.264"
                               :url "https://cdn1.example.test/video.m4s"
                               :backup-urls '("https://cdn2.example.test/video.m4s")
                               :audio-url "https://cdn1.example.test/audio.m4s"
                               :width 1920 :height 1080 :fps 30 :bandwidth 2000000)
                         (list :id 64 :label "720P" :codec-label "H.264"
                               :url "https://cdn1.example.test/video720.m4s"
                               :audio-url "https://cdn1.example.test/audio.m4s"
                               :width 1280 :height 720 :fps 30 :bandwidth 1000000)))))

(ert-deftest etaf-bili-watch-tests-parse-target-bv-av-urls ()
  "Direct target parsing recognizes BV, av, bilibili.com URLs and b23.tv."
  (let ((bv (etaf-bili-parse-target "BV1xx411c7mD")))
    (should (equal "BV1xx411c7mD" (plist-get bv :bvid))))
  (let ((av (etaf-bili-parse-target "av170001")))
    (should (= 170001 (plist-get av :aid))))
  (let ((url (etaf-bili-parse-target
              "https://www.bilibili.com/video/BV1xx411c7mD?p=3&t=125")))
    (should (equal "BV1xx411c7mD" (plist-get url :bvid)))
    (should (= 3 (plist-get url :page)))
    (should (= 125 (plist-get url :start))))
  (let ((short (etaf-bili-parse-target "https://b23.tv/abc123")))
    (should (equal "https://b23.tv/abc123" (plist-get short :short-url))))
  (should-not (etaf-bili-parse-target "Emacs 配置教程")))

(ert-deftest etaf-bili-watch-tests-sqlite-store-progress-prefs-and-history ()
  "SQLite store persists resume points, prefs and deduplicated search history."
  (let* ((dir (make-temp-file "etaf-bili-store-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir)))
    (unwind-protect
        (progn
          ;; Progress round-trip & resume clamping rules
          (etaf-bili-store-progress-put "BV1abc" 99 124.5 600 "测试视频")
          (let ((saved (etaf-bili-store-progress-get "BV1abc" 99)))
            (should saved)
            (should (= 124.5 (car saved)))
            (should (= 600.0 (cdr saved))))
          (should (= 124.5 (etaf-bili-store-resume-seconds "BV1abc" 99 60 600)))
          (should (= 200.0 (etaf-bili-store-resume-seconds "BV1abc" 99 200 600)))
          ;; Under 5s or within 12s of end resets to 0
          (etaf-bili-store-progress-put "BV1early" 1 3.0 300 "刚开始")
          (should (= 0.0 (etaf-bili-store-resume-seconds "BV1early" 1 0 300)))
          (etaf-bili-store-progress-put "BV1end" 1 292.0 300 "快看完了")
          (should (= 0.0 (etaf-bili-store-resume-seconds "BV1end" 1 0 300)))
          ;; Preferences: booleans, numbers and lists
          (etaf-bili-store-pref-put 'audio nil)
          (should-not (etaf-bili-store-pref-get 'audio t))
          (etaf-bili-store-pref-put 'volume 75)
          (should (= 75 (etaf-bili-store-pref-get 'volume 100)))
          (etaf-bili-store-pref-put 'speed 1.25)
          (should (= 1.25 (etaf-bili-store-pref-get 'speed 1)))
          ;; Search history deduplication and max-12 cap
          (dotimes (i 15)
            (etaf-bili-store-search-history-add (format "词条 %d" i)))
          (etaf-bili-store-search-history-add "词条 10")
          (let ((hist (etaf-bili-store-search-history)))
            (should (= 12 (length hist)))
            (should (equal "词条 10" (car hist)))
            (should (= 1 (cl-count "词条 10" hist :test #'equal)))))
      (delete-directory dir t))))

(ert-deftest etaf-bili-watch-tests-subtitle-danmaku-and-timestamps ()
  "Subtitle search, danmaku windowing and comment timestamp extraction work."
  (let ((cues '((1.0 4.0 "第一句字幕")
                (6.0 10.0 "第二句字幕")
                (15.0 20.0 "第三句字幕"))))
    (should-not (etaf-bili-subtitle-at cues 0.5))
    (should (equal "第一句字幕" (etaf-bili-subtitle-at cues 2.5)))
    (should-not (etaf-bili-subtitle-at cues 5.0))
    (should (equal "第三句字幕" (etaf-bili-subtitle-at cues 18.0))))
  (let* ((dm '((:time 5.0 :text "太早了")
               (:time 19.0 :text "前方高能")
               (:time 20.2 :text "学到了")
               (:time 20.8 :text "三连支持")
               (:time 35.0 :text "太晚了")))
         (win (etaf-bili-danmaku-window dm 21.0 3.0 2)))
    (should (= 2 (length win)))
    (should (equal '("前方高能" "学到了")
                   (mapcar (lambda (d) (plist-get d :text)) win))))
  (let ((ts (etaf-bili-extract-timestamps "目录：00:45 介绍，02:15 实战，1:02:05 总结")))
    (should (equal '((45 . "00:45") (135 . "02:15") (3725 . "1:02:05")) ts))))

(ert-deftest etaf-bili-watch-tests-cookie-jar-preserves-httponly-sessdata ()
  "Bundled Node account backend parses and preserves `#HttpOnly_' Netscape cookies."
  (skip-unless (executable-find etaf-bili-node-program))
  (let* ((dir (make-temp-file "etaf-bili-jar-" t))
         (jar (expand-file-name "cookies.txt" dir))
         (script (expand-file-name "bili.mjs" etaf-bili-backend-directory)))
    (unwind-protect
        (progn
          (with-temp-file jar
            (insert "# Netscape HTTP Cookie File\n"
                    "#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t2147483647\tSESSDATA\tsecret_token\n"
                    "#HttpOnly_.example.test\tTRUE\t/\tTRUE\t2147483647\tKEEP\tkeep_value\n"))
          (let ((process-environment
                 (cons (concat "ETAF_BILI_COOKIE_FILE=" jar) process-environment)))
            (with-temp-buffer
              (should (= 0 (call-process etaf-bili-node-program nil t nil
                                         script "logout")))))
          (let ((after (with-temp-buffer
                         (insert-file-contents jar)
                         (buffer-string))))
            ;; `.bilibili.com' #HttpOnly_ cookie was recognized and removed
            (should-not (string-match-p "SESSDATA" after))
            ;; Non-bilibili #HttpOnly_ cookie survived round-trip with prefix intact
            (should (string-match-p
                     "#HttpOnly_\\.example\\.test\tTRUE\t/\tTRUE\t2147483647\tKEEP\tkeep_value"
                     after))
            ;; Atomic rename left no stray temporary file
            (should-not (seq-filter (lambda (n) (string-prefix-p ".cookies-" n))
                                    (directory-files dir)))))
      (delete-directory dir t))))

(ert-deftest etaf-bili-watch-tests-channels-filters-and-pagination ()
  "All expanded channels send expected ops/params and pagination deduplicates."
  (let* ((dir (make-temp-file "etaf-bili-chan-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (requests nil)
         (client
          (lambda (req cb)
            (push req requests)
            (pcase (plist-get req :op)
              (:popular
               (if (= (or (plist-get req :page) 1) 1)
                   (funcall cb (list :ok (list (list :bvid "BV1a" :title "第一页一")
                                               (list :bvid "BV1b" :title "第一页二"))))
                 (funcall cb (list :ok (list (list :bvid "BV1b" :title "重复条目")
                                             (list :bvid "BV1c" :title "第二页新增"))))))
              (:rcmd (funcall cb (list :ok (list (list :bvid "BV1r" :title "推荐一")))))
              (:ranking (funcall cb (list :ok (list (list :bvid "BV1k" :title "科技榜一")))))
              (:search (funcall cb (list :ok (list (list :bvid "BV1s" :title "最多播放一")))))
              (:dynamic (funcall cb (list :ok (list :items (list (list :bvid "BV1d" :title "动态一"))
                                                    :offset "off2" :has-more t))))
              (:toview (funcall cb (list :ok (list (list :bvid "BV1t" :title "稍后再看一")))))
              (:history (funcall cb (list :ok (list :items (list (list :bvid "BV1h" :title "历史一"))
                                                    :cursor nil))))
              (:fav-folders (funcall cb (list :ok (list (list :id 77 :title "默认收藏夹" :count 1)))))
              (:fav-list (funcall cb (list :ok (list (list :bvid "BV1f" :title "收藏一")))))
              (:space (funcall cb (list :ok (list (list :bvid "BV1u" :title "UP主投稿一")))))
              (_ (funcall cb (list :error "unexpected"))))))
         (session (etaf-bili-session-create :client client)))
    (unwind-protect
        (progn
          (etaf-bili-load-popular session)
          (etaf-bili-load-more session)
          (let ((items (plist-get (etaf-bili-session-state session) :items)))
            (should (= 3 (length items)))
            (should (equal '("BV1a" "BV1b" "BV1c")
                           (mapcar (lambda (r) (plist-get r :bvid)) items))))
          (etaf-bili-load-rcmd session)
          (should (eq 'rcmd (plist-get (etaf-bili-session-state session) :mode)))
          (etaf-bili-load-ranking session 36)
          (should (= 36 (plist-get (car requests) :rid)))
          (etaf-bili-search session "Emacs" "click")
          (should (equal "click" (plist-get (car requests) :order)))
          (etaf-bili-load-dynamic session)
          (should (eq 'dynamic (plist-get (etaf-bili-session-state session) :mode)))
          (etaf-bili-load-toview session)
          (should (eq 'toview (plist-get (etaf-bili-session-state session) :mode)))
          (etaf-bili-load-history session)
          (should (eq 'history (plist-get (etaf-bili-session-state session) :mode)))
          (etaf-bili-load-favorites session 77)
          (should (eq :fav-list (plist-get (car requests) :op)))
          (etaf-bili-load-space session 8000 "某UP主")
          (should (eq 'space (plist-get (etaf-bili-session-state session) :mode)))
          (should (= 8000 (plist-get (car requests) :mid))))
      (delete-directory dir t))))

(ert-deftest etaf-bili-watch-tests-play-error-toast-preserves-gallery ()
  "A single-video stream error shows a Toast and keeps the Gallery cards visible."
  (let* ((dir (make-temp-file "etaf-bili-toast-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (etaf-bili-client-factory
          (lambda ()
            (lambda (req cb)
              (pcase (plist-get req :op)
                (:popular (funcall cb (list :ok (etaf-bili-watch-tests--sample-rows))))
                (:play (funcall cb (list :error "该视频需要大会员权限")))
                (_ (funcall cb (list :ok nil))))))))
    (when noninteractive (set-frame-size (selected-frame) 120 40))
    (let ((buffer (etaf-bili-open)))
      (unwind-protect
          (with-current-buffer buffer
            (etaf-bili-play)
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              ;; Gallery cards remain visible instead of being wiped
              (should (string-match-p "深度教程 0" text))
              (should (string-match-p "深度教程 1" text))
              ;; Non-destructive Toast reports the failure reason
              (should (string-match-p "需要大会员" text))))
        (etaf-bili-close)
        (delete-directory dir t)))))

(ert-deftest etaf-bili-watch-tests-watch-view-lifecycle-audio-only-and-org-link ()
  "Watch View mounts tabs, quality picker, theater, audio-only mini-player and Org link."
  (let* ((dir (make-temp-file "etaf-bili-watch-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (etaf-video-ffmpeg-program "/usr/bin/true")
         (etaf-video-ffprobe-program "/usr/bin/true")
         (etaf-video-ffplay-program "/usr/bin/true")
         (etaf-bili-client-factory
          (lambda ()
            (lambda (req cb)
              (pcase (plist-get req :op)
                (:popular (funcall cb (list :ok (etaf-bili-watch-tests--sample-rows))))
                (:play (funcall cb (list :ok (etaf-bili-watch-tests--sample-play
                                              (plist-get req :bvid)
                                              (plist-get req :cid)))))
                (:player-info
                 (funcall cb (list :ok (list :last-play-time 0
                                             :subtitles '((:lang "zh-CN" :label "中文"
                                                           :url "https://sub.test/1.json"))
                                             :chapters '((:from 0 :to 120 :title "章节一"))))))
                (:subtitle-body
                 (funcall cb (list :ok '((0.0 10.0 "测试字幕行")))))
                (:danmaku
                 (funcall cb (list :ok '((:time 2.0 :text "第一条弹幕" :mode 1 :color 16777215)))))
                (:comments
                 (funcall cb (list :ok '((:rpid "1" :author "热心观众" :likes 42
                                          :message "空降 01:30 干货满满")))))
                (:related
                 (funcall cb (list :ok (etaf-bili-watch-tests--sample-rows "BV1rel" 2))))
                (_ (funcall cb (list :ok nil))))))))
    (when noninteractive (set-frame-size (selected-frame) 150 42))
    (let ((buffer (etaf-bili-open)))
      (unwind-protect
          (with-current-buffer buffer
            ;; Enter Watch View
            (etaf-bili-play)
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "深度教程 0" text))
              (should (string-match-p "1080P" text))
              (should (string-match-p "选集" text))
              (should (string-match-p "字幕" text))
              (should (string-match-p "弹幕" text))
              (should (string-match-p "评论" text))
              (should (string-match-p "相关" text))
              (should (string-match-p "章节一" text)))
            ;; Quality picker dialog opens and closes via Escape without leaving Watch
            (etaf-bili-watch-quality-menu)
            (should (string-match-p "选择画质与线路"
                                    (buffer-substring-no-properties (point-min) (point-max))))
            (etaf-bili-watch-escape)
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should-not (string-match-p "选择画质与线路" text))
              (should (string-match-p "深度教程 0" text)))
            ;; Theater toggle collapses the side panel and exposes the narrow drawer button
            (etaf-bili-watch-toggle-theater)
            (should (string-match-p "侧栏 (i)"
                                    (buffer-substring-no-properties (point-min) (point-max))))
            (etaf-bili-watch-toggle-theater)
            ;; Copy Org timestamp link
            (let ((kill-ring nil))
              (etaf-bili-copy-org-link)
              (should (car kill-ring))
              (should (string-match-p "\\[\\[elisp:(etaf-bili-open-video \"BV1watch0\""
                                      (car kill-ring))))
            ;; Audio-only mode keeps mini-player visible after returning to Gallery
            (etaf-bili-watch-toggle-audio-only)
            (should (string-match-p "纯音频"
                                    (buffer-substring-no-properties (point-min) (point-max))))
            (etaf-bili-watch-back)
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "正在听" text))
              (should (string-match-p "回剧场" text)))
            ;; Return to Watch View, turn off audio-only, then return to Gallery
            (etaf-bili-return-to-watch)
            (should (string-match-p "纯音频"
                                    (buffer-substring-no-properties (point-min) (point-max))))
            (etaf-bili-watch-toggle-audio-only)
            (etaf-bili-watch-back)
            (should (string-match-p "深度教程 1"
                                    (buffer-substring-no-properties (point-min) (point-max)))))
        (etaf-bili-close)
        (delete-directory dir t)))))

(ert-deftest etaf-bili-watch-tests-open-preserves-mode-line-and-reuses-buffer ()
  "`etaf-bili-open' keeps the user's mode-line and reuses an already open buffer."
  (let* ((dir (make-temp-file "etaf-bili-open-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (calls 0)
         (etaf-bili-client-factory
          (lambda ()
            (lambda (_req cb)
              (cl-incf calls)
              (funcall cb (list :ok (etaf-bili-watch-tests--sample-rows)))))))
    (when noninteractive (set-frame-size (selected-frame) 120 40))
    (let ((b1 (etaf-bili-open)))
      (unwind-protect
          (progn
            (should (buffer-local-value 'mode-line-format b1))
            (let ((b2 (etaf-bili-open)))
              (should (eq b1 b2))
              (should (= 1 calls))))
        (etaf-bili-close)
        (delete-directory dir t)))))

(ert-deftest etaf-bili-watch-tests-unmount-resets-inflight-covers-for-remount ()
  "Unmounting while covers are in-flight resets state so remount reloads them."
  (let* ((dir (make-temp-file "etaf-bili-cover-reset-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (cover-calls 0)
         (client
          (lambda (req cb)
            (pcase (plist-get req :op)
              (:popular
               (funcall cb (list :ok (list (list :bvid "BV1cov0" :title "带封面"
                                                 :author "UP" :duration 60
                                                 :cover "https://i0.hdslb.com/a.jpg")))))
              (:cover
               (cl-incf cover-calls)
               ;; Deliberately hold the transfer open to simulate in-flight unmount
               nil)
              (_ (funcall cb (list :ok nil))))))
         (session (etaf-bili-session-create :client client))
         (buf (generate-new-buffer " *etaf-bili-remount*")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _f) t)))
          (switch-to-buffer buf)
          (etaf-mount buf (etaf-bili-view session))
          (should (= 1 cover-calls))
          (etaf-unmount (etaf-runtime-for-buffer buf))
          ;; Remounting the kept-alive session must re-request the interrupted cover
          (etaf-mount buf (etaf-bili-view session))
          (should (= 2 cover-calls)))
      (when-let* ((rt (etaf-runtime-for-buffer buf)))
        (etaf-unmount rt))
      (kill-buffer buf)
      (delete-directory dir t))))

(ert-deftest etaf-bili-watch-tests-danmaku-zero-jitter-and-audio-parity ()
  "Danmaku toggle keeps stage geometry invariant, defaults volume to 100%, and persists settings."
  (let* ((dir (make-temp-file "etaf-bili-dm-av-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (etaf-video-ffmpeg-program "/usr/bin/true")
         (etaf-video-ffprobe-program "/usr/bin/true")
         (etaf-video-ffplay-program "/usr/bin/true")
         (etaf-bili-client-factory
          (lambda ()
            (lambda (req cb)
              (pcase (plist-get req :op)
                (:popular (funcall cb (list :ok (etaf-bili-watch-tests--sample-rows))))
                (:play (funcall cb (list :ok (etaf-bili-watch-tests--sample-play
                                              (plist-get req :bvid)
                                              (plist-get req :cid)))))
                (:danmaku
                 (funcall cb (list :ok '((:time 2.0 :text "前方高能" :mode 1 :color "#FFFFFF")
                                         (:time 4.0 :text "画质真清晰" :mode 5 :color "#FFE066")))))
                (_ (funcall cb (list :ok nil))))))))
    (when noninteractive (set-frame-size (selected-frame) 160 44))
    (let ((buffer (etaf-bili-open)))
      (unwind-protect
          (with-current-buffer buffer
            (etaf-bili-play)
            (let* ((rt (etaf-runtime-for-buffer buffer))
                   (text (buffer-substring-no-properties (point-min) (point-max)))
                   (stage-on (etaf-host-ref-size rt 'bili-watch-stage)))
              ;; Default unity volume 100% and Hi-Res audio badge
              (should (string-match-p "♪ 100%" text))
              (should (string-match-p "1080P · Hi-Res" text))
              (should stage-on)
              ;; Stepping volume down and up updates HUD cleanly with invariant width
              (etaf-bili-watch-volume-down)
              (should (string-match-p "♪  90%"
                                      (buffer-substring-no-properties (point-min) (point-max))))
              (etaf-bili-watch-volume-up)
              (should (string-match-p "♪ 100%"
                                      (buffer-substring-no-properties (point-min) (point-max))))
              ;; Toggling danmaku OFF and back ON causes zero stage layout shift
              (etaf-bili-watch-toggle-danmaku)
              (let ((stage-off (etaf-host-ref-size rt 'bili-watch-stage)))
                (should (equal stage-on stage-off)))
              (etaf-bili-watch-toggle-danmaku)
              (let ((stage-re-on (etaf-host-ref-size rt 'bili-watch-stage)))
                (should (equal stage-on stage-re-on)))
              ;; Danmaku sidebar tab exposes live settings and persists choices in SQLite
              (etaf-dispatch-event rt 'bili-watch-tab-danmaku 'press)
              (let ((dm-text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "弹幕显示设置" dm-text))
                (should (string-match-p "区域" dm-text))
                (should (string-match-p "透明" dm-text))
                (should (string-match-p "前方高能" dm-text)))
              (etaf-dispatch-event rt 'bili-dm-area-quarter 'press)
              (etaf-dispatch-event rt 'bili-dm-opacity-60 'press)
              (should (equal "quarter" (etaf-bili-store-pref-get "dm-area" "half")))
              (should (= 60 (etaf-bili-store-pref-get "dm-opacity" 80)))))
        (etaf-bili-close)
        (delete-directory dir t)))))

(ert-deftest etaf-bili-watch-tests-hires-flac-audio-selection ()
  "Client stream selection prioritizes DASH Hi-Res FLAC audio over 192K AAC."
  (let* ((dir (make-temp-file "etaf-bili-flac-" t))
         (fake-curl (expand-file-name "fake-curl.py" dir))
         (etaf-bili-curl-program fake-curl)
         (client (etaf-bili-make-client :state-directory dir))
         result)
    (unwind-protect
        (progn
          (with-temp-file fake-curl
            (insert
             "#!/usr/bin/env python3\n"
             "import json, sys\n"
             "url = sys.argv[-1]\n"
             "if '/nav' in url:\n"
             "    body = {'code': 0, 'data': {'wbi_img': {\n"
             "        'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',\n"
             "        'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png'}}}\n"
             "elif '/view' in url:\n"
             "    body = {'code': 0, 'data': {\n"
             "        'bvid': 'BV1flac', 'aid': 42, 'cid': 5000, 'title': 'Hi-Res 测试',\n"
             "        'duration': 180, 'owner': {'name': 'UP', 'mid': 99},\n"
             "        'stat': {'view': 100, 'danmaku': 5, 'like': 10, 'coin': 2, 'favorite': 3},\n"
             "        'dimension': {'width': 1920, 'height': 1080},\n"
             "        'pages': [{'page': 1, 'cid': 5000, 'part': 'P1', 'duration': 180}]}}\n"
             "else:\n"
             "    body = {'code': 0, 'data': {'dash': {\n"
             "        'video': [{'id': 80, 'codecid': 7, 'width': 1920, 'height': 1080,\n"
             "                   'frameRate': '30', 'bandwidth': 2500000,\n"
             "                   'baseUrl': 'https://cdn.test/1080.m4s'}],\n"
             "        'flac': {'display': True, 'audio': {\n"
             "            'id': 30251, 'bandwidth': 1200000,\n"
             "            'baseUrl': 'https://cdn.test/hires.flac',\n"
             "            'backupUrl': ['https://cdn2.test/hires.flac']}},\n"
             "        'audio': [{'id': 30280, 'bandwidth': 192000,\n"
             "                   'baseUrl': 'https://cdn.test/192k.m4s'}]}}};\n"
             "sys.stdout.write(json.dumps(body))\n"))
          (set-file-modes fake-curl #o755)
          (etaf-bili-client-call client '(:op :play :bvid "BV1flac")
                                 (lambda (reply) (setq result reply)))
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (not result) (< (float-time) deadline))
              (sleep-for 0.02)))
          (let ((stream (plist-get result :ok)))
            (should stream)
            (should (equal "https://cdn.test/hires.flac" (plist-get stream :audio-url)))
            (should (= 30251 (plist-get stream :audio-id)))
            (should (equal "Hi-Res" (plist-get stream :audio-label)))))
      (delete-directory dir t))))

(ert-deftest etaf-bili-watch-tests-quality-dialog-keyboard-nav-and-alignment ()
  "Quality picker aligns labels without dot prefixes and supports up/down + RET."
  (let* ((dir (make-temp-file "etaf-bili-qnav-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (etaf-video-ffmpeg-program "/usr/bin/true")
         (etaf-video-ffprobe-program "/usr/bin/true")
         (etaf-video-ffplay-program "/usr/bin/true")
         (etaf-bili-client-factory
          (lambda ()
            (lambda (req cb)
              (pcase (plist-get req :op)
                (:popular (funcall cb (list :ok (etaf-bili-watch-tests--sample-rows))))
                (:play (funcall cb (list :ok (etaf-bili-watch-tests--sample-play
                                              (plist-get req :bvid)
                                              (plist-get req :cid)))))
                (_ (funcall cb (list :ok nil))))))))
    (when noninteractive (set-frame-size (selected-frame) 150 44))
    (let ((buffer (etaf-bili-open)))
      (unwind-protect
          (with-current-buffer buffer
            (etaf-bili-play)
            ;; Sidebar parts list uses flush alignment without shifting arrows
            (should-not (string-match-p "▸ P1"
                                        (buffer-substring-no-properties (point-min) (point-max))))
            (etaf-bili-watch-quality-menu)
            (let* ((rt (etaf-runtime-for-buffer buffer))
                   (text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "选择画质与线路" text))
              (should (string-match-p "当前" text))
              ;; No bullet prefix shifting active quality label out of column
              (should-not (string-match-p "●  1080P" text))
              (should (eq 'bili-quality-row-0 (etaf-focused-host-ref rt)))
              ;; Down arrow moves focus cleanly to 720P and RET activates it
              (etaf-direction 'down rt)
              (should (eq 'bili-quality-row-1 (etaf-focused-host-ref rt)))
              (etaf-activate rt)
              (let ((after (buffer-substring-no-properties (point-min) (point-max))))
                (should-not (string-match-p "选择画质与线路" after))
                (should (string-match-p "720P" after)))))
        (etaf-bili-close)
        (delete-directory dir t)))))

(ert-deftest etaf-bili-watch-tests-fullscreen-modes-and-mode-line-restore ()
  "Pure Fullscreen toggles window/frame tiers, hides/restores mode-line and keeps Watch live."
  (let* ((dir (make-temp-file "etaf-bili-fs-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" dir))
         (etaf-video-ffmpeg-program "/usr/bin/true")
         (etaf-video-ffprobe-program "/usr/bin/true")
         (etaf-video-ffplay-program "/usr/bin/true")
         (etaf-bili-client-factory
          (lambda ()
            (lambda (req cb)
              (pcase (plist-get req :op)
                (:popular (funcall cb (list :ok (etaf-bili-watch-tests--sample-rows))))
                (:play (funcall cb (list :ok (etaf-bili-watch-tests--sample-play
                                              (plist-get req :bvid)
                                              (plist-get req :cid)))))
                (_ (funcall cb (list :ok nil))))))))
    (when noninteractive (set-frame-size (selected-frame) 150 44))
    (let ((buffer (etaf-bili-open)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((orig-ml mode-line-format))
              (etaf-bili-play)
              (let ((watch-text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "全屏" watch-text))
                (should (string-match-p "宽屏" watch-text)))
              ;; Enter in-window pure fullscreen (`f') — height must match immediately (no 1-row lag)
              (should (eq 'window (etaf-bili-watch-toggle-fullscreen)))
              (should (eq 'window (etaf-fullscreen-mode buffer)))
              (should (null mode-line-format))
              (when-let* ((win (get-buffer-window buffer t)))
                (should (= (count-lines (point-min) (point-max))
                           (window-body-height win))))
              (let ((fs-text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "↩ 退出" fs-text))
                (should (string-match-p "真全屏 F" fs-text))
                (should-not (string-match-p "← 返回" fs-text)))
              ;; Upgrade directly to frame fullscreen (`F')
              (should (eq 'frame (etaf-bili-watch-toggle-frame-fullscreen)))
              (should (eq 'frame (etaf-fullscreen-mode buffer)))
              (should (null mode-line-format))
              ;; Esc exits fullscreen cleanly without leaving Watch View, restoring mode-line & height
              (etaf-bili-watch-escape)
              (should-not (etaf-fullscreen-mode buffer))
              (should (equal mode-line-format orig-ml))
              (when-let* ((win (get-buffer-window buffer t)))
                (should (= (count-lines (point-min) (point-max))
                           (window-body-height win))))
              (let ((after-text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "← 返回" after-text))
                (should (string-match-p "全屏" after-text)))))
        (etaf-bili-close)
        (delete-directory dir t)))))

(ert-deftest etaf-bili-watch-tests-cookie-jar-handles-crlf-windows-cookies ()
  "CRLF Netscape cookies (as written by Windows curl) never leak CR into headers or CSRF."
  (skip-unless (executable-find etaf-bili-node-program))
  (let* ((dir (make-temp-file "etaf-bili-crlf-" t))
         (jar (expand-file-name "cookies.txt" dir))
         (backend (expand-file-name "bili.mjs" etaf-bili-backend-directory)))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'raw-text))
            (with-temp-file jar
              (insert "# Netscape HTTP Cookie File\r\n"
                      ".bilibili.com\tTRUE\t/\tFALSE\t1795063504\tb_nut\t1795063504\r\n"
                      ".bilibili.com\tTRUE\t/\tFALSE\t1795063504\tbuvid3\t8FC4B97E-TEST\r\n"
                      "#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t1999999999\tSESSDATA\tsecret_token\r\n"
                      ".bilibili.com\tTRUE\t/\tFALSE\t1999999999\tbili_jct\tcsrf_win_123\r\n"
                      "#HttpOnly_.other.example\tTRUE\t/\tTRUE\t1999999999\tKEEP\tkeep_val\r\n")))
          ;; Logout through bundled backend strips CR from CRLF cookies and writes LF back.
          (let* ((process-environment (cons (format "ETAF_BILI_COOKIE_FILE=%s" jar)
                                            process-environment))
                 (out (with-temp-buffer
                        (call-process etaf-bili-node-program nil t nil backend "logout")
                        (buffer-string)))
                 (reply (json-parse-string (string-trim out) :object-type 'plist))
                 (written (with-temp-buffer
                            (insert-file-contents-literally jar)
                            (buffer-string))))
            (should (eq t (plist-get reply :ok)))
            (should-not (string-match-p "\r" written))
            (should (string-match-p "#HttpOnly_\\.other\\.example\tTRUE\t/\tTRUE\t1999999999\tKEEP\tkeep_val" written))
            (should-not (string-match-p "bili_jct" written)))
          ;; Re-write a CRLF jar and verify `:like' sends a clean CR-free `csrf=' parameter.
          (let ((coding-system-for-write 'raw-text))
            (with-temp-file jar
              (insert ".bilibili.com\tTRUE\t/\tFALSE\t1999999999\tbili_jct\tcsrf_win_456\r\n")))
          (let* ((fake-curl (expand-file-name "fake-curl.py" dir))
                 (args-file (expand-file-name "curl-args.json" dir))
                 (etaf-bili-curl-program fake-curl)
                 (client (etaf-bili-make-client :state-directory dir :timeout 5))
                 (result nil))
            (with-temp-file fake-curl
              (insert "#!/usr/bin/env python3\n"
                      "import json, sys\n"
                      (format "open(%S, 'w').write(json.dumps(sys.argv[1:]))\n" args-file)
                      "sys.stdout.write('{\"code\":0,\"data\":{}}')\n"))
            (set-file-modes fake-curl #o755)
            (etaf-bili-client-call client '(:op :like :bvid "BV1crlf" :like 1)
                                   (lambda (reply) (setq result reply)))
            (let ((deadline (+ (float-time) 5.0)))
              (while (and (not result) (< (float-time) deadline))
                (sleep-for 0.02)))
            (should (plist-member result :ok))
            (let ((argv (with-temp-buffer
                          (insert-file-contents args-file)
                          (json-parse-buffer :array-type 'list))))
              (should (member "csrf=csrf_win_456" argv))
              (should-not (cl-some (lambda (a) (string-match-p "\r" a)) argv)))))
      (delete-directory dir t))))

(provide 'etaf-bili-watch-tests)
;;; etaf-bili-watch-tests.el ends here
