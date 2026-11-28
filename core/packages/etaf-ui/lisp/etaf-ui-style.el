;;; etaf-ui-style.el --- Internal styling for ETAF UI Components -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Private catalog styling.  ETAF owns Theme; this module only supplies
;; fallback values for the semantic tokens consumed by official Components.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(defconst etaf-ui--style-palette
  '(:ui-fg "#252A2E"
    :ui-bg "#FFFDF8"
    :ui-border "#687386"
    :ui-muted-fg "#526174"
    :ui-danger-fg "#FF6B6B"
    :ui-success-fg "#2F6B43"
    :ui-success-bg "#DCEBDD"
    :ui-success-border "#6D8A73"
    :ui-danger-bg "#FFF0F0"
    :ui-danger-border "#CF6A6A"
    :ui-warning-fg "#8A4B08"
    :ui-warning-bg "#FFF3D6"
    :ui-warning-border "#D99A2B"
    :ui-info-fg "#155E75"
    :ui-info-bg "#E0F2FE"
    :ui-info-border "#38A3C7"
    :ui-disabled-fg "#687386"
    :ui-disabled-bg "#E5E7EB"
    :ui-disabled-border "#9CA3AF"
    ;; Buttons and selection controls are tonal pills: primary fills the
    ;; accent, secondary and selected states use its soft tint.
    :ui-button-primary-fg "#FFFFFF"
    :ui-button-primary-bg "#2F6FE4"
    :ui-button-primary-hover-bg (etaf-theme-token :ui-button-primary-bg "#2F6FE4"
                                                   etaf-ui--state-hover-deepen)
    :ui-button-secondary-fg "#1F4FB0"
    :ui-button-secondary-bg "#DCE7FA"
    :ui-button-secondary-hover-bg (etaf-theme-token :ui-button-secondary-bg "#DCE7FA"
                                                     etaf-ui--state-hover-shift)
    :ui-button-ghost-fg "#252A2E"
    :ui-button-ghost-hover-bg (etaf-theme-token :ui-bg "#FFFDF8"
                                                 etaf-ui--state-hover-shift)
    :ui-checkbox-enabled-fg "#252A2E"
    :ui-checkbox-disabled-fg "#6B7280"
    :ui-table-border "#687386"
    :ui-table-selected-fg "#2F6B43"
    :ui-table-selected-bg "#DCEBDD"
    :ui-data-grid-error-fg "#FF6B6B"
    :ui-pagination-muted-fg "#526174"
    :ui-panel-fg "#252A2E"
    :ui-panel-bg "#FFFDF8"
    :ui-panel-hover-bg (etaf-theme-token :ui-panel-bg "#FFFDF8"
                                         etaf-ui--state-hover-shift)
    :ui-panel-border "#687386"
    ;; Desktop surface tokens.  Bars, windows, dividers and pickers read
    ;; these so a Desktop Theme restyles the whole shell through paint slots.
    :ui-accent "#2F6FE4"
    :ui-accent-fg "#FFFFFF"
    :ui-accent-soft-bg "#DCE7FA"
    :ui-shell-bg "#E3E9F0"
    :ui-shell-fg "#16202C"
    :ui-shell-muted-fg "#66727F"
    :ui-shell-item-fg "#4A5664"
    :ui-shell-item-minimized-fg "#98A3AF"
    :ui-window-bg "#FFFFFF"
    :ui-window-fg "#16202C"
    :ui-window-border "#D6DEE7"
    :ui-window-title-bg "#F7F9FC"
    :ui-window-title-fg "#7B8794"
    :ui-window-title-active-fg "#16202C"
    :ui-divider-bg "#DCE3EB"
    :ui-search-bg "#EEF2F6"
    :ui-search-fg "#16202C"
    :ui-picker-item-bg "#F7F9FC"
    :ui-picker-item-fg "#16202C"
    :ui-picker-item-muted-fg "#66727F")
  "Fallback values for semantic tokens used by ETAF UI Components.")

(defun etaf-ui--style-tokens (&rest keys)
  "Return deferred ETAF Theme values for private catalog token KEYS."
  (let (result)
    (dolist (key keys result)
      (setq result
            (plist-put
             result key
             (etaf-theme-token key (plist-get etaf-ui--style-palette key)))))))

(defun etaf-ui--style-token (key)
  "Return the deferred ETAF Theme value for private catalog token KEY."
  (etaf-theme-token key (plist-get etaf-ui--style-palette key)))

