;;; etaf-ui-field.el --- Native in-place text fields -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The catalog's one text editing Component.  A field is ordinary rendered
;; text until it is activated; activation opens a native editing session on
;; its value text, so typed keys, input methods, point, selection and undo
;; behave as in an ordinary buffer while the field keeps its padding, frame
;; and wrapping.  No extra frame, window or per-field surface is created.
;; Single-line and multi-line fields share the Component; `:rows' sets the
;; minimum height and the field grows with its value.  Applications keep
;; values, drafts and submission policy.

;;; Code:
(require 'cl-lib)
(require 'etaf-ui-basic)
(require 'etaf-ui-input)
(require 'etaf-ui-icon)

(declare-function etaf-direction "etaf" (direction &optional runtime))
(declare-function etaf-keymap-reserved-events "etaf" (keymap))
(declare-function etaf-runtime-mounted-p "etaf-runtime" (runtime))

(cl-defstruct (etaf-ui--text-input (:constructor etaf-ui--text-input-create))
  runtime ref text-ref props-fn session snapshot active focused)

(defvar etaf-ui--text-inputs (make-hash-table :test #'eq)
  "Mounted text inputs keyed by Runtime, then by public Host reference.")
(defvar etaf-ui--active-text-input nil
  "Text input currently editing, regardless of the current buffer.")
(defvar-local etaf-ui--field-cursor nil
  "Cursor settings of the buffer before its field session, as (LOCAL . TYPE).")

(defun etaf-ui--text-input-finish-active (runtime)
  "Leave the active text input when a press elsewhere in RUNTIME supersedes it."
  (let ((field etaf-ui--active-text-input))
    (when (and field (eq runtime (etaf-ui--text-input-runtime field)))
      (etaf-text-input-end 'blur))))

(defun etaf-ui--text-input-blur (&optional window)
  "Leave the active text input when a switch left its buffer behind.
Runs from the session buffer's `post-command-hook' and window change hooks;
WINDOW defaults to the selected window."
  (when (and etaf-ui--active-text-input
             (window-live-p (or window (selected-window))))
    (let ((selected (if window
                        (frame-selected-window (window-frame window))
                      (selected-window))))
      (when (and (window-live-p selected)
                 (not (eq (window-buffer selected) (current-buffer))))
        (etaf-text-input-end 'blur)))))

(defun etaf-ui--text-input-table (runtime)
  "Return RUNTIME's text input table, creating it on first use."
  (or (gethash runtime etaf-ui--text-inputs)
      (puthash runtime (make-hash-table :test #'equal) etaf-ui--text-inputs)))

(defun etaf-ui--text-input-find (runtime ref)
  "Return RUNTIME's mounted text input for REF, or nil."
  (and runtime
       (let ((table (gethash runtime etaf-ui--text-inputs)))
         (and table (gethash ref table)))))

(defun etaf-ui--text-input-props (field)
  "Return FIELD's committed public inputs."
  (funcall (etaf-ui--text-input-props-fn field)))

(defun etaf-ui--text-input-submit-on-return-p (props)
  "Return non-nil when a field with PROPS submits on Return."
  (let ((explicit (plist-get props :submit-on-return)))
    (if (eq explicit etaf-ui--unsupplied)
        (= (or (plist-get props :rows) 1) 1)
      (and explicit t))))

(defun etaf-ui-field--submit ()
  "Submit the active field."
  (interactive)
  (etaf-text-input-end))

(defun etaf-ui-field--cancel ()
  "Cancel the active field, restoring its value at activation."
  (interactive)
  (etaf-text-input-end t))

(defun etaf-ui-field--blur ()
  "Leave the active field keeping its text and its Host focus."
  (interactive)
  (when-let* ((field etaf-ui--active-text-input))
    (let ((runtime (etaf-ui--text-input-runtime field))
          (ref (etaf-ui--text-input-ref field)))
      (etaf-text-input-end 'blur)
      (when (etaf-runtime-mounted-p runtime)
        (etaf-focus runtime ref)))))

(defun etaf-ui-field--next ()
  "Leave the field and focus the next application control."
  (interactive)
  (when-let* ((field etaf-ui--active-text-input))
    (let ((runtime (etaf-ui--text-input-runtime field)))
      (etaf-text-input-end 'blur)
      (etaf-focus-next runtime))))

(defun etaf-ui-field--previous ()
  "Leave the field and focus the previous application control."
  (interactive)
  (when-let* ((field etaf-ui--active-text-input))
    (let ((runtime (etaf-ui--text-input-runtime field)))
      (etaf-text-input-end 'blur)
      (etaf-focus-previous runtime))))

(defun etaf-ui-field--leave (direction)
  "Leave the active field at a text boundary and continue in DIRECTION."
  (when-let* ((field etaf-ui--active-text-input))
    (let ((runtime (etaf-ui--text-input-runtime field))
          (ref (etaf-ui--text-input-ref field)))
      (etaf-text-input-end 'blur)
      (when (etaf-runtime-mounted-p runtime)
        (etaf-focus runtime ref)
        (etaf-direction direction runtime)))))

(defun etaf-ui-field--left ()
  "Move the caret left; at the value start leave toward the left region."
  (interactive)
  (unless (condition-case nil (progn (left-char 1) t) (error nil))
    (etaf-ui-field--leave 'left)))

(defun etaf-ui-field--right ()
  "Move the caret right; at the value end leave toward the right region."
  (interactive)
  (unless (condition-case nil (progn (right-char 1) t) (error nil))
    (etaf-ui-field--leave 'right)))

(defun etaf-ui-field--up ()
  "Move the caret up one visual line; at the first line leave upward."
  (interactive)
  (unless (condition-case nil (progn (line-move -1) t) (error nil))
    (etaf-ui-field--leave 'up)))

(defun etaf-ui-field--down ()
  "Move the caret down one visual line; at the last line leave downward."
  (interactive)
  (unless (condition-case nil (progn (line-move 1) t) (error nil))
    (etaf-ui-field--leave 'down)))

(dolist (command '(etaf-ui-field--left etaf-ui-field--right
                   etaf-ui-field--up etaf-ui-field--down))
  (etaf-input-edit-command-add command))

(defun etaf-ui--text-input-keymap (props)
  "Return the session keymap of a field with PROPS.
`newline' bindings edit the value; commands registered with
`etaf-input-edit-command-add' run in the session buffer and the other commands
run in the application buffer.  Arrow keys move the caret and leave the
field at its text boundary.  PROPS' :keymap is consulted first."
  (let ((map (make-sparse-keymap)))
    (when (etaf-ui--text-input-submit-on-return-p props)
      (define-key map (kbd "RET") #'etaf-ui-field--submit)
      (define-key map (kbd "<return>") #'etaf-ui-field--submit))
    (define-key map (kbd "<S-return>") #'newline)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-<return>") #'etaf-ui-field--submit)
    (define-key map (kbd "C-c C-c") #'etaf-ui-field--submit)
    (define-key map (kbd "C-c C-k") #'etaf-ui-field--cancel)
    (define-key map (kbd "<escape>") #'etaf-ui-field--blur)
    (define-key map (kbd "TAB") #'etaf-ui-field--next)
    (define-key map (kbd "<backtab>") #'etaf-ui-field--previous)
    (dolist (binding '(("<left>" . etaf-ui-field--left)
                       ("<right>" . etaf-ui-field--right)
                       ("<up>" . etaf-ui-field--up)
                       ("<down>" . etaf-ui-field--down)))
      (define-key map (kbd (car binding)) (cdr binding)))
    (if-let* ((own (plist-get props :keymap)))
        (make-composed-keymap (list own) map)
      map)))

;;;###autoload
(defun etaf-text-input-begin (runtime ref)
  "Begin native editing of the mounted text input REF in RUNTIME.
Return the input or nil when REF is unknown, disabled, read-only or editing.
Activation normally calls this from the field's own event callback; call it
directly to focus a composer or open a grid cell for editing.  Another field
editing meanwhile is left first, keeping its text."
  (when-let* ((field (etaf-ui--text-input-find runtime ref))
              (props (etaf-ui--text-input-props field)))
    (unless (or (etaf-ui--text-input-active field)
                (plist-get props :disabled) (plist-get props :read-only))
      (when etaf-ui--active-text-input (etaf-text-input-end 'blur))
      (etaf-ui--text-input-open field props))))

(defun etaf-ui--text-input-open (field props)
  "Open PROPS' native session for FIELD and return the field."
  (let* ((runtime (etaf-ui--text-input-runtime field))
         (buffer (etaf-runtime-buffer runtime))
         (functions (plist-get props :completion-functions))
         (session (etaf-input-begin
                   runtime (etaf-ui--text-input-text-ref field)
                   :keymap (etaf-ui--text-input-keymap props)
                   :on-change (lambda (text)
                                (when-let* ((callback (plist-get
                                                       (etaf-ui--text-input-props field)
                                                       :change-handler)))
                                  (funcall callback text)))
                   :on-leave (lambda () (etaf-text-input-end 'blur))
                   :local-variables
                   (append '((electric-indent-inhibit . t))
                           (and functions
                                (list (cons 'completion-at-point-functions functions)))))))
    (setf (etaf-ui--text-input-session field) session
          (etaf-ui--text-input-snapshot field) (or (plist-get props :value) "")
          (etaf-ui--text-input-active field) t)
    (setq etaf-ui--active-text-input field)
    (with-current-buffer buffer
      (setq etaf-ui--field-cursor (cons (local-variable-p 'cursor-type) cursor-type))
      (setq-local cursor-type '(bar . 2))
      (add-hook 'post-command-hook #'etaf-ui--text-input-blur nil t)
      (add-hook 'window-selection-change-functions #'etaf-ui--text-input-blur nil t)
      (add-hook 'window-buffer-change-functions #'etaf-ui--text-input-blur nil t))
    (etaf-runtime-set-input-finisher runtime #'etaf-ui--text-input-finish-active)
    (etaf-set-value (etaf-ui--text-input-focused field) t)
    (when-let* ((callback (plist-get props :on-focus)))
      (funcall callback))
    field))

;;;###autoload
(defun etaf-text-input-end (&optional how)
  "Finish the active text input's session and return its text.
HOW nil submits: the field's `:on-submit' callback receives the text.  HOW
`blur' leaves the field keeping its text as the value, without callbacks.
Any other HOW cancels: the value captured at activation is restored through
the change callback and `:on-cancel' receives the abandoned text.  Return nil
when no field is active.  A dead buffer or a failing callback still releases
the session."
  (when-let* ((field etaf-ui--active-text-input)
              (session (etaf-ui--text-input-session field)))
    (let* ((runtime (etaf-ui--text-input-runtime field))
           (buffer (etaf-runtime-buffer runtime))
           (props (etaf-ui--text-input-props field))
           (text (etaf-input-text session)))
      ;; Ownership clears first: nothing below may leave the field active even
      ;; when a callback or the renderer fails.
      (setf (etaf-ui--text-input-session field) nil
            (etaf-ui--text-input-active field) nil)
      (setq etaf-ui--active-text-input nil)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (remove-hook 'post-command-hook #'etaf-ui--text-input-blur t)
          (remove-hook 'window-selection-change-functions #'etaf-ui--text-input-blur t)
          (remove-hook 'window-buffer-change-functions #'etaf-ui--text-input-blur t)
          (when etaf-ui--field-cursor
            (if (car etaf-ui--field-cursor)
                (setq-local cursor-type (cdr etaf-ui--field-cursor))
              (kill-local-variable 'cursor-type))
            (setq etaf-ui--field-cursor nil))))
      (unwind-protect
          (progn
            (etaf-input-end session)
            (when (etaf-runtime-mounted-p runtime)
              (etaf-runtime-set-input-finisher runtime nil)
              (etaf-set-value (etaf-ui--text-input-focused field) nil))
            (cond
             ((eq how 'blur))
             (how
              (when-let* ((callback (plist-get props :change-handler)))
                (funcall callback (etaf-ui--text-input-snapshot field)))
              (when-let* ((callback (plist-get props :on-cancel)))
                (funcall callback text)))
             (t
              (when-let* ((callback (plist-get props :on-submit)))
                (funcall callback text)))))
        (when (etaf-runtime-mounted-p runtime)
          (etaf-runtime-flush runtime)))
      text)))

;;;###autoload
(defun etaf-text-input-active-p (&optional runtime)
  "Return the text input currently editing in RUNTIME, or nil.
RUNTIME defaults to the Runtime of the active field, so this query works from
any buffer."
  (when (and etaf-ui--active-text-input
             (or (null runtime)
                 (eq runtime (etaf-ui--text-input-runtime etaf-ui--active-text-input))))
    etaf-ui--active-text-input))

(etaf-define-component etaf-text-input
    (&key (value etaf-ui--unsupplied) bind (on-change etaf-ui--unsupplied)
          (label "Text") (placeholder "") (rows 1) (width 'stretch)
          (variant 'outlined) disabled read-only (submit-on-return etaf-ui--unsupplied)
          on-submit on-cancel on-focus completion-functions keymap hide-label ref)
  "Edit text directly inside the application's layout.
VALUE/ON-CHANGE or a writable BIND supplies the controlled string; ROWS sets
the minimum visible lines (1 is a single-line input, more is a text area) and
the field grows with longer values.  Activation starts a native editing
session on the field's value, so typed keys, input methods, point, selection,
undo and the kill ring behave as in an ordinary buffer while the frame,
padding and wrapping stay in place; a click inside the field moves the caret
and a click elsewhere leaves it, keeping the text.  Return submits when
`:submit-on-return' is non-nil (default for one row) and otherwise inserts a
newline; Shift+Return and C-j insert a newline; C-c C-c and Ctrl+Return
submit; C-c C-k cancels and restores the activation value; Escape leaves
the session keeping its text and its Host focus; TAB
and backtab leave and move application focus.

ON-SUBMIT and ON-CANCEL receive the session text; ON-FOCUS runs without
arguments once editing begins.  PLACEHOLDER shows while the
value is empty and never becomes its content.  VARIANT `outlined' (default)
draws a panel with a hairline frame that turns to the accent colour while the
field edits; `plain' draws only the text, for a composer whose container
already provides the surface.  Neither changes geometry when focus changes.
READ-ONLY allows focus and copy but no session; DISABLED also removes
activation.  COMPLETION-FUNCTIONS configures CAPF for the session's
completion commands and KEYMAP adds bindings that run in the application
buffer."
  :bindings ((runtime (etaf-current-runtime))
             (field-ref (etaf-local-ref 'field))
             (text-ref (etaf-local-ref 'field-text))
             (field (etaf-ui--text-input-create
                     :runtime runtime :ref (or ref field-ref) :text-ref text-ref
                     :focused (etaf-ref nil))))
  :validate
  (progn
    (etaf-check-prop :rows rows (and (integerp rows) (> rows 0))
                     "a positive line count" 'etaf-text-input)
    (etaf-check-prop :label label (stringp label) "a string" 'etaf-text-input)
    (etaf-check-prop :placeholder placeholder (stringp placeholder) "a string"
                     'etaf-text-input)
    (etaf-check-prop :variant variant (memq variant '(outlined plain))
                     "`outlined' or `plain'" 'etaf-text-input)
    (etaf-check-prop :width width
                     (or (symbolp width) (consp width)) "an Ebox length" 'etaf-text-input)
    (dolist (callback (list on-submit on-cancel on-focus))
      (etaf-check-prop :callback callback (or (null callback) (functionp callback))
                       "a function or nil" 'etaf-text-input))
    (etaf-check-prop :completion-functions completion-functions
                     (and (proper-list-p completion-functions)
                          (cl-every #'functionp completion-functions))
                     "a list of completion functions" 'etaf-text-input)
    (let ((reserved (and keymap (keymapp keymap)
                        (etaf-keymap-reserved-events keymap))))
      (etaf-check-prop :keymap keymap
                       (and (or (null keymap) (keymapp keymap)) (null reserved))
                       (if reserved
                           (format "a keymap or nil without framework-reserved keys (found %s)"
                                   (mapconcat #'key-description reserved ", "))
                         "a keymap or nil")
                       'etaf-text-input)))
  :setup
  (let ((sources (mapcar (lambda (name) (cons name (etaf-prop name)))
                         '(:value :bind :on-change :placeholder :rows :disabled
                           :read-only :submit-on-return :on-submit :on-cancel
                           :on-focus :completion-functions :keymap))))
    (setf (etaf-ui--text-input-props-fn field)
          (lambda ()
            (let (props)
              (dolist (entry sources)
                (setq props (plist-put props (car entry) (etaf-value (cdr entry)))))
              (let* ((input (etaf-ui--controlled-input
                             'etaf-text-input :value (plist-get props :bind)
                             (plist-get props :value) (plist-get props :on-change)))
                     (text (etaf-ui--reactive-value (car input))))
                (etaf-check-prop :value text
                                 (or (null text) (stringp text))
                                 "a string or nil" 'etaf-text-input)
                (plist-put (plist-put props :value text) :change-handler (cdr input))))))
    (etaf-on-mounted
     (lambda ()
       (puthash (etaf-ui--text-input-ref field) field
                (etaf-ui--text-input-table (etaf-ui--text-input-runtime field)))))
    (etaf-on-unmounted
     (lambda ()
       ;; Unmounting is not a submission: keep the user's text as the draft.
       (when (etaf-ui--text-input-active field) (etaf-text-input-end 'blur))
       (let* ((runtime (etaf-ui--text-input-runtime field))
              (table (gethash runtime etaf-ui--text-inputs)))
         (when table
           (remhash (etaf-ui--text-input-ref field) table)
           (when (= (hash-table-count table) 0) (remhash runtime etaf-ui--text-inputs)))))))
  :render
  (let* ((props (etaf-ui--text-input-props field))
         (current (or (plist-get props :value) ""))
         (outlined (eq variant 'outlined))
         (focused (etaf-value (etaf-ui--text-input-focused field))))
    (etaf-ui--input-field
     label hide-label
     (list
      (etaf-node
       'box
       (list :ref (or ref field-ref) :role 'textbox :aria-label label
             :tab-index (unless disabled 0) :disabled disabled
             :width width :min-height (list 'lh rows)
             ;; A stretching field fills the rest of its row next to a label.
             ;; Its fixed basis decides line breaking, so the label never
             ;; jumps to another line as the value grows.
             :flex-grow (if (eq width 'stretch) 1 0) :min-width '(ch 0)
             :flex-basis (when (eq width 'stretch) '(ch 12))
             :padding (if outlined
                          (etaf-theme-token :ui-input-padding '((lh 0) (ch 1)))
                        '((lh 0) (ch 0)))
             :border-radius (when outlined (etaf-theme-token :ui-input-radius '(px 0)))
             :background-color (when outlined
                                 (etaf-theme-token :ui-input-bg
                                                   (etaf-ui--style-token :ui-panel-bg)))
             ;; The frame is always present so focus only changes its colour.
             :border (when outlined
                       (etaf-ui--style-border
                        (if focused (etaf-ui--style-token :ui-accent)
                          (etaf-theme-token :ui-input-border
                                            (etaf-ui--style-token :ui-panel-border)))))
             :color (when outlined (etaf-ui--style-token :ui-panel-fg))
             :on-press (unless disabled
                         (if read-only
                             (lambda () nil)
                           (lambda ()
                             (etaf-text-input-begin runtime (or ref field-ref)))))
             :class "etaf-text-input")
       (cons (etaf-node 'text
                        (list :ref text-ref
                              :color (when outlined (etaf-ui--style-token :ui-panel-fg)))
                        (list current))
             ;; The placeholder follows the empty value, so the caret sits
             ;; before it and typing replaces it.
             (when (and (equal current "") (not (equal placeholder "")))
               (list (etaf-node 'text (list :color (etaf-ui--style-token :ui-muted-fg))
                                (list placeholder)))))))
     nil
     ;; A field nested in another wrapping row must measure at its own width:
     ;; Ebox measures a stretching flex child at the whole row, which would
     ;; push a number input's steppers onto separate lines.  An explicit
     ;; field width sizes this row to its content instead.
     (when (consp width) (list :width 'max-content)))))

(etaf-define-component etaf-search-field
    (&key (value etaf-ui--unsupplied) bind (on-change etaf-ui--unsupplied)
          (placeholder "Search") (width 'stretch) icon on-focus on-submit
          on-cancel on-clear keymap ref)
  "Render a rounded search field editing a controlled query.
VALUE/ON-CHANGE or a writable BIND supplies the query, edited live through
`etaf-text-input' so ON-CHANGE sees every keystroke.  The field is a pill
three rows tall whose painted surface leaves half a row above and below the
text.  PLACEHOLDER shows while the query is empty; ICON non-nil adds a
magnifier before it.  A clear button follows a nonempty query: it empties
the query, calls ON-CLEAR and keeps editing.  A press anywhere on the pill
begins editing.
ON-FOCUS, ON-SUBMIT, ON-CANCEL and KEYMAP follow `etaf-text-input'; REF
names the input for `etaf-text-input-begin'."
  :bindings ((runtime (etaf-current-runtime))
             (field-ref (etaf-local-ref 'search)))
  :validate
  (progn
    (etaf-check-prop :placeholder placeholder (stringp placeholder) "a string"
                     'etaf-search-field)
    (etaf-check-prop :on-clear on-clear (or (null on-clear) (functionp on-clear))
                     "a function or nil" 'etaf-search-field))
  :render
  (let* ((input (etaf-ui--controlled-input 'etaf-search-field :value
                                           bind value on-change))
         (text (or (etaf-ui--reactive-value (car input)) ""))
         (change (cdr input))
         (target (or ref field-ref))
         (muted (etaf-ui--style-token :ui-muted-fg)))
    (etaf-node
     'flex
     (list :class "etaf-search-field" :role 'search
           :flex-direction 'row :align-items 'center
           :width width :min-width '(ch 0) :flex-shrink 1
           :flex-grow (if (eq width 'stretch) 1 0)
           :flex-basis (when (eq width 'stretch) '(ch 0))
           :column-gap '(ch 1) :padding-inline '(ch 2) :padding-block '(lh 0.5)
           :border-radius '(px 16) :pointer 'text
           :background-color (etaf-ui--style-token :ui-search-bg)
           :color (etaf-ui--style-token :ui-search-fg)
           :on-press (lambda () (etaf-text-input-begin runtime target)))
     (delq
      nil
      (list
       (and icon
            (etaf-node 'box (list :flex-shrink 0 :color muted)
                       (list (etaf-ui-icon 'search :min-width 1))))
       (etaf-node
        'box (list :flex-grow 1 :flex-shrink 1 :flex-basis '(ch 0)
                   :min-width '(ch 0))
        (list (etaf-node
               'etaf-text-input
               (list :value text :on-change change :label placeholder
                     :hide-label t :placeholder placeholder :variant 'plain
                     :width 'stretch :on-focus on-focus :on-submit on-submit
                     :on-cancel on-cancel :keymap keymap :ref target)
               nil)))
       (and (not (string-empty-p text))
            (etaf-node 'box (list :flex-shrink 0 :color muted :pointer 'hand)
                       (list (etaf-ui-icon
                              'close :min-width 1 :help-echo "Clear"
                              :on-press (lambda ()
                                          (when (etaf-text-input-active-p runtime)
                                            (etaf-text-input-end 'blur))
                                          (funcall change "")
                                          (when on-clear (funcall on-clear))
                                          (etaf-text-input-begin runtime target)))))))))))

(provide 'etaf-ui-field)
;;; etaf-ui-field.el ends here
