;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit.el --- Framework for games with native ETAF presentation

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.2.4
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0"))
;; Keywords: games

;;; Commentary:
;; Applications define games with their rules, backend configuration and ETAF
;; presentation. GameKit starts independent game instances and owns transport,
;; state publication, actions and lifetime. Backend adapters remain beneath this
;; game-level contract. Game applications are sibling checkouts in the same
;; workspace; requiring the framework does not load them. See docs/manual.md for projects.
;;
;; Error: etaf-gamekit-error
;; Invalid session operation, missing runtime or malformed protocol message.
;; Synchronous rejection sends no input. Asynchronous failure is available
;; through etaf-gamekit-status and etaf-gamekit-last-error.
;;
;; Variable: etaf-gamekit-godot-program
;; Godot 4.7+ executable or PATH command. Defaults to the pinned cache install
;; from native/godot/install-godot.py, which etaf-gamekit-install-godot runs. Set
;; before opening a Godot session.
;;
;; Variable: etaf-gamekit-request-timeout
;; Positive startup/action deadline in seconds (default 15). Timeout fails the
;; connection and retains its latest observation for recovery and inspection.
;;
;; Variable: etaf-gamekit-node-program
;; Node.js 18+ executable or PATH command for boardgame.io (default "node").
;; Install its pinned dependencies with make engine-boardgame-io.
;;
;; Variable: etaf-gamekit-openspiel-python-program
;; Python executable with OpenSpiel installed. Defaults to the isolated cache
;; environment that etaf-gamekit-install-openspiel creates; configure before
;; opening.
;;
;; Function: etaf-gamekit-install-godot (&optional godot)
;;;###autoload (autoload 'etaf-gamekit-install-godot "etaf-gamekit-engines" nil t)
;; Install the pinned Godot runtime that GameKit games run. The packaged setup
;; script verifies the release's SHA-256 before unpacking and writes only under
;; ~/.cache/emacs-taf/game-engines, honouring XDG_CACHE_HOME; it runs no package
;; manager and leaves PATH and init files alone. GODOT registers an existing
;; Godot 4.7 or newer executable instead of downloading the pinned release.
;; Installation runs in the background: progress goes to *ETAF engine install*
;; and the echo area reports the result. One run happens at a time, and a
;; failure keeps an already working runtime in place.
;;
;; Function: etaf-gamekit-install-openspiel (&optional python)
;;;###autoload (autoload 'etaf-gamekit-install-openspiel "etaf-gamekit-engines" nil t)
;; Install the pinned OpenSpiel environment that GameKit games run. PYTHON
;; selects the interpreter of the private cache environment instead of the
;; newest 3.11+ interpreter on PATH. The packaged setup script creates
;; ~/.cache/emacs-taf/game-engines/openspiel, honouring XDG_CACHE_HOME, installs
;; the pinned release and imports it to verify the result; an older environment
;; is replaced only after the new one works, so a failure keeps it in place.
;; Installation runs in the background: progress goes to *ETAF engine install*
;; and the echo area reports the result. One run happens at a time.
;;
;; Macro: etaf-gamekit-define-game (name &rest properties)
;;;###autoload (autoload 'etaf-gamekit-define-game "etaf-gamekit" nil nil 'macro)
;; Define constant NAME as an opaque, inert game definition; return NAME.
;; Evaluated properties are :title (default NAME's spelling), :backend (required
;; registered adapter symbol), :options (JSON-compatible keyword plist), :view
;; and :validate. VIEW receives the running instance and returns an ETAF View;
;; omitted displays game status. VALIDATE receives a detached observation and
;; must return exactly t. Definition starts no process or application mount.
;; Each game's own package keeps its rules, assets, UI and launch command.
;;
;; Function: etaf-gamekit-start (game &key buffer options (display t))
;;;###autoload (autoload 'etaf-gamekit-start "etaf-gamekit" nil nil)
;; Start an independent instance of GAME, a value defined with define-game.
;; Return its opaque session. OPTIONS overrides the game's backend options for
;; this instance without changing the definition. BUFFER is an empty, unmounted
;; buffer or name; omitted creates a fresh buffer named after the game title.
;; DISPLAY mounts the presentation into BUFFER; pass nil when a host window
;; renders this session through GAME's view, so one session is mounted once
;; and its rendering stays independent of every other app window.
;; This function does not select a window. Startup is asynchronous. Invalid
;; configuration signals etaf-gamekit-error before launching; schema rejection,
;; deadline and transport failures are observable through status/last-error.
;; Killing or unmounting the buffer releases the owned process and timers.
;;
;; Function: etaf-gamekit-display (session)
;;;###autoload (autoload 'etaf-gamekit-display "etaf-gamekit-view" nil nil)
;; Mount SESSION's presentation into its own buffer and return that buffer.
;; A session is displayed at most once: a hosted session passes :display nil
;; to `etaf-gamekit-start' and is rendered by exactly one host window instead.
;;
;; Function: etaf-gamekit-game-info (session)
;; Return detached (:name SYMBOL :title STRING :backend SYMBOL) metadata for
;; SESSION's game. Metadata is available during the initial view construction.
;;
;; Function: etaf-gamekit-action (session operation &optional arguments)
;;;###autoload (autoload 'etaf-gamekit-action "etaf-gamekit" nil nil)
;; Send an advertised OPERATION string with keyword-plist ARGUMENTS, returning
;; its increasing request id. Up to eight requests may be outstanding, with
;; acknowledgments accepted in order. Starting, failed/closed, full-queue,
;; unadvertised or unserializable calls signal etaf-gamekit-error.
;; A backend rejection retains the valid state and records last-error. The
;; session returns to ready after all outstanding requests are acknowledged.
;;
;; Function: etaf-gamekit-status (session)
;; Return starting, busy, ready, failed or closed. Reads inside an ETAF View
;; track the coalesced connection display. Ready means a response was accepted,
;; with display publication scheduled within 1/60 second plus rendering time.
;;
;; Function: etaf-gamekit-observation (session)
;; Return a detached copy of the latest accepted backend observation, or nil
;; during startup. It never waits or changes the authoritative backend state.
;;
;; Function: etaf-gamekit-view (session &optional field)
;; Reactively read a detached copy of the coalesced display observation.
;; FIELD, when supplied, is a top-level keyword selecting one field to copy.
;; Use this inside ETAF views/computed values; intermediate streamed frames may
;; be skipped. The caller owns the returned copy, not the backend's state.
;;
;; Function: etaf-gamekit-capabilities (session)
;; Reactively read a detached list of action names advertised by the backend.
;; An action name is not a UI widget; the application's presentation chooses
;; meaningful controls and the game validates every incoming action.
;;
;; Function: etaf-gamekit-last-error (session)
;; Reactively read the latest backend rejection or transport failure, or nil.
;; A successful acknowledged action clears it; unsolicited frames do not.
;; Failed sessions require a new connection.
;;
;; Function: etaf-gamekit-buffer (session)
;; Return the application buffer, which may have been killed.
;;
;; Function: etaf-gamekit-close (session)
;;;###autoload (autoload 'etaf-gamekit-close "etaf-gamekit" nil nil)
;; Idempotently release the session's process, timers and application mount.
;; Preserve its buffer and last observation for inspection. No save is implied.
;;
;; Function: etaf-gamekit-dispose (session)
;;;###autoload (autoload 'etaf-gamekit-dispose "etaf-gamekit" nil nil)
;; Idempotently close SESSION and kill its backing buffer when live.
;; Intended for host close callbacks (such as `etaf-app-define' `:session'
;; `:close') where a hosted session owns no visible Emacs buffer.
;;
;; Function: etaf-gamekit-register-backend (name &key title launch features replace)
;; Backend author API: register symbolic NAME with TITLE and LAUNCH. LAUNCH
;; receives detached game OPTIONS and returns a program/argument string list;
;; GameKit owns starting and stopping that process. FEATURES are descriptive
;; symbols, not active-game permissions or an installation claim. Duplicate
;; names fail unless REPLACE is non-nil. Return NAME. Active games are unaffected.
;;
;; Function: etaf-gamekit-unregister-backend (name)
;; Remove NAME from future discovery and game starts. Return t when it existed,
;; nil otherwise. Active game instances remain owned by their callers.
;;
;; Function: etaf-gamekit-backends ()
;; Return detached adapter descriptions (:name SYMBOL :title STRING :features
;; SYMBOLS), sorted by name. Built-ins are godot, boardgame-io and openspiel.
;; Registration does not install dependencies. Game configuration and adapter
;; installation belong to the workflows documented in docs/manual.md.
;;
;; Component: etaf-gamekit-frame-canvas (&key frame text geometry directory background ref label)
;; Show a native canvas published as per-line image strips, or TEXT.
;; FRAME is a reactive frame description (:id ID :block DEVICE-BLOCK :line
;; DEVICE-LINE :width DEVICE-WIDTH :strips [SERIALS...]) or nil; the producer
;; writes strip ROW of publication SERIAL as ROW-SERIAL.png in DIRECTORY and
;; republishes only changed strips.  GEOMETRY is a reactive plist (:graphic
;; BOOL :density DEVICE-PIXELS-PER-LOGICAL-PIXEL :device-block DEVICE-BLOCK
;; :device-line DEVICE-LINE :pixel-width LOGICAL-WIDTH :columns COLUMNS :rows
;; ROWS :ascent PERCENT); frames show only when :graphic is non-nil and the
;; frame's block, line and width match the geometry.  TEXT is the reactive
;; fallback shown on text displays and before a matching frame arrives.  LABEL
;; names the region and REF is the canvas Host reference.  Only changed rows
;; decode one strip file each, and replaced images are flushed in batches, so
;; a moving scene stays cheap.

;; Component: etaf-playing-card (&key rank suit face-down empty selected disabled on-press label ref columns lines)
;; Parameters:
;; :rank — Optional one-line string of at most 3 display columns; default nil. No tabs/newlines.
;; :suit — spades/hearts/clubs/diamonds/nil; default nil.
;; :face-down, :empty, :selected, :disabled — Optional flags; default nil. Hide face, show pile, mark selection, or disable activation.
;; :on-press — Optional function (); default nil (noninteractive).
;; :label — Optional accessible string; nil derives a safe card/pile name. Never put hidden card information in it.
;; :ref — Optional Host reference; default nil. Addresses the whole card.
;; :columns, :lines — Integer width >= 7 and height >= 1; defaults 9 character columns and 5 text lines. Never stretch with the viewport.
;;
;; Present a controlled playing card or empty pile as one activation target.
;; RANK is a one-line string up to three columns; SUIT is spades, hearts,
;; clubs, diamonds or nil. FACE-DOWN conceals the rank/suit, including the
;; generated accessible label. EMPTY presents a pile placeholder. SELECTED
;; changes paint without changing geometry. COLUMNS defaults to 9 (minimum 7);
;; LINES defaults to 5 (minimum 1); one row exposes just a card's corner in a
;; stack. These intrinsic dimensions never stretch to fill a viewport.
;; ON-PRESS receives no arguments; omitted/disabled cards are noninteractive.
;; LABEL overrides the accessible name and help, so callers must not put
;; hidden information there. Caller owns selection, stacks, moves and rules.
;; Colors use :ui-playing-card-* theme tokens; default faces are warm ivory
;; with contrasting red/black suits. Hover preserves all card text; backs
;; and empty piles derive a subtle tint from their own surface rather than
;; the face-up hover fill. Selected cards suppress hover paint.
;; Invalid rank/suit/dimensions signal
;; etaf-component-call-error. Use (etaf-view (etaf-playing-card :rank "A"
;; :suit 'hearts :on-press (lambda () ...))). No game backend is required.
;;
;;;
;;; Code:
(require 'etaf)
(defconst etaf-gamekit--directory
  (or (catch 'found
        (dolist (file (list (bound-and-true-p byte-compile-current-file)
                            (and load-file-name
                                 (not (string-suffix-p ".eln" load-file-name))
                                 load-file-name)
                            (locate-library "etaf-gamekit")
                            buffer-file-name))
          (when (stringp file)
            (let ((dir (file-name-directory file)))
              (when (and dir
                         (or (file-exists-p (expand-file-name "etaf-gamekit.el" dir))
                             (file-exists-p (expand-file-name "etaf-gamekit.elc" dir))))
                (throw 'found dir))))))
      default-directory))
(defgroup etaf-gamekit nil "Build games with ETAF presentation." :group 'games)
(defcustom etaf-gamekit-godot-program
  (expand-file-name
   "emacs-taf/game-engines/bin/godot"
   (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))
  "Godot executable used by new game sessions."
  :type 'string :group 'etaf-gamekit)
(defcustom etaf-gamekit-request-timeout 15
  "Maximum seconds for a complete adapter response."
  :type 'number :group 'etaf-gamekit)
(defcustom etaf-gamekit-node-program "node"
  "Node.js executable used by the boardgame.io adapter."
  :type 'string :group 'etaf-gamekit)
(defcustom etaf-gamekit-openspiel-python-program
  (expand-file-name "emacs-taf/game-engines/openspiel/bin/python"
                    (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))
  "Python executable with the pinned OpenSpiel package installed."
  :type 'string :group 'etaf-gamekit)
(define-error 'etaf-gamekit-error "ETAF game error")
;; Installed archives compile each module separately, so `lisp' must already be
;; on `load-path' while the byte compiler runs, not only when this entry loads.
;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-gamekit")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-gamekit.el" dir))
                                (file-exists-p (expand-file-name "etaf-gamekit.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
      (add-to-list 'load-path lisp-dir))))
(let* ((lisp-dir (expand-file-name "lisp" etaf-gamekit--directory))
       (load-path (if (file-directory-p lisp-dir)
                      (cons lisp-dir load-path)
                    load-path)))
  (require 'etaf-gamekit-session)
  (require 'etaf-gamekit-backends)
  (require 'etaf-gamekit-engines)
  (require 'etaf-gamekit-game)
  (require 'etaf-gamekit-frame)
  (require 'etaf-gamekit-view)
  (require 'etaf-playing-card))
(provide 'etaf-gamekit)
;;; etaf-gamekit.el ends here
