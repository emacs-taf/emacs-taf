;;; etaf-md-cache.el --- Remote image async cache and disk cache hygiene -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Thin Markdown session adapter over `etaf-doc-cache' for bounded LRU disk
;; hygiene and non-blocking remote HTTP(S) image caching.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-doc)

(declare-function etaf-md--read "etaf-md-model" (session key))
(declare-function etaf-md--refresh-block-assets "etaf-md-model" (session))

(defcustom etaf-md-remote-images t
  "Whether displayed previews asynchronously download remote HTTP(S) images.
When non-nil, remote image URLs in mounted previews are fetched in the
background into the local cache directory and repainted in place once ready.
Headless sessions created by `etaf-md-create' never perform network I/O."
  :type 'boolean
  :group 'etaf-md)

(defcustom etaf-md-cache-max-bytes (* 100 1024 1024)
  "Maximum total size in bytes retained per `etaf-md' disk cache directory.
When a cache directory (`typeset/', `qrcode/' or `images/') exceeds this cap or
`etaf-md-cache--max-files', the least recently modified entries are removed
lazily on idle."
  :type 'integer
  :group 'etaf-md)

(defconst etaf-md-cache--root-directory
  (expand-file-name "etaf-md/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Root cache directory shared by `etaf-md' asset caches.")

(defconst etaf-md-cache--image-directory
  (expand-file-name "images/" etaf-md-cache--root-directory)
  "Directory storing asynchronously cached remote images.")

(defconst etaf-md-cache--max-images-per-page 30
  "Maximum remote images queued per document pass.")

(defconst etaf-md-cache--max-files 512
  "Maximum files retained in one cache directory before LRU pruning.")

(defun etaf-md-cache-prune-directory (directory &optional max-bytes max-files)
  "Schedule lazy LRU pruning of DIRECTORY to stay under MAX-BYTES and MAX-FILES."
  (etaf-doc-cache-prune-directory
   directory
   (or max-bytes etaf-md-cache-max-bytes)
   (or max-files etaf-md-cache--max-files)))

(defun etaf-md-cache--http-url-p (url)
  "Return non-nil when URL is an `http://' or `https://' URL."
  (etaf-doc-cache-http-url-p url))

(defun etaf-md-cache-image-path (url)
  "Return local cached image path for remote URL from memory, or nil.
Never touches the network or filesystem, so it is safe during render."
  (etaf-doc-cache-image-path url))

(defun etaf-md-cache--extract-block-urls (block)
  "Return unique HTTP(S) image URLs referenced inside parsed BLOCK."
  (let ((urls nil))
    (cl-labels
        ((maybe (url)
           (when (etaf-doc-cache-http-url-p url)
             (push (string-trim url) urls)))
         (walk-inline (node)
           (when (and (listp node) (keywordp (car node)))
             (pcase (plist-get node :type)
               ('image
                (maybe (plist-get node :url)))
               ('html
                (let ((text (or (plist-get node :text) ""))
                      (pos 0)
                      (case-fold-search t))
                  (while (string-match "<img\\b[^>]*\\bsrc=[\"']\\(https?://[^\"']+\\)[\"']"
                                       text pos)
                    (maybe (match-string 1 text))
                    (setq pos (match-end 0))))))
             (dolist (child (plist-get node :children))
               (walk-inline child))))
         (walk-block (b)
           (when (and (listp b) (keywordp (car b)))
             (pcase (plist-get b :type)
               ((or 'paragraph 'heading)
                (dolist (ch (plist-get b :children)) (walk-inline ch)))
               ('html-block
                (let ((text (or (plist-get b :text) ""))
                      (pos 0)
                      (case-fold-search t))
                  (while (string-match "<img\\b[^>]*\\bsrc=[\"']\\(https?://[^\"']+\\)[\"']"
                                       text pos)
                    (maybe (match-string 1 text))
                    (setq pos (match-end 0)))))
               ((or 'blockquote 'container 'list-item)
                (dolist (ch (plist-get b :children)) (walk-block ch)))
               ('list
                (dolist (item (plist-get b :items))
                  (dolist (ch (plist-get item :children)) (walk-block ch))))
               ('table
                (dolist (cell (plist-get b :header))
                  (dolist (ch cell) (walk-inline ch)))
                (dolist (row (plist-get b :rows))
                  (dolist (cell row)
                    (dolist (ch cell) (walk-inline ch)))))))))
      (walk-block block))
    (delete-dups (nreverse urls))))

(defun etaf-md-cache--notify-session (session)
  "Coalesce repaint of SESSION after cached remote images become ready."
  (when (and (buffer-live-p (plist-get session :buffer))
             (not (plist-get session :image-refresh-pending)))
    (plist-put session :image-refresh-pending t)
    (run-at-time 0.12 nil
                 (lambda ()
                   (plist-put session :image-refresh-pending nil)
                   (when (and (buffer-live-p (plist-get session :buffer))
                              (fboundp 'etaf-md--refresh-block-assets))
                     (etaf-md--refresh-block-assets session))))))

(defun etaf-md-cache-warm-block (block)
  "Populate in-memory image cache from disk for any remote image URLs in BLOCK.
Called outside `:render' during publishing; performs no network I/O."
  (when etaf-md-remote-images
    (etaf-doc-cache-warm-urls
     (etaf-md-cache--extract-block-urls block)
     etaf-md-cache--image-directory))
  block)

(defun etaf-md-cache-request-images (session)
  "Queue asynchronous downloads for uncached remote images in mounted SESSION.
Does nothing when `etaf-md-remote-images' is nil or SESSION has no live buffer."
  (when (and etaf-md-remote-images
             (buffer-live-p (plist-get session :buffer)))
    (let ((urls nil))
      (dolist (entry (plist-get (etaf-md--read session :document) :children))
        (dolist (url (etaf-md-cache--extract-block-urls (plist-get entry :block)))
          (push url urls)))
      (when urls
        (etaf-doc-cache-request-urls
         (nreverse urls)
         (lambda () (etaf-md-cache--notify-session session))
         (list :directory etaf-md-cache--image-directory
               :max-bytes etaf-md-cache-max-bytes
               :max-files etaf-md-cache--max-files
               :max-per-page etaf-md-cache--max-images-per-page
               :live-p (lambda () (buffer-live-p (plist-get session :buffer)))))))))

(provide 'etaf-md-cache)
;;; etaf-md-cache.el ends here
