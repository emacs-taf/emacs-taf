;;; performance-scenarios.el --- etaf-rss interaction workloads -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Maintained workloads for the workspace performance driver.  Each scenario
;; mounts the real reader with a scripted client (no network, no store), so a
;; sample measures the interface: one real public action per sample followed by
;; the publication flush, with the precondition restored by alternating the
;; action direction.  The fixture keeps a wide canvas in both modes; batch
;; Emacs has no window, so the reader keeps the wide layout it uses headless.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-rss)

(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-rss-benchmark--article-count 120
  "Articles in the scripted store; enough rows to page a real list.")

(defconst etaf-rss-benchmark--feed-count 6
  "Feeds in the scripted store, each holding an equal share of the articles.")

(defun etaf-rss-benchmark--article (index)
  "Return benchmark article INDEX as a service row."
  (let ((feed (1+ (% index etaf-rss-benchmark--feed-count)))
        (now (float-time)))
    (list :id (format "bench-%d" index)
          :feed (format "bench-feed-%d" feed)
          :feed-title (format "基准订阅 %d" feed)
          :title (format "第 %d 篇：增量渲染与阅读体验的长期观察" index)
          :url (format "https://bench.example/%d" index)
          :author "基准作者"
          :published (- now (* index 600))
          :summary "这是一段用于列表行的摘要文本，长度接近真实文章。"
          :read (zerop (% index 3))
          :starred (zerop (% index 7)))))

(defun etaf-rss-benchmark--content ()
  "Return the reading-pane HTML of the benchmark article."
  (mapconcat #'identity
             (cl-loop for index from 1 to 40
                      collect (format "<p>第 %d 段正文，用来撑开阅读面板并触发滚动。</p>" index))
             ""))

(defun etaf-rss-benchmark--feeds ()
  "Return the scripted sidebar feeds."
  (apply #'vector
         (cl-loop for feed from 1 to etaf-rss-benchmark--feed-count
                  collect (list :id (format "bench-feed-%d" feed)
                                :url (format "https://bench.example/%d/feed" feed)
                                :title (format "基准订阅 %d" feed)
                                :site "https://bench.example"
                                :folder (if (cl-evenp feed) "偶数组" "奇数组")
                                :unread 20
                                :total (/ etaf-rss-benchmark--article-count
                                          etaf-rss-benchmark--feed-count)
                                :updated (float-time)
                                :last-fetch (float-time)
                                :error nil))))

(defun etaf-rss-benchmark--client (request callback)
  "Answer REQUEST from the scripted store, synchronously."
  (let* ((rows (apply #'vector
                      (cl-loop for index from 1 to etaf-rss-benchmark--article-count
                               collect (etaf-rss-benchmark--article index))))
         (feeds (etaf-rss-benchmark--feeds))
         (first (append (aref rows 0) (list :content (etaf-rss-benchmark--content))))
         (total (length rows)))
    (funcall callback
             (pcase (plist-get request :op)
               (:snapshot (list :ok (list :feeds feeds :total total
                                          :unread (- total 40) :starred 18 :theme "dark")))
               (:feeds (list :ok (list :feeds feeds :total total
                                       :unread (- total 40) :starred 18)))
               (:articles (list :ok (list :rows rows :total total)))
               (:article (list :ok first))
               (:mark-read (list :ok (list :changed 1 :feeds feeds :unread (- total 41)
                                           :total total :starred 18)))
               (:mark-read-scope (list :ok (list :ids ["bench-1"] :feeds feeds
                                                 :unread 0 :total total :starred 18)))
               (:star (list :ok (list :id "bench-1" :feeds feeds :unread (- total 40)
                                      :total total :starred 19)))
               (:set-theme (list :ok (list :theme "dark")))
               (_ (list :ok (list :feeds feeds :total total
                                  :unread (- total 40) :starred 18)))))))

(defun etaf-rss-benchmark--selected-title (model)
  "Return the title of MODEL's selected row."
  (plist-get (etaf-rss--selected-row model) :title))

(defun etaf-rss-benchmark--title-prefix (title)
  "Return the visible prefix of a list TITLE.
The list column clips long titles, so a painted-row check compares the part
that is always on screen."
  (substring title 0 (min 6 (length title))))

