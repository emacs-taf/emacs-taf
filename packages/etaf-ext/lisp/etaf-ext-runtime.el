;;; etaf-ext-runtime.el --- Lifecycle, permissions, isolation and context API -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runtime orchestration for `etaf-ext':
;; - Per-Runtime attachment lifecycle and lazy `on-command' activation
;; - Strict permission gating on every context primitive
;; - Shared commit-revision Host tree snapshot cache
;; - Automatic debouncing, theme-change dispatch and unmount cleanup
;; - Error ring buffer and automatic circuit breaker isolation
;; - Pure mode and compact non-invasive mode-line indicator

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext-core)
(require 'etaf-ext-store)

(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))
(declare-function etaf-ext--sync-keys-on-runtime "etaf-ext-keys" (runtime))
(declare-function etaf-ext--clear-dispatch-key-layer "etaf-ext-keys" (runtime))
(declare-function etaf-ext-manage "etaf-ext-ui" (&optional target-runtime))

(defcustom etaf-ext-notify-function nil
  "Optional sink called with `(TITLE &rest ARGS)' by `etaf-ext-notify'.
When nil (default), falls back to `message'."
  :type '(choice (const :tag "Use message" nil) function)
  :group 'etaf-ext)

;;;; Context record & runtime tables

(cl-defstruct (etaf-ext-context (:constructor etaf-ext--ctx-make) (:copier nil))
  "Live attachment handle handed to one extension on one mounted Runtime."
  id spec runtime state active-p
  (trigger 'manual)
  commit-timer scroll-timer
  popup-panel popup-buffer)

(defvar etaf-ext--attach-trigger 'manual
  "Dynamic reason for `etaf-ext-attach' (`auto', `manual', `command', `popup').")

(defvar etaf-ext--explicitly-disabled nil
  "Non-nil when the user explicitly turned off `etaf-ext-mode'.")

