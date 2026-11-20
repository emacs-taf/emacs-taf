;;; etaf-ui-editor.el --- Native editing behavior for embedded UI -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Shared editing behavior for application-owned native text areas.  The mode
;; preserves the major mode's editing, keymap, selection, undo and completion.
;; It owns only the empty hint and edit observation, never windows, layout,
;; application drafts, transport acknowledgements or rendered Ebox surfaces.

;;; Code:
(require 'cl-lib)

(defvar etaf-ui-editor-mode)
(defvar-local etaf-ui--editor-hint nil
  "Owned empty-text overlay.")
(defvar-local etaf-ui--editor-placeholder ""
  "Empty editor hint, excluded from the buffer value.")
(defvar-local etaf-ui--editor-placeholder-face 'shadow
  "Face used for the empty editor hint.")
(defvar-local etaf-ui--editor-on-change nil
  "Function observing accepted native text edits.")
(defvar-local etaf-ui--editor-replacing nil
  "Non-nil while coalescing this mode's replacement notification.")
(defvar-local etaf-ui--editor-notifying nil
  "Non-nil while the mode's change observer runs.")

(defun etaf-ui--editor-require (buffer)
  "Require live BUFFER with the shared editor behavior enabled."
  (unless (and (buffer-live-p buffer)
               (buffer-local-value 'etaf-ui-editor-mode buffer))
    (user-error "Expected a live buffer with etaf-ui-editor-mode enabled"))
  buffer)

(defun etaf-ui--editor-refresh-hint ()
  "Refresh the hint without adding it to text, selection or undo."
  (when (overlayp etaf-ui--editor-hint)
    (save-restriction
      (widen)
      (move-overlay etaf-ui--editor-hint (point-min) (point-min))
      (overlay-put etaf-ui--editor-hint 'after-string
                   (when (= (point-min) (point-max))
                     (propertize etaf-ui--editor-placeholder
                                 'face etaf-ui--editor-placeholder-face
                                 'cursor t))))))

(defun etaf-ui--editor-changed (&rest _change)
  "Observe accepted text without scheduling layout or rendering."
  (unless etaf-ui--editor-replacing
    (etaf-ui--editor-refresh-hint)
    (when (and etaf-ui--editor-on-change (not etaf-ui--editor-notifying))
      (let ((etaf-ui--editor-notifying t))
        (funcall etaf-ui--editor-on-change (current-buffer))))))

(defun etaf-ui--editor-cleanup ()
  "Release the mode's overlay and hooks, not the caller's text or buffer."
  (when (overlayp etaf-ui--editor-hint) (delete-overlay etaf-ui--editor-hint))
  (setq etaf-ui--editor-hint nil etaf-ui--editor-on-change nil)
  (remove-hook 'after-change-functions #'etaf-ui--editor-changed t)
  (remove-hook 'change-major-mode-hook #'etaf-ui--editor-cleanup t)
  (remove-hook 'kill-buffer-hook #'etaf-ui--editor-cleanup t))

;;;###autoload
(define-minor-mode etaf-ui-editor-mode
  "Enable shared native editing behavior in the current editable UI buffer.
The application or component owns this buffer and its display.  Enabling
preserves text, major mode, key bindings, undo, point, mark, completion and
modified state.  No minibuffer, window, frame, process or timer is opened.
Disabling removes the hint and observer without discarding text.  Configure
this behavior with `etaf-ui-editor-configure'."
  :lighter nil
  (if etaf-ui-editor-mode
      (progn
        (unless (overlayp etaf-ui--editor-hint)
          (setq etaf-ui--editor-hint (make-overlay (point-min) (point-min))))
        (add-hook 'after-change-functions #'etaf-ui--editor-changed nil t)
        (add-hook 'change-major-mode-hook #'etaf-ui--editor-cleanup nil t)
        (add-hook 'kill-buffer-hook #'etaf-ui--editor-cleanup nil t)
        (etaf-ui--editor-refresh-hint))
    (etaf-ui--editor-cleanup)))

;;;###autoload
(cl-defun etaf-ui-editor-configure
    (&key (placeholder nil placeholder-p) (placeholder-face nil face-p)
          (on-change nil callback-p))
  "Configure shared editing behavior in the current buffer.
Enable `etaf-ui-editor-mode' first.  Supplied PLACEHOLDER is a string copied
without properties.  PLACEHOLDER-FACE is a face specification (default shadow).
ON-CHANGE is nil or a function receiving the edited buffer after accepted
text changes.  Omitted fields retain their values; explicit nil removes the
observer.  Configuration never changes the text or calls ON-CHANGE.

Callbacks receive no eager text copy: read `etaf-ui-editor-value' if needed.
An observer error propagates after the edit and does not erase the draft.
Do not edit the same buffer inside its observer.  Native typing is not an
ETAF render; application callbacks choose how to synchronize their state."
  (etaf-ui--editor-require (current-buffer))
  (unless (and (or (not placeholder-p) (stringp placeholder))
               (or (not callback-p) (null on-change) (functionp on-change))
               (or (not face-p) (null placeholder-face)
                   (facep placeholder-face) (proper-list-p placeholder-face)))
    (user-error "Invalid editor placeholder, face or change observer"))
  (when placeholder-p
    (setq etaf-ui--editor-placeholder (substring-no-properties placeholder)))
  (when face-p (setq etaf-ui--editor-placeholder-face placeholder-face))
  (when callback-p (setq etaf-ui--editor-on-change on-change))
  (etaf-ui--editor-refresh-hint))

;;;###autoload
(defun etaf-ui-editor-value (&optional buffer)
  "Return the widened, property-free text of native editor BUFFER.
BUFFER defaults to the current buffer; it must have `etaf-ui-editor-mode'
enabled.  The caller owns the returned string.  This query never changes
point, mark, narrowing, modified state or undo."
  (with-current-buffer (etaf-ui--editor-require (or buffer (current-buffer)))
    (save-restriction
      (widen)
      (buffer-substring-no-properties (point-min) (point-max)))))

;;;###autoload
(defun etaf-ui-editor-replace (buffer text &optional expected-tick)
  "Replace editor BUFFER's value with property-free TEXT.
Return t on acceptance, including identical text.  If EXPECTED-TICK is
non-nil and differs from BUFFER's `buffer-chars-modified-tick', return nil
without changing anything.  Edit-then-undo also makes an earlier tick stale.
The caller decides whether an asynchronous result permits replacement.

Equal text preserves all edit state without notification.  A changed value
is one undoable replacement, retaining native markers where possible.  Other
native change hooks still run; this mode notifies ON-CHANGE once after the
replacement.  A callback error propagates but does not undo accepted text.
Explicit replacement may update a read-only buffer.  Invalid inputs, stale
buffers or replacement during ON-CHANGE signal `user-error'."
  (unless (and (stringp text) (or (null expected-tick) (integerp expected-tick)))
    (user-error "Expected string text and an optional integer modification tick"))
  (with-current-buffer (etaf-ui--editor-require buffer)
    (when etaf-ui--editor-notifying
      (user-error "Cannot replace editor text from its change observer"))
    (save-restriction
      (widen)
      (when (or (null expected-tick) (= expected-tick (buffer-chars-modified-tick)))
        (let ((value (substring-no-properties text)))
          (unless (equal value (buffer-substring-no-properties (point-min) (point-max)))
            (undo-boundary)
            (let ((inhibit-read-only t) (etaf-ui--editor-replacing t))
              (atomic-change-group
                (replace-region-contents (point-min) (point-max) (lambda () value))))
            (undo-boundary)
            (etaf-ui--editor-changed)))
        t))))

(provide 'etaf-ui-editor)
;;; etaf-ui-editor.el ends here
