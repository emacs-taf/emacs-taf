;;; etaf-org-cache.el --- Remote image async cache and disk cache hygiene -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Thin Org session adapter over `etaf-doc-cache' for bounded LRU disk hygiene
;; and non-blocking remote HTTP(S) image caching.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-doc)

(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--refresh-block-assets "etaf-org-model" (session))
(declare-function etaf-org--walk-document-blocks "etaf-org-model" (document fn))

(defcustom etaf-org-remote-images t
  "Whether displayed previews asynchronously download remote HTTP(S) images.
When non-nil, remote image URLs in mounted previews are fetched in the
background into the local cache directory and repainted in place once ready.
Headless sessions created by `etaf-org-create' never perform network I/O."
  :type 'boolean
  :group 'etaf-org)

(defcustom etaf-org-cache-max-bytes (* 100 1024 1024)
  "Maximum total size in bytes retained per `etaf-org' disk cache directory.
When a cache directory (`typeset/', `qrcode/', `images/', `pdf/' or
`diagrams/') exceeds this cap or `etaf-org-cache--max-files', the least
recently modified entries are removed lazily on idle."
  :type 'integer
  :group 'etaf-org)

(defconst etaf-org-cache--root-directory
  (expand-file-name "etaf-org/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Root cache directory shared by `etaf-org' asset caches.")

(defconst etaf-org-cache--image-directory
  (expand-file-name "images/" etaf-org-cache--root-directory)
  "Directory storing asynchronously cached remote images.")

(defconst etaf-org-cache--max-images-per-page 30
  "Maximum remote images queued per document pass.")

(defconst etaf-org-cache--max-files 512
  "Maximum files retained in one cache directory before LRU pruning.")

(defun etaf-org-cache-prune-directory (directory &optional max-bytes max-files)
  "Schedule lazy LRU pruning of DIRECTORY to stay under MAX-BYTES and MAX-FILES."
  (etaf-doc-cache-prune-directory
   directory
   (or max-bytes etaf-org-cache-max-bytes)
   (or max-files etaf-org-cache--max-files)))

(defun etaf-org-cache--http-url-p (url)
  "Return non-nil when URL is an `http://' or `https://' URL."
  (etaf-doc-cache-http-url-p url))

(defun etaf-org-cache--image-url-p (url)
  "Return non-nil when remote URL points to an image extension."
  (etaf-doc-cache-image-url-p url))

(defun etaf-org-cache-image-path (url)
  "Return local cached image path for remote URL from memory, or nil.
Never touches the network or filesystem, so it is safe during render."
  (etaf-doc-cache-image-path url))

(defun etaf-org-cache--extract-block-urls (block)
  "Return unique HTTP(S) image URLs referenced inside parsed Org BLOCK."
  (let ((urls nil))
    (cl-labels
        ((maybe (url)
           (when (etaf-doc-cache-image-url-p url)
             (push (string-trim url) urls)))
         (walk-block (b)
           (when (and (listp b) (keywordp (car b)))
             (when-let* ((media (plist-get b :media))
                         (remote (plist-get media :remote-url)))
               (maybe remote))
             (when (and (eq (plist-get b :type) 'special-block)
                        (equal (plist-get b :name) "image-card"))
               (maybe (plist-get (plist-get b :attrs) :src)))
             (when (eq (plist-get b :type) 'table)
               (dolist (row (plist-get b :rows))
                 (dolist (cell (plist-get row :cells))
                   (dolist (node (plist-get cell :inlines))
                     (when-let* ((media (plist-get node :media))
                                 (remote (plist-get media :remote-url)))
                       (maybe remote))
                     (when (and (eq (plist-get node :type) 'link)
                                (eq (plist-get node :kind) 'url))
                       (maybe (plist-get node :target)))))))
             (dolist (ch (plist-get b :blocks)) (walk-block ch))
             (dolist (ch (plist-get b :children)) (walk-block ch))
             (dolist (item (plist-get b :items))
               (dolist (ch (plist-get item :blocks)) (walk-block ch))))))
      (walk-block block))
    (delete-dups (nreverse urls))))

(defun etaf-org-cache--notify-session (session)
  "Coalesce repaint of SESSION after cached remote images become ready."
  (when (and (buffer-live-p (plist-get session :buffer))
             (not (plist-get session :image-refresh-pending)))
    (plist-put session :image-refresh-pending t)
    (run-at-time 0.12 nil
                 (lambda ()
                   (plist-put session :image-refresh-pending nil)
                   (when (and (buffer-live-p (plist-get session :buffer))
                              (fboundp 'etaf-org--refresh-block-assets))
                     (etaf-org--refresh-block-assets session))))))

(defun etaf-org-cache-warm-block (block)
  "Populate in-memory image cache from disk for any remote image URLs in BLOCK.
Called outside `:render' during publishing; performs no network I/O."
  (when etaf-org-remote-images
    (etaf-doc-cache-warm-urls
     (etaf-org-cache--extract-block-urls block)
     etaf-org-cache--image-directory))
  block)

(defun etaf-org-cache-request-images (session)
  "Queue asynchronous downloads for uncached remote images in mounted SESSION.
Does nothing when `etaf-org-remote-images' is nil or SESSION has no live buffer."
  (when (and etaf-org-remote-images
             (buffer-live-p (plist-get session :buffer))
             (fboundp 'etaf-org--walk-document-blocks))
    (let ((urls nil))
      (etaf-org--walk-document-blocks
       (etaf-org--read session :document)
       (lambda (block)
         (dolist (url (etaf-org-cache--extract-block-urls block))
           (push url urls))))
      (when urls
        (etaf-doc-cache-request-urls
         (nreverse urls)
         (lambda () (etaf-org-cache--notify-session session))
         (list :directory etaf-org-cache--image-directory
               :max-bytes etaf-org-cache-max-bytes
               :max-files etaf-org-cache--max-files
               :max-per-page etaf-org-cache--max-images-per-page
               :live-p (lambda () (buffer-live-p (plist-get session :buffer)))))))))

(provide 'etaf-org-cache)
;;; etaf-org-cache.el ends here
