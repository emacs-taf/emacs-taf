;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi.el --- Chinese chess (Xiangqi), a standalone GameKit application

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.10
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-gamekit "0.1.0") (etaf-ui "0.1.0"))
;;; Commentary:
;; Chu He presents OpenSpiel's xiangqi rules on a native ETAF board with both
;; palettes and a computer opponent. Graphical displays use vector
;; intersections and circular stones; terminals keep text cells. Artwork,
;; selection, move hints and the check warning are presentation only; legality
;; and history stay in OpenSpiel, and its adapter supplies the opponent's search.
;;
;; Variable: etaf-xiangqi-game
;; Inert game definition usable with etaf-gamekit-start. Each instance owns an
;; independent match with red moving first. Override :seed in GameKit options
;; for a reproducible opening.
;;
;; Variable: etaf-xiangqi-appearance
;; Initial appearance for new instances: auto (default), light or dark. Auto
;; follows the opening frame's background mode. Each instance can switch
;; independently with the theme button or T without resetting the match.
;;
;; Variable: etaf-xiangqi-opponent
;; Who plays which side in new instances: computer-black (the default, with the
;; human on red), computer-red or hot-seat. The application dialog switches a
;; running match with O; the computer moves when it is its turn and the backend
;; advertises the bot operation. A reply leaves at least 0.6 seconds of reading
;; time, then uses a scoped ETAF transition on graphical boards. The last move's
;; endpoints and caption remain visible. Disabling etaf-animation-enabled keeps
;; the reading interval and static feedback without interpolated movement.
;;
;; Variable: etaf-xiangqi-level
;; Strength of the computer opponent in new instances: easy, normal (default)
;; or hard. Each level selects the search's plies and seconds per move; the
;; dialog changes it for a running match.
;;
;; Function: etaf-xiangqi-create (&optional seed)
;;;###autoload (autoload 'etaf-xiangqi-create "etaf-xiangqi" nil t)
;; Create an independent match whose single host renders it.
;; SEED is an optional integer; omitted creates a fresh random opening. The
;; session owns state and the backend process but mounts no presentation of its
;; own, so the caller's one view (etaf-xiangqi-view) is the only rendering;
;; etaf-xiangqi-open displays it in its own buffer instead. Release the session
;; with etaf-gamekit-close.
;;
;; Function: etaf-xiangqi-view (session)
;;;###autoload (autoload 'etaf-xiangqi-view "etaf-xiangqi" nil t)
;; Return the reactive View for SESSION, suitable for embedding in a host such
;; as an etaf-desktop window. The caller owns SESSION's display and lifecycle.
;;
;; Function: etaf-xiangqi-doctor ()
;; Return capability facts for playing xiangqi.  The shape matches
;; `etaf-install-doctor': the rules engine comes from `etaf-gamekit', which is an
;; ordinary package dependency, while the OpenSpiel runtime must be installed
;; once before a game can start.  The check follows
;; `etaf-gamekit-openspiel-python-program', and its remedy installs that runtime.
;; Function: etaf-xiangqi-open (&optional seed)
;;;###autoload (autoload 'etaf-xiangqi-open "etaf-xiangqi" nil t)
;; Open and display an independent match; return its GameKit instance. SEED is
;; an optional integer. The opponent follows etaf-xiangqi-opponent: the
;; computer replies by itself, or both sides are played hot-seat in one buffer,
;; where the bridge view switches to the side to move after every move.
;; Requires the OpenSpiel runtime installed by GameKit. No snapshot is loaded
;; implicitly.
;;
;; Function: etaf-xiangqi-close (&optional instance)
;;;###autoload (autoload 'etaf-xiangqi-close "etaf-xiangqi" nil t)
;; Close INSTANCE and its buffer. Omitted uses the current Xiangqi buffer.
;; No automatic save is performed; use the application's Save command first.
;; Closing also cancels pending reply presentation and its animation scope.
;;
;;; Code:
(require 'etaf-gamekit)

(defun etaf-xiangqi-doctor ()
  "Return capability facts for playing xiangqi.
The shape matches `etaf-install-doctor': :required and :optional lists of
(LABEL AVAILABLE REMEDY).  Nothing is installed or changed."
  (list :required
        (list (list "OpenSpiel runtime"
                    (and (stringp etaf-gamekit-openspiel-python-program)
                         (executable-find etaf-gamekit-openspiel-python-program))
                    "Install it once with: M-x etaf-gamekit-install-openspiel"))
        :optional nil))

(require 'etaf-ui)
(defgroup etaf-xiangqi nil "Chu He xiangqi." :group 'games)
(defcustom etaf-xiangqi-appearance 'auto
  "Initial appearance of new Xiangqi instances."
  :type '(choice (const auto) (const light) (const dark)) :group 'etaf-xiangqi)
(defcustom etaf-xiangqi-opponent 'computer-black
  "Who plays which side in new Xiangqi instances."
  :type '(choice (const computer-black) (const computer-red) (const hot-seat))
  :group 'etaf-xiangqi)
(defcustom etaf-xiangqi-level 'normal
  "Strength of the computer opponent in new Xiangqi instances."
  :type '(choice (const easy) (const normal) (const hard)) :group 'etaf-xiangqi)
(defconst etaf-xiangqi--directory
  (file-name-directory
   (or (and load-file-name
            (not (string-suffix-p ".eln" load-file-name))
            (file-directory-p (expand-file-name "lisp" (file-name-directory load-file-name)))
            load-file-name)
       (bound-and-true-p byte-compile-current-file)
       (locate-library "etaf-xiangqi")
       buffer-file-name)))
;; Installed archives compile each module separately, so `lisp' must be on
;; `load-path' while the byte compiler runs, not only when this entry loads.
;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-xiangqi")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-xiangqi.el" dir))
                                (file-exists-p (expand-file-name "etaf-xiangqi.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))
(let ((load-path (cons (expand-file-name "lisp" etaf-xiangqi--directory) load-path)))
  (require 'etaf-xiangqi-theme)
  (require 'etaf-xiangqi-model)
  (require 'etaf-xiangqi-views)
  (require 'etaf-xiangqi-app))
(provide 'etaf-xiangqi)
;;; etaf-xiangqi.el ends here
