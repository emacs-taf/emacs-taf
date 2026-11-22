;;; maillist-mail.el --- Sending mail from maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A reply or a new post opens in `message-mode', with the replied message's
;; canonical Message-ID in `In-Reply-To' and its ancestor chain in
;; `References' so the archive and every mail client keep the conversation
;; together.  GNU Debbugs lists (`emacs-bugs', or any source declaring
;; `:reply-style debbugs') direct replies to `<bug>@debbugs.gnu.org' parsed
;; from the subject so a reply never opens a duplicate bug report.
;;
;; Sending defaults to smtpmail with an application password from auth-source
;; (`maillist-mail-configure' stores it once with 0600 permissions for
;; plaintext `~/.authinfo'), or respects Emacs's existing mail transport when
;; `maillist-send-mail-function' is set to `inherit'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'message)
(require 'smtpmail)
(require 'auth-source)
(require 'etaf)
(require 'maillist-model)

(defvar maillist--session nil
  "Session of a mounted client buffer; bound by the application shell.")

(defgroup maillist nil
  "Mailing-list archive client."
  :group 'applications)

(defcustom maillist-mail-address user-mail-address
  "Address this client sends from.
It is also the smtpmail user; the password comes from auth-source under
`maillist-smtp-server' and this address."
  :type '(choice (const :tag "Use `user-mail-address'" nil) string)
  :group 'maillist)

(defcustom maillist-send-mail-function 'smtpmail
  "How `maillist' sends composed mail.
`smtpmail' (the default) uses `smtpmail-send-it' configured from
`maillist-smtp-server', `maillist-smtp-service' and
`maillist-smtp-stream-type'.  `inherit' leaves Emacs's own
`message-send-mail-function' untouched (for users already configured with
msmtp, sendmail, gmi or smtpmail-multi)."
  :type '(choice (const :tag "Built-in smtpmail" smtpmail)
                 (const :tag "Inherit Emacs message-send-mail-function" inherit))
  :group 'maillist)

(defcustom maillist-smtp-server "smtp.gmail.com"
  "SMTP server used to send replies and new posts."
  :type 'string
  :group 'maillist)

(defcustom maillist-smtp-service 465
  "SMTP port used to send replies and new posts."
  :type 'integer
  :group 'maillist)

(defcustom maillist-smtp-stream-type 'ssl
  "Stream type of the SMTP connection: `ssl', `starttls' or nil."
  :type '(choice (const ssl) (const starttls) (const nil))
  :group 'maillist)

(defun maillist-mail--account ()
  "Return the bare email address this client sends from."
  (let ((address (or maillist-mail-address user-mail-address)))
    (unless (and address (not (string-empty-p address)))
      (user-error "请先设置 maillist-mail-address 或 user-mail-address"))
    address))

(defun maillist-mail--from-header (address)
  "Return RFC 5322 From header value for ADDRESS, including `user-full-name'."
  (let ((name (and (stringp user-full-name) (string-trim user-full-name))))
    (cond
     ((string-match-p "<[^>]+>" address) address)
     ((or (null name) (string-empty-p name)) address)
     ((string-match-p "[.,;:\"<>()@\\]" name)
      (format "\"%s\" <%s>" (replace-regexp-in-string "\"" "\\\\\"" name) address))
     (t (format "%s <%s>" name address)))))

(defun maillist-mail--secret (address)
  "Return the smtpmail application password of ADDRESS, or nil."
  (when-let* ((found (car (auth-source-search
                           :host maillist-smtp-server
                           :user address
                           :port (number-to-string maillist-smtp-service)
                           :require '(:secret)))))
    (let ((secret (plist-get found :secret)))
      (if (functionp secret) (funcall secret) secret))))

(defun maillist-mail--authinfo-file ()
  "Return the auth-source file the client writes its password to."
  (if (file-exists-p (expand-file-name "~/.authinfo.gpg"))
      (expand-file-name "~/.authinfo.gpg")
    (expand-file-name "~/.authinfo")))

(defun maillist-mail--quote-authinfo (value)
  "Quote VALUE for `~/.authinfo' when it contains whitespace or quotes."
  (if (string-match-p "[ \t\"]" value)
      (format "\"%s\"" (replace-regexp-in-string "\"" "\\\\\"" value))
    value))

(defun maillist-mail-configure ()
  "Store the SMTP application password of the current account.
The password goes to the same auth-source file the client reads; nothing is
written into this package or its database.  An entry for the same server,
port and address is replaced, and a plaintext `~/.authinfo' file is locked to
mode 0600."
  (interactive)
  (let* ((address (read-string "发信地址: " (or maillist-mail-address
                                               user-mail-address)))
         (password (read-passwd (format "%s 的应用专用密码: " address)))
         (file (maillist-mail--authinfo-file))
         (port-str (number-to-string maillist-smtp-service))
         (entry (format "machine %s login %s port %s password %s"
                        maillist-smtp-server address port-str
                        (maillist-mail--quote-authinfo password)))
         (pattern (format "^machine[ \t]+%s[ \t]+login[ \t]+%s[ \t]+port[ \t]+%s\\b.*$"
                          (regexp-quote maillist-smtp-server)
                          (regexp-quote address)
                          (regexp-quote port-str))))
    (when (string-empty-p password)
      (user-error "密码为空，未保存"))
    (with-temp-buffer
      (when (file-exists-p file)
        (insert-file-contents file))
      (goto-char (point-min))
      (if (re-search-forward pattern nil t)
          (replace-match entry t t)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert entry "\n"))
      (write-region (point-min) (point-max) file nil 'silent))
    (unless (string-suffix-p ".gpg" file)
      (ignore-errors (set-file-modes file #o600)))
    (auth-source-forget-all-cached)
    (message "已保存 %s 的 smtpmail 凭据（%s）" address file)
    address))

;;; ---------------------------------------------------------------------------
;;; Message buffers
;;; ---------------------------------------------------------------------------

(defun maillist--format-mid (id)
  "Return canonical Message-ID ID wrapped in angle brackets, or nil."
  (when (and (stringp id) (not (string-empty-p id)))
    (if (and (string-prefix-p "<" id) (string-suffix-p ">" id))
        id
      (format "<%s>" id))))

(defun maillist--reference-chain (target messages)
  "Return the RFC 5322 `References' chain leading up to TARGET among MESSAGES.
Walks `:parent' links from TARGET to the thread root with cycle protection.
If the chain exceeds 10 ids, keeps the thread root plus the 9 most recent
ancestors per RFC 5322 section 3.6.4."
  (let ((by-id (make-hash-table :test #'equal))
        (chain nil)
        (seen (make-hash-table :test #'equal))
        (cursor target))
    (dolist (m messages)
      (when-let* ((id (plist-get m :id)))
        (unless (string-empty-p id)
          (puthash id m by-id))))
    (while (and cursor
                (let ((id (plist-get cursor :id)))
                  (and id (not (string-empty-p id)) (not (gethash id seen)))))
      (let ((id (plist-get cursor :id))
            (parent (plist-get cursor :parent)))
        (puthash id t seen)
        (push (maillist--format-mid id) chain)
        (setq cursor (and parent (gethash parent by-id)))))
    ;; If `:parent' links were missing (for example a flat feed), include the
    ;; root message so the reply still threads under it.
    (when (and (= (length chain) 1) (> (length messages) 1))
      (when-let* ((root (maillist--format-mid (plist-get (car messages) :id))))
        (unless (member root chain)
          (push root chain))))
    (if (> (length chain) 10)
        (cons (car chain) (last chain 9))
      chain)))

(defun maillist--reply-subject (subject)
  "Return SUBJECT with one Re: prefix."
  (let ((case-fold-search t)
        (subject (string-trim (or subject ""))))
    (if (string-match-p "\\`re:" subject)
        subject
      (concat "Re: " subject))))

(defun maillist--list-reply-address (source thread target)
  "Return the list recipient address for replying to TARGET in THREAD of SOURCE.
For GNU Debbugs lists (`:reply-style debbugs' or `bug-gnu-emacs@gnu.org'),
extract `bug#<N>' from the subject and return `<N>@debbugs.gnu.org' so a
reply appends to the bug instead of filing a new one."
  (let* ((base-addr (or (plist-get source :address) ""))
         (debbugs-p (or (eq (plist-get source :reply-style) 'debbugs)
                        (equal (downcase base-addr) "bug-gnu-emacs@gnu.org")))
         (subj (or (plist-get target :subject) (plist-get thread :subject) "")))
    (if (and debbugs-p
             (let ((case-fold-search t))
               (string-match "\\bbug#\\([0-9]+\\)\\b" subj)))
        (format "%s@debbugs.gnu.org" (match-string 1 subj))
      base-addr)))

(defun maillist--attribution (message)
  "Return the attribution line quoting MESSAGE."
  (let ((author (or (plist-get message :author) "someone"))
        (email (or (plist-get message :email) ""))
        (stamp (plist-get message :date)))
    (format "%s\n\n"
            (string-trim
             (concat author (if (string-empty-p email) "" (format " <%s>" email))
                     (if stamp (format " writes (%s):"
                                       (maillist-long-label stamp))
                       " writes:"))))))

(defun maillist--quote (text)
  "Return TEXT as a quoted reply body."
  (mapconcat (lambda (line) (concat "> " line))
             (split-string (or text "") "\n") "\n"))

(defun maillist--prepare (session to subject headers body &optional references)
  "Open a message buffer of SESSION sending TO with SUBJECT.
HEADERS is an alist of extra headers, BODY the initial body and REFERENCES
the thread's message ids for the References header.  Composing works without
a stored SMTP password; the password is only needed when the mail goes out."
  (let* ((address (maillist-mail--account))
         (from (maillist-mail--from-header address))
         (secret (and (eq maillist-send-mail-function 'smtpmail)
                      (maillist-mail--secret address)))
         buffer)
    (message-mail to subject (append (list (cons 'From from)) headers))
    (setq buffer (current-buffer))
    (when (and references (not (string-empty-p references)))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^--text follows this line--$" nil t)
          (goto-char (match-beginning 0))
          (insert "References: " references "\n"))))
    (message-goto-body)
    (insert body)
    (when (eq maillist-send-mail-function 'smtpmail)
      (setq-local smtpmail-smtp-server maillist-smtp-server)
      (setq-local smtpmail-smtp-service maillist-smtp-service)
      (setq-local smtpmail-stream-type maillist-smtp-stream-type)
      (setq-local smtpmail-smtp-user address)
      ;; Emacs 29+ reads the password from auth-source; older releases also
      ;; consult this list, so fill it only where it exists.
      (when (boundp 'smtpmail-auth-credentials)
        (when secret
          (setq-local smtpmail-auth-credentials
                      (list (list maillist-smtp-server maillist-smtp-service
                                  address secret)))))
      (setq-local message-send-mail-function #'smtpmail-send-it))
    (setq-local message-signature (or message-signature t))
    (add-hook 'message-sent-hook
              (lambda ()
                (run-at-time 2 nil
                             (lambda ()
                               (when (and (maillist--alive-p session)
                                          (maillist--archive-list-p session))
                                 (maillist-refresh session t)))))
              nil t)
    ;; Place point at the start of the message body so headers remain visible.
    (message-goto-body)
    (pop-to-buffer buffer)
    buffer))

(defun maillist-mail--session ()
  "Return the session of the current client buffer."
  (or maillist--session
      (when-let* ((state (etaf-app-state)))
        (plist-get state :session))
      (user-error "不在邮件列表缓冲区中")))

(defun maillist--reply-parts (session &optional message-id)
  "Return what a reply to SESSION's open thread is built from.
Replies target MESSAGE-ID when supplied, otherwise SESSION's focused message
(`:focused-message'), falling back to the newest message in the thread."
  (let ((thread (etaf-value (plist-get session :open))))
    (unless (and thread (plist-get thread :messages))
      (user-error "没有可回复的线程"))
    (let* ((messages (or (plist-get session :open-messages)
                         (plist-get thread :messages)))
           (wanted (or message-id (etaf-value (plist-get session :focused-message))))
           (target (or (and wanted
                            (cl-find wanted messages
                                     :key (lambda (m) (plist-get m :id))
                                     :test #'equal))
                       (car (last messages))))
           (source (plist-get session :source))
           (refs (maillist--reference-chain target messages)))
      (list :thread thread
            :messages messages
            :last target
            :list (maillist--list-reply-address source thread target)
            :in-reply-to (maillist--format-mid (plist-get target :id))
            :references (mapconcat #'identity refs " ")))))

(defun maillist--reply-buffer (session parts to cc)
  "Open the reply buffer of SESSION from PARTS, sending TO and copying CC.
CC may be nil or empty, in which case the reply goes to TO alone."
  (let* ((target (plist-get parts :last))
         (in-reply-to (plist-get parts :in-reply-to))
         (references (plist-get parts :references))
         (headers (append (when in-reply-to
                            (list (cons 'In-Reply-To in-reply-to)))
                          (unless (or (null cc) (string-empty-p cc))
                            (list (cons 'Cc cc))))))
    (maillist--prepare
     session to
     (maillist--reply-subject (or (plist-get target :subject)
                                  (plist-get (plist-get parts :thread) :subject)))
     headers
     (concat (maillist--attribution target)
             (maillist--quote (plist-get target :text))
             "\n\n")
     references)))

;;;###autoload
(defun maillist-reply (session &optional private message-id)
  "Reply to SESSION's open thread (targeting focused message or MESSAGE-ID).
With PRIVATE non-nil the reply goes to the replied message's author instead
of the list.  Both forms keep canonical `In-Reply-To' and `References', and
Debbugs lists automatically address `<bug>@debbugs.gnu.org'."
  (interactive (list (maillist-mail--session) current-prefix-arg))
  (let* ((parts (maillist--reply-parts session message-id))
         (author (or (plist-get (plist-get parts :last) :email) "")))
    (when (and private (string-empty-p author))
      (user-error "这一封没有发件人地址，无法私回"))
    (let ((buffer (maillist--reply-buffer
                   session parts
                   (if private author (plist-get parts :list)) nil)))
      (message "%s" (if private
                        (format "私回 %s，不发到列表" author)
                      (format "回信地址是 %s；列表外地址发帖会进入审核队列"
                              (plist-get parts :list))))
      buffer)))

;;;###autoload
(defun maillist-reply-all (session &optional message-id)
  "Reply to SESSION's open thread and copy the replied message's author.
The list (or Debbugs bug address) stays the recipient; the replied author is
placed in Cc unless it matches the sender's own address or the list address."
  (interactive (list (maillist-mail--session)))
  (let* ((parts (maillist--reply-parts session message-id))
         (to (plist-get parts :list))
         (self (downcase (maillist-mail--account)))
         (raw-author (string-trim (or (plist-get (plist-get parts :last) :email) "")))
         (cc (unless (or (string-empty-p raw-author)
                         (equal (downcase raw-author) self)
                         (equal (downcase raw-author) (downcase (or to ""))))
               raw-author))
         (buffer (maillist--reply-buffer session parts to cc)))
    (message "回信地址是 %s；%s"
             to
             (if cc (format "%s 在 Cc 里" cc) "无需额外 Cc"))
    buffer))

;;;###autoload
(defun maillist-compose (session)
  "Write a new post to SESSION's list."
  (interactive (list (maillist-mail--session)))
  (let* ((source (plist-get session :source))
         (subject (read-string "新帖主题: ")))
    (when (string-empty-p (string-trim subject))
      (user-error "主题不能为空"))
    (let ((buffer (maillist--prepare
                   session (plist-get source :address) subject nil "\n")))
      (message "新帖发到 %s；未订阅的地址会进入审核队列"
               (plist-get source :address))
      buffer)))

(provide 'maillist-mail)
;;; maillist-mail.el ends here
