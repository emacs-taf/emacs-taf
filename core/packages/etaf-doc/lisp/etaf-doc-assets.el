;;; etaf-doc-assets.el --- Shared workspace sandbox, slicing, symbol & VCS assets -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Shared read-only workspace asset helpers for living-document apps (`etaf-md',
;; `etaf-org'): symlink-safe workspace path confinement, language inference,
;; bounded source slicing (line range, `#region', Markdown heading section, or
;; symbol definition with balanced Elisp sexp parsing), Emacs symbol
;; introspection, bounded directory tree walking, and asynchronous Git/Jujutsu
;; log and diff runners.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)

(declare-function find-lisp-object-file-name "find-func" (object type))
(declare-function help-function-arglist "help-fns" (def &optional preserve-names))

(defconst etaf-doc-assets--default-max-file-bytes (* 64 1024)
  "Default maximum bytes read per workspace source file.")

(defconst etaf-doc-assets--default-max-lines 400
  "Default maximum lines returned for one source slice or diff snapshot.")

(defconst etaf-doc-assets--default-ignore
  '(".git" ".jj" "node_modules" ".DS_Store" "__pycache__" "target" "dist" "build" ".cache")
  "Directory and file names skipped during workspace scans.")

;;; ---------------------------------------------------------------------------
;;; Workspace boundary and path helpers
;;; ---------------------------------------------------------------------------

(defun etaf-doc-assets-workspace-root (dir)
  "Return the canonical workspace root directory containing DIR.
Searches upward for `.git' or `.jj', falling back to DIR itself."
  (let* ((base (expand-file-name (or dir default-directory)))
         (vcs (or (locate-dominating-file base ".git")
                  (locate-dominating-file base ".jj")))
         (root (or vcs base)))
    (file-name-as-directory
     (if (file-exists-p root) (file-truename root) (expand-file-name root)))))

(defun etaf-doc-assets-safe-path (dir relpath)
  "Resolve RELPATH relative to DIR strictly inside its workspace root.
Follows symlinks via `file-truename' before checking containment and returns
nil when RELPATH escapes the workspace root."
  (when (and (stringp relpath) (not (string-blank-p relpath)))
    (let* ((base (expand-file-name (or dir default-directory)))
           (root (etaf-doc-assets-workspace-root base))
           (candidate (expand-file-name (string-trim relpath) base))
           (resolved (if (file-exists-p candidate)
                         (file-truename candidate)
                       candidate))
           (root-true (if (file-exists-p root) (file-truename root) root)))
      (when (or (equal (file-name-as-directory resolved)
                       (file-name-as-directory root-true))
                (file-in-directory-p resolved root-true))
        candidate))))

(defun etaf-doc-assets-lang-for-path (path)
  "Infer a canonical syntax-highlight language tag from file PATH."
  (pcase (downcase (or (file-name-extension (or path "")) ""))
    ((or "el" "elisp") "elisp")
    ("py" "python")
    ((or "js" "mjs" "cjs") "js")
    ((or "ts" "tsx") "ts")
    ("jsx" "jsx")
    ("rs" "rust")
    ("go" "go")
    ((or "c" "h") "c")
    ((or "cc" "cpp" "cxx" "hpp") "cpp")
    ("java" "java")
    ((or "sh" "zsh") "sh")
    ("bash" "bash")
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

;;; ---------------------------------------------------------------------------
;;; Bounded source reading & slicing
;;; ---------------------------------------------------------------------------

(defun etaf-doc-assets--read-lines (path max-bytes)
  "Read up to MAX-BYTES of PATH as a list of lines."
  (with-temp-buffer
    (insert-file-contents path nil 0 max-bytes)
    (split-string (buffer-string) "\n")))

(defun etaf-doc-assets--parse-line-range (spec total max-lines)
  "Parse SPEC (`12-40' or `12') clamped to 1..TOTAL -> `(BEG . END)'."
  (cond
   ((and (stringp spec)
         (string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" (string-trim spec)))
    (let ((b (max 1 (string-to-number (match-string 1 spec))))
          (e (min total (string-to-number (match-string 2 spec)))))
      (cons (min b e) (max b e))))
   ((and (stringp spec) (string-match "\\`\\([0-9]+\\)\\'" (string-trim spec)))
    (let ((b (max 1 (min total (string-to-number (match-string 1 spec))))))
      (cons b b)))
   (t (cons 1 (min total max-lines)))))

