;;; etaf-ui-markdown-highlight.el --- Colour fenced code with Emacs' own faces  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A fenced code block names its language, and Emacs already knows how to read
;; that language: `font-lock' gives every token a face, whether it comes from a
;; major mode's keywords or from a tree-sitter grammar.  This module runs the
;; language's own mode over the block's text in a scratch buffer and turns the
;; resulting faces into runs, so the painter draws the same colours the source
;; buffer would show.
;;
;; Nothing here loads a third-party package: a language prefers its installed
;; Emacs major mode or ready Tree-sitter mode, and falls back to a built-in
;; lightweight lexical scanner when no mode is available.  Shell sessions also
;; highlight prompts, commands, flags and pipes that `sh-mode' leaves unstyled.
;; Unknown languages and oversized blocks stay plain code, never slowing the
;; page.
;;
;; Highlighting is a pure function of (LANGUAGE . TEXT), so its answer is cached
;; by that key: a repaint of the same block costs one hash lookup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst etaf-ui-markdown-highlight--max-lines 400
  "Lines a code block may have and still be highlighted.
A page repaints after every keystroke, so a pasted file-long block is left in
one colour instead of turning typing into a fontification run.")

(defconst etaf-ui-markdown-highlight--max-chars 20000
  "Characters a code block may have and still be highlighted.")

(defconst etaf-ui-markdown-highlight--cache-size 256
  "Code blocks kept in the highlight cache.")

