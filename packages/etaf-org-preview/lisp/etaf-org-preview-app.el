;;; etaf-org-preview-app.el --- Application shell of etaf-org-preview -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one preview session to the Views.  The
;; `etaf-org-preview-app' Component is the only place that reads the session's
;; reactive sources, so a palette, width or document change repaints the
;; preview in one place.  It also provides the palette tokens to its subtree,
;; so shared ETAF UI Components follow the document colors.
;;
;; `etaf-org-preview-open' opens the session as an ETAF application: the
;; buffer, its root keys, the reading measure and the commands for outline
;; navigation, links, reloading and theming.  A window resize reflows
;; through the framework's viewport update, so the application never rebuilds
;; the document for a geometry change.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-preview-model)
(require 'etaf-org-preview-views)

(defun etaf-org-preview--buffer-name (file)
  "Return the preview buffer name for FILE."
  (format "*ETAF Org: %s*" (file-name-nondirectory file)))

(defconst etaf-org-preview--keys
  '(("n" etaf-org-preview-next-heading "下一个标题")
    ("C-c n" etaf-org-preview-next-heading "下一个标题")
    ("C-c p" etaf-org-preview-previous-heading "上一个标题")
    ("C-c j" etaf-org-preview-goto-heading "选择标题")
    ("C-c C-o" etaf-org-preview-open-link "打开光标处链接")
    ("C-c t" etaf-org-preview-toggle-toc "切换目录")
    ("C-c v" etaf-org-preview-toggle-hidden "显示隐藏内容")
    ("t" etaf-org-preview--cycle-theme-command "切换主题")
    ("[" etaf-org-preview-narrower "缩窄阅读栏")
    ("]" etaf-org-preview-wider "加宽阅读栏")
    ("r" etaf-org-preview-reload "重新加载文档")
    ("C-c h" etaf-help "查看快捷键")
    ("q" etaf-org-preview-close "关闭预览"))
  "Root keys of a preview opened by `etaf-org-preview-open'.
Native scrolling, isearch and RET activation stay available; the keys only add
outline navigation, links, reloading, theming and closing.")

(defun etaf-org-preview--current-session ()
  "Return the preview session of the current buffer."
  (or (etaf-app-state)
      (user-error "Not an ETAF org preview buffer")))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview-next-heading (&optional session)
  "Move point to the next headline.
SESSION defaults to the current preview buffer's session; pass one when
driving a headless mount from a script."
  (interactive)
  (let ((session (or session (etaf-org-preview--current-session))))
    (unless (etaf-org-preview--adjacent-heading session 1)
      (message "No further heading"))))

(defun etaf-org-preview-previous-heading (&optional session)
  "Move point to the previous headline.
SESSION defaults to the current preview buffer's session."
  (interactive)
  (let ((session (or session (etaf-org-preview--current-session))))
    (unless (etaf-org-preview--adjacent-heading session -1)
      (message "No earlier heading"))))

(defun etaf-org-preview-goto-heading ()
  "Choose a headline of the current preview and move to it."
  (interactive)
  (let* ((session (etaf-org-preview--current-session))
         (outline (etaf-org-preview-outline session))
         (candidates
          (cl-loop for entry in outline
                   for index from 0
                   collect (cons (format "%s%s"
                                         (make-string (* 2 (1- (nth 0 entry))) ?\s)
                                         (nth 1 entry))
                                 index))))
    (unless candidates
      (user-error "This document has no headlines"))
    (let ((choice (completing-read "标题：" candidates nil t)))
      (etaf-org-preview-locate session (cdr (assoc choice candidates))))))

(defun etaf-org-preview-open-link ()
  "Activate the link or control at point."
  (interactive)
  (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
    (if runtime
        (etaf-activate runtime)
      (user-error "This buffer has no preview runtime"))))

(defun etaf-org-preview-toggle-toc ()
  "Show or hide the table of contents."
  (interactive)
  (let* ((session (etaf-org-preview--current-session))
         (visible (etaf-value (etaf-org-preview--ref session :toc-visible))))
    (etaf-org-preview-show-toc session (not visible))
    (message "目录：%s" (if visible "隐藏" "显示"))))

(defun etaf-org-preview-toggle-hidden ()
  "Show or hide comments, properties, drawers and metadata."
  (interactive)
  (let* ((session (etaf-org-preview--current-session))
         (hidden (etaf-value (etaf-org-preview--ref session :hidden))))
    (etaf-org-preview-show-hidden session (not hidden))
    (message "隐藏内容：%s" (if hidden "显示" "隐藏"))))

(defun etaf-org-preview--cycle-theme-command ()
  "Switch the preview to the next fixed palette."
  (interactive)
  (let* ((session (etaf-org-preview--current-session))
         (theme (etaf-org-preview-cycle-theme session)))
    (message "主题：%s" theme)))

(defun etaf-org-preview-wider ()
  "Widen the reading measure by four columns."
  (interactive)
  (let* ((session (etaf-org-preview--current-session))
         (width (etaf-org-preview-adjust-width session 4)))
    (message "阅读栏：最多 %d 列" width)))

(defun etaf-org-preview-narrower ()
  "Narrow the reading measure by four columns."
  (interactive)
  (let* ((session (etaf-org-preview--current-session))
         (width (etaf-org-preview-adjust-width session -4)))
    (message "阅读栏：最多 %d 列" width)))

(defun etaf-org-preview-reload ()
  "Re-read and repaint the current preview."
  (interactive)
  (let ((session (etaf-org-preview--current-session)))
    (etaf-org-preview-refresh session)
    (etaf-org-preview--flush session)
    (message "已重新加载 %s" (etaf-org-preview--read session :title))))

