;;; etaf-weread-demo.el --- Runnable etaf-weread demo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Two entry points for trying the reader without wiring anything:
;;
;;   M-x etaf-weread-demo-open   a scripted account (no network, no login)
;;   M-x etaf-weread-demo-live   the bundled backend and the stored login
;;
;; The scripted account carries a small shelf, one book with chapters and
;; highlights, a notebook entry and reading statistics, so every screen of the
;; reader can be checked offline.  It is also a compact example of the client
;; protocol declared by `etaf-weread-client-call'.

;;; Code:

(require 'etaf)
(require 'etaf-weread)

(defconst etaf-weread-demo--books
  '((:bookId "1" :title "夜航西飞" :author "柏瑞尔·马卡姆"
             :category "文学-外国文学" :progress 42 :readingTime 9360)
    (:bookId "2" :title "为什么伟大不能被计划" :author "肯尼斯·斯坦利"
             :category "经济理财-管理" :progress 12 :readingTime 1800)
    (:bookId "3" :title "音乐是怎样算成的" :author "阿里·马奥尔"
             :category "科学技术-科学科普" :progress 0 :readingTime 0)
    (:bookId "4" :title "禅与摩托车维修艺术" :author "罗伯特·M.波西格"
             :category "文学-外国文学" :progress 100 :readingTime 12840
             :finished t)
    (:bookId "5" :title "费曼物理学讲义" :author "理查德·费曼"
             :category "科学技术-物理" :progress 28 :readingTime 5400)
    (:bookId "6" :title "红楼梦" :author "曹雪芹"
             :category "文学-古典文学" :progress 7 :readingTime 2600)
    (:bookId "7" :title "置身事内" :author "兰小欢"
             :category "经济理财-经济" :progress 63 :readingTime 7200)
    (:bookId "8" :title "人类简史" :author "尤瓦尔·赫拉利"
             :category "历史-世界史" :progress 88 :readingTime 9900)
    (:bookId "9" :title "代码整洁之道" :author "罗伯特·C.马丁"
             :category "计算机-软件工程" :progress 45 :readingTime 4800)
    (:bookId "10" :title "非暴力沟通" :author "马歇尔·卢森堡"
             :category "心理-沟通" :progress 21 :readingTime 3100)
    (:bookId "11" :title "毛姆短篇小说全集" :author "毛姆"
             :category "文学-外国文学" :progress 52 :readingTime 6600)
    (:bookId "12" :title "中国美术史" :author "李霖灿"
             :category "艺术-美术" :progress 0 :readingTime 0))
  "Shelf the scripted demo account reports.")

(defconst etaf-weread-demo--chapters
  '((:chapterIdx 1 :title "卷一 在非洲" :wordCount 8200)
    (:chapterIdx 2 :title "第二章 夜航" :wordCount 6400)
    (:chapterIdx 3 :title "第三章 归途" :wordCount 7100)
    (:chapterIdx 4 :title "第四章 驼队" :wordCount 5300))
  "Chapter list the scripted demo account reports.")

(defconst etaf-weread-demo--highlights
  '(("卷一 在非洲" "我们生来就是孤独的，但我们也生来就渴望陪伴。"
     "孤独不是缺少陪伴，是缺少被理解。")
    ("卷二 夜航" "飞行是一种孤独的自由。" nil)
    ("卷三 归途" "你要先学会一个人走，才能决定和谁一起走。" "和投资与写作是一回事。")
    ("卷四 驼队" "真正的旅行没有目的地。" nil))
  "Highlights and attached thoughts the scripted demo account reports.")

(defun etaf-weread-demo--client (request callback)
  "Answer the scripted demo account the way the backend would answer REQUEST.
This function is a valid `etaf-weread-client-call' client, which is what makes
it useful as a reference: it is the whole backend in one place."
  (let ((book (lambda (item)
                (list :bookId (plist-get item :bookId)
                      :title (plist-get item :title)
                      :author (plist-get item :author)
                      :category (plist-get item :category)
                      :progress (plist-get item :progress)
                      :readingTime (plist-get item :readingTime)
                      :finished (plist-get item :finished)))))
    (funcall
     callback
     (list :ok
           (pcase (plist-get request :op)
             (:status '(:ok t :login "ok" :name "演示读者" :vid "demo"))
             (:shelf (list :ok t :books (length etaf-weread-demo--books)
                           :reading 3 :finished 1
                           :data (list :shelf (mapcar book etaf-weread-demo--books))))
             (:notebook (list :ok t :books 2 :notes 4 :reviews 2
                              :data (list :books
                                          (mapcar (lambda (item)
                                                    (list :bookId (plist-get item :bookId)
                                                          :title (plist-get item :title)
                                                          :counts (list :notes 4 :reviews 2)))
                                                  (seq-take etaf-weread-demo--books 2)))))
             (:search (list :ok t
                            :data (list :books
                                        (list (list :bookId "9" :title "夜航船"
                                                    :author "张岱" :rating 91)))))
             (:book (list :ok t
                          :data (list :book (list :bookId (plist-get request :id)
                                                  :title "夜航西飞"
                                                  :author "柏瑞尔·马卡姆"
                                                  :category "文学-外国文学"
                                                  :counts (list :notes 4 :reviews 2)
                                                  :intro "回忆录。第一次单人由东向西飞越大西洋。")
                                      :progress (list :progress 42 :readingTime 9360)
                                      :chapters (mapcar (lambda (chapter)
                                                          (list :chapterIdx (plist-get chapter :chapterIdx)
                                                                :title (plist-get chapter :title)
                                                                :wordCount (plist-get chapter :wordCount)))
                                                        etaf-weread-demo--chapters))))
             (:notes (list :ok t
                           :data (list :book (list :bookId (plist-get request :id)
                                                   :title "夜航西飞")
                                       :highlights
                                       (cl-loop for (chapter text nil) in etaf-weread-demo--highlights
                                                for index from 1
                                                collect (list :bookmarkId (format "demo-%d" index)
                                                              :chapterName chapter
                                                              :range (format "%d-%d" index (1+ index))
                                                              :markText text
                                                              :createTime (+ 1700000000 index)))
                                       :reviews
                                       (cl-loop for (chapter _nil thought) in etaf-weread-demo--highlights
                                                for index from 1
                                                when thought
                                                collect (list :reviewId (format "demo-r%d" index)
                                                              :chapterName chapter
                                                              :range (format "%d-%d" index (1+ index))
                                                              :content thought
                                                              :createTime (+ 1700000100 index))))))
             (:stats (list :ok t :books 4 :finished 1 :reading 3 :notes 4
                           :total_reading_seconds 24000
                           :total_reading_time "6小时40分"
                           :conclusion "读完 1 本 · 在读 3 本 · 累计 6小时40分"
                           :data (list :top (mapcar book etaf-weread-demo--books)
                                       :finished '("禅与摩托车维修艺术")
                                       :reading nil)))
             (:export (list :ok t :conclusion "演示模式不写文件")))))))

(defun etaf-weread-demo-open ()
  "Open the reader on the scripted demo account.
No network, login or external backend is needed."
  (interactive)
  (etaf-weread-open (etaf-weread-create :client #'etaf-weread-demo--client)))

(defun etaf-weread-demo-live ()
  "Open the reader against the bundled backend and the stored login."
  (interactive)
  (etaf-weread-open))

(provide 'etaf-weread-demo)
;;; etaf-weread-demo.el ends here
