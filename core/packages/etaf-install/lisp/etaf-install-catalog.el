;;; etaf-install-catalog.el --- Target catalog, manifest and CLI registry -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Internal target catalog, archive manifest loader, OS package-manager
;; command builder and archive refresh helpers for `etaf-install'.

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
    (etaf-doc "Shared document parsing, typesetting and widgets" framework nil)
    ;; The window manager itself comes from MELPA, which the installer only
    ;; registers when a target asks for it.
    (etaf-posframe "Floating panel host" framework nil melpa)
    (etaf-ext "Universal extension engine and manager" framework etaf-ext-manage melpa)
    (etaf "ETAF framework" framework nil)
    (etaf-media "Native video playback (libmpv/ffmpeg)" framework nil)
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

(defvar etaf-install-community-cache nil
  "Community packages read from the archive manifest, or nil when unread.")

(defvar etaf-install--manifest-cache nil
  "Parsed `manifest.json' hash table cached from the archive, or nil.")

(defvar etaf-install--manifest-source nil
  "Archive URL or directory from which `etaf-install--manifest-cache' came.")

(defun etaf-install--archive-base ()
  "Return the active ETAF archive base URL or directory with trailing slash."
  (file-name-as-directory
   (if (and (stringp etaf-install-archive-url)
            (not (string-empty-p etaf-install-archive-url))
            (not (equal etaf-install-archive-url "https://etaf.top/packages/")))
       etaf-install-archive-url
     (or (cdr (assoc "etaf" package-archives))
         etaf-install-archive-url))))

