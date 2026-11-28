;;; etaf-manual-generate.el --- Generated appendices of the ETAF manual -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Internal generators behind the appendices and indexes that book.json
;; marks with `generate'.  Each returns Markdown built from the parsed
;; chapters, so the reader and the book gate treat the result exactly like a
;; written chapter: the book model parses it with the same chapter parser and
;; keeps it in the generated chapter's :content.  The public book shapes are
;; documented in etaf-manual.el.  This module is loaded on demand by the book
;; model, not from consumer code.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-manual-book)

;;;; Strings

(defconst etaf-manual-generate--strings
  '((token-lead
     "Every Theme token the official Component catalog reads, grouped by the chapter that defines it. The entry behind each name gives the token's role, fallback and consuming Components."
     . "官方组件目录读取的全部主题 token，按定义它们的章分组。每个名字背后的条目给出 token 的角色、回退值与消费它的组件。")
    (token-name "Token" . "token")
    (token-purpose "Purpose" . "用途")
    (style-lead
     "Every style property with its value syntax, initial value, what it applies to, whether it is inherited and whether it affects paint or geometry, grouped by the chapter that defines it. The entry gives the full semantics and examples."
     . "全部样式属性及其值语法、初值、适用对象、是否继承、影响绘制还是几何，按定义它们的章分组。完整语义与示例见对应条目。")
    (style-property "Property" . "属性")
    (style-value "Value" . "值")
    (style-initial "Initial" . "初值")
    (style-applies "Applies to" . "适用")
    (style-inherited "Inherited" . "继承")
    (style-impact "Impact" . "影响")
    (host-lead
     "The Host kinds ETAF defines and the semantic and event properties a Host accepts. Each name links to the entry, which gives the accepted values and behavior."
     . "ETAF 定义的 Host 种类，以及 Host 接受的语义与事件属性。每个名字链接到条目，条目给出取值与行为。")
    (host-hosts "Hosts" . "Hosts")
    (host-name "Host" . "Host")
    (host-properties "Semantic Properties" . "语义属性")
    (host-property "Property" . "属性")
    (host-purpose "Purpose" . "用途")
    (component-lead
     "Every component in the catalog with the arguments its entry declares, grouped by the chapter that defines it. The entry gives the presentation, slots, events and Theme tokens."
     . "目录中的全部组件及其条目声明的参数，按定义它们的章分组。条目给出表现、slot、事件与所用主题 token。")
    (component-name "Component" . "组件")
    (component-signature "Signature" . "签名")
    (concept-lead
     "Concepts, properties and mechanisms named by the chapters, with the sections that discuss them, grouped by initial letter; terms that start with a symbol come first."
     . "各章命名的概念、属性与机制，以及讨论它们的节。词条按首字母分组，中文词条按首字的拼音归入同一字母序列，符号开头的词条排在最前。")
    (concept-symbols "Symbols" . "符号")
    (symbol-lead
     "Every documented function, macro, variable, hook, error, component, semantic property, style property and Theme token. Functions, macros, variables, hooks and errors are grouped by the package their prefix names, components and the other entries by kind, and each group is alphabetical. The entry behind each name gives its contract."
     . "全部有记录的 function、宏、变量、钩子、错误、组件、语义属性、样式属性与主题 token。function、宏、变量、钩子与错误按名字前缀所属的包分组，组件与其余条目按种类分组，组内按字母序。每个名字链接到给出契约的条目。")
    (symbol-component "Components" . "组件")
    (symbol-property "Semantic Properties" . "语义属性")
    (symbol-style "Style Properties" . "样式属性")
    (symbol-token "Theme Tokens" . "主题 token"))
  "Localized strings of the generated appendices.")

(defconst etaf-manual-generate--symbol-kinds
  '(function macro variable hook error component property style token)
  "Definition kinds the symbol index lists, in tie-breaking order.")

;;;; Helpers

(defun etaf-manual-generate--string (key language)
  "Return the localized string KEY for LANGUAGE."
  (let ((pair (alist-get key etaf-manual-generate--strings)))
    (if (equal language "zh-CN") (cdr pair) (car pair))))

(defun etaf-manual-generate--definitions (chapters kind)
  "Return every definition of KIND in CHAPTERS in reading order."
  (cl-loop for chapter in chapters
           append (cl-loop for definition in (plist-get chapter :definitions)
                           when (eq (plist-get definition :kind) kind)
                           collect definition)))

(defun etaf-manual-generate--by-chapter (chapters kind)
  "Return ((CHAPTER . DEFINITIONS) ...) for every chapter defining KIND."
  (cl-loop for chapter in chapters
           for definitions = (cl-loop for definition in (plist-get chapter :definitions)
                                      when (eq (plist-get definition :kind) kind)
                                      collect definition)
           when definitions collect (cons chapter definitions)))

(defun etaf-manual-generate--rebase-links (text chapter)
  "Rewrite bare fragment links in TEXT to point at CHAPTER.
A link such as `[x](#anchor)' is valid in the chapter an entry is written
in; the generated appendix that copies the text is another file."
  (if (stringp text)
      (replace-regexp-in-string "](#" (format "](%s.md#" chapter) text t t)
    text))

