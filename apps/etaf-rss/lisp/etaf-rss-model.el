;;; etaf-rss-model.el --- Session state and actions of the RSS reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; One session is a plist of `etaf-ref' reactive sources plus the bookkeeping
;; the actions share.  Every displayed value is read from a source, so a
;; backend reply or a key press repaints the mounted reader through the one
;; boundary in `etaf-rss-app'; the model itself owns no buffer and no timer
;; until `etaf-rss--start' arms them, which is what makes it a complete
;; headless reader for scripts and tests.
;;
;; The model talks to a service client with plist requests and never touches
;; the store or the network directly.  Replies are guarded by a generation
;; counter: a reply belonging to a superseded scope or search is dropped
;; rather than painted over the current one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-rss-theme)
(require 'etaf-rss-parse)
(require 'etaf-rss-service)
(require 'etaf-rss-store)
(require 'etaf-rss-miniflux)


;;; ---------------------------------------------------------------------------
;;; Geometry and timing
;;; ---------------------------------------------------------------------------

(defconst etaf-rss--sidebar-columns 24
  "Width of the subscription sidebar in a wide layout.")

(defconst etaf-rss--sidebar-narrow-columns 18
  "Width of the narrow subscription sidebar in a medium layout.")

(defconst etaf-rss--list-min-columns 36
  "Narrowest article list that still shows a title and a date.")

(defconst etaf-rss--list-inset 2
  "Horizontal padding of the article list in columns, one side.
The list and the reading pane each inset their content, so the reading width
budget has to leave both insets out.  It is the `(ch 2)' padding the list
pane declares.")

(defconst etaf-rss--reader-inset 4
  "Columns the reading pane spends on its own horizontal insets.")

(defcustom etaf-rss-reading-measure 58
  "Preferred width of the article reading column, in columns.
The column is capped by what the pane can hold, so a narrow frame shrinks it
instead of clipping; a very wide frame does not stretch prose across the
screen."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-wide-columns 118
  "Frame width, in columns, that fits the sidebar, the list and the reader.
At or above this width the reader shows all three columns."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-medium-columns 72
  "Frame width, in columns, that still fits the glyph-only scope rail.
At or above this width, but below `etaf-rss-wide-columns', the rail stays and
one content pane is shown at a time; below it the scopes move into a header
strip."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-page-size 14
  "Article rows shown at once by a headless session.
A mounted reader replaces it with the count that fits its window."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-list-limit 300
  "Most rows one scope loads.
The list pages through them by viewport; a scope with more articles reports
its full total and the loaded count separately."
  :type 'integer
  :group 'etaf-rss)

(defcustom etaf-rss-follow-delay 0.45
  "Seconds of quiet before the reading pane follows the selection.
Browsing faster than this never loads (or marks read) an article that was
only passed over."
  :type 'number
  :group 'etaf-rss)

(defcustom etaf-rss-mark-read-delay 1.0
  "Seconds an article stays open before it is marked read.
The delay keeps fast browsing from marking every article it passes; a reader
that stops on one marks it, and `etaf-rss-toggle-read' flips it back."
  :type 'number
  :group 'etaf-rss)

(defcustom etaf-rss-refresh-interval 900
  "Seconds between automatic feed refreshes of a mounted reader.
The refresh runs in the background and never blocks the interface; set it to
nil to refresh only on request."
  :type '(choice (const :tag "Never" nil) integer)
  :group 'etaf-rss)

;;; ---------------------------------------------------------------------------
;;; Construction
;;; ---------------------------------------------------------------------------

(defcustom etaf-rss-backend 'local
  "Backend a new session reads: `local' or `miniflux'.
`local' keeps subscriptions, articles and reading state in
`etaf-rss-data-file'.  `miniflux' reads a self-hosted Miniflux server through
`etaf-rss-miniflux-client', configured by `etaf-rss-miniflux-url' and
`etaf-rss-miniflux-token'.  Both backends show the same reader."
  :type '(choice (const :tag "Local JSON store" local)
                 (const :tag "Miniflux server" miniflux))
  :group 'etaf-rss)

;;; ---------------------------------------------------------------------------
;;; Construction
;;; ---------------------------------------------------------------------------

(cl-defun etaf-rss-create (&key client)
  "Create an RSS reader session that talks to CLIENT.
CLIENT defaults to `etaf-rss-client-factory' when that is bound and otherwise
to the backend named by `etaf-rss-backend'.  It may also be a backend symbol
(`local' or `miniflux') or a client from `etaf-rss-miniflux-client'; any
client keeps a whole session offline when it is scripted.
The session owns no buffer and no timer before it is mounted, so it is also a
complete headless reader for scripts and tests."
  (let* ((client (cond ((consp client) client)
                       ((functionp client) client)
                       ((memq client '(local miniflux)) client)
                       (client)
                       (etaf-rss-client-factory
                        (funcall etaf-rss-client-factory))
                       (t etaf-rss-backend)))
         (client (pcase client
                   ('local (etaf-rss-make-client))
                   ('miniflux (etaf-rss-miniflux-client))
                   (_ client))))
    (list :client client
          :buffer nil
          :disposed nil
          :started-at nil
          :generation 0
          :article-generation 0
          :list-key nil
          :article-cache (make-hash-table :test 'equal)
          :follow-timer nil
          :refresh-timer nil
          :scope (etaf-ref (list :kind :all) :name 'etaf-rss-scope)
          :scope-label (etaf-ref "全部文章" :name 'etaf-rss-scope-label)
          :scope-subtitle (etaf-ref "" :name 'etaf-rss-scope-subtitle)
          :feeds (etaf-ref [] :name 'etaf-rss-feeds)
          :collapsed (etaf-ref nil :name 'etaf-rss-collapsed)
          :total (etaf-ref 0 :name 'etaf-rss-total)
          :unread (etaf-ref 0 :name 'etaf-rss-unread)
          :starred-count (etaf-ref 0 :name 'etaf-rss-starred-count)
          :rows (etaf-ref [] :name 'etaf-rss-rows)
          :list-total (etaf-ref 0 :name 'etaf-rss-list-total)
          :selection (etaf-ref 0 :name 'etaf-rss-selection)
          :window-start (etaf-ref 0 :name 'etaf-rss-window-start)
          :window-rows (etaf-ref 0 :name 'etaf-rss-window-rows)
          :window-columns (etaf-ref 0 :name 'etaf-rss-window-columns)
          :page-size (etaf-ref etaf-rss-page-size :name 'etaf-rss-page-size)
          :pane (etaf-ref 'list :name 'etaf-rss-pane)
          :layout (etaf-ref 'wide :name 'etaf-rss-layout)
          :reader-id (etaf-ref nil :name 'etaf-rss-reader-id)
          :reader-title (etaf-ref "" :name 'etaf-rss-reader-title)
          :reader-meta (etaf-ref "" :name 'etaf-rss-reader-meta)
          :reader-blocks (etaf-ref nil :name 'etaf-rss-reader-blocks)
          :reader-lines (etaf-ref nil :name 'etaf-rss-reader-lines)
          :reader-scroll (etaf-ref 0 :name 'etaf-rss-reader-scroll)
          :reader-rows (etaf-ref 10 :name 'etaf-rss-reader-rows)
          :reader-columns (etaf-ref etaf-rss-reading-measure :name 'etaf-rss-reader-columns)
          :reader-wrapped (etaf-ref 0 :name 'etaf-rss-reader-wrapped)
          :reader-loading (etaf-ref nil :name 'etaf-rss-reader-loading)
          :reader-error (etaf-ref nil :name 'etaf-rss-reader-error)
          :reader-read (etaf-ref nil :name 'etaf-rss-reader-read)
          :reader-starred (etaf-ref nil :name 'etaf-rss-reader-starred)
          :reader-url (etaf-ref nil :name 'etaf-rss-reader-url)
          :query (etaf-ref "" :name 'etaf-rss-query)
          :theme-mode etaf-rss--theme-mode
          :theme (etaf-ref (etaf-rss-theme-defaults) :name 'etaf-rss-theme)
          :loading (etaf-ref nil :name 'etaf-rss-loading)
          :refreshing (etaf-ref nil :name 'etaf-rss-refreshing)
          :refresh-done (etaf-ref 0 :name 'etaf-rss-refresh-done)
          :refresh-total (etaf-ref 0 :name 'etaf-rss-refresh-total)
          :error (etaf-ref nil :name 'etaf-rss-error)
          :message (etaf-ref nil :name 'etaf-rss-message))))

(defun etaf-rss--ref (app key)
  "Return APP's reactive source named KEY."
  (plist-get app key))

(defun etaf-rss--read (app key)
  "Return APP's current value for KEY, tracked while rendering."
  (etaf-value (etaf-rss--ref app key)))

(defun etaf-rss--write (app key value)
  "Publish VALUE as APP's new value for KEY; return VALUE.
A write that would not change the reading is skipped: the reader repaints on
every write, and a reply that repeats the previous reading would otherwise
repaint the whole view for nothing."
  (let ((ref (etaf-rss--ref app key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

(defun etaf-rss--client (app)
  "Return APP's service client."
  (plist-get app :client))

(cl-defun etaf-rss--call (app request &key on-ok on-error)
  "Send REQUEST for APP, routing a failure into the visible status line.
ON-OK receives the reply data and ON-ERROR the failure message, its hint and
its feed id when the service reported one.  A client that signals while
turning the request into a call is reported like any other failure, so
nothing reaches the caller of a reader action."
  (let ((delivered nil)
        (fail (lambda (message hint feed-id)
                (etaf-rss--write app :error message)
                (etaf-rss--write app :message
                                 (if (and hint (not (string-empty-p hint)))
                                     (format "%s（%s）" message hint)
                                   message))
                (when on-error (funcall on-error message hint feed-id)))))
    (condition-case error
        (etaf-rss-client-call
         (etaf-rss--client app) request
         (lambda (result)
           (setq delivered t)
           (if (eq (car result) :ok)
               (progn
                 (etaf-rss--write app :error nil)
                 (when on-ok (funcall on-ok (cadr result))))
             (funcall fail (or (cadr result) "请求失败")
                      (plist-get (cddr result) :hint)
                      (plist-get (cddr result) :feed-id)))))
      (error (unless delivered
               (funcall fail (error-message-string error) nil nil))))))

(defun etaf-rss--note (app text)
  "Show TEXT as APP's status line message."
  (etaf-rss--write app :message text))

(defun etaf-rss--fit-now (app)
  "Publish APP and trim its panes to the window, when it is displayed.
Every action that changes which chrome the reader paints ends here, so the
canvas fits again as soon as the reading pane gains its title, meta line or
article, not only when the window resizes."
  (when-let* ((buffer (plist-get app :buffer))
              (runtime (and (buffer-live-p buffer)
                            (etaf-runtime-for-buffer buffer)))
              (window (and (buffer-live-p buffer)
                           (get-buffer-window buffer t))))
    (etaf-runtime-flush runtime)
    (etaf-rss--fit-height app window)))

(defun etaf-rss--fit-height (app window)
  "Paint APP inside WINDOW's body rows.
The row budgets above the panes are constants, so a layout change or a
text-scale change can leave the painted canvas a row taller than the window;
a buffer taller than its window scrolls as a whole, which would carry the
sidebar and the list along with the article.  The fit measures the painted
canvas and shrinks both panes by the excess rows, at most twice."
  (when (and (window-live-p window)
             (buffer-live-p (plist-get app :buffer))
             (eq (window-buffer window) (plist-get app :buffer)))
    ;; The fit counts rows on the canvas that was painted, so its row height
    ;; is the canvas's line, not the frame's own face.
    (let ((row (max 1 (or (plist-get (ignore-errors (etaf-display-metrics)) :line-height)
                         (frame-char-height (window-frame window)))))
          (attempts 0))
      (while (< attempts 2)
        (setq attempts (1+ attempts))
        (let* ((body (window-body-height window t))
               (painted (with-selected-window window
                          (cdr (window-text-pixel-size window (point-min)
                                                       (point-max) nil (1+ body))))))
          (if (<= painted body)
              (setq attempts 2)
            (let ((excess (max 1 (ceiling (- painted body) (float row)))))
              (etaf-batch
                ;; The shell is pinned to `:window-rows', so the excess is
                ;; trimmed there too; otherwise the panes shrink inside a
                ;; canvas that is still a row taller than the window.
                (etaf-rss--write app :window-rows
                                 (max 8 (- (etaf-rss--read app :window-rows) excess)))
                (etaf-rss--write app :page-size
                                 (max 1 (- (etaf-rss--read app :page-size) excess)))
                (etaf-rss--write app :reader-rows
                                 (max 3 (- (etaf-rss--read app :reader-rows) excess)))
                (etaf-rss--clamp-position app))
              (when-let* ((runtime (etaf-runtime-for-buffer (plist-get app :buffer))))
                (etaf-runtime-flush runtime)))))))))

