;;; etaf-desktop-theme.el --- Desktop theme registry -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Named color themes for the desktop shell.  A theme is a plist of semantic
;; ETAF Theme tokens consumed by `etaf-ui' desktop Components (bars, windows,
;; dividers, dialogs and pickers).  The runtime provides the selected theme to
;; the whole desktop subtree as a reactive source, so switching themes or the
;; accent publishes through Ebox paint slots instead of re-rendering the tree.
;; An open modal no longer dims these tokens: the shared modal backdrop dims
;; whatever the desktop painted, images and text included.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(defvar etaf-desktop--themes nil
  "Registered desktop themes as an ordered alist of NAME to plist.
Each plist holds `:label', `:mode' (`light' or `dark') and `:tokens'.")

(defconst etaf-desktop--theme-panel-tokens
  '(:ui-fg :ui-bg :ui-muted-fg :ui-border
    :ui-panel-bg :ui-panel-fg :ui-panel-border
    :ui-picker-item-bg :ui-picker-item-fg :ui-picker-item-muted-fg
    :ui-button-ghost-fg
    :ui-button-secondary-fg :ui-button-secondary-bg
    :ui-button-primary-fg :ui-button-primary-bg
    :ui-checkbox-enabled-fg)
  "Tokens painting dialogs and pickers.  These stay crisp above a modal backdrop.")

