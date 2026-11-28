;;; etaf-ncm-gui-scenarios.el --- NCM player GUI acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Drive the shipped NetEase player through its documented keys and its whole
;; size matrix on the shared `emacs-gui-verifier' engine.
;;
;; The player mounts against a scripted client, so a run is deterministic and
;; needs neither the network nor mpv.  The run owns one sized frame and resizes
;; it through the matrix, so every breakpoint (wide, medium, narrow) and a
;; short height are exercised in one pass.  Functional assertions certify
;; behavior; they do not certify appearance: review the captured frames.
;;
;; Run it from an existing graphical Emacs (a server connection is enough):
;;
;;   emacsclient -e '(progn (load "scripts/etaf-ncm-gui-scenarios.el") \
;;                     (etaf-ncm-gui-run "/tmp/ncm-gui-run"))'
;;
;; For a long run, schedule the call from a timer so the client returns; the
;; engine yields to Emacs between actions.  A fresh run directory is required.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'emacs-gui-verifier)
(require 'etaf-ncm)

(etaf-define-component etaf-ncm-gui-embed-region (&key model width)
  "Render MODEL's player inside a region WIDTH characters wide.
The player is embedded here, so its layout must follow the region rather than
the canvas a host paints around it."
  :view (etaf-viewport-region :width (list 'ch (etaf-value width))
          (etaf-ncm-app :model model)))

(etaf-define-component etaf-ncm-gui-embed-canvas (&key model)
  "Render MODEL's player filling its canvas, with no enclosing region."
  :view (etaf-ncm-app :model model))

;;; ---------------------------------------------------------------------------
;;; Scripted backend
;;; ---------------------------------------------------------------------------

(defvar etaf-ncm-gui--requests nil
  "Requests received by the scripted client, newest first.")

(defvar etaf-ncm-gui--status nil
  "Playback status document the scripted client reports.")

(defun etaf-ncm-gui--songs (count)
  "Return COUNT backend songs with deterministic names."
  (cl-loop for index from 1 to count
           collect (list :id index :name (format "曲目 %d" index)
                         :artist (format "歌手 %d" index)
                         :album (format "专辑 %d" (1- index))
                         :ms 180000 :vip (cl-evenp index))))

(defun etaf-ncm-gui--status-document ()
  "Return the playback truth the scripted client reports."
  (or etaf-ncm-gui--status
      (list :ok t :state "playing" :title "曲目 1" :artist "歌手 1"
            :song_id "1" :queue_pos "2/5" :elapsed "42" :duration "180"
            :volume "55" :repeat "false" :shuffle "false" :source "mpv"
            :as_of "2026-01-01T00:00:00+0800")))

(defun etaf-ncm-gui--client (request callback)
  "Answer REQUEST on CALLBACK from canned data, recording it first."
  (push request etaf-ncm-gui--requests)
  (funcall callback
           (list :ok
                 (pcase (plist-get request :op)
                   (:browse (list :count 60 :songs (etaf-ncm-gui--songs 60)))
                   (:search (list :count 3 :songs (etaf-ncm-gui--songs 3)))
                   (:lyric (list :id 1 :lyric
                                 (concat "[00:00.50] 第一行歌词\n"
                                         "[00:05.00] 第二行歌词\n"
                                         "[00:10.25] 第三行歌词\n")))
                   (:session (list :loggedIn t :uid 0 :nick "听众" :vip 0))
                   (:status (etaf-ncm-gui--status-document))
                   (:queue (list :ok t :count "3" :pos "2"
                                 :songs (etaf-ncm-gui--songs 3)))
                   (_ t)))))

(defun etaf-ncm-gui--request (op)
  "Return the newest recorded request whose `:op' is OP."
  (seq-find (lambda (request) (eq (plist-get request :op) op))
            etaf-ncm-gui--requests))

(defun etaf-ncm-gui--clear-requests ()
  "Forget recorded requests so an action observes only its own."
  (setq etaf-ncm-gui--requests nil))

;;; ---------------------------------------------------------------------------
;;; Adapter helpers
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-gui--target (context)
  "Return CONTEXT's player buffer."
  (etaf-gui-verifier-context-target-buffer context))

