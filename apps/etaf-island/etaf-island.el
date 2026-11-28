;;; etaf-island.el --- Pure-protocol Dynamic Island shell for Emacs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.2") (etaf-ui "0.3.4"))
;; Keywords: convenience, frames, ui
;; URL: https://github.com/emacs-taf/etaf-island

;;; Commentary:

;; Public API
;;
;; ETAF Island is a Dynamic Island system shell consuming ETAF's cross-application
;; live activity (`etaf-activity-*') and notification (`etaf-notify*') protocol.
;; Applications publish structured status, progress, audio meters and actions to
;; `etaf' without knowing about `etaf-island', and `etaf-island' presents them
;; as a headerless floating top-center capsule (`etaf-posframe') or standalone
;; buffer (`etaf-island-open') preserving Emacs's mode-line.
;;
;; Load this package with (require 'etaf-island) after adding this repository
;; root and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  Only the
;; interfaces listed below are supported for use by other packages.
;;
;; Error: etaf-island-error
;; Signals an invalid ETAF Island operation, session, mode, tab or missing host.
;;
;; Variable: etaf-island-auto-hide-idle
;; When non-nil, hide the floating capsule when no active activity or unread
;; notification is present, and re-open automatically when an alert arrives.
;;
;; Variable: etaf-island-sense-compilation
;; When non-nil and `etaf-island-mode' is enabled, publish active Emacs
;; compilations as live `task' activities and completion results via `etaf-notify'.
;;
;; Variable: etaf-island-sense-org-clock
;; When non-nil and `etaf-island-mode' is enabled, publish the active `org-clock'
;; task as a live `timer' activity.
;;
;; Function: etaf-island-create (&key (appearance 'auto) (mode 'compact) (tab 'activities))
;;;###autoload (autoload 'etaf-island-create "etaf-island" nil nil)
;; Create and return a new headless ETAF Island shell session.
;; APPEARANCE is `auto', `dark' or `light'; MODE is `compact', `expanded' or
;; `alert'; TAB is `activities', `events' or `quick'.
;;
;; Function: etaf-island-state (session)
;;;###autoload (autoload 'etaf-island-state "etaf-island" nil nil)
;; Return a plain read-only snapshot plist of SESSION combined with current
;; `etaf-activity-list' and `etaf-notify-list'.
;;
;; Function: etaf-island-set-mode (session mode)
;;;###autoload (autoload 'etaf-island-set-mode "etaf-island" nil nil)
;; Switch SESSION's display mode to MODE (`compact', `expanded' or `alert').
;;
;; Function: etaf-island-select-tab (session tab)
;;;###autoload (autoload 'etaf-island-select-tab "etaf-island" nil nil)
;; Select expanded TAB (`activities', `events' or `quick') in SESSION.
;;
;; Function: etaf-island-reset-position (session)
;;;###autoload (autoload 'etaf-island-reset-position "etaf-island" nil nil)
;; Clear SESSION's dragged position override so the floating island re-centers.
;;
;; Function: etaf-island-toggle-appearance (session)
;;;###autoload (autoload 'etaf-island-toggle-appearance "etaf-island" nil nil)
;; Cycle SESSION appearance through `auto', `dark' and `light' and return it.
;;
;; Function: etaf-island-notify (title &key app detail (variant 'info) action-label on-action (ttl 5.0) group actions session)
;;;###autoload (autoload 'etaf-island-notify "etaf-island" nil nil)
;; Convenience helper publishing notification TITLE through `etaf-notify' and
;; pulsing SESSION (or the default session).
;;
;; Function: etaf-island-dismiss-notification (session &optional id)
;;;###autoload (autoload 'etaf-island-dismiss-notification "etaf-island" nil nil)
;; Dismiss notification ID (or the active alert) via `etaf-notify-dismiss' and
;; collapse any active alert on SESSION.
;;
;; Function: etaf-island-clear-notifications (session)
;;;###autoload (autoload 'etaf-island-clear-notifications "etaf-island" nil nil)
;; Clear all stored notifications via `etaf-notify-clear' and collapse alerts.
;;
;; Function: etaf-island-view (&optional session interactive standalone)
;;;###autoload (autoload 'etaf-island-view "etaf-island" nil nil)
;; Return an embeddable ETAF View for SESSION.
;;
;; Function: etaf-island-open (&optional session)
;;;###autoload (autoload 'etaf-island-open "etaf-island" nil t)
;; Open ETAF Island in its own buffer preserving Emacs's mode-line.
;;
;; Function: etaf-island-show (&optional session)
;;;###autoload (autoload 'etaf-island-show "etaf-island" nil t)
;; Show ETAF Island in a headerless draggable top-center floating `etaf-posframe'
;; capsule that reshapes in place without manual resizing or unwanted scrolling.
;;
;; Function: etaf-island-focus (&optional session)
;;;###autoload (autoload 'etaf-island-focus "etaf-island" nil t)
;; Smart keyboard summon: expand and focus the floating island for full keyboard
;; control, or collapse back to the compact capsule and restore editor focus.
;;
;; Function: etaf-island-hide ()
;;;###autoload (autoload 'etaf-island-hide "etaf-island" nil t)
;; Hide the active floating ETAF Island panel, if any.
;;
;; Function: etaf-island-toggle (&optional session)
;;;###autoload (autoload 'etaf-island-toggle "etaf-island" nil t)
;; Toggle the floating ETAF Island panel on or off.
;;
;; Function: etaf-island-mode (&optional arg)
;;;###autoload (autoload 'etaf-island-mode "etaf-island" nil t)
;; Global minor mode connecting `etaf-island' to `etaf-notify-functions',
;; `etaf-activity-change-functions' and optional Emacs native sensors.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-island")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-island.el" dir))
                                (file-exists-p (expand-file-name "etaf-island.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-island-theme)
(require 'etaf-island-sensors)
(require 'etaf-island-model)
(require 'etaf-island-views)
(require 'etaf-island-app)

;;;###autoload
(with-eval-after-load 'etaf
  (etaf-app-register 'etaf-island
    :title "灵动岛"
    :icon "I"
    :category 'system
    :feature 'etaf-island
    :open 'etaf-island-open
    :hosts '(buffer desktop)
    :session '(:create etaf-island-create :view etaf-island-view)
    :window '(:width 780 :height 18 :min-width 480 :min-height 10)))

(provide 'etaf-island)
;;; etaf-island.el ends here
