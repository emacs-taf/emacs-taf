;;; etaf-ui-pane.el --- Pane furniture: logs and a status bar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A pane layout spends its edges on structure, so its furniture has to live
;; inside single rows.  These two components cover the pieces a workspace puts
;; around its content: a log whose level column is coloured instead of boxed,
;; and a status bar that states the mode and the keys of the moment without a
;; frame of its own.

;;; Code:

(require 'etaf-ui-style)

(defun etaf-ui--pane-colours ()
  "Return the colours the pane components paint with."
  (etaf-ui--style-tokens :ui-panel-fg :ui-panel-bg :ui-panel-border
                         :ui-muted-fg :ui-accent :ui-success-fg
                         :ui-warning-fg :ui-danger-fg))

(defun etaf-ui--log-level-colour (level colours)
  "Return the ink of LEVEL from COLOURS."
  (pcase (and level (downcase (format "%s" level)))
    ("error" (plist-get colours :ui-danger-fg))
    ("warn" (plist-get colours :ui-warning-fg))
    ((or "info" "notice") (plist-get colours :ui-accent))
    ("success" (plist-get colours :ui-success-fg))
    (_ (plist-get colours :ui-muted-fg))))

(etaf-define-component etaf-log
    (&key rows (level-width 5) (time-width 8) (width 'stretch) ref)
  "Render ROWS as a log, one entry per row.
Each row is a plist with :time, :level and :message.  The time and the level
are muted and coloured, the level column has LEVEL-WIDTH cells and the time
TIME-WIDTH, and the message fills the rest; nothing is boxed, because a pane
already draws the frame."
  :validate
  (etaf-check-prop :rows rows (proper-list-p rows)
                   "a list of entries" 'etaf-log)
  :render
  (let* ((colours (etaf-ui--pane-colours))
         (mono (or (face-attribute 'fixed-pitch :family nil t) "monospace"))
         (ink (plist-get colours :ui-panel-fg))
         (muted (plist-get colours :ui-muted-fg)))
    (etaf-node
     'column
     (list :class "etaf-log" :ref ref :width width :item-gap '(lh 0))
     (mapcar
      (lambda (row)
        (let ((time (or (plist-get row :time) ""))
              (level (or (plist-get row :level) ""))
              (message (or (plist-get row :message) "")))
          (etaf-node
           'flex
           (list :width 'stretch :column-gap '(ch 1))
           (list
            (etaf-node 'text
                       (list :font-family mono :color muted)
                       (list (format (format "%%%ds" time-width) time)))
            (etaf-node 'text
                       (list :font-family mono
                             :color (etaf-ui--log-level-colour level colours)
                             :font-weight 'bold)
                       (list (format (format "%%-%ds" level-width) level)))
            (etaf-node 'box
                       (list :flex-basis '(ch 0) :flex-grow 1 :wrap-mode 'char)
                       (list (etaf-node 'text
                                        (list :font-family mono :color ink)
                                        (list message))))))))
      rows))))

(etaf-define-component etaf-status-bar
    (&key mode (keys nil) (note nil) (width 'stretch) ref)
  "Render a one-row status bar with MODE, KEYS and NOTE.
MODE is a filled chip naming the current mode; KEYS is a list of (KEY .
LABEL) pairs, painted as a key and its meaning; NOTE sits at the right end.
The bar owns no frame: it reads as the bottom edge of the window."
  :validate
  (progn
    (etaf-check-prop :keys keys (proper-list-p keys)
                     "a list of (key . label) pairs" 'etaf-status-bar)
    (etaf-check-prop :mode mode (or (null mode) (stringp mode))
                     "a string or nil" 'etaf-status-bar))
  :render
  (let* ((colours (etaf-ui--pane-colours))
         (mono (or (face-attribute 'fixed-pitch :family nil t) "monospace"))
         (surface (plist-get colours :ui-panel-bg))
         (muted (plist-get colours :ui-muted-fg))
         (accent (plist-get colours :ui-accent)))
    (etaf-node
     'flex
     (list :class "etaf-status-bar" :ref ref :width width :align-items 'center
           :background-color surface
           :border-top (etaf-ui--style-border (plist-get colours :ui-panel-border))
           :padding '((lh 0) (ch 1)))
     (append
      (when mode
        (list (etaf-node
               'box
               (list :background-color accent
                     :color (etaf-ui-color-legible surface accent)
                     :padding-inline '(ch 1))
               (list (etaf-node 'text
                                (list :font-family mono :font-weight 'bold)
                                (list (upcase mode)))))))
      (cl-loop for (key . label) in keys
               append
               (list (etaf-node 'text
                                (list :font-family mono :color muted)
                                (list (format " %s " key)))
                     (etaf-node 'text
                                (list :color muted)
                                (list (format "%s  " label)))))
      (list (etaf-node 'box (list :flex-basis '(ch 0) :flex-grow 1) nil))
      (when note
        (list (etaf-node 'text (list :color muted) (list note))))))))

(provide 'etaf-ui-pane)
;;; etaf-ui-pane.el ends here
