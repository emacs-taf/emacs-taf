;;; etaf-md-qrcode.el --- Draw a QR code with qrencode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A `qrcode' block turns its text into a scannable code.  The module keeps the
;; drawing out of the render: a publish reads the cache and paints what is
;; there, a request fills the cache on a timer and publishes once more, the way
;; a diagram arrives.  `qrencode' is the only program behind it; without it the
;; block keeps its text and says so.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'etaf-ui)
(require 'etaf-md-node)
(require 'etaf-md-env)

(declare-function etaf-md--typeset-changed "etaf-md-typeset" (session))
(declare-function etaf-md--media-picture "etaf-md-views" (url env max-columns max-rows))
(declare-function etaf-md--component-view-env "etaf-md-components" (env))

(defconst etaf-md-qrcode--cache-directory
  (expand-file-name "etaf-md/qrcode/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Directory holding one picture per QR block.")

(defvar etaf-md-qrcode--running (make-hash-table :test #'equal)
  "Cache files whose program is running, so a publish does not start it twice.")

(defun etaf-md-qrcode-available-p ()
  "Return non-nil when the system can draw a QR code."
  (and (executable-find "qrencode") t))

(defun etaf-md-qrcode--block-text (block)
  "Return BLOCK's QR text when it is a qrcode container, else nil."
  (when (and (eq (plist-get block :type) 'container)
             (equal (plist-get block :name) "qrcode"))
    (let ((text (plist-get (plist-get block :attrs) :text)))
      (and (stringp text)
           (not (string-blank-p text))
           text))))

(defun etaf-md-qrcode--file (text)
  "Return the cache file holding TEXT's drawing."
  (expand-file-name (concat (secure-hash 'sha1 text) ".png")
                    etaf-md-qrcode--cache-directory))

(defun etaf-md-qrcode-attach (block)
  "Return BLOCK carrying the drawing already cached for it, if any."
  (let ((text (etaf-md-qrcode--block-text block)))
    (if-let* ((text)
              (file (etaf-md-qrcode--file text))
              ((file-exists-p file)))
        (plist-put (copy-sequence block) :qr file)
      block)))

(defun etaf-md-qrcode-cached-p (env)
  "Return non-nil when ENV's block has its drawing on disk."
  (when-let* ((node (etaf-md-env-node env))
              (path (plist-get (etaf-md-node-block node) :qr)))
    (file-exists-p path)))

(defun etaf-md-qrcode-view (env)
  "Return ENV's QR code as a picture, or nil while it is not drawn yet.
The code is a PNG drawn by `qrencode' with its own quiet zone, so it keeps
the square shape the scanner expects at any font metric."
  (let* ((node (etaf-md-env-node env))
         (path (plist-get (etaf-md-node-block node) :qr)))
    (when (and path (file-exists-p path))
      (etaf-md--media-picture path (etaf-md--component-view-env env) 24 24))))

(defun etaf-md-qrcode--write (text file)
  "Draw TEXT's code into PNG FILE; return non-nil when it was written."
  (make-directory (file-name-directory file) t)
  (let ((temporary (make-temp-file "etaf-md-qr-" nil ".png")))
    (unwind-protect
        (when (zerop (call-process "qrencode" nil nil nil
                                   "-t" "PNG" "-s" "8" "-m" "2"
                                   "-o" temporary text))
          (rename-file temporary file t)
          t)
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun etaf-md-qrcode-request (session)
  "Start the drawings SESSION's page needs and does not show yet."
  (when (etaf-md-qrcode-available-p)
    (dolist (entry (plist-get (etaf-md--read session :document) :children))
      (let* ((block (plist-get entry :block))
             (text (etaf-md-qrcode--block-text block))
             (file (and text (etaf-md-qrcode--file text))))
        (when (and file
                   (not (file-exists-p file))
                   (not (gethash file etaf-md-qrcode--running)))
          (puthash file t etaf-md-qrcode--running)
          (run-at-time
           0 nil
           (lambda ()
             (unwind-protect
                 (when (etaf-md-qrcode--write text file)
                   (when (fboundp 'etaf-md--typeset-changed)
                     (etaf-md--typeset-changed session)))
               (remhash file etaf-md-qrcode--running)))))))))

(provide 'etaf-md-qrcode)

;;; etaf-md-qrcode.el ends here
