;;; etaf-slides-theme.el --- Slide palettes for etaf-slides -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Internal palettes of the slide application.  A palette is a plain alist of
;; semantic color keys shared by the stage, the slide body and the overview, so
;; one layout serves both appearances and a theme change never leaks a
;; half-updated set of colors.
;;
;; The dark palette follows the ecosystem neutral scale: the canvas is
;; #191a1c and the slide is one raised step above it, so the stage reads as a
;; surface on the page instead of a full-bleed background.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defconst etaf-slides-themes
  '((light . ((:bg . "#e8e4d9") (:surface . "#ffffff") (:panel . "#f7f5ee")
              (:panel2 . "#efece3") (:ink . "#1f2328") (:muted . "#59636e")
              (:faint . "#8b949e") (:accent . "#b4531f") (:accent-soft . "#f7e4d6")
              (:border . "#e4dfd2") (:code-bg . "#f6f3ec") (:quote-bg . "#f5f1e6")
              (:quote-bar . "#d9cfb8") (:table-header . "#f0ece2")
              (:table-stripe . "#faf8f2") (:heading . "#1f2328")
              (:heading-rule . "#ddd6c6") (:ok . "#1a7f37") (:ok-soft . "#dafbe1")
              (:warn . "#9a6700") (:warn-soft . "#fff8c5") (:danger . "#d1242f")
              (:danger-soft . "#ffebe9") (:important . "#8250df")
              (:important-soft . "#fbefff")))
    (dark . ((:bg . "#0f1012") (:surface . "#191a1c") (:panel . "#202225")
             (:panel2 . "#2b2e33") (:ink . "#e6edf3") (:muted . "#9198a1")
             (:faint . "#6e7681") (:accent . "#e0925a") (:accent-soft . "#3a2a1e")
             (:border . "#303338") (:code-bg . "#1b1d20") (:quote-bg . "#1c1e21")
             (:quote-bar . "#43464b") (:table-header . "#26282c")
             (:table-stripe . "#1c1e21") (:heading . "#e6edf3")
             (:heading-rule . "#303338") (:ok . "#3fb950") (:ok-soft . "#12261e")
             (:warn . "#d29922") (:warn-soft . "#272115") (:danger . "#f85149")
             (:danger-soft . "#2a1518") (:important . "#a371f7")
             (:important-soft . "#221a38"))))
  "Slide palettes by appearance.
Both share the same semantic keys; `etaf-slides-color' is the only reader, so
a view never names a color literal of its own.")

(defun etaf-slides-palette (mode)
  "Return the palette alist of MODE, a light or dark appearance.
An unknown MODE falls back to the light palette instead of failing a render."
  (or (alist-get (if (eq mode 'dark) 'dark 'light) etaf-slides-themes
                 nil nil #'eq)
      (alist-get 'light etaf-slides-themes nil nil #'eq)))

(defun etaf-slides-color (palette key &optional fallback)
  "Return PALETTE's color for semantic KEY, or FALLBACK.
A missing key with no fallback returns the palette's ink, so a typo in a key
paints readable text instead of dropping the whole view."
  (or (cdr (assq key palette))
      fallback
      (cdr (assq :ink palette))
      "#000000"))

(defun etaf-slides-resolve-theme (theme)
  "Return the appearance that THEME names.
THEME is `light', `dark' or `auto'; `auto' follows the frame's appearance
through `etaf-appearance', which is reactive, so a theme switch repaints."
  (if (eq theme 'auto) (or (etaf-appearance) 'light) theme))

(defun etaf-slides-theme-tokens (mode)
  "Return the ETAF UI theme plist for MODE, a light or dark appearance.
The tokens carry the slide surface and the shared controls placed on it; a
component that reads a token missing here would fall back to the catalog's
light default, so the set covers the controls this application uses."
  (let ((palette (etaf-slides-palette mode)))
    (cl-flet ((c (key) (etaf-slides-color palette key)))
      (list :ui-bg (c :bg)
            :ui-fg (c :ink)
            :ui-panel-bg (c :panel)
            :ui-panel-fg (c :ink)
            :ui-panel-border (c :border)
            :ui-muted-fg (c :muted)
            :ui-border (c :border)
            :ui-divider-bg (c :border)
            :ui-accent (c :accent)
            :ui-accent-fg (c :surface)
            :ui-accent-soft-bg (c :accent-soft)
            :ui-button-primary-bg (c :accent)
            :ui-button-primary-fg (c :surface)
            :ui-button-secondary-bg (c :panel)
            :ui-button-secondary-fg (c :ink)
            :ui-button-border (c :border)
            :ui-table-border (c :border)
            :ui-table-selected-bg (c :accent-soft)
            :ui-table-selected-fg (c :ink)
            :ui-success-fg (c :ok)
            :ui-warning-fg (c :warn)
            :ui-danger-fg (c :danger)))))

(provide 'etaf-slides-theme)
;;; etaf-slides-theme.el ends here
