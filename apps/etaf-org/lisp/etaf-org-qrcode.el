;;; etaf-org-qrcode.el --- Async QR code drawing via qrencode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Thin Org special-block adapter over `etaf-doc-qrcode' for `#+begin_qrcode'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc)
(require 'etaf-org-cache)
(require 'etaf-org-node)
(require 'etaf-org-env)

(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--refresh-block-assets "etaf-org-model" (session))
(declare-function etaf-org--walk-document-blocks "etaf-org-model" (document fn))

(defconst etaf-org-qrcode--cache-directory
  (expand-file-name "qrcode/" etaf-org-cache--root-directory)
  "Directory holding one PNG per rendered QR block.")

(defun etaf-org-qrcode-available-p ()
  "Return non-nil when `qrencode' is available on `exec-path'."
  (etaf-doc-qrcode-available-p))

(defun etaf-org-qrcode--block-text (block)
  "Return QR payload string for BLOCK when it is a `qrcode' container, else nil."
  (when (and (eq (plist-get block :type) 'special-block)
             (equal (plist-get block :name) "qrcode"))
    (let ((text (or (plist-get (plist-get block :attrs) :text)
                    (string-trim (or (plist-get block :raw-content) "")))))
      (and (stringp text) (not (string-blank-p text)) text))))

(defun etaf-org-qrcode--file (text)
  "Return the cache PNG file path for QR payload TEXT."
  (etaf-doc-qrcode-file text etaf-org-qrcode--cache-directory))

(defun etaf-org-qrcode-attach (block)
  "Attach `:qr' cached PNG path onto BLOCK when present on disk."
  (if-let* ((text (etaf-org-qrcode--block-text block))
            (file (etaf-org-qrcode--file text))
            ((file-exists-p file)))
      (plist-put (copy-sequence block) :qr file)
    block))

(defun etaf-org-qrcode-request (session)
  "Start asynchronous QR renderings needed by mounted SESSION."
  (when (and (etaf-doc-qrcode-available-p)
             (buffer-live-p (plist-get session :buffer))
             (fboundp 'etaf-org--walk-document-blocks))
    (let ((texts nil))
      (etaf-org--walk-document-blocks
       (etaf-org--read session :document)
       (lambda (block)
         (when-let* ((text (etaf-org-qrcode--block-text block)))
           (push text texts))))
      (when texts
        (etaf-doc-qrcode-request-texts
         (nreverse texts)
         (lambda ()
           (when (and (buffer-live-p (plist-get session :buffer))
                      (fboundp 'etaf-org--refresh-block-assets))
             (etaf-org--refresh-block-assets session)))
         etaf-org-qrcode--cache-directory)))))

(provide 'etaf-org-qrcode)
;;; etaf-org-qrcode.el ends here
