;;; etaf-doc-qrcode.el --- Shared asynchronous QR code drawing via qrencode -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Asynchronous QR code PNG generation backed by `qrencode' and bounded LRU
;; disk caching (`etaf-doc-cache').  Shared across ETAF document renderers
;; (`etaf-md', `etaf-org').  Rendering stays pure and never spawns subprocesses.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-doc-cache)

(defconst etaf-doc-qrcode--default-directory
  (expand-file-name "qrcode/" etaf-doc-cache--default-root)
  "Default directory holding cached QR code PNG images.")

(defvar etaf-doc-qrcode--running (make-hash-table :test #'equal)
  "Cache file paths whose `qrencode' process is currently in flight.")

(defun etaf-doc-qrcode-available-p ()
  "Return non-nil when `qrencode' is available on `exec-path'."
  (and (executable-find "qrencode") t))

(defun etaf-doc-qrcode-file (text &optional directory)
  "Return the deterministic cached PNG file path for QR payload TEXT.
DIRECTORY defaults to `~/.cache/etaf-doc/qrcode/'."
  (when (and (stringp text) (not (string-blank-p text)))
    (expand-file-name (concat (secure-hash 'sha1 text) ".png")
                      (or directory etaf-doc-qrcode--default-directory))))

(defun etaf-doc-qrcode--write-async (text file directory done)
  "Draw TEXT's QR PNG into FILE asynchronously via `etaf-process-run'.
Calls DONE with non-nil when FILE was written, or nil on failure."
  (make-directory (file-name-directory file) t)
  (let ((temporary (make-temp-file "etaf-doc-qr-" nil ".png")))
    (etaf-process-run
     (list "qrencode" "-t" "PNG" "-s" "8" "-m" "2" "-o" temporary text)
     :name "etaf-doc-qrencode"
     :timeout 10
     :callback
     (lambda (res)
       (let ((ok nil))
         (unwind-protect
             (when (and (eq (plist-get res :status) 'exit)
                        (eql (plist-get res :exit) 0)
                        (file-exists-p temporary))
               (rename-file temporary file t)
               (etaf-doc-cache-prune-directory directory)
               (setq ok t))
           (when (file-exists-p temporary)
             (ignore-errors (delete-file temporary))))
         (funcall done ok))))))

(defun etaf-doc-qrcode-request-texts (texts on-ready &optional directory)
  "Queue asynchronous `qrencode' jobs for uncached QR payloads in TEXTS.
Invokes ON-READY with no arguments whenever a new PNG finishes writing.
DIRECTORY defaults to `~/.cache/etaf-doc/qrcode/'."
  (when (etaf-doc-qrcode-available-p)
    (let ((dir (or directory etaf-doc-qrcode--default-directory)))
      (dolist (text (delete-dups (copy-sequence texts)))
        (when-let* ((file (etaf-doc-qrcode-file text dir))
                    ((not (file-exists-p file)))
                    ((not (gethash file etaf-doc-qrcode--running))))
          (puthash file t etaf-doc-qrcode--running)
          (etaf-doc-qrcode--write-async
           text file dir
           (lambda (ok)
             (remhash file etaf-doc-qrcode--running)
             (when (and ok (functionp on-ready))
               (funcall on-ready)))))))))

(provide 'etaf-doc-qrcode)
;;; etaf-doc-qrcode.el ends here
