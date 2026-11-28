;;; etaf-desktop-theme.el --- Desktop theme registry -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defvar etaf-desktop--themes nil "Registered desktop themes alist of NAME to plist.")
(defconst etaf-desktop--surface-modes '((light . "亮") (system . "随") (dark . "暗")) "Host switch modes.")

(defun etaf-desktop--theme-color-p (value)
  "Return non-nil when VALUE is a six-digit hexadecimal color string."
  (and (stringp value) (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" value)))

(cl-defun etaf-desktop-define-theme (name &key label (mode 'light) tokens)
  "Register desktop theme NAME with LABEL, color MODE and TOKENS."
  (unless (and (symbolp name) name (not (memq name '(system light dark))))
    (signal 'etaf-desktop-error (list (format "Invalid desktop theme name: %S" name))))
  (unless (memq mode '(light dark))
    (signal 'etaf-desktop-error (list (format "Desktop theme mode must be light or dark: %S" mode))))
  (unless (and (proper-list-p tokens) (zerop (% (length tokens) 2))
               (cl-loop for (k v) on tokens by #'cddr always (and (keywordp k) (etaf-desktop--theme-color-p v))))
    (signal 'etaf-desktop-error (list "Desktop theme tokens must be a plist of #RRGGBB colors")))
  (let ((entry (list :name name :label (or label (capitalize (symbol-name name)))
                     :mode mode :tokens (copy-sequence tokens))))
    (if (assq name etaf-desktop--themes) (setcdr (assq name etaf-desktop--themes) entry)
      (setq etaf-desktop--themes (append etaf-desktop--themes (list (cons name entry)))))
    (copy-tree entry)))

(defun etaf-desktop-themes ()
  "Return registered desktop themes as detached plists in definition order."
  (mapcar (lambda (e) (list :name (plist-get (cdr e) :name) :label (plist-get (cdr e) :label) :mode (plist-get (cdr e) :mode)))
          etaf-desktop--themes))

(defun etaf-desktop-theme-tokens (name) "Return token plist of desktop theme NAME."
  (copy-sequence (plist-get (etaf-desktop--theme-entry name) :tokens)))

(defun etaf-desktop--theme-name-p (name) "Return non-nil when NAME names a theme."
  (or (memq name '(system light dark)) (and (assq name etaf-desktop--themes) t)))

(defun etaf-desktop--theme-default-for-mode (mode)
  (cl-find-if (lambda (e) (eq (plist-get (cdr e) :mode) mode)) etaf-desktop--themes))

(defun etaf-desktop--theme-entry (name)
  "Return registered theme plist selected by NAME, with fallbacks filled."
  (let* ((mode (pcase name ('system (etaf-theme-current-mode)) ((or 'light 'dark) name)
                      (_ (plist-get (cdr (assq name etaf-desktop--themes)) :mode))))
         (entry (or (and (not (memq name '(system light dark))) (cdr (assq name etaf-desktop--themes)))
                    (cdr (etaf-desktop--theme-default-for-mode (or mode 'light)))))
         (base (cdr (etaf-desktop--theme-default-for-mode (plist-get entry :mode))))
         (tokens (copy-sequence (plist-get base :tokens))))
    (cl-loop for (k v) on (plist-get entry :tokens) by #'cddr do (setq tokens (plist-put tokens k v)))
    (list :name (plist-get entry :name) :label (plist-get entry :label) :mode (plist-get entry :mode) :tokens tokens)))

(defun etaf-desktop--theme-for-settings (settings)
  "Return the ETAF Theme plist for SETTINGS."
  (let* ((entry (etaf-desktop--theme-entry (plist-get settings :theme)))
         (tokens (plist-get entry :tokens)) (dark (eq (plist-get entry :mode) 'dark))
         (accent (plist-get settings :accent-color)))
    (when (etaf-desktop--theme-color-p accent)
      (let ((soft (etaf-ui-color-mix accent (plist-get tokens :ui-shell-bg) (if dark 0.7 0.8))))
        (cl-loop for (k v) on (list :ui-accent accent :ui-accent-soft-bg soft :ui-button-primary-bg accent
                                    :ui-button-secondary-fg accent :ui-button-secondary-bg soft)
                 by #'cddr do (setq tokens (plist-put tokens k v)))))
    (plist-put tokens :ui-mode (plist-get entry :mode))))

(defun etaf-desktop--shell-tokens (mode bg fg acc afg shl cnv ttl pnl bdr soft)
  "Derive a desktop theme token plist via `etaf-ui-host-theme-palette'."
  (let* ((p (etaf-ui-host-theme-palette :mode mode :curated t :bg bg :fg fg :surface-1 pnl
                                        :surface-2 ttl :border bdr :accent acc :accent-fg afg :accent-soft soft))
         (muted (plist-get p :ink-2)) (div (etaf-ui-color-mix cnv fg (if (eq mode 'dark) 0.08 0.12))))
    (list :ui-shell-bg shl :ui-shell-fg fg :ui-shell-muted-fg muted
          :ui-shell-item-fg (etaf-ui-color-mix fg shl 0.25) :ui-shell-item-minimized-fg (plist-get p :ink-3)
          :ui-accent acc :ui-accent-fg afg :ui-accent-soft-bg soft :ui-canvas-bg cnv :ui-canvas-fg fg
          :ui-canvas-border div :ui-window-bg bg :ui-window-fg fg :ui-window-border bdr
          :ui-window-title-bg ttl :ui-window-title-fg muted :ui-window-title-active-fg fg
          :ui-divider-bg div :ui-fg fg :ui-bg bg :ui-muted-fg muted :ui-border bdr :ui-panel-bg pnl
          :ui-panel-fg fg :ui-panel-border bdr :ui-picker-item-bg ttl :ui-picker-item-fg fg
          :ui-picker-item-muted-fg muted :ui-button-ghost-fg fg :ui-button-secondary-fg acc
          :ui-button-secondary-bg soft :ui-button-primary-fg afg :ui-button-primary-bg acc :ui-checkbox-enabled-fg fg)))

(dolist (s '((daylight "Daylight" light "#FFFFFF" "#16202C" "#2F6FE4" "#FFFFFF" "#E4E9F0" "#EEF2F7" "#F5F7FA" "#FFFFFF" "#CBD5E0" "#D6E2FA")
             (midnight "Midnight" dark  "#25272b" "#E6EBF2" "#6FA1FF" "#0B1016" "#191a1c" "#202225" "#202225" "#2b2e33" "#3a3d42" "#233552")
             (paper    "Paper"    light "#FFFCF6" "#2C2924" "#B4552D" "#FFF9F0" "#E9E3D8" "#F4EFE6" "#F6F1E8" "#FFFCF6" "#D6CDBD" "#F1D9CC")
             (forest   "Forest"   dark  "#222D26" "#E3EBE4" "#7FC99A" "#0F1712" "#151C18" "#1B241E" "#1C2620" "#243029" "#354438" "#24382C")
             (graphite "Graphite" dark  "#2C2C2E" "#EDEDEF" "#F2B545" "#1C1C1E" "#1C1C1E" "#242426" "#262628" "#2E2E31" "#3F3F43" "#3C3423")))
  (etaf-desktop-define-theme (nth 0 s) :label (nth 1 s) :mode (nth 2 s) :tokens (apply #'etaf-desktop--shell-tokens (nthcdr 2 s))))

(provide 'etaf-desktop-theme)
;;; etaf-desktop-theme.el ends here
