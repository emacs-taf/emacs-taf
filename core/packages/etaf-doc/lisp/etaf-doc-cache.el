;;; etaf-doc-cache.el --- Shared LRU disk hygiene and remote image cache -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Shared asynchronous remote HTTP(S) image cache and bounded lazy LRU disk
;; eviction for ETAF document applications (`etaf-md', `etaf-org', `etaf-web').
;;
;; Rendering stays pure and non-blocking: `etaf-doc-cache-image-path' performs
;; an O(1) in-memory hash lookup without touching the disk or network, while
;; `etaf-doc-cache-request-urls' downloads uncached URLs asynchronously and
;; notifies callers when ready.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'etaf)

(defconst etaf-doc-cache--default-root
  (expand-file-name "etaf-doc/"
                    (or (let ((xdg (getenv "XDG_CACHE_HOME")))
                          (and xdg (not (string-empty-p xdg)) xdg))
                        (expand-file-name "~/.cache")))
  "Default root directory for `etaf-doc' disk caches.")

(defconst etaf-doc-cache--default-image-directory
  (expand-file-name "images/" etaf-doc-cache--default-root)
  "Default directory storing asynchronously cached remote images.")

(defconst etaf-doc-cache--default-max-bytes (* 100 1024 1024)
  "Default upper bound in bytes for one pruned disk cache directory.")

(defconst etaf-doc-cache--default-max-files 512
  "Default file count upper bound for one pruned disk cache directory.")

(defconst etaf-doc-cache--max-image-bytes (* 5 1024 1024)
  "Hard upper bound in bytes for one downloaded remote image (5 MB).")

(defconst etaf-doc-cache--max-concurrent 4
  "Maximum concurrent remote image downloads.")

(defconst etaf-doc-cache--fetch-timeout 15
  "Timeout in seconds for a single remote image fetch.")

(defconst etaf-doc-cache--failed-ttl 300
  "Seconds before a failed remote image URL may be retried.")

(defconst etaf-doc-cache--user-agent
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  "User-Agent header used when downloading remote images.")

