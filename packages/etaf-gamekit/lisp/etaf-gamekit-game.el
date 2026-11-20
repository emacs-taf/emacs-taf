;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-game.el --- Game definitions and independent running instances

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-gamekit-backends)

(cl-defstruct (etaf-gamekit--game (:constructor etaf-gamekit--game-create))
  name title backend options view validate)

(defun etaf-gamekit--configuration (options)
  "Validate and detach a game's JSON-compatible keyword OPTIONS."
  (unless (and (proper-list-p options) (zerop (% (length options) 2))
               (cl-loop for (key _value) on options by #'cddr always (keywordp key)))
    (signal 'etaf-gamekit-error '("Game options must be a keyword plist")))
  ;; The serialization only validates OPTIONS; its string is not retained.
  (ignore
   (condition-case failure
       (json-serialize (or options (make-hash-table)) :false-object :false)
     (error (signal 'etaf-gamekit-error (list (error-message-string failure))))))
  (etaf-gamekit--copy options))

(cl-defun etaf-gamekit--define-game (name &key title backend options view validate)
  "Create inert NAME with TITLE, BACKEND, OPTIONS, VIEW and VALIDATE."
  (unless (and (symbolp name) name (not (keywordp name))
               (or (null title) (and (stringp title) (not (string-empty-p title))))
               (symbolp backend) backend (not (keywordp backend))
               (or (null view) (functionp view)) (or (null validate) (functionp validate)))
    (signal 'etaf-gamekit-error '("A game needs a symbolic backend, title and callable view/validator")))
  (etaf-gamekit--game-create :name name :title (copy-sequence (or title (symbol-name name)))
                            :backend backend :options (etaf-gamekit--configuration options)
                            :view view :validate validate))

(defmacro etaf-gamekit-define-game (name &rest properties)
  "Define an inert game NAME from evaluated PROPERTIES."
  (declare (indent 1))
  `(defconst ,name (etaf-gamekit--define-game ',name ,@properties)
     "Game definition consumed by `etaf-gamekit-start'."))

(defun etaf-gamekit-game-info (session)
  "Return detached name, title and backend metadata for running game SESSION."
  (etaf-gamekit--copy (etaf-gamekit--session-game-info session)))

(cl-defun etaf-gamekit-start (game &key buffer options (display t))
  "Start an independent instance of GAME in BUFFER, overriding its OPTIONS.
DISPLAY mounts the presentation into BUFFER; pass nil when a host window
renders this session with GAME's view, so the session is mounted once."
  (unless (etaf-gamekit--game-p game)
    (signal 'etaf-gamekit-error '("Start requires a game defined with etaf-gamekit-define-game")))
  (let ((configuration (etaf-gamekit--copy (etaf-gamekit--game-options game)))
        (overrides (etaf-gamekit--configuration options)))
    (cl-loop for (key value) on overrides by #'cddr
             do (setq configuration (plist-put configuration key value)))
    (let* ((backend (etaf-gamekit--game-backend game))
           (command (etaf-gamekit--backend-command backend configuration))
           (info (list :name (etaf-gamekit--game-name game) :title (etaf-gamekit--game-title game)
                       :backend backend)))
      (etaf-gamekit--start command
                           (or buffer (generate-new-buffer-name
                                       (format "*%s*" (etaf-gamekit--game-title game))))
                           (etaf-gamekit--game-view game) (etaf-gamekit--game-validate game)
                           (etaf-gamekit--copy info) display))))

(provide 'etaf-gamekit-game)
;;; etaf-gamekit-game.el ends here
