;;; etaf-ext-keys.el --- Conflict-free key resolution, dispatcher and palette for etaf-ext -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Central command-first keybinding resolver, conflict firewall, persisted user
;; override API, unified two-step prefix dispatcher (`etaf-ext-dispatch') and
;; fuzzy command palette (`etaf-ext-command-palette') for `etaf-ext'.
;;
;; Precedence (highest to lowest):
;;   1. ETAF framework reserved keys (`ESC', `Tab', `?', `M-g', `C-g', arrows)
;;   2. Active Runtime application keys (Host `:keys' and buffer local maps)
;;   3. Explicit user overrides persisted in `etaf-ext-store' (`etaf-ext-set-key')
;;   4. Active minor modes and `global-map' (including prefix collisions)
;;   5. Unified framework extension prefix (`etaf-ext-key-prefix', default `C-c C-e')
;;   6. Higher-priority extension bindings
;;   7. Extension `:suggested-key' hints (only under `safe' policy)

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext-core)
(require 'etaf-ext-store)
(require 'etaf-ext-runtime)

(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))
(declare-function etaf-ext-manage-popup "etaf-ext-ui" (&optional target-runtime))

(defconst etaf-ext--dispatch-layer-key 'etaf-ext--dispatch
  "Key-layer owner symbol used for `etaf-ext-key-prefix' on mounted Runtimes.")

(defconst etaf-ext--dispatch-reserved-keys '("q" "/" "M" "P" "?")
  "Single-character keys reserved for top-level actions in `etaf-ext-dispatch'.")

(defvar etaf-ext--dispatch-panel nil
  "Active `etaf-posframe' panel handle for `etaf-ext-dispatch', or nil.")

(defvar etaf-ext--dispatch-gen 0
  "Monotonic counter preventing stale transient exits from hiding newer menus.")

;;;; Key normalization & low-level predicates

(defun etaf-ext--keys-to-event (key)
  "Convert KEY (`kbd' string or key vector) to a non-empty event vector."
  (let ((ev (condition-case nil
                (cond
                 ((and (stringp key) (not (string-empty-p key)))
                  (vconcat (kbd key)))
                 ((and (vectorp key) (> (length key) 0))
                  (vconcat key))
                 (t nil))
              (error nil))))
    (unless (and (vectorp ev) (> (length ev) 0))
      (signal 'etaf-ext-error (list "Invalid key sequence" key)))
    ev))

(defun etaf-ext--keys-prefix-p (prefix seq)
  "Return non-nil when key vector PREFIX is a proper prefix of SEQ."
  (and (< (length prefix) (length seq))
       (equal prefix (substring seq 0 (length prefix)))))

(defun etaf-ext--keys-overlap-p (ev1 ev2)
  "Return non-nil when key vectors EV1 and EV2 are equal or prefix-conflict."
  (or (equal ev1 ev2)
      (etaf-ext--keys-prefix-p ev1 ev2)
      (etaf-ext--keys-prefix-p ev2 ev1)))

(defun etaf-ext--keys-printing-single-p (ev)
  "Return non-nil when EV is a single unmodified ASCII printing character."
  (and (= (length ev) 1)
       (integerp (aref ev 0))
       (<= ?\s (aref ev 0) ?~)))

(defun etaf-ext--keys-reserved-p (ev)
  "Return non-nil when EV's leading event is ETAF framework-reserved."
  (let ((km (make-sparse-keymap)))
    (define-key km (vector (aref ev 0)) #'ignore)
    (and (etaf-keymap-reserved-events km) t)))

(defun etaf-ext--format-binding-name (binding)
  "Return concise human-readable name for keymap BINDING."
  (cond
   ((symbolp binding) (symbol-name binding))
   ((keymapp binding) "前缀映射")
   ((functionp binding) "匿名命令")
   (t (format "%s" binding))))

(defun etaf-ext--keymap-conflict-detail (map ev &optional allow-prefixes ignore-commands)
  "Return conflict plist if EV collides with a binding or prefix in MAP, else nil.
ALLOW-PREFIXES is a list of prefix vectors permitted to be prefix keymaps
\(such as bare `C-c' or `ESC').  IGNORE-COMMANDS lists benign stock bindings."
  (when (keymapp map)
    (let ((len (length ev))
          (hit nil))
      ;; 1. Check every proper prefix of EV.
      (cl-loop for i from 1 below len
               until hit
               do (let* ((pfx (substring ev 0 i))
                         (b (lookup-key map pfx t)))
                    (when (and b (not (numberp b)))
                      (cond
                       ((keymapp b)
                        (unless (member pfx allow-prefixes)
                          (setq hit (list :relation 'prefix-map
                                          :key (key-description pfx)
                                          :binding b))))
                       ((not (memq b ignore-commands))
                        (setq hit (list :relation 'prefix-command
                                        :key (key-description pfx)
                                        :binding b)))))))
      ;; 2. Check EV itself.
      (unless hit
        (let ((b (lookup-key map ev t)))
          (when (and b (not (numberp b)))
            (cond
             ((keymapp b)
              (setq hit (list :relation 'exact-map
                              :key (key-description ev)
                              :binding b)))
             ((not (memq b ignore-commands))
              (setq hit (list :relation 'exact-command
                              :key (key-description ev)
                              :binding b)))))))
      hit)))

;;;; Conflict firewall

(defun etaf-ext--check-runtime-app-conflict (ev runtime)
  "Return conflict plist when EV collides with RUNTIME's own app/framework keys."
  (when (and runtime (etaf-runtime-mounted-p runtime))
    (let ((hdata (ignore-errors (etaf-help-data runtime)))
          (hit nil))
      (dolist (group (plist-get hdata :groups))
        (unless (or hit (eq (plist-get group :kind) 'extension))
          (let ((source (or (plist-get group :source) "当前应用")))
            (dolist (entry (plist-get group :entries))
              (unless hit
                (let ((eev (or (plist-get entry :events)
                               (and (stringp (plist-get entry :key))
                                    (ignore-errors
                                      (etaf-ext--keys-to-event (plist-get entry :key)))))))
                  (when (and eev (etaf-ext--keys-overlap-p ev eev))
                    (setq hit
                          (list :kind 'app-key
                                :key (key-description ev)
                                :owner source
                                :reason (format "与当前页面「%s」快捷键 %s（%s）冲突"
                                                source
                                                (or (plist-get entry :key) (key-description eev))
                                                (or (plist-get entry :label) "已占用")))))))))))
      hit)))

(defun etaf-ext--check-minor-mode-conflict (ev runtime)
  "Return conflict plist when EV collides with active minor-mode or emulation maps."
  (let* ((buf (and runtime (etaf-runtime-mounted-p runtime)
                   (etaf-runtime-buffer runtime)))
         (target-buf (if (buffer-live-p buf) buf (current-buffer)))
         (allow-pfx '([?\C-c] [27]))
         (ignore-cmds '(undefined self-insert-command))
         (hit nil))
    (with-current-buffer target-buf
      (dolist (alist (list minor-mode-overriding-map-alist minor-mode-map-alist))
        (dolist (pair alist)
          (unless hit
            (let ((mode (car-safe pair))
                  (map (cdr-safe pair)))
              (when (and (symbolp mode)
                         (not (eq mode 'etaf-ext-mode))
                         (boundp mode)
                         (symbol-value mode)
                         (keymapp map))
                (when-let* ((d (etaf-ext--keymap-conflict-detail
                                map ev allow-pfx ignore-cmds)))
                  (setq hit
                        (list :kind 'minor-mode
                              :key (key-description ev)
                              :owner mode
                              :reason (format "与次模式 %s 的 %s（%s）冲突"
                                              mode
                                              (plist-get d :key)
                                              (etaf-ext--format-binding-name
                                               (plist-get d :binding)))))))))))
      (unless hit
        (dolist (source emulation-mode-map-alists)
          ;; Skip buffer-local emulation maps (ETAF's own runtime keymap and
          ;; app-local emulation maps are already inspected via `etaf-help-data').
          (unless (or hit (and (symbolp source) (local-variable-p source)))
            (let ((alist (if (and (symbolp source) (boundp source))
                             (symbol-value source) source)))
              (when (listp alist)
                (dolist (pair alist)
                  (unless hit
                    (let ((mode (car-safe pair))
                          (map (cdr-safe pair)))
                      (when (and (keymapp map)
                                 (or (eq mode t)
                                     (and (symbolp mode) (boundp mode)
                                          (symbol-value mode))))
                        (when-let* ((d (etaf-ext--keymap-conflict-detail
                                        map ev allow-pfx ignore-cmds)))
                          (setq hit
                                (list :kind 'minor-mode
                                      :key (key-description ev)
                                      :owner (if (symbolp source) source mode)
                                      :reason (format "与按键层 %s 的 %s（%s）冲突"
                                                      (if (symbolp source) source mode)
                                                      (plist-get d :key)
                                                      (etaf-ext--format-binding-name
                                                       (plist-get d :binding))))))))))))))))
    hit))

(defun etaf-ext--check-global-conflict (ev)
  "Return conflict plist when EV collides with `global-map', or nil."
  (let* ((allow-pfx '([?\C-c] [27]))
         ;; On read-only ETAF pages, stock M-f (`forward-word') is safe unless
         ;; rebound by the user or a minor mode/app.
         (ignore-cmds (if (equal ev [?\M-f])
                          '(undefined self-insert-command forward-word)
                        '(undefined self-insert-command)))
         (d (etaf-ext--keymap-conflict-detail global-map ev allow-pfx ignore-cmds)))
    (when d
      (let* ((rel (plist-get d :relation))
             (bname (etaf-ext--format-binding-name (plist-get d :binding)))
             (k (plist-get d :key))
             (pfx-p (memq rel '(prefix-map exact-map))))
        (list :kind (if pfx-p 'global-prefix 'global-key)
              :key (key-description ev)
              :owner (plist-get d :binding)
              :reason (format "与全局%s %s（%s）冲突"
                              (if pfx-p "前缀" "键")
                              k bname))))))

(defun etaf-ext--check-env-conflict (ev runtime &optional check-global-p)
  "Check EV against reserved keys, RUNTIME app keys, minor modes and globals.
When CHECK-GLOBAL-P is nil, skips minor-mode and `global-map' checks (used when
installing an explicit user override already confirmed by the user)."
  (or (when (etaf-ext--keys-reserved-p ev)
        (list :kind 'framework-reserved
              :key (key-description ev)
              :owner 'etaf
              :reason (format "框架保留键 %s，禁止覆盖" (key-description ev))))
      (etaf-ext--check-runtime-app-conflict ev runtime)
      (when check-global-p
        (or (etaf-ext--check-minor-mode-conflict ev runtime)
            (etaf-ext--check-global-conflict ev)))))

(defun etaf-ext--prefix-status (&optional runtime)
  "Return status plist for `etaf-ext-key-prefix' on RUNTIME.
Returns `(:key STR-OR-NIL :status SYM :conflict PLIST-OR-NIL)' where `:status'
is `active', `disabled', `manual-mode' or `conflict'."
  (cond
   ((eq etaf-ext-keybinding-policy 'manual)
    (list :key etaf-ext-key-prefix :status 'manual-mode :conflict nil))
   ((or (null etaf-ext-key-prefix)
        (and (stringp etaf-ext-key-prefix) (string-empty-p etaf-ext-key-prefix)))
    (list :key nil :status 'disabled :conflict nil))
   (t
    (let* ((ev (condition-case nil
                   (etaf-ext--keys-to-event etaf-ext-key-prefix)
                 (error nil)))
           (kdesc (and ev (key-description ev))))
      (if (null ev)
          (list :key etaf-ext-key-prefix
                :status 'conflict
                :conflict (list :kind 'invalid
                                :key (format "%s" etaf-ext-key-prefix)
                                :owner 'etaf-ext
                                :reason "无效的统一扩展前缀键序"))
        (let ((conflict (etaf-ext--check-env-conflict ev runtime t)))
          (if conflict
              (list :key kdesc :status 'conflict :conflict conflict)
            (list :key kdesc :status 'active :conflict nil))))))))

(defun etaf-ext-check-key-conflict (key &optional runtime exclude-ext exclude-cmd)
  "Check whether KEY conflicts with reserved, app, global or extension keys.
RUNTIME is an optional mounted ETAF Runtime.  EXCLUDE-EXT and EXCLUDE-CMD skip
the specified command when checking sibling extensions.
Return nil when conflict-free, or a plist `(:kind :key :owner :reason)'."
  (let* ((ev (etaf-ext--keys-to-event key))
         (kdesc (key-description ev)))
    (or (etaf-ext--check-env-conflict ev runtime t)
        ;; Check unified extension prefix unless checking the prefix itself.
        (let ((pst (unless (eq exclude-ext etaf-ext--dispatch-layer-key)
                     (etaf-ext--prefix-status runtime))))
          (when (and pst (eq (plist-get pst :status) 'active))
            (let ((pev (etaf-ext--keys-to-event (plist-get pst :key))))
              (when (etaf-ext--keys-overlap-p ev pev)
                (list :kind 'ext-prefix
                      :key kdesc
                      :owner 'etaf-ext
                      :reason (format "与统一扩展前缀 %s 冲突"
                                      (plist-get pst :key)))))))
        ;; Check other enabled extensions' active direct keys.
        (let ((hit nil))
          (dolist (entry (etaf-ext-command-bindings runtime))
            (unless hit
              (let ((eid (plist-get entry :ext-id))
                    (cid (plist-get entry :cmd-id))
                    (ekey (plist-get entry :effective-key)))
                (when (and ekey
                           (not (and (eq eid exclude-ext)
                                     (or (null exclude-cmd) (eq cid exclude-cmd)))))
                  (let ((eev (ignore-errors (etaf-ext--keys-to-event ekey))))
                    (when (and eev (etaf-ext--keys-overlap-p ev eev))
                      (setq hit
                            (list :kind 'extension
                                  :key kdesc
                                  :owner eid
                                  :reason (format "与扩展「%s」的「%s」（%s）冲突"
                                                  (plist-get entry :ext-name)
                                                  (plist-get entry :label)
                                                  ekey)))))))))
          hit))))

;;;; Prefix-tree allocation (conflict-free single-char dispatch keys)

(defun etaf-ext--candidate-chars (hint name)
  "Return ordered single-character dispatch key candidates from HINT and NAME."
  (let ((clean (replace-regexp-in-string "\\`etaf-" "" (downcase (or name ""))))
        (pool nil))
    (when (and (stringp hint) (= (length hint) 1))
      (push hint pool))
    (dotimes (i (length clean))
      (let ((ch (aref clean i)))
        (when (or (<= ?a ch ?z) (<= ?0 ch ?9))
          (push (char-to-string ch) pool))))
    (dolist (ch (append (number-sequence ?a ?z) (number-sequence ?1 ?9)))
      (push (char-to-string ch) pool))
    (delete-dups (nreverse pool))))

(defun etaf-ext--allocate-ext-prefixes (ext-ids)
  "Return alist `(EXT-ID . PREFIX-CHAR)' for EXT-IDS with zero collisions."
  (let ((used (copy-sequence etaf-ext--dispatch-reserved-keys))
        (out nil))
    (dolist (id ext-ids (nreverse out))
      (when-let* ((spec (gethash id etaf-ext--registry)))
        (when (etaf-ext--spec-commands spec)
          (let* ((hint (etaf-ext--spec-prefix-hint spec))
                 (cands (etaf-ext--candidate-chars hint (symbol-name id)))
                 (chosen (or (cl-find-if (lambda (c) (not (member c used))) cands)
                             (car cands))))
            (when chosen
              (push chosen used)
              (push (cons id chosen) out))))))))

(defun etaf-ext--allocate-cmd-subkeys (cmds)
  "Return alist `(CMD-ID . SUBKEY-STR)' for CMDS with zero collisions."
  (let ((used '("q" "?" "DEL"))
        (out nil))
    (dolist (cmd cmds (nreverse out))
      (let* ((cid (car cmd))
             (hint (plist-get (cdr cmd) :subkey))
             (cands (etaf-ext--candidate-chars hint (symbol-name cid)))
             (chosen (or (cl-find-if (lambda (c) (not (member c used))) cands)
                         (car cands))))
        (when chosen
          (push chosen used)
          (push (cons cid chosen) out))))))

;;;; Unified two-pass binding resolver

(defun etaf-ext--runtime-eligible-ext-ids (runtime)
  "Return ordered extension IDs eligible for key resolution on RUNTIME.
When RUNTIME is nil, returns all registered extensions in priority order."
  (if (and runtime (etaf-runtime-mounted-p runtime))
      (cl-remove-if-not
       (lambda (id)
         (when-let* ((spec (gethash id etaf-ext--registry)))
           (etaf-ext--allowed-on-runtime-p spec runtime)))
       etaf-ext--order)
    (copy-sequence etaf-ext--order)))

(defun etaf-ext--resolve-all (&optional runtime)
  "Resolve prefix status and all command keybindings for RUNTIME (or globally).
Return plist `(:prefix-status PLIST :ext-prefixes ALIST :bindings LIST)'."
  (etaf-ext--policy-ensure-loaded)
  (let* ((live-rt (and runtime (etaf-runtime-mounted-p runtime) runtime))
         (pst (etaf-ext--prefix-status live-rt))
         (prefix-active-p (eq (plist-get pst :status) 'active))
         (prefix-key (and prefix-active-p (plist-get pst :key)))
         (prefix-ev (and prefix-key (ignore-errors (etaf-ext--keys-to-event prefix-key))))
         (eligible-ids (etaf-ext--runtime-eligible-ext-ids live-rt))
         (active-prefix-ids
          (cl-remove-if-not
           (lambda (id)
             (and (etaf-ext-enabled-p id)
                  (not (gethash id etaf-ext--suspended))))
           eligible-ids))
         (ext-prefixes (etaf-ext--allocate-ext-prefixes active-prefix-ids))
         (claimed nil) ;; list of (ev ext-name cmd-label ext-id)
         (records (make-hash-table :test #'equal))
         (ordered-keys nil))
    ;; Build initial per-command skeletons in priority order.
    (dolist (id etaf-ext--order)
      (when-let* ((spec (gethash id etaf-ext--registry)))
        (let* ((cmds (etaf-ext--spec-commands spec))
               (subkeys (etaf-ext--allocate-cmd-subkeys cmds))
               (epfx (cdr (assq id ext-prefixes)))
               (single-cmd-p (= (length cmds) 1))
               (enabled-p (and (etaf-ext-enabled-p id)
                               (not (gethash id etaf-ext--suspended))))
               (allowed-p (if live-rt
                              (memq id eligible-ids)
                            enabled-p))
               (has-perm-p (and (memq 'keys (etaf-ext--spec-permissions spec)) t)))
          (dolist (cmd cmds)
            (let* ((cid (car cmd))
                   (pl (cdr cmd))
                   (label (plist-get pl :label))
                   (subk (cdr (assq cid subkeys)))
                   (sugg (plist-get pl :suggested-key))
                   (ovr (etaf-ext--policy-key-override id cid))
                   (dispatch-key
                    (when (and prefix-key epfx enabled-p allowed-p)
                      (if single-cmd-p
                          (format "%s %s" prefix-key epfx)
                        (format "%s %s %s" prefix-key epfx subk))))
                   (rec (list :ext-id id
                              :ext-name (etaf-ext--spec-name spec)
                              :cmd-id cid
                              :label label
                              :prefix-key epfx
                              :subkey subk
                              :dispatch-key dispatch-key
                              :suggested-key sugg
                              :override ovr
                              :effective-key nil
                              :source 'none
                              :status (cond
                                       ((not enabled-p) 'disabled)
                                       ((not allowed-p) 'disabled)
                                       ((not has-perm-p) 'no-permission)
                                       (t 'unbound))
                              :conflict nil)))
              (puthash (cons id cid) rec records)
              (push (cons id cid) ordered-keys))))))
    (setq ordered-keys (nreverse ordered-keys))
    ;; Helper to check overlap against already-claimed extension direct keys.
    (cl-flet ((find-claimed (ev)
                (cl-find-if (lambda (c) (etaf-ext--keys-overlap-p ev (car c)))
                            claimed)))
      ;; Pass 1: Explicit user overrides (highest extension precedence).
      (dolist (pair ordered-keys)
        (let* ((rec (gethash pair records))
               (ovr (plist-get rec :override)))
          (when (and (eq (plist-get rec :status) 'unbound)
                     (stringp ovr))
            (let* ((ev (ignore-errors (etaf-ext--keys-to-event ovr)))
                   (kdesc (and ev (key-description ev))))
              (if (null ev)
                  (progn
                    (plist-put rec :source 'user)
                    (plist-put rec :status 'conflict)
                    (plist-put rec :conflict
                               (list :kind 'invalid :key ovr :owner 'user
                                     :reason "无效的自定义按键序列")))
                (let ((conflict
                       (or (etaf-ext--check-env-conflict ev live-rt nil)
                           (when (and prefix-ev (etaf-ext--keys-overlap-p ev prefix-ev))
                             (list :kind 'ext-prefix :key kdesc :owner 'etaf-ext
                                   :reason (format "与统一扩展前缀 %s 冲突" prefix-key)))
                           (when-let* ((hit (find-claimed ev)))
                             (list :kind 'extension :key kdesc :owner (nth 3 hit)
                                   :reason (format "与扩展「%s」的「%s」冲突"
                                                   (nth 1 hit) (nth 2 hit)))))))
                  (plist-put rec :source 'user)
                  (if conflict
                      (progn
                        (plist-put rec :status 'conflict)
                        (plist-put rec :conflict conflict))
                    (plist-put rec :effective-key kdesc)
                    (plist-put rec :status 'active)
                    (push (list ev (plist-get rec :ext-name)
                                (plist-get rec :label) (car pair))
                          claimed))))))))
      ;; Pass 2: Extension `:suggested-key' hints (only when no override exists).
      (dolist (pair ordered-keys)
        (let* ((rec (gethash pair records))
               (ovr (plist-get rec :override))
               (sugg (plist-get rec :suggested-key)))
          (when (and (eq (plist-get rec :status) 'unbound)
                     (null ovr)
                     (stringp sugg))
            (plist-put rec :source 'suggested)
            (if (memq etaf-ext-keybinding-policy '(prefix-only manual))
                (plist-put rec :status 'policy-skipped)
              (let* ((ev (ignore-errors (etaf-ext--keys-to-event sugg)))
                     (kdesc (and ev (key-description ev)))
                     (conflict
                      (cond
                       ((null ev)
                        (list :kind 'invalid :key sugg :owner (car pair)
                              :reason "无效的建议按键序列"))
                       ((etaf-ext--keys-printing-single-p ev)
                        (list :kind 'printing-key :key kdesc :owner (car pair)
                              :reason "单字符印刷键保留给页面应用与导航"))
                       (t
                        (or (etaf-ext--check-env-conflict ev live-rt t)
                            (when (and prefix-ev (etaf-ext--keys-overlap-p ev prefix-ev))
                              (list :kind 'ext-prefix :key kdesc :owner 'etaf-ext
                                    :reason (format "与统一扩展前缀 %s 冲突" prefix-key)))
                            (when-let* ((hit (find-claimed ev)))
                              (list :kind 'extension :key kdesc :owner (nth 3 hit)
                                    :reason (format "与扩展「%s」的「%s」冲突"
                                                    (nth 1 hit) (nth 2 hit)))))))))
                (if conflict
                    (progn
                      (plist-put rec :status 'conflict)
                      (plist-put rec :conflict conflict))
                  (plist-put rec :effective-key kdesc)
                  (plist-put rec :status 'active)
                  (push (list ev (plist-get rec :ext-name)
                              (plist-get rec :label) (car pair))
                        claimed))))))))
    (list :prefix-status pst
          :ext-prefixes ext-prefixes
          :bindings (mapcar (lambda (k) (gethash k records)) ordered-keys))))

(defun etaf-ext-command-bindings (&optional runtime ext-id)
  "Return resolved command keybinding plists for RUNTIME and optional EXT-ID.
Each element is a fresh read-only plist with `:ext-id', `:ext-name', `:cmd-id',
`:label', `:prefix-key', `:subkey', `:dispatch-key', `:suggested-key',
`:override', `:effective-key', `:source', `:status' and `:conflict'."
  (when ext-id (etaf-ext--get-spec ext-id))
  (let* ((resolved (etaf-ext--resolve-all runtime))
         (all (plist-get resolved :bindings))
         (filtered (if ext-id
                       (cl-remove-if-not
                        (lambda (r) (eq (plist-get r :ext-id) ext-id))
                        all)
                     all)))
    (mapcar #'copy-tree filtered)))

;;;; Runtime key-layer synchronization

(defun etaf-ext--clear-dispatch-key-layer (runtime)
  "Remove the unified extension prefix key layer from RUNTIME."
  (when (and runtime (etaf-runtime-mounted-p runtime))
    (ignore-errors
      (etaf-runtime-clear-key-layer runtime etaf-ext--dispatch-layer-key))))

(defun etaf-ext--sync-keys-on-runtime (runtime)
  "Reconcile unified prefix and all per-extension key layers on mounted RUNTIME."
  (when (and runtime (etaf-runtime-mounted-p runtime))
    (if (or (gethash runtime etaf-ext--pure-runtimes)
            (not (bound-and-true-p etaf-ext-mode)))
        (progn
          (etaf-ext--clear-dispatch-key-layer runtime)
          (dolist (id etaf-ext--order)
            (ignore-errors (etaf-runtime-clear-key-layer runtime id))))
      (let* ((resolved (etaf-ext--resolve-all runtime))
             (pst (plist-get resolved :prefix-status))
             (ext-prefixes (plist-get resolved :ext-prefixes))
             (bindings (plist-get resolved :bindings))
             (by-ext (make-hash-table :test #'eq)))
        ;; 1. Unified extension dispatcher prefix layer (only when active & needed).
        (if (and (eq (plist-get pst :status) 'active)
                 ext-prefixes)
            (let ((pkey (plist-get pst :key)))
              (ignore-errors
                (etaf-runtime-set-key-layer
                 runtime
                 etaf-ext--dispatch-layer-key
                 (list (list pkey
                             (lambda ()
                               (interactive)
                               (etaf-ext-dispatch runtime))
                             "扩展命令分发"))
                 "扩展入口"
                 5)))
          (etaf-ext--clear-dispatch-key-layer runtime))
        ;; 2. Group active direct keys per extension.
        (dolist (rec bindings)
          (when (and (eq (plist-get rec :status) 'active)
                     (plist-get rec :effective-key))
            (let ((eid (plist-get rec :ext-id))
                  (cid (plist-get rec :cmd-id))
                  (k (plist-get rec :effective-key))
                  (lbl (plist-get rec :label)))
              (push (list k
                          (lambda ()
                            (interactive)
                            (etaf-ext-run-command eid cid runtime))
                          lbl)
                    (gethash eid by-ext)))))
        ;; 3. Apply or clear each registered extension's direct key layer.
        (dolist (id etaf-ext--order)
          (let ((spec (gethash id etaf-ext--registry))
                (entries (nreverse (gethash id by-ext))))
            (if (and spec entries (etaf-ext--allowed-on-runtime-p spec runtime))
                (ignore-errors
                  (etaf-runtime-set-key-layer
                   runtime id entries
                   (etaf-ext--spec-name spec)
                   (etaf-ext--spec-priority spec)))
              (ignore-errors
                (etaf-runtime-clear-key-layer runtime id)))))))))

;;;; Public keybinding override API

(defun etaf-ext-key-override (id cmd-id)
  "Return persisted key override (string, `:unbound' or nil) for ID and CMD-ID."
  (let ((spec (etaf-ext--get-spec id)))
    (unless (assq cmd-id (etaf-ext--spec-commands spec))
      (signal 'etaf-ext-error (list "Unknown extension command" id cmd-id)))
    (etaf-ext--policy-key-override id cmd-id)))

(defun etaf-ext-set-key (id cmd-id key)
  "Persist direct key override KEY for extension ID's command CMD-ID.
KEY may be a `kbd' string or key vector, `:unbound' to suppress any suggested
direct key, or nil to revert to default resolution.  Framework-reserved keys
signal `etaf-ext-error'.  Immediately reconciles all mounted ETAF Runtimes."
  (let ((spec (etaf-ext--get-spec id)))
    (unless (assq cmd-id (etaf-ext--spec-commands spec))
      (signal 'etaf-ext-error (list "Unknown extension command" id cmd-id)))
    (let ((val (cond
                ((null key) nil)
                ((eq key :unbound) :unbound)
                (t
                 (let ((ev (etaf-ext--keys-to-event key)))
                   (when (etaf-ext--keys-reserved-p ev)
                     (signal 'etaf-ext-error
                             (list "Cannot bind framework-reserved key"
                                   (key-description ev))))
                   (key-description ev))))))
      (etaf-ext--policy-set-key-override id cmd-id val)
      (dolist (rt (etaf-runtime-list))
        (etaf-ext--sync-keys-on-runtime rt))
      (etaf-ext--emit-change 'keybindings id)
      val)))

(defun etaf-ext-reset-key (id cmd-id)
  "Clear any persisted key override for extension ID's command CMD-ID."
  (etaf-ext-set-key id cmd-id nil))

;;;; Target Runtime helper for interactive commands

(defun etaf-ext--keys-target-runtime (&optional runtime)
  "Return mounted non-manager target Runtime for interactive extension commands."
  (or (and runtime (etaf-runtime-mounted-p runtime) runtime)
      (let ((cur (or (etaf-current-runtime)
                     (etaf-runtime-for-buffer (current-buffer)))))
        (when (and cur (etaf-runtime-mounted-p cur)
                   (not (eq (plist-get (etaf-runtime-meta cur) :app)
                            'etaf-ext-manager)))
          cur))
      (cl-find-if
       (lambda (rt)
         (and (etaf-runtime-mounted-p rt)
              (not (eq (plist-get (etaf-runtime-meta rt) :app)
                       'etaf-ext-manager))))
       (etaf-runtime-list))))

;;;; Unified two-step Extension Dispatcher (`etaf-ext-dispatch')

(defun etaf-ext--dispatch-hide ()
  "Hide any open `etaf-ext-dispatch' floating menu."
  (when-let* ((panel etaf-ext--dispatch-panel))
    (setq etaf-ext--dispatch-panel nil)
    (when (and (fboundp 'etaf-posframe-live-p)
               (etaf-posframe-live-p panel))
      (ignore-errors (etaf-posframe-hide panel)))))

(defun etaf-ext--dispatch-show-popup (title rows footer-text)
  "Render a compact non-focusing floating menu via `etaf-posframe' when graphic.
ROWS is a list of `(KEY-STR ICON TONE LABEL META ON-PRESS)'."
  (if (and (not noninteractive)
           etaf-ext-use-posframe
           (display-graphic-p)
           (require 'etaf-posframe nil t)
           (fboundp 'etaf-posframe-show))
      (let* ((theme (etaf-ext-theme))
             (surface (plist-get theme :ext-surface))
             (surface2 (plist-get theme :ext-surface2))
             (fg (plist-get theme :ext-fg))
             (muted (plist-get theme :ext-muted))
             (dim (plist-get theme :ext-dim))
             (accent (plist-get theme :ext-accent))
             (bdr (plist-get theme :ext-border))
             (bdr-soft (plist-get theme :ext-border-soft))
             (hover (plist-get theme :ext-hover))
             (pw 60)
             (ph (min 24 (+ 5 (length rows))))
             (view
              (etaf-node
               'column
               (list :width (list 'ch pw)
                     :background-color surface
                     :color fg
                     :border (list '(px 1) 'solid bdr)
                     :padding '((lh 1) (ch 2))
                     :item-gap '(lh 0))
               (list
                (etaf-node
                 'flex (list :width 'stretch :justify-content 'space-between
                             :align-items 'center
                             :padding '((lh 0) (ch 0) (lh 0) (ch 0)))
                 (list
                  (etaf-node 'text (list :color accent :font-weight 'bold)
                             (list title))
                  (etaf-node 'text (list :color dim)
                             (list (or etaf-ext-key-prefix "扩展分发")))))
                (etaf-node
                 'column
                 (list :width 'stretch
                       :margin '((lh 1) (ch 0) (lh 0) (ch 0))
                       :border-top (list '(px 1) 'solid bdr-soft)
                       :item-gap '(lh 0))
                 (mapcar
                  (lambda (row)
                    (pcase-let ((`(,k ,icon ,_tone ,lbl ,meta ,on-press) row))
                      (etaf-node
                       'flex
                       (append
                        (list :width 'stretch :justify-content 'space-between
                              :align-items 'center :gap '((lh 0) (ch 1))
                              :padding '((lh 0) (ch 1)))
                        (when on-press
                          (list :pointer 'hand
                                :hover-style (list :background-color hover)
                                :on-press on-press)))
                       (list
                        (etaf-node
                         'flex (list :align-items 'center :gap '((lh 0) (ch 1)))
                         (delq nil
                               (list
                                (etaf-node
                                 'box (list :width '(ch 4) :flex-shrink 0
                                            :background-color surface2
                                            :text-align 'center)
                                 (list (etaf-node 'text (list :color accent :font-weight 'bold)
                                                  (list k))))
                                (when (and (stringp icon) (not (string-empty-p icon)))
                                  (etaf-node 'text (list :color muted) (list icon)))
                                (etaf-node 'text (list :color fg) (list lbl)))))
                        (when (and (stringp meta) (not (string-empty-p meta)))
                          (etaf-node 'text (list :color dim) (list meta)))))))
                  rows))
                (etaf-node
                 'box (list :width 'stretch
                            :margin '((lh 1) (ch 0) (lh 0) (ch 0))
                            :border-top (list '(px 1) 'solid bdr-soft)
                            :padding '((lh 0) (ch 0)))
                 (list (etaf-node 'text (list :color dim) (list footer-text))))))))
        (setq etaf-ext--dispatch-panel
              (etaf-posframe-show
               view
               :key 'etaf-ext-dispatch-popup
               :title title
               :at 'frame-center
               :width (+ pw 2)
               :height ph
               :focusable nil
               :focus-on-open nil
               :theme 'auto)))
    (unless noninteractive
      (message "%s: %s"
               title
               (mapconcat (lambda (r) (format "[%s] %s" (nth 0 r) (nth 3 r)))
                          rows "  ")))))

(defun etaf-ext--dispatch-open-ext (rt ext-id ext-pfx cmd-bindings)
  "Open Level-2 subcommand dispatcher for EXT-ID on RT."
  (let* ((spec (etaf-ext--get-spec ext-id))
         (gen (cl-incf etaf-ext--dispatch-gen))
         (map (make-sparse-keymap))
         (rows nil))
    (dolist (rec cmd-bindings)
      (let* ((cid (plist-get rec :cmd-id))
             (subk (plist-get rec :subkey))
             (lbl (plist-get rec :label))
             (ekey (plist-get rec :effective-key))
             (action (lambda ()
                       (interactive)
                       (cl-incf etaf-ext--dispatch-gen)
                       (etaf-ext--dispatch-hide)
                       (etaf-ext-run-command ext-id cid rt))))
        (when subk
          (define-key map (kbd subk) action)
          (push (list subk nil nil lbl (or ekey "") action) rows))))
    (let ((back-fn (lambda ()
                     (interactive)
                     (etaf-ext-dispatch rt)))
          (quit-fn (lambda ()
                     (interactive)
                     (cl-incf etaf-ext--dispatch-gen)
                     (etaf-ext--dispatch-hide))))
      (define-key map (kbd "DEL") back-fn)
      (define-key map (kbd "<backspace>") back-fn)
      (define-key map (kbd "q") quit-fn)
      (define-key map [escape] quit-fn)
      (define-key map (kbd "C-g") quit-fn))
    (etaf-ext--dispatch-show-popup
     (format "%s [%s]" (etaf-ext--spec-name spec) ext-pfx)
     (nreverse rows)
     "按键直接执行 · DEL 返回扩展列表 · Esc 取消")
    (set-transient-map
     map nil
     (lambda ()
       (when (eql etaf-ext--dispatch-gen gen)
         (etaf-ext--dispatch-hide))))))

;;;###autoload
(defun etaf-ext-dispatch (&optional runtime)
  "Open the unified two-step ETAF extension key dispatcher for RUNTIME.
Pressing an extension prefix letter executes immediately when the extension has
one command, or opens its subcommand level when it has multiple commands.
Press `/' for `etaf-ext-command-palette', `M' for `etaf-ext-manage-popup',
or `P' to toggle Pure Mode."
  (interactive)
  (let ((rt (etaf-ext--keys-target-runtime runtime)))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (user-error "当前没有挂载的 ETAF 页面"))
    (when (gethash rt etaf-ext--pure-runtimes)
      (user-error "当前页面处于纯净模式，请先退出纯净模式"))
    (let* ((resolved (etaf-ext--resolve-all rt))
           (ext-prefixes (plist-get resolved :ext-prefixes))
           (all-bindings (plist-get resolved :bindings))
           (gen (cl-incf etaf-ext--dispatch-gen))
           (map (make-sparse-keymap))
           (rows nil))
      (unless ext-prefixes
        (etaf-ext--dispatch-hide)
        (user-error "当前页面没有可用的扩展命令"))
      (dolist (pair ext-prefixes)
        (let* ((eid (car pair))
               (epfx (cdr pair))
               (spec (gethash eid etaf-ext--registry))
               (cmds (cl-remove-if-not
                      (lambda (r) (eq (plist-get r :ext-id) eid))
                      all-bindings))
               (single-p (= (length cmds) 1))
               (action
                (if single-p
                    (let ((only-cid (plist-get (car cmds) :cmd-id)))
                      (lambda ()
                        (interactive)
                        (cl-incf etaf-ext--dispatch-gen)
                        (etaf-ext--dispatch-hide)
                        (etaf-ext-run-command eid only-cid rt)))
                  (lambda ()
                    (interactive)
                    (etaf-ext--dispatch-open-ext rt eid epfx cmds)))))
          (define-key map (kbd epfx) action)
          (push (list epfx
                      (etaf-ext--spec-icon spec)
                      (etaf-ext--spec-tone spec)
                      (etaf-ext--spec-name spec)
                      (if single-p
                          (plist-get (car cmds) :label)
                        (format "%d 条命令 ▸" (length cmds)))
                      action)
                rows)))
      (let ((palette-fn (lambda ()
                          (interactive)
                          (cl-incf etaf-ext--dispatch-gen)
                          (etaf-ext--dispatch-hide)
                          (etaf-ext-command-palette rt)))
            (manage-fn (lambda ()
                         (interactive)
                         (cl-incf etaf-ext--dispatch-gen)
                         (etaf-ext--dispatch-hide)
                         (etaf-ext-manage-popup rt)))
            (pure-fn (lambda ()
                       (interactive)
                       (cl-incf etaf-ext--dispatch-gen)
                       (etaf-ext--dispatch-hide)
                       (etaf-ext-pure-mode-toggle rt)))
            (quit-fn (lambda ()
                       (interactive)
                       (cl-incf etaf-ext--dispatch-gen)
                       (etaf-ext--dispatch-hide))))
        (define-key map (kbd "/") palette-fn)
        (define-key map (kbd "M") manage-fn)
        (define-key map (kbd "P") pure-fn)
        (define-key map (kbd "q") quit-fn)
        (define-key map [escape] quit-fn)
        (define-key map (kbd "C-g") quit-fn))
      (etaf-ext--dispatch-show-popup
       "ETAF 扩展命令分发"
       (nreverse rows)
       "/ 命令面板 · M 扩展中心 · P 纯净模式 · Esc 取消")
      (set-transient-map
       map nil
       (lambda ()
         (when (eql etaf-ext--dispatch-gen gen)
           (etaf-ext--dispatch-hide)))))))

;;;; Unified Fuzzy Command Palette (`etaf-ext-command-palette')

;;;###autoload
(defun etaf-ext-command-palette (&optional runtime)
  "Search and execute any available ETAF extension command for RUNTIME."
  (interactive)
  (let ((rt (etaf-ext--keys-target-runtime runtime)))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (user-error "当前没有挂载的 ETAF 页面"))
    (when (gethash rt etaf-ext--pure-runtimes)
      (user-error "当前页面处于纯净模式，请先退出纯净模式"))
    (let* ((bindings (cl-remove-if
                      (lambda (r) (eq (plist-get r :status) 'disabled))
                      (etaf-ext-command-bindings rt)))
           (table nil))
      (unless bindings
        (user-error "当前页面没有可用的扩展命令"))
      (dolist (rec bindings)
        (let* ((eid (plist-get rec :ext-id))
               (cid (plist-get rec :cmd-id))
               (spec (gethash eid etaf-ext--registry))
               (icon (or (etaf-ext--spec-icon spec) "·"))
               (key-hint (or (plist-get rec :effective-key)
                             (plist-get rec :dispatch-key)
                             "未绑定"))
               (label (format "[%s] %s · %s  [%s]"
                              icon
                              (plist-get rec :ext-name)
                              (plist-get rec :label)
                              key-hint)))
          (push (cons label (cons eid cid)) table)))
      (setq table (nreverse table))
      (let* ((choice (completing-read "ETAF 扩展命令: " table nil t))
             (pair (cdr (assoc choice table))))
        (when pair
          (etaf-ext-run-command (car pair) (cdr pair) rt))))))

(provide 'etaf-ext-keys)
;;; etaf-ext-keys.el ends here
