;;; etaf-bili-service.el --- Bilibili web API client -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The application's only outside world: the Bilibili web API, driven through
;; curl child processes.  Every call is asynchronous -- CALLBACK runs later in
;; the Emacs event loop with `(:ok DATA)' or `(:error MESSAGE :hint HINT)'.
;;
;; Requests are plists: (:op :popular), (:op :ranking), (:op :search :keyword
;; "emacs" :page 1), (:op :play :bvid "BV...").  The `:play' operation chains
;; the two protocol steps (video metadata, then stream URL) so callers ask
;; once; its `:ok' data is an `etaf-video' source plist with the Referer and
;; User-Agent headers the CDN requires.
;;
;; Two protocol facts shape the code.  Search and the signed endpoints need
;; WBI signing: the server hands out two keys on any page load, the client
;; caches them, and `w_rid' is an MD5 over the sorted query plus a permuted
;; key.  Every request also needs a `buvid3' cookie, so the client warms its
;; cookie jar once with a homepage visit before the first API call.
;;
;; Tests bind `etaf-bili-client-factory' to a fake client, so no scenario
;; needs the network.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-util)

(define-error 'etaf-bili-error "Bilibili client error")

(defcustom etaf-bili-state-directory
  (locate-user-emacs-file "etaf-bili/")
  "Directory holding the client's cookie jar and other local state."
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

(defconst etaf-bili--api-root "https://api.bilibili.com"
  "Root of the web API endpoints this client calls.")

(defconst etaf-bili--referer "https://www.bilibili.com"
  "Referer sent with API and stream requests.
The video CDN refuses requests without it; the API endpoints expect it too.")

(defconst etaf-bili--user-agent
  (concat "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
          "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
  "Browser user agent sent with every request.
The API and CDN reject the default curl agent for some endpoints.")

(defconst etaf-bili--mixin-key-tab
  [46 47 18 2 53 8 23 32 15 50 10 31 58 3 45 35
   27 43 5 49 33 9 42 19 29 28 14 39 12 38 41 13
   37 48 7 16 24 55 40 61 26 17 0 1 60 51 30 4
   22 25 54 21 56 59 6 63 57 62 11 36 20 34 44 52]
  "WBI permutation table: index i of the mixed key comes from position TAB[i].")

(defvar etaf-bili-client-factory nil
  "Function returning the backend client used by new sessions.
It is called with no arguments and must return a client built by
`etaf-bili-make-client', or any function accepting (REQUEST CALLBACK) as
`etaf-bili-client-call' documents.  Nil selects the default curl client;
tests bind this to a fake client.")

;;; WBI signing

(defun etaf-bili--mixin-key (img-key sub-key)
  "Return the WBI mixin key from IMG-KEY and SUB-KEY.
The server's two keys are permuted through `etaf-bili--mixin-key-tab' and
truncated to 32 characters."
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
  "Sign PARAMS with MIXIN-KEY and return the query string.
PARAMS is an alist of string keys and values; a `wts' timestamp (defaulting
to the current time) is appended, the result is sorted by key and encoded
like `encodeURIComponent' before the MD5, and `w_rid' is appended to the
returned query.  Exposed so the signature contract is testable without the
network."
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
  "Urlencode TEXT the way the WBI signer does.
