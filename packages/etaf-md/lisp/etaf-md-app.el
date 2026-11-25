;;; etaf-md-app.el --- Application shell of etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one preview session to the Views.  The
;; `etaf-md-app' Component is the only place that reads the session's
;; reactive sources, so a palette, width or document change repaints the whole
;; preview in one place; it also provides the palette tokens to its subtree so
;; shared ETAF UI Components follow the same colors.
;;
;; `etaf-md-open' opens the session as an ETAF application: the
;; application buffer, its root keys, the initial reading measure, the page
;; background and the commands for outline navigation, reload and theming.  A
;; window resize reflows through the framework's own viewport update, so the
;; application never rebuilds the view for a geometry change.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-md-theme)
(require 'etaf-md-model)
(require 'etaf-md-views)

(defun etaf-md--buffer-name (file)
  "Return the preview buffer name for FILE, disambiguating collisions.
When another live preview already holds `*ETAF Markdown: BASENAME*' for a
different file, includes the parent directory name so two files with the same
basename never overwrite or reuse each other's preview."
  (let* ((canonical (etaf-md--canonical-file file))
         (base (format "*ETAF Markdown: %s*" (file-name-nondirectory file)))
         (existing (get-buffer base))
         (existing-state (and existing (etaf-app-state existing)))
         (existing-file (and existing-state
                             (etaf-md--canonical-file
                              (plist-get existing-state :file)))))
    (if (or (null existing)
            (null existing-file)
            (equal existing-file canonical))
        base
      (let* ((dir (directory-file-name (file-name-directory canonical)))
             (parent (file-name-nondirectory dir))
             (qualified (if (and parent (not (string-empty-p parent)))
                            (format "*ETAF Markdown: %s/%s*"
                                    parent (file-name-nondirectory file))
                          base)))
        (if (let* ((qbuf (get-buffer qualified))
                   (qstate (and qbuf (etaf-app-state qbuf)))
                   (qfile (and qstate
                               (etaf-md--canonical-file
                                (plist-get qstate :file)))))
              (and qbuf qfile (not (equal qfile canonical))))
            (generate-new-buffer-name qualified)
          qualified)))))

(defvar etaf-md--follow-sessions)

(defun etaf-md--find-preview-buffer (file)
  "Return an existing live preview buffer displaying canonical FILE, or nil."
  (let ((canonical (etaf-md--canonical-file file)))
    (or (when-let* ((session (gethash canonical etaf-md--follow-sessions))
                    (buf (plist-get session :buffer))
                    ((buffer-live-p buf)))
          buf)
        (cl-find-if
         (lambda (buf)
           (when-let* ((state (and (buffer-live-p buf) (etaf-app-state buf)))
                       (sfile (plist-get state :file)))
             (equal (etaf-md--canonical-file sfile) canonical)))
         (buffer-list)))))

(declare-function etaf-md--live-refresh "etaf-md-live" (session text &optional dirty-span live-p))
(declare-function etaf-md-assets--compute-symbol "etaf-md-assets" (attrs &optional session))
(declare-function etaf-md-assets--safe-path "etaf-md-assets" (session relpath))
(declare-function etaf-md-assets-open-symbol "etaf-md-assets" (session name))
(declare-function pulse-momentary-highlight-one-line "pulse" (point &optional face))

(defconst etaf-md--keys
  '(("n" etaf-md-next-heading "下一个标题")
    ("p" etaf-md-previous-heading "上一个标题")
    ("C-c j" etaf-md-goto-heading "选择标题")
    ("C-c t" etaf-md-toggle-toc "开关目录侧窗")
    ("S" etaf-md-toggle-spoilers "显示/隐藏所有遮罩")
    ("K" etaf-md-preview-link "预览光标处链接或符号")
    ("e" etaf-md-goto-source "跳回源文档行")
    ("o" etaf-md-goto-source "跳回源文档行")
    ("v" etaf-md-toggle-split "开关双栏对照编辑")
    ("f" etaf-md-follow-scroll "开关滚动跟随")
    ("g" etaf-md-reload "重新加载文档")
    ("r" etaf-md-reload "重新加载文档")
    ("t" etaf-md-cycle-theme "切换主题")
    ("[" etaf-md-narrower "缩窄阅读栏")
    ("]" etaf-md-wider "加宽阅读栏")
    ("C-c h" etaf-help "查看快捷键")
    ("q" etaf-md-close "关闭预览"))
  "Root keys of a preview opened by `etaf-md-open'.
The page is a rendering, so the markdown is edited in its own buffer and these
keys only move around the view.  Native scrolling, isearch and link activation
stay available as they are.")

(defun etaf-md--republish-appearance (&rest _)
  "Republish every preview that follows the Emacs theme.
A picture is drawn for the ink it was published with, so a theme switch changes
what a page needs while its text stays the same: without this the page keeps a
formula drawn in the previous theme's ink, which reads as a blank block when the
two are both light."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when-let* ((session (ignore-errors (etaf-app-state))))
        (when (eq (etaf-md--read session :theme-mode) 'auto)
          (ignore-errors (etaf-md--republish session)))))))

(add-hook 'enable-theme-functions #'etaf-md--republish-appearance)
(when (boundp 'ns-system-appearance-change-functions)
  (add-hook 'ns-system-appearance-change-functions
            #'etaf-md--republish-appearance))

(defun etaf-md--preview-buffer-p (&optional buffer)
  "Return non-nil when BUFFER (defaulting to current) is an active preview."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((state (etaf-app-state)))
          (and (listp state) (etaf-ref-p (plist-get state :document)) t))))))

(defun etaf-md--current-session ()
  "Return the preview session of the current buffer."
  (or (etaf-app-state)
      (user-error "Not an ETAF markdown preview buffer")))

;;; ---------------------------------------------------------------------------
;;; Preview navigation and display actions (buffer-local keys, non-interactive)
;;; ---------------------------------------------------------------------------

(defun etaf-md-next-heading ()
  "Move to the next outline heading of the current preview."
  (let ((session (etaf-md--current-session)))
    (unless (etaf-md--adjacent-heading session 1)
      (message "No further heading"))))

(defun etaf-md-previous-heading ()
  "Move to the previous outline heading of the current preview."
  (let ((session (etaf-md--current-session)))
    (unless (etaf-md--adjacent-heading session -1)
      (message "No earlier heading"))))

