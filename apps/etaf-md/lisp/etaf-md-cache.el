;;; etaf-md-cache.el --- Remote image async cache and disk cache hygiene -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Asynchronous downloading and bounded disk caching of remote HTTP(S) images
;; referenced by displayed markdown previews, plus lazy LRU eviction shared by
;; `etaf-md''s on-disk caches (`typeset/', `qrcode/' and `images/').
;;
;; Rendering stays pure and non-blocking: `etaf-md-cache-image-path' performs an
;; O(1) in-memory lookup, and `etaf-md-cache-request-images' only starts
;; downloads asynchronously for sessions mounted in a live buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'etaf)

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

(defconst etaf-md-cache--max-image-bytes (* 5 1024 1024)
  "Hard upper bound in bytes for one downloaded remote image (5 MB).")

(defconst etaf-md-cache--max-images-per-page 30
  "Maximum remote images queued per document pass.")

(defconst etaf-md-cache--max-concurrent 4
  "Maximum concurrent remote image downloads.")

(defconst etaf-md-cache--max-files 512
  "Maximum files retained in one cache directory before LRU pruning.")

(defconst etaf-md-cache--fetch-timeout 15
  "Timeout in seconds for a single remote image fetch.")

(defconst etaf-md-cache--user-agent
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  "User-Agent header used when downloading remote images.")

(defvar etaf-md-cache--images (make-hash-table :test #'equal)
  "In-memory map of remote image URL to local cached file path.")

(defvar etaf-md-cache--running (make-hash-table :test #'equal)
  "Remote image URLs currently being downloaded, mapped to cancel functions.")

(defvar etaf-md-cache--failed (make-hash-table :test #'equal)
  "Remote image URLs that failed recently, mapped to failure timestamp.")

(defconst etaf-md-cache--failed-ttl 300
  "Seconds before a failed remote image URL may be retried.")

(defvar etaf-md-cache--queue nil
  "Pending remote image download items `(URL . SESSION)'.")

(defvar etaf-md-cache--in-flight 0
  "Number of remote image downloads currently running.")

(defvar etaf-md-cache--prune-timers (make-hash-table :test #'equal)
  "Pending idle LRU prune timers keyed by cache directory path.")

;;; ---------------------------------------------------------------------------
;;; Bounded LRU disk cache pruning
;;; ---------------------------------------------------------------------------

(defun etaf-md-cache-prune-directory (directory &optional max-bytes max-files)
  "Schedule lazy LRU pruning of DIRECTORY to stay under MAX-BYTES and MAX-FILES.
Prunes at most once per idle burst so writes never stall editing or rendering."
  (when (and (stringp directory)
             (file-directory-p directory)
             (not (gethash directory etaf-md-cache--prune-timers)))
    (let ((cap-bytes (or max-bytes etaf-md-cache-max-bytes))
          (cap-files (or max-files etaf-md-cache--max-files)))
      (puthash
       directory
       (run-with-idle-timer
        1.5 nil
        (lambda ()
          (remhash directory etaf-md-cache--prune-timers)
          (etaf-md-cache--prune-now directory cap-bytes cap-files)))
       etaf-md-cache--prune-timers))))

(defun etaf-md-cache--prune-now (directory max-bytes max-files)
  "Evict oldest files in DIRECTORY until total size and file count fit limits."
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
        ;; Oldest modification time first.
        (setq entries (sort entries (lambda (a b) (< (car a) (car b)))))
        (while (and entries
                    (or (> total-bytes max-bytes) (> total-files max-files)))
          (let* ((victim (pop entries))
                 (size (nth 1 victim))
                 (file (nth 2 victim)))
            (ignore-errors (delete-file file))
            (setq total-bytes (- total-bytes size)
                  total-files (1- total-files))))))))

;;; ---------------------------------------------------------------------------
;;; Remote image lookup and async download
;;; ---------------------------------------------------------------------------

(defun etaf-md-cache--http-url-p (url)
  "Return non-nil when URL is an `http://' or `https://' URL."
  (and (stringp url)
       (string-match-p "\\`https?://" (downcase (string-trim url)))))