(defun etaf-doc-assets--slice-lines (lines beg end max-lines)
  "Return 1-based inclusive slice BEG..END of LINES capped at MAX-LINES."
  (let* ((total (length lines))
         (b (max 1 (min (max 1 total) beg)))
         (e (max b (min total (min end (+ b max-lines -1))))))
    (list :start b
          :end e
          :truncated (> end e)
          :content (mapconcat #'identity (cl-subseq lines (1- b) e) "\n"))))

(defun etaf-doc-assets--find-elisp-sexp-end (lines hit)
  "Return the 1-based end line of the top-level Lisp form at HIT in LINES."
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

(defun etaf-doc-assets--find-symbol-range (lines sym context &optional lang)
  "Locate SYM definition in LINES; return `(BEG . END)' with CONTEXT lines.
For Emacs Lisp sources (LANG `elisp'), parses the complete balanced top-level
form via `forward-sexp' so closing parentheses are never clipped."
  (let* ((total (length lines))
         (ctx (max 0 (or context 0)))
         (q (regexp-quote sym))
         (def-re (format "\\(?:defun\\|defmacro\\|defsubst\\|defvar\\|defcustom\\|defconst\\|cl-defun\\|cl-defstruct\\|etaf-define-component\\|function\\|def\\|fn\\|class\\|struct\\|interface\\|type\\|const\\)[ \t]+%s\\(?:[ \t\n(\\[{:=;,]\\|\\'\\)" q))
         (hit (or (cl-loop for line in lines for idx from 1
                           when (string-match-p def-re line) return idx)
                  (cl-loop for line in lines for idx from 1
                           when (string-match-p
                                 (format "\\(?:\\`\\|[ \t\n(\\[{]\\)%s\\(?:[ \t\n(\\[{:=;,]\\|\\'\\)" q)
                                 line)
                           return idx))))
    (when hit
      (let* ((beg (max 1 (- hit ctx)))
             (sexp-end (and (equal lang "elisp")
                            (etaf-doc-assets--find-elisp-sexp-end lines hit)))
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
                        (setq e scan scan (1+ scan)))
                      e))))
        (cons beg (min total (+ end ctx)))))))

(defun etaf-doc-assets-read-slice (dir relpath &optional options)
  "Safely read a bounded source slice from RELPATH under DIR's workspace root.
OPTIONS is a plist supporting `:lines', `:region', `:section', `:symbol',
`:context', `:lang', `:default-lines', `:max-bytes' and `:max-lines'.
Returns a plist with `:ok t' and slice metadata, or `(:error MESSAGE)'."
  (if (or (null relpath) (not (stringp relpath)) (string-blank-p relpath))
      (list :error "缺少源文件路径")
    (let ((path (etaf-doc-assets-safe-path dir relpath)))
      (cond
       ((null path)
        (list :error (format "路径超出工作区范围：%s" relpath)))
       ((not (file-readable-p path))
        (list :error (format "找不到文件：%s" relpath)))
       ((file-directory-p path)
        (list :error (format "目标是目录而非文件：%s" relpath)))
       (t
        (let* ((max-bytes (or (plist-get options :max-bytes)
                              etaf-doc-assets--default-max-file-bytes))
               (max-lines (or (plist-get options :max-lines)
                              etaf-doc-assets--default-max-lines))
               (lines (etaf-doc-assets--read-lines path max-bytes))
               (total (length lines))
               (lang (or (plist-get options :lang)
                         (etaf-doc-assets-lang-for-path path)))
               (region (plist-get options :region))
               (section (plist-get options :section))
               (sym (plist-get options :symbol))
               (line-spec (plist-get options :lines))
               (default-lines (or (plist-get options :default-lines) max-lines))
               (raw-ctx (plist-get options :context))
               (ctx (cond ((integerp raw-ctx) raw-ctx)
                          ((and (stringp raw-ctx) (string-match-p "\\`[0-9]+\\'" raw-ctx))
                           (string-to-number raw-ctx))
                          (t 0)))
               (range
                (cond
                 ((and (stringp sym) (not (string-blank-p sym)))
                  (etaf-doc-assets--find-symbol-range lines sym ctx lang))
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
                    (if b (cons b (or e total))
                      (cons 1 (min total default-lines)))))
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
                    (if b (cons b (or e total))
                      (cons 1 (min total default-lines)))))
                 (line-spec
                  (etaf-doc-assets--parse-line-range line-spec total max-lines))
                 (t (cons 1 (min total default-lines))))))
          (if (null range)
              (list :error (format "在 %s 中未找到符号 %s" relpath sym))
            (let ((sliced (etaf-doc-assets--slice-lines lines (car range) (cdr range) max-lines)))
              (list :ok t
                    :path path
                    :rel relpath
                    :symbol sym
                    :lang lang
                    :start-line (plist-get sliced :start)
                    :end-line (plist-get sliced :end)
                    :total-lines total
                    :truncated (plist-get sliced :truncated)
                    :content (plist-get sliced :content))))))))))