(defun etaf-install--read-manifest-from-base (base)
  "Read and parse `manifest.json' from local directory or HTTPS URL BASE."
  (condition-case nil
      (cond
       ((and (file-name-absolute-p base) (file-directory-p base))
        (let ((file (expand-file-name "manifest.json" base)))
          (when (file-readable-p file)
            (with-temp-buffer
              (insert-file-contents file)
              (json-parse-buffer :object-type 'hash-table
                                 :array-type 'list
                                 :null-object nil)))))
       ((string-prefix-p "https://" base)
        (let ((buffer (url-retrieve-synchronously
                       (concat base "manifest.json")
                       t t 3)))
          (prog1 (when buffer
                   (with-current-buffer buffer
                     (goto-char (point-min))
                     (when (search-forward "\n\n" nil t)
                       (json-parse-buffer :object-type 'hash-table
                                          :array-type 'list
                                          :null-object nil))))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))
    (error nil)))

(defun etaf-install--manifest (&optional force)
  "Return the cached archive `manifest.json' hash table, or nil.
Local directory archives are read on demand without network access.
HTTPS archives are only fetched when FORCE is non-nil or during an
interactive call, so enabling the installer or non-interactive checks
never touch the network."
  (let* ((base (etaf-install--archive-base))
         (local-p (and (file-name-absolute-p base) (file-directory-p base))))
    (when (or force (not (equal etaf-install--manifest-source base)))
      (when (or force local-p (called-interactively-p 'any))
        (let ((parsed (etaf-install--read-manifest-from-base base)))
          (when (hash-table-p parsed)
            (setq etaf-install--manifest-cache parsed
                  etaf-install--manifest-source base
                  etaf-install-community-cache (gethash "community" parsed))))))
    (when (equal etaf-install--manifest-source base)
      etaf-install--manifest-cache)))

(defun etaf-install--community ()
  "Return the community records cached from the archive manifest, or nil."
  (or etaf-install-community-cache
      (when-let* ((manifest (etaf-install--manifest)))
        (setq etaf-install-community-cache (gethash "community" manifest)))))

(defun etaf-install--catalog-entry-to-target (name record)
  "Convert manifest catalog NAME and RECORD hash table into a target tuple."
  (let* ((pkg (intern name))
         (label (or (gethash "label" record) name))
         (group-name (or (gethash "group" record) "application"))
         (group (or (intern-soft group-name) 'application))
         (open-name (or (gethash "open" record) ""))
         (open-sym (and (stringp open-name)
                        (not (string-empty-p open-name))
                        (intern open-name)))
         (caps (mapcar #'intern
                       (cl-remove-if-not
                        (lambda (c) (and (stringp c) (not (string-empty-p c))))
                        (gethash "capabilities" record)))))
    (append (list pkg label group open-sym) caps)))

(defun etaf-install--catalog-targets ()
  "Return dynamic first-party targets from `manifest.json' `catalog', or nil."
  (let* ((manifest (etaf-install--manifest))
         (catalog (and (hash-table-p manifest) (gethash "catalog" manifest)))
         (entries nil))
    (when (hash-table-p catalog)
      (maphash (lambda (name record)
                 (when (hash-table-p record)
                   (push (etaf-install--catalog-entry-to-target name record) entries)))
               catalog))
    entries))

(defun etaf-install--archive-targets ()
  "Return community packages this table does not curate.

  They are installed the same way as a curated target, in the group and under
  the label the archive states. The open command and the capability checks
  belong to whoever wrote such a package, so its row carries neither."
  (let ((records (etaf-install--community))
        (dynamic-catalog (etaf-install--catalog-targets))
        extra)
    (when (hash-table-p records)
      (maphash (lambda (name record)
                 (let ((sym (intern name)))
                   (when (and (not (assq sym etaf-install--targets))
                              (not (assq sym dynamic-catalog))
                              (assq sym package-archive-contents))
                     (push (list sym
                                 (or (gethash "label" record) name)
                                 (or (intern-soft (or (gethash "group" record) "application"))
                                     'application)
                                 (intern-soft (or (gethash "open" record) "")))
                           extra))))
               records))
    (nreverse extra)))

(defun etaf-install--available-targets ()
  "Return curated targets merged with manifest catalog and community targets.
Built-in `etaf-install--targets' keeps offline menus working and preserves
curated order; `manifest.json' `catalog' overrides labels/capabilities and
adds newly published first-party packages without upgrading `etaf-install'."
  (let* ((dynamic (etaf-install--catalog-targets))
         (by-name (make-hash-table :test #'eq))
         (result nil))
    (dolist (entry dynamic)
      (puthash (car entry) entry by-name))
    (dolist (curated etaf-install--targets)
      (let* ((sym (car curated))
             (override (gethash sym by-name)))
        (push (or override curated) result)
        (remhash sym by-name)))
    (let (added)
      (maphash (lambda (_sym entry) (push entry added)) by-name)
      (setq result (nreverse result))
      (when added
        (setq result (append result
                             (sort added (lambda (a b)
                                           (string< (symbol-name (car a))
                                                    (symbol-name (car b)))))))))
    (append result
            (and (boundp 'package-archive-contents)
                 (etaf-install--archive-targets)))))

(defun etaf-install--target (package)
  "Return the supported target description for PACKAGE."
  (or (assq package (etaf-install--available-targets))
      (progn
        (etaf-install--manifest t)
        (assq package (etaf-install--available-targets)))
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

(defun etaf-install--target-system-tools (package)
  "Return manual system CLI and managed-engine plist for PACKAGE.
Reads dynamic `manifest.json' `catalog' metadata when available and
falls back to the built-in `etaf-install--system-tools' table offline."
  (let* ((manifest (etaf-install--manifest))
         (catalog (and (hash-table-p manifest) (gethash "catalog" manifest)))
         (record (and (hash-table-p catalog) (gethash (symbol-name package) catalog)))
         (st (and (hash-table-p record) (gethash "system_tools" record))))
    (if (hash-table-p st)
        (let (plist)
          (when-let* ((req (gethash "required" st)))
            (setq plist (plist-put plist :required (mapcar #'intern req))))
          (when-let* ((opt (gethash "optional" st)))
            (setq plist (plist-put plist :optional (mapcar #'intern opt))))
          (when-let* ((engs (gethash "managed_engines" st)))
            (setq plist (plist-put plist :managed-engines
                                   (mapcar (lambda (pair)
                                             (list (car pair) (intern (cadr pair))))
                                           engs))))
          plist)
      (cdr (assq package etaf-install--system-tools)))))

(defun etaf-install--label-to-cli-tool (label)
  "Map a doctor fact LABEL string to a tool key in `etaf-install--cli-catalog'."
  (let ((low (downcase (or label ""))))
    (or (cl-loop for (key . spec) in etaf-install--cli-catalog
                 for name = (downcase (or (plist-get spec :name) ""))
                 for disp = (downcase (or (plist-get spec :label) ""))
                 for bins = (mapcar #'downcase (plist-get spec :binaries))
                 when (or (equal low name)
                          (equal low disp)
                          (member low bins)
                          (and (not (string-empty-p name))
                               (string-prefix-p (concat name " ") low))
                          (and (not (string-empty-p disp))
                               (string-prefix-p disp low)))
                 return key)
        (cond
         ((string-prefix-p "node" low) 'node)
         ((string-prefix-p "python" low) 'python3)
         ((equal low "ffplay") 'ffmpeg)
         ((string-prefix-p "ripgrep" low) 'rg)
         ((string-prefix-p "graphviz" low) 'dot)
         (t nil)))))

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
  (let* ((entry (etaf-install--target-system-tools package))
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
  (let ((engines (plist-get (etaf-install--target-system-tools package)
                            :managed-engines)))
    (cl-find-if
     (lambda (eng)
       (cl-some (lambda (fact) (equal (car fact) (car eng))) missing-facts))
     engines)))


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
  (etaf-install--manifest t)
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


(defun etaf-install--version-string (version)
  "Return VERSION as a dotted string, or nil."
  (and version (package-version-join version)))

(defun etaf-install--live-installed-descs (package)
  "Return live installed descriptors for PACKAGE from `package-alist'."
  (let ((descs (cdr (assq package package-alist))))
    (cl-remove-if
     (lambda (desc)
       (let ((dir (package-desc-dir desc)))
         (and (stringp dir) (not (file-directory-p dir)))))
     descs)))

(defun etaf-install--newest-installed-desc (package)
  "Return the highest-version live installed descriptor for PACKAGE, or nil."
  (when-let* ((descs (etaf-install--live-installed-descs package)))
    (cl-reduce (lambda (a b)
                 (if (version-list-< (package-desc-version a)
                                     (package-desc-version b))
                     b a))
               descs)))

(provide 'etaf-install-catalog)
;;; etaf-install-catalog.el ends here
