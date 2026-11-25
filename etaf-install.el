;;; -*- lexical-binding: t; -*-
;;; etaf-install.el --- Install ETAF with the Emacs package manager

;; Version: 0.2.23
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
;; When `etaf-install-auto-native' is non-nil (the default), any prebuilt native
;; dynamic modules declared by PACKAGE or its installed ETAF dependencies are
;; automatically downloaded, verified (SHA-256), cached and activated before
;; opening so users need no compiler and no second command; an unavailable or
;; unreachable native prebuild never fails the Lisp installation.
;; Missing mandatory Emacs capabilities or a conflicting source checkout signal
;; user-error before installation.  An upgrade of a loaded dependency also
;; requires a restart before installation.  A target's runtime tools are
;; reported after installation; the install message names the first remedy and
;; `etaf-install-doctor' lists all of them.  On failure, remove only packages added
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
;; installed target plus the installer.  When `etaf-install-auto-native' is
;; non-nil, also fetch any newly required or updated prebuilt native modules
;; declared by upgraded packages.  Return a report.  Restart Emacs when an
;; update replaces loaded Lisp.
;;
;; Function: etaf-install-remove (package &optional no-confirm)
;; Remove PACKAGE's package files and its `package-selected-packages' entry.
;; Application data, logins and caches are kept; shared dependencies remain.
;;
;; Function: etaf-install-status (&optional package)
;; Return installed and available versions, the update flag and runtime facts
;; for PACKAGE or every supported target.
;;
;; Function: etaf-install-native (&optional package force)
;; Download, verify (SHA-256) and install the prebuilt native dynamic module(s)
;; declared by PACKAGE or its installed ETAF dependencies into
;; `etaf-install-native-directory', activating them immediately when possible.
;; No compiler, Make or Python is required.  With FORCE (prefix argument),
;; re-download even when a verified copy is already cached.
;;
;; Variable: etaf-install-auto-native
;; Non-nil (the default) to automatically download, verify and activate
;; available prebuilt native dynamic modules during `etaf-install' and
;; `etaf-install-update' so users need only M-x etaf-install.  Set to nil to
;; opt out and invoke `etaf-install-native' manually instead.
;;
;; Variable: etaf-install-native-directory
;; User cache directory holding verified prebuilt native dynamic modules.
;; Defaults to nil, resolving to `${XDG_CACHE_HOME:-~/.cache}/emacs-taf/native/'.
;; Stored outside `package-user-dir' so package upgrades preserve compatible
;; native modules and read-only package directories keep working.
;;
;; Variable: etaf-install-native-url
;; Optional HTTPS base URL or existing local directory overriding the download
;; URLs in `native/manifest.json' (for mirrors, offline installs or tests).
;;
;; Setup once using the installation block in the workspace README, then use
;; M-x etaf-install.  Credentials and external application backends are outside
;; this installer's scope.  It offers only targets with a verified Lisp install.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'subr-x)
(require 'tabulated-list)

(defvar url-http-response-status)
(declare-function ekp-c-module-load "ekp" ())

(defgroup etaf-install nil
  "Install the ETAF framework and its Lisp applications."
  :group 'applications)

(defcustom etaf-install-archive-url "https://etaf.top/packages/"
  "ETAF package archive URL, or an absolute local archive directory."
  :type 'string
  :group 'etaf-install)

(defcustom etaf-install-auto-native t
  "When non-nil, automatically download and activate prebuilt native modules.
Applies during `etaf-install' and `etaf-install-update' for the target and its
installed ETAF dependencies so users need no compiler and no second command.
Missing or unreachable native prebuilds fall back cleanly without failing the
Lisp installation."
  :type 'boolean
  :group 'etaf-install)

