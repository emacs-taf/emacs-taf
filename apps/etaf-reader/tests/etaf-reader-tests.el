;;; etaf-reader-tests.el --- Public acceptance scenarios -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public API acceptance for etaf-reader.  Every scenario drives the reader
;; through interfaces declared by the root entry Commentary: a headless
;; session, its navigation, selection, annotation, search and progress
;; functions.  A scripted parser supplies the book data, so no network,
;; backend process or frame is required.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ert)
(require 'etaf-reader)

;;; ---------------------------------------------------------------------------
;;; Scripted backend
;;; ---------------------------------------------------------------------------

(defconst etaf-reader-tests--chapters
  (list
   (list "第一章 起点"
         (concat "他在清晨出发。走过长长的街道，街角的面包店刚刚开门，空气里有麦子的香味。"
                 "\n\n"
                 "走了很久，鞋底磨薄了一层。远处的钟楼指向正午，他在桥边停下，看了看河水。"
                 "\n\n"
                 "下午的风从河面吹来，带着水汽。他想起出门前母亲说的话，于是继续向前走。"))
   (list "第二章 途中"
         (concat "路边有一家书店。木头的招牌掉了漆，门口摆着一摞旧杂志。"
                 "\n\n"
                 "他停下来，翻了一本讲远方的书。书里写到一座常年下雪的山，和一条通往海的路。"
                 "\n\n"
                 "店主没有催他。他把书放回原处，买了一支铅笔，在扉页写下自己的名字。"))
   (list "第三章 终点"
         (concat "黄昏时到达。村口的灯一盏一盏亮起来，像一串安静的句子。"
                 "\n\n"
                 "他终于站在那扇门前面，抬手，又放下。门上贴着一张褪色的纸，写着欢迎回家。"
                 "\n\n"
                 "故事到这里结束。他把一路上的笔记收进背包，准备第二天重新出发。")))
  "The three chapters the scripted parser serves.")

(defun etaf-reader-tests--blocks (text)
  "Return paragraph blocks of TEXT with projection offsets."
  (let ((cursor 0) (blocks nil) (index 0))
    (dolist (paragraph (split-string text "\n\n" t))
      (when (> index 0)
        (setq cursor (1+ cursor)))
      (push (list (cons :type "p") (cons :text paragraph)
                  (cons :start cursor) (cons :end (+ cursor (length paragraph))))
            blocks)
      (setq cursor (+ cursor (length paragraph)))
      (setq index (1+ index)))
    (nreverse blocks)))

(defun etaf-reader-tests--parser (root &optional heading image)
  "Return a scripted parser whose single book lives under ROOT.
HEADING turns each chapter's first block into a heading; IMAGE turns its
second block into a picture."
  (let ((book-path (expand-file-name "fake-book.epub" root))
        (chapters etaf-reader-tests--chapters))
    (with-temp-file book-path (insert "fake epub"))
    (list
     :scan
     (lambda (directory)
       (ignore directory)
       (list :books (list (list :path book-path :title "测试书" :author "作者"
                                :format "epub" :chapters (length chapters)
                                :chars 1200 :pages 0 :size 10 :mtime 1234.0))
             :failed 0))
     :extract
     (lambda (_source out)
       (make-directory (expand-file-name "chapters" out) t)
       (let ((index 0) (total 0) (entries nil))
         (dolist (chapter chapters)
           (let* ((text (nth 1 chapter))
                  (file (format "chapters/%03d.json" index)))
             (with-temp-file (expand-file-name file out)
               (insert (json-encode
                        (list :index index :title (nth 0 chapter)
                              :chars (length text) :text text
                              :blocks (let ((blocks (etaf-reader-tests--blocks text)))
                                        (when heading
                                          (setcdr (assq :type (car blocks)) "h1"))
                                        (when (and image (cdr blocks))
                                          (setcdr (assq :type (cadr blocks)) "img"))
                                        blocks)))))
             (push (list (cons :index index) (cons :title (nth 0 chapter))
                         (cons :chars (length text)) (cons :file file))
                   entries)
             (setq total (+ total (length text)))
             (setq index (1+ index))))
         (with-temp-file (expand-file-name "manifest.json" out)
           (insert (json-encode
                    (list :schema 1 :title "测试书" :author "作者" :format "epub"
                          :path book-path :cover "" :chars total :pages 0
                          :size 10 :mtime 1234.0
                          :chapters (nreverse entries)))))
         (list :out out :title "测试书" :chapters (length chapters)))))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defmacro etaf-reader-tests--with-environment (&rest body)
  "Run BODY with a disposable library store and cache directory."
  (declare (indent 0) (debug (body)))
  `(let* ((folder (make-temp-file "etaf-reader-tests" t))
          (etaf-reader-store-file (expand-file-name "library.sqlite3" folder))
          (etaf-reader-cache-directory (expand-file-name "cache" folder))
          ;; The scripted parser ignores the directory, but the scan visits only
          ;; directories that exist; never depend on the user's ~/ebooks.
          (etaf-reader-library-directories (list folder)))
     (unwind-protect
         (progn ,@body)
       (delete-directory folder t))))

(defun etaf-reader-tests--open (session)
  "Import the scripted book, open it and use a deterministic page geometry."
  (etaf-reader-refresh-library session)
  (etaf-reader-open-book session (car (etaf-reader-books session)))
  (etaf-reader-set-metrics session 40 4 1 'medium 'page)
  session)

(defun etaf-reader-tests--line (session index)
  "Return SESSION's wrapped line at INDEX."
  (nth index (etaf-reader-lines session)))

;;; ---------------------------------------------------------------------------
;;; Session and library
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-reader-tests-headless-session-starts-on-shelf ()
  "A session built without a buffer starts on the shelf and names itself."
  (etaf-reader-tests--with-environment
    (let ((session (etaf-reader-create)))
      (should (equal (plist-get (etaf-reader-state session) :view) 'shelf))
      (should (null (plist-get (etaf-reader-state session) :book)))
      (should (null (etaf-reader-books session))))))

(ert-deftest etaf-reader-tests-scan-imports-into-the-store ()
  "Scanning the library stores the book and opening imports its chapters."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-create
                     :parser (etaf-reader-tests--parser folder))))
      (unwind-protect
          (progn
            (etaf-reader-refresh-library session)
            (let ((books (etaf-reader-books session)))
              (should (= (length books) 1))
              (should (equal (plist-get (car books) :title) "测试书"))
              (should (= (or (plist-get (car books) :chapters) 0) 3)))
            (etaf-reader-open-book session (car (etaf-reader-books session)))
            (let ((state (etaf-reader-state session)))
              (should (eq (plist-get state :view) 'reader))
              (should (= (plist-get state :chapters) 3))
              (should (etaf-reader-lines session)))
            ;; The batch write keeps every chapter paired with its metadata:
            ;; open the last chapter and read its own text back.
            (etaf-reader-open-chapter session 2)
            (should (string-match-p
                     "故事到这里结束"
                     (mapconcat (lambda (line)
                                  (or (plist-get line :text) ""))
                                (etaf-reader-lines session) ""))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-book-without-chapters-imports-and-reports-it ()
  "A book whose parser found no chapter imports, then says it has nothing to read."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-empty-book" t))
           (book-path (expand-file-name "empty.epub" folder))
           (parser
            (list
             :scan (lambda (_directory)
                     (list :books (list (list :path book-path :title "空书"
                                              :author "" :format "epub"
                                              :chapters 0 :chars 0 :pages 0
                                              :size 1 :mtime 1.0))
                           :failed 0))
             :extract
             (lambda (_source out)
               (make-directory out t)
               (with-temp-file (expand-file-name "manifest.json" out)
                 (insert (json-encode
                          (list :schema 1 :title "空书" :author ""
                                :format "epub" :path book-path :cover ""
                                :chars 0 :pages 0 :size 1 :mtime 1.0
                                :chapters []))))
               (list :out out :title "空书" :chapters 0))))
           (session (etaf-reader-create :parser parser)))
      (unwind-protect
          (progn
            (with-temp-file book-path (insert "empty epub"))
            (etaf-reader-refresh-library session)
            (let ((books (etaf-reader-books session)))
              (should (= 1 (length books)))
              ;; Importing writes no chapter row, and that is not a failed
              ;; write: the reader then reports the empty book by itself.
              (let ((failure (should-error (etaf-reader-open-book session (car books))
                                           :type 'etaf-reader-error)))
                (should (string-match-p "没有可读章节"
                                        (error-message-string failure))))
              ;; The import still stored the book, and the shelf stays put.
              (etaf-reader-refresh-library session)
              (should (= 1 (length (etaf-reader-books session))))
              (should (eq 'shelf (plist-get (etaf-reader-state session) :view)))))
        (delete-directory folder t)))))

;;; ---------------------------------------------------------------------------
;;; Reading
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-reader-tests-pages-turn-and-chapters-advance ()
  "Page turns move the reading line and cross into the next chapter."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (let ((state (etaf-reader-state session)))
              (should (> (plist-get state :lines) 4))
              (should (= (plist-get state :line) 0)))
            (etaf-reader-next-page session)
            (should (= (plist-get (etaf-reader-state session) :line) 4))
            (etaf-reader-previous-page session)
            (should (= (plist-get (etaf-reader-state session) :line) 0))
            (etaf-reader-open-chapter session 0)
            (etaf-reader-goto-line session (1- (length (etaf-reader-lines session))))
            (etaf-reader-next-page session)
            (should (= (plist-get (etaf-reader-state session) :chapter) 1))
            (should (= (plist-get (etaf-reader-state session) :line) 0))
            (etaf-reader-previous-page session)
            (should (= (plist-get (etaf-reader-state session) :chapter) 0)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-selection-annotate-and-note ()
  "A selection becomes an annotation that can carry a thought."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (etaf-reader-begin-selection session 0 0)
            (etaf-reader-extend-selection session 0 4)
            (should (equal (etaf-reader-selection session) '(0 . 4)))
            (should (equal (etaf-reader-selection-text session) "他在清晨"))
            (let ((id (etaf-reader-annotate session "highlight" "yellow")))
              (should id)
              (etaf-reader-annotation-note session id "一句想法")
              (let ((row (car (etaf-reader-annotations session))))
                (should (equal (plist-get row :kind) "highlight"))
                (should (equal (plist-get row :color) "yellow"))
                (should (equal (plist-get row :note) "一句想法"))
                (should (equal (plist-get row :quote) "他在清晨")))
              (etaf-reader-mark-annotation session id "wavy" "blue")
              (should (equal (plist-get (car (etaf-reader-annotations session))
                                        :kind)
                             "wavy"))
              (etaf-reader-annotation-delete session id)
              (should (null (etaf-reader-annotations session))))
            (should (= (plist-get (etaf-reader-state session) :annotations) 0)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-progress-is-restored ()
  "Saving stores the position and a new session resumes there."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (parser (etaf-reader-tests--parser folder))
           (session (etaf-reader-tests--open (etaf-reader-create :parser parser))))
      (unwind-protect
          (progn
            (etaf-reader-open-chapter session 1)
            (etaf-reader-goto-line session 3)
            (let ((offset (plist-get (etaf-reader-tests--line session 3) :start))
                  (percent (etaf-reader-percent session)))
              (etaf-reader-save-now session)
              (should (> percent 0))
              (let* ((second (etaf-reader-create :parser parser))
                     (state (progn (etaf-reader-refresh-library second)
                                   (etaf-reader-open-book
                                    second (car (etaf-reader-books second)))
                                   (etaf-reader-state second)))
                     (line (etaf-reader-tests--line
                            second (plist-get state :line))))
                (should (= (plist-get state :chapter) 1))
                (should (<= (or (plist-get line :start) 0) offset))
                (should (<= offset (or (plist-get line :end) 0))))
              (should (> (etaf-reader-percent session) 0))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-search-finds-and-selects ()
  "Search finds a phrase across chapters and selects the match."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (let* ((state (etaf-reader-search-book session "书店"))
                   (match (car (plist-get state :matches))))
              (should (= (length (plist-get state :matches)) 1))
              (should (= (plist-get match :chapter) 1))
              (should (= (plist-get (etaf-reader-state session) :chapter) 1))
              (should (equal (etaf-reader-selection session)
                             (cons (plist-get match :start) (plist-get match :end)))))
            (let ((state (etaf-reader-search-book session "不存在的词")))
              (should (null (plist-get state :matches)))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-reflow-keeps-position ()
  "A column change re-wraps the chapter and keeps the reading offset."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (let* ((before (length (etaf-reader-lines session)))
                 (index (1- before))
                 (offset (plist-get (etaf-reader-tests--line session index) :start)))
            (etaf-reader-goto-line session index)
            (etaf-reader-set-metrics session 24 4 1 'narrow 'page)
            (let* ((lines (etaf-reader-lines session))
                   (line (nth (plist-get (etaf-reader-state session) :line) lines)))
              (should (> (length lines) before))
              (should (<= (or (plist-get line :start) 0) offset))
              (should (<= offset (or (plist-get line :end) 0)))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-export-notes ()
  "Exporting writes the quotations and thoughts as Markdown."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder))))
           (file (expand-file-name "notes.md" folder)))
      (unwind-protect
          (progn
            (etaf-reader-begin-selection session 0 0)
            (etaf-reader-extend-selection session 0 4)
            (let ((id (etaf-reader-annotate session "highlight" "yellow")))
              (etaf-reader-annotation-note session id "值得记住"))
            (etaf-reader-export-notes session file)
            (should (file-exists-p file))
            (with-temp-buffer
              (insert-file-contents file)
              (should (string-match-p "测试书" (buffer-string)))
              (should (string-match-p "他在清晨" (buffer-string)))
              (should (string-match-p "值得记住" (buffer-string)))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-shelf-filters-use-state ()
  "The shelf filters books by their stored reading state."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (etaf-reader-save-now session)
            (should (= (length (etaf-reader-books
                                (progn (etaf-reader-set-filter session 'unread)
                                       session)))
                       0))
            (etaf-reader-set-filter session 'reading)
            (should (= (length (etaf-reader-books session)) 1))
            (etaf-reader-set-filter session 'all)
            (should (= (length (etaf-reader-books session)) 1)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-mounted-styled-pages-and-final-page ()
  "Mounted turns preserve titles, annotations and blank final-page slots."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-mounted-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder t))))
           buffer quote)
      (unwind-protect
          (save-window-excursion
            (setq buffer (etaf-reader-open session))
            (etaf-reader-set-metrics session 24 4 2 'wide 'page)
            (let* ((lines (etaf-reader-lines session))
                   (marked (cl-position-if
                            (lambda (line) (> (- (plist-get line :end)
                                                (plist-get line :start)) 8)) lines)))
              (etaf-reader-begin-selection session marked 0)
              (etaf-reader-extend-selection session marked 6)
              (setq quote (etaf-reader-selection-text session))
              (etaf-reader-annotate session "wavy" "red"))
            (dolist (top (list 8 0 (1- (length (etaf-reader-lines session))) 0))
              (etaf-reader-goto-line session top)
              (should (= top (plist-get (etaf-reader-state session) :line)))
              (let ((expected (string-trim
                               (plist-get (nth top (etaf-reader-lines session)) :text))))
                (with-current-buffer buffer
                  (should (string-match-p (regexp-quote expected)
                                          (buffer-substring-no-properties
                                           (point-min) (point-max)))))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (should (search-forward quote nil t))
              (let* ((face (get-text-property (- (point) (length quote)) 'face))
                     (faces (if (keywordp (car-safe face)) (list face) face)))
                (should (seq-some (lambda (f) (eq (plist-get f :weight) 'bold)) faces))
                (should (seq-some (lambda (f) (plist-get f :underline)) faces))))
            ;; A resize followed by a turn uses the newly published column count.
            (etaf-reader-set-metrics session 32 4 1 'medium 'page)
            (with-current-buffer buffer (execute-kbd-macro (kbd "SPC")))
            (should (= 4 (plist-get (etaf-reader-state session) :line))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-library-query-sort-and-pages ()
  "Every filtered book remains reachable through bounded library pages."
  (etaf-reader-tests--with-environment
    (let* ((directory (make-temp-file "reader-library-" t))
           (etaf-reader-library-directories (list directory))
           (parser
            (list :scan
                  (lambda (_directory)
                    (list :failed 0 :books
                          (cl-loop for n below 12
                                   collect (list :path (expand-file-name (format "Book %02d.epub" n) directory)
                                                 :title (if (= n 0) "" (format "Book %02d" n))
                                                 :author (if (< n 6) "甲" "乙")
                                                 :format "epub" :size 1 :mtime 1))))))
           (session (etaf-reader-create :parser parser)))
      (unwind-protect
          (progn
            (etaf-reader-refresh-library session)
            (etaf-reader-set-metrics session 40 14 1 'medium 'page)
            (should (= 6 (length (etaf-reader-filter-library session "甲" 'all 'title))))
            (let ((pages (plist-get (etaf-reader-library-page session) :pages))
                  titles)
              (should (> pages 1))
              (dotimes (_ pages)
                (setq titles (append titles (mapcar (lambda (book) (plist-get book :title))
                                                    (plist-get (etaf-reader-library-page session) :items))))
                (etaf-reader-page-library session 1))
              (should (equal titles '("Book 00" "Book 01" "Book 02" "Book 03" "Book 04" "Book 05"))))
            (etaf-reader-filter-library session "Book 11" 'unread)
            (should (= 0 (plist-get (etaf-reader-library-page session) :index)))
            (should (= 1 (plist-get (etaf-reader-library-page session) :total))))
        (delete-directory directory t)))))

(ert-deftest etaf-reader-tests-preferences-persist-and-reject-invalid-options ()
  "Reading preferences survive a new session; invalid input changes nothing."
  (etaf-reader-tests--with-environment
    (let ((session (etaf-reader-create)))
      (etaf-reader-configure session :theme 'sepia :mode 'scroll :density 'compact :columns 32)
      (let ((before (etaf-reader-state session)))
        (should-error (etaf-reader-configure session :theme 'light :columns 0)
                      :type 'etaf-reader-error)
        (should (equal before (etaf-reader-state session))))
      (let ((state (etaf-reader-state (etaf-reader-create))))
        (should (eq (plist-get state :theme) 'sepia))
        (should (eq (plist-get state :mode) 'scroll))
        (should (eq (plist-get state :density) 'compact))))))

(ert-deftest etaf-reader-tests-root-keys-own-the-canvas ()
  "The reader's keys beat the renderer and its canvas follows the theme."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-canvas-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder)
                                         :theme 'dark)))
           (canvas (lambda (buffer)
                     (with-current-buffer buffer
                       (plist-get (car (last (alist-get 'default face-remapping-alist)))
                                  :background))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (etaf-reader-open session))
            ;; The canvas paints the dark palette's app background.
            (should (equal (funcall canvas buffer) "#111110"))
            (with-current-buffer buffer (execute-kbd-macro (kbd "t")))
            (should (eq (plist-get (etaf-reader-state session) :theme) 'light))
            ;; The light palette keeps its app background on the canvas too.
            (should (equal (funcall canvas buffer) "#f9f9f8"))
            (with-current-buffer buffer (execute-kbd-macro (kbd "q")))
            (should-not (buffer-live-p buffer)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(etaf-define-component etaf-reader-tests--framing-host (&key surface session)
  "Provide SURFACE to the reader SESSION and render it below."
  :setup (etaf-surface-provide surface)
  :render (etaf-reader-view-for-session session))

(defun etaf-reader-tests--row-painting (buffer color)
  "Return the first position in BUFFER whose face paints COLOR as background."
  (with-current-buffer buffer
    (let ((pos (point-min))
          found)
      (while (and (< pos (point-max)) (not found))
        (when (equal color
                     (plist-get (get-text-property pos 'face) :background))
          (setq found pos))
        (setq pos (1+ pos)))
      found)))

(defun etaf-reader-tests--painted-background (buffer position)
  "Return the background BUFFER paints at POSITION."
  (with-current-buffer buffer
    (plist-get (get-text-property position 'face) :background)))

(ert-deftest etaf-reader-tests-declares-its-surface-to-a-host ()
  "A host frames the reader from the surface the reader declares.
The reader's own switch and a panel's title-bar switch write the session's
mode cell, so the paper repaints instead of only the frame chrome."
  (etaf-reader-tests--with-environment
    (let* ((session (etaf-reader-create :theme 'dark))
           (surface (etaf-surface-create))
           (buffer (generate-new-buffer " *etaf-reader framing host*")))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (etaf-reader-tests--framing-host
                                    :surface surface :session session)))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should (equal '((light . "亮") (dark . "暗") (sepia . "纸"))
                           (etaf-surface-modes surface)))
            (should (eq 'dark (etaf-value (etaf-surface-mode surface))))
            (let* ((before (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg))
                   (pos (etaf-reader-tests--row-painting buffer before)))
              (should pos)
              (etaf-set-value (etaf-surface-mode surface) 'sepia)
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (should (eq 'sepia (plist-get (etaf-reader-state session) :theme)))
              (let ((after (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg)))
                (should-not (equal before after))
                (should (equal after
                               (etaf-reader-tests--painted-background buffer pos))))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-reader-tests-arrows-reach-the-page ()
  "Arrows turn the page and extend a selection wherever point rests."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-arrows-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (etaf-reader-open session))
            (etaf-reader-set-metrics session 24 4 1 'narrow 'page)
            (with-current-buffer buffer
              (goto-char (point-min))
              (let ((line (plist-get (etaf-reader-state session) :line)))
                (execute-kbd-macro (kbd "<right>"))
                (should-not (etaf-focused-host-ref))
                (should (> (plist-get (etaf-reader-state session) :line) line)))
              (execute-kbd-macro (kbd "v <down>"))
              (should (plist-get (etaf-reader-state session) :selection))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-pages-turn-past-pictures ()
  "Pages turn onto, across and away from a picture line."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-pictures-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder nil t))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (etaf-reader-open session))
            (etaf-reader-set-metrics session 24 4 2 'wide 'page)
            (let ((pictures 0) (lines nil))
              (with-current-buffer buffer
                (dotimes (_ 6)
                  (let ((state (etaf-reader-state session)))
                    (push (cons (plist-get state :chapter) (plist-get state :line))
                          lines))
                  (when (string-match-p "\\[图片" (buffer-substring-no-properties
                                                   (point-min) (point-max)))
                    (setq pictures (1+ pictures)))
                  (execute-kbd-macro (kbd "SPC"))
                  (should-not (string-prefix-p
                               "出错" (or (plist-get (etaf-reader-state session) :message) "")))))
              (should (> pictures 0))
              (should (equal lines (delete-dups (copy-sequence lines))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-navigation-panes-and-return-position ()
  "Mounted navigation opens, pages and closes without losing the reading page."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-navigation-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (etaf-reader-open session))
            (etaf-reader-jump session 2 0)
            (should (= 2 (plist-get (etaf-reader-state session) :chapter)))
            (etaf-reader-jump-back session)
            (should (= 0 (plist-get (etaf-reader-state session) :chapter)))
            (dolist (pane '(toc notes bookmarks search settings))
              (etaf-reader-show-pane session pane)
              (should (eq pane (plist-get (etaf-reader-state session) :pane)))
              (with-current-buffer buffer
                (should (string-match-p "关闭" (buffer-substring-no-properties (point-min) (point-max)))))
              (etaf-reader-show-pane session nil)
              (with-current-buffer buffer
                (should (string-match-p "测试书" (buffer-substring-no-properties (point-min) (point-max))))))
            ;; App keys must still work while a catalog control owns focus.
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (control (seq-find
                             (lambda (entry)
                               (equal (plist-get (cdr entry) :aria-label) "更多"))
                             (etaf-runtime-host-props-entries runtime))))
              (should control)
              (with-current-buffer buffer (etaf-focus runtime (car control))))
            (with-current-buffer buffer (execute-kbd-macro (kbd "o")))
            (should (eq 'settings (plist-get (etaf-reader-state session) :pane)))
            (with-current-buffer buffer (execute-kbd-macro (kbd "<escape>")))
            (should-not (plist-get (etaf-reader-state session) :pane)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-switching-books-keeps-separate-progress ()
  "Switching books never saves the previous chapter against the new book."
  (etaf-reader-tests--with-environment
    (let* ((first-root (make-temp-file "reader-first-" t))
           (second-root (make-temp-file "reader-second-" t))
           (first-parser (etaf-reader-tests--parser first-root))
           (second-parser (etaf-reader-tests--parser second-root))
           (reader (etaf-reader-create :parser first-parser))
           (other (etaf-reader-create :parser second-parser)))
      (unwind-protect
          (progn
            (etaf-reader-refresh-library reader)
            (let ((first-book (car (etaf-reader-books reader))))
              (etaf-reader-refresh-library other)
              (let ((second-book
                     (seq-find (lambda (book)
                                 (equal (plist-get book :path)
                                        (expand-file-name "fake-book.epub" second-root)))
                               (etaf-reader-books other))))
                (etaf-reader-open-book reader first-book first-parser)
                (etaf-reader-open-chapter reader 1)
                (etaf-reader-open-book reader second-book second-parser)
                (should (= 0 (plist-get (etaf-reader-state reader) :chapter)))
                (etaf-reader-open-chapter reader 2)
                (etaf-reader-open-book reader first-book first-parser)
                (should (= 1 (plist-get (etaf-reader-state reader) :chapter)))
                (etaf-reader-open-book reader second-book second-parser)
                (should (= 2 (plist-get (etaf-reader-state reader) :chapter))))))
        (delete-directory first-root t)
        (delete-directory second-root t)))))

(ert-deftest etaf-reader-tests-help-stays-in-reader ()
  "All help requests preserve reading state and use the same mounted modal."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-help-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (should-error (etaf-reader-show-pane session 'help) :type 'etaf-reader-error)
            (setq buffer (etaf-reader-open session))
            (with-current-buffer buffer
              (let* ((runtime (etaf-runtime-for-buffer buffer))
                     (windows (window-list))
                     (before (etaf-reader-state session)))
                (etaf-focus-next runtime)
                (let ((focus (etaf-focused-host-ref runtime)))
                  (dolist (open (list (lambda () (execute-kbd-macro (kbd "?")))
                                     (lambda () (execute-kbd-macro (kbd "C-c h")))
                                     (lambda () (etaf-reader-show-pane session 'help))))
                    (funcall open)
                    (let* ((data (etaf-help-data runtime))
                           (entries (apply #'append
                                           (mapcar (lambda (group) (plist-get group :entries))
                                                   (plist-get data :groups))))
                           (chapter (cl-find "H" entries :test #'equal
                                             :key (lambda (entry) (plist-get entry :key))))
                           (up (cl-find "M-v" entries :test #'equal
                                        :key (lambda (entry) (plist-get entry :key))))
                           (same-runtime (eq runtime (etaf-runtime-for-buffer buffer))))
                      (should same-runtime)
                      (should (eq (window-buffer) buffer))
                      (should (equal windows (window-list)))
                      (should (equal (plist-get data :title) "电子书阅读器"))
                      (should (equal (plist-get chapter :label) "上一章"))
                      (should (equal (plist-get up :label) "阅读上一页")))
                    (execute-kbd-macro (kbd "/"))
                    (execute-kbd-macro "?")
                    (execute-kbd-macro (kbd "<escape>"))
                    (let ((editing (etaf-text-input-active-p runtime)))
                      (should-not editing))
                    (should (string-match-p "快捷键 · 只读"
                                            (buffer-substring-no-properties (point-min) (point-max))))
                    (execute-kbd-macro (kbd "<escape>"))
                    (let ((restored (equal focus (etaf-focused-host-ref runtime)))
                          (after (etaf-reader-state session)))
                      (should restored)
                      (should (equal before after)))))
                (etaf-reader-show-pane session 'help)
                (etaf-reader-show-pane session nil)
                (let ((open (etaf-help-close runtime)))
                  (should-not open)))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-mode-line-preserved ()
  "Opening the reader preserves Emacs's mode-line."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-modeline-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (etaf-reader-open session))
            (let ((ml (with-current-buffer buffer mode-line-format)))
              (should ml)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-previous-page-lands-on-chapter-end ()
  "Turning backward across a chapter boundary opens the previous chapter's last page."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-prev-end-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (let* ((ch0-lines (length (etaf-reader-lines session)))
                 (expected-last (* (/ (max 0 (1- ch0-lines)) 4) 4)))
            (should (> expected-last 0))
            (etaf-reader-open-chapter session 1 0)
            (should (= 1 (plist-get (etaf-reader-state session) :chapter)))
            (should (= 0 (plist-get (etaf-reader-state session) :line)))
            (etaf-reader-previous-page session)
            (should (= 0 (plist-get (etaf-reader-state session) :chapter)))
            (should (= expected-last (plist-get (etaf-reader-state session) :line))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-zero-length-selection-rejected-and-toolbar-edits-in-place ()
  "Zero-length selection never creates corrupt annotations; Scheme A toolbar stays open to edit."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-toolbar-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder))))
           buffer)
      (unwind-protect
          (save-window-excursion
            ;; Zero-length selection produces nil and refuses annotation.
            (etaf-reader-begin-selection session 0 2)
            (etaf-reader-extend-selection session 0 2)
            (should-not (etaf-reader-selection session))
            (should-not (etaf-reader-annotate session "highlight" "yellow"))
            (should-not (etaf-reader-annotations session))
            (etaf-reader-clear-selection session)
            ;; Mounted Scheme A workflow: select -> toolbar (no 删除) -> highlight -> stays open with 删除 -> switch to wavy -> delete.
            (setq buffer (etaf-reader-open session))
            (etaf-reader-set-metrics session 32 10 1 'medium 'page)
            (with-current-buffer buffer
              (execute-kbd-macro (kbd "v <right> <right> <right> <right> RET"))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "高亮" text))
                (should-not (string-match-p "删除" text)))
              (let* ((runtime (etaf-runtime-for-buffer buffer))
                     (btn (seq-find (lambda (e) (equal (plist-get (cdr e) :aria-label) "高亮"))
                                    (etaf-runtime-host-props-entries runtime))))
                (should btn)
                (etaf-focus runtime (car btn))
                (execute-kbd-macro (kbd "RET")))
              ;; Annotation created and toolbar stays open in edit mode showing 删除.
              (should (= 1 (length (etaf-reader-annotations session))))
              (should (equal "highlight" (plist-get (car (etaf-reader-annotations session)) :kind)))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "删除" text)))
              ;; Switch style in-place to wavy without re-selecting.
              (let* ((runtime (etaf-runtime-for-buffer buffer))
                     (btn (seq-find (lambda (e) (equal (plist-get (cdr e) :aria-label) "波浪"))
                                    (etaf-runtime-host-props-entries runtime))))
                (should btn)
                (etaf-focus runtime (car btn))
                (execute-kbd-macro (kbd "RET")))
              (should (equal "wavy" (plist-get (car (etaf-reader-annotations session)) :kind)))
              ;; Delete annotation and dismiss toolbar.
              (let* ((runtime (etaf-runtime-for-buffer buffer))
                     (btn (seq-find (lambda (e) (equal (plist-get (cdr e) :aria-label) "删除"))
                                    (etaf-runtime-host-props-entries runtime))))
                (should btn)
                (etaf-focus runtime (car btn))
                (execute-kbd-macro (kbd "RET")))
              (should-not (etaf-reader-annotations session))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-scroll-mode-and-sidebar-controls ()
  "Scroll mode renders a single column; sidebar lists all chapters and updates on page turns."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "reader-scroll-sb-" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create :parser (etaf-reader-tests--parser folder))))
           buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (etaf-reader-open session))
            (etaf-reader-set-metrics session 40 12 2 'wide 'page)
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                ;; All three chapters appear in the sidebar.
                (should (string-match-p "第一章 起点" text))
                (should (string-match-p "第二章 途中" text))
                (should (string-match-p "第三章 终点" text))
                (should (string-match-p "全书进度" text)))
              ;; Toggle to scroll mode: only one column Host is mounted.
              (execute-kbd-macro (kbd "z"))
              (should (eq 'scroll (plist-get (etaf-reader-state session) :mode)))
              (let* ((runtime (etaf-runtime-for-buffer buffer))
                     (col0 (etaf-runtime-host-props-for runtime 'reader-column-0))
                     (col1 (etaf-runtime-host-props-for runtime 'reader-column-1)))
                (should col0)
                (should-not col1))
              ;; Return to page mode.
              (execute-kbd-macro (kbd "z"))
              (should (eq 'page (plist-get (etaf-reader-state session) :mode)))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (etaf-reader-close)))
        (delete-directory folder t)))))

(provide 'etaf-reader-tests)
;;; etaf-reader-tests.el ends here
