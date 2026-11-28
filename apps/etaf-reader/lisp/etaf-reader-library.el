;;; etaf-reader-library.el --- Library discovery and import -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Discovery and import are split behind one small parser contract so tests
;; and other frontends can replace the backend:
;;
;;   (list :scan    (lambda (directory) PLIST)      ; :books (...) :failed N
;;         :extract (lambda (path output) PLIST))   ; :out ... :cover ...
;;
;; The default parser calls the `ebook-parse' skill.  Import extracts a book
;; into a per-book cache directory (images and manifest) and writes the
;; chapters into the store; opening a book then never touches the file again.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'etaf)
(require 'etaf-reader-theme)
(require 'etaf-reader-store)

(defcustom etaf-reader-library-directories (list (expand-file-name "~/ebooks"))
  "Directories scanned for local ebooks."
  :type '(repeat directory)
  :group 'etaf-reader)

(defcustom etaf-reader-parser-command nil
  "Command prefix that runs the ebook parser, or nil to discover one.
A value ending in `.py' runs under `python3'; a bare command is executed
directly.  The parser must implement the `ebook-parse' CLI contract."
  :type '(choice (const :tag "Discover" nil) (repeat string))
  :group 'etaf-reader)

(defcustom etaf-reader-cache-directory
  (locate-user-emacs-file "etaf-reader/books")
  "Directory holding extracted book assets (covers and images)."
  :type 'directory
  :group 'etaf-reader)

;;; ---------------------------------------------------------------------------
;;; Default parser (ebook-parse CLI)
;;; ---------------------------------------------------------------------------

(defun etaf-reader--discover-parser ()
  "Return the command prefix for the ebook parser.
Discovery order: `etaf-reader-parser-command', the `PI_READER_PARSER'
environment variable, the installed `ebook-parse' command, then the shared
skill checkout."
  (let ((configured (or etaf-reader-parser-command
                        (let ((env (getenv "PI_READER_PARSER")))
                          (and env (list env))))))
    (cond
     (configured configured)
     ((executable-find "ebook-parse") (list (executable-find "ebook-parse")))
     (t
      (let ((script (expand-file-name
                     "skills/ebook-parse/scripts/ebook_parse.py"
                     (or (getenv "PI_CODING_AGENT_DIR")
                         (expand-file-name "~/.pi/agent")))))
        (when (file-readable-p script) (list "python3" script)))))))

(defun etaf-reader--run-parser (arguments)
  "Run the discovered parser with ARGUMENTS and return its JSON plist.
Signals `etaf-reader-error' with the parser's own output when it fails.  The
parser bounds its own work with `--timeout' defaults, so the synchronous call
cannot block on a runaway child."
  (let ((command (etaf-reader--discover-parser)))
    (unless command
      (signal 'etaf-reader-error
              (list "找不到电子书解析器：安装 ebook-parse 技能，或设置 etaf-reader-parser-command")))
    (let* ((program (car command))
           (script-p (string-suffix-p ".py" program))
           (executable (if script-p "python3" program))
           (full-arguments (append (if script-p (list program) nil) arguments))
           (stderr-file (make-temp-file "etaf-reader-parser-stderr")))
      (unwind-protect
          (with-temp-buffer
            (let* ((status (apply #'call-process executable nil
                                  (list (current-buffer) stderr-file) nil
                                  full-arguments))
                   (stdout (string-trim (buffer-string)))
                   (stderr (with-temp-buffer
                             (insert-file-contents stderr-file)
                             (string-trim (buffer-string)))))
              (unless (and (integerp status) (zerop status))
                (signal 'etaf-reader-error
                        (list (format "解析器失败（退出码 %s）：%s"
                                      status (or stderr "无输出")))))
              (condition-case error
                  (json-parse-string stdout :object-type 'plist :array-type 'list
                                     :null-object nil :false-object nil)
                (error
                 (signal 'etaf-reader-error
                         (list (format "解析器输出不是 JSON：%s" error)))))))
        (ignore-errors (delete-file stderr-file))))))

(defvar etaf-reader-default-parser
  (list :scan (lambda (directory)
                (etaf-reader--run-parser (list "scan" directory)))
        :extract (lambda (path output)
                   (etaf-reader--run-parser (list "extract" path "--out" output
                                                  "--force"))))
  "Default parser implementation backed by the `ebook-parse' skill.")