(defcustom etaf-install-native-directory nil
  "Directory holding verified prebuilt native dynamic modules, or nil.
When nil, resolves to `${XDG_CACHE_HOME:-~/.cache}/emacs-taf/native/'."
  :type '(choice (const :tag "Default XDG cache" nil) directory)
  :group 'etaf-install)

(defcustom etaf-install-native-url nil
  "Optional override HTTPS base URL or local directory for native binaries.
When nil, uses the pinned HTTPS mirrors declared in each package's
`native/manifest.json'."
  :type '(choice (const :tag "Use package manifest mirrors" nil) string)
  :group 'etaf-install)

(defconst etaf-install--targets
  '((etaf-install "Install ETAF" framework etaf-install)
    (ebox "Box model renderer" framework nil)
    (ecss "CSS cascade engine" framework nil)
    (etaf-gamekit "Game runtime for Godot battles" framework nil)
    (etaf-ui "ETAF components and gallery" framework etaf-ui-gallery-open)
    ;; The window manager itself comes from MELPA, which the installer only
    ;; registers when a target asks for it.
    (etaf-posframe "Floating panel host" framework nil melpa)
    (etaf "ETAF framework" framework nil)
    (etaf-db "ETAF SQLite backend" framework nil sqlite)
    (ekp "Knuth-Plass paragraph layout" framework nil)
    (etaf-manual "ETAF reference manual" application etaf-manual-open)
    (etaf-md "Markdown reading view" application etaf-md-open)
    (etaf-org-preview "Org reading view" application etaf-org-preview-open)
    (etaf-video-player "Video with sound in a buffer" application etaf-video-player-open)
    (etaf-desktop "Windows and workspaces" application etaf-desktop-open)
    ;; MELPA supplies Telega and Transient; Transient needs Compat from GNU ELPA.
    (etaf-telega "Telegram client" application etaf-telega-open melpa gnu)
    (etaf-weread "WeChat Reading" application etaf-weread-open)
    (etaf-ncm "NetEase Cloud Music" application etaf-ncm-open)
    (etaf-pomodoro "Focus timer" application etaf-pomodoro-open)
    (maillist "Mailing-list archive client" application maillist-open sqlite)
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

(defvar etaf-install-community-cache nil
  "Community packages read from the archive manifest, or nil when unread.")

(defun etaf-install--community ()
  "Return the community records cached by an interactive run, or nil.

  Reading them costs a request to the archive, so it happens only when the user
  runs the installer, never on a package.el installation path: a gate or a
  batch installation must not wait on the network."
  (or etaf-install-community-cache
      (setq etaf-install-community-cache
            (when (called-interactively-p 'any)
              (condition-case nil
                  (let ((buffer (url-retrieve-synchronously
                                 (concat (or (cdr (assoc "etaf" package-archives))
                                             etaf-install-archive-url)
                                         "manifest.json")
                                 t t 3)))
                    (prog1 (when buffer
                             (with-current-buffer buffer
                               (goto-char (point-min))
                               (when (search-forward "\n\n" nil t)
                                 (gethash "community"
                                          (json-parse-buffer :object-type 'hash-table
                                                             :null-object nil)))))
                      (when (buffer-live-p buffer) (kill-buffer buffer))))
                (error nil))))))

(defun etaf-install--archive-targets ()
  "Return community packages this table does not curate.

  They are installed the same way as a curated target, in the group and under
  the label the archive states. The open command and the capability checks
  belong to whoever wrote such a package, so its row carries neither."
  (let ((records (etaf-install--community))
        extra)
    (when (hash-table-p records)
      (maphash (lambda (name record)
                 (when (and (not (assq (intern name) etaf-install--targets))
                            (assq (intern name) package-archive-contents))
                   (push (list (intern name)
                               (or (gethash "label" record) name)
                               (or (intern-soft (or (gethash "group" record) "application"))
                                   'application)
                               (intern-soft (or (gethash "open" record) "")))
                         extra)))
               records))
    (nreverse extra)))

(defun etaf-install--available-targets ()
  "Return the curated targets followed by the archive's other packages."
  (append etaf-install--targets
          (and (boundp 'package-archive-contents)
               (etaf-install--archive-targets))))

(defun etaf-install--target (package)
  "Return the supported target description for PACKAGE."
  (or (assq package (etaf-install--available-targets))
      (user-error "Unsupported target %s; run M-x etaf-install to choose one" package)))

(defconst etaf-install--group-labels
  '((framework . "Framework") (application . "Application") (game . "Game"))
  "Menu prefix for each target group.")

(defun etaf-install--target-choices ()
  "Return completion candidates as (LABEL . PACKAGE), grouped in menu order."
  (let (choices)
    (dolist (group '(framework application game))
      (dolist (target (cl-remove-if-not (lambda (entry) (eq (nth 2 entry) group))
                                  (etaf-install--available-targets)))
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
  (dolist (target (etaf-install--available-targets))
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
    (when (assq package (etaf-install--available-targets))
      (etaf-install--register-target-archives package)))
  (let* ((needed (cons "etaf"
                       (cl-loop for package in packages
                                when (assq package (etaf-install--available-targets))
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
    (let* ((native-auto (etaf-install--native-ensure-best-effort package))
           (native-installed (plist-get native-auto :installed))
           (native-failed (plist-get native-auto :failed))
           (native-restart (plist-get native-auto :restart))
           (missing (cl-remove-if #'cadr (plist-get (etaf-install-doctor package) :required))))
      (if missing
          (message "ETAF: %s is installed; missing for use: %s. %s Run M-x etaf-install-doctor for all details."
                   package
                   (mapconcat (lambda (fact) (car fact)) missing ", ")
                   (nth 2 (car missing)))
        (when (and (not no-open) (nth 3 target))
          (call-interactively (nth 3 target)))
        (cond
         (native-failed
          (message "ETAF: %s is ready (using fallback; native download failed: %s; retry with M-x etaf-install-native)."
                   package (cdar native-failed)))
         (native-installed
          (message "ETAF: %s is ready (prebuilt native acceleration active%s).  M-x etaf-install opens installed targets; M-x etaf-install-manage updates or removes them."
                   package (if native-restart "; restart Emacs to switch to the updated binary" "")))
         ((eq (etaf-install--native-status package) 'available)
          (message "ETAF: %s is ready. Optional prebuilt native acceleration available: run M-x etaf-install-native." package))
         (t
          (message "ETAF: %s is ready.  M-x etaf-install opens installed targets; M-x etaf-install-manage updates or removes them." package)))))
    package))

;;; Prebuilt native dynamic modules

(defvar etaf-install--native-platform-override nil
  "Internal test override for `etaf-install--native-platform'.")

(defun etaf-install--native-cache-root ()
  "Return the root directory where verified native dynamic modules live."
  (file-name-as-directory
   (expand-file-name
    (or etaf-install-native-directory
        (expand-file-name "emacs-taf/native"
                          (or (let ((xdg (getenv "XDG_CACHE_HOME")))
                                (and xdg (not (string-empty-p xdg)) xdg))
                              (expand-file-name "~/.cache")))))))

(defun etaf-install--native-platform ()
  "Return the normalized platform key for this Emacs, or nil if unsupported."
  (or etaf-install--native-platform-override
      (let* ((cfg (downcase (or system-configuration "")))
             (arch (cond
                    ((string-match-p "\\(aarch64\\|arm64\\)" cfg) "arm64")
                    ((string-match-p "\\(x86_64\\|amd64\\)" cfg) "x86_64")
                    (t nil)))
             (os (pcase system-type
                   ('darwin "darwin")
                   ('gnu/linux "linux")
                   ('windows-nt "windows")
                   (_ nil))))
        (when (and os arch)
          (format "%s-%s" os arch)))))

(defun etaf-install--native-suffix (&optional platform)
  "Return the dynamic module file suffix for PLATFORM or this Emacs."
  (cond
   ((and platform (string-prefix-p "darwin-" platform)) ".dylib")
   ((and platform (string-prefix-p "windows-" platform)) ".dll")
   ((and platform (string-prefix-p "linux-" platform)) ".so")
   ((and (boundp 'module-file-suffix) (stringp module-file-suffix))
    module-file-suffix)
   ((eq system-type 'darwin) ".dylib")
   ((eq system-type 'windows-nt) ".dll")
   (t ".so")))

(defun etaf-install--package-directory (package)
  "Return the installed or source directory for PACKAGE, or nil."
  (let* ((desc (cadr (assq package (bound-and-true-p package-alist))))
         (pkg-dir (and desc (fboundp 'package-desc-dir) (package-desc-dir desc)))
         (lib (unless (and pkg-dir (file-directory-p pkg-dir))
                (locate-library (symbol-name package)))))
    (cond
     ((and pkg-dir (file-directory-p pkg-dir))
      (file-name-as-directory pkg-dir))
     ((and lib (not (string-suffix-p ".eln" lib)))
      (file-name-directory lib)))))

(defun etaf-install--native-manifest-path (package)
  "Return PACKAGE's `native/manifest.json' path if present on disk."
  (when-let* ((dir (etaf-install--package-directory package))
              (path (expand-file-name "native/manifest.json" dir))
              ((file-readable-p path)))
    path))

(defun etaf-install--native-read-manifest (package)
  "Read and validate PACKAGE's `native/manifest.json', or return nil."
  (when-let* ((path (etaf-install--native-manifest-path package)))
    (let ((doc (with-temp-buffer
                 (insert-file-contents path)
                 (json-parse-buffer :object-type 'hash-table
                                    :array-type 'list
                                    :null-object nil))))
      (unless (and (hash-table-p doc)
                   (eql (gethash "schema" doc) 1)
                   (equal (gethash "package" doc) (symbol-name package))
                   (listp (gethash "modules" doc)))
        (error "Invalid native manifest in %s" path))
      doc)))

(defun etaf-install--native-module-cache-path (package version module &optional platform)
  "Return the cached path for PACKAGE VERSION's native MODULE."
  (expand-file-name
   (concat module (etaf-install--native-suffix platform))
   (expand-file-name (format "%s/%s" package version)
                     (etaf-install--native-cache-root))))

(defun etaf-install--native-local-checkout-path (package module &optional platform)
  "Return PACKAGE's in-tree built native MODULE path if it exists."
  (when-let* ((dir (etaf-install--package-directory package))
              (file (expand-file-name
                     (concat "native/" module (etaf-install--native-suffix platform))
                     dir))
              ((file-exists-p file)))
    file))

(defun etaf-install--native-cached-p (dest expected-sha)
  "Return non-nil when DEST exists and its recorded SHA-256 matches EXPECTED-SHA."
  (let ((marker (concat dest ".sha256")))
    (and (file-exists-p dest)
         (file-readable-p marker)
         (equal (string-trim
                 (with-temp-buffer
                   (insert-file-contents marker)
                   (buffer-string)))
                expected-sha))))

(defun etaf-install--installed-dependency-closure (package)
  "Return PACKAGE followed by its installed dependency closure as symbols."
  (let ((seen (list package))
        (result (list package))
        (pending (list package)))
    (while pending
      (let* ((name (pop pending))
             (desc (or (cadr (assq name package-alist))
                       (cadr (assq name package-archive-contents)))))
        (when desc
          (dolist (req (package-desc-reqs desc))
            (let ((dep (car req)))
              (unless (or (eq dep 'emacs) (memq dep seen))
                (push dep seen)
                (when (package-installed-p dep)
                  (push dep result)
                  (push dep pending))))))))
    (nreverse result)))

(defun etaf-install--native-packages-for-target (package)
  "Return installed packages in PACKAGE's closure declaring native manifests."
  (let ((closure (if (package-installed-p package)
                     (etaf-install--installed-dependency-closure package)
                   (list package))))
    (cl-remove-if-not #'etaf-install--native-manifest-path closure)))

(defun etaf-install--native-local-archive-dir ()
  "Return a local native staging dir beside `etaf-install-archive-url', if any."
  (when (and (stringp etaf-install-archive-url)
             (file-name-absolute-p etaf-install-archive-url)
             (file-directory-p etaf-install-archive-url))
    (let* ((archive (directory-file-name (expand-file-name etaf-install-archive-url)))
           (child (expand-file-name "native" archive))
           (sibling (expand-file-name "native" (file-name-directory archive))))
      (cond
       ((file-directory-p child) child)
       ((file-directory-p sibling) sibling)))))

(defun etaf-install--native-auto-source-available-p ()
  "Return non-nil when automatic native download has a configured source.
Prevents offline local-archive runs from making unintended internet requests
unless `etaf-install-native-url' or a local staged `native/' directory exists."
  (or (and etaf-install-native-url t)
      (and (stringp etaf-install-archive-url)
           (string-prefix-p "https://" etaf-install-archive-url))
      (and (etaf-install--native-local-archive-dir) t)))

(defun etaf-install--native-single-status (package)
  "Return native module status for PACKAGE itself.
Returns nil, `installed', `available', or `unavailable'."
  (when-let* ((doc (ignore-errors (etaf-install--native-read-manifest package)))
              (modules (gethash "modules" doc)))
    (let ((platform (etaf-install--native-platform))
          (all-installed t)
          (any-available nil)
          (dynamic-ok (and (boundp 'module-file-suffix) module-file-suffix
                           (fboundp 'module-load))))
      (dolist (mod modules)
        (let* ((name (gethash "name" mod))
               (version (gethash "version" mod))
               (platforms (gethash "platforms" mod))
               (entry (and platform (hash-table-p platforms)
                           (gethash platform platforms)))
               (sha (and (hash-table-p entry) (gethash "sha256" entry)))
               (dest (etaf-install--native-module-cache-path
                      package version name platform))
               (local (etaf-install--native-local-checkout-path
                       package name platform))
               (present (or local
                            (and sha (etaf-install--native-cached-p dest sha))
                            (and (null sha) (file-exists-p dest)))))
          (unless present
            (setq all-installed nil)
            (when (and dynamic-ok entry)
              (setq any-available t)))))
      (cond
       (all-installed 'installed)
       (any-available 'available)
       (t 'unavailable)))))

(defun etaf-install--native-status (package)
  "Return aggregated native module status for PACKAGE and its dependencies.
Returns nil, `installed', `available', or `unavailable'."
  (let ((pkgs (etaf-install--native-packages-for-target package)))
    (when pkgs
      (let ((statuses (delq nil (mapcar #'etaf-install--native-single-status pkgs))))
        (when statuses
          (cond
           ((cl-every (lambda (s) (eq s 'installed)) statuses) 'installed)
           ((memq 'available statuses) 'available)
           (t 'unavailable)))))))

(defun etaf-install--file-sha256 (file)
  "Return the lowercase hex SHA-256 digest of FILE's raw bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (downcase (secure-hash 'sha256 (current-buffer)))))

(defun etaf-install--native-download-url (url destination)
  "Download binary URL to DESTINATION via HTTPS or loopback HTTP."
  (unless (or (string-prefix-p "https://" url)
              (string-prefix-p "http://127.0.0.1:" url)
              (string-prefix-p "http://localhost:" url))
    (error "Refusing non-HTTPS native binary URL: %s" url))
  (let ((buffer (url-retrieve-synchronously url t t 30)))
    (unless buffer
      (error "No response from %s" url))
    (unwind-protect
        (with-current-buffer buffer
          (let ((status (and (boundp 'url-http-response-status)
                             url-http-response-status)))
            (unless (and (integerp status) (= status 200))
              (error "HTTP %s from %s" (or status "error") url)))
          (set-buffer-multibyte nil)
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "Malformed HTTP response from %s" url))
          (let ((coding-system-for-write 'no-conversion))
            (write-region (point) (point-max) destination nil 'silent)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun etaf-install--native-fetch-verified (package version entry destination)
  "Fetch, verify size and SHA-256 for ENTRY, and atomically install to DESTINATION."
  (let* ((file (gethash "file" entry))
         (expected-sha (gethash "sha256" entry))
         (expected-size (gethash "size" entry))
         (urls (gethash "urls" entry))
         (override (or etaf-install-native-url
                       (etaf-install--native-local-archive-dir)))
         (partial (concat destination ".partial"))
         (errors nil))
    (unless (and (stringp file)
                 (string-match-p "\\`[a-z0-9][a-z0-9._-]*\\.\\(dylib\\|so\\|dll\\)\\'" file))
      (error "Invalid artifact file name in native manifest: %S" file))
    (unless (and (stringp expected-sha)
                 (string-match-p "\\`[0-9a-f]\\{64\\}\\'" expected-sha))
      (error "Invalid SHA-256 checksum in native manifest for %s" file))
    (unless (and (integerp expected-size) (> expected-size 0))
      (error "Invalid artifact size in native manifest for %s" file))
    (make-directory (file-name-directory destination) t)
    (let ((sources
           (cond
            ((and override
                  (file-name-absolute-p override)
                  (file-directory-p override))
             (list (cons 'local
                         (let ((nested (expand-file-name
                                        (format "%s/%s/%s" package version file)
                                        override)))
                           (if (file-exists-p nested)
                               nested
                             (expand-file-name file override))))))
            ((and override
                  (or (string-prefix-p "https://" override)
                      (string-prefix-p "http://127.0.0.1:" override)
                      (string-prefix-p "http://localhost:" override)))
             (list (cons 'url
                         (format "%s/%s/%s/%s"
                                 (directory-file-name override)
                                 package version file))))
            (override
             (user-error "ETAF native URL must use HTTPS or an existing local directory"))
            (t
             (mapcar (lambda (u) (cons 'url u)) urls)))))
      (unless sources
        (error "No download mirrors declared for %s" file))
      (let ((ok nil))
        (dolist (source sources)
          (unless ok
            (unwind-protect
                (condition-case err
                    (progn
                      (when (file-exists-p partial) (delete-file partial))
                      (if (eq (car source) 'local)
                          (progn
                            (unless (file-readable-p (cdr source))
                              (error "Missing local artifact %s" (cdr source)))
                            (copy-file (cdr source) partial t))
                        (etaf-install--native-download-url (cdr source) partial))
                      (let ((actual-size (file-attribute-size (file-attributes partial))))
                        (unless (eql actual-size expected-size)
                          (error "Size mismatch for %s: expected %d bytes, got %s"
                                 file expected-size actual-size)))
                      (let ((actual-sha (etaf-install--file-sha256 partial)))
                        (unless (equal actual-sha expected-sha)
                          (error "SHA-256 mismatch for %s: expected %s, got %s"
                                 file expected-sha actual-sha)))
                      (set-file-modes partial #o755)
                      (rename-file partial destination t)
                      (with-temp-file (concat destination ".sha256")
                        (insert expected-sha "\n"))
                      (setq ok t))
                  (error
                   (push (format "%s: %s" (cdr source) (error-message-string err)) errors)))
              (when (file-exists-p partial)
                (ignore-errors (delete-file partial))))))
        (unless ok
          (user-error "Failed to download verified native module %s: %s"
                      file (mapconcat #'identity (nreverse errors) "; ")))))))

(defvar etaf-install--native-loaded-modules nil
  "Native dynamic module names loaded by `etaf-install-native' in this session.")

(defun etaf-install--native-module-loaded-p (module)
  "Return non-nil when dynamic module MODULE is already loaded in this Emacs.
Avoids relying on bare `featurep', because an Elisp library (such as
`etaf-video-mpv') may share the module's feature name before the native
binary is loaded, while `module-load' does not record into `load-history'."
  (let ((suffix (etaf-install--native-suffix))
        (needle (regexp-quote module))
        (feature (intern-soft module))
        (prefix (concat module "-")))
    (or (member module etaf-install--native-loaded-modules)
        (cl-some (lambda (entry)
                   (let ((file (car entry)))
                     (and (stringp file)
                          (string-suffix-p suffix file)
                          (string-match-p needle (file-name-nondirectory file)))))
                 load-history)
        (and feature
             (featurep feature)
             (not (cl-some (lambda (entry)
                             (and (stringp (car entry))
                                  (not (string-suffix-p suffix (car entry)))
                                  (member (cons 'provide feature) (cdr entry))))
                           load-history)))
        (and (fboundp 'module-function-p)
             (let (found)
               (mapatoms
                (lambda (sym)
                  (when (and (not found)
                             (fboundp sym)
                             (string-prefix-p prefix (symbol-name sym))
                             (module-function-p (symbol-function sym)))
                    (setq found t))))
               found)))))

(defun etaf-install--native-activate (package module dest newly-installed)
  "Activate native MODULE at DEST for PACKAGE.
Return non-nil when Emacs must be restarted because an older copy is loaded."
  (cond
   ((and (eq package 'ekp) (fboundp 'ekp-c-module-load))
    (ekp-c-module-load)
    (cl-pushnew module etaf-install--native-loaded-modules :test #'equal)
    nil)
   ((etaf-install--native-module-loaded-p module)
    newly-installed)
   ((fboundp 'module-load)
    (module-load dest)
    (cl-pushnew module etaf-install--native-loaded-modules :test #'equal)
    nil)
   (t nil)))

(defun etaf-install--native-candidates ()
  "Return completion candidates (LABEL . PACKAGE) for packages with native modules."
  (let (choices)
    (dolist (target (etaf-install--available-targets))
      (let* ((pkg (car target))
             (status (etaf-install--native-status pkg)))
        (when status
          (push (cons (format "%s — %s (%s)"
                              pkg (nth 1 target)
                              (pcase status
                                ('installed "installed")
                                ('available "available")
                                (_ "no prebuild for this platform")))
                      pkg)
                choices))))
    (nreverse choices)))

(defun etaf-install--read-native-target ()
  "Prompt for an installed ETAF package that declares a native module."
  (unless package--initialized (package-initialize))
  (let ((choices (etaf-install--native-candidates)))
    (unless choices
      (user-error "No installed ETAF package declares a prebuilt native module"))
    (let ((choice (completing-read "Install native module for: "
                                   (mapcar #'car choices) nil t nil nil (caar choices))))
      (or (cdr (assoc choice choices))
          (user-error "No package selected")))))

(defun etaf-install--native-install-one (package platform force)
  "Download, verify and activate native modules for a single PACKAGE on PLATFORM.
Return a plist with :installed, :skipped and :restart."
  (let* ((doc (or (etaf-install--native-read-manifest package)
                  (user-error "%s is not installed or declares no native module manifest" package)))
         (modules (gethash "modules" doc))
         installed skipped restart)
    (dolist (mod modules)
      (let* ((name (gethash "name" mod))
             (version (gethash "version" mod))
             (platforms (gethash "platforms" mod))
             (entry (and (hash-table-p platforms) (gethash platform platforms)))
             (dest (etaf-install--native-module-cache-path package version name platform)))
        (unless (hash-table-p entry)
          (let (available)
            (when (hash-table-p platforms)
              (maphash (lambda (k _v) (push k available)) platforms))
            (user-error
             "No prebuilt native module for %s on %s yet%s.%s"
             package platform
             (if available
                 (format " (published: %s)" (mapconcat #'identity (sort available #'string<) ", "))
               "")
             (cond
              ((eq package 'ekp) " Run M-x ekp-c-module-build to compile locally.")
              ((etaf-install--native-manifest-path package)
               " The package continues working with its fallback backend.")
              (t "")))))
        (let* ((expected-sha (gethash "sha256" entry))
               (cached (and (not force) (etaf-install--native-cached-p dest expected-sha))))
          (if cached
              (push (cons name dest) skipped)
            (message "ETAF: downloading %s (%s)…" name platform)
            (etaf-install--native-fetch-verified package version entry dest)
            (push (cons name dest) installed))
          (when (etaf-install--native-activate package name dest (not cached))
            (setq restart t)))))
    (list :installed (nreverse installed)
          :skipped (nreverse skipped)
          :restart (and restart t))))

(defun etaf-install--native-ensure-best-effort (package)
  "Automatically fetch available prebuilt native modules for PACKAGE's closure.
Never signals an error so optional native download failures do not fail Lisp
installation or updates.  Return a plist (:installed :skipped :failed :restart)."
  (let (installed skipped failed restart)
    (when (and etaf-install-auto-native
               (boundp 'module-file-suffix) module-file-suffix
               (fboundp 'module-load)
               (etaf-install--native-auto-source-available-p))
      (let ((platform (etaf-install--native-platform)))
        (when platform
          (dolist (native-pkg (etaf-install--native-packages-for-target package))
            (when (eq (etaf-install--native-single-status native-pkg) 'available)
              (condition-case err
                  (let ((one (etaf-install--native-install-one native-pkg platform nil)))
                    (setq installed (append installed (plist-get one :installed))
                          skipped (append skipped (plist-get one :skipped)))
                    (when (plist-get one :restart)
                      (setq restart t)))
                (error
                 (push (cons native-pkg (error-message-string err)) failed))))))))
    (list :installed installed
          :skipped skipped
          :failed (nreverse failed)
          :restart (and restart t))))

;;;###autoload
(defun etaf-install-native (&optional package force)
  "Download and verify prebuilt native dynamic module(s) for PACKAGE.
Covers PACKAGE and any installed ETAF dependencies declaring
`native/manifest.json'.  Installs into `etaf-install-native-directory'
\(`~/.cache/emacs-taf/native/' by default), outside `package-user-dir', so
upgrades preserve compatible binaries and no compiler is needed.  With prefix
argument FORCE, re-download even when a verified copy is already cached.
Return a report plist."
  (interactive
   (list (etaf-install--read-native-target) current-prefix-arg))
  (unless package--initialized (package-initialize))
  (unless (and (boundp 'module-file-suffix) module-file-suffix (fboundp 'module-load))
    (user-error "This Emacs was built without dynamic module support (`module-load')"))
  (let* ((package (or package (etaf-install--read-native-target)))
         (native-pkgs (etaf-install--native-packages-for-target package))
         (platform (or (etaf-install--native-platform)
                       (user-error "Unsupported platform for prebuilt native modules (%s / %s)"
                                   system-type system-configuration)))
         installed skipped restart)
    (unless native-pkgs
      (user-error "%s is not installed or declares no native module manifest" package))
    (dolist (native-pkg native-pkgs)
      (let ((one (etaf-install--native-install-one native-pkg platform force)))
        (setq installed (append installed (plist-get one :installed))
              skipped (append skipped (plist-get one :skipped)))
        (when (plist-get one :restart)
          (setq restart t))))
    (let ((report (list :package package
                        :packages native-pkgs
                        :platform platform
                        :installed installed
                        :skipped skipped
                        :restart (and restart t))))
      (message "ETAF: native module for %s is ready (%s)%s."
               package platform
               (if restart "; restart Emacs to activate the new version" ""))
      report)))

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
  (cl-loop for target in (etaf-install--available-targets)
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

(defun etaf-install--target-runtime-fact (package)
  "Return PACKAGE's first missing required fact, or nil."
  (let* ((facts (etaf-install-doctor package))
         (missing (cl-find-if (lambda (fact) (not (cadr fact)))
                              (plist-get facts :required))))
    missing))

(defun etaf-install--target-status (package)
  "Return a status plist for PACKAGE."
  (let* ((target (etaf-install--target package))
         (installed (etaf-install--installed-version package))
         (available (etaf-install--available-version package))
         (installed-p (not (null installed)))
         (update (and installed available (version-list-< installed available)))
         (runtime-fact (and installed-p (etaf-install--target-runtime-fact package)))
         (native-status (and installed-p (etaf-install--native-status package)))
         (runtime (cond ((not installed-p) "—")
                        (runtime-fact (format "%s missing" (car runtime-fact)))
                        ((eq native-status 'installed) "Ready · native")
                        ((eq native-status 'available) "Ready · native: n")
                        (t "Ready")))
         (remedy (or (nth 2 runtime-fact)
                     (and (eq native-status 'available)
                          "Optional prebuilt native module available: press `n' or run M-x etaf-install-native.")))
         (descriptor (or (cadr (assq package package-archive-contents))
                         (cadr (assq package package-alist)))))
    (list :package package
          :label (nth 1 target)
          :group (nth 2 target)
          :installed (etaf-install--version-string installed)
          :available (etaf-install--version-string available)
          :installed-p installed-p
          :update update
          :ready (and installed-p (null runtime-fact))
          :native native-status
          :runtime runtime
          :remedy remedy
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
            (mapcar #'car (etaf-install--available-targets)))))

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
    (let (native-installed native-failed)
      (when updated
        (setq etaf-install--restart-needed t)
        (dolist (item updated)
          (let ((one (etaf-install--native-ensure-best-effort (car item))))
            (setq native-installed (append native-installed (plist-get one :installed))
                  native-failed (append native-failed (plist-get one :failed))))))
      (let ((report (list :updated (nreverse updated)
                          :failed (nreverse failed)
                          :native-installed native-installed
                          :native-failed native-failed
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
        report))))

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

(defvar-local etaf-install--manage-last-status nil
  "Pending status headline set by a manage action for `post-command-hook'.")

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
                'face (cond ((or (equal runtime "Ready")
                                 (string-prefix-p "Ready" runtime)) 'success)
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

(defconst etaf-install--manage-keys
  '(("i" . "install")
    ("n" . "native")
    ("u" . "update")
    ("U" . "update all")
    ("d" . "remove")
    ("RET" . "open")
    ("?" . "doctor")
    ("g" . "refresh")
    ("l" . "packages")
    ("q" . "quit"))
  "Key-to-action hint pairs shown in the ETAF Packages buffer.")

(defconst etaf-install--manage-mode-line-tiers
  (list etaf-install--manage-keys
        '(("i" . "install")
          ("n" . "native")
          ("u" . "update")
          ("d" . "remove")
          ("RET" . "open")
          ("g" . "refresh")
          ("q" . "quit"))
        '(("i") ("n") ("d") ("RET") ("g") ("q"))
        '(("C-h m" . "keys")))
  "Mode-line key hint tiers as lists of (KEY . LABEL), longest first.")

(defconst etaf-install--manage-key-hints
  (mapcar (lambda (tier)
            (mapconcat (lambda (entry)
                         (if (cdr entry)
                             (format "%s %s" (car entry) (cdr entry))
                           (car entry)))
                       tier " · "))
          etaf-install--manage-mode-line-tiers)
  "Plain-text key hints for the mode line, longest first.
The longest hint list that fits beside a summary and the refresh button wins,
so narrow windows keep actionable keys visible instead of collapsing early.")

(defun etaf-install--manage-format-tier (tier &optional help-echo)
  "Format TIER of (KEY . LABEL) pairs with high-contrast key faces.
When HELP-ECHO is non-nil, attach it as the tooltip text."
  (let ((text (mapconcat
               (lambda (entry)
                 (let ((key (propertize (car entry) 'face 'help-key-binding)))
                   (if (cdr entry)
                       (concat key " " (cdr entry))
                     key)))
               tier " · ")))
    (if help-echo
        (propertize text 'help-echo help-echo)
      text)))

(defconst etaf-install--manage-action-commands
  '(etaf-install--manage-install
    etaf-install--manage-install-native
    etaf-install--manage-update
    etaf-install--manage-update-all
    etaf-install--manage-remove
    etaf-install--manage-refresh-archives)
  "Manage commands whose own status message is kept above the key hints.")

(defvar etaf-install--manage-refresh-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'etaf-install--manage-refresh-archives)
    map)
  "Mouse map for the mode line's refresh button.")

(defun etaf-install--manage-summaries ()
  "Return the mode-line summary in every length, longest first."
  (let* ((statuses (etaf-install--manage-statuses))
         (total (length statuses))
         (updates (cl-count-if (lambda (status) (plist-get status :update)) statuses))
         (installer (or (etaf-install--version-string
                         (etaf-install--installed-version 'etaf-install))
                        "dev"))
         (change (if (> updates 0)
                     (propertize (format " · %d updates available" updates)
                                 'face 'font-lock-keyword-face)
                   " · no updates"))
         (restart (when etaf-install--restart-needed
                    (propertize " · restart required" 'face 'warning))))
    (list (concat (format " ETAF Packages · %d targets · installer %s" total installer)
                  change restart)
          (concat (format " %d targets · installer %s" total installer) change restart)
          (concat (format " %d targets · installer %s" total installer) restart)
          (format " %d targets" total))))

(defun etaf-install--manage-mode-line ()
  "Return the mode line for the ETAF Packages buffer.
The buffer holds the table only: the summary, the keys and the refresh button
sit on this line, so no second window is needed to show them.  The longest
hint list that still leaves room for a summary wins, so the keys stay visible
in a narrow window instead of being cut off."
  (let* ((button (propertize " Refresh " 'face 'mode-line-highlight
                             'mouse-face 'highlight
                             'keymap etaf-install--manage-refresh-map
                             'help-echo "Refresh package archives (g)"))
         (summaries (etaf-install--manage-summaries))
         (full-help (car etaf-install--manage-key-hints))
         (fitted (cl-loop for tier in etaf-install--manage-mode-line-tiers
                          for hints = (etaf-install--manage-format-tier tier full-help)
                          for room = (- (window-width) (length hints) (length button) 3)
                          for summary = (cl-find-if (lambda (text) (<= (length text) room))
                                                    summaries)
                          when summary
                          return (cons summary hints)
                          finally return (cons (car (last summaries)) nil)))
         (summary (car fitted))
         (hints (cdr fitted))
         (padding (max 1 (- (window-width) (length summary) (length hints)
                            (length button) (if hints 1 0)))))
    (concat (propertize summary 'face 'mode-line-buffer-id)
            (make-string padding ?\s)
            (when hints (concat hints " "))
            button)))

(defun etaf-install--manage-format-key-hints (&optional width)
  "Return the formatted keybinding hint string for the echo area.
When WIDTH is positive, wrap between items so no hint breaks across lines."
  (let* ((sep (propertize " · " 'face 'shadow))
         (sep-width (string-width sep))
         (limit (or width (if noninteractive 120 (max 20 (- (frame-width) 2)))))
         (lines nil)
         (line "")
         (line-width 0))
    (dolist (entry etaf-install--manage-keys)
      (let* ((item (concat (propertize (car entry) 'face 'help-key-binding)
                           " "
                           (cdr entry)))
             (item-width (string-width item)))
        (cond
         ((= line-width 0)
          (setq line item
                line-width item-width))
         ((<= (+ line-width sep-width item-width) limit)
          (setq line (concat line sep item)
                line-width (+ line-width sep-width item-width)))
         (t
          (push line lines)
          (setq line item
                line-width item-width)))))
    (when (> line-width 0)
      (push line lines))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun etaf-install--manage-current-summary ()
  "Return the single-line summary for the target at point, or nil."
  (let ((package (tabulated-list-get-id)))
    (when package
      (let ((status (cl-find package (etaf-install--manage-statuses)
                             :key (lambda (item) (plist-get item :package)))))
        (when status
          (format "%s — %s%s%s"
                  (plist-get status :label)
                  (plist-get status :runtime)
                  (if (plist-get status :remedy)
                      (format " · %s" (plist-get status :remedy))
                    "")
                  (if (plist-get status :dependencies)
                      (format " · depends: %s"
                              (mapconcat #'symbol-name
                                         (plist-get status :dependencies) " · "))
                    "")))))))

(defun etaf-install--manage-echo (headline)
  "Display HEADLINE (when non-nil) and the manage key hints in the echo area."
  (let ((hints (etaf-install--manage-format-key-hints))
        (message-log-max nil))
    (if (and headline (not (string-empty-p headline)))
        (message "%s\n%s" headline hints)
      (message "%s" hints))))

(defun etaf-install--manage-show-current (&optional headline)
  "Describe the target at point and show key hints in the echo area.
When HEADLINE is non-nil, show it above the key hints instead of the
target summary."
  (etaf-install--manage-echo
   (or headline (etaf-install--manage-current-summary))))

(defun etaf-install--manage-post-command ()
  "Refresh the echo-area target summary and key hints after a command."
  (let ((pending etaf-install--manage-last-status))
    (setq etaf-install--manage-last-status nil)
    (unless (or (active-minibuffer-window)
                (eq this-command 'etaf-install--manage-quit))
      (let ((msg (or pending (current-message))))
        (cond
         ((and msg (memq this-command etaf-install--manage-action-commands))
          (etaf-install--manage-echo (car (split-string msg "\n"))))
         ((and this-command msg (not (eq this-command 'etaf-install-manage)))
          nil)
         (t
          (etaf-install--manage-show-current)))))))

(defun etaf-install--manage-current-target ()
  "Return the target at point or signal a user error."
  (or (tabulated-list-get-id)
      (user-error "No ETAF target on this line")))

(defun etaf-install--manage-reprint (&optional headline)
  "Invalidate the cache and reprint the manage buffer.
When HEADLINE is non-nil, display it above the key hints in the echo area."
  (etaf-install--manage-invalidate)
  (tabulated-list-revert)
  (setq etaf-install--manage-last-status headline)
  (etaf-install--manage-show-current headline))

(defun etaf-install--manage-install ()
  "Install the target at point."
  (interactive)
  (let ((package (etaf-install--manage-current-target)))
    (etaf-install package t)
    (etaf-install--manage-reprint (current-message))))

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
    (etaf-install--manage-reprint (current-message))))

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

(defun etaf-install--manage-install-native (&optional force)
  "Install prebuilt native module(s) for the target at point."
  (interactive "P")
  (let ((package (etaf-install--manage-current-target)))
    (unless (package-installed-p package)
      (user-error "Install %s first (press `i')" package))
    (etaf-install-native package force)
    (etaf-install--manage-reprint (current-message))))

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
  (let ((status-message "ETAF: package archives refreshed"))
    (message "%s" status-message)
    (etaf-install--manage-reprint status-message)))

(defun etaf-install--manage-list-packages ()
  "Open the standard package menu beside the ETAF list.
`list-packages' otherwise claims this window and hides the manager until it is
reopened."
  (interactive)
  (let ((display-buffer-overriding-action '((display-buffer-pop-up-window))))
    (list-packages)))

(defun etaf-install--manage-quit ()
  "Quit the ETAF Packages window."
  (interactive)
  (quit-window))

(defvar etaf-install--manage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "i") #'etaf-install--manage-install)
    (define-key map (kbd "n") #'etaf-install--manage-install-native)
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
  (add-hook 'post-command-hook #'etaf-install--manage-post-command nil t)
  (setq-local mode-line-format '(:eval (etaf-install--manage-mode-line)))
  (hl-line-mode 1)
  (tabulated-list-init-header))

;;;###autoload
(defun etaf-install-manage ()
  "Show and manage installed and available ETAF targets.
The buffer is the whole interface: a native tabulated list of every target with
its status, versions, runtime and dependencies, plus the archive's community
packages.  The echo area shows the selected target's details and the key hints.
`i' installs, `n' installs native modules, `u' updates, `U' updates all, `d'
removes, RET opens, `?' reports capabilities, `g' refreshes the archives, `l'
shows the standard package menu and `q' quits.  Removal deletes package files
only; application data, logins and caches stay."
  (interactive)
  (unless package--initialized (package-initialize))
  (etaf-install--archive)
  (etaf-install--register-installed-archives)
  (let ((buffer (get-buffer-create "*ETAF Packages*")))
    (with-current-buffer buffer
      (etaf-install--manage-mode)
      (setq etaf-install--manage-cache nil)
      (tabulated-list-print t))
    ;; The table is the whole interface: take the frame instead of leaving the
    ;; previous buffer in a window above or below it.
    (delete-other-windows)
    (switch-to-buffer buffer)
    (etaf-install--manage-show-current)))

(etaf-install--register-installed-archives)

(provide 'etaf-install)
;;; etaf-install.el ends here
