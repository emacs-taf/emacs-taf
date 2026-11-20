;;; -*- lexical-binding: t; -*-
;;; prefetch-standard-archives.el --- Fetch one standard-archive snapshot for CI

;;; Commentary:
;; The installation matrix must not depend on a third-party archive staying
;; reachable for every target and every Emacs process.  This script downloads
;; the GNU, NonGNU and MELPA indexes once, resolves the external packages named
;; by release-dependencies.json, and stores the indexes plus their tarballs in
;; a local mirror.  The CI runner serves that mirror over localhost, so every
;; target installs the same live snapshot while the ETAF archive still comes
;; from the sealed build.
;;
;; Environment:
;;   ETAF_PREFETCH_OUTPUT  Directory that receives the mirror and manifest.json.
;;   ETAF_PREFETCH_ROOTS   Comma-separated package names from standard archives.
;;
;; Existing nonempty files are kept, so the Python wrapper can retry after a
;; throttled request without downloading earlier files again.  A failed request
;; is reported with its HTTP status; package.el's generic download message is
;; not used here.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'package)
(require 'url)
(require 'url-http)

(defconst etaf-prefetch--archives
  '(("gnu" . "https://elpa.gnu.org/packages/")
    ("nongnu" . "https://elpa.nongnu.org/nongnu/")
    ("melpa" . "https://melpa.org/packages/"))
  "Standard archives the installer may register.")

(defun etaf-prefetch--fetch (url destination)
  "Download URL to DESTINATION and return DESTINATION.
Signal an error that names the HTTP status when the response is not 2xx.
Keep an existing nonempty DESTINATION, and publish a new file atomically."
  (if (and (file-regular-p destination)
           (> (file-attribute-size (file-attributes destination)) 0))
      destination
    (let ((buffer (url-retrieve-synchronously url t t 120)))
      (unless buffer
        (error "No response: %s" url))
      (unwind-protect
          (with-current-buffer buffer
            (let ((status url-http-response-status))
              (unless (and (integerp status) (<= 200 status 299))
                (error "HTTP %s: %s" status url))
              (set-buffer-multibyte nil)
              (goto-char (point-min))
              (unless (search-forward "\n\n" nil t)
                (error "Malformed HTTP response: %s" url))
              (make-directory (file-name-directory destination) t)
              (let ((temporary (make-temp-file
                                (expand-file-name ".prefetch-" (file-name-directory destination)))))
                (unwind-protect
                    (progn
                      (let ((coding-system-for-write 'binary))
                        (write-region (point) (point-max) temporary nil 'silent))
                      (rename-file temporary destination t))
                  (when (file-exists-p temporary)
                    (delete-file temporary))))))
        (kill-buffer buffer)))
    destination))

(defun etaf-prefetch--sha256 (file)
  "Return the SHA-256 of FILE as a lowercase hexadecimal string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun etaf-prefetch--version (descriptor)
  "Return DESCRIPTOR's version as a dotted string."
  (package-version-join (package-desc-version descriptor)))

(defun etaf-prefetch--index (output)
  "Download the registered indexes and stage them for package.el.
Return an alist of archive names, their source URLs and index checksums."
  (let (records)
    (dolist (archive etaf-prefetch--archives)
      (let* ((name (car archive))
             (base (cdr archive))
             (cache (expand-file-name (concat "archives/" name "/archive-contents")
                                      package-user-dir))
             (mirror (expand-file-name (concat name "/archive-contents") output)))
        (etaf-prefetch--fetch (concat base "archive-contents") cache)
        (make-directory (file-name-directory mirror) t)
        (copy-file cache mirror t)
        (push (list :name name :url base
                    :sha256 (etaf-prefetch--sha256 mirror))
              records)))
    (nreverse records)))

(defun etaf-prefetch--closure (roots)
  "Return the external dependency closure for ROOTS in `package-archive-contents'."
  (let ((seen (make-hash-table :test #'equal))
        packages)
    (dolist (root roots)
      (let ((descriptor (cadr (assq (intern root) package-archive-contents))))
        (unless descriptor
          (error "No standard archive provides %s" root))
        (dolist (item (package-compute-transaction
                       (list descriptor) (package-desc-reqs descriptor)))
          ;; Built-in packages have no archive and need no tarball.
          (when (package-desc-archive item)
            (let ((key (package-desc-full-name item)))
              (unless (gethash key seen)
                (puthash key t seen)
                (push item packages)))))))
    (nreverse packages)))

(defun etaf-prefetch--packages (output descriptors)
  "Download DESCRIPTORS into OUTPUT and return their manifest records."
  (let (records)
    (dolist (descriptor descriptors)
      (let* ((archive (package-desc-archive descriptor))
             (source (cdr (assoc archive etaf-prefetch--archives)))
             (file (concat (package-desc-full-name descriptor)
                           (package-desc-suffix descriptor)))
             (url (concat source file))
             (destination (expand-file-name (concat archive "/" file) output)))
        (unless source
          (error "%s comes from an unhandled archive %s"
                 (package-desc-full-name descriptor) archive))
        (etaf-prefetch--fetch url destination)
        (push (list :name (symbol-name (package-desc-name descriptor))
                    :version (etaf-prefetch--version descriptor)
                    :archive archive
                    :file file
                    :sha256 (etaf-prefetch--sha256 destination))
              records)))
    (nreverse records)))

(defun etaf-prefetch--write-manifest (output roots archives packages)
  "Write OUTPUT/manifest.json describing the fetched snapshot."
  (let* ((manifest (expand-file-name "manifest.json" output))
         (temporary (make-temp-file (expand-file-name ".manifest-" output))))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert
             (json-encode
              (list (cons 'schema 1)
                    (cons 'fetched_at (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
                    (cons 'roots roots)
                    (cons 'archives
                          (mapcar (lambda (entry)
                                    (list (cons 'name (plist-get entry :name))
                                          (cons 'url (plist-get entry :url))
                                          (cons 'sha256 (plist-get entry :sha256))))
                                  archives))
                    (cons 'packages
                          (mapcar (lambda (entry)
                                    (list (cons 'name (plist-get entry :name))
                                          (cons 'version (plist-get entry :version))
                                          (cons 'archive (plist-get entry :archive))
                                          (cons 'file (plist-get entry :file))
                                          (cons 'sha256 (plist-get entry :sha256))))
                                  packages)))))
            (insert "\n"))
          (rename-file temporary manifest t))
      (when (file-exists-p temporary)
        (delete-file temporary)))
    manifest))

(let* ((output (getenv "ETAF_PREFETCH_OUTPUT"))
       (roots (split-string (or (getenv "ETAF_PREFETCH_ROOTS") "") "," t))
       (temporary (make-temp-file "etaf-prefetch-" t)))
  (unless (and output roots)
    (error "Set ETAF_PREFETCH_OUTPUT and ETAF_PREFETCH_ROOTS"))
  (setq output (file-name-as-directory (expand-file-name output))
        package-user-dir (expand-file-name "elpa" temporary)
        package-archives (append etaf-prefetch--archives nil)
        package-check-signature nil)
  (make-directory package-user-dir t)
  (make-directory output t)
  (unwind-protect
      (let ((archives (etaf-prefetch--index output)))
        ;; The indexes are staged in package-user-dir, so reading them does not
        ;; touch the network or a user profile.
        (package-read-all-archive-contents)
        (let* ((descriptors (etaf-prefetch--closure roots))
               (packages (etaf-prefetch--packages output descriptors)))
          (etaf-prefetch--write-manifest output roots archives packages)
          (princ (format "prefetched=%s roots=%s packages=%d\n"
                         output (mapconcat #'identity roots ",") (length packages)))))
    (delete-directory temporary t)))

;;; prefetch-standard-archives.el ends here
