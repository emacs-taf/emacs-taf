;;; maillist-nntp.el --- Persistent async NNTP backend for maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public-inbox archives such as yhetil.org expose read-only NNTP alongside
;; their HTTP pages.  Unlike HTTP (which sits behind anti-bot proxies and
;; per-request TLS handshakes and returns index pages without senders), one
;; persistent NNTP socket fetches hundreds of headers with authors and
;; References in a single `XOVER' command and pipelines `ARTICLE <mid>' bursts
;; in a fraction of a second.
;;
;; All socket I/O is non-blocking (`make-network-process' with `:nowait t').
;; A priority queue lets user-initiated thread opens preempt background
;; prefetching.  If NNTP cannot connect, the host enters a short cooldown and
;; callers fall back transparently to HTTP.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rfc2047)
(require 'mail-parse)
(require 'mm-decode)
(require 'mm-util)
(require 'qp)
(require 'maillist-service)

(defcustom maillist-transport 'auto
  "Transport used for archive sync and thread loading.
`auto' uses NNTP whenever a source declares `:nntp' and falls back to HTTP if
NNTP is unreachable; `nntp' prefers NNTP; `http' always uses HTTP endpoints."
  :type '(choice (const :tag "NNTP when available, else HTTP" auto)
                 (const :tag "NNTP only when declared" nntp)
                 (const :tag "HTTP only" http))
  :group 'maillist)

(defcustom maillist-nntp-sync-window 250
  "Number of recent articles fetched on an initial NNTP sync.
Subsequent syncs fetch only articles newer than the stored high-water mark."
  :type 'integer
  :group 'maillist)

(defcustom maillist-nntp-older-batch 200
  "Number of older articles fetched per `maillist-load-older' over NNTP."
  :type 'integer
  :group 'maillist)

(defcustom maillist-nntp-connect-timeout 6
  "Seconds to wait for an NNTP connection before falling back to HTTP."
  :type 'number
  :group 'maillist)

(defcustom maillist-nntp-pipeline-size 20
  "Maximum number of `ARTICLE' commands sent in one NNTP pipeline burst."
  :type 'integer
  :group 'maillist)

(defconst maillist-nntp--multiline-codes '("101" "215" "220" "221" "222" "224")
  "NNTP 3-digit status codes followed by a dot-terminated multiline block.")

(defconst maillist-nntp--cooldown-seconds 300
  "Seconds an unreachable NNTP endpoint stays bypassed in favor of HTTP.")

(defvar maillist-nntp--connections (make-hash-table :test #'equal)
  "Active persistent NNTP connection plists keyed by (HOST . PORT).")

(defvar maillist-nntp--cooldown (make-hash-table :test #'equal)
  "Map from (HOST . PORT) to expiration time while NNTP is bypassed.")

;;; ---------------------------------------------------------------------------
;;; Source capability & cooldown helpers
;;; ---------------------------------------------------------------------------

(defun maillist-nntp-source-spec (source)
  "Return SOURCE's `:nntp' plist when NNTP is enabled for SOURCE, else nil."
  (when (and (not (eq maillist-transport 'http))
             (listp source))
    (let ((spec (plist-get source :nntp)))
      (when (and (listp spec)
                 (stringp (plist-get spec :host))
                 (stringp (plist-get spec :group)))
        spec))))

(defun maillist-nntp--key (spec)
  "Return the connection table key for NNTP SPEC."
  (cons (plist-get spec :host) (or (plist-get spec :port) 119)))

(defun maillist-nntp-available-p (source)
  "Return non-nil when SOURCE can currently attempt NNTP."
  (when-let* ((spec (maillist-nntp-source-spec source)))
    (let ((until (gethash (maillist-nntp--key spec) maillist-nntp--cooldown)))
      (or (null until) (>= (float-time) until)))))

(defun maillist-nntp-clear-cooldown (&optional source)
  "Clear NNTP fallback cooldown for SOURCE, or all hosts when SOURCE is nil."
  (if-let* ((spec (and source (maillist-nntp-source-spec source))))
      (remhash (maillist-nntp--key spec) maillist-nntp--cooldown)
    (clrhash maillist-nntp--cooldown)))

;;; ---------------------------------------------------------------------------
;;; Pure parsers: XOVER, threading, RFC 5322 + MIME
;;; ---------------------------------------------------------------------------

(defun maillist-nntp--strip-angle (text)
  "Return Message-ID TEXT without outer angle brackets or whitespace, or nil."
  (when (stringp text)
    (let ((trimmed (string-trim text)))
      (when (string-prefix-p "<" trimmed)
        (setq trimmed (substring trimmed 1)))
      (when (string-suffix-p ">" trimmed)
        (setq trimmed (substring trimmed 0 (1- (length trimmed)))))
      (setq trimmed (string-trim trimmed))
      (unless (string-empty-p trimmed) trimmed))))

(defun maillist-nntp--parse-references (text)
  "Return ordered list of canonical Message-IDs extracted from References TEXT."
  (when (and (stringp text) (not (string-empty-p text)))
    (let ((start 0) (ids nil))
      (while (string-match "<\\([^<> \t\r\n]+\\)>" text start)
        (setq start (match-end 0))
        (let ((id (string-trim (match-string 1 text))))
          (unless (string-empty-p id)
            (push id ids))))
      (nreverse ids))))

(defun maillist-nntp--decode-header (text)
  "Decode RFC 2047 words and collapse whitespace in header TEXT."
  (let* ((raw (or text ""))
         (unibyte (if (multibyte-string-p raw)
                      raw
                    (decode-coding-string raw 'utf-8)))
         (clean (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " unibyte)))
         (decoded (or (ignore-errors (rfc2047-decode-string clean)) clean)))
    (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " decoded))))

(defun maillist-nntp--iso-date (text)
  "Convert RFC 5322 date TEXT to an ISO-8601 UTC timestamp, or empty string."
  (if-let* ((raw (and (stringp text) (string-trim text)))
            ((not (string-empty-p raw)))
            (time (ignore-errors (date-to-time raw))))
      (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t)
    ""))

(defun maillist-nntp--parse-from (text)
  "Return (NAME . EMAIL) extracted from RFC 5322 From header TEXT."
  (let ((decoded (maillist-nntp--decode-header text)))
    (if (string-empty-p decoded)
        (cons "" "")
      (let* ((parsed (ignore-errors (mail-header-parse-address decoded)))
             (first (car parsed))
             (second (cdr parsed))
             (email "")
             (name ""))
        (cond
         ((null parsed)
          (if (string-match "<\\([^<> \t]+@[^<> \t]+\\)>" decoded)
              (setq email (match-string 1 decoded)
                    name (string-trim
                          (string-trim (substring decoded 0 (match-beginning 0)))
                          "\"" "\""))
            (setq name decoded)))
         ((and first (string-match-p "@" first))
          (setq email first
                name (if (and second (not (string-empty-p second))) second first)))
         ((and second (string-match-p "@" second))
          (setq email second
                name (if (and first (not (string-empty-p first))) first second)))
         (t
          (setq name (or first decoded))))
        (cons (string-trim (or name "")) (string-trim (or email "")))))))

(defun maillist-nntp-parse-overview (text)
  "Parse NNTP `XOVER' multiline response TEXT into overview article plists.
Each record carries `:artnum', `:subject', `:author', `:email', `:date',
`:id', `:parent', `:root-id' and `:references'."
  (let ((articles nil))
    (dolist (line (split-string (or text "") "\r?\n" t))
      (let ((fields (split-string line "\t")))
        (when (>= (length fields) 5)
          (let* ((artnum (string-to-number (nth 0 fields)))
                 (subject (maillist-nntp--decode-header (nth 1 fields)))
                 (from (maillist-nntp--parse-from (nth 2 fields)))
                 (date (maillist-nntp--iso-date (nth 3 fields)))
                 (id (maillist-nntp--strip-angle (nth 4 fields)))
                 (refs (maillist-nntp--parse-references (nth 5 fields)))
                 (parent (car (last refs)))
                 (root (or (car refs) id)))
            (when (and (> artnum 0) id)
              (push (list :artnum artnum
                          :subject subject
                          :author (car from)
                          :email (cdr from)
                          :date date
                          :id id
                          :parent (unless (equal parent id) parent)
                          :root-id root
                          :references refs)
                    articles))))))
    (nreverse articles)))

(defun maillist-nntp-group-articles (articles)
  "Group overview ARTICLES into thread rows sorted newest first.
Uses union-find across `:id', `:parent' and `:root-id' so replies with
truncated `References' stay attached to their discussion.  Each returned row
matches the shape of `maillist-parse-index' plus `:author' and `:participants'."
  (let ((parent-map (make-hash-table :test #'equal))
        (by-id (make-hash-table :test #'equal))
        (buckets (make-hash-table :test #'equal)))
    (cl-labels
        ((find-root (x)
           (let ((p (gethash x parent-map)))
             (if (or (null p) (equal p x))
                 x
               (let ((r (find-root p)))
                 (puthash x r parent-map)
                 r))))
         (unite (a b)
           (when (and a b (not (string-empty-p a)) (not (string-empty-p b)))
             (let ((ra (find-root a))
                   (rb (find-root b)))
               (unless (equal ra rb)
                 ;; Keep the root candidate (usually the earlier ancestor).
                 (puthash rb ra parent-map))))))
      ;; Register all articles and connect references -> id.
      (dolist (art articles)
        (let* ((id (plist-get art :id))
               (root (plist-get art :root-id))
               (parent (plist-get art :parent)))
          (when id
            (puthash id art by-id)
            (unless (gethash id parent-map) (puthash id id parent-map))
            (when root
              (unless (gethash root parent-map) (puthash root root parent-map))
              (unite root id))
            (when parent
              (unless (gethash parent parent-map) (puthash parent parent parent-map))
              (unite parent id)))))
      ;; Bucket articles by connected component.
      (dolist (art articles)
        (let* ((id (plist-get art :id))
               (rep (find-root id)))
          (puthash rep (cons art (gethash rep buckets)) buckets)))
      ;; Build thread rows.
      (let ((rows nil))
        (maphash
         (lambda (_rep items)
           (let* ((ordered (sort (copy-sequence items)
                                 (lambda (a b)
                                   (let ((da (or (plist-get a :date) ""))
                                         (db (or (plist-get b :date) "")))
                                     (if (equal da db)
                                         (< (or (plist-get a :artnum) 0)
                                            (or (plist-get b :artnum) 0))
                                       (string< da db))))))
                  (first (car ordered))
                  (last-art (car (last ordered)))
                  ;; Deterministically pick the thread root from the earliest
                  ;; article in the component (independent of union-find order):
                  ;; if the earliest article has References predating our window,
                  ;; its first reference is the root; otherwise it IS the root.
                  (earliest-refs (plist-get first :references))
                  (canonical-id (or (car earliest-refs) (plist-get first :id)))
                  (root-art (gethash canonical-id by-id))
                  (raw-subject (or (and root-art (plist-get root-art :subject))
                                   (plist-get first :subject)
                                   ""))
                  (subject (if root-art
                               raw-subject
                             (maillist-thread-subject raw-subject)))
                  (author (or (and root-art
                                   (not (string-empty-p
                                         (or (plist-get root-art :author) "")))
                                   (plist-get root-art :author))
                              (cl-loop for a in ordered
                                       for name = (plist-get a :author)
                                       when (and name (not (string-empty-p name)))
                                       return name)
                              ""))
                  (senders (make-hash-table :test #'equal)))
             (dolist (a ordered)
               (plist-put a :root-id canonical-id)
               (let ((name (string-trim (or (plist-get a :author) ""))))
                 (unless (string-empty-p name) (puthash name t senders))))
             (push (list :id canonical-id
                         :subject (if (string-empty-p subject) raw-subject subject)
                         :date (or (plist-get last-art :date) "")
                         :count (length ordered)
                         :depth 0
                         :author author
                         :participants (max 1 (hash-table-count senders)))
                   rows)))
         buckets)
        (sort rows (lambda (a b)
                     (string> (or (plist-get a :date) "")
                              (or (plist-get b :date) ""))))))))

(defun maillist-nntp--header-value (headers name)
  "Return unfolded value of header NAME in HEADERS string, or nil."
  (let ((case-fold-search t))
    (when (string-match (format "^%s:[ \t]*\\(.*\\(?:\n[ \t]+.*\\)*\\)"
                                (regexp-quote name))
                        headers)
      (string-trim
       (replace-regexp-in-string "\n[ \t]+" " " (match-string 1 headers))))))

(defun maillist-nntp--decode-part-text (raw cte charset)
  "Decode RAW bytes using Content-Transfer-Encoding CTE and CHARSET."
  (let* ((enc (downcase (string-trim (or cte ""))))
         (bytes
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (or raw ""))
            (let ((inhibit-message t))
              (condition-case nil
                  (cond
                   ((equal enc "base64")
                    (base64-decode-region (point-min) (point-max)))
                   ((equal enc "quoted-printable")
                    (quoted-printable-decode-region (point-min) (point-max))))
                (error nil)))
            (buffer-string)))
         (cs (or (and (stringp charset)
                      (not (string-empty-p charset))
                      (let ((c (ignore-errors (mm-charset-to-coding-system charset))))
                        (and (coding-system-p c) c)))
                 'utf-8))
         (decoded (if (multibyte-string-p bytes)
                      bytes
                    (decode-coding-string bytes cs))))
    (replace-regexp-in-string "\r\n" "\n" decoded t t)))

(defun maillist-nntp--strip-html (html)
  "Return plain text fallback extracted from HTML string."
  (let ((text (replace-regexp-in-string "<br[ \t]*/?>" "\n" (or html "") t t)))
    (setq text (replace-regexp-in-string "</p>\\|</div>\\|</tr>" "\n" text t t))
    (setq text (replace-regexp-in-string "<[^>]+>" "" text))
    (maillist-decode-entities text)))

(defun maillist-nntp--collect-mime (handle)
  "Extract readable text from an `mm-dissect-buffer' HANDLE tree."
  (cond
   ((null handle) nil)
   ;; Composite multipart handle: (TYPE-STRING SUBHANDLE1 SUBHANDLE2 ...)
   ((stringp (car handle))
    (let ((subtype (downcase (car handle)))
          (children (cdr handle)))
      (cond
       ((equal subtype "multipart/alternative")
        (or (cl-loop for child in children
                     when (and (not (stringp (car child)))
                               (equal (downcase (or (mm-handle-media-type child) ""))
                                      "text/plain"))
                     return (maillist-nntp--collect-mime child))
            (cl-some #'maillist-nntp--collect-mime children)))
       (t
        (let ((parts (delq nil (mapcar #'maillist-nntp--collect-mime children))))
          (when parts (string-join parts "\n\n")))))))
   ;; Leaf MIME handle.
   (t
    (let* ((type (downcase (or (mm-handle-media-type handle) "text/plain")))
           (disp (mm-handle-disposition handle))
           (fname (or (mm-handle-filename handle)
                      (cdr (assq 'filename (cdr-safe disp)))))
           (charset (cdr (assq 'charset (cdr-safe (mm-handle-type handle))))))
      (cond
       ((or (equal type "text/plain")
            (equal type "text/x-patch")
            (equal type "text/x-diff")
            (equal type "message/rfc822"))
        (let* ((raw (condition-case nil (mm-get-part handle) (error "")))
               (cs (or (and charset
                            (let ((c (ignore-errors (mm-charset-to-coding-system charset))))
                              (and (coding-system-p c) c)))
                       'utf-8))
               (text (if (multibyte-string-p raw)
                         raw
                       (decode-coding-string raw cs)))
               (clean (replace-regexp-in-string "\r\n" "\n" text t t)))
          (if (and fname (not (equal type "text/plain")))
              (format "[附件: %s]\n%s" fname clean)
            clean)))
       ((equal type "text/html")
        (let* ((raw (condition-case nil (mm-get-part handle) (error "")))
               (text (if (multibyte-string-p raw) raw (decode-coding-string raw 'utf-8))))
          (maillist-nntp--strip-html text)))
       ((member type '("application/pgp-signature" "application/pkcs7-signature"))
        nil)
       (fname
        (format "[附件: %s (%s)]" fname type))
       (t nil))))))

(defun maillist-nntp--extract-body (raw-bytes content-type cte)
  "Extract decoded message body text from raw RFC 5322 article RAW-BYTES."
  (let ((ctype (downcase (or content-type ""))))
    (if (string-prefix-p "multipart/" ctype)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert (replace-regexp-in-string "\r\n" "\n" raw-bytes t t))
          (goto-char (point-min))
          (let* ((inhibit-message t)
                 (handles (condition-case nil
                              (mm-dissect-buffer t t)
                            (error nil))))
            (unwind-protect
                (or (and handles (maillist-nntp--collect-mime handles))
                    "")
              (when handles
                (ignore-errors (mm-destroy-parts handles))))))
      ;; Fast path for single-part text/plain (most mailing-list traffic).
      (let* ((charset
              (let ((case-fold-search t))
                (when (and content-type
                           (string-match "charset=[\"']?\\([^\"'; \t\r\n]+\\)"
                                         content-type))
                  (match-string 1 content-type))))
             (sep (string-match "\r?\n\r?\n" raw-bytes))
             (body-raw (if sep (substring raw-bytes (match-end 0)) "")))
        (if (string-prefix-p "text/html" ctype)
            (maillist-nntp--strip-html
             (maillist-nntp--decode-part-text body-raw cte charset))
          (maillist-nntp--decode-part-text body-raw cte charset))))))

(defun maillist-nntp-parse-article (raw &optional fallback-id)
  "Parse raw RFC 5322 article string RAW into a canonical maillist message plist.
FALLBACK-ID supplies `:id' if the article lacks a `Message-ID' header."
  (let* ((raw-str (or raw ""))
         (sep (string-match "\r?\n\r?\n" raw-str))
         (hdr-raw (if sep (substring raw-str 0 sep) raw-str))
         (hdr (replace-regexp-in-string "\r\n" "\n" hdr-raw t t))
         (from (maillist-nntp--parse-from (maillist-nntp--header-value hdr "From")))
         (subject (maillist-nntp--decode-header
                   (maillist-nntp--header-value hdr "Subject")))
         (date (maillist-nntp--iso-date (maillist-nntp--header-value hdr "Date")))
         (id (or (maillist-nntp--strip-angle
                  (maillist-nntp--header-value hdr "Message-ID"))
                 fallback-id
                 ""))
         (in-reply-to (maillist-nntp--strip-angle
                       (maillist-nntp--header-value hdr "In-Reply-To")))
         (refs (maillist-nntp--parse-references
                (maillist-nntp--header-value hdr "References")))
         (parent (or (unless (equal in-reply-to id) in-reply-to)
                     (let ((last-ref (car (last refs))))
                       (unless (equal last-ref id) last-ref))))
         (ctype (maillist-nntp--header-value hdr "Content-Type"))
         (cte (maillist-nntp--header-value hdr "Content-Transfer-Encoding"))
         (text (string-trim (maillist-nntp--extract-body raw-str ctype cte) "\n" "\n")))
    (list :id id
          :author (car from)
          :email (cdr from)
          :date date
          :parent parent
          :depth 0
          :subject subject
          :text text)))

;;; ---------------------------------------------------------------------------
;;; Persistent non-blocking NNTP client
;;; ---------------------------------------------------------------------------

(defun maillist-nntp--cancel-timer (plist key)
  "Cancel and clear timer under KEY in PLIST."
  (when-let* ((timer (plist-get plist key)))
    (cancel-timer timer)
    (plist-put plist key nil)))

(defun maillist-nntp--close-conn (conn &optional error-text mark-cooldown)
  "Close NNTP CONN, optionally failing pending work with ERROR-TEXT.
When MARK-COOLDOWN is non-nil, record a fallback cooldown for CONN's host."
  (maillist-nntp--cancel-timer conn :connect-timer)
  (let ((key (plist-get conn :key))
        (proc (plist-get conn :process))
        (buf (plist-get conn :buffer))
        (current (plist-get conn :current))
        (queue (plist-get conn :queue)))
    (when (eq (gethash key maillist-nntp--connections) conn)
      (remhash key maillist-nntp--connections))
    (when mark-cooldown
      (puthash key (+ (float-time) maillist-nntp--cooldown-seconds)
               maillist-nntp--cooldown))
    (plist-put conn :state 'closed)
    (plist-put conn :current nil)
    (plist-put conn :queue nil)
    (plist-put conn :process nil)
    (when (and proc (process-live-p proc))
      (set-process-filter proc nil)
      (set-process-sentinel proc nil)
      (ignore-errors (delete-process proc)))
    (when (buffer-live-p buf)
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer buf))))
    (when error-text
      (let ((all (append (and current (list current)) queue)))
        (dolist (req all)
          (maillist-nntp--cancel-timer req :timer)
          (unless (plist-get req :done)
            (plist-put req :done t)
            (funcall (plist-get req :callback) (list :error error-text))))))))

(defun maillist-nntp-close-all ()
  "Close every persistent NNTP connection held by maillist."
  (let (conns)
    (maphash (lambda (_k conn) (push conn conns)) maillist-nntp--connections)
    (dolist (conn conns)
      (maillist-nntp--close-conn conn "NNTP 连接已关闭" nil))))

(defun maillist-nntp--un-dot-stuff (text)
  "Remove RFC 3977 dot-stuffing from multiline NNTP body TEXT."
  (replace-regexp-in-string "^\\.\\." "." text))

(defun maillist-nntp--try-read-response (buf)
  "Try to consume one complete NNTP response from BUF.
Return (:code CODE :status LINE :body TEXT-OR-NIL), or nil when incomplete."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (when (search-forward "\r\n" nil t)
        (let* ((status-end (match-beginning 0))
               (body-start (match-end 0))
               (status (buffer-substring-no-properties (point-min) status-end))
               (code (and (>= (length status) 3) (substring status 0 3)))
               (multiline (member code maillist-nntp--multiline-codes)))
          (if (not multiline)
              (progn
                (delete-region (point-min) body-start)
                (list :code code :status status :body nil))
            (goto-char body-start)
            (cond
             ;; Empty multiline body immediately terminated by ".\r\n".
             ((looking-at "\\.\r\n")
              (delete-region (point-min) (match-end 0))
              (list :code code :status status :body ""))
             ;; Standard multiline body ending with "\r\n.\r\n".
             ((search-forward "\r\n.\r\n" nil t)
              (let* ((body-end (match-beginning 0))
                     (term-end (match-end 0))
                     (raw (buffer-substring-no-properties body-start body-end)))
                (delete-region (point-min) term-end)
                (list :code code :status status
                      :body (maillist-nntp--un-dot-stuff raw))))
             (t nil))))))))

(defun maillist-nntp--pump (conn)
  "Send the next queued request on CONN if CONN is ready."
  (when (and (eq (plist-get conn :state) 'ready)
             (null (plist-get conn :current))
             (plist-get conn :queue)
             (process-live-p (plist-get conn :process)))
    (let* ((req (pop (plist-get conn :queue)))
           (cmds (plist-get req :commands))
           (wire (concat (mapconcat #'identity cmds "\r\n") "\r\n")))
      (plist-put conn :state 'busy)
      (plist-put conn :current req)
      (plist-put req :remaining (length cmds))
      (plist-put req :responses nil)
      (plist-put req :timer
                 (run-at-time
                  (or (plist-get req :timeout) 20) nil
                  (lambda ()
                    (when (eq (plist-get conn :current) req)
                      (maillist-nntp--close-conn conn "NNTP 请求超时" nil)))))
      (condition-case err
          (process-send-string (plist-get conn :process) wire)
        (error
         (maillist-nntp--close-conn conn (error-message-string err) nil))))))

(defun maillist-nntp--drain (conn)
  "Parse all complete responses currently buffered in CONN."
  (let ((buf (plist-get conn :buffer))
        (progress t))
    (while (and progress (not (eq (plist-get conn :state) 'closed)))
      (setq progress nil)
      (pcase (plist-get conn :state)
        ('connecting
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (goto-char (point-min))
             (when (search-forward "\r\n" nil t)
               (let ((line (buffer-substring-no-properties
                            (point-min) (match-beginning 0))))
                 (delete-region (point-min) (match-end 0))
                 (maillist-nntp--cancel-timer conn :connect-timer)
                 (if (or (string-prefix-p "200" line)
                         (string-prefix-p "201" line))
                     (progn
                       (plist-put conn :ever-ready t)
                       (plist-put conn :state 'ready)
                       (maillist-nntp--pump conn)
                       (setq progress t))
                   (maillist-nntp--close-conn
                    conn (format "NNTP 拒绝连接：%s" line) t)))))))
        ('busy
         (when-let* ((req (plist-get conn :current))
                     (resp (maillist-nntp--try-read-response buf)))
           (setq progress t)
           (plist-put req :responses (cons resp (plist-get req :responses)))
           (cl-decf (plist-get req :remaining))
           (when (<= (plist-get req :remaining) 0)
             (maillist-nntp--cancel-timer req :timer)
             (plist-put conn :current nil)
             (plist-put conn :state 'ready)
             (unless (plist-get req :done)
               (plist-put req :done t)
               (let ((resps (nreverse (plist-get req :responses))))
                 (condition-case err
                     (funcall (plist-get req :callback) (list :ok resps))
                   (error
                    (message "maillist-nntp callback error: %s"
                             (error-message-string err))))))
             (maillist-nntp--pump conn))))))))

(defun maillist-nntp--filter (proc chunk)
  "Process filter appending CHUNK to PROC's NNTP buffer and draining responses."
  (when-let* ((conn (process-get proc 'maillist-nntp-conn))
              (buf (plist-get conn :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-max))
        (insert chunk))
      (maillist-nntp--drain conn))))

(defun maillist-nntp--sentinel (proc event)
  "Process sentinel handling NNTP connect completion and disconnects."
  (when-let* ((conn (process-get proc 'maillist-nntp-conn)))
    (unless (eq (plist-get conn :state) 'closed)
      (cond
       ((string-prefix-p "open" event)
        nil)
       (t
        (let* ((ever-ready (plist-get conn :ever-ready))
               (current (plist-get conn :current))
               (queue (plist-get conn :queue)))
          (if (and ever-ready (null current) (null queue))
              ;; Idle socket closed by remote server; drop silently without cooldown.
              (maillist-nntp--close-conn conn nil nil)
            (if (and ever-ready current (not (plist-get current :retried)))
                ;; Reused socket dropped right as a request went out: reconnect once.
                (let ((host (plist-get conn :host))
                      (port (plist-get conn :port))
                      (retry-list (cons current queue)))
                  (plist-put current :retried t)
                  (plist-put conn :current nil)
                  (plist-put conn :queue nil)
                  (maillist-nntp--close-conn conn nil nil)
                  (dolist (req retry-list)
                    (maillist-nntp--cancel-timer req :timer)
                    (maillist-nntp--enqueue-req host port req)))
              (maillist-nntp--close-conn
               conn (format "NNTP 断开：%s" (string-trim event))
               (not ever-ready))))))))))

(defun maillist-nntp--ensure-conn (host port)
  "Return an active or connecting NNTP connection plist for HOST:PORT."
  (let* ((key (cons host port))
         (existing (gethash key maillist-nntp--connections)))
    (if (and existing
             (not (eq (plist-get existing :state) 'closed))
             (process-live-p (plist-get existing :process)))
        existing
      (let* ((buf (generate-new-buffer (format " *maillist-nntp-%s:%s*" host port)))
             (conn (list :key key :host host :port port
                         :buffer buf :state 'connecting
                         :ever-ready nil :queue nil :current nil
                         :connect-timer nil)))
        (with-current-buffer buf
          (set-buffer-multibyte nil))
        (puthash key conn maillist-nntp--connections)
        (condition-case err
            (let ((proc (make-network-process
                         :name (format "maillist-nntp-%s:%s" host port)
                         :buffer nil
                         :host host
                         :service port
                         :nowait t
                         :coding 'binary
                         :filter #'maillist-nntp--filter
                         :sentinel #'maillist-nntp--sentinel)))
              (set-process-query-on-exit-flag proc nil)
              (process-put proc 'maillist-nntp-conn conn)
              (plist-put conn :process proc)
              (plist-put conn :connect-timer
                         (run-at-time
                          maillist-nntp-connect-timeout nil
                          (lambda ()
                            (when (eq (plist-get conn :state) 'connecting)
                              (maillist-nntp--close-conn conn "NNTP 连接超时" t)))))
              conn)
          (error
           (maillist-nntp--close-conn conn (error-message-string err) t)
           nil))))))

(defun maillist-nntp--enqueue-req (host port req)
  "Insert REQ into HOST:PORT's priority queue and pump."
  (if-let* ((conn (maillist-nntp--ensure-conn host port)))
      (let ((prio (plist-get req :priority))
            (queue (plist-get conn :queue)))
        (if (eq prio 'high)
            ;; Insert after existing high-priority items, before low-priority ones.
            (let ((head nil) (tail queue))
              (while (and tail (eq (plist-get (car tail) :priority) 'high))
                (push (pop tail) head))
              (plist-put conn :queue (append (nreverse head) (list req) tail)))
          (plist-put conn :queue (append queue (list req))))
        (maillist-nntp--pump conn))
    (unless (plist-get req :done)
      (plist-put req :done t)
      (funcall (plist-get req :callback) (list :error "无法建立 NNTP 连接")))))

(defun maillist-nntp--send (spec commands callback &optional priority timeout)
  "Send COMMANDS to NNTP SPEC and pass (:ok RESPONSES) or (:error MSG) to CALLBACK.
PRIORITY is `high' (default) or `low'."
  (let* ((host (plist-get spec :host))
         (port (or (plist-get spec :port) 119))
         (key (cons host port))
         (until (gethash key maillist-nntp--cooldown)))
    (if (and until (< (float-time) until))
        (run-at-time 0 nil callback (list :error "NNTP 暂时不可用"))
      (maillist-nntp--enqueue-req
       host port
       (list :commands commands
             :priority (or priority 'high)
             :timeout timeout
             :callback callback)))))

;;; ---------------------------------------------------------------------------
;;; High-level NNTP operations
;;; ---------------------------------------------------------------------------

(defun maillist-nntp--parse-group-status (status)
  "Parse NNTP `211 COUNT LOW HIGH GROUP' STATUS into (:count :low :high), or nil."
  (when (and (stringp status)
             (string-match "\\`211[ \t]+\\([0-9]+\\)[ \t]+\\([0-9]+\\)[ \t]+\\([0-9]+\\)"
                           status))
    (list :count (string-to-number (match-string 1 status))
          :low (string-to-number (match-string 2 status))
          :high (string-to-number (match-string 3 status)))))

(defun maillist-nntp-fetch-overview (source callback &optional start-art end-art priority)
  "Fetch NNTP overview articles for SOURCE and pass result to CALLBACK.
When START-ART is nil, fetches the latest `maillist-nntp-sync-window' articles.
When START-ART is an integer and END-ART is nil, fetches only articles strictly
newer than START-ART (`(1+ START-ART)' through group high).  When both
START-ART and END-ART are integers, fetches that exact inclusive range.
CALLBACK receives (:ok (:low LO :high HI :group-low GL :articles LIST))
or (:error MSG)."
  (let ((spec (maillist-nntp-source-spec source)))
    (if (null spec)
        (funcall callback (list :error "该源未配置 NNTP"))
      (let ((group (plist-get spec :group)))
        (maillist-nntp--send
         spec (list (format "GROUP %s" group))
         (lambda (res)
           (if-let* ((err (plist-get res :error)))
               (funcall callback (list :error err))
             (let* ((resp (car (plist-get res :ok)))
                    (info (maillist-nntp--parse-group-status (plist-get resp :status))))
               (if (null info)
                   (funcall callback
                            (list :error (format "NNTP 无法选择组 %s：%s"
                                                 group (plist-get resp :status))))
                 (let* ((g-low (plist-get info :low))
                        (g-high (plist-get info :high))
                        (lo (cond
                             ((and (integerp start-art) (integerp end-art))
                              (max g-low start-art))
                             ((integerp start-art)
                              (max g-low
                                   (1+ start-art)
                                   (- g-high (1- maillist-nntp-sync-window))))
                             (t
                              (max g-low (- g-high (1- maillist-nntp-sync-window))))))
                        (hi (if (integerp end-art)
                                (min g-high end-art)
                              g-high)))
                   (if (or (<= g-high 0) (> lo hi))
                       (funcall callback
                                (list :ok (list :low (or start-art g-low)
                                                :high g-high
                                                :group-low g-low
                                                :articles nil)))
                     (maillist-nntp--send
                      spec (list (format "XOVER %d-%d" lo hi))
                      (lambda (xres)
                        (if-let* ((xerr (plist-get xres :error)))
                            (funcall callback (list :error xerr))
                          (let* ((xresp (car (plist-get xres :ok)))
                                 (code (plist-get xresp :code)))
                            (if (equal code "224")
                                (funcall callback
                                         (list :ok
                                               (list :low lo
                                                     :high hi
                                                     :group-low g-low
                                                     :articles
                                                     (maillist-nntp-parse-overview
                                                      (plist-get xresp :body)))))
                              (funcall callback
                                       (list :error
                                             (format "NNTP XOVER 失败：%s"
                                                     (plist-get xresp :status))))))))
                      priority)))))))
         priority)))))

(defun maillist-nntp-fetch-articles (source mids callback &optional priority)
  "Fetch articles for canonical Message-IDs MIDS from SOURCE via NNTP pipelining.
CALLBACK receives (:ok MESSAGES) where MESSAGES is a list of parsed message
plists (missing 430 articles are skipped), or (:error MSG) on transport error."
  (let ((spec (maillist-nntp-source-spec source))
        (ids (delq nil (delete-dups (copy-sequence mids)))))
    (cond
     ((null spec)
      (funcall callback (list :error "该源未配置 NNTP")))
     ((null ids)
      (funcall callback (list :ok nil)))
     (t
      (let ((collected nil)
            (batch-size (max 1 maillist-nntp-pipeline-size)))
        (cl-labels
            ((next-batch (remaining)
               (if (null remaining)
                   (funcall callback (list :ok (nreverse collected)))
                 (let* ((chunk (seq-take remaining batch-size))
                        (rest (seq-drop remaining batch-size))
                        (cmds (mapcar (lambda (id) (format "ARTICLE <%s>" id)) chunk)))
                   (maillist-nntp--send
                    spec cmds
                    (lambda (res)
                      (if-let* ((err (plist-get res :error)))
                          (funcall callback (list :error err))
                        (cl-mapc
                         (lambda (id resp)
                           (when (and (equal (plist-get resp :code) "220")
                                      (stringp (plist-get resp :body)))
                             (push (maillist-nntp-parse-article
                                    (plist-get resp :body) id)
                                   collected)))
                         chunk (plist-get res :ok))
                        (next-batch rest)))
                    priority)))))
          (next-batch ids)))))))

(defun maillist-nntp-fetch-raw (source id callback &optional priority)
  "Fetch raw RFC 5322 text of message ID from SOURCE over NNTP.
CALLBACK receives (:ok TEXT) or (:error MSG)."
  (let ((spec (maillist-nntp-source-spec source)))
    (if (null spec)
        (funcall callback (list :error "该源未配置 NNTP"))
      (maillist-nntp--send
       spec (list (format "ARTICLE <%s>" id))
       (lambda (res)
         (if-let* ((err (plist-get res :error)))
             (funcall callback (list :error err))
           (let* ((resp (car (plist-get res :ok)))
                  (body (plist-get resp :body)))
             (if (and (equal (plist-get resp :code) "220") (stringp body))
                 (let* ((decoded (if (multibyte-string-p body)
                                     body
                                   (decode-coding-string body 'utf-8)))
                        (clean (replace-regexp-in-string "\r\n" "\n" decoded t t)))
                   (funcall callback (list :ok clean)))
               (funcall callback
                        (list :error (format "NNTP 找不到邮件：%s"
                                             (plist-get resp :status))))))))
       priority))))

(provide 'maillist-nntp)
;;; maillist-nntp.el ends here
