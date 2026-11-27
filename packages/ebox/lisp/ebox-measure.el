;;; ebox-measure.el --- Pixel measurement for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Measures display widths of text under one face.  Plain characters are
;; measured once per font face and cached; grapheme clusters, display
;; properties and caller faces fall back to `string-pixel-width'.  The
;; measuring buffer's face remapping (including text scale) selects the cache.
;; Emacs 31 measures a string for a buffer natively; Emacs 29 and 30 copy the
;; same buffer-local display settings into a private work buffer.

;;; Code:

(require 'cl-lib)

;; The graphical branch is not entered on builds without native fonts.
(declare-function font-info "font.c" (name &optional frame))
(declare-function ebox-image--metrics "ebox-image" (frame))

(defvar ebox--measure-buffer nil
  "Buffer whose face remapping applies to measurements, or nil.")

(defvar ebox--width-tables (make-hash-table :test 'equal :weakness 'key)
  "Map of immutable metric contexts to per-face tables.")

(defvar ebox--cluster-width-cache (make-hash-table :test 'equal)
  "Width cache for multi-character clusters keyed by (FACE . STRING).")

(defvar ebox--width-epoch 0
  "Counter incremented whenever measurement caches are cleared.")

(defconst ebox--metric-locals
  '(face-remapping-alist overline-margin line-spacing
    default-text-properties char-property-alias-alist
    bidi-paragraph-direction)
  "Buffer-local settings that decide a measured string's size.")

(defvar-local ebox--metric-snapshot nil
  "Immutable snapshot of the values `ebox--metric-key' depends on.")

(defvar-local ebox--metric-context nil
  "Cached metric context key of this buffer.")

(defvar ebox--active-metric-key nil
  "Metric context key bound for one layout pass, or nil outside one.")

(defun ebox--metric-key ()
  "Return the active metric context key, or compute this buffer's key.
A layout binds one key for all its faces; the inputs cannot change until
the pass finishes."
  (or ebox--active-metric-key (ebox--compute-metric-key)))

