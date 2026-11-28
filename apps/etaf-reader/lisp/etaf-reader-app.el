;;; etaf-reader-app.el --- Application shell of etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one reader session to the Views, owns the
;; buffer, the keymap and the window metrics.  The `etaf-reader-app'
;; Component is the only place that renders the session; every command writes
;; a reactive source, so a page turn, an annotation or a theme change repaints
;; without a remount.
;;
;; The reader runs as an ETAF application (`etaf-app-open'): its keys are the
;; root Host's `:keys', the base canvas follows the palette, and each settled
;; window resize repaginates through the application's fit function.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-reader-theme)
(require 'etaf-reader-model)
(require 'etaf-reader-views)

(defconst etaf-reader--buffer-name "*ETAF Reader*"
  "Buffer that shows the reader.")

;;; ---------------------------------------------------------------------------
;;; Small helpers
;;; ---------------------------------------------------------------------------

(defun etaf-reader--current ()
  "Return the current buffer's reader session."
  (or (etaf-app-state)
      (user-error "Not an ETAF reader buffer")))

(defun etaf-reader--call (function)
  "Run FUNCTION for the current session with error reporting."
  (let* ((session (etaf-reader--current))
         (etaf-reader-store-file (plist-get session :store-file))
         (etaf-reader-cache-directory (plist-get session :cache-directory)))
    (etaf-reader-guard session function)))

(defun etaf-reader--require-reader (session)
  "Signal `etaf-reader-error' unless SESSION has an open book in reading view."
  (unless (and (eq (etaf-reader--read session :view) 'reader)
               (etaf-reader--read session :book))
    (signal 'etaf-reader-error '("请先打开一本书"))))

(defun etaf-reader--find-text-line (lines from step)
  "Return the nearest line index in LINES from FROM moving by STEP (+1 or -1)
whose source span is positive, or FROM clamped to LINES."
  (let* ((count (length lines))
         (idx (max 0 (min (1- (max 1 count)) from))))
    (while (and (>= idx 0) (< idx count)
                (<= (etaf-reader--line-span (nth idx lines)) 0))
      (setq idx (+ idx step)))
    (if (and (>= idx 0) (< idx count))
        idx
      (max 0 (min (1- (max 1 count)) from)))))

(defun etaf-reader--cursor-move (session delta-line delta-char)
  "Move the selection caret by DELTA-LINE lines and DELTA-CHAR characters.
Wraps cleanly across line ends and skips blank paragraph-gap lines."
  (let* ((cursor (etaf-reader--read session :cursor))
         (lines (etaf-reader--read session :lines))
         (count (length lines))
         (line (or (plist-get cursor :line)
                   (etaf-reader--find-text-line lines (etaf-reader--read session :line) 1)))
         (char (or (plist-get cursor :char) 0))
         (cur-span (if (< line count) (etaf-reader--line-span (nth line lines)) 0))
         (new-line line)
         (new-char char))
    (cond
     ((/= delta-line 0)
      (let* ((step (if (> delta-line 0) 1 -1))
             (candidate (+ line delta-line)))
        (setq new-line (etaf-reader--find-text-line lines candidate step))
        (let ((span (if (< new-line count) (etaf-reader--line-span (nth new-line lines)) 0)))
          (setq new-char (max 0 (min span char))))))
     ((> delta-char 0)
      (if (< (+ char delta-char) cur-span)
          (setq new-char (+ char delta-char))
        (if (< char cur-span)
            (setq new-char cur-span)
          (let ((next (etaf-reader--find-text-line lines (1+ line) 1)))
            (if (> next line)
                (setq new-line next new-char 0)
              (setq new-char cur-span))))))
     ((< delta-char 0)
      (if (> (+ char delta-char) 0)
          (setq new-char (+ char delta-char))
        (if (> char 0)
            (setq new-char 0)
          (let ((prev (etaf-reader--find-text-line lines (1- line) -1)))
            (if (< prev line)
                (setq new-line prev
                      new-char (etaf-reader--line-span (nth prev lines)))
              (setq new-char 0)))))))
    (if cursor
        (etaf-reader-extend-selection session new-line new-char)
      (etaf-reader-begin-selection session new-line new-char))
    ;; Keep the caret inside the visible page.
    (let* ((top (etaf-reader--read session :line))
           (page (max 1 (etaf-reader--page-size session))))
      (cond ((< new-line top) (etaf-reader-goto-line session new-line))
            ((>= new-line (+ top page))
             (etaf-reader-goto-line session (max 0 (- new-line (1- page)))))))))

;;; ---------------------------------------------------------------------------
;;; Component and view
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-reader-app (&key session)
  "Render the reader for SESSION and own its lifecycle."
  :bindings ((reader (or session
                         (signal 'etaf-reader-error
                                 '("etaf-reader-app needs the :session from `etaf-reader-create'"))))
             (runtime (etaf-current-runtime))
             (theme (etaf-reader--ref reader :theme))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-reader-theme-defaults (etaf-value theme)))
                      :name 'etaf-reader-theme-tokens)))
  :setup
  (progn
    (etaf-theme-provide tokens)
    ;; One appearance state: a panel's title-bar switch writes the session's
    ;; mode cell, and both the paper and the panel chrome follow it.
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme tokens :mode theme
                            :modes etaf-reader--surface-modes))
    ;; Scroll the active chapter into view inside the full-height TOC sidebar
    ;; only when the open book, chapter, or sidebar visibility changes, so
    ;; manual wheel browsing of the TOC is never fought back.
    (let* ((last-toc-key nil)
           (reveal-toc
            (lambda ()
              (let* ((view (etaf-reader--read reader :view))
                     (metrics (etaf-reader--read reader :metrics))
                     (sidebar (and (etaf-reader--read reader :sidebar)
                                   (not (eq (plist-get metrics :layout) 'narrow))))
                     (book (etaf-reader--read reader :book))
                     (chapter (etaf-reader--read reader :chapter))
                     (key (and (eq view 'reader) sidebar book chapter
                               (list (plist-get book :id)
                                     (plist-get chapter :index)
                                     (etaf-reader--read reader :window-rows)))))
                (unless (equal key last-toc-key)
                  (setq last-toc-key key)
                  (when (and key runtime (etaf-runtime-mounted-p runtime))
                    (ignore-errors
                      (etaf-scroll-into-view runtime 'reader-toc-current))))))))
      (etaf-on-mounted reveal-toc)
      (etaf-on-updated reveal-toc))
    (etaf-on-unmounted
     (lambda ()
       (when-let* ((timer (plist-get reader :save-timer)))
         (cancel-timer timer)
         (plist-put reader :save-timer nil)))))
  :render
  (etaf-reader-view reader))

;;; ---------------------------------------------------------------------------
;;; Window metrics
;;; ---------------------------------------------------------------------------

(defun etaf-reader--fit (session window)
  "Repaginate SESSION for WINDOW, its display window."
  (plist-put session :buffer (current-buffer))
  (etaf-reader-guard
   session (lambda ()
             (etaf-reader-sync-metrics session
                                       (window-body-width window)
                                       (window-body-height window)))))

;;; ---------------------------------------------------------------------------
;;; Keymap
;;; ---------------------------------------------------------------------------

(defconst etaf-reader--bindings
  '(("SPC" etaf-reader-next-page-command "阅读下一页")
    ("S-SPC" etaf-reader-previous-page-command "阅读上一页")
    ("C-v" etaf-reader-next-page-command "阅读下一页")
    ("M-v" etaf-reader-previous-page-command "阅读上一页")
    ("<next>" etaf-reader-next-page-command "阅读下一页")
    ("DEL" etaf-reader-previous-page-command "阅读上一页")
    ("<prior>" etaf-reader-previous-page-command "阅读上一页")
    ("H" etaf-reader-chapter-backward-command "上一章")
    ("L" etaf-reader-chapter-forward-command "下一章")
    ("v" etaf-reader-toggle-selection-command "切换文字选择")
    ("RET" etaf-reader-return-command "确认选区／激活控件")
    ("C-c C-k" etaf-reader-cancel-selection-command "关闭面板／取消选区")
    ("s" etaf-reader-search-command "搜索全书")
    ("n" etaf-reader-search-next-command "下一个匹配")
    ("N" etaf-reader-search-previous-command "上一个匹配")
    ("c" etaf-reader-toc-command "目录")
    ("a" etaf-reader-notes-command "笔记与划线")
    ("b" etaf-reader-bookmark-command "收藏当前页")
    ("B" etaf-reader-bookmarks-command "书签列表")
    ("S" etaf-reader-search-results-command "搜索结果")
    ("o" etaf-reader-settings-command "阅读设置")
    ("u" etaf-reader-jump-back-command "返回跳转前")
    ("g" etaf-reader-goto-percent-command "跳转阅读进度")
    ("z" etaf-reader-toggle-mode-command "切换分页／滚动")
    ("[" etaf-reader-narrower-command "收窄阅读栏")
    ("]" etaf-reader-wider-command "加宽阅读栏")
    ("t" etaf-reader-toggle-theme-command "切换阅读主题")
    ("f" etaf-reader-shelf-command "返回书库")
    ("j" etaf-reader-shelf-down-command "下一排")
    ("k" etaf-reader-shelf-up-command "上一排")
    ("h" etaf-reader-shelf-left-command "左一本")
    ("l" etaf-reader-shelf-right-command "右一本")
    ("d" etaf-reader-toggle-detail-command "详情面板／阅读侧栏")
    ("i" etaf-reader-scan-command "重新扫描书库")
    ("E" etaf-reader-export-command "导出笔记")
    ("C-c h" etaf-help "查看快捷键")
    ("q" etaf-reader-close "关闭阅读器"))
  "Root keys of the reader, as (KEY COMMAND LABEL).
They beat the renderer's own minor-mode map; a focused control still takes
RET, and the reader's RET dispatches between a selection and activation.
Wheel bindings live on the non-scrolling main columns so scrollable sidebars
and the detail panel keep native smooth scrolling.")

(defun etaf-reader-view-for-session (session)
  "Return the mountable View of SESSION."
  (etaf-view (etaf-reader-app :session session :keys etaf-reader--bindings)))

(defun etaf-reader-return-command ()
  "Confirm the current selection, activate a focused control, or open the book."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (cond
        ((and (etaf-reader-selection session)
              (etaf-reader--read session :cursor)
              (null (etaf-reader--read session :toolbar)))
         (etaf-reader-show-toolbar session))
        ((etaf-focused-host-ref)
         (etaf-activate))
        ((and (eq (etaf-reader--read session :view) 'shelf)
              (etaf-reader--read session :shelf-cursor)
              (let* ((page (etaf-reader-library-page session))
                     (id (etaf-reader--read session :shelf-cursor)))
                (when-let* ((book (seq-find (lambda (row) (equal id (plist-get row :id)))
                                            (plist-get page :items))))
                  (etaf-reader-open-book session book)
                  t))))
        (t nil))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun etaf-reader-next-page-command ()
  "Turn to the next page (page mode) or scroll (scroll mode)."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (cond ((etaf-reader--read session :pane) (etaf-reader--step-pane session 1))
             ((eq (etaf-reader--read session :view) 'shelf)
              (etaf-reader-page-library session 1))
             ((eq (etaf-reader--read session :mode) 'scroll)
              (etaf-reader-scroll-lines session 3))
             (t (etaf-reader-clear-selection session)
                (etaf-reader-next-page session)))))))

(defun etaf-reader-previous-page-command ()
  "Turn to the previous page (page mode) or scroll back (scroll mode)."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (cond ((etaf-reader--read session :pane) (etaf-reader--step-pane session -1))
             ((eq (etaf-reader--read session :view) 'shelf)
              (etaf-reader-page-library session -1))
             ((eq (etaf-reader--read session :mode) 'scroll)
              (etaf-reader-scroll-lines session -3))
             (t (etaf-reader-clear-selection session)
                (etaf-reader-previous-page session)))))))

(defun etaf-reader--direction (direction)
  "Run the reader's DIRECTION movement and return `handled' or `release'.
Up and down scroll or extend the selection a line; left and right turn pages
unless a keyboard selection is active, when they move its cursor.  Without a
selection, a focused control releases the arrows to focus movement."
  (if (and (etaf-focused-host-ref)
           (not (etaf-reader--read (etaf-reader--current) :cursor)))
      'release
    (etaf-reader--move direction)
    'handled))

(defun etaf-reader--move (direction)
  "Move the page or the keyboard selection in DIRECTION."
  (pcase direction
    ('up (etaf-reader-backward-line-command))
    ('down (etaf-reader-forward-line-command))
    ('left (if (etaf-reader--read (etaf-reader--current) :cursor)
               (etaf-reader-backward-char-command)
             (etaf-reader-previous-page-command)))
    ('right (if (etaf-reader--read (etaf-reader--current) :cursor)
                (etaf-reader-forward-char-command)
              (etaf-reader-next-page-command)))))

(defun etaf-reader-forward-line-command ()
  "Move down one line, or extend the keyboard selection."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session 1 0)
         (etaf-reader-scroll-lines session 1))))))

(defun etaf-reader-backward-line-command ()
  "Move up one line, or extend the keyboard selection."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session -1 0)
         (etaf-reader-scroll-lines session -1))))))

(defun etaf-reader-forward-char-command ()
  "Move right one character, or go to the next chapter."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session 0 1)
         (etaf-reader-next-chapter session))))))

(defun etaf-reader-backward-char-command ()
  "Move left one character, or go to the previous chapter."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session 0 -1)
         (etaf-reader-previous-chapter session))))))

