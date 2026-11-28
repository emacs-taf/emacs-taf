;;; etaf-devtools-core.el --- Core options, palette and safe formatting -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shared error conditions, user customization options, cyclic-safe value
;; formatting, source-definition navigation and theme-derived palette helpers
;; for `etaf-devtools'.  Every colour is derived dynamically from the active
;; Emacs frame via `etaf-ui-color-mix' and `etaf-ui-color-legible'.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)

(defgroup etaf-devtools nil
  "Interactive runtime inspector and developer tools for ETAF."
  :group 'etaf)

(define-error 'etaf-devtools-error "ETAF DevTools error")

(defcustom etaf-devtools-default-dock 'right
  "Default presentation placement when opening `etaf-devtools'.
Supported values are `right' (right side window), `bottom' (bottom side
window) and `posframe' (floating child frame via `etaf-posframe')."
  :type '(choice (const :tag "Right side window" right)
                 (const :tag "Bottom side window" bottom)
                 (const :tag "Floating posframe" posframe))
  :group 'etaf-devtools)

(defcustom etaf-devtools-right-width 68
  "Preferred column width for a right-docked `etaf-devtools' side window."
  :type 'integer
  :group 'etaf-devtools)

(defcustom etaf-devtools-bottom-height 18
  "Preferred line height for a bottom-docked `etaf-devtools' side window."
  :type 'integer
  :group 'etaf-devtools)

(defcustom etaf-devtools-max-flush-history 200
  "Maximum number of flush summaries retained in the Perf timeline."
  :type 'integer
  :group 'etaf-devtools)

(defcustom etaf-devtools-highlight-duration 0.35
  "Seconds that incremental Highlight Updates overlays remain visible."
  :type 'number
  :group 'etaf-devtools)

(defcustom etaf-devtools-full-highlight-duration 0.45
  "Seconds that full-redraw Highlight Updates overlays remain visible."
  :type 'number
  :group 'etaf-devtools)

(defcustom etaf-devtools-use-posframe t
  "When non-nil, allow `etaf-posframe' for floating panels and picker badges."
  :type 'boolean
  :group 'etaf-devtools)

(defvar etaf-devtools--palette-cache nil
  "Cached (KEY . PALETTE) for `etaf-devtools--palette'.")

(defvar etaf-devtools--theme-generation (etaf-ref 0 :name 'devtools-theme-gen)
  "Monotonic reactive counter bumped when the active Emacs theme changes.")

(defun etaf-devtools--valid-color (value)
  "Return VALUE as a #RRGGBB hex string when valid, else nil."
  (when (and (stringp value)
             (not (member value '("unspecified" "unspecified-bg" "unspecified-fg"))))
    (if (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" value)
        (downcase value)
      (when-let* ((rgb (color-name-to-rgb value)))
        (apply #'color-rgb-to-hex (append rgb (list 2)))))))

(defun etaf-devtools--face-color (face attr frame &optional fallback)
  "Return FACE's ATTR hex colour on FRAME, or FALLBACK."
  (let* ((val (and (facep face)
                   (frame-live-p frame)
                   (face-attribute face attr frame t))))
    (or (etaf-devtools--valid-color val) fallback)))

(defun etaf-devtools--luminance (hex)
  "Return perceived luminance (0..1) of HEX."
  (pcase-let ((`(,r ,g ,b) (or (color-name-to-rgb hex) '(0.5 0.5 0.5))))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun etaf-devtools--dark-bg-p (hex)
  "Return non-nil when background colour HEX is dark."
  (< (etaf-devtools--luminance hex) 0.45))

(defun etaf-devtools--calm-accent (bg raw dark-p)
  "Return calm, legible accent derived from RAW against BG."
  (let* ((base (or (etaf-devtools--valid-color raw)
                   (if dark-p "#4dd0e1" "#005e8b")))
         (calmed (if (and dark-p (> (etaf-devtools--luminance base) 0.72))
                     (etaf-ui-color-mix bg base 0.72)
                   base)))
    (etaf-ui-color-legible calmed bg 3.5)))

(defun etaf-devtools--palette-key (&optional frame)
  "Return cache key for FRAME's current theme colours."
  (let ((fr (or (and (frame-live-p frame) frame) (selected-frame))))
    (list (etaf-theme-current-mode)
          (frame-parameter fr 'background-color)
          (frame-parameter fr 'foreground-color)
          custom-enabled-themes
          (etaf-devtools--face-color 'shadow :foreground fr)
          (etaf-devtools--face-color 'link :foreground fr)
          (etaf-devtools--face-color 'font-lock-function-name-face :foreground fr)
          (etaf-devtools--face-color 'hl-line :background fr))))

(defun etaf-devtools--clear-palette-cache (&rest _)
  "Invalidate cached palette and notify reactive DevTools views."
  (setq etaf-devtools--palette-cache nil)
  (etaf-update-value etaf-devtools--theme-generation #'1+))

(add-hook 'enable-theme-functions #'etaf-devtools--clear-palette-cache)
(add-hook 'disable-theme-functions #'etaf-devtools--clear-palette-cache)

(defun etaf-devtools--derive-palette (&optional frame)
  "Derive a complete DevTools colour palette from FRAME's active Emacs theme."
  (let* ((fr (or (and (frame-live-p frame) frame) (selected-frame)))
         (bg (etaf-devtools--face-color 'default :background fr "#263238"))
         (dark-p (etaf-devtools--dark-bg-p bg))
         (ink (etaf-devtools--face-color 'default :foreground fr
                                         (if dark-p "#ffffff" "#1a1a1a")))
         (muted (or (let ((s (etaf-devtools--face-color 'shadow :foreground fr)))
                      (and s (>= (etaf-ui-color-contrast s bg) 3.0) s))
                    (etaf-ui-color-mix bg ink (if dark-p 0.62 0.58))))
         (dim (etaf-ui-color-mix bg ink (if dark-p 0.38 0.40)))
         (raw-accent (or (etaf-devtools--face-color 'link :foreground fr)
                         (etaf-devtools--face-color 'font-lock-function-name-face :foreground fr)
                         (etaf-devtools--face-color 'font-lock-keyword-face :foreground fr)
                         (if dark-p "#4dd0e1" "#005e8b")))
         (accent (etaf-devtools--calm-accent bg raw-accent dark-p))
         (accent-fg (if (>= (etaf-ui-color-contrast "#ffffff" accent) 4.2)
                        "#ffffff"
                      "#101418"))
         (kw (etaf-ui-color-legible
              (or (etaf-devtools--face-color 'font-lock-keyword-face :foreground fr)
                  (if dark-p "#fff59d" "#721045"))
              bg 3.2))
         (ok (etaf-ui-color-legible
              (or (etaf-devtools--face-color 'font-lock-string-face :foreground fr)
                  (etaf-devtools--face-color 'success :foreground fr)
                  (if dark-p "#9ccc65" "#006800"))
              bg 3.2))
         (warn (etaf-ui-color-legible
                (or (etaf-devtools--face-color 'warning :foreground fr)
                    (if dark-p "#ff9800" "#884900"))
                bg 3.2))
         (danger (etaf-ui-color-legible
                  (or (etaf-devtools--face-color 'error :foreground fr)
                      (if dark-p "#f36c60" "#a60000"))
                  bg 3.2))
         (surface (etaf-ui-color-mix bg ink (if dark-p 0.04 0.032)))
         (surface2 (etaf-ui-color-mix bg ink (if dark-p 0.085 0.065)))
         (line (etaf-ui-color-mix bg ink (if dark-p 0.14 0.14)))
         (line-soft (etaf-ui-color-mix bg ink (if dark-p 0.09 0.085)))
         (select (or (let ((hl (etaf-devtools--face-color 'hl-line :background fr)))
                       (and hl
                            (> (etaf-ui-color-contrast hl bg) 1.08)
                            (< (etaf-ui-color-contrast hl bg) 2.2)
                            hl))
                     (etaf-ui-color-mix bg accent (if dark-p 0.16 0.12))))
         (hover (etaf-ui-color-mix bg ink (if dark-p 0.065 0.05)))
         (soft (if dark-p 0.17 0.11)))
    (list :dark dark-p
          :bg bg
          :surface surface
          :surface2 surface2
          :line line
          :line-soft line-soft
          :select select
          :hover hover
          :ink ink
          :muted muted
          :dim dim
          :kw kw
          :accent accent
          :accent-fg accent-fg
          :accent-soft (etaf-ui-color-mix bg accent soft)
          :ok ok
          :ok-soft (etaf-ui-color-mix bg ok soft)
          :warn warn
          :warn-soft (etaf-ui-color-mix bg warn soft)
          :danger danger
          :danger-soft (etaf-ui-color-mix bg danger soft)
          :box-margin (etaf-ui-color-mix bg warn (if dark-p 0.14 0.12))
          :box-border (etaf-ui-color-mix bg accent (if dark-p 0.18 0.15))
          :box-padding (etaf-ui-color-mix bg ok (if dark-p 0.16 0.12))
          :box-content (etaf-ui-color-mix bg accent (if dark-p 0.28 0.22))
          :highlight-fill (etaf-ui-color-mix bg accent (if dark-p 0.17 0.12))
          :flash-inc (etaf-ui-color-mix bg accent (if dark-p 0.26 0.18))
          :flash-full (etaf-ui-color-mix bg warn (if dark-p 0.30 0.22)))))

(defun etaf-devtools--palette (&optional frame)
  "Return cached theme-derived palette for FRAME."
  (let ((key (etaf-devtools--palette-key frame)))
    (if (and etaf-devtools--palette-cache
             (equal (car etaf-devtools--palette-cache) key))
        (cdr etaf-devtools--palette-cache)
      (let ((pal (etaf-devtools--derive-palette frame)))
        (setq etaf-devtools--palette-cache (cons key pal))
        pal))))

(defun etaf-devtools--theme-tokens (&optional frame)
  "Build `etaf-ui-theme-tokens' plist for `etaf-theme-provide'."
  (let ((p (etaf-devtools--palette frame)))
    (append
     (list :ui-search-bg (plist-get p :surface)
           :ui-search-fg (plist-get p :ink))
     (etaf-ui-theme-tokens
      (list :bg (plist-get p :bg)
            :fg (plist-get p :ink)
            :panel (plist-get p :surface)
            :track (plist-get p :surface2)
            :border (plist-get p :line)
            :muted (plist-get p :muted)
            :dim (plist-get p :dim)
            :accent (plist-get p :accent)
            :accent-fg (plist-get p :accent-fg)
            :accent-soft (plist-get p :accent-soft)
            :success (plist-get p :ok)
            :warning (plist-get p :warn)
            :danger (plist-get p :danger)
            :info (plist-get p :accent))))))

(defun etaf-devtools--safe-print (value &optional max-chars)
  "Return a cyclic-safe, property-free string representation of VALUE."
  (let* ((limit (or max-chars 100))
         (print-circle t)
         (print-length 10)
         (print-level 4)
         (print-escape-newlines t)
         (raw (condition-case nil
                  (substring-no-properties (prin1-to-string value))
                (error "#<unprintable>"))))
    (if (> (length raw) limit)
        (concat (substring raw 0 (max 1 (1- limit))) "…")
      raw)))

(defun etaf-devtools--truncate (text max-cols)
  "Truncate single-line TEXT to fit MAX-COLS display columns with ellipsis."
  (let ((s (if (stringp text) (substring-no-properties text) (format "%s" text))))
    (setq s (replace-regexp-in-string "[\n\r\t]+" " " s))
    (if (<= (string-width s) max-cols)
        s
      (concat (truncate-string-to-width s (max 1 (1- max-cols))) "…"))))

(defun etaf-devtools--hex-color-p (value)
  "Return non-nil when VALUE is a #RRGGBB colour string."
  (and (stringp value)
       (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" value)))

(defun etaf-devtools--parse-lisp-input (text)
  "Safely read exactly one Lisp value from TEXT without evaluating arbitrary code.
Supports nil, t, numbers, strings, keywords, quoted symbols/lists and plain
symbol/list literals.  Signals `etaf-devtools-error' on syntax errors."
  (let ((trimmed (string-trim (or text ""))))
    (when (string-empty-p trimmed)
      (signal 'etaf-devtools-error '("Value cannot be empty")))
    (condition-case err
        (pcase-let ((`(,form . ,pos) (read-from-string trimmed)))
          (unless (string-empty-p (string-trim (substring trimmed pos)))
            (signal 'etaf-devtools-error
                    (list "Trailing input after Lisp value" trimmed)))
          (if (and (consp form) (eq (car form) 'quote) (= (length form) 2))
              (cadr form)
            form))
      (etaf-devtools-error (signal (car err) (cdr err)))
      (error
       (signal 'etaf-devtools-error
               (list (format "Invalid Lisp value: %s" (error-message-string err))))))))

(defun etaf-devtools--jump-to-component (name source-file)
  "Jump to `(etaf-define-component NAME ...)' in SOURCE-FILE."
  (let* ((file (or source-file
                   (let ((def-sym (intern-soft (format "%s--etaf-component-definition" name))))
                     (and def-sym (symbol-file def-sym 'defvar)))))
         (el-file (and file
                       (if (string-suffix-p ".elc" file)
                           (concat (substring file 0 -4) ".el")
                         file))))
    (unless (and el-file (file-readable-p el-file))
      (user-error "Cannot locate source file for Component `%s'" name))
    (let ((buf (find-file-noselect el-file)))
      (pop-to-buffer buf)
      (goto-char (point-min))
      (let ((pattern (format "(etaf-define-component[ \t\n]+%s\\b"
                             (regexp-quote (symbol-name name)))))
        (when (re-search-forward pattern nil t)
          (goto-char (match-beginning 0))
          (recenter)))
      t)))

(provide 'etaf-devtools-core)
;;; etaf-devtools-core.el ends here