;;; ---------------------------------------------------------------------------
;;; Live Emacs symbol introspection
;;; ---------------------------------------------------------------------------

(defun etaf-doc-assets--format-compact (value)
  "Format VALUE safely with bounded depth and circle protection."
  (let ((print-circle t) (print-length 8) (print-level 3))
    (let ((s (prin1-to-string value)))
      (if (> (length s) 120) (concat (substring s 0 117) "...") s))))

(defun etaf-doc-assets--first-paragraph (doc)
  "Return the first paragraph of DOC with wrapped lines joined cleanly."
  (when (and (stringp doc) (not (string-blank-p doc)))
    (let* ((trimmed (string-trim doc))
           (para (car (split-string trimmed "\n[ \t]*\n" t))))
      (when para
        (replace-regexp-in-string "[ \t]*\n[ \t]*" " " (string-trim para))))))

(defun etaf-doc-assets-inspect-symbol (name &optional workspace-dir)
  "Return live Emacs symbol introspection plist for NAME.
WORKSPACE-DIR, when supplied, computes `:rel-file' relative to its workspace."
  (let ((sym (and (stringp name) (not (string-blank-p name))
                  (intern-soft (string-trim name)))))
    (cond
     ((or (null name) (not (stringp name)) (string-blank-p name))
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
             (kind (cond (cmd-p "交互命令") (macro-p "宏") (fn-p "函数")
                         ((custom-variable-p sym) "可定制变量")
                         (var-p "变量") (face-p "Face") (t "符号")))
             (signature (when (and fn-p (fboundp 'help-function-arglist))
                          (ignore-errors
                            (let ((args (help-function-arglist sym t)))
                              (format "(%s%s)"
                                      (symbol-name sym)
                                      (if (and args (not (eq args t)))
                                          (concat " " (mapconcat #'prin1-to-string args " "))
                                        ""))))))
             (keys (when cmd-p
                     (let ((raw (where-is-internal sym nil nil t)))
                       (mapcar #'key-description (seq-take raw 4)))))
             (val (when var-p
                    (etaf-doc-assets--format-compact (symbol-value sym))))
             (doc (or (and fn-p (ignore-errors (documentation sym t)))
                      (and var-p (ignore-errors (documentation-property sym 'variable-documentation t)))
                      (and face-p (ignore-errors (documentation-property sym 'face-documentation t)))))
             (summary (etaf-doc-assets--first-paragraph doc))
             (src (when (fboundp 'find-lisp-object-file-name)
                    (or (and fn-p (ignore-errors (find-lisp-object-file-name sym (symbol-function sym))))
                        (and var-p (ignore-errors (find-lisp-object-file-name sym 'defvar))))))
             (src-file (and (stringp src)
                            (let ((el (if (string-suffix-p ".elc" src)
                                          (concat (substring src 0 -4) ".el")
                                        src)))
                              (if (file-readable-p el) el src))))
             (root (and workspace-dir (etaf-doc-assets-workspace-root workspace-dir)))
             (rel-file (when (and src-file root)
                         (let ((ts (ignore-errors (file-truename src-file))))
                           (if (and ts (file-in-directory-p ts root))
                               (file-relative-name ts root)
                             (file-name-nondirectory src-file))))))
        (list :ok t
              :name (symbol-name sym)
              :symbol sym
              :kind kind
              :signature signature
              :keys keys
              :value val
              :doc summary
              :summary summary
              :file src-file
              :rel-file (or rel-file (and src-file (file-name-nondirectory src-file)))))))))

;;; ---------------------------------------------------------------------------
;;; Bounded project directory tree
;;; ---------------------------------------------------------------------------

(defun etaf-doc-assets-project-tree (dir relpath &optional options)
  "Compute a bounded workspace directory tree for RELPATH under DIR.
OPTIONS accepts `:depth' (default 3, clamped 1..6), `:ignore' (extra names),
`:limit' (default 150) and `:trailing-slash' (append `/' to directories)."
  (let* ((rel (or relpath "."))
         (root (etaf-doc-assets-safe-path dir rel))
         (depth-raw (plist-get options :depth))
         (max-depth (min 6 (max 1 (cond ((integerp depth-raw) depth-raw)
                                        ((and (stringp depth-raw)
                                              (string-match-p "\\`[0-9]+\\'" depth-raw))
                                         (string-to-number depth-raw))
                                        (t 3)))))
         (extra-ignore (let ((ig (plist-get options :ignore)))
                         (cond ((listp ig) ig)
                               ((stringp ig) (split-string ig "[, \t]+" t))
                               (t nil))))
         (ignore-list (append etaf-doc-assets--default-ignore extra-ignore))
         (trailing-slash (plist-get options :trailing-slash))
         (remaining (or (plist-get options :limit) 150)))
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
           (scan (d depth)
             (when (and (> remaining 0) (<= depth max-depth))
               (let* ((raw (condition-case nil (directory-files d t nil t)
                             (file-error nil)))
                      (filtered (cl-remove-if
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
                       (push (list :name (if (and trailing-slash dir-p)
                                             (concat name "/")
                                           name)
                                   :path p
                                   :rel (file-relative-name p root)
                                   :dir dir-p
                                   :dir-p dir-p
                                   :children (when (and dir-p (< depth max-depth))
                                               (scan p (1+ depth))))
                             items))))
                 (nreverse items)))))
        (let ((tree (scan root 1)))
          (list :ok t
                :root root
                :path root
                :rel rel
                :truncated (<= remaining 0)
                :items tree
                :entries tree)))))))

