;;; etaf-bili-service.el --- Bilibili web API client -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The application's only outside world: the Bilibili web API, driven through
;; curl child processes.  Every call is asynchronous -- CALLBACK runs later in
;; the Emacs event loop with `(:ok DATA)' or `(:error MESSAGE :hint HINT)'.
;;
;; Requests are plists keyed by `:op':
;;   Discovery: :popular, :ranking, :rcmd, :dynamic, :toview, :history,
;;              :fav-folders, :fav-list, :space, :search, :related
;;   Video/Play: :video, :play, :resolve-url, :player-info, :subtitle-body,
;;               :danmaku, :comments, :cover
;;   Actions: :like, :coin, :toview-add, :fav-add, :heartbeat
;;
;; The `:play' operation chains video metadata and WBI-signed DASH playurl
;; resolution (`fnval=4048'), preferring H.264/HEVC codecs, keeping backup CDN
;; URLs, and returning a pre-normalized `etaf-video' source plist (`:kind
;; 'url', `:width', `:height', `:fps', `:duration', `:audio') so playback
;; starts with zero synchronous ffprobe calls.
;;
;; Cover downloads never send or write `cookies.txt', avoiding concurrent jar
;; corruption and unnecessary credential exposure to the image CDN.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url-util)
(require 'xml)
(require 'etaf)
(require 'etaf-media)

(define-error 'etaf-bili-error "Bilibili client error")

(defcustom etaf-bili-state-directory
  (locate-user-emacs-file "etaf-bili/")
  "Directory holding the client's cookie jar, cover cache and local state."
  :type 'directory
  :group 'etaf-bili)

(defcustom etaf-bili-request-timeout 20
  "Seconds before one backend request is abandoned."
  :type 'number
  :group 'etaf-bili)

(defcustom etaf-bili-curl-program "curl"
  "curl executable used for every request."
  :type 'string
  :group 'etaf-bili)

(defcustom etaf-bili-preferred-quality 80
  "Preferred Bilibili quality id when opening a video (80 = 1080P)."
  :type 'integer
  :group 'etaf-bili)

(defcustom etaf-bili-preferred-codecs '("avc" "hev" "av01")
  "Ordered video codec prefix preference when selecting a DASH track.
H.264 (`avc') is preferred first for broad hardware decoding and low CPU."
  :type '(repeat string)
  :group 'etaf-bili)

(defconst etaf-bili--api-root "https://api.bilibili.com"
  "Root of the web API endpoints this client calls.")

(defconst etaf-bili--referer "https://www.bilibili.com"
  "Referer sent with API and stream requests.")

(defconst etaf-bili--user-agent
  (concat "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
          "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
  "Browser user agent sent with every request.")

(defconst etaf-bili--cover-cache-limit 400
  "Maximum cached cover files kept under `etaf-bili-state-directory/covers/'.")

(defconst etaf-bili--mixin-key-tab
  [46 47 18 2 53 8 23 32 15 50 10 31 58 3 45 35
   27 43 5 49 33 9 42 19 29 28 14 39 12 38 41 13
   37 48 7 16 24 55 40 61 26 17 0 1 60 51 30 4
   22 25 54 21 56 59 6 63 57 62 11 36 20 34 44 52]
  "WBI permutation table: index i of the mixed key comes from position TAB[i].")

(defconst etaf-bili-ranking-partitions
  '((0 . "全站") (188 . "科技") (36 . "知识") (4 . "游戏") (1 . "动画") (3 . "音乐"))
  "Ranking partition id and display name pairs.")

(defconst etaf-bili-search-orders
  '(("totalrank" . "综合") ("click" . "最多播放") ("pubdate" . "最新发布") ("dm" . "最多弹幕"))
  "Search sort order values and display labels.")

(defvar etaf-bili-client-factory nil
  "Function returning the backend client used by new sessions.
It is called with no arguments and must return a client built by
`etaf-bili-make-client', or any function accepting (REQUEST CALLBACK) as
`etaf-bili-client-call' documents.  Nil selects the default curl client;
tests bind this to a fake client.")

;;; Direct target parsing (BV / av / URL)

(defun etaf-bili-parse-target (input)
  "Parse INPUT as a direct Bilibili video target, or return nil.
Recognizes BV ids, av numbers, bilibili.com video URLs (including optional
`p=' part index and `t=' start seconds) and b23.tv short URLs.
Returns a plist with `:bvid', `:aid' or `:short-url' plus optional `:page'
and `:start'."
  (when (stringp input)
    (let* ((text (string-trim input))
           (page (when (string-match "[?&]p=\\([0-9]+\\)" text)
                   (string-to-number (match-string 1 text))))
           (start (when (string-match "[?&]t=\\([0-9]+\\(?:\\.[0-9]+\\)?\\)" text)
                    (string-to-number (match-string 1 text))))
           (base
            (cond
             ((string-match "\\(BV[0-9A-Za-z]\\{10\\}\\)" text)
              (list :bvid (match-string 1 text)))
             ((string-match "\\`\\(?:https?://\\(?:www\\|m\\)\\.bilibili\\.com/video/\\)?[aA][vV]\\([0-9]+\\)" text)
              (list :aid (string-to-number (match-string 1 text))))
             ((string-match "\\(https?://b23\\.tv/[0-9A-Za-z_-]+\\)" text)
              (list :short-url (match-string 1 text)))
             (t nil))))
      (when base
        (append base
                (when (and page (> page 0)) (list :page page))
                (when (and start (> start 0)) (list :start start)))))))

;;; WBI signing

(defun etaf-bili--mixin-key (img-key sub-key)
  "Return the WBI mixin key from IMG-KEY and SUB-KEY."
  (let* ((raw (concat img-key sub-key))
         (length (length raw)))
    (unless (> length 0)
      (signal 'etaf-bili-error (list "Empty WBI keys")))
    (substring
     (apply #'string
            (mapcar (lambda (index) (aref raw (min index (1- length))))
                    etaf-bili--mixin-key-tab))
     0 (min 32 length))))

(defun etaf-bili-wbi-query (params mixin-key &optional wts)
  "Sign PARAMS with MIXIN-KEY and return the query string with `w_rid'.
PARAMS is an alist of string keys and values; a `wts' timestamp (defaulting
to the current time) is appended, the result is sorted by key and encoded
like `encodeURIComponent' before the MD5, and `w_rid' is appended to the
returned query."
  (unless mixin-key
    (signal 'etaf-bili-error (list "WBI keys are not available")))
  (let* ((params (append params
                         (list (cons "wts" (or wts
                                               (number-to-string
                                                (time-convert nil 'integer)))))))
         (sorted (sort (copy-sequence params)
                       (lambda (a b) (string< (car a) (car b)))))
         (query (mapconcat (lambda (pair)
                             (format "%s=%s"
                                     (etaf-bili--urlencode (car pair))
                                     (etaf-bili--urlencode (cdr pair))))
                           sorted "&"))
         (rid (secure-hash 'md5 (concat query mixin-key))))
    (concat query "&w_rid=" rid)))

(defun etaf-bili--urlencode (text)
  "Urlencode TEXT the way `encodeURIComponent' and Bilibili WBI expect."
  (url-hexify-string (or text "")
                     (string-to-list
                      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")))

;;; JSON helpers

(defun etaf-bili--get (alist key)
  "Return KEY's value in ALIST."
  (and (listp alist) (cdr (assq key alist))))

(defun etaf-bili--rows (value)
  "Return the elements of a JSON array VALUE in either json.el shape."
  (cond
   ((null value) nil)
   ((and (consp value) (eq (car value) 'list)) (cdr value))
   ((listp value) (append value nil))
   (t nil)))

(defun etaf-bili--get-in (alist keys)
  "Walk KEYS through nested ALISTs, returning nil when a step is missing."
  (let ((value alist))
    (while (and keys value)
      (setq value (and (listp value) (etaf-bili--get value (car keys)))
            keys (cdr keys)))
    value))

(defun etaf-bili--https-url (url)
  "Normalize protocol-relative or http URL to https, or return empty string."
  (cond
   ((not (stringp url)) "")
   ((string-prefix-p "//" url) (concat "https:" url))
   ((string-prefix-p "http://" url) (concat "https://" (substring url 7)))
   (t url)))

;;; Presentation & parsing helpers

(defun etaf-bili-clean-title (title)
  "Return TITLE without search highlighting markup and HTML entities."
  (when title
    (let ((text (replace-regexp-in-string "<[^>]*>" "" title)))
      (dolist (pair '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">")
                      ("&quot;" . "\"") ("&#39;" . "'") ("&apos;" . "'")))
        (setq text (replace-regexp-in-string
                    (regexp-quote (car pair)) (cdr pair) text)))
      text)))

(defun etaf-bili--seconds (duration)
  "Return DURATION in seconds from a number or `MM:SS'/`HH:MM:SS' string."
  (save-match-data
    (cond
     ((numberp duration) (round duration))
     ((stringp duration)
      (let ((parts (mapcar #'string-to-number (split-string duration ":" t))))
        (pcase (length parts)
          (3 (+ (* (nth 0 parts) 3600) (* (nth 1 parts) 60) (nth 2 parts)))
          (2 (+ (* (nth 0 parts) 60) (nth 1 parts)))
          (1 (car parts))
          (_ 0))))
     (t 0))))

(defun etaf-bili--parse-fps (rate)
  "Parse a Bilibili DASH frameRate string or number into a float, or nil."
  (cond
   ((and (numberp rate) (> rate 0)) (float rate))
   ((stringp rate)
    (cond
     ((string-match "\\`\\([0-9.]+\\)/\\([0-9.]+\\)\\'" rate)
      (let ((n (string-to-number (match-string 1 rate)))
            (d (string-to-number (match-string 2 rate))))
        (when (> d 0) (/ (float n) d))))
     ((string-match-p "\\`[0-9.]+\\'" rate)
      (let ((v (string-to-number rate)))
        (when (> v 0) (float v))))
     (t nil)))
   (t nil)))

(defun etaf-bili--date (value)
  "Return VALUE as a `YYYY-MM-DD' string."
  (cond
   ((and (numberp value) (> value 0))
    (format-time-string "%Y-%m-%d" (seconds-to-time value)))
   ((stringp value)
    (if (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" value)
        (match-string 1 value)
      value))
   (t "")))

(defun etaf-bili--views (value)
  "Return a view count VALUE as a display string."
  (cond
   ((numberp value) (number-to-string value))
   ((stringp value) value)
   (t "")))

(defun etaf-bili--parse-video (entry)
  "Parse one API video ENTRY into the application's row plist.
Handles popular, ranking, search, rcmd, dynamic, history, toview, fav,
space and related item shapes."
  ;; Dynamic feed wraps archive inside modules.module_dynamic.major.archive.
  (let* ((dyn-archive (etaf-bili--get-in entry '(modules module_dynamic major archive)))
         (dyn-author (etaf-bili--get-in entry '(modules module_author)))
         (hist (etaf-bili--get entry 'history))
         (src (or dyn-archive entry))
         (bvid (or (etaf-bili--get src 'bvid)
                   (etaf-bili--get src 'bv_id)
                   (etaf-bili--get hist 'bvid)
                   ""))
         (aid (or (etaf-bili--get src 'aid)
                  (etaf-bili--get src 'id)
                  (etaf-bili--get hist 'oid)
                  0))
         (title (or (etaf-bili-clean-title (etaf-bili--get src 'title)) ""))
         (author (or (etaf-bili--get src 'author)
                     (etaf-bili--get-in src '(owner name))
                     (etaf-bili--get-in src '(upper name))
                     (etaf-bili--get dyn-author 'name)
                     (etaf-bili--get entry 'author_name)
                     ""))
         (mid (or (etaf-bili--get src 'mid)
                  (etaf-bili--get-in src '(owner mid))
                  (etaf-bili--get-in src '(upper mid))
                  (etaf-bili--get dyn-author 'mid)
                  (etaf-bili--get entry 'author_mid)
                  0))
         (duration (etaf-bili--seconds
                    (or (etaf-bili--get src 'duration)
                        (etaf-bili--get src 'duration_text)
                        (etaf-bili--get src 'length)
                        0)))
         (views (etaf-bili--views
                 (or (etaf-bili--get src 'play)
                     (etaf-bili--get-in src '(stat view))
                     (etaf-bili--get-in src '(stat play))
                     (etaf-bili--get-in src '(cnt_info play))
                     "")))
         (danmaku (etaf-bili--views
                   (or (etaf-bili--get-in src '(stat danmaku))
                       (etaf-bili--get-in src '(stat danmaku_text))
                       (etaf-bili--get src 'video_review)
                       "")))
         (likes (or (etaf-bili--get-in src '(stat like))
                    (etaf-bili--get src 'like)
                    0))
         (date (etaf-bili--date
                (or (etaf-bili--get src 'pubdate)
                    (etaf-bili--get src 'created)
                    (etaf-bili--get src 'pubtime)
                    (etaf-bili--get entry 'view_at)
                    (etaf-bili--get dyn-author 'pub_ts)
                    "")))
         (cover (etaf-bili--https-url
                 (or (etaf-bili--get src 'pic)
                     (etaf-bili--get src 'cover)
                     (etaf-bili--get entry 'cover)
                     "")))
         (videos (or (etaf-bili--get src 'videos)
                     (etaf-bili--get src 'page)
                     1))
         (progress (let ((prog (etaf-bili--get entry 'progress)))
                     (and (numberp prog) (> prog 0) prog)))
         (desc (or (etaf-bili--get src 'desc)
                   (etaf-bili--get src 'description)
                   (etaf-bili--get src 'intro)
                   ""))
         (tname (or (etaf-bili--get src 'tname) ""))
         (rcmd (or (etaf-bili--get-in src '(rcmd_reason content))
                   (let ((r (etaf-bili--get src 'rcmd_reason)))
                     (and (stringp r) r)))))
    (append
     (list :bvid bvid
           :aid (if (numberp aid) aid (string-to-number (format "%s" aid)))
           :title title
           :author author
           :duration duration
           :views views
           :date date
           :cover cover)
     (when (and (numberp mid) (> mid 0)) (list :mid mid))
     (when (and (stringp danmaku) (not (string-empty-p danmaku))) (list :danmaku danmaku))
     (when (and (numberp likes) (> likes 0)) (list :likes likes))
     (when (and (numberp videos) (> videos 1)) (list :videos videos))
     (when progress (list :progress progress))
     (when (and (stringp desc) (not (string-empty-p desc))) (list :desc desc))
     (when (and (stringp tname) (not (string-empty-p tname))) (list :tname tname))
     (when (and (stringp rcmd) (not (string-empty-p rcmd))) (list :rcmd-reason rcmd)))))

(defun etaf-bili-parse-videos (data)
  "Parse a video list response DATA into row plists.
Supports list, result, item, items, medias, list.vlist and bare list shapes."
  (let ((items
         (cond
          ((and (listp data) (consp (car data)) (symbolp (caar data))
                (or (assq 'list data) (assq 'result data) (assq 'item data)
                    (assq 'items data) (assq 'medias data)))
           (or (let ((lst (etaf-bili--get data 'list)))
                 (if (and (listp lst) (assq 'vlist lst))
                     (etaf-bili--rows (etaf-bili--get lst 'vlist))
                   (etaf-bili--rows lst)))
               (etaf-bili--rows (etaf-bili--get data 'result))
               (etaf-bili--rows (etaf-bili--get data 'item))
               (etaf-bili--rows (etaf-bili--get data 'items))
               (etaf-bili--rows (etaf-bili--get data 'medias))))
          ((listp data) (etaf-bili--rows data))
          (t nil))))
    (seq-filter
     (lambda (row)
       (and (stringp (plist-get row :bvid))
            (not (string-empty-p (plist-get row :bvid)))))
     (mapcar #'etaf-bili--parse-video items))))

;;; Client & Cookie Jar

(defun etaf-bili--cookie-file (client)
  "Return CLIENT's cookie jar path, creating its directory."
  (let ((file (expand-file-name "cookies.txt" (plist-get client :state-directory))))
    (make-directory (file-name-directory file) t)
    file))

(defun etaf-bili--read-cookie (client cookie-name)
  "Return COOKIE-NAME's value from CLIENT's Netscape cookie jar, or nil."
  (let ((file (etaf-bili--cookie-file client)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (catch 'found
          (while (not (eobp))
            (let* ((line (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))
                   (http-only (string-prefix-p "#HttpOnly_" line)))
              (when (or http-only (not (string-prefix-p "#" line)))
                (let* ((clean (if http-only (substring line (length "#HttpOnly_")) line))
                       (fields (split-string clean "\t")))
                  (when (and (= (length fields) 7)
                             (equal (nth 5 fields) cookie-name))
                    (throw 'found (string-trim-right (nth 6 fields) "\r+"))))))
            (forward-line 1))
          nil)))))

(cl-defun etaf-bili-make-client (&key state-directory timeout)
  "Create the default curl-backed client.
STATE-DIRECTORY and TIMEOUT default to `etaf-bili-state-directory' and
`etaf-bili-request-timeout'."
  (list :state-directory (or state-directory etaf-bili-state-directory)
        :timeout (or timeout etaf-bili-request-timeout)
        :warmed nil
        :wbi nil))

(defun etaf-bili--client-reset (client)
  "Reset CLIENT's cached WBI and warm flags after account state changes."
  (when (and (listp client) (plist-member client :warmed))
    (plist-put client :warmed nil)
    (plist-put client :wbi nil)))

(defun etaf-bili--curl-command (client arguments &optional cookie-mode)
  "Build one curl invocation for CLIENT with ARGUMENTS appended.
COOKIE-MODE is `:read' (default, passes `-b'), `:read-write' (passes `-b' and
`-c', reserved for cookie bootstrap only), or `:none' (for public image CDN)."
  (let ((mode (or cookie-mode :read)))
    (append (list etaf-bili-curl-program
                  "-sS" "-L" "--max-time" (number-to-string (plist-get client :timeout))
                  "-A" etaf-bili--user-agent
                  "-e" etaf-bili--referer)
            (pcase mode
              (:read (list "-b" (etaf-bili--cookie-file client)))
              (:read-write (let ((jar (etaf-bili--cookie-file client)))
                             (list "-b" jar "-c" jar)))
              (_ nil))
            arguments)))

(defun etaf-bili--run (client arguments callback &optional cookie-mode coding)
  "Run bounded curl ARGUMENTS for CLIENT, then deliver stdout to CALLBACK.
Return the `etaf-process-run' job so an owner can cancel it."
  (etaf-process-run
   (etaf-bili--curl-command client arguments cookie-mode)
   :name "etaf-bili-curl"
   :coding (or coding '(utf-8 . utf-8))
   :callback
   (lambda (result)
     (if (eq (plist-get result :status) 'failed)
         (funcall callback (list :error (or (plist-get result :message)
                                            "curl 没有启动")))
       (let ((body (or (plist-get result :output) ""))
             (failure (string-trim (or (plist-get result :stderr) "")))
             (code (or (plist-get result :exit) 0)))
         (funcall callback
                  (if (and (eq (plist-get result :status) 'exit) (zerop code))
                      (list :ok body)
                    (list :error "网络请求未完成，请重试"
                          :hint (format "curl %s: %s" code failure)))))))))

(defun etaf-bili--json (body)
  "Parse BODY as a JSON object alist, signaling on malformed data."
  (condition-case nil
      (json-parse-string body :object-type 'alist :array-type 'list)
    (error (signal 'etaf-bili-error
                   (list "Bilibili returned a non-JSON response")))))

(defun etaf-bili--api-call (client path params callback &optional signed)
  "GET api PATH with PARAMS and call CALLBACK with the parsed payload."
  (let* ((wbi (plist-get client :wbi))
         (query (if (and signed wbi)
                    (etaf-bili-wbi-query params wbi)
                  (mapconcat (lambda (pair)
                               (format "%s=%s"
                                       (etaf-bili--urlencode (car pair))
                                       (etaf-bili--urlencode (cdr pair))))
                             params "&")))
         (url (concat etaf-bili--api-root path
                      (if (string-empty-p query) "" "?")
                      query)))
    (etaf-bili--run
     client (list url)
     (lambda (reply)
       (if (plist-get reply :error)
           (funcall callback reply)
         (condition-case problem
             (let* ((payload (etaf-bili--json (plist-get reply :ok)))
                    (code (etaf-bili--get payload 'code)))
               (if (eq code 0)
                   (funcall callback (list :ok (etaf-bili--get payload 'data)))
                 (funcall callback
                          (list :error (format "Bilibili error %s: %s"
                                               code
                                               (or (etaf-bili--get payload 'message) ""))))))
           (etaf-bili-error
            (funcall callback (list :error (error-message-string problem))))))))))

(defun etaf-bili--api-post (client path params callback)
  "POST form PARAMS with CSRF token to api PATH and deliver result to CALLBACK."
  (let ((csrf (etaf-bili--read-cookie client "bili_jct")))
    (if (not (and (stringp csrf) (not (string-empty-p csrf))))
        (progn (funcall callback '(:error "请先扫码登录哔哩哔哩")) nil)
      (let* ((all-params (append params (list (cons "csrf" csrf))))
             (args (append (list "-X" "POST")
                           (cl-mapcan (lambda (pair)
                                        (list "--data-urlencode"
                                              (format "%s=%s" (car pair) (cdr pair))))
                                      all-params)
                           (list (concat etaf-bili--api-root path)))))
        (etaf-bili--run
         client args
         (lambda (reply)
           (if (plist-get reply :error)
               (funcall callback reply)
             (condition-case problem
                 (let* ((payload (etaf-bili--json (plist-get reply :ok)))
                        (code (etaf-bili--get payload 'code)))
                   (if (eq code 0)
                       (funcall callback (list :ok (etaf-bili--get payload 'data)))
                     (funcall callback
                              (list :error (format "Bilibili error %s: %s"
                                                   code
                                                   (or (etaf-bili--get payload 'message) ""))))))
               (etaf-bili-error
                (funcall callback (list :error (error-message-string problem))))))))))))

(defun etaf-bili--warm (client then)
  "Make sure CLIENT has `buvid3' cookie and WBI keys, then call THEN.
Avoids overwriting `cookies.txt' once `buvid3' already exists, preventing
concurrent writes from clobbering freshly logged-in session cookies."
  (if (and (plist-get client :warmed) (plist-get client :wbi))
      (funcall then)
    (let ((fetch-nav
           (lambda ()
             (etaf-bili--run
              client (list (concat etaf-bili--api-root "/x/web-interface/nav"))
              (lambda (reply)
                (when-let* ((body (plist-get reply :ok))
                            (payload (ignore-errors (etaf-bili--json body)))
                            (data (etaf-bili--get payload 'data))
                            (img (etaf-bili--get-in data '(wbi_img img_url)))
                            (sub (etaf-bili--get-in data '(wbi_img sub_url))))
                  (plist-put client :wbi (etaf-bili--mixin-key
                                          (file-name-base img) (file-name-base sub)))
                  (plist-put client :warmed t))
                (funcall then))
              :read))))
      (if (etaf-bili--read-cookie client "buvid3")
          (funcall fetch-nav)
        (etaf-bili--run
         client (list "-o" null-device etaf-bili--referer)
         (lambda (_reply) (funcall fetch-nav))
         :read-write)))))

;;; Quality, Codec & DASH Stream Resolution

(defun etaf-bili--quality-label (id)
  "Return the site's quality name for numeric stream ID."
  (or (cdr (assq id '((16 . "360P") (32 . "480P") (64 . "720P")
                      (74 . "720P60") (80 . "1080P") (112 . "1080P+")
                      (116 . "1080P60") (120 . "4K") (125 . "HDR")
                      (126 . "杜比视界") (127 . "8K"))))
      (format "%s" id)))

(defun etaf-bili--codec-label (codec codecid)
  "Return concise human-readable codec name for CODEC string or CODECID."
  (let ((c (downcase (or codec ""))))
    (cond
     ((or (string-prefix-p "avc" c) (eq codecid 7)) "H.264")
     ((or (string-prefix-p "hev" c) (string-prefix-p "hvc" c) (eq codecid 12)) "HEVC")
     ((or (string-prefix-p "av01" c) (eq codecid 13)) "AV1")
     ((not (string-empty-p c)) c)
     (t "H.264"))))

(defun etaf-bili--codec-rank (codec)
  "Return preference rank (lower is better) for CODEC string."
  (let ((c (downcase (or codec "")))
        (prefs etaf-bili-preferred-codecs)
        (idx 0)
        (found nil))
    (while (and prefs (not found))
      (if (string-prefix-p (car prefs) c)
          (setq found idx)
        (setq idx (1+ idx) prefs (cdr prefs))))
    (or found 99)))

(defun etaf-bili--cdn-rank (url)
  "Return CDN reliability rank for URL (lower is preferred).
Bilibili frequently places PCDN/MCDN endpoints (`mcdn.bilivideo.cn:8082',
`mountaintoys.cn:4483', `szbdyd.com', etc.) as `baseUrl' while placing the
official `upos-*.bilivideo.com' mirror in `backupUrl'.  PCDN nodes commonly
reject ffmpeg/ffplay TLS handshakes, so official UPOS mirrors go first."
  (let ((host (and (stringp url)
                   (string-match "\\`https?://\\([^/]+\\)" url)
                   (downcase (match-string 1 url)))))
    (cond
     ((not host) 99)
     ;; Explicit PCDN / MCDN nodes (often non-443 ports) fail TLS in ffmpeg
     ((or (string-match-p "mcdn\\.bilivideo\\|szbdyd\\.com\\|mountaintoys\\.cn\\|pcdn" host)
          (string-match-p ":[0-9]+\\'" host))
      3)
     ;; Official UPOS mirror CDNs on standard port 443 work reliably everywhere
     ((string-match-p "\\`upos-.*\\.bilivideo\\.com\\'" host) 0)
     ((string-match-p "\\.bilivideo\\.com\\'" host) 1)
     (t 2))))

(defun etaf-bili--entry-urls (entry)
  "Return (PRIMARY . BACKUPS) URLs from a DASH stream ENTRY, preferring UPOS CDNs."
  (let* ((primary (or (etaf-bili--get entry 'baseUrl)
                      (etaf-bili--get entry 'base_url)))
         (backups (or (etaf-bili--rows (etaf-bili--get entry 'backupUrl))
                      (etaf-bili--rows (etaf-bili--get entry 'backup_url))))
         (all (delete-dups
               (seq-filter (lambda (u) (and (stringp u) (not (string-empty-p u))))
                           (cons primary backups))))
         (ranked (sort (copy-sequence all)
                       (lambda (a b) (< (etaf-bili--cdn-rank a)
                                        (etaf-bili--cdn-rank b))))))
    (cons (car ranked) (cdr ranked))))

(defun etaf-bili--dedup-streams (videos)
  "Convert DASH VIDEOS array into deduplicated, sorted stream plists.
Picks the best preferred codec per quality id while keeping backup URLs and
native geometry (`width', `height', `fps') so ffprobe is never needed."
  (let ((by-id (make-hash-table :test #'eql))
        (result nil))
    (dolist (entry videos)
      (let* ((id (or (etaf-bili--get entry 'id) 0))
             (urls (etaf-bili--entry-urls entry))
             (url (car urls))
             (codec (or (etaf-bili--get entry 'codecs) ""))
             (codecid (etaf-bili--get entry 'codecid))
             (rank (etaf-bili--codec-rank codec))
             (existing (gethash id by-id)))
        (when (and (stringp url) (not (string-empty-p url)))
          (when (or (null existing) (< rank (plist-get existing :codec-rank)))
            (puthash id
                     (list :id id
                           :label (etaf-bili--quality-label id)
                           :codec codec
                           :codec-label (etaf-bili--codec-label codec codecid)
                           :codec-rank rank
                           :url url
                           :backup-urls (cdr urls)
                           :width (etaf-bili--get entry 'width)
                           :height (etaf-bili--get entry 'height)
                           :fps (etaf-bili--parse-fps
                                 (or (etaf-bili--get entry 'frameRate)
                                     (etaf-bili--get entry 'frame_rate)))
                           :bandwidth (or (etaf-bili--get entry 'bandwidth) 0))
                     by-id)))))
    (maphash (lambda (_k v) (push v result)) by-id)
    (sort result (lambda (a b) (> (plist-get a :id) (plist-get b :id))))))

(defun etaf-bili--pick-stream (streams requested-qn)
  "Select the best stream from STREAMS matching REQUESTED-QN.
Prefers exact match, otherwise highest quality at or below REQUESTED-QN,
otherwise the highest available stream."
  (or (and requested-qn
           (cl-find requested-qn streams :key (lambda (s) (plist-get s :id))))
      (and requested-qn
           (cl-find-if (lambda (s) (<= (plist-get s :id) requested-qn)) streams))
      (car streams)))

(defun etaf-bili--audio-label (id bandwidth &optional flac-p)
  "Return a concise user-facing label for a DASH audio track."
  (let ((aid (or id 0))
        (bw (or bandwidth 0)))
    (cond
     ((or flac-p (= aid 30251)) "Hi-Res")
     ((= aid 30250) "杜比")
     ((or (= aid 30280) (>= bw 160000)) "192K")
     ((or (= aid 30232) (>= bw 100000)) "132K")
     ((> bw 0) "64K")
     (t nil))))

(defun etaf-bili--pick-audio (dash)
  "Select the highest-fidelity audio stream from Bilibili DASH payload.
Prefers Hi-Res lossless FLAC (`dash.flac.audio') when present, otherwise
picks the highest-bandwidth track in `dash.audio' (e.g. 192K AAC)."
  (let* ((flac-entry (etaf-bili--get-in dash '(flac audio)))
         (flac-urls (and flac-entry (etaf-bili--entry-urls flac-entry))))
    (if (car-safe flac-urls)
        (let ((id (or (etaf-bili--get flac-entry 'id) 30251))
              (bw (or (etaf-bili--get flac-entry 'bandwidth) 0)))
          (list :urls flac-urls
                :id id
                :bandwidth bw
                :label (etaf-bili--audio-label id bw t)))
      (let* ((audios (etaf-bili--rows (etaf-bili--get dash 'audio)))
             (best (car (sort (copy-sequence audios)
                              (lambda (a b)
                                (let ((ba (or (etaf-bili--get a 'bandwidth) 0))
                                      (bb (or (etaf-bili--get b 'bandwidth) 0)))
                                  (if (= ba bb)
                                      (> (or (etaf-bili--get a 'id) 0)
                                         (or (etaf-bili--get b 'id) 0))
                                    (> ba bb)))))))
             (urls (and best (etaf-bili--entry-urls best))))
        (when (car-safe urls)
          (let ((id (or (etaf-bili--get best 'id) 0))
                (bw (or (etaf-bili--get best 'bandwidth) 0)))
            (list :urls urls
                  :id id
                  :bandwidth bw
                  :label (etaf-bili--audio-label id bw nil))))))))

(defun etaf-bili--stream-url (client bvid cid callback &optional qn)
  "Ask for BVID's playable stream at CID and call CALLBACK with the result.
CALLBACK receives (SELECTED AUDIO-INFO STREAMS REPLY).  Uses WBI-signed
`/x/player/wbi/playurl' with `fnval=4048' to unlock full logged-in quality."
  (let* ((want-qn (or qn etaf-bili-preferred-quality 80))
         (params (list (cons "bvid" bvid)
                       (cons "cid" (number-to-string cid))
                       (cons "qn" (number-to-string want-qn))
                       (cons "fnval" "4048")
                       (cons "fnver" "0")
                       (cons "fourk" "1")
                       (cons "try_look" "1")))
         (path (if (plist-get client :wbi)
                   "/x/player/wbi/playurl"
                 "/x/player/playurl")))
    (etaf-bili--api-call
     client path params
     (lambda (reply)
       (let* ((play (plist-get reply :ok))
              (dash (etaf-bili--get play 'dash))
              (videos (etaf-bili--rows (etaf-bili--get dash 'video)))
              (durl (etaf-bili--rows (etaf-bili--get play 'durl)))
              (streams (etaf-bili--dedup-streams videos))
              (chosen (etaf-bili--pick-stream streams want-qn))
              (audio-info (and dash (etaf-bili--pick-audio dash))))
         (cond
          ((and chosen (plist-get chosen :url))
           (funcall callback chosen audio-info streams reply))
          ((and durl (etaf-bili--get (car durl) 'url))
           (let ((d-entry (car durl)))
             (funcall callback
                      (list :id (or (etaf-bili--get play 'quality) 64)
                            :label (etaf-bili--quality-label (or (etaf-bili--get play 'quality) 64))
                            :codec-label "MP4"
                            :url (etaf-bili--get d-entry 'url)
                            :backup-urls (etaf-bili--rows (etaf-bili--get d-entry 'backup_url)))
                      nil nil reply)))
          (t (funcall callback nil nil nil reply)))))
     t)))

;;; Danmaku, Subtitles, Comments & Detail Parsers

(defun etaf-bili--parse-danmaku-xml (xml-text)
  "Parse Bilibili danmaku XML-TEXT into a sorted list of plists.
Each entry carries `:time' (float seconds), `:mode' (integer),
`:color' (`#RRGGBB'), and `:text'."
  (let (entries)
    (when (and (stringp xml-text) (not (string-empty-p xml-text)))
      (with-temp-buffer
        (insert xml-text)
        (goto-char (point-min))
        (while (re-search-forward
                "<d p=\"\\([^\"]+\\)\">\\([^<]*\\)</d>" nil t)
          (let* ((raw-attrs (match-string 1))
                 (raw-text (match-string 2))
                 (attrs (split-string raw-attrs ","))
                 (time (string-to-number (or (nth 0 attrs) "0")))
                 (mode (string-to-number (or (nth 1 attrs) "1")))
                 (rgb (string-to-number (or (nth 3 attrs) "16777215")))
                 (color (format "#%06X" (logand rgb #xffffff)))
                 (text (string-trim (etaf-bili-clean-title raw-text))))
            (unless (string-empty-p text)
              (push (list :time (float time) :mode mode :color color :text text)
                    entries))))))
    (sort entries (lambda (a b) (< (plist-get a :time) (plist-get b :time))))))

;;; Native libass Danmaku Compiler (collision-free lanes)

(defun etaf-bili--danmaku-ass-font ()
  "Return a crisp platform sans-serif CJK font for ASS danmaku rendering."
  (pcase system-type
    ('darwin "PingFang SC")
    ('windows-nt "Microsoft YaHei")
    (_ "Noto Sans CJK SC")))

(defun etaf-bili--danmaku-ass-time (seconds)
  "Format SECONDS as an ASS timestamp `H:MM:SS.cc'."
  (let* ((cs (max 0 (round (* (float seconds) 100.0))))
         (h (/ cs 360000))
         (m (/ (% cs 360000) 6000))
         (s (/ (% cs 6000) 100))
         (c (% cs 100)))
    (format "%d:%02d:%02d.%02d" h m s c)))

(defun etaf-bili--danmaku-ass-escape (text)
  "Escape TEXT safely for an ASS Dialogue payload."
  (let* ((clean (replace-regexp-in-string "[\000-\037\177]+" " " (or text "")))
         (clean (replace-regexp-in-string "[ \t]+" " " (string-trim clean)))
         (clean (replace-regexp-in-string "\\\\" "\\\\\\\\" clean))
         (clean (replace-regexp-in-string "{" "\\\\{" clean))
         (clean (replace-regexp-in-string "}" "\\\\}" clean)))
    clean))

(defun etaf-bili--danmaku-ass-color (hex)
  "Convert `#RRGGBB' HEX or 24-bit integer to ASS `&HBBGGRR&', or nil for white."
  (let ((s (cond ((stringp hex) hex)
                 ((integerp hex) (format "#%06X" (logand hex #xffffff)))
                 (t nil))))
    (when (and (stringp s)
               (string-match "\\`#\\([0-9A-Fa-f]\\{2\\}\\)\\([0-9A-Fa-f]\\{2\\}\\)\\([0-9A-Fa-f]\\{2\\}\\)\\'" s))
      (let ((rr (upcase (match-string 1 s)))
            (gg (upcase (match-string 2 s)))
            (bb (upcase (match-string 3 s))))
        (unless (and (string= rr "FF") (string= gg "FF") (string= bb "FF"))
          (format "\\c&H%s%s%s&" bb gg rr))))))

(defun etaf-bili--danmaku-compile-ass (entries &optional opts)
  "Compile sorted Bilibili danmaku ENTRIES into an ASS script string.
OPTS is a plist supporting `:area' (`quarter', `half' or `full'),
`:opacity' (10..100, default 80), `:font-size' (`small', `medium' or
`large'), `:density' (`low', `medium' or `high'), `:show-scroll',
`:show-top' and `:show-bottom'.  Uses collision-free lane scheduling so
scrolling and fixed danmaku never overlap."
  (let* ((area (or (plist-get opts :area) 'half))
         (opacity (max 10 (min 100 (or (plist-get opts :opacity) 80))))
         (size-key (or (plist-get opts :font-size) 'medium))
         (density (or (plist-get opts :density) 'medium))
         (show-scroll (if (plist-member opts :show-scroll) (plist-get opts :show-scroll) t))
         (show-top (if (plist-member opts :show-top) (plist-get opts :show-top) t))
         (show-bottom (if (plist-member opts :show-bottom) (plist-get opts :show-bottom) nil))
         (font-px (pcase size-key ('small 36) ('large 54) (_ 44)))
         (lane-h (round (* font-px 1.26)))
         (usable-h (pcase area ('quarter 290) ('full 920) (_ 520)))
         (max-lanes (max 2 (floor usable-h lane-h)))
         (scroll-lanes (pcase density
                         ('low (max 2 (floor (* max-lanes 0.55))))
                         ('high max-lanes)
                         (_ (max 3 (floor (* max-lanes 0.85))))))
         (fixed-lanes (max 2 (min 5 (floor max-lanes 2))))
         (gap-px (pcase density ('low 150.0) ('high 28.0) (_ 76.0)))
         (scroll-dur 9.5)
         (fixed-dur 4.5)
         (res-x 1920.0)
         (top-pad 18)
         (alpha (format "%02X" (round (* 255.0 (- 1.0 (/ (float opacity) 100.0))))))
         (outline-alpha (format "%02X" (min 255 (+ 28 (round (* 255.0 (- 1.0 (/ (float opacity) 100.0))))))))
         (font (etaf-bili--danmaku-ass-font))
         ;; Scroll lane state: vector of nil or (prev-start prev-end prev-w prev-v).
         (scroll-state (make-vector scroll-lanes nil))
         (top-ends (make-vector fixed-lanes -1.0))
         (bot-ends (make-vector fixed-lanes -1.0))
         (events nil))
    (dolist (item entries)
      (let* ((mode (or (plist-get item :mode) 1))
             (t0 (float (max 0.0 (or (plist-get item :time) 0.0))))
             (raw-text (or (plist-get item :text) ""))
             (text (etaf-bili--danmaku-ass-escape raw-text)))
        (unless (string-empty-p text)
          (let ((color-tag (or (etaf-bili--danmaku-ass-color (plist-get item :color)) "")))
            (cond
             ;; Scrolling right-to-left (modes 1, 2, 3, 6)
             ((and show-scroll (memq mode '(1 2 3 6)))
              (let* ((w (float (max font-px (round (* (string-width raw-text) font-px 0.54)))))
                     (v (/ (+ res-x w) scroll-dur))
                     (t1 (+ t0 scroll-dur))
                     (chosen nil)
                     (i 0))
                (while (and (< i scroll-lanes) (null chosen))
                  (let ((prev (aref scroll-state i))
                        (top-busy (and (< i fixed-lanes) (> (aref top-ends i) t0))))
                    (if (and (not top-busy)
                             (or (null prev)
                                 (let ((p-start (nth 0 prev))
                                       (p-end (nth 1 prev))
                                       (p-w (nth 2 prev))
                                       (p-v (nth 3 prev)))
                                   (and (>= t0 (+ p-start (/ (+ p-w gap-px) p-v)))
                                        (>= (+ t0 (/ (- res-x gap-px) v)) p-end)))))
                        (setq chosen i)
                      (setq i (1+ i)))))
                (when chosen
                  (aset scroll-state chosen (list t0 t1 w v))
                  (let ((y (+ top-pad (* chosen lane-h))))
                    (push (format "Dialogue: 0,%s,%s,Scroll,,0,0,0,,{\\move(%d,%d,%d,%d)%s}%s"
                                  (etaf-bili--danmaku-ass-time t0)
                                  (etaf-bili--danmaku-ass-time t1)
                                  (round res-x) y (- (round w)) y color-tag text)
                          events)))))
             ;; Top fixed (mode 5) — prefer a lane with no active scroll overlap
             ((and show-top (= mode 5))
              (let ((chosen nil) (fallback nil) (i 0))
                (while (and (< i fixed-lanes) (null chosen))
                  (when (<= (aref top-ends i) t0)
                    (unless fallback (setq fallback i))
                    (let ((sp (and (< i scroll-lanes) (aref scroll-state i))))
                      (when (or (null sp) (<= (nth 1 sp) t0))
                        (setq chosen i))))
                  (setq i (1+ i)))
                (unless chosen (setq chosen fallback))
                (when chosen
                  (let ((t1 (+ t0 fixed-dur))
                        (y (+ top-pad (* chosen lane-h))))
                    (aset top-ends chosen t1)
                    (push (format "Dialogue: 1,%s,%s,Top,,0,0,0,,{\\an8\\pos(960,%d)%s}%s"
                                  (etaf-bili--danmaku-ass-time t0)
                                  (etaf-bili--danmaku-ass-time t1)
                                  y color-tag text)
                          events)))))
             ;; Bottom fixed (mode 4)
             ((and show-bottom (= mode 4))
              (let ((chosen nil) (i 0))
                (while (and (< i fixed-lanes) (null chosen))
                  (if (<= (aref bot-ends i) t0)
                      (setq chosen i)
                    (setq i (1+ i))))
                (when chosen
                  (let ((t1 (+ t0 fixed-dur))
                        (y (- 1030 (* chosen lane-h))))
                    (aset bot-ends chosen t1)
                    (push (format "Dialogue: 1,%s,%s,Bottom,,0,0,0,,{\\an2\\pos(960,%d)%s}%s"
                                  (etaf-bili--danmaku-ass-time t0)
                                  (etaf-bili--danmaku-ass-time t1)
                                  y color-tag text)
                          events))))))))))
    (concat
     "[Script Info]\n"
     "ScriptType: v4.00+\n"
     "PlayResX: 1920\n"
     "PlayResY: 1080\n"
     "WrapStyle: 2\n"
     "ScaledBorderAndShadow: yes\n\n"
     "[V4+ Styles]\n"
     "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
     (format "Style: Scroll,%s,%d,&H%sFFFFFF,&H%sFFFFFF,&H%s000000,&H80000000,-1,0,0,0,100,100,0,0,1,2.2,0.8,7,0,0,0,1\n"
             font font-px alpha alpha outline-alpha)
     (format "Style: Top,%s,%d,&H%sFFFFFF,&H%sFFFFFF,&H%s000000,&H80000000,-1,0,0,0,100,100,0,0,1,2.2,0.8,8,0,0,0,1\n"
             font font-px alpha alpha outline-alpha)
     (format "Style: Bottom,%s,%d,&H%sFFFFFF,&H%sFFFFFF,&H%s000000,&H80000000,-1,0,0,0,100,100,0,0,1,2.2,0.8,2,0,0,0,1\n\n"
             font font-px alpha alpha outline-alpha)
     "[Events]\n"
     "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
     (mapconcat #'identity (nreverse events) "\n")
     (when events "\n"))))

(defun etaf-bili--danmaku-write-ass (entries path &optional opts)
  "Write compiled ASS danmaku for ENTRIES with OPTS to PATH.
Return PATH on success, or nil when ENTRIES is empty."
  (when (and entries (stringp path))
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file path
        (insert (etaf-bili--danmaku-compile-ass entries opts))))
    path))

(defun etaf-bili--parse-subtitle-json (body)
  "Parse Bilibili JSON subtitle BODY into sorted `(START END TEXT)' cues."
  (condition-case nil
      (let* ((payload (etaf-bili--json body))
             (rows (etaf-bili--rows (etaf-bili--get payload 'body)))
             cues)
        (dolist (row rows)
          (let ((from (etaf-bili--get row 'from))
                (to (etaf-bili--get row 'to))
                (text (string-trim (or (etaf-bili--get row 'content) ""))))
            (when (and (numberp from) (numberp to) (not (string-empty-p text)))
              (push (list (float from) (float to)
                          (replace-regexp-in-string "[\r\n]+" " " text))
                    cues))))
        (sort cues (lambda (a b) (< (car a) (car b)))))
    (error nil)))

(defun etaf-bili--parse-comment (reply &optional top-p)
  "Parse one Bilibili comment REPLY alist into a plist."
  (when (listp reply)
    (let* ((member (etaf-bili--get reply 'member))
           (content (etaf-bili--get reply 'content))
           (sub (etaf-bili--rows (etaf-bili--get reply 'replies)))
           (msg (string-trim (or (etaf-bili--get content 'message) ""))))
      (unless (string-empty-p msg)
        (list :rpid (or (etaf-bili--get reply 'rpid) 0)
              :author (or (etaf-bili--get member 'uname) "用户")
              :likes (or (etaf-bili--get reply 'like) 0)
              :time (etaf-bili--date (etaf-bili--get reply 'ctime))
              :message msg
              :top (and top-p t)
              :replies (cl-loop for r in (seq-take sub 2)
                                for parsed = (etaf-bili--parse-comment r nil)
                                when parsed collect parsed))))))

(defun etaf-bili--parse-comments (data)
  "Parse `/x/v2/reply/wbi/main' DATA into a flat list of top + hot comments."
  (let* ((top-upper (etaf-bili--get-in data '(top upper)))
         (top-list (etaf-bili--rows (etaf-bili--get data 'top_replies)))
         (replies (etaf-bili--rows (etaf-bili--get data 'replies)))
         (seen (make-hash-table :test #'equal))
         (out nil))
    (dolist (entry (append (when top-upper (list top-upper)) top-list))
      (when-let* ((parsed (etaf-bili--parse-comment entry t)))
        (unless (gethash (plist-get parsed :rpid) seen)
          (puthash (plist-get parsed :rpid) t seen)
          (push parsed out))))
    (dolist (entry replies)
      (when-let* ((parsed (etaf-bili--parse-comment entry nil)))
        (unless (gethash (plist-get parsed :rpid) seen)
          (puthash (plist-get parsed :rpid) t seen)
          (push parsed out))))
    (nreverse out)))

(defun etaf-bili--parse-video-detail (data)
  "Parse `/x/web-interface/view' DATA into rich video metadata plist."
  (let* ((pages-raw (etaf-bili--rows (etaf-bili--get data 'pages)))
         (dim (etaf-bili--get data 'dimension))
         (dw (etaf-bili--get dim 'width))
         (dh (etaf-bili--get dim 'height))
         (pages
          (cl-loop for p in pages-raw
                   for idx from 1
                   for pdim = (etaf-bili--get p 'dimension)
                   collect (list :page (or (etaf-bili--get p 'page) idx)
                                 :cid (etaf-bili--get p 'cid)
                                 :part (or (etaf-bili-clean-title (etaf-bili--get p 'part))
                                           (format "P%d" idx))
                                 :duration (etaf-bili--seconds (etaf-bili--get p 'duration))
                                 :width (or (etaf-bili--get pdim 'width) dw)
                                 :height (or (etaf-bili--get pdim 'height) dh))))
         (sections (etaf-bili--rows (etaf-bili--get-in data '(ugc_season sections))))
         (season
          (cl-loop for sec in sections
                   append
                   (cl-loop for ep in (etaf-bili--rows (etaf-bili--get sec 'episodes))
                            collect (list :bvid (etaf-bili--get ep 'bvid)
                                          :aid (etaf-bili--get ep 'aid)
                                          :cid (etaf-bili--get ep 'cid)
                                          :title (or (etaf-bili-clean-title (etaf-bili--get ep 'title)) "")
                                          :duration (etaf-bili--seconds
                                                     (or (etaf-bili--get-in ep '(arc duration))
                                                         (etaf-bili--get-in ep '(page duration))
                                                         0))))))
         (first-page (car pages)))
    (list :bvid (or (etaf-bili--get data 'bvid) "")
          :aid (or (etaf-bili--get data 'aid) 0)
          :cid (or (plist-get first-page :cid) (etaf-bili--get data 'cid))
          :title (or (etaf-bili-clean-title (etaf-bili--get data 'title)) "")
          :description (or (etaf-bili--get data 'desc) "")
          :duration (etaf-bili--seconds (etaf-bili--get data 'duration))
          :author (or (etaf-bili--get-in data '(owner name)) "")
          :mid (or (etaf-bili--get-in data '(owner mid)) 0)
          :views (etaf-bili--views (or (etaf-bili--get-in data '(stat view)) ""))
          :danmaku (etaf-bili--views (or (etaf-bili--get-in data '(stat danmaku)) ""))
          :likes (or (etaf-bili--get-in data '(stat like)) 0)
          :coins (or (etaf-bili--get-in data '(stat coin)) 0)
          :favorites (or (etaf-bili--get-in data '(stat favorite)) 0)
          :date (etaf-bili--date (etaf-bili--get data 'pubdate))
          :tname (or (etaf-bili--get data 'tname) "")
          :cover (etaf-bili--https-url (etaf-bili--get data 'pic))
          :dimension (when (and (numberp dw) (numberp dh) (> dw 0) (> dh 0))
                       (cons dw dh))
          :pages pages
          :season season)))

;;; Cover Downloads (cookie-free & bounded)

(defun etaf-bili--prune-cover-cache (directory)
  "Keep at most `etaf-bili--cover-cache-limit' files in DIRECTORY."
  (ignore-errors
    (let* ((files (cl-remove-if
                   (lambda (f)
                     (let ((base (file-name-nondirectory f)))
                       (or (string-prefix-p "." base)
                           (file-directory-p f))))
                   (directory-files directory t nil t)))
           (excess (- (length files) etaf-bili--cover-cache-limit)))
      (when (> excess 0)
        (let ((sorted (sort files
                            (lambda (a b)
                              (time-less-p
                               (file-attribute-modification-time (file-attributes a))
                               (file-attribute-modification-time (file-attributes b)))))))
          (dolist (old (seq-take sorted excess))
            (ignore-errors (delete-file old))))))))

(defun etaf-bili--fetch-cover (client url callback)
  "Cache a public cover URL for CLIENT and deliver its local path to CALLBACK.
Only Bilibili's image CDN is accepted.  Never sends or writes cookies.
Returns `(JOB . TEMP-FILE)' or nil when resolved synchronously from cache."
  (if (not (and (stringp url)
                (string-match-p "\\`https?://[A-Za-z0-9.-]+\\.hdslb\\.com/" url)))
      (progn (funcall callback '(:error "封面地址不可用")) nil)
    (let* ((url (replace-regexp-in-string "\\`http:" "https:" url))
           (directory (expand-file-name "covers/" (plist-get client :state-directory)))
           (file (expand-file-name (concat (secure-hash 'sha256 url) ".img") directory)))
      (make-directory directory t)
      (if (file-exists-p file)
          (progn (funcall callback (list :ok file)) nil)
        (let* ((temporary (make-temp-file (expand-file-name ".cover-" directory)))
               (job
                (etaf-bili--run
                 client (list "--fail" "--proto" "=https" "--max-filesize" "2097152"
                              "--output" temporary "--" url)
                 (lambda (reply)
                   (if (and (plist-member reply :ok)
                            (file-exists-p temporary)
                            (> (or (file-attribute-size (file-attributes temporary)) 0) 0))
                       (progn
                         (rename-file temporary file t)
                         (when (zerop (random 25))
                           (etaf-bili--prune-cover-cache directory))
                         (funcall callback (list :ok file)))
                     (ignore-errors (when (file-exists-p temporary) (delete-file temporary)))
                     (funcall callback (list :error "封面加载失败，仍可播放视频"))))
                 :none)))
          (cons job temporary))))))

;;; Public client dispatch

(defun etaf-bili-client-call (client request callback)
  "Perform one REQUEST through CLIENT and deliver the result to CALLBACK.
CLIENT is either the plist `etaf-bili-make-client' returns or a function
accepting (REQUEST CALLBACK); tests inject the function through
`etaf-bili-client-factory'.

CALLBACK receives `(:ok DATA)' or `(:error MESSAGE :hint HINT)'."
  (if (functionp client)
      (funcall client request callback)
    (etaf-bili--call-curl client request callback)))

(defun etaf-bili--call-curl (client request callback)
  "Perform REQUEST through the curl CLIENT implementation."
  (pcase (plist-get request :op)
    (:cover
     (let ((pair (etaf-bili--fetch-cover client (plist-get request :url) callback)))
       (if (consp pair) (car pair) pair)))
    (:cover-tracked
     (etaf-bili--fetch-cover client (plist-get request :url) callback))
    (:popular
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/web-interface/popular"
         (list (cons "ps" "20")
               (cons "pn" (number-to-string (or (plist-get request :page) 1))))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))))))
    (:ranking
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/web-interface/ranking/v2"
         (list (cons "rid" (number-to-string (or (plist-get request :rid) 0)))
               (cons "type" "all"))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))))))
    (:rcmd
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/web-interface/wbi/index/top/feed/rcmd"
         (list (cons "ps" "20")
               (cons "fresh_type" "4")
               (cons "fresh_idx" (number-to-string (or (plist-get request :page) 1)))
               (cons "feed_version" "V8"))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))
         t))))
    (:dynamic
     (etaf-bili--warm
      client
      (lambda ()
        (let ((params (append (list (cons "type" "video"))
                              (when-let* ((off (plist-get request :offset)))
                                (list (cons "offset" off))))))
          (etaf-bili--api-call
           client "/x/polymer/web-dynamic/v1/feed/all" params
           (lambda (reply)
             (if-let* ((data (plist-get reply :ok)))
                 (funcall callback
                          (list :ok (etaf-bili-parse-videos data)
                                :offset (etaf-bili--get data 'offset)
                                :has-more (etaf-bili--get data 'has_more)))
               (funcall callback reply))))))))
    (:toview
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/v2/history/toview" nil
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))))))
    (:history
     (etaf-bili--warm
      client
      (lambda ()
        (let ((params (append (list (cons "type" "archive") (cons "ps" "20"))
                              (when-let* ((m (plist-get request :max)))
                                (list (cons "max" (number-to-string m))))
                              (when-let* ((va (plist-get request :view-at)))
                                (list (cons "view_at" (number-to-string va)))))))
          (etaf-bili--api-call
           client "/x/web-interface/history/cursor" params
           (lambda (reply)
             (if-let* ((data (plist-get reply :ok)))
                 (let ((cursor (etaf-bili--get data 'cursor)))
                   (funcall callback
                            (list :ok (etaf-bili-parse-videos data)
                                  :max (etaf-bili--get cursor 'max)
                                  :view-at (etaf-bili--get cursor 'view_at))))
               (funcall callback reply))))))))
    (:fav-folders
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/v3/fav/folder/created/list-all"
         (list (cons "up_mid" (number-to-string (or (plist-get request :mid) 0))))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback
                        (list :ok
                              (mapcar (lambda (f)
                                        (list :id (etaf-bili--get f 'id)
                                              :title (or (etaf-bili--get f 'title) "默认收藏夹")
                                              :count (or (etaf-bili--get f 'media_count) 0)))
                                      (etaf-bili--rows (etaf-bili--get data 'list)))))
             (funcall callback reply)))))))
    (:fav-list
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/v3/fav/resource/list"
         (list (cons "media_id" (number-to-string (or (plist-get request :media-id) 0)))
               (cons "pn" (number-to-string (or (plist-get request :page) 1)))
               (cons "ps" "20"))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))))))
    (:space
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/space/wbi/arc/search"
         (list (cons "mid" (number-to-string (or (plist-get request :mid) 0)))
               (cons "pn" (number-to-string (or (plist-get request :page) 1)))
               (cons "ps" "20"))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))
         t))))
    (:search
     (etaf-bili--warm
      client
      (lambda ()
        (let ((params (append
                       (list (cons "search_type" "video")
                             (cons "keyword" (or (plist-get request :keyword) ""))
                             (cons "page" (number-to-string (or (plist-get request :page) 1))))
                       (when-let* ((order (plist-get request :order)))
                         (unless (equal order "totalrank")
                           (list (cons "order" order))))
                       (when-let* ((dur (plist-get request :duration)))
                         (when (and (numberp dur) (> dur 0))
                           (list (cons "duration" (number-to-string dur))))))))
          (etaf-bili--api-call
           client "/x/web-interface/wbi/search/type" params
           (lambda (reply)
             (if-let* ((data (plist-get reply :ok)))
                 (funcall callback (list :ok (etaf-bili-parse-videos data)))
               (funcall callback reply)))
           t)))))
    (:related
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/web-interface/archive/related"
         (list (cons "bvid" (or (plist-get request :bvid) "")))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))))))
    (:resolve-url
     (let ((short-url (plist-get request :url)))
       (etaf-bili--run
        client (list "-I" "-o" null-device "-w" "%{url_effective}" short-url)
        (lambda (reply)
          (if-let* ((resolved (plist-get reply :ok))
                    (target (etaf-bili-parse-target resolved)))
              (funcall callback (list :ok target))
            (funcall callback (list :error "无法解析短链接指向的视频"))))
        :none)))
    (:video
     (etaf-bili--warm
      client
      (lambda ()
        (let ((params (if-let* ((bvid (plist-get request :bvid)))
                          (list (cons "bvid" bvid))
                        (list (cons "aid" (number-to-string (or (plist-get request :aid) 0)))))))
          (etaf-bili--api-call
           client "/x/web-interface/view" params
           (lambda (reply)
             (if-let* ((data (plist-get reply :ok)))
                 (funcall callback (list :ok (etaf-bili--parse-video-detail data)))
               (funcall callback reply))))))))
    (:play
     (etaf-bili--warm
      client
      (lambda ()
        (let ((req-cid (plist-get request :cid))
              (req-qn (plist-get request :qn))
              (req-bvid (plist-get request :bvid))
              (req-aid (plist-get request :aid)))
          (etaf-bili-client-call
           client (if req-bvid (list :op :video :bvid req-bvid) (list :op :video :aid req-aid))
           (lambda (info)
             (if-let* ((data (plist-get info :ok))
                       (bvid (plist-get data :bvid))
                       (pages (plist-get data :pages))
                       (page-entry (or (and req-cid
                                            (cl-find req-cid pages
                                                     :key (lambda (p) (plist-get p :cid))))
                                       (car pages)))
                       (cid (or req-cid (plist-get page-entry :cid) (plist-get data :cid))))
                 (etaf-bili--stream-url
                  client bvid cid
                  (lambda (chosen audio-info streams reply)
                    (if (and chosen (plist-get chosen :url))
                        (let* ((dim (plist-get data :dimension))
                               (width (or (plist-get chosen :width)
                                          (plist-get page-entry :width)
                                          (car-safe dim) 1280))
                               (height (or (plist-get chosen :height)
                                           (plist-get page-entry :height)
                                           (cdr-safe dim) 720))
                               (fps (or (plist-get chosen :fps) 30.0))
                               (dur (or (and page-entry (> (or (plist-get page-entry :duration) 0) 0)
                                             (plist-get page-entry :duration))
                                        (plist-get data :duration)
                                        0))
                               (audio-urls (plist-get audio-info :urls))
                               (audio-primary (car-safe audio-urls)))
                          (funcall callback
                                   (list :ok
                                         (append
                                          (list :kind 'url
                                                :url (plist-get chosen :url)
                                                :bvid bvid
                                                :aid (plist-get data :aid)
                                                :cid cid
                                                :title (plist-get data :title)
                                                :part-title (and page-entry (plist-get page-entry :part))
                                                :part-index (or (and page-entry (plist-get page-entry :page)) 1)
                                                :duration dur
                                                :width width
                                                :height height
                                                :fps fps
                                                :audio t
                                                :quality-id (plist-get chosen :id)
                                                :quality-label (plist-get chosen :label)
                                                :codec-label (plist-get chosen :codec-label)
                                                :backup-urls (plist-get chosen :backup-urls)
                                                :headers (list (cons "Referer" etaf-bili--referer)
                                                               (cons "User-Agent" etaf-bili--user-agent))
                                                :description (plist-get data :description)
                                                :author (plist-get data :author)
                                                :mid (plist-get data :mid)
                                                :views (plist-get data :views)
                                                :danmaku (plist-get data :danmaku)
                                                :likes (plist-get data :likes)
                                                :coins (plist-get data :coins)
                                                :favorites (plist-get data :favorites)
                                                :date (plist-get data :date)
                                                :tname (plist-get data :tname)
                                                :cover (plist-get data :cover)
                                                :pages pages
                                                :season (plist-get data :season))
                                          (when audio-primary
                                            (append
                                             (list :audio-url audio-primary
                                                   :audio-backup-urls (cdr audio-urls))
                                             (when-let* ((aid (plist-get audio-info :id)))
                                               (list :audio-id aid))
                                             (when-let* ((albl (plist-get audio-info :label)))
                                               (list :audio-label albl))))
                                          (when streams
                                            (list :streams streams))))))
                      (funcall callback
                               (or (and (plist-get reply :error) reply)
                                   (list :error "No stream URL in the reply")))))
                  req-qn)
               (funcall callback (or info (list :error "Video metadata missing"))))))))))
    (:player-info
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/player/wbi/v2"
         (list (cons "bvid" (or (plist-get request :bvid) ""))
               (cons "cid" (number-to-string (or (plist-get request :cid) 0))))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (let* ((lpt (or (etaf-bili--get data 'last_play_time) 0))
                      (subs (mapcar (lambda (s)
                                      (list :lan (or (etaf-bili--get s 'lan) "")
                                            :label (or (etaf-bili--get s 'lan_doc)
                                                       (etaf-bili--get s 'lan) "字幕")
                                            :url (etaf-bili--https-url
                                                  (etaf-bili--get s 'subtitle_url))))
                                    (etaf-bili--rows
                                     (etaf-bili--get-in data '(subtitle subtitles)))))
                      (chapters (mapcar (lambda (vp)
                                          (list :from (or (etaf-bili--get vp 'from) 0)
                                                :to (or (etaf-bili--get vp 'to) 0)
                                                :title (or (etaf-bili--get vp 'content) "")))
                                        (etaf-bili--rows (etaf-bili--get data 'view_points)))))
                 (funcall callback
                          (list :ok (list :last-play-time (if (and (numberp lpt) (> lpt 0))
                                                              (/ (float lpt) 1000.0)
                                                            0)
                                          :subtitles (seq-filter (lambda (s) (not (string-empty-p (plist-get s :url)))) subs)
                                          :chapters chapters))))
             (funcall callback reply)))
         t))))
    (:subtitle-body
     (let ((url (etaf-bili--https-url (plist-get request :url))))
       (if (string-empty-p url)
           (funcall callback '(:ok nil))
         (etaf-bili--run
          client (list url)
          (lambda (reply)
            (if-let* ((body (plist-get reply :ok)))
                (funcall callback (list :ok (etaf-bili--parse-subtitle-json body)))
              (funcall callback reply)))
          :none))))
    (:danmaku
     (let ((cid (plist-get request :cid)))
       (if (not (and (numberp cid) (> cid 0)))
           (funcall callback '(:ok nil))
         (etaf-bili--run
          client (list "--compressed"
                       (format "https://comment.bilibili.com/%d.xml" cid))
          (lambda (reply)
            (if-let* ((body (plist-get reply :ok)))
                (funcall callback (list :ok (etaf-bili--parse-danmaku-xml body)))
              (funcall callback reply)))
          :read))))
    (:comments
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/v2/reply/wbi/main"
         (list (cons "type" "1")
               (cons "oid" (number-to-string (or (plist-get request :aid) 0)))
               (cons "mode" "3")
               (cons "next" (number-to-string (or (plist-get request :page) 0))))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili--parse-comments data)))
             (funcall callback reply)))
         t))))
    (:like
     (etaf-bili--api-post
      client "/x/web-interface/archive/like"
      (list (cons "bvid" (or (plist-get request :bvid) ""))
            (cons "like" (number-to-string (or (plist-get request :like) 1))))
      callback))
    (:coin
     (etaf-bili--api-post
      client "/x/web-interface/coin/add"
      (list (cons "bvid" (or (plist-get request :bvid) ""))
            (cons "multiply" (number-to-string (or (plist-get request :multiply) 1)))
            (cons "select_like" "1"))
      callback))
    (:toview-add
     (etaf-bili--api-post
      client "/x/v2/history/toview/add"
      (list (cons "bvid" (or (plist-get request :bvid) "")))
      callback))
    (:fav-add
     (etaf-bili--api-post
      client "/x/v3/fav/resource/deal"
      (list (cons "rid" (number-to-string (or (plist-get request :aid) 0)))
            (cons "type" "2")
            (cons "add_media_ids" (number-to-string (or (plist-get request :folder-id) 0))))
      callback))
    (:heartbeat
     (etaf-bili--api-post
      client "/x/click-interface/web/heartbeat"
      (list (cons "aid" (number-to-string (or (plist-get request :aid) 0)))
            (cons "cid" (number-to-string (or (plist-get request :cid) 0)))
            (cons "played_time" (number-to-string (max 0 (round (or (plist-get request :played-time) 0))))))
      callback))
    (_
     (funcall callback (list :error (format "Unknown operation: %S" (plist-get request :op)))))))

(provide 'etaf-bili-service)
;;; etaf-bili-service.el ends here