(defun ebox--compute-metric-key ()
  "Return an immutable key for the measuring buffer's metric context.
The key covers the frame and its font, the default face height, the measurement
epoch, the face remapping, and the buffer-local settings that change a
string's size.  Emacs mutates some of these in place, so compare the live
values with a snapshot before rebuilding the key."
  (with-current-buffer (or ebox--measure-buffer (current-buffer))
    (let* ((raw-frame (window-frame (ebox--measuring-window)))
           (ws (window-system raw-frame))
           (font (and ws (frame-parameter raw-frame 'font)))
           (height (and ws (face-attribute 'default :height raw-frame)))
           ;; Child frames inheriting the parent frame's exact window system,
           ;; font and default height share its already-warm glyph width cache
           ;; instead of cold-measuring every character on every popup.
           (parent (and ws (frame-parent raw-frame)))
           (frame (if (and parent
                           (frame-live-p parent)
                           (eq (window-system parent) ws)
                           (equal (frame-parameter parent 'font) font)
                           (equal (face-attribute 'default :height parent) height))
                      parent
                    raw-frame))
           (now (list ebox--width-epoch frame font height
                      overline-margin line-spacing
                      default-text-properties char-property-alias-alist
                      face-remapping-alist)))
      (unless (equal now ebox--metric-snapshot)
        (setq ebox--metric-snapshot (copy-tree now)
              ebox--metric-context
              (list ebox--width-epoch frame font height
                    overline-margin line-spacing
                    (copy-tree default-text-properties)
                    (copy-tree char-property-alias-alist)
                    (delq nil
                          (mapcar (lambda (entry)
                                    (let ((metric (ebox--metric-face (cdr entry))))
                                      (unless (equal metric (car entry))
                                        (cons (car entry) metric))))
                                  (copy-tree face-remapping-alist))))))
      ebox--metric-context)))

(defvar-local ebox--display-metrics-cache nil
  "Last font context and effective default-face metrics for this buffer.")

(defvar ebox--active-metrics nil
  "Effective default-face metrics bound for one layout pass.")

(defvar ebox--measure-frame nil
  "Explicit frame for an image preparation, or nil for the buffer's display.")

(defun ebox--measuring-window ()
  "Return the window whose frame decides display metrics.
Use an explicitly bound measuring frame, then a window showing the current
buffer, then the selected window."
  (if ebox--measure-frame
      (frame-selected-window ebox--measure-frame)
    (or (get-buffer-window (current-buffer) t) (selected-window))))

(defun ebox--text-display-p ()
  "Return non-nil when layout targets character cells, not graphical pixels.
Read the frame of the window the current buffer is displayed in, or the
selected window when it is hidden.  Terminals cannot render font metrics
such as a larger font size, so callers substitute an attribute they support."
  (null (window-system (window-frame (ebox--measuring-window)))))

(defun ebox-display-metrics (&optional buffer-or-name)
  "Return BUFFER-OR-NAME's effective default-face metrics as a fresh plist.
Default to the current buffer.  :char-width and :line-height are positive
pixel sizes; :ascent is the image ascent percentage matching the baseline.
Honor buffer-local text scaling on its displaying frame, or the selected
frame when hidden.  Text displays return unit cells and 100 percent ascent.
An unknown buffer signals `error'."
  (copy-sequence (ebox--display-metrics buffer-or-name)))

(defconst ebox--line-probes "0汉"
  "Characters whose fonts set a row's height: Latin and CJK body text.
A font that reaches further than the Latin one for text the reader reads as
prose raises the line.  Fonts for decoration and rarer scripts stay out;
their glyphs are fitted into the line instead.")

(defun ebox--line-box (face frame)
  "Return (HEIGHT . ASCENT) of the tallest of `ebox--line-probes' under FACE.
A row takes the largest ascent plus the largest descent of the glyphs in it,
so body text in a taller font sizes the line rather than shrinking its glyphs
into a line set by another script."
  (with-temp-buffer
    (let ((height 0) (ascent 0) (descent 0))
      (dolist (char (string-to-list ebox--line-probes))
        ;; A string probe inherits the window's base font.  Apply the remap
        ;; exactly once.
        (let ((info (font-info (font-at 0 nil
                                       (propertize (char-to-string char) 'face face))
                               frame)))
          (when info
            (setq height (max height (aref info 3))
                  ascent (max ascent (aref info 8))
                  descent (max descent (aref info 9))))))
      (cons (max 1 height (+ ascent descent)) ascent))))

(defun ebox--display-metrics (&optional buffer-or-name)
  "Read BUFFER-OR-NAME's cached metrics without allocating on a cache hit.
The returned plist belongs to the measuring layer and must not be changed."
  (with-current-buffer (or buffer-or-name (current-buffer))
    (let* ((ebox--measure-buffer (current-buffer))
           (window (ebox--measuring-window))
           (frame (window-frame window))
           (context (ebox--metric-key))
           (cache (car ebox--display-metrics-cache)))
      (unless (equal context cache)
        (setq ebox--display-metrics-cache
              (cons context
                    (if (not (window-system frame))
                        '(:char-width 1 :line-height 1 :ascent 100)
                      (let ((face (or (cdr (assq 'default face-remapping-alist))
                                      'default))
                            (buffer (current-buffer)))
                        (with-selected-window window
                          (let* ((box (ebox--line-box face frame))
                                 (height (car box))
                                 (ascent (cdr box)))
                            (list :char-width (max 1 (ebox--buffer-string-pixel-width
                                                      "0" buffer))
                                  :line-height height
                                  :ascent (min 100 (max 1 (ceiling (* 100.0 ascent) height)))))))))))
      (cdr ebox--display-metrics-cache))))

(defconst ebox--metric-neutral-attributes
  '(:foreground :background :distant-foreground :underline
    :strike-through :extend :stipple)
  "Face attributes that never change glyph advances or line metrics.")

(defun ebox--metric-face (face)
  "Return the face whose metrics FACE shares.
A plist naming only metric-neutral attributes measures like the default
face, and a list of faces drops such members.  `:overline' stays: it adds
`overline-margin' pixels to a row's ascent."
  (cond ((atom face) face)
        ((keywordp (car face))
         (let ((rest face))
           (while (and rest (memq (car rest) ebox--metric-neutral-attributes))
             (setq rest (cddr rest)))
           (and rest face)))
        (t (let ((kept (delq nil (mapcar #'ebox--metric-face face))))
             (if (cdr kept) kept (car kept))))))

(defun ebox--merge-face (own face)
  "Return the face list painting text face OWN over node FACE."
  (cond ((null face) own)
        ((and (consp own) (not (keywordp (car own)))) (append own (list face)))
        (t (list own face))))

(defvar ebox--face-memo (make-vector 3 nil)
  "The last [CONTEXT-KEY FACE TABLE] lookup of `ebox--face-table'.")

(defun ebox--face-table (face)
  "Return the metric table of FACE for the current measuring context.
Faces with equal metric attributes share one table: painting conses fresh
face plists, which must not re-measure every character."
  (let ((key (ebox--metric-key))
        (memo ebox--face-memo))
    (if (and (aref memo 2) (eq face (aref memo 1)) (eq key (aref memo 0)))
        (aref memo 2)
      (let* ((tables (or (gethash key ebox--width-tables)
                         (puthash key (make-hash-table :test 'equal)
                                  ebox--width-tables)))
             (table
              (or (gethash face tables)
                  (puthash face
                           (let ((metric (ebox--metric-face face)))
                             (or (gethash metric tables)
                                 (puthash metric
                                          (cons (make-vector 128 nil)
                                                (make-hash-table :test 'eq))
                                          tables)))
                           tables))))
        (aset memo 0 key)
        (aset memo 1 face)
        (aset memo 2 table)
        table))))

;; A frame Emacs has never redisplayed can crash the display engine when
;; text is measured on it (a segmentation fault in `face_for_font' under
;; `buffer-text-pixel-size'), which happens when an application opens in a
;; frame created in the same command.  Window change functions record each
;; window's width once redisplay has seen it, and Ebox always installs one
;; (`ebox--window-size-change'), so a zero `window-old-pixel-width' marks a
;; window redisplay has not reached yet.
(defvar ebox--settled-windows (make-hash-table :test 'eq :weakness 'key)
  "Windows already checked by `ebox--settle-measuring-frame'.")

(defun ebox--settle-measuring-frame ()
  "Redisplay once before measuring on a window redisplay has not seen.
Each window is checked once, so iconified or hidden frames do not cost a
redisplay per flush."
  (let ((window (selected-window)))
    (when (and (not noninteractive)
               (display-graphic-p)
               (not (gethash window ebox--settled-windows)))
      (puthash window t ebox--settled-windows)
      (when (zerop (window-old-pixel-width window))
        (redisplay t)))))

(defconst ebox--native-buffer-pixel-width
  (let ((max (cdr (func-arity 'string-pixel-width))))
    (or (eq max 'many) (>= max 2)))
  "Non-nil when `string-pixel-width' accepts a BUFFER (Emacs 31 and later).")

(defun ebox--buffer-string-pixel-width (string buffer)
  "Return the pixel width of STRING displayed in BUFFER.
BUFFER's display settings apply, as `string-pixel-width' applies them in
Emacs 31."
  (cond
   (ebox--native-buffer-pixel-width
    ;; The older byte compiler sees this unreachable Emacs 31 arity; the
    ;; capability check above selects it only where that argument exists.
    (with-suppressed-warnings ((callargs string-pixel-width))
      (string-pixel-width string buffer)))
   ((zerop (length string)) 0)
   (t
    (let ((locals (delq nil (mapcar (lambda (variable)
                                      (and (local-variable-p variable buffer)
                                           (cons variable
                                                 (buffer-local-value
                                                  variable buffer))))
                                    ebox--metric-locals))))
      (with-current-buffer (get-buffer-create " *ebox-pixel-width*")
        (dolist (variable ebox--metric-locals)
          (kill-local-variable variable))
        (pcase-dolist (`(,variable . ,value) locals)
          (set (make-local-variable variable) value))
        (setq-local display-line-numbers nil)
        (let ((inhibit-read-only t) deactivate-mark)
          (erase-buffer)
          (insert string)
          (add-text-properties (point-min) (point-max)
                               '(line-prefix "" wrap-prefix "")))
        (car (buffer-text-pixel-size nil nil t)))))))

(defun ebox--measure-raw (string)
  "Measure STRING with `string-pixel-width' in the measuring buffer."
  (ebox--buffer-string-pixel-width
   string (or ebox--measure-buffer (current-buffer))))

(defun ebox--char-width (char face)
  "Return the pixel width of CHAR displayed with FACE."
  (let* ((table (ebox--face-table face)))
    (if (< char 128)
        (let ((vector (car table)))
          (or (aref vector char)
              (aset vector char
                    (ebox--measure-raw
                     (if face (propertize (string char) 'face face)
                       (string char))))))
      (let ((hash (cdr table)))
        (or (gethash char hash)
            (puthash char
                     (if (ebox--fit-candidate-p char)
                         (ebox--fitted-width (string char) face)
                       (ebox--measure-raw
                        (if face (propertize (string char) 'face face)
                          (string char))))
                     hash))))))

(defconst ebox--width-probe (concat (number-sequence 32 126) "汉")
  "Characters whose widths identify a face's horizontal metrics.")

(defun ebox--face-widths (face)
  "Return the widths of `ebox--width-probe' under FACE, measured once."
  (let ((table (cdr (ebox--face-table face))))
    (or (gethash 'probe table)
        (puthash 'probe (mapcar (lambda (char) (ebox--char-width char face))
                                ebox--width-probe)
                 table))))

(defun ebox--same-widths-p (a b)
  "Return non-nil when faces A and B give the probe characters equal widths.
A monospaced font keeps its advance across weights, so a weight change
under it repaints without moving text."
  (or (eq a b) (equal (ebox--face-widths a) (ebox--face-widths b))))

(defsubst ebox--cjk-char-p (char)
  "Return non-nil when CHAR breaks like a CJK ideograph."
  (and (>= char #x2E80)
       (or (<= char #x303F)
           (and (>= char #x3040) (<= char #x30FF))
           (and (>= char #x3400) (<= char #x4DBF))
           (and (>= char #x4E00) (<= char #x9FFF))
           (and (>= char #xAC00) (<= char #xD7AF))
           (and (>= char #xF900) (<= char #xFAFF))
           (and (>= char #xFF00) (<= char #xFFEF))
           (and (>= char #x20000) (<= char #x2FFFF)))))

(defsubst ebox--extension-char-p (char)
  "Return non-nil when CHAR extends the previous grapheme cluster."
  (and (>= char #x300)
       (or (<= char #x36F)
           (and (>= char #x1AB0) (<= char #x1AFF))
           (and (>= char #x1DC0) (<= char #x1DFF))
           (and (>= char #x20D0) (<= char #x20FF))
           (and (>= char #xFE00) (<= char #xFE0F))
           (and (>= char #xFE20) (<= char #xFE2F))
           (and (>= char #x1F3FB) (<= char #x1F3FF))
           (and (>= char #xE0100) (<= char #xE01EF))
           (eq char #x200D))))

(defsubst ebox--regional-indicator-p (char)
  "Return non-nil when CHAR is a regional indicator."
  (and (>= char #x1F1E6) (<= char #x1F1FF)))

(defun ebox--cluster-end (string start end)
  "Return the end of the grapheme cluster at START in STRING before END."
  (let ((next (1+ start)))
    (if (and (< (aref string start) 128)
             (or (>= next end) (< (aref string next) 128)))
        next
      (when (and (< next end)
                 (ebox--regional-indicator-p (aref string start))
                 (ebox--regional-indicator-p (aref string next)))
        (setq next (1+ next)))
      (while (and (< next end)
                  (or (ebox--extension-char-p (aref string next))
                      (eq (aref string (1- next)) #x200D)))
        (setq next (1+ next)))
      next)))

(defun ebox--plain-string-p (string)
  "Return non-nil when STRING carries no text properties."
  (and (null (text-properties-at 0 string))
       (null (next-property-change 0 string))))

(defun ebox--display-free-p (string)
  "Return non-nil when no part of STRING carries a `display' property."
  (and (null (get-text-property 0 'display string))
       (null (next-single-property-change 0 'display string))))

(defun ebox--fixed-space-width (display)
  "Return the fixed pixel width of DISPLAY space spec, or nil."
  (when (and (eq (car-safe display) 'space)
             (not (plist-member (cdr display) :align-to)))
    (let ((width (plist-get (cdr display) :width)))
      (and (consp width) (numberp (car width)) (null (cdr width))
           (car width)))))

(defvar ebox--image-widths (make-hash-table :test 'eq :weakness 'key)
  "Map of image display specification to (REMAP-KEY . WIDTH).")

(defun ebox--slice-width (display start end)
  "Return the pixel width of one glyph START..END showing image slice DISPLAY.
Return nil unless DISPLAY contains a slice with pixel W and an image.
Other display modifiers, such as `raise', do not change the slice width."
  (and (= end (1+ start)) (consp (car-safe display))
       (let ((slice (if (eq (car-safe (car display)) 'slice) (car display)
                      (assq 'slice display))))
         (and slice (natnump (nth 3 slice))
              (or (eq (car-safe (cadr display)) 'image) (assq 'image display))
              (nth 3 slice)))))

(defun ebox--display-width (string start end &optional face)
  "Measure display run START..END of STRING under FACE.
Fixed spaces need no measurement, and an image keeps its width while its
specification object and the measuring context stay the same."
  (let ((display (get-text-property start 'display string)))
    (or (ebox--fixed-space-width display)
        (ebox--slice-width display start end)
        (if (eq (car-safe display) 'image)
            (let ((key (ebox--metric-key))
                  (cached (gethash display ebox--image-widths)))
              (if (and cached (eq (car cached) key))
                  (cdr cached)
                (cdr (puthash display
                              (cons key (ebox--measure-raw
                                         (substring string start end)))
                              ebox--image-widths))))
          (ebox--segment-width string start end face)))))

(defun ebox--segment-width (string start end face)
  "Measure STRING from START to END under FACE, honoring its properties."
  (let ((segment (substring string start end)))
    (when face
      (add-face-text-property 0 (length segment) face t segment))
    (ebox--measure-raw segment)))

;;;; Line-fitting glyphs
;; Fallback fonts for emoji, symbols and rarer scripts can reach above or
;; below the default line, so one such glyph grows its whole row and opens
;; gaps between the slices of images beside it.  A character is a candidate
;; when its font's ascent or descent exceeds the default font's, judged
;; once per character; a candidate cluster taller than its face's line is
;; fitted by the largest font scale that keeps the line height.  `raise'
;; cannot help: it only adds ascent or descent.  SVG text is not an option:
;; librsvg's Pango backend aborts Emacs on some emoji, and draws others
;; without color.  A color emoji font's line is far taller than its
;; glyphs, so scaling shrinks emoji well below the text; on macOS such
;; clusters are instead drawn as line-high images that the native helper
;; renders once into a disk cache.  Measurement and painting share the
;; fitted form.

(defsubst ebox--fit-range-p (char)
  "Return non-nil when CHAR lies in a range of emoji and symbol fonts.
Emoji sequences take their font from later characters, so the font of
these characters alone does not decide."
  (and (>= char #x2000)
       (or (<= char #x2BFF)
           (memq char '(#x3030 #x303D #x3297 #x3299 #xFE0F))
           (and (>= char #x1F000) (<= char #x1FAFF)))))

(defvar ebox--tall-chars (make-char-table 'ebox-tall-chars)
  "Whether each character's font exceeds the default font: t or `no'.")

(defvar ebox--default-font-box nil
  "The default font's (ASCENT . DESCENT) in pixels, or nil before use.")

(defvar ebox--default-font-family nil
  "The default font's family string, or nil before use.")

(defun ebox--font-box (font)
  "Return FONT's (ASCENT . DESCENT) in pixels."
  (let ((info (query-font font)))
    (cons (aref info 4) (aref info 5))))

(defun ebox--tall-char-p (char)
  "Return non-nil when CHAR exceeds the default line or uses a fallback font.
Only graphical frames have fonts; elsewhere every row is one text line."
  (let ((known (aref ebox--tall-chars char)))
    (cond (known (eq known t))
          ((or noninteractive (not (display-graphic-p))) nil)
          (t
           (let* ((base-font (car-safe (internal-char-font nil ?0)))
                  (base (or ebox--default-font-box
                            (and base-font
                                 (setq ebox--default-font-box
                                       (ebox--font-box base-font)))))
                  (base-family
                   (or ebox--default-font-family
                       (and base-font
                            (setq ebox--default-font-family
                                  (let ((f (font-get base-font :family)))
                                    (and f (format "%s" f)))))))
                  (font (car-safe (internal-char-font nil char)))
                  (box (and font (ebox--font-box font)))
                  (tall (and base box (or (> (car box) (car base))
                                          (> (cdr box) (cdr base)))))
                  (foreign (and font base-family
                                (not (ebox--cjk-char-p char))
                                (not (equal (let ((f (font-get font :family)))
                                              (and f (format "%s" f)))
                                            base-family))))
                  (candidate (and (or tall foreign) t)))
             (aset ebox--tall-chars char (if candidate t 'no))
             candidate)))))

(defsubst ebox--fit-candidate-p (char)
  "Return non-nil when CHAR may need fitting into the line."
  (and (>= char #x80)
       (or (ebox--fit-range-p char) (ebox--tall-char-p char))))

(defun ebox--next-fit-candidate (string start)
  "Return the index of the first fitting candidate in STRING from START."
  (let (found)
    (while (and (not found) start
                (setq start (string-match-p "[^\0-\177]" string start)))
      (if (ebox--fit-candidate-p (aref string start))
          (setq found start)
        (setq start (1+ start))))
    found))

(defun ebox--fit-candidate-string-p (string)
  "Return non-nil when STRING contains a character that may need fitting."
  (and (multibyte-string-p string)
       (ebox--next-fit-candidate string 0)))

(defvar ebox--fit-scales
  '(0.9 0.85 0.8 0.75 0.7 0.65 0.6 0.55 0.5 0.45 0.4 0.35 0.3)
  "Font scales tried, largest first, to fit a glyph taller than its line.
A glyph that no scale fits takes the last.")

(defun ebox--measure-raw-size (string)
  "Return STRING's (WIDTH . HEIGHT) in pixels in the measuring context.
Copy the display settings of the buffer the string will be shown in.  The
line-number column and line and wrap prefixes are Ebox's own display, so a
mounted canvas owns them and the work buffer leaves them out."
  (let ((source (or ebox--measure-buffer (current-buffer))))
    (with-temp-buffer
      (dolist (variable ebox--metric-locals)
        (set (make-local-variable variable)
             (buffer-local-value variable source)))
      (setq-local display-line-numbers nil
                  line-prefix ""
                  wrap-prefix ""
                  truncate-lines t)
      (insert string)
      (buffer-text-pixel-size nil nil t))))

(defvar ebox--default-height-cache nil
  "Cons of a metric key and the default face height in 1/10 pt.")

(defun ebox--default-height ()
  "Return the default face's height in 1/10 pt on the measuring frame.
Every size in Ebox is expressed against this number, so a reader who
changes the default font scales the whole interface with it."
  (let ((context (ebox--metric-key)))
    (if (equal context (car ebox--default-height-cache))
        (cdr ebox--default-height-cache)
      (let* ((window (ebox--measuring-window))
             (frame (window-frame window))
             (height (if (window-system frame)
                         (with-selected-window window
                           (face-attribute 'default :height frame))
                       ;; No window system: the default face still declares
                       ;; 12 pt, and every Ebox size is in the same 1/10 pt
                       ;; unit, so a ratio must render identically in batch and
                       ;; in a frame instead of shrinking tenfold.
                       120)))
        (when (floatp height)
          (setq height (round (* 100 height))))
        (setq height (if (and (integerp height) (> height 0)) height 120))
        (setq ebox--default-height-cache (cons context height))
        height))))

(defun ebox--font-height (ratio)
  "Return the absolute face height in 1/10 pt for RATIO of the body size.
A style declares a ratio, so 1.42 means one and a half times the reader's
body text, whatever its point size and the screen resolution."
  (max 10 (round (* (ebox--default-height) (float ratio)))))

(defun ebox--face-size (face)
  "Return FACE's height in 1/10 pt, composing FACE the way Emacs does.
A float `:height' scales the height accumulated before it, an integer sets
it, and a face that names neither keeps the default height."
  (let ((height (ebox--default-height))
        (items (if (and (consp face) (not (keywordp (car face)))) face (list face))))
    (dolist (item items)
      (when (and (consp item) (keywordp (car item)))
        (let ((own (plist-get item :height)))
          (cond ((integerp own) (setq height own))
                ((floatp own) (setq height (round (* height own))))))))
    (max 10 height)))

(defun ebox--fit-spec (face scale)
  "Return the display spec painting FACE's glyph at SCALE of its height.
A `height' display spec is a factor of the default face, so the factor has
to carry the face's own size.  A bare factor would drop a heading to the
body size instead of shrinking it from where it was."
  (list 'height (/ (* (float (ebox--face-size face)) scale)
                   (max 1 (ebox--default-height)))))

(defun ebox--face-text-height (face)
  "Return the pixel height of ordinary Latin text under FACE.
This is the shortest a row of FACE's text can be, so the row strut uses it
to decide whether a row needs holding at the line height."
  (let ((hash (cdr (ebox--face-table face))))
    (or (gethash 'text-height hash)
        (puthash 'text-height
                 (cdr (ebox--measure-raw-size
                       (if face (propertize "0" 'face face) "0")))
                 hash))))

(defun ebox--face-body-height (face)
  "Return the pixel height of FACE's body text, Latin and CJK.
The probe covers the same scripts the default face's line box uses.  A face
that makes text larger therefore keeps its Chinese as tall as its Latin
instead of reading the CJK font as an overflowing fallback glyph."
  (let ((hash (cdr (ebox--face-table face))))
    (or (gethash 'body-height hash)
        (puthash 'body-height
                 (cdr (ebox--measure-raw-size
                       (if face
                           (propertize ebox--line-probes 'face face)
                         ebox--line-probes)))
                 hash))))

(defun ebox--face-line-height (face)
  "Return the pixel height of a line of ordinary text under FACE."
  (let ((hash (cdr (ebox--face-table face))))
    (or (gethash 'line-height hash)
        (puthash 'line-height
                 (max (plist-get (or ebox--active-metrics
                                    (ebox--display-metrics ebox--measure-buffer)) :line-height)
                      (ebox--face-body-height face))
                 hash))))

(defvar ebox--row-strut-cache nil
  "Cons of a row-metric key and the row strut built from it.")

(defvar ebox--active-row-strut 'unset
  "When not `unset', the precomputed row strut for the current flush/render.")

(defun ebox--row-strut ()
  "Return the shared string that fills a published row to one line height.
Its zero-width space is exactly the line high and places the baseline where
images align, so a row holding only shorter glyphs still measures one line.
It starts the row, inside the visible area, so the truncation boundary
cannot drop it.  Return nil when ordinary text already reaches the line."
  (if (not (eq ebox--active-row-strut 'unset))
      ebox--active-row-strut
    (let* ((metrics (or ebox--active-metrics
                        (ebox--display-metrics ebox--measure-buffer)))
           (line (plist-get metrics :line-height))
           (ascent (plist-get metrics :ascent))
           (text (ebox--face-text-height nil))
           (key (list line ascent text ebox--width-epoch)))
      (unless (equal key (car ebox--row-strut-cache))
        (setq ebox--row-strut-cache
              (cons key (and (> line text)
                             (propertize "\u200b"
                                         'display (list 'space :width '(0)
                                                        :height (list line)
                                                        :ascent ascent))))))
      (cdr ebox--row-strut-cache))))

(defvar ebox--family-faces (make-hash-table :test 'equal)
  "Interned (:family NAME) face plists keyed by font family string.")

(defun ebox--family-face (family)
  "Return the shared (:family FAMILY) face plist for FAMILY."
  (or (gethash family ebox--family-faces)
      (puthash family (list :family family) ebox--family-faces)))

(defun ebox--font-family-name (string)
  "Return the font family string Emacs resolves for STRING's first character."
  (let* ((buffer (or ebox--measure-buffer (current-buffer)))
         (window (with-current-buffer buffer (ebox--measuring-window)))
         (font (with-current-buffer buffer (font-at 0 window string)))
         (family (and font (font-get font :family))))
    (and family (format "%s" family))))

(defun ebox--base-font-family (face)
  "Return the font family string of ordinary Latin text under FACE, or nil."
  (let* ((hash (cdr (ebox--face-table face)))
         (cached (gethash 'base-family hash)))
    (if cached
        (and (stringp cached) cached)
      (let ((name (ebox--font-family-name
                   (if face (propertize "0" 'face face) "0"))))
        (puthash 'base-family (or name 'none) hash)
        name))))

(defun ebox--foreign-family (cluster face)
  "Return CLUSTER's resolved font family when it differs from FACE's base font."
  (let ((name (ebox--font-family-name
               (if face (propertize cluster 'face face) cluster))))
    (and name (not (equal name (ebox--base-font-family face))) name)))

(defun ebox--fit-row-height (cluster face scale &optional glyph-face)
  "Return the height of a row holding CLUSTER at SCALE beside text under FACE.
When GLYPH-FACE is non-nil, paint CLUSTER with it while the body probe keeps
FACE."
  (let ((glyph (propertize cluster 'face (or glyph-face face))))
    (when scale
      (put-text-property 0 (length glyph) 'display (ebox--fit-spec face scale) glyph))
    (cdr (ebox--measure-raw-size
          (concat (propertize ebox--line-probes 'face face) glyph)))))

(defconst ebox--emoji-source
  (expand-file-name "../native/emoji/emoji-render.swift"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Source of the macOS helper that renders color emoji images.")

(defvar ebox--emoji-directory (locate-user-emacs-file "ebox-emoji/")
  "Directory holding the compiled emoji helper and its rendered images.")

(defvar ebox--emoji-program nil
  "The emoji helper executable, `off' when unavailable, or nil before use.")

(defvar ebox--emoji-process nil
  "The running emoji helper process, or nil.")

(defun ebox--emoji-program ()
  "Return the compiled emoji helper, building it once, or nil."
  (unless ebox--emoji-program
    (setq ebox--emoji-program
          (or (and (eq window-system 'ns)
                   (file-readable-p ebox--emoji-source)
                   (executable-find "swiftc")
                   (let ((program (expand-file-name
                                   (format "emoji-render-%s"
                                           (substring (with-temp-buffer
                                                        (insert-file-contents-literally
                                                         ebox--emoji-source)
                                                        (secure-hash 'sha1 (current-buffer)))
                                                      0 12))
                                   ebox--emoji-directory)))
                     (make-directory ebox--emoji-directory t)
                     (unless (file-executable-p program)
                       ;; Images from an older helper may be drawn differently.
                       (dolist (file (directory-files ebox--emoji-directory t
                                                      "\\`emoji-render-\\|\\.png\\'"))
                         (delete-file file))
                       (call-process "swiftc" nil nil nil "-O"
                                     ebox--emoji-source "-o" program))
                     (and (file-executable-p program) program)))
              'off)))
  (and (stringp ebox--emoji-program) ebox--emoji-program))

(defun ebox--emoji-render (size name text)
  "Render TEXT as SIZE-pixel image NAME through the helper; return success."
  (when-let* ((program (ebox--emoji-program)))
    (unless (process-live-p ebox--emoji-process)
      (setq ebox--emoji-process
            (make-process :name "ebox-emoji" :noquery t :connection-type 'pipe
                          :coding 'utf-8-unix
                          :buffer (generate-new-buffer " *ebox-emoji*")
                          :command (list program (expand-file-name
                                                  ebox--emoji-directory)))))
    (let ((process ebox--emoji-process))
      (with-current-buffer (process-buffer process)
        (erase-buffer)
        (process-send-string process (format "%d\t%s\t%s\n" size name text))
        (while (and (not (progn (goto-char (point-min)) (search-forward "\n" nil t)))
                    (accept-process-output process 2)))
        (string= (buffer-substring (point-min) (max (point-min) (1- (point))))
                 name)))))

(defun ebox--emoji-p (cluster)
  "Return non-nil when CLUSTER is drawn with a color emoji font."
  (cl-some (lambda (char)
             (or (= char #xFE0F) (and (>= char #x1F000) (<= char #x1FAFF))
                 (let ((font (car-safe (internal-char-font nil char))))
                   (and font (string-match-p "Emoji" (format "%s" (font-get font :family)))))))
           cluster))

(defun ebox--emoji-image (cluster height)
  "Return a HEIGHT-pixel square image of emoji CLUSTER, or nil."
  (when (and (ebox--emoji-p cluster) (image-type-available-p 'png))
    (let* ((size (* 2 height))
           (name (format "%s-%d" (mapconcat (lambda (c) (format "%x" c)) cluster "-")
                         size))
           (file (expand-file-name (concat name ".png") ebox--emoji-directory))
           (ascent (nth 2 (ebox-image--metrics nil))))
      (when (and ascent (or (file-exists-p file) (ebox--emoji-render size name cluster)))
        (create-image file 'png nil :width height :height height
                      :ascent ascent :margin 0)))))

(defun ebox--fit (cluster face)
  "Return nil when CLUSTER needs no paint override, else (WIDTH DISPLAY . FAMILY).
DISPLAY, painted over CLUSTER, is a line-high emoji image, a `height' display
specification, or nil when only FAMILY must be pinned.  FAMILY is the foreign
font family string resolved during measurement so differently colored realized
faces paint the exact same fallback font."
  (if (or noninteractive (not (display-graphic-p)))
      nil
    (let* ((hash (cdr (ebox--face-table face)))
           (fits (or (gethash 'fit hash)
                     (puthash 'fit (make-hash-table :test 'equal) hash)))
           (cached (gethash cluster fits)))
      (if cached
          (and (consp cached) cached)
        ;; A row's height is its largest ascent plus its largest descent, so
        ;; each candidate is measured beside an ordinary character.  Emacs
        ;; caches discovered fallback fonts per realized face (which includes
        ;; foreground/background), so pin any foreign fallback family resolved
        ;; here onto painted glyphs to keep layout and paint widths identical.
        (let* ((line (ebox--face-line-height face))
               (cjk (ebox--cjk-char-p (aref cluster 0)))
               (family (unless cjk (ebox--foreign-family cluster face)))
               (glyph-face (if family
                               (ebox--merge-face (ebox--family-face family) face)
                             face))
               (image nil)
               (fit
                (cond
                 ((> (ebox--fit-row-height cluster face nil glyph-face) line)
                  (if (setq image (ebox--emoji-image cluster line))
                      (cons line (cons image nil))
                    (let* ((pinned (or family (ebox--foreign-family cluster face)))
                           (gface (if (and pinned (not family))
                                      (ebox--merge-face (ebox--family-face pinned) face)
                                    glyph-face)))
                      (cl-loop
                       for (scale . more) on ebox--fit-scales
                       when (or (null more)
                                (<= (ebox--fit-row-height cluster face scale gface) line))
                       return (let ((spec (ebox--fit-spec face scale)))
                                (cons (car (ebox--measure-raw-size
                                            (propertize cluster 'face gface
                                                        'display spec)))
                                      (cons spec pinned)))))))
                 (family
                  (cons (ebox--measure-raw (propertize cluster 'face glyph-face))
                        (cons nil family))))))
          (puthash cluster (or fit 'fits) fits)
          fit)))))

(defun ebox--fitted-width (cluster face)
  "Return CLUSTER's pixel width under FACE in its line-fitted form."
  (or (car (ebox--fit cluster face))
      (ebox--measure-raw (if face (propertize cluster 'face face) cluster))))

(defun ebox--cluster-width (string start next face)
  "Return the width of cluster START..NEXT in plain STRING under FACE."
  (if (= next (1+ start))
      (ebox--char-width (aref string start) face)
    (let* ((text (substring-no-properties string start next))
           (key (cons face text)))
      (or (gethash key ebox--cluster-width-cache)
          (puthash key (if (ebox--fit-candidate-string-p text)
                           (ebox--fitted-width text face)
                         (ebox--measure-raw
                          (if face (propertize text 'face face) text)))
                   ebox--cluster-width-cache)))))

(defun ebox--units (string face)
  "Return STRING's display units as a list of (START END WIDTH).
Plain grapheme clusters, runs sharing one replacing display property, and
fixed display spaces are one unit each.  FACE is the node's font face."
  (let ((pos 0) (len (length string)) units)
    (if (ebox--plain-string-p string)
        (while (< pos len)
          (let ((next (ebox--cluster-end string pos len)))
            (push (list pos next (ebox--cluster-width string pos next face))
                  units)
            (setq pos next)))
      (while (< pos len)
        (let* ((display (get-text-property pos 'display string))
               (space (and display (ebox--fixed-space-width display)))
               (next (if display
                         (or (next-single-property-change pos 'display string len)
                             len)
                       (ebox--cluster-end string pos len)))
               (width
                (cond (space space)
                      (display (ebox--display-width string pos next face))
                      ((get-text-property pos 'face string)
                       (ebox--cluster-width
                        string pos next
                        (ebox--merge-face (get-text-property pos 'face string)
                                          face)))
                      (t (ebox--cluster-width string pos next face)))))
          (push (list pos next width) units)
          (setq pos next))))
    (nreverse units)))

(defun ebox--text-width (string face)
  "Return the display width of one-line STRING under FACE."
  (if (and (ebox--plain-string-p string))
      (let ((pos 0) (len (length string)) (total 0))
        (while (< pos len)
          (let ((char (aref string pos)))
            (if (and (< char 128)
                     (let ((next (1+ pos)))
                       (or (>= next len) (< (aref string next) 128))))
                (setq total (+ total (ebox--char-width char face))
                      pos (1+ pos))
              (let ((next (ebox--cluster-end string pos len)))
                (setq total (+ total (ebox--cluster-width string pos next face))
                      pos next)))))
        total)
    (let ((total 0))
      (dolist (unit (ebox--units string face) total)
        (setq total (+ total (nth 2 unit)))))))

(defun ebox--line-width (line)
  "Return the display width of composed LINE, honoring its own faces."
  (let ((pos 0) (len (length line)) (total 0))
    (while (< pos len)
      (let* ((display (get-text-property pos 'display line))
             (space (and display (ebox--fixed-space-width display)))
             (next (if display
                       (or (next-single-property-change pos 'display line len) len)
                     (min (or (next-single-property-change pos 'face line len) len)
                          (or (next-single-property-change pos 'display line len)
                              len)))))
        (setq total
              (+ total
                 (cond (space space)
                       (display (ebox--display-width line pos next))
                       (t (ebox--text-width
                           (substring-no-properties line pos next)
                           (get-text-property pos 'face line))))))
        (setq pos next)))
    total))

(defvar ebox--space-cache (make-hash-table :test 'equal)
  "Interned pixel spaces keyed by (WIDTH . FACE).")

(defun ebox--space (width &optional face)
  "Return a one-character space WIDTH pixels wide painted with FACE.
Return the empty string when WIDTH is not positive."
  (if (<= width 0)
      ""
    (let ((key (cons width face)))
      (or (gethash key ebox--space-cache)
          (puthash key
                   (let* ((display (list 'space :width (list width)))
                          (string (propertize " " 'display display)))
                     (when face (put-text-property 0 1 'face face string))
                     string)
                   ebox--space-cache)))))

(defun ebox--props-same-p (a b)
  "Return non-nil when text property lists A and B paint alike.
Painting conses fresh faces, which compare by value.  Display values compare
by identity, since Emacs joins adjacent characters with `eq' displays and the
buffer must keep exactly the composed line's objects; other values, such as
node records, compare by identity because `equal' would descend into the
tree they link to."
  (while (and a b (eq (car a) (car b))
              (let ((x (cadr a)) (y (cadr b)))
                (or (eq x y)
                    (and (eq (car a) 'face) (equal x y)))))
    (setq a (cddr a) b (cddr b)))
  (and (null a) (null b)))

(defvar ebox--display-twins (make-hash-table :test 'eq :weakness 'key)
  "An equal but distinct copy of each shared display value, in both directions.
Display values are interned so that a composed line keeps the same objects
across rewrites, but Emacs paints consecutive characters showing the same
`eq' display value as one element.  A run of identical shared displays must
therefore alternate between the value and its twin to keep every glyph and
its width.")

(defun ebox--display-twin (display)
  "Return an equal copy of DISPLAY that never compares `eq' to it."
  (or (gethash display ebox--display-twins)
      (let ((twin (copy-sequence display)))
        (puthash twin display ebox--display-twins)
        (puthash display twin ebox--display-twins)
        twin)))

(defvar ebox--twin-strings (make-hash-table :test 'eq :weakness 'key)
  "One-character strings whose first character shows an alternate display.")

(defun ebox--twin-first (part display)
  "Return PART with its first character showing DISPLAY's alternate.
PART starts with the shared DISPLAY.  When its second character already
shows the alternate, the first receives a fresh copy instead."
  (let ((twin (ebox--display-twin display)))
    (if (= (length part) 1)
        (or (gethash part ebox--twin-strings)
            (puthash part (let ((copy (copy-sequence part)))
                            (put-text-property 0 1 'display twin copy)
                            copy)
                     ebox--twin-strings))
      (let ((copy (copy-sequence part)))
        (put-text-property 0 1 'display
                           (if (eq (get-text-property 1 'display part) twin)
                               (copy-sequence display)
                             twin)
                           copy)
        copy))))

(defun ebox--join-parts (parts)
  "Return the nonempty strings of PARTS as they compose one line.
PARTS is a tree: each element is a string or a nested list of parts, so a
node shares its children's cached parts without copying them.  Emacs draws
consecutive characters whose `display' values are `eq' as one element, so
two shared displays meeting at a junction would collapse into one.  Each
string is free of such pairs and only the junctions are examined: a string
starting with the display that ends the previous one shows that display's
alternate, which keeps the line's display objects stable across rewrites."
  (let ((kept nil) (last nil) (stack nil) (rest parts))
    (while (or rest stack)
      (if (null rest)
          (setq rest (pop stack))
        (let ((part (car rest)))
          (setq rest (cdr rest))
          (if (consp part)
              (progn (when rest (push rest stack))
                     (setq rest part))
            (let ((n (length part)))
              (when (> n 0)
                (let ((first (get-text-property 0 'display part)))
                  (when (and first (eq first last))
                    (setq part (ebox--twin-first part first))))
                (setq last (get-text-property (1- n) 'display part))
                (push part kept)))))))
    (nreverse kept)))

(defun ebox--join (parts)
  "Concatenate the strings PARTS into one composed line.
See `ebox--join-parts'."
  (let ((kept (ebox--join-parts parts)))
    (cond ((null kept) "")
          ((null (cdr kept)) (car kept))
          (t (apply #'concat kept)))))

(defun ebox--join-fresh (parts)
  "Return a new string composing PARTS, which the caller may modify.
See `ebox--join'."
  (let ((kept (ebox--join-parts parts)))
    (if (cdr kept) (apply #'concat kept) (copy-sequence (or (car kept) "")))))

(defun ebox-pixel-space (pixel-width)
  "Return a display space PIXEL-WIDTH pixels wide."
  (ebox--space (or pixel-width 0)))

(defun ebox-string-pixel-width (string)
  "Return the display pixel width of STRING's first line."
  (let* ((source (or string ""))
         (newline (string-search "\n" source)))
    (ebox--line-width (if newline (substring source 0 newline) source))))

(defun ebox-clear-cache ()
  "Clear pixel caches after font, theme or named face metrics change."
  (clrhash ebox--width-tables)
  (clrhash ebox--cluster-width-cache)
  (clrhash ebox--space-cache)
  (clrhash ebox--image-widths)
  (clrhash ebox--family-faces)
  (fillarray ebox--face-memo nil)
  (setq ebox--tall-chars (make-char-table 'ebox-tall-chars)
        ebox--default-font-box nil
        ebox--default-font-family nil)
  (cl-incf ebox--width-epoch))

(defun ebox--reset-metrics (&rest _)
  "Reset measurement caches after a theme or frame font change."
  (ebox-clear-cache))

(when (boundp 'enable-theme-functions)
  (add-hook 'enable-theme-functions #'ebox--reset-metrics))
(when (boundp 'disable-theme-functions)
  (add-hook 'disable-theme-functions #'ebox--reset-metrics))
(when (boundp 'after-setting-font-hook)
  (add-hook 'after-setting-font-hook #'ebox--reset-metrics))

(provide 'ebox-measure)

;;; ebox-measure.el ends here
