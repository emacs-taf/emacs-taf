;;; etaf-manual-book.el --- Book model of the ETAF Reference Manual -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Internal reader for the book sources below book/.  The format is described
;; in docs/manual.md: book/book.json orders parts, chapters and appendices;
;; each chapter is one Markdown file per language.  This module turns those
;; files into plists: headings become nodes, `#### Kind: name signature'
;; headings become definition entries and `elisp :run' fences become
;; runnable examples.  The public shapes are documented in etaf-manual.el.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(define-error 'etaf-manual-error "ETAF manual error")

(defconst etaf-manual--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the etaf-manual checkout or installed package.")

(defconst etaf-manual--definition-kinds
  '(("Function" . function) ("Macro" . macro) ("Variable" . variable)
    ("Hook" . hook) ("Error" . error) ("Component" . component)
    ("Host" . host) ("Property" . property) ("Style" . style)
    ("Token" . token) ("Syntax" . syntax))
  "Definition heading labels and the kind symbols they denote.")

(defconst etaf-manual--definition-regexp
  (concat "\\`\\(" (regexp-opt (mapcar #'car etaf-manual--definition-kinds))
          "\\): \\([^ \t\n]+\\)\\(?:[ \t]+\\(.*?\\)\\)?[ \t]*\\'")
  "Match the text of a definition heading: KIND, NAME and SIGNATURE.")

(defvar etaf-manual--cache (make-hash-table :test #'equal)
  "Parsed books keyed by (DIRECTORY . LANGUAGE), validated by file times.")

;;;; Text helpers

(defun etaf-manual--slug (text)
  "Return the GitHub-compatible heading anchor of TEXT.
Inline links contribute their text; letters, numbers, marks, hyphens and
underscores are kept, spaces become hyphens and everything else is dropped."
  (let ((plain (replace-regexp-in-string
                "\\[\\([^]]*\\)\\]([^)]*)" "\\1" text)))
    (apply #'string
           (cl-loop for char across (downcase plain)
                    for category = (get-char-code-property char 'general-category)
                    if (eq char ?\s) collect ?-
                    else if (or (memq char '(?- ?_))
                                (memq (aref (symbol-name category) 0) '(?L ?N ?M)))
                    collect char))))

(defun etaf-manual--unique-anchor (slug seen)
  "Return SLUG made unique against hash table SEEN, recording it."
  (let ((count (gethash slug seen)))
    (puthash slug (1+ (or count -1)) seen)
    (if count (format "%s-%d" slug (1+ count)) slug)))

(defun etaf-manual--inline-code (line)
  "Return the contents of single-line inline code spans in LINE."
  (let ((start 0) spans)
    (while (string-match "\\(`+\\)\\(.+?\\)\\1" line start)
      ;; `string-trim' runs its own regexp matches, so capture the outer
      ;; match before trimming or `match-end' would describe the wrong match.
      (let ((span (match-string 2 line))
            (end (match-end 0)))
        (push (string-trim span) spans)
        (setq start end)))
    (nreverse spans)))

(defun etaf-manual--links (line)
  "Return Markdown link targets in LINE outside inline code."
  (let ((text (replace-regexp-in-string "\\(`+\\).+?\\1" "" line))
        (start 0) targets)
    (while (string-match "\\](\\([^) \t]+\\)\\(?:[ \t]+\"[^\"]*\"\\)?)" text start)
      (push (match-string 1 text) targets)
      (setq start (match-end 0)))
    (nreverse targets)))

;;;; Chapters

(defun etaf-manual--finish-definition-body (group body-lines)
  "Attach the joined BODY-LINES to every definition plist in GROUP."
  (let ((body (string-trim (string-join (nreverse body-lines) "\n"))))
    (when (and group (not (string-empty-p body)))
      (dolist (definition group)
        (plist-put definition :body body)))))

(defun etaf-manual--parse-chapter-text (text id label)
  "Parse chapter TEXT with identifier ID, reporting problems at LABEL.
TEXT is the Markdown source itself, so generated appendices and written
chapters share one parser."
  (let ((seen (make-hash-table :test #'equal))
        (line-number 0) fence title nodes definitions examples figures links code
        index fence-kind fence-start fence-caption fence-lines section-anchor group body-lines)
    (dolist (line (split-string text "\n"))
      (cl-incf line-number)
      (cond
       ;; Inside a fence: collect its text until the closing fence.
       (fence
        (when group (push line body-lines))
        (if (string-match-p (concat "\\`[ ]\\{0,3\\}" (regexp-quote fence) "[`~]*[ \t]*\\'") line)
            (progn
              (when fence-start
                (push (append
                       (list :id (if (eq fence-kind 'figure)
                                     (format "%s-figure-%d" id (1+ (length figures)))
                                   (format "%s-%d" id (1+ (length examples))))
                             :chapter id :line fence-start)
                       (when (eq fence-kind 'figure)
                         (list :caption fence-caption))
                       (list :code (string-join (nreverse fence-lines) "\n")))
                      (if (eq fence-kind 'figure) figures examples)))
              (setq fence nil fence-kind nil fence-start nil
                    fence-caption nil fence-lines nil))
          (when fence-start (push line fence-lines))))
       ((string-match "\\`[ ]\\{0,3\\}\\(```+\\|~~~+\\)[ \t]*\\(.*\\)\\'" line)
        (when group (push line body-lines))
        (setq fence (match-string 1 line))
        (let ((info (match-string 2 line)))
          (cond
           ((string-match "\\`elisp[ \t]+:run\\b" info)
            (setq fence-kind 'run fence-start line-number))
           ((string-match "\\`elisp[ \t]+:figure\\b\\(?:[ \t]+\\(.*\\)\\)?\\'" info)
            (setq fence-kind 'figure fence-start line-number
                  fence-caption (match-string 1 info))))))
       ((string-match "\\`\\(#\\{1,6\\}\\)[ \t]+\\(.*?\\)[ \t]*#*[ \t]*\\'" line)
        (let* ((level (length (match-string 1 line)))
               (heading (match-string 2 line))
               (anchor (etaf-manual--unique-anchor (etaf-manual--slug heading) seen)))
          (cond
           ((= level 4)
            (unless (string-match etaf-manual--definition-regexp heading)
              (signal 'etaf-manual-error
                      (list "Level-4 headings are definition entries" label line-number)))
            (let ((definition (list :kind (cdr (assoc (match-string 1 heading)
                                                      etaf-manual--definition-kinds))
                                    :name (intern (match-string 2 heading))
                                    :signature (or (match-string 3 heading) "")
                                    :anchor anchor :line line-number :chapter id
                                    :body nil)))
              (push definition definitions)
              ;; Consecutive headings share the description that follows them.
              (if (and group (string-empty-p (string-join body-lines "")))
                  (setq group (cons definition group))
                (etaf-manual--finish-definition-body group body-lines)
                (setq group (list definition) body-lines nil))))
           (t
            (etaf-manual--finish-definition-body group body-lines)
            (setq group nil body-lines nil)
            (when (> level 4)
              (signal 'etaf-manual-error
                      (list "Headings deeper than level 4" label line-number)))
            (if (= level 1)
                (if title
                    (signal 'etaf-manual-error
                            (list "Chapter has several titles" label line-number))
                  (setq title heading))
              (push (list :level level :title heading :anchor anchor :line line-number)
                    nodes))
            (setq section-anchor anchor)))
          (dolist (target (etaf-manual--links heading))
            (push (cons line-number target) links))))
       (t
        (when group (push line body-lines))
        (when (string-match "\\`<!--[ \t]*index:[ \t]*\\(.*?\\)[ \t]*-->\\'" line)
          (dolist (term (split-string (match-string 1 line) ";" t "[ \t]+"))
            (push (list :term term :line line-number :anchor section-anchor) index)))
        (dolist (target (etaf-manual--links line))
          (push (cons line-number target) links))
        (dolist (span (etaf-manual--inline-code line))
          (push (cons line-number span) code)))))
    (etaf-manual--finish-definition-body group body-lines)
    (when fence
      (signal 'etaf-manual-error (list "Unclosed code fence" label)))
    (unless title
      (signal 'etaf-manual-error (list "Chapter needs a level-1 title" label)))
    (list :title title :nodes (nreverse nodes)
          :definitions (nreverse definitions) :examples (nreverse examples)
          :figures (nreverse figures)
          :links (nreverse links) :code (nreverse code) :index (nreverse index))))

(defun etaf-manual--parse-chapter (file id)
  "Parse chapter FILE with identifier ID into a chapter plist."
  (let ((text (with-temp-buffer
                (insert-file-contents file)
                (buffer-string))))
    (append (list :file file)
            (etaf-manual--parse-chapter-text text id file))))

;;;; Books

(defun etaf-manual--roman (number)
  "Return NUMBER as an uppercase Roman numeral."
  (let ((result "") (rest number))
    (pcase-dolist (`(,value . ,glyph)
                   '((1000 . "M") (900 . "CM") (500 . "D") (400 . "CD")
                     (100 . "C") (90 . "XC") (50 . "L") (40 . "XL")
                     (10 . "X") (9 . "IX") (5 . "V") (4 . "IV") (1 . "I")))
      (while (>= rest value)
        (setq result (concat result glyph) rest (- rest value))))
    result))

(defun etaf-manual--read-json (file)
  "Read FILE as JSON with plist objects and list arrays."
  (condition-case error
      (json-parse-string
       (with-temp-buffer (insert-file-contents file) (buffer-string))
       :object-type 'plist :array-type 'list :null-object nil :false-object nil)
    (file-missing (signal 'etaf-manual-error (list "Missing book description" file)))
    (json-error (signal 'etaf-manual-error (list "Invalid book description" file error)))))

(defun etaf-manual--localized (value language)
  "Return LANGUAGE's string from title plist VALUE."
  (or (plist-get value (intern (concat ":" language)))
      (plist-get value :en)))

(defun etaf-manual--book-files (directory language description)
  "Return the chapter files DESCRIPTION reads in LANGUAGE below DIRECTORY."
  (let (files)
    (dolist (part (plist-get description :parts))
      (dolist (chapter (plist-get part :chapters))
        (push (expand-file-name (format "%s/%s.md" language chapter) directory) files)))
    (dolist (appendix (plist-get description :appendices))
      (unless (plist-get appendix :generate)
        (push (expand-file-name (format "%s/%s.md" language (plist-get appendix :id))
                                directory)
              files)))
    (nreverse files)))

(defun etaf-manual--stamp (files)
  "Return modification times of FILES, nil for missing files."
  (mapcar (lambda (file) (file-attribute-modification-time (file-attributes file)))
          files))

(defconst etaf-manual--revalidate-seconds 1.0
  "Longest time a validated book is reused without checking its sources.")

(defun etaf-manual--fresh-p (entry)
  "Return non-nil when cache ENTRY was validated during the current input.
Within one input event and `etaf-manual--revalidate-seconds' the sources
cannot have changed under the reader, so the many lookups of one redisplay
or command share a single check."
  (and entry
       (eql (nth 2 entry) num-nonmacro-input-events)
       (< (- (float-time) (nth 3 entry)) etaf-manual--revalidate-seconds)))

(defun etaf-manual--read-book (directory language)
  "Parse the book below DIRECTORY in LANGUAGE, reusing an unchanged result."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (key (cons directory language))
         (cached (gethash key etaf-manual--cache)))
    (if (etaf-manual--fresh-p cached)
        (cadr cached)
      (let* ((description (etaf-manual--read-json
                           (expand-file-name "book.json" directory)))
             (languages (plist-get description :languages)))
        (unless (member language languages)
          (signal 'etaf-manual-error
                  (list "Unsupported manual language" language languages)))
        (let* ((files (cons (expand-file-name "book.json" directory)
                            (etaf-manual--book-files directory language description)))
               (stamp (etaf-manual--stamp files))
               (book (if (and cached (equal (car cached) stamp))
                         (cadr cached)
                       (etaf-manual--build-book directory language description))))
          (puthash key (list stamp book num-nonmacro-input-events (float-time))
                   etaf-manual--cache)
          book)))))

(declare-function etaf-manual-generate "etaf-manual-generate" (name language title chapters))

(defun etaf-manual--generate (name language title chapters)
  "Return the Markdown of generated NAME in LANGUAGE with TITLE."
  (require 'etaf-manual-generate)
  (etaf-manual-generate name language title chapters))

(defun etaf-manual--resolve-generated (chapter language sources)
  "Return CHAPTER with its generated Markdown content parsed into it.
CHAPTER's :generate names the generator; SOURCES are the parsed chapters
the generator reads."
  (let* ((name (plist-get chapter :generate))
         (content (etaf-manual--generate name language (plist-get chapter :title) sources))
         (parsed (etaf-manual--parse-chapter-text
                  content (plist-get chapter :id)
                  (format "<generated:%s>" name))))
    (cl-remf parsed :title)
    (append chapter (list :content content) parsed)))

(defun etaf-manual--build-book (directory language description)
  "Build LANGUAGE's book plist from DESCRIPTION below DIRECTORY."
  (let ((chapter-number 0) (part-number 0) (appendix-number 0) parts chapters appendices)
    (dolist (part (plist-get description :parts))
      (let ((part-id (intern (plist-get part :id))) ids)
        (dolist (slug (plist-get part :chapters))
          (let* ((id (intern slug))
                 (file (expand-file-name (format "%s/%s.md" language slug) directory)))
            (unless (file-exists-p file)
              (signal 'etaf-manual-error (list "Missing chapter" file)))
            (push id ids)
            (push (append (list :id id :kind 'chapter :number (cl-incf chapter-number)
                                :part part-id)
                          (etaf-manual--parse-chapter file id))
                  chapters)))
        (push (list :id part-id :number (etaf-manual--roman (cl-incf part-number))
                    :title (etaf-manual--localized (plist-get part :title) language)
                    :chapters (nreverse ids))
              parts)))
    ;; Written appendices parse now; generated ones are resolved below, once
    ;; every written chapter is available.
    (dolist (appendix (plist-get description :appendices))
      (let* ((id (intern (plist-get appendix :id)))
             (generate (plist-get appendix :generate))
             (number (string (+ ?A appendix-number))))
        (cl-incf appendix-number)
        (push (if generate
                  (list :id id :kind 'appendix :number number
                        :generate (intern generate)
                        :title (etaf-manual--localized (plist-get appendix :title) language))
                (append (list :id id :kind 'appendix :number number)
                        (etaf-manual--parse-chapter
                         (expand-file-name (format "%s/%s.md" language id) directory)
                         id)))
              appendices)))
    (let* ((chapter-list (nreverse chapters))
           (appendix-list (nreverse appendices))
           (written (append chapter-list
                            (cl-remove-if (lambda (chapter)
                                            (plist-get chapter :generate))
                                          appendix-list)))
           (resolved (mapcar (lambda (appendix)
                               (if (plist-get appendix :generate)
                                   (etaf-manual--resolve-generated appendix language written)
                                 appendix))
                             appendix-list))
           (indices (mapcar (lambda (spec)
                              (etaf-manual--resolve-generated
                               (list :id (intern (plist-get spec :id))
                                     :kind 'index
                                     :generate (intern (plist-get spec :generate))
                                     :title (etaf-manual--localized
                                             (plist-get spec :title) language))
                               language
                               (append written resolved)))
                            (plist-get description :indices))))
      (list :language language :directory directory
            :title (etaf-manual--localized (plist-get description :title) language)
            :packages (plist-get description :packages)
            :references (plist-get description :references)
            :coverage (plist-get description :coverage)
            :languages (plist-get description :languages)
            :parts (nreverse parts)
            :chapters (append chapter-list resolved indices)))))

(provide 'etaf-manual-book)
;;; etaf-manual-book.el ends here