(defun etaf-reader-chapter-forward-command ()
  "Open the next chapter."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (etaf-reader-next-chapter session)))))

(defun etaf-reader-chapter-backward-command ()
  "Open the previous chapter."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (etaf-reader-previous-chapter session)))))

(defun etaf-reader-toggle-selection-command ()
  "Start or clear the keyboard selection."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (if (etaf-reader--read session :cursor)
           (etaf-reader-clear-selection session)
         (let* ((lines (etaf-reader--read session :lines))
                (start (etaf-reader--find-text-line
                        lines (etaf-reader--read session :line) 1)))
           (etaf-reader-begin-selection session start 0)
           (etaf-reader-message session "方向键移动选择，回车打开工具条，C-c C-k 取消")))))))

(defun etaf-reader-confirm-selection-command ()
  "Open the annotation toolbar for the current selection."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (if (etaf-reader-selection session)
           (etaf-reader-show-toolbar session)
         (etaf-reader-message session "还没有选中文字"))))))

(defun etaf-reader-cancel-selection-command ()
  "Close any open help/pane and clear the selection, cursor and toolbar."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (when-let* ((buffer (plist-get session :buffer))
                   (runtime (and (buffer-live-p buffer)
                                 (etaf-runtime-for-buffer buffer))))
         (etaf-help-close runtime))
       (etaf-batch
         (etaf-reader--write session :pane nil)
         (etaf-reader-clear-selection session))))))

