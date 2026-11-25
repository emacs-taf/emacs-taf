;;; etaf-ext-core.el --- Extension manifest, registry and matching for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Core types, error conditions, permission vocabulary, declarative manifest
;; registration (`etaf-ext-register', `etaf-ext-define') and Runtime matching
;; for `etaf-ext'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)

;;;; Error conditions

(define-error 'etaf-ext-error "ETAF extension error")
(define-error 'etaf-ext-permission-error "ETAF extension permission denied"
              'etaf-ext-error)

;;;; Permissions & customization

(defconst etaf-ext-known-permissions
  '(read-tree decorate companion override overlay interact inspect
              storage keys popup notify)
  "Supported permission capabilities an ETAF extension may request.")

(defgroup etaf-ext nil
  "Universal extension engine for mounted ETAF Views."
  :group 'applications
  :prefix "etaf-ext-")

(defcustom etaf-ext-storage-file
  (expand-file-name "etaf-ext/storage.sqlite3" user-emacs-directory)
  "SQLite file storing extension preferences, policies and per-extension KV data.
When nil or when native SQLite is unavailable, falls back to in-memory storage."
  :type '(choice (const :tag "In-memory only" nil) file)
  :group 'etaf-ext)

(defcustom etaf-ext-circuit-breaker-threshold 3
  "Consecutive callback errors before an extension is automatically suspended."
  :type 'integer
  :group 'etaf-ext)

(defcustom etaf-ext-max-error-log 24
  "Maximum recent error entries retained per extension."
  :type 'integer
  :group 'etaf-ext)

(defcustom etaf-ext-use-posframe t
  "When non-nil, show extension popups via `etaf-posframe' when available."
  :type 'boolean
  :group 'etaf-ext)

(defcustom etaf-ext-key-prefix "C-c C-e"
  "Unified prefix key inside ETAF Runtimes opening the extension dispatcher.
Follows Emacs's `C-c C-<letter>' mode/framework namespace instead of claiming
user-reserved `C-c <letter>' keys.  Set to nil to disable automatic prefix
binding (commands remain reachable via `etaf-ext-command-palette',
`etaf-ext-dispatch' and `etaf-ext-manage')."
  :type '(choice (const :tag "Disabled" nil) string)
  :set (lambda (sym val)
         (set-default sym val)
         (when (and (bound-and-true-p etaf-ext-mode)
                    (fboundp 'etaf-ext-sync))
           (ignore-errors (etaf-ext-sync))))
  :group 'etaf-ext)

(defcustom etaf-ext-keybinding-policy 'safe
  "Policy governing direct key bindings installed on mounted ETAF Runtimes.
- `safe': install `:suggested-key' bindings only when free of conflicts with
  framework keys, the active application, `global-map', active minor modes and
  higher-priority extensions; install `etaf-ext-key-prefix' when conflict-free.
- `prefix-only': skip all `:suggested-key' direct bindings; keep only
  `etaf-ext-key-prefix' and explicit user overrides (`etaf-ext-set-key').
- `manual': install neither `:suggested-key' nor `etaf-ext-key-prefix'; bind
  only explicit user overrides (`etaf-ext-set-key')."
  :type '(choice (const :tag "Safe (conflict-checked)" safe)
                 (const :tag "Prefix & overrides only" prefix-only)
                 (const :tag "Manual overrides only" manual))
  :set (lambda (sym val)
         (set-default sym val)
         (when (and (bound-and-true-p etaf-ext-mode)
                    (fboundp 'etaf-ext-sync))
           (ignore-errors (etaf-ext-sync))))
  :group 'etaf-ext)

;;;; Extension specification struct & registry

(cl-defstruct (etaf-ext--spec (:constructor etaf-ext--spec-make) (:copier nil))
  "Registered manifest and callbacks of one ETAF extension."
  id name version description icon tone prefix-hint
  matches activation permissions
  (priority 50) (debounce 0.08)
  commands popup badge
  on-attach on-commit on-scroll on-meta on-focus on-theme on-detach)

(defvar etaf-ext--registry (make-hash-table :test #'eq)
  "Hash table mapping extension ID symbol to `etaf-ext--spec'.")

(defvar etaf-ext--order nil
  "Registered extension IDs in ascending priority and registration order.")

(defvar etaf-ext-change-functions nil
  "Hook run with `(EVENT EXT-ID)' when extension registry or state changes.")

(defun etaf-ext--emit-change (event &optional ext-id)
  "Notify `etaf-ext-change-functions' with EVENT and EXT-ID safely."
  (dolist (fn (copy-sequence etaf-ext-change-functions))
    (when (functionp fn)
      (condition-case nil
          (funcall fn event ext-id)
        (error nil)))))

(defun etaf-ext--validate-permissions (perms)
  "Validate PERMS list against `etaf-ext-known-permissions'."
  (unless (proper-list-p perms)
    (signal 'etaf-ext-error (list "Extension :permissions must be a list" perms)))
  (dolist (p perms)
    (unless (memq p etaf-ext-known-permissions)
      (signal 'etaf-ext-error (list "Unknown extension permission" p))))
  (delete-dups (copy-sequence perms)))

(defun etaf-ext--normalize-single-key (raw label)
  "Validate RAW as a single-event `kbd' string for LABEL and normalize it."
  (when raw
    (unless (and (stringp raw) (not (string-empty-p raw)))
      (signal 'etaf-ext-error (list (format "Invalid %s" label) raw)))
    (let ((ev (condition-case nil
                  (vconcat (kbd raw))
                (error nil))))
      (unless (and (vectorp ev) (= (length ev) 1))
        (signal 'etaf-ext-error
                (list (format "%s must be a single key event" label) raw)))
      (key-description ev))))

(defun etaf-ext--normalize-key-seq (raw label)
  "Validate RAW as a non-empty `kbd' string or key vector for LABEL."
  (when raw
    (unless (or (and (stringp raw) (not (string-empty-p raw)))
                (and (vectorp raw) (> (length raw) 0)))
      (signal 'etaf-ext-error (list (format "Invalid %s" label) raw)))
    (let ((ev (condition-case nil
                  (vconcat (if (stringp raw) (kbd raw) raw))
                (error nil))))
      (unless (and (vectorp ev) (> (length ev) 0))
        (signal 'etaf-ext-error (list (format "Invalid %s" label) raw)))
      (key-description ev))))

(defun etaf-ext--validate-commands (commands)
  "Validate COMMANDS entries `(CMD-ID :label STR :fn FN ...)'."
  (unless (proper-list-p commands)
    (signal 'etaf-ext-error (list "Extension :commands must be a list" commands)))
  (let ((out nil)
        (allowed '(:subkey :suggested-key :label :fn)))
    (dolist (cmd commands (nreverse out))
      (unless (and (consp cmd) (symbolp (car cmd)) (car cmd)
                   (proper-list-p (cdr cmd))
                   (zerop (% (length (cdr cmd)) 2)))
        (signal 'etaf-ext-error (list "Invalid extension command entry" cmd)))
      (let* ((cid (car cmd))
             (plist (cdr cmd)))
        (cl-loop for (k _v) on plist by #'cddr
                 unless (memq k allowed)
                 do (signal 'etaf-ext-error
                            (list "Unknown extension command key; use :subkey or :suggested-key"
                                  cid k)))
        (let* ((subkey (etaf-ext--normalize-single-key
                        (plist-get plist :subkey)
                        (format "command %s :subkey" cid)))
               (suggested (etaf-ext--normalize-key-seq
                           (plist-get plist :suggested-key)
                           (format "command %s :suggested-key" cid)))
               (label (plist-get plist :label))
               (fn (plist-get plist :fn)))
          (when (and label (not (stringp label)))
            (signal 'etaf-ext-error (list "Invalid command :label" cid label)))
          (unless (or (functionp fn) (commandp fn))
            (signal 'etaf-ext-error (list "Extension command requires callable :fn" cid)))
          (push (cons cid (list :subkey subkey
                                :suggested-key suggested
                                :label (or label (symbol-name cid))
                                :fn fn))
                out))))))

(defun etaf-ext--validate-matches (matches)
  "Validate MATCHES plist describing which Runtimes an extension attaches to."
  (unless (or (null matches)
              (and (proper-list-p matches) (zerop (% (length matches) 2))))
    (signal 'etaf-ext-error (list "Extension :matches must be a plist or nil" matches)))
  (cl-loop for (k v) on matches by #'cddr
           do (pcase k
                (:apps
                 (unless (or (eq v t) (null v)
                             (and (proper-list-p v) (cl-every #'symbolp v)))
                   (signal 'etaf-ext-error (list "Invalid :matches :apps" v))))
                (:kinds
                 (unless (or (null v)
                             (and (proper-list-p v) (cl-every #'symbolp v)))
                   (signal 'etaf-ext-error (list "Invalid :matches :kinds" v))))
                (:uri-regexp
                 (unless (or (null v) (stringp v))
                   (signal 'etaf-ext-error (list "Invalid :matches :uri-regexp" v))))
                (:buffer-regexp
                 (unless (or (null v) (stringp v))
                   (signal 'etaf-ext-error (list "Invalid :matches :buffer-regexp" v))))
                (:predicate
                 (unless (or (null v) (functionp v))
                   (signal 'etaf-ext-error (list "Invalid :matches :predicate" v))))
                (_
                 (signal 'etaf-ext-error (list "Unknown :matches key" k)))))
  (copy-sequence (or matches '(:apps t))))

(defun etaf-ext--rebuild-order ()
  "Rebuild `etaf-ext--order' sorted by ascending priority then symbol name."
  (let (ids)
    (maphash (lambda (k _v) (push k ids)) etaf-ext--registry)
    (setq etaf-ext--order
          (sort ids
                (lambda (a b)
                  (let* ((sa (gethash a etaf-ext--registry))
                         (sb (gethash b etaf-ext--registry))
                         (pa (etaf-ext--spec-priority sa))
                         (pb (etaf-ext--spec-priority sb)))
                    (if (/= pa pb)
                        (< pa pb)
                      (string< (symbol-name a) (symbol-name b)))))))))

(defun etaf-ext-register (id &rest spec)
  "Register or update ETAF extension ID from keyword plist SPEC.
Supported keys:
  :name         Human-readable string (defaults to ID name).
  :version      Version string (default \"0.1.0\").
  :description  Short summary string (default \"\").
  :icon         Optional short glyph string for the extension manager monogram.
  :tone         Optional semantic tone symbol (`accent', `info', `success',
                `warning', `danger' or `neutral') for the manager monogram.
  :prefix-hint  Optional single-event `kbd' string (such as \"x\") suggested
                under `etaf-ext-key-prefix' (`etaf-ext-dispatch').
  :matches      Plist (`:apps', `:kinds', `:uri-regexp', `:buffer-regexp',
                `:predicate'); defaults to `(:apps t)'.
  :activation   `on-match' (default), `on-command', or predicate `(RUNTIME)'.
  :permissions  List of symbols from `etaf-ext-known-permissions'.
  :priority     Integer ordering priority (default 50, lower runs first).
  :debounce     Non-negative number of seconds to coalesce commit/scroll hooks.
  :commands     List of `(CMD-ID :label LABEL :fn FN ...)' with optional
                `:subkey' and `:suggested-key'.
  :popup        Optional function `(ctx)' returning a popup View.
  :badge        Optional function `(ctx)' returning `(:text STR :variant SYM)'.
  :on-attach, :on-commit, :on-scroll, :on-meta, :on-focus, :on-theme,
  :on-detach    Optional lifecycle callbacks receiving `(ctx ...)'."
  (unless (and (symbolp id) id)
    (signal 'etaf-ext-error (list "Extension ID must be a non-nil symbol" id)))
  (unless (and (proper-list-p spec) (zerop (% (length spec) 2)))
    (signal 'etaf-ext-error (list "Extension spec must be a keyword plist" id)))
  (let ((allowed '(:name :version :description :icon :tone :prefix-hint
                         :matches :activation
                         :permissions :priority :debounce :commands :popup :badge
                         :on-attach :on-commit :on-scroll :on-meta
                         :on-focus :on-theme :on-detach)))
    (cl-loop for (k _v) on spec by #'cddr
             unless (memq k allowed)
             do (signal 'etaf-ext-error (list "Unknown extension spec key" k))))
  (let* ((name (or (plist-get spec :name) (symbol-name id)))
         (version (or (plist-get spec :version) "0.1.0"))
         (description (or (plist-get spec :description) ""))
         (icon (plist-get spec :icon))
         (tone (plist-get spec :tone))
         (prefix-hint (etaf-ext--normalize-single-key
                       (plist-get spec :prefix-hint)
                       "extension :prefix-hint"))
         (activation (or (plist-get spec :activation) 'on-match))
         (priority (if (plist-member spec :priority) (plist-get spec :priority) 50))
         (debounce (if (plist-member spec :debounce) (plist-get spec :debounce) 0.08))
         (matches (etaf-ext--validate-matches (plist-get spec :matches)))
         (perms (etaf-ext--validate-permissions (plist-get spec :permissions)))
         (commands (etaf-ext--validate-commands (plist-get spec :commands))))
    (unless (stringp name)
      (signal 'etaf-ext-error (list "Extension :name must be a string" name)))
    (unless (stringp version)
      (signal 'etaf-ext-error (list "Extension :version must be a string" version)))
    (unless (stringp description)
      (signal 'etaf-ext-error (list "Extension :description must be a string" description)))
    (when (and icon (not (stringp icon)))
      (signal 'etaf-ext-error (list "Extension :icon must be a string or nil" icon)))
    (when (and tone (not (memq tone '(accent info success warning danger neutral))))
      (signal 'etaf-ext-error
              (list "Extension :tone must be accent, info, success, warning, danger or neutral"
                    tone)))
    (unless (or (memq activation '(on-match on-command))
                (functionp activation))
      (signal 'etaf-ext-error
              (list "Extension :activation must be on-match, on-command or a function"
                    activation)))
    (unless (integerp priority)
      (signal 'etaf-ext-error (list "Extension :priority must be an integer" priority)))
    (unless (and (numberp debounce) (>= debounce 0))
      (signal 'etaf-ext-error (list "Extension :debounce must be a nonnegative number" debounce)))
    (dolist (cb-key '(:popup :badge :on-attach :on-commit :on-scroll
                             :on-meta :on-focus :on-theme :on-detach))
      (let ((fn (plist-get spec cb-key)))
        (when (and fn (not (functionp fn)))
          (signal 'etaf-ext-error (list "Extension callback must be a function or nil" cb-key fn)))))
    (let ((rec (etaf-ext--spec-make
                :id id :name name :version version :description description
                :icon icon :tone tone :prefix-hint prefix-hint
                :matches matches :activation activation :permissions perms
                :priority priority :debounce debounce :commands commands
                :popup (plist-get spec :popup)
                :badge (plist-get spec :badge)
                :on-attach (plist-get spec :on-attach)
                :on-commit (plist-get spec :on-commit)
                :on-scroll (plist-get spec :on-scroll)
                :on-meta (plist-get spec :on-meta)
                :on-focus (plist-get spec :on-focus)
                :on-theme (plist-get spec :on-theme)
                :on-detach (plist-get spec :on-detach))))
      (puthash id rec etaf-ext--registry)
      (etaf-ext--rebuild-order)
      (etaf-ext--emit-change 'registered id)
      id)))

(defmacro etaf-ext-define (id &rest spec)
  "Declaratively register ETAF extension ID with keyword SPEC."
  (declare (indent 1))
  `(etaf-ext-register ',id ,@spec))

(defun etaf-ext--get-spec (id)
  "Return `etaf-ext--spec' for ID, or signal `etaf-ext-error'."
  (or (gethash id etaf-ext--registry)
      (signal 'etaf-ext-error (list "Unknown ETAF extension" id))))

(defun etaf-ext-list ()
  "Return list of registered ETAF extension IDs in priority order."
  (copy-sequence etaf-ext--order))

(defun etaf-ext-info (id)
  "Return a detached read-only manifest plist for extension ID, or nil."
  (when-let* ((spec (gethash id etaf-ext--registry)))
    (list :id (etaf-ext--spec-id spec)
          :name (etaf-ext--spec-name spec)
          :version (etaf-ext--spec-version spec)
          :description (etaf-ext--spec-description spec)
          :icon (etaf-ext--spec-icon spec)
          :tone (etaf-ext--spec-tone spec)
          :prefix-hint (etaf-ext--spec-prefix-hint spec)
          :matches (copy-tree (etaf-ext--spec-matches spec))
          :activation (let ((act (etaf-ext--spec-activation spec)))
                        (if (functionp act) 'on-condition act))
          :permissions (copy-sequence (etaf-ext--spec-permissions spec))
          :priority (etaf-ext--spec-priority spec)
          :debounce (etaf-ext--spec-debounce spec)
          :commands (copy-tree (etaf-ext--spec-commands spec))
          :has-popup (and (etaf-ext--spec-popup spec) t)
          :has-badge (and (etaf-ext--spec-badge spec) t))))

;;;; Matching engine

(defun etaf-ext--spec-matches-runtime-p (spec runtime)
  "Return non-nil when extension SPEC matches mounted RUNTIME."
  (when (and spec runtime (etaf-runtime-mounted-p runtime))
    (let* ((matches (etaf-ext--spec-matches spec))
           (meta (etaf-runtime-meta runtime))
           (buf (etaf-runtime-buffer runtime))
           (bname (and (buffer-live-p buf) (buffer-name buf)))
           (app (plist-get meta :app))
           (kind (plist-get meta :kind))
           (uri (plist-get meta :uri))
           (apps (plist-get matches :apps))
           (kinds (plist-get matches :kinds))
           (uri-re (plist-get matches :uri-regexp))
           (buf-re (plist-get matches :buffer-regexp))
           (pred (plist-get matches :predicate)))
      (and (or (null apps)
               (eq apps t)
               (and app (memq app apps)))
           (or (null kinds)
               (and kind (memq kind kinds)))
           (or (null uri-re)
               (and (stringp uri) (string-match-p uri-re uri)))
           (or (null buf-re)
               (and (stringp bname) (string-match-p buf-re bname)))
           (or (null pred)
               (condition-case nil
                   (funcall pred runtime meta buf)
                 (error nil)))
           t))))

(defun etaf-ext-match-p (id runtime)
  "Return non-nil when registered extension ID matches mounted RUNTIME."
  (etaf-ext--spec-matches-runtime-p (etaf-ext--get-spec id) runtime))

(provide 'etaf-ext-core)
;;; etaf-ext-core.el ends here
