;;; emacs-gui-verifier.el --- Generic temporal GUI scenario engine -*- lexical-binding: t; -*-

;;; Commentary:

;; This developer tool executes declarative GUI scenarios against any Emacs
;; buffer.  It owns action ordering, checkpoint phases, target-buffer guards,
;; completion, and evidence lifecycle.  It does not know ETAF Runtime, Ebox,
;; Playground, or any concrete example; adapters supply those facts through
;; callbacks and opaque context data.
;;
;; It also ships reusable buffer checks: `etaf-gui-verifier-line-height-assertions'
;; guards the row-height budget that keeps a canvas from clipping, and
;; `etaf-gui-verifier-canvas-filled-p' / `etaf-gui-verifier-canvas-assertion'
;; keep a repaint settled on the window size.
;; `etaf-gui-verifier-native-click' sends one complete native click to an
;; explicitly supplied, visible buffer position without raising a frame.

;;; Code:

(require 'cl-lib)
(require 'json)

(defun etaf-gui-verifier-native-click (position &optional window)
  "Send a native down/up click at explicit POSITION in WINDOW; return t.
WINDOW defaults to the selected window and must be that live graphical
window in a visible frame, displaying the current buffer.  POSITION is an
accessible integer or a live marker in that buffer, never nil.  Reject
invalid, invisible or offscreen targets before sending either event; do not
fall back to point.
The complete click uses one keyboard macro and never raises a frame or
moves the OS pointer.  Callers resolve fresh positions from their own
published targets and verify the resulting application state separately."
  (setq window (or window (selected-window)))
  (unless (and (window-live-p window) (eq window (selected-window))
               (eq (window-buffer window) (current-buffer))
               (display-graphic-p (window-frame window))
               (eq t (frame-visible-p (window-frame window))))
    (error "Native click requires the selected graphical window and current buffer"))
  (unless (and (integer-or-marker-p position)
               (or (integerp position) (eq (marker-buffer position) (current-buffer)))
               (<= (point-min) position) (<= position (point-max)))
    (error "Native click requires an explicit position in the current buffer"))
  (redisplay t)
  (let ((data (posn-at-point position window)))
    (unless (and data (eq (posn-window data) window)
                 (equal (posn-point data) (if (markerp position) (marker-position position) position))
                 (not (invisible-p position))
                 (pos-visible-in-window-p position window))
      (error "Native click target is not visible in the selected window"))
    (execute-kbd-macro (vector (list 'down-mouse-1 data) (list 'mouse-1 data))))
  t)

(defconst etaf-gui-verifier--capture-program
  (expand-file-name "capture-emacs-window.sh"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Window-only capture tool distributed with this engine.")

(cl-defstruct (etaf-gui-verifier-action
               (:constructor etaf-gui-verifier-action-create))
  "One ordered GUI action and its postcondition callback."
  id execute assertions screenshot settled-p
  (settle-timeout 5.0) (settle-interval 0.05))

(cl-defstruct (etaf-gui-verifier-scenario
               (:constructor etaf-gui-verifier-scenario-create))
  "One reusable GUI scenario assembled by an adapter."
  name claim initialize actions invariants adapter completion)

(cl-defstruct (etaf-gui-verifier-context
               (:constructor etaf-gui-verifier--context-create))
  "Mutable execution state owned only by one verifier run."
  scenario target-buffer data (action-count 0) (last-duration-ms 0.0)
  measurements directory started-at (sequence 0))

(defun etaf-gui-verifier--write-json (file value &optional append)
  "Write JSON VALUE to FILE as UTF-8, optionally APPENDing a record."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (insert (decode-coding-string (json-serialize value :null-object nil) 'utf-8-unix) "\n")
      (write-region (point-min) (point-max) file append 'silent))))

(defun etaf-gui-verifier--record (context value)
  "Append evidence VALUE to CONTEXT's manifest."
  (unless (equal (alist-get 'kind value) "run-start")
    (cl-incf (etaf-gui-verifier-context-sequence context))
    (setq value
          (append value
                  `((sequence . ,(etaf-gui-verifier-context-sequence context))
                    (elapsed_ms . ,(* 1000.0
                                     (- (float-time)
                                        (etaf-gui-verifier-context-started-at context))))))))
  (etaf-gui-verifier--write-json
   (expand-file-name "manifest.jsonl" (etaf-gui-verifier-context-directory context))
   value t))