(defun etaf-desktop--theme-color-p (value)
  "Return non-nil when VALUE is a six-digit hexadecimal color string."
  (and (stringp value)
       (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" value)))

(defun etaf-desktop--theme-blend (from to amount)
  "Return FROM moved AMOUNT (0.0-1.0) of the way toward hexadecimal color TO."
  (if (not (and (etaf-desktop--theme-color-p from)
                (etaf-desktop--theme-color-p to)))
      from
    (let ((amount (max 0.0 (min 1.0 (float amount)))))
      (apply #'format "#%02X%02X%02X"
             (cl-loop for offset in '(1 3 5)
                      collect (let ((a (string-to-number
                                        (substring from offset (+ offset 2)) 16))
                                    (b (string-to-number
                                        (substring to offset (+ offset 2)) 16)))
                                (round (+ a (* (- b a) amount)))))))))

(cl-defun etaf-desktop-define-theme (name &key label (mode 'light) tokens)
  "Register desktop theme NAME with LABEL, color MODE and TOKENS.

NAME is a non-nil symbol other than `system', `light' or `dark'.  MODE is
`light' or `dark' and lets `system' pick a theme matching the Emacs frame.
TOKENS is a plist of six-digit hexadecimal colors for the shell and panel
tokens listed in `etaf-desktop-theme-tokens'; missing tokens fall back to
the built-in theme of the same MODE.  Redefining NAME replaces its entry.
Return the registered theme plist."
  (unless (and (symbolp name) name (not (memq name '(system light dark))))
    (signal 'etaf-desktop-error
            (list (format "Invalid desktop theme name: %S" name))))
  (unless (memq mode '(light dark))
    (signal 'etaf-desktop-error
            (list (format "Desktop theme mode must be light or dark: %S" mode))))
  (unless (and (proper-list-p tokens) (zerop (% (length tokens) 2))
               (cl-loop for (key value) on tokens by #'cddr
                        always (and (keywordp key)
                                    (etaf-desktop--theme-color-p value))))
    (signal 'etaf-desktop-error
            (list "Desktop theme tokens must be a plist of #RRGGBB colors")))
  (let ((entry (list :name name
                     :label (or label (capitalize (symbol-name name)))
                     :mode mode :tokens (copy-sequence tokens))))
    (if (assq name etaf-desktop--themes)
        (setcdr (assq name etaf-desktop--themes) entry)
      (setq etaf-desktop--themes
            (append etaf-desktop--themes (list (cons name entry)))))
    (copy-tree entry)))

(defun etaf-desktop-themes ()
  "Return registered desktop themes as detached plists in definition order.
Each plist holds `:name', `:label' and `:mode'."
  (mapcar (lambda (entry)
            (list :name (plist-get (cdr entry) :name)
                  :label (plist-get (cdr entry) :label)
                  :mode (plist-get (cdr entry) :mode)))
          etaf-desktop--themes))

(defun etaf-desktop-theme-tokens (name)
  "Return the complete token plist of registered desktop theme NAME.
`system', `light' and `dark' resolve to the built-in theme for that mode."
  (copy-sequence
   (plist-get (etaf-desktop--theme-entry name) :tokens)))

(defun etaf-desktop--theme-name-p (name)
  "Return non-nil when NAME selects a registered or built-in theme."
  (or (memq name '(system light dark))
      (and (assq name etaf-desktop--themes) t)))

(defun etaf-desktop--theme-default-for-mode (mode)
  "Return the first registered theme entry whose mode is MODE."
  (cl-find-if (lambda (entry) (eq (plist-get (cdr entry) :mode) mode))
              etaf-desktop--themes))

(defun etaf-desktop--theme-entry (name)
  "Return the registered theme plist selected by NAME, with fallbacks filled."
  (let* ((mode (pcase name
                 ('system (etaf-theme-current-mode))
                 ((or 'light 'dark) name)
                 (_ (plist-get (cdr (assq name etaf-desktop--themes)) :mode))))
         (entry (or (and (not (memq name '(system light dark)))
                         (cdr (assq name etaf-desktop--themes)))
                    (cdr (etaf-desktop--theme-default-for-mode (or mode 'light)))))
         (base (cdr (etaf-desktop--theme-default-for-mode
                     (plist-get entry :mode))))
         (tokens (copy-sequence (plist-get base :tokens))))
    (cl-loop for (key value) on (plist-get entry :tokens) by #'cddr
             do (setq tokens (plist-put tokens key value)))
    (list :name (plist-get entry :name) :label (plist-get entry :label)
          :mode (plist-get entry :mode) :tokens tokens)))

(defconst etaf-desktop--surface-modes
  '((light . "亮") (system . "随") (dark . "暗"))
  "Appearance modes the desktop offers its host, in display order.
`system' follows the Emacs frame the desktop is displayed in, which is what
the settings dialog names System; a named theme stays on the settings.")

(defun etaf-desktop--theme-for-settings (settings)
  "Return the ETAF Theme plist for SETTINGS.

`:accent-color', when set, replaces the theme's accent and derives its soft
background.  A modal dims the painted shell through its shared backdrop
rather than restyling these tokens."
  (let* ((entry (etaf-desktop--theme-entry (plist-get settings :theme)))
         (tokens (plist-get entry :tokens))
         (dark (eq (plist-get entry :mode) 'dark))
         (accent (plist-get settings :accent-color)))
    (when (etaf-desktop--theme-color-p accent)
      (setq tokens (plist-put tokens :ui-accent accent))
      (setq tokens (plist-put tokens :ui-accent-soft-bg
                              (etaf-desktop--theme-blend
                               accent (plist-get tokens :ui-shell-bg)
                               (if dark 0.7 0.8))))
      (setq tokens (plist-put tokens :ui-button-primary-bg accent))
      (setq tokens (plist-put tokens :ui-button-secondary-fg accent))
      (setq tokens (plist-put tokens :ui-button-secondary-bg
                              (plist-get tokens :ui-accent-soft-bg))))
    ;; The polarity travels with the tokens so the desktop can hand it to the
    ;; applications in its windows through `etaf-appearance-provide'.
    (plist-put tokens :ui-mode (plist-get entry :mode))))

;; Built-in themes.  The first light and the first dark entry are the
;; `system' defaults and supply fallbacks for partial custom themes.

(etaf-desktop-define-theme
 'daylight :label "Daylight" :mode 'light
 :tokens
 '(:ui-shell-bg "#E4E9F0" :ui-shell-fg "#16202C" :ui-shell-muted-fg "#6B7683"
   :ui-shell-item-fg "#4A5664" :ui-shell-item-minimized-fg "#9AA5B1"
   :ui-accent "#2F6FE4" :ui-accent-fg "#FFFFFF" :ui-accent-soft-bg "#D6E2FA"
   :ui-canvas-bg "#EEF2F7" :ui-canvas-fg "#16202C" :ui-canvas-border "#D3DBE4"
   :ui-window-bg "#FFFFFF" :ui-window-fg "#16202C" :ui-window-border "#CBD5E0"
   :ui-window-title-bg "#F5F7FA" :ui-window-title-fg "#8A96A3"
   :ui-window-title-active-fg "#16202C" :ui-divider-bg "#D3DBE4"
   :ui-fg "#16202C" :ui-bg "#FFFFFF" :ui-muted-fg "#6B7683" :ui-border "#CBD5E0"
   :ui-panel-bg "#FFFFFF" :ui-panel-fg "#16202C" :ui-panel-border "#C3CDD8"
   :ui-picker-item-bg "#F5F7FA" :ui-picker-item-fg "#16202C"
   :ui-picker-item-muted-fg "#6B7683"
   :ui-button-ghost-fg "#16202C"
   :ui-button-secondary-fg "#2F6FE4" :ui-button-secondary-bg "#D6E2FA"
   :ui-button-primary-fg "#FFFFFF" :ui-button-primary-bg "#2F6FE4"
   :ui-checkbox-enabled-fg "#16202C"))

(etaf-desktop-define-theme
 'midnight :label "Midnight" :mode 'dark
 :tokens
 '(:ui-shell-bg "#191a1c" :ui-shell-fg "#E6EBF2" :ui-shell-muted-fg "#7F8A98"
   :ui-shell-item-fg "#A9B3BF" :ui-shell-item-minimized-fg "#5E6976"
   :ui-accent "#6FA1FF" :ui-accent-fg "#0B1016" :ui-accent-soft-bg "#233552"
   :ui-canvas-bg "#202225" :ui-canvas-fg "#E6EBF2" :ui-canvas-border "#303338"
   :ui-window-bg "#25272b" :ui-window-fg "#E6EBF2" :ui-window-border "#3a3d42"
   :ui-window-title-bg "#202225" :ui-window-title-fg "#6F7B89"
   :ui-window-title-active-fg "#F2F5F9" :ui-divider-bg "#303338"
   :ui-fg "#E6EBF2" :ui-bg "#25272b" :ui-muted-fg "#7F8A98" :ui-border "#303338"
   :ui-panel-bg "#2b2e33" :ui-panel-fg "#E6EBF2" :ui-panel-border "#43464b"
   :ui-picker-item-bg "#2e3135" :ui-picker-item-fg "#E6EBF2"
   :ui-picker-item-muted-fg "#8B96A4"
   :ui-button-ghost-fg "#E6EBF2"
   :ui-button-secondary-fg "#6FA1FF" :ui-button-secondary-bg "#233552"
   :ui-button-primary-fg "#0B1016" :ui-button-primary-bg "#6FA1FF"
   :ui-checkbox-enabled-fg "#E6EBF2"))

(etaf-desktop-define-theme
 'paper :label "Paper" :mode 'light
 :tokens
 '(:ui-shell-bg "#E9E3D8" :ui-shell-fg "#2C2924" :ui-shell-muted-fg "#7E776B"
   :ui-shell-item-fg "#5B554B" :ui-shell-item-minimized-fg "#A8A093"
   :ui-accent "#B4552D" :ui-accent-fg "#FFF9F0" :ui-accent-soft-bg "#F1D9CC"
   :ui-canvas-bg "#F4EFE6" :ui-canvas-fg "#2C2924" :ui-canvas-border "#DDD5C7"
   :ui-window-bg "#FFFCF6" :ui-window-fg "#2C2924" :ui-window-border "#D6CDBD"
   :ui-window-title-bg "#F6F1E8" :ui-window-title-fg "#978F82"
   :ui-window-title-active-fg "#2C2924" :ui-divider-bg "#DDD5C7"
   :ui-fg "#2C2924" :ui-bg "#FFFCF6" :ui-muted-fg "#7E776B" :ui-border "#D6CDBD"
   :ui-panel-bg "#FFFCF6" :ui-panel-fg "#2C2924" :ui-panel-border "#CFC5B4"
   :ui-picker-item-bg "#F6F1E8" :ui-picker-item-fg "#2C2924"
   :ui-picker-item-muted-fg "#7E776B"
   :ui-button-ghost-fg "#2C2924"
   :ui-button-secondary-fg "#B4552D" :ui-button-secondary-bg "#F1D9CC"
   :ui-button-primary-fg "#FFF9F0" :ui-button-primary-bg "#B4552D"
   :ui-checkbox-enabled-fg "#2C2924"))

(etaf-desktop-define-theme
 'forest :label "Forest" :mode 'dark
 :tokens
 '(:ui-shell-bg "#151C18" :ui-shell-fg "#E3EBE4" :ui-shell-muted-fg "#7C8B80"
   :ui-shell-item-fg "#A6B4A9" :ui-shell-item-minimized-fg "#5B6A5F"
   :ui-accent "#7FC99A" :ui-accent-fg "#0F1712" :ui-accent-soft-bg "#24382C"
   :ui-canvas-bg "#1B241E" :ui-canvas-fg "#E3EBE4" :ui-canvas-border "#2A362E"
   :ui-window-bg "#222D26" :ui-window-fg "#E3EBE4" :ui-window-border "#354438"
   :ui-window-title-bg "#1C2620" :ui-window-title-fg "#6E7D72"
   :ui-window-title-active-fg "#F1F6F2" :ui-divider-bg "#2A362E"
   :ui-fg "#E3EBE4" :ui-bg "#222D26" :ui-muted-fg "#7C8B80" :ui-border "#354438"
   :ui-panel-bg "#243029" :ui-panel-fg "#E3EBE4" :ui-panel-border "#3B4B40"
   :ui-picker-item-bg "#2A3730" :ui-picker-item-fg "#E3EBE4"
   :ui-picker-item-muted-fg "#8A998E"
   :ui-button-ghost-fg "#E3EBE4"
   :ui-button-secondary-fg "#7FC99A" :ui-button-secondary-bg "#24382C"
   :ui-button-primary-fg "#0F1712" :ui-button-primary-bg "#7FC99A"
   :ui-checkbox-enabled-fg "#E3EBE4"))

(etaf-desktop-define-theme
 'graphite :label "Graphite" :mode 'dark
 :tokens
 '(:ui-shell-bg "#1C1C1E" :ui-shell-fg "#EDEDEF" :ui-shell-muted-fg "#8A8A8F"
   :ui-shell-item-fg "#B3B3B8" :ui-shell-item-minimized-fg "#636369"
   :ui-accent "#F2B545" :ui-accent-fg "#1C1C1E" :ui-accent-soft-bg "#3C3423"
   :ui-canvas-bg "#242426" :ui-canvas-fg "#EDEDEF" :ui-canvas-border "#333336"
   :ui-window-bg "#2C2C2E" :ui-window-fg "#EDEDEF" :ui-window-border "#3F3F43"
   :ui-window-title-bg "#262628" :ui-window-title-fg "#7A7A80"
   :ui-window-title-active-fg "#F7F7F8" :ui-divider-bg "#333336"
   :ui-fg "#EDEDEF" :ui-bg "#2C2C2E" :ui-muted-fg "#8A8A8F" :ui-border "#3F3F43"
   :ui-panel-bg "#2E2E31" :ui-panel-fg "#EDEDEF" :ui-panel-border "#45454A"
   :ui-picker-item-bg "#363639" :ui-picker-item-fg "#EDEDEF"
   :ui-picker-item-muted-fg "#98989E"
   :ui-button-ghost-fg "#EDEDEF"
   :ui-button-secondary-fg "#F2B545" :ui-button-secondary-bg "#3C3423"
   :ui-button-primary-fg "#1C1C1E" :ui-button-primary-bg "#F2B545"
   :ui-checkbox-enabled-fg "#EDEDEF"))

(provide 'etaf-desktop-theme)
;;; etaf-desktop-theme.el ends here
