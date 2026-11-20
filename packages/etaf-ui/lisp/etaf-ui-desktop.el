;;; etaf-ui-desktop.el --- Reusable desktop navigation Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Presentational Components used by desktop hosts and application shells.
;; These Components deliberately keep all selection, workspace, window and
;; layout state in their callers.  They expose ordinary ETAF callbacks and
;; Behaviors, so a desktop policy can use the same controls in floating and
;; tiled layouts without creating another input or focus system.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-basic)
(require 'etaf-ui-surface)
(require 'etaf-ui-style)

(defun etaf-ui--desktop-scalar-key-p (key)
  "Return non-nil when desktop navigation KEY is a stable scalar."
  (or (symbolp key) (stringp key) (numberp key)))

(defun etaf-ui--desktop-items (items component &optional title-key)
  "Validate desktop ITEM plists for COMPONENT and return them.
TITLE-KEY is the plist key used for the visible caption, defaulting to
`:label'.  An optional :description is accepted for launcher/switcher rows."
  (let ((title-key (or title-key :label)) keys)
    (etaf-check-prop :items items (proper-list-p items)
                     "a list of item plists" component)
    (dolist (item items)
      (etaf-check-prop
       :items item
       (and (proper-list-p item)
            (zerop (% (length item) 2))
            (plist-member item :key)
            (etaf-ui--desktop-scalar-key-p (plist-get item :key))
            (stringp (plist-get item title-key))
            (not (string-empty-p (plist-get item title-key)))
            (not (member (plist-get item :key) keys))
            (or (null (plist-get item :description))
                (stringp (plist-get item :description)))
            (or (null (plist-get item :ref))
                (symbolp (plist-get item :ref))))
       "items with unique scalar :key and nonempty caption" component)
      (push (plist-get item :key) keys))
    items))

(defun etaf-ui--desktop-item-caption (item title-key)
  "Return ITEM's TITLE-KEY caption.

State is communicated by the surrounding button presentation.  Keeping the
caption free of marker glyphs avoids a noisy taskbar and leaves the text width
stable as focus changes."
  (plist-get item title-key))

(defun etaf-ui--desktop-bar-item-tone (item-key active state)
  "Return ITEM-KEY's presentation tone from ACTIVE and STATE sources.
Both sources are read unconditionally so a Host property binding keeps one
stable dependency set whichever tone currently wins."
  (let ((active-key (etaf-ui--reactive-value active))
        (state (etaf-ui--reactive-value state)))
    (cond ((equal item-key active-key) 'active)
          ((eq state 'minimized) 'minimized)
          (t 'plain))))

(etaf-define-component etaf-ui--desktop-bar-item
    (&key item-key label ref active disabled callback state class active-class
          minimized-class)
  "Project controlled selection onto one stateless navigation Host.

Tone colors are Theme tokens read inside Host property bindings, so both a
selection change and a Theme change stay retained paint updates."
  :view
  (box :ref ref :role 'button :aria-label label
       :aria-selected (eq (etaf-ui--desktop-bar-item-tone item-key active state)
                          'active)
       :width 'max-content :disabled disabled
       :tab-index (unless disabled 0) :pointer (unless disabled 'arrow)
       :on-press callback :padding '((lh 0) (ch 1.5))
       :class (pcase (etaf-ui--desktop-bar-item-tone item-key active state)
                ('active active-class)
                ('minimized minimized-class)
                (_ class))
       :color (pcase (etaf-ui--desktop-bar-item-tone item-key active state)
                ('active (etaf-ui--style-token :ui-accent))
                ('minimized (etaf-ui--style-token :ui-shell-item-minimized-fg))
                (_ (etaf-ui--style-token :ui-shell-item-fg)))
       :background-color
       (pcase (etaf-ui--desktop-bar-item-tone item-key active state)
         ('active (etaf-ui--style-token :ui-accent-soft-bg))
         (_ (etaf-ui--style-token :ui-shell-bg)))
       :font-weight 'normal
       ;; A reactive label reads like a Label text; a source object would reach
       ;; the Text Host unresolved.
       (text (expr (etaf-ui--text-value label)))))

(defun etaf-ui--desktop-ref (ref-prefix name)
  "Return the runtime Host reference NAME under REF-PREFIX.
A desktop that embeds another application can mount several bars in one ETAF
Runtime; a caller-supplied prefix keeps their Host references distinct."
  (if (and (stringp ref-prefix) (not (string-empty-p ref-prefix)))
      (intern (concat ref-prefix name))
    (intern name)))

(defun etaf-ui--desktop-bar-item-node (item active on-select taskbar
                                            &optional ref-prefix)
  "Build ITEM's selection Host using ACTIVE and ON-SELECT.
TASKBAR selects window-state presentation.  REF-PREFIX namespaces the
workspace-tab Host reference."
  (let* ((key (plist-get item :key))
         (disabled (plist-get item :disabled))
         (class (etaf-ui--class-value
                 "etaf-button" (if disabled "disabled" "enabled")
                 (if taskbar "etaf-taskbar-item" "etaf-workspace-item"))))
    (etaf-node
     'etaf-ui--desktop-bar-item
     (append
      (list :key key :item-key key :label (plist-get item :label)
            :ref (or (plist-get item :ref)
                     (unless taskbar
                       (etaf-ui--desktop-ref
                        ref-prefix (format "etaf-workspace-%s" key))))
            :active active :disabled disabled
            :callback (and on-select (not disabled)
                           (lambda () (funcall on-select key)))
            :class class :active-class (concat class " active")
            :minimized-class (concat class " minimized")
            :state (and taskbar (plist-get item :state)))
      (unless taskbar (list :flex-shrink 0 :min-width 'max-content)))
     nil)))

(etaf-define-component etaf-ui--desktop-status (&key status)
  "Render STATUS in the workspace bar's remaining single-row space.
An absent or empty STATUS paints one blank character so the Text keeps
owning the row's pixels: a status that becomes empty then publishes as a
retained Text update instead of re-rendering the bar."
  :view
  (box :class "etaf-workspace-status"
       :flex-grow 1 :flex-basis '(px 0)
       :min-width '(px 0) :height '(lh 1)
       :wrap-mode 'none :overflow 'hidden
    (text :color (etaf-ui--style-token :ui-shell-muted-fg)
          (expr (let ((value (etaf-ui--reactive-value status)))
                  (etaf-check-prop :status value
                                   (or (null value) (stringp value))
                                   "a string or nil" 'etaf-workspace-bar)
                  (if (or (null value) (string-empty-p value)) " " value))))))

(defconst etaf-ui--desktop-layout-label-width 13
  "Character width reserved by the workspace bar's layout control.
It holds labels up to eight characters plus the control's padding.")

(etaf-define-component etaf-ui--desktop-layout-label (&key label)
  "Render the workspace bar's layout control LABEL as one reactive Text payload.
The control keeps a fixed width so a changed label rewrites only its own
text instead of laying out the bar again."
  :view
  (text (expr (let ((value (etaf-ui--reactive-value label)))
                (etaf-check-prop :layout-label value (stringp value)
                                 "a string" 'etaf-workspace-bar)
                value))))

(etaf-define-component etaf-taskbar
    (&key items active on-select on-launch (launcher-label "Applications")
          ref-prefix class)
  "Render a controlled TASKBAR for desktop windows.

ITEMS are plists with scalar :key and nonempty string :label.  Optional
:state is `active', `minimized', `error' or nil, or a ref or computed of
one, and :disabled suppresses activation.  ACTIVE may be a scalar key, nil,
ref or computed and marks the focused item.  The caller owns all window
state.  ON-SELECT receives an item key; ON-LAUNCH, when supplied, opens the
caller's launcher.  REF-PREFIX namespaces the Host references this bar creates,
so a caller can mount several taskbars in one ETAF Runtime.  Colors come from
the inherited Theme's `:ui-shell-*' and `:ui-accent*' tokens."
  :validate
  (progn
    (etaf-ui--desktop-items items 'etaf-taskbar)
    (dolist (item items)
      (etaf-check-prop :disabled (plist-get item :disabled)
                       (booleanp (plist-get item :disabled)) "a boolean"
                       'etaf-taskbar)
      (let ((state (plist-get item :state)))
        (etaf-check-prop :state state
                         (or (etaf-ref-p state) (etaf-computed-p state)
                             (memq state '(nil active minimized error)))
                         "nil, active, minimized, error, ref or computed"
                         'etaf-taskbar)))
    (etaf-check-prop :active active
                     (or (etaf-ref-p active) (etaf-computed-p active)
                         (etaf-ui--desktop-scalar-key-p active))
                     "a taskbar key, nil, ref or computed" 'etaf-taskbar)
    (etaf-check-prop :on-select on-select
                     (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-taskbar)
    (etaf-check-prop :on-launch on-launch
                     (or (null on-launch) (functionp on-launch))
                     "a function or nil" 'etaf-taskbar)
    (etaf-check-prop :launcher-label launcher-label (stringp launcher-label)
                     "a string" 'etaf-taskbar)
    (etaf-check-prop :ref-prefix ref-prefix
                     (or (null ref-prefix) (stringp ref-prefix))
                     "a string or nil" 'etaf-taskbar))
  :render
  (let ((shell (etaf-ui--style-tokens :ui-shell-bg :ui-shell-fg
                                      :ui-shell-muted-fg)))
    (etaf-node
     'row
     (list :class (etaf-ui--class-value "etaf-taskbar" nil class)
           :role 'toolbar :aria-label "Taskbar" :width 'stretch
           :focus-group 'horizontal
           :height '(lh 1) :item-gap '(ch 1)
           :padding '((lh 0) (ch 1))
           :background-color (plist-get shell :ui-shell-bg)
           :color (plist-get shell :ui-shell-fg))
     (append
      (when on-launch
        (list (etaf-node 'etaf-button
                         (list :label (concat "⊞ " launcher-label)
                               :aria-label launcher-label :variant 'primary
                               :class "etaf-taskbar-launcher"
                               :ref (etaf-ui--desktop-ref ref-prefix
                                                          "etaf-taskbar-launcher")
                               :on-press on-launch)
                         nil)))
      (or
       (mapcar
        (lambda (item)
          (etaf-ui--desktop-bar-item-node item active on-select t ref-prefix))
        items)
       (list (etaf-node 'text
                        (list :color (plist-get shell :ui-shell-muted-fg))
                        (list "No windows"))))))))

(etaf-define-component etaf-workspace-bar
    (&key workspaces active on-select on-add on-close (add-label "New workspace")
          brand status layout-label layout-action settings-label settings-action
          ref-prefix class)
  "Render controlled WORKSPACES as an accessible workspace switcher bar.

WORKSPACES may contain scalar keys or plists with :key, :label, optional
:description and :disabled.  ACTIVE is a selected key, ref or computed.
STATUS is a string, nil, ref or computed.  Its single-row region uses the
remaining bar width and clips excess text, keeping trailing actions at the
right edge.  ON-SELECT receives a key; ON-ADD and ON-CLOSE are optional
caller-owned policy actions.
LAYOUT-LABEL and LAYOUT-ACTION render the trailing control that reports and
switches the workspace's window-management mode.  LAYOUT-LABEL is a string,
ref or computed of one; the control keeps a fixed width so a changed label
publishes as a retained Text update.  SETTINGS-LABEL and
SETTINGS-ACTION optionally add a trailing caller-owned settings action.  No
workspace is created, removed or persisted by this Component.  REF-PREFIX
namespaces the Host references this bar creates, so a caller can mount several
bars in one ETAF Runtime without their tabs and trailing controls shadowing
each other.  Colors come from the inherited Theme's `:ui-shell-*' and
`:ui-accent*' tokens."
  :validate
  (progn
    (etaf-check-prop :workspaces workspaces (proper-list-p workspaces)
                     "a list of workspace keys or item plists"
                     'etaf-workspace-bar)
    (dolist (workspace workspaces)
      (when (listp workspace)
        (etaf-ui--desktop-items (list workspace) 'etaf-workspace-bar))
      (when (not (listp workspace))
        (etaf-check-prop :workspace workspace
                         (etaf-ui--desktop-scalar-key-p workspace)
                         "a scalar key or item plist" 'etaf-workspace-bar)))
    (etaf-check-prop :on-select on-select
                     (or (null on-select) (functionp on-select))
                     "a function or nil" 'etaf-workspace-bar)
    (etaf-check-prop :on-add on-add (or (null on-add) (functionp on-add))
                     "a function or nil" 'etaf-workspace-bar)
    (etaf-check-prop :on-close on-close
                     (or (null on-close) (functionp on-close))
                     "a function or nil" 'etaf-workspace-bar)
    (etaf-check-prop :add-label add-label (stringp add-label)
                     "a string" 'etaf-workspace-bar)
    (etaf-check-prop :brand brand (or (null brand) (stringp brand))
                     "a string or nil" 'etaf-workspace-bar)
    (etaf-check-prop :status status
                     (or (null status) (stringp status)
                         (etaf-ref-p status) (etaf-computed-p status))
                     "a string, nil, ref or computed" 'etaf-workspace-bar)
    (etaf-check-prop :layout-label layout-label
                     (or (null layout-label) (stringp layout-label)
                         (etaf-ref-p layout-label)
                         (etaf-computed-p layout-label))
                     "a string, nil, ref or computed" 'etaf-workspace-bar)
    (etaf-check-prop :layout-action layout-action
                     (or (null layout-action) (functionp layout-action))
                     "a function or nil" 'etaf-workspace-bar)
    (etaf-check-prop :settings-label settings-label
                     (or (null settings-label) (stringp settings-label))
                     "a string or nil" 'etaf-workspace-bar)
    (etaf-check-prop :settings-action settings-action
                     (or (null settings-action) (functionp settings-action))
                     "a function or nil" 'etaf-workspace-bar)
    (etaf-check-prop :ref-prefix ref-prefix
                     (or (null ref-prefix) (stringp ref-prefix))
                     "a string or nil" 'etaf-workspace-bar))
  :render
  (let ((items
         (mapcar
          (lambda (workspace)
            (if (listp workspace)
                workspace
              (list :key workspace :label (format "%s" workspace))))
          workspaces))
        (shell (etaf-ui--style-tokens :ui-shell-bg :ui-shell-fg
                                      :ui-shell-item-fg)))
    (etaf-node
     'flex
     (list :class (etaf-ui--class-value "etaf-workspace-bar" nil class)
           :role 'tablist :aria-label "Workspaces" :width 'stretch
           :focus-group 'horizontal
           :height '(lh 1) :flex-direction 'row :gap '((lh 0) (ch 1))
           :padding '((lh 0) (ch 1))
           :background-color (plist-get shell :ui-shell-bg)
           :color (plist-get shell :ui-shell-fg))
     (append
      (when brand
        (list (etaf-node 'text
                         (list :font-weight 'bold
                               :color (plist-get shell :ui-shell-fg))
                         (list brand))))
      (mapcar
       (lambda (item)
         (etaf-ui--desktop-bar-item-node item active on-select nil ref-prefix))
       items)
      (when on-add
        (list (etaf-node 'etaf-button
                         (list :label "+" :aria-label add-label
                               :flex-shrink 0 :min-width 'max-content
                               :variant 'ghost :on-press on-add)
                         nil)))
      (when on-close
        (list (etaf-node 'etaf-button
                         (list :label "×" :aria-label "Close workspace bar"
                               :flex-shrink 0 :min-width 'max-content
                               :variant 'ghost :on-press on-close)
                         nil)))
      (when (or status layout-label (and settings-label settings-action))
        (list (etaf-node 'etaf-ui--desktop-status (list :status status) nil)))
      (when layout-label
        (list (etaf-node 'etaf-button
                         (list :label (if (stringp layout-label)
                                          layout-label "Window layout")
                               :aria-label (if (stringp layout-label)
                                               layout-label "Window layout")
                               :ref (etaf-ui--desktop-ref ref-prefix
                                                          "etaf-workspace-layout")
                               :variant 'secondary
                               :class "etaf-workspace-layout"
                               ;; A fixed allocation keeps a reactive label
                               ;; change inside its own relayout boundary.
                               :width (list 'ch etaf-ui--desktop-layout-label-width)
                               :flex-shrink 0 :overflow 'hidden
                               :pointer 'hand
                               :on-press layout-action)
                         (list (etaf-node 'etaf-ui--desktop-layout-label
                                          (list :label layout-label) nil)))))
      (when (and settings-label settings-action)
        (list (etaf-node 'etaf-button
                         (list :label settings-label
                               :aria-label settings-label
                               :ref (etaf-ui--desktop-ref ref-prefix
                                                          "etaf-workspace-settings")
                               :variant 'ghost
                               :class "etaf-workspace-settings"
                               :flex-shrink 0 :min-width 'max-content
                               :color (plist-get shell :ui-shell-item-fg)
                               :pointer 'arrow
                               :on-press settings-action)
                         nil)))))))

(defun etaf-ui--desktop-launcher-items (items component)
  "Validate launcher ITEMS and return them unchanged."
  (etaf-ui--desktop-items items component)
  (dolist (item items)
    (etaf-check-prop :disabled (plist-get item :disabled)
                     (booleanp (plist-get item :disabled)) "a boolean"
                     component)
    (etaf-check-prop :state (plist-get item :state)
                     (memq (plist-get item :state) '(nil active minimized error))
                     "nil, active, minimized or error" component))
  items)

(defun etaf-ui--desktop-picker-body (items on-select selected class)
  "Build a picker body for ITEMS with ON-SELECT and SELECTED key.
CLASS names the body for styling.

Items render as full-width rows: a caption, an optional muted description
and, for the SELECTED item, an accent marker and tinted background.  Colors
are Theme tokens so a Desktop Theme restyles the picker in place; the
selected row uses the secondary button tint, a dialog token that stays
crisp while the shell behind the picker is dimmed."
  (let ((tokens (etaf-ui--style-tokens :ui-picker-item-bg :ui-picker-item-fg
                                       :ui-picker-item-muted-fg
                                       :ui-button-secondary-fg
                                       :ui-button-secondary-bg :ui-panel-bg)))
    (etaf-node
     'column
     (list :class class :width 'stretch :item-gap '(lh 1))
     (mapcar
      (lambda (item)
        (let* ((key (plist-get item :key))
               (disabled (plist-get item :disabled))
               (is-selected (and selected (equal key selected)))
               (caption (etaf-ui--desktop-item-caption item :label))
               (description (plist-get item :description))
               (bg (if is-selected
                       (plist-get tokens :ui-button-secondary-bg)
                     (plist-get tokens :ui-picker-item-bg))))
          (etaf-node
           'box
           (list :key key :ref (plist-get item :ref)
                 :class (etaf-ui--class-value
                         "etaf-picker-item" (if disabled "disabled" "enabled")
                         (and is-selected "selected"))
                 :role 'button :aria-label (plist-get item :label)
                 :disabled disabled :tab-index (unless disabled 0)
                 :pointer (unless disabled 'arrow)
                 :width 'stretch :padding '((lh 0) (ch 2))
                 :color (if is-selected
                            (plist-get tokens :ui-button-secondary-fg)
                          (plist-get tokens :ui-picker-item-fg))
                 :background-color bg
                 :on-press (and on-select (not disabled)
                                (lambda () (funcall on-select key))))
           (list (etaf-node
                  'column (list :item-gap '(lh 0) :width 'stretch)
                  (append
                   (list (etaf-node 'text
                                    (list :font-weight
                                          (if is-selected 'bold 'normal))
                                    (list caption)))
                   (when description
                     (list (etaf-node
                            'text
                            (list :color (plist-get tokens :ui-picker-item-muted-fg))
                            (list (concat "  " description)))))))))))
      items))))

(defun etaf-ui--desktop-picker-height (items)
  "Return the `(lh N)' Dialog height that fits picker ITEMS exactly.

Each item occupies one caption row plus one description row when described,
separated by one row; the card's header, body air and footer add five rows."
  (let ((rows 0))
    (dolist (item items)
      (setq rows (+ rows (if (plist-get item :description) 2 1))))
    (list 'lh (+ rows (max 0 (1- (length items))) 5))))

(etaf-define-component etaf-launcher
    (&key open (title "Applications") items on-select on-close
          (close-label "Close") (backdrop t))
  "Render a controlled application LAUNCHER in a modal Dialog.

ITEMS use :key/:label and optional :description, :state and :disabled.  The
launcher owns no registry or open state.  ON-SELECT receives the selected key;
the caller normally closes OPEN after handling it.  ON-CLOSE is required when
OPEN is true so Escape and the close button remain accessible.  BACKDROP nil
keeps the underlying surface painted; a Desktop then dims it through its own
Theme while the launcher is open."
  :validate
  (progn
    (etaf-ui--desktop-launcher-items items 'etaf-launcher)
    (etaf-check-prop :backdrop backdrop (booleanp backdrop) "a boolean" 'etaf-launcher)
    (etaf-check-prop :on-select on-select (functionp on-select)
                     "a function" 'etaf-launcher)
    (etaf-check-prop :on-close on-close (functionp on-close)
                     "a function" 'etaf-launcher)
    (etaf-check-prop :title title (stringp title) "a string" 'etaf-launcher)
    (etaf-check-prop :close-label close-label (stringp close-label)
                     "a string" 'etaf-launcher))
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-dialog
               (list :open open :title title :close-label close-label
                     :on-close on-close :width '(ch 56) :backdrop backdrop
                     :height (etaf-ui--desktop-picker-height items))
               (list (etaf-ui--desktop-picker-body items on-select nil
                                                   "etaf-launcher-list")))))

(etaf-define-component etaf-switcher
    (&key open (title "Switch application") items selected on-select on-close
          (close-label "Close") (backdrop t))
  "Render a controlled application/window SWITCHER in a modal Dialog.

The presentation is shared with `etaf-launcher', but SELECTED marks the
currently focused item.  ON-SELECT receives a key and the caller controls
whether the switcher closes, changes focus or changes workspace.  BACKDROP
follows `etaf-launcher'."
  :validate
  (progn
    (etaf-ui--desktop-launcher-items items 'etaf-switcher)
    (etaf-check-prop :backdrop backdrop (booleanp backdrop) "a boolean" 'etaf-switcher)
    (let ((selected-value (etaf-ui--reactive-value selected)))
      (etaf-check-prop :selected selected-value
                       (or (null selected-value)
                           (cl-some (lambda (item)
                                     (equal selected-value (plist-get item :key))) items))
                     "a key from :items or nil" 'etaf-switcher)
    (etaf-check-prop :on-select on-select (functionp on-select)
                     "a function" 'etaf-switcher)
    (etaf-check-prop :on-close on-close (functionp on-close)
                     "a function" 'etaf-switcher)
    (etaf-check-prop :title title (stringp title) "a string" 'etaf-switcher)
    (etaf-check-prop :close-label close-label (stringp close-label)
                     "a string" 'etaf-switcher)))
  :render
  (let ((selected (etaf-ui--reactive-value selected)))
    (when (etaf-ui--reactive-value open)
      (etaf-node 'etaf-dialog
                 (list :open open :title title :close-label close-label
                       :on-close on-close :width '(ch 56) :backdrop backdrop
                       :height (etaf-ui--desktop-picker-height items))
                 (list (etaf-ui--desktop-picker-body items on-select selected
                                                     "etaf-switcher-list"))))))

(defun etaf-ui--reactive-source-p (value)
  "Return non-nil when VALUE is an ETAF ref or computed."
  (or (etaf-ref-p value) (etaf-computed-p value)))

(defun etaf-ui--splitter-overlay-rect-p (rect)
  "Return non-nil when RECT is a complete positioned divider rectangle.
Each entry is a scalar unit value or a ref or computed.  Reactive entries
are accepted by shape without being read: validation runs in the
Component's input effect, and reading them there would make every
rectangle change re-render the divider instead of publishing through its
Host bindings."
  (and (proper-list-p rect)
       (= (length rect) 8)
       (cl-loop for key in '(:left :top :width :height)
                for unit in '(px lh px lh)
                for minimum in '(0 0 1 1)
                always (let ((value (plist-get rect key)))
                         (or (etaf-ui--reactive-source-p value)
                             (and (proper-list-p value)
                                  (= (length value) 2)
                                  (eq (car value) unit)
                                  (integerp (cadr value))
                                  (>= (cadr value) minimum)))))))

(etaf-define-component etaf-ui--splitter-overlay-divider
    (&key orientation rect z-index divider-content visible use on-change)
  "Render one positioned divider whose RECT entries are Host bindings.
RECT holds :left/:top/:width/:height scalars or reactive sources,
DIVIDER-CONTENT is a string or a reactive source of one and VISIBLE hides the
divider while keeping its retained node.  Every geometry, content and
visibility read happens inside a Host property expression, so a caller-owned
layout policy updates the divider through its retained bindings."
  :view
  (box :class "etaf-splitter-divider" :role 'separator :tab-index 0
       :aria-label (if (eq orientation 'horizontal) "Resize columns" "Resize rows")
       ;; A left/right split has an upright rule that arrows move sideways.
       :aria-orientation (if (eq orientation 'horizontal) 'vertical 'horizontal)
       :pointer (if (eq orientation 'horizontal) 'hdrag 'vdrag)
       :use use :on-drag on-change
       :z-index (etaf-ui--reactive-value z-index)
       :visibility (if (etaf-ui--reactive-value visible) 'visible 'hidden)
       :background-color (etaf-ui--style-token :ui-divider-bg)
       :position 'absolute
       :left (etaf-ui--reactive-value (plist-get rect :left))
       :top (etaf-ui--reactive-value (plist-get rect :top))
       :width (etaf-ui--reactive-value (plist-get rect :width))
       :height (etaf-ui--reactive-value (plist-get rect :height))
       (text (expr (etaf-ui--text-value divider-content)))))

(etaf-define-component etaf-splitter
    (&key (orientation 'horizontal) (ratio 0.5) (min-ratio 0.1)
          (max-ratio 0.9) on-change use class overlay z-index divider-content
          overlay-rect (visible t))
  "Render a controlled split layout with a keyboard-focusable divider.
Arrows across the focused divider step it like a pointer drag.

HORIZONTAL splits left/right; VERTICAL splits top/bottom.  RATIO is the first
pane's fraction and is caller-owned.  ON-CHANGE receives the raw divider
gesture and USE may contain an ETAF Behavior that converts that gesture into a
new ratio.  Named `first' and `second' slots hold the pane Views.  OVERLAY
renders only the divider for a caller-owned positioned host, and
DIVIDER-CONTENT supplies that divider's rendered extent (a row of characters
for VERTICAL, one character per row for HORIZONTAL) because a positioned box
paints only the content it has.  OVERLAY-RECT optionally supplies the exact
caller-allocated :left/:top/:width/:height for an overlay; absent it, the
divider uses RATIO relative to its positioned parent.  OVERLAY-RECT entries,
DIVIDER-CONTENT, Z-INDEX and VISIBLE may be refs or computed values; the
allocated overlay reads them only inside Host property bindings, so a layout
policy can move, hide or show a divider without re-rendering it.  VISIBLE
defaults to t and applies to allocated overlays.  The Component never stores
a ratio or window/layout policy."
  :validate
  (progn
    (etaf-check-prop :orientation orientation (memq orientation '(horizontal vertical))
                     "horizontal or vertical" 'etaf-splitter)
    (etaf-check-prop :ratio ratio
                     (and (numberp (etaf-ui--reactive-value ratio))
                          (<= min-ratio (etaf-ui--reactive-value ratio) max-ratio))
                     "a ratio within the configured bounds" 'etaf-splitter)
    (etaf-check-prop :min-ratio min-ratio (and (numberp min-ratio) (> min-ratio 0) (< min-ratio 1))
                     "a fraction between zero and one" 'etaf-splitter)
    (etaf-check-prop :max-ratio max-ratio (and (numberp max-ratio) (> max-ratio 0) (< max-ratio 1)
                                               (<= min-ratio max-ratio))
                     "a fraction no smaller than min-ratio" 'etaf-splitter)
    (etaf-check-prop :on-change on-change (or (null on-change) (functionp on-change))
                     "a function or nil" 'etaf-splitter)
    (etaf-check-prop :overlay overlay (booleanp overlay)
                     "a boolean" 'etaf-splitter)
    (etaf-check-prop :z-index z-index
                     (or (null z-index) (integerp z-index)
                         (etaf-ui--reactive-source-p z-index))
                     "nil, an integer, a ref or a computed" 'etaf-splitter)
    (etaf-check-prop :divider-content divider-content
                     (or (null divider-content) (stringp divider-content)
                         (etaf-ui--reactive-source-p divider-content))
                     "nil, a string, a ref or a computed" 'etaf-splitter)
    (etaf-check-prop :visible visible
                     (or (booleanp visible) (etaf-ui--reactive-source-p visible))
                     "a boolean, a ref or a computed" 'etaf-splitter)
    (etaf-check-prop :overlay-rect overlay-rect
                     (or (null overlay-rect)
                         (and overlay
                              (etaf-ui--splitter-overlay-rect-p overlay-rect)))
                     "nil or an overlay (:left (px N) :top (lh N) :width (px N) :height (lh N)) rectangle"
                     'etaf-splitter))
  :render
  (if (and overlay overlay-rect)
      ;; The allocated overlay never reads RATIO: its rectangle and content
      ;; are retained bindings owned by the caller's layout policy.
      (etaf-node 'etaf-ui--splitter-overlay-divider
                 (list :orientation orientation :rect overlay-rect
                       :z-index z-index :divider-content divider-content
                       :visible visible :use use :on-change on-change)
                 nil)
    (let* ((ratio (float (etaf-ui--reactive-value ratio)))
           (first-width (list '% (round (* 100 ratio))))
           (first (etaf-current-slot 'first))
           (second (etaf-current-slot 'second))
           (divider-props
            (list :class "etaf-splitter-divider" :role 'separator :tab-index 0
                  :aria-label (if (eq orientation 'horizontal)
                                  "Resize columns" "Resize rows")
                  :aria-orientation (if (eq orientation 'horizontal)
                                        'vertical 'horizontal)
                  :pointer (if (eq orientation 'horizontal) 'hdrag 'vdrag)
                  :use use :on-drag on-change
                  :z-index (etaf-ui--reactive-value z-index)
                  :background-color (etaf-ui--style-token :ui-divider-bg)))
           (divider
            (if overlay
                (etaf-node
                 'box
                 (append divider-props
                         (if (eq orientation 'horizontal)
                             (list :position 'absolute
                                   :left (list '% (round (* 100 ratio)))
                                   :top '(lh 0) :width '(px 3)
                                   :height 'stretch)
                           (list :position 'absolute :left '(px 0)
                                 :top (list '% (round (* 100 ratio)))
                                 :width 'stretch :height '(lh 1))))
                 (when divider-content
                   (list (etaf-node 'text nil
                                    (list (etaf-ui--reactive-value
                                           divider-content))))))
              (if (eq orientation 'horizontal)
                  (etaf-node 'box
                             (append divider-props
                                     (list :width '(px 3) :height 'stretch)) nil)
                (etaf-node 'box
                           (append divider-props
                                   (list :width 'stretch :height '(lh 1))) nil))))
           (props (list :class (etaf-ui--class-value "etaf-splitter" nil class)
                        :width 'stretch :height 'stretch
                        :overflow 'hidden)))
      (if overlay
          divider
        (if (eq orientation 'horizontal)
            (etaf-node 'flex (append props (list :flex-direction 'row))
                       (list
                        (etaf-node 'box (list :width first-width :height 'stretch
                                              :overflow 'hidden) first)
                        divider
                        (etaf-node 'box (list :flex-grow 1 :min-width '(px 0)
                                              :height 'stretch :overflow 'hidden)
                                   second)))
          (etaf-node 'flex (append props (list :flex-direction 'column))
                     (list
                      (etaf-node 'box (list :height (list '% (round (* 100 ratio)))
                                            :width 'stretch :overflow 'hidden) first)
                      divider
                      (etaf-node 'box (list :flex-grow 1 :min-height '(lh 0)
                                            :width 'stretch :overflow 'hidden)
                                 second))))))))

(etaf-define-component etaf-pane-resizer
    (&key size (side 'right) min max on-change on-end (line t) background ref)
  "Render a vertical divider that resizes an adjacent fixed-width pane.
SIZE is the pane's current width in pixels, a number, ref or computed.
SIDE `right' places the divider on the pane's right, so dragging right
widens it; `left' serves a pane on the divider's right.  Each drag move
passes the candidate width, clamped to MIN and MAX pixels when given, to
ON-CHANGE; ON-END receives the final width.  The divider shows a hairline
in the divider color beside the pane when LINE is non-nil, over
BACKGROUND, and is wide enough to grab.  The focused divider steps the
width one column per Left or Right press.  The width stays caller-owned;
REF reaches the rendered divider so callers can focus or address it."
  :bindings ((origin (list nil)))
  :validate
  (progn
    (etaf-check-prop :side side (memq side '(left right)) "left or right"
                     'etaf-pane-resizer)
    (dolist (callback (list on-change on-end))
      (etaf-check-prop :callback callback (or (null callback) (functionp callback))
                       "a function or nil" 'etaf-pane-resizer))
    (dolist (bound (list min max))
      (etaf-check-prop :bound bound (or (null bound) (numberp bound))
                       "a pixel count or nil" 'etaf-pane-resizer)))
  :render
  (let ((width (lambda (gesture)
                 (let* ((dx (car (plist-get gesture :delta)))
                        (next (+ (car origin) (if (eq side 'right) dx (- dx)))))
                   (round (min (or max next) (max (or min next) next)))))))
    (etaf-node
     'box
     (append
      (list :class "etaf-pane-resizer" :role 'separator
            :ref ref
            :aria-label "Resize pane" :pointer 'hdrag
            :aria-orientation 'vertical
            :tab-index (when (or on-change on-end) 0)
            :width '(px 5) :height 'stretch :flex-shrink 0
            :background-color background
            :on-drag
            (lambda (gesture)
              (pcase (plist-get gesture :phase)
                ('start (setcar origin (etaf-ui--reactive-value size)))
                ((or 'move 'end)
                 (when (car origin)
                   (let ((next (funcall width gesture)))
                     (when on-change (funcall on-change next))
                     (when (eq (plist-get gesture :phase) 'end)
                       (setcar origin nil)
                       (when on-end (funcall on-end next))))))
                ('cancel (setcar origin nil)))))
      (and line
           (if (eq side 'right)
               (list :border-left-width '(px 1) :border-left-style 'solid
                     :border-left-color (etaf-ui--style-token :ui-divider-bg))
             (list :border-right-width '(px 1) :border-right-style 'solid
                   :border-right-color
                   (etaf-ui--style-token :ui-divider-bg)))))
     nil)))

(provide 'etaf-ui-desktop)
;;; etaf-ui-desktop.el ends here
