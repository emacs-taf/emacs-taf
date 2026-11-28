;;; etaf-web-lang.el --- 4-layer code block language identification -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Four-layer confidence funnel for identifying fenced code block languages
;; when compiling HTML `<pre>'/`<code>' blocks into Markdown:
;;
;; 1. Ancestor DOM + multi-framework metadata (data-language, lang, class
;;    prefixes on `<code>', `<pre>' and 1..3 enclosing wrappers, bare known
;;    language classes, sibling language badges and filename headers).
;; 2. Canonical language normalization aligned with `etaf-doc-highlight'.
;; 3. High-precision deterministic content anchors (shebang, JSON parse,
;;    unified diff, HTTP wire message, Python REPL, Dockerfile, Makefile,
;;    Emacs Lisp / Lisp S-exprs, HTML/XML, SQL, Shell command sessions, TOML).
;; 4. Margin-gated weighted feature scorer with an optional weak page-level
;;    prior that only breaks ties when a snippet carries genuine syntax cues;
;;    falls back honestly to "text" rather than guessing on prose or output.

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'subr-x)

;;; ---------------------------------------------------------------------------
;;; Canonical language tables & alias normalization (Layer 2)
;;; ---------------------------------------------------------------------------

(defconst etaf-web-lang--plain-tokens
  '("text" "plain" "plaintext" "none" "txt" "raw" "nohighlight" "no-highlight"
    "ascii" "art-ascii-art" "art-text" "output" "ansi")
  "Explicit plain-text markers that lock a code block to \"text\".")

(defconst etaf-web-lang--human-lang-codes
  '("en" "zh" "ja" "ko" "fr" "de" "es" "pt" "it" "ru" "ar" "hi" "nl" "sv"
    "pl" "tr" "vi" "th" "id" "uk" "cs" "da" "fi" "no" "nb" "nn" "el" "he"
    "ro" "hu" "bg" "sk" "sl" "hr" "sr" "ca" "eu" "gl" "fa" "ur" "bn" "ta")
  "ISO 639-1 human language prefixes ignored on HTML `lang' attributes.")

(defconst etaf-web-lang--aliases
  '(("python3" . "python") ("py3" . "python") ("py" . "python")
    ("pycon" . "python") ("ipython" . "python") ("ipy" . "python")
    ("shell-session" . "sh") ("shellsession" . "sh")
    ("sh-session" . "sh") ("bash-session" . "sh")
    ("shell-script" . "sh") ("shellscript" . "sh") ("terminal" . "sh")
    ("source-shell" . "sh") ("source-bash" . "bash")
    ("rs" . "rust") ("source-rust" . "rust")
    ("golang" . "go") ("source-go" . "go")
    ("mjs" . "js") ("cjs" . "js") ("ecmascript" . "js") ("source-js" . "js")
    ("source-ts" . "ts") ("source-tsx" . "tsx") ("source-jsx" . "jsx")
    ("c++" . "cpp") ("cxx" . "cpp") ("cc" . "cpp") ("hpp" . "cpp")
    ("c#" . "csharp") ("cs" . "csharp")
    ("objective-c" . "objc") ("objectivec" . "objc") ("obj-c" . "objc")
    ("text-html-basic" . "html") ("html+django" . "html")
    ("html+jinja" . "html") ("html+handlebars" . "html") ("xhtml" . "html")
    ("template" . "html")
    ("text-xml" . "xml")
    ("yml" . "yaml")
    ("docker" . "dockerfile")
    ("gnumake" . "makefile") ("mk" . "makefile")
    ("ps1" . "powershell") ("pwsh" . "powershell")
    ("dos" . "bat") ("cmd" . "bat") ("batch" . "bat")
    ("el" . "elisp") ("emacs-lisp" . "elisp")
    ("common-lisp" . "lisp") ("commonlisp" . "lisp") ("clisp" . "lisp")
    ("rb" . "ruby") ("kt" . "kotlin") ("hs" . "haskell")
    ("ml" . "ocaml") ("ex" . "elixir") ("erl" . "erlang")
    ("clj" . "clojure") ("cljs" . "clojure") ("scm" . "scheme")
    ("proto" . "protobuf") ("gql" . "graphql") ("tf" . "hcl")
    ("terraform" . "hcl") ("md" . "markdown") ("gfm" . "markdown")
    ("tex" . "latex") ("patch" . "diff") ("cfg" . "ini") ("dosini" . "ini")
    ("properties" . "ini") ("dotenv" . "conf") ("env" . "conf")
    ("postgresql" . "sql") ("postgres" . "sql") ("mysql" . "sql")
    ("sqlite" . "sql") ("plsql" . "sql") ("tsql" . "sql")
    ("plain" . "text") ("plaintext" . "text") ("none" . "text")
    ("txt" . "text") ("nohighlight" . "text") ("raw" . "text")
    ("text-plain" . "text"))
  "Normalization map from framework/lexer aliases to canonical fence names.")

(defconst etaf-web-lang--known-langs
  '("elisp" "emacs-lisp" "lisp" "scheme" "clojure"
    "python" "python3" "py" "pycon"
    "javascript" "js" "jsx" "mjs" "cjs"
    "typescript" "ts" "tsx"
    "json" "jsonc" "json5"
    "c" "cpp" "c++" "objc" "java" "csharp" "cs"
    "rust" "rs" "go" "golang" "ruby" "rb" "php" "perl" "lua"
    "sh" "bash" "zsh" "shell" "console" "shell-session" "fish" "powershell"
    "ps1" "bat" "batch" "dos"
    "sql" "yaml" "yml" "toml" "ini" "conf" "nginx" "hcl" "terraform"
    "xml" "html" "svg" "css" "scss" "less" "sass"
    "markdown" "md" "org" "diff" "patch" "make" "makefile"
    "dockerfile" "docker" "cmake" "latex" "tex"
    "haskell" "hs" "kotlin" "kt" "swift" "scala" "erlang" "elixir"
    "ocaml" "vim" "zig" "nix" "dart" "groovy" "svelte" "vue"
    "graphql" "gql" "protobuf" "proto" "http" "http-message"
    "abnf" "bnf" "ebnf" "awk" "asm" "wasm" "wat" "glsl" "wgsl" "solidity")
  "Whitelist of known programming/markup/config languages for bare class matching.")

(defconst etaf-web-lang--filename-exact
  '(("dockerfile" . "dockerfile")
    ("makefile" . "makefile") ("gnumakefile" . "makefile")
    ("cmakelists.txt" . "cmake")
    ("cargo.toml" . "toml") ("pyproject.toml" . "toml")
    ("go.mod" . "go") ("go.sum" . "text")
    ("package.json" . "json") ("tsconfig.json" . "jsonc")
    (".bashrc" . "bash") (".zshrc" . "zsh") (".profile" . "sh")
    (".gitignore" . "conf") (".editorconfig" . "ini")
    ("nginx.conf" . "nginx"))
  "Exact lowercased filenames mapped to canonical languages.")

