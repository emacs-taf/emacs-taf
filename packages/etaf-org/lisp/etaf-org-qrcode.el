;;; etaf-org-qrcode.el --- Async QR code drawing via qrencode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Draws `#+begin_qrcode' blocks asynchronously with `qrencode' into
;; `~/.cache/etaf-org/qrcode/' with bounded LRU eviction.  Rendering never
;; runs a subprocess: publish attaches already-cached PNGs, and mounted
;; sessions request missing drawings asynchronously and repaint in place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-cache)
(require 'etaf-org-node)
(require 'etaf-org-env)

(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--refresh-block-assets "etaf-org-model" (session))
(declare-function etaf-org--walk-document-blocks "etaf-org-model" (document fn))

(defconst etaf-org-qrcode--cache-directory
  (expand-file-name "qrcode/" etaf-org-cache--root-directory)
  "Directory holding one PNG per rendered QR block.")

(defvar etaf-org-qrcode--running (make-hash-table :test #'equal)
  "Cache files whose `qrencode' job is currently in flight.")

(defun etaf-org-qrcode-available-p ()
  "Return non-nil when `qrencode' is available on `exec-path'."
  (and (executable-find "qrencode") t))

(defun etaf-org-qrcode--block-text (block)
  "Return QR payload string for BLOCK when it is a `qrcode' container, else nil."
  (when (and (eq (plist-get block :type) 'special-block)
             (equal (plist-get block :name) "qrcode"))
    (let ((text (or (plist-get (plist-get block :attrs) :text)
                    (string-trim (or (plist-get block :raw-content) "")))))
      (and (stringp text) (not (string-blank-p text)) text))))

(defun etaf-org-qrcode--file (text)
  "Return the cache PNG file path for QR payload TEXT."
  (expand-file-name (concat (secure-hash 'sha1 text) ".png")
                    etaf-org-qrcode--cache-directory))

(defun etaf-org-qrcode-attach (block)
  "Attach `:qr' cached PNG path onto BLOCK when present on disk."
  (if-let* ((text (etaf-org-qrcode--block-text block))
            (file (etaf-org-qrcode--file text))
            ((file-exists-p file)))
      (plist-put (copy-sequence block) :qr file)
    block))

(defun etaf-org-qrcode--write-async (text file done)
  "Draw TEXT's QR PNG into FILE asynchronously via `etaf-process-run'."
  (make-directory (file-name-directory file) t)
  (let ((temporary (make-temp-file "etaf-org-qr-" nil ".png")))
    (etaf-process-run
     (list "qrencode" "-t" "PNG" "-s" "8" "-m" "2" "-o" temporary text)
     :name "etaf-org-qrencode"
     :timeout 10
     :callback
     (lambda (res)
       (let ((ok nil))
         (unwind-protect
             (when (and (eq (plist-get res :status) 'exit)
                        (eql (plist-get res :exit) 0)
                        (file-exists-p temporary))
               (rename-file temporary file t)
               (etaf-org-cache-prune-directory etaf-org-qrcode--cache-directory)
               (setq ok t))
           (when (file-exists-p temporary)
             (ignore-errors (delete-file temporary))))
         (funcall done ok))))))

(defun etaf-org-qrcode-request (session)
  "Start asynchronous QR renderings needed by mounted SESSION."
  (when (and (etaf-org-qrcode-available-p)
             (buffer-live-p (plist-get session :buffer))
             (fboundp 'etaf-org--walk-document-blocks))
    (etaf-org--walk-document-blocks
     (etaf-org--read session :document)
     (lambda (block)
       (when-let* ((text (etaf-org-qrcode--block-text block))
                   (file (etaf-org-qrcode--file text))
                   ((not (file-exists-p file)))
                   ((not (gethash file etaf-org-qrcode--running))))
         (puthash file t etaf-org-qrcode--running)
         (etaf-org-qrcode--write-async
          text file
          (lambda (ok)
            (remhash file etaf-org-qrcode--running)
            (when (and ok (buffer-live-p (plist-get session :buffer))
                       (fboundp 'etaf-org--refresh-block-assets))
              (etaf-org--refresh-block-assets session)))))))))

(provide 'etaf-org-qrcode)
;;; etaf-org-qrcode.el ends here
