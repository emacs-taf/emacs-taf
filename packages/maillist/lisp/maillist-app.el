;;; maillist-app.el --- Application shell of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer owns the buffer, the session binding and the mount
;; lifecycle through `etaf-app-open', which also owns the canvas settings, the
;; resize hook and the close path.  Keys the client owns become the root
;; Host's `:keys'; the renderer keeps RET, q, the scrolling keys and `?'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'maillist-theme)
(require 'maillist-model)
(require 'maillist-views)
(require 'maillist-mail)

(defcustom maillist-buffer-name "*ETAF Lists*"
  "Buffer name of a mounted client."
  :type 'string
  :group 'maillist)

(defvar-local maillist--session nil
  "Session shown by the current buffer's runtime.")

(defun maillist--runtime ()
  "Return the runtime of the current buffer."
  (etaf-runtime-for-buffer (current-buffer)))

(defun maillist--reload (session)
  "Reload SESSION: repeat the search when one is active, else sync."
  (let ((query (etaf-value (plist-get session :query))))
    (if (string-empty-p query)
        (maillist-refresh session)
      (maillist-search session query))))

(defun maillist--search-later (session text)
  "Search SESSION for TEXT once typing pauses."
  (when-let* ((timer (plist-get session :search-timer)))
    (cancel-timer timer))
  (plist-put session :search-timer
             (run-at-time 0.35 nil
                          (lambda ()
                            (when (maillist--alive-p session)
                              (maillist-search session text))))))

(defun maillist--focus-search ()
  "Begin editing the search field of the current client."
  (when-let* ((runtime (maillist--runtime)))
    (etaf-text-input-begin runtime 'maillist-search)))

(defun maillist--back (session)
  "Leave the open thread and show the list again."
  (etaf-set-value (plist-get session :reading) nil))

(defun maillist--reader-top ()
  "Scroll the open thread back to its first line."
  (when-let* ((runtime (maillist--runtime)))
    (ignore-errors (etaf-scroll-to runtime 'maillist-reader 0))))

(defun maillist--reveal (id)
  "Scroll the thread list so row ID shows."
  (when-let* ((runtime (maillist--runtime)))
    (ignore-errors
      (etaf-scroll-into-view
       runtime (intern (concat "maillist-thread-" id))))))

(defun maillist--open-row (session id)
  "Open row ID of SESSION and show it."
  (maillist-select session id)
  (maillist--reader-top)
  (maillist--reveal id)
  (when (maillist--narrow-p session)
    (etaf-set-value (plist-get session :reading) t)))

(defun maillist--narrow-p (session)
  "Return non-nil when SESSION's viewport shows one column."
  (< (etaf-value (plist-get session :viewport)) maillist-narrow-width))

(defun maillist--keys (session)
  "Return the root key bindings for SESSION."
  (list (list "j" (lambda () (maillist-move session 1)
                  (when-let* ((id (etaf-value (plist-get session :selected))))
                    (maillist--reader-top)
                    (maillist--reveal id)))
              "下一线程")
        (list "k" (lambda () (maillist-move session -1)
                  (when-let* ((id (etaf-value (plist-get session :selected))))
                    (maillist--reader-top)
                    (maillist--reveal id)))
              "上一线程")
        (list "s" (lambda () (maillist-toggle-star session)) "收藏或取消收藏")
        (list "r" (lambda () (maillist-reply session current-prefix-arg))
              "回复线程（C-u 私回）")
        (list "c" (lambda () (maillist-compose session)) "写新帖")
        (list "e" (lambda () (maillist-load-earlier session)) "展开更早的邮件")
        (list "g" (lambda () (maillist--reload session)) "刷新")
        (list "u" (lambda () (maillist--back session)) "返回线程列表")
        (list "/" (lambda () (maillist--focus-search)) "搜索")))

(defun maillist--view (session)
  "Return the View of SESSION."
  (etaf-view
   (maillist-app
    :model (list :list-name (plist-get (plist-get session :source) :name))
    :viewport (plist-get session :viewport)
    :viewport-px (plist-get session :viewport-px)
    :list-width (plist-get session :list-width)
    :groups (plist-get session :groups)
    :selected (plist-get session :selected)
    :thread (plist-get session :open)
    :scope (plist-get session :scope)
    :summary (plist-get session :summary)
    :status (plist-get session :status)
    :toast (plist-get session :toast)
    :query (plist-get session :query)
    :reading (plist-get session :reading)
    :keys (maillist--keys session)
    :on-select (lambda (id) (maillist--open-row session id))
    :on-message (lambda (id) (maillist-toggle-message session id))
    :on-scope (lambda (value)
                (maillist-set-scope session value)
                (when-let* ((id (etaf-value (plist-get session :selected))))
                  (maillist--reveal id)))
    :on-search (lambda (text) (maillist--search-later session text))
    :on-back (lambda () (maillist--back session))
    :on-earlier (lambda () (maillist-load-earlier session))
    :on-resize (lambda (pixels)
                 (etaf-set-value (plist-get session :list-width) pixels)))))

;;;###autoload
(cl-defun maillist-open (&key (sync t))
  "Mount the client in its own buffer and return that buffer.
SYNC nil opens from the local cache without contacting the archive, which
embedded hosts and tests use."
  (interactive)
  (let* ((session (maillist-create))
         (buffer (etaf-app-open
                  maillist-buffer-name
                  (maillist--view session)
                  :state (list :session session)
                  :on-fit (lambda (window)
                            (setq-local maillist--session session)
                            (etaf-set-value (plist-get session :viewport)
                                            (window-body-width window))
                            (etaf-set-value (plist-get session :viewport-px)
                                            (window-body-width window t))
                            (when (zerop (or (etaf-value
                                              (plist-get session :list-width))
                                             0))
                              (etaf-set-value
                               (plist-get session :list-width)
                               (max 240 (min (* 62 (frame-char-width
                                                    (window-frame window)))
                                             (- (window-body-width window t) 420))))))
                  :on-close (lambda () (maillist-dispose session))
                  :mount-options
                  (lambda (window)
                    (list :viewport-width (window-body-width window t)
                          :viewport-height (window-body-height window))))))
    (with-current-buffer buffer
      (setq-local maillist--session session))
    (maillist--apply-view session t)
    (when sync (maillist-refresh session))
    buffer))

;;;###autoload
(defun maillist-close ()
  "Close the mounted client and kill its buffer."
  (interactive)
  (if (etaf-app-buffer maillist-buffer-name)
      (etaf-app-close maillist-buffer-name)
    (user-error "没有打开的邮件列表")))

(provide 'maillist-app)
;;; maillist-app.el ends here
