;;; export-site.el --- Export the book as Starlight content -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Dev tool for the site in `site/'.  It reads the parsed book with the same
;; reader the application uses, writes one Markdown page per chapter and
;; language, and emits the shared sidebar.  Chapter links are rewritten to
;; site routes; `elisp :run' and `elisp :figure' fences become plain code
;; fences with a short label, because a static site cannot mount a view.
;;
;;   emacs -Q --batch -L .. -L ../lisp -l scripts/export-site.el -- --site DIR

;;; Code:

(require 'cl-lib)
(require 'etaf-manual-book)

(defconst export-site--locales
  '(("en" . "en") ("zh-CN" . "zh-cn"))
  "Book language to site locale directory.")

(defconst export-site--ui
  '(("en" . (:runnable "Runnable example"
             :figure "Inline figure"
             :appendices "Appendices"
             :indices "Indices"))
    ("zh-CN" . (:runnable "可运行示例"
                :figure "插图"
                :appendices "附录"
                :indices "索引")))
  "Labels the exporter inserts around special content.")

(defun export-site--ui (language key)
  "Return LANGUAGE's label for KEY."
  (plist-get (cdr (assoc language export-site--ui)) key))

(defun export-site--routes (book)
  "Return BOOK's chapter ids and title anchors as an alist."
  (mapcar (lambda (chapter)
            (cons (symbol-name (plist-get chapter :id))
                  (etaf-manual--slug (or (plist-get chapter :title) ""))))
          (plist-get book :chapters)))

(defun export-site--rewrite-link (link locale routes)
  "Return LINK rewritten to a site route in LOCALE.
LINK is the inside of a Markdown link; ROUTES is the chapter alist.  An
anchor naming the target chapter's title is dropped: the title lives in
the page frontmatter and has no heading of its own."
  (if (string-match "\\`\\([a-z0-9][a-z0-9-]*\\)\\.md\\(#[^)]*\\)?\\'" link)
      (let* ((id (match-string 1 link))
             (anchor (or (match-string 2 link) ""))
             (title (cdr (assoc id routes))))
        (if title
            (format "/%s%s/%s" (if (equal locale "en") "" (concat locale "/"))
                    id (if (equal anchor (concat "#" title)) "" anchor))
          link))
    link))

(defun export-site--rewrite-links (line locale ids)
  "Rewrite chapter links in LINE for LOCALE; IDS are the chapter ids."
  (replace-regexp-in-string
   "\\](\\([a-z0-9][a-z0-9-]*\\.md\\(?:#[^)]*\\)?\\))"
   (lambda (match)
     (save-match-data
       (concat "](" (export-site--rewrite-link (substring match 2 -1) locale ids) ")")))
   line t t))

(defun export-site--fence-label (language info)
  "Return a label line for fence INFO, or nil for an ordinary fence."
  (cond
   ((string-match "\\`[ \t]*elisp[ \t]+:run\\_>" info)
    (format "*%s*" (export-site--ui language :runnable)))
   ((string-match "\\`[ \t]*elisp[ \t]+:figure\\_>\\(?:[ \t]+\\(.*\\)\\)?\\'" info)
    (let ((caption (match-string 1 info)))
      (format "*%s*%s" (export-site--ui language :figure)
              (if (and caption (not (string-empty-p caption)))
                  (format ": %s" caption)
                ""))))
   (t nil)))

(defun export-site--transform (text language locale ids)
  "Return TEXT as site Markdown for LANGUAGE and LOCALE.
The chapter title moves to frontmatter; special fences gain a label and
chapter links become site routes."
  (let ((lines (split-string text "\n"))
        (fence nil)
        (title-seen nil)
        out)
    (dolist (line lines)
      (cond
       ((and (null fence) (string-match "\\`[ ]\\{0,3\\}\\(```+\\|~~~+\\)\\(.*\\)\\'" line))
        (let* ((ticks (match-string 1 line))
               (info (match-string 2 line))
               (label (export-site--fence-label language info)))
          (when label (push label out))
          (push (if label (format "%selisp" ticks) line) out)
          (setq fence ticks)))
       ((and fence (string-match-p
                    (concat "\\`[ ]\\{0,3\\}" (regexp-quote fence) "[`~]*[ \t]*\\'") line))
        (push line out)
        (setq fence nil))
       (fence (push line out))
       ((and (not title-seen) (string-match-p "\\`# [^#]" line))
        (setq title-seen t))
       (t (push (export-site--rewrite-links line locale ids) out))))
    (let ((body (string-join (nreverse out) "\n")))
      (string-trim body))))

(defun export-site--chapter-title (chapter)
  "Return CHAPTER's title for frontmatter."
  (let ((title (or (plist-get chapter :title) "")))
    (replace-regexp-in-string "\"" "\\\\\"" title t t)))

(defun export-site--chapter-text (chapter)
  "Return CHAPTER's Markdown source."
  (if-let* ((content (plist-get chapter :content)))
      content
    (with-temp-buffer
      (insert-file-contents (plist-get chapter :file))
      (buffer-string))))

(defun export-site--write (file text)
  "Write TEXT to FILE, creating its directory."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun export-site--page (chapter language locale ids)
  "Return the page text of CHAPTER in LANGUAGE and LOCALE; IDS are chapter ids."
  (format "---\ntitle: \"%s\"\n---\n\n%s\n"
          (export-site--chapter-title chapter)
          (export-site--transform (export-site--chapter-text chapter)
                                  language locale ids)))

