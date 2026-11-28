;;; etaf-weread-tests.el --- Acceptance tests for etaf-weread -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public behaviour tests.  Every scenario drives the reader through the
;; interfaces declared in `etaf-weread.el' with a scripted client, so no test
;; needs the network, a login or a graphical frame.  The local index scenarios
;; exercise the real SQLite backend against a temporary database file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-weread)

;;; ---------------------------------------------------------------------------
;;; Scripted backend
;;; ---------------------------------------------------------------------------

(defvar etaf-weread-tests--requests nil
  "Requests received by the scripted client, newest first.")

(defvar etaf-weread-tests--error nil
  "When non-nil, the scripted client fails every request with this message.")

(defvar etaf-weread-tests--thought "想法内容"
  "Thought the scripted client attaches to the matching highlight.")

(defvar etaf-weread-tests--book-count 2
  "Number of books the scripted shelf and notebook list.")

(defun etaf-weread-tests--books (&optional prefix)
  "Return BOOK-COUNT backend books named with PREFIX."
  (cl-loop for index from 1 to etaf-weread-tests--book-count
           collect (list :bookId (number-to-string index)
                         :title (format "%s书%d" (or prefix "") index)
                         :author (format "作者%d" index)
                         :progress (if (= index 1) 36 0)
                         :readingTime (if (= index 1) 4384 0))))

(defun etaf-weread-tests--notes (book-id title)
  "Return the notes reply of BOOK-ID named TITLE.
The second book carries an orphan thought, so grouping is observable."
  (list :ok t
        :data (list :book (list :bookId book-id :title title)
                    :highlights (list (list :bookmarkId (format "%s-b1" book-id)
                                            :chapterName "第一章" :range "1-2"
                                            :markText (format "%s的划线" title)
                                            :createTime 100))
                    :reviews (append
                              (list (list :reviewId (format "%s-r1" book-id)
                                          :range "1-2"
                                          :content etaf-weread-tests--thought
                                          :createTime 101))
                              (when (equal book-id "2")
                                (list (list :reviewId (format "%s-r2" book-id)
                                            :range "9-9"
                                            :content "没有划线的想法"
                                            :createTime 102)))))))

(defvar etaf-weread-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file, resolved while it is loaded.")

(defvar etaf-weread-tests--extra-chapters nil
  "Extra chapters the scripted book reports, for tests that need a long pane.")

(defun etaf-weread-tests--client (request callback)
  "Answer REQUEST on CALLBACK from the scripted account."
  (push request etaf-weread-tests--requests)
  (if etaf-weread-tests--error
      (funcall callback (list :error etaf-weread-tests--error :hint "scripted"))
    (funcall callback
             (list :ok
                   (pcase (plist-get request :op)
                     (:status (list :ok t :login "ok" :name "测试读者" :vid "1"))
                     (:login (list :ok t :login "ok" :name "测试读者" :vid "1"
                                   :conclusion "登录成功：测试读者"))
                     (:logout (list :ok t :login "out"
                                    :conclusion "已退出微信读书：本机登录态已删除"))
                     (:shelf (list :ok t :books etaf-weread-tests--book-count
                                   :reading 1 :finished 0
                                   :data (list :shelf (etaf-weread-tests--books))))
                     (:notebook (list :ok t :books etaf-weread-tests--book-count
                                      :notes 2 :reviews 2
                                      :data (list :books
                                                  (mapcar (lambda (book)
                                                            (list :bookId (plist-get book :bookId)
                                                                  :title (plist-get book :title)
                                                                  :counts (list :notes 1 :reviews 1)))
                                                          (etaf-weread-tests--books)))))
                     (:search (list :ok t
                                    :data (list :books
                                                (list (list :bookId "9" :title "搜到的书"
                                                            :author "作者" :rating 93)))))
                     (:book (list :ok t
                                  :data (list :book (list :bookId (plist-get request :id)
                                                          :title (format "详情节%s" (plist-get request :id))
                                                          :author "作者"
                                                          :category "文学"
                                                          :counts (list :notes 1 :reviews 1)
                                                          :intro "简介")
                                              :progress (list :progress 36 :readingTime 4384)
                                              :chapters (append
                                                         (list (list :chapterIdx 1 :title "第一章"
                                                                     :wordCount 100)
                                                               (list :chapterIdx 2 :title "第二章"
                                                                     :wordCount 200))
                                                         etaf-weread-tests--extra-chapters))))
                     (:notes (etaf-weread-tests--notes
                              (plist-get request :id)
                              (format "详情节%s" (plist-get request :id))))
                     (:stats (list :ok t :books etaf-weread-tests--book-count
                                   :finished 0 :reading 1 :notes 2
                                   :total_reading_seconds 4384
                                   :total_reading_time "1小时13分"
                                   :conclusion "读完 0 本 · 在读 1 本 · 累计 1小时13分"
                                   :data (list :top (etaf-weread-tests--books)
                                               :finished nil :reading nil)))
                     (:export (list :ok t :conclusion "已导出笔记"))))))) 

(defvar etaf-weread-tests--settings nil
  "Settings file the next test session binds, for tests that share one file.")

(defun etaf-weread-tests--session (&optional client)
  "Return a reader session driven by the scripted CLIENT.
The session's preferences live in a disposable file, so a test never reads or
writes the settings file of a real reader.  A test that needs two sessions to
share one file binds `etaf-weread-tests--settings' first."
  (let ((etaf-weread-settings-file
         (or etaf-weread-tests--settings
             (make-temp-file "weread-tests-settings-" nil ".eld"))))
    (etaf-weread-create :client (or client #'etaf-weread-tests--client))))

(defun etaf-weread-tests--request (op)
  "Return the newest recorded request whose `:op' is OP."
  (seq-find (lambda (request) (eq (plist-get request :op) op))
            etaf-weread-tests--requests))

(defun etaf-weread-tests--request-count (op)
  "Return how many recorded requests use OP."
  (cl-count op etaf-weread-tests--requests :key (lambda (request)
                                                   (plist-get request :op))))

(defmacro etaf-weread-tests--with-index (&rest body)
  "Run BODY with a disposable SQLite index and index-on-read enabled."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "etaf-weread-index-" t))
          (etaf-weread-index-file (expand-file-name "notes.sqlite3" directory))
          (etaf-weread-index-on-read t))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p directory)
         (delete-directory directory t)))))

