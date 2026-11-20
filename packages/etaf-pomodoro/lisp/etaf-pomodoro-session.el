;;; etaf-pomodoro-session.el --- Countdown state of one Pomodoro session -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A session owns the timer's reactive state: the seconds left, the length the
;; session started with, whether it is running and the visual style.  Every
;; displayed value is a ref, so the countdown, a button and a key all repaint
;; through the framework instead of calling a refresh.  The session also owns
;; the one-second tick timer; it starts when a View mounts it and stops when
;; that View unmounts or the caller closes the session.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(define-error 'etaf-pomodoro-error "Invalid Pomodoro operation")

(defvar etaf-pomodoro-default-minutes)

(defvar etaf-pomodoro-default-minutes 25
  "Focus length of a session created without :minutes.
Declared as a defcustom in `etaf-pomodoro.el'; this copy keeps the file
compilable on its own.")

(defconst etaf-pomodoro--styles '(minimal ring card)
  "Visual styles, in cycling order.")

(cl-defstruct (etaf-pomodoro--session (:constructor etaf-pomodoro--session-make)
                                      (:copier nil))
  "Reactive state of one timer."
  remaining total running style timer)

(defun etaf-pomodoro--session-check (session)
  "Return SESSION, or signal when a caller passed something else."
  (unless (etaf-pomodoro--session-p session)
    (signal 'etaf-pomodoro-error
            (list (format "Not a Pomodoro session: %S" session))))
  session)

(cl-defun etaf-pomodoro-create (&key minutes style)
  "Return a new Pomodoro session.
MINUTES is the focus length, 25 by default.  STYLE is `minimal' (default),
`ring' or `card'.  The session starts paused; mounting its View through
`etaf-pomodoro-view' starts the one-second tick, and closing it stops the
tick."
  (let* ((minutes (or minutes etaf-pomodoro-default-minutes))
         (style (or style 'minimal)))
    (unless (and (wholenump minutes) (> minutes 0))
      (signal 'etaf-pomodoro-error
              (list (format "Focus length must be a positive number of minutes: %S"
                            minutes))))
    (unless (memq style etaf-pomodoro--styles)
      (signal 'etaf-pomodoro-error
              (list (format "Unknown Pomodoro style: %S" style))))
    (let ((seconds (* 60 minutes)))
      (etaf-pomodoro--session-make
       :remaining (etaf-ref seconds)
       :total (etaf-ref seconds)
       :running (etaf-ref nil)
       :style (etaf-ref style)))))

(defun etaf-pomodoro-state (session)
  "Return SESSION's public state as a plist.
The keys are `:remaining' (seconds left), `:total' (seconds the session
started with), `:running' (non-nil while counting) and `:style'."
  (etaf-pomodoro--session-check session)
  (list :remaining (etaf-value (etaf-pomodoro--session-remaining session))
        :total (etaf-value (etaf-pomodoro--session-total session))
        :running (etaf-value (etaf-pomodoro--session-running session))
        :style (etaf-value (etaf-pomodoro--session-style session))))

(defun etaf-pomodoro-toggle (session)
  "Start or pause SESSION's countdown and return its new running state."
  (etaf-pomodoro--session-check session)
  (let ((running (etaf-pomodoro--session-running session)))
    (etaf-batch (setf (etaf-value running) (not (etaf-value running))))
    (etaf-value running)))

(defun etaf-pomodoro-reset (session)
  "Return SESSION's countdown to its full length and pause it."
  (etaf-pomodoro--session-check session)
  (etaf-batch
    (setf (etaf-value (etaf-pomodoro--session-remaining session))
          (etaf-value (etaf-pomodoro--session-total session)))
    (setf (etaf-value (etaf-pomodoro--session-running session)) nil))
  (etaf-pomodoro-state session))

(defun etaf-pomodoro-extend (session &optional minutes)
  "Add MINUTES of focus, 5 by default, to SESSION's countdown.
The extra time also extends the session's full length, so the progress line
keeps measuring the whole countdown."
  (etaf-pomodoro--session-check session)
  (let ((seconds (* 60 (or minutes 5))))
    (unless (and (wholenump seconds) (> seconds 0))
      (signal 'etaf-pomodoro-error
              (list (format "Extension must be a positive number of minutes: %S"
                            minutes))))
    (etaf-batch
      (setf (etaf-value (etaf-pomodoro--session-remaining session))
            (+ (etaf-value (etaf-pomodoro--session-remaining session)) seconds))
      (setf (etaf-value (etaf-pomodoro--session-total session))
            (+ (etaf-value (etaf-pomodoro--session-total session)) seconds)))
    (etaf-pomodoro-state session)))

(defun etaf-pomodoro-next-style (session)
  "Switch SESSION to the next visual style and return that style."
  (etaf-pomodoro--session-check session)
  (let* ((style (etaf-pomodoro--session-style session))
         (next (car (or (cdr (memq (etaf-value style) etaf-pomodoro--styles))
                        etaf-pomodoro--styles))))
    (etaf-batch (setf (etaf-value style) next))
    next))

(defun etaf-pomodoro--tick (session)
  "Advance SESSION's countdown by one second while it runs.
The countdown stops at zero and reports the finished focus through the echo
area; the timer itself keeps ticking so the next start needs no new timer."
  (when (etaf-value (etaf-pomodoro--session-running session))
    (let ((left (1- (etaf-value (etaf-pomodoro--session-remaining session)))))
      (if (> left 0)
          (etaf-batch
            (setf (etaf-value (etaf-pomodoro--session-remaining session)) left))
        (etaf-batch
          (setf (etaf-value (etaf-pomodoro--session-remaining session)) 0)
          (setf (etaf-value (etaf-pomodoro--session-running session)) nil))
        (message "番茄完成，起来走走")))))

(defun etaf-pomodoro--start (session)
  "Start SESSION's one-second tick unless it already runs."
  (etaf-pomodoro--session-check session)
  (unless (timerp (etaf-pomodoro--session-timer session))
    (setf (etaf-pomodoro--session-timer session)
          (run-at-time 1 1 (lambda () (etaf-pomodoro--tick session))))))

(defun etaf-pomodoro-stop-session (session)
  "Stop SESSION's one-second tick and return SESSION.
The countdown keeps its values, so a session mounted again continues from
where it stopped."
  (when (etaf-pomodoro--session-p session)
    (when (timerp (etaf-pomodoro--session-timer session))
      (cancel-timer (etaf-pomodoro--session-timer session)))
    (setf (etaf-pomodoro--session-timer session) nil))
  session)

(provide 'etaf-pomodoro-session)
;;; etaf-pomodoro-session.el ends here