;;; ---------------------------------------------------------------------------
;;; Library operations
;;; ---------------------------------------------------------------------------

(defun etaf-reader--book-title (book)
  "Return BOOK's metadata title or its file name when metadata is blank."
  (let ((title (string-trim (or (plist-get book :title) ""))))
    (if (string-empty-p title)
        (if-let* ((path (plist-get book :path))) (file-name-base path) "未命名书籍")
      title)))

(defun etaf-reader--book-id (path)
  "Return the stable identity of the book at PATH."
  (secure-hash 'sha1 (file-truename (expand-file-name path))))

(defun etaf-reader--now ()
  "Return the current time as an integer."
  (floor (float-time)))

(cl-defun etaf-reader-library-scan (&key parser directories)
  "Scan every library directory and store the discovered books.
PARSER defaults to `etaf-reader-default-parser', DIRECTORIES to
`etaf-reader-library-directories'.  Return a plist with `:total', `:new',
`:changed' and `:failed'.  A previously imported book keeps its reading state
when its file is unchanged; a changed file is marked for re-import."
  (let* ((parser (or parser etaf-reader-default-parser))
         (scan (plist-get parser :scan))
         (directories (or directories etaf-reader-library-directories))
         (seen (make-hash-table :test #'equal))
         (new 0) (changed 0) (failed 0) (total 0))
    (dolist (directory directories)
      (when (file-directory-p directory)
        (let* ((report (funcall scan directory))
               (books (plist-get report :books)))
          (setq failed (+ failed (or (plist-get report :failed) 0)))
          (dolist (row books)
            (let* ((path (expand-file-name (plist-get row :path)))
                   (id (etaf-reader--book-id path))
                   (existing (etaf-reader-store-book id))
                   (mtime (or (plist-get row :mtime) 0))
                   (size (or (plist-get row :size) 0))
                   (unchanged (and existing
                                   (equal (plist-get existing :mtime) mtime)
                                   (equal (plist-get existing :size) size)
                                   (> (or (plist-get existing :chapters) 0) 0))))
              (puthash id t seen)
              (setq total (1+ total))
              (unless unchanged
                (if existing (setq changed (1+ changed)) (setq new (1+ new))))
              (when (or (null existing) (not unchanged))
                (etaf-reader-store-put-book
                 (list :id id
                       :title (or (plist-get row :title)
                                  (file-name-base path))
                       :author (or (plist-get row :author) "")
                       :format (or (plist-get row :format) "")
                       :path path
                       :cover (or (plist-get existing :cover) "")
                       :chapters (if unchanged
                                     (or (plist-get existing :chapters) 0)
                                   (or (plist-get row :chapters) 0))
                       :chars (if unchanged
                                  (or (plist-get existing :chars) 0)
                                (or (plist-get row :chars) 0))
                       :pages (or (plist-get row :pages) 0)
                       :size size
                       :mtime mtime
                       :added (or (plist-get existing :added) (etaf-reader--now))
                       :opened (or (plist-get existing :opened) 0)))))))))
    (list :total total :new new :changed changed :failed failed)))

(defun etaf-reader--cache-book-directory (id)
  "Return the asset cache directory of book ID."
  (expand-file-name id etaf-reader-cache-directory))

(defun etaf-reader--json-encode (value)
  "Encode VALUE as JSON, keeping keyword-keyed plists as objects at any depth.
`json-encode' guesses alist vs plist; a list of block plists is ambiguous and
would be encoded as an alist, so the store writes blocks through this encoder."
  (cond
   ((null value) "null")
   ((eq value t) "true")
   ((stringp value) (json-encode value))
   ((numberp value) (number-to-string value))
   ((and (listp value) (keywordp (car value)))
    (let ((parts nil)
          (rest value))
      (while rest
        (let ((key (pop rest))
              (item (pop rest)))
          (push (format "%s:%s"
                        (json-encode (substring (symbol-name key) 1))
                        (etaf-reader--json-encode item))
                parts)))
      (format "{%s}" (mapconcat #'identity (nreverse parts) ","))))
   ((listp value)
    (format "[%s]" (mapconcat #'etaf-reader--json-encode value ",")))
   (t (json-encode (format "%s" value)))))

(defun etaf-reader--read-json-file (file)
  "Return the JSON object stored in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'plist :array-type 'list
                       :null-object nil :false-object nil)))

(defun etaf-reader--import-book-file (id path parser)
  "Extract the book at PATH and write its chapters under ID.
Return the number of chapters imported.  A previous extraction is replaced
only after the new one succeeded."
  (let* ((extract (plist-get parser :extract))
         (cache (etaf-reader--cache-book-directory id))
         (fresh (concat cache ".new"))
         (had-cache (file-directory-p cache))
         (target (if had-cache fresh cache)))
    (when (file-directory-p fresh)
      (ignore-errors (delete-directory fresh t)))
    (let* ((report (funcall extract path (directory-file-name target)))
           (out (or (plist-get report :out) (directory-file-name target)))
           (manifest (etaf-reader--read-json-file
                      (expand-file-name "manifest.json" out)))
           (chapters (plist-get manifest :chapters))
           (count 0))
      (when had-cache
        (ignore-errors (delete-directory cache t)))
      (unless (string= (directory-file-name (expand-file-name out))
                       (directory-file-name (expand-file-name cache)))
        (rename-file out cache t))
      (let (chapter-rows content-rows)
        (dolist (entry chapters)
          (let* ((file (expand-file-name (plist-get entry :file) cache))
                 (chapter (etaf-reader--read-json-file file))
                 (index (or (plist-get chapter :index) count))
                 (chapter-id (format "%s#%d" id index)))
            (push (list :id chapter-id :book id :idx index
                        :title (or (plist-get chapter :title) "")
                        :chars (or (plist-get chapter :chars) 0))
                  chapter-rows)
            (push (list :id chapter-id
                        :text (or (plist-get chapter :text) "")
                        :blocks (etaf-reader--json-encode
                                 (or (plist-get chapter :blocks) [])))
                  content-rows)
            (setq count (1+ count))))
        ;; One batch per table: a thousand-chapter book no longer pays a
        ;; Controller reload for every row (measured 7.7 s before).
        (etaf-reader-store-put-chapters (nreverse chapter-rows))
        (etaf-reader-store-put-contents (nreverse content-rows)))
      (etaf-reader-store-put-book
       (list :id id
             :title (or (plist-get manifest :title) (plist-get manifest :path))
             :author (or (plist-get manifest :author) "")
             :format (or (plist-get manifest :format) "")
             :path (or (plist-get manifest :path) path)
             :cover (or (plist-get manifest :cover) "")
             :chapters count
             :chars (or (plist-get manifest :chars) 0)
             :pages (or (plist-get manifest :pages) 0)
             :size (or (plist-get manifest :size) 0)
             :mtime (or (plist-get manifest :mtime) 0)
             :added (etaf-reader--now)
             :opened (etaf-reader--now)))
      count)))

(defun etaf-reader-library-import (book &optional parser)
  "Import BOOK (a store row plist) and return it refreshed.
PARSER defaults to `etaf-reader-default-parser'.  Signals
`etaf-reader-error' when the file or the parser fails."
  (let* ((id (plist-get book :id))
         (path (plist-get book :path))
         (parser (or parser etaf-reader-default-parser)))
    (unless (and path (file-readable-p path))
      (signal 'etaf-reader-error (list (format "文件不可读：%s" path))))
    (etaf-reader--import-book-file id path parser)
    (or (etaf-reader-store-book id) book)))

(defun etaf-reader-library-ensure (book &optional parser)
  "Import BOOK when its chapter rows are missing, then return it refreshed."
  (if (etaf-reader-store-chapters (plist-get book :id))
      (or (etaf-reader-store-book (plist-get book :id)) book)
    (etaf-reader-library-import book parser)))

(provide 'etaf-reader-library)
;;; etaf-reader-library.el ends here