(defun etaf-weread-tests--wait (predicate &optional timeout)
  "Wait until PREDICATE is non-nil for at most TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

;;; ---------------------------------------------------------------------------
;;; Session and list behaviour
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-new-session-is-headless ()
  "A session built without a buffer sends no request and keeps its defaults."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (let ((state (etaf-weread-state app)))
      (should (eq (plist-get state :section) :shelf))
      (should (eq (plist-get state :pane) 'list))
      (should (eq (plist-get state :layout) 'wide))
      (should (equal (plist-get state :index-query) ""))
      (should (= (plist-get state :rows-total) 0)))
    (should-not etaf-weread-tests--requests)))

(ert-deftest etaf-weread-tests-refresh-loads-shelf-account-and-stats ()
  "Refreshing loads the shelf, the account and the reading statistics."
  (setq etaf-weread-tests--requests nil)
  (let* ((app (etaf-weread-tests--session))
         (state (progn (etaf-weread-refresh app) (etaf-weread-state app))))
    (should (= (plist-get state :rows-total) 2))
    (should (equal (plist-get (nth 0 (plist-get state :items)) :title) "书1"))
    (should (equal (plist-get (nth 0 (plist-get state :items)) :right) "1小时13分"))
    (should (string-match-p "书架 2 本" (plist-get state :message)))
    (should (equal (plist-get (plist-get state :account) :name) "测试读者"))
    (should (equal (plist-get (plist-get state :stats) :total-time) "1小时13分"))
    (should (memq :shelf (mapcar (lambda (request) (plist-get request :op))
                                 etaf-weread-tests--requests)))
    (should (= (plist-get state :list-total) 2))))

(ert-deftest etaf-weread-tests-login-sends-the-login-request-and-reloads ()
  "Signing in runs the backend login and loads the account it returns."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (should (eq (etaf-weread-login app) app))
    (let ((request (etaf-weread-tests--request :login)))
      (should request)
      (should (= (plist-get request :timeout) etaf-weread-login-timeout)))
    (let ((state (etaf-weread-state app)))
      (should (equal (plist-get (plist-get state :account) :name) "测试读者"))
      (should-not (plist-get state :error))
      (should (= (plist-get state :rows-total) 2)))))

(ert-deftest etaf-weread-tests-logout-forgets-the-account-and-names-the-command ()
  "Signing out drops the account data and shows the Emacs login command."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-refresh app)
    (should (= (plist-get (etaf-weread-state app) :rows-total) 2))
    (should (eq (etaf-weread-logout app) app))
    (should (etaf-weread-tests--request :logout))
    (let ((state (etaf-weread-state app)))
      (should-not (plist-get state :account))
      (should-not (plist-get state :stats))
      (should-not (plist-get state :error))
      (should (= (plist-get state :rows-total) 0))
      (should (string-match-p "已退出" (plist-get state :message)))
      (should (string-match-p "M-x etaf-weread-login" (plist-get state :message))))))

(ert-deftest etaf-weread-tests-login-failure-names-the-emacs-command ()
  "A failure needing a login names `etaf-weread-login', not the backend CLI."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session
              (lambda (request callback)
                (push request etaf-weread-tests--requests)
                (funcall callback
                         (list :error "还没有微信读书登录态"
                               :hint "node weread.mjs login"
                               :code "auth"))))))
    (etaf-weread-refresh app)
    (let ((state (etaf-weread-state app)))
      (should (equal (plist-get state :error) "还没有微信读书登录态"))
      (should (string-match-p "还没有微信读书登录态" (plist-get state :message)))
      (should (string-match-p "M-x etaf-weread-login" (plist-get state :message)))
      (should-not (string-match-p "weread.mjs" (plist-get state :message))))))

(ert-deftest etaf-weread-tests-sections-are-navigable ()
  "Every sidebar section opens and names itself; unknown sections signal."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    (let ((app (etaf-weread-tests--session)))
      (dolist (entry (apply #'append (mapcar #'cdr etaf-weread-sections)))
        (let ((section (car entry)))
          (etaf-weread-locate app section)
          (let ((state (etaf-weread-state app)))
            (should (eq (plist-get state :section) section))
            (should (equal (plist-get state :title) (nth 1 entry))))))
      (etaf-weread-locate app :shelf)
      (should-error (etaf-weread-locate app :nonsense) :type 'etaf-weread-error)
      (should (eq (plist-get (etaf-weread-state app) :section) :shelf)))))

(ert-deftest etaf-weread-tests-filter-selects-shelf-section ()
  "`etaf-weread-set-filter' shows the matching shelf section and filter."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (dolist (case '(("all" . :shelf) ("reading" . :reading) ("finished" . :finished)))
      (etaf-weread-set-filter app (car case))
      (should (eq (plist-get (etaf-weread-state app) :section) (cdr case))))
    (should (equal (plist-get (etaf-weread-tests--request :shelf) :filter) "finished"))
    (should-error (etaf-weread-set-filter app "sideways") :type 'etaf-weread-error)))

(ert-deftest etaf-weread-tests-search-trims-and-rejects-blank ()
  "Searching trims the keyword, shows the results, and rejects a blank one."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-search app "  三体  ")
    (let ((state (etaf-weread-state app)))
      (should (equal (plist-get state :query) "三体"))
      (should (eq (plist-get state :mode) 'search))
      (should (equal (plist-get (nth 0 (plist-get state :items)) :title) "搜到的书")))
    (should (equal (plist-get (etaf-weread-tests--request :search) :keyword) "三体"))
    (should-error (etaf-weread-search app "   ") :type 'etaf-weread-error)))

(ert-deftest etaf-weread-tests-selection-keeps-its-page ()
  "Selection clamps at both ends, scrolls the page, and activates a row."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-page-size 2)
         (app (etaf-weread-tests--session)))
    (etaf-weread-refresh app)
    (etaf-weread-move-selection app 5)
    (should (= (plist-get (etaf-weread-state app) :selection) 1))
    (etaf-weread-move-selection app -9)
    (should (= (plist-get (etaf-weread-state app) :selection) 0))
    (etaf-weread-activate-selection app)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))
    (should (equal (plist-get (plist-get (etaf-weread-state app) :detail) :id) "1"))))

;;; ---------------------------------------------------------------------------
;;; Book detail and highlights
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-show-book-loads-detail-and-chapters ()
  "Showing a book publishes its detail, chapters and counts from the cache."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-show-book app "7")
    (let ((detail (plist-get (etaf-weread-state app) :detail)))
      (should (equal (plist-get detail :id) "7"))
      (should (equal (plist-get detail :category) "文学"))
      (should (= (length (plist-get detail :chapters)) 2))
      (should (= (plist-get detail :progress) 36)))
    (should (= (etaf-weread-tests--request-count :book) 1))
    (etaf-weread-show-book app "7")
    (should (= (etaf-weread-tests--request-count :book) 1))))

