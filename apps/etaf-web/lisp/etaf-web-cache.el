;;; etaf-web-cache.el --- Async fetch, headless render, cache and asset store -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Handles reading local HTML files, asynchronous HTTP(S) fetching with charset
;; detection, asynchronous headless Chromium DOM rendering for script-driven
;; pages, on-disk caching (`index.md' / `source.html' / `meta.json'), and
;; bounded background image downloading into each cached page's `assets/'
;; directory without blocking Emacs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'url-util)
(require 'etaf)
(require 'etaf-web-compile)

(defcustom etaf-web-cache-directory "~/.cache/etaf-web/"
  "Root directory where `etaf-web' stores cached pages and image assets."
  :type 'directory
  :group 'etaf-web)

(defcustom etaf-web-download-images t
  "Whether `etaf-web-open' downloads page images into the local cache.
Hard limits always apply: 5 MB per image and at most 30 images per page.
When nil, remote image URLs remain untouched and render as placeholders."
  :type 'boolean
  :group 'etaf-web)

(defcustom etaf-web-fetch-timeout 30
  "Timeout in seconds for HTTP(S) fetches performed by `etaf-web-open'.
May be an integer or floating-point number of seconds."
  :type 'number
  :group 'etaf-web)

(defcustom etaf-web-render-command nil
  "Program used to render pages whose content a script builds.
nil auto-detects a Chromium-based browser on this machine, the symbol `off'
skips rendering, and a string names the executable to run."
  :type '(choice (const :tag "Auto-detect" nil)
                 (const :tag "Off" off)
                 string)
  :group 'etaf-web)

(defcustom etaf-web-render-timeout 25
  "Seconds to wait for a rendered page before giving up on it."
  :type 'number
  :group 'etaf-web)

(defconst etaf-web--browser-candidates
  '("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "google-chrome" "google-chrome-stable" "chromium" "chromium-browser"
    "microsoft-edge" "brave-browser")
  "Executables tried, in order, when `etaf-web-render-command' is nil.")

(defconst etaf-web--notice-marker ":::note {title=\"这页需要脚本渲染\"}"
  "First line of the reading-view notice for a page with no prose.")

(defconst etaf-web--max-image-bytes (* 5 1024 1024)
  "Hard upper bound in bytes for a single downloaded image (5 MB).")

(defconst etaf-web--max-images-per-page 30
  "Hard upper bound on images cached per page.")

(defconst etaf-web--max-concurrent-images 4
  "Maximum number of image downloads kept in flight concurrently.")

(defconst etaf-web--user-agent
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  "User-Agent header sent for HTTP(S) fetches.")

;;; ---------------------------------------------------------------------------
;;; URL normalization & cache paths
;;; ---------------------------------------------------------------------------

(defun etaf-web--http-url-p (source)
  "Return non-nil when SOURCE is an `http://' or `https://' URL."
  (and (stringp source)
       (string-match-p "\\`https?://" (downcase (string-trim source)))))

(defun etaf-web--file-url-p (source)
  "Return non-nil when SOURCE is a `file://' URL."
  (and (stringp source)
       (string-match-p "\\`file://" (downcase (string-trim source)))))

(defun etaf-web--normalize-url (url)
  "Return a canonical form of URL suitable for cache keys and base URLs.
Lowercases scheme and host, drops default HTTP/HTTPS ports and `#fragment', and
normalizes an empty path to `/'."
  (let* ((trimmed (string-trim url))
         (parsed (url-generic-parse-url trimmed))
         (scheme (downcase (or (url-type parsed) "")))
         (host (and (url-host parsed) (downcase (url-host parsed))))
         (port (url-port-if-non-default parsed))
         (filename (or (url-filename parsed) "")))
    (cond
     ((member scheme '("http" "https"))
      (let* ((path (if (string-empty-p filename) "/" filename))
             (port-part (if port (format ":%d" port) "")))
        (format "%s://%s%s%s" scheme (or host "") port-part path)))
     ((equal scheme "file")
      (format "file://%s" (expand-file-name (url-unhex-string filename))))
     (t trimmed))))

(defun etaf-web--normalize-user-input (input)
  "Normalize user address bar INPUT into a URL or local file path."
  (let ((trimmed (string-trim (or input ""))))
    (cond
     ((string-empty-p trimmed) "")
     ((or (etaf-web--http-url-p trimmed) (etaf-web--file-url-p trimmed))
      trimmed)
     ((or (string-prefix-p "/" trimmed)
          (string-prefix-p "~/" trimmed)
          (string-prefix-p "./" trimmed)
          (string-prefix-p "../" trimmed)
          (file-exists-p trimmed))
      trimmed)
     (t (concat "https://" trimmed)))))

(defun etaf-web--url-parts (url)
  "Return `(HOST . PATH)' display strings for URL."
  (cond
   ((etaf-web--http-url-p url)
    (let* ((parsed (url-generic-parse-url url))
           (host (or (url-host parsed) ""))
           (port (url-port-if-non-default parsed))
           (host-str (if port (format "%s:%d" host port) host))
           (path (or (url-filename parsed) "/")))
      (cons host-str (if (string-empty-p path) "/" path))))
   ((etaf-web--file-url-p url)
    (let ((path (url-unhex-string
                 (or (url-filename (url-generic-parse-url url)) ""))))
      (cons "file" path)))
   (t (cons "" (or url "")))))

(defun etaf-web--url-display-parts (url)
  "Return `(SCHEME HOST PATH)' strings for URL, preserving scheme (e.g. https://)."
  (cond
   ((etaf-web--http-url-p url)
    (let* ((parsed (url-generic-parse-url url))
           (scheme (concat (downcase (or (url-type parsed) "https")) "://"))
           (host (or (url-host parsed) ""))
           (port (url-port-if-non-default parsed))
           (host-str (if port (format "%s:%d" host port) host))
           (path (or (url-filename parsed) "/")))
      (list scheme host-str (if (string-empty-p path) "/" path))))
   ((etaf-web--file-url-p url)
    (let ((path (url-unhex-string
                 (or (url-filename (url-generic-parse-url url)) ""))))
      (list "file://" "" path)))
   (t (list "" "" (or url "")))))

(defun etaf-web--page-dir (canonical-url)
  "Return cache directory path for CANONICAL-URL and current compiler version."
  (let ((key (secure-hash 'sha1
                          (concat canonical-url "\0" etaf-web--compiler-version))))
    (expand-file-name (concat "pages/" key)
                      (expand-file-name etaf-web-cache-directory))))

(defun etaf-web--render-cache-dir ()
  "Return shared Chromium HTTP disk-cache directory under cache root."
  (let ((dir (expand-file-name "render-cache"
                               (expand-file-name etaf-web-cache-directory))))
    (make-directory dir t)
    dir))

(defun etaf-web--validate-source (source)
  "Validate SOURCE string synchronously; return `(:kind :canonical :local-path)'.
Signals `etaf-web-error' on non-string/empty input or unreadable local files."
  (unless (and (stringp source) (not (string-blank-p source)))
    (signal 'etaf-web-error '("Source must be a non-empty file path or URL")))
  (let ((trimmed (string-trim source)))
    (if (etaf-web--http-url-p trimmed)
        (list :kind 'http
              :canonical (etaf-web--normalize-url trimmed))
      (let ((local-path (if (etaf-web--file-url-p trimmed)
                            (expand-file-name
                             (url-unhex-string
                              (or (url-filename (url-generic-parse-url trimmed)) "")))
                          (expand-file-name trimmed))))
        (unless (and (file-exists-p local-path)
                     (file-readable-p local-path)
                     (not (file-directory-p local-path)))
          (signal 'etaf-web-error
                  (list (format "Cannot read HTML file: %s" local-path))))
        (list :kind 'file
              :canonical (concat "file://" local-path)
              :local-path local-path)))))

;;; ---------------------------------------------------------------------------
;;; Charset detection & decoding
;;; ---------------------------------------------------------------------------

(defun etaf-web--charset-to-coding (charset)
  "Map HTML/HTTP CHARSET string to a valid Emacs coding system, or nil."
  (when (and (stringp charset) (not (string-blank-p charset)))
    (let* ((norm (downcase (string-trim charset)))
           (mapped (pcase norm
                     ((or "utf8" "utf-8") 'utf-8)
                     ((or "gb2312" "gbk" "gb18030" "x-gbk") 'gb18030)
                     ((or "latin1" "iso-8859-1" "iso8859-1") 'iso-8859-1)
                     ((or "windows-1252" "cp1252") 'windows-1252)
                     ((or "big5" "big5-hkscs") 'big5)
                     ((or "shift_jis" "shift-jis" "sjis") 'shift_jis)
                     ((or "euc-jp" "eucjp") 'euc-jp)
                     ((or "euc-kr" "euckr") 'euc-kr)
                     (_ (intern norm)))))
      (and (coding-system-p mapped) mapped))))

(defun etaf-web--extract-charset-from-header (content-type)
  "Extract charset name from HTTP CONTENT-TYPE header, or nil."
  (when (and (stringp content-type)
             (let ((case-fold-search t))
               (string-match "charset=[ \t]*[\"']?\\([a-z0-9._-]+\\)"
                             content-type)))
    (match-string 1 content-type)))

(defun etaf-web--extract-charset-from-head (raw-bytes)
  "Scan first 4 KB of RAW-BYTES for a `<meta charset>' declaration, or nil."
  (let* ((prefix (substring raw-bytes 0 (min 4096 (length raw-bytes))))
         (case-fold-search t))
    (when (string-match
           "<meta\\b[^>]*\\bcharset[ \t]*=[ \t]*[\"']?\\([a-z0-9._-]+\\)"
           prefix)
      (match-string 1 prefix))))

(defun etaf-web--decode-html (raw-bytes &optional content-type)
  "Decode unibyte HTML RAW-BYTES using CONTENT-TYPE, `<meta>' or `utf-8'."
  (let ((coding (or (etaf-web--charset-to-coding
                     (etaf-web--extract-charset-from-header content-type))
                    (etaf-web--charset-to-coding
                     (etaf-web--extract-charset-from-head raw-bytes))
                    'utf-8)))
    (decode-coding-string raw-bytes coding)))

;;; ---------------------------------------------------------------------------
;;; Asynchronous HTTP retrieval (non-blocking curl + url-retrieve fallback)
;;; ---------------------------------------------------------------------------

(defun etaf-web--effective-timeout ()
  "Return positive numeric fetch timeout in seconds."
  (if (and (numberp etaf-web-fetch-timeout) (> etaf-web-fetch-timeout 0))
      etaf-web-fetch-timeout
    30))

(defun etaf-web--no-proxy-env ()
  "Return `:environment' overrides clearing proxy variables when Emacs has none."
  (when (null url-proxy-services)
    '("HTTP_PROXY=" "HTTPS_PROXY=" "ALL_PROXY="
      "http_proxy=" "https_proxy=" "all_proxy="
      "NO_PROXY=*" "no_proxy=*")))

(defun etaf-web--parse-http-raw (raw-bytes url)
  "Parse raw unibyte HTTP response RAW-BYTES (including redirects) for URL.
Returns plist `(:status :content-type :content-length :etag :body-bytes)'
or signals `etaf-web-error' on empty response or status >= 400."
  (when (or (not (stringp raw-bytes)) (zerop (length raw-bytes)))
    (signal 'etaf-web-error
            (list (format "Connection failed while fetching %s: empty response"
                          url))))
  (let ((bytes (if (multibyte-string-p raw-bytes)
                   (encode-coding-string raw-bytes 'raw-text)
                 raw-bytes)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert bytes)
      (goto-char (point-min))
    (let ((status 200)
          (reason nil)
          (content-type nil)
          (content-length nil)
          (etag nil)
          (body-start (point-min))
          (more t))
      ;; Advance past 1xx/3xx redirect header blocks emitted by `curl -L -i'.
      (while more
        (setq more nil)
        (when (and (looking-at "HTTP/[0-9.]+[ \t]+\\([0-9]\\{3\\}\\)")
                   (re-search-forward "\r?\n\r?\n" nil t))
          (let* ((hdr-end (match-beginning 0))
                 (next-start (match-end 0))
                 (header-text (buffer-substring-no-properties body-start hdr-end)))
            (setq body-start next-start
                  content-type nil
                  content-length nil
                  etag nil)
            (when (string-match
                   "\\`HTTP/[0-9.]+[ \t]+\\([0-9]\\{3\\}\\)\\(?:[ \t]+\\([^\r\n]+\\)\\)?"
                   header-text)
              (setq status (string-to-number (match-string 1 header-text))
                    reason (and (match-string 2 header-text)
                                (string-trim (match-string 2 header-text)))))
            (let ((case-fold-search t))
              (when (string-match "^content-type:[ \t]*\\([^\r\n]+\\)" header-text)
                (setq content-type (string-trim (match-string 1 header-text))))
              (when (string-match "^content-length:[ \t]*\\([0-9]+\\)" header-text)
                (setq content-length (string-to-number (match-string 1 header-text))))
              (when (string-match "^etag:[ \t]*\\([^\r\n]+\\)" header-text)
                (setq etag (string-trim (match-string 1 header-text)))))
            (goto-char body-start)
            (when (and (or (and (>= status 100) (< status 200))
                           (and (>= status 300) (< status 400)))
                       (looking-at "HTTP/[0-9.]+[ \t]+[0-9]\\{3\\}"))
              (setq more t)))))
      (when (>= status 400)
        (signal 'etaf-web-error
                (list (if (and reason (not (string-empty-p reason)))
                          (format "HTTP %d %s while fetching %s" status reason url)
                        (format "HTTP %d while fetching %s" status url)))))
      (list :status status
            :content-type content-type
            :content-length content-length
            :etag etag
            :body-bytes (buffer-substring-no-properties body-start (point-max)))))))

(defun etaf-web--fetch-via-curl-async (url callback timeout &optional referer)
  "Fetch URL asynchronously via `curl' and invoke CALLBACK with `(RESP ERR)'.
When REFERER is non-nil, sends it as the HTTP Referer header."
  (let* ((args (append
                (list "curl" "-sS" "-L" "-i" "--compressed"
                      "--max-time" (format "%s" timeout)
                      "--connect-timeout" (format "%s" (min timeout 15))
                      "-A" etaf-web--user-agent)
                (when (and (stringp referer) (not (string-empty-p referer)))
                  (list "-e" referer))
                (when (null url-proxy-services)
                  (list "--noproxy" "*"))
                (list url)))
         (cancelled nil)
         (job nil))
    (setq job
          (etaf-process-run
           args
           :name "etaf-web-fetch"
           :timeout (+ timeout 2)
           :coding 'no-conversion
           :environment (etaf-web--no-proxy-env)
           :callback
           (lambda (res)
             (unless cancelled
               (let ((status (plist-get res :status))
                     (code (plist-get res :exit))
                     (out (plist-get res :output))
                     (stderr (string-trim (or (plist-get res :stderr) "")))
                     (msg (or (plist-get res :message) "")))
                 (cond
                  ((or (eq status 'timeout) (eql code 28))
                   (funcall callback nil
                            (list :kind 'timeout
                                  :message (format "Timed out after %ss while fetching %s"
                                                   timeout url))))
                  ((and (eq status 'exit) (eql code 0))
                   (condition-case err
                       (funcall callback (etaf-web--parse-http-raw out url) nil)
                     (etaf-web-error
                      (let ((emsg (or (and (stringp (cadr err)) (cadr err))
                                      (error-message-string err))))
                        (funcall callback nil
                                 (list :kind (if (string-prefix-p "HTTP " emsg)
                                                 'http 'connection)
                                       :message emsg))))))
                  (t
                   (let ((detail (cond
                                  ((not (string-empty-p stderr)) stderr)
                                  ((not (string-empty-p msg)) msg)
                                  (t (format "exit %S" code)))))
                     (funcall callback nil
                              (list :kind 'connection
                                    :message (format "Connection failed while fetching %s: %s"
                                                     url detail)))))))))))
    (lambda ()
      (setq cancelled t)
      (when job (etaf-process-cancel job)))))

(defun etaf-web--fetch-via-url-async (url callback timeout)
  "Fallback async fetch of URL using `url-retrieve' with TIMEOUT seconds."
  (let ((settled nil)
        (timer nil)
        (buf nil)
        (url-request-method "GET")
        (url-show-status nil)
        (url-automatic-caching nil))
    (cl-labels
        ((finish (resp err)
           (unless settled
             (setq settled t)
             (when (timerp timer) (cancel-timer timer) (setq timer nil))
             (when (buffer-live-p buf)
               (let ((proc (get-buffer-process buf)))
                 (when (process-live-p proc) (delete-process proc)))
               (kill-buffer buf))
             (funcall callback resp err))))
      (setq timer
            (run-with-timer
             timeout nil
             (lambda ()
               (finish nil (list :kind 'timeout
                                 :message (format "Timed out after %ss while fetching %s"
                                                  timeout url))))))
      (condition-case err
          (setq buf
                (url-retrieve
                 url
                 (lambda (status)
                   (if-let* ((uerr (plist-get status :error)))
                       (let ((msg (format "%S" uerr)))
                         (finish nil (list :kind 'connection
                                           :message (format "Connection failed while fetching %s: %s"
                                                            url msg))))
                     (let ((raw (when (buffer-live-p (current-buffer))
                                  (set-buffer-multibyte nil)
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))
                       (condition-case perr
                           (finish (etaf-web--parse-http-raw raw url) nil)
                         (etaf-web-error
                          (let ((emsg (or (and (stringp (cadr perr)) (cadr perr))
                                          (error-message-string perr))))
                            (finish nil (list :kind (if (string-prefix-p "HTTP " emsg)
                                                        'http 'connection)
                                              :message emsg))))))))
                 nil t t))
        (error
         (finish nil (list :kind 'connection
                           :message (format "Connection failed while fetching %s: %s"
                                            url (error-message-string err)))))))
    (lambda ()
      (unless settled
        (setq settled t)
        (when (timerp timer) (cancel-timer timer) (setq timer nil))
        (when (buffer-live-p buf)
          (let ((proc (get-buffer-process buf)))
            (when (process-live-p proc) (delete-process proc)))
          (kill-buffer buf))))))

(defun etaf-web--fetch-raw-async (url callback &optional timeout referer)
  "Fetch URL asynchronously and call CALLBACK with `(RESP ERR-PLIST)'.
When REFERER is non-nil, passes it as HTTP Referer (for page assets).
Returns a zero-argument cancel function."
  (let ((eff-timeout (or timeout (etaf-web--effective-timeout))))
    (if (executable-find "curl")
        (etaf-web--fetch-via-curl-async url callback eff-timeout referer)
      (etaf-web--fetch-via-url-async url callback eff-timeout))))

;;; ---------------------------------------------------------------------------
;;; Image asset storage & async parallel backfill
;;; ---------------------------------------------------------------------------

(defun etaf-web--image-extension (url content-type)
  "Infer an image file extension from CONTENT-TYPE or URL."
  (let ((mime (and (stringp content-type)
                   (downcase (car (split-string content-type ";"))))))
    (or (pcase (and mime (string-trim mime))
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
        "img")))

(defun etaf-web--write-bytes (file bytes)
  "Write unibyte BYTES to FILE creating parent directories."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'no-conversion))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert bytes))))

(defun etaf-web--write-utf8 (file text)
  "Write UTF-8 TEXT to FILE creating parent directories."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file file
      (insert text))))

(defun etaf-web--copy-local-image (file-url assets-dir)
  "Copy local FILE-URL into ASSETS-DIR if readable and within size limit."
  (condition-case nil
      (let* ((parsed (url-generic-parse-url file-url))
             (path (expand-file-name (url-unhex-string (or (url-filename parsed) ""))))
             (attrs (and (file-readable-p path) (file-attributes path)))
             (size (and attrs (file-attribute-size attrs))))
        (when (and attrs (not (file-directory-p path))
                   (integerp size) (> size 0)
                   (<= size etaf-web--max-image-bytes))
          (let* ((ext (etaf-web--image-extension path nil))
                 (name (format "%s.%s" (secure-hash 'sha1 file-url) ext))
                 (dest (expand-file-name name assets-dir)))
            (make-directory assets-dir t)
            (copy-file path dest t)
            (concat "assets/" name))))
    (error nil)))

(defun etaf-web--existing-asset-for-url (url assets-dir)
  "Return existing relative `assets/...' path for URL under ASSETS-DIR, or nil."
  (when (file-directory-p assets-dir)
    (let* ((prefix (secure-hash 'sha1 url))
           (matches (directory-files assets-dir nil
                                     (concat "\\`" (regexp-quote prefix) "\\."))))
      (when matches
        (concat "assets/" (car matches))))))

(defun etaf-web--make-local-image-rewriter (page-dir)
  "Return a fast non-blocking image rewriter for Phase 1 compilation.
Copies `file://' images and reuses already-cached HTTP(S) assets under
PAGE-DIR/assets/, leaving uncached remote URLs for background async backfill."
  (let ((assets-dir (expand-file-name "assets" page-dir))
        (seen (make-hash-table :test #'equal))
        (count 0))
    (lambda (url)
      (or (gethash url seen)
          (let ((result
                 (cond
                  ((not etaf-web-download-images) url)
                  ((>= count etaf-web--max-images-per-page) url)
                  ((etaf-web--file-url-p url)
                   (let ((rel (etaf-web--copy-local-image url assets-dir)))
                     (when rel (setq count (1+ count)))
                     (or rel url)))
                  ((etaf-web--http-url-p url)
                   (let ((rel (etaf-web--existing-asset-for-url url assets-dir)))
                     (when rel (setq count (1+ count)))
                     (or rel url)))
                  (t url))))
            (puthash url result seen)
            result)))))

(defun etaf-web--save-downloaded-image (url resp assets-dir)
  "Validate HTTP RESP for image URL and write to ASSETS-DIR; return relpath/nil."
  (let* ((ct (plist-get resp :content-type))
         (declared-len (plist-get resp :content-length))
         (bytes (plist-get resp :body-bytes)))
    (when (and (stringp bytes)
               (> (length bytes) 0)
               (<= (length bytes) etaf-web--max-image-bytes)
               (or (null declared-len)
                   (<= declared-len etaf-web--max-image-bytes))
               (not (and (stringp ct)
                         (string-prefix-p "text/html" (downcase ct)))))
      (let* ((ext (etaf-web--image-extension url ct))
             (name (format "%s.%s" (secure-hash 'sha1 url) ext))
             (dest (expand-file-name name assets-dir)))
        (etaf-web--write-bytes dest bytes)
        (concat "assets/" name)))))

(defun etaf-web--remote-image-references (text)
  "Return unique remote HTTP(S) image URLs that TEXT still references."
  (let (urls)
    (dolist (regexp '("!\\[[^]]*\\](\\(https?://[^)[:space:]]+\\)"
                      "<img[^>]+src=\"\\(https?://[^\"]+\\)\""))
      (with-temp-buffer
        (insert (or text ""))
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (push (match-string 1) urls))))
    (delete-dups (nreverse urls))))

(defun etaf-web--cached-asset-count (assets-dir)
  "Return number of image files currently cached inside ASSETS-DIR."
  (if (file-directory-p assets-dir)
      (length (cl-remove-if (lambda (f) (member f '("." "..")))
                            (directory-files assets-dir)))
    0))

(defun etaf-web--backfill-images-async (page-dir index-file on-done &optional page-url)
  "Asynchronously download remote images referenced by INDEX-FILE into PAGE-DIR.
Honors `etaf-web-download-images', 5 MB per image and 30 images per page.
Optional PAGE-URL is sent as the HTTP Referer header so hotlink-checked assets
load cleanly.  Calls ON-DONE with non-nil when INDEX-FILE was updated.
Returns a canceller."
  (if (or (not etaf-web-download-images) (not (file-readable-p index-file)))
      (progn
        (when on-done (funcall on-done nil))
        (lambda () nil))
    (let* ((assets-dir (expand-file-name "assets" page-dir))
           (text (etaf-web--read-utf8 index-file))
           (all-urls (etaf-web--remote-image-references text))
           (existing-count (etaf-web--cached-asset-count assets-dir))
           (budget (max 0 (- etaf-web--max-images-per-page existing-count)))
           (queue (seq-take all-urls budget))
           (replacements nil)
           (in-flight 0)
           (cancels nil)
           (finished nil)
           (cancelled nil))
      (if (null queue)
          (progn
            (when on-done (funcall on-done nil))
            (lambda () nil))
        (cl-labels
            ((finish ()
               (unless (or cancelled finished)
                 (setq finished t)
                 (let ((changed nil))
                   (when (and replacements (file-readable-p index-file))
                     (let ((cur (etaf-web--read-utf8 index-file)))
                       (dolist (pair replacements)
                         (let ((updated (replace-regexp-in-string
                                         (regexp-quote (car pair))
                                         (cdr pair) cur t t)))
                           (unless (equal updated cur)
                             (setq cur updated changed t))))
                       (when changed
                         (etaf-web--write-utf8 index-file cur))))
                   (when on-done (funcall on-done changed)))))
             (pump ()
               (unless cancelled
                 (while (and queue (< in-flight etaf-web--max-concurrent-images))
                   (let* ((url (pop queue))
                          (existing (etaf-web--existing-asset-for-url url assets-dir)))
                     (if existing
                         (push (cons url existing) replacements)
                       (setq in-flight (1+ in-flight))
                       (let ((cancel nil))
                         (setq cancel
                               (etaf-web--fetch-raw-async
                                url
                                (lambda (resp _err)
                                  (setq cancels (delq cancel cancels)
                                        in-flight (1- in-flight))
                                  (unless cancelled
                                    (when resp
                                      (when-let* ((rel (etaf-web--save-downloaded-image
                                                        url resp assets-dir)))
                                        (push (cons url rel) replacements)))
                                    (pump)))
                                (min (etaf-web--effective-timeout) 15)
                                page-url))
                         (push cancel cancels)))))
                 (when (and (null queue) (zerop in-flight))
                   (finish)))))
          (pump))
        (lambda ()
          (setq cancelled t)
          (dolist (fn cancels) (ignore-errors (funcall fn)))
          (setq cancels nil))))))

;;; ---------------------------------------------------------------------------
;;; Cache metadata & script-shell detection
;;; ---------------------------------------------------------------------------

(defun etaf-web--read-meta-title (page-dir)
  "Return cached page title from PAGE-DIR/meta.json, or nil."
  (let ((meta-file (expand-file-name "meta.json" page-dir)))
    (when (file-readable-p meta-file)
      (condition-case nil
          (let ((data (json-parse-string
                       (with-temp-buffer
                         (insert-file-contents meta-file)
                         (buffer-string))
                       :object-type 'alist)))
            (let ((title (alist-get 'title data)))
              (and (stringp title) (not (string-empty-p title)) title)))
        (error nil)))))

(defun etaf-web--write-meta (page-dir url title etag)
  "Write PAGE-DIR/meta.json recording URL, fetch time, TITLE and ETAG."
  (let ((payload (json-encode
                  `((url . ,url)
                    (fetched_at . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
                    (title . ,(or title :null))
                    (etag . ,(or etag :null))
                    (compiler_version . ,etaf-web--compiler-version)))))
    (etaf-web--write-utf8 (expand-file-name "meta.json" page-dir)
                          (concat payload "\n"))))

(defun etaf-web--read-file-bytes (path)
  "Read raw unibyte contents of local file PATH."
  (unless (and (file-exists-p path) (file-readable-p path)
               (not (file-directory-p path)))
    (signal 'etaf-web-error (list (format "Cannot read HTML file: %s" path))))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-web--read-utf8 (file)
  "Return the UTF-8 contents of FILE, or nil when it cannot be read."
  (when (file-readable-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun etaf-web--browser-program ()
  "Return the browser executable used to render script-built pages, or nil."
  (let ((configured etaf-web-render-command))
    (cond
     ((eq configured 'off) nil)
     ((and (stringp configured) (not (string-empty-p configured)))
      (executable-find configured))
     ((stringp configured) nil)
     (t (cl-find-if #'executable-find etaf-web--browser-candidates)))))

(defun etaf-web--render-dom-async (url callback)
  "Render URL headlessly via `etaf-process-run' without blocking Emacs.
Calls CALLBACK with rendered DOM string or nil.  Returns a canceller that
terminates Chromium and cleans up its private profile directory."
  (let ((program (and (stringp url) (etaf-web--browser-program))))
    (if (not program)
        (progn
          (run-at-time 0 nil callback nil)
          (lambda () nil))
      (let* ((timeout (if (and (numberp etaf-web-render-timeout)
                               (> etaf-web-render-timeout 0))
                          etaf-web-render-timeout
                        25))
             (profile (make-temp-file "etaf-web-profile-" t))
             (disk-cache (etaf-web--render-cache-dir))
             (args (append
                    (list program
                          "--headless=new" "--disable-gpu"
                          "--no-sandbox" "--hide-scrollbars"
                          "--no-first-run" "--no-default-browser-check"
                          "--disable-extensions" "--disable-sync"
                          "--disable-background-networking"
                          "--disable-component-update"
                          "--disable-default-apps" "--mute-audio"
                          "--blink-settings=imagesEnabled=false"
                          (concat "--user-data-dir=" profile)
                          (concat "--disk-cache-dir=" disk-cache)
                          "--virtual-time-budget=3000")
                    (when (null url-proxy-services)
                      (list "--no-proxy-server"))
                    (list "--dump-dom" url)))
             (cancelled nil)
             (job nil))
        (cl-labels ((cleanup ()
                      (when (file-directory-p profile)
                        (ignore-errors (delete-directory profile t)))))
          (setq job
                (etaf-process-run
                 args
                 :name "etaf-web-render"
                 :timeout timeout
                 :coding 'utf-8-unix
                 :environment (etaf-web--no-proxy-env)
                 :callback
                 (lambda (res)
                   (cleanup)
                   (unless cancelled
                     (let ((text (and (eq (plist-get res :status) 'exit)
                                      (plist-get res :output))))
                       (if (and (stringp text)
                                (> (length text) 500)
                                (string-match-p "<html" (downcase text)))
                           (funcall callback text)
                         (funcall callback nil)))))))
          (lambda ()
            (setq cancelled t)
            (when job (etaf-process-cancel job))
            (cleanup)))))))

(defun etaf-web--prose-text (markdown)
  "Return MARKDOWN's readable prose, without syntax, targets or front matter."
  (let* ((text (or markdown ""))
         (body (if (string-match "\\`---\n\\(?:.\|\n\\)*?\n---\n" text)
                   (substring text (match-end 0))
                 text))
         (plain (replace-regexp-in-string "\\]([^)]*)" "]" body))
         (plain (replace-regexp-in-string "<[^>]*>" " " plain))
         (plain (replace-regexp-in-string "\\(?:https?\\|browser\\):[^[:space:]]+" " " plain)))
    (string-trim (replace-regexp-in-string "[`*_#>|:~\\[\\]()!-]" " " plain))))

(defun etaf-web--markdown-thin-p (markdown)
  "Return non-nil when MARKDOWN carries no sentence of its own.
A page shell keeps its navigation words but no prose, so a long line is the
signal that a page has something to read.  Link targets, image URLs and front
matter do not count."
  (let* ((prose (etaf-web--prose-text markdown))
         (chars (length (replace-regexp-in-string "[ \t\n]+" " " prose)))
         (longest (apply #'max 0
                         (mapcar (lambda (line) (length (string-trim line)))
                                 (split-string prose "\n")))))
    (and (< longest 40) (< chars 400))))

(defun etaf-web--script-shell-p (html markdown)
  "Return non-nil when HTML runs a script and MARKDOWN has no prose.
A page that ships a sentence of its own is never treated as a shell, even when
it also loads scripts."
  (and (stringp html)
       (string-match-p "<script" (downcase html))
       (etaf-web--markdown-thin-p markdown)))

(defun etaf-web--notice-page-p (text)
  "Return non-nil when TEXT is the notice shown for a page with no prose."
  (and (stringp text) (string-prefix-p etaf-web--notice-marker text)))

(defun etaf-web--notice-markdown (url reason)
  "Return the reading-view notice for URL that yielded no prose, with REASON."
  (format (concat "%s\n%s\n\n"
                  "HTML 里没有正文，所以现在读不到内容。\n\n"
                  "[在浏览器打开](browser:%s)\n:::")
          etaf-web--notice-marker reason url))

;;; ---------------------------------------------------------------------------
;;; Unified asynchronous page materialization & job control
;;; ---------------------------------------------------------------------------

(cl-defstruct (etaf-web--load-job (:constructor etaf-web--load-job-create))
  "Handle for an in-flight asynchronous page load and its background tasks."
  url
  cancelled
  cancels)

(defun etaf-web--job-add-cancel (job fn)
  "Register canceller FN on JOB, invoking immediately if already cancelled."
  (if (etaf-web--load-job-cancelled job)
      (when fn (ignore-errors (funcall fn)))
    (when fn (push fn (etaf-web--load-job-cancels job)))))

(defun etaf-web--cancel-job (job)
  "Cancel JOB and stop every active subprocess/timer without orphan processes."
  (when (and job (not (etaf-web--load-job-cancelled job)))
    (setf (etaf-web--load-job-cancelled job) t)
    (dolist (fn (etaf-web--load-job-cancels job))
      (ignore-errors (funcall fn)))
    (setf (etaf-web--load-job-cancels job) nil)))

(defun etaf-web--write-and-finish (job canonical page-dir html markdown title etag
                                       on-stage on-ready on-images)
  "Write compiled artifacts for JOB into PAGE-DIR, emit ready, backfill images."
  (unless (etaf-web--load-job-cancelled job)
    (let ((index-file (expand-file-name "index.md" page-dir)))
      (make-directory page-dir t)
      (etaf-web--write-utf8 (expand-file-name "source.html" page-dir) html)
      (etaf-web--write-utf8 index-file markdown)
      (etaf-web--write-meta page-dir canonical title etag)
      (when on-stage (funcall on-stage 'done "完成" 1.0))
      (when on-ready
        (funcall on-ready
                 (list :index-file index-file
                       :page-dir page-dir
                       :url canonical
                       :title title
                       :cached nil)))
      ;; Phase 2: asynchronously backfill remote images after text is readable.
      (when (and (not (etaf-web--load-job-cancelled job))
                 etaf-web-download-images
                 (etaf-web--remote-image-references markdown))
        (etaf-web--job-add-cancel
         job
         (etaf-web--backfill-images-async
          page-dir index-file
          (lambda (changed)
            (when (and changed (not (etaf-web--load-job-cancelled job)) on-images)
              (funcall on-images index-file)))
          canonical))))))

(cl-defun etaf-web--load-page-async (source &key force on-stage on-ready on-images on-error)
  "Load SOURCE asynchronously, returning an `etaf-web--load-job' handle.
FORCE bypasses any cached `index.md'.  ON-STAGE receives `(STAGE LABEL
PROGRESS)'.  ON-READY receives a plist `(:index-file :page-dir :url :title
:cached)'.  ON-IMAGES receives INDEX-FILE when background image downloads
update it.  ON-ERROR receives `(:kind :message :url :has-cache)'.
Signals `etaf-web-error' synchronously only on invalid SOURCE or unreadable
local HTML files."
  (let* ((validated (etaf-web--validate-source source))
         (kind (plist-get validated :kind))
         (canonical (plist-get validated :canonical))
         (page-dir (etaf-web--page-dir canonical))
         (index-file (expand-file-name "index.md" page-dir))
         (job (etaf-web--load-job-create :url canonical)))
    (if (eq kind 'file)
        (let* ((local-path (plist-get validated :local-path))
               (raw-bytes (etaf-web--read-file-bytes local-path))
               (html (etaf-web--decode-html raw-bytes nil))
               (rewriter (etaf-web--make-local-image-rewriter page-dir))
               (compiled (etaf-web--compile html :base-url canonical
                                            :image-rewriter rewriter))
               (markdown (plist-get compiled :markdown))
               (title (plist-get compiled :title)))
          (etaf-web--write-and-finish job canonical page-dir html markdown title nil
                                      on-stage on-ready on-images))
      ;; HTTP(S) page: check cache first unless FORCE is non-nil.
      (let ((use-cache nil))
        (when (and (not force) (file-readable-p index-file))
          (let ((cached (etaf-web--read-utf8 index-file)))
            (cond
             ((etaf-web--notice-page-p cached)
              ;; Retry notice once a headless browser is available.
              (unless (etaf-web--browser-program)
                (setq use-cache t)))
             ((etaf-web--script-shell-p
               (or (etaf-web--read-utf8 (expand-file-name "source.html" page-dir)) "")
               cached)
              (setq use-cache nil))
             (t (setq use-cache t)))))
        (if use-cache
            (progn
              (when on-stage (funcall on-stage 'done "缓存" 1.0))
              (when on-ready
                (funcall on-ready
                         (list :index-file index-file
                               :page-dir page-dir
                               :url canonical
                               :title (etaf-web--read-meta-title page-dir)
                               :cached t)))
              (when (and (not (etaf-web--load-job-cancelled job))
                         etaf-web-download-images)
                (etaf-web--job-add-cancel
                 job
                 (etaf-web--backfill-images-async
                  page-dir index-file
                  (lambda (changed)
                    (when (and changed (not (etaf-web--load-job-cancelled job))
                               on-images)
                      (funcall on-images index-file)))
                  canonical))))
          ;; Fresh async HTTP fetch -> optional async Chrome render -> compile.
          (when on-stage (funcall on-stage 'fetching "抓取中" 0.15))
          (etaf-web--job-add-cancel
           job
           (etaf-web--fetch-raw-async
            canonical
            (lambda (resp err)
              (unless (etaf-web--load-job-cancelled job)
                (if err
                    (when on-error
                      (funcall on-error
                               (list :kind (plist-get err :kind)
                                     :message (plist-get err :message)
                                     :url canonical
                                     :has-cache (and (file-readable-p index-file) t))))
                  (let* ((etag (plist-get resp :etag))
                         (html (etaf-web--decode-html
                                (plist-get resp :body-bytes)
                                (plist-get resp :content-type)))
                         (rewriter (etaf-web--make-local-image-rewriter page-dir)))
                    (when on-stage (funcall on-stage 'compiling "编译中" 0.55))
                    (let* ((compiled (etaf-web--compile html :base-url canonical
                                                        :image-rewriter rewriter))
                           (markdown (plist-get compiled :markdown))
                           (title (plist-get compiled :title)))
                      (if (not (etaf-web--script-shell-p html markdown))
                          (etaf-web--write-and-finish
                           job canonical page-dir html markdown title etag
                           on-stage on-ready on-images)
                        ;; Script-driven shell: render asynchronously if browser exists.
                        (if (not (etaf-web--browser-program))
                            (etaf-web--write-and-finish
                             job canonical page-dir html
                             (etaf-web--notice-markdown
                              canonical
                              "这页的正文由 JavaScript 生成，本机没有找到可用的无头浏览器。")
                             title etag on-stage on-ready on-images)
                          (when on-stage (funcall on-stage 'rendering "渲染中" 0.35))
                          (etaf-web--job-add-cancel
                           job
                           (etaf-web--render-dom-async
                            canonical
                            (lambda (rendered)
                              (unless (etaf-web--load-job-cancelled job)
                                (when on-stage (funcall on-stage 'compiling "编译中" 0.85))
                                (let* ((r-rewriter (and rendered
                                                        (etaf-web--make-local-image-rewriter page-dir)))
                                       (r-comp (and rendered
                                                    (etaf-web--compile rendered
                                                                       :base-url canonical
                                                                       :image-rewriter r-rewriter)))
                                       (r-md (and r-comp (plist-get r-comp :markdown)))
                                       (r-title (or (and r-comp (plist-get r-comp :title)) title)))
                                  (if (and r-md (not (etaf-web--markdown-thin-p r-md)))
                                      (etaf-web--write-and-finish
                                       job canonical page-dir rendered r-md r-title etag
                                       on-stage on-ready on-images)
                                    (etaf-web--write-and-finish
                                     job canonical page-dir html
                                     (etaf-web--notice-markdown
                                      canonical
                                      "这页的正文由 JavaScript 生成，浏览器渲染也没有拿到内容。")
                                    title etag on-stage on-ready on-images)))))))))))))))))))
    job))

(provide 'etaf-web-cache)
;;; etaf-web-cache.el ends here