(defun export-site--js (value)
  "Return VALUE as a double-quoted JavaScript string."
  (format "\"%s\"" (replace-regexp-in-string
                    "\"" "\\\\\"" (format "%s" value) t t)))

(defun export-site--sidebar (books)
  "Return the sidebar module text built from BOOKS (en . zh-CN)."
  (let* ((en (cdr (assoc "en" books)))
         (zh (cdr (assoc "zh-CN" books)))
         (en-chapters (plist-get en :chapters))
         (zh-chapters (plist-get zh :chapters)))
    (cl-labels
        ((groups
          (en-list zh-list en-label zh-label)
          (format
           "  { label: %s, translations: { 'zh-CN': %s }, items: [\n%s\n  ] }"
           (export-site--js en-label) (export-site--js zh-label)
           (mapconcat
            (lambda (pair)
              (let* ((title (export-site--item-title (car pair)))
                     (zh-title (export-site--item-title (cdr pair))))
                (format "    { label: %s, translations: { 'zh-CN': %s }, slug: '%s' },"
                        (export-site--js title) (export-site--js zh-title)
                        (symbol-name (plist-get (car pair) :id)))))
            (cl-mapcar #'cons en-list zh-list) "\n"))))
      (string-join
       (append
        (cl-loop for en-part in (plist-get en :parts)
                 for zh-part in (plist-get zh :parts)
                 collect
                 (groups (cl-loop for id in (plist-get en-part :chapters)
                                  collect (cl-find id en-chapters
                                                   :key (lambda (c) (plist-get c :id))))
                         (cl-loop for id in (plist-get zh-part :chapters)
                                  collect (cl-find id zh-chapters
                                                   :key (lambda (c) (plist-get c :id))))
                         (plist-get en-part :title)
                         (plist-get zh-part :title)))
        (let ((en-appendix (cl-remove-if-not
                            (lambda (c) (eq (plist-get c :kind) 'appendix)) en-chapters))
              (zh-appendix (cl-remove-if-not
                            (lambda (c) (eq (plist-get c :kind) 'appendix)) zh-chapters)))
          (list (groups en-appendix zh-appendix
                        (export-site--ui "en" :appendices)
                        (export-site--ui "zh-CN" :appendices))))
        (let ((en-index (cl-remove-if-not
                         (lambda (c) (eq (plist-get c :kind) 'index)) en-chapters))
              (zh-index (cl-remove-if-not
                         (lambda (c) (eq (plist-get c :kind) 'index)) zh-chapters)))
          (list (groups en-index zh-index
                        (export-site--ui "en" :indices)
                        (export-site--ui "zh-CN" :indices)))))
       ",\n"))))

(defun export-site--item-title (chapter)
  "Return CHAPTER's sidebar label with its number when it has one."
  (let ((title (format "%s" (or (plist-get chapter :title) "")))
        (number (plist-get chapter :number)))
    (if number (format "%s %s" number title) title)))

(defun export-site--export (site books)
  "Write BOOKS into SITE's Starlight content tree."
  (let ((docs (expand-file-name "src/content/docs" site)))
    (when (file-directory-p docs)
      (delete-directory docs t))
    (dolist (language (list "en" "zh-CN"))
      (let* ((book (cdr (assoc language books)))
             (locale (cdr (assoc language export-site--locales)))
             (ids (export-site--routes book))
             (directory (if (equal locale "en")
                            docs
                          (expand-file-name locale docs))))
        (dolist (chapter (plist-get book :chapters))
          (export-site--write
           (expand-file-name (format "%s.md" (plist-get chapter :id)) directory)
           (export-site--page chapter language locale ids)))))
    (export-site--write
     (expand-file-name "404.md" docs)
     (concat "---\ntitle: Page not found / 未找到页面\n"
             "template: splash\npagefind: false\n---\n\n"
             "This address is not a reference page. "
             "[Install ETAF](/introduction/#installation) or "
             "[browse the manual](/introduction/).\n\n"
             "此地址不是参考页面。请查看[安装说明](/zh-cn/introduction/#安装)"
             "或[参考手册](/zh-cn/introduction/)。\n"))
    (export-site--write
     (expand-file-name "src/sidebar.mjs" site)
     (concat "// Generated by scripts/export-site.el; do not edit.\nexport default [\n"
             (export-site--sidebar books)
             "\n];\n"))))

(defun export-site--arguments ()
  "Parse command line arguments."
  (let ((site (expand-file-name "site" etaf-manual--root))
        (arguments command-line-args-left))
    (setq command-line-args-left nil)
    (while arguments
      (pcase (pop arguments)
        ("--" nil)
        ("--site" (setq site (expand-file-name (pop arguments))))
        (argument (error "Unknown argument: %s" argument))))
    site))

(defvar export-site--no-run nil
  "When non-nil, loading this file only defines functions.")

(unless export-site--no-run
  (let ((site (export-site--arguments)))
    (export-site--export
     site
     (mapcar (lambda (pair)
               (cons (car pair)
                     (etaf-manual--read-book
                      (expand-file-name "book" etaf-manual--root) (car pair))))
             export-site--locales))))

;;; export-site.el ends here
