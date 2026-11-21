;;; maillist-app.el --- Application shell of maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer owns the buffer, the session binding and the mount
;; lifecycle through `etaf-app-open', which also owns the canvas settings, the
;; resize hook and the close path.  Keys the client owns become the root
;; Host's `:keys'; the renderer keeps RET, q, Tab, M-g, arrows and `?'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'maillist-theme)
(require 'maillist-model)
(require 'maillist-views)
(require 'maillist-mail)

(defcustom maillist-buffer-name "*maillist*"
  "Buffer name of a mounted client."
  :type 'string
  :group 'maillist)

(defvar-local maillist--session nil
  "Session shown by the current buffer's runtime.")

(defconst maillist--help-notes
  '("搜索语法：from: / to: / subject: / body: / message:（可加 - 排除），after: / before: YYYY-MM-DD，以及本地筛选 is:unread / is:read / is:starred（按 RET 执行远端搜索，清空回到列表）。"
    "回复邮件：r 回复列表（emacs-bugs 自动发往对应 bug@debbugs.gnu.org），R 抄送作者，C-u r 私回作者；用 [ / ] 切换线程内要回复的目标邮件。"
    "区域导航：M-g f 进入搜索栏、M-g t 进入线程列表、M-g v 进入邮件正文；Tab 在各区域间跳转，SPC / DEL 直接翻阅正文。"
    "发信配置：运行 M-x maillist-mail-configure 保存应用密码，或将 maillist-send-mail-function 设为 inherit 复用 Emacs 原有发信配置。")
  "Help notes displayed inside the in-buffer `?` modal help.")

(defun maillist--runtime ()
  "Return the runtime of the current buffer."
  (etaf-runtime-for-buffer (current-buffer)))

(defun maillist--reload (session)
  "Reload SESSION: repeat the search when one is active, else sync."
  (let ((query (etaf-value (plist-get session :query))))
    (if (string-empty-p query)
        (maillist-refresh session)
      (maillist-search session query))))

(defun maillist--cancel-search-timer (session)
  "Cancel any pending local-filter debounce timer on SESSION."
  (when-let* ((timer (plist-get session :search-timer)))
    (cancel-timer timer)
    (plist-put session :search-timer nil)))

(defun maillist--search-input-change (session text)
  "Handle live typing in SESSION's search field.
Always updates `:search-input'.  Clearing the field restores the archive list
immediately; local-only filters (`is:unread', `is:starred', `is:read') apply
after a brief pause without recording partial drafts in history; remote
archive queries wait for `RET' (`maillist--search-submit') so typing never
floods the archive or pollutes history."
  (etaf-set-value (plist-get session :search-input) (or text ""))
  (maillist--cancel-search-timer session)
  (let* ((trimmed (string-trim (or text "")))
         (compiled (maillist-compile-query trimmed))
         (remote (plist-get compiled :query))
         (filters (plist-get compiled :filters)))
    (cond
     ((string-empty-p trimmed)
      (unless (string-empty-p (etaf-value (plist-get session :query)))
        (maillist--restore-archive-list session)))
     ((and (string-empty-p remote) filters)
      (plist-put
       session :search-timer
       (run-at-time
        0.25 nil
        (lambda ()
          (when (maillist--alive-p session)
            (plist-put session :search-timer nil)
            (etaf-set-value (plist-get session :query) trimmed)
            (etaf-set-value (plist-get session :filters) filters)
            (etaf-set-value (plist-get session :scope) 'all)
            (etaf-set-value (plist-get session :threads)
                            (plist-get session :archive-threads))
            (maillist--clear-open session)
            (maillist--apply-view session)
            (maillist--status session 'idle "")))))))))

(defun maillist--search-submit (session text)
  "Submit TEXT from SESSION's search field, running remote or local search."
  (maillist--cancel-search-timer session)
  (maillist-search session text))

(defun maillist--search-clear (session)
  "Clear SESSION's search field and restore the archive list."
  (maillist--cancel-search-timer session)
  (maillist-search session ""))

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

(defun maillist--scroll-page (session direction)
  "Scroll SESSION's reader (or list in narrow list view) by one page in DIRECTION."
  (when-let* ((runtime (maillist--runtime)))
    (let* ((rows (max 6 (or (etaf-value (plist-get session :viewport-rows)) 24)))
           (step (* direction (max 4 (- rows 6))))
           (narrow (maillist--narrow-p session))
           (target (if (or (not narrow) (etaf-value (plist-get session :reading)))
                       'maillist-reader
                     'maillist-thread-list)))
      (ignore-errors (etaf-scroll-by runtime target step)))))

(defun maillist--reveal (id)
  "Scroll the thread list so row ID shows."
  (when-let* ((runtime (maillist--runtime)))
    (ignore-errors
      (etaf-scroll-into-view
       runtime (intern (concat "maillist-thread-" id))))))

(defun maillist--reveal-message (id)
  "Scroll the reader so message ID shows."
  (when-let* ((runtime (maillist--runtime)))
    (ignore-errors
      (etaf-scroll-into-view
       runtime (intern (concat "maillist-message-" id)) 'start))))

(defun maillist--narrow-p (session)
  "Return non-nil when SESSION's viewport shows one column."
  (< (etaf-value (plist-get session :viewport)) maillist-narrow-width))

(defun maillist--open-row (session id)
  "Open row ID of SESSION and show it."
  (maillist-select session id)
  (maillist--reader-top)
  (maillist--reveal id)
  (when (maillist--narrow-p session)
    (etaf-set-value (plist-get session :reading) t)))

(defun maillist--move-thread (session delta)
  "Move SESSION's selection by DELTA.
In wide mode (or narrow reading mode) open the new row; in narrow list-only
mode move the selection highlight without fetching or marking off-screen."
  (let ((no-open (and (maillist--narrow-p session)
                      (not (etaf-value (plist-get session :reading))))))
    (maillist-move session delta no-open)
    (when-let* ((id (etaf-value (plist-get session :selected))))
      (unless no-open (maillist--reader-top))
      (maillist--reveal id))))

(defun maillist--move-message-key (session delta)
  "Focus the next or previous message in SESSION's open thread and reveal it."
  (let ((before (etaf-value (plist-get session :focused-message)))
        (open (etaf-value (plist-get session :open))))
    (if (not (and open (plist-get open :messages)))
        (maillist--toast session 'info "没有打开的线程" 3)
      (let ((id (maillist-move-message session delta)))
        (cond
         ((null id)
          (maillist--toast session 'info "没有打开的线程" 3))
         ((equal id before)
          (maillist--toast session 'info
                           (if (< delta 0) "已是线程内第一封" "已是线程内最后一封")
                           2))
         (t
          (maillist--reveal-message id)))))))

(defun maillist--toggle-star (session)
  "Toggle star on SESSION's selected thread and show a status notice."
  (if (not (maillist-selected-row session))
      (maillist--toast session 'info "没有选中的线程" 3)
    (let ((starred (maillist-toggle-star session)))
      (maillist--toast session 'info
                       (if starred "已收藏" "已取消收藏")
                       3))))

(defun maillist--load-earlier-key (session)
  "Expand older hidden messages in SESSION's open thread with feedback."
  (let ((open (etaf-value (plist-get session :open))))
    (cond
     ((null open)
      (maillist--toast session 'info "没有打开的线程" 3))
     ((zerop (or (plist-get open :hidden) 0))
      (maillist--toast session 'info "已显示线程内全部邮件" 3))
     (t
      (maillist-load-earlier session)
      (let* ((now (etaf-value (plist-get session :open)))
             (shown (length (plist-get now :messages)))
             (total (or (plist-get now :total) shown)))
        (maillist--toast session 'info
                         (if (>= shown total)
                             (format "已显示全部 %d 封邮件" total)
                           (format "已展开更早邮件（当前显示 %d / %d 封）"
                                   shown total))
                         3))))))

(defun maillist--toggle-all-messages-key (session)
  "Collapse or expand all messages in SESSION's open thread."
  (if (etaf-value (plist-get session :open))
      (let ((collapsed (maillist-toggle-all-messages session)))
        (maillist--toast session 'info
                         (if collapsed "已折叠全部邮件" "已展开全部邮件") 3))
    (maillist--toast session 'info "没有打开的线程" 3)))

(defun maillist--toggle-quotes-key (session)
  "Toggle quote folding in SESSION's reader."
  (let ((folded (maillist-toggle-quotes session)))
    (maillist--toast session 'info
                     (if folded "已折叠长引文" "已展开全部引文") 3)))

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
  "Open another archive for SESSION, or add a new public-inbox source."
  (let* ((add-label "+ 添加新邮件列表…")
         (choices (append (mapcar (lambda (source) (plist-get source :name))
                                  maillist-sources)
                          (list add-label)))
         (choice (completing-read "邮件列表：" choices nil t)))
    (cond
     ((equal choice add-label)
      (let ((added (call-interactively #'maillist-add-source)))
        (when added
          (maillist-open :list (plist-get added :name)))))
     ((and choice
           (not (equal choice (plist-get (plist-get session :source) :name))))
      (maillist-open :list choice)))))

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

(defun maillist--copy-mbox-url (session)
  "Put the downloadable `t.mbox.gz' URL of SESSION's thread on the kill ring."
  (if-let* ((id (etaf-value (plist-get session :selected))))
      (let ((url (maillist-thread-mbox-url session id)))
        (kill-new url)
        (maillist--toast session 'info
                         (format "已复制 mbox 地址（可用 curl -sL | gunzip | git am）：%s" url)
                         7))
    (maillist--toast session 'info "没有选中的线程" 3)))

(defun maillist--target-message-id (session)
  "Return the focused message id of SESSION, or the selected thread id."
  (or (etaf-value (plist-get session :focused-message))
      (etaf-value (plist-get session :selected))))

(defun maillist--copy-message-id (session)
  "Copy the canonical `<Message-ID>' of SESSION's focused message."
  (if-let* ((id (maillist--target-message-id session)))
      (let ((mid (format "<%s>" id)))
        (kill-new mid)
        (maillist--toast session 'info (format "已复制 %s" mid) 5))
    (maillist--toast session 'info "没有选中的邮件" 3)))

(defun maillist--view-raw-message (session)
  "Fetch and display the raw RFC 5322 email for SESSION's focused message."
  (if-let* ((id (maillist--target-message-id session)))
      (progn
        (maillist--toast session 'info "正在获取原始邮件…")
        (maillist--fetch-raw
         session id
         (lambda (result)
           (when (maillist--alive-p session)
             (if-let* ((err (plist-get result :error)))
                 (maillist--toast session 'error (format "获取原始邮件失败：%s" err) 7)
               (maillist--clear-toast session)
               (let ((buf (get-buffer-create (format "*maillist raw: %s*" id))))
                 (with-current-buffer buf
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert (or (plist-get result :ok) ""))
                     (goto-char (point-min)))
                   (view-mode 1))
                 (pop-to-buffer buf)))))))
    (maillist--toast session 'info "没有选中的邮件" 3)))

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
  (if-let* ((id (maillist--reveal-selected (maillist-next-unread session))))
      (progn
        (maillist--reader-top)
        (when (maillist--narrow-p session)
          (etaf-set-value (plist-get session :reading) t))
        id)
    (maillist--toast session 'info "没有更多未读的线程" 4)
    nil))

(defun maillist--prev-unread (session)
  "Open the previous unread thread of SESSION and say so when there is none."
  (if-let* ((id (maillist--reveal-selected (maillist-prev-unread session))))
      (progn
        (maillist--reader-top)
        (when (maillist--narrow-p session)
          (etaf-set-value (plist-get session :reading) t))
        id)
    (maillist--toast session 'info "前面没有更多未读的线程" 4)
    nil))

(defun maillist--select-edge (session edge)
  "Move SESSION to its first or last row, and open it when the reader shows."
  (let ((no-open (and (maillist--narrow-p session)
                      (not (etaf-value (plist-get session :reading))))))
    (when (maillist--reveal-selected (maillist-select-edge session edge no-open))
      (unless no-open (maillist--reader-top)))))

(defun maillist--reveal-selected (id)
  "Scroll the list to row ID and return it."
  (when id
    (maillist--reveal id)
    id))

(defun maillist--keys (session)
  "Return the root key bindings for SESSION."
  (list (list "j" (lambda () (maillist--move-thread session 1)) "下一线程")
        (list "k" (lambda () (maillist--move-thread session -1)) "上一线程")
        (list "n" (lambda () (maillist--next-unread session)) "下一未读")
        (list "p" (lambda () (maillist--prev-unread session)) "上一未读")
        (list "<" (lambda () (maillist--select-edge session 'first)) "第一个线程")
        (list "G" (lambda () (maillist--select-edge session 'last)) "最后一个线程")
        (list "]" (lambda () (maillist--move-message-key session 1)) "线程内下一封")
        (list "[" (lambda () (maillist--move-message-key session -1)) "线程内上一封")
        (list "SPC" (lambda () (maillist--scroll-page session 1)) "正文向下翻页")
        (list "DEL" (lambda () (maillist--scroll-page session -1)) "正文向上翻页")
        (list "S-SPC" (lambda () (maillist--scroll-page session -1)) "正文向上翻页")
        (list "s" (lambda () (maillist--toggle-star session)) "收藏或取消收藏")
        (list "r" (lambda () (maillist-reply session current-prefix-arg))
              "回复邮件（C-u 私回）")
        (list "R" (lambda () (maillist-reply-all session)) "回复全部（抄送作者）")
        (list "c" (lambda () (maillist-compose session)) "写新帖")
        (list "e" (lambda () (maillist--load-earlier-key session)) "展开更早的邮件")
        (list "z" (lambda () (maillist--toggle-all-messages-key session)) "折叠或展开全部邮件")
        (list "Q" (lambda () (maillist--toggle-quotes-key session)) "折叠或展开引文")
        (list "v" (lambda () (maillist--view-raw-message session)) "查看原始邮件与完整头")
        (list "m" (lambda () (maillist--copy-mbox-url session)) "复制线程 mbox 地址")
        (list "w" (lambda () (maillist--copy-message-id session)) "复制 Message-ID")
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
        (list "L" (lambda () (maillist--switch-list session)) "切换或添加邮件列表")
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

(defun maillist--char-pixel-width (window)
  "Return the effective pixel width of one character cell in WINDOW.
Uses `etaf-display-metrics' once mounted so text scaling is honoured."
  (or (when-let* ((runtime (maillist--runtime))
                  (metrics (ignore-errors (etaf-display-metrics runtime))))
        (plist-get metrics :char-width))
      (max 1 (/ (window-body-width window t)
                (max 1 (window-body-width window))))))

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
    :focused-message (plist-get session :focused-message)
    :hide-quotes (plist-get session :hide-quotes)
    :scope (plist-get session :scope)
    :summary (plist-get session :summary)
    :status (plist-get session :status)
    :toast (plist-get session :toast)
    :search-input (plist-get session :search-input)
    :query (plist-get session :query)
    :reading (plist-get session :reading)
    :keys (maillist--keys session)
    :help maillist--help-notes
    :on-select (lambda (id) (maillist--open-row session id))
    :on-message (lambda (id) (maillist-toggle-message session id))
    :on-scope (lambda (value)
                (maillist-set-scope session value)
                (when-let* ((id (etaf-value (plist-get session :selected))))
                  (maillist--reveal id)))
    :on-switch-list (lambda () (maillist--switch-list session))
    :on-search-change (lambda (text) (maillist--search-input-change session text))
    :on-search-submit (lambda (text) (maillist--search-submit session text))
    :on-search-clear (lambda () (maillist--search-clear session))
    :on-back (lambda () (maillist--back session))
    :on-earlier (lambda () (maillist-load-earlier session))
    :on-toggle-quotes (lambda () (maillist--toggle-quotes-key session))
    :on-resize (lambda (pixels)
                 (etaf-set-value (plist-get session :list-width) pixels)
                 (when-let* ((store (plist-get session :store)))
                   (ignore-errors
                     (maillist-store-save-setting
                      "list-width" (number-to-string pixels) store)))))))

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
                  ;; Keep the user's original Emacs theme mode-line.
                  :mode-line t
                  ;; The client paints its own focus; a text cursor would sit
                  ;; on whatever cell point last landed on.
                  :cursor nil
                  :on-fit (lambda (window)
                            (setq-local maillist--session session)
                            (let* ((cols (window-body-width window))
                                   (px (window-body-width window t))
                                   (current (or (etaf-value
                                                 (plist-get session :list-width))
                                                0)))
                              (etaf-batch
                               (etaf-set-value (plist-get session :viewport) cols)
                               (etaf-set-value (plist-get session :viewport-rows)
                                               (window-body-height window))
                               (etaf-set-value (plist-get session :viewport-px) px)
                               (when (zerop current)
                                 (etaf-set-value
                                  (plist-get session :list-width)
                                  (max 240 (* 62 (maillist--char-pixel-width
                                                  window))))))))
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