(defun etaf-ui--color-hex (color)
  "Return COLOR as #RRGGBB, or nil when Emacs cannot resolve it.
A `#RRGGBB' string is read as it stands.  A face may name its colour, as the
moccasin a string inherits from a theme does, and a name goes through Emacs'
colour table; that table answers in a terminal's own colours, which is why the
hex form is read directly instead of through it."
  (when (stringp color)
    (cond
     ((string-match "\\`#[0-9a-fA-F]\\{6\\}\\'" color) (upcase color))
     (t (when-let* ((channels (ignore-errors (color-name-to-rgb color))))
          (when (cl-every #'numberp channels)
            (apply #'format "#%02X%02X%02X"
                   (mapcar (lambda (channel)
                             (let ((scaled (if (> channel 1.0)
                                               (/ channel 65535.0)
                                             channel)))
                               (max 0 (min 255 (round (* scaled 255))))))
                           channels))))))))

(defun etaf-ui--color-luminance (color)
  "Return the relative luminance of COLOR, or nil when Emacs cannot resolve it.
The channels are linearised the way WCAG defines them, because the contrast
ratio below is only meaningful on that scale."
  (when-let* ((channels (etaf-ui--color-channels (etaf-ui--color-hex color))))
    (cl-destructuring-bind (red green blue) channels
      (let ((linear (lambda (value)
                      (let ((scaled (/ value 255.0)))
                        (if (<= scaled 0.04045)
                            (/ scaled 12.92)
                          (expt (/ (+ scaled 0.055) 1.055) 2.4))))))
        (+ (* 0.2126 (funcall linear red))
           (* 0.7152 (funcall linear green))
           (* 0.0722 (funcall linear blue)))))))

(defun etaf-ui-color-contrast (from to)
  "Return the WCAG contrast ratio between FROM and TO, from 1 to 21.
Either colour may be written the way Emacs resolves colours, `#RRGGBB' or a
name such as `moccasin'; one Emacs cannot resolve has no measurable contrast
and answers 0, which reads as a colour nobody checked."
  (let ((first (etaf-ui--color-luminance from))
        (second (etaf-ui--color-luminance to)))
    (if (and first second)
        (/ (+ (max first second) 0.05) (+ (min first second) 0.05))
      0)))

(defvar etaf-ui--color-legible-cache (make-hash-table :test #'equal)
  "Readable variants of a colour on a surface, keyed by the three inputs.")

(defun etaf-ui-color-legible (color background &optional ratio)
  "Return COLOR made readable on BACKGROUND, keeping its hue.
A syntax colour written for one page disappears on another: the pale pink a
dark theme gives strings vanishes on a white page.  COLOR is mixed toward
black on a light surface and toward white on a dark one, in steps, until it
reaches RATIO (default 4.5, the WCAG AA ratio for body text); a colour that
already passes, and a colour in any spelling other than #RRGGBB, comes back
unchanged.  The answer is cached per (COLOR BACKGROUND RATIO), because a page
re-renders its code blocks on every repaint."
  (let* ((target (or ratio 4.5))
         (start (etaf-ui--color-hex color))
         (surface (etaf-ui--color-hex background)))
    (or (gethash (list color background target) etaf-ui--color-legible-cache)
        (puthash (list color background target)
                 (if (or (not start) (not surface)
                         (>= (etaf-ui-color-contrast start surface) target))
                     color
                   (let* ((toward (if (>= (or (etaf-ui--color-luminance surface) 0) 0.5)
                                      "#000000" "#FFFFFF"))
                          (ink start)
                          (step 0.08))
                     (while (and (< step 1.0)
                                 (< (etaf-ui-color-contrast ink surface) target))
                       (setq ink (etaf-ui-color-mix start toward step))
                       (setq step (+ step 0.08)))
                     (if (>= (etaf-ui-color-contrast ink surface) target)
                         ink
                       toward)))
                 etaf-ui--color-legible-cache))))

(defun etaf-ui-color-mix (from to amount)
  "Return FROM mixed AMOUNT of the way toward TO.
Both colors are #RRGGBB strings; a color in any other spelling is returned
unchanged, which keeps a Theme that uses a named color usable."
  (let ((start (etaf-ui--color-channels from))
        (end (etaf-ui--color-channels to)))
    (if (and start end)
        (apply #'format "#%02X%02X%02X"
               (cl-mapcar (lambda (a b)
                            (max 0 (min 255 (round (+ a (* (- b a) amount))))))
                          start end))
      from)))

(defun etaf-ui--color-channels (color)
  "Return COLOR's (RED GREEN BLUE) channels as numbers, or nil."
  (when (and (stringp color)
             (string-match
              "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'"
              color))
    (list (string-to-number (match-string 1 color) 16)
          (string-to-number (match-string 2 color) 16)
          (string-to-number (match-string 3 color) 16))))



;;; Application palettes

(defconst etaf-ui--theme-roles
  '(:bg :fg :panel :track :border :muted :dim :accent :accent-fg :accent-soft
        :success :success-bg :success-border :warning :warning-bg :warning-border
        :danger :danger-bg :danger-border :info :info-bg :info-border
        :important :important-bg :important-border)
  "Palette roles `etaf-ui-theme-tokens' accepts.")

