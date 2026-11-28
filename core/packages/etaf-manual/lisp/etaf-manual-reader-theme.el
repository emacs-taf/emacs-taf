;;; etaf-manual-reader-theme.el --- Palettes for the manual reader -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defcustom etaf-manual-reader-language "zh-CN" "Initial manual language: `zh-CN' or `en'."
  :type '(choice (const :tag "Simplified Chinese" "zh-CN") (const :tag "English" "en")) :group 'etaf-manual)
(defconst etaf-manual-reader--theme-modes '((light . "亮") (auto . "随") (dark . "暗")) "Host switch modes.")

(defun etaf-manual-reader--make (mode bg ink acc asoft p1 p2 code sb scur hov)
  (let ((p (etaf-ui-host-theme-palette :mode mode :curated t :aliases t :bg bg :fg ink :surface-1 p1
                                       :surface-2 p2 :track p2 :accent acc :accent-fg "#ffffff" :accent-soft asoft :hover hov)))
    (append (list (cons :code-bg code) (cons :quote-bar (plist-get p :border-strong))
                  (cons :quote-bg (etaf-ui-color-mix bg ink 0.03)) (cons :table-header p1)
                  (cons :table-stripe (etaf-ui-color-mix bg ink 0.02)) (cons :heading ink)
                  (cons :heading-rule (plist-get p :border)) (cons :sidebar sb) (cons :sidebar-current scur))
            (cl-loop for (k v) on p by #'cddr collect (cons k v)))))

(defconst etaf-manual-reader-palettes
  (list (cons 'dark (etaf-manual-reader--make 'dark "#191a1c" "#e6edf3" "#4493f8" "#152c4d" "#202225" "#25272b" "#2b2e33" "#17181a" "#14243a" "#25272b"))
        (cons 'light (etaf-manual-reader--make 'light "#ffffff" "#1f2328" "#0969da" "#ddf4ff" "#f6f8fa" "#eef1f4" "#e7ecf2" "#f3f5f8" "#dbeafe" "#e9eef5")))
  "Color palettes of the manual reader.")

(defun etaf-manual-reader--resolved (theme)
  (let ((theme (or theme 'auto))) (if (eq theme 'auto) (etaf-appearance) theme)))

(defun etaf-manual-reader-palette (theme)
  "Return THEME's palette alist."
  (or (cdr (assq (etaf-manual-reader--resolved theme) etaf-manual-reader-palettes))
      (signal 'etaf-manual-error (list (format "Unknown manual reader theme: %S" theme)))))

(defun etaf-manual-reader-color (key &optional theme)
  "Return THEME's color for semantic KEY."
  (or (cdr (assq key (etaf-manual-reader-palette theme)))
      (signal 'etaf-manual-error (list (format "Unknown manual reader color: %S" key)))))

(defun etaf-manual-reader-theme-tokens (theme)
  "Return the ETAF UI token plist for THEME."
  (let* ((pal (etaf-manual-reader-palette theme)) (g (lambda (k) (cdr (assq k pal)))))
    (etaf-ui-host-theme-tokens :palette pal
     :overrides (list :ink (funcall g :ink) :paper (funcall g :bg) :panel (funcall g :panel) :line (funcall g :border)
                      :muted (funcall g :muted) :accent (funcall g :accent) :accent-soft (funcall g :accent-soft)
                      :ui-disabled-fg (funcall g :muted) :ui-button-ghost-hover-bg (funcall g :panel2)
                      :ui-progress-value (funcall g :accent)))))

(provide 'etaf-manual-reader-theme)
;;; etaf-manual-reader-theme.el ends here
