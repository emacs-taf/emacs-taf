;;; -*- lexical-binding: t; -*-
;;; etaf-ui-playing-card.el --- Controlled playing-card presentation

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-ui-basic)

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
         (ink (etaf-ui--style-token (cond (face-down :ui-playing-card-back-fg)
                                         (empty :ui-playing-card-empty-fg)
                                         ((memq suit '(hearts diamonds)) :ui-playing-card-red)
                                         (t :ui-playing-card-black))))
         (background (etaf-ui--style-token (cond (selected :ui-playing-card-selected-bg)
                                                (face-down :ui-playing-card-back-bg)
                                                (empty :ui-playing-card-empty-bg)
                                                (t :ui-playing-card-bg))))
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
                      (list :background-color
                            (if (or face-down empty)
                                (etaf-ui--state-hover-shift background)
                              (etaf-ui--style-token :ui-playing-card-hover-bg))))
       (column :width 'stretch
         (text :for (index (number-sequence 0 (1- lines))) :key index (expr (nth index content))))))))

(provide 'etaf-ui-playing-card)
;;; etaf-ui-playing-card.el ends here