(defconst etaf-ui--theme-status-colors
  '((:success "#1A7F37" "#3FB950")
    (:warning "#9A6700" "#D29922")
    (:danger "#D1242F" "#F85149")
    (:important "#8250DF" "#A371F7"))
  "Status colors for light and dark backgrounds when a palette omits them.")

(defun etaf-ui--theme-palette-roles (palette)
  "Return PALETTE's roles with every omitted role derived.
PALETTE must name `:bg' and `:fg' as #RRGGBB strings unless every derived
role is supplied too."
  (unless (and (proper-list-p palette) (cl-evenp (length palette)))
    (signal 'wrong-type-argument (list 'plistp palette)))
  (cl-loop for (role value) on palette by #'cddr
           do (unless (memq role etaf-ui--theme-roles)
                (signal 'wrong-type-argument
                        (list (cons 'member etaf-ui--theme-roles) role)))
           do (unless (stringp value)
                (signal 'wrong-type-argument (list 'stringp role value))))
  (dolist (role '(:bg :fg))
    (unless (plist-get palette role)
      (signal 'wrong-type-argument (list 'stringp role nil))))
  (let* ((roles (copy-sequence palette))
         (get (lambda (role) (plist-get roles role)))
         (default (lambda (role value)
                    (unless (plist-get roles role)
                      (setq roles (plist-put roles role value)))))
         (bg (funcall get :bg))
         (fg (funcall get :fg))
         (dark (< (or (etaf-ui--color-luminance bg) 1.0) 0.5)))
    (funcall default :panel bg)
    (funcall default :track (funcall get :panel))
    (funcall default :border (etaf-ui-color-mix bg fg 0.18))
    (funcall default :muted (etaf-ui-color-mix fg bg 0.35))
    (funcall default :dim (funcall get :muted))
    (funcall default :accent fg)
    (funcall default :accent-fg "#FFFFFF")
    (funcall default :accent-soft (etaf-ui-color-mix bg (funcall get :accent) 0.16))
    (dolist (status etaf-ui--theme-status-colors)
      (funcall default (car status) (if dark (nth 2 status) (nth 1 status))))
    (funcall default :info (funcall get :accent))
    (dolist (status '(:success :warning :danger :info :important))
      (let ((color (funcall get status))
            (name (substring (symbol-name status) 1)))
        (funcall default (intern (format ":%s-bg" name))
                 (etaf-ui-color-mix bg color 0.12))
        (funcall default (intern (format ":%s-border" name))
                 (etaf-ui-color-mix bg color 0.35))))
    roles))

(defun etaf-ui-theme-tokens (palette)
  "Return the catalog Theme tokens for application PALETTE.
PALETTE is a plist of #RRGGBB color roles.  `:bg' (the application
surface) and `:fg' (its text) are required.  Optional roles, each derived
when omitted: `:panel' (raised surfaces, default `:bg'), `:track'
\(progress and range tracks, default `:panel'), `:border' (lines),
`:muted' (secondary text), `:dim' (disabled text, default `:muted'),
`:accent' (default `:fg'), `:accent-fg' (text on the accent, default
white), `:accent-soft' (selection and tonal fills), and `:success',
`:warning', `:danger', `:info' and `:important' (default status hues),
each with a `-bg' and `-border' variant.  The result maps these roles
onto every color token the catalog components read, so an application
provides one coherent palette instead of listing each token.  An
application that wants a different value for one token puts that token
before the result when it provides the Theme; the first value of a key
wins."
  (let* ((roles (etaf-ui--theme-palette-roles palette))
         (role (lambda (name) (plist-get roles name)))
         (bg (funcall role :bg)) (fg (funcall role :fg))
         (panel (funcall role :panel)) (track (funcall role :track))
         (border (funcall role :border)) (muted (funcall role :muted))
         (dim (funcall role :dim)) (accent (funcall role :accent))
         (accent-fg (funcall role :accent-fg))
         (accent-soft (funcall role :accent-soft)))
    (list :ui-fg fg :ui-bg bg :ui-border border :ui-muted-fg muted
          :ui-disabled-fg dim :ui-disabled-bg panel :ui-disabled-border border
          :ui-accent accent :ui-accent-fg accent-fg :ui-accent-soft-bg accent-soft
          :ui-button-primary-fg accent-fg :ui-button-primary-bg accent
          :ui-button-secondary-fg accent :ui-button-secondary-bg accent-soft
          :ui-button-ghost-fg muted
          :ui-success-fg (funcall role :success)
          :ui-success-bg (funcall role :success-bg)
          :ui-success-border (funcall role :success-border)
          :ui-warning-fg (funcall role :warning)
          :ui-warning-bg (funcall role :warning-bg)
          :ui-warning-border (funcall role :warning-border)
          :ui-danger-fg (funcall role :danger)
          :ui-danger-bg (funcall role :danger-bg)
          :ui-danger-border (funcall role :danger-border)
          :ui-info-fg (funcall role :info)
          :ui-info-bg (funcall role :info-bg)
          :ui-info-border (funcall role :info-border)
          :ui-important-fg (funcall role :important)
          :ui-important-bg (funcall role :important-bg)
          :ui-important-border (funcall role :important-border)
          :ui-panel-fg fg :ui-panel-bg panel
          :ui-panel-hover-bg (if (and track (not (string-equal-ignore-case track panel)))
                                 track
                               (etaf-ui--state-hover-shift panel))
          :ui-panel-border border
          :ui-divider-bg border
          :ui-progress-track track :ui-range-track track :ui-range-fill accent
          :ui-table-border border :ui-table-selected-fg accent
          :ui-table-selected-bg accent-soft
          :ui-shell-bg panel :ui-shell-fg fg :ui-shell-muted-fg muted
          :ui-shell-item-fg muted :ui-shell-item-minimized-fg dim
          :ui-window-bg bg :ui-window-fg fg :ui-window-border border
          :ui-window-title-bg panel :ui-window-title-fg muted
          :ui-window-title-active-fg fg
          :ui-picker-item-bg panel :ui-picker-item-fg fg
          :ui-picker-item-muted-fg muted
          :ui-pagination-muted-fg muted
          :ui-data-grid-error-fg (funcall role :danger)
          :ui-checkbox-enabled-fg fg :ui-checkbox-disabled-fg dim)))

