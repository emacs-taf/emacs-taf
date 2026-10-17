;;; -*- lexical-binding: t; -*-
;;; etaf-install.el --- Install ETAF with the Emacs package manager

;; Version: 0.2.0
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
;; Interactive use offers the supported targets grouped as framework,
;; applications and games, with the component gallery as the default.  Each
;; target may expose a `<package>-doctor' returning the same :required and
;; :optional facts as `etaf-install-doctor', which are merged into its report.  NO-OPEN suppresses opening, for batch installation.  Return the
;; installed package symbol.  Already installed targets can be opened offline.
;; Missing mandatory Emacs capabilities or a conflicting source checkout signal
;; user-error before installation.  An upgrade of a loaded dependency also
;; requires a restart before installation. On failure, remove only packages added
;; by this attempt, preserving older installations and unrelated packages. Report
;; cleanup failures without hiding the installation error. Restart before retrying
;; because partially loaded Lisp cannot be safely rolled back in this process.
;; Use M-x etaf-install-manage for the supported lifecycle; package.el owns
;; upgrades and removal.  Restart Emacs after upgrading loaded packages.
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
;; Function: etaf-install-manage ()
;; Show installed and available ETAF targets in a native tabulated list.  The
;; buffer supports install, update, remove, open, doctor and refresh through
;; package.el; it is the supported lifecycle entry for ETAF targets.
;;
;; Function: etaf-install-update (&optional package)
;; Refresh the ETAF and standard archives and upgrade PACKAGE, or every
;; installed target plus the installer.  Return a report.  Restart Emacs when
;; an update replaces loaded Lisp.
;;
;; Function: etaf-install-remove (package &optional no-confirm)
;; Remove PACKAGE's package files and its `package-selected-packages' entry.
;; Application data, logins and caches are kept; shared dependencies remain.
;;
;; Function: etaf-install-status (&optional package)
;; Return installed and available versions, the update flag and runtime facts
;; for PACKAGE or every supported target.
;;
;; Setup once using the installation block in the workspace README, then use
;; M-x etaf-install.  Credentials and external application backends are outside
;; this installer's scope.  It offers only targets with a verified Lisp install.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'subr-x)
(require 'tabulated-list)

(defgroup etaf-install nil
  "Install the ETAF framework and its Lisp applications."
  :group 'applications)

(defcustom etaf-install-archive-url "https://etaf.top/packages/"
  "ETAF package archive URL, or an absolute local archive directory."
  :type 'string
  :group 'etaf-install)

(defconst etaf-install--targets
  '((etaf-ui "ETAF components and gallery" framework etaf-ui-gallery-open)
    (etaf "ETAF framework" framework nil)
    (etaf-db "ETAF SQLite backend" framework nil sqlite)
    (ekp "Knuth-Plass paragraph layout" framework nil)
    (etaf-md-preview "Markdown reading view" application etaf-md-preview-open)
    (etaf-video-player "Video with sound in a buffer" application etaf-video-player-open)
    (etaf-desktop "Windows and workspaces" application etaf-desktop-open)
    (etaf-manual "ETAF reference manual" application etaf-manual-open)
    ;; MELPA supplies Telega and Transient; Transient needs Compat from GNU ELPA.
    (etaf-telega "Telegram client" application etaf-telega-open melpa gnu)
    (etaf-weread "WeChat Reading" application etaf-weread-open)
    (etaf-ncm "NetEase Cloud Music" application etaf-ncm-open)
    (etaf-xiangqi "Xiangqi" game etaf-xiangqi-open)
    (etaf-tanks "Tank battle" game etaf-tanks-open))
  "Installable targets as (PACKAGE LABEL GROUP OPEN &rest CAPABILITIES).
GROUP groups the menu: `framework', `application' or `game'.  OPEN is the
command that presents the installed target, or nil.  CAPABILITIES lists extra
required features, such as `sqlite'.")

(defconst etaf-install--extra-archives
  '((gnu . "https://elpa.gnu.org/packages/")
    (nongnu . "https://elpa.nongnu.org/nongnu/")
    (melpa . "https://melpa.org/packages/"))
  "Standard archives a target may declare as a capability, keyed by symbol.
They are registered only for the target that needs them, and stay registered
so the ETAF manager and later upgrades through `M-x list-packages` resolve them.")
(defvar etaf-install--busy nil)
(defvar etaf-install--restart-required nil)
(defvar etaf-install--restart-needed nil
  "Non-nil when an update replaced loaded Lisp; restart before using it.")

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

(defconst etaf-install--group-labels
  '((framework . "Framework") (application . "Application") (game . "Game"))
  "Menu prefix for each target group.")

(defun etaf-install--target-choices ()
  "Return completion candidates as (LABEL . PACKAGE), grouped in menu order."
  (let (choices)
    (dolist (group '(framework application game))
      (dolist (target (cl-remove-if-not (lambda (entry) (eq (nth 2 entry) group))
                                  etaf-install--targets))
        (push (cons (format "%s — %s (%s)"
                            (car target) (nth 1 target)
                            (cdr (assq group etaf-install--group-labels)))
                    (car target))
              choices)))
    (nreverse choices)))

(defun etaf-install--read-target ()
  "Read a supported package with standard Emacs completion."
  (let* ((choices (etaf-install--target-choices))
         (choice (completing-read "Install: " (mapcar #'car choices)
                                  nil t nil nil (caar choices))))
    (or (cdr (assoc choice choices))
        (user-error "No installation target selected"))))

(defun etaf-install--display-doctor (package &optional facts)
  "Show PACKAGE's doctor FACTS in a standard help buffer."
  (let* ((facts (or facts (etaf-install-doctor package)))
         (required (plist-get facts :required))
         (optional (plist-get facts :optional)))
    (with-help-window "*ETAF Installation*"
      (princ (format "ETAF installation: %s\nEmacs %s on %s\n\n"
                     package emacs-version system-type))
      (dolist (section (list (cons "Required" required) (cons "Optional" optional)))
        (princ (format "%s\n" (car section)))
        (dolist (fact (cdr section))
          (princ (format "  %s: %s\n" (car fact) (if (cadr fact) "available" "unavailable")))
          (unless (cadr fact) (princ (format "    %s\n" (nth 2 fact)))))
        (princ "\n"))
      (princ "Install: M-x etaf-install\nManage/update/remove: M-x etaf-install-manage\nRestart Emacs after upgrading loaded packages.\n"))))

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
    (when (fboundp (intern (format "%s-doctor" package)))
      (let ((facts (funcall (intern (format "%s-doctor" package)))))
        (setq required (append required (plist-get facts :required))
              optional (append optional (plist-get facts :optional)))))
    (when (memq 'sqlite (nthcdr 4 target))
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
        (etaf-install--display-doctor package result))
      result)))

(defun etaf-install--register-target-archives (package)
  "Register the standard archives PACKAGE's dependency closure needs."
  (dolist (capability (nthcdr 4 (etaf-install--target package)))
    (let ((archive (assq capability etaf-install--extra-archives)))
      (when (and archive (not (assoc (symbol-name (car archive)) package-archives)))
        (add-to-list 'package-archives
                     (cons (symbol-name (car archive)) (cdr archive)) t)))))

(defun etaf-install--register-installed-archives ()
  "Register standard archives for every installed ETAF target."
  (dolist (target etaf-install--targets)
    (when (package-installed-p (car target))
      (etaf-install--register-target-archives (car target)))))

(defun etaf-install--archive ()
  "Register the configured ETAF archive without changing other sources or policies."
  (unless (or (string-prefix-p "https://" etaf-install-archive-url)
              (and (file-name-absolute-p etaf-install-archive-url)
                   (file-directory-p etaf-install-archive-url)))
    (user-error "ETAF archive must use HTTPS or an existing local directory"))
  (let ((url (file-name-as-directory etaf-install-archive-url)))
    (setq package-archives
          (cons (cons "etaf" url)
                (cl-remove "etaf" package-archives :key #'car :test #'equal)))))

(defun etaf-install--refresh-archives (packages)
  "Refresh ETAF and the standard archives PACKAGES need.
PACKAGES may include the installer itself; only supported targets contribute
extra archives.  Refresh stays scoped so unrelated sources are untouched."
  (etaf-install--archive)
  (dolist (package packages)
    (when (assq package etaf-install--targets)
      (etaf-install--register-target-archives package)))
  (let* ((needed (cons "etaf"
                       (cl-loop for package in packages
                                when (assq package etaf-install--targets)
                                append (cl-loop for capability in (nthcdr 4 (etaf-install--target package))
                                                for archive = (assq capability etaf-install--extra-archives)
                                                when archive collect (symbol-name (car archive))))))
         (package-archives (cl-remove-if-not
                            (lambda (entry) (member (car entry) needed))
                            package-archives)))
    (package-refresh-contents)))

(defun etaf-install--built-in-file-p (file)
  "Return non-nil when FILE belongs to this Emacs's own Lisp tree."
  (and file
       (let ((directory (or (and (boundp 'lisp-directory) lisp-directory)
                            (expand-file-name "../lisp" data-directory))))
         (file-in-directory-p file (file-name-as-directory directory)))))

(defun etaf-install--check-source (package)
  "Refuse unresolved source code or a preloaded checkout for PACKAGE."
  (let* ((library (locate-library (symbol-name package)))
         (loaded (car (cl-find-if
                       (lambda (entry) (member (cons 'provide package) (cdr entry)))
                       load-history)))
         (installed (cdr (assq package package-alist))))
    (dolist (file (delete-dups (delq nil (list library loaded))))
      (unless (or (etaf-install--built-in-file-p file)
                  (cl-some (lambda (descriptor)
                             (let ((directory (package-desc-dir descriptor)))
                               (and directory (file-in-directory-p file directory))))
                           installed))
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
      ;; A loaded installed package must be restarted before its replacement
      ;; can be used.  A built-in is always loaded; install its replacement for
      ;; the next session instead of aborting before this one can finish.
      (when (and (featurep (package-desc-name item))
                 (not (package-installed-p (package-desc-name item)
                                           (package-desc-version item)))
                 (not (package-built-in-p (package-desc-name item))))
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
    ;; Only installation prerequisites stop the install: an Emacs that is too old
    ;; and the SQLite capability the package is compiled against. A target's own
    ;; runtime tools are reported after installation instead of blocking it.
    (dolist (fact (plist-get facts :required))
      (when (member (car fact) '("Emacs 29.1 or newer" "SQLite built into Emacs"))
        (unless (cadr fact) (user-error "%s: %s" (car fact) (nth 2 fact)))))
    (unless package--initialized (package-initialize))
    (etaf-install--check-source package)
    (unless (package-installed-p package)
      (message "ETAF: checking the official package archive…")
      ;; Scope the refresh to ETAF without discarding the user's other archive
      ;; configuration.  No global signature setting or proxy is rewritten.
      (etaf-install--refresh-archives (list package))
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
    (let ((missing (cl-remove-if #'cadr (plist-get (etaf-install-doctor package) :required))))
      (if missing
          (message "ETAF: %s is installed. Missing for use: %s"
                   package
                   (mapconcat (lambda (fact) (format "%s (%s)" (car fact) (nth 2 fact)))
                              missing "; "))
        (when (and (not no-open) (nth 3 target))
          (call-interactively (nth 3 target)))))
    (message "ETAF: %s is ready.  M-x etaf-install opens installed targets; M-x etaf-install-manage updates or removes them." package)
    package))

;;; Target management

(defun etaf-install--version-string (version)
  "Return VERSION as a dotted string, or nil."
  (and version (package-version-join version)))

(defun etaf-install--installed-version (package)
  "Return PACKAGE's installed version list, or nil."
  (when (package-installed-p package)
    (let ((descriptor (cadr (assq package package-alist))))
      (and descriptor (package-desc-version descriptor)))))

(defun etaf-install--available-version (package)
  "Return PACKAGE's archive version list, or nil."
  (let ((descriptor (cadr (assq package package-archive-contents))))
    (and descriptor (package-desc-version descriptor))))

(defun etaf-install--installed-targets ()
  "Return installed supported targets in menu order."
  (cl-loop for target in etaf-install--targets
           when (package-installed-p (car target))
           collect (car target)))

(defun etaf-install--dependency-names (descriptor)
  "Return DESCRIPTOR's package dependency closure as symbols.
Follow archive descriptors so a target such as Telega shows its MELPA/GNU
dependencies rather than only direct requirements."
  (let ((seen nil) (names nil) (pending (list descriptor)))
    (while pending
      (dolist (requirement (package-desc-reqs (pop pending)))
        (let ((name (car requirement)))
          (unless (or (eq name 'emacs) (memq name seen))
            (push name seen)
            (push name names)
            (let ((dependency (cadr (assq name package-archive-contents))))
              (when dependency (push dependency pending)))))))
    (nreverse names)))

(defun etaf-install--target-runtime (package)
  "Return PACKAGE's runtime readiness label."
  (let* ((facts (etaf-install-doctor package))
         (missing (cl-find-if (lambda (fact) (not (cadr fact)))
                              (plist-get facts :required))))
    (if missing
        (format "%s missing" (car missing))
      "Ready")))

(defun etaf-install--target-status (package)
  "Return a status plist for PACKAGE."
  (let* ((target (etaf-install--target package))
         (installed (etaf-install--installed-version package))
         (available (etaf-install--available-version package))
         (installed-p (not (null installed)))
         (update (and installed available (version-list-< installed available)))
         (runtime (if installed-p (etaf-install--target-runtime package) "—"))
         (descriptor (or (cadr (assq package package-archive-contents))
                         (cadr (assq package package-alist)))))
    (list :package package
          :label (nth 1 target)
          :group (nth 2 target)
          :installed (etaf-install--version-string installed)
          :available (etaf-install--version-string available)
          :installed-p installed-p
          :update update
          :ready (and installed-p (equal runtime "Ready"))
          :runtime runtime
          :dependencies (and descriptor (etaf-install--dependency-names descriptor)))))

;;;###autoload
(defun etaf-install-status (&optional package)
  "Return status plists for PACKAGE, or for every supported target.
Each plist has :package, :label, :group, :installed, :available,
:installed-p, :update, :ready, :runtime and :dependencies."
  (unless package--initialized (package-initialize))
  (if package
      (etaf-install--target-status package)
    (mapcar #'etaf-install--target-status
            (mapcar #'car etaf-install--targets))))

(defun etaf-install--read-installed-target (&optional prompt)
  "Read an installed target with completion."
  (unless package--initialized (package-initialize))
  (let ((installed (etaf-install--installed-targets)))
    (unless installed (user-error "No ETAF target is installed"))
    (intern (completing-read (or prompt "Target: ")
                             (mapcar #'symbol-name installed) nil t))))

;;;###autoload
(defun etaf-install-update (&optional package)
  "Update PACKAGE, or every installed target and the installer.
Refresh the ETAF archive and the standard archives installed targets need,
upgrade only installed ETAF packages, and return a plist with `:updated',
`:failed' and `:restart'.  Restart Emacs when a loaded package changes;
package.el remains the package manager."
  (interactive (list (unless current-prefix-arg
                       (etaf-install--read-installed-target "Update: "))))
  (unless package--initialized (package-initialize))
  (let* ((targets (if package (list package) (etaf-install--installed-targets)))
         (all (if package targets
                (if (package-installed-p 'etaf-install)
                    (cons 'etaf-install targets)
                  targets)))
         updated failed)
    (condition-case error
        (etaf-install--refresh-archives all)
      (error (push (cons 'archives (error-message-string error)) failed)))
    (unless failed
      (dolist (name all)
        (condition-case error
            (let ((installed (etaf-install--installed-version name))
                  (available (etaf-install--available-version name)))
              (when (and installed available (version-list-< installed available))
                (package-upgrade name)
                (push (cons name (etaf-install--version-string available)) updated)))
          (error (push (cons name (error-message-string error)) failed)))))
    (when updated
      (setq etaf-install--restart-needed t))
    (let ((report (list :updated (nreverse updated)
                        :failed (nreverse failed)
                        :restart (and updated t))))
      (when (called-interactively-p 'interactive)
        (message "ETAF: %s%s%s"
                 (if updated
                     (format "updated %s"
                             (mapconcat (lambda (item) (format "%s %s" (car item) (cdr item)))
                                        updated ", "))
                   "no updates")
                 (if failed (format "; %d failed" (length failed)) "")
                 (if updated "; restart Emacs to use it" "")))
      report)))

;;;###autoload
(defun etaf-install-remove (package &optional no-confirm)
  "Remove PACKAGE's package files and selection.
Application data, logins and caches are kept; shared dependencies remain
installed.  With NO-CONFIRM, skip the prompt."
  (interactive (list (etaf-install--read-installed-target "Remove: ")))
  (unless package--initialized (package-initialize))
  (etaf-install--target package)
  (unless (package-installed-p package)
    (user-error "%s is not installed" package))
  (unless (or no-confirm
              (y-or-n-p (format "Remove %s? Package files only; app data, logins and caches stay. "
                                package)))
    (user-error "Cancelled"))
  (let ((descriptor (cadr (assq package package-alist))))
    (package-delete descriptor)
    (setq package-selected-packages (delete package package-selected-packages))
    (message "ETAF: %s removed. App data, logins and caches were kept." package)
    package))

;;; The ETAF Packages buffer

(defvar-local etaf-install--manage-cache nil
  "Cached status plists for the ETAF Packages buffer.")

(defun etaf-install--manage-statuses ()
  "Return cached target status plists for this buffer."
  (or etaf-install--manage-cache
      (setq etaf-install--manage-cache (etaf-install-status))))

(defun etaf-install--manage-invalidate ()
  "Drop cached target status."
  (setq etaf-install--manage-cache nil))

(defun etaf-install--manage-status-cell (status)
  "Return the status cell for STATUS."
  (cond ((plist-get status :update)
         (concat (propertize "● " 'face 'font-lock-keyword-face)
                 (propertize "Update" 'face 'font-lock-keyword-face)))
        ((plist-get status :installed-p)
         (concat (propertize "● " 'face 'success)
                 (propertize "Installed" 'face 'success)))
        (t (concat (propertize "● " 'face 'shadow)
                   (propertize "Not installed" 'face 'shadow)))))

(defun etaf-install--manage-target-cell (status)
  "Return the target cell for STATUS."
  (concat (propertize (symbol-name (plist-get status :package)) 'face 'bold)
          " — "
          (propertize (plist-get status :label) 'face 'shadow)))

(defun etaf-install--manage-group-cell (status)
  "Return the group cell for STATUS."
  (or (cdr (assq (plist-get status :group) etaf-install--group-labels))
      (capitalize (symbol-name (plist-get status :group)))))

(defun etaf-install--manage-version-cell (version &optional update)
  "Return a version cell for VERSION, highlighting UPDATE availability."
  (let ((version (or version "—")))
    (if update
        (concat (propertize version 'face 'font-lock-keyword-face) " ↑")
      (propertize version 'face 'shadow))))

(defun etaf-install--manage-runtime-cell (status)
  "Return the runtime cell for STATUS."
  (let ((runtime (plist-get status :runtime)))
    (propertize runtime
                'face (cond ((equal runtime "Ready") 'success)
                            ((equal runtime "—") 'shadow)
                            (t 'warning)))))

(defun etaf-install--manage-dependency-cell (status)
  "Return the dependency cell for STATUS."
  (let ((dependencies (plist-get status :dependencies)))
    (propertize (if dependencies
                    (mapconcat #'symbol-name dependencies " · ")
                  "—")
                'face 'shadow)))

(defun etaf-install--manage-entries ()
  "Return tabulated-list entries for ETAF targets."
  (mapcar
   (lambda (status)
     (list (plist-get status :package)
           (vector (etaf-install--manage-status-cell status)
                   (etaf-install--manage-target-cell status)
                   (etaf-install--manage-group-cell status)
                   (etaf-install--manage-version-cell (plist-get status :installed)
                                                      (plist-get status :update))
                   (etaf-install--manage-version-cell (plist-get status :available)
                                                      (plist-get status :update))
                   (etaf-install--manage-runtime-cell status)
                   (etaf-install--manage-dependency-cell status))))
   (etaf-install--manage-statuses)))

(defvar etaf-install--manage-header-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'etaf-install--manage-refresh-from-header)
    (define-key map [header-line mouse-1] #'etaf-install--manage-refresh-from-header)
    map)
  "Mouse map for the ETAF Packages header button.")

(defun etaf-install--manage-header-line ()
  "Return the header line for the ETAF Packages buffer."
  (let* ((statuses (etaf-install--manage-statuses))
         (total (length statuses))
         (updates (cl-count-if (lambda (status) (plist-get status :update)) statuses))
         (installer (or (etaf-install--version-string
                         (etaf-install--installed-version 'etaf-install))
                        "dev"))
         (left (concat
                (propertize " ETAF Packages " 'face '(:weight bold :height 1.35))
                (propertize (format "  %d targets  " total) 'face 'shadow)
                (propertize (format "installer %s  " installer) 'face 'shadow)
                (if (> updates 0)
                    (propertize (format "● %d updates available  " updates)
                                'face 'font-lock-keyword-face)
                  (propertize "No updates  " 'face 'shadow))
                (when etaf-install--restart-needed
                  (propertize "● Restart required  " 'face 'warning))))
         (button (propertize " Refresh " 'face 'mode-line
                             'mouse-face 'highlight
                             'keymap etaf-install--manage-header-keymap
                             'help-echo "Refresh package archives (g)"))
         (padding (max 2 (- (window-width) (length left) (length button) 8))))
    (concat left (make-string padding ?\s) button)))

(defun etaf-install--manage-mode-line ()
  "Return the mode line for the ETAF Packages buffer."
  (let* ((statuses (etaf-install--manage-statuses))
         (installed (cl-count-if (lambda (status) (plist-get status :installed-p)) statuses))
         (updates (cl-count-if (lambda (status) (plist-get status :update)) statuses))
         (title " ETAF Packages  ")
         (summary (format "%d targets · %d installed · %d updates"
                          (length statuses) installed updates))
         (keys "i install · u update · U update all · d remove · RET open · ? doctor · g refresh · l list-packages · q quit")
         (padding (max 2 (- (window-width) (length title) (length summary)
                            (length keys) 2))))
    (concat title (propertize summary 'face 'shadow)
            (make-string padding ?\s)
            (propertize keys 'face 'shadow) " ")))

(define-derived-mode etaf-install--manage-header-mode special-mode "ETAF Header"
  "Major mode for the ETAF Packages header buffer."
  (setq-local mode-line-format nil)
  (setq-local header-line-format nil)
  (setq-local truncate-lines t))

(defun etaf-install--manage-update-header ()
  "Refresh the header buffer from the ETAF Packages table."
  (let ((header (get-buffer "*ETAF Packages Header*"))
        (table (get-buffer "*ETAF Packages*")))
    (when (and header table)
      (with-current-buffer header
        (setq etaf-install--manage-cache
              (with-current-buffer table (etaf-install--manage-statuses)))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (etaf-install--manage-header-line) "\n"
                  (propertize "Install, update, remove and open ETAF targets · package.el owns dependencies and byte compilation" 'face 'shadow) "\n"
                  (propertize "Remove deletes package files only; app data, logins and caches stay." 'face 'shadow)))))))

(defun etaf-install--manage-refresh-from-header ()
  "Refresh archives from the header window."
  (interactive)
  (let ((table (get-buffer "*ETAF Packages*")))
    (when table
      (with-current-buffer table
        (etaf-install--manage-refresh-archives)))))

(defun etaf-install--manage-show-current ()
  "Describe the target at point in the echo area."
  (let ((package (tabulated-list-get-id)))
    (when package
      (let ((status (cl-find package (etaf-install--manage-statuses)
                             :key (lambda (item) (plist-get item :package)))))
        (when status
          (message "%s — %s%s"
                   (plist-get status :label)
                   (plist-get status :runtime)
                   (if (plist-get status :dependencies)
                       (format " · %s"
                               (mapconcat #'symbol-name
                                          (plist-get status :dependencies) " · "))
                     "")))))))

(defun etaf-install--manage-current-target ()
  "Return the target at point or signal a user error."
  (or (tabulated-list-get-id)
      (user-error "No ETAF target on this line")))

(defun etaf-install--manage-reprint ()
  "Invalidate the cache and reprint the manage buffer."
  (etaf-install--manage-invalidate)
  (tabulated-list-revert)
  (etaf-install--manage-show-current))

(defun etaf-install--manage-install ()
  "Install the target at point."
  (interactive)
  (let ((package (etaf-install--manage-current-target)))
    (etaf-install package t)
    (etaf-install--manage-reprint)))

(defun etaf-install--manage-update ()
  "Update the target at point."
  (interactive)
  (let ((package (etaf-install--manage-current-target)))
    (etaf-install-update package)
    (etaf-install--manage-reprint)))

(defun etaf-install--manage-update-all ()
  "Update every installed target and the installer."
  (interactive)
  (when (y-or-n-p "Update all installed ETAF targets and the installer? ")
    (etaf-install-update)
    (etaf-install--manage-reprint)))

(defun etaf-install--manage-remove ()
  "Remove the target at point."
  (interactive)
  (let ((package (etaf-install--manage-current-target)))
    (etaf-install-remove package)
    (etaf-install--manage-reprint)))

(defun etaf-install--manage-open ()
  "Open the installed target at point."
  (interactive)
  (let* ((package (etaf-install--manage-current-target))
         (target (etaf-install--target package))
         (open (nth 3 target)))
    (unless (package-installed-p package)
      (user-error "%s is not installed" package))
    (unless open
      (user-error "%s has no open command" package))
    (call-interactively open)))

(defun etaf-install--manage-doctor ()
  "Show the doctor report for the target at point."
  (interactive)
  (etaf-install--display-doctor (etaf-install--manage-current-target)))

(defun etaf-install--manage-refresh-archives ()
  "Refresh the ETAF and installed targets' standard archives."
  (interactive)
  (unless package--initialized (package-initialize))
  (etaf-install--refresh-archives
   (cons 'etaf-install (etaf-install--installed-targets)))
  (etaf-install--manage-reprint)
  (message "ETAF: package archives refreshed"))

(defun etaf-install--manage-list-packages ()
  "Open the standard package menu."
  (interactive)
  (call-interactively #'list-packages))

(defun etaf-install--manage-quit ()
  "Quit the ETAF Packages window and its header."
  (interactive)
  (let ((header-window (get-buffer-window "*ETAF Packages Header*")))
    (when header-window
      (delete-window header-window)))
  (quit-window))

(defvar etaf-install--manage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "i") #'etaf-install--manage-install)
    (define-key map (kbd "u") #'etaf-install--manage-update)
    (define-key map (kbd "U") #'etaf-install--manage-update-all)
    (define-key map (kbd "d") #'etaf-install--manage-remove)
    (define-key map (kbd "RET") #'etaf-install--manage-open)
    (define-key map (kbd "?") #'etaf-install--manage-doctor)
    (define-key map (kbd "g") #'etaf-install--manage-refresh-archives)
    (define-key map (kbd "l") #'etaf-install--manage-list-packages)
    (define-key map (kbd "q") #'etaf-install--manage-quit)
    map)
  "Key map for `etaf-install--manage-mode'.")

(define-derived-mode etaf-install--manage-mode tabulated-list-mode "ETAF Packages"
  "Major mode for the ETAF Packages buffer."
  (setq tabulated-list-format
        [("Status" 16 t) ("Target" 51 t) ("Group" 16 t)
         ("Installed" 14 t) ("Available" 16 t) ("Runtime" 30 t)
         ("Depends on" 46 t)])
  (setq tabulated-list-entries #'etaf-install--manage-entries)
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'etaf-install--manage-invalidate nil t)
  (add-hook 'tabulated-list-revert-hook #'etaf-install--manage-update-header nil t)
  (add-hook 'post-command-hook #'etaf-install--manage-show-current nil t)
  (setq-local mode-line-format '(:eval (etaf-install--manage-mode-line)))
  (hl-line-mode 1)
  (tabulated-list-init-header))

;;;###autoload
(defun etaf-install-manage ()
  "Show and manage installed and available ETAF targets."
  (interactive)
  (unless package--initialized (package-initialize))
  (etaf-install--archive)
  (etaf-install--register-installed-archives)
  (let ((header (get-buffer-create "*ETAF Packages Header*"))
        (buffer (get-buffer-create "*ETAF Packages*")))
    (with-current-buffer header
      (etaf-install--manage-header-mode))
    (with-current-buffer buffer
      (etaf-install--manage-mode)
      (setq etaf-install--manage-cache nil)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    (let ((table-window (get-buffer-window buffer)))
      (let ((existing (get-buffer-window header)))
        (when (and existing (window-live-p existing))
          (delete-window existing)))
      (when (and (not noninteractive)
                 table-window
                 (>= (window-height table-window) 8)
                 (>= (frame-height) 12))
        (let* ((first-window table-window)
               (other-window (split-window first-window (- (frame-height) 4) 'above))
               (header-window (if (< (window-height first-window) (window-height other-window))
                                  first-window other-window))
               (table-window (if (< (window-height first-window) (window-height other-window))
                                 other-window first-window)))
          (set-window-buffer header-window header)
          (set-window-buffer table-window buffer)
          (set-window-parameter header-window 'mode-line-format 'none)
          (select-window table-window))))
    (etaf-install--manage-update-header)
    (etaf-install--manage-show-current)))

(etaf-install--register-installed-archives)

(provide 'etaf-install)
;;; etaf-install.el ends here
