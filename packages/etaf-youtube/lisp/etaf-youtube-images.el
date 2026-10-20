;;; etaf-youtube-images.el --- Asynchronous thumbnail cache -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Thumbnails are remote images, so a view never blocks on the network: the
;; model requests a URL, the cache returns nil until the download completes,
;; and a version ref repaints only the cells that bind it.  Files are kept in
;; a cache directory keyed by a URL digest, so reopening the application
;; reuses them without another request.
;;
;; Downloads use curl.  When the youtube skill has recorded a working proxy
;; route, that proxy is tried first (with `no_proxy' removed, because an
;; inherited `no_proxy=*' would otherwise defeat an explicit -x); a direct
;; attempt follows.  The fetch boundary is injectable for offline tests.

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'json)
(require 'subr-x)
(require 'etaf)

(defcustom etaf-youtube-images-directory
  (locate-user-emacs-file "etaf-youtube/thumbnails/")
  "Directory holding cached thumbnail files."
  :type 'directory
  :group 'etaf-youtube)

(defcustom etaf-youtube-image-timeout 25
  "Seconds curl may spend on one thumbnail."
  :type 'number
  :group 'etaf-youtube)

(defcustom etaf-youtube-image-workers 4
  "How many thumbnail downloads may run at once."
  :type 'integer
  :group 'etaf-youtube)

(cl-defstruct (etaf-youtube-images (:constructor etaf-youtube--images--make))
  "Thumbnail cache with bounded asynchronous downloads."
  directory fetcher proxy-fn cache queue active cancels version-ref)

(defun etaf-youtube--fetch-url (url)
  "Return URL as it should be downloaded.
YouTube signs thumbnail URLs with a query token that makes its CDN answer
with AVIF, which Emacs may not decode; the unsigned URL serves the same
JPEG thumbnail, so the token is dropped for i.ytimg.com images."
  (if (string-prefix-p "https://i.ytimg.com/" url)
      (if-let* ((query (string-search "?" url)))
          (substring url 0 query)
        url)
    url))

(defun etaf-youtube--route-proxy ()
  "Return the proxy URL the youtube skill recorded, or nil.
The skill documents `local/skills/youtube/route.json' schema 1 as route
state containing only the route and probe time."
  (let ((file (expand-file-name
               "local/skills/youtube/route.json"
               (or (getenv "PI_CODING_AGENT_DIR")
                   (expand-file-name "~/.pi/agent")))))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (plist-get (json-parse-buffer :object-type 'plist) :proxy))
        (error nil)))))

(defconst etaf-youtube--proxy-variables
  '("http_proxy" "https_proxy" "all_proxy" "no_proxy"
    "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" "NO_PROXY")
  "Environment variables unset for curl, which receives its route explicitly.")

(defun etaf-youtube--curl-attempt (url file proxy callback)
  "Download URL into FILE through PROXY and call CALLBACK with error and status.
PROXY may be nil for a direct request.  Status is the HTTP code, or zero
on transport failure.  Return a cancel function."
  (let ((job (etaf-process-run
              (list "curl" "-fsSL" "--max-time"
                    (number-to-string etaf-youtube-image-timeout)
                    "--connect-timeout" "10"
                    "--noproxy" (if proxy "" "*")
                    "--proxy" (or proxy "")
                    "--write-out" "%{http_code}"
                    "-o" file url)
              :name "etaf-youtube-image"
              ;; An entry without `=' removes the variable for the child.
              :environment etaf-youtube--proxy-variables
              :callback
              (lambda (result)
                (let ((http-status (string-to-number
                                    (or (plist-get result :output) "")))
                      (message (string-trim (or (plist-get result :stderr) ""))))
                  (cond
                   ((and (eq (plist-get result :status) 'exit)
                         (eql (plist-get result :exit) 0)
                         (file-exists-p file)
                         (> (or (file-attribute-size (file-attributes file)) 0) 0))
                    (funcall callback nil http-status))
                   ((eq (plist-get result :status) 'failed)
                    (funcall callback (plist-get result :message) 0))
                   (t
                    (funcall callback
                             (if (string-empty-p message)
                                 (format "curl exited with status %s"
                                         (plist-get result :exit))
                               message)
                             http-status))))))))
    (lambda () (etaf-process-cancel job))))

(defun etaf-youtube--default-fetcher (images url file callback)
  "Download URL into FILE for IMAGES and call CALLBACK with nil or an error.
The configured route is tried first; transport failures may try direct.
A missing YouTube thumbnail variant falls back once to its standard JPEG
on the same working route.  HTTP errors never trigger pointless route probes.
Return a cancel function."
  (let* ((proxy (ignore-errors (funcall (etaf-youtube-images-proxy-fn images))))
         (fallback (when (and (string-match
                              "\\`https://i\\.ytimg\\.com/vi/\\([A-Za-z0-9_-]+\\)/" url)
                             (not (string-suffix-p "/hqdefault.jpg" url)))
                     (format "https://i.ytimg.com/vi/%s/hqdefault.jpg"
                             (match-string 1 url))))
         (cancelled nil)
         (cancel nil))
    (cl-labels
        ((attempt
          (target routes fallback-url)
          (unless cancelled
            (setq cancel
                  (etaf-youtube--curl-attempt
                   target file (car routes)
                   (lambda (error &optional status)
                     (cond
                      (cancelled nil)
                      ((null error) (funcall callback nil))
                      ((and (eq status 404) fallback-url)
                       (attempt fallback-url routes nil))
                      ((and (or (null status) (zerop status)) (cdr routes))
                       (attempt target (cdr routes) fallback-url))
                      (t (funcall callback error)))))))))
      (attempt url (if proxy (list proxy nil) (list nil)) fallback))
    (lambda ()
      (setq cancelled t)
      (when (and cancel (functionp cancel)) (ignore-errors (funcall cancel))))))

(cl-defun etaf-youtube-images-create (&key directory fetcher proxy-fn)
  "Create a thumbnail cache.
DIRECTORY defaults to `etaf-youtube-images-directory'; FETCHER defaults to
the curl-based downloader and receives (IMAGES URL FILE CALLBACK); PROXY-FN
returns an optional proxy URL and defaults to the skill route state."
  (etaf-youtube--images--make
   :directory (file-name-as-directory
               (or directory etaf-youtube-images-directory))
   :fetcher (or fetcher #'etaf-youtube--default-fetcher)
   :proxy-fn (or proxy-fn #'etaf-youtube--route-proxy)
   :cache (make-hash-table :test #'equal)
   :queue nil
   :active 0
   :cancels (make-hash-table :test #'equal)
   :version-ref (etaf-ref 0 :name 'etaf-youtube-image-version)))

(defun etaf-youtube-images-version (images)
  "Return IMAGES's completion version ref."
  (etaf-youtube-images-version-ref images))

(defun etaf-youtube--images-bump (images)
  "Increment IMAGES's version so bound cells repaint."
  (setf (etaf-value (etaf-youtube-images-version-ref images))
        (1+ (or (etaf-value (etaf-youtube-images-version-ref images)) 0))))

(defun etaf-youtube--image-file (images url)
  "Return IMAGES's cached image file for URL, or nil."
  (let* ((directory (etaf-youtube-images-directory images))
         (stem (secure-hash 'sha1 url)))
    (when (file-directory-p directory)
      (car (directory-files directory t
                            (concat "\\`" (regexp-quote stem) "\\.[a-z]+\\'")
                            t)))))

