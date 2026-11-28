;;; etaf-ext.el --- Universal extension engine for mounted ETAF Views -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.3
;; Package-Requires: ((emacs "29.1") (etaf "0.3.10") (etaf-ui "0.3.6") (etaf-posframe "0.3.0"))
;; Keywords: extensions, ui, convenience
;; URL: https://github.com/emacs-taf/etaf-ext

;;; Commentary:

;; Universal Chrome/VS Code-style extension engine and manager for any mounted
;; ETAF View.  `etaf-ext' contains only the extension engine, permission-checked
;; context runtime, isolated SQLite storage and Extension Manager UI
;; (`etaf-ext-manage'); concrete extensions live in their own independent
;; packages (such as `etaf-hints', `etaf-highlight', `etaf-translate',
;; `etaf-export' or user config scripts) and register declaratively via
;; `etaf-ext-define'.
;;
;; Public API
;;
;; Load this package with (require 'etaf-ext) after adding this repository,
;; ETAF, ETAF UI, ETAF Posframe, Ebox and ECSS roots to `load-path'.
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; docs/manual.md contains workflows.
;;
;; Error: etaf-ext-error
;; Invalid `etaf-ext' configuration, manifest or lifecycle operation.
;;
;; Error: etaf-ext-permission-error
;; Raised when an extension invokes a context primitive whose capability was
;; not declared in its manifest `:permissions'; parent is `etaf-ext-error'.
;;
;; Variable: etaf-ext-known-permissions
;; List of supported permission symbols an extension manifest may request.
;;
;; Variable: etaf-ext-storage-file
;; SQLite WAL file path storing extension policies and isolated KV namespaces,
;; or nil to keep storage in memory only.
;;
;; Variable: etaf-ext-circuit-breaker-threshold
;; Consecutive callback errors before an extension is automatically suspended.
;;
;; Variable: etaf-ext-max-error-log
;; Maximum recent error entries retained per extension.
;;
;; Variable: etaf-ext-use-posframe
;; When non-nil, render extension popups via `etaf-posframe' on graphic frames.
;;
;; Variable: etaf-ext-key-prefix
;; Unified framework prefix sequence inside mounted ETAF Runtimes opening
;; `etaf-ext-dispatch' (default "C-c C-e", or nil to disable).
;;
;; Variable: etaf-ext-keybinding-policy
;; Conflict and direct-binding policy (`safe', `prefix-only' or `manual').
;;
;; Variable: etaf-ext-notify-function
;; Optional notification sink called with `(TITLE &rest ARGS)' by `etaf-ext-notify'.
;;
;; Hook: etaf-ext-change-functions
;; Abnormal hook run with `(EVENT EXT-ID)' whenever extension registry,
;; enablement, pure mode or error state changes.
;;
;; Variable: etaf-ext-mode
;; Non-nil when the global ETAF extension engine minor mode is active.
;;
;; Function: etaf-ext-mode (&optional arg)
;;;###autoload (autoload 'etaf-ext-mode "etaf-ext" nil t)
;; Global minor mode enabling automatic extension attachment, lifecycle hooks
;; and key-layer synchronization across all mounted ETAF Runtimes.
;;
;; Function: etaf-ext-register (id &rest spec)
;;;###autoload (autoload 'etaf-ext-register "etaf-ext" nil nil)
;; Register or update extension ID with keyword manifest plist SPEC.
;; Validates permissions, matching rules, commands, priority and callbacks.
;;
;; Macro: etaf-ext-define (id &rest spec)
;;;###autoload (autoload 'etaf-ext-define "etaf-ext" nil nil)
;; Declarative wrapper around `etaf-ext-register' quoting extension symbol ID.
;;
;; Function: etaf-ext-unregister (id)
;;;###autoload (autoload 'etaf-ext-unregister "etaf-ext" nil nil)
;; Cleanly detach extension ID from all live Runtimes and remove its registration.
;;
;; Function: etaf-ext-list ()
;;;###autoload (autoload 'etaf-ext-list "etaf-ext" nil nil)
;; Return list of registered extension IDs ordered by ascending priority.
;;
;; Function: etaf-ext-info (id)
;;;###autoload (autoload 'etaf-ext-info "etaf-ext" nil nil)
;; Return a detached read-only manifest plist for extension ID, or nil.
;;
;; Function: etaf-ext-match-p (id runtime)
;;;###autoload (autoload 'etaf-ext-match-p "etaf-ext" nil nil)
;; Return non-nil when registered extension ID's `:matches' matches RUNTIME.
;;
;; Function: etaf-ext-enable (id)
;;;###autoload (autoload 'etaf-ext-enable "etaf-ext" nil nil)
;; Globally enable extension ID (persisted) and attach to matching Runtimes.
;;
;; Function: etaf-ext-disable (id)
;;;###autoload (autoload 'etaf-ext-disable "etaf-ext" nil nil)
;; Globally disable extension ID (persisted) and cleanly detach from all Runtimes.
;;
;; Function: etaf-ext-enabled-p (id)
;;;###autoload (autoload 'etaf-ext-enabled-p "etaf-ext" nil nil)
;; Return non-nil when extension ID is globally enabled.
;;
;; Function: etaf-ext-set-app-policy (id app-id policy)
;;;###autoload (autoload 'etaf-ext-set-app-policy "etaf-ext" nil nil)
;; Persist per-app POLICY (`allow', `deny' or nil) for extension ID on APP-ID
;; and reconcile live Runtimes immediately.
;;
;; Function: etaf-ext-app-policy (id app-id)
;;;###autoload (autoload 'etaf-ext-app-policy "etaf-ext" nil nil)
;; Return persisted per-app policy (`allow', `deny' or nil) for ID and APP-ID.
;;
;; Function: etaf-ext-app-policies (id)
;;;###autoload (autoload 'etaf-ext-app-policies "etaf-ext" nil nil)
;; Return sorted alist of `(APP-ID . POLICY)' rules configured for extension ID.
;;
;; Function: etaf-ext-attach (id &optional runtime)
;;;###autoload (autoload 'etaf-ext-attach "etaf-ext" nil nil)
;; Attach extension ID to mounted RUNTIME and return its live `etaf-ext-context'.
;;
;; Function: etaf-ext-detach (id &optional runtime)
;;;###autoload (autoload 'etaf-ext-detach "etaf-ext" nil nil)
;; Detach extension ID from RUNTIME, wiping presentations, overlays, popups and keys.
;;
;; Function: etaf-ext-context (id &optional runtime)
;;;###autoload (autoload 'etaf-ext-context "etaf-ext" nil nil)
;; Return active `etaf-ext-context' for extension ID on RUNTIME without attaching,
;; or nil when ID is not currently attached to RUNTIME.
;;
;; Function: etaf-ext-sync (&optional runtime)
;;;###autoload (autoload 'etaf-ext-sync "etaf-ext" nil nil)
;; Ensure lifecycle hooks are installed (unless `etaf-ext-mode' was explicitly
;; disabled) and reconcile matching extensions on RUNTIME or all mounted Runtimes.
;;
;; Function: etaf-ext-run-command (id cmd-id &optional runtime)
;;;###autoload (autoload 'etaf-ext-run-command "etaf-ext" nil nil)
;; Execute extension ID's declared command CMD-ID on RUNTIME, lazy-attaching first.
;;
;; Function: etaf-ext-open-popup (id &optional runtime)
;;;###autoload (autoload 'etaf-ext-open-popup "etaf-ext" nil nil)
;; Open extension ID's declared `:popup' panel for RUNTIME.
;;
;; Function: etaf-ext-active-for-runtime (&optional runtime)
;;;###autoload (autoload 'etaf-ext-active-for-runtime "etaf-ext" nil nil)
;; Return list of extension IDs currently attached and active on RUNTIME.
;;
;; Function: etaf-ext-active-runtimes (id)
;;;###autoload (autoload 'etaf-ext-active-runtimes "etaf-ext" nil nil)
;; Return list of mounted Runtimes where extension ID is currently attached.
;;
;; Function: etaf-ext-pure-mode-p (&optional runtime)
;;;###autoload (autoload 'etaf-ext-pure-mode-p "etaf-ext" nil nil)
;; Return non-nil when RUNTIME is currently in extension pure mode.
;;
;; Function: etaf-ext-pure-mode-toggle (&optional runtime)
;;;###autoload (autoload 'etaf-ext-pure-mode-toggle "etaf-ext" nil t)
;; Interactive command toggling pure mode on RUNTIME to hide or restore all extensions.
;;
;; Function: etaf-ext-errors (id)
;;;###autoload (autoload 'etaf-ext-errors "etaf-ext" nil nil)
;; Return detached list of recent error plists recorded for extension ID.
;;
;; Function: etaf-ext-clear-errors (id)
;;;###autoload (autoload 'etaf-ext-clear-errors "etaf-ext" nil nil)
;; Clear recorded error entries and consecutive failure count for extension ID.
;;
;; Function: etaf-ext-suspended-p (id)
;;;###autoload (autoload 'etaf-ext-suspended-p "etaf-ext" nil nil)
;; Return non-nil when extension ID is currently suspended by the circuit breaker.
;;
;; Function: etaf-ext-reset (id)
;;;###autoload (autoload 'etaf-ext-reset "etaf-ext" nil nil)
;; Clear circuit-breaker suspension and errors for ID, re-attaching matching Runtimes.
;;
;; Function: etaf-ext-theme (&optional frame)
;;;###autoload (autoload 'etaf-ext-theme "etaf-ext" nil nil)
;; Return a theme-derived palette plist (`:ext-*' and `:ui-*' tokens) computed
;; from FRAME's active Emacs theme so extensions adapt cleanly to light and dark modes.
;;
;; Function: etaf-ext-ctx-id (ctx)
;;;###autoload (autoload 'etaf-ext-ctx-id "etaf-ext" nil nil)
;; Return extension ID symbol of live context CTX.
;;
;; Function: etaf-ext-ctx-runtime (ctx)
;;;###autoload (autoload 'etaf-ext-ctx-runtime "etaf-ext" nil nil)
;; Return mounted `etaf-runtime' associated with context CTX.
;;
;; Function: etaf-ext-ctx-state (ctx)
;;;###autoload (autoload 'etaf-ext-ctx-state "etaf-ext" nil nil)
;; Return per-Runtime session state stored on context CTX.
;;
;; Function: etaf-ext-ctx-set-state (ctx value)
;;;###autoload (autoload 'etaf-ext-ctx-set-state "etaf-ext" nil nil)
;; Store per-Runtime session state VALUE on context CTX and return VALUE.
;;
;; Function: etaf-ext-ctx-meta (ctx)
;;;###autoload (autoload 'etaf-ext-ctx-meta "etaf-ext" nil nil)
;; Return detached Runtime metadata plist (`:app', `:kind', `:uri', `:title') for CTX.
;;
;; Function: etaf-ext-ctx-trigger (ctx)
;;;###autoload (autoload 'etaf-ext-ctx-trigger "etaf-ext" nil nil)
;; Return attachment trigger symbol (`auto', `manual', `command' or `popup') for CTX.
;;
;; Function: etaf-ext-refresh-badge (ctx)
;;;###autoload (autoload 'etaf-ext-refresh-badge "etaf-ext" nil nil)
;; Refresh the compact mode-line extension badge for CTX's Runtime.
;;
;; Function: etaf-ext-set-activity (ctx plist)
;;;###autoload (autoload 'etaf-ext-set-activity "etaf-ext" nil nil)
;; Publish a live ETAF activity owned by CTX from PLIST.
;; Automatically binds `:owner-runtime' and removes the activity when CTX
;; detaches, disables, trips the circuit breaker or enters pure mode.
;;
;; Function: etaf-ext-clear-activity (ctx)
;;;###autoload (autoload 'etaf-ext-clear-activity "etaf-ext" nil nil)
;; Remove any live ETAF activity currently owned by CTX.
;;
;; Function: etaf-ext-tree (ctx)
;;;###autoload (autoload 'etaf-ext-tree "etaf-ext" nil nil)
;; Return read-only Host tree for CTX's Runtime (shared within commit revision).
;; Requires `read-tree' permission.
;;
;; Function: etaf-ext-geometries (ctx host-ids)
;;;###autoload (autoload 'etaf-ext-geometries "etaf-ext" nil nil)
;; Return live geometry and visibility alist for HOST-IDS in CTX's Runtime.
;; Requires `read-tree' permission.
;;
;; Function: etaf-ext-host-at-point (ctx &optional position)
;;;###autoload (autoload 'etaf-ext-host-at-point "etaf-ext" nil nil)
;; Return Host ID lineage at POSITION (default point) in CTX's Runtime.
;; Requires `read-tree' permission.
;;
;; Function: etaf-ext-host-text-at-point (ctx &optional position)
;;;###autoload (autoload 'etaf-ext-host-text-at-point "etaf-ext" nil nil)
;; Return text Host character offset and active region plist at POSITION.
;; Requires `read-tree' permission.
;;
;; Function: etaf-ext-inspect-host (ctx host-id)
;;;###autoload (autoload 'etaf-ext-inspect-host "etaf-ext" nil nil)
;; Return detailed box-model, presentations and ECSS inspection plist for HOST-ID.
;; Requires `inspect' permission.
;;
;; Function: etaf-ext-commit-summary (ctx)
;;;###autoload (autoload 'etaf-ext-commit-summary "etaf-ext" nil nil)
;; Return latest commit summary plist for CTX's Runtime.
;; Requires `inspect' permission.
;;
;; Function: etaf-ext-decorate (ctx updates)
;;;###autoload (autoload 'etaf-ext-decorate "etaf-ext" nil nil)
;; Apply additive text-span or face decoration UPDATES owned by CTX.
;; Requires `decorate' permission.
;;
;; Function: etaf-ext-companion (ctx updates)
;;;###autoload (autoload 'etaf-ext-companion "etaf-ext" nil nil)
;; Apply coexisting companion View UPDATES (`companion-after'/'beside'/'inside') owned by CTX.
;; Requires `companion' permission.
;;
;; Function: etaf-ext-override (ctx updates)
;;;###autoload (autoload 'etaf-ext-override "etaf-ext" nil nil)
;; Apply priority-stacked Host override UPDATES owned by CTX.
;; Requires `override' permission.
;;
;; Function: etaf-ext-present (ctx updates)
;;;###autoload (autoload 'etaf-ext-present "etaf-ext" nil nil)
;; Apply mixed Host presentation UPDATES (`decorate', `companion-*', `override'
;; or nil removals) atomically in one flush for CTX, enforcing per-entry permissions.
;;
;; Function: etaf-ext-clear-presentations (ctx)
;;;###autoload (autoload 'etaf-ext-clear-presentations "etaf-ext" nil nil)
;; Clear all Host presentations owned by CTX on its Runtime.
;;
;; Function: etaf-ext-set-overlay (ctx view &optional origin)
;;;###autoload (autoload 'etaf-ext-set-overlay "etaf-ext" nil nil)
;; Set or update the named root-layer overlay VIEW owned by CTX.
;; Requires `overlay' permission.
;;
;; Function: etaf-ext-clear-overlay (ctx)
;;;###autoload (autoload 'etaf-ext-clear-overlay "etaf-ext" nil nil)
;; Remove the root-layer overlay owned by CTX.
;;
;; Function: etaf-ext-press (ctx host-id)
;;;###autoload (autoload 'etaf-ext-press "etaf-ext" nil nil)
;; Trigger semantic press event on committed HOST-ID in CTX's Runtime.
;; Requires `interact' permission.
;;
;; Function: etaf-ext-focus (ctx host-id)
;;;###autoload (autoload 'etaf-ext-focus "etaf-ext" nil nil)
;; Move logical keyboard focus to committed HOST-ID in CTX's Runtime.
;; Requires `interact' permission.
;;
;; Function: etaf-ext-scroll-to (ctx host-id &optional align)
;;;###autoload (autoload 'etaf-ext-scroll-to "etaf-ext" nil nil)
;; Scroll CTX's Runtime so committed HOST-ID is visible (`nearest', `top' or `center').
;; Requires `interact' permission.
;;
;; Function: etaf-ext-storage-get (ctx key &optional default)
;;;###autoload (autoload 'etaf-ext-storage-get "etaf-ext" nil nil)
;; Read persisted KEY from CTX's isolated storage namespace, returning DEFAULT if absent.
;; Requires `storage' permission.
;;
;; Function: etaf-ext-storage-set (ctx key value)
;;;###autoload (autoload 'etaf-ext-storage-set "etaf-ext" nil nil)
;; Persist VALUE under KEY in CTX's isolated storage namespace.
;; Requires `storage' permission.
;;
;; Function: etaf-ext-storage-delete (ctx key)
;;;###autoload (autoload 'etaf-ext-storage-delete "etaf-ext" nil nil)
;; Delete KEY from CTX's isolated storage namespace.
;; Requires `storage' permission.
;;
;; Function: etaf-ext-storage-keys (ctx)
;;;###autoload (autoload 'etaf-ext-storage-keys "etaf-ext" nil nil)
;; Return sorted list of stored key strings in CTX's isolated storage namespace.
;; Requires `storage' permission.
;;
;; Function: etaf-ext-show-popup (ctx view &rest options)
;;;###autoload (autoload 'etaf-ext-show-popup "etaf-ext" nil nil)
;; Show floating popup VIEW owned by CTX via `etaf-posframe' or a native side window.
;; Requires `popup' permission.
;;
;; Function: etaf-ext-hide-popup (ctx)
;;;###autoload (autoload 'etaf-ext-hide-popup "etaf-ext" nil nil)
;; Hide any floating popup currently owned by CTX.
;;
;; Function: etaf-ext-notify (ctx title &rest args)
;;;###autoload (autoload 'etaf-ext-notify "etaf-ext" nil nil)
;; Send user notification TITLE from CTX (via `etaf-ext-notify-function' or `message').
;; Requires `notify' permission.
;;
;; Function: etaf-ext-set-key (id cmd-id key)
;;;###autoload (autoload 'etaf-ext-set-key "etaf-ext" nil nil)
;; Persist user direct key override KEY (`kbd' string, vector, `:unbound' or nil)
;; for extension ID's command CMD-ID and reconcile all live ETAF Runtimes.
;;
;; Function: etaf-ext-reset-key (id cmd-id)
;;;###autoload (autoload 'etaf-ext-reset-key "etaf-ext" nil nil)
;; Clear any persisted user key override for extension ID's command CMD-ID.
;;
;; Function: etaf-ext-key-override (id cmd-id)
;;;###autoload (autoload 'etaf-ext-key-override "etaf-ext" nil nil)
;; Return persisted key override (string, `:unbound' or nil) for ID and CMD-ID.
;;
;; Function: etaf-ext-check-key-conflict (key &optional runtime exclude-ext exclude-cmd)
;;;###autoload (autoload 'etaf-ext-check-key-conflict "etaf-ext" nil nil)
;; Check whether KEY conflicts with framework reserved keys, RUNTIME app keys,
;; `global-map', active minor modes or sibling extensions; return nil or a
;; conflict plist `(:kind :key :owner :reason)'.
;;
;; Function: etaf-ext-command-bindings (&optional runtime ext-id)
;;;###autoload (autoload 'etaf-ext-command-bindings "etaf-ext" nil nil)
;; Return resolved command keybinding status plists for RUNTIME and optional EXT-ID.
;;
;; Function: etaf-ext-dispatch (&optional runtime)
;;;###autoload (autoload 'etaf-ext-dispatch "etaf-ext" nil t)
;; Open the unified two-step ETAF extension key dispatcher for RUNTIME.
;;
;; Function: etaf-ext-command-palette (&optional runtime)
;;;###autoload (autoload 'etaf-ext-command-palette "etaf-ext" nil t)
;; Fuzzy-search and execute any available extension command for RUNTIME.
;;
;; Function: etaf-ext-manage (&optional target-runtime)
;;;###autoload (autoload 'etaf-ext-manage "etaf-ext" nil t)
;; Open the interactive Chrome-style ETAF Extension Manager as a full buffer.
;;
;; Function: etaf-ext-manage-popup (&optional target-runtime)
;;;###autoload (autoload 'etaf-ext-manage-popup "etaf-ext" nil t)
;; Toggle the interactive ETAF Extension Manager in a centered floating posframe,
;; falling back to `etaf-ext-manage' on non-graphic frames or without posframe.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-ext")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-ext.el" dir))
                                (file-exists-p (expand-file-name "etaf-ext.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-ext-core)
(require 'etaf-ext-store)
(require 'etaf-ext-runtime)
(require 'etaf-ext-keys)
(require 'etaf-ext-ui)

(provide 'etaf-ext)
;;; etaf-ext.el ends here
