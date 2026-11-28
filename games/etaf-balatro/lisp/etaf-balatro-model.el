;;; etaf-balatro-model.el --- Reactive run state, Tarots, records and onboarding -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Reactive session model for `etaf-balatro'.  Wraps the pure rules engine in
;; `etaf-ref' values, persists lifetime records and onboarding preferences,
;; supports targeted Tarot deck sculpting on selected hand cards, drives the
;; 4-step interactive beginner guide and toggleable smart Coach ribbon, and
;; choreographs left-to-right scoring cascades via `etaf-animation-timeline'.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-balatro-engine)

(defcustom etaf-balatro-default-speed 1.0
  "Default scoring cascade playback speed multiplier (1.0, 2.0 or 4.0)."
  :type '(choice (const :tag "1x" 1.0)
                 (const :tag "2x" 2.0)
                 (const :tag "4x" 4.0))
  :group 'applications)

(defcustom etaf-balatro-records-file
  (locate-user-emacs-file "etaf-balatro-records.eld")
  "File storing persistent ETAF Balatro lifetime stats and onboarding state.
Bind to nil to disable disk persistence (for example in automated tests)."
  :type '(choice (const :tag "Disable persistence" nil)
                 file)
  :group 'applications)

(defconst etaf-balatro--valid-speeds '(1.0 2.0 4.0)
  "Supported scoring animation speed multipliers.")

(defconst etaf-balatro--max-jokers 5
  "Maximum number of Joker passive slots.")

(defconst etaf-balatro--max-consumables 2
  "Maximum number of held consumable slots.")

(defconst etaf-balatro--hand-size 8
  "Number of cards dealt to the player's hand.")

(defconst etaf-balatro--guide-page-count 4
  "Total number of interactive onboarding guide pages.")

;; ---------------------------------------------------------------------------
;; Persistent Records & Preferences
;; ---------------------------------------------------------------------------

(defun etaf-balatro--default-records ()
  "Return a fresh default lifetime records plist."
  (list :tutorial-seen nil
        :coach-enabled t
        :runs-played 0
        :wins 0
        :best-ante 1
        :best-hand-score 0
        :best-hand-name ""))

(defun etaf-balatro--load-records ()
  "Load persistent lifetime records plist from `etaf-balatro-records-file'."
  (let ((base (etaf-balatro--default-records)))
    (if (and (stringp etaf-balatro-records-file)
             (file-readable-p etaf-balatro-records-file))
        (condition-case nil
            (with-temp-buffer
              (insert-file-contents etaf-balatro-records-file)
              (let ((data (read (current-buffer))))
                (if (and (listp data) (keywordp (car data)))
                    (let ((merged (copy-sequence base)))
                      (while data
                        (let ((k (pop data))
                              (v (pop data)))
                          (setq merged (plist-put merged k v))))
                      merged)
                  base)))
          (error base))
      base)))

(defun etaf-balatro--save-records (records)
  "Write RECORDS plist to `etaf-balatro-records-file' when non-nil."
  (when (stringp etaf-balatro-records-file)
    (ignore-errors
      (let ((dir (file-name-directory etaf-balatro-records-file)))
        (when (and dir (not (file-directory-p dir)))
          (make-directory dir t)))
      (with-temp-file etaf-balatro-records-file
        (let ((print-length nil)
              (print-level nil))
          (prin1 records (current-buffer))
          (insert "\n")))))
  records)

(defun etaf-balatro--update-records (session mutator)
  "Apply MUTATOR to SESSION's records copy, saving only when changed."
  (let* ((prev (or (etaf-balatro--val session :records)
                   (etaf-balatro--load-records)))
         (next (funcall mutator (copy-sequence prev))))
    (unless (equal prev next)
      (etaf-balatro--save-records next)
      (etaf-balatro--set session :records next))
    next))

;;;###autoload
(defun etaf-balatro-records ()
  "Return a fresh copy of persistent ETAF Balatro lifetime records."
  (copy-sequence (etaf-balatro--load-records)))

;; ---------------------------------------------------------------------------
;; Session Helpers
;; ---------------------------------------------------------------------------