(defconst etaf-web-lang--extension-map
  '(("el" . "elisp") ("lisp" . "lisp") ("cl" . "lisp") ("scm" . "scheme")
    ("clj" . "clojure") ("cljs" . "clojure")
    ("py" . "python") ("pyi" . "python")
    ("js" . "js") ("mjs" . "js") ("cjs" . "js") ("jsx" . "jsx")
    ("ts" . "ts") ("mts" . "ts") ("cts" . "ts") ("tsx" . "tsx")
    ("json" . "json") ("jsonc" . "jsonc")
    ("c" . "c") ("h" . "c") ("cpp" . "cpp") ("cc" . "cpp")
    ("cxx" . "cpp") ("hpp" . "cpp") ("hh" . "cpp")
    ("m" . "objc") ("mm" . "objc") ("java" . "java") ("cs" . "csharp")
    ("rs" . "rust") ("go" . "go") ("rb" . "ruby") ("php" . "php")
    ("pl" . "perl") ("pm" . "perl") ("lua" . "lua")
    ("sh" . "sh") ("bash" . "bash") ("zsh" . "zsh") ("fish" . "fish")
    ("ps1" . "powershell") ("bat" . "bat") ("cmd" . "bat")
    ("sql" . "sql") ("yaml" . "yaml") ("yml" . "yaml")
    ("toml" . "toml") ("ini" . "ini") ("cfg" . "ini") ("conf" . "conf")
    ("xml" . "xml") ("svg" . "xml") ("html" . "html") ("htm" . "html")
    ("css" . "css") ("scss" . "scss") ("less" . "less")
    ("md" . "markdown") ("markdown" . "markdown") ("org" . "org")
    ("diff" . "diff") ("patch" . "diff") ("mk" . "makefile")
    ("cmake" . "cmake") ("tex" . "latex")
    ("hs" . "haskell") ("kt" . "kotlin") ("kts" . "kotlin")
    ("swift" . "swift") ("scala" . "scala") ("erl" . "erlang")
    ("ex" . "elixir") ("exs" . "elixir") ("ml" . "ocaml") ("mli" . "ocaml")
    ("vim" . "vim") ("zig" . "zig") ("nix" . "nix") ("dart" . "dart")
    ("groovy" . "groovy") ("svelte" . "svelte") ("vue" . "vue")
    ("graphql" . "graphql") ("gql" . "graphql") ("proto" . "protobuf")
    ("tf" . "hcl") ("hcl" . "hcl") ("awk" . "awk") ("asm" . "asm")
    ("glsl" . "glsl") ("wgsl" . "wgsl") ("sol" . "solidity"))
  "Lowercased file extensions mapped to canonical languages.")

(defconst etaf-web-lang--wrapper-hint-classes
  '("hljs" "sourcecode" "highlight" "prism" "shiki" "code-block"
    "codeblock" "syntaxhighlighter" "mw-highlight" "chroma" "rouge")
  "Classes indicating a wrapper element is a syntax-highlighted code box.")

(defun etaf-web-lang--node-p (node)
  "Return non-nil when NODE is a DOM element cons cell."
  (and (consp node) (symbolp (car node))))

(defun etaf-web-lang--attr (node attr)
  "Return string attribute ATTR from DOM NODE, or nil."
  (when (etaf-web-lang--node-p node)
    (let ((val (dom-attr node attr)))
      (when (stringp val) val))))

