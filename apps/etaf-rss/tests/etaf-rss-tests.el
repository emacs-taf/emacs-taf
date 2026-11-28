;;; etaf-rss-tests.el --- Acceptance tests for etaf-rss -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public behaviour tests.  Every scenario drives the reader through the
;; interfaces declared in `etaf-rss.el' with the real service client reading
;; the fixtures over file:// URLs, so no test needs the network, while the
;; whole stack (store, fetch, parse, merge, scopes, reading pane) is
;; exercised.  Feed replies arrive asynchronously, so a scenario that depends
;; on one waits for the state it expects.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-rss)

(defvar etaf-rss-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file, resolved while it is loaded.")

(defun etaf-rss-tests--fixture (name)
  "Return the file:// URL of fixture NAME."
  (concat "file://" (expand-file-name name
                                      (expand-file-name "fixtures"
                                                        etaf-rss-tests--directory))))

(defun etaf-rss-tests--wait (predicate &optional timeout)
  "Wait until PREDICATE is non-nil for at most TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (sleep-for 0.01))
    (funcall predicate)))

(defun etaf-rss-tests--session ()
  "Return (SESSION . FILE) over a disposable data file."
  (let ((file (make-temp-file "etaf-rss-tests-" nil ".json")))
    (delete-file file)
    (cons (etaf-rss-create :client (etaf-rss-make-client :data-file file))
          file)))

(defun etaf-rss-tests--rows (session)
  "Return SESSION's loaded rows as a list."
  (append (plist-get (etaf-rss-state session) :rows) nil))

(defun etaf-rss-tests--subscribe (session file)
  "Subscribe SESSION to fixture FILE and wait until its rows arrive."
  (etaf-rss-add-feed session (etaf-rss-tests--fixture file))
  (etaf-rss-tests--wait (lambda () (> (length (etaf-rss-tests--rows session)) 0)))
  (etaf-rss-state session))

(defmacro etaf-rss-tests--with-session (binding &rest body)
  "Run BODY with BINDING bound to (SESSION . FILE), then clean up."
  (declare (indent 1) (debug t))
  `(let ((,binding (etaf-rss-tests--session)))
     (unwind-protect
         (progn ,@body)
       (etaf-rss-cancel (car ,binding))
       (ignore-errors (delete-file (cdr ,binding))))))

