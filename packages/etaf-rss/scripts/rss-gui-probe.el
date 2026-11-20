;;; rss-gui-probe.el --- Drive and inspect a live ETAF RSS reader -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader's layout invariants can only be checked in a real frame: the
;; model budgets rows from the window, and a row painted taller than planned
;; pushes the canvas past the window.  This file is the maintained probe a GUI
;; check loads, so probes stop being throwaway files that bypass the
;; byte-compilation gate.
;;
;; Load it in a graphical Emacs with the reader and its providers on
;; `load-path', then:
;;
;;   (etaf-rss-gui-open "150x42")   ; mount the reader at a frame size
;;   (etaf-rss-gui-status)          ; one-line state for logging
;;   (etaf-rss-gui-keys "jj n RET") ; real keys through the command loop
;;   (etaf-rss-gui-scroll "SPC")    ; keys, then report reading progress
;;   (etaf-rss-gui-check)           ; layout invariants; nil when healthy
;;
;; The client is scripted, so the probe paints a full reader without a
;; network or a stored account.  Nothing here is part of the package's public
;; API.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-rss)

(defvar etaf-rss-gui--model nil
  "Reader session the probe drives, or nil before the first open.")

(defun etaf-rss-gui--article (index feed feed-title title author minutes summary)
  "Return one scripted article row."
  (list :id (format "gui-%d" index)
        :feed (format "gui-feed-%d" feed)
        :feed-title feed-title
        :title title
        :url (format "https://example.com/%d" index)
        :author author
        :published (- (float-time) (* minutes 60))
        :summary summary
        :read nil
        :starred (zerop (% index 9))))

(defconst etaf-rss-gui--paragraphs
  '("增量更新是文本应用最容易被忽视的体验来源。每次按键之后，用户期望看到的是即时反馈，而不是整屏重排。"
    "把工作分成两层之后，事情变得清楚：一层负责决定哪些内容变了，另一层只负责把变化画出来。"
    "列表的选中状态只改变一行的背景与字重；阅读面板的滚动只替换可见的几行；侧栏的未读数只更新一个数字。"
    "当这三件事各自沿着最短路径走到屏幕，一次按键的开销就和当前文章的长度无关了。"
    "剩下的工作是让数据来源保持安静：网络请求串行、回复带版本号、过期结果直接丢弃。"
    "于是界面只关心已经确认的事实，用户看到的一切都来自已经提交的状态。"))

(defun etaf-rss-gui--content (&optional extra)
  "Return the scripted article HTML, with optional EXTRA paragraphs."
  (concat "<h2>为什么要做增量更新</h2>"
          (mapconcat (lambda (text) (format "<p>%s</p>" text))
                     (append etaf-rss-gui--paragraphs extra)
                     "")
          "<blockquote>先把预算算清楚，再决定每一行画什么。</blockquote>"
          "<ul><li>列表只画可见页</li><li>正文只替换变动行</li><li>数据先到内存，再进界面</li></ul>"
          "<pre>(etaf-rss-move-selection session 1)</pre>"
          "<p>更多实现细节见 <a href=\"https://example.com/docs\">项目文档</a>。</p>"))

(defun etaf-rss-gui--feeds ()
  "Return the scripted sidebar feeds."
  (apply #'vector
         (cl-loop for (title folder unread) in '(("少数派" "技术" 12)
                                                 ("阮一峰的网络日志" "技术" 4)
                                                 ("机器之心" "资讯" 27)
                                                 ("Hacker News" "资讯" 31)
                                                 ("云风的 BLOG" "技术" 3))
                  for index from 1
                  collect (list :id (format "gui-feed-%d" index)
                                :url (format "https://example.com/%d/feed" index)
                                :title title :site "https://example.com"
                                :folder folder :unread unread :total (+ unread 40)
                                :updated (float-time)
                                :last-fetch (float-time)
                                :error nil))))

(defun etaf-rss-gui--rows ()
  "Return the scripted article rows."
  (apply #'vector
         (cl-loop for index from 1 to 60
                  for feed = (1+ (% (1- index) 5))
                  for title = (nth (% index 6)
                                   '("为什么增量更新如此重要"
                                     "一次按键到屏幕的距离"
                                     "文本应用里的毫秒级反馈"
                                     "把网络延迟挡在界面之外"
                                     "阅读器的信息层级设计"
                                     "从数据到画布的提交边界"))
                  for author = (nth (% index 5)
                                    '("作者甲" "作者乙" "作者丙" "作者丁" "作者戊"))
                  collect (etaf-rss-gui--article
                           index feed
                           (nth (1- feed)
                                '("少数派" "阮一峰的网络日志"
                                  "机器之心" "Hacker News" "云风的 BLOG"))
                           title author (+ 3 index)
                           "读完之后，列表与阅读面板都保持在原地。"))))

(defun etaf-rss-gui--client (request callback)
  "Answer REQUEST from the scripted reader."
  (let* ((op (plist-get request :op))
         (feeds (etaf-rss-gui--feeds))
         (rows (etaf-rss-gui--rows))
         (article (cl-find (plist-get request :id) rows
                           :key (lambda (row) (plist-get row :id)) :test #'equal))
         (article (append (or article (aref rows 0))
                          (list :content (etaf-rss-gui--content)))))
    (funcall callback
             (pcase op
               (:snapshot (list :ok (list :feeds feeds :total (length rows)
                                          :unread 77 :starred 6 :theme "dark")))
               (:feeds (list :ok (list :feeds feeds :total (length rows)
                                       :unread 77 :starred 6)))
               (:articles (list :ok (list :rows rows :total (length rows))))
               (:article (list :ok article))
               (:mark-read (list :ok (list :changed 1 :feeds feeds :unread 76
                                           :total (length rows) :starred 6)))
               (:mark-read-scope (list :ok (list :ids ["gui-1"] :feeds feeds
                                                 :unread 0 :total (length rows) :starred 6)))
               (:star (list :ok (list :id "gui-1" :feeds feeds :unread 77
                                      :total (length rows) :starred 7)))
               (:set-theme (list :ok (list :theme "dark")))
               (_ (list :ok (list :feeds feeds :total (length rows)
                                  :unread 77 :starred 6)))))))

(defun etaf-rss-gui--window ()
  "Return the window showing the probe's reader, or nil."
  (when (and etaf-rss-gui--model
             (buffer-live-p (plist-get etaf-rss-gui--model :buffer)))
    (get-buffer-window (plist-get etaf-rss-gui--model :buffer) t)))

(defun etaf-rss-gui-flush ()
  "Flush the mounted reader's publication and redisplay."
  (let ((window (etaf-rss-gui--window)))
    (when window
      (with-selected-window window
        (etaf-runtime-flush (etaf-runtime-for-buffer (window-buffer window)))
        (redisplay t)))))

(defvar etaf-rss-gui--frame nil
  "Dedicated frame the probe's reader lives in, or nil.")

(defun etaf-rss-gui-set-size (width height)
  "Put the reader in a dedicated WIDTH x HEIGHT frame and refit it.
The initial frame of a fresh Emacs ignores `set-frame-size', so the probe
creates its own frame; the frame is deleted by `etaf-rss-gui-close'."
  (unless (and etaf-rss-gui--frame (frame-live-p etaf-rss-gui--frame))
    (setq etaf-rss-gui--frame
          (make-frame (list (cons 'width width) (cons 'height height)))))
  (select-frame etaf-rss-gui--frame)
  (set-frame-size etaf-rss-gui--frame width height)
  (accept-process-output nil 0.05)
  (when etaf-rss-gui--model
    (etaf-rss--sync-layout etaf-rss-gui--model (etaf-rss-gui--window))
    (etaf-rss-gui-flush)))

(defun etaf-rss-gui-close ()
  "Close the probe's frame; the reader buffer is left for inspection."
  (when (and etaf-rss-gui--frame (frame-live-p etaf-rss-gui--frame))
    (delete-frame etaf-rss-gui--frame t)
    (setq etaf-rss-gui--frame nil)))

(defun etaf-rss-gui-open (&optional size)
  "Mount the reader in the selected frame at SIZE, a \"WIDTHxHEIGHT\" string.
SIZE defaults to `RSS_GUI_SIZE' or \"150x42\".  Return the new session."
  (let* ((size (or size (getenv "RSS_GUI_SIZE") "150x42"))
         (parts (split-string size "x"))
         (width (string-to-number (car parts)))
         (height (string-to-number (or (cadr parts) "42")))
         (session (etaf-rss-create :client #'etaf-rss-gui--client)))
    (setq etaf-rss-gui--model session)
    (etaf-rss-gui-set-size width height)
    (etaf-rss-open session)
    (accept-process-output nil 0.1)
    (etaf-rss-gui-flush)
    session))

(defun etaf-rss-gui-status ()
  "Return one line describing the probe's reader state."
  (let* ((state (etaf-rss-state etaf-rss-gui--model))
         (window (etaf-rss-gui--window)))
    (format "layout=%s pane=%s rows=%d/%d selection=%d reader=%d lines=%d scroll=%d body=%dx%d"
            (plist-get state :layout)
            (plist-get state :pane)
            (length (plist-get state :visible))
            (plist-get state :list-total)
            (plist-get state :selection)
            (or (plist-get state :reader-total) 0)
            (length (plist-get state :reader-lines))
            (plist-get state :reader-scroll)
            (and window (window-body-width window))
            (and window (window-body-height window)))))

(defun etaf-rss-gui-keys (keys)
  "Send KEYS through the command loop as a keyboard macro."
  (let ((window (etaf-rss-gui--window)))
    (when window
      (select-window window))
    (execute-kbd-macro (kbd keys))
    (accept-process-output nil 0.02)
    (etaf-rss-gui-flush)
    (etaf-rss-gui-status)))

(defun etaf-rss-gui-canvas-height ()
  "Return the painted canvas height of the reader in pixels."
  (let ((window (etaf-rss-gui--window)))
    (when window
      (with-selected-window window
        (cdr (window-text-pixel-size window (point-min) (point-max) nil nil t))))))

(defun etaf-rss-gui--reader-width-problems (runtime state)
  "Return width problems of the reading pane in RUNTIME.
Each wrapped line is a column budget; this measures the pixels it paints
against the width the renderer committed to the pane, so a budget that
ignores the pane's insets shows up even when the line count still fits."
  (let ((pane (and runtime (etaf-host-ref-size runtime 'etaf-rss-reader-pane))))
    (if (null pane)
        (list "the reader pane reports no committed width")
      (let ((budget (- (car pane)
                       (etaf-string-pixel-width
                        (make-string etaf-rss--reader-inset ?0))))
            (problems nil))
        (dolist (line (plist-get state :reader-lines))
          (let* ((indent (if (eq (plist-get line :kind) 'quote)
                             (etaf-string-pixel-width "0")
                           0))
                 (painted (+ indent
                             (etaf-string-pixel-width
                              (or (plist-get line :text) "")))))
            (when (> painted budget)
              (push (format "a reading line paints %dpx in a %dpx pane budget"
                            painted budget)
                    problems))))
        (nreverse problems)))))

(defun etaf-rss-gui-check ()
  "Return layout problems of the mounted reader, or nil when healthy.
Checks the painted canvas against the window, the reading width against the
wrapped lines, the reading lines' painted pixels against the pane the
renderer committed, the truncation slot, and a wide list's title budget."
  (let* ((window (etaf-rss-gui--window))
         (state (etaf-rss-state etaf-rss-gui--model))
         (problems nil))
    (unless window
      (push "reader window is gone" problems))
    (when window
      (with-selected-window window
        (let ((canvas (etaf-rss-gui-canvas-height))
              (body (window-body-height window t))
              (width (window-body-width window))
              (layout (plist-get state :layout))
              (text (buffer-substring-no-properties (point-min) (point-max))))
          (when (and canvas (> canvas body))
            (push (format "canvas %dpx exceeds body %dpx" canvas body) problems))
          (when (string-match-p "\\$" text)
            (push "a truncation marker is visible" problems))
          (when (eq layout 'wide)
            (when (< width etaf-rss-wide-columns)
              (push (format "wide layout at %d columns" width) problems))
            ;; A row reserves fixed columns for the source and the time; the
            ;; title takes the rest, and eight characters is not a title.
            (let* ((list-columns (etaf-rss--list-columns width 'wide))
                   (title-columns (etaf-rss--title-columns list-columns)))
              (when (< title-columns 12)
                (push (format "a wide list at %d columns leaves titles %d columns"
                              width title-columns)
                      problems))))
          ;; The wrapping budget is columns; what clips is pixels, so measure
          ;; the painted lines against the pane the renderer actually gave us.
          (when (or (eq layout 'wide) (eq (plist-get state :pane) 'reader))
            (setq problems
                  (append (etaf-rss-gui--reader-width-problems
                           (etaf-runtime-for-buffer (window-buffer window))
                           state)
                          problems))))))
    (dolist (line (plist-get state :reader-lines))
      (when (> (string-width (or (plist-get line :text) ""))
               (plist-get state :reader-columns))
        (push "a wrapped line is wider than its column" problems)))
    (nreverse problems)))

(provide 'rss-gui-probe)
;;; rss-gui-probe.el ends here