(defun etaf-balatro--require-session (session)
  "Validate SESSION plist or signal `etaf-balatro-error'."
  (unless (and (listp session) (eq (plist-get session :type) 'etaf-balatro-session))
    (signal 'etaf-balatro-error (list "Invalid etaf-balatro session" session)))
  session)

(defun etaf-balatro--next-uid (session)
  "Return a monotonically increasing integer UID for SESSION."
  (let* ((cell (plist-get session :uid-counter))
         (next (1+ (car cell))))
    (setcar cell next)
    next))

(defun etaf-balatro--val (session key)
  "Read untracked value of reactive ref KEY in SESSION."
  (etaf-untracked (etaf-value (plist-get session key))))

(defun etaf-balatro--set (session key value)
  "Set reactive ref KEY in SESSION to VALUE."
  (setf (etaf-value (plist-get session key)) value))

(defun etaf-balatro--stop-timeline (session)
  "Dispose any active scoring timeline scope owned by SESSION."
  (let ((scope-cell (plist-get session :timeline-scope))
        (tl-cell (plist-get session :timeline-ref)))
    (when (car scope-cell)
      (ignore-errors (etaf-scope-stop (car scope-cell)))
      (setcar scope-cell nil))
    (setcar tl-cell nil)))

(defun etaf-balatro--next-blind-coords (ante blind)
  "Return (NEXT-ANTE . NEXT-BLIND) following ANTE and BLIND."
  (pcase blind
    ('small (cons ante 'big))
    ('big (cons ante 'boss))
    (_ (cons (1+ ante) 'small))))

(defun etaf-balatro--draw-up-to (draw-pile hand limit)
  "Draw cards from DRAW-PILE into HAND until LIMIT cards are held.
Returns (NEW-DRAW-PILE . NEW-HAND)."
  (let ((pile draw-pile)
        (cur hand))
    (while (and (< (length cur) limit) pile)
      (push (car pile) cur)
      (setq pile (cdr pile)))
    (cons pile cur)))

(defun etaf-balatro--compute-preview (session)
  "Return live hand preview plist for currently selected cards in SESSION."
  (let* ((hand (etaf-balatro--val session :hand))
         (selected-ids (etaf-balatro--val session :selected-ids))
         (selected (cl-remove-if-not
                    (lambda (c) (memq (plist-get c :id) selected-ids))
                    hand)))
    (if (null selected)
        nil
      (let* ((held (cl-remove-if
                    (lambda (c) (memq (plist-get c :id) selected-ids))
                    hand))
             (sim (etaf-balatro-simulate-score
                   selected held
                   (etaf-balatro--val session :jokers)
                   (etaf-balatro--val session :hand-levels)
                   :hands-left (etaf-balatro--val session :hands-left)
                   :discards-left (etaf-balatro--val session :discards-left)
                   :money (etaf-balatro--val session :money)
                   :boss-trait (etaf-balatro--val session :boss-trait)
                   :seed (car (plist-get session :rng)))))
        (list :hand-type (plist-get sim :hand-type)
              :hand-name (plist-get sim :hand-name)
              :level (plist-get sim :level)
              :base-chips (plist-get sim :base-chips)
              :base-mult (plist-get sim :base-mult)
              :estimated-chips (plist-get sim :final-chips)
              :estimated-mult (plist-get sim :final-mult)
              :estimated-score (plist-get sim :total-score))))))

(defun etaf-balatro--session-coach-hint (session)
  "Compute live contextual Coach hint for SESSION."
  (etaf-balatro--coach-hint
   (list :phase (etaf-balatro--val session :phase)
         :animating (etaf-balatro--val session :animating)
         :jokers (etaf-balatro--val session :jokers)
         :hand (etaf-balatro--val session :hand)
         :selected-ids (etaf-balatro--val session :selected-ids)
         :consumables (etaf-balatro--val session :consumables)
         :discards-left (etaf-balatro--val session :discards-left)
         :score (etaf-balatro--val session :score)
         :target (etaf-balatro--val session :target)
         :money (etaf-balatro--val session :money)
         :boss-trait (etaf-balatro--val session :boss-trait)
         :next-blind-spec (etaf-balatro--val session :next-blind-spec)
         :preview (etaf-balatro--compute-preview session))))

(defun etaf-balatro--deal-blind (session ante blind)
  "Configure SESSION for ANTE and BLIND, shuffling deck and dealing a hand."
  (let* ((rng (plist-get session :rng))
         (spec (etaf-balatro--blind-spec ante blind rng))
         (next-coords (etaf-balatro--next-blind-coords ante blind))
         (next-preview (when (<= (car next-coords) 8)
                         (let ((peek-rng (list (car rng))))
                           (etaf-balatro--blind-spec
                            (car next-coords) (cdr next-coords) peek-rng))))
         (deck (etaf-balatro--val session :deck))
         (shuffled (etaf-balatro--rng-shuffle deck rng))
         (dealt (etaf-balatro--draw-up-to shuffled nil etaf-balatro--hand-size))
         (sort-mode (etaf-balatro--val session :sort-mode))
         (hand (etaf-balatro--sort-cards (cdr dealt) sort-mode))
         (boss-trait (plist-get spec :boss-trait))
         (discards (if (and boss-trait (eq (plist-get boss-trait :id) 'no-discards))
                       0 3)))
    (etaf-batch
      (etaf-balatro--set session :phase 'playing)
      (etaf-balatro--set session :ante ante)
      (etaf-balatro--set session :blind blind)
      (etaf-balatro--set session :blind-name (plist-get spec :name))
      (etaf-balatro--set session :blind-reward (plist-get spec :reward))
      (etaf-balatro--set session :boss-trait boss-trait)
      (etaf-balatro--set session :next-blind-spec next-preview)
      (etaf-balatro--set session :target (plist-get spec :target))
      (etaf-balatro--set session :score 0)
      (etaf-balatro--set session :hands-left 4)
      (etaf-balatro--set session :discards-left discards)
      (etaf-balatro--set session :draw-pile (car dealt))
      (etaf-balatro--set session :hand hand)
      (etaf-balatro--set session :selected-ids nil)
      (etaf-balatro--set session :played-cards nil)
      (etaf-balatro--set session :animating nil)
      (etaf-balatro--set session :active-event nil)
      (etaf-balatro--set session :active-card-id nil)
      (etaf-balatro--set session :active-joker-uid nil)
      (etaf-balatro--set session :display-chips 0)
      (etaf-balatro--set session :display-mult 0)
      (etaf-balatro--set session :display-hand-name nil)
      (etaf-balatro--set session :display-hand-level nil)
      (etaf-balatro--set session :last-hand-score 0)
      (etaf-balatro--set session :step-index 0)
      (etaf-balatro--set session :step-total 0)
      (etaf-balatro--set session :trace nil)
      (etaf-balatro--set session :message
                      (if boss-trait
                          (format "Boss 盲注「%s」：%s"
                                  (plist-get boss-trait :name)
                                  (plist-get boss-trait :desc))
                        (format "阶段 %d · %s — 目标 %d 分，按 1-8 选牌后按 RET 出牌"
                                ante (plist-get spec :name)
                                (plist-get spec :target)))))))

(defun etaf-balatro--init-run-state (session seed &optional preserve-modal)
  "Reset SESSION to a fresh run seeded by integer SEED."
  (etaf-balatro--stop-timeline session)
  (let* ((s (if (integerp seed) (abs seed) (mod (abs (random)) 9000)))
         (rng (list (+ 1000 s)))
         (deck (etaf-balatro--make-standard-deck))
         (starter-joker (etaf-balatro--make-joker 'greedy-heart 1))
         (starter-planet (list :uid 2 :kind 'planet :hand-type 'flush
                               :name "木星" :hand-name "同花"
                               :short "同花 升 1 级"
                               :desc "同花永久升 1 级 (+15 筹码 +2 倍率)"))
         (starter-tarot (etaf-balatro--make-tarot 'justice 3)))
    (setcar (plist-get session :rng) (car rng))
    (setcar (plist-get session :uid-counter) 10)
    (etaf-batch
      (etaf-balatro--set session :seed s)
      (etaf-balatro--set session :money 6)
      (etaf-balatro--set session :deck deck)
      (etaf-balatro--set session :jokers (list starter-joker))
      (etaf-balatro--set session :selected-joker-index 0)
      (etaf-balatro--set session :consumables (list starter-planet starter-tarot))
      (etaf-balatro--set session :hand-levels (etaf-balatro--default-hand-levels))
      (etaf-balatro--set session :shop nil)
      (etaf-balatro--set session :last-payout nil)
      (unless preserve-modal
        (etaf-balatro--set session :modal nil))
      (etaf-balatro--set session :best-hand-score 0)
      (etaf-balatro--set session :best-hand-name "")
      (etaf-balatro--set session :hands-played 0))
    (etaf-balatro--update-records
     session
     (lambda (rec)
       (plist-put rec :runs-played (1+ (or (plist-get rec :runs-played) 0)))))
    (etaf-balatro--deal-blind session 1 'small)
    session))

;;;###autoload
(cl-defun etaf-balatro-new-run (&key seed (appearance 'auto) speed skip-onboarding)
  "Create and return a new deterministic `etaf-balatro' run session.
SEED is an optional integer for reproducible deals and shop rolls.
APPEARANCE is `auto' (default, follows active Emacs theme), `dark' or `light'.
SPEED is 1.0, 2.0 or 4.0.  When SKIP-ONBOARDING is nil and the player has not
yet seen the interactive guide, opens the 4-step beginner guide automatically."
  (let* ((spd (float (or speed etaf-balatro-default-speed 1.0)))
         (app (if (memq appearance '(auto dark light)) appearance 'auto))
         (rec (etaf-balatro--load-records))
         (show-guide (and (not skip-onboarding)
                          (not (plist-get rec :tutorial-seen)))))
    (unless (member spd etaf-balatro--valid-speeds)
      (signal 'etaf-balatro-error (list "Speed must be 1.0, 2.0 or 4.0" speed)))
    (let ((session
           (list :type 'etaf-balatro-session
                 :rng (list 4821)
                 :uid-counter (list 10)
                 :timeline-scope (list nil)
                 :timeline-ref (list nil)
                 :seed (etaf-ref 4821 :name 'balatro-seed)
                 :appearance (etaf-ref app :name 'balatro-appearance)
                 :speed (etaf-ref spd :name 'balatro-speed)
                 :phase (etaf-ref 'playing :name 'balatro-phase)
                 :ante (etaf-ref 1 :name 'balatro-ante)
                 :blind (etaf-ref 'small :name 'balatro-blind)
                 :blind-name (etaf-ref "小盲注" :name 'balatro-blind-name)
                 :blind-reward (etaf-ref 3 :name 'balatro-blind-reward)
                 :boss-trait (etaf-ref nil :name 'balatro-boss-trait)
                 :next-blind-spec (etaf-ref nil :name 'balatro-next-blind)
                 :target (etaf-ref 300 :name 'balatro-target)
                 :score (etaf-ref 0 :name 'balatro-score)
                 :hands-left (etaf-ref 4 :name 'balatro-hands-left)
                 :discards-left (etaf-ref 3 :name 'balatro-discards-left)
                 :money (etaf-ref 6 :name 'balatro-money)
                 :deck (etaf-ref nil :name 'balatro-deck)
                 :draw-pile (etaf-ref nil :name 'balatro-draw-pile)
                 :hand (etaf-ref nil :name 'balatro-hand)
                 :selected-ids (etaf-ref nil :name 'balatro-selected-ids)
                 :played-cards (etaf-ref nil :name 'balatro-played-cards)
                 :sort-mode (etaf-ref 'rank :name 'balatro-sort-mode)
                 :jokers (etaf-ref nil :name 'balatro-jokers)
                 :selected-joker-index (etaf-ref 0 :name 'balatro-sel-joker)
                 :consumables (etaf-ref nil :name 'balatro-consumables)
                 :hand-levels (etaf-ref nil :name 'balatro-hand-levels)
                 :animating (etaf-ref nil :name 'balatro-animating)
                 :active-event (etaf-ref nil :name 'balatro-active-event)
                 :active-card-id (etaf-ref nil :name 'balatro-active-card)
                 :active-joker-uid (etaf-ref nil :name 'balatro-active-joker)
                 :display-chips (etaf-ref 0 :name 'balatro-disp-chips)
                 :display-mult (etaf-ref 0 :name 'balatro-disp-mult)
                 :display-hand-name (etaf-ref nil :name 'balatro-disp-hand)
                 :display-hand-level (etaf-ref nil :name 'balatro-disp-level)
                 :last-hand-score (etaf-ref 0 :name 'balatro-last-score)
                 :step-index (etaf-ref 0 :name 'balatro-step-idx)
                 :step-total (etaf-ref 0 :name 'balatro-step-total)
                 :trace (etaf-ref nil :name 'balatro-trace)
                 :shop (etaf-ref nil :name 'balatro-shop)
                 :last-payout (etaf-ref nil :name 'balatro-payout)
                 :modal (etaf-ref (when show-guide 'guide) :name 'balatro-modal)
                 :guide-step (etaf-ref 0 :name 'balatro-guide-step)
                 :coach-enabled (etaf-ref (not (null (plist-get rec :coach-enabled)))
                                          :name 'balatro-coach-enabled)
                 :records (etaf-ref rec :name 'balatro-records)
                 :best-hand-score (etaf-ref 0 :name 'balatro-best-hand)
                 :best-hand-name (etaf-ref "" :name 'balatro-best-hand-name)
                 :hands-played (etaf-ref 0 :name 'balatro-hands-played)
                 :message (etaf-ref "" :name 'balatro-message))))
      (etaf-balatro--init-run-state session (or seed 4821) show-guide))))

;;;###autoload
(defun etaf-balatro-state (session)
  "Return a plain read-only snapshot plist of SESSION."
  (etaf-balatro--require-session session)
  (list :phase (etaf-balatro--val session :phase)
        :seed (etaf-balatro--val session :seed)
        :ante (etaf-balatro--val session :ante)
        :blind (etaf-balatro--val session :blind)
        :blind-name (etaf-balatro--val session :blind-name)
        :boss-trait (etaf-balatro--val session :boss-trait)
        :target (etaf-balatro--val session :target)
        :score (etaf-balatro--val session :score)
        :hands-left (etaf-balatro--val session :hands-left)
        :discards-left (etaf-balatro--val session :discards-left)
        :money (etaf-balatro--val session :money)
        :hand (copy-sequence (etaf-balatro--val session :hand))
        :selected-ids (copy-sequence (etaf-balatro--val session :selected-ids))
        :played-cards (copy-sequence (etaf-balatro--val session :played-cards))
        :jokers (copy-sequence (etaf-balatro--val session :jokers))
        :selected-joker-index (etaf-balatro--val session :selected-joker-index)
        :consumables (copy-sequence (etaf-balatro--val session :consumables))
        :hand-levels (copy-alist (etaf-balatro--val session :hand-levels))
        :deck (copy-sequence (etaf-balatro--val session :deck))
        :deck-remaining (length (etaf-balatro--val session :draw-pile))
        :deck-total (length (etaf-balatro--val session :deck))
        :sort-mode (etaf-balatro--val session :sort-mode)
        :speed (etaf-balatro--val session :speed)
        :appearance (etaf-balatro--val session :appearance)
        :animating (etaf-balatro--val session :animating)
        :active-event (etaf-balatro--val session :active-event)
        :step-index (etaf-balatro--val session :step-index)
        :step-total (etaf-balatro--val session :step-total)
        :trace (copy-sequence (etaf-balatro--val session :trace))
        :shop (copy-sequence (etaf-balatro--val session :shop))
        :last-payout (etaf-balatro--val session :last-payout)
        :modal (etaf-balatro--val session :modal)
        :guide-step (etaf-balatro--val session :guide-step)
        :coach-enabled (etaf-balatro--val session :coach-enabled)
        :coach-hint (etaf-balatro--session-coach-hint session)
        :records (copy-sequence (etaf-balatro--val session :records))
        :best-hand-score (etaf-balatro--val session :best-hand-score)
        :best-hand-name (etaf-balatro--val session :best-hand-name)
        :preview (etaf-balatro--compute-preview session)
        :message (etaf-balatro--val session :message)))

;; ---------------------------------------------------------------------------
;; Hand Selection, Sorting & Discard
;; ---------------------------------------------------------------------------

;;;###autoload
(defun etaf-balatro-toggle-card (session index)
  "Toggle selection of the card at 0-based INDEX in SESSION's hand."
  (etaf-balatro--require-session session)
  (when (and (eq (etaf-balatro--val session :phase) 'playing)
             (not (etaf-balatro--val session :animating))
             (> (etaf-balatro--val session :hands-left) 0))
    (let* ((hand (etaf-balatro--val session :hand))
           (card (and (integerp index) (>= index 0) (< index (length hand))
                      (nth index hand))))
      (when card
        (let* ((cid (plist-get card :id))
               (cur (etaf-balatro--val session :selected-ids)))
          (cond
           ((memq cid cur)
            (etaf-balatro--set session :selected-ids (delq cid (copy-sequence cur))))
           ((>= (length cur) 5)
            (etaf-balatro--set session :message "每次最多选择 5 张牌出牌或弃牌"))
           (t
            (etaf-balatro--set session :selected-ids (append cur (list cid)))))))))
  (etaf-balatro--val session :selected-ids))

;;;###autoload
(defun etaf-balatro-clear-selection (session)
  "Deselect all currently selected cards in SESSION."
  (etaf-balatro--require-session session)
  (unless (etaf-balatro--val session :animating)
    (etaf-balatro--set session :selected-ids nil))
  nil)

;;;###autoload
(defun etaf-balatro-cycle-sort (session)
  "Toggle SESSION's hand sort mode between `rank' and `suit'."
  (etaf-balatro--require-session session)
  (let* ((next (if (eq (etaf-balatro--val session :sort-mode) 'rank) 'suit 'rank))
         (sorted (etaf-balatro--sort-cards (etaf-balatro--val session :hand) next)))
    (etaf-batch
      (etaf-balatro--set session :sort-mode next)
      (etaf-balatro--set session :hand sorted))
    next))

;;;###autoload
(defun etaf-balatro-discard (session)
  "Discard currently selected cards in SESSION and draw replacements."
  (etaf-balatro--require-session session)
  (when (and (eq (etaf-balatro--val session :phase) 'playing)
             (not (etaf-balatro--val session :animating))
             (> (etaf-balatro--val session :hands-left) 0))
    (let* ((selected-ids (etaf-balatro--val session :selected-ids))
           (discards (etaf-balatro--val session :discards-left)))
      (cond
       ((<= discards 0)
        (etaf-balatro--set session :message "本关已无剩余弃牌次数"))
       ((null selected-ids)
        (etaf-balatro--set session :message "请先按数字 1-8 选中至少 1 张要弃掉的牌"))
       (t
        (let* ((hand (etaf-balatro--val session :hand))
               (kept (cl-remove-if
                      (lambda (c) (memq (plist-get c :id) selected-ids))
                      hand))
               (dealt (etaf-balatro--draw-up-to
                       (etaf-balatro--val session :draw-pile)
                       kept etaf-balatro--hand-size))
               (sorted (etaf-balatro--sort-cards
                        (cdr dealt) (etaf-balatro--val session :sort-mode)))
               (jokers (mapcar
                        (lambda (j)
                          (if (eq (plist-get j :id) 'gc-collector)
                              (let ((cp (copy-sequence j)))
                                (plist-put cp :bonus-chips
                                           (+ 8 (or (plist-get cp :bonus-chips) 0))))
                            j))
                        (etaf-balatro--val session :jokers)))
               (gc-grew (cl-some (lambda (j) (eq (plist-get j :id) 'gc-collector))
                                 jokers)))
          (etaf-batch
            (etaf-balatro--set session :discards-left (1- discards))
            (etaf-balatro--set session :draw-pile (car dealt))
            (etaf-balatro--set session :hand sorted)
            (etaf-balatro--set session :selected-ids nil)
            (etaf-balatro--set session :jokers jokers)
            (etaf-balatro--set session :message
                            (format "已弃掉 %d 张牌并补牌%s"
                                    (length selected-ids)
                                    (if gc-grew " · 垃圾回收器 +8 筹码!" "")))))))))
  (etaf-balatro--val session :hand))

;; ---------------------------------------------------------------------------
;; Scoring Cascade Playback (`etaf-animation-timeline')
;; ---------------------------------------------------------------------------

(defun etaf-balatro--finish-hand (session sim)
  "Commit final scoring result SIM to SESSION after cascade completes."
  (let* ((total (plist-get sim :total-score))
         (hand-name (or (plist-get sim :hand-name) ""))
         (new-score (+ (etaf-balatro--val session :score) total))
         (target (etaf-balatro--val session :target))
         (hands-left (etaf-balatro--val session :hands-left))
         (shattered (plist-get sim :shattered-ids))
         (deck (if shattered
                   (cl-remove-if (lambda (c) (memq (plist-get c :id) shattered))
                                 (etaf-balatro--val session :deck))
                 (etaf-balatro--val session :deck)))
         (prev-best (etaf-balatro--val session :best-hand-score))
         (best (max prev-best total))
         (best-name (if (> total prev-best) hand-name
                      (etaf-balatro--val session :best-hand-name)))
         (ante (etaf-balatro--val session :ante))
         (blind (etaf-balatro--val session :blind))
         (won-run (and (>= new-score target) (= ante 8) (eq blind 'boss))))
    (etaf-balatro--update-records
     session
     (lambda (rec)
       (when (> total (or (plist-get rec :best-hand-score) 0))
         (plist-put rec :best-hand-score total)
         (plist-put rec :best-hand-name hand-name))
       (when (> ante (or (plist-get rec :best-ante) 1))
         (plist-put rec :best-ante ante))
       (when won-run
         (plist-put rec :wins (1+ (or (plist-get rec :wins) 0)))
         (plist-put rec :best-ante 8))
       rec))
    (etaf-batch
      (etaf-balatro--set session :animating nil)
      (etaf-balatro--set session :active-event nil)
      (etaf-balatro--set session :active-card-id nil)
      (etaf-balatro--set session :active-joker-uid nil)
      (etaf-balatro--set session :display-chips (plist-get sim :final-chips))
      (etaf-balatro--set session :display-mult (plist-get sim :final-mult))
      (etaf-balatro--set session :last-hand-score total)
      (etaf-balatro--set session :score new-score)
      (etaf-balatro--set session :deck deck)
      (etaf-balatro--set session :best-hand-score best)
      (etaf-balatro--set session :best-hand-name best-name)
      (cond
       ((>= new-score target)
        (if won-run
            (progn
              (etaf-balatro--set session :phase 'victory)
              (etaf-balatro--set session :message
                              (format "通关全部 8 阶段！最高单手 %d 分（%s），按 N 再来一局"
                                      best best-name)))
          (let* ((reward (etaf-balatro--val session :blind-reward))
                 (hand-bonus hands-left)
                 (money (etaf-balatro--val session :money))
                 (interest (min 5 (/ (max 0 money) 5)))
                 (earned (+ reward hand-bonus interest))
                 (new-money (+ money earned))
                 (shop (etaf-balatro--generate-shop
                        (etaf-balatro--val session :jokers)
                        (plist-get session :rng)
                        (lambda () (etaf-balatro--next-uid session)))))
            (etaf-balatro--set session :money new-money)
            (etaf-balatro--set session :last-payout
                            (list :reward reward
                                  :hand-bonus hand-bonus
                                  :interest interest
                                  :total earned
                                  :blind-name (etaf-balatro--val session :blind-name)
                                  :ante ante))
            (etaf-balatro--set session :shop shop)
            (etaf-balatro--set session :phase 'shop)
            (etaf-balatro--set session :message
                            (format "盲注击破！入账 +$%d（赏金 $%d + 余手 $%d + 利息 $%d）"
                                    earned reward hand-bonus interest)))))
       ((<= hands-left 0)
        (etaf-balatro--set session :phase 'gameover)
        (etaf-balatro--set session :message
                        (format "出牌耗尽（%d / %d），本局止步阶段 %d · 按 N 重新挑战"
                                new-score target ante)))
       (t
        (let* ((dealt (etaf-balatro--draw-up-to
                       (etaf-balatro--val session :draw-pile)
                       (etaf-balatro--val session :hand)
                       etaf-balatro--hand-size))
               (sorted (etaf-balatro--sort-cards
                        (cdr dealt) (etaf-balatro--val session :sort-mode))))
          (etaf-balatro--set session :draw-pile (car dealt))
          (etaf-balatro--set session :hand sorted)
          (etaf-balatro--set session :selected-ids nil)
          (etaf-balatro--set session :message
                          (format "本手 %s 结算 +%d 分（%d / %d）%s"
                                  hand-name total new-score target
                                  (if shattered
                                      (format " · %d 张玻璃牌碎裂！" (length shattered))
                                    "")))))))))

;;;###autoload
(defun etaf-balatro-play-hand (session &optional instant)
  "Play selected cards in SESSION, running the scoring cascade timeline.
When INSTANT is non-nil (or `etaf-animation-enabled' is nil), settles
immediately without waiting for timeline frames."
  (etaf-balatro--require-session session)
  (when (and (eq (etaf-balatro--val session :phase) 'playing)
             (not (etaf-balatro--val session :animating))
             (> (etaf-balatro--val session :hands-left) 0))
    (let* ((hand (etaf-balatro--val session :hand))
           (selected-ids (etaf-balatro--val session :selected-ids))
           (played (cl-remove-if-not
                    (lambda (c) (memq (plist-get c :id) selected-ids))
                    hand))
           (held (cl-remove-if
                  (lambda (c) (memq (plist-get c :id) selected-ids))
                  hand))
           (boss-trait (etaf-balatro--val session :boss-trait))
           (boss-id (and boss-trait (plist-get boss-trait :id))))
      (cond
       ((null played)
        (etaf-balatro--set session :message "请先按数字 1-8 选中 1 到 5 张牌"))
       ((and (eq boss-id 'must-five) (/= (length played) 5))
        (etaf-balatro--set session :message "Boss 词条「满编五张」生效：必须恰好选择 5 张牌"))
       ((and (eq boss-id 'max-three) (> (length played) 3))
        (etaf-balatro--set session :message "Boss 词条「精简三张」生效：最多只能选择 3 张牌"))
       (t
        (let* ((hands-left (etaf-balatro--val session :hands-left))
               (rng (plist-get session :rng))
               (sim-seed (etaf-balatro--rng-int rng #x100000))
               (sim (etaf-balatro-simulate-score
                     played held
                     (etaf-balatro--val session :jokers)
                     (etaf-balatro--val session :hand-levels)
                     :hands-left hands-left
                     :discards-left (etaf-balatro--val session :discards-left)
                     :money (etaf-balatro--val session :money)
                     :boss-trait boss-trait
                     :seed sim-seed))
               (events (plist-get sim :events))
               (total-steps (length events)))
          (etaf-balatro--stop-timeline session)
          (etaf-batch
            (etaf-balatro--set session :hands-left (1- hands-left))
            (etaf-balatro--set session :hands-played (1+ (etaf-balatro--val session :hands-played)))
            (etaf-balatro--set session :hand held)
            (etaf-balatro--set session :selected-ids nil)
            (etaf-balatro--set session :played-cards played)
            (etaf-balatro--set session :display-hand-name (plist-get sim :hand-name))
            (etaf-balatro--set session :display-hand-level (plist-get sim :level))
            (etaf-balatro--set session :display-chips (plist-get sim :base-chips))
            (etaf-balatro--set session :display-mult (plist-get sim :base-mult))
            (etaf-balatro--set session :last-hand-score 0)
            (etaf-balatro--set session :step-index 0)
            (etaf-balatro--set session :step-total total-steps)
            (etaf-balatro--set session :trace nil))
          (if (or instant (not etaf-animation-enabled) (null events))
              (progn
                (etaf-balatro--set session :trace events)
                (etaf-balatro--set session :step-index total-steps)
                (etaf-balatro--finish-hand session sim))
            (let* ((speed (max 0.5 (or (etaf-balatro--val session :speed) 1.0)))
                   (step-delay (/ 0.34 speed))
                   (steps nil)
                   (idx 0))
              (dolist (ev events)
                (setq idx (1+ idx))
                (let ((ev-copy ev)
                      (step-num idx))
                  (push (list :call
                              (lambda ()
                                (etaf-batch
                                  (etaf-balatro--set session :step-index step-num)
                                  (etaf-balatro--set session :active-event ev-copy)
                                  (etaf-balatro--set session :active-card-id
                                                  (when (eq (plist-get ev-copy :kind) 'card)
                                                    (plist-get ev-copy :id)))
                                  (etaf-balatro--set session :active-joker-uid
                                                  (when (eq (plist-get ev-copy :kind) 'joker)
                                                    (plist-get ev-copy :id)))
                                  (etaf-balatro--set session :display-chips
                                                  (plist-get ev-copy :chips-after))
                                  (etaf-balatro--set session :display-mult
                                                  (plist-get ev-copy :mult-after))
                                  (etaf-balatro--set session :trace
                                                  (append (etaf-balatro--val session :trace)
                                                          (list ev-copy))))))
                        steps)
                  (push (list :delay step-delay) steps)))
              (setq steps (nreverse steps))
              (etaf-balatro--set session :animating t)
              (etaf-balatro--set session :message
                              (format "正在结算 %s · 按 SPC 立即完成"
                                      (plist-get sim :hand-name)))
              (let ((scope (etaf-effect-scope :detached t :name 'balatro-timeline)))
                (setcar (plist-get session :timeline-scope) scope)
                (etaf-scope-run
                 scope
                 (lambda ()
                   (let ((tl (etaf-animation-timeline
                              steps
                              :name 'balatro-scoring-cascade
                              :on-complete
                              (lambda ()
                                (etaf-balatro--finish-hand session sim)
                                (setcar (plist-get session :timeline-ref) nil)))))
                     (setcar (plist-get session :timeline-ref) tl))))))))))))
  (etaf-balatro-state session))

;;;###autoload
(defun etaf-balatro-skip-animation (session)
  "Immediately finish any active scoring cascade animation in SESSION."
  (etaf-balatro--require-session session)
  (let ((tl (car (plist-get session :timeline-ref))))
    (when (and tl (etaf-balatro--val session :animating))
      (setcar (plist-get session :timeline-ref) nil)
      (unwind-protect
          (etaf-animation-finish tl)
        (etaf-balatro--stop-timeline session))))
  (etaf-balatro--val session :animating))

;;;###autoload
(defun etaf-balatro-set-speed (session speed)
  "Set SESSION's cascade playback speed multiplier to SPEED (1.0, 2.0 or 4.0)."
  (etaf-balatro--require-session session)
  (let ((spd (float speed)))
    (unless (member spd etaf-balatro--valid-speeds)
      (signal 'etaf-balatro-error (list "Speed must be 1.0, 2.0 or 4.0" speed)))
    (etaf-balatro--set session :speed spd)
    spd))

;; ---------------------------------------------------------------------------
;; Jokers, Planets, Targeted Tarots & Shop
;; ---------------------------------------------------------------------------

;;;###autoload
(defun etaf-balatro-select-joker (session index)
  "Select owned Joker at 0-based INDEX in SESSION."
  (etaf-balatro--require-session session)
  (let ((len (length (etaf-balatro--val session :jokers))))
    (when (and (> len 0) (integerp index))
      (etaf-balatro--set session :selected-joker-index
                      (max 0 (min (1- len) index)))))
  (etaf-balatro--val session :selected-joker-index))

;;;###autoload
(defun etaf-balatro-move-joker (session delta)
  "Shift the selected Joker left (DELTA < 0) or right (DELTA > 0) in SESSION."
  (etaf-balatro--require-session session)
  (unless (etaf-balatro--val session :animating)
    (let* ((jokers (copy-sequence (etaf-balatro--val session :jokers)))
           (len (length jokers))
           (idx (or (etaf-balatro--val session :selected-joker-index) 0))
           (target (+ idx (if (< delta 0) -1 1))))
      (cond
       ((<= len 1)
        (etaf-balatro--set session :message "拥有至少 2 张小丑后可用 [, / .] 调整结算顺序"))
       ((and (>= idx 0) (< idx len) (>= target 0) (< target len))
        (let ((a (nth idx jokers))
              (b (nth target jokers)))
          (setf (nth idx jokers) b
                (nth target jokers) a)
          (etaf-batch
            (etaf-balatro--set session :jokers jokers)
            (etaf-balatro--set session :selected-joker-index target)
            (etaf-balatro--set session :message
                            (format "已将「%s」移至槽位 %d"
                                    (plist-get a :name) (1+ target)))))))))
  (etaf-balatro--val session :jokers))

;;;###autoload
(defun etaf-balatro-sell-joker (session &optional index)
  "Sell owned Joker at INDEX (or currently selected Joker) in SESSION."
  (etaf-balatro--require-session session)
  (unless (etaf-balatro--val session :animating)
    (let* ((jokers (etaf-balatro--val session :jokers))
           (len (length jokers))
           (idx (if (integerp index) index
                  (or (etaf-balatro--val session :selected-joker-index) 0))))
      (when (and (> len 0) (>= idx 0) (< idx len))
        (let* ((victim (nth idx jokers))
               (price (etaf-balatro--joker-sell-price victim))
               (rest (cl-loop for j in jokers for i from 0
                              unless (= i idx) collect j)))
          (etaf-batch
            (etaf-balatro--set session :jokers rest)
            (etaf-balatro--set session :selected-joker-index
                            (max 0 (min (1- (length rest)) idx)))
            (etaf-balatro--set session :money (+ (etaf-balatro--val session :money) price))
            (etaf-balatro--set session :message
                            (format "已出售「%s」，获得 $%d"
                                    (plist-get victim :name) price)))))))
  (etaf-balatro--val session :jokers))

(defun etaf-balatro--upgrade-hand-level (session hand-type)
  "Increment HAND-TYPE level by 1 in SESSION and return the updated stats."
  (let* ((levels (copy-alist (etaf-balatro--val session :hand-levels)))
         (cell (assq hand-type levels)))
    (if cell
        (setcdr cell (1+ (cdr cell)))
      (push (cons hand-type 2) levels))
    (etaf-balatro--set session :hand-levels levels)
    (etaf-balatro--hand-stats hand-type levels)))

(defun etaf-balatro--apply-tarot (session item rest-consumables)
  "Apply targeted Tarot ITEM to currently selected hand cards in SESSION."
  (let* ((phase (etaf-balatro--val session :phase))
         (selected-ids (etaf-balatro--val session :selected-ids))
         (max-t (or (plist-get item :max-targets) 1))
         (tname (plist-get item :name))
         (effect (plist-get item :effect)))
    (cond
     ((not (eq phase 'playing))
      (etaf-balatro--set session :message
                      (format "塔罗「%s」需在牌局中选中 1-%d 张手牌后再使用" tname max-t)))
     ((null selected-ids)
      (etaf-balatro--set session :message
                      (format "请先按数字 1-8 选中 1-%d 张手牌，再施放塔罗「%s」" max-t tname)))
     ((> (length selected-ids) max-t)
      (etaf-balatro--set session :message
                      (format "塔罗「%s」最多作用于 %d 张牌（当前已选 %d 张）"
                              tname max-t (length selected-ids))))
     (t
      (let* ((hand (mapcar #'copy-sequence (etaf-balatro--val session :hand)))
             (deck (mapcar #'copy-sequence (etaf-balatro--val session :deck)))
             (targets (cl-remove-if-not
                       (lambda (c) (memq (plist-get c :id) selected-ids))
                       hand))
             (labels (mapconcat #'etaf-balatro--card-label targets "、")))
        (pcase effect
          ('enhance
           (let* ((enh (plist-get item :enhancement))
                  (enh-name (plist-get (etaf-balatro--enhancement-info enh) :name)))
             (dolist (c hand)
               (when (memq (plist-get c :id) selected-ids)
                 (plist-put c :enhancement enh)))
             (dolist (c deck)
               (when (memq (plist-get c :id) selected-ids)
                 (plist-put c :enhancement enh)))
             (etaf-batch
               (etaf-balatro--set session :hand hand)
               (etaf-balatro--set session :deck deck)
               (etaf-balatro--set session :selected-ids nil)
               (etaf-balatro--set session :consumables rest-consumables)
               (etaf-balatro--set session :message
                               (format "塔罗「%s」施放完成：%s 已永久锻造为 [%s]"
                                       tname labels enh-name)))))
          ('suit
           (let* ((suit (plist-get item :suit))
                  (sname (etaf-balatro--suit-name suit)))
             (dolist (c hand)
               (when (memq (plist-get c :id) selected-ids)
                 (plist-put c :suit suit)))
             (dolist (c deck)
               (when (memq (plist-get c :id) selected-ids)
                 (plist-put c :suit suit)))
             (let ((sorted (etaf-balatro--sort-cards hand (etaf-balatro--val session :sort-mode))))
               (etaf-batch
                 (etaf-balatro--set session :hand sorted)
                 (etaf-balatro--set session :deck deck)
                 (etaf-balatro--set session :selected-ids nil)
                 (etaf-balatro--set session :consumables rest-consumables)
                 (etaf-balatro--set session :message
                                 (format "塔罗「%s」施放完成：%s 已永久转化为 %s %s"
                                         tname labels (etaf-balatro--suit-glyph suit) sname))))))
          ('destroy
           (let* ((kept-hand (cl-remove-if
                              (lambda (c) (memq (plist-get c :id) selected-ids))
                              hand))
                  (kept-deck (cl-remove-if
                              (lambda (c) (memq (plist-get c :id) selected-ids))
                              deck))
                  (dealt (etaf-balatro--draw-up-to
                          (etaf-balatro--val session :draw-pile)
                          kept-hand etaf-balatro--hand-size))
                  (sorted (etaf-balatro--sort-cards
                           (cdr dealt) (etaf-balatro--val session :sort-mode))))
             (etaf-batch
               (etaf-balatro--set session :hand sorted)
               (etaf-balatro--set session :draw-pile (car dealt))
               (etaf-balatro--set session :deck kept-deck)
               (etaf-balatro--set session :selected-ids nil)
               (etaf-balatro--set session :consumables rest-consumables)
               (etaf-balatro--set session :message
                               (format "塔罗「%s」施放完成：已从牌库永久销毁 %s（现余 %d 张）"
                                       tname labels (length kept-deck))))))))))))

;;;###autoload
(defun etaf-balatro-use-consumable (session &optional index)
  "Use held consumable (Planet or targeted Tarot) at 0-based INDEX in SESSION."
  (etaf-balatro--require-session session)
  (unless (etaf-balatro--val session :animating)
    (let* ((items (etaf-balatro--val session :consumables))
           (idx (or index 0))
           (item (and (>= idx 0) (< idx (length items)) (nth idx items))))
      (cond
       ((null items)
        (etaf-balatro--set session :message "消耗品槽位为空（过关后可在商店购入星球或塔罗牌）"))
       ((null item)
        (etaf-balatro--set session :message
                        (format "消耗品槽 %d 为空，请按 [u] 使用槽 1" (1+ idx))))
       (t
        (let ((rest (cl-loop for x in items for i from 0
                             unless (= i idx) collect x)))
          (pcase (plist-get item :kind)
            ('tarot
             (etaf-balatro--apply-tarot session item rest))
            (_
             (let ((stats (etaf-balatro--upgrade-hand-level
                           session (plist-get item :hand-type))))
               (etaf-batch
                 (etaf-balatro--set session :consumables rest)
                 (etaf-balatro--set session :message
                                 (format "使用行星「%s」：%s 升至 Lv.%d（%d × %d）"
                                         (plist-get item :name)
                                         (plist-get stats :name)
                                         (plist-get stats :level)
                                         (plist-get stats :chips)
                                         (plist-get stats :mult))))))))))))
  (etaf-balatro--val session :consumables))

;;;###autoload
(defun etaf-balatro-buy-shop-item (session index)
  "Purchase shop shelf item at 0-based INDEX in SESSION."
  (etaf-balatro--require-session session)
  (when (eq (etaf-balatro--val session :phase) 'shop)
    (let* ((shop (mapcar #'copy-sequence (etaf-balatro--val session :shop)))
           (item (and (integerp index) (>= index 0) (< index (length shop))
                      (nth index shop)))
           (money (etaf-balatro--val session :money)))
      (cond
       ((null item) nil)
       ((plist-get item :sold)
        (etaf-balatro--set session :message "该商品已售罄"))
       ((< money (plist-get item :cost))
        (etaf-balatro--set session :message
                        (format "金币不足（需要 $%d，当前 $%d）"
                                (plist-get item :cost) money)))
       (t
        (let ((kind (plist-get item :kind))
              (cost (plist-get item :cost)))
          (pcase kind
            ('joker
             (let ((jokers (etaf-balatro--val session :jokers)))
               (if (>= (length jokers) etaf-balatro--max-jokers)
                   (etaf-balatro--set session :message
                                   "小丑槽位已满（5 / 5），请先按 x 出售旧小丑")
                 (let ((new-joker (etaf-balatro--make-joker
                                   (plist-get item :joker-id)
                                   (etaf-balatro--next-uid session))))
                   (plist-put item :sold t)
                   (etaf-batch
                     (etaf-balatro--set session :money (- money cost))
                     (etaf-balatro--set session :jokers (append jokers (list new-joker)))
                     (etaf-balatro--set session :selected-joker-index (length jokers))
                     (etaf-balatro--set session :shop shop)
                     (etaf-balatro--set session :message
                                     (format "已购入小丑「%s」"
                                             (plist-get new-joker :name))))))))
            ('planet
             (plist-put item :sold t)
             (let ((stats (etaf-balatro--upgrade-hand-level
                           session (plist-get item :hand-type))))
               (etaf-batch
                 (etaf-balatro--set session :money (- money cost))
                 (etaf-balatro--set session :shop shop)
                 (etaf-balatro--set session :message
                                 (format "购买行星「%s」：%s 升至 Lv.%d（%d × %d）"
                                         (plist-get item :name)
                                         (plist-get stats :name)
                                         (plist-get stats :level)
                                         (plist-get stats :chips)
                                         (plist-get stats :mult))))))
            ('tarot
             (let ((cons-list (etaf-balatro--val session :consumables)))
               (if (>= (length cons-list) etaf-balatro--max-consumables)
                   (etaf-balatro--set session :message
                                   "消耗品槽位已满（2 / 2），请先使用已有消耗品")
                 (let ((new-tarot (etaf-balatro--make-tarot
                                   (plist-get item :tarot-id)
                                   (etaf-balatro--next-uid session))))
                   (plist-put item :sold t)
                   (etaf-batch
                     (etaf-balatro--set session :money (- money cost))
                     (etaf-balatro--set session :consumables (append cons-list (list new-tarot)))
                     (etaf-balatro--set session :shop shop)
                     (etaf-balatro--set session :message
                                     (format "已购入塔罗「%s」存入消耗品槽（战内选牌按 u / U 施放）"
                                             (plist-get new-tarot :name))))))))))))))
  (etaf-balatro--val session :shop))

;;;###autoload
(defun etaf-balatro-reroll-shop (session)
  "Spend $5 to roll 4 fresh shop items in SESSION."
  (etaf-balatro--require-session session)
  (when (eq (etaf-balatro--val session :phase) 'shop)
    (let ((money (etaf-balatro--val session :money)))
      (if (< money 5)
          (etaf-balatro--set session :message "金币不足 $5，无法刷新商店")
        (let ((shop (etaf-balatro--generate-shop
                     (etaf-balatro--val session :jokers)
                     (plist-get session :rng)
                     (lambda () (etaf-balatro--next-uid session)))))
          (etaf-batch
            (etaf-balatro--set session :money (- money 5))
            (etaf-balatro--set session :shop shop)
            (etaf-balatro--set session :message "已花费 $5 刷新商店货架"))))))
  (etaf-balatro--val session :shop))

;;;###autoload
(defun etaf-balatro-next-blind (session)
  "Leave the shop and begin the next Blind in SESSION."
  (etaf-balatro--require-session session)
  (when (eq (etaf-balatro--val session :phase) 'shop)
    (let* ((coords (etaf-balatro--next-blind-coords
                    (etaf-balatro--val session :ante)
                    (etaf-balatro--val session :blind))))
      (etaf-balatro--deal-blind session (car coords) (cdr coords))))
  (etaf-balatro-state session))

;; ---------------------------------------------------------------------------
;; Appearance, Modals, Onboarding Guide, Coach & Restart
;; ---------------------------------------------------------------------------

;;;###autoload
(defun etaf-balatro-toggle-appearance (session)
  "Cycle SESSION appearance through `auto', `dark' and `light' and return it."
  (etaf-balatro--require-session session)
  (let* ((cur (etaf-balatro--val session :appearance))
         (next (pcase cur ('auto 'dark) ('dark 'light) (_ 'auto))))
    (etaf-balatro--set session :appearance next)
    next))

;;;###autoload
(defun etaf-balatro-toggle-modal (session modal)
  "Toggle MODAL (`deck', `hands', `guide' or nil) in SESSION."
  (etaf-balatro--require-session session)
  (unless (memq modal '(nil deck hands guide))
    (signal 'etaf-balatro-error (list "Unknown modal" modal)))
  (let* ((cur (etaf-balatro--val session :modal))
         (next (if (or (null modal) (eq cur modal)) nil modal)))
    (when (and (eq cur 'guide) (null next))
      (etaf-balatro--update-records session (lambda (r) (plist-put r :tutorial-seen t))))
    (etaf-balatro--set session :modal next)
    next))

;;;###autoload
(defun etaf-balatro-open-guide (session &optional step)
  "Open the 4-step interactive beginner guide in SESSION at 0-based STEP."
  (etaf-balatro--require-session session)
  (let ((idx (max 0 (min (1- etaf-balatro--guide-page-count) (or step 0)))))
    (etaf-batch
      (etaf-balatro--set session :guide-step idx)
      (etaf-balatro--set session :modal 'guide))
    idx))

;;;###autoload
(defun etaf-balatro-guide-step (session delta)
  "Step the interactive beginner guide in SESSION by DELTA (-1 or +1).
Stepping past the final page closes the guide and records completion."
  (etaf-balatro--require-session session)
  (let* ((cur (or (etaf-balatro--val session :guide-step) 0))
         (next (+ cur (if (< delta 0) -1 1))))
    (cond
     ((>= next etaf-balatro--guide-page-count)
      (etaf-balatro--update-records session (lambda (r) (plist-put r :tutorial-seen t)))
      (etaf-balatro--set session :modal nil)
      nil)
     (t
      (let ((clamped (max 0 next)))
        (etaf-balatro--set session :guide-step clamped)
        clamped)))))

;;;###autoload
(defun etaf-balatro-toggle-coach (session)
  "Toggle the contextual in-game Coach ribbon in SESSION and persist it."
  (etaf-balatro--require-session session)
  (let ((next (not (etaf-balatro--val session :coach-enabled))))
    (etaf-balatro--set session :coach-enabled next)
    (etaf-balatro--update-records session (lambda (r) (plist-put r :coach-enabled next)))
    next))

;;;###autoload
(defun etaf-balatro-restart (session &optional seed)
  "Restart SESSION with a fresh run, optionally using integer SEED."
  (etaf-balatro--require-session session)
  (let ((next-seed (if (integerp seed)
                       seed
                     (1+ (mod (or (etaf-balatro--val session :seed) 4821) 8999)))))
    (etaf-balatro--init-run-state session next-seed nil)
    (etaf-balatro-state session)))

(provide 'etaf-balatro-model)
;;; etaf-balatro-model.el ends here
