;;; -*- lexical-binding: t; -*-
;;; etaf-install.el --- Install ETAF with the Emacs package manager

;; Version: 0.2.31
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
;; Function: etaf-install-doctor (&optional package)
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
;; Show installed and available ETAF targets in a native tabulated list.  The
;; buffer includes a `System CLI' column showing only manual OS command-line
;; tools the user must install (excluding auto-downloaded native modules,
;; bundled package backends and managed game engines), and supports install,
;; native download, update, remove, open, doctor and refresh through
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
;; Return installed and available versions, the update flag, runtime status,
;; manual `:system-cli' requirements and dependency closure for PACKAGE or
;; every supported target.
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
    (etaf-ext "Universal extension engine and manager" framework etaf-ext-manage melpa)
    (etaf "ETAF framework" framework nil)
    (etaf-db "ETAF SQLite backend" framework nil sqlite)
    (ekp "Knuth-Plass paragraph layout" framework nil)
    (etaf-hints "Quick jump hints extension" extension nil melpa)
    (etaf-highlight "Highlighter and notes extension" extension nil melpa)
    (etaf-translate "Immersive page translation extension" extension nil melpa)
    (etaf-export "Vector PDF and SVG export extension" extension nil melpa)
    (etaf-manual "ETAF reference manual" application etaf-manual-open)
    (etaf-md "Markdown reading view" application etaf-md-open)
    (etaf-org "Org reading view and living documents" application etaf-org-open)
    (etaf-video-player "Video with sound in a buffer" application etaf-video-player-open)
    (etaf-desktop "Windows and workspaces" application etaf-desktop-open)
    ;; MELPA supplies Telega and Transient; Transient needs Compat from GNU ELPA.
    (etaf-telega "Telegram client" application etaf-telega-open melpa gnu)
    (etaf-weread "WeChat Reading" application etaf-weread-open)
    (etaf-ncm "NetEase Cloud Music" application etaf-ncm-open)
    (etaf-bili "Bilibili client" application etaf-bili-open)
    (etaf-youtube "YouTube client" application etaf-youtube-open)
    (etaf-pomodoro "Focus timer" application etaf-pomodoro-open)
    (maillist "Mailing-list archive client" application maillist-open sqlite)
    (etaf-xiangqi "Xiangqi" game etaf-xiangqi-open)
    (etaf-tanks "Tank battle" game etaf-tanks-open))
  "Installable targets as (PACKAGE LABEL GROUP OPEN &rest CAPABILITIES).
GROUP groups the menu: `framework', `extension', `application' or `game'.
Only packages built on `etaf-ext' use `extension'.  OPEN is the
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
  '((framework . "Framework") (extension . "Extension")
    (application . "Application") (game . "Game"))
  "Menu prefix for each target group.")

