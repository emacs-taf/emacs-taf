;;; maillist-service.el --- Mailing-list archives backend for maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; One source is a public-inbox archive: an index page listing threads and a
;; per-thread Atom document carrying every message.  Any archive that serves
;; those endpoints works unchanged; a new list is a new source plist, not new
;; code.  A source is (:name NAME :base URL :address LIST-ADDRESS) with optional
;; `:index' (file name for a local mirror) and `:reply-style' (`debbugs' for
;; GNU bug lists where replies address `<bug>@debbugs.gnu.org').
;;
;; Every request is asynchronous: CALLBACK receives (:ok VALUE) on success and
;; (:error MESSAGE) otherwise.  Parsing is pure and testable from a string, so
;; the network is never needed to verify the mapping.  HTTP responses are
;; decoded according to their declared charset (defaulting to UTF-8) before
;; parsing, and Message-IDs are kept in canonical unescaped form internally and
;; percent-encoded once when building archive URLs.
;;
;; A parsed thread row is (:id :subject :date :count :depth); `:date' is an
;; ISO-8601 UTC stamp so it sorts and caches as text.  A parsed thread is
;; (:id :subject :messages :participants), each message
;; (:id :author :email :date :parent :depth :subject :text) where `:text' is
;; the raw body.  `maillist-classify-lines' turns a body into display lines.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'url-util)
(require 'xml)
(require 'mm-util)
(require 'mail-parse)
(require 'rfc2047)

(declare-function libxml-available-p "xml.c" ())
(declare-function libxml-parse-xml-region "xml.c"
                  (start end &optional base-url discard-comments))

(defgroup maillist nil
  "Mailing-list archive client."
  :group 'applications)

(defcustom maillist-sources
  '((:name "emacs-devel"
     :base "https://yhetil.org/emacs-devel/"
     :address "emacs-devel@gnu.org"
     :nntp (:host "news.yhetil.org" :port 119 :group "yhetil.emacs.devel"))
    (:name "emacs-user"
     :base "https://yhetil.org/emacs-user/"
     :address "help-gnu-emacs@gnu.org"
     :nntp (:host "news.yhetil.org" :port 119 :group "yhetil.emacs.user"))
    (:name "emacs-bugs"
     :base "https://yhetil.org/emacs-bugs/"
     :address "bug-gnu-emacs@gnu.org"
     :reply-style debbugs
     :nntp (:host "news.yhetil.org" :port 119 :group "yhetil.emacs.bugs"))
    (:name "emacs-tangents"
     :base "https://yhetil.org/emacs-tangents/"
     :address "emacs-tangents@gnu.org"
     :nntp (:host "news.yhetil.org" :port 119 :group "yhetil.emacs.tangents")))
  "Archives this client can open.
A source is (:name NAME :base URL :address LIST-ADDRESS); optional `:index'
names a file the archive serves instead of its directory URL, which a local
mirror needs, optional `:reply-style' (`debbugs') directs replies to the bug
address parsed from the subject instead of the new-bug address, and optional
`:nntp' (`(:host HOST :port PORT :group GROUP)') enables persistent NNTP sync."
  :type '(repeat (plist :key-type symbol :value-type sexp))
  :group 'maillist)

(defconst maillist-default-source (car maillist-sources)
  "Archive opened by a new client.")

(defun maillist-source (name)
  "Return the source description named NAME.
NAME defaults to the first known archive; an unknown name is an error."
  (or (cl-find (or name (plist-get (car maillist-sources) :name)
                   (plist-get maillist-default-source :name))
               maillist-sources
               :key (lambda (source) (plist-get source :name))
               :test #'equal)
      (user-error "未知邮件列表：%s" name)))

;;; ---------------------------------------------------------------------------
;;; Message-ID encoding
;;; ---------------------------------------------------------------------------

(defconst maillist--path-id-chars
  (append url-unreserved-chars '(?@ ?= ?! ?$ ?& ?* ?, ?\; ?:))
  "Characters kept literal inside a public-inbox Message-ID URL path segment.
Characters like `+', `%', `/', `?', `#' and spaces are percent-encoded once,
while `@', `.', `-', `_' and `=' stay readable and work on `file:' mirrors.")

(defun maillist--decode-id (segment)
  "Return URL path SEGMENT decoded to a canonical Message-ID string, or nil."
  (when (and (stringp segment) (not (string-empty-p segment)))
    (let ((raw (url-unhex-string segment)))
      (if (multibyte-string-p raw)
          raw
        (decode-coding-string raw 'utf-8)))))

(defun maillist--encode-path-id (id)
  "Return canonical Message-ID ID percent-encoded for a URL path segment."
  (url-hexify-string (or id "") maillist--path-id-chars))

;;; ---------------------------------------------------------------------------
;;; Dates
;;; ---------------------------------------------------------------------------

(defvar maillist--day-cache nil
  "Cached (MINUTE TODAY YESTERDAY YEAR WEEK-AGO) for fast date labels.")

(defvar maillist--time-label-cache (cons nil (make-hash-table :test #'equal))
  "Per-minute cache (MINUTE . HASH-TABLE) mapping stamp strings to list labels.")

(defun maillist--calendar-today ()
  "Return cached (TODAY YESTERDAY YEAR WEEK-AGO) strings, refreshed per minute."
  (let ((minute (floor (/ (float-time) 60))))
    (if (eql minute (car-safe maillist--day-cache))
        (cdr maillist--day-cache)
      (let ((vals (list (format-time-string "%Y-%m-%d")
                        (format-time-string "%Y-%m-%d" (time-subtract nil 86400))
                        (format-time-string "%Y")
                        (format-time-string "%Y-%m-%d"
                                            (time-subtract nil (* 7 86400))))))
        (setq maillist--day-cache (cons minute vals))
        vals))))

(defun maillist--time-value (stamp)
  "Return STAMP parsed as a time value, or nil when it is not a timestamp."
  (when (stringp stamp)
    (ignore-errors (date-to-time stamp))))

(defun maillist-time-label (stamp)
  "Return the list label of STAMP: a clock today, a date before that.
Dates from earlier calendar years carry the year (`YY-MM') so old archive
threads are not confused with this year's mail."
  (if (not (stringp stamp))
      ""
    (let ((minute (floor (/ (float-time) 60))))
      (unless (eql minute (car maillist--time-label-cache))
        (setq maillist--time-label-cache
              (cons minute (make-hash-table :test #'equal))))
      (let ((table (cdr maillist--time-label-cache)))
        (or (gethash stamp table)
            (let ((label
                   (if-let* ((time (maillist--time-value stamp)))
                       (pcase-let* ((`(,today ,yesterday ,year ,_week)
                                     (maillist--calendar-today))
                                    (day (format-time-string "%Y-%m-%d" time)))
                         (cond
                          ((equal day today) (format-time-string "%H:%M" time))
                          ((equal day yesterday) "昨天")
                          ((string-prefix-p year day) (substring day 5 10))
                          (t (format-time-string "%y-%m" time))))
                     "")))
              (puthash stamp label table)
              label))))))

(defun maillist-day-label (stamp)
  "Return the group label of STAMP: today, yesterday, this week or older."
  (if-let* ((time (maillist--time-value stamp)))
      (pcase-let* ((`(,today ,yesterday ,_year ,week-ago) (maillist--calendar-today))
                   (day (format-time-string "%Y-%m-%d" time)))
        (cond
         ((equal day today) "今天")
         ((equal day yesterday) "昨天")
         ((string> day week-ago) "本周")
         (t "更早")))
    "更早"))

(defun maillist-long-label (stamp)
  "Return STAMP as a readable date for the reader header."
  (if-let* ((time (maillist--time-value stamp)))
      (format-time-string "%Y-%m-%d %H:%M" time)
    ""))

;;; ---------------------------------------------------------------------------
;;; Thread index
;;; ---------------------------------------------------------------------------

(defun maillist-decode-entities (text)
  "Return TEXT with the HTML entities a public-inbox page emits."
  (let ((text (or text "")))
    (setq text
          (replace-regexp-in-string
           "&#[xX]\\([0-9a-fA-F]+\\);\\|&#\\([0-9]+\\);"
           (lambda (match)
             (save-match-data
               (let* ((hex (when (string-match "\\`&#[xX]\\([0-9a-fA-F]+\\);\\'" match)
                             (string-to-number (match-string 1 match) 16)))
                      (dec (when (and (null hex)
                                      (string-match "\\`&#\\([0-9]+\\);\\'" match))
                             (string-to-number (match-string 1 match) 10)))
                      (code (or hex dec)))
                 (if (and code (characterp code))
                     (char-to-string code)
                   match))))
           text t t))
    (setq text (replace-regexp-in-string "&quot;" "\"" text t t))
    (setq text (replace-regexp-in-string "&apos;" "'" text t t))
    (setq text (replace-regexp-in-string "&nbsp;" " " text t t))
    (setq text (replace-regexp-in-string "&lt;" "<" text t t))
    (setq text (replace-regexp-in-string "&gt;" ">" text t t))
    (replace-regexp-in-string "&amp;" "&" text t t)))