(defun etaf-ui--state-hover-step (color amount)
  "Return COLOR stepped AMOUNT away from mid grey for a hover fill.
A dark surface gets a darker fill and a light one a lighter fill, so the
fill moves away from the label a themed application paints on it instead
of toward it: the label keeps at least its resting contrast, and one
control adapts to both palettes instead of repeating one fixed tint.  A
surface already near the light or dark extreme steps the other way so the
hover stays visibly distinct."
  (if-let* ((luminance (etaf-ui--color-luminance color)))
      (let* ((dark-p (< luminance 0.5))
             (extreme-p (or (<= luminance 0.02) (>= luminance 0.98)))
             (target (if (eq dark-p extreme-p) "#FFFFFF" "#000000"))
             (fill (etaf-ui-color-mix color target amount)))
        (if (string-equal-ignore-case fill color)
            (etaf-ui-color-mix color (if (equal target "#FFFFFF") "#000000" "#FFFFFF") amount)
          fill))
    color))

(defun etaf-ui--state-hover-shift (color)
  "Return COLOR shifted for a tonal or ghost control's hover fill."
  (etaf-ui--state-hover-step color 0.06))

(defun etaf-ui--state-hover-deepen (color)
  "Return COLOR shifted for a filled control's hover fill.
The filled-control path shares the distance rule with tonal and ghost
controls, so a filled label keeps its contrast in a light or a dark
palette; the historical name is kept for its callers."
  (etaf-ui--state-hover-step color 0.12))

(defun etaf-ui--style-border (value &optional width)
  "Return canonical border VALUE from a semantic ETAF Theme value.
Optional WIDTH is the border thickness in pixels (default 1)."
  (let ((px (or width 1)))
    (cond
     ((etaf-theme-token-p value)
      (etaf-theme-token (nth 1 value) (nth 2 value)
                        (lambda (color) (etaf-ui--style-border color px))))
     ((and (stringp value)
           (string-match-p "\\`#[[:xdigit:]]+\\'" value))
      (list (list 'px px) 'solid value))
     (t value))))

(provide 'etaf-ui-style)
;;; etaf-ui-style.el ends here
