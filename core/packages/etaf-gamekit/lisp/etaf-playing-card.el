;;; etaf-playing-card.el --- Controlled playing-card presentation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Present one caller-owned playing card or empty pile placeholder without game
;; rules.  Lives in `etaf-gamekit' so `etaf-ui' stays focused on general UI
;; controls.

;;; Code:

(require 'etaf)
(require 'etaf-ui)

(defconst etaf-gamekit--playing-card-defaults
  '(:ui-playing-card-bg "#F7F4EC"
    :ui-playing-card-black "#253546"
    :ui-playing-card-red "#B73951"
    :ui-playing-card-back-bg "#315C76"
    :ui-playing-card-back-fg "#BFD8E5"
    :ui-playing-card-empty-bg "#E7EDF1"
    :ui-playing-card-empty-fg "#788B99"
    :ui-playing-card-selected-bg "#F6D994")
  "Fallback colors for `etaf-playing-card' when the active Theme omits them.")

(defun etaf-gamekit--playing-card-color (token)
  "Resolve playing-card color TOKEN from the active Theme or defaults."
  (or (etaf-theme-token token)
      (plist-get etaf-gamekit--playing-card-defaults token)))

(defun etaf-gamekit--playing-card-hover (background)
  "Derive a subtle hover background from BACKGROUND."
  (let* ((rgb (and (stringp background) (ignore-errors (color-name-to-rgb background))))
         (luma (if rgb (+ (* 0.2126 (nth 0 rgb)) (* 0.7152 (nth 1 rgb)) (* 0.0722 (nth 2 rgb))) 0.5))
         (target (if (< luma 0.35) "#FFFFFF" "#000000")))
    (if (stringp background)
        (etaf-ui-color-mix background target (if (< luma 0.35) 0.14 0.08))
      "#EAE4D5")))

(etaf-define-component etaf-playing-card
    (&key rank suit face-down empty selected disabled on-press label ref (columns 9) (lines 5))
  "Present one caller-owned card or pile placeholder, without game rules."
  :validate
  (progn
    (etaf-check-prop :rank rank (or (null rank) (and (stringp rank) (<= (string-width rank) 3)
                                                   (not (string-match-p "[\n\t]" rank))))
                     "nil or a one-line rank up to three columns" 'etaf-playing-card)
    (etaf-check-prop :suit suit (memq suit '(nil spades hearts clubs diamonds))
                     "nil or spades, hearts, clubs, diamonds" 'etaf-playing-card)
    (etaf-check-prop :columns columns (and (integerp columns) (>= columns 7))
                     "an integer of at least seven character columns" 'etaf-playing-card)
    (etaf-check-prop :lines lines (and (integerp lines) (>= lines 1))
                     "a positive number of text rows" 'etaf-playing-card))
  :render
  (let* ((glyph (pcase suit ('spades "♠") ('hearts "♥") ('clubs "♣") ('diamonds "♦") (_ "·")))
         (caption (cond (face-down "Face-down card") (empty (format "Empty %s pile" (or suit 'card)))
                        (t (format "%s of %s" (or rank "") (or suit 'cards)))))
         (corner (cond (face-down "· · ·") (empty glyph) (t (concat (or rank "") " " glyph))))
         (ink (etaf-gamekit--playing-card-color
               (cond (face-down :ui-playing-card-back-fg)
                     (empty :ui-playing-card-empty-fg)
                     ((memq suit '(hearts diamonds)) :ui-playing-card-red)
                     (t :ui-playing-card-black))))
         (background (etaf-gamekit--playing-card-color
                      (cond (selected :ui-playing-card-selected-bg)
                            (face-down :ui-playing-card-back-bg)
                            (empty :ui-playing-card-empty-bg)
                            (t :ui-playing-card-bg))))
         (hover-bg (or (and (not (or face-down empty))
                            (etaf-theme-token :ui-playing-card-hover-bg))
                       (etaf-gamekit--playing-card-hover background)))
         (content (make-list lines "")))
    (unless empty (setcar content (concat " " corner)))
    (when (or empty (> lines 2))
      (setf (nth (/ lines 2) content)
            (concat (make-string (max 1 (/ (- columns (string-width glyph)) 2)) ?\s)
                    (if face-down "◇" glyph))))
    (when (and (not empty) (> lines 3))
      (setf (nth (1- lines) content)
            (concat (make-string (max 1 (- columns (string-width corner) 1)) ?\s) corner)))
    (etaf-view
     (etaf-button :label (or label caption) :aria-label (or label caption)
       :ref ref :disabled (or disabled (null on-press)) :on-press on-press
       :variant 'ghost :padding '((lh 0) (ch 0)) :width (list 'ch columns)
       :height (list 'lh lines) :box-sizing 'border-box :font-weight 'normal
       :bgcolor background :color ink
       :help-echo (or label caption)
       :hover-style (unless (or selected disabled (null on-press))
                      (list :background-color hover-bg))
       (column :width 'stretch
         (text :for (index (number-sequence 0 (1- lines))) :key index (expr (nth index content))))))))

(provide 'etaf-playing-card)
;;; etaf-playing-card.el ends here
