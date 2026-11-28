;;; etaf-translate-rules.el --- Declarative site/app rules and glossaries -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Rule and glossary registries governing how `etaf-translate' adapts to
;; different ETAF applications, web domains, buffer patterns and technical
;; domains, with optional persistence to `etaf-translate-state-file'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ext)
(require 'etaf-translate-core)
(require 'etaf-translate-store)

(declare-function etaf-translate--engine-available-p "etaf-translate-engine" (name))

(defcustom etaf-translate-glossary nil
  "Global terminology alist of `(SOURCE . TARGET)' pairs for translation.
For example `((\"ETAF\" . \"ETAF\") (\"Ebox\" . \"Ebox\"))'."
  :type '(alist :key-type string :value-type string)
  :group 'etaf-translate)

(defvar-local etaf-translate-buffer-domain nil
  "Optional buffer-local domain or site override (for example \"etaf.top\").")

(defvar etaf-translate--rules nil
  "Registered rules as an alist of (NAME . PLIST).")

(defvar etaf-translate--site-resolvers nil
  "List of functions `(runtime buffer)' returning a site/domain string or nil.")

(defvar etaf-translate--persisted-site-rules nil
  "Alist of persisted `(SITE . SPEC)' user site preferences.")

(defvar etaf-translate--persisted-prefs nil
  "Sparse plist of panel-persisted user preferences.")

(defvar etaf-translate--prefs-source :uninitialized
  "Value of `etaf-translate-state-file' owning `etaf-translate--persisted-prefs'.")

(defvar etaf-translate--state-loaded-file nil
  "Last `etaf-translate-state-file' path loaded into memory.")

;;;; Site/domain resolution

(defun etaf-translate-register-site-resolver (fn)
  "Register FN `(runtime buffer) -> site-string-or-nil' for domain rules."
  (when (functionp fn)
    (add-to-list 'etaf-translate--site-resolvers fn))
  fn)

(defun etaf-translate--extract-host-from-url (url)
  "Return lowercased hostname from URL string, or nil."
  (when (and (stringp url)
             (string-match "\\`https?://\\(?:[^/@]+@\\)?\\([^/:?#]+\\)" url))
    (downcase (match-string 1 url))))

(defun etaf-translate-current-site (&optional runtime)
  "Return site/domain or application ID for RUNTIME's buffer, or nil.
Checks `etaf-translate-buffer-domain', registered site resolvers (such as
`etaf-web' URLs), `*Web: <host>*' buffer names, and known ETAF app buffers."
  (let* ((rt (or runtime (etaf-current-runtime) (etaf-runtime-for-buffer (current-buffer))))
         (buf (if rt (etaf-runtime-buffer rt) (current-buffer))))
    (when (buffer-live-p buf)
      (or (when-let* ((dom (buffer-local-value 'etaf-translate-buffer-domain buf)))
            (and (stringp dom) (not (string-empty-p dom)) (downcase dom)))
          (cl-loop for fn in etaf-translate--site-resolvers
                   for res = (ignore-errors (funcall fn rt buf))
                   when (and (stringp res) (not (string-empty-p res)))
                   return (downcase res))
          (when (and rt (etaf-runtime-mounted-p rt))
            (let* ((meta (etaf-runtime-meta rt))
                   (uri (plist-get meta :uri))
                   (app (plist-get meta :app)))
              (or (etaf-translate--extract-host-from-url uri)
                  (and (symbolp app) app (downcase (symbol-name app))))))
          (let ((name (buffer-name buf)))
            (cond
             ((string-match "\\`\\*Web:[ \t]+\\([^*\n ]+\\)" name)
              (downcase (match-string 1 name)))
             ((string-prefix-p "*ETAF Markdown" name) "etaf-md")
             ((string-prefix-p "*ETAF Org" name) "etaf-org")
             ((string-prefix-p "*ETAF Manual" name) "etaf-manual")
             ((string-prefix-p "*ETAF RSS" name) "etaf-rss")
             ((string-prefix-p "*ETAF Reader" name) "etaf-reader")
             ((string-prefix-p "*ETAF Telega" name) "etaf-telega")
             ((string-match-p "\\`\\*[Mm]aillist" name) "maillist")
             (t nil)))))))

(defun etaf-translate--domain-matches-p (pattern site)
  "Return non-nil when SITE matches domain PATTERN (exact or wildcard)."
  (when (and (stringp pattern) (stringp site))
    (let* ((pat (downcase (string-trim pattern)))
           (host (downcase (string-trim site)))
           (bare (if (string-prefix-p "*." pat) (substring pat 2) pat)))
      (or (string= host bare)
          (string-suffix-p (concat "." bare) host)))))

;;;; Persistent user state (panel preferences + site rules + glossary)

(defconst etaf-translate--pref-keys
  '(:mode :style :source-lang :target-lang :engine)
  "Allowed sparse preference keys persisted from the control panel.")

(defun etaf-translate--valid-pref-p (key val)
  "Return non-nil when VAL is a valid persisted preference for KEY."
  (pcase key
    (:mode (memq val etaf-translate--valid-modes))
    (:style (memq val etaf-translate--valid-styles))
    (:source-lang (or (eq val 'auto)
                      (and (stringp val) (not (string-empty-p val)))))
    (:target-lang (and (stringp val) (not (string-empty-p val))))
    (:engine (and (symbolp val) val))
    (_ nil)))

(defun etaf-translate--sanitize-prefs (raw)
  "Return a clean sparse plist keeping only valid entries from RAW."
  (let ((out nil))
    (when (proper-list-p raw)
      (cl-loop for (k v) on raw by #'cddr
               when (and (memq k etaf-translate--pref-keys)
                         (etaf-translate--valid-pref-p k v))
               do (setq out (plist-put out k v))))
    out))

(defun etaf-translate--site-rule-name (site)
  "Return the stable rule symbol for remembered SITE."
  (intern (format "etaf-translate-site:%s" (downcase site))))

(defun etaf-translate--ensure-state-loaded ()
  "Load persisted preferences, site rules and glossary from state file."
  (when (and (stringp etaf-translate-state-file)
             (not (equal etaf-translate--state-loaded-file etaf-translate-state-file)))
    (setq etaf-translate--state-loaded-file etaf-translate-state-file
          etaf-translate--prefs-source etaf-translate-state-file
          etaf-translate--persisted-prefs nil
          etaf-translate--persisted-site-rules nil)
    (when-let* ((data (etaf-translate-store-load-state etaf-translate-state-file)))
      (setq etaf-translate--persisted-prefs
            (etaf-translate--sanitize-prefs (plist-get data :prefs)))
      (dolist (pair (plist-get data :glossary))
        (when (and (consp pair) (stringp (car pair)) (stringp (cdr pair)))
          (unless (assoc (car pair) etaf-translate-glossary)
            (push (cons (car pair) (cdr pair)) etaf-translate-glossary))))
      (dolist (entry (plist-get data :site-rules))
        (when (and (consp entry) (stringp (car entry)) (proper-list-p (cdr entry)))
          (push (cons (car entry) (copy-sequence (cdr entry)))
                etaf-translate--persisted-site-rules)
          (ignore-errors
            (apply #'etaf-translate-register-rule
                   (etaf-translate--site-rule-name (car entry))
                   (cdr entry))))))))

(defun etaf-translate--active-prefs ()
  "Return active sparse preferences plist for `etaf-translate-state-file'."
  (etaf-translate--ensure-state-loaded)
  (when (equal etaf-translate--prefs-source etaf-translate-state-file)
    etaf-translate--persisted-prefs))

(defun etaf-translate--persist-state ()
  "Write panel prefs, site rules and glossary to `etaf-translate-state-file'."
  (when (stringp etaf-translate-state-file)
    (etaf-translate-store-save-state
     (list :prefs (etaf-translate--active-prefs)
           :site-rules etaf-translate--persisted-site-rules
           :glossary etaf-translate-glossary)
     etaf-translate-state-file)))

(defun etaf-translate--set-pref (key value)
  "Update sparse preference KEY to VALUE and persist to state file."
  (when (and (memq key etaf-translate--pref-keys)
             (etaf-translate--valid-pref-p key value))
    (etaf-translate--ensure-state-loaded)
    (unless (equal etaf-translate--prefs-source etaf-translate-state-file)
      (setq etaf-translate--persisted-prefs nil
            etaf-translate--prefs-source etaf-translate-state-file))
    (setq etaf-translate--persisted-prefs
          (plist-put (copy-sequence etaf-translate--persisted-prefs) key value))
    (etaf-translate--persist-state)
    value))

;;;; Rule registry

(defun etaf-translate-register-rule (name &rest spec)
  "Register or replace declarative translation rule NAME with plist SPEC.
Supported keys:
  :priority        Integer order (smaller wins; default 50).
  :domain          Host/site string (e.g. \"etaf.top\", \"*.arxiv.org\") or list.
  :buffer-regexp   Regexp matched against the Runtime buffer name.
  :major-mode      Major mode symbol or list of symbols.
  :predicate       Function `(runtime buffer)' returning non-nil.
  :mode            `bilingual-stacked' or `replace'.
  :style           `left-bar', `muted' or `tinted'.
  :scope           `content' or `full'.
  :source-lang     Source language override.
  :target-lang     Target language override.
  :engine          Engine or profile symbol override.
  :fallback-engine Fallback engine or profile symbol override.
  :prompt-style    Prompt style override (`technical', `academic', ...).
  :auto-translate  Auto-enable when a matching Runtime mounts or navigates.
  :never-translate Block auto-translation on matching buffers.
  :exclude-roles   Extra Host `:role' symbols to skip.
  :exclude-classes Extra Host `:class' names to skip.
  :glossary        Extra `(SOURCE . TARGET)' alist merged over global glossary."
  (unless (and (symbolp name) name)
    (signal 'etaf-translate-error (list "Rule name must be a non-nil symbol" name)))
  (unless (proper-list-p spec)
    (signal 'etaf-translate-error (list "Rule spec must be a plist" spec)))
  (when-let* ((mode (plist-get spec :mode)))
    (etaf-translate--check-mode mode))
  (when-let* ((style (plist-get spec :style)))
    (etaf-translate--check-style style))
  (when-let* ((scope (plist-get spec :scope)))
    (etaf-translate--check-scope scope))
  (let* ((priority (or (plist-get spec :priority) 50))
         (normalized (plist-put (copy-sequence spec) :priority priority)))
    (unless (integerp priority)
      (signal 'etaf-translate-error (list "Rule :priority must be an integer" priority)))
    (setq etaf-translate--rules
          (cons (cons name normalized)
                (assq-delete-all name etaf-translate--rules)))
    (when (plist-get normalized :auto-translate)
      (etaf-ext-sync))
    name))

(defun etaf-translate-unregister-rule (name)
  "Remove rule NAME and return non-nil if it was registered."
  (let ((found (assq name etaf-translate--rules)))
    (when found
      (setq etaf-translate--rules (assq-delete-all name etaf-translate--rules))
      t)))

(defun etaf-translate-rules ()
  "Return a detached list of registered rules sorted by `:priority'."
  (etaf-translate--ensure-state-loaded)
  (mapcar (lambda (entry)
            (cons (car entry) (copy-sequence (cdr entry))))
          (sort (copy-sequence etaf-translate--rules)
                (lambda (a b)
                  (< (or (plist-get (cdr a) :priority) 50)
                     (or (plist-get (cdr b) :priority) 50))))))

(defun etaf-translate--rule-matches-p (spec runtime buffer site)
  "Return non-nil when rule SPEC matches RUNTIME, BUFFER and SITE."
  (let ((dom (plist-get spec :domain))
        (buf-re (plist-get spec :buffer-regexp))
        (modes (plist-get spec :major-mode))
        (pred (plist-get spec :predicate))
        (buf-name (and (buffer-live-p buffer) (buffer-name buffer)))
        (buf-mode (and (buffer-live-p buffer)
                       (buffer-local-value 'major-mode buffer))))
    (and (or (null dom)
             (and site
                  (if (listp dom)
                      (cl-some (lambda (d) (etaf-translate--domain-matches-p d site)) dom)
                    (etaf-translate--domain-matches-p dom site))))
         (or (null buf-re) (and buf-name (string-match-p buf-re buf-name)))
         (or (null modes)
             (if (listp modes) (memq buf-mode modes) (eq buf-mode modes)))
         (or (null pred)
             (ignore-errors (funcall pred runtime buffer))))))

(defun etaf-translate-resolve-policy (runtime &optional overrides)
  "Return effective translation policy plist for RUNTIME merged with OVERRIDES.
Resolution order (highest wins): OVERRIDES > matching rules > persisted panel
preferences > global defaults.  Multiple matching rules merge in priority order."
  (etaf-translate--ensure-state-loaded)
  (let* ((buffer (and runtime (etaf-runtime-buffer runtime)))
         (site (and runtime (etaf-translate-current-site runtime)))
         (prefs (etaf-translate--active-prefs))
         (matched-list nil))
    (when runtime
      (dolist (entry (etaf-translate-rules))
        (when (etaf-translate--rule-matches-p (cdr entry) runtime buffer site)
          (push (cdr entry) matched-list)))
      (setq matched-list (nreverse matched-list)))
    (let* ((pick (lambda (key default)
                   (cond
                    ((plist-member overrides key) (plist-get overrides key))
                    ((cl-some (lambda (r) (plist-member r key)) matched-list)
                     (cl-loop for r in matched-list
                              when (plist-member r key)
                              return (plist-get r key)))
                    ((and (plist-member prefs key)
                          (or (not (eq key :engine))
                              (not (fboundp 'etaf-translate--engine-available-p))
                              (etaf-translate--engine-available-p
                               (plist-get prefs key))))
                     (plist-get prefs key))
                    (t default))))
           (never-p (cl-some (lambda (r) (plist-get r :never-translate)) matched-list))
           (auto-p (and (not never-p) (funcall pick :auto-translate nil)))
           (exclude-roles
            (cl-delete-duplicates
             (append (plist-get overrides :exclude-roles)
                     (cl-mapcan (lambda (r) (copy-sequence (plist-get r :exclude-roles)))
                                matched-list))))
           (exclude-classes
            (cl-delete-duplicates
             (append (plist-get overrides :exclude-classes)
                     (cl-mapcan (lambda (r) (copy-sequence (plist-get r :exclude-classes)))
                                matched-list))
             :test #'equal))
           (glossary
            (append (plist-get overrides :glossary)
                    (cl-mapcan (lambda (r) (copy-sequence (plist-get r :glossary)))
                               matched-list)
                    etaf-translate-glossary)))
      (list :site site
            :mode (etaf-translate--check-mode
                   (funcall pick :mode etaf-translate-default-mode))
            :style (etaf-translate--check-style
                    (funcall pick :style etaf-translate-default-style))
            :scope (etaf-translate--check-scope
                    (funcall pick :scope etaf-translate-default-scope))
            :source-lang (funcall pick :source-lang etaf-translate-source-lang)
            :target-lang (funcall pick :target-lang etaf-translate-target-lang)
            :engine (funcall pick :engine etaf-translate-default-engine)
            :fallback-engine (funcall pick :fallback-engine etaf-translate-fallback-engine)
            :prompt-style (funcall pick :prompt-style etaf-translate-prompt-style)
            :auto-translate auto-p
            :never-translate never-p
            :exclude-roles exclude-roles
            :exclude-classes exclude-classes
            :glossary glossary))))

(defun etaf-translate--has-auto-translate-rule-p ()
  "Return non-nil when any registered rule requests `:auto-translate'."
  (etaf-translate--ensure-state-loaded)
  (cl-some (lambda (entry) (plist-get (cdr entry) :auto-translate))
           etaf-translate--rules))

;;;; User-facing site rule and glossary management

(defun etaf-translate-remember-site (site action &optional overrides)
  "Persist preference ACTION (`auto', `never' or `custom') for SITE.
Optional plist OVERRIDES may specify `:mode', `:style', `:target-lang' or
`:engine'.  Registers a priority-5 rule and saves `etaf-translate-state-file'."
  (unless (and (stringp site) (not (string-empty-p (string-trim site))))
    (signal 'etaf-translate-error (list "Site must be a non-empty string" site)))
  (unless (memq action '(auto never custom))
    (signal 'etaf-translate-error (list "Site action must be auto, never or custom" action)))
  (etaf-translate--ensure-state-loaded)
  (let* ((norm (downcase (string-trim site)))
         (spec (append
                (list :priority 5 :domain norm)
                (pcase action
                  ('auto (list :auto-translate t :never-translate nil))
                  ('never (list :auto-translate nil :never-translate t))
                  ('custom nil))
                overrides))
         (rname (etaf-translate--site-rule-name norm)))
    (apply #'etaf-translate-register-rule rname spec)
    (setq etaf-translate--persisted-site-rules
          (cons (cons norm spec)
                (assoc-delete-all norm etaf-translate--persisted-site-rules)))
    (etaf-translate--persist-state)
    rname))

(defun etaf-translate-forget-site (site)
  "Remove persisted rule for SITE and update `etaf-translate-state-file'."
  (etaf-translate--ensure-state-loaded)
  (let* ((norm (downcase (string-trim (or site ""))))
         (rname (etaf-translate--site-rule-name norm))
         (removed (etaf-translate-unregister-rule rname)))
    (setq etaf-translate--persisted-site-rules
          (assoc-delete-all norm etaf-translate--persisted-site-rules))
    (etaf-translate--persist-state)
    removed))

(defun etaf-translate-add-glossary-term (source target &optional persist)
  "Add or update glossary entry (SOURCE . TARGET) in `etaf-translate-glossary'.
When PERSIST is non-nil, save to `etaf-translate-state-file'."
  (unless (and (stringp source) (not (string-empty-p (string-trim source)))
               (stringp target) (not (string-empty-p (string-trim target))))
    (signal 'etaf-translate-error
            (list "Glossary source and target must be non-empty strings" source target)))
  (etaf-translate--ensure-state-loaded)
  (let ((s (string-trim source))
        (tgt (string-trim target)))
    (setq etaf-translate-glossary
          (cons (cons s tgt)
                (assoc-delete-all s etaf-translate-glossary)))
    (when persist
      (etaf-translate--persist-state))
    (cons s tgt)))

(defun etaf-translate-remove-glossary-term (source &optional persist)
  "Remove SOURCE from `etaf-translate-glossary' and optionally PERSIST."
  (etaf-translate--ensure-state-loaded)
  (let ((had (assoc source etaf-translate-glossary)))
    (when had
      (setq etaf-translate-glossary
            (assoc-delete-all source etaf-translate-glossary))
      (when persist
        (etaf-translate--persist-state))
      t)))

(defun etaf-translate-glossary-hash (glossary)
  "Return a stable short hash for GLOSSARY alist, or \"\" when empty."
  (if (null glossary)
      ""
    (substring
     (etaf-translate-text-hash
      (mapconcat (lambda (pair)
                   (format "%s=%s" (car pair) (cdr pair)))
                 glossary "\n"))
     0 12)))

(provide 'etaf-translate-rules)
;;; etaf-translate-rules.el ends here
