;;; etaf-balatro-tests.el --- Public acceptance tests for ETAF Balatro -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-balatro)

(defun etaf-balatro-test--card (id rank suit &optional enh)
  "Construct a plain card plist for public API tests."
  (list :id id :rank rank :suit suit :enhancement (or enh 'none)))

(ert-deftest etaf-balatro-evaluates-all-nine-poker-hands-and-ace-low-straight ()
  "All 9 poker hands, Ace-low straight, hand-level scaling and validation work."
  (let ((sf (etaf-balatro-evaluate-hand
             (list (etaf-balatro-test--card 1 10 'hearts)
                   (etaf-balatro-test--card 2 11 'hearts)
                   (etaf-balatro-test--card 3 12 'hearts)
                   (etaf-balatro-test--card 4 13 'hearts)
                   (etaf-balatro-test--card 5 14 'hearts))))
        (wheel (etaf-balatro-evaluate-hand
                (list (etaf-balatro-test--card 1 14 'spades)
                      (etaf-balatro-test--card 2 2 'hearts)
                      (etaf-balatro-test--card 3 3 'clubs)
                      (etaf-balatro-test--card 4 4 'diamonds)
                      (etaf-balatro-test--card 5 5 'spades))))
        (quads (etaf-balatro-evaluate-hand
                (list (etaf-balatro-test--card 1 9 'spades)
                      (etaf-balatro-test--card 2 9 'hearts)
                      (etaf-balatro-test--card 3 9 'clubs)
                      (etaf-balatro-test--card 4 9 'diamonds)
                      (etaf-balatro-test--card 5 2 'spades))))
        (fh (etaf-balatro-evaluate-hand
             (list (etaf-balatro-test--card 1 13 'spades)
                   (etaf-balatro-test--card 2 13 'hearts)
                   (etaf-balatro-test--card 3 13 'clubs)
                   (etaf-balatro-test--card 4 7 'diamonds)
                   (etaf-balatro-test--card 5 7 'spades))))
        (flush (etaf-balatro-evaluate-hand
                (list (etaf-balatro-test--card 1 14 'hearts)
                      (etaf-balatro-test--card 2 10 'hearts)
                      (etaf-balatro-test--card 3 7 'hearts)
                      (etaf-balatro-test--card 4 4 'hearts)
                      (etaf-balatro-test--card 5 2 'hearts))
                '((flush . 3))))
        (trips (etaf-balatro-evaluate-hand
                (list (etaf-balatro-test--card 1 8 'spades)
                      (etaf-balatro-test--card 2 8 'hearts)
                      (etaf-balatro-test--card 3 8 'clubs))))
        (twop (etaf-balatro-evaluate-hand
               (list (etaf-balatro-test--card 1 11 'spades)
                     (etaf-balatro-test--card 2 11 'hearts)
                     (etaf-balatro-test--card 3 5 'clubs)
                     (etaf-balatro-test--card 4 5 'diamonds))))
        (pair (etaf-balatro-evaluate-hand
               (list (etaf-balatro-test--card 1 6 'spades)
                     (etaf-balatro-test--card 2 6 'hearts)
                     (etaf-balatro-test--card 3 14 'clubs))))
        (high (etaf-balatro-evaluate-hand
               (list (etaf-balatro-test--card 1 14 'spades)
                     (etaf-balatro-test--card 2 9 'hearts)))))
    (should (eq (plist-get sf :hand-type) 'straight-flush))
    (should (eq (plist-get wheel :hand-type) 'straight))
    (should (eq (plist-get quads :hand-type) 'four-of-a-kind))
    (should (equal (plist-get quads :scoring-ids) '(1 2 3 4)))
    (should (eq (plist-get fh :hand-type) 'full-house))
    (should (eq (plist-get flush :hand-type) 'flush))
    (should (= (plist-get flush :level) 3))
    (should (= (plist-get flush :base-chips) 65))
    (should (= (plist-get flush :base-mult) 8))
    (should (eq (plist-get trips :hand-type) 'three-of-a-kind))
    (should (eq (plist-get twop :hand-type) 'two-pair))
    (should (eq (plist-get pair :hand-type) 'one-pair))
    (should (equal (plist-get pair :scoring-ids) '(1 2)))
    (should (eq (plist-get high :hand-type) 'high-card))
    (should (equal (plist-get high :scoring-ids) '(1)))
    (should-error (etaf-balatro-evaluate-hand nil) :type 'etaf-balatro-error)))

(ert-deftest etaf-balatro-scoring-cascade-order-enhancements-and-boss-debuffs ()
  "Joker order (+Mult vs xMult), enhancements, retrigger and Boss traits compute accurately."
  (let* ((played (list (etaf-balatro-test--card 1 14 'hearts 'glass)
                       (etaf-balatro-test--card 2 14 'clubs 'bonus)))
         (held (list (etaf-balatro-test--card 3 8 'spades 'steel)))
         (j-plus '(:id paren-pair :uid 10 :name "括号对子"))
         (j-mult '(:id mult-prism :uid 11 :name "乘算棱镜"))
         (j-macro '(:id macro-recorder :uid 12 :name "宏录制器"))
         (order-good (etaf-balatro-simulate-score
                      played held (list j-plus j-mult) nil
                      :discards-left 1 :seed 7))
         (order-bad (etaf-balatro-simulate-score
                     played held (list j-mult j-plus) nil
                     :discards-left 1 :seed 7))
         (with-macro (etaf-balatro-simulate-score
                      played nil (list j-macro) nil :seed 7))
         (debuffed (etaf-balatro-simulate-score
                    (list (etaf-balatro-test--card 1 14 'spades 'foil))
                    nil nil nil
                    :boss-trait '(:id debuff-spades :name "黑桃封锁") :seed 7))
         (banned (etaf-balatro-simulate-score
                  (list (etaf-balatro-test--card 1 14 'hearts))
                  nil nil nil
                  :boss-trait '(:id ban-high-card :name "高牌禁用") :seed 7)))
    (should (> (plist-get order-good :total-score)
               (plist-get order-bad :total-score)))
    (should (cl-some (lambda (e) (eq (plist-get e :kind) 'held))
                     (plist-get order-good :events)))
    (should (= (plist-get with-macro :final-mult) 8))
    (should (= (plist-get debuffed :final-chips) 5))
    (should (= (plist-get banned :total-score) 0))))

(ert-deftest etaf-balatro-seeded-run-selection-discard-and-timeline-skip ()
  "Seeded runs are reproducible and SPC skip finishes active cascade immediately."
  (let* ((etaf-balatro-records-file nil)
         (etaf-animation-enabled t)
         (r1 (etaf-balatro-new-run :seed 4821 :skip-onboarding t))
         (r2 (etaf-balatro-new-run :seed 4821 :skip-onboarding t))
         (h1 (plist-get (etaf-balatro-state r1) :hand))
         (h2 (plist-get (etaf-balatro-state r2) :hand)))
    (should (equal h1 h2))
    (should (= (length h1) 8))
    (should (eq (etaf-balatro-cycle-sort r1) 'suit))
    (etaf-balatro-toggle-card r1 0)
    (etaf-balatro-toggle-card r1 1)
    (should (= (length (plist-get (etaf-balatro-state r1) :selected-ids)) 2))
    (etaf-balatro-discard r1)
    (should (= (plist-get (etaf-balatro-state r1) :discards-left) 2))
    (should (= (length (plist-get (etaf-balatro-state r1) :hand)) 8))
    (etaf-balatro-toggle-card r1 0)
    (etaf-balatro-toggle-card r1 1)
    (etaf-balatro-play-hand r1)
    (should (plist-get (etaf-balatro-state r1) :animating))
    (etaf-balatro-skip-animation r1)
    (let ((after (etaf-balatro-state r1)))
      (should-not (plist-get after :animating))
      (should (> (plist-get after :score) 0))
      (should (= (plist-get after :hands-left) 3))
      (should (> (length (plist-get after :trace)) 0)))))

(ert-deftest etaf-balatro-targeted-tarot-sculpting-and-planet-consumables ()
  "Planet upgrades hand level while targeted Tarots permanently forge selected cards."
  (let* ((etaf-balatro-records-file nil)
         (etaf-animation-enabled nil)
         (sess (etaf-balatro-new-run :seed 4821 :skip-onboarding t)))
    ;; Starter consumables hold slot 0 Jupiter (Planet) and slot 1 Justice (Glass Tarot)
    (should (= (length (plist-get (etaf-balatro-state sess) :consumables)) 2))
    ;; Casting Tarot with no card selected keeps Tarot and explains why
    (etaf-balatro-use-consumable sess 1)
    (should (= (length (plist-get (etaf-balatro-state sess) :consumables)) 2))
    (should (string-match-p "选中" (plist-get (etaf-balatro-state sess) :message)))
    ;; Select card 0 and cast Justice (slot 1) -> card 0 permanently becomes Glass in hand AND deck
    (let ((target-id (plist-get (nth 0 (plist-get (etaf-balatro-state sess) :hand)) :id)))
      (etaf-balatro-toggle-card sess 0)
      (etaf-balatro-use-consumable sess 1)
      (let* ((st (etaf-balatro-state sess))
             (hand-card (cl-find target-id (plist-get st :hand)
                                 :key (lambda (c) (plist-get c :id))))
             (deck-card (cl-find target-id (plist-get st :deck)
                                 :key (lambda (c) (plist-get c :id)))))
        (should (= (length (plist-get st :consumables)) 1))
        (should (eq (plist-get hand-card :enhancement) 'glass))
        (should (eq (plist-get deck-card :enhancement) 'glass))))
    ;; Now cast Jupiter (remaining at slot 0) -> Flush Lv.2
    (etaf-balatro-use-consumable sess 0)
    (should (null (plist-get (etaf-balatro-state sess) :consumables)))
    (should (= (cdr (assq 'flush (plist-get (etaf-balatro-state sess) :hand-levels))) 2))))

(defun etaf-balatro-test--play-best (sess)
  "Pick the strongest scoring hand (flush or top pairs/hearts) in SESS and play."
  (let* ((hand (plist-get (etaf-balatro-state sess) :hand))
         (by-suit (mapcar (lambda (s)
                            (cl-loop for c in hand for i from 0
                                     when (eq (plist-get c :suit) s) collect i))
                          '(hearts spades diamonds clubs)))
         (flush-idx (cl-find-if (lambda (idxs) (>= (length idxs) 5)) by-suit))
         (picks (or (and flush-idx (cl-subseq flush-idx 0 5))
                    (let ((by-rank nil))
                      (cl-loop for c in hand for i from 0 do
                               (let* ((r (plist-get c :rank))
                                      (cell (assq r by-rank)))
                                 (if cell (setcdr cell (append (cdr cell) (list i)))
                                   (push (cons r (list i)) by-rank))))
                      (setq by-rank (sort by-rank
                                          (lambda (a b)
                                            (let ((la (length (cdr a)))
                                                  (lb (length (cdr b))))
                                              (if (/= la lb) (> la lb) (> (car a) (car b)))))))
                      (let ((res nil))
                        (dolist (g by-rank)
                          (when (and (>= (length (cdr g)) 2)
                                     (<= (+ (length res) (length (cdr g))) 5))
                            (setq res (append res (cdr g)))))
                        (or res '(0 1 2 3 4)))))))
    (etaf-balatro-clear-selection sess)
    (dolist (i picks) (etaf-balatro-toggle-card sess i))
    (etaf-balatro-play-hand sess t)))

(ert-deftest etaf-balatro-winning-blind-transitions-to-shop-and-supports-economy ()
  "Clearing a blind enters shop with payout, buying Jokers/Planets/Tarots, reordering and selling."
  (let* ((etaf-balatro-records-file nil)
         (etaf-animation-enabled nil)
         (sess (etaf-balatro-new-run :seed 101 :skip-onboarding t)))
    ;; Use Jupiter and cast starter Tarot on card 0 so consumables has room for shop Tarot
    (etaf-balatro-use-consumable sess 0)
    (etaf-balatro-toggle-card sess 0)
    (etaf-balatro-use-consumable sess 0)
    (let ((safety 0))
      (while (and (eq (plist-get (etaf-balatro-state sess) :phase) 'playing)
                  (< safety 4))
        (etaf-balatro-test--play-best sess)
        (setq safety (1+ safety))))
    (let ((st (etaf-balatro-state sess)))
      (should (eq (plist-get st :phase) 'shop))
      (should (> (plist-get st :money) 6))
      (should (= (length (plist-get st :shop)) 4))
      (should (eq (plist-get (nth 3 (plist-get st :shop)) :kind) 'tarot))
      ;; Buy Planet (slot 2, $3) and Tarot (slot 3, $3-$4)
      (let ((before-money (plist-get st :money)))
        (etaf-balatro-buy-shop-item sess 2)
        (should (= (plist-get (etaf-balatro-state sess) :money) (- before-money 3)))
        (should (plist-get (nth 2 (plist-get (etaf-balatro-state sess) :shop)) :sold)))
      (let* ((st2 (etaf-balatro-state sess))
             (t-cost (plist-get (nth 3 (plist-get st2 :shop)) :cost)))
        (when (>= (plist-get st2 :money) t-cost)
          (etaf-balatro-buy-shop-item sess 3)
          (should (= (length (plist-get (etaf-balatro-state sess) :consumables)) 1))))
      ;; Buy a Joker if affordable, reorder, and sell
      (let* ((st3 (etaf-balatro-state sess))
             (j-cost (plist-get (nth 0 (plist-get st3 :shop)) :cost)))
        (when (>= (plist-get st3 :money) j-cost)
          (etaf-balatro-buy-shop-item sess 0)
          (let ((jokers-before (mapcar (lambda (j) (plist-get j :uid))
                                       (plist-get (etaf-balatro-state sess) :jokers))))
            (should (= (length jokers-before) 2))
            (etaf-balatro-move-joker sess -1)
            (let ((jokers-after (mapcar (lambda (j) (plist-get j :uid))
                                        (plist-get (etaf-balatro-state sess) :jokers))))
              (should (equal jokers-after (reverse jokers-before))))
            (etaf-balatro-sell-joker sess 0)
            (should (= (length (plist-get (etaf-balatro-state sess) :jokers)) 1)))))
      ;; Advance to Ante 1 Big Blind
      (etaf-balatro-next-blind sess)
      (let ((next (etaf-balatro-state sess)))
        (should (eq (plist-get next :phase) 'playing))
        (should (eq (plist-get next :blind) 'big))
        (should (= (plist-get next :score) 0))
        (should (= (plist-get next :hands-left) 4))))))

(ert-deftest etaf-balatro-onboarding-guide-coach-and-persistent-records ()
  "First run opens 4-step guide, stepping persists tutorial-seen and Coach toggles cleanly."
  (let* ((tmp (make-temp-file "etaf-balatro-rec-" nil ".eld"))
         (etaf-balatro-records-file tmp)
         (etaf-animation-enabled nil))
    (unwind-protect
        (progn
          (delete-file tmp)
          (let ((s1 (etaf-balatro-new-run :seed 4821)))
            ;; Fresh profile opens interactive 4-step guide automatically
            (should (eq (plist-get (etaf-balatro-state s1) :modal) 'guide))
            (should (= (plist-get (etaf-balatro-state s1) :guide-step) 0))
            (should (plist-get (etaf-balatro-state s1) :coach-enabled))
            (should (stringp (plist-get (etaf-balatro-state s1) :coach-hint)))
            ;; Step through all 4 pages; stepping past page 4 closes and persists tutorial-seen
            (should (= (etaf-balatro-guide-step s1 1) 1))
            (should (= (etaf-balatro-guide-step s1 1) 2))
            (should (= (etaf-balatro-guide-step s1 1) 3))
            (should (null (etaf-balatro-guide-step s1 1)))
            (should (null (plist-get (etaf-balatro-state s1) :modal)))
            ;; Toggle Coach off and verify persisted in records
            (should-not (etaf-balatro-toggle-coach s1))
            (let ((rec (etaf-balatro-records)))
              (should (plist-get rec :tutorial-seen))
              (should-not (plist-get rec :coach-enabled))
              (should (= (plist-get rec :runs-played) 1))))
          ;; Second run does NOT auto-open guide because tutorial-seen is persisted
          (let ((s2 (etaf-balatro-new-run :seed 4821)))
            (should (null (plist-get (etaf-balatro-state s2) :modal)))
            (should-not (plist-get (etaf-balatro-state s2) :coach-enabled))
            (should (= (etaf-balatro-open-guide s2 2) 2))
            (should (eq (plist-get (etaf-balatro-state s2) :modal) 'guide))))
      (when (file-exists-p tmp)
        (delete-file tmp)))))

(ert-deftest etaf-balatro-open-renders-guide-matrix-themes-and-preserves-mode-line ()
  "Opening ETAF Balatro preserves mode-line, hides cursor, renders v2 modals and cycles auto/dark/light."
  (let* ((etaf-balatro-records-file nil)
         (etaf-animation-enabled nil)
         (sess (etaf-balatro-new-run :seed 4821 :appearance 'auto :skip-onboarding t))
         (buf (etaf-balatro-open sess)))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer buf)))
          (should (buffer-live-p buf))
          (should runtime)
          (etaf-runtime-refit runtime 148 48)
          (with-current-buffer buf
            (should mode-line-format)
            (should (null cursor-type))
            (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "ETAF BALATRO" txt))
              (should (string-match-p "小盲注" txt))
              (should (string-match-p "贪婪红心" txt))
              (should (string-match-p "实战提示" txt))))
          ;; Open 4-step Onboarding Guide modal
          (etaf-balatro-open-guide sess 0)
          (with-current-buffer buf
            (should (string-match-p "60 秒小丑牌入门"
                                    (buffer-substring-no-properties (point-min) (point-max)))))
          ;; Toggle 52-card Deck Matrix modal and Hand Levels modal
          (etaf-balatro-toggle-modal sess 'deck)
          (with-current-buffer buf
            (should (string-match-p "52 张牌库矩阵"
                                    (buffer-substring-no-properties (point-min) (point-max)))))
          (etaf-balatro-toggle-modal sess 'hands)
          (with-current-buffer buf
            (should (string-match-p "扑克牌型与当前升级倍率表"
                                    (buffer-substring-no-properties (point-min) (point-max)))))
          (etaf-balatro-toggle-modal sess nil)
          ;; Cycle auto -> dark -> light -> auto and refit narrow viewport
          (should (eq (etaf-balatro-toggle-appearance sess) 'dark))
          (should (eq (etaf-balatro-toggle-appearance sess) 'light))
          (should (eq (etaf-balatro-toggle-appearance sess) 'auto))
          (etaf-runtime-refit runtime 72 28)
          (with-current-buffer buf
            (should (string-match-p "ETAF BALATRO"
                                    (buffer-substring-no-properties (point-min) (point-max))))))
      (when (buffer-live-p buf)
        (etaf-app-close buf)))))

(ert-deftest etaf-balatro-gui-return-arrows-modal-toggles-and-card-focus ()
  "GUI <return>, guide arrow directions, modal toggles and card-focused Enter work."
  (let* ((etaf-balatro-records-file nil)
         (etaf-animation-enabled nil)
         (sess (etaf-balatro-new-run :seed 4821 :appearance 'dark))
         (buf (etaf-balatro-open sess)))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (let ((rt (etaf-runtime-for-buffer buf)))
            (etaf-runtime-refit rt 148 48)
            ;; Auto-opened guide: arrows return handled/release without error
            (should (eq (plist-get (etaf-balatro-state sess) :modal) 'guide))
            (etaf-direction 'right rt)
            (should (= (plist-get (etaf-balatro-state sess) :guide-step) 1))
            (etaf-direction 'left rt)
            (should (= (plist-get (etaf-balatro-state sess) :guide-step) 0))
            (etaf-direction 'down rt)
            (etaf-direction 'up rt)
            ;; GUI <return> steps through guide pages and closes after page 4
            (execute-kbd-macro (kbd "<return> <return> <return> <return>"))
            (should (null (plist-get (etaf-balatro-state sess) :modal)))
            ;; v and h toggle Deck Matrix and Hand Levels open AND closed
            (execute-kbd-macro "v")
            (should (eq (plist-get (etaf-balatro-state sess) :modal) 'deck))
            (execute-kbd-macro "v")
            (should (null (plist-get (etaf-balatro-state sess) :modal)))
            (execute-kbd-macro "h")
            (should (eq (plist-get (etaf-balatro-state sess) :modal) 'hands))
            (execute-kbd-macro "h")
            (should (null (plist-get (etaf-balatro-state sess) :modal)))
            ;; Selecting cards by keyboard then pressing GUI <return> plays hand
            (execute-kbd-macro (kbd "1 2 <return>"))
            (should (= (plist-get (etaf-balatro-state sess) :hands-left) 3))
            (should (> (plist-get (etaf-balatro-state sess) :score) 0))
            ;; Every painted cell of a playing card must be clickable (no dead face!)
            (let* ((bounds (etaf-host-ref-bounds rt 'balatro-hand-card-0))
                   (tot 0) (dead 0))
              (should bounds)
              (save-excursion
                (goto-char (car bounds))
                (while (< (point) (cdr bounds))
                  (let ((bol (line-beginning-position))
                        (eol (line-end-position)))
                    (cl-loop for p from bol below eol do
                             (when (eq (etaf-host-ref-at rt p) 'balatro-hand-card-0)
                               (cl-incf tot)
                               (let ((km (get-text-property p 'keymap)))
                                 (unless (and km (lookup-key km [mouse-1]))
                                   (cl-incf dead))))))
                  (forward-line 1)))
              (should (> tot 20))
              (should (= dead 0)))
            ;; Mouse-clicking a card (pointer press) then pressing GUI <return>
            ;; ALSO plays hand (never deselects the clicked card!).
            (let ((last-input-event '(mouse-1 (nil 1 (0 . 0) 0))))
              (etaf-focus rt 'balatro-hand-card-0)
              (etaf-dispatch-event rt 'balatro-hand-card-0 'press))
            (should (= (length (plist-get (etaf-balatro-state sess) :selected-ids)) 1))
            (execute-kbd-macro (kbd "<return>"))
            (should (= (plist-get (etaf-balatro-state sess) :hands-left) 2))))
      (when (buffer-live-p buf)
        (etaf-app-close buf)))))

(ert-deftest etaf-balatro-validates-invalid-session-speed-and-modal ()
  "Public API signals `etaf-balatro-error' for invalid sessions, speeds and modals."
  (let* ((etaf-balatro-records-file nil)
         (sess (etaf-balatro-new-run :seed 42 :skip-onboarding t)))
    (should-error (etaf-balatro-state 'not-a-session) :type 'etaf-balatro-error)
    (should-error (etaf-balatro-set-speed sess 3.0) :type 'etaf-balatro-error)
    (should-error (etaf-balatro-toggle-modal sess 'unknown) :type 'etaf-balatro-error)
    (should (= (etaf-balatro-set-speed sess 2.0) 2.0))
    (should (= (etaf-balatro-set-speed sess 4.0) 4.0))))

(ert-deftest etaf-balatro-rapid-guide-and-chaos-key-mashing-stays-usable ()
  "Rapidly mashing `g', `G', `v', `h' and game keys never corrupts state or focus."
  (let* ((tmp (make-temp-file "etaf-balatro-chaos-" nil ".eld"))
         (etaf-balatro-records-file tmp)
         (etaf-animation-enabled t)
         (sess (etaf-balatro-new-run :seed 4821 :appearance 'dark :skip-onboarding t))
         (buf (etaf-balatro-open sess)))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (let ((rt (etaf-runtime-for-buffer buf)))
            (etaf-runtime-refit rt 148 48)
            ;; Rapidly toggle the beginner guide 40 times in a row.
            (dotimes (_ 40)
              (execute-kbd-macro "g"))
            (should (null (plist-get (etaf-balatro-state sess) :modal)))
            ;; Mix modal keys, navigation, coach toggle, appearance, sorting,
            ;; consumables and escape rapidly.
            (execute-kbd-macro
             (kbd "g 2 3 4 <left> <right> p n g v v h h G G t t t s s"))
            (should (null (plist-get (etaf-balatro-state sess) :modal)))
            ;; Starting a scoring cascade and skipping multiple times is safe.
            (execute-kbd-macro (kbd "1 2 <return>"))
            (should (plist-get (etaf-balatro-state sess) :animating))
            (etaf-balatro-skip-animation sess)
            (etaf-balatro-skip-animation sess)
            (let ((st (etaf-balatro-state sess)))
              (should-not (plist-get st :animating))
              (should (> (plist-get st :score) 0))
              (should (= (plist-get st :hands-left) 3)))
            ;; Opening guide while selecting cards, dismissing via Escape, and
            ;; continuing to play works cleanly.
            (execute-kbd-macro (kbd "g g g <escape> 1 2 <return> SPC"))
            (let ((st2 (etaf-balatro-state sess)))
              (should (null (plist-get st2 :modal)))
              (should-not (plist-get st2 :animating))
              (should (= (plist-get st2 :hands-left) 2)))))
      (when (buffer-live-p buf)
        (etaf-app-close buf))
      (when (file-exists-p tmp)
        (delete-file tmp)))))

(provide 'etaf-balatro-tests)
;;; etaf-balatro-tests.el ends here
