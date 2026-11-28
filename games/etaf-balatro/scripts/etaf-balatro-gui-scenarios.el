;;; -*- lexical-binding: t; -*-
;;; etaf-balatro-gui-scenarios.el --- Production v2 graphical E2E acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-balatro)
(require 'emacs-gui-verifier)

(defun etaf-balatro-gui--size (width rows)
  "Resize the verification frame to WIDTH pixels and ROWS text lines."
  (let ((chrome (- (frame-pixel-height) (window-body-height nil t))))
    (set-frame-parameter nil 'fullscreen nil)
    (set-frame-size nil width (+ chrome (* rows (frame-char-height))) t)))

(defun etaf-balatro-gui--buffer-text (buffer)
  "Return BUFFER plain text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-balatro-gui--line-height-assertion (buffer)
  "Assert every row in BUFFER fits ETAF's uniform line height."
  (when (get-buffer-window buffer)
    (with-current-buffer buffer
      (let ((limit (plist-get (etaf-display-metrics) :line-height))
            offending)
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let ((h (line-pixel-height)))
              (when (> h limit)
                (push (format "line %d is %dpx (> %dpx): %s"
                              (line-number-at-pos) h limit
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))
                      offending)))
            (forward-line 1)))
        (etaf-gui-verifier-assert
         "Every row fits ETAF's uniform line height"
         (null offending)
         (when offending (mapconcat #'identity (nreverse offending) "; ")))))))

(defun etaf-balatro-gui-run (directory)
  "Run ETAF Balatro v2 graphical E2E suite into DIRECTORY."
  (unless (display-graphic-p) (error "A graphical frame is required"))
  (let ((size (cons (frame-pixel-width) (frame-pixel-height)))
        (fullscreen (frame-parameter nil 'fullscreen))
        (etaf-animation-enabled t)
        (etaf-animation-paused nil)
        (etaf-balatro-records-file nil)
        session buffer runtime)
    (unwind-protect
        (cl-labels
            ((text () (etaf-balatro-gui--buffer-text buffer))
             (viewport-synced-p ()
               (and runtime
                    (let* ((vp (etaf-runtime-viewport runtime))
                           (bw (window-body-width nil t))
                           (bh (window-body-height nil t))
                           (lh (with-current-buffer buffer
                                 (plist-get (etaf-display-metrics) :line-height)))
                           (rh (with-current-buffer buffer
                                 (cdr (window-text-pixel-size
                                       (get-buffer-window buffer)
                                       (point-min) (point-max))))))
                      (and (= (car vp) bw)
                           (<= rh bh)
                           (>= rh (- bh lh))))))
             (key-action (id keys predicate &optional screenshot)
               (etaf-gui-verifier-action-create
                :id id :screenshot screenshot
                :execute (lambda (_context)
                           (switch-to-buffer buffer)
                           (execute-kbd-macro (kbd keys)))
                :settled-p (lambda (_context) (funcall predicate)))))
          (etaf-gui-verifier-run
           (etaf-gui-verifier-scenario-create
            :name "etaf-balatro-v2"
            :claim "Production v2: 4-step onboarding, physical card lift, targeted Tarots, 52-card matrix, live modus-vivendi/modus-operandi theme adaptation, shop and responsive viewports"
            :initialize
            (lambda (context)
              (mapc #'disable-theme custom-enabled-themes)
              (load-theme 'modus-vivendi t)
              (etaf-balatro-gui--size 1440 52)
              ;; Fresh profile: auto-opens 4-step interactive onboarding guide!
              (setq session (etaf-balatro-new-run :seed 101 :appearance 'auto :speed 1.0)
                    buffer (etaf-balatro-open session)
                    runtime (etaf-runtime-for-buffer buffer))
              (switch-to-buffer buffer)
              (etaf-gui-verifier-context-select-buffer context buffer)
              (message nil))
            :invariants
            (lambda (_context)
              (delq nil
                    (list
                     (etaf-gui-verifier-assert
                      "Original Emacs mode-line is preserved"
                      (with-current-buffer buffer (not (null mode-line-format))))
                     (etaf-gui-verifier-assert
                      "Stray Emacs text cursor is hidden"
                      (with-current-buffer buffer (null cursor-type)))
                     (etaf-gui-verifier-assert
                      "Top header bar stays visible with zero vertical scroll overflow"
                      (when-let* ((win (get-buffer-window buffer)))
                        (with-current-buffer buffer
                          (string-match-p
                           "ETAF BALATRO"
                           (buffer-substring-no-properties
                            (window-start win) (window-end win t))))))
                     (etaf-gui-verifier-assert
                      "No horizontal overflow in wide window"
                      (let ((w (window-body-width nil t))
                            (rendered (car (window-text-pixel-size
                                            nil (point-min) (point-max)))))
                        (or (< w 900) (<= rendered (+ w 4)))))
                     (etaf-balatro-gui--line-height-assertion buffer))))
            :actions
            (list
             ;; 1. First-run 4-step Onboarding Guide (Page 1: Core formula + example)
             (etaf-gui-verifier-action-create
              :id "01-onboarding-page1" :screenshot t
              :execute (lambda (_context)
                         (etaf-balatro-gui--size 1440 52)
                         (switch-to-buffer buffer))
              :settled-p (lambda (_context)
                           (and (viewport-synced-p)
                                (eq (plist-get (etaf-balatro-state session) :modal) 'guide)
                                (= (plist-get (etaf-balatro-state session) :guide-step) 0)
                                (string-match-p "60 秒小丑牌入门" (text)))))
             ;; 2. Step to Page 3 via real GUI <right> arrow keys (no :on-direction warning!)
             (key-action
              "02-onboarding-page3" "<right> <right>"
              (lambda () (and (= (plist-get (etaf-balatro-state session) :guide-step) 2)
                              (string-match-p "正确摆位" (text))))
              t)
             ;; 3. Finish onboarding, forge 6♥ (slot 7) with Justice Tarot (U), select pair 7+8 so lifted cards + Glass tag + 3-step cascade shine!
             (etaf-gui-verifier-action-create
              :id "03-dark-lifted-tarot-forged" :screenshot t
              :execute (lambda (_context)
                         (switch-to-buffer buffer)
                         (execute-kbd-macro (kbd "<escape>"))
                         ;; Forge card 7 (6♥ on seed 101) into Glass x2 using starter Tarot in slot 2 (U)
                         (execute-kbd-macro (kbd "7 U"))
                         ;; Select pair 7+8 (6♥ Glass + 6♣) plus card 1 so 3-step cascade + lifted cards shine
                         (execute-kbd-macro (kbd "1 7 8")))
              :settled-p (lambda (_context)
                           (let ((st (etaf-balatro-state session)))
                             (and (viewport-synced-p)
                                  (null (plist-get st :modal))
                                  (= (length (plist-get st :selected-ids)) 3)
                                  (string-match-p "玻璃 ×2" (text))
                                  (string-match-p "实战提示" (text))))))
             ;; 4. Live mid-cascade animation frame triggered by physical GUI <return>
             (etaf-gui-verifier-action-create
              :id "04-dark-cascade-mid" :screenshot t
              :execute (lambda (_context)
                         (switch-to-buffer buffer)
                         (execute-kbd-macro (kbd "<return>")))
              :settled-p (lambda (_context)
                           (let ((st (etaf-balatro-state session)))
                             (when (and (plist-get st :animating)
                                        (>= (plist-get st :step-index)
                                            (min 2 (max 1 (plist-get st :step-total)))))
                               (setq etaf-animation-paused t)
                               t))))
             ;; 5. Instant SPC skip settled frame
             (etaf-gui-verifier-action-create
              :id "05-dark-cascade-settled" :screenshot t
              :execute (lambda (_context)
                         (setq etaf-animation-paused nil)
                         (switch-to-buffer buffer)
                         (execute-kbd-macro (kbd "SPC")))
              :settled-p (lambda (_context)
                           (let ((st (etaf-balatro-state session)))
                             (and (not (plist-get st :animating))
                                  (or (eq (plist-get st :phase) 'shop)
                                      (> (plist-get st :score) 0))))))
             ;; 6. Full 52-card Deck Matrix modal (showing ★ Glass card!)
             (key-action
              "06-dark-deck-matrix" "v"
              (lambda () (and (eq (plist-get (etaf-balatro-state session) :modal) 'deck)
                              (string-match-p "52 张牌库矩阵" (text))
                              (string-match-p "★" (text))))
              t)
             ;; 7. Close modal & LIVE load-theme to modus-operandi (Light Emacs theme!)
             (etaf-gui-verifier-action-create
              :id "07-live-modus-operandi-light" :screenshot t
              :execute (lambda (_context)
                         (switch-to-buffer buffer)
                         (execute-kbd-macro (kbd "<escape>"))
                         (mapc #'disable-theme custom-enabled-themes)
                         (load-theme 'modus-operandi t)
                         ;; Select 3 cards in light theme so lifted cards show clearly
                         (when (eq (plist-get (etaf-balatro-state session) :phase) 'playing)
                           (execute-kbd-macro (kbd "1 3 5"))))
              :settled-p (lambda (_context)
                           (and (viewport-synced-p)
                                (null (plist-get (etaf-balatro-state session) :modal))
                                (eq (plist-get (etaf-balatro-state session) :appearance) 'auto)
                                (memq 'modus-operandi custom-enabled-themes))))
             ;; 8. Clear blind into spacious Shop in live modus-operandi Light theme
             (etaf-gui-verifier-action-create
              :id "08-shop-modus-operandi-light" :screenshot t
              :execute (lambda (_context)
                         (let ((safety 0))
                           (while (and (eq (plist-get (etaf-balatro-state session) :phase) 'playing)
                                       (< safety 5))
                             (let* ((hand (plist-get (etaf-balatro-state session) :hand))
                                    (hearts (cl-loop for c in hand for i from 0
                                                     when (eq (plist-get c :suit) 'hearts) collect i))
                                    (picks (or (and (>= (length hearts) 5) (cl-subseq hearts 0 5))
                                               (let ((by-r nil))
                                                 (cl-loop for c in hand for i from 0 do
                                                          (let* ((r (plist-get c :rank))
                                                                 (cell (assq r by-r)))
                                                            (if cell (setcdr cell (append (cdr cell) (list i)))
                                                              (push (cons r (list i)) by-r))))
                                                 (setq by-r (sort by-r
                                                                  (lambda (a b)
                                                                    (let ((la (length (cdr a)))
                                                                          (lb (length (cdr b))))
                                                                      (if (/= la lb) (> la lb) (> (car a) (car b)))))))
                                                 (let ((res nil))
                                                   (dolist (g by-r)
                                                     (when (and (>= (length (cdr g)) 2)
                                                                (<= (+ (length res) (length (cdr g))) 5))
                                                       (setq res (append res (cdr g)))))
                                                   (or res '(0 1 2 3 4)))))))
                               (etaf-balatro-clear-selection session)
                               (dolist (i picks) (etaf-balatro-toggle-card session i))
                               (etaf-balatro-play-hand session t))
                             (setq safety (1+ safety)))
                           ;; Fallback: if unlucky deal exhausted hands, restart with seed 4821 and clear
                           (unless (eq (plist-get (etaf-balatro-state session) :phase) 'shop)
                             (etaf-balatro-restart session 4821)
                             (let ((safety 0))
                               (while (and (eq (plist-get (etaf-balatro-state session) :phase) 'playing)
                                           (< safety 4))
                                 (etaf-balatro-clear-selection session)
                                 (dotimes (i 5) (etaf-balatro-toggle-card session i))
                                 (etaf-balatro-play-hand session t)
                                 (setq safety (1+ safety)))))))
              :settled-p (lambda (_context)
                           (and (eq (plist-get (etaf-balatro-state session) :phase) 'shop)
                                (string-match-p "本关商店货架" (text)))))
             ;; 9. Live switch back to modus-vivendi Dark in Shop & buy Tarot (4) + Planet (3)
             (etaf-gui-verifier-action-create
              :id "09-shop-modus-vivendi-dark-buy" :screenshot t
              :execute (lambda (_context)
                         (mapc #'disable-theme custom-enabled-themes)
                         (load-theme 'modus-vivendi t)
                         (switch-to-buffer buffer)
                         (execute-kbd-macro (kbd "4 3")))
              :settled-p (lambda (_context)
                           (let ((st (etaf-balatro-state session)))
                             (and (memq 'modus-vivendi custom-enabled-themes)
                                  (plist-get (nth 3 (plist-get st :shop)) :sold)
                                  (>= (length (plist-get st :consumables)) 1)))))
             ;; 10. Advance to Big Blind via physical GUI <return>, test narrow 660x40 viewport
             (etaf-gui-verifier-action-create
              :id "10-narrow-viewport" :screenshot t
              :execute (lambda (_context)
                         (switch-to-buffer buffer)
                         (execute-kbd-macro (kbd "<return>"))
                         (etaf-balatro-gui--size 660 40))
              :settled-p (lambda (_context)
                           (and (eq (plist-get (etaf-balatro-state session) :phase) 'playing)
                                (<= (frame-pixel-width) 720)
                                (viewport-synced-p))))
             ;; 11. Test short 1180x30 viewport
             (etaf-gui-verifier-action-create
              :id "11-short-viewport" :screenshot t
              :execute (lambda (_context)
                         (etaf-balatro-gui--size 1180 30))
              :settled-p (lambda (_context)
                           (and (viewport-synced-p)
                                (<= (window-body-height) 32))))))
           directory)
          'ok)
      (setq etaf-animation-paused nil)
      (when (buffer-live-p buffer) (etaf-app-close buffer))
      (mapc #'disable-theme custom-enabled-themes)
      (set-frame-size nil (car size) (cdr size) t)
      (set-frame-parameter nil 'fullscreen fullscreen))))

(provide 'etaf-balatro-gui-scenarios)
;;; etaf-balatro-gui-scenarios.el ends here
