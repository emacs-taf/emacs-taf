;;; etaf-pomodoro-tests.el --- Acceptance tests for etaf-pomodoro -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests.  Every scenario drives the timer through the
;; interfaces declared in `etaf-pomodoro.el'; rendering scenarios mount a real
;; runtime in a batch Emacs and read the visible buffer back, so they assert
;; what a reader sees instead of internal state.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-pomodoro)

(defun etaf-pomodoro-tests--mount (session)
  "Mount SESSION's View in a fresh buffer and return that buffer."
  (etaf-mount (generate-new-buffer " *pomodoro-test*")
              (etaf-pomodoro-view session)
              '(:viewport-width 60 :viewport-height 20)))

(defmacro etaf-pomodoro-tests--with-mount (session &rest body)
  "Mount SESSION, run BODY in its buffer, and always kill the buffer."
  (declare (indent 1) (debug t))
  `(let ((buffer (etaf-pomodoro-tests--mount ,session)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun etaf-pomodoro-tests--text ()
  "Return the visible text of the current buffer without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun etaf-pomodoro-tests--face-at (needle property)
  "Return PROPERTY of the face at the first occurrence of NEEDLE."
  (goto-char (point-min))
  (should (search-forward needle nil t))
  (let* ((face (or (get-text-property (match-beginning 0) 'face)
                   (plist-get (text-properties-at (match-beginning 0)) 'face)))
         (faces (cond ((null face) nil)
                      ((and (listp face) (keywordp (car face))) (list face))
                      ((listp face) face)
                      (t (list face)))))
    (cl-loop for entry in faces
             when (and (listp entry) (plist-get entry property))
             return (plist-get entry property))))

(etaf-define-component etaf-pomodoro-tests--host (&key appearance session)
  "Host SESSION's timer inside an explicitly provided APPEARANCE."
  :setup (etaf-appearance-provide appearance)
  :render (etaf-pomodoro-view session))

(defun etaf-pomodoro-tests--mount-host (appearance session)
  "Mount SESSION's timer with APPEARANCE and return its buffer."
  (etaf-mount (generate-new-buffer " *pomodoro-host-test*")
              (etaf-view (etaf-pomodoro-tests--host
                          :appearance appearance :session session))
              '(:viewport-width 60 :viewport-height 20)))

(ert-deftest etaf-pomodoro-creates-a-paused-session ()
  "A new session starts paused at its full length with the default style."
  (let ((session (etaf-pomodoro-create)))
    (should (equal (list :remaining 1500 :total 1500 :running nil :style 'minimal)
                   (etaf-pomodoro-state session))))
  (let ((session (etaf-pomodoro-create :minutes 5 :style 'ring)))
    (should (equal (list :remaining 300 :total 300 :running nil :style 'ring)
                   (etaf-pomodoro-state session)))))

(ert-deftest etaf-pomodoro-rejects-invalid-input ()
  "An unknown style or a non-positive length is a session error."
  (let ((error (should-error (etaf-pomodoro-create :minutes 0)
                             :type 'etaf-pomodoro-error)))
    (should (string-match-p "positive" (error-message-string error))))
  (should-error (etaf-pomodoro-create :style 'sepia) :type 'etaf-pomodoro-error)
  (should-error (etaf-pomodoro-extend (etaf-pomodoro-create) 0)
                :type 'etaf-pomodoro-error))

(ert-deftest etaf-pomodoro-commands-move-the-countdown ()
  "Toggle, reset, extend and the style cycle change the state they own."
  (let ((session (etaf-pomodoro-create :minutes 1)))
    (should (eq t (etaf-pomodoro-toggle session)))
    (should (plist-get (etaf-pomodoro-state session) :running))
    (should-not (etaf-pomodoro-toggle session))
    (should-not (plist-get (etaf-pomodoro-state session) :running))
    (etaf-pomodoro-extend session)
    (should (equal (list 360 360)
                   (list (plist-get (etaf-pomodoro-state session) :remaining)
                         (plist-get (etaf-pomodoro-state session) :total))))
    (etaf-pomodoro-toggle session)
    (etaf-pomodoro-reset session)
    (should (equal (list :remaining 360 :total 360 :running nil :style 'minimal)
                   (etaf-pomodoro-state session)))
    (should (eq 'ring (etaf-pomodoro-next-style session)))
    (should (eq 'card (etaf-pomodoro-next-style session)))
    (should (eq 'minimal (etaf-pomodoro-next-style session)))))

(ert-deftest etaf-pomodoro-tick-runs-only-while-mounted ()
  "The mounted View counts a running session and stops on unmount.
The countdown is the observable result: one second of wall time removes one
second, and a session left paused, or one whose View is gone, keeps its value."
  (let* ((session (etaf-pomodoro-create :minutes 1))
         (buffer (etaf-pomodoro-tests--mount session)))
    (unwind-protect
        (with-current-buffer buffer
          (sleep-for 1.2)
          (should (= 60 (plist-get (etaf-pomodoro-state session) :remaining)))
          (etaf-pomodoro-toggle session)
          (sleep-for 1.2)
          (should (< (plist-get (etaf-pomodoro-state session) :remaining) 60)))
      (kill-buffer buffer))
    ;; The unmounted session keeps its value: the tick stopped with the View.
    (let ((remaining (plist-get (etaf-pomodoro-state session) :remaining)))
      (sleep-for 1.2)
      (should (= remaining (plist-get (etaf-pomodoro-state session) :remaining))))))

(ert-deftest etaf-pomodoro-view-renders-the-clock-and-actions ()
  "The mounted surface shows the countdown, the actions and the key hints."
  (etaf-pomodoro-tests--with-mount (etaf-pomodoro-create)
    (let ((text (etaf-pomodoro-tests--text)))
      (should (string-match-p "25:00" text))
      (should (string-match-p "已暂停" text))
      (should (string-match-p "开始" text))
      (should (string-match-p "重置" text))
      (should (string-match-p "+5" text))
      (should (string-match-p "风格" text))
      (should (string-match-p "25 分钟" text))
      (should (string-match-p "p 暂停" text))
      (should (string-match-p "t 风格" text))
      ;; The progress line is drawn, not just described.
      (should (string-match-p "\u2501\\|\u2500" text)))))

(ert-deftest etaf-pomodoro-styles-share-one-height ()
  "Every style paints the same rows, so a panel keeps its size on a switch.
A style that needed an extra row would clip a panel whose frame settled at
mount, which is why the styles share one four-row body."
  (let* ((session (etaf-pomodoro-create :style 'minimal))
         (buffer (etaf-pomodoro-tests--mount session)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((heights (list (line-number-at-pos (point-max)))))
            (etaf-pomodoro-next-style session)
            (push (line-number-at-pos (point-max)) heights)
            (etaf-pomodoro-next-style session)
            (push (line-number-at-pos (point-max)) heights)
            (should (= 1 (length (delete-dups heights))))))
      (kill-buffer buffer))))

(ert-deftest etaf-pomodoro-surface-follows-the-host-appearance ()
  "A host that provides an appearance controls the timer's palette.
The timer used to read the panel's tokens at mount; a provided appearance ref
must repaint the same mounted surface when it switches."
  (let ((appearance (etaf-ref 'light)))
    (let ((buffer (etaf-pomodoro-tests--mount-host
                         appearance (etaf-pomodoro-create))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((light (etaf-pomodoro-tests--face-at "25:00" :foreground)))
              (should (equal "#383A42" light))
              (etaf-set-value appearance 'dark)
              (should (equal "#E9F0F4"
                             (etaf-pomodoro-tests--face-at "25:00" :foreground)))))
        (kill-buffer buffer)))))

(provide 'etaf-pomodoro-tests)
;;; etaf-pomodoro-tests.el ends here