;;; ---------------------------------------------------------------------------
;;; Asynchronous VCS log and diff (Git / Jujutsu)
;;; ---------------------------------------------------------------------------

(defun etaf-doc-assets-git-log-async (dir on-done &optional options)
  "Run Git or Jujutsu log asynchronously for DIR's workspace; invoke ON-DONE.
OPTIONS accepts `:path' (relative filter), `:limit' (default 8, max 50)."
  (let* ((root (etaf-doc-assets-workspace-root dir))
         (rel (plist-get options :path))
         (target (if rel (etaf-doc-assets-safe-path dir rel) root))
         (limit-raw (plist-get options :limit))
         (limit (min 50 (max 1 (cond ((integerp limit-raw) limit-raw)
                                     ((and (stringp limit-raw)
                                           (string-match-p "\\`[0-9]+\\'" limit-raw))
                                      (string-to-number limit-raw))
                                     (t 8)))))
         (git (executable-find "git"))
         (has-git (locate-dominating-file root ".git"))
         (has-jj (and (not has-git) (locate-dominating-file root ".jj")))
         (jj (and has-jj (or (executable-find "jjosh") (executable-find "jj")))))
    (cond
     ((and rel (null target))
      (funcall on-done (list :error (format "路径超出工作区：%s" rel))))
     ((and (null jj) (null git))
      (funcall on-done (list :error "未检测到 git 或 jj 程序")))
     (t
      (let ((cmd (if jj
                     (append
                      (list jj "--repository" (expand-file-name has-jj) "log" "--no-graph"
                            "-n" (number-to-string limit)
                            "-T" "commit_id.short(7) ++ \"\\x1f\" ++ committer.timestamp().format(\"%Y-%m-%d\") ++ \"\\x1f\" ++ author.name() ++ \"\\x1f\" ++ description.first_line() ++ \"\\n\"")
                      (when rel (list (file-relative-name target (expand-file-name has-jj)))))
                   (append
                    (list git "-C" root "log" (format "-n%d" limit)
                          "--date=short"
                          "--pretty=format:%h\x1f%ad\x1f%an\x1f%s")
                    (when rel (list "--" (file-relative-name target root)))))))
        (etaf-process-run
         cmd
         :name "etaf-doc-git-log"
         :timeout 10
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
                 (funcall on-done (list :ok t :dir root :rel rel :commits rows)))
             (funcall on-done
                      (list :error "当前目录不是 Git/Jujutsu 仓库或无提交历史"))))))))))

