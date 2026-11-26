;;; -*- lexical-binding: t; -*-
;;; install-smoke.el --- Verify a package archive without source checkouts

;;; Commentary:
;; The release runner starts this file in a fresh Emacs -Q process.  Both the
;; archive and the disposable profile must be supplied explicitly.  It never
;; initializes the user's packages, reads their init, or adds source load paths.
;;
;; ETAF_INSTALL_DIRECT is read with `getenv`: any non-nil value, including
;; the empty string, selects ordinary `package-install`.  Unset it
;; (`env -u ETAF_INSTALL_DIRECT`) when the same profile must exercise the
;; `etaf-install` path.
;;
;; ETAF_INSTALL_STANDARD_ARCHIVES points GNU, NonGNU and MELPA at a prefetched
;; snapshot served locally by the CI runner.  The runner fetches one live
;; snapshot per workflow run; every target then installs from that snapshot
;; instead of re-fetching a rate-limited third-party archive.  Without it the
;; live archives are used, as in a developer's focused verification.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'json)

(defvar etaf-install-smoke-standard-archives
  (getenv "ETAF_INSTALL_STANDARD_ARCHIVES")
  "Base URL of a prefetched standard archive snapshot, or nil.")

(defun etaf-install-smoke-standard-archive (name default)
  "Return the standard archive URL for NAME, preferring the local snapshot."
  (if etaf-install-smoke-standard-archives
      (concat (file-name-as-directory etaf-install-smoke-standard-archives)
              name "/")
    default))

(defun etaf-install-smoke-refresh ()
  "Refresh archives, retrying while a registered archive came back empty.
Network fetches of a large third-party archive fail intermittently; a missing
archive would otherwise look like an unavailable dependency.  Four attempts
with growing pauses cover a short outage without hiding one that persists.  A
prefetched snapshot is local: an empty archive there is a snapshot defect, so
report it immediately instead of retrying and hiding it."
  (let ((attempt 0) missing last-error)
    (while (progn
             ;; A failed archive fetch can signal instead of only reporting an
             ;; empty contents; a retry is the response either way.
             (condition-case error
                 (package-refresh-contents)
               (error
                (setq last-error error)
                (message "Archive refresh attempt %d failed: %s"
                         (1+ attempt) (error-message-string error))))
             (setq attempt (1+ attempt)
                   missing (cl-remove-if
                            (lambda (archive)
                              (or (equal (car archive) "etaf")
                                  (cl-some (lambda (entry)
                                             (equal (package-desc-archive (cadr entry))
                                                    (car archive)))
                                           package-archive-contents)))
                            package-archives))
             (and missing
                  (< attempt (if etaf-install-smoke-standard-archives 1 4))))
      (message "Retrying empty archives in %d seconds: %S" (* 5 attempt) missing)
      (sleep-for (* 5 attempt)))
    (when missing
      (if etaf-install-smoke-standard-archives
          (error "Prefetched standard archives are incomplete: %S%s"
                 missing
                 (if last-error
                     (format " (%s)" (error-message-string last-error))
                   ""))
        ;; An empty archive that this target does not need must not fail the
        ;; installation; a needed dependency still fails with package.el's own
        ;; message.  Name what stayed empty so a flaky network is visible.
        (message "Archives still empty after %d attempts: %S" attempt missing)))))

(defvar etaf-install-archive-url)
(defvar etaf-install-native-directory)
(defvar etaf-install-native-url)

(declare-function etaf-install "etaf-install" (&optional package no-open))
(declare-function etaf-install-doctor "etaf-install" (&optional package))
(declare-function etaf-install-status "etaf-install" (&optional package))
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
(declare-function etaf-posframe-theme "etaf-posframe" (frame))

