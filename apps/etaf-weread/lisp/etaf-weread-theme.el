;;; etaf-weread-theme.el --- Palette and ETAF UI theme for etaf-weread -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader renders its own surface instead of borrowing the user's Emacs
;; theme, so it looks the same in every session.  `etaf-weread-color' is the
;; palette lookup used by the Views; `etaf-weread-theme-defaults' projects the
;; same palette onto the ETAF UI token contract consumed by etaf-ui Components
;; (buttons, text inputs, progress bars).

;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-weread-error "WeChat Reading reader error")

(defgroup etaf-weread nil
  "WeChat Reading client built with ETAF and Ebox."
  :group 'applications)

(defconst etaf-weread--palettes
  '((dark :bg "#191a1c" :panel "#202225" :panel2 "#25272b" :panel3 "#2b2e33"
          :line "#303338" :ink "#E8ECF2" :muted "#9AA5B4" :dim "#66707F"
          :accent "#5B8DEF" :accent-soft "#1A2436" :gold "#E4B15E" :ok "#4FBF8B"
          :warn "#E4B15E" :danger "#FF7A85" :danger-bg "#3A1E24" :info "#6FB4E8"
          :selected "#25272b" :meter "#5B8DEF" :cover "#2b2e33" :quote "#8EA8D8")
    (light :bg "#FFFFFF" :panel "#F7F8FA" :panel2 "#EDF0F4" :panel3 "#E1E6EC"
           :line "#E1E6EC" :ink "#1C2330" :muted "#5A6371" :dim "#8A93A0"
           :accent "#2F6FED" :accent-soft "#E8EFFD" :gold "#B07A16" :ok "#2E7D5B"
           :warn "#B07A16" :danger "#C0392B" :danger-bg "#FBE4E2" :info "#2C6FA8"
           :selected "#EDF0F4" :meter "#2F6FED" :cover "#E1E6EC" :quote "#4A6FC0")
    (sepia :bg "#F4EBD9" :panel "#EFE4CD" :panel2 "#E7D8BC" :panel3 "#DCC9A6"
           :line "#D9C5A2" :ink "#3B3225" :muted "#6D5E47" :dim "#95846A"
           :accent "#8A6A2F" :accent-soft "#EDE0C4" :gold "#8A6A2F" :ok "#4C7A54"
           :warn "#9A6B1F" :danger "#A5442F" :danger-bg "#F0D9CE" :info "#4A6E8A"
           :selected "#E4D3B2" :meter "#8A6A2F" :cover "#DCC9A6" :quote "#7A6440"))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-weread-theme-mode 'dark
  "Appearance a new Emacs session starts with.
`dark' (default) renders the reader's own dark surface, `light' the light one
and `sepia' a warm paper surface for long reading.  This is independent of the
active Emacs theme.  The running state is `etaf-weread--theme-mode'; this
option only seeds it."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light)
                 (const :tag "Sepia" sepia))
  :group 'etaf-weread)

(defvar etaf-weread--theme-mode (etaf-ref etaf-weread-theme-mode)
  "Live appearance of the reader.
`T' and a panel's title-bar switch both write this cell, and the palette is
derived from it, so the reader and its host show one state instead of two.
`auto' follows the appearance the host provides; `sepia' is the reader's own
third palette and has no segment in the standard three-mode switch.")

(defconst etaf-weread--surface-modes
  '((light . "亮") (auto . "随") (dark . "暗"))
  "Appearance modes the reader offers its host, in display order.
They are the standard three a panel's title bar shows, so the reader's switch
reads like every other panel's; the reader's own `sepia' stays on `T'.")

(defun etaf-weread--resolved-mode (&optional mode)
  "Return the palette mode MODE paints with, or the reader's live mode.
`auto' follows the appearance the host provides, so a reader inside a panel
matches the panel's palette and a standalone reader follows the Emacs theme.
An unknown mode falls back to `dark'."
  (let ((mode (or mode (etaf-value etaf-weread--theme-mode))))
    (if (eq mode 'auto) (etaf-appearance) mode)))

(defun etaf-weread--current-mode (&optional mode)
  "Return the palette mode to paint MODE, or the reader's live mode.
An unknown mode falls back to `dark'."
  (let ((mode (etaf-weread--resolved-mode mode)))
    (if (assq mode etaf-weread--palettes) mode 'dark)))

(defun etaf-weread-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to the reader's live mode; an unknown mode falls back to
`dark'.  An unknown KEY signals `etaf-weread-error' instead of returning a
fallback, because a typo would otherwise paint an invisible surface."
  (let* ((mode (etaf-weread--current-mode mode))
         (palette (cdr (assq mode etaf-weread--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (signal 'etaf-weread-error (list (format "Unknown color: %S" key))))
    color))

(defun etaf-weread-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
MODE defaults to the reader's live mode.  The result is passed to
`etaf-theme-provide' by the application so shared etaf-ui Components use the
same colors as the reader's own Views."
  (let* ((mode (etaf-weread--current-mode mode))
         (dark (eq mode 'dark))
         (bg (etaf-weread-color :bg mode))
         (panel (etaf-weread-color :panel mode))
         (panel3 (etaf-weread-color :panel3 mode))
         (ink (etaf-weread-color :ink mode))
         (line (etaf-weread-color :line mode))
         (muted (etaf-weread-color :muted mode))
         (accent (etaf-weread-color :accent mode))
         (accent-soft (etaf-weread-color :accent-soft mode))
         (ok (etaf-weread-color :ok mode))
         (ok-bg (if dark "#17301F" "#E3F3E8"))
         (ok-border (if dark "#2E5C3F" "#A9D8BB"))
         (danger (etaf-weread-color :danger mode))
         (danger-bg (if dark "#3A1E24" "#FBE4E2"))
         (danger-border (if dark "#7A2A2C" "#E8B4AE"))
         (warn (etaf-weread-color :warn mode))
         (warn-bg (if dark "#33280F" "#FBF0DA"))
         (warn-border (if dark "#6B5423" "#E0C48A"))
         (info (etaf-weread-color :info mode))
         (info-bg (if dark "#14232F" "#E4F0FA"))
         (info-border (if dark "#2C4E66" "#A8CBE6")))
    (etaf-ui-theme-tokens
     (list :bg bg :fg ink :panel panel :track panel3 :border line :muted muted
           :accent accent :accent-fg "#FFFFFF" :accent-soft accent-soft
           :success ok :success-bg ok-bg :success-border ok-border
           :warning warn :warning-bg warn-bg :warning-border warn-border
           :danger danger :danger-bg danger-bg :danger-border danger-border
           :info info :info-bg info-bg :info-border info-border))))

(provide 'etaf-weread-theme)
;;; etaf-weread-theme.el ends here
