;;; -*- lexical-binding: t; -*-
;;; install-smoke.el --- Verify a package archive without source checkouts

;;; Commentary:
;; The release runner starts this file in a fresh Emacs -Q process.  Both the
;; archive and the disposable profile must be supplied explicitly.  It never
;; initializes the user's packages, reads their init, or adds source load paths.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'json)

(defun etaf-install-smoke-refresh ()
  "Refresh archives, retrying once when a registered archive came back empty.
Network fetches of a large third-party archive fail intermittently; a missing
archive would otherwise look like an unavailable dependency."
  (package-refresh-contents)
  (let ((missing (cl-remove-if
                  (lambda (archive)
                    (or (equal (car archive) "etaf")
                        (cl-some (lambda (entry)
                                   (equal (package-desc-archive (cadr entry)) (car archive)))
                                 package-archive-contents)))
                  package-archives)))
    (when missing
      (sleep-for 5)
      (package-refresh-contents))))

(defvar etaf-install-archive-url)

(declare-function etaf-install "etaf-install" (&optional package no-open))
(declare-function etaf-install-doctor "etaf-install" (&optional package))
(declare-function etaf-ui-gallery-open "etaf-ui" (&optional buffer-or-name))
(declare-function etaf-manual-book "etaf-manual" (&optional language))
(declare-function etaf-unmount "etaf" (&optional runtime))
(declare-function etaf-runtime-for-buffer "etaf" (buffer-or-name))
(declare-function etaf-runtime-host-props-entries "etaf" (runtime))
(declare-function etaf-runtime-refit "etaf" (runtime viewport-width &optional viewport-height))
(declare-function etaf-scroll-into-view "etaf" (runtime host-ref &optional align))
(declare-function etaf-focus "etaf" (&optional runtime host-ref))
(declare-function etaf-activate "etaf" (&optional runtime))
(declare-function ekp-hyphen-create "ekp" (&optional lang file left right))
(declare-function etaf-sqlite-column "etaf-db" (id sql-name &rest options))
(declare-function etaf-sqlite-table "etaf-db" (id columns &optional primary-key))
(declare-function etaf-sqlite-database "etaf-db" (file table))
(declare-function etaf-sqlite-initialize "etaf-db" (database))

