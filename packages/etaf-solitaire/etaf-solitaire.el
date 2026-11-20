;;; -*- lexical-binding: t; -*-
;;; etaf-solitaire.el --- Verdant solitaire, a standalone GameKit application

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-gamekit "0.1.0") (etaf-ui "0.1.0"))
;;; Commentary:
;; Verdant presents OpenSpiel's K+ Klondike rules with a native card table.
;; K+ folds repeated draws into available waste-card choices; it is not a
;; Windows Klondike emulator. Rules, chance and history remain in OpenSpiel.
;;
;; Variable: etaf-solitaire-game
;; Inert game definition usable with etaf-gamekit-start. Each instance owns
;; an independent deal. Override :seed in GameKit options for a reproducible deal.
;;
;; Variable: etaf-solitaire-appearance
;; Initial appearance for new instances: auto, light or dark. Auto follows
;; the opening frame's background mode. Each instance can switch independently
;; with the theme button or T without changing its game state.
;;
;; Function: etaf-solitaire-create (&optional seed)
;;;###autoload (autoload 'etaf-solitaire-create "etaf-solitaire" nil t)
;; Create and return an independent GameKit session without displaying it.
;; SEED is an optional integer; omitted creates a fresh random deal. The caller
;; owns display and lifecycle; pass the result to etaf-solitaire-view and
;; release it with etaf-gamekit-close.
;;
;; Function: etaf-solitaire-view (session)
;;;###autoload (autoload 'etaf-solitaire-view "etaf-solitaire" nil t)
;; Return the reactive View for SESSION, suitable for embedding in a host such
;; as an etaf-desktop window. The caller owns SESSION's display and lifecycle.
;; Escape dismisses a dialog or selected card one layer at a time; with no
;; temporary state, the enclosing host may handle it without closing the deal.
;;
;; Function: etaf-solitaire-open (&optional seed)
;;;###autoload (autoload 'etaf-solitaire-open "etaf-solitaire" nil t)
;; Open and display an independent game; return its GameKit instance.
;; SEED is an optional integer; omitted creates a fresh random deal. Requires
;; the OpenSpiel runtime installed by GameKit. No snapshot is loaded implicitly.
;;
;; Function: etaf-solitaire-close (&optional instance)
;;;###autoload (autoload 'etaf-solitaire-close "etaf-solitaire" nil t)
;; Close INSTANCE and its buffer. Omitted uses the current Solitaire buffer.
;; No automatic save is performed; use the application's Save command first.
;;
;;; Code:
(require 'etaf-gamekit)
(require 'etaf-ui)
(defgroup etaf-solitaire nil "Verdant solitaire." :group 'games)
(defcustom etaf-solitaire-appearance 'auto
  "Initial appearance of new Solitaire instances."
  :type '(choice (const auto) (const light) (const dark)) :group 'etaf-solitaire)
(defconst etaf-solitaire--directory
  (file-name-directory (or load-file-name buffer-file-name)))
(let ((load-path (cons (expand-file-name "lisp" etaf-solitaire--directory) load-path)))
  (require 'etaf-solitaire-theme)
  (require 'etaf-solitaire-model)
  (require 'etaf-solitaire-views)
  (require 'etaf-solitaire-app))
(provide 'etaf-solitaire)
;;; etaf-solitaire.el ends here