(defun etaf-md-cache--image-extension (url content-type)
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

(defun etaf-md-cache--existing-on-disk (url)
  "Return cached local path on disk for remote URL, or nil."
  (when (and (etaf-md-cache--http-url-p url)
             (file-directory-p etaf-md-cache--image-directory))
    (let* ((prefix (secure-hash 'sha1 url))
           (matches (directory-files etaf-md-cache--image-directory t
                                     (concat "\\`" (regexp-quote prefix) "\\."))))
      (when (and matches (file-readable-p (car matches)))
        (puthash url (car matches) etaf-md-cache--images)
        (car matches)))))

(defun etaf-md-cache-image-path (url)
  "Return local cached image path for remote URL from memory, or nil.
Never touches the network or filesystem, so it is safe during render."
  (and (stringp url)
       (gethash url etaf-md-cache--images)))

(defun etaf-md-cache--no-proxy-env ()
  "Return `:environment' overrides clearing proxy variables when Emacs has none."
  (when (null url-proxy-services)
    '("HTTP_PROXY=" "HTTPS_PROXY=" "ALL_PROXY="
      "http_proxy=" "https_proxy=" "all_proxy="
      "NO_PROXY=*" "no_proxy=*")))

(defun etaf-md-cache--parse-http-response (raw-bytes)
  "Parse unibyte HTTP response RAW-BYTES; return `(:status :content-type :body)'."
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

(defun etaf-md-cache--save-image (url resp)
  "Validate parsed HTTP RESP and write image for URL atomically to disk.
Return the local file path, or nil when RESP is empty, oversized or HTML."
  (let* ((ct (plist-get resp :content-type))
         (bytes (plist-get resp :body)))
    (when (and (stringp bytes)
               (> (length bytes) 0)
               (<= (length bytes) etaf-md-cache--max-image-bytes)
               (not (and (stringp ct)
                         (string-prefix-p "text/html" (downcase ct)))))
      (make-directory etaf-md-cache--image-directory t)
      (let* ((ext (etaf-md-cache--image-extension url ct))
             (dest (expand-file-name
                    (format "%s.%s" (secure-hash 'sha1 url) ext)
                    etaf-md-cache--image-directory))
             (tmp (make-temp-file "etaf-md-img-" nil (concat "." ext))))
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'no-conversion))
                (with-temp-file tmp
                  (set-buffer-multibyte nil)
                  (insert bytes)))
              (rename-file tmp dest t)
              (puthash url dest etaf-md-cache--images)
              (etaf-md-cache-prune-directory etaf-md-cache--image-directory)
              dest)
          (when (file-exists-p tmp)
            (ignore-errors (delete-file tmp))))))))

(defun etaf-md-cache--fetch-async (url callback)
  "Download remote image URL asynchronously; invoke CALLBACK with `(PATH)'.
Return a zero-argument cancel function."
  (if (executable-find "curl")
      (let* ((args (append
                    (list "curl" "-sS" "-L" "-i"
                          "--max-time" (number-to-string etaf-md-cache--fetch-timeout)
                          "--connect-timeout" "10"
                          "--max-filesize" (number-to-string etaf-md-cache--max-image-bytes)
                          "-A" etaf-md-cache--user-agent)
                    (when (null url-proxy-services)
                      (list "--noproxy" "*"))
                    (list url)))
             (cancelled nil)
             (job nil))
        (setq job
              (etaf-process-run
               args
               :name "etaf-md-image-fetch"
               :timeout (+ etaf-md-cache--fetch-timeout 2)
               :coding 'no-conversion
               :environment (etaf-md-cache--no-proxy-env)
               :callback
               (lambda (res)
                 (unless cancelled
                   (let ((path (when (and (eq (plist-get res :status) 'exit)
                                          (eql (plist-get res :exit) 0))
                                 (when-let* ((resp (etaf-md-cache--parse-http-response
                                                    (plist-get res :output))))
                                   (etaf-md-cache--save-image url resp)))))
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
                                   (when-let* ((resp (etaf-md-cache--parse-http-response
                                                      (buffer-substring-no-properties
                                                       (point-min) (point-max)))))
                                     (etaf-md-cache--save-image url resp)))))
                       (funcall callback path)))
                 (when (buffer-live-p buf) (kill-buffer buf)))))
           nil t t)
        (error
         (run-at-time 0 nil callback nil)))
      (lambda () (setq cancelled t)))))