(defun etaf-web-lang--class-list (node)
  "Return lowercased CSS class tokens of DOM NODE."
  (let ((cls (etaf-web-lang--attr node 'class)))
    (when (and cls (not (string-blank-p cls)))
      (split-string (downcase cls) "[ \t\n\r]+" t))))

(defun etaf-web-lang--clean-text (node)
  "Return collapsed plain text of DOM NODE."
  (string-trim
   (replace-regexp-in-string
    "[ \t\n\r]+" " "
    (cond
     ((stringp node) node)
     ((not (etaf-web-lang--node-p node)) "")
     (t (mapconcat #'etaf-web-lang--clean-text (dom-children node) " "))))))

(defun etaf-web-lang--normalize (raw)
  "Normalize RAW language identifier to a canonical tag, or nil if invalid."
  (when (stringp raw)
    (let* ((s (downcase (string-trim raw)))
           ;; Drop trailing line-highlight metadata (`ts {1,3}', `js;').
           (s (if (string-match "\\`\\([a-z0-9_+#.-]+\\)" s)
                  (match-string 1 s)
                ""))
           (s (replace-regexp-in-string "[.;:,]+\\'" "" s)))
      (when (and (not (string-empty-p s))
                 (<= (length s) 28))
        (cond
         ;; Strip `source-' / `text-' prefix from GitHub/TextMate scopes.
         ((string-prefix-p "source-" s)
          (let ((rest (substring s 7)))
            (or (cdr (assoc s etaf-web-lang--aliases))
                (cdr (assoc rest etaf-web-lang--aliases))
                rest)))
         ((string-prefix-p "text-" s)
          (or (cdr (assoc s etaf-web-lang--aliases))
              (let ((rest (substring s 5)))
                (when (member rest etaf-web-lang--known-langs)
                  (or (cdr (assoc rest etaf-web-lang--aliases)) rest)))))
         (t
          (or (cdr (assoc s etaf-web-lang--aliases)) s)))))))

(defun etaf-web-lang--from-filename (name)
  "Infer canonical language from filename or title string NAME, or nil."
  (when (and (stringp name) (not (string-blank-p name)) (<= (length name) 120))
    (let* ((trimmed (string-trim name))
           ;; Take last whitespace-delimited path token if there is a short label.
           (base (downcase (file-name-nondirectory
                            (replace-regexp-in-string "[ \t]+\\'" "" trimmed)))))
      (or (cdr (assoc base etaf-web-lang--filename-exact))
          (when (string-match "\\.[a-z0-9]+\\'" base)
            (let ((ext (substring base (1+ (match-beginning 0)))))
              (cdr (assoc ext etaf-web-lang--extension-map))))))))

(defun etaf-web-lang--human-lang-p (val)
  "Return non-nil when VAL looks like a BCP-47 human language tag (e.g. en-US)."
  (let ((low (downcase (string-trim (or val "")))))
    (or (member low etaf-web-lang--human-lang-codes)
        (and (string-match "\\`\\([a-z]\\{2\\}\\)-[a-z0-9-]+\\'" low)
             (member (match-string 1 low) etaf-web-lang--human-lang-codes)))))

(defun etaf-web-lang--build-parent-map (root)
  "Return `eq' hash-table mapping every DOM element under ROOT to its parent."
  (let ((map (make-hash-table :test #'eq)))
    (cl-labels
        ((walk (node)
           (when (etaf-web-lang--node-p node)
             (dolist (child (dom-children node))
               (when (etaf-web-lang--node-p child)
                 (puthash child node map)
                 (walk child))))))
      (walk root))
    map))

(defun etaf-web-lang--ancestors (node parent-map max-depth)
  "Return up to MAX-DEPTH enclosing wrapper elements above NODE via PARENT-MAP."
  (when parent-map
    (let ((cur (gethash node parent-map))
          (out nil)
          (depth 0))
      (while (and cur (< depth max-depth)
                  (not (memq (dom-tag cur) '(body html main article))))
        (push cur out)
        (setq cur (gethash cur parent-map)
              depth (1+ depth)))
      (nreverse out))))

;;; ---------------------------------------------------------------------------
;;; Layer 1: DOM & multi-framework metadata extraction
;;; ---------------------------------------------------------------------------

(defun etaf-web-lang--explicit-plain-node-p (node)
  "Return non-nil when DOM NODE explicitly marks plain text / ASCII art."
  (when (etaf-web-lang--node-p node)
    (let* ((dl (downcase (string-trim
                          (or (etaf-web-lang--attr node 'data-lang)
                              (etaf-web-lang--attr node 'data-language)
                              (etaf-web-lang--attr node 'data-code-lang)
                              ""))))
           (classes (etaf-web-lang--class-list node)))
      (or (member dl etaf-web-lang--plain-tokens)
          (cl-some
           (lambda (c)
             (or (member c etaf-web-lang--plain-tokens)
                 (and (string-match
                       "\\`\\(?:language-\\|lang-\\|highlight-\\|mw-highlight-lang-\\)\\([a-z0-9_-]+\\)\\'"
                       c)
                      (member (match-string 1 c) etaf-web-lang--plain-tokens))))
           classes)))))

(defun etaf-web-lang--extract-from-node (node is-code-or-pre)
  "Extract normalized language from DOM NODE's attributes/classes, or nil.
When IS-CODE-OR-PRE is non-nil, also checks HTML `lang' and bare known
language class names (such as Rustdoc's `<pre class=\"rust item-decl\">')."
  (when (etaf-web-lang--node-p node)
    (let ((found nil))
      ;; 1. Dedicated data-* language attributes.
      (dolist (attr '(data-lang data-language data-code-lang data-prism-lang
                                data-highlight data-syntax data-brush))
        (unless found
          (let ((v (etaf-web-lang--attr node attr)))
            (when (and v (not (string-blank-p v)))
              (let ((norm (etaf-web-lang--normalize v)))
                (when (and norm (not (equal norm "text")))
                  (setq found norm)))))))
      ;; 2. HTML `lang' attribute on `<pre>'/`<code>' (e.g. PyPI `<pre lang="python">').
      (when (and (not found) is-code-or-pre)
        (let ((v (etaf-web-lang--attr node 'lang)))
          (when (and v (not (string-blank-p v)) (not (etaf-web-lang--human-lang-p v)))
            (let ((norm (etaf-web-lang--normalize v)))
              (when (and norm (not (equal norm "text"))
                         (or (member (downcase (string-trim v)) etaf-web-lang--known-langs)
                             (member norm etaf-web-lang--known-langs)))
                (setq found norm))))))
      ;; 3. Class-list prefix patterns & bare language classes.
      (unless found
        (let* ((classes (etaf-web-lang--class-list node))
               (has-hl-marker (or is-code-or-pre
                                  (cl-some (lambda (c)
                                             (member c etaf-web-lang--wrapper-hint-classes))
                                           classes)))
               (rest classes))
          (while (and rest (not found))
            (let ((cls (pop rest)))
              (cond
               ;; `brush: js' split across two whitespace class tokens.
               ((and (equal cls "brush:") rest)
                (let ((norm (etaf-web-lang--normalize (car rest))))
                  (when (and norm (not (equal norm "text")))
                    (setq found norm))))
               ((string-match
                 "\\`\\(?:language-\\|lang-\\|mw-highlight-lang-\\|highlight-source-\\|highlight-text-\\|brush:\\|syntax-\\|code-lang-\\)\\([a-z0-9_+#.-]+\\)\\'"
                 cls)
                (let* ((raw (match-string 1 cls))
                       (norm (etaf-web-lang--normalize
                              (if (string-prefix-p "highlight-text-" cls)
                                  (concat "text-" raw)
                                raw))))
                  (when (and norm (not (equal norm "text")))
                    (setq found norm))))
               ;; Sphinx / Pygments `highlight-python3', `highlight-bash' (skip UI words).
               ((string-match "\\`highlight-\\([a-z0-9_+#.-]+\\)\\'" cls)
                (let* ((raw (match-string 1 cls))
                       (norm (etaf-web-lang--normalize raw)))
                  (when (and norm (not (equal norm "text"))
                             (or (member raw etaf-web-lang--known-langs)
                                 (member norm etaf-web-lang--known-langs)))
                    (setq found norm))))
               ;; Bare known language class on `<pre>'/`<code>' or highlighted wrapper.
               ((and has-hl-marker
                     (member cls etaf-web-lang--known-langs))
                (let ((norm (etaf-web-lang--normalize cls)))
                  (when (and norm (not (equal norm "text")))
                    (setq found norm)))))))))
      ;; 4. Filename attributes (`data-filename', `data-file', `data-title', `title').
      (unless found
        (dolist (attr '(data-filename data-file data-title title))
          (unless found
            (let ((v (etaf-web-lang--attr node attr)))
              (when v
                (let ((by-file (etaf-web-lang--from-filename v)))
                  (when (and by-file (not (equal by-file "text")))
                    (setq found by-file))))))))
      found)))

(defun etaf-web-lang--extract-from-wrapper-siblings (wrapper pre-node)
  "Inspect sibling language badges or captions inside WRAPPER for PRE-NODE."
  (when (etaf-web-lang--node-p wrapper)
    (let ((found nil))
      (dolist (child (dom-children wrapper))
        (when (and (not found)
                   (etaf-web-lang--node-p child)
                   (not (eq child pre-node))
                   (not (eq (dom-tag child) 'pre)))
          (let* ((tag (dom-tag child))
                 (classes (etaf-web-lang--class-list child))
                 (lang-badge
                  (and (memq tag '(span div figcaption p header))
                       (or (eq tag 'figcaption)
                           (cl-some
                            (lambda (c)
                              (string-match-p
                               "\\`\\(?:lang\\|code-lang\\|language\\|code-title\\|filename\\|file-name\\|code-header\\)\\'"
                               c))
                            classes)))))
            (when lang-badge
              (let* ((txt (etaf-web-lang--clean-text child))
                     (low (downcase txt)))
                (cond
                 ((and (<= (length low) 20)
                       (member low etaf-web-lang--known-langs))
                  (let ((norm (etaf-web-lang--normalize low)))
                    (when (and norm (not (equal norm "text")))
                      (setq found norm))))
                 ((<= (length txt) 80)
                  (let ((by-file (etaf-web-lang--from-filename txt)))
                    (when (and by-file (not (equal by-file "text")))
                      (setq found by-file))))))))))
      found)))

(defun etaf-web-lang--from-dom (pre-node code-node parent-map)
  "Layer 1+2: return canonical language or `explicit-plain' from DOM, or nil."
  (let* ((ancestors (etaf-web-lang--ancestors pre-node parent-map 3))
         (nodes (delq nil (append (list code-node pre-node) ancestors)))
         (explicit-plain nil)
         (found nil))
    (dolist (n nodes)
      (when (and (not found) (not explicit-plain))
        (let ((is-cp (or (eq n code-node) (eq n pre-node))))
          (setq found (etaf-web-lang--extract-from-node n is-cp))
          (when (and (not found) (etaf-web-lang--explicit-plain-node-p n))
            (setq explicit-plain t)))))
    (when (and (not found) (not explicit-plain))
      (dolist (w (cl-subseq ancestors 0 (min 2 (length ancestors))))
        (unless found
          (setq found (etaf-web-lang--extract-from-wrapper-siblings w pre-node)))))
    (cond
     (found found)
     (explicit-plain 'explicit-plain)
     (t nil))))

;;; ---------------------------------------------------------------------------
;;; Page-level weak prior (computed once per page)
;;; ---------------------------------------------------------------------------

(defun etaf-web-lang--url-or-title-prior (base-url title)
  "Return weak page-level language hint from BASE-URL or TITLE, or nil."
  (let ((u (downcase (or base-url "")))
        (tstr (downcase (or title ""))))
    (cond
     ((or (string-match-p "go\\.dev/doc\\|golang\\.org" u)
          (string-match-p "\\beffective go\\b" tstr))
      "go")
     ((string-match-p "doc\\.rust-lang\\.org\\|docs\\.rs/" u) "rust")
     ((string-match-p "docs\\.python\\.org\\|docs\\.pytest\\.org" u) "python")
     ((string-match-p "gnu\\.org/software/emacs/manual/html_node/elisp" u) "elisp")
     ((string-match-p "typescriptlang\\.org/docs" u) "ts")
     ((string-match-p "react\\.dev/learn\\|react\\.dev/reference" u) "jsx")
     ((string-match-p "vuejs\\.org/guide\\|vuejs\\.org/api" u) "js")
     ((string-match-p "svelte\\.dev/docs" u) "svelte")
     ((string-match-p "w3\\.org/tr/css-" u) "css")
     (t nil))))

(defun etaf-web-lang--page-prior (root parent-map base-url title)
  "Return weak page-level language prior from explicit blocks or URL/TITLE."
  (let ((counts (make-hash-table :test #'equal))
        (total 0))
    (cl-labels
        ((walk (n)
           (when (etaf-web-lang--node-p n)
             (if (eq (dom-tag n) 'pre)
                 (let* ((code-node (cl-find-if
                                    (lambda (c) (and (etaf-web-lang--node-p c)
                                                     (eq (dom-tag c) 'code)))
                                    (dom-children n)))
                        (lang (etaf-web-lang--from-dom n code-node parent-map)))
                   (when (and (stringp lang)
                              (not (member lang '("text" "sh" "bash" "console" "json" "yaml" "toml"))))
                     (puthash lang (1+ (gethash lang counts 0)) counts)
                     (setq total (1+ total))))
               (dolist (c (dom-children n)) (walk c))))))
      (walk root))
    (let ((best nil)
          (best-n 0))
      (maphash (lambda (k v)
                 (when (> v best-n) (setq best k best-n v)))
               counts)
      (if (and best (>= best-n 2) (>= (/ (float best-n) (max 1 total)) 0.60))
          best
        (etaf-web-lang--url-or-title-prior base-url title)))))

;;; ---------------------------------------------------------------------------
;;; Layer 3: Deterministic high-precision content anchors
;;; ---------------------------------------------------------------------------

(defun etaf-web-lang--non-code-p (body)
  "Return non-nil when BODY is clearly non-code (keybindings, ASCII art, paths)."
  (let ((trimmed (string-trim body)))
    (or (string-empty-p trimmed)
        (< (length trimmed) 3)
        ;; Emacs keybinding notation like `C-x C-f /sudo::/etc/hosts' or `M-x ...'.
        (and (not (string-match-p "\n" trimmed))
             (string-match-p "\\`[CMS]-[a-zA-Z0-9-]" trimmed))
        ;; ASCII art diagrams with long repeated `===' / `---' / box borders.
        (and (string-match-p "===\\{3,\\}\\|---\\{5,\\}\\|\\+---\\+\\|[┌┐└┘├┤┬┴┼─│]\\{4,\\}" trimmed)
             (not (string-match-p "^\\(?:diff --git\\|--- a/\\|SELECT \\|CREATE \\)" trimmed)))
        ;; Short single-line plain file path or prose (`~/.emacs or ~/.emacs.d/init.el').
        (and (not (string-match-p "\n" trimmed))
             (string-match-p
              "\\`\\(?:[$%][ \t]+\\)?[~./a-zA-Z0-9_-]+ or [~./a-zA-Z0-9_-]+\\'"
              trimmed)))))

(defun etaf-web-lang--shebang-lang (body)
  "Return canonical language from a leading `#!' shebang line, or nil."
  (when (string-match
         "\\`#![ \t]*\\(?:/usr/bin/env[ \t]+\\(?:-S[ \t]+\\)?\\|/[^ \t\n]*/\\)\\([a-zA-Z0-9_.-]+\\)"
         body)
    (let ((interp (downcase (match-string 1 body))))
      (cond
       ((string-prefix-p "python" interp) "python")
       ((equal interp "bash") "bash")
       ((member interp '("sh" "dash" "ash" "ksh")) "sh")
       ((equal interp "zsh") "zsh")
       ((equal interp "fish") "fish")
       ((member interp '("node" "nodejs" "deno" "bun")) "js")
       ((string-prefix-p "ruby" interp) "ruby")
       ((string-prefix-p "perl" interp) "perl")
       ((string-prefix-p "php" interp) "php")
       ((string-prefix-p "lua" interp) "lua")
       ((member interp '("awk" "gawk" "mawk")) "awk")
       ((equal interp "pwsh") "powershell")
       (t nil)))))

(defun etaf-web-lang--valid-json-p (trimmed)
  "Return non-nil when TRIMMED is a valid JSON object or array literal."
  (and (>= (length trimmed) 6)
       (or (and (string-prefix-p "{" trimmed) (string-suffix-p "}" trimmed)
                (string-match-p "\"[^\"]+\"[ \t]*:" trimmed))
           (and (string-prefix-p "[" trimmed) (string-suffix-p "]" trimmed)
                (string-match-p "[{\"]" trimmed)))
       (fboundp 'json-parse-string)
       (condition-case nil
           (progn (ignore (json-parse-string trimmed)) t)
         (error nil))))

(defun etaf-web-lang--balanced-parens-p (text)
  "Return non-nil when TEXT has balanced parens outside strings/comments."
  (let ((depth 0)
        (opens 0)
        (in-str nil)
        (in-cmt nil)
        (esc nil)
        (i 0)
        (len (length text))
        (ok t))
    (while (and ok (< i len))
      (let ((ch (aref text i)))
        (cond
         (in-cmt (when (= ch ?\n) (setq in-cmt nil)))
         (in-str
          (cond
           (esc (setq esc nil))
           ((= ch ?\\) (setq esc t))
           ((= ch ?\") (setq in-str nil))))
         (t
          (cond
           ((= ch ?\;) (setq in-cmt t))
           ((= ch ?\") (setq in-str t))
           ((= ch ?\() (setq depth (1+ depth) opens (1+ opens)))
           ((= ch ?\))
            (setq depth (1- depth))
            (when (< depth 0) (setq ok nil)))))))
      (setq i (1+ i)))
    (and ok (> opens 0) (= depth 0) (not in-str))))

(defun etaf-web-lang--shell-command-p (body)
  "Return non-nil when BODY is a shell prompt session or CLI invocation."
  (let* ((lines (cl-remove-if #'string-blank-p (split-string body "\n")))
         (first (and lines (string-trim (car lines)))))
    (when first
      (cond
       ;; Explicit `$ cmd' or `% cmd' shell prompt session.
       ((string-match-p "\\`[$%][ \t]+[a-zA-Z0-9_./~-]" first)
        t)
       ;; Short CLI invocation block (1..8 lines) starting with known CLI tool.
       ((and (<= (length lines) 8)
             (not (string-match-p "[{};]\\|\\bfunction \\|\\bdef \\|\\bfn \\|\\btype \\|\\bstruct " body))
             (string-match-p
              (concat
               "\\`\\(?:\\(?:sudo\\|doas\\)[ \t]+\\)?"
               "\\(?:git\\|cargo\\|rustup\\|rustc\\|npm\\|pnpm\\|yarn\\|npx\\|bun\\|deno\\|"
               "pip3?\\|uv\\|poetry\\|conda\\|brew\\|port\\|apt\\(?:-get\\)?\\|dnf\\|yum\\|"
               "pacman\\|yay\\|apk\\|nix\\(?:-env\\)?\\|flox\\|guix\\|emerge\\|zypper\\|"
               "pkg\\(?:_add\\|in\\|man\\)?\\|xbps-install\\|choco\\|scoop\\|winget\\|"
               "subscription-manager\\|docker\\|podman\\|kubectl\\|helm\\|terraform\\|"
               "curl\\|wget\\|make\\|cmake\\|ninja\\|python3?\\|pytest\\|node\\|ruby\\|gem\\|"
               "bundle\\|php\\|composer\\|emacs\\|emacsclient\\|jj\\|jjosh\\|rg\\|fd\\|"
               "systemctl\\|journalctl\\|chmod\\|chown\\|mkdir\\|export\\|tar\\|ssh\\|scp\\|rsync\\|pushd\\)"
               "\\(?:[ \t]+\\|\\'\\)"
               "\\|\\`go[ \t]+\\(?:get\\|run\\|build\\|test\\|install\\|mod\\|fmt\\|vet\\|doc\\)\\b")
              first))
        t)
       (t nil)))))

(defun etaf-web-lang--html-markup-p (trimmed)
  "Return non-nil when TRIMMED is standalone HTML markup (not JSX/CSS grammar)."
  (or (let ((case-fold-search t))
        (string-match-p "\\`<!doctype[ \t]+html\\b\\|\\`<html\\b" trimmed))
      (and (string-prefix-p "<" trimmed)
           (string-suffix-p ">" trimmed)
           ;; Exclude JS/TS/JSX modules & CSS value grammar (`<visual-box> = ...').
           (not (string-match-p "\\b\\(?:function\\|const\\|let\\|import\\|export\\|return\\)\\b" trimmed))
           (not (string-match-p "\\`<[a-z-]+>[ \t]*=" trimmed))
           (let ((case-fold-search t))
             (string-match-p
              "\\`<\\(?:div\\|span\\|p\\|a\\|ul\\|ol\\|li\\|nav\\|header\\|footer\\|main\\|article\\|section\\|form\\|input\\|button\\|table\\|tr\\|td\\|th\\|h[1-6]\\|img\\|script\\|style\\|link\\|meta\\|head\\|body\\|template\\|label\\|select\\|figure\\|pre\\|code\\)\\(?:[ \t\n/>]\\)"
              trimmed))
           (string-match-p "</[a-zA-Z][a-zA-Z0-9-]*>\\|/>\\'" trimmed))))

(defun etaf-web-lang--detect-anchor (body)
  "Layer 3: detect unmistakable language via deterministic content anchors."
  (let ((trimmed (string-trim body)))
    (cond
     ((etaf-web-lang--shebang-lang trimmed))
     ;; Python interactive REPL (`>>> ...').
     ((string-match-p "\\`>>>[ \t]+\\S-" trimmed)
      "python")
     ;; Unified diff.
     ((or (string-match-p "^diff --git " trimmed)
          (and (string-match-p "^--- " trimmed)
               (string-match-p "^\\+\\+\\+ " trimmed)
               (string-match-p "^@@ " trimmed)))
      "diff")
     ;; HTTP wire message.
     ((and (string-match-p
            "\\`\\(?:\\(?:GET\\|POST\\|PUT\\|PATCH\\|DELETE\\|HEAD\\|OPTIONS\\)[ \t]+/[^ \t\n]*[ \t]+HTTP/[12]\\|HTTP/[12]\\(?:\\.[01]\\)?[ \t]+[1-5][0-9][0-9]\\)"
            trimmed)
           (string-match-p "\n[A-Za-z][A-Za-z0-9-]+:[ \t]+" trimmed))
      "http")
     ;; Valid JSON object or array.
     ((etaf-web-lang--valid-json-p trimmed)
      "json")
     ;; Dockerfile.
     ((and (string-match-p "^FROM[ \t]+[^ \t\n]+" trimmed)
           (string-match-p "^\\(?:RUN\\|COPY\\|ADD\\|WORKDIR\\|ENV\\|EXPOSE\\|CMD\\|ENTRYPOINT\\|ARG\\)[ \t]+" trimmed))
      "dockerfile")
     ;; Makefile.
     ((or (string-match-p "^\\.PHONY:" trimmed)
          (and (string-match-p "^[A-Za-z0-9_./%-]+:[ \t]*[^\n]*\n\t" trimmed)
               (not (string-match-p "[{}]" trimmed))))
      "makefile")
     ;; Emacs Lisp / Common Lisp S-expressions.
     ((and (string-match-p "\\`\\(?:;[^\n]*\n[ \t]*\\)*(" trimmed)
           (etaf-web-lang--balanced-parens-p trimmed)
           (or (string-match-p
                "(\\(?:defun\\|defvar\\|defcustom\\|defconst\\|defmacro\\|cl-defun\\|setq\\|setq-default\\|add-hook\\|add-to-list\\|load\\|autoload\\|use-package\\|require\\|provide\\|global-set-key\\|keymap-set\\|define-key\\|with-eval-after-load\\|set-face-\\(?:background\\|foreground\\|attribute\\)\\|custom-set-\\(?:variables\\|faces\\)\\|let\\*?\\|progn\\|when-let\\*?\\|if-let\\*?\\|dolist\\|interactive\\|ert-deftest\\|defparameter\\|defclass\\|in-package\\)\\(?:[ \t\n)]\\)"
                trimmed)))
      (if (string-match-p "(\\(?:defparameter\\|defclass\\|in-package\\)\\b" trimmed)
          "lisp"
        "elisp"))
     ;; XML / SVG.
     ((let ((case-fold-search t))
        (string-match-p "\\`<\\?xml\\b\\|\\`<svg\\b" trimmed))
      "xml")
     ;; Standalone HTML or JSX snippet.
     ((etaf-web-lang--html-markup-p trimmed)
      (if (string-match-p "\\b\\(?:className\\|htmlFor\\|onClick\\|onChange\\|onSubmit\\)=" trimmed)
          "jsx"
        "html"))
     ;; SQL statements.
     ((and (not (string-match-p "[{}]" trimmed))
           (let ((case-fold-search t))
             (string-match-p
              (concat
               "\\`\\(?:--[^\n]*\n\\|[ \t\n]\\)*"
               "\\(?:SELECT\\b[^;]+\\bFROM\\b\\|"
               "SELECT[ \t]+\\(?:json_object\\|json_array\\|count\\|sum\\|avg\\|min\\|max\\|coalesce\\|version\\)("
               "\\|INSERT[ \t]+INTO\\b\\|"
               "UPDATE[ \t]+[a-zA-Z0-9_.\"`]+[ \t]+SET\\b\\|"
               "DELETE[ \t]+FROM\\b\\|"
               "CREATE[ \t]+\\(?:OR[ \t]+REPLACE[ \t]+\\)?\\(?:TABLE\\|VIEW\\|INDEX\\|DATABASE\\|SCHEMA\\|FUNCTION\\|TRIGGER\\)\\b\\|"
               "ALTER[ \t]+TABLE\\b\\|"
               "DROP[ \t]+\\(?:TABLE\\|VIEW\\|INDEX\\|DATABASE\\)\\b\\|"
               "WITH[ \t]+[a-zA-Z0-9_]+[ \t]+AS[ \t]*(\\|"
               "WAIT[ \t]+FOR[ \t]+LSN\\b\\)")
              trimmed)))
      "sql")
     ;; Bash script constructs (`if [[ ... ]]; then ... fi`).
     ((and (string-match-p "\\bif[ \t]+\\[\\[.+\\]\\];?[ \t\n]+then\\b" trimmed)
           (string-match-p "^[ \t]*fi\\b" trimmed))
      "bash")
     ;; Shell prompt sessions & CLI commands.
     ((etaf-web-lang--shell-command-p trimmed)
      "sh")
     ;; TOML / INI configuration.
     ((and (string-match-p "^\\[[a-zA-Z0-9_. \"-]+\\][ \t]*$" trimmed)
           (string-match-p "^[ \t]*[a-zA-Z0-9_.-]+[ \t]*=[ \t]*[^ \t\n]" trimmed)
           (not (string-match-p "[{};]" trimmed)))
      (if (string-match-p "^[ \t]*[a-zA-Z0-9_.-]+[ \t]*=[ \t]*\\(?:\"\\|\\[\\|true\\|false\\|[0-9]+\\(?:\\.[0-9]+\\)?[ \t]*$\\)" trimmed)
          "toml"
        "ini"))
     (t nil))))

;;; ---------------------------------------------------------------------------
;;; Layer 4: Margin-gated weighted feature scorer + weak page prior
;;; ---------------------------------------------------------------------------

(defun etaf-web-lang--count-matches (regexp text &optional cap)
  "Count non-overlapping matches of REGEXP in TEXT, capped at CAP (default 5)."
  (let ((limit (or cap 5))
        (count 0)
        (pos 0)
        (case-fold-search nil))
    (while (and (< count limit)
                (string-match regexp text pos))
      (setq count (1+ count)
            pos (max (1+ pos) (match-end 0))))
    count))

(defun etaf-web-lang--score-all (body)
  "Return alist of `(LANG . SCORE)' from weighted syntax features in BODY."
  (let* ((scores nil)
         (semi-lines (etaf-web-lang--count-matches ";[ \t]*$" body 6))
         (has-jsx (and (string-match-p "<[A-Za-z][A-Za-z0-9.]*\\(?:[ \t\n/>]\\)" body)
                       (string-match-p "</[A-Za-z][A-Za-z0-9.]*>\\|/>" body)
                       (string-match-p "\\b\\(?:return\\|function\\|const\\|export\\)\\b" body))))
    (cl-flet ((add (lang pts)
                (let ((cell (assoc lang scores)))
                  (if cell
                      (setcdr cell (+ (cdr cell) pts))
                    (push (cons lang pts) scores)))))
      ;; --- Go ---
      (let ((s 0.0))
        (when (string-match-p "^package[ \t]+[a-z_][a-z0-9_]*" body) (setq s (+ s 4.5)))
        (when (string-match-p "\\bfunc[ \t]+\\(?:([^)\n]+)[ \t]+\\)?[A-Za-z_][A-Za-z0-9_]*(" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "\\btype[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+\\(?:struct\\|interface\\)\\b" body)
          (setq s (+ s 4.0)))
        (when (string-match-p "\\btype[ \t]+[A-Z][A-Za-z0-9_]*[ \t]+\\(?:\\[\\|float64\\|float32\\|int\\|uint\\|string\\|byte\\|rune\\|func\\)" body)
          (setq s (+ s 3.5)))
        (when (string-match-p ":=" body) (setq s (+ s 2.5)))
        (when (string-match-p "\\bdefer[ \t]+" body) (setq s (+ s 2.5)))
        (when (string-match-p "\\bchan\\b\\|<-[ \t]*[a-zA-Z_]" body) (setq s (+ s 2.5)))
        (when (string-match-p "\\bfmt\\.[A-Z]\\|\\bos\\.[A-Z]\\|\\bhttp\\.[A-Z]\\|\\bruntime\\.[A-Z]" body)
          (setq s (+ s 3.0)))
        (when (string-match-p "\\berr[ \t]*!=[ \t]*nil\\b" body) (setq s (+ s 3.0)))
        (when (string-match-p "\\binterface{}" body) (setq s (+ s 3.0)))
        (when (string-match-p "^import[ \t]+(\\|^import[ \t]+\\(?:_[ \t]+\\)?\"" body) (setq s (+ s 3.5)))
        (when (string-match-p "^\\(?:var\\|const\\)[ \t]+(" body) (setq s (+ s 3.5)))
        (when (string-match-p "\\bvar[ \t]+_[ \t]+[A-Za-z0-9_.]+[ \t]*=" body) (setq s (+ s 3.5)))
        (when (string-match-p "\\bvar[ \t]+[a-zA-Z_][a-zA-Z0-9_]*[ \t]+\\(?:int\\|bool\\|string\\|byte\\|error\\|float64\\)\\b" body)
          (setq s (+ s 2.5)))
        (when (string-match-p "\\bmap\\[" body) (setq s (+ s 2.5)))
        (when (string-match-p "\\[\\]\\(?:byte\\|int\\|string\\|rune\\|float64\\)" body)
          (setq s (+ s 2.5)))
        (when (string-match-p "&[A-Z][A-Za-z0-9_]*{" body) (setq s (+ s 2.5)))
        (when (string-match-p "\\b\\(?:make\\|append\\|cap\\|len\\)(" body) (setq s (+ s 1.5)))
        (when (string-match-p "\\bfor[ \t]+[^;{\n]+:=[ \t]*range\\b" body) (setq s (+ s 3.5)))
        (when (string-match-p "\\bgo[ \t]+\\(?:func(\\|[a-zA-Z_][a-zA-Z0-9_.]*(\\)\\b" body)
          (setq s (+ s 3.0)))
        (when (string-match-p "\\b\\(?:string\\|int\\|int64\\|uint\\|byte\\|rune\\|bool\\|error\\)\\b" body)
          (setq s (+ s 0.8)))
        (when (string-match-p "\\b\\(?:def\\|fn\\|class\\|self\\.\\|function\\)\\b" body)
          (setq s (- s 3.0)))
        (when (>= semi-lines 3) (setq s (- s 2.0)))
        (when (> s 0.0) (add "go" s)))

      ;; --- Rust ---
      (let ((s 0.0))
        (when (string-match-p "\\b\\(?:pub[ \t]+\\)?\\(?:async[ \t]+\\)?fn[ \t]+[a-z_][a-z0-9_]*" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "\\blet[ \t]+mut[ \t]+" body) (setq s (+ s 3.5)))
        (when (string-match-p "\\bimpl\\(?:<[^>\n]+>\\)?[ \t]+[A-Z]" body) (setq s (+ s 3.5)))
        (when (string-match-p "\\bpub[ \t]+\\(?:struct\\|enum\\|trait\\|mod\\|type\\|const\\)[ \t]+" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "\\buse[ \t]+[a-z_][a-z0-9_]*::" body) (setq s (+ s 3.5)))
        (when (string-match-p "\\b\\(?:println\\|eprintln\\|format\\|vec\\|assert_eq\\|assert\\|panic\\|dbg\\)!" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "#\\[\\(?:derive\\|cfg\\|test\\|allow\\|inline\\)" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "->[ \t]*\\(?:Result\\|Option\\|Self\\|bool\\|usize\\|i32\\|u32\\|u64\\|String\\|Vec\\|&\\)" body)
          (setq s (+ s 3.0)))
        (when (string-match-p "&\\(?:mut[ \t]+\\)?\\(?:self\\|str\\|\\[\\)" body)
          (setq s (+ s 2.5)))
        (when (string-match-p "\\bmatch[ \t]+[^({\n]+{" body) (setq s (+ s 2.5)))
        (when (string-match-p "::[a-zA-Z_]" body) (setq s (+ s 1.2)))
        (when (string-match-p "\\b\\(?:func\\|def\\|function\\)\\b\\|:=" body)
          (setq s (- s 3.0)))
        (when (> s 0.0) (add "rust" s)))

      ;; --- Python ---
      (let ((s 0.0))
        (when (string-match-p "^[ \t]*\\(?:async[ \t]+\\)?def[ \t]+[a-zA-Z_][a-zA-Z0-9_]*(" body)
          (setq s (+ s 4.0)))
        (when (string-match-p "^[ \t]*class[ \t]+[A-Z][a-zA-Z0-9_]*\\(?:([^)\n]*)\\)?:" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "^[ \t]*from[ \t]+[a-zA-Z0-9_.]+[ \t]+import[ \t]+" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "^[ \t]*import[ \t]+[a-zA-Z_][a-zA-Z0-9_.]*\\(?:[ \t]+as[ \t]+\\|[ \t]*$\\)" body)
          (setq s (+ s 2.5)))
        (when (string-match-p "\\belif\\b" body) (setq s (+ s 3.0)))
        (when (string-match-p "\\bself\\.[a-zA-Z_]" body) (setq s (+ s 3.0)))
        (when (string-match-p "if[ \t]+__name__[ \t]*==[ \t]*['\"]__main__['\"]:" body)
          (setq s (+ s 4.5)))
        (when (string-match-p "^[ \t]*@[a-zA-Z_][a-zA-Z0-9_.]*\\(?:(\\|[ \t]*$\\)" body)
          (setq s (+ s 2.0)))
        (when (string-match-p "\\b\\(?:None\\|True\\|False\\)\\b" body) (setq s (+ s 1.5)))
        (when (string-match-p "\\blambda[ \t]+[^:\n]+:" body) (setq s (+ s 2.5)))
        (when (string-match-p "\\bprint(" body) (setq s (+ s 1.5)))
        (when (>= semi-lines 2) (setq s (- s 3.5)))
        (when (string-match-p "{\\s-*$" body) (setq s (- s 2.5)))
        (when (string-match-p "\\b\\(?:func\\|fn\\|function\\|const\\|var\\)\\b" body)
          (setq s (- s 2.5)))
        (when (> s 0.0) (add "python" s)))

      ;; --- JavaScript / JSX / TypeScript / TSX ---
      (let ((js 0.0)
            (ts 0.0))
        (when (string-match-p "\\b\\(?:export[ \t]+default[ \t]+\\|export[ \t]+\\)?\\(?:async[ \t]+\\)?function\\*?[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*(" body)
          (setq js (+ js 3.0)))
        (when (string-match-p "\\b\\(?:const\\|let\\|var\\)[ \t]+[{[A-Za-z_$]" body)
          (setq js (+ js 2.0)))
        (when (string-match-p "=>[ \t]*[{(\n]" body) (setq js (+ js 2.5)))
        (when (string-match-p "\\bconsole\\.\\(?:log\\|error\\|warn\\|info\\)(" body)
          (setq js (+ js 3.0)))
        (when (string-match-p "^[ \t]*import[ \t]+.+[ \t]+from[ \t]+['\"]" body)
          (setq js (+ js 3.5)))
        (when (string-match-p "\\bmodule\\.exports\\b\\|\\brequire(['\"]" body)
          (setq js (+ js 3.0)))
        (when (string-match-p "\\bdocument\\.\\(?:querySelector\\|getElementById\\|createElement\\)" body)
          (setq js (+ js 3.0)))
        (when (string-match-p "\\b\\(?:useState\\|useEffect\\|useRef\\|useMemo\\|useCallback\\|useContext\\)(" body)
          (setq js (+ js 3.5)))
        (when (string-match-p "===" body) (setq js (+ js 1.5)))
        (when (string-match-p "\\b\\(?:def\\|fn\\|func\\|pub\\)\\b\\|:=" body)
          (setq js (- js 3.5)))
        (when (string-match-p "^[ \t]*#include\\b" body) (setq js (- js 4.0)))
        ;; TypeScript-specific annotations.
        (when (string-match-p "\\b\\(?:export[ \t]+\\)?interface[ \t]+[A-Z][A-Za-z0-9_]*" body)
          (setq ts (+ ts 4.0)))
        (when (string-match-p "\\b\\(?:export[ \t]+\\)?type[ \t]+[A-Z][A-Za-z0-9_]*\\(?:<[^>\n]+>\\)?[ \t]*=" body)
          (setq ts (+ ts 4.0)))
        (when (string-match-p ":[ \t]*\\(?:string\\|number\\|boolean\\|void\\|unknown\\|never\\|any\\|Record<\\|Promise<\\|Array<\\)\\b" body)
          (setq ts (+ ts 3.0)))
        (when (string-match-p "\\bas[ \t]+const\\b\\|\\breadonly[ \t]+[a-zA-Z_]" body)
          (setq ts (+ ts 2.5)))
        (when (string-match-p "\\benum[ \t]+[A-Z][A-Za-z0-9_]*[ \t]*{" body)
          (setq ts (+ ts 2.5)))
        (cond
         ((and has-jsx (or (> (+ js ts) 2.5)
                           (string-match-p "\\`[ \t\n]*return[ \t]*(" body)))
          (add (if (>= ts 3.0) "tsx" "jsx") (+ (max js 2.0) ts 2.5)))
         ((>= ts 3.0)
          (add "ts" (+ js ts)))
         ((> js 0.0)
          (add "js" js))))

      ;; --- C & C++ ---
      (let ((c 0.0)
            (cpp 0.0))
        (when (string-match-p "^[ \t]*#include[ \t]*[<\"][^>\"\n]+[>\"]" body)
          (setq c (+ c 4.0) cpp (+ cpp 4.0)))
        (when (string-match-p "\\bint[ \t]+main[ \t]*(" body)
          (setq c (+ c 3.0) cpp (+ cpp 3.0)))
        (when (string-match-p "\\b\\(?:printf\\|fprintf\\|malloc\\|calloc\\|free\\|sizeof\\)(" body)
          (setq c (+ c 2.5)))
        (when (string-match-p "\\btypedef[ \t]+struct\\b" body)
          (setq c (+ c 3.5)))
        (when (string-match-p "\\bstd::[a-zA-Z_]" body) (setq cpp (+ cpp 4.5)))
        (when (string-match-p "\\btemplate[ \t]*<[^>\n]+>" body) (setq cpp (+ cpp 4.0)))
        (when (string-match-p "\\bnamespace[ \t]+[a-zA-Z_]" body) (setq cpp (+ cpp 3.0)))
        (when (string-match-p "\\bconstexpr\\b\\|\\bnullptr\\b\\|\\bstd::vector\\b" body)
          (setq cpp (+ cpp 3.5)))
        (when (> cpp c) (add "cpp" cpp))
        (when (and (> c 0.0) (>= c cpp)) (add "c" c)))

      ;; --- Java ---
      (let ((s 0.0))
        (when (string-match-p "\\bpublic[ \t]+\\(?:static[ \t]+\\)?\\(?:final[ \t]+\\)?\\(?:class\\|interface\\|enum\\|record\\)[ \t]+[A-Z]" body)
          (setq s (+ s 4.0)))
        (when (string-match-p "\\bpublic[ \t]+static[ \t]+void[ \t]+main\\b" body) (setq s (+ s 4.5)))
        (when (string-match-p "\\bSystem\\.out\\.print" body) (setq s (+ s 4.0)))
        (when (string-match-p "^[ \t]*import[ \t]+java\\." body) (setq s (+ s 4.0)))
        (when (string-match-p "@Override\\b" body) (setq s (+ s 3.0)))
        (when (> s 0.0) (add "java" s)))

      ;; --- C# ---
      (let ((s 0.0))
        (when (string-match-p "^[ \t]*using[ \t]+System\\b" body) (setq s (+ s 4.0)))
        (when (string-match-p "\\bConsole\\.Write" body) (setq s (+ s 4.0)))
        (when (string-match-p "\\bpublic[ \t]+\\(?:async[ \t]+\\)?Task<" body) (setq s (+ s 3.5)))
        (when (string-match-p "{\\s-*get;\\s-*set;\\s-*}" body) (setq s (+ s 3.5)))
        (when (> s 0.0) (add "csharp" s)))

      ;; --- Ruby ---
      (let ((s 0.0))
        (when (and (string-match-p "^[ \t]*def[ \t]+[a-z_][a-z0-9_?!]*" body)
                   (string-match-p "^[ \t]*end\\b" body))
          (setq s (+ s 4.0)))
        (when (string-match-p "\\bdo[ \t]+|[a-z_]" body) (setq s (+ s 3.5)))
        (when (string-match-p "\\battr_\\(?:reader\\|writer\\|accessor\\)\\b" body) (setq s (+ s 4.0)))
        (when (string-match-p "\\belsif\\b" body) (setq s (+ s 3.5)))
        (when (string-match-p "^[ \t]*puts[ \t]+" body) (setq s (+ s 2.0)))
        (when (> s 0.0) (add "ruby" s)))

      ;; --- PHP ---
      (let ((s 0.0))
        (when (string-match-p "<\\?php\\b" body) (setq s (+ s 5.0)))
        (when (and (string-match-p "\\$[a-zA-Z_][a-zA-Z0-9_]*[ \t]*=" body)
                   (string-match-p "->[a-zA-Z_]" body))
          (setq s (+ s 4.0)))
        (when (> s 0.0) (add "php" s)))

      ;; --- CSS ---
      (let ((s 0.0))
        (when (string-match-p "^[ \t]*@\\(?:media\\|keyframes\\|import\\|layer\\|theme\\|supports\\|font-face\\|property\\)\\b" body)
          (setq s (+ s 4.0)))
        (when (string-match-p "--[a-z][a-z0-9-]*:[ \t]*[^;\n]+;" body)
          (setq s (+ s 3.5)))
        (when (string-match-p "[.#a-zA-Z*][^{}\n]\\{0,50\\}{[ \t\n]*[a-z-]+:[ \t]*[^;{}\n]+" body)
          (setq s (+ s 3.0)))
        (let ((prop-hits
               (etaf-web-lang--count-matches
                "\\b\\(?:display\\|margin\\|padding\\|color\\|background\\(?:-color\\)?\\|font-\\(?:size\\|family\\|weight\\)\\|border\\(?:-radius\\)?\\|flex\\|grid\\|position\\|width\\|height\\|align-items\\|justify-content\\|appearance\\|gap\\):[ \t]*[^;\n}]+"
                body 4)))
          (setq s (+ s (* 1.5 prop-hits))))
        (when (string-match-p "\\b\\(?:function\\|func\\|def\\|fn\\|class\\|import\\|SELECT\\|struct\\)\\b" body)
          (setq s (- s 4.5)))
        (when (> s 0.0) (add "css" s)))

      ;; --- YAML ---
      (let ((s 0.0))
        (when (and (not (string-match-p "[{};]" body))
                   (not (string-match-p "\\b\\(?:SELECT\\|FROM\\|HTTP/\\)\\b" body)))
          (let ((kv-lines (etaf-web-lang--count-matches
                           "^[ \t]*[a-zA-Z_][a-zA-Z0-9_.-]*:[ \t]*\\(?:[^ \t\n].*\\)?$"
                           body 6))
                (list-lines (etaf-web-lang--count-matches "^[ \t]*-[ \t]+[a-zA-Z0-9_\"']" body 4)))
            (when (and (>= kv-lines 3)
                       (or (>= list-lines 1)
                           (string-match-p "^  [a-zA-Z_][a-zA-Z0-9_.-]*:" body)
                           (string-match-p "\\`---[ \t]*\n" body)))
              (setq s (+ 2.5 (* 0.5 kv-lines) (* 0.5 list-lines))))))
        (when (> s 0.0) (add "yaml" s))))
    scores))

(defun etaf-web-lang--detect-scored (body page-prior)
  "Layer 4: pick language from BODY via margin-gated scoring and PAGE-PRIOR."
  (let ((scores (etaf-web-lang--score-all body)))
    (when (and page-prior (stringp page-prior))
      (let ((cell (or (assoc page-prior scores)
                      (and (equal page-prior "jsx") (assoc "js" scores))
                      (and (equal page-prior "tsx") (assoc "ts" scores)))))
        ;; Weak prior ONLY boosts a candidate with real syntax evidence (>= 2.0).
        (when (and cell (>= (cdr cell) 2.0))
          (setcdr cell (+ (cdr cell) 1.5)))))
    (setq scores (sort scores (lambda (a b) (> (cdr a) (cdr b)))))
    (let* ((top (car scores))
           (second (cadr scores))
           (best-score (if top (cdr top) 0.0))
           (second-score (if second (cdr second) 0.0)))
      (when (and top
                 (>= best-score 4.0)
                 (>= (- best-score second-score) 2.0)
                 (>= best-score (* 1.45 (max 0.5 second-score))))
        (car top)))))

;;; ---------------------------------------------------------------------------
;;; Public entry for etaf-web-compile
;;; ---------------------------------------------------------------------------

(defun etaf-web-lang--detect (pre-node code-node body parent-map page-prior)
  "Identify canonical language for PRE-NODE / CODE-NODE holding BODY.
Runs the 4-layer funnel (DOM metadata -> alias normalization -> deterministic
content anchors -> margin-gated feature scoring with weak PAGE-PRIOR), falling
back to \"text\" when uncertain."
  (let ((dom-res (etaf-web-lang--from-dom pre-node code-node parent-map)))
    (cond
     ((eq dom-res 'explicit-plain) "text")
     ((stringp dom-res) dom-res)
     ((etaf-web-lang--non-code-p body) "text")
     ((etaf-web-lang--detect-anchor body))
     ((etaf-web-lang--detect-scored body page-prior))
     (t "text"))))

(provide 'etaf-web-lang)
;;; etaf-web-lang.el ends here
