;;; etaf-md-env.el --- What a node paint may read -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A paint receives one argument, the environment of the block being painted:
;; the node itself plus the services the renderer owns.  It reads attributes
;; through `etaf-md-attr', paints children through `etaf-md-content' and
;; `etaf-md-render', and turns `surface' and `accent' words into colours.  It
;; cannot read a file, reach the network or see another block.
;;
;; The environment has one node.  A child is passed back in as the last
;; argument of `etaf-md-attr', `etaf-md-children' or `etaf-md-render', never by
;; mutating the environment.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui)
(require 'etaf-md-node)
(require 'etaf-md-theme)

(declare-function etaf-md--republish "etaf-md-model" (session))
(declare-function etaf-md--env "etaf-md-model" (session))
(declare-function etaf-md--open-url "etaf-md-model" (session url))
(declare-function etaf-md--wrap-heading "etaf-md-views" (block view))

(cl-defstruct (etaf-md-env (:constructor etaf-md-env-create)
                           (:copier nil))
  "The context one block is painted in."
  session
  node
  width
  state
  palette
  theme
  block
  slot
  root-begin)

(defun etaf-md--env-with-width (env width)
  "Return a copy of ENV whose available column count is narrowed to WIDTH."
  (etaf-md-env-create
   :session (etaf-md-env-session env)
   :node (etaf-md-env-node env)
   :width (max 1 width)
   :state (etaf-md-env-state env)
   :palette (etaf-md-env-palette env)
   :theme (etaf-md-env-theme env)
   :block (etaf-md-env-block env)
   :slot (etaf-md-env-slot env)
   :root-begin (etaf-md-env-root-begin env)))

(defun etaf-md--markdown-env (env)
  "Return the `etaf-ui-markdown' rendering env for paint ENV.
Preserves the page services (media, links, footnotes) while binding `:width'
to ENV's own available columns and bridging per-block interactive state."
  (let* ((session (etaf-md-env-session env))
         (base (if session
                   (copy-sequence (etaf-md--env session))
                 (list :theme (etaf-md-env-theme env)
                       :palette (etaf-md-env-palette env)))))
    (setq base (plist-put base :width (etaf-md-env-width env)))
    (when session
      (setq base (plist-put base :block-state
                            (lambda (key &optional default)
                              (etaf-md-block-state env key default))))
      (setq base (plist-put base :set-block-state
                            (lambda (key value)
                              (etaf-md-set-block-state env key value)))))
    base))

(defun etaf-md--paint (node env)
  "Return the view ENV's definition gives NODE, or a failure line."
  (let* ((type (etaf-md-node-type node))
         (definition (etaf-md-node-definition type))
         (problems (and definition (plist-get definition :view)
                        (etaf-md--all-problems node))))
    (cond
     (problems
      (etaf-md--failure-view
       env (or (etaf-md-node-source node) "") (cadr (car problems))))
     ((and definition (plist-get definition :view))
      (let ((inner (etaf-md-env-create
                    :session (etaf-md-env-session env)
                    :node node
                    :width (etaf-md-env-width env)
                    :state (etaf-md-env-state env)
                    :palette (etaf-md-env-palette env)
                    :theme (etaf-md-env-theme env)
                    :block (etaf-md-node-block node)
                    :slot (etaf-md-env-slot env)
                    :root-begin (etaf-md-env-root-begin env))))
        (condition-case err
            (funcall (plist-get definition :view) inner)
          (etaf-md-error
           (etaf-md--failure-view
            env (or (etaf-md-node-source node) "")
            (or (and (stringp (cadr err)) (cadr err))
                (error-message-string err)))))))
     ;; A Markdown block the new model does not define yet keeps the painter
     ;; it has today; only a container with no definition is a failure,
     ;; because a container cannot be painted without one.
     ((and (etaf-md-node-block node)
           (not (eq (plist-get (etaf-md-node-block node) :type) 'container)))
      (let ((block (etaf-md-node-block node)))
        (etaf-md--wrap-heading
         block
         (etaf-ui-markdown-view-block
          block
          ;; A block painted below a container keeps the page services: media,
          ;; links and the page directory are part of the environment the block
          ;; was written for, and a minimal plist would show a placeholder.
          (etaf-md--markdown-env env)))))
     (t
      (etaf-md--failure-view
       env (or (etaf-md-node-source node)
               (format "::: %s" (or (etaf-md-node-type node) "?")))
       (format "没有 %s 的定义" type))))))

(defun etaf-md--failure-view (env source message)
  "Return SOURCE painted as text with MESSAGE under it."
  (etaf-view
   (column :item-gap '(lh 0)
     (text :color (etaf-md--muted env)
       (expr source))
     (text :color (etaf-md--muted env) :font-weight 'bold
       (expr message)))))

(defun etaf-md--muted (env)
  "Return the muted ink of ENV's palette."
  (or (etaf-md--palette-value (etaf-md-env-palette env) :muted) "#9198a1"))

(defun etaf-md--hover-p (env)
  "Return non-nil when ENV's session enables pointer hover feedback."
  (let ((session (etaf-md-env-session env)))
    (if (and session (plist-member session :link-hover))
        (plist-get session :link-hover)
      t)))

(defun etaf-md--hover-fill (env &optional variant)
  "Return a theme-derived hover fill for leaf controls in ENV, or nil."
  (when (etaf-md--hover-p env)
    (let ((palette (etaf-md-env-palette env)))
      (pcase variant
        ('soft (or (etaf-md--palette-value palette :panel2)
                   (etaf-md--palette-value palette :panel)))
        (_ (or (etaf-md--palette-value palette :accent-soft)
               (etaf-md--palette-value palette :panel2)))))))

(defun etaf-md--leaf-button (env label on-press &rest opts)
  "Return a single-face interactive leaf control in ENV.
OPTS accepts `:selected', `:disabled', `:color', `:background', `:role',
`:help', `:bold', `:hover-variant'.  Selected or disabled leaves suppress
`:hover-style' so interactive states never stack, and hover applies strictly
to this leaf text node without touching surrounding container styling."
  (let* ((selected (plist-get opts :selected))
         (disabled (plist-get opts :disabled))
         (role (or (plist-get opts :role) 'button))
         (help (plist-get opts :help))
         (bold (if (plist-member opts :bold) (plist-get opts :bold) selected))
         (accent (etaf-md-accent env 'primary))
         (muted (etaf-md--muted env))
         (palette (etaf-md-env-palette env))
         (color (or (plist-get opts :color)
                    (cond (disabled (or (etaf-md--palette-value palette :faint) muted))
                          (selected accent)
                          (t accent))))
         (bg (or (plist-get opts :background)
                 (when selected
                   (or (etaf-md--palette-value palette :accent-soft)
                       (etaf-md-surface env 'sunken)))))
         (interactive-p (and (not disabled) (functionp on-press)))
         (hover (and interactive-p (not selected)
                     (etaf-md--hover-fill env (plist-get opts :hover-variant)))))
    (etaf-node 'text
               (append
                (list :color color)
                (when bg (list :background-color bg))
                (when bold (list :font-weight 'bold))
                (when help (list :help-echo help))
                (when interactive-p
                  (list :role role :tab-index 0 :pointer 'hand
                        :on-press on-press))
                (when hover
                  (list :hover-style (list :background-color hover))))
               (list label))))

(defun etaf-md--hairline (env)
  "Return a one-pixel border as the Theme ENV's page lives in defines it.
The border token is the theme's own line colour.  Drawing the frame in an
accent instead would reuse the body ink, which is four times heavier than the
hairline the markdown tables already use; an accent is a highlight, not an
edge.  The palette supplies the fallback for a page mounted without a Theme."
  (etaf-theme-token
   :ui-panel-border
   (plist-get (etaf-md-theme-tokens (etaf-md-env-theme env)
                                    (etaf-md-env-palette env))
              :ui-panel-border)
   (lambda (color) (list (list 'px 1) 'solid color))))

;;; The twelve functions

(defun etaf-md-attr (env key &optional node)
  "Return KEY's final value on NODE, or on ENV's own node.
A style rule wins over the document, the document over the declaration's
default, and a derived attribute has only the value the parser or the derive
step wrote."
  (etaf-md--value (or node (etaf-md-env-node env)) key env))

(defun etaf-md-type (env)
  "Return the type name of ENV's node."
  (etaf-md-node-type (etaf-md-env-node env)))

(defun etaf-md-children (env &optional node)
  "Return NODE's children, or ENV's own node's children."
  (etaf-md-node-children (or node (etaf-md-env-node env))))

(defun etaf-md-content (env)
  "Return ENV's children painted as one view."
  (etaf-md-render env (etaf-md-children env)))

(defun etaf-md-render (env nodes)
  "Return NODES painted as one view, stacked in document order.
Separates adjacent block views inside containers with one blank line, matching
top-level document block rhythm."
  (let ((views
         (delq nil
               (mapcar (lambda (node) (etaf-md--paint node env))
                       (cl-remove-if
                        (lambda (node) (eq (plist-get node :type) 'blank))
                        nodes)))))
    (etaf-view
     (column :width 'stretch :item-gap '(lh 1)
       (expr views)))))

(defun etaf-md--palette-value (palette key)
  "Return KEY's colour from PALETTE, in alist or plist form.
A theme palette is an alist; a hand-built one may be a plist.  Both reach
the same component, so the lookup accepts either."
  (or (alist-get key palette) (plist-get palette key)))

(defun etaf-md-surface (env word)
  "Return surface WORD as a colour for ENV, or nil for none."
  (let ((palette (etaf-md-env-palette env)))
    (pcase word
      ('none nil)
      ('page (etaf-md--palette-value palette :bg))
      ('raised (or (etaf-md--palette-value palette :panel)
                   (etaf-md--palette-value palette :panel2)))
      ('sunken (or (etaf-md--palette-value palette :sunken)
                   (etaf-md--palette-value palette :panel2)
                   (etaf-md--palette-value palette :panel)))
      ('quote (etaf-md--palette-value palette :quote-bg))
      ('table-header (etaf-md--palette-value palette :table-header))
      ('table-stripe (etaf-md--palette-value palette :table-stripe)))))

(defun etaf-md-accent (env word)
  "Return accent WORD as a colour for ENV.
Every word reads the page's palette first, so a light page and a dark page
keep their own ink instead of sharing one fixed set of colours."
  (let* ((palette (etaf-md-env-palette env))
         (value (lambda (key fallback)
                  (or (etaf-md--palette-value palette key) fallback))))
    (pcase word
      ('neutral (funcall value :muted "#9198a1"))
      ('primary (funcall value :accent "#4493f8"))
      ('info (funcall value :accent "#4493f8"))
      ('success (funcall value :ok "#2da44e"))
      ('warning (funcall value :warn "#bf8700"))
      ('danger (funcall value :danger "#cf222e"))
      ('important (funcall value :important "#8250df")))))

(defun etaf-md-default-view (env)
  "Return ENV's node painted with the definition's previous view."
  (let ((definition (etaf-md-node-definition (etaf-md-node-type (etaf-md-env-node env)))))
    (if-let* ((view (plist-get definition :default-view)))
        (funcall view env)
      (etaf-md--paint (etaf-md-env-node env) env))))

(defun etaf-md-follow-link (env target)
  "Open TARGET for ENV's session; return non-nil when it was followed."
  (let ((session (etaf-md-env-session env)))
    (when (and session target)
      (if-let* ((open (plist-get session :open-url)))
          (funcall open target)
        (etaf-md--open-url session target))
      t)))

(defun etaf-md--block-identity (env)
  "Return the identity ENV's block keeps across repaints and edits above it.
Top-level containers use their block's stable slot symbol; nested containers
combine that slot with their type and offset relative to the top-level block so
editing lines above the container never resets its interactive state."
  (let* ((slot (etaf-md-env-slot env))
         (node (etaf-md-env-node env))
         (block (and node (etaf-md-node-block node)))
         (begin (and block (plist-get block :begin)))
         (root-begin (etaf-md-env-root-begin env)))
    (cond
     ((and slot (or (null begin) (null root-begin) (eql begin root-begin)))
      slot)
     (slot
      (list slot (etaf-md-node-type node) (- begin root-begin)))
     (t (or begin 0)))))

(defun etaf-md--block-state-ref (session identity)
  "Return the pre-allocated reactive ref storing state for IDENTITY.
Each top-level block owns its own `etaf-ref' in SESSION's `:block-states'
table (allocated when its entry is created, never during `:render'), so
toggling one control repaints only that block.  Falls back to SESSION's
`:block-state' ref when IDENTITY is not associated with a block slot."
  (when session
    (let ((table (plist-get session :block-states))
          (slot (if (consp identity) (car identity) identity)))
      (or (and (hash-table-p table) (gethash slot table))
          (plist-get session :block-state)))))

(defun etaf-md--block-state-prune (session slot)
  "Remove interactive container state belonging to retired SLOT in SESSION."
  (when-let* ((table (and session (plist-get session :block-states)))
              ((hash-table-p table)))
    (remhash slot table)))

(defun etaf-md-block-state (env key &optional default)
  "Return KEY's state for ENV's block, or DEFAULT.
Reads only this block's dedicated reactive ref, so toggling another container
never wakes this one."
  (let* ((session (etaf-md-env-session env))
         (identity (etaf-md--block-identity env))
         (ref (etaf-md--block-state-ref session identity))
         (alist (and (etaf-ref-p ref) (etaf-value ref)))
         (cell (and alist (assoc (cons identity key) alist))))
    (if cell (cdr cell) default)))

(defun etaf-md-set-block-state (env key value)
  "Store VALUE under KEY for ENV's block and repaint only that block."
  (let* ((session (etaf-md-env-session env))
         (identity (etaf-md--block-identity env))
         (ref (etaf-md--block-state-ref session identity)))
    (when (etaf-ref-p ref)
      (let* ((alist (copy-alist (etaf-value ref)))
             (full-key (cons identity key))
             (cell (assoc full-key alist)))
        (if cell
            (setcdr cell value)
          (push (cons full-key value) alist))
        (etaf-set-value ref alist))))
  value)

(defun etaf-md-available-width (env)
  "Return the columns ENV's block may occupy."
  (etaf-md-env-width env))

(provide 'etaf-md-env)
;;; etaf-md-env.el ends here
