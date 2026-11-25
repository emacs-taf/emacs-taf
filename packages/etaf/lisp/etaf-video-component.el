;;; etaf-video-component.el --- Native video Component and controls -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The `etaf-video' Component renders a live video source inside any ETAF
;; layout.  A playback session decodes the source into raw frames, the
;; Component maps each frame into the canvas and publishes it through the
;; retained Host content boundary, so one displayed frame is one retained
;; Ebox publication instead of an ordinary ETAF render.  Three render modes
;; are available:
;;
;;   image  one scaled JPEG per frame as an image cell (graphical frames);
;;   ascii  one density-ramp character per pixel;
;;   color  two full-color pixels per `▀' half-block cell.
;;
;; `image' falls back to `ascii' when the target buffer is not shown in a
;; graphical frame, so a layout built for one environment still renders in
;; the other.  The density ramp, decoder programs and audio defaults are
;; variables; applications keep canvas layout, input and chrome.
;;
;; Components are driven by handle: callers pass `:handle' and use the
;; `etaf-video-play', `etaf-video-pause', `etaf-video-toggle-playback',
;; `etaf-video-step', `etaf-video-seek', `etaf-video-set-speed',
;; `etaf-video-set-volume', `etaf-video-set-audio' and `etaf-video-state'
;; functions.  A video placed with the plain `etaf-video' DSL form and no
;; handle still plays itself.

;;; Code:

