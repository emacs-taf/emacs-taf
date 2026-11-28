;;; etaf-screensaver-scene.el --- Scene registry and authoring builders -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A scene is registered under a symbol ID with pure callbacks: optional
;; :create, optional :step, required :render and optional :resize.  Built-in
;; and user scenes share the same public registry and high-level builders
;; (text, scalar field and particle systems).  All scenes run headless without
;; touching buffers, timers or processes.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-canvas)

(defconst etaf-screensaver--frame-styles '(full card)
  "Supported canvas framing styles.")

(defconst etaf-screensaver--scene-keys
  '(:title :summary :frame-rate :duration :background :frame :params
    :create :step :render :resize)
  "Property keys accepted by `etaf-screensaver-define-scene'.")

(cl-defstruct (etaf-screensaver--scene
               (:constructor etaf-screensaver--scene-make))
  "Registered description of one generative scene."
  id title summary frame-rate duration background frame params
  create step render resize)

(defvar etaf-screensaver--scenes nil
  "Registered scenes in registration order, as (ID . SCENE) pairs.")

(defun etaf-screensaver--param-key (key)
  "Normalize parameter KEY, accepting symbols and equivalent keywords."
  (if (keywordp key) (intern (substring (symbol-name key) 1)) key))

(defun etaf-screensaver--validate-params (params id)
  "Validate scene ID's default PARAMS alist and return a normalized copy."
  (unless (or (null params) (proper-list-p params))
    (etaf-screensaver--fail "Scene %s :params must be an alist" id))
  (let (seen result)
    (dolist (entry params)
      (unless (and (consp entry) (symbolp (car entry)) (car entry))
        (etaf-screensaver--fail "Scene %s parameter entry must be (KEY . DEFAULT): %S"
                                id entry))
      (let ((key (etaf-screensaver--param-key (car entry))))
        (when (memq key seen)
          (etaf-screensaver--fail "Scene %s repeats parameter %s" id key))
        (push key seen)
        (push (cons key (cdr entry)) result)))
    (nreverse result)))

