;;; ebox-interaction.el --- Keymaps, focus, pointer input and scrolling -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Interaction capabilities live on retained nodes.  Composition copies the
;; lines of an interactive node and fills absent `ebox-node', `keymap',
;; `help-echo', `pointer' and `mouse-face' properties, so the innermost node
;; wins, an explicit nil blocks inheritance, and an ancestor's keymap reaches
;; descendants without their own.
;; Focus and the held pointer target are mount state; they surface as the
;; derived selector states focus and active, and :disabled t derives disabled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mwheel)
(require 'ebox-node)
(require 'ebox-layout)
(require 'ebox-buffer)

(define-error 'ebox-input-cancelled "Ebox input target is no longer available" 'quit)

;;;; Derived states

(defun ebox--interaction-states (node)
  "Return NODE's interaction-derived selector states."
  (let ((mount ebox--current-mount) states)
    (when (plist-get (ebox-node-inter node) :disabled) (push "disabled" states))
    (when mount
      (when (eq node (ebox-mount-active mount)) (push "active" states))
      (when (eq node (ebox-mount-focus mount)) (push "focus" states)))
    states))

(setq ebox--derived-states-function #'ebox--interaction-states)

;;;; Text properties of interactive nodes

(defun ebox--face-plist (face)
  "Return FACE, a plist or a list of plists, as one plist."
  (cond ((null face) nil)
        ((keywordp (car-safe face)) face)
        (t (apply #'append (delq nil face)))))

(defun ebox--hover-face (node value)
  "Return the native mouse face for NODE with :hover-style VALUE.
Emacs displays `mouse-face' instead of the text's `face' while the pointer is
over the node, so a hover face carrying only VALUE would drop everything else
NODE paints; a background-only hover style would then lose the label colour and
the text would fall back to the frame's default face.  Start from NODE's
computed face, apply VALUE over it, and intern the result so equal rows share
one face object."
  (unless (and (proper-list-p value) (zerop (% (length value) 2)))
    (signal 'ebox-error (list "Ebox :hover-style must be an even plist" value)))
  (let* ((cs (ebox-node-cs node))
         ;; `plist-put' mutates, and the resting face is interned and shared.
         (face (copy-sequence (ebox--face-plist (and cs (ebox-cs-face cs))))))
    (cl-loop for (key val) on value by #'cddr do
             (unless (memq key ebox--hover-properties)
               (signal 'ebox-error (list "Ebox :hover-style does not support" key)))
             (pcase key
               (:color (setq face (plist-put face :foreground val)))
               (:background-color (setq face (plist-put face :background val)))
               (:font-weight (setq face (plist-put face :weight (ebox--emacs-weight
                                                                 (ebox--css-weight val 400)))))
               (:font-style (setq face (plist-put face :slant val)))
               (:text-decoration-line
                (pcase val
                  ('underline (setq face (plist-put face :underline t)))
                  ('line-through (setq face (plist-put face :strike-through t)))
                  ('overline (setq face (plist-put face :overline t)))
                  ('none (setq face (append face '(:underline nil :overline nil
                                                   :strike-through nil))))))
               (:text-decoration-color
                (when (eq (plist-get face :underline) t)
                  (setq face (plist-put face :underline
                                        (list :color (if (eq val 'currentColor)
                                                         'foreground-color val))))))))
    (ebox--intern-face face)))

(defvar ebox--empty-keymap (make-sparse-keymap)
  "Keymap that blocks an ancestor's keymap on explicit nil.")

(defun ebox--inter-text-properties (node)
  "Return text properties painting NODE's interaction capabilities."
  ;; Keep hover-face identity stable across rows, but let NODE own the cache.
  ;; Authored property replacement clears it even when a hidden node does not
  ;; compose another line, so retired callbacks do not outlive their owner.
  (or (ebox-node-inter-cache node)
      (let ((inter (ebox-node-inter node))
            (props (list 'ebox-node node)))
        (when (plist-member inter :keymap)
          (setq props (append props
                              (list 'keymap
                                    (if (plist-get inter :disabled) ebox--empty-keymap
                                      (or (plist-get inter :keymap) ebox--empty-keymap))))))
        (when (and (plist-get inter :disabled) (not (plist-member inter :keymap)))
          (setq props (append props (list 'keymap ebox--empty-keymap))))
        ;; An explicit nil is painted too, so it blocks an ancestor's value.
        (when (plist-member inter :help-echo)
          (setq props (append props (list 'help-echo (plist-get inter :help-echo)))))
        (when (plist-member inter :pointer)
          (setq props (append props (list 'pointer (plist-get inter :pointer)))))
        (when (plist-member inter :hover-style)
          (setq props (append props (list 'mouse-face
                                          (and (plist-get inter :hover-style)
                                               (ebox--hover-face
                                                node
                                                (plist-get inter :hover-style)))))))
        (setf (ebox-node-inter-cache node) props))))

(defconst ebox--help-absent (make-symbol "ebox-help-absent")
  "`ebox-help-echo' marker for a probe run with no help of its own.
A later ancestor help fill replaces it; an explicit nil or an inner value
still blocks the ancestor.")

(defun ebox--fill-property (string property value)
  "Put PROPERTY VALUE on the parts of STRING where it is absent.
A present nil, painted by an inner node, keeps blocking VALUE."
  (let ((pos 0) (len (length string)))
    (while (< pos len)
      (let ((next (or (next-property-change pos string len) len)))
        (unless (plist-member (text-properties-at pos string) property)
          (put-text-property pos next property value string))
        (setq pos next)))))

(defun ebox--fill-help (string value)
  "Fill STRING's `help-echo' with VALUE, composing painted hover probes.
A probe records its run's original help in `ebox-help-echo'.  When that run
had no help of its own, the ancestor's VALUE becomes the original; an
explicit nil or an inner node's help still blocks it."
  (let ((pos 0) (len (length string)))
    (while (< pos len)
      (let* ((next (min (or (next-single-property-change pos 'help-echo string len)
                            len)
                        (or (next-single-property-change
                             pos 'ebox-help-echo string len)
                            len)))
             (props (text-properties-at pos string)))
        (cond
         ((not (eq (plist-get props 'help-echo) #'ebox--hover-help))
          (unless (plist-member props 'help-echo)
            (put-text-property pos next 'help-echo value string)))
         ((eq (plist-get props 'ebox-help-echo) ebox--help-absent)
          (put-text-property pos next 'ebox-help-echo value string)))
        (setq pos next)))))

(defun ebox--decorate-interactive (node line &optional fresh)
  "Return LINE carrying NODE's interaction properties.
LINE is copied first unless FRESH says the caller owns it.  A hidden node
paints nothing, so it carries no interaction feedback either."
  (let* ((hidden (ebox--hidden-p node))
         (inter (ebox-node-inter node))
         (props (and (not hidden) (ebox--inter-text-properties node)))
         (copy (if fresh line (copy-sequence line)))
         (hover-style (and (not hidden) (plist-get inter :hover-style)))
         (hover-content (and (not hidden) (plist-get inter :hover-content))))
    (while props
      (if (eq (car props) 'help-echo)
          (ebox--fill-help copy (cadr props))
        (ebox--fill-property copy (car props) (cadr props)))
      (setq props (cddr props)))
    (when (and ebox--current-mount (or hover-style hover-content))
      ;; Pointer feedback needs the pointer's node.  A painted help-echo
      ;; probe reports entry and a short guard follows it, so no buffer
      ;; enables `track-mouse' and motion over another window never becomes
      ;; a command here.
      (setf (ebox-mount-hover-p ebox--current-mount) t)
      (ebox--fill-hover-help copy (not hover-content)))
    copy))

(defun ebox--hover-help (window object position)
  "Report pointer entry at POSITION and return the painted help text.
Painted as `help-echo' on hover targets.  Emacs calls it on pointer movement
without `track-mouse', so entering a mounted buffer paints hover and starts the
pointer guard; returning the run's original help keeps echo-area and tooltip
output unchanged."
  (let ((original (and (integer-or-marker-p position)
                       (or (bufferp object) (stringp object))
                       (get-text-property position 'ebox-help-echo object))))
    (when (eq original ebox--help-absent) (setq original nil))
    (when (and (bufferp object) (integer-or-marker-p position))
      (with-current-buffer object
        (ebox--pointer-enter window position)
        (unless (equal original ebox--pointer-help)
          ;; `show_help_echo' stops at a function returning nil, so clear a
          ;; help it already shows the way a plain nil property would.
          (when (and (null original) ebox--pointer-help
                     (functionp show-help-function))
            (funcall show-help-function nil))
          (setq-local ebox--pointer-help original))))
    (if (functionp original)
        (funcall original window object position)
      original)))

(defun ebox--fill-hover-help (string mouse-face-only)
  "Give STRING a `help-echo' probe that reports pointer entry.
MOUSE-FACE-ONLY non-nil installs it only on runs carrying `mouse-face', so an
explicit nil hover blocker keeps its help value and paints no feedback.  Each
run's original help is kept in `ebox-help-echo' for the probe to return."
  (let ((pos 0) (len (length string)))
    (while (< pos len)
      (let* ((next (or (next-single-property-change pos 'help-echo string len)
                       len))
             (props (text-properties-at pos string)))
        (when (or (not mouse-face-only) (plist-get props 'mouse-face))
          (unless (plist-member props 'ebox-help-echo)
            (put-text-property pos next 'ebox-help-echo
                               (if (plist-member props 'help-echo)
                                   (plist-get props 'help-echo)
                                 ebox--help-absent)
                               string))
          (put-text-property pos next 'help-echo #'ebox--hover-help string))
        (setq pos next)))))

(setq ebox--decorate-function #'ebox--decorate-interactive)

;;;; Liveness

(defun ebox--node-live-p (node mount)
  "Return non-nil when NODE is laid out under MOUNT's root.
A text node has no box of its own; it is live when its parent is."
  (and node mount
       (ebox-node-layout (if (ebox-node-text-p node)
                             (ebox-node-parent node)
                           node))
       (eq (ebox-node-root node) (ebox-mount-root mount))
       (buffer-live-p (ebox-mount-buffer mount))))

(defun ebox--node-enabled-p (node)
  "Return non-nil unless NODE or an ancestor is disabled."
  (let ((ok t))
    (while (and ok node)
      (when (plist-get (ebox-node-inter node) :disabled) (setq ok nil))
      (setq node (ebox-node-parent node)))
    ok))

(defun ebox--mount-for (buffer-or-name)
  "Return the mount of BUFFER-OR-NAME or signal `user-error'."
  (or (ebox-buffer-mount buffer-or-name)
      (user-error "No mounted Ebox tree in %s"
                  (if buffer-or-name buffer-or-name (buffer-name)))))

(defun ebox--set-mount-state (mount slot node)
  "Set MOUNT's interaction SLOT (focus or active) to NODE and restyle."
  (let ((old (if (eq slot 'focus) (ebox-mount-focus mount) (ebox-mount-active mount))))
    (unless (eq old node)
      (if (eq slot 'focus)
          (setf (ebox-mount-focus mount) node)
        (setf (ebox-mount-active mount) node))
      (ebox-with-batch
        (when (ebox--node-live-p old mount) (ebox-node-restyle old))
        (when node (ebox-node-restyle node))))))

;;;; Keymaps

(defvar ebox--dispatching-activation nil
  "Non-nil while invoking a target already selected by Ebox activation.")

(defun ebox--declared-keymap (node)
  "Return the keymap NODE uses, inherited from its nearest declaring ancestor."
  (let (found done)
    (while (and node (not done))
      (let ((inter (ebox-node-inter node)))
        (cond
         ((plist-get inter :disabled) (setq done t))
         ((plist-member inter :keymap)
          (setq found (plist-get inter :keymap) done t))))
      (setq node (ebox-node-parent node)))
    found))

(defun ebox--keymap-owner (node)
  "Return NODE's nearest ancestor-or-self declaring a non-nil keymap."
  (let (found done)
    (while (and node (not done))
      (let ((inter (ebox-node-inter node)))
        (when (plist-member inter :keymap)
          (setq done t)
          (when (and (plist-get inter :keymap) (not (plist-get inter :disabled)))
            (setq found node))))
      (setq node (ebox-node-parent node)))
    found))

(defun ebox--focused-at-point ()
  "Return the focused node when point is at its first painted character."
  (let* ((mount ebox--buffer-mount)
         (focus (and mount (ebox-mount-focus mount))))
    (when (and (ebox--node-live-p focus mount)
               (eql (point) (ebox-node-position focus)))
      focus)))

(defun ebox--focus-around-point ()
  "Return the focused node when point lies inside its painted subtree."
  (let* ((mount ebox--buffer-mount)
         (focus (and mount (ebox-mount-focus mount)))
         (here (and (ebox--node-live-p focus mount) (ebox-node-at))))
    (and here (ebox-node-ancestor-p focus here) focus)))

(defun ebox--focused-key (focus)
  "Run the key just typed for FOCUS instead of the node under point.
FOCUS's own keymap answers first; without a binding there, the key reaches
the buffer's other active maps as if no node keymap covered point.  A call
without a key event, such as `call-interactively', is an activation (RET)."
  (let* ((keys (this-command-keys-vector))
         (keys (if (> (length keys) 0) keys (kbd "RET")))
         (map (ebox--declared-keymap focus))
         (own (and (keymapp map) (lookup-key map keys)))
         (beneath (lambda ()
                    (let ((covering (list (get-char-property (point) 'keymap)
                                          (get-char-property (point) 'local-map))))
                      (lookup-key (cl-remove-if (lambda (m) (memq m covering))
                                                (current-active-maps t))
                                  keys)))))
    (cond
     ((commandp own)
      (let ((last-input-event (aref keys (1- (length keys))))
            (ebox--dispatching-activation t))
        (command-execute own)))
     ((commandp (setq own (funcall beneath)))
      (command-execute own))
     (t (user-error "%s is undefined for the focused node"
                    (key-description keys))))))

(defun ebox--command (callback &optional activation-p)
  "Wrap CALLBACK as a command; ACTIVATION-P uses logical focus.
A keyboard activation typed while point lies inside the focused node belongs
to that node, even when point rests on a clickable descendant."
  (lambda (&optional event)
    (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
    (if (null event)
        (let ((focus (and activation-p (not ebox--dispatching-activation)
                          (ebox--focus-around-point))))
          (if focus (ebox--focused-key focus) (funcall callback)))
      (let* ((position (event-start event))
             (window (posn-window position)))
        (unless (and (window-live-p window) (null (posn-area position)))
          (user-error "Ebox activation requires a live text window"))
        (with-current-buffer (window-buffer window)
          (funcall callback))))))

(defconst ebox--claimed-mouse-events
  (append '(mouse-1 double-mouse-1 triple-mouse-1
            down-mouse-1 double-down-mouse-1 triple-down-mouse-1
            drag-mouse-1 double-drag-mouse-1 triple-drag-mouse-1)
          (cl-loop for modifier in '(shift control meta super hyper)
                   append (mapcar (lambda (base) (event-convert-list (list modifier base)))
                                  '(down-mouse-1 mouse-1 drag-mouse-1))))
  "Primary-button events an activatable or draggable owner claims.")

(defun ebox--press-command (press)
  "Track primary-button PRESS on an activatable owner."
  (interactive (list last-input-event))
  (ebox--track-press press))

(defconst ebox--press-claim-keymap
  (let ((map (make-sparse-keymap)))
    (dolist (event ebox--claimed-mouse-events)
      (define-key map (vector event)
                  (if (memq 'down (event-modifiers event)) #'ebox--press-command #'ignore)))
    map)
  "Shared parent claiming the primary-button sequence for press-only keymaps.
Presses neither start region selection nor reach global commands.")

(defconst ebox--activation-keys '([13] [return] [32] [mouse-1])
  "Keys an :activate callback receives when the keymap has no :drag.")

(defun ebox-keymap-create (&rest options)
  "Create a native keymap from OPTIONS.
:activate is a zero-argument callback for RET, return, SPC and the primary
mouse button; :bindings is an alist of key descriptions or vectors paired with
zero-argument callbacks; :drag is a one-argument gesture callback and
:drag-lock-modifier names a modifier that keeps the gesture alive after
release.  :drag-edge non-nil reports an `edge' phase while a drag rests in or
past the window's edge band; the callback owns any scrolling.  See the Ebox
Commentary for the gesture protocol."
  (unless (and (proper-list-p options) (zerop (% (length options) 2)))
    (error "Ebox keymap options must be an even plist"))
  (let ((map (make-sparse-keymap)) seen keys)
    (cl-loop for (key _value) on options by #'cddr do
             (unless (memq key '(:activate :bindings :drag :drag-lock-modifier
                                 :drag-edge))
               (error "Unknown Ebox keymap option: %S" key))
             (when (memq key seen)
               (error "Repeated Ebox keymap option: %S" key))
             (push key seen))
    (let ((activate (plist-get options :activate))
          (drag (plist-get options :drag))
          (lock (plist-get options :drag-lock-modifier))
          (edge (plist-get options :drag-edge))
          (bindings (plist-get options :bindings)))
      (when (and lock (not (memq lock '(shift control meta super hyper))))
        (error "Ebox :drag-lock-modifier must be a supported modifier: %S" lock))
      (when (and lock (not drag))
        (error "Ebox :drag-lock-modifier requires :drag"))
      (when (and drag (not (functionp drag)))
        (error "Ebox :drag callback must accept one gesture argument"))
      (unless (proper-list-p bindings)
        (error "Ebox keymap :bindings must be an alist"))
      (when activate
        (let ((command (ebox--command activate t)))
          (dolist (key (if drag (butlast ebox--activation-keys) ebox--activation-keys))
            (define-key map key command)
            (push key keys))
          (unless drag
            (define-key map [double-mouse-1] command)
            (define-key map [triple-mouse-1] command)
            (set-keymap-parent map ebox--press-claim-keymap))))
      (dolist (entry bindings)
        (unless (and (consp entry) (functionp (cdr entry)))
          (error "Ebox keymap bindings require a key and a callback"))
        (let ((key (car entry)) (callback (cdr entry)))
          (unless (or (stringp key) (vectorp key))
            (error "Ebox keymap keys must be strings or vectors"))
          (unless (or (autoloadp (indirect-function callback))
                      (zerop (car (func-arity callback))))
            (error "Ebox keymap callbacks must accept zero arguments"))
          (setq key (vconcat (kbd (if (stringp key) key (key-description key)))))
          (when (zerop (length key))
            (error "Ebox keymap keys must not be empty"))
          (when (cl-some (lambda (other)
                           (let ((n (min (length key) (length other))))
                             (equal (cl-subseq key 0 n) (cl-subseq other 0 n))))
                         keys)
            (error "Ebox keymap binding overlaps an existing key: %s"
                   (key-description key)))
          (define-key map key (ebox--command callback))
          (push key keys)))
      (when drag
        ;; Claim the whole primary-button sequence so presses do not start
        ;; region selection and modifier presses do not reach global commands.
        (let ((track (lambda (press)
                       (interactive (list last-input-event))
                       (ebox--track-drag
                        press drag nil
                        (and lock (memq lock (event-modifiers press)))
                        edge))))
          (dolist (event ebox--claimed-mouse-events)
            (unless (lookup-key map (vector event))
              (define-key map (vector event)
                          (if (memq 'down (event-modifiers event)) track #'ignore)))))))
    map))

(defun ebox-help-create (function)
  "Adapt zero-argument FUNCTION to a native `help-echo' callback.
The help object's buffer becomes current while FUNCTION runs; it must return
a string or nil."
  (unless (and (functionp function)
               (or (autoloadp (indirect-function function))
                   (zerop (car (func-arity function)))))
    (error "Ebox help requires a zero-argument function"))
  (lambda (window object _position)
    (let ((buffer (cond ((bufferp object) object)
                        ((overlayp object) (overlay-buffer object))
                        ((and (stringp object) (window-live-p window))
                         (window-buffer window)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((value (funcall function)))
            (unless (or (null value) (stringp value))
              (error "Ebox help function must return a string or nil"))
            value))))))

;;;; Activation

(defun ebox-activate (&optional position noerror)
  "Invoke the RET binding of the node at POSITION, defaulting to point.
With nil POSITION, the focused node wins while point is at its first painted
character.  Signal `user-error' when there is no command, or return nil when
NOERROR is non-nil."
  (interactive)
  (let* ((focused (and (null position) (ebox--focused-at-point)))
         (position (or position (point)))
         (map (cond
               (focused (ebox--declared-keymap focused))
               ((and (integer-or-marker-p position)
                     (<= (point-min) position) (< position (point-max))
                     (not (eq (char-after position) ?\n)))
                (get-text-property position 'keymap))))
         (command (and (keymapp map) (lookup-key map (kbd "RET")))))
    (if (commandp command)
        (let ((last-input-event ?\r)
              (ebox--dispatching-activation t))
          (command-execute command))
      (unless noerror (user-error "No Ebox RET command at position")))))

;;;; Pointer gestures

(defvar ebox--drag-active nil
  "Non-nil inside the primary-button tracking loop.")

(defun ebox--drag-pointer (position window)
  "Return POSITION as (X . Y) pixels from WINDOW's text-area origin, or nil.
POSITION may name any part of WINDOW's frame: another window, a mode line,
header line, fringe or margin, or the frame itself when the pointer is past
every window, as tracking reports while the button is held.  The result can
therefore lie outside the text area.  Return nil when POSITION has no pixel
coordinates in that frame."
  (let ((xy (posn-x-y position)) (where (posn-window position))
        (area (posn-area position)) (frame (window-frame window)))
    (when-let* (((and (consp xy) (numberp (car xy)) (numberp (cdr xy))))
                (origin
                 (cond
                  ((and (window-live-p where) (eq (window-frame where) frame))
                   ;; Text coordinates count from the text area.  Side areas
                   ;; count X from the window edge and Y from the text rows;
                   ;; lines, bars and dividers count from the window corner.
                   (let ((outer (window-pixel-edges where))
                         (inner (window-inside-pixel-edges where)))
                     (cons (nth 0 (if area outer inner))
                           (nth 1 (if (memq area '(nil left-margin right-margin
                                                       left-fringe right-fringe))
                                      inner
                                    outer)))))
                  ((eq where frame) (cons 0 0)))))
      (let ((inside (window-inside-pixel-edges window)))
        (cons (- (+ (car origin) (car xy)) (nth 0 inside))
              (- (+ (cdr origin) (cdr xy)) (nth 1 inside)))))))

(defun ebox--drag-clamp (pointer width height)
  "Return POINTER clamped to a WIDTH by HEIGHT text area."
  (cons (min (max (car pointer) 0) (max 0 (1- width)))
        (min (max (cdr pointer) 0) (max 0 (1- height)))))

(defun ebox--event-owner (position)
  "Return the keymap owner node painted at buffer POSITION."
  (when (and (integer-or-marker-p position)
             (<= (point-min) position) (< position (point-max)))
    (let ((node (get-text-property position 'ebox-node)))
      (and node (ebox--keymap-owner node)))))

(defun ebox--escape-event-p (event)
  "Return non-nil when EVENT is the Escape key."
  (or (eq event 'escape)
      (eq (event-basic-type event) 'escape)
      (equal event ?\e)))

(defun ebox--drag-edge-symbols (position width height band-x band-y)
  "Return the edge symbols POSITION rests against or is past.
WIDTH and HEIGHT are the text area's size.  POSITION is text-area pixels and
may lie outside it; BAND-X and BAND-Y are the edge bands in pixels.  Symbols
come in the fixed order `left', `right', `top', `bottom'."
  (let ((x (car position)) (y (cdr position)))
    (delq nil (list (and (<= x band-x) 'left)
                    (and (>= x (- width band-x)) 'right)
                    (and (<= y band-y) 'top)
                    (and (>= y (- height band-y)) 'bottom)))))

(defvar ebox-drag-edge-band 1
  "Lines and columns from a window edge where a drag reports edge intent.")

(defvar ebox-drag-edge-interval 0.12
  "Seconds between `edge' gestures while a drag rests in or past the edge band.")

(defun ebox--drag-edge-band ()
  "Return the configured drag edge band in lines or columns."
  (if (and (numberp ebox-drag-edge-band) (> ebox-drag-edge-band 0))
      ebox-drag-edge-band
    1))

(defun ebox--drag-edge-interval ()
  "Return the configured seconds between `edge' gestures."
  (if (and (numberp ebox-drag-edge-interval) (> ebox-drag-edge-interval 0))
      ebox-drag-edge-interval
    0.12))

(defun ebox--track-drag (event callback &optional defer-active lock edge)
  "Track primary-button EVENT on its owner, calling CALLBACK per phase.
DEFER-ACTIVE delays the active state until the first motion.  LOCK keeps the
gesture alive after the first release until the next press.  EDGE reports an
`edge' phase while the pointer rests in or past the window's edge band; the
phase carries intent only and this tracker never scrolls.  The pointer may
leave the text area: positions clamp to it and :overshoot reports the rest."
  (when ebox--drag-active
    (user-error "An Ebox drag is already active"))
  (let* ((press (event-start event)) (window (posn-window press)))
    (unless (and (window-live-p window) (null (posn-area press)))
      (user-error "Ebox drag requires a live text window"))
    (let* ((buffer (window-buffer window))
           (mount (ebox-buffer-mount buffer))
           (start (ebox--drag-pointer press window))
           (owner (and mount start
                       (with-current-buffer buffer
                         (ebox--event-owner (posn-point press)))))
           (button (event-basic-type event))
           (position start) (pointer start) (last-event event) (reason 'input)
           (ebox--drag-active t)
           (mouse-fine-grained-tracking t)
           (window-edges (window-inside-pixel-edges window))
           (width (- (nth 2 window-edges) (nth 0 window-edges)))
           (height (- (nth 3 window-edges) (nth 1 window-edges)))
           (frame (window-frame window))
           (band (ebox--drag-edge-band))
           (band-x (max 1 (* band (frame-char-width frame))))
           (band-y (max 1 (* band (frame-char-height frame))))
           (interval (ebox--drag-edge-interval))
           edge-since next-edge elapsed moved
           done started finished active locked finishing)
      (cl-labels
          ((available ()
             (and (window-live-p window) (eq (window-buffer window) buffer)
                  (eq (ebox-buffer-mount buffer) mount)
                  (ebox--node-live-p owner mount)
                  (ebox--node-visible-p owner)
                  (ebox--node-enabled-p owner)))
           (emit (phase)
             (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
               (funcall callback
                        (list :phase phase :event last-event :node owner
                              :window window :buffer buffer
                              :start (cons (car start) (cdr start))
                              :position (cons (car position) (cdr position))
                              :delta (cons (- (car position) (car start))
                                           (- (cdr position) (cdr start)))
                              :overshoot (cons (- (car pointer) (car position))
                                               (- (cdr pointer) (cdr position)))
                              :reason (and (eq phase 'cancel) reason)
                              :edges (and (eq phase 'edge)
                                          (ebox--drag-edge-symbols
                                           pointer width height
                                           band-x band-y))
                              :elapsed (and (eq phase 'edge) elapsed)))))
           (track (xy)
             ;; Follow the pointer anywhere; positions stay in the text area.
             (setq pointer xy
                   position (ebox--drag-clamp xy width height)
                   moved (or moved (not (equal xy start)))))
           (edge-tick ()
             (when (and edge moved (not locked) (not finishing) (not done))
               (let ((edges (ebox--drag-edge-symbols
                             pointer width height band-x band-y))
                     (now (float-time)))
                 (if (null edges)
                     (setq edge-since nil next-edge nil)
                   (unless edge-since
                     (setq edge-since now
                           next-edge (+ now interval)))
                   (when (and next-edge (>= now next-edge))
                     ;; Wall time since the previous edge phase began, so a
                     ;; slow callback can scroll by time and keep its speed.
                     (setq elapsed (- now edge-since)
                           edge-since now
                           next-edge (+ now interval))
                     (emit 'edge)
                     (redisplay t)))))))
        (when (and owner (available))
          (unwind-protect
              (condition-case problem
                  (progn
                    (unless defer-active
                      (ebox--set-mount-state mount 'active owner)
                      (setq active t))
                    (setq started t)
                    ;; Tooltip timers and windows widen the gaps in which the
                    ;; NS port drops mouse events, losing the release; hide
                    ;; any tip now and show no help until the drag ends.
                    (when (and show-help-function (display-graphic-p frame))
                      (funcall show-help-function nil))
                    (emit 'start)
                    (track-mouse
                      (let ((track-mouse 'dragging)
                            (show-help-function #'ignore))
                        (while (and (not done) (or finishing (available)))
                          (when-let* ((next (read-event nil nil 0.05)))
                            (unless (or finishing (available))
                              (push next unread-command-events)
                              (setq reason 'target-unavailable done t))
                            (when (and (not done) (not finishing)
                                       (mouse-movement-p next))
                              ;; Merge already pending motions, bounded per round.
                              (let ((count 1) (poll t))
                                (while (and poll (< count 64))
                                  (let ((candidate (read-event nil nil 0)))
                                    (cond
                                     ((null candidate) (setq poll nil))
                                     ((mouse-movement-p candidate)
                                      (setq next candidate count (1+ count)))
                                     (t (push candidate unread-command-events)
                                        (setq poll nil)))))))
                            (setq last-event next)
                            (unless done
                              (let* ((modifiers (event-modifiers next))
                                     (primary-down (and (eq (event-basic-type next) button)
                                                        (memq 'down modifiers)))
                                     (release (and (eq (event-basic-type next) button)
                                                   (not (memq 'down modifiers))))
                                     (motion (mouse-movement-p next)))
                                (cond
                                 ((and finishing release) (setq done t))
                                 ((and finishing motion) nil)
                                 ((ebox--escape-event-p next)
                                  (setq reason 'quit done t))
                                 ((and locked primary-down)
                                  (when-let* ((xy (ebox--drag-pointer (event-start next) window)))
                                    (track xy))
                                  (setq finished t finishing t locked nil)
                                  (emit 'end)
                                  (redisplay t))
                                 ((or release motion)
                                  (when (and defer-active motion (not active))
                                    (ebox--set-mount-state mount 'active owner)
                                    (setq active t))
                                  (let ((xy (ebox--drag-pointer
                                             (if release (event-end next) (event-start next))
                                             window))
                                        (before position))
                                    (when xy (track xy))
                                    (cond
                                     (release
                                      (if (and lock (not locked))
                                          (progn (setq locked t) (emit 'move))
                                        (setq finished t done t)
                                        (emit 'end)))
                                     ((not (equal position before))
                                      (emit 'move)))
                                    (redisplay t)))
                                 ((and primary-down (not finishing))
                                  ;; A new press of the held button means the
                                  ;; window system lost its release: end where
                                  ;; the pointer last was, then let the press
                                  ;; start whatever it starts.
                                  (push next unread-command-events)
                                  (setq finished t done t)
                                  (emit 'end))
                                 (t (push next unread-command-events)
                                    (setq reason 'input done t))))))
                          (edge-tick))
                        (unless (or finished (available))
                          (setq reason 'target-unavailable)))))
                ((error quit)
                 (setq reason (if (eq (car problem) 'quit) 'quit 'error))
                 (signal (car problem) (cdr problem))))
            (unwind-protect
                (when (and started (not finished)) (emit 'cancel))
              (when (and active (eq (ebox-buffer-mount buffer) mount))
                (ebox--set-mount-state mount 'active nil)))))))))

(defun ebox--track-press (event)
  "Track primary-button EVENT until release; activate its owner when still hit."
  (let* ((window (posn-window (event-start event)))
         (buffer (and (window-live-p window) (window-buffer window)))
         (release-key (cond ((memq 'triple (event-modifiers event)) [triple-mouse-1])
                            ((memq 'double (event-modifiers event)) [double-mouse-1])
                            (t [mouse-1]))))
    (when (and buffer (ebox-buffer-mount buffer))
      (ebox--track-drag
       event
       (lambda (gesture)
         (when (eq (plist-get gesture :phase) 'end)
           (let* ((owner (plist-get gesture :node))
                  (mount (ebox-buffer-mount buffer))
                  (position (posn-point (event-end (plist-get gesture :event))))
                  (hit (with-current-buffer buffer (ebox--event-owner position))))
             (when (eq owner hit)
               (ebox--set-mount-state mount 'active nil)
               (when (eq window (selected-window))
                 (ignore-errors (ebox-focus owner buffer)))
               (let* ((map (ebox--declared-keymap owner))
                      (command (and (keymapp map) (lookup-key map release-key)))
                      (ebox--dispatching-activation t)
                      (last-input-event (plist-get gesture :event)))
                 (when (commandp command)
                   (with-current-buffer buffer (command-execute command))))))))
       t))))

;;;; Focus

(defun ebox--focus-scrolled-out-p (node)
  "Return non-nil when a scrolling ancestor hides NODE.
A tab stop scrolled out of view paints nothing, so the cover check cannot
judge it; focus reveals it and it stays reachable."
  (let ((scroller (ebox--clip-parent node))
        (scrolled-out nil))
    (while (and scroller (not scrolled-out))
      (when (ebox--scrollable-p scroller)
        (let* ((geo (ebox-node-layout scroller))
               (top (+ (or (ebox-node-root-line scroller) 0)
                       (ebox-geo-mt geo) (ebox-geo-pt geo)))
               (bottom (+ top (ebox-geo-vh geo)))
               (start (or (ebox-node-root-line node) top))
               (end (+ start (ebox-node-h node))))
          (when (or (<= end top) (>= start bottom))
            (setq scrolled-out t))))
      (setq scroller (ebox--clip-parent scroller)))
    scrolled-out))

(defun ebox--focusable-p (node mount)
  "Return non-nil when NODE can receive focus in MOUNT."
  (and (ebox--node-live-p node mount)
       (ebox--node-visible-p node)
       (ebox--node-enabled-p node)
       (let ((geometry (ebox-node-geometry node)))
         (and geometry (> (plist-get geometry :height) 0)
              (or (ebox-node-text-p node)
                  (ebox--focus-scrolled-out-p node)
                  (ebox--uncovered-x node mount geometry))))))

(defun ebox--focus-scope (mount)
  "Return MOUNT's innermost visible modal focus scope, or its root."
  (let ((root (ebox-mount-root mount)) found)
    (ebox-node-walk root
                    (lambda (node)
                      (when (and (eq (plist-get (ebox-node-inter node) :focus-scope) 'modal)
                                 (ebox--node-visible-p node))
                        (setq found node))))
    (or found root)))

(defun ebox--focus-group (node limit)
  "Return NODE's nearest strict ancestor declaring :focus-group below LIMIT."
  (let ((parent (ebox-node-parent node)) found)
    (while (and parent (not found) (not (eq parent limit)))
      (when (plist-get (ebox-node-inter parent) :focus-group)
        (setq found parent))
      (setq parent (ebox-node-parent parent)))
    found))

(defun ebox--current-member-p (node)
  "Return non-nil when NODE is marked as its group's selected or current item."
  (cl-some (lambda (name)
             (let ((value (cdr (assoc name (ebox-node-attributes node)))))
               (and value (not (member value '("false" "nil"))))))
           '("aria-selected" "aria-current" "aria-checked")))

(defun ebox--raw-stops (mount root)
  "Return focusable stops under ROOT in MOUNT, sorted in tab order.
Lower tab indices come first; equal indices keep tree order, so each
region's controls are visited together even when regions sit side by side."
  (let (stops)
    (ebox-node-walk root
                    (lambda (node)
                      (let ((index (plist-get (ebox-node-inter node) :tab-index)))
                        (when (and (integerp index) (>= index 0)
                                   (ebox--focusable-p node mount))
                          (push (cons node index) stops)))))
    (mapcar #'car (sort (nreverse stops)
                        (lambda (a b) (< (cdr a) (cdr b)))))))

(defun ebox--group-entry (mount group members)
  "Return the member of GROUP among MEMBERS that represents it in tab order."
  (let ((focus (ebox-mount-focus mount))
        (memory (gethash group (ebox-mount-focus-memory mount))))
    (or (car (memq focus members))
        (car (memq memory members))
        (cl-find-if #'ebox--current-member-p members)
        (car members))))

(defun ebox--tab-stops (mount &optional within)
  "Return MOUNT's focus stops in tab order, optionally only WITHIN a node.
Without WITHIN the stops come from the innermost modal scope.  Each focus
group strictly inside the searched subtree contributes only its entry."
  (let* ((root (or within (ebox--focus-scope mount)))
         (stops (ebox--raw-stops mount root))
         (groups (make-hash-table :test #'eq)))
    (dolist (stop stops)
      (let ((group (ebox--focus-group stop root)))
        (when group (push stop (gethash group groups)))))
    (if (zerop (hash-table-count groups))
        stops
      (let ((entries (make-hash-table :test #'eq)))
        (maphash (lambda (group members)
                   (puthash group (ebox--group-entry mount group (nreverse members))
                            entries))
                 groups)
        (cl-remove-if (lambda (stop)
                        (let ((group (ebox--focus-group stop root)))
                          (and group (not (eq stop (gethash group entries))))))
                      stops)))))

(defun ebox--node-rect (node)
  "Return NODE's border box as (X Y WIDTH HEIGHT), Y in pixels."
  (let ((g (ebox-node-geometry node))
        (line (ebox--line-pixels)))
    (and g (list (plist-get g :x) (* line (plist-get g :y))
                 (plist-get g :width) (* line (plist-get g :height))))))

(defun ebox--line-pixels ()
  "Return the approximate pixel height of one root line."
  (let ((window (get-buffer-window (current-buffer) t)))
    (if window (frame-char-height (window-frame window)) (frame-char-height))))

(defun ebox--focus-reveal (node mount)
  "Scroll NODE's scrollers so NODE shows, flushing MOUNT when unbatched."
  (when (ebox--clip-parent node)
    (ebox-node-scroll-into-view node)
    (when (and (zerop ebox--batch-depth) (ebox-mount-queued mount))
      (ebox-flush))))

(defun ebox--focus-hover (mount node)
  "Show the hover content of NODE's hover owner in MOUNT, or restore it."
  (let* ((owner (let ((n node))
                  (while (and n (not (plist-get (ebox-node-inter n) :hover-content)))
                    (setq n (ebox-node-parent n)))
                  n))
         (group (and owner (ebox--hover-group owner))))
    (unless (equal group (ebox-mount-hover mount))
      (when (ebox-mount-hover mount) (ebox--hover-restore mount))
      (when group (ebox--hover-activate mount group)))))

(defvar ebox-focus-change-functions nil
  "Abnormal hook run in a mounted buffer after `ebox-focus' moved its focus.
Each function receives the previously focused node, or nil, and the newly
focused node, or nil when focus was cleared.")

(defun ebox-focus (node &optional buffer-or-name)
  "Focus NODE in BUFFER-OR-NAME and move point to its first character.
Nil NODE clears focus.  Signal `user-error' when NODE cannot be focused.
NODE's scrolling ancestors reveal it, its focus group remembers it and its
hover content shows as it would under the mouse.  A change of focused node
runs `ebox-focus-change-functions'."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (previous (ebox-mount-focus mount)))
    (when (and node (not (ebox--focusable-p node mount)))
      (user-error "Ebox node cannot receive focus"))
    (with-current-buffer (ebox-mount-buffer mount)
      (when node
        (ebox--focus-reveal node mount)
        (let ((group (ebox--focus-group node nil)))
          (when group (puthash group node (ebox-mount-focus-memory mount))))
        (setf (ebox-mount-focus-anchor mount) (ebox--node-rect node)))
      (ebox--set-mount-state mount 'focus node)
      (when (ebox-mount-hover-p mount) (ebox--focus-hover mount node))
      (when node
        (let ((position (ebox-node-position node)))
          (when position
            (goto-char position)
            (dolist (window (get-buffer-window-list (current-buffer) nil t))
              (set-window-point window position)))))
      (unless (eq previous node)
        (run-hook-with-args 'ebox-focus-change-functions previous node)))
    node))

(defun ebox-focused-node (&optional buffer-or-name)
  "Return the focused node of BUFFER-OR-NAME, or nil."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (when mount
      (let ((focus (ebox-mount-focus mount)))
        (if (and focus (not (ebox--focusable-p focus mount)))
            (progn (setf (ebox-mount-focus mount) nil) nil)
          focus)))))

(defun ebox--anchor-index (mount stops count)
  "Return the index in STOPS after (COUNT > 0) or before MOUNT's lost focus."
  (let ((anchor (ebox-mount-focus-anchor mount))
        (n (length stops)))
    (when anchor
      (let* ((line (ebox--line-pixels))
             (ay (/ (nth 1 anchor) line)) (ax (nth 0 anchor))
             (after (cl-position-if
                     (lambda (stop)
                       (let ((g (ebox-node-geometry stop)))
                         (or (> (plist-get g :y) ay)
                             (and (= (plist-get g :y) ay) (>= (plist-get g :x) ax)))))
                     stops)))
        (if (> count 0) (+ (or after n) (1- count))
          (+ (or after n) count))))))

(defun ebox--focus-move (count cycle buffer-or-name &optional within restart)
  "Move focus COUNT stops; CYCLE wraps.  WITHIN limits the stops to a subtree.
RESTART ignores the current focus.  When the focused node has disappeared,
movement continues from its last position."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (stops (ebox--tab-stops mount within))
         (current (and (not restart) (ebox-focused-node buffer-or-name)))
         (index (and current (cl-position current stops))))
    (unless stops (user-error "No Ebox focus stop"))
    (if (and (eql count 0) (not restart))
        current
      (let* ((n (length stops))
             (target
              (cond
               (index (+ index count))
               ((and (not restart) (not current))
                (or (ebox--anchor-index mount stops count)
                    (if (< count 0) (+ n count) (max 0 (1- count)))))
               (t (if (< count 0) (+ n count) (max 0 (1- count)))))))
        (if cycle (setq target (mod target n))
          (unless (and (>= target 0) (< target n))
            (user-error "No %s Ebox focus stop" (if (< count 0) "previous" "next"))))
        (ebox-focus (nth target stops) buffer-or-name)))))

(defun ebox-focus-next (&optional count cycle buffer-or-name)
  "Move focus COUNT (default 1) tab stops forward; CYCLE wraps at the end."
  (interactive (list 1 t nil))
  (ebox--focus-move (or count 1) cycle buffer-or-name))

(defun ebox-focus-previous (&optional count cycle buffer-or-name)
  "Move focus COUNT (default 1) tab stops backward; CYCLE wraps at the start."
  (interactive (list 1 t nil))
  (ebox--focus-move (- (or count 1)) cycle buffer-or-name))

(defun ebox-focus-first (&optional buffer-or-name)
  "Focus the first tab stop of BUFFER-OR-NAME."
  (interactive)
  (ebox--focus-move 1 nil buffer-or-name nil t))

(defun ebox-focus-within (node &optional count cycle buffer-or-name)
  "Move focus among the tab stops inside NODE.
Nil COUNT focuses the first stop; integer COUNT moves relative to the current
focus when it lies inside NODE."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (current (ebox-focused-node buffer-or-name))
         (inside (and current (ebox-node-ancestor-p node current))))
    (unless (ebox--node-live-p node mount)
      (user-error "Ebox focus root is not mounted"))
    (if (or (null count) (not inside))
        (ebox--focus-move (if (and count (< count 0)) -1 1) cycle buffer-or-name node t)
      (ebox--focus-move count cycle buffer-or-name node))))

;;;; Directional focus

(defun ebox--direction-score (from to direction)
  "Return the distance from rect FROM to rect TO in DIRECTION, or nil.
TO must lie wholly beyond FROM's edge; the perpendicular gap counts double
and the offset between centers breaks ties."
  (pcase-let ((`(,fx ,fy ,fw ,fh) from) (`(,tx ,ty ,tw ,th) to))
    (let ((along (pcase direction
                   ('down (and (>= ty (+ fy fh)) (- ty (+ fy fh))))
                   ('up (and (<= (+ ty th) fy) (- fy (+ ty th))))
                   ('right (and (>= tx (+ fx fw)) (- tx (+ fx fw))))
                   ('left (and (<= (+ tx tw) fx) (- fx (+ tx tw))))))
          (gap (if (memq direction '(up down))
                   (max 0 (- tx (+ fx fw)) (- fx (+ tx tw)))
                 (max 0 (- ty (+ fy fh)) (- fy (+ ty th)))))
          (offset (if (memq direction '(up down))
                      (abs (- (+ tx (/ tw 2.0)) (+ fx (/ fw 2.0))))
                    (abs (- (+ ty (/ th 2.0)) (+ fy (/ fh 2.0)))))))
      (and along (+ along (* 2 gap) (/ offset 4.0))))))

(defun ebox--nearest (from candidates direction)
  "Return the node in CANDIDATES nearest to rect FROM in DIRECTION."
  (let (best best-score)
    (dolist (node candidates)
      (let* ((rect (ebox--node-rect node))
             (score (and rect (ebox--direction-score from rect direction))))
        (when (and score (or (null best-score) (< score best-score)))
          (setq best node best-score score))))
    best))

(defun ebox--group-members (mount group)
  "Return GROUP's focusable member stops in MOUNT in tab order."
  (cl-remove-if-not (lambda (stop) (eq (ebox--focus-group stop nil) group))
                    (ebox--raw-stops mount group)))

(defun ebox--nodes-within-p (node root)
  "Return non-nil when NODE is ROOT or a descendant of ROOT."
  (or (eq node root) (ebox-node-ancestor-p root node)))

(defun ebox-focus-direction (direction &optional buffer-or-name root)
  "Move focus toward DIRECTION, one of `up', `down', `left' or `right'.
Inside a `vertical' focus group, up and down step through its members; a
`horizontal' group steps with left and right and a `grid' group moves to
the nearest member in DIRECTION.  Other keys, a group boundary and
ungrouped stops move to the nearest stop in DIRECTION within the modal
scope; entering another group lands on its entry.  ROOT, when non-nil,
restricts every candidate stop to ROOT or its descendants, and a group
participates only when it lies inside ROOT.  Return the focused node, or
nil when no stop lies in DIRECTION."
  (unless (memq direction '(up down left right))
    (signal 'wrong-type-argument (list '(member up down left right) direction)))
  (let* ((mount (ebox--mount-for buffer-or-name))
         (current (ebox-focused-node buffer-or-name))
         (scope (ebox--focus-scope mount))
         (group (and current (ebox--focus-group current scope)))
         (group (and group
                     (or (null root) (ebox--nodes-within-p group root))
                     group))
         (orientation (and group (plist-get (ebox-node-inter group) :focus-group)))
         (forward (memq direction '(down right)))
         (from (if current (ebox--node-rect current) (ebox-mount-focus-anchor mount)))
         target)
    (cond
     ((and (null current) (null from))
      (let ((stops (cl-remove-if-not (lambda (stop) (or (null root)
                                                        (ebox--nodes-within-p stop root)))
                                     (ebox--tab-stops mount))))
        (setq target (if forward (car stops) (car (last stops))))))
     (group
      (let ((members (if (null root)
                         (ebox--group-members mount group)
                       (cl-remove-if-not (lambda (stop) (ebox--nodes-within-p stop root))
                                         (ebox--group-members mount group)))))
        (setq target
              (if (eq orientation 'grid)
                  (ebox--nearest from (delq current (copy-sequence members)) direction)
                (when (memq direction (if (eq orientation 'vertical) '(up down) '(left right)))
                  (let ((index (cl-position current members)))
                    (and index (> (if forward (1+ index) index) 0)
                         (nth (if forward (1+ index) (1- index)) members)))))))))
    (unless target
      (let* ((stops (ebox--raw-stops mount scope))
             (candidates (cl-remove-if (lambda (stop)
                                         (or (eq stop current)
                                             (and root (not (ebox--nodes-within-p stop root)))
                                             (and group (eq (ebox--focus-group stop scope) group))))
                                       stops))
             (near (and from (ebox--nearest from candidates direction)))
             (near-group (and near (ebox--focus-group near scope)))
             (near-group (and near-group
                              (or (null root) (ebox--nodes-within-p near-group root))
                              near-group)))
        (setq target (if near-group
                         (ebox--group-entry mount near-group
                                            (ebox--group-members mount near-group))
                       near))))
    (when target (ebox-focus target buffer-or-name))))

(defun ebox-focus-scope (&optional buffer-or-name)
  "Return the innermost visible modal focus scope of BUFFER-OR-NAME.
Without a visible `:focus-scope modal' node, return the mount root."
  (ebox--focus-scope (ebox--mount-for buffer-or-name)))

(defun ebox-focus-stops (&optional buffer-or-name)
  "Return every focus stop of BUFFER-OR-NAME's modal scope in tab order.
Unlike Tab navigation, members of focus groups are all listed."
  (let ((mount (ebox--mount-for buffer-or-name)))
    (ebox--raw-stops mount (ebox--focus-scope mount))))

(defun ebox-focus-edge (last &optional buffer-or-name root)
  "Focus the first member of the focused node's group, or the LAST one.
Outside a group, focus the first or LAST stop of the modal scope.
ROOT restricts candidates and groups to its subtree, like
`ebox-focus-direction'.  A root outside the mount signals `user-error'."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (scope (or root (ebox--focus-scope mount)))
         (_ (unless (ebox--node-live-p scope mount)
              (user-error "Ebox focus root is not mounted")))
         (current (ebox-focused-node buffer-or-name))
         (group (and current (not (eq current scope))
                     (ebox-node-ancestor-p scope current)
                     (ebox--focus-group current scope)))
         (stops (if group (ebox--group-members mount group)
                  (ebox--tab-stops mount scope))))
    (unless stops (user-error "No Ebox focus stop"))
    (ebox-focus (if last (car (last stops)) (car stops)) buffer-or-name)))

(defun ebox--direction-command (direction)
  "Return a command moving focus toward DIRECTION or scrolling past the end."
  (lambda ()
    (interactive)
    (unless (ebox-focus-direction direction)
      (pcase direction
        ('down (ebox-scroll-down))
        ('up (ebox-scroll-up))))))

;;;; Native input

(defun ebox-call-with-input (node reader &optional buffer-or-name)
  "Call zero-argument READER for visible, enabled NODE in BUFFER-OR-NAME.
Return its result when NODE is still available afterwards; otherwise signal
`ebox-input-cancelled'.  Afterwards NODE holds logical focus, or the earlier
focus returns when NODE is gone."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (focus (ebox-mount-focus mount)))
    (unless (ebox--focusable-p node mount)
      (user-error "Ebox input target is not available"))
    (let (result)
      (unwind-protect
          (setq result (funcall reader))
        (when (eq (ebox-buffer-mount (ebox-mount-buffer mount)) mount)
          (cond ((ebox--focusable-p node mount)
                 (ebox--set-mount-state mount 'focus node))
                ((ebox--focusable-p focus mount)
                 (ebox--set-mount-state mount 'focus focus)))))
      (unless (and (eq (ebox-buffer-mount (ebox-mount-buffer mount)) mount)
                   (ebox--focusable-p node mount))
        (signal 'ebox-input-cancelled (list node)))
      result)))

;;;; Input sessions

;; A session edits one text node through a hidden editing buffer that holds
;; the node's value.  Keys typed in the mounted buffer resolve against that
;; buffer's keymaps and run there, so every native editing command, the kill
;; ring, undo and input methods act on the value itself.  The node displays
;; the value through ordinary layout: wrapping, padding and borders stay
;; intact while the user types, and each painted character carries its
;; value offset so point and the region map between both buffers.

(define-error 'ebox-input-error "Invalid Ebox input session" 'ebox-error)

(cl-defstruct (ebox--input-session (:constructor ebox--input-session-make)
                                   (:copier nil))
  "Native editing of one text node through a hidden editing buffer."
  mount node shadow keymap on-change on-leave value preedit
  held turn command goal-x overlays emulation done)

(defvar ebox--input-sessions nil
  "Active input sessions.")

(defvar ebox--input-shadow-cache (make-hash-table :test #'eq :weakness 'key)
  "Last editing buffer of each text node, keeping point and undo history.")

(defvar ebox-input-edit-commands
  '(newline open-line newline-and-indent electric-newline-and-maybe-indent
    completion-at-point indent-for-tab-command yank)
  "Commands that edit the session text when bound in a session keymap.
Other bindings of a session keymap run in the mounted buffer.")

(defconst ebox--input-passthrough-regexp
  (concat "\\`\\(?:mouse-\\|mwheel-\\|pixel-scroll-\\|scroll-\\|recenter\\|"
          "move-to-window-line\\|other-window\\|other-frame\\|delete-window\\|"
          "delete-other-windows\\|split-window\\|switch-to-buffer\\|"
          "kill-buffer\\|kill-current-buffer\\|save-buffer\\|save-some-buffers\\|"
          "save-buffers-kill\\|find-file\\|execute-extended-command\\|"
          "eval-expression\\|universal-argument\\|digit-argument\\|"
          "negative-argument\\|handle-\\|text-scale-\\|tab-\\|windmove-\\|"
          "winner-\\|toggle-frame\\|suspend-frame\\|describe-\\|help\\|"
          "ns-\\|menu-bar-\\|tmm-\\|ignore\\'\\|keyboard-escape-quit\\)")
  "Names of commands acting on windows, frames or Emacs rather than text.")

(defun ebox-input-active-p (&optional buffer-or-name)
  "Return the active input session of BUFFER-OR-NAME, or nil."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (and mount (ebox-mount-session mount))))

(defun ebox--input-current ()
  "Return the current buffer's live input session, or nil."
  (let ((mount ebox--buffer-mount))
    (and mount (ebox-mount-session mount))))

(defun ebox--input-check (session)
  "Signal unless SESSION is an input session."
  (unless (ebox--input-session-p session)
    (signal 'ebox-input-error (list "Expected an input session" session))))

(defun ebox--input-caret (session)
  "Return SESSION's caret as a value offset."
  (with-current-buffer (ebox--input-session-shadow session) (1- (point))))

(defun ebox--input-display (session)
  "Return SESSION's displayed text: its value with any preedit at the caret."
  (let ((value (ebox--input-session-value session))
        (preedit (ebox--input-session-preedit session)))
    (if (and preedit (> (length preedit) 0))
        (let ((caret (ebox--input-caret session)))
          (concat (substring value 0 caret) preedit (substring value caret)))
      value)))

(defun ebox--input-display-caret (session)
  "Return SESSION's caret as an offset in its displayed text."
  (+ (ebox--input-caret session) (length (ebox--input-session-preedit session))))

(defun ebox--input-value-offset (session offset)
  "Return the value offset of displayed OFFSET in SESSION."
  (let ((caret (ebox--input-caret session))
        (size (length (ebox--input-session-preedit session))))
    (cond ((<= offset caret) offset)
          ((>= offset (+ caret size)) (- offset size))
          (t caret))))

(defun ebox--input-show (session)
  "Display SESSION's text in its node; the caller settles the change."
  (let* ((node (ebox--input-session-node session))
         (display (ebox--input-display session))
         (preedit (ebox--input-session-preedit session))
         (caret (ebox--input-caret session))
         (cell (assq node ebox--editing)))
    (when cell
      (setcdr cell (and preedit (> (length preedit) 0)
                        (cons caret (+ caret (length preedit))))))
    (unless (equal display (ebox-node-text node))
      (setf (ebox-node-text node) display)
      (ebox--mark node ebox--d-layout))))

;;;; Painted rows

(defun ebox--input-para (node)
  "Return (OWNER . PARA) for the paragraph that lays out text NODE, or nil."
  (let ((owner node) para)
    (while (and owner (not para))
      (let ((geo (ebox-node-layout owner)))
        (setq para (and geo (ebox--para-of geo node))))
      (unless para (setq owner (ebox-node-parent owner))))
    (and para (cons owner para))))

(defun ebox--input-rows (session)
  "Return SESSION's painted rows in the current (mounted) buffer.
Each row is [BOL FIRST FIRST-OFFSET LAST LAST-OFFSET START INDEX]: FIRST and
LAST are the positions of the row's first and last value characters, nil on
an empty row, and START is the row's content start."
  (let* ((mount (ebox--input-session-mount session))
         (found (ebox--input-para (ebox--input-session-node session))))
    (when found
      (let* ((owner (car found)) (para (cdr found))
             (geo (ebox-node-layout owner))
             (top (ebox--item-top-in-root para))
             (left (+ (car (ebox--root-xy owner)) (ebox-geo-ml geo) (ebox-geo-bl geo)
                      (ebox-geo-pl geo) (ebox-para-x para)))
             (total (ebox-mount-lines mount))
             rows)
        (save-excursion
          (dotimes (k (ebox-para-h para))
            (let ((line (+ top k)))
              (when (and (>= line 0) (< line total))
                (ebox--goto-line mount line)
                (let* ((bol (point)) (eol (line-end-position))
                       (first (text-property-not-all bol eol 'ebox-offset nil))
                       (last (and first
                                  (if (get-text-property (1- eol) 'ebox-offset)
                                      (1- eol)
                                    (1- (previous-single-property-change
                                         eol 'ebox-offset nil first))))))
                  (push (vector bol first (and first (get-text-property first 'ebox-offset))
                                last (and last (get-text-property last 'ebox-offset))
                                (ebox--pos-at-x bol left) k)
                        rows))))))
        (nreverse rows)))))

(defun ebox--input-empty-offset (row before)
  "Return the offset of empty ROW after the non-empty row BEFORE, or nil.
Only newlines leave a row empty, one per row after the previous text."
  (if before
      (+ (aref before 4) 1 (- (aref row 6) (aref before 6)))
    (aref row 6)))

(defun ebox--input-offset-at (session rows pos)
  "Return SESSION's displayed offset for buffer POS among ROWS."
  (let ((bol (save-excursion (goto-char pos) (line-beginning-position)))
        (size (length (ebox--input-display session)))
        before)
    (catch 'done
      (dolist (row rows)
        (when (= (aref row 0) bol)
          (throw 'done
                 (min size
                      (cond
                       ((null (aref row 1)) (ebox--input-empty-offset row before))
                       ((<= pos (aref row 1)) (aref row 2))
                       ((> pos (aref row 3)) (1+ (aref row 4)))
                       (t (or (get-text-property pos 'ebox-offset)
                              (let ((p pos))
                                (while (and (> p (aref row 1))
                                            (not (get-text-property (1- p) 'ebox-offset)))
                                  (setq p (1- p)))
                                (1+ (get-text-property (1- p) 'ebox-offset)))))))))
        (when (aref row 1) (setq before row)))
      (if (and rows (< bol (aref (car rows) 0))) 0 size))))

(defun ebox--input-position-of (rows offset)
  "Return the buffer position showing displayed OFFSET among ROWS."
  (let (before result (tail rows))
    (while (and tail (not result))
      (let ((row (car tail)) (next (cadr tail)))
        (if (aref row 1)
            (let ((first (aref row 2)) (last (aref row 4)))
              (cond
               ((and (<= first offset) (<= offset last))
                (setq result (or (text-property-any (aref row 1) (1+ (aref row 3))
                                                    'ebox-offset offset)
                                 (aref row 1))))
               ((and (= offset (1+ last))
                     (not (and next (aref next 1) (= (aref next 2) offset))))
                (setq result (1+ (aref row 3)))))
              (setq before row))
          (when (= offset (ebox--input-empty-offset row before))
            (setq result (aref row 5)))))
      (setq tail (cdr tail)))
    (or result
        (let ((row (car (last rows))))
          (and row (if (aref row 1) (1+ (aref row 3)) (aref row 5)))))))

(defun ebox--input-paint-region (session rows)
  "Highlight SESSION's active region over its painted value characters."
  (mapc #'delete-overlay (ebox--input-session-overlays session))
  (setf (ebox--input-session-overlays session) nil)
  (let ((region (with-current-buffer (ebox--input-session-shadow session)
                  (and mark-active (mark t) (/= (mark t) (point))
                       (cons (1- (min (mark t) (point))) (1- (max (mark t) (point)))))))
        overlays)
    (when region
      (dolist (row rows)
        (when (aref row 1)
          (let ((from (max (car region) (aref row 2)))
                (to (min (cdr region) (1+ (aref row 4)))))
            (when (< from to)
              (let* ((end (1+ (aref row 3)))
                     (start (text-property-any (aref row 1) end 'ebox-offset from))
                     (stop (text-property-any (aref row 1) end 'ebox-offset (1- to))))
                (when (and start stop)
                  (let ((overlay (make-overlay start (1+ stop) nil t nil)))
                    (overlay-put overlay 'face 'region)
                    (overlay-put overlay 'priority 100)
                    (push overlay overlays)))))))))
    (setf (ebox--input-session-overlays session) overlays)))

(defun ebox--input-place-point (session)
  "Put the mounted buffer's point on SESSION's caret and paint its region."
  (let ((buffer (ebox-mount-buffer (ebox--input-session-mount session))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((rows (ebox--input-rows session))
               (pos (and rows (ebox--input-position-of
                               rows (ebox--input-display-caret session)))))
          (when pos
            (goto-char pos)
            (dolist (window (get-buffer-window-list buffer nil t))
              (set-window-point window pos)))
          (ebox--input-paint-region session rows))))))

(defun ebox--input-after-flush (buffer)
  "Keep BUFFER's point on its input session's caret after a flush."
  (let* ((mount (ebox-buffer-mount buffer))
         (session (and mount (ebox-mount-session mount))))
    (when (and session (ebox--input-session-held session))
      (ebox--input-place-point session))))

(add-hook 'ebox-after-flush-functions #'ebox--input-after-flush)

;;;; Commands

(defun ebox--input-passthrough-p (command)
  "Return non-nil when COMMAND acts outside the session text."
  (and (symbolp command)
       (string-match-p ebox--input-passthrough-regexp (symbol-name command))))

(defun ebox--input-text-binding (keys)
  "Return the current buffer's binding of KEYS as typed into a text buffer.
The mounted buffer may bind a function key such as <backspace> that a
plain buffer reaches only through `local-function-key-map' (as DEL)."
  (or (key-binding keys t)
      (let ((translated (lookup-key local-function-key-map keys)))
        (and (arrayp translated) (key-binding translated t)))))

(defun ebox--input-pre-command ()
  "Route the coming keyboard command to the current buffer's input session."
  (when-let* ((session (ebox--input-current)))
    (setf (ebox--input-session-turn session) nil
          (ebox--input-session-command session) nil)
    (let ((event last-command-event))
      (when (and (consp event) (eq (event-basic-type event) 'mouse-1)
                 (memq 'down (event-modifiers event)))
        (let ((start (event-start event)))
          (when (and (eq (posn-window start) (selected-window))
                     (null (posn-area start)) (integerp (posn-point start))
                     (ebox--input-inside-p session (posn-point start)))
            (setq this-command #'ebox--input-track-pointer))))
      (when (or (integerp event) (and event (symbolp event)))
        (let* ((keys (this-command-keys-vector))
               (keymap (ebox--input-session-keymap session))
               (own (and keymap (lookup-key keymap keys)))
               (own (and (commandp own) (not (numberp own)) own)))
          (if (and own (not (memq own ebox-input-edit-commands)))
              (setq this-command own)
            (let ((command (or own (with-current-buffer
                                       (ebox--input-session-shadow session)
                                     (ebox--input-text-binding keys)))))
              (cond
               ((memq command '(ns-put-working-text ns-insert-working-text))
                (setf (ebox--input-session-turn session) t)
                (setq this-command #'ebox--input-put-preedit))
               ((memq command '(ns-unput-working-text ns-delete-working-text))
                (setf (ebox--input-session-turn session) t)
                (setq this-command #'ebox--input-clear-preedit))
               ((memq command '(next-line previous-line))
                (setf (ebox--input-session-turn session) t)
                (setq this-command (if (eq command 'next-line)
                                       #'ebox--input-next-row
                                     #'ebox--input-previous-row)))
               ((and command (commandp command)
                     (not (ebox--input-passthrough-p command)))
                (setf (ebox--input-session-turn session) t
                      (ebox--input-session-command session) command)
                (setq this-command #'ebox--input-run))))))))))

(defun ebox--input-run ()
  "Run the current input session's command in its editing buffer."
  (interactive)
  (let* ((session (ebox--input-current))
         (command (and session (ebox--input-session-command session)))
         (keys (this-command-keys-vector))
         final)
    (when command
      (with-current-buffer (ebox--input-session-shadow session)
        (setq deactivate-mark nil)
        (let ((this-command command) (real-this-command command))
          (when (and (bound-and-true-p delete-selection-mode)
                     (fboundp 'delete-selection-pre-hook))
            (delete-selection-pre-hook))
          (call-interactively command nil keys)
          (setq final this-command))
        (when (and deactivate-mark mark-active) (deactivate-mark)))
      (setq this-command final))))

(defun ebox--input-put-preedit ()
  "Show the input method's working text at the session caret."
  (interactive)
  (when-let* ((session (ebox--input-current)))
    (setf (ebox--input-session-preedit session)
          (and (boundp 'ns-working-text) (stringp ns-working-text)
               (substring-no-properties ns-working-text)))
    (ebox--mutation (ebox--input-show session))))

(defvar ebox--input-special-saved nil
  "Input-method special-event bindings displaced while sessions are active.")

(defconst ebox--input-special-events
  '((ns-put-working-text . ebox--input-special-put)
    (ns-unput-working-text . ebox--input-special-unput))
  "Input-method working-text special events and their session handlers.
Emacs runs these outside the command loop, so command hooks never see them.")

(defun ebox--input-special-session ()
  "Return the input session of the selected window's buffer, or nil."
  (with-current-buffer (window-buffer (selected-window))
    (ebox--input-current)))

(defun ebox--input-special-fallback (event)
  "Run EVENT's displaced special-event binding."
  (let ((command (cdr (assq event ebox--input-special-saved))))
    (when (commandp command) (call-interactively command))))

(defun ebox--input-special-put ()
  "Show input-method working text in the selected session, else natively."
  (interactive)
  (if (ebox--input-special-session)
      (with-current-buffer (window-buffer (selected-window))
        (ebox--input-put-preedit))
    (ebox--input-special-fallback 'ns-put-working-text)))

(defun ebox--input-special-unput ()
  "Clear input-method working text in the selected session, else natively."
  (interactive)
  (if (ebox--input-special-session)
      (with-current-buffer (window-buffer (selected-window))
        (ebox--input-clear-preedit))
    (ebox--input-special-fallback 'ns-unput-working-text)))

(defun ebox--input-special-install ()
  "Route input-method special events through sessions while any is active."
  (unless ebox--input-special-saved
    (dolist (entry ebox--input-special-events)
      (push (cons (car entry) (lookup-key special-event-map (vector (car entry))))
            ebox--input-special-saved)
      (define-key special-event-map (vector (car entry)) (cdr entry)))))

(defun ebox--input-special-uninstall ()
  "Restore the input-method special-event bindings once no session remains."
  (when (and ebox--input-special-saved (null ebox--input-sessions))
    (dolist (entry ebox--input-special-saved)
      (when (eq (lookup-key special-event-map (vector (car entry)))
                (cdr (assq (car entry) ebox--input-special-events)))
        (define-key special-event-map (vector (car entry)) (cdr entry))))
    (setq ebox--input-special-saved nil)))

(defun ebox--input-clear-preedit ()
  "Remove the input method's working text from the session."
  (interactive)
  (when-let* ((session (ebox--input-current)))
    (setf (ebox--input-session-preedit session) nil)
    (ebox--mutation (ebox--input-show session))))

(defun ebox--input-move-row (delta)
  "Move the current session's caret DELTA painted rows, keeping its column."
  (when-let* ((session (ebox--input-current)))
    (let* ((rows (ebox--input-rows session))
           (caret (ebox--input-display-caret session))
           (pos (and rows (ebox--input-position-of rows caret)))
           (bol (and pos (save-excursion (goto-char pos) (line-beginning-position))))
           (index (and bol (cl-position bol rows :key (lambda (row) (aref row 0)))))
           (x (if (and (memq last-command '(ebox--input-next-row ebox--input-previous-row))
                       (ebox--input-session-goal-x session))
                  (ebox--input-session-goal-x session)
                (and bol (ebox--line-width (buffer-substring bol pos)))))
           (target (and index (+ index delta)))
           (offset (cond ((null target) nil)
                         ((< target 0) 0)
                         ((>= target (length rows)) (length (ebox--input-display session)))
                         (t (let ((row (nth target rows)))
                              (ebox--input-offset-at
                               session rows (ebox--pos-at-x (aref row 0) x)))))))
      (setf (ebox--input-session-goal-x session) x)
      (when offset
        (with-current-buffer (ebox--input-session-shadow session)
          (goto-char (1+ (ebox--input-value-offset session offset))))))))

(defun ebox--input-next-row ()
  "Move the session caret to the next painted row."
  (interactive)
  (ebox--input-move-row 1))

(defun ebox--input-previous-row ()
  "Move the session caret to the previous painted row."
  (interactive)
  (ebox--input-move-row -1))

(defun ebox--input-sync (session)
  "Publish SESSION's edited value and show its caret."
  (let ((value (with-current-buffer (ebox--input-session-shadow session)
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (unless (equal value (ebox--input-session-value session))
      (setf (ebox--input-session-value session) value)
      (when-let* ((callback (ebox--input-session-on-change session)))
        (funcall callback value)))
    (unless (ebox--input-session-done session)
      (ebox--mutation (ebox--input-show session))
      (ebox--input-place-point session))))

(defun ebox--input-inside-p (session pos)
  "Return non-nil when buffer POS lies inside SESSION's field.
The field is the box of the edited node's activatable owner, padding
included, or the value's painted rows when no owner frames it."
  (let ((owner (ebox--keymap-owner (ebox--input-session-node session))))
    (if (and owner (eq owner (ebox--event-owner pos)))
        t
      (let* ((found (ebox--input-para (ebox--input-session-node session)))
             (geometry (and found (ebox-node-geometry (car found))))
             (rows (ebox--input-rows session))
             (bol (save-excursion (goto-char pos) (line-beginning-position))))
        (when (and geometry (cl-find bol rows :key (lambda (row) (aref row 0))))
          (let ((left (plist-get geometry :x)))
            (and (>= pos (ebox--pos-at-x bol left))
                 (< pos (ebox--pos-at-x bol (+ left (plist-get geometry :width)))))))))))

(defun ebox--input-select (session from to)
  "Put SESSION's caret at buffer position TO, selecting from FROM when it differs."
  (let* ((rows (ebox--input-rows session))
         (caret (ebox--input-value-offset
                 session (ebox--input-offset-at session rows to)))
         (anchor (and from (/= from to)
                      (ebox--input-value-offset
                       session (ebox--input-offset-at session rows from)))))
    (when mark-active (deactivate-mark))
    (with-current-buffer (ebox--input-session-shadow session)
      (if (and anchor (/= anchor caret))
          (push-mark (1+ anchor) t t)
        (deactivate-mark))
      (goto-char (1+ caret)))
    (setf (ebox--input-session-held session) t)
    (ebox--input-place-point session)))

(defun ebox--input-select-unit (session unit)
  "Select the word around SESSION's caret, or its whole value, for UNIT."
  (with-current-buffer (ebox--input-session-shadow session)
    (let ((bounds (if (eq unit 'word)
                      (bounds-of-thing-at-point 'word)
                    (cons (point-min) (point-max)))))
      (when (and bounds (< (car bounds) (cdr bounds)))
        (push-mark (car bounds) t t)
        (goto-char (cdr bounds)))))
  (ebox--input-place-point session))

(defun ebox--input-leave (session)
  "Release SESSION's caret hold and report that the pointer left its field."
  (setf (ebox--input-session-held session) nil)
  (mapc #'delete-overlay (ebox--input-session-overlays session))
  (setf (ebox--input-session-overlays session) nil)
  (when-let* ((callback (ebox--input-session-on-leave session)))
    (funcall callback)))

(defun ebox--input-track-pointer (event)
  "Place the input caret at primary press EVENT and select while dragging.
A double press selects the word at the caret and a triple press the value."
  (interactive "e")
  (when-let* ((session (ebox--input-current)))
    (let* ((from (posn-point (event-start event)))
           (count (cond ((memq 'triple (event-modifiers event)) 3)
                        ((memq 'double (event-modifiers event)) 2)
                        (t 1))))
      (ebox--input-select session from from)
      (let (next)
        (track-mouse
          (setq track-mouse 'dragging)
          (while (progn (setq next (read-event))
                        (mouse-movement-p next))
            (let ((to (posn-point (event-end next))))
              (when (and (= count 1) (integerp to) (ebox--input-inside-p session to))
                (ebox--input-select session from to)))))
        ;; The release belongs to this press; anything else runs normally.
        (unless (and (consp next) (eq (event-basic-type next) 'mouse-1)
                     (not (memq 'down (event-modifiers next))))
          (push next unread-command-events)))
      (pcase count
        (2 (ebox--input-select-unit session 'word))
        (3 (ebox--input-select-unit session 'all))))))

(defun ebox--input-pointer (session event)
  "Place SESSION's caret and region from mouse EVENT, or leave the field."
  (let* ((end (event-end event))
         (window (posn-window end))
         (buffer (ebox-mount-buffer (ebox--input-session-mount session))))
    (when (and (windowp window) (eq (window-buffer window) buffer)
               (null (posn-area end)) (integerp (posn-point end)))
      (let* ((pos (posn-point end))
             (from (posn-point (event-start event)))
             (owner (ebox--keymap-owner (ebox--input-session-node session)))
             (control (ebox--event-owner pos)))
        ;; A nested control owns this click, but is not outside the field's
        ;; frame.  Its callback may explicitly finish editing; otherwise keep
        ;; the session and caret, rather than treating its release as leaving.
        (unless (and owner control (not (eq owner control))
                     (ebox-node-ancestor-p owner control))
          (if (not (ebox--input-inside-p session pos))
              (ebox--input-leave session)
            (ebox--input-select
             session (if (and (integerp from) (ebox--input-inside-p session from)) from pos)
             pos)))))))

(defun ebox--input-post-command ()
  "Show the effect of the last command on the current buffer's session."
  (when-let* ((session (ebox--input-current)))
    (let ((event (if (and (consp last-command-event)
                          (memq 'down (event-modifiers last-command-event))
                          (consp last-input-event))
                     ;; A press tracker consumed the release: judge by it.
                     last-input-event
                   last-command-event)))
      (cond
       ((ebox--input-session-turn session)
        (setf (ebox--input-session-held session) t)
        (ebox--input-sync session))
       ((eq this-command #'ebox--input-track-pointer))
       ((and (consp event)
             (memq (event-basic-type event) '(mouse-1 mouse-2 mouse-3))
             (cl-intersection '(click drag) (event-modifiers event)))
        (ebox--input-pointer session event))
       ((and (ebox--input-session-held session)
             (or (integerp event) (and event (symbolp event))))
        (ebox--input-place-point session))))
    (when (and (not (ebox--input-session-done session))
               (ebox--input-session-held session))
      (setq disable-point-adjustment t))))

;;;; Session lifecycle

(defun ebox--input-external-text (node string)
  "Handle STRING set on NODE while an input session edits it.
Return non-nil when NODE is edited.  The session's own value is ignored;
another string replaces the value, clears undo and puts the caret at its end."
  (when-let* ((session (cl-find node ebox--input-sessions
                                :key #'ebox--input-session-node)))
    (unless (equal string (ebox--input-session-value session))
      (with-current-buffer (ebox--input-session-shadow session)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (substring-no-properties string)))
        (setq buffer-undo-list nil)
        (deactivate-mark))
      (setf (ebox--input-session-value session) (substring-no-properties string)
            (ebox--input-session-preedit session) nil)
      (ebox--input-show session))
    t))

(setq ebox--input-text-function #'ebox--input-external-text)

(defun ebox-input-begin (buffer-or-name node &rest options)
  "Begin native editing of text NODE in BUFFER-OR-NAME and return a session.
The node's text becomes the session value with the caret at its end.  Keys
typed in the buffer while the session is active edit that value with their
ordinary Emacs commands: insertion, deletion, motion, kill and yank, undo,
the region and input methods.  The node keeps its layout and displays each
edit immediately, so wrapping, padding and borders stay in place; point
follows the caret and a click inside the node's box moves it.

OPTIONS is a plist.  :on-change is called with the new value after each
command that changes it.  :keymap holds bindings consulted first; they run
in BUFFER-OR-NAME, except the commands in `ebox-input-edit-commands', which
edit the value.  :on-leave is called without arguments when a later click lands
outside the node's box; the opening gesture is not a leave event.
:local-variables is an alist of buffer-local
settings, such as `completion-at-point-functions', for the commands editing
the value.  :caret is a value offset placing the caret; without it a fresh
session opens at the end, while a session whose node text is unchanged
since the last one reuses its editing buffer and keeps the previous caret,
region and undo history.  Setting the node's text to another string
replaces the value and clears its undo history.

An unmounted buffer, a node that is not laid-out text and a second session
in the same buffer are `ebox-input-error's."
  (let ((mount (ebox-buffer-mount buffer-or-name))
        (keymap (plist-get options :keymap)))
    (unless mount (signal 'ebox-input-error (list "Expected a mounted Ebox buffer")))
    (when (ebox-mount-session mount)
      (signal 'ebox-input-error (list "Buffer already has an input session")))
    (unless (and (ebox-node-p node) (ebox-node-text-p node)
                 (ebox--node-live-p node mount))
      (signal 'ebox-input-error (list "Expected a mounted text node" node)))
    (when (and keymap (not (keymapp keymap)))
      (signal 'ebox-input-error (list "Expected a keymap" keymap)))
    (let* ((value (substring-no-properties (ebox-node-text node)))
           (cached (gethash node ebox--input-shadow-cache))
           (cached-p (and (buffer-live-p cached)
                          (with-current-buffer cached
                            (equal (buffer-substring-no-properties (point-min) (point-max))
                                   value))))
           (shadow (if cached-p cached (generate-new-buffer " *ebox-input*" t)))
           (session (ebox--input-session-make
                     :mount mount :node node :shadow shadow :keymap keymap
                     :on-change (plist-get options :on-change)
                     :on-leave (plist-get options :on-leave)
                     ;; The command opening the editor already consumed its
                     ;; activation gesture.  Its release must not immediately
                     ;; count as a click outside this newly opened field.
                     ;; The next pre-command hook resets TURN normally.
                     :value value :held t :turn t
                     :emulation (and keymap (list (cons t keymap))))))
      (with-current-buffer shadow
        (unless cached-p
          (erase-buffer)
          (insert value)
          (setq buffer-undo-list nil))
        (when-let* ((caret (plist-get options :caret)))
          (goto-char (min (point-max) (max (point-min) (1+ (max 0 (truncate caret)))))))
        (dolist (binding (plist-get options :local-variables))
          (set (make-local-variable (car binding)) (cdr binding))))
      (with-current-buffer (ebox-mount-buffer mount)
        (setf (ebox-mount-session mount) session)
        (push session ebox--input-sessions)
        (ebox--input-special-install)
        (push (list node) ebox--editing)
        (when (ebox--input-session-emulation session)
          (setq-local emulation-mode-map-alists
                      (cons (ebox--input-session-emulation session)
                            emulation-mode-map-alists)))
        (add-hook 'pre-command-hook #'ebox--input-pre-command nil t)
        (add-hook 'post-command-hook #'ebox--input-post-command nil t)
        (when mark-active (deactivate-mark))
        ;; A fresh string makes the paragraph rebuild its pieces, which now
        ;; carry the value offsets.
        (ebox--mutation
          (setf (ebox-node-text node) (copy-sequence value))
          (ebox--mark node ebox--d-layout))
        (ebox--input-place-point session))
      session)))

(defun ebox-input-text (session)
  "Return SESSION's current value, or nil once it ended."
  (ebox--input-check session)
  (unless (ebox--input-session-done session)
    (ebox--input-session-value session)))

(defun ebox-input-session-node (session)
  "Return the node SESSION edits."
  (ebox--input-check session)
  (ebox--input-session-node session))

(defun ebox--input-release (session)
  "Detach SESSION from its buffers without repainting its node."
  (unless (ebox--input-session-done session)
    (setf (ebox--input-session-done session) t
          (ebox--input-session-held session) nil)
    (let* ((mount (ebox--input-session-mount session))
           (node (ebox--input-session-node session))
           (buffer (ebox-mount-buffer mount))
           (shadow (ebox--input-session-shadow session)))
      (setq ebox--input-sessions (delq session ebox--input-sessions)
            ebox--editing (assq-delete-all node ebox--editing))
      (ebox--input-special-uninstall)
      (when (eq (ebox-mount-session mount) session)
        (setf (ebox-mount-session mount) nil))
      (mapc #'delete-overlay (ebox--input-session-overlays session))
      (setf (ebox--input-session-overlays session) nil)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (remove-hook 'pre-command-hook #'ebox--input-pre-command t)
          (remove-hook 'post-command-hook #'ebox--input-post-command t)
          (when (ebox--input-session-emulation session)
            (setq-local emulation-mode-map-alists
                        (delq (ebox--input-session-emulation session)
                              emulation-mode-map-alists)))))
      (if (and (buffer-live-p shadow)
               (eq (ebox-buffer-mount (ebox-mount-buffer mount)) mount)
               (ebox--node-live-p node mount))
          (puthash node shadow ebox--input-shadow-cache)
        (when (buffer-live-p shadow) (kill-buffer shadow))))))

(defun ebox-input-end (session)
  "End SESSION and return its value.
The node keeps displaying the value without preedit.  Ending a session that
already ended, for example after its buffer was unmounted, returns nil."
  (ebox--input-check session)
  (unless (ebox--input-session-done session)
    (let* ((value (ebox--input-session-value session))
           (mount (ebox--input-session-mount session))
           (node (ebox--input-session-node session)))
      (ebox--input-release session)
      (when (and (eq (ebox-buffer-mount (ebox-mount-buffer mount)) mount)
                 (ebox--node-live-p node mount))
        (ebox--mutation
          (setf (ebox-node-text node) (copy-sequence value))
          (ebox--mark node ebox--d-layout)))
      value)))

;;;; Interaction navigation

(defun ebox--interaction-move (count)
  "Move point COUNT keymap owners forward (negative: backward)."
  (unless (ebox-buffer-mount) (user-error "Current buffer has no Ebox tree"))
  (if (zerop count) (point)
    (let* ((origin (point))
           (current (and (< origin (point-max)) (ebox--event-owner origin)))
           (seen (make-hash-table :test 'eq))
           (position (point-min)) stops)
      (while (< position (point-max))
        (let* ((end (next-single-property-change position 'ebox-node nil (point-max)))
               (owner (ebox--event-owner position)))
          (while (and (< position end) (eq (char-after position) ?\n))
            (setq position (1+ position)))
          (when (and owner (< position end) (not (gethash owner seen)))
            (puthash owner t seen)
            (push (cons position owner) stops))
          (setq position end)))
      (when (> count 0) (setq stops (nreverse stops)))
      (let* ((eligible (cl-remove-if-not
                        (lambda (stop)
                          (and (not (eq (cdr stop) current))
                               (if (> count 0) (> (car stop) origin) (< (car stop) origin))))
                        stops))
             (target (nth (1- (abs count)) eligible)))
        (unless target
          (user-error "No %s Ebox interaction" (if (> count 0) "next" "previous")))
        (goto-char (car target))))))

(defun ebox-next-interaction (&optional count)
  "Move point to the next keymap owner COUNT times; return the position."
  (interactive "p")
  (ebox--interaction-move (or count 1)))

(defun ebox-previous-interaction (&optional count)
  "Move point to the previous keymap owner COUNT times; return the position."
  (interactive "p")
  (ebox--interaction-move (- (or count 1))))

;;;; Hover content

(defun ebox--hover-target (node)
  "Return the text node whose content NODE's :hover-content replaces."
  (if (eq (ebox-node-tag node) 'text) node
    (let (found)
      (ebox--do-kids (child node)
        (when (and (not found) (eq (ebox-node-tag child) 'text))
          (setq found child)))
      found)))

(defun ebox--hover-group (node)
  "Return NODE's hover group key, or NODE itself."
  (or (plist-get (ebox-node-inter node) :hover-group) node))

(defun ebox--hover-owner (position)
  "Return the innermost node with :hover-content painted at POSITION."
  (let ((node (and (< position (point-max)) (get-text-property position 'ebox-node))))
    (while (and node (not (plist-get (ebox-node-inter node) :hover-content)))
      (setq node (ebox-node-parent node)))
    node))

(defun ebox--hover-members (mount group)
  "Return MOUNT's hover-content nodes in GROUP."
  (if (ebox-node-p group) (list group)
    (let (members)
      (ebox-node-walk (ebox-mount-root mount)
                      (lambda (node)
                        (let ((inter (ebox-node-inter node)))
                          (when (and (plist-get inter :hover-content)
                                     (equal (plist-get inter :hover-group) group))
                            (push node members)))))
      members)))

(defun ebox--hover-restore (mount)
  "Restore the text replaced by MOUNT's active hover group."
  (ebox-with-batch
    (dolist (entry (ebox-mount-hover-saved mount))
      (when (ebox-node-parent (car entry))
        (ebox-node-set-text (car entry) (cdr entry)))))
  (setf (ebox-mount-hover mount) nil
        (ebox-mount-hover-saved mount) nil))

(defun ebox--hover-activate (mount group)
  "Show the :hover-content of every member of GROUP in MOUNT."
  (let (saved)
    (ebox-with-batch
      (dolist (node (ebox--hover-members mount group))
        (let* ((target (ebox--hover-target node))
               (value (plist-get (ebox-node-inter node) :hover-content))
               (content (if (functionp value)
                            (with-current-buffer (ebox-mount-buffer mount) (funcall value))
                          value)))
          (when (and target (stringp content))
            (push (cons target (ebox-node-text target)) saved)
            (ebox-node-set-text target content)))))
    (setf (ebox-mount-hover mount) group
          (ebox-mount-hover-saved mount) saved)))

(defvar-local ebox--pointer-hover-node nil
  "Node whose :hover-style paints under the pointer in this buffer.")
(defvar-local ebox--pointer-help nil
  "Effective help the pointer last reported in this buffer, or nil.")
(defvar ebox--pointer-hover-buffer nil
  "Mounted buffer currently owning pointer hover paint.")

(defun ebox--clear-pointer-hover ()
  "Remove pointer paint from the current buffer without changing its text."
  (let ((node ebox--pointer-hover-node))
    (setq ebox--pointer-hover-node nil)
    (when (eq ebox--pointer-hover-buffer (current-buffer))
      (setq ebox--pointer-hover-buffer nil))
    (when (and (ebox-node-p node) (ebox--node-live-p node ebox--buffer-mount))
      (setf (ebox-node-hover node) nil)
      (ebox--mutation (ebox--mark node ebox--d-style)))))

(defun ebox--paint-pointer-hover (node)
  "Paint NODE's `:hover-style' in the current buffer, or clear it for nil.
NODE is restyled through its own computed paint, so a hovered control keeps
its border radius and its padding coverage.  A detached previous target
cannot repaint and keeps no allocated paint."
  (unless (eq node ebox--pointer-hover-node)
    (ebox--mutation
      (let ((old ebox--pointer-hover-node))
        (when (and (ebox-node-p old) (ebox--node-live-p old ebox--buffer-mount))
          (setf (ebox-node-hover old) nil)
          (ebox--mark old ebox--d-style))
        (when (and (ebox-node-p node) (ebox--node-live-p node ebox--buffer-mount))
          (setf (ebox-node-hover node) t)
          (ebox--mark node ebox--d-style))))
    (setq ebox--pointer-hover-node (and (ebox-node-p node) node)
          ebox--pointer-hover-buffer (and (ebox-node-p node) (current-buffer)))))

(defun ebox--pointer-hover-owner (point)
  "Return the owner of the hover face painted at POINT, respecting nil blockers."
  (when (and (integer-or-marker-p point) (< point (point-max))
             (get-text-property point 'mouse-face))
    (let ((node (get-text-property point 'ebox-node)))
      (while (and node (not (plist-member (ebox-node-inter node) :hover-style)))
        (setq node (ebox-node-parent node)))
      node)))

(defconst ebox-hover-guard-interval 0.1
  "Seconds between pointer checks while feedback is painted.")

(defvar-local ebox--hover-guard-timer nil
  "Timer that keeps pointer feedback valid while it paints in this buffer.")

(defun ebox--pointer-buffer-position (window)
  "Return WINDOW's buffer position under the mouse pointer, or nil.
Window chrome, another window, another frame or an unknown pointer reports
nil.  The pointer is resolved inside its own frame: `mouse-pixel-position'
and `window-pixel-edges' share the frame's origin.  A child frame can be
placed relative to its parent while its reported absolute edges omit that
origin, so measuring the display-absolute pointer against those edges would
hit-test the rows below the pointer instead of the row under it."
  (let* ((mouse (mouse-pixel-position))
         (frame (car-safe mouse))
         (x (car-safe (cdr-safe mouse)))
         (y (cdr-safe (cdr-safe mouse))))
    (when (and (eq frame (window-frame window)) (numberp x) (numberp y))
      (let* ((edges (window-pixel-edges window))
             (left (- x (nth 0 edges)))
             (top (- y (nth 1 edges))))
        ;; The pointer can be beside or above the window — on the mode line,
        ;; a header line, another window — and those offsets are negative.
        ;; `posn-at-x-y' signals on them, so report no position instead.
        (when (and (>= left 0) (>= top 0))
          (let ((posn (posn-at-x-y left top window t)))
            (when (and (eq (posn-window posn) window)
                       (null (posn-area posn))
                       (integer-or-marker-p (posn-point posn)))
              (posn-point posn))))))))

(defun ebox--pointer-enter (window position)
  "Adopt pointer hover at POSITION in WINDOW.
The painted help-echo probe calls this on pointer movement, which needs no
`track-mouse'.  A guard timer follows the pointer until no feedback remains,
so leaving the buffer never turns motion over other windows into input here."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (integer-or-marker-p position)
             (bound-and-true-p ebox-buffer-mode)
             (ebox-buffer-mount))
    (ebox--update-pointer-hover position nil)
    (unless (timerp ebox--hover-guard-timer)
      (setq ebox--hover-guard-timer
            (run-at-time ebox-hover-guard-interval nil
                         #'ebox--hover-guard (current-buffer))))))

(defun ebox--hover-guard (buffer)
  "Follow the pointer while BUFFER paints pointer feedback.
Refresh the pointed node while the pointer is over BUFFER, and release the
paint once it is not.  Stop when nothing is painted."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (not (and (bound-and-true-p ebox-buffer-mode)
                    (ebox-buffer-mount)
                    (or ebox--pointer-hover-node
                        (ebox-mount-hover ebox--buffer-mount))))
          (setq ebox--hover-guard-timer nil)
        (let* ((mouse (mouse-position))
               (frame (car mouse))
               ;; The pointer can sit outside the frame — on another display, a
               ;; menu bar, or past the edge — where its cell coordinates are
               ;; negative.  `window-at' signals on those, so treat them as "not
               ;; over this buffer" instead.
               (at (and (cdr mouse)
                        (wholenump (cadr mouse))
                        (wholenump (cddr mouse))
                        (window-at (cadr mouse) (cddr mouse) frame)))
               (position (and (windowp at)
                              (eq frame (window-frame at))
                              (eq (window-buffer at) buffer)
                              (ebox--pointer-buffer-position at))))
          (if position
              (progn
                (ebox--update-pointer-hover position nil)
                (setq ebox--hover-guard-timer
                      (run-at-time ebox-hover-guard-interval nil
                                   #'ebox--hover-guard buffer)))
            (ebox--pointer-leave)))))))

(defun ebox--update-pointer-hover (position area)
  "Paint pointer feedback for POSITION in the current buffer.
AREA non-nil means POSITION is window chrome rather than text, so feedback
clears."
  (let ((inside (null area)))
    (ebox--paint-pointer-hover
     (and inside (ebox--pointer-hover-owner position)))
    (when ebox--buffer-mount
      (let* ((owner (and inside (integer-or-marker-p position)
                         (ebox--hover-owner position)))
             (group (and owner (ebox--hover-group owner))))
        (unless (equal group (ebox-mount-hover ebox--buffer-mount))
          (when (ebox-mount-hover ebox--buffer-mount)
            (ebox--hover-restore ebox--buffer-mount))
          (when group
            (ebox--hover-activate ebox--buffer-mount group)))))))

(defun ebox--pointer-leave ()
  "Release pointer feedback in the current buffer and stop tracking.
Keyboard focus keeps showing its own `:hover-content'."
  (ebox--clear-pointer-hover)
  (when-let* ((mount ebox--buffer-mount))
    (when (ebox-mount-hover mount)
      (ebox--hover-restore mount)
      (ebox--focus-hover mount (ebox-mount-focus mount))))
  (setq-local ebox--pointer-help nil)
  (when (timerp ebox--hover-guard-timer)
    (cancel-timer ebox--hover-guard-timer))
  (setq ebox--hover-guard-timer nil)
  (kill-local-variable 'track-mouse))

(defun ebox--hover-event (event)
  "Update pointer feedback for mouse-movement EVENT.
The event window decides: motion inside this mounted buffer paints the pointed
node, and motion anywhere else releases the feedback.  A painted help-echo
probe reports entry, and the pointer guard refreshes or releases the paint
while it is active."
  (interactive "e")
  (clear-this-command-keys)
  (let* ((position (event-end event))
         (window (and (consp position) (posn-window position)))
         (point (and (consp position) (posn-point position)))
         (area (and (consp position) (posn-area position)))
         (buffer (and (window-live-p window) (window-buffer window)))
         (mount (and buffer (ebox-buffer-mount buffer))))
    (when (and (buffer-live-p ebox--pointer-hover-buffer)
               (not (eq buffer ebox--pointer-hover-buffer)))
      (with-current-buffer ebox--pointer-hover-buffer
        (ebox--pointer-leave)))
    (if (and mount (eq buffer (current-buffer)))
        (with-current-buffer buffer
          (ebox--update-pointer-hover point area))
      (ebox--pointer-leave))))

;;;; Scrolling

(defvar ebox-scroll-step 3
  "Lines scrolled by one wheel step or `ebox-scroll-down'.")

(defun ebox--scrollable-p (node)
  "Return non-nil when NODE clips scrollable content."
  (let ((geo (ebox-node-layout node)))
    (and geo (memq (ebox-cs-overflow (ebox-node-cs node)) '(scroll auto))
         (> (ebox-geo-ch geo) (ebox-geo-vh geo)))))

(defun ebox--scroll-chain (position)
  "Return scrollable nodes containing buffer POSITION, innermost first."
  (let ((node (and (integer-or-marker-p position) (ebox-node-at position)))
        chain)
    (while node
      (when (ebox--scrollable-p node) (push node chain))
      (setq node (if (and (ebox-node-cs node) (ebox--abs-p node))
                     (ebox-node-host node)
                   (ebox-node-parent node))))
    (nreverse chain)))

(defun ebox-node-scroll-offset (node)
  "Return NODE's scroll offset in lines.
A laid-out node reports the offset it shows: an offset past content that
shrank clamps to the content's end."
  (let ((geo (ebox-node-layout node))
        (offset (ebox-node-scroll node)))
    (if geo
        (max 0 (min offset (- (ebox-geo-ch geo) (ebox-geo-vh geo))))
      offset)))

(defun ebox-node-set-scroll (node offset)
  "Scroll NODE's content to OFFSET lines, clamped; return the applied offset.
Reaching the last line pins a `:scroll-anchor end' node there, so it keeps
showing the end as content grows; any smaller offset releases the pin.
A changed offset is reported to NODE's `:scroll' function after settling."
  (let* ((geo (ebox-node-layout node))
         (limit (if geo (max 0 (- (ebox-geo-ch geo) (ebox-geo-vh geo))) 0))
         (offset (max 0 (min offset limit)))
         (shown (ebox-node-scroll-offset node)))
    (setf (ebox-node-pinned node) (>= offset limit)
          (ebox-node-scroll node) offset)
    (unless (= offset shown)
      (let ((mount (ebox--mount-of node)))
        (if (and geo mount (zerop (logand (ebox-node-dirty node) 15)))
            ;; Scrolling changes which content lines show, not the layout.
            (progn
              (setf (ebox-geo-scroll geo) offset)
              (push (list node 0 (ebox-node-h node) (ebox-node-h node))
                    (ebox-mount-report mount))
              (ebox--enqueue node))
          (ebox--mark node ebox--d-layout))
        (ebox--settle))
      (when-let* ((fn (plist-get (ebox-node-inter node) :scroll)))
        (funcall fn offset)))
    offset))

(defun ebox-node-scroll-into-view (node &optional align)
  "Scroll NODE's scrolling ancestors so its lines show; return NODE.
Each scroller, innermost first, moves the least distance that shows NODE's
margin box, or its top when NODE is taller than the viewport.  ALIGN
`start' or `end' instead puts NODE's top at the scroller's first line or
its bottom at the last line, as far as the content allows."
  (unless (memq align '(nil start end))
    (signal 'wrong-type-argument (list '(member nil start end) align)))
  (let ((scroller (ebox--clip-parent node)))
    (while scroller
      (when (ebox--scrollable-p scroller)
        (let* ((geo (ebox-node-layout scroller))
               (offset (ebox-geo-scroll geo))
               (top (+ (- (ebox--item-top-in-root node)
                          (ebox--item-top-in-root scroller)
                          (ebox-geo-mt geo) (ebox-geo-pt geo))
                       offset))
               (bottom (+ top (ebox-node-h node)))
               (vh (ebox-geo-vh geo)))
          (cond ((eq align 'start) (ebox-node-set-scroll scroller top))
                ((eq align 'end) (ebox-node-set-scroll scroller (- bottom vh)))
                ((< top offset) (ebox-node-set-scroll scroller top))
                ((> bottom (+ offset vh))
                 (ebox-node-set-scroll scroller (min top (- bottom vh)))))))
      (setq scroller (ebox--clip-parent scroller))))
  node)

(defun ebox--scroll-by (delta position fallback)
  "Scroll the node chain at POSITION by DELTA lines; FALLBACK gets the rest."
  (let ((rest delta))
    (dolist (node (ebox--scroll-chain position))
      (unless (zerop rest)
        (let* ((old (ebox-node-scroll-offset node))
               (new (ebox-node-set-scroll node (+ old rest))))
          (setq rest (- rest (- new old))))))
    (unless (zerop rest)
      (condition-case nil
          (funcall fallback rest)
        ((beginning-of-buffer end-of-buffer) nil)))))

(defun ebox--tree-fits-window-p (window)
  "Return non-nil when WINDOW's whole buffer fits its body.
The pixels are measured, not counted in lines: a wrapped or styled row is
taller than one line, and the last row of a canvas often ends in padding
cells, so neither line counts nor `pos-visible-in-window-p' answers whether
the picture is complete."
  (when (window-live-p window)
    (let ((body (window-body-height window t)))
      (<= (cdr (window-text-pixel-size window (point-min) (point-max)
                                       nil (1+ body)))
          body))))

(defun ebox--scroll-window (lines)
  "Scroll the selected window by LINES that no scroller consumed.
A mounted tree that fits its window keeps its pinned top and bottom rows in
place: the canvas already shows everything, so scrolling it would slide the
whole page instead of revealing content."
  (if (> lines 0)
      (unless (ebox--tree-fits-window-p (selected-window))
        (scroll-up lines))
    (scroll-down (- lines))))

(defun ebox-scroll-down (&optional n)
  "Scroll the content at point down by N lines (default `ebox-scroll-step')."
  (interactive "p")
  (ebox--scroll-by (or n ebox-scroll-step) (point) #'ebox--scroll-window))

(defun ebox-scroll-up (&optional n)
  "Scroll the content at point up by N lines (default `ebox-scroll-step')."
  (interactive "p")
  (ebox-scroll-down (- (or n ebox-scroll-step))))

(defun ebox--page-lines (arg)
  "Return the page size in lines for prefix ARG."
  (if arg (prefix-numeric-value arg)
    (max 1 (- (window-body-height) next-screen-context-lines))))

(defun ebox-scroll-page-down (&optional arg)
  "Scroll the content at point down by a page, or ARG lines."
  (interactive "P")
  (ebox-scroll-down (ebox--page-lines arg)))

(defun ebox-scroll-page-up (&optional arg)
  "Scroll the content at point up by a page, or ARG lines."
  (interactive "P")
  (ebox-scroll-up (ebox--page-lines arg)))

(defun ebox--wheel (event delta)
  "Scroll the content under wheel EVENT by DELTA lines."
  (let* ((start (event-start event))
         (window (posn-window start)))
    (if (and (window-live-p window) (null (posn-area start))
             (ebox-buffer-mount (window-buffer window)))
        (with-selected-window window
          (ebox--scroll-by delta (posn-point start) #'ebox--scroll-window))
      (mwheel-scroll event))))

(defun ebox-wheel-scroll-down (event)
  "Scroll the content under wheel EVENT down."
  (interactive "e")
  (ebox--wheel event ebox-scroll-step))

(defun ebox-wheel-scroll-up (event)
  "Scroll the content under wheel EVENT up."
  (interactive "e")
  (ebox--wheel event (- ebox-scroll-step)))

;;;; Swipe gestures

(defvar ebox-swipe-distance 60
  "Horizontal pixels a two-finger gesture travels before it counts as a swipe.")

(defvar ebox-swipe-quiet 0.35
  "Seconds without horizontal wheel events that end a swipe gesture.
Momentum events continue the gesture, so one physical swipe fires once; a
change of direction starts the next gesture at once, so swiping left and
right in a row fires each time without waiting for the momentum to stop.")

(defvar ebox--swipe-state nil
  "Current gesture as (TIME DIRECTION DISTANCE FIRED).")

(defun ebox--swipe-direction (event)
  "Return the finger direction, `left' or `right', of horizontal wheel EVENT.
macOS natural scrolling reports fingers moving right as `wheel-left';
`mouse-wheel-flip-direction' reverses the mapping."
  (let ((right (eq (event-basic-type event) 'wheel-left)))
    (if (bound-and-true-p mouse-wheel-flip-direction)
        (if right 'left 'right)
      (if right 'right 'left))))

(defun ebox--swipe-target (position)
  "Return the innermost enabled node with a `:swipe' handler at POSITION."
  (let ((node (and (integer-or-marker-p position) (ebox-node-at position)))
        found)
    (while (and node (not found))
      (let ((inter (ebox-node-inter node)))
        (if (and (plist-get inter :swipe) (not (plist-get inter :disabled)))
            (setq found node)
          (setq node (if (and (ebox-node-cs node) (ebox--abs-p node))
                         (ebox-node-host node)
                       (ebox-node-parent node))))))
    found))

(defun ebox-wheel-swipe (event)
  "Recognize a horizontal two-finger swipe from wheel EVENT.
Accumulate one gesture's horizontal travel and, once it reaches
`ebox-swipe-distance', call the `:swipe' handler of the innermost node under
the pointer once with the finger direction.  Later events of the same
gesture, including momentum, are absorbed; a change of direction starts the
next gesture immediately, so consecutive left and right swipes each fire."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start))
         (now (float-time))
         (direction (ebox--swipe-direction event))
         (delta (nth 4 event))
         (travel (if (and (consp delta) (numberp (car delta)))
                     (abs (car delta))
                   ebox-swipe-distance))
         (state ebox--swipe-state))
    ;; Momentum keeps the fired gesture's direction, so the opposite way is
    ;; the reader swiping back at once; it begins a new gesture without a
    ;; quiet pause, or a repeated swipe would be swallowed.
    (when (or (null state) (> (- now (nth 0 state)) ebox-swipe-quiet)
              (not (eq direction (nth 1 state))))
      (setq state (list now direction 0 nil)))
    (setf (nth 0 state) now
          (nth 2 state) (+ (nth 2 state) travel))
    (setq ebox--swipe-state state)
    (when (and (not (nth 3 state)) (>= (nth 2 state) ebox-swipe-distance)
               (window-live-p window) (null (posn-area start)))
      (setf (nth 3 state) t)
      (with-current-buffer (window-buffer window)
        (when-let* ((node (ebox--swipe-target (posn-point start))))
          (funcall (plist-get (ebox-node-inter node) :swipe) direction))))))

;;;; Buffer mode

(defvar ebox-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    ;; A mounted canvas is application output: unbound printing keys must
    ;; not type into it.  Input sessions disable the mode while they edit.
    (suppress-keymap map t)
    (dolist (area '(nil right-fringe left-fringe right-margin left-margin))
      (let ((prefix (if area (vector area) [])))
        (dolist (event '(wheel-down double-wheel-down triple-wheel-down mouse-5))
          (define-key map (vconcat prefix (vector event)) #'ebox-wheel-scroll-down))
        (dolist (event '(wheel-up double-wheel-up triple-wheel-up mouse-4))
          (define-key map (vconcat prefix (vector event)) #'ebox-wheel-scroll-up))))
    (dolist (event '(wheel-left double-wheel-left triple-wheel-left
                     wheel-right double-wheel-right triple-wheel-right))
      (define-key map (vector event) #'ebox-wheel-swipe))
    (define-key map [remap scroll-up-command] #'ebox-scroll-page-down)
    (define-key map [remap scroll-down-command] #'ebox-scroll-page-up)
    (define-key map (kbd "n") #'ebox-scroll-down)
    (define-key map (kbd "p") #'ebox-scroll-up)
    (dolist (key '("C-v" "<next>" "<kp-next>" "SPC"))
      (define-key map (kbd key) #'ebox-scroll-page-down))
    (dolist (key '("M-v" "<prior>" "<kp-prior>" "S-SPC" "<backspace>"))
      (define-key map (kbd key) #'ebox-scroll-page-up))
    (define-key map (kbd "q") #'quit-window)
    (dolist (key '("TAB" "<tab>"))
      (define-key map (kbd key) (lambda () (interactive) (ebox-focus-next 1 t))))
    (dolist (key '("S-TAB" "<backtab>"))
      (define-key map (kbd key) (lambda () (interactive) (ebox-focus-previous 1 t))))
    (dolist (key '("RET" "<return>"))
      (define-key map (kbd key) #'ebox-activate))
    (dolist (entry '((down "<down>" "C-n") (up "<up>" "C-p")
                     (left "<left>" "C-b") (right "<right>" "C-f")))
      (dolist (key (cdr entry))
        (define-key map (kbd key) (ebox--direction-command (car entry)))))
    (dolist (key '("<home>" "M-<"))
      (define-key map (kbd key) (lambda () (interactive) (ebox-focus-edge nil))))
    (dolist (key '("<end>" "M->"))
      (define-key map (kbd key) (lambda () (interactive) (ebox-focus-edge t))))
    (define-key map [mouse-movement] #'ebox--hover-event)
    ;; Painted cells are not a text selection: a press or drag only moves
    ;; point, so dragging over the canvas never paints a region.
    (dolist (event '(down-mouse-1 drag-mouse-1))
      (define-key map (vector event) #'mouse-set-point))
    map)
  "Keymap of mounted Ebox buffers: scrolling, focus navigation and activation.
Arrows and C-n/C-p/C-b/C-f move focus with `ebox-focus-direction', scrolling
when no stop lies above or below; Home/End and M-</M-> reach the group's or
scope's first and last stop.")

(defun ebox--refuse-mark ()
  "Deactivate a mark activated over a mounted canvas.
The canvas has no text selection; an input session keeps its own region."
  (deactivate-mark))

(defconst ebox--scroll-overridden-modes '(pixel-scroll-precision-mode pixel-scroll-mode)
  "Minor modes whose wheel bindings Ebox buffers override locally.")

(defvar-local ebox--saved-overline-margin nil
  "Original local flag and value of `overline-margin' while the mode is on.")

(defvar-local ebox--saved-show-paren nil
  "Original local flag and value of `show-paren-mode' while the mode is on.")

(define-minor-mode ebox-buffer-mode
  "Minor mode for mounted Ebox buffers."
  :lighter " Ebox"
  :keymap ebox-buffer-mode-map
  (if ebox-buffer-mode
      (progn
        (unless ebox--saved-overline-margin
          (setq ebox--saved-overline-margin
                (cons (local-variable-p 'overline-margin) overline-margin)))
        ;; Overlines otherwise add ascent to rows with a top border.
        (setq-local overline-margin 0)
        ;; Painted text is not code: paren matching would tint layout cells.
        (unless ebox--saved-show-paren
          (setq ebox--saved-show-paren
                (cons (local-variable-p 'show-paren-mode)
                      (bound-and-true-p show-paren-mode))))
        (setq-local show-paren-mode nil)
        (add-hook 'activate-mark-hook #'ebox--refuse-mark nil t)
        (add-hook 'mouse-leave-buffer-hook #'ebox--pointer-leave nil t)
        (add-hook 'kill-buffer-hook #'ebox--clear-pointer-hover nil t)
        (setq-local minor-mode-overriding-map-alist
                    (append (mapcar (lambda (mode) (cons mode ebox-buffer-mode-map))
                                    ebox--scroll-overridden-modes)
                            (cl-remove-if (lambda (entry)
                                            (memq (car entry) ebox--scroll-overridden-modes))
                                          minor-mode-overriding-map-alist))))
    (setq-local minor-mode-overriding-map-alist
                (cl-remove-if (lambda (entry)
                                (memq (car entry) ebox--scroll-overridden-modes))
                              minor-mode-overriding-map-alist))
    (remove-hook 'activate-mark-hook #'ebox--refuse-mark t)
    (remove-hook 'mouse-leave-buffer-hook #'ebox--pointer-leave t)
    (remove-hook 'kill-buffer-hook #'ebox--clear-pointer-hover t)
    (ebox--clear-pointer-hover)
    (when (timerp ebox--hover-guard-timer)
      (cancel-timer ebox--hover-guard-timer))
    (setq ebox--hover-guard-timer nil)
    (kill-local-variable 'ebox--pointer-help)
    (when ebox--saved-overline-margin
      (if (car ebox--saved-overline-margin)
          (setq-local overline-margin (cdr ebox--saved-overline-margin))
        (kill-local-variable 'overline-margin))
      (setq ebox--saved-overline-margin nil))
    (when ebox--saved-show-paren
      (if (car ebox--saved-show-paren)
          (setq-local show-paren-mode (cdr ebox--saved-show-paren))
        (kill-local-variable 'show-paren-mode))
      (setq ebox--saved-show-paren nil))
    (kill-local-variable 'track-mouse)))

;;;; Selector queries

(defun ebox-selector-query (root selector)
  "Return ROOT's descendants-or-self matching SELECTOR in document order."
  (let ((selector (if (stringp selector) (ecss-selector-parse selector) selector))
        (ebox--current-mount (ebox-node-mount (ebox-node-root root)))
        matches)
    (unless (ebox-mount-p ebox--current-mount) (setq ebox--current-mount nil))
    (ebox-node-walk root (lambda (node)
                           (when (ecss-selector-match-p selector node ebox--ecss-adapter)
                             (push node matches))))
    (nreverse matches)))

(defun ebox-selector-query-buffer (buffer-or-name selector)
  "Return nodes mounted in BUFFER-OR-NAME matching SELECTOR."
  (let ((root (ebox-buffer-root buffer-or-name)))
    (and root (ebox-selector-query root selector))))

(provide 'ebox-interaction)

;;; ebox-interaction.el ends here
