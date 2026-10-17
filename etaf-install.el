;;; -*- lexical-binding: t; -*-
;;; etaf-install.el --- Install ETAF with the Emacs package manager

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/emacs-taf/emacs-taf
;; Keywords: convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A small installation entry, not a second package manager.  Packages, their
;; dependencies, autoloads and local compilation remain owned by package.el.
;; Enabling this package registers the official archive without network access.
;; No shell, Git, Python, system compiler or configuration replacement is needed.
;;
;; Function: etaf-install (&optional package no-open)
;; Install PACKAGE from the official archive and open its existing application.
;; Interactive use offers the supported targets, with the component gallery as
;; the default.  NO-OPEN suppresses opening, for batch installation.  Return the
;; installed package symbol.  Already installed targets can be opened offline.
;; Missing mandatory Emacs capabilities or a conflicting source checkout signal
;; user-error before installation.  An upgrade of a loaded dependency also
;; requires a restart before installation. On failure, remove only packages added
;; by this attempt, preserving older installations and unrelated packages. Report
;; cleanup failures without hiding the installation error. Restart before retrying
;; because partially loaded Lisp cannot be safely rolled back in this process.
;; Use the standard package menu for upgrades; restart Emacs after an upgrade.
;;
;; Function: etaf-install-doctor (&optional package)
;; Return a plist with :package, :ready, :required and :optional capability facts.
;; Each capability fact is (LABEL AVAILABLE REMEDY).  PACKAGE defaults to
;; etaf-ui.  Interactively show the facts in a standard help buffer.  This check
;; performs no network requests, package installation or configuration writes.
;;
;; Variable: etaf-install-archive-url
;; HTTPS URL of the ETAF package archive.  A local absolute directory is accepted
;; for offline installation and release verification.  Existing archives and
;; signature verification policy are preserved; this option never disables TLS.
;;
;; Setup once using the installation block in the workspace README, then use
;; M-x etaf-install.  Credentials and external application backends are outside
;; this installer's scope.  It offers only targets with a verified Lisp install.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'subr-x)

(defgroup etaf-install nil
  "Install the ETAF framework and its Lisp applications."
  :group 'applications)

(defcustom etaf-install-archive-url "https://etaf.top/packages/"
  "ETAF package archive URL, or an absolute local archive directory."
  :type 'string
  :group 'etaf-install)

(defconst etaf-install--targets
  '((etaf-ui "ETAF components and gallery" etaf-ui-gallery-open)
    (etaf "ETAF framework" nil)
    (etaf-manual "ETAF reference manual" etaf-manual-open)
    (etaf-db "ETAF SQLite backend" nil sqlite)
    (ekp "Knuth-Plass paragraph layout" nil)))

(defvar etaf-install--busy nil)
(defvar etaf-install--restart-required nil)

;; package.el evaluates this when enabling the installed package.  Registering
;; an archive is local work, not a refresh; respect an existing same-named source.
;;;###autoload
(with-eval-after-load 'package
  (unless (assoc "etaf" package-archives)
    (add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))))

(defun etaf-install--target (package)
  "Return the supported target description for PACKAGE."
  (or (assq package etaf-install--targets)
      (user-error "Unsupported target %s; run M-x etaf-install to choose one" package)))