(defvar etaf-ui-markdown-highlight--cache (make-hash-table :test #'equal)
  "Highlighted runs by (LANGUAGE . TEXT).")

(defvar etaf-ui-markdown-highlight--buffers (make-hash-table :test #'eq)
  "Reusable hidden scratch buffers keyed by major mode.")

(defconst etaf-ui-markdown-highlight-languages
  '(("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode)
    ("el" . emacs-lisp-mode) ("lisp" . emacs-lisp-mode)
    ("common-lisp" . lisp-mode) ("clisp" . lisp-mode)
    ("scheme" . scheme-mode) ("clojure" . clojure-mode)
    ("python" . python-mode) ("python3" . python-mode)
    ("py" . python-mode) ("py3" . python-mode) ("pycon" . python-mode)
    ("javascript" . js-mode) ("js" . js-mode) ("mjs" . js-mode) ("cjs" . js-mode)
    ("jsx" . js-jsx-mode)
    ("typescript" . typescript-mode) ("ts" . typescript-mode)
    ("tsx" . tsx-ts-mode)
    ("json" . js-mode) ("jsonc" . js-mode) ("json5" . js-mode)
    ("c" . c-mode) ("h" . c-mode)
    ("cpp" . c++-mode) ("c++" . c++-mode) ("cxx" . c++-mode) ("cc" . c++-mode)
    ("objc" . objc-mode) ("java" . java-mode)
    ("csharp" . csharp-mode) ("cs" . csharp-mode)
    ("rust" . rust-mode) ("rs" . rust-mode)
    ("go" . go-mode) ("golang" . go-mode)
    ("ruby" . ruby-mode) ("rb" . ruby-mode)
    ("php" . php-mode) ("perl" . perl-mode) ("lua" . lua-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("zsh" . sh-mode) ("shell" . sh-mode)
    ("console" . sh-mode) ("shell-session" . sh-mode)
    ("fish" . fish-mode) ("powershell" . powershell-mode) ("ps1" . powershell-mode)
    ("bat" . bat-mode) ("dos" . bat-mode) ("cmd" . bat-mode)
    ("awk" . awk-mode) ("asm" . asm-mode)
    ("sql" . sql-mode) ("yaml" . yaml-mode) ("yml" . yaml-mode)
    ("toml" . conf-toml-mode) ("ini" . conf-mode) ("conf" . conf-mode)
    ("properties" . conf-javaprop-mode) ("dotenv" . conf-unix-mode)
    ("env" . conf-unix-mode) ("nginx" . nginx-mode)
    ("http" . conf-colon-mode) ("http-message" . conf-colon-mode)
    ("xml" . nxml-mode) ("html" . html-mode) ("svg" . nxml-mode)
    ("css" . css-mode) ("scss" . scss-mode) ("less" . css-mode)
    ("markdown" . markdown-mode) ("md" . markdown-mode)
    ("org" . org-mode) ("diff" . diff-mode) ("patch" . diff-mode)
    ("make" . makefile-mode) ("makefile" . makefile-mode)
    ("dockerfile" . dockerfile-mode) ("docker" . dockerfile-mode)
    ("cmake" . cmake-mode)
    ("latex" . latex-mode) ("tex" . latex-mode)
    ("haskell" . haskell-mode) ("hs" . haskell-mode)
    ("kotlin" . kotlin-mode) ("kt" . kotlin-mode)
    ("swift" . swift-mode) ("scala" . scala-mode)
    ("erlang" . erlang-mode) ("elixir" . elixir-mode)
    ("ocaml" . tuareg-mode) ("vim" . vimrc-mode)
    ("zig" . zig-mode) ("nix" . nix-mode) ("dart" . dart-mode)
    ("groovy" . groovy-mode) ("svelte" . svelte-mode) ("vue" . vue-mode)
    ("graphql" . graphql-mode) ("gql" . graphql-mode)
    ("protobuf" . protobuf-mode) ("proto" . protobuf-mode)
    ("hcl" . hcl-mode) ("terraform" . terraform-mode))
  "Fence language names and the major mode that reads each one.
Only a mode whose library is already loaded or loadable is used; the entry
keeps the name a document writes, which is not always the mode's name.")

(defconst etaf-ui-markdown-highlight--ts-modes
  '(("rust" rust-ts-mode . rust) ("rs" rust-ts-mode . rust)
    ("go" go-ts-mode . go) ("golang" go-ts-mode . go)
    ("typescript" typescript-ts-mode . typescript)
    ("ts" typescript-ts-mode . typescript)
    ("tsx" tsx-ts-mode . tsx)
    ("javascript" js-ts-mode . javascript) ("js" js-ts-mode . javascript)
    ("jsx" tsx-ts-mode . tsx)
    ("json" json-ts-mode . json) ("jsonc" json-ts-mode . json)
    ("python" python-ts-mode . python) ("python3" python-ts-mode . python)
    ("py" python-ts-mode . python)
    ("yaml" yaml-ts-mode . yaml) ("yml" yaml-ts-mode . yaml)
    ("toml" toml-ts-mode . toml)
    ("bash" bash-ts-mode . bash) ("sh" bash-ts-mode . bash)
    ("c" c-ts-mode . c) ("cpp" c++-ts-mode . cpp) ("c++" c++-ts-mode . cpp)
    ("java" java-ts-mode . java)
    ("csharp" csharp-ts-mode . c-sharp) ("cs" csharp-ts-mode . c-sharp)
    ("css" css-ts-mode . css) ("html" html-ts-mode . html)
    ("dockerfile" dockerfile-ts-mode . dockerfile)
    ("docker" dockerfile-ts-mode . dockerfile)
    ("cmake" cmake-ts-mode . cmake)
    ("ruby" ruby-ts-mode . ruby) ("rb" ruby-ts-mode . ruby)
    ("php" php-ts-mode . php) ("elixir" elixir-ts-mode . elixir)
    ("lua" lua-ts-mode . lua))
  "Built-in Emacs 29+ Tree-sitter modes paired with their grammar symbols.")

(defconst etaf-ui-markdown-highlight--fallback-modes
  '(("tsx" . js-jsx-mode)
    ("typescript" . js-mode) ("ts" . js-mode)
    ("yaml" . conf-colon-mode) ("yml" . conf-colon-mode)
    ("nginx" . conf-space-mode))
  "Built-in fallback modes when neither classic nor Tree-sitter modes load.")

(defun etaf-ui-markdown-highlight--try-mode (mode)
  "Return MODE if it is callable or its library loads cleanly, else nil."
  (when mode
    (let ((library (intern (replace-regexp-in-string "-mode\\'" "" (symbol-name mode)))))
      (when (or (fboundp mode)
                (require mode nil t)
                (require library nil t))
        (and (fboundp mode) mode)))))

(defun etaf-ui-markdown-highlight--try-ts-mode (language)
  "Return a ready built-in Tree-sitter mode for LANGUAGE, or nil."
  (when-let* ((entry (assoc language etaf-ui-markdown-highlight--ts-modes))
              (mode (cadr entry))
              (ts-lang (cddr entry)))
    (when (and (fboundp 'treesit-ready-p)
               (treesit-ready-p ts-lang t))
      (etaf-ui-markdown-highlight--try-mode mode))))

(defun etaf-ui-markdown-highlight--mode (language)
  "Return the major mode that reads LANGUAGE, or nil when none is available.
Tries the primary classic mode, then an Emacs 29+ Tree-sitter mode only when
its grammar is ready, and finally any built-in syntax fallback."
  (when-let* ((language (and (stringp language) (downcase language))))
    (let* ((primary (cdr (assoc language etaf-ui-markdown-highlight-languages)))
           (primary-is-ts (and primary
                               (string-suffix-p "-ts-mode" (symbol-name primary)))))
      (or (and (not primary-is-ts)
               (etaf-ui-markdown-highlight--try-mode primary))
          (etaf-ui-markdown-highlight--try-ts-mode language)
          (etaf-ui-markdown-highlight--try-mode
           (cdr (assoc language etaf-ui-markdown-highlight--fallback-modes)))))))

(defconst etaf-ui-markdown-highlight-roles
  '((font-lock-keyword-face . keyword)
    (font-lock-builtin-face . builtin)
    (font-lock-string-face . string)
    (font-lock-doc-face . string)
    (font-lock-comment-face . comment)
    (font-lock-comment-delimiter-face . comment)
    (font-lock-function-name-face . function)
    (font-lock-function-call-face . function)
    (font-lock-variable-name-face . variable)
    (font-lock-variable-use-face . variable)
    (font-lock-property-name-face . variable)
    (font-lock-property-use-face . variable)
    (font-lock-type-face . type)
    (font-lock-constant-face . constant)
    (font-lock-number-face . constant)
    (font-lock-escape-face . constant)
    (font-lock-operator-face . keyword)
    (font-lock-preprocessor-face . preprocessor)
    (font-lock-warning-face . warning))
  "The token role each font-lock face paints.
The highlighter reads the source of a fence with the language's own mode, so
the tokens are the faces font-lock already found; a role names what a token is,
which is what lets the page colour it from its own palette instead of copying
whatever the reader's theme happened to choose.")

(defconst etaf-ui-markdown-highlight-palettes
  '((light . ((keyword . "#cf222e") (builtin . "#0550ae") (string . "#0a3069")
              (comment . "#6e7781") (function . "#8250df") (variable . "#953800")
              (type . "#953800") (constant . "#0550ae") (preprocessor . "#953800")
              (warning . "#9a6700")))
    (dark . ((keyword . "#ff7b72") (builtin . "#79c0ff") (string . "#a5d6ff")
             (comment . "#8b949e") (function . "#d2a8ff") (variable . "#ffa657")
             (type . "#ffa657") (constant . "#79c0ff") (preprocessor . "#ffa657")
             (warning . "#e3b341"))))
  "Syntax colours a code block takes on a light and on a dark page.
They are the pairs a reader of GitHub's code view already knows, so a block sits
on the page the way a block sits in a browser: saturated enough to read on a
white surface and light enough on a dark one.  A face with no role keeps its
own colour, adjusted to the page's contrast.")

