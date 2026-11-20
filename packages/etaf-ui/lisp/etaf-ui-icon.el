;;; etaf-ui-icon.el --- Registered, line-safe icons -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Styles are registry data.  Font glyphs share a named face and a private
;; fontset; SVG glyphs share a square image box.  Neither route changes the
;; containing buffer's fontset, line spacing or display settings.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui-basic)
(require 'xml)

;; These native primitives are used only on graphical frames. Text-only
;; builds compile the same library and keep the printable icon fallback.
(declare-function font-info "font.c" (name &optional frame))
(declare-function font-face-attributes "font.c" (font &optional frame))
(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function set-fontset-font "fontset.c" (name target font-spec &optional frame add))
(declare-function create-fontset-from-fontset-spec "fontset" (fontset-spec &optional style-variant-p noerror))

(defvar etaf-ui-icon-default-set 'nerd
  "Default registered icon set, used after an explicitly requested set.")

(defvar etaf-ui-terminal-icon-set 'tty
  "Icon set consulted first on a text terminal for an SVG request.
Set it to a registered font set whose glyphs the terminal font contains, such
as `nerd` after installing a Nerd Font, to keep one icon family in a terminal.
Names the set does not contain fall through to the requested set.")

(defvar etaf-ui--icon-sets nil "Icon set specifications in registration order.")
(defvar etaf-ui--icon-cache (make-hash-table :test #'equal)
  "Cached fonts, faces and images, keyed by frame and default typography.")

(defun etaf-ui--icon-name (name)
  "Normalize symbolic or string icon NAME to a symbol."
  (cond ((and name (symbolp name)) name)
        ((and (stringp name) (> (length name) 0)) (intern name))
        (t (user-error "Icon name must be a nonempty symbol or string: %S" name))))

(defun etaf-ui-icon-set-register (name spec)
  "Register or replace symbolic NAME with icon set plist SPEC.
Font sets require :family, positive float :height and :glyphs.  SVG sets
require :viewbox and :paths or :draw; :inset defaults to 2 pixels.  Entries
are alists from symbols to printable strings of one or two cells, SVG bodies
or nullary draw
functions respectively.  Optional :fallback maps names to printable ASCII.
Invalid specifications signal `user-error' without changing the registry.
Treat the stored SPEC as immutable; re-register to change it.  Return NAME."
  (unless (and name (symbolp name) (proper-list-p spec)
               (zerop (% (length spec) 2)))
    (user-error "Invalid icon set name/specification: %S" name))
  (let ((kind (plist-get spec :kind))
        (glyphs (plist-get spec :glyphs))
        (paths (plist-get spec :paths))
        (draw (plist-get spec :draw)))
    (unless
        (pcase kind
          ('font (and (stringp (plist-get spec :family))
                      (floatp (plist-get spec :height))
                      (> (plist-get spec :height) 0)
                      (proper-list-p glyphs)
                      (cl-every (lambda (entry)
                                  (and (consp entry) (symbolp (car entry))
                                       (stringp (cdr entry))
                                       (<= 1 (string-width (cdr entry)) 2)
                                       (not (string-match-p "[\n\r\t]" (cdr entry)))
                                       (> (string-to-char (cdr entry)) 32)))
                                glyphs)))
          ('svg (let ((viewbox (plist-get spec :viewbox))
                      (inset (or (plist-get spec :inset) 2)))
                  (and (sequencep viewbox) (= (length viewbox) 4)
                       (cl-every #'numberp viewbox)
                       (> (elt viewbox 2) 0) (> (elt viewbox 3) 0)
                       (integerp inset) (>= inset 0)
                       (proper-list-p paths) (proper-list-p draw)
                       (or paths draw)
                       (cl-every (lambda (entry)
                                   (and (consp entry) (symbolp (car entry))
                                        (stringp (cdr entry)))) paths)
                       (cl-every (lambda (entry)
                                   (and (consp entry) (symbolp (car entry))
                                        (functionp (cdr entry)))) draw))))
          (_ nil))
      (user-error "Invalid %S icon set specification for %S" kind name))
    (let ((keys (mapcar #'car (append glyphs paths draw))))
      (unless (= (length keys) (length (delete-dups (copy-sequence keys))))
        (user-error "Duplicate icon names in %S" name)))
    (unless (and (proper-list-p (plist-get spec :fallback))
                 (cl-every
                  (lambda (entry)
                    (and (consp entry) (symbolp (car entry))
                         (stringp (cdr entry))
                         (string-match-p "\\`[ -~]+\\'" (cdr entry))))
                  (plist-get spec :fallback)))
      (user-error "Icon fallbacks must be nonempty printable ASCII strings")))
  (if-let* ((entry (assq name etaf-ui--icon-sets)))
      (setcdr entry spec)
    (setq etaf-ui--icon-sets (append etaf-ui--icon-sets (list (cons name spec)))))
  (clrhash etaf-ui--icon-cache)
  name)

(defun etaf-ui-icon-set-remove (name)
  "Remove registered set NAME; removing an absent set is harmless.
Existing rendered values remain valid until their next render.  Return nil."
  (setq etaf-ui--icon-sets (assq-delete-all name etaf-ui--icon-sets))
  (clrhash etaf-ui--icon-cache)
  nil)

