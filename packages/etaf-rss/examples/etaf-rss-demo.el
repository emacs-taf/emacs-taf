;;; etaf-rss-demo.el --- Run the RSS reader headless -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A non-interactive path into a working reader.  The demo injects a small
;; in-memory client, so it needs no network and no stored data, and prints the
;; state after every step:
;;
;;   emacs -Q --batch -L . -L lisp -L ../etaf -L ../etaf-ui -L ../ebox -L ../ecss \
;;         -l examples/etaf-rss-demo.el
;;
;; For the real reader, put the checkout and its providers on `load-path',
;; then call `etaf-rss-open': it mounts the interface in the selected window.
;; Subscribe with `a', search with `/', read with RET and `SPC', and see `?'
;; for the whole key map.

;;; Code:

(require 'etaf)
(require 'etaf-rss)

(defun etaf-rss-demo--client (request callback)
  "Answer REQUEST from a small in-memory reader."
  (let* ((now (float-time))
         (feed (list :id "demo-feed" :url "https://demo.example/feed"
                     :title "演示订阅" :site "https://demo.example" :folder "演示"
                     :unread 2 :total 3 :updated now :last-fetch now :error nil))
         (feeds (vector feed))
         (rows (apply #'vector
                      (cl-loop for index from 1 to 3
                               collect (list :id (format "demo-%d" index)
                                             :feed "demo-feed"
                                             :feed-title "演示订阅"
                                             :title (format "演示文章 %d" index)
                                             :url (format "https://demo.example/%d" index)
                                             :author "演示作者"
                                             :published (- now (* index 3600))
                                             :summary (format "第 %d 篇的摘要。" index)
                                             :read (= index 3)
                                             :starred (= index 1)))))
         (article (append (aref rows 0)
                          (list :content (concat "<h1>演示文章 1</h1>"
                                                 "<p>这是正文第一段，演示阅读面板如何换行。</p>"
                                                 "<ul><li>要点一</li><li>要点二</li></ul>")))))
    (funcall callback
             (pcase (plist-get request :op)
               (:snapshot (list :ok (list :feeds feeds :total 3 :unread 2 :starred 1
                                          :theme "dark")))
               (:feeds (list :ok (list :feeds feeds :total 3 :unread 2 :starred 1)))
               (:articles (list :ok (list :rows rows :total 3)))
               (:article (list :ok article))
               (:mark-read (list :ok (list :changed 1 :feeds feeds :unread 1
                                           :total 3 :starred 1)))
               (:mark-read-scope (list :ok (list :ids ["demo-1" "demo-2"] :feeds feeds
                                                 :unread 0 :total 3 :starred 1)))
               (:star (list :ok (list :id "demo-1" :feeds feeds :unread 2
                                      :total 3 :starred 1)))
               (:set-theme (list :ok (list :theme "dark")))
               (_ (list :ok (list :feeds feeds :total 3 :unread 2 :starred 1)))))))

(defun etaf-rss-demo-run ()
  "Build a headless reader, walk its main actions and return the session."
  (let ((session (etaf-rss-create :client #'etaf-rss-demo--client)))
    (etaf-rss-refresh session)
    (let ((state (etaf-rss-state session)))
      (princ (format "文章：%d 篇，未读 %d 篇，范围「%s」\n"
                     (plist-get state :list-total)
                     (plist-get state :unread)
                     (plist-get state :scope-label))))
    (etaf-rss-move-selection session 1)
    (etaf-rss-activate-selection session)
    (let ((state (etaf-rss-state session)))
      (princ (format "正在阅读：%s（正文 %d 行，宽 %d 列）\n"
                     (plist-get state :reader-title)
                     (plist-get state :reader-total)
                     (plist-get state :reader-columns))))
    (etaf-rss-toggle-star session)
    (etaf-rss-locate session :starred)
    (princ (format "收藏范围：%d 篇\n" (plist-get (etaf-rss-state session) :list-total)))
    (etaf-rss-search session "演示")
    (princ (format "搜索「演示」：%d 篇\n" (plist-get (etaf-rss-state session) :list-total)))
    (etaf-rss-cancel (plist-get session :client))
    session))

(etaf-rss-demo-run)

(provide 'etaf-rss-demo)
;;; etaf-rss-demo.el ends here
