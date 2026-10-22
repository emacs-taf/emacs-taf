;;; maillist-mail.el --- Sending mail from maillist -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A reply or a new post opens in `message-mode', with the thread's message ids
;; in `In-Reply-To' and `References' so the archive and every mail client keep
;; the conversation together.  Sending uses smtpmail with an application
;; password taken from auth-source; `maillist-mail-configure' stores that
;; password once, and the client never keeps its own copy.
;;
;; A GNU mailing list moderates posts from an address that is not subscribed,
;; so the client says that once instead of hiding the queue.

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
MAILLIST-SMTP-SERVER and this address."
  :type '(choice (const :tag "Use `user-mail-address'" nil) string)
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
  "Return the address this client sends from."
  (let ((address (or maillist-mail-address user-mail-address)))
    (unless (and address (not (string-empty-p address)))
      (user-error "请先设置 maillist-mail-address 或 user-mail-address"))
    address))

(defun maillist-mail--secret (address)
  "Return the smtpmail application password of ADDRESS, or nil."
  (when-let* ((found (car (auth-source-search
                           :host maillist-smtp-server
                           :user address
                           :port (number-to-string maillist-smtp-service)
                           :require '(:secret)))))
    (let ((secret (plist-get found :secret)))
      (if (functionp secret) (funcall secret) secret))))

;;;###autoload
(defun maillist-mail--authinfo-file ()
  "Return the auth-source file the client writes its password to."
  (if (file-exists-p (expand-file-name "~/.authinfo.gpg"))
      (expand-file-name "~/.authinfo.gpg")
    (expand-file-name "~/.authinfo")))

(defun maillist-mail-configure ()
  "Store the SMTP application password of the current account.
The password goes to the same auth-source file the client reads; nothing is
written into this package or its database.  An entry for the same server and
address is replaced, so running this twice does not duplicate it."
  (interactive)
  (let* ((address (read-string "发信地址: " (or maillist-mail-address
                                               user-mail-address)))
         (password (read-passwd (format "%s 的应用专用密码: " address)))
         (file (maillist-mail--authinfo-file))
         (entry (format "machine %s login %s port %s password %s"
                        maillist-smtp-server address
                        maillist-smtp-service password))
         (pattern (format "^machine[ \t]+%s[ \t]+login[ \t]+%s.*$"
                          (regexp-quote maillist-smtp-server)
                          (regexp-quote address))))
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
    (auth-source-forget-all-cached)
    (message "已保存 %s 的 smtpmail 凭据（%s）" address file)
    address))

;;; ---------------------------------------------------------------------------
;;; Message buffers
;;; ---------------------------------------------------------------------------

(defun maillist--message-ids (messages)
  "Return the `<id>' strings of MESSAGES, oldest first."
  (delq nil (mapcar (lambda (message)
                      (let ((id (plist-get message :id)))
                        (and id (not (string-empty-p id))
                             (format "<%s>" id))))
                    messages)))

(defun maillist--reply-subject (subject)
  "Return SUBJECT with one Re: prefix."
  (let ((subject (string-trim (or subject ""))))
    (if (string-match-p "\\`re:" subject)
        subject
      (concat "Re: " subject))))

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
the thread's message ids for the References header, which message mode only
generates for its own reply command, so it is inserted here.  A stored
password is installed for clients that read `smtpmail-auth-credentials', but
composing works without one: the password is only needed when the mail goes
out."
  (let* ((address (maillist-mail--account))
         (secret (maillist-mail--secret address))
         buffer)
    (message-mail to subject (append (list (cons 'From address)) headers))
    (setq buffer (current-buffer))
    (when (and references (not (string-empty-p references)))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^--text follows this line--$" nil t)
          (goto-char (match-beginning 0))
          (insert "References: " references "\n"))))
    (message-goto-body)
    (insert body)
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
    (setq-local message-send-mail-function #'smtpmail-send-it)
    (setq-local message-signature (or message-signature t))
    (add-hook 'message-sent-hook
              (lambda ()
                (run-at-time 1 nil
                             (lambda ()
                               (when (maillist--alive-p session)
                                 (maillist-refresh session)))))
              nil t)
    (goto-char (point-min))
    (pop-to-buffer buffer)
    buffer))

(defun maillist-mail--session ()
  "Return the session of the current client buffer."
  (or maillist--session
      (when-let* ((state (etaf-app-state)))
        (plist-get state :session))
      (user-error "不在邮件列表缓冲区中")))

;;;###autoload
(defun maillist-reply (session &optional private)
  "Reply to SESSION's open thread.
With PRIVATE non-nil the reply goes to the last message's author instead of
the list, which is how a mailing-list reader answers someone directly.  Both
forms keep `In-Reply-To' and `References', so the mail stays in the thread."
  (interactive (list (maillist-mail--session) current-prefix-arg))
  (let ((thread (etaf-value (plist-get session :open))))
    (unless (and thread (plist-get thread :messages))
      (user-error "没有可回复的线程"))
    (let* ((messages (plist-get session :open-messages))
           (last-message (car (last messages)))
           (author (or (plist-get last-message :email) ""))
           (source (plist-get session :source))
           (list-address (plist-get source :address))
           (ids (maillist--message-ids messages))
           (references (mapconcat #'identity (last ids 10) " "))
           buffer)
      (when (and private (string-empty-p author))
        (user-error "这一封没有发件人地址，无法私回"))
      (setq buffer
            (maillist--prepare
             session (if private author list-address)
             (maillist--reply-subject (plist-get thread :subject))
             (append (list (cons 'In-Reply-To (car (last ids))))
                     (unless (string-empty-p references)
                       (list (cons 'References references))))
             (concat (maillist--attribution last-message)
                     (maillist--quote (plist-get last-message :text))
                     "\n\n")
             references))
      (message "%s" (if private
                        (format "私回 %s，不发到列表" author)
                      (format "回信地址是 %s；列表外地址发帖会进入审核队列"
                              list-address)))
      buffer)))

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
