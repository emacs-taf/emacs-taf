;;; etaf-keys.el --- Scoped Host keys, regions and the command palette -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Host declares `:keys', a list of (KEY COMMAND [LABEL]) entries, and the
;; key works while focus (or point) is inside that Host.  Each Runtime buffer
;; owns one emulation keymap holding every key any Host has declared; each
;; binding is a menu-item filter that resolves the key when it is pressed:
;;
;; 1. The scope starts at the focused Host, else the Host at point.  When a
;;    visible `:focus-scope modal' Host does not contain it, the scope starts
;;    at that modal Host instead.  A pointer event (a wheel turn or a
;;    click) starts at the Host under the pointer, so a pane can bind the
;;    wheel for itself.
;; 2. The registered Host and its ancestors are searched nearest first; the
;;    search stops after the first `:focus-scope modal' or `:key-scope local'
;;    Host.  A disabled Host contributes no keys but still bounds the search.
;; 3. The first entry matching the key wins, except that RET activates a
;;    nearer enabled Host with a press handler, so a focused control keeps
;;    RET even when an enclosing Host binds it.  Without one, the framework
;;    defaults apply: `M-g' opens region selection, Escape dispatches the
;;    nearest `:on-dismiss', `?' opens `etaf-help', Tab moves one tab stop,
;;    and an arrow key runs `etaf-direction' (the nearest `:on-direction'
;;    handler, a focused separator or slider step, then movement inside the
;;    surrounding region and its adjacent regions).  A local or modal scope
;;    ignores unbound printing keys so they never reach the application
;;    behind it.
;; 4. Otherwise the key falls through to the buffer's other keymaps.  Keys
;;    also fall through while a native input session edits the buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-runtime)
(require 'etaf-events)
(require 'etaf-regions)

(defvar etaf--current-runtime)
(defvar etaf--current-event)
(defvar etaf--runtimes)
(defvar etaf--help-state)
(declare-function etaf-help "etaf-help" (&optional runtime))

(defvar-local etaf--keys-alist nil
  "Emulation keymap alist holding the Runtime's scoped key bindings.")
(put 'etaf--keys-alist 'permanent-local t)

(add-to-list 'emulation-mode-map-alists 'etaf--keys-alist)

(defconst etaf--keys-dismiss-events (list [escape])
  "Events that dismiss the nearest Host with `:on-dismiss'.
C-g is never bound: it keeps Emacs's native keyboard-quit semantics.")

(defconst etaf--keys-selector-event [?\M-g]
  "Event entering region selection; `etaf-region-select' answers it.")

(defconst etaf--keys-direction-events
  '(([left] . left) ([right] . right) ([up] . up) ([down] . down))
  "Arrow events mapped to direction symbols for `etaf-direction'.")

(defconst etaf--keys-control-direction-events
  '(([?\C-b] . left) ([?\C-f] . right) ([?\C-p] . up) ([?\C-n] . down))
  "Native direction aliases constrained inside a keyboard boundary.
Host bindings still take precedence over these non-reserved aliases.")

(defconst etaf--keys-edge-events
  '(([home] . nil) ([end] . t) ([?\M-<] . nil) ([?\M->] . t))
  "Native edge aliases constrained inside a keyboard boundary.
A cdr of t selects the last stop; nil selects the first.")

(defconst etaf--keys-vim-direction-events
  '(([?\h] . left) ([?\j] . down) ([?\k] . up) ([?\l] . right))
  "Vim direction events mapped to direction symbols.")

(defconst etaf--keys-tab-events
  (list (vconcat (kbd "TAB")) (vconcat (kbd "<tab>"))
        (vconcat (kbd "S-TAB")) (vconcat (kbd "<backtab>")))
  "Events that move focus one tab stop, in either terminal or GUI encoding.")

(defconst etaf--keys-backtab-events
  (list (vconcat (kbd "S-TAB")) (vconcat (kbd "<backtab>")))
  "Tab events that move focus backward.")

(defconst etaf--keys-reserved-events
  (append (list [escape] etaf--keys-selector-event [?\C-g] [??])
          etaf--keys-tab-events
          (mapcar #'car etaf--keys-direction-events))
  "Events a Host `:keys' may not bind as the first event of an entry.
Escape, the region selector entry, native quit, the help key, Tab and the
direction keys are framework-owned; applications express direction behavior
through `:on-direction' instead of binding these keys.")

(defun etaf-keymap-reserved-events (keymap)
  "Return the framework-reserved events bound at the top level of KEYMAP.
Escape, the region selector entry, native quit, `?', Tab and the direction
keys are framework-owned: no application or component scope may override
them, and direction behavior is expressed through `:on-direction' instead.
Return a list of event vectors in binding order, or nil when KEYMAP is nil,
not a keymap, or free of conflicts.  Component authors use this to reject a
caller-supplied `:keymap' during validation."
  (when (keymapp keymap)
    (let (conflicts)
      (map-keymap
       (lambda (event _binding)
         (let ((sequence (vector event)))
           (when (member sequence etaf--keys-reserved-events)
             (push sequence conflicts))))
       keymap)
      (nreverse conflicts))))

(defvar etaf-direction-scheme 'arrows
  "Direction scheme of the key layer: `arrows' or `vim'.
`arrows' uses the physical arrow keys and leaves `h', `j', `k' and `l' to
the application.  `vim' additionally dispatches those letters as direction
keys in navigation state.  Set it through `etaf-set-direction-scheme' so a
conflicting Runtime is reported instead of shadowed.")

(defconst etaf--keys-step-events
  `(([left] . (-1 . 0)) ([right] . (1 . 0)) ([up] . (0 . -1)) ([down] . (0 . 1))
    ([?\C-b] . (-1 . 0)) ([?\C-f] . (1 . 0)) ([?\C-p] . (0 . -1)) ([?\C-n] . (0 . 1)))
  "Events that step a focused separator or slider, with their column/row step.")

(defconst etaf--keys-printing-events
  (mapcar #'vector (number-sequence ?\s ?~))
  "Printing events a local or modal scope swallows when nothing binds them.")

(defun etaf--keys-event (key)
  "Return the event vector of KEY, a `kbd' string or a key vector."
  (vconcat (if (stringp key) (kbd key) key)))

(defun etaf--keys-validate (keys)
  "Signal `etaf-renderer-error' unless KEYS is a valid `:keys' value."
  (unless (proper-list-p keys)
    (signal 'etaf-renderer-error (list ":keys must be a list of (KEY COMMAND [LABEL])")))
  (dolist (entry keys)
    (unless (and (proper-list-p entry) (<= 2 (length entry) 3)
                 (or (stringp (car entry)) (vectorp (car entry)))
                 (functionp (nth 1 entry))
                 (or (null (nth 2 entry)) (stringp (nth 2 entry))))
      (signal 'etaf-renderer-error
              (list (format ":keys entry must be (KEY COMMAND [LABEL]): %S" entry))))
    (let ((events (etaf--keys-event (car entry))))
      (when (= (length events) 0)
        (signal 'etaf-renderer-error
                (list (format ":keys entry binds no key: %S" entry))))
      ;; Printing keys are single-key commands (and modal guards), so they
      ;; cannot also start a sequence.
      (when (and (> (length events) 1)
                 (member (vector (aref events 0)) etaf--keys-printing-events))
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s starts with a printing key"
                              (key-description events)))))
      (when (member (vector (aref events 0)) etaf--keys-reserved-events)
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s binds a framework-reserved key"
                              (key-description events)))))
      (when (and (eq etaf-direction-scheme 'vim)
                 (member (vector (aref events 0))
                         (mapcar #'car etaf--keys-vim-direction-events)))
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s shadows the Vim direction scheme"
                              (key-description events)))))))
  keys)

(defvar etaf--keys-sequences (make-hash-table :test #'eq :weakness 'key)
  "Map from a Runtime key map to the key sequences defined in it.")

(defun etaf--keys-prefix-p (prefix sequence)
  "Return non-nil when PREFIX is a proper prefix of SEQUENCE."
  (and (< (length prefix) (length sequence))
       (equal prefix (substring sequence 0 (length prefix)))))

(defun etaf--keys-define (map event)
  "Bind key sequence EVENT in MAP to its dynamic scoped resolution, once.
A sequence that extends or prefixes another bound sequence is a render error:
one key cannot both run a command and start a longer sequence."
  (let ((defined (gethash map etaf--keys-sequences)))
    (unless (member event defined)
      (when (cl-find-if (lambda (other)
                          (or (etaf--keys-prefix-p other event)
                              (etaf--keys-prefix-p event other)))
                        defined)
        (signal 'etaf-renderer-error
                (list (format ":keys sequence %s conflicts with a prefix binding"
                              (key-description event)))))
      (puthash map (cons event defined) etaf--keys-sequences)
      (define-key map event
                  (list 'menu-item "" nil
                        :filter (lambda (_binding) (etaf--keys-binding event)))))))

(defun etaf--keys-install (runtime)
  "Give RUNTIME's buffer its scoped key map with the framework defaults."
  (let ((map (make-sparse-keymap)))
    (dolist (event (append etaf--keys-dismiss-events
                           (list [??] [13] [return] etaf--keys-selector-event)
                           (mapcar #'car etaf--keys-step-events)
                           (mapcar #'car etaf--keys-edge-events)
                           etaf--keys-tab-events
                           etaf--keys-printing-events))
      (etaf--keys-define map event))
    (setf (etaf-runtime-keymap runtime) map)
    (with-current-buffer (etaf-runtime-buffer runtime)
      (add-hook 'ebox-focus-change-functions #'etaf--keys-focus-change nil t)
      (etaf--regions-install runtime)
      (setq etaf--keys-alist (list (cons t map)))
      ;; Host keys are the most specific bindings, so they precede any
      ;; emulation map the application installed in this buffer.
      (setq-local emulation-mode-map-alists
                  (cons 'etaf--keys-alist
                        (remq 'etaf--keys-alist emulation-mode-map-alists))))))

(defun etaf--keys-uninstall (runtime)
  "Remove RUNTIME's scoped key map from its buffer."
  (setf (etaf-runtime-keymap runtime) nil)
  (let ((buffer (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'ebox-focus-change-functions #'etaf--keys-focus-change t)
        (etaf--regions-uninstall runtime)
        (kill-local-variable 'etaf--keys-alist)
        (kill-local-variable 'etaf--help-state)))))

(defun etaf--keys-focus-change (previous node)
  "Notify Hosts left and entered moving PREVIOUS to NODE, nearest first.
Shared ancestors receive neither event.  Both phases share one reactive batch;
callbacks observe Ebox's already accepted focus, never a second focus state."
  (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
    (let* ((old (and previous (etaf-runtime-node-host-ref runtime previous)))
           (ref (and node (etaf-runtime-node-host-ref runtime node)))
           (left (and old (cons old (etaf-runtime-host-ancestor-refs runtime old))))
           (entered (and ref (cons ref (etaf-runtime-host-ancestor-refs runtime ref))))
           (nodes (etaf-runtime-nodes runtime))
           (old-seg (and previous (gethash previous nodes)))
           (new-seg (and node (gethash node nodes)))
           (old-id (and old-seg (eq (etaf--seg-kind old-seg) 'host)
                        (etaf--host-id (etaf--seg-data old-seg))))
           (new-id (and new-seg (eq (etaf--seg-kind new-seg) 'host)
                        (etaf--host-id (etaf--seg-data new-seg)))))
      (etaf-batch
        (dolist (phase (list (list 'focus-leave :on-focus-leave left entered)
                            (list 'focus-enter :on-focus-enter entered left)))
          (dolist (each (nth 2 phase))
            (when (and (etaf-runtime-mounted-p runtime)
                       (eq node (ebox-focused-node (etaf-runtime-buffer runtime)))
                       (not (member each (nth 3 phase))))
              (let ((props (etaf--keys-props runtime each)))
                (when (and (functionp (plist-get props (nth 1 phase)))
                           (not (plist-get props :disabled)))
                  (etaf-dispatch-event runtime each (car phase))))))))
      (when (and (etaf-runtime-mounted-p runtime)
                 (not (eql old-id new-id)))
        (etaf--run-runtime-hooks 'etaf-runtime-focus-change-functions
                                 runtime old-id new-id)))))

(defun etaf--keys-register (runtime keys)
  "Add the events of a Host's KEYS to RUNTIME's scoped key map."
  (when-let* ((map (etaf-runtime-keymap runtime)))
    (dolist (entry keys)
      (etaf--keys-define map (etaf--keys-event (car entry))))))

(defun etaf--keys-props (runtime ref)
  "Return RUNTIME's committed semantic props of Host REF without copying."
  (let ((seg (etaf--runtime-host-seg runtime ref)))
    (and seg (etaf--host-props (etaf--seg-data seg)))))

(defun etaf--keys-boundary-p (runtime ref)
  "Return non-nil when REF bounds keyboard operation in RUNTIME."
  (let ((props (etaf--keys-props runtime ref)))
    (or (eq (plist-get props :focus-scope) 'modal)
        (eq (plist-get props :key-scope) 'local))))

(defun etaf--keys-chain (runtime &optional from)
  "Return RUNTIME's Host references from FROM or its key entry outward.
Local boundaries follow real focus even if redisplay moves point elsewhere.
Outside one, focus answers while point lies inside it, else point answers.
FROM explicitly chooses a Host while retaining modal and local boundaries."
  (let* ((buffer (etaf-runtime-buffer runtime))
         (scope (ebox-focus-scope buffer))
         (focus (ebox-focused-node buffer))
         (focus-ref (and focus (etaf-runtime-node-host-ref runtime focus)))
         (local (and focus-ref
                     (cl-some (lambda (ref)
                                (eq (plist-get (etaf--keys-props runtime ref) :key-scope)
                                    'local))
                              (cons focus-ref
                                    (etaf-runtime-host-ancestor-refs runtime focus-ref)))))
         (here (ebox-node-at (point) buffer))
         (node (or (and from (etaf-runtime-host-node runtime from))
                   (if (and focus (or local (null here) (eq here focus)
                                      (ebox-node-ancestor-p focus here)))
                       focus
                     (or here focus))))
         (node (if (and node (or (eq node scope) (ebox-node-ancestor-p scope node)))
                   node
                 scope))
         (ref (and node (etaf-runtime-node-host-ref runtime node)))
         chain)
    (when ref
      (catch 'done
        (dolist (each (cons ref (etaf-runtime-host-ancestor-refs runtime ref)))
          (push each chain)
          (when (etaf--keys-boundary-p runtime each)
            (throw 'done nil)))))
    (nreverse chain)))

(defun etaf--keys-scope-root (runtime &optional from)
  "Return the keyboard navigation root of RUNTIME from FROM or its key entry.
A local boundary restricts only navigation from inside it.  The engine's
visible modal scope still bounds an entry from outside that modal."
  (with-current-buffer (etaf-runtime-buffer runtime)
    (let ((ref (car (last (etaf--keys-chain runtime from)))))
      (if (etaf--keys-boundary-p runtime ref)
          (etaf-runtime-host-node runtime ref)
        (ebox-focus-scope (current-buffer))))))

(defun etaf--keys-scope-stops (runtime)
  "Return RUNTIME's engine-ordered stops within its keyboard scope."
  (let ((root (etaf--keys-scope-root runtime)))
    (cl-remove-if-not
     (lambda (node) (or (eq root node) (ebox-node-ancestor-p root node)))
     (ebox-focus-stops (etaf-runtime-buffer runtime)))))

(defun etaf--keys-entries (runtime chain)
  "Return the effective ((REF . ENTRY) ...) of CHAIN in RUNTIME.
Entries are ordered nearest first; a key bound by a nearer Host shadows the
same key further out."
  (let (seen result)
    (dolist (ref chain)
      (let ((props (etaf--keys-props runtime ref)))
        (unless (plist-get props :disabled)
          (dolist (entry (plist-get props :keys))
            (let ((event (etaf--keys-event (car entry))))
              (unless (member event seen)
                (push event seen)
                (push (cons ref entry) result)))))))
    (nreverse result)))

(defun etaf--keys-run (runtime ref command)
  "Run key COMMAND for Host REF in RUNTIME like a keymap binding.
No batch surrounds COMMAND, so it sees each of its writes published: it can
move point to or begin input on a Host it just revealed, exactly as when a
keymap or M-x runs it."
  (unless (etaf-runtime-mounted-p runtime)
    (user-error "The ETAF Runtime is no longer mounted"))
  (when (symbolp command) (setq this-command command))
  (let ((etaf--current-runtime runtime)
        (etaf--current-event (list :runtime runtime :host-ref ref
                                   :kind 'key :payload nil)))
    (etaf-runtime-event-begin runtime)
    (unwind-protect
        (if (commandp command)
            (call-interactively command)
          (funcall command))
      (etaf-runtime-event-end runtime))))

(defun etaf--keys-callable (references kind)
  "Return a KIND command referring only weakly to its mounted owners.
Keep this factory separate: interpreted closures must not capture the caller's
Runtime or callback arguments through their lexical environment."
  (lambda ()
    (interactive)
    (let ((runtime (gethash 'runtime references))
          (ref (gethash 'ref references))
          (argument (gethash 'argument references)))
      (unless (and runtime (etaf-runtime-mounted-p runtime))
        (user-error "The ETAF Runtime is no longer mounted"))
      (pcase kind
        ('command
         (unless (and ref argument) (user-error "The ETAF key binding is no longer available"))
         (etaf--keys-run runtime ref argument))
        ('layer
         (unless argument (user-error "The ETAF extension key binding is no longer available"))
         (etaf--keys-run runtime nil argument))
        ('dismiss (etaf-dispatch-event runtime ref 'dismiss))
        ('direction (etaf-direction argument runtime))
        ('tab (if argument (etaf-focus-previous runtime) (etaf-focus-next runtime)))
        ('edge (ebox-focus-edge argument (etaf-runtime-buffer runtime)
                                (etaf--keys-scope-root runtime)))
        ('step (etaf-drag-step runtime ref (car argument) (cdr argument)))))))

(defun etaf--keys-command (runtime kind &optional ref argument)
  "Return a KIND command without extending RUNTIME or ARGUMENT's lifetime.
Expose the command as a named symbol, not the closure itself: Emacs stores the
resolved command in `this-command', and native printing, `command-history' or a
package that stringifies it must not walk RUNTIME's object graph."
  (let ((references (make-hash-table :test 'eq :weakness 'value :size 3)))
    (puthash 'runtime runtime references)
    (puthash 'ref ref references)
    (puthash 'argument argument references)
    (let ((command (make-symbol (format "etaf-key-%s" kind))))
      (fset command (etaf--keys-callable references kind))
      command)))

(defun etaf--keys-dismiss-ref (runtime chain)
  "Return the nearest enabled Host in CHAIN with a dismiss handler."
  (cl-find-if (lambda (ref)
                (let ((props (etaf--keys-props runtime ref)))
                  (and (functionp (plist-get props :on-dismiss))
                       (not (plist-get props :disabled)))))
              chain))

(defun etaf--keys-step-ref (runtime event)
  "Return the focused separator or slider that EVENT steps, or nil."
  (when-let* ((step (cdr (assoc event etaf--keys-step-events)))
              (node (ebox-focused-node (etaf-runtime-buffer runtime)))
              (ref (etaf-runtime-node-host-ref runtime node))
              (props (etaf--keys-props runtime ref)))
    (let ((role (format "%s" (plist-get props :role)))
          (orientation (format "%s" (plist-get props :aria-orientation))))
      (and (member role '("separator" "slider"))
           (functionp (plist-get props :on-drag))
           (not (plist-get props :disabled))
           ;; A vertical rule moves sideways; a horizontal one moves up/down.
           (cond ((equal orientation "vertical") (/= (car step) 0))
                 ((equal orientation "horizontal") (/= (cdr step) 0))
                 (t t))
           ref))))

(defun etaf--keys-direction-of (event)
  "Return the direction EVENT selects under the active scheme, or nil."
  (or (cdr (assoc event etaf--keys-direction-events))
      (and (eq etaf-direction-scheme 'vim)
           (cdr (assoc event etaf--keys-vim-direction-events)))))

(defun etaf--keys-pointer-ref (runtime)
  "Return the Host under the pointer event being looked up in RUNTIME, or nil.
Wheel and click bindings follow the pointer rather than focus or point."
  (let ((event last-input-event))
    (when (and (consp event) (consp (cdr event)) (consp (event-start event)))
      (let* ((position (event-start event))
             (window (posn-window position))
             (point (posn-point position))
             (buffer (etaf-runtime-buffer runtime)))
        (when (and (windowp window) (eq (window-buffer window) buffer)
                   (integer-or-marker-p point))
          (when-let* ((node (ebox-node-at point buffer)))
            (etaf-runtime-node-host-ref runtime node)))))))

(defun etaf--keys-activation-ref (runtime chain)
  "Return the nearest Host in CHAIN that a RUNTIME activation would press."
  (cl-find-if (lambda (ref)
                (and (not (plist-get (etaf--keys-props runtime ref) :disabled))
                     (etaf--event-handler runtime ref 'press)))
              chain))

(defun etaf--keys-binding (event)
  "Return the command EVENT runs in the current Runtime buffer, or nil."
  (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
    (when (and runtime (not (ebox-input-active-p (current-buffer))))
      (let* ((chain (etaf--keys-chain runtime (etaf--keys-pointer-ref runtime)))
             (found (cl-find event (etaf--keys-entries runtime chain)
                             :key (lambda (item) (etaf--keys-event (cadr item)))
                             :test #'equal))
             (return (member event '([13] [return])))
             (pressed (and return (etaf--keys-activation-ref runtime chain))))
        (cond
         ;; A control nearer than the Host that binds RET keeps activation.
         ((and found pressed
               (< (cl-position pressed chain) (cl-position (car found) chain)))
          #'etaf-activate)
         (found (etaf--keys-command runtime 'command (car found) (nth 2 found)))
         (return #'etaf-activate)
         ((equal event etaf--keys-selector-event)
          #'etaf-region-select)
         ((member event etaf--keys-dismiss-events)
          (if-let* ((ref (etaf--keys-dismiss-ref runtime chain)))
              (etaf--keys-command runtime 'dismiss ref)
            (when (etaf--keys-boundary-p runtime (car (last chain)))
              #'ignore)))
         ((etaf--keys-direction-of event)
          (etaf--keys-command runtime 'direction nil (etaf--keys-direction-of event)))
         ((member event etaf--keys-tab-events)
          (etaf--keys-command runtime 'tab nil (and (member event etaf--keys-backtab-events) t)))
         ((and (etaf--keys-boundary-p runtime (car (last chain)))
               (assoc event etaf--keys-control-direction-events))
          (etaf--keys-command runtime 'direction nil
                              (cdr (assoc event etaf--keys-control-direction-events))))
         ((and (etaf--keys-boundary-p runtime (car (last chain)))
               (assoc event etaf--keys-edge-events))
          (etaf--keys-command runtime 'edge nil
                              (cdr (assoc event etaf--keys-edge-events))))
         ((equal event [??])
          #'etaf-help)
         ((etaf--keys-step-ref runtime event)
          (let ((ref (etaf--keys-step-ref runtime event))
                (step (cdr (assoc event etaf--keys-step-events))))
            (etaf--keys-command runtime 'step ref step)))
         ;; A boundary keeps typed letters from reaching its host, including
         ;; buffer keymaps outside Host `:keys' (notably the engine's q).
         ((and (or (member event etaf--keys-printing-events)
                   (bound-and-true-p etaf--help-state))
               (etaf--keys-boundary-p runtime (car (last chain))))
          #'ignore)
         ;; Registered extension key layers resolve outside local/modal
         ;; boundaries, strictly below Host `:keys' and framework defaults.
         ((and (not (etaf--keys-boundary-p runtime (car (last chain))))
               (etaf--keys-layer-command runtime event))))))))

(defun etaf--keys-layer-command (runtime event)
  "Return the extension key-layer command for EVENT in RUNTIME, or nil."
  (cl-loop for (_key . layer) in (etaf-runtime-key-layers runtime)
           for hit = (cl-find event (plist-get layer :entries)
                              :key #'car :test #'equal)
           when hit
           return (etaf--keys-command runtime 'layer nil (nth 1 hit))))

(defun etaf--keys-layer-help-entries (runtime seen)
  "Return effective help entries from RUNTIME's key layers not in SEEN."
  (let ((out nil)
        (used (copy-sequence seen)))
    (dolist (pair (etaf-runtime-key-layers runtime))
      (let* ((key (car pair))
             (layer (cdr pair))
             (source (or (plist-get layer :label) (symbol-name key))))
        (dolist (entry (plist-get layer :entries))
          (let ((events (car entry))
                (label (nth 2 entry)))
            (unless (member events used)
              (push events used)
              (when (and (stringp label) (not (string-empty-p label)))
                (push (list :key (key-description events)
                            :events events
                            :label label
                            :source source)
                      out)))))))
    (nreverse out)))

(defun etaf--keys-layer-prefix-conflict-p (map event)
  "Return non-nil when EVENT conflicts as a prefix with bindings in MAP."
  (let ((defined (gethash map etaf--keys-sequences)))
    (and (not (member event defined))
         (cl-some (lambda (other)
                    (or (etaf--keys-prefix-p other event)
                        (etaf--keys-prefix-p event other)))
                  defined))))

;;;###autoload
(defun etaf-runtime-set-key-layer (runtime key entries &optional label priority)
  "Register or replace extension key layer KEY on mounted RUNTIME.
KEY is a non-nil symbol.  ENTRIES is a list of `(KEY-DESC COMMAND [LABEL])'
items; nil removes KEY.  Framework-reserved first events (`Escape', `M-g',
`C-g', `?', `Tab', arrows) signal `etaf-runtime-error'.  LABEL names the
source in keyboard help, and PRIORITY is an integer (default 50, lower wins).
Bindings that prefix-conflict with an already bound key sequence are skipped
without disturbing the application.  Return the list of active key strings."
  (etaf--assert-not-rendering 'set-key-layer)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (symbolp key) key)
    (signal 'etaf-runtime-error (list "Key layer key must be a non-nil symbol" key)))
  (unless (proper-list-p entries)
    (signal 'etaf-runtime-error (list "Key layer entries must be a list" entries)))
  (when (and label (not (stringp label)))
    (signal 'etaf-runtime-error (list "Key layer label must be a string or nil" label)))
  (let ((prio (or priority 50)))
    (unless (integerp prio)
      (signal 'etaf-runtime-error (list "Key layer priority must be an integer" prio)))
    (if (null entries)
        (progn
          (setf (etaf-runtime-key-layers runtime)
                (assq-delete-all key (etaf-runtime-key-layers runtime)))
          nil)
      (let ((normalized nil)
            (active nil)
            (map (etaf-runtime-keymap runtime)))
        (dolist (item entries)
          (unless (and (proper-list-p item) (>= (length item) 2) (<= (length item) 3))
            (signal 'etaf-runtime-error (list "Invalid key layer entry" item)))
          (let* ((raw-key (nth 0 item))
                 (cmd (nth 1 item))
                 (desc (nth 2 item)))
            (unless (or (stringp raw-key) (vectorp raw-key))
              (signal 'etaf-runtime-error (list "Invalid key layer sequence" raw-key)))
            (unless (or (functionp cmd) (commandp cmd))
              (signal 'etaf-runtime-error (list "Invalid key layer command" cmd)))
            (when (and desc (not (stringp desc)))
              (signal 'etaf-runtime-error (list "Invalid key layer label" desc)))
            (let* ((event (etaf--keys-event raw-key))
                   (first-ev (and (> (length event) 0) (vector (aref event 0)))))
              (when (or (= (length event) 0)
                        (member first-ev etaf--keys-reserved-events))
                (signal 'etaf-runtime-error
                        (list "Extension key layer cannot bind reserved key"
                              (key-description event))))
              (unless (and map (etaf--keys-layer-prefix-conflict-p map event))
                (when map (etaf--keys-define map event))
                (push (list event cmd desc) normalized)
                (push (key-description event) active)))))
        (let* ((others (assq-delete-all key (etaf-runtime-key-layers runtime)))
               (entry (cons key (list :priority prio
                                      :label label
                                      :entries (nreverse normalized))))
               (merged (sort (cons entry others)
                             (lambda (a b)
                               (< (plist-get (cdr a) :priority)
                                  (plist-get (cdr b) :priority))))))
          (setf (etaf-runtime-key-layers runtime) merged))
        (nreverse active)))))

;;;###autoload
(defun etaf-runtime-clear-key-layer (runtime &optional key)
  "Remove extension key layer KEY (or all when nil) from mounted RUNTIME.
Return the number of layers removed."
  (etaf--assert-not-rendering 'clear-key-layer)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when (and key (not (symbolp key)))
    (signal 'etaf-runtime-error (list "Key layer key must be a symbol or nil" key)))
  (let ((layers (etaf-runtime-key-layers runtime)))
    (if (null key)
        (let ((n (length layers)))
          (setf (etaf-runtime-key-layers runtime) nil)
          n)
      (if (assq key layers)
          (progn
            (setf (etaf-runtime-key-layers runtime)
                  (assq-delete-all key layers))
            1)
        0))))

;;;###autoload
(defun etaf-drag-step (runtime host-ref columns rows)
  "Drag HOST-REF in mounted RUNTIME by COLUMNS and ROWS from the keyboard.
Dispatch one `start' and one `end' gesture to the Host's `:on-drag' with
a delta of COLUMNS character widths and ROWS line heights in pixels, the
units of a pointer drag, so every drag handler also works from the keyboard.
The gestures carry `:keyboard' t.  Return HOST-REF."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (numberp columns) (numberp rows))
    (signal 'etaf-event-error (list "Drag step COLUMNS and ROWS must be numbers")))
  (let* ((buffer (etaf-runtime-buffer runtime))
         (node (or (etaf-runtime-host-node runtime host-ref)
                   (signal 'etaf-event-error
                           (list "No committed Host reference" host-ref))))
         (window (or (get-buffer-window buffer) (selected-window)))
         ;; A drag step is that many cells of the canvas the pointer is over,
         ;; so the pixels come from its face instead of the frame's.  With a
         ;; text scale the two differ and the gesture would travel the wrong
         ;; distance.
         (metrics (etaf-display-metrics runtime))
         (delta (cons (* columns (plist-get metrics :char-width))
                      (* rows (plist-get metrics :line-height))))
         (base (list :event last-input-event :node node :window window
                     :buffer buffer :start (cons 0 0) :reason nil :keyboard t)))
    (etaf-dispatch-event runtime host-ref 'drag
                         (append (list :phase 'start :position (cons 0 0)
                                       :delta (cons 0 0))
                                 base)
                         t)
    (etaf-dispatch-event runtime host-ref 'drag
                         (append (list :phase 'end :position delta :delta delta)
                                 base)
                         t)
    host-ref))

(defun etaf--keys-current-step (columns rows)
  "Drag the Host whose `:keys' entry is running by COLUMNS and ROWS."
  (let ((runtime (plist-get etaf--current-event :runtime))
        (ref (plist-get etaf--current-event :host-ref)))
    (unless (and runtime ref)
      (signal 'etaf-event-error (list "Keyboard drag requires a Host key event")))
    (etaf-drag-step runtime ref columns rows)))

(defun etaf--keys-move-bindings (axis)
  "Return the `:keys' moving a draggable Host along AXIS with M-arrows."
  (let (keys)
    (when (memq axis '(nil x both))
      (push (list "M-<left>" (lambda () (etaf--keys-current-step -1 0)) "Move left") keys)
      (push (list "M-<right>" (lambda () (etaf--keys-current-step 1 0)) "Move right") keys))
    (when (memq axis '(nil y both))
      (push (list "M-<up>" (lambda () (etaf--keys-current-step 0 -1)) "Move up") keys)
      (push (list "M-<down>" (lambda () (etaf--keys-current-step 0 1)) "Move down") keys))
    (nreverse keys)))

(defun etaf--keys-resize-bindings (edges)
  "Return the `:keys' resizing a Host with EDGES by M-S-arrows.
Right and down grow the Host and left and up shrink it, whichever edge
the Host drags."
  (let ((dx (cond ((memq 'right edges) 1) ((memq 'left edges) -1)))
        (dy (cond ((memq 'bottom edges) 1) ((memq 'top edges) -1)))
        keys)
    (when dx
      (push (list "M-S-<right>" (lambda () (etaf--keys-current-step dx 0)) "Wider") keys)
      (push (list "M-S-<left>" (lambda () (etaf--keys-current-step (- dx) 0)) "Narrower")
            keys))
    (when dy
      (push (list "M-S-<down>" (lambda () (etaf--keys-current-step 0 dy)) "Taller") keys)
      (push (list "M-S-<up>" (lambda () (etaf--keys-current-step 0 (- dy))) "Shorter")
            keys))
    (nreverse keys)))

;;;; Command palette

(defun etaf--keys-control-label (runtime ref node)
  "Return the palette label of control NODE registered as REF in RUNTIME."
  (let* ((props (and ref (etaf--keys-props runtime ref)))
         (label (plist-get props :aria-label))
         (bounds (and (not label) (ebox-node-bounds node t)))
         (text (or (and label (format "%s" label))
                   (and bounds
                        (with-current-buffer (etaf-runtime-buffer runtime)
                          (buffer-substring-no-properties (car bounds) (cdr bounds)))))))
    (when text
      (setq text (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)))
      (unless (string-empty-p text)
        (truncate-string-to-width text 60 nil nil "…")))))

(defun etaf--keys-palette-candidates (runtime)
  "Return palette entries (LABEL ANNOTATION FUNCTION) for RUNTIME."
  (let* ((buffer (etaf-runtime-buffer runtime))
         (chain (etaf--keys-chain runtime))
         candidates)
    (dolist (item (etaf--keys-entries runtime chain))
      (let ((ref (car item)) (entry (cdr item)))
        (when (nth 2 entry)
          (push (list (nth 2 entry) (key-description (etaf--keys-event (car entry)))
                      (lambda () (etaf--keys-run runtime ref (nth 1 entry))))
                candidates))))
    (when-let* ((ref (etaf--keys-dismiss-ref runtime chain)))
      (unless (cl-find [escape] (etaf--keys-entries runtime chain)
                       :key (lambda (item) (etaf--keys-event (cadr item)))
                       :test #'equal)
        (push (list "Close" "<escape>"
                    (lambda () (etaf-dispatch-event runtime ref 'dismiss)))
              candidates)))
    (dolist (node (etaf--keys-scope-stops runtime))
      (let* ((ref (etaf-runtime-node-host-ref runtime node))
             (label (etaf--keys-control-label runtime ref node))
             (props (and ref (etaf--keys-props runtime ref)))
             (role (plist-get props :role)))
        (when label
          (push (list label (if role (format "%s" role) "control")
                      (lambda ()
                        (ebox-focus node buffer)
                        (when (and (functionp (plist-get props :on-press))
                                   (not (plist-get props :disabled)))
                          (etaf-dispatch-event runtime ref 'press))))
                candidates))))
    (nreverse candidates)))

;;;###autoload
;;;###autoload
(defun etaf-palette (&optional runtime)
  "Choose and run a command or control of mounted RUNTIME by name.
The candidates are the labelled `:keys' that the current focus reaches,
Close when an `:on-dismiss' Host is in scope, and every focusable control
in the current keyboard scope, named by its `:aria-label' or painted text.
Choosing a key runs its command; choosing a control focuses and presses it.  The
palette is an execution surface and stays reachable from `M-x'; `?' opens
`etaf-help' instead so that viewing never runs anything."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (let* ((candidates (etaf--keys-palette-candidates runtime))
           (table (make-hash-table :test #'equal))
           names)
      (unless candidates (user-error "No ETAF command is reachable here"))
      (dolist (candidate candidates)
        (let* ((base (car candidate)) (name base) (count 1))
          (while (gethash name table)
            (setq count (1+ count) name (format "%s <%d>" base count)))
          (puthash name candidate table)
          (push name names)))
      (setq names (nreverse names))
      (let* ((completion-extra-properties
              (list :annotation-function
                    (lambda (name)
                      (when-let* ((candidate (gethash name table)))
                        (concat "  " (propertize (nth 1 candidate)
                                                 'face 'completions-annotations))))))
             (choice (completing-read
                      "Command: "
                      (lambda (string predicate action)
                        (if (eq action 'metadata)
                            '(metadata (display-sort-function . identity))
                          (complete-with-action action names string predicate)))
                      nil t)))
        (funcall (nth 2 (gethash choice table)))))))

(defun etaf--keys-source-name (runtime ref)
  "Return REF's readable name in RUNTIME, or nil."
  (when-let* ((props (etaf--keys-props runtime ref)))
    (let ((label (plist-get props :aria-label)))
      (cond ((and label (not (string-empty-p (format "%s" label))))
             (format "%s" label))
            ((symbolp ref) (format "%s" ref))))))

;;;; Region and direction navigation

(defun etaf--direction-handler (runtime ref direction)
  "Run the nearest enabled `:on-direction' from REF in RUNTIME's key scope.
Return the handler's result symbol, or nil when no handler is in scope."
  (cl-loop for candidate in (etaf--keys-chain runtime ref)
           for props = (etaf--keys-props runtime candidate)
           for handler = (plist-get props :on-direction)
           when (and (functionp handler) (not (plist-get props :disabled)))
           return (let ((result (funcall handler direction)))
                    (unless (memq result '(handled hold release))
                      (signal 'etaf-event-error
                              (list (format ":on-direction returned %S; expected handled, hold or release"
                                            result))))
                    result)))

(defun etaf--direction-step (runtime ref direction)
  "Step a focused separator or slider REF in DIRECTION; return REF or nil."
  (when ref
    (let* ((event (car (rassoc direction etaf--keys-direction-events)))
           (step (and event (cdr (assoc event etaf--keys-step-events)))))
      (when (and step (eq (etaf--keys-step-ref runtime event) ref))
        (etaf-drag-step runtime ref (car step) (cdr step))
        ref))))

(defun etaf--direction-move (runtime ref direction)
  "Move focus from REF in DIRECTION, crossing region boundaries.
Inside a declared region the movement is limited to that region; at its edge
the adjacent region's entry is focused.  Without a region the Ebox spatial
movement applies and the viewport scrolls at its edge.  Return the focused
Host reference or nil."
  (let* ((buffer (etaf-runtime-buffer runtime))
         (regions (etaf--regions-in-scope runtime ref))
         (region (etaf--regions-containing runtime regions ref))
         (root (and region (etaf-runtime-host-node runtime (plist-get region :ref)))))
    (if region
        (if-let* ((node (and root (ebox-focus-direction direction buffer root))))
            (etaf-runtime-node-host-ref runtime node)
          (when-let* ((target (etaf--regions-neighbor runtime regions direction)))
            (etaf--regions-focus runtime
                                 (cl-find target regions
                                          :key (lambda (item) (plist-get item :id))))))
      (if-let* ((node (ebox-focus-direction direction buffer
                                              (etaf--keys-scope-root runtime ref))))
          (etaf-runtime-node-host-ref runtime node)
        (pcase direction
          ('down (ebox-scroll-down))
          ('up (ebox-scroll-up)))
        nil))))

;;;###autoload
(defun etaf-direction (direction &optional runtime)
  "Move DIRECTION in mounted RUNTIME and return the focused Host reference.
DIRECTION is `up', `down', `left' or `right'.  Order: the nearest Host
`:on-direction' handler (it returns `handled', `hold' or `release'); a
focused separator or slider step; then focus movement inside the surrounding
region, entering the adjacent region at its edge.  Without a surrounding
region the Ebox spatial movement applies and the viewport scrolls at the
edge.  Return nil when nothing moves."
  (interactive
   (list (intern (completing-read "Direction: " '("up" "down" "left" "right")
                                  nil t nil nil "down"))))
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (memq direction '(up down left right))
    (signal 'etaf-event-error (list (format "Unknown direction %S" direction))))
  (with-current-buffer (etaf-runtime-buffer runtime)
    (let ((ref (car (etaf--keys-chain runtime (etaf-focused-host-ref runtime)))))
      (if (memq (etaf--direction-handler runtime ref direction) '(handled hold))
          (etaf-focused-host-ref runtime)
        (or (etaf--direction-step runtime ref direction)
            (etaf--direction-move runtime ref direction))))))

(defun etaf--direction-vim-conflicts (runtime)
  "Return Vim-scheme conflicts in RUNTIME as readable strings."
  (let ((letters (mapcar (lambda (pair) (aref (car pair) 0))
                         etaf--keys-vim-direction-events))
        conflicts)
    (dolist (entry (etaf-runtime-host-props-entries runtime))
      (dolist (binding (plist-get (cdr entry) :keys))
        (let ((events (etaf--keys-event (car binding))))
          (when (and (> (length events) 0)
                     (memq (aref events 0) letters))
            (push (format "Host %s binds %s" (car entry) (key-description events))
                  conflicts)))))
    (dolist (region (etaf--regions-collect runtime))
      (let ((char (etaf--regions-key-char (plist-get region :key))))
        (when (and char (memq char letters))
          (push (format "region %s uses hint %c" (plist-get region :id) char)
                conflicts))))
    (nreverse conflicts)))

;;;###autoload
(defun etaf-set-direction-scheme (scheme &optional runtime)
  "Select the direction SCHEME, `arrows' or `vim', after conflict checks.
Vim requires every mounted Runtime to be free of Host `:keys' and region hint
letters using `h', `j', `k' or `l'; conflicts are reported and the previous
scheme stays in effect.  RUNTIME limits the check to that Runtime and
defaults to the active one.  Return SCHEME."
  (interactive
   (list (intern (completing-read "Direction scheme: " '("arrows" "vim")
                                  nil t nil nil (symbol-name etaf-direction-scheme)))))
  (unless (memq scheme '(arrows vim))
    (signal 'etaf-event-error (list (format "Unknown direction scheme %S" scheme))))
  (when (eq scheme 'vim)
    (let (conflicts)
      (dolist (item (if runtime
                        (list (etaf-runtime-require-mounted runtime))
                      (let (runtimes)
                        (maphash (lambda (_ item)
                                   (when (etaf-runtime-mounted-p item)
                                     (push item runtimes)))
                                 etaf--runtimes)
                        runtimes)))
        (setq conflicts (append conflicts (etaf--direction-vim-conflicts item))))
      (when conflicts
        (user-error "Vim direction scheme conflicts: %s" (string-join conflicts "; ")))))
  (setq etaf-direction-scheme scheme)
  scheme)

(provide 'etaf-keys)

;;; etaf-keys.el ends here