(ert-deftest etaf-weread-tests-notes-group-and-attach-thoughts ()
  "Highlights group by chapter; a thought attaches and orphans collect apart."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-show-book app "2" 'notes)
    (let* ((notes (plist-get (etaf-weread-state app) :notes))
           (groups (plist-get notes :groups)))
      (should (= (plist-get notes :highlights) 1))
      (should (= (plist-get notes :thoughts) 2))
      (should (equal (plist-get (car groups) :chapter) "第一章"))
      (should (equal (plist-get (car (plist-get (car groups) :items)) :thought)
                     "想法内容"))
      (should (equal (plist-get (car (last groups)) :chapter) "其他想法"))
      (should (equal (plist-get (car (plist-get (car (last groups)) :items)) :text)
                     "")))))

(ert-deftest etaf-weread-tests-panes-toggle-and-load-notes ()
  "The side pane switches between detail and highlights and back."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-show-book app "2")
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))
    (etaf-weread-toggle-pane app)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'notes))
    (should (plist-get (etaf-weread-state app) :notes))
    (etaf-weread-toggle-pane app)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))
    (should-error (etaf-weread-show-pane app 'sideways) :type 'etaf-weread-error)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))))

(ert-deftest etaf-weread-tests-press-row-selects-then-opens ()
  "A press selects another row; pressing the selected row opens it."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-refresh app)
    (etaf-weread-press-row app 2)
    (should (= (plist-get (etaf-weread-state app) :selection) 1))
    (should-not (etaf-weread-tests--request :book))
    (etaf-weread-press-row app 2)
    (should (equal (plist-get (plist-get (etaf-weread-state app) :detail) :id) "2"))
    (should-error (etaf-weread-press-row app 99) :type 'etaf-weread-error)))

(ert-deftest etaf-weread-tests-reader-url-and-open-book ()
  "Reader URLs prefer the backend deep link and open through `browse-url'."
  (should (equal (etaf-weread-reader-url
                  '(:id "123" :deep-link "https://weread.qq.com/book-detail?x=1"))
                 "https://weread.qq.com/book-detail?x=1"))
  (should (equal (etaf-weread-reader-url "123")
                 "https://weread.qq.com/web/reader/123"))
  (should-not (etaf-weread-reader-url nil))
  (setq etaf-weread-tests--requests nil)
  (let* ((app (etaf-weread-tests--session))
         (opened nil))
    (etaf-weread-refresh app)
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url &rest _arguments) (setq opened url))))
      (etaf-weread-open-book app))
    (should (equal opened "https://weread.qq.com/web/reader/1"))))

(ert-deftest etaf-weread-tests-export-notes-sends-the-export-request ()
  "Exporting the selected book sends the backend export and reports its reply."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-refresh app)
    (etaf-weread-export-notes app)
    (should (equal (plist-get (etaf-weread-tests--request :export) :id) "1"))
    (should (equal (plist-get (etaf-weread-state app) :message) "已导出笔记"))))

;;; ---------------------------------------------------------------------------
;;; Local SQLite index
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-index-stores-and-searches-highlights ()
  "Reading highlights stores them in SQLite and the index section finds them."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    (let ((app (etaf-weread-tests--session)))
      (etaf-weread-show-book app "1" 'notes)
      (should (file-exists-p etaf-weread-index-file))
      (should (= (etaf-weread-index-search app "划线") 1))
      (should (equal (plist-get (etaf-weread-state app) :section) :index))
      (let ((row (car (plist-get (etaf-weread-state app) :items))))
        (should (eq (plist-get row :kind) :highlight))
        (should (equal (plist-get row :title) "详情节1")))
      ;; A non-matching keyword filters the index down to nothing.
      (should (= (etaf-weread-index-search app "不存在的词") 0))
      (should (= (etaf-weread-index-search app "") 1)))))

(ert-deftest etaf-weread-tests-index-notebook-walks-and-skips-indexed ()
  "The notebook walk fetches unindexed books once and skips them afterwards."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    (let ((app (etaf-weread-tests--session)))
      (etaf-weread-index-notebook app)
      (should (= (etaf-weread-tests--request-count :notes) 2))
      (should (string-match-p "索引完成：写入 3 条"
                              (or (plist-get (etaf-weread-state app) :message) "")))
      ;; Two highlights plus the orphan thought mention 划线.
      (should (= (etaf-weread-index-search app "划线") 3))
      (etaf-weread-index-notebook app)
      (should (= (etaf-weread-tests--request-count :notes) 2))
      (etaf-weread-index-notebook app t)
      (should (= (etaf-weread-tests--request-count :notes) 4))
      (should (= (etaf-weread-index-search app "划线") 3)))))

(ert-deftest etaf-weread-tests-index-upsert-updates-a-changed-thought ()
  "Re-indexing a changed thought updates the stored row instead of adding one."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    ;; Bind the thought so the edit below does not leak into later tests.
    (let ((app (etaf-weread-tests--session))
          (etaf-weread-tests--thought "原来的想法"))
      (etaf-weread-show-book app "1" 'notes)
      (should (= (etaf-weread-index-search app "原来的想法") 1))
      (setq etaf-weread-tests--thought "改过的想法")
      (etaf-weread-index-notebook app t)
      ;; Every scripted highlight carries the current thought, so both books
      ;; now match it while the old text is gone.
      (should (= (etaf-weread-index-search app "改过的想法") 2))
      (should (= (etaf-weread-index-search app "原来的想法") 0))
      (should (= (etaf-weread-index-search app "") 3)))))

