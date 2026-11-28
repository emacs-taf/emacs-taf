;;; performance-scenarios.el --- Reader page-turn workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; Mounted keyboard page turns with a heading and persisted annotations.
;; The workspace driver owns timing, redisplay, sampling and evidence.

;;; Code:
(require 'etaf-reader)
(require 'json)
(declare-function taf-benchmark-register "performance-driver")

(defun etaf-reader-benchmark--parser (file)
  "Return a deterministic local parser for FILE."
  (list
   :scan (lambda (_directory)
           (list :books (list (list :path file :title "阅读验收" :author "ETAF"
                                    :format "epub" :size 1 :mtime 1 :chapters 1))
                 :failed 0))
   :extract
   (lambda (_file out)
     (let ((offset 0) blocks paragraphs)
       (dotimes (i 120)
         (let ((text (if (= i 0) "阅读验收 · 第一章"
                       (format "第%03d段。读书时，文字与笔记应该安静地留在纸上，翻页不应打断思绪。" i))))
           (push text paragraphs)
           (push (list (cons :type (if (= i 0) "h1" "p"))
                       (cons :text text) (cons :start offset)
                       (cons :end (+ offset (length text)))) blocks)
           (setq offset (+ offset (length text) 1))))
       (make-directory (expand-file-name "chapters" out) t)
       (with-temp-file (expand-file-name "chapters/000.json" out)
         (insert (json-encode
                  (list :index 0 :title "第一章" :chars (1- offset)
                        :text (mapconcat #'identity (nreverse paragraphs) "\n")
                        :blocks (vconcat (nreverse blocks))))))
       (with-temp-file (expand-file-name "manifest.json" out)
         (insert (json-encode
                  (list :schema 1 :title "阅读验收" :author "ETAF" :format "epub"
                        :path file :cover "" :chars (1- offset) :pages 0 :size 1 :mtime 1
                        :chapters [((:index . 0) (:title . "第一章")
                                    (:file . "chapters/000.json"))]))))
       (list :out out)))))

(defun etaf-reader-benchmark--setup (_mode)
  "Create a mounted reader with isolated data and return its driver fixture."
  (when (get-buffer "*ETAF Reader*")
    (error "Close the reader in the dedicated benchmark instance before running"))
  (let* ((root (make-temp-file "reader-benchmark-" t))
         (store (expand-file-name "library.sqlite3" root))
         (cache (expand-file-name "cache" root))
         (file (expand-file-name "book.epub" root))
         (etaf-reader-store-file store)
         (etaf-reader-cache-directory cache)
         (etaf-reader-library-directories (list root))
         (session (etaf-reader-create :parser (etaf-reader-benchmark--parser file)))
         buffer rows quote)
    (with-temp-file file (insert "fixture"))
    (etaf-reader-refresh-library session)
    (etaf-reader-open-book session (car (etaf-reader-books session)))
    (setq buffer (etaf-reader-open session))
    (setq rows (max 4 (- (window-body-height (get-buffer-window buffer t)) 7)))
    (etaf-reader-set-metrics session 40 rows 1 'medium 'page)
    (etaf-reader-begin-selection session 5 0)
    (etaf-reader-extend-selection session 5 8)
    (setq quote (etaf-reader-selection-text session))
    (unless (and quote (not (string-empty-p quote)))
      (error "Reader workload did not select annotation text"))
    (etaf-reader-annotate session "wavy" "red")
    (etaf-reader-clear-selection session)
    (list
     :buffer buffer
     :invoke
     (lambda (sample)
       (let ((etaf-reader-store-file store) (etaf-reader-cache-directory cache))
         (with-current-buffer buffer
           (execute-kbd-macro (if (zerop (% sample 2)) (kbd "SPC") (kbd "DEL"))))))
     :verify
     (lambda ()
       (let* ((state (etaf-reader-state session))
              (top (plist-get state :line))
              (visible (with-current-buffer buffer
                         (buffer-substring-no-properties (point-min) (point-max)))))
         (if (and (= (plist-get state :chapter) 0)
                  (memq top (list 0 rows))
                  (cl-every (lambda (line)
                              (string-match-p (regexp-quote (string-trim (or (plist-get line :text) "")))
                                              visible))
                            (seq-take (nthcdr top (etaf-reader-lines session)) rows))
                  (or (/= top 0)
                      (with-current-buffer buffer
                        (save-excursion
                          (goto-char (point-min))
                          (when (search-forward quote nil t)
                            (let* ((face (get-text-property (- (point) (length quote)) 'face))
                                   (faces (if (keywordp (car-safe face)) (list face) face)))
                              (seq-some (lambda (f) (plist-get f :underline)) faces)))))))
             t "Reader page, annotation and visible text disagree")))
     :observe
     (lambda (sink)
       (let ((runtime (etaf-runtime-for-buffer buffer)))
         (etaf-performance-clear)
         (etaf-performance-start runtime)
         (lambda ()
           (etaf-performance-stop runtime)
           (dolist (operation (plist-get (etaf-performance-report-data) :operations))
             (when (equal (plist-get operation :buffer-name) (buffer-name buffer))
               (dolist (stage (plist-get operation :stages))
                 (funcall sink
                          (append (list :provider (plist-get stage :provider)
                                        :stage (plist-get stage :stage)
                                        :duration-ms (plist-get stage :duration-ms))
                                  (plist-get stage :metadata)))))))))
     :cleanup
     (lambda ()
       (let ((etaf-reader-store-file store) (etaf-reader-cache-directory cache))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (etaf-reader-close))))
       (delete-directory root t)))))

(taf-benchmark-register
 "reader.page.styled" :version 2 :modes '(batch gui) :budget-ms 16
 :impact 'local :isolation 'series
 :description "Keyboard page turns between a marked heading page and prose"
 :setup #'etaf-reader-benchmark--setup)

(provide 'etaf-reader-performance-scenarios)
;;; performance-scenarios.el ends here
