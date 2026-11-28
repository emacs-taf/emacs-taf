;;; etaf-balatro-engine.el --- Pure deterministic poker roguelike rules -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure-function deterministic game engine for `etaf-balatro'.  Owns seeded PRNG,
;; standard 52-card deck construction, card enhancements (bonus, mult, glass,
;; steel, foil), poker hand classification, hand-level upgrades, 14 distinct
;; Jokers, 6 targeted Tarot sculpting cards, 8 Antes x 3 Blinds with Boss
;; traits, shop generation, contextual Coach hand/order analysis, and the
;; step-by-step scoring cascade returning exact totals and an ordered trace.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(define-error 'etaf-balatro-error "ETAF Balatro error")

(defconst etaf-balatro--suits '(spades hearts clubs diamonds)
  "Canonical suit order.")

(defconst etaf-balatro--suit-meta
  '((spades   . ("♠" "黑桃"))
    (hearts   . ("♥" "红桃"))
    (clubs    . ("♣" "梅花"))
    (diamonds . ("♦" "方片")))
  "Display glyph and Chinese name for each suit.")

(defconst etaf-balatro--enhancement-meta
  '((none  . (:name "普通" :short "" :badge "" :desc "无附加材质"))
    (bonus . (:name "奖励" :short "+30 筹" :badge "B" :desc "计分时额外 +30 筹码"))
    (mult  . (:name "倍率" :short "+4 倍" :badge "+" :desc "计分时额外 +4 倍率"))
    (glass . (:name "玻璃" :short "玻璃 ×2" :badge "★" :desc "计分时 ×2.0 倍率，25% 几率碎裂"))
    (steel . (:name "钢铁" :short "钢铁 ×1.5" :badge "S" :desc "留在手牌时 ×1.5 倍率"))
    (foil  . (:name "金箔" :short "金箔 +50" :badge "F" :desc "计分时额外 +50 筹码")))
  "Enhancement definitions keyed by symbol.")

(defconst etaf-balatro--hand-specs
  '((straight-flush  . (:name "同花顺" :planet "海王星" :chips 100 :mult 8 :d-chips 40 :d-mult 4))
    (four-of-a-kind  . (:name "四条"   :planet "火星"   :chips 60  :mult 7 :d-chips 30 :d-mult 3))
    (full-house      . (:name "葫芦"   :planet "地球"   :chips 40  :mult 4 :d-chips 25 :d-mult 2))
    (flush           . (:name "同花"   :planet "木星"   :chips 35  :mult 4 :d-chips 15 :d-mult 2))
    (straight        . (:name "顺子"   :planet "土星"   :chips 30  :mult 4 :d-chips 30 :d-mult 3))
    (three-of-a-kind . (:name "三条"   :planet "金星"   :chips 30  :mult 3 :d-chips 20 :d-mult 2))
    (two-pair        . (:name "两对"   :planet "天王星" :chips 20  :mult 2 :d-chips 20 :d-mult 1))
    (one-pair        . (:name "对子"   :planet "水星"   :chips 10  :mult 2 :d-chips 15 :d-mult 1))
    (high-card       . (:name "高牌"   :planet "冥王星" :chips 5   :mult 1 :d-chips 10 :d-mult 1)))
  "Poker hand base scoring table and Planet upgrade increments.")

(defconst etaf-balatro--joker-catalog
  '((:id greedy-heart :name "贪婪红心" :rarity common :cost 5 :mult-kind card
     :short "♥ 牌 +4 倍" :desc "每张计分的 ♥ 牌提供 +4 倍率" :kind card)
    (:id chip-miner :name "筹码矿工" :rarity common :cost 5 :mult-kind chips
     :short "同花 +60 筹" :desc "打出同花或同花顺时 +60 筹码" :kind independent)
    (:id mult-prism :name "乘算棱镜" :rarity rare :cost 7 :mult-kind xmult
     :short "弃牌 ≤2 ×2 倍" :desc "本关剩余弃牌 ≤ 2 时 ×2.0 倍率（建议放右侧）" :kind independent)
    (:id macro-recorder :name "宏录制器" :rarity uncommon :cost 6 :mult-kind retrigger
     :short "首牌复播 ×2" :desc "重复触发你打出的第 1 张计分牌 1 次" :kind retrigger)
    (:id gc-collector :name "垃圾回收器" :rarity uncommon :cost 6 :mult-kind chips
     :short "弃牌 +8 筹" :desc "每次弃牌永久累加 +8 筹码（成长型）" :kind scaling)
    (:id paren-pair :name "括号对子" :rarity common :cost 4 :mult-kind +mult
     :short "含对 +8 倍" :desc "牌型为对子/两对/三条/葫芦/四条时 +8 倍率" :kind independent)
    (:id even-steven :name "偶数节奏" :rarity common :cost 5 :mult-kind card
     :short "偶数 +4 倍" :desc "每张 2/4/6/8/10 计分牌提供 +4 倍率" :kind card)
    (:id odd-todd :name "奇数冲刺" :rarity common :cost 5 :mult-kind chips
     :short "奇数 +30 筹" :desc "每张 A/3/5/7/9 计分牌提供 +30 筹码" :kind card)
    (:id royal-crown :name "王冠徽章" :rarity uncommon :cost 6 :mult-kind card
     :short "J/Q/K +5 倍" :desc "每张 J/Q/K 人头计分牌提供 +5 倍率" :kind card)
    (:id neon-flush :name "霓虹同花" :rarity rare :cost 7 :mult-kind xmult
     :short "同花 ×2.5 倍" :desc "打出同花或同花顺时 ×2.5 倍率（建议放右侧）" :kind independent)
    (:id steel-foundry :name "钢铁锻炉" :rarity uncommon :cost 6 :mult-kind +mult
     :short "留≥3 +12 倍" :desc "结算时手牌留存 ≥ 3 张提供 +12 倍率" :kind independent)
    (:id last-stand :name "背水一战" :rarity rare :cost 7 :mult-kind xmult
     :short "末手 ×3.0 倍" :desc "在最后 1 次出牌时触发 ×3.0 倍率（建议放最右）" :kind independent)
    (:id golden-interest :name "复利账本" :rarity common :cost 5 :mult-kind +mult
     :short "每 $5 +3 倍" :desc "当前每持有 $5 金币提供 +3 倍率" :kind independent)
    (:id emacs-lambda :name "Lambda 折算" :rarity rare :cost 8 :mult-kind xmult
     :short "4 张 ×2.2 倍" :desc "本手恰好打出 4 张牌时 ×2.2 倍率（建议放右侧）" :kind independent))
  "Catalog of all Joker passive cards.")

(defconst etaf-balatro--tarot-catalog
  '((:id magician :name "魔术师" :cost 3 :max-targets 2 :effect enhance :enhancement mult
     :short "2 张牌变倍率牌 (+4 倍)"
     :desc "战内选中 1-2 张手牌施放，永久锻造为倍率牌（打出 +4 倍率）")
    (:id hierophant :name "教皇" :cost 3 :max-targets 2 :effect enhance :enhancement bonus
     :short "2 张牌变奖励牌 (+30 筹)"
     :desc "战内选中 1-2 张手牌施放，永久锻造为奖励牌（打出 +30 筹码）")
    (:id justice :name "正义" :cost 4 :max-targets 1 :effect enhance :enhancement glass
     :short "1 张牌变玻璃牌 (×2 倍)"
     :desc "战内选中 1 张手牌施放，永久锻造为玻璃牌（打出 ×2.0 倍率）")
    (:id chariot :name "战车" :cost 4 :max-targets 1 :effect enhance :enhancement steel
     :short "1 张牌变钢铁牌 (留手 ×1.5)"
     :desc "战内选中 1 张手牌施放，永久锻造为钢铁牌（留在手牌 ×1.5 倍率）")
    (:id sun :name "太阳" :cost 3 :max-targets 3 :effect suit :suit hearts
     :short "最多 3 张牌转 ♥ 红桃"
     :desc "战内选中 1-3 张手牌施放，永久转化为 ♥ 红桃（助力同花与贪婪红心）")
    (:id hanged-man :name "倒吊人" :cost 3 :max-targets 2 :effect destroy
     :short "永久销毁最多 2 张废牌"
     :desc "战内选中 1-2 张手牌施放，将其从牌库永久移除以精简构筑"))
  "Catalog of targeted Tarot sculpting consumables.")

(defconst etaf-balatro--boss-traits
  '((:id debuff-spades :name "黑桃封锁"
     :desc "所有 ♠ 牌不计筹码与材质强化")
    (:id debuff-hearts :name "红桃封锁"
     :desc "所有 ♥ 牌不计筹码与材质强化")
    (:id must-five :name "满编五张"
     :desc "每次出牌必须恰好选择 5 张牌")
    (:id max-three :name "精简三张"
     :desc "每次出牌最多选择 3 张牌")
    (:id no-discards :name "零弃牌令"
     :desc "本关开始时弃牌次数清零")
    (:id ban-high-card :name "高牌禁用"
     :desc "打出高牌时基础得分归零"))
  "Boss Blind trait definitions.")

(defconst etaf-balatro--ante-base-targets
  [300 800 2000 5000 11000 20000 35000 50000]
  "Base Small Blind target score for Antes 1 through 8.")

;; ---------------------------------------------------------------------------
;; Pure deterministic PRNG
;; ---------------------------------------------------------------------------

(defun etaf-balatro--rng-step (state)
  "Advance LCG integer STATE and return (VALUE . NEXT-STATE) in [0, 2^31-1]."
  (let* ((s (logand (abs (if (integerp state) state 4821)) #x7fffffff))
         (next (logand (+ (* s 1103515245) 12345) #x7fffffff)))
    (cons next next)))

(defun etaf-balatro--rng-int (rng limit)
  "Draw an integer in [0, LIMIT) from mutable RNG cell (STATE) and update it."
  (let* ((pair (etaf-balatro--rng-step (car rng)))
         (val (car pair)))
    (setcar rng (cdr pair))
    (if (> limit 0) (mod (ash val -8) limit) 0)))

(defun etaf-balatro--rng-shuffle (items rng)
  "Return a deterministically shuffled copy of ITEMS using RNG cell."
  (let* ((vec (vconcat items))
         (n (length vec)))
    (cl-loop for i from (1- n) downto 1 do
             (let* ((j (etaf-balatro--rng-int rng (1+ i)))
                    (tmp (aref vec i)))
               (aset vec i (aref vec j))
               (aset vec j tmp)))
    (append vec nil)))

;; ---------------------------------------------------------------------------
;; Card helpers & Deck generation
;; ---------------------------------------------------------------------------

(defun etaf-balatro--rank-label (rank)
  "Return short display string for numeric RANK 2..14."
  (pcase rank
    (14 "A")
    (13 "K")
    (12 "Q")
    (11 "J")
    (_ (number-to-string rank))))

(defun etaf-balatro--rank-chips (rank)
  "Return base chip value for numeric RANK 2..14."
  (cond
   ((= rank 14) 11)
   ((>= rank 10) 10)
   (t rank)))

(defun etaf-balatro--suit-glyph (suit)
  "Return short symbol glyph for SUIT."
  (or (car (cdr (assq suit etaf-balatro--suit-meta))) "?"))

(defun etaf-balatro--suit-name (suit)
  "Return Chinese display name for SUIT."
  (or (cadr (cdr (assq suit etaf-balatro--suit-meta))) "未知"))

(defun etaf-balatro--card-label (card)
  "Return concise human-readable label like \"A ♥\" for CARD."
  (format "%s %s"
          (etaf-balatro--rank-label (plist-get card :rank))
          (etaf-balatro--suit-glyph (plist-get card :suit))))

(defun etaf-balatro--enhancement-info (enhancement)
  "Return metadata plist for ENHANCEMENT symbol."
  (or (cdr (assq (or enhancement 'none) etaf-balatro--enhancement-meta))
      (cdr (assq 'none etaf-balatro--enhancement-meta))))

(defun etaf-balatro--make-standard-deck ()
  "Create a fresh ordered 52-card deck."
  (let ((id 1)
        cards)
    (dolist (suit etaf-balatro--suits)
      (cl-loop for rank from 2 to 14 do
               (push (list :id id :rank rank :suit suit :enhancement 'none) cards)
               (setq id (1+ id))))
    (nreverse cards)))

(defun etaf-balatro--default-hand-levels ()
  "Return fresh alist of (HAND-TYPE . LEVEL) initialized to level 1."
  (mapcar (lambda (spec) (cons (car spec) 1)) etaf-balatro--hand-specs))

(defun etaf-balatro--hand-stats (hand-type &optional hand-levels)
  "Return plist (:name :planet :level :chips :mult) for HAND-TYPE."
  (let* ((spec (or (cdr (assq hand-type etaf-balatro--hand-specs))
                   (cdr (assq 'high-card etaf-balatro--hand-specs))))
         (lvl (max 1 (or (cdr (assq hand-type hand-levels)) 1)))
         (extra (1- lvl)))
    (list :hand-type hand-type
          :name (plist-get spec :name)
          :planet (plist-get spec :planet)
          :level lvl
          :chips (+ (plist-get spec :chips) (* extra (plist-get spec :d-chips)))
          :mult (+ (plist-get spec :mult) (* extra (plist-get spec :d-mult))))))

(defun etaf-balatro--joker-def (id)
  "Return catalog definition plist for Joker ID, or nil."
  (cl-find id etaf-balatro--joker-catalog :key (lambda (j) (plist-get j :id))))

(defun etaf-balatro--tarot-def (id)
  "Return catalog definition plist for Tarot ID, or nil."
  (cl-find id etaf-balatro--tarot-catalog :key (lambda (tr) (plist-get tr :id))))

(defun etaf-balatro--make-joker (id &optional instance-id)
  "Instantiate a live Joker plist from catalog ID."
  (let ((def (or (etaf-balatro--joker-def id)
                 (signal 'etaf-balatro-error (list "Unknown joker id" id)))))
    (append (copy-sequence def)
            (list :uid (or instance-id id)
                  :bonus-chips 0))))

(defun etaf-balatro--make-tarot (id &optional instance-id)
  "Instantiate a live Tarot consumable plist from catalog ID."
  (let ((def (or (etaf-balatro--tarot-def id)
                 (signal 'etaf-balatro-error (list "Unknown tarot id" id)))))
    (append (copy-sequence def)
            (list :kind 'tarot
                  :uid (or instance-id id)))))

(defun etaf-balatro--joker-sell-price (joker)
  "Return sell price for JOKER (half of cost, minimum 2)."
  (max 2 (/ (or (plist-get joker :cost) 4) 2)))

(defun etaf-balatro--blind-spec (ante blind rng)
  "Return plist for ANTE (1..8) and BLIND (`small', `big', `boss')."
  (let* ((idx (max 0 (min (1- (length etaf-balatro--ante-base-targets)) (1- ante))))
         (base (aref etaf-balatro--ante-base-targets idx))
         (factor (pcase blind ('small 1.0) ('big 1.5) (_ 2.0)))
         (reward (pcase blind ('small 3) ('big 4) (_ 5)))
         (name (pcase blind ('small "小盲注") ('big "大盲注") (_ "Boss 盲注")))
         (trait (when (eq blind 'boss)
                  (nth (etaf-balatro--rng-int rng (length etaf-balatro--boss-traits))
                       etaf-balatro--boss-traits))))
    (list :ante ante
          :blind blind
          :name name
          :target (round (* base factor))
          :reward reward
          :boss-trait trait)))

(defun etaf-balatro--sort-cards (cards mode)
  "Return CARDS sorted by MODE (`rank' descending or `suit' then rank)."
  (let ((copy (copy-sequence cards)))
    (sort copy
          (lambda (a b)
            (let ((ra (plist-get a :rank))
                  (rb (plist-get b :rank))
                  (sa (or (cl-position (plist-get a :suit) etaf-balatro--suits) 0))
                  (sb (or (cl-position (plist-get b :suit) etaf-balatro--suits) 0)))
              (if (eq mode 'suit)
                  (if (/= sa sb) (< sa sb) (> ra rb))
                (if (/= ra rb) (> ra rb) (< sa sb))))))))