(defun etaf-ui-markdown-highlight-color (props dark)
  "Return the colour the run PROPS takes on a page of DARK appearance, or nil.
PROPS comes from `etaf-ui-markdown-highlight--face-props'; a run whose face has
no role answers nil, and its caller decides what to paint."
  (when-let* ((role (plist-get props :role))
              (palette (alist-get (if dark 'dark 'light)
                                  etaf-ui-markdown-highlight-palettes)))
    (alist-get role palette)))

(defun etaf-ui-markdown-highlight--face-props (face)
  "Return the drawing props of FACE as an Ebox style plist.
Only what a text run can express is kept: colour, weight, slant, underline and
strike-through.  An inherited attribute is resolved through the face itself, so
a mode that only sets a foreground still renders."
  (let* ((faces (ensure-list face))
         (primary (cl-find-if #'facep faces))
         (props nil))
    (when primary
      ;; The face's own name is the only handle on what the token is; a mode
      ;; that inherits from a font-lock face is resolved to the role too.
      (let ((role (cl-some (lambda (f)
                             (and (symbolp f)
                                  (cdr (assq f etaf-ui-markdown-highlight-roles))))
                           faces)))
        (when role (setq props (plist-put props :role role))))
      ;; INHERIT is t, not nil: a mode's face usually sets one attribute and
      ;; inherits the rest, and only an inherited value is the colour the
      ;; source buffer actually shows.
      (let ((foreground (face-attribute primary :foreground nil t)))
        (when (and (stringp foreground)
                   (not (member foreground '("unspecified" "default"))))
          (setq props (plist-put props :color foreground))))
      (let ((weight (face-attribute primary :weight nil t)))
        (when (memq weight '(bold semi-bold extra-bold ultra-bold light))
          (setq props (plist-put props :font-weight weight))))
      (let ((slant (face-attribute primary :slant nil t)))
        (when (memq slant '(italic oblique reverse-oblique reverse-italic))
          (setq props (plist-put props :font-style slant))))
      (let ((underline (face-attribute primary :underline nil t)))
        (when (and underline (not (memq underline '(unspecified nil))))
          (setq props (plist-put props :text-decoration-line '(underline)))))
      (let ((strike (face-attribute primary :strike-through nil t)))
        (when (and strike (not (memq strike '(unspecified nil))))
          (setq props (plist-put props :text-decoration-line '(line-through))))))
    props))

(defun etaf-ui-markdown-highlight--runs (text)
  "Return TEXT as runs of `(:text STRING :props PLIST)' by its faces.
The runs follow the face changes in order, so a stretch of one token stays one
run: a page of code is a handful of text nodes, not one per character."
  (let ((runs nil)
        (index 0)
        (end (length text))
        (face-cache (make-hash-table :test #'equal)))
    (while (< index end)
      (let* ((face (get-text-property index 'face text))
             (cached (gethash face face-cache 'miss))
             (props (if (eq cached 'miss)
                        (puthash face
                                 (etaf-ui-markdown-highlight--face-props face)
                                 face-cache)
                      cached))
             (next (or (next-single-property-change index 'face text end) end)))
        (when (> next index)
          (let ((run (list :text (substring-no-properties text index next)
                           :props props)))
            ;; A run that draws like the one before it joins it, so the page
            ;; does not pay for a new text node every token boundary.
            (if (and runs (equal (plist-get run :props) (plist-get (car runs) :props)))
                (setcar runs (list :text (concat (plist-get (car runs) :text)
                                                 (plist-get run :text))
                                   :props (plist-get run :props)))
              (push run runs))))
        (setq index next)))
    (nreverse runs)))

(defun etaf-ui-markdown-highlight-code (language text)
  "Return runs colouring TEXT as LANGUAGE, or nil when it cannot be coloured.
The answer is a list of `(:text STRING :props PLIST)' covering TEXT in order,
with PLIST an Ebox style plist; nil means paint the block in one colour.  This
runs the language's own major mode over the text, so keywords, strings,
comments and numbers come out as the source buffer shows them, and the result
costs one cache lookup on the next repaint."
  (when (and (stringp text)
             (stringp language)
             (<= (length text) etaf-ui-markdown-highlight--max-chars)
             (<= (cl-count ?\n text) etaf-ui-markdown-highlight--max-lines))
    (let* ((key (cons (downcase language) text))
           (cached (gethash key etaf-ui-markdown-highlight--cache 'miss)))
      (if (not (eq cached 'miss))
          cached
        (let ((runs (etaf-ui-markdown-highlight--compute language text)))
          (when (> (hash-table-count etaf-ui-markdown-highlight--cache)
                   etaf-ui-markdown-highlight--cache-size)
            (clrhash etaf-ui-markdown-highlight--cache))
          (puthash key runs etaf-ui-markdown-highlight--cache)
          runs)))))

(defun etaf-ui-markdown-highlight--buffer (mode)
  "Return a live hidden scratch buffer initialized in MODE, or nil.
Reusing one buffer per major mode avoids paying mode setup on every keystroke
while editing inside a fenced code block."
  (let ((existing (gethash mode etaf-ui-markdown-highlight--buffers)))
    (if (and (buffer-live-p existing)
             (not (eq (buffer-local-value 'major-mode existing)
                      'fundamental-mode)))
        existing
      (let ((buf (generate-new-buffer (format " *etaf-ui-md-hl-%s*" mode)))
            (inhibit-message t)
            (message-log-max nil))
        (with-current-buffer buf
          (setq-local buffer-undo-list t)
          ;; `delay-mode-hooks' keeps the mode from running a user's hooks in a
          ;; throwaway buffer; only the syntax rules matter here.
          (condition-case nil
              (delay-mode-hooks (funcall mode))
            (error nil))
          (if (not (eq major-mode 'fundamental-mode))
              (progn
                (setq-local font-lock-verbose nil)
                (puthash mode buf etaf-ui-markdown-highlight--buffers)
                buf)
            (kill-buffer buf)
            nil))))))

;;; ---------------------------------------------------------------------------
;;; Built-in zero-dependency lightweight lexer fallback & Shell CLI enhancer
;;; ---------------------------------------------------------------------------

(defun etaf-ui-markdown-highlight--word-set (words)
  "Build an `equal' hash-table set from space-separated WORDS string."
  (let ((tbl (make-hash-table :test #'equal)))
    (dolist (w (split-string words "[ \t\n]+" t))
      (puthash w t tbl))
    tbl))

(defconst etaf-ui-markdown-highlight--lex-specs
  (let* ((go-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :strings '(double backtick char) :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
                :types (etaf-ui-markdown-highlight--word-set
                        "any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr")
                :constants (etaf-ui-markdown-highlight--word-set
                            "true false nil iota")
                :builtins (etaf-ui-markdown-highlight--word-set
                           "append cap clear close complex copy delete imag len make max min new panic print println real recover")))
         (rust-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :strings '(double char) :rust-lifetimes t :rust-macros t
                :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while")
                :types (etaf-ui-markdown-highlight--word-set
                        "bool char str i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 String Vec Option Result Box Arc Rc HashMap HashSet BTreeMap")
                :constants (etaf-ui-markdown-highlight--word-set
                            "true false Some None Ok Err")))
         (docker-spec
          (list :line-comment "#" :strings '(double single)
                :case-insensitive-kw t :vars t :flags t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS")))
         (zig-spec
          (list :line-comment "//" :strings '(double char)
                :at-builtins t :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while")
                :types (etaf-ui-markdown-highlight--word-set
                        "bool f16 f32 f64 f80 f128 i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize c_char c_int c_long c_short c_uint c_ulong c_ushort comptime_float comptime_int anyerror anyopaque void noreturn type")
                :constants (etaf-ui-markdown-highlight--word-set
                            "true false null undefined")))
         (sfc-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :html-comment t :html-tags t
                :strings '(double single backtick)
                :keywords (etaf-ui-markdown-highlight--word-set
                           "as async await break case catch class const continue default delete do else export extends finally for from function if import in instanceof interface let new of return static switch this throw try type typeof var void while yield")
                :types (etaf-ui-markdown-highlight--word-set
                        "string number boolean any unknown never void object Record Array Promise")
                :constants (etaf-ui-markdown-highlight--word-set
                            "true false null undefined NaN Infinity")))
         (kotlin-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :strings '(double char) :at-builtins t :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "abstract actual annotation as break by catch class companion const constructor continue crossinline data do else enum expect external final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias val var vararg when where while")
                :types (etaf-ui-markdown-highlight--word-set
                        "Any Boolean Byte Char Double Float Int Long Nothing Short String Unit List Map Set")
                :constants (etaf-ui-markdown-highlight--word-set "true false null")))
         (swift-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :strings '(double) :at-builtins t :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "actor as async await break case catch class continue default defer do else enum extension fallthrough fileprivate for func guard if import in init inout internal is let mutating nonmutating open operator override private protocol public repeat rethrows return self Self static struct subscript super switch throw throws try typealias var where while")
                :types (etaf-ui-markdown-highlight--word-set
                        "Any Bool Character Double Float Int Int64 String UInt Void Array Dictionary Set Optional")
                :constants (etaf-ui-markdown-highlight--word-set "true false nil")))
         (scala-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :strings '(double char) :at-builtins t :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "abstract case catch class def do else enum export extends final finally for given if implicit import lazy match new object override package private protected return sealed super then this throw trait try type using val var while with yield")
                :types (etaf-ui-markdown-highlight--word-set
                        "Any AnyVal Boolean Byte Char Double Float Int Long Nothing Short String Unit Option Either List Seq Map Set")
                :constants (etaf-ui-markdown-highlight--word-set "true false null None Some")))
         (dart-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :strings '(double single) :at-builtins t :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield")
                :types (etaf-ui-markdown-highlight--word-set
                        "bool double int num String Object Future Stream List Map Set Iterable")
                :constants (etaf-ui-markdown-highlight--word-set "true false null")))
         (haskell-spec
          (list :line-comment "--" :block-comment '("{-". "-}")
                :strings '(double char) :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "as case class data default deriving do else forall foreign hiding if import in infix infixl infixr instance let mdo module newtype of qualified then type where")
                :types (etaf-ui-markdown-highlight--word-set
                        "Bool Char Double Float Int Integer IO Maybe Either String Ordering")
                :constants (etaf-ui-markdown-highlight--word-set "True False Nothing Just Left Right")))
         (elixir-spec
          (list :line-comment "#" :strings '(double single) :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "after alias and case catch cond def defdelegate defexception defguard defimpl defmacro defmodule defp defprotocol defstruct do else end fn for if import in not or quote raise receive require rescue try unless unquote use when with")
                :constants (etaf-ui-markdown-highlight--word-set "true false nil")))
         (erlang-spec
          (list :line-comment "%" :strings '(double) :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse receive rem try when xor")
                :constants (etaf-ui-markdown-highlight--word-set "true false ok error undefined")))
         (ocaml-spec
          (list :block-comment '("(*" . "*)") :strings '(double)
                :keywords (etaf-ui-markdown-highlight--word-set
                           "and as assert asr begin class constraint do done downto else end exception external for fun function functor if in include inherit initializer land lazy let lor lsl lsr lxor match method mod module mutable new nonrec object of open or private rec sig struct then to try type val virtual when while with")
                :types (etaf-ui-markdown-highlight--word-set "int float bool char string bytes unit list array option result")
                :constants (etaf-ui-markdown-highlight--word-set "true false None Some Ok Error")))
         (nix-spec
          (list :line-comment "#" :block-comment '("/*" . "*/")
                :strings '(double)
                :keywords (etaf-ui-markdown-highlight--word-set
                           "assert else if in inherit let or rec then with")
                :builtins (etaf-ui-markdown-highlight--word-set
                           "builtins derivation import fetchTarball fetchGit fetchurl map foldl' filter")
                :constants (etaf-ui-markdown-highlight--word-set "true false null")))
         (lua-spec
          (list :line-comment "--" :strings '(double single)
                :keywords (etaf-ui-markdown-highlight--word-set
                           "and break do else elseif end for function goto if in local not or repeat return then until while")
                :builtins (etaf-ui-markdown-highlight--word-set
                           "assert error ipairs next pairs pcall print require select tonumber tostring type xpcall")
                :constants (etaf-ui-markdown-highlight--word-set "true false nil")))
         (clojure-spec
          (list :line-comment ";" :strings '(double)
                :keywords (etaf-ui-markdown-highlight--word-set
                           "def defn defn- defmacro defprotocol defrecord defmulti defmethod deftype fn let loop recur if when cond case do dotimes doseq for ns require import use try catch finally throw quote")
                :constants (etaf-ui-markdown-highlight--word-set "true false nil")))
         (powershell-spec
          (list :line-comment "#" :strings '(double single)
                :vars t :case-insensitive-kw t :flags t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "begin break catch class continue data do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using while")
                :constants (etaf-ui-markdown-highlight--word-set "true false null")))
         (fish-spec
          (list :line-comment "#" :strings '(double single) :vars t :flags t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "and begin break builtin case command continue else end eval exec for function if in not or return set switch while")))
         (graphql-spec
          (list :line-comment "#" :strings '(double) :at-builtins t :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "directive enum extend fragment implements input interface mutation on query repeatable scalar schema subscription type union")
                :types (etaf-ui-markdown-highlight--word-set "ID Int Float String Boolean")
                :constants (etaf-ui-markdown-highlight--word-set "true false null")))
         (proto-spec
          (list :line-comment "//" :block-comment '("/*" . "*/")
                :strings '(double single) :type-cap t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "edition enum extend extensions import map message oneof option optional package public repeated required reserved returns rpc service stream syntax to weak")
                :types (etaf-ui-markdown-highlight--word-set
                        "bool bytes double fixed32 fixed64 float int32 int64 sfixed32 sfixed64 sint32 sint64 string uint32 uint64")
                :constants (etaf-ui-markdown-highlight--word-set "true false")))
         (hcl-spec
          (list :line-comment "#" :block-comment '("/*" . "*/")
                :strings '(double)
                :keywords (etaf-ui-markdown-highlight--word-set
                           "backend count data depends_on dynamic for for_each if in lifecycle locals module output provider required_providers resource terraform variable")
                :constants (etaf-ui-markdown-highlight--word-set "true false null")))
         (cmake-spec
          (list :line-comment "#" :strings '(double) :vars t :case-insensitive-kw t
                :keywords (etaf-ui-markdown-highlight--word-set
                           "add_custom_command add_custom_target add_definitions add_dependencies add_executable add_library add_subdirectory add_test break cmake_minimum_required configure_file else elseif endforeach endfunction endif endmacro endwhile fetchcontent_declare file find_library find_package find_path find_program foreach function if include install list macro message option project return set string target_compile_definitions target_compile_options target_include_directories target_link_libraries target_sources unset while")
                :constants (etaf-ui-markdown-highlight--word-set
                            "ON OFF TRUE FALSE PUBLIC PRIVATE INTERFACE STATIC SHARED REQUIRED")))
         (abnf-spec
          (list :line-comment ";" :strings '(double) :abnf t
                :builtins (etaf-ui-markdown-highlight--word-set
                           "ALPHA BIT CHAR CR CRLF CTL DIGIT DQUOTE HEXDIG HTAB LF LWSP OCTET SP VCHAR WSP OWS BWS RWS"))))
    (list (cons "go" go-spec) (cons "golang" go-spec)
          (cons "rust" rust-spec) (cons "rs" rust-spec)
          (cons "dockerfile" docker-spec) (cons "docker" docker-spec)
          (cons "zig" zig-spec)
          (cons "svelte" sfc-spec) (cons "vue" sfc-spec)
          (cons "kotlin" kotlin-spec) (cons "kt" kotlin-spec)
          (cons "swift" swift-spec)
          (cons "scala" scala-spec)
          (cons "dart" dart-spec) (cons "groovy" kotlin-spec)
          (cons "haskell" haskell-spec) (cons "hs" haskell-spec)
          (cons "elixir" elixir-spec) (cons "erlang" erlang-spec)
          (cons "ocaml" ocaml-spec) (cons "nix" nix-spec)
          (cons "lua" lua-spec) (cons "clojure" clojure-spec)
          (cons "powershell" powershell-spec) (cons "ps1" powershell-spec)
          (cons "fish" fish-spec)
          (cons "graphql" graphql-spec) (cons "gql" graphql-spec)
          (cons "protobuf" proto-spec) (cons "proto" proto-spec)
          (cons "hcl" hcl-spec) (cons "terraform" hcl-spec)
          (cons "cmake" cmake-spec)
          (cons "abnf" abnf-spec) (cons "abnf9110" abnf-spec)
          (cons "bnf" abnf-spec) (cons "ebnf" abnf-spec)))
  "Built-in zero-dependency lightweight lexer specs for fallback highlighting.")

(defun etaf-ui-markdown-highlight--push-run (runs slice props)
  "Prepend SLICE with PROPS onto reversed RUNS, coalescing equal PROPS."
  (if (and runs (equal (plist-get (car runs) :props) props))
      (progn
        (setcar runs (list :text (concat (plist-get (car runs) :text) slice)
                           :props props))
        runs)
    (cons (list :text slice :props props) runs)))

(defun etaf-ui-markdown-highlight--scan-quoted (text i len quote)
  "Return end index after a QUOTE-delimited string starting at I in TEXT."
  (let ((j (1+ i))
        (esc nil))
    (while (< j len)
      (let ((ch (aref text j)))
        (cond
         (esc (setq esc nil j (1+ j)))
         ((and (not (= quote ?`)) (= ch ?\\)) (setq esc t j (1+ j)))
         ((= ch quote) (setq j (1+ j)) (setq len j))
         ((and (not (= quote ?`)) (= ch ?\n)) (setq len j))
         (t (setq j (1+ j))))))
    j))

(defun etaf-ui-markdown-highlight--lex (spec text)
  "Tokenize TEXT with lightweight SPEC into `(:text STRING :props PLIST)' runs."
  (let* ((len (length text))
         (i 0)
         (runs nil)
         (line-cmt (plist-get spec :line-comment))
         (blk-cmt (plist-get spec :block-comment))
         (html-cmt (plist-get spec :html-comment))
         (html-tags (plist-get spec :html-tags))
         (strings (plist-get spec :strings))
         (kw-set (plist-get spec :keywords))
         (type-set (plist-get spec :types))
         (const-set (plist-get spec :constants))
         (builtin-set (plist-get spec :builtins))
         (ci-kw (plist-get spec :case-insensitive-kw))
         (type-cap (plist-get spec :type-cap))
         (rust-lt (plist-get spec :rust-lifetimes))
         (rust-mac (plist-get spec :rust-macros))
         (at-bi (plist-get spec :at-builtins))
         (vars (plist-get spec :vars))
         (flags (plist-get spec :flags))
         (abnf (plist-get spec :abnf))
         (case-fold-search nil)
         (at-bol t))
    (while (< i len)
      (let ((ch (aref text i))
            (next nil)
            (role nil))
        (cond
         ;; Newline resets at-bol.
         ((= ch ?\n)
          (setq next (1+ i) at-bol t))
         ;; Horizontal whitespace.
         ((or (= ch ?\s) (= ch ?\t))
          (let ((j (1+ i)))
            (while (and (< j len) (memq (aref text j) '(?\s ?\t)))
              (setq j (1+ j)))
            (setq next j)))
         ;; HTML comment `<!-- ... -->'.
         ((and html-cmt (<= (+ i 4) len)
               (string= (substring text i (+ i 4)) "<!--"))
          (let ((end (string-match "-->" text (+ i 4))))
            (setq next (if end (+ end 3) len) role 'comment at-bol nil)))
         ;; Block comment (`/* ... */', `{- ... -}', `(* ... *)').
         ((and blk-cmt
               (let ((open (car blk-cmt)))
                 (and (<= (+ i (length open)) len)
                      (string= (substring text i (+ i (length open))) open))))
          (let* ((open (car blk-cmt))
                 (close (cdr blk-cmt))
                 (end (string-match (regexp-quote close) text (+ i (length open)))))
            (setq next (if end (+ end (length close)) len)
                  role 'comment at-bol nil)))
         ;; Line comment (`//', `#', `--', `;', `%').
         ((and line-cmt
               (<= (+ i (length line-cmt)) len)
               (string= (substring text i (+ i (length line-cmt))) line-cmt))
          (let ((nl (cl-position ?\n text :start i)))
            (setq next (or nl len) role 'comment at-bol nil)))
         ;; Rust attribute `#[...]' or `#![...]'.
         ((and rust-mac (= ch ?#) (< (1+ i) len)
               (or (= (aref text (1+ i)) ?\[)
                   (and (= (aref text (1+ i)) ?!)
                        (< (+ i 2) len)
                        (= (aref text (+ i 2)) ?\[))))
          (let ((close (cl-position ?\] text :start i)))
            (setq next (if close (1+ close) (or (cl-position ?\n text :start i) len))
                  role 'preprocessor at-bol nil)))
         ;; Double-quoted string.
         ((and (memq 'double strings) (= ch ?\"))
          (setq next (etaf-ui-markdown-highlight--scan-quoted text i len ?\")
                role 'string at-bol nil))
         ;; Backtick string.
         ((and (memq 'backtick strings) (= ch ?`))
          (setq next (etaf-ui-markdown-highlight--scan-quoted text i len ?`)
                role 'string at-bol nil))
         ;; Single-quoted string or char literal / Rust lifetime.
         ((and (= ch ?') (or (memq 'single strings) (memq 'char strings) rust-lt))
          (cond
           ((memq 'single strings)
            (setq next (etaf-ui-markdown-highlight--scan-quoted text i len ?')
                  role 'string at-bol nil))
           ;; Char literal `'a'` or `'\n'` or `'\x20'`.
           ((and (memq 'char strings)
                 (string-match "\\`'\\(?:\\\\.\\|[^'\\\n]\\)'" (substring text i (min len (+ i 8)))))
            (setq next (+ i (match-end 0)) role 'string at-bol nil))
           ;; Rust lifetime `'a`, `'static`.
           ((and rust-lt (< (1+ i) len)
                 (string-match "\\`'[a-zA-Z_][a-zA-Z0-9_]*" (substring text i (min len (+ i 32)))))
            (setq next (+ i (match-end 0)) role 'type at-bol nil))
           (t
            (setq next (1+ i) at-bol nil))))
         ;; HTML/Vue/Svelte tags `<tag` / `</tag`.
         ((and html-tags (= ch ?<) (< (1+ i) len)
               (string-match "\\`</?\\([a-zA-Z][a-zA-Z0-9_:-]*\\)"
                             (substring text i (min len (+ i 48)))))
          (setq next (+ i (match-end 0)) role 'function at-bol nil))
         ;; ABNF `<prose-val>` or `%xHH` / `%dNN`.
         ((and abnf (= ch ?<)
               (string-match "\\`<[^>\n]+>" (substring text i (min len (+ i 80)))))
          (setq next (+ i (match-end 0)) role 'string at-bol nil))
         ((and abnf (= ch ?%)
               (string-match "\\`%[bdxBDX][0-9a-fA-F.-]+" (substring text i (min len (+ i 32)))))
          (setq next (+ i (match-end 0)) role 'constant at-bol nil))
         ;; Shell/Dockerfile/CMake/PowerShell `$VAR` / `${VAR}`.
         ((and vars (= ch ?$)
               (string-match "\\`\\$\\(?:{[^}\n]+}\\|[a-zA-Z_][a-zA-Z0-9_:]*\\)"
                             (substring text i (min len (+ i 48)))))
          (setq next (+ i (match-end 0)) role 'variable at-bol nil))
         ;; Zig/Kotlin/Swift/GraphQL `@builtin` / `@annotation`.
         ((and at-bi (= ch ?@)
               (string-match "\\`@[a-zA-Z_][a-zA-Z0-9_]*"
                             (substring text i (min len (+ i 40)))))
          (setq next (+ i (match-end 0)) role 'builtin at-bol nil))
         ;; CLI-style `--flag` / `-flag` (Dockerfile/PowerShell/Fish).
         ((and flags (= ch ?-) (or at-bol (and (> i 0) (memq (aref text (1- i)) '(?\s ?\t))))
               (string-match "\\`--?[a-zA-Z][a-zA-Z0-9_-]*"
                             (substring text i (min len (+ i 40)))))
          (setq next (+ i (match-end 0)) role 'constant at-bol nil))
         ;; Numbers (`0x1f`, `3.14`, `42`).
         ((and (>= ch ?0) (<= ch ?9)
               (or (= i 0)
                   (not (string-match-p "[a-zA-Z0-9_]" (substring text (1- i) i)))))
          (string-match "\\`\\(?:0[xXbBoO][0-9a-fA-F_]+\\|[0-9][0-9_]*\\(?:\\.[0-9_]+\\)?\\(?:[eE][+-]?[0-9_]+\\)?\\)"
                        (substring text i (min len (+ i 40))))
          (setq next (+ i (match-end 0)) role 'constant at-bol nil))
         ;; Identifiers, keywords, types, constants, builtins, calls, macros.
         ((or (and (>= ch ?a) (<= ch ?z))
              (and (>= ch ?A) (<= ch ?Z))
              (= ch ?_))
          (let ((j (1+ i)))
            (while (and (< j len)
                        (let ((c (aref text j)))
                          (or (and (>= c ?a) (<= c ?z))
                              (and (>= c ?A) (<= c ?Z))
                              (and (>= c ?0) (<= c ?9))
                              (= c ?_)
                              (and abnf (= c ?-)))))
              (setq j (1+ j)))
            ;; Include trailing `!' on Rust macros (`vec!`, `println!`).
            (when (and rust-mac (< j len) (= (aref text j) ?!))
              (setq j (1+ j)))
            (let* ((word (substring text i j))
                   (key (if ci-kw (upcase word) word))
                   (key-lo (if ci-kw (downcase word) word))
                   (after-ws (let ((k j))
                               (while (and (< k len) (memq (aref text k) '(?\s ?\t)))
                                 (setq k (1+ k)))
                               k)))
              (setq role
                    (cond
                     ((and rust-mac (string-suffix-p "!" word)) 'preprocessor)
                     ((and kw-set (or (gethash word kw-set)
                                      (and ci-kw (or (gethash key kw-set)
                                                     (gethash key-lo kw-set)))))
                      'keyword)
                     ((and const-set (or (gethash word const-set)
                                         (and ci-kw (gethash key const-set))))
                      'constant)
                     ((and type-set (gethash word type-set)) 'type)
                     ((and builtin-set (gethash word builtin-set)) 'builtin)
                     ((and abnf at-bol (< after-ws len) (= (aref text after-ws) ?=))
                      'function)
                     ((and (< j len) (= (aref text j) ?\()) 'function)
                     ((and type-cap (>= ch ?A) (<= ch ?Z)
                           (string-match-p "[a-z]" word))
                      'type)
                     (t nil)))
              (setq next j at-bol nil))))
         ;; Any other single punctuation character.
         (t
          (setq next (1+ i) at-bol nil)))
        (setq runs (etaf-ui-markdown-highlight--push-run
                    runs (substring text i next)
                    (when role (list :role role))))
        (setq i next)))
    (nreverse runs)))

(defconst etaf-ui-markdown-highlight--shell-langs
  '("sh" "bash" "zsh" "shell" "console" "shell-session")
  "Languages whose uncolored CLI runs receive prompt/command/flag enhancement.")

(defconst etaf-ui-markdown-highlight--shell-wrappers
  '("sudo" "doas" "env" "command" "exec" "nohup" "time" "xargs")
  "Shell command prefixes that keep the next word in command position.")

(defun etaf-ui-markdown-highlight--enhance-shell (runs)
  "Enhance uncolored spans in shell RUNS with prompt, command, flag and pipe roles.
Already-colored runs from `sh-mode' (strings, comments, variables, keywords)
are preserved untouched, and concatenation of all `:text' remains identical."
  (let ((out nil)
        (at-bol t)
        (expect-cmd t)
        (case-fold-search nil))
    (dolist (run runs)
      (let ((txt (plist-get run :text))
            (props (plist-get run :props)))
        (if props
            (progn
              (setq out (etaf-ui-markdown-highlight--push-run out txt props))
              (if (string-suffix-p "\n" txt)
                  (setq at-bol t expect-cmd t)
                (setq at-bol nil expect-cmd nil)))
          (let ((i 0)
                (len (length txt)))
            (while (< i len)
              (let ((ch (aref txt i))
                    (next nil)
                    (role nil))
                (cond
                 ((= ch ?\n)
                  (setq next (1+ i) at-bol t expect-cmd t))
                 ((or (= ch ?\s) (= ch ?\t))
                  (let ((j (1+ i)))
                    (while (and (< j len) (memq (aref txt j) '(?\s ?\t)))
                      (setq j (1+ j)))
                    (setq next j)))
                 ;; Leading prompt (`$ ', `% ', `> ') at line start.
                 ((and at-bol (memq ch '(?$ ?% ?>))
                       (< (1+ i) len) (memq (aref txt (1+ i)) '(?\s ?\t)))
                  (setq next (1+ i) role 'comment at-bol nil expect-cmd t))
                 ;; Shell control/pipe/redirect operators.
                 ((and (<= (+ i 2) len)
                       (member (substring txt i (+ i 2)) '("&&" "||" ">>" "<<")))
                  (let ((op (substring txt i (+ i 2))))
                    (setq next (+ i 2) role 'keyword at-bol nil
                          expect-cmd (member op '("&&" "||")))))
                 ((memq ch '(?| ?\; ?> ?<))
                  (setq next (1+ i) role 'keyword at-bol nil
                        expect-cmd (memq ch '(?| ?\;))))
                 ;; CLI flags (`--release`, `-sb`, `-f`).
                 ((and (= ch ?-) (not expect-cmd)
                       (or (= i 0) (memq (aref txt (1- i)) '(?\s ?\t)))
                       (string-match "\\`--?[a-zA-Z0-9][a-zA-Z0-9_.-]*"
                                     (substring txt i (min len (+ i 48)))))
                  (setq next (+ i (match-end 0)) role 'constant at-bol nil))
                 ;; Command name in command position.
                 ((and expect-cmd
                       (string-match "\\`[a-zA-Z0-9_./~][a-zA-Z0-9_./~+-]*"
                                     (substring txt i (min len (+ i 48)))))
                  (let* ((end (+ i (match-end 0)))
                         (tok (substring txt i end)))
                    (cond
                     ;; Variable assignment `FOO=bar` before command.
                     ((and (< end len) (= (aref txt end) ?=))
                      (setq next end role 'variable at-bol nil expect-cmd nil))
                     ((member tok etaf-ui-markdown-highlight--shell-wrappers)
                      (setq next end role 'builtin at-bol nil expect-cmd t))
                     (t
                      (setq next end role 'function at-bol nil expect-cmd nil)))))
                 ;; Plain argument token.
                 (t
                  (let ((j (1+ i)))
                    (while (and (< j len)
                                (not (memq (aref txt j)
                                           '(?\s ?\t ?\n ?| ?\; ?> ?< ?&))))
                      (setq j (1+ j)))
                    (setq next j at-bol nil expect-cmd nil))))
                (setq out (etaf-ui-markdown-highlight--push-run
                           out (substring txt i next)
                           (when role (list :role role))))
                (setq i next)))))))
    (nreverse out)))

(defvar-local etaf-ui-markdown-highlight--last-text nil
  "Last source text fontified in this scratch highlight buffer.")

(defun etaf-ui-markdown-highlight--line-prefix (old new)
  "Return the line-start index of the first difference between OLD and NEW."
  (let* ((common (min (length old) (length new)))
         (cmp (compare-strings old 0 common new 0 common))
         (diff (if (eq cmp t) common (1- (abs cmp)))))
    (if (<= diff 0)
        0
      (let ((nl (cl-position ?\n new :from-end t :end diff)))
        (if nl (1+ nl) 0)))))

(defun etaf-ui-markdown-highlight--compute (language text)
  "Return the highlighted runs of TEXT as LANGUAGE, or nil."
  (let* ((lang (and (stringp language) (downcase language)))
         (mode (and lang (etaf-ui-markdown-highlight--mode lang)))
         (buf (and mode (etaf-ui-markdown-highlight--buffer mode)))
         (runs
          (cond
           (buf
            ;; A mode may announce what it set up, as `sh-mode' does when it
            ;; picks the shell's indentation; the reader asked for a page, not
            ;; for that log.
            (let ((inhibit-message t)
                  (message-log-max nil))
              (with-current-buffer buf
                (let* ((inhibit-read-only t)
                       (last etaf-ui-markdown-highlight--last-text)
                       (prefix (if (and (stringp last)
                                        (= (1- (point-max)) (length last)))
                                   (etaf-ui-markdown-highlight--line-prefix last text)
                                 0)))
                  (if (> prefix 0)
                      (let ((edit-pos (1+ prefix)))
                        (delete-region edit-pos (point-max))
                        (goto-char edit-pos)
                        (insert (substring text prefix))
                        (when (fboundp 'syntax-ppss-flush-cache)
                          (syntax-ppss-flush-cache edit-pos))
                        (condition-case nil
                            (let* ((ppss (and (fboundp 'syntax-ppss)
                                              (syntax-ppss edit-pos)))
                                   (start (if (and ppss (or (nth 3 ppss) (nth 4 ppss))
                                                   (integerp (nth 8 ppss)))
                                              (nth 8 ppss)
                                            edit-pos)))
                              (font-lock-ensure start (point-max))
                              (setq etaf-ui-markdown-highlight--last-text text)
                              (etaf-ui-markdown-highlight--runs (buffer-string)))
                          (error
                           (setq etaf-ui-markdown-highlight--last-text nil)
                           nil)))
                    (erase-buffer)
                    (insert text)
                    (when (fboundp 'syntax-ppss-flush-cache)
                      (syntax-ppss-flush-cache (point-min)))
                    (condition-case nil
                        (progn
                          (font-lock-ensure)
                          (setq etaf-ui-markdown-highlight--last-text text)
                          (etaf-ui-markdown-highlight--runs (buffer-string)))
                      (error
                       (setq etaf-ui-markdown-highlight--last-text nil)
                       nil)))))))
           ((when-let* ((spec (cdr (assoc lang etaf-ui-markdown-highlight--lex-specs))))
              (etaf-ui-markdown-highlight--lex spec text))))))
    (if (and runs (member lang etaf-ui-markdown-highlight--shell-langs))
        (etaf-ui-markdown-highlight--enhance-shell runs)
      runs)))

(provide 'etaf-ui-markdown-highlight)

;;; etaf-ui-markdown-highlight.el ends here