(defun etaf-doc-assets-git-diff-async (dir on-done &optional options)
  "Run Git or Jujutsu diff asynchronously for DIR's workspace; invoke ON-DONE.
OPTIONS accepts `:path', `:range' (or `:rev') and `:max-lines' (default 400)."
  (let* ((root (etaf-doc-assets-workspace-root dir))
         (rel (plist-get options :path))
         (range (or (plist-get options :range) (plist-get options :rev)))
         (max-lines (or (plist-get options :max-lines) etaf-doc-assets--default-max-lines))
         (target (when rel (etaf-doc-assets-safe-path dir rel)))
         (git (executable-find "git"))
         (has-git (locate-dominating-file root ".git"))
         (has-jj (and (not has-git) (locate-dominating-file root ".jj")))
         (jj (and has-jj (or (executable-find "jjosh") (executable-find "jj")))))
    (cond
     ((and rel (null target))
      (funcall on-done (list :error (format "路径超出工作区：%s" rel))))
     ((and (null jj) (null git))
      (funcall on-done (list :error "未检测到 git 或 jj 程序")))
     (t
      (let ((cmd (if jj
                     (append
                      (list jj "--repository" (expand-file-name has-jj) "diff" "--git" "--color=never")
                      (when (and (stringp range) (not (string-blank-p range))) (list "-r" range))
                      (when target (list (file-relative-name target (expand-file-name has-jj)))))
                   (append
                    (list git "-C" root "diff" "--no-color")
                    (when (and (stringp range) (not (string-blank-p range))) (list range))
                    (when target (list "--" (file-relative-name target root)))))))
        (etaf-process-run
         cmd
         :name "etaf-doc-git-diff"
         :timeout 10
         :callback
         (lambda (res)
           (if (and (eq (plist-get res :status) 'exit)
                    (eql (plist-get res :exit) 0))
               (let* ((raw (or (plist-get res :output) ""))
                      (lines (split-string raw "\n"))
                      (truncated (> (length lines) max-lines))
                      (kept (if truncated (seq-take lines max-lines) lines)))
                 (funcall on-done
                          (list :ok t :dir root :rel rel :range range
                                :truncated truncated
                                :empty (string-blank-p raw)
                                :lines kept)))
             (funcall on-done
                      (list :error "无法获取 git/jj diff（请确认处于仓库中）"))))))))))

(provide 'etaf-doc-assets)
;;; etaf-doc-assets.el ends here