;;; ---------------------------------------------------------------------------
;;; Failures, theme and presentation
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-backend-failure-is-reported-not-signaled ()
  "A failing backend reply lands in the status line while the reader stays usable."
  (setq etaf-weread-tests--requests nil
        etaf-weread-tests--error "登录态失效")
  (unwind-protect
      (let ((app (etaf-weread-tests--session)))
        (etaf-weread-refresh app)
        (should (equal (plist-get (etaf-weread-state app) :error) "登录态失效"))
        (should (string-match-p "登录态失效" (plist-get (etaf-weread-state app) :message)))
        (etaf-weread-locate app :notebook)
        (should (= (plist-get (etaf-weread-state app) :rows-total) 0)))
    (setq etaf-weread-tests--error nil)))

(ert-deftest etaf-weread-tests-missing-backend-script-is-reported ()
  "A client whose backend script is missing reports an error instead of signaling."
  (let* ((directory (make-temp-file "etaf-weread-missing-" t))
         (app (etaf-weread-create
               :client (etaf-weread-make-client :backend-directory directory))))
    (unwind-protect
        (progn
          (etaf-weread-refresh app)
          (should (string-match-p "weread backend script is missing"
                                  (plist-get (etaf-weread-state app) :message))))
      (delete-directory directory t))))

(ert-deftest etaf-weread-tests-theme-tokens-cover-both-palettes ()
  "Colours resolve per palette, and the UI defaults follow the mode."
  (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'"
                          (etaf-weread-color :accent 'dark)))
  (should-error (etaf-weread-color :nonsense) :type 'etaf-weread-error)
  (dolist (key '(:bg :panel :panel2 :panel3 :line :ink :muted :dim
                 :accent :accent-soft :gold :ok :warn :danger :danger-bg
                 :info :selected :meter :cover :quote))
    (dolist (mode '(dark light sepia))
      (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'"
                              (etaf-weread-color key mode)))))
  (let ((dark (etaf-weread-color :bg 'dark))
        (defaults (etaf-weread-theme-defaults 'dark)))
    (should (equal (plist-get defaults :ui-bg) dark))
    (should (plist-get defaults :ui-accent))
    (should-not (equal dark (etaf-weread-color :bg 'light)))
    (should-not (equal (etaf-weread-theme-defaults 'sepia)
                       (etaf-weread-theme-defaults 'light)))))

(ert-deftest etaf-weread-tests-format-duration-and-progress-bar ()
  "Reading time and the text progress bar keep their documented shapes."
  (should (equal (etaf-weread-format-duration 4384) "1小时13分"))
  (should (equal (etaf-weread-format-duration 600) "10分"))
  (should (equal (etaf-weread-format-duration 0) ""))
  (should (equal (etaf-weread-progress-bar 0 4) "░░░░"))
  (should (equal (etaf-weread-progress-bar 100 4) "████"))
  (should (equal (etaf-weread-progress-bar 50 4) "██░░")))

;;; ---------------------------------------------------------------------------
;;; Mounting and default client
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-mount-renders-and-revives ()
  "Mounting paints the shelf and killing the buffer lets the session mount again."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session))
        (buffer (get-buffer-create " *etaf-weread-tests-mount*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "书1" text))
              (should (string-match-p "全部书架" text))))
          ;; The highlight pane renders a keyed list too; mount it so duplicate
          ;; or invalid keys fail here instead of in a live frame.
          (etaf-weread-show-book app "1" 'notes)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "详情节1" text))
              (should (string-match-p "划线" text))))
          ;; The shared Progress, Tabs, Statistic and Empty controls must render
          ;; in the panes that compose them.
          (etaf-weread-show-book app "1" 'detail)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "已读" text))
              (should (string-match-p "目录 2" text))))
          (etaf-weread-locate app :stats)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "阅读统计" text))
              (should (string-match-p "读完" text))))
          (kill-buffer buffer)
          (let ((again (get-buffer-create " *etaf-weread-tests-mount*")))
            (etaf-mount again (etaf-weread-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (with-current-buffer again
              (should (string-match-p "书1"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))))
      (when (get-buffer " *etaf-weread-tests-mount*")
        (kill-buffer " *etaf-weread-tests-mount*")))))

(ert-deftest etaf-weread-tests-cached-list-refreshes-without-a-loading-state ()
  "A cached list is compared in the background and replaced only when it changed.
The first visit loads in the foreground; the next visit paints the cache at
once and refreshes it without a loading state, so the sidebar never flickers;
a changed reply then replaces the rows."
  (setq etaf-weread-tests--requests nil)
  (let* ((app nil)
         (loading-at-request 'unseen)
         (client (lambda (request callback)
                   (when (equal (plist-get request :op) :shelf)
                     (setq loading-at-request
                           (plist-get (etaf-weread-state app) :loading)))
                   (etaf-weread-tests--client request callback))))
    (setq app (etaf-weread-tests--session client))
    ;; First visit: a foreground load, with its loading state.
    (etaf-weread-locate app :shelf)
    (should (eq loading-at-request t))
    (should (= 2 (length (plist-get (etaf-weread-state app) :items))))
    ;; Next visit: cache first, background compare, no loading state.
    (setq etaf-weread-tests--requests nil
          loading-at-request 'unseen)
    (etaf-weread-locate app :reading)
    (etaf-weread-locate app :shelf)
    (should (eq loading-at-request nil))
    (should (= 2 (length (plist-get (etaf-weread-state app) :items))))
    ;; A changed reply replaces the cached rows.
    (setq etaf-weread-tests--book-count 3)
    (unwind-protect
        (progn
          (etaf-weread-locate app :reading)
          (etaf-weread-locate app :shelf)
          (should (= 3 (length (plist-get (etaf-weread-state app) :items)))))
      (setq etaf-weread-tests--book-count 2))
    ;; Re-opening the section that is already shown keeps the reader's place.
    (etaf-weread-move-selection app 1)
    (etaf-weread-locate app :shelf)
    (should (= 1 (plist-get (etaf-weread-state app) :selection)))))

(ert-deftest etaf-weread-tests-prefetch-warms-lists-and-stops-on-close ()
  "A mounted reader warms unopened lists in the background and stops on close.
The timer loads a list that was never opened, so opening it later shows cached
rows and refreshes them without a loading state; killing the buffer cancels
the timer."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-prefetch-interval 0.05)
         ;; 预热的是「还没缓存」的列表；把过期阈值放长，避免过期刷新把预热挤出循环。
         (etaf-weread-library-refresh-interval 3600)
         (app nil)
         (loading-at-request nil)
         (client (lambda (request callback)
                   (push (cons (plist-get request :op)
                               (plist-get (etaf-weread-state app) :loading))
                         loading-at-request)
                   (etaf-weread-tests--client request callback)))
         (buffer (get-buffer-create " *etaf-weread-tests-prefetch*")))
    (setq app (etaf-weread-tests--session client))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          ;; A mounted reader only warms lists while a window shows it.
          (set-window-buffer (selected-window) buffer)
          (etaf-weread-locate app :shelf)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :notebook) 0))))
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :stats) 0))))
          ;; A warmed section opens from its cache, without a loading state.
          (setq loading-at-request nil)
          (etaf-weread-locate app :notebook)
          (should (eq (cdr (assq :notebook loading-at-request)) nil))
          (should (etaf-weread-tests--wait
                   (lambda () (plist-get (etaf-weread-state app) :items))))
          (kill-buffer buffer)
          (setq etaf-weread-tests--requests nil)
          (accept-process-output nil 0.3)
          (should (= 0 (etaf-weread-tests--request-count :shelf))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-weread-tests-prefetch-pauses-while-hidden ()
  "A reader no window shows pauses its background refreshes until shown again."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-prefetch-interval 0.05)
         (etaf-weread-library-refresh-interval 0.05)
         (app (etaf-weread-tests--session)))
    (unwind-protect
        (let* ((buffer (etaf-weread-open app))
               (other (get-buffer-create " *etaf-weread-tests-other*")))
          (etaf-weread-locate app :shelf)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :shelf) 3))))
          ;; 藏起来：预热停下（等一拍再清账，避免把在途请求算进隐藏期）。
          (set-window-buffer (get-buffer-window buffer t) other)
          (accept-process-output nil 0.2)
          (setq etaf-weread-tests--requests nil)
          (accept-process-output nil 0.5)
          (should (= 0 (etaf-weread-tests--request-count :shelf)))
          ;; 重新显示：预热恢复。
          (set-window-buffer (get-buffer-window other t) buffer)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :shelf) 0)))))
      (etaf-weread-close))))

