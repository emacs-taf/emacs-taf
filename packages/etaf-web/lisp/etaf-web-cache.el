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

(defun etaf-web--render-dom (url)
  "Return the DOM a browser renders for URL, or nil when it cannot.
Never signals: a missing browser, a crash and a timeout all answer nil."
  (when (and (stringp url) (etaf-web--browser-program))
    (let* ((timeout (if (and (numberp etaf-web-render-timeout)
                             (> etaf-web-render-timeout 0))
                        etaf-web-render-timeout
                      25))
           (deadline (+ (float-time) timeout))
           (buffer (generate-new-buffer " *etaf-web render*"))
           (profile (make-temp-file "etaf-web-profile-" t))
           (stderr (make-temp-file "etaf-web-render-"))
           (process nil)
           (dom nil))
      (unwind-protect
          (progn
            (setq process
                  (make-process
                   :name "etaf-web-render"
                   :buffer buffer
                   :command (list (etaf-web--browser-program)
                                  "--headless=new" "--disable-gpu"
                                  "--no-sandbox" "--hide-scrollbars"
                                  ;; A private profile keeps the render out of
                                  ;; a browser the reader already has open,
                                  ;; which would answer the command instead.
                                  (concat "--user-data-dir=" profile)
                                  "--virtual-time-budget=10000"
                                  "--dump-dom" url)
                   :stderr stderr
                   :noquery t
                   :connection-type 'pipe))
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.1))
            (when (process-live-p process)
              (delete-process process))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (when (and (> (length text) 500)
                           (string-match-p "<html" (downcase text)))
                  (setq dom text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (ignore-errors (delete-directory profile t))
        (ignore-errors (delete-file stderr)))
      dom)))

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

(defun etaf-web--remote-image-references (text)
  "Return the remote image URLs TEXT still points at."
  (let (urls)
    (dolist (regexp '("!\\[[^]]*\\](\\(https?://[^)[:space:]]+\\)"
                      "<img[^>]+src=\"\\(https?://[^\"]+\\)\""))
      (with-temp-buffer
        (insert (or text ""))
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (push (match-string 1) urls))))
    (delete-dups (nreverse urls))))

(defun etaf-web--backfill-images (page-dir index-file)
  "Download images INDEX-FILE still points at remotely, inside PAGE-DIR.
Return non-nil when the file changed.  A cached page keeps working after a
failed download instead of showing placeholders until the cache is deleted."
  (when (and etaf-web-download-images (file-readable-p index-file))
    (let* ((text (etaf-web--read-utf8 index-file))
           (urls (etaf-web--remote-image-references text))
           (rewriter (etaf-web--make-image-rewriter page-dir))
           (changed nil))
      (make-directory (expand-file-name "assets" page-dir) t)
      (dolist (url urls)
        (let ((local (funcall rewriter url)))
          (when (and (stringp local) (not (equal local url)))
            (setq text (replace-regexp-in-string
                        (regexp-quote url) local text t t)
                  changed t))))
      (when changed
        (etaf-web--write-utf8 index-file text))
      changed)))

(defun etaf-web--materialize (canonical page-dir html etag)
  "Compile HTML fetched from CANONICAL into PAGE-DIR and return the plist.
A page that compiles to no prose is rendered through a browser first; when
that fails too, the page carries a notice instead of an empty buffer.  ETAG is
stored in the page metadata."
  (let* ((index-file (expand-file-name "index.md" page-dir))
         (rewriter (etaf-web--make-image-rewriter page-dir))
         (compiled (etaf-web--compile html :base-url canonical
                                      :image-rewriter rewriter))
         (markdown (plist-get compiled :markdown))
         (title (plist-get compiled :title)))
    (when (etaf-web--script-shell-p html markdown)
      (let ((rendered (etaf-web--render-dom canonical)))
        (if rendered
            (setq html rendered
                  compiled (etaf-web--compile html :base-url canonical
                                              :image-rewriter rewriter)
                  markdown (plist-get compiled :markdown)
                  title (plist-get compiled :title))
          (setq markdown
                (etaf-web--notice-markdown
                 canonical
                 (if (etaf-web--browser-program)
                     "这页的正文由 JavaScript 生成，浏览器渲染也没有拿到内容。"
                   "这页的正文由 JavaScript 生成，本机没有找到可用的无头浏览器。"))))))
    (make-directory page-dir t)
    (etaf-web--write-utf8 (expand-file-name "source.html" page-dir) html)
    (etaf-web--write-utf8 index-file markdown)
    (etaf-web--write-meta page-dir canonical title etag)
    (list :index-file index-file
          :page-dir page-dir
          :url canonical
          :title title
          :cached nil)))

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
        (when (file-readable-p index-file)
          (let ((cached (etaf-web--read-utf8 index-file)))
            (if (etaf-web--notice-page-p cached)
                ;; A notice is retried once a renderer can tell more.
                (when (etaf-web--browser-program)
                  (delete-file index-file))
              (if (etaf-web--script-shell-p
                   (or (etaf-web--read-utf8
                        (expand-file-name "source.html" page-dir))
                       "")
                   cached)
                  ;; Compiled before script pages could be rendered.
                  (delete-file index-file)
                (etaf-web--backfill-images page-dir index-file)))))
        (if (file-readable-p index-file)
            (list :index-file index-file
                  :page-dir page-dir
                  :url canonical
                  :title (etaf-web--read-meta-title page-dir)
                  :cached t)
          (let* ((resp (etaf-web--fetch-raw canonical))
                 (html (etaf-web--decode-html
                        (plist-get resp :body-bytes)
                        (plist-get resp :content-type))))
            (etaf-web--materialize canonical page-dir html
                                   (plist-get resp :etag))))))
     (t
      (let* ((local-path (if (etaf-web--file-url-p trimmed)
                             (expand-file-name
                              (url-unhex-string
                               (or (url-filename (url-generic-parse-url trimmed)) "")))
                           (expand-file-name trimmed)))
             (raw-bytes (etaf-web--read-file-bytes local-path))
             (html (etaf-web--decode-html raw-bytes nil))
             (canonical (concat "file://" local-path))
             (page-dir (etaf-web--page-dir canonical)))
        (etaf-web--materialize canonical page-dir html nil))))))

(provide 'etaf-web-cache)
;;; etaf-web-cache.el ends here