(defconst maillist--index-link
  "<a[ \t\r\n]+href=\"\\([^\"]+\\)/T/#[tu]\"\\(?:[^>]*\\)>"
  "Start of one thread entry in a public-inbox index page.")

(defun maillist--index-count (text)
  "Return the message count reported in TEXT, or nil."
  (when (string-match "\\([0-9]+\\)\\(?:\\+\\)? message" text)
    (string-to-number (match-string 1 text))))

(defun maillist--index-stamp (text)
  "Return the ISO-8601 UTC timestamp reported in TEXT, or nil."
  (when (string-match (concat "\\([0-9]\\{4\\}\\)-\\([0-9][0-9]\\)-\\([0-9][0-9]\\)"
                              "[ ]+\\([0-9][0-9]?\\):\\([0-9][0-9]\\)")
                      text)
    (format "%s-%s-%sT%02d:%s:00Z"
            (match-string 1 text) (match-string 2 text) (match-string 3 text)
            (string-to-number (match-string 4 text)) (match-string 5 text))))

(defun maillist--index-meta (start)
  "Return the metadata text that follows an entry beginning at START."
  (save-excursion
    (goto-char start)
    (let ((tail-end (line-end-position))
          (next-end (progn (forward-line 1) (line-end-position))))
      (concat (buffer-substring-no-properties start tail-end) " "
              (buffer-substring-no-properties (line-beginning-position) next-end)))))

(defun maillist-parse-index (html)
  "Parse a public-inbox index page HTML into thread rows.
Each row carries `:id', `:subject', `:date', `:count' and `:depth', newest
first.  A buried sub-thread is marked with `:depth' 1 and keeps the archive's
own subject."
  (let ((rows '()) (seen (make-hash-table :test #'equal)) (last-date nil))
    (with-temp-buffer
      (insert (or html ""))
      (goto-char (point-min))
      (while (re-search-forward maillist--index-link nil t)
        (let* ((href (match-string 1))
               (prefix (save-excursion
                         (goto-char (match-beginning 0))
                         (buffer-substring-no-properties
                          (line-beginning-position) (point))))
               (subject-start (point))
               (subject-end (or (and (search-forward "</a>" nil t)
                                     (match-beginning 0))
                                (point-max)))
               (subject (maillist-decode-entities
                         (string-trim
                          (buffer-substring-no-properties subject-start subject-end))))
               (meta (maillist--index-meta subject-end))
               (id (maillist--decode-id
                    (file-name-nondirectory (directory-file-name href))))
               (depth (if (string-match-p "`" prefix) 1 0))
               (date (maillist--index-stamp meta)))
          (when (and id (not (gethash id seen)))
            (puthash id t seen)
            (setq last-date (or date last-date))
            (push (list :id id
                        :subject subject
                        :date (or date last-date)
                        :count (maillist--index-count meta)
                        :depth depth)
                  rows)))))
    (nreverse rows)))

(defun maillist--parse-index-next (html)
  "Return the next-page query string (`?t=...') from index HTML, or nil.
Public-inbox index pages end with a `next (older)' link carrying `?t=...'
which pages through threads without hitting search's per-day cap."
  (when (and (stringp html)
             (let ((case-fold-search t))
               (string-match
                "<a[ \t\r\n]+\\(?:[^>]*?[ \t\r\n]\\)?href=\"\\(\\?t=[^\"]+\\)\"[^>]*>[ \t\r\n]*next"
                html)))
    (maillist-decode-entities (match-string 1 html))))