(defun etaf-gui-verifier--result (context status &optional failure)
  "Save CONTEXT's functional STATUS and optional FAILURE atomically.
Visual review and latency certification remain separate from assertions."
  (let* ((directory (etaf-gui-verifier-context-directory context))
         (pending (expand-file-name "result.json.tmp" directory)))
    (etaf-gui-verifier--write-json
     pending
     `((schema . 1) (status . ,status) (error . ,failure)
       (scenario . ,(etaf-gui-verifier-scenario-name
                     (etaf-gui-verifier-context-scenario context)))
       (pid . ,(emacs-pid)) (emacs . ,(emacs-version))
       (action_count . ,(etaf-gui-verifier-context-action-count context))
       (visual_review . "required") (foreground_latency . "not-certified")
       (measurements . ,(vconcat
                         (reverse (etaf-gui-verifier-context-measurements context))))))
    (rename-file pending (expand-file-name "result.json" directory) t)))

(defun etaf-gui-verifier--capture-rectangle ()
  "Return the selected frame's X11 capture rectangle as \"X,Y,W,H\".
The outer position and size describe the window the display server places; on
GTK builds the toolbar and menu bar sit outside `outer-size' and are added back
here.  Return nil when the frame has no X display."
  (let* ((frame (selected-frame))
         (display (frame-parameter frame 'display))
         (geometry (frame-geometry frame))
         (position (or (alist-get 'outer-position geometry)
                       (frame-position frame)))
         (size (alist-get 'outer-size geometry))
         (internal (or (alist-get 'internal-border-width geometry) 0))
         (external (or (alist-get 'external-border-size geometry) '(0 . 0)))
         (toolbar (or (alist-get 'tool-bar-size geometry) '(0 . 0)))
         (menu-lines (or (frame-parameter frame 'menu-bar-lines) 0))
         (x (max 0 (+ (car position) (car external))))
         (y (max 0 (+ (cdr position) (cdr external))))
         (width (+ (or (car-safe size) (frame-pixel-width frame))
                   (* 2 internal) (car external)))
         (height (+ (or (cdr-safe size) (frame-pixel-height frame))
                    (cdr toolbar) (cdr external) (* 2 internal)
                    (if (> menu-lines 0) (* 2 (frame-char-height frame)) 0))))
    (when (and (stringp display) (> (length display) 0))
      (format "%d,%d,%d,%d" x y width height))))


(defun etaf-gui-verifier--capture (context action-id)
  "Capture CONTEXT's selected window for ACTION-ID without activation."
  (let* ((before (etaf-gui-verifier--measurement-state context))
         (facts (cdr before))
         (path (expand-file-name
                (format "frames/%06d-%s.png"
                        (1+ (etaf-gui-verifier-context-sequence context))
                        (replace-regexp-in-string "[^[:alnum:]_-]" "-" action-id))
                (etaf-gui-verifier-context-directory context)))
         (process-environment (copy-sequence process-environment)))
    (unless (and (alist-get 'graphic facts)
                 (alist-get 'target_selected facts)
                 (equal (alist-get 'frame_visible facts) "visible")
                 (= (length (cl-remove-if-not #'display-graphic-p (frame-list))) 1)
                 (not (active-minibuffer-window)))
      (error "Capture requires one visible graphical frame and its selected target"))
    (make-directory (file-name-directory path) t)
    (setenv "ETAF_GUI_CAPTURE_PID" (number-to-string (emacs-pid)))
    (unless (eq system-type 'darwin)
      (let ((rectangle (etaf-gui-verifier--capture-rectangle)))
        (unless rectangle
          (error "Window capture needs a frame with an X display: %s" (selected-frame)))
        (setenv "ETAF_GUI_CAPTURE_GEOMETRY" rectangle)))
    (unless (and (zerop (call-process etaf-gui-verifier--capture-program
                                    nil nil nil "-x" path))
                 (file-regular-p path) (> (file-attribute-size (file-attributes path)) 0))
      (error "Window capture failed: %s" path))
    (unless (equal before (etaf-gui-verifier--measurement-state context))
      (error "GUI target changed during capture: %s" path))
    path))

(defun etaf-gui-verifier-context-put (context key value)
  "Store adapter VALUE for KEY in CONTEXT and return VALUE."
  (setf (alist-get key (etaf-gui-verifier-context-data context)) value)
  value)

(defun etaf-gui-verifier-context-get (context key &optional default)
  "Return CONTEXT adapter value KEY, or DEFAULT when absent."
  (alist-get key (etaf-gui-verifier-context-data context) default))

(defun etaf-gui-verifier--measurement-state (context)
  "Return CONTEXT's live identities followed by JSON-safe GUI facts."
  (let* ((frame (selected-frame))
         (window (selected-window))
         (target (etaf-gui-verifier-context-target-buffer context))
         (selected-buffer (window-buffer window))
         (focus (frame-focus-state frame)))
    (cons
     (list frame window target selected-buffer
           (mapcar (lambda (pane) (list pane (window-buffer pane) (window-pixel-edges pane)))
                   (window-list frame 'no-minibuf)))
     `((graphic . ,(and (display-graphic-p frame) t))
       (focus . ,(cond ((eq focus t) "foreground")
                      ((null focus) "background")
                      (t "unknown")))
       (frame_name . ,(frame-parameter frame 'name))
       (frame_window_id . ,(frame-parameter frame 'window-id))
       (frame_visible . ,(pcase (frame-visible-p frame)
                           ('t "visible") ('icon "icon") (_ "hidden")))
       (target_buffer . ,(and (buffer-live-p target) (buffer-name target)))
       (selected_buffer . ,(buffer-name selected-buffer))
       (target_selected . ,(and (buffer-live-p target)
                               (eq target selected-buffer)))
       (font . ,(format "%s" (frame-parameter frame 'font)))
       (frame_width_px . ,(frame-pixel-width frame))
       (frame_height_px . ,(frame-pixel-height frame))
       (window_edges_px . ,(vconcat (window-pixel-edges window)))
       (window_layout . ,(vconcat
                          (mapcar (lambda (pane)
                                    `((buffer . ,(buffer-name (window-buffer pane)))
                                      (edges_px . ,(vconcat (window-pixel-edges pane)))
                                      (selected . ,(eq pane window))))
                                  (window-list frame 'no-minibuf))))
       (inhibit_quit . ,(and inhibit-quit t))
       (inhibit_redisplay . ,(and inhibit-redisplay t))
       (noninteractive . ,(and noninteractive t))))))

(defun etaf-gui-verifier-measure-action (context action &optional require-foreground)
  "Measure ACTION's execute callback once with CONTEXT; return its exact result.
Retain a JSON-safe measurement in CONTEXT's measurements, newest first,
including failed or quit callbacks, and update the legacy last duration.
Wall/CPU/GC timing covers only the callback, excluding GUI-state snapshots and
the verifier's later checkpoints, redisplay, and settling.  Calls made inside
the callback are included.  No focus or execution bindings change.

With REQUIRE-FOREGROUND, reject a non-graphical, unfocused, unknown, hidden,
or unselected target before invoking the callback.  Rejection retains an
untimed record and clears the legacy duration.  Changes to frame/window/buffer
identities, graphical display, focus, visibility, native window ID, target
selection, font, frame pixel size, or window pixel edges invalidate the record
and, when foreground is required, signal after a successful callback.  Frame
and buffer names and execution bindings are diagnostic observations, not
identity guards.  Callback errors and quits propagate with their original data.
A closing snapshot quit is recorded and propagated after a successful callback,
but never replaces an existing callback error or quit.

Background callbacks are allowed by default and labeled accordingly.  A
valid record requires a successful callback with a live selected target in
an unchanged environment; even a foreground record does not certify
input-to-presentation latency."
  (let* ((before (etaf-gui-verifier--measurement-state context))
         (facts (cdr before))
         (foreground (if (alist-get 'graphic facts)
                         (alist-get 'focus facts)
                       "unknown"))
         (status "rejected")
         started cpu-start gc-start gcs-start result changed snapshot-quit)
    (unwind-protect
        (progn
          (when (and require-foreground
                     (not (and (equal foreground "foreground")
                               (equal (alist-get 'frame_visible facts) "visible")
                               (alist-get 'target_selected facts))))
            (error "GUI action requires a selected foreground target: %s"
                   (etaf-gui-verifier-action-id action)))
          (setq cpu-start (current-cpu-time)
                gc-start gc-elapsed
                gcs-start gcs-done
                started (float-time))
          (condition-case condition
              (progn
                (setq result
                      (funcall (etaf-gui-verifier-action-execute action) context)
                      status "success"))
            ((error quit)
             (setq status (if (eq (car condition) 'quit) "quit" "error"))
             (signal (car condition) (cdr condition)))))
      (let* ((finished (and started (float-time)))
             (cpu-end (and started (current-cpu-time)))
             (gc-end gc-elapsed)
             (gcs-end gcs-done)
             (wall-ms (and started (* 1000.0 (- finished started))))
             ;; Snapshot failure must not replace an action's error or quit.
             (after (and started
                         (condition-case condition
                             (etaf-gui-verifier--measurement-state context)
                           (quit (setq snapshot-quit condition) nil)
                           (error nil)))))
        (setq changed
              (and started
                   (or (not (equal (car before) (car after)))
                       (cl-some
                        (lambda (key)
                          (not (equal (alist-get key facts)
                                      (alist-get key (cdr after)))))
                        '(graphic focus frame_visible frame_window_id
                          target_selected font frame_width_px frame_height_px
                          window_edges_px)))))
        (when (and snapshot-quit (equal status "success"))
          (setq status "quit"))
        (when (and changed require-foreground (equal status "success"))
          (setq status "invalid"))
        (setf (etaf-gui-verifier-context-last-duration-ms context) wall-ms)
        (push
         `((action_id . ,(etaf-gui-verifier-action-id action))
           (boundary . "action.execute callback")
           (presentation_measured . nil)
           (status . ,status)
           (valid . ,(and (equal status "success") (not changed)
                          (alist-get 'target_selected facts)))
           (foreground . ,(if changed "changed" foreground))
           (foreground_required . ,(and require-foreground t))
           (wall_ms . ,wall-ms)
           (cpu_ms . ,(and cpu-end
                           (* 1000.0
                              (- (/ (float (car cpu-end)) (cdr cpu-end))
                                 (/ (float (car cpu-start)) (cdr cpu-start))))))
           (gc_count . ,(and started (- gcs-end gcs-start)))
           (gc_ms . ,(and started (* 1000.0 (- gc-end gc-start))))
           (before . ,facts)
           (after . ,(cdr after)))
         (etaf-gui-verifier-context-measurements context))))
    ;; An action's nonlocal failure bypasses this point and keeps precedence.
    (when snapshot-quit
      (signal (car snapshot-quit) (cdr snapshot-quit)))
    (when (equal status "invalid")
      (error "GUI action environment changed during callback: %s"
             (etaf-gui-verifier-action-id action)))
    result))

(defun etaf-gui-verifier-context-select-buffer (context buffer)
  "Select live BUFFER as CONTEXT's single-window target."
  (unless (buffer-live-p buffer)
    (error "GUI verifier target buffer is not live"))
  (setf (etaf-gui-verifier-context-target-buffer context) buffer)
  (switch-to-buffer buffer)
  (delete-other-windows)
  buffer)

(defun etaf-gui-verifier-assert (name passed &optional detail)
  "Return one normalized assertion NAME for PASSED and optional DETAIL."
  (append (list (cons 'name name) (cons 'passed (and passed t)))
          (when detail (list (cons 'detail detail)))))

(defun etaf-gui-verifier-line-height-assertions (&optional buffer)
  "Return assertions that every line of BUFFER fits the frame line height.
BUFFER defaults to the current buffer and must be displayed in a window,
because only a displayed buffer reports a true `line-pixel-height'.  Emacs
gives a row the pixel height of the tallest font box among its glyphs, so one
symbol that falls back to another font, such as a text-style variation
selector, silently pushes the canvas past the window and clips its bottom
rows.  The assertion detail names every offending line with its height and
text, and a buffer that is not displayed yields no assertions."
  (let ((buffer (or buffer (current-buffer))))
    (when (get-buffer-window buffer)
      (with-current-buffer buffer
        (let ((limit (frame-char-height))
              offending)
          (save-excursion
            (goto-char (point-min))
            (while (not (eobp))
              (let ((height (line-pixel-height)))
                (when (> height limit)
                  (push (format "line %d is %dpx: %s"
                                (line-number-at-pos) height
                                (buffer-substring-no-properties
                                 (line-beginning-position)
                                 (line-end-position)))
                        offending)))
              (forward-line 1)))
          (list (etaf-gui-verifier-assert
                 "no line exceeds the frame line height"
                 (null offending)
                 (when offending
                   (mapconcat #'identity (nreverse offending) "; ")))))))))

(defun etaf-gui-verifier-canvas-filled-p (&optional buffer)
  "Return non-nil when BUFFER's painted canvas fills its window exactly.
The canvas is `window-text-pixel-size' for the whole buffer.  A canvas taller
than the window body hides the bottom rows and a shorter one leaves empty
space; a layout that budgets `(vh 100)' matches exactly once its repaint for
the current size has finished.  A resize action can therefore use this as its
settle predicate.  Return nil when BUFFER is not displayed in a window."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((window (get-buffer-window buffer)))
      (with-current-buffer buffer
        (= (cdr (window-text-pixel-size window))
           (window-body-height window t))))))

(defun etaf-gui-verifier-canvas-assertion (&optional buffer)
  "Return an assertion that BUFFER's painted canvas fills its window.
Use it beside `etaf-gui-verifier-canvas-filled-p', which the same scenario
repeats as its settle predicate.  The detail reports both pixel heights so a
failure names the mismatch."
  (let ((buffer (or buffer (current-buffer))))
    (if-let* ((window (get-buffer-window buffer)))
        (with-current-buffer buffer
          (let ((canvas (cdr (window-text-pixel-size window)))
                (body (window-body-height window t)))
            (etaf-gui-verifier-assert
             "canvas height fits the window" (= canvas body)
             (format "canvas %s vs window %s" canvas body))))
      (etaf-gui-verifier-assert "canvas height fits the window" nil
                                "target buffer is not displayed"))))

(defun etaf-gui-verifier--target-assertions (context)
  "Return generic selected-target assertions for CONTEXT."
  (let ((buffer (etaf-gui-verifier-context-target-buffer context)))
    (list
     (etaf-gui-verifier-assert
      "target-buffer-selected"
      (and (buffer-live-p buffer)
           (eq (window-buffer (selected-window)) buffer))))))

(defun etaf-gui-verifier--scenario-assertions (context)
  "Return generic and adapter assertions for CONTEXT."
  (let* ((scenario (etaf-gui-verifier-context-scenario context))
         (function (etaf-gui-verifier-scenario-invariants scenario)))
    (append
     (etaf-gui-verifier--target-assertions context)
     (and function (funcall function context)))))

(defun etaf-gui-verifier--adapter-data (context)
  "Return generic and adapter JSON data for CONTEXT."
  (let* ((scenario (etaf-gui-verifier-context-scenario context))
         (function (etaf-gui-verifier-scenario-adapter scenario)))
    (append
     (list
      (cons 'scenario (etaf-gui-verifier-scenario-name scenario))
      (cons 'action_count
            (etaf-gui-verifier-context-action-count context))
      (cons 'duration_ms
            (etaf-gui-verifier-context-last-duration-ms context))
      (cons 'last_measurement
            (car (etaf-gui-verifier-context-measurements context))))
     (and function (funcall function context)))))

(defun etaf-gui-verifier--checkpoint
    (context action-id phase screenshot &optional extra)
  "Capture CONTEXT ACTION-ID PHASE with SCREENSHOT and EXTRA assertions."
  (let* ((assertions (append (etaf-gui-verifier--scenario-assertions context) extra))
         (failed (cl-remove-if (lambda (entry) (eq (alist-get 'passed entry) t))
                               assertions))
         (window (selected-window))
         (buffer (window-buffer window))
         (start (window-start window))
         (end (or (window-end window t) start)))
    (etaf-gui-verifier--record
     context
     `((kind . "checkpoint") (action_id . ,action-id) (phase . ,phase)
       (screenshot . ,(and screenshot
                           (etaf-gui-verifier--capture context action-id)))
       (window . ((count . ,(length (window-list nil 'no-minibuf)))
                  (edges_px . ,(vconcat (window-pixel-edges window)))
                  (window-start . ,start) (window-end . ,end)))
       (buffer . ((name . ,(buffer-name buffer))
                  (visible-text-sha256
                   . ,(with-current-buffer buffer
                        (secure-hash 'sha256
                                     (buffer-substring-no-properties start end))))))
       (assertions . ,(vconcat
                       (mapcar (lambda (entry)
                                 (cons (cons 'passed (if (eq (alist-get 'passed entry) t)
                                                        t :false))
                                       (assq-delete-all 'passed (copy-tree entry))))
                               assertions)))
       (adapter . ,(append
                    (etaf-gui-verifier--adapter-data context)
                    `((environment . ,(cdr (etaf-gui-verifier--measurement-state context))))))))
    (when failed
      (error "GUI assertion failed at %s/%s: %s" action-id phase
             (mapconcat (lambda (entry) (alist-get 'name entry)) failed ", ")))))

(defun etaf-gui-verifier--settle-action (context action)
  "Wait until ACTION's visible result is settled in CONTEXT."
  (let ((settled-p (etaf-gui-verifier-action-settled-p action))
        (timeout (etaf-gui-verifier-action-settle-timeout action))
        (interval (etaf-gui-verifier-action-settle-interval action)))
    (unless settled-p
      (error "GUI action has no settle predicate: %s"
             (etaf-gui-verifier-action-id action)))
    (unless (and (numberp timeout) (> timeout 0))
      (error "GUI action settle timeout must be positive: %s"
             (etaf-gui-verifier-action-id action)))
    (unless (and (numberp interval) (> interval 0))
      (error "GUI action settle interval must be positive: %s"
             (etaf-gui-verifier-action-id action)))
    ;; Always complete at least one redisplay before accepting a predicate.
    ;; A predicate proves adapter state, not that Emacs painted that state.
    (redisplay t)
    (sit-for 0)
    (let ((deadline
           (+ (float-time) timeout))
          settled)
      (while (not settled)
        (when (>= (float-time) deadline)
          (error "GUI action did not settle before timeout: %s"
                 (etaf-gui-verifier-action-id action)))
        (if (funcall settled-p context)
            ;; Require the same postcondition across one event/paint turn.
            ;; Runtime state can be synchronous while the GUI compositor still
            ;; presents the preceding frame.
            (progn
              (sit-for interval)
              (redisplay t)
              (setq settled (funcall settled-p context)))
          (sit-for interval)
          (redisplay t))))))

(defun etaf-gui-verifier--run-action (context action)
  "Execute ACTION once inside CONTEXT's ordered checkpoint protocol."
  (let ((action-id (etaf-gui-verifier-action-id action))
        (assertions (etaf-gui-verifier-action-assertions action)))
    (etaf-gui-verifier--checkpoint
     context action-id "before-action" nil)
    (etaf-gui-verifier-measure-action context action)
    (cl-incf (etaf-gui-verifier-context-action-count context))
    (etaf-gui-verifier--checkpoint
     context action-id "after-action" nil)
    (etaf-gui-verifier--settle-action context action)
    (etaf-gui-verifier--checkpoint
     context action-id "after-redisplay"
     (etaf-gui-verifier-action-screenshot action)
     (and assertions (funcall assertions context)))))

;;;###autoload
(defun etaf-gui-verifier-run (scenario run-directory)
  "Execute SCENARIO and save assertions and window evidence to RUN-DIRECTORY.
Use the current Emacs server; do not create frames or change application focus.
RUN-DIRECTORY must not contain a previous manifest or result.  Write a JSONL
manifest and an atomic result.json with functional status, all callback timings
and outstanding visual/latency review requirements.  A failed assertion or
callback records failure and signals.  Screenshots use the distributed macOS
window-only tool; no external skill installation is required.

For long scenarios call this from a timer so the emacsclient request returns
promptly.  The existing scenario settle loop yields to Emacs between actions."
  (unless (etaf-gui-verifier-scenario-p scenario)
    (signal 'wrong-type-argument
            (list 'etaf-gui-verifier-scenario-p scenario)))
  (let* ((directory (file-name-as-directory (expand-file-name run-directory)))
         (context
          (etaf-gui-verifier--context-create
           :scenario scenario :directory directory :started-at (float-time)))
         (initialize (etaf-gui-verifier-scenario-initialize scenario))
         (completion (etaf-gui-verifier-scenario-completion scenario))
         finished-p)
    (dolist (name '("manifest.jsonl" "result.json"))
      (when (file-exists-p (expand-file-name name directory))
        (error "GUI evidence already exists: %s" directory)))
    (make-directory directory t)
    (etaf-gui-verifier--result context "running")
    (etaf-gui-verifier--record
     context
     `((kind . "run-start") (schema_version . 1)
       (run_id . ,(etaf-gui-verifier-scenario-name scenario))
       (claim . ,(etaf-gui-verifier-scenario-claim scenario))
       (required_phases . ["before-action" "after-action" "after-redisplay"])))
    (condition-case error-data
        (progn
          (when initialize (funcall initialize context))
          (dolist (action (etaf-gui-verifier-scenario-actions scenario))
            (etaf-gui-verifier--run-action context action))
          (let ((completed (if completion
                               (funcall completion context)
                             t)))
            (etaf-gui-verifier--record
             context `((kind . "run-end") (completed . ,(if completed t :false))
                       (adapter . ,(etaf-gui-verifier--adapter-data context))))
            (etaf-gui-verifier--result context (if completed "passed" "failed"))
            (setq finished-p t)
            (unless completed
              (error "GUI scenario completion predicate failed")))
          context)
      ((error quit)
       (unless finished-p
         (condition-case finish-error
             (progn
               (etaf-gui-verifier--record
                context `((kind . "run-end") (completed . :false)
                          (adapter . ((error . ,(error-message-string error-data))))))
               (etaf-gui-verifier--result
                context "failed" (error-message-string error-data)))
           (error
            (message "GUI verifier could not record failed completion: %s"
                     (error-message-string finish-error)))))
       (signal (car error-data) (cdr error-data))))))

(provide 'emacs-gui-verifier)
;;; emacs-gui-verifier.el ends here