(defvar etaf-ext--scroll-observers (make-hash-table :test #'eq :weakness 'key)
  "Weak map from `etaf-runtime' to its shared buffer-local scroll hook fn.")

(defvar etaf-ext--attachments (make-hash-table :test #'eq :weakness 'key)
  "Weak map from mounted `etaf-runtime' to alist of (EXT-ID . `etaf-ext-context').")

(defvar etaf-ext--tree-cache (make-hash-table :test #'eq :weakness 'key)
  "Weak map from mounted `etaf-runtime' to (REVISION . HOST-TREE).")

(defvar etaf-ext--pure-runtimes (make-hash-table :test #'eq :weakness 'key)
  "Weak set of mounted `etaf-runtime' instances currently in pure mode.")

(defvar etaf-ext--errors (make-hash-table :test #'eq)
  "Hash map from extension ID to list of recent error plists.")

(defvar etaf-ext--consecutive-errors (make-hash-table :test #'eq)
  "Hash map from extension ID to consecutive failure count.")

(defvar etaf-ext--suspended (make-hash-table :test #'eq)
  "Hash set of extension IDs suspended by the circuit breaker.")

(defvar etaf-ext--hooks-installed nil
  "Non-nil when `etaf-ext' lifecycle hooks are wired into ETAF.")

(defvar etaf-ext--theme-timer nil
  "Coalescing timer for dispatching theme changes to attached extensions.")

;;;; Mode-line indicator (preserves user theme mode-line)

(defvar-local etaf-ext--mode-line-active nil
  "Non-nil when the compact extension badge is active in this buffer.")

(defvar-local etaf-ext--mode-line-label ""
  "Propertized compact extension badge for this buffer.")

(defconst etaf-ext--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1]
      (lambda (ev)
        (interactive "e")
        (with-selected-window (posn-window (event-start ev))
          (let ((rt (etaf-runtime-for-buffer (current-buffer))))
            (if (fboundp 'etaf-ext-manage)
                (etaf-ext-manage rt)
              (message "ETAF Extensions active"))))))
    (define-key map [mode-line mouse-2]
      (lambda (ev)
        (interactive "e")
        (with-selected-window (posn-window (event-start ev))
          (etaf-ext-pure-mode-toggle))))
    map)
  "Keymap for clicking the compact `etaf-ext' mode-line indicator.")

(unless (assq 'etaf-ext--mode-line-active minor-mode-alist)
  (push '(etaf-ext--mode-line-active (:eval etaf-ext--mode-line-label))
        minor-mode-alist))

(defun etaf-ext--update-indicator (runtime)
  "Refresh the compact buffer-local mode-line indicator for RUNTIME."
  (when (and runtime (etaf-runtime-mounted-p runtime))
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let* ((pure (gethash runtime etaf-ext--pure-runtimes))
                 (attached (gethash runtime etaf-ext--attachments))
                 (active-ctxs (cl-remove-if-not #'etaf-ext-context-active-p
                                                (mapcar #'cdr attached)))
                 (susp-count (hash-table-count etaf-ext--suspended))
                 (badges nil))
            (dolist (ctx active-ctxs)
              (when-let* ((fn (etaf-ext--spec-badge (etaf-ext-context-spec ctx))))
                (when-let* ((res (condition-case nil (funcall fn ctx) (error nil)))
                            (txt (and (listp res) (plist-get res :text)))
                            ((and (stringp txt) (not (string-empty-p txt)))))
                  (push txt badges))))
            (setq badges (nreverse badges))
            (if (and (not pure) (null active-ctxs) (= susp-count 0))
                (setq etaf-ext--mode-line-active nil
                      etaf-ext--mode-line-label "")
              (let* ((raw (cond
                           (pure " 拼⊘")
                           ((> susp-count 0) (format " 拼!%d" susp-count))
                           (badges (format " 拼[%s]" (mapconcat #'identity badges "·")))
                           (t (format " 拼%d" (length active-ctxs)))))
                     (tip (format "ETAF 扩展: 运行 %d · 暂停 %d%s\n左键: 扩展管理 · 中键: 纯净模式"
                                  (length active-ctxs) susp-count
                                  (if pure " · 纯净模式" ""))))
                (setq etaf-ext--mode-line-label
                      (propertize raw
                                  'help-echo tip
                                  'mouse-face 'mode-line-highlight
                                  'local-map etaf-ext--mode-line-map)
                      etaf-ext--mode-line-active t))))
          (force-mode-line-update))))))

;;;; Error isolation & circuit breaker

(defun etaf-ext--record-error (ext-id phase err)
  "Record ERR during PHASE for EXT-ID and trip circuit breaker if needed."
  (let* ((msg (condition-case nil
                  (error-message-string err)
                (error (format "%s" (car-safe err)))))
         (entry (list :time (format-time-string "%H:%M:%S")
                      :phase phase
                      :message msg))
         (existing (gethash ext-id etaf-ext--errors))
         (trimmed (cons entry (cl-subseq existing 0 (min (length existing)
                                                         (max 0 (1- etaf-ext-max-error-log))))))
         (streak (1+ (or (gethash ext-id etaf-ext--consecutive-errors) 0))))
    (puthash ext-id trimmed etaf-ext--errors)
    (puthash ext-id streak etaf-ext--consecutive-errors)
    (when (and (> etaf-ext-circuit-breaker-threshold 0)
               (>= streak etaf-ext-circuit-breaker-threshold)
               (not (gethash ext-id etaf-ext--suspended)))
      (puthash ext-id t etaf-ext--suspended)
      (etaf-ext--detach-from-all ext-id)
      (etaf-ext--emit-change 'suspended ext-id)
      (let* ((spec (gethash ext-id etaf-ext--registry))
             (ename (if spec (etaf-ext--spec-name spec) (symbol-name ext-id))))
        (etaf-notify
         (format "扩展熔断保护 · %s" ename)
         :app 'etaf-ext
         :detail (format "连续异常 %d 次，已自动暂停并清理其页面表现" streak)
         :variant 'danger
         :group (cons 'etaf-ext-cb ext-id)
         :ttl 8.0
         :actions (list (list :id 'open :label "打开扩展中心" :primary t
                              :fn (lambda ()
                                    (when (fboundp 'etaf-ext-manage)
                                      (etaf-ext-manage)))))))
      (message "ETAF 扩展 %s 连续异常 %d 次，已自动暂停并清理" ext-id streak))
    (etaf-ext--emit-change 'error ext-id)))

(defun etaf-ext--safe-call (ext-id phase fn &rest args)
  "Invoke FN with ARGS under error isolation for EXT-ID during PHASE."
  (condition-case err
      (let ((res (apply fn args)))
        (puthash ext-id 0 etaf-ext--consecutive-errors)
        res)
    (error
     (etaf-ext--record-error ext-id phase err)
     nil)))

(defun etaf-ext-errors (id)
  "Return detached list of recent error plists recorded for extension ID."
  (etaf-ext--get-spec id)
  (copy-tree (gethash id etaf-ext--errors)))

(defun etaf-ext-clear-errors (id)
  "Clear recorded errors and consecutive failure count for extension ID."
  (etaf-ext--get-spec id)
  (remhash id etaf-ext--errors)
  (puthash id 0 etaf-ext--consecutive-errors)
  (etaf-ext--emit-change 'errors-cleared id)
  t)

(defun etaf-ext-suspended-p (id)
  "Return non-nil when extension ID is suspended by the circuit breaker."
  (etaf-ext--get-spec id)
  (and (gethash id etaf-ext--suspended) t))

(defun etaf-ext-reset (id)
  "Clear circuit-breaker suspension and errors for ID, re-attaching live Runtimes."
  (etaf-ext--get-spec id)
  (remhash id etaf-ext--suspended)
  (remhash id etaf-ext--errors)
  (puthash id 0 etaf-ext--consecutive-errors)
  (when (etaf-ext-enabled-p id)
    (etaf-ext--sync-ext-on-all id))
  (etaf-ext--emit-change 'reset id)
  t)

;;;; Permission & liveness guards

(defun etaf-ext--check-ctx (ctx perm)
  "Ensure CTX is a live extension context and holds PERM (when non-nil)."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (unless (and (etaf-ext-context-active-p ctx)
               (etaf-runtime-mounted-p (etaf-ext-context-runtime ctx)))
    (signal 'etaf-ext-error
            (list "Extension context is no longer active" (etaf-ext-context-id ctx))))
  (when (and perm
             (not (memq perm (etaf-ext--spec-permissions
                              (etaf-ext-context-spec ctx)))))
    (signal 'etaf-ext-permission-error
            (list (format "Extension %s lacks permission %s"
                          (etaf-ext-context-id ctx) perm)
                  (etaf-ext-context-id ctx) perm)))
  ctx)

;;;; Public Context API (permission-checked)

(defun etaf-ext-ctx-id (ctx)
  "Return extension ID symbol of CTX."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (etaf-ext-context-id ctx))

(defun etaf-ext-ctx-runtime (ctx)
  "Return mounted `etaf-runtime' associated with CTX."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (etaf-ext-context-runtime ctx))

(defun etaf-ext-ctx-state (ctx)
  "Return per-Runtime session state stored on CTX."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (etaf-ext-context-state ctx))

(defun etaf-ext-ctx-set-state (ctx value)
  "Store per-Runtime session state VALUE on CTX and return VALUE."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (setf (etaf-ext-context-state ctx) value))

(defun etaf-ext-ctx-meta (ctx)
  "Return detached Runtime metadata plist for CTX."
  (etaf-ext--check-ctx ctx nil)
  (etaf-runtime-meta (etaf-ext-context-runtime ctx)))

(defun etaf-ext-ctx-trigger (ctx)
  "Return attach trigger (`auto', `manual', `command' or `popup') for CTX."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (etaf-ext-context-trigger ctx))

(defun etaf-ext-refresh-badge (ctx)
  "Refresh the compact mode-line extension badge for CTX's Runtime."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (let ((rt (etaf-ext-context-runtime ctx)))
    (when (and rt (etaf-runtime-mounted-p rt))
      (etaf-ext--update-indicator rt))
    t))

(defun etaf-ext-tree (ctx)
  "Return read-only Host tree for CTX's Runtime (shared within commit revision).
Requires `read-tree' permission."
  (etaf-ext--check-ctx ctx 'read-tree)
  (let* ((rt (etaf-ext-context-runtime ctx))
         (rev (etaf-runtime-revision rt))
         (cached (gethash rt etaf-ext--tree-cache)))
    (if (and cached (eql (car cached) rev))
        (cdr cached)
      (let ((tree (etaf-runtime-host-tree rt)))
        (puthash rt (cons rev tree) etaf-ext--tree-cache)
        tree))))

(defun etaf-ext-geometries (ctx host-ids)
  "Return live geometry and visibility alist for HOST-IDS in CTX's Runtime.
Requires `read-tree' permission."
  (etaf-ext--check-ctx ctx 'read-tree)
  (etaf-runtime-host-geometries (etaf-ext-context-runtime ctx) host-ids))

(defun etaf-ext-host-at-point (ctx &optional position)
  "Return Host ID lineage at POSITION (default point) in CTX's Runtime.
Requires `read-tree' permission."
  (etaf-ext--check-ctx ctx 'read-tree)
  (etaf-runtime-host-id-at (etaf-ext-context-runtime ctx) position))

(defun etaf-ext-host-text-at-point (ctx &optional position)
  "Return text Host offset and active region plist at POSITION in CTX's Runtime.
Requires `read-tree' permission."
  (etaf-ext--check-ctx ctx 'read-tree)
  (etaf-runtime-host-text-offset-at (etaf-ext-context-runtime ctx) position))

(defun etaf-ext-inspect-host (ctx host-id)
  "Return detailed box-model and ECSS inspection plist for HOST-ID.
Requires `inspect' permission."
  (etaf-ext--check-ctx ctx 'inspect)
  (etaf-runtime-inspect-host (etaf-ext-context-runtime ctx) host-id))

(defun etaf-ext-commit-summary (ctx)
  "Return latest commit summary plist for CTX's Runtime.
Requires `inspect' permission."
  (etaf-ext--check-ctx ctx 'inspect)
  (etaf-runtime-commit-summary (etaf-ext-context-runtime ctx)))

(defun etaf-ext-decorate (ctx updates)
  "Apply decoration UPDATES `(HOST-ID . (:spans ... :face ...))' owned by CTX.
Requires `decorate' permission."
  (etaf-ext--check-ctx ctx 'decorate)
  (let* ((rt (etaf-ext-context-runtime ctx))
         (id (etaf-ext-context-id ctx))
         (prio (etaf-ext--spec-priority (etaf-ext-context-spec ctx)))
         (specs
          (mapcar (lambda (entry)
                    (let ((hid (car entry))
                          (val (cdr entry)))
                      (cons hid
                            (if (null val)
                                (list :mode 'decorate :spans nil :face nil)
                              (append (list :mode 'decorate)
                                      (unless (plist-member val :priority)
                                        (list :priority prio))
                                      val)))))
                  updates)))
    (prog1 (etaf-runtime-set-host-presentations rt id specs)
      (etaf-ext--update-indicator rt))))

(defun etaf-ext-companion (ctx updates)
  "Apply companion UPDATES `(HOST-ID . (:mode ... :view ...))' owned by CTX.
`:mode' defaults to `companion-after'.  Requires `companion' permission."
  (etaf-ext--check-ctx ctx 'companion)
  (let* ((rt (etaf-ext-context-runtime ctx))
         (id (etaf-ext-context-id ctx))
         (prio (etaf-ext--spec-priority (etaf-ext-context-spec ctx)))
         (specs
          (mapcar (lambda (entry)
                    (let ((hid (car entry))
                          (val (cdr entry)))
                      (cons hid
                            (if (null val)
                                nil
                              (append (unless (plist-member val :mode)
                                        (list :mode 'companion-after))
                                      (unless (plist-member val :priority)
                                        (list :priority prio))
                                      val)))))
                  updates)))
    (prog1 (etaf-runtime-set-host-presentations rt id specs)
      (etaf-ext--update-indicator rt))))

(defun etaf-ext-override (ctx updates)
  "Apply override UPDATES `(HOST-ID . (:text ... | :view ...))' owned by CTX.
Requires `override' permission."
  (etaf-ext--check-ctx ctx 'override)
  (let* ((rt (etaf-ext-context-runtime ctx))
         (id (etaf-ext-context-id ctx))
         (prio (etaf-ext--spec-priority (etaf-ext-context-spec ctx)))
         (specs
          (mapcar (lambda (entry)
                    (let ((hid (car entry))
                          (val (cdr entry)))
                      (cons hid
                            (if (null val)
                                nil
                              (append (list :mode 'override)
                                      (unless (plist-member val :priority)
                                        (list :priority prio))
                                      val)))))
                  updates)))
    (prog1 (etaf-runtime-set-host-presentations rt id specs)
      (etaf-ext--update-indicator rt))))

(defun etaf-ext-present (ctx updates)
  "Apply mixed Host presentation UPDATES atomically in one flush for CTX.
Each entry in UPDATES is `(HOST-ID . SPEC)' where SPEC is nil (remove) or a
presentation plist whose `:mode' (`decorate', `override', `companion-after',
`companion-beside', `companion-inside') is checked against CTX's permissions."
  (etaf-ext--check-ctx ctx nil)
  (let* ((rt (etaf-ext-context-runtime ctx))
         (id (etaf-ext-context-id ctx))
         (perms (etaf-ext--spec-permissions (etaf-ext-context-spec ctx)))
         (prio (etaf-ext--spec-priority (etaf-ext-context-spec ctx)))
         (specs
          (mapcar
           (lambda (entry)
             (let ((hid (car entry))
                   (val (cdr entry)))
               (if (null val)
                   (progn
                     (unless (or (memq 'decorate perms)
                                 (memq 'companion perms)
                                 (memq 'override perms))
                       (signal 'etaf-ext-permission-error
                               (list (format "Extension %s lacks presentation permission" id)
                                     id 'companion)))
                     (cons hid nil))
                 (let* ((mode (or (plist-get val :mode) 'companion-after))
                        (req-perm (pcase mode
                                    ('decorate 'decorate)
                                    ('override 'override)
                                    (_ 'companion))))
                   (unless (memq req-perm perms)
                     (signal 'etaf-ext-permission-error
                             (list (format "Extension %s lacks permission %s" id req-perm)
                                   id req-perm)))
                   (cons hid (append (unless (plist-member val :mode)
                                       (list :mode mode))
                                     (unless (plist-member val :priority)
                                       (list :priority prio))
                                     val))))))
           updates)))
    (prog1 (etaf-runtime-set-host-presentations rt id specs)
      (etaf-ext--update-indicator rt))))

(defun etaf-ext-clear-presentations (ctx)
  "Clear all Host presentations owned by CTX on its Runtime."
  (etaf-ext--check-ctx ctx nil)
  (let ((rt (etaf-ext-context-runtime ctx)))
    (prog1 (etaf-runtime-clear-presentations rt (etaf-ext-context-id ctx))
      (etaf-ext--update-indicator rt))))

(defun etaf-ext-set-overlay (ctx view &optional origin)
  "Set or update root-layer overlay VIEW owned by CTX.
Requires `overlay' permission."
  (etaf-ext--check-ctx ctx 'overlay)
  (let ((rt (etaf-ext-context-runtime ctx)))
    (prog1 (etaf-runtime-set-overlay rt (etaf-ext-context-id ctx) view origin)
      (etaf-ext--update-indicator rt))))

(defun etaf-ext-clear-overlay (ctx)
  "Remove root-layer overlay owned by CTX."
  (etaf-ext--check-ctx ctx nil)
  (let ((rt (etaf-ext-context-runtime ctx)))
    (prog1 (etaf-runtime-clear-overlay rt (etaf-ext-context-id ctx))
      (etaf-ext--update-indicator rt))))

(defun etaf-ext-press (ctx host-id)
  "Trigger press event on committed HOST-ID in CTX's Runtime.
Requires `interact' permission."
  (etaf-ext--check-ctx ctx 'interact)
  (etaf-runtime-trigger-host-press (etaf-ext-context-runtime ctx) host-id))

(defun etaf-ext-focus (ctx host-id)
  "Move logical focus to committed HOST-ID in CTX's Runtime.
Requires `interact' permission."
  (etaf-ext--check-ctx ctx 'interact)
  (etaf-runtime-focus-host (etaf-ext-context-runtime ctx) host-id))

(defun etaf-ext-scroll-to (ctx host-id &optional align)
  "Scroll CTX's Runtime so committed HOST-ID is visible.
Requires `interact' permission."
  (etaf-ext--check-ctx ctx 'interact)
  (etaf-runtime-scroll-host-into-view (etaf-ext-context-runtime ctx) host-id align))

(defun etaf-ext-storage-get (ctx key &optional default)
  "Read persisted KEY under CTX's isolated storage namespace.
Requires `storage' permission."
  (etaf-ext--check-ctx ctx 'storage)
  (etaf-ext--kv-get (etaf-ext-context-id ctx) key default))

(defun etaf-ext-storage-set (ctx key value)
  "Write VALUE for KEY under CTX's isolated storage namespace.
Requires `storage' permission."
  (etaf-ext--check-ctx ctx 'storage)
  (etaf-ext--kv-set (etaf-ext-context-id ctx) key value))

(defun etaf-ext-storage-delete (ctx key)
  "Delete KEY from CTX's isolated storage namespace.
Requires `storage' permission."
  (etaf-ext--check-ctx ctx 'storage)
  (etaf-ext--kv-delete (etaf-ext-context-id ctx) key))

(defun etaf-ext-storage-keys (ctx)
  "List stored keys under CTX's isolated storage namespace.
Requires `storage' permission."
  (etaf-ext--check-ctx ctx 'storage)
  (etaf-ext--kv-keys (etaf-ext-context-id ctx)))

(defun etaf-ext--hex-color (color)
  "Normalize COLOR to an `#RRGGBB' string, or return nil if invalid."
  (when (and (stringp color)
             (not (member color '("unspecified-fg" "unspecified-bg" "unspecified")))
             (ignore-errors (color-name-to-rgb color)))
    (apply #'color-rgb-to-hex (append (color-name-to-rgb color) '(2)))))

(defun etaf-ext--face-hex (face attr &optional frame)
  "Read FACE ATTR on FRAME as an `#RRGGBB' string, or nil."
  (when (facep face)
    (etaf-ext--hex-color (ignore-errors (face-attribute face attr frame t)))))

(defun etaf-ext--luminance (hex)
  "Return rough perceived luminance (0..1) of `#RRGGBB' color HEX."
  (pcase-let ((`(,r ,g ,b) (or (color-name-to-rgb hex) '(0.5 0.5 0.5))))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun etaf-ext--calm-hue (raw surface fg dark &optional min-contrast)
  "Return a restrained, readable hue derived from RAW over SURFACE.
In DARK polarity, gently desaturates overly electric hues toward FG so status
pills, icons and accents stay calm instead of neon."
  (let* ((base (or raw (if dark "#64B5F6" "#2563EB")))
         (softened (if dark
                       (let* ((desat (etaf-ui-color-mix base fg 0.24))
                              (lum (etaf-ext--luminance desat)))
                         (if (> lum 0.68)
                             (etaf-ui-color-mix desat surface 0.22)
                           desat))
                     base)))
    (etaf-ui-color-legible softened surface (or min-contrast 4.0))))

(defun etaf-ext-theme (&optional frame)
  "Build an `etaf-ui-theme-tokens' plist derived from Emacs FRAME's palette.
Includes calm three-tier `:ext-*' surface roles plus standard `:ui-*' tokens."
  (let* ((f (or frame (selected-frame)))
         (raw-bg (or (etaf-ext--face-hex 'default :background f)
                     (if (eq (etaf-appearance) 'dark) "#263238" "#FFFFFF")))
         (dark (or (< (etaf-ext--luminance raw-bg) 0.45)
                   (and (eq (etaf-appearance) 'dark)
                        (< (etaf-ext--luminance raw-bg) 0.55))))
         (fg (or (etaf-ext--face-hex 'default :foreground f)
                 (if dark "#E2E8F0" "#1E293B")))
         ;; Three-tier calm elevation: canvas < surface (cards) < surface2 (inset strips).
         (canvas (if dark
                     raw-bg
                   (etaf-ui-color-mix raw-bg fg 0.03)))
         (surface (if dark
                      (etaf-ui-color-mix raw-bg fg 0.055)
                    raw-bg))
         (surface2 (if dark
                       (etaf-ui-color-mix raw-bg fg 0.095)
                     (etaf-ui-color-mix raw-bg fg 0.055)))
         (border (etaf-ui-color-mix surface fg (if dark 0.11 0.13)))
         (border-soft (etaf-ui-color-mix surface fg (if dark 0.065 0.075)))
         (hover (etaf-ui-color-mix surface fg (if dark 0.06 0.04)))
         (muted (etaf-ui-color-legible
                 (or (let ((sh (etaf-ext--face-hex 'shadow :foreground f)))
                       (and sh (>= (etaf-ui-color-contrast sh surface) 3.6) sh))
                     (etaf-ui-color-mix fg surface (if dark 0.34 0.36)))
                 surface 4.2))
         (dim (etaf-ui-color-legible
               (etaf-ui-color-mix fg surface (if dark 0.50 0.50))
               surface 3.1))
         (raw-accent (or (etaf-ext--face-hex 'link :foreground f)
                         (etaf-ext--face-hex 'font-lock-function-name-face :foreground f)
                         (if dark "#64B5F6" "#2563EB")))
         (accent (etaf-ext--calm-hue raw-accent surface fg dark 4.2))
         ;; Deep composed fill for primary CTA in dark mode instead of electric pastel.
         (accent-fill (if dark
                          (etaf-ui-color-mix accent canvas 0.54)
                        accent))
         (accent-fg (if (>= (etaf-ui-color-contrast "#F8FAFC" accent-fill) 4.5)
                        "#F8FAFC"
                      "#0F172A"))
         (accent-soft (etaf-ui-color-mix accent surface (if dark 0.87 0.89)))
         (accent-border (etaf-ui-color-mix surface accent (if dark 0.30 0.36)))
         (selected (if dark
                       (etaf-ui-color-mix (etaf-ui-color-mix surface fg 0.06) accent 0.07)
                     (etaf-ui-color-mix accent surface 0.92)))
         (selected-border (etaf-ui-color-mix surface accent (if dark 0.36 0.52)))
         (success (etaf-ext--calm-hue
                   (or (etaf-ext--face-hex 'success :foreground f)
                       (etaf-ext--face-hex 'font-lock-string-face :foreground f)
                       (if dark "#81C784" "#15803D"))
                   surface fg dark 4.0))
         (success-soft (etaf-ui-color-mix success surface (if dark 0.88 0.90)))
         (success-border (etaf-ui-color-mix surface success (if dark 0.28 0.34)))
         (warning (etaf-ext--calm-hue
                   (or (etaf-ext--face-hex 'warning :foreground f)
                       (if dark "#FFB74D" "#B45309"))
                   surface fg dark 4.0))
         (warning-soft (etaf-ui-color-mix warning surface (if dark 0.88 0.90)))
         (warning-border (etaf-ui-color-mix surface warning (if dark 0.28 0.34)))
         (danger (etaf-ext--calm-hue
                  (or (etaf-ext--face-hex 'error :foreground f)
                      (if dark "#F36C60" "#DC2626"))
                  surface fg dark 4.0))
         (danger-soft (etaf-ui-color-mix danger surface (if dark 0.88 0.90)))
         (danger-border (etaf-ui-color-mix surface danger (if dark 0.30 0.36)))
         (kbd-bg (if dark
                     (etaf-ui-color-mix surface canvas 0.45)
                   surface2))
         (kbd-border border-soft))
    (append
     (list :ext-mode (if dark 'dark 'light)
           :ext-bg raw-bg
           :ext-canvas canvas
           :ext-fg fg
           :ext-panel surface
           :ext-surface surface
           :ext-surface2 surface2
           :ext-track surface2
           :ext-selected selected
           :ext-selected-border selected-border
           :ext-hover hover
           :ext-border border
           :ext-border-soft border-soft
           :ext-muted muted
           :ext-dim dim
           :ext-accent accent
           :ext-accent-fill accent-fill
           :ext-accent-fg accent-fg
           :ext-accent-soft accent-soft
           :ext-accent-border accent-border
           :ext-success success
           :ext-success-soft success-soft
           :ext-success-border success-border
           :ext-warning warning
           :ext-warning-soft warning-soft
           :ext-warning-border warning-border
           :ext-danger danger
           :ext-danger-soft danger-soft
           :ext-danger-border danger-border
           :ext-kbd-bg kbd-bg
           :ext-kbd-border kbd-border)
     (etaf-ui-theme-tokens
      (list :bg canvas :fg fg :panel surface :track surface2 :border border
            :muted muted :dim dim :accent accent :accent-fg accent-fg
            :accent-soft accent-soft
            :success success :warning warning :danger danger :info accent)))))

(etaf-define-component etaf-ext--themed-root (&key theme render)
  "Root wrapper providing THEME tokens for fallback popup and manager buffers."
  :setup (progn (etaf-theme-provide theme) nil)
  :render (etaf-view (expr (if (functionp render) (funcall render) render))))

(defun etaf-ext--posframe-ready-p ()
  "Return non-nil when `etaf-posframe' can render child-frame popups."
  (and etaf-ext-use-posframe
       (display-graphic-p)
       (require 'etaf-posframe nil t)
       (fboundp 'etaf-posframe-show)))

(defun etaf-ext-hide-popup (ctx)
  "Hide any floating popup currently owned by CTX."
  (unless (etaf-ext-context-p ctx)
    (signal 'etaf-ext-error (list "Expected an etaf-ext-context" ctx)))
  (when-let* ((panel (etaf-ext-context-popup-panel ctx)))
    (setf (etaf-ext-context-popup-panel ctx) nil)
    (when (fboundp 'etaf-posframe-hide)
      (ignore-errors (etaf-posframe-hide panel))))
  (when-let* ((pbuf (etaf-ext-context-popup-buffer ctx)))
    (setf (etaf-ext-context-popup-buffer ctx) nil)
    (when (buffer-live-p pbuf)
      (when-let* ((win (get-buffer-window pbuf t)))
        (ignore-errors (delete-window win)))
      (when-let* ((prt (etaf-runtime-for-buffer pbuf)))
        (ignore-errors (etaf-unmount prt)))
      (ignore-errors (kill-buffer pbuf))))
  t)

(defun etaf-ext-show-popup (ctx view &rest options)
  "Show floating popup VIEW owned by CTX with OPTIONS.
VIEW may be an ETAF View or a zero-argument function returning one.
Prefers `etaf-posframe' on graphical displays and falls back to a native ETAF
side window otherwise.  Requires `popup' permission."
  (etaf-ext--check-ctx ctx 'popup)
  (etaf-ext-hide-popup ctx)
  (let* ((id (etaf-ext-context-id ctx))
         (rt (etaf-ext-context-runtime ctx))
         (buf (etaf-runtime-buffer rt))
         (title (or (plist-get options :title)
                    (etaf-ext--spec-name (etaf-ext-context-spec ctx))))
         (width (or (plist-get options :width) 52))
         (height (or (plist-get options :height) 18))
         (at (or (plist-get options :at) 'window-top-right))
         (focusable (if (plist-member options :focusable)
                        (and (plist-get options :focusable) t)
                      t))
         (focus-on-open (and (plist-get options :focus-on-open) t)))
    (if (and (buffer-live-p buf) (etaf-ext--posframe-ready-p))
        (with-current-buffer buf
          (let ((panel (etaf-posframe-show
                        view
                        :key (intern (format "etaf-ext-popup:%s" id))
                        :title title
                        :width width
                        :height height
                        :at at
                        :focusable focusable
                        :focus-on-open focus-on-open
                        :draggable t
                        :theme 'auto)))
            (setf (etaf-ext-context-popup-panel ctx) panel)
            panel))
      (let* ((pbuf (get-buffer-create (format " *ETAF Ext: %s*" id)))
             (theme (etaf-ext-theme))
             (wrapped (etaf-view
                       (etaf-ext--themed-root :theme theme :render view))))
        (etaf-mount pbuf wrapped (list :viewport-width (* width 8)
                                       :viewport-height height))
        (setf (etaf-ext-context-popup-buffer ctx) pbuf)
        (unless noninteractive
          (display-buffer-in-side-window
           pbuf `((side . right) (slot . 1) (window-width . ,(max 36 width)))))
        pbuf))))

(defun etaf-ext--activity-key (ctx)
  "Return stable `etaf-activity' key owned by extension context CTX."
  (cons 'etaf-ext (cons (etaf-ext-context-id ctx)
                        (etaf-ext-context-runtime ctx))))

(defun etaf-ext-set-activity (ctx plist)
  "Publish a live ETAF activity owned by CTX from PLIST.
Automatically cleans up when CTX detaches, unmounts, suspends or enters
pure mode."
  (etaf-ext--check-ctx ctx nil)
  (let* ((id (etaf-ext-context-id ctx))
         (rt (etaf-ext-context-runtime ctx))
         (merged (copy-sequence plist)))
    (unless (plist-get merged :app)
      (setq merged (plist-put merged :app id)))
    (setq merged (plist-put merged :owner-runtime rt))
    (etaf-activity-publish (etaf-ext--activity-key ctx) merged)))

(defun etaf-ext-clear-activity (ctx)
  "Remove any live ETAF activity owned by CTX."
  (when (etaf-ext-context-p ctx)
    (etaf-activity-remove (etaf-ext--activity-key ctx))))

(defun etaf-ext-notify (ctx title &rest args)
  "Send user notification TITLE from CTX.
Routes to `etaf-ext-notify-function' when set, otherwise publishes through
`etaf-notify' (which pulses active shells or falls back to `message').
Requires `notify' permission."
  (etaf-ext--check-ctx ctx 'notify)
  (let ((detail (plist-get args :detail))
        (variant (or (plist-get args :variant) 'info))
        (ttl (or (plist-get args :ttl) 5.0))
        (group (plist-get args :group))
        (actions (plist-get args :actions)))
    (if (and (functionp etaf-ext-notify-function) (not noninteractive))
        (ignore-errors (apply etaf-ext-notify-function title args))
      (etaf-notify title
                   :app (etaf-ext-context-id ctx)
                   :detail detail
                   :variant variant
                   :ttl ttl
                   :group group
                   :actions actions))
    t))

;;;; Matching with global enable & per-app policies

(defun etaf-ext--allowed-on-runtime-p (spec runtime)
  "Return non-nil when SPEC is enabled, unsuspended and allowed on RUNTIME."
  (let* ((id (etaf-ext--spec-id spec))
         (meta (and runtime (etaf-runtime-mounted-p runtime)
                    (etaf-runtime-meta runtime)))
         (app (plist-get meta :app))
         (app-pol (and app (etaf-ext-app-policy id app))))
    (and (etaf-ext-enabled-p id)
         (not (gethash id etaf-ext--suspended))
         (not (gethash runtime etaf-ext--pure-runtimes))
         (not (eq app-pol 'deny))
         (or (eq app-pol 'allow)
             (etaf-ext--spec-matches-runtime-p spec runtime)))))

;;;; Key-layer wiring & lazy command invocation

(defun etaf-ext--install-keys (_spec runtime)
  "Reconcile all extension key layers on RUNTIME through `etaf-ext-keys'."
  (when (fboundp 'etaf-ext--sync-keys-on-runtime)
    (etaf-ext--sync-keys-on-runtime runtime)))

(defun etaf-ext--cancel-ctx-timers (ctx)
  "Cancel any pending debounce timers on CTX."
  (when (timerp (etaf-ext-context-commit-timer ctx))
    (cancel-timer (etaf-ext-context-commit-timer ctx))
    (setf (etaf-ext-context-commit-timer ctx) nil))
  (when (timerp (etaf-ext-context-scroll-timer ctx))
    (cancel-timer (etaf-ext-context-scroll-timer ctx))
    (setf (etaf-ext-context-scroll-timer ctx) nil)))

;;;; Attach / Detach lifecycle

(defun etaf-ext--find-ctx (runtime id)
  "Return active `etaf-ext-context' for ID on RUNTIME, or nil."
  (cdr (assq id (gethash runtime etaf-ext--attachments))))

(defun etaf-ext-context (id &optional runtime)
  "Return active `etaf-ext-context' for extension ID on RUNTIME, or nil.
Does not attach ID when it is not currently active on RUNTIME.
RUNTIME defaults to the active or current-buffer Runtime."
  (let* ((rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer))))
         (ctx (and rt (etaf-runtime-mounted-p rt)
                   (etaf-ext--find-ctx rt id))))
    (and ctx (etaf-ext-context-active-p ctx) ctx)))

(defun etaf-ext--ensure-scroll-observer (runtime)
  "Ensure a shared buffer-local scroll hook is installed for RUNTIME."
  (when (and runtime (etaf-runtime-mounted-p runtime)
             (not (gethash runtime etaf-ext--scroll-observers)))
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (buffer-live-p buf)
        (let ((fn (lambda (_win _start)
                    (etaf-ext--on-flush runtime))))
          (puthash runtime fn etaf-ext--scroll-observers)
          (with-current-buffer buf
            (add-hook 'window-scroll-functions fn nil t)))))))

(defun etaf-ext--maybe-remove-scroll-observer (runtime)
  "Remove RUNTIME's scroll observer when no `:on-scroll' extension remains."
  (when-let* ((fn (gethash runtime etaf-ext--scroll-observers)))
    (let* ((alist (gethash runtime etaf-ext--attachments))
           (need (cl-some
                  (lambda (pair)
                    (let ((ctx (cdr pair)))
                      (and (etaf-ext-context-active-p ctx)
                           (etaf-ext--spec-on-scroll (etaf-ext-context-spec ctx)))))
                  alist)))
      (unless need
        (remhash runtime etaf-ext--scroll-observers)
        (let ((buf (and runtime (etaf-runtime-buffer runtime))))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (remove-hook 'window-scroll-functions fn t))))))))

(defun etaf-ext--should-auto-attach-p (spec runtime)
  "Return non-nil when SPEC should auto-attach to allowed RUNTIME."
  (let ((act (etaf-ext--spec-activation spec)))
    (cond
     ((eq act 'on-match) t)
     ((functionp act)
      (and (etaf-ext--safe-call (etaf-ext--spec-id spec) 'match act runtime) t))
     (t nil))))

(defun etaf-ext-attach (id &optional runtime)
  "Attach extension ID to mounted RUNTIME (default current buffer's Runtime).
Return the live `etaf-ext-context', or nil if suspended/failed."
  (let* ((spec (etaf-ext--get-spec id))
         (rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer)))))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (signal 'etaf-ext-error (list "No mounted ETAF Runtime available")))
    (etaf-ext--ensure-hooks)
    (or (let ((existing (etaf-ext--find-ctx rt id)))
          (and existing (etaf-ext-context-active-p existing) existing))
        (unless (gethash id etaf-ext--suspended)
          (let ((ctx (etaf-ext--ctx-make :id id :spec spec :runtime rt
                                         :active-p t
                                         :trigger etaf-ext--attach-trigger)))
            (puthash rt
                     (cons (cons id ctx)
                           (assq-delete-all id (gethash rt etaf-ext--attachments)))
                     etaf-ext--attachments)
            (etaf-ext--install-keys spec rt)
            (when (etaf-ext--spec-on-scroll spec)
              (etaf-ext--ensure-scroll-observer rt))
            (when-let* ((on-attach (etaf-ext--spec-on-attach spec)))
              (let ((res (etaf-ext--safe-call id 'attach on-attach ctx)))
                (when (and res (null (etaf-ext-context-state ctx)))
                  (setf (etaf-ext-context-state ctx) res))))
            (etaf-ext--update-indicator rt)
            (etaf-ext--emit-change 'attached id)
            (and (etaf-ext-context-active-p ctx) ctx))))))

(defun etaf-ext-detach (id &optional runtime)
  "Detach extension ID from RUNTIME, wiping all presentations, overlays and keys.
Return non-nil when an attachment or key layer was removed."
  (let* ((rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer))))
         (ctx (and rt (etaf-ext--find-ctx rt id)))
         (removed nil))
    (when ctx
      (etaf-ext--cancel-ctx-timers ctx)
      (when (etaf-ext-context-active-p ctx)
        (when-let* ((on-detach (etaf-ext--spec-on-detach (etaf-ext-context-spec ctx))))
          (condition-case err
              (funcall on-detach ctx)
            (error (etaf-ext--record-error id 'detach err))))
        (setf (etaf-ext-context-active-p ctx) nil))
      (etaf-ext-clear-activity ctx)
      (etaf-ext-hide-popup ctx)
      (let ((rest (assq-delete-all id (gethash rt etaf-ext--attachments))))
        (if rest
            (puthash rt rest etaf-ext--attachments)
          (remhash rt etaf-ext--attachments)))
      (etaf-ext--maybe-remove-scroll-observer rt)
      (setq removed t))
    (when (and rt (etaf-runtime-mounted-p rt))
      (when (> (etaf-runtime-clear-presentations rt id) 0) (setq removed t))
      (when (> (etaf-runtime-clear-overlay rt id) 0) (setq removed t))
      (when (> (etaf-runtime-clear-key-layer rt id) 0) (setq removed t))
      (etaf-ext--update-indicator rt))
    (when removed
      (etaf-ext--emit-change 'detached id))
    removed))

(defun etaf-ext--detach-from-all (id)
  "Detach extension ID from every live mounted Runtime."
  (dolist (rt (etaf-runtime-list))
    (ignore-errors (etaf-ext-detach id rt))))

(defun etaf-ext--sync-runtime (runtime)
  "Reconcile all registered extensions against mounted RUNTIME."
  (when (and runtime (etaf-runtime-mounted-p runtime))
    (dolist (id etaf-ext--order)
      (when-let* ((spec (gethash id etaf-ext--registry)))
        (if (etaf-ext--allowed-on-runtime-p spec runtime)
            (when (and (not (etaf-ext--find-ctx runtime id))
                       (etaf-ext--should-auto-attach-p spec runtime))
              (let ((etaf-ext--attach-trigger 'auto))
                (etaf-ext-attach id runtime)))
          (etaf-ext-detach id runtime))))
    (when (fboundp 'etaf-ext--sync-keys-on-runtime)
      (etaf-ext--sync-keys-on-runtime runtime))
    (etaf-ext--update-indicator runtime)))

(defun etaf-ext--sync-ext-on-all (id)
  "Reconcile extension ID across every currently mounted Runtime."
  (when-let* ((spec (gethash id etaf-ext--registry)))
    (dolist (rt (etaf-runtime-list))
      (if (etaf-ext--allowed-on-runtime-p spec rt)
          (when (and (not (etaf-ext--find-ctx rt id))
                     (etaf-ext--should-auto-attach-p spec rt))
            (let ((etaf-ext--attach-trigger 'auto))
              (etaf-ext-attach id rt)))
        (etaf-ext-detach id rt))
      (when (fboundp 'etaf-ext--sync-keys-on-runtime)
        (etaf-ext--sync-keys-on-runtime rt)))))

(defun etaf-ext-sync (&optional runtime)
  "Ensure lifecycle hooks are installed and reconcile extensions on RUNTIME.
When RUNTIME is nil, reconciles all live mounted Runtimes.  Does nothing when
`etaf-ext-mode' was explicitly disabled by the user."
  (unless etaf-ext--explicitly-disabled
    (etaf-ext--ensure-hooks)
    (if runtime
        (etaf-ext--sync-runtime runtime)
      (dolist (rt (etaf-runtime-list))
        (etaf-ext--sync-runtime rt)))
    t))

;;;; Public control commands

(defun etaf-ext-enable (id)
  "Globally enable extension ID and attach it to matching mounted Runtimes."
  (etaf-ext--get-spec id)
  (etaf-ext--ensure-hooks)
  (etaf-ext--policy-set-enabled id t)
  (etaf-ext--sync-ext-on-all id)
  (etaf-ext--emit-change 'enabled id)
  t)

(defun etaf-ext-disable (id)
  "Globally disable extension ID and cleanly detach it from all Runtimes."
  (etaf-ext--get-spec id)
  (etaf-ext--policy-set-enabled id nil)
  (etaf-ext--detach-from-all id)
  (etaf-ext--emit-change 'disabled id)
  t)

(defun etaf-ext-set-app-policy (id app-id policy)
  "Set per-app POLICY (`allow', `deny' or nil) for extension ID on APP-ID."
  (etaf-ext--get-spec id)
  (etaf-ext--policy-set-app id app-id policy)
  (etaf-ext--sync-ext-on-all id)
  (etaf-ext--emit-change 'policy id)
  policy)

(defun etaf-ext-unregister (id)
  "Detach and remove registered extension ID; return non-nil if present."
  (when (gethash id etaf-ext--registry)
    (etaf-ext--detach-from-all id)
    (remhash id etaf-ext--registry)
    (remhash id etaf-ext--errors)
    (remhash id etaf-ext--consecutive-errors)
    (remhash id etaf-ext--suspended)
    (etaf-ext--rebuild-order)
    (etaf-ext--emit-change 'unregistered id)
    t))

(defun etaf-ext-run-command (id cmd-id &optional runtime)
  "Execute extension ID's command CMD-ID on RUNTIME (lazy-attaching if needed)."
  (let* ((spec (etaf-ext--get-spec id))
         (cmd (assq cmd-id (etaf-ext--spec-commands spec)))
         (rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer)))))
    (unless cmd
      (signal 'etaf-ext-error (list "Unknown extension command" id cmd-id)))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (signal 'etaf-ext-error (list "No mounted ETAF Runtime in current buffer")))
    (when (gethash rt etaf-ext--pure-runtimes)
      (user-error "当前页面处于纯净模式，请先退出纯净模式"))
    (unless (etaf-ext-enabled-p id)
      (user-error "扩展 %s 已禁用" (etaf-ext--spec-name spec)))
    (when (gethash id etaf-ext--suspended)
      (user-error "扩展 %s 因连续报错已暂停，请在扩展管理中重置" (etaf-ext--spec-name spec)))
    (let* ((etaf-ext--attach-trigger 'command)
           (ctx (etaf-ext-attach id rt)))
      (when ctx
        (etaf-ext--safe-call id cmd-id (plist-get (cdr cmd) :fn) ctx)))))

(defun etaf-ext-open-popup (id &optional runtime)
  "Open extension ID's declared `:popup' panel for RUNTIME."
  (let* ((spec (etaf-ext--get-spec id))
         (popup-fn (etaf-ext--spec-popup spec))
         (rt (or runtime (etaf-current-runtime)
                 (etaf-runtime-for-buffer (current-buffer)))))
    (unless popup-fn
      (signal 'etaf-ext-error (list "Extension has no :popup handler" id)))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (signal 'etaf-ext-error (list "No mounted ETAF Runtime available")))
    (let* ((etaf-ext--attach-trigger 'popup)
           (ctx (etaf-ext-attach id rt)))
      (when ctx
        (let ((view (etaf-ext--safe-call id 'popup popup-fn ctx)))
          (when view
            (etaf-ext-show-popup ctx view)))))))

(defun etaf-ext-active-for-runtime (&optional runtime)
  "Return list of active extension IDs currently attached to RUNTIME."
  (let ((rt (or runtime (etaf-current-runtime)
                (etaf-runtime-for-buffer (current-buffer)))))
    (when (and rt (etaf-runtime-mounted-p rt))
      (cl-loop for (id . ctx) in (gethash rt etaf-ext--attachments)
               when (etaf-ext-context-active-p ctx)
               collect id))))

(defun etaf-ext-active-runtimes (id)
  "Return list of mounted Runtimes where extension ID is currently attached."
  (etaf-ext--get-spec id)
  (cl-loop for rt in (etaf-runtime-list)
           for ctx = (etaf-ext--find-ctx rt id)
           when (and ctx (etaf-ext-context-active-p ctx))
           collect rt))

(defun etaf-ext-pure-mode-p (&optional runtime)
  "Return non-nil when RUNTIME is currently in extension pure mode."
  (let ((rt (or runtime (etaf-current-runtime)
                (etaf-runtime-for-buffer (current-buffer)))))
    (and rt (gethash rt etaf-ext--pure-runtimes) t)))

(defun etaf-ext-pure-mode-toggle (&optional runtime)
  "Toggle extension pure mode on RUNTIME (hiding/restoring all extensions)."
  (interactive)
  (let ((rt (or runtime (etaf-current-runtime)
                (etaf-runtime-for-buffer (current-buffer)))))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (user-error "当前 buffer 没有挂载的 ETAF 页面"))
    (if (gethash rt etaf-ext--pure-runtimes)
        (progn
          (remhash rt etaf-ext--pure-runtimes)
          (etaf-ext--sync-runtime rt)
          (etaf-ext--emit-change 'pure-mode-off nil)
          nil)
      (puthash rt t etaf-ext--pure-runtimes)
      (dolist (id (copy-sequence etaf-ext--order))
        (ignore-errors (etaf-ext-detach id rt)))
      (when (fboundp 'etaf-ext--clear-dispatch-key-layer)
        (etaf-ext--clear-dispatch-key-layer rt))
      (etaf-ext--update-indicator rt)
      (etaf-ext--emit-change 'pure-mode-on nil)
      t)))

;;;; ETAF Runtime lifecycle hooks

(defun etaf-ext--on-mount (runtime)
  "Attach matching extensions when RUNTIME finishes initial mount."
  (when etaf-ext--order
    (etaf-ext--sync-runtime runtime)))

(defun etaf-ext--schedule-ctx-hook (ctx slot phase fn)
  "Invoke or debounce FN for CTX in timer SLOT (`commit' or `scroll')."
  (let* ((spec (etaf-ext-context-spec ctx))
         (delay (etaf-ext--spec-debounce spec))
         (id (etaf-ext-context-id ctx))
         (rt (etaf-ext-context-runtime ctx))
         (run-fn
          (lambda ()
            (if (eq slot 'commit)
                (setf (etaf-ext-context-commit-timer ctx) nil)
              (setf (etaf-ext-context-scroll-timer ctx) nil))
            (when (and (etaf-ext-context-active-p ctx)
                       (etaf-runtime-mounted-p rt)
                       (not (gethash id etaf-ext--suspended)))
              (etaf-ext--safe-call id phase fn ctx)
              (etaf-ext--update-indicator rt)))))
    (if (or noninteractive (<= delay 0))
        (funcall run-fn)
      (let ((prev (if (eq slot 'commit)
                      (etaf-ext-context-commit-timer ctx)
                    (etaf-ext-context-scroll-timer ctx))))
        (when (timerp prev) (cancel-timer prev))
        (let ((timer (run-with-timer delay nil run-fn)))
          (if (eq slot 'commit)
              (setf (etaf-ext-context-commit-timer ctx) timer)
            (setf (etaf-ext-context-scroll-timer ctx) timer)))))))

(defun etaf-ext--on-commit (runtime)
  "Dispatch application commits to attached extensions on RUNTIME."
  (remhash runtime etaf-ext--tree-cache)
  (when-let* ((alist (gethash runtime etaf-ext--attachments)))
    (dolist (pair (copy-sequence alist))
      (let ((ctx (cdr pair)))
        (when (etaf-ext-context-active-p ctx)
          (when-let* ((fn (etaf-ext--spec-on-commit (etaf-ext-context-spec ctx))))
            (etaf-ext--schedule-ctx-hook ctx 'commit 'commit fn))))))
  ;; Re-evaluate conditional auto-activation extensions after in-place navigation.
  (when (and runtime (etaf-runtime-mounted-p runtime))
    (dolist (id etaf-ext--order)
      (when-let* ((spec (gethash id etaf-ext--registry)))
        (when (and (functionp (etaf-ext--spec-activation spec))
                   (not (etaf-ext--find-ctx runtime id))
                   (etaf-ext--allowed-on-runtime-p spec runtime)
                   (etaf-ext--should-auto-attach-p spec runtime))
          (let ((etaf-ext--attach-trigger 'auto))
            (etaf-ext-attach id runtime)))))))

(defun etaf-ext--on-flush (runtime)
  "Dispatch non-presentation flushes (scroll/refit) to attached extensions."
  (when-let* ((alist (gethash runtime etaf-ext--attachments)))
    (dolist (pair (copy-sequence alist))
      (let ((ctx (cdr pair)))
        (when (etaf-ext-context-active-p ctx)
          (when-let* ((fn (etaf-ext--spec-on-scroll (etaf-ext-context-spec ctx))))
            (etaf-ext--schedule-ctx-hook ctx 'scroll 'scroll fn)))))))

(defun etaf-ext--on-meta (runtime meta)
  "Re-match extensions and dispatch `:on-meta' when RUNTIME metadata changes."
  (etaf-ext--sync-runtime runtime)
  (when-let* ((alist (gethash runtime etaf-ext--attachments)))
    (dolist (pair (copy-sequence alist))
      (let ((ctx (cdr pair)))
        (when (etaf-ext-context-active-p ctx)
          (when-let* ((fn (etaf-ext--spec-on-meta (etaf-ext-context-spec ctx))))
            (etaf-ext--safe-call (car pair) 'meta fn ctx meta)
            (etaf-ext--update-indicator runtime)))))))

(defun etaf-ext--on-focus (runtime prev-id next-id)
  "Dispatch `:on-focus' when Host focus moves on RUNTIME."
  (when-let* ((alist (gethash runtime etaf-ext--attachments)))
    (dolist (pair (copy-sequence alist))
      (let ((ctx (cdr pair)))
        (when (etaf-ext-context-active-p ctx)
          (when-let* ((fn (etaf-ext--spec-on-focus (etaf-ext-context-spec ctx))))
            (etaf-ext--safe-call (car pair) 'focus fn ctx prev-id next-id)))))))

(defun etaf-ext--on-unmount (runtime)
  "Cleanly detach all extensions when RUNTIME begins unmounting."
  (remhash runtime etaf-ext--tree-cache)
  (remhash runtime etaf-ext--pure-runtimes)
  (when-let* ((sfn (gethash runtime etaf-ext--scroll-observers)))
    (remhash runtime etaf-ext--scroll-observers)
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (remove-hook 'window-scroll-functions sfn t)))))
  (when-let* ((alist (copy-sequence (gethash runtime etaf-ext--attachments))))
    (dolist (pair alist)
      (let* ((id (car pair))
             (ctx (cdr pair)))
        (etaf-ext--cancel-ctx-timers ctx)
        (when (etaf-ext-context-active-p ctx)
          (when-let* ((fn (etaf-ext--spec-on-detach (etaf-ext-context-spec ctx))))
            (condition-case err
                (funcall fn ctx)
              (error (etaf-ext--record-error id 'detach err))))
          (setf (etaf-ext-context-active-p ctx) nil))
        (etaf-ext-clear-activity ctx)
      (etaf-ext-hide-popup ctx)))
    (remhash runtime etaf-ext--attachments)))

(defun etaf-ext--dispatch-theme-change ()
  "Notify all attached extensions that Emacs's active theme changed."
  (setq etaf-ext--theme-timer nil)
  (dolist (rt (etaf-runtime-list))
    (when-let* ((alist (copy-sequence (gethash rt etaf-ext--attachments))))
      (dolist (pair alist)
        (let ((ctx (cdr pair)))
          (when (etaf-ext-context-active-p ctx)
            (when-let* ((fn (etaf-ext--spec-on-theme (etaf-ext-context-spec ctx))))
              (etaf-ext--safe-call (car pair) 'theme fn ctx))))))))

(defun etaf-ext--on-theme-enabled (&rest _ignored)
  "Schedule coalesced theme change notification for attached extensions."
  (when (timerp etaf-ext--theme-timer)
    (cancel-timer etaf-ext--theme-timer))
  (if noninteractive
      (etaf-ext--dispatch-theme-change)
    (setq etaf-ext--theme-timer
          (run-with-timer 0.05 nil #'etaf-ext--dispatch-theme-change))))

(defun etaf-ext--ensure-hooks ()
  "Install `etaf-ext' lifecycle hooks into ETAF once."
  (unless etaf-ext--hooks-installed
    (add-hook 'etaf-runtime-mount-functions #'etaf-ext--on-mount)
    (add-hook 'etaf-runtime-after-commit-functions #'etaf-ext--on-commit)
    (add-hook 'etaf-runtime-after-flush-functions #'etaf-ext--on-flush)
    (add-hook 'etaf-runtime-meta-change-functions #'etaf-ext--on-meta)
    (add-hook 'etaf-runtime-focus-change-functions #'etaf-ext--on-focus)
    (add-hook 'etaf-runtime-unmount-functions #'etaf-ext--on-unmount)
    (when (boundp 'enable-theme-functions)
      (add-hook 'enable-theme-functions #'etaf-ext--on-theme-enabled))
    (when (boundp 'disable-theme-functions)
      (add-hook 'disable-theme-functions #'etaf-ext--on-theme-enabled))
    (setq etaf-ext--hooks-installed t)))

(defun etaf-ext--remove-hooks ()
  "Uninstall `etaf-ext' lifecycle hooks from ETAF."
  (when etaf-ext--hooks-installed
    (remove-hook 'etaf-runtime-mount-functions #'etaf-ext--on-mount)
    (remove-hook 'etaf-runtime-after-commit-functions #'etaf-ext--on-commit)
    (remove-hook 'etaf-runtime-after-flush-functions #'etaf-ext--on-flush)
    (remove-hook 'etaf-runtime-meta-change-functions #'etaf-ext--on-meta)
    (remove-hook 'etaf-runtime-focus-change-functions #'etaf-ext--on-focus)
    (remove-hook 'etaf-runtime-unmount-functions #'etaf-ext--on-unmount)
    (when (boundp 'enable-theme-functions)
      (remove-hook 'enable-theme-functions #'etaf-ext--on-theme-enabled))
    (when (boundp 'disable-theme-functions)
      (remove-hook 'disable-theme-functions #'etaf-ext--on-theme-enabled))
    (when (timerp etaf-ext--theme-timer)
      (cancel-timer etaf-ext--theme-timer)
      (setq etaf-ext--theme-timer nil))
    (setq etaf-ext--hooks-installed nil)))

(defun etaf-ext--on-registry-change (event ext-id)
  "Auto-sync newly registered EXT-ID while `etaf-ext-mode' is active."
  (when (and (eq event 'registered)
             ext-id
             (bound-and-true-p etaf-ext-mode))
    (etaf-ext--sync-ext-on-all ext-id)))

(add-hook 'etaf-ext-change-functions #'etaf-ext--on-registry-change)

;;;###autoload
(define-minor-mode etaf-ext-mode
  "Global minor mode enabling the universal ETAF extension engine."
  :global t
  :group 'etaf-ext
  (if etaf-ext-mode
      (progn
        (setq etaf-ext--explicitly-disabled nil)
        (etaf-ext--ensure-hooks)
        (dolist (rt (etaf-runtime-list))
          (etaf-ext--sync-runtime rt)))
    (setq etaf-ext--explicitly-disabled t)
    (dolist (rt (etaf-runtime-list))
      (when (fboundp 'etaf-ext--clear-dispatch-key-layer)
        (etaf-ext--clear-dispatch-key-layer rt))
      (dolist (id (copy-sequence etaf-ext--order))
        (ignore-errors (etaf-ext-detach id rt))))
    (etaf-ext--remove-hooks)))

(provide 'etaf-ext-runtime)
;;; etaf-ext-runtime.el ends here
