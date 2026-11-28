;;; etaf-balatro.el --- Balatro-style text deck-building scoring roguelike -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.2") (etaf-ui "0.3.4"))
;; Keywords: games, cards
;; URL: https://github.com/emacs-taf/etaf-balatro

;;; Commentary:

;; Public API
;;
;; ETAF Balatro is a pure-ETAF Balatro-inspired text deck-building and scoring
;; roguelike for Emacs.  Play poker hands across 8 Antes of Small, Big and
;; Boss Blinds, trigger left-to-right card enhancement and Joker scoring
;; cascades animated by `etaf-animation-timeline', reorder Jokers to optimize
;; additive versus multiplicative scaling, sculpt individual hand cards with
;; targeted Tarot consumables, inspect the 52-card Deck Matrix, and follow an
;; interactive 4-step beginner guide and contextual in-game Coach ribbon.
;;
;; Load this package with (require 'etaf-balatro) after adding this repository
;; root and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.  Only the
;; interfaces listed below are supported for use by other packages.
;;
;; Error: etaf-balatro-error
;; Signals an invalid ETAF Balatro session, hand, speed, modal or Joker operation.
;;
;; Variable: etaf-balatro-default-speed
;; Default scoring cascade playback multiplier (1.0, 2.0 or 4.0).
;;
;; Variable: etaf-balatro-records-file
;; File path for persistent lifetime records and onboarding state, or nil.
;;
;; Function: etaf-balatro-records ()
;;;###autoload (autoload 'etaf-balatro-records "etaf-balatro" nil nil)
;; Return a fresh copy of persistent ETAF Balatro lifetime records.
;;
;; Function: etaf-balatro-new-run (&key seed (appearance 'auto) speed skip-onboarding)
;;;###autoload (autoload 'etaf-balatro-new-run "etaf-balatro" nil nil)
;; Create and return a new deterministic ETAF Balatro run session.
;;
;; Function: etaf-balatro-state (session)
;;;###autoload (autoload 'etaf-balatro-state "etaf-balatro" nil nil)
;; Return a plain read-only snapshot plist of SESSION.
;;
;; Function: etaf-balatro-evaluate-hand (cards &optional hand-levels)
;;;###autoload (autoload 'etaf-balatro-evaluate-hand "etaf-balatro" nil nil)
;; Classify 1 to 5 played CARDS and return scoring metadata plist.
;;
;; Function: etaf-balatro-simulate-score (played-cards held-cards jokers hand-levels &key (hands-left 4) (discards-left 3) (money 4) boss-trait (seed 4821))
;;;###autoload (autoload 'etaf-balatro-simulate-score "etaf-balatro" nil nil)
;; Purely evaluate PLAYED-CARDS with HELD-CARDS, JOKERS and HAND-LEVELS.
;; Returns final chips, mult, total score, ordered `:events' trace and
;; `:shattered-ids' for broken Glass cards.
;;
;; Function: etaf-balatro-toggle-card (session index)
;;;###autoload (autoload 'etaf-balatro-toggle-card "etaf-balatro" nil nil)
;; Toggle selection of the card at 0-based INDEX in SESSION's hand.
;;
;; Function: etaf-balatro-clear-selection (session)
;;;###autoload (autoload 'etaf-balatro-clear-selection "etaf-balatro" nil nil)
;; Deselect all currently selected cards in SESSION.
;;
;; Function: etaf-balatro-cycle-sort (session)
;;;###autoload (autoload 'etaf-balatro-cycle-sort "etaf-balatro" nil nil)
;; Toggle SESSION's hand sort mode between `rank' and `suit'.
;;
;; Function: etaf-balatro-play-hand (session &optional instant)
;;;###autoload (autoload 'etaf-balatro-play-hand "etaf-balatro" nil nil)
;; Play selected cards in SESSION, running the scoring cascade timeline.
;;
;; Function: etaf-balatro-discard (session)
;;;###autoload (autoload 'etaf-balatro-discard "etaf-balatro" nil nil)
;; Discard currently selected cards in SESSION and draw replacements.
;;
;; Function: etaf-balatro-skip-animation (session)
;;;###autoload (autoload 'etaf-balatro-skip-animation "etaf-balatro" nil nil)
;; Immediately finish any active scoring cascade animation in SESSION.
;;
;; Function: etaf-balatro-set-speed (session speed)
;;;###autoload (autoload 'etaf-balatro-set-speed "etaf-balatro" nil nil)
;; Set SESSION's cascade playback speed multiplier to SPEED (1.0, 2.0 or 4.0).
;;
;; Function: etaf-balatro-select-joker (session index)
;;;###autoload (autoload 'etaf-balatro-select-joker "etaf-balatro" nil nil)
;; Select owned Joker at 0-based INDEX in SESSION.
;;
;; Function: etaf-balatro-move-joker (session delta)
;;;###autoload (autoload 'etaf-balatro-move-joker "etaf-balatro" nil nil)
;; Shift the selected Joker left (DELTA < 0) or right (DELTA > 0) in SESSION.
;;
;; Function: etaf-balatro-sell-joker (session &optional index)
;;;###autoload (autoload 'etaf-balatro-sell-joker "etaf-balatro" nil nil)
;; Sell owned Joker at INDEX (or currently selected Joker) in SESSION.
;;
;; Function: etaf-balatro-use-consumable (session &optional index)
;;;###autoload (autoload 'etaf-balatro-use-consumable "etaf-balatro" nil nil)
;; Use held consumable (Planet or targeted Tarot) at 0-based INDEX in SESSION.
;;
;; Function: etaf-balatro-buy-shop-item (session index)
;;;###autoload (autoload 'etaf-balatro-buy-shop-item "etaf-balatro" nil nil)
;; Purchase shop shelf item at 0-based INDEX in SESSION.
;;
;; Function: etaf-balatro-reroll-shop (session)
;;;###autoload (autoload 'etaf-balatro-reroll-shop "etaf-balatro" nil nil)
;; Spend $5 to roll 4 fresh shop items in SESSION.
;;
;; Function: etaf-balatro-next-blind (session)
;;;###autoload (autoload 'etaf-balatro-next-blind "etaf-balatro" nil nil)
;; Leave the shop and begin the next Blind in SESSION.
;;
;; Function: etaf-balatro-toggle-appearance (session)
;;;###autoload (autoload 'etaf-balatro-toggle-appearance "etaf-balatro" nil nil)
;; Cycle SESSION appearance through `auto', `dark' and `light' and return it.
;;
;; Function: etaf-balatro-toggle-modal (session modal)
;;;###autoload (autoload 'etaf-balatro-toggle-modal "etaf-balatro" nil nil)
;; Toggle MODAL (`deck', `hands', `guide' or nil) in SESSION.
;;
;; Function: etaf-balatro-open-guide (session &optional step)
;;;###autoload (autoload 'etaf-balatro-open-guide "etaf-balatro" nil nil)
;; Open the 4-step interactive beginner guide in SESSION at 0-based STEP.
;;
;; Function: etaf-balatro-guide-step (session delta)
;;;###autoload (autoload 'etaf-balatro-guide-step "etaf-balatro" nil nil)
;; Step the interactive beginner guide in SESSION by DELTA (-1 or +1).
;;
;; Function: etaf-balatro-toggle-coach (session)
;;;###autoload (autoload 'etaf-balatro-toggle-coach "etaf-balatro" nil nil)
;; Toggle the contextual in-game Coach ribbon in SESSION and persist it.
;;
;; Function: etaf-balatro-restart (session &optional seed)
;;;###autoload (autoload 'etaf-balatro-restart "etaf-balatro" nil nil)
;; Restart SESSION with a fresh run, optionally using integer SEED.
;;
;; Function: etaf-balatro-view (&optional session quit)
;;;###autoload (autoload 'etaf-balatro-view "etaf-balatro" nil nil)
;; Return an embeddable ETAF View for SESSION.
;;
;; Function: etaf-balatro-open (&optional seed)
;;;###autoload (autoload 'etaf-balatro-open "etaf-balatro" nil t)
;; Open ETAF Balatro in its own buffer preserving Emacs's mode-line.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-balatro")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-balatro.el" dir))
                                (file-exists-p (expand-file-name "etaf-balatro.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))

(require 'etaf-balatro-theme)
(require 'etaf-balatro-engine)
(require 'etaf-balatro-model)
(require 'etaf-balatro-views)
(require 'etaf-balatro-app)

;;;###autoload
(with-eval-after-load 'etaf
  (etaf-app-register 'etaf-balatro
    :title "小丑牌 · Balatro"
    :icon "J"
    :category 'game
    :feature 'etaf-balatro
    :open 'etaf-balatro-open
    :hosts '(buffer desktop panel)
    :session '(:create etaf-balatro-new-run
               :view etaf-balatro-view
               :keep-alive t)
    :window '(:width 1200 :height 36 :min-width 640 :min-height 24)
    :panel '(:width 126 :height 38 :fill-height t
             :at frame-center :stack nil :draggable t)))

(provide 'etaf-balatro)
;;; etaf-balatro.el ends here
