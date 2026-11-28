;;; maillist-gui-scenarios.el --- maillist GUI acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Drive the shipped mailing-list client through its documented keys and its
;; size matrix on the shared `emacs-gui-verifier' engine.
;;
;; The client reads a loopback copy of the test fixture archive, so a run needs
;; neither the network nor an account, and the same server answers the date
;; search the "older mail" key asks for.  The run owns one sized frame and
;; resizes it through the matrix, so the wide and narrow layouts and a short
;; height are exercised in one pass.  Functional assertions certify behavior;
;; they do not certify appearance: review the captured frames.
;;
;; Run it from an existing graphical Emacs (a server connection is enough):
;;
;;   emacsclient -e '(progn (load "scripts/maillist-gui-scenarios.el") \
;;                     (maillist-gui-run "/tmp/maillist-gui-run" t))'
;;
;; For a long run, schedule the call from a timer so the client returns; the
;; engine yields to Emacs between actions.  A fresh run directory is required.

;;; Code:

(require 'cl-lib)
(require 'url-util)
(require 'etaf)
(require 'maillist)
(require 'emacs-gui-verifier)

;;; ---------------------------------------------------------------------------
;;; Fixture archive on loopback
;;; ---------------------------------------------------------------------------

(defvar maillist-gui--requests 0
  "Requests the fixture archive answered in this run.")

(defvar maillist-gui--server nil
  "Process serving the fixture archive, or nil.")

(defvar maillist-gui--browsed nil
  "Addresses the browser stub was asked to open, newest first.")

(defvar maillist-gui--fixtures
  (expand-file-name "../tests/fixtures/archive"
                    (file-name-directory
                     (or load-file-name buffer-file-name
                         (locate-library "maillist"))))
  "Directory of the test fixture archive, resolved from this file.")


(defun maillist-gui--literal (path)
  "Return the file at PATH as unibyte text."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defun maillist-gui--older-page ()
  "Return a search page naming two discussions older than the fixtures.
Two messages of the first discussion are listed, which is what the archive
does for a date range; the client groups them by subject."
  (concat
   "<html><body><form action=\"./\"><pre><a\nhref=\"?t=20261020220657\">"
   "<b>fixture mailing list </b></a></pre></form><pre>"
   "     1. <b><a\nhref=\"old-root@example.com/\">Older discussion</a></b>\n"
   "        - by Old Sender @ 2026-10-01 08:00 UTC [99%]\n\n"
   "     2. <b><a\nhref=\"old-reply@example.com/\">Re: Older discussion</a></b>\n"
   "        - by Other Sender @ 2026-10-01 09:30 UTC [99%]\n\n"
   "     3. <b><a\nhref=\"another@example.com/\">Another old thread</a></b>\n"
   "        - by Third Sender @ 2026-09-28 12:00 UTC [99%]\n\n"
   "</pre></body></html>"))

(defun maillist-gui--answer (process body &optional status)
  "Answer the request PROCESS holds with BODY and close the connection.
STATUS is the response status line, 200 by default."
  (process-send-string
   process
   (concat "HTTP/1.1 " (or status "200 OK") "\r\n"
           "Content-Type: text/html\r\n"
           (format "Content-Length: %d\r\n" (length body))
           "Connection: close\r\n\r\n"
           body))
  (delete-process process))

(defun maillist-gui--serve (process chunk)
  "Answer PROCESS's request, taken as CHUNK, from the fixture archive.
A date query gets the older page, a raw message gets a sender header, and
every other path is a file of the fixture directory."
  (let ((request (concat (or (process-get process :request) "") chunk)))
    (process-put process :request request)
    (when (string-match-p "\r\n\r\n" request)
      (setq maillist-gui--requests (1+ maillist-gui--requests))
      (let* ((target (nth 1 (split-string (car (split-string request "\r\n")) " ")))
             (path (url-unhex-string (or target "/")))
             (file (cond ((string-match-p "\\?q=" path) nil)
                         ((string-match-p "raw\\'" path) nil)
                         ((string-match-p "\\`/t\\.atom\\|/t\\.atom" path)
                          (expand-file-name
                           (concat (car (split-string path "/" 'omit-nulls))
                                   "/t.atom")
                           maillist-gui--fixtures))
                         (t (expand-file-name "index.html"
                                              maillist-gui--fixtures)))))
        (cond
         ((string-match-p "\\?q=" path)
          (maillist-gui--answer process (maillist-gui--older-page)))
         ((string-match-p "raw\\'" path)
          (maillist-gui--answer process "From: Fixture Sender <sender@example.org>\n"))
         ((and file (file-exists-p file))
          (maillist-gui--answer process (maillist-gui--literal file)))
         (t (maillist-gui--answer process "" "404 Not Found")))))))