(defun etaf-org-preview-close ()
  "Unmount the preview and kill its buffer."
  (interactive)
  (etaf-org-preview--current-session)
  (etaf-app-close))

;;; ---------------------------------------------------------------------------
;;; Window fitting
;;; ---------------------------------------------------------------------------

(defun etaf-org-preview--fit-width (session &optional window)
  "Set SESSION's reading measure from WINDOW, or from the one showing it.
The framework calls this on every window change, so the measure follows a
resize instead of keeping the width the document was opened at."
  (let* ((buffer (plist-get session :buffer))
         (window (or (and (window-live-p window) window)
                     (and (buffer-live-p buffer) (get-buffer-window buffer t)))))
    (if (window-live-p window)
        (let* ((body (window-body-width window))
               (gutter (* 2 etaf-org-preview--measure-gutter))
               (width
                (cond
                 ;; A window that holds the minimum measure and its gutters
                 ;; gets the usual clamp.
                 ((>= body (+ etaf-org-preview-width-min gutter))
                  (min etaf-org-preview-width-max (- body gutter)))
                 ;; Below that the gutters go first, then the measure may
                 ;; shrink under its preferred minimum so the page still
                 ;; reflows instead of scrolling sideways.
                 ((>= body etaf-org-preview-width-min)
                  etaf-org-preview-width-min)
                 (t (max 12 body)))))
          ;; A display change that leaves the window the same size must not
          ;; undo a measure the reader picked with `[' or `]'; only a real
          ;; resize refits.
          (if (equal (plist-get session :fit-body) body)
              (etaf-org-preview--read session :width)
            (plist-put session :fit-body body)
            (etaf-org-preview--write session :width width)
            width))
      (etaf-org-preview--read session :width))))

;;; ---------------------------------------------------------------------------
;;; Application Component and entry points
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-org-preview-app (&key session)
  "Render the org preview for SESSION and own its lifecycle.
SESSION must come from `etaf-org-preview-create'.  Mounting provides the
palette for its subtree; every displayed value is read from the session's
reactive cells, so a refresh, a width change or a theme change repaints the
document without a remount."
  :bindings ((document (etaf-org-preview--ref session :document))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-org-preview-theme-tokens
                         (etaf-org-preview--session-palette session)))
                      :name 'etaf-org-preview-theme-tokens)))
  :setup
  (progn
    (etaf-theme-provide tokens)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme tokens :mode nil
                            :modes etaf-org-preview--surface-modes)))
  :render
  (etaf-org-preview--view-document
   (etaf-value document)
   (etaf-org-preview--env session)))

(defun etaf-org-preview-view (&optional session)
  "Return the preview View for SESSION.
SESSION defaults to a new empty session."
  (etaf-view (etaf-org-preview-app
              :session (or session (etaf-org-preview-create :text "")))))

;;;###autoload
(defun etaf-org-preview-open (&optional source)
  "Open an Org preview and return its buffer.
SOURCE is a file path, a session from `etaf-org-preview-create', or nil to
prompt for a file.  Interactively it defaults to the current buffer's Org file
and then to a file prompt.  A file that already has a preview buffer is
selected instead of rendered twice."
  (interactive
   (list (read-file-name
          "Org file: " nil nil t
          (when (and buffer-file-name
                     (string-match-p "\\.org\\'" buffer-file-name))
            (file-relative-name buffer-file-name default-directory)))))
  (if (and (listp source) (etaf-ref-p (plist-get source :document)))
      (etaf-org-preview--display source
                                 (etaf-org-preview--buffer-name-for-session source))
    (let* ((file (expand-file-name source))
           (name (etaf-org-preview--buffer-name file))
           (existing (get-buffer name)))
      (if (and existing (etaf-app-state existing))
          (switch-to-buffer existing)
        (etaf-org-preview--display (etaf-org-preview-create :file file) name)))))

(defun etaf-org-preview--buffer-name-for-session (session)
  "Return the preview buffer name for SESSION."
  (if-let* ((file (plist-get session :file)))
      (etaf-org-preview--buffer-name file)
    "*ETAF Org*"))

(defun etaf-org-preview--display (session name)
  "Open SESSION as the application buffer NAME and return it."
  (let* ((buffer
          (etaf-app-open
           name
           (etaf-view (etaf-org-preview-app :session session
                                            :keys etaf-org-preview--keys))
           :state session
           :mode-line t
           :background (lambda () (etaf-org-preview--page-background session))
           :on-fit (lambda (window)
                     (plist-put session :buffer (current-buffer))
                     (etaf-org-preview--fit-width session window))
           :on-close (lambda ()
                       (etaf-org-preview--live-unregister session)
                       (etaf-org-preview--follow-unregister
                        (plist-get session :file))
                       (plist-put session :buffer nil)))))
    (plist-put session :buffer buffer)
    (let ((source (and (plist-get session :file)
                       (find-buffer-visiting (plist-get session :file)))))
      (when (and (null source)
                 (derived-mode-p 'org-mode)
                 buffer-file-name
                 (plist-get session :file)
                 (equal (expand-file-name buffer-file-name)
                        (plist-get session :file)))
        (setq source (current-buffer)))
      (etaf-org-preview--live-register session source))
    (etaf-org-preview--follow-register session)
    (with-current-buffer buffer
      (setq-local imenu-create-index-function
                  (lambda ()
                    (let ((outline (etaf-org-preview-outline session)))
                      (cl-loop for entry in outline
                               for position = (etaf-org-preview--position
                                               session (nth 2 entry))
                               when position
                               collect (cons (nth 1 entry) position))))))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

(provide 'etaf-org-preview-app)
;;; etaf-org-preview-app.el ends here
