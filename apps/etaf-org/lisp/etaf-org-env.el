;;; etaf-org-env.el --- Rendering environment and 12 node primitives -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Every node paint function receives one argument, ENV — the context of the
;; block being painted.  Through the twelve public `env' primitives it reads
;; resolved attributes (`etaf-org-attr'), inspects node type and children,
;; converts semantic `surface' and `accent' words to theme colors, paints
;; children (`etaf-org-content' / `etaf-org-render'), delegates to the previous
;; paint (`etaf-org-default-view'), follows links, reads/writes per-block
;; reactive state, and queries available column width.
;;
;; All interactive leaf controls go through `etaf-org--leaf-button', enforcing
;; strict leaf-only pointer hover discipline (selected or disabled leaves
;; suppress `:hover-style', and multi-styled containers never attach hover).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc)
(require 'etaf-org-node)
(require 'etaf-org-theme)

(declare-function etaf-org--open-target "etaf-org-model" (session target))
(declare-function etaf-org--env "etaf-org-model" (session))
(declare-function etaf-org--block-view "etaf-org-views" (block env))
(declare-function etaf-org--propagate-target "etaf-org-model" (session target-id key value))

(cl-defstruct (etaf-org-env (:constructor etaf-org-env-create)
                            (:copier nil))
  "The rendering context handed to a node paint function."
  session
  node
  width
  state
  palette
  theme
  block
  slot
  section
  legacy-env)

(defun etaf-org--env-with-width (env width)
  "Return a copy of ENV whose available column count is narrowed to WIDTH."
  (let* ((legacy (etaf-org-env-legacy-env env))
         (next-legacy (when legacy
                        (plist-put (copy-sequence legacy) :width (max 1 width)))))
    (etaf-org-env-create
     :session (etaf-org-env-session env)
     :node (etaf-org-env-node env)
     :width (max 1 width)
     :state (etaf-org-env-state env)
     :palette (etaf-org-env-palette env)
     :theme (etaf-org-env-theme env)
     :block (etaf-org-env-block env)
     :slot (etaf-org-env-slot env)
     :section (etaf-org-env-section env)
     :legacy-env next-legacy)))

(defun etaf-org--env-for-node (env node &optional width)
  "Return a child environment derived from ENV bound to NODE."
  (let* ((w (max 1 (or width (etaf-org-env-width env) 88)))
         (legacy (etaf-org-env-legacy-env env))
         (next-legacy (when legacy
                        (plist-put (copy-sequence legacy) :width w))))
    (etaf-org-env-create
     :session (etaf-org-env-session env)
     :node node
     :width w
     :state (etaf-org-env-state env)
     :palette (etaf-org-env-palette env)
     :theme (etaf-org-env-theme env)
     :block (etaf-org-node-block node)
     :slot (etaf-org-env-slot env)
     :section (etaf-org-env-section env)
     :legacy-env next-legacy)))

(defun etaf-org--palette-value (palette key)
  "Return KEY's color from PALETTE (alist or plist)."
  (or (cdr (assq key palette)) (plist-get palette key)))

(defun etaf-org--env-color (env key)
  "Return semantic color KEY from ENV's palette."
  (let ((palette (if (etaf-org-env-p env)
                     (etaf-org-env-palette env)
                   (plist-get env :palette))))
    (or (etaf-org--palette-value palette key)
        (etaf-org--palette-value (cdr (assq 'light etaf-org-themes)) key))))

(defun etaf-org--muted (env)
  "Return the muted foreground color for ENV."
  (or (etaf-org--env-color env :muted) "#9198a1"))

(defun etaf-org--mono-family ()
  "Return the optional `:font-mono' theme token, or nil for unified body font.
Matches `etaf-ui-markdown--mono-family': avoids forcing Emacs `fixed-pitch'
(\"Monospace\") which switches to mismatched fallback fonts on macOS/Windows."
  (let ((family (etaf-theme-token :font-mono nil)))
    (and (stringp family) (not (string-empty-p family)) family)))

(defun etaf-org--hover-p (env)
  "Return non-nil when ENV's session enables pointer hover feedback."
  (let ((session (if (etaf-org-env-p env)
                     (etaf-org-env-session env)
                   (plist-get env :session))))
    (if (and session (plist-member session :link-hover))
        (plist-get session :link-hover)
      t)))

(defun etaf-org--hover-fill (env &optional variant)
  "Return a theme-derived hover fill for unselected leaf controls in ENV."
  (when (etaf-org--hover-p env)
    (let ((palette (if (etaf-org-env-p env)
                       (etaf-org-env-palette env)
                     (plist-get env :palette))))
      (pcase variant
        ('soft (or (etaf-org--palette-value palette :panel2)
                   (etaf-org--palette-value palette :panel)))
        (_ (or (etaf-org--palette-value palette :accent-soft)
               (etaf-org--palette-value palette :panel2)))))))

(defun etaf-org--leaf-button (env label on-press &rest opts)
  "Return a single-face interactive leaf control in ENV."
  (let ((palette (if (etaf-org-env-p env)
                     (etaf-org-env-palette env)
                   (plist-get env :palette))))
    (apply #'etaf-doc-widget-leaf-button
           palette label on-press
           :hover (etaf-org--hover-p env)
           opts)))

(defun etaf-org--hairline (env)
  "Return a 1px solid hairline border spec matching ENV's theme."
  (list '(px 1) 'solid (or (etaf-org--env-color env :border) "#d1d9e0")))

(defun etaf-org--failure-view (env source messages)
  "Return an inline non-blocking diagnostic view for SOURCE with MESSAGES."
  (let ((msgs (if (listp messages) messages (list messages)))
        (muted (etaf-org--muted env))
        (danger (or (etaf-org--env-color env :danger) "#d1242f"))
        (panel (etaf-org--env-color env :panel)))
    (etaf-node 'column
               (list :width 'stretch
                     :item-gap '(lh 0)
                     :background-color panel
                     :border-left (list '(px 2) 'solid danger)
                     :padding '((lh 0) (ch 2)))
               (append
                (mapcar (lambda (msg)
                          (etaf-node 'text
                                     (list :color danger :font-weight 'bold)
                                     (list (format "%s" msg))))
                        msgs)
                (when (and (stringp source) (not (string-empty-p source)))
                  (list (etaf-node 'box
                                   (list :width 'stretch :wrap-mode 'char)
                                   (list (etaf-node 'text
                                                    (list :color muted)
                                                    (list source))))))))))

(defun etaf-org--paint (node env)
  "Paint NODE in ENV using its registered definition, or degrade cleanly."
  (cond
   ((null node) nil)
   ((etaf-org-node-p node)
    (let* ((type (etaf-org-node-type node))
           (def (etaf-org-node-definition type))
           (problems (when (and def (plist-get def :view))
                       (etaf-org--validate-node node))))
      (cond
       (problems
        (etaf-org--failure-view env (or (etaf-org-node-source node) "") problems))
       ((and def (plist-get def :view))
        (let ((inner (etaf-org--env-for-node env node)))
          (condition-case err
              (funcall (plist-get def :view) inner)
            (error
             (etaf-org--failure-view
              env
              (or (etaf-org-node-source node) "")
              (format "%s 渲染失败：%s" type (error-message-string err)))))))
       ((etaf-org-node-block node)
        (etaf-org--block-view (etaf-org-node-block node)
                              (or (etaf-org-env-legacy-env env)
                                  (and (etaf-org-env-session env)
                                       (etaf-org--env (etaf-org-env-session env))))))
       (t
        (etaf-org--failure-view
         env
         (or (etaf-org-node-source node)
             (format "#+begin_%s" (or type "?")))
         (format "line %d: 没有 %s 的定义"
                 (or (etaf-org-node-line node) 1) type))))))
   ;; Plain parsed block plist inside a container body.
   ((and (listp node) (keywordp (car node)))
    (etaf-org--block-view node
                          (or (etaf-org-env-legacy-env env)
                              (and (etaf-org-env-session env)
                                   (etaf-org--env (etaf-org-env-session env))))))
   (t nil)))

;;; ---------------------------------------------------------------------------
;;; The twelve public env functions
;;; ---------------------------------------------------------------------------

(defun etaf-org-attr (env key &optional node)
  "Return KEY's resolved value on NODE, or on ENV's own node.
Style rules beat the document, the document beats the declaration's default,
and derived attributes come exclusively from parse/derive."
  (let* ((target (or node (etaf-org-env-node env)))
         (val (if (etaf-org-node-p target)
                  (etaf-org--resolve-attr target key)
                (plist-get (plist-get target :attrs) (etaf-org--attr-key key)))))
    ;; Resolve color tokens to actual palette colors when attribute type is `color'.
    (if (and (etaf-org-node-p target) (stringp val))
        (let* ((def (etaf-org-node-definition (etaf-org-node-type target)))
               (decl (etaf-org--declaration (plist-get def :attrs) key)))
          (if (and decl (eq (plist-get decl :type) 'color)
                   (not (string-prefix-p "#" val)))
              (etaf-org--resolve-color-token env val)
            val))
      val)))

(defun etaf-org--resolve-color-token (env token)
  "Resolve semantic color TOKEN name to a palette color in ENV."
  (pcase (intern (downcase (format "%s" token)))
    ('background (etaf-org--env-color env :bg))
    ('foreground (etaf-org--env-color env :ink))
    ('muted (etaf-org--env-color env :muted))
    ('faint (etaf-org--env-color env :faint))
    ('border (etaf-org--env-color env :border))
    ('surface-raised (etaf-org--env-color env :panel))
    ('surface-sunken (or (etaf-org--env-color env :sunken)
                         (etaf-org--env-color env :panel2)))
    ('quote (etaf-org--env-color env :quote-bg))
    ('quote-bar (etaf-org--env-color env :quote-bar))
    ('table-header (etaf-org--env-color env :table-header))
    ('table-stripe (etaf-org--env-color env :table-stripe))
    ('heading (etaf-org--env-color env :heading))
    ('primary (etaf-org--env-color env :accent))
    ('primary-soft (etaf-org--env-color env :accent-soft))
    ('success (etaf-org--env-color env :ok))
    ('success-soft (etaf-org--env-color env :ok-soft))
    ('warning (etaf-org--env-color env :warn))
    ('warning-soft (etaf-org--env-color env :warn-soft))
    ('danger (etaf-org--env-color env :danger))
    ('danger-soft (etaf-org--env-color env :danger-soft))
    ('important (etaf-org--env-color env :important))
    ('important-soft (etaf-org--env-color env :important-soft))
    (_ (or (etaf-org--env-color env (etaf-org--attr-key token))
           token))))

(defun etaf-org-type (env)
  "Return the node type symbol of ENV's node."
  (when-let* ((node (etaf-org-env-node env)))
    (if (etaf-org-node-p node)
        (etaf-org-node-type node)
      (plist-get node :type))))

(defun etaf-org-children (env &optional node)
  "Return NODE's children, or ENV's node's children, in document order."
  (let ((target (or node (etaf-org-env-node env))))
    (cond
     ((etaf-org-node-p target) (etaf-org-node-children target))
     ((listp target) (or (plist-get target :children) (plist-get target :blocks)))
     (t nil))))

(defun etaf-org-render (env nodes)
  "Paint NODES as a vertical column View in ENV."
  (let* ((items (if (and (listp nodes)
                         (not (etaf-org-node-p nodes))
                         (not (keywordp (car nodes))))
                    nodes
                  (list nodes)))
         (views (delq nil (mapcar (lambda (n) (etaf-org--paint n env)) items))))
    (when views
      (if (= (length views) 1)
          (car views)
        (etaf-node 'column
                   (list :width 'stretch :item-gap '(lh 1))
                   views)))))

(defun etaf-org-content (env)
  "Paint all children of ENV's node as one View."
  (etaf-org-render env (etaf-org-children env)))

(defun etaf-org-surface (env word)
  "Convert semantic surface WORD to a palette color in ENV, or nil for `none'."
  (let ((sym (if (symbolp word) word (intern (downcase (format "%s" word))))))
    (pcase sym
      ('none nil)
      ('page (etaf-org--env-color env :bg))
      ('raised (etaf-org--env-color env :panel))
      ('sunken (or (etaf-org--env-color env :sunken)
                   (etaf-org--env-color env :panel2)))
      ('quote (etaf-org--env-color env :quote-bg))
      ('table-header (etaf-org--env-color env :table-header))
      ('table-stripe (etaf-org--env-color env :table-stripe))
      (_ nil))))

(defun etaf-org-accent (env word &optional soft)
  "Convert accent WORD to its foreground (or SOFT fill) color in ENV."
  (let ((sym (if (symbolp word) word (intern (downcase (format "%s" word))))))
    (if soft
        (pcase sym
          ('primary (etaf-org--env-color env :accent-soft))
          ('info (etaf-org--env-color env :info-soft))
          ('success (etaf-org--env-color env :ok-soft))
          ('warning (etaf-org--env-color env :warn-soft))
          ('danger (etaf-org--env-color env :danger-soft))
          ('important (etaf-org--env-color env :important-soft))
          (_ (etaf-org--env-color env :panel)))
      (pcase sym
        ('primary (etaf-org--env-color env :accent))
        ('info (etaf-org--env-color env :info))
        ('success (etaf-org--env-color env :ok))
        ('warning (etaf-org--env-color env :warn))
        ('danger (etaf-org--env-color env :danger))
        ('important (etaf-org--env-color env :important))
        (_ (etaf-org--env-color env :ink))))))

(defun etaf-org-default-view (env)
  "Paint ENV's node with its previous (shipped) view function."
  (let* ((node (etaf-org-env-node env))
         (type (and (etaf-org-node-p node) (etaf-org-node-type node)))
         (def (and type (etaf-org-node-definition type)))
         (prev (or (plist-get def :default-view)
                   (plist-get (plist-get def :shipped) :view))))
    (when (functionp prev)
      (funcall prev env))))

(defun etaf-org-follow-link (env target)
  "Open link TARGET through ENV's session; return non-nil when handled."
  (when (and (stringp target) (not (string-blank-p target)))
    (if-let* ((session (etaf-org-env-session env)))
        (progn (etaf-org--open-target session target) t)
      nil)))

(defun etaf-org-block-state (env key &optional default)
  "Return per-block reactive state for KEY in ENV, or DEFAULT."
  (let ((state-ref (etaf-org-env-state env)))
    (if (etaf-ref-p state-ref)
        (let ((plist (etaf-value state-ref)))
          (if (plist-member plist key #'equal)
              (plist-get plist key #'equal)
            default))
      default)))

(defun etaf-org-set-block-state (env key value)
  "Store VALUE under KEY in ENV's per-block reactive state and return VALUE.
When ENV's node declares `:target', propagates `:selected' updates to that
target block."
  (let ((state-ref (etaf-org-env-state env)))
    (when (etaf-ref-p state-ref)
      (let* ((old (copy-sequence (or (etaf-value state-ref) nil)))
             (next (plist-put old key value #'equal)))
        (etaf-set-value state-ref next)))
    (when-let* ((node (etaf-org-env-node env))
                ((etaf-org-node-p node))
                (target (etaf-org-attr env :target))
                (session (etaf-org-env-session env))
                ((fboundp 'etaf-org--propagate-target)))
      (when (eq key :selected)
        (etaf-org--propagate-target session target :selected value)))
    value))

(defun etaf-org-available-width (env)
  "Return the available column count for ENV's block."
  (max 8 (or (etaf-org-env-width env)
             (and (etaf-org-env-legacy-env env)
                  (plist-get (etaf-org-env-legacy-env env) :width))
             88)))

(provide 'etaf-org-env)
;;; etaf-org-env.el ends here
