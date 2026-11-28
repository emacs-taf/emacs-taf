;;; etaf-bili-theme.el --- Palette and ETAF UI theme for etaf-bili -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(require 'etaf)
(require 'etaf-ui)

(defgroup etaf-bili nil "Bilibili client built with ETAF and Ebox." :group 'applications)

(defconst etaf-bili--palettes
  (list
   (cons 'dark (etaf-ui-host-theme-palette
                :mode 'dark :curated t :aliases t :bg "#0B0E14" :fg "#ECF0F6"
                :surface-1 "#131720" :surface-2 "#191E29" :surface-3 "#212836" :track "#212836"
                :accent "#FB7299" :accent-fg "#FFFFFF" :accent-soft "#341C28"
                :ok "#4FB477" :warn "#E8B45C" :danger "#FF7A7A" :info "#6FB4E8"
                :extras '(:gold "#E8B45C")))
   (cons 'light (etaf-ui-host-theme-palette
                 :mode 'light :curated t :aliases t :bg "#F1F3F7" :fg "#181C24"
                 :surface-1 "#FFFFFF" :surface-2 "#F7F8FB" :surface-3 "#E9ECF2" :track "#E9ECF2"
                 :accent "#D64D7C" :accent-fg "#FFFFFF" :accent-soft "#FCE8F0"
                 :ok "#2E7D4F" :warn "#B07A16" :danger "#C0392B" :info "#2C6FA8"
                 :extras '(:gold "#B07A16"))))
  "Palette of every supported appearance, keyed by mode.")

(defcustom etaf-bili-theme-mode 'dark
  "Appearance used by a new client: `dark' or `light'."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light))
  :group 'etaf-bili)

(defconst etaf-bili--theme-modes '((dark . "暗") (light . "亮")) "Host switch modes.")
(defvar etaf-bili--theme-mode-ref (etaf-ref etaf-bili-theme-mode) "Live appearance ref.")

(defun etaf-bili--palette (&optional mode)
  "Return the palette plist for MODE or the live mode."
  (let ((active (or mode (etaf-value etaf-bili--theme-mode-ref))))
    (cdr (assq (if (eq active 'light) 'light 'dark) etaf-bili--palettes))))

(defun etaf-bili-color (key &optional mode)
  "Return the palette color named KEY for MODE."
  (or (and (keywordp key) (plist-get (etaf-bili--palette mode) key))
      (error "Unknown etaf-bili color: %S" key)))

(defun etaf-bili-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (let* ((p (etaf-bili--palette (or mode etaf-bili-theme-mode)))
         (p2 (plist-get p :panel2)) (p3 (plist-get p :panel3)) (ink (plist-get p :ink)))
    (etaf-ui-host-theme-tokens
     :palette p
     :overrides (list :ink ink :paper (plist-get p :bg) :panel (plist-get p :surface)
                      :line (plist-get p :line) :muted (plist-get p :muted)
                      :accent (plist-get p :accent) :accent-soft (plist-get p :accent-soft)
                      :ui-disabled-bg p3 :ui-search-bg p2 :ui-search-fg ink
                      :ui-shell-bg p2 :ui-window-title-bg p2))))

(provide 'etaf-bili-theme)
;;; etaf-bili-theme.el ends here
