;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi-app.el --- Standalone game definition and lifetime

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-gamekit)
(require 'etaf-xiangqi-views)

(defvar-local etaf-xiangqi--session nil)

(etaf-gamekit-define-game etaf-xiangqi-game
  :title "Chu He · 中国象棋" :backend 'openspiel
  :options '(:game "xiangqi" :player 0 :seed 11)
  :validate (lambda (observation)
              (and (equal (plist-get observation :schema) "openspiel/1")
                   (equal (plist-get (plist-get observation :game) :name) "xiangqi")
                   (stringp (plist-get observation :observation)) t))
  :view #'etaf-xiangqi--view)

(defun etaf-xiangqi-create (&optional seed)
  "Return a session whose one host renders it through `etaf-xiangqi-view'.

SEED is an optional integer.  The session owns the match and its backend
process but mounts no presentation of its own, so a desktop window (or any
other single host) stays the only rendering of this match; `etaf-xiangqi-open'
displays it in its own buffer instead.  Release it with `etaf-gamekit-close'."
  (etaf-gamekit-start etaf-xiangqi-game :display nil
                      :options (list :seed (or seed (random most-positive-fixnum)))))

(defun etaf-xiangqi-open (&optional seed)
  "Display an independent match with optional integer SEED and return its instance."
  (interactive)
  (let* ((session (etaf-xiangqi-create seed))
         (buffer (etaf-gamekit-display session)))
    (with-current-buffer buffer
      (setq-local etaf-xiangqi--session session cursor-type nil mode-line-format nil
                  truncate-lines t
                  buffer-display-table (copy-sequence (or standard-display-table (make-display-table))))
      (set-display-table-slot buffer-display-table 'truncation ?\s))
    (switch-to-buffer buffer)
    (etaf-refit (etaf-runtime-for-buffer buffer) (selected-window))
    session))

(defun etaf-xiangqi-close (&optional instance)
  "Close INSTANCE, or the current Xiangqi instance, without implicit saving."
  (interactive)
  (let ((session (or instance etaf-xiangqi--session)))
    (unless session (user-error "This is not a Xiangqi buffer"))
    (etaf-gamekit-close session)
    (when (buffer-live-p (etaf-gamekit-buffer session))
      (kill-buffer (etaf-gamekit-buffer session)))))

(provide 'etaf-xiangqi-app)
;;; etaf-xiangqi-app.el ends here