(ert-deftest etaf-weread-tests-auth-failure-pauses-refreshes ()
  "A refresh that fails because the login expired pauses the warmer for good.
A successful foreground load clears the pause, so signing in again resumes it."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-prefetch-interval 0.05)
         ;; 让已缓存的列表保持新鲜，预热就会去补还没缓存的节（含 :notebook）。
         (etaf-weread-library-refresh-interval 3600)
         (fail-auth t)
         (app nil)
         (client (lambda (request callback)
                   ;; 失败分支自己记账：脚本客户端只会记成功的请求。
                   (if (and fail-auth (eq (plist-get request :op) :notebook))
                       (progn
                         (push request etaf-weread-tests--requests)
                         (funcall callback
                                  (list :error "微信读书接口错误（登录超时）"
                                        :hint "M-x etaf-weread-open 登录"
                                        :code "auth")))
                     (etaf-weread-tests--client request callback)))))
    (setq app (etaf-weread-tests--session client))
    (unwind-protect
        (progn
          (etaf-weread-open app)
          (etaf-weread-locate app :shelf)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :notebook) 0))))
          ;; 暂停后不再有任何后台刷新（用快照比较，不清理账目）。
          (accept-process-output nil 0.2)
          (let ((shelf-before (etaf-weread-tests--request-count :shelf))
                (notebook-before (etaf-weread-tests--request-count :notebook)))
            (accept-process-output nil 0.5)
            (should (= shelf-before (etaf-weread-tests--request-count :shelf)))
            (should (= notebook-before (etaf-weread-tests--request-count :notebook))))
          ;; 前台加载成功解除暂停：预热恢复去补未缓存的节。
          (let ((notebook-before (etaf-weread-tests--request-count :notebook)))
            (setq fail-auth nil)
            (etaf-weread-locate app :shelf)
            (should (etaf-weread-tests--wait
                     (lambda ()
                       (> (etaf-weread-tests--request-count :notebook)
                          notebook-before))))))
      (etaf-weread-close))))

(ert-deftest etaf-weread-tests-status-hints-fit-their-layout ()
  "Each layout paints its binding hint whole instead of clipping it.
The wide status bar and the compact tab row choose a hint that fits the
columns they are painted in, so no layout cuts the summary off."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-hints*")
        (app (etaf-weread-tests--session))
        (headless (get-buffer-create " *etaf-weread-tests-hints-wide*"))
        (narrow nil))
    (unwind-protect
        (progn
          ;; Headless (wide): the status bar carries the whole summary.
          (etaf-mount headless (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (with-current-buffer headless
            (should (string-match-p
                     (regexp-quote "g 刷新 · v 笔记 · o 浏览器 · E 导出 · T 深浅色 · ? 帮助")
                     (buffer-substring-no-properties (point-min) (point-max)))))
          (kill-buffer headless)
          ;; A medium frame (the batch window is 80 columns): the compact tab
          ;; row still fits the whole summary next to the switch.
          (let ((buffer (etaf-weread-open app)))
            (etaf-weread-refresh app)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (should (string-match-p
                       (regexp-quote "↑/↓ 选择 · RET 打开 · v 切换面板")
                       (buffer-substring-no-properties (point-min) (point-max)))))
            ;; A narrow frame: only the short hint fits.
            (setq narrow (split-window (selected-window) 25 'right))
            (set-window-buffer (selected-window)
                               (get-buffer-create " *etaf-weread-tests-other*"))
            (set-window-buffer narrow buffer)
            (select-window narrow)
            (etaf-weread-refresh app)
            (etaf-runtime-refit (etaf-runtime-for-buffer buffer) 371 24)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p (regexp-quote "? 帮助") text))
                (should-not (string-match-p
                             (regexp-quote "↑/↓ 选择 · RET 打开 · v 切换面板")
                             text))))))
      (when (and narrow (window-live-p narrow)
                 (not (eq narrow (selected-window))))
        (delete-window narrow))
      (when (get-buffer " *etaf-weread-tests-hints*")
        (kill-buffer " *etaf-weread-tests-hints*"))
      (when (buffer-live-p headless) (kill-buffer headless))
      (when (get-buffer " *etaf-weread-tests-other*")
        (kill-buffer " *etaf-weread-tests-other*")))))

