;;; etaf-pomodoro.el --- Focus timer as an ETAF application -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0"))
;; Keywords: tools, timer, hypermedia
;; URL: https://github.com/emacs-taf/etaf-pomodoro

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-pomodoro) after adding this
;; repository and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  A
;; Pomodoro timer is an ETAF application: `etaf-pomodoro-open' opens one
;; window whose countdown, buttons and keys the framework owns, and the same
;; session mounts as a floating panel through `etaf-pomodoro-create' and
;; `etaf-pomodoro-view', for example with `etaf-posframe-register-app'.
;; Three styles (`minimal', `ring' and `card') occupy the same rows, so
;; switching style inside a panel does not change the panel's size.  The
;; surface paints no border of its own: the host's frame is the card, so a
;; panel border stays one pixel wide on every side.
;;
;; A session is the unit of state.  It holds four reactive refs (seconds left,
;; full length, running, style) and the one-second tick; the tick runs while a
;; View is mounted, so closing the window or the panel stops it and the values
;; stay where they stopped.  The palette follows the appearance the host
;; reports: a panel inside a dark frame can stay light, and a standalone window
;; follows the Emacs theme.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Error: etaf-pomodoro-error
;; Signals an invalid Pomodoro operation: a focus length that is not a positive
;; whole number of minutes, an unknown style, or a non-positive extension.
;;
;; Variable: etaf-pomodoro-default-minutes
;; Focus length of a session created without :minutes.  Default 25; a positive
;; whole number of minutes.
;;
;; Function: etaf-pomodoro-open (&optional minutes)
;;;###autoload (autoload 'etaf-pomodoro-open "etaf-pomodoro" nil t)
;; Open a timer in its own buffer and return the buffer.
;; The timer starts paused; `p' starts or pauses it, `r' resets it, `+' adds
;; five minutes, `t' switches the style and `q' closes the window.  An open
;; timer is selected instead of creating a second one.  Closing the buffer
;; stops the tick and drops the session, so the next start begins fresh.
;;
;; Function: etaf-pomodoro-stop ()
;;;###autoload (autoload 'etaf-pomodoro-stop "etaf-pomodoro" nil t)
;; Close the standalone timer and stop its tick.
;; Inside a floating panel the command does nothing, because the renderer
;; closes the panel with its own key before the application key runs.
;;
;; Function: etaf-pomodoro-create (&key minutes style)
;;;###autoload (autoload 'etaf-pomodoro-create "etaf-pomodoro" nil t)
;; Return a new paused session.
;; MINUTES is the focus length, `etaf-pomodoro-default-minutes' by default, and
;; STYLE is `minimal' (default), `ring' or `card'.  A non-positive length or an
;; unknown style signals `etaf-pomodoro-error'.  The caller owns the session;
;; mounting `etaf-pomodoro-view' starts its tick and unmounting stops it.
;;
;; Function: etaf-pomodoro-view (&optional session quit)
;;;###autoload (autoload 'etaf-pomodoro-view "etaf-pomodoro" nil t)
;; Return SESSION's View for mounting in another host.
;; SESSION defaults to a new session.  The View paints the timer surface with
;; its own keys and follows the appearance the embedding host provides, so the
;; same View serves a standalone window, a floating panel and a desktop window.
;; QUIT adds a `q' key that closes the standalone window; leave it nil when the
;; host closes its own surface with its own key (a floating panel does), because
;; a surface key would consume `q' before the host could act on it.
;;
;; Function: etaf-pomodoro-state (session)
;;;###autoload (autoload 'etaf-pomodoro-state "etaf-pomodoro" nil t)
;; Return SESSION's public state as a plist.
;; The keys are `:remaining' (seconds left), `:total' (seconds the session
;; started with), `:running' (non-nil while counting) and `:style'.  Reading
;; the state does not change the session.
;;
;; Function: etaf-pomodoro-toggle (session)
;;;###autoload (autoload 'etaf-pomodoro-toggle "etaf-pomodoro" nil t)
;; Start or pause SESSION's countdown and return the new running state.
;;
;; Function: etaf-pomodoro-reset (session)
;;;###autoload (autoload 'etaf-pomodoro-reset "etaf-pomodoro" nil t)
;; Return SESSION's countdown to its full length and pause it.
;;
;; Function: etaf-pomodoro-extend (session &optional minutes)
;;;###autoload (autoload 'etaf-pomodoro-extend "etaf-pomodoro" nil t)
;; Add MINUTES of focus, five by default, to SESSION.
;; The extension also lengthens the session's full length, so the progress line
;; keeps measuring the whole countdown.
;;
;; Function: etaf-pomodoro-next-style (session)
;;;###autoload (autoload 'etaf-pomodoro-next-style "etaf-pomodoro" nil t)
;; Switch SESSION to the next of `minimal', `ring' and `card', returning it.
;;
;; Function: etaf-pomodoro-stop-session (session)
;;;###autoload (autoload 'etaf-pomodoro-stop-session "etaf-pomodoro" nil t)
;; Stop SESSION's one-second tick and return SESSION.
;; The countdown keeps its values, so mounting the session again continues from
;; where it stopped.  A host that keeps a session alive after hiding its
;; surface calls this when the session must not keep counting.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defgroup etaf-pomodoro nil
  "Focus timer built with ETAF."
  :group 'etaf
  :prefix "etaf-pomodoro-")

(defcustom etaf-pomodoro-default-minutes 25
  "Focus length of a session created without :minutes.
A positive whole number of minutes, 25 by default."
  :type 'integer
  :group 'etaf-pomodoro)

;;;###autoload
(eval-and-compile
  ;; A checkout is added to `load-path' by its root only.  The implementation
  ;; lives in lisp/, so find it beside the entry; `load-file-name' points into
  ;; the native-compilation cache once the package is compiled there, which has
  ;; no lisp/ directory, so the first candidate that does wins.
  (let ((root (cl-loop for file in (list load-file-name
                                         (bound-and-true-p byte-compile-current-file)
                                         (locate-library "etaf-pomodoro")
                                         buffer-file-name)
                       for dir = (and file (file-name-directory file))
                       when (and dir (file-directory-p (expand-file-name "lisp" dir)))
                       return dir)))
    (when root
      (add-to-list 'load-path (expand-file-name "lisp" root)))))

(require 'etaf-pomodoro-theme)
(require 'etaf-pomodoro-session)
(require 'etaf-pomodoro-views)
(require 'etaf-pomodoro-app)

(provide 'etaf-pomodoro)
;;; etaf-pomodoro.el ends here