(defun etaf-md-cache--extract-block-urls (block)
  "Return unique HTTP(S) image URLs referenced inside parsed BLOCK."
  (let ((urls nil))
    (cl-labels
        ((maybe (url)
           (when (etaf-md-cache--http-url-p url)
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
                (let ((text (or (plist-get b :text) "")))
                  (let ((pos 0) (case-fold-search t))
                    (while (string-match "<img\\b[^>]*\\bsrc=[\"']\\(https?://[^\"']+\\)[\"']"
                                         text pos)
                      (maybe (match-string 1 text))
                      (setq pos (match-end 0))))))
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

(defun etaf-md-cache--failed-recently-p (url)
  "Return non-nil when URL failed within `etaf-md-cache--failed-ttl' seconds."
  (when-let* ((ts (gethash url etaf-md-cache--failed)))
    (if (< (- (float-time) ts) etaf-md-cache--failed-ttl)
        t
      (remhash url etaf-md-cache--failed)
      nil)))

(defun etaf-md-cache--pump ()
  "Start queued remote image downloads up to `etaf-md-cache--max-concurrent'."
  (while (and etaf-md-cache--queue
              (< etaf-md-cache--in-flight etaf-md-cache--max-concurrent))
    (let* ((item (pop etaf-md-cache--queue))
           (url (car item))
           (session (cdr item))
           (buf (plist-get session :buffer)))
      (when (and (buffer-live-p buf)
                 (not (etaf-md-cache-image-path url))
                 (not (gethash url etaf-md-cache--running))
                 (not (etaf-md-cache--failed-recently-p url)))
        (if (etaf-md-cache--existing-on-disk url)
            (etaf-md-cache--notify-session session)
          (setq etaf-md-cache--in-flight (1+ etaf-md-cache--in-flight))
          (let ((cancel nil))
            (setq cancel
                  (etaf-md-cache--fetch-async
                   url
                   (lambda (path)
                     (remhash url etaf-md-cache--running)
                     (setq etaf-md-cache--in-flight
                           (max 0 (1- etaf-md-cache--in-flight)))
                     (if path
                         (etaf-md-cache--notify-session session)
                       (puthash url (float-time) etaf-md-cache--failed))
                     (etaf-md-cache--pump))))
            (puthash url cancel etaf-md-cache--running)))))))

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
    (dolist (url (etaf-md-cache--extract-block-urls block))
      (unless (etaf-md-cache-image-path url)
        (etaf-md-cache--existing-on-disk url))))
  block)

(defun etaf-md-cache-request-images (session)
  "Queue asynchronous downloads for uncached remote images in mounted SESSION.
Does nothing when `etaf-md-remote-images' is nil or SESSION has no live buffer."
  (when (and etaf-md-remote-images
             (buffer-live-p (plist-get session :buffer)))
    (let ((wanted nil)
          (found-on-disk nil)
          (count 0))
      (dolist (entry (plist-get (etaf-md--read session :document) :children))
        (when (< count etaf-md-cache--max-images-per-page)
          (dolist (url (etaf-md-cache--extract-block-urls (plist-get entry :block)))
            (when (< count etaf-md-cache--max-images-per-page)
              (cond
               ((etaf-md-cache-image-path url) nil)
               ((etaf-md-cache--existing-on-disk url)
                (setq found-on-disk t))
               ((or (gethash url etaf-md-cache--running)
                    (etaf-md-cache--failed-recently-p url))
                nil)
               (t
                (setq count (1+ count))
                (push url wanted)))))))
      (when found-on-disk
        (etaf-md-cache--notify-session session))
      (when wanted
        (dolist (url (delete-dups (nreverse wanted)))
          (unless (cl-some (lambda (pair) (equal (car pair) url))
                           etaf-md-cache--queue)
            (setq etaf-md-cache--queue
                  (nconc etaf-md-cache--queue (list (cons url session))))))
        (etaf-md-cache--pump)))))

(provide 'etaf-md-cache)
;;; etaf-md-cache.el ends here