(defun etaf-ncm-gui--app (context)
  "Return CONTEXT's player session."
  (etaf-gui-verifier-context-get context 'app))

(defun etaf-ncm-gui--state (context)
  "Return CONTEXT's player state snapshot."
  (etaf-ncm-state (etaf-ncm-gui--app context)))

(defun etaf-ncm-gui--key (context keys)
  "Send documented KEYS through CONTEXT's player command loop."
  (with-current-buffer (etaf-ncm-gui--target context)
    (execute-kbd-macro (kbd keys))))

(defun etaf-ncm-gui--text (context)
  "Return CONTEXT's player text without properties."
  (with-current-buffer (etaf-ncm-gui--target context)
    (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-ncm-gui--shows (context text)
  "Return non-nil when CONTEXT's player displays TEXT."
  (string-match-p (regexp-quote text) (etaf-ncm-gui--text context)))

(defun etaf-ncm-gui--assert (name passed &optional detail)
  "Return a verifier assertion NAME for PASSED, with optional DETAIL."
  (etaf-gui-verifier-assert name passed detail))

(defun etaf-ncm-gui--action (id execute assertions &optional screenshot)
  "Build one scenario action ID from EXECUTE and ASSERTIONS.
SCREENSHOT asks the engine for a window capture after the action settles."
  (etaf-gui-verifier-action-create
   :id id :execute execute :screenshot screenshot
   :settled-p (lambda (context) (ignore context) t)
   :assertions assertions))

(defun etaf-ncm-gui--embed-budget (columns)
  "Mount a player in a COLUMNS-wide region and return its state snapshot.
COLUMNS zero mounts the same player with no region, so the two readings differ
only in the region the player is embedded in."
  (let* ((app (etaf-ncm-create :client #'etaf-ncm-gui--client))
         (width (and (> columns 0) (etaf-ref columns)))
         (view (if width
                   (etaf-view (etaf-ncm-gui-embed-region :model app :width width))
                 (etaf-view (etaf-ncm-gui-embed-canvas :model app))))
         (buffer (get-buffer-create (format " *ncm-embed-%s*" columns)))
         (window (selected-window))
         (original (window-buffer window))
         (state nil))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (with-current-buffer buffer
            (etaf-mount (buffer-name buffer) view
                        (list :viewport-width (window-body-width window t)
                              :viewport-height (window-body-height window)))
            (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
            (setq state (etaf-ncm-state app))
            (etaf-unmount)))
      (set-window-buffer window original)
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    state))

(defun etaf-ncm-gui--focused (context)
  "Return the ref of the Host focused in CONTEXT's player."
  (with-current-buffer (etaf-ncm-gui--target context)
    (etaf-focused-host-ref (etaf-runtime-for-buffer (current-buffer)))))

(defun etaf-ncm-gui--tab-walk (context)
  "Press TAB from the focused song list until focus returns; return the refs."
  (with-current-buffer (etaf-ncm-gui--target context)
    (etaf-focus (etaf-runtime-for-buffer (current-buffer)) 'ncm-list))
  (let (walk)
    (catch 'done
      (dotimes (_ 60)
        (etaf-ncm-gui--key context "TAB")
        (let ((ref (etaf-ncm-gui--focused context)))
          (push ref walk)
          (when (eq ref 'ncm-list) (throw 'done nil)))))
    (nreverse walk)))

(defun etaf-ncm-gui--palette (context choice)
  "Open CONTEXT's palette, choose CHOICE, return every listed label."
  (let (names)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (setq names (all-completions "" collection))
                 (or (seq-find (lambda (name) (string-prefix-p choice name)) names)
                     (keyboard-quit)))))
      (with-current-buffer (etaf-ncm-gui--target context)
        (condition-case nil
            (etaf-palette (etaf-runtime-for-buffer (current-buffer)))
          (quit nil))))
    names))

(defun etaf-ncm-gui--press-control (context ref)
  "Activate the bar control REF through ETAF's press dispatch.
A click or RET ends in a `press' dispatch for its Host; dispatching the ref
directly keeps the scenario deterministic when the control's first painted
cell is not point-eligible.  A paint is included so its recorded time is a
background input-to-paint sample."
  (with-current-buffer (etaf-ncm-gui--target context)
    (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
      (etaf-dispatch-event runtime ref 'press)
      (redisplay t))))

(defun etaf-ncm-gui--press-help (context help)
  "Activate the control whose help text is HELP in CONTEXT's player.
A click or RET ends in the same `press' dispatch; the card's tab strip has no
stable ref per tab, so the scenario resolves the tab by the name it shows."
  (with-current-buffer (etaf-ncm-gui--target context)
    (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
           (entry (cl-find-if
                   (lambda (entry) (equal (plist-get (cdr entry) :help-echo) help))
                   (etaf-runtime-host-props-entries runtime))))
      (unless entry
        (error "No control with help text %S in the player" help))
      (etaf-dispatch-event runtime (car entry) 'press)
      (redisplay t))))

(defun etaf-ncm-gui--control-action (id ref op)
  "Build an action pressing bar control REF and asserting backend OP."
  (etaf-ncm-gui--action
   id
   (lambda (context)
     (etaf-ncm-gui--clear-requests)
     (etaf-ncm-gui--press-control context ref))
   (lambda (context)
     (ignore context)
     (list (etaf-ncm-gui--assert (format "bar control %s reaches the backend" ref)
                                 (etaf-ncm-gui--request op))))))

(defun etaf-ncm-gui--panel-action (id ref panel)
  "Build an action pressing bar control REF and asserting aside PANEL."
  (etaf-ncm-gui--action
   id
   (lambda (context)
     (etaf-ncm-gui--press-control context ref))
   (lambda (context)
     (list (etaf-ncm-gui--assert (format "bar control %s shows %s" ref panel)
                                 (eq (plist-get (etaf-ncm-gui--state context) :aside)
                                     panel))))))

;;; ---------------------------------------------------------------------------
;;; The run
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-gui--frame-options (width height)
  "Return frame parameters for a WIDTH x HEIGHT verification frame."
  (list (cons 'name "ncm-gui-acceptance")
        (cons 'width width) (cons 'height height)
        (cons 'fullscreen nil)))

(defun etaf-ncm-gui--resize (width height expected-layout &optional screenshot)
  "Build an action resizing the frame and waiting for EXPECTED-LAYOUT."
  (etaf-gui-verifier-action-create
   :id (format "layout-%s-%dx%d" expected-layout width height)
   :execute (lambda (context)
              (set-frame-size (selected-frame) width height))
   :settled-p (lambda (context)
                (and (= (frame-width) width) (= (frame-height) height)
                     (eq (plist-get (etaf-ncm-gui--state context) :layout)
                         expected-layout)
                     ;; The layout state flips before the canvas repaints; the
                     ;; resize is settled once the painted height matches too.
                     (with-current-buffer (etaf-ncm-gui--target context)
                       (etaf-gui-verifier-canvas-filled-p))))
   :screenshot screenshot
   :assertions
   (lambda (context)
     (let ((state (etaf-ncm-gui--state context)))
       (list
        (etaf-ncm-gui--assert
         (format "layout %s at %dx%d" expected-layout width height)
         (eq (plist-get state :layout) expected-layout))
        (etaf-ncm-gui--assert
         (format "frame is %dx%d" width height)
         (and (= (frame-width) width) (= (frame-height) height)))
        (with-current-buffer (etaf-ncm-gui--target context)
          (etaf-gui-verifier-canvas-assertion)))))))

(defun etaf-ncm-gui-run (directory &optional screenshots)
  "Verify the NetEase player in DIRECTORY, optionally taking SCREENSHOTS.
DIRECTORY must be fresh.  One pass walks every documented key, then the
wide/medium/narrow/short matrix; the run owns its frame and leaves the player
closed."
  (etaf-gui-verifier-run
   (etaf-gui-verifier-scenario-create
    :name "ncm-player"
    :claim "Documented keys, the layout matrix and an embedded region on a scripted backend"
    :invariants
    (lambda (context)
      ;; Row heights stay within the frame line height at every checkpoint,
      ;; on the real frame; the resize actions below also settle on a canvas
      ;; that matches the window, so a clipped bottom bar fails here.
      (with-current-buffer (etaf-ncm-gui--target context)
        (etaf-gui-verifier-line-height-assertions)))
    :initialize
    (lambda (context)
      (ignore-errors (etaf-ncm-close))
      (setq etaf-ncm-gui--requests nil
            etaf-ncm-gui--status nil)
      (let* ((app (etaf-ncm-create :client #'etaf-ncm-gui--client))
             (old (selected-frame))
             (frame (make-frame (etaf-ncm-gui--frame-options 150 40))))
        (select-frame frame)
        (delete-frame old)
        (delete-other-windows)
        (set-frame-size frame 150 40)
        (let* ((display-buffer-overriding-action '((display-buffer-same-window)))
               (buffer (etaf-ncm-open app)))
          (etaf-gui-verifier-context-put context 'app app)
          (etaf-gui-verifier-context-select-buffer context buffer))))
    :actions
    (list
     ;; --- Library and selection -------------------------------------------
     (etaf-ncm-gui--action
      "library-renders"
      (lambda (context) (ignore context))
      (lambda (context)
        (let ((state (etaf-ncm-gui--state context)))
          (list (etaf-ncm-gui--assert "wide layout" (eq (plist-get state :layout) 'wide))
                (etaf-ncm-gui--assert "daily library" (equal (plist-get state :title) "每日推荐"))
                (etaf-ncm-gui--assert "sixty rows loaded" (= (plist-get state :rows-total) 60))
                (etaf-ncm-gui--assert "list renders" (etaf-ncm-gui--shows context "曲目 1")))))
      t)
     (etaf-ncm-gui--action
      "selection-j-k"
      (lambda (context) (etaf-ncm-gui--key context "<down>"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "j selects the second row"
                                    (= (plist-get (etaf-ncm-gui--state context) :selection) 1)))))
     (etaf-ncm-gui--action
      "selection-k-back"
      (lambda (context) (etaf-ncm-gui--key context "<up>"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "k returns to the first row"
                                    (= (plist-get (etaf-ncm-gui--state context) :selection) 0)))))
     (etaf-ncm-gui--action
      "paging-end-home"
      (lambda (context) (etaf-ncm-gui--key context "<end>"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "End selects the last row"
                                    (= (plist-get (etaf-ncm-gui--state context) :selection) 59)))))
     (etaf-ncm-gui--action
      "paging-home"
      (lambda (context) (etaf-ncm-gui--key context "<home>"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "Home selects the first row"
                                    (= (plist-get (etaf-ncm-gui--state context) :selection) 0)))))
     (etaf-ncm-gui--action
      "paging-next-prior"
      (lambda (context) (etaf-ncm-gui--key context "<next>"))
      (lambda (context)
        (let ((size (plist-get (etaf-ncm-gui--state context) :page-size)))
          (list (etaf-ncm-gui--assert "PageDown moves a whole page"
                                      (= (plist-get (etaf-ncm-gui--state context) :selection)
                                         size))))))
     (etaf-ncm-gui--action
      "paging-prior"
      (lambda (context) (etaf-ncm-gui--key context "<prior>"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "PageUp returns to the first page"
                                    (= (plist-get (etaf-ncm-gui--state context) :selection) 0)))))
     (etaf-ncm-gui--action
      "activate-row"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "RET"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "RET plays the selected row"
                                    (or (etaf-ncm-gui--request :play)
                                        (etaf-ncm-gui--request :jump))))))
     ;; --- Transport and playback ------------------------------------------
     (etaf-ncm-gui--action
      "toggle-playback"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "SPC"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "SPC toggles playback"
                                    (etaf-ncm-gui--request :toggle)))))
     (etaf-ncm-gui--action
      "next-track"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "n"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "n switches forward" (etaf-ncm-gui--request :next)))))
     (etaf-ncm-gui--action
      "previous-track"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "p"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "p switches back" (etaf-ncm-gui--request :previous)))))
     (etaf-ncm-gui--action
      "add-to-queue"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "a"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "a appends to the queue" (etaf-ncm-gui--request :add)))))
     (etaf-ncm-gui--action
      "like-and-unlike"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "f"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "f likes the song" (etaf-ncm-gui--request :like)))))
     (etaf-ncm-gui--action
      "unlike"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "F"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "F removes the like" (etaf-ncm-gui--request :unlike)))))
     (etaf-ncm-gui--action
      "repeat-and-shuffle"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "r")
        (etaf-ncm-gui--key context "z"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "r sets repeat" (etaf-ncm-gui--request :repeat))
              (etaf-ncm-gui--assert "z sets shuffle" (etaf-ncm-gui--request :shuffle)))))
     (etaf-ncm-gui--action
      "volume-keys"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "+")
        (etaf-ncm-gui--key context "-"))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "volume keys reach the backend"
                                    (etaf-ncm-gui--request :volume)))))
     (etaf-ncm-gui--action
      "seek-keys"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context ".")
        (etaf-ncm-gui--key context ","))
      (lambda (context)
        (ignore context)
        (list (etaf-ncm-gui--assert "seek keys reach the backend"
                                    (etaf-ncm-gui--request :seek)))))
     ;; --- Bar controls through the native activation path ------------------
     (etaf-ncm-gui--control-action "bar-previous" 'ncm-previous :previous)
     (etaf-ncm-gui--control-action "bar-play" 'ncm-play :toggle)
     (etaf-ncm-gui--control-action "bar-next" 'ncm-next :next)
     (etaf-ncm-gui--control-action "bar-repeat" 'ncm-repeat :repeat)
     (etaf-ncm-gui--control-action "bar-add" 'ncm-plus :add)
     (etaf-ncm-gui--control-action "bar-like" 'ncm-like :like)
     (etaf-ncm-gui--control-action "bar-shuffle" 'ncm-shuffle :shuffle)
     (etaf-ncm-gui--control-action "bar-stop" 'ncm-stop :stop)
     (etaf-ncm-gui--panel-action "bar-queue-panel" 'ncm-queue-aside 'queue)
     (etaf-ncm-gui--panel-action "bar-cover-lyrics" 'ncm-cover 'lyrics)
     (etaf-ncm-gui--panel-action "bar-lyrics-panel" 'ncm-lyrics 'lyrics)
     ;; --- Panes, asides, search, refresh ----------------------------------
     (etaf-ncm-gui--action
      "aside-switches-to-queue"
      (lambda (context) (etaf-ncm-gui--key context "i"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "l switches the aside"
                                    (eq (plist-get (etaf-ncm-gui--state context) :aside) 'queue)))))
     (etaf-ncm-gui--action
      "aside-back-to-lyrics"
      (lambda (context) (etaf-ncm-gui--key context "i"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "l returns to lyrics"
                                    (eq (plist-get (etaf-ncm-gui--state context) :aside) 'lyrics)))))
     (etaf-ncm-gui--action
      "pane-toggle"
      (lambda (context)
        (etaf-gui-verifier-context-put
         context 'pane-before (plist-get (etaf-ncm-gui--state context) :pane))
        (etaf-ncm-gui--key context "v"))
      (lambda (context)
        (let ((before (etaf-gui-verifier-context-get context 'pane-before)))
          (list (etaf-ncm-gui--assert "v switches the pane"
                                      (not (eq (plist-get (etaf-ncm-gui--state context) :pane)
                                               before)))))))
     (etaf-ncm-gui--action
      "pane-toggle-back"
      (lambda (context) (etaf-ncm-gui--key context "v"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "v returns the pane"
                                    (eq (plist-get (etaf-ncm-gui--state context) :pane)
                                        (etaf-gui-verifier-context-get context 'pane-before))))))
     (etaf-ncm-gui--action
      "refresh"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "g"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "g reloads the library"
                                    (etaf-ncm-gui--request :browse))
              (etaf-ncm-gui--assert "library stays rendered"
                                    (etaf-ncm-gui--shows context "曲目 1")))))
     (etaf-ncm-gui--action
      "search"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "/晴天 RET"))
      (lambda (context)
        (let ((request (etaf-ncm-gui--request :search)))
          (list (etaf-ncm-gui--assert "search reaches the backend" request)
                (etaf-ncm-gui--assert "search carries the keyword"
                                      (equal (plist-get request :keyword) "晴天"))))))
     ;; --- Sections, theme, help -------------------------------------------
     (etaf-ncm-gui--action
      "section-key"
      (lambda (context) (etaf-ncm-gui--key context "2"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "2 locates the second library"
                                    (eq (plist-get (etaf-ncm-gui--state context) :section) :fm)))))
     (etaf-ncm-gui--action
      "section-back"
      (lambda (context) (etaf-ncm-gui--key context "1"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "1 returns to the daily library"
                                    (eq (plist-get (etaf-ncm-gui--state context) :section) :daily)))))
     (etaf-ncm-gui--action
      "theme-toggle"
      (lambda (context)
        (etaf-gui-verifier-context-put
         context 'theme-before (plist-get (etaf-ncm-gui--state context) :theme))
        (etaf-ncm-gui--key context "T"))
      (lambda (context)
        (list (etaf-ncm-gui--assert
               "T changes the palette"
               (not (equal (plist-get (etaf-ncm-gui--state context) :theme)
                           (etaf-gui-verifier-context-get context 'theme-before)))))))
     (etaf-ncm-gui--action
      "theme-back"
      (lambda (context) (etaf-ncm-gui--key context "T"))
      (lambda (context)
        (list (etaf-ncm-gui--assert
               "T returns to the first palette"
               (equal (plist-get (etaf-ncm-gui--state context) :theme)
                      (etaf-gui-verifier-context-get context 'theme-before))))))
     (etaf-ncm-gui--action
      "palette"
      (lambda (context)
        (etaf-ncm-gui--clear-requests)
        (etaf-gui-verifier-context-put
         context 'palette (etaf-ncm-gui--palette context "下一首")))
      (lambda (context)
        (let ((names (etaf-gui-verifier-context-get context 'palette)))
          (list (etaf-ncm-gui--assert
                 "? lists the player keys and controls"
                 (cl-every (lambda (label)
                             (seq-find (lambda (name) (string-prefix-p label name))
                                       names))
                           '("下一首" "播放选中行" "音乐库：每日推荐")))
                (etaf-ncm-gui--assert "a palette choice runs its command"
                                      (etaf-ncm-gui--request :next))))))
     (etaf-ncm-gui--action
      "keyboard-tab-walk"
      (lambda (context)
        (etaf-gui-verifier-context-put
         context 'tab-walk (etaf-ncm-gui--tab-walk context)))
      (lambda (context)
        (let ((walk (etaf-gui-verifier-context-get context 'tab-walk)))
          (list (etaf-ncm-gui--assert
                 "Tab reaches every region and returns to the list"
                 (and (eq (car (last walk)) 'ncm-list)
                      (cl-every (lambda (ref) (memq ref walk))
                                '(ncm-seek ncm-volume ncm-lyrics))
                      ;; A group is one stop entered at its remembered member.
                      (cl-some (lambda (ref) (memq ref walk))
                               '(ncm-previous ncm-play ncm-next)))
                 (format "%S" walk)))))
      screenshots)
     (etaf-ncm-gui--action
      "keyboard-transport-arrows"
      (lambda (context)
        (with-current-buffer (etaf-ncm-gui--target context)
          (etaf-focus (etaf-runtime-for-buffer (current-buffer)) 'ncm-play))
        (etaf-ncm-gui--key context "<right>")
        (etaf-gui-verifier-context-put context 'right (etaf-ncm-gui--focused context))
        (etaf-ncm-gui--key context "C-b C-b")
        (etaf-gui-verifier-context-put context 'left (etaf-ncm-gui--focused context))
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "RET"))
      (lambda (context)
        (list (etaf-ncm-gui--assert
               "arrows walk the transport group"
               (and (eq (etaf-gui-verifier-context-get context 'right) 'ncm-next)
                    (eq (etaf-gui-verifier-context-get context 'left) 'ncm-previous)))
              (etaf-ncm-gui--assert "RET presses the focused control"
                                    (etaf-ncm-gui--request :previous))))
      screenshots)
     (etaf-ncm-gui--action
      "keyboard-volume-step"
      (lambda (context)
        (with-current-buffer (etaf-ncm-gui--target context)
          (etaf-focus (etaf-runtime-for-buffer (current-buffer)) 'ncm-volume))
        (etaf-ncm-gui--clear-requests)
        (etaf-ncm-gui--key context "<left>"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "Left steps the focused volume"
                                    (etaf-ncm-gui--request :volume)))))
     (etaf-ncm-gui--action
      "keyboard-back-to-list"
      (lambda (context)
        (with-current-buffer (etaf-ncm-gui--target context)
          (etaf-focus (etaf-runtime-for-buffer (current-buffer)) 'ncm-list))
        (etaf-gui-verifier-context-put
         context 'selection (plist-get (etaf-ncm-gui--state context) :selection))
        (etaf-ncm-gui--key context "<down>"))
      (lambda (context)
        (list (etaf-ncm-gui--assert
               "Down in the focused list moves the selection"
               (= (plist-get (etaf-ncm-gui--state context) :selection)
                  (1+ (etaf-gui-verifier-context-get context 'selection)))))))
     ;; --- Layout matrix ----------------------------------------------------
     (etaf-ncm-gui--resize 90 30 'medium screenshots)
     (etaf-ncm-gui--action
      "compact-pane-tabs"
      (lambda (context) (ignore context))
      (lambda (context)
        (list (etaf-ncm-gui--assert "compact tabs render"
                                    (and (etaf-ncm-gui--shows context "列表")
                                         (etaf-ncm-gui--shows context "歌词")))))
      screenshots)
     (etaf-ncm-gui--action
      "compact-transport-renders"
      (lambda (context) (ignore context))
      (lambda (context)
        (let ((state (etaf-ncm-gui--state context)))
          (list (etaf-ncm-gui--assert "compact page size shrinks"
                                      (< (plist-get state :page-size) 24)))))
      screenshots)
     (etaf-ncm-gui--resize 60 30 'narrow screenshots)
     (etaf-ncm-gui--action
      "narrow-chips-render"
      (lambda (context) (ignore context))
      (lambda (context)
        (list (etaf-ncm-gui--assert "narrow keeps the library list"
                                    (etaf-ncm-gui--shows context "曲目 1"))))
      screenshots)
     (etaf-ncm-gui--action
      "narrow-aside"
      (lambda (context) (etaf-ncm-gui--key context "v"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "narrow can show the lyrics pane"
                                    (etaf-ncm-gui--shows context "歌词"))))
      screenshots)
     (etaf-ncm-gui--action
      "narrow-back-to-list"
      (lambda (context) (etaf-ncm-gui--key context "v"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "narrow returns to the list"
                                    (etaf-ncm-gui--shows context "曲目 1")))))
     ;; --- The small-size card family --------------------------------------
     ;; A card replaces the header, chip strip, panel and bar with one content
     ;; pane, its switch and the transport.  It is entered from a stacked
     ;; layout, so the lyric pane comes to the front.
     (etaf-ncm-gui--resize 46 20 'card screenshots)
     (etaf-ncm-gui--action
      "card-keeps-the-essentials"
      (lambda (context) (ignore context))
      (lambda (context)
        (let ((pane (plist-get (etaf-ncm-gui--state context) :pane)))
          (list (etaf-ncm-gui--assert "the card opens on the lyric pane"
                                      (eq pane 'aside))
                (etaf-ncm-gui--assert "the card shows the pane switch"
                                      (etaf-ncm-gui--shows context "歌词"))
                (etaf-ncm-gui--assert "the card keeps the progress line"
                                      (etaf-ncm-gui--shows context "03:00"))
                (etaf-ncm-gui--assert "the card drops the search field"
                                      (not (etaf-ncm-gui--shows context "搜索歌曲")))
                (etaf-ncm-gui--assert "the card drops the chip strip"
                                      (not (etaf-ncm-gui--shows context "播放全部"))))))
      screenshots)
     (etaf-ncm-gui--action
      "card-switches-to-the-library"
      (lambda (context) (etaf-ncm-gui--key context "v"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "v brings the library into the card"
                                    (etaf-ncm-gui--shows context "曲目 1"))
              (etaf-ncm-gui--assert "the card switch names the two libraries"
                                    (and (etaf-ncm-gui--shows context "收藏")
                                         (etaf-ncm-gui--shows context "推荐")))
              (etaf-ncm-gui--assert "the card switch drops the generic list tab"
                                    (not (etaf-ncm-gui--shows context "列表")))))
      screenshots)
     (etaf-ncm-gui--action
      "card-opens-the-liked-library"
      (lambda (context) (etaf-ncm-gui--press-help context "收藏"))
      (lambda (context)
        (let ((state (etaf-ncm-gui--state context)))
          (list (etaf-ncm-gui--assert "the 收藏 tab loads the liked library"
                                      (eq (plist-get state :section) :liked))
                (etaf-ncm-gui--assert "the liked library lands in the list pane"
                                      (eq (plist-get state :pane) 'list)))))
      screenshots)
     (etaf-ncm-gui--action
      "card-opens-the-recommendation"
      (lambda (context) (etaf-ncm-gui--press-help context "推荐"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "the 推荐 tab loads the daily library"
                                    (eq (plist-get (etaf-ncm-gui--state context) :section)
                                        :daily))))
      screenshots)
     ;; A small frame shows a page, not the library: the wheel and the arrows
     ;; must still reach the rows behind it.
     (etaf-ncm-gui--action
      "card-scrolls-past-the-page"
      (lambda (context)
        (with-current-buffer (etaf-ncm-gui--target context)
          (etaf-focus (etaf-runtime-for-buffer (current-buffer)) 'ncm-list))
        (etaf-gui-verifier-context-put
         context 'card-page (plist-get (etaf-ncm-gui--state context) :page-size))
        (etaf-ncm-gui--key context (mapconcat #'identity (make-list 12 "<down>") " ")))
      (lambda (context)
        (let ((state (etaf-ncm-gui--state context))
              (page (etaf-gui-verifier-context-get context 'card-page)))
          (list (etaf-ncm-gui--assert
                 (format "arrows walk past the %s-row page (selection %s)"
                         page (plist-get state :selection))
                 (> (plist-get state :selection) page))
                (etaf-ncm-gui--assert
                 "the scrolling canvas follows the selection"
                 (with-current-buffer (etaf-ncm-gui--target context)
                   (> (or (etaf-scroll-offset
                           (etaf-runtime-for-buffer (current-buffer))
                           'ncm-list-scroll)
                          0)
                      0))))))
      screenshots)
     (etaf-ncm-gui--resize 34 14 'tile screenshots)
     (etaf-ncm-gui--action
      "tile-keeps-only-the-essentials"
      (lambda (context) (ignore context))
      (lambda (context)
        (list (etaf-ncm-gui--assert "the tile keeps the library"
                                    (etaf-ncm-gui--shows context "曲目 1"))
              (etaf-ncm-gui--assert "the tile drops the switch row"
                                    (not (etaf-ncm-gui--shows context "列表")))
              (etaf-ncm-gui--assert "the tile drops the progress line"
                                    (not (etaf-ncm-gui--shows context "03:00")))
              (etaf-ncm-gui--assert "the tile drops the cover band"
                                    (not (etaf-ncm-gui--shows context "专辑")))))
      screenshots)
     (etaf-ncm-gui--action
      "tile-keys-still-switch-panes"
      (lambda (context) (etaf-ncm-gui--key context "v"))
      (lambda (context)
        (list (etaf-ncm-gui--assert "v shows the lyric in the tile"
                                    (etaf-ncm-gui--shows context "第一行歌词"))))
      screenshots)
     ;; A medium-width frame that is too short for its chrome is a card too.
     (etaf-ncm-gui--resize 90 20 'card screenshots)
     (etaf-ncm-gui--action
      "short-medium-frame-is-a-card"
      (lambda (context) (ignore context))
      (lambda (context)
        (list (etaf-ncm-gui--assert "a short medium frame becomes a card"
                                    (eq (plist-get (etaf-ncm-gui--state context) :layout)
                                        'card))))
      screenshots)
     (etaf-ncm-gui--resize 150 14 'wide screenshots)
     (etaf-ncm-gui--action
      "short-frame-keeps-the-bar"
      (lambda (context) (ignore context))
      (lambda (context)
        (let ((state (etaf-ncm-gui--state context)))
          (list (etaf-ncm-gui--assert "short frame keeps a positive page"
                                      (> (plist-get state :page-size) 0))
                (etaf-ncm-gui--assert "short frame keeps the player bar"
                                      (etaf-ncm-gui--shows context "00:42"))
                (etaf-ncm-gui--assert "short frame keeps the player tools"
                                      (etaf-ncm-gui--shows context "55%")))))
      screenshots)
     ;; The embedded region check isolates width: the frame is tall enough that
     ;; only the region, not its rows, decides the tier.
     (etaf-ncm-gui--resize 150 40 'wide)
     ;; --- Embedded region ---------------------------------------------------
     ;; A host that embeds the player gives it a region, not the canvas.  Both
     ;; readings below come from the same player code: only the enclosing
     ;; region differs, so an embedded player that laid out for the canvas
     ;; would report the canvas width here as well.
     ;; --- Embedded region ---------------------------------------------------
     ;; A host that embeds the player gives it a region, not the canvas.  The
     ;; 60-column region sits below the medium breakpoint while the canvas of
     ;; the 150-column frame sits above the wide one, so a player that read the
     ;; canvas would report `wide' in both readings.
     (etaf-ncm-gui--action
      "embed-region-follows-the-region"
      (lambda (context)
        (ignore context)
        (etaf-gui-verifier-context-put
         context 'region-state (etaf-ncm-gui--embed-budget 60)))
      (lambda (context)
        (let ((state (etaf-gui-verifier-context-get context 'region-state)))
          (list
           (etaf-ncm-gui--assert
            (format "a 60-column region lays out narrow (got %s, %s rows a page)"
                    (plist-get state :layout) (plist-get state :page-size))
            (eq (plist-get state :layout) 'narrow))
           (etaf-ncm-gui--assert
            "the embedded player still loads the library"
            (> (or (plist-get state :rows-total) 0) 0))))))
     (etaf-ncm-gui--action
      "embed-canvas-fills-the-canvas"
      (lambda (context)
        (ignore context)
        (etaf-gui-verifier-context-put
         context 'canvas-state (etaf-ncm-gui--embed-budget 0)))
      (lambda (context)
        (let ((state (etaf-gui-verifier-context-get context 'canvas-state)))
          (list
           (etaf-ncm-gui--assert
            (format "the same player without a region lays out wide (got %s)"
                    (plist-get state :layout))
            (eq (plist-get state :layout) 'wide))))))
     (etaf-ncm-gui--resize 150 40 'wide screenshots))
    :completion
    (lambda (context)
      (etaf-ncm-gui--key context "q")
      (not (get-buffer "*ETAF 网易云音乐*"))))
   directory))

(provide 'etaf-ncm-gui-scenarios)
;;; etaf-ncm-gui-scenarios.el ends here
