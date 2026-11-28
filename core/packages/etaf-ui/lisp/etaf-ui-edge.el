;;; etaf-ui-edge.el --- Panels and controls whose rule carries their label -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A text frame pays for its rules with cells, so a titled panel that puts the
;; title on its own row spends a row of content on decoration.  These three
;; components put the label on the rule itself: the panel title sits in the
;; first row, where the frame's top rule runs across it, and the tabs share
;; that same rule instead of owning a strip above it.  A field's rule runs
;; directly under its value, so a form reads as text with lines rather than as
;; boxes around text.
;;
;; Everything here is built from a box's own border and padding, which the
;; renderer paints as cell decorations rather than as extra rows, so none of
;; the three costs a row of content.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-style)

(defun etaf-ui--edge-colors ()
  "Return the panel colours these components paint with."
  (etaf-ui--style-tokens :ui-panel-fg :ui-panel-bg :ui-panel-border
                         :ui-accent :ui-accent-soft-bg :ui-muted-fg))

(etaf-define-component etaf-edge-panel
    (&key title status (variant 'default) focus accent background
          (width 'stretch) margin-top ref)
  "Render a panel whose TITLE sits on the panel's top rule.
STATUS, when given, is painted at the right end of the same rule, so a panel
names itself and reports without spending a row.  VARIANT `flat' drops the
surface and keeps the rule; ACCENT paints the rule and the title in one
colour, which is how a workspace tells its panes apart; FOCUS paints the rule
in the accent colour.  The caller's default slot is the body, under the title."
  :validate
  (progn
    (etaf-check-prop :variant variant (memq variant '(default flat))
                     "`default' or `flat'" 'etaf-edge-panel)
    (etaf-check-prop :accent accent (or (null accent) (stringp accent))
                     "a colour string or nil" 'etaf-edge-panel))
  :render
  (let* ((colours (etaf-ui--edge-colors))
         (line (cond (focus (plist-get colours :ui-accent))
                     (accent accent)
                     (t (plist-get colours :ui-panel-border))))
         (surface (unless (eq variant 'flat)
                    (or background (plist-get colours :ui-panel-bg)))))
    (etaf-view
     (box :class (format "etaf-edge-panel %s%s"
                         (symbol-name variant) (if focus " focus" ""))
       :width width :ref ref :margin-top margin-top
       :border (etaf-ui--style-border line)
       :background-color surface
       :padding '((lh 0) (ch 1))
       (expr (when (or title status)
               (etaf-view
                (flex :class "etaf-edge-panel-title" :width 'stretch
                  (text :color (or accent (plist-get colours :ui-panel-fg))
                        :font-weight 'bold
                    (expr (or title "")))
                  (box :flex-basis '(ch 0) :flex-grow 1)
                  (text :class "etaf-edge-panel-status"
                        :color (plist-get colours :ui-muted-fg)
                    (expr (or status "")))))))
       ;; The body never touches the rule: one blank row above and below is
       ;; what makes a pane read as a page rather than as a boxed paragraph.
       (box :width 'stretch :padding '((lh 1) (ch 0))
         (expr (etaf-current-slot 'default)))))))

(etaf-define-component etaf-edge-tabs
    (&key items active on-change accent (width 'stretch) margin-top ref)
  "Render ITEMS as tabs set into the panel's top rule.
The frame's rule runs across the tab row, so the labels sit on the edge of
the pane instead of on a strip above it; the chosen tab takes the accent ink,
a bold weight and the raised surface, and the other tabs stay muted.  ACTIVE
is a key from ITEMS, ON-CHANGE receives the key of a pressed tab, and the
caller's default slot is the pane under the rule."
  :validate
  (progn
    (etaf-check-prop :items items (proper-list-p items)
                     "a list of tabs" 'etaf-edge-tabs)
    (etaf-check-prop :on-change on-change (functionp on-change)
                     "a function" 'etaf-edge-tabs)
    (etaf-check-prop :active active
                     (cl-some (lambda (item)
                                (equal active (plist-get item :key)))
                              items)
                     "a key present in :items" 'etaf-edge-tabs))
  :render
  (let* ((colours (etaf-ui--edge-colors))
         (hover-bg (etaf-theme-token :ui-panel-bg "#F6F7F9"
                                     #'etaf-ui--state-hover-shift)))
    (etaf-view
     (box :class "etaf-edge-tabs" :width width :ref ref :margin-top margin-top
       :border (etaf-ui--style-border (or accent
                                          (plist-get colours :ui-panel-border)))
       :background-color (plist-get colours :ui-panel-bg)
       (expr
        (etaf-node
         'flex
         (list :class "etaf-edge-tabs-bar" :width 'stretch :role 'tablist)
         (seq-map
          (lambda (item)
            (let ((selected (equal active (plist-get item :key))))
              (etaf-node
               'box
               (list :class (if selected
                                "etaf-edge-tab selected"
                              "etaf-edge-tab")
                     :role 'tab :tab-index 0
                     :aria-selected selected
                     :aria-label (plist-get item :label)
                     ;; The chosen tab is a filled block, the way a printed
                     ;; index tab is: the accent paints the cell and the page
                     ;; ink sits on it.  Only unselected tabs take pointer hover.
                     :color (if selected
                                (etaf-ui-color-legible
                                 (plist-get colours :ui-panel-bg)
                                 (or accent (plist-get colours :ui-accent)))
                              (plist-get colours :ui-muted-fg))
                     :background-color
                     (and selected (or accent (plist-get colours :ui-accent)))
                     :pointer (unless selected 'hand)
                     :hover-style (unless selected
                                    (list :background-color hover-bg))
                     :font-weight (if selected 'bold nil)
                     :padding-inline '(ch 1)
                     :on-press (lambda ()
                                 (funcall on-change (plist-get item :key))))
               (list (etaf-node 'text nil
                                (list (or (plist-get item :label) "")))))))
          items)))
       (box :width 'stretch :padding '((lh 1) (ch 0))
         (expr (etaf-current-slot 'default)))))))

(etaf-define-component etaf-underline-field
    (&key label value placeholder focus (width 'stretch) ref)
  "Render a read-only field drawn as a line under its value.
LABEL names the field above it in muted ink; VALUE is what the rule carries,
and PLACEHOLDER shows in the muted ink while VALUE is empty.  FOCUS paints
the rule in the accent colour, so a form reads as rows of labelled text
rather than as boxes, and the rule costs no row of its own."
  :render
  (let* ((colours (etaf-ui--edge-colors))
         (value (or value ""))
         (empty (string-empty-p value)))
    (etaf-view
     (column :class "etaf-underline-field" :width width :cross-align 'stretch
       (text :class "etaf-underline-field-label"
             :color (plist-get colours :ui-muted-fg)
         (expr (or label "")))
       (box :class "etaf-underline-field-value" :ref ref
         :width 'stretch
         :border-bottom
         (etaf-ui--style-border
          (if focus (plist-get colours :ui-accent)
            (plist-get colours :ui-panel-border)))
         :padding '((lh 0) (ch 1))
         (text :color (if empty
                          (plist-get colours :ui-muted-fg)
                        (plist-get colours :ui-panel-fg))
           (expr (if empty (or placeholder "") value))))))))

(provide 'etaf-ui-edge)
;;; etaf-ui-edge.el ends here