(defun etaf-reader-search-command ()
  "Search the current book or filter the library on the shelf."
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (shelf (eq (etaf-reader--read session :view) 'shelf))
            (query (string-trim (read-string (if shelf "书名或作者：" "搜索全书：")))))
       (if shelf
           (etaf-reader-filter-library session query)
         (unless (string-empty-p query)
           (etaf-reader--remember-position session)
           (etaf-reader-search-book session query)
           (etaf-reader-show-pane session 'search)))))))

(defun etaf-reader-search-next-command ()
  "Jump to the next search match."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (etaf-reader-search-next session)))))

(defun etaf-reader-search-previous-command ()
  "Jump to the previous search match."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (etaf-reader-search-next session t)))))

(defun etaf-reader-toc-command ()
  "Toggle the table of contents pane."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader-show-pane session 'toc)))))

(defun etaf-reader-notes-command ()
  "Toggle the notes pane."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader-show-pane session 'notes)))))

(defun etaf-reader-bookmarks-command ()
  "Open the bookmark list."
  (etaf-reader--call (lambda () (etaf-reader-show-pane (etaf-reader--current) 'bookmarks))))

(defun etaf-reader-search-results-command ()
  "Open the current search result list."
  (etaf-reader--call (lambda () (etaf-reader-show-pane (etaf-reader--current) 'search))))

(defun etaf-reader-settings-command ()
  "Open reading preferences."
  (etaf-reader--call (lambda () (etaf-reader-show-pane (etaf-reader--current) 'settings))))

(defun etaf-reader-jump-back-command ()
  "Return to the position before a navigation jump."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (etaf-reader-jump-back session)))))

(defun etaf-reader-bookmark-command ()
  "Bookmark the top line of the current page."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (etaf-reader-add-bookmark session)))))

(defun etaf-reader-goto-percent-command ()
  "Jump to a percent of the book."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--require-reader session)
       (let ((input (string-trim (read-string "跳到百分比（0-100）："))))
         (if (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" input)
             (progn
               (etaf-reader--remember-position session)
               (etaf-reader-goto-percent session (string-to-number input)))
           (unless (string-empty-p input)
             (etaf-reader-message session "请输入 0 到 100 之间的数字"))))))))

(defun etaf-reader-toggle-mode-command ()
  "Toggle page turning and scrolling."
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (mode (if (eq (etaf-reader--read session :mode) 'page) 'scroll 'page)))
       (etaf-reader-configure session :mode mode)
       (etaf-reader-message session (if (eq mode 'page) "翻页模式" "滚动模式"))))))

(defun etaf-reader--adjust-columns (session delta)
  "Adjust SESSION's reading width by DELTA characters."
  (let* ((row (or (etaf-reader--read session :metrics) '()))
         (columns (max 24 (min 72 (+ (or (plist-get row :columns) 40) delta)))))
    (etaf-reader-configure session :columns columns)
    (etaf-reader-message session (format "栏宽 %d 字符" columns))))

(defun etaf-reader-wider-command ()
  "Widen the reading column."
  (etaf-reader--call
   (lambda () (etaf-reader--adjust-columns (etaf-reader--current) 4))))

(defun etaf-reader-narrower-command ()
  "Narrow the reading column."
  (etaf-reader--call
   (lambda () (etaf-reader--adjust-columns (etaf-reader--current) -4))))

(defun etaf-reader-toggle-theme-command ()
  "Switch to the next palette."
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (themes '(dark light sepia))
            (current (etaf-reader--read session :theme))
            (tail (cdr (memq current themes))))
       (etaf-reader-configure session :theme (or (car tail) (car themes)))
       (etaf-reader-message session
                            (format "主题：%s" (etaf-reader--read session :theme)))))))

(defun etaf-reader--shelf-move-command (dx dy)
  "Move the shelf cursor by DX cells and DY shelves."
  (let ((session (etaf-reader--current)))
    (when (eq (etaf-reader--read session :view) 'shelf)
      (etaf-reader--shelf-move session dx dy))))

(defun etaf-reader-shelf-down-command ()
  "Move the shelf cursor one shelf down."
  (etaf-reader--call (lambda () (etaf-reader--shelf-move-command 0 1))))

(defun etaf-reader-shelf-up-command ()
  "Move the shelf cursor one shelf up."
  (etaf-reader--call (lambda () (etaf-reader--shelf-move-command 0 -1))))

(defun etaf-reader-shelf-left-command ()
  "Move the shelf cursor one book left."
  (etaf-reader--call (lambda () (etaf-reader--shelf-move-command -1 0))))

(defun etaf-reader-shelf-right-command ()
  "Move the shelf cursor one book right."
  (etaf-reader--call (lambda () (etaf-reader--shelf-move-command 1 0))))

(defun etaf-reader-toggle-detail-command ()
  "Show or hide the shelf's detail panel, or the reading sidebar.
The shelf has a detail panel; the reader has a chapter sidebar. Both answer
to the same key so one binding covers whichever view is open."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (eq (etaf-reader--read session :view) 'reader)
           (etaf-reader--toggle-sidebar session)
         (etaf-reader--toggle-detail session))))))

(defun etaf-reader-shelf-command ()
  "Return to the shelf."
  (etaf-reader--call (lambda () (etaf-reader-show-shelf (etaf-reader--current)))))

(defun etaf-reader-scan-command ()
  "Rescan the library directories."
  (etaf-reader--call
   (lambda ()
     (etaf-reader-message (etaf-reader--current) "正在扫描书库…")
     (etaf-reader-refresh-library (etaf-reader--current)))))

(defun etaf-reader--export-book-interactive (session book)
  "Prompt for a destination path and export BOOK's annotations in SESSION."
  (unless book
    (signal 'etaf-reader-error '("请先选择一本书")))
  (let* ((title (etaf-reader--book-title book))
         (default (expand-file-name (concat title ".md") "~/"))
         (file (etaf-call-with-input
                (lambda ()
                  (read-file-name "导出到：" (file-name-directory default)
                                  default nil (file-name-nondirectory default))))))
    (etaf-reader--export-book-notes session book file)))

(defun etaf-reader-export-command ()
  "Export the current book's (or shelf cursor book's) annotations as Markdown."
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (book (if (eq (etaf-reader--read session :view) 'reader)
                      (etaf-reader--read session :book)
                    (let* ((id (etaf-reader--read session :shelf-cursor))
                           (items (plist-get (etaf-reader-library-page session) :items)))
                      (or (and id (seq-find (lambda (row) (equal id (plist-get row :id))) items))
                          (car items))))))
       (etaf-reader--export-book-interactive session book)))))

(defun etaf-reader--wheel (delta)
  "Scroll by DELTA lines (or turn pages)."
  (if (> delta 0)
      (etaf-reader-next-page-command)
    (etaf-reader-previous-page-command)))

(defun etaf-reader-wheel-down-command ()
  "Scroll the reader downwards."
  (etaf-reader--wheel 3))

(defun etaf-reader-wheel-up-command ()
  "Scroll the reader upwards."
  (etaf-reader--wheel -3))

;;; ---------------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------------

(defun etaf-reader--display (session)
  "Open SESSION as the reader application and return its buffer.
An open reader closes first and saves its position."
  ;; Store reads happen before mounting: creating Data Controllers inside
  ;; ETAF's publication is a render side effect and is rejected.
  (etaf-reader--write session :books (etaf-reader-store-books))
  (etaf-reader-refresh-states session)
  (etaf-reader--sync-shelf-cursor session)
  (let ((buffer
         (etaf-app-open
          etaf-reader--buffer-name (etaf-reader-view-for-session session)
          :state session
          :mode-line t
          :background (lambda ()
                        (etaf-reader-color :bg (etaf-reader--read session :theme)))
          :on-fit (lambda (window) (etaf-reader--fit session window))
          :on-close (lambda ()
                      (let ((etaf-reader-store-file (plist-get session :store-file)))
                        (etaf-reader-save-quiet session))
                      (plist-put session :buffer nil)))))
    (plist-put session :buffer buffer)
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

(defun etaf-reader--open-path (session path)
  "Open the book file at PATH in SESSION."
  (let* ((path (expand-file-name path))
         (id (etaf-reader--book-id path))
         (existing (etaf-reader-store-book id))
         (row (or existing
                  (list :id id :path path
                        :title (file-name-base path)
                        :author "" :format (upcase (file-name-extension path))
                        :cover "" :chapters 0 :chars 0 :pages 0
                        :size 0 :mtime 0 :added (floor (float-time))
                        :opened 0))))
    (etaf-reader-open-book session row)))

;;;###autoload
(defun etaf-reader-open (&optional file)
  "Open the local ebook reader and return its buffer.
FILE, when a path, is imported and opened right away; when a session from
`etaf-reader-create', that session is mounted as it is, which lets scripts
and tests display the exact state they built."
  (interactive)
  (let* ((provided (and (listp file) (plist-get file :view)))
         (session (if provided file (etaf-reader-create)))
         (etaf-reader-store-file (plist-get session :store-file))
         (etaf-reader-cache-directory (plist-get session :cache-directory))
         (buffer (etaf-reader--display session)))
    (cond
     (provided nil)
     ((and (stringp file) (file-readable-p file))
      (etaf-reader--call-in session
                            (lambda () (etaf-reader--open-path session file))))
     ((and (null (etaf-reader--read session :books))
           (seq-some #'file-directory-p etaf-reader-library-directories))
      (etaf-reader--call-in session
                            (lambda () (etaf-reader-refresh-library session)))))
    buffer))

;;;###autoload
(defun etaf-reader-open-file (file)
  "Open FILE (an ebook) in a new reader."
  (interactive "fEbook file: ")
  (etaf-reader-open file))

(defun etaf-reader--call-in (session function)
  "Run FUNCTION for SESSION reporting errors in the status line."
  (condition-case error
      (funcall function)
    (etaf-reader-error
     (etaf-reader-message session (etaf-reader--format-error error)))
    (error
     (etaf-reader-message session (format "出错：%s" error)))))

;;;###autoload
(defun etaf-reader-close ()
  "Save the reading position and close the reader."
  (interactive)
  (unless (etaf-app-state etaf-reader--buffer-name)
    (user-error "No ETAF reader is open"))
  (etaf-app-close etaf-reader--buffer-name))

(provide 'etaf-reader-app)
;;; etaf-reader-app.el ends here