This follows `encodeURIComponent': the unreserved marks stay, a space
becomes `%20' (not `+'), and everything else hex-escapes uppercase; the
server recomputes the signature with the same encoding."
  (url-hexify-string (or text "")
                     (string-to-list
                      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")))

;;; JSON helpers

(defun etaf-bili--get (alist key)
  "Return KEY's value in ALIST.
ALIST comes from `etaf-bili--json', where object keys are symbols."
  (cdr (assq key alist)))

(defun etaf-bili--rows (value)
  "Return the elements of a JSON array VALUE in either json.el shape.
Depending on the parsed context the array is already the element list or it
is wrapped as a `(list ...)' form; both shapes flatten to the rows."
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

;;; Presentation helpers (shared with the model's rows)

(defun etaf-bili-clean-title (title)
  "Return TITLE without search highlighting markup.
The search API wraps matches in `<em class=\"keyword\">' tags and escapes
XML entities; the player column shows plain text instead."
  (when title
    (let ((text (replace-regexp-in-string "<[^>]*>" "" title)))
      (dolist (pair '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">")
                      ("&quot;" . "\"") ("&#39;" . "'") ("&apos;" . "'")))
        (setq text (replace-regexp-in-string
                    (regexp-quote (car pair)) (cdr pair) text)))
      text)))

(defun etaf-bili--seconds (duration)
  "Return DURATION in seconds.
DURATION is either a number of seconds or a `MM:SS' / `HH:MM:SS' string as
the search API returns it."
  (cond
   ((numberp duration) (round duration))
   ((stringp duration)
    (let ((parts (mapcar #'string-to-number (split-string duration ":" t))))
      (pcase (length parts)
        (3 (+ (* (nth 0 parts) 3600) (* (nth 1 parts) 60) (nth 2 parts)))
        (2 (+ (* (nth 0 parts) 60) (nth 1 parts)))
        (1 (car parts))
        (_ 0))))
   (t 0)))

(defun etaf-bili--date (value)
  "Return VALUE as a `YYYY-MM-DD' string.
VALUE is a Unix timestamp, a `YYYY-MM-DD HH:MM:SS' string or an ISO date."
  (cond
   ((numberp value)
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
Rows carry `:bvid', `:aid', `:title', `:author', `:duration' (seconds),
`:views' (a display string), `:date' and `:cover'."
  (list :bvid (or (etaf-bili--get entry 'bvid) "")
        :aid (or (etaf-bili--get entry 'aid) 0)
        :title (or (etaf-bili-clean-title (etaf-bili--get entry 'title)) "")
        :author (or (etaf-bili--get entry 'author)
                    (etaf-bili--get-in entry '(owner name))
                    "")
        :duration (etaf-bili--seconds (etaf-bili--get entry 'duration))
        :views (etaf-bili--views (or (etaf-bili--get entry 'play)
                                     (etaf-bili--get-in entry '(stat view))
                                     ""))
        :date (etaf-bili--date (etaf-bili--get entry 'pubdate))
        :cover (or (etaf-bili--get entry 'pic) "")))

(defun etaf-bili-parse-videos (data)
  "Parse a video list response DATA into row plists.
DATA is the `data' object of a popular, ranking or search response, parsed
by `json-parse-string' with an alist object type.  Each row carries
`:bvid', `:aid', `:title', `:author', `:duration' (seconds), `:views'
(a display string), `:date' and `:cover'."
  (let ((items (or (etaf-bili--rows (etaf-bili--get data 'list))
                   (etaf-bili--rows (etaf-bili--get data 'result)))))
    (mapcar #'etaf-bili--parse-video items)))

;;; Client

(defun etaf-bili--cookie-file (client)
  "Return CLIENT's cookie jar path, creating its directory."
  (let ((file (expand-file-name "cookies.txt" (plist-get client :state-directory))))
    (make-directory (file-name-directory file) t)
    file))

(cl-defun etaf-bili-make-client (&key state-directory timeout)
  "Create the default curl-backed client.
STATE-DIRECTORY and TIMEOUT default to `etaf-bili-state-directory' and
`etaf-bili-request-timeout'."
  (list :state-directory (or state-directory etaf-bili-state-directory)
        :timeout (or timeout etaf-bili-request-timeout)
        :warmed nil
        :wbi nil))

(defun etaf-bili--curl-command (client arguments)
  "Build one curl invocation for CLIENT with ARGUMENTS appended.
ARGUMENTS is a list of command-line strings."
  (append (list etaf-bili-curl-program
                "-sS" "-L" "--max-time" (number-to-string (plist-get client :timeout))
                "-A" etaf-bili--user-agent
                "-e" etaf-bili--referer
                "-b" (etaf-bili--cookie-file client)
                "-c" (etaf-bili--cookie-file client))
          arguments))

(defun etaf-bili--run (client arguments callback)
  "Run bounded curl ARGUMENTS for CLIENT, then deliver stdout to CALLBACK.
Drain both pipes before settlement; stderr process messages are not backend
errors.  The returned process can be cancelled by its owner."
  (let ((output (generate-new-buffer " *bili-output*"))
        (errors (generate-new-buffer " *bili-errors*")))
    (condition-case problem
        (let ((process
               (make-process
                :name "etaf-bili-curl" :buffer output :stderr errors
                :coding '(utf-8-unix . utf-8-unix) :noquery t
                :command (etaf-bili--curl-command client arguments)
                :sentinel
                (lambda (process _event)
                  (when (and (memq (process-status process) '(exit signal))
                             (buffer-live-p output))
                    (while (accept-process-output process 0))
                    (when-let* ((pipe (get-buffer-process errors)))
                      (while (accept-process-output pipe 0)))
                    (let ((body (with-current-buffer output
                                  (buffer-substring-no-properties (point-min) (point-max))))
                          (failure (with-current-buffer errors
                                     (string-trim (buffer-substring-no-properties
                                                   (point-min) (point-max)))))
                          (code (process-exit-status process)))
                      (kill-buffer output)
                      (kill-buffer errors)
                      (funcall callback
                               (if (= code 0) (list :ok body)
                                 (list :error "网络请求未完成，请重试"
                                       :hint (format "curl %s: %s" code failure))))))))))
          (when-let* ((pipe (get-buffer-process errors)))
            (set-process-sentinel pipe #'ignore))
          process)
      (file-error
       (kill-buffer output) (kill-buffer errors)
       (funcall callback (list :error (error-message-string problem)))
       nil))))

(defun etaf-bili--json (body)
  "Parse BODY as a JSON object alist, signaling on malformed data."
  (condition-case nil
      (json-parse-string body :object-type 'alist :array-type 'list)
    (error (signal 'etaf-bili-error
                   (list "Bilibili returned a non-JSON response")))))

(defun etaf-bili--api-call (client path params callback &optional signed)
  "GET api PATH with PARAMS and call CALLBACK with the parsed payload.
PARAMS is an alist of string keys.  When SIGNED is non-nil the WBI signature
is added from CLIENT's cached keys.  The callback receives
`(:ok DATA)' with the `data' field on success and `(:error MESSAGE)' when
the response reports an API error or carries no JSON."
  (let* ((query (if signed
                    (etaf-bili-wbi-query params (plist-get client :wbi))
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

(defun etaf-bili--warm (client then)
  "Make sure CLIENT has cookies and WBI keys, then call THEN.
The homepage visit fills the cookie jar with `buvid3'; the nav response
carries the two WBI keys even when it reports the visitor as not logged in
(code -101), so it is parsed without the strict code check.  Both steps run
once per client; a failed warm still calls THEN because the unsigned
endpoints keep working without keys."
  (if (and (plist-get client :warmed) (plist-get client :wbi))
      (funcall then)
    (etaf-bili--run
     client (list etaf-bili--referer)
     (lambda (_reply)
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
          (funcall then)))))))

(defun etaf-bili--stream-url (client bvid cid callback)
  "Ask for BVID's playable stream at CID and call CALLBACK with the result.
CALLBACK receives (URL AUDIO STREAMS REPLY).  The reply's DASH manifest is
preferred: a Bilibili stream is usually a video track and a separate audio
track, so the player needs both URLs and must remember every other track for
an instant quality switch.  An older MP4 reply (DASH absent) still works
through its `durl' entry.  URL is nil when nothing is playable, and REPLY
carries the failure as reported by the site."
  (etaf-bili--api-call
   client "/x/player/playurl"
   (list (cons "bvid" bvid)
         (cons "cid" (number-to-string cid))
         (cons "qn" "80")
         (cons "fnval" "16")
         (cons "fourk" "1"))
   (lambda (reply)
     (let* ((play (plist-get reply :ok))
            (dash (etaf-bili--get play 'dash))
            (videos (etaf-bili--rows (etaf-bili--get dash 'video)))
            (audios (etaf-bili--rows (etaf-bili--get dash 'audio)))
            (durl (etaf-bili--rows (etaf-bili--get play 'durl)))
            (video (car videos))
            (audio (car (sort (copy-sequence audios)
                              (lambda (a b)
                                (> (or (etaf-bili--get a 'bandwidth) 0)
                                   (or (etaf-bili--get b 'bandwidth) 0)))))))
       (cond
        ((and video (etaf-bili--get video 'baseUrl))
         (funcall callback
                  (etaf-bili--get video 'baseUrl)
                  (etaf-bili--get audio 'baseUrl)
                  (mapcar (lambda (entry)
                            (list :id (etaf-bili--get entry 'id)
                                  :label (etaf-bili--quality-label
                                          (etaf-bili--get entry 'id))
                                  :url (etaf-bili--get entry 'baseUrl)
                                  :codec (etaf-bili--get entry 'codecs)))
                          videos)
                  reply))
        ((and durl (etaf-bili--get (car durl) 'url))
         (funcall callback (etaf-bili--get (car durl) 'url) nil nil reply))
        (t (funcall callback nil nil nil reply)))))))

(defun etaf-bili--quality-label (id)
  "Return the site's quality name for numeric stream ID.
Codes follow Bilibili's playurl documentation; an unknown ID keeps its
number so the menu still names what it offers."
  (or (cdr (assq id '((16 . "360P") (32 . "480P") (64 . "720P")
                      (74 . "720P60") (80 . "1080P") (112 . "1080P+")
                      (116 . "1080P60") (120 . "4K") (125 . "HDR")
                      (126 . "杜比视界") (127 . "8K"))))
      (format "%s" id)))

(defun etaf-bili-client-call (client request callback)
  "Perform one REQUEST through CLIENT and deliver the result to CALLBACK.
CLIENT is either the plist `etaf-bili-make-client' returns or a function
accepting (REQUEST CALLBACK); tests inject the function through
`etaf-bili-client-factory'.  REQUEST is a plist with an `:op':

- `(:op :popular :page 1)' -- currently popular videos.
- `(:op :ranking)' -- the all-category ranking.
- `(:op :search :keyword \"emacs\" :page 1)' -- video search.
- `(:op :video :bvid \"BV...\")' -- one video's metadata (`:ok' carries
  `:bvid', `:aid', `:cid', `:title', `:description', `:duration'.
- `(:op :play :bvid \"BV...\")' -- the metadata chain, then the stream URL;
  `:ok' carries an `etaf-video' source plist (`:url' plus the Referer and
  User-Agent `:headers' the CDN needs) together with `:title', `:duration'
  and `:bvid'.

CALLBACK receives `(:ok DATA)' or `(:error MESSAGE :hint HINT)'.  Network
failures, non-JSON responses and API error codes are all reported through
the error list."
  (if (functionp client)
      (funcall client request callback)
    (etaf-bili--call-curl client request callback)))

(defun etaf-bili--fetch-cover (client url callback)
  "Cache a public cover URL for CLIENT and deliver its local path to CALLBACK.
Only Bilibili's image CDN is accepted.  Downloads are limited to 2 MiB and
atomically renamed; a failed or cancelled transfer leaves no cache entry."
  (if (not (and (stringp url)
                (string-match-p "\\`https?://[A-Za-z0-9.-]+\\.hdslb\\.com/" url)))
      (progn (funcall callback '(:error "封面地址不可用")) nil)
    (let* ((url (replace-regexp-in-string "\\`http:" "https:" url))
           (directory (expand-file-name "covers/" (plist-get client :state-directory)))
           (file (expand-file-name (concat (secure-hash 'sha256 url) ".img") directory)))
      (make-directory directory t)
      (if (file-exists-p file)
          (progn (funcall callback (list :ok file)) nil)
        (let ((temporary (make-temp-file (expand-file-name ".cover-" directory))))
          (etaf-bili--run
           client (list "--fail" "--proto" "=https" "--max-filesize" "2097152"
                        "--output" temporary "--" url)
           (lambda (reply)
             (if (and (plist-member reply :ok)
                      (> (file-attribute-size (file-attributes temporary)) 0))
                 (progn (rename-file temporary file t)
                        (funcall callback (list :ok file)))
               (delete-file temporary)
               (funcall callback (list :error "封面加载失败，仍可播放视频"))))))))))

(defun etaf-bili--call-curl (client request callback)
  "Perform REQUEST through the curl CLIENT implementation."
  (pcase (plist-get request :op)
    (:cover (etaf-bili--fetch-cover client (plist-get request :url) callback))
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
         (list (cons "rid" "0") (cons "type" "all"))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))))))
    (:search
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/web-interface/wbi/search/type"
         (list (cons "search_type" "video")
               (cons "keyword" (or (plist-get request :keyword) ""))
               (cons "page" (number-to-string (or (plist-get request :page) 1))))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback (list :ok (etaf-bili-parse-videos data)))
             (funcall callback reply)))
         t))))
    (:video
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili--api-call
         client "/x/web-interface/view"
         (list (cons "bvid" (or (plist-get request :bvid) "")))
         (lambda (reply)
           (if-let* ((data (plist-get reply :ok)))
               (funcall callback
                        (list :ok (list :bvid (etaf-bili--get data 'bvid)
                                        :aid (etaf-bili--get data 'aid)
                                        :cid (etaf-bili--get
                                              (car (etaf-bili--rows
                                                    (etaf-bili--get data 'pages)))
                                              'cid)
                                        :title (or (etaf-bili-clean-title
                                                    (etaf-bili--get data 'title))
                                                   "")
                                        :description (etaf-bili--get data 'desc)
                                        :duration (etaf-bili--seconds
                                                   (etaf-bili--get data 'duration)))))
             (funcall callback reply)))))))
    (:play
     (etaf-bili--warm
      client
      (lambda ()
        (etaf-bili-client-call
         client (list :op :video :bvid (plist-get request :bvid))
         (lambda (info)
           (if-let* ((data (plist-get info :ok))
                     (cid (plist-get data :cid)))
               (etaf-bili--stream-url
                client (plist-get data :bvid) cid
                (lambda (url audio streams reply)
                  (if url
                      (funcall callback
                               (list :ok (append
                                          (list :url url
                                                :bvid (plist-get data :bvid)
                                                :title (plist-get data :title)
                                                :duration (plist-get data :duration)
                                                :headers (list (cons "Referer" etaf-bili--referer)
                                                               (cons "User-Agent" etaf-bili--user-agent)))
                                          (when audio (list :audio-url audio))
                                          (when streams (list :streams streams)))))
                    (funcall callback
                             (or reply (list :error "No stream URL in the reply"))))))
             (funcall callback (or info (list :error "Video metadata missing")))))))))
    (_
     (funcall callback (list :error (format "Unknown operation: %S" (plist-get request :op)))))))

(provide 'etaf-bili-service)
;;; etaf-bili-service.el ends here
