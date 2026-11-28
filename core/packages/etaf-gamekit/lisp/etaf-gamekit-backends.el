;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-backends.el --- Backend adapters used by game definitions

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-gamekit-session)
(defvar etaf-gamekit--directory)
(defvar etaf-gamekit-godot-program)
(defvar etaf-gamekit-node-program)
(defvar etaf-gamekit-openspiel-python-program)

(defvar etaf-gamekit--backends (make-hash-table :test #'eq))

(defun etaf-gamekit--backend-description (name entry)
  "Return detached public metadata for engine NAME and registry ENTRY."
  (etaf-gamekit--copy
   (list :name name :title (plist-get entry :title) :features (plist-get entry :features))))

(cl-defun etaf-gamekit-register-backend (name &key title launch features replace)
  "Register NAME with TITLE, LAUNCH and FEATURES; optionally REPLACE it."
  (unless (and (symbolp name) name (not (keywordp name))
               (stringp title) (not (string-empty-p title)) (functionp launch)
               (proper-list-p features) (cl-every #'symbolp features))
    (signal 'etaf-gamekit-error '("Engine registration needs a name, title, launch function and feature symbols")))
  (when (and (gethash name etaf-gamekit--backends) (not replace))
    (signal 'etaf-gamekit-error (list (format "Engine already registered: %s" name))))
  (puthash name (list :title (copy-sequence title) :launch launch
                      :features (copy-sequence features)) etaf-gamekit--backends)
  name)

(defun etaf-gamekit-unregister-backend (name)
  "Remove NAME from future discovery and launches, leaving live sessions alone."
  (prog1 (and (gethash name etaf-gamekit--backends) t)
    (remhash name etaf-gamekit--backends)))

(defun etaf-gamekit-backends ()
  "Return detached descriptions of registered runtimes, sorted by name."
  (let (result)
    (maphash (lambda (name entry)
               (push (etaf-gamekit--backend-description name entry) result)) etaf-gamekit--backends)
    (sort result (lambda (left right)
                   (string-lessp (symbol-name (plist-get left :name))
                                 (symbol-name (plist-get right :name)))))))

(defun etaf-gamekit--backend-command (engine options)
  "Build ENGINE's process command for already validated game OPTIONS."
  (let ((entry (gethash engine etaf-gamekit--backends)))
    (unless entry
      (signal 'etaf-gamekit-error (list (format "Unknown engine: %s" engine))))
    (condition-case failure
        (funcall (plist-get entry :launch) (etaf-gamekit--copy options))
      (error (signal 'etaf-gamekit-error
                     (list (format "Backend %s configuration failed: %s" engine (error-message-string failure))))))))

(defun etaf-gamekit--options (options allowed)
  "Reject keys in OPTIONS outside ALLOWED before starting a runtime."
  (cl-loop for (key _value) on options by #'cddr
           unless (memq key allowed)
           do (signal 'etaf-gamekit-error (list (format "Unsupported engine option: %s" key)))))

(defun etaf-gamekit--program (program install)
  "Resolve PROGRAM or explain INSTALL without changing the environment."
  (or (and (stringp program)
           (or (and (file-executable-p program) program) (executable-find program)))
      (signal 'etaf-gamekit-error (list (format "Missing runtime %s; %s" program install)))))

(defun etaf-gamekit--godot-launch (options)
  "Build the Godot command for OPTIONS."
  (etaf-gamekit--options options '(:project))
  (let ((project (plist-get options :project)))
    (unless (and (stringp project) (file-readable-p (expand-file-name "project.godot" project)))
      (signal 'etaf-gamekit-error '("Godot :project must contain project.godot")))
    (list (etaf-gamekit--program etaf-gamekit-godot-program
                                 "install it with M-x etaf-gamekit-install-godot")
          "--headless" "--no-header" "--path" (expand-file-name project)
          "--script" (expand-file-name "native/godot/gamekit.gd" etaf-gamekit--directory))))

(defun etaf-gamekit--boardgame-launch (options)
  "Build a boardgame.io command for a public Game module in OPTIONS."
  (etaf-gamekit--options options '(:game :num-players :player :seed))
  (let ((game (plist-get options :game))
        (count (or (plist-get options :num-players) 2))
        (player (plist-get options :player)) (seed (plist-get options :seed)))
    (unless (and (stringp game) (file-regular-p game) (file-readable-p game)
                 (integerp count) (<= 1 count 100)
                 (or (null player) (and (stringp player) (string-match-p "\\`[0-9]+\\'" player)
                                       (< (string-to-number player) count)))
                 (or (null seed) (stringp seed)))
      (signal 'etaf-gamekit-error '("boardgame.io needs :game, valid :num-players, and optional player/seed strings")))
    (append (list (etaf-gamekit--program etaf-gamekit-node-program "install Node.js 18 or newer")
                  (expand-file-name "native/boardgame-io/bridge.cjs" etaf-gamekit--directory)
                  "--game" (expand-file-name game) "--num-players" (number-to-string count))
            (when player (list "--player" player)) (when seed (list "--seed" seed)))))

(defun etaf-gamekit--openspiel-launch (options)
  "Build an OpenSpiel command for its registered game specification in OPTIONS."
  (etaf-gamekit--options options '(:game :player :seed))
  (let ((game (plist-get options :game)) (player (or (plist-get options :player) 0))
        (seed (or (plist-get options :seed) 0)))
    (unless (and (stringp game) (not (string-empty-p game))
                 (integerp player) (>= player 0) (integerp seed))
      (signal 'etaf-gamekit-error '("OpenSpiel needs a game specification and integer player/seed")))
    (list (etaf-gamekit--program etaf-gamekit-openspiel-python-program
                                 "install it with M-x etaf-gamekit-install-openspiel")
          (expand-file-name "native/openspiel/bridge.py" etaf-gamekit--directory)
          "--game" game "--player" (number-to-string player) "--seed" (number-to-string seed))))

(etaf-gamekit-register-backend 'godot :title "Godot"
 :features '(real-time game-project snapshots) :launch #'etaf-gamekit--godot-launch :replace t)
(etaf-gamekit-register-backend 'boardgame-io :title "boardgame.io"
 :features '(turns phases player-views replay-snapshots) :launch #'etaf-gamekit--boardgame-launch :replace t)
(etaf-gamekit-register-backend 'openspiel :title "OpenSpiel"
 :features '(rule-catalog legal-actions chance simultaneous-actions snapshots undo-redo)
 :launch #'etaf-gamekit--openspiel-launch :replace t)

(provide 'etaf-gamekit-backends)
;;; etaf-gamekit-backends.el ends here