(defun etaf-rss-benchmark--painted-p (buffer text)
  "Return non-nil when BUFFER's canvas contains TEXT."
  (with-current-buffer buffer
    (string-match-p (regexp-quote text) (buffer-substring-no-properties
                                         (point-min) (point-max)))))

(defconst etaf-rss-benchmark--batch-canvas
  (list :viewport-width 1440 :viewport-height 44)
  "Fixed canvas for batch Emacs, which has no window to fit.
It equals a wide frame, so batch workloads paint the same three columns a GUI
window would.")

(defun etaf-rss-benchmark--fixture (operation mode)
  "Return the benchmark fixture for OPERATION in MODE.
MODE is `batch' or `gui'; both mount the reader in a fresh buffer with the
scripted client and leave it ready for timed samples."
  (let* ((model (etaf-rss-create :client #'etaf-rss-benchmark--client))
         (buffer (generate-new-buffer " *etaf-rss-benchmark*"))
         (samples 0)
         (scroll 0)
         (scope :all))
    (plist-put model :buffer buffer)
    (if (eq mode 'batch)
        (etaf-mount buffer (etaf-rss-view model) etaf-rss-benchmark--batch-canvas)
      (etaf-mount buffer (etaf-rss-view model)))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    (etaf-rss-refresh model)
    ;; The scripted replies arrive on the event loop, so give them one tick
    ;; before the timed samples start.
    (let ((deadline (+ (float-time) 1)))
      (while (and (zerop (length (etaf-rss--read model :rows)))
                  (< (float-time) deadline))
        (sleep-for 0.01)))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    (when (eq operation 'scroll)
      (etaf-rss-activate-selection model)
      (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
    (list
     :buffer buffer
     :invoke
     (lambda (_sample)
       (cl-incf samples)
       (pcase operation
         ('selection
          (etaf-rss-move-selection model (if (cl-oddp samples) 1 -1)))
         ('page
          (etaf-rss-move-selection model (if (cl-oddp samples) 10 -10)))
         ('scroll
          (setq scroll (if (cl-oddp samples) (1+ scroll) (max 0 (1- scroll))))
          (etaf-rss-scroll-reader model (if (cl-oddp samples) 1 -1)))
         ('scope
          (setq scope (if (eq scope :all) :unread :all))
          (etaf-rss-locate model scope)))
       (etaf-runtime-flush (etaf-runtime-for-buffer buffer)))
     :settled (lambda () t)
     :outcome (lambda () (list :samples samples))
     :verify
     (lambda ()
       (pcase operation
         ('selection
          (if (etaf-rss-benchmark--painted-p
               buffer (etaf-rss-benchmark--title-prefix
                       (etaf-rss-benchmark--selected-title model)))
              t
            "The selected row title is not painted"))
         ('page
          (if (etaf-rss-benchmark--painted-p
               buffer (etaf-rss-benchmark--title-prefix
                       (etaf-rss-benchmark--selected-title model)))
              t
            "The paged row title is not painted"))
         ('scroll
          (let ((state (etaf-rss-state model)))
            (if (and (>= (plist-get state :reader-scroll) 0)
                     (< (plist-get state :reader-scroll)
                        (max 1 (plist-get state :reader-total))))
                t
              "The reading scroll left its range")))
         ('scope
          (if (equal (plist-get (etaf-rss-state model) :scope)
                     (list :kind scope))
              t
            "The scope did not switch"))))
     :cleanup
     (lambda ()
       (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
         (etaf-unmount runtime))
       (when (buffer-live-p buffer) (kill-buffer buffer))))))

(dolist (operation '(selection page scroll scope))
  (taf-benchmark-register
   (format "etaf-rss.browse.%s" operation)
   :version 1 :modes '(batch gui) :budget-ms 50 :impact 'local
   :required-providers '(etaf-ui)
   :description (format "RSS reader %s on a mounted 120-article reader" operation)
   :setup (let ((selected operation))
            (lambda (mode) (etaf-rss-benchmark--fixture selected mode)))))