(defvar etaf-doc-cache--images (make-hash-table :test #'equal)
  "In-memory map of remote image URL to local cached file path.")

(defvar etaf-doc-cache--running (make-hash-table :test #'equal)
  "Remote image URLs currently being downloaded, mapped to cancel functions.")

(defvar etaf-doc-cache--failed (make-hash-table :test #'equal)
  "Remote image URLs that failed recently, mapped to failure timestamp.")

(defvar etaf-doc-cache--queue nil
  "Pending remote image download entries.")

(defvar etaf-doc-cache--in-flight 0
  "Number of remote image downloads currently running.")

(defvar etaf-doc-cache--prune-timers (make-hash-table :test #'equal)
  "Pending idle LRU prune timers keyed by cache directory path.")

;;; ---------------------------------------------------------------------------
;;; Bounded LRU disk cache pruning
;;; ---------------------------------------------------------------------------

(defun etaf-doc-cache--prune-now (directory max-bytes max-files)
  "Evict oldest regular files in DIRECTORY to stay within MAX-BYTES/MAX-FILES."
  (when (file-directory-p directory)
    (let ((entries nil)
          (total-bytes 0)
          (total-files 0))
      (dolist (file (directory-files directory t "\\`[^.]" t))
        (when-let* ((attrs (file-attributes file))
                    ((null (file-attribute-type attrs)))
                    (size (file-attribute-size attrs))
                    (mtime (float-time (file-attribute-modification-time attrs))))
          (setq total-bytes (+ total-bytes size)
                total-files (1+ total-files))
          (push (list mtime size file) entries)))
      (when (or (> total-bytes max-bytes) (> total-files max-files))
        (setq entries (sort entries (lambda (a b) (< (car a) (car b)))))
        (while (and entries
                    (or (> total-bytes max-bytes) (> total-files max-files)))
          (let* ((victim (pop entries))
                 (size (nth 1 victim))
                 (file (nth 2 victim)))
            (ignore-errors (delete-file file))
            (setq total-bytes (- total-bytes size)
                  total-files (1- total-files))))))))

(defun etaf-doc-cache-prune-directory (directory &optional max-bytes max-files)
  "Schedule lazy idle LRU pruning of DIRECTORY under MAX-BYTES and MAX-FILES.
Coalesces repeated calls per DIRECTORY so cache writes never stall rendering."
  (when (and (stringp directory)
             (file-directory-p directory)
             (not (gethash directory etaf-doc-cache--prune-timers)))
    (let ((cap-bytes (or max-bytes etaf-doc-cache--default-max-bytes))
          (cap-files (or max-files etaf-doc-cache--default-max-files)))
      (puthash
       directory
       (run-with-idle-timer
        1.5 nil
        (lambda ()
          (remhash directory etaf-doc-cache--prune-timers)
          (etaf-doc-cache--prune-now directory cap-bytes cap-files)))
       etaf-doc-cache--prune-timers))))

;;; ---------------------------------------------------------------------------
;;; URL classification and O(1) memory lookup
;;; ---------------------------------------------------------------------------

(defun etaf-doc-cache-http-url-p (url)
  "Return non-nil when URL is an `http://' or `https://' URL."
  (and (stringp url)
       (string-match-p "\\`https?://" (downcase (string-trim url)))))

(defun etaf-doc-cache-image-url-p (url)
  "Return non-nil when remote URL points to a supported image extension."
  (and (etaf-doc-cache-http-url-p url)
       (let* ((clean (car (split-string (string-trim url) "[?#]")))
              (ext (downcase (or (file-name-extension clean) ""))))
         (member ext '("png" "jpg" "jpeg" "gif" "webp" "bmp" "svg")))))

(defun etaf-doc-cache-image-path (url)
  "Return local cached image path for remote URL from memory, or nil.
Never touches the disk or network, so it is safe to call inside `:render'."
  (and (stringp url)
       (gethash url etaf-doc-cache--images)))

(defun etaf-doc-cache--image-extension (url content-type)
  "Infer a local file extension from HTTP CONTENT-TYPE or URL."
  (let ((mime (and (stringp content-type)
                   (downcase (string-trim (car (split-string content-type ";")))))))
    (or (pcase mime
          ("image/png" "png")
          ((or "image/jpeg" "image/jpg") "jpg")
          ("image/gif" "gif")
          ("image/webp" "webp")
          ("image/bmp" "bmp")
          ("image/svg+xml" "svg")
          (_ nil))
        (let* ((clean (car (split-string (or url "") "[?#]")))
               (ext (downcase (or (file-name-extension clean) ""))))
          (and (member ext '("png" "jpg" "jpeg" "gif" "webp" "bmp" "svg"))
               ext))
        "png")))

(defun etaf-doc-cache--existing-on-disk (url &optional directory)
  "Return cached local file path on disk for remote URL in DIRECTORY, or nil."
  (let ((dir (or directory etaf-doc-cache--default-image-directory)))
    (when (and (etaf-doc-cache-http-url-p url)
               (file-directory-p dir))
      (let* ((prefix (secure-hash 'sha1 url))
             (matches (directory-files dir t
                                       (concat "\\`" (regexp-quote prefix) "\\."))))
        (when (and matches (file-readable-p (car matches)))
          (puthash url (car matches) etaf-doc-cache--images)
          (car matches))))))

(defun etaf-doc-cache-warm-urls (urls &optional directory)
  "Populate in-memory cache from disk for remote URLS in DIRECTORY.
Performs no network I/O.  Return non-nil when at least one URL was newly warmed."
  (let ((warmed nil))
    (dolist (url urls)
      (when (and (etaf-doc-cache-http-url-p url)
                 (not (etaf-doc-cache-image-path url))
                 (etaf-doc-cache--existing-on-disk url directory))
        (setq warmed t)))
    warmed))

;;; ---------------------------------------------------------------------------
;;; Async HTTP(S) image download queue
;;; ---------------------------------------------------------------------------

(defun etaf-doc-cache--no-proxy-env ()
  "Return proxy-clearing `:environment' overrides when Emacs has no proxy."
  (when (null url-proxy-services)
    '("HTTP_PROXY=" "HTTPS_PROXY=" "ALL_PROXY="
      "http_proxy=" "https_proxy=" "all_proxy="
      "NO_PROXY=*" "no_proxy=*")))

(defun etaf-doc-cache--parse-http-response (raw-bytes)
  "Parse unibyte HTTP RAW-BYTES into `(:status :content-type :body)'."
  (when (and (stringp raw-bytes) (> (length raw-bytes) 0))
    (let ((bytes (if (multibyte-string-p raw-bytes)
                     (encode-coding-string raw-bytes 'raw-text)
                   raw-bytes)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert bytes)
        (goto-char (point-min))
        (let ((status 200)
              (content-type nil)
              (body-start (point-min))
              (more t))
          (while more
            (setq more nil)
            (when (and (looking-at "HTTP/[0-9.]+[ \t]+\\([0-9]\\{3\\}\\)")
                       (re-search-forward "\r?\n\r?\n" nil t))
              (let* ((hdr-end (match-beginning 0))
                     (next-start (match-end 0))
                     (hdr (buffer-substring-no-properties body-start hdr-end)))
                (setq body-start next-start
                      content-type nil)
                (when (string-match "\\`HTTP/[0-9.]+[ \t]+\\([0-9]\\{3\\}\\)" hdr)
                  (setq status (string-to-number (match-string 1 hdr))))
                (let ((case-fold-search t))
                  (when (string-match "^content-type:[ \t]*\\([^\r\n]+\\)" hdr)
                    (setq content-type (string-trim (match-string 1 hdr)))))
                (goto-char body-start)
                (when (and (or (and (>= status 100) (< status 200))
                               (and (>= status 300) (< status 400)))
                           (looking-at "HTTP/[0-9.]+[ \t]+[0-9]\\{3\\}"))
                  (setq more t)))))
          (when (and (>= status 200) (< status 400))
            (list :status status
                  :content-type content-type
                  :body (buffer-substring-no-properties body-start (point-max)))))))))

(defun etaf-doc-cache--save-image (url resp directory max-bytes max-files)
  "Validate parsed HTTP RESP and write image for URL atomically into DIRECTORY."
  (let* ((dir (or directory etaf-doc-cache--default-image-directory))
         (ct (plist-get resp :content-type))
         (bytes (plist-get resp :body)))
    (when (and (stringp bytes)
               (> (length bytes) 0)
               (<= (length bytes) etaf-doc-cache--max-image-bytes)
               (not (and (stringp ct)
                         (string-prefix-p "text/html" (downcase ct)))))
      (make-directory dir t)
      (let* ((ext (etaf-doc-cache--image-extension url ct))
             (dest (expand-file-name
                    (format "%s.%s" (secure-hash 'sha1 url) ext)
                    dir))
             (tmp (make-temp-file "etaf-doc-img-" nil (concat "." ext))))
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'no-conversion))
                (with-temp-file tmp
                  (set-buffer-multibyte nil)
                  (insert bytes)))
              (rename-file tmp dest t)
              (puthash url dest etaf-doc-cache--images)
              (etaf-doc-cache-prune-directory dir max-bytes max-files)
              dest)
          (when (file-exists-p tmp)
            (ignore-errors (delete-file tmp))))))))

(defun etaf-doc-cache--fetch-async (url directory max-bytes max-files callback)
  "Download remote image URL asynchronously into DIRECTORY; invoke CALLBACK."
  (if (executable-find "curl")
      (let* ((args (append
                    (list "curl" "-sS" "-L" "-i"
                          "--max-time" (number-to-string etaf-doc-cache--fetch-timeout)
                          "--connect-timeout" "10"
                          "--max-filesize" (number-to-string etaf-doc-cache--max-image-bytes)
                          "-A" etaf-doc-cache--user-agent)
                    (when (null url-proxy-services)
                      (list "--noproxy" "*"))
                    (list url)))
             (cancelled nil)
             (job nil))
        (setq job
              (etaf-process-run
               args
               :name "etaf-doc-image-fetch"
               :timeout (+ etaf-doc-cache--fetch-timeout 2)
               :coding 'no-conversion
               :environment (etaf-doc-cache--no-proxy-env)
               :callback
               (lambda (res)
                 (unless cancelled
                   (let ((path (when (and (eq (plist-get res :status) 'exit)
                                          (eql (plist-get res :exit) 0))
                                 (when-let* ((resp (etaf-doc-cache--parse-http-response
                                                    (plist-get res :output))))
                                   (etaf-doc-cache--save-image
                                    url resp directory max-bytes max-files)))))
                     (funcall callback path))))))
        (lambda ()
          (setq cancelled t)
          (when job (etaf-process-cancel job))))
    (let ((cancelled nil)
          (url-show-status nil)
          (url-automatic-caching nil))
      (condition-case nil
          (url-retrieve
           url
           (lambda (status)
             (let ((buf (current-buffer)))
               (unwind-protect
                   (unless cancelled
                     (let ((path (unless (plist-get status :error)
                                   (set-buffer-multibyte nil)
                                   (when-let* ((resp (etaf-doc-cache--parse-http-response
                                                      (buffer-substring-no-properties
                                                       (point-min) (point-max)))))
                                     (etaf-doc-cache--save-image
                                      url resp directory max-bytes max-files)))))
                       (funcall callback path)))
                 (when (buffer-live-p buf) (kill-buffer buf)))))
           nil t t)
        (error
         (run-at-time 0 nil callback nil)))
      (lambda () (setq cancelled t)))))

(defun etaf-doc-cache--failed-recently-p (url)
  "Return non-nil when URL failed within `etaf-doc-cache--failed-ttl' seconds."
  (when-let* ((ts (gethash url etaf-doc-cache--failed)))
    (if (< (- (float-time) ts) etaf-doc-cache--failed-ttl)
        t
      (remhash url etaf-doc-cache--failed)
      nil)))

(defun etaf-doc-cache--pump ()
  "Start queued remote image downloads up to `etaf-doc-cache--max-concurrent'."
  (while (and etaf-doc-cache--queue
              (< etaf-doc-cache--in-flight etaf-doc-cache--max-concurrent))
    (let* ((item (pop etaf-doc-cache--queue))
           (url (plist-get item :url))
           (dir (plist-get item :directory))
           (max-bytes (plist-get item :max-bytes))
           (max-files (plist-get item :max-files))
           (live-p (plist-get item :live-p))
           (on-ready (plist-get item :on-ready)))
      (when (and (or (null live-p) (funcall live-p))
                 (not (etaf-doc-cache-image-path url))
                 (not (gethash url etaf-doc-cache--running))
                 (not (etaf-doc-cache--failed-recently-p url)))
        (if (etaf-doc-cache--existing-on-disk url dir)
            (when (functionp on-ready) (funcall on-ready))
          (setq etaf-doc-cache--in-flight (1+ etaf-doc-cache--in-flight))
          (let ((cancel nil))
            (setq cancel
                  (etaf-doc-cache--fetch-async
                   url dir max-bytes max-files
                   (lambda (path)
                     (remhash url etaf-doc-cache--running)
                     (setq etaf-doc-cache--in-flight
                           (max 0 (1- etaf-doc-cache--in-flight)))
                     (if path
                         (when (and (or (null live-p) (funcall live-p))
                                    (functionp on-ready))
                           (funcall on-ready))
                       (puthash url (float-time) etaf-doc-cache--failed))
                     (etaf-doc-cache--pump))))
            (puthash url cancel etaf-doc-cache--running)))))))

(defun etaf-doc-cache-request-urls (urls on-ready &optional options)
  "Queue asynchronous downloads for uncached remote image URLS.
Invokes ON-READY whenever one or more images are found on disk or finish
downloading.  OPTIONS is an optional plist supporting `:directory',
`:max-bytes', `:max-files', `:max-per-page' (default 30) and `:live-p'
(zero-argument predicate checked before starting or delivering a download)."
  (let* ((dir (or (plist-get options :directory)
                  etaf-doc-cache--default-image-directory))
         (max-bytes (plist-get options :max-bytes))
         (max-files (plist-get options :max-files))
         (max-per-page (or (plist-get options :max-per-page) 30))
         (live-p (plist-get options :live-p))
         (wanted nil)
         (found-on-disk nil)
         (count 0))
    (when (or (null live-p) (funcall live-p))
      (dolist (url (delete-dups (copy-sequence urls)))
        (when (and (< count max-per-page)
                   (etaf-doc-cache-http-url-p url))
          (cond
           ((etaf-doc-cache-image-path url) nil)
           ((etaf-doc-cache--existing-on-disk url dir)
            (setq found-on-disk t))
           ((or (gethash url etaf-doc-cache--running)
                (etaf-doc-cache--failed-recently-p url))
            nil)
           (t
            (setq count (1+ count))
            (push url wanted)))))
      (when (and found-on-disk (functionp on-ready))
        (funcall on-ready))
      (when wanted
        (dolist (url (nreverse wanted))
          (unless (cl-some (lambda (item) (equal (plist-get item :url) url))
                           etaf-doc-cache--queue)
            (setq etaf-doc-cache--queue
                  (nconc etaf-doc-cache--queue
                         (list (list :url url
                                     :directory dir
                                     :max-bytes max-bytes
                                     :max-files max-files
                                     :live-p live-p
                                     :on-ready on-ready))))))
        (etaf-doc-cache--pump)))))

(provide 'etaf-doc-cache)
;;; etaf-doc-cache.el ends here
