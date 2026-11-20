;;; etaf-weread-model.el --- Reader state and backend actions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns everything a reader session remembers: the selected section,
;; the visible book rows, the keyboard selection, the book detail shown in the
;; side pane and its highlights, and the account and reading statistics.  Every
;; mutable value is an ETAF reactive source, so a View that reads it repaints
;; when a backend reply arrives; every backend request is asynchronous and its
;; reply is dropped when it belongs to a superseded load.
;;
;; The model is independent of any buffer: `etaf-weread-create' plus the public
;; actions drive a complete session headlessly, which is how the acceptance
;; scenarios exercise it with a fake client.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-weread-service)
(require 'etaf-weread-index)
(require 'etaf-weread-theme)

(defconst etaf-weread-sections
  '((书架
     (:shelf "全部书架" list)
     (:reading "在读" clock)
     (:finished "读完" check))
    (笔记
     (:notebook "笔记本" lyrics)
     (:index "笔记检索" search))
    (发现
     (:search "搜索书城" star)
     (:stats "阅读统计" chart)))
  "Sidebar groups shown by the reader.
Each group is (GROUP-NAME (SECTION LABEL ICON) ...), where ICON names an
`etaf-ui-icon' in the shared SVG set; SECTION keys are accepted by
`etaf-weread-locate'.")

(defconst etaf-weread--section-subtitles
  '((:shelf . "书架里的全部书")
    (:reading . "最近在读的书")
    (:finished . "已经读完的书")
    (:notebook . "有划线和想法的书")
    (:index . "本地索引的全部划线与想法")
    (:search . "搜索微信读书书城")
    (:stats . "读完与在读 · 累计阅读时长"))
  "One-line explanation shown under each section title.")

(defcustom etaf-weread-page-size 16
  "Book rows shown at once.
`etaf-weread-open' replaces this with the number that fits the window, so the
reader fills the frame it is given; the default only applies to a headless
model created by `etaf-weread-create'."
  :type 'integer
  :group 'etaf-weread)

(defconst etaf-weread--sidebar-columns 22
  "Frame columns the section sidebar occupies.")

(defconst etaf-weread--rail-columns 7
  "Frame columns the glyph-only section rail of a medium layout occupies.")

(defconst etaf-weread--pane-columns 46
  "Frame columns the side pane occupies, including its border and padding.")

(defconst etaf-weread--pane-content-columns 36
  "Usable text columns inside the side pane.
The pane's frame width minus its border and padding.")

(defconst etaf-weread--list-min-columns 70
  "Frame columns the book list needs to render one full row.
The full row spends 50 columns on everything but the title (index, author,
meter, time, badge and the gaps), so a narrower list leaves the title too few
columns to be recognizable and the row reads as broken.")

(defcustom etaf-weread-wide-columns (+ etaf-weread--sidebar-columns
                                      etaf-weread--pane-columns
                                      etaf-weread--list-min-columns)
  "Frame width, in columns, that fits all three reader columns.
At or above this width the reader shows the section sidebar, the book list and
the detail pane at the same time (`wide' layout).  Between
`etaf-weread-medium-columns' and this width it keeps a narrow glyph rail and
shows one pane at a time; below it the sections move into a chip strip.
Derived from the sidebar, the pane and the list's minimum, so the frame can
never show three columns the book list cannot render in."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-medium-columns 68
  "Frame width, in columns, that still fits a glyph-only section rail."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-list-limit 200
  "Rows requested from the backend for one list load.
A larger shelf is still navigated through the loaded rows; the footer reports
the backend total when the reply is partial."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-search-count 25
  "Book results requested for one store search."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-detail-follow-delay 0.3
  "Seconds of quiet before the detail pane follows the selection.
Moving through the list faster than this never requests a book that was only
passed over, so browsing stays cheap on the network."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-library-refresh-interval 120
  "Seconds after which a cached list is refreshed in the background.
A cached list is shown at once when a section is opened, then compared with a
fresh reply; the cache is a display shortcut, never the source of truth.  A
shorter interval keeps the sidebar current at the cost of more requests."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-prefetch-lists t
  "Whether a mounted reader refreshes sidebar lists while it is idle.
One list at a time is warmed or refreshed in the background, so switching
sections shows current data without waiting for the network."
  :type 'boolean
  :group 'etaf-weread)

(defcustom etaf-weread-prefetch-interval 15
  "Seconds between two background list refreshes while the reader is idle."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-settings-file
  (locate-user-emacs-file "etaf-weread/settings.eld")
  "File that stores the chosen appearance between sessions.
A new session starts with the theme stored there.  Bind it before creating a
session to keep several profiles apart."
  :type 'file
  :group 'etaf-weread)

(declare-function youdao-dictionary-search "youdao-dictionary" (query))

;;; ---------------------------------------------------------------------------
;;; Reading preferences
;;; ---------------------------------------------------------------------------

(defun etaf-weread--settings-read ()
  "Return the stored reading preferences as a property plist.
A missing file means the defaults, and a corrupt one is ignored rather than
breaking the session."
  (condition-case nil
      (when (file-readable-p etaf-weread-settings-file)
        (with-temp-buffer
          (insert-file-contents etaf-weread-settings-file)
          (let ((stored (read (current-buffer))))
            (and (listp stored) stored))))
    (error nil)))

(defun etaf-weread--settings-write (app)
  "Store APP's reading preferences for the next session.
The session remembers the file it was created with, so binding
`etaf-weread-settings-file' around `etaf-weread-create' keeps its writes in
that file too.  A failed write is reported in the status line instead of
signalling: losing a preference must not interrupt the reading."
  (condition-case error
      (let ((file (or (plist-get app :settings-file) etaf-weread-settings-file)))
        (make-directory (file-name-directory (expand-file-name file)) t)
        (with-temp-file file
          (prin1 (list :theme etaf-weread-theme-mode)
                 (current-buffer))))
    (error
     (etaf-weread--write app :message
                         (format "无法保存阅读设置：%s" (error-message-string error))))))

;;; ---------------------------------------------------------------------------
;;; Construction and reactive access
;;; ---------------------------------------------------------------------------

