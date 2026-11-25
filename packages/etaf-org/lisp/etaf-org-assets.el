;;; etaf-org-assets.el --- Workspace sandbox assets (L1) & actions (L2) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Read-only workspace assets (L1) and explicit user-triggered actions (L2)
;; powering the living-document features of `etaf-org'.
;;
;; Every filesystem read, subprocess and network call stays strictly outside
;; ETAF's `:render' phase:
;; - Publish-time bounded L1 snapshots: `#+SETUPFILE:', `#+INCLUDE:',
;;   `#+BIBLIOGRAPHY:' (`.bib' / CSL JSON), `include', `code-ref', `symbol',
;;   `project-tree', `org-query', `kanban', `clock-summary', `transclude'.
;; - Async background L1 jobs (`etaf-process-run`): `git-log', `git-diff',
;;   `backlinks' (rg/Elisp).
;; - Explicit L2 actions: `run', source checkbox toggling
;;   (`etaf-org-interactive-checkbox'), opt-in TODO cycling
;;   (`etaf-org-interactive-todo'), and opt-in Babel execution
;;   (`etaf-org-allow-babel').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'etaf)
(require 'etaf-org-cache)
(require 'etaf-org-parse)
(require 'etaf-org-derive)
(require 'etaf-org-env)

(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--refresh-block-assets "etaf-org-model" (session))
(declare-function etaf-org--walk-document-blocks "etaf-org-model" (document fn))
(declare-function etaf-org-refresh "etaf-org-model" (session))
(declare-function find-lisp-object-file-name "find-func" (object type))
(declare-function help-function-arglist "help-fns" (def &optional preserve-names))
(declare-function org-babel-execute-src-block "ob-core" (&optional arg info params executor-type))
(declare-function org-id-find "org-id" (id &optional markerp))
(defvar org-confirm-babel-evaluate)

;;; ---------------------------------------------------------------------------
;;; Trust & behavior customization
;;; ---------------------------------------------------------------------------

(defcustom etaf-org-allow-local-read t
  "Whether read-only workspace features may read files inside the project root.
Applies to `#+SETUPFILE:', `#+INCLUDE:', `#+BIBLIOGRAPHY:', `include',
`code-ref', `project-tree', `org-query', `kanban', `transclude', `git-log',
`git-diff' and `backlinks'.  Paths escaping the workspace root are always
rejected."
  :type 'boolean
  :group 'etaf-org)

(defcustom etaf-org-allow-actions 'ask
  "Whether explicit executable widget actions (`run') are permitted.
`ask' prompts with `yes-or-no-p' before each execution, `t' allows execution
without prompting, and `nil' disables execution."
  :type '(choice (const :tag "Prompt before running" ask)
                 (const :tag "Allow without prompt" t)
                 (const :tag "Disable executable actions" nil))
  :group 'etaf-org)

(defcustom etaf-org-allow-babel nil
  "Whether `#+begin_src' blocks show an explicit `[运行]' Babel trigger.
Default nil keeps code blocks completely non-executable.  `ask' prompts
before executing via Org Babel; `t' runs on click without prompting."
  :type '(choice (const :tag "Disabled (read-only)" nil)
                 (const :tag "Prompt before executing" ask)
                 (const :tag "Execute on click" t))
  :group 'etaf-org)

(defcustom etaf-org-interactive-checkbox t
  "Whether clicking a checkbox toggles `[ ]' and `[X]' in source.
Also updates enclosing `[n/m]' and `[p%]' progress cookies."
  :type 'boolean
  :group 'etaf-org)

(defcustom etaf-org-interactive-todo nil
  "Whether clicking a headline TODO chip cycles its keyword in source."
  :type 'boolean
  :group 'etaf-org)

(defcustom etaf-org-media-lightbox 'auto
  "Whether activating a local image opens the in-buffer media lightbox.
`auto' uses the lightbox on graphical frames and opens externally in text/batch;
`t' always uses the lightbox; `nil' always opens externally."
  :type '(choice (const :tag "On graphical frames" auto)
                 (const :tag "Always use lightbox" t)
                 (const :tag "Open externally" nil))
  :group 'etaf-org)

(defconst etaf-org-assets--max-file-bytes (* 64 1024)
  "Maximum bytes read per workspace source file.")

(defconst etaf-org-assets--max-lines 400
  "Maximum lines kept for one source slice snapshot.")

(defconst etaf-org-assets--max-workspace-files 200
  "Maximum `.org' files scanned for `org-query' / `backlinks'.")

(defconst etaf-org-assets--default-ignore
  '(".git" ".jj" "node_modules" ".DS_Store" "__pycache__" "target" "dist" "build" ".cache")
  "Directory and file names skipped during workspace scans.")

;;; ---------------------------------------------------------------------------
;;; Workspace sandbox helpers
;;; ---------------------------------------------------------------------------

(defun etaf-org-assets--workspace-root (session)
  "Return the canonical workspace root directory for SESSION."
  (let* ((dir (expand-file-name (or (and session (plist-get session :dir))
                                    default-directory)))
         (vcs (or (locate-dominating-file dir ".git")
                  (locate-dominating-file dir ".jj")))
         (root (or vcs dir)))
    (file-name-as-directory
     (if (file-exists-p root) (file-truename root) (expand-file-name root)))))

(defun etaf-org-assets--safe-path (session relpath)
  "Resolve RELPATH strictly inside SESSION's workspace root, or return nil."
  (when (and (stringp relpath) (not (string-blank-p relpath)))
    (let* ((base (expand-file-name (or (and session (plist-get session :dir))
                                       default-directory)))
           (root (etaf-org-assets--workspace-root session))
           (candidate (expand-file-name (string-trim relpath) base))
           (resolved (if (file-exists-p candidate) (file-truename candidate) candidate))
           (root-true (if (file-exists-p root) (file-truename root) root)))
      (when (or (equal (file-name-as-directory resolved)
                       (file-name-as-directory root-true))
                (file-in-directory-p resolved root-true))
        candidate))))

(defun etaf-org-assets--lang-for-path (path)
  "Infer syntax highlight language from PATH extension."
  (pcase (downcase (or (file-name-extension path) ""))
    ((or "el" "elisp") "elisp") ("py" "python")
    ((or "js" "mjs" "cjs") "js") ((or "ts" "tsx") "ts") ("jsx" "jsx")
    ("rs" "rust") ("go" "go") ("c" "c") ("h" "c")
    ((or "cc" "cpp" "cxx" "hpp") "cpp") ("java" "java")
    ((or "sh" "bash" "zsh") "sh") ("json" "json") ((or "yml" "yaml") "yaml")
    ("toml" "toml") ("css" "css") ((or "html" "htm") "html") ("xml" "xml")
    ("sql" "sql") ((or "md" "markdown") "markdown") ("org" "org")
    (ext (if (string-empty-p ext) "text" ext))))

(defun etaf-org-assets--read-lines (path)
  "Read up to `etaf-org-assets--max-file-bytes' of PATH as lines."
  (with-temp-buffer
    (insert-file-contents path nil 0 etaf-org-assets--max-file-bytes)
    (split-string (buffer-string) "\n")))

(defun etaf-org-assets--parse-line-range (spec total)
  "Parse SPEC (`10-30' or `10') clamped to 1..TOTAL -> `(BEG . END)'."
  (cond
   ((and (stringp spec)
         (string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" (string-trim spec)))
    (let ((b (max 1 (string-to-number (match-string 1 spec))))
          (e (min total (string-to-number (match-string 2 spec)))))
      (cons (min b e) (max b e))))
   ((and (stringp spec) (string-match "\\`\\([0-9]+\\)\\'" (string-trim spec)))
    (let ((b (max 1 (min total (string-to-number (match-string 1 spec))))))
      (cons b b)))
   (t (cons 1 (min total etaf-org-assets--max-lines)))))

(defun etaf-org-assets--slice-lines (lines beg end)
  "Return 1-based inclusive slice BEG..END of LINES."
  (let* ((total (length lines))
         (b (max 1 (min (max 1 total) beg)))
         (e (max b (min total (min end (+ b etaf-org-assets--max-lines -1))))))
    (list :start b :end e :truncated (> end e)
          :content (mapconcat #'identity (cl-subseq lines (1- b) e) "\n"))))

;;; ---------------------------------------------------------------------------
;;; Native Org L1: #+SETUPFILE:, #+INCLUDE:, #+BIBLIOGRAPHY:
;;; ---------------------------------------------------------------------------

(defun etaf-org-assets-collect-setupfiles (session text &optional visited depth)
  "Collect `#+KEY:' setting lines from local `#+SETUPFILE:' directives in TEXT.
Respects `etaf-org-allow-local-read', workspace root, cycle detection and max
depth 4.  Runs before parse, never inside `:render'."
  (when (and etaf-org-allow-local-read (< (or depth 0) 4))
    (let ((seen (or visited (make-hash-table :test #'equal)))
          (collected nil)
          (pos 0)
          (case-fold-search t))
      (while (string-match "^[ \t]*#\\+SETUPFILE:[ \t]*\\(.*\\)$" text pos)
        (setq pos (match-end 0))
        (let* ((raw (string-trim (match-string 1 text) "[ \t\"]+" "[ \t\"]+"))
               (path (etaf-org-assets--safe-path session raw))
               (true (and path (file-readable-p path) (file-truename path))))
          (when (and true (not (gethash true seen)))
            (puthash true t seen)
            (let ((body (with-temp-buffer
                          (insert-file-contents path nil 0 etaf-org-assets--max-file-bytes)
                          (buffer-string))))
              (setq collected
                    (append collected
                            (etaf-org-assets-collect-setupfiles
                             session body seen (1+ (or depth 0)))
                            (split-string body "\n")))))))
      collected)))

(defun etaf-org-assets--parse-bib-text (text)
  "Parse BibTeX TEXT into a hash table mapping cite key to metadata plist."
  (let ((table (make-hash-table :test #'equal))
        (pos 0)
        (case-fold-search t))
    (while (string-match "@\\([A-Za-z]+\\)[ \t]*{[ \t]*\\([^, \t\n]+\\)[ \t]*," text pos)
      (let* ((entry-type (downcase (match-string 1 text)))
             (key (string-trim (match-string 2 text)))
             (scan (match-end 0))
             (depth 1)
             (len (length text)))
        (while (and (< scan len) (> depth 0))
          (let ((ch (aref text scan)))
            (cond ((eq ch ?{) (cl-incf depth))
                  ((eq ch ?}) (cl-decf depth))))
          (cl-incf scan))
        (let ((body (substring text (match-end 0) (max (match-end 0) (1- scan))))
              (fields (list :key key :entry-type entry-type))
              (fpos 0))
          (while (string-match
                  "\\([A-Za-z][A-Za-z0-9_-]*\\)[ \t]*=[ \t]*\\(?:{\\([^}]*\\)}\\|\"\\([^\"]*\\)\"\\|\\([0-9]+\\)\\)"
                  body fpos)
            (let* ((fk (intern (concat ":" (downcase (match-string 1 body)))))
                   (fv (string-trim
                        (replace-regexp-in-string
                         "[ \t\n]+" " "
                         (or (match-string 2 body)
                             (match-string 3 body)
                             (match-string 4 body) "")))))
              (setq fields (plist-put fields fk fv))
              (setq fpos (match-end 0))))
          (unless (member entry-type '("comment" "preamble" "string"))
            (puthash key fields table)))
        (setq pos scan)))
    table))

(defun etaf-org-assets-load-bibliographies (session document)
  "Load local `#+BIBLIOGRAPHY:' `.bib' or `.json' files for DOCUMENT."
  (let ((table (make-hash-table :test #'equal)))
    (when etaf-org-allow-local-read
      (dolist (rel (plist-get document :bibliographies))
        (when-let* ((path (etaf-org-assets--safe-path session rel))
                    ((file-readable-p path)))
          (let ((ext (downcase (or (file-name-extension path) "")))
                (text (with-temp-buffer
                        (insert-file-contents path nil 0 (* 256 1024))
                        (buffer-string))))
            (if (equal ext "json")
                (when-let* ((items (ignore-errors
                                     (json-parse-string text :object-type 'plist
                                                        :array-type 'list))))
                  (dolist (item items)
                    (when-let* ((id (plist-get item :id)))
                      (puthash id
                               (list :key id
                                     :title (plist-get item :title)
                                     :author (let ((au (plist-get item :author)))
                                               (if (listp au)
                                                   (mapconcat (lambda (a)
                                                                (or (plist-get a :family)
                                                                    (plist-get a :literal) ""))
                                                              au ", ")
                                                 (format "%s" (or au ""))))
                                     :year (let ((iss (plist-get item :issued)))
                                             (format "%s"
                                                     (or (car (car (plist-get iss :date-parts)))
                                                         "")))
                                     :doi (plist-get item :DOI))
                               table))))
              (maphash (lambda (k v) (puthash k v table))
                       (etaf-org-assets--parse-bib-text text)))))))
    table))

(defun etaf-org-assets--compute-org-include (session block)
  "Compute L1 expansion for native `#+INCLUDE: target args' BLOCK."
  (let ((target (plist-get block :target))
        (args (or (plist-get block :args) "")))
    (cond
     ((not etaf-org-allow-local-read)
      (list :disabled t :target target))
     (t
      (let* ((parts (split-string (or target "") "::"))
             (file-part (car parts))
             (search (cadr parts))
             (path (etaf-org-assets--safe-path session file-part)))
        (cond
         ((null path)
          (list :error (format "路径超出工作区范围：%s" target)))
         ((not (file-readable-p path))
          (list :error (format "找不到包含文件：%s" target)))
         (t
          (let* ((plist (car (etaf-org--parse-plist-string args)))
                 (line-spec (plist-get plist :lines))
                 (kind (cond
                        ((string-match "\\`src[ \t]+\\([^ \t]+\\)" args)
                         (cons 'src (match-string 1 args)))
                        ((string-match-p "\\`example\\b" args) (cons 'example nil))
                        ((string-match-p "\\`quote\\b" args) (cons 'quote nil))
                        (t (cons 'org nil))))
                 (lines (etaf-org-assets--read-lines path))
                 (total (length lines)))
            (if (eq (car kind) 'org)
                (etaf-org-assets--compute-transclude
                 session
                 (list :target target
                       :only-contents (plist-get plist :only-contents)))
              (let* ((range (etaf-org-assets--parse-line-range line-spec total))
                     (sliced (etaf-org-assets--slice-lines lines (car range) (cdr range))))
                (list :ok t :kind (car kind)
                      :lang (or (cdr kind) (etaf-org-assets--lang-for-path path))
                      :path path :rel file-part :search search
                      :start-line (plist-get sliced :start)
                      :end-line (plist-get sliced :end)
                      :content (plist-get sliced :content))))))))))))

;;; ---------------------------------------------------------------------------
;;; L1 Sync Workspace Widgets (include, code-ref, symbol, project-tree)
;;; ---------------------------------------------------------------------------

(defun etaf-org-assets--compute-include (session attrs)
  "Compute `#+begin_include' L1 snapshot for ATTRS in SESSION."
  (let ((src (plist-get attrs :src)))
    (cond
     ((not etaf-org-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-org-allow-local-read 为 nil）"))
     ((or (null src) (string-blank-p src))
      (list :error "include 缺少 :src 属性"))
     (t
      (let ((path (etaf-org-assets--safe-path session src)))
        (cond
         ((null path) (list :error (format "路径超出工作区范围：%s" src)))
         ((not (file-readable-p path)) (list :error (format "找不到文件：%s" src)))
         ((file-directory-p path) (list :error (format "目标是目录而非文件：%s" src)))
         (t
          (let* ((lines (etaf-org-assets--read-lines path))
                 (total (length lines))
                 (range (etaf-org-assets--parse-line-range (plist-get attrs :lines) total))
                 (sliced (etaf-org-assets--slice-lines lines (car range) (cdr range))))
            (list :ok t :path path :rel src
                  :lang (or (plist-get attrs :lang) (etaf-org-assets--lang-for-path path))
                  :start-line (plist-get sliced :start)
                  :end-line (plist-get sliced :end)
                  :total-lines total
                  :truncated (plist-get sliced :truncated)
                  :content (plist-get sliced :content))))))))))

(defun etaf-org-assets--find-elisp-sexp-end (lines hit)
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

(defun etaf-org-assets--find-symbol-range (lines sym context &optional lang)
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
                            (etaf-org-assets--find-elisp-sexp-end lines hit)))
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

(defun etaf-org-assets--compute-code-ref (session attrs)
  "Compute `#+begin_code-ref' live slice for ATTRS in SESSION."
  (let* ((src (plist-get attrs :src))
         (sym (plist-get attrs :symbol))
         (line-spec (plist-get attrs :lines))
         (raw-ctx (plist-get attrs :context))
         (ctx (cond ((integerp raw-ctx) raw-ctx)
                    ((and (stringp raw-ctx) (string-match-p "\\`[0-9]+\\'" raw-ctx))
                     (string-to-number raw-ctx))
                    (t 0))))
    (cond
     ((not etaf-org-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-org-allow-local-read 为 nil）"))
     ((or (null src) (string-blank-p src))
      (list :error "code-ref 缺少 :src 属性"))
     (t
      (let ((path (etaf-org-assets--safe-path session src)))
        (cond
         ((null path) (list :error (format "路径超出工作区范围：%s" src)))
         ((not (file-readable-p path)) (list :error (format "找不到源码文件：%s" src)))
         (t
          (let* ((lines (etaf-org-assets--read-lines path))
                 (total (length lines))
                 (lang (or (plist-get attrs :lang) (etaf-org-assets--lang-for-path path)))
                 (range (cond
                         ((and (stringp sym) (not (string-blank-p sym)))
                          (etaf-org-assets--find-symbol-range lines sym ctx lang))
                         (line-spec (etaf-org-assets--parse-line-range line-spec total))
                         (t (cons 1 (min total 24))))))
            (if (null range)
                (list :error (format "在 %s 中未找到符号 %s" src sym))
              (let ((sliced (etaf-org-assets--slice-lines lines (car range) (cdr range))))
                (list :ok t :path path :rel src :symbol sym
                      :lang lang
                      :start-line (plist-get sliced :start)
                      :end-line (plist-get sliced :end)
                      :content (plist-get sliced :content))))))))))))

(defun etaf-org-assets--format-compact (value)
  "Format VALUE with circle and depth limits."
  (let ((print-circle t) (print-length 8) (print-level 3))
    (let ((s (prin1-to-string value)))
      (if (> (length s) 120) (concat (substring s 0 117) "...") s))))

(defun etaf-org-assets--first-paragraph (doc)
  "Return the complete first paragraph of DOC with wrapped lines joined cleanly."
  (when (and (stringp doc) (not (string-blank-p doc)))
    (let* ((trimmed (string-trim doc))
           (para (car (split-string trimmed "\n[ \t]*\n" t))))
      (when para
        (replace-regexp-in-string "[ \t]*\n[ \t]*" " " (string-trim para))))))

(defun etaf-org-assets-compute-symbol (attrs &optional session)
  "Compute live Emacs symbol introspection card data for ATTRS in SESSION."
  (let* ((name (plist-get attrs :name))
         (sym (and (stringp name) (intern-soft (string-trim name)))))
    (cond
     ((or (null name) (string-blank-p name))
      (list :error "symbol 缺少 :name 属性"))
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
             (doc (or (and fn-p (ignore-errors (documentation sym t)))
                      (and var-p (ignore-errors (documentation-property sym 'variable-documentation t)))
                      (and face-p (ignore-errors (documentation-property sym 'face-documentation t)))))
             (summary (etaf-org-assets--first-paragraph doc))
             (val (when var-p (etaf-org-assets--format-compact (symbol-value sym))))
             (src (when (fboundp 'find-lisp-object-file-name)
                    (or (and fn-p (ignore-errors (find-lisp-object-file-name sym (symbol-function sym))))
                        (and var-p (ignore-errors (find-lisp-object-file-name sym 'defvar))))))
             (src-file (and (stringp src)
                            (let ((el (if (string-suffix-p ".elc" src)
                                          (concat (substring src 0 -4) ".el")
                                        src)))
                              (if (file-readable-p el) el src))))
             (root (and session (etaf-org-assets--workspace-root session)))
             (rel-file (when (and src-file root)
                         (let ((ts (ignore-errors (file-truename src-file))))
                           (if (and ts (file-in-directory-p ts root))
                               (file-relative-name ts root)
                             (file-name-nondirectory src-file))))))
        (list :ok t :name (symbol-name sym) :kind kind
              :signature signature :keys keys :summary summary :doc summary
              :value val :file src-file
              :rel-file (or rel-file (and src-file (file-name-nondirectory src-file)))))))))

(defun etaf-org-assets--walk-dir (dir depth max-depth)
  "Walk DIR up to MAX-DEPTH returning tree nodes."
  (when (and (file-directory-p dir) (<= depth max-depth))
    (let ((entries (sort (directory-files dir nil "\\`[^.]" t) #'string<))
          (out nil))
      (dolist (name entries)
        (unless (or (member name etaf-org-assets--default-ignore)
                    (string-suffix-p ".elc" name))
          (let* ((full (expand-file-name name dir))
                 (dir-p (file-directory-p full)))
            (push (list :name (if dir-p (concat name "/") name)
                        :path full :dir dir-p
                        :children (when (and dir-p (< depth max-depth))
                                    (etaf-org-assets--walk-dir full (1+ depth) max-depth)))
                  out))))
      (nreverse out))))

(defun etaf-org-assets--compute-project-tree (session attrs)
  "Compute `#+begin_project-tree' directory tree inside workspace sandbox."
  (if (not etaf-org-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-org-allow-local-read 为 nil）")
    (let* ((rel (or (plist-get attrs :path) "."))
           (raw-depth (plist-get attrs :depth))
           (depth (max 1 (min 5 (cond ((integerp raw-depth) raw-depth)
                                      ((and (stringp raw-depth)
                                            (string-match-p "\\`[0-9]+\\'" raw-depth))
                                       (string-to-number raw-depth))
                                      (t 2)))))
           (dir (etaf-org-assets--safe-path session rel)))
      (cond
       ((null dir) (list :error (format "路径超出工作区范围：%s" rel)))
       ((not (file-directory-p dir)) (list :error (format "目录不存在：%s" rel)))
       (t (list :ok t :path dir :rel rel
                :entries (etaf-org-assets--walk-dir dir 1 depth)))))))

;;; ---------------------------------------------------------------------------
;;; Org-Exclusive L1 Superpowers: org-query, kanban, clock-summary, transclude
;;; ---------------------------------------------------------------------------

(defun etaf-org-assets--collect-org-files (dir max-files)
  "Collect up to MAX-FILES `.org' files recursively under DIR."
  (let ((files nil))
    (cl-labels ((walk (d depth)
                  (when (and (file-directory-p d) (<= depth 4)
                             (< (length files) max-files))
                    (dolist (name (sort (directory-files d nil "\\`[^.]" t) #'string<))
                      (unless (or (member name etaf-org-assets--default-ignore)
                                  (>= (length files) max-files))
                        (let ((full (expand-file-name name d)))
                          (cond
                           ((file-directory-p full) (walk full (1+ depth)))
                           ((string-suffix-p ".org" (downcase name))
                            (push full files)))))))))
      (walk dir 1))
    (nreverse files)))

(defun etaf-org-assets--extract-section-rows (doc file-label)
  "Flatten sections of DOC into queryable row plists."
  (let ((rows nil))
    (cl-labels ((walk (sections)
                  (dolist (sec sections)
                    (let* ((plan (etaf-org-section-planning sec))
                           (dl (plist-get plan :deadline))
                           (sc (plist-get plan :scheduled))
                           (clk (cl-loop for e in (etaf-org-section-logbook sec)
                                         sum (or (plist-get e :minutes) 0))))
                      (push (list :id (etaf-org-section-id sec)
                                  :level (etaf-org-section-level sec)
                                  :title (etaf-org-section-title-plain sec)
                                  :todo (etaf-org-section-todo sec)
                                  :todo-state (etaf-org-section-todo-state sec)
                                  :priority (etaf-org-section-priority sec)
                                  :tags (etaf-org-section-effective-tags sec)
                                  :own-tags (etaf-org-section-tags sec)
                                  :properties (etaf-org-section-properties sec)
                                  :deadline (and dl (plist-get dl :raw))
                                  :scheduled (and sc (plist-get sc :raw))
                                  :overdue (plist-get plan :overdue)
                                  :clock-minutes clk
                                  :file (plist-get doc :file)
                                  :file-label file-label
                                  :line-start (etaf-org-section-line-start sec))
                            rows))
                    (walk (etaf-org-section-children sec)))))
      (walk (plist-get doc :sections)))
    (nreverse rows)))

(defun etaf-org-assets--match-query-row (row attrs)
  "Return non-nil when query ROW satisfies filter ATTRS."
  (let ((todo-want (plist-get attrs :todo))
        (tags-want (plist-get attrs :tags))
        (pri-want (plist-get attrs :priority))
        (where-want (plist-get attrs :where))
        (ok t))
    (when (and ok todo-want (not (string-blank-p todo-want)))
      (let ((allowed (mapcar #'upcase (split-string todo-want "[, \t]+" t)))
            (actual (upcase (or (plist-get row :todo) ""))))
        (unless (member actual allowed)
          (setq ok nil))))
    (when (and ok tags-want (not (string-blank-p tags-want)))
      (let ((rt (plist-get row :tags)))
        (dolist (tok (split-string tags-want "[, \t]+" t))
          (if (string-prefix-p "-" tok)
              (when (member (substring tok 1) rt) (setq ok nil))
            (unless (member (string-trim-left tok "\\+") rt) (setq ok nil))))))
    (when (and ok pri-want (not (string-blank-p pri-want)))
      (let ((allowed (mapcar #'upcase (split-string pri-want "[, \t#]+" t))))
        (unless (member (upcase (or (plist-get row :priority) "")) allowed)
          (setq ok nil))))
    (when (and ok where-want (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" where-want))
      (let* ((k (upcase (string-trim (match-string 1 where-want))))
             (v (string-trim (match-string 2 where-want)))
             (pv (or (cdr (assoc-string k (plist-get row :properties) t)) "")))
        (unless (equal pv v) (setq ok nil))))
    ok))

(defun etaf-org-assets--compute-org-query (session document attrs &optional section)
  "Compute `#+begin_org-query' or `#+begin_kanban' rows for ATTRS."
  (let* ((scope (downcase (or (plist-get attrs :scope)
                              (plist-get attrs :source)
                              "file")))
         (rows nil))
    (cond
     ((and (equal scope "workspace") (not etaf-org-allow-local-read))
      (list :error "工作区查询需要开启 etaf-org-allow-local-read"))
     ((equal scope "workspace")
      (let* ((root (etaf-org-assets--workspace-root session))
             (files (etaf-org-assets--collect-org-files root 60))
             (today (plist-get session :today)))
        (dolist (file files)
          (let* ((txt (with-temp-buffer
                        (insert-file-contents file nil 0 etaf-org-assets--max-file-bytes)
                        (buffer-string)))
                 (subdoc (etaf-org-derive
                          (etaf-org--parse txt :file file :flavor 'standard)
                          today)))
            (setq rows (append rows
                               (etaf-org-assets--extract-section-rows
                                subdoc (file-relative-name file root))))))))
     ((and (equal scope "subtree") section)
      (setq rows (etaf-org-assets--extract-section-rows
                  (list :sections (etaf-org-section-children section)
                        :file (plist-get document :file))
                  (etaf-org-section-title-plain section))))
     ((string-prefix-p "#" scope)
      (let* ((target-id (substring scope 1))
             (sec-map (plist-get document :section-by-id))
             (sec (and (hash-table-p sec-map) (gethash target-id sec-map))))
        (if sec
            (setq rows (etaf-org-assets--extract-section-rows
                        (list :sections (etaf-org-section-children sec)
                              :file (plist-get document :file))
                        (etaf-org-section-title-plain sec)))
          (setq rows nil))))
     (t
      (setq rows (etaf-org-assets--extract-section-rows
                  document (or (and (plist-get document :file)
                                    (file-name-nondirectory (plist-get document :file)))
                               "当前文档")))))
    (if (plist-get rows :error)
        rows
      (let* ((filtered (cl-remove-if-not
                        (lambda (r) (etaf-org-assets--match-query-row r attrs))
                        rows))
             (sort-key (downcase (or (plist-get attrs :sort) "")))
             (sorted
              (pcase sort-key
                ("deadline"
                 (sort filtered (lambda (a b)
                                  (string< (or (plist-get a :deadline) "9999")
                                           (or (plist-get b :deadline) "9999")))))
                ("scheduled"
                 (sort filtered (lambda (a b)
                                  (string< (or (plist-get a :scheduled) "9999")
                                           (or (plist-get b :scheduled) "9999")))))
                ("priority"
                 (sort filtered (lambda (a b)
                                  (string< (or (plist-get a :priority) "Z")
                                           (or (plist-get b :priority) "Z")))))
                ("title"
                 (sort filtered (lambda (a b)
                                  (string< (or (plist-get a :title) "")
                                           (or (plist-get b :title) "")))))
                (_ filtered)))
             (limit (let ((raw (plist-get attrs :limit)))
                      (cond ((integerp raw) raw)
                            ((and (stringp raw) (string-match-p "\\`[0-9]+\\'" raw))
                             (string-to-number raw))
                            (t 50)))))
        (list :ok t :scope scope
              :total (length sorted)
              :rows (cl-subseq sorted 0 (min limit (length sorted))))))))

(defun etaf-org-assets--compute-clock-summary (document attrs &optional section)
  "Compute `#+begin_clock-summary' aggregated time entries from DOCUMENT."
  (let* ((scope (downcase (or (plist-get attrs :scope) "file")))
         (group-by (downcase (or (plist-get attrs :group-by) "section")))
         (roots (if (and (equal scope "subtree") section)
                    (list section)
                  (plist-get document :sections)))
         (buckets (make-hash-table :test #'equal))
         (order nil)
         (total 0))
    (cl-labels ((add-mins (key mins)
                  (when (> mins 0)
                    (unless (gethash key buckets) (push key order))
                    (puthash key (+ (gethash key buckets 0) mins) buckets)
                    (setq total (+ total mins))))
                (walk (secs)
                  (dolist (sec secs)
                    (let ((mins (cl-loop for e in (etaf-org-section-logbook sec)
                                         sum (or (plist-get e :minutes) 0))))
                      (when (> mins 0)
                        (if (equal group-by "tag")
                            (let ((tags (or (etaf-org-section-effective-tags sec) '("未分类"))))
                              (dolist (tag tags) (add-mins (concat ":" tag ":") mins)))
                          (add-mins (etaf-org-section-title-plain sec) mins))))
                    (walk (etaf-org-section-children sec)))))
      (walk roots))
    (list :ok t
          :total-minutes total
          :group-by group-by
          :items (mapcar (lambda (k) (cons k (gethash k buckets 0)))
                         (nreverse order)))))

(defun etaf-org-assets--find-section-in-doc (doc search)
  "Locate section in DOC matching SEARCH (`#custom-id', `*Title' or plain title)."
  (let* ((s (string-trim (or search "")))
         (sec-map (plist-get doc :section-by-id)))
    (cond
     ((string-prefix-p "#" s)
      (and (hash-table-p sec-map) (gethash (substring s 1) sec-map)))
     ((string-prefix-p "*" s)
      (let ((want (string-trim (string-trim-left s "\\*+")))
            (found nil))
        (cl-labels ((walk (secs)
                      (dolist (sec secs)
                        (when (and (null found)
                                   (equal (etaf-org-section-title-plain sec) want))
                          (setq found sec))
                        (walk (etaf-org-section-children sec)))))
          (walk (plist-get doc :sections)))
        found))
     (t
      (or (and (hash-table-p sec-map) (gethash s sec-map))
          (etaf-org-assets--find-section-in-doc doc (concat "*" s)))))))

(defun etaf-org-assets--compute-transclude (session attrs &optional depth)
  "Compute `#+begin_transclude' read-only Org section snapshot with cycle cap."
  (let ((target (plist-get attrs :target))
        (only-contents (plist-get attrs :only-contents)))
    (cond
     ((not etaf-org-allow-local-read)
      (list :error "本地文件读取已禁用（etaf-org-allow-local-read 为 nil）"))
     ((>= (or depth 0) 3)
      (list :error "transclude 嵌套深度超过上限（3 层），已中止以防环引用"))
     ((or (null target) (string-blank-p target))
      (list :error "transclude 缺少 :target 属性"))
     (t
      (let* ((raw (if (string-prefix-p "file:" target) (substring target 5) target))
             (parts (split-string raw "::"))
             (file-part (car parts))
             (search (cadr parts))
             (path (etaf-org-assets--safe-path session file-part)))
        (cond
         ((null path) (list :error (format "路径超出工作区范围：%s" target)))
         ((not (file-readable-p path)) (list :error (format "找不到嵌入文件：%s" target)))
         (t
          (let* ((text (with-temp-buffer
                         (insert-file-contents path nil 0 etaf-org-assets--max-file-bytes)
                         (buffer-string)))
                 (doc (etaf-org-derive
                       (etaf-org--parse text :file path :flavor 'standard)
                       (plist-get session :today)))
                 (sec (when (and search (not (string-empty-p search)))
                        (etaf-org-assets--find-section-in-doc doc search))))
            (cond
             ((and search (not (string-empty-p search)) (null sec))
              (list :error (format "在 %s 中找不到目标节：%s" file-part search)))
             (sec
              (list :ok t :path path :target target
                    :title (etaf-org-section-title-plain sec)
                    :only-contents (and only-contents
                                        (not (member (format "%s" only-contents) '("nil" "false"))))
                    :blocks (etaf-org-section-body sec)
                    :section sec))
             (t
              (list :ok t :path path :target target
                    :title (or (plist-get doc :title) (file-name-nondirectory path))
                    :only-contents t
                    :blocks (plist-get doc :preamble)
                    :sections (plist-get doc :sections))))))))))))

;;; ---------------------------------------------------------------------------
;;; Async L1 jobs: git-log, git-diff, backlinks
;;; ---------------------------------------------------------------------------

(defun etaf-org-assets--async-key (kind attrs)
  "Return cache key for async asset KIND + ATTRS."
  (format "%s:%s" kind (secure-hash 'sha1 (prin1-to-string attrs))))

(defun etaf-org-assets--store-async (session key value)
  "Store async asset VALUE under KEY in SESSION and trigger repaint."
  (let ((table (or (plist-get session :assets)
                   (let ((ht (make-hash-table :test #'equal)))
                     (plist-put session :assets ht)
                     ht))))
    (puthash key value table)
    (when (and (buffer-live-p (plist-get session :buffer))
               (fboundp 'etaf-org--refresh-block-assets))
      (etaf-org--refresh-block-assets session))))

(defun etaf-org-assets--request-git-log (session key attrs)
  "Run `git log' or Jujutsu log asynchronously inside workspace root."
  (let* ((root (etaf-org-assets--workspace-root session))
         (rel (plist-get attrs :path))
         (target (if rel (etaf-org-assets--safe-path session rel) root))
         (limit (let ((r (plist-get attrs :limit)))
                  (cond ((integerp r) (min 30 (max 1 r)))
                        ((and (stringp r) (string-match-p "\\`[0-9]+\\'" r))
                         (min 30 (max 1 (string-to-number r))))
                        (t 8))))
         (git (executable-find "git"))
         (has-git (locate-dominating-file root ".git"))
         (has-jj (and (not has-git) (locate-dominating-file root ".jj")))
         (jj (and has-jj (or (executable-find "jjosh") (executable-find "jj")))))
    (cond
     ((and rel (null target))
      (etaf-org-assets--store-async session key (list :error (format "路径超出工作区：%s" rel))))
     ((and (null jj) (null git))
      (etaf-org-assets--store-async session key '(:error "未找到 git 或 jj 程序")))
     (t
      (let* ((default-directory root)
             (cmd (if jj
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
         cmd :name "etaf-org-git-log" :timeout 10
         :callback
         (lambda (res)
           (if (and (eq (plist-get res :status) 'exit) (eql (plist-get res :exit) 0))
               (let ((rows
                      (delq nil
                            (mapcar
                             (lambda (line)
                               (let ((cols (split-string line "\x1f")))
                                 (when (>= (length cols) 4)
                                   (list :hash (nth 0 cols)
                                         :date (nth 1 cols)
                                         :author (nth 2 cols)
                                         :subject (if (string-blank-p (nth 3 cols))
                                                      "(working copy)"
                                                    (nth 3 cols))))))
                             (split-string (or (plist-get res :output) "") "\n" t)))))
                 (etaf-org-assets--store-async session key (list :ok t :commits rows)))
             (etaf-org-assets--store-async
              session key '(:error "当前目录不是 Git/Jujutsu 仓库或无提交历史"))))))))))

(defun etaf-org-assets--request-git-diff (session key attrs)
  "Run `git diff' or Jujutsu diff asynchronously inside workspace root."
  (let* ((root (etaf-org-assets--workspace-root session))
         (rev (plist-get attrs :rev))
         (rel (or (plist-get attrs :file) (plist-get attrs :path)))
         (target (when rel (etaf-org-assets--safe-path session rel)))
         (git (executable-find "git"))
         (has-git (locate-dominating-file root ".git"))
         (has-jj (and (not has-git) (locate-dominating-file root ".jj")))
         (jj (and has-jj (or (executable-find "jjosh") (executable-find "jj")))))
    (cond
     ((and rel (null target))
      (etaf-org-assets--store-async session key (list :error (format "路径超出工作区：%s" rel))))
     ((and (null jj) (null git))
      (etaf-org-assets--store-async session key '(:error "未找到 git 或 jj 程序")))
     (t
      (let* ((default-directory root)
             (cmd (if jj
                      (append
                       (list jj "--repository" (expand-file-name has-jj) "diff" "--git" "--color=never")
                       (when (and (stringp rev) (not (string-blank-p rev))) (list "-r" rev))
                       (when target (list (file-relative-name target (expand-file-name has-jj)))))
                    (append
                     (list git "-C" root "diff" "--no-color")
                     (when (and (stringp rev) (not (string-blank-p rev))) (list rev))
                     (when target (list "--" (file-relative-name target root)))))))
        (etaf-process-run
         cmd :name "etaf-org-git-diff" :timeout 10
         :callback
         (lambda (res)
           (if (and (eq (plist-get res :status) 'exit) (eql (plist-get res :exit) 0))
               (let* ((out (or (plist-get res :output) ""))
                      (lines (split-string out "\n"))
                      (trimmed (cl-subseq lines 0 (min 120 (length lines)))))
                 (etaf-org-assets--store-async
                  session key (list :ok t :content (string-join trimmed "\n")
                                    :truncated (> (length lines) 120))))
             (etaf-org-assets--store-async
              session key '(:error "无法获取工作区 diff（请确认处于 Git 或 Jujutsu 仓库中）"))))))))))

(defun etaf-org-assets--request-backlinks (session key attrs)
  "Scan workspace `.org' files asynchronously for incoming links to SESSION."
  (let* ((root (etaf-org-assets--workspace-root session))
         (self (plist-get session :file))
         (base (and self (file-name-nondirectory self)))
         (doc (etaf-org--read session :document))
         (ids nil))
    (when doc
      (cl-labels ((collect (secs)
                    (dolist (s secs)
                      (when-let* ((id (cdr (assoc "ID" (etaf-org-section-properties s)))))
                        (push id ids))
                      (collect (etaf-org-section-children s)))))
        (collect (plist-get doc :sections))))
    (let* ((needles (delq nil (append (when base (list base)) ids)))
           (limit (let ((r (plist-get attrs :limit)))
                    (if (and (stringp r) (string-match-p "\\`[0-9]+\\'" r))
                        (string-to-number r)
                      20))))
      (cond
       ((null needles)
        (etaf-org-assets--store-async session key '(:ok t :links nil)))
       ((executable-find "rg")
        (let ((pattern (mapconcat #'regexp-quote needles "|"))
              (default-directory root))
          (etaf-process-run
           (list "rg" "-n" "-H" "--glob" "*.org" "-m" "5" pattern ".")
           :name "etaf-org-backlinks" :timeout 10
           :callback
           (lambda (res)
             (let ((hits nil)
                   (self-true (and self (ignore-errors (file-truename self)))))
               (dolist (line (split-string (or (plist-get res :output) "") "\n" t))
                 (when (string-match "\\`\\([^:]+\\):\\([0-9]+\\):\\(.*\\)\\'" line)
                   (let* ((raw-rel (match-string 1 line))
                          (raw-lno (match-string 2 line))
                          (raw-ctx (match-string 3 line))
                          (rel (string-trim-left raw-rel "\\./"))
                          (lno (string-to-number raw-lno))
                          (ctx (string-trim raw-ctx))
                          (full (expand-file-name rel root)))
                     (unless (and self-true (equal (ignore-errors (file-truename full)) self-true))
                       (push (list :file full :rel rel :line lno :context ctx) hits)))))
               (etaf-org-assets--store-async
                session key (list :ok t :links (cl-subseq (nreverse hits)
                                                          0 (min limit (length hits))))))))))
       (t
        ;; Pure-Elisp fallback when ripgrep is not installed.
        (let ((hits nil)
              (self-true (and self (ignore-errors (file-truename self))))
              (re (regexp-opt needles)))
          (dolist (file (etaf-org-assets--collect-org-files root 80))
            (unless (and self-true (equal (ignore-errors (file-truename file)) self-true))
              (with-temp-buffer
                (insert-file-contents file nil 0 etaf-org-assets--max-file-bytes)
                (goto-char (point-min))
                (let ((count 0))
                  (while (and (< count 3) (re-search-forward re nil t))
                    (cl-incf count)
                    (push (list :file file
                                :rel (file-relative-name file root)
                                :line (line-number-at-pos)
                                :context (string-trim
                                          (buffer-substring-no-properties
                                           (line-beginning-position)
                                           (line-end-position))))
                          hits))))))
          (etaf-org-assets--store-async
           session key (list :ok t :links (cl-subseq (nreverse hits)
                                                     0 (min limit (length hits)))))))))))

;;; ---------------------------------------------------------------------------
;;; Publish-time attachment & async trigger
;;; ---------------------------------------------------------------------------

(defun etaf-org-assets-attach-block (session document block &optional section)
  "Attach publish-time L1 `:asset-data' snapshot to BLOCK (zero I/O in `:render')."
  (let ((type (plist-get block :type)))
    (cond
     ((eq type 'include-card)
      (plist-put (copy-sequence block) :asset-data
                 (etaf-org-assets--compute-org-include session block)))
     ((memq type '(special-block dynamic-block))
      (let* ((name (downcase (or (plist-get block :name) "")))
             (attrs (plist-get block :attrs))
             (assets-ht (plist-get session :assets))
             (async-key (when (member name '("git-log" "git-diff" "backlinks"))
                          (etaf-org-assets--async-key name attrs)))
             (data
              (pcase name
                ("include" (etaf-org-assets--compute-include session attrs))
                ("code-ref" (etaf-org-assets--compute-code-ref session attrs))
                ("symbol" (etaf-org-assets-compute-symbol attrs session))
                ("project-tree" (etaf-org-assets--compute-project-tree session attrs))
                ((or "org-query" "kanban")
                 (etaf-org-assets--compute-org-query session document attrs section))
                ("clock-summary"
                 (etaf-org-assets--compute-clock-summary document attrs section))
                ("transclude"
                 (etaf-org-assets--compute-transclude session attrs 0))
                ((or "git-log" "git-diff" "backlinks")
                 (if (not etaf-org-allow-local-read)
                     '(:error "本地文件读取已禁用（etaf-org-allow-local-read 为 nil）")
                   (or (and (hash-table-p assets-ht) (gethash async-key assets-ht))
                       '(:loading t))))
                (_ nil))))
        (if data
            (plist-put (copy-sequence block) :asset-data data)
          block)))
     (t block))))

(defun etaf-org-assets-request (session)
  "Start async L1 jobs (`git-log', `git-diff', `backlinks').
Runs only when `etaf-org-allow-local-read' is non-nil and SESSION is mounted."
  (when (and etaf-org-allow-local-read
             (buffer-live-p (plist-get session :buffer))
             (fboundp 'etaf-org--walk-document-blocks))
    (let ((assets-ht (or (plist-get session :assets)
                         (let ((ht (make-hash-table :test #'equal)))
                           (plist-put session :assets ht) ht)))
          (pending (or (plist-get session :assets-running)
                       (let ((ht (make-hash-table :test #'equal)))
                         (plist-put session :assets-running ht) ht))))
      (etaf-org--walk-document-blocks
       (etaf-org--read session :document)
       (lambda (block)
         (when (memq (plist-get block :type) '(special-block dynamic-block))
           (let* ((name (downcase (or (plist-get block :name) "")))
                  (attrs (plist-get block :attrs))
                  (key (and (member name '("git-log" "git-diff" "backlinks"))
                            (etaf-org-assets--async-key name attrs))))
             (when (and key (not (gethash key assets-ht)) (not (gethash key pending)))
               (puthash key t pending)
               (pcase name
                 ("git-log" (etaf-org-assets--request-git-log session key attrs))
                 ("git-diff" (etaf-org-assets--request-git-diff session key attrs))
                 ("backlinks" (etaf-org-assets--request-backlinks session key attrs)))))))))))

;;; ---------------------------------------------------------------------------
;;; L2 Explicit Controlled Actions
;;; ---------------------------------------------------------------------------

(defun etaf-org-assets--confirm-action (description)
  "Check `etaf-org-allow-actions' gate for DESCRIPTION."
  (pcase etaf-org-allow-actions
    ('t t)
    ('ask (yes-or-no-p (format "etaf-org 执行确认：%s？ " description)))
    (_ (message "可执行动作已禁用（etaf-org-allow-actions 为 nil）") nil)))

(defun etaf-org-assets-run-command (env command)
  "Execute shell COMMAND for a `run' widget with explicit trust confirmation."
  (when (and (stringp command) (not (string-blank-p command))
             (etaf-org-assets--confirm-action
              (format "运行命令 `%s'" (truncate-string-to-width (string-trim command) 60))))
    (let* ((session (etaf-org-env-session env))
           (default-directory (etaf-org-assets--workspace-root session)))
      (etaf-org-set-block-state env :status 'running)
      (etaf-org-set-block-state env :output "正在执行...")
      (etaf-process-run
       (list shell-file-name shell-command-switch command)
       :name "etaf-org-run" :timeout 30
       :callback
       (lambda (res)
         (etaf-org-set-block-state
          env :status (if (eql (plist-get res :exit) 0) 'ok 'error))
         (etaf-org-set-block-state
          env :output (string-trim-right (or (plist-get res :output) ""))))))))

(defun etaf-org-assets--update-parent-cookies ()
  "Recompute `[n/m]' and `[p%]' cookies on the enclosing heading of current line."
  (save-excursion
    (when (re-search-backward "^\\(\\*+\\)[ \t]+.*\\[\\([0-9]*/[0-9]*\\|[0-9]+%\\)\\]" nil t)
      (let* ((h-start (line-beginning-position))
             (h-end (save-excursion
                      (forward-line 1)
                      (if (re-search-forward "^\\*+[ \t]" nil t)
                          (line-beginning-position)
                        (point-max))))
             (total 0) (done 0))
        (save-excursion
          (goto-char h-start)
          (forward-line 1)
          (while (re-search-forward "^[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+\\[\\([ xX-]\\)\\]" h-end t)
            (cl-incf total)
            (when (member (match-string 1) '("x" "X"))
              (cl-incf done))))
        (when (> total 0)
          (goto-char h-start)
          (when (re-search-forward "\\[\\([0-9]*/[0-9]*\\|[0-9]+%\\)\\]" (line-end-position) t)
            (let ((is-pct (string-suffix-p "%" (match-string 1))))
              (replace-match
               (if is-pct
                   (format "[%d%%]" (round (* 100.0 (/ (float done) total))))
                 (format "[%d/%d]" done total))
               t t))))))))

(defun etaf-org-assets-toggle-checkbox (session source-line)
  "Toggle Org checkbox on 1-based SOURCE-LINE in SESSION's source buffer/file."
  (when (and etaf-org-interactive-checkbox (integerp source-line) (> source-line 0))
    (let* ((src-buf (plist-get session :source-buffer))
           (file (plist-get session :file))
           (apply-fn
            (lambda ()
              (save-excursion
                (goto-char (point-min))
                (forward-line (1- source-line))
                (when (re-search-forward "\\[\\([ xX-]\\)\\]" (line-end-position) t)
                  (let ((cur (match-string 1)))
                    (replace-match (if (member cur '("x" "X")) "[ ]" "[X]") t t)
                    (etaf-org-assets--update-parent-cookies)
                    t))))))
      (cond
       ((buffer-live-p src-buf)
        (with-current-buffer src-buf
          (when (funcall apply-fn)
            (etaf-org-refresh session)
            t)))
       ((and file (file-writable-p file))
        (let ((changed nil))
          (with-temp-buffer
            (insert-file-contents file)
            (when (funcall apply-fn)
              (setq changed t)
              (write-region (point-min) (point-max) file nil 'silent)))
          (when changed
            (etaf-org-refresh session)
            t)))
       ((stringp (plist-get session :text))
        (let ((updated nil))
          (with-temp-buffer
            (insert (plist-get session :text))
            (when (funcall apply-fn)
              (setq updated (buffer-string))))
          (when updated
            (plist-put session :text updated)
            (etaf-org-refresh session)
            t)))))))

(defun etaf-org-assets-cycle-todo (session source-line current-todo)
  "Cycle TODO keyword on 1-based SOURCE-LINE in SESSION when opt-in enabled."
  (when (and etaf-org-interactive-todo (integerp source-line) (> source-line 0))
    (let* ((keywords (mapcar #'car (or (plist-get session :todo-keywords)
                                       etaf-org--default-todo-keywords)))
           (tail (cdr (member current-todo keywords)))
           (next (or (car tail) (car keywords)))
           (src-buf (plist-get session :source-buffer))
           (file (plist-get session :file))
           (apply-fn
            (lambda ()
              (save-excursion
                (goto-char (point-min))
                (forward-line (1- source-line))
                (when (looking-at (format "^\\(\\*+[ \t]+\\)%s\\([ \t]+\\)"
                                          (regexp-quote current-todo)))
                  (replace-match (format "\\1%s\\2" next) t)
                  t)))))
      (cond
       ((buffer-live-p src-buf)
        (with-current-buffer src-buf
          (when (funcall apply-fn) (etaf-org-refresh session) next)))
       ((and file (file-writable-p file))
        (let ((changed nil))
          (with-temp-buffer
            (insert-file-contents file)
            (when (funcall apply-fn)
              (setq changed t)
              (write-region (point-min) (point-max) file nil 'silent)))
          (when changed (etaf-org-refresh session) next)))
       ((stringp (plist-get session :text))
        (let ((updated nil))
          (with-temp-buffer
            (insert (plist-get session :text))
            (when (funcall apply-fn) (setq updated (buffer-string))))
          (when updated
            (plist-put session :text updated)
            (etaf-org-refresh session)
            next)))))))

(defun etaf-org-assets-execute-babel (session source-line)
  "Execute Org Babel block at SOURCE-LINE in SESSION when allowed.
Honors `etaf-org-allow-babel' (`nil', `ask' or `t')."
  (when (and etaf-org-allow-babel (integerp source-line))
    (let ((ok (or (eq etaf-org-allow-babel t)
                  (and (eq etaf-org-allow-babel 'ask)
                       (yes-or-no-p
                        (format "确认执行第 %d 行的 Org Babel 代码块？ " source-line))))))
      (when ok
        (let ((buf (or (and (buffer-live-p (plist-get session :source-buffer))
                            (plist-get session :source-buffer))
                       (and (plist-get session :file)
                            (find-file-noselect (plist-get session :file))))))
          (if (not (buffer-live-p buf))
              (message "需要关联的 Org 文件或 buffer 才能执行 Babel")
            (require 'ob-core nil t)
            (if (not (fboundp 'org-babel-execute-src-block))
                (message "当前 Emacs 未加载 Org Babel (ob-core)")
              (with-current-buffer buf
                (save-excursion
                  (goto-char (point-min))
                  (forward-line (1- source-line))
                  (let ((org-confirm-babel-evaluate nil))
                    (org-babel-execute-src-block))))
              (etaf-org-refresh session)
              (message "已执行第 %d 行代码块并刷新结果" source-line))))))))

(provide 'etaf-org-assets)
;;; etaf-org-assets.el ends here