;;; ---------------------------------------------------------------------------
;;; Scopes
;;; ---------------------------------------------------------------------------

(defun etaf-rss--normalize-scope (_app scope)
  "Return SCOPE as a canonical scope plist accepted by the service.
SCOPE may be the keywords `:all', `:unread' and `:starred' or a scope plist.
Anything else signals `etaf-rss-error' and leaves APP unchanged."
  (cond
   ((eq scope :all) (list :kind :all))
   ((eq scope :unread) (list :kind :unread))
   ((eq scope :starred) (list :kind :starred))
   ((and (consp scope) (memq (plist-get scope :kind) '(:all :unread :starred :feed :folder :search)))
    scope)
   (t (signal 'etaf-rss-error (list (format "未知的阅读范围：%S" scope))))))

(defun etaf-rss--scope-label (app scope)
  "Return the display label of SCOPE in APP."
  (pcase (plist-get scope :kind)
    (:all "全部文章")
    (:unread "未读")
    (:starred "收藏")
    (:search (format "搜索：%s" (plist-get scope :query)))
    (:folder (plist-get scope :name))
    (:feed (let ((feed (etaf-rss--feed app (plist-get scope :id))))
             (if feed (plist-get feed :title) "订阅")))))

(defun etaf-rss--scope-subtitle (app scope)
  "Return the one-line description of SCOPE in APP."
  (let ((scope-label (etaf-rss--scope-label app scope)))
    (pcase (plist-get scope :kind)
      (:all (format "%s · 共 %d 篇 · 未读 %d" scope-label
                    (etaf-rss--read app :total) (etaf-rss--read app :unread)))
      (:unread (format "%s · 还有 %d 篇未读" scope-label (etaf-rss--read app :unread)))
      (:starred (format "%s · %d 篇" scope-label (etaf-rss--read app :starred-count)))
      (:folder (format "文件夹 · %s" (etaf-rss--folder-summary app (plist-get scope :name))))
      (:feed (let ((feed (etaf-rss--feed app (plist-get scope :id))))
               (if feed
                   (format "%s · 未读 %d / %d"
                           (or (plist-get feed :url) "")
                           (or (plist-get feed :unread) 0)
                           (or (plist-get feed :total) 0))
                 scope-label)))
      (:search (format "%s · 匹配 %d 篇" scope-label (etaf-rss--read app :list-total)))
      (_ scope-label))))

(defun etaf-rss--feed (app id)
  "Return APP's feed plist for ID, or nil."
  (seq-find (lambda (feed) (equal (plist-get feed :id) id))
            (append (etaf-rss--read app :feeds) nil)))

(defun etaf-rss--folder-summary (app name)
  "Return a count summary for folder NAME in APP."
  (let ((feeds (seq-filter (lambda (feed)
                             (equal (or (plist-get feed :folder) "") name))
                           (append (etaf-rss--read app :feeds) nil))))
    (format "%d 个订阅 · 未读 %d"
            (length feeds)
            (apply #'+ (mapcar (lambda (feed) (or (plist-get feed :unread) 0)) feeds)))))

(defun etaf-rss--folders (app)
  "Return APP's folder names in service order, without the empty folder."
  (let ((names nil))
    (dolist (feed (append (etaf-rss--read app :feeds) nil))
      (let ((folder (or (plist-get feed :folder) "")))
        (unless (or (string-empty-p folder) (member folder names))
          (push folder names))))
    (nreverse names)))

(defun etaf-rss--scope-feeds (app scope)
  "Return the feed IDs SCOPE covers in APP."
  (pcase (plist-get scope :kind)
    (:all (mapcar (lambda (feed) (plist-get feed :id))
                  (append (etaf-rss--read app :feeds) nil)))
    (:unread (mapcar (lambda (feed) (plist-get feed :id))
                     (append (etaf-rss--read app :feeds) nil)))
    (:starred (mapcar (lambda (feed) (plist-get feed :id))
                      (append (etaf-rss--read app :feeds) nil)))
    (:folder (mapcar (lambda (feed) (plist-get feed :id))
                     (seq-filter (lambda (feed)
                                   (equal (or (plist-get feed :folder) "")
                                          (plist-get scope :name)))
                                 (append (etaf-rss--read app :feeds) nil))))
    (:feed (list (plist-get scope :id)))
    (_ nil)))

;;; ---------------------------------------------------------------------------
;;; List loading
;;; ---------------------------------------------------------------------------

(defun etaf-rss--apply-feeds (app data)
  "Store the sidebar values of DATA in APP."
  (etaf-batch
    (etaf-rss--write app :feeds (or (plist-get data :feeds) []))
    (etaf-rss--write app :total (or (plist-get data :total) 0))
    (etaf-rss--write app :unread (or (plist-get data :unread) 0))
    (etaf-rss--write app :starred-count (or (plist-get data :starred) 0))))

(defun etaf-rss--clamp-position (app)
  "Keep APP's selection and window start inside its current rows."
  (let* ((rows (etaf-rss--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-rss--read app :page-size))))
    (etaf-rss--write app :selection
                     (max 0 (min (max 0 (1- total))
                                 (etaf-rss--read app :selection))))
    (etaf-rss--write app :window-start
                     (max 0 (min (etaf-rss--read app :window-start)
                                 (max 0 (- total size)))))))

(defun etaf-rss--selected-row (app)
  "Return the article row APP's selection points at, or nil."
  (let ((rows (etaf-rss--read app :rows)))
    (when (> (length rows) 0)
      (aref rows (min (1- (length rows))
                      (max 0 (etaf-rss--read app :selection)))))))

(defun etaf-rss--selected-id (app)
  "Return the ID of APP's selected row, or nil."
  (let ((row (etaf-rss--selected-row app)))
    (and row (plist-get row :id))))

(defun etaf-rss--row-index (rows id)
  "Return the index of the row with ID in ROWS, or nil."
  (cl-loop for row across rows
           for index from 0
           when (equal (plist-get row :id) id)
           return index))

(defun etaf-rss--load-rows (app &optional keep-position)
  "Load APP's current scope into its row list.
KEEP-POSITION follows the selected article across a reload, so new items
arriving above it never move the reading place.  A reply from a superseded
scope is dropped."
  (let ((generation (setf (plist-get app :generation)
                          (1+ (plist-get app :generation))))
        (scope (etaf-rss--read app :scope))
        (previous (and keep-position (etaf-rss--selected-id app)))
        (key (format "%S" (etaf-rss--read app :scope))))
    (setf (plist-get app :list-key) key)
    (etaf-rss--write app :loading t)
    (etaf-rss--call
     app (list :op :articles :scope scope)
     :on-ok
     (lambda (data)
       (when (= generation (plist-get app :generation))
         (let* ((rows (or (plist-get data :rows) []))
                (position (and previous
                               (etaf-rss--row-index rows previous))))
           (etaf-batch
             (etaf-rss--write app :rows rows)
             (etaf-rss--write app :list-total (or (plist-get data :total)
                                                  (length rows)))
             (if position
                 (progn
                   (etaf-rss--write app :selection position)
                   (etaf-rss--clamp-position app))
               (progn
                 (etaf-rss--write app :selection 0)
                 (etaf-rss--write app :window-start 0)))
             (etaf-rss--write app :loading nil))
           (etaf-rss--write app :scope-subtitle
                            (etaf-rss--scope-subtitle
                             app (etaf-rss--read app :scope)))
           (when (etaf-rss--reader-visible-p app)
             (etaf-rss--schedule-reader app)))))
     :on-error
     (lambda (message _hint _feed-id)
       (when (= generation (plist-get app :generation))
         (etaf-batch
           (etaf-rss--write app :loading nil)
           (etaf-rss--write app :rows [])
           (etaf-rss--write app :list-total 0))
         (etaf-rss--note app message))))))

(defun etaf-rss--show-scope (app scope)
  "Show SCOPE in APP and load its rows.
A cached sidebar already knows the new label; the rows arrive on the next
event loop turn, so switching scopes never blocks a key press."
  (etaf-batch
    (etaf-rss--write app :scope scope)
    (etaf-rss--write app :scope-label (etaf-rss--scope-label app scope))
    (etaf-rss--write app :scope-subtitle (etaf-rss--scope-subtitle app scope))
    (etaf-rss--write app :reader-scroll 0)
    (when (etaf-rss--compact-layout-p app)
      (etaf-rss--write app :pane 'list)))
  (etaf-rss--load-rows app)
  (etaf-rss--fit-now app))

;;; ---------------------------------------------------------------------------
;;; Public navigation
;;; ---------------------------------------------------------------------------

(defun etaf-rss-locate (app scope)
  "Show SCOPE of APP and load its rows.
SCOPE is `:all', `:unread', `:starred', the list (:kind :feed :id ID),
(:kind :folder :name NAME) or (:kind :search :query TEXT).  An unknown SCOPE
signals `etaf-rss-error' and leaves APP unchanged."
  (etaf-rss--show-scope app (etaf-rss--normalize-scope app scope)))