(require 'cl-lib)
(require 'etaf-component)
(require 'etaf-reactive)
(require 'etaf-runtime)
(require 'etaf-video-audio)
(require 'etaf-video-mpv)
(require 'etaf-video-session)
(require 'etaf-video-source)

;; Only the image mode uses these optional native display primitives.
(declare-function image-flush "image.c" (spec &optional frame))
(declare-function canvas-refresh "image.c" (image &optional reload-data))
(declare-function etaf-video-canvas-close "etaf-video-canvas" (fd))
(declare-function font-info "font.c" (name &optional frame))

(defvar etaf-video-density-ramp " .:-=+*#%@"
  "Characters used for one video pixel in the `ascii' render mode.
The ramp maps darkness to density from left to right.  It must be nonempty
and single-line.  A canvas captures the ramp when it is built; changing this
default affects canvases built afterwards and does not repaint a mounted one.")

(defvar etaf-video--cached-ramp-table nil
  "Cached byte-to-character translation table, or nil.")
(defvar etaf-video--cached-ramp nil
  "Ramp the cached translation table was built from.")

(defvar etaf-video-render-backend 'image
  "Rendering backend for `etaf-video' Components.
`image' publishes one scaled JPEG per frame through the retained Host
content boundary, which is the established route.  `canvas' draws every
frame into one Emacs canvas image and refreshes it in place, so a frame
costs no JPEG encode, no decode and no Host publication; it needs an Emacs
whose `canvas' image type is available and a graphical frame.  `auto' picks
`canvas' when both hold and `image' otherwise.  Terminals always use the
text modes regardless of this value.")

(defun etaf-video--ramp-table (ramp)
  "Return RAMP's byte-to-character translation table.
RAMP is a nonempty single-line string; each byte selects the ramp character
nearest to its darkness.  Tables are cached per ramp."
  (unless (and (stringp ramp) (> (length ramp) 0)
               (not (string-match-p "\n" ramp)))
    (user-error "Video density ramp must be a nonempty single-line string: %S"
                ramp))
  (unless (and etaf-video--cached-ramp-table
               etaf-video--cached-ramp
               (equal etaf-video--cached-ramp ramp))
    (let ((table (make-char-table 'translation-table))
          (last (1- (length ramp))))
      (dotimes (byte 256)
        ;; (255 * last + 127) / 255 rounds the byte to the nearest ramp slot.
        (aset table byte (aref ramp (/ (+ (* byte last) 127) 255))))
      (setq etaf-video--cached-ramp-table table
            etaf-video--cached-ramp (copy-sequence ramp))))
  etaf-video--cached-ramp-table)

(defun etaf-video--ascii-grid-text (bytes columns rows ramp)
  "Return BYTES as ROWS lines of COLUMNS ramp characters.
BYTES holds COLUMNS times ROWS grayscale bytes.  The result carries no text
properties."
  (let ((buffer (generate-new-buffer " *etaf-video grid*")))
    (unwind-protect
        (with-current-buffer buffer
          (erase-buffer)
          (set-buffer-multibyte nil)
          (insert bytes)
          (translate-region (point-min) (point-max) (etaf-video--ramp-table ramp))
          (let ((row (1- rows)))
            (while (> row 0)
              (goto-char (1+ (* row columns)))
              (insert "\n")
              (setq row (1- row))))
          (buffer-substring-no-properties (point-min) (point-max)))
      (kill-buffer buffer))))

(defvar etaf-video--hex-pairs (make-vector 256 nil)
  "Two-digit lowercase hex text for every byte, indexed by value.")

(dotimes (byte 256)
  (aset etaf-video--hex-pairs byte (format "%02x" byte)))

(defun etaf-video--color-grid-text (bytes columns rows)
  "Return BYTES as ROWS lines of half-block cells with true color.
BYTES holds COLUMNS by twice ROWS RGB24 pixels in row-major order.  The top
pixel of each cell becomes the foreground of a `▀' character and the bottom
pixel its background, so one character cell shows two full-color pixels.
The result carries one `face' property per cell."
  (let ((text (mapconcat #'identity
                         (make-list rows (make-string columns ?▀))
                         "\n"))
        (hex etaf-video--hex-pairs)
        (position 0))
    (dotimes (row rows)
      (let ((top (* (* 2 row) columns 3))
            (bottom (* (1+ (* 2 row)) columns 3)))
        (dotimes (column columns)
          (let* ((top-offset (+ top (* column 3)))
                 (bottom-offset (+ bottom (* column 3))))
            (put-text-property
             position (1+ position) 'face
             (list :foreground
                   (concat "#" (aref hex (aref bytes top-offset))
                           (aref hex (aref bytes (+ top-offset 1)))
                           (aref hex (aref bytes (+ top-offset 2))))
                   :background
                   (concat "#" (aref hex (aref bytes bottom-offset))
                           (aref hex (aref bytes (+ bottom-offset 1)))
                           (aref hex (aref bytes (+ bottom-offset 2)))))
             text)
            (setq position (1+ position))))
        (when (< row (1- rows))
          (setq position (1+ position)))))
    text))

(defvar etaf-video--instances (make-hash-table :test #'eq)
  "Mounted `etaf-video' instances by handle.
The Component registers its instance after its first publication and removes
it on unmount, so the control functions always address a live session.")

(defvar etaf-video--content-id-counter 0
  "Number of allocated canvas Host ids, used to make each one unique.")

(defun etaf-video--next-content-id ()
  "Return a canvas Host id that is unique within this Emacs session."
  (format "etaf-video-canvas-%d" (cl-incf etaf-video--content-id-counter)))

(defun etaf-video--instance-for (handle)
  "Return the mounted video instance registered under HANDLE."
  (unless (and handle (symbolp handle))
    (user-error "Video handle must be a symbol: %S" handle))
  (or (gethash handle etaf-video--instances)
      (user-error "No mounted etaf-video for handle %S" handle)))

(defun etaf-video--session-for (handle)
  "Return the playback session registered under HANDLE."
  (let ((instance (etaf-video--instance-for handle)))
    (or (etaf-video--instance-session instance)
        (user-error "The etaf-video for handle %S has no session" handle))))

(cl-defstruct (etaf-video--instance (:constructor etaf-video--instance--make))
  "Mounted state owned by one `etaf-video' Component instance."
  handle ref cell sources runtime session applied autoplay image-scale
  image-max-width image-max-height image-last canvas-spec canvas-key)

(defun etaf-video--instance-view-content (instance)
  "Return INSTANCE's current canvas text for ordinary publications.
Retained frame updates write through `etaf-runtime-update-host-content'; an
ordinary publication renders this placeholder, and the next displayed frame
restores the picture."
  (or (car (etaf-video--instance-cell instance)) " "))

(defun etaf-video--instance-frame (instance)
  "Return the frame showing INSTANCE's buffer, or the selected frame."
  (let* ((runtime (etaf-video--instance-runtime instance))
         (buffer (and runtime (etaf-runtime-buffer runtime)))
         (window (and buffer (buffer-live-p buffer)
                      (get-buffer-window buffer t))))
    (if window (window-frame window) (selected-frame))))

(defun etaf-video--instance-graphic-p (instance)
  "Return non-nil when INSTANCE's buffer is shown in a graphical frame."
  (display-graphic-p (etaf-video--instance-frame instance)))

(defun etaf-video--control-value (source)
  "Read a playback control SOURCE without subscribing the View to its value."
  (if (or (etaf-ref-p source) (etaf-computed-p source))
      (etaf-value source)
    source))

(defun etaf-video--instance-read-inputs (instance)
  "Return INSTANCE's current tracked input values as a plist."
  (let ((sources (etaf-video--instance-sources instance)))
    (list :src (etaf-value (plist-get sources :src))
          :columns (etaf-value (plist-get sources :columns))
          :rows (etaf-value (plist-get sources :rows))
          :mode (etaf-value (plist-get sources :mode))
          :ramp (etaf-value (plist-get sources :ramp))
          :audio (etaf-video--control-value (etaf-value (plist-get sources :audio)))
          :volume (etaf-video--control-value (etaf-value (plist-get sources :volume)))
          :speed (etaf-video--control-value (etaf-value (plist-get sources :speed)))
          :device-pixel-ratio (etaf-value (plist-get sources :device-pixel-ratio))
          :display-fps (etaf-value (plist-get sources :display-fps)))))

(defun etaf-video--instance-effective-mode (instance)
  "Return INSTANCE's render mode after the graphic fallback.
An `image' canvas falls back to `ascii' when its buffer is not shown in a
graphical frame, so the same layout renders in terminals."
  (let ((mode (plist-get (etaf-video--instance-applied instance) :mode)))
    (if (and (eq mode 'image) (not (etaf-video--instance-graphic-p instance)))
        'ascii
      mode)))

(defvar etaf-video-canvas-module-file nil
  "Path of the loaded native canvas reader module, or nil.")

(defvar etaf-video--canvas-module-failed nil
  "Non-nil after a missing or broken canvas reader module was reported once.")

(defun etaf-video--canvas-module-extension ()
  "Return the native module file extension for this system."
  (pcase system-type
    ('darwin "dylib")
    ('windows-nt "dll")
    (_ "so")))

(defun etaf-video--canvas-module ()
  "Load and return the native canvas reader module, or nil.
The module is optional: a missing or unloadable one keeps the `image'
backend instead of breaking video playback."
  (unless etaf-video--canvas-module-failed
    (or etaf-video-canvas-module-file
        (let* ((root (ignore-errors
                       (file-name-directory (locate-library "etaf"))))
               (file (and root
                          (expand-file-name
                           (format "native/etaf-video-canvas.%s"
                                   (etaf-video--canvas-module-extension))
                           root))))
          (if (and file (file-exists-p file)
                   (condition-case nil
                       (progn (module-load file) t)
                     (error nil)))
              (setq etaf-video-canvas-module-file file)
            (setq etaf-video--canvas-module-failed t)
            nil)))))

(defun etaf-video--instance-canvas-p (instance)
  "Return non-nil when INSTANCE can draw into an Emacs canvas image."
  (and (image-type-available-p 'canvas)
       (etaf-video--canvas-module)
       (fboundp 'etaf-video-canvas-read)
       (etaf-video--instance-graphic-p instance)))

(defun etaf-video--instance-effective-backend (instance)
  "Return INSTANCE's rendering backend after the capability fallback.
A `canvas' or `auto' request falls back to `image' when this Emacs cannot
display canvas images or the buffer is not in a graphical frame."
  (if (and (memq etaf-video-render-backend '(canvas auto))
           (etaf-video--instance-canvas-p instance))
      'canvas
    'image))

(defun etaf-video--instance-effective-engine (instance)
  "Return INSTANCE's playback engine: `mpv' or `ffmpeg'."
  (let* ((applied (etaf-video--instance-applied instance))
         (src (plist-get applied :src))
         (kind (and (consp src) (plist-get src :kind)))
         (demo-p (or (null src) (eq kind 'demo)
                     (and (consp src) (or (eq (car src) :demo) (plist-get src :demo)))))
         (mode (etaf-video--instance-effective-mode instance)))
    (pcase etaf-video-engine
      ('ffmpeg 'ffmpeg)
      ('mpv (if demo-p 'ffmpeg 'mpv))
      (_ (if (and (not demo-p)
                  (eq mode 'image)
                  (etaf-video--instance-graphic-p instance)
                  (or (etaf-video--instance-canvas-p instance)
                      (image-type-available-p 'pbm))
                  (etaf-video-mpv-available-p))
             'mpv
           'ffmpeg)))))

(defun etaf-video--canvas-cell (runtime frame)
  "Return the cell RUNTIME draws as (CHAR-WIDTH . LINE-HEIGHT) pixels.
FRAME answers only when no canvas is mounted.  A video canvas states its rows
in its own cells, so measuring them with the frame's face sizes the picture,
the slices and the canvas spec apart from the rows they occupy."
  (let ((metrics (and runtime (ignore-errors (etaf-display-metrics runtime)))))
    (cons (max 1 (or (plist-get metrics :char-width) (frame-char-width frame)))
          (max 1 (or (plist-get metrics :line-height)
                     (frame-char-height frame))))))

(defun etaf-video--instance-display-size (instance)
  "Return INSTANCE's canvas size in pixels as `(WIDTH . HEIGHT)'.
The canvas renders at its own cell size, except that a canvas wider than
the window body is clamped by Ebox to the viewport; an image frame must fit
the smaller of the two.  HEIGHT is capped to the window body as well, though
a taller canvas is clipped by the layout anyway."
  (let* ((applied (etaf-video--instance-applied instance))
         (columns (plist-get applied :columns))
         (rows (plist-get applied :rows))
         (frame (etaf-video--instance-frame instance))
         (runtime (etaf-video--instance-runtime instance))
         (buffer (and runtime (etaf-runtime-buffer runtime)))
         (window (and buffer (buffer-live-p buffer)
                      (get-buffer-window buffer t)))
         (cell (etaf-video--canvas-cell runtime frame))
         (char-width (car cell))
         (char-height (cdr cell))
         (width (* columns char-width))
         (height (* rows char-height)))
    (cons (if window (min width (window-body-width window t)) width)
          (if window
              (min height (* (window-body-height window) char-height))
            height))))

(defun etaf-video--instance-pixel-frame-size (instance format &optional ratio)
  "Return INSTANCE's pixel frame size for FORMAT.
WIDTH and HEIGHT are producer pixels; SCALE maps device pixels back to
logical pixels for display, and the last two elements are the display
WIDTH and HEIGHT in logical pixels.  RATIO overrides the device pixel
ratio; a canvas producer must match the canvas buffer, which stays at
logical resolution."
  (let* ((applied (etaf-video--instance-applied instance))
         (columns (plist-get applied :columns))
         (rows (plist-get applied :rows))
         (frame (etaf-video--instance-frame instance))
         (ratio (or ratio
                    (plist-get applied :device-pixel-ratio)
                    (ignore-errors (frame-scale-factor frame))
                    1.0))
         (display (etaf-video--instance-display-size instance))
         (cell (etaf-video--canvas-cell
                (etaf-video--instance-runtime instance) frame))
         (width (if display (car display)
                  (max 1 (* columns (car cell)))))
         (height (if display (cdr display)
                   (max 1 (* rows (cdr cell))))))
    (list format
          (max 1 (round (* width ratio)))
          (max 1 (round (* height ratio)))
          (if (> ratio 0) (/ 1.0 ratio) 1.0)
          width height)))

(defun etaf-video--instance-frame-size (instance)
  "Return INSTANCE's `(FORMAT WIDTH HEIGHT SCALE MAX-WIDTH MAX-HEIGHT)'.
WIDTH and HEIGHT are producer pixels; SCALE maps device pixels back to
logical pixels for image display, and MAX-WIDTH and MAX-HEIGHT cap the
displayed image (nil for the raw modes)."
  (let* ((applied (etaf-video--instance-applied instance))
         (columns (plist-get applied :columns))
         (rows (plist-get applied :rows))
         (engine (etaf-video--instance-effective-engine instance)))
    (cond
     ((eq engine 'mpv)
      (if (eq (etaf-video--instance-effective-backend instance) 'canvas)
          (etaf-video--instance-pixel-frame-size instance 'canvas 1.0)
        (pcase (etaf-video--instance-effective-mode instance)
          ('image (etaf-video--instance-pixel-frame-size
                   instance 'ppm (or (plist-get applied :device-pixel-ratio) 1.0)))
          ('color (list 'rgb24 columns (* 2 rows) 1.0 nil nil))
          (_ (list 'gray columns rows 1.0 nil nil)))))
     ((eq (etaf-video--instance-effective-backend instance) 'canvas)
      ;; The canvas buffer is logical-resolution, so the producer must
      ;; write exactly that many pixels; a device-resolution frame would
      ;; overflow the canvas and crash the module.
      (etaf-video--instance-pixel-frame-size instance 'bgra 1.0))
     (t
      (pcase (etaf-video--instance-effective-mode instance)
        ('image (etaf-video--instance-pixel-frame-size instance 'mjpeg))
        ('color (list 'rgb24 columns (* 2 rows) 1.0 nil nil))
        (_ (list 'gray columns rows 1.0 nil nil)))))))

(defun etaf-video--image-ascent (frame &optional line)
  "Return the image ascent percentage that keeps a row at the canvas line.
LINE is that line's height in pixels; it defaults to FRAME's own.
A canvas row usually shares its buffer line with application text, and a line
grows to the sum of the largest ascent and the largest descent it holds.  The
default font's own ascent and descent are therefore the whole row an image
may occupy; aligning the image to that baseline keeps the line exactly one
character high instead of pushing the rows below the canvas off the window."
  (let* ((height (max 1 (or line
                            ;; A caller with no canvas line left sits on the
                            ;; frame's own row.
                            (frame-char-height frame)))) ; frame metric
         (info (ignore-errors (font-info (face-font 'default frame))))
         (ascent (and (vectorp info) (> (length info) 9) (aref info 8)))
         (descent (and (vectorp info) (> (length info) 9) (aref info 9))))
    (if (and (numberp ascent) (numberp descent) (numberp height)
             (> height 0) (> ascent 0) (>= descent 0))
        (min 100 (max 1 (ceiling (* 100.0 (/ (float ascent) height)))))
      82)))

(defun etaf-video--image-grid-text (instance image)
  "Return INSTANCE's canvas text cropping IMAGE into one cell per row.
One frame image is many character rows tall while a buffer line holds one
row, so publishing the image whole would push every line below the canvas
past the window edge.  Slicing the frame into IMAGE's own character rows
keeps the canvas exactly `rows' lines tall, which is what lets a caller
place chrome under it."
  (let* ((applied (etaf-video--instance-applied instance))
         (rows (max 1 (or (plist-get applied :rows) 1)))
         (frame (etaf-video--instance-frame instance))
         (row-height (cdr (etaf-video--canvas-cell
                           (etaf-video--instance-runtime instance) frame)))
         (display (etaf-video--instance-display-size instance))
         (width (max 1 (or (car-safe display) 1)))
         (height (max 1 (or (cdr-safe display) row-height))))
    (mapconcat
     (lambda (row)
       (let ((y (* row row-height)))
         (if (>= y height)
             " "
           (propertize
            " "
            'display
            (list (list 'slice 0 y width (min row-height (- height y)))
                  image)))))
     (number-sequence 0 (1- rows))
     "\n")))

(defun etaf-video--instance-present (instance frame)
  "Draw FRAME for INSTANCE through its effective backend."
  (if (eq (etaf-video--instance-effective-backend instance) 'canvas)
      (if (etaf-video-mpv--session-p (etaf-video--instance-session instance))
          (when (and frame (etaf-video--instance-runtime instance)
                     (etaf-runtime-mounted-p (etaf-video--instance-runtime instance)))
            (canvas-refresh frame)
            (redisplay))
        (etaf-video--instance-present-canvas instance frame))
    (etaf-video--instance-present-image instance frame)))

(defun etaf-video--display-canvas (display)
  "Return the canvas image spec nested in DISPLAY, or nil.
Ebox may wrap the published descriptor in raise and slice modifiers, so
search the whole display value instead of assuming one nesting depth."
  (cond
   ((and (consp display) (eq (car display) 'image)
         (eq (plist-get (cdr display) :type) 'canvas))
    display)
   ((consp display)
    (seq-some #'etaf-video--display-canvas display))
   (t nil)))

(defun etaf-video--instance-canvas-display (instance)
  "Return the canvas image spec the Host displays for INSTANCE, or nil.
The text property holds a copy of the spec that was published, and a canvas
is refreshed through that displayed object, not through the object the
publisher kept."
  (let* ((runtime (etaf-video--instance-runtime instance))
         (buffer (and runtime (etaf-runtime-buffer runtime))))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (catch 'canvas
            (while (< (point) (point-max))
              (when-let* ((spec (etaf-video--display-canvas
                                 (get-text-property (point) 'display))))
                (throw 'canvas spec))
              (goto-char (or (next-single-property-change
                              (point) 'display nil (point-max))
                             (point-max))))
            nil))))))

(defun etaf-video--make-canvas-spec (columns rows _ratio)
  "Return a canvas image spec for COLUMNS by ROWS character cells.
The buffer stays at logical resolution: the NS backend re-uploads every
pixel on refresh, so a device-resolution canvas costs four times more per
frame for no visible gain in a text host.  The :id stays stable so one Ebox
image host can refresh the same buffer in place."
  (let* ((frame (selected-frame))
         (metrics (ignore-errors (etaf-display-metrics)))
         (char-width (max 1 (or (plist-get metrics :char-width)
                                (frame-char-width frame))))
         (char-height (max 1 (or (plist-get metrics :line-height)
                                 (frame-char-height frame))))
         (width (* columns char-width))
         (height (* rows char-height)))
    (list 'image :type 'canvas
          :id (make-symbol "etaf-video-canvas")
          :data (make-string (* width height 4) 0)
          :data-width width :data-height height
          :scale 1.0
          :ascent (etaf-video--image-ascent frame char-height))))

(defun etaf-video--instance-ensure-canvas (instance)
  "Return INSTANCE's canvas image spec, creating it for the current size.
The spec carries a live pixel buffer that the producer writes into; its :id
stays stable so an Ebox image host keeps one preparation across frames."
  (let ((key (etaf-video--instance-frame-size instance))
        (spec (etaf-video--instance-canvas-spec instance)))
    (unless (and spec (equal key (etaf-video--instance-canvas-key instance)))
      ;; A new spec means the old pixel buffer is gone.
      (etaf-video--instance-canvas-fd-closed instance)
      (setf (etaf-video--instance-canvas-key instance) key))
    spec))

(defun etaf-video--instance-canvas-fd-closed (instance)
  "Release INSTANCE's canvas fifo reader after its spec was replaced."
  (when-let* ((session (etaf-video--instance-session instance))
              (source (etaf-video--session-source session))
              (fd (etaf-video--source-canvas-fd source)))
    (ignore-errors (etaf-video-canvas-close fd))
    (setf (etaf-video--source-canvas-fd source) nil)))

(defun etaf-video--instance-present-canvas (instance _frame)
  "Refresh INSTANCE's canvas from the frame its producer wrote into it.
FRAME is ignored: the native reader has already copied the newest BGRA frame
into the canvas pixel buffer, so a presented tick only refreshes the image
host that Ebox prepared for the spec."
  (let ((runtime (etaf-video--instance-runtime instance))
        ;; Ebox publishes a copy of the spec inside the prepared raster, and
        ;; a canvas is keyed by its spec object, so write into the copy the
        ;; buffer actually displays.  They share one pixel string, but only
        ;; the displayed object owns the canvas that redisplay shows.
        (spec (or (etaf-video--instance-canvas-display instance)
                  (etaf-video--instance-canvas-spec instance))))
    (when (and runtime (etaf-runtime-mounted-p runtime) spec)
      (let* ((session (etaf-video--instance-session instance))
             (source (and session (etaf-video--session-source session)))
             (read (and source (etaf-video--source-fifo source)
                        (condition-case nil
                            (etaf-video--source-read-canvas source spec)
                          (error 0)))))
        (when (and read (> read 0))
          (canvas-refresh spec)
          (redisplay))))))

(defun etaf-video--instance-present-image (instance frame)
  "Map FRAME for INSTANCE's effective mode and publish it.
The retained content update replaces only the canvas Host, so one displayed
frame does not pay for an ordinary ETAF publication."
  (let ((runtime (etaf-video--instance-runtime instance)))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (let* ((applied (etaf-video--instance-applied instance))
             (cell (etaf-video--instance-cell instance))
             (ref (etaf-video--instance-ref instance))
             (mode (etaf-video--instance-effective-mode instance))
             (session (etaf-video--instance-session instance))
             (img-type (if (and (etaf-video-mpv--session-p session)
                                (eq (etaf-video-mpv--session-format session) 'ppm))
                           'pbm
                         'jpeg))
             (image (and (eq mode 'image)
                         (let ((win-frame (etaf-video--instance-frame instance)))
                           (create-image frame img-type t
                                         :ascent (etaf-video--image-ascent
                                                  win-frame
                                                  (cdr (etaf-video--canvas-cell
                                                        runtime win-frame)))
                                         :scale (etaf-video--instance-image-scale instance)
                                         :max-width (etaf-video--instance-image-max-width instance)
                                         :max-height (etaf-video--instance-image-max-height instance)))))
             (content
              (pcase mode
                ('image (etaf-video--image-grid-text instance image))
                ('color
                 (etaf-video--color-grid-text
                  frame
                  (plist-get applied :columns)
                  (plist-get applied :rows)))
                (_
                 (etaf-video--ascii-grid-text
                  frame
                  (plist-get applied :columns)
                  (plist-get applied :rows)
                  (plist-get applied :ramp))))))
        (setcar cell content)
        (condition-case problem
            (progn
              (etaf-runtime-update-host-content runtime ref content)
              ;; Emacs caches every image spec it has displayed.  A video
              ;; presents a new spec per frame, so the previous frame is
              ;; flushed as soon as the new one is committed; otherwise a long
              ;; video grows the image cache for as long as its eviction delay
              ;; and holds every decoded frame in memory.
              (when-let* ((previous (etaf-video--instance-image-last instance)))
                (ignore-errors (image-flush previous)))
              (setf (etaf-video--instance-image-last instance) image))
          (etaf-runtime-error
           (let ((sess (etaf-video--instance-session instance)))
             (if (etaf-video-mpv--session-p sess)
                 (etaf-video-mpv--session-destroy sess)
               (etaf-video-session-destroy sess)))
           (message "etaf-video: %s" (error-message-string problem))))))))

(defun etaf-video--instance-register (instance)
  "Register INSTANCE's handle, refusing a handle owned by another video."
  (let ((handle (etaf-video--instance-handle instance)))
    (let ((existing (gethash handle etaf-video--instances)))
      (when (and existing (not (eq existing instance)))
        (user-error "An etaf-video is already mounted for handle %S" handle)))
    (puthash handle instance etaf-video--instances)))

(defun etaf-video--session-destroy-any (session)
  "Destroy SESSION whether backed by libmpv or ffmpeg."
  (when session
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-destroy session)
      (etaf-video-session-destroy session))))

(defun etaf-video--session-state-any (session)
  "Read detached state plist from SESSION whether libmpv or ffmpeg."
  (if (etaf-video-mpv--session-p session)
      (etaf-video-mpv--session-state session)
    (append (list :engine 'ffmpeg) (etaf-video-session-state session))))

(defun etaf-video--instance-build (instance &optional start playing)
  "Create INSTANCE's playback session from its applied inputs.
START is the seek position in seconds and PLAYING says whether the new
session starts playing; a paused session presents one frame instead."
  (let* ((applied (etaf-video--instance-applied instance))
         (size (etaf-video--instance-frame-size instance))
         (engine (etaf-video--instance-effective-engine instance))
         (session
          (if (eq engine 'mpv)
              (etaf-video-mpv--session-create
               (etaf-video-source-info (plist-get applied :src))
               :format (nth 0 size)
               :width (nth 1 size)
               :height (nth 2 size)
               :speed (plist-get applied :speed)
               :fps (plist-get applied :display-fps)
               :start (or start 0)
               :audio (plist-get applied :audio)
               :volume (plist-get applied :volume)
               :playing playing
               :canvas-spec-fn (lambda ()
                                 (or (etaf-video--instance-canvas-display instance)
                                     (etaf-video--instance-canvas-spec instance)))
               :on-frame (lambda (frame _session)
                           (etaf-video--instance-present instance frame)))
            (etaf-video-session-create
             (plist-get applied :src)
             :format (nth 0 size)
             :width (nth 1 size)
             :height (nth 2 size)
             :speed (plist-get applied :speed)
             :fps (plist-get applied :display-fps)
             :start (or start 0)
             :canvas (eq (etaf-video--instance-effective-backend instance)
                         'canvas)
             :audio (plist-get applied :audio)
             :volume (plist-get applied :volume)
             :on-frame (lambda (frame _session)
                         (etaf-video--instance-present instance frame))))))
    (setf (etaf-video--instance-session instance) session
          (etaf-video--instance-image-scale instance) (nth 3 size)
          (etaf-video--instance-image-max-width instance) (nth 4 size)
          (etaf-video--instance-image-max-height instance) (nth 5 size))
    (unless (eq engine 'mpv)
      (if playing
          (etaf-video-session-play session)
        (etaf-video-session-step session)))))

(defun etaf-video--source-start-offset (src)
  "Return initial seek offset in seconds declared on SRC, or 0."
  (let ((start (and (consp src) (plist-get src :start))))
    (if (and (numberp start) (>= start 0)) start 0)))

(defun etaf-video--instance-mount (instance autoplay)
  "Mount INSTANCE, start its session and honor AUTOPLAY."
  (setf (etaf-video--instance-runtime instance) (etaf-current-runtime)
        (etaf-video--instance-autoplay instance) (and autoplay t))
  (etaf-video--instance-register instance)
  (setf (etaf-video--instance-applied instance)
        (etaf-video--instance-read-inputs instance))
  (when (eq (etaf-video--instance-effective-backend instance) 'canvas)
    (setf (etaf-video--instance-canvas-spec instance)
          (etaf-value (plist-get (etaf-video--instance-sources instance)
                                 :canvas)))
    (etaf-video--instance-ensure-canvas instance))
  (etaf-video--instance-build
   instance
   (etaf-video--source-start-offset
    (plist-get (etaf-video--instance-applied instance) :src))
   autoplay))

(defun etaf-video--instance-unmount (instance)
  "Release INSTANCE's session and handle registration."
  (when-let* ((image (etaf-video--instance-image-last instance)))
    (ignore-errors (image-flush image))
    (setf (etaf-video--instance-image-last instance) nil))
  (setf (etaf-video--instance-canvas-spec instance) nil
        (etaf-video--instance-canvas-key instance) nil)
  (when-let* ((session (etaf-video--instance-session instance)))
    (etaf-video--session-destroy-any session)
    (setf (etaf-video--instance-session instance) nil))
  (let ((handle (etaf-video--instance-handle instance)))
    (when (eq (gethash handle etaf-video--instances) instance)
      (remhash handle etaf-video--instances)))
  (setf (etaf-video--instance-runtime instance) nil))

(defun etaf-video--instance-apply (instance inputs)
  "Apply new tracked INPUTS to INSTANCE.
A source change rebuilds the session at the start of the new source.  On
libmpv, size changes resize the output surface in place without restarting
playback; on ffmpeg, size, mode, ramp or device pixel ratio changes rebuild
at the current position.  Speed, volume and audio update in place."
  (let ((old (etaf-video--instance-applied instance)))
    (unless (equal old inputs)
      (let* ((session (etaf-video--instance-session instance))
             (mpv-p (etaf-video-mpv--session-p session))
             (src-changed (not (equal (plist-get old :src) (plist-get inputs :src))))
             (size-changed (or (not (equal (plist-get old :columns) (plist-get inputs :columns)))
                               (not (equal (plist-get old :rows) (plist-get inputs :rows)))
                               (not (equal (plist-get old :device-pixel-ratio)
                                           (plist-get inputs :device-pixel-ratio)))))
             (mode-changed (or (not (equal (plist-get old :mode) (plist-get inputs :mode)))
                               (not (equal (plist-get old :ramp) (plist-get inputs :ramp)))
                               (not (equal (plist-get old :display-fps)
                                           (plist-get inputs :display-fps)))))
             (structural (or src-changed mode-changed (and size-changed (not mpv-p)))))
        (setf (etaf-video--instance-applied instance) inputs)
        (cond
         ((and mpv-p size-changed (not src-changed) (not mode-changed))
          (let ((size (etaf-video--instance-frame-size instance)))
            (setf (etaf-video--instance-image-scale instance) (nth 3 size)
                  (etaf-video--instance-image-max-width instance) (nth 4 size)
                  (etaf-video--instance-image-max-height instance) (nth 5 size))
            (etaf-video-mpv--session-resize session (nth 1 size) (nth 2 size))))
         (structural
          (when session
            (let* ((state (etaf-video--session-state-any session))
                   (duration (plist-get state :duration))
                   (playing (if src-changed
                                (or (plist-get state :playing)
                                    (etaf-video--instance-autoplay instance))
                              (plist-get state :playing)))
                   (position
                    (cond (src-changed
                           (etaf-video--source-start-offset (plist-get inputs :src)))
                          ((and (not playing) duration
                                (or (plist-get state :ended)
                                    (>= (plist-get state :position) duration)))
                           (max 0 (- duration
                                     (/ 1.0 (or (plist-get state :source-fps) 25)))))
                          (t (plist-get state :position)))))
              (etaf-video--session-destroy-any session)
              (setf (etaf-video--instance-session instance) nil)
              (when (etaf-video--instance-runtime instance)
                (etaf-video--instance-build instance position playing)))))
         (session
          (unless (equal (plist-get old :speed) (plist-get inputs :speed))
            (if mpv-p
                (etaf-video-mpv--session-set-speed session (plist-get inputs :speed))
              (etaf-video-session-set-speed session (plist-get inputs :speed))))
          (unless (equal (plist-get old :volume) (plist-get inputs :volume))
            (if mpv-p
                (etaf-video-mpv--session-set-volume session (plist-get inputs :volume))
              (etaf-video-session-set-volume session (plist-get inputs :volume))))
          (unless (equal (plist-get old :audio) (plist-get inputs :audio))
            (if mpv-p
                (etaf-video-mpv--session-set-audio session (plist-get inputs :audio))
              (etaf-video-session-set-audio session (plist-get inputs :audio))))))))))

(etaf-define-component etaf-video
    (&key src (columns 100) (rows 30) (mode 'image)
          (ramp etaf-video-density-ramp)
          (audio etaf-video-audio) (volume etaf-video-audio-volume) (speed 1)
          (autoplay t) handle device-pixel-ratio display-fps
          position left top z-index)
  "Render a live video source in a fixed COLUMNS by ROWS canvas.

SRC is nil for the built-in demo, a local file name, an HTTP(S) URL, or a
plist accepted by the video source normalizer; a normalized metadata plist
from `etaf-video-source-info' mounts without another probe.  MODE selects
how the canvas renders:
`image' shows one scaled JPEG per frame and needs a graphical frame (it falls
back to `ascii' otherwise), `ascii' maps each pixel to one density-ramp
character, and `color' shows two full-color pixels per `▀' half-block cell.
DENSITY-RAMP defaults to `etaf-video-density-ramp'.

AUDIO, VOLUME and SPEED configure the running playback; AUTOPLAY starts it
as soon as the Component is mounted, otherwise the first frame is shown
paused.  DISPLAY-FPS caps the presented frame rate, defaulting to
`etaf-video-display-fps'.  DEVICE-PIXEL-RATIO overrides the display's device
pixel ratio for `image' frames, defaulting to `frame-scale-factor' so Retina
displays stay sharp.

POSITION, LEFT, TOP and Z-INDEX place the canvas; they are declared on the
canvas node itself so the retained content route can prove an inline
placement winner and publish frames without an ordinary publication.

HANDLE is a symbol used by the `etaf-video-play' family of control
functions; the Component registers it while mounted.  Without HANDLE the
video still plays itself but cannot be controlled."

  :validate
  (progn
    (etaf-check-prop :columns columns
                     (and (integerp columns) (> columns 0))
                     "a positive integer")
    (etaf-check-prop :rows rows
                     (and (integerp rows) (> rows 0))
                     "a positive integer")
    (etaf-check-prop :mode mode
                     (memq mode '(image ascii color))
                     "image, ascii or color")
    (etaf-check-prop :ramp ramp
                     (and (stringp ramp) (> (length ramp) 0)
                          (not (string-match-p "\n" ramp)))
                     "a nonempty single-line string")
    (etaf-check-prop :volume volume
                     (or (etaf-ref-p volume) (etaf-computed-p volume)
                         (and (numberp volume) (<= 0 volume 100)))
                     "a number between 0 and 100, or a reactive source")
    (etaf-check-prop :speed speed
                     (or (etaf-ref-p speed) (etaf-computed-p speed)
                         (and (numberp speed) (> speed 0)))
                     "a positive number, or a reactive source")
    (etaf-check-prop :handle handle
                     (or (null handle) (symbolp handle))
                     "nil or a symbol")
    (etaf-check-prop :display-fps display-fps
                     (or (null display-fps)
                         (and (integerp display-fps) (> display-fps 0)))
                     "nil or a positive integer")
    (etaf-check-prop :device-pixel-ratio device-pixel-ratio
                     (or (null device-pixel-ratio)
                         (and (numberp device-pixel-ratio)
                              (> device-pixel-ratio 0)))
                     "nil or a positive number"))

  :bindings
  ((src-input (etaf-prop 'src))
   (columns-input (etaf-prop 'columns))
   (rows-input (etaf-prop 'rows))
   (mode-input (etaf-prop 'mode))
   (ramp-input (etaf-prop 'ramp))
   (audio-input (etaf-prop 'audio))
   (volume-input (etaf-prop 'volume))
   (speed-input (etaf-prop 'speed))
   (ratio-input (etaf-prop 'device-pixel-ratio))
   (fps-input (etaf-prop 'display-fps))
   (content-ref (etaf-local-ref 'content))
   (content-id (etaf-video--next-content-id))
   (canvas-input (etaf-computed
                  (lambda ()
                    (etaf-video--make-canvas-spec
                     (etaf-value columns-input)
                     (etaf-value rows-input)
                     (etaf-value ratio-input)))
                  :name 'canvas-spec))
   (instance (etaf-video--instance--make
              :handle (or handle (make-symbol "etaf-video"))
              :ref content-ref
              :cell (cons " " nil)
              :sources (list :src src-input :columns columns-input
                             :rows rows-input :mode mode-input
                             :ramp ramp-input :audio audio-input
                             :volume volume-input :speed speed-input
                             :device-pixel-ratio ratio-input
                             :display-fps fps-input
                             :canvas canvas-input))))

  :setup
  (progn
    (etaf-on-mounted
     (lambda () (etaf-video--instance-mount instance autoplay)))
    (etaf-on-unmounted
     (lambda () (etaf-video--instance-unmount instance)))
    ;; Inputs are tracked through the Component's own sources, so a change
    ;; republishes first and only then restarts or retunes the session.  The
    ;; watcher runs the getter directly so every changed prop source can
    ;; reach it without an intermediate cached computed.
    (etaf-watch-effect
     (lambda ()
       (etaf-video--instance-apply instance (etaf-video--instance-read-inputs instance))
       nil)
     :name 'etaf-video-inputs))

  :view
  ;; Placement is declared on the canvas node itself so Ebox's retained
  ;; content route can prove an inline placement winner; a call-site prop
  ;; that only reaches the node through component scoping would keep a
  ;; playing canvas on the ordinary publication route.
  (box :width (list 'ch columns)
       :height (list 'lh rows)
       :position (or position 'static)
       :left (or left '(px 0))
       :top (or top '(lh 0))
       :z-index (or z-index 0)
       :wrap-mode 'none
       :overflow 'hidden
       :background-color "#050607"
    ;; A canvas is exactly one image host: Ebox's text renderer turns an
    ;; image display inside text into an empty width placeholder, so the
    ;; frame must be prepared as an image instead.
    (image :if (eq (etaf-video--instance-effective-backend instance) 'canvas)
           :src (etaf-value canvas-input)
           :columns columns :rows rows)
    (text :if (not (eq (etaf-video--instance-effective-backend instance) 'canvas))
          :ref content-ref :id content-id
          (expr (etaf-video--instance-view-content instance)))))

(defun etaf-video-play (handle)
  "Start or resume the mounted video identified by HANDLE."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-play session)
      (etaf-video-session-play session)))
  t)

(defun etaf-video-pause (handle)
  "Pause the mounted video identified by HANDLE."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-pause session)
      (etaf-video-session-pause session)))
  t)

(defun etaf-video-toggle-playback (handle)
  "Toggle the mounted video identified by HANDLE between play and pause.
A finished video restarts from its beginning."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-toggle session)
      (etaf-video-session-toggle session)))
  t)

(defun etaf-video-step (handle)
  "Pause the mounted video identified by HANDLE and present one more frame."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-step session)
      (etaf-video-session-step session)))
  t)

(defun etaf-video-step-back (handle)
  "Pause the mounted video identified by HANDLE and step backward one frame.
Requires the libmpv engine; on the ffmpeg backend this seeks back 1 second."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-step-back session)
      (let ((pos (max 0.0 (- (or (plist-get (etaf-video-session-state session) :position) 0.0) 1.0))))
        (etaf-video-session-pause session)
        (etaf-video-session-seek session pos))))
  t)

(defun etaf-video-seek (handle seconds)
  "Move the mounted video identified by HANDLE to SECONDS."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-seek session seconds)
      (etaf-video-session-seek session seconds)))
  t)

(defun etaf-video-set-speed (handle speed)
  "Set the playback rate of the mounted video identified by HANDLE."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-set-speed session speed)
      (etaf-video-session-set-speed session speed)))
  t)

(defun etaf-video-set-volume (handle volume)
  "Set the audio volume of the mounted video identified by HANDLE, 0 to 100."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-set-volume session volume)
      (etaf-video-session-set-volume session volume)))
  t)

(defun etaf-video-set-audio (handle audio)
  "Turn audio of the mounted video identified by HANDLE on or off."
  (let ((session (etaf-video--session-for handle)))
    (if (etaf-video-mpv--session-p session)
        (etaf-video-mpv--session-set-audio session audio)
      (etaf-video-session-set-audio session audio)))
  t)

(defun etaf-video-set-property (handle name value)
  "Set playback engine property NAME to VALUE on mounted video HANDLE.
Supported on the libmpv engine (returns t on success, nil when unsupported)."
  (let ((session (etaf-video--session-for handle)))
    (when (etaf-video-mpv--session-p session)
      (etaf-video-mpv--session-set-property session name value))))

(defun etaf-video-get-property (handle name &optional type)
  "Read playback engine property NAME from mounted video HANDLE.
TYPE is `node' (default), `string', `bool', `int' or `float'.  Returns nil on
engines that do not expose properties."
  (let ((session (etaf-video--session-for handle)))
    (when (etaf-video-mpv--session-p session)
      (etaf-video-mpv--session-get-property session name type))))

(defun etaf-video-command (handle &rest args)
  "Send command ARGS to the playback engine of mounted video HANDLE.
Supported on the libmpv engine; returns nil on engines without commands."
  (let ((session (etaf-video--session-for handle)))
    (when (etaf-video-mpv--session-p session)
      (etaf-video-mpv--session-command session args))))

(defun etaf-video-state (handle)
  "Return the mounted video identified by HANDLE as a detached plist.
Keys include `:handle', `:engine', `:mode', `:source', `:playing',
`:position', `:duration', `:speed', `:format', `:width', `:height',
`:display-fps', `:source-fps', `:received', `:presented', `:dropped',
`:audio', `:buffering', `:error' and `:ended'."
  (let ((instance (etaf-video--instance-for handle)))
    (append (list :handle handle
                  :mode (etaf-video--instance-effective-mode instance))
            (etaf-video--session-state-any (etaf-video--session-for handle)))))

(provide 'etaf-video-component)
;;; etaf-video-component.el ends here