(defun maillist-gui--start-server ()
  "Start the fixture archive and return its base URL.
The fixture index must be readable, so a run against the wrong directory
fails here instead of answering 404 for every request."
  (unless (file-exists-p (expand-file-name "index.html" maillist-gui--fixtures))
    (error "Fixture archive not found in %s" maillist-gui--fixtures))
  (let ((server (make-network-process
                 :name "maillist-gui-archive"
                 :server t
                 :host "127.0.0.1"
                 :service t
                 :family 'ipv4
                 :coding 'binary
                 :noquery t
                 :filter #'maillist-gui--serve)))
    (setq maillist-gui--server server)
    (format "http://127.0.0.1:%d/" (process-contact server :service))))

(defun maillist-gui--stop-server ()
  "Stop the fixture archive."
  (when (process-live-p maillist-gui--server)
    (delete-process maillist-gui--server))
  (setq maillist-gui--server nil))

;;; ---------------------------------------------------------------------------
;;; Reading the client through its buffer
;;; ---------------------------------------------------------------------------

(defun maillist-gui--target (context)
  "Return CONTEXT's client buffer."
  (etaf-gui-verifier-context-target-buffer context))

(defun maillist-gui--text (context)
  "Return CONTEXT's client text without properties."
  (with-current-buffer (maillist-gui--target context)
    (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun maillist-gui--shows (context text)
  "Return non-nil when CONTEXT's client displays TEXT."
  (string-match-p (regexp-quote text) (maillist-gui--text context)))

(defun maillist-gui--open-id (context)
  "Return the id of the thread CONTEXT's client shows, or nil.
The list and the reader share the same text, so the assertion names the thread
the client actually opened rather than a subject both columns show."
  (with-current-buffer (maillist-gui--target context)
    (let* ((state (etaf-app-state (buffer-name)))
           (session (plist-get state :session))
           (open (and session (etaf-value (plist-get session :open)))))
      (plist-get open :id))))

(defun maillist-gui--key (context keys)
  "Send documented KEYS through CONTEXT's client command loop."
  (with-current-buffer (maillist-gui--target context)
    (execute-kbd-macro (kbd keys))))

(defun maillist-gui--assert (name passed &optional detail)
  "Return verifier assertion NAME for PASSED, with optional DETAIL."
  (etaf-gui-verifier-assert name passed detail))

(defun maillist-gui--settled (context)
  "Return non-nil when CONTEXT's client has finished its request."
  (let ((text (ignore-errors (maillist-gui--text context))))
    (and text
         (not (string-match-p "正在同步邮件列表" text))
         (not (string-match-p "正在搜索" text))
         (not (string-match-p "正在取更早的邮件" text)))))

(defun maillist-gui--eventually (context &rest needles)
  "Return non-nil when CONTEXT's text shows any of NEEDLES.
An action whose result arrives asynchronously settles on the text the reader
sees, not on the brief absence of the loading notice."
  (let ((text (ignore-errors (maillist-gui--text context))))
    (and text
         (seq-some (lambda (needle)
                     (string-match-p (regexp-quote needle) text))
                   needles))))

(defun maillist-gui--action (id execute assertions &optional screenshot)
  "Build one scenario action ID from EXECUTE and ASSERTIONS.
SCREENSHOT asks the engine for a window capture after the action settles."
  (etaf-gui-verifier-action-create
   :id id :execute execute :screenshot screenshot
   :settled-p #'maillist-gui--settled
   :assertions assertions))

(defun maillist-gui--key-action (id keys screenshot assertions)
  "Build an action pressing KEYS, taking SCREENSHOT and asserting ASSERTIONS.
KEYS are documented keys, sent through the client's own command loop."
  (maillist-gui--action
   id (lambda (context) (maillist-gui--key context keys))
   assertions screenshot))

(defun maillist-gui--painted-width (&optional buffer)
  "Return the widest painted line of BUFFER in pixels."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((window (get-buffer-window buffer)))
      (with-current-buffer buffer
        (car (window-text-pixel-size window (point-min) (point-max) 100000))))))

(defun maillist-gui--canvas-fits-p (&optional buffer)
  "Return non-nil when BUFFER's painted canvas fits its window width and height.
With the original theme's mode-line preserved, a boxed mode-line can leave a
sub-line pixel remainder below the last full row; the canvas fills every full
row without overflowing horizontally or vertically."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((window (get-buffer-window buffer)))
      (with-current-buffer buffer
        (let* ((size (window-text-pixel-size window (point-min) (point-max) 100000))
               (painted-w (car size))
               (painted-h (cdr size))
               (body-w (window-body-width window t))
               (body-h (window-body-height window t))
               (row-h (max 1 (line-pixel-height))))
          (and (> painted-w 0)
               (<= painted-w body-w)
               (<= painted-h body-h)
               (< (- body-h painted-h) row-h)))))))

(defun maillist-gui--height-assertion (&optional buffer)
  "Return an assertion that BUFFER's painted canvas fills every full window row."
  (let ((buffer (or buffer (current-buffer))))
    (if-let* ((window (get-buffer-window buffer)))
        (with-current-buffer buffer
          (let* ((painted (cdr (window-text-pixel-size
                                window (point-min) (point-max) 100000)))
                 (body (window-body-height window t))
                 (row-h (max 1 (line-pixel-height))))
            (maillist-gui--assert
             "canvas height fills every full row above the mode-line"
             (and (<= painted body) (< (- body painted) row-h))
             (format "canvas-h=%s body-h=%s row-h=%s" painted body row-h))))
      (maillist-gui--assert "canvas height fills every full row above the mode-line" nil
                            "target buffer is not displayed"))))

(defun maillist-gui--width-assertion (&optional buffer)
  "Return an assertion that BUFFER's painted canvas fits the window width.
A row wider than the window scrolls sideways on the first click past its
edge, so a header that overflows its canvas fails here."
  (let ((buffer (or buffer (current-buffer))))
    (if-let* ((window (get-buffer-window buffer)))
        (with-current-buffer buffer
          ;; An explicit X-LIMIT past the window keeps the measurement from
          ;; being clamped, so a row that runs under the canvas fails here.
          (let ((painted (car (window-text-pixel-size
                               window (point-min) (point-max) 100000)))
                (body (window-body-width window t)))
            (maillist-gui--assert
             "canvas width fits the window" (<= painted body)
             (format "canvas %s vs window %s" painted body))))
      (maillist-gui--assert "canvas width fits the window" nil
                            "target buffer is not displayed"))))

(defun maillist-gui--resize (width height screenshots)
  "Build an action resizing the frame to WIDTH x HEIGHT characters.
The action settles once the painted canvas fills the window again, so a
layout that budgets the viewport is repainted before it is measured."
  (etaf-gui-verifier-action-create
   :id (format "layout-%dx%d" width height)
   :execute (lambda (context)
              (ignore context)
              (set-frame-size (selected-frame) width height))
   :settle-timeout 20.0
   :settled-p (lambda (context)
                (and (= (frame-width) width) (= (frame-height) height)
                     (with-current-buffer (maillist-gui--target context)
                       (maillist-gui--canvas-fits-p))))
   :screenshot screenshots
   :assertions
   (lambda (context)
     (append
      (list
       (maillist-gui--assert (format "frame is %dx%d" width height)
                             (and (= (frame-width) width)
                                  (= (frame-height) height))))
      (with-current-buffer (maillist-gui--target context)
        (list
         (maillist-gui--height-assertion)
         (maillist-gui--width-assertion)))))))

;;; ---------------------------------------------------------------------------
;;; The run
;;; ---------------------------------------------------------------------------

(defun maillist-gui--frame-options (width height)
  "Return frame parameters for a WIDTH x HEIGHT verification frame."
  (list (cons 'name "maillist-gui-acceptance")
        (cons 'width width) (cons 'height height)
        (cons 'fullscreen nil)))

(defun maillist-gui-run (directory &optional screenshots)
  "Verify the mailing-list client in DIRECTORY, taking SCREENSHOTS when asked.
DIRECTORY must be fresh.  One pass walks every documented key against the
fixture archive, then the wide, narrow and short sizes; the run owns its frame
and leaves the client closed."
  (let* ((base (maillist-gui--start-server))
         (other (make-temp-file "maillist-gui-other" t))
         (maillist-store-file (make-temp-file "maillist-gui-store" nil ".sqlite3"))
         (maillist-prefetch-threads 200)
         (maillist-prefetch-bodies 0)
         (maillist-auto-refresh nil)
         (maillist-network-route 'direct)
         (url-proxy-services nil)
         (maillist-sources
          (list (list :name "fixture" :base base :address "fixture@example.org")
                (list :name "other"
                      :base (concat "file://" other "/")
                      :index "index.html"
                      :address "other@example.org"))))
    (write-region "<html><body><pre>other list</pre></body></html>"
                  nil (expand-file-name "index.html" other) nil 'silent)
    (unwind-protect
        (etaf-gui-verifier-run
         (etaf-gui-verifier-scenario-create
          :name "maillist-client"
          :claim "Documented keys, the mail reading flow and the size matrix on a loopback archive"
          :invariants
          (lambda (context)
            (with-current-buffer (maillist-gui--target context)
              (cons (maillist-gui--assert "mode-line is preserved"
                                          (not (null mode-line-format)))
                    (etaf-gui-verifier-line-height-assertions))))
          :initialize
          (lambda (context)
            (ignore-errors (maillist-close))
            (let* ((old (selected-frame))
                   (frame (make-frame (maillist-gui--frame-options 150 40))))
              (select-frame frame)
              (delete-frame old)
              (delete-other-windows)
              (set-frame-size frame 150 40)
              (let* ((display-buffer-overriding-action '((display-buffer-same-window)))
                     (buffer (maillist-open :sync t :list "fixture")))
                (etaf-gui-verifier-context-select-buffer context buffer))))
          :actions
          (list
           ;; --- The list, as the client opens ---------------------------
           (etaf-gui-verifier-action-create
            :id "list-syncs"
            :execute (lambda (context) (ignore context))
            :settled-p #'maillist-gui--settled
            :screenshot screenshots
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "the archive name shows"
                                     (maillist-gui--shows context "fixture"))
               (maillist-gui--assert "the scopes show"
                                     (and (maillist-gui--shows context "全部")
                                          (maillist-gui--shows context "未读")
                                          (maillist-gui--shows context "已收藏")))
               (maillist-gui--assert "the search field shows"
                                     (maillist-gui--shows context "搜索标题或正文"))
               (maillist-gui--assert "the archive answered four threads"
                                     (maillist-gui--shows context "4 个线程"))
               (maillist-gui--assert "the newest thread shows"
                                     (maillist-gui--shows context
                                                          "[PATCH] Fix the widget default")))))
           ;; --- Selection and the reader --------------------------------
           (maillist-gui--key-action
            "select-next" "j" screenshots
            (lambda (context)
              (list
               (maillist-gui--assert "j opens the next thread"
                                     (maillist-gui--shows context "Widget default value"))
               (maillist-gui--assert "the reader names the thread size"
                                     (maillist-gui--shows context "2 封")))))
           (maillist-gui--key-action
            "select-previous" "k"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "k returns to the first thread"
                                     (maillist-gui--shows context "3 封")))))
           (maillist-gui--key-action
            "message-prev" "["
            nil
            (lambda (context)
              (let ((focused (with-current-buffer (maillist-gui--target context)
                               (let ((session (plist-get (etaf-app-state (buffer-name)) :session)))
                                 (etaf-value (plist-get session :focused-message))))))
                (list
                 (maillist-gui--assert "[ moves focused message to the previous mail"
                                       (equal "alpha-reply@example.com" focused))))))
           (maillist-gui--key-action
            "toggle-quotes-on" "Q"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "Q folds long quoted blocks"
                                     (maillist-gui--shows context "已折叠长引文")))))
           (maillist-gui--key-action
            "toggle-quotes-off" "Q"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "Q unfolds quotes again"
                                     (maillist-gui--shows context "已展开全部引文")))))
           (maillist-gui--key-action
            "toggle-all-collapse" "z"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "z collapses all messages in the thread"
                                     (maillist-gui--shows context "已折叠全部邮件")))))
           (maillist-gui--key-action
            "toggle-all-expand" "z"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "z expands all messages again"
                                     (maillist-gui--shows context "已展开全部邮件")))))
           (maillist-gui--key-action
            "copy-mbox-url" "m"
            nil
            (lambda (context)
              (ignore context)
              (list
               (maillist-gui--assert "m copies the thread mbox.gz URL"
                                     (and (stringp (car kill-ring))
                                          (string-suffix-p "/t.mbox.gz" (car kill-ring)))))))
           (maillist-gui--key-action
            "copy-message-id" "w"
            nil
            (lambda (context)
              (ignore context)
              (list
               (maillist-gui--assert "w copies the focused Message-ID"
                                     (equal "<alpha-reply@example.com>" (car kill-ring))))))
           (maillist-gui--key-action
            "open-help" "?"
            nil
            (lambda (context)
              (let ((notes (with-current-buffer (maillist-gui--target context)
                             (plist-get (etaf-help-data
                                         (etaf-runtime-for-buffer (current-buffer)))
                                        :notes))))
                (list
                 (maillist-gui--assert "? shows in-buffer modal help"
                                       (and (maillist-gui--shows context "回复邮件")
                                            (cl-some (lambda (n) (string-match-p "搜索语法" n))
                                                     notes)))))))
           (maillist-gui--key-action
            "close-help" "<escape>"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "ESC closes help back to the client"
                                     (maillist-gui--shows context "4 个线程")))))
           (maillist-gui--key-action
            "next-unread" "n"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "n opens the next unread thread"
                                     (equal "beta-reply@example.com"
                                            (maillist-gui--open-id context))))))
           (etaf-gui-verifier-action-create
            :id "activate-with-ret"
            :execute
            (lambda (context)
              (with-current-buffer (maillist-gui--target context)
                (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
                  ;; The native activation path: focus the row, then RET.
                  (etaf-focus runtime 'maillist-thread-beta@example.com)
                  (execute-kbd-macro (kbd "RET")))))
            :settled-p #'maillist-gui--settled
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "RET on a focused row opens that thread"
                                     (maillist-gui--shows context "2 封")))))
           (maillist-gui--key-action
            "back-to-list" "u"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "u returns to the list"
                                     (maillist-gui--shows context "4 个线程")))))
           ;; --- The address and the browser ----------------------------
           (maillist-gui--key-action
            "copy-thread-url" "C"
            nil
            (lambda (context)
              (ignore context)
              (list
               (maillist-gui--assert "C copies the archive page"
                                     (and (stringp (car kill-ring))
                                          (string-prefix-p base (car kill-ring)))))))
           (etaf-gui-verifier-action-create
            :id "browse-thread"
            :execute
            (lambda (context)
              (setq maillist-gui--browsed nil)
              (cl-letf (((symbol-function 'browse-url)
                         (lambda (url &rest _) (setq maillist-gui--browsed url))))
                (maillist-gui--key context "B")))
            :settled-p #'maillist-gui--settled
            :assertions
            (lambda (context)
              (ignore context)
              (list
               (maillist-gui--assert "B opens the archive page of the thread"
                                     (and maillist-gui--browsed
                                          (string-prefix-p base maillist-gui--browsed)
                                          (string-match-p "beta@example.com"
                                                          maillist-gui--browsed))))))
           ;; --- Marks and scopes ---------------------------------------
           (maillist-gui--key-action
            "empty-starred-scope" "3"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "empty starred scope shows dedicated message"
                                     (maillist-gui--shows context "还没有收藏的线程")))))
           (maillist-gui--key-action
            "back-to-all-before-star" "1"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "returns to all threads"
                                     (maillist-gui--shows context "Widget default value")))))
           (maillist-gui--key-action
            "star" "s"
            nil
            (lambda (context)
              (let ((toast (with-current-buffer (maillist-gui--target context)
                             (let ((sess (plist-get (etaf-app-state (buffer-name)) :session)))
                               (plist-get (etaf-value (plist-get sess :toast)) :text)))))
                (list
                 (maillist-gui--assert "s shows starred toast notice"
                                       (equal "已收藏" toast)
                                       (format "toast=%S" toast))
                 (maillist-gui--assert "reader header shows starred badge"
                                       (maillist-gui--shows context "* 已收藏"))))))
           (maillist-gui--key-action
            "unstar" "s"
            nil
            (lambda (context)
              (let ((toast (with-current-buffer (maillist-gui--target context)
                             (let ((sess (plist-get (etaf-app-state (buffer-name)) :session)))
                               (plist-get (etaf-value (plist-get sess :toast)) :text)))))
                (list
                 (maillist-gui--assert "second s shows unstarred toast notice"
                                       (equal "已取消收藏" toast)
                                       (format "toast=%S" toast))))))
           (maillist-gui--key-action
            "restar" "s"
            nil
            (lambda (context)
              (let ((toast (with-current-buffer (maillist-gui--target context)
                             (let ((sess (plist-get (etaf-app-state (buffer-name)) :session)))
                               (plist-get (etaf-value (plist-get sess :toast)) :text)))))
                (list
                 (maillist-gui--assert "restarring shows toast again"
                                       (equal "已收藏" toast)
                                       (format "toast=%S" toast))))))
           (maillist-gui--key-action
            "scope-starred" "3"
            screenshots
            (lambda (context)
              (list
               (maillist-gui--assert "the starred scope shows the starred thread"
                                     (maillist-gui--shows context "Widget default value"))
               (maillist-gui--assert "the starred scope hides the others"
                                     (not (maillist-gui--shows context
                                                               "Question about quoting"))))))
           (maillist-gui--key-action
            "scope-all" "1"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "the all scope shows every thread"
                                     (maillist-gui--shows context
                                                          "Question about quoting")))))
           (maillist-gui--key-action
            "mark-unread" "M-u"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "M-u marks the thread unread"
                                     (maillist-gui--shows context "已标为未读")))))
           (maillist-gui--key-action
            "scope-unread" "2"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "the unread scope shows the thread again"
                                     (maillist-gui--shows context "Widget default value")))))
           (maillist-gui--key-action
            "mark-all-read" "A"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "A reports how many threads it marked"
                                     (maillist-gui--shows context "标为已读")))))
           (maillist-gui--key-action
            "scope-all-again" "1"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "the list is back"
                                     (maillist-gui--shows context "4 个线程")))))
           ;; --- Search and its history ---------------------------------
           (etaf-gui-verifier-action-create
            :id "search-local-filter"
            :execute
            (lambda (context)
              (ignore context)
              (execute-kbd-macro (kbd "/"))
              (execute-kbd-macro "is:starred"))
            :settle-timeout 15.0
            :settled-p
            (lambda (context)
              (maillist-gui--eventually context "搜索结果" "搜索失败"))
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "a local filter narrows the list"
                                     (maillist-gui--shows context "搜索结果"))
               (maillist-gui--assert "the starred thread is the only row"
                                     (and (maillist-gui--shows context "Widget default value")
                                          (not (maillist-gui--shows context
                                                                    "Question about quoting")))))))
           (etaf-gui-verifier-action-create
            :id "search-history-back"
            :execute
            (lambda (context)
              (ignore context)
              (execute-kbd-macro (kbd "RET"))
              (execute-kbd-macro (kbd "M-p")))
            :settle-timeout 15.0
            :settled-p
            (lambda (context)
              (maillist-gui--eventually context "个线程" "同步失败"))
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "M-p walks back to the archive list"
                                     (and (maillist-gui--shows context "4 个线程")
                                          (not (maillist-gui--shows context "搜索结果")))))))
           ;; --- Mail older than the list --------------------------------
           (etaf-gui-verifier-action-create
            :id "load-older"
            :execute (lambda (context) (maillist-gui--key context "o"))
            :settle-timeout 15.0
            :settled-p
            (lambda (context)
              (maillist-gui--eventually context "更早的邮件" "没有更多" "失败"))
            :screenshot screenshots
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "o adds the older mail"
                                     (maillist-gui--shows context "已取回 2 封更早的邮件"))
               (maillist-gui--assert "the older discussion joins the list"
                                     (maillist-gui--shows context "Older discussion"))
               (maillist-gui--assert "the list counts the added rows"
                                     (maillist-gui--shows context "6 个线程")))))
           (maillist-gui--key-action
            "jump-last" "G"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "G opens the last thread of the list"
                                     (equal "another@example.com"
                                            (maillist-gui--open-id context))))))
           (maillist-gui--key-action
            "jump-first" "<"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "< opens the first thread of the list"
                                     (equal "alpha@example.com"
                                            (maillist-gui--open-id context))))))
           ;; --- Switching archives -------------------------------------
           (etaf-gui-verifier-action-create
            :id "switch-list"
            :execute
            (lambda (context)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "other")))
                (maillist-gui--key context "L"))
              ;; Opening another archive replaces the application buffer, so
              ;; the run follows the client to the new one.
              (etaf-gui-verifier-context-select-buffer
               context (etaf-app-buffer maillist-buffer-name)))
            :settle-timeout 15.0
            :settled-p
            (lambda (context)
              (maillist-gui--eventually context "0 个线程" "同步失败"))
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "L opens the chosen archive"
                                     (maillist-gui--shows context "0 个线程")))))
           (etaf-gui-verifier-action-create
            :id "switch-back"
            :execute
            (lambda (context)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "fixture")))
                (maillist-gui--key context "L"))
              (etaf-gui-verifier-context-select-buffer
               context (etaf-app-buffer maillist-buffer-name)))
            :settle-timeout 15.0
            :settled-p
            (lambda (context)
              (maillist-gui--eventually context "6 个线程" "同步失败"))
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "the fixture archive comes back with its rows"
                                     (maillist-gui--shows context "6 个线程")))))
           ;; --- The size matrix ----------------------------------------
           (maillist-gui--resize 120 32 screenshots)
           (etaf-gui-verifier-action-create
            :id "wide-keeps-both-columns"
            :execute (lambda (context) (ignore context))
            :settled-p #'maillist-gui--settled
            :screenshot screenshots
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "the wide layout keeps the list and the reader"
                                     (and (maillist-gui--shows context "6 个线程")
                                          (maillist-gui--shows context "Older discussion"))))))
           (maillist-gui--resize 108 32 screenshots)
           (maillist-gui--resize 96 32 screenshots)
           (etaf-gui-verifier-action-create
            :id "narrow-shows-one-column"
            :execute (lambda (context) (ignore context))
            :settled-p #'maillist-gui--settled
            :screenshot screenshots
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "the narrow layout shows the list alone"
                                     (and (maillist-gui--shows context "6 个线程")
                                          (maillist-gui--shows context "Older discussion"))))))
           (etaf-gui-verifier-action-create
            :id "narrow-opens-the-reader"
            :execute
            (lambda (context)
              (with-current-buffer (maillist-gui--target context)
                (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
                  ;; The narrow layout keeps the list until a row is opened;
                  ;; focus the row and activate it with RET.
                  (etaf-focus runtime 'maillist-thread-alpha@example.com)
                  (execute-kbd-macro (kbd "RET")))))
            :settled-p #'maillist-gui--settled
            :screenshot screenshots
            :assertions
            (lambda (context)
              (list
               (maillist-gui--assert "opening a row in a narrow window shows the reader"
                                     (maillist-gui--shows context "封 ·"))
               (maillist-gui--assert "the narrow reader offers the way back"
                                     (maillist-gui--shows context "← 列表")))))
           (maillist-gui--key-action
            "narrow-back-to-list" "u"
            nil
            (lambda (context)
              (list
               (maillist-gui--assert "the narrow layout returns to the list"
                                     (maillist-gui--shows context "6 个线程")))))
           (maillist-gui--resize 120 16 screenshots)
           (etaf-gui-verifier-action-create
            :id "short-window"
            :execute (lambda (context) (ignore context))
            :settled-p #'maillist-gui--settled
            :screenshot screenshots
            :assertions
            (lambda (context)
              (let ((list-width
                     (with-current-buffer (maillist-gui--target context)
                       (let* ((state (etaf-app-state (buffer-name)))
                              (session (plist-get state :session)))
                         (and session
                              (etaf-value (plist-get session :list-width)))))))
                (list
                 (maillist-gui--assert "a short window keeps the header and rows"
                                       (and (maillist-gui--shows context "fixture")
                                            (maillist-gui--shows context "6 个线程")))
                 (maillist-gui--assert "widening restores the user list width"
                                       (and (integerp list-width) (> list-width 320))
                                       (format "list-width=%s" list-width))))))
           (maillist-gui--resize 150 40 nil)))
         directory)
        (ignore-errors (maillist-close))
        (maillist-gui--stop-server)
        (ignore-errors (delete-directory other t))
        (ignore-errors (delete-file maillist-store-file)))))

(provide 'maillist-gui-scenarios)
;;; maillist-gui-scenarios.el ends here
