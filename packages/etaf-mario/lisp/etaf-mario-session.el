;;; -*- lexical-binding: t; -*-
;;; etaf-mario-session.el --- Reactive state shared by loop and presentation

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A session owns one running game: its world, display phase, canvas rows and
;; the reactive values the View reads.  The simulation mutates the world in
;; place; the loop copies the few values the HUD shows into refs so a score
;; change repaints one line instead of the whole application.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-mario-model)

(cl-defstruct (etaf-mario--session (:constructor etaf-mario--session-create))
  "Mutable state of one open game."
  buffer runtime world
  phase-ref frame-ref appearance-ref
  score-ref coins-ref time-ref lives-ref power-ref message-ref
  level-ref best-ref
  cols rows win-cols win-rows size-ref frame revision
  timer last-tick next-due accumulator ticks
  held hud jump-pressed fire-pressed
  settings message message-until
  progress best menu)

(defun etaf-mario--session-make (level-index &optional appearance settings progress)
  "Return a session for LEVEL-INDEX.
APPEARANCE, SETTINGS and PROGRESS seed the new game."
  (let* ((world (etaf-mario-world-create level-index))
         (big (frame-parameter nil 'background-mode)))
    (etaf-mario--session-create
     :world world
     :phase-ref (etaf-ref 'title)
     :frame-ref (etaf-ref nil)
     :appearance-ref (etaf-ref
                      (if (eq appearance 'auto)
                          (if (eq big 'dark) 'dark 'light)
                        (or appearance 'light)))
     :score-ref (etaf-ref (etaf-mario-world-score world))
     :coins-ref (etaf-ref (etaf-mario-world-coins world))
     :time-ref (etaf-ref (etaf-mario-world-time world))
     :lives-ref (etaf-ref (etaf-mario-world-lives world))
     :power-ref (etaf-ref 'small)
     :message-ref (etaf-ref nil)
     :level-ref (etaf-ref "1-1")
     :best-ref (etaf-ref (or (plist-get progress :best) 0))
     :win-rows 0
     :win-cols 0
     :size-ref (etaf-ref (cons 0 0))
     :revision (etaf-ref 0)
     :cols 0 :rows 0 :frame nil
     :held nil :hud nil :jump-pressed nil :fire-pressed nil :ticks 0
     :settings (or settings (list :frame-rate 30))
     :message nil :message-until 0.0
     :progress (or progress (list :best 0 :unlocked 0))
     :best (or (plist-get progress :best) 0)
     :menu 0)))

(defun etaf-mario-session-phase (session)
  "Return SESSION's current display phase."
  (etaf-value (etaf-mario--session-phase-ref session)))

(defun etaf-mario-session-player-power (session)
  "Return SESSION's player power symbol."
  (etaf-mario--player-power (etaf-mario-world-player (etaf-mario--session-world session))))

(defun etaf-mario--session-sync (session)
  "Copy SESSION's running counters into its reactive refs.
Only changed values are written, so a steady frame publishes nothing."
  (let* ((world (etaf-mario--session-world session))
         (player (etaf-mario-world-player world))
         (pairs (list (cons (etaf-mario--session-score-ref session)
                            (etaf-mario-world-score world))
                      (cons (etaf-mario--session-coins-ref session)
                            (etaf-mario-world-coins world))
                      (cons (etaf-mario--session-time-ref session)
                            (etaf-mario-world-time world))
                      (cons (etaf-mario--session-lives-ref session)
                            (etaf-mario-world-lives world))
                      (cons (etaf-mario--session-power-ref session)
                            (etaf-mario--player-power player)))))
    (dolist (pair pairs)
      (unless (equal (etaf-value (car pair)) (cdr pair))
        (setf (etaf-value (car pair)) (cdr pair))))))

(defun etaf-mario--session-say (session text &optional seconds)
  "Show TEXT in SESSION's footer for SECONDS."
  (setf (etaf-mario--session-message session) text
        (etaf-mario--session-message-until session) (+ (float-time) (or seconds 2.0)))
  (unless (equal (etaf-value (etaf-mario--session-message-ref session)) text)
    (setf (etaf-value (etaf-mario--session-message-ref session)) text)))

(defun etaf-mario--session-expire-message (session)
  "Clear SESSION's footer message once its time is over."
  (when (and (etaf-mario--session-message session)
             (> (float-time) (etaf-mario--session-message-until session)))
    (setf (etaf-mario--session-message session) nil)
    (when (etaf-value (etaf-mario--session-message-ref session))
      (setf (etaf-value (etaf-mario--session-message-ref session)) nil))))

(provide 'etaf-mario-session)
;;; etaf-mario-session.el ends here
