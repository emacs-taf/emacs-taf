;;; etaf-weread-app.el --- Application shell of the WeChat Reading client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one reader model to the Views.  `etaf-weread-app'
;; is the only place that reads the model's reactive sources, so a backend reply
;; or a key press repaints the whole reader in one place, and it owns the
;; session lifecycle: the palette is provided for its subtree, the current
;; section loads on mount, and the session's timers and in-flight requests are
;; released on unmount.
;;
;; `etaf-weread-open' opens the reader as an ETAF application: the buffer, the
;; root keys, the canvas background and the window-fitting layout and page
;; size.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-weread-theme)
(require 'etaf-weread-service)
(require 'etaf-weread-model)
(require 'etaf-weread-views)

;;; ---------------------------------------------------------------------------
;;; Buffer state and keys
;;; ---------------------------------------------------------------------------

(defcustom etaf-weread-buffer-name "*ETAF 微信读书*"
  "Buffer opened by `etaf-weread-open'."
  :type 'string
  :group 'etaf-weread)

(defconst etaf-weread--bindings
  '(("C-n" etaf-weread--next-item "下一项")
    ("C-p" etaf-weread--previous-item "上一项")
    ("<wheel-up>" etaf-weread--wheel-up "向上滚动")
    ("<wheel-down>" etaf-weread--wheel-down "向下滚动")
    ("<home>" etaf-weread--first-item "列表开头")
    ("<end>" etaf-weread--last-item "列表末尾")
    ("<next>" etaf-weread--next-page "下一页")
    ("<prior>" etaf-weread--previous-page "上一页")
    ("RET" etaf-weread--activate "打开书籍／激活控件")
    ("C-v" etaf-weread--scroll-pane-down "面板下一页")
    ("M-v" etaf-weread--scroll-pane-up "面板上一页")
    ("SPC" etaf-weread--scroll-pane-down "面板下一页")
    ("S-SPC" etaf-weread--scroll-pane-up "面板上一页")
    ("v" etaf-weread--toggle-pane "切换面板")
    ("d" etaf-weread--detail-pane "书籍详情")
    ("P" etaf-weread--notes-pane "书籍划线")
    ("o" etaf-weread--open-book "在浏览器阅读")
    ("E" etaf-weread--export-notes "导出笔记")
    ("s" etaf-weread--shelf "全部书架")
    ("n" etaf-weread--notebook "笔记本")
    ("i" etaf-weread--index-section "本地笔记检索")
    ("I" etaf-weread--build-index "建立本地笔记索引")
    ("t" etaf-weread--stats "阅读统计")
    ("/" etaf-weread--search "搜索书城")
    ("S" etaf-weread--search "搜索书城")
    ("1" etaf-weread--shelf "全部书架")
    ("2" etaf-weread--reading "在读书籍")
    ("3" etaf-weread--finished "已读书籍")
    ("4" etaf-weread--notebook "笔记本")
    ("5" etaf-weread--search "搜索书城")
    ("6" etaf-weread--stats "阅读统计")
    ("7" etaf-weread--index-section "本地笔记检索")
    ("g" etaf-weread--refresh "刷新")
    ("G" etaf-weread--last-item "列表末尾")
    ("T" etaf-weread--cycle-theme "切换深浅／纸色主题")
    ("C-c h" etaf-help "查看快捷键")
    ("q" etaf-weread-close "关闭阅读器"))
  "Root keys of the reader and their short help labels.
They replace the renderer's scrolling keys with reader commands: the wheel
and page keys move the selection or scroll the side pane, `v' switches the
side pane and `o' opens the selected book in the browser.  RET reaches a
focused control first and otherwise opens the selection.")

(defun etaf-weread--direction (direction)
  "Move the Weread selection or scroll the side pane with DIRECTION.
Point stays where it was, so a following RET keeps falling back to the
selection the reader promises instead of a row under a revealed point."
  (pcase direction
    ('down (save-excursion (etaf-weread--next-item)) 'handled)
    ('up (save-excursion (etaf-weread--previous-item)) 'handled)
    (_ 'release)))

(defvar-local etaf-weread--buffer-model nil
  "Reader session the current buffer shows, or nil.
An ordinary application buffer records its state through `etaf-app-open'; a
floating panel or a desktop host mounts the View directly, so the reader
records its session here when it mounts and the commands find it either way.")

;;;###autoload
(defun etaf-weread-session (&optional buffer)
  "Return the reader session mounted in BUFFER-OR-NAME, or nil.
BUFFER-OR-NAME defaults to the current buffer.  `etaf-weread-open' records its
session through `etaf-app-open', and a host that mounts `etaf-weread-view'
records it when the View mounts, so a command or a host finds the reader it
acts on; a buffer without a mounted reader returns nil."
  (let ((buffer (get-buffer (or buffer (current-buffer)))))
    (and (buffer-live-p buffer)
         (or (buffer-local-value 'etaf-weread--buffer-model buffer)
             (etaf-app-state buffer)))))

(defun etaf-weread--current-model ()
  "Return the model of the current reader buffer."
  (or (etaf-weread-session)
      (user-error "Current buffer is not an etaf-weread reader")))

;;; ---------------------------------------------------------------------------
;;; Model to View projections
;;; ---------------------------------------------------------------------------

(defun etaf-weread--view-entries (model)
  "Return MODEL's visible book rows as list entries."
  (pcase-let* ((`(,rows ,start ,_total) (etaf-weread--page-rows model))
               (selection (etaf-weread--read model :selection)))
    (cl-loop for row in rows
             for index from start
             collect (list :index (1+ index)
                           :row row
                           :selected (= index selection)))))

(defun etaf-weread--pane-chapters (model)
  "Return the visible chapter lines of MODEL's detail pane."
  (let* ((detail (etaf-weread--read model :detail))
         (chapters (plist-get detail :chapters))
         (rows (max 1 (etaf-weread--read model :pane-rows)))
         (scroll (max 0 (min (etaf-weread--read model :pane-scroll)
                             (max 0 (- (length chapters) rows))))))
    (when chapters
      (seq-subseq chapters scroll (min (length chapters) (+ scroll rows))))))

(defun etaf-weread--pane-lines (model)
  "Return the visible lines of MODEL's highlight pane.
The pane shares its scroll and row budget with the painted rows, so the scroll
clamps and the lines always agree."
  (let* ((lines (etaf-weread--notes-lines
                 (plist-get (etaf-weread--read model :notes) :groups)))
         (rows (max 1 (etaf-weread--read model :pane-rows)))
         (scroll (max 0 (min (etaf-weread--read model :pane-scroll)
                             (max 0 (- (length lines) rows))))))
    (when lines
      (seq-subseq lines scroll (min (length lines) (+ scroll rows))))))

(defun etaf-weread--search-text (model text)
  "Search TEXT in MODEL, reporting an empty keyword in the status line.
In the local index section TEXT filters the highlights instead of the store,
which is why the same field serves both places."
  (if (eq (etaf-weread--read model :mode) 'index)
      (progn
        (etaf-weread--write model :index-query (or text ""))
        (etaf-weread--index-reload model))
    (etaf-weread--write model :query (or text ""))
    (if (string-empty-p (string-trim (or text "")))
        (etaf-weread--write model :message "输入关键词后开始搜索")
      (condition-case error
          (etaf-weread-search model text)
        (etaf-weread-error (etaf-weread--write model :message (error-message-string error)))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun etaf-weread--next-item ()
  "Move the book selection down."
  (interactive)
  (etaf-weread-move-selection (etaf-weread--current-model) 1))

(defun etaf-weread--previous-item ()
  "Move the book selection up."
  (interactive)
  (etaf-weread-move-selection (etaf-weread--current-model) -1))

(defun etaf-weread--pane-hit-p (xy columns _rows layout pane)
  "Return non-nil when text-cell position XY hits the visible side pane.
COLUMNS describes the event window; LAYOUT and PANE describe the reader."
  (and (memq pane '(detail notes))
       (consp xy) (numberp (car xy)) (numberp (cdr xy))
       (< 0 (cdr xy))
       (if (eq layout 'wide)
           (and (> (car xy) (max 0 (- columns (cadr etaf-weread--pane-width))))
                (< (car xy) columns))
         t)))

(defun etaf-weread--wheel (event delta)
  "Scroll the side pane or move the book selection by DELTA at EVENT's position."
  (let* ((position (event-start event))
         (window (posn-window position)))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (let* ((model (etaf-weread--current-model))
               (pixels (posn-x-y position))
               (xy (and (consp pixels)
                        (cons (/ (float (car pixels)) (window-font-width window))
                              (/ (float (cdr pixels)) (window-font-height window))))))
          (if (and (null (posn-area position))
                   (etaf-weread--pane-hit-p
                    xy (window-body-width window) (window-body-height window)
                    (etaf-weread--read model :layout) (etaf-weread--read model :pane)))
              (etaf-weread-scroll-pane model delta)
            (etaf-weread-move-selection model delta)))))))

(defun etaf-weread--wheel-up (event)
  "Scroll the side pane or select the previous book at EVENT."
  (interactive "e")
  (etaf-weread--wheel event -1))

(defun etaf-weread--wheel-down (event)
  "Scroll the side pane or select the next book at EVENT."
  (interactive "e")
  (etaf-weread--wheel event 1))

(defun etaf-weread--first-item ()
  "Select the first book of the list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (- (plist-get state :selection)))))

(defun etaf-weread--last-item ()
  "Select the last book of the list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (- (1- (or (plist-get state :rows-total) 1))
                                         (plist-get state :selection)))))

(defun etaf-weread--next-page ()
  "Select one page further down the book list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (or (plist-get state :page-size) 10))))

(defun etaf-weread--previous-page ()
  "Select one page further up the book list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (- (or (plist-get state :page-size) 10)))))

(defun etaf-weread--activate ()
  "Open the selected book's detail or highlights.
A focused control or the pressable Host at point takes RET before this root
key, so this only runs where moving the selection left point."
  (interactive)
  (etaf-weread-activate-selection (etaf-weread--current-model)))

(defun etaf-weread--scroll-pane-down ()
  "Scroll the side pane one page down.
The wheel scrolls the pane under the pointer; these keys give the same
ability to a keyboard, which otherwise cannot move a long table of contents
or highlight list."
  (interactive)
  (let ((model (etaf-weread--current-model)))
    (etaf-weread-scroll-pane model (max 1 (etaf-weread--read model :pane-rows)))))

(defun etaf-weread--scroll-pane-up ()
  "Scroll the side pane one page up."
  (interactive)
  (let ((model (etaf-weread--current-model)))
    (etaf-weread-scroll-pane model (- (max 1 (etaf-weread--read model :pane-rows))))))

(defun etaf-weread--toggle-pane ()
  "Switch between the book list, the book card and the highlights."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (pane (etaf-weread--read model :pane)))
    (if (eq pane 'list)
        (progn
          (etaf-weread--write model :pane 'detail)
          (etaf-weread--schedule-detail model (etaf-weread--selected-id model)))
      (etaf-weread-toggle-pane model))))

(defun etaf-weread--detail-pane ()
  "Show the book detail pane."
  (interactive)
  (etaf-weread-show-pane (etaf-weread--current-model) 'detail))

(defun etaf-weread--notes-pane ()
  "Show the highlights pane of the selected book."
  (interactive)
  (let ((model (etaf-weread--current-model)))
    (etaf-weread-show-book model (etaf-weread--selected-row model) 'notes)))

(defun etaf-weread--open-book ()
  "Open the selected book in the browser's WeChat Reading reader."
  (interactive)
  (condition-case error
      (etaf-weread-open-book (etaf-weread--current-model))
    (etaf-weread-error (message "%s" (error-message-string error)))))

(defun etaf-weread--export-notes ()
  "Export the selected book's highlights and thoughts as Markdown."
  (interactive)
  (condition-case error
      (etaf-weread-export-notes (etaf-weread--current-model))
    (etaf-weread-error (message "%s" (error-message-string error)))))

(defun etaf-weread--shelf ()
  "Show the whole shelf."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :shelf))

(defun etaf-weread--reading ()
  "Show the books currently being read."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :reading))

(defun etaf-weread--finished ()
  "Show the finished books."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :finished))

(defun etaf-weread--notebook ()
  "Show the books with highlights and thoughts."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :notebook))

(defun etaf-weread--index-section ()
  "Show the local SQLite index of highlights."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :index))

(defun etaf-weread--build-index (&optional refresh)
  "Index the notebook's highlights into the local SQLite index.
With prefix argument REFRESH, re-fetch books that are already indexed."
  (interactive "P")
  (etaf-weread-index-notebook (etaf-weread--current-model) refresh))

(defun etaf-weread--stats ()
  "Show the reading statistics."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :stats))

(defun etaf-weread--search ()
  "Search the WeChat Reading store."
  (interactive)
  (etaf-weread--search-text (etaf-weread--current-model)
                            (read-string "搜索书名或作者：")))

(defun etaf-weread--refresh ()
  "Reload the current list, account and statistics."
  (interactive)
  (etaf-weread-refresh (etaf-weread--current-model)))

(defun etaf-weread--cycle-theme ()
  "Switch the reader to the next palette.
The reader's mode cell is its one appearance state, and every View reads it
while rendering, so the reader and a panel framing it repaint together."
  (interactive)
  (etaf-weread-cycle-theme (etaf-weread--current-model)))


;;; ---------------------------------------------------------------------------
;;; Application Component and entry points
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-weread-app (&key model)
  "Render the reader for MODEL and own its session lifecycle.
MODEL must come from `etaf-weread-create'.  Mounting provides the palette for
the subtree, fits the layout and loads the current section; unmounting releases
the session's timers and pending backend requests."
  :bindings ((session (or model
                          (signal 'etaf-weread-error
                                  '("etaf-weread-app needs the :model from `etaf-weread-create'"))))
             (palette (etaf-weread--ref session :theme))
             ;; Callbacks are instance values, not per-render closures: a
             ;; re-render that passes a new function object to a keyed child
             ;; would make that child render again for nothing.
             (on-locate (lambda (section) (etaf-weread-locate session section)))
             (on-search (lambda (text) (etaf-weread--search-text session text)))
             (on-refresh (lambda () (etaf-weread-refresh session)))
             (on-press-row (lambda (index) (etaf-weread-press-row session index)))
             (on-open-book (lambda () (etaf-weread--open-book-in session)))
             (on-export-notes (lambda () (etaf-weread--export-in session)))
             (on-pane (lambda (target)
                        (if (eq target 'list)
                            (etaf-weread--write session :pane 'list)
                          (etaf-weread-show-pane session target)))))
  :setup
  (progn
    (etaf-theme-provide palette)
    ;; One appearance state for the reader and the panel that frames it: the
    ;; palette follows the reader's mode cell, and a host paints from the same
    ;; cell, so `T' and a title-bar switch repaint both.
    (etaf-watch (lambda () (etaf-weread-theme-defaults))
                (lambda (theme _old) (etaf-weread--write session :theme theme))
                :immediate t :test #'equal :name 'etaf-weread-theme)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme palette
                            :mode etaf-weread--theme-mode
                            :modes etaf-weread--surface-modes))
    (etaf-on-mounted
     (lambda ()
       ;; A host mounts this View without `etaf-app-open', so record the
       ;; session and the buffer it renders into: the keys find the session,
       ;; and the background refresh knows whether anyone can see it.
       (when-let* ((runtime (etaf-current-runtime))
                   (buffer (and runtime (etaf-runtime-buffer runtime))))
         (when (buffer-live-p buffer)
           (plist-put session :buffer buffer)
           (with-current-buffer buffer
             (setq-local etaf-weread--buffer-model session))))
       (etaf-weread--start session)
       (etaf-weread-refresh session)))
    (etaf-on-unmounted
     (lambda ()
       (when-let* ((runtime (etaf-current-runtime))
                   (buffer (and runtime (etaf-runtime-buffer runtime))))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (eq etaf-weread--buffer-model session)
               (kill-local-variable 'etaf-weread--buffer-model))))
         (when (eq (plist-get session :buffer) buffer)
           (plist-put session :buffer nil)))
       (etaf-weread--dispose session))))
  :view
  (flex :flex-direction 'column :width '(vw 100) :height '(vh 100)
        :ref 'weread-root :aria-label "微信读书"
        :help '("书架与笔记来自微信读书账号；本地笔记索引支持离线检索。"
                "搜索随当前内容切换：书城或笔记索引。")
        ;; One clear line above the chrome keeps the header off the window
        ;; edge; the layout chrome counts this line.
        :padding-top '(lh 1)
        ;; Rows that show symbol glyphs render a little taller than the frame's
        ;; line height because their fallback font has larger metrics.  Keep the
        ;; last line clear so those extra pixels land in empty space.
        :padding-bottom '(lh 1)
        :on-direction #'etaf-weread--direction
        ;; The reader's keys belong to its root Host, so every host that mounts
        ;; this View keeps them: an ordinary application buffer, a floating
        ;; panel and a desktop host alike.
        :keys etaf-weread--bindings
        :color (etaf-weread-color :ink) :bgcolor (etaf-weread-color :bg)
    (flex :width 'stretch :flex-grow 1 :flex-basis 'auto :min-height '(lh 0)
          :align-items 'stretch
      (etaf-weread--view-sidebar
       :if (eq (etaf-weread--read session :layout) 'wide)
       :groups etaf-weread-sections
       :section (etaf-weread--read session :section)
       :on-locate on-locate)
      (etaf-weread--view-sidebar
       :if (eq (etaf-weread--read session :layout) 'medium)
       :compact t
       :groups etaf-weread-sections
       :section (etaf-weread--read session :section)
       :on-locate on-locate)
      (flex :if (etaf-weread--list-shown-p session)
            :flex-direction 'column :width 'stretch :flex-grow 1
            :flex-basis 'auto :min-width '(ch 0) :min-height '(lh 0)
            :padding (if (etaf-weread--compact-layout-p session)
                         '((lh 0) (ch 1)) '((lh 1) (ch 2)))
            :gap '((lh 1) (px 0))
        (etaf-weread--view-header
         :title (etaf-weread--read session :title)
         :subtitle (etaf-weread--read session :subtitle)
         :query (etaf-weread--read session
                                  (if (eq (etaf-weread--read session :mode) 'index)
                                      :index-query
                                    :query))
         :placeholder (if (eq (etaf-weread--read session :mode) 'index)
                          "搜索本地笔记"
                        "搜索书名或作者")
         :mode (etaf-weread--read session :mode)
         :loading (etaf-weread--read session :loading)
         :compact (etaf-weread--compact-layout-p session)
         :on-search on-search
         :on-refresh on-refresh)
        (etaf-weread--view-chips
         :if (eq (etaf-weread--read session :layout) 'narrow)
         :groups etaf-weread-sections
         :section (etaf-weread--read session :section)
         :on-locate on-locate)
        (etaf-weread--view-list
         :entries (etaf-weread--view-entries session)
         :start (1+ (nth 1 (etaf-weread--page-rows session)))
         :total (etaf-weread--read session :list-total)
         :loaded (length (etaf-weread--read session :rows))
         :compact (etaf-weread--compact-layout-p session)
         :loading (etaf-weread--read session :loading)
         :empty-note (cond ((etaf-weread--read session :loading) "正在加载…")
                           ((eq (etaf-weread--read session :mode) 'index)
                            "本地索引为空：按 I 索引笔记本，或先翻几本书的笔记")
                           ((eq (etaf-weread--read session :mode) 'search)
                            "输入关键词后开始搜索")
                           (t "这里还没有内容：g 刷新"))
         :on-press on-press-row))
      (flex :if (etaf-weread--pane-shown-p session)
            :flex-direction 'column
            ;; The card and highlight panes keep their fixed column; a compact
            ;; layout gives the shown pane the whole body.
            :width (unless (etaf-weread--compact-layout-p session)
                     etaf-weread--pane-width)
            :flex-grow (if (etaf-weread--compact-layout-p session) 1 0)
            :flex-shrink 0
            :flex-basis 'auto
            :min-width '(ch 0) :min-height '(lh 0)
            :background-color (etaf-weread-color :panel)
            :border-left (etaf-weread--view-border 'left (etaf-weread-color :line))
        (etaf-weread--view-stats
         :if (eq (etaf-weread--read session :mode) 'stats)
         :stats (etaf-weread--read session :stats))
        (etaf-weread--view-detail
         :if (and (not (eq (etaf-weread--read session :mode) 'stats))
                  (eq (etaf-weread--effective-pane session) 'detail))
         :detail (etaf-weread--read session :detail)
         :pane (etaf-weread--effective-pane session)
         :chapters (etaf-weread--pane-chapters session)
         :on-open on-open-book
         :on-export on-export-notes
         :on-pane on-pane)
        (etaf-weread--view-notes
         :if (and (not (eq (etaf-weread--read session :mode) 'stats))
                  (eq (etaf-weread--effective-pane session) 'notes))
         :notes (etaf-weread--read session :notes)
         :pane (etaf-weread--effective-pane session)
         :lines (etaf-weread--pane-lines session)
         :on-pane on-pane
         :on-open on-open-book)))
    (etaf-weread--view-tabs
     ;; The switch moves between the list, the card and the highlights on a
     ;; compact layout.
     :if (and (etaf-weread--compact-layout-p session)
              (memq (etaf-weread--read session :pane) '(list detail notes)))
     :pane (etaf-weread--read session :pane)
     :layout (etaf-weread--read session :layout)
     :on-pane on-pane)
    (etaf-weread--view-footer
     :hint etaf-weread--footer-hint
     :account (etaf-weread--read session :account)
     :summary (etaf-weread--read session :summary)
     :message (etaf-weread--read session :message)
     :error (etaf-weread--read session :error)
     :compact (etaf-weread--compact-layout-p session))))

(defun etaf-weread--open-book-in (app)
  "Open APP's selected book in the browser, reporting a failure in the status line."
  (condition-case error
      (etaf-weread-open-book app)
    (etaf-weread-error (etaf-weread--write app :message (error-message-string error)))))

(defun etaf-weread--export-in (app)
  "Export APP's selected book, reporting a failure in the status line."
  (condition-case error
      (etaf-weread-export-notes app)
    (etaf-weread-error (etaf-weread--write app :message (error-message-string error)))))

(defun etaf-weread--mounted-session ()
  "Return the session of the mounted reader, or nil."
  (etaf-app-state etaf-weread-buffer-name))

(defun etaf-weread--login-sentence (result)
  "Return what to show for a login or logout RESULT."
  (if (eq (car result) :ok)
      (or (etaf-weread--string (plist-get (cadr result) :conclusion))
          "微信读书：已登录")
    (let ((message (or (cadr result) "微信读书登录失败"))
          (hint (plist-get (cddr result) :hint)))
      (if (and hint (not (string-empty-p hint)))
          (format "%s（%s）" message hint)
        message))))

(defun etaf-weread-login (&optional app)
  "Sign in to WeChat Reading and load the account again.
The bundled backend reuses a signed-in controlled browser, otherwise reads the
local Chrome session, and otherwise opens the browser at the QR page and waits
up to `etaf-weread-login-timeout' seconds for the scan.  APP defaults to the
mounted reader: the progress and the reply are shown in its status line and
the account, the lists and the statistics are reloaded when the login
succeeds.  With no reader open the reply is reported in the echo area, and a
reader opened while the browser waited is refreshed.  Return APP, or nil when
the login ran without a session."
  (interactive)
  (let* ((app (or app (etaf-weread--mounted-session)))
         (starting "正在登录微信读书：必要时在浏览器里扫码…"))
    (if app
        (progn
          (etaf-weread--note app starting)
          (etaf-weread--call
           app (list :op :login :timeout etaf-weread-login-timeout)
           :on-ok (lambda (data)
                    (etaf-weread--note
                     app (or (etaf-weread--string (plist-get data :conclusion))
                             "微信读书：已登录"))
                    (etaf-weread-refresh app))))
      (message "%s" starting)
      (etaf-weread-client-call
       (etaf-weread-make-client)
       (list :op :login :timeout etaf-weread-login-timeout)
       (lambda (result)
         (message "微信读书：%s" (etaf-weread--login-sentence result))
         (when-let* ((mounted (and (eq (car result) :ok)
                                   (etaf-weread--mounted-session))))
           (etaf-weread-refresh mounted)))))
    app))

(defun etaf-weread--forget-account (app)
  "Drop APP's account, its loaded lists and the open book.
A reply still in flight is dropped too, so nothing repopulates the reader with
the account that just signed out."
  (setf (plist-get app :generation) (1+ (plist-get app :generation)))
  (etaf-list-cache-disarm (plist-get app :list-cache))
  (setf (plist-get app :list-cache) (etaf-list-cache-create :grace 3))
  (etaf-batch
    (etaf-weread--write app :account nil)
    (etaf-weread--write app :summary "")
    (etaf-weread--write app :stats nil)
    (etaf-weread--write app :rows nil)
    (etaf-weread--write app :list-total 0)
    (etaf-weread--write app :selection 0)
    (etaf-weread--write app :window-start 0)
    (etaf-weread--write app :detail nil)
    (etaf-weread--write app :notes nil)
    (etaf-weread--write app :loading nil)
    (etaf-weread--write app :error nil))
  ;; The disarmed cache above still holds the signed-out account's lists; a
  ;; mounted reader arms the refresh timer again for the fresh one, and a
  ;; headless session never armed a timer.
  (when (plist-get app :started-at)
    (etaf-weread--schedule-prefetch app))
  (etaf-weread--sync-pane-total app))

(defun etaf-weread-logout (&optional app)
  "Sign out of WeChat Reading and forget what was loaded from the account.
Only the login saved by the bundled backend is deleted; the WeChat Reading
account itself is left alone.  APP defaults to the mounted reader and drops
its account, loaded lists and open book at once, naming
`etaf-weread-login' in the status line.  With no reader open the reply is
reported in the echo area.  Return APP, or nil when the logout ran without a
session."
  (interactive)
  (let ((app (or app (etaf-weread--mounted-session))))
    (if app
        (progn
          (etaf-weread--note app "正在退出微信读书登录…")
          (etaf-weread--call
           app (list :op :logout)
           :on-ok (lambda (_data)
                    (etaf-weread--forget-account app)
                    (etaf-weread--note
                     app (format "已退出登录：%s 重新登录"
                                 etaf-weread--sign-in-command)))))
      (etaf-weread-client-call
       (etaf-weread-make-client) (list :op :logout)
       (lambda (result)
         (message "微信读书：%s" (etaf-weread--login-sentence result)))))
    app))

(defun etaf-weread-view (&optional model)
  "Return the reader View for MODEL.
MODEL defaults to a new session, exactly as `etaf-weread-open' creates one;
pass a session from `etaf-weread-create' to embed the reader in your own mount.
The View carries the reader's keys on its root Host, so a host that mounts it
keeps them."
  (etaf-view (etaf-weread-app :model (or model (etaf-weread-create)))))

(defun etaf-weread-open (&optional model)
  "Open the WeChat Reading reader and return its buffer.
MODEL defaults to a session from `etaf-weread-create', so the reader opens on
the shelf with the signed-in account.  A caller-provided MODEL keeps its
section, selection and loaded detail.  The layout, page size and canvas
height come from the window that shows the reader, so the first paint
already fits it, and they follow each settled resize; a window whose lines a
minibuffer borrows keeps its layout until they return.  Cells the reader
does not paint, such as the sub-cell remainder at the window edge, take the
palette background."
  (interactive)
  (let* ((model (or model (etaf-weread-create)))
         (buffer
          (etaf-app-open
           etaf-weread-buffer-name (etaf-weread-view model)
           :state model
           :background (lambda () (plist-get (etaf-weread--read model :theme) :ui-bg))
           :on-fit (lambda (window)
                     (plist-put model :buffer (current-buffer))
                     (etaf-weread--sync-layout model window)))))
    (plist-put model :buffer buffer)
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

(defun etaf-weread-close ()
  "Unmount the reader and kill its buffer."
  (interactive)
  (when (etaf-app-state etaf-weread-buffer-name)
    (etaf-app-close etaf-weread-buffer-name)))

(provide 'etaf-weread-app)
;;; etaf-weread-app.el ends here