(ert-deftest etaf-weread-tests-section-switches-return-to-the-list-on-compact ()
  "A section switch shows the list pane again on a compact frame.
A compact frame shows one pane at a time, so browsing another section must
not leave the reader on the side pane it was showing; a wide frame keeps
its pane choice."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-compact*")
        (app (etaf-weread-tests--session))
        (headless (get-buffer-create " *etaf-weread-tests-compact-wide*"))
        (narrow nil))
    (unwind-protect
        (progn
          ;; Headless (wide): a section switch keeps the pane.
          (etaf-mount headless (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (etaf-weread-show-book app "1" 'notes)
          (etaf-weread-locate app :notebook)
          (should (eq 'notes (plist-get (etaf-weread-state app) :pane)))
          (kill-buffer headless)
          ;; Compact: the same switch brings the list back into view.
          (let ((buffer (etaf-weread-open app)))
            (setq narrow (split-window (selected-window) 25 'right))
            (set-window-buffer (selected-window)
                               (get-buffer-create " *etaf-weread-tests-other*"))
            (set-window-buffer narrow buffer)
            (select-window narrow)
            (etaf-weread-refresh app)
            (etaf-weread-show-book app "1" 'notes)
            (should (eq 'notes (plist-get (etaf-weread-state app) :pane)))
            (etaf-weread-locate app :notebook)
            (should (eq 'list (plist-get (etaf-weread-state app) :pane)))))
      (when (and narrow (window-live-p narrow)
                 (not (eq narrow (selected-window))))
        (delete-window narrow))
      (when (get-buffer " *etaf-weread-tests-compact*")
        (kill-buffer " *etaf-weread-tests-compact*"))
      (when (get-buffer " *etaf-weread-tests-other*")
        (kill-buffer " *etaf-weread-tests-other*"))
      (when (buffer-live-p headless) (kill-buffer headless)))))

(ert-deftest etaf-weread-tests-ret-opens-the-selection ()
  "Pressing RET after moving the selection opens the selected book.
The renderer only activates a Host under point, and the arrows leave point
where it was, so the reader falls back to the selection the manual promises."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-ret*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (with-current-buffer buffer
            (execute-kbd-macro (kbd "<down>"))
            (should (= 1 (plist-get (etaf-weread-state app) :selection)))
            (execute-kbd-macro (kbd "RET"))
            (should (eq 'detail (plist-get (etaf-weread-state app) :pane)))
            (should (equal "2" (plist-get (plist-get (etaf-weread-state app) :detail)
                                           :id)))))
      (when (get-buffer " *etaf-weread-tests-ret*")
        (kill-buffer " *etaf-weread-tests-ret*")))))

(ert-deftest etaf-weread-tests-pane-keys-scroll-the-pane ()
  "SPC and M-v scroll a long detail pane from the keyboard.
The wheel scrolls the pane under the pointer; without keys a keyboard-only
reader cannot move a long table of contents at all."
  (setq etaf-weread-tests--requests nil
        etaf-weread-tests--extra-chapters
        (cl-loop for index from 3 to 24
                 collect (list :chapterIdx index
                               :title (format "第%d章" index)
                               :wordCount 100)))
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-scroll*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (etaf-weread-show-book app "1" 'detail)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (should (= 0 (plist-get (etaf-weread-state app) :pane-scroll)))
            (execute-kbd-macro (kbd "SPC"))
            (should (> (plist-get (etaf-weread-state app) :pane-scroll) 0))
            (execute-kbd-macro (kbd "M-v"))
            (should (= 0 (plist-get (etaf-weread-state app) :pane-scroll)))))
      (setq etaf-weread-tests--extra-chapters nil)
      (when (get-buffer " *etaf-weread-tests-scroll*")
        (kill-buffer " *etaf-weread-tests-scroll*")))))

(ert-deftest etaf-weread-tests-replaced-keys-run-the-reader-command ()
  "The keys the renderer also binds run the reader command, not its scroll.
`n', `q' and the page keys are scroll or window bindings in the renderer's
minor-mode map, which shadows a major-mode map unless the reader overrides
them."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-keys*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (with-current-buffer buffer
            (execute-kbd-macro (kbd "n"))
            (should (eq :notebook (plist-get (etaf-weread-state app) :section)))
            (execute-kbd-macro (kbd "<next>"))
            (should (> (plist-get (etaf-weread-state app) :selection) 0))
            (execute-kbd-macro (kbd "<prior>"))
            (should (= 0 (plist-get (etaf-weread-state app) :selection)))
            (execute-kbd-macro "q")
            (should-not (buffer-live-p buffer))))
      (when (get-buffer " *etaf-weread-tests-keys*")
        (kill-buffer " *etaf-weread-tests-keys*")))))

(ert-deftest etaf-weread-tests-open-fills-the-selected-window ()
  "Opening the reader replaces the selected window instead of splitting it.
A native text app owns the whole window it was opened from; a general
display rule must not turn it into a playground-style pane."
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-window*")
        (app (etaf-weread-tests--session))
        (frame (selected-frame))
        (width (frame-width))
        (height (frame-height)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (set-frame-size frame 120 40)
          (let ((windows (length (window-list)))
                (selected (selected-window)))
            (unwind-protect
                (progn
                  (etaf-weread-open app)
                  (should (= (length (window-list)) windows))
                  (should (eq (selected-window) selected))
                  (should (eq (window-buffer selected)
                              (get-buffer etaf-weread-buffer-name))))
              (etaf-weread-close))))
      (set-frame-size frame width height)
      (when (get-buffer etaf-weread-buffer-name)
        (kill-buffer etaf-weread-buffer-name)))))

(ert-deftest etaf-weread-tests-open-and-close-own-a-buffer ()
  "Opening paints a reader canvas whose keys beat renderer scrolling."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-open*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (should (buffer-live-p buffer))
          (with-current-buffer buffer
            (should-not mode-line-format)
            (should (equal (plist-get (car (last (alist-get 'default face-remapping-alist)))
                                      :background)
                           (etaf-weread-color :bg)))
            (should (string-match-p "书1"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            (let ((pane (plist-get (etaf-weread-state app) :pane)))
              (execute-kbd-macro (kbd "v"))
              (should-not (eq (plist-get (etaf-weread-state app) :pane) pane)))
            (execute-kbd-macro (kbd "q")))
          (should-not (get-buffer etaf-weread-buffer-name)))
      (when (get-buffer etaf-weread-buffer-name)
        (kill-buffer etaf-weread-buffer-name)))))

(ert-deftest etaf-weread-tests-default-client-runs-the-backend-script ()
  "The default client passes the documented arguments to the bundled backend."
  (let* ((directory (make-temp-file "etaf-weread-backend-" t))
         (script (expand-file-name "weread.mjs" directory))
         (log (expand-file-name "calls.log" directory))
         (out (expand-file-name "export" directory))
         (reply nil))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "import fs from 'node:fs';\n"
                    "fs.appendFileSync(process.env.WEREAD_TEST_LOG, process.argv.slice(2).join(' ') + '\\n');\n"
                    "console.log(JSON.stringify({ok: true}));\n"))
          (let* ((process-environment
                  (cons (concat "WEREAD_TEST_LOG=" log) process-environment))
                 (etaf-weread-export-directory out)
                 (client (etaf-weread-make-client :backend-directory directory :timeout 10)))
            (etaf-weread-client-call
             client (list :op :shelf :filter "reading" :limit 20)
             (lambda (result) (setq reply result)))
            (should (etaf-weread-tests--wait (lambda () reply)))
            (should (eq (car-safe reply) :ok))
            (setq reply nil)
            (etaf-weread-client-call
             client (list :op :export :id "42")
             (lambda (result) (setq reply result)))
            (should (etaf-weread-tests--wait (lambda () reply)))
            (should (eq (car-safe reply) :ok))
            (dolist (op '(:login :logout))
              (setq reply nil)
              (etaf-weread-client-call
               client (list :op op)
               (lambda (result) (setq reply result)))
              (should (etaf-weread-tests--wait (lambda () reply)))
              (should (eq (car-safe reply) :ok)))
            (with-temp-buffer
              (insert-file-contents log)
              (let ((lines (split-string (buffer-string) "\n" t)))
                (should (equal (nth 0 lines)
                               "shelf --filter reading --limit 20 --json --quiet"))
                (should (equal (nth 1 lines)
                               (format "export 42 --yes --json --quiet --out %s" out)))
                (should (equal (nth 2 lines) "login --json --quiet"))
                (should (equal (nth 3 lines) "logout --json --quiet"))))))
      (delete-directory directory t))))

