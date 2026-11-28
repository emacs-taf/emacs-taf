;;; etaf-md-assets.el --- Workspace assets and actions for etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Read-only workspace assets (L1) and explicit user-triggered actions (L2)
;; backing the living-document widgets of `etaf-md'.
;;
;; Every filesystem read and subprocess stays strictly outside ETAF's
;; `:render' phase:
;; - Fast bounded local reads (`include', `code-ref', `symbol', `project-tree')
;;   attach their snapshots during document publish.
;; - External processes (`git-log', `git-diff') run asynchronously via
;;   `etaf-process-run' into SESSION's `:assets' cache and repaint only the
;;   owning block when ready.
;; - Executable actions (`run', interactive task checkboxes) fire solely from
;;   explicit user activation and respect trust settings.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)

(declare-function etaf-md--open-url "etaf-md-model" (session url))
(declare-function etaf-md--publish "etaf-md-model" (session contents &optional dirty-span live-p))
(declare-function etaf-md--read "etaf-md-model" (session key))
(declare-function etaf-md--refresh-block-assets "etaf-md-model" (session))
(declare-function etaf-md--session-text "etaf-md-model" (session))
(declare-function etaf-md-set-block-state "etaf-md-env" (env key value))
(declare-function find-lisp-object-file-name "find-func" (object type))
(declare-function help-function-arglist "help-fns" (def &optional preserve-names))
(defvar pulse-flag)
(defvar pulse-delay)
(defvar pulse-iterations)
(defvar pulse-momentary-overlay)
(declare-function pulse-momentary-highlight-one-line "pulse" (point &optional face))
(declare-function pulse-momentary-unhighlight "pulse" ())

(defvar etaf-md--pulse-clear-timer nil
  "One-shot timer clearing a non-pulsing highlight overlay on TTY frames.")

(defun etaf-md--pulse-line (pos)
  "Momentarily highlight the line at POS, auto-clearing on TTY frames too.
On GUI frames with an explicit default background `pulse' fades out on its own
timer.  On terminal frames (where `default' background is `unspecified-bg' or
`pulse-flag' is nil), `pulse' leaves a static highlight until the next command;
schedule a matching one-shot cleanup timer so TTY and GUI behave consistently."
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
  "Whether activating a local image opens the in-buffer media lightbox.
`auto' opens the lightbox on graphical frames and uses the system opener on
text/batch frames; `t' always uses the in-buffer lightbox; `nil' always opens
images externally."
  :type '(choice (const :tag "On graphical frames" auto)
                 (const :tag "Always use lightbox" t)
                 (const :tag "Open externally" nil))
  :group 'etaf-md)

(defconst etaf-md-assets--max-file-bytes (* 64 1024)
  "Maximum bytes read from a workspace source file for `include'/`code-ref'.")

(defconst etaf-md-assets--max-lines 400
  "Maximum lines kept for one `include', `code-ref' or `git-diff' snapshot.")

(defconst etaf-md-assets--default-ignore
  '(".git" ".jj" "node_modules" ".DS_Store" "__pycache__" "target" "dist" "build" ".cache")
  "Directory and file names skipped by `project-tree'.")

;;; ---------------------------------------------------------------------------
;;; Workspace boundary and helpers
;;; ---------------------------------------------------------------------------

(defun etaf-md-assets--workspace-root (session)
  "Return the canonical workspace root directory for SESSION."
  (let* ((dir (expand-file-name (or (and session (plist-get session :dir))
                                    default-directory)))
         (vcs (or (locate-dominating-file dir ".git")
                  (locate-dominating-file dir ".jj")))
         (root (or vcs dir)))
    (file-name-as-directory
     (if (file-exists-p root) (file-truename root) (expand-file-name root)))))

(defun etaf-md-assets--safe-path (session relpath)
  "Resolve RELPATH inside SESSION's workspace root, or return nil if outside."
  (when (and (stringp relpath) (not (string-blank-p relpath)))
    (let* ((base (expand-file-name (or (and session (plist-get session :dir))
                                       default-directory)))
           (root (etaf-md-assets--workspace-root session))
           (candidate (expand-file-name (string-trim relpath) base))
           (resolved (if (file-exists-p candidate)
                         (file-truename candidate)
                       candidate))
           (root-true (if (file-exists-p root) (file-truename root) root)))
      (when (or (equal (file-name-as-directory resolved)
                       (file-name-as-directory root-true))
                (file-in-directory-p resolved root-true))
        candidate))))

(defun etaf-md-assets--lang-for-path (path)
  "Infer a syntax highlight language tag from file PATH."
  (pcase (downcase (or (file-name-extension path) ""))
    ((or "el" "elisp") "elisp")
    ("py" "python")
    ((or "js" "mjs" "cjs") "js")
    ((or "ts" "tsx") "ts")
    ("jsx" "jsx")
    ("rs" "rust")
    ("go" "go")
    ("c" "c")
    ((or "cc" "cpp" "cxx" "hpp") "cpp")
    ("h" "c")
    ("java" "java")
    ("sh" "sh")
    ("bash" "bash")
    ("zsh" "sh")
    ("json" "json")
    ((or "yml" "yaml") "yaml")
    ("toml" "toml")
    ("css" "css")
    ((or "html" "htm") "html")
    ("xml" "xml")
    ("sql" "sql")
    ((or "md" "markdown") "markdown")
    ("org" "org")
    (ext (if (string-empty-p ext) "text" ext))))

(defun etaf-md-assets--read-lines (path)
  "Read up to `etaf-md-assets--max-file-bytes' of PATH as a list of lines."
  (with-temp-buffer
    (insert-file-contents path nil 0 etaf-md-assets--max-file-bytes)
    (split-string (buffer-string) "\n")))

(defun etaf-md-assets--parse-line-range (spec total)
  "Parse line range SPEC (`12-40' or `12') clamped to 1..TOTAL -> (BEG . END)."
  (cond
   ((and (stringp spec) (string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" (string-trim spec)))
    (let ((b (max 1 (string-to-number (match-string 1 spec))))
          (e (min total (string-to-number (match-string 2 spec)))))
      (cons (min b e) (max b e))))
   ((and (stringp spec) (string-match "\\`\\([0-9]+\\)\\'" (string-trim spec)))
    (let ((b (max 1 (min total (string-to-number (match-string 1 spec))))))
      (cons b b)))
   (t (cons 1 (min total etaf-md-assets--max-lines)))))

(defun etaf-md-assets--slice-lines (lines beg end)
  "Return 1-based inclusive slice BEG..END of LINES joined by newlines."
  (let* ((total (length lines))
         (b (max 1 (min (max 1 total) beg)))
         (e (max b (min total (min end (+ b etaf-md-assets--max-lines -1))))))
    (list :start b
          :end e
          :truncated (> end e)
          :content (mapconcat #'identity (cl-subseq lines (1- b) e) "\n"))))

;;; ---------------------------------------------------------------------------
;;; L1 sync snapshots (run during publish, never during :render)
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
      (let ((path (etaf-md-assets--safe-path session src)))
        (cond
         ((null path)
          (list :error (format "路径超出工作区范围：%s" src)))
         ((not (file-readable-p path))
          (list :error (format "找不到文件：%s" src)))
         ((file-directory-p path)
          (list :error (format "目标是目录而非文件：%s" src)))
         (t
          (let* ((lines (etaf-md-assets--read-lines path))
                 (total (length lines))
                 (region (plist-get attrs :region))
                 (section (plist-get attrs :section))
                 (line-spec (plist-get attrs :lines))
                 (range
                  (cond
                   ((and (stringp region) (not (string-blank-p region)))
                    (let ((re-start (format "#region[ \t]+%s\\b" (regexp-quote region)))
                          (re-end "#endregion\\b")
                          (b nil) (e nil))
                      (cl-loop for line in lines for idx from 1 do
                               (cond
                                ((and (null b) (string-match-p re-start line))
                                 (setq b (1+ idx)))
                                ((and b (null e) (string-match-p re-end line))
                                 (setq e (1- idx)))))
                      (if b
                          (cons b (or e total))
                        (cons 1 (min total etaf-md-assets--max-lines)))))
                   ((and (stringp section) (not (string-blank-p section)))
                    (let ((b nil) (e nil) (level 0))
                      (cl-loop for line in lines for idx from 1 do
                               (when (string-match "\\`\\(#+\\)[ \t]+\\(.+\\)\\'" line)
                                 (let ((lv (length (match-string 1 line)))
                                       (title (string-trim (match-string 2 line))))
                                   (cond
                                    ((and (null b) (equal title section))
                                     (setq b idx level lv))
                                    ((and b (null e) (<= lv level))
                                     (setq e (1- idx)))))))
                      (if b
                          (cons b (or e total))
                        (cons 1 (min total etaf-md-assets--max-lines)))))
                   (t (etaf-md-assets--parse-line-range line-spec total))))
                 (sliced (etaf-md-assets--slice-lines lines (car range) (cdr range))))
            (list :ok t
                  :path path
                  :rel src
                  :lang (or (plist-get attrs :lang) (etaf-md-assets--lang-for-path path))
                  :start-line (plist-get sliced :start)
                  :end-line (plist-get sliced :end)
                  :total-lines total
                  :truncated (plist-get sliced :truncated)
                  :content (plist-get sliced :content))))))))))

(defun etaf-md-assets--find-elisp-sexp-end (lines hit)
  "Return the 1-based end line of the Lisp form starting at HIT in LINES."
  (ignore-errors
    (with-temp-buffer
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (insert (mapconcat #'identity lines "\n"))
      (goto-char (point-min))
      (forward-line (1- hit))
      (skip-chars-forward " \t")
      (when (eq (char-after) ?\()
        (forward-sexp 1)
        (line-number-at-pos (point))))))

(defun etaf-md-assets--find-symbol-range (lines sym context &optional lang)
  "Locate SYM definition in LINES; return (BEG . END) with CONTEXT lines.
For Emacs Lisp sources (LANG `elisp'), parses the complete balanced top-level
sexp with `forward-sexp' so closing parentheses are never clipped."
  (let* ((total (length lines))
         (ctx (max 0 (or context 0)))
         (q (regexp-quote sym))
         (def-re (format "\\(?:defun\\|defmacro\\|defsubst\\|defvar\\|defcustom\\|defconst\\|cl-defun\\|cl-defstruct\\|etaf-define-component\\|function\\|def\\|fn\\|class\\|struct\\|interface\\|type\\|const\\)[ \t]+%s\\b" q))
         (hit (or (cl-loop for line in lines for idx from 1
                           when (string-match-p def-re line) return idx)
                  (cl-loop for line in lines for idx from 1
                           when (string-match-p (format "\\b%s\\b" q) line) return idx))))
    (when hit
      (let* ((beg (max 1 (- hit ctx)))
             (sexp-end (and (equal lang "elisp")
                            (etaf-md-assets--find-elisp-sexp-end lines hit)))
             (end (if (and sexp-end (>= sexp-end hit))
                      (min total (min (+ hit 80) sexp-end))
                    (let ((e hit)
                          (base-indent (if (string-match "\\`[ \t]*" (nth (1- hit) lines))
                                           (length (match-string 0 (nth (1- hit) lines)))
                                         0))
                          (scan (1+ hit))
                          (limit (min total (+ hit 60))))
                      (while (and (<= scan limit)
                                  (let ((l (nth (1- scan) lines)))
                                    (or (string-blank-p l)
                                        (and (string-match "\\`[ \t]*" l)
                                             (> (length (match-string 0 l)) base-indent))
                                        (string-prefix-p ")" (string-trim l))
                                        (string-prefix-p "}" (string-trim l)))))
                        (setq e scan
                              scan (1+ scan)))
                      e))))
        (cons beg (min total (+ end ctx)))))))

(defun etaf-md-assets--compute-code-ref (session attrs)
  "Compute `code-ref' live source slice for ATTRS in SESSION."
  (let ((src (plist-get attrs :src))
        (sym (plist-get attrs :symbol))
        (line-spec (plist-get attrs :lines))
        (ctx (let ((raw (plist-get attrs :context)))
               (cond ((integerp raw) raw)
                     ((and (stringp raw) (string-match-p "\\`[0-9]+\\'" raw))
                      (string-to-number raw))
                     (t 0)))))
    (cond
     ((not etaf-md-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-md-allow-local-read 为 nil）"))
     ((or (null src) (string-blank-p src))
      (list :error "code-ref 缺少 src 属性"))
     (t
      (let ((path (etaf-md-assets--safe-path session src)))
        (cond
         ((null path)
          (list :error (format "路径超出工作区范围：%s" src)))
         ((not (file-readable-p path))
          (list :error (format "找不到源码文件：%s" src)))
         (t
          (let* ((lines (etaf-md-assets--read-lines path))
                 (total (length lines))
                 (lang (or (plist-get attrs :lang) (etaf-md-assets--lang-for-path path)))
                 (range (cond
                         ((and (stringp sym) (not (string-blank-p sym)))
                          (etaf-md-assets--find-symbol-range lines sym ctx lang))
                         (line-spec
                          (etaf-md-assets--parse-line-range line-spec total))
                         (t (cons 1 (min total 24))))))
            (if (null range)
                (list :error (format "在 %s 中未找到符号 %s" src sym))
              (let ((sliced (etaf-md-assets--slice-lines lines (car range) (cdr range))))
                (list :ok t
                      :path path
                      :rel src
                      :symbol sym
                      :lang lang
                      :start-line (plist-get sliced :start)
                      :end-line (plist-get sliced :end)
                      :content (plist-get sliced :content))))))))))))

(defun etaf-md-assets--format-compact (value)
  "Format VALUE safely with bounded depth and circle protection."
  (let ((print-circle t)
        (print-length 8)
        (print-level 3))
    (let ((s (prin1-to-string value)))
      (if (> (length s) 120)
          (concat (substring s 0 117) "...")
        s))))

(defun etaf-md-assets--first-paragraph (doc)
  "Return the complete first paragraph of DOC with wrapped lines joined cleanly."
  (when (and (stringp doc) (not (string-blank-p doc)))
    (let* ((trimmed (string-trim doc))
           (para (car (split-string trimmed "\n[ \t]*\n" t))))
      (when para
        (replace-regexp-in-string "[ \t]*\n[ \t]*" " " (string-trim para))))))

(defun etaf-md-assets--compute-symbol (attrs &optional session)
  "Compute live Emacs symbol introspection card data for ATTRS in SESSION."
  (let* ((name (plist-get attrs :name))
         (sym (and (stringp name) (intern-soft (string-trim name)))))
    (cond
     ((or (null name) (string-blank-p name))
      (list :error "symbol 缺少 name 属性"))
     ((null sym)
      (list :ok t :name name :missing t :kind "未定义符号"))
     (t
      (require 'help-fns nil t)
      (require 'find-func nil t)
      (let* ((fn-p (fboundp sym))
             (var-p (boundp sym))
             (cmd-p (commandp sym))
             (macro-p (and fn-p (macrop (symbol-function sym))))
             (face-p (facep sym))
             (kind (cond
                    (cmd-p "交互命令")
                    (macro-p "宏")
                    (fn-p "函数")
                    ((custom-variable-p sym) "可定制变量")
                    (var-p "变量")
                    (face-p "Face")
                    (t "符号")))
             (arglist (when (and fn-p (fboundp 'help-function-arglist))
                        (ignore-errors
                          (format "(%s%s)"
                                  name
                                  (let ((args (help-function-arglist sym t)))
                                    (if (and args (not (eq args t)))
                                        (concat " " (mapconcat #'prin1-to-string args " "))
                                      ""))))))
             (keys (when cmd-p
                     (let ((raw (where-is-internal sym nil nil t)))
                       (mapcar #'key-description (seq-take raw 4)))))
             (val (when var-p
                    (etaf-md-assets--format-compact (symbol-value sym))))
             (doc (or (and fn-p (ignore-errors (documentation sym t)))
                      (and var-p (documentation-property sym 'variable-documentation t))
                      (and face-p (documentation-property sym 'face-documentation t))))
             (summary (etaf-md-assets--first-paragraph doc))
             (src (when (fboundp 'find-lisp-object-file-name)
                    (or (and fn-p (ignore-errors (find-lisp-object-file-name sym (symbol-function sym))))
                        (and var-p (ignore-errors (find-lisp-object-file-name sym 'defvar))))))
             (src-file (and (stringp src)
                            (let ((el (if (string-suffix-p ".elc" src)
                                          (concat (substring src 0 -4) ".el")
                                        src)))
                              (if (file-readable-p el) el src))))
             (root (and session (etaf-md-assets--workspace-root session)))
             (rel-file (when (and src-file root)
                         (let ((ts (ignore-errors (file-truename src-file))))
                           (if (and ts (file-in-directory-p ts root))
                               (file-relative-name ts root)
                             (file-name-nondirectory src-file))))))
        (list :ok t
              :name name
              :symbol sym
              :kind kind
              :signature arglist
              :keys keys
              :value val
              :doc summary
              :file src-file
              :rel-file (or rel-file (and src-file (file-name-nondirectory src-file)))))))))

(defun etaf-md-assets--compute-project-tree (session attrs)
  "Compute bounded workspace directory tree snapshot for ATTRS in SESSION."
  (cond
   ((not etaf-md-allow-local-read)
    (list :error "本地文件读取已禁用（etaf-md-allow-local-read 为 nil）"))
   (t
    (let* ((rel (or (plist-get attrs :path) "."))
           (root (etaf-md-assets--safe-path session rel))
           (depth-raw (plist-get attrs :depth))
           (max-depth (min 6 (max 1 (cond ((integerp depth-raw) depth-raw)
                                          ((and (stringp depth-raw)
                                                (string-match-p "\\`[0-9]+\\'" depth-raw))
                                           (string-to-number depth-raw))
                                          (t 3)))))
           (extra-ignore (when-let* ((ig (plist-get attrs :ignore)))
                           (split-string ig "[, \t]+" t)))
           (ignore-list (append etaf-md-assets--default-ignore extra-ignore))
           (remaining 150))
      (cond
       ((null root)
        (list :error (format "路径超出工作区范围：%s" rel)))
       ((not (file-directory-p root))
        (list :error (format "目录不存在：%s" rel)))
       (t
        (cl-labels
            ((ignored-p (name)
               (or (member name '("." ".."))
                   (member name ignore-list)
                   (string-suffix-p ".elc" name)))
             (scan (dir d)
               (when (and (> remaining 0) (<= d max-depth))
                 (let* ((raw (condition-case nil
                                 (directory-files dir t nil t)
                               (file-error nil)))
                        (filtered
                         (cl-remove-if
                          (lambda (p) (ignored-p (file-name-nondirectory p)))
                          raw))
                        (sorted
                         (sort filtered
                               (lambda (a b)
                                 (let ((da (file-directory-p a))
                                       (db (file-directory-p b)))
                                   (if (eq da db)
                                       (string< (file-name-nondirectory a)
                                                (file-name-nondirectory b))
                                     da)))))
                        (items nil))
                   (dolist (p sorted)
                     (when (> remaining 0)
                       (setq remaining (1- remaining))
                       (let ((dir-p (file-directory-p p))
                             (name (file-name-nondirectory p)))
                         (push (list :name name
                                     :path p
                                     :rel (file-relative-name p root)
                                     :dir-p dir-p
                                     :children (when (and dir-p (< d max-depth))
                                                 (scan p (1+ d))))
                               items))))
                   (nreverse items)))))
          (list :ok t
                :root root
                :rel rel
                :truncated (<= remaining 0)
                :items (scan root 1)))))))))

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

(defun etaf-md-assets--request-git-log (session attrs key)
  "Populate `git-log' asset asynchronously for ATTRS into KEY."
  (let* ((dir (etaf-md-assets--workspace-root session))
         (rel (plist-get attrs :path))
         (target (if rel (etaf-md-assets--safe-path session rel) dir))
         (limit-raw (plist-get attrs :limit))
         (limit (min 50 (max 1 (cond ((integerp limit-raw) limit-raw)
                                     ((and (stringp limit-raw)
                                           (string-match-p "\\`[0-9]+\\'" limit-raw))
                                      (string-to-number limit-raw))
                                     (t 8)))))
         (git (executable-find "git")))
    (cond
     ((not etaf-md-allow-local-read)
      (etaf-md-assets--store-and-refresh session key (list :error "本地读取已禁用")))
     ((null git)
      (etaf-md-assets--store-and-refresh session key (list :error "未检测到 git 程序")))
     ((null target)
      (etaf-md-assets--store-and-refresh session key (list :error (format "路径超出工作区：%s" rel))))
     (t
      (let* ((has-git (locate-dominating-file dir ".git"))
             (has-jj (and (not has-git) (locate-dominating-file dir ".jj")))
             (jj (and has-jj (or (executable-find "jjosh") (executable-find "jj"))))
             (cmd (if jj
                      (append (list jj "--repository" (expand-file-name has-jj) "log" "--no-graph"
                                    "-n" (number-to-string limit)
                                    "-T" "commit_id.short(7) ++ \"\\x1f\" ++ committer.timestamp().format(\"%Y-%m-%d\") ++ \"\\x1f\" ++ author.name() ++ \"\\x1f\" ++ description.first_line() ++ \"\\n\"")
                              (when rel (list (file-relative-name target (expand-file-name has-jj)))))
                    (append (list git "-C" dir "log"
                                  (format "-n%d" limit)
                                  "--date=short"
                                  "--pretty=format:%h\x1f%ad\x1f%an\x1f%s")
                            (when rel (list "--" (file-relative-name target dir)))))))
        (etaf-process-run
         cmd
         :name "etaf-md-git-log"
         :timeout 8
         :callback
         (lambda (res)
           (if (and (eq (plist-get res :status) 'exit)
                    (eql (plist-get res :exit) 0))
               (let ((rows
                      (delq nil
                            (mapcar
                             (lambda (line)
                               (let ((parts (split-string line "\x1f")))
                                 (when (>= (length parts) 4)
                                   (list :hash (nth 0 parts)
                                         :date (nth 1 parts)
                                         :author (nth 2 parts)
                                         :subject (if (string-blank-p (nth 3 parts))
                                                      "(working copy)"
                                                    (nth 3 parts))))))
                             (split-string (or (plist-get res :output) "") "\n" t)))))
                 (etaf-md-assets--store-and-refresh
                  session key (list :ok t :dir dir :rel rel :commits rows)))
             (etaf-md-assets--store-and-refresh
              session key (list :error "当前目录不是 Git 仓库或无提交历史"))))))))))

(defun etaf-md-assets--request-git-diff (session attrs key)
  "Populate `git-diff' asset asynchronously for ATTRS into KEY."
  (let* ((dir (etaf-md-assets--workspace-root session))
         (rel (plist-get attrs :path))
         (range (plist-get attrs :range))
         (target (when rel (etaf-md-assets--safe-path session rel)))
         (git (executable-find "git")))
    (cond
     ((not etaf-md-allow-local-read)
      (etaf-md-assets--store-and-refresh session key (list :error "本地读取已禁用")))
     ((null git)
      (etaf-md-assets--store-and-refresh session key (list :error "未检测到 git 程序")))
     ((and rel (null target))
      (etaf-md-assets--store-and-refresh session key (list :error (format "路径超出工作区：%s" rel))))
     (t
      (let ((cmd (append (list git "-C" dir "diff" "--no-color")
                         (when (and (stringp range) (not (string-blank-p range)))
                           (list range))
                         (when target (list "--" (file-relative-name target dir))))))
        (etaf-process-run
         cmd
         :name "etaf-md-git-diff"
         :timeout 8
         :callback
         (lambda (res)
           (if (and (eq (plist-get res :status) 'exit)
                    (eql (plist-get res :exit) 0))
               (let* ((raw (or (plist-get res :output) ""))
                      (lines (split-string raw "\n"))
                      (truncated (> (length lines) etaf-md-assets--max-lines))
                      (kept (if truncated
                                (seq-take lines etaf-md-assets--max-lines)
                              lines)))
                 (etaf-md-assets--store-and-refresh
                  session key
                  (list :ok t :dir dir :rel rel :range range
                        :truncated truncated
                        :empty (string-blank-p raw)
                        :lines kept)))
             (etaf-md-assets--store-and-refresh
              session key (list :error "无法获取 git diff（请确认处于 Git 仓库中）"))))))))))

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
            (pcase name
              ("git-log" (etaf-md-assets--request-git-log session attrs key))
              ("git-diff" (etaf-md-assets--request-git-diff session attrs key)))))))))

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
                (or (and session (plist-get session :dir)) default-directory))))
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
  "Toggle Markdown task checkbox on line at BEGIN + LINE-OFFSET in TEXT.
Returns updated string, or nil when no task marker was found on that line."
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
         (dir (or (and session (plist-get session :dir)) default-directory))
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
