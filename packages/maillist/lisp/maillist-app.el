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
  "Leave the open thread of SESSION and show the list again."
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

(defun maillist--set-scope-key (session scope)
  "Show SESSION's SCOPE and keep the open thread in view."
  (maillist-set-scope session scope)
  (when-let* ((id (etaf-value (plist-get session :selected))))
    (maillist--reveal id)))

(defun maillist--mark-selected (session read)
  "Mark the row SESSION has selected READ or unread and say what happened."
  (let ((id (etaf-value (plist-get session :selected))))
    (if (not id)
        (maillist--toast session 'info "没有选中的线程" 3)
      (let ((now (maillist-set-read session id read)))
        (maillist--toast session 'info
                         (if now "已标为已读" "已标为未读")
                         3)
        (when now (maillist--reader-top))))))

(defun maillist--mark-all-read (session)
  "Mark every row SESSION shows read."
  (let ((count (maillist-mark-all-read session)))
    (maillist--toast session 'info
                     (if (> count 0)
                         (format "已把 %d 个线程标为已读" count)
                       "没有未读的线程")
                     4)))

(defun maillist--load-older (session)
  "Ask SESSION's archive for mail older than the list holds."
  (maillist-load-older session))

(defun maillist--switch-list (session)
  "Open another archive for SESSION, remembered for the next start."
  (let ((name (completing-read
               "邮件列表："
               (mapcar (lambda (source) (plist-get source :name)) maillist-sources)
               nil t)))
    (when (and name (not (equal name (plist-get (plist-get session :source) :name))))
      (maillist-open :list name))))

(defun maillist--thread-url (session)
  "Return the archive page of the thread SESSION shows, or nil."
  (when-let* ((id (etaf-value (plist-get session :selected))))
    (maillist-thread-url session id)))

(defun maillist--copy-thread-url (session)
  "Put the archive page of SESSION's open thread on the kill ring."
  (if-let* ((url (maillist--thread-url session)))
      (progn
        (kill-new url)
        (maillist--toast session 'info (format "已复制 %s" url) 5))
    (maillist--toast session 'info "没有选中的线程" 3)))

(defun maillist--browse-thread (session)
  "Open SESSION's selected thread in the browser."
  (if-let* ((url (maillist--thread-url session)))
      (progn (browse-url url)
             (maillist--toast session 'info "已在浏览器打开" 3))
    (maillist--toast session 'info "没有选中的线程" 3)))

(defun maillist--recall-query (session &optional forward)
  "Search SESSION again with an older query, or a newer one when FORWARD."
  (let ((query (maillist-recall-query session forward)))
    (maillist--toast session 'info
                     (if (string-empty-p query)
                         "回到邮件列表"
                       (format "搜索「%s」" query))
                     4)))

(defun maillist--next-unread (session)
  "Open the next unread thread of SESSION and say so when there is none."
  (if (maillist--reveal-selected (maillist-next-unread session))
      (maillist--reader-top)
    (maillist--toast session 'info "没有更多未读的线程" 4)))

(defun maillist--select-edge (session edge)
  "Move SESSION to its first or last row, and open it."
  (when (maillist--reveal-selected (maillist-select-edge session edge))
    (maillist--reader-top)))

(defun maillist--reveal-selected (id)
  "Scroll the list to row ID and return it."
  (when id
    (maillist--reveal id)
    id))

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
        (list "n" (lambda () (maillist--next-unread session)) "下一未读")
        (list "G" (lambda () (maillist--select-edge session 'last)) "最后一个线程")
        (list "s" (lambda () (maillist-toggle-star session)) "收藏或取消收藏")
        (list "r" (lambda () (maillist-reply session current-prefix-arg))
              "回复线程（C-u 私回）")
        (list "R" (lambda () (maillist-reply-all session)) "回复全部（抄送作者）")
        (list "c" (lambda () (maillist-compose session)) "写新帖")
        (list "e" (lambda () (maillist-load-earlier session)) "展开更早的邮件")
        (list "g" (lambda () (maillist--reload session)) "刷新")
        (list "u" (lambda () (maillist--back session)) "返回线程列表")
        (list "1" (lambda () (maillist--set-scope-key session 'all)) "全部")
        (list "2" (lambda () (maillist--set-scope-key session 'unread)) "只看未读")
        (list "3" (lambda () (maillist--set-scope-key session 'starred)) "只看收藏")
        (list "M-u" (lambda () (maillist--mark-selected session nil)) "标为未读")
        (list "A" (lambda () (maillist--mark-all-read session)) "全部标为已读")
        (list "o" (lambda () (maillist--load-older session)) "取更早的邮件")
        (list "M-p" (lambda () (maillist--recall-query session)) "上一个搜索")
        (list "M-n" (lambda () (maillist--recall-query session t)) "下一个搜索")
        (list "C" (lambda () (maillist--copy-thread-url session)) "复制原帖地址")
        (list "B" (lambda () (maillist--browse-thread session)) "浏览器打开原帖")
        (list "L" (lambda () (maillist--switch-list session)) "切换邮件列表")
        (list "/" (lambda () (maillist--focus-search)) "搜索")))

(defun maillist--arm-refresh (session)
  "Sync SESSION every `maillist-auto-refresh' seconds while it is open.
Mail arrives without the reader asking, so the client asks the archive on a
schedule; a quiet sync stays out of the notice area and reports only a thread
the archive added."
  (when (and maillist-auto-refresh (> maillist-auto-refresh 0))
    (let ((buffer (get-buffer maillist-buffer-name)))
      (plist-put
       session :refresh-timer
       (run-with-timer
        maillist-auto-refresh
        maillist-auto-refresh
        (lambda ()
          (when (and (maillist--alive-p session)
                     (buffer-live-p buffer))
            (maillist-refresh session t))))))))

(defun maillist--disarm-refresh (session)
  "Cancel SESSION's idle refresh timer."
  (when-let* ((timer (plist-get session :refresh-timer)))
    (cancel-timer timer)
    (plist-put session :refresh-timer nil)))

(defun maillist--view (session)
  "Return the View of SESSION."
  (etaf-view
   (maillist-app
    :model (list :list-name (plist-get (plist-get session :source) :name))
    :viewport (plist-get session :viewport)
    :viewport-px (plist-get session :viewport-px)
    :viewport-rows (plist-get session :viewport-rows)
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
(cl-defun maillist-open (&key (sync t) list)
  "Mount the client in its own buffer and return that buffer.
SYNC nil opens from the local cache without contacting the archive, which
embedded hosts and tests use.  LIST names the archive to read; without it the
client opens the one it opened last."
  (interactive)
  (let* ((session (maillist-create :list list))
         (buffer (etaf-app-open
                  maillist-buffer-name
                  (maillist--view session)
                  :state (list :session session)
                  ;; The client paints its own focus; a text cursor would sit
                  ;; on whatever cell point last landed on.
                  :cursor nil
                  :on-fit (lambda (window)
                            (setq-local maillist--session session)
                            (etaf-set-value (plist-get session :viewport)
                                            (window-body-width window))
                            (etaf-set-value (plist-get session :viewport-rows)
                                            (window-body-height window))
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
    (maillist--arm-refresh session)
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
