;;; etaf-reader-demo.el --- Scripted demo session for etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A runnable reader with a scripted parser and a disposable library, so the
;; whole application can be opened without the backend or an ebook file:
;;
;;   emacs -Q -L ../.. -L . -l examples/etaf-reader-demo.el -f etaf-reader-demo-open
;;
;; The demo adds a book with three chapters to a temporary store and mounts
;; the reader on it.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'etaf-reader)

(defconst etaf-reader-demo--chapters
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
  "The chapters the demo book contains.")

(defun etaf-reader-demo--blocks (text)
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

(defun etaf-reader-demo-parser (root)
  "Return a scripted parser serving the demo book under ROOT."
  (let ((book-path (expand-file-name "demo-book.epub" root))
        (chapters etaf-reader-demo--chapters))
    (with-temp-file book-path (insert "demo epub"))
    (list
     :scan
     (lambda (directory)
       (ignore directory)
       (list :books (list (list :path book-path :title "示例书" :author "ETAF"
                                :format "epub" :chapters (length chapters)
                                :chars 1200 :pages 0 :size 10 :mtime 1.0))
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
                              :blocks (etaf-reader-demo--blocks text)))))
             (push (list (cons :index index) (cons :title (nth 0 chapter))
                         (cons :chars (length text)) (cons :file file))
                   entries)
             (setq total (+ total (length text)))
             (setq index (1+ index))))
         (with-temp-file (expand-file-name "manifest.json" out)
           (insert (json-encode
                    (list :schema 1 :title "示例书" :author "ETAF" :format "epub"
                          :path book-path :cover "" :chars total :pages 0
                          :size 10 :mtime 1.0
                          :chapters (nreverse entries)))))
         (list :out out))))))

(defun etaf-reader-demo-create ()
  "Return a reader session over the scripted demo book."
  (let* ((root (make-temp-file "etaf-reader-demo" t))
         (etaf-reader-store-file (expand-file-name "library.sqlite3" root))
         (etaf-reader-cache-directory (expand-file-name "cache" root))
         (etaf-reader--store nil)
         (session (etaf-reader-create :parser (etaf-reader-demo-parser root))))
    (etaf-reader-refresh-library session)
    (etaf-reader-open-book session (car (etaf-reader-store-books)))
    session))

;;;###autoload
(defun etaf-reader-demo-open ()
  "Open the reader on its scripted demo book and return the buffer."
  (interactive)
  (etaf-reader-open (etaf-reader-demo-create)))

(provide 'etaf-reader-demo)
;;; etaf-reader-demo.el ends here