;;; ---------------------------------------------------------------------------
;;; Search results
;;; ---------------------------------------------------------------------------

(defconst maillist--search-row
  (concat "<b><a[ \t\n]*href=\"\\([^\"]+\\)\"[^>]*>\\([^<]*\\)</a></b>"
          "\\([ \t\n]*- by \\([^\n]*?\\) @ \\([0-9][0-9-]* [0-9][0-9:]* UTC\\)\\)?")
  "One result of a public-inbox search page.
The page lists messages, each as a permalink plus a `- by AUTHOR @ DATE UTC'
line; the index page lists threads and looks nothing like it.")

(defun maillist--search-stamp (stamp)
  "Return STAMP of a search result as an ISO-8601 UTC timestamp, or nil."
  (when (and (stringp stamp)
             (string-match
              "\\`\\([0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\) \\([0-9][0-9]:[0-9][0-9]\\) UTC"
              stamp))
    (format "%sT%s:00Z" (match-string 1 stamp) (match-string 2 stamp))))

(defun maillist-parse-search (html)
  "Parse a public-inbox search page HTML into message rows.
Each row carries `:id', `:subject', `:date' and `:author', newest first; the
archive answers a query with the messages that matched, not with threads, so a
row carries no `:count' or `:depth'.  Opening a row asks the archive for that
message's thread, which public-inbox serves from any message of it."
  (let ((rows '()) (seen (make-hash-table :test #'equal)))
    (with-temp-buffer
      (insert (or html ""))
      (goto-char (point-min))
      (while (re-search-forward maillist--search-row nil t)
        (let* ((id (maillist--decode-id
                    (file-name-nondirectory
                     (directory-file-name (match-string 1)))))
               (subject (maillist-decode-entities
                         (string-trim (match-string 2))))
               (author (maillist-decode-entities
                        (string-trim (or (match-string 4) ""))))
               (date (maillist--search-stamp (match-string 5))))
          (unless (or (null id) (string-empty-p id) (string-empty-p subject)
                      (gethash id seen))
            (puthash id t seen)
            (push (list :id id :subject subject :date date :author author)
                  rows)))))
    (nreverse rows)))

(defun maillist--search-page-p (html)
  "Return non-nil when HTML looks like a genuine public-inbox search page.
An anti-bot challenge or error page served with HTTP 200 has neither rows nor
the archive's search form; distinguishing it lets search fall back to the local
cache instead of reporting an empty result."
  (and (stringp html)
       (let ((case-fold-search t))
         (or (string-match-p "search results" html)
             (string-match-p "name=[\"']?q[\"']?" html)
             (string-match-p "no results found" html)
             (string-match-p "action=\"\\./\"" html)))))

;;; ---------------------------------------------------------------------------
;;; Thread Atom
;;; ---------------------------------------------------------------------------