;;; ---------------------------------------------------------------------------
;;; Parsing and text
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-rss-tests-parses-rss-atom-and-json ()
  "RSS, Atom and JSON Feed documents become the same article shape."
  (dolist (case '(("example-rss.xml" "示例科技周刊" 2)
                  ("example-atom.xml" "Atom 示例" 1)
                  ("example-feed.json" "JSON 示例" 1)))
    (pcase-let* ((`(,file ,title ,count) case)
                 (text (with-temp-buffer
                         (insert-file-contents
                          (expand-file-name file (expand-file-name
                                                  "fixtures" etaf-rss-tests--directory)))
                         (buffer-substring-no-properties (point-min) (point-max))))
                 (feed (etaf-rss-parse-feed text "https://x.example/feed")))
      (should (equal (plist-get feed :title) title))
      (should (= (length (plist-get feed :articles)) count))
      (let ((article (car (plist-get feed :articles))))
        (should (stringp (plist-get article :id)))
        (should (stringp (plist-get article :title)))
        (should (numberp (plist-get article :published)))))))

(ert-deftest etaf-rss-tests-parses-opml-and-renders-html ()
  "OPML subscriptions parse and article HTML becomes reading blocks."
  (let* ((opml (with-temp-buffer
                 (insert-file-contents
                  (expand-file-name "example.opml"
                                    (expand-file-name "fixtures"
                                                      etaf-rss-tests--directory)))
                 (buffer-substring-no-properties (point-min) (point-max))))
         (entries (etaf-rss-parse-opml opml)))
    (should (= (length entries) 2))
    (should (equal (plist-get (car entries) :folder) "技术")))
  (let* ((blocks (etaf-rss-render-html
                  "<h1>标题</h1><p>正文<a href=\"https://a.example\">链接</a></p><ul><li>点</li></ul>"))
         (lines (etaf-rss-wrap-blocks blocks 16)))
    (should (memq 'heading (mapcar (lambda (block) (plist-get block :kind)) blocks)))
    (should (memq 'item (mapcar (lambda (block) (plist-get block :kind)) blocks)))
    (should (memq 'link (mapcar (lambda (block) (plist-get block :kind)) blocks)))
    (should (> (length lines) (length blocks)))
    (should (cl-every (lambda (line) (<= (string-width (plist-get line :text)) 16))
                      lines)))
  (should (equal (etaf-rss-plain-text "<p>一段</p><p>两段</p>") "一段 两段"))
  (should (equal (etaf-rss-relative-time (- (float-time) 30)) "刚刚")))

(ert-deftest etaf-rss-tests-wraps-prose-at-spaces ()
  "Prose with spaces wraps at the last space instead of signalling."
  (let* ((text "Article URL: https://example.com/a-very-long-link-without-spaces")
         (lines (etaf-rss-wrap-blocks (list (list :kind 'para :text text)) 24)))
    (should (> (length lines) 1))
    (should (equal (plist-get (car lines) :text) "Article URL:"))
    (should (cl-every (lambda (line) (<= (string-width (plist-get line :text)) 24))
                      lines))
    (should (equal (replace-regexp-in-string
                    " " "" (mapconcat (lambda (line) (plist-get line :text)) lines ""))
                   (replace-regexp-in-string " " "" text)))))

;;; ---------------------------------------------------------------------------
;;; Session, subscription and scopes
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-rss-tests-new-session-is-headless ()
  "A session built without a buffer keeps its defaults and loads nothing."
  (etaf-rss-tests--with-session session
    (let ((state (etaf-rss-state (car session))))
      (should (equal (plist-get state :scope) (list :kind :all)))
      (should (eq (plist-get state :layout) 'wide))
      (should (eq (plist-get state :pane) 'list))
      (should (= (plist-get state :rows-total) 0))
      (should (= (plist-get state :total) 0))
      (should-not (plist-get state :reader-id)))))

(ert-deftest etaf-rss-tests-subscribe-lists-articles ()
  "Subscribing to a feed stores it and lists its articles newest first."
  (etaf-rss-tests--with-session session
    (let ((state (etaf-rss-tests--subscribe (car session) "example-rss.xml")))
      (should (= (plist-get state :total) 2))
      (should (= (plist-get state :unread) 2))
      (should (= (plist-get state :list-total) 2))
      (should (= (length (plist-get state :feeds)) 1))
      (should (string-match-p "示例科技周刊"
                              (plist-get (car (plist-get state :feeds)) :title)))
      (should (seq-some (lambda (row) (string-match-p "增量" (plist-get row :title)))
                        (plist-get state :rows))))))

(ert-deftest etaf-rss-tests-add-feed-discovers-site-feed ()
  "Subscribing to a site page finds the feed it advertises."
  (etaf-rss-tests--with-session session
    (etaf-rss-add-feed (car session) (etaf-rss-tests--fixture "example-site.html"))
    (should (etaf-rss-tests--wait
             (lambda () (> (length (etaf-rss-tests--rows (car session))) 0))))
    (let ((state (etaf-rss-state (car session))))
      (should (= (length (plist-get state :feeds)) 1))
      (should (string-match-p "站点自动发现"
                              (plist-get (car (plist-get state :feeds)) :title))))))

(ert-deftest etaf-rss-tests-broken-feed-reports-error ()
  "A feed that cannot be fetched reports a readable error and leaves the reader usable."
  (etaf-rss-tests--with-session session
    (let ((result (etaf-rss-add-feed (car session) "file:///nonexistent/feed.xml")))
      (should result)
      (should (etaf-rss-tests--wait
               (lambda () (let ((state (etaf-rss-state (car session))))
                            (and (plist-get state :message)
                                 (not (plist-get state :loading)))))))
      (let ((state (etaf-rss-state (car session))))
        (should (plist-get state :error))
        (should (stringp (plist-get state :message)))
        (should (= (plist-get state :total) 0))))))

(ert-deftest etaf-rss-tests-scopes-filter-articles ()
  "The unread, starred, feed and folder scopes each filter the stored articles."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (let ((rows (etaf-rss-tests--rows (car session))))
      (etaf-rss-toggle-star (car session))
      (etaf-rss-locate (car session) :starred)
      (should (etaf-rss-tests--wait
               (lambda () (= (plist-get (etaf-rss-state (car session)) :list-total) 1))))
      (etaf-rss-toggle-read (car session))
      (etaf-rss-locate (car session) :unread)
      (should (etaf-rss-tests--wait
               (lambda () (= (plist-get (etaf-rss-state (car session)) :list-total)
                             (1- (length rows))))))
      (etaf-rss-locate (car session) (list :kind :feed :id (plist-get (car rows) :feed)))
      (should (etaf-rss-tests--wait
               (lambda () (= (plist-get (etaf-rss-state (car session)) :list-total)
                             (length rows)))))
      (should (equal (plist-get (etaf-rss-state (car session)) :scope)
                     (list :kind :feed :id (plist-get (car rows) :feed))))
      (etaf-rss-locate (car session) :all)
      (should (etaf-rss-tests--wait
               (lambda () (= (plist-get (etaf-rss-state (car session)) :list-total)
                             (length rows)))))
      (should-error (etaf-rss-locate (car session) :nope) :type 'etaf-rss-error))))

(ert-deftest etaf-rss-tests-search-finds-and-rejects-blank ()
  "Search matches titles and bodies, and a blank keyword signals."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (etaf-rss-search (car session) "增量")
    (should (etaf-rss-tests--wait
             (lambda () (= (plist-get (etaf-rss-state (car session)) :list-total) 1))))
    (let ((state (etaf-rss-state (car session))))
      (should (= (plist-get state :list-total) 1))
      (should (eq (plist-get (plist-get state :scope) :kind) :search)))
    (should-error (etaf-rss-search (car session) "  ") :type 'etaf-rss-error)))

;;; ---------------------------------------------------------------------------
;;; Selection, reading and state
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-rss-tests-selection-moves-and-pages ()
  "Selection stays inside the list and pages the window when it moves out."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (etaf-rss-move-selection (car session) 5)
    (should (= (plist-get (etaf-rss-state (car session)) :selection) 1))
    (etaf-rss-move-selection (car session) -5)
    (should (= (plist-get (etaf-rss-state (car session)) :selection) 0))
    (etaf-rss-press-row (car session) 2)
    (should (= (plist-get (etaf-rss-state (car session)) :selection) 1))
    (should-error (etaf-rss-press-row (car session) 9) :type 'etaf-rss-error)))

(ert-deftest etaf-rss-tests-read-and-star-toggle ()
  "Read and star toggles flip the visible row and the scope counts."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (should (etaf-rss-toggle-read (car session)))
    (should (eq t (plist-get (car (etaf-rss-tests--rows (car session))) :read)))
    (should (etaf-rss-tests--wait
             (lambda () (= (plist-get (etaf-rss-state (car session)) :unread) 1))))
    (should (etaf-rss-toggle-star (car session)))
    (should (eq t (plist-get (car (etaf-rss-tests--rows (car session))) :starred)))
    (should (etaf-rss-tests--wait
             (lambda () (= (plist-get (etaf-rss-state (car session)) :starred-count) 1))))
    (etaf-rss-toggle-read (car session))
    (should-not (plist-get (car (etaf-rss-tests--rows (car session))) :read))))

(ert-deftest etaf-rss-tests-reader-loads-and-scrolls ()
  "Activating an article wraps its body and scroll clamps at both ends."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (etaf-rss-activate-selection (car session))
    (should (etaf-rss-tests--wait
             (lambda () (plist-get (etaf-rss-state (car session)) :reader-lines))))
    (let ((state (etaf-rss-state (car session))))
      (should (eq (plist-get state :pane) 'reader))
      (should (equal (plist-get state :reader-id)
                     (plist-get (car (plist-get state :visible)) :id)))
      (should (> (plist-get state :reader-total) 0))
      (should (cl-every (lambda (line)
                          (<= (string-width (or (plist-get line :text) ""))
                              (plist-get state :reader-columns)))
                        (plist-get state :reader-lines))))
    (etaf-rss-scroll-reader (car session) -10)
    (should (= (plist-get (etaf-rss-state (car session)) :reader-scroll) 0))
    (etaf-rss-scroll-reader (car session) 100000)
    (let ((state (etaf-rss-state (car session))))
      (should (= (plist-get state :reader-scroll)
                 (max 0 (- (plist-get state :reader-total)
                           (plist-get state :reader-rows))))))
    (etaf-rss-show-pane (car session) 'list)
    (should (eq (plist-get (etaf-rss-state (car session)) :pane) 'list))
    (should-error (etaf-rss-show-pane (car session) 'sideways)
                  :type 'etaf-rss-error)))

(ert-deftest etaf-rss-tests-mark-read-scopes ()
  "Marking all and marking above read cover exactly the intended articles."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (etaf-rss-mark-above-read (car session))
    (should (eq t (plist-get (car (etaf-rss-tests--rows (car session))) :read)))
    (should (etaf-rss-tests--wait
             (lambda () (= (plist-get (etaf-rss-state (car session)) :unread) 1))))
    (etaf-rss-mark-all-read (car session))
    (should (etaf-rss-tests--wait
             (lambda () (= (plist-get (etaf-rss-state (car session)) :unread) 0))))
    (should (cl-every (lambda (row) (eq t (plist-get row :read)))
                      (append (plist-get (etaf-rss-state (car session)) :rows) nil)))))

(ert-deftest etaf-rss-tests-refresh-preserves-state ()
  "Refreshing an unchanged file keeps read and starred state."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (etaf-rss-toggle-read (car session))
    (etaf-rss-toggle-star (car session))
    (let ((id (plist-get (car (etaf-rss-tests--rows (car session))) :id)))
      (etaf-rss-refresh (car session))
      (should (etaf-rss-tests--wait
               (lambda () (not (plist-get (etaf-rss-state (car session)) :refreshing)))
               10))
      (let ((row (cl-find id (etaf-rss-tests--rows (car session))
                          :key (lambda (item) (plist-get item :id)) :test #'equal)))
        (should row)
        (should (eq t (plist-get row :read)))
        (should (eq t (plist-get row :starred)))))))

;;; ---------------------------------------------------------------------------
;;; Subscriptions and OPML
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-rss-tests-remove-feed-keeps-starred ()
  "Unsubscribing removes the feed but keeps its starred articles."
  (etaf-rss-tests--with-session session
    (etaf-rss-tests--subscribe (car session) "example-rss.xml")
    (etaf-rss-toggle-star (car session))
    (let ((feed (car (plist-get (etaf-rss-state (car session)) :feeds))))
      (should (equal (etaf-rss-remove-feed (car session) (plist-get feed :id))
                     (plist-get feed :title))))
    (should (etaf-rss-tests--wait
             (lambda () (zerop (length (plist-get (etaf-rss-state (car session)) :feeds))))))
    (etaf-rss-locate (car session) :starred)
    (should (etaf-rss-tests--wait
             (lambda () (= (plist-get (etaf-rss-state (car session)) :list-total) 1))))
    (should (= (plist-get (etaf-rss-state (car session)) :list-total) 1))))

(ert-deftest etaf-rss-tests-opml-round-trip ()
  "Subscriptions export to OPML and import into another session."
  (etaf-rss-tests--with-session source
    (etaf-rss-tests--subscribe (car source) "example-rss.xml")
    (let* ((path (make-temp-file "etaf-rss-tests-opml-" nil ".opml"))
           (export (progn (etaf-rss-export-opml (car source) path)
                          (etaf-rss-tests--wait
                           (lambda () (file-exists-p path))
                           5))))
      (should export)
      (should (etaf-rss-tests--wait
               (lambda () (with-temp-buffer
                            (insert-file-contents path)
                            (string-match-p "outline" (buffer-string))))))
      (unwind-protect
          (etaf-rss-tests--with-session target
            (etaf-rss-import-opml (car target) path)
            (should (etaf-rss-tests--wait
                     (lambda () (= (length (plist-get (etaf-rss-state (car target))
                                                      :feeds))
                                   1))))
            (should (= (length (plist-get (etaf-rss-state (car target)) :feeds)) 1)))
        (ignore-errors (delete-file path))))))

(ert-deftest etaf-rss-tests-theme-switches ()
  "The palette switches between dark and light and persists the choice."
  (etaf-rss-tests--with-session session
    (let ((start (plist-get (etaf-rss-state (car session)) :theme-mode)))
      (should (memq start '(dark light)))
      (should (etaf-rss-cycle-theme (car session)))
      (should-not (eq start (plist-get (etaf-rss-state (car session)) :theme-mode))))
    (should (etaf-rss-set-theme (car session) 'dark))
    (should (eq (plist-get (etaf-rss-state (car session)) :theme-mode) 'dark))
    (should-error (etaf-rss-set-theme (car session) 'sepia) :type 'etaf-rss-error)
    (should (equal (etaf-rss-color :bg 'dark) (plist-get (etaf-rss-theme-defaults 'dark) :ui-bg)))))

(defun etaf-rss-tests--row-painting (buffer color)
  "Return the first position in BUFFER whose face paints COLOR as background."
  (with-current-buffer buffer
    (let ((pos (point-min))
          found)
      (while (and (< pos (point-max)) (not found))
        (when (equal color
                     (plist-get (get-text-property pos 'face) :background))
          (setq found pos))
        (setq pos (1+ pos)))
      found)))

(defun etaf-rss-tests--painted-background (buffer position)
  "Return the background BUFFER paints at POSITION."
  (with-current-buffer buffer
    (plist-get (get-text-property position 'face) :background)))

(etaf-define-component etaf-rss-tests--framing-host (&key surface session)
  "Provide SURFACE to the reader SESSION and render it below."
  :setup (etaf-surface-provide surface)
  :render (etaf-rss-view session))

(ert-deftest etaf-rss-tests-declares-its-surface-to-a-host ()
  "A host frames the reader from the surface the reader declares.
The panel's title-bar switch writes the reader's mode cell, so every mounted
row repaints with the new palette instead of only the frame chrome."
  (etaf-rss-tests--with-session session
    (let* ((surface (etaf-surface-create))
           (buffer (generate-new-buffer " *etaf-rss framing host*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (etaf-mount buffer
                        (etaf-view (etaf-rss-tests--framing-host
                                    :surface surface :session (car session))))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should (equal '((light . "亮") (dark . "暗"))
                           (etaf-surface-modes surface)))
            (let* ((mode (etaf-value (etaf-surface-mode surface)))
                   (other (if (eq mode 'dark) 'light 'dark))
                   (before (etaf-rss-color :bg))
                   (pos (etaf-rss-tests--row-painting buffer before)))
              (should pos)
              (etaf-set-value (etaf-surface-mode surface) other)
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (should (eq other (etaf-value (etaf-surface-mode surface))))
              (should-not (equal before (etaf-rss-color :bg)))
              (should (equal (etaf-rss-color :bg)
                             (etaf-rss-tests--painted-background buffer pos)))
              (should (equal (plist-get (etaf-value (etaf-surface-theme surface))
                                        :ui-bg)
                             (etaf-rss-color :bg)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))
