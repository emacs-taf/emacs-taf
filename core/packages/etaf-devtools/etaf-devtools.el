;;; etaf-devtools.el --- Interactive runtime inspector and developer tools for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.6") (etaf-ui "0.3.4") (etaf-posframe "0.3.0"))
;; Keywords: tools, convenience, ui
;; URL: https://github.com/emacs-taf/etaf

;;; Commentary:

;; Interactive developer tools for any mounted ETAF application: live Component
;; and Host tree inspection, pure-text 4-layer Box Model metrics, on-demand
;; ECSS cascade provenance with WCAG contrast verification, reactive state
;; inspection with live `etaf-ref' editing, Highlight Updates flash overlays,
;; Flush & `etaf-performance' profiling, Focus/Keys/Regions diagnostics, and
;; multi-viewport QA simulation.
;;
;; Public API
;;
;; Load this package with (require 'etaf-devtools) after adding this repository
;; and its providers (`etaf', `etaf-ui', `etaf-posframe', `ebox', `ecss') to
;; `load-path'.  Only the interfaces listed below are supported for consumers.
;; All unlisted symbols and files under `lisp/' are internal.  This Commentary
;; is the authoritative export list; docs/manual.md contains workflows.
;;
;; Error: etaf-devtools-error
;; Invalid `etaf-devtools' operation or user expression input.
;; Catch with `condition-case'; failed calls do not return a value.
;;
;; Variable: etaf-devtools-default-dock
;; Default panel placement when opening: `right' (default), `bottom' or
;; `posframe'.
;;
;; Variable: etaf-devtools-right-width
;; Preferred column width of a right-docked `etaf-devtools' side window.
;;
;; Variable: etaf-devtools-bottom-height
;; Preferred line height of a bottom-docked `etaf-devtools' side window.
;;
;; Variable: etaf-devtools-max-flush-history
;; Maximum Flush/Commit entries kept in the Perf ring buffer.
;;
;; Variable: etaf-devtools-highlight-duration
;; Duration in seconds for incremental Highlight Updates overlays.
;;
;; Variable: etaf-devtools-full-highlight-duration
;; Duration in seconds for full-redraw Highlight Updates overlays.
;;
;; Variable: etaf-devtools-use-posframe
;; Non-nil to allow `etaf-posframe' for floating panels and picker badges.
;;
;; Function: etaf-devtools (&optional target)
;;;###autoload (autoload 'etaf-devtools "etaf-devtools" nil t)
;; Alias of `etaf-devtools-open'.
;;
;; Function: etaf-devtools-open (&optional target)
;;;###autoload (autoload 'etaf-devtools-open "etaf-devtools" nil t)
;; Open or focus `etaf-devtools' attached to TARGET Runtime (or the current
;; ETAF buffer).  Return the active session.
;;
;; Function: etaf-devtools-close ()
;;;###autoload (autoload 'etaf-devtools-close "etaf-devtools" nil t)
;; Close `etaf-devtools' and release all overlays, hooks, recordings and timers.
;;
;; Function: etaf-devtools-inspect (&optional runtime)
;;;###autoload (autoload 'etaf-devtools-inspect "etaf-devtools" nil t)
;; Start the interactive Element Picker on RUNTIME (or the current ETAF buffer).
;; Supports pointer clicks and keyboard stepping (`[' / `]' walk ancestors,
;; `RET' confirms, `ESC' cancels).
;;
;; Function: etaf-devtools-highlight-updates (&optional arg runtime)
;;;###autoload (autoload 'etaf-devtools-highlight-updates "etaf-devtools" nil t)
;; Toggle read-only Highlight Updates flash overlays on RUNTIME without mutating
;; the target buffer or distorting Ebox flush counts.
;;
;; Function: etaf-devtools-toggle-dock ()
;;;###autoload (autoload 'etaf-devtools-toggle-dock "etaf-devtools" nil t)
;; Cycle active `etaf-devtools' placement across `right', `bottom' and
;; `posframe' (falling back to `right' when posframe is unavailable).
;;
;; Function: etaf-devtools-create (&optional target)
;;;###autoload (autoload 'etaf-devtools-create "etaf-devtools" nil nil)
;; Create a standalone headless session for TARGET Runtime, suitable for
;; `etaf-posframe-register-app' or programmatic mounting.
;;
;; Function: etaf-devtools-view (session)
;;;###autoload (autoload 'etaf-devtools-view "etaf-devtools" nil nil)
;; Return the root ETAF View for SESSION.
;;
;; Function: etaf-devtools-dispose (session)
;;;###autoload (autoload 'etaf-devtools-dispose "etaf-devtools" nil nil)
;; Dispose standalone SESSION and release its hooks, timers and overlays.
;;
;; Function: etaf-devtools-doctor ()
;;;###autoload (autoload 'etaf-devtools-doctor "etaf-devtools" nil nil)
;; Return `:required' and `:optional' capability checks for `etaf-devtools'.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-devtools")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-devtools.el" dir))
                                (file-exists-p (expand-file-name "etaf-devtools.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-devtools-core)
(require 'etaf-devtools-overlay)
(require 'etaf-devtools-target)
(require 'etaf-devtools-model)
(require 'etaf-devtools-picker)
(require 'etaf-devtools-view)
(require 'etaf-devtools-ui)

(provide 'etaf-devtools)
;;; etaf-devtools.el ends here