(defun etaf-manual-generate--summary (definition)
  "Return the one-line summary of DEFINITION, or nil.
The summary is the first paragraph of the entry body; a leading value table
is skipped."
  (let ((lines (split-string (or (plist-get definition :body) "") "\n")))
    (while (and lines (string-empty-p (string-trim (car lines))))
      (setq lines (cdr lines)))
    (while (and lines (string-match-p "\\`[ \t]*|" (car lines)))
      (setq lines (cdr lines))
      (while (and lines (string-empty-p (string-trim (car lines))))
        (setq lines (cdr lines))))
    (let ((line (and lines (string-trim (car lines)))))
      (unless (or (null line) (string-empty-p line) (string-prefix-p "```" line))
        (etaf-manual-generate--rebase-links line (plist-get definition :chapter))))))

(defun etaf-manual-generate--first-table (definition)
  "Return the data rows of the first table in DEFINITION's body as cell lists."
  (let ((lines (split-string (or (plist-get definition :body) "") "\n")) rows)
    (while (and lines (not (string-match-p "\\`[ \t]*|" (car lines))))
      (setq lines (cdr lines)))
    (while (and lines (string-match-p "\\`[ \t]*|" (car lines)))
      (let ((line (string-trim (car lines))))
        (unless (string-match-p "\\`|[- |:]+\\'" line)
          (push (mapcar #'string-trim (butlast (cdr (split-string line "|")))) rows)))
      (setq lines (cdr lines)))
    (nreverse rows)))

(defun etaf-manual-generate--target (definition)
  "Return the link target of DEFINITION's entry."
  (format "%s.md#%s" (plist-get definition :chapter) (plist-get definition :anchor)))

(defun etaf-manual-generate--link (text definition)
  "Return a Markdown link showing TEXT to DEFINITION's entry."
  (format "[%s](%s)" text (etaf-manual-generate--target definition)))

(defun etaf-manual-generate--code (name)
  "Return NAME as an inline code span."
  (format "`%s`" name))

(defun etaf-manual-generate--cell (text)
  "Return TEXT escaped for a Markdown table cell."
  (replace-regexp-in-string "|" "\\\\|" (or text "")))

(defun etaf-manual-generate--row (cells)
  "Return CELLS as a Markdown table row."
  (concat "| " (mapconcat #'etaf-manual-generate--cell cells " | ") " |"))

(defun etaf-manual-generate--table (header rows)
  "Return a Markdown table with HEADER cells and ROWS of strings."
  (string-join
   (append (list (etaf-manual-generate--row header)
                 (concat "| " (mapconcat (lambda (_cell) "---") header " | ") " |"))
           rows)
   "\n"))

(defun etaf-manual-generate--section (heading body)
  "Return a level-2 section with HEADING and BODY."
  (concat "## " heading "\n\n" body))

(defun etaf-manual-generate--document (title lead sections)
  "Return a generated Markdown document with TITLE, LEAD and SECTIONS."
  (string-join (append (list (concat "# " title) lead) sections) "\n\n"))

;;;; Generators

(defun etaf-manual-generate--token-table (language title chapters)
  "Return the Theme token table appendix in LANGUAGE."
  (let (sections)
    (dolist (group (etaf-manual-generate--by-chapter chapters 'token))
      (push (etaf-manual-generate--section
             (plist-get (car group) :title)
             (etaf-manual-generate--table
              (list (etaf-manual-generate--string 'token-name language)
                    (etaf-manual-generate--string 'token-purpose language))
              (cl-loop for definition in (cdr group)
                       collect (etaf-manual-generate--row
                                (list (etaf-manual-generate--link
                                       (etaf-manual-generate--code (plist-get definition :name))
                                       definition)
                                      (or (etaf-manual-generate--summary definition) "—"))))))
            sections))
    (etaf-manual-generate--document
     title (etaf-manual-generate--string 'token-lead language)
     (nreverse sections))))

(defun etaf-manual-generate--style-quick-reference (language title chapters)
  "Return the style property quick reference appendix in LANGUAGE."
  (let (sections)
    (dolist (group (etaf-manual-generate--by-chapter chapters 'style))
      (push (etaf-manual-generate--section
             (plist-get (car group) :title)
             (etaf-manual-generate--table
              (mapcar (lambda (key) (etaf-manual-generate--string key language))
                      '(style-property style-value style-initial style-applies
                        style-inherited style-impact))
              (cl-loop for definition in (cdr group)
                       for data = (cdr (etaf-manual-generate--first-table definition))
                       collect (etaf-manual-generate--row
                                (cons (etaf-manual-generate--link
                                       (etaf-manual-generate--code (plist-get definition :name))
                                       definition)
                                      (cl-loop for index from 0 below 5
                                               for cell = (nth index (car data))
                                               collect (if (and cell (not (string-empty-p cell)))
                                                           (etaf-manual-generate--rebase-links
                                                            cell (plist-get definition :chapter))
                                                         "—")))))))
            sections))
    (etaf-manual-generate--document
     title (etaf-manual-generate--string 'style-lead language)
     (nreverse sections))))

(defun etaf-manual-generate--host-and-property-quick-reference (language title chapters)
  "Return the Host and semantic property quick reference in LANGUAGE."
  (let ((hosts (etaf-manual-generate--definitions chapters 'host))
        (properties (etaf-manual-generate--definitions chapters 'property)))
    (etaf-manual-generate--document
     title (etaf-manual-generate--string 'host-lead language)
     (list
      (etaf-manual-generate--section
       (etaf-manual-generate--string 'host-hosts language)
       (etaf-manual-generate--table
        (list (etaf-manual-generate--string 'host-name language)
              (etaf-manual-generate--string 'host-purpose language))
        (cl-loop for definition in hosts
                 collect (etaf-manual-generate--row
                          (list (etaf-manual-generate--link
                                 (etaf-manual-generate--code (plist-get definition :name))
                                 definition)
                                (or (etaf-manual-generate--summary definition) "—"))))))
      (etaf-manual-generate--section
       (etaf-manual-generate--string 'host-properties language)
       (etaf-manual-generate--table
        (list (etaf-manual-generate--string 'host-property language)
              (etaf-manual-generate--string 'host-purpose language))
        (cl-loop for definition in properties
                 collect (etaf-manual-generate--row
                          (list (etaf-manual-generate--link
                                 (etaf-manual-generate--code (plist-get definition :name))
                                 definition)
                                (or (etaf-manual-generate--summary definition) "—"))))))))))

(defun etaf-manual-generate--component-quick-reference (language title chapters)
  "Return the component quick reference appendix in LANGUAGE."
  (let (sections)
    (dolist (group (etaf-manual-generate--by-chapter chapters 'component))
      (push (etaf-manual-generate--section
             (plist-get (car group) :title)
             (etaf-manual-generate--table
              (list (etaf-manual-generate--string 'component-name language)
                    (etaf-manual-generate--string 'component-signature language))
              (cl-loop for definition in (cdr group)
                       for signature = (plist-get definition :signature)
                       collect (etaf-manual-generate--row
                                (list (etaf-manual-generate--link
                                       (etaf-manual-generate--code (plist-get definition :name))
                                       definition)
                                      (if (string-empty-p signature)
                                          "—"
                                        (etaf-manual-generate--code signature)))))))
            sections))
    (etaf-manual-generate--document
     title (etaf-manual-generate--string 'component-lead language)
     (nreverse sections))))

(defvar jka-compr-verbose)

(defvar etaf-manual-generate--pinyin nil
  "Hash table from Han characters to their first Pinyin syllable, or `none'.")

(defun etaf-manual-generate--pinyin (char)
  "Return CHAR's first Pinyin syllable, or nil.
The syllables come from the Pinyin rules of Emacs's own `chinese-py' input
method, read once; an Emacs without them groups Han terms together."
  (unless etaf-manual-generate--pinyin
    (setq etaf-manual-generate--pinyin
          (let ((file (locate-library "quail/PY.el" t)))
            (if (not file)
                'none
              (let ((table (make-hash-table :test #'eq)) rules)
                (with-temp-buffer
                  (let ((jka-compr-verbose nil))
                    (insert-file-contents file))
                  (goto-char (point-min))
                  (when (search-forward "(quail-define-rules" nil t)
                    (goto-char (match-beginning 0))
                    (setq rules (cdr (read (current-buffer))))))
                (dolist (rule rules)
                  (when (and (stringp (car-safe rule)) (stringp (cadr rule)))
                    (mapc (lambda (han)
                            (unless (gethash han table)
                              (puthash han (car rule) table)))
                          (cadr rule))))
                table)))))
  (and (hash-table-p etaf-manual-generate--pinyin)
       (gethash char etaf-manual-generate--pinyin)))

(defun etaf-manual-generate--sort-key (term)
  "Return TERM's index sort key: its text, a Han initial spelled in Pinyin."
  (let ((syllable (etaf-manual-generate--pinyin (aref term 0))))
    (downcase (if syllable (concat syllable " " term) term))))

(defun etaf-manual-generate--initial (term)
  "Return TERM's index group letter, or nil for a term led by a symbol."
  (let* ((key (etaf-manual-generate--sort-key term))
         (char (aref key 0)))
    (and (<= ?a char ?z) (string (upcase char)))))

(defun etaf-manual-generate--groups (items key-function group-function)
  "Group ITEMS sorted by KEY-FUNCTION under GROUP-FUNCTION's labels.
Return ((LABEL . ITEMS) ...) in order of first appearance."
  (let ((sorted (sort (mapcar (lambda (item)
                                (cons (funcall key-function item) item))
                              items)
                      (lambda (first second)
                        (string< (car first) (car second)))))
        groups)
    (dolist (pair sorted)
      (let* ((item (cdr pair))
             (label (funcall group-function item))
             (group (assoc label groups)))
        (if group
            (push item (cdr group))
          (push (list label item) groups))))
    (mapcar (lambda (group) (cons (car group) (nreverse (cdr group))))
            (nreverse groups))))

(defun etaf-manual-generate--concept-index (language title chapters)
  "Return the concept index in LANGUAGE from the chapters' index markers.
Terms are grouped by initial letter; Han terms join the letter of their
first character's Pinyin, and terms led by a symbol form the first group."
  (let ((terms (make-hash-table :test #'equal)))
    (dolist (chapter chapters)
      (let* ((id (plist-get chapter :id))
             (titles (make-hash-table :test #'equal)))
        (puthash (etaf-manual--slug (plist-get chapter :title))
                 (plist-get chapter :title) titles)
        (dolist (node (plist-get chapter :nodes))
          (puthash (plist-get node :anchor) (plist-get node :title) titles))
        (dolist (record (plist-get chapter :index))
          (let* ((term (plist-get record :term))
                 (anchor (or (plist-get record :anchor)
                             (etaf-manual--slug (plist-get chapter :title))))
                 (target (format "%s.md#%s" id anchor))
                 (label (or (gethash anchor titles) (plist-get chapter :title)))
                 (entry (format "[%s](%s)" label target))
                 (existing (gethash term terms)))
            (unless (member entry existing)
              (puthash term (append existing (list entry)) terms))))))
    (let* ((symbols (etaf-manual-generate--string 'concept-symbols language))
           (groups (etaf-manual-generate--groups
                    (hash-table-keys terms)
                    (lambda (term)
                      (let ((key (etaf-manual-generate--sort-key term)))
                        ;; Symbol-led terms sort before every letter.
                        (concat (if (etaf-manual-generate--initial term) "1" "0")
                                key)))
                    (lambda (term)
                      (or (etaf-manual-generate--initial term) symbols)))))
      (etaf-manual-generate--document
       title (etaf-manual-generate--string 'concept-lead language)
       (mapcar (lambda (group)
                 (etaf-manual-generate--section
                  (car group)
                  (mapconcat (lambda (term)
                               (format "- **%s** — %s" term
                                       (mapconcat #'identity
                                                  (gethash term terms) "; ")))
                             (cdr group) "\n")))
               groups)))))

(defconst etaf-manual-generate--symbol-packages
  '("ecss" "ekp" "ebox" "etaf-ui" "etaf-db" "etaf")
  "Package prefixes that group the symbol index, longer prefixes first.")

(defun etaf-manual-generate--symbol-group (name kind language)
  "Return the symbol index group of NAME of KIND in LANGUAGE.
A prefixed Lisp symbol belongs to its package; a component, whose name does
not tell its providing package, and the other entries belong to their kind."
  (or (and (memq kind '(function macro variable hook error))
           (cl-find-if (lambda (package)
                         (string-prefix-p (concat package "-") name))
                       etaf-manual-generate--symbol-packages))
      (etaf-manual-generate--string
       (pcase kind
         ('component 'symbol-component)
         ('property 'symbol-property)
         ('style 'symbol-style)
         (_ 'symbol-token))
       language)))

(defun etaf-manual-generate--symbol-index (language title chapters)
  "Return the symbol index in LANGUAGE for the named definitions in CHAPTERS.
Groups follow the manual's package order, then the component, property,
style and token kinds; each group is alphabetical."
  (let (rows)
    (dolist (kind etaf-manual-generate--symbol-kinds)
      (dolist (definition (etaf-manual-generate--definitions chapters kind))
        (let ((name (symbol-name (plist-get definition :name))))
          (push (list name kind definition
                      (etaf-manual-generate--symbol-group name kind language))
                rows))))
    (let* ((order (append '("ecss" "ekp" "ebox" "etaf" "etaf-ui" "etaf-db")
                          (mapcar (lambda (key)
                                    (etaf-manual-generate--string key language))
                                  '(symbol-component symbol-property
                                    symbol-style symbol-token))))
           (groups (etaf-manual-generate--groups
                    rows
                    (lambda (row)
                      (format "%02d %s %s"
                              (or (cl-position (nth 3 row) order :test #'equal) 99)
                              (car row)
                              (symbol-name (nth 1 row))))
                    (lambda (row) (nth 3 row)))))
      (etaf-manual-generate--document
       title (etaf-manual-generate--string 'symbol-lead language)
       (mapcar (lambda (group)
                 (etaf-manual-generate--section
                  (car group)
                  (mapconcat (lambda (row)
                               (format "- %s — %s"
                                       (etaf-manual-generate--link
                                        (etaf-manual-generate--code (car row))
                                        (nth 2 row))
                                       (capitalize (symbol-name (nth 1 row)))))
                             (cdr group) "\n")))
               groups)))))

(defun etaf-manual-generate (name language title chapters)
  "Return the Markdown of generated NAME in LANGUAGE with TITLE.
CHAPTERS are the parsed chapters the generator reads."
  (pcase name
    ('token-table (etaf-manual-generate--token-table language title chapters))
    ('style-quick-reference
     (etaf-manual-generate--style-quick-reference language title chapters))
    ('host-and-property-quick-reference
     (etaf-manual-generate--host-and-property-quick-reference language title chapters))
    ('component-quick-reference
     (etaf-manual-generate--component-quick-reference language title chapters))
    ('concept-index (etaf-manual-generate--concept-index language title chapters))
    ('symbol-index (etaf-manual-generate--symbol-index language title chapters))
    (_ (signal 'etaf-manual-error
               (list "Unknown generated content"
                     (format "<generated:%s>" name) nil)))))

(provide 'etaf-manual-generate)
;;; etaf-manual-generate.el ends here
