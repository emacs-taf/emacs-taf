;;; etaf-web-cache.el --- Fetch, decode, cache and asset store -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Handles reading local HTML files, fetching HTTP(S) pages with charset
;; detection, caching compiled `index.md' / `source.html' / `meta.json', and
;; downloading bounded image assets into each cached page's `assets/' directory.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'url-util)
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
  "Timeout in seconds for synchronous HTTP(S) fetches.
May be an integer or floating-point number of seconds."
  :type 'number
  :group 'etaf-web)

(defconst etaf-web--max-image-bytes (* 5 1024 1024)
  "Hard upper bound in bytes for a single downloaded image (5 MB).")

(defconst etaf-web--max-images-per-page 30
  "Hard upper bound on images cached per page.")

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

(defun etaf-web--page-dir (canonical-url)
  "Return cache directory path for CANONICAL-URL and current compiler version."
  (let ((key (secure-hash 'sha1
                          (concat canonical-url "\0" etaf-web--compiler-version))))
    (expand-file-name (concat "pages/" key)
                      (expand-file-name etaf-web-cache-directory))))

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
;;; HTTP retrieval
;;; ---------------------------------------------------------------------------

(defun etaf-web--parse-http-buffer (buffer url)
  "Parse HTTP response headers and raw body bytes from BUFFER for URL."
  (with-current-buffer buffer
    (set-buffer-multibyte nil)
    (when (zerop (buffer-size))
      (signal 'etaf-web-error
              (list (format "Connection failed while fetching %s: empty response"
                            url))))
    (goto-char (point-min))
    (let ((status 200)
          (reason nil)
          (content-type nil)
          (content-length nil)
          (etag nil)
          (body-start (point-min)))
      (when (re-search-forward "\r?\n\r?\n" nil t)
        (setq body-start (match-end 0))
        (let ((header-text (buffer-substring-no-properties
                            (point-min) (match-beginning 0))))
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
              (setq etag (string-trim (match-string 1 header-text)))))))
      (when (>= status 400)
        (signal 'etaf-web-error
                (list (if (and reason (not (string-empty-p reason)))
                          (format "HTTP %d %s while fetching %s" status reason url)
                        (format "HTTP %d while fetching %s" status url)))))
      (list :status status
            :content-type content-type
            :content-length content-length
            :etag etag
            :body-bytes (buffer-substring-no-properties body-start (point-max))))))

(defun etaf-web--fetch-raw (url)
  "Synchronously fetch URL and return parsed HTTP plist."
  (let* ((timeout (if (and (numberp etaf-web-fetch-timeout)
                           (> etaf-web-fetch-timeout 0))
                      etaf-web-fetch-timeout
                    30))
         (url-request-method "GET")
         (url-show-status nil)
         (url-automatic-caching nil)
         (buffer
          (condition-case err
              (url-retrieve-synchronously url t t timeout)
            (error
             (let ((msg (error-message-string err)))
               (if (string-match-p "timed? out\\|timeout" (downcase msg))
                   (signal 'etaf-web-error
                           (list (format "Timed out after %ss while fetching %s"
                                         timeout url)))
                 (signal 'etaf-web-error
                         (list (format "Connection failed while fetching %s: %s"
                                       url msg)))))))))
    (unless (buffer-live-p buffer)
      (signal 'etaf-web-error
              (list (format "Timed out after %ss while fetching %s"
                            timeout url))))
    (unwind-protect
        (etaf-web--parse-http-buffer buffer url)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;;; ---------------------------------------------------------------------------
;;; Image asset caching
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

(defun etaf-web--download-image (url assets-dir)
  "Download image URL into ASSETS-DIR honoring hard limits; return relpath/nil."
  (condition-case nil
      (let* ((resp (etaf-web--fetch-raw url))
             (ct (plist-get resp :content-type))
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
            (concat "assets/" name))))
    (error nil)))

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

(defun etaf-web--make-image-rewriter (page-dir)
  "Return an image URL rewriter caching bounded images under PAGE-DIR/assets/."
  (let ((assets-dir (expand-file-name "assets" page-dir))
        (seen (make-hash-table :test #'equal))
        (count 0))
    (lambda (url)
      (or (gethash url seen)
          (let ((result
                 (cond
                  ((not etaf-web-download-images) url)
                  ((>= count etaf-web--max-images-per-page) url)
                  ((etaf-web--http-url-p url)
                   (let ((rel (etaf-web--download-image url assets-dir)))
                     (when rel (setq count (1+ count)))
                     (or rel url)))
                  ((etaf-web--file-url-p url)
                   (let ((rel (etaf-web--copy-local-image url assets-dir)))
                     (when rel (setq count (1+ count)))
                     (or rel url)))
                  (t url))))
            (puthash url result seen)
            result)))))

;;; ---------------------------------------------------------------------------
;;; Cache metadata & page materialization
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

(defun etaf-web--prepare-page (source)
  "Fetch or read SOURCE, compile and materialize its cache directory.
Returns plist with `:index-file', `:page-dir', `:url', `:title' and `:cached'."
  (unless (and (stringp source) (not (string-blank-p source)))
    (signal 'etaf-web-error '("Source must be a non-empty file path or URL")))
  (let ((trimmed (string-trim source)))
    (cond
     ((etaf-web--http-url-p trimmed)
      (let* ((canonical (etaf-web--normalize-url trimmed))
             (page-dir (etaf-web--page-dir canonical))
             (index-file (expand-file-name "index.md" page-dir)))
        (if (file-readable-p index-file)
            (list :index-file index-file
                  :page-dir page-dir
                  :url canonical
                  :title (etaf-web--read-meta-title page-dir)
                  :cached t)
          (let* ((resp (etaf-web--fetch-raw canonical))
                 (html (etaf-web--decode-html
                        (plist-get resp :body-bytes)
                        (plist-get resp :content-type)))
                 (rewriter (etaf-web--make-image-rewriter page-dir))
                 (compiled (etaf-web--compile html
                                              :base-url canonical
                                              :image-rewriter rewriter))
                 (title (plist-get compiled :title)))
            (make-directory page-dir t)
            (etaf-web--write-utf8 (expand-file-name "source.html" page-dir) html)
            (etaf-web--write-utf8 index-file (plist-get compiled :markdown))
            (etaf-web--write-meta page-dir canonical title (plist-get resp :etag))
            (list :index-file index-file
                  :page-dir page-dir
                  :url canonical
                  :title title
                  :cached nil)))))
     (t
      (let* ((local-path (if (etaf-web--file-url-p trimmed)
                             (expand-file-name
                              (url-unhex-string
                               (or (url-filename (url-generic-parse-url trimmed)) "")))
                           (expand-file-name trimmed)))
             (raw-bytes (etaf-web--read-file-bytes local-path))
             (html (etaf-web--decode-html raw-bytes nil))
             (canonical (concat "file://" local-path))
             (page-dir (etaf-web--page-dir canonical))
             (index-file (expand-file-name "index.md" page-dir))
             (rewriter (etaf-web--make-image-rewriter page-dir))
             (compiled (etaf-web--compile html
                                          :base-url canonical
                                          :image-rewriter rewriter))
             (title (plist-get compiled :title)))
        (make-directory page-dir t)
        (etaf-web--write-utf8 (expand-file-name "source.html" page-dir) html)
        (etaf-web--write-utf8 index-file (plist-get compiled :markdown))
        (etaf-web--write-meta page-dir canonical title nil)
        (list :index-file index-file
              :page-dir page-dir
              :url canonical
              :title title
              :cached nil))))))

(provide 'etaf-web-cache)
;;; etaf-web-cache.el ends here