(defun etaf-youtube-images-descriptor (images url)
  "Return URL's image descriptor from IMAGES, or nil while it is not ready.
Requesting is done by `etaf-youtube-images-request'; this function never
starts work, so a render stays free of side effects."
  (when (and url (not (string-empty-p url)))
    (plist-get (gethash url (etaf-youtube-images-cache images)) :image)))

(defun etaf-youtube-images-request (images url)
  "Ensure URL is downloaded into IMAGES.
A URL already cached, queued, failed or in flight is left alone.  Return
non-nil when the request is new."
  (when (and url (not (string-empty-p url)))
    (unless (gethash url (etaf-youtube-images-cache images))
      (puthash url (list :status 'queued) (etaf-youtube-images-cache images))
      (setf (etaf-youtube-images-queue images)
            (append (etaf-youtube-images-queue images) (list url)))
      (etaf-youtube--images-pump images)
      t)))

(defun etaf-youtube--images-pump (images)
  "Start queued IMAGES downloads while workers are available."
  (while (and (etaf-youtube-images-queue images)
              (< (etaf-youtube-images-active images)
                 (max 1 etaf-youtube-image-workers)))
    (let* ((url (pop (etaf-youtube-images-queue images)))
           (file (etaf-youtube--image-file images url)))
      (cond
       (file
        (etaf-youtube--images-finish images url file nil)
        (etaf-youtube--images-bump images))
       ((eq (plist-get (gethash url (etaf-youtube-images-cache images)) :status)
            'loading)
        nil)
       (t
        (puthash url (list :status 'loading) (etaf-youtube-images-cache images))
        (let* ((directory (etaf-youtube-images-directory images))
               (fetcher (etaf-youtube-images-fetcher images)))
          (condition-case error
              (progn
                (ignore-errors (make-directory directory t))
                (cl-incf (etaf-youtube-images-active images))
                (let ((target (expand-file-name (concat (secure-hash 'sha1 url)
                                                        ".part")
                                                directory))
                      (cancel nil))
                  (setq cancel
                        (funcall fetcher images (etaf-youtube--fetch-url url) target
                                 (lambda (problem)
                                   (cl-decf (etaf-youtube-images-active images))
                                   (remhash url (etaf-youtube-images-cancels images))
                                   (if problem
                                       (progn
                                         (ignore-errors (delete-file target))
                                         (puthash url (list :status 'error
                                                            :message problem)
                                                  (etaf-youtube-images-cache images))
                                         (etaf-youtube--images-bump images))
                                     (etaf-youtube--images-finish
                                      images url target nil))
                                   (etaf-youtube--images-pump images))))
                  (when (eq (plist-get (gethash url
                                                (etaf-youtube-images-cache images))
                                       :status)
                            'loading)
                    (puthash url cancel
                             (etaf-youtube-images-cancels images)))))
            (error
             (cl-decf (etaf-youtube-images-active images))
             (puthash url (list :status 'error
                                :message (error-message-string error))
                      (etaf-youtube-images-cache images))
             (etaf-youtube--images-bump images)))))))))

(defun etaf-youtube--images-finish (images url file error)
  "Record URL's downloaded FILE in IMAGES, or its ERROR.
The temporary file is renamed to its image extension before the descriptor
is created, so the descriptor never points at the removed temporary path."
  (if (and file (null error))
      (condition-case problem
          (let ((type (image-type-from-file-header file)))
            (if (null type)
                (progn
                  (ignore-errors (delete-file file))
                  (puthash url (list :status 'error
                                     :message "not a recognized image")
                           (etaf-youtube-images-cache images)))
              (let* ((target (concat (file-name-sans-extension file)
                                     "." (symbol-name type)))
                     (final (cond
                             ;; An already-cached file is used as it is;
                             ;; deleting the target here would delete the
                             ;; cache entry itself.
                             ((equal file target) file)
                             ((file-exists-p target)
                              (ignore-errors (delete-file file))
                              target)
                             (t (rename-file file target t) target)))
                     (image (create-image final type nil)))
                (if (null image)
                    (progn
                      (ignore-errors (delete-file final))
                      (puthash url (list :status 'error
                                         :message "cannot decode the image")
                               (etaf-youtube-images-cache images)))
                  (puthash url (list :status 'ready :file final :image image)
                           (etaf-youtube-images-cache images))))))
        (error
         (ignore-errors (delete-file file))
         (puthash url (list :status 'error
                            :message (error-message-string problem))
                  (etaf-youtube-images-cache images))))
    (puthash url (list :status 'error :message (or error "download failed"))
             (etaf-youtube-images-cache images)))
  (etaf-youtube--images-bump images))

(defun etaf-youtube-images-clear-error (images url)
  "Forget IMAGES's failed URL so a later request may retry it."
  (let ((entry (gethash url (etaf-youtube-images-cache images))))
    (when (eq (plist-get entry :status) 'error)
      (remhash url (etaf-youtube-images-cache images))
      (etaf-youtube--images-bump images))))

(defun etaf-youtube-images-cancel (images)
  "Cancel IMAGES's queued and in-flight downloads."
  (dolist (cancel (hash-table-values (etaf-youtube-images-cancels images)))
    (when (functionp cancel) (ignore-errors (funcall cancel))))
  (clrhash (etaf-youtube-images-cancels images))
  (dolist (url (etaf-youtube-images-queue images))
    (remhash url (etaf-youtube-images-cache images)))
  (setf (etaf-youtube-images-queue images) nil
        (etaf-youtube-images-active images) 0)
  (etaf-youtube--images-bump images))

(provide 'etaf-youtube-images)
;;; etaf-youtube-images.el ends here