(cl-defun etaf-weread-create (&key client)
  "Create a reader session that talks to CLIENT.
CLIENT defaults to `etaf-weread-client-factory' when that is bound, and
otherwise to `etaf-weread-make-client'.  The session owns no buffer and no
timer until it is mounted by `etaf-weread-app' or started by
`etaf-weread-refresh'; it is also a complete headless reader for tests and
other Lisp callers."
  (let* ((client (or client
                     (if etaf-weread-client-factory
                         (funcall etaf-weread-client-factory)
                       (etaf-weread-make-client))))
         (settings (etaf-weread--settings-read)))
    (when (memq (plist-get settings :theme) '(dark light sepia))
      (setq etaf-weread-theme-mode (plist-get settings :theme))
      (etaf-set-value etaf-weread--theme-mode etaf-weread-theme-mode))
    (list :client client
          :buffer nil
          :settings-file etaf-weread-settings-file
          :disposed nil
          :started-at nil
          :follow-timer nil
          :generation 0
          :detail-generation 0
          :notes-generation 0
          :list-key nil
          :list-cache (etaf-list-cache-create :grace 3)
          :detail-cache (make-hash-table :test 'equal)
          :notes-cache (make-hash-table :test 'equal)
          :section (etaf-ref :shelf :name 'etaf-weread-section)
          :filter (etaf-ref "all" :name 'etaf-weread-filter)
          :mode (etaf-ref 'browse :name 'etaf-weread-mode)
          :query (etaf-ref "" :name 'etaf-weread-query)
          :title (etaf-ref "全部书架" :name 'etaf-weread-title)
          :subtitle (etaf-ref "书架里的全部书" :name 'etaf-weread-subtitle)
          :rows (etaf-ref nil :name 'etaf-weread-rows)
          :list-total (etaf-ref 0 :name 'etaf-weread-list-total)
          :selection (etaf-ref 0 :name 'etaf-weread-selection)
          :window-start (etaf-ref 0 :name 'etaf-weread-window-start)
          :window-rows (etaf-ref 0 :name 'etaf-weread-window-rows)
          :page-size (etaf-ref etaf-weread-page-size :name 'etaf-weread-page-size)
          :pane (etaf-ref 'list :name 'etaf-weread-pane)
          :pane-scroll (etaf-ref 0 :name 'etaf-weread-pane-scroll)
          :pane-rows (etaf-ref 10 :name 'etaf-weread-pane-rows)
          :pane-total (etaf-ref 0 :name 'etaf-weread-pane-total)
          :detail (etaf-ref nil :name 'etaf-weread-detail)
          :notes (etaf-ref nil :name 'etaf-weread-notes)
          :stats (etaf-ref nil :name 'etaf-weread-stats)
          :index-query (etaf-ref "" :name 'etaf-weread-index-query)
          :index-syncing (etaf-ref nil :name 'etaf-weread-index-syncing)
          :index-controller nil
          :index-generation 0
          :index-pending nil
          :account (etaf-ref nil :name 'etaf-weread-account)
          :summary (etaf-ref "" :name 'etaf-weread-summary)
          :theme (etaf-ref (etaf-weread-theme-defaults) :name 'etaf-weread-theme)
          :layout (etaf-ref 'wide :name 'etaf-weread-layout)
          :loading (etaf-ref nil :name 'etaf-weread-loading)
          :error (etaf-ref nil :name 'etaf-weread-error)
          :message (etaf-ref nil :name 'etaf-weread-message))))

(defun etaf-weread--ref (app key)
  "Return APP's reactive source named KEY."
  (plist-get app key))

(defun etaf-weread--read (app key)
  "Return APP's current value for KEY, tracked while rendering."
  (etaf-value (etaf-weread--ref app key)))

(defun etaf-weread--write (app key value)
  "Publish VALUE as APP's new value for KEY; return VALUE.
A write that would not change the reading is skipped: the reader re-renders on
every write, and a reply that repeats the previous reading would otherwise
repaint the whole view for nothing."
  (let ((ref (etaf-weread--ref app key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

(defun etaf-weread--client (app)
  "Return APP's backend client."
  (plist-get app :client))

(defconst etaf-weread--sign-in-command "M-x etaf-weread-login"
  "Command the reader names when the account needs a login.")

(defun etaf-weread--failure-message (message hint code)
  "Return the status-line sentence of a failed request.
MESSAGE is the backend's own sentence and CODE its stable error code.  A login
failure names `etaf-weread-login' instead of the backend's command line,
because that is the command the person can run from the reader; any other
failure keeps the backend's hint beside its message."
  (cond ((equal code "auth")
         (format "%s：%s 登录" message etaf-weread--sign-in-command))
        ((and hint (not (string-empty-p hint))) (format "%s（%s）" message hint))
        (t message)))

(cl-defun etaf-weread--call (app request &key on-ok on-error)
  "Send REQUEST for APP, routing a failure into the visible status line.
ON-OK receives the reply data; ON-ERROR the failure message, its hint and the
backend's error code.  A client that
signals while turning the request into a command is reported like any other
backend failure, so nothing reaches the caller of a reader action."
  (let ((delivered nil)
        (fail (lambda (message hint code)
                (etaf-weread--write app :error message)
                (etaf-weread--write app :message
                                    (etaf-weread--failure-message message hint code))
                (when on-error (funcall on-error message hint code)))))
    (condition-case error
        (etaf-weread-client-call
         (etaf-weread--client app) request
         (lambda (result)
           (setq delivered t)
           (if (eq (car result) :ok)
               (progn
                 (etaf-weread--write app :error nil)
                 (when on-ok (funcall on-ok (cadr result))))
             (funcall fail (or (cadr result) "请求失败")
                      (plist-get (cddr result) :hint)
                      (plist-get (cddr result) :code)))))
      (error (if delivered
                 (signal (car error) (cdr error))
               (funcall fail (error-message-string error) nil nil))))))

(defun etaf-weread--note (app text)
  "Show TEXT as the reader's status line message."
  (etaf-weread--write app :message text))

;;; ---------------------------------------------------------------------------
;;; Formatting helpers
;;; ---------------------------------------------------------------------------

(defun etaf-weread--payload (data)
  "Return the business payload of backend reply DATA.
A backend reply wraps its fields in a `data' object beside `ok',
`conclusion' and `as_of'; a scripted client may pass the fields directly, which
this helper accepts as well."
  (or (plist-get data :data) data))

(defun etaf-weread-format-duration (seconds)
  "Return SECONDS as a compact reading time such as \"1小时13分\" or \"10分\".
Zero or missing time returns an empty string so a row can omit the column."
  (let ((total (max 0 (round (or (and (numberp seconds) seconds) 0)))))
    (if (zerop total)
        ""
      (let ((hours (/ total 3600))
            (minutes (/ (% total 3600) 60)))
        (cond ((and (> hours 0) (> minutes 0)) (format "%d小时%d分" hours minutes))
              ((> hours 0) (format "%d小时" hours))
              (t (format "%d分" minutes)))))))

(defun etaf-weread-progress-bar (percent &optional width)
  "Return a text progress bar of WIDTH cells for PERCENT (0 to 100).
WIDTH defaults to 8.  The filled part uses U+2588 and the remainder U+2591, so
the bar reads as one glyph string in any monospace font."
  (let* ((width (max 1 (or width 8)))
         (ratio (max 0.0 (min 1.0 (/ (float (or (and (numberp percent) percent) 0))
                                     100.0))))
         (filled (round (* ratio width))))
    (concat (make-string filled ?\u2588)
            (make-string (- width filled) ?\u2591))))

(defun etaf-weread--parse-number (value)
  "Return VALUE as a number, or nil when it is empty or not numeric."
  (cond ((numberp value) value)
        ((eq value :false) nil)
        ((not (stringp value)) nil)
        (t (let ((text (string-trim value)))
             (and (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" text)
                  (string-to-number text))))))

(defun etaf-weread--string (value)
  "Return VALUE as a trimmed string, or an empty string."
  (let ((text (cond ((stringp value) value)
                    ((numberp value) (number-to-string value))
                    ((eq value :false) "")
                    (t ""))))
    (string-trim text)))

(defun etaf-weread--list (value)
  "Return VALUE as a list, or nil when it is not one."
  (if (listp value) value nil))

(defun etaf-weread--required-number (value)
  "Return VALUE as a number, defaulting to 0."
  (or (etaf-weread--parse-number value) 0))

(defun etaf-weread--truthy-p (value)
  "Return non-nil when VALUE means true in a backend reply.
The backend writes booleans as JSON true/false, but some legacy fields are 1/0
numbers or \"true\" strings."
  (cond ((eq value t) t)
        ((numberp value) (/= value 0))
        ((stringp value) (member (downcase (string-trim value))
                                 '("true" "1" "yes")))
        (t nil)))

(defun etaf-weread--rating-text (value)
  "Return rating VALUE as \"9.3\", or an empty string.
The backend reports ratings as tenths (93 means 9.3)."
  (let ((rating (etaf-weread--parse-number value)))
    (if (and rating (> rating 0))
        (if (> rating 10)
            (format "%.1f" (/ rating 10.0))
          (format "%.1f" (float rating)))
      "")))

(defun etaf-weread--progress-text (percent)
  "Return PERCENT as \"36%\", or an empty string when it is missing."
  (let ((percent (etaf-weread--parse-number percent)))
    (if (and percent (> percent 0))
        (format "%d%%" (round percent))
      "")))

;;; ---------------------------------------------------------------------------
;;; Section labels and list loading
;;; ---------------------------------------------------------------------------

(defun etaf-weread--section-label (section)
  "Return the sidebar label of SECTION, or nil."
  (seq-some (lambda (group)
              (when-let* ((entry (assq section (cdr group))))
                (nth 1 entry)))
            etaf-weread-sections))

(defun etaf-weread--section-glyph (section)
  "Return the sidebar glyph of SECTION, or an empty string."
  (or (seq-some (lambda (group)
                  (when-let* ((entry (assq section (cdr group))))
                    (nth 2 entry)))
                etaf-weread-sections)
      ""))

(defun etaf-weread-set-filter (app filter)
  "Show the shelf FILTER in APP and load its books.
FILTER is `all' (or \"all\"), `reading' (or \"reading\") or `finished' (or
\"finished\"); the matching section `:shelf', `:reading' or `:finished' is
shown.  Anything else signals `etaf-weread-error'."
  (let* ((filter (string-remove-prefix ":" (downcase (format "%s" filter))))
         (section (pcase filter
                    ((or "all" "shelf") :shelf)
                    ((or "reading" "in-progress") :reading)
                    ((or "finished" "done") :finished)
                    (_ (signal 'etaf-weread-error
                               (list (format "Unknown shelf filter: %S" filter)))))))
    (etaf-weread-locate app section)))

(defun etaf-weread--shelf-filter (section)
  "Return the backend filter string of shelf SECTION."
  (pcase section
    (:reading "reading")
    (:finished "finished")
    (_ "all")))

(defun etaf-weread-locate (app section)
  "Show SECTION of APP and load its rows.
SECTION is one of the keys in `etaf-weread-sections': `:shelf', `:reading',
`:finished', `:notebook', `:index', `:search' or `:stats'.  A cached list is
shown at once and refreshed in the background; the first visit waits for the
backend, and a reply from an earlier section is discarded.  Unknown SECTION
signals `etaf-weread-error'."
  (unless (etaf-weread--section-label section)
    (signal 'etaf-weread-error (list (format "Unknown section: %S" section))))
  (let* ((key (etaf-weread--list-key app section))
         (same-p (equal key (plist-get app :list-key))))
    (etaf-batch
      (etaf-weread--write app :section section)
      (etaf-weread--write app :title (or (etaf-weread--section-label section) "书架"))
      (etaf-weread--write app :subtitle
                          (or (cdr (assq section etaf-weread--section-subtitles)) ""))
      (etaf-weread--write app :mode
                          (pcase section
                            (:search 'search)
                            (:index 'index)
                            (:stats 'stats)
                            (_ 'browse)))
      (etaf-weread--write app :filter (etaf-weread--shelf-filter section))
      (etaf-weread--write app :pane-scroll 0)
      (etaf-weread--show-list-pane app)
      (setf (plist-get app :list-key) key)
      (etaf-weread--show-cached-list app key same-p))
    (if (eq section :index)
        (etaf-weread--index-reload app)
      (cond ((eq section :search)
             (when (not (string-empty-p (etaf-weread--read app :query)))
               (etaf-weread--load-list
                app key (etaf-weread--list-request app section) same-p
                (and (etaf-weread--list-entry app key) t))))
            (t (etaf-weread--load-list
                app key (etaf-weread--list-request app section) same-p
                (and (etaf-weread--list-entry app key) t)))))))

(defun etaf-weread-cycle-theme (app)
  "Switch APP to the next appearance and return it.
The order is `dark', `light' then `sepia'; from `auto' it pins the light or
dark palette opposite the appearance it resolves to.  The choice is stored in
`etaf-weread-settings-file' so the next session starts with it."
  (let* ((order '(dark light sepia))
         (mode (or (cadr (memq (etaf-weread--current-mode) order)) 'dark)))
    (setq etaf-weread-theme-mode mode)
    (etaf-set-value etaf-weread--theme-mode mode)
    (etaf-weread--write app :theme (etaf-weread-theme-defaults mode))
    (etaf-weread--settings-write app)
    (etaf-weread--note app (format "外观：%s"
                                   (pcase mode
                                     ('dark "深色")
                                     ('light "浅色")
                                     (_ "纸色"))))
    mode))

(defun etaf-weread-search (app keyword)
  "Search the WeChat Reading store for KEYWORD and show the matches.
KEYWORD is trimmed; an empty keyword signals `etaf-weread-error' instead of
querying the backend."
  (let ((keyword (string-trim (or keyword ""))))
    (when (string-empty-p keyword)
      (signal 'etaf-weread-error '("搜索关键词不能为空")))
    (let* ((key (list :search keyword))
           (same-p (equal key (plist-get app :list-key))))
      (etaf-batch
        (etaf-weread--write app :section :search)
        (etaf-weread--write app :mode 'search)
        (etaf-weread--write app :query keyword)
        (etaf-weread--write app :title "搜索结果")
        (etaf-weread--write app :subtitle (format "关键词：%s" keyword))
        (etaf-weread--write app :pane-scroll 0)
        (etaf-weread--show-list-pane app)
        (setf (plist-get app :list-key) key)
        (etaf-weread--show-cached-list app key same-p))
      (etaf-weread--load-list app key (etaf-weread--list-request app :search)
                              same-p (and (etaf-weread--list-entry app key) t)))))

(defun etaf-weread--list-key (app section)
  "Return the cache key of SECTION in APP.
A search section keys on its stored query, so a new keyword is a new list."
  (pcase section
    (:index (list :index))
    (:search (list :search (etaf-weread--read app :query)))
    (_ (list section))))

(defun etaf-weread--list-request (app section)
  "Return the backend request for SECTION in APP."
  (pcase section
    (:notebook (list :op :notebook :limit etaf-weread-list-limit))
    (:search (list :op :search :keyword (etaf-weread--read app :query)
                   :count etaf-weread-search-count))
    (:stats (list :op :stats))
    (:index nil)
    (_ (list :op :shelf :filter (etaf-weread--shelf-filter section)
             :limit etaf-weread-list-limit))))

(defconst etaf-weread--cached-sections
  '(:shelf :reading :finished :notebook :stats)
  "Sections whose lists live in the session's list cache.
Search and the highlight index have their own stores.")

(defun etaf-weread--cache-candidate (app now)
  "Return the (SECTION KEY REQUEST) to refresh in the background, or nil.
The stalest cached list comes first; when every cached list is still fresh,
one list that was never loaded is warmed so opening its section can use the
cache.  `etaf-list-cache' owns that order, the freshness interval and the
one-at-a-time rule; this function only maps a section to its request."
  (when (and etaf-weread-prefetch-lists
             (not (plist-get app :disposed))
             (etaf-weread--cache-visible-p app)
             (not (etaf-weread--read app :loading)))
    (let* ((pairs (cl-loop for section in etaf-weread--cached-sections
                           collect (cons (etaf-weread--list-key app section)
                                         section)))
           (key (etaf-list-cache-next (plist-get app :list-cache)
                                      (mapcar #'car pairs)
                                      now etaf-weread-library-refresh-interval)))
      (when key
        (let ((section (cdr (assq key pairs))))
          (list section key (etaf-weread--list-request app section)))))))

(defun etaf-weread--cache-visible-p (app)
  "Return non-nil when APP's buffer can be seen, or the session is headless.
A mounted reader that no window shows pauses its background refreshes: nobody
is looking at it, so the network and CPU can wait until it is shown again."
  (let ((buffer (plist-get app :buffer)))
    (or (null buffer)
        (and (buffer-live-p buffer)
             (get-buffer-window buffer t)))))

(defun etaf-weread--prefetch-list (app)
  "Refresh one cached list of APP in the background when one is due.
The refresh uses the ordinary load path, so a changed reply repaints the
section it belongs to and an unchanged reply leaves the page alone."
  (when-let* ((candidate (etaf-weread--cache-candidate app (float-time))))
    (etaf-weread--load-list app (nth 1 candidate) (nth 2 candidate) t t)))

(defun etaf-weread--schedule-prefetch (app)
  "Arm APP's idle cache refresh, replacing any timer already armed."
  (when etaf-weread-prefetch-lists
    (etaf-list-cache-arm (plist-get app :list-cache)
                         (lambda ()
                           (unless (plist-get app :disposed)
                             (etaf-weread--prefetch-list app)))
                         :interval etaf-weread-prefetch-interval)))

(defun etaf-weread--list-entry (app key)
  "Return APP's cached list for KEY, or nil."
  (etaf-list-cache-entry (plist-get app :list-cache) key))

(defun etaf-weread--store-list (app key rows total)
  "Cache ROWS and TOTAL for KEY in APP."
  (etaf-list-cache-put (plist-get app :list-cache) key rows total))

(defun etaf-weread--show-cached-list (app key keep-position-p)
  "Show APP's cached rows for KEY when one exists, without a loading state.
KEEP-POSITION-P leaves the reader where they are, for a refresh of the list
they are already looking at."
  (let ((entry (etaf-weread--list-entry app key)))
    (etaf-batch
      (etaf-weread--write app :rows (plist-get entry :rows))
      (etaf-weread--write app :list-total (or (plist-get entry :total) 0))
      (if keep-position-p
          (etaf-weread--clamp-list-position app)
        (etaf-weread--write app :selection 0)
        (etaf-weread--write app :window-start 0))
      (etaf-weread--write app :loading nil))))

(defun etaf-weread--clamp-list-position (app)
  "Keep APP's selection and page inside its current rows."
  (let* ((total (length (etaf-weread--read app :rows)))
         (size (max 1 (etaf-weread--read app :page-size))))
    (etaf-weread--write app :selection
                        (max 0 (min (max 0 (1- total))
                                    (etaf-weread--read app :selection))))
    (etaf-weread--write app :window-start
                        (max 0 (min (etaf-weread--read app :window-start)
                                    (max 0 (- total size)))))
    (etaf-weread--sync-pane-total app)))

(defun etaf-weread--load-list
    (app key request &optional keep-position-p background)
  "Load REQUEST for APP, caching its rows under KEY.
KEEP-POSITION-P keeps the position of a reload of the list the reader is
already looking at.  BACKGROUND is a refresh the reader did not ask for: it
shows no loading state, repaints only when the reply differs from the cache,
and never invalidates a visible load.  A reply belonging to an earlier load is
dropped."
  (let* ((generation
          (if background
              (plist-get app :generation)
            (setf (plist-get app :generation) (1+ (plist-get app :generation)))))
         (cache (plist-get app :list-cache))
         (previous (etaf-list-cache-entry cache key)))
    (when background
      (etaf-list-cache-set-busy cache t))
    (unless background
      (etaf-weread--write app :loading t)
      (etaf-weread--write app :error nil))
    (etaf-weread--call
     app request
     :on-ok (lambda (data)
              (when background
                (etaf-list-cache-set-busy cache nil))
              (etaf-list-cache-note-success cache)
              (let* ((rows (etaf-weread--rows-for app request data))
                     (total (or (etaf-weread--parse-number (plist-get data :total))
                                (length rows)))
                     (unchanged (and previous
                                     (equal (plist-get previous :rows) rows)
                                     (equal (plist-get previous :total) total))))
                (etaf-list-cache-put cache key rows total)
                (when (and (= generation (plist-get app :generation))
                           (equal key (plist-get app :list-key)))
                  (if unchanged
                      ;; 内容没变：只收下新的时间戳，页面保持原样。
                      (etaf-weread--write app :loading nil)
                    (etaf-batch
                      (etaf-weread--write app :rows rows)
                      (etaf-weread--write app :list-total total)
                      (if keep-position-p
                          (etaf-weread--clamp-list-position app)
                        (etaf-weread--write app :selection 0)
                        (etaf-weread--write app :window-start 0))
                      (etaf-weread--write app :loading nil)
                      (etaf-weread--write app :summary
                                          (etaf-weread--list-summary app request data rows))
                      (etaf-weread--note app (etaf-weread--list-summary app request data rows)))
                    (etaf-weread--sync-pane-total app)
                    ;; The detail pane follows the settled selection; moving
                    ;; through the list never requests books passed over.
                    (when (etaf-weread--pane-shown-p app)
                      (etaf-weread--schedule-detail
                       app (etaf-weread--selected-id app)))))))
     :on-error (lambda (message _hint code)
                 (etaf-list-cache-note-failure cache code)
                 (when background
                   (etaf-list-cache-set-busy cache nil))
                 (when (and (= generation (plist-get app :generation))
                            (equal key (plist-get app :list-key))
                            (not background))
                   (etaf-weread--write app :loading nil)
                   (etaf-weread--write app :rows nil)
                   (etaf-weread--write app :list-total 0)
                   (etaf-weread--write app :summary "")
                   (etaf-weread--note app message))))))

(defun etaf-weread--rows-for (app request data)
  "Map backend DATA of REQUEST into APP's book rows."
  (let ((payload (etaf-weread--payload data)))
    (pcase (plist-get request :op)
      (:shelf (etaf-weread--book-rows (plist-get payload :shelf) :shelf))
      (:notebook (etaf-weread--book-rows (plist-get payload :books) :notebook))
      (:search (etaf-weread--book-rows (plist-get payload :books) :search))
      (:stats
       (etaf-weread--write app :stats (etaf-weread--stats-from-data data))
       (etaf-weread--book-rows (plist-get payload :top) :stats))
      (_ nil))))

(defun etaf-weread--book-rows (items source)
  "Return book plists ITEMS as list rows for SOURCE.
SOURCE is `:shelf', `:notebook', `:search' or `:stats' and selects the badge a
row carries; a book id is required, everything else is presentation."
  (cl-loop for item in (etaf-weread--list items)
           for id = (etaf-weread--string (plist-get item :bookId))
           when (not (string-empty-p id))
           collect (let* ((counts (plist-get item :counts))
                          (notes (etaf-weread--required-number (plist-get counts :notes)))
                          (reviews (etaf-weread--required-number
                                    (plist-get counts :reviews)))
                          (finished (etaf-weread--truthy-p (plist-get item :finished))))
                     (list :kind :book
                           :id id
                           :title (or (etaf-weread--string (plist-get item :title)) "未命名")
                           :author (etaf-weread--string (plist-get item :author))
                           :category (etaf-weread--string (plist-get item :category))
                           :cover (etaf-weread--string (plist-get item :cover))
                           :deep-link (etaf-weread--string (plist-get item :deepLink))
                           :progress (etaf-weread--required-number
                                      (plist-get item :progress))
                           :reading-time (etaf-weread--required-number
                                          (plist-get item :readingTime))
                           :rating (etaf-weread--parse-number (plist-get item :rating))
                           :finished finished
                           :notes notes
                           :reviews reviews
                           :in-shelf (etaf-weread--truthy-p (plist-get item :inShelf))
                           :badge (pcase source
                                    (:notebook (cond ((and (> notes 0) (> reviews 0))
                                                      (format "✎ %d · ✦ %d" notes reviews))
                                                     ((> notes 0) (format "✎ %d" notes))
                                                     ((> reviews 0) (format "✦ %d" reviews))
                                                     (t "")))
                                    (:search (etaf-weread--rating-text
                                              (plist-get item :rating)))
                                    (_ (cond (finished "读完")
                                             ((> notes 0) (format "✎ %d" notes))
                                             (t ""))))
                           :right (etaf-weread-format-duration
                                   (plist-get item :readingTime))))))

(defun etaf-weread--list-summary (app request data rows)
  "Return the status-line summary of DATA loaded for REQUEST in APP."
  (pcase (plist-get request :op)
    (:shelf (format "书架 %s 本 · 在读 %s · 读完 %s"
                    (or (etaf-weread--parse-number (plist-get data :books))
                        (length rows))
                    (or (etaf-weread--parse-number (plist-get data :reading)) 0)
                    (or (etaf-weread--parse-number (plist-get data :finished)) 0)))
    (:notebook (format "有笔记 %s 本 · 笔记 %s · 想法 %s"
                       (or (etaf-weread--parse-number (plist-get data :books))
                           (length rows))
                       (or (etaf-weread--parse-number (plist-get data :notes)) 0)
                       (or (etaf-weread--parse-number (plist-get data :reviews)) 0)))
    (:search (format "搜索「%s」· 展示了 %d 本"
                     (etaf-weread--read app :query) (length rows)))
    (:stats (let ((stats (etaf-weread--read app :stats)))
              (or (plist-get stats :conclusion)
                  (format "读得最多的 %d 本" (length rows)))))
    (_ "")))

;;; ---------------------------------------------------------------------------
;;; Book detail and highlights
;;; ---------------------------------------------------------------------------

(defun etaf-weread--selected-row (app)
  "Return the row APP's selection points at, or nil."
  (nth (etaf-weread--read app :selection) (etaf-weread--read app :rows)))

(defun etaf-weread--item-id (item)
  "Return the book id of ITEM, a row or an id string, or nil."
  (cond ((null item) nil)
        ((listp item) (let ((id (plist-get item :id)))
                        (and id (not (string-empty-p (format "%s" id)))
                             (format "%s" id))))
        ((stringp item) (unless (string-empty-p (string-trim item))
                          (string-trim item)))
        (t (format "%s" item))))

(defun etaf-weread--item-title (item)
  "Return the book title of ITEM, or an empty string."
  (if (listp item) (or (etaf-weread--string (plist-get item :title)) "") ""))

(defun etaf-weread--detail-id (app)
  "Return the book id APP's detail pane is about, or nil."
  (plist-get (etaf-value (etaf-weread--ref app :detail)) :id))

(defun etaf-weread--selected-id (app)
  "Return the book id APP's selection points at, or nil."
  (etaf-weread--item-id (etaf-weread--selected-row app)))

(defun etaf-weread-show-book (app item &optional pane)
  "Show the book ITEM in APP's side pane and load what is missing.
ITEM is a row or a book id.  PANE is `detail' (the default) or `notes'; the
notes pane always loads the highlights of the book.  Cached data is painted at
once; otherwise a loading placeholder appears and the request runs in the
background.  A missing book id signals `etaf-weread-error'."
  (let ((id (etaf-weread--item-id item)))
    (unless id
      (signal 'etaf-weread-error '("No book selected")))
    (let ((pane (or pane 'detail)))
      (unless (memq pane '(detail notes))
        (signal 'etaf-weread-error (list (format "Unknown pane: %S" pane))))
      (etaf-weread--write app :pane pane)
      (etaf-weread--write app :pane-scroll 0)
      (etaf-weread--publish-detail app id (etaf-weread--item-title item))
      (when (eq pane 'notes)
        (etaf-weread--publish-notes app id))
      (unless (gethash id (plist-get app :detail-cache))
        (etaf-weread--load-detail app id))
      (when (and (eq pane 'notes) (not (gethash id (plist-get app :notes-cache))))
        (etaf-weread--load-notes app id)))
    id))

(defun etaf-weread--schedule-detail (app id)
  "Make APP's detail pane follow ID after a short quiet period.
A book whose detail is cached is painted immediately; otherwise the request is
delayed by `etaf-weread-detail-follow-delay', so fast browsing never asks the
backend about a book that was only passed over."
  (when-let* ((timer (plist-get app :follow-timer)))
    (cancel-timer timer)
    (setf (plist-get app :follow-timer) nil))
  (when (and id
             (not (plist-get app :disposed)))
    (if (gethash id (plist-get app :detail-cache))
        (etaf-weread--publish-detail app id)
      (etaf-weread--publish-detail app id nil)
      (setf (plist-get app :follow-timer)
            (run-at-time
             etaf-weread-detail-follow-delay nil
             (lambda ()
               (setf (plist-get app :follow-timer) nil)
               (when (and (not (plist-get app :disposed))
                          (equal id (etaf-weread--selected-id app))
                          (not (gethash id (plist-get app :detail-cache))))
                 (etaf-weread--load-detail app id))))))))

(defun etaf-weread--publish-detail (app id &optional title)
  "Publish APP's detail data for ID, using cached data when available.
TITLE is used for the loading placeholder before the book info arrives."
  (let ((detail (or (gethash id (plist-get app :detail-cache))
                    (list :id id :title (or title "") :loading t))))
    (etaf-weread--write app :detail detail)
    (etaf-weread--sync-pane-total app)))

(defun etaf-weread--publish-notes (app id)
  "Publish APP's highlights for ID, using cached data when available."
  (let ((notes (or (gethash id (plist-get app :notes-cache))
                   (list :id id :loading t))))
    (etaf-weread--write app :notes notes)
    (etaf-weread--sync-pane-total app)))

(defun etaf-weread--load-detail (app id)
  "Load book info, chapter list and counts of ID into APP.
A reply belonging to a superseded book is still cached but never painted."
  (let ((generation (cl-incf (plist-get app :detail-generation))))
    (etaf-weread--call
     app (list :op :book :id id)
     :on-ok (lambda (data)
              (let ((detail (etaf-weread--detail-from-data data id)))
                (puthash id detail (plist-get app :detail-cache))
                (when (and (= generation (plist-get app :detail-generation))
                           (equal id (etaf-weread--detail-id app)))
                  (etaf-weread--write app :detail detail)
                  (etaf-weread--sync-pane-total app)
                  (etaf-weread--note
                   app (format "%s · %d 章 · %s"
                               (or (plist-get detail :title) id)
                               (length (plist-get detail :chapters))
                               (if (plist-get detail :progress)
                                   (etaf-weread--progress-text (plist-get detail :progress))
                                 "未开始"))))))
     :on-error (lambda (message _hint _code)
                 (when (and (= generation (plist-get app :detail-generation))
                            (equal id (etaf-weread--detail-id app)))
                   (etaf-weread--write app :detail (list :id id :error message))
                   (etaf-weread--note app message))))))

(defun etaf-weread--load-notes (app id)
  "Load the highlights and thoughts of book ID into APP."
  (let ((generation (cl-incf (plist-get app :notes-generation))))
    (etaf-weread--call
     app (list :op :notes :id id)
     :on-ok (lambda (data)
              (let ((notes (etaf-weread--notes-from-data data id)))
                (puthash id notes (plist-get app :notes-cache))
                (when etaf-weread-index-on-read
                  (condition-case error
                      (etaf-weread--index-store app id notes)
                    (error (etaf-weread--note
                            app (format "索引写入失败：%s"
                                        (error-message-string error))))))
                (when (and (= generation (plist-get app :notes-generation))
                           (equal id (plist-get (etaf-value (etaf-weread--ref app :detail)) :id)))
                  (etaf-weread--write app :notes notes)
                  (etaf-weread--sync-pane-total app)
                  (etaf-weread--note app (format "「%s」划线与想法：%d 条"
                                                 (or (plist-get notes :title) id)
                                                 (or (plist-get notes :count) 0))))))
     :on-error (lambda (message _hint _code)
                 (when (and (= generation (plist-get app :notes-generation))
                            (equal id (plist-get (etaf-value (etaf-weread--ref app :detail)) :id)))
                   (etaf-weread--write app :notes (list :id id :error message))
                   (etaf-weread--note app message))))))

(defun etaf-weread--detail-from-data (data id)
  "Return the reader's detail plist built from backend DATA for book ID."
  (let* ((payload (etaf-weread--payload data))
         (book (plist-get payload :book))
         (progress (plist-get payload :progress))
         (counts (plist-get book :counts))
         (finished (etaf-weread--truthy-p (plist-get book :finished))))
    (list :id id
          :title (or (etaf-weread--string (plist-get book :title)) id)
          :author (etaf-weread--string (plist-get book :author))
          :category (etaf-weread--string (plist-get book :category))
          :rating (etaf-weread--rating-text (plist-get book :rating))
          :word-count (etaf-weread--required-number (plist-get book :wordCount))
          :progress (etaf-weread--required-number (plist-get progress :progress))
          :reading-time (etaf-weread--required-number (plist-get progress :readingTime))
          :notes (etaf-weread--required-number (plist-get counts :notes))
          :reviews (etaf-weread--required-number (plist-get counts :reviews))
          :bookmarks (etaf-weread--required-number (plist-get counts :bookmarks))
          :intro (etaf-weread--string (plist-get book :intro))
          :publisher (etaf-weread--string (plist-get book :publisher))
          :translator (etaf-weread--string (plist-get book :translator))
          :published (etaf-weread--string (plist-get book :publishTime))
          :deep-link (or (etaf-weread--string (plist-get book :deepLink))
                         (etaf-weread-reader-url id))
          :finished finished
          :chapters
          (cl-loop for chapter in (etaf-weread--list (plist-get payload :chapters))
                   collect (list :index (etaf-weread--required-number
                                         (plist-get chapter :chapterIdx))
                                 :title (or (etaf-weread--string (plist-get chapter :title))
                                            "—")
                                 :words (etaf-weread--required-number
                                         (plist-get chapter :wordCount))
                                 :paid (etaf-weread--truthy-p (plist-get chapter :paid)))))))

(defun etaf-weread--notes-from-data (data id)
  "Return the highlights plist built from backend DATA for book ID.
Highlights keep their backend order and are grouped by chapter; a thought is
attached to the highlight carrying the same range, and thoughts without a
matching highlight collect under 其他想法."
  (let* ((payload (etaf-weread--payload data))
         (book (plist-get payload :book))
         (highlights (etaf-weread--list (plist-get payload :highlights)))
         (reviews (etaf-weread--list (plist-get payload :reviews)))
         (leftover (copy-sequence reviews))
         (groups nil))
    (dolist (highlight highlights)
      (let* ((chapter (or (etaf-weread--string (plist-get highlight :chapterName))
                          "未分章"))
             (range (etaf-weread--string (plist-get highlight :range)))
             (thought (seq-find (lambda (review)
                                  (equal (etaf-weread--string (plist-get review :range))
                                         range))
                                leftover))
             (group (cl-find chapter groups
                             :key (lambda (item) (plist-get item :chapter))
                             :test #'equal)))
        (when thought
          (setq leftover (delq thought leftover)))
        (unless group
          (setq group (list :chapter chapter :items nil))
          (setq groups (append groups (list group))))
        (let* ((bookmark (etaf-weread--string (plist-get highlight :bookmarkId)))
               (row-id (if (string-empty-p bookmark)
                           (format "hl:%s:%s" id range)
                         bookmark))
               (item (list :id row-id
                           :text (etaf-weread--string (plist-get highlight :markText))
                           :thought (and thought
                                         (etaf-weread--string (plist-get thought :content)))
                           :time (etaf-weread--required-number
                                  (plist-get highlight :createTime)))))
          (plist-put group :items
                     (append (plist-get group :items) (list item))))))
    (when leftover
      (let ((items nil))
        (cl-loop for review in leftover
                 for position from 0
                 do (let* ((review-id (etaf-weread--string
                                       (plist-get review :reviewId)))
                           (row-id (if (string-empty-p review-id)
                                       (format "review:%s:%d" id position)
                                     (format "review:%s" review-id))))
                      (setq items
                            (append items
                                    (list (list :id row-id
                                                :text ""
                                                :thought (etaf-weread--string
                                                          (plist-get review :content))
                                                :time (etaf-weread--required-number
                                                       (plist-get review :createTime))))))))
        (setq groups (append groups
                             (list (list :chapter "其他想法" :items items))))))
    (list :id id
          :title (or (etaf-weread--string (plist-get book :title)) id)
          :count (+ (length highlights) (length reviews))
          :highlights (length highlights)
          :thoughts (length reviews)
          :groups groups)))

(defun etaf-weread--stats-from-data (data)
  "Return the reading statistics built from backend DATA.
The summary counts are top-level fields; the title lists live in the reply's
`data' object."
  (let ((payload (etaf-weread--payload data)))
    (list :books (etaf-weread--required-number (plist-get data :books))
          :finished (etaf-weread--required-number (plist-get data :finished))
          :reading (etaf-weread--required-number (plist-get data :reading))
          :notes (etaf-weread--required-number (plist-get data :notes))
          :total-seconds (etaf-weread--required-number
                          (plist-get data :total_reading_seconds))
          :total-time (etaf-weread--string (plist-get data :total_reading_time))
          :conclusion (etaf-weread--string (plist-get data :conclusion))
          :finished-books (mapcar (lambda (title)
                                    (etaf-weread--string title))
                                  (etaf-weread--list (plist-get payload :finished)))
          :reading-books (cl-loop for item in (etaf-weread--list (plist-get payload :reading))
                                  collect (list :title (etaf-weread--string
                                                        (plist-get item :title))
                                                :progress (etaf-weread--required-number
                                                           (plist-get item :progress)))))))

;;; ---------------------------------------------------------------------------
;;; Selection, panes and actions
;;; ---------------------------------------------------------------------------

(defun etaf-weread-move-selection (app delta)
  "Move APP's list selection by DELTA rows and keep it inside the page.
While the detail pane is visible the pane follows the settled selection."
  (let* ((rows (etaf-weread--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-weread--read app :page-size))))
    (when (> total 0)
      (let ((previous (etaf-weread--read app :selection))
            (selection (max 0 (min (1- total)
                                   (+ (etaf-weread--read app :selection) delta))))
            (start (etaf-weread--read app :window-start)))
        (cond ((< selection start) (setq start selection))
              ((>= selection (+ start size)) (setq start (- (1+ selection) size))))
        (etaf-weread--write app :selection selection)
        (etaf-weread--write app :window-start (max 0 start))
        (when (and (/= selection previous)
                   (etaf-weread--pane-shown-p app))
          (etaf-weread--schedule-detail app (etaf-weread--selected-id app)))))))

(defun etaf-weread-activate-selection (app)
  "Open the book APP's selection points at.
In the notebook section the highlight pane opens; elsewhere the detail pane
opens.  An indexed highlight row opens the highlights of its book.  An empty
list does nothing."
  (when-let* ((row (etaf-weread--selected-row app)))
    (if (eq (plist-get row :kind) :highlight)
        (etaf-weread-show-book app (plist-get row :book) 'notes)
      (let ((pane (if (eq (plist-get (etaf-weread-state app) :section) :notebook)
                      'notes
                    'detail)))
        (etaf-weread-show-book app row pane)))))

(defun etaf-weread-press-row (app index)
  "Press list row INDEX (counting from 1) in APP.
Pressing another row selects it; pressing the selected row again opens it.
This is the gesture a click on a list row performs, which a programmatic
caller can use to follow the same sentence.  An out-of-range INDEX signals
`etaf-weread-error'."
  (let ((total (length (etaf-weread--read app :rows))))
    (unless (and (integerp index) (>= index 1) (<= index total))
      (signal 'etaf-weread-error (list (format "No row %S" index))))
    (if (= (1- index) (etaf-weread--read app :selection))
        (etaf-weread-activate-selection app)
      (etaf-weread--write app :selection (1- index))
      (etaf-weread--clamp-list-position app)
      (when (etaf-weread--pane-shown-p app)
        (etaf-weread--schedule-detail app (etaf-weread--selected-id app))))))

(defun etaf-weread-show-pane (app pane)
  "Show PANE in APP and return it.
PANE is `detail' for the book card with its table of contents, or `notes' for
the highlights and thoughts.  A `wide' layout keeps every column visible, so
there PANE is remembered without removing anything; compact layouts show that
single pane.  Opening the notes loads them when they are not cached yet."
  (unless (memq pane '(detail notes))
    (signal 'etaf-weread-error (list (format "Unknown pane: %S" pane))))
  (etaf-weread--write app :pane pane)
  (etaf-weread--write app :pane-scroll 0)
  (when (and (eq pane 'notes)
             (etaf-weread--detail-id app)
             (not (gethash (etaf-weread--detail-id app)
                           (plist-get app :notes-cache))))
    (etaf-weread--load-notes app (etaf-weread--detail-id app)))
  pane)

(defun etaf-weread-toggle-pane (app)
  "Switch APP's side pane between the book detail and its highlights."
  (etaf-weread-show-pane app
                         (if (eq (etaf-weread--effective-pane app) 'detail)
                             'notes
                           'detail)))

(defun etaf-weread-scroll-pane (app delta)
  "Scroll APP's detail or highlight pane by DELTA rows."
  (let* ((total (etaf-weread--read app :pane-total))
         (size (max 1 (etaf-weread--read app :pane-rows))))
    (etaf-weread--write app :pane-scroll
                        (max 0 (min (+ (etaf-weread--read app :pane-scroll) delta)
                                    (max 0 (- total size)))))))

(defun etaf-weread-reader-url (item)
  "Return the WeChat Reading URL of ITEM, or nil.
ITEM is a book row or a book id.  The backend's deep link is used when it has
one, otherwise the id addresses the web reader."
  (let ((deep-link (and (listp item) (etaf-weread--string (plist-get item :deep-link))))
        (id (etaf-weread--item-id item)))
    (cond ((and deep-link (not (string-empty-p deep-link))) deep-link)
          ((and (stringp item) (string-match-p "\\`https?://" item)) item)
          ((and id (not (string-empty-p id)))
           (format "https://weread.qq.com/web/reader/%s" id))
          (t nil))))

(defun etaf-weread-open-book (app &optional item)
  "Open ITEM, or APP's selected book, in the WeChat Reading web reader.
The browser is opened through `browse-url', so the reader keeps running while
the account reads.  A book without a URL signals `etaf-weread-error'."
  (let* ((item (or item (etaf-weread--selected-row app)))
         (url (etaf-weread-reader-url item)))
    (unless url
      (signal 'etaf-weread-error '("No book to open")))
    (etaf-weread--note app (format "在浏览器中打开：%s"
                                   (or (etaf-weread--item-title item) url)))
    (browse-url url)
    url))

(defun etaf-weread-export-notes (app &optional item)
  "Export the highlights and thoughts of ITEM, or the selected book, as Markdown.
The backend writes the file under its configured export directory and the reply
is reported in the status line.  A book without an id signals
`etaf-weread-error'."
  (let* ((item (or item (etaf-weread--selected-row app)))
         (id (etaf-weread--item-id item)))
    (unless id
      (signal 'etaf-weread-error '("No book to export")))
    (etaf-weread--note app (format "正在导出笔记：%s…"
                                   (or (etaf-weread--item-title item) id)))
    (etaf-weread--call
     app (list :op :export :id id)
     :on-ok (lambda (data)
              (etaf-weread--note app
                                 (or (etaf-weread--string (plist-get data :conclusion))
                                     (format "笔记已导出：%s" id)))))
    id))

(defun etaf-weread-refresh (app)
  "Reload APP's current list, account and statistics.
The list reload keeps the reader's position and re-fits the layout to the
window that shows APP."
  (etaf-weread--write app :error nil)
  (etaf-weread--sync-layout app)
  (let* ((section (etaf-weread--read app :section))
         (key (etaf-weread--list-key app section)))
    (setf (plist-get app :list-key) key)
    (etaf-weread--load-list app key (etaf-weread--list-request app section) t)
    (when (eq section :search)
      (etaf-weread--write app :query (etaf-weread--read app :query))))
  (etaf-weread--request-account app)
  ;; The statistics summary is cheap and feeds the status line, so a mounted
  ;; reader keeps it warm even while browsing another section.
  (unless (eq (etaf-weread--read app :section) :stats)
    (etaf-weread--request-stats app))
  (when (eq (etaf-weread--read app :section) :stats)
    (etaf-weread--request-stats app))
  (when (eq (etaf-weread--read app :section) :index)
    (etaf-weread--index-reload app))
  (etaf-weread--sync-pane-total app))

(defun etaf-weread--request-account (app)
  "Load APP's account from the stored login."
  (etaf-weread--call
   app (list :op :status)
   :on-ok (lambda (data)
            (etaf-weread--write app :account
                                (list :name (or (etaf-weread--string
                                                 (plist-get data :name))
                                                "已登录")
                                      :vid (etaf-weread--string (plist-get data :vid))
                                      :login (etaf-weread--string (plist-get data :login))))
            (etaf-weread--write app :summary
                                (or (etaf-weread--read app :summary) "")))))

(defun etaf-weread--request-stats (app)
  "Load APP's aggregate reading statistics into the summary."
  (etaf-weread--call
   app (list :op :stats)
   :on-ok (lambda (data)
            (etaf-weread--write app :stats (etaf-weread--stats-from-data data))
            (unless (plist-get (etaf-weread--read app :stats) :error)
              (when (or (null (etaf-weread--read app :rows))
                        (eq (etaf-weread--read app :section) :stats))
                (etaf-weread--write app :summary
                                    (etaf-weread--string
                                     (plist-get data :conclusion))))))))

;;; ---------------------------------------------------------------------------
;;; Local highlight index
;;; ---------------------------------------------------------------------------

(defun etaf-weread--index-reload (app)
  "Show APP's local highlight index filtered by its `:index-query'.
The rows are read from the SQLite index through ETAF DB; a storage failure is
reported in the status line instead of breaking the reader."
  (condition-case error
      (let* ((stored (etaf-weread--index-rows app))
             (query (etaf-weread--read app :index-query))
             (rows (etaf-weread--index-list-rows
                    (etaf-weread--index-sorted
                     (etaf-weread--index-filter stored query)))))
        (etaf-batch
          (etaf-weread--write app :rows rows)
          (etaf-weread--write app :list-total (length rows))
          (etaf-weread--clamp-list-position app)
          (etaf-weread--write app :loading nil)
          (etaf-weread--write app :summary
                              (format "本地索引 %d 条%s"
                                      (length rows)
                                      (if (string-empty-p (string-trim query))
                                          ""
                                        (format "（筛选：%s）" (string-trim query)))))
          (etaf-weread--note
           app (if (and (string-empty-p (string-trim query)) (null rows))
                   "本地索引还是空的：按 I 索引笔记本，或先翻几本书的笔记"
                 (format "本地索引 %d 条" (length rows)))))
        (length rows))
    (error
     (etaf-weread--write app :rows nil)
     (etaf-weread--write app :list-total 0)
     (etaf-weread--write app :loading nil)
     (etaf-weread--write app :error (error-message-string error))
     (etaf-weread--note app (format "本地索引不可用：%s" (error-message-string error)))
     0)))

(defun etaf-weread-index-search (app &optional keyword)
  "Filter APP's local highlight index by KEYWORD and show the results.
KEYWORD matches the highlight, the thought, the chapter and the book title
case-insensitively; nil or an empty keyword shows every indexed highlight.
The `:index' section is shown, which is also what `etaf-weread-locate' does."
  (etaf-weread--write app :index-query (or keyword ""))
  (etaf-weread-locate app :index)
  (length (etaf-weread--read app :rows)))

(defun etaf-weread-index-notebook (app &optional refresh)
  "Index the highlights of every notebook book into APP's SQLite index.
The notebook is listed once; the books not indexed yet are fetched one at a
time in the background, and REFRESH non-nil re-fetches books that are already
indexed.  Progress is reported in the status line and a reply after dispose is
dropped.  Return the generation of this run."
  (let ((generation (cl-incf (plist-get app :index-generation))))
    (setf (plist-get app :index-pending) nil)
    (etaf-weread--write app :index-syncing "正在读取笔记本…")
    (etaf-weread--note app "正在读取笔记本…")
    (etaf-weread--call
     app (list :op :notebook :limit etaf-weread-list-limit)
     :on-ok (lambda (data)
              (when (= generation (plist-get app :index-generation))
                (let* ((payload (etaf-weread--payload data))
                       (books (etaf-weread--book-rows (plist-get payload :books) :notebook))
                       (indexed (and (not refresh) (etaf-weread--index-books app)))
                       (pending (cl-remove-if
                                 (lambda (row)
                                   (and indexed (gethash (plist-get row :id) indexed)))
                                 books)))
                  (setf (plist-get app :index-pending)
                        (list :generation generation :remaining pending
                              :total (length pending) :done 0
                              :stored 0))
                  (if pending
                      (progn
                        (etaf-weread--write app :index-syncing
                                            (format "索引 0/%d" (length pending)))
                        (etaf-weread--index-step app))
                    (progn
                      (etaf-weread--write app :index-syncing nil)
                      (etaf-weread--note app "索引已是最新")
                      (when (eq (etaf-weread--read app :section) :index)
                        (etaf-weread--index-reload app)))))))
     :on-error (lambda (_message _hint _code)
                 (when (= generation (plist-get app :index-generation))
                   (etaf-weread--write app :index-syncing nil))))
    generation))

(defun etaf-weread--index-step (app)
  "Fetch the next pending notebook book and store its highlights.
Every reply checks the run generation, so a disposed session or a newer index
run never continues an older walk.  One book is in flight at a time, which
keeps the backend's rate limit and the progress line honest."
  (let* ((pending (plist-get app :index-pending))
         (generation (and pending (plist-get pending :generation))))
    (when (and pending (= generation (plist-get app :index-generation)))
      (if (null (plist-get pending :remaining))
          (progn
            (setf (plist-get app :index-pending) nil)
            (etaf-weread--write app :index-syncing nil)
            (etaf-weread--note app
                               (format "索引完成：写入 %d 条"
                                       (plist-get pending :stored)))
            (when (eq (etaf-weread--read app :section) :index)
              (etaf-weread--index-reload app)))
        (let* ((remaining (plist-get pending :remaining))
               (row (car remaining))
               (id (plist-get row :id))
               (title (or (plist-get row :title) id)))
          (etaf-weread--write app :index-syncing
                              (format "索引 %d/%d：%s"
                                      (1+ (plist-get pending :done))
                                      (plist-get pending :total)
                                      (truncate-string-to-width title 16 nil nil "…")))
          (etaf-weread--call
           app (list :op :notes :id id)
           :on-ok (lambda (data)
                    (when (= generation (plist-get app :index-generation))
                      (condition-case error
                          (let ((counts (etaf-weread--index-store
                                         app id (etaf-weread--notes-from-data data id))))
                            (plist-put pending :stored
                                       (+ (plist-get pending :stored)
                                          (plist-get counts :stored))))
                        (error
                         (etaf-weread--note app
                                            (format "索引写入失败：%s"
                                                    (error-message-string error)))))
                      (plist-put pending :remaining (cdr remaining))
                      (plist-put pending :done (1+ (plist-get pending :done)))
                      (etaf-weread--index-step app)))
           :on-error (lambda (message _hint _code)
                       (when (= generation (plist-get app :index-generation))
                         (setf (plist-get app :index-pending) nil)
                         (etaf-weread--write app :index-syncing nil)
                         (etaf-weread--note app (format "索引中断：%s" message))))))))))

;;; ---------------------------------------------------------------------------
;;; Layout fitting
;;; ---------------------------------------------------------------------------

(defun etaf-weread--page-size-for (window &optional layout)
  "Return the book row count that fits WINDOW's height in LAYOUT.
Compact layouts spend lines on the chip strip and pane tabs, so they fit fewer
rows than the wide three-column layout."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         ;; The chrome includes the root's top padding line.
         (chrome (pcase layout
                   ('narrow 16)
                   ('medium 14)
                   (_ 11))))
    (max 1 (- height chrome))))

(defun etaf-weread--pane-rows-for (window layout)
  "Return the content rows of the side pane fitting WINDOW in LAYOUT.
The book card above the chapter list takes about ten lines; the notes pane has
a shorter heading.  A compact layout gives the pane the full body height."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         ;; The chrome includes the root's top padding line.
         (chrome (pcase layout
                   ('narrow 16)
                   ('medium 14)
                   (_ 15))))
    (max 1 (- height chrome))))

(defun etaf-weread--window-columns (&optional window)
  "Return WINDOW's body width in columns, or the frame width when it is dead."
  (if (and window (window-live-p window))
      (window-body-width window)
    (frame-width)))

(defun etaf-weread--layout-for (columns)
  "Return the layout COLUMNS columns of text can hold.
The result is `wide', `medium' or `narrow'; see `etaf-weread-wide-columns' and
`etaf-weread-medium-columns'."
  (cond ((>= columns etaf-weread-wide-columns) 'wide)
        ((>= columns etaf-weread-medium-columns) 'medium)
        (t 'narrow)))

(defun etaf-weread--sync-layout (app &optional window)
  "Match APP's layout, pane visibility and row budgets to WINDOW.
WINDOW defaults to the window showing APP's buffer.  A headless session keeps
the wide layout, because it has no viewport to adapt to."
  (let* ((buffer (plist-get app :buffer))
         (window (or window
                     (and (buffer-live-p buffer) (get-buffer-window buffer t))))
         (layout (if window
                     (etaf-weread--layout-for (etaf-weread--window-columns window))
                   'wide))
         (size (etaf-weread--page-size-for window layout)))
    (etaf-batch
      (etaf-weread--write app :layout layout)
      (etaf-weread--write app :page-size size)
      (etaf-weread--write app :window-rows
                          (if (and window (window-live-p window))
                              (window-body-height window)
                            (frame-height)))
      (etaf-weread--write app :pane-rows (etaf-weread--pane-rows-for window layout))
      (etaf-weread--clamp-list-position app)
      (etaf-weread--sync-pane-total app))
    layout))

(defun etaf-weread--compact-layout-p (app)
  "Return non-nil when APP shows one pane at a time."
  (not (eq (etaf-weread--read app :layout) 'wide)))

(defun etaf-weread--show-list-pane (app)
  "Bring APP's list pane back into view on a compact layout.
Loading a section, a filter or a store search is a list operation, and a
compact frame shows one pane at a time; it must leave the side pane it was
showing.  A wide layout keeps every column, so its pane choice is kept."
  (when (and (etaf-weread--compact-layout-p app)
             (not (eq (etaf-weread--read app :pane) 'list)))
    (etaf-weread--write app :pane 'list)
    (etaf-weread--sync-layout app)))

(defun etaf-weread--effective-pane (app)
  "Return the pane APP is actually showing.
A `wide' layout keeps the side pane visible, so a `list' reading there means
the detail pane; a compact layout shows exactly the recorded pane."
  (let ((pane (etaf-weread--read app :pane)))
    (if (and (eq pane 'list) (not (etaf-weread--compact-layout-p app)))
        'detail
      pane)))

(defun etaf-weread--list-shown-p (app)
  "Return non-nil when APP's book list fits in the frame."
  (or (not (etaf-weread--compact-layout-p app))
      (eq (etaf-weread--read app :pane) 'list)))

(defun etaf-weread--pane-shown-p (app)
  "Return non-nil when APP's detail or highlight pane fits in the frame."
  (or (not (etaf-weread--compact-layout-p app))
      (memq (etaf-weread--read app :pane) '(detail notes))))

(defun etaf-weread--sync-pane-total (app)
  "Recompute the scrollable rows of APP's side pane."
  (let* ((total (pcase (etaf-weread--effective-pane app)
                  ('notes (etaf-weread--notes-total app))
                  (_ (etaf-weread--detail-total app))))
         (page (max 1 (etaf-weread--read app :pane-rows))))
    (etaf-weread--write app :pane-total total)
    (etaf-weread--write app :pane-scroll
                        (max 0 (min (etaf-weread--read app :pane-scroll)
                                    (max 0 (- total page)))))))
(defun etaf-weread--detail-total (app)
  "Return the scrollable chapter lines of APP's detail pane."
  (length (plist-get (etaf-value (etaf-weread--ref app :detail)) :chapters)))

(defun etaf-weread--notes-lines (groups)
  "Return GROUPS flattened into the lines of the highlight pane.
A chapter heading, a quote and a thought are each one line carrying `:kind';
this is what the pane counts and slices, so the pane's scroll budget and the
rendered lines always agree."
  (let ((lines nil)
        (position 0))
    (dolist (group groups)
      (push (list :key (cl-incf position)
                  :kind 'chapter
                  :text (or (plist-get group :chapter) ""))
            lines)
      (dolist (item (plist-get group :items))
        (let ((text (or (plist-get item :text) ""))
              (thought (or (plist-get item :thought) "")))
          (cl-incf position)
          (if (string-empty-p text)
              (unless (string-empty-p thought)
                (push (list :key position
                            :kind 'thought :text thought)
                      lines))
            (push (list :key position
                        :kind 'quote :text text :thought thought)
                  lines)))))
    (nreverse lines)))

(defun etaf-weread--notes-total (app)
  "Return the scrollable lines of APP's highlight pane."
  (length (etaf-weread--notes-lines
           (plist-get (etaf-value (etaf-weread--ref app :notes)) :groups))))

(defun etaf-weread--page-rows (app)
  "Return the visible slice of APP's rows as (ROWS START TOTAL)."
  (let* ((rows (etaf-weread--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-weread--read app :page-size)))
         (start (max 0 (min (etaf-weread--read app :window-start)
                            (max 0 (- total size))))))
    (list (seq-subseq rows start (min total (+ start size))) start total)))

;;; ---------------------------------------------------------------------------
;;; Session lifecycle
;;; ---------------------------------------------------------------------------

(defun etaf-weread--start (app)
  "Start APP: fit the layout and warm the list cache.
An opened reader refits the layout after each settled resize through its
application window fit (see `etaf-weread-open').
Lists are cached per section and shown at once; a slow background timer
compares them with fresh replies and repaints only what changed, so the
sidebar stays current without ever making the reader wait."
  (setf (plist-get app :disposed) nil
        (plist-get app :started-at) (float-time))
  (etaf-weread--sync-layout app)
  (etaf-weread--schedule-prefetch app))

(defun etaf-weread--dispose (app)
  "Release APP's timers, local index and in-flight requests."
  (setf (plist-get app :disposed) t)
  (cl-incf (plist-get app :index-generation))
  (setf (plist-get app :index-pending) nil)
  (when-let* ((timer (plist-get app :follow-timer)))
    (cancel-timer timer)
    (setf (plist-get app :follow-timer) nil))
  (etaf-list-cache-disarm (plist-get app :list-cache))
  (etaf-weread--index-dispose app)
  (etaf-weread-cancel (etaf-weread--client app)))

;;; ---------------------------------------------------------------------------
;;; Detached state for callers and tests
;;; ---------------------------------------------------------------------------

(defun etaf-weread-state (app)
  "Return APP's session state as a detached plist.
The snapshot is a copy: mutating it never changes the reader.  Keys are
`:section', `:filter', `:title', `:subtitle', `:mode', `:query', `:items'
(the loaded rows), `:visible' (the rows on the current page), `:selection',
`:window-start', `:page-size', `:rows-total' (loaded count), `:list-total'
(backend total or the loaded count), `:layout', `:pane', `:pane-rows',
`:pane-scroll', `:pane-total', `:detail', `:notes', `:stats', `:account',
`:summary', `:theme', `:loading', `:error', `:message' and `:viewport-width'
(the pixel canvas the reader paints)."
  (let* ((rows (etaf-weread--read app :rows))
         (page (etaf-weread--page-rows app))
         (detail (etaf-weread--read app :detail))
         (notes (etaf-weread--read app :notes))
         (stats (etaf-weread--read app :stats)))
    (list :section (etaf-weread--read app :section)
          :filter (etaf-weread--read app :filter)
          :title (etaf-weread--read app :title)
          :subtitle (etaf-weread--read app :subtitle)
          :mode (etaf-weread--read app :mode)
          :query (etaf-weread--read app :query)
          :items (mapcar #'copy-sequence rows)
          :visible (mapcar #'copy-sequence (nth 0 page))
          :window-start (nth 1 page)
          :selection (etaf-weread--read app :selection)
          :page-size (etaf-weread--read app :page-size)
          :viewport-width
          (let ((runtime (and (buffer-live-p (plist-get app :buffer))
                              (etaf-runtime-for-buffer (plist-get app :buffer)))))
            (and runtime (etaf-runtime-mounted-p runtime)
                 (car (etaf-runtime-viewport runtime))))
          :rows-total (length rows)
          :list-total (etaf-weread--read app :list-total)
          :layout (etaf-weread--read app :layout)
          :pane (etaf-weread--read app :pane)
          :pane-rows (etaf-weread--read app :pane-rows)
          :pane-scroll (etaf-weread--read app :pane-scroll)
          :pane-total (etaf-weread--read app :pane-total)
          :detail (and detail (copy-sequence detail))
          :notes (and notes (copy-sequence notes))
          :stats (and stats (copy-sequence stats))
          :account (let ((account (etaf-weread--read app :account)))
                     (and account (copy-sequence account)))
          :summary (etaf-weread--read app :summary)
          :index-query (etaf-weread--read app :index-query)
          :index-syncing (etaf-weread--read app :index-syncing)
          :theme (etaf-weread--read app :theme)
          :loading (etaf-weread--read app :loading)
          :error (etaf-weread--read app :error)
          :message (etaf-weread--read app :message))))

(provide 'etaf-weread-model)
;;; etaf-weread-model.el ends here
