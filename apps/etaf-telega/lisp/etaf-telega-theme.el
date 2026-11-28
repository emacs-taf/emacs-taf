;;; etaf-telega-theme.el --- Palettes of etaf-telega -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defcustom etaf-telega-theme 'auto "Initial appearance: `auto', `dark', `light' or `native'."
  :type '(choice (const :tag "Follow the frame" auto) (const :tag "Dark" dark)
                 (const :tag "Light" light) (const :tag "Current Emacs theme" native)) :group 'etaf-telega)
(defvar etaf-telega--theme-mode (etaf-ref etaf-telega-theme) "Live appearance ref.")
(defconst etaf-telega--surface-modes '((light . "亮") (auto . "随") (dark . "暗")) "Host switch modes.")
(defvar etaf-telega--canvas-version (etaf-ref 0) "Palette generation cell.")
(defconst etaf-telega--senders
  '((dark  "#f48fb1" "#64b5f6" "#ce93d8" "#81c784" "#ffb74d" "#ef9a9a" "#4dd0e1" "#fff176")
    (light "#d6336c" "#1d4ed8" "#7c3aed" "#15803d" "#b45309" "#b91c1c" "#0e7490" "#a16207")))

(defun etaf-telega--theme-name ()
  (let ((c (etaf-value etaf-telega--theme-mode)))
    (cond ((memq c '(dark light native)) c) ((eq (etaf-appearance) 'dark) 'dark) (t 'light))))

(defun etaf-telega--host-palette ()
  (etaf-value etaf-telega--canvas-version)
  (pcase (etaf-telega--theme-name)
    ('native (etaf-ui-host-theme-palette :mode 'auto :aliases t))
    ('light (etaf-ui-host-theme-palette :mode 'light :curated t :aliases t :bg "#ffffff" :fg "#111827"
             :surface-1 "#f3f5f8" :sunken "#e9eef4" :ink-2 "#6b7280" :border "#e3e8ee" :border-subtle "#eef2f6"
             :accent "#2481cc" :accent-fg "#FFFFFF" :accent-soft "#dbeafe" :select "#d9ecfb" :danger "#dc2626" :ok "#16a34a"))
    (_ (etaf-ui-host-theme-palette :mode 'dark :curated t :aliases t :bg "#191a1c" :fg "#e9eef4"
        :surface-1 "#202225" :sunken "#17181a" :ink-2 "#8796a8" :border "#303338" :border-subtle "#26282b"
        :accent "#5eacef" :accent-fg "#FFFFFF" :accent-soft "#2b5278" :select "#2b5278" :danger "#ef5b5b" :ok "#4fbf67"))))

(defun etaf-telega--palette ()
  (let* ((name (etaf-telega--theme-name)) (p (etaf-telega--host-palette))
         (native (eq name 'native)) (bg (plist-get p :surface-0)) (canvas (if native bg (plist-get p :sunken))))
    (append `((:bg . ,(unless native bg)) (:surface . ,(unless native bg)) (:surface-2 . ,(plist-get p :surface-1))
              (:canvas . ,canvas) (:chat-bg . ,(unless native canvas))
              (:bubble-in . ,(if (eq name 'light) "#ffffff" (plist-get p :surface-2)))
              (:bubble-out . ,(plist-get p :select)) (:senders . ,(cdr (assq (plist-get p :mode) etaf-telega--senders))))
            (cl-loop for (k v) on p by #'cddr collect (cons k v)))))

(defun etaf-telega-color (key)
  "Return the active palette's color for KEY."
  (let ((e (assq key (etaf-telega--palette))))
    (if e (cdr e) (if (eq (etaf-telega--theme-name) 'dark) "#e9eef4" "#111827"))))

(defun etaf-telega-sender-color (name)
  "Return the active palette's stable sender color for NAME."
  (let ((colors (or (alist-get :senders (etaf-telega--palette)) (cdr (assq 'dark etaf-telega--senders)))) (hash 0))
    (dolist (ch (string-to-list (or name ""))) (setq hash (mod (+ (* hash 31) ch) 1000003)))
    (nth (mod hash (length colors)) colors)))

(defun etaf-telega-theme-defaults ()
  "Return the ETAF UI token plist for the active palette."
  (let* ((p (etaf-telega--host-palette)) (bg (plist-get p :surface-0)) (panel (plist-get p :surface-1))
         (ink (plist-get p :ink-1)) (muted (plist-get p :ink-2)) (bdr (plist-get p :border)))
    (etaf-ui-host-theme-tokens :palette p
     :overrides (list :ui-panel-bg panel :ui-panel-fg ink :ui-panel-border bdr :ui-divider-bg bdr
                      :ui-picker-item-bg panel :ui-picker-item-fg ink :ui-picker-item-muted-fg muted
                      :ui-search-bg panel :ui-search-fg ink :ui-disabled-bg bg :ui-disabled-border bdr
                      :ui-button-secondary-bg (plist-get p :accent-soft) :ui-button-ghost-bg bg :ui-range-track bdr
                      :ui-success-bg panel :ui-danger-fg muted :ui-danger-bg panel :ui-warning-fg muted
                      :ui-warning-bg panel :ui-info-fg "#FFFFFF" :ui-info-bg (plist-get p :accent)))))

(provide 'etaf-telega-theme)
;;; etaf-telega-theme.el ends here
