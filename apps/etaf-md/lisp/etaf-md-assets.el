;;; etaf-md-assets.el --- Workspace assets and actions for etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Markdown living-document workspace assets (L1) and explicit actions (L2),
;; delegating path sandboxing, bounded slicing, symbol introspection, directory
;; trees, and Git/Jujutsu log & diff to `etaf-doc-assets'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-doc)

(declare-function etaf-md--open-url "etaf-md-model" (session url))
(declare-function etaf-md--publish "etaf-md-model" (session contents &optional dirty-span live-p))
(declare-function etaf-md--read "etaf-md-model" (session key))
(declare-function etaf-md--refresh-block-assets "etaf-md-model" (session))
(declare-function etaf-md--session-text "etaf-md-model" (session))
(declare-function etaf-md-set-block-state "etaf-md-env" (env key value))
(defvar pulse-flag)
(defvar pulse-delay)
(defvar pulse-iterations)
(defvar pulse-momentary-overlay)
(declare-function pulse-momentary-highlight-one-line "pulse" (point &optional face))
(declare-function pulse-momentary-unhighlight "pulse" ())

(defvar etaf-md--pulse-clear-timer nil
  "One-shot timer clearing a non-pulsing highlight overlay on TTY frames.")

(defun etaf-md--pulse-line (pos)
  "Momentarily highlight the line at POS, auto-clearing on TTY frames too."
  (when (timerp etaf-md--pulse-clear-timer)
    (cancel-timer etaf-md--pulse-clear-timer)
    (setq etaf-md--pulse-clear-timer nil))
  (when (and (require 'pulse nil t)
             (not (eq (bound-and-true-p pulse-flag) 'never)))
    (pulse-momentary-highlight-one-line pos)
    (when (and (bound-and-true-p pulse-momentary-overlay)
               (memq #'pulse-momentary-unhighlight pre-command-hook))
      (let* ((ov pulse-momentary-overlay)
             (delay (max 0.25 (* (or (bound-and-true-p pulse-delay) 0.03)
                                 (or (bound-and-true-p pulse-iterations) 10)))))
        (setq etaf-md--pulse-clear-timer
              (run-at-time
               delay nil
               (lambda ()
                 (setq etaf-md--pulse-clear-timer nil)
                 (when (eq (bound-and-true-p pulse-momentary-overlay) ov)
                   (pulse-momentary-unhighlight)))))))))

;;; ---------------------------------------------------------------------------
;;; Trust and behavior customization
;;; ---------------------------------------------------------------------------

(defcustom etaf-md-allow-local-read t
  "Whether read-only workspace widgets may read files inside the project root.
Applies to `include', `code-ref', `project-tree', `git-log' and `git-diff'.
Paths escaping the document's workspace root are always rejected."
  :type 'boolean
  :group 'etaf-md)

