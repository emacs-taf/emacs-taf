;;; etaf-manual-reader-theme.el --- Palettes for the manual reader -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Internal palettes of the manual reader.  A palette is a plain alist of
;; semantic color keys shared with the markdown renderer (which reads
;; `:ink', `:accent', `:panel' and friends) plus two reader-only surfaces
;; for the navigation column.  Both palettes describe the same layout, so a
;; theme change never leaks a half-updated set of colors.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(defcustom etaf-manual-reader-language "zh-CN"
  "Language the manual reader opens with.
`zh-CN' reads the Simplified Chinese manual, `en' the English one; the
reader's own language switch changes it for the running session."
  :type '(choice (const :tag "Simplified Chinese" "zh-CN")
                 (const :tag "English" "en"))
  :group 'etaf-manual)

(defconst etaf-manual-reader-palettes
  '((dark . ((:bg . "#191a1c")
             (:ink . "#e6edf3")
             (:muted . "#9198a1")
             (:faint . "#6e7681")
             (:accent . "#4493f8")
             (:accent-soft . "#152c4d")
             (:border . "#303338")
             (:panel . "#202225")
             (:panel2 . "#25272b")
             (:code-bg . "#2b2e33")
             (:quote-bar . "#43464b")
             (:quote-bg . "#1c1e21")
             (:table-header . "#202225")
             (:table-stripe . "#1c1e21")
             (:heading . "#e6edf3")
             (:heading-rule . "#303338")
             (:ok . "#3fb950")
             (:ok-soft . "#12261e")
             (:warn . "#d29922")
             (:warn-soft . "#272115")
             (:danger . "#f85149")
             (:danger-soft . "#2a1518")
             (:important . "#a371f7")
             (:important-soft . "#221a38")
             (:sidebar . "#17181a")
             (:sidebar-current . "#14243a")
             (:hover . "#25272b")))
    (light . ((:bg . "#ffffff")
              (:ink . "#1f2328")
              (:muted . "#59636e")
              (:faint . "#818b98")
              (:accent . "#0969da")
              (:accent-soft . "#ddf4ff")
              (:border . "#d1d9e0")
              (:panel . "#f6f8fa")
              (:panel2 . "#eef1f4")
              (:code-bg . "#e7ecf2")
              (:quote-bar . "#d1d9e0")
              (:quote-bg . "#f9fbfd")
              (:table-header . "#f0f3f6")
              (:table-stripe . "#fbfcfd")
              (:heading . "#1f2328")
              (:heading-rule . "#d1d9e0")
              (:ok . "#1a7f37")
              (:ok-soft . "#dafbe1")
              (:warn . "#9a6700")
              (:warn-soft . "#fff8c5")
              (:danger . "#d1242f")
              (:danger-soft . "#ffebe9")
              (:important . "#8250df")
              (:important-soft . "#fbefff")
              (:sidebar . "#f3f5f8")
              (:sidebar-current . "#dbeafe")
              (:hover . "#e9eef5"))))
  "Color palettes of the manual reader.")

(defconst etaf-manual-reader--theme-modes
  '((light . "亮") (auto . "随") (dark . "暗"))
  "Appearance modes the reader offers, in display order.
`t' cycles them and the title bar of a panel framing the reader offers the
same three, so the switch reads like every other panel's.")

(defun etaf-manual-reader--resolved (theme)
  "Return the light or dark palette name THEME paints with.
`auto' follows the appearance the host provides: a reader inside a panel
matches the panel's palette, and a standalone reader follows the Emacs
theme.  Reading a ref here is what makes `auto' repaint on a theme switch."
  (let ((theme (or theme 'auto)))
    (if (eq theme 'auto) (etaf-appearance) theme)))

(defun etaf-manual-reader-palette (theme)
  "Return THEME's palette alist.
THEME is `light', `dark', `auto' (follow the host appearance) or nil for the
same."
  (or (cdr (assq (etaf-manual-reader--resolved theme)
                 etaf-manual-reader-palettes))
      (signal 'etaf-manual-error
              (list (format "Unknown manual reader theme: %S" theme)))))

(defun etaf-manual-reader-color (key &optional theme)
  "Return THEME's color for semantic KEY."
  (or (cdr (assq key (etaf-manual-reader-palette theme)))
      (signal 'etaf-manual-error
              (list (format "Unknown manual reader color: %S" key)))))

(defun etaf-manual-reader-theme-tokens (theme)
  "Return the ETAF UI token plist for THEME.
The application provides this through `etaf-theme-provide', so shared ETAF
UI Components follow the reader's colors."
  (let* ((palette (etaf-manual-reader-palette theme))
         (dark (eq (etaf-manual-reader--resolved theme) 'dark))
         (lookup (lambda (key) (cdr (assq key palette))))
         (bg (funcall lookup :bg))
         (panel (funcall lookup :panel))
         (panel2 (funcall lookup :panel2))
         (ink (funcall lookup :ink))
         (line (funcall lookup :border))
         (muted (funcall lookup :muted))
         (accent (funcall lookup :accent))
         (accent-soft (funcall lookup :accent-soft)))
    (list :ink ink :paper bg :panel panel :line line :muted muted
          :accent accent :accent-soft accent-soft
          :ui-fg ink :ui-bg bg :ui-border line :ui-muted-fg muted
          :ui-disabled-fg muted :ui-disabled-bg panel :ui-disabled-border line
          :ui-accent accent :ui-accent-fg "#ffffff" :ui-accent-soft-bg accent-soft
          :ui-button-primary-fg "#ffffff" :ui-button-primary-bg accent
          :ui-button-secondary-fg accent :ui-button-secondary-bg accent-soft
          :ui-button-ghost-fg muted
          :ui-button-ghost-hover-bg panel2
          :ui-success-fg (if dark "#3fb950" "#1a7f37")
          :ui-success-bg (if dark "#12261e" "#dafbe1")
          :ui-success-border (if dark "#2ea04366" "#aceebb")
          :ui-warning-fg (if dark "#d29922" "#9a6700")
          :ui-warning-bg (if dark "#272115" "#fff8c5")
          :ui-warning-border (if dark "#d2992266" "#d4a72c")
          :ui-danger-fg (if dark "#f85149" "#d1242f")
          :ui-danger-bg (if dark "#2a1518" "#ffebe9")
          :ui-danger-border (if dark "#f8514966" "#ff818266")
          :ui-info-fg accent :ui-info-bg accent-soft :ui-info-border line
          :ui-panel-fg ink :ui-panel-bg panel :ui-panel-border line
          :ui-divider-bg line
          :ui-progress-track panel2 :ui-progress-value accent
          :ui-table-border line :ui-table-selected-fg accent
          :ui-table-selected-bg accent-soft
          :ui-checkbox-enabled-fg ink :ui-checkbox-disabled-fg muted)))

(provide 'etaf-manual-reader-theme)
;;; etaf-manual-reader-theme.el ends here
