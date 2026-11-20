;;; ebox-image.el --- Prepared character-grid image content -*- lexical-binding: t; -*-

;;; Commentary:
;; Image preparation owns I/O, capability selection and immutable cell rasters.
;; Image nodes and text content lay out prepared lines without source I/O.
;; Paint may derive cached, in-memory SVG brightness composites; it never
;; rereads a file or starts an external converter.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)
(require 'xml)
(require 'ansi-color)
(require 'ebox-measure)

;; Native image primitives are absent from text-only Emacs builds. They are
;; used only after graphical capability selection, not for the text adapter.
(declare-function image-size "image.c" (spec &optional pixels frame))
(defvar image-types)

(cl-defstruct (ebox-image--prepared (:constructor ebox-image--make-prepared)
                                    (:copier nil))
  "Immutable, detached raster prepared for one character allocation.
IDENTITY makes distinct preparations unequal: `equal' ignores the text
properties that carry their pixels, so two images of one size would
otherwise compare equal and an update to the other one would be skipped."
  (identity (make-symbol "ebox-image"))
  columns rows adapter converter text lines width)

(defvar ebox-image--background nil
  "Background color graphical images were most recently composited over.
Layout records it; preparation decodes new graphics for it, so images on one
background decode once instead of once more for a background variant.")

(defvar ebox-image-converters
  '((chafa . ebox-image--chafa) (ffmpeg . ebox-image--ffmpeg))
  "Ordered (NAME . FUNCTION) image converters, called only by preparation.
FUNCTION receives SOURCE, COLUMNS, ROWS.  SOURCE is a local absolute file name
or an owned Emacs image descriptor.  Return nil to decline, or a string of
exactly ROWS lines of COLUMNS `▀' characters, each with a `face' plist
containing 24-bit :foreground and :background strings (#RRGGBB).
No trailing newline.
Errors and malformed results decline to the next converter.  Functions must
not mutate SOURCE.  Change NAME or clear the image cache when behavior changes.
The defaults try chafa's truecolor symbols, then ffmpeg's scaled raw RGB.
Neither executable is a package dependency; nil selects the placeholder.")

(defvar ebox-image--cache (make-hash-table :test #'equal)
  "Bounded cache of prepared image rasters, independent of mounted buffers.
Each entry is (LAST-USE . PREPARED): the bounded cache keeps the most
recently used preparations, so a screen holding more images than the old
fixed count does not evict every unrelated one on each preparation.")

(defconst ebox-image--cache-limit 256
  "Maximum cached preparations; live prepared values survive eviction.")

(defconst ebox-image--cache-evict 32
  "Entries dropped when the cache exceeds `ebox-image--cache-limit'.")

(defvar ebox-image--cache-uses 0
  "Monotonic access stamp marking the least recently used cache entries.")

(defun ebox-image--cache-take (key)
  "Return the cached preparation for KEY and mark it recently used."
  (let ((cell (gethash key ebox-image--cache)))
    (when cell
      (setcar cell (cl-incf ebox-image--cache-uses))
      (cdr cell))))

(defun ebox-image--cache-put (key prepared)
  "Cache PREPARED for KEY, dropping the least recently used entries."
  (puthash key (cons (cl-incf ebox-image--cache-uses) prepared) ebox-image--cache)
  (when (> (hash-table-count ebox-image--cache) ebox-image--cache-limit)
    (let ((stamps nil))
      (maphash (lambda (item cell) (push (cons (car cell) item) stamps))
               ebox-image--cache)
      (setq stamps (sort stamps (lambda (left right) (< (car left) (car right)))))
      (dotimes (_ (min (length stamps)
                       (max 1 ebox-image--cache-evict)))
        (remhash (cdr (car stamps)) ebox-image--cache)
        (setq stamps (cdr stamps))))))

(defvar ebox-image--composites (make-hash-table :test 'eq :weakness 'key)
  "Paint variants keyed by immutable image or display identity.
Each live source retains at most eight recent parameter variants.  Keys
contain only paint parameters, never nodes, input handlers or mounted trees.")

(defun ebox-image--composite (source key make)
  "Return SOURCE's cached KEY variant, or build it once with MAKE."
  (let* ((variants (gethash source ebox-image--composites))
         (entry (assoc key variants)))
    (unless entry (setq entry (cons key (funcall make))))
    (setq variants (cons entry (delq entry (gethash source ebox-image--composites))))
    (when (> (length variants) 8) (setcdr (nthcdr 7 variants) nil))
    (puthash source variants ebox-image--composites)
    (cdr entry)))

(defun ebox-image-cache-clear ()
  "Release cached preparations and composites without changing live images.
Call after installing converters or changing their configuration."
  (clrhash ebox-image--cache)
  (clrhash ebox-image--composites)
  (setq ebox-image--cache-uses 0))

(defun ebox-image--source (source)
  "Validate SOURCE and return an owned source and its cache identity."
  (cond
   ((stringp source)
    (when (file-remote-p source)
      (error "Ebox image sources must be local files"))
    (let* ((path (expand-file-name source))
           (attrs (file-attributes path 'integer)))
      (list path
            (list path (and attrs (file-truename path))
                  (and attrs (list (file-attribute-size attrs)
                                   (file-attribute-modification-time attrs)
                                   (file-attribute-status-change-time attrs)
                                   (file-attribute-inode-number attrs)))))))
   ((and (consp source) (eq (car source) 'image)
         (proper-list-p (cdr source))
         (zerop (% (length (cdr source)) 2))
         (symbolp (plist-get (cdr source) :type))
         (or (stringp (plist-get (cdr source) :data))
             (stringp (plist-get (cdr source) :file))))
    (cond
     ;; A canvas owns a live pixel buffer that its producer rewrites in
     ;; place, so the payload is not part of its identity.  Comparing two
     ;; multi-megabyte buffers on every layout would cost more than drawing
     ;; the frame, and the pixels never describe a different image.
     ((eq (plist-get (cdr source) :type) 'canvas)
      (let ((props (cdr source)))
        (list source
              (list 'canvas
                    (plist-get props :id)
                    (plist-get props :data-width)
                    (plist-get props :data-height)
                    (plist-get props :scale)
                    (plist-get props :ascent)))))
     (t
      (let ((owned (copy-tree source)))
        (if-let* ((file (plist-get (cdr owned) :file))
                  (normalized (ebox-image--source file)))
            (progn
              (setcdr owned (plist-put (cdr owned) :file (car normalized)))
              (list owned (list owned (cadr normalized))))
          (list owned owned))))))
   (t (error "Ebox image source must be a file or image descriptor"))))

(defun ebox-image--metrics (frame)
  "Return (CELL-WIDTH LINE-HEIGHT ASCENT-PERCENT) for the measuring context.
Use the buffer's effective default face on graphical FRAME, or return nil."
  (when (display-graphic-p frame)
    (let* ((ebox--measure-frame (or frame (selected-frame)))
           (metrics (or (and (eq ebox--measure-frame (selected-frame))
                             ebox--active-metrics)
                        (ebox--display-metrics ebox--measure-buffer))))
      (list (plist-get metrics :char-width)
            (plist-get metrics :line-height)
            (plist-get metrics :ascent)))))

(defun ebox-image--bytes (source)
  "Read SOURCE bytes during preparation, never during rendering."
  (if-let* ((data (and (consp source) (plist-get (cdr source) :data))))
      (if (multibyte-string-p data) (encode-coding-string data 'utf-8-unix) data)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       (if (stringp source) source (plist-get (cdr source) :file)))
      (buffer-string))))

(defun ebox-image--grid (columns rows character cell)
  "Build COLUMNS by ROWS of CHARACTER, using CELL for each cell's properties."
  (mapconcat
   (lambda (y)
     (let ((line (make-string columns character)))
       (dotimes (x columns)
         (add-text-properties x (1+ x) (funcall cell x y) line))
       line))
   (number-sequence 0 (1- rows)) "\n"))

(defun ebox-image--slice (descriptor width y height ascent lh inset)
  "Return a WIDTH-pixel display slice of DESCRIPTOR from Y, HEIGHT tall.
A slice shorter than line height LH sits at the line's bottom, or with
INSET bottom at its top, so the line keeps its height.  ASCENT is the
descriptor's ascent percentage."
  (let ((slice (list 'slice 0 y width height)))
    (if (= height lh)
        (list slice descriptor)
      ;; Redisplay gives a slice HEIGHT * ASCENT / 100 pixels of ascent; raise
      ;; moves it to the font's ascent at the top or descent at the bottom.
      (let* ((font-ascent (floor (* lh ascent) 100))
             (own (floor (* height ascent) 100))
             (want (if (eq inset 'bottom) font-ascent (- height (- lh font-ascent)))))
        (list (list 'raise (/ (float (- want own)) lh)) slice descriptor)))))

(defun ebox-image--graphics (source columns rows metrics frame &optional inset)
  "Prepare SOURCE as COLUMNS by ROWS display slices using METRICS on FRAME.
INSET is (TOP . BOTTOM) pixels left empty above and below the image."
  (let* ((canvas (and (consp source)
                      (eq (plist-get (cdr source) :type) 'canvas)))
         (data (unless canvas (ebox-image--bytes source)))
         (type (if canvas 'canvas
                 (image-type data (and (consp source)
                                       (plist-get (cdr source) :type)) t))))
    (when (image-type-available-p type)
      (pcase-let* ((`(,cw ,lh ,ascent) metrics)
                   (top (min (or (car inset) 0) (1- lh)))
                   (bottom (min (or (cdr inset) 0) (1- lh)))
                   (width (* columns cw))
                   (height (- (* rows lh) top bottom))
                   (descriptor (and (> height 0)
                                    (if (eq type 'canvas)
                                        ;; A canvas descriptor owns a live
                                        ;; pixel buffer; recreating it would
                                        ;; drop its :id and data dimensions,
                                        ;; so slice the published one.
                                        source
                                      ;; WIDTH and HEIGHT are page pixels, the
                                      ;; same units the grid and the slices are
                                      ;; cut in.  Asking for one image pixel per
                                      ;; device pixel as well made a frame with
                                      ;; two device pixels per page pixel draw
                                      ;; the picture at twice its size, so each
                                      ;; slice showed half a row of it and every
                                      ;; label appeared twice.
                                      ;; Image pixels are page pixels here: a
                                      ;; frame that scales images by its own
                                      ;; factor would answer a larger size than
                                      ;; asked for, and both the size check
                                      ;; below and the slice grid are written
                                      ;; in page pixels.
                                      (apply #'create-image data type t :width width
                                             :height height :ascent ascent
                                             :scale 1
                                             :margin 0
                                             (and ebox-image--background
                                                  (list :background
                                                        ebox-image--background)))))))
        ;; A type that cannot decode/scale this source is not usable.  Decoding
        ;; here also warms Emacs' cache before a caller publishes the block.
        ;; Each row is one glyph showing a full-width slice: redisplay
        ;; draws an image once per glyph, so per-cell slices multiply the
        ;; cost of every scroll and repaint by the column count.
        (when (and descriptor (equal (image-size descriptor t frame)
                                     (cons width height)))
          (mapconcat
           (lambda (y)
             (let* ((start (max 0 (- (* y lh) top)))
                    (end (min height (- (* (1+ y) lh) top))))
               (propertize " " 'display
                           (ebox-image--slice descriptor width start (- end start) ascent lh
                                              (and (= y (1- rows)) (> bottom 0)
                                                   'bottom)))))
           (number-sequence 0 (1- rows)) "\n"))))))

(defun ebox-image--display-image (display)
  "Return the image in native DISPLAY, including sliced/raised displays."
  (cond ((eq (car-safe display) 'image) display)
        ((consp (car-safe display)) (assq 'image display))))

(defun ebox-image--svg-brightness (data amount foreground)
  "Filter SVG DATA by AMOUNT without rasterizing its vector content.
FOREGROUND supplies native currentColor before filtering.  Preserve explicit
colors, namespaces and the root viewport, including nonzero viewBox origins."
  (let* ((tree (with-temp-buffer
                 (insert (if (multibyte-string-p data) data
                           (decode-coding-string data 'utf-8)))
                 (xml-parse-region (point-min) (point-max))))
         (root (car tree))
         (viewbox (cdr (assq 'viewBox (cadr root))))
         (bounds (and viewbox (split-string viewbox "[ ,\t\n]+" t)))
         (id "ebox-brightness")
         (slope (number-to-string amount)))
    (while (string-match-p (regexp-quote id) data) (setq id (concat id "-b")))
    (when (and foreground (not (assq 'color (cadr root))))
      (setf (cadr root) (cons (cons 'color foreground) (cadr root))))
    (setcdr
     (cdr root)
     (list
      `(defs nil
         (filter ((id . ,id) (filterUnits . "userSpaceOnUse")
                  (x . ,(or (nth 0 bounds) "0")) (y . ,(or (nth 1 bounds) "0"))
                  (width . ,(or (nth 2 bounds) "100%"))
                  (height . ,(or (nth 3 bounds) "100%"))
                  (color-interpolation-filters . "sRGB"))
           (feComponentTransfer nil
             (feFuncR ((type . "linear") (slope . ,slope)))
             (feFuncG ((type . "linear") (slope . ,slope)))
             (feFuncB ((type . "linear") (slope . ,slope))))))
      (cons 'g (cons (list (cons 'filter (concat "url(#" id ")"))) (cddr root)))))
    (with-temp-buffer (xml-print tree) (buffer-string))))

(defun ebox-image--brightness-image (image amount foreground background frame)
  "Return IMAGE's in-memory AMOUNT brightness variant on FRAME.
FOREGROUND is its native color before filtering.  BACKGROUND is the
already filtered background for transparent pixels.
Only self-contained PNG, JPEG and SVG data are embedded: unsupported or
file-only native descriptors keep their pixels rather than disappearing.
Preparation turns local image files into self-contained data descriptors."
  (let* ((props (cdr image))
         (data (plist-get props :data))
         (mime (alist-get (plist-get props :type)
                          '((png . "image/png") (jpeg . "image/jpeg")
                            (svg . "image/svg+xml")))))
    (if (not (and mime (stringp data) (not (plist-get props :file))
                  (display-graphic-p frame) (image-type-available-p 'svg)))
        image
      (ebox-image--composite
       image (list 'brightness amount foreground background frame)
       (lambda ()
         (let* ((rotation (plist-get props :rotation))
                (size (image-size
                       (if (or (null rotation) (zerop rotation)) image
                         (cons 'image (plist-put (copy-sequence props) :rotation 0)))
                       t frame))
                (margin (or (plist-get props :margin) 0))
                (relief (abs (or (plist-get props :relief) 0)))
                (width (- (car size) (* 2 (+ relief (if (consp margin) (car margin) margin)))))
                (height (- (cdr size) (* 2 (+ relief (if (consp margin) (cdr margin) margin)))))
                (svg-source (eq (plist-get props :type) 'svg))
                (uri (unless svg-source
                       (ebox-image--composite
                        image 'data-uri
                        (lambda ()
                          (concat "data:" mime ";base64,"
                                  (base64-encode-string data t))))))
                (svg (if svg-source
                         (ebox-image--svg-brightness data amount foreground)
                       (format
                        (concat "<svg xmlns='http://www.w3.org/2000/svg' "
                              "xmlns:xlink='http://www.w3.org/1999/xlink' width='%s' height='%s'>"
                              "<defs><filter id='b' x='0' y='0' width='1' height='1' "
                              "color-interpolation-filters='sRGB'><feComponentTransfer>"
                              "<feFuncR type='linear' slope='%s'/>"
                              "<feFuncG type='linear' slope='%s'/>"
                              "<feFuncB type='linear' slope='%s'/>"
                              "</feComponentTransfer></filter></defs>"
                              "<image width='%s' height='%s' preserveAspectRatio='none' "
                              "filter='url(#b)' xlink:href='%s'/></svg>")
                        width height amount amount amount width height uri)))
                (variant (cl-loop for (key value) on props by #'cddr
                                  unless (memq key '(:type :data :width :height :scale
                                                    :max-width :max-height :background))
                                  append (list key value))))
           ;; The wrapper uses the already displayed dimensions; retaining the
           ;; original scale would scale twice.  Native margin, relief, ascent
           ;; and rotation still apply, and display slices are left untouched.
           (append (list 'image :type 'svg :data svg :width width :height height)
                   (and background (list :background background)) variant)))))))

(defun ebox-image--brightness-display (display amount foreground background)
  "Filter DISPLAY by AMOUNT with FOREGROUND over BACKGROUND without I/O.
Keep native slice/raise modifiers and share each derived display value."
  (let* ((image (ebox-image--display-image display))
         (frame (or ebox--measure-frame
                    (and ebox--measure-buffer
                         (when-let* ((window (get-buffer-window ebox--measure-buffer)))
                           (window-frame window)))
                    (selected-frame))))
    (if (or (= amount 1) (not image)) display
      (ebox-image--composite
       display (list 'display amount foreground background frame)
       (lambda ()
         (let ((variant (ebox-image--brightness-image image amount foreground background frame)))
           (cond ((eq variant image) display)
                 ((eq display image) variant)
                 (t (mapcar (lambda (item) (if (eq item image) variant item)) display)))))))))

(defun ebox-image--run (source program arguments)
  "Run PROGRAM with ARGUMENTS on SOURCE, returning bytes only on success."
  (when-let* ((executable (executable-find program)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let* ((coding-system-for-read 'binary)
             (coding-system-for-write 'binary)
             (data (and (consp source) (plist-get (cdr source) :data)
                        (ebox-image--bytes source)))
             (file (if (stringp source) source (plist-get (cdr source) :file)))
             (args (mapcar (lambda (arg) (if (eq arg :input)
                                               (if data "-" file) arg))
                           arguments))
             (status
              (if data
                  (progn
                    (insert data)
                    (apply #'call-process-region (point-min) (point-max)
                           executable t (list t nil) nil args))
                (apply #'call-process executable nil (list t nil) nil args))))
        (when (eql status 0) (buffer-string))))))

(defun ebox-image--ansi-face (face property)
  "Read PROPERTY from the plists in ANSI FACE."
  (if (keywordp (car-safe face)) (plist-get face property)
    (cl-loop for item in face thereis (and (listp item) (plist-get item property)))))

(defun ebox-image--chafa (source columns rows)
  "Convert SOURCE to a COLUMNS by ROWS truecolor half-block grid with chafa."
  (when-let* ((bytes
               (ebox-image--run
                source "chafa"
                (list "--format=symbols" "--colors=full" "--symbols=u2580"
                      "--fill=none" "--optimize=0" "--relative=off"
                      "--animate=off" "--stretch" "--polite=on" "--probe=off"
                      "--bg=#000000" "--size" (format "%dx%d" columns rows)
                      :input))))
    (let* ((ansi-color-apply-face-function #'ansi-color-apply-text-property-face)
           (text (ansi-color-apply (decode-coding-string bytes 'utf-8-unix)))
           (text (string-remove-suffix "\n" text))
           (result (substring-no-properties text)))
      (dotimes (i (length text))
        (unless (= (aref text i) ?\n)
          (let ((face (get-text-property i 'font-lock-face text)))
            (put-text-property
             i (1+ i) 'face
             (list :foreground (ebox-image--ansi-face face :foreground)
                   :background (ebox-image--ansi-face face :background)) result))))
      result)))

(defun ebox-image--ffmpeg (source columns rows)
  "Convert SOURCE to COLUMNS by ROWS using ffmpeg's two RGB pixels per cell."
  (when-let* ((bytes
               (ebox-image--run
                source "ffmpeg"
                (list "-v" "error" "-nostdin" "-i" :input
                      "-vf" (format "scale=%d:%d:flags=area" columns (* 2 rows))
                      "-frames:v" "1" "-f" "rawvideo" "-pix_fmt" "rgb24" "pipe:1"))))
    (when (= (length bytes) (* columns rows 6))
      (cl-labels ((rgb (x y)
                   (let ((offset (* 3 (+ x (* y columns)))))
                     (format "#%02x%02x%02x" (aref bytes offset)
                             (aref bytes (+ offset 1)) (aref bytes (+ offset 2))))))
        (ebox-image--grid columns rows ?▀
                          (lambda (x y)
                            (list 'face (list :foreground (rgb x (* y 2))
                                              :background (rgb x (1+ (* y 2)))))))))))

(defun ebox-image--valid-grid-p (text columns rows)
  "Whether TEXT is a safe COLUMNS by ROWS truecolor converter result."
  (and (stringp text)
       (= (length text) (+ (* columns rows) (1- rows)))
       (cl-loop for i below (length text)
                always
                (if (= (% i (1+ columns)) columns)
                    (= (aref text i) ?\n)
                  (and (= (aref text i) ?▀)
                       (let ((face (get-text-property i 'face text)))
                         (cl-every
                          (lambda (key)
                            (let ((color (plist-get face key)))
                              (and (stringp color)
                                   (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color))))
                          '(:foreground :background))))))))

(cl-defun ebox-image-prepare (source columns rows &key (adapter 'auto)
                                   (frame (selected-frame)) inset
                                   (converters ebox-image-converters))
  "Prepare SOURCE for an integer COLUMNS by ROWS character area.
Return an opaque reusable value; inspect it with `ebox-image-info'.  SOURCE
is a local file or an Emacs image descriptor containing :file or :data.
ADAPTER is auto, text, or placeholder.  Auto tries graphics on FRAME with a
usable image type and font metrics, then CONVERTERS, then a monochrome ASCII
placeholder.  Text skips graphics.  Placeholder skips both.  CONVERTERS obeys
`ebox-image-converters'.  Missing/corrupt images also become placeholders.
INSET is nil or (TOP . BOTTOM), pixels below one line height that a graphics
image leaves empty above and below it inside its rows; the image scales
into the rest, and the gap shows the box background.
This is the only source I/O step: call outside the render/commit hot path.
Native decoding is warmed here.  Paint can derive cached SVG brightness
composites from these bytes without reopening the source or converters.
Repeat after source or frame/font changes; identical preparations are cached."
  (unless (and (integerp columns) (> columns 0) (integerp rows) (> rows 0))
    (error "Ebox image columns and rows must be positive integers"))
  (unless (memq adapter '(auto text placeholder))
    (error "Unknown Ebox image adapter: %S" adapter))
  (unless (or (null inset)
              (and (consp inset) (natnump (car inset)) (natnump (cdr inset))))
    (error "Ebox image inset must be nil or (TOP . BOTTOM) pixels"))
  (unless (and (proper-list-p converters)
               (cl-every (lambda (entry)
                           (and (consp entry) (symbolp (car entry))
                                (functionp (cdr entry)))) converters))
    (error "Invalid Ebox image converter protocol"))
  (pcase-let* ((`(,owned ,identity) (ebox-image--source source))
               (metrics (and (eq adapter 'auto) (ebox-image--metrics frame)))
               (key (list identity columns rows adapter metrics inset
                          (and metrics image-types) (copy-tree converters)))
               (cached (ebox-image--cache-take key)))
    (or cached
        (let ((text (and metrics
                         (ignore-errors
                           (ebox-image--graphics owned columns rows metrics frame inset))))
              (selected 'graphics) converter)
          (unless text
            (setq selected 'text)
            (unless (eq adapter 'placeholder)
              (catch 'converted
                (dolist (entry converters)
                  (let ((result (ignore-errors
                                  (funcall (cdr entry) owned columns rows))))
                    (when (ignore-errors (ebox-image--valid-grid-p result columns rows))
                      ;; Rebuild just the allowed properties: converters cannot
                      ;; inject display, keymap or ownership into publication.
                      (setq text (substring-no-properties result)
                            converter (car entry))
                      (dotimes (i (length result))
                        (unless (= (aref result i) ?\n)
                          (let ((face (get-text-property i 'face result)))
                            (put-text-property
                             i (1+ i) 'face
                             (list :foreground (copy-sequence (plist-get face :foreground))
                                   :background (copy-sequence (plist-get face :background)))
                             text))))
                      (throw 'converted t)))))))
          (unless text
            (setq selected 'placeholder
                  text (ebox-image--grid columns rows ?. (lambda (_x _y) nil))))
          (let ((prepared (ebox-image--make-prepared
                           :columns columns :rows rows :adapter selected
                           :converter converter :text text)))
            (ebox-image--cache-put key prepared)
            prepared)))))

(defun ebox-image--check (prepared)
  "Validate PREPARED and return it."
  (unless (ebox-image--prepared-p prepared)
    (error "Expected a value from ebox-image-prepare"))
  prepared)

(defun ebox-image-info (prepared)
  "Return PREPARED's adapter, converter, columns and rows as a fresh plist."
  (ebox-image--check prepared)
  (list :adapter (ebox-image--prepared-adapter prepared)
        :converter (ebox-image--prepared-converter prepared)
        :columns (ebox-image--prepared-columns prepared)
        :rows (ebox-image--prepared-rows prepared)))

(defun ebox-image-content (prepared)
  "Return an owned character string for PREPARED, without any I/O.
Lines are separated by newlines.  Graphics display values are shared
descriptors and slices: do not mutate those nested values."
  (ebox-image--check prepared)
  (copy-sequence (ebox-image--prepared-text prepared)))

(defun ebox-image--lines (prepared)
  "Return PREPARED's raster as a list of line strings."
  (or (ebox-image--prepared-lines prepared)
      (setf (ebox-image--prepared-lines prepared)
            (split-string (ebox-image--prepared-text prepared) "\n"))))

(defun ebox-image--width (prepared)
  "Return PREPARED's raster width in pixels."
  (let ((width (ebox-image--prepared-width prepared)))
    (if (and width (eq (car width) ebox--width-epoch)) (cdr width)
      (cdr (setf (ebox-image--prepared-width prepared)
                 (cons ebox--width-epoch
                       (apply #'max 0 (mapcar #'ebox-string-pixel-width
                                              (ebox-image--lines prepared)))))))))

(provide 'ebox-image)
;;; ebox-image.el ends here
