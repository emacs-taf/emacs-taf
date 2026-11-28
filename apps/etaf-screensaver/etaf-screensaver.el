;;; etaf-screensaver.el --- Idle generative screensavers for Emacs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0"))
;; Keywords: multimedia, convenience
;; URL: https://github.com/emacs-taf/etaf-screensaver

;;; Commentary:
;; A restrained, canvas-only screensaver framework for Emacs built on ETAF.
;; After an idle interval, animation fills the current frame; any key press,
;; mouse movement, completed click or wheel event dismisses it and restores
;; the prior window configuration without replaying input.  This is a visual
;; screensaver, not a security lock.  No child processes are created.
;;
;; Quick start:
;;   (require 'etaf-screensaver)
;;   (setq etaf-screensaver-idle-delay 300
;;         etaf-screensaver-order 'shuffle
;;         etaf-screensaver-playlist '(poems (matrix :speed 12) snow clock))
;;   (etaf-screensaver-mode 1)
;;
;; Only the declarations below are public; unlisted symbols are internal.
;; See docs/manual.md for configuration and custom scene authoring recipes.
;;
;; Function: etaf-screensaver-mode (&optional arg)
;;;###autoload (autoload 'etaf-screensaver-mode "etaf-screensaver" nil t)
;; Toggle automatic idle screensaver presentation after
;; `etaf-screensaver-idle-delay' seconds.  Positive ARG enables; nonpositive
;; ARG disables and dismisses any active presentation.  Avoids active
;; minibuffers and unfocused or hidden frames.
;;
;; Function: etaf-screensaver-open (&optional playlist seed)
;;;###autoload (autoload 'etaf-screensaver-open "etaf-screensaver" nil t)
;; Start presenting PLAYLIST (default `etaf-screensaver-playlist') in the
;; selected frame and return its buffer.  With a prefix argument interactively,
;; prompt for a single scene to preview.  Optional integer SEED reproduces
;; randomized choices.  Starting while active returns the existing buffer
;; without overwriting the saved window snapshot.  Invalid settings signal
;; `etaf-screensaver-error' before taking over windows.
;;
;; Function: etaf-screensaver-preview (scene)
;;;###autoload (autoload 'etaf-screensaver-preview "etaf-screensaver" nil t)
;; Interactively choose and preview a registered SCENE without modifying
;; `etaf-screensaver-playlist' or the saved resume position.
;;
;; Function: etaf-screensaver-stop ()
;;;###autoload (autoload 'etaf-screensaver-stop "etaf-screensaver" nil t)
;; Dismiss any active presentation, restore windows, mouse tracking and GC
;; threshold, and release all timers, hooks and buffers.  Safe to call
;; repeatedly.
;;
;; Function: etaf-screensaver-status ()
;;;###autoload (autoload 'etaf-screensaver-status "etaf-screensaver" nil nil)
;; Return a plist snapshot of automatic mode (`:active', `:automatic') and,
;; when active, `:scene', `:buffer', `:index', `:seed', `:ticks', `:elapsed',
;; `:columns', `:rows', `:frame-rate', `:duration', `:frame',
;; `:transition-progress', copied `:params' and `:up-next'.
;;
;; Function: etaf-screensaver-scenes ()
;;;###autoload (autoload 'etaf-screensaver-scenes "etaf-screensaver" nil nil)
;; Return registered scene identifier symbols in registration order.
;;
;; Function: etaf-screensaver-scene-info (scene)
;;;###autoload (autoload 'etaf-screensaver-scene-info "etaf-screensaver" nil nil)
;; Return SCENE's public metadata plist (`:id', `:title', `:summary',
;; `:frame-rate', `:duration', `:background', `:frame', `:params').  SCENE
;; accepts an identifier, symbol name or display title.
;;
;; Macro: etaf-screensaver-define-scene (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-scene "etaf-screensaver" nil nil)
;; Register generative scene ID with plist PROPERTIES: required `:render' and
;; optional `:title', `:summary', `:frame-rate', `:duration', `:background',
;; `:frame' (`full' or `card'), `:params' defaults alist, `:create', `:step'
;; and `:resize'.  Callbacks must be pure.  Re-registering replaces ID in
;; place.
;;
;; Macro: etaf-screensaver-define-text-scene (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-text-scene "etaf-screensaver" nil nil)
;; Define a text, quote or poem screensaver under ID with `:items' (list of
;; strings or `(:text STR :caption STR)' plists, or a 0-arg generator),
;; `:style' (`typewriter', `fade', `scroll' or `static'), `:align', `:color',
;; `:caption-color', `:hold', `:fade', `:speed', `:letter-spacing' and
;; `:order'.
;;
;; Macro: etaf-screensaver-define-field-scene (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-field-scene "etaf-screensaver" nil nil)
;; Define a 2D scalar-field screensaver under ID from `:value'
;; `(lambda (x y ctx))', `:range', `:ramp', optional `:palette' and `:block'.
;;
;; Macro: etaf-screensaver-define-particle-scene (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-particle-scene "etaf-screensaver" nil nil)
;; Define a particle-system screensaver under ID from optional `:count' and
;; callbacks `:spawn', `:update' and `:draw'.
;;
;; Function: etaf-screensaver-canvas-create (columns rows)
;;;###autoload (autoload 'etaf-screensaver-canvas-create "etaf-screensaver" nil nil)
;; Create a blank COLUMNS by ROWS character canvas.
;;
;; Function: etaf-screensaver-canvas-clear (canvas)
;;;###autoload (autoload 'etaf-screensaver-canvas-clear "etaf-screensaver" nil nil)
;; Clear CANVAS characters and colors in place and return CANVAS.
;;
;; Function: etaf-screensaver-canvas-put (canvas row col char &optional color)
;;;###autoload (autoload 'etaf-screensaver-canvas-put "etaf-screensaver" nil nil)
;; Draw CHAR at ROW, COL in CANVAS with optional COLOR string or face plist.
;; Handles wide CJK cells safely and ignores out-of-bounds coordinates.
;;
;; Function: etaf-screensaver-canvas-text (canvas row col text &optional color)
;;;###autoload (autoload 'etaf-screensaver-canvas-text "etaf-screensaver" nil nil)
;; Draw TEXT at ROW, COL in CANVAS with optional COLOR or face plist.  COL
;; accepts an integer column or `left', `center' or `right'.
;;
;; Function: etaf-screensaver-canvas-fill (canvas row col width height char &optional color)
;;;###autoload (autoload 'etaf-screensaver-canvas-fill "etaf-screensaver" nil nil)
;; Fill a WIDTH by HEIGHT rectangle at ROW, COL in CANVAS with CHAR and COLOR.
;;
;; Function: etaf-screensaver-canvas-box (canvas row col width height &optional color)
;;;###autoload (autoload 'etaf-screensaver-canvas-box "etaf-screensaver" nil nil)
;; Draw a thin Unicode box of WIDTH by HEIGHT at ROW, COL in CANVAS.
;;
;; Function: etaf-screensaver-canvas-rows (canvas)
;;;###autoload (autoload 'etaf-screensaver-canvas-rows "etaf-screensaver" nil nil)
;; Project CANVAS to a list of exact-width strings with merged face runs.
;;
;; Function: etaf-screensaver-color-mix (from to ratio)
;;;###autoload (autoload 'etaf-screensaver-color-mix "etaf-screensaver" nil nil)
;; Linearly blend six-digit hex colors FROM and TO by RATIO clamped to [0, 1].
;;
;; Function: etaf-screensaver-ramp (sequence ratio)
;;;###autoload (autoload 'etaf-screensaver-ramp "etaf-screensaver" nil nil)
;; Sample a character or element from nonempty string, vector or list SEQUENCE
;; at RATIO clamped to [0, 1].
;;
;; Variable: etaf-screensaver-idle-delay
;; Positive idle seconds before automatic presentation starts, default 300.
;;
;; Variable: etaf-screensaver-playlist
;; Repeating playlist: a scene symbol, a configured item `(SCENE :key val ...)',
;; or a list mixing both.  Built-in scenes include `matrix', `snow', `donut',
;; `plasma', `equalizer', `sand', `poems' and `clock'.
;;
;; Variable: etaf-screensaver-order
;; Round ordering for `etaf-screensaver-playlist': `sequential' (default),
;; `shuffle' or `random'.
;;
;; Variable: etaf-screensaver-duration
;; Default positive seconds per scene when neither item nor scene specifies one,
;; default 30.
;;
;; Variable: etaf-screensaver-frame-rate
;; Positive global frame-rate cap in (0, 60], default 30.
;;
;; Variable: etaf-screensaver-background
;; Default canvas background color when a scene does not set its own.
;;
;; Variable: etaf-screensaver-frame
;; Global framing override: nil (scene default), `full' or `card'.
;;
;; Variable: etaf-screensaver-transition-duration
;; Top-to-bottom reveal seconds between different pages in [0, 5], default 1.0.
;; Zero disables transitions.
;;
;; Error: etaf-screensaver-error
;; Signaled for invalid configuration, unknown scenes/parameters or runtime
;; scene errors.

;;; Code:
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-screensaver")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-screensaver.el" dir))
                                (file-exists-p (expand-file-name "etaf-screensaver.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-screensaver-app)
(require 'etaf-screensaver-builtins)

;;;###autoload
(with-eval-after-load 'etaf
  (etaf-app-register 'etaf-screensaver
    :title "屏保"
    :icon "S"
    :category 'system
    :feature 'etaf-screensaver
    :open 'etaf-screensaver-open
    :hosts '(buffer)))

(provide 'etaf-screensaver)
;;; etaf-screensaver.el ends here
