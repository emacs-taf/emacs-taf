;;; -*- lexical-binding: t; -*-
;;; etaf-solitaire-app.el --- Standalone game definition and lifetime

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-gamekit)
(require 'etaf-solitaire-views)

(defvar-local etaf-solitaire--session nil)

(etaf-gamekit-define-game etaf-solitaire-game
  :title "Verdant · 纸牌接龙" :backend 'openspiel
  :options '(:game "solitaire(depth_limit=600)" :player 0 :seed 11)
  :validate (lambda (observation)
              (and (equal (plist-get observation :schema) "openspiel/1")
                   (equal (plist-get (plist-get observation :game) :name) "solitaire")
                   (stringp (plist-get observation :observation)) t))
  :view #'etaf-solitaire--view)

(defun etaf-solitaire-create (&optional seed)
  "Return a session whose single host renders it through `etaf-solitaire-view'.

SEED is an optional integer.  The session owns the deal and its backend
process but mounts no presentation of its own, so one host window (or
`etaf-solitaire-open') is the only rendering.  Release it with
`etaf-gamekit-close'."
  (etaf-gamekit-start etaf-solitaire-game :display nil
                      :options (list :seed (or seed (random most-positive-fixnum)))))

(defun etaf-solitaire-open (&optional seed)
  "Display an independent deal with optional integer SEED and return its instance."
  (interactive)
  (let* ((session (etaf-solitaire-create seed))
         (buffer (etaf-gamekit-display session)))
    (with-current-buffer buffer
      (setq-local etaf-solitaire--session session
                  buffer-display-table (copy-sequence (or standard-display-table (make-display-table))))
      (set-display-table-slot buffer-display-table 'truncation ?\s))
    (switch-to-buffer buffer)
    (etaf-refit (etaf-runtime-for-buffer buffer) (selected-window))
    session))

(defun etaf-solitaire-close (&optional instance)
  "Close INSTANCE, or the current Solitaire instance, without implicit saving."
  (interactive)
  (let ((session (or instance etaf-solitaire--session)))
    (unless session (user-error "This is not a Solitaire buffer"))
    (etaf-gamekit-close session)
    (when (buffer-live-p (etaf-gamekit-buffer session))
      (kill-buffer (etaf-gamekit-buffer session)))))

(provide 'etaf-solitaire-app)
;;; etaf-solitaire-app.el ends here