(defun maillist--parse-xml (xml-text)
  "Parse XML-TEXT once and return its root XML node, or nil on failure.
Uses Emacs's C `libxml-parse-xml-region' when available for large threads and
falls back to pure-Elisp `xml-parse-region'."
  (when (and (stringp xml-text) (not (string-empty-p (string-trim xml-text))))
    (with-temp-buffer
      (insert xml-text)
      (condition-case nil
          (if (and (fboundp 'libxml-available-p) (libxml-available-p))
              (libxml-parse-xml-region (point-min) (point-max))
            (car (xml-parse-region (point-min) (point-max))))
        (error nil)))))

(defun maillist--plain (node)
  "Return the text content of XML NODE."
  (cond ((stringp node) node)
        ((consp node)
         (mapconcat #'maillist--plain (cddr node) ""))
        (t "")))

(defun maillist--node (name node)
  "Return the first child of NODE whose tag is NAME."
  (car (xml-get-children node name)))

(defun maillist--attribute (node name)
  "Return NAME attribute of XML NODE as a string, or nil."
  (let ((value (xml-get-attribute-or-nil node name)))
    (and (stringp value) value)))

(defun maillist--message-id (href)
  "Return the canonical message id named by HREF, or nil."
  (when (and (stringp href) (not (string-empty-p href)))
    (maillist--decode-id
     (file-name-nondirectory (directory-file-name href)))))

(defun maillist--entry-parent (entry)
  "Return the parent message id referenced by Atom ENTRY, or nil.
`libxml-parse-xml-region' strips XML namespace prefixes (`in-reply-to') while
`xml-parse-region' keeps them (`thr:in-reply-to')."
  (let ((reply (or (car (xml-get-children entry 'in-reply-to))
                   (car (xml-get-children entry 'thr:in-reply-to)))))
    (maillist--message-id (maillist--attribute reply 'href))))

(defun maillist--trim-url (url)
  "Return URL with trailing sentence punctuation removed.
Balanced closing parentheses, brackets and braces inside URL are kept so links
such as Wikipedia articles stay intact."
  (let ((result url)
        (trimmed t))
    (while trimmed
      (setq trimmed nil)
      (let ((len (length result)))
        (when (> len 0)
          (let ((last (aref result (1- len))))
            (cond
             ((memq last '(?. ?, ?\; ?: ?! ??))
              (setq result (substring result 0 (1- len))
                    trimmed t))
             ((memq last '(?\) ?\] ?\}))
              (let* ((open (pcase last (?\) ?\() (?\] ?\[) (?\} ?\{)))
                     (opens (cl-count open result))
                     (closes (cl-count last result)))
                (when (> closes opens)
                  (setq result (substring result 0 (1- len))
                        trimmed t)))))))))
    result))

(defun maillist-message-links (text &optional include-quotes)
  "Return the web addresses a reader can act on from message TEXT.
Trailing sentence punctuation is trimmed while balanced parentheses inside a
URL stay intact.  Quoted lines (`> ...') are skipped unless INCLUDE-QUOTES is
non-nil so replies do not repeat every link from earlier messages.  The result
keeps the order the message mentions them, without repeats."
  (let ((links '()))
    (dolist (line (split-string (or text "") "\n"))
      (when (or include-quotes
                (not (string-match-p "\\`[ \t]*>" line)))
        (let ((start 0))
          (while (string-match "https?://[^ \t\n\r\"'`<>|]+" line start)
            (let ((link (maillist--trim-url (match-string 0 line))))
              (setq start (match-end 0))
              (when (and (> (length link) 8) (not (member link links)))
                (push link links)))))))
    (nreverse links)))

(defun maillist--quote-depth (line)
  "Return the number of leading `>' quote markers in LINE, or 0."
  (if (string-match "\\`[ \t]*\\([>][> \t]*\\)" line)
      (cl-count ?> (match-string 1 line))
    0))

(defun maillist--hunk-continuation-p (lines index)
  "Return non-nil when LINES after blank line at INDEX continue a diff hunk."
  (let ((next (nth (1+ index) lines)))
    (and next
         (not (equal next "-- "))
         (or (string-prefix-p " " next)
             (string-prefix-p "+" next)
             (string-prefix-p "-" next)
             (string-prefix-p "@@ " next)))))

(defun maillist-classify-lines (text &optional prefix)
  "Split message TEXT into (:id :kind :text ...) lines.
PREFIX names the message so every line keeps a stable key.  KIND is `body',
`blank', `quote' (with `:quote-depth'), `signature', `patch-meta', `patch-add'
or `patch-del'."
  (let* ((raw-lines (split-string (or text "") "\n"))
         (in-hunk nil)
         (in-sig nil)
         (index 0)
         (out nil))
    (dolist (line raw-lines)
      (let* ((qdepth (unless in-sig (maillist--quote-depth line)))
             (kind
              (cond
               ((equal line "-- ")
                (setq in-hunk nil in-sig t)
                "signature")
               (in-sig
                (if (string-empty-p (string-trim line)) "blank" "signature"))
               ((and qdepth (> qdepth 0))
                (setq in-hunk nil)
                "quote")
               ((or (string-match-p "\\`@@ .*@@" line)
                    (string-prefix-p "diff --git " line)
                    (string-match-p "\\`index [0-9a-f]+\\.\\.[0-9a-f]+" line)
                    (string-match-p "\\`--- [ab]/" line)
                    (string-match-p "\\`\\+\\+\\+ [ab]/" line))
                (when (string-match-p "\\`@@ .*@@" line)
                  (setq in-hunk t))
                "patch-meta")
               ((and in-hunk (string-prefix-p "+" line)) "patch-add")
               ((and in-hunk (string-prefix-p "-" line)) "patch-del")
               ((string-empty-p (string-trim line))
                (unless (maillist--hunk-continuation-p raw-lines index)
                  (setq in-hunk nil))
                "blank")
               (t
                (unless (string-prefix-p " " line) (setq in-hunk nil))
                "body")))
             (entry (list :id (format "%s-%d" (or prefix "") index)
                          :kind kind
                          :text (if (equal kind "blank") "" line))))
        (when (equal kind "quote")
          (setq entry (append entry (list :quote-depth qdepth))))
        (push entry out)
        (cl-incf index)))
    (nreverse out)))

(defun maillist--compute-depths (messages)
  "Fill `:depth' on every message of MESSAGES from its `:parent' chain.
A second pass resolves depths even when a reply appears before its parent in
the feed, while a visited table guards against broken cyclic references."
  (let ((parent-of (make-hash-table :test #'equal))
        (memo (make-hash-table :test #'equal)))
    (dolist (message messages)
      (let ((id (plist-get message :id))
            (parent (plist-get message :parent)))
        (when (and id (not (string-empty-p id)) parent)
          (puthash id parent parent-of))))
    (cl-labels
        ((depth-of (id seen)
           (cond
            ((or (null id) (string-empty-p id)) 0)
            ((gethash id memo))
            ((member id seen) 0)
            (t
             (let* ((parent (gethash id parent-of))
                    (d (if parent
                           (1+ (depth-of parent (cons id seen)))
                         0)))
               (puthash id d memo)
               d)))))
      (dolist (message messages)
        (plist-put message :depth (depth-of (plist-get message :id) nil)))))
  messages)

(defun maillist-parse-thread (xml-text &optional fallback-subject)
  "Parse a public-inbox thread Atom document XML-TEXT into a thread plist.
FALLBACK-SUBJECT names the thread when the feed does not.  The result carries
`:id', `:subject', `:participants' and `:messages'; each message keeps its
raw `:text' so it can be cached and classified again on load."
  (let* ((doc (maillist--parse-xml xml-text))
         (entries (and doc (xml-get-children doc 'entry)))
         (senders (make-hash-table :test #'equal))
         (messages
          (mapcar
           (lambda (entry)
             (let* ((link (maillist--attribute (car (xml-get-children entry 'link)) 'href))
                    (author (maillist--node 'author entry))
                    (content (maillist--node 'content entry))
                    (pre (car (xml-get-children
                               (car (xml-get-children content 'div)) 'pre)))
                    (id (or (maillist--message-id link) ""))
                    (name (string-trim (maillist--plain (maillist--node 'name author)))))
               (unless (string-empty-p name)
                 (puthash name t senders))
               (list :id id
                     :author name
                     :email (string-trim (maillist--plain (maillist--node 'email author)))
                     :date (maillist--plain (maillist--node 'updated entry))
                     :parent (maillist--entry-parent entry)
                     :depth 0
                     :subject (string-trim (maillist--plain (maillist--node 'title entry)))
                     :text (string-trim (maillist--plain pre) "\n" "\n"))))
           entries))
         (title (if doc
                    (string-trim (maillist--plain (maillist--node 'title doc)))
                  "")))
    (unless messages
      (error "档案没有返回这个线程的邮件（可能暂时不可用，按 g 重试）"))
    (maillist--compute-depths messages)
    (list :id (or (plist-get (car messages) :id) "")
          :subject (if (string-empty-p title)
                       (or fallback-subject
                           (plist-get (car messages) :subject)
                           "")
                     title)
          :participants (hash-table-count senders)
          :messages messages)))

(defun maillist-parse-recent (xml-text)
  "Parse a public-inbox new-messages feed XML-TEXT into (MESSAGE-ID . AUTHOR).
The feed names the sender of the newest messages only, which is enough to fill
the author column before a thread is opened."
  (let* ((doc (maillist--parse-xml xml-text))
         (entries (and doc (xml-get-children doc 'entry)))
         (hints '()))
    (dolist (entry entries (nreverse hints))
      (let* ((link (maillist--attribute
                    (car (xml-get-children entry 'link)) 'href))
             (id (maillist--message-id link))
             (author (string-trim
                      (maillist--plain
                       (maillist--node 'name (maillist--node 'author entry))))))
        (when (and id (not (string-empty-p author)))
          (push (cons id author) hints))))))

(defun maillist--parse-recent-messages (xml-text)
  "Parse `new.atom' XML-TEXT into full message plists, or nil when empty."
  (when-let* ((thread (ignore-errors (maillist-parse-thread xml-text))))
    (plist-get thread :messages)))

(defun maillist-parse-author (text)
  "Return the sender display name of the raw message TEXT, or nil.
The archive's index carries no sender, but one raw message is small enough to
fill the list's author column; folded and RFC 2047 encoded names are unfolded
and decoded."
  (with-temp-buffer
    (insert (or text ""))
    (goto-char (point-min))
    (when (looking-at "From ")
      (forward-line 1))
    (let ((case-fold-search t) from)
      (when (re-search-forward "^From:[ \t]*" nil t)
        (let ((start (point)))
          (end-of-line)
          (while (looking-at "\n[ \t]")
            (forward-line 1)
            (end-of-line))
          (setq from (buffer-substring-no-properties start (point)))))
      (when from
        (setq from (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " from)))
        (setq from (ignore-errors (rfc2047-decode-string from)))
        (when (and from (not (string-empty-p from)))
          (let* ((parsed (ignore-errors (mail-header-parse-address from)))
                 (first (car parsed))
                 (second (cdr parsed)))
            (cond
             ((null parsed) from)
             ;; Releases disagree on the pair's order, so the component with
             ;; an @ is the address and the other one is the display name.
             ((and first (string-match-p "@" first))
              (if (and second (not (string-empty-p second))) second from))
             ((and second (string-match-p "@" second))
              (if (and first (not (string-empty-p first))) first from))
             (t (or first from)))))))))

;;; ---------------------------------------------------------------------------
;;; Transport
;;; ---------------------------------------------------------------------------

(defun maillist--url (source path)
  "Return the URL of PATH inside SOURCE."
  (concat (plist-get source :base) path))

(defconst maillist-request-timeout 45
  "Seconds after which a stalled archive request is abandoned.")

(defcustom maillist-route-attempt-timeout 10
  "Seconds the leading route may stall before the other one answers.
A host that drops the connection instead of refusing it would otherwise hold
the request until `maillist-request-timeout' and never reach the other route."
  :type 'number
  :group 'maillist)

(defcustom maillist-proxy nil
  "Proxy address used for archive requests, as HOST:PORT.
Empty means the request takes the proxy from `url-proxy-services' or from the
environment."
  :type '(choice (const :tag "Not set" nil) string)
  :group 'maillist)

(defcustom maillist-network-route 'auto
  "How archive requests reach the network.
`auto' tries a direct connection first and the proxy after it, `proxy' tries
the proxy first and the direct connection after it, and `direct' never uses a
proxy.  Whichever route leads, a connection that cannot be made or stops
answering moves on to the other one: a proxy endpoint that is not running does
not take the client offline, and a blocked direct path still reaches the
archive.  The proxy is `maillist-proxy' when set, otherwise the one named by
`url-proxy-services' or the environment."
  :type '(choice (const :tag "Direct, then the proxy" auto)
                 (const :tag "The proxy, then direct" proxy)
                 (const :tag "Direct only" direct))
  :group 'maillist)

(defun maillist--configured-proxy ()
  "Return proxy services of `maillist-proxy', or nil."
  (let ((value (string-trim (or maillist-proxy ""))))
    (unless (string-empty-p value)
      (let ((host (string-trim
                   (replace-regexp-in-string "\\`https?://" "" value) "/")))
        (when (string-match-p ":" host)
          (list (cons "https" host) (cons "http" host)))))))

(defun maillist--http-proxy-value (value)
  "Return HOST:PORT when VALUE names an HTTP(S) proxy, or nil for SOCKS/empty.
`url.el' speaks HTTP CONNECT proxies only, so feeding it a `socks5://' address
from `ALL_PROXY' would only fail."
  (when (and (stringp value) (not (string-empty-p (string-trim value))))
    (let ((trimmed (string-trim value)))
      (unless (let ((case-fold-search t))
                (string-match-p "\\`socks" trimmed))
        (let ((host (string-trim
                     (replace-regexp-in-string "\\`https?://" "" trimmed) "/")))
          (when (string-match-p ":" host) host))))))

(defun maillist--env-proxy-services ()
  "Return proxy services built from the environment, or nil.
The client decides its own route instead of inheriting whichever hosts the
environment tells url.el to send around a proxy."
  (when-let* ((host (cl-some #'maillist--http-proxy-value
                             (list (getenv "HTTPS_PROXY") (getenv "https_proxy")
                                   (getenv "HTTP_PROXY") (getenv "http_proxy")
                                   (getenv "ALL_PROXY") (getenv "all_proxy")))))
    (list (cons "https" host) (cons "http" host))))

(defconst maillist--no-bypass (cons "no_proxy" "\\`\\'")
  "Bypass entry that matches no host.
url.el builds a bypass from the environment's NO_PROXY the first time a
request runs, so an explicit proxy attempt carries its own entry, which both
shadows an inherited bypass and keeps url.el from adding one.")

(defun maillist--url-proxy-entries ()
  "Return `url-proxy-services' when it actually configures an HTTP(S) proxy."
  (when (and (bound-and-true-p url-proxy-services)
             (consp url-proxy-services)
             (or (assoc "https" url-proxy-services)
                 (assoc "http" url-proxy-services)))
    url-proxy-services))

(defun maillist--proxy-services ()
  "Return the proxy services of a proxy attempt, or nil."
  (when-let* ((services
               (or (maillist--configured-proxy)
                   (maillist--url-proxy-entries)
                   (maillist--env-proxy-services))))
    (cons maillist--no-bypass services)))

(defvar maillist--route-health (make-hash-table :test #'equal)
  "Cache of the last working network route per (CHOICE PROXY HOST).")

(defconst maillist--route-health-ttl 300
  "Seconds a learned working network route leads before re-probing.")

(defun maillist--route-cache-key (url choice proxy)
  "Return route-health cache key for URL, CHOICE and PROXY services."
  (let ((host (ignore-errors (url-host (url-generic-parse-url (or url "")))))
        (proxy-addr (or (cdr (assoc "https" proxy)) (cdr (assoc "http" proxy)))))
    (list choice proxy-addr host)))

(defun maillist--route-list (url &optional route)
  "Return the network routes to try for URL, in order.
ROUTE is `direct', `proxy' or nil, which means `maillist-network-route'.  The
configured route leads and the other one follows, because an archive reachable
one way must not stay unreachable while the endpoint of the other way is down.
When a recent request proved the fallback route healthy, that route leads for
`maillist--route-health-ttl' seconds so every request does not stall against a
dead endpoint.  `direct' alone is one route, and a `file:' archive never uses
a proxy."
  (let ((choice (or route maillist-network-route))
        (proxy (maillist--proxy-services)))
    (if (string-prefix-p "file:" (or url ""))
        '(direct)
      (let ((base (pcase choice
                    ('direct '(direct))
                    ('proxy (if proxy '(proxy direct) '(direct)))
                    (_ (if proxy '(direct proxy) '(direct))))))
        (if (and (null route) (cdr base))
            (let* ((key (maillist--route-cache-key url choice proxy))
                   (entry (gethash key maillist--route-health))
                   (winner (and entry (< (float-time) (cdr entry)) (car entry))))
              (if (and winner (memq winner base))
                  (cons winner (delq winner (copy-sequence base)))
                base))
          base)))))

(defun maillist--route-label (route)
  "Return ROUTE as the noun a failure message names."
  (if (eq route 'proxy) "代理" "档案"))

(defun maillist--failure-text (failure code route)
  "Return FAILURE of ROUTE as one sentence the reader can act on.
FAILURE is url.el's error value and CODE the status it reported; either may be
nil.  Both of url.el's own shapes are property lists, which
`error-message-string' renders as a `peculiar error' naming the properties
instead of what the reader needs to know."
  (let* ((endpoint (and (consp failure)
                        (eq 'connection-failed (nth 1 failure))
                        (nthcdr 3 failure)))
         (host (plist-get endpoint :host))
         (status (and (consp failure) (eq 'http (nth 1 failure))
                      (nth 2 failure))))
    (cond
     ((stringp host)
      (format "无法连接%s %s:%s" (maillist--route-label route) host
              (plist-get endpoint :service)))
     (status (format "档案返回 HTTP %s" status))
     (failure (error-message-string failure))
     (t (format "档案返回 HTTP %s" code)))))

(defun maillist--kill-buffer (buffer)
  "Kill BUFFER without asking whether its running request may be stopped."
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun maillist--response-coding (headers)
  "Return the coding system declared in HTTP HEADERS, defaulting to `utf-8'."
  (let ((charset
         (and (stringp headers)
              (let ((case-fold-search t))
                (when (string-match
                       "^Content-Type:[^\r\n]*charset=[\"']?\\([^\"'; \t\r\n]+\\)"
                       headers)
                  (match-string 1 headers))))))
    (or (and charset
             (let ((cs (ignore-errors (mm-charset-to-coding-system charset))))
               (and (coding-system-p cs) cs)))
        'utf-8)))

(defun maillist--response-body ()
  "Return the decoded response body of the current url buffer.
HTTP responses arrive from `url-retrieve' as unibyte octets; decode them using
the declared charset (or UTF-8) and normalize CRLF so non-ASCII subjects,
names and bodies never turn into mojibake."
  (goto-char (point-min))
  (let* ((has-headers (re-search-forward "\r?\n\r?\n" nil t))
         (headers (and has-headers
                       (buffer-substring-no-properties (point-min) (match-beginning 0))))
         (raw (buffer-substring-no-properties
               (if has-headers (point) (point-min))
               (point-max)))
         (decoded (if (multibyte-string-p raw)
                      raw
                    (decode-coding-string raw (maillist--response-coding headers)))))
    (replace-regexp-in-string "\r\n" "\n" decoded t t)))

(defun maillist--request (url callback &optional route)
  "Fetch URL asynchronously and call CALLBACK with (:body TEXT) or (:error MSG).
Only the first completion is delivered: a timeout or a killed buffer after
the response never calls CALLBACK twice.  ROUTE is `direct', `proxy' or nil,
which means the configured route; the routes `maillist--route-list' returns
for it are tried in order."
  (let* ((routes (maillist--route-list url route))
         (cache-key (and (null route) (cdr routes)
                         (maillist--route-cache-key
                          url maillist-network-route (maillist--proxy-services)))))
    (maillist--attempt url callback routes nil cache-key)))

(defun maillist--attempt (url callback routes failures &optional cache-key)
  "Fetch URL through the first of ROUTES and hand the result to CALLBACK.
FAILURES holds the text of the routes that already failed, so the last answer
names every endpoint that did not answer.  CACHE-KEY, when non-nil, records
the winning route in `maillist--route-health'.  `url-http-attempt-keepalives'
is disabled per request so reverse proxies that drop HTTP/1.1 keep-alive
sockets never hang subsequent fetches."
  (let* ((route (car routes))
         (rest (cdr routes))
         (state (list :done nil :timer nil :buffer nil))
         (finish
          (lambda (result)
            (unless (plist-get state :done)
              (plist-put state :done t)
              (when-let* ((timer (plist-get state :timer)))
                (cancel-timer timer))
              (funcall callback result))))
         (again
          (lambda (text)
            (unless (plist-get state :done)
              (plist-put state :done t)
              (when-let* ((timer (plist-get state :timer)))
                (cancel-timer timer))
              (maillist--kill-buffer (plist-get state :buffer))
              (maillist--attempt url callback rest
                                 (append failures (list text)) cache-key))))
         (give-up
          (lambda (text)
            (funcall finish
                     (list :error
                           (string-join (delete-dups (append failures (list text)))
                                        "；")))))
         (url-http-attempt-keepalives nil)
         (url-proxy-services (and (eq route 'proxy) (maillist--proxy-services))))
    (plist-put
     state :buffer
     (condition-case err
         (url-retrieve
          url
          (lambda (status)
            (let ((failure (plist-get status :error))
                  (code (plist-get status :http-code))
                  (body (ignore-errors (maillist--response-body))))
              (maillist--kill-buffer (current-buffer))
              (cond
               ((and (null failure) (or (null code) (equal code 200)))
                (when cache-key
                  (puthash cache-key
                           (cons route (+ (float-time) maillist--route-health-ttl))
                           maillist--route-health))
                (funcall finish (list :body (or body ""))))
               (rest (funcall again (maillist--failure-text failure code route)))
               (t (funcall give-up (maillist--failure-text failure code route))))))
          nil t t)
       (error
        (let ((text (maillist--failure-text err nil route)))
          (if rest
              (funcall again text)
            (funcall give-up text)))
        nil)))
    (when (and (buffer-live-p (plist-get state :buffer))
               (not (plist-get state :done)))
      (plist-put state :timer
                 (run-at-time
                  (if rest maillist-route-attempt-timeout
                    maillist-request-timeout)
                  nil
                  (lambda ()
                    (let ((buffer (plist-get state :buffer)))
                      (if rest
                          (funcall again "连接超时")
                        (funcall give-up "请求超时")
                        (maillist--kill-buffer buffer)))))))))

(defun maillist--on-body (url callback parse)
  "Fetch URL, call PARSE on the body, and pass the result to CALLBACK."
  (maillist--request
   url
   (lambda (result)
     (if (plist-get result :error)
         (funcall callback result)
       (funcall callback
                (condition-case err
                    (list :ok (funcall parse (plist-get result :body)))
                  (error (list :error (error-message-string err)))))))))

(defun maillist--index-url (source &optional cursor)
  "Return the thread-list URL of SOURCE, optionally at pagination CURSOR."
  (if (and cursor (not (string-empty-p cursor)))
      (maillist--url source cursor)
    (maillist--url source (or (plist-get source :index) ""))))

(defun maillist--index-answer (body)
  "Return (:ok (:rows ROWS :next NEXT)) or (:error MSG) for index BODY.
A public-inbox mirror always lists its threads, so a body that carries none is
no index: an empty body after a dropped connection, or a page that is not the
thread index.  Answering (:ok nil) would trade the client's rows for nothing."
  (if-let* ((rows (maillist-parse-index body)))
      (list :ok (list :rows rows :next (maillist--parse-index-next body)))
    (list :error (if (string-empty-p (string-trim (or body "")))
                     "档案返回了空响应"
                   "档案没有返回线程索引"))))

(defun maillist--fetch-index-page (source callback &optional cursor)
  "Fetch SOURCE's index page at CURSOR and call CALLBACK with (:ok (:rows :next))."
  (cl-labels
      ((attempt
        (retry)
        (maillist--request
         (maillist--index-url source cursor)
         (lambda (result)
           (if-let* ((error (plist-get result :error)))
               (funcall callback (list :error error))
             (let ((answer (maillist--index-answer (plist-get result :body))))
               (cond
                ((eq (car answer) :ok) (funcall callback answer))
                (retry (run-at-time 1 nil (lambda () (attempt nil))))
                (t (funcall callback answer)))))))))
    (attempt t)))

(defun maillist-fetch-index (source callback)
  "Fetch SOURCE's thread list and call CALLBACK with (:ok ROWS) or (:error MSG).
An answer carrying no thread row is fetched once more before it becomes an
error: the archive sometimes drops the connection after the status line, and
the retry is what tells a flake from a failure.  A failed answer stays an
error, so the caller keeps the rows it already has."
  (maillist--fetch-index-page
   source
   (lambda (result)
     (if (eq (car result) :ok)
         (funcall callback (list :ok (plist-get (cadr result) :rows)))
       (funcall callback result)))))

(defun maillist-fetch-thread (source id callback &optional subject)
  "Fetch thread ID of SOURCE and call CALLBACK with (:ok THREAD).
SUBJECT names the thread when its feed does not."
  (maillist--on-body
   (maillist--url source (concat (maillist--encode-path-id id) "/t.atom"))
   callback
   (lambda (body) (maillist-parse-thread body subject))))

(defun maillist-thread-subject (subject)
  "Return SUBJECT without the reply prefixes a thread accumulates."
  (let ((case-fold-search t)
        (text (string-trim (or subject ""))))
    (while (string-match "\\`re\\[[0-9]+\\]:[ \t]*\\|\\`re:[ \t]*" text)
      (setq text (string-trim (substring text (match-end 0)))))
    text))

(defun maillist-fetch-subject (source subject callback)
  "Fetch from SOURCE every message whose subject matches SUBJECT.
A merged or truncated thread document can lose the messages the index
announced; the subject feed still answers with them."
  (let ((clean (replace-regexp-in-string "\"" " " (maillist-thread-subject subject))))
    (maillist--on-body
     (maillist--url source
                    (concat "?q="
                            (url-hexify-string (format "s:\"%s\"" clean))
                            "&x=A"))
     callback #'maillist-parse-thread)))

(defun maillist-fetch-message (source id callback)
  "Fetch message ID of SOURCE alone and call CALLBACK with (:ok THREAD).
The search Atom feed answers with one entry, so this is a few kilobytes even
when the whole thread is huge; it lets the newest mail show while the rest
downloads."
  (maillist--on-body
   (maillist--url source
                  (concat "?q=" (url-hexify-string (concat "mid:" id)) "&x=A"))
   callback #'maillist-parse-thread))

(defun maillist-fetch-author (source id callback)
  "Fetch the sender of message ID from SOURCE and call CALLBACK with (:ok AUTHOR)."
  (maillist--on-body
   (maillist--url source (concat (maillist--encode-path-id id) "/raw"))
   callback #'maillist-parse-author))

(defun maillist-fetch-raw (source id callback)
  "Fetch the raw RFC 5322 message ID from SOURCE and pass (:ok TEXT) to CALLBACK."
  (maillist--on-body
   (maillist--url source (concat (maillist--encode-path-id id) "/raw"))
   callback #'identity))

(defun maillist-fetch-recent (source callback)
  "Fetch SOURCE's newest messages and call CALLBACK with (:ok HINTS)."
  (maillist--on-body (maillist--url source "new.atom")
                     callback #'maillist-parse-recent))

(defun maillist--fetch-recent-payload (source callback)
  "Fetch SOURCE's `new.atom' and pass (:ok (:hints H :messages M)) to CALLBACK."
  (maillist--on-body
   (maillist--url source "new.atom")
   callback
   (lambda (body)
     (let ((msgs (maillist--parse-recent-messages body)))
       (list :hints (or (delq nil
                              (mapcar (lambda (m)
                                        (let ((id (plist-get m :id))
                                              (author (plist-get m :author)))
                                          (when (and id (not (string-empty-p (or author ""))))
                                            (cons id author))))
                                      msgs))
                        (maillist-parse-recent body))
             :messages msgs)))))

(defun maillist--search-answer (body)
  "Parse search HTML BODY into rows or signal when BODY is not a search page."
  (let ((rows (maillist-parse-search body)))
    (if (or rows (maillist--search-page-p body))
        rows
      (error "档案没有返回搜索结果页"))))

(defun maillist-fetch-search (source query callback &optional offset)
  "Search SOURCE for QUERY and call CALLBACK with (:ok ROWS).
QUERY is the archive's own syntax, which `maillist-compile-query' builds
from what the reader types; OFFSET requests a later result page (`&o=N').
ROWS are the messages that matched, as `maillist-parse-search' reads them."
  (let ((suffix (if (and (integerp offset) (> offset 0))
                    (format "&o=%d" offset)
                  "")))
    (maillist--on-body
     (maillist--url source (concat "?q=" (url-hexify-string query) suffix))
     callback #'maillist--search-answer)))

;;; ---------------------------------------------------------------------------
;;; Query syntax
;;; ---------------------------------------------------------------------------

(defconst maillist-query-fields
  '(("from" . "f") ("to" . "t") ("subject" . "s") ("body" . "b")
    ("message" . "mid"))
  "Fields this client compiles into the archive's own query prefixes.")

(defun maillist--query-tokens (text)
  "Split TEXT into search tokens, keeping a quoted phrase together.
A token ends at whitespace outside quotes; the quotes stay in the token, so
`maillist--query-term' can decide whether it is a phrase."
  (let ((index 0)
        (length (length text))
        tokens)
    (while (< index length)
      (if (memq (aref text index) '(?\s ?\t ?\n))
          (cl-incf index)
        (let ((start index)
              (quoted nil))
          ;; Consume characters until whitespace outside a quoted phrase.
          (while
              (let ((char (and (< index length) (aref text index))))
                (cond
                 ((null char) nil)
                 ((eq char ?\")
                  (setq quoted (not quoted))
                  (cl-incf index)
                  t)
                 ((and (not quoted) (memq char '(?\s ?\t ?\n))) nil)
                 (t (cl-incf index) t))))
          (push (substring text start index) tokens))))
    (nreverse tokens)))

(defun maillist--query-term (value)
  "Return VALUE as one archive term, quoted when it is a phrase.
The archive's search engine takes a quoted string as a phrase and a bare word
as one term; an empty value contributes nothing."
  (let ((text (string-trim (string-trim value) "\"" "\"")))
    (cond
     ((string-empty-p text) nil)
     ((string-match-p "[ \t\"]" text)
      (format "\"%s\"" (replace-regexp-in-string "\"" "" text)))
     (t text))))

(defun maillist--unquote (value)
  "Return VALUE trimmed of outer whitespace and quotes."
  (string-trim (string-trim (or value "")) "\"" "\""))

(defun maillist--query-date-p (value)
  "Return non-nil when VALUE is an ISO date the archive's range accepts."
  (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\'" value))

(defun maillist-compile-query (text)
  "Compile the reader's search TEXT for a public-inbox archive.
Fields `from:', `to:', `subject:', `body:' and `message:' (optionally negated
with a leading `-') become the archive's own prefixes, `after:' and `before:'
become date ranges, and bare words or quoted phrases stay terms.  `is:unread',
`is:read' and `is:starred' (and their `-is:' negations) are returned as local
filters, because the archive does not know this reader's marks.
Return (:query REMOTE :filters FILTERS :terms TERMS); REMOTE is empty when
TEXT only names local filters, and TERMS carries structured clauses for local
fallback search."
  (let ((remote nil)
        (filters nil)
        (terms nil))
    (dolist (token (maillist--query-tokens (or text "")))
      (let* ((negated (and (> (length token) 1) (eq (aref token 0) ?-)))
             (body (if negated (substring token 1) token))
             (colon (string-match "\\`\\([a-zA-Z]+\\):" body))
             (field (and colon (downcase (match-string 1 body))))
             (value (and colon (substring body (match-end 0))))
             (plain (and value (maillist--unquote value))))
        (cond
         ((and field (equal field "is"))
          (let ((flag (pcase (downcase (or plain ""))
                        ("unread" (if negated 'read 'unread))
                        ("read" (if negated 'unread 'read))
                        ("starred" (if negated 'unstarred 'starred)))))
            (when flag (cl-pushnew flag filters))))
         ((and field (equal field "after") (not negated)
               (maillist--query-date-p (or plain "")))
          (push (format "d:%s.." plain) remote)
          (push (list :field 'after :value plain :negate nil) terms))
         ((and field (equal field "before") (not negated)
               (maillist--query-date-p (or plain "")))
          (push (format "d:..%s" plain) remote)
          (push (list :field 'before :value plain :negate nil) terms))
         ((and field (assoc field maillist-query-fields))
          (when-let* ((term (maillist--query-term value)))
            (push (format "%s%s:%s"
                          (if negated "-" "")
                          (cdr (assoc field maillist-query-fields))
                          term)
                  remote)
            (push (list :field (intern field) :value plain :negate negated) terms)))
         (t
          (when-let* ((term (maillist--query-term (if negated body token))))
            (push (concat (if negated "-" "") term) remote)
            (push (list :field 'any
                        :value (maillist--unquote (if negated body token))
                        :negate negated)
                  terms))))))
    (list :query (string-join (nreverse remote) " ")
          :filters (nreverse filters)
          :terms (nreverse terms))))

(provide 'maillist-service)
;;; maillist-service.el ends here
