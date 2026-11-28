;;; etaf-install-manage.el --- Installation, updates and manager UI -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Package installation, bottom-up dependency upgrades, obsolete pruning,
;; removal and the `*ETAF Packages*' tabulated-list interface.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'subr-x)
(require 'tabulated-list)
(require 'etaf-install-catalog)
(require 'etaf-install-native)
(require 'etaf-install-doctor)

(defvar etaf-install--skip-refresh nil
  "Non-nil when a batch caller has already refreshed the required archives.")

(defvar etaf-install--last-native-report nil
  "Internal collector for native installation results during batch ensure.")

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
      (unless etaf-install--skip-refresh
        (message "ETAF: checking the official package archive…")
        ;; Scope the refresh to ETAF without discarding the user's other archive
        ;; configuration.  No global signature setting or proxy is rewritten.
        (etaf-install--refresh-archives (list package)))
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
              (package-install descriptor)
              ;; Remove superseded older versions of packages upgraded by this
              ;; installation only after load and selection have succeeded.
              (etaf-install--prune-obsolete-packages
               (mapcar #'package-desc-name
                       (etaf-install--added-packages before))))
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
    (etaf-install--check-plan (etaf-install--newest-installed-desc package) t)
    (require package)
    (let* ((native-auto (etaf-install--native-ensure-best-effort package))
           (native-installed (plist-get native-auto :installed))
           (native-failed (plist-get native-auto :failed))
           (native-restart (plist-get native-auto :restart))
           (post-facts (etaf-install-doctor package))
           (missing (cl-remove-if #'cadr (plist-get post-facts :required)))
           (managed-started nil))
      (setq etaf-install--last-native-report native-auto)
      (when (and missing (not no-open) (not noninteractive))
        (let* ((engine (etaf-install--missing-managed-engine package missing))
               (missing-clis (etaf-install--missing-cli-tools-from-facts
                              post-facts :required)))
          (when (and engine
                     (null missing-clis)
                     (fboundp (cadr engine))
                     (y-or-n-p (format "%s requires %s. Download and install it now? "
                                       package (car engine))))
            (call-interactively (cadr engine))
            (setq managed-started (car engine)))))
      (cond
       (managed-started
        (message "ETAF: %s is installed; installing %s in *ETAF engine install*. Re-run M-x etaf-install when done."
                 package managed-started))
       (missing
        (when (and (not no-open) (not noninteractive))
          (etaf-install--display-doctor package post-facts))
        (let* ((cmd (etaf-install--missing-install-command package post-facts))
               (first-remedy (or (nth 2 (car missing)) "")))
          (message "ETAF: %s is installed; missing for use: %s. %s%s Run M-x etaf-install-doctor for all details."
                   package
                   (mapconcat (lambda (fact) (car fact)) missing ", ")
                   first-remedy
                   (if (and cmd (not (string-match-p (regexp-quote cmd) first-remedy)))
                       (format " Try: %s." cmd)
                     ""))))
       (t
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
          (message "ETAF: %s is ready.  M-x etaf-install opens installed targets; M-x etaf-install-manage updates or removes them." package))))))
    package))

(defun etaf-install-ensure (packages &optional refresh)
  "Ensure every target in PACKAGES is installed from the official ETAF archive.
PACKAGES may be a single package symbol or a list of package symbols, suitable
for declarative use in an Emacs init file alongside `use-package'.  Registers
the ETAF archive locally without modifying user init files.