(ert-deftest etaf-weread-tests-backend-refusal-reports-its-own-message ()
  "A refused backend command reports its own message.
The bundled backend answers a failure with a JSON object on stdout and a non-zero
exit, and the exit event can arrive before that output; the reader must drain
the pipes before reading them.  A crash without JSON keeps the exit status."
  (let* ((directory (make-temp-file "etaf-weread-refusal-backend-" t))
         (script (expand-file-name "weread.mjs" directory)))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "if (process.argv[2] === 'shelf') {\n"
                    "  console.log(JSON.stringify({ ok: false, error: 'auth', message: '还没有微信读书登录态', hint: 'M-x etaf-weread-login 扫码登录' }));\n"
                    "  process.exit(3);\n"
                    "}\n"
                    "console.error('boom');\n"
                    "process.exit(1);\n"))
          (let* ((client (etaf-weread-make-client :backend-directory directory :timeout 10))
                 (ask (lambda (request)
                        (let (reply)
                          (etaf-weread-client-call
                           client request (lambda (result) (setq reply result)))
                          (should (etaf-weread-tests--wait (lambda () reply)))
                          reply))))
            (let ((refusal (funcall ask (list :op :shelf :filter "reading" :limit 20))))
              (should (eq (car-safe refusal) :error))
              (should (equal (cadr refusal) "还没有微信读书登录态"))
              (should (equal (plist-get (cddr refusal) :code) "auth"))
              (should (equal (plist-get (cddr refusal) :hint)
                             "M-x etaf-weread-login 扫码登录")))
            (let ((crash (funcall ask (list :op :status))))
              (should (eq (car-safe crash) :error))
              (should (string-prefix-p "Backend command failed" (cadr crash)))
              (should (equal (plist-get (cddr crash) :hint) "boom")))))
      (delete-directory directory t))))

(ert-deftest etaf-weread-tests-backend-timeout-and-cancel ()
  "A slow backend times out with its command as hint; a cancelled call never replies."
  (let* ((directory (make-temp-file "etaf-weread-slow-backend-" t))
         (script (expand-file-name "weread.mjs" directory)))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "setTimeout(() => console.log('{}'), 5000);\n"))
          (let ((client (etaf-weread-make-client :backend-directory directory
                                                 :timeout 0.3))
                reply)
            (etaf-weread-client-call client (list :op :status)
                                     (lambda (result) (setq reply result)))
            (should (etaf-weread-tests--wait (lambda () reply)))
            (should (equal (cadr reply) "Backend request timed out after 0.3s"))
            (should (string-match-p "weread\\.mjs status" (plist-get (cddr reply) :hint)))
            (setq reply nil)
            (etaf-weread-client-call client (list :op :status)
                                     (lambda (result) (setq reply result)))
            (should (= (etaf-weread-cancel client) 1))
            (should (= (etaf-weread-cancel client) 0))
            (sleep-for 0.5)
            (should-not reply)))
      (delete-directory directory t))))

