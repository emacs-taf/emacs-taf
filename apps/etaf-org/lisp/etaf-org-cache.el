;;; etaf-org-cache.el --- Remote image async cache and disk cache hygiene -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Asynchronous downloading and bounded disk caching of remote HTTP(S) images
;; referenced by displayed Org previews, plus lazy LRU eviction shared by
;; `etaf-org''s on-disk caches (`typeset/', `qrcode/', `images/', `pdf/' and
;; `diagrams/').
;;
;; Rendering stays pure and non-blocking: `etaf-org-cache-image-path' performs
;; an O(1) in-memory lookup, and `etaf-org-cache-request-images' only starts
;; downloads asynchronously for sessions mounted in a live buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'etaf)

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

(defconst etaf-org-cache--max-image-bytes (* 5 1024 1024)
  "Hard upper bound in bytes for one downloaded remote image (5 MB).")

(defconst etaf-org-cache--max-images-per-page 30
  "Maximum remote images queued per document pass.")

(defconst etaf-org-cache--max-concurrent 4
  "Maximum concurrent remote image downloads.")

(defconst etaf-org-cache--max-files 512
  "Maximum files retained in one cache directory before LRU pruning.")

(defconst etaf-org-cache--fetch-timeout 15
  "Timeout in seconds for a single remote image fetch.")

(defconst etaf-org-cache--user-agent
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  "User-Agent header used when downloading remote images.")

(defvar etaf-org-cache--images (make-hash-table :test #'equal)
  "In-memory map of remote image URL to local cached file path.")

(defvar etaf-org-cache--running (make-hash-table :test #'equal)
  "Remote image URLs currently being downloaded, mapped to cancel functions.")

(defvar etaf-org-cache--failed (make-hash-table :test #'equal)
  "Remote image URLs that failed recently, mapped to failure timestamp.")

(defconst etaf-org-cache--failed-ttl 300
  "Seconds before a failed remote image URL may be retried.")

(defvar etaf-org-cache--queue nil
  "Pending remote image download items `(URL . SESSION)'.")

(defvar etaf-org-cache--in-flight 0
  "Number of remote image downloads currently running.")