When every requested package is already installed and REFRESH is nil, performs
no network requests and returns immediately so startup stays fast and offline.
When any package is missing (or REFRESH is non-nil), refreshes the required
archives once, installs each missing target without opening its application,
and ensures declared prebuilt native modules when `etaf-install-auto-native'
is non-nil.

Return a plist with `:installed', `:already', `:native-installed' and
`:native-failed'."
  (let* ((raw (cond
               ((null packages) nil)
               ((and (symbolp packages) (not (eq packages t))) (list packages))
               ((listp packages) packages)
               (t (user-error "PACKAGES must be a symbol or list of symbols: %S" packages))))
         (requested (delete-dups (copy-sequence raw))))
    (dolist (pkg requested)
      (unless (and (symbolp pkg) (not (memq pkg '(nil t))))
        (user-error "Invalid ETAF package symbol: %S" pkg)))
    (unless package--initialized (package-initialize))
    (etaf-install--archive)
    (if (null requested)
        (list :installed nil :already nil
              :native-installed nil :native-failed nil)
      (let (already missing)
        (dolist (pkg requested)
          (if (package-installed-p pkg)
              (push pkg already)
            (push pkg missing)))
        (setq already (nreverse already)
              missing (nreverse missing))
        (if (and (null missing) (not refresh))
            (list :installed nil
                  :already already
                  :native-installed nil
                  :native-failed nil)
          (when etaf-install--busy
            (user-error "An ETAF installation is already running in this Emacs"))
          (when etaf-install--restart-required
            (user-error "Restart Emacs before retrying; a failed installation left partially loaded Lisp"))
          (etaf-install--refresh-archives (if refresh requested missing))
          (let ((etaf-install--skip-refresh t)
                (etaf-install--last-native-report nil)
                installed native-installed native-failed)
            (dolist (pkg missing)
              (setq etaf-install--last-native-report nil)
              (etaf-install pkg t)
              (push pkg installed)
              (when etaf-install--last-native-report
                (setq native-installed
                      (append native-installed
                              (plist-get etaf-install--last-native-report :installed))
                      native-failed
                      (append native-failed
                              (plist-get etaf-install--last-native-report :failed)))))
            (when refresh
              (dolist (pkg already)
                (let ((one (etaf-install--native-ensure-best-effort pkg)))
                  (setq native-installed
                        (append native-installed (plist-get one :installed))
                        native-failed
                        (append native-failed (plist-get one :failed))))))
            (list :installed (nreverse installed)
                  :already already
                  :native-installed native-installed
                  :native-failed native-failed)))))))


;;; Target management

(defun etaf-install--installed-version (package)
  "Return PACKAGE's highest installed version list, or nil."
  (when (package-installed-p package)
    (let ((descriptor (etaf-install--newest-installed-desc package)))
      (and descriptor (package-desc-version descriptor)))))

(defun etaf-install--available-version (package)
  "Return PACKAGE's archive version list, or nil."
  (let ((descriptor (cadr (assq package package-archive-contents))))
    (and descriptor (package-desc-version descriptor))))

(defun etaf-install--package-reqs (package)
  "Return direct dependency symbols of PACKAGE from archive or installed data."
  (let ((desc (or (cadr (assq package package-archive-contents))
                  (etaf-install--newest-installed-desc package))))
    (when desc
      (delq 'emacs (mapcar #'car (package-desc-reqs desc))))))

(defun etaf-install--sort-by-dependencies (packages)
  "Return PACKAGES ordered bottom-up so dependencies precede dependents.
Preserves input order for unrelated packages and guards against cycles."
  (let ((allowed (copy-sequence packages))
        (visited (make-hash-table :test #'eq))
        (visiting (make-hash-table :test #'eq))
        result)
    (cl-labels
        ((visit (pkg)
           (unless (or (gethash pkg visited) (gethash pkg visiting))
             (puthash pkg t visiting)
             (dolist (dep (etaf-install--package-reqs pkg))
               (when (memq dep allowed)
                 (visit dep)))
             (remhash pkg visiting)
             (puthash pkg t visited)
             (push pkg result))))
      (dolist (pkg packages)
        (visit pkg)))
    (nreverse result)))

(defun etaf-install--descriptor-deletable-p (desc)
  "Return non-nil when DESC lives inside `package-user-dir' and is removable."
  (let ((dir (and (package-desc-p desc) (package-desc-dir desc))))
    (and (stringp dir)
         (not (and (fboundp 'package-vc-p) (funcall 'package-vc-p desc)))
         (file-in-directory-p
          dir
          (file-name-as-directory (expand-file-name package-user-dir))))))

(defun etaf-install--descriptor-retained-p (desc)
  "Return non-nil when Emacs retention policy or `package-load-list' keeps DESC."
  (let* ((name (package-desc-name desc))
         (version (package-version-join (package-desc-version desc)))
         (load-entry (assq name package-load-list))
         (pinned-ver (and (consp load-entry)
                          (if (consp (cdr load-entry))
                              (cadr load-entry)
                            (cdr load-entry))))
         (pinned (and (stringp pinned-ver)
                      (equal pinned-ver version))))
    (or pinned
        (and (boundp 'package-retention-policy)
             (fboundp 'package-matches-selector-p)
             (funcall 'package-matches-selector-p
                      (symbol-value 'package-retention-policy)
                      desc)))))

(defun etaf-install--prune-obsolete-packages (packages)
  "Delete superseded older versions of PACKAGES from `package-user-dir'.
Keeps the highest installed version of each package, respects
`package-retention-policy' and `package-load-list', deduplicates stale or
duplicate entries in `package-alist', and never fails an already-completed
install or update.  Return deleted full package names."
  (let (pruned)
    (dolist (name (delete-dups (copy-sequence packages)))
      (when-let* ((entry (assq name package-alist))
                  (descs (cdr entry))
                  ((> (length descs) 1))
                  (newest (etaf-install--newest-installed-desc name)))
        (let* ((newest-ver (package-desc-version newest))
               (newest-raw (package-desc-dir newest))
               (newest-dir (and (stringp newest-raw)
                                (file-directory-p newest-raw)
                                (file-truename newest-raw))))
          (dolist (desc (copy-sequence descs))
            (unless (eq desc newest)
              (let* ((dir (and (package-desc-p desc) (package-desc-dir desc)))
                     (live (and (stringp dir) (file-directory-p dir)))
                     (same-dir (and live newest-dir
                                    (equal (file-truename dir) newest-dir))))
                (cond
                 ;; Deduplicate in-memory descriptors pointing to the active
                 ;; directory without ever touching disk.
                 (same-dir
                  (setcdr entry (delq desc (cdr entry))))
                 ;; Remove ghost descriptors whose directory is already gone
                 ;; (Emacs `package-delete' leaves them in `package-alist').
                 ((and (stringp dir) (not live))
                  (setcdr entry (delq desc (cdr entry))))
                 ((and live
                       (version-list-< (package-desc-version desc) newest-ver)
                       (etaf-install--descriptor-deletable-p desc)
                       (not (etaf-install--descriptor-retained-p desc)))
                  (condition-case err
                      (progn
                        (package-delete desc t t)
                        (unless (file-directory-p dir)
                          (setcdr entry (delq desc (cdr entry)))
                          (push (package-desc-full-name desc) pruned)))
                    (error
                     (message "ETAF: could not remove old %s: %s"
                              (package-desc-full-name desc)
                              (error-message-string err))))))))))))
    (nreverse pruned)))

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
          :system-cli (etaf-install--system-cli-summary package)
          :remedy remedy
          :dependencies (and descriptor (etaf-install--dependency-names descriptor)))))