(defun etaf-md-goto-heading ()
  "Choose an outline heading of the current preview and move to it."
  (let* ((session (etaf-md--current-session))
         (outline (etaf-md-outline session))
         (candidates
          (cl-loop for entry in outline
                   for index from 0
                   collect (cons (format "%s%s %s"
                                         (make-string (* 2 (1- (nth 0 entry))) ?\s)
                                         (make-string (1+ (nth 0 entry)) ?#)
                                         (nth 1 entry))
                                 index))))
    (unless candidates
      (user-error "This document has no headings"))
    (let ((choice (completing-read "Heading: " candidates nil t)))
      (etaf-md-locate session (cdr (assoc choice candidates))))))

(defun etaf-md-reload ()
  "Re-read and repaint the current preview."
  (let ((session (etaf-md--current-session)))
    (etaf-md-refresh session)
    (message "Reloaded %s" (etaf-md--read session :title))))

(defun etaf-md--source-offset-at-point (session preview-buf pos)
  "Return the 0-based source char offset matching POS in PREVIEW-BUF, or nil.
Uses each block's host bounds and interpolates proportionally by line within
tall blocks so jumping back from inside a long code block or table lands on
the matching line."
  (when-let* ((runtime (and (buffer-live-p preview-buf)
                            (etaf-runtime-for-buffer preview-buf)))
              (entries (plist-get session :entries)))
    (let ((best-entry nil)
          (best-bounds nil)
          (prev-entry nil)
          (prev-bounds nil))
      (dolist (entry entries)
        (unless best-entry
          (when-let* ((ref (plist-get entry :ref))
                      (bounds (etaf-host-ref-bounds runtime ref))
                      (beg (car bounds))
                      (end (cdr bounds)))
            (cond
             ((and (<= beg pos) (<= pos end))
              (setq best-entry entry best-bounds bounds))
             ((< beg pos)
              (setq prev-entry entry prev-bounds bounds))))))
      (let* ((entry (or best-entry prev-entry (car entries)))
             (bounds (or best-bounds prev-bounds))
             (block (and entry (plist-get entry :block)))
             (src-beg (and block (plist-get block :begin)))
             (src-end (and block (plist-get block :end))))
        (when (and (integerp src-beg) (integerp src-end))
          (if (and best-bounds (> (cdr bounds) (car bounds)) (> src-end src-beg))
              (let* ((pbeg (car bounds))
                     (pend (cdr bounds))
                     (p-lines (with-current-buffer preview-buf
                                (max 1 (count-lines pbeg pend))))
                     (p-offset (with-current-buffer preview-buf
                                 (count-lines pbeg (max pbeg (min pend pos)))))
                     (frac (min 1.0 (/ (float p-offset) (float p-lines)))))
                (list src-beg src-end frac))
            (list src-beg src-end 0.0)))))))

(defun etaf-md--source-buffer-for (session)
  "Return a live source buffer for SESSION (opening its file if needed), or nil."
  (let ((file (plist-get session :file)))
    (or (let ((sb (plist-get session :source-buffer)))
          (and (buffer-live-p sb) sb))
        (and file (or (find-buffer-visiting file)
                      (and (file-readable-p file)
                           (find-file-noselect file)))))))

(defun etaf-md--target-pos-in-source (source-buf loc)
  "Return the 1-based line-start position in SOURCE-BUF corresponding to LOC."
  (with-current-buffer source-buf
    (if (null loc)
        (point-min)
      (pcase-let* ((`(,src-beg ,src-end ,frac) loc)
                   (pmin (point-min))
                   (pmax (point-max))
                   (b (max pmin (min pmax (+ pmin src-beg))))
                   (e (max b (min pmax (+ pmin src-end))))
                   (lines (max 1 (count-lines b e)))
                   (step (min (max 0 (1- lines))
                              (round (* frac (max 0 (1- lines)))))))
        (save-excursion
          (goto-char b)
          (when (> step 0) (forward-line step))
          (line-beginning-position))))))

(defun etaf-md-goto-source ()
  "Jump from the current preview point to the matching line in the source file.
Selects the source window when already visible; otherwise switches to the
source buffer in the current window without creating an unexpected split.
Returns the target buffer position, or signals `user-error' when the preview
has no backing source."
  (let* ((session (etaf-md--current-session))
         (preview-buf (current-buffer))
         (pos (point))
         (source-buf (etaf-md--source-buffer-for session)))
    (unless (buffer-live-p source-buf)
      (user-error "This preview has no source file or buffer"))
    (let* ((loc (etaf-md--source-offset-at-point session preview-buf pos))
           (target-pos (etaf-md--target-pos-in-source source-buf loc))
           (win (get-buffer-window source-buf t)))
      (if (window-live-p win)
          (select-window win)
        (switch-to-buffer source-buf))
      (with-current-buffer source-buf
        (goto-char target-pos)
        (recenter)
        (when (require 'pulse nil t)
          (pulse-momentary-highlight-one-line (point))))
      target-pos)))

(defun etaf-md-wider ()
  "Widen the current preview's reading column."
  (let* ((session (etaf-md--current-session))
         (cap (etaf-md-adjust-width session 4)))
    (message "Reading width: %d (max %d)"
             (etaf-md--effective-width session) cap)))

(defun etaf-md-narrower ()
  "Narrow the current preview's reading column."
  (let* ((session (etaf-md--current-session))
         (cap (etaf-md-adjust-width session -4)))
    (message "Reading width: %d (max %d)"
             (etaf-md--effective-width session) cap)))

(defun etaf-md--outline-buffer-name (session)
  "Return the side-window outline buffer name for SESSION."
  (let ((count (length (etaf-md-outline session))))
    (if (> count 0)
        (format "*ETAF Outline* (%d sections)" count)
      "*ETAF Outline*")))

(defun etaf-md--outline-close (session)
  "Close and clean up SESSION's independent Emacs side-window outline."
  (when session
    (when (etaf-md--ref session :toc-open)
      (etaf-md--write session :toc-open nil))
    (when-let* ((buf (plist-get session :toc-buffer)))
      (plist-put session :toc-buffer nil)
      (when (buffer-live-p buf)
        (when-let* ((win (get-buffer-window buf t)))
          (when (and (window-live-p win) (not (one-window-p t)))
            (ignore-errors (delete-window win))))
        (when-let* ((rt (etaf-runtime-for-buffer buf)))
          (ignore-errors (etaf-unmount rt)))
        (ignore-errors (kill-buffer buf))))))

(etaf-define-component etaf-md--outline-app (&key session)
  "Independent side-window outline panel synced with SESSION."
  :setup
  (etaf-theme-provide
   (etaf-computed
    (lambda ()
      (etaf-md-theme-tokens (etaf-md--read session :theme)
                            (etaf-md--session-palette session)))))
  :render
  (let* ((env (etaf-md--env session))
         (outline (etaf-md-outline session))
         (active (or (etaf-md--read session :toc-active) 0))
         (bg (etaf-md--env-color env :bg))
         (ink (etaf-md--env-color env :ink))
         (muted (etaf-md--env-color env :muted))
         (border (etaf-md--env-color env :border))
         (accent (etaf-md--env-color env :accent))
         (accent-soft (etaf-md--env-color env :accent-soft))
         (hover (when (if (plist-member env :link-hover) (plist-get env :link-hover) t)
                  (etaf-md--env-color env :panel2)))
         (min-lv (if outline (apply #'min (mapcar #'car outline)) 1)))
    (etaf-node
     'column
     (list :width '(vw 100)
           :background-color bg
           :color ink
           :padding '((lh 1) (ch 2))
           :item-gap '(lh 0)
           :aria-label "大纲目录")
     (append
      (list
       (etaf-node
        'flex
        (list :width 'stretch :align-items 'center
              :padding-bottom '(lh 1)
              :border-bottom (list '(px 1) 'solid border))
        (list
         (etaf-node 'text (list :font-weight 'bold :color ink)
                    (list "大纲目录"))
         (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil)
         (etaf-node 'text
                    (append
                     (list :color muted :role 'button :tab-index 0 :pointer 'hand
                           :help-echo "关闭大纲侧窗（C-c t 或 q）"
                           :on-press (lambda () (etaf-md--outline-close session)))
                     (when hover (list :hover-style (list :background-color hover))))
                    (list "C-c t 关闭"))))
       (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil))
      (if (null outline)
          (list (etaf-node 'text (list :color muted) (list "（文档暂无标题）")))
        (cl-loop for entry in outline
                 for idx from 0
                 for lv = (nth 0 entry)
                 for text = (nth 1 entry)
                 for is-active = (eql idx active)
                 for indent = (* 2 (max 0 (- lv min-lv)))
                 for target-idx = idx
                 collect
                 (etaf-node
                  'box
                  (append
                   (list :width 'stretch
                         :padding (list '(lh 0) '(ch 1) '(lh 0) (list 'ch (1+ indent)))
                         :wrap-mode 'word)
                   (when is-active
                     (list :background-color accent-soft
                           :border-left (list '(px 2) 'solid accent))))
                  (list
                   (etaf-node
                    'text
                    (append
                     (list :color (cond (is-active ink)
                                        ((= lv min-lv) ink)
                                        (t muted))
                           :font-weight (when (or is-active (= lv min-lv)) 'bold)
                           :role 'link :tab-index 0
                           :pointer (unless is-active 'hand)
                           :aria-selected (when is-active t)
                           :help-echo (format "跳转到 %s" text)
                           :on-press (lambda ()
                                       (etaf-md-locate session target-idx)))
                     (when (and hover (not is-active))
                       (list :hover-style (list :background-color hover))))
                    (list text))))))))))

(defun etaf-md--outline-open (session)
  "Open SESSION's independent Emacs side-window outline on the right."
  (let* ((preview-win (selected-window))
         (preview-buf (window-buffer preview-win))
         (existing (plist-get session :toc-buffer))
         (buf (if (buffer-live-p existing)
                  existing
                (let ((b (save-window-excursion
                           (etaf-app-open
                            (generate-new-buffer-name
                             (etaf-md--outline-buffer-name session))
                            (etaf-view (etaf-md--outline-app :session session))
                            :state session
                            :mode-line t
                            :background (lambda () (etaf-md--page-background session))
                            :on-close (lambda ()
                                        (when (etaf-md--ref session :toc-open)
                                          (etaf-md--write session :toc-open nil))
                                        (plist-put session :toc-buffer nil))))))
                  (with-current-buffer b
                    (let ((map (if (current-local-map)
                                   (copy-keymap (current-local-map))
                                 (make-sparse-keymap))))
                      (define-key map (kbd "q")
                                  (lambda () (interactive)
                                    (etaf-md--outline-close session)))
                      (define-key map (kbd "C-c t")
                                  (lambda () (interactive)
                                    (etaf-md--outline-close session)))
                      (use-local-map map)))
                  (plist-put session :toc-buffer b)
                  b))))
    (etaf-md--write session :toc-open t)
    (when (and (window-live-p preview-win) (buffer-live-p preview-buf))
      (set-window-buffer preview-win preview-buf))
    (display-buffer-in-side-window
     buf '((side . right) (slot . 0) (window-width . 32)
           (preserve-size . (t . nil))))
    (when (window-live-p preview-win)
      (select-window preview-win))
    (when-let* ((rt (etaf-runtime-for-buffer buf)))
      (etaf-runtime-flush rt))
    buf))

(defun etaf-md-toggle-toc (&optional arg)
  "Toggle the side-window TOC outline for the current preview.
With prefix ARG (or interactive prefix argument), open when positive and close
otherwise.  Return new state."
  (let* ((session (etaf-md--current-session))
         (effective (or arg current-prefix-arg))
         (next (if effective (> (prefix-numeric-value effective) 0)
                 (not (etaf-md--read session :toc-open)))))
    (if next
        (etaf-md--outline-open session)
      (etaf-md--outline-close session))
    (message "大纲侧窗：%s" (if next "已打开" "已关闭"))
    (and next t)))

(defun etaf-md-toggle-spoilers (&optional arg)
  "Reveal or hide all `!!spoiler!!' spans in the current preview.
With prefix ARG (or interactive prefix argument), reveal when positive and
hide otherwise.  Return new state."
  (let* ((session (etaf-md--current-session))
         (effective (or arg current-prefix-arg))
         (next (if effective (> (prefix-numeric-value effective) 0)
                 (not (etaf-md--read session :reveal-spoilers)))))
    (etaf-md--write session :reveal-spoilers (and next t))
    (message "所有遮罩内容：%s" (if next "已显示" "已隐藏"))
    (and next t)))

(defun etaf-md--help-at-point ()
  "Return resolved `help-echo' string at point, or nil."
  (let ((help (get-text-property (point) 'help-echo)))
    (cond
     ((stringp help) help)
     ((functionp help)
      (ignore-errors (funcall help (selected-window) (current-buffer) (point)))))))

(defun etaf-md-preview-link ()
  "Preview the link, wiki-link, anchor or Emacs symbol at point in-place.
Calling again while the preview card is open dismisses it if point has no
previewable target.  Returns the preview plist or nil."
  (let* ((session (etaf-md--current-session))
         (help (etaf-md--help-at-point))
         (preview nil))
    (cond
     ;; Emacs symbol chip (`Emacs 符号：NAME（...）')
     ((and (stringp help)
           (string-match "\\`Emacs 符号：\\([^（\n]+\\)" help))
      (let* ((name (string-trim (match-string 1 help)))
             (info (etaf-md-assets--compute-symbol (list :name name)))
             (sig (plist-get info :signature))
             (doc (or (plist-get info :doc)
                      (and (plist-get info :missing) "当前 Emacs 中未定义该符号")
                      "（无文档字符串）")))
        (setq preview
              (list :title (format "ƒ %s" name)
                    :kind (or (plist-get info :kind) "符号")
                    :body (if sig (format "%s\n%s" sig doc) doc)
                    :on-open (lambda () (etaf-md-assets-open-symbol session name))))))
     ;; Wiki-link (`[[target#anchor]]')
     ((and (stringp help)
           (string-match "\\`\\[\\[\\([^]#|]+\\)\\(?:#\\([^]|]+\\)\\)?\\]\\]\\'" help))
      (let* ((raw-target (match-string 1 help))
             (anchor (match-string 2 help))
             (target (string-trim raw-target))
             (dir (or (plist-get session :dir) default-directory))
             (file (cl-find-if #'file-readable-p
                               (list (expand-file-name target dir)
                                     (expand-file-name (concat target ".md") dir)
                                     (expand-file-name (concat target ".markdown") dir))))
             (snippet (if file
                          (with-temp-buffer
                            (insert-file-contents file nil 0 800)
                            (string-trim (buffer-string)))
                        (format "未找到本地文档：%s" target))))
        (setq preview
              (list :title (if anchor (format "%s #%s" target anchor) target)
                    :kind "双链"
                    :body (if (> (length snippet) 360)
                              (concat (substring snippet 0 357) "...")
                            snippet)
                    :on-open (when file (lambda () (etaf-md--open-url session file)))))))
     ;; Anchor link (`#slug')
     ((and (stringp help) (string-prefix-p "#" help))
      (let* ((slug (substring help 1))
             (outline (etaf-md-outline session))
             (idx (cl-position slug outline :key (lambda (e) (nth 2 e)) :test #'equal)))
        (when idx
          (let ((entry (nth idx outline)))
            (setq preview
                  (list :title (nth 1 entry)
                        :kind (format "H%d 锚点" (nth 0 entry))
                        :body (format "文内标题锚点 #%s（点击「打开」跳转）" slug)
                        :on-open (lambda () (etaf-md-locate session idx))))))))
     ;; Local markdown/file link or remote URL
     ((and (stringp help) (not (string-blank-p help)))
      (let* ((clean (car (split-string help "#")))
             (local (and (not (etaf-md--remote-url-p clean))
                         (etaf-md-assets--safe-path session clean))))
        (cond
         ((and local (file-readable-p local) (not (file-directory-p local)))
          (let ((snippet (with-temp-buffer
                           (insert-file-contents local nil 0 800)
                           (string-trim (buffer-string)))))
            (setq preview
                  (list :title (file-name-nondirectory local)
                        :kind "本地文档"
                        :body (if (> (length snippet) 360)
                                  (concat (substring snippet 0 357) "...")
                                snippet)
                        :on-open (lambda () (etaf-md--open-url session help))))))
         ((etaf-md--remote-url-p help)
          (setq preview
                (list :title help
                      :kind "外部链接"
                      :body (format "点击「打开」将在系统浏览器中访问 %s" help)
                      :on-open (lambda () (etaf-md--open-url session help)))))))))
    (if preview
        (progn
          (etaf-md--write session :link-preview preview)
          preview)
      (if (etaf-md--read session :link-preview)
          (progn
            (etaf-md--write session :link-preview nil)
            (message "已关闭链接预览")
            nil)
        (message "光标处没有可预览的链接、双链或符号")
        nil))))

(defun etaf-md--cleanup-source-kill-hook (session)
  "Remove the preview teardown hook from SESSION's source buffer, if live."
  (when-let* ((src (plist-get session :source-buffer))
              ((buffer-live-p src)))
    (with-current-buffer src
      (remove-hook 'kill-buffer-hook #'etaf-md--preview-source-killed t))))

(defun etaf-md-close ()
  "Unmount the current preview, kill its buffer and restore the window cleanly.
When opened in a split created by `etaf-md-preview' or `etaf-md-toggle-split',
removes only that split window so unrelated panes stay intact.  When opened in
a single window via `etaf-md-open', restores the originating buffer in the same
window without deleting it.  Signals `user-error' when the current buffer is
not a preview."
  (let* ((session (etaf-md--current-session))
         (preview-buf (current-buffer))
         (window (or (get-buffer-window preview-buf t) (selected-window)))
         (split-p (and (window-live-p window)
                       (window-parameter window 'etaf-md-preview-split)))
         (source-buf (plist-get session :source-buffer))
         (source-win (and (buffer-live-p source-buf)
                          (get-buffer-window source-buf t)))
         (source-split-p (and (window-live-p source-win)
                              (window-parameter source-win 'etaf-md-source-split)))
         (origin-buf (or (let ((ob (plist-get session :origin-buffer)))
                           (and (buffer-live-p ob)
                                (not (eq ob preview-buf))
                                ob))
                         (and (buffer-live-p source-buf)
                              (not (eq source-buf preview-buf))
                              source-buf))))
    (etaf-md--cleanup-source-kill-hook session)
    (etaf-md--cancel-asset-timer session)
    (etaf-md--outline-close session)
    (etaf-app-close)
    (cond
     ((and (or split-p source-split-p)
           (window-live-p window)
           (not (one-window-p t)))
      (when (window-live-p source-win)
        (set-window-parameter source-win 'etaf-md-source-split nil))
      (ignore-errors (delete-window window)))
     ((and (window-live-p window) (buffer-live-p origin-buf))
      (set-window-buffer window origin-buf)))))

(defun etaf-md-toggle-split ()
  "Toggle between single-window full reading view and side-by-side editing.
From a single-window preview, splits the source buffer on the left synced to
the current line with follow-scroll enabled.  When the source is already shown
beside the preview, collapses back to a full-width reading window.  Returns
non-nil when side-by-side split is active."
  (let* ((session (etaf-md--current-session))
         (preview-buf (current-buffer))
         (preview-win (selected-window))
         (source-buf (etaf-md--source-buffer-for session)))
    (unless (buffer-live-p source-buf)
      (user-error "This preview has no source file or buffer"))
    (let ((src-win (get-buffer-window source-buf)))
      (if (and (window-live-p src-win) (not (eq src-win preview-win)))
          ;; Currently split: collapse back to single-window full preview.
          (let ((was-split (or (window-parameter src-win 'etaf-md-source-split)
                               (window-parameter preview-win 'etaf-md-preview-split))))
            (etaf-md--cleanup-source-kill-hook session)
            (plist-put session :follow-scroll nil)
            (set-window-parameter preview-win 'etaf-md-preview-split nil)
            (set-window-parameter src-win 'etaf-md-source-split nil)
            (when (and was-split (not (one-window-p t)))
              (ignore-errors (delete-window src-win)))
            (when (window-live-p preview-win)
              (select-window preview-win))
            (message "已切回单窗阅读")
            nil)
        ;; Currently single-window: open source buffer on the left beside preview.
        (let* ((loc (etaf-md--source-offset-at-point session preview-buf (point)))
               (target-pos (etaf-md--target-pos-in-source source-buf loc))
               (left-win (split-window preview-win nil 'left)))
          (set-window-parameter left-win 'etaf-md-source-split t)
          (set-window-buffer left-win source-buf)
          (plist-put session :source-buffer source-buf)
          (etaf-md--live-start session source-buf)
          (with-current-buffer source-buf
            (add-hook 'kill-buffer-hook #'etaf-md--preview-source-killed nil t))
          (with-selected-window left-win
            (goto-char target-pos)
            (recenter))
          (plist-put session :follow-scroll t)
          (when (window-live-p preview-win)
            (select-window preview-win))
          (message "已开启双栏对照（再按 v 收起源码，按 e 跳去编辑）")
          t)))))

;;; ---------------------------------------------------------------------------
;;; Window fitting
;;; ---------------------------------------------------------------------------

(defun etaf-md--effective-width (session)
  "Return the reading width the window actually gives SESSION.
The session's `:width' is the maximum measure; a narrower window fills the
available columns instead, so this reports what is on screen outside the
column's side gutters."
  (let* ((buffer (plist-get session :buffer))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (cap (etaf-md--read session :width)))
    (if (window-live-p window)
        (min cap (max 24 (- (window-body-width window)
                            (* 2 etaf-md--measure-gutter))))
      cap)))

;;; ---------------------------------------------------------------------------
;;; Following the source file
;;; ---------------------------------------------------------------------------

(defconst etaf-md--follow-tick 0.016
  "Seconds between a source change and its repaint (one frame at 60 Hz).
A change only schedules a repaint when none is pending, so a burst of
keystrokes coalesces into one repaint per frame.")

(defconst etaf-md--follow-max-wait 0.06
  "Maximum seconds to defer a live repaint while keyboard input is pending.
Yielding when `(input-pending-p)' keeps rapid typing bursts and IME preedit
completely smooth while guaranteeing at least ~16 fps live updates.")

(defconst etaf-md--follow-retry 0.2
  "Seconds between attempts to watch a file that is temporarily missing.")

(defvar etaf-md--follow-sessions (make-hash-table :test #'equal)
  "Displayed preview sessions by canonical source file name.")

(defvar etaf-md--follow-watches (make-hash-table :test #'equal)
  "Change watches by canonical source file name.")

(defvar etaf-md--follow-timers (make-hash-table :test #'equal)
  "Pending repaint timers by canonical source file name.")

(defvar etaf-md--follow-deadlines (make-hash-table :test #'equal)
  "Maximum defer timestamps for pending repaints by canonical file name.")

(defvar etaf-md--live-sources (make-hash-table :test #'equal)
  "Visiting buffers followed for unsaved edits by canonical source file name.")

(defun etaf-md--record-dirty-span (session beg end old-len)
  "Merge an `after-change-functions' edit (BEG END OLD-LEN) into SESSION.
Positions BEG and END are 1-based buffer coordinates in the updated buffer;
accumulates 0-based `(MIN-BEG OLD-END NEW-END)' relative to last published text."
  (let* ((b (max 0 (1- beg)))
         (e (max b (1- end)))
         (prev (plist-get session :dirty-span)))
    (plist-put
     session :dirty-span
     (if (null prev)
         (list b (+ b old-len) e)
       (pcase-let* ((`(,p-beg ,p-old-end ,p-new-end) prev)
                    (min-beg (min p-beg b))
                    (after-old (+ b old-len)))
         (if (<= after-old p-new-end)
             (list min-beg p-old-end (+ p-new-end (- (- e b) old-len)))
           (list min-beg (+ p-old-end (- after-old p-new-end)) e)))))))

(defun etaf-md--live-changed (beg end old-len)
  "Record a source buffer edit (BEG END OLD-LEN) and schedule preview repaint."
  (when buffer-file-name
    (let ((file (etaf-md--canonical-file buffer-file-name)))
      (when-let* ((session (gethash file etaf-md--follow-sessions)))
        (etaf-md--record-dirty-span session beg end old-len)
        (etaf-md--follow-schedule file)))))

(defun etaf-md--live-start (session &optional source-buffer)
  "Make SESSION follow unsaved edits and scrolls of its visiting buffer.
When SOURCE-BUFFER is given, attach directly to it; otherwise look up any
buffer visiting SESSION's canonical or literal file path (resolving symlinks)."
  (when-let* ((path (plist-get session :file))
              (file (etaf-md--canonical-file path))
              (buffer (or (and (buffer-live-p source-buffer) source-buffer)
                          (find-buffer-visiting file)
                          (find-buffer-visiting path))))
    (puthash file buffer etaf-md--live-sources)
    (plist-put session :source-buffer buffer)
    (with-current-buffer buffer
      (plist-put session :live-tick (buffer-chars-modified-tick))
      (add-hook 'after-change-functions #'etaf-md--live-changed nil t)
      (add-hook 'post-command-hook #'etaf-md--follow-scroll-command nil t)
      (add-hook 'window-scroll-functions #'etaf-md--follow-scroll-window nil t))))

(defun etaf-md--live-stop (file)
  "Stop following unsaved edits of FILE and drop its visiting buffer."
  (when-let* ((file (etaf-md--canonical-file file))
              (buffer (gethash file etaf-md--live-sources)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'after-change-functions #'etaf-md--live-changed t)
        (remove-hook 'post-command-hook #'etaf-md--follow-scroll-command t)
        (remove-hook 'window-scroll-functions #'etaf-md--follow-scroll-window t)))
    (remhash file etaf-md--live-sources)))

(defun etaf-md--follow-visit ()
  "Start following the file the buffer just opened, when a preview shows it.
A preview can be opened before its markdown is, and a reader who opens the
file afterwards expects the preview to follow that buffer as they type.  The
hook is buffer-local where it lands, so closing the file takes it away."
  (when-let* ((file (and buffer-file-name
                         (etaf-md--canonical-file buffer-file-name)))
              (session (gethash file etaf-md--follow-sessions)))
    (etaf-md--live-start session (current-buffer))))

(defconst etaf-md--follow-attempts 3
  "Times to retry a watch while its file is missing.
An editor that saves atomically deletes the old file before it renames the
new one over the name, and the watch must be re-armed once the name exists
again; each retry waits `etaf-md--follow-retry'.")

(defun etaf-md--follow-saved ()
  "Repaint the preview of the file being saved, when one is open."
  (when buffer-file-name
    (let ((file (etaf-md--canonical-file buffer-file-name)))
      (when-let* ((session (gethash file etaf-md--follow-sessions)))
        ;; Saving settles any provisional live unclosed fence with exact parse.
        (plist-put session :live-tick nil)
        (plist-put session :dirty-span nil)
        (etaf-md--follow-schedule file t)))))

(defun etaf-md--follow-watch (file)
  "Arm, or re-arm, FILE's change watch and return its descriptor.
Return nil when the file cannot be watched right now, for example because it
is missing; the caller retries.  The watch follows the file's own node, so an
atomic replace leaves it watching a node nothing writes again, and every event
re-arms it."
  (when-let* ((old (gethash file etaf-md--follow-watches)))
    (ignore-errors (file-notify-rm-watch old))
    (remhash file etaf-md--follow-watches))
  (when-let* ((watch
               (condition-case nil
                   (file-notify-add-watch
                    file '(change)
                    (lambda (event)
                      (etaf-md--follow-event file event)))
                 (file-error nil))))
    (puthash file watch etaf-md--follow-watches)
    watch))

(defun etaf-md--follow-event (file event)
  "Repaint FILE's preview for EVENT, and re-arm the watch only when it died."
  (let ((action (nth 1 event)))
    (when (memq action '(changed created renamed))
      (when-let* ((session (gethash file etaf-md--follow-sessions)))
        (plist-put session :live-tick nil)
        (plist-put session :dirty-span nil))
      (etaf-md--follow-schedule file))
    (when (memq action '(stopped deleted))
      (etaf-md--follow-rearm file etaf-md--follow-attempts))))

(defun etaf-md--follow-rearm (file attempts)
  "Watch FILE again, retrying ATTEMPTS times while it is missing."
  (when (gethash file etaf-md--follow-sessions)
    (unless (etaf-md--follow-watch file)
      (when (> attempts 0)
        (run-with-timer etaf-md--follow-retry nil
                        #'etaf-md--follow-rearm file (1- attempts))))))

(defun etaf-md--follow-register (session)
  "Make the displayed SESSION follow its source file.
A session created from text has no file, so it never follows anything."
  (when-let* ((path (plist-get session :file)))
    (let ((file (etaf-md--canonical-file path)))
      (puthash file session etaf-md--follow-sessions)
      (etaf-md--follow-watch file)
      (etaf-md--live-start session)
      ;; The mount already published this text, so a follow that finds it
      ;; unchanged has nothing to repaint.
      (plist-put session :live-text (etaf-md--session-text session))
      (add-hook 'after-save-hook #'etaf-md--follow-saved t)
      (add-hook 'find-file-hook #'etaf-md--follow-visit))))

(defun etaf-md--follow-unregister (file)
  "Stop following FILE: drop its watch, pending repaint and session."
  (when-let* ((file (etaf-md--canonical-file file)))
    (when-let* ((session (gethash file etaf-md--follow-sessions)))
      (etaf-md--cancel-asset-timer session)
      (when-let* ((m (plist-get session :follow-scroll-marker)))
        (when (markerp m) (set-marker m nil))
        (plist-put session :follow-scroll-marker nil))
      (when-let* ((tm (plist-get session :follow-scroll-timer)))
        (when (timerp tm) (cancel-timer tm))
        (plist-put session :follow-scroll-timer nil))
      (plist-put session :follow-scroll-pending nil))
    (etaf-md--live-stop file)
    (when-let* ((watch (gethash file etaf-md--follow-watches)))
      (ignore-errors (file-notify-rm-watch watch))
      (remhash file etaf-md--follow-watches))
    (when-let* ((timer (gethash file etaf-md--follow-timers)))
      (cancel-timer timer)
      (remhash file etaf-md--follow-timers))
    (remhash file etaf-md--follow-deadlines)
    (remhash file etaf-md--follow-sessions)
    (when (zerop (hash-table-count etaf-md--follow-sessions))
      (remove-hook 'after-save-hook #'etaf-md--follow-saved)
      (remove-hook 'find-file-hook #'etaf-md--follow-visit))))

;;; ---------------------------------------------------------------------------
;;; Following the source's scroll
;;; ---------------------------------------------------------------------------

(defun etaf-md--follow-scroll-session ()
  "Return the preview session the current buffer scrolls for, or nil.
Run from the markdown buffer, this is the preview following its file; run from
the preview, it is the preview itself."
  (or (etaf-app-state)
      (and buffer-file-name
           (gethash (etaf-md--canonical-file buffer-file-name)
                    etaf-md--follow-sessions))))

(defun etaf-md-follow-scroll (&optional arg)
  "Toggle scrolling the preview along with its source buffer.
While it is on, scrolling the source window moves the preview proportionally to
the matching block and line.  Only the source's scrolling follows; scrolling
the preview itself stays free.  Run it from the markdown buffer or from its
preview.  With prefix ARG (or interactive prefix argument), turn the follow on
when positive and off otherwise.  Return the new state.  Signal `user-error'
when no preview shows the current buffer."
  (let ((session (or (etaf-md--follow-scroll-session)
                     (user-error "No preview shows the current buffer")))
        (effective (or arg current-prefix-arg)))
    (let ((on (if effective
                  (> (prefix-numeric-value effective) 0)
                (not (plist-get session :follow-scroll)))))
      (plist-put session :follow-scroll (and on t))
      (when-let* ((m (plist-get session :follow-scroll-marker)))
        (when (markerp m) (set-marker m nil)))
      (when-let* ((tm (plist-get session :follow-scroll-timer)))
        (when (timerp tm) (cancel-timer tm)))
      (plist-put session :follow-scroll-timer nil)
      (plist-put session :follow-scroll-pending nil)
      (plist-put session :follow-scroll-marker nil)
      (plist-put session :follow-scroll-line nil)
      (when on
        (etaf-md--follow-scroll-sync session t))
      (message "Preview follows the source scroll: %s" (if on "on" "off"))
      (plist-get session :follow-scroll))))

(defun etaf-md--follow-scroll-command ()
  "Move the current buffer's preview along with its source window.
Runs from the source buffer's `post-command-hook' in O(1) using a buffer
marker so typing bursts never scan line numbers from buffer start."
  (when buffer-file-name
    (when-let* ((session (gethash (etaf-md--canonical-file buffer-file-name)
                                  etaf-md--follow-sessions))
                ((plist-get session :follow-scroll)))
      (etaf-md--follow-scroll-sync session))))

(defun etaf-md--follow-scroll-window (window new-start)
  "Move the preview along when source WINDOW scrolls to NEW-START.
Runs from buffer-local `window-scroll-functions', covering mouse wheel and
trackpad scrolling as well as keyboard commands.  Defers the cross-window
`set-window-start' to a 0-second coalesced timer so it runs outside
`redisplay_internal' and macOS/GUI ports always repaint the unselected
preview window."
  (when (and buffer-file-name (window-live-p window))
    (when-let* ((session (gethash (etaf-md--canonical-file buffer-file-name)
                                  etaf-md--follow-sessions))
                ((plist-get session :follow-scroll)))
      (plist-put session :follow-scroll-pending (cons window new-start))
      (unless (timerp (plist-get session :follow-scroll-timer))
        (plist-put
         session :follow-scroll-timer
         (run-with-timer
          0 nil
          (lambda ()
            (plist-put session :follow-scroll-timer nil)
            (when-let* ((pending (plist-get session :follow-scroll-pending)))
              (plist-put session :follow-scroll-pending nil)
              (when (and (plist-get session :follow-scroll)
                         (window-live-p (car pending)))
                (etaf-md--follow-scroll-sync
                 session nil (car pending) (cdr pending)))))))))))

(defun etaf-md--follow-scroll-same-line-p (source marker pos)
  "Return non-nil when MARKER and POS sit on the same line of SOURCE in O(1)."
  (and (markerp marker)
       (eq (marker-buffer marker) source)
       (let ((mpos (marker-position marker)))
         (and (integerp mpos)
              (or (= mpos pos)
                  (with-current-buffer source
                    (= (save-excursion (goto-char mpos) (line-beginning-position))
                       (save-excursion (goto-char pos) (line-beginning-position)))))))))

(defun etaf-md--follow-scroll-sync (session &optional force source-win start-pos)
  "Scroll SESSION's window to match its source window's visible top line.
When FORCE is non-nil, syncs even if the source line marker did not move.
Interpolates proportionally inside tall blocks and always snaps
`set-window-start' to column 0 of the target row so the left gutter stays
intact."
  (let* ((source (plist-get session :source-buffer))
         (buffer (plist-get session :buffer))
         (source-window (or source-win
                            (and (buffer-live-p source)
                                 (get-buffer-window source t))))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (start (or start-pos (and source-window (window-start source-window)))))
    (when (and start window (buffer-live-p source)
               (eq (window-buffer window) buffer))
      (let ((marker (plist-get session :follow-scroll-marker)))
        (when (or force (not (etaf-md--follow-scroll-same-line-p source marker start)))
          (with-current-buffer source
            (let ((bol (save-excursion (goto-char start) (line-beginning-position))))
              (if (and (markerp marker) (eq (marker-buffer marker) source))
                  (set-marker marker bol)
                (plist-put session :follow-scroll-marker (copy-marker bol)))))
          (let* ((offset (max 0 (1- start)))
                 (match (etaf-md--block-entry-at session offset)))
            (cond
             ((eq match 'top)
              (let ((top (with-current-buffer buffer (point-min))))
                (set-window-start window top nil)
                (set-window-point window top)
                (force-window-update window)
                top))
             ((consp match)
              (let* ((entry (car match))
                     (ref (plist-get entry :ref))
                     (block (plist-get entry :block))
                     (runtime (etaf-runtime-for-buffer buffer))
                     (bounds (and runtime ref (etaf-host-ref-bounds runtime ref)))
                     (position (or (car-safe bounds)
                                   (and runtime ref (etaf-host-ref-position runtime ref)))))
                (when position
                  (let* ((src-beg (plist-get block :begin))
                         (src-end (plist-get block :end))
                         (extra-lines
                          (if (and (consp bounds)
                                   (integerp src-beg) (integerp src-end)
                                   (> offset src-beg) (< offset src-end))
                              (let* ((pmin (with-current-buffer source (point-min)))
                                     (pmax (with-current-buffer source (point-max)))
                                     (sb (max pmin (min pmax (+ pmin src-beg))))
                                     (se (max sb (min pmax (+ pmin src-end))))
                                     (sp (max sb (min se start)))
                                     (src-lines (with-current-buffer source
                                                  (max 1 (count-lines sb se))))
                                     (src-off (with-current-buffer source
                                                (count-lines sb sp)))
                                     (prev-lines (with-current-buffer buffer
                                                   (max 1 (count-lines (car bounds)
                                                                       (cdr bounds))))))
                                (if (> prev-lines 1)
                                    (min (1- prev-lines)
                                         (round (* (/ (float src-off) (float src-lines))
                                                   (1- prev-lines))))
                                  0))
                            0))
                         (row-start
                          (with-current-buffer buffer
                            (save-excursion
                              (goto-char position)
                              (when (> extra-lines 0)
                                (forward-line extra-lines))
                              (line-beginning-position)))))
                    (set-window-start window row-start nil)
                    ;; Keep window-point at the synced row and force a window
                    ;; update so GUI redisplay repaints the unselected preview.
                    (set-window-point window row-start)
                    (force-window-update window)
                    row-start)))))))))))

(defun etaf-md--block-entry-at (session offset)
  "Return `(ENTRY . t)' at 0-based source OFFSET, `top' before block 0, or nil."
  (let ((first nil)
        (last nil)
        (found nil))
    (dolist (entry (plist-get session :entries))
      (let* ((block (plist-get entry :block))
             (begin (plist-get block :begin))
             (end (plist-get block :end)))
        (when (and (not found)
                   (integerp begin)
                   (integerp end))
          (setq first (or first begin))
          (setq last entry)
          (when (< offset end)
            (setq found entry)))))
    (cond ((and first (< offset first)) 'top)
          (found (cons found t))
          (last (cons last t))
          (t nil))))

(defun etaf-md--block-ref-at (session position)
  "Return ref symbol of SESSION's block at 1-based source POSITION, or `top'."
  (let ((match (etaf-md--block-entry-at session (max 0 (1- position)))))
    (cond ((eq match 'top) 'top)
          ((consp match) (plist-get (car match) :ref))
          (t nil))))

(defun etaf-md--follow-schedule (file &optional immediate)
  "Schedule a live repaint for canonical FILE.
Coalesces keystroke bursts onto a 16 ms frame tick and yields while
`(input-pending-p)' up to `etaf-md--follow-max-wait'.  When IMMEDIATE is
non-nil (e.g. on save), clears the defer deadline so exact parsing runs soon."
  (when (gethash file etaf-md--follow-sessions)
    (when immediate
      (puthash file 0 etaf-md--follow-deadlines))
    (unless (gethash file etaf-md--follow-timers)
      (unless (gethash file etaf-md--follow-deadlines)
        (puthash file (+ (float-time) etaf-md--follow-max-wait)
                 etaf-md--follow-deadlines))
      (puthash file
               (run-with-timer etaf-md--follow-tick nil
                               #'etaf-md--follow-repaint file)
               etaf-md--follow-timers))))

(defun etaf-md--follow-repaint (file)
  "Repaint canonical FILE's preview after its source changed.
Defers one frame when keyboard input is pending (up to the burst deadline) so
typing and IME composition never stall."
  (remhash file etaf-md--follow-timers)
  (let ((deadline (or (gethash file etaf-md--follow-deadlines) 0)))
    (if (and (not noninteractive)
             (input-pending-p)
             (< (float-time) deadline))
        (puthash file
                 (run-with-timer etaf-md--follow-tick nil
                                 #'etaf-md--follow-repaint file)
                 etaf-md--follow-timers)
      (remhash file etaf-md--follow-deadlines)
      (when-let* ((session (gethash file etaf-md--follow-sessions))
                  (buffer (plist-get session :buffer))
                  ((buffer-live-p buffer)))
        (condition-case error
            (let* ((source (plist-get session :source-buffer))
                   (live-buf (and (buffer-live-p source) source))
                   (tick (and live-buf
                              (with-current-buffer live-buf
                                (buffer-chars-modified-tick))))
                   (live-p (and live-buf
                                (with-current-buffer live-buf
                                  (buffer-modified-p))))
                   (dirty-span (plist-get session :dirty-span)))
              (plist-put session :dirty-span nil)
              ;; Fast O(1) skip when the source buffer's char tick has not
              ;; moved and no provisional fence needs settling.
              (unless (and tick
                           (eql tick (plist-get session :live-tick))
                           (or live-p (null (plist-get session :provisional-fence-span))))
                (let ((text (etaf-md--session-text session)))
                  (when tick (plist-put session :live-tick tick))
                  (when (or (not (equal text (plist-get session :live-text)))
                            (and (not live-p)
                                 (plist-get session :provisional-fence-span)))
                    (etaf-md--live-refresh session text dirty-span live-p)))))
          (etaf-md-error
           (message "Preview kept its last render: %s"
                    (error-message-string error))))))))

(etaf-define-component etaf-md-app (&key session)
  "Render the markdown preview for SESSION and own its lifecycle.
SESSION must come from `etaf-md-create'.  Mounting provides the palette for its
subtree and subscribes to `:page-structure' rather than raw `:document', so
editing inside an existing block wakes only that block's Component."
  :bindings ((preview (or session
                          (signal 'etaf-md-error
                                  '("etaf-md-app needs the :session from `etaf-md-create'"))))
             (structure (etaf-md--ref preview :page-structure))
             (theme (etaf-md--ref preview :theme))
             (mode (etaf-md--ref preview :theme-mode))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-md-theme-tokens
                         (etaf-value theme)
                         (etaf-md--session-palette preview)))
                      :name 'etaf-md-theme-tokens)))
  :setup
  (progn
    (etaf-theme-provide tokens)
    (when-let* ((rt (etaf-current-runtime))
                (buf (etaf-runtime-buffer rt)))
      (unless (buffer-live-p (plist-get preview :buffer))
        (plist-put preview :buffer buf)
        (etaf-md--schedule-async-assets preview nil)
        (etaf-on-unmounted
         (lambda ()
           (etaf-md--cancel-asset-timer preview)
           (when (eq (plist-get preview :buffer) buf)
             (plist-put preview :buffer nil))))))
    ;; One appearance state: `auto' resolves to the frame's faces, a named
    ;; mode paints its fixed page, and a panel's title-bar switch writes the
    ;; same cell as `t', so the document and the panel chrome follow it.
    (etaf-watch mode
                (lambda (mode _old)
                  (etaf-batch
                    (etaf-md--write preview :theme
                                             (if (eq mode 'auto)
                                                 (etaf-md-auto-theme)
                                               mode))
                    (etaf-md--write preview :theme-source
                                             (if (eq mode 'auto) 'frame 'palette)))
                  ;; The page's pictures are drawn for a palette too, so a
                  ;; switch publishes again to attach the ones it needs.
                  (etaf-md--republish preview))
                :immediate t :name 'etaf-md-mode)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme tokens :mode mode
                            :modes etaf-md--surface-modes)))
  :render
  (etaf-md--view-document
   preview
   (etaf-value structure)
   (etaf-md--env preview)))

(defun etaf-md-view (&optional session)
  "Return the preview View for SESSION.
SESSION defaults to a new session over an empty document; pass a session from
`etaf-md-create' to mount a real one."
  (etaf-view (etaf-md-app
              :session (or session (etaf-md-create :text "")))))

(defun etaf-md--sync-preview-to-source-pos (session source-buf pos)
  "Position SESSION's preview buffer near the block matching POS in SOURCE-BUF."
  (when (and session (buffer-live-p source-buf) (integerp pos))
    (let* ((preview-buf (plist-get session :buffer))
           (win (and (buffer-live-p preview-buf)
                     (get-buffer-window preview-buf t)))
           (offset (max 0 (1- pos)))
           (match (etaf-md--block-entry-at session offset)))
      (when (and (buffer-live-p preview-buf) (consp match))
        (let* ((entry (car match))
               (ref (plist-get entry :ref))
               (runtime (etaf-runtime-for-buffer preview-buf))
               (bounds (and runtime ref (etaf-host-ref-bounds runtime ref)))
               (target (or (car-safe bounds)
                           (and runtime ref (etaf-host-ref-position runtime ref)))))
          (when (integerp target)
            (with-current-buffer preview-buf
              (let ((bol (save-excursion (goto-char target) (line-beginning-position))))
                (goto-char bol)
                (when (window-live-p win)
                  (set-window-point win bol)
                  (with-selected-window win (recenter)))))))))))

;;; `etaf-md' autoloads this command from the entry file, which loads the
;;; typesetter too; a second cookie here would skip it and leave a code block
;;; calling an undefined renderer.
(defun etaf-md-open (&optional source)
  "Open a full-width Markdown reading view in the current window.
SOURCE is a file path, a session from `etaf-md-create', or nil to prompt for a
file.  Interactively, when the current buffer visits a Markdown file and no
prefix argument is given, opens it directly in the current window without
prompting or splitting windows; with a prefix argument (`C-u') or from any
other buffer, prompts for a file.  Reuses an existing preview buffer visiting
the same canonical file and returns the preview buffer."
  (interactive
   (list
    (cond
     (current-prefix-arg
      (read-file-name
       "Markdown file: " nil nil t
       (when (and buffer-file-name
                  (string-match-p etaf-md--markdown-file-regexp buffer-file-name))
         (file-relative-name buffer-file-name default-directory))))
     ((and (etaf-app-state) (etaf-ref-p (plist-get (etaf-app-state) :document)))
      (etaf-app-state))
     ((and buffer-file-name
           (string-match-p etaf-md--markdown-file-regexp buffer-file-name))
      (expand-file-name buffer-file-name))
     (t
      (read-file-name "Markdown file: " nil nil t)))))
  (let* ((origin-buf (current-buffer))
         (origin-pos (point))
         (origin-file (and buffer-file-name
                           (etaf-md--canonical-file buffer-file-name))))
    (if (and (listp source) (etaf-ref-p (plist-get source :document)))
        (let ((existing (plist-get source :buffer)))
          (if (buffer-live-p existing)
              (progn (switch-to-buffer existing) existing)
            (let ((buf (etaf-md--display source
                                         (etaf-md--buffer-name-for-session source))))
              (unless (eq origin-buf buf)
                (plist-put source :origin-buffer origin-buf))
              buf)))
      (let* ((file (etaf-md--canonical-file source))
             (from-source-p (and origin-file (equal origin-file file)))
             (existing (etaf-md--find-preview-buffer file))
             (buf (if existing
                      (progn (switch-to-buffer existing) existing)
                    (etaf-md--display (etaf-md-create :file file)
                                      (etaf-md--buffer-name file)))))
        (when-let* ((session (and (buffer-live-p buf) (etaf-app-state buf))))
          (unless (eq origin-buf buf)
            (plist-put session :origin-buffer origin-buf))
          (when (and from-source-p (> origin-pos 1))
            (etaf-md--sync-preview-to-source-pos session origin-buf origin-pos)))
        buf))))

(defun etaf-md--open-preview-split (source-buf)
  "Open a right-side live preview split beside SOURCE-BUF and return its buffer."
  (let* ((file (etaf-md--canonical-file (buffer-file-name source-buf)))
         (source-win (or (get-buffer-window source-buf) (selected-window)))
         (existing-preview (etaf-md--find-preview-buffer file))
         (existing-win (and existing-preview (get-buffer-window existing-preview)))
         (preview-buf nil))
    (select-window source-win)
    (unless (eq (window-buffer source-win) source-buf)
      (switch-to-buffer source-buf))
    (if (and (window-live-p existing-win) (not (eq existing-win source-win)))
        (setq preview-buf existing-preview)
      (let ((right-win (split-window-right)))
        (set-window-parameter right-win 'etaf-md-preview-split t)
        (select-window right-win)
        (setq preview-buf (etaf-md-open file))))
    (when (window-live-p source-win)
      (select-window source-win))
    (with-current-buffer source-buf
      (add-hook 'kill-buffer-hook #'etaf-md--preview-source-killed nil t))
    (when-let* ((session (and (buffer-live-p preview-buf)
                              (etaf-app-state preview-buf))))
      (plist-put session :follow-scroll t)
      (etaf-md--follow-scroll-sync session t source-win))
    preview-buf))

(defun etaf-md--close-preview-split (source-buf)
  "Close the live preview split attached to SOURCE-BUF, keeping SOURCE-BUF."
  (when-let* ((path (and (buffer-live-p source-buf)
                         (buffer-file-name source-buf)))
              (file (etaf-md--canonical-file path))
              (preview-buf (etaf-md--find-preview-buffer file)))
    (let ((src-win (get-buffer-window source-buf))
          (prev-win (get-buffer-window preview-buf)))
      (when (and (window-live-p src-win)
                 (window-parameter src-win 'etaf-md-source-split)
                 (window-live-p prev-win)
                 (not (eq prev-win src-win)))
        ;; Promote preview-win as the split to delete so source-win survives.
        (set-window-parameter src-win 'etaf-md-source-split nil)
        (set-window-parameter prev-win 'etaf-md-preview-split t))
      (with-current-buffer preview-buf
        (etaf-md-close))
      (when (window-live-p src-win)
        (select-window src-win)))))

(defun etaf-md--preview-source-killed ()
  "Tear down the live preview split when its source buffer is killed."
  (etaf-md--close-preview-split (current-buffer)))

;;; Autoloaded from `etaf-md' for the same reason as `etaf-md-open'.
(defun etaf-md-preview (&optional file)
  "Toggle a live side-by-side ETAF Markdown preview beside the source buffer.
When called from a preview buffer with no FILE, delegates to
`etaf-md-toggle-split'.  Otherwise previews FILE (defaulting to the current
buffer's visited file, or prompting for a file interactively when the buffer
visits none): if a live preview window is already visible beside the source
window, closes it and removes only the split it created; otherwise opens a
non-destructive right split without closing unrelated panes, enables
proportional scroll-follow synced to the current source line, and leaves point
in the source buffer.  Returns the preview buffer when opened, or nil when
closed."
  (interactive
   (list
    (unless (or (etaf-md--preview-buffer-p)
                buffer-file-name)
      (read-file-name "Markdown file: " nil nil t))))
  (if (and (null file) (etaf-md--preview-buffer-p))
      (etaf-md-toggle-split)
    (let* ((source-buf (if file
                           (or (find-buffer-visiting file)
                               (find-file-noselect file))
                         (current-buffer)))
           (path (or file (buffer-file-name source-buf))))
      (unless path
        (user-error "Save this buffer to a file before opening a live preview"))
      (let* ((canonical (etaf-md--canonical-file path))
             (existing-preview (etaf-md--find-preview-buffer canonical))
             (source-win (or (get-buffer-window source-buf) (selected-window)))
             (existing-win (and existing-preview
                                (get-buffer-window existing-preview))))
        (if (and (window-live-p existing-win)
                 (not (eq existing-win source-win)))
            (progn
              (etaf-md--close-preview-split source-buf)
              nil)
          (etaf-md--open-preview-split source-buf))))))

(defun etaf-md--buffer-name-for-session (session)
  "Return the preview buffer name for SESSION."
  (if-let* ((file (plist-get session :file)))
      (etaf-md--buffer-name file)
    "*ETAF Markdown*"))

(defun etaf-md--display (session name)
  "Open SESSION as the application buffer NAME and return that buffer.
The reading measure stays capped at `:width' while stretching cleanly inside
narrower windows, so resizing a split up to a full frame never gets trapped at
the initial split width."
  (let ((buffer
         (etaf-app-open
          name
          (etaf-view (etaf-md-app :session session :keys etaf-md--keys))
          :state session
          :mode-line t
          :background (lambda () (etaf-md--page-background session))
          :on-close (lambda ()
                      (etaf-md--cleanup-source-kill-hook session)
                      (etaf-md--outline-close session)
                      (etaf-md--follow-unregister (plist-get session :file))
                      (plist-put session :buffer nil)))))
    (plist-put session :buffer buffer)
    (etaf-md--follow-register session)
    (etaf-md--schedule-async-assets session nil)
    (add-hook 'kill-buffer-hook
              (lambda ()
                (etaf-md--cleanup-source-kill-hook session)
                (etaf-md--outline-close session)
                (etaf-md--follow-unregister (plist-get session :file)))
              t t)
    (with-current-buffer buffer
      (let ((sync-viewport
             (lambda (&optional _frame-or-win)
               (when-let* ((buf (plist-get session :buffer))
                           ((buffer-live-p buf))
                           (win (get-buffer-window buf t)))
                 (let ((cols (window-body-width win)))
                   (unless (equal cols (etaf-md--read session :viewport-width))
                     (etaf-md--write session :viewport-width cols)))))))
        (add-hook 'window-size-change-functions sync-viewport t t)
        (funcall sync-viewport))
      (setq-local imenu-create-index-function
                  (lambda ()
                    (let ((outline (etaf-md-outline session)))
                      (mapcar (lambda (cell)
                                (cons (nth 1 (nth (car cell) outline))
                                      (cdr cell)))
                              (etaf-md--heading-positions session))))))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

(provide 'etaf-md-app)
;;; etaf-md-app.el ends here
