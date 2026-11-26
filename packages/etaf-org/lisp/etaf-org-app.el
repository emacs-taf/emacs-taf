;;; etaf-org-app.el --- Application shell and reading commands of etaf-org -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds an `etaf-org' session to ETAF Views, window
;; geometry, reading actions, full-width reading (`etaf-org-open'),
;; non-destructive live side-by-side preview (`etaf-org-preview'),
;; single-window <-> split toggle (`v'), reverse source navigation (`e' / `o'),
;; follow-scroll (`f'), independent Emacs right side-window outline (`C-c t'),
;; in-buffer peek (`K'), live section filter (`C-c /'), section folding
;; (`z' / `Z'), and spoiler reveal (`S').
;;
;; Only `etaf-org-open' and `etaf-org-preview' are interactive `M-x' commands;
;; all preview-buffer actions are non-interactive Lisp functions bound via
;; `etaf-org--keys' so `M-x' stays completely clean (matching `etaf-md').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pulse)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-model)
(require 'etaf-org-live)
(require 'etaf-org-views)

(defconst etaf-org--org-file-regexp "\\.org\\'"
  "Filename regexp matching Org-mode documents.")

(defconst etaf-org--keys
  '(("n" etaf-org-next-heading "下一个标题")
    ("p" etaf-org-previous-heading "上一个标题")
    ("C-c n" etaf-org-next-heading "下一个标题")
    ("C-c p" etaf-org-previous-heading "上一个标题")
    ("C-c j" etaf-org-goto-heading "选择标题")
    ("C-c C-o" etaf-org-open-link "打开光标处链接")
    ("K" etaf-org-preview-link "速览光标处链接/脚注/引用")
    ("e" etaf-org-goto-source "跳回 Org 源码行")
    ("o" etaf-org-goto-source "跳回 Org 源码行")
    ("v" etaf-org-toggle-split "开关双栏对照编辑")
    ("f" etaf-org-follow-scroll "开关滚动跟随")
    ("C-c t" etaf-org-toggle-toc "开关目录侧窗")
    ("C-c /" etaf-org-filter "按条件筛选章节")
    ("z" etaf-org-cycle-fold "折叠/展开当前节")
    ("Z" etaf-org-cycle-global-fold "全局折叠/展开")
    ("S" etaf-org-toggle-spoilers "显示/隐藏剧透内容")
    ("C-c v" etaf-org-toggle-hidden "显示/隐藏注释与属性")
    ("t" etaf-org-cycle-theme "切换主题（dark/light/sepia/auto）")
    ("[" etaf-org-narrower "缩窄阅读栏")
    ("]" etaf-org-wider "加宽阅读栏")
    ("g" etaf-org-reload "重新加载文档")
    ("r" etaf-org-reload "重新加载文档")
    ("C-c h" etaf-help "查看快捷键")
    ("q" etaf-org-close "关闭预览"))
  "Root keys of a preview opened by `etaf-org-open' or `etaf-org-preview'.")

(defun etaf-org--republish-appearance (&rest _)
  "Republish every `etaf-org' preview following Emacs appearance (`auto')."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when-let* ((session (ignore-errors (etaf-app-state))))
        (when (and (listp session)
                   (etaf-ref-p (plist-get session :document))
                   (eq (etaf-org--read session :theme-mode) 'auto))
          (ignore-errors (etaf-org--republish session)))))))

(add-hook 'enable-theme-functions #'etaf-org--republish-appearance)
(when (boundp 'ns-system-appearance-change-functions)
  (add-hook 'ns-system-appearance-change-functions
            #'etaf-org--republish-appearance))

(defun etaf-org--preview-buffer-p (&optional buffer)
  "Return non-nil when BUFFER (defaulting to current) is an active preview."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((state (etaf-app-state)))
          (and (listp state)
               (etaf-ref-p (plist-get state :document))
               (not (plist-get state :outline-buffer-p))
               t))))))

(defun etaf-org--current-session ()
  "Return the preview session of the current buffer."
  (let ((state (etaf-app-state)))
    (if (and (listp state) (etaf-ref-p (plist-get state :document)))
        state
      (user-error "Not an ETAF org preview buffer"))))

(defun etaf-org--find-preview-buffer-for-file (file)
  "Return an existing live preview buffer visiting canonical FILE, or nil."
  (when file
    (let ((target (etaf-org--canonical-file file)))
      (or (when-let* ((session (gethash target etaf-org--follow-sessions))
                      (buf (plist-get session :buffer))
                      ((buffer-live-p buf)))
            buf)
          (cl-find-if
           (lambda (buf)
             (when-let* ((st (and (buffer-live-p buf) (etaf-app-state buf)))
                         ((listp st))
                         ((not (plist-get st :outline-buffer-p)))
                         (bf (plist-get st :file)))
               (equal (etaf-org--canonical-file bf) target)))
           (buffer-list))))))

