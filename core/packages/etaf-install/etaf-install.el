;;; -*- lexical-binding: t; -*-
;;; etaf-install.el --- Install ETAF with the Emacs package manager

;; Version: 0.2.35
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
;;;###autoload (autoload 'etaf-install "etaf-install" nil t)
;; Install PACKAGE from the official archive and open its existing application.
;; Interactive use offers the supported targets grouped as framework,
;; extensions, applications and games, with the component gallery as the
;; default.  Each target may expose a `<package>-doctor' returning the same
;; :required and :optional facts as `etaf-install-doctor', which are merged
;; into its report.  NO-OPEN suppresses opening, for batch installation.
;; Return the installed package symbol.  Already installed targets can be
;; opened offline.  When `etaf-install-auto-native' is non-nil (the default),
;; any prebuilt native dynamic modules declared by PACKAGE or its installed
;; ETAF dependencies are automatically downloaded, verified (SHA-256), cached
;; and activated before opening so users need no compiler and no second
;; command; an unavailable or unreachable native prebuild never fails the Lisp
;; installation.  Missing mandatory Emacs capabilities or a conflicting source
;; checkout signal user-error before installation.  An upgrade of a loaded
;; dependency also requires a restart before installation.  A target's runtime
;; tools are reported after installation; interactive runs offer to run
;; ETAF-managed game engine installers when available and automatically open
;; `*ETAF Installation*' with a platform-specific copyable install command when
;; required system CLIs are missing.  On failure, remove only packages added by
;; this attempt, preserving older installations and unrelated packages.  Report
;; cleanup failures without hiding the installation error.  Restart before
;; retrying because partially loaded Lisp cannot be safely rolled back in this
;; process.  Use M-x etaf-install-manage for the supported lifecycle;
;; package.el owns upgrades and removal.  Restart Emacs after upgrading loaded
;; packages.
;;
;; Function: etaf-install-ensure (packages &optional refresh)
;;;###autoload (autoload 'etaf-install-ensure "etaf-install")
;; Declaratively ensure every target in PACKAGES (a symbol or list of symbols)
;; is installed from the official ETAF archive, intended for init files
;; alongside `use-package'.  Registers the ETAF archive locally without
;; editing init files.  When every target in PACKAGES is already installed and
;; REFRESH is nil, performs zero network requests and returns immediately so
;; startup stays fast and offline.  When any target is missing (or REFRESH is
;; non-nil), refreshes the needed archives once, installs each missing target
;; without opening its application, and ensures declared prebuilt native
;; modules when `etaf-install-auto-native' is non-nil.  Return a plist with
;; :installed, :already, :native-installed and :native-failed.  Signals
;; `user-error' for invalid package symbols or the same source/restart guards
;; as `etaf-install'.
;;
;; Function: etaf-install-doctor (&optional package)
;;;###autoload (autoload 'etaf-install-doctor "etaf-install" nil t)
;; Return a plist with :package, :ready, :required and :optional capability
;; facts.  Each capability fact is (LABEL AVAILABLE REMEDY).  PACKAGE defaults
;; to etaf-ui and works both before and after PACKAGE is installed.
;; Interactively show the facts in an interactive `*ETAF Installation*' buffer
;; with `c' to copy the combined system install command, `r' to re-check, `o'
;; to open when ready, `n' to install prebuilt native modules and `q' to quit.
;; This check performs no network requests, package installation or
;; configuration writes.
;;
;; Variable: etaf-install-archive-url
;; HTTPS URL of the ETAF package archive.  A local absolute directory is accepted
;; for offline installation and release verification.  Existing archives and
;; signature verification policy are preserved; this option never disables TLS.
;;
;; Function: etaf-install-manage ()
;;;###autoload (autoload 'etaf-install-manage "etaf-install" nil t)
;; Show installed and available ETAF targets in a native tabulated list.  The
;; buffer includes a `System CLI' column showing only manual OS command-line
;; tools the user must install (excluding auto-downloaded native modules,
;; bundled package backends and managed game engines), and supports install,
;; native download, update, remove, open, doctor and refresh through
;; package.el; it is the supported lifecycle entry for ETAF targets.
;;
;; Function: etaf-install-update (&optional package)
;;;###autoload (autoload 'etaf-install-update "etaf-install" nil t)
;; Refresh the ETAF and standard archives and upgrade PACKAGE together with its
;; installed ETAF dependency closure, or every installed target plus the
;; installer when PACKAGE is nil, in bottom-up dependency order.  Unrelated
;; targets and non-ETAF third-party packages are not upgraded unless required
;; by `Package-Requires'.  Removes superseded older package directories left by
;; dependency upgrades (respecting `package-retention-policy' and
;; `package-load-list').  When `etaf-install-auto-native' is non-nil, also
;; fetch any newly required or updated prebuilt native modules declared by
;; upgraded packages.  Return a plist with :updated, :pruned, :failed,
;; :native-installed, :native-failed and :restart.  Restart Emacs when an
;; update replaces loaded Lisp.
;;
;; Function: etaf-install-remove (package &optional no-confirm)
;;;###autoload (autoload 'etaf-install-remove "etaf-install" nil t)
;; Remove PACKAGE's package files and its `package-selected-packages' entry.
;; Application data, logins and caches are kept; shared dependencies remain.
;;
;; Function: etaf-install-status (&optional package)
;;;###autoload (autoload 'etaf-install-status "etaf-install")
;; Return installed and available versions, the update flag, runtime status,
;; manual `:system-cli' requirements and dependency closure for PACKAGE or
;; every supported target.
;;
;; Function: etaf-install-native (&optional package force)
;;;###autoload (autoload 'etaf-install-native "etaf-install" nil t)
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
;; Setup once using the installation block in the monorepo README, then use
;; M-x etaf-install.  Credentials and external application backends are outside
;; this installer's scope.  It offers only targets with a verified Lisp install.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-install")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-install.el" dir))
                                (file-exists-p (expand-file-name "etaf-install.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

;; package.el evaluates this when enabling the installed package.  Registering
;; an archive is local work, not a refresh; respect an existing same-named source.
;;;###autoload
(with-eval-after-load 'package
  (unless (assoc "etaf" package-archives)
    (add-to-list 'package-archives '("etaf" . "https://etaf.top/packages/"))))

(require 'etaf-install-catalog)
(require 'etaf-install-native)
(require 'etaf-install-doctor)
(require 'etaf-install-manage)

(provide 'etaf-install)
;;; etaf-install.el ends here
