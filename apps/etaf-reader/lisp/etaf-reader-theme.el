;;; etaf-reader-theme.el --- Palettes for etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Three fixed palettes with one paper-like page and six annotation colors.
;; `etaf-reader-color' is the lookup used by the Views; the application
;; projects the same palette onto the ETAF UI token contract so shared
;; etaf-ui Components (buttons, tabs, progress bars) follow the reader.

;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-reader-error "ETAF reader error")

(defgroup etaf-reader nil
  "Local ebook reader built with ETAF and Ebox."
  :group 'applications)

(defcustom etaf-reader-theme 'dark
  "Appearance of a new reader session: `dark', `light' or `sepia'.
The running choice is the session's mode cell, which the reader's own switch
and a panel's title-bar switch both write; this option only seeds it."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light)
                 (const :tag "Sepia" sepia))
  :group 'etaf-reader)

(defconst etaf-reader--surface-modes
  '((light . "亮") (dark . "暗") (sepia . "纸"))
  "Appearance modes the reader offers its host, in display order.
The third segment picks the paper palette, which the reader keeps for long
reading.")

;;: One entry per palette.  The six annotation colors come in a strong ink
;;: (underline styles and toolbar dots) and a soft tint (highlight fill).
(defconst etaf-reader--palettes
  '((dark :bg "#111110" :sidebar "#191918" :panel "#191918" :panel2 "#222221"
          :subtle "#222221" :raised "#222221" :hover "#2a2a28" :pressed "#31312e"
          :line "#31312e" :border "#3b3a37" :border-strong "#62605b"
          :ink "#eeeeec" :muted "#b5b3ad" :dim "#6f6d66" :faint "#494844"
          :accent "#3e63dd" :accent-text "#9eb1ff" :accent-soft "#1d2e62"
          :cover "#222221" :sel "#182449" :quote "#9eb1ff"
          :plank-face "#2a2a28" :plank-top "#3b3a37" :plank-edge "#191918"
          :gold "#f3d673"
          :red "#ff9592" :red-soft "#3b1219"
          :orange "#ff9d5c" :orange-soft "#3a2410"
          :yellow "#f3d673" :yellow-soft "#37301a"
          :green "#3dd68c" :green-soft "#132d21"
          :blue "#9eb1ff" :blue-soft "#1d2e62"
          :purple "#baa7ff" :purple-soft "#291f43")
    (light :bg "#f9f9f8" :sidebar "#f1f0ef" :panel "#ffffff" :panel2 "#f1f0ef"
           :subtle "#f1f0ef" :raised "#ffffff" :hover "#e9e8e6" :pressed "#e2e1de"
           :line "#e2e1de" :border "#dad9d6" :border-strong "#bcbbb5"
           :ink "#21201c" :muted "#63635e" :dim "#8d8d86" :faint "#bcbbb5"
           :accent "#3e63dd" :accent-text "#3a5bc7" :accent-soft "#e1e9ff"
           :cover "#f1f0ef" :sel "#edf2fe" :quote "#3a5bc7"
           :plank-face "#e2e1de" :plank-top "#ffffff" :plank-edge "#cfceca"
           :gold "#b07a16"
           :red "#ce2c31" :red-soft "#feebec"
           :orange "#c46a16" :orange-soft "#fbead9"
           :yellow "#a8861b" :yellow-soft "#faf0cd"
           :green "#218358" :green-soft "#e6f6eb"
           :blue "#3e63dd" :blue-soft "#e1e9ff"
           :purple "#6550b9" :purple-soft "#f4f0fe")
    (sepia :bg "#f6efdf" :sidebar "#f0e7d3" :panel "#fbf6ea" :panel2 "#f0e7d3"
           :subtle "#f0e7d3" :raised "#fbf6ea" :hover "#e8dcc3" :pressed "#ddceb0"
           :line "#e0d3b6" :border "#d6c6a4" :border-strong "#b7a37c"
           :ink "#3b3225" :muted "#6d5e47" :dim "#95846a" :faint "#b7a37c"
           :accent "#8a6a2f" :accent-text "#7a5c24" :accent-soft "#ece0c6"
           :cover "#efe4cd" :sel "#ece0c6" :quote "#7a6440"
           :plank-face "#e8dcc3" :plank-top "#fbf6ea" :plank-edge "#d6c6a4"
           :gold "#8a6a2f"
           :red "#b0453a" :red-soft "#f0dcd4"
           :orange "#a2641f" :orange-soft "#efe0c8"
           :yellow "#8f7517" :yellow-soft "#eee4c0"
           :green "#4c7a54" :green-soft "#dfe8d4"
           :blue "#3f6293" :blue-soft "#dfe4ee"
           :purple "#6e5590" :purple-soft "#e7dff0"))
  "Palette of every supported appearance, keyed by mode.
The steps come from the Radix sand and indigo scales, so the three modes
share one colour system instead of three unrelated sets.")

(defconst etaf-reader--format-colors
  '((dark (epub "#3dd68c" "#132d21") (pdf "#ff9592" "#3b1219")
          (mobi "#ffe7b3" "#302008") (azw3 "#baa7ff" "#291f43"))
    (light (epub "#218358" "#e6f6eb") (pdf "#ce2c31" "#feebec")
           (mobi "#ab6400" "#fff7c2") (azw3 "#6550b9" "#f4f0fe"))
    (sepia (epub "#4c7a54" "#dfe8d4") (pdf "#b0453a" "#f0dcd4")
           (mobi "#a2641f" "#efe0c8") (azw3 "#6e5590" "#e7dff0")))
  "Ink and fill of each format badge, keyed by mode.
Formats outside the list take the palette's secondary text on a subtle fill.")

(defun etaf-reader-format-colors (format &optional mode)
  "Return (INK . FILL) for FORMAT, a format name such as \"EPUB\"."
  (let* ((mode (if (assq (or mode etaf-reader-theme) etaf-reader--palettes)
                   (or mode etaf-reader-theme)
                 'dark))
         (key (intern (downcase (or format ""))))
         (entry (assq key (cdr (assq mode etaf-reader--format-colors)))))
    (cond (entry (cons (nth 1 entry) (nth 2 entry)))
          ((memq mode '(dark sepia))
           (cons (etaf-reader-color :muted mode) (etaf-reader-color :panel2 mode)))
          (t (cons (etaf-reader-color :muted mode) (etaf-reader-color :subtle mode))))))

(defconst etaf-reader--annotation-colors
  '(red orange yellow green blue purple)
  "Annotation color keys offered by the toolbar, in display order.")

(defun etaf-reader-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to `etaf-reader-theme'; an unknown mode falls back to `dark'.
An unknown KEY signals `etaf-reader-error' instead of painting a fallback."
  (let* ((mode (if (assq (or mode etaf-reader-theme) etaf-reader--palettes)
                   (or mode etaf-reader-theme)
                 'dark))
         (palette (cdr (assq mode etaf-reader--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (signal 'etaf-reader-error (list (format "Unknown color: %S" key))))
    color))

(defun etaf-reader-annotation-color-keys ()
  "Return the annotation color keys in toolbar order."
  (copy-sequence etaf-reader--annotation-colors))

(defun etaf-reader-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
The application passes the result to `etaf-theme-provide' so shared etaf-ui
Components follow the reader's palette."
  (let ((dark (eq (or mode etaf-reader-theme) 'dark))
        (panel2 (etaf-reader-color :panel2 mode))
        (danger (etaf-reader-color :red mode)))
    ;; Disabled fills sit on the second panel tone, one step above the
    ;; catalog's default of the first.
    (cons :ui-disabled-bg
          (cons panel2
                (etaf-ui-theme-tokens
                 (list :bg (etaf-reader-color :bg mode)
                       :fg (etaf-reader-color :ink mode)
                       :panel (etaf-reader-color :panel mode)
                       :track panel2
                       :border (etaf-reader-color :border mode)
                       :muted (etaf-reader-color :muted mode)
                       :dim (etaf-reader-color :dim mode)
                       :accent (etaf-reader-color :accent mode)
                       :accent-fg "#FFFFFF"
                       :accent-soft (etaf-reader-color :accent-soft mode)
                       :success (if dark "#4FBF8B" "#2E7D5B")
                       :danger danger
                       :danger-bg (etaf-reader-color :red-soft mode)
                       :danger-border danger
                       :warning (etaf-reader-color :gold mode)
                       :warning-bg (etaf-reader-color :yellow-soft mode)))))))

(provide 'etaf-reader-theme)
;;; etaf-reader-theme.el ends here
