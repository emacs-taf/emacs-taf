;;; etaf-balatro-views.el --- Production v2 pure ETAF views for ETAF Balatro -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure ETAF UI Views implementing the approved `etaf-balatro' v2 design across
;; auto/dark/light themes and wide/medium/narrow/short viewports.  Features a
;; calm 3-level tonal surface hierarchy, generous spacing, 36-column sidebar
;; without orphan wrapping, physical 1-row card lift on selection, a 2-slot
;; Planet + targeted Tarot consumables tray, toggleable contextual Coach
;; ribbon, interactive 4-step beginner onboarding guide, and a 52-card Deck
;; Matrix.  Uses Emacs's default text size and preserves uniform line height.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-balatro-theme)
(require 'etaf-balatro-engine)
(require 'etaf-balatro-model)

(defconst etaf-balatro--matrix-ranks '(14 13 12 11 10 9 8 7 6 5 4 3 2)
  "Descending rank order for the 4x13 Deck Matrix.")

(defun etaf-balatro--focus-ref (ref &optional buffer)
  "Move ETAF focus to REF in BUFFER's or the current mounted runtime."
  (let* ((buf-rt (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer)))
         (cur-rt (etaf-current-runtime))
         (rt (cond
              ((and buf-rt (etaf-runtime-mounted-p buf-rt)) buf-rt)
              ((and cur-rt (etaf-runtime-mounted-p cur-rt)) cur-rt)
              (t (let ((local (etaf-runtime-for-buffer (current-buffer))))
                   (and local (etaf-runtime-mounted-p local) local))))))
    (when rt
      (ignore-errors (etaf-focus rt ref)))))

(defun etaf-balatro--format-int (n)
  "Format integer N with thousands separators."
  (let* ((neg (< n 0))
         (digits (number-to-string (abs (round n))))
         (len (length digits))
         (parts nil)
         (i len))
    (while (> i 3)
      (push (substring digits (- i 3) i) parts)
      (setq i (- i 3)))
    (push (substring digits 0 i) parts)
    (concat (if neg "-" "") (mapconcat #'identity parts ","))))

(defun etaf-balatro--format-mult (m)
  "Format multiplier M cleanly (integer when exact, else 1 decimal)."
  (let ((n (or m 0)))
    (if (= n (round n))
        (number-to-string (round n))
      (format "%.1f" (float n)))))

(defun etaf-balatro--rarity-label (rarity)
  "Return Chinese rarity label for RARITY symbol."
  (pcase rarity
    ('rare "稀有")
    ('uncommon "罕见")
    (_ "普通")))

(defun etaf-balatro--rarity-colors (tokens rarity)
  "Return (BG BORDER TEXT) colors for Joker RARITY."
  (pcase rarity
    ('rare (list (plist-get tokens :balatro-purple-bg)
                 (plist-get tokens :balatro-purple-border)
                 (plist-get tokens :balatro-purple)))
    ('uncommon (list (plist-get tokens :balatro-cyan-bg)
                     (plist-get tokens :balatro-cyan-border)
                     (plist-get tokens :balatro-cyan)))
    (_ (list (plist-get tokens :balatro-card)
             (plist-get tokens :balatro-border)
             (plist-get tokens :balatro-muted)))))

(defun etaf-balatro--enh-color (tokens enh)
  "Return semantic accent color for enhancement ENH."
  (pcase enh
    ('glass (plist-get tokens :balatro-glass))
    ('steel (plist-get tokens :balatro-steel))
    ('foil (plist-get tokens :balatro-foil))
    ('bonus (plist-get tokens :balatro-bonus))
    ('mult (plist-get tokens :balatro-mult-fg))
    (_ (plist-get tokens :balatro-dim))))

(defun etaf-balatro--suit-color (tokens suit)
  "Return calibrated foreground color for SUIT."
  (pcase suit
    ('hearts (plist-get tokens :balatro-heart))
    ('diamonds (plist-get tokens :balatro-diamond))
    ('spades (plist-get tokens :balatro-spade))
    (_ (plist-get tokens :balatro-club))))

(defun etaf-balatro--joker-live-short (joker)
  "Return dynamic short description string for JOKER."
  (if (eq (plist-get joker :id) 'gc-collector)
      (format "成长 +%d 筹" (or (plist-get joker :bonus-chips) 0))
    (or (plist-get joker :short) "")))

(defun etaf-balatro--blind-dots (blind)
  "Return 3-element list of status symbols for Small / Big / Boss dots."
  (pcase blind
    ('small '(active pending pending))
    ('big '(done active pending))
    (_ '(done done active))))

(defun etaf-balatro--deck-matrix-row (suit deck draw-ids hand-ids)
  "Build display cells for SUIT across ranks A..2 from DECK.
Returns a list of plists (:key :label :status :enh) where status is `draw',
`hand', `used' or `missing'."
  (mapcar
   (lambda (rank)
     (let* ((matches (cl-remove-if-not
                      (lambda (c)
                        (and (eq (plist-get c :suit) suit)
                             (= (plist-get c :rank) rank)))
                      deck))
            (rlab (etaf-balatro--rank-label rank)))
       (if (null matches)
           (list :key (format "%s-%d" suit rank) :label "·" :status 'missing :enh 'none)
         (let* ((in-hand (cl-find-if (lambda (c) (memq (plist-get c :id) hand-ids)) matches))
                (in-draw (cl-find-if (lambda (c) (memq (plist-get c :id) draw-ids)) matches))
                (rep (or in-hand in-draw (car matches)))
                (enh (or (plist-get rep :enhancement) 'none))
                (badge (plist-get (etaf-balatro--enhancement-info enh) :badge))
                (extra (if (> (length matches) 1) (format "×%d" (length matches)) ""))
                (status (cond (in-hand 'hand) (in-draw 'draw) (t 'used))))
           (list :key (format "%s-%d" suit rank)
                 :label (concat rlab badge extra)
                 :status status
                 :enh enh)))))
   etaf-balatro--matrix-ranks))

;; ---------------------------------------------------------------------------
;; Top Header Bar (Airy, Unified Speed Capsule, Onboarding & Host-Theme Toggle)
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--header (&key session tokens compact medium-p)
  "Render top navigation bar with blind dots, speed capsule, guide and theme."
  :render
  (let* ((seed (etaf-value (plist-get session :seed)))
         (speed (etaf-value (plist-get session :speed)))
         (appearance (etaf-value (plist-get session :appearance)))
         (phase (etaf-value (plist-get session :phase)))
         (ante (etaf-value (plist-get session :ante)))
         (blind (etaf-value (plist-get session :blind)))
         (blind-name (etaf-value (plist-get session :blind-name)))
         (dots (etaf-balatro--blind-dots blind))
         (tight (or compact medium-p))
         (speeds '((1.0 . "1×") (2.0 . "2×") (4.0 . "4×"))))
    (etaf-view
     (flex :class "balatro-header" :width 'stretch :height '(lh 1) :flex-shrink 0
           :align-items 'center :justify-content 'space-between
           :padding-inline (if tight '(ch 1) '(ch 3)) :column-gap '(ch 2)
           :background-color (plist-get tokens :balatro-header)
           :border-bottom (list '(px 1) 'solid (plist-get tokens :balatro-border))
       (row :item-gap (if tight '(ch 1) '(ch 2)) :cross-align 'center
         (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
               "♠ ETAF BALATRO")
         (text :if (not compact)
               :color (if (eq phase 'shop)
                          (plist-get tokens :balatro-green)
                        (plist-get tokens :balatro-muted))
               :font-weight (if (eq phase 'shop) 'bold 'normal)
               (expr (if (eq phase 'shop)
                         (format "过关商店 · 阶段 %d / 8" ante)
                       (format "阶段 %d / 8 · %s" ante blind-name))))
         (row :if (not compact) :item-gap '(ch 1) :cross-align 'center
           (expr
            (mapcar
             (lambda (pair)
               (let ((idx (car pair))
                     (st (cdr pair)))
                 (etaf-view
                  (text :key idx
                        :color (pcase st
                                 ('done (plist-get tokens :balatro-green))
                                 ('active (plist-get tokens :balatro-gold))
                                 (_ (plist-get tokens :balatro-border-strong)))
                        (expr (if (eq st 'pending) "○" "●"))))))
             (cl-loop for d in dots for i from 0 collect (cons i d)))))
         (text :if (not tight)
               :color (plist-get tokens :balatro-dim)
               (expr (format "种子 #%d" seed))))
       (row :item-gap '(ch 1) :cross-align 'center
         ;; Unified segmented speed capsule (single outer hairline)
         (row :if (not (eq phase 'shop)) :item-gap '(ch 0) :cross-align 'center
              :background-color (plist-get tokens :balatro-card)
              :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
           (expr
            (mapcar
             (lambda (sp)
               (let* ((val (car sp))
                      (lbl (cdr sp))
                      (active (= speed val)))
                 (etaf-view
                  (box :key lbl :role 'button :tab-index 0
                       :aria-label (format "播放速度 %s" lbl)
                       :padding-inline '(ch 1)
                       :background-color (if active
                                             (plist-get tokens :balatro-chips-bg)
                                           (plist-get tokens :balatro-card))
                       :color (if active
                                  (plist-get tokens :balatro-chips-fg)
                                (plist-get tokens :balatro-muted))
                       :font-weight (if active 'bold 'normal)
                       :pointer (unless active 'hand)
                       :hover-style (unless active
                                      (list :background-color (plist-get tokens :balatro-hover)))
                       :on-press (lambda () (etaf-balatro-set-speed session val))
                    (text (expr lbl))))))
             speeds)))
         (etaf-button :ref 'balatro-guide-btn
                      :label (cond (compact "指引") (medium-p "指引 · g") (t "新手指引 · g"))
                      :variant 'secondary
                      :border (list '(px 1) 'solid (plist-get tokens :balatro-border-strong))
                      :on-press (lambda () (etaf-balatro-open-guide session 0)))
         (etaf-button :ref 'balatro-theme-btn
                      :label (cond (compact "主题") (medium-p "主题 · t")
                                   (t (etaf-balatro--appearance-label appearance)))
                      :variant 'secondary
                      :border (list '(px 1) 'solid (plist-get tokens :balatro-border-strong))
                      :on-press (lambda () (etaf-balatro-toggle-appearance session)))
         (etaf-button :if (not tight) :ref 'balatro-help-btn
                      :label "? 帮助" :variant 'ghost
                      :on-press #'etaf-help)
         (etaf-button :ref 'balatro-restart-btn
                      :label (if tight "新局" "新开局")
                      :variant 'secondary
                      :bgcolor (plist-get tokens :balatro-card-alt)
                      :color (plist-get tokens :balatro-fg)
                      :border (list '(px 1) 'solid (plist-get tokens :balatro-border-strong))
                      :on-press (lambda () (etaf-balatro-restart session))))))))

;; ---------------------------------------------------------------------------
;; Animated Rolling Chips x Mult Scoreboard Card
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--formula-card (&key session tokens card-pad box-pad-v)
  "Render the blue Chips x red Mult scoring card with rolling transitions."
  :bindings
  ((chips-target
    (etaf-computed
     (lambda ()
       (let ((animating (etaf-value (plist-get session :animating)))
             (sel (etaf-value (plist-get session :selected-ids))))
         (etaf-value (plist-get session :hand))
         (etaf-value (plist-get session :hand-levels))
         (etaf-value (plist-get session :jokers))
         (if (and (not animating) sel)
             (float (or (plist-get (etaf-balatro--compute-preview session) :base-chips) 0))
           (float (or (etaf-value (plist-get session :display-chips)) 0)))))))
   (mult-target
    (etaf-computed
     (lambda ()
       (let ((animating (etaf-value (plist-get session :animating)))
             (sel (etaf-value (plist-get session :selected-ids))))
         (etaf-value (plist-get session :hand))
         (etaf-value (plist-get session :hand-levels))
         (etaf-value (plist-get session :jokers))
         (if (and (not animating) sel)
             (float (or (plist-get (etaf-balatro--compute-preview session) :base-mult) 0))
           (float (or (etaf-value (plist-get session :display-mult)) 0)))))))
   (chips-shown (etaf-transition chips-target :duration 0.16 :easing 'ease-out
                                 :name 'balatro-chips-roll))
   (mult-shown (etaf-transition mult-target :duration 0.16 :easing 'ease-out
                                :name 'balatro-mult-roll)))
  :render
  (let* ((animating (etaf-value (plist-get session :animating)))
         (sel (etaf-value (plist-get session :selected-ids)))
         (preview (when (and (not animating) sel)
                    (etaf-balatro--compute-preview session)))
         (hand-name (if preview (plist-get preview :hand-name)
                      (etaf-value (plist-get session :display-hand-name))))
         (hand-level (if preview (plist-get preview :level)
                       (etaf-value (plist-get session :display-hand-level))))
         (hand-score (if preview (plist-get preview :estimated-score)
                       (etaf-value (plist-get session :last-hand-score))))
         (preview-p (and preview (not animating)))
         (c-val (round (etaf-value chips-shown)))
         (m-val (etaf-balatro--round-mult (etaf-value mult-shown)))
         (title (if hand-name (format "牌型：%s" hand-name) "牌型：等待选牌"))
         (lvl-text (when hand-level (format "Lv.%d" hand-level))))
    (etaf-view
     (column :class "balatro-formula" :width 'stretch
             :padding card-pad :item-gap (if box-pad-v '(lh 1) '(lh 0))
             :background-color (plist-get tokens :balatro-surface)
             :border (list '(px 1) 'solid (plist-get tokens :balatro-chips-border))
       (flex :width 'stretch :justify-content 'space-between :align-items 'center
         (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
               (expr title))
         (expr
          (when lvl-text
            (etaf-view
             (box :padding-inline '(ch 1)
                  :background-color (plist-get tokens :balatro-chips-bg)
                  :color (plist-get tokens :balatro-chips-fg) :font-weight 'bold
               (text (expr lvl-text)))))))
       (flex :width 'stretch :align-items 'center :column-gap '(ch 1)
         (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                 :cross-align 'center
                 :padding (if box-pad-v '((lh 1) (ch 1)) '((lh 0) (ch 1)))
                 :background-color (plist-get tokens :balatro-chips-bg)
                 :border (list '(px 1) 'solid (plist-get tokens :balatro-chips-border))
           (text :color (plist-get tokens :balatro-chips-fg) "筹码")
           (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                 (expr (etaf-balatro--format-int c-val))))
         (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold "×")
         (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                 :cross-align 'center
                 :padding (if box-pad-v '((lh 1) (ch 1)) '((lh 0) (ch 1)))
                 :background-color (plist-get tokens :balatro-mult-bg)
                 :border (list '(px 1) 'solid (plist-get tokens :balatro-mult-border))
           (text :color (plist-get tokens :balatro-mult-fg) "倍率")
           (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                 (expr (etaf-balatro--format-mult m-val)))))
       (flex :width 'stretch :justify-content 'space-between :align-items 'center
             :padding-top (if box-pad-v '(lh 1) '(lh 0))
             :border-top (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
         (text :color (plist-get tokens :balatro-muted)
               (expr (if preview-p "含强化与小丑预计" "本手最终得分")))
         (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
               (expr (if (> (or hand-score 0) 0)
                         (format "+%s" (etaf-balatro--format-int hand-score))
                       "—"))))))))

;; ---------------------------------------------------------------------------
;; Left HUD Sidebar (36ch Wide — Generous Padding, Zero Orphan Wrapping)
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--sidebar (&key session tokens short-p compact-v-p medium-p tall-p extra-tall-p)
  "Render the responsive left HUD sidebar."
  :render
  (let* ((ante (etaf-value (plist-get session :ante)))
         (blind (etaf-value (plist-get session :blind)))
         (blind-name (etaf-value (plist-get session :blind-name)))
         (reward (etaf-value (plist-get session :blind-reward)))
         (boss-trait (etaf-value (plist-get session :boss-trait)))
         (next-spec (etaf-value (plist-get session :next-blind-spec)))
         (target (max 1 (etaf-value (plist-get session :target))))
         (score (etaf-value (plist-get session :score)))
         (hands-left (etaf-value (plist-get session :hands-left)))
         (discards-left (etaf-value (plist-get session :discards-left)))
         (money (etaf-value (plist-get session :money)))
         (draw-len (length (etaf-value (plist-get session :draw-pile))))
         (deck-len (length (etaf-value (plist-get session :deck))))
         (animating (etaf-value (plist-get session :animating)))
         (selected-ids (etaf-value (plist-get session :selected-ids)))
         (hand (etaf-value (plist-get session :hand)))
         (preview (when (and (not animating) selected-ids)
                    (etaf-balatro--compute-preview session)))
         (trace (etaf-value (plist-get session :trace)))
         (est-pass (and preview (>= (+ score (plist-get preview :estimated-score)) target)))
         (next-label
          (if next-spec
              (if (plist-get next-spec :boss-trait)
                  (format "Boss·%s" (plist-get (plist-get next-spec :boss-trait) :name))
                (format "%s %s" (plist-get next-spec :name)
                        (etaf-balatro--format-int (plist-get next-spec :target))))
            "终局"))
         (card-pad (if (or compact-v-p (not extra-tall-p)) '((lh 0) (ch 2)) '((lh 1) (ch 2))))
         (counter-pad (if extra-tall-p '((lh 1) (ch 2)) '((lh 0) (ch 2))))
         (trace-tail (let ((n (length trace))
                           (cap (cond (short-p 3) (compact-v-p 4) (tall-p 8) (t 5))))
                       (if (> n cap) (nthcdr (- n cap) trace) trace))))
    (ignore hand medium-p)
    (etaf-view
     (flex :class "balatro-sidebar" :flex-direction 'column
           :width '(% 24) :min-width '(ch 34) :max-width '(ch 50)
           :height 'stretch :flex-shrink 0
           :row-gap (if compact-v-p '(lh 0) '(lh 1))
       ;; 1. Blind Header Card
       (column :width 'stretch :padding card-pad :item-gap '(lh 0)
               :background-color (if (eq blind 'boss)
                                     (plist-get tokens :balatro-boss-bg)
                                   (plist-get tokens :balatro-gold-bg))
               :border (list '(px 1) 'solid
                             (if (eq blind 'boss)
                                 (plist-get tokens :balatro-boss-border)
                               (plist-get tokens :balatro-gold-border)))
         (text :color (if (eq blind 'boss)
                          (plist-get tokens :balatro-boss-fg)
                        (plist-get tokens :balatro-gold))
               :font-weight 'bold
               (expr (format "阶段 %d / 8 · %s" ante blind-name)))
         (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
               (expr (format "目标分数  %s" (etaf-balatro--format-int target))))
         (text :color (if boss-trait
                          (plist-get tokens :balatro-boss-fg)
                        (plist-get tokens :balatro-muted))
               (expr (if boss-trait
                         (format "词条：%s" (plist-get boss-trait :name))
                       (format "赏金 $%d · 下关 %s" reward next-label)))))

       ;; 2. Round Score Progress Card
       (column :width 'stretch :padding card-pad :item-gap '(lh 0)
               :background-color (plist-get tokens :balatro-surface)
               :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
         (flex :width 'stretch :justify-content 'space-between
           (text :color (plist-get tokens :balatro-muted) "本关累计得分")
           (text :color (plist-get tokens :balatro-green) :font-weight 'bold
                 (expr (format "%s / %s"
                               (etaf-balatro--format-int score)
                               (etaf-balatro--format-int target)))))
         (etaf-progress :value (min score target) :max target
                        :label "达成进度"
                        :variant 'success :animated t)
         (text :color (if est-pass (plist-get tokens :balatro-green)
                        (plist-get tokens :balatro-muted))
               :font-weight (if est-pass 'bold 'normal)
               (expr (cond
                      (est-pass
                       (format "本手预计 +%s → 可直接通关!"
                               (etaf-balatro--format-int (plist-get preview :estimated-score))))
                      (preview
                       (format "本手预计 +%s 分"
                               (etaf-balatro--format-int (plist-get preview :estimated-score))))
                      (t (format "距目标还差 %s 分"
                                 (etaf-balatro--format-int (max 0 (- target score)))))))))

       ;; 3. Formula Card (Chips x Mult)
       (etaf-balatro--formula-card :session session :tokens tokens
                                :card-pad card-pad :box-pad-v tall-p)

       ;; 4. 2x2 Counters (Generous vertical + horizontal breathing)
       (column :width 'stretch :item-gap (if short-p '(lh 0) '(lh 1))
         (flex :width 'stretch :column-gap '(ch 2)
           (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                   :padding counter-pad
                   :background-color (plist-get tokens :balatro-surface)
                   :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
             (text :color (plist-get tokens :balatro-muted) "剩余出牌")
             (text :color (plist-get tokens :balatro-chips-fg) :font-weight 'bold
                   (expr (format "%d 次" hands-left))))
           (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                   :padding counter-pad
                   :background-color (plist-get tokens :balatro-surface)
                   :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
             (text :color (plist-get tokens :balatro-muted) "剩余弃牌")
             (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold
                   (expr (format "%d 次" discards-left)))))
         (flex :width 'stretch :column-gap '(ch 2)
           (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                   :padding counter-pad
                   :background-color (plist-get tokens :balatro-surface)
                   :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
             (text :color (plist-get tokens :balatro-muted) "当前金币")
             (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                   (expr (format "$%d" money))))
           (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                   :padding counter-pad
                   :background-color (plist-get tokens :balatro-surface)
                   :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
             (text :color (plist-get tokens :balatro-muted) "剩余牌库")
             (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                   (expr (format "%d / %d" draw-len deck-len))))))

       ;; 5. Live Scoring Trace Card (expands to fill remaining sidebar height)
       (flex :flex-direction 'column :width 'stretch
             :flex-grow 1 :min-height '(lh 3)
             :padding card-pad :row-gap (if short-p '(lh 0) '(lh 1)) :overflow 'hidden
             :background-color (plist-get tokens :balatro-surface)
             :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
         (box :width 'stretch
              :border-bottom (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
           (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                 "连锁结算追踪"))
         (expr
          (if (null trace-tail)
              (etaf-view
               (box :width 'stretch :wrap-mode 'word
                 (text :color (plist-get tokens :balatro-dim)
                       "出牌后将逐张展示筹码与倍率触发明细")))
            (etaf-view
             (column :width 'stretch :item-gap '(lh 0)
               (expr
                (mapcar
                 (lambda (entry)
                   (let* ((idx (car entry))
                          (ev (cdr entry))
                          (col (pcase (plist-get ev :kind)
                                 ('joker (plist-get tokens :balatro-gold))
                                 ('held (plist-get tokens :balatro-steel))
                                 ('boss (plist-get tokens :balatro-boss-fg))
                                 (_ (if (> (or (plist-get ev :mult-factor) 1.0) 1.0)
                                        (plist-get tokens :balatro-glass)
                                      (plist-get tokens :balatro-chips-fg))))))
                     (etaf-view
                      (text :key idx :color col
                            (expr (format "▸ %s" (plist-get ev :detail)))))))
                 (cl-loop for ev in trace-tail for i from 0 collect (cons i ev)))))))))))))

(etaf-define-component etaf-balatro--narrow-hud (&key session tokens)
  "Compact 2-row top HUD used when viewport width < 114ch."
  :render
  (let* ((ante (etaf-value (plist-get session :ante)))
         (blind-name (etaf-value (plist-get session :blind-name)))
         (target (max 1 (etaf-value (plist-get session :target))))
         (score (etaf-value (plist-get session :score)))
         (hands-left (etaf-value (plist-get session :hands-left)))
         (discards-left (etaf-value (plist-get session :discards-left)))
         (money (etaf-value (plist-get session :money)))
         (animating (etaf-value (plist-get session :animating)))
         (selected-ids (etaf-value (plist-get session :selected-ids)))
         (preview (when (and (not animating) selected-ids)
                    (etaf-balatro--compute-preview session)))
         (c-val (if preview (plist-get preview :base-chips)
                  (etaf-value (plist-get session :display-chips))))
         (m-val (if preview (plist-get preview :base-mult)
                  (etaf-value (plist-get session :display-mult))))
         (h-name (or (and preview (plist-get preview :hand-name))
                     (etaf-value (plist-get session :display-hand-name))
                     "等待选牌")))
    (etaf-view
     (column :class "balatro-narrow-hud" :width 'stretch
             :padding '((lh 0) (ch 2)) :item-gap '(lh 0)
             :background-color (plist-get tokens :balatro-surface)
             :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
       (flex :width 'stretch :justify-content 'space-between :align-items 'center
         (row :item-gap '(ch 2)
           (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                 (expr (format "阶段 %d · %s" ante blind-name)))
           (text :color (plist-get tokens :balatro-green) :font-weight 'bold
                 (expr (format "%s / %s"
                               (etaf-balatro--format-int score)
                               (etaf-balatro--format-int target)))))
         (row :item-gap '(ch 2)
           (text :color (plist-get tokens :balatro-chips-fg) :font-weight 'bold
                 (expr (format "出 %d" hands-left)))
           (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold
                 (expr (format "弃 %d" discards-left)))
           (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                 (expr (format "$%d" money)))))
       (flex :width 'stretch :justify-content 'space-between :align-items 'center
         (row :item-gap '(ch 1)
           (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                 (expr h-name))
           (text :color (plist-get tokens :balatro-chips-fg) :font-weight 'bold
                 (expr (format "%d 筹" c-val)))
           (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold
                 (expr (format "× %s 倍" (etaf-balatro--format-mult m-val)))))
         (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
               (expr (if preview
                         (format "预计 +%s" (etaf-balatro--format-int
                                             (plist-get preview :estimated-score)))
                       (let ((last (etaf-value (plist-get session :last-hand-score))))
                         (if (> last 0)
                             (format "上手 +%s" (etaf-balatro--format-int last))
                           "1-8 选牌"))))))))))

;; ---------------------------------------------------------------------------
;; Joker Passive Bar & 2-Slot Planet/Tarot Consumables Tray
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--joker-bar (&key session tokens shop-mode narrow-p medium-p short-p extra-tall-p)
  "Render the 5-slot Joker bar and 2-slot Planet/Tarot consumables tray."
  :render
  (let* ((jokers (etaf-value (plist-get session :jokers)))
         (sel-idx (or (etaf-value (plist-get session :selected-joker-index)) 0))
         (active-uid (etaf-value (plist-get session :active-joker-uid)))
         (active-ev (etaf-value (plist-get session :active-event)))
         (consumables (etaf-value (plist-get session :consumables)))
         (animating (etaf-value (plist-get session :animating)))
         (compact-cons-p (or narrow-p medium-p))
         (panel-pad (if (and (or extra-tall-p shop-mode)
                             (not short-p) (not compact-cons-p))
                        '((lh 1) (ch 2))
                      '((lh 0) (ch 2))))
         (slot-h (if short-p '(lh 3) '(lh 5)))
         (slot-pad (if (or short-p compact-cons-p) '((lh 0) (ch 1)) '((lh 1) (ch 1))))
         (j-slots (cl-loop for i below etaf-balatro--max-jokers
                           collect (cons i (nth i jokers))))
         (c-slots (cl-loop for i below etaf-balatro--max-consumables
                           collect (cons i (nth i consumables)))))
    (etaf-view
     (flex :class "balatro-joker-row" :width 'stretch :flex-shrink 0
           :flex-direction (if compact-cons-p 'column 'row)
           :column-gap '(ch 2) :row-gap '(lh 0)
           :align-items 'stretch
       ;; Owned Jokers Container (5 proportional shares beside 2-share consumables)
       (column :flex-grow (if compact-cons-p 0 5)
               :flex-basis (if compact-cons-p 'auto '(ch 0))
               :min-width '(ch 0) :width (if compact-cons-p 'stretch 'auto)
               :padding panel-pad :item-gap '(lh 0)
               :background-color (plist-get tokens :balatro-surface)
               :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
         (flex :width 'stretch :justify-content 'space-between :align-items 'center
           (row :item-gap '(ch 2)
             (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                   (expr (format "小丑被动槽 (%d / %d)"
                                 (length jokers) etaf-balatro--max-jokers)))
             (text :if (not narrow-p) :color (plist-get tokens :balatro-dim)
                   (expr (cond
                          (medium-p (if shop-mode "[ , / . ] 调序 · [x] 卖" "[ , / . ] 调序"))
                          (shop-mode "[ , / . ] 调序 · [x] 卖出回血")
                          (t "从左到右结算 · [ , / . ] 调序（+倍率放 ×倍率左侧）")))))
           (row :if (and (> (length jokers) 0) (not animating))
                :item-gap '(ch 1)
             (etaf-button :if (> (length jokers) 1)
                          :ref 'balatro-joker-left :label "← 移" :variant 'ghost
                          :on-press (lambda () (etaf-balatro-move-joker session -1)))
             (etaf-button :if (> (length jokers) 1)
                          :ref 'balatro-joker-right :label "移 →" :variant 'ghost
                          :on-press (lambda () (etaf-balatro-move-joker session 1)))
             (etaf-button :if shop-mode
                          :ref 'balatro-joker-sell :label "出售 · x" :variant 'ghost
                          :color (plist-get tokens :balatro-mult-fg)
                          :on-press (lambda () (etaf-balatro-sell-joker session)))))
         (flex :width 'stretch :column-gap (if compact-cons-p '(ch 1) '(ch 2))
           (expr
            (mapcar
             (lambda (pair)
               (let* ((idx (car pair))
                      (joker (cdr pair)))
                 (if (null joker)
                     (etaf-view
                      (flex :flex-direction 'column :key (format "empty-%d" idx)
                            :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                            :height slot-h :align-items 'center :justify-content 'center
                            :background-color (plist-get tokens :balatro-empty-bg)
                            :border (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
                        (text :color (plist-get tokens :balatro-dim)
                              (expr (format "空槽 %d" (1+ idx))))))
                   (let* ((uid (plist-get joker :uid))
                          (pulsing (and active-uid (equal uid active-uid)))
                          (selected (and (not pulsing) (= idx sel-idx)))
                          (r-colors (etaf-balatro--rarity-colors
                                     tokens (plist-get joker :rarity)))
                          (bg (if pulsing (plist-get tokens :balatro-gold-bg)
                                (nth 0 r-colors)))
                          (border (cond
                                   (pulsing (plist-get tokens :balatro-gold-border))
                                   (selected (plist-get tokens :balatro-chips-border))
                                   (t (nth 1 r-colors))))
                          (tag-text (if pulsing
                                        (or (and active-ev (plist-get active-ev :tag)) "触发!")
                                      (if shop-mode
                                          (format "%s · 卖 $%d"
                                                  (etaf-balatro--rarity-label (plist-get joker :rarity))
                                                  (etaf-balatro--joker-sell-price joker))
                                        (format "槽 %d · %s" (1+ idx)
                                                (etaf-balatro--rarity-label
                                                 (plist-get joker :rarity)))))))
                     (etaf-view
                      (column :key uid :ref (intern (format "balatro-joker-%d" idx))
                              :role 'button :tab-index -1
                              :aria-label (format "小丑 %s：%s"
                                                  (plist-get joker :name)
                                                  (plist-get joker :desc))
                              :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                              :height slot-h :padding slot-pad :item-gap '(lh 0)
                              :background-color bg
                              :border (list '(px 1) 'solid border)
                              :pointer (unless (or selected pulsing animating) 'hand)
                              :on-press (let ((i idx))
                                          (lambda () (etaf-balatro-select-joker session i)))
                        (text :color (if pulsing (plist-get tokens :balatro-gold)
                                       (plist-get tokens :balatro-fg))
                              :font-weight 'bold
                              (expr (plist-get joker :name)))
                        (text :color (nth 2 r-colors)
                              (expr (etaf-balatro--joker-live-short joker)))
                        (text :color (if pulsing (plist-get tokens :balatro-gold)
                                       (plist-get tokens :balatro-dim))
                              :font-weight (if pulsing 'bold 'normal)
                              (expr tag-text))))))))
             j-slots))))

       ;; Wide 2-Slot Consumables Tray (2 proportional shares beside 5-share Jokers)
       (column :if (not compact-cons-p)
               :flex-grow 2 :flex-basis '(ch 0) :min-width '(ch 30)
               :padding panel-pad :item-gap '(lh 0)
               :background-color (plist-get tokens :balatro-surface)
               :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
         (text :color (plist-get tokens :balatro-cyan) :font-weight 'bold
               (expr (format "消耗品槽 (%d / %d)" (length consumables)
                             etaf-balatro--max-consumables)))
         (flex :width 'stretch :column-gap '(ch 2)
           (expr
            (mapcar
             (lambda (pair)
               (let* ((idx (car pair))
                      (item (cdr pair))
                      (key-lbl (if (= idx 0) "[u]" "[U]")))
                 (if (null item)
                     (etaf-view
                      (flex :flex-direction 'column :key (format "c-empty-%d" idx)
                            :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                            :height slot-h :align-items 'center :justify-content 'center
                            :background-color (plist-get tokens :balatro-empty-bg)
                            :border (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
                        (text :color (plist-get tokens :balatro-dim)
                              (expr (format "空槽 %d" (1+ idx))))))
                   (let* ((tarot-p (eq (plist-get item :kind) 'tarot))
                          (bg (if tarot-p (plist-get tokens :balatro-purple-bg)
                                (plist-get tokens :balatro-cyan-bg)))
                          (bdr (if tarot-p (plist-get tokens :balatro-purple-border)
                                 (plist-get tokens :balatro-cyan-border)))
                          (title-col (if tarot-p (plist-get tokens :balatro-purple)
                                       (plist-get tokens :balatro-cyan)))
                          (sub (if tarot-p
                                   (pcase (plist-get item :effect)
                                     ('destroy "销毁废牌")
                                     ('suit "转 ♥ 红桃")
                                     (_ (format "锻造%s"
                                                (plist-get (etaf-balatro--enhancement-info
                                                            (plist-get item :enhancement))
                                                           :name))))
                                 (format "%s升1级" (plist-get item :hand-name))))
                          (hint (if tarot-p
                                    (format "%s 选牌用" key-lbl)
                                  (format "%s 立即用" key-lbl))))
                     (etaf-view
                      (column :key (plist-get item :uid)
                              :ref (intern (format "balatro-consumable-%d" idx))
                              :role 'button :tab-index -1
                              :aria-label (format "使用消耗品 %s：%s"
                                                  (plist-get item :name)
                                                  (or (plist-get item :desc) ""))
                              :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                              :height slot-h :padding slot-pad :item-gap '(lh 0)
                              :background-color bg
                              :border (list '(px 1) 'solid bdr)
                              :pointer (unless animating 'hand)
                              :on-press (lambda () (etaf-balatro-use-consumable session idx))
                        (text :color title-col :font-weight 'bold
                              (expr (plist-get item :name)))
                        (text :color (plist-get tokens :balatro-fg) (expr sub))
                        (text :color (plist-get tokens :balatro-muted) (expr hint))))))))
             c-slots))))

       ;; Compact 1-Row Consumables Strip (in 126-col posframe & narrow windows)
       (flex :if compact-cons-p :width 'stretch :align-items 'center
             :justify-content 'space-between :padding '((lh 0) (ch 2)) :column-gap '(ch 2)
             :background-color (plist-get tokens :balatro-surface)
             :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
         (text :color (plist-get tokens :balatro-cyan) :font-weight 'bold
               (expr (format "消耗品 (%d/%d)" (length consumables)
                             etaf-balatro--max-consumables)))
         (row :item-gap '(ch 2) :cross-align 'center
           (expr
            (mapcar
             (lambda (pair)
               (let* ((idx (car pair))
                      (item (cdr pair))
                      (key-lbl (if (= idx 0) "[u]" "[U]")))
                 (if (null item)
                     (etaf-view
                      (text :key (format "c-mini-empty-%d" idx)
                            :color (plist-get tokens :balatro-dim)
                            (expr (format "%s 空槽" key-lbl))))
                   (let* ((tarot-p (eq (plist-get item :kind) 'tarot))
                          (bg (if tarot-p (plist-get tokens :balatro-purple-bg)
                                (plist-get tokens :balatro-cyan-bg)))
                          (bdr (if tarot-p (plist-get tokens :balatro-purple-border)
                                 (plist-get tokens :balatro-cyan-border)))
                          (fg (if tarot-p (plist-get tokens :balatro-purple)
                                (plist-get tokens :balatro-cyan))))
                     (etaf-view
                      (box :key (plist-get item :uid)
                           :ref (intern (format "balatro-consumable-%d" idx))
                           :role 'button :tab-index -1
                           :padding-inline '(ch 1)
                           :background-color bg
                           :color fg :font-weight 'bold
                           :border (list '(px 1) 'solid bdr)
                           :pointer (unless animating 'hand)
                           :on-press (lambda () (etaf-balatro-use-consumable session idx))
                        (text (expr (format "%s %s" key-lbl (plist-get item :name))))))))))
             c-slots))))))))

;; ---------------------------------------------------------------------------
;; Contextual Smart Coach Ribbon
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--coach-bar (&key session tokens)
  "Render the unobtrusive live Coach hint ribbon with a 1-click hide toggle."
  :render
  (let ((enabled (etaf-value (plist-get session :coach-enabled))))
    ;; Track live session refs so advice updates reactively on every move.
    (etaf-value (plist-get session :phase))
    (etaf-value (plist-get session :animating))
    (etaf-value (plist-get session :jokers))
    (etaf-value (plist-get session :hand))
    (etaf-value (plist-get session :selected-ids))
    (etaf-value (plist-get session :consumables))
    (etaf-value (plist-get session :discards-left))
    (etaf-value (plist-get session :score))
    (etaf-value (plist-get session :target))
    (etaf-value (plist-get session :money))
    (etaf-value (plist-get session :boss-trait))
    (etaf-value (plist-get session :hand-levels))
    (let ((hint (when enabled (etaf-balatro--session-coach-hint session))))
      (etaf-view
       (flex :if (and enabled hint) :class "balatro-coach-bar"
             :width 'stretch :align-items 'center :justify-content 'space-between
             :padding '((lh 0) (ch 2)) :column-gap '(ch 2) :flex-shrink 0
             :background-color (plist-get tokens :balatro-coach-bg)
             :border (list '(px 1) 'solid (plist-get tokens :balatro-coach-border))
         (flex :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
               :column-gap '(ch 1) :align-items 'center
           (box :flex-shrink 0
             (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                   "★ 实战提示:"))
           (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :wrap-mode 'word
             (text :color (plist-get tokens :balatro-fg) (expr hint))))
         (etaf-button :ref 'balatro-coach-hide-btn
                      :label "[G] 收起" :variant 'ghost
                      :on-press (lambda () (etaf-balatro-toggle-coach session))))))))

;; ---------------------------------------------------------------------------
;; Card Slot with Physical 1-Row Lift on Selection
;; ---------------------------------------------------------------------------

(defun etaf-balatro--card-face-lines (rank suit columns lines)
  "Return LINES fixed-width strings depicting RANK and SUIT across COLUMNS."
  (let* ((glyph (etaf-balatro--suit-glyph suit))
         (corner (concat (or rank "") " " glyph))
         (cw (string-width corner))
         (gw (string-width glyph))
         (blank (make-string columns ?\s))
         (rows (make-list lines blank)))
    (setcar rows (concat " " corner (make-string (max 0 (- columns 1 cw)) ?\s)))
    (when (> lines 2)
      (let* ((lpad (max 1 (/ (- columns gw) 2)))
             (rpad (max 0 (- columns lpad gw))))
        (setf (nth (/ lines 2) rows)
              (concat (make-string lpad ?\s) glyph (make-string rpad ?\s)))))
    (when (> lines 3)
      (let ((lpad (max 1 (- columns cw 1))))
        (setf (nth (1- lines) rows)
              (concat (make-string lpad ?\s) corner " "))))
    rows))

(etaf-define-component etaf-balatro--card-slot
    (&key card index selected active lift-p badge-text caption caption-color
          tokens card-cols card-lines card-pad-v disabled on-press ref)
  "Render one whole-surface clickable playing card with 1-row padding and lift."
  :render
  (let* ((rank (etaf-balatro--rank-label (plist-get card :rank)))
         (suit (plist-get card :suit))
         (enh (or (plist-get card :enhancement) 'none))
         (enh-short (plist-get (etaf-balatro--enhancement-info enh) :short))
         (sub-text (or caption
                       (if (and enh-short (not (string-empty-p enh-short)))
                           (format "%s · %s" (or index "") enh-short)
                         (or index ""))))
         (sub-color (or caption-color
                        (cond
                         (active (plist-get tokens :balatro-gold))
                         (selected (plist-get tokens :balatro-gold))
                         ((not (eq enh 'none)) (etaf-balatro--enh-color tokens enh))
                         (t (plist-get tokens :balatro-muted)))))
         (lit (or selected active))
         (ink (if (memq suit '(hearts diamonds))
                  (plist-get tokens :ui-playing-card-red)
                (plist-get tokens :ui-playing-card-black)))
         (card-face-bg (if lit
                           (plist-get tokens :ui-playing-card-selected-bg)
                         (plist-get tokens :ui-playing-card-bg)))
         (card-border (if lit
                          (plist-get tokens :ui-playing-card-selected-border)
                        (plist-get tokens :ui-playing-card-border)))
         (card-pad (if card-pad-v '((lh 1) (ch 1)) '((lh 0) (ch 0))))
         (interactive-p (and on-press (not disabled)))
         (face-rows (etaf-balatro--card-face-lines rank suit card-cols card-lines))
         (card-frame
          (etaf-view
           (box :ref ref
                :role (when interactive-p 'button)
                :tab-index (when interactive-p -1)
                :aria-label (format "%s%s" (etaf-balatro--card-label card)
                                    (if selected "（已选）" ""))
                :help-echo (when interactive-p
                             (format "%s（点击%s）"
                                     (etaf-balatro--card-label card)
                                     (if selected "取消选中" "选中")))
                :background-color card-face-bg
                :color ink
                :padding card-pad
                :border (list '(px 1) 'solid card-border)
                :pointer (when interactive-p 'hand)
                :hover-style (when (and interactive-p (not selected))
                               (list :background-color
                                     (plist-get tokens :ui-playing-card-hover-bg)
                                     :color ink))
                :on-press (when interactive-p on-press)
             (column :width (list 'ch card-cols) :item-gap '(lh 0)
               (text :for (row-idx (number-sequence 0 (1- card-lines)))
                     :key row-idx
                     :color ink
                     (expr (nth row-idx face-rows))))))))
    (if lift-p
        ;; Hand card slot: constant height (padded-card-height + 3).
        ;; Selected:   [▲ row] [Card] [1-row lift gap] [Caption]
        ;; Unselected: [empty] [empty] [Card]          [Caption]
        (etaf-view
         (column :cross-align 'center :item-gap '(lh 0)
           (box :height '(lh 1)
             (expr
              (when selected
                (etaf-view
                 (text :color (plist-get tokens :balatro-gold) :font-weight 'bold "▲")))))
           (box :if (not selected) :height '(lh 1))
           (expr card-frame)
           (box :if selected :height '(lh 1))
           (text :color sub-color
                 :font-weight (if selected 'bold 'normal)
                 (expr sub-text))))
      ;; Stage card slot: top active badge + card + bottom chip/enhancement caption
      (etaf-view
       (column :cross-align 'center :item-gap '(lh 0)
         (box :height '(lh 1)
           (expr
            (when badge-text
              (etaf-view
               (box :padding-inline '(ch 1)
                    :background-color (if active (plist-get tokens :balatro-mult-bg)
                                        (plist-get tokens :balatro-card))
                    :color (if active (plist-get tokens :balatro-gold)
                             (plist-get tokens :balatro-muted))
                    :font-weight 'bold
                 (text (expr badge-text)))))))
         (expr card-frame)
         (text :color sub-color
               :font-weight (if lit 'bold 'normal)
               (expr sub-text)))))))

;; ---------------------------------------------------------------------------
;; Scoring Cascade Stage & Hand Area
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--play-stage
    (&key session tokens card-cols card-lines card-pad-v short-p show-coach-p)
  "Render the center scoring stage showing played cards and Coach ribbon."
  :render
  (let* ((played (etaf-value (plist-get session :played-cards)))
         (animating (etaf-value (plist-get session :animating)))
         (active-cid (etaf-value (plist-get session :active-card-id)))
         (active-ev (etaf-value (plist-get session :active-event)))
         (step-idx (etaf-value (plist-get session :step-index)))
         (step-total (etaf-value (plist-get session :step-total)))
         (msg (etaf-value (plist-get session :message)))
         (boss-trait (etaf-value (plist-get session :boss-trait))))
    (etaf-view
     (flex :class "balatro-stage" :flex-direction 'column :width 'stretch
           :flex-grow 1 :min-height (if short-p '(lh 6) '(lh 10))
           :padding (if short-p '((lh 0) (ch 2)) '((lh 1) (ch 2)))
           :row-gap '(lh 0)
           :background-color (plist-get tokens :balatro-surface)
           :border (list '(px 1) 'solid
                         (if animating (plist-get tokens :balatro-green-border)
                           (plist-get tokens :balatro-border)))
       (flex :width 'stretch :justify-content 'space-between :align-items 'center
             :flex-shrink 0 :column-gap '(ch 2)
         (row :item-gap '(ch 2) :cross-align 'center
           (text :color (if animating (plist-get tokens :balatro-green)
                          (plist-get tokens :balatro-fg))
                 :font-weight 'bold
                 (expr (cond
                        (animating "出牌结算舞台 · 正在播放连锁计分 (按 SPC 立即完成)")
                        (played "出牌结算舞台 · 上手结算复盘")
                        (t "出牌结算舞台 · 准备出牌"))))
           (text :if (and played (not animating) (stringp msg) (not (string-empty-p msg)))
                 :color (plist-get tokens :balatro-gold)
                 (expr msg)))
         (text :color (if animating (plist-get tokens :balatro-gold)
                        (plist-get tokens :balatro-dim))
               :font-weight (if animating 'bold 'normal)
               (expr (if (> step-total 0)
                         (format "步骤 %d / %d" step-idx step-total)
                       (if boss-trait
                           (format "Boss：%s" (plist-get boss-trait :name))
                         "待命")))))
       (expr
        (if played
            (etaf-view
             (flex :width 'stretch :flex-grow 1
                   :align-items 'center :justify-content 'center :column-gap '(ch 3)
               (expr
                (mapcar
                 (lambda (card)
                   (let* ((cid (plist-get card :id))
                          (is-active (and active-cid (equal cid active-cid)))
                          (enh (or (plist-get card :enhancement) 'none))
                          (enh-short (plist-get (etaf-balatro--enhancement-info enh) :short))
                          (badge (when is-active
                                   (or (and active-ev (plist-get active-ev :tag)) "触发!")))
                          (cap (cond
                                (is-active (or (and active-ev (plist-get active-ev :tag)) "结算中"))
                                ((not (eq enh 'none)) (format "[%s]" enh-short))
                                (t (format "+%d 筹"
                                           (etaf-balatro--rank-chips (plist-get card :rank)))))))
                     (etaf-view
                      (etaf-balatro--card-slot
                       :key cid :card card
                       :active is-active
                       :badge-text badge
                       :caption cap
                       :caption-color (if is-active (plist-get tokens :balatro-gold)
                                        (etaf-balatro--enh-color tokens enh))
                       :tokens tokens
                       :card-cols card-cols :card-lines card-lines
                       :card-pad-v card-pad-v
                       :disabled t))))
                 played))))
          (etaf-view
           (flex :flex-direction 'column :width 'stretch :flex-grow 1
                 :align-items 'center :justify-content 'center :row-gap '(lh 1)
             (text :color (plist-get tokens :balatro-fg) :font-weight 'bold (expr msg))
             (box :width 'stretch :wrap-mode 'word :text-align 'center
               (text :color (plist-get tokens :balatro-muted)
                     "点击整张手牌或按 1-8 选牌（选中牌会上浮），按 RET 出牌 · 按 g 查看 60 秒新手指引"))))))
       (expr
        (when show-coach-p
          (etaf-view
           (etaf-balatro--coach-bar :session session :tokens tokens))))))))

(etaf-define-component etaf-balatro--hand-area
    (&key session tokens card-cols card-lines card-pad-v short-p narrow-p wide-gap-p)
  "Render the 8-card lifted interactive hand and action buttons."
  :render
  (let* ((hand (etaf-value (plist-get session :hand)))
         (selected-ids (etaf-value (plist-get session :selected-ids)))
         (sort-mode (etaf-value (plist-get session :sort-mode)))
         (animating (etaf-value (plist-get session :animating)))
         (discards (etaf-value (plist-get session :discards-left)))
         (coach-on (etaf-value (plist-get session :coach-enabled)))
         (records (etaf-value (plist-get session :records)))
         (best-ever (or (plist-get records :best-hand-score) 0))
         (wins (or (plist-get records :wins) 0))
         (can-play (and (not animating) (> (length selected-ids) 0)))
         (can-discard (and (not animating) (> (length selected-ids) 0) (> discards 0)))
         (btn-border (list '(px 1) 'solid (plist-get tokens :balatro-border-strong))))
    (etaf-view
     (column :class "balatro-hand-area" :width 'stretch :flex-shrink 0
             :padding (if short-p '((lh 0) (ch 2)) '((lh 1) (ch 2)))
             :item-gap '(lh 0)
             :background-color (plist-get tokens :balatro-surface)
             :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
       (flex :width 'stretch :justify-content 'space-between :align-items 'center
         (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
               (expr (format "手牌区 (已选 %d / 5 张 · 按数字 1-%d 选中或取消)"
                             (length selected-ids) (max 1 (length hand)))))
         (text :color (plist-get tokens :balatro-muted)
               (expr (format "排序：%s" (if (eq sort-mode 'rank) "按点数" "按花色")))))
       (flex :width 'stretch :justify-content 'center
             :column-gap (if wide-gap-p '(ch 2) '(ch 1))
         (expr
          (mapcar
           (lambda (pair)
             (let* ((idx (car pair))
                    (card (cdr pair))
                    (cid (plist-get card :id))
                    (sel (and (memq cid selected-ids) t))
                    (enh (or (plist-get card :enhancement) 'none))
                    (enh-short (plist-get (etaf-balatro--enhancement-info enh) :short))
                    (cap (if (and enh-short (not (string-empty-p enh-short)))
                             (format "%d · %s" (1+ idx) enh-short)
                           (number-to-string (1+ idx)))))
               (etaf-view
                (etaf-balatro--card-slot
                 :key cid
                 :ref (intern (format "balatro-hand-card-%d" idx))
                 :card card
                 :selected sel
                 :lift-p t
                 :caption cap
                 :tokens tokens
                 :card-cols card-cols :card-lines card-lines
                 :card-pad-v card-pad-v
                 :disabled animating
                 :on-press (lambda () (etaf-balatro-toggle-card session idx))))))
           (cl-loop for c in hand for i from 0 collect (cons i c)))))
       (flex :width 'stretch :justify-content 'space-between :align-items 'center
             :flex-wrap 'wrap :row-gap '(lh 0) :column-gap '(ch 2)
             :padding-top (if short-p '(lh 0) '(lh 1))
             :border-top (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
         (row :item-gap '(ch 1) :flex-shrink 0
           (etaf-button :ref 'balatro-play-btn
                        :label (if narrow-p "出牌" "出牌 · RET") :variant 'primary
                        :disabled (not can-play)
                        :on-press (lambda () (etaf-balatro-play-hand session)))
           (etaf-button :ref 'balatro-discard-btn
                        :label (if narrow-p "弃牌" "弃牌 · d") :variant 'secondary
                        :bgcolor (when can-discard (plist-get tokens :balatro-mult-bg))
                        :color (when can-discard (plist-get tokens :balatro-mult-fg))
                        :border (if can-discard
                                    (list '(px 1) 'solid (plist-get tokens :balatro-mult-border))
                                  (list '(px 1) 'solid (plist-get tokens :balatro-border-soft)))
                        :disabled (not can-discard)
                        :on-press (lambda () (etaf-balatro-discard session)))
           (etaf-button :ref 'balatro-sort-btn
                        :label (if narrow-p "排序" "切换排序 · s") :variant 'secondary
                        :border btn-border
                        :on-press (lambda () (etaf-balatro-cycle-sort session)))
           (etaf-button :ref 'balatro-deck-btn
                        :label (if narrow-p "牌库" "牌库矩阵 · v") :variant 'secondary
                        :border btn-border
                        :on-press (lambda () (etaf-balatro-toggle-modal session 'deck)))
           (etaf-button :ref 'balatro-hands-btn
                        :label (if narrow-p "牌型" "牌型表 · h") :variant 'secondary
                        :border btn-border
                        :on-press (lambda () (etaf-balatro-toggle-modal session 'hands))))
         (row :item-gap '(ch 2) :cross-align 'center
           (text :if (and (not narrow-p) (not short-p) (not animating))
                 :color (plist-get tokens :balatro-dim)
                 (expr (format "历史最高单手 %s · 胜场 %d"
                               (etaf-balatro--format-int best-ever) wins)))
           (etaf-button :if (and (not coach-on) (not short-p))
                        :ref 'balatro-coach-show-btn :label "提示 · G" :variant 'ghost
                        :on-press (lambda () (etaf-balatro-toggle-coach session)))
           (etaf-button :if animating
                        :ref 'balatro-skip-btn :label "跳过动画 · SPC" :variant 'primary
                        :on-press (lambda () (etaf-balatro-skip-animation session)))))))))

;; ---------------------------------------------------------------------------
;; Shop View (Spacious v2 Shelf + Tarot Sculpting + Mini 52-Card Deck Overview)
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--shop-view (&key session tokens narrow-p medium-p short-p extra-tall-p)
  "Render the post-blind shop matching the approved v2 design."
  :render
  (let* ((payout (etaf-value (plist-get session :last-payout)))
         (next-spec (etaf-value (plist-get session :next-blind-spec)))
         (shop (etaf-value (plist-get session :shop)))
         (money (etaf-value (plist-get session :money)))
         (deck (etaf-value (plist-get session :deck)))
         (records (etaf-value (plist-get session :records)))
         (msg (etaf-value (plist-get session :message)))
         (next-interest (min 5 (/ (max 0 money) 5)))
         (enhanced-cards (cl-remove-if
                          (lambda (c) (eq (plist-get c :enhancement) 'none))
                          deck))
         (tight (or short-p medium-p))
         (card-pad (if tight '((lh 0) (ch 1)) '((lh 1) (ch 2))))
         (left-col
          (etaf-view
           (flex :flex-direction 'column
                 :width (if narrow-p 'stretch '(% 24))
                 :min-width (unless narrow-p '(ch 34))
                 :max-width (unless narrow-p '(ch 50))
                 :height (if narrow-p 'auto 'stretch) :flex-shrink 0
                 :row-gap (if short-p '(lh 0) '(lh 1))
             ;; 1. Payout Summary
             (column :width 'stretch :padding card-pad :item-gap '(lh 0)
                     :background-color (plist-get tokens :balatro-green-bg)
                     :border (list '(px 1) 'solid (plist-get tokens :balatro-green-border))
               (text :color (plist-get tokens :balatro-green) :font-weight 'bold
                     (expr (format "✓ 阶段 %d · %s 已通关"
                                   (or (plist-get payout :ante) 1)
                                   (or (plist-get payout :blind-name) "盲注"))))
               (text :color (plist-get tokens :balatro-fg)
                     (expr (format "赏金 $%d + 余手 $%d + 利息 $%d"
                                   (or (plist-get payout :reward) 0)
                                   (or (plist-get payout :hand-bonus) 0)
                                   (or (plist-get payout :interest) 0))))
               (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                     (expr (format "本关入账 +$%d · 现持有 $%d"
                                   (or (plist-get payout :total) 0) money))))
             ;; 2. Next Blind Preview
             (column :if next-spec :width 'stretch :padding card-pad :item-gap '(lh 0)
                     :background-color (if (plist-get next-spec :boss-trait)
                                           (plist-get tokens :balatro-boss-bg)
                                         (plist-get tokens :balatro-gold-bg))
                     :border (list '(px 1) 'solid
                                   (if (plist-get next-spec :boss-trait)
                                       (plist-get tokens :balatro-boss-border)
                                     (plist-get tokens :balatro-gold-border)))
               (text :color (if (plist-get next-spec :boss-trait)
                                (plist-get tokens :balatro-boss-fg)
                              (plist-get tokens :balatro-gold))
                     :font-weight 'bold
                     (expr (format "下一关：阶段 %d · %s"
                                   (plist-get next-spec :ante)
                                   (plist-get next-spec :name))))
               (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                     (expr (format "目标分数  %s"
                                   (etaf-balatro--format-int (plist-get next-spec :target)))))
               (box :width 'stretch :wrap-mode 'word
                 (text :color (if (plist-get next-spec :boss-trait)
                                  (plist-get tokens :balatro-boss-fg)
                                (plist-get tokens :balatro-muted))
                       (expr (if-let* ((bt (plist-get next-spec :boss-trait)))
                                 (format "Boss 词条「%s」：%s"
                                         (plist-get bt :name) (plist-get bt :desc))
                               (format (if tight "通关赏金 $%d · 强化构筑"
                                         "通关赏金 $%d · 提前构筑小丑与塔罗")
                                       (plist-get next-spec :reward)))))))
             ;; 3. Economy 2-col Counters
             (flex :width 'stretch :column-gap '(ch 2)
               (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                       :padding card-pad
                       :background-color (plist-get tokens :balatro-surface)
                       :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
                 (text :color (plist-get tokens :balatro-muted) "当前金币")
                 (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                       (expr (format "$%d" money))))
               (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                       :padding card-pad
                       :background-color (plist-get tokens :balatro-surface)
                       :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
                 (text :color (plist-get tokens :balatro-muted) "下关利息")
                 (text :color (plist-get tokens :balatro-green) :font-weight 'bold
                       (expr (format "+$%d (每 $5)" next-interest)))))
             ;; 4. Mini 52-Card Deck Overview & Lifetime Records
             (flex :flex-direction 'column :width 'stretch
                   :flex-grow (if narrow-p 0 1) :min-height '(lh 9)
                   :padding card-pad :row-gap '(lh 1) :overflow 'hidden
                   :background-color (plist-get tokens :balatro-surface)
                   :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
               (flex :width 'stretch :justify-content 'space-between :align-items 'center
                 (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                       (expr (format "完整牌库速览 (%d 张)" (length deck))))
                 (etaf-button :ref 'balatro-shop-deck-mini :label "[v] 矩阵" :variant 'ghost
                              :on-press (lambda () (etaf-balatro-toggle-modal session 'deck))))
               (column :width 'stretch :item-gap '(lh 0)
                 (expr
                  (mapcar
                   (lambda (suit)
                     (let* ((cnt (cl-count suit deck :key (lambda (c) (plist-get c :suit))))
                            (cells (etaf-balatro--deck-matrix-row suit deck nil nil))
                            (row-str (mapconcat (lambda (c) (plist-get c :label)) cells " ")))
                       (etaf-view
                        (flex :key suit :width 'stretch :column-gap '(ch 1)
                          (box :flex-shrink 0
                            (text :color (etaf-balatro--suit-color tokens suit) :font-weight 'bold
                                  (expr (format "%s %2d" (etaf-balatro--suit-glyph suit) cnt))))
                          (text :color (plist-get tokens :balatro-muted)
                                (expr row-str))))))
                   '(spades hearts diamonds clubs))))
               (column :width 'stretch :item-gap '(lh 0)
                       :padding-top '(lh 1)
                       :border-top (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
                 (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                       (expr (format "已锻造强化牌 (%d 张)" (length enhanced-cards))))
                 (box :width 'stretch :wrap-mode 'word
                   (text :color (plist-get tokens :balatro-muted)
                         (expr (if enhanced-cards
                                   (mapconcat
                                    (lambda (c)
                                      (format "%s [%s]"
                                              (etaf-balatro--card-label c)
                                              (plist-get (etaf-balatro--enhancement-info
                                                          (plist-get c :enhancement))
                                                         :short)))
                                    (cl-subseq enhanced-cards 0 (min 4 (length enhanced-cards)))
                                    " · ")
                                 "暂无（买右方塔罗卡带进战斗定向锻造）")))))
               (column :if (not short-p) :width 'stretch :item-gap '(lh 0)
                       :padding-top '(lh 1)
                       :border-top (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
                 (text :color (plist-get tokens :balatro-dim)
                       (expr (format "最高 %s · %d 胜 · 最佳 %d/8"
                                     (etaf-balatro--format-int (or (plist-get records :best-hand-score) 0))
                                     (or (plist-get records :wins) 0)
                                     (or (plist-get records :best-ante) 1)))))))))
         (right-col
          (etaf-view
           (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                 :height (if narrow-p 'auto 'stretch) :row-gap (if short-p '(lh 0) '(lh 1))
             ;; Owned Jokers + Consumables Tray
             (etaf-balatro--joker-bar :session session :tokens tokens
                                   :shop-mode t :narrow-p narrow-p
                                   :medium-p medium-p :short-p short-p
                                   :extra-tall-p extra-tall-p)
             ;; Smart Coach Bar in Shop
             (expr
              (unless short-p
                (etaf-view (etaf-balatro--coach-bar :session session :tokens tokens))))
             ;; Main Shop Shelf Showcase
             (flex :flex-direction 'column :width 'stretch
                   :flex-grow (if narrow-p 0 1) :min-height '(lh 10)
                   :padding (if short-p '((lh 0) (ch 2)) '((lh 1) (ch 2)))
                   :row-gap (if short-p '(lh 0) '(lh 1))
                   :background-color (plist-get tokens :balatro-surface)
                   :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
               (flex :width 'stretch :justify-content 'space-between :align-items 'center
                     :flex-shrink 0
                 (row :item-gap '(ch 2)
                   (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                         "本关商店货架")
                   (text :color (plist-get tokens :balatro-muted) (expr msg)))
                 (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                       (expr (format "持有金币 $%d" money))))
               (flex :width 'stretch :flex-grow 1 :min-height '(lh 7)
                     :align-items 'stretch :column-gap '(ch 2)
                 (expr
                  (mapcar
                   (lambda (pair)
                     (let* ((idx (car pair))
                            (item (cdr pair))
                            (sold (plist-get item :sold))
                            (cost (plist-get item :cost))
                            (kind (plist-get item :kind))
                            (can-buy (and (not sold) (>= money cost)))
                            (card-bg (pcase kind
                                       ('planet (plist-get tokens :balatro-cyan-bg))
                                       ('tarot (plist-get tokens :balatro-purple-bg))
                                       (_ (plist-get tokens :balatro-card))))
                            (accent (pcase kind
                                      ('planet (plist-get tokens :balatro-cyan-border))
                                      ('tarot (plist-get tokens :balatro-purple-border))
                                      (_ (if (eq (plist-get item :rarity) 'rare)
                                             (plist-get tokens :balatro-purple-border)
                                           (plist-get tokens :balatro-border-strong)))))
                            (badge-bg (pcase kind
                                        ('planet (plist-get tokens :balatro-surface))
                                        ('tarot (plist-get tokens :balatro-surface))
                                        (_ (plist-get tokens :balatro-chips-bg))))
                            (badge-fg (pcase kind
                                        ('planet (plist-get tokens :balatro-cyan))
                                        ('tarot (plist-get tokens :balatro-purple))
                                        (_ (if (eq (plist-get item :rarity) 'rare)
                                               (plist-get tokens :balatro-purple)
                                             (plist-get tokens :balatro-chips-fg)))))
                            (type-label (if tight
                                            (pcase kind
                                              ('planet "行星")
                                              ('tarot "塔罗")
                                              (_ "小丑"))
                                          (pcase kind
                                            ('planet "行星 · 升级")
                                            ('tarot "塔罗 · 锻造")
                                            (_ (format "小丑 · %s"
                                                       (etaf-balatro--rarity-label
                                                        (plist-get item :rarity)))))))
                            (btn-label (cond
                                        (sold "已售罄")
                                        (tight (format "[%d] $%d" (1+ idx) cost))
                                        ((eq kind 'planet) (format "[%d] 立即升级 · $%d" (1+ idx) cost))
                                        ((eq kind 'tarot) (format "[%d] 收入槽位 · $%d" (1+ idx) cost))
                                        (t (format "[%d] 购买 · $%d" (1+ idx) cost)))))
                       (etaf-view
                        (flex :key (plist-get item :uid)
                              :ref (intern (format "balatro-shop-buy-%d" idx))
                              :role (when can-buy 'button)
                              :tab-index (when can-buy -1)
                              :aria-label (format "%s（%s）" (plist-get item :name) btn-label)
                              :help-echo (when can-buy (format "点击购买 %s（$%d）"
                                                               (plist-get item :name) cost))
                              :pointer (when can-buy 'hand)
                              :on-press (when can-buy
                                          (lambda () (etaf-balatro-buy-shop-item session idx)))
                              :flex-direction 'column
                              :justify-content 'space-between
                              :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                              :padding (if tight '((lh 0) (ch 1)) '((lh 1) (ch 2)))
                              :row-gap (if tight '(lh 0) '(lh 1))
                              :background-color (if sold (plist-get tokens :balatro-empty-bg) card-bg)
                              :border (list '(px 1) 'solid
                                            (if sold (plist-get tokens :balatro-border-soft) accent))
                          (column :width 'stretch :item-gap '(lh 1)
                            (flex :width 'stretch :justify-content 'space-between :align-items 'center
                              (box :padding-inline '(ch 1)
                                   :background-color badge-bg
                                   :color badge-fg :font-weight 'bold
                                (text (expr type-label)))
                              (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                                    (expr (format "$%d" cost))))
                            (column :width 'stretch :item-gap '(lh 0)
                              (text :color (if sold (plist-get tokens :balatro-dim)
                                             (plist-get tokens :balatro-fg))
                                    :font-weight 'bold
                                    (expr (plist-get item :name)))
                              (box :width 'stretch :wrap-mode 'word
                                (text :color badge-fg :font-weight 'bold
                                      (expr (plist-get item :short)))))
                            (box :width 'stretch :wrap-mode 'word
                              (text :color (plist-get tokens :balatro-muted)
                                    (expr (plist-get item :desc)))))
                          (box :width 'stretch :padding '((lh 0) (ch 1)) :text-align 'center
                               :background-color (cond
                                                  ((and can-buy (= idx 0))
                                                   (plist-get tokens :ui-button-primary-bg))
                                                  (can-buy
                                                   (plist-get tokens :balatro-card-alt))
                                                  (t (plist-get tokens :balatro-surface)))
                               :color (cond
                                       ((and can-buy (= idx 0))
                                        (plist-get tokens :ui-button-primary-fg))
                                       (can-buy (plist-get tokens :balatro-fg))
                                       (t (plist-get tokens :balatro-dim)))
                               :font-weight (if can-buy 'bold 'normal)
                               :border (list '(px 1) 'solid
                                             (cond
                                              ((and can-buy (= idx 0))
                                               (plist-get tokens :ui-button-primary-bg))
                                              (can-buy (plist-get tokens :balatro-border-strong))
                                              (t (plist-get tokens :balatro-border-soft))))
                            (text (expr btn-label)))))))
                   (cl-loop for it in shop for i from 0 collect (cons i it)))))
               ;; Bottom Action Bar
               (flex :width 'stretch :justify-content 'space-between :align-items 'center
                     :flex-wrap 'wrap :row-gap '(lh 0) :column-gap '(ch 2)
                     :flex-shrink 0
                     :padding-top (if short-p '(lh 0) '(lh 1))
                     :border-top (list '(px 1) 'solid (plist-get tokens :balatro-border-soft))
                 (row :item-gap '(ch 1) :flex-shrink 0
                   (etaf-button :ref 'balatro-reroll-btn
                                :label "刷新货架 · r ($5)" :variant 'secondary
                                :border (list '(px 1) 'solid (plist-get tokens :balatro-border-strong))
                                :disabled (< money 5)
                                :on-press (lambda () (etaf-balatro-reroll-shop session)))
                   (etaf-button :ref 'balatro-shop-hands-btn
                                :label "牌型表 · h" :variant 'secondary
                                :border (list '(px 1) 'solid (plist-get tokens :balatro-border-strong))
                                :on-press (lambda () (etaf-balatro-toggle-modal session 'hands)))
                   (etaf-button :ref 'balatro-shop-deck-btn
                                :label "牌库矩阵 · v" :variant 'secondary
                                :border (list '(px 1) 'solid (plist-get tokens :balatro-border-strong))
                                :on-press (lambda () (etaf-balatro-toggle-modal session 'deck))))
                 (etaf-button :ref 'balatro-next-blind-btn
                              :label "进入下一关 · RET →" :variant 'primary
                              :bgcolor (plist-get tokens :balatro-green-bg)
                              :color (plist-get tokens :balatro-green)
                              :border (list '(px 1) 'solid (plist-get tokens :balatro-green-border))
                              :on-press (lambda () (etaf-balatro-next-blind session)))))))))
    (if narrow-p
        (etaf-view
         (column :width 'stretch :item-gap '(lh 1)
           (expr left-col)
           (expr right-col)))
      (etaf-view
       (flex :width 'stretch :flex-grow 1
             :column-gap (if medium-p '(ch 2) '(ch 3)) :align-items 'stretch
         (expr left-col)
         (expr right-col))))))

;; ---------------------------------------------------------------------------
;; Victory / Game Over Screen (With Lifetime Records)
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--end-view (&key session tokens)
  "Render the Victory or Game Over summary screen with persistent records."
  :render
  (let* ((phase (etaf-value (plist-get session :phase)))
         (win-p (eq phase 'victory))
         (ante (etaf-value (plist-get session :ante)))
         (best (etaf-value (plist-get session :best-hand-score)))
         (best-name (etaf-value (plist-get session :best-hand-name)))
         (played (etaf-value (plist-get session :hands-played)))
         (seed (etaf-value (plist-get session :seed)))
         (records (etaf-value (plist-get session :records)))
         (msg (etaf-value (plist-get session :message))))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :flex-grow 1
           :padding '((lh 2) (ch 3))
           :align-items 'center :justify-content 'center
       (column :width '(% 64) :min-width '(ch 56) :max-width '(% 92)
               :padding '((lh 2) (ch 3)) :item-gap '(lh 1)
               :background-color (if win-p (plist-get tokens :balatro-green-bg)
                                   (plist-get tokens :balatro-boss-bg))
               :border (list '(px 1) 'solid
                             (if win-p (plist-get tokens :balatro-green-border)
                               (plist-get tokens :balatro-boss-border)))
         (text :color (if win-p (plist-get tokens :balatro-green)
                        (plist-get tokens :balatro-boss-fg))
               :font-weight 'bold
               (expr (if win-p "✓ 通关胜利 · 8 阶段全制霸!" "本局结束 · 出牌机会耗尽")))
         (box :width 'stretch :wrap-mode 'word
           (text :color (plist-get tokens :balatro-fg) (expr msg)))
         (flex :width 'stretch :justify-content 'space-between
           (text :color (plist-get tokens :balatro-muted)
                 (expr (format "到达阶段：%d / 8" ante)))
           (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                 (expr (format "本局最高单手：%s%s"
                               (etaf-balatro--format-int best)
                               (if (string-empty-p best-name) "" (format " (%s)" best-name)))))
           (text :color (plist-get tokens :balatro-muted)
                 (expr (format "出牌 %d 次 · #%d" played seed))))
         (flex :width 'stretch :justify-content 'space-between
               :border-top (list '(px 1) 'solid (plist-get tokens :balatro-border))
           (text :color (plist-get tokens :balatro-muted)
                 (expr (format "历史开局 %d 次 · 通关 %d 胜"
                               (or (plist-get records :runs-played) 0)
                               (or (plist-get records :wins) 0))))
           (text :color (plist-get tokens :balatro-cyan)
                 (expr (format "历史最高：%s 分 · 最佳阶段 %d / 8"
                               (etaf-balatro--format-int (or (plist-get records :best-hand-score) 0))
                               (or (plist-get records :best-ante) 1)))))
         (row :item-gap '(ch 2)
           (etaf-button :ref 'balatro-end-restart :label "再来一局 · N" :variant 'primary
                        :on-press (lambda () (etaf-balatro-restart session)))
           (etaf-button :ref 'balatro-end-replay :label "同种子重开" :variant 'secondary
                        :on-press (lambda () (etaf-balatro-restart session seed)))
           (etaf-button :ref 'balatro-end-guide :label "重看新手指引 · g" :variant 'ghost
                        :on-press (lambda () (etaf-balatro-open-guide session 0)))))))))

;; ---------------------------------------------------------------------------
;; 4-Step Interactive Beginner Onboarding Guide Body
;; ---------------------------------------------------------------------------

(defun etaf-balatro--guide-page-body (step tokens)
  "Return the ETAF View body for 0-based onboarding guide STEP."
  (pcase step
    (0
     (etaf-view
      (column :width 'stretch :item-gap '(lh 1)
        (column :width 'stretch :item-gap '(lh 0)
          (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                "一局怎么赢？只要记住一个核心公式!")
          (box :width 'stretch :wrap-mode 'word
            (text :color (plist-get tokens :balatro-muted)
                  "每关你有 4 次出牌机会，凑出扑克牌型得分；本关累计分达到「目标分数」就过关进商店，连闯 8 个阶段通关！")))
        ;; Visual Chips x Mult = Total diagram
        (column :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                :background-color (plist-get tokens :balatro-card)
                :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
          (text :color (plist-get tokens :balatro-muted)
                "单手得分公式（游戏自动实时帮你算，选牌时左侧立即预判）")
          (flex :width 'stretch :align-items 'center :column-gap '(ch 1)
            (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                    :cross-align 'center :padding '((lh 0) (ch 1))
                    :background-color (plist-get tokens :balatro-chips-bg)
                    :border (list '(px 1) 'solid (plist-get tokens :balatro-chips-border))
              (text :color (plist-get tokens :balatro-chips-fg) :font-weight 'bold "筹码 (Chips)")
              (text :color (plist-get tokens :balatro-muted) "牌型底分 + 牌面点数"))
            (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold "×")
            (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                    :cross-align 'center :padding '((lh 0) (ch 1))
                    :background-color (plist-get tokens :balatro-mult-bg)
                    :border (list '(px 1) 'solid (plist-get tokens :balatro-mult-border))
              (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold "倍率 (Mult)")
              (text :color (plist-get tokens :balatro-muted) "牌型倍率 + 小丑放大"))
            (text :color (plist-get tokens :balatro-gold) :font-weight 'bold "=")
            (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                    :cross-align 'center :padding '((lh 0) (ch 1))
                    :background-color (plist-get tokens :balatro-gold-bg)
                    :border (list '(px 1) 'solid (plist-get tokens :balatro-gold-border))
              (text :color (plist-get tokens :balatro-gold) :font-weight 'bold "本手总分")
              (text :color (plist-get tokens :balatro-muted) "前期数百 → 成型破万!"))))
        ;; Worked real example
        (column :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                :background-color (plist-get tokens :balatro-card)
                :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
          (text :color (plist-get tokens :balatro-green) :font-weight 'bold
                "举个真实算例：打出「对子 6 ♥ + 6 ♣」且拥有开局小丑「贪婪红心」")
          (text :color (plist-get tokens :balatro-fg)
                "1. 基础牌型「对子 Lv.1」自带：10 筹码 × 2 倍率")
          (text :color (plist-get tokens :balatro-fg)
                "2. 两张牌依次触发：6 ♥ (+6 筹) → 触发贪婪红心 (+4 倍!) → 6 ♣ (+6 筹)")
          (box :width 'stretch :wrap-mode 'word
            (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                  "3. 最终：(10 + 6 + 6) × (2 + 4) = 22 × 6 = 132 分！（首关 300 分仅需 2-3 手）")))
        (box :width 'stretch :wrap-mode 'word
          (text :color (plist-get tokens :balatro-dim)
                "提示：完全不用死记扑克牌型！随时按 h 查牌型表，局内「实战智能提示」也会带你打完第一关。")))))
    (1
     (etaf-view
      (column :width 'stretch :item-gap '(lh 1)
        (column :width 'stretch :item-gap '(lh 0)
          (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                "三步掌握每回合操作：选牌 → 弃牌换牌 → 连锁出牌")
          (box :width 'stretch :wrap-mode 'word
            (text :color (plist-get tokens :balatro-muted)
                  "每回合你会拿到 8 张手牌，从中挑选 1 到 5 张组成最强牌型（对子、两对、三条、顺子、同花、葫芦等）。")))
        (flex :width 'stretch :column-gap '(ch 2) :align-items 'stretch
          (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                  :background-color (plist-get tokens :balatro-card)
                  :border (list '(px 1) 'solid (plist-get tokens :balatro-chips-border))
            (text :color (plist-get tokens :balatro-chips-fg) :font-weight 'bold "① 按 1-8 选牌")
            (box :width 'stretch :wrap-mode 'word
              (text :color (plist-get tokens :balatro-fg)
                    "点击或按数字 1-8 选中手牌，选中的牌会向上浮起 1 行，左侧立刻显示牌型和预计总分。")))
          (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                  :background-color (plist-get tokens :balatro-card)
                  :border (list '(px 1) 'solid (plist-get tokens :balatro-mult-border))
            (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold "② s 排序 · d 弃牌")
            (box :width 'stretch :wrap-mode 'word
              (text :color (plist-get tokens :balatro-fg)
                    "按 s 在「按点数 / 按花色」间切换找顺子或同花；牌太散时选中废牌按 d 弃牌换新牌！")))
          (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                  :background-color (plist-get tokens :balatro-card)
                  :border (list '(px 1) 'solid (plist-get tokens :balatro-green-border))
            (text :color (plist-get tokens :balatro-green) :font-weight 'bold "③ RET 出牌 · SPC 跳")
            (box :width 'stretch :wrap-mode 'word
              (text :color (plist-get tokens :balatro-fg)
                    "按 RET 出牌欣赏逐张爆发连锁；想提速可随时按 SPC 立即完成，或右上切 2× / 4× 倍速。"))))
        (column :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                :background-color (plist-get tokens :balatro-coach-bg)
                :border (list '(px 1) 'solid (plist-get tokens :balatro-coach-border))
          (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                "小技巧：把牌湊成「同花」或「两对」为什么比单出高牌强很多？")
          (box :width 'stretch :wrap-mode 'word
            (text :color (plist-get tokens :balatro-fg)
                  "高牌只结算最大的 1 张牌，而同花/顺子/葫芦 5 张牌全部参与计分，还能连吃 5 次花色或点数小丑加成！"))))))
    (2
     (etaf-view
      (column :width 'stretch :item-gap '(lh 1)
        (column :width 'stretch :item-gap '(lh 0)
          (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                "从几百分飙到几万分的秘诀：小丑摆位 + 定向塔罗锻造")
          (text :color (plist-get tokens :balatro-muted)
                "上方小丑槽按严格从左到右的顺序结算！永远把「+倍率」放在「×倍率」左侧："))
        ;; Joker order comparison
        (flex :width 'stretch :column-gap '(ch 2) :align-items 'stretch
          (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                  :background-color (plist-get tokens :balatro-mult-bg)
                  :border (list '(px 1) 'solid (plist-get tokens :balatro-mult-border))
            (text :color (plist-get tokens :balatro-mult-fg) :font-weight 'bold
                  "✗ 顺序摆反：[×2 倍] → [+8 倍]")
            (box :width 'stretch :wrap-mode 'word
              (text :color (plist-get tokens :balatro-fg)
                    "基础 2 倍先乘 2 再加 8 = 12 倍")))
          (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                  :background-color (plist-get tokens :balatro-green-bg)
                  :border (list '(px 1) 'solid (plist-get tokens :balatro-green-border))
            (text :color (plist-get tokens :balatro-green) :font-weight 'bold
                  "✓ 正确摆位：[+8 倍] → [×2 倍]")
            (box :width 'stretch :wrap-mode 'word
              (text :color (plist-get tokens :balatro-fg)
                    "基础 2 倍先加 8 再乘 2 = 20 倍（白赚 +67%！）"))))
        (column :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                :background-color (plist-get tokens :balatro-card)
                :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
          (text :color (plist-get tokens :balatro-purple) :font-weight 'bold
                "右上角消耗品槽：行星牌 [u] vs 定向塔罗牌 [u / U]")
          (box :width 'stretch :wrap-mode 'word
            (text :color (plist-get tokens :balatro-fg)
                  "• 行星牌（青色）：随时按 u 立即使用，永久升级对应牌型的基础筹码与倍率。"))
          (box :width 'stretch :wrap-mode 'word
            (text :color (plist-get tokens :balatro-fg)
                  "• 塔罗牌（紫色）：牌局中先按 1-8 选中目标手牌，再按 u / U 定向施放！"))
          (box :width 'stretch :wrap-mode 'word
            (text :color (plist-get tokens :balatro-muted)
                  "  玻璃 (×2倍) · 钢铁 (留手×1.5倍) · 倍率 (+4倍) · 奖励 (+30筹) · 太阳 (转♥红桃) · 倒吊人 (销毁废牌)")))
        (box :width 'stretch :wrap-mode 'word
          (text :color (plist-get tokens :balatro-dim)
                "小贴士：选中上方任意小丑后按 [ , / . ] 即可左右调换顺序；若摆反了，实战提示会主动提醒你。")))))
    (_
     (etaf-view
      (column :width 'stretch :item-gap '(lh 1)
        (column :width 'stretch :item-gap '(lh 0)
          (text :color (plist-get tokens :balatro-fg) :font-weight 'bold
                "商店运营、复利利息与高频快捷键速查")
          (text :color (plist-get tokens :balatro-muted)
                "打赢每一关进入商店强化构筑；每阶段第 3 关是带特殊词条的 Boss 盲注！"))
        (flex :width 'stretch :column-gap '(ch 2) :align-items 'stretch
          (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                  :background-color (plist-get tokens :balatro-gold-bg)
                  :border (list '(px 1) 'solid (plist-get tokens :balatro-gold-border))
            (text :color (plist-get tokens :balatro-gold) :font-weight 'bold "金币与复利利息")
            (box :width 'stretch :wrap-mode 'word
              (text :color (plist-get tokens :balatro-fg)
                    "过关获赏金 ($3/$4/$5) + 剩余出牌数 ($1/次) + 利息（每攒 $5 下关多给 $1，最高 +$5）。留 $25 最稳！")))
          (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                  :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                  :background-color (plist-get tokens :balatro-boss-bg)
                  :border (list '(px 1) 'solid (plist-get tokens :balatro-boss-border))
            (text :color (plist-get tokens :balatro-boss-fg) :font-weight 'bold "Boss 盲注应对")
            (box :width 'stretch :wrap-mode 'word
              (text :color (plist-get tokens :balatro-fg)
                    "商店左侧会提前预告下一关 Boss 词条（如红桃封锁 / 满编五张 / 零弃牌令），方便你提前换小丑或改花色。"))))
        (column :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 0)
                :background-color (plist-get tokens :balatro-card)
                :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
          (text :color (plist-get tokens :balatro-cyan) :font-weight 'bold "常用快捷键一览（全部按钮也可直接鼠标点击）")
          (flex :width 'stretch :column-gap '(ch 3)
            (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :item-gap '(lh 0)
              (text :color (plist-get tokens :balatro-fg) "1-8  选中手牌 / 商店购买")
              (text :color (plist-get tokens :balatro-fg) "RET  出牌 / 进入下一关")
              (text :color (plist-get tokens :balatro-fg) "d / s  弃牌换牌 / 切换排序")
              (text :color (plist-get tokens :balatro-fg) "u / U  使用消耗品 1 / 2"))
            (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :item-gap '(lh 0)
              (text :color (plist-get tokens :balatro-fg) ", / .  小丑左右调序 · x 出售")
              (text :color (plist-get tokens :balatro-fg) "v / h  52 张牌库矩阵 / 牌型表")
              (text :color (plist-get tokens :balatro-fg) "g / G  重看新手指引 / 开关提示")
              (text :color (plist-get tokens :balatro-fg) "t / N  跟随或切换主题 / 新开局")))))))))

;; ---------------------------------------------------------------------------
;; Controlled Modals: 4-Step Guide / 52-Card Deck Matrix / Hand Levels Table
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--modals (&key session tokens)
  "Render controlled Guide, 52-Card Deck Matrix and Hand Levels modals."
  :render
  (let* ((modal (etaf-value (plist-get session :modal)))
         (guide-step (or (etaf-value (plist-get session :guide-step)) 0))
         (deck (etaf-value (plist-get session :deck)))
         (draw (etaf-value (plist-get session :draw-pile)))
         (hand (etaf-value (plist-get session :hand)))
         (hand-levels (etaf-value (plist-get session :hand-levels)))
         (enhanced (cl-remove-if (lambda (c) (eq (plist-get c :enhancement) 'none)) deck))
         (draw-ids (mapcar (lambda (c) (plist-get c :id)) draw))
         (hand-ids (mapcar (lambda (c) (plist-get c :id)) hand))
         (title (pcase modal
                  ('guide "♠ 欢迎来到 ETAF Balatro · 60 秒小丑牌入门")
                  ('hands "扑克牌型与当前升级倍率表")
                  (_ (format "完整 52 张牌库矩阵（牌库剩余 %d / 总计 %d 张）"
                             (length draw) (length deck)))))
         (vp (etaf-viewport))
         (vw-px (and vp (numberp (car vp)) (> (car vp) 0) (car vp)))
         (metrics (etaf-display-metrics))
         (cw (max 1 (or (plist-get metrics :char-width) 1)))
         (gui-p (> cw 1))
         (width (if (and gui-p vw-px)
                    (pcase modal
                      ('guide (list 'px (min 840 (max 520 (round (* vw-px 0.72))))))
                      ('deck (list 'px (min 760 (max 480 (round (* vw-px 0.66))))))
                      (_ (list 'px (min 600 (max 420 (round (* vw-px 0.52)))))))
                  (pcase modal
                    ('guide '(ch 96))
                    ('deck '(ch 88))
                    (_ '(ch 68)))))
         (modal-keys
          (pcase modal
            ('guide
             (list
              (list "RET" (lambda () (etaf-balatro-guide-step session 1)) "指引下一页")
              (list "<return>" (lambda () (etaf-balatro-guide-step session 1)))
              (list "n" (lambda () (etaf-balatro-guide-step session 1)) "指引下一页")
              (list "p" (lambda () (etaf-balatro-guide-step session -1)) "指引上一页")
              (list "SPC" (lambda () (etaf-balatro-guide-step session 1)) "指引下一页")
              (list "g" (lambda () (etaf-balatro-toggle-modal session nil)) "关闭指引")
              (list "1" (lambda () (etaf-balatro-open-guide session 0)) "第 1 页")
              (list "2" (lambda () (etaf-balatro-open-guide session 1)) "第 2 页")
              (list "3" (lambda () (etaf-balatro-open-guide session 2)) "第 3 页")
              (list "4" (lambda () (etaf-balatro-open-guide session 3)) "第 4 页")))
            ('deck
             (list
              (list "v" (lambda () (etaf-balatro-toggle-modal session nil)) "关闭牌库矩阵")
              (list "RET" (lambda () (etaf-balatro-toggle-modal session nil)) "关闭牌库矩阵")
              (list "<return>" (lambda () (etaf-balatro-toggle-modal session nil)))))
            ('hands
             (list
              (list "h" (lambda () (etaf-balatro-toggle-modal session nil)) "关闭牌型表")
              (list "RET" (lambda () (etaf-balatro-toggle-modal session nil)) "关闭牌型表")
              (list "<return>" (lambda () (etaf-balatro-toggle-modal session nil)))))))
         (modal-dir
          (when (eq modal 'guide)
            (lambda (dir)
              (pcase dir
                ('right (etaf-balatro-guide-step session 1) 'handled)
                ('left (etaf-balatro-guide-step session -1) 'handled)
                (_ 'hold)))))
         (step-labels '((0 . "1 核心规则") (1 . "2 选牌弃牌")
                        (2 . "3 构筑秘诀") (3 . "4 商店与 Boss"))))
    (etaf-view
     (etaf-dialog
      :open (not (null modal))
      :title title
      :width width :animated t
      :close-label (unless (eq modal 'guide) "关闭 · ESC")
      :keys modal-keys
      :on-direction modal-dir
      :on-close (lambda () (etaf-balatro-toggle-modal session nil))
      (expr
       (pcase modal
         ('guide
          (etaf-view
           (column :width 'stretch :item-gap '(lh 1)
             ;; Step indicator pills
             (row :item-gap '(ch 1)
               (expr
                (mapcar
                 (lambda (pair)
                   (let* ((sidx (car pair))
                          (slbl (cdr pair))
                          (cur (= sidx guide-step)))
                     (etaf-view
                      (box :key sidx :ref (intern (format "balatro-guide-tab-%d" sidx))
                           :role 'button :tab-index -1
                           :aria-label slbl
                           :padding-inline '(ch 1)
                           :background-color (if cur (plist-get tokens :balatro-chips-bg)
                                               (plist-get tokens :balatro-card))
                           :color (if cur (plist-get tokens :balatro-chips-fg)
                                    (plist-get tokens :balatro-muted))
                           :font-weight (if cur 'bold 'normal)
                           :border (list '(px 1) 'solid
                                         (if cur (plist-get tokens :balatro-chips-border)
                                           (plist-get tokens :balatro-border)))
                           :pointer (unless cur 'hand)
                           :hover-style (unless cur
                                          (list :background-color (plist-get tokens :balatro-hover)))
                           :on-press (lambda () (etaf-balatro-open-guide session sidx))
                        (text (expr slbl))))))
                 step-labels)))
             ;; Page content
             (expr (etaf-balatro--guide-page-body guide-step tokens))
             ;; Footer navigation (flex-wrap guarantees buttons never clip on any font/viewport)
             (flex :width 'stretch :justify-content 'space-between :align-items 'center
                   :flex-wrap 'wrap :row-gap '(lh 0) :column-gap '(ch 2)
                   :border-top (list '(px 1) 'solid (plist-get tokens :balatro-border))
               (text :color (plist-get tokens :balatro-dim)
                     (expr (format "第 %d / %d 页 · 按 g 重看"
                                   (1+ guide-step) etaf-balatro--guide-page-count)))
               (row :item-gap '(ch 1) :flex-shrink 0
                 (etaf-button :ref 'balatro-guide-skip :label "跳过" :variant 'ghost
                              :tab-index -1
                              :on-press (lambda () (etaf-balatro-toggle-modal session nil)))
                 (etaf-button :if (> guide-step 0)
                              :ref 'balatro-guide-prev :label "← 上一步" :variant 'secondary
                              :tab-index -1
                              :on-press (lambda () (etaf-balatro-guide-step session -1)))
                 (etaf-button :ref 'balatro-guide-next
                              :label (if (= guide-step (1- etaf-balatro--guide-page-count))
                                         "开始开玩 ✓" "下一步 →")
                              :variant 'primary
                              :tab-index 0
                              :on-press (lambda () (etaf-balatro-guide-step session 1))))))))
         ('hands
          (etaf-view
           (column :width 'stretch :item-gap '(lh 1)
             (column :width 'stretch :item-gap '(lh 0)
               (expr
                (mapcar
                 (lambda (spec)
                   (let* ((st (etaf-balatro--hand-stats (car spec) hand-levels))
                          (up (> (plist-get st :level) 1)))
                     (etaf-view
                      (flex :key (car spec) :width 'stretch :justify-content 'space-between
                            :padding '((lh 0) (ch 1))
                            :background-color (if up (plist-get tokens :balatro-cyan-bg)
                                                (plist-get tokens :balatro-surface))
                        (text :color (if up (plist-get tokens :balatro-cyan)
                                       (plist-get tokens :balatro-fg))
                              :font-weight (if up 'bold 'normal)
                              (expr (format "%s  Lv.%d（%s）"
                                            (plist-get st :name)
                                            (plist-get st :level)
                                            (plist-get st :planet))))
                        (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                              (expr (format "%d 筹 × %d 倍%s"
                                            (plist-get st :chips)
                                            (plist-get st :mult)
                                            (if up " ▲" ""))))))))
                 etaf-balatro--hand-specs)))
             (box :width 'stretch :wrap-mode 'word
               (text :color (plist-get tokens :balatro-dim)
                     "提示：过关后在商店购买对应星球牌，或在右上消耗品槽按 u 使用星球牌即可永久升级。")))))
         (_
          ;; Full 4 x 13 52-Card Interactive Deck Matrix
          (etaf-view
           (column :width 'stretch :item-gap '(lh 1)
             (column :width 'stretch :item-gap '(lh 0)
               (box :width 'stretch :wrap-mode 'word
                 (text :color (plist-get tokens :balatro-fg)
                       "状态图例：亮色 = 仍在牌库  ·  金色 = 当前手牌  ·  暗淡 = 本关已打出/弃置"))
               (box :width 'stretch :wrap-mode 'word
                 (text :color (plist-get tokens :balatro-muted)
                       "材质标记：★ 玻璃 (×2)  ·  + 倍率 (+4)  ·  S 钢铁 (×1.5)  ·  B 奖励 (+30)  ·  F 金箔 (+50)")))
             (column :width 'stretch :padding '((lh 1) (ch 2)) :item-gap '(lh 1)
                     :background-color (plist-get tokens :balatro-card)
                     :border (list '(px 1) 'solid (plist-get tokens :balatro-border))
               (expr
                (mapcar
                 (lambda (suit)
                   (let* ((rem (cl-count suit draw :key (lambda (c) (plist-get c :suit))))
                          (tot (cl-count suit deck :key (lambda (c) (plist-get c :suit))))
                          (cells (etaf-balatro--deck-matrix-row suit deck draw-ids hand-ids)))
                     (etaf-view
                      (flex :key suit :width 'stretch :justify-content 'space-between
                            :align-items 'center
                        (row :item-gap '(ch 1)
                          (text :color (etaf-balatro--suit-color tokens suit) :font-weight 'bold
                                (expr (format "%s %s" (etaf-balatro--suit-glyph suit)
                                              (etaf-balatro--suit-name suit))))
                          (row :item-gap '(ch 1)
                            (expr
                             (mapcar
                              (lambda (cell)
                                (let* ((st (plist-get cell :status))
                                       (enh (plist-get cell :enh))
                                       (col (cond
                                             ((eq st 'missing) (plist-get tokens :balatro-border-strong))
                                             ((eq st 'used) (plist-get tokens :balatro-dim))
                                             ((not (eq enh 'none)) (etaf-balatro--enh-color tokens enh))
                                             ((eq st 'hand) (plist-get tokens :balatro-gold))
                                             (t (plist-get tokens :balatro-fg)))))
                                  (etaf-view
                                   (text :key (plist-get cell :key)
                                         :color col
                                         :font-weight (if (or (eq st 'hand) (not (eq enh 'none)))
                                                          'bold 'normal)
                                         (expr (plist-get cell :label))))))
                              cells))))
                        (text :color (plist-get tokens :balatro-cyan)
                              (expr (format "%2d / %2d" rem tot)))))))
                 '(spades hearts diamonds clubs))))
             (column :width 'stretch :item-gap '(lh 0)
               (text :color (plist-get tokens :balatro-gold) :font-weight 'bold
                     (expr (format "已锻造特殊强化牌 (%d 张)" (length enhanced))))
               (box :width 'stretch :wrap-mode 'word
                 (text :color (plist-get tokens :balatro-muted)
                       (expr (if enhanced
                                 (mapconcat
                                  (lambda (c)
                                    (format "%s [%s]"
                                            (etaf-balatro--card-label c)
                                            (plist-get (etaf-balatro--enhancement-info
                                                        (plist-get c :enhancement))
                                                       :short)))
                                  enhanced " · ")
                               "当前暂无特殊强化牌：在牌局中选中手牌按 U 施放塔罗，或在商店购买更多塔罗卡。"))))))))))))))

;; ---------------------------------------------------------------------------
;; Root Application View (Full Viewport + Reactive Host Theme)
;; ---------------------------------------------------------------------------

(etaf-define-component etaf-balatro--root (&key session keys on-dismiss)
  "Root responsive ETAF Component for `etaf-balatro'."
  :bindings
  ((tokens (etaf-computed
            (lambda ()
              (etaf-value etaf-balatro--theme-epoch)
              (etaf-balatro--tokens
               (etaf-value (plist-get session :appearance)))))))
  :setup
  (let ((root-buf (when-let* ((rt (etaf-current-runtime)))
                    (etaf-runtime-buffer rt))))
    (etaf-theme-provide tokens)
    (etaf-watch (plist-get session :modal)
                (lambda (new _old)
                  (cond
                   ((null new) (etaf-balatro--focus-ref 'balatro-root root-buf))
                   ((eq new 'guide) (etaf-balatro--focus-ref 'balatro-guide-next root-buf))))
                :flush 'post :name 'balatro-modal-focus)
    (etaf-watch (plist-get session :phase)
                (lambda (_new _old)
                  (unless (etaf-balatro--val session :modal)
                    (etaf-balatro--focus-ref 'balatro-root root-buf)))
                :flush 'post :name 'balatro-phase-focus)
    (etaf-on-mounted
     (lambda ()
       (unless (etaf-balatro--val session :modal)
         (etaf-balatro--focus-ref 'balatro-root root-buf)))))
  :render
  (let* ((tok (etaf-value tokens))
         (phase (etaf-value (plist-get session :phase)))
         (vp (etaf-viewport))
         (metrics (etaf-display-metrics))
         (cw (max 1 (or (plist-get metrics :char-width) 1)))
         (lh (max 1 (or (plist-get metrics :line-height) 1)))
         (has-vh (and vp (numberp (cdr vp)) (> (cdr vp) 0)))
         ;; Normalize horizontal density using effective CJK-safe cell width
         ;; (half line-height on GUI fonts where Latin `ch' is condensed).
         (eff-cw (if (> cw 1) (max (float cw) (* lh 0.56)) 1.0))
         (eff-cols (if (and vp (numberp (car vp))) (/ (car vp) eff-cw) 144.0))
         (rows (if has-vh (cdr vp) 44))
         (narrow-p (< eff-cols 96))
         (medium-p (and (not narrow-p) (< eff-cols 132)))
         (short-p (< rows 30))
         (compact-v-p (< rows 37))
         (show-coach-p (>= rows 35))
         (tall-p (>= rows 40))
         (extra-tall-p (>= rows 45))
         (spacious-p (and (>= eff-cols 132) (>= rows 38)))
         (card-pad-v (not short-p))
         (card-cols (if spacious-p 9 7))
         (card-lines (cond (spacious-p 5)
                           ((not short-p) 4)
                           (t 3))))
    (etaf-view
     (flex :ref 'balatro-root :class (format "balatro-root is-%s" phase)
           :tab-index -1
           :flex-direction 'column :position 'relative
           :width 'stretch :height (when has-vh '(vh 100))
           :background-color (plist-get tok :balatro-bg)
           :color (plist-get tok :balatro-fg)
           :keys keys :on-dismiss on-dismiss
           :on-press-capture
           (lambda ()
             (when (etaf-event-pointer-p)
               (pcase (etaf-balatro--val session :modal)
                 ('guide (etaf-balatro--focus-ref 'balatro-guide-next))
                 ('nil (etaf-balatro--focus-ref 'balatro-root))
                 (_ nil))))
           :aria-label "ETAF Balatro 文字卡牌构筑肉鸽"
           :help '("牌局：1-8 选牌，RET 出牌，d 弃牌，s 排序，SPC 立即完成动画，u / U 用消耗品（塔罗需先选牌）。"
                   "构筑：, / . 调整小丑左右顺序（+倍率放×倍率左侧），商店 1-4 购买，r 刷新，x 出售，RET 下一关。"
                   "全局：g 60 秒新手指引，G 开关实战提示，v 52 张牌库矩阵，h 牌型表，t 切换主题模式，N 新开局，q 关闭。")
       (etaf-balatro--header :session session :tokens tok
                             :compact narrow-p :medium-p medium-p)
       (flex :flex-direction 'column :width 'stretch :flex-grow 1 :min-height '(lh 0)
             :padding (if (or compact-v-p medium-p) '((lh 0) (ch 2)) '((lh 1) (ch 3)))
         (expr
          (pcase phase
            ('shop
             (etaf-view
              (etaf-balatro--shop-view :session session :tokens tok
                                    :narrow-p narrow-p :medium-p medium-p
                                    :short-p compact-v-p
                                    :extra-tall-p extra-tall-p)))
            ((or 'victory 'gameover)
             (etaf-view
              (etaf-balatro--end-view :session session :tokens tok)))
            (_
             (if narrow-p
                 (etaf-view
                  (flex :flex-direction 'column :width 'stretch :flex-grow 1
                        :row-gap '(lh 0)
                    (etaf-balatro--narrow-hud :session session :tokens tok)
                    (etaf-balatro--joker-bar :session session :tokens tok
                                          :narrow-p t :medium-p nil :short-p t)
                    (etaf-balatro--play-stage :session session :tokens tok
                                           :card-cols card-cols :card-lines card-lines
                                           :card-pad-v nil :short-p t :show-coach-p nil)
                    (etaf-balatro--hand-area :session session :tokens tok
                                          :card-cols card-cols :card-lines card-lines
                                          :card-pad-v nil :short-p t :narrow-p t :wide-gap-p nil)))
               (etaf-view
                (flex :width 'stretch :flex-grow 1
                      :column-gap (if medium-p '(ch 2) '(ch 3)) :align-items 'stretch
                  (etaf-balatro--sidebar :session session :tokens tok
                                      :short-p short-p :compact-v-p compact-v-p
                                      :medium-p medium-p :tall-p tall-p
                                      :extra-tall-p extra-tall-p)
                  (flex :flex-direction 'column :flex-grow 1 :flex-basis '(ch 0)
                        :min-width '(ch 0) :height 'stretch
                        :row-gap (if compact-v-p '(lh 0) '(lh 1))
                    (etaf-balatro--joker-bar :session session :tokens tok
                                          :narrow-p nil :medium-p medium-p
                                          :short-p compact-v-p :extra-tall-p extra-tall-p)
                    (etaf-balatro--play-stage :session session :tokens tok
                                           :card-cols card-cols :card-lines card-lines
                                           :card-pad-v card-pad-v :short-p compact-v-p
                                           :show-coach-p show-coach-p)
                    (etaf-balatro--hand-area :session session :tokens tok
                                          :card-cols card-cols :card-lines card-lines
                                          :card-pad-v card-pad-v :short-p (not extra-tall-p)
                                          :narrow-p nil :wide-gap-p spacious-p)))))))))
       (etaf-balatro--modals :session session :tokens tok)))))

(provide 'etaf-balatro-views)
;;; etaf-balatro-views.el ends here