(ert-deftest etaf-weread-tests-help-stays-in-reader ()
  "Both help entries show effective keys without leaving or changing the reader."
  (save-window-excursion
    (let* ((etaf-weread-buffer-name " *Weread help acceptance*")
           (model (etaf-weread-tests--session))
           (buffer (etaf-weread-open model))
           (runtime (etaf-runtime-for-buffer buffer)))
      (unwind-protect
          (with-current-buffer buffer
            (etaf-focus-next runtime)
            (let ((focus (etaf-focused-host-ref runtime))
                  (windows (window-list))
                  (section (plist-get (etaf-weread-state model) :section)))
              (dolist (key '("?" "C-c h"))
                (execute-kbd-macro (kbd key))
                (let* ((data (etaf-help-data runtime))
                       (entries (apply #'append
                                       (mapcar (lambda (group) (plist-get group :entries))
                                               (plist-get data :groups))))
                       (export (cl-find "E" entries :test #'equal
                                        :key (lambda (entry) (plist-get entry :key))))
                       (up (cl-find "M-v" entries :test #'equal
                                    :key (lambda (entry) (plist-get entry :key))))
                       (same-runtime (eq runtime (etaf-runtime-for-buffer buffer))))
                  (should same-runtime)
                  (should (eq (window-buffer) buffer))
                  (should (equal windows (window-list)))
                  (should (equal (plist-get data :title) "微信读书"))
                  (should (equal (plist-get export :label) "导出笔记"))
                  (should (equal (plist-get up :label) "面板上一页"))
                  (should (plist-get data :notes)))
                (execute-kbd-macro (kbd "/"))
                (execute-kbd-macro "?")
                (let ((editing (etaf-text-input-active-p runtime)))
                  (should editing))
                (execute-kbd-macro (kbd "<escape>"))
                (let ((editing (etaf-text-input-active-p runtime)))
                  (should-not editing))
                (should (string-match-p "快捷键 · 只读"
                                        (buffer-substring-no-properties (point-min) (point-max))))
                (execute-kbd-macro (kbd "<escape>"))
                (let ((restored (equal focus (etaf-focused-host-ref runtime)))
                      (after (plist-get (etaf-weread-state model) :section)))
                  (should restored)
                  (should (equal section after)))))
            (execute-kbd-macro (kbd "?"))
            (let* ((map (get-text-property (point-min) 'keymap))
                   (command (lookup-key map [mouse-1]))
                   (last-input-event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
              (call-interactively command))
            (let ((closed (etaf-help-close runtime)))
              (should-not closed)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-weread-close)))))))

(ert-deftest etaf-weread-tests-keys-belong-to-the-root-host ()
  "The reader's keys travel with its View, so a foreign host keeps them.
A panel mounts the same View without `etaf-app-open'; the root Host's keys and
the session the mount records are what make its commands act on the mounted
reader instead of signalling that the buffer is not one."
  (let ((session (etaf-weread-tests--session))
        (buffer (generate-new-buffer " *etaf-weread-tests-keys*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-weread-view session))
          (with-current-buffer buffer
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should (commandp (key-binding (kbd "T"))))
            (should (eq session (etaf-weread-session)))
            (should (eq session (etaf-weread-session buffer)))))
      (when-let* ((runtime (and (buffer-live-p buffer)
                                (etaf-runtime-for-buffer buffer))))
        (ignore-errors (etaf-unmount runtime)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defvar etaf-weread-tests--surface-model nil
  "Reader session mounted by the surface host during a case.")

(etaf-define-component etaf-weread-tests-surface-host (&key surface appearance)
  "Provide SURFACE and APPEARANCE to the reader mounted below."
  :setup (progn
           (etaf-surface-provide surface)
           (when appearance (etaf-appearance-provide appearance)))
  :view (expr (etaf-weread-view etaf-weread-tests--surface-model)))

(ert-deftest etaf-weread-tests-declares-its-palette-to-a-host ()
  "A panel frames the reader with the reader's palette and the standard switch.
The title bar offers the same `亮'/`随'/`暗' as every other panel, `随' follows
the appearance its host provides, and the reader's own `T' still reaches `纸'."
  (let ((surface (etaf-surface-create))
        (appearance (etaf-ref 'dark))
        (buffer (generate-new-buffer " *etaf-weread-tests-surface*")))
    (let ((etaf-weread-tests--surface-model (etaf-weread-tests--session)))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (etaf-weread-tests-surface-host
                                    :surface surface :appearance appearance))
                        (list :viewport-width 1200 :viewport-height 40))
            (should (equal '((light . "亮") (auto . "随") (dark . "暗"))
                           (etaf-surface-modes surface)))
            (should (equal (etaf-weread-theme-defaults
                            (etaf-value (etaf-surface-mode surface)))
                           (etaf-value (etaf-surface-theme surface))))
            ;; `随' follows the appearance the host provides.
            (etaf-set-value (etaf-surface-mode surface) 'auto)
            (etaf-set-value appearance 'light)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should (equal (etaf-weread-theme-defaults 'light)
                           (etaf-value (etaf-surface-theme surface))))
            ;; The reader's own key keeps cycling, and reaches `纸', which the
            ;; three-mode switch cannot show.  From `auto' it pins a palette.
            (should (eq 'light (etaf-weread-cycle-theme
                                etaf-weread-tests--surface-model)))
            (should (eq 'sepia (etaf-weread-cycle-theme
                                etaf-weread-tests--surface-model)))
            (should (eq 'sepia (etaf-value (etaf-surface-mode surface))))
            (should (equal (etaf-weread-theme-defaults 'sepia)
                           (etaf-value (etaf-surface-theme surface))))
            (should (eq 'dark (etaf-weread-cycle-theme
                               etaf-weread-tests--surface-model))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'etaf-weread-tests)
;;; etaf-weread-tests.el ends here
