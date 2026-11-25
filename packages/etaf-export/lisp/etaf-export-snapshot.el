;;; etaf-export-snapshot.el --- Rendered ETAF buffer capture for export -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Captures a mounted ETAF buffer's rendered rows, resolved faces, pixel-aligned
;; horizontal geometry, inline decorations and sliced image/SVG descriptors
;; using standard Emacs buffer/face APIs and ETAF's public runtime interface.
;; Supports optional perceptual dark-to-light paper remapping without mutating
;; the live Emacs buffer.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)

(defconst etaf-export--default-font-stack
  "Menlo, SF Mono, Monaco, LXGW WenKai Mono, PingFang SC, Hiragino Sans GB, Noto Sans Mono CJK SC, monospace"
  "Default fallback font stack for monospace Latin, box drawing and CJK.")

;;;; Color Conversion and Light-Print Remapping

(defun etaf-export--color-hex (color)
  "Normalize Emacs COLOR specification to lowercase \"#rrggbb\", or nil."
  (cond
   ((or (null color) (eq color 'unspecified) (eq color t)) nil)
   ((not (stringp color)) nil)
   ((string-prefix-p "unspecified" color) nil)
   ((string-match "\\`#\\([0-9a-fA-F]\\{6\\}\\)\\'" color)
    (downcase color))
   ((string-match "\\`#\\([0-9a-fA-F]\\)\\([0-9a-fA-F]\\)\\([0-9a-fA-F]\\)\\'" color)
    (downcase (format "#%s%s%s%s%s%s"
                      (match-string 1 color) (match-string 1 color)
                      (match-string 2 color) (match-string 2 color)
                      (match-string 3 color) (match-string 3 color))))
   ((string-match "\\`#\\([0-9a-fA-F]\\{2\\}\\)[0-9a-fA-F]\\{2\\}\\([0-9a-fA-F]\\{2\\}\\)[0-9a-fA-F]\\{2\\}\\([0-9a-fA-F]\\{2\\}\\)[0-9a-fA-F]\\{2\\}\\'" color)
    (downcase (format "#%s%s%s"
                      (match-string 1 color)
                      (match-string 2 color)
                      (match-string 3 color))))
   (t
    (when-let* ((rgb (ignore-errors (color-values color))))
      (format "#%02x%02x%02x"
              (ash (nth 0 rgb) -8)
              (ash (nth 1 rgb) -8)
              (ash (nth 2 rgb) -8))))))

(defun etaf-export--hex-to-rgb01 (hex)
  "Convert \"#rrggbb\" HEX to normalized (R G B) floats in [0.0, 1.0]."
  (when (and (stringp hex) (= (length hex) 7) (= (aref hex 0) ?#))
    (list (/ (string-to-number (substring hex 1 3) 16) 255.0)
          (/ (string-to-number (substring hex 3 5) 16) 255.0)
          (/ (string-to-number (substring hex 5 7) 16) 255.0))))

(defun etaf-export--rgb01-to-hex (r g b)
  "Convert normalized (R G B) floats in [0.0, 1.0] to lowercase \"#rrggbb\"."
  (format "#%02x%02x%02x"
          (max 0 (min 255 (round (* r 255.0))))
          (max 0 (min 255 (round (* g 255.0))))
          (max 0 (min 255 (round (* b 255.0))))))

(defun etaf-export--color-luma (hex)
  "Return relative WCAG luminance of HEX in [0.0, 1.0]."
  (if-let* ((rgb (etaf-export--hex-to-rgb01 hex)))
      (cl-labels ((lin (c)
                    (if (<= c 0.03928)
                        (/ c 12.92)
                      (expt (/ (+ c 0.055) 1.055) 2.4))))
        (+ (* 0.2126 (lin (nth 0 rgb)))
           (* 0.7152 (lin (nth 1 rgb)))
           (* 0.0722 (lin (nth 2 rgb)))))
    0.5))

(defun etaf-export--dark-p (hex)
  "Return non-nil when HEX is a dark surface color."
  (< (etaf-export--color-luma (or hex "#ffffff")) 0.42))

(defun etaf-export--rgb-chroma (r g b)
  "Return RGB chroma (max - min) in [0.0, 1.0], robust near white and black."
  (- (max r g b) (min r g b)))

(defun etaf-export--remap-bg-light (hex canvas-hex)
  "Remap background HEX from dark CANVAS-HEX onto a clean white-paper surface."
  (let ((c (etaf-export--color-hex hex)))
    (cond
     ((null c) nil)
     ((not (etaf-export--dark-p canvas-hex)) c)
     ((equal c canvas-hex) "#ffffff")
     (t
      (pcase-let* ((`(,r ,g ,b) (etaf-export--hex-to-rgb01 c))
                   (chroma (etaf-export--rgb-chroma r g b))
                   (`(,h ,s ,l) (color-rgb-to-hsl r g b))
                   (`(,cr ,cg ,cb) (etaf-export--hex-to-rgb01 canvas-hex))
                   (`(,_ch ,_cs ,cl) (color-rgb-to-hsl cr cg cb))
                   (dl (max 0.0 (- l cl))))
        (if (< chroma 0.07)
            (let* ((nl (max 0.86 (min 0.985 (- 0.985 (* dl 1.35)))))
                   (nrgb (color-hsl-to-rgb h (* s 0.25) nl)))
              (etaf-export--rgb01-to-hex (nth 0 nrgb) (nth 1 nrgb) (nth 2 nrgb)))
          (let* ((ns (min s 0.65))
                 (nl (max 0.90 (min 0.96 (- 0.965 (* dl 0.35)))))
                 (nrgb (color-hsl-to-rgb h ns nl)))
            (etaf-export--rgb01-to-hex (nth 0 nrgb) (nth 1 nrgb) (nth 2 nrgb)))))))))

(defun etaf-export--remap-border-light (hex canvas-hex)
  "Remap border or rule HEX from dark CANVAS-HEX to crisp light-paper ink."
  (let ((c (etaf-export--color-hex hex)))
    (cond
     ((null c) nil)
     ((not (etaf-export--dark-p canvas-hex)) c)
     (t
      (pcase-let* ((`(,r ,g ,b) (etaf-export--hex-to-rgb01 c))
                   (chroma (etaf-export--rgb-chroma r g b))
                   (`(,h ,s ,l) (color-rgb-to-hsl r g b)))
        (if (< chroma 0.08)
            (let* ((nl (max 0.62 (min 0.87 (- 1.06 l))))
                   (nrgb (color-hsl-to-rgb h (* s 0.2) nl)))
              (etaf-export--rgb01-to-hex (nth 0 nrgb) (nth 1 nrgb) (nth 2 nrgb)))
          (etaf-ui-color-legible c "#ffffff" 3.2)))))))

(defun etaf-export--remap-fg-light (hex bg-light canvas-hex)
  "Remap foreground HEX from dark CANVAS-HEX so it is legible over BG-LIGHT."
  (let ((c (etaf-export--color-hex hex))
        (bg (or bg-light "#ffffff")))
    (cond
     ((null c) nil)
     ((not (etaf-export--dark-p canvas-hex)) c)
     (t
      (pcase-let* ((`(,r ,g ,b) (etaf-export--hex-to-rgb01 c))
                   (chroma (etaf-export--rgb-chroma r g b))
                   (`(,h ,s ,l) (color-rgb-to-hsl r g b)))
        (cond
         ;; Subtle dark-on-dark box-drawing characters (table rules/dividers)
         ((and (< chroma 0.09) (< l 0.38))
          (etaf-export--remap-border-light c canvas-hex))
         ((< chroma 0.09)
          (let* ((nl (max 0.12 (min 0.44 (- 1.03 l))))
                 (nrgb (color-hsl-to-rgb h (* s 0.18) nl))
                 (cand (etaf-export--rgb01-to-hex (nth 0 nrgb) (nth 1 nrgb) (nth 2 nrgb))))
            (etaf-ui-color-legible cand bg 4.5)))
         (t
          (let* ((nl (min l 0.44))
                 (nrgb (color-hsl-to-rgb h (min 0.85 (max s 0.45)) nl))
                 (cand (etaf-export--rgb01-to-hex (nth 0 nrgb) (nth 1 nrgb) (nth 2 nrgb))))
            (etaf-ui-color-legible cand bg 4.5)))))))))

(defun etaf-export--remap-svg-light (svg-text canvas-hex)
  "Adapt dark-themed hex colors inside SVG-TEXT for crisp light-paper printing."
  (if (not (and (stringp svg-text) (etaf-export--dark-p canvas-hex)))
      svg-text
    (let ((case-fold-search t))
      (replace-regexp-in-string
       "\\b\\(fill\\|stroke\\|color\\)\\([ \t]*[:=][ \t]*[\"']?\\)\\(#[0-9a-fA-F]\\{6\\}\\)"
       (lambda (match)
         (let* ((prop (downcase (match-string 1 match)))
                (sep (match-string 2 match))
                (raw (downcase (match-string 3 match)))
                (mapped
                 (cond
                  ((equal raw canvas-hex) "#ffffff")
                  ((string= prop "color")
                   (etaf-export--remap-fg-light raw "#ffffff" canvas-hex))
                  ((string= prop "stroke")
                   (if (< (etaf-export--color-luma raw) 0.25)
                       (etaf-export--remap-border-light raw canvas-hex)
                     (etaf-export--remap-fg-light raw "#ffffff" canvas-hex)))
                  ;; fill: dark neutral/tinted boxes become light paper; bright white text becomes dark ink
                  ((> (etaf-export--color-luma raw) 0.65)
                   (etaf-export--remap-fg-light raw "#ffffff" canvas-hex))
                  ((< (etaf-export--color-luma raw) 0.22)
                   (etaf-export--remap-bg-light raw canvas-hex))
                  (t raw))))
           (concat prop sep (or mapped raw))))
       svg-text t t))))

;;;; Face & Display Property Extraction

(defun etaf-export--canvas-colors (buffer)
  "Return (BG FG) hex strings for BUFFER's effective default canvas."
  (with-current-buffer buffer
    (let* ((win (get-buffer-window buffer t))
           (frame (and win (window-frame win)))
           (remap (alist-get 'default face-remapping-alist))
           (remap-bg nil)
           (remap-fg nil))
      (when remap
        (dolist (spec (if (and (listp remap) (keywordp (car remap)))
                          (list remap)
                        remap))
          (when (and (listp spec) (keywordp (car spec)))
            (unless remap-bg
              (setq remap-bg (etaf-export--color-hex (plist-get spec :background))))
            (unless remap-fg
              (setq remap-fg (etaf-export--color-hex (plist-get spec :foreground)))))))
      (let* ((def-bg (or remap-bg
                         (etaf-export--color-hex (face-attribute 'default :background frame t))
                         "#ffffff"))
             (def-fg (or remap-fg
                         (etaf-export--color-hex (face-attribute 'default :foreground frame t))
                         (if (etaf-export--dark-p def-bg) "#e6edf3" "#1f2328"))))
        (list def-bg def-fg)))))

(defun etaf-export--font-metrics (runtime buffer &optional font-override)
  "Return cell and font metrics plist for RUNTIME and BUFFER.
Optional FONT-OVERRIDE replaces the inherited font stack."
  (with-current-buffer buffer
    (let* ((win (get-buffer-window buffer t))
           (frame (and win (window-frame win)))
           (graphic (and frame (display-graphic-p frame)))
           (dm (ignore-errors (etaf-display-metrics runtime)))
           (dm-cw (and dm (plist-get dm :char-width)))
           (dm-lh (and dm (plist-get dm :line-height)))
           (dm-asc (and dm (plist-get dm :ascent)))
           (pixel-metrics (and (numberp dm-cw) (> dm-cw 2)
                               (numberp dm-lh) (> dm-lh 4)))
           (cw (if pixel-metrics (float dm-cw) 8.0))
           (lh (if pixel-metrics (float dm-lh) 18.0))
           (px-scale (if pixel-metrics
                         1.0
                       (/ cw (float (max 1 (or dm-cw 1))))))
           (base-h (let ((h (face-attribute 'default :height frame t)))
                     (if (and (integerp h) (> h 0)) h 120)))
           ;; Match Emacs's real logical font height (base-h / 10 on macOS NS,
           ;; or ~0.78..0.88 of line-height on 96dpi displays) so CJK/Latin run
           ;; widths stay aligned with Emacs cells without artificial shrinking.
           (font-size (if pixel-metrics
                          (min (* lh 0.88)
                               (max (* lh 0.78)
                                    (if (>= base-h 60)
                                        (/ (float base-h) 10.0)
                                      (* lh 0.82))))
                        14.0))
           (ascent (if (and pixel-metrics (numberp dm-asc) (> dm-asc 0))
                       (* lh (/ (float (min 95 (max 60 dm-asc))) 100.0))
                     (* lh 0.76)))
           (frame-fam (and graphic (face-attribute 'default :family frame t)))
           (family (cond
                    ((and (stringp font-override) (not (string-empty-p font-override)))
                     font-override)
                    ((and (stringp frame-fam)
                          (not (string-empty-p frame-fam))
                          (not (string= frame-fam "default")))
                     (concat frame-fam ", " etaf-export--default-font-stack))
                    (t etaf-export--default-font-stack))))
      (list :cw cw
            :lh lh
            :px-scale px-scale
            :font-size font-size
            :ascent ascent
            :base-height base-h
            :font-family family))))

(defun etaf-export--flatten-face (face-spec)
  "Flatten FACE-SPEC into an ordered list of face attribute plists."
  (cond
   ((null face-spec) nil)
   ((symbolp face-spec)
    (when (facep face-spec)
      (let ((attrs nil)
            (inh (face-attribute face-spec :inherit nil nil)))
        (dolist (k '(:foreground :background :weight :slant :height
                                 :underline :overline :strike-through
                                 :box :extend :family))
          (let ((v (face-attribute face-spec k nil nil)))
            (unless (eq v 'unspecified)
              (setq attrs (plist-put attrs k v)))))
        (append (and attrs (list attrs))
                (when (and inh (not (eq inh 'unspecified)))
                  (etaf-export--flatten-face inh))))))
   ((and (consp face-spec) (keywordp (car face-spec)))
    (let ((inh (plist-get face-spec :inherit)))
      (append (list face-spec)
              (when (and inh (not (eq inh 'unspecified)))
                (etaf-export--flatten-face inh)))))
   ((listp face-spec)
    (cl-mapcan #'etaf-export--flatten-face face-spec))
   (t nil)))

(defun etaf-export--resolve-face (face-spec canvas-bg canvas-fg base-height)
  "Resolve FACE-SPEC into a normalized style plist against CANVAS-BG / CANVAS-FG."
  (let ((fg nil) (bg nil) (weight nil) (slant nil) (scale 1.0) (height-seen nil)
        (underline nil) (overline nil) (strike nil) (box nil) (extend nil)
        (family nil))
    (dolist (pl (etaf-export--flatten-face face-spec))
      (when (and (null fg) (plist-member pl :foreground))
        (setq fg (etaf-export--color-hex (plist-get pl :foreground))))
      (when (and (null bg) (plist-member pl :background))
        (setq bg (etaf-export--color-hex (plist-get pl :background))))
      (when (and (null weight) (plist-member pl :weight))
        (let ((w (plist-get pl :weight)))
          (unless (eq w 'unspecified) (setq weight w))))
      (when (and (null slant) (plist-member pl :slant))
        (let ((s (plist-get pl :slant)))
          (unless (eq s 'unspecified) (setq slant s))))
      (when (and (not height-seen) (plist-member pl :height))
        (let ((h (plist-get pl :height)))
          (cond
           ((integerp h)
            (setq scale (/ (float h) (float (max 60 base-height)))
                  height-seen t))
           ((floatp h)
            (setq scale h height-seen t)))))
      (when (and (null underline) (plist-member pl :underline))
        (let ((u (plist-get pl :underline)))
          (unless (or (null u) (eq u 'unspecified)) (setq underline u))))
      (when (and (null overline) (plist-member pl :overline))
        (let ((o (plist-get pl :overline)))
          (unless (or (null o) (eq o 'unspecified)) (setq overline o))))
      (when (and (null strike) (plist-member pl :strike-through))
        (let ((st (plist-get pl :strike-through)))
          (unless (or (null st) (eq st 'unspecified)) (setq strike st))))
      (when (and (null box) (plist-member pl :box))
        (let ((bx (plist-get pl :box)))
          (unless (or (null bx) (eq bx 'unspecified)) (setq box bx))))
      (when (and (null extend) (plist-get pl :extend))
        (setq extend t))
      (when (and (null family) (stringp (plist-get pl :family)))
        (setq family (plist-get pl :family))))
    (let* ((eff-fg (or fg canvas-fg))
           (eff-bg (or bg canvas-bg))
           (ul-color (cond
                      ((eq underline t) eff-fg)
                      ((stringp underline) (or (etaf-export--color-hex underline) eff-fg))
                      ((consp underline)
                       (let ((c (plist-get underline :color)))
                         (if (or (null c) (eq c 'foreground-color))
                             eff-fg
                           (or (etaf-export--color-hex c) eff-fg))))
                      (t nil)))
           (ul-style (if (and (consp underline) (eq (plist-get underline :style) 'wave))
                         'wave 'line))
           (ol-color (cond
                      ((eq overline t) eff-fg)
                      ((stringp overline) (or (etaf-export--color-hex overline) eff-fg))
                      ((consp overline)
                       (or (etaf-export--color-hex (plist-get overline :color)) eff-fg))
                      (t nil)))
           (st-color (cond
                      ((eq strike t) eff-fg)
                      ((stringp strike) (or (etaf-export--color-hex strike) eff-fg))
                      ((consp strike)
                       (or (etaf-export--color-hex (plist-get strike :color)) eff-fg))
                      (t nil)))
           (box-color (cond
                       ((eq box t) eff-fg)
                       ((stringp box) (or (etaf-export--color-hex box) eff-fg))
                       ((consp box)
                        (or (etaf-export--color-hex (plist-get box :color)) eff-fg))
                       (t nil)))
           (box-lw (cond
                    ((and (consp box) (integerp (plist-get box :line-width)))
                     (abs (plist-get box :line-width)))
                    ((and (consp box) (consp (plist-get box :line-width)))
                     (abs (car (plist-get box :line-width))))
                    (box-color 1)
                    (t 0))))
      (list :fg eff-fg
            :bg eff-bg
            :explicit-bg (and bg (not (equal bg canvas-bg)))
            :bold (memq weight '(bold extra-bold ultra-bold semi-bold demibold))
            :italic (memq slant '(italic oblique reverse-italic reverse-oblique))
            :scale (max 0.5 (min 4.0 scale))
            :underline ul-color
            :underline-style ul-style
            :overline ol-color
            :strike st-color
            :box box-color
            :box-width box-lw
            :extend extend
            :family family))))

(defun etaf-export--apply-theme-to-style (style theme orig-canvas-bg)
  "Apply THEME (`current' or `light') to STYLE derived from ORIG-CANVAS-BG."
  (if (or (not (eq theme 'light)) (not (etaf-export--dark-p orig-canvas-bg)))
      style
    (let* ((copy (copy-sequence style))
           (bg (etaf-export--remap-bg-light (plist-get style :bg) orig-canvas-bg))
           (fg (etaf-export--remap-fg-light (plist-get style :fg) bg orig-canvas-bg))
           (ul (when-let* ((u (plist-get style :underline)))
                 (if (equal u (plist-get style :fg))
                     fg
                   (etaf-export--remap-border-light u orig-canvas-bg))))
           (ol (when-let* ((o (plist-get style :overline)))
                 (etaf-export--remap-border-light o orig-canvas-bg)))
           (st (when-let* ((s (plist-get style :strike)))
                 (etaf-export--remap-fg-light s bg orig-canvas-bg)))
           (bx (when-let* ((b (plist-get style :box)))
                 (etaf-export--remap-border-light b orig-canvas-bg))))
      (plist-put copy :bg bg)
      (plist-put copy :fg fg)
      (plist-put copy :underline ul)
      (plist-put copy :overline ol)
      (plist-put copy :strike st)
      (plist-put copy :box bx)
      copy)))

(defun etaf-export--parse-display (display)
  "Parse Emacs text `display' property DISPLAY into a structured plist, or nil."
  (cond
   ((null display) nil)
   ((stringp display) (list :kind 'string :text display))
   ((eq (car-safe display) 'space)
    (let ((w (plist-get (cdr display) :width))
          (a (plist-get (cdr display) :align-to)))
      (cond
       ((and (consp w) (numberp (car w)))
        (list :kind 'space :px (float (car w))))
       ((numberp w)
        (list :kind 'space :cols (float w)))
       (a (list :kind 'align-to :spec a))
       (t (list :kind 'space :cols 1.0)))))
   ((eq (car-safe display) 'raise)
    (list :kind 'raise :factor (if (numberp (cadr display)) (float (cadr display)) 0.0)))
   ((eq (car-safe display) 'image)
    (let ((props (cdr display)))
      (list :kind 'image
            :descriptor display
            :type (plist-get props :type)
            :data (plist-get props :data)
            :file (plist-get props :file)
            :img-w (plist-get props :width)
            :img-h (plist-get props :height)
            :slice nil
            :raise nil)))
   ((and (consp display) (listp (car display)))
    (let ((img nil) (slice nil) (raise nil))
      (dolist (item display)
        (pcase (car-safe item)
          ('image (setq img item))
          ('slice (setq slice (cdr item)))
          ('raise (when (numberp (cadr item))
                    (setq raise (float (cadr item)))))))
      (cond
       (img
        (let ((props (cdr img)))
          (list :kind 'image
                :descriptor img
                :type (plist-get props :type)
                :data (plist-get props :data)
                :file (plist-get props :file)
                :img-w (plist-get props :width)
                :img-h (plist-get props :height)
                :slice slice
                :raise raise)))
       (raise (list :kind 'raise :factor raise))
       (t nil))))
   (t nil)))

(defun etaf-export--image-bytes (spec)
  "Return raw bytes string and normalized type symbol for image SPEC, or nil."
  (let* ((type (plist-get spec :type))
         (data (plist-get spec :data))
         (file (plist-get spec :file))
         (bytes (cond
                 ((stringp data) data)
                 ((and (stringp file) (file-readable-p file))
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file)
                    (buffer-string)))
                 (t nil)))
         (eff-type (or type
                       (and (stringp file)
                            (let ((ext (downcase (or (file-name-extension file) ""))))
                              (pcase ext
                                ("svg" 'svg)
                                ("png" 'png)
                                ((or "jpg" "jpeg") 'jpeg)
                                ("gif" 'gif)
                                ("webp" 'webp)
                                (_ nil)))))))
    (when (and bytes (not (string-empty-p bytes)))
      (when (and (null eff-type) (string-match-p "<svg\\b" (substring bytes 0 (min 512 (length bytes)))))
        (setq eff-type 'svg))
      (cons (or eff-type 'png) bytes))))

;;;; Snapshot Construction & Multi-Row Image Stitching

(defun etaf-export--capture-line (beg end row-idx cw lh px-scale base-height orig-bg orig-fg theme)
  "Capture one rendered buffer line [BEG, END) at ROW-IDX."
  (let ((pos beg)
        (x 0.0)
        (runs nil)
        (max-scale 1.0)
        (max-img-h 0.0)
        (has-ink nil)
        (line-extend nil))
    (while (< pos end)
      (let* ((next (min end (or (next-property-change pos nil end) end)))
             (face-prop (get-text-property pos 'face))
             (disp-prop (get-text-property pos 'display))
             (raw-style (etaf-export--resolve-face face-prop orig-bg orig-fg base-height))
             (style (etaf-export--apply-theme-to-style raw-style theme orig-bg))
             (disp (etaf-export--parse-display disp-prop)))
        (when (plist-get style :extend)
          (setq line-extend style))
        (pcase (plist-get disp :kind)
          ('space
           (let ((w (if-let* ((px (plist-get disp :px)))
                        (* px px-scale)
                      (* (or (plist-get disp :cols) 1.0) cw))))
             (when (or (plist-get style :explicit-bg)
                       (plist-get style :overline)
                       (plist-get style :underline)
                       (plist-get style :box))
               (setq has-ink t))
             (push (list :kind 'space :x x :w w :style style) runs)
             (setq x (+ x w))))
          ('align-to
           (let* ((spec (plist-get disp :spec))
                  (target (cond
                           ((and (consp spec) (numberp (car spec))) (* (float (car spec)) px-scale))
                           ((numberp spec) (* (float spec) cw))
                           (t x)))
                  (w (max 0.0 (- target x))))
             (when (> w 0.0)
               (push (list :kind 'space :x x :w w :style style) runs)
               (setq x (+ x w)))))
          ('image
           (let* ((slice (plist-get disp :slice))
                  (sw (float (or (and slice (nth 2 slice))
                                 (plist-get disp :img-w)
                                 cw)))
                  (sh (float (or (and slice (nth 3 slice))
                                 (plist-get disp :img-h)
                                 lh))))
             (setq has-ink t
                   max-img-h (max max-img-h sh))
             (push (list :kind 'image
                         :x x :w sw :h sh
                         :row row-idx
                         :style style
                         :display disp)
                   runs)
             (setq x (+ x sw))))
          (_
           (let* ((text (if (eq (plist-get disp :kind) 'string)
                            (plist-get disp :text)
                          (buffer-substring-no-properties pos next)))
                  (raise (if (eq (plist-get disp :kind) 'raise)
                             (plist-get disp :factor)
                           0.0))
                  (sc (plist-get style :scale))
                  (w (* (float (string-width text)) cw sc)))
             (setq max-scale (max max-scale sc))
             (when (or (string-match-p "[^ \t]" text)
                       (plist-get style :explicit-bg)
                       (plist-get style :overline)
                       (plist-get style :underline)
                       (plist-get style :strike)
                       (plist-get style :box))
               (setq has-ink t))
             (push (list :kind 'text
                         :x x :w w
                         :text text
                         :raise raise
                         :style style)
                   runs)
             (setq x (+ x w)))))
        (setq pos next)))
    ;; Check trailing newline extend face (Ebox puts :extend t on the line break)
    (when (< end (point-max))
      (let* ((nl-face (get-text-property end 'face))
             (raw (and nl-face (etaf-export--resolve-face nl-face orig-bg orig-fg base-height))))
        (when (and raw (plist-get raw :extend))
          (setq line-extend (etaf-export--apply-theme-to-style raw theme orig-bg)))))
    (let ((row-h (max lh
                      max-img-h
                      (if (> max-scale 1.05)
                          (float (ceiling (* lh (min max-scale 2.8) 0.90)))
                        lh))))
      (list :index row-idx
            :y 0.0
            :height row-h
            :width x
            :max-scale max-scale
            :has-ink has-ink
            :extend line-extend
            :runs (nreverse runs)))))

(defun etaf-export--stitch-images (lines)
  "Stitch consecutive vertical slices sharing one image descriptor across LINES.
Marks stitched slice runs with `:stitched t' and returns list of unified image
block plists."
  (let ((active nil) ; list of (DESCRIPTOR . RECORD)
        (finished nil)
        (next-id 0))
    (dolist (line lines)
      (let ((row-idx (plist-get line :index))
            (row-y (plist-get line :y))
            (row-h (plist-get line :height))
            (seen-this-row nil))
        (dolist (run (plist-get line :runs))
          (when (eq (plist-get run :kind) 'image)
            (let* ((disp (plist-get run :display))
                   (desc (plist-get disp :descriptor))
                   (slice (plist-get disp :slice))
                   (sx (float (or (nth 0 slice) 0.0)))
                   (sy (float (or (nth 1 slice) 0.0)))
                   (sw (plist-get run :w))
                   (sh (plist-get run :h))
                   (x (plist-get run :x))
                   (match (cl-find-if
                           (lambda (entry)
                             (let ((rec (cdr entry)))
                               (and (eq (car entry) desc)
                                    (= (plist-get rec :last-row) (1- row-idx))
                                    (<= (abs (- (plist-get rec :x) x)) 1.5)
                                    (<= (abs (- (plist-get rec :w) sw)) 1.5)
                                    (<= (abs (- (plist-get rec :sy-end) sy)) 2.5))))
                           active)))
              (if match
                  (let ((rec (cdr match)))
                    (plist-put rec :last-row row-idx)
                    (plist-put rec :sy-end (+ sy sh))
                    (plist-put rec :y-end (+ row-y (min sh row-h)))
                    (plist-put rec :runs (cons run (plist-get rec :runs)))
                    (push match seen-this-row))
                ;; Only stitch slices that are vertical sub-slices or multi-row images
                (let* ((img-h (float (or (plist-get disp :img-h) sh)))
                       (inset-y (if (and slice (= sy 0.0) (< sh row-h))
                                    (- row-h sh)
                                  0.0))
                       (rec (list :id (cl-incf next-id)
                                  :descriptor desc
                                  :display disp
                                  :x x
                                  :y (+ row-y inset-y)
                                  :y-end (+ row-y inset-y sh)
                                  :w sw
                                  :img-h img-h
                                  :sx sx
                                  :sy-start sy
                                  :sy-end (+ sy sh)
                                  :start-row row-idx
                                  :last-row row-idx
                                  :runs (list run)))
                       (entry (cons desc rec)))
                  (push entry active)
                  (push entry seen-this-row))))))
        ;; Retire entries not continued on this row
        (let ((still nil))
          (dolist (entry active)
            (if (memq entry seen-this-row)
                (push entry still)
              (push (cdr entry) finished)))
          (setq active still))))
    (dolist (entry active)
      (push (cdr entry) finished))
    ;; Only promote records that span >1 row into stitched blocks; 1-row inline
    ;; shapes (like Ebox rounded corners) stay inline on their row.
    (let ((blocks nil))
      (dolist (rec (nreverse finished))
        (when (> (plist-get rec :last-row) (plist-get rec :start-row))
          (dolist (r (plist-get rec :runs))
            (plist-put r :stitched t))
          (let* ((y0 (plist-get rec :y))
                 (y1 (plist-get rec :y-end))
                 (disp (plist-get rec :display))
                 (bytes-pair (etaf-export--image-bytes disp)))
            (when bytes-pair
              (push (list :id (plist-get rec :id)
                          :x (plist-get rec :x)
                          :y y0
                          :w (plist-get rec :w)
                          :h (max 1.0 (- y1 y0))
                          :start-row (plist-get rec :start-row)
                          :end-row (plist-get rec :last-row)
                          :type (car bytes-pair)
                          :bytes (cdr bytes-pair))
                    blocks)))))
      (nreverse blocks))))

(defun etaf-export--content-x-bounds (lines canvas-bg)
  "Compute tight horizontal (MIN-X . MAX-X) content bounds across LINES.
Ignores empty centering gutters filled only with CANVAS-BG, and excludes
multi-row stitched images/diagrams from stretching the document column width
when non-image text/card content is present (wide diagrams scale cleanly to
fit inside the resulting column during SVG emission)."
  (let ((text-min nil)
        (text-max nil)
        (all-min nil)
        (all-max nil))
    (dolist (line lines)
      (dolist (run (plist-get line :runs))
        (let* ((kind (plist-get run :kind))
               (style (plist-get run :style))
               (x (plist-get run :x))
               (w (plist-get run :w))
               (stitched (plist-get run :stitched))
               (meaningful
                (pcase kind
                  ('image t)
                  ('text
                   (or (string-match-p "[^ \t]" (plist-get run :text))
                       (and (plist-get style :bg) (not (equal (plist-get style :bg) canvas-bg)))
                       (plist-get style :overline)
                       (plist-get style :underline)
                       (plist-get style :strike)
                       (plist-get style :box)))
                  ('space
                   (or (and (plist-get style :bg) (not (equal (plist-get style :bg) canvas-bg)))
                       (plist-get style :overline)
                       (plist-get style :underline)
                       (plist-get style :box)))
                  (_ nil))))
          (when (and meaningful (> w 0.0))
            (setq all-min (if all-min (min all-min x) x))
            (setq all-max (if all-max (max all-max (+ x w)) (+ x w)))
            (unless (and (eq kind 'image) stitched)
              (setq text-min (if text-min (min text-min x) x))
              (setq text-max (if text-max (max text-max (+ x w)) (+ x w))))))))
    (let ((min-x (or text-min all-min))
          (max-x (or text-max all-max)))
      (if (and min-x max-x (> max-x min-x))
          (cons (max 0.0 (- min-x 4.0)) (+ max-x 4.0))
        (cons 0.0 (max 320.0 (cl-loop for l in lines maximize (plist-get l :width) into m finally return (or m 320.0))))))))

(cl-defun etaf-export--snapshot-runtime (runtime &key (theme 'current) font-family)
  "Capture rendered snapshot plist from mounted RUNTIME.
THEME is `current' (keep rendered colors) or `light' (remap dark pages onto
clean white paper without touching the live buffer)."
  (let* ((buf (etaf-runtime-buffer runtime))
         (meta (etaf-runtime-meta runtime)))
    (unless (buffer-live-p buf)
      (error "ETAF runtime buffer is no longer live"))
    (pcase-let* ((`(,orig-bg ,orig-fg) (etaf-export--canvas-colors buf))
                 (eff-bg (if (eq theme 'light)
                             (etaf-export--remap-bg-light orig-bg orig-bg)
                           orig-bg))
                 (eff-fg (if (eq theme 'light)
                             (etaf-export--remap-fg-light orig-fg eff-bg orig-bg)
                           orig-fg))
                 (metrics (etaf-export--font-metrics runtime buf font-family))
                 (cw (plist-get metrics :cw))
                 (lh (plist-get metrics :lh))
                 (px-scale (plist-get metrics :px-scale))
                 (base-h (plist-get metrics :base-height))
                 (lines nil)
                 (row-idx 0))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let ((beg (line-beginning-position))
                  (end (line-end-position)))
              (push (etaf-export--capture-line beg end row-idx cw lh px-scale base-h
                                               orig-bg orig-fg theme)
                    lines)
              (setq row-idx (1+ row-idx))
              (if (= (forward-line 1) 0)
                  nil
                (goto-char (point-max)))))))
      (setq lines (nreverse lines))
      ;; Trim trailing blank canvas lines so PDF does not end with blank pages
      (while (and lines (not (plist-get (car (last lines)) :has-ink)))
        (setq lines (butlast lines)))
      ;; Compute cumulative Y coordinates
      (let ((y 0.0))
        (dolist (line lines)
          (plist-put line :y y)
          (setq y (+ y (plist-get line :height))))
        (let* ((images (etaf-export--stitch-images lines))
               (bounds (etaf-export--content-x-bounds lines eff-bg))
               (min-x (car bounds))
               (max-x (cdr bounds)))
          (list :title (or (plist-get meta :title) (buffer-name buf))
                :app (plist-get meta :app)
                :uri (plist-get meta :uri)
                :buffer-name (buffer-name buf)
                :theme theme
                :orig-bg orig-bg
                :bg eff-bg
                :fg eff-fg
                :dark-source (etaf-export--dark-p orig-bg)
                :metrics metrics
                :min-x min-x
                :max-x max-x
                :content-width (max 1.0 (- max-x min-x))
                :content-height (max lh y)
                :line-count (length lines)
                :lines lines
                :images images))))))

(provide 'etaf-export-snapshot)
;;; etaf-export-snapshot.el ends here
