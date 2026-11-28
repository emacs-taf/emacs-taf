;;; etaf-md-qrcode.el --- Draw a QR code with qrencode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Thin Markdown container adapter over `etaf-doc-qrcode' for `qrcode' blocks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc)
(require 'etaf-md-node)
(require 'etaf-md-env)
(require 'etaf-md-cache)

(declare-function etaf-md--typeset-changed "etaf-md-typeset" (session))
(declare-function etaf-md--refresh-block-assets "etaf-md-model" (session))
(declare-function etaf-md--read "etaf-md-model" (session key))
(declare-function etaf-md--media-picture "etaf-md-views" (url env max-columns max-rows))
(declare-function etaf-md--component-view-env "etaf-md-components" (env))

(defconst etaf-md-qrcode--cache-directory
  (expand-file-name "qrcode/" etaf-md-cache--root-directory)
  "Directory holding one picture per QR block.")

(defun etaf-md-qrcode-available-p ()
  "Return non-nil when the system can draw a QR code."
  (etaf-doc-qrcode-available-p))

(defun etaf-md-qrcode--block-text (block)
  "Return BLOCK's QR text when it is a qrcode container, else nil."
  (when (and (eq (plist-get block :type) 'container)
             (equal (plist-get block :name) "qrcode"))
    (let ((text (plist-get (plist-get block :attrs) :text)))
      (and (stringp text) (not (string-blank-p text)) text))))

(defun etaf-md-qrcode--file (text)
  "Return the cache file holding TEXT's drawing."
  (etaf-doc-qrcode-file text etaf-md-qrcode--cache-directory))

(defun etaf-md-qrcode-attach (block)
  "Return BLOCK carrying the drawing already cached for it, if any."
  (if-let* ((text (etaf-md-qrcode--block-text block))
            (file (etaf-md-qrcode--file text))
            ((file-exists-p file)))
      (plist-put (copy-sequence block) :qr file)
    block))

(defun etaf-md-qrcode-cached-p (env)
  "Return non-nil when ENV's block has its drawing on disk."
  (when-let* ((node (etaf-md-env-node env))
              (path (plist-get (etaf-md-node-block node) :qr)))
    (file-exists-p path)))

(defun etaf-md-qrcode-view (env)
  "Return ENV's QR code as a picture, or nil while it is not drawn yet."
  (let* ((node (etaf-md-env-node env))
         (path (plist-get (etaf-md-node-block node) :qr)))
    (when (and path (file-exists-p path))
      (etaf-md--media-picture path (etaf-md--component-view-env env) 24 24))))

(defun etaf-md-qrcode-request (session)
  "Start the asynchronous QR drawings SESSION's page needs and does not show."
  (when (etaf-doc-qrcode-available-p)
    (let ((texts nil))
      (dolist (entry (plist-get (etaf-md--read session :document) :children))
        (when-let* ((text (etaf-md-qrcode--block-text (plist-get entry :block))))
          (push text texts)))
      (when texts
        (etaf-doc-qrcode-request-texts
         (nreverse texts)
         (lambda ()
           (cond
            ((fboundp 'etaf-md--typeset-changed)
             (etaf-md--typeset-changed session))
            ((fboundp 'etaf-md--refresh-block-assets)
             (etaf-md--refresh-block-assets session))))
         etaf-md-qrcode--cache-directory)))))

(provide 'etaf-md-qrcode)
;;; etaf-md-qrcode.el ends here