(defun etaf-org--find-preview-buffer-for-source (source-buf)
  "Return an existing live preview buffer tracking SOURCE-BUF, or nil."
  (when (buffer-live-p source-buf)
    (or (when-let* ((file (buffer-file-name source-buf)))
          (etaf-org--find-preview-buffer-for-file file))
        (when-let* ((state (buffer-local-value 'etaf-org--live-state source-buf))
                    (session (plist-get state :session))
                    (buf (plist-get session :buffer))
                    ((buffer-live-p buf)))
          buf))))

(defun etaf-org--buffer-name (file)
  "Return a disambiguated preview buffer name for FILE."
  (let* ((canonical (etaf-org--canonical-file file))
         (base (file-name-nondirectory file))
         (simple (format "*ETAF Org: %s*" base))
         (existing (get-buffer simple))
         (existing-state (and existing (etaf-app-state existing)))
         (existing-file (and (listp existing-state)
                             (plist-get existing-state :file)
                             (etaf-org--canonical-file
                              (plist-get existing-state :file)))))
    (if (or (null existing)
            (null existing-file)
            (equal existing-file canonical))
        simple
      (let* ((parent (file-name-nondirectory
                      (directory-file-name (file-name-directory canonical))))
             (qualified (if (and parent (not (string-empty-p parent)))
                            (format "*ETAF Org: %s/%s*" parent base)
                          simple)))
        (if (let* ((qbuf (get-buffer qualified))
                   (qstate (and qbuf (etaf-app-state qbuf)))
                   (qfile (and (listp qstate)
                               (plist-get qstate :file)
                               (etaf-org--canonical-file
                                (plist-get qstate :file)))))
              (and qbuf qfile (not (equal qfile canonical))))
            (generate-new-buffer-name qualified)
          qualified)))))

(defun etaf-org--buffer-name-for-session (session)
  "Return the preview buffer name for SESSION."
  (if-let* ((file (plist-get session :file)))
      (etaf-org--buffer-name file)
    (if-let* ((title (etaf-org--read session :title))
              ((and (stringp title) (not (string-blank-p title)))))
        (format "*ETAF Org: %s*" title)
      "*ETAF Org*")))

(defun etaf-org--source-buffer-for (session)
  "Return a live source buffer for SESSION (opening its file if needed), or nil."
  (let ((file (plist-get session :file)))
    (or (let ((sb (plist-get session :source-buffer)))
          (and (buffer-live-p sb) sb))
        (and file (or (find-buffer-visiting file)
                      (and (file-readable-p file)
                           (find-file-noselect file)))))))

;;; ---------------------------------------------------------------------------
;;; Independent Emacs Right Side-Window Outline (`*ETAF Org Outline*')
;;; ---------------------------------------------------------------------------

(defun etaf-org--outline-buffer-name (_session)
  "Return the side-window outline buffer name for SESSION."
  "*ETAF Org Outline*")

(defun etaf-org--outline-close (session)
  "Close and clean up SESSION's independent Emacs side-window outline."
  (when session
    (when (etaf-org--ref session :toc-open)
      (etaf-org--write session :toc-open nil))
    (when-let* ((buf (plist-get session :toc-buffer)))
      (plist-put session :toc-buffer nil)
      (when (buffer-live-p buf)
        (when-let* ((win (get-buffer-window buf t)))
          (when (and (window-live-p win) (not (one-window-p t)))
            (ignore-errors (delete-window win))))
        (when-let* ((rt (etaf-runtime-for-buffer buf)))
          (ignore-errors (etaf-unmount rt)))
        (ignore-errors (kill-buffer buf))))))

(etaf-define-component etaf-org--outline-app (&key session)
  "Independent side-window outline panel synced with SESSION."
  :bindings ((tokens (etaf-computed
                      (lambda ()
                        (etaf-org-theme-tokens
                         (etaf-org--session-palette session)))
                      :name 'etaf-org-outline-tokens)))
  :setup
  (etaf-theme-provide tokens)
  :render
  (let* ((env (etaf-org--env session))
         (outline (etaf-org-outline session))
         (active-id (or (etaf-org--read session :active-section)
                        (nth 2 (car outline))))
         (bg (etaf-org--env-color env :bg))
         (ink (etaf-org--env-color env :ink))
         (muted (etaf-org--env-color env :muted))
         (border (etaf-org--env-color env :border))
         (accent (etaf-org--env-color env :accent))
         (accent-soft (etaf-org--env-color env :accent-soft))
         (hover (etaf-org--hover-fill env 'soft))
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
                     (list :color muted :role 'button :tab-index 0
                           :pointer 'hand
                           :help-echo "关闭大纲侧窗（C-c t 或 q）"
                           :on-press (lambda ()
                                       (etaf-org--outline-close session)))
                     (when hover
                       (list :hover-style (list :background-color hover))))
                    (list "C-c t 关闭"))))
       (etaf-node 'box (list :width 'stretch :height '(lh 1)) nil))
      (if (null outline)
          (list (etaf-node 'text (list :color muted) (list "（文档暂无标题）")))
        (cl-loop for entry in outline
                 for idx from 0
                 for lv = (nth 0 entry)
                 for text = (nth 1 entry)
                 for id = (nth 2 entry)
                 for is-active = (equal id active-id)
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
                                       (etaf-org-locate session target-idx)))
                     (when (and hover (not is-active))
                       (list :hover-style (list :background-color hover))))
                    (list text))))))))))

(defun etaf-org--outline-open (session)
  "Open SESSION's independent Emacs side-window outline on the right."
  (etaf-org--sync-active-section session t)
  (let* ((preview-win (selected-window))
         (preview-buf (window-buffer preview-win))
         (existing (plist-get session :toc-buffer))
         (buf (if (buffer-live-p existing)
                  existing
                (let* ((base (etaf-org--outline-buffer-name session))
                       (name (if (get-buffer base)
                                 (generate-new-buffer-name base)
                               base))
                       (b (save-window-excursion
                            (etaf-app-open
                             name
                             (etaf-view (etaf-org--outline-app :session session))
                             :state (list :outline-buffer-p t :session session)
                             :mode-line t
                             :background (lambda ()
                                           (etaf-org--page-background session))
                             :on-close (lambda ()
                                         (when (etaf-org--ref session :toc-open)
                                           (etaf-org--write session :toc-open nil))
                                         (plist-put session :toc-buffer nil))))))
                  (with-current-buffer b
                    (let ((map (if (current-local-map)
                                   (copy-keymap (current-local-map))
                                 (make-sparse-keymap))))
                      (define-key map (kbd "q")
                                  (lambda () (interactive)
                                    (etaf-org--outline-close session)))
                      (define-key map (kbd "C-c t")
                                  (lambda () (interactive)
                                    (etaf-org--outline-close session)))
                      (use-local-map map)))
                  (plist-put session :toc-buffer b)
                  b))))
    (etaf-org--write session :toc-open t)
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

(defun etaf-org-toggle-toc (&optional arg)
  "Toggle the independent right side-window outline `*ETAF Org Outline*'.
With ARG, open when positive and close otherwise.  Return non-nil when
the side window is open and nil when closed."
  (let* ((session (etaf-org--current-session))
         (next (if arg
                   (> (prefix-numeric-value arg) 0)
                 (not (etaf-org--read session :toc-open)))))
    (if next
        (etaf-org--outline-open session)
      (etaf-org--outline-close session))
    (message "大纲侧窗：%s" (if next "已打开" "已关闭"))
    (and next t)))

;;; ---------------------------------------------------------------------------
;;; Preview navigation and display actions (buffer-local keys, non-interactive)
;;; ---------------------------------------------------------------------------

(defun etaf-org-next-heading (&optional session)
  "Move point to the next headline of SESSION or current preview."
  (let ((session (or session (etaf-org--current-session))))
    (unless (etaf-org--adjacent-heading session 1)
      (message "No further heading"))))

(defun etaf-org-previous-heading (&optional session)
  "Move point to the previous headline of SESSION or current preview."
  (let ((session (or session (etaf-org--current-session))))
    (unless (etaf-org--adjacent-heading session -1)
      (message "No earlier heading"))))

(defun etaf-org-goto-heading ()
  "Choose a headline of the current preview and move to it."
  (let* ((session (etaf-org--current-session))
         (outline (etaf-org-outline session))
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
      (etaf-org-locate session (cdr (assoc choice candidates))))))

(defun etaf-org-open-link ()
  "Activate the link or control at point."
  (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
    (if runtime
        (etaf-activate runtime)
      (user-error "This buffer has no preview runtime"))))

(defun etaf-org-preview-link (&optional session)
  "Open or dismiss the in-buffer peek card (`K') at point in SESSION."
  (let ((session (or session (etaf-org--current-session))))
    (etaf-org--peek-at-point session)
    (etaf-org--flush session)))

(defvar etaf-org--pulse-clear-timer nil
  "One-shot timer clearing a non-pulsing highlight overlay on TTY frames.")

(defun etaf-org--pulse-line (pos)
  "Momentarily highlight the line at POS, auto-clearing on TTY frames too.
On terminal frames where `pulse' cannot fade out on its own timer, schedule a
matching one-shot cleanup timer so TTY and GUI frames behave consistently."
  (when (timerp etaf-org--pulse-clear-timer)
    (cancel-timer etaf-org--pulse-clear-timer)
    (setq etaf-org--pulse-clear-timer nil))
  (when (and (require 'pulse nil t)
             (not (eq (bound-and-true-p pulse-flag) 'never)))
    (pulse-momentary-highlight-one-line pos)
    (when (and (bound-and-true-p pulse-momentary-overlay)
               (memq #'pulse-momentary-unhighlight pre-command-hook))
      (let* ((ov pulse-momentary-overlay)
             (delay (max 0.25 (* (or (bound-and-true-p pulse-delay) 0.03)
                                 (or (bound-and-true-p pulse-iterations) 10)))))
        (setq etaf-org--pulse-clear-timer
              (run-at-time
               delay nil
               (lambda ()
                 (setq etaf-org--pulse-clear-timer nil)
                 (when (eq (bound-and-true-p pulse-momentary-overlay) ov)
                   (pulse-momentary-unhighlight)))))))))

(defun etaf-org-goto-source (&optional session)
  "Jump from preview point to the matching line in the Org source (`e'/`o').
Selects the source window when already visible; otherwise switches to the
source buffer in the current window without creating an unexpected split."
  (let* ((session (or session (etaf-org--current-session)))
         (line (etaf-org--source-line-at-point session))
         (src (etaf-org--source-buffer-for session)))
    (unless (buffer-live-p src)
      (user-error "此会话没有关联的 Org 源码文件或 buffer"))
    (let ((win (get-buffer-window src t)))
      (if (window-live-p win)
          (select-window win)
        (switch-to-buffer src))
      (with-current-buffer src
        (goto-char (point-min))
        (forward-line (max 0 (1- line)))
        (recenter)
        (etaf-org--pulse-line (point)))
      line)))

(defun etaf-org-follow-scroll (&optional arg)
  "Toggle proportional follow-scroll synchronization (`f').
Works from either the preview buffer or its source Org buffer.  With
ARG, turn follow on when positive and off otherwise (programmatic callers may
also pass a session plist).  Return the new boolean state."
  (let* ((session-arg (and (listp arg) (etaf-ref-p (plist-get arg :document)) arg))
         (session (or session-arg
                      (etaf-org--follow-scroll-session)
                      (user-error "当前缓冲区没有关联的 Org 预览")))
         (next (if (and arg (not session-arg))
                   (> (prefix-numeric-value arg) 0)
                 (not (plist-get session :follow-scroll)))))
    (etaf-org--set-follow-scroll session next)
    (message "跟随滚动：%s" (if next "开启" "关闭"))
    next))

(defun etaf-org-filter (&optional query session)
  "Filter visible sections (`C-c /') by TODO, :tag:, #A, or text.
When QUERY is nil, prompt in the minibuffer; pass an empty string to clear."
  (let* ((session (or session (etaf-org--current-session)))
         (query (if (null query)
                    (read-string "筛选章节（如 TODO :work: #A 关键词，留空清除）："
                                 (or (etaf-org--read session :filter) ""))
                  query)))
    (etaf-org-set-filter session query)
    (etaf-org--flush session)
    (if (and (stringp query) (not (string-blank-p query)))
        (message "已筛选：%s" (string-trim query))
      (message "已清除筛选"))))

(defun etaf-org-cycle-fold (&optional session)
  "Cycle fold state (`folded' -> `children' -> `open') of current section."
  (let* ((session (or session (etaf-org--current-session)))
         (id (or (etaf-org--reading-section session)
                 (nth 2 (car (etaf-org-outline session))))))
    (if id
        (let ((next (etaf-org--toggle-fold session id)))
          (etaf-org--flush session)
          (message "章节折叠：%s" next))
      (message "文档中没有章节"))))

(defun etaf-org-cycle-global-fold (&optional session)
  "Cycle global fold state between `overview' and `content' (`Z')."
  (let* ((session (or session (etaf-org--current-session)))
         (next (etaf-org--cycle-global session)))
    (etaf-org--flush session)
    (message "全局视图：%s" (if (eq next 'overview) "大纲概览" "全部展开"))))

(defun etaf-org-toggle-spoilers (&optional session)
  "Toggle global visibility of `!!spoiler!!' and `[[spoiler:...]]' masks (`S')."
  (let* ((session (or session (etaf-org--current-session)))
         (next (not (etaf-org--read session :spoilers-revealed))))
    (etaf-org--write session :spoilers-revealed next)
    (etaf-org--flush session)
    (message "剧透内容：%s" (if next "已全部显示" "已重新隐藏"))
    next))

(defun etaf-org-toggle-hidden ()
  "Show or hide comments, properties, drawers and metadata (`C-c v')."
  (let* ((session (etaf-org--current-session))
         (hidden (etaf-org--read session :hidden)))
    (etaf-org-show-hidden session (not hidden))
    (message "隐藏内容：%s" (if hidden "隐藏" "显示"))))

(defun etaf-org-wider ()
  "Widen the reading measure by four columns (`]')."
  (let* ((session (etaf-org--current-session))
         (width (etaf-org-adjust-width session 4)))
    (message "阅读栏：最多 %d 列" width)))

(defun etaf-org-narrower ()
  "Narrow the reading measure by four columns (`[')."
  (let* ((session (etaf-org--current-session))
         (width (etaf-org-adjust-width session -4)))
    (message "阅读栏：最多 %d 列" width)))

(defun etaf-org-reload ()
  "Re-read and repaint the current preview (`g' / `r')."
  (let ((session (etaf-org--current-session)))
    (etaf-org-refresh session)
    (etaf-org--flush session)
    (message "已重新加载 %s" (etaf-org--read session :title))))

;;; ---------------------------------------------------------------------------
;;; Split management, `etaf-org-close', `etaf-org-toggle-split', `etaf-org-preview'
;;; ---------------------------------------------------------------------------

(defun etaf-org--cleanup-source-kill-hook (session)
  "Remove our source kill-buffer hook registered for SESSION."
  (when-let* ((src (plist-get session :source-buffer))
              ((buffer-live-p src)))
    (with-current-buffer src
      (remove-hook 'kill-buffer-hook #'etaf-org--preview-source-killed t))))

(defun etaf-org-close ()
  "Unmount preview, close its outline side window and restore windows cleanly.
When opened in a split created by `etaf-org-preview' or `etaf-org-toggle-split',
removes only that split window so unrelated panes stay intact.  When opened in
a single window via `etaf-org-open', restores the originating buffer in place
without deleting the window."
  (let* ((session (etaf-org--current-session))
         (preview-buf (current-buffer))
         (window (or (get-buffer-window preview-buf t) (selected-window)))
         (split-p (and (window-live-p window)
                       (window-parameter window 'etaf-org-preview-split)))
         (source-buf (plist-get session :source-buffer))
         (source-win (and (buffer-live-p source-buf)
                          (get-buffer-window source-buf t)))
         (source-split-p (and (window-live-p source-win)
                              (window-parameter source-win 'etaf-org-source-split)))
         (origin-buf (or (let ((ob (plist-get session :origin-buffer)))
                           (and (buffer-live-p ob)
                                (not (eq ob preview-buf))
                                ob))
                         (and (buffer-live-p source-buf)
                              (not (eq source-buf preview-buf))
                              source-buf))))
    (etaf-org--cleanup-source-kill-hook session)
    (etaf-org--set-follow-scroll session nil)
    (etaf-org--outline-close session)
    (etaf-app-close)
    (cond
     ((and (or split-p source-split-p)
           (window-live-p window)
           (not (one-window-p t)))
      (when (window-live-p source-win)
        (set-window-parameter source-win 'etaf-org-source-split nil))
      (ignore-errors (delete-window window)))
     ((and (window-live-p window) (buffer-live-p origin-buf))
      (set-window-buffer window origin-buf)))))

(defun etaf-org-toggle-split ()
  "Toggle single-window full reading view and side-by-side editing (`v').
From a single-window preview, splits the source buffer on the left synced to
the current line with follow-scroll enabled.  When the source is already shown
beside the preview, collapses back to a full-width reading window.  Returns
non-nil when side-by-side split is active."
  (let* ((session (etaf-org--current-session))
         (preview-win (selected-window))
         (source-buf (etaf-org--source-buffer-for session)))
    (unless (buffer-live-p source-buf)
      (user-error "此会话没有关联的 Org 源码文件或 buffer"))
    (let ((src-win (get-buffer-window source-buf)))
      (if (and (window-live-p src-win) (not (eq src-win preview-win)))
          ;; Currently split: collapse back to single-window full preview.
          (let ((was-split (or (window-parameter src-win 'etaf-org-source-split)
                               (window-parameter preview-win 'etaf-org-preview-split))))
            (etaf-org--cleanup-source-kill-hook session)
            (etaf-org--set-follow-scroll session nil)
            (set-window-parameter preview-win 'etaf-org-preview-split nil)
            (set-window-parameter src-win 'etaf-org-source-split nil)
            (when (and was-split (not (one-window-p t)))
              (ignore-errors (delete-window src-win)))
            (when (window-live-p preview-win)
              (select-window preview-win)
              (etaf-org--fit-width session preview-win)
              (etaf-org--flush session))
            (message "已切回单窗阅读")
            nil)
        ;; Currently single-window: open source buffer on the left beside preview.
        (let* ((line (etaf-org--source-line-at-point session))
               (left-win (split-window preview-win nil 'left)))
          (set-window-parameter left-win 'etaf-org-source-split t)
          (set-window-buffer left-win source-buf)
          (etaf-org--live-register session source-buf)
          (with-current-buffer source-buf
            (add-hook 'kill-buffer-hook #'etaf-org--preview-source-killed nil t))
          (with-selected-window left-win
            (goto-char (point-min))
            (forward-line (max 0 (1- line)))
            (recenter))
          (etaf-org--set-follow-scroll session t)
          (when (window-live-p preview-win)
            (select-window preview-win)
            (etaf-org--fit-width session preview-win)
            (etaf-org--flush session))
          (message "已开启双栏对照（再按 v 收起源码，按 e 跳去编辑）")
          t)))))

;;; ---------------------------------------------------------------------------
;;; Window fitting
;;; ---------------------------------------------------------------------------

(defun etaf-org--realign-after-resize (session window anchor-line)
  "Keep Org preview WINDOW aligned with its source or prior ANCHOR-LINE."
  (let* ((buf (plist-get session :buffer))
         (src (plist-get session :source-buffer))
         (swin (and (plist-get session :follow-scroll)
                    (buffer-live-p src)
                    (get-buffer-window src t))))
    (cond
     ((window-live-p swin)
      (etaf-org--sync-preview-scroll session t swin))
     ((and (integerp anchor-line) (buffer-live-p buf) (window-live-p window)
           (eq (window-buffer window) buf))
      (when-let* ((target (etaf-org--position-for-source-line session anchor-line)))
        (with-current-buffer buf
          (let ((bol (save-excursion (goto-char target) (line-beginning-position))))
            (set-window-start window bol nil)
            (set-window-point window bol)
            (when (eq (current-buffer) buf) (goto-char bol))
            (force-window-update window))))))))

(defun etaf-org--fit-width (session &optional window)
  "Fit SESSION's `:viewport-width' and reading measure to WINDOW."
  (let* ((buffer (plist-get session :buffer))
         (window (or (and (window-live-p window) window)
                     (and (buffer-live-p buffer) (get-buffer-window buffer t)))))
    (if (window-live-p window)
        (let* ((body (window-body-width window))
               (prev-body (plist-get session :fit-body))
               (gutter (* 2 etaf-org--measure-gutter))
               (width
                (cond
                 ((>= body (+ etaf-org-width-min gutter))
                  (min etaf-org-width-max (- body gutter)))
                 ((>= body etaf-org-width-min)
                  etaf-org-width-min)
                 (t (max 12 body))))
               (rt (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
               (anchor-line (plist-get session :resize-anchor-line)))
          (etaf-org--write session :viewport-width body)
          (plist-put session :resize-anchor-line nil)
          (prog1
              (if (equal prev-body body)
                  (etaf-org--read session :width)
                (plist-put session :fit-body body)
                (etaf-org--write session :width width)
                width)
            (when (and rt (etaf-runtime-mounted-p rt)
                       (or (and prev-body (not (equal prev-body body)))
                           anchor-line))
              (etaf-next-tick
               (lambda ()
                 (when (and (buffer-live-p buffer) (window-live-p window)
                            (eq (window-buffer window) buffer))
                   (etaf-org--realign-after-resize session window anchor-line)))))))
      (etaf-org--read session :width))))

;;; ---------------------------------------------------------------------------
;;; Application Component & Entry Points
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-org-app (&key session)
  "Render the Org preview for SESSION and own its theme surface."
  :bindings ((document (etaf-org--ref session :document))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-org-theme-tokens
                         (etaf-org--session-palette session)))
                      :name 'etaf-org-theme-tokens)))
  :setup
  (progn
    (etaf-theme-provide tokens)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme tokens :mode nil
                            :modes etaf-org--surface-modes))
    (when-let* ((rt (etaf-current-runtime)))
      (etaf-watch-effect
       (lambda ()
         (when (etaf-runtime-mounted-p rt)
           (let* ((vp (etaf-runtime-viewport rt))
                  (vw (car-safe vp))
                  (prev-vw (plist-get session :last-canvas-width)))
             (plist-put session :last-canvas-width vw)
             (when (and prev-vw vw (not (equal vw prev-vw)))
               (etaf-next-tick
                (lambda ()
                  (when-let* ((buf (plist-get session :buffer))
                              ((buffer-live-p buf))
                              (win (get-buffer-window buf t)))
                    (let ((anchor (plist-get session :resize-anchor-line)))
                      (plist-put session :resize-anchor-line nil)
                      (etaf-org--realign-after-resize session win anchor)))))))))
       :name 'etaf-org-viewport-realign)))
  :render
  (etaf-org--view-document
   (etaf-value document)
   (etaf-org--env session)))

(defun etaf-org-view (&optional session)
  "Return the preview View for SESSION (defaulting to a fresh empty session).
Not an interactive command; pass a session from `etaf-org-create' to embed an
Org document in any ETAF layout via `etaf-mount'."
  (etaf-view (etaf-org-app
              :session (or session (etaf-org-create :text "")))))

(defun etaf-org--sync-preview-to-source-line (session line)
  "Position SESSION's preview buffer near 1-based source LINE."
  (when (and session (integerp line) (> line 1))
    (let* ((preview-buf (plist-get session :buffer))
           (win (and (buffer-live-p preview-buf)
                     (get-buffer-window preview-buf t)))
           (target (etaf-org--position-for-source-line session line)))
      (when (and (buffer-live-p preview-buf) (integerp target))
        (with-current-buffer preview-buf
          (let ((bol (save-excursion (goto-char target) (line-beginning-position))))
            (goto-char bol)
            (when (window-live-p win)
              (set-window-point win bol)
              (with-selected-window win (recenter)))))))))

(defun etaf-org--display (session name &optional source-buffer)
  "Mount SESSION into application buffer NAME (linked to SOURCE-BUFFER)."
  (let* ((cleanup (lambda ()
                    (etaf-org--cleanup-source-kill-hook session)
                    (etaf-org--outline-close session)
                    (etaf-org--set-follow-scroll session nil)
                    (etaf-org--live-unregister session)
                    (etaf-org--follow-unregister (plist-get session :file))
                    (plist-put session :buffer nil)))
         (buffer
          (etaf-app-open
           name
           (etaf-view (etaf-org-app :session session
                                    :keys etaf-org--keys))
           :state session
           :mode-line t
           :background (lambda () (etaf-org--page-background session))
           :on-fit (lambda (window)
                     (plist-put session :buffer (current-buffer))
                     (etaf-org--fit-width session window))
           :on-close cleanup)))
    (plist-put session :buffer buffer)
    (let ((source (or (and (buffer-live-p source-buffer) source-buffer)
                      (and (plist-get session :file)
                           (find-buffer-visiting (plist-get session :file))))))
      (when (and (null source)
                 (derived-mode-p 'org-mode)
                 buffer-file-name
                 (plist-get session :file)
                 (equal (etaf-org--canonical-file buffer-file-name)
                        (etaf-org--canonical-file (plist-get session :file))))
        (setq source (current-buffer)))
      (etaf-org--live-register session source))
    (etaf-org--follow-register session)
    (etaf-org--request-async-assets session)
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook cleanup t t)
      (add-hook 'window-size-change-functions
                (lambda (&optional _frame-or-win)
                  (when-let* ((buf (plist-get session :buffer))
                              ((buffer-live-p buf))
                              (win (get-buffer-window buf t)))
                    (let ((cols (window-body-width win)))
                      (when (and (null (plist-get session :resize-anchor-line))
                                 (not (equal cols (plist-get session :fit-body))))
                        (plist-put session :resize-anchor-line
                                   (with-current-buffer buf
                                     (save-excursion
                                       (goto-char (window-start win))
                                       (etaf-org--source-line-at-point session))))))))
                -10 t)
      (add-hook 'post-command-hook
                (lambda () (etaf-org--sync-active-section session))
                nil t)
      (setq-local imenu-create-index-function
                  (lambda ()
                    (let ((outline (etaf-org-outline session)))
                      (cl-loop for entry in outline
                               for position = (etaf-org--position session (nth 2 entry))
                               when position
                               collect (cons (nth 1 entry) position))))))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

;;; Autoloaded from `etaf-org.el' so the full package loads before first call.
(defun etaf-org-open (&optional source)
  "Open a full-width Org reading view in the current window.
SOURCE is a file path, a session from `etaf-org-create', or nil to prompt.
Interactively, when the current buffer visits an `.org' file (or is an
`org-mode' buffer) and no prefix argument is given, opens it directly in the
current window without prompting or splitting, synced to the current source
line; with `C-u' or from any non-Org buffer, prompts for a file.  Reuses an
existing preview buffer visiting the same canonical file and returns it."
  (interactive
   (list
    (cond
     (current-prefix-arg
      (read-file-name
       "Org file: " nil nil t
       (when (and buffer-file-name
                  (string-match-p etaf-org--org-file-regexp buffer-file-name))
         (file-relative-name buffer-file-name default-directory))))
     ((etaf-org--preview-buffer-p)
      (etaf-app-state))
     ((and buffer-file-name
           (string-match-p etaf-org--org-file-regexp buffer-file-name))
      (expand-file-name buffer-file-name))
     ((derived-mode-p 'org-mode)
      (current-buffer))
     (t
      (read-file-name "Org file: " nil nil t)))))
  (let* ((origin-buf (current-buffer))
         (origin-line (line-number-at-pos (point)))
         (origin-file (and buffer-file-name
                           (etaf-org--canonical-file buffer-file-name))))
    (cond
     ;; Existing session passed directly.
     ((and (listp source) (etaf-ref-p (plist-get source :document)))
      (let ((existing (plist-get source :buffer)))
        (if (buffer-live-p existing)
            (progn (switch-to-buffer existing) existing)
          (let ((buf (etaf-org--display source
                                        (etaf-org--buffer-name-for-session source))))
            (unless (eq origin-buf buf)
              (plist-put source :origin-buffer origin-buf))
            buf))))
     ;; Unsaved Org buffer passed directly.
     ((bufferp source)
      (let* ((existing (etaf-org--find-preview-buffer-for-source source))
             (buf (if (and existing (buffer-live-p existing))
                      (progn (switch-to-buffer existing) existing)
                    (let* ((text (with-current-buffer source
                                   (buffer-substring-no-properties (point-min) (point-max))))
                           (session (etaf-org-create :text text :title (buffer-name source)))
                           (name (format "*ETAF Org: %s*" (buffer-name source))))
                      (etaf-org--display session name source)))))
        (when-let* ((session (and (buffer-live-p buf) (etaf-app-state buf))))
          (unless (eq origin-buf buf)
            (plist-put session :origin-buffer origin-buf))
          (when (and (eq origin-buf source) (> origin-line 1))
            (etaf-org--sync-preview-to-source-line session origin-line)))
        buf))
     ;; File path.
     (t
      (let* ((file (etaf-org--canonical-file (expand-file-name source)))
             (from-source-p (and origin-file (equal origin-file file)))
             (existing (etaf-org--find-preview-buffer-for-file file))
             (buf (if (and existing (buffer-live-p existing))
                      (progn (switch-to-buffer existing) existing)
                    (etaf-org--display (etaf-org-create :file file)
                                       (etaf-org--buffer-name file)
                                       (when from-source-p origin-buf)))))
        (when-let* ((session (and (buffer-live-p buf) (etaf-app-state buf))))
          (unless (eq origin-buf buf)
            (plist-put session :origin-buffer origin-buf))
          (when (and from-source-p (> origin-line 1))
            (etaf-org--sync-preview-to-source-line session origin-line)))
        buf)))))

(defun etaf-org--open-preview-split (source-buf)
  "Open a right-side live preview split beside SOURCE-BUF and return its buffer."
  (let* ((file (and (buffer-file-name source-buf)
                    (etaf-org--canonical-file (buffer-file-name source-buf))))
         (source-win (or (get-buffer-window source-buf) (selected-window)))
         (existing-preview (etaf-org--find-preview-buffer-for-source source-buf))
         (existing-win (and existing-preview (get-buffer-window existing-preview)))
         (preview-buf nil))
    (select-window source-win)
    (unless (eq (window-buffer source-win) source-buf)
      (switch-to-buffer source-buf))
    (if (and (window-live-p existing-win) (not (eq existing-win source-win)))
        (setq preview-buf existing-preview)
      (let ((right-win (condition-case nil
                           (split-window-right)
                         (error (split-window-below)))))
        (set-window-parameter right-win 'etaf-org-preview-split t)
        (select-window right-win)
        (setq preview-buf (etaf-org-open (or file source-buf)))))
    (when (window-live-p source-win)
      (select-window source-win))
    (with-current-buffer source-buf
      (add-hook 'kill-buffer-hook #'etaf-org--preview-source-killed nil t))
    (when-let* ((session (and (buffer-live-p preview-buf)
                              (etaf-app-state preview-buf))))
      (unless (eq (plist-get session :source-buffer) source-buf)
        (etaf-org--live-register session source-buf))
      (when-let* ((pwin (get-buffer-window preview-buf t)))
        (etaf-org--fit-width session pwin)
        (etaf-org--flush session))
      (etaf-org--set-follow-scroll session t)
      (etaf-org--sync-preview-scroll session t source-win))
    preview-buf))

(defun etaf-org--close-preview-split (source-buf)
  "Close the live preview split attached to SOURCE-BUF, keeping SOURCE-BUF."
  (when-let* ((preview-buf (etaf-org--find-preview-buffer-for-source source-buf))
              ((buffer-live-p preview-buf)))
    (let ((src-win (get-buffer-window source-buf))
          (prev-win (get-buffer-window preview-buf)))
      (when (and (window-live-p src-win)
                 (window-parameter src-win 'etaf-org-source-split)
                 (window-live-p prev-win)
                 (not (eq prev-win src-win)))
        ;; Promote preview-win as the split to delete so source-win survives.
        (set-window-parameter src-win 'etaf-org-source-split nil)
        (set-window-parameter prev-win 'etaf-org-preview-split t))
      (with-current-buffer preview-buf
        (etaf-org-close))
      (when (window-live-p src-win)
        (select-window src-win)))))

(defun etaf-org--preview-source-killed ()
  "Tear down the live preview split when its source buffer is killed."
  (etaf-org--close-preview-split (current-buffer)))

;;; Autoloaded from `etaf-org.el' alongside `etaf-org-open'.
(defun etaf-org-preview (&optional file)
  "Toggle a live side-by-side ETAF Org preview beside the source buffer.
When called from a preview buffer with no FILE, delegates to
`etaf-org-toggle-split'.  Otherwise previews FILE (defaulting to the current
buffer's visited file or Org buffer, or prompting interactively when the buffer
visits none): if a live preview window is already visible beside the source
window, closes it and removes only the split it created; otherwise opens a
non-destructive right split without closing unrelated panes, enables
proportional follow-scroll synced to the current source line, and leaves point
in the source buffer.  Returns the preview buffer when opened, or nil when
closed."
  (interactive
   (list
    (unless (or (etaf-org--preview-buffer-p)
                buffer-file-name
                (derived-mode-p 'org-mode))
      (read-file-name "Org file: " nil nil t))))
  (if (and (null file) (etaf-org--preview-buffer-p))
      (etaf-org-toggle-split)
    (let* ((source-buf (if file
                           (or (find-buffer-visiting file)
                               (find-file-noselect file))
                         (current-buffer)))
           (path (or file (buffer-file-name source-buf))))
      (unless (or path (with-current-buffer source-buf (derived-mode-p 'org-mode)))
        (user-error "Save this buffer to an .org file before opening a live preview"))
      (let* ((existing-preview (etaf-org--find-preview-buffer-for-source source-buf))
             (source-win (or (get-buffer-window source-buf) (selected-window)))
             (existing-win (and existing-preview
                                (get-buffer-window existing-preview))))
        (if (and (window-live-p existing-win)
                 (not (eq existing-win source-win)))
            (progn
              (etaf-org--close-preview-split source-buf)
              nil)
          (etaf-org--open-preview-split source-buf))))))

(provide 'etaf-org-app)
;;; etaf-org-app.el ends here