(defcustom etaf-md-allow-actions 'ask
  "Whether explicit executable widget actions (`run') are permitted.
`ask' prompts with `yes-or-no-p' before each execution, `t' allows execution
without prompting, and `nil' disables execution altogether."
  :type '(choice (const :tag "Prompt before running" ask)
                 (const :tag "Allow without prompt" t)
                 (const :tag "Disable executable actions" nil))
  :group 'etaf-md)

(defcustom etaf-md-interactive-checkbox t
  "Whether clicking a task list checkbox toggles `[ ]' and `[x]' in source."
  :type 'boolean
  :group 'etaf-md)

(defcustom etaf-md-media-lightbox 'auto
  "Whether activating a local image opens the in-buffer media lightbox."
  :type '(choice (const :tag "On graphical frames" auto)
                 (const :tag "Always use lightbox" t)
                 (const :tag "Open externally" nil))
  :group 'etaf-md)

(defconst etaf-md-assets--max-file-bytes (* 64 1024)
  "Maximum bytes read from a workspace source file for `include'/`code-ref'.")

(defconst etaf-md-assets--max-lines 400
  "Maximum lines kept for one `include', `code-ref' or `git-diff' snapshot.")

(defun etaf-md-assets--session-dir (session)
  "Return the base directory for SESSION."
  (or (and session (plist-get session :dir)) default-directory))

(defun etaf-md-assets--workspace-root (session)
  "Return the canonical workspace root directory for SESSION."
  (etaf-doc-assets-workspace-root (etaf-md-assets--session-dir session)))

(defun etaf-md-assets--safe-path (session relpath)
  "Resolve RELPATH inside SESSION's workspace root, or return nil if outside."
  (etaf-doc-assets-safe-path (etaf-md-assets--session-dir session) relpath))

(defun etaf-md-assets--lang-for-path (path)
  "Infer a syntax highlight language tag from file PATH."
  (etaf-doc-assets-lang-for-path path))

;;; ---------------------------------------------------------------------------
;;; L1 sync snapshots (delegating to `etaf-doc-assets')
;;; ---------------------------------------------------------------------------

(defun etaf-md-assets--compute-include (session attrs)
  "Compute `include' asset snapshot for ATTRS in SESSION."
  (let ((src (plist-get attrs :src)))
    (cond
     ((not etaf-md-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-md-allow-local-read 为 nil）"))
     ((or (null src) (string-blank-p src))
      (list :error "include 缺少 src 属性"))
     (t
      (etaf-doc-assets-read-slice
       (etaf-md-assets--session-dir session) src
       (list :region (plist-get attrs :region)
             :section (plist-get attrs :section)
             :lines (plist-get attrs :lines)
             :lang (plist-get attrs :lang)
             :max-bytes etaf-md-assets--max-file-bytes
             :max-lines etaf-md-assets--max-lines))))))

(defun etaf-md-assets--compute-code-ref (session attrs)
  "Compute `code-ref' live source slice for ATTRS in SESSION."
  (let ((src (plist-get attrs :src)))
    (cond
     ((not etaf-md-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-md-allow-local-read 为 nil）"))
     ((or (null src) (string-blank-p src))
      (list :error "code-ref 缺少 src 属性"))
     (t
      (etaf-doc-assets-read-slice
       (etaf-md-assets--session-dir session) src
       (list :symbol (plist-get attrs :symbol)
             :lines (plist-get attrs :lines)
             :context (plist-get attrs :context)
             :lang (plist-get attrs :lang)
             :default-lines 24
             :max-bytes etaf-md-assets--max-file-bytes
             :max-lines etaf-md-assets--max-lines))))))

(defun etaf-md-assets--compute-symbol (attrs &optional session)
  "Compute live Emacs symbol introspection card data for ATTRS in SESSION."
  (etaf-doc-assets-inspect-symbol
   (plist-get attrs :name)
   (and session (etaf-md-assets--session-dir session))))

(defun etaf-md-assets--compute-project-tree (session attrs)
  "Compute bounded workspace directory tree snapshot for ATTRS in SESSION."
  (if (not etaf-md-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-md-allow-local-read 为 nil）")
    (etaf-doc-assets-project-tree
     (etaf-md-assets--session-dir session)
     (or (plist-get attrs :path) ".")
     (list :depth (plist-get attrs :depth)
           :ignore (plist-get attrs :ignore)
           :limit 150))))

;;; ---------------------------------------------------------------------------
;;; L1 async providers (git-log, git-diff)
;;; ---------------------------------------------------------------------------

(defun etaf-md-assets--cache (session)
  "Return SESSION's asset cache hash table."
  (or (plist-get session :assets)
      (let ((tbl (make-hash-table :test #'equal)))
        (plist-put session :assets tbl)
        tbl)))

(defun etaf-md-assets--key (name attrs session)
  "Return a stable cache key for async container NAME with ATTRS in SESSION."
  (list name
        (and session (plist-get session :dir))
        (and session (plist-get session :file))
        attrs))

(defun etaf-md-assets--attach-container (block session)
  "Attach `:asset-data' to container BLOCK from sync reads or SESSION cache."
  (let* ((name (plist-get block :name))
         (attrs (plist-get block :attrs))
         (data
          (pcase name
            ("include" (etaf-md-assets--compute-include session attrs))
            ("code-ref" (etaf-md-assets--compute-code-ref session attrs))
            ("symbol" (etaf-md-assets--compute-symbol attrs session))
            ("project-tree" (etaf-md-assets--compute-project-tree session attrs))
            ((or "git-log" "git-diff")
             (let* ((cache (and session (etaf-md-assets--cache session)))
                    (key (etaf-md-assets--key name attrs session)))
               (and cache (gethash key cache)))))))
    (if data
        (plist-put (copy-sequence block) :asset-data data)
      block)))

(defun etaf-md-assets-attach (block session)
  "Attach cached workspace asset data onto BLOCK (recursing into containers)."
  (if (not (eq (plist-get block :type) 'container))
      block
    (let* ((updated (etaf-md-assets--attach-container block session))
           (children (plist-get updated :children))
           (new-children (when children
                           (mapcar (lambda (ch) (etaf-md-assets-attach ch session))
                                   children))))
      (if (equal children new-children)
          updated
        (plist-put (copy-sequence updated) :children new-children)))))

(defun etaf-md-assets--collect-async-blocks (blocks)
  "Collect `(NAME . ATTRS)' pairs for async workspace containers in BLOCKS."
  (let ((found nil))
    (cl-labels
        ((walk (items)
           (dolist (b items)
             (when (eq (plist-get b :type) 'container)
               (let ((name (plist-get b :name)))
                 (when (member name '("git-log" "git-diff"))
                   (push (cons name (plist-get b :attrs)) found)))
               (walk (plist-get b :children))))))
      (walk blocks))
    (delete-dups (nreverse found))))

(defun etaf-md-assets--store-and-refresh (session key value)
  "Store VALUE under KEY in SESSION's `:assets' cache and refresh blocks."
  (when session
    (puthash key value (etaf-md-assets--cache session))
    (when (and (buffer-live-p (plist-get session :buffer))
               (fboundp 'etaf-md--refresh-block-assets))
      (etaf-md--refresh-block-assets session))))

(defun etaf-md-assets-request (session)
  "Kick off missing async workspace assets for SESSION."
  (when (and session (buffer-live-p (plist-get session :buffer)))
    (let* ((doc (etaf-md--read session :document))
           (blocks (mapcar (lambda (e) (or (plist-get e :block) e))
                           (plist-get doc :children)))
           (items (etaf-md-assets--collect-async-blocks blocks))
           (cache (etaf-md-assets--cache session))
           (pending (or (plist-get session :assets-pending)
                        (let ((tbl (make-hash-table :test #'equal)))
                          (plist-put session :assets-pending tbl)
                          tbl))))
      (dolist (item items)
        (let* ((name (car item))
               (attrs (cdr item))
               (key (etaf-md-assets--key name attrs session)))
          (unless (or (gethash key cache) (gethash key pending))
            (puthash key t pending)
            (if (not etaf-md-allow-local-read)
                (etaf-md-assets--store-and-refresh session key (list :error "本地读取已禁用"))
              (let ((dir (etaf-md-assets--session-dir session))
                    (done (lambda (res)
                            (etaf-md-assets--store-and-refresh session key res))))
                (pcase name
                  ("git-log"
                   (etaf-doc-assets-git-log-async
                    dir done (list :path (plist-get attrs :path)
                                   :limit (plist-get attrs :limit))))
                  ("git-diff"
                   (etaf-doc-assets-git-diff-async
                    dir done (list :path (plist-get attrs :path)
                                   :range (plist-get attrs :range)
                                   :max-lines etaf-md-assets--max-lines))))))))))))

;;; ---------------------------------------------------------------------------
;;; L2 explicit user-triggered actions (never auto-run)
;;; ---------------------------------------------------------------------------

(defun etaf-md-assets--confirm-action (description)
  "Check `etaf-md-allow-actions' before executing DESCRIPTION."
  (pcase etaf-md-allow-actions
    ('t t)
    ('nil
     (message "已禁止执行动作（etaf-md-allow-actions 为 nil）：%s" description)
     nil)
    (_
     (if noninteractive
         (progn
           (message "需要确认才能执行（请设置 etaf-md-allow-actions 为 t）：%s" description)
           nil)
       (yes-or-no-p (format "允许在预览文档中执行 %s？" description))))))

(defun etaf-md-assets-run-command (session env cmd &optional cwd)
  "Run shell CMD for ENV's `run' container in SESSION after trust check."
  (let* ((trimmed (string-trim (or cmd "")))
         (dir (if (and cwd (not (string-blank-p cwd)))
                  (etaf-md-assets--safe-path session cwd)
                (etaf-md-assets--session-dir session))))
    (cond
     ((string-empty-p trimmed)
      (message "没有可执行的命令"))
     ((null dir)
      (message "工作目录超出允许范围：%s" cwd))
     ((etaf-md-assets--confirm-action (format "命令 `%s`" trimmed))
      (let ((start (float-time)))
        (etaf-md-set-block-state
         env :run-result
         (list :status 'running :lines (list (list :time (format-time-string "%H:%M:%S")
                                                   :level "INFO"
                                                   :message (format "$ %s" trimmed)))))
        (etaf-process-run
         (list shell-file-name shell-command-switch trimmed)
         :name "etaf-md-run"
         :directory dir
         :timeout 20
         :callback
         (lambda (res)
           (let* ((elapsed (- (float-time) start))
                  (exit-code (plist-get res :exit))
                  (ok (and (eq (plist-get res :status) 'exit) (eql exit-code 0)))
                  (raw (string-trim-right (or (plist-get res :output) "")))
                  (now (format-time-string "%H:%M:%S"))
                  (out-lines
                   (if (string-empty-p raw)
                       (list (list :time now :level (if ok "INFO" "ERROR")
                                   :message (if ok "（无输出）"
                                              (format "进程退出：%S" (or exit-code (plist-get res :status))))))
                     (mapcar (lambda (l)
                               (list :time now
                                     :level (if ok "OUT" "ERR")
                                     :message l))
                             (seq-take (split-string raw "\n") 80)))))
             (etaf-md-set-block-state
              env :run-result
              (list :status (if ok 'ok 'error)
                    :exit exit-code
                    :duration elapsed
                    :lines out-lines))))))))))

(defun etaf-md-assets--toggle-checkbox-in-string (text begin line-offset)
  "Toggle Markdown task checkbox on line at BEGIN + LINE-OFFSET in TEXT."
  (when (and (stringp text) (integerp begin) (integerp line-offset)
             (<= 0 begin (length text)))
    (with-temp-buffer
      (insert text)
      (goto-char (+ (point-min) begin))
      (forward-line line-offset)
      (let ((eol (line-end-position)))
        (when (re-search-forward "\\(\\[\\)\\([ xX]\\)\\(\\]\\)" eol t)
          (let ((next (if (equal (match-string 2) " ") "x" " ")))
            (replace-match (concat "\\1" next "\\3") t nil)
            (buffer-string)))))))

(defun etaf-md-assets-toggle-task (session block item _item-index)
  "Toggle GFM task ITEM inside BLOCK for SESSION and update source/preview."
  (when (and session etaf-md-interactive-checkbox)
    (let* ((begin (plist-get block :begin))
           (line-offset (or (plist-get item :line-offset) 0))
           (source-buf (plist-get session :source-buffer))
           (file (plist-get session :file)))
      (cond
       ((and (buffer-live-p source-buf)
             (not (with-current-buffer source-buf buffer-read-only)))
        (with-current-buffer source-buf
          (save-excursion
            (goto-char (+ (point-min) (or begin 0)))
            (forward-line line-offset)
            (let ((eol (line-end-position)))
              (when (re-search-forward "\\(\\[\\)\\([ xX]\\)\\(\\]\\)" eol t)
                (let ((next (if (equal (match-string 2) " ") "x" " ")))
                  (replace-match (concat "\\1" next "\\3") t nil)))))))
       ((and file (file-writable-p file))
        (let* ((old (etaf-md--session-text session))
               (updated (etaf-md-assets--toggle-checkbox-in-string old begin line-offset)))
          (when updated
            (with-temp-file file (insert updated))
            (etaf-md--publish session updated))))
       ((plist-get session :text)
        (let* ((old (plist-get session :text))
               (updated (etaf-md-assets--toggle-checkbox-in-string old begin line-offset)))
          (when updated
            (plist-put session :text updated)
            (etaf-md--publish session updated))))))))

(defun etaf-md-assets-open-wiki-link (session target anchor _label)
  "Resolve and open wiki-link `[[TARGET#ANCHOR]]' for SESSION."
  (let* ((target (string-trim (or target "")))
         (anchor (and anchor (not (string-blank-p anchor)) (string-trim anchor)))
         (dir (etaf-md-assets--session-dir session))
         (resolved
          (cond
           ((string-empty-p target) "")
           ((file-readable-p (expand-file-name target dir)) target)
           ((file-readable-p (expand-file-name (concat target ".md") dir))
            (concat target ".md"))
           ((file-readable-p (expand-file-name (concat target ".markdown") dir))
            (concat target ".markdown"))
           (t (concat target ".md"))))
         (dest (if anchor
                   (if (string-empty-p resolved)
                       (format "#%s" anchor)
                     (format "%s#%s" resolved anchor))
                 resolved)))
    (etaf-md--open-url session dest)))

(defun etaf-md-assets-open-symbol (session name)
  "Inspect Emacs symbol NAME from SESSION."
  (let* ((trimmed (string-trim (or name "")))
         (sym (intern-soft trimmed)))
    (cond
     ((when-let* ((handler (and session (plist-get session :on-symbol))))
        (funcall handler trimmed)))
     ((null sym)
      (message "未找到已加载的 Emacs 符号：%s" trimmed))
     ((fboundp 'describe-symbol)
      (describe-symbol sym))
     (t
      (message "Emacs 符号：%s" trimmed)))))

(defun etaf-md-assets-jump-file (session abs-path &optional line)
  "Open ABS-PATH (optionally at LINE) in another window from SESSION."
  (ignore session)
  (if (and (stringp abs-path) (file-readable-p abs-path))
      (let ((buf (find-file-noselect abs-path)))
        (pop-to-buffer buf)
        (when (and (integerp line) (> line 0))
          (goto-char (point-min))
          (forward-line (1- line))
          (recenter)
          (etaf-md--pulse-line (point))))
    (message "无法打开文件：%s" abs-path)))

(provide 'etaf-md-assets)
;;; etaf-md-assets.el ends here
