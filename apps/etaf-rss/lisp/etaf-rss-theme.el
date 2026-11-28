;;; etaf-rss-theme.el --- Palette and ETAF UI theme for etaf-rss -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader paints its own surface instead of borrowing the user's Emacs
;; theme, so it looks the same in every session.  `etaf-rss-color' is the
;; palette lookup used by the Views; `etaf-rss-theme-defaults' projects the
;; same palette onto the ETAF UI token contract consumed by etaf-ui Components
;; (buttons, inputs, progress bars).

;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-rss-error "RSS reader error")

(defgroup etaf-rss nil
  "RSS reader built with ETAF and Ebox."
  :group 'applications)

(defconst etaf-rss--palettes
  '((dark :bg "#0E1116" :panel "#141920" :panel2 "#1A212B" :panel3 "#222B37"
          :line "#232C39" :line-soft "#1B222C" :ink "#E9EDF3" :muted "#98A3B3"
          :dim "#647080" :accent "#E8A33D" :accent-soft "#2B2317" :gold "#E8A33D"
          :ok "#4FBF8B" :warn "#E8A33D" :danger "#FF7A85" :danger-bg "#3A1E24"
          :info "#6FB4E8" :selected "#1E2733" :unread "#E9EDF3" :read "#7C8798"
          :feed "#7FB3E8" :quote "#9CB4D4" :time "#6C7789")
    (light :bg "#FFFFFF" :panel "#F7F8FA" :panel2 "#EDF0F4" :panel3 "#E2E7ED"
           :line "#E2E7ED" :line-soft "#EEF1F5" :ink "#1B2431" :muted "#5A6472"
           :dim "#8B94A2" :accent "#B26A10" :accent-soft "#FBF0DD" :gold "#A86B14"
           :ok "#2E7D5B" :warn "#A86B14" :danger "#C0392B" :danger-bg "#FBE4E2"
           :info "#2C6FA8" :selected "#F0F2F6" :unread "#1B2431" :read "#6C7686"
           :feed "#2C6FA8" :quote "#3F66A0" :time "#7A8494"))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-rss-theme-mode 'dark
  "Appearance used by a new reader session.
`dark' (default) renders the reader's own dark surface and `light' the light
one; this is independent of the active Emacs theme.  The running choice is
one live mode cell that `T' and a panel's title-bar switch both write; this
option only seeds it."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-rss)

(defconst etaf-rss--surface-modes
  '((light . "亮") (dark . "暗"))
  "Appearance modes the reader offers its host, in display order.
The reader has two maintained palettes, so a panel's title bar offers these
two segments instead of the standard three.")

(defvar etaf-rss--theme-mode (etaf-ref etaf-rss-theme-mode)
  "Live appearance of the reader.
`T' and a panel's title-bar switch both write this cell, and the palette and
the tokens are derived from it, so every painted surface follows one state.
`etaf-rss-theme-mode' only seeds it.")

(defun etaf-rss--mode (&optional mode)
  "Return MODE, or the reader's live appearance."
  (or mode (etaf-value etaf-rss--theme-mode)))

(defun etaf-rss-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to the reader's live appearance; an unknown mode falls back to
`dark'.  An unknown KEY signals `etaf-rss-error' instead of returning a
fallback, because a typo would otherwise paint an invisible surface."
  (let* ((mode (let ((mode (etaf-rss--mode mode)))
                 (if (assq mode etaf-rss--palettes) mode 'dark)))
         (palette (cdr (assq mode etaf-rss--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (signal 'etaf-rss-error (list (format "Unknown color: %S" key))))
    color))

(defun etaf-rss-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
MODE defaults to `etaf-rss-theme-mode'.  The result is passed to
`etaf-theme-provide' by the application so shared etaf-ui Components use the
same colors as the reader's own Views."
  (let* ((mode (etaf-rss--mode mode))
         (dark (eq mode 'dark))
         (bg (etaf-rss-color :bg mode))
         (panel (etaf-rss-color :panel mode))
         (panel3 (etaf-rss-color :panel3 mode))
         (ink (etaf-rss-color :ink mode))
         (line (etaf-rss-color :line mode))
         (muted (etaf-rss-color :muted mode))
         (accent (etaf-rss-color :accent mode))
         (accent-soft (etaf-rss-color :accent-soft mode))
         (ok (etaf-rss-color :ok mode))
         (ok-bg (if dark "#17301F" "#E3F3E8"))
         (ok-border (if dark "#2E5C3F" "#A9D8BB"))
         (danger (etaf-rss-color :danger mode))
         (danger-bg (if dark "#3A1E24" "#FBE4E2"))
         (danger-border (if dark "#7A2A2C" "#E8B4AE"))
         (warn (etaf-rss-color :warn mode))
         (warn-bg (if dark "#33280F" "#FBF0DA"))
         (warn-border (if dark "#6B5423" "#E0C48A"))
         (info (etaf-rss-color :info mode))
         (info-bg (if dark "#14232F" "#E4F0FA"))
         (info-border (if dark "#2C4E66" "#A8CBE6")))
    (etaf-ui-theme-tokens
     (list :bg bg :fg ink :panel panel :track panel3 :border line :muted muted
           :accent accent :accent-fg "#FFFFFF" :accent-soft accent-soft
           :success ok :success-bg ok-bg :success-border ok-border
           :warning warn :warning-bg warn-bg :warning-border warn-border
           :danger danger :danger-bg danger-bg :danger-border danger-border
           :info info :info-bg info-bg :info-border info-border))))

(provide 'etaf-rss-theme)
;;; etaf-rss-theme.el ends here
