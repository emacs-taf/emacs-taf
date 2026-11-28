;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-model.el --- Observation contract, settings and battle commands
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Godot world owns every rule.  This file checks the published
;; observation before GameKit accepts it, translates the user's settings to
;; native parameters and sends commands only when they can take effect.

;;; Code:
(require 'cl-lib)
(require 'etaf-gamekit)

(defvar etaf-tanks-game-speed)
(defvar etaf-tanks-tank-speed)
(defvar etaf-tanks-sensitivity)
(defvar etaf-tanks-drive-mode)
(defvar etaf-tanks-frame-rate)
(defvar etaf-tanks-board-size)

(defconst etaf-tanks--phases '("menu" "edit" "intro" "play" "cleared" "over")
  "Phases published by the native adapter.")

(defun etaf-tanks--flag-p (value)
  "Whether VALUE is a decoded JSON boolean."
  (memq value '(t :false)))

(defun etaf-tanks--count-p (value &optional limit)
  "Whether VALUE is a natural number not above LIMIT."
  (and (natnump value) (or (null limit) (<= value limit))))

(defun etaf-tanks--valid-hud-p (hud)
  "Whether HUD is the stable battle summary."
  (and (cl-every (lambda (key) (etaf-tanks--count-p (plist-get hud key)))
                 '(:lives :score :star :remaining :field :total))
       (<= (plist-get hud :star) 3)
       (cl-every (lambda (key) (etaf-tanks--flag-p (plist-get hud key)))
                 '(:alive :shield :freeze :fortify :base))
       (let ((kills (plist-get hud :kills)))
         (and (proper-list-p kills) (= (length kills) 4) (cl-every #'natnump kills)))
       (let ((bonus (plist-get hud :bonus)))
         (or (null bonus) (member bonus '("helmet" "clock" "shovel" "star" "grenade" "tank"))))))

(defun etaf-tanks--valid-actor-p (actor size)
  "Whether ACTOR is the player's per-frame state inside SIZE blocks."
  (and (numberp (plist-get actor :x)) (numberp (plist-get actor :y))
       (<= 0 (plist-get actor :x) (car size)) (<= 0 (plist-get actor :y) (cadr size))
       (member (plist-get actor :facing) '("n" "e" "s" "w"))
       (etaf-tanks--flag-p (plist-get actor :moving))
       (etaf-tanks--flag-p (plist-get actor :can_fire))
       (natnump (plist-get actor :shots))))

(defun etaf-tanks--valid-world-p (world size)
  "Whether WORLD is a text-mode world description of SIZE blocks."
  (let ((rows (plist-get world :terrain)))
    (and (proper-list-p rows) (= (length rows) (cadr size))
         (cl-every (lambda (row) (and (stringp row) (= (length row) (car size)))) rows)
         (proper-list-p (plist-get world :units))
         (cl-every (lambda (unit) (and (numberp (plist-get unit :x)) (numberp (plist-get unit :y))
                                       (member (plist-get unit :facing) '("n" "e" "s" "w"))
                                       (member (plist-get unit :kind) '("player" "enemy"))))
                   (plist-get world :units))
         (proper-list-p (plist-get world :shells)))))

(defun etaf-tanks--valid-p (observation)
  "Validate OBSERVATION before GameKit publishes it to this application."
  (let ((size (plist-get observation :size)) (frame (plist-get observation :frame))
        (events (plist-get observation :events)) (phase (plist-get observation :phase)))
    (and (equal (plist-get observation :schema) "tanks/2")
         (member phase etaf-tanks--phases)
         (etaf-tanks--flag-p (plist-get observation :paused))
         (natnump (plist-get observation :stage))
         (stringp (plist-get observation :title))
         (member (plist-get observation :difficulty) '("easy" "normal" "hard"))
         (or (null size)
             (and (proper-list-p size) (= (length size) 2)
                  (integerp (car size)) (<= 12 (car size) 52)
                  (integerp (cadr size)) (<= 12 (cadr size) 40)))
         (or (null frame)
             (and (natnump (plist-get frame :id)) (natnump (plist-get frame :block))
                  (natnump (plist-get frame :line)) (natnump (plist-get frame :width))
                  (proper-list-p (plist-get frame :strips))
                  (cl-every #'natnump (plist-get frame :strips))))
         (proper-list-p events)
         (cl-every (lambda (event) (and (natnump (plist-get event :id)) (stringp (plist-get event :title))
                                        (stringp (plist-get event :detail)) (stringp (plist-get event :kind))))
                   events)
         (or (member phase '("menu" "edit"))
             (and size (etaf-tanks--valid-hud-p (plist-get observation :hud))
                  (etaf-tanks--valid-actor-p (plist-get observation :actor) size)))
         (or (null (plist-get observation :world))
             (and size (etaf-tanks--valid-world-p (plist-get observation :world) size)))
         t)))

;;; Settings

(defconst etaf-tanks--sensitivities
  '((sensitive 0.20 0.08) (standard 0.30 0.12) (smooth 0.45 0.18))
  "Drive hold after the first press and after each repeat, in seconds.")

(defvar etaf-tanks--keyboard-timing nil
  "Cached (HOLD REPEAT) derived from the system key repeat, or `none'.")

(defun etaf-tanks--keyboard-timing ()
  "Derive drive hold times from the macOS key repeat settings, once.
The first hold must outlast the delay before keys start repeating, and the
repeat hold must bridge several repeat intervals; otherwise a held arrow
stutters between the press and the first repeat."
  (unless etaf-tanks--keyboard-timing
    (setq etaf-tanks--keyboard-timing
          (or (and (eq system-type 'darwin) (executable-find "defaults")
                   (let ((read (lambda (key)
                                 (with-temp-buffer
                                   (and (eq 0 (call-process "defaults" nil t nil "read" "-g" key))
                                        (let ((value (string-to-number (buffer-string))))
                                          (and (> value 0) (* value 0.015))))))))
                     (let ((initial (funcall read "InitialKeyRepeat"))
                           (interval (funcall read "KeyRepeat")))
                       (and initial interval
                            (list (min 1.0 (max 0.12 (+ initial 0.06)))
                                  (min 0.5 (max 0.06 (+ (* 3 interval) 0.03))))))))
              'none)))
  (if (eq etaf-tanks--keyboard-timing 'none)
      (cdr (assq 'standard etaf-tanks--sensitivities))
    etaf-tanks--keyboard-timing))

(defun etaf-tanks--default-settings ()
  "Return the session settings plist from the user's options."
  (list :speed etaf-tanks-game-speed :tank-speed etaf-tanks-tank-speed
        :sensitivity etaf-tanks-sensitivity :drive etaf-tanks-drive-mode
        :frame-rate etaf-tanks-frame-rate :board etaf-tanks-board-size))

(defun etaf-tanks--native-settings (settings)
  "Translate SETTINGS to the adapter's settings arguments."
  (let ((timing (if (eq (plist-get settings :sensitivity) 'auto)
                    (etaf-tanks--keyboard-timing)
                  (cdr (assq (plist-get settings :sensitivity) etaf-tanks--sensitivities)))))
    (list :speed (float (plist-get settings :speed))
          :player_speed (float (plist-get settings :tank-speed))
          :hold (car timing) :repeat (cadr timing)
          :latch (if (eq (plist-get settings :drive) 'latch) t :false)
          :frame_rate (plist-get settings :frame-rate))))

;;; Commands

(defun etaf-tanks--usable-p (session)
  "Whether SESSION accepts commands now."
  (memq (etaf-gamekit-status session) '(ready busy)))

(defconst etaf-tanks--input-operations '("drive" "aim" "stop" "fire")
  "Operations a held key repeats, dropped while the request queue is full.")

(defconst etaf-tanks--state-operations '("menu" "edit" "display" "settings")
  "Operations carrying complete state, so a newer one replaces a waiting one.")

(defvar etaf-tanks--backlogs (make-hash-table :test #'eq :weakness 'key)
  "Commands per session waiting for request-queue room, oldest first.")

(defun etaf-tanks--post (session operation arguments)
  "Hand OPERATION with ARGUMENTS to SESSION; return nil when the queue is full.
Only a busy session has outstanding requests that can fill the queue, so any
other rejection is a defect and is signalled again."
  (condition-case problem
      (progn (etaf-gamekit-action session operation arguments) t)
    (etaf-gamekit-error
     (if (eq (etaf-gamekit-status session) 'busy) nil
       (signal (car problem) (cdr problem))))))

(defun etaf-tanks--drain (session)
  "Send SESSION's waiting commands in order while the queue has room."
  (let ((backlog (gethash session etaf-tanks--backlogs)))
    (if (not (etaf-tanks--usable-p session))
        (remhash session etaf-tanks--backlogs)
      (while (and backlog (etaf-tanks--post session (caar backlog) (cdar backlog)))
        (setq backlog (cdr backlog)))
      (if (null backlog)
          (remhash session etaf-tanks--backlogs)
        (puthash session backlog etaf-tanks--backlogs)
        (run-at-time 0.016 nil #'etaf-tanks--drain session)))))

(defun etaf-tanks--send (session operation &optional arguments)
  "Send OPERATION with ARGUMENTS to a usable SESSION; return non-nil if accepted.
Held-key input is dropped while the request queue is full, since the key
repeats.  Other commands wait in order for room; a waiting command that
carries complete state is replaced by a newer one of the same operation."
  (when (etaf-tanks--usable-p session)
    (let ((backlog (gethash session etaf-tanks--backlogs)))
      (cond
       ((member operation etaf-tanks--input-operations)
        (etaf-tanks--post session operation arguments))
       ((and (null backlog) (etaf-tanks--post session operation arguments)) t)
       (t
        (let ((tail (car (last backlog))))
          (if (and tail (equal (car tail) operation) (member operation etaf-tanks--state-operations))
              (setcdr tail arguments)
            (puthash session (append backlog (list (cons operation arguments))) etaf-tanks--backlogs)
            (unless backlog (run-at-time 0.016 nil #'etaf-tanks--drain session))))
        t)))))

(defun etaf-tanks--phase (session)
  "Return SESSION's latest accepted phase without copying the observation."
  (plist-get (etaf-gamekit-observation session) :phase))

(defun etaf-tanks--live-p (session)
  "Whether SESSION shows a battle that is still running or introducing."
  (let ((observation (etaf-gamekit-observation session)))
    (and (member (plist-get observation :phase) '("intro" "play"))
         (eq (plist-get observation :paused) :false))))

(defun etaf-tanks--pause-for-input (session)
  "Pause a running battle before a dialog or minibuffer prompt takes input.
The explicit state is idempotent, so a pause still in flight from P is kept."
  (when (member (etaf-tanks--phase session) '("intro" "play"))
    (etaf-tanks--send session "pause" '(:paused t))))

(provide 'etaf-tanks-model)
;;; etaf-tanks-model.el ends here
