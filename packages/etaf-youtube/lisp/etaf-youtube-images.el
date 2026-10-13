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

(defun etaf-youtube--curl-attempt (url file proxy callback)
  "Download URL into FILE through PROXY and call CALLBACK with nil or an error.
PROXY may be nil for a direct request.  Return a cancel function."
  (let* ((environment
          (if proxy
              (cl-remove-if
               (lambda (entry)
                 (string-match-p "\\`\\(no_proxy\\|NO_PROXY\\)=" entry))
               process-environment)
            process-environment))
         (program (executable-find "curl")))
    (if (null program)
        (progn (funcall callback "curl is not on PATH") #'ignore)
      (let* ((out (generate-new-buffer " *etaf-youtube curl*"))
             (err (generate-new-buffer " *etaf-youtube curl err*"))
             (process (let ((process-environment environment))
                        (make-process
                         :name "etaf-youtube-image"
                         :command (append (list program "-fsSL" "--max-time"
                                                (number-to-string etaf-youtube-image-timeout)
                                                "--connect-timeout" "10")
                                          (when proxy (list "-x" proxy))
                                          (list "-o" file url))
                         :buffer out
                         :stderr err
                         :coding 'binary
                         :connection-type 'pipe
                         :noquery t)))
             (done nil))
        (when-let* ((err-process (get-buffer-process err)))
          (set-process-sentinel err-process #'ignore))
        (set-process-sentinel
         process
         (lambda (proc _event)
           (when (and (not done)
                      (memq (process-status proc) '(exit signal failed)))
             (setq done t)
             (accept-process-output proc 0)
             (when-let* ((err-process (get-buffer-process err)))
               (accept-process-output err-process 0))
             (let ((status (process-exit-status proc))
                   (message (string-trim (with-current-buffer err (buffer-string)))))
               (when (buffer-live-p out) (kill-buffer out))
               (when (buffer-live-p err) (kill-buffer err))
               (if (and (= status 0) (file-exists-p file)
                        (> (or (nth 7 (file-attributes file)) 0) 0))
                   (funcall callback nil)
                 (funcall callback
                          (if (string-empty-p message)
                              (format "curl exited with status %d" status)
                            message)))))))
        (lambda ()
          (when (process-live-p process)
            (setq done t)
            (delete-process process)
            (when (buffer-live-p out) (kill-buffer out))
            (when (buffer-live-p err) (kill-buffer err))))))))

(defun etaf-youtube--default-fetcher (images url file callback)
  "Download URL into FILE for IMAGES and call CALLBACK with nil or an error.
The configured route proxy is tried first, then a direct request.  Return a
cancel function."
  (let ((proxy (ignore-errors (funcall (etaf-youtube-images-proxy-fn images))))
        (cancelled nil)
        (cancel nil))
    (cl-labels
        ((attempt
          (attempts)
          (cond
           ((or cancelled (null attempts)) nil)
           (t
            (setq cancel
                  (etaf-youtube--curl-attempt
                   url file (car attempts)
                   (lambda (error)
                     (cond
                      (cancelled nil)
                      ((null error) (funcall callback nil))
                      ((cdr attempts) (attempt (cdr attempts)))
                      (t (funcall callback error))))))))))
      (attempt (if proxy (list proxy nil) (list nil))))
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
                        (funcall fetcher images url target
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
  "Record URL's downloaded FILE in IMAGES, or its ERROR."
  (if (and file (null error))
      (condition-case problem
          (let* ((type (image-type-from-file-header file))
                 (image (and type (create-image file type nil))))
            (if (null image)
                (progn
                  (ignore-errors (delete-file file))
                  (puthash url (list :status 'error
                                     :message "not a recognized image")
                           (etaf-youtube-images-cache images)))
              (let* ((target (concat (file-name-sans-extension file)
                                     "." (symbol-name type)))
                     (final (if (file-exists-p target)
                                (progn (ignore-errors (delete-file file)) target)
                              (rename-file file target t)
                              target)))
                (puthash url (list :status 'ready :file final :image image)
                         (etaf-youtube-images-cache images)))))
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