(defun etaf-screensaver--register (id properties)
  "Register or replace scene ID from plist PROPERTIES and return it."
  (unless (and (symbolp id) id (not (keywordp id)))
    (etaf-screensaver--fail "Scene identifier must be a non-keyword symbol: %S" id))
  (unless (and (proper-list-p properties) (zerop (% (length properties) 2)))
    (etaf-screensaver--fail "Scene %s properties must be an even plist" id))
  (let ((tail properties) seen)
    (while tail
      (let ((key (pop tail)))
        (pop tail)
        (unless (and (memq key etaf-screensaver--scene-keys) (not (memq key seen)))
          (etaf-screensaver--fail "Scene %s has unknown or duplicate property %S" id key))
        (push key seen))))
  (let ((render (plist-get properties :render))
        (create (plist-get properties :create))
        (step (plist-get properties :step))
        (resize (plist-get properties :resize))
        (title (plist-get properties :title))
        (summary (plist-get properties :summary))
        (frame-rate (or (plist-get properties :frame-rate) 20))
        (duration (plist-get properties :duration))
        (background (plist-get properties :background))
        (frame (or (plist-get properties :frame) 'full))
        (params (etaf-screensaver--validate-params (plist-get properties :params) id)))
    (unless (functionp render)
      (etaf-screensaver--fail "Scene %s requires a :render function" id))
    (dolist (pair (list (cons :create create) (cons :step step) (cons :resize resize)))
      (when (and (cdr pair) (not (functionp (cdr pair))))
        (etaf-screensaver--fail "Scene %s %s must be a function or nil" id (car pair))))
    (unless (or (null title) (and (stringp title) (not (equal title ""))))
      (etaf-screensaver--fail "Scene %s :title must be a nonempty string" id))
    (unless (or (null summary) (stringp summary))
      (etaf-screensaver--fail "Scene %s :summary must be a string" id))
    (unless (and (numberp frame-rate) (> frame-rate 0) (<= frame-rate 60))
      (etaf-screensaver--fail "Scene %s :frame-rate must be in (0, 60]" id))
    (unless (or (null duration) (and (numberp duration) (> duration 0) (<= duration 86400)))
      (etaf-screensaver--fail "Scene %s :duration must be in (0, 86400]" id))
    (unless (or (null background) (stringp background))
      (etaf-screensaver--fail "Scene %s :background must be a color string" id))
    (unless (memq frame etaf-screensaver--frame-styles)
      (etaf-screensaver--fail "Scene %s :frame must be full or card" id))
    (let ((scene (etaf-screensaver--scene-make
                  :id id
                  :title (or title (symbol-name id))
                  :summary (or summary "")
                  :frame-rate frame-rate
                  :duration duration
                  :background background
                  :frame frame
                  :params params
                  :create create
                  :step step
                  :render render
                  :resize resize)))
      (setq etaf-screensaver--scenes
            (if (assq id etaf-screensaver--scenes)
                (mapcar (lambda (pair)
                          (if (eq (car pair) id) (cons id scene) pair))
                        etaf-screensaver--scenes)
              (append etaf-screensaver--scenes (list (cons id scene)))))
      scene)))

(defun etaf-screensaver--resolve-scene (scene)
  "Resolve SCENE (identifier, symbol name or display title) to its symbol ID."
  (cond
   ((null scene) nil)
   ((and (symbolp scene) (assq scene etaf-screensaver--scenes)) scene)
   ((stringp scene)
    (or (cl-loop for pair in etaf-screensaver--scenes
                 when (or (equal scene (symbol-name (car pair)))
                          (equal scene (etaf-screensaver--scene-title (cdr pair))))
                 return (car pair))
        (intern scene)))
   (t scene)))

(defun etaf-screensaver--scene (id)
  "Return the registered scene struct for ID, or signal `etaf-screensaver-error'."
  (or (cdr (assq id etaf-screensaver--scenes))
      (etaf-screensaver--fail "Unknown scene: %S" id)))

(defun etaf-screensaver-scenes ()
  "Return registered scene identifiers in registration order."
  (mapcar #'car etaf-screensaver--scenes))

(defun etaf-screensaver-scene-info (scene)
  "Return SCENE's public description plist without exposing callbacks.
SCENE may be an identifier symbol, its string name or its display title."
  (let* ((id (etaf-screensaver--resolve-scene scene))
         (desc (etaf-screensaver--scene id)))
    (list :id id
          :title (etaf-screensaver--scene-title desc)
          :summary (etaf-screensaver--scene-summary desc)
          :frame-rate (etaf-screensaver--scene-frame-rate desc)
          :duration (etaf-screensaver--scene-duration desc)
          :background (etaf-screensaver--scene-background desc)
          :frame (etaf-screensaver--scene-frame desc)
          :params (copy-tree (etaf-screensaver--scene-params desc)))))

(defun etaf-screensaver--plist-form (properties allowed label)
  "Validate plist keys in macro PROPERTIES against ALLOWED and build `(list ...)'."
  (unless (zerop (% (length properties) 2))
    (etaf-screensaver--fail "%s properties must be key/value pairs" label))
  (let ((tail properties) seen forms)
    (while tail
      (let ((key (pop tail))
            (val (pop tail)))
        (unless (and (keywordp key) (memq key allowed) (not (memq key seen)))
          (etaf-screensaver--fail "%s has unknown or duplicate property %S" label key))
        (push key seen)
        (push key forms)
        (push val forms)))
    `(list ,@(nreverse forms))))

(defmacro etaf-screensaver-define-scene (id &rest properties)
  "Register generative scene ID described by plist PROPERTIES.

PROPERTIES accepts:
  :title       display name (defaults to ID's name)
  :summary     one-line description
  :frame-rate  preferred frames per second in (0, 60] (default 20)
  :duration    optional natural duration in seconds
  :background  canvas background hex color overriding global default
  :frame       `full' (default) or `card'
  :params      default parameters alist, e.g. ((speed . 8) (color . \"#3BF07A\"))
  :create      optional (lambda (ctx)) returning initial state
  :step        optional (lambda (state ctx)) mutating state in place
  :render      required (lambda (state ctx)) returning a canvas, list of row
               strings or newline-separated string
  :resize      optional (lambda (state ctx)) returning resized state

CTX holds :columns, :rows, :elapsed, :dt, :tick, :seed, :background, :param,
:random and (during :render) a cleared reusable :canvas."
  (declare (indent 1))
  `(etaf-screensaver--register
    ',id ,(etaf-screensaver--plist-form properties etaf-screensaver--scene-keys
                                        "etaf-screensaver-define-scene")))

;;; High-level builder 1: text / quote / poem scenes.

(defconst etaf-screensaver--text-scene-keys
  '(:title :summary :frame-rate :duration :background :frame :params
    :items :style :color :caption-color :align :hold :fade :speed
    :letter-spacing :order)
  "Property keys accepted by `etaf-screensaver-define-text-scene'.")

(defun etaf-screensaver--space-chars (text)
  "Insert a single space between consecutive characters of TEXT."
  (let ((len (length text)))
    (if (<= len 1) text
      (let (parts)
        (dotimes (i len)
          (push (substring text i (1+ i)) parts)
          (when (< i (1- len)) (push " " parts)))
        (apply #'concat (nreverse parts))))))

(defun etaf-screensaver--text-normalize-items (raw letter-spacing)
  "Normalize RAW items into a vector of (LINES . CAPTION) entries."
  (let ((list (if (functionp raw) (funcall raw) raw)))
    (when (stringp list) (setq list (list list)))
    (unless (and (proper-list-p list) list)
      (etaf-screensaver--fail "Text scene :items must be a nonempty list or generator"))
    (vconcat
     (mapcar
      (lambda (entry)
        (let* ((text (cond ((stringp entry) entry)
                           ((and (proper-list-p entry) (stringp (plist-get entry :text)))
                            (plist-get entry :text))
                           (t (etaf-screensaver--fail
                               "Text scene item must be a string or (:text ...): %S" entry))))
               (caption (and (listp entry) (plist-get entry :caption)))
               (lines (mapcar (lambda (line)
                                (if letter-spacing (etaf-screensaver--space-chars line) line))
                              (split-string text "\n"))))
          (cons lines (and (stringp caption) (not (equal caption "")) caption))))
      list))))

(defun etaf-screensaver--text-order (count order random)
  "Return an index vector of length COUNT arranged by ORDER using RANDOM."
  (let ((vec (vconcat (number-sequence 0 (1- count)))))
    (when (eq order 'shuffle)
      (cl-loop for i from (1- count) downto 1 do
               (let* ((j (funcall random (1+ i)))
                      (tmp (aref vec i)))
                 (aset vec i (aref vec j))
                 (aset vec j tmp))))
    vec))

(defun etaf-screensaver--text-prefix-lines (lines count)
  "Return LINES truncated to at most COUNT total characters."
  (let ((remaining count) result)
    (dolist (line lines)
      (cond
       ((<= remaining 0) (push "" result))
       ((>= remaining (length line))
        (push line result)
        (cl-decf remaining (length line)))
       (t
        (push (substring line 0 remaining) result)
        (setq remaining 0))))
    (nreverse result)))

(defun etaf-screensaver--text-draw-block (canvas lines caption align ink cap-ink)
  "Draw centered vertical block of LINES and optional CAPTION on CANVAS."
  (let* ((rows (etaf-screensaver--canvas-height canvas))
         (total (+ (length lines) (if caption 2 0)))
         (top (max 0 (/ (- rows total) 2))))
    (cl-loop for line in lines for i from 0 do
             (etaf-screensaver-canvas-text canvas (+ top i) align line ink))
    (when caption
      (etaf-screensaver-canvas-text
       canvas (+ top (length lines) 1) align caption cap-ink))))

(defun etaf-screensaver--register-text-scene (id properties)
  "Build and register a text screensaver ID from PROPERTIES."
  (let* ((items (plist-get properties :items))
         (style (or (plist-get properties :style) 'typewriter))
         (align (or (plist-get properties :align) 'center))
         (order (or (plist-get properties :order) 'sequential))
         (hold (or (plist-get properties :hold) 3.0))
         (fade (or (plist-get properties :fade) 0.7))
         (speed (or (plist-get properties :speed) (if (eq style 'scroll) 2.5 8.0)))
         (letter-spacing (plist-get properties :letter-spacing))
         (color (plist-get properties :color))
         (caption-color (plist-get properties :caption-color))
         (extra-params (plist-get properties :params))
         (defaults (list (cons 'items items)
                         (cons 'style style)
                         (cons 'color color)
                         (cons 'caption-color caption-color)
                         (cons 'align align)
                         (cons 'hold hold)
                         (cons 'fade fade)
                         (cons 'speed speed)
                         (cons 'letter-spacing letter-spacing)
                         (cons 'order order)))
         (merged-params (append extra-params
                                (cl-remove-if (lambda (d) (assq (car d) extra-params))
                                              defaults))))
    (unless (or (functionp items) (stringp items) (and (proper-list-p items) items))
      (etaf-screensaver--fail "Text scene %s requires :items" id))
    (unless (memq style '(typewriter fade scroll static))
      (etaf-screensaver--fail "Text scene %s :style must be typewriter, fade, scroll or static" id))
    (unless (memq align '(left center right))
      (etaf-screensaver--fail "Text scene %s :align must be left, center or right" id))
    (unless (memq order '(sequential shuffle))
      (etaf-screensaver--fail "Text scene %s :order must be sequential or shuffle" id))
    (let (scene-props)
      (dolist (key '(:title :summary :frame-rate :duration :background :frame))
        (when (plist-member properties key)
          (setq scene-props (plist-put scene-props key (plist-get properties key)))))
      (setq scene-props (plist-put scene-props :params merged-params))
      (setq scene-props
            (plist-put
             scene-props :create
             (lambda (ctx)
               (let* ((param (plist-get ctx :param))
                      (entries (etaf-screensaver--text-normalize-items
                                (funcall param 'items)
                                (funcall param 'letter-spacing)))
                      (seq (etaf-screensaver--text-order
                            (length entries) (funcall param 'order)
                            (plist-get ctx :random))))
                 (list :entries entries :seq seq :pos 0 :phase-time 0.0 :scroll 0.0)))))
      (setq scene-props
            (plist-put
             scene-props :step
             (lambda (state ctx)
               (let* ((param (plist-get ctx :param))
                      (dt (plist-get ctx :dt))
                      (cur-style (funcall param 'style)))
                 (pcase cur-style
                   ('scroll
                    (cl-incf (plist-get state :scroll)
                             (* dt (max 0.1 (float (funcall param 'speed))))))
                   ((or 'typewriter 'fade)
                    (let* ((entries (plist-get state :entries))
                           (seq (plist-get state :seq))
                           (entry (aref entries (aref seq (plist-get state :pos))))
                           (chars (apply #'+ (mapcar #'length (car entry))))
                           (spd (max 0.5 (float (funcall param 'speed))))
                           (fd (max 0.0 (float (funcall param 'fade))))
                           (hd (max 0.1 (float (funcall param 'hold))))
                           (intro (if (eq cur-style 'typewriter) (/ (float chars) spd) fd))
                           (cycle (+ intro hd fd 0.35)))
                      (cl-incf (plist-get state :phase-time) dt)
                      (when (>= (plist-get state :phase-time) cycle)
                        (setf (plist-get state :phase-time) 0.0)
                        (let ((next (1+ (plist-get state :pos))))
                          (if (< next (length seq))
                              (setf (plist-get state :pos) next)
                            (setf (plist-get state :pos) 0
                                  (plist-get state :seq)
                                  (etaf-screensaver--text-order
                                   (length entries) (funcall param 'order)
                                   (plist-get ctx :random))))))))
                   (_ nil))))))
      (setq scene-props
            (plist-put
             scene-props :render
             (lambda (state ctx)
               (let* ((param (plist-get ctx :param))
                      (canvas (plist-get ctx :canvas))
                      (bg (or (plist-get ctx :background) "#05070B"))
                      (bg-hex (if (etaf-screensaver--hex-rgb bg) bg "#05070B"))
                      (default-ink (if (etaf-screensaver--color-light-p bg-hex) "#2B3036" "#E2E8F0"))
                      (ink (or (funcall param 'color) default-ink))
                      (cap-ink (or (funcall param 'caption-color)
                                   (etaf-screensaver-color-mix ink bg-hex 0.42)))
                      (cur-style (funcall param 'style))
                      (cur-align (funcall param 'align))
                      (entries (if (and (eq cur-style 'static)
                                        (functionp (funcall param 'items)))
                                   (etaf-screensaver--text-normalize-items
                                    (funcall param 'items) (funcall param 'letter-spacing))
                                 (plist-get state :entries)))
                      (seq (plist-get state :seq)))
                 (pcase cur-style
                   ('static
                    (let ((entry (aref entries (min (1- (length entries))
                                                    (aref seq (min (1- (length seq))
                                                                   (plist-get state :pos)))))))
                      (etaf-screensaver--text-draw-block
                       canvas (car entry) (cdr entry) cur-align ink cap-ink)))
                   ('scroll
                    (let ((rows (etaf-screensaver--canvas-height canvas))
                          flat)
                      (dotimes (i (length seq))
                        (let ((entry (aref entries (aref seq i))))
                          (dolist (line (car entry)) (push (cons line nil) flat))
                          (when (cdr entry) (push (cons (cdr entry) t) flat))
                          (push (cons "" nil) flat)))
                      (let* ((lines (vconcat (nreverse flat)))
                             (total (+ (length lines) rows))
                             (offset (mod (floor (plist-get state :scroll)) (max 1 total))))
                        (dotimes (r rows)
                          (let ((idx (- (+ r offset) rows)))
                            (when (and (>= idx 0) (< idx (length lines)))
                              (let ((item (aref lines idx)))
                                (etaf-screensaver-canvas-text
                                 canvas r cur-align (car item)
                                 (if (cdr item) cap-ink ink)))))))))
                   ((or 'typewriter 'fade)
                    (let* ((entry (aref entries (aref seq (plist-get state :pos))))
                           (lines (car entry))
                           (caption (cdr entry))
                           (chars (apply #'+ (mapcar #'length lines)))
                           (spd (max 0.5 (float (funcall param 'speed))))
                           (fd (max 0.0 (float (funcall param 'fade))))
                           (hd (max 0.1 (float (funcall param 'hold))))
                           (intro (if (eq cur-style 'typewriter) (/ (float chars) spd) fd))
                           (tm (plist-get state :phase-time)))
                      (cond
                       ((< tm intro)
                        (if (eq cur-style 'typewriter)
                            (let ((shown (max 1 (min chars (ceiling (* tm spd))))))
                              (etaf-screensaver--text-draw-block
                               canvas (etaf-screensaver--text-prefix-lines lines shown)
                               nil cur-align ink cap-ink))
                          (let ((alpha (if (> fd 0) (/ tm fd) 1.0)))
                            (etaf-screensaver--text-draw-block
                             canvas lines caption cur-align
                             (etaf-screensaver-color-mix bg-hex ink alpha)
                             (etaf-screensaver-color-mix bg-hex cap-ink alpha)))))
                       ((< tm (+ intro hd))
                        (etaf-screensaver--text-draw-block
                         canvas lines caption cur-align ink cap-ink))
                       ((< tm (+ intro hd fd))
                        (let ((alpha (if (> fd 0) (- 1.0 (/ (- tm intro hd) fd)) 0.0)))
                          (etaf-screensaver--text-draw-block
                           canvas lines caption cur-align
                           (etaf-screensaver-color-mix bg-hex ink alpha)
                           (etaf-screensaver-color-mix bg-hex cap-ink alpha))))
                       (t nil)))))
                 canvas))))
      (etaf-screensaver--register id scene-props))))

(defmacro etaf-screensaver-define-text-scene (id &rest properties)
  "Define a text, quote or poem screensaver under ID.

PROPERTIES accepts all metadata keys of `etaf-screensaver-define-scene' plus:
  :items           nonempty list of strings or (:text STR :caption STR) plists,
                   or a 0-arg function returning such a list
  :style           `typewriter' (default), `fade', `scroll' or `static'
  :color           ink hex color (defaults to contrast against background)
  :caption-color   optional caption hex color
  :align           `center' (default), `left' or `right'
  :hold            seconds held after reveal (default 3.0)
  :fade            seconds for fade transitions (default 0.7)
  :speed           chars/sec for typewriter (8) or rows/sec for scroll (2.5)
  :letter-spacing  non-nil inserts spaces between characters for airy display
  :order           `sequential' (default) or `shuffle'"
  (declare (indent 1))
  `(etaf-screensaver--register-text-scene
    ',id ,(etaf-screensaver--plist-form properties etaf-screensaver--text-scene-keys
                                        "etaf-screensaver-define-text-scene")))

;;; High-level builder 2: scalar field scenes.

(defconst etaf-screensaver--field-scene-keys
  '(:title :summary :frame-rate :duration :background :frame :params
    :value :range :ramp :palette :block)
  "Property keys accepted by `etaf-screensaver-define-field-scene'.")

(defun etaf-screensaver--register-field-scene (id properties)
  "Build and register a 2D scalar-field screensaver ID from PROPERTIES."
  (let* ((value-fn (plist-get properties :value))
         (range (or (plist-get properties :range) '(-1.0 1.0)))
         (ramp (or (plist-get properties :ramp) " .:-=+*#%@"))
         (palette (plist-get properties :palette))
         (block (or (plist-get properties :block) '(1 1)))
         (low (float (car range)))
         (high (float (if (consp (cdr range)) (cadr range) (cdr range))))
         (span (if (= low high) 1.0 (- high low)))
         (bw (max 1 (car block)))
         (bh (max 1 (if (consp (cdr block)) (cadr block) (cdr block))))
         (palette-vec (when palette
                        (unless (and (or (vectorp palette) (proper-list-p palette))
                                     (> (length palette) 0)
                                     (cl-every #'stringp palette))
                          (etaf-screensaver--fail "Field scene %s :palette must be color strings" id))
                        (vconcat palette))))
    (unless (functionp value-fn)
      (etaf-screensaver--fail "Field scene %s requires a :value function (x y ctx)" id))
    (unless (and (stringp ramp) (> (length ramp) 0))
      (etaf-screensaver--fail "Field scene %s :ramp must be a nonempty string" id))
    (let ((scene-props (list :frame-rate (or (plist-get properties :frame-rate) 12))))
      (dolist (key '(:title :summary :frame-rate :duration :background :frame :params))
        (when (plist-member properties key)
          (setq scene-props (plist-put scene-props key (plist-get properties key)))))
      (setq scene-props
            (plist-put
             scene-props :render
             (lambda (_state ctx)
               (let* ((canvas (plist-get ctx :canvas))
                      (rows (plist-get ctx :rows))
                      (cols (plist-get ctx :columns))
                      (ramp-len (length ramp))
                      (pal-len (and palette-vec (length palette-vec))))
                 (cl-loop for r from 0 below rows by bh do
                          (let ((yf (float r)))
                            (cl-loop for c from 0 below cols by bw do
                                     (let* ((val (float (funcall value-fn (float c) yf ctx)))
                                            (norm (max 0.0 (min 1.0 (/ (- val low) span))))
                                            (ch (aref ramp (min (1- ramp-len) (floor (* norm ramp-len)))))
                                            (color (and palette-vec
                                                        (aref palette-vec
                                                              (min (1- pal-len) (floor (* norm pal-len)))))))
                                       (if (and (= bw 1) (= bh 1))
                                           (etaf-screensaver-canvas-put canvas r c ch color)
                                         (etaf-screensaver-canvas-fill canvas r c bw bh ch color))))))
                 canvas))))
      (etaf-screensaver--register id scene-props))))

(defmacro etaf-screensaver-define-field-scene (id &rest properties)
  "Define a 2D scalar-field screensaver under ID.

PROPERTIES accepts all metadata keys of `etaf-screensaver-define-scene' plus:
  :value    required (lambda (x y ctx)) returning a numeric intensity
  :range    (LOW HIGH) value bounds mapped to [0, 1] (default (-1.0 1.0))
  :ramp     character ramp string (default \" .:-=+*#%@\")
  :palette  optional list/vector of quantized foreground color strings
  :block    optional (W H) cell block size (default (1 1))"
  (declare (indent 1))
  `(etaf-screensaver--register-field-scene
    ',id ,(etaf-screensaver--plist-form properties etaf-screensaver--field-scene-keys
                                        "etaf-screensaver-define-field-scene")))

;;; High-level builder 3: particle scenes.

(defconst etaf-screensaver--particle-scene-keys
  '(:title :summary :frame-rate :duration :background :frame :params
    :count :spawn :update :draw)
  "Property keys accepted by `etaf-screensaver-define-particle-scene'.")

(defun etaf-screensaver--register-particle-scene (id properties)
  "Build and register a particle-system screensaver ID from PROPERTIES."
  (let ((count-spec (plist-get properties :count))
        (spawn (plist-get properties :spawn))
        (update (plist-get properties :update))
        (draw (plist-get properties :draw)))
    (unless (functionp spawn)
      (etaf-screensaver--fail "Particle scene %s requires :spawn (index ctx)" id))
    (unless (functionp update)
      (etaf-screensaver--fail "Particle scene %s requires :update (particle ctx)" id))
    (unless (functionp draw)
      (etaf-screensaver--fail "Particle scene %s requires :draw (particle canvas ctx)" id))
    (let ((scene-props nil)
          (resolve-count
           (lambda (ctx)
             (let ((n (cond ((functionp count-spec) (funcall count-spec ctx))
                            ((integerp count-spec) count-spec)
                            ((assq 'count (plist-get ctx :params))
                             (funcall (plist-get ctx :param) 'count))
                            (t 80))))
               (max 1 (round n))))))
      (dolist (key '(:title :summary :frame-rate :duration :background :frame :params))
        (when (plist-member properties key)
          (setq scene-props (plist-put scene-props key (plist-get properties key)))))
      (setq scene-props
            (plist-put
             scene-props :create
             (lambda (ctx)
               (let* ((n (funcall resolve-count ctx))
                      (vec (make-vector n nil)))
                 (dotimes (i n) (aset vec i (funcall spawn i ctx)))
                 (list :particles vec)))))
      (setq scene-props
            (plist-put
             scene-props :step
             (lambda (state ctx)
               (let ((vec (plist-get state :particles)))
                 (dotimes (i (length vec))
                   (funcall update (aref vec i) ctx))))))
      (setq scene-props
            (plist-put
             scene-props :render
             (lambda (state ctx)
               (let ((canvas (plist-get ctx :canvas))
                     (vec (plist-get state :particles)))
                 (dotimes (i (length vec))
                   (funcall draw (aref vec i) canvas ctx))
                 canvas))))
      (setq scene-props
            (plist-put
             scene-props :resize
             (lambda (state _ctx) state)))
      (etaf-screensaver--register id scene-props))))

(defmacro etaf-screensaver-define-particle-scene (id &rest properties)
  "Define a particle-system screensaver under ID.

PROPERTIES accepts all metadata keys of `etaf-screensaver-define-scene' plus:
  :count   positive integer or (lambda (ctx)); defaults to param `count' or 80
  :spawn   required (lambda (index ctx)) returning one particle state
  :update  required (lambda (particle ctx)) mutating particle state in place
  :draw    required (lambda (particle canvas ctx)) drawing onto CANVAS"
  (declare (indent 1))
  `(etaf-screensaver--register-particle-scene
    ',id ,(etaf-screensaver--plist-form properties etaf-screensaver--particle-scene-keys
                                        "etaf-screensaver-define-particle-scene")))

(provide 'etaf-screensaver-scene)
;;; etaf-screensaver-scene.el ends here
