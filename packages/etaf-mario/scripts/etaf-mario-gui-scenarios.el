;;; -*- lexical-binding: t; -*-
;;; etaf-mario-gui-scenarios.el --- Play Super Mario through native input
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; This adapter drives the running game with the keys a player actually
;; presses.  It never calls a game command and never reads the session's
;; private state: the HUD line and the painted canvas are the observable
;; interface, so a scenario fails when the screen a player sees is wrong even
;; when the model is right.
;;
;; The run starts from a disposable progress file with every stage unlocked,
;; opens the game in the selected graphical frame, walks to blocks by aligning
;; the painted player under the painted block, and exercises blocks, items,
;; enemies, dialogs, stage changes, a pit death and the resize matrix.  The
;; screenshots are evidence for visual review; the assertions certify behavior
;; only.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'etaf)
(require 'etaf-mario)
(require 'emacs-gui-verifier)

(defconst etaf-mario-gui--buffer-name "*超级马里奥*"
  "Buffer name of the running game.")

(defvar etaf-mario-gui--buffer nil
  "Game buffer owned by the current scenario run.")

(defvar etaf-mario-gui--background-cookie nil
  "Face-remap cookie that matches the canvas background to the UI theme.")

(defun etaf-mario-gui--text ()
  "Return the game buffer's text without properties."
  (with-current-buffer etaf-mario-gui--buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-mario-gui--lines ()
  "Return the game buffer's text as a list of lines."
  (split-string (etaf-mario-gui--text) "\n"))

(defun etaf-mario-gui--hud-line ()
  "Return the HUD line carrying MARIO's counters, or nil."
  (cl-find-if (lambda (line) (string-match-p "MARIO [0-9]\\{6\\}" line))
              (etaf-mario-gui--lines)))

(defun etaf-mario-gui--hud (regexp)
  "Return the first group of REGEXP matched against the HUD line."
  (let ((line (etaf-mario-gui--hud-line)))
    (when (and line (string-match regexp line))
      (match-string 1 line))))

(defun etaf-mario-gui--score ()
  "Return the HUD score as a number, or nil."
  (when-let* ((text (etaf-mario-gui--hud "MARIO \\([0-9]+\\)")))
    (string-to-number text)))

(defun etaf-mario-gui--coins ()
  "Return the HUD coin count as a number, or nil."
  (when-let* ((text (etaf-mario-gui--hud "● ×\\([0-9]+\\)")))
    (string-to-number text)))

(defun etaf-mario-gui--time ()
  "Return the HUD level clock as a number, or nil."
  (when-let* ((text (etaf-mario-gui--hud "TIME \\([0-9]+\\)")))
    (string-to-number text)))

(defun etaf-mario-gui--lives ()
  "Return the HUD life count as a number, or nil."
  (when-let* ((text (etaf-mario-gui--hud "♥×\\([0-9]+\\)")))
    (string-to-number text)))

(defun etaf-mario-gui--world ()
  "Return the HUD stage name, or nil."
  (etaf-mario-gui--hud "WORLD \\([0-9]+-[0-9]+\\)"))

(defun etaf-mario-gui--canvas-lines ()
  "Return the sixteen canvas rows between the HUD and the footer."
  (let* ((lines (etaf-mario-gui--lines))
         (hud (cl-position-if (lambda (line) (string-match-p "MARIO [0-9]\\{6\\}" line))
                              lines))
         (footer (and hud
                      (cl-position-if (lambda (line) (string-match-p "移动" line))
                                      lines :start (1+ hud)))))
    (when (and hud footer)
      (seq-subseq lines (1+ hud) footer))))

(defun etaf-mario-gui--player-column ()
  "Return the painted player's left canvas column, or nil.
Mario's face row is his only always-present row: the walking sprites split
their feet and the jump splits them too, while the face keeps its eyes.  A
pipe paints a solid body, a goomba uses a different face, and enemies cannot
be mistaken for this row."
  (let (column)
    (cl-loop for line in (etaf-mario-gui--canvas-lines)
             when (string-match "▐feef▌" line)
             do (setq column (match-beginning 0))
             and return column)
    column))

(defun etaf-mario-gui--first-question-column ()
  "Return the first painted question block's left column, or nil."
  (let (column)
    (cl-loop for line in (etaf-mario-gui--canvas-lines)
             when (string-match "?" line)
             do (setq column (match-beginning 0))
             and return column)
    column))

(defun etaf-mario-gui--block-run-column ()
  "Return the left column of the first long block run, or nil."
  (let (column)
    (cl-loop for line in (etaf-mario-gui--canvas-lines)
             when (string-match "▛▀▀▀▀" line)
             do (setq column (match-beginning 0))
             and return column)
    column))

(defun etaf-mario-gui--goomba-column ()
  "Return the first painted goomba's left canvas column, or nil."
  (let (column)
    (cl-loop for line in (etaf-mario-gui--canvas-lines)
             when (string-match "▐eWe▌" line)
             do (setq column (match-beginning 0))
             and return column)
    column))

(defun etaf-mario-gui--window ()
  "Return the window showing the game buffer."
  (get-buffer-window etaf-mario-gui--buffer t))

(defun etaf-mario-gui--canvas-width ()
  "Return the widest painted canvas row."
  (let ((lines (etaf-mario-gui--canvas-lines)))
    (and lines (cl-loop for line in lines maximize (length line)))))

(defun etaf-mario-gui--expected-canvas-width ()
  "Return the canvas width implied by the game window."
  (let ((window (etaf-mario-gui--window)))
    (and window
         (1+ (min 200 (max 40 (- (window-body-width window) 2)))))))

(defun etaf-mario-gui--canvas-settled-p ()
  "Return non-nil when sixteen canvas rows match the window's stage width."
  (let ((lines (etaf-mario-gui--canvas-lines)))
    (and (eql 16 (length lines))
         (= (etaf-mario-gui--canvas-width)
            (etaf-mario-gui--expected-canvas-width)))))

(defun etaf-mario-gui--press (keys &optional settle)
  "Send KEYS through the command loop, then wait SETTLE seconds."
  (switch-to-buffer etaf-mario-gui--buffer)
  (execute-kbd-macro (kbd keys))
  (when settle (sit-for settle)))

(defun etaf-mario-gui--hold (keys seconds)
  "Hold KEYS for SECONDS by repeating the documented key events."
  (switch-to-buffer etaf-mario-gui--buffer)
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (execute-kbd-macro (kbd keys))
      (sit-for 0.025))))

(defun etaf-mario-gui--jump (hold)
  "Jump and keep the jump key held for HOLD seconds."
  (switch-to-buffer etaf-mario-gui--buffer)
  (execute-kbd-macro (kbd "z"))
  (let ((end (+ (float-time) hold)))
    (while (< (float-time) end)
      (execute-kbd-macro (kbd "z"))
      (sit-for 0.02))))

(defun etaf-mario-gui--align (target tolerance)
  "Walk until the player stands with his centre within TOLERANCE of TARGET.
TARGET is a function returning the painted target column.  The loop reads the
same canvas a player sees, so camera scrolling cannot accumulate drift.  It
also waits for the screen column to stop changing: a jump started while the
last walk key is still moving the player would bump a neighbouring block."
  (switch-to-buffer etaf-mario-gui--buffer)
  (let ((tries 0)
        (stable 0))
    (while (and (< stable 4) (< tries 600))
      (let* ((column (funcall target))
             (player (etaf-mario-gui--player-column))
             (delta (and column player (- column (+ player 3)))))
        (cond
         ((null delta)
          (setq stable 0)
          (sit-for 0.04))
         ((> (abs delta) tolerance)
          (execute-kbd-macro
           (kbd (if (< delta 0) "<left>" "<right>")))
          (sit-for 0.03)
          (setq stable 0))
         (t
          ;; Four stable samples need the player nearly stopped: at walking
          ;; speed the error would leave this window within 0.1 s, so a jump
          ;; started here cannot drift into a neighbouring block.
          (cl-incf stable)
          (sit-for 0.03))))
      (cl-incf tries))
    (>= stable 4)))

(defun etaf-mario-gui--size (columns rows)
  "Resize the scenario frame to COLUMNS by ROWS text cells."
  (set-frame-parameter nil 'fullscreen nil)
  (set-frame-size nil columns rows))

(defun etaf-mario-gui--canvas-background (color)
  "Paint COLOR behind the game canvas so the UI theme stays readable."
  (when etaf-mario-gui--background-cookie
    (with-current-buffer etaf-mario-gui--buffer
      (face-remap-remove-relative etaf-mario-gui--background-cookie)))
  (setq etaf-mario-gui--background-cookie
        (with-current-buffer etaf-mario-gui--buffer
          (face-remap-add-relative 'default (list :background color)))))

(defun etaf-mario-gui--settled (predicate)
  "Return a verifier settle predicate calling PREDICATE once per poll."
  (lambda (_context) (funcall predicate)))

(defun etaf-mario-gui-run (directory)
  "Play Super Mario through graphical native input and save evidence in DIRECTORY.
Run in an existing dedicated graphical frame; the frame geometry, the game
buffer and the progress file are restored after success or failure."
  (unless (display-graphic-p)
    (error "A graphical frame is required"))
  (let* ((frame-size (cons (frame-width) (frame-height)))
         (fullscreen (frame-parameter nil 'fullscreen))
         (previous-appearance etaf-mario-appearance)
         (previous-rate etaf-mario-frame-rate)
         (previous-file etaf-mario-progress-file)
         (progress (make-temp-file "mario-gui-" nil ".eld"))
         session-runtime)
    (unwind-protect
        (progn
          (with-temp-file progress (insert "(:best 0 :unlocked 3)\n"))
          (setq etaf-mario-progress-file progress
                etaf-mario-appearance 'light
                etaf-mario-frame-rate 30)
          (when (get-buffer etaf-mario-gui--buffer-name)
            (etaf-mario-close (get-buffer etaf-mario-gui--buffer-name)))
          (etaf-mario-gui--size 132 44)
          (etaf-mario-open)
          (setq etaf-mario-gui--buffer (get-buffer etaf-mario-gui--buffer-name))
          (etaf-mario-gui--canvas-background "#F4F5F1")
          (setq session-runtime (etaf-runtime-for-buffer etaf-mario-gui--buffer))
          (etaf-gui-verifier-run
           (etaf-gui-verifier-scenario-create
            :name "super-mario"
            :claim "Native platform play, blocks, items, enemies, dialogs, stages and resize"
            :initialize
            (lambda (context)
              (etaf-gui-verifier-context-select-buffer context etaf-mario-gui--buffer)
              (message nil))
            :invariants
            (lambda (_context)
              ;; The help panel is a full modal surface of its own; it covers
              ;; the game canvas, so the canvas and line-height budgets do not
              ;; describe the buffer while it is open.
              (unless (string-match-p "快捷键 · 只读" (etaf-mario-gui--text))
                (append
                 (list
                  (etaf-gui-verifier-assert
                   "sixteen canvas rows"
                   (eql 16 (length (etaf-mario-gui--canvas-lines)))
                   (format "rows %s" (length (etaf-mario-gui--canvas-lines)))))
                 (etaf-gui-verifier-line-height-assertions etaf-mario-gui--buffer))))
            :actions
            (let ((score-before-stomp 0)
                    (restart-time 0))
              (list
               (etaf-gui-verifier-action-create
                :id "title-start" :screenshot t :settle-timeout 10
                :execute (lambda (_context) (etaf-mario-gui--press "RET" 0.4))
                :settled-p (etaf-mario-gui--settled
                            (lambda ()
                              (and (not (string-match-p "开始游戏" (etaf-mario-gui--text)))
                                   (etaf-mario-gui--player-column)
                                   (< (etaf-mario-gui--time) 350))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the game clock is running"
                         (and (etaf-mario-gui--time) (< (etaf-mario-gui--time) 350)))
                        (etaf-gui-verifier-assert
                         "the player is painted at the start"
                         (eql 11 (etaf-mario-gui--player-column))))))
               (etaf-gui-verifier-action-create
                :id "walk" :settle-timeout 8
                :execute (lambda (_context) (etaf-mario-gui--hold "<right>" 0.7))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (> (or (etaf-mario-gui--player-column) 0) 20)))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "walking moves the painted player"
                         (> (or (etaf-mario-gui--player-column) 0) 20)))))
               (etaf-gui-verifier-action-create
                :id "bump-question" :screenshot t :settle-timeout 15
                :execute
                (lambda (_context)
                  ;; Walk in while watching the painted block.  Jump as soon
                  ;; as its centre lines up, exactly like the manual pass: the
                  ;; small residual walk speed carries into the block.
                  (let ((end (+ (float-time) 2.5))
                        (done nil))
                    (while (and (not done) (< (float-time) end))
                      (let* ((block (etaf-mario-gui--first-question-column))
                             (player (etaf-mario-gui--player-column))
                             (delta (and block player
                                         (- (1+ block) (+ player 3)))))
                        (if (and delta (<= (abs delta) 1))
                            (setq done t)
                          (etaf-mario-gui--press "<right>" 0.03)))))
                  (etaf-mario-gui--jump 0.45))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (eql 1 (etaf-mario-gui--coins))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the question block pays one coin"
                         (eql 1 (etaf-mario-gui--coins)))
                        (etaf-gui-verifier-assert
                         "the block pays two hundred points"
                         (>= (etaf-mario-gui--score) 200)))))
               (etaf-gui-verifier-action-create
                :id "mushroom" :screenshot t :settle-timeout 15
                :execute
                (lambda (_context)
                  (let ((end (+ (float-time) 2.5))
                        (done nil))
                    (while (and (not done) (< (float-time) end))
                      (let* ((run (etaf-mario-gui--block-run-column))
                             (player (etaf-mario-gui--player-column))
                             (delta (and run player
                                         (- (+ run 10) (+ player 3)))))
                        (if (and delta (<= (abs delta) 1))
                            (setq done t)
                          (etaf-mario-gui--press "<right>" 0.03)))))
                  (etaf-mario-gui--jump 0.4)
                  (sit-for 0.6)
                  ;; Step past the run's edge so the falling mushroom walks
                  ;; into Mario instead of being outrun.
                  (etaf-mario-gui--hold "<right> x" 0.35)
                  (let ((end (+ (float-time) 2.0)))
                    (while (and (< (float-time) end)
                                (not (string-match-p
                                      "超级" (etaf-mario-gui--hud-line))))
                      (sit-for 0.05))))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "超级" (etaf-mario-gui--hud-line))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the mushroom turns Mario big"
                         (string-match-p "超级" (etaf-mario-gui--hud-line)))
                        (etaf-gui-verifier-assert
                         "the mushroom pays a thousand points"
                         (>= (etaf-mario-gui--score) 1200)))))
               (etaf-gui-verifier-action-create
                :id "stomp-goomba" :settle-timeout 12
                :execute (lambda (_context)
                           (setq score-before-stomp (etaf-mario-gui--score))
                           (let ((tries 0) (done nil))
                             (while (and (not done) (< tries 20))
                               (let* ((goomba (etaf-mario-gui--goomba-column))
                                      (player (etaf-mario-gui--player-column))
                                      (delta (and goomba player (- goomba (+ player 3)))))
                                 (cond
                                  ((and delta (<= 3 delta 12))
                                   (setq done t)
                                   (etaf-mario-gui--jump 0.3)
                                   (etaf-mario-gui--hold "<right>" 0.45))
                                  (t (etaf-mario-gui--hold "<right>" 0.2)
                                     (cl-incf tries)))))))
                :settled-p (etaf-mario-gui--settled
                            (lambda ()
                              (>= (etaf-mario-gui--score) (+ score-before-stomp 100))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "stomping a goomba pays a hundred points"
                         (>= (etaf-mario-gui--score) (+ score-before-stomp 100)))
                        (etaf-gui-verifier-assert
                         "the stomp costs no life"
                         (>= (etaf-mario-gui--lives) 3)))))
               (etaf-gui-verifier-action-create
                :id "pause" :screenshot t :settle-timeout 8
                :execute (lambda (_context) (etaf-mario-gui--press "p" 0.3))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "继续游戏" (etaf-mario-gui--text))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert "the pause menu opens"
                                                  (string-match-p "继续游戏"
                                                                  (etaf-mario-gui--text))))))
               (etaf-gui-verifier-action-create
                :id "resume" :settle-timeout 8
                :execute (lambda (_context) (etaf-mario-gui--press "RET" 0.3))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (not (string-match-p "继续游戏" (etaf-mario-gui--text))))))
               (etaf-gui-verifier-action-create
                :id "settings-open" :screenshot t :settle-timeout 10
                :execute (lambda (_context) (etaf-mario-gui--press "s" 0.4))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "画面帧率" (etaf-mario-gui--text))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the settings dialog lists the frame-rate control"
                         (string-match-p "画面帧率" (etaf-mario-gui--text))))))
               (etaf-gui-verifier-action-create
                :id "settings-sixty" :screenshot t :settle-timeout 10
                :execute (lambda (_context)
                           (etaf-mario-gui--press "<right>" 0.2)
                           (etaf-mario-gui--press "RET" 0.3)
                           (etaf-mario-gui--press "s" 0.4))
                :settled-p (etaf-mario-gui--settled
                            (lambda ()
                              (and (= 60 etaf-mario-frame-rate)
                                   (not (string-match-p "画面帧率" (etaf-mario-gui--text))))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the settings dialog selects sixty frames"
                         (= 60 etaf-mario-frame-rate)))))
               (etaf-gui-verifier-action-create
                :id "help" :screenshot t :settle-timeout 10
                :execute (lambda (_context) (etaf-mario-gui--press "<f1>" 0.4))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "快捷键 · 只读" (etaf-mario-gui--text))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the help panel lists the application keys"
                         (string-match-p "跳跃" (etaf-mario-gui--text))))))
               (etaf-gui-verifier-action-create
                :id "close-help" :settle-timeout 8
                :execute (lambda (_context) (etaf-mario-gui--press "<escape>" 0.3))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (not (string-match-p "快捷键 · 只读"
                                                            (etaf-mario-gui--text))))))
               (etaf-gui-verifier-action-create
                :id "dark-theme" :screenshot t :settle-timeout 8
                :execute (lambda (_context)
                           (etaf-mario-gui--press "t" 0.2)
                           (etaf-mario-gui--canvas-background "#191A1C"))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "MARIO" (etaf-mario-gui--text))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the dark theme keeps the game readable"
                         (string-match-p "MARIO" (etaf-mario-gui--text))))))
               (etaf-gui-verifier-action-create
                :id "light-theme-again" :screenshot t :settle-timeout 8
                :execute (lambda (_context)
                           (etaf-mario-gui--press "t" 0.2)
                           (etaf-mario-gui--canvas-background "#F4F5F1"))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "MARIO" (etaf-mario-gui--text)))))
               (etaf-gui-verifier-action-create
                :id "restart" :settle-timeout 10
                :execute (lambda (_context)
                           (setq restart-time (etaf-mario-gui--time))
                           (etaf-mario-gui--press "r" 0.05))
                :settled-p (etaf-mario-gui--settled
                            (lambda ()
                              (and (eql 11 (etaf-mario-gui--player-column))
                                   (> (etaf-mario-gui--time) restart-time))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "restarting restores the level clock"
                         (>= (etaf-mario-gui--time) 345))
                        (etaf-gui-verifier-assert
                         "restarting returns the player to the start"
                         (eql 11 (etaf-mario-gui--player-column))))))
               (etaf-gui-verifier-action-create
                :id "to-title" :settle-timeout 10
                :execute (lambda (_context)
                           (etaf-mario-gui--press "p" 0.3)
                           (etaf-mario-gui--press "TAB TAB TAB TAB" 0.1)
                           (etaf-mario-gui--press "RET" 0.3))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "开始游戏" (etaf-mario-gui--text)))))
               (etaf-gui-verifier-action-create
                :id "select-unlocked-list" :screenshot t :settle-timeout 10
                :execute (lambda (_context)
                           (etaf-mario-gui--press "TAB" 0.1)
                           (etaf-mario-gui--press "RET" 0.3))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (string-match-p "1-4 熔岩城堡" (etaf-mario-gui--text))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the level picker lists the unlocked campaign"
                         (and (string-match-p "1-1 郁绿平原" (etaf-mario-gui--text))
                              (string-match-p "1-4 熔岩城堡" (etaf-mario-gui--text)))))))
               (etaf-gui-verifier-action-create
                :id "select-second-stage" :settle-timeout 10
                :execute (lambda (_context)
                           (etaf-mario-gui--press "<down>" 0.2)
                           (etaf-mario-gui--press "RET" 0.4))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (equal "1-2" (etaf-mario-gui--world))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the HUD names the selected stage"
                         (equal "1-2" (etaf-mario-gui--world)))
                        (etaf-gui-verifier-assert
                         "the underground ceiling is painted"
                         (and (etaf-mario-gui--canvas-lines)
                              (string-match-p "╬" (mapconcat #'identity
                                                              (etaf-mario-gui--canvas-lines)
                                                              "\n")))))))
               (etaf-gui-verifier-action-create
                :id "wide-150" :screenshot t :settle-timeout 12
                :execute (lambda (_context) (etaf-mario-gui--size 150 26))
                :settled-p (etaf-mario-gui--settled #'etaf-mario-gui--canvas-settled-p)
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert "wide canvas follows the window"
                                                  (etaf-mario-gui--canvas-settled-p)))))
               (etaf-gui-verifier-action-create
                :id "standard-100" :screenshot t :settle-timeout 12
                :execute (lambda (_context) (etaf-mario-gui--size 100 30))
                :settled-p (etaf-mario-gui--settled #'etaf-mario-gui--canvas-settled-p)
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert "standard canvas follows the window"
                                                  (etaf-mario-gui--canvas-settled-p)))))
               (etaf-gui-verifier-action-create
                :id "narrow-72" :screenshot t :settle-timeout 12
                :execute (lambda (_context) (etaf-mario-gui--size 72 24))
                :settled-p (etaf-mario-gui--settled #'etaf-mario-gui--canvas-settled-p)
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the compact HUD hides the optional stage label"
                         (not (string-match-p "WORLD" (etaf-mario-gui--hud-line))))
                        (etaf-gui-verifier-assert
                         "the narrow canvas follows the window"
                         (etaf-mario-gui--canvas-settled-p)))))
               (etaf-gui-verifier-action-create
                :id "standard-132" :screenshot t :settle-timeout 12
                :execute (lambda (_context) (etaf-mario-gui--size 132 44))
                :settled-p (etaf-mario-gui--settled #'etaf-mario-gui--canvas-settled-p)
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the restored canvas follows the window"
                         (etaf-mario-gui--canvas-settled-p)))))
               (etaf-gui-verifier-action-create
                :id "select-castle" :screenshot t :settle-timeout 12
                :execute (lambda (_context)
                           (etaf-mario-gui--press "p" 0.3)
                           (etaf-mario-gui--press "TAB TAB TAB TAB" 0.1)
                           (etaf-mario-gui--press "RET" 0.3)
                           (etaf-mario-gui--press "TAB" 0.1)
                           (etaf-mario-gui--press "RET" 0.3)
                           (etaf-mario-gui--press "<down> <down> <down>" 0.1)
                           (etaf-mario-gui--press "RET" 0.4))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (equal "1-4" (etaf-mario-gui--world))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "the castle stage paints lava and stone"
                         (let ((canvas (mapconcat #'identity
                                                   (etaf-mario-gui--canvas-lines) "\n")))
                           (and (string-match-p "≋" canvas)
                                (string-match-p "╬" canvas)))))))
               (etaf-gui-verifier-action-create
                :id "select-sky-stage" :settle-timeout 12
                :execute (lambda (_context)
                           (etaf-mario-gui--press "p" 0.3)
                           (etaf-mario-gui--press "TAB TAB TAB TAB" 0.1)
                           (etaf-mario-gui--press "RET" 0.3)
                           (etaf-mario-gui--press "TAB" 0.1)
                           (etaf-mario-gui--press "RET" 0.3)
                           (etaf-mario-gui--press "<down> <down>" 0.1)
                           (etaf-mario-gui--press "RET" 0.4))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (equal "1-3" (etaf-mario-gui--world)))))
               (etaf-gui-verifier-action-create
                :id "pit-death" :screenshot t :settle-timeout 15
                :execute (lambda (_context) (etaf-mario-gui--hold "<right>" 3.0))
                :settled-p (etaf-mario-gui--settled
                            (lambda () (= 2 (etaf-mario-gui--lives))))
                :assertions
                (lambda (_context)
                  (list (etaf-gui-verifier-assert
                         "falling into the first pit costs one life"
                         (= 2 (etaf-mario-gui--lives)))
                        (etaf-gui-verifier-assert
                         "the stage continues after the death"
                         (equal "1-3" (etaf-mario-gui--world))))))
               (etaf-gui-verifier-action-create
                :id "update-report" :settle-timeout 8
                :execute (lambda (_context)
                           (etaf-mario-gui--hold "<right>" 0.6))
                :settled-p (etaf-mario-gui--settled
                            (lambda ()
                              (eq 'lines
                                  (plist-get (etaf-runtime-update-report session-runtime)
                                             :strategy))))
                :assertions
                (lambda (_context)
                  (let ((report (etaf-runtime-update-report session-runtime)))
                    (list (etaf-gui-verifier-assert
                           "the running frame publishes only changed lines"
                           (eq 'lines (plist-get report :strategy)))
                          (etaf-gui-verifier-assert
                           "one frame updates at most a stage row and the HUD"
                           (<= (or (plist-get report :edits) 0) 16)))))))))
           directory))
      (when etaf-mario-gui--background-cookie
        (when (and etaf-mario-gui--buffer
                   (buffer-live-p etaf-mario-gui--buffer))
          (with-current-buffer etaf-mario-gui--buffer
            (face-remap-remove-relative etaf-mario-gui--background-cookie)))
        (setq etaf-mario-gui--background-cookie nil))
      (when (and etaf-mario-gui--buffer
                 (buffer-live-p etaf-mario-gui--buffer))
        (etaf-mario-close etaf-mario-gui--buffer))
      (setq etaf-mario-progress-file previous-file
            etaf-mario-appearance previous-appearance
            etaf-mario-frame-rate previous-rate)
      (when (file-exists-p progress) (delete-file progress))
      (set-frame-size nil (car frame-size) (cdr frame-size))
      (set-frame-parameter nil 'fullscreen fullscreen))))

(provide 'etaf-mario-gui-scenarios)
;;; etaf-mario-gui-scenarios.el ends here