(defun etaf-ui-icon-sets ()
  "Return registered icon set names in registration order."
  (mapcar #'car etaf-ui--icon-sets))

(defun etaf-ui-icon-set-spec (name)
  "Return the stored specification for NAME, or nil when absent."
  (cdr (assq name etaf-ui--icon-sets)))

(defun etaf-ui--icon-spec (name)
  "Return NAME's specification, signaling a usage error if absent."
  (or (etaf-ui-icon-set-spec name) (user-error "Unknown icon set: %S" name)))

(defun etaf-ui-icon-names (&optional set)
  "Return names provided by SET, or their union when SET is nil.
An unknown non-nil SET signals `user-error'.  Missing names are never
invented from other sets; use the component for fallback lookup."
  (if set
      (let ((spec (etaf-ui--icon-spec set)))
        (mapcar #'car (append (plist-get spec :glyphs)
                             (plist-get spec :paths) (plist-get spec :draw))))
    (delete-dups (cl-mapcan #'etaf-ui-icon-names (etaf-ui-icon-sets)))))

(defun etaf-ui--icon-default-info (frame)
  "Return the default font's native metrics on FRAME, or nil without one.
A frame can report graphics while its default face font is still unresolved,
as a batch or daemon frame does; callers then keep the one-line icon height
contract instead of asking `font-info' about a nil font."
  (when-let* (((display-graphic-p frame))
              (font (face-font 'default frame)))
    (font-info font frame)))

(defun etaf-ui--icon-font (spec pixels frame)
  "Open SPEC's exact family at PIXELS on FRAME, without font substitution."
  (when (display-graphic-p frame)
    (let* ((family (plist-get spec :family))
           (key (list 'font family pixels frame)))
      (or (gethash key etaf-ui--icon-cache)
          (let ((entity (find-font (font-spec :family family) frame)))
            (when (and entity
                       (equal (downcase family)
                              (downcase (format "%s" (font-get entity :family)))))
              (let ((font (open-font entity pixels frame)))
                (puthash key font etaf-ui--icon-cache))))))))

(defun etaf-ui-icon-metrics (set &optional frame)
  "Report unclamped SET metrics relative to FRAME's standard line.
Return :family, :height, :line-pixel-height, :line-height and :fit.
Font rows include the surrounding default font's ascent and descent.
Missing GUI fonts report nil pixel height and nil fit.  In batch/TTY,
estimate height from the declared ratio and standard row height; no font
availability claim is made.  Unknown SET signals `user-error'."
  (let* ((spec (etaf-ui--icon-spec set))
         (frame (or frame (selected-frame)))
         (line (frame-char-height frame)) ;; frame metric
         (height (or (plist-get spec :height) 1.0))
         (default (etaf-ui--icon-default-info frame))
         (font (and default (eq (plist-get spec :kind) 'font)
                    (etaf-ui--icon-font spec (max 1 (round (* (aref default 2) height))) frame)))
         (info (and font (font-info (font-xlfd-name font) frame)))
         (pixels
          (cond ((eq (plist-get spec :kind) 'svg) line)
                ((not default) (ceiling (* line height)))
                (info (+ (max (aref default 8) (aref info 8))
                         (max (aref default 9) (aref info 9)))))))
    (list :family (plist-get spec :family) :height height
          :line-pixel-height pixels :line-height line
          :fit (and pixels (<= pixels line)))))

(defun etaf-ui--icon-font-presentation (set spec size frame line)
  "Return a shared, clamped named face and font for SET, SPEC, SIZE and FRAME.
LINE is the canvas row height the glyph must fit."
  (let* ((default (etaf-ui--icon-default-info frame))
         (pixels (and default (max 1 (min line
                                         (round (* (aref default 2)
                                                   (plist-get spec :height) size))))))
         (key (list 'face set spec pixels frame default)))
    (when pixels
      (or (gethash key etaf-ui--icon-cache)
          (let (font info)
            ;; Match both halves of the baseline.  A font whose total height
            ;; fits can still grow a mixed text row through a larger descent.
            (while (and (> pixels 0)
                        (setq font (etaf-ui--icon-font spec pixels frame))
                        (setq info (font-info (font-xlfd-name font) frame))
                        (or (> (aref info 8) (aref default 8))
                            (> (aref info 9) (aref default 9))))
              (setq pixels (1- pixels)))
            (when (and font (> pixels 0))
              (let* ((family (plist-get spec :family))
                     (face (make-symbol "etaf-ui-icon-face"))
                     (fontset (create-fontset-from-fontset-spec
                               (format "-*-*-medium-r-normal--*-*-*-*-*-*-fontset-etaficon%d"
                                       (length (face-list)))))
                     (pattern (font-spec :family family :registry "iso10646-1")))
                ;; Anonymous :fontset faces do not pin private-use glyphs.
                ;; Include the registry: a bare family containing a hyphen is
                ;; otherwise parsed as a foundry/family pair by Emacs.
                (dolist (entry (plist-get spec :glyphs))
                  (when (> (string-to-char (cdr entry)) 127)
                    (set-fontset-font fontset (string-to-char (cdr entry)) pattern)))
                (make-face face)
                (set-face-attribute face nil :font font :fontset fontset
                                    :weight 'normal :slant 'normal
                                    :underline nil :overline nil :box nil)
                (puthash key (list face font) etaf-ui--icon-cache))))))))

(defun etaf-ui--icon-paint (face color)
  "Extract only foreground/background from FACE, with COLOR taking priority.
Typography and decorations cannot override an icon's line-height contract."
  (let ((attributes
         (if (and (symbolp face) (facep face))
             (list :foreground (face-attribute face :foreground nil t)
                   :background (face-attribute face :background nil t))
           face))
        result)
    (dolist (key '(:foreground :background))
      (let ((value (plist-get attributes key)))
        (when (and value (not (eq value 'unspecified)))
          (setq result (plist-put result key value)))))
    (when color (setq result (plist-put result :foreground color)))
    result))

(defun etaf-ui--icon-text (name spec)
  "Return SPEC's printable fallback for NAME, or the name as plain text."
  (or (cdr (assq name (plist-get spec :fallback)))
      (let ((print-escape-newlines t) (print-escape-nonascii t))
        (substring (prin1-to-string (symbol-name name)) 1 -1))))

(defun etaf-ui--icon-svg-p ()
  "Return non-nil when the current graphical frame supports SVG."
  (and (display-graphic-p) (image-type-available-p 'svg)))

(defun etaf-ui--icon-image (spec name size lines font line)
  "Return cached SVG image for SPEC, NAME, SIZE and LINES.
FONT supplies the exact family for a font glyph and LINE the canvas row the
caller slices it at.  Images use a single centered canvas, sliced at standard
row boundaries by the caller."
  (let* ((box (* line lines))
         (inset (or (plist-get spec :inset) 2))
         (extent (max 1 (min box (round (* (max 1 (- box inset)) size)))))
         (height (if (= lines 2) box extent))
         (key (list 'image spec name extent height font))
         (cached (gethash key etaf-ui--icon-cache)))
    (or cached
        (let* ((viewbox (or (plist-get spec :viewbox) [0 0 14 14]))
               (body (if font
                         (format "<text x='7' y='7' text-anchor='middle' dominant-baseline='central' font-family='%s' font-size='12' fill='currentColor'>%s</text>"
                                 (xml-escape-string (plist-get spec :family))
                                 (xml-escape-string (cdr (assq name (plist-get spec :glyphs)))))
                       (or (cdr (assq name (plist-get spec :paths)))
                           (funcall (cdr (assq name (plist-get spec :draw)))))))
               (image
                (create-image
                 (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><svg x='0' y='%s' width='%d' height='%d' viewBox='%s' fill='none' stroke='currentColor' stroke-width='1.4' stroke-linecap='round' stroke-linejoin='round'>%s</svg></svg>"
                         extent height (/ (- height extent) 2.0) extent extent
                         (mapconcat #'number-to-string viewbox " ") body)
                 'svg t :ascent 'center :scale 1)))
          (puthash key image etaf-ui--icon-cache)))))

(defun etaf-ui--icon-content (name set size lines paint)
  "Resolve NAME through SET and return SIZE/LINES text values with PAINT."
  (when set (etaf-ui--icon-spec set))
  (etaf-ui--icon-spec etaf-ui-icon-default-set)
  ;; One read for the whole icon: the glyph clamp, the image canvas and the
  ;; slice rows all use the row height the canvas draws.
  (let* ((line (cdr (etaf-ui--canvas-cell)))
         (requested (and set (etaf-ui-icon-set-spec set)))
         (text-display (not (display-graphic-p)))
         (terminal-set (and text-display etaf-ui-terminal-icon-set))
         (candidates
          (delete-dups
           ;; A terminal cannot draw an SVG set; the registered terminal set is
           ;; its implementation there, so it goes first instead of the artwork.
           (if (and text-display (eq set 'svg)
                    (eq (plist-get requested :kind) 'svg))
               (list terminal-set set etaf-ui-icon-default-set 'sys 'svg)
             (append (list set)
                     (and terminal-set (list terminal-set))
                     (list etaf-ui-icon-default-set 'sys 'svg)))))
         spec presentation chosen)
    (catch 'found
      (dolist (candidate candidates)
        (when-let* ((entry (and candidate (etaf-ui-icon-set-spec candidate))))
          (when (memq name (etaf-ui-icon-names candidate))
            (let ((fontp (eq (plist-get entry :kind) 'font)))
              (setq presentation
                    (and fontp (etaf-ui--icon-font-presentation
                                candidate entry size (selected-frame) line)))
              (when (or (not fontp) (not (display-graphic-p))
                        (and presentation
                             (font-has-char-p (cadr presentation)
                                              (string-to-char (cdr (assq name (plist-get entry :glyphs)))))))
                (setq spec entry chosen candidate)
                (throw 'found t)))))))
    (let* ((image (and chosen (etaf-ui--icon-svg-p)
                       ;; Draw font glyphs into the canvas too: an icon font's
                       ;; ink often exceeds its declared ascent and descent, so
                       ;; a glyph set as text is clipped by its row.
                       (or (eq (plist-get spec :kind) 'svg) presentation)
                       (etaf-ui--icon-image spec name size lines presentation line)))
           (text (cond
                  ((and presentation (not image))
                   (propertize (copy-sequence (cdr (assq name (plist-get spec :glyphs))))
                               'face (list (car presentation))))
                  ;; A requested font set and the terminal set draw their own
                  ;; glyphs on a text display; fallback sets keep their
                  ;; printable variants.
                  ((and text-display (eq (plist-get spec :kind) 'font)
                        (or (eq chosen terminal-set) (eq chosen set)))
                   (or (cdr (assq name (plist-get spec :glyphs)))
                       (etaf-ui--icon-text name spec)))
                  (t (etaf-ui--icon-text name spec))))
           (default (etaf-ui--icon-default-info (selected-frame)))
           (safe-face (if default
                          (font-face-attributes (face-font 'default))
                        '(:inherit default :height 1.0)))
           values)
      (dotimes (row lines)
        (let ((value (copy-sequence (if (or image (= row 0)) text " "))))
          (if image
              (put-text-property
               0 (length value) 'display
               (if (= lines 1) image
                 (list (list 'slice 0 (* row line)
                             (car (image-size image t)) line) image))
               value)
            ;; A text frame has no font metrics to clamp.  Inheriting the
            ;; default face there would paint the default background behind
            ;; each glyph, so a one-cell mark and a two-cell mark would show
            ;; differently sized squares instead of one aligned column.
            (when (and (display-graphic-p)
                       (not (and presentation (= row 0))))
              (put-text-property 0 (length value) 'face safe-face value)))
          (when paint (add-face-text-property 0 (length value) paint nil value))
          (push value values)))
      (nreverse values))))

(defun etaf-ui--icon-label (label help fallback)
  "Return LABEL, else a string HELP, else FALLBACK as an accessible name."
  (cond (label label)
        ((stringp help) help)
        ((symbolp fallback) (symbol-name fallback))
        (t fallback)))

(cl-defun etaf-ui-icon-lines (name &key set (size 1.0) color face (lines 1))
  "Return owned propertized strings for icon NAME in LINES standard rows.
SET, SIZE, COLOR and FACE use the same resolution as `etaf-ui-icon'. Resolve
once in a Component binding, then choose the text in retained Host expressions
without introducing an overlapping positioned icon. Images are shared and
must not be mutated; each returned string can be changed independently."
  (etaf-check-prop :size size (and (numberp size) (> size 0)) "a positive number" 'etaf-ui-icon-lines)
  (etaf-check-prop :lines lines (memq lines '(1 2)) "1 or 2" 'etaf-ui-icon-lines)
  (etaf-ui--icon-content (etaf-ui--icon-name name) set size lines
                         (etaf-ui--icon-paint face color)))

(etaf-define-component etaf-ui-icon
    (&key name set (size 1.0) color face (lines 1) (min-width 2)
          help-echo on-press tab-index aria-label id class ref)
  "Render one semantic icon in one or two standard rows.
SIZE scales within the reserved rows and is clamped to their pixel height.
MIN-WIDTH is in cells.  The complete box is the ON-PRESS target; a pressable
icon is a Tab stop with TAB-INDEX, default 0, and a negative TAB-INDEX keeps
it clickable but out of Tab order.  ARIA-LABEL names it for the command
palette and defaults to a string HELP-ECHO, then NAME."
  :render
  (progn
    (etaf-check-prop :size size (and (numberp size) (> size 0)) "a positive number" 'etaf-ui-icon)
    (etaf-check-prop :lines lines (memq lines '(1 2)) "1 or 2" 'etaf-ui-icon)
    (etaf-check-prop :min-width min-width (and (numberp min-width) (>= min-width 1)) "at least one cell" 'etaf-ui-icon)
    (etaf-check-prop :on-press on-press (or (null on-press) (functionp on-press)) "a function or nil" 'etaf-ui-icon)
    (let* ((name (etaf-ui--icon-name name))
           (paint (etaf-ui--icon-paint face color))
           (values (etaf-ui--icon-content name set size lines paint)))
      (etaf-node
       'column
       (append
        (list :id id :ref ref :class (etaf-ui--class-value "etaf-ui-icon" nil class)
              :role (if on-press 'button 'img)
              :aria-label (etaf-ui--icon-label aria-label help-echo name)
              :on-press on-press :tab-index (and on-press (or tab-index 0))
              :width 'max-content :min-width (list 'ch min-width)
              :height (list 'lh lines) :overflow 'hidden
              :color (plist-get paint :foreground)
              :background-color (plist-get paint :background))
        ;; An explicit nil would block the enclosing control's help.
        (when help-echo (list :help-echo help-echo)))
       (mapcar (lambda (value)
                 (etaf-node 'box (list :height '(lh 1) :width 'stretch
                                      :text-align 'center :overflow 'hidden)
                            (list (etaf-node 'text nil (list value))))) values)))))

(cl-defun etaf-ui-icon (name &key set (size 1.0) color face (lines 1)
                            (min-width 2) help-echo on-press tab-index aria-label
                            id class ref)
  "Construct an icon View for NAME with SET, SIZE, COLOR, FACE and LINES.
MIN-WIDTH, HELP-ECHO, ON-PRESS, TAB-INDEX, ARIA-LABEL, ID, CLASS and REF
belong to the whole box.
Inside `etaf-view', use the component form with :name instead of NAME."
  (etaf-node 'etaf-ui-icon
             (list :name name :set set :size size :color color :face face
                   :lines lines :min-width min-width :help-echo help-echo
                   :on-press on-press :tab-index tab-index :aria-label aria-label
                   :id id :class class :ref ref)
             nil))

(etaf-define-component etaf-ui-toggle-icon
    (&key value off on set (size 1.0) color on-color face (lines 1) (min-width 2)
          help-echo on-press tab-index aria-label id class ref)
  "Render OFF or ON as one icon that switches without re-rendering.
VALUE is a boolean or a reactive source.  Both variants are resolved while
rendering; each row's text then reads VALUE directly, so a change publishes a
retained Host text update instead of rebuilding the Component.  OFF and ON
may name the same icon when only ON-COLOR differs, which turns a colour state
such as shuffle or repeat into the same retained update.  ON-COLOR defaults
to COLOR.  SET, SIZE, FACE, LINES, MIN-WIDTH, HELP-ECHO, ON-PRESS,
TAB-INDEX, ID, CLASS and REF match `etaf-ui-icon'.  The complete box is the
ON-PRESS target.  ARIA-LABEL defaults to a string HELP-ECHO, then \"OFF / ON\"."
  :render
  (progn
    (etaf-check-prop :size size (and (numberp size) (> size 0)) "a positive number" 'etaf-ui-toggle-icon)
    (etaf-check-prop :lines lines (memq lines '(1 2)) "1 or 2" 'etaf-ui-toggle-icon)
    (etaf-check-prop :min-width min-width (and (numberp min-width) (>= min-width 1))
                     "at least one cell" 'etaf-ui-toggle-icon)
    (etaf-check-prop :on-press on-press (or (null on-press) (functionp on-press))
                     "a function or nil" 'etaf-ui-toggle-icon)
    (etaf-check-prop :value value
                     (or (etaf-ref-p value) (etaf-computed-p value) (booleanp value))
                     "a boolean or a reactive source" 'etaf-ui-toggle-icon)
    (let* ((off (etaf-ui--icon-name off))
           (on (etaf-ui--icon-name on))
           (paint (etaf-ui--icon-paint face color))
           (off-values (etaf-ui--icon-content off set size lines paint))
           (on-values (etaf-ui--icon-content on set size lines
                                             (etaf-ui--icon-paint face (or on-color color)))))
      (etaf-view
       (column :id id :ref ref :class (etaf-ui--class-value "etaf-ui-icon" nil class)
               :role (if on-press 'button 'img)
               :aria-label (etaf-ui--icon-label
                            aria-label help-echo
                            (format "%s / %s" (symbol-name off) (symbol-name on)))
               :on-press on-press :tab-index (and on-press (or tab-index 0))
               :help-echo help-echo
               :width 'max-content :min-width (list 'ch min-width)
               :height (list 'lh lines) :overflow 'hidden
               :color (plist-get paint :foreground)
               :background-color (plist-get paint :background)
         (etaf-ui--toggle-icon-row :if (>= lines 1) :row 0
                                  :value value :off off-values :on on-values)
         (etaf-ui--toggle-icon-row :if (>= lines 2) :row 1
                                  :value value :off off-values :on on-values))))))

(etaf-define-component etaf-ui--toggle-icon-row
    (&key row value off on)
  "Render one centred toggle row: OFF or ON selected by VALUE.
Internal sibling of `etaf-ui-toggle-icon'; its text reads VALUE directly so a
change stays a retained Host update rather than a Component rerender."
  :render
  (etaf-view
   (box :height '(lh 1) :width 'stretch :text-align 'center :overflow 'hidden
     (text (expr (nth row (if (etaf-ui--reactive-value value) on off)))))))

;; Built-in maps contain only real glyphs.  A style is allowed to provide a
;; subset: for example the installed Octicons has no pause or music glyph.
(let* ((fa '((play . "\uf04b") (pause . "\uf04c") (next . "\uf051")
             (previous . "\uf048") (repeat . "\uf01e") (shuffle . "\uf074")
             (heart . "\uf08a") (heart-filled . "\uf004") (volume . "\uf028")
             (volume-mute . "\uf026") (volume-low . "\uf027") (volume-high . "\uf028")
             (search . "\uf002") (refresh . "\uf021") (close . "\uf00d")
             (plus . "\uf067") (minus . "\uf068") (queue . "\uf03a")
             (lyrics . "\uf0f6") (list . "\uf03a") (music . "\uf001")
             (settings . "\uf013") (chevron-up . "\uf077") (chevron-down . "\uf078")
             (chevron-left . "\uf053") (chevron-right . "\uf054")
             (check . "\uf00c") (account . "\uf007") (loading . "\uf110")
             (pin . "\uf08d") (bell-off . "\uf1f6") (send . "\uf1d8")
             (reply . "\uf112") (users . "\uf0c0") (megaphone . "\uf0a1")
             (at . "\uf1fa") (smile . "\uf118") (image . "\uf03e")
             (video . "\uf03d") (file . "\uf15b") (info . "\uf05a")
             (paperclip . "\uf0c6")
             (menu . "\uf0c9") (more-vertical . "\uf142") (eye . "\uf06e")))
       (fallback '((play . ">") (pause . "||") (next . ">|") (previous . "|<")
                   (repeat . "@") (repeat-one . "@1") (shuffle . "~")
                   (heart . "<3") (heart-filled . "<3") (volume . "v")
                   (volume-mute . "x") (volume-low . "v-") (volume-high . "v+")
                   (search . "?") (refresh . "@") (close . "x") (plus . "+")
                   (minus . "-") (queue . "=") (lyrics . "T") (list . "=")
                   (music . "m") (settings . "*") (chevron-up . "^")
                   (chevron-down . "v") (chevron-left . "<") (chevron-right . ">")
                   (check . "ok") (account . "u") (loading . "...")
                   (more . "...")
                   (download . "v")
                   (star . "*") (radio . "~") (disc . "o") (chart . "=")
                   (mic . "!") (clock . "c")
                   (pin . "^") (bell-off . "z") (send . ">") (reply . "<")
                   (users . "#") (megaphone . "!") (at . "@") (dot . "*")
                   (smile . ":)") (image . "[]") (video . "|>") (file . "=")
                   (paperclip . "&")
                   (info . "i") (menu . "=") (more-vertical . ":")
                   (sidebar . "|]") (eye . "o")
                   (checkbox . "[ ]") (checkbox-checked . "[x]")
                   (checkbox-crossed . "[x]") (checkbox-dashed . "[-]")))
       (fonts
        `((nerd ("DroidSansMono Nerd Font" "DejaVuSansMono Nerd Font") 1.0 ,fa)
          (fa ("FontAwesome") 0.86 ,fa)
          (material ("Material Icons") 0.86
                    ((play . "\ue037") (pause . "\ue034") (next . "\ue044")
                     (previous . "\ue045") (repeat . "\ue040") (repeat-one . "\ue041")
                     (shuffle . "\ue043") (heart . "\ue87e") (heart-filled . "\ue87d")
                     (volume . "\ue050") (volume-mute . "\ue04f") (volume-low . "\ue04d")
                     (volume-high . "\ue050") (search . "\ue8b6") (refresh . "\ue5d5")
                     (close . "\ue5cd") (plus . "\ue145") (minus . "\ue15b")
                     (queue . "\ue03c") (lyrics . "\ue241") (list . "\ue896")
                     (music . "\ue405") (settings . "\ue8b8") (chevron-up . "\ue5ce")
                     (chevron-down . "\ue5cf") (chevron-left . "\ue5cb")
                     (chevron-right . "\ue5cc") (check . "\ue5ca")
                     (paperclip . "\ue226")
                     (account . "\ue7fd") (loading . "\ue863")))
          (octicons ("github-octicons") 0.86
                    ((play . "\uf05a") (heart-filled . "♥") (volume . "\uf0ba")
                     (volume-mute . "\uf080") (search . "\uf02e") (refresh . "\uf087")
                     (close . "\uf081") (plus . "\uf05d") (minus . "\uf0ca")
                     (queue . "\uf076") (lyrics . "\uf011") (list . "\uf061")
                     (settings . "\uf02f") (chevron-up . "\uf0a2") (chevron-down . "\uf0a3")
                     (chevron-left . "\uf0a4") (chevron-right . "\uf078")
                     (check . "\uf03a") (account . "\uf018") (loading . "\uf087")))
          (sys ("Apple Symbols" "Zapf Dingbats") 1.0
               ((play . "▶") (repeat . "↻") (shuffle . "⇄") (heart . "♡")
                (heart-filled . "♥") (search . "⌕") (refresh . "↻")
                (close . "✕") (plus . "+") (minus . "−") (queue . "☰")
                (list . "☰") (music . "♫") (settings . "⚙") (chevron-up . "⌃")
                (chevron-down . "⌄") (chevron-left . "‹") (chevron-right . "›")
                (check . "✓") (loading . "⌛"))))))
  (dolist (entry fonts)
    (pcase-let* ((`(,name ,families ,height ,glyphs) entry)
                 (family (or (cl-find-if
                              (lambda (family)
                                (etaf-ui--icon-font (list :family family) 12 (selected-frame)))
                              families)
                             (car families)))
                 (spec (list :kind 'font :family family :height height))
                 (font (etaf-ui--icon-font spec 12 (selected-frame))))
      (etaf-ui-icon-set-register
       name (append spec
                    (list :glyphs (if font (cl-remove-if-not
                                           (lambda (entry) (font-has-char-p font (string-to-char (cdr entry))))
                                           glyphs)
                                    ;; Apple Symbols has no check/cross; Zapf does.
                                    (if (eq name 'sys)
                                        (assq-delete-all 'check (assq-delete-all 'close (copy-tree glyphs)))
                                      glyphs))
                          :fallback fallback)))))
  (etaf-ui-icon-set-register
   'tty
   (list :kind 'font :family "monospace" :height 1.0
         :glyphs
         '((play . "▶") (pause . "❚❚") (next . "⏭") (previous . "⏮")
           (repeat . "↻") (repeat-one . "↻") (shuffle . "⇄")
           (heart . "♡") (heart-filled . "♥")
           (volume . "♪") (volume-mute . "×") (volume-low . "♪") (volume-high . "♪")
           (search . "⌕") (refresh . "↻") (close . "✕") (plus . "+") (minus . "−")
           (queue . "▤") (lyrics . "¶") (list . "▤") (music . "♫") (settings . "⚙")
           (chevron-up . "⌃") (chevron-down . "⌄") (chevron-left . "‹") (chevron-right . "›")
           (check . "✓") (account . "☺") (loading . "…") (more . "…")
           (download . "↓") (star . "☆") (radio . "◉") (disc . "◎") (chart . "▥")
           (mic . "◍") (clock . "◷") (send . "→") (reply . "←") (users . "▤")
           (at . "@") (dot . "•") (smile . "☺") (image . "▣") (video . "▶")
           (file . "▥") (paperclip . "&") (info . "i") (menu . "≡")
           (more-vertical . "⋮") (eye . "◉"))
         :fallback fallback))
  (etaf-ui-icon-set-register
   'svg
   (list :kind 'svg :viewbox [0 0 14 14] :inset 2 :fallback fallback
         :paths
         '((play . "<path d='M4 2L12 7L4 12Z'/>")
           (pause . "<path d='M4 2V12M10 2V12'/>")
           (next . "<path d='M2 2L10 7L2 12ZM12 2V12'/>")
           (previous . "<path d='M12 2L4 7L12 12ZM2 2V12'/>")
           (repeat . "<path d='M2 5V3H12L10 1M12 9V11H2L4 13'/>")
           (repeat-one . "<path d='M2 5V3H12L10 1M12 9V11H2L4 13M6 6L7 5V9'/>")
           (shuffle . "<path d='M1 3H3L10 11H13M11 9L13 11L11 13M1 11H3L10 3H13M11 1L13 3L11 5'/>")
           (heart . "<path d='M7 12L2 7C-2 2 4 -1 7 4C10 -1 16 2 12 7Z'/>")
           (heart-filled . "<path fill='currentColor' d='M7 12L2 7C-2 2 4 -1 7 4C10 -1 16 2 12 7Z'/>")
           (volume . "<path d='M1 5H4L7 2V12L4 9H1ZM10 4Q13 7 10 10'/>")
           (volume-mute . "<path d='M1 5H4L7 2V12L4 9H1ZM10 5L13 9M13 5L10 9'/>")
           (volume-low . "<path d='M1 5H4L7 2V12L4 9H1ZM10 5Q12 7 10 9'/>")
           (volume-high . "<path d='M1 5H4L7 2V12L4 9H1ZM9 5Q11 7 9 9M11 2Q15 7 11 12'/>")
           (search . "<circle cx='6' cy='6' r='4'/><path d='M9 9L13 13'/>")
           (refresh . "<path d='M12 5A5 5 0 1 0 12 9M9 5H12V2'/>")
           (close . "<path d='M3 3L11 11M11 3L3 11'/>")
           (plus . "<path d='M2 7H12M7 2V12'/>")
           (minus . "<path d='M2 7H12'/>")
           (queue . "<path d='M2 3H12M2 7H8M2 11H8M11 7V13M8 10H14'/>")
           (lyrics . "<path d='M2 2H12M7 2V9M4 9H10M3 12H11'/>")
           (list . "<path d='M2 3H3M6 3H12M2 7H3M6 7H12M2 11H3M6 11H12'/>")
           (music . "<path d='M5 10V3L12 1V8M5 5L12 3'/><ellipse cx='3' cy='11' rx='2' ry='1.5'/><ellipse cx='10' cy='9' rx='2' ry='1.5'/>")
           (settings . "<circle cx='7' cy='7' r='3.5'/><circle cx='7' cy='7' r='1'/><path d='M7 1V3M7 11V13M1 7H3M11 7H13M3 3L4 4M10 10L11 11M3 11L4 10M10 4L11 3'/>")
           (chevron-up . "<path d='M3 9L7 5L11 9'/>")
           (chevron-down . "<path d='M3 5L7 9L11 5'/>")
           (chevron-left . "<path d='M9 3L5 7L9 11'/>")
           (chevron-right . "<path d='M5 3L9 7L5 11'/>")
           (check . "<path d='M2 7L5 10L12 3'/>")
           (account . "<circle cx='7' cy='4' r='2.5'/><path d='M2 13V11C2 6 12 6 12 11V13'/>")
           (loading . "<path d='M7 2A5 5 0 1 1 2 7'/><path d='M2 4V2H4'/>")
           (star . "<path d='M7 1.5L8.6 5.4L12.5 7L8.6 8.6L7 12.5L5.4 8.6L1.5 7L5.4 5.4Z'/>")
           (radio . "<circle cx='7' cy='7' r='1.6'/><path d='M3.5 10.5A5 5 0 0 1 3.5 3.5M10.5 3.5A5 5 0 0 1 10.5 10.5'/>")
           (disc . "<circle cx='7' cy='7' r='5'/><circle cx='7' cy='7' r='1.4'/>")
           (chart . "<path d='M2.5 12V8M5.5 12V4M8.5 12V6.5M11.5 12V2.5'/>")
           (mic . "<rect x='5' y='2' width='4' height='6' rx='2'/><path d='M3.5 7A3.5 3.5 0 0 0 10.5 7M7 10.5V12.5M5 12.5H9'/>")
           (clock . "<circle cx='7' cy='7' r='5'/><path d='M7 4.5V7.5L9.2 9.2'/>")
           (more . "<circle cx='3' cy='7' r='1.2' fill='currentColor'/><circle cx='7' cy='7' r='1.2' fill='currentColor'/><circle cx='11' cy='7' r='1.2' fill='currentColor'/>")
           (download . "<path d='M7 2V9M3.5 5.5L7 9L10.5 5.5M2 12H12'/>")
           (pin . "<path d='M5 2H9L8.5 6L11 8.5H3L5.5 6ZM7 8.5V12.5'/>")
           (bell-off . "<path d='M3.5 10.5V6.5A3.5 3.5 0 0 1 9.8 4.4M10.5 6.5V10.5H3.5M6 12.2H8M2 2L12 12'/>")
           (send . "<path d='M2 7L12 2.5L9.5 12L7 8ZM7 8L12 2.5'/>")
           (reply . "<path d='M6 3.5L2.5 7L6 10.5M2.5 7H8.5C10.5 7 11.5 8.5 11.5 11'/>")
           (users . "<circle cx='5' cy='4.5' r='2'/><path d='M1.5 12V11C1.5 7.8 8.5 7.8 8.5 11V12'/><path d='M9 2.7A2 2 0 0 1 9 6.3M10 8.2C11.6 8.6 12.5 9.6 12.5 11V12'/>")
           (megaphone . "<path d='M2 5.5H4.5L10.5 2.5V11.5L4.5 8.5H2ZM4.5 8.5L5.5 12H7L6.2 8.9'/>")
           (at . "<circle cx='7' cy='7' r='2.2'/><path d='M9.2 7V8.2C9.2 9.8 11.8 9.8 11.8 7.5A4.8 4.8 0 1 0 9.5 11.4'/>")
           (dot . "<circle cx='7' cy='7' r='2.6' fill='currentColor'/>")
           (smile . "<circle cx='7' cy='7' r='5.2'/><circle cx='5.2' cy='5.8' r='0.6' fill='currentColor'/><circle cx='8.8' cy='5.8' r='0.6' fill='currentColor'/><path d='M4.6 8.4Q7 10.8 9.4 8.4'/>")
           (image . "<rect x='1.5' y='2.5' width='11' height='9' rx='1.5'/><circle cx='5' cy='5.6' r='1'/><path d='M2 10.5L5.5 7.5L8 9.5L9.8 8L12 10'/>")
           (video . "<rect x='1.5' y='3.5' width='8' height='7' rx='1.5'/><path d='M9.5 6L12.5 4.2V9.8L9.5 8'/>")
           (file . "<path d='M3 1.5H8L11 4.5V12.5H3ZM8 1.5V4.5H11'/>")
           (paperclip . "<path d='M12.5 6.4l-5.4 5.4a3.5 3.5 0 0 1-5-5l5.4-5.4a2.3 2.3 0 0 1 3.3 3.3l-5.4 5.4a1.2 1.2 0 0 1-1.7-1.7l5-5'/>")
           (info . "<circle cx='7' cy='7' r='5.5'/><path d='M7 6.2V10'/><circle cx='7' cy='4.3' r='0.7' fill='currentColor' stroke='none'/>")
           (menu . "<path d='M2 3.5H12M2 7H12M2 10.5H12'/>")
           (more-vertical . "<circle cx='7' cy='3' r='1.2' fill='currentColor'/><circle cx='7' cy='7' r='1.2' fill='currentColor'/><circle cx='7' cy='11' r='1.2' fill='currentColor'/>")
           (sidebar . "<rect x='1.5' y='2' width='11' height='10' rx='2'/><path d='M8.5 2V12'/>")
           (eye . "<path d='M1 7C3 3.3 11 3.3 13 7C11 10.7 3 10.7 1 7Z'/><circle cx='7' cy='7' r='1.8'/>")
           (checkbox . "<rect x='1.2' y='1.2' width='11.6' height='11.6'/>")
           (checkbox-checked . "<rect x='1.2' y='1.2' width='11.6' height='11.6'/><path d='M3.7 7.2L6.1 9.6L10.5 4.3'/>")
           (checkbox-crossed . "<rect x='1.2' y='1.2' width='11.6' height='11.6'/><path d='M4.6 4.6L9.4 9.4M9.4 4.6L4.6 9.4'/>")
           (checkbox-dashed . "<rect x='1.2' y='1.2' width='11.6' height='11.6'/><path d='M4.2 7H9.8'/>")))))

(provide 'etaf-ui-icon)
;;; etaf-ui-icon.el ends here