(let* ((archive (getenv "ETAF_INSTALL_ARCHIVE"))
       (profile (getenv "ETAF_INSTALL_PROFILE"))
       (target (intern (or (getenv "ETAF_INSTALL_TARGET") "etaf-ui")))
       (direct (getenv "ETAF_INSTALL_DIRECT"))
       (native-url (getenv "ETAF_INSTALL_NATIVE_URL")))
  (unless (and archive profile (file-directory-p profile))
    (error "Set ETAF_INSTALL_ARCHIVE and a disposable ETAF_INSTALL_PROFILE"))
  (setq user-emacs-directory (file-name-as-directory profile)
        package-user-dir (expand-file-name "elpa" profile)
        custom-file (expand-file-name "custom.el" profile)
        etaf-install-native-directory (expand-file-name "native-cache" profile)
        package-directory-list nil
        ;; Mirror the archives the installer registers: a direct
        ;; `package-install` of a target that depends on a package from a
        ;; standard archive needs the same sources.
        package-archives
        (list (cons "etaf" (file-name-as-directory archive))
              (cons "gnu" (etaf-install-smoke-standard-archive
                            "gnu" "https://elpa.gnu.org/packages/"))
              (cons "nongnu" (etaf-install-smoke-standard-archive
                               "nongnu" "https://elpa.nongnu.org/nongnu/"))
              (cons "melpa" (etaf-install-smoke-standard-archive
                              "melpa" "https://melpa.org/packages/")))
        native-comp-jit-compilation nil
        print-circle t print-length 30 print-level 6)
  (package-initialize)
  (etaf-install-smoke-refresh)
  (if direct
      (progn (package-install target) (require target))
    (package-install 'etaf-install)
    (require 'etaf-install)
    (setq etaf-install-archive-url (file-name-as-directory archive)
          etaf-install-native-directory (expand-file-name "native-cache" profile)
          etaf-install-native-url (and native-url (not (string-empty-p native-url)) native-url))
    (etaf-install target (not (eq target 'etaf-ui)))
    (when (and etaf-install-native-url
               (memq target '(etaf-md etaf ekp etaf-video-player)))
      (let ((status (etaf-install-status target)))
        (unless (eq (plist-get status :native) 'installed)
          (error "etaf-install did not automatically install native modules for %s: %S"
                 target status))))
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
    (let ((etaf-install-archive-url "/nonexistent-offline-archive/")
          (etaf-install-native-url nil))
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
  (when (memq target '(etaf-md etaf-org etaf-video-player etaf-desktop
                   etaf-telega etaf-xiangqi etaf-tanks etaf-weread etaf-ncm
                   etaf-pomodoro maillist))
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
  ;; Packages that ship a native module manifest must install it intact.
  (when (memq target '(etaf-md etaf ekp))
    (let* ((desc (cadr (assq target package-alist)))
           (dir (and desc (package-desc-dir desc)))
           (manifest (and dir (expand-file-name "native/manifest.json" dir))))
      (unless (and manifest (file-readable-p manifest))
        (error "Installed %s is missing native/manifest.json" target))
      (let ((doc (with-temp-buffer
                   (insert-file-contents manifest)
                   (json-parse-buffer :object-type 'hash-table :array-type 'list))))
        (unless (and (eql (gethash "schema" doc) 1)
                     (equal (gethash "package" doc) (symbol-name target))
                     (consp (gethash "modules" doc)))
          (error "Installed %s has malformed native/manifest.json" target)))))
  (when (eq target 'etaf-md)
    (let* ((desc (cadr (assq 'etaf-md package-alist)))
           (dir (and desc (package-desc-dir desc))))
      (dolist (unexpected '("Makefile"
                            "tests"
                            "benchmarks"
                            "examples"
                            "scripts"
                            "native/vendor"
                            "native/build"))
        (when (file-exists-p (expand-file-name unexpected dir))
          (error "Installed etaf-md should not ship %s" unexpected)))
      (dolist (expected '("docs/manual.md"
                          "docs/extensions.md"
                          "backends/mermaid-render.mjs"
                          "native/manifest.json"))
        (unless (file-readable-p (expand-file-name expected dir))
          (error "Installed etaf-md is missing %s" expected)))
      (let* ((facts (funcall (intern "etaf-md-doctor")))
             (native-fact (assoc "typeset-native" (plist-get facts :optional))))
        (unless native-fact
          (error "Installed etaf-md-doctor is missing typeset-native"))
        (when (string-match-p "make native-build" (nth 2 native-fact))
          (error "Installed etaf-md-doctor still references unshipped make native-build")))
      ;; Rendering a document with Mermaid and display math must degrade cleanly
      ;; in a fresh archive install before the optional native binary is fetched.
      (eval
       '(let* ((session (etaf-md-create
                         :text "# Archive Smoke\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\n$$\nx^2 + y^2 = z^2\n$$\n"))
               (buffer (etaf-mount (generate-new-buffer " *etaf-md-install-smoke*")
                                   (etaf-md-view session)
                                   '(:viewport-width 96 :viewport-height 40))))
          (unwind-protect
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (unless (string-match-p "Archive Smoke" text)
                    (error "Installed etaf-md failed to render heading"))))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (etaf-unmount))
              (kill-buffer buffer))))
       t)))
  (when (eq target 'etaf-org)
    (let* ((desc (cadr (assq 'etaf-org package-alist)))
           (dir (and desc (package-desc-dir desc))))
      (dolist (unexpected '("Makefile"
                            "tests"
                            "benchmarks"
                            "examples"
                            "scripts"))
        (when (file-exists-p (expand-file-name unexpected dir))
          (error "Installed etaf-org should not ship %s" unexpected)))
      (dolist (expected '("docs/manual.md"
                          "docs/extensions.md"
                          "backends/mermaid-render.mjs"))
        (unless (file-readable-p (expand-file-name expected dir))
          (error "Installed etaf-org is missing %s" expected)))))
  (when (eq target 'etaf-manual)
    (unless (plist-get (etaf-manual-book "en") :chapters)
      (error "Installed reference manual has no book data")))
  (when (eq target 'etaf-posframe)
    ;; A panel cannot open without a display, but its palette must resolve from
    ;; the frame it would be placed on: that is what the package is for.
    (let ((theme (etaf-posframe-theme (selected-frame))))
      (unless (and (stringp (plist-get theme :ui-panel-bg))
                   (stringp (plist-get theme :ui-panel-fg)))
        (error "Installed panel host cannot derive a palette: %S" theme))))
  (when (eq target 'ekp)
    (unless (ekp-hyphen-create "en")
      (error "Installed paragraph layout has no English dictionary")))
  (when (eq target 'etaf-ext)
    (require 'etaf-ext)
    (dolist (sym '(etaf-ext-manage etaf-ext-dispatch etaf-ext-command-palette etaf-ext-list))
      (unless (fboundp sym)
        (error "Installed etaf-ext does not provide %s" sym))))
  (when (memq target '(etaf-hints etaf-highlight etaf-translate etaf-export))
    (require target)
    (unless (memq target (funcall (intern "etaf-ext-list")))
      (error "Installed extension %s did not register in etaf-ext" target))
    (when (fboundp (intern (format "%s-doctor" target)))
      (let ((facts (funcall (intern (format "%s-doctor" target)))))
        (dolist (section '(:required :optional))
          (dolist (fact (plist-get facts section))
            (unless (and (listp fact) (stringp (car fact)) (nth 2 fact))
              (error "%s-doctor returned a malformed fact: %S" target fact)))))))
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
