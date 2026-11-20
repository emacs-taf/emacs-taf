;;; -*- lexical-binding: t; -*-
;;; etaf-bili-model.el --- Library state and asynchronous actions

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The session owns the library, selection, query and asynchronous request
;; identities.  UI resources are attached by the application, not by views.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-bili-theme)
(require 'etaf-bili-service)

(cl-defstruct (etaf-bili--session (:constructor etaf-bili--session--make))
  "Library state and application-owned resources."
  client buffer mode keyword items selected status loading request playback
  mode-ref status-ref items-ref selected-ref loading-ref playback-ref
  theme-ref layout-ref query-ref error-ref play-loading-ref
  details-ref visible-row-ref disposed (play-request 0) on-change
  account-ref login-ref
  ;; The row whose stream was already resolved, and its source, so a second
  ;; press on the same card plays without asking the site again.
  play-bvid play-source
  (covers (make-hash-table :test #'equal)) cover-queue (cover-active 0)
  processes)

(cl-defun etaf-bili-session-create (&key client)
  "Create a headless session with CLIENT, or `etaf-bili-client-factory'.
Nil factory selects the default curl client.  Creation sends no requests."
  (etaf-bili--session--make
   :client (or client (if etaf-bili-client-factory
                         (funcall etaf-bili-client-factory)
                       (etaf-bili-make-client)))
   :mode 'popular :selected 0 :status "就绪" :request 0
   :mode-ref (etaf-ref 'popular) :status-ref (etaf-ref "就绪")
   :items-ref (etaf-ref nil) :selected-ref (etaf-ref 0)
   :loading-ref (etaf-ref nil) :playback-ref (etaf-ref nil)
   :theme-ref (etaf-ref (etaf-bili-theme-defaults))
   :layout-ref (etaf-ref nil :test #'equal) :query-ref (etaf-ref "")
   :error-ref (etaf-ref nil) :play-loading-ref (etaf-ref nil) :details-ref (etaf-ref nil)
   :visible-row-ref (etaf-ref 0)
   ;; The account name the backend reported, nil while signed out, and the
   ;; sign-in overlay: :open, :qr and :status.
   :account-ref (etaf-ref nil) :login-ref (etaf-ref nil)
   :play-bvid nil :play-source nil))

(defun etaf-bili--status (session text)
  "Set SESSION's displayed status to TEXT."
  (setf (etaf-bili--session-status session) text)
  (etaf-set-value (etaf-bili--session-status-ref session) text))

(defun etaf-bili--notify (session &optional reset)
  "Notify SESSION's application; RESET requests the new library's beginning."
  (when (etaf-bili--session-on-change session)
    (funcall (etaf-bili--session-on-change session) reset)))

(defun etaf-bili--request (session request label)
  "Replace SESSION's library with REQUEST, rejecting stale responses."
  (unless (etaf-bili--session-disposed session)
    (let ((token (cl-incf (etaf-bili--session-request session))))
      (cl-incf (etaf-bili--session-play-request session))
      (setf (etaf-bili--session-loading session) t)
      (etaf-batch
        (etaf-set-value (etaf-bili--session-loading-ref session) t)
        (etaf-set-value (etaf-bili--session-error-ref session) nil)
        (etaf-set-value (etaf-bili--session-play-loading-ref session) nil)
        (etaf-bili--status session (format "%s · 加载中…" label)))
      (etaf-bili-client-call
       (etaf-bili--session-client session) request
       (lambda (reply)
         (when (and (not (etaf-bili--session-disposed session))
                    (= token (etaf-bili--session-request session)))
           (setf (etaf-bili--session-loading session) nil)
           (etaf-batch
             (etaf-set-value (etaf-bili--session-loading-ref session) nil)
             (if (plist-member reply :ok)
                 (let ((items (cl-delete-duplicates
                               (copy-sequence (plist-get reply :ok))
                               :key (lambda (row) (plist-get row :bvid))
                               :test #'equal :from-end t)))
                   (setf (etaf-bili--session-items session) items
                         (etaf-bili--session-selected session) 0)
                   ;; Cover refs are prepared before publishing new cards.
                   (etaf-bili--notify session t)
                   (etaf-set-value (etaf-bili--session-items-ref session) items)
                   (etaf-set-value (etaf-bili--session-selected-ref session) 0)
                   (etaf-bili--status session (format "%s · %d 条" label (length items))))
               (let ((error (or (plist-get reply :error) "请求失败，请重试")))
                 (etaf-set-value (etaf-bili--session-error-ref session) error)
                 (etaf-bili--status session (format "%s · %s" label error)))))))))))

(defun etaf-bili-load-popular (session)
  "Load the popular feed into SESSION."
  (etaf-batch
    (setf (etaf-bili--session-mode session) 'popular
          (etaf-bili--session-keyword session) nil)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'popular)
    (etaf-bili--request session '(:op :popular) "热门")))

(defun etaf-bili-load-ranking (session)
  "Load the all-category ranking into SESSION."
  (etaf-batch
    (setf (etaf-bili--session-mode session) 'ranking
          (etaf-bili--session-keyword session) nil)
    (etaf-set-value (etaf-bili--session-mode-ref session) 'ranking)
    (etaf-bili--request session '(:op :ranking) "排行榜")))

(defun etaf-bili-search (session keyword)
  "Search videos for KEYWORD in SESSION; ignore whitespace-only queries."
  (unless (string-empty-p (string-trim keyword))
    (etaf-batch
      (setf (etaf-bili--session-mode session) 'search
            (etaf-bili--session-keyword session) keyword)
      (etaf-set-value (etaf-bili--session-query-ref session) keyword)
      (etaf-set-value (etaf-bili--session-mode-ref session) 'search)
      (etaf-bili--request session (list :op :search :keyword keyword)
                          (format "搜索 %s" keyword)))))

(defun etaf-bili-session-state (session)
  "Return a detached snapshot of SESSION.
Keys are :mode, :keyword, :status, :loading, :items, :selected, :playback,
:error, :play-loading, :account and :login.  :account is the signed-in name
or nil, and :login is the sign-in overlay state (:open :qr :status).  Empty
successful results have nil :error."
  (copy-tree
   (list :mode (etaf-bili--session-mode session)
         :keyword (etaf-bili--session-keyword session)
         :status (etaf-bili--session-status session)
         :loading (and (etaf-bili--session-loading session) t)
         :items (etaf-bili--session-items session)
         :selected (etaf-bili--session-selected session)
         :playback (etaf-bili--session-playback session)
         :error (etaf-value (etaf-bili--session-error-ref session))
         :play-loading (etaf-value (etaf-bili--session-play-loading-ref session))
         :account (etaf-value (etaf-bili--session-account-ref session))
         :login (etaf-value (etaf-bili--session-login-ref session)))))

(defun etaf-bili-reload (session)
  "Reload SESSION's current feed or search."
  (pcase (etaf-bili--session-mode session)
    ('ranking (etaf-bili-load-ranking session))
    ('search (etaf-bili-search session (or (etaf-bili--session-keyword session) "")))
    (_ (etaf-bili-load-popular session))))

(defun etaf-bili-move (session delta)
  "Move SESSION's selection DELTA places, clamping at the endpoints."
  (let ((count (length (etaf-bili--session-items session))))
    (when (> count 0)
      (let ((next (max 0 (min (1- count) (+ (etaf-bili--session-selected session) delta)))))
        (setf (etaf-bili--session-selected session) next)
        (etaf-set-value (etaf-bili--session-selected-ref session) next)
        (etaf-bili--notify session)))))

(defun etaf-bili-selected-row (session)
  "Return SESSION's selected video or nil."
  (nth (etaf-bili--session-selected session) (etaf-bili--session-items session)))

(defun etaf-bili-play-selected (session on-ready)
  "Resolve SESSION's selected stream and call ON-READY with its source.
A card whose stream was already resolved plays immediately: the site's
play URL expires in hours, not seconds, so asking again would only add
latency to every press.  Any other card asks once and then remembers the
source.  Only the latest play request may complete; failure keeps the
library and reports :error, and a closed session cannot reopen playback."
  (when-let* ((row (etaf-bili-selected-row session)))
    (let ((bvid (plist-get row :bvid)))
      (if (and (equal bvid (etaf-bili--session-play-bvid session))
               (plist-get (etaf-bili--session-play-source session) :url))
          (let ((source (etaf-bili--session-play-source session)))
            (etaf-bili--status session (format "播放：%s" (or (plist-get source :title)
                                                              (plist-get row :title))))
            (funcall on-ready source))
        (let ((token (cl-incf (etaf-bili--session-play-request session))))
          (etaf-batch
            (etaf-set-value (etaf-bili--session-play-loading-ref session) t)
            (etaf-set-value (etaf-bili--session-error-ref session) nil)
            (etaf-bili--status session "正在获取播放地址…"))
          (etaf-bili-client-call
           (etaf-bili--session-client session) (list :op :play :bvid bvid)
           (lambda (reply)
             (when (and (not (etaf-bili--session-disposed session))
                        (= token (etaf-bili--session-play-request session)))
               (etaf-batch
                 (etaf-set-value (etaf-bili--session-play-loading-ref session) nil)
                 (if-let* ((source (plist-get reply :ok)))
                     (progn
                       (setf (etaf-bili--session-play-bvid session) bvid
                             (etaf-bili--session-play-source session) source)
                       (etaf-bili--status session (format "播放：%s" (or (plist-get source :title)
                                                                         (plist-get row :title))))
                       (funcall on-ready source))
                   (let ((error (or (plist-get reply :error) "未知错误")))
                     (etaf-set-value (etaf-bili--session-error-ref session) error)
                     (etaf-bili--status session (concat "播放失败：" error)))))))))))))

(provide 'etaf-bili-model)