(defun etaf-install--read-target ()
  "Read a supported package with standard Emacs completion."
  (let* ((choices (mapcar (lambda (target)
                            (cons (format "%s — %s" (car target) (cadr target))
                                  (car target)))
                          etaf-install--targets))
         (choice (completing-read "Install: " (mapcar #'car choices)
                                  nil t nil nil (caar choices))))
    (cdr (assoc choice choices))))

;;;###autoload
(defun etaf-install-doctor (&optional package)
  "Check required and optional capabilities for PACKAGE without changing anything."
  (interactive (list (etaf-install--read-target)))
  (let* ((package (or package 'etaf-ui))
         (target (etaf-install--target package))
         (required
          (list (list "Emacs 29.1 or newer" (not (version< emacs-version "29.1"))
                      "Use Emacs 29.1 or newer; your existing configuration is preserved.")))
         (optional
          (list (list "Native Lisp compilation"
                      (and (fboundp 'native-comp-available-p) (native-comp-available-p))
                      "Byte compilation works without it; a native-comp capable Emacs can improve speed."))))
    (when (memq 'sqlite (nthcdr 3 target))
      (push (list "SQLite built into Emacs"
                  (and (fboundp 'sqlite-available-p) (sqlite-available-p))
                  "Use an Emacs build with SQLite support; installing the sqlite3 executable is not sufficient.")
            required))
    (unless (eq package 'ekp)
      (push (list "Graphical display" (display-graphic-p)
                  "Terminal rendering is available, but graphical images require a graphical Emacs frame.")
            optional))
    (let ((result (list :package package
                        :ready (cl-every #'cadr required)
                        :required required :optional optional)))
      (when (called-interactively-p 'interactive)
        (with-help-window "*ETAF Installation*"
          (princ (format "ETAF installation: %s\nEmacs %s on %s\n\n"
                         package emacs-version system-type))
          (dolist (section (list (cons "Required" required) (cons "Optional" optional)))
            (princ (format "%s\n" (car section)))
            (dolist (fact (cdr section))
              (princ (format "  %s: %s\n" (car fact) (if (cadr fact) "available" "unavailable")))
              (unless (cadr fact) (princ (format "    %s\n" (nth 2 fact)))))
            (princ "\n"))
          (princ "Install: M-x etaf-install\nUpdate/remove: M-x list-packages\nRestart Emacs after upgrading loaded packages.\n")))
      result)))

(defun etaf-install--archive ()
  "Register the configured archive without changing other sources or policies."
  (unless (or (string-prefix-p "https://" etaf-install-archive-url)
              (and (file-name-absolute-p etaf-install-archive-url)
                   (file-directory-p etaf-install-archive-url)))
    (user-error "ETAF archive must use HTTPS or an existing local directory"))
  (let ((url (file-name-as-directory etaf-install-archive-url)))
    (setq package-archives
          (cons (cons "etaf" url)
                (cl-remove "etaf" package-archives :key #'car :test #'equal)))))

(defun etaf-install--check-source (package)
  "Refuse unresolved source code or a preloaded checkout for PACKAGE."
  (let* ((library (locate-library (symbol-name package)))
         (loaded (car (cl-find-if
                       (lambda (entry) (member (cons 'provide package) (cdr entry)))
                       load-history)))
         (installed (cdr (assq package package-alist))))
    (dolist (file (delete-dups (delq nil (list library loaded))))
      (unless (cl-some (lambda (descriptor)
                         (let ((directory (package-desc-dir descriptor)))
                           (and directory (file-in-directory-p file directory))))
                       installed)
        (user-error "%s already comes from %s; keep that installation or remove its load-path entry and restart before using package.el"
                    package file)))))

(defun etaf-install--check-plan (descriptor &optional installed-only)
  "Check sources in DESCRIPTOR's dependency closure.
INSTALLED-ONLY checks offline reopening without computing an upgrade plan."
  (let* ((plan (unless installed-only
                 (package-compute-transaction
                  (list descriptor) (package-desc-reqs descriptor))))
         (pending (list descriptor))
         seen)
    (dolist (item plan)
      (when (and (featurep (package-desc-name item))
                 (not (package-installed-p (package-desc-name item)
                                           (package-desc-version item))))
        (user-error "A newer %s is required; restart Emacs and install before opening ETAF"
                    (package-desc-name item))))
    (while pending
      (let* ((item (pop pending))
             (name (package-desc-name item)))
        (unless (memq name seen)
          (push name seen)
          (etaf-install--check-source name)
          (dolist (requirement (package-desc-reqs item))
            (let ((dependency (or (cl-find (car requirement) plan :key #'package-desc-name)
                                  (cadr (assq (car requirement) package-alist)))))
              (when dependency (push dependency pending)))))))))

(defun etaf-install--added-packages (before)
  "Return descriptors added to `package-alist' since BEFORE."
  (cl-loop for (_ . descriptors) in package-alist
           append (cl-remove-if
                   (lambda (descriptor)
                     (cl-find (package-desc-full-name descriptor) before
                              :key #'package-desc-full-name :test #'equal))
                   descriptors)))

;;;###autoload
(defun etaf-install (&optional package no-open)
  "Install supported PACKAGE and open it unless NO-OPEN is non-nil."
  (interactive (list (etaf-install--read-target)))
  (when etaf-install--busy
    (user-error "An ETAF installation is already running in this Emacs"))
  (when etaf-install--restart-required
    (user-error "Restart Emacs before retrying; a failed installation left partially loaded Lisp"))
  (let* ((package (or package 'etaf-ui))
         (target (etaf-install--target package))
         (facts (etaf-install-doctor package))
         (etaf-install--busy t))
    (dolist (fact (plist-get facts :required))
      (unless (cadr fact) (user-error "%s: %s" (car fact) (nth 2 fact))))
    (unless package--initialized (package-initialize))
    (etaf-install--check-source package)
    (unless (package-installed-p package)
      (etaf-install--archive)
      (message "ETAF: checking the official package archive…")
      ;; Scope the refresh to ETAF without discarding the user's other archive
      ;; configuration.  No global signature setting or proxy is rewritten.
      (let ((package-archives (list (assoc "etaf" package-archives))))
        (package-refresh-contents))
      (let* ((descriptor (cadr (assq package package-archive-contents)))
             (before (apply #'append (mapcar #'cdr package-alist)))
             (selected (copy-sequence package-selected-packages)))
        (unless (and descriptor (equal (package-desc-archive descriptor) "etaf"))
          (user-error "ETAF archive did not provide %s; check the connection and run M-x etaf-install again" package))
        (etaf-install--check-plan descriptor)
        (condition-case error-data
            (progn
              (message "ETAF: installing %s and its dependencies…" package)
              ;; Do not persist selected-package configuration until the
              ;; installation and its entry load have actually succeeded.
              (package-install descriptor t)
              (unless (package-installed-p package)
                (error "Package installation did not activate %s" package))
              (require package)
              (package-install descriptor))
          ((error quit)
           ;; package.el keeps old versions. Remove only newly added versions,
           ;; not user data, existing installations or unrelated packages.
           (setq etaf-install--restart-required t
                 package-selected-packages selected)
           (dolist (added (etaf-install--added-packages before))
             (condition-case cleanup-error
                 (package-delete added t t)
               (error
                (message "ETAF cleanup failed for %s: %s; remove it with M-x list-packages after restarting"
                         (package-desc-full-name added) (error-message-string cleanup-error)))))
           (message "ETAF installation failed; previous packages were kept. Restart Emacs before retrying.")
           (signal (car error-data) (cdr error-data))))))
    (etaf-install--check-plan (cadr (assq package package-alist)) t)
    (require package)
    (when (and (not no-open) (nth 2 target))
      (call-interactively (nth 2 target)))
    (message "ETAF: %s is ready.  M-x etaf-install opens installed targets without downloading again." package)
    package))

(provide 'etaf-install)
;;; etaf-install.el ends here
