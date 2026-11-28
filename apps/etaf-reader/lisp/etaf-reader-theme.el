;;; etaf-reader-theme.el --- Palettes for etaf-reader -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-reader-error "ETAF reader error")
(defgroup etaf-reader nil "Local ebook reader built with ETAF and Ebox." :group 'applications)
(defcustom etaf-reader-theme 'dark "Appearance: `dark', `light' or `sepia'."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light) (const :tag "Sepia" sepia)) :group 'etaf-reader)
(defconst etaf-reader--surface-modes '((light . "亮") (dark . "暗") (sepia . "纸")) "Host switch modes.")
(defconst etaf-reader--annotation-colors '(red orange yellow green blue purple) "Toolbar annotation keys.")
(defun etaf-reader-annotation-color-keys () "Return toolbar annotation color keys." (copy-sequence etaf-reader--annotation-colors))

(defun etaf-reader--make (mode bg p1 p2 ink acc ok warn danger dsoft wsoft extras)
  (let ((p (etaf-ui-host-theme-palette :mode mode :curated t :aliases t :bg bg :fg ink :surface-1 p1 :surface-2 p2
                                       :track p2 :accent acc :accent-fg "#FFFFFF" :ok ok :warn warn :warn-soft wsoft
                                       :danger danger :danger-soft dsoft :danger-border danger)))
    (append extras (list :sidebar p2 :subtle p2 :raised p1 :pressed (plist-get p :border-subtle)
                         :line (plist-get p :border-subtle) :faint (plist-get p :border-strong)
                         :cover p2 :sel (plist-get p :accent-soft) :plank-top p1) p)))

(defconst etaf-reader--palettes
  (list
   (cons 'dark (etaf-reader--make 'dark "#111110" "#191918" "#222221" "#eeeeec" "#3e63dd" "#4FBF8B" "#f3d673" "#ff9592" "#3b1219" "#3f3618"
                '(:sidebar "#191918" :accent-text "#9eb1ff" :accent-soft "#1d2e62" :sel "#263a75" :quote "#9eb1ff"
                  :plank-face "#252523" :plank-top "#3b3a37" :plank-edge "#161615" :gold "#f3d673"
                  :red "#ff9592" :red-soft "#3b1219" :orange "#ff9d5c" :orange-soft "#3a2410" :yellow "#f3d673" :yellow-soft "#3f3618"
                  :green "#3dd68c" :green-soft "#132d21" :blue "#9eb1ff" :blue-soft "#1d2e62" :purple "#baa7ff" :purple-soft "#291f43")))
   (cons 'light (etaf-reader--make 'light "#f9f9f8" "#ffffff" "#f1f0ef" "#21201c" "#3e63dd" "#2E7D5B" "#b07a16" "#ce2c31" "#feebec" "#faf0cd"
                 '(:accent-text "#3a5bc7" :accent-soft "#e1e9ff" :sel "#dce6ff" :quote "#3a5bc7"
                   :plank-face "#e6e5e2" :plank-edge "#cfceca" :gold "#b07a16"
                   :red "#ce2c31" :red-soft "#feebec" :orange "#c46a16" :orange-soft "#fbead9" :yellow "#a8861b" :yellow-soft "#faf0cd"
                   :green "#218358" :green-soft "#e6f6eb" :blue "#3e63dd" :blue-soft "#e1e9ff" :purple "#6550b9" :purple-soft "#f4f0fe")))
   (cons 'sepia (etaf-reader--make 'light "#f6efdf" "#fbf6ea" "#f0e7d3" "#3b3225" "#8a6a2f" "#2E7D5B" "#8a6a2f" "#b0453a" "#f0dcd4" "#e9db9f"
                 '(:accent-text "#7a5c24" :accent-soft "#ece0c6" :cover "#efe4cd" :sel "#e2d2ae" :quote "#7a6440"
                   :plank-face "#e8dcc3" :plank-edge "#d6c6a4" :gold "#8a6a2f"
                   :red "#b0453a" :red-soft "#f0dcd4" :orange "#a2641f" :orange-soft "#efe0c8" :yellow "#8f7517" :yellow-soft "#e9db9f"
                   :green "#4c7a54" :green-soft "#dfe8d4" :blue "#3f6293" :blue-soft "#dfe4ee" :purple "#6e5590" :purple-soft "#e7dff0"))))
  "Palette of every supported appearance, keyed by mode.")

(defconst etaf-reader--format-colors
  '((dark (epub "#3dd68c" "#132d21") (pdf "#ff9592" "#3b1219") (mobi "#ffe7b3" "#302008") (azw3 "#baa7ff" "#291f43"))
    (light (epub "#218358" "#e6f6eb") (pdf "#ce2c31" "#feebec") (mobi "#ab6400" "#fff7c2") (azw3 "#6550b9" "#f4f0fe"))
    (sepia (epub "#4c7a54" "#dfe8d4") (pdf "#b0453a" "#f0dcd4") (mobi "#a2641f" "#efe0c8") (azw3 "#6e5590" "#e7dff0")))
  "Ink and fill of each format badge, keyed by mode.")

(defun etaf-reader--mode (&optional mode)
  (let ((m (or mode etaf-reader-theme))) (if (assq m etaf-reader--palettes) m 'dark)))

(defun etaf-reader-color (key &optional mode)
  "Return the palette color named KEY, signaling `etaf-reader-error' if unknown."
  (or (and (keywordp key) (plist-get (cdr (assq (etaf-reader--mode mode) etaf-reader--palettes)) key))
      (signal 'etaf-reader-error (list (format "Unknown color: %S" key)))))

(defun etaf-reader-format-colors (format &optional mode)
  "Return (INK . FILL) for FORMAT."
  (let* ((m (etaf-reader--mode mode))
         (e (assq (intern (downcase (or format ""))) (cdr (assq m etaf-reader--format-colors)))))
    (if e (cons (nth 1 e) (nth 2 e))
      (cons (etaf-reader-color :muted m) (etaf-reader-color (if (memq m '(dark sepia)) :panel2 :subtle) m)))))

(defun etaf-reader-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE."
  (let ((p (cdr (assq (etaf-reader--mode mode) etaf-reader--palettes))))
    (etaf-ui-host-theme-tokens :palette p
     :overrides (list :ui-disabled-bg (plist-get p :panel2) :ui-search-bg (plist-get p :subtle) :ui-search-fg (plist-get p :ink)))))

(provide 'etaf-reader-theme)
;;; etaf-reader-theme.el ends here