;; ---------------------------------------------------------------------------
;; Pure Poker Hand Evaluator
;; ---------------------------------------------------------------------------

(defun etaf-balatro--straight-p (ranks)
  "Return non-nil when 5 descending RANKS form a straight (including A-5)."
  (when (= (length ranks) 5)
    (let ((uniq (cl-remove-duplicates ranks)))
      (when (= (length uniq) 5)
        (or (= (- (car uniq) (car (last uniq))) 4)
            (equal uniq '(14 5 4 3 2)))))))

;;;###autoload
(defun etaf-balatro-evaluate-hand (cards &optional hand-levels)
  "Classify 1 to 5 played CARDS and return scoring metadata plist.
HAND-LEVELS is an optional alist of (HAND-TYPE . LEVEL)."
  (unless (and (listp cards) (>= (length cards) 1) (<= (length cards) 5))
    (signal 'etaf-balatro-error (list "Played hand must contain 1 to 5 cards" (length cards))))
  (let* ((sorted (sort (copy-sequence cards)
                       (lambda (a b) (> (plist-get a :rank) (plist-get b :rank)))))
         (ranks (mapcar (lambda (c) (plist-get c :rank)) sorted))
         (suits (mapcar (lambda (c) (plist-get c :suit)) sorted))
         (flush-p (and (= (length sorted) 5)
                       (= (length (cl-remove-duplicates suits)) 1)))
         (straight-p (etaf-balatro--straight-p ranks))
         (groups nil))
    (dolist (card sorted)
      (let* ((r (plist-get card :rank))
             (cell (assq r groups)))
        (if cell
            (setcdr cell (cons card (cdr cell)))
          (push (cons r (list card)) groups))))
    (setq groups
          (sort groups
                (lambda (a b)
                  (let ((la (length (cdr a)))
                        (lb (length (cdr b))))
                    (if (/= la lb) (> la lb) (> (car a) (car b)))))))
    (let* ((counts (mapcar (lambda (g) (length (cdr g))) groups))
           (hand-type
            (cond
             ((and flush-p straight-p) 'straight-flush)
             ((equal (car counts) 4) 'four-of-a-kind)
             ((and (= (length counts) 2) (= (nth 0 counts) 3) (= (nth 1 counts) 2))
              'full-house)
             (flush-p 'flush)
             (straight-p 'straight)
             ((equal (car counts) 3) 'three-of-a-kind)
             ((and (>= (length counts) 2) (= (nth 0 counts) 2) (= (nth 1 counts) 2))
              'two-pair)
             ((equal (car counts) 2) 'one-pair)
             (t 'high-card)))
           (scoring-cards
            (pcase hand-type
              ((or 'straight-flush 'full-house 'flush 'straight) sorted)
              ('four-of-a-kind (cdr (nth 0 groups)))
              ('three-of-a-kind (cdr (nth 0 groups)))
              ('two-pair (append (cdr (nth 0 groups)) (cdr (nth 1 groups))))
              ('one-pair (cdr (nth 0 groups)))
              (_ (list (car sorted)))))
           (scoring-set (mapcar (lambda (c) (plist-get c :id)) scoring-cards))
           (ordered-ids (cl-loop for c in cards
                                 when (memq (plist-get c :id) scoring-set)
                                 collect (plist-get c :id)))
           (stats (etaf-balatro--hand-stats hand-type hand-levels)))
      (list :hand-type hand-type
            :hand-name (plist-get stats :name)
            :level (plist-get stats :level)
            :base-chips (plist-get stats :chips)
            :base-mult (plist-get stats :mult)
            :scoring-ids ordered-ids))))

;; ---------------------------------------------------------------------------
;; Pure Scoring Cascade Engine (returns final numbers + ordered event trace)
;; ---------------------------------------------------------------------------

(defun etaf-balatro--card-debuffed-p (card boss-trait)
  "Return non-nil when CARD is debuffed by BOSS-TRAIT."
  (let ((tid (and boss-trait (plist-get boss-trait :id)))
        (suit (plist-get card :suit)))
    (or (and (eq tid 'debuff-spades) (eq suit 'spades))
        (and (eq tid 'debuff-hearts) (eq suit 'hearts)))))

(defun etaf-balatro--round-mult (mult)
  "Normalize MULT to at most 2 decimal places (integer when exact)."
  (let ((r (/ (round (* mult 100.0)) 100.0)))
    (if (= r (round r)) (round r) r)))

;;;###autoload
(cl-defun etaf-balatro-simulate-score
    (played-cards held-cards jokers hand-levels
                  &key (hands-left 4) (discards-left 3) (money 4)
                  boss-trait (seed 4821))
  "Purely evaluate PLAYED-CARDS with HELD-CARDS, JOKERS and HAND-LEVELS.
Returns a plist with final chips, mult, total score, ordered `:events' trace
for cascade animation, and `:shattered-ids' for broken Glass cards."
  (let* ((eval (etaf-balatro-evaluate-hand played-cards hand-levels))
         (hand-type (plist-get eval :hand-type))
         (hand-name (plist-get eval :hand-name))
         (level (plist-get eval :level))
         (scoring-ids (plist-get eval :scoring-ids))
         (boss-id (and boss-trait (plist-get boss-trait :id)))
         (ban-high (and (eq boss-id 'ban-high-card) (eq hand-type 'high-card)))
         (chips (if ban-high 0 (plist-get eval :base-chips)))
         (mult (float (if ban-high 0 (plist-get eval :base-mult))))
         (rng (list seed))
         (has-macro (cl-some (lambda (j) (eq (plist-get j :id) 'macro-recorder)) jokers))
         (events nil)
         (shattered-ids nil)
         (first-scoring-id (car scoring-ids)))
    (cl-labels
        ((emit (kind id label detail tag c-delta m-delta m-factor)
           (when (/= c-delta 0) (setq chips (+ chips c-delta)))
           (when (/= m-delta 0) (setq mult (+ mult m-delta)))
           (when (/= m-factor 1.0) (setq mult (* mult m-factor)))
           (push (list :kind kind
                       :id id
                       :label label
                       :detail detail
                       :tag tag
                       :chips-delta c-delta
                       :mult-delta m-delta
                       :mult-factor m-factor
                       :chips-after chips
                       :mult-after (etaf-balatro--round-mult mult))
                 events))
         (score-one-card (card retrigger-p)
           (let* ((cid (plist-get card :id))
                  (clabel (etaf-balatro--card-label card))
                  (rank (plist-get card :rank))
                  (suit (plist-get card :suit))
                  (enh (or (plist-get card :enhancement) 'none))
                  (debuffed (etaf-balatro--card-debuffed-p card boss-trait)))
             (if debuffed
                 (emit 'card cid clabel
                       (format "%s 被 Boss 封锁" clabel)
                       "已封锁" 0 0 1.0)
               (let* ((base-c (etaf-balatro--rank-chips rank))
                      (c-add (+ base-c
                                (pcase enh ('bonus 30) ('foil 50) (_ 0))))
                      (m-add (if (eq enh 'mult) 4 0))
                      (m-fac (if (eq enh 'glass) 2.0 1.0))
                      (enh-tag (pcase enh
                                 ('glass "玻璃 ×2!")
                                 ('bonus (format "+%d 筹" c-add))
                                 ('foil (format "金箔 +%d" c-add))
                                 ('mult (format "+%d 筹 +4 倍" base-c))
                                 (_ (format "+%d 筹" base-c))))
                      (prefix (if retrigger-p "宏复播 · " "")))
                 (emit 'card cid clabel
                       (format "%s%s → +%d 筹%s%s"
                               prefix clabel c-add
                               (if (> m-add 0) (format " +%d 倍" m-add) "")
                               (if (> m-fac 1.0) (format " ×%.1f 倍" m-fac) ""))
                       (if retrigger-p (concat "复播 " enh-tag) enh-tag)
                       c-add m-add m-fac)
                 (dolist (joker jokers)
                   (let ((jid (plist-get joker :id))
                         (juid (plist-get joker :uid))
                         (jname (plist-get joker :name)))
                     (cond
                      ((and (eq jid 'greedy-heart) (eq suit 'hearts))
                       (emit 'joker juid jname
                             (format "%s (%s) → +4 倍" jname clabel)
                             "+4 倍!" 0 4 1.0))
                      ((and (eq jid 'even-steven) (member rank '(2 4 6 8 10)))
                       (emit 'joker juid jname
                             (format "%s (%s) → +4 倍" jname clabel)
                             "+4 倍!" 0 4 1.0))
                      ((and (eq jid 'odd-todd) (member rank '(14 3 5 7 9)))
                       (emit 'joker juid jname
                             (format "%s (%s) → +30 筹" jname clabel)
                             "+30 筹" 30 0 1.0))
                      ((and (eq jid 'royal-crown) (member rank '(11 12 13)))
                       (emit 'joker juid jname
                             (format "%s (%s) → +5 倍" jname clabel)
                             "+5 倍!" 0 5 1.0)))))
                 (when (and (eq enh 'glass) (not retrigger-p)
                            (= (etaf-balatro--rng-int rng 4) 0))
                   (push cid shattered-ids)))))))
      (when ban-high
        (emit 'boss 'boss-ban "高牌禁用"
              "Boss 词条：高牌基础分归零" "禁用!" 0 0 1.0))
      (unless ban-high
        (dolist (card played-cards)
          (when (memq (plist-get card :id) scoring-ids)
            (score-one-card card nil)
            (when (and has-macro (equal (plist-get card :id) first-scoring-id))
              (score-one-card card t))))
        (dolist (card held-cards)
          (when (and (eq (plist-get card :enhancement) 'steel)
                     (not (etaf-balatro--card-debuffed-p card boss-trait)))
            (let ((clabel (etaf-balatro--card-label card)))
              (emit 'held (plist-get card :id) clabel
                    (format "留手 %s 钢铁 → ×1.5 倍" clabel)
                    "钢铁 ×1.5" 0 0 1.5))))
        (dolist (joker jokers)
          (let ((jid (plist-get joker :id))
                (juid (plist-get joker :uid))
                (jname (plist-get joker :name)))
            (pcase jid
              ('chip-miner
               (when (memq hand-type '(flush straight-flush))
                 (emit 'joker juid jname
                       (format "%s → +60 筹" jname) "+60 筹" 60 0 1.0)))
              ('gc-collector
               (let ((bonus (or (plist-get joker :bonus-chips) 0)))
                 (when (> bonus 0)
                   (emit 'joker juid jname
                         (format "%s → +%d 筹" jname bonus)
                         (format "+%d 筹" bonus) bonus 0 1.0))))
              ('paren-pair
               (when (memq hand-type '(one-pair two-pair three-of-a-kind full-house four-of-a-kind))
                 (emit 'joker juid jname
                       (format "%s → +8 倍" jname) "+8 倍!" 0 8 1.0)))
              ('steel-foundry
               (when (>= (length held-cards) 3)
                 (emit 'joker juid jname
                       (format "%s → +12 倍" jname) "+12 倍!" 0 12 1.0)))
              ('golden-interest
               (let ((bonus (* 3 (/ (max 0 money) 5))))
                 (when (> bonus 0)
                   (emit 'joker juid jname
                         (format "%s → +%d 倍" jname bonus)
                         (format "+%d 倍!" bonus) 0 bonus 1.0))))
              ('mult-prism
               (when (<= discards-left 2)
                 (emit 'joker juid jname
                       (format "%s → ×2.0 倍" jname) "×2.0 倍!" 0 0 2.0)))
              ('neon-flush
               (when (memq hand-type '(flush straight-flush))
                 (emit 'joker juid jname
                       (format "%s → ×2.5 倍" jname) "×2.5 倍!" 0 0 2.5)))
              ('last-stand
               (when (<= hands-left 1)
                 (emit 'joker juid jname
                       (format "%s → ×3.0 倍" jname) "×3.0 倍!" 0 0 3.0)))
              ('emacs-lambda
               (when (= (length played-cards) 4)
                 (emit 'joker juid jname
                       (format "%s → ×2.2 倍" jname) "×2.2 倍!" 0 0 2.2)))))))
      (let* ((final-mult (etaf-balatro--round-mult mult))
             (total (max 0 (round (* chips final-mult)))))
        (list :hand-type hand-type
              :hand-name hand-name
              :level level
              :base-chips (plist-get eval :base-chips)
              :base-mult (plist-get eval :base-mult)
              :scoring-ids scoring-ids
              :final-chips chips
              :final-mult final-mult
              :total-score total
              :events (nreverse events)
              :shattered-ids (nreverse shattered-ids))))))

;; ---------------------------------------------------------------------------
;; Smart In-Game Coach Analyzer (Pure)
;; ---------------------------------------------------------------------------

(defun etaf-balatro--joker-order-warning (jokers)
  "Return warning text when any xMult Joker sits left of a +Mult Joker."
  (let ((seen-x nil)
        (warning nil))
    (dolist (j jokers)
      (let ((mk (or (plist-get j :mult-kind)
                    (plist-get (etaf-balatro--joker-def (plist-get j :id)) :mult-kind))))
        (cond
         ((eq mk 'xmult)
          (unless seen-x (setq seen-x (plist-get j :name))))
         ((and seen-x (eq mk '+mult) (null warning))
          (setq warning
                (format "排序提效：「%s」(×倍率) 在「%s」(+倍率) 左侧！选中它按 [.] 右移可白赚更高倍率"
                        seen-x (plist-get j :name)))))))
    warning))

(defun etaf-balatro--find-straight-indices (indexed-cards)
  "Return 5 1-based indices for the highest straight in INDEXED-CARDS, or nil."
  (let ((by-rank nil))
    (dolist (pair indexed-cards)
      (let ((r (plist-get (cdr pair) :rank)))
        (unless (assq r by-rank)
          (push (cons r (car pair)) by-rank))))
    (let ((found nil))
      (cl-loop for top from 14 downto 6
               until found do
               (let ((run (cl-loop for r from top downto (- top 4)
                                   collect (cdr (assq r by-rank)))))
                 (when (cl-every #'identity run)
                   (setq found (sort run #'<)))))
      (unless found
        (let ((wheel (mapcar (lambda (r) (cdr (assq r by-rank))) '(14 5 4 3 2))))
          (when (cl-every #'identity wheel)
            (setq found (sort wheel #'<)))))
      found)))

(defun etaf-balatro--best-hand-in-hand (hand)
  "Analyze dealt HAND and return best combo plist (:hand-name :indices :suit)."
  (when hand
    (let* ((indexed (cl-loop for c in hand for i from 1 collect (cons i c)))
           (by-suit nil)
           (by-rank nil))
      (dolist (pair indexed)
        (let* ((s (plist-get (cdr pair) :suit))
               (r (plist-get (cdr pair) :rank))
               (sc (assq s by-suit))
               (rc (assq r by-rank)))
          (if sc (setcdr sc (append (cdr sc) (list (car pair))))
            (push (cons s (list (car pair))) by-suit))
          (if rc (setcdr rc (append (cdr rc) (list (car pair))))
            (push (cons r (list (car pair))) by-rank))))
      (setq by-rank (sort by-rank
                          (lambda (a b)
                            (let ((la (length (cdr a)))
                                  (lb (length (cdr b))))
                              (if (/= la lb) (> la lb) (> (car a) (car b)))))))
      (let* ((flush-cell (cl-find-if (lambda (c) (>= (length (cdr c)) 5)) by-suit))
             (straight-idx (etaf-balatro--find-straight-indices indexed))
             (g0 (nth 0 by-rank))
             (g1 (nth 1 by-rank)))
        (cond
         ((and g0 (>= (length (cdr g0)) 4))
          (list :hand-name "四条" :indices (cl-subseq (cdr g0) 0 4)))
         ((and g0 g1 (>= (length (cdr g0)) 3) (>= (length (cdr g1)) 2))
          (list :hand-name "葫芦"
                :indices (sort (append (cl-subseq (cdr g0) 0 3)
                                       (cl-subseq (cdr g1) 0 2))
                               #'<)))
         (flush-cell
          (list :hand-name "同花"
                :suit (car flush-cell)
                :indices (cl-subseq (cdr flush-cell) 0 5)))
         (straight-idx
          (list :hand-name "顺子" :indices straight-idx))
         ((and g0 (= (length (cdr g0)) 3))
          (list :hand-name "三条" :indices (cdr g0)))
         ((and g0 g1 (= (length (cdr g0)) 2) (= (length (cdr g1)) 2))
          (list :hand-name "两对"
                :indices (sort (append (cdr g0) (cdr g1)) #'<)))
         ((and g0 (= (length (cdr g0)) 2))
          (list :hand-name "对子" :indices (cdr g0)))
         (t
          (list :hand-name "高牌" :indices (list 1))))))))

(defun etaf-balatro--coach-hint (ctx)
  "Return a concise actionable Chinese hint string for live game context CTX."
  (let* ((phase (plist-get ctx :phase))
         (animating (plist-get ctx :animating))
         (jokers (plist-get ctx :jokers))
         (order-warn (etaf-balatro--joker-order-warning jokers))
         (hand (plist-get ctx :hand))
         (selected-ids (plist-get ctx :selected-ids))
         (consumables (plist-get ctx :consumables))
         (discards (or (plist-get ctx :discards-left) 0))
         (score (or (plist-get ctx :score) 0))
         (target (or (plist-get ctx :target) 300))
         (money (or (plist-get ctx :money) 0))
         (boss-trait (plist-get ctx :boss-trait))
         (next-spec (plist-get ctx :next-blind-spec))
         (preview (plist-get ctx :preview)))
    (cond
     (animating
      "正在逐张播放计分连锁；随时按 [SPC] 立即完成，或点右上 [1×/2×/4×] 调整动画速度。")
     (order-warn order-warn)
     ((eq phase 'shop)
      (cond
       ((and next-spec (plist-get next-spec :boss-trait))
        (let ((bt (plist-get next-spec :boss-trait)))
          (format "下一关是 Boss「%s」（%s），建议针对性购入小丑或塔罗，准备就绪按 [RET] 开战！"
                  (plist-get bt :name) (plist-get bt :desc))))
       ((>= money 10)
        (format "当前有 $%d，每保留 $5 下关多拿 $1 利息（现可稳拿 +$%d）；按 [1-4] 选购，买塔罗进消耗品槽战内锻造，[RET] 进下一关。"
                money (min 5 (/ money 5))))
       (t
        "按 [1-4] 购买小丑、行星升级或塔罗锻造；按 [, / .] 调小丑顺序，[x] 卖出旧小丑，准备妥当按 [RET] 进下一关。")))
     ((eq phase 'playing)
      (let* ((boss-id (and boss-trait (plist-get boss-trait :id)))
             (sel-n (length selected-ids))
             (tarot-idx (cl-position 'tarot consumables :key (lambda (x) (plist-get x :kind))))
             (tarot-item (and tarot-idx (nth tarot-idx consumables)))
             (tarot-key (if (and tarot-idx (= tarot-idx 1)) "U" "u"))
             (planet-item (cl-find 'planet consumables :key (lambda (x) (plist-get x :kind)))))
        (cond
         ((and (eq boss-id 'must-five) (> sel-n 0) (/= sel-n 5))
          (format "Boss「满编五张」生效：当前已选 %d 张，必须恰好选满 5 张才能按 [RET] 出牌！" sel-n))
         ((and (eq boss-id 'max-three) (> sel-n 3))
          (format "Boss「精简三张」生效：最多只能选 3 张牌（当前 %d 张），请取消多余牌。" sel-n))
         (preview
          (let* ((est (plist-get preview :estimated-score))
                 (hname (plist-get preview :hand-name)))
            (cond
             ((>= (+ score est) target)
              (format "已选「%s」，预计 +%d 分可直接通关！立刻按 [RET] 出牌收下过关赏金。"
                      hname est))
             ((and tarot-item (<= sel-n (or (plist-get tarot-item :max-targets) 1)))
              (format "已选「%s」（预计 +%d 分），可按 [RET] 出牌；也可按 [%s] 对所选牌施放塔罗「%s」（%s）！"
                      hname est tarot-key
                      (plist-get tarot-item :name) (plist-get tarot-item :short)))
             (t
              (format "当前已选「%s」（预计 +%d 分），按 [RET] 出牌；不满意也可按 [d] 弃掉换新牌。"
                      hname est)))))
         (t
          (let* ((best (etaf-balatro--best-hand-in-hand hand))
                 (bname (plist-get best :hand-name))
                 (bidx (plist-get best :indices))
                 (idx-str (mapconcat #'number-to-string bidx "、")))
            (cond
             ((and best (not (equal bname "高牌")))
              (format "手牌可凑「%s」（按 %s 选中）%s；也可按 [s] 切换花色排序找同花%s。"
                      bname idx-str
                      (if (eq (plist-get best :suit) 'hearts) "，可连吃贪婪红心" "")
                      (if planet-item
                          (format "，或按 [u] 先用「%s」升级" (plist-get planet-item :name))
                        "")))
             ((> discards 0)
              (format "当前手牌较散，可按 [s] 切花色排序观察同花，或选几张低点牌按 [d] 弃牌换牌（剩余 %d 次弃牌）。"
                      discards))
             (t
              "按数字 [1-8] 选牌（随时按 [h] 看牌型表，[g] 重看 60 秒新手指引），选好后按 [RET] 出牌。")))))))
     (t nil))))

;; ---------------------------------------------------------------------------
;; Shop Generator (2 Jokers + 1 Planet + 1 Targeted Tarot)
;; ---------------------------------------------------------------------------

(defun etaf-balatro--generate-shop (owned-jokers rng next-uid-fn)
  "Generate 4 shop shelf items (2 Jokers, 1 Planet, 1 Tarot) using RNG."
  (let* ((owned-ids (mapcar (lambda (j) (plist-get j :id)) owned-jokers))
         (avail (cl-remove-if (lambda (j) (memq (plist-get j :id) owned-ids))
                              etaf-balatro--joker-catalog))
         (pool (if (>= (length avail) 2) avail etaf-balatro--joker-catalog))
         (shuffled-jokers (etaf-balatro--rng-shuffle pool rng))
         (j1 (nth 0 shuffled-jokers))
         (j2 (nth 1 shuffled-jokers))
         (planet-spec (nth (etaf-balatro--rng-int rng (length etaf-balatro--hand-specs))
                           etaf-balatro--hand-specs))
         (tarot-def (nth (etaf-balatro--rng-int rng (length etaf-balatro--tarot-catalog))
                         etaf-balatro--tarot-catalog)))
    (list
     (list :uid (funcall next-uid-fn) :kind 'joker :sold nil
           :joker-id (plist-get j1 :id)
           :name (plist-get j1 :name)
           :rarity (plist-get j1 :rarity)
           :cost (plist-get j1 :cost)
           :short (plist-get j1 :short)
           :desc (plist-get j1 :desc))
     (list :uid (funcall next-uid-fn) :kind 'joker :sold nil
           :joker-id (plist-get j2 :id)
           :name (plist-get j2 :name)
           :rarity (plist-get j2 :rarity)
           :cost (plist-get j2 :cost)
           :short (plist-get j2 :short)
           :desc (plist-get j2 :desc))
     (list :uid (funcall next-uid-fn) :kind 'planet :sold nil
           :hand-type (car planet-spec)
           :name (plist-get (cdr planet-spec) :planet)
           :hand-name (plist-get (cdr planet-spec) :name)
           :cost 3
           :short (format "%s 永久升 1 级" (plist-get (cdr planet-spec) :name))
           :desc (format "+%d 筹码 +%d 倍率 · 购买立即生效"
                         (plist-get (cdr planet-spec) :d-chips)
                         (plist-get (cdr planet-spec) :d-mult)))
     (list :uid (funcall next-uid-fn) :kind 'tarot :sold nil
           :tarot-id (plist-get tarot-def :id)
           :name (plist-get tarot-def :name)
           :cost (plist-get tarot-def :cost)
           :max-targets (plist-get tarot-def :max-targets)
           :short (plist-get tarot-def :short)
           :desc (plist-get tarot-def :desc)))))

(provide 'etaf-balatro-engine)
;;; etaf-balatro-engine.el ends here