(let* ((archive (getenv "ETAF_INSTALL_ARCHIVE"))
       (profile (getenv "ETAF_INSTALL_PROFILE"))
       (target (intern (or (getenv "ETAF_INSTALL_TARGET") "etaf-ui")))
       (direct (getenv "ETAF_INSTALL_DIRECT")))
  (unless (and archive profile (file-directory-p profile))
    (error "Set ETAF_INSTALL_ARCHIVE and a disposable ETAF_INSTALL_PROFILE"))
  (setq user-emacs-directory (file-name-as-directory profile)
        package-user-dir (expand-file-name "elpa" profile)
        custom-file (expand-file-name "custom.el" profile)
        package-directory-list nil
        ;; Mirror the archives the installer registers: a direct
        ;; `package-install` of a target that depends on a package from a
        ;; standard archive needs the same sources.
        package-archives (list (cons "etaf" (file-name-as-directory archive))
                               '("gnu" . "https://elpa.gnu.org/packages/")
                               '("nongnu" . "https://elpa.nongnu.org/nongnu/")
                               '("melpa" . "https://melpa.org/packages/"))
        native-comp-jit-compilation nil
        print-circle t print-length 30 print-level 6)
  (package-initialize)
  (etaf-install-smoke-refresh)
  (if direct
      (progn (package-install target) (require target))
    (package-install 'etaf-install)
    (require 'etaf-install)
    (setq etaf-install-archive-url (file-name-as-directory archive))
    (etaf-install target (not (eq target 'etaf-ui)))
    ;; Framework targets must be usable immediately. An application's external
    ;; tools are runtime capabilities: the package installs, opening waits.
    (when (memq target '(etaf-ui etaf etaf-manual ekp etaf-db))
      (unless (plist-get (etaf-install-doctor target) :ready)
        (error "Installed target is missing required capabilities"))))
  (dolist (entry package-alist)
    (let ((library (locate-library (symbol-name (car entry)))))
      (unless (and library (file-in-directory-p library package-user-dir))
        (error "Installed package escaped the disposable profile: %s" (car entry)))))
  ;; Opening an installed target must not refresh or download again.
  (unless direct
    (let ((etaf-install-archive-url "/nonexistent-offline-archive/"))
      (etaf-install target (not (eq target 'etaf-ui)))))
  (when (featurep 'etaf)
    (eval
     '(let ((value (etaf-ref "before"))
            (buffer (generate-new-buffer " *etaf-install-smoke*")))
        (unwind-protect
            (progn
              (etaf-mount buffer (etaf-view (text (expr (etaf-value value)))))
              (setf (etaf-value value) "after")
              (with-current-buffer buffer
                (etaf-runtime-flush)
                (unless (string-match-p "after" (buffer-substring-no-properties (point-min) (point-max)))
                  (error "Installed reactive rendering failed"))))
          (with-current-buffer buffer (etaf-unmount))
          (kill-buffer buffer)))
     t))
  (when (eq target 'etaf-ui)
    (when direct (call-interactively #'etaf-ui-gallery-open))
    (let ((buffer (get-buffer "*ETAF UI Gallery*")))
      (unless buffer (error "Installed entry did not open the gallery"))
      (unwind-protect
          (with-current-buffer buffer
            (unless (> (buffer-size) 100)
              (error "Installed component gallery did not render"))
            (let ((runtime (etaf-runtime-for-buffer buffer))
                  (interprogram-cut-function nil)
                  (kill-ring nil))
              ;; Use the wide category controls for this copy-and-run workflow;
              ;; the entry above still opens at the actual batch frame size.
              (etaf-runtime-refit runtime (* 160 (frame-char-width)) 80)
              (dolist (label '("基础与操作" "查看用法：etaf-button" "复制示例：etaf-button"))
                (let* ((entry (cl-find-if
                               (lambda (entry)
                                 (equal label (plist-get (cdr entry) :aria-label)))
                               (etaf-runtime-host-props-entries runtime)))
                       (ref (car entry)))
                  (unless ref (error "Installed gallery control is missing: %s" label))
                  (etaf-scroll-into-view runtime ref)
                  (etaf-focus runtime ref)
                  (etaf-activate runtime)))
              (let ((source (current-kill 0 t)))
                (unless (string-prefix-p ";;; -*- lexical-binding: t; -*-" source)
                  (error "Installed gallery did not copy a standalone example"))
                (unwind-protect
                    (save-window-excursion
                      (with-temp-buffer
                        (insert source)
                        (let ((lexical-binding t)) (eval-buffer)))
                      (unless (etaf-runtime-for-buffer "*ETAF UI Example*")
                        (error "Copied installed example did not mount")))
                  (when-let* ((example (get-buffer "*ETAF UI Example*")))
                    (when-let* ((mounted (etaf-runtime-for-buffer example)))
                      (etaf-unmount mounted))
                    (kill-buffer example))))))
        (with-current-buffer buffer (etaf-unmount))
        (kill-buffer buffer))))
  (when (memq target '(etaf-md-preview etaf-video-player etaf-desktop etaf-telega))
    ;; Applications install and load like any package; their external tools are
    ;; runtime capabilities, so a missing ffmpeg must not fail the install gate.
    (require target)
    (let ((open (intern (format "%s-open" target))))
      (unless (fboundp open)
        (error "Installed %s does not provide %s" target open)))
    (when (fboundp (intern (format "%s-doctor" target)))
      (let ((facts (funcall (intern (format "%s-doctor" target)))))
        (dolist (section '(:required :optional))
          (dolist (fact (plist-get facts section))
            (unless (and (listp fact) (stringp (car fact)) (nth 2 fact))
              (error "%s-doctor returned a malformed fact: %S" target fact)))))))
  (when (eq target 'etaf-manual)
    (unless (plist-get (etaf-manual-book "en") :chapters)
      (error "Installed reference manual has no book data")))
  (when (eq target 'ekp)
    (unless (ekp-hyphen-create "en")
      (error "Installed paragraph layout has no English dictionary")))
  (when (eq target 'etaf-db)
    (let* ((file (expand-file-name "installation.sqlite" profile))
           (table (etaf-sqlite-table
                   'installation
                   (list (etaf-sqlite-column 'id "id" :type 'integer)) 'id)))
      (etaf-sqlite-initialize (etaf-sqlite-database file table))
      (unless (file-regular-p file) (error "Installed SQLite backend did not initialize"))))
  (princ (json-encode (list :status "ok" :emacs emacs-version
                           :system (symbol-name system-type) :target (symbol-name target)
                           :entry (if direct "package-install" "etaf-install")
                           :packages (mapcar (lambda (entry) (symbol-name (car entry))) package-alist)))))

;;; install-smoke.el ends here