(defvar etaf-org-cache--prune-timers (make-hash-table :test #'equal)
  "Pending idle LRU prune timers keyed by cache directory path.")

;;; ---------------------------------------------------------------------------
;;; Bounded LRU disk cache pruning
;;; ---------------------------------------------------------------------------

(defun etaf-org-cache-prune-directory (directory &optional max-bytes max-files)
  "Schedule lazy LRU pruning of DIRECTORY to stay under MAX-BYTES and MAX-FILES.
Prunes at most once per idle burst so writes never stall editing or rendering."
  (when (and (stringp directory)
             (file-directory-p directory)
             (not (gethash directory etaf-org-cache--prune-timers)))
    (let ((cap-bytes (or max-bytes etaf-org-cache-max-bytes))
          (cap-files (or max-files etaf-org-cache--max-files)))
      (puthash
       directory
       (run-with-idle-timer
        1.5 nil
        (lambda ()
          (remhash directory etaf-org-cache--prune-timers)
          (etaf-org-cache--prune-now directory cap-bytes cap-files)))
       etaf-org-cache--prune-timers))))

(defun etaf-org-cache--prune-now (directory max-bytes max-files)
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

(defun etaf-org-cache--http-url-p (url)
  "Return non-nil when URL is an `http://' or `https://' URL."
  (and (stringp url)
       (string-match-p "\\`https?://" (downcase (string-trim url)))))

(defun etaf-org-cache--image-url-p (url)
  "Return non-nil when remote URL points to an image extension."
  (and (etaf-org-cache--http-url-p url)
       (let* ((clean (car (split-string (string-trim url) "[?#]")))
              (ext (downcase (or (file-name-extension clean) ""))))
         (member ext '("png" "jpg" "jpeg" "gif" "webp" "bmp" "svg")))))

(defun etaf-org-cache--image-extension (url content-type)
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

(defun etaf-org-cache--existing-on-disk (url)
  "Return cached local path on disk for remote URL, or nil."
  (when (and (etaf-org-cache--http-url-p url)
             (file-directory-p etaf-org-cache--image-directory))
    (let* ((prefix (secure-hash 'sha1 url))
           (matches (directory-files etaf-org-cache--image-directory t
                                     (concat "\\`" (regexp-quote prefix) "\\."))))
      (when (and matches (file-readable-p (car matches)))
        (puthash url (car matches) etaf-org-cache--images)
        (car matches)))))

(defun etaf-org-cache-image-path (url)
  "Return local cached image path for remote URL from memory, or nil.
Never touches the network or filesystem, so it is safe during render."
  (and (stringp url)
       (gethash url etaf-org-cache--images)))

(defun etaf-org-cache--no-proxy-env ()
  "Return `:environment' overrides clearing proxy variables when Emacs has none."
  (when (null url-proxy-services)
    '("HTTP_PROXY=" "HTTPS_PROXY=" "ALL_PROXY="
      "http_proxy=" "https_proxy=" "all_proxy="
      "NO_PROXY=*" "no_proxy=*")))

(defun etaf-org-cache--parse-http-response (raw-bytes)
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

(defun etaf-org-cache--save-image (url resp)
  "Validate parsed HTTP RESP and write image for URL atomically to disk.
Return the local file path, or nil when RESP is empty, oversized or HTML."
  (let* ((ct (plist-get resp :content-type))
         (bytes (plist-get resp :body)))
    (when (and (stringp bytes)
               (> (length bytes) 0)
               (<= (length bytes) etaf-org-cache--max-image-bytes)
               (not (and (stringp ct)
                         (string-prefix-p "text/html" (downcase ct)))))
      (make-directory etaf-org-cache--image-directory t)
      (let* ((ext (etaf-org-cache--image-extension url ct))
             (dest (expand-file-name
                    (format "%s.%s" (secure-hash 'sha1 url) ext)
                    etaf-org-cache--image-directory))
             (tmp (make-temp-file "etaf-org-img-" nil (concat "." ext))))
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'no-conversion))
                (with-temp-file tmp
                  (set-buffer-multibyte nil)
                  (insert bytes)))
              (rename-file tmp dest t)
              (puthash url dest etaf-org-cache--images)
              (etaf-org-cache-prune-directory etaf-org-cache--image-directory)
              dest)
          (when (file-exists-p tmp)
            (ignore-errors (delete-file tmp))))))))

(defun etaf-org-cache--fetch-async (url callback)
  "Download remote image URL asynchronously; invoke CALLBACK with `(PATH)'.
Return a zero-argument cancel function."
  (if (executable-find "curl")
      (let* ((args (append
                    (list "curl" "-sS" "-L" "-i"
                          "--max-time" (number-to-string etaf-org-cache--fetch-timeout)
                          "--connect-timeout" "10"
                          "--max-filesize" (number-to-string etaf-org-cache--max-image-bytes)
                          "-A" etaf-org-cache--user-agent)
                    (when (null url-proxy-services)
                      (list "--noproxy" "*"))
                    (list url)))
             (cancelled nil)
             (job nil))
        (setq job
              (etaf-process-run
               args
               :name "etaf-org-image-fetch"
               :timeout (+ etaf-org-cache--fetch-timeout 2)
               :coding 'no-conversion
               :environment (etaf-org-cache--no-proxy-env)
               :callback
               (lambda (res)
                 (unless cancelled
                   (let ((path (when (and (eq (plist-get res :status) 'exit)
                                          (eql (plist-get res :exit) 0))
                                 (when-let* ((resp (etaf-org-cache--parse-http-response
                                                    (plist-get res :output))))
                                   (etaf-org-cache--save-image url resp)))))
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
                                   (when-let* ((resp (etaf-org-cache--parse-http-response
                                                      (buffer-substring-no-properties
                                                       (point-min) (point-max)))))
                                     (etaf-org-cache--save-image url resp)))))
                       (funcall callback path)))
                 (when (buffer-live-p buf) (kill-buffer buf)))))
           nil t t)
        (error
         (run-at-time 0 nil callback nil)))
      (lambda () (setq cancelled t)))))

(defun etaf-org-cache--extract-block-urls (block)
  "Return unique HTTP(S) image URLs referenced inside parsed Org BLOCK."
  (let ((urls nil))
    (cl-labels
        ((maybe (url)
           (when (etaf-org-cache--image-url-p url)
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

(defun etaf-org-cache--failed-recently-p (url)
  "Return non-nil when URL failed within `etaf-org-cache--failed-ttl' seconds."
  (when-let* ((ts (gethash url etaf-org-cache--failed)))
    (if (< (- (float-time) ts) etaf-org-cache--failed-ttl)
        t
      (remhash url etaf-org-cache--failed)
      nil)))

(defun etaf-org-cache--pump ()
  "Start queued remote image downloads up to `etaf-org-cache--max-concurrent'."
  (while (and etaf-org-cache--queue
              (< etaf-org-cache--in-flight etaf-org-cache--max-concurrent))
    (let* ((item (pop etaf-org-cache--queue))
           (url (car item))
           (session (cdr item))
           (buf (plist-get session :buffer)))
      (when (and (buffer-live-p buf)
                 (not (etaf-org-cache-image-path url))
                 (not (gethash url etaf-org-cache--running))
                 (not (etaf-org-cache--failed-recently-p url)))
        (if (etaf-org-cache--existing-on-disk url)
            (etaf-org-cache--notify-session session)
          (setq etaf-org-cache--in-flight (1+ etaf-org-cache--in-flight))
          (let ((cancel nil))
            (setq cancel
                  (etaf-org-cache--fetch-async
                   url
                   (lambda (path)
                     (remhash url etaf-org-cache--running)
                     (setq etaf-org-cache--in-flight
                           (max 0 (1- etaf-org-cache--in-flight)))
                     (if path
                         (etaf-org-cache--notify-session session)
                       (puthash url (float-time) etaf-org-cache--failed))
                     (etaf-org-cache--pump))))
            (puthash url cancel etaf-org-cache--running)))))))

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
    (dolist (url (etaf-org-cache--extract-block-urls block))
      (unless (etaf-org-cache-image-path url)
        (etaf-org-cache--existing-on-disk url))))
  block)

(defun etaf-org-cache-request-images (session)
  "Queue asynchronous downloads for uncached remote images in mounted SESSION.
Does nothing when `etaf-org-remote-images' is nil or SESSION has no live buffer."
  (when (and etaf-org-remote-images
             (buffer-live-p (plist-get session :buffer))
             (fboundp 'etaf-org--walk-document-blocks))
    (let ((wanted nil)
          (found-on-disk nil)
          (count 0))
      (etaf-org--walk-document-blocks
       (etaf-org--read session :document)
       (lambda (block)
         (when (< count etaf-org-cache--max-images-per-page)
           (dolist (url (etaf-org-cache--extract-block-urls block))
             (when (< count etaf-org-cache--max-images-per-page)
               (cond
                ((etaf-org-cache-image-path url) nil)
                ((etaf-org-cache--existing-on-disk url)
                 (setq found-on-disk t))
                ((or (gethash url etaf-org-cache--running)
                     (etaf-org-cache--failed-recently-p url))
                 nil)
                (t
                 (setq count (1+ count))
                 (push url wanted))))))))
      (when found-on-disk
        (etaf-org-cache--notify-session session))
      (when wanted
        (dolist (url (delete-dups (nreverse wanted)))
          (unless (cl-some (lambda (pair) (equal (car pair) url))
                           etaf-org-cache--queue)
            (setq etaf-org-cache--queue
                  (nconc etaf-org-cache--queue (list (cons url session))))))
        (etaf-org-cache--pump)))))

(provide 'etaf-org-cache)
;;; etaf-org-cache.el ends here
