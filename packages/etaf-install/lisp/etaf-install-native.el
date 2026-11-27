;;; etaf-install-native.el --- Prebuilt native module installer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Download, SHA-256 verify, cache and activate prebuilt Emacs dynamic
;; modules declared in package `native/manifest.json' files.

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'subr-x)
(require 'etaf-install-catalog)

(defvar url-http-response-status)
(declare-function ekp-c-module-load "ekp" ())

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

(defun etaf-install--native-library-cache-path (package version lib-name)
  "Return the cached path for PACKAGE VERSION's companion shared library LIB-NAME."
  (unless (and (stringp lib-name)
               (string-match-p
                "\\`[a-z0-9][a-z0-9._-]*\\.\\(dylib\\|so\\(?:\\.[0-9]+\\)*\\|dll\\)\\'"
                lib-name))
    (error "Invalid companion library name in native manifest: %S" lib-name))
  (expand-file-name
   lib-name
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

(defun etaf-install--etaf-dependency-closure (package)
  "Return PACKAGE plus its installed ETAF dependency closure as symbols.
Walks requirements from both installed and archive descriptors so updating
PACKAGE also upgrades any outdated ETAF dependencies it relies on, without
touching unrelated ETAF targets or non-ETAF third-party packages."
  (let ((etaf-names (mapcar #'car (etaf-install--available-targets)))
        (seen (list package))
        (result (list package))
        (pending (list package)))
    (while pending
      (let ((name (pop pending)))
        (dolist (desc (delq nil
                            (list (etaf-install--newest-installed-desc name)
                                  (cadr (assq name package-archive-contents)))))
          (dolist (req (package-desc-reqs desc))
            (let ((dep (car req)))
              (unless (or (eq dep 'emacs) (memq dep seen))
                (push dep seen)
                (when (and (memq dep etaf-names) (package-installed-p dep))
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
               (libs (and (hash-table-p entry) (gethash "libraries" entry)))
               (libs-ok
                (or local
                    (cl-every
                     (lambda (lib)
                       (and (hash-table-p lib)
                            (let* ((lname (gethash "name" lib))
                                   (lsha (gethash "sha256" lib))
                                   (ldest (ignore-errors
                                            (etaf-install--native-library-cache-path
                                             package version lname))))
                              (and ldest lsha
                                   (etaf-install--native-cached-p ldest lsha)))))
                     libs)))
               (present (and libs-ok
                             (or local
                                 (and sha (etaf-install--native-cached-p dest sha))
                                 (and (null sha) (file-exists-p dest))))))
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
  (let* ((curl (executable-find "curl"))
         (curl-ok
          (and curl
               (zerop (call-process
                       curl nil nil nil
                       "-fsSL" "--compressed"
                       "--noproxy" "127.0.0.1,localhost"
                       "--retry" "2"
                       "--connect-timeout" "20"
                       "--max-time" "300"
                       "-o" destination url))
               (file-exists-p destination))))
    (unless curl-ok
      (when (file-exists-p destination)
        (ignore-errors (delete-file destination)))
      (let ((buffer (url-retrieve-synchronously url t t 120)))
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
            (kill-buffer buffer)))))))

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
        (dolist (lib (gethash "libraries" entry))
          (unless (hash-table-p lib)
            (error "Invalid companion library record for %s" name))
          (let* ((lib-name (gethash "name" lib))
                 (lib-sha (gethash "sha256" lib))
                 (lib-dest (etaf-install--native-library-cache-path
                            package version lib-name))
                 (lib-cached (and (not force)
                                  (etaf-install--native-cached-p lib-dest lib-sha))))
            (if lib-cached
                (push (cons lib-name lib-dest) skipped)
              (message "ETAF: downloading %s (%s)…" lib-name platform)
              (etaf-install--native-fetch-verified package version lib lib-dest)
              (push (cons lib-name lib-dest) installed))))
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

(provide 'etaf-install-native)
;;; etaf-install-native.el ends here
