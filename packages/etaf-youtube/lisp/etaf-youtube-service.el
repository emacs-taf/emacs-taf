;;; etaf-youtube-service.el --- YouTube backend transport and URL parsing -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Runs the bundled Node.js YouTube backend (`backends/youtube/youtube.mjs')
;; through its protocol 1 JSON interface.  Every call is asynchronous,
;; timeout-bounded and cancellable; a late reply from a cancelled or
;; superseded request never reaches its callback.  The runner boundary is
;; injectable, so the public suite drives a whole session with canned JSON
;; and no browser, process or network.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-parse)
(require 'etaf)

(defun etaf-youtube--package-root ()
  "Return the root directory of the `etaf-youtube' package.
Works in source checkouts, ELPA archive installs and native-compiled loads."
  (let* ((desc (and (boundp 'package-alist)
                    (cadr (assq 'etaf-youtube package-alist))))
         (pkg-dir (and desc (fboundp 'package-desc-dir) (package-desc-dir desc)))
         (lib (locate-library "etaf-youtube"))
         (from-lib (and lib (not (string-suffix-p ".eln" lib))
                        (file-name-directory lib)))
         (from-load (and load-file-name (not (string-suffix-p ".eln" load-file-name))
                         (let ((d (file-name-directory load-file-name)))
                           (if (string-suffix-p "/lisp/" d)
                               (expand-file-name ".." d)
                             d))))
         (from-buf (and buffer-file-name
                        (let ((d (file-name-directory buffer-file-name)))
                          (if (string-suffix-p "/lisp/" d)
                              (expand-file-name ".." d)
                            d)))))
    (or (cl-find-if (lambda (d)
                      (and d (file-directory-p (expand-file-name "backends/youtube" d))))
                    (list pkg-dir from-lib from-load from-buf))
        pkg-dir from-lib from-load from-buf default-directory)))

(defcustom etaf-youtube-node-program "node"
  "Node.js executable that runs the bundled backend."
  :type 'string
  :group 'etaf-youtube)

(defcustom etaf-youtube-backend-directory
  (expand-file-name "backends/youtube" (etaf-youtube--package-root))
  "Directory holding this package's bundled YouTube backend.
The backend speaks the versioned protocol 1 JSON interface and needs only
Node.js; nothing here calls an external skill."
  :type 'directory
  :group 'etaf-youtube)

(defcustom etaf-youtube-command nil
  "Command prefix that runs the backend, or nil for the bundled one.
A list replaces the whole prefix, which the public suite uses to inject a
stand-in script."
  :type '(repeat string)
  :group 'etaf-youtube)

(defun etaf-youtube--command ()
  "Return the command prefix that runs the bundled backend."
  (or etaf-youtube-command
      (list etaf-youtube-node-program
            (expand-file-name "youtube.mjs" etaf-youtube-backend-directory))))

(defcustom etaf-youtube-request-timeout 95
  "Seconds before an unfinished backend request is cancelled."
  :type 'number
  :group 'etaf-youtube)

;;; ---------------------------------------------------------------------------
;;; Direct YouTube URL / ID target parsing
;;; ---------------------------------------------------------------------------

(defun etaf-youtube--parse-time-param (raw)
  "Parse YouTube `t' query parameter RAW (e.g. `90', `90s', `1m30s') to seconds."
  (when (and (stringp raw) (not (string-empty-p raw)))
    (cond
     ((string-match "\\`\\([0-9]+\\)s?\\'" raw)
      (string-to-number (match-string 1 raw)))
     ((string-match
       "\\`\\(?:\\([0-9]+\\)h\\)?\\(?:\\([0-9]+\\)m\\)?\\(?:\\([0-9]+\\)s\\)?\\'"
       raw)
      (let ((h (if (match-string 1 raw) (string-to-number (match-string 1 raw)) 0))
            (m (if (match-string 2 raw) (string-to-number (match-string 2 raw)) 0))
            (s (if (match-string 3 raw) (string-to-number (match-string 3 raw)) 0)))
        (when (> (+ h m s) 0)
          (+ (* 3600 h) (* 60 m) s))))
     (t nil))))

(defun etaf-youtube--parse-target (input)
  "Parse INPUT as a direct YouTube video/channel/playlist target, or nil.
Returns a plist `(:kind video :id ID :start SECONDS)', `(:kind channel :id ID)',
or `(:kind playlist :id ID)', or nil when INPUT is an ordinary search query."
  (let ((trimmed (string-trim (or input ""))))
    (cond
     ((string-empty-p trimmed) nil)
     ;; Direct YouTube / youtu.be URL
     ((string-match-p "\\`https?://\\(?:www\\.\\|m\\.\\|music\\.\\)?\\(?:youtube\\.com\\|youtu\\.be\\)/" trimmed)
      (let* ((parsed (url-generic-parse-url trimmed))
             (host (downcase (or (url-host parsed) "")))
             (path-query (or (url-filename parsed) ""))
             (parts (split-string path-query "?" t))
             (path (or (car parts) ""))
             (query (cadr parts))
             (params (and query (url-parse-query-string query)))
             (qval (lambda (k) (cadr (assoc k params))))
             (t-sec (etaf-youtube--parse-time-param (funcall qval "t"))))
        (cond
         ((string= host "youtu.be")
          (let ((seg (car (split-string path "/" t))))
            (when (and seg (string-match-p "\\`[A-Za-z0-9_-]\\{11\\}\\'" seg))
              (list :kind 'video :id seg :start t-sec))))
         ((string-prefix-p "/watch" path)
          (let ((vid (funcall qval "v")))
            (when (and vid (string-match-p "\\`[A-Za-z0-9_-]\\{11\\}\\'" vid))
              (list :kind 'video :id vid :start t-sec))))
         ((string-match "\\`/\\(?:shorts\\|live\\|embed\\)/\\([A-Za-z0-9_-]\\{11\\}\\)" path)
          (list :kind 'video :id (match-string 1 path) :start t-sec))
         ((string-prefix-p "/playlist" path)
          (let ((pl (funcall qval "list")))
            (when (and pl (string-match-p "\\`\\(?:PL\\|UU\\|VL\\|WL\\|LL\\)[A-Za-z0-9_-]*\\'" pl))
              (list :kind 'playlist :id pl))))
         ((string-match "\\`/channel/\\(UC[A-Za-z0-9_-]\\{22\\}\\)" path)
          (list :kind 'channel :id (match-string 1 path)))
         ((string-match "\\`/\\(@[A-Za-z0-9_.-]+\\)" path)
          (list :kind 'channel :id (match-string 1 path)))
         (t nil))))
     ;; Bare UC channel ID
     ((string-match-p "\\`UC[A-Za-z0-9_-]\\{22\\}\\'" trimmed)
      (list :kind 'channel :id trimmed))
     ;; Bare @handle (no whitespace)
     ((string-match-p "\\`@[A-Za-z0-9_.-]\\{2,\\}\\'" trimmed)
      (list :kind 'channel :id trimmed))
     ;; Bare PL playlist ID
     ((string-match-p "\\`PL[A-Za-z0-9_-]\\{12,\\}\\'" trimmed)
      (list :kind 'playlist :id trimmed))
     ;; Bare 11-char YouTube video ID (must contain at least one digit or -/_ so plain words stay search)
     ((and (string-match-p "\\`[A-Za-z0-9_-]\\{11\\}\\'" trimmed)
           (string-match-p "[0-9_-]" trimmed))
      (list :kind 'video :id trimmed :start nil))
     (t nil))))

;;; ---------------------------------------------------------------------------
;;; Service transport
;;; ---------------------------------------------------------------------------

(cl-defstruct (etaf-youtube--call
               (:constructor etaf-youtube--call--make))
  "One in-flight backend request."
  id key cancel timer callback)

(cl-defstruct (etaf-youtube-service
               (:constructor etaf-youtube--service--make))
  "Transport that runs protocol 1 backend commands."
  runner timeout calls counter)

(defun etaf-youtube--decode-json (text)
  "Return TEXT as a protocol payload plist, or signal an error."
  (let ((trimmed (string-trim text)))
    (when (string-empty-p trimmed)
      (error "Empty response"))
    (json-parse-string trimmed
                       :object-type 'plist
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun etaf-youtube--failure (payload message hint)
  "Build the service failure result from PAYLOAD, MESSAGE and HINT."
  (list :status 'error
        :value payload
        :message (or (and (stringp message) (not (string-empty-p message)) message)
                     "YouTube request failed")
        :hint (and (stringp hint) (not (string-empty-p hint)) hint)))

(defun etaf-youtube--settle (service id result)
  "Deliver RESULT to the call ID in SERVICE, unless it was cancelled.
RESULT is the raw runner plist `:exit', `:stdout' and `:stderr'."
  (when-let* ((call (gethash id (etaf-youtube-service-calls service))))
    (remhash id (etaf-youtube-service-calls service))
    (when-let* ((timer (etaf-youtube--call-timer call)))
      (cancel-timer timer))
    (let* ((exit (plist-get result :exit))
           (stdout (or (plist-get result :stdout) ""))
           (stderr (or (plist-get result :stderr) ""))
           (transport (plist-get result :error))
           (payload nil)
           (decoded nil))
      (unless transport
        (condition-case nil
            (setq payload (etaf-youtube--decode-json stdout)
                  decoded t)
          (error nil)))
      (cond
       (transport
        (funcall (etaf-youtube--call-callback call)
                 (etaf-youtube--failure nil (format "Transport failed: %s" transport)
                                        nil)))
       ((not decoded)
        (funcall (etaf-youtube--call-callback call)
                 (etaf-youtube--failure nil (string-trim stderr)
                                        "The backend did not return JSON")))
       ((and (eq exit 0) (plist-get payload :ok))
        (funcall (etaf-youtube--call-callback call)
                 (list :status 'ok :value payload)))
       (t
        (funcall (etaf-youtube--call-callback call)
                 (etaf-youtube--failure payload
                                        (or (plist-get payload :message)
                                            (string-trim stderr))
                                        (plist-get payload :hint))))))))

(defun etaf-youtube--run-process (argv callback)
  "Start ARGV and call CALLBACK with its `:exit', `:stdout' and `:stderr'.
Return a cancel function that stops the process."
  (let ((job (etaf-process-run
              argv :name "etaf-youtube"
              :coding '(utf-8 . utf-8)
              :callback
              (lambda (result)
                (funcall callback
                         (if (eq (plist-get result :status) 'failed)
                             (list :exit 127 :stdout ""
                                   :error (plist-get result :message))
                           (list :exit (plist-get result :exit)
                                 :stdout (or (plist-get result :output) "")
                                 :stderr (plist-get result :stderr))))))))
    (lambda () (etaf-process-cancel job))))

(cl-defun etaf-youtube-service-create (&key runner timeout)
  "Create a backend transport.
RUNNER defaults to the process runner; it receives ARGV and a CALLBACK and
returns a cancel function.  TIMEOUT defaults to
`etaf-youtube-request-timeout'."
  (etaf-youtube--service--make
   :runner (or runner #'etaf-youtube--run-process)
   :timeout (or timeout etaf-youtube-request-timeout)
   :calls (make-hash-table :test #'eql)
   :counter 0))

(defun etaf-youtube-service-call (service args callback &optional key)
  "Run backend ARGS through SERVICE and deliver the result to CALLBACK.
ARGS is a list of command words; `--json' is appended.  CALLBACK receives a
result plist whose `:status' is `ok', `error' or `timeout'; `:value' holds
the protocol payload on success, and `:message' and `:hint' describe a
failure.  KEY identifies the request: a new call with the same non-nil key
cancels the previous one, so only the newest reply reaches CALLBACK.

Return the opaque call id."
  (let ((id (cl-incf (etaf-youtube-service-counter service))))
    (when key
      (etaf-youtube-service-cancel service key))
    (let* ((call (etaf-youtube--call--make :id id :key key :callback callback))
           (runner (etaf-youtube-service-runner service))
           (argv (append (etaf-youtube--command) args (list "--json"))))
      (puthash id call (etaf-youtube-service-calls service))
      (setf (etaf-youtube--call-cancel call)
            (condition-case error
                (funcall runner argv
                         (lambda (result)
                           (etaf-youtube--settle service id result)))
              (error
               (etaf-youtube--settle
                service id
                (list :exit 1 :stdout ""
                      :error (error-message-string error))))))
      (when-let* ((cancel (etaf-youtube--call-cancel call)))
        (setf (etaf-youtube--call-timer call)
              (run-at-time (etaf-youtube-service-timeout service) nil
                           (lambda ()
                             (when (gethash id (etaf-youtube-service-calls service))
                               (ignore-errors (funcall cancel))
                               (remhash id (etaf-youtube-service-calls service))
                               (funcall callback
                                        (etaf-youtube--failure
                                         nil "YouTube request timed out"
                                         "Retry when the connection recovers")))))))
      id)))

(defun etaf-youtube-service-cancel (service &optional key)
  "Cancel SERVICE's in-flight request for KEY, or every request when KEY is nil."
  (let ((ids (etaf-youtube-service-calls service)))
    (maphash
     (lambda (id call)
       (when (or (null key) (equal key (etaf-youtube--call-key call)))
         (when-let* ((timer (etaf-youtube--call-timer call)))
           (cancel-timer timer))
         (when-let* ((cancel (etaf-youtube--call-cancel call)))
           (ignore-errors (funcall cancel)))
         (remhash id ids)))
     (copy-hash-table ids))))

(defun etaf-youtube-service-close (service)
  "Cancel every request of SERVICE and release its state."
  (etaf-youtube-service-cancel service)
  (clrhash (etaf-youtube-service-calls service)))

(provide 'etaf-youtube-service)
;;; etaf-youtube-service.el ends here