(defun etaf-install--target-choices ()
  "Return completion candidates as (LABEL . PACKAGE), grouped in menu order."
  (let (choices)
    (dolist (group '(framework extension application game))
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

;;; Manual system CLI catalog and platform install commands

(defvar etaf-install--package-manager-override nil
  "Internal test override for `etaf-install--detect-package-manager'.
When set to a package manager symbol (such as `brew', `apt', `pacman' or
`winget'), forces that package manager; when `none', simulates none found.")

(defconst etaf-install--cli-catalog
  '((ffmpeg
     :name "ffmpeg" :label "ffmpeg" :binaries ("ffmpeg" "ffprobe")
     :packages ((brew . "ffmpeg") (apt . "ffmpeg") (dnf . "ffmpeg")
                (pacman . "ffmpeg") (zypper . "ffmpeg")
                (winget . "Gyan.FFmpeg") (scoop . "ffmpeg") (choco . "ffmpeg"))
     :purpose "Video decoding, ffprobe metadata and inline playback.")
    (mpv
     :name "mpv" :label "mpv" :binaries ("mpv")
     :packages ((brew . "mpv") (apt . "mpv") (dnf . "mpv")
                (pacman . "mpv") (zypper . "mpv")
                (winget . "shinchiro.mpv") (scoop . "mpv") (choco . "mpv"))
     :purpose "Audio playback engine.")
    (node
     :name "node" :label "Node.js" :binaries ("node")
     :packages ((brew . "node") (apt . "nodejs") (dnf . "nodejs")
                (pacman . "nodejs") (zypper . "nodejs22")
                (winget . "OpenJS.NodeJS.LTS") (scoop . "nodejs-lts")
                (choco . "nodejs-lts"))
     :purpose "Runs the package's bundled JavaScript backend (Node.js 22+).")
    (python3
     :name "python3" :label "Python 3" :binaries ("python3")
     :packages ((brew . "python") (apt . "python3") (dnf . "python3")
                (pacman . "python") (zypper . "python3")
                (winget . "Python.Python.3.12") (scoop . "python")
                (choco . "python"))
     :purpose "Runs Python helper scripts or game-engine virtual environments.")
    (rsvg-convert
     :name "rsvg-convert" :label "rsvg-convert" :binaries ("rsvg-convert")
     :extra-paths ("/opt/homebrew/bin/rsvg-convert"
                   "/usr/local/bin/rsvg-convert"
                   "/usr/bin/rsvg-convert")
     :packages ((brew . "librsvg") (apt . "librsvg2-bin")
                (dnf . "librsvg2-tools") (pacman . "librsvg")
                (zypper . "rsvg-convert") (scoop . "librsvg"))
     :purpose "Converts vector SVG pages to PDF (SVG/live preview need none).")
    (telega-server
     :name "telega-server" :label "telega-server" :binaries ("telega-server")
     :packages nil
     :custom-note
     "Install TDLib (e.g. brew install tdlib), then run M-x telega-server-build and ensure telega-server is on exec-path."
     :purpose "Native TDLib bridge required by Telega.")
    (qrencode
     :name "qrencode" :label "qrencode" :binaries ("qrencode")
     :packages ((brew . "qrencode") (apt . "qrencode") (dnf . "qrencode")
                (pacman . "qrencode") (zypper . "qrencode"))
     :purpose "Draws PNG QR codes for QR blocks and QR sign-in.")
    (git
     :name "git" :label "git" :binaries ("git")
     :packages ((brew . "git") (apt . "git") (dnf . "git")
                (pacman . "git") (zypper . "git")
                (winget . "Git.Git") (scoop . "git") (choco . "git"))
     :purpose "Powers git-log and git-diff live document widgets.")
    (rg
     :name "rg" :label "ripgrep (rg)" :binaries ("rg")
     :packages ((brew . "ripgrep") (apt . "ripgrep") (dnf . "ripgrep")
                (pacman . "ripgrep") (zypper . "ripgrep")
                (winget . "BurntSushi.ripgrep.MSVC") (scoop . "ripgrep")
                (choco . "ripgrep"))
     :purpose "Accelerates workspace backlink scans.")
    (dot
     :name "dot" :label "Graphviz (dot)" :binaries ("dot")
     :packages ((brew . "graphviz") (apt . "graphviz") (dnf . "graphviz")
                (pacman . "graphviz") (zypper . "graphviz")
                (winget . "Graphviz.Graphviz") (scoop . "graphviz")
                (choco . "graphviz"))
     :purpose "Renders Graphviz dot source blocks.")
    (plantuml
     :name "plantuml" :label "PlantUML" :binaries ("plantuml")
     :packages ((brew . "plantuml") (apt . "plantuml") (dnf . "plantuml")
                (pacman . "plantuml") (zypper . "plantuml")
                (scoop . "plantuml") (choco . "plantuml"))
     :purpose "Renders PlantUML source blocks.")
    (curl
     :name "curl" :label "curl" :binaries ("curl")
     :packages ((brew . "curl") (apt . "curl") (dnf . "curl")
                (pacman . "curl") (zypper . "curl")
                (winget . "cURL.cURL") (scoop . "curl") (choco . "curl"))
     :purpose "Calls HTTP APIs, translation engines and thumbnail/cover downloads.")
    (yt-dlp
     :name "yt-dlp" :label "yt-dlp" :binaries ("yt-dlp")
     :packages ((brew . "yt-dlp") (apt . "yt-dlp") (dnf . "yt-dlp")
                (pacman . "yt-dlp") (zypper . "yt-dlp")
                (winget . "yt-dlp.yt-dlp") (scoop . "yt-dlp") (choco . "yt-dlp"))
     :purpose "Resolves adaptive YouTube video/audio streams, chapters and subtitles."))
  "Catalog of external OS CLI tools users install themselves.
Excludes prebuilt native dynamic modules (auto-downloaded via
`etaf-install-native'), bundled `backends/' scripts shipped inside package
tarballs, and ETAF-managed game engines (`etaf-gamekit-install-*').")

(defconst etaf-install--system-tools
  '((etaf-export       :required (rsvg-convert))
    (etaf-translate    :optional (curl))
    (etaf-md           :optional (ffmpeg qrencode git))
    (etaf-org          :optional (ffmpeg qrencode git rg dot plantuml))
    (etaf-video-player :required (ffmpeg))
    (etaf-telega       :required (telega-server))
    (etaf-weread       :required (node))
    (etaf-ncm          :required (node python3 mpv) :optional (qrencode))
    (etaf-bili         :required (curl) :optional (node ffmpeg mpv))
    (etaf-youtube      :required (node yt-dlp curl) :optional (ffmpeg mpv))
    (etaf-xiangqi      :required (python3)
                       :managed-engines (("OpenSpiel runtime" etaf-gamekit-install-openspiel)))
    (etaf-tanks        :managed-engines (("Godot runtime" etaf-gamekit-install-godot))))
  "Manual system CLI and managed-engine metadata for curated ETAF targets.
`:required' and `:optional' list ONLY external OS CLI tool keys from
`etaf-install--cli-catalog'.  Auto-downloaded prebuilt native modules and
bundled package backends are intentionally excluded from `System CLI'.")

(defun etaf-install--detect-package-manager ()
  "Return the OS package manager available on PATH, or nil."
  (cond
   ((eq etaf-install--package-manager-override 'none) nil)
   (etaf-install--package-manager-override)
   ((eq system-type 'darwin)
    (and (executable-find "brew") 'brew))
   ((eq system-type 'windows-nt)
    (cond ((executable-find "winget") 'winget)
          ((executable-find "scoop") 'scoop)
          ((executable-find "choco") 'choco)))
   (t
    (cond ((or (executable-find "apt") (executable-find "apt-get")) 'apt)
          ((executable-find "dnf") 'dnf)
          ((executable-find "pacman") 'pacman)
          ((executable-find "zypper") 'zypper)
          ((executable-find "brew") 'brew)))))

(defun etaf-install--preferred-package-manager ()
  "Return the detected OS package manager, or this OS's standard default."
  (or (etaf-install--detect-package-manager)
      (pcase system-type
        ('darwin 'brew)
        ('windows-nt 'winget)
        (_ 'apt))))

(defun etaf-install--cli-installed-p (tool)
  "Return non-nil when manual system CLI TOOL is installed on this machine."
  (let* ((spec (cdr (assq tool etaf-install--cli-catalog)))
         (binaries (plist-get spec :binaries))
         (extras (plist-get spec :extra-paths)))
    (and binaries
         (cl-every
          (lambda (bin)
            (or (executable-find bin)
                (and extras
                     (cl-some #'file-executable-p extras))))
          binaries))))

(defun etaf-install--pm-command (pm packages)
  "Format one copyable shell command for package manager PM and PACKAGES."
  (let ((pkgs (delete-dups (delq nil (copy-sequence packages)))))
    (when pkgs
      (pcase pm
        ('brew (concat "brew install " (mapconcat #'identity pkgs " ")))
        ('apt (concat "sudo apt install " (mapconcat #'identity pkgs " ")))
        ('dnf (concat "sudo dnf install " (mapconcat #'identity pkgs " ")))
        ('pacman (concat "sudo pacman -S " (mapconcat #'identity pkgs " ")))
        ('zypper (concat "sudo zypper install " (mapconcat #'identity pkgs " ")))
        ('scoop (concat "scoop install " (mapconcat #'identity pkgs " ")))
        ('choco (concat "choco install " (mapconcat #'identity pkgs " ")))
        ('winget (mapconcat (lambda (p) (concat "winget install " p)) pkgs " && "))
        (_ nil)))))

(defun etaf-install--cli-install-commands (tools &optional pm)
  "Return combined copyable install command(s) for TOOLS under PM.
Return a list of command strings (usually 1 string combining OS packages)."
  (let* ((pm (or pm (etaf-install--preferred-package-manager)))
         (pm-pkgs nil)
         (custom-cmds nil))
    (dolist (tool (delete-dups (copy-sequence tools)))
      (let* ((spec (cdr (assq tool etaf-install--cli-catalog)))
             (pkg (cdr (assq pm (plist-get spec :packages))))
             (custom (plist-get spec :custom-cmd)))
        (cond
         (pkg (push pkg pm-pkgs))
         (custom (push custom custom-cmds)))))
    (let ((pm-cmd (etaf-install--pm-command pm (nreverse pm-pkgs)))
          (extras (delete-dups (nreverse custom-cmds))))
      (if pm-cmd (cons pm-cmd extras) extras))))

(defun etaf-install--cli-combined-command (tools &optional pm)
  "Return a single copyable shell command installing TOOLS, or nil."
  (let ((cmds (etaf-install--cli-install-commands tools pm)))
    (when cmds
      (mapconcat #'identity cmds " && "))))

(defun etaf-install--cli-remedy (tool &optional optional-p)
  "Return a platform-aware remedy sentence for missing manual CLI TOOL."
  (let* ((spec (cdr (assq tool etaf-install--cli-catalog)))
         (label (or (plist-get spec :label) (symbol-name tool)))
         (purpose (plist-get spec :purpose))
         (custom-note (plist-get spec :custom-note))
         (cmd (etaf-install--cli-combined-command (list tool)))
         (prefix (if optional-p "Optional: " "")))
    (cond
     (custom-note (concat prefix custom-note))
     (cmd (format "%sInstall %s (%s).%s"
                  prefix label cmd
                  (if purpose (concat " " purpose) "")))
     (t (format "%sInstall %s with your system package manager.%s"
                prefix label (if purpose (concat " " purpose) ""))))))

(defun etaf-install--label-to-cli-tool (label)
  "Map a doctor fact LABEL string to a tool key in `etaf-install--cli-catalog'."
  (let ((low (downcase (or label ""))))
    (cond
     ((or (string-prefix-p "node" low) (equal low "node.js")) 'node)
     ((or (string-prefix-p "python" low) (equal low "python3")) 'python3)
     ((equal low "mpv") 'mpv)
     ((member low '("ffmpeg" "ffprobe" "ffplay")) 'ffmpeg)
     ((string-prefix-p "rsvg-convert" low) 'rsvg-convert)
     ((equal low "telega-server") 'telega-server)
     ((equal low "qrencode") 'qrencode)
     ((equal low "git") 'git)
     ((or (equal low "rg") (string-prefix-p "ripgrep" low)) 'rg)
     ((or (equal low "dot") (string-prefix-p "graphviz" low)) 'dot)
     ((string-prefix-p "plantuml" low) 'plantuml)
     ((equal low "curl") 'curl)
     ((equal low "yt-dlp") 'yt-dlp)
     (t nil))))

(defun etaf-install--enrich-fact (fact)
  "Append a platform-specific install command to unavailable FACT when helpful."
  (let ((label (car fact))
        (avail (cadr fact))
        (remedy (or (nth 2 fact) "")))
    (if avail
        fact
      (let* ((tool (etaf-install--label-to-cli-tool label))
             (cmd (and tool (etaf-install--cli-combined-command (list tool)))))
        (if (and cmd (not (string-match-p (regexp-quote cmd) remedy)))
            (list label avail (format "%s  Try: %s" remedy cmd))
          fact)))))

(defun etaf-install--system-cli-summary (package)
  "Return manual system CLI summary plist for PACKAGE, or nil if none."
  (let* ((entry (cdr (assq package etaf-install--system-tools)))
         (req-tools (plist-get entry :required))
         (opt-tools (plist-get entry :optional)))
    (when (or req-tools opt-tools)
      (let* ((req-alist (mapcar (lambda (tool)
                                  (cons tool (and (etaf-install--cli-installed-p tool) t)))
                                req-tools))
             (opt-alist (mapcar (lambda (tool)
                                  (cons tool (and (etaf-install--cli-installed-p tool) t)))
                                opt-tools))
             (missing-req (cl-loop for (tool . ok) in req-alist
                                   unless ok collect tool))
             (missing-opt (cl-loop for (tool . ok) in opt-alist
                                   unless ok collect tool))
             (cmd (etaf-install--cli-combined-command
                   (or missing-req missing-opt))))
        (list :required req-alist
              :optional opt-alist
              :missing-required missing-req
              :missing-optional missing-opt
              :install-command cmd)))))

(defun etaf-install--missing-cli-tools-from-facts (facts section)
  "Return manual CLI tool symbols unavailable in FACTS's SECTION."
  (let (tools)
    (dolist (fact (plist-get facts section))
      (unless (cadr fact)
        (when-let* ((tool (etaf-install--label-to-cli-tool (car fact))))
          (push tool tools))))
    (delete-dups (nreverse tools))))

(defun etaf-install--missing-install-command (_package facts)
  "Return the combined copyable install command for missing required CLIs."
  (let ((missing-req (etaf-install--missing-cli-tools-from-facts facts :required)))
    (when missing-req
      (etaf-install--cli-combined-command missing-req))))

(defun etaf-install--missing-managed-engine (package missing-facts)
  "Return (LABEL COMMAND) for the first missing managed engine of PACKAGE."
  (let ((engines (plist-get (cdr (assq package etaf-install--system-tools))
                            :managed-engines)))
    (cl-find-if
     (lambda (eng)
       (cl-some (lambda (fact) (equal (car fact) (car eng))) missing-facts))
     engines)))

;;; Interactive installation & doctor guide buffer

(defvar-local etaf-install--doctor-package nil
  "Target package currently displayed in `*ETAF Installation*'.")

(defvar-local etaf-install--doctor-copy-cmd nil
  "Combined shell command ready to copy from `*ETAF Installation*'.")

(defun etaf-install--doctor-copy-command ()
  "Copy the combined system install command in `*ETAF Installation*'."
  (interactive)
  (unless (and (stringp etaf-install--doctor-copy-cmd)
               (not (string-empty-p etaf-install--doctor-copy-cmd)))
    (user-error "No system install command to copy for %s"
                (or etaf-install--doctor-package "this package")))
  (kill-new etaf-install--doctor-copy-cmd)
  (message "ETAF: copied install command: %s" etaf-install--doctor-copy-cmd))

(defun etaf-install--doctor-recheck ()
  "Re-run capability checks for the package shown in `*ETAF Installation*'."
  (interactive)
  (let ((package (or etaf-install--doctor-package
                     (user-error "No ETAF package in this buffer"))))
    (let ((facts (etaf-install-doctor package)))
      (etaf-install--render-doctor-buffer package facts)
      (when-let* ((mgr (get-buffer "*ETAF Packages*"))
                  ((buffer-live-p mgr)))
        (with-current-buffer mgr
          (when (derived-mode-p 'etaf-install--manage-mode)
            (etaf-install--manage-invalidate)
            (tabulated-list-revert))))
      (if (plist-get facts :ready)
          (message "ETAF: %s is ready%s"
                   package
                   (if (and (package-installed-p package)
                            (nth 3 (etaf-install--target package)))
                       " — press `o' to open."
                     "."))
        (let ((missing (cl-remove-if #'cadr (plist-get facts :required))))
          (message "ETAF: %s still missing %s."
                   package (mapconcat #'car missing ", ")))))))

(defun etaf-install--doctor-open ()
  "Open the package shown in `*ETAF Installation*' when installed and ready."
  (interactive)
  (let* ((package (or etaf-install--doctor-package
                      (user-error "No ETAF package in this buffer")))
         (target (etaf-install--target package))
         (open (nth 3 target)))
    (unless (package-installed-p package)
      (user-error "%s is not installed yet; run M-x etaf-install" package))
    (unless open
      (user-error "%s has no open command" package))
    (let* ((facts (etaf-install-doctor package))
           (missing (cl-remove-if #'cadr (plist-get facts :required))))
      (when missing
        (etaf-install--render-doctor-buffer package facts)
        (user-error "%s still requires %s" package (mapconcat #'car missing ", "))))
    (call-interactively open)))

(defun etaf-install--doctor-install-native ()
  "Install prebuilt native module(s) for the package in `*ETAF Installation*'."
  (interactive)
  (let ((package (or etaf-install--doctor-package
                     (user-error "No ETAF package in this buffer"))))
    (etaf-install-native package)
    (etaf-install--render-doctor-buffer package (etaf-install-doctor package))))

(defvar etaf-install--doctor-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "c") #'etaf-install--doctor-copy-command)
    (define-key map (kbd "r") #'etaf-install--doctor-recheck)
    (define-key map (kbd "o") #'etaf-install--doctor-open)
    (define-key map (kbd "n") #'etaf-install--doctor-install-native)
    map)
  "Keymap for `*ETAF Installation*' doctor guide buffer.")

(define-derived-mode etaf-install--doctor-mode special-mode "ETAF Doctor"
  "Major mode for the interactive `*ETAF Installation*' guide buffer."
  (setq-local truncate-lines nil))

(defun etaf-install--render-doctor-buffer (package facts)
  "Render PACKAGE's doctor FACTS into `*ETAF Installation*' and return buffer."
  (let* ((buf (get-buffer-create "*ETAF Installation*"))
         (required (plist-get facts :required))
         (optional (plist-get facts :optional))
         (missing-req (cl-remove-if #'cadr required))
         (missing-req-tools (etaf-install--missing-cli-tools-from-facts facts :required))
         (missing-opt-tools (etaf-install--missing-cli-tools-from-facts facts :optional))
         (pm (etaf-install--preferred-package-manager))
         (req-cmd (and missing-req-tools
                       (etaf-install--cli-combined-command missing-req-tools pm)))
         (opt-cmd (and (null req-cmd) missing-opt-tools
                       (etaf-install--cli-combined-command missing-opt-tools pm)))
         (copy-cmd (or req-cmd opt-cmd))
         (engine (and missing-req (etaf-install--missing-managed-engine package missing-req)))
         (installed-p (package-installed-p package))
         (open-cmd (nth 3 (etaf-install--target package)))
         (native-status (and installed-p (etaf-install--native-status package))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (etaf-install--doctor-mode)
        (setq etaf-install--doctor-package package
              etaf-install--doctor-copy-cmd copy-cmd)
        (insert (propertize (format "ETAF installation: %s\n" package) 'face 'bold))
        (insert (propertize (format "Emacs %s on %s" emacs-version system-type) 'face 'shadow))
        (insert "   ")
        (if missing-req
            (insert (propertize
                     (format "Missing %d required item%s\n\n"
                             (length missing-req)
                             (if (= (length missing-req) 1) "" "s"))
                     'face 'warning))
          (insert (propertize
                   (if installed-p "Ready\n\n" "Prerequisites met (not installed yet)\n\n")
                   'face 'success)))
        (when (or req-cmd engine (eq native-status 'available)
                  (and installed-p (null missing-req) open-cmd))
          (insert (propertize "Quick actions\n" 'face 'bold))
          (when req-cmd
            (insert (format "  Install missing system CLI tools (%s):\n"
                            (or pm system-type)))
            (insert "    " (propertize req-cmd 'face 'font-lock-keyword-face) "\n"))
          (insert "  ")
          (when req-cmd
            (insert-text-button
             "[Copy command (c)]"
             'action (lambda (_btn) (etaf-install--doctor-copy-command))
             'follow-link t
             'help-echo "Copy the system install command to the kill ring")
            (insert "  "))
          (when (and engine (fboundp (cadr engine)))
            (let ((eng-cmd (cadr engine))
                  (eng-label (car engine)))
              (insert-text-button
               (format "[Install %s]" eng-label)
               'action (lambda (_btn) (call-interactively eng-cmd))
               'follow-link t
               'help-echo (format "Run M-x %s" eng-cmd))
              (insert "  ")))
          (when (eq native-status 'available)
            (insert-text-button
             "[Install native (n)]"
             'action (lambda (_btn) (etaf-install--doctor-install-native))
             'follow-link t
             'help-echo "Download and verify prebuilt native dynamic module(s)")
            (insert "  "))
          (insert-text-button
           "[Re-check (r)]"
           'action (lambda (_btn) (etaf-install--doctor-recheck))
           'follow-link t
           'help-echo "Re-run capability checks after installing tools")
          (when (and installed-p (null missing-req) open-cmd)
            (insert "  ")
            (insert-text-button
             (format "[Open %s (o)]" package)
             'action (lambda (_btn) (etaf-install--doctor-open))
             'follow-link t
             'help-echo (format "Run M-x %s" open-cmd)))
          (insert "\n\n"))
        (dolist (section (list (cons "Required" required) (cons "Optional" optional)))
          (insert (propertize (format "%s\n" (car section)) 'face 'bold))
          (dolist (fact (cdr section))
            (let ((avail (cadr fact)))
              (insert "  "
                      (propertize (if avail "✓" "✗")
                                  'face (if avail 'success
                                          (if (equal (car section) "Required")
                                              'warning 'shadow)))
                      (format " %s: %s\n" (car fact)
                              (if avail "available" "unavailable")))
              (unless avail
                (insert (propertize (format "    %s\n" (nth 2 fact)) 'face 'shadow)))))
          (insert "\n"))
        (when opt-cmd
          (insert (propertize "Optional system CLI install command\n" 'face 'bold))
          (insert "  " (propertize opt-cmd 'face 'font-lock-keyword-face) "  ")
          (insert-text-button
           "[Copy (c)]"
           'action (lambda (_btn) (etaf-install--doctor-copy-command))
           'follow-link t
           'help-echo "Copy the optional system CLI install command")
          (insert "\n\n"))
        (insert (propertize
                 "Keys: c copy command   r re-check   o open   n native   q quit\n"
                 'face 'shadow))
        (insert "Install: M-x etaf-install   Manage/update/remove: M-x etaf-install-manage\n")
        (insert "Restart Emacs after upgrading loaded packages.\n")
        (goto-char (point-min))))
    buf))

(defun etaf-install--display-doctor (package &optional facts)
  "Show PACKAGE's doctor FACTS in the interactive `*ETAF Installation*' buffer."
  (let* ((facts (or facts (etaf-install-doctor package)))
         (buf (etaf-install--render-doctor-buffer package facts)))
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun etaf-install-doctor (&optional package)
  "Check required and optional capabilities for PACKAGE without modifying state."
  (interactive (list (etaf-install--read-target)))
  (let* ((package (or package 'etaf-ui))
         (target (etaf-install--target package))
         (doctor-fn (intern (format "%s-doctor" package)))
         (required
          (list (list "Emacs 29.1 or newer" (not (version< emacs-version "29.1"))
                      "Use Emacs 29.1 or newer; your existing configuration is preserved.")))
         (optional
          (list (list "Native Lisp compilation"
                      (and (fboundp 'native-comp-available-p) (native-comp-available-p))
                      "Byte compilation works without it; a native-comp capable Emacs can improve speed."))))
    (if (fboundp doctor-fn)
        (let ((facts (funcall doctor-fn)))
          (setq required (append required (mapcar #'etaf-install--enrich-fact
                                                  (plist-get facts :required)))
                optional (append optional (mapcar #'etaf-install--enrich-fact
                                                  (plist-get facts :optional)))))
      ;; Before PACKAGE is installed, synthesize manual System CLI and managed
      ;; engine facts from the declarative catalog so users see prerequisites upfront.
      (when-let* ((entry (cdr (assq package etaf-install--system-tools))))
        (dolist (tool (plist-get entry :required))
          (let ((spec (cdr (assq tool etaf-install--cli-catalog))))
            (setq required
                  (append required
                          (list (list (or (plist-get spec :label) (symbol-name tool))
                                      (and (etaf-install--cli-installed-p tool) t)
                                      (etaf-install--cli-remedy tool)))))))
        (dolist (eng (plist-get entry :managed-engines))
          (setq required
                (append required
                        (list (list (car eng) nil
                                    (format "Install it once after installing %s: M-x %s"
                                            package (cadr eng)))))))
        (dolist (tool (plist-get entry :optional))
          (let ((spec (cdr (assq tool etaf-install--cli-catalog))))
            (setq optional
                  (append optional
                          (list (list (or (plist-get spec :label) (symbol-name tool))
                                      (and (etaf-install--cli-installed-p tool) t)
                                      (etaf-install--cli-remedy tool t)))))))))
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
           (post-facts (etaf-install-doctor package))
           (missing (cl-remove-if #'cadr (plist-get post-facts :required)))
           (managed-started nil))
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
          :system-cli (etaf-install--system-cli-summary package)
          :remedy remedy
          :dependencies (and descriptor (etaf-install--dependency-names descriptor)))))

;;;###autoload
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

;;;###autoload
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

(provide 'etaf-install)
;;; etaf-install.el ends here