(defun etaf-install-status (&optional package)
  "Return status plists for PACKAGE, or for every supported target.
Each plist has :package, :label, :group, :installed, :available,
:installed-p, :update, :ready, :native, :runtime, :system-cli, :remedy and
:dependencies."
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

(defun etaf-install--format-update-summary (report)
  "Format a concise one-line status message for `etaf-install-update' REPORT."
  (let ((updated (plist-get report :updated))
        (pruned (plist-get report :pruned))
        (failed (plist-get report :failed)))
    (format "ETAF: %s%s%s%s"
            (if updated
                (format "updated %s"
                        (mapconcat (lambda (item)
                                     (format "%s %s" (car item) (cdr item)))
                                   updated ", "))
              "no updates")
            (if (and pruned (null updated))
                (format "; cleaned %d old package version%s"
                        (length pruned)
                        (if (= (length pruned) 1) "" "s"))
              "")
            (if failed (format "; %d failed" (length failed)) "")
            (if updated "; restart Emacs to use it" ""))))

(defun etaf-install-update (&optional package)
  "Update PACKAGE with its installed ETAF dependencies, or every installed target.
Refresh the ETAF archive and the standard archives installed targets need,
upgrade installed ETAF packages in bottom-up dependency order (expanding
PACKAGE to its installed ETAF dependency closure without upgrading unrelated
targets or third-party packages), remove superseded older versions (respecting
`package-retention-policy' and `package-load-list'), and return a plist with
`:updated', `:pruned', `:failed', `:native-installed', `:native-failed' and
`:restart'.  Restart Emacs when a loaded package changes; package.el remains
the package manager."
  (interactive (list (unless current-prefix-arg
                       (etaf-install--read-installed-target "Update: "))))
  (unless package--initialized (package-initialize))
  (let* ((targets (if package
                      (etaf-install--etaf-dependency-closure package)
                    (etaf-install--installed-targets)))
         (all (delete-dups
               (if package
                   (copy-sequence targets)
                 (if (package-installed-p 'etaf-install)
                     (cons 'etaf-install (copy-sequence targets))
                   (copy-sequence targets)))))
         updated pruned failed)
    (condition-case error
        (etaf-install--refresh-archives all)
      (error (push (cons 'archives (error-message-string error)) failed)))
    (unless failed
      (when package
        (setq all (delete-dups (etaf-install--etaf-dependency-closure package))))
      (let* ((ordered (etaf-install--sort-by-dependencies all))
             (before (apply #'append (mapcar #'cdr package-alist))))
        (dolist (name ordered)
          (condition-case error
              (let ((installed (etaf-install--installed-version name))
                    (available (etaf-install--available-version name)))
                (when (and installed available (version-list-< installed available))
                  (package-upgrade name)
                  (push (cons name (etaf-install--version-string available)) updated)))
            (error (push (cons name (error-message-string error)) failed))))
        ;; Record any dependencies upgraded transitively by `package-upgrade'.
        (let* ((added (etaf-install--added-packages before))
               (added-names nil))
          (dolist (desc added)
            (let ((dep-name (package-desc-name desc)))
              (push dep-name added-names)
              (unless (assq dep-name updated)
                (push (cons dep-name
                            (etaf-install--version-string
                             (package-desc-version desc)))
                      updated))))
          ;; Order reported updates bottom-up for readable summaries.
          (when updated
            (let ((order (etaf-install--sort-by-dependencies
                          (mapcar #'car updated))))
              (setq updated
                    (delq nil (mapcar (lambda (n) (assq n updated)) order)))))
          ;; Prune superseded older versions for upgraded packages and installed
          ;; ETAF dependencies in scope (never touching unrelated packages).
          (let ((etaf-names (mapcar #'car (etaf-install--available-targets)))
                (prune-scope (append ordered added-names)))
            (dolist (name ordered)
              (when (package-installed-p name)
                (dolist (dep (etaf-install--installed-dependency-closure name))
                  (when (memq dep etaf-names)
                    (push dep prune-scope)))))
            (setq pruned (etaf-install--prune-obsolete-packages prune-scope))))))
    (let (native-installed native-failed)
      (when updated
        (setq etaf-install--restart-needed t)
        (dolist (item updated)
          (let ((one (etaf-install--native-ensure-best-effort (car item))))
            (setq native-installed (append native-installed (plist-get one :installed))
                  native-failed (append native-failed (plist-get one :failed))))))
      (let ((report (list :updated updated
                          :pruned pruned
                          :failed (nreverse failed)
                          :native-installed native-installed
                          :native-failed native-failed
                          :restart (and updated t))))
        (when (called-interactively-p 'interactive)
          (message "%s" (etaf-install--format-update-summary report)))
        report))))

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
  (let* ((descs (etaf-install--live-installed-descs package))
         (newest (etaf-install--newest-installed-desc package))
         (dependents
          (cl-loop for (other . other-descs) in package-alist
                   unless (eq other package)
                   when (cl-some
                         (lambda (od)
                           (let ((dir (package-desc-dir od)))
                             (and (or (not (stringp dir)) (file-directory-p dir))
                                  (assq package (package-desc-reqs od)))))
                         other-descs)
                   collect other)))
    (when dependents
      (user-error "Cannot remove %s; still required by %s"
                  package (mapconcat #'symbol-name dependents ", ")))
    (let* ((entry (assq package package-alist))
           (newest-raw (and newest (package-desc-dir newest)))
           (seen-dirs (when (and (stringp newest-raw) (file-directory-p newest-raw))
                        (list (file-truename newest-raw)))))
      (dolist (desc (remq newest descs))
        (let* ((dir (and (package-desc-p desc) (package-desc-dir desc)))
               (true-dir (and (stringp dir) (file-directory-p dir)
                              (file-truename dir))))
          (when (and true-dir
                     (not (member true-dir seen-dirs))
                     (etaf-install--descriptor-deletable-p desc))
            (package-delete desc t t)
            (push true-dir seen-dirs))
          (when entry
            (setcdr entry (delq desc (cdr entry)))))))
    (when newest
      (package-delete newest))
    (setq package-alist (assq-delete-all package package-alist)
          package-selected-packages (delete package package-selected-packages))
    (message "ETAF: %s removed. App data, logins and caches were kept." package)
    package))

;;; The ETAF Packages buffer

(defvar etaf-install--manage-width-override nil
  "Internal test override for `*ETAF Packages*' viewport width in columns.")

(defvar-local etaf-install--manage-cache nil
  "Cached status plists for the ETAF Packages buffer.")

(defvar-local etaf-install--manage-layout nil
  "Current responsive column layout plist for `*ETAF Packages*'.")

(defvar-local etaf-install--manage-last-width nil
  "Last viewport column width applied to `*ETAF Packages*'.")

(defvar-local etaf-install--manage-last-status nil
  "Pending status headline set by a manage action for `post-command-hook'.")

(defvar-local etaf-install--manage-suppress-hints nil
  "Non-nil after quitting `*ETAF Packages*' so `post-command-hook' stays silent.")

(defconst etaf-install--group-short-labels
  '((framework . "Core") (extension . "Ext")
    (application . "App") (game . "Game"))
  "Compact group labels used in narrow `*ETAF Packages*' viewports.")

(defun etaf-install--manage-statuses ()
  "Return cached target status plists for this buffer."
  (or etaf-install--manage-cache
      (setq etaf-install--manage-cache (etaf-install-status))))

(defun etaf-install--manage-invalidate ()
  "Drop cached target status and refresh responsive column widths."
  (setq etaf-install--manage-cache nil
        etaf-install--manage-last-width nil))

(defun etaf-install--manage-window-width (&optional window)
  "Return effective column width for `*ETAF Packages*' in WINDOW."
  (cond
   ((integerp etaf-install--manage-width-override)
    (max 50 etaf-install--manage-width-override))
   (noninteractive 180)
   (t
    (let ((win (or (and (window-live-p window) window)
                   (get-buffer-window (current-buffer))
                   (selected-window))))
      (max 50 (if (window-live-p win) (window-body-width win) (frame-width)))))))

(defun etaf-install--manage-with-tooltip (text tooltip)
  "Return a copy of TEXT with `help-echo' set to TOOLTIP, preserving faces."
  (if (and (stringp tooltip) (not (string-empty-p tooltip)))
      (let ((copy (copy-sequence text)))
        (add-text-properties 0 (length copy) (list 'help-echo tooltip) copy)
        copy)
    text))

(defun etaf-install--manage-fit-list (items sep max-width &optional prefix overflow-sep)
  "Join propertized ITEMS with SEP to fit inside MAX-WIDTH display columns.
Optional PREFIX is prepended before the first item.  When ITEMS do not all
fit, append OVERFLOW-SEP (defaults to SEP) plus `+N' in `shadow' face so the
result never exceeds MAX-WIDTH."
  (let* ((pfx (or prefix ""))
         (ov-sep (or overflow-sep sep))
         (full (concat pfx (mapconcat #'identity items sep))))
    (if (<= (string-width full) max-width)
        full
      (let* ((total (length items))
             (fitted nil))
        (if (= total 1)
            ;; Never turn a single item (such as `✗ telega-server') into `+1';
            ;; truncate the item itself cleanly while preserving its face.
            (let* ((item (car items))
                   (face (get-text-property 0 'face item))
                   (room (max 1 (- max-width (string-width pfx))))
                   (cut (truncate-string-to-width item room nil nil "…")))
              (concat pfx (if face (propertize cut 'face face) cut)))
          (cl-loop for count downfrom (1- total) to 1
                   until fitted
                   do (let* ((head (mapconcat #'identity (cl-subseq items 0 count) sep))
                             (tail (propertize (format "%s+%d" ov-sep (- total count))
                                               'face 'shadow))
                             (cand (concat pfx head tail)))
                        (when (<= (string-width cand) max-width)
                          (setq fitted cand))))
          (or fitted
              (let ((fallback (concat pfx (propertize (format "+%d" total) 'face 'shadow))))
                (if (<= (string-width fallback) max-width)
                    fallback
                  (truncate-string-to-width fallback (max 1 max-width) nil nil "…")))))))))

(defun etaf-install--manage-status-text (status mode)
  "Return plain status text for STATUS under density MODE."
  (pcase mode
    ('narrow
     (cond ((plist-get status :update) "↑")
           ((plist-get status :installed-p) "●")
           (t "○")))
    ('compact
     (cond ((plist-get status :update) "● Update")
           ((plist-get status :installed-p) "● Installed")
           (t "○ Available")))
    (_
     (cond ((plist-get status :update) "● Update")
           ((plist-get status :installed-p) "● Installed")
           (t "● Not installed")))))

(defun etaf-install--manage-group-text (status mode)
  "Return plain group text for STATUS under density MODE."
  (let ((group (plist-get status :group)))
    (if (eq mode 'wide)
        (or (cdr (assq group etaf-install--group-labels))
            (capitalize (symbol-name group)))
      (or (cdr (assq group etaf-install--group-short-labels))
          (capitalize (symbol-name group))))))

(defun etaf-install--manage-version-text (version &optional update)
  "Return plain version display text for VERSION and UPDATE flag."
  (let ((ver (or version "—")))
    (if update (concat ver " ↑") ver)))

(defun etaf-install--cli-tool-name (tool)
  "Return short display name for manual CLI TOOL."
  (or (plist-get (cdr (assq tool etaf-install--cli-catalog)) :name)
      (symbol-name tool)))

(defun etaf-install--manage-cli-natural-width (status)
  "Return natural display width needed for STATUS's System CLI cell."
  (let ((cli (plist-get status :system-cli)))
    (if (null cli)
        1
      (let ((req (plist-get cli :required))
            (opt (plist-get cli :optional)))
        (cond
         (req
          (string-width
           (mapconcat (lambda (item)
                        (format "✓ %s" (etaf-install--cli-tool-name (car item))))
                      req " · ")))
         (opt
          (let* ((names (mapcar (lambda (item)
                                  (etaf-install--cli-tool-name (car item)))
                                opt))
                 (sample (if (> (length names) 3)
                             (format "opt: %s, %s, +%d"
                                     (car names) (cadr names) (- (length names) 2))
                           (concat "opt: " (mapconcat #'identity names ", ")))))
            (string-width sample)))
         (t 1))))))

(defun etaf-install--manage-compute-layout (statuses total-width)
  "Compute a content-driven responsive column layout for STATUSES in TOTAL-WIDTH."
  (let* ((mode (cond ((>= total-width 120) 'wide)
                     ((>= total-width 92) 'compact)
                     (t 'narrow)))
         (gutter (if (eq mode 'narrow) 0 1))
         (h-status (if (eq mode 'narrow) "St" "Status"))
         (h-target "Target")
         (h-group (if (eq mode 'wide) "Group" "Grp"))
         (h-inst (if (eq mode 'wide) "Installed" "Inst"))
         (h-avail (if (eq mode 'wide) "Available" "Avail"))
         (h-run (if (eq mode 'narrow) "Run" "Runtime"))
         (h-cli (if (eq mode 'narrow) "CLI" "System CLI"))
         (h-deps (if (eq mode 'narrow) "Deps" "Depends on"))
         (max-w (lambda (fn floor)
                  (cl-reduce #'max statuses :key fn :initial-value floor)))
         (status-c (funcall max-w
                            (lambda (s)
                              (string-width (etaf-install--manage-status-text s mode)))
                            (string-width h-status)))
         (group-c (funcall max-w
                           (lambda (s)
                             (string-width (etaf-install--manage-group-text s mode)))
                           (string-width h-group)))
         (inst-c (funcall max-w
                          (lambda (s)
                            (string-width (etaf-install--manage-version-text
                                           (plist-get s :installed)
                                           (plist-get s :update))))
                          (string-width h-inst)))
         (avail-c (funcall max-w
                           (lambda (s)
                             (string-width (etaf-install--manage-version-text
                                            (plist-get s :available)
                                            (plist-get s :update))))
                           (string-width h-avail)))
         (run-nat (funcall max-w
                           (lambda (s) (string-width (or (plist-get s :runtime) "—")))
                           (string-width h-run)))
         (target-nat (funcall max-w
                              (lambda (s)
                                (string-width (format "%s — %s"
                                                      (plist-get s :package)
                                                      (plist-get s :label))))
                              (string-width h-target)))
         (cli-nat (min 28 (funcall max-w
                                   #'etaf-install--manage-cli-natural-width
                                   (string-width h-cli))))
         (deps-nat (funcall max-w
                            (lambda (s)
                              (let ((deps (plist-get s :dependencies)))
                                (if deps
                                    (string-width (mapconcat #'symbol-name deps " · "))
                                  1)))
                            (string-width h-deps)))
         ;; Tabulated-list adds 1 left padding + 7 inter-column spaces; keep 1
         ;; safety cell at the right edge so Emacs never draws truncation `→'.
         (budget (max 56 (- total-width 9)))
         (status-w (+ status-c gutter))
         (group-w (+ group-c gutter))
         (inst-w (+ inst-c gutter))
         (avail-w (+ avail-c gutter))
         (fixed (+ status-w group-w inst-w avail-w))
         (flex (max 34 (- budget fixed)))
         (run-want (+ run-nat gutter))
         (target-want (+ target-nat gutter))
         (cli-want (+ cli-nat gutter))
         (deps-want deps-nat)
         ;; Step 1: allocate clean floor widths to the 4 flexible columns.
         (run-w (min run-want (pcase mode ('narrow 7) ('compact 12) (_ 18))))
         (target-w (min target-want (pcase mode ('narrow 18) ('compact 24) (_ 28))))
         (cli-w (min cli-want (pcase mode ('narrow 11) ('compact 15) (_ 18))))
         (deps-w (min deps-want (pcase mode ('narrow 10) ('compact 14) (_ 18))))
         (used (+ run-w target-w cli-w deps-w)))
    ;; If floor widths exceed flex budget on an extreme narrow window, trim cleanly.
    (when (> used flex)
      (let ((over (- used flex)))
        (let ((d (min over (max 0 (- deps-w 6)))))
          (setq deps-w (- deps-w d) over (- over d)))
        (let ((d (min over (max 0 (- cli-w 7)))))
          (setq cli-w (- cli-w d) over (- over d)))
        (let ((d (min over (max 0 (- target-w 12)))))
          (setq target-w (- target-w d) over (- over d)))
        (let ((d (min over (max 0 (- run-w 5)))))
          (setq run-w (- run-w d) over (- over d)))))
    ;; Step 2: distribute surplus by value — Runtime exact fit, then System CLI
    ;; (capped in narrow/compact modes so Target and Depends on stay balanced),
    ;; then split remaining room smoothly between Target and Depends on.
    (let ((extra (max 0 (- flex (+ run-w target-w cli-w deps-w))))
          (cli-cap (pcase mode ('narrow 16) ('compact 20) (_ cli-want))))
      (when (> extra 0)
        (let ((add (min extra (max 0 (- run-want run-w)))))
          (setq run-w (+ run-w add) extra (- extra add))))
      (when (> extra 0)
        (let ((add (min extra (max 0 (- (min cli-want cli-cap) cli-w)))))
          (setq cli-w (+ cli-w add) extra (- extra add))))
      (when (> extra 0)
        (let* ((t-need (max 0 (- target-want target-w)))
               (t-share (min t-need (ceiling (* extra 0.6))))
               (d-rem (- extra t-share))
               (d-need (max 0 (- deps-want deps-w)))
               (d-add (min d-rem d-need))
               (leftover (- d-rem d-add))
               (t-extra (min (max 0 (- t-need t-share)) leftover)))
          (setq target-w (+ target-w t-share t-extra)
                deps-w (+ deps-w d-add (max 0 (- leftover t-extra)))))))
    (list :mode mode
          :width total-width
          :gutter gutter
          :headers (list h-status h-target h-group h-inst h-avail h-run h-cli h-deps)
          :widths (list status-w target-w group-w inst-w avail-w run-w cli-w deps-w)
          :target-max (max 8 (- target-w gutter))
          :runtime-max (max 5 (- run-w gutter))
          :cli-max (max 6 (- cli-w gutter))
          :deps-max (max 6 deps-w))))

(defun etaf-install--manage-apply-layout (&optional width)
  "Recompute and apply `tabulated-list-format' for WIDTH in `*ETAF Packages*'."
  (let* ((total-width (or width (etaf-install--manage-window-width)))
         (statuses (etaf-install--manage-statuses))
         (layout (etaf-install--manage-compute-layout statuses total-width))
         (headers (plist-get layout :headers))
         (widths (plist-get layout :widths)))
    (setq etaf-install--manage-layout layout
          etaf-install--manage-last-width total-width
          tabulated-list-format
          (apply #'vector
                 (cl-mapcar (lambda (title w) (list title w t)) headers widths)))
    (tabulated-list-init-header)
    layout))

(defun etaf-install--manage-on-resize (&optional frame-or-window)
  "Refit `*ETAF Packages*' columns when its window width changes."
  (let ((win (cond
              ((windowp frame-or-window) frame-or-window)
              ((framep frame-or-window)
               (get-buffer-window (current-buffer) frame-or-window))
              (t (get-buffer-window (current-buffer))))))
    (when (and (window-live-p win)
               (eq (window-buffer win) (current-buffer)))
      (let ((width (etaf-install--manage-window-width win)))
        (unless (eql width etaf-install--manage-last-width)
          (etaf-install--manage-apply-layout width)
          (tabulated-list-print t))))))

(defun etaf-install--manage-status-cell (status layout)
  "Return the status cell for STATUS under LAYOUT."
  (let* ((mode (plist-get layout :mode))
         (text (etaf-install--manage-status-text status mode))
         (face (cond ((plist-get status :update) 'font-lock-keyword-face)
                     ((plist-get status :installed-p) 'success)
                     (t 'shadow)))
         (tip (cond
               ((plist-get status :update)
                (format "Update available: %s -> %s (press u to update)"
                        (plist-get status :installed)
                        (plist-get status :available)))
               ((plist-get status :installed-p)
                (format "Installed (%s)" (plist-get status :installed)))
               (t "Not installed (press i to install)"))))
    (etaf-install--manage-with-tooltip (propertize text 'face face) tip)))

(defun etaf-install--manage-target-cell (status layout)
  "Return the target cell for STATUS fitted to LAYOUT with a full tooltip."
  (let* ((pkg (symbol-name (plist-get status :package)))
         (label (or (plist-get status :label) ""))
         (group (etaf-install--manage-group-text status 'wide))
         (max-w (plist-get layout :target-max))
         (tip (format "%s — %s (%s)" pkg label group))
         (bold-pkg (propertize pkg 'face 'bold))
         (full (concat bold-pkg " — " (propertize label 'face 'shadow)))
         (text
          (cond
           ((<= (string-width full) max-w) full)
           ((>= (- max-w (string-width pkg) 3) 4)
            (let ((rem (- max-w (string-width pkg) 3)))
              (concat bold-pkg " — "
                      (propertize (truncate-string-to-width label rem nil nil "…")
                                  'face 'shadow))))
           ((<= (string-width pkg) max-w) bold-pkg)
           (t (propertize (truncate-string-to-width pkg max-w nil nil "…")
                          'face 'bold)))))
    (etaf-install--manage-with-tooltip text tip)))

(defun etaf-install--manage-group-cell (status layout)
  "Return the group cell for STATUS under LAYOUT."
  (let* ((mode (plist-get layout :mode))
         (text (etaf-install--manage-group-text status mode))
         (full (etaf-install--manage-group-text status 'wide)))
    (etaf-install--manage-with-tooltip text (format "Group: %s" full))))

(defun etaf-install--manage-version-cell (version &optional update)
  "Return a version cell for VERSION, highlighting UPDATE availability."
  (let ((version (or version "—")))
    (if update
        (concat (propertize version 'face 'font-lock-keyword-face) " ↑")
      (propertize version 'face 'shadow))))

(defun etaf-install--manage-runtime-cell (status layout)
  "Return the runtime cell for STATUS fitted to LAYOUT with full tooltip."
  (let* ((runtime (or (plist-get status :runtime) "—"))
         (remedy (plist-get status :remedy))
         (max-w (plist-get layout :runtime-max))
         (face (cond ((or (equal runtime "Ready")
                          (string-prefix-p "Ready" runtime)) 'success)
                     ((equal runtime "—") 'shadow)
                     (t 'warning)))
         (shown (if (<= (string-width runtime) max-w)
                    runtime
                  (truncate-string-to-width runtime max-w nil nil "…")))
         (tip (if remedy
                  (format "%s\n%s\nPress ? for full capability report." runtime remedy)
                (unless (equal runtime "—")
                  (format "%s (press ? for capability report)" runtime)))))
    (etaf-install--manage-with-tooltip (propertize shown 'face face) tip)))

(defun etaf-install--manage-cli-tooltip (cli)
  "Return hover tooltip text describing manual System CLI summary CLI."
  (let* ((req (plist-get cli :required))
         (opt (plist-get cli :optional))
         (cmd (plist-get cli :install-command))
         (parts nil))
    (when req
      (push (concat "Required: "
                    (mapconcat (lambda (item)
                                 (format "%s %s"
                                         (if (cdr item) "✓" "✗")
                                         (etaf-install--cli-tool-name (car item))))
                               req ", "))
            parts))
    (when opt
      (push (concat "Optional: "
                    (mapconcat (lambda (item)
                                 (format "%s %s"
                                         (if (cdr item) "✓" "✗")
                                         (etaf-install--cli-tool-name (car item))))
                               opt ", "))
            parts))
    (when cmd
      (push (concat "Install: " cmd) parts))
    (push "Press ? for details and copyable commands." parts)
    (mapconcat #'identity (nreverse parts) "\n")))

(defun etaf-install--manage-cli-cell (status layout)
  "Return the System CLI cell for STATUS fitted to LAYOUT.
Shows only external OS CLI tools the user must install manually (excluding
auto-downloaded native modules, bundled package backends and managed engines)."
  (let ((cli (plist-get status :system-cli)))
    (if (null cli)
        (propertize "—" 'face 'shadow)
      (let* ((req (plist-get cli :required))
             (opt (plist-get cli :optional))
             (max-w (plist-get layout :cli-max))
             (tip (etaf-install--manage-cli-tooltip cli))
             (text
              (cond
               (req
                (let* ((render-item
                        (lambda (item)
                          (let ((ok (cdr item))
                                (name (etaf-install--cli-tool-name (car item))))
                            (propertize (format "%s %s" (if ok "✓" "✗") name)
                                        'face (if ok 'success 'warning)))))
                       (sep (propertize " · " 'face 'shadow))
                       (natural (mapconcat render-item req sep)))
                  (if (<= (string-width natural) max-w)
                      natural
                    ;; When compacting, prioritize missing (`✗') tools first so
                    ;; missing prerequisites never hide behind `+N'.
                    (let* ((ordered (append (cl-remove-if #'cdr req)
                                            (cl-remove-if-not #'cdr req)))
                           (pills (mapcar render-item ordered)))
                      (etaf-install--manage-fit-list pills sep max-w nil " · ")))))
               (opt
                (let* ((names (mapcar (lambda (item)
                                        (propertize (etaf-install--cli-tool-name (car item))
                                                    'face 'shadow))
                                      opt))
                       (pfx (propertize "opt: " 'face 'shadow))
                       (sep (propertize ", " 'face 'shadow)))
                  (etaf-install--manage-fit-list names sep max-w pfx ", ")))
               (t (propertize "—" 'face 'shadow)))))
        (etaf-install--manage-with-tooltip text tip)))))

(defun etaf-install--manage-dependency-cell (status layout)
  "Return the dependency cell for STATUS fitted to LAYOUT with `+N' overflow."
  (let ((dependencies (plist-get status :dependencies)))
    (if (null dependencies)
        (propertize "—" 'face 'shadow)
      (let* ((names (mapcar #'symbol-name dependencies))
             (max-w (plist-get layout :deps-max))
             (tip (format "Depends on (%d): %s"
                          (length names)
                          (mapconcat #'identity names " · ")))
             (items (mapcar (lambda (n) (propertize n 'face 'shadow)) names))
             (sep (propertize " · " 'face 'shadow))
             (text (etaf-install--manage-fit-list items sep max-w nil " · ")))
        (etaf-install--manage-with-tooltip text tip)))))

(defun etaf-install--manage-entries ()
  "Return tabulated-list entries for ETAF targets."
  (let ((layout (or etaf-install--manage-layout
                    (etaf-install--manage-apply-layout))))
    (mapcar
     (lambda (status)
       (list (plist-get status :package)
             (vector (etaf-install--manage-status-cell status layout)
                     (etaf-install--manage-target-cell status layout)
                     (etaf-install--manage-group-cell status layout)
                     (etaf-install--manage-version-cell (plist-get status :installed)
                                                        (plist-get status :update))
                     (etaf-install--manage-version-cell (plist-get status :available)
                                                        (plist-get status :update))
                     (etaf-install--manage-runtime-cell status layout)
                     (etaf-install--manage-cli-cell status layout)
                     (etaf-install--manage-dependency-cell status layout))))
     (etaf-install--manage-statuses))))

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
  "Key-to-action hint pairs shown in the echo area for `*ETAF Packages*'.")

(defvar etaf-install--manage-refresh-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1]
      (lambda ()
        "Refresh the ETAF and installed targets' standard archives."
        (interactive)
        (etaf-install--manage-refresh-archives)))
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
The mode line shows only the summary and the refresh button; key hints are
displayed in the echo area."
  (let* ((button (propertize " Refresh " 'face 'mode-line-highlight
                             'mouse-face 'highlight
                             'keymap etaf-install--manage-refresh-map
                             'help-echo "Refresh package archives (g)"))
         (summaries (etaf-install--manage-summaries))
         (room (- (window-width) (length button) 1))
         (summary (or (cl-find-if (lambda (text) (<= (length text) room))
                                  summaries)
                      (car (last summaries))))
         (padding (max 1 (- (window-width) (length summary) (length button)))))
    (concat (propertize summary 'face 'mode-line-buffer-id)
            (make-string padding ?\s)
            button)))

(defun etaf-install--manage-format-key-hints (&optional width)
  "Return the formatted keybinding hint string for the echo area.
When WIDTH is positive, wrap between items so no hint breaks across lines."
  (let* ((sep "   ")
         (sep-width (string-width sep))
         (limit (or width (if noninteractive 120 (max 20 (- (frame-width) 2)))))
         (lines nil)
         (line "")
         (line-width 0))
    (dolist (entry etaf-install--manage-keys)
      (let* ((item (concat (propertize (car entry) 'face 'bold)
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

(defun etaf-install--manage-echo (&optional headline)
  "Display the manage key hints in the echo area.
When HEADLINE is non-nil, show it above the key hints."
  (let ((hints (etaf-install--manage-format-key-hints))
        (message-log-max nil))
    (if (and headline (not (string-empty-p headline)))
        (message "%s\n%s" headline hints)
      (message "%s" hints))))

(defun etaf-install--manage-show-current (&optional headline)
  "Show the manage key hints in the echo area.
When HEADLINE is non-nil, display it above the key hints."
  (etaf-install--manage-echo headline))

(defun etaf-install--manage-post-command ()
  "Refresh the echo-area key hints after a command."
  (let ((pending etaf-install--manage-last-status)
        (suppress etaf-install--manage-suppress-hints))
    (setq etaf-install--manage-last-status nil
          etaf-install--manage-suppress-hints nil)
    (unless (or suppress (active-minibuffer-window))
      (let ((msg (or pending (current-message))))
        (cond
         ((and pending (not (string-empty-p pending)))
          (etaf-install--manage-echo (car (split-string pending "\n"))))
         ((and this-command msg (not (eq this-command 'etaf-install-manage)))
          nil)
         (t
          (etaf-install--manage-show-current)))))))

(defun etaf-install--manage-current-target ()
  "Return the target at point or signal a user error."
  (or (tabulated-list-get-id)
      (user-error "No ETAF target on this line")))

(defun etaf-install--manage-on-revert ()
  "Invalidate cached status and refit columns before reverting `*ETAF Packages*'."
  (etaf-install--manage-invalidate)
  (etaf-install--manage-apply-layout))

(defun etaf-install--manage-reprint (&optional headline)
  "Invalidate the cache, refit columns and reprint the manage buffer.
When HEADLINE is non-nil, display it above the key hints in the echo area."
  (etaf-install--manage-invalidate)
  (etaf-install--manage-apply-layout)
  (tabulated-list-revert)
  (setq etaf-install--manage-last-status headline)
  (etaf-install--manage-show-current headline))

(defun etaf-install--manage-install ()
  "Install the target at point."
  (let ((package (etaf-install--manage-current-target)))
    (etaf-install package t)
    (etaf-install--manage-reprint (current-message))))

(defun etaf-install--manage-update ()
  "Update the target at point."
  (let* ((package (etaf-install--manage-current-target))
         (report (etaf-install-update package)))
    (etaf-install--manage-reprint
     (etaf-install--format-update-summary report))))

(defun etaf-install--manage-update-all ()
  "Update every installed target and the installer."
  (when (y-or-n-p "Update all installed ETAF targets and the installer? ")
    (let ((report (etaf-install-update)))
      (etaf-install--manage-reprint
       (etaf-install--format-update-summary report)))))

(defun etaf-install--manage-remove ()
  "Remove the target at point."
  (let ((package (etaf-install--manage-current-target)))
    (etaf-install-remove package)
    (etaf-install--manage-reprint (current-message))))

(defun etaf-install--manage-open ()
  "Open the installed target at point."
  (let* ((package (etaf-install--manage-current-target))
         (target (etaf-install--target package))
         (open (nth 3 target)))
    (unless (package-installed-p package)
      (user-error "%s is not installed" package))
    (unless open
      (user-error "%s has no open command" package))
    (let* ((facts (etaf-install-doctor package))
           (missing (cl-remove-if #'cadr (plist-get facts :required))))
      (if missing
          (progn
            (etaf-install--display-doctor package facts)
            (message "ETAF: %s requires %s — see *ETAF Installation*."
                     package (mapconcat #'car missing ", ")))
        (call-interactively open)))))

(defun etaf-install--manage-install-native (&optional force)
  "Install prebuilt native module(s) for the target at point."
  (let ((package (etaf-install--manage-current-target)))
    (unless (package-installed-p package)
      (user-error "Install %s first (press `i')" package))
    (etaf-install-native package force)
    (etaf-install--manage-reprint (current-message))))

(defun etaf-install--manage-doctor ()
  "Show the doctor report for the target at point."
  (etaf-install--display-doctor (etaf-install--manage-current-target)))

(defun etaf-install--manage-refresh-archives ()
  "Refresh the ETAF and installed targets' standard archives."
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
  (let ((display-buffer-overriding-action '((display-buffer-pop-up-window))))
    (list-packages)))

(defun etaf-install--manage-quit ()
  "Quit the ETAF Packages window."
  (setq etaf-install--manage-suppress-hints t)
  (quit-window))

(defvar etaf-install--manage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "i")
      (lambda () "Install the target at point." (interactive)
        (etaf-install--manage-install)))
    (define-key map (kbd "n")
      (lambda (&optional force)
        "Install prebuilt native module(s) for the target at point."
        (interactive "P")
        (etaf-install--manage-install-native force)))
    (define-key map (kbd "u")
      (lambda () "Update the target at point." (interactive)
        (etaf-install--manage-update)))
    (define-key map (kbd "U")
      (lambda () "Update every installed target and the installer." (interactive)
        (etaf-install--manage-update-all)))
    (define-key map (kbd "d")
      (lambda () "Remove the target at point." (interactive)
        (etaf-install--manage-remove)))
    (define-key map (kbd "RET")
      (lambda () "Open the installed target at point." (interactive)
        (etaf-install--manage-open)))
    (define-key map (kbd "?")
      (lambda () "Show the doctor report for the target at point." (interactive)
        (etaf-install--manage-doctor)))
    (define-key map (kbd "g")
      (lambda () "Refresh the ETAF and installed targets' standard archives." (interactive)
        (etaf-install--manage-refresh-archives)))
    (define-key map (kbd "l")
      (lambda () "Open the standard package menu beside the ETAF list." (interactive)
        (etaf-install--manage-list-packages)))
    (define-key map (kbd "q")
      (lambda () "Quit the ETAF Packages window." (interactive)
        (etaf-install--manage-quit)))
    map)
  "Key map for `etaf-install--manage-mode'.")

(define-derived-mode etaf-install--manage-mode tabulated-list-mode "ETAF Packages"
  "Major mode for the ETAF Packages buffer."
  :interactive nil
  (setq tabulated-list-format
        [("Status" 16 t) ("Target" 54 t) ("Group" 12 t)
         ("Installed" 10 t) ("Available" 10 t) ("Runtime" 8 t)
         ("System CLI" 27 t) ("Depends on" 44 t)])
  (setq tabulated-list-entries #'etaf-install--manage-entries)
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'etaf-install--manage-on-revert nil t)
  (add-hook 'window-size-change-functions #'etaf-install--manage-on-resize nil t)
  (add-hook 'post-command-hook #'etaf-install--manage-post-command nil t)
  (setq-local mode-line-format '(:eval (etaf-install--manage-mode-line)))
  (hl-line-mode 1)
  (tabulated-list-init-header))

(defun etaf-install-manage ()
  "Show and manage installed and available ETAF targets.
The buffer is the whole interface: a native tabulated list of every target with
its status, versions, runtime, manual System CLI tools and Lisp dependencies,
plus the archive's community packages.  Column widths adapt to visible content
and window width, keeping full details available on hover tooltips.  The echo
area shows the key hints.
`i' installs, `n' installs native modules, `u' updates, `U' updates all, `d'
removes, RET opens, `?' reports capabilities, `g' refreshes the archives, `l'
shows the standard package menu and `q' quits.  Removal deletes package files
only; application data, logins and caches stay."
  (interactive)
  (unless package--initialized (package-initialize))
  (etaf-install--archive)
  (etaf-install--register-installed-archives)
  (let ((buffer (get-buffer-create "*ETAF Packages*")))
    ;; The table is the whole interface: take the frame first so the initial
    ;; responsive layout measures the real displayed window width.
    (delete-other-windows)
    (switch-to-buffer buffer)
    (with-current-buffer buffer
      (etaf-install--manage-mode)
      (etaf-install--manage-invalidate)
      (etaf-install--manage-apply-layout)
      (tabulated-list-print t))
    (etaf-install--manage-show-current)))

(etaf-install--register-installed-archives)

(provide 'etaf-install-manage)
;;; etaf-install-manage.el ends here