(defun etaf-rss-search (app keyword)
  "Search APP's stored articles for KEYWORD and show the matches.
KEYWORD is trimmed; a blank one signals `etaf-rss-error' without querying.
Matching is case-insensitive and every space-separated term must appear in
the title, the summary or the article body."
  (let ((keyword (string-trim (or keyword ""))))
    (when (string-empty-p keyword)
      (signal 'etaf-rss-error '("搜索关键词不能为空")))
    (etaf-rss--write app :query keyword)
    (etaf-rss--show-scope app (list :kind :search :query keyword))))

(defun etaf-rss-move-selection (app delta)
  "Move APP's list selection by DELTA rows and keep it inside the page.
When the reading pane is visible it follows the settled selection."
  (let* ((rows (etaf-rss--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-rss--read app :page-size))))
    (when (> total 0)
      (let ((previous (etaf-rss--read app :selection))
            (selection (max 0 (min (1- total)
                                   (+ (etaf-rss--read app :selection) delta))))
            (start (etaf-rss--read app :window-start)))
        (cond ((< selection start) (setq start selection))
              ((>= selection (+ start size)) (setq start (- (1+ selection) size))))
        (etaf-rss--write app :selection selection)
        (etaf-rss--write app :window-start (max 0 start))
        (when (and (/= selection previous)
                   (etaf-rss--reader-visible-p app))
          (etaf-rss--schedule-reader app))))))

(defun etaf-rss-select-first (app)
  "Select the first row of APP."
  (etaf-rss-move-selection app (- (etaf-rss--read app :selection))))

(defun etaf-rss-select-last (app)
  "Select the last row of APP."
  (etaf-rss-move-selection
   app (- (1- (length (etaf-rss--read app :rows)))
          (etaf-rss--read app :selection))))

(defun etaf-rss-next-unread (app delta)
  "Move APP's selection to the next unread row, DIRECTION steps away.
DELTA is 1 for the next unread article and -1 for the previous one; the
search stops at the end (or start) when there is none."
  (let* ((rows (etaf-rss--read app :rows))
         (total (length rows))
         (start (etaf-rss--read app :selection))
         (found nil))
    (when (> total 0)
      (let ((index (+ start delta)))
        (while (and (>= index 0) (< index total) (not found))
          (when (not (eq t (plist-get (aref rows index) :read)))
            (setq found index))
          (setq index (+ index delta))))
      (if found
          (etaf-rss-move-selection app (- found start))
        (etaf-rss--note app (if (> delta 0) "后面没有未读文章了" "前面没有未读文章了"))))))

(defun etaf-rss-press-row (app index)
  "Press list row INDEX (counting from 1) in APP.
Pressing another row selects it and shows its article in the reading pane;
pressing the selected row again opens the reading pane (a compact layout
switches to it).  This is the gesture a click on a row performs.  An
out-of-range INDEX signals `etaf-rss-error'."
  (let ((total (length (etaf-rss--read app :rows))))
    (unless (and (integerp index) (>= index 1) (<= index total))
      (signal 'etaf-rss-error (list (format "没有第 %S 行" index))))
    (if (= (1- index) (etaf-rss--read app :selection))
        (etaf-rss-activate-selection app)
      (etaf-rss--write app :selection (1- index))
      (etaf-rss--clamp-position app)
      (when (etaf-rss--reader-visible-p app)
        (etaf-rss--schedule-reader app)))))

(defun etaf-rss-activate-selection (app)
  "Show the selected article in APP's reading pane.
A compact layout switches its single pane to the article; a wide layout
already shows the pane, so the pane is scrolled to the top."
  (when-let* ((row (etaf-rss--selected-row app)))
    (etaf-rss--write app :pane 'reader)
    (etaf-rss--show-article app row)))

(defun etaf-rss-show-pane (app pane)
  "Show PANE in APP and return it.
PANE is `list' or `reader'; on a compact layout it names the single visible
pane, and on a wide layout it only records the choice because both columns
stay visible.  An unknown PANE signals `etaf-rss-error'."
  (unless (memq pane '(list reader))
    (signal 'etaf-rss-error (list (format "未知面板：%S" pane))))
  (etaf-rss--write app :pane pane)
  (when (eq pane 'reader)
    (etaf-rss--schedule-reader app))
  (etaf-rss--fit-now app)
  pane)

(defun etaf-rss-toggle-pane (app)
  "Switch APP between the article list and the reading pane and return the new one."
  (let ((pane (if (eq (etaf-rss--read app :pane) 'reader) 'list 'reader)))
    (etaf-rss-show-pane app pane)
    pane))

;;; ---------------------------------------------------------------------------
;;; Reading pane
;;; ---------------------------------------------------------------------------

(defun etaf-rss--reader-visible-p (app)
  "Return non-nil when APP shows its reading pane."
  (or (not (etaf-rss--compact-layout-p app))
      (eq (etaf-rss--read app :pane) 'reader)))

(defun etaf-rss--compact-layout-p (app)
  "Return non-nil when APP shows one pane at a time."
  (not (eq (etaf-rss--read app :layout) 'wide)))

(defun etaf-rss--schedule-reader (app)
  "Load the selected article once the selection settles.
Each move restarts the timer, so a passed-over article is neither fetched nor
marked read.  The delay is `etaf-rss-follow-delay'."
  (when-let* ((timer (plist-get app :follow-timer)))
    (cancel-timer timer))
  (setf (plist-get app :follow-timer)
        (run-at-time
         etaf-rss-follow-delay nil
         (lambda ()
           (setf (plist-get app :follow-timer) nil)
           (unless (plist-get app :disposed)
             (when-let* ((row (etaf-rss--selected-row app)))
               (when (etaf-rss--reader-visible-p app)
                 (etaf-rss--show-article app row))))))))

(defun etaf-rss--show-article (app row)
  "Show ROW's article in APP's reading pane, loading it when needed."
  (let ((id (plist-get row :id)))
    (etaf-rss--write app :reader-id id)
    (etaf-rss--write app :reader-meta (etaf-rss--row-meta row))
    (etaf-rss--write app :reader-read (plist-get row :read))
    (etaf-rss--write app :reader-starred (plist-get row :starred))
    (etaf-rss--write app :reader-url (plist-get row :url))
    (let ((cached (gethash id (plist-get app :article-cache))))
      (if cached
          (progn
            (etaf-rss--write app :reader-loading nil)
            (etaf-rss--write app :reader-error nil)
            (etaf-rss--write app :reader-title (plist-get row :title))
            (etaf-rss--publish-reader app cached))
        (etaf-rss--write app :reader-loading t)
        (etaf-rss--write app :reader-error nil)
        (etaf-rss--write app :reader-title (plist-get row :title))
        (etaf-rss--write app :reader-blocks nil)
        (etaf-rss--write app :reader-lines nil)
        (etaf-rss--load-article app id)))
    ;; Showing an article is how it becomes read, but only once the reader
    ;; rests on it: the timer is what keeps a fast j/k pass from marking every
    ;; article it flew over.
    (when-let* ((timer (plist-get app :read-timer)))
      (cancel-timer timer))
    (setf (plist-get app :read-timer) nil)
    (unless (eq t (plist-get row :read))
      (setf (plist-get app :read-timer)
            (run-at-time
             etaf-rss-mark-read-delay nil
             (lambda ()
               (setf (plist-get app :read-timer) nil)
               (unless (plist-get app :disposed)
                 (when (equal (etaf-rss--read app :reader-id) id)
                   (etaf-rss--set-read app id t)))))))))

(defun etaf-rss--load-article (app id)
  "Load article ID into APP's reading pane.
A reply that no longer matches the open article is dropped, so fast browsing
never paints a stale story."
  (let ((generation (setf (plist-get app :article-generation)
                          (1+ (plist-get app :article-generation)))))
    (etaf-rss--call
     app (list :op :article :id id)
     :on-ok (lambda (data)
              (let ((row (etaf-rss--row-of data)))
                (puthash (plist-get row :id)
                         (etaf-rss--blocks-of row)
                         (plist-get app :article-cache))
                (when (and (= generation (plist-get app :article-generation))
                           (equal (etaf-rss--read app :reader-id) id))
                  (etaf-batch
                    (etaf-rss--write app :reader-loading nil)
                    (etaf-rss--write app :reader-meta (etaf-rss--row-meta row))
                    (etaf-rss--write app :reader-read (plist-get row :read))
                    (etaf-rss--publish-reader app (etaf-rss--blocks-of row))))))
     :on-error (lambda (message _hint _feed-id)
                 (when (and (= generation (plist-get app :article-generation))
                            (equal (etaf-rss--read app :reader-id) id))
                   (etaf-rss--write app :reader-loading nil)
                   (etaf-rss--write app :reader-error message))))))

(defun etaf-rss--row-of (data)
  "Return the article row carried by a detail reply DATA."
  (if (plist-get data :id)
      data
    (plist-get data :article)))

(defun etaf-rss--blocks-of (row)
  "Return ROW's reading blocks, rendering its HTML once per article.
An article without a body shows its summary; an article without either shows
a hint pointing at the browser key."
  (let* ((content (or (plist-get row :content) ""))
         (summary (or (plist-get row :summary) ""))
         (blocks (cond ((not (string-empty-p (string-trim content)))
                        (etaf-rss-render-html content))
                       ((not (string-empty-p (string-trim summary)))
                        (etaf-rss-render-html summary))
                       (t (list (list :kind 'para
                                      :text "(这篇没有正文，按 o 在浏览器里打开)"))))))
    (if blocks
        blocks
      (list (list :kind 'para :text "(这篇没有正文，按 o 在浏览器里打开)")))))

(defun etaf-rss--publish-reader (app blocks)
  "Wrap BLOCKS to APP's current reading width and publish the lines.
Wrapping happens once per article and width; scrolling only slices the
result, which is what keeps a key press independent of the article's length."
  (let ((columns (max 16 (etaf-rss--read app :reader-columns))))
    (etaf-batch
      (etaf-rss--write app :reader-blocks blocks)
      (etaf-rss--write app :reader-wrapped columns)
      (etaf-rss--write app :reader-lines
                       (etaf-rss-wrap-blocks blocks columns))
      (etaf-rss--write app :reader-scroll 0))
    ;; The pane grew by its title, meta line and article rows; fit it again
    ;; so the reading pane can never push the canvas past the window.
    (etaf-rss--fit-now app)))

(defun etaf-rss--reader-total (app)
  "Return the line count of APP's open article."
  (length (etaf-rss--read app :reader-lines)))

(defun etaf-rss-scroll-reader (app delta)
  "Scroll APP's reading pane by DELTA lines.
The scroll clamps at both ends; the pane paints only the visible lines."
  (let* ((total (etaf-rss--reader-total app))
         (rows (max 1 (etaf-rss--read app :reader-rows)))
         (scroll (max 0 (min (etaf-rss--read app :reader-scroll)
                             (max 0 (- total rows))))))
    (etaf-rss--write app :reader-scroll
                     (max 0 (min (max 0 (- total rows))
                                 (+ scroll delta))))))

(defun etaf-rss--visible-lines (app)
  "Return the reading-pane lines APP paints."
  (let* ((lines (etaf-rss--read app :reader-lines))
         (rows (max 1 (etaf-rss--read app :reader-rows)))
         (scroll (max 0 (min (etaf-rss--read app :reader-scroll)
                             (max 0 (- (length lines) rows))))))
    (when lines
      (seq-subseq lines scroll (min (length lines) (+ scroll rows))))))

;;; ---------------------------------------------------------------------------
;;; Reading state
;;; ---------------------------------------------------------------------------

(defun etaf-rss--update-row (app id key value)
  "Publish KEY VALUE on the row with ID in APP's loaded rows.
The row vector is copied so the change is a new reading and the view
repaints; the rest of the vector keeps its identity."
  (let* ((rows (etaf-rss--read app :rows))
         (index (and rows (etaf-rss--row-index rows id))))
    (when index
      (let ((copy (copy-sequence rows)))
        (aset copy index (plist-put (copy-sequence (aref copy index)) key value))
        (etaf-rss--write app :rows copy)))))

(defun etaf-rss--set-read (app id read &optional silent)
  "Set the read state of article ID in APP, optimistically and then for real.
The visible row flips immediately, the service persists it, and a failure is
reported in the status line."
  (etaf-rss--update-row app id :read (and read t))
  (when (equal (etaf-rss--read app :reader-id) id)
    (etaf-rss--write app :reader-read (and read t)))
  (etaf-rss--call
   app (list :op :mark-read :ids (list id) :read (and read t))
   :on-ok (lambda (data) (etaf-rss--apply-feeds app data))
   :on-error (lambda (message _hint _feed-id)
               (unless silent (etaf-rss--note app message)))))

(defun etaf-rss-toggle-read (app)
  "Toggle the read state of APP's selected article and return it.
The toggle is optimistic: the row flips before the service confirms, so the
interface never waits on a disk write."
  (let ((row (etaf-rss--selected-row app)))
    (unless row (signal 'etaf-rss-error '("列表里没有文章")))
    (let ((read (not (eq t (plist-get row :read)))))
      (etaf-rss--set-read app (plist-get row :id) read)
      read)))

(defun etaf-rss-toggle-star (app)
  "Toggle the star of APP's selected article and return it.
The toggle is optimistic, like `etaf-rss-toggle-read'."
  (let* ((row (etaf-rss--selected-row app)))
    (unless row (signal 'etaf-rss-error '("列表里没有文章")))
    (let ((starred (not (eq t (plist-get row :starred)))))
      (etaf-rss--update-row app (plist-get row :id) :starred (and starred t))
      (when (equal (etaf-rss--read app :reader-id) (plist-get row :id))
        (etaf-rss--write app :reader-starred (and starred t)))
      (etaf-rss--call
       app (list :op :star :id (plist-get row :id) :starred (and starred t))
       :on-ok (lambda (data) (etaf-rss--apply-feeds app data))
       :on-error (lambda (message _hint _feed-id)
                   (etaf-rss--note app message)))
      (etaf-rss--note app (if starred "已收藏" "已取消收藏"))
      starred)))

(defun etaf-rss--rows-before (app index)
  "Return the IDs of APP's rows up to and including INDEX."
  (let ((rows (etaf-rss--read app :rows))
        (ids nil))
    (dotimes (position (min (length rows) (1+ index)))
      (push (plist-get (aref rows position) :id) ids))
    (nreverse ids)))

(defun etaf-rss-mark-all-read (app &optional unread-p)
  "Mark every article of APP's current scope read and return the count.
With UNREAD-P non-nil the scope is marked unread instead, which is how a
reader undoes an accidental \"all read\".  The change is optimistic and
confirmed by the service."
  (let ((scope (etaf-rss--read app :scope)))
    ;; The visible rows flip before the service confirms, so the list never
    ;; waits on a disk write.
    (let ((rows (copy-sequence (etaf-rss--read app :rows))))
      (dotimes (index (length rows))
        (aset rows index (plist-put (copy-sequence (aref rows index))
                                    :read (not unread-p))))
      (etaf-rss--write app :rows rows))
    (etaf-rss--call
     app (list :op :mark-read-scope :scope scope :read (not unread-p))
     :on-ok (lambda (data)
              (let ((ids (append (plist-get data :ids) nil)))
                (dolist (id ids)
                  (etaf-rss--update-row app id :read (not unread-p)))
                (etaf-rss--apply-feeds app data)
                (etaf-rss--note
                 app (format "%s %d 篇"
                             (if unread-p "已标为未读" "已全部标为已读")
                             (length ids)))))
     :on-error (lambda (message _hint _feed-id)
                 (etaf-rss--load-rows app t)
                 (etaf-rss--note app message)))))

(defun etaf-rss-mark-above-read (app)
  "Mark the selected article and everything above it read and return the count."
  (let* ((ids (etaf-rss--rows-before app (etaf-rss--read app :selection)))
         (rows (copy-sequence (etaf-rss--read app :rows))))
    (when ids
      ;; Optimistic: the rows above the selection read as done at once.
      (dotimes (index (min (length rows) (length ids)))
        (aset rows index (plist-put (copy-sequence (aref rows index)) :read t)))
      (etaf-rss--write app :rows rows)
      (etaf-rss--call
       app (list :op :mark-read :ids ids :read t)
       :on-ok (lambda (data)
                (dolist (id ids) (etaf-rss--update-row app id :read t))
                (etaf-rss--apply-feeds app data)
                (etaf-rss--note app (format "已把前 %d 篇标为已读" (length ids))))
       :on-error (lambda (message _hint _feed-id)
                   (etaf-rss--load-rows app t)
                   (etaf-rss--note app message))))))

;;; ---------------------------------------------------------------------------
;;; Subscriptions
;;; ---------------------------------------------------------------------------

(defun etaf-rss-add-feed (app url &optional folder)
  "Subscribe APP to URL and return non-nil when the request started.
The feed is fetched and parsed before it is added, so a wrong address is
reported instead of stored.  A page that is not a feed is searched for its
advertised feed links.  FOLDER files the subscription when non-nil."
  (let ((url (string-trim (or url ""))))
    (when (string-empty-p url)
      (signal 'etaf-rss-error '("订阅地址不能为空")))
    (etaf-rss--write app :loading t)
    (etaf-rss--note app (format "正在添加订阅 %s …" url))
    (etaf-rss--call
     app (list :op :add-feed :url url :folder (or folder ""))
     :on-ok (lambda (data)
              (etaf-rss--write app :loading nil)
              (etaf-rss--apply-feeds app data)
              (let ((feed (plist-get data :feed)))
                (etaf-rss--note app (format "已添加「%s」，%d 篇新文章"
                                            (plist-get feed :title)
                                            (or (plist-get data :new) 0)))
                (etaf-rss--show-scope app (list :kind :feed :id (plist-get feed :id)))))
     :on-error (lambda (message _hint _feed-id)
                 (etaf-rss--write app :loading nil)
                 (etaf-rss--note app message)))
    t))

(defun etaf-rss-remove-feed (app &optional id)
  "Unsubscribe the feed ID from APP, or the feed of the current scope.
Starred articles of the feed stay in the reader.  Return the removed feed's
title, or signal `etaf-rss-error' when there is no feed to remove."
  (let* ((id (or id (plist-get (etaf-rss--read app :scope) :id)))
         (feed (and id (etaf-rss--feed app id))))
    (unless feed
      (signal 'etaf-rss-error '("当前没有选中订阅（在侧栏点一个订阅再删）")))
    (etaf-rss--call
     app (list :op :remove-feed :id id)
     :on-ok (lambda (data)
              (etaf-rss--apply-feeds app data)
              (etaf-rss--note app (format "已退订「%s」" (or (plist-get feed :title) id)))
              (etaf-rss--show-scope app (list :kind :all)))
     :on-error (lambda (message _hint _feed-id)
                 (etaf-rss--note app message)))
    (plist-get feed :title)))

(defun etaf-rss-move-feed (app id folder)
  "File the feed ID under FOLDER in APP and return the file name.
An empty FOLDER moves the subscription back to the top level."
  (unless id (signal 'etaf-rss-error '("没有要移动的订阅")))
  (etaf-rss--call
   app (list :op :move-feed :id id :folder (or folder ""))
   :on-ok (lambda (data)
            (etaf-rss--apply-feeds app data)
            (etaf-rss--note app (if (string-empty-p (or folder ""))
                                    "已移出文件夹"
                                  (format "已移到「%s」" folder))))
   :on-error (lambda (message _hint _feed-id)
               (etaf-rss--note app message)))
  folder)

(defun etaf-rss-toggle-folder (app name)
  "Collapse or expand the folder NAME in APP and return the open folders."
  (let ((collapsed (etaf-rss--read app :collapsed)))
    (etaf-rss--write app :collapsed
                     (if (member name collapsed)
                         (seq-remove (lambda (item) (equal item name)) collapsed)
                       (cons name collapsed)))
    (etaf-rss--read app :collapsed)))

(defun etaf-rss-import-opml (app path)
  "Add the subscriptions of the OPML file at PATH to APP and return the count.
Nothing is fetched by the import itself; the caller refreshes afterwards."
  (etaf-rss--call
   app (list :op :opml-import :path (expand-file-name path))
   :on-ok (lambda (data)
            (etaf-rss--apply-feeds app data)
            (let ((added (or (plist-get data :added) 0))
                  (skipped (or (plist-get data :skipped) 0)))
              (etaf-rss--note app (format "导入完成：新增 %d 个，跳过 %d 个" added skipped))
              (when (> added 0)
                (etaf-rss-refresh-feeds app))))
   :on-error (lambda (message _hint _feed-id)
               (etaf-rss--note app message)))
  path)

(defun etaf-rss-export-opml (app path)
  "Write APP's subscriptions to the OPML file at PATH and return the path."
  (etaf-rss--call
   app (list :op :opml-export :path (expand-file-name path))
   :on-ok (lambda (data)
            (etaf-rss--note app (format "已导出 %d 个订阅到 %s"
                                        (or (plist-get data :count) 0)
                                        (plist-get data :path))))
   :on-error (lambda (message _hint _feed-id)
               (etaf-rss--note app message)))
  path)

(defun etaf-rss-open-article (app &optional row)
  "Open ROW's article, or APP's selected article, in the browser.
The reader keeps running; a row without a URL reports that in the status
line instead of signalling."
  (let* ((row (or row (etaf-rss--selected-row app)))
         (url (and row (plist-get row :url))))
    (cond
     ((null row) (signal 'etaf-rss-error '("列表里没有文章")))
     ((or (null url) (string-empty-p url))
      (etaf-rss--note app "这篇文章没有原始链接")
      nil)
     (t
      (browse-url url)
      (etaf-rss--note app (format "已在浏览器打开：%s" url))
      url))))

;;; ---------------------------------------------------------------------------
;;; Refresh
;;; ---------------------------------------------------------------------------

(defun etaf-rss-refresh (app)
  "Reload APP's sidebar and current list, then re-fetch its feeds.
The local reload paints at once; the network refresh runs feed by feed in the
background and reports its progress in the status line.  Malformed or
unreachable feeds leave the reader usable and are reported."
  (etaf-batch
    (etaf-rss--write app :error nil)
    (etaf-rss--sync-layout app))
  (etaf-rss--call
   app (list :op :snapshot)
   :on-ok (lambda (data)
            (etaf-rss--apply-feeds app data)
            (when-let* ((theme (plist-get data :theme)))
              (when (member theme '("dark" "light"))
                (etaf-rss--apply-theme app (intern theme))))
            (etaf-rss--write app :scope-subtitle
                             (etaf-rss--scope-subtitle app (etaf-rss--read app :scope)))
            (etaf-rss--load-rows app t)))
  (etaf-rss-refresh-feeds app)
  (etaf-rss--schedule-auto-refresh app))

(defun etaf-rss-refresh-feeds (app &optional scope)
  "Re-fetch the feeds APP's current scope covers, one at a time.
SCOPE defaults to the reader's current one and can name another scope (for
example `(:kind :all)' to refresh every subscription).  The refresh reports
how many feeds are waiting and how many are done, and it never blocks an
interaction: each reply repaints the sidebar, and the list is reloaded once
at the end when the scope it shows was affected."
  (let ((feeds (etaf-rss--scope-feeds app (or scope (etaf-rss--read app :scope)))))
    (when feeds
      (setf (plist-get app :refresh-queue) feeds
            (plist-get app :refresh-new) 0)
      (etaf-batch
        (etaf-rss--write app :refreshing t)
        (etaf-rss--write app :refresh-total (length feeds))
        (etaf-rss--write app :refresh-done 0))
      (etaf-rss--pump-refresh app))))

(defun etaf-rss--pump-refresh (app)
  "Fetch the next queued feed of APP, or finish the refresh."
  (let ((queue (plist-get app :refresh-queue)))
    (if (null queue)
        (progn
          (when (etaf-rss--read app :refreshing)
            (etaf-rss--write app :refreshing nil)
            (setf (plist-get app :refresh-queue) nil)
            (let ((new (or (plist-get app :refresh-new) 0)))
              (etaf-rss--note app
                              (if (> new 0)
                                  (format "刷新完成：%d 篇新文章" new)
                                "刷新完成：没有新文章")))
            (etaf-rss--load-rows app t)))
      (let ((id (car queue)))
        (setf (plist-get app :refresh-queue) (cdr queue))
        (etaf-rss--call
         app (list :op :refresh :id id)
         :on-ok (lambda (data)
                  (etaf-rss--apply-feeds app data)
                  (setf (plist-get app :refresh-new)
                        (+ (or (plist-get app :refresh-new) 0)
                           (or (plist-get data :new) 0)))
                  (etaf-rss--write app :refresh-done
                                   (1+ (or (etaf-rss--read app :refresh-done) 0)))
                  (etaf-rss--write app :scope-subtitle
                                   (etaf-rss--scope-subtitle
                                    app (etaf-rss--read app :scope)))
                  (etaf-rss--pump-refresh app))
         :on-error (lambda (message _hint feed-id)
                     (etaf-rss--write app :refresh-done
                                      (1+ (or (etaf-rss--read app :refresh-done) 0)))
                     (when feed-id
                       (etaf-rss--apply-feed-error app feed-id message))
                     (etaf-rss--pump-refresh app)))))))

(defun etaf-rss--apply-feed-error (app id message)
  "Show MESSAGE on the sidebar feed ID of APP."
  (let ((feeds (etaf-rss--read app :feeds)))
    (etaf-rss--write
     app :feeds
     (vconcat
      (mapcar (lambda (feed)
                (if (equal (plist-get feed :id) id)
                    (plist-put (copy-sequence feed) :error message)
                  feed))
              (append feeds nil))))))

(defun etaf-rss--schedule-auto-refresh (app)
  "Arm APP's periodic refresh, replacing any timer already armed."
  (when-let* ((timer (plist-get app :refresh-timer)))
    (cancel-timer timer)
    (setf (plist-get app :refresh-timer) nil))
  (when (and etaf-rss-refresh-interval
             (not (plist-get app :disposed)))
    (setf (plist-get app :refresh-timer)
          (run-at-time etaf-rss-refresh-interval etaf-rss-refresh-interval
                       (lambda ()
                         (unless (plist-get app :disposed)
                           (when (etaf-rss--buffer-visible-p app)
                             (etaf-rss-refresh-feeds app))))))))

(defun etaf-rss--buffer-visible-p (app)
  "Return non-nil when APP's buffer is shown, or the session is headless."
  (let ((buffer (plist-get app :buffer)))
    (or (null buffer)
        (and (buffer-live-p buffer)
             (get-buffer-window buffer t)))))

;;; ---------------------------------------------------------------------------
;;; Appearance
;;; ---------------------------------------------------------------------------

(defun etaf-rss--apply-theme (app mode)
  "Switch APP to palette MODE and publish the matching UI tokens."
  (etaf-batch
    (etaf-rss--write app :theme-mode mode)
    (etaf-rss--write app :theme (etaf-rss-theme-defaults mode))))

(defun etaf-rss-set-theme (app mode)
  "Switch APP to the appearance MODE and return it.
MODE is `dark' or `light'; anything else signals `etaf-rss-error'.  The
choice is remembered by the service, and it seeds the next session, so the
reader keeps it after a restart."
  (unless (memq mode '(dark light))
    (signal 'etaf-rss-error (list (format "未知外观：%S" mode))))
  (setq etaf-rss-theme-mode mode)
  (etaf-rss--write app :theme-mode mode)
  (etaf-rss--write app :theme (etaf-rss-theme-defaults mode))
  (etaf-rss--call app (list :op :set-theme :theme (symbol-name mode)))
  mode)

(defun etaf-rss-cycle-theme (app)
  "Switch APP to the next appearance and return it.
The order is `dark', `light' and back to `dark'."
  (etaf-rss-set-theme app (if (eq (etaf-rss--read app :theme-mode) 'dark)
                              'light
                            'dark)))

;;; ---------------------------------------------------------------------------
;;; Layout
;;; ---------------------------------------------------------------------------

(defun etaf-rss--window-columns (&optional window)
  "Return WINDOW's body width in columns, or the frame width when it is dead."
  (if (and window (window-live-p window))
      (window-body-width window)
    (frame-width)))

(defun etaf-rss--layout-for (columns)
  "Return the layout COLUMNS columns of text can hold."
  (cond ((>= columns etaf-rss-wide-columns) 'wide)
        ((>= columns etaf-rss-medium-columns) 'medium)
        (t 'narrow)))

(defun etaf-rss--reader-capacity (columns layout)
  "Return how many text columns the reading pane holds in COLUMNS.
The wide layout spends columns on the sidebar and splits what is left
between the article list and the reading pane, which spends its own insets
plus one safety column; a medium layout keeps the rail and shows one content
pane.  The share is what the flex row actually gives the reader, so a
wrapped line never clips at the pane edge."
  (let* ((share (pcase layout
                  ('wide (etaf-rss--list-columns columns layout))
                  ('medium (- columns etaf-rss--sidebar-narrow-columns
                               (* 2 etaf-rss--list-inset)))
                  (_ columns))))
    (max 24 (- share (+ etaf-rss--reader-inset 1)))))

(defun etaf-rss--list-columns (columns layout)
  "Return the width the article list column gets in COLUMNS and LAYOUT.
The wide layout puts the list and the reading pane in one row, each with
`flex-grow 1' from a zero basis, so the list's width is half of what the
sidebar leaves; a single-pane layout gives it the whole width.  Every budget
that depends on the list (its title columns, the reading width) reads this,
so a budget cannot assume a share the flex row does not give."
  (if (eq layout 'wide)
      (max etaf-rss--list-min-columns
           (floor (/ (- columns etaf-rss--sidebar-columns) 2)))
    columns))

(defun etaf-rss--page-size-for (window layout)
  "Return the article row count that fits WINDOW's height in LAYOUT."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         (chrome (pcase layout
                   ('wide 5)
                   ('medium 9)
                   ;; The narrow layout also paints the scope chips under the
                   ;; header, one row more than the medium layout.
                   (_ 10))))
    (max 1 (- height chrome))))

(defun etaf-rss--reader-rows-for (window layout)
  "Return the reading line count that fits WINDOW's height in LAYOUT."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         (chrome (pcase layout
                   ('wide 7)
                   ('medium 10)
                   (_ 10))))
    (max 3 (- height chrome))))

(defun etaf-rss--sync-layout (app &optional window)
  "Match APP's layout, page size and reading width to WINDOW.
WINDOW defaults to the window showing APP's buffer.  A headless session keeps
the wide layout, because it has no viewport to adapt to.  An open article is
wrapped again when the reading width changed, so no line clips after a
resize."
  (let* ((buffer (plist-get app :buffer))
         (window (or window
                     (and (buffer-live-p buffer) (get-buffer-window buffer t))))
         (columns (etaf-rss--window-columns window))
         (layout (if window (etaf-rss--layout-for columns) 'wide))
         (capacity (etaf-rss--reader-capacity columns layout))
         (reader-columns (max 24 (min etaf-rss-reading-measure capacity))))
    (etaf-batch
      (etaf-rss--write app :layout layout)
      (etaf-rss--write app :page-size (etaf-rss--page-size-for window layout))
      (etaf-rss--write app :window-rows
                       (if (and window (window-live-p window))
                           (window-body-height window)
                         (frame-height)))
      (etaf-rss--write app :window-columns columns)
      (etaf-rss--write app :reader-rows (etaf-rss--reader-rows-for window layout))
      (etaf-rss--write app :reader-columns reader-columns)
      (etaf-rss--clamp-position app))
    ;; The open article is wrapped again when the reading width changed, so no
    ;; line clips after a resize; the blocks live in the article cache, which
    ;; is the one place that survives a pane switch.
    (let ((blocks (gethash (etaf-rss--read app :reader-id)
                           (plist-get app :article-cache))))
      (when (and blocks (/= reader-columns (etaf-rss--read app :reader-wrapped)))
        (etaf-batch
          (etaf-rss--write app :reader-wrapped reader-columns)
          (etaf-rss--write app :reader-lines (etaf-rss-wrap-blocks blocks reader-columns)))))
    ;; Publish the new geometry before measuring it: the canvas is judged by
    ;; what is painted, not by the constants that asked for it.
    (when-let* ((runtime (and (buffer-live-p buffer)
                              (etaf-runtime-for-buffer buffer))))
      (etaf-runtime-flush runtime))
    (etaf-rss--fit-height app window)
    ;; The paint the fit just triggered may still change the pane height, so
    ;; measure once more after the pending work publishes.
    (etaf-next-tick
     (lambda ()
       (when (and (buffer-live-p (plist-get app :buffer))
                  (window-live-p window))
         (etaf-rss--fit-height app window))))
    layout))

;;; ---------------------------------------------------------------------------
;;; Session lifecycle
;;; ---------------------------------------------------------------------------

(defun etaf-rss--start (app)
  "Start APP: fit the layout and refresh its state.
An opened reader refits the layout after each settled resize through its
application window fit (see `etaf-rss-open')."
  (setf (plist-get app :disposed) nil
        (plist-get app :started-at) (float-time))
  (etaf-rss--sync-layout app))

(defun etaf-rss--dispose (app)
  "Release APP's timers and in-flight requests; the session stays reusable."
  (when-let* ((timer (plist-get app :read-timer)))
    (cancel-timer timer)
    (setf (plist-get app :read-timer) nil))
  (when-let* ((timer (plist-get app :follow-timer)))
    (cancel-timer timer)
    (setf (plist-get app :follow-timer) nil))
  (when-let* ((timer (plist-get app :refresh-timer)))
    (cancel-timer timer)
    (setf (plist-get app :refresh-timer) nil))
  (setf (plist-get app :disposed) t)
  (etaf-rss-cancel (etaf-rss--client app)))

;;; ---------------------------------------------------------------------------
;;; View projection and state
;;; ---------------------------------------------------------------------------

(defun etaf-rss--page-rows (app)
  "Return the visible slice of APP's rows as (ROWS START TOTAL)."
  (let* ((rows (etaf-rss--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-rss--read app :page-size)))
         (start (max 0 (min (etaf-rss--read app :window-start)
                            (max 0 (- total size))))))
    (list (seq-subseq rows start (min total (+ start size))) start total)))

(defun etaf-rss--view-entries (app)
  "Return APP's visible rows as list entries for the view."
  (pcase-let* ((`(,rows ,start ,_total) (etaf-rss--page-rows app))
               (selection (etaf-rss--read app :selection)))
    (cl-loop for row across rows
             for index from start
             collect (list :index (1+ index)
                           :row row
                           :selected (= index selection)))))

(defun etaf-rss--sidebar (app)
  "Return APP's sidebar as (SMART FOLDERS), both plain data for the view.
SMART entries are (:key :label :icon :unread).  FOLDERS is a list of
(:name :unread :open :feeds); each feed is (:id :title :unread :active)."
  (let* ((scope (etaf-rss--read app :scope))
         (kind (plist-get scope :kind))
         (feeds (append (etaf-rss--read app :feeds) nil))
         (collapsed (etaf-rss--read app :collapsed))
         (smart (list (list :key :all :label "全部文章" :icon 'list
                            :unread (etaf-rss--read app :unread))
                      (list :key :unread :label "未读" :icon 'radio
                            :unread (etaf-rss--read app :unread))
                      (list :key :starred :label "收藏" :icon 'star
                            :unread (etaf-rss--read app :starred-count))))
         (folders nil))
    (dolist (feed feeds)
      (let ((folder (or (plist-get feed :folder) "")))
        (if (string-empty-p folder)
            (let ((entry (assq :top folders)))
              (unless entry
                (setq entry (list :top))
                (setq folders (append folders (list entry))))
              (setcdr entry (append (cdr entry) (list feed))))
          (let ((entry (assoc folder folders)))
            (unless entry
              (setq entry (list folder))
              (setq folders (append folders (list entry))))
            (setcdr entry (append (cdr entry) (list feed)))))))
    (list
     (mapcar (lambda (item)
               (plist-put item :active (eq kind (plist-get item :key))))
             smart)
     (mapcar
      (lambda (entry)
        (let* ((name (car entry))
               (members (cdr entry))
               (top (eq name :top)))
          (list :name (if top "" name)
                :label (if top "未分组"
                         (format "%s（%d）" name (length members)))
                :top top
                :open (and (not top) (not (member name collapsed)))
                :active (if top
                            (eq kind :feed)
                          (and (eq kind :folder)
                               (equal (plist-get scope :name) name)))
                :unread (apply #'+ (mapcar (lambda (feed)
                                             (or (plist-get feed :unread) 0))
                                           members))
                :feeds (mapcar (lambda (feed)
                                 (list :id (plist-get feed :id)
                                       :title (plist-get feed :title)
                                       :unread (or (plist-get feed :unread) 0)
                                       :error (plist-get feed :error)
                                       :active (and (eq kind :feed)
                                                    (equal (plist-get scope :id)
                                                           (plist-get feed :id)))))
                               members))))
      folders))))

(defun etaf-rss--row-meta (row)
  "Return the meta line of ROW: feed, author and publish time."
  (string-join
   (delq nil
         (list (plist-get row :feed-title)
               (let ((author (plist-get row :author)))
                 (and author (not (string-empty-p author)) author))
               (let ((time (plist-get row :published)))
                 (and time (etaf-rss-relative-time time)))))
   " · "))

(defun etaf-rss-state (app)
  "Return APP's session state as a detached plist snapshot.
Keys are `:scope', `:scope-label', `:scope-subtitle', `:title', `:feeds',
`:folders', `:rows' (loaded rows), `:visible' (the rows on the current page),
`:selection', `:window-start', `:page-size', `:rows-total', `:list-total',
`:layout', `:pane', `:reader-id', `:reader-title', `:reader-meta',
`:reader-blocks', `:reader-lines' (the wrapped article), `:reader-scroll',
`:reader-rows', `:reader-total', `:reader-columns', `:reader-wrapped',
`:reader-loading', `:reader-error', `:reader-read', `:reader-starred',
`:reader-url', `:query', `:loading', `:refreshing', `:refresh-done',
`:refresh-total', `:error', `:message', `:total', `:unread',
`:starred-count', `:theme-mode', `:viewport-width'.  The snapshot copies
every value, so mutating it never changes the reader."
  (let* ((page (etaf-rss--page-rows app))
         (sidebar (etaf-rss--sidebar app)))
    (list :scope (etaf-rss--read app :scope)
          :scope-label (etaf-rss--read app :scope-label)
          :scope-subtitle (etaf-rss--read app :scope-subtitle)
          :title (etaf-rss--read app :scope-label)
          :feeds (mapcar #'copy-sequence (append (etaf-rss--read app :feeds) nil))
          :folders (mapcar #'copy-sequence (nth 1 sidebar))
          :rows (mapcar #'copy-sequence (append (etaf-rss--read app :rows) nil))
          :visible (mapcar #'copy-sequence (nth 0 page))
          :selection (etaf-rss--read app :selection)
          :window-start (nth 1 page)
          :page-size (etaf-rss--read app :page-size)
          :rows-total (length (etaf-rss--read app :rows))
          :list-total (etaf-rss--read app :list-total)
          :layout (etaf-rss--read app :layout)
          :pane (etaf-rss--read app :pane)
          :reader-id (etaf-rss--read app :reader-id)
          :reader-title (etaf-rss--read app :reader-title)
          :reader-meta (etaf-rss--read app :reader-meta)
          :reader-blocks (etaf-rss--read app :reader-blocks)
          :reader-lines (etaf-rss--read app :reader-lines)
          :reader-scroll (etaf-rss--read app :reader-scroll)
          :reader-rows (etaf-rss--read app :reader-rows)
          :reader-total (length (etaf-rss--read app :reader-lines))
          :reader-columns (etaf-rss--read app :reader-columns)
          :reader-wrapped (etaf-rss--read app :reader-wrapped)
          :reader-loading (etaf-rss--read app :reader-loading)
          :reader-error (etaf-rss--read app :reader-error)
          :reader-read (etaf-rss--read app :reader-read)
          :reader-starred (etaf-rss--read app :reader-starred)
          :reader-url (etaf-rss--read app :reader-url)
          :query (etaf-rss--read app :query)
          :loading (etaf-rss--read app :loading)
          :refreshing (etaf-rss--read app :refreshing)
          :refresh-done (etaf-rss--read app :refresh-done)
          :refresh-total (etaf-rss--read app :refresh-total)
          :error (etaf-rss--read app :error)
          :message (etaf-rss--read app :message)
          :total (etaf-rss--read app :total)
          :unread (etaf-rss--read app :unread)
          :starred-count (etaf-rss--read app :starred-count)
          :theme-mode (etaf-rss--read app :theme-mode)
          :viewport-width
          (let ((runtime (and (buffer-live-p (plist-get app :buffer))
                              (etaf-runtime-for-buffer (plist-get app :buffer)))))
            (and runtime (etaf-runtime-mounted-p runtime)
                 (car (etaf-runtime-viewport runtime)))))))

(provide 'etaf-rss-model)
;;; etaf-rss-model.el ends here
